//
//  DiffViewerView.swift
//  kero
//
//  A git diff opened as a tab: `DiffTab` loads both sides of the change and
//  computes the diff natively (DiffEngine); `DiffRootView` renders it with
//  STTextView-based code panes (DiffTextView.swift) in unified or split
//  layout, with an editable buffer for worktree files. This replaced the
//  WKWebView-based PierreDiffsSwift renderer — everything on screen is AppKit.
//

import AppKit
import Combine
import Foundation
import STTextView
import SwiftUI

/// Mutable pipe storage shared by the two dedicated readers in
/// `DiffTab.runGitData`. Each instance is written by exactly one reader.
private nonisolated final class DiffPipeData: @unchecked Sendable {
    var value = Data()
}

/// Unified vs. split layout. Raw values match the retired web renderer's, so
/// the persisted preference carries over.
enum DiffLayoutStyle: String {
    case unified
    case split
}

/// Lightweight UI state that should follow Kero across launches without
/// becoming a user-facing TOML setting.
private enum DiffViewPreferences {
    private static let layoutKey = "diffView.layout"
    private static let modeKey = "diffView.mode"

    static var layoutStyle: DiffLayoutStyle {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: layoutKey),
                  let style = DiffLayoutStyle(rawValue: rawValue)
            else { return .unified }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: layoutKey)
        }
    }

    static var prefersEditing: Bool {
        get { UserDefaults.standard.string(forKey: modeKey) == "edit" }
        set {
            UserDefaults.standard.set(newValue ? "edit" : "review", forKey: modeKey)
        }
    }
}

/// Fixed typography shared by every diff pane: pinning the line height makes
/// split-view rows align exactly (a tall emoji can't stretch one side) and
/// makes scroll math a multiplication.
enum DiffTypography {
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: font)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }
}

/// The precomputed render artifacts for one old/new content pair. Built off
/// the main actor; colors for syntax runs are baked into the attributed
/// documents (base text color included), so the display is rebuilt when the
/// font, ghostty theme, or light/dark appearance changes.
nonisolated struct DiffDisplay {
    let id = UUID()
    let computation: DiffComputation
    let unifiedText: NSAttributedString
    let leftText: NSAttributedString
    let rightText: NSAttributedString
}

/// The content-derived intermediates a display is built from, cached on the
/// tab so expanding a folded run rebuilds documents without re-running the
/// diff or the syntax pass.
private nonisolated struct DiffDisplayInputs {
    let core: DiffCore
    let oldRuns: [DiffHighlightRun]
    let newRuns: [DiffHighlightRun]
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
final class DiffTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool
    /// Historical commit shown by this tab. Nil keeps the existing
    /// index/worktree behavior.
    let commitHash: String?
    /// First parent and name-status metadata used to describe a historical
    /// comparison in the tab strip.
    let commitParentHash: String?
    let commitStatus: Character?
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String?

    @Published private(set) var error: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isUnmerged = false
    @Published private(set) var isEditable = false
    @Published private(set) var isDirty = false
    @Published var saveError: String?

    /// Whether the two sides differ at all (drives the "No changes" state).
    @Published private(set) var hasChanges = false
    @Published private(set) var layoutStyle: DiffLayoutStyle = DiffViewPreferences.layoutStyle
    @Published private(set) var isEditing = false
    /// Rendered diff artifacts; nil while the first computation is in flight.
    @Published private(set) var display: DiffDisplay?
    /// Live decorations for the edit-mode buffer, recomputed (debounced) as
    /// the user types.
    @Published private(set) var editDecorations: DiffDecorations = .empty
    /// Per-fold expansion counters (`DiffCollapsedRun.runIndex` →
    /// lines revealed at each edge). Reset whenever the compared content
    /// changes, since run identities derive from the diff ops.
    private var runExpansions: [Int: DiffRunExpansion] = [:]
    /// Cached diff/highlight intermediates backing `display`, so expansion
    /// only rebuilds documents.
    private var displayInputs: DiffDisplayInputs?

    /// The mounted root view, for routing Find menu commands to whichever
    /// text view is active. Weak: the view belongs to the pane hierarchy.
    weak var hostRootView: DiffRootView?

    private(set) var oldContent = ""
    private(set) var newContent = ""

    private nonisolated static let maxBytes = 5 << 20
    private var savedNewContent = ""
    /// Live text of the edit-mode buffer. Kept out of the published display
    /// so a keystroke never rebuilds the review documents.
    private(set) var editedNewContent = ""
    /// Bumped whenever `editedNewContent` is replaced from *outside* the edit
    /// pane (a reload), so the pane knows to reset its buffer — without
    /// comparing full document strings on every render.
    private(set) var editBufferRevision: UInt = 0
    private var reloadGeneration: UInt = 0
    private var displayGeneration: UInt = 0
    private var displayTask: Task<Void, Never>?
    /// The appearance the current display run was baked for, so window
    /// appearance callbacks only trigger a rebake on a real light/dark flip.
    private var displayBakedDark: Bool?
    private var editGeneration: UInt = 0
    private var editDecorationsTask: Task<Void, Never>?
    private var settingsObservers: Set<AnyCancellable> = []

    init(
        repoRoot: String,
        path: String,
        staged: Bool,
        untracked: Bool,
        origPath: String?,
        commitHash: String? = nil,
        commitParentHash: String? = nil,
        commitStatus: Character? = nil
    ) {
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        self.commitHash = commitHash
        self.commitParentHash = commitParentHash
        self.commitStatus = commitStatus

        // The documents bake in font and colors, so they're rebuilt when the
        // font settings or the selected ghostty theme change. (Light/dark
        // appearance flips are caught by the root view, which sees the
        // effective appearance.)
        let settings = AppSettings.shared
        Publishers.Merge3(
            settings.$fontFamily.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$fontSize.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Theme.changes.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.recomputeDisplay()
            if self?.isEditing == true {
                self?.refreshEditDecorations(immediate: true)
            }
        }
        .store(in: &settingsObservers)

        reload()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var title: String {
        if let commitHash {
            let after = "\(name) (\(commitHash.prefix(7)))"
            guard let commitParentHash else { return after }
            let beforeName = ((origPath ?? path) as NSString).lastPathComponent
            let before = "\(beforeName) (\(commitParentHash.prefix(7)))"
            switch commitStatus {
            case "A": return after
            case "D": return before
            default: return "\(before) ↔ \(after)"
            }
        }
        return staged
            ? String(localized: "\(name) (Staged)", comment: "Tab title for the staged diff of a file.")
            : name
    }

    func reload() {
        // Keep the editor's document and undo history stable until the user
        // leaves edit mode, and never replace an unsaved buffer from disk.
        guard !isEditing, !isDirty else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        error = nil
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked
        let commitHash = commitHash

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var failureVar: String?
                let unmerged = commitHash == nil && !staged
                    && Self.isUnmerged(path: path, in: root)
                let old: String
                let new: String
                if let commitHash {
                    old = Self.firstGitContent(
                        ["\(commitHash)^:\(oldPath)"], in: root, error: &failureVar
                    )
                    new = Self.firstGitContent(
                        ["\(commitHash):\(path)"], in: root, error: &failureVar
                    )
                } else if staged {
                    old = Self.firstGitContent(
                        ["HEAD:\(oldPath)"], in: root, error: &failureVar
                    )
                    new = Self.firstGitContent(
                        [":\(path)"], in: root, error: &failureVar
                    )
                } else {
                    if untracked {
                        old = ""
                    } else {
                        // An unmerged index has no stage-0 `:path`. Prefer our
                        // side, then the merge base, so conflict rows show a
                        // meaningful before-side instead of the whole file as new.
                        old = Self.firstGitContent(
                            [":\(oldPath)", ":2:\(oldPath)", ":1:\(oldPath)", "HEAD:\(oldPath)"],
                            in: root,
                            error: &failureVar
                        )
                    }
                    new = Self.readWorktreeFile(root: root, path: path, error: &failureVar)
                }
                let editable = commitHash == nil && !staged
                    && Self.isEditableWorktreeFile(root: root, path: path)
                return (
                    old: old,
                    new: new,
                    failure: failureVar,
                    unmerged: unmerged,
                    editable: editable
                )
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            let contentChanged = result.old != self.oldContent
                || result.new != self.newContent
            if contentChanged {
                // Fold-run identities derive from the diff ops; new content
                // means new ops.
                self.runExpansions.removeAll()
            }
            self.isLoading = false
            self.error = result.failure
            self.isUnmerged = result.unmerged
            self.isEditable = result.editable && result.failure == nil
            self.isEditing = self.isEditable && DiffViewPreferences.prefersEditing
            self.oldContent = result.old
            self.newContent = result.new
            self.savedNewContent = result.new
            self.editedNewContent = result.new
            self.editBufferRevision &+= 1
            self.isDirty = false
            self.saveError = nil
            self.hasChanges = result.old != result.new
            // Re-visits reload from git but usually find identical bytes;
            // recomputing would re-render the same diff.
            if contentChanged || (self.hasChanges && self.display == nil) {
                self.recomputeDisplay()
            }
            if self.isEditing {
                self.refreshEditDecorations(immediate: true)
            }
        }
    }

    /// Refreshes a live diff when navigation brings it back on screen.
    /// Historical blobs are immutable and already loaded by `init`; reloading
    /// on every project switch would only recompute the same diff. An initial
    /// live load also stays in flight rather than being duplicated by the
    /// view's first mount.
    func refreshWhenSelected() {
        guard commitHash == nil, !isLoading else { return }
        reload()
    }

    // MARK: Display pipeline

    /// Rebuilds the review documents (line diff + syntax colors + attributed
    /// text) off the main actor. Superseded runs are dropped by generation.
    func recomputeDisplay() {
        displayGeneration &+= 1
        let generation = displayGeneration
        guard hasChanges, error == nil else {
            display = nil
            displayInputs = nil
            return
        }
        let old = oldContent
        let new = newContent
        let path = path
        let expansions = runExpansions
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        displayBakedDark = dark
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            let highlightContext = await DiffSyntaxHighlighter.context(for: path)
            let font = TerminalFont.current()
            let paragraphStyle = DiffTypography.paragraphStyle(for: font)
            let textColor = Theme.terminal(dark: dark).foregroundNSColor
            let payload = await Task.detached(priority: .userInitiated) {
                () -> (inputs: DiffDisplayInputs, display: DiffDisplay) in
                let inputs = DiffDisplayInputs(
                    core: DiffCore.compute(oldText: old, newText: new),
                    oldRuns: highlightContext.map {
                        DiffSyntaxHighlighter.runs(text: old, context: $0)
                    } ?? [],
                    newRuns: highlightContext.map {
                        DiffSyntaxHighlighter.runs(text: new, context: $0)
                    } ?? []
                )
                let display = Self.makeDisplay(
                    inputs: inputs, expansions: expansions,
                    font: font, paragraphStyle: paragraphStyle, textColor: textColor
                )
                return (inputs, display)
            }.value
            guard let self, !Task.isCancelled, self.displayGeneration == generation else { return }
            self.displayInputs = payload.inputs
            self.display = payload.display
        }
    }

    /// Reveals one chunk of a folded run (Pierre's semantics: 100 lines per
    /// click, at the edge(s) the separator's position dictates). Rebuilds only
    /// the rendered documents — diff ops and highlight runs come from cache.
    func expandRun(_ fold: DiffCollapsedRun) {
        guard hasChanges else { return }
        var expansion = runExpansions[fold.runIndex] ?? DiffRunExpansion()
        switch fold.direction {
        case .revealUp:
            expansion.fromEnd += DiffCollapse.expansionLineCount
        case .revealDown:
            expansion.fromStart += DiffCollapse.expansionLineCount
        case .both:
            expansion.fromStart += DiffCollapse.expansionLineCount
            expansion.fromEnd += DiffCollapse.expansionLineCount
        }
        runExpansions[fold.runIndex] = expansion
        guard let inputs = displayInputs else {
            recomputeDisplay()
            return
        }
        displayGeneration &+= 1
        let generation = displayGeneration
        let expansions = runExpansions
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        displayBakedDark = dark
        let font = TerminalFont.current()
        let paragraphStyle = DiffTypography.paragraphStyle(for: font)
        let textColor = Theme.terminal(dark: dark).foregroundNSColor
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            let payload = await Task.detached(priority: .userInitiated) {
                Self.makeDisplay(
                    inputs: inputs, expansions: expansions,
                    font: font, paragraphStyle: paragraphStyle, textColor: textColor
                )
            }.value
            guard let self, !Task.isCancelled, self.displayGeneration == generation else { return }
            self.display = payload
        }
    }

    /// Documents + baked attributed text for the current fold state.
    private nonisolated static func makeDisplay(
        inputs: DiffDisplayInputs,
        expansions: [Int: DiffRunExpansion],
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        textColor: NSColor
    ) -> DiffDisplay {
        let computation = DiffComputation.build(core: inputs.core, expansions: expansions)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        return DiffDisplay(
            computation: computation,
            unifiedText: DiffSyntaxHighlighter.attributedDocument(
                computation.unified, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            ),
            leftText: DiffSyntaxHighlighter.attributedDocument(
                computation.splitLeft, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            ),
            rightText: DiffSyntaxHighlighter.attributedDocument(
                computation.splitRight, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            )
        )
    }

    /// Rebakes the display when the window's light/dark appearance no longer
    /// matches the one the documents were built for.
    func refreshDisplayForAppearance(dark: Bool) {
        guard let displayBakedDark, displayBakedDark != dark else { return }
        recomputeDisplay()
        if isEditing {
            refreshEditDecorations(immediate: true)
        }
    }

    // MARK: Editing

    /// Accepts the live buffer from the edit pane. The text view owns the
    /// document; this mirrored value drives dirty state, saving, and the
    /// debounced decoration recompute.
    func updateEditedContent(_ contents: String) {
        guard isEditable else { return }
        editedNewContent = contents
        isDirty = contents != savedNewContent
        if isDirty {
            // A reload already in flight must not win after the first edit.
            reloadGeneration &+= 1
        }
        refreshEditDecorations()
    }

    func setLayoutStyle(_ style: DiffLayoutStyle) {
        guard layoutStyle != style else { return }
        layoutStyle = style
        DiffViewPreferences.layoutStyle = style
    }

    func setEditing(_ editing: Bool) {
        guard isEditable, isEditing != editing else { return }
        if editing {
            isEditing = true
            refreshEditDecorations(immediate: true)
        } else {
            // Publish the reviewed buffer so the read-only diff shows the
            // text the user just edited (saved or not).
            isEditing = false
            if newContent != editedNewContent {
                newContent = editedNewContent
                runExpansions.removeAll()
                hasChanges = oldContent != newContent
                recomputeDisplay()
            } else if display == nil, hasChanges {
                recomputeDisplay()
            }
        }
        DiffViewPreferences.prefersEditing = editing
    }

    private func refreshEditDecorations(immediate: Bool = false) {
        editGeneration &+= 1
        let generation = editGeneration
        let old = oldContent
        let new = editedNewContent
        // Ghost lines are baked with the same inputs as the review documents:
        // the cached old-side highlight runs plus the current typography.
        let oldRuns = displayInputs?.oldRuns ?? []
        let font = TerminalFont.current()
        let paragraphStyle = DiffTypography.paragraphStyle(for: font)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = Theme.terminal(dark: dark)
        let textColor = theme.foregroundNSColor
        let emphasisColor = theme.backgroundNSColor.blended(
            withFraction: 0.38, of: theme.paletteNSColor(1) ?? .systemRed
        ) ?? .systemRed
        editDecorationsTask?.cancel()
        editDecorationsTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let decorations = await Task.detached(priority: .userInitiated) {
                Self.computeEditDecorations(
                    old: old, new: new, oldRuns: oldRuns,
                    font: font, paragraphStyle: paragraphStyle,
                    textColor: textColor, emphasisColor: emphasisColor
                )
            }.value
            guard let self, !Task.isCancelled, self.editGeneration == generation else { return }
            self.editDecorations = decorations
        }
    }

    private nonisolated static func computeEditDecorations(
        old: String,
        new: String,
        oldRuns: [DiffHighlightRun],
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        textColor: NSColor,
        emphasisColor: NSColor
    ) -> DiffDecorations {
        let (oldLines, _) = DiffLineSplitter.lines(of: old)
        let (newLines, _) = DiffLineSplitter.lines(of: new)
        let ops = DiffEngine.lineOps(old: oldLines, new: newLines)
        let state = DiffComputation.editState(ops: ops, oldLines: oldLines, newLines: newLines)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        let oldNS = old as NSString
        let ghostBlocks = state.ghosts.map { block in
            DiffDecorations.GhostBlock(
                anchorLine: block.anchorLine,
                firstOldLine: block.firstOldLine,
                lines: DiffSyntaxHighlighter.attributedGhostLines(
                    oldText: oldNS,
                    block: block,
                    runs: oldRuns,
                    baseAttributes: base,
                    emphasisColor: emphasisColor
                )
            )
        }
        return .edit(
            state: state,
            snapshotOffsets: newLines.map(\.utf16Range.location),
            lineCount: newLines.count,
            ghostBlocks: ghostBlocks
        )
    }

    func save() {
        guard isEditable, isDirty else { return }
        let fileURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path)
        do {
            try editedNewContent.write(to: fileURL, atomically: true, encoding: .utf8)
            savedNewContent = editedNewContent
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Routes the Find menu at whichever diff text view is on screen.
    func performFindAction(_ action: FindAction) {
        hostRootView?.performFindAction(action)
    }

    // MARK: Git plumbing

    private nonisolated enum GitContent {
        case missing
        case content(String)
        case binary
        case tooLarge
    }

    private nonisolated static func firstGitContent(
        _ specs: [String], in root: String, error: inout String?
    ) -> String {
        for spec in specs {
            switch gitContent(spec, in: root) {
            case .missing:
                continue
            case .content(let content):
                return content
            case .binary:
                error = String(localized: "Binary file")
                return ""
            case .tooLarge:
                error = String(localized: "File is too large to diff")
                return ""
            }
        }
        return ""
    }

    private nonisolated static func gitContent(_ spec: String, in root: String) -> GitContent {
        let size = GitStatusModel.runGit(["cat-file", "-s", spec], in: root)
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        let run = runGitData(["cat-file", "blob", spec], in: root)
        guard run.status == 0 else { return .missing }
        guard run.stdout.count <= maxBytes else { return .tooLarge }
        guard !run.stdout.contains(0),
              let content = String(data: run.stdout, encoding: .utf8)
        else {
            return .binary
        }
        return .content(content)
    }

    /// GitStatusModel's general runner intentionally exposes decoded text.
    /// Diff blobs need their original bytes so invalid UTF-8 and embedded NULs
    /// cannot be mistaken for an empty text file.
    private nonisolated static func runGitData(
        _ args: [String], in root: String
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }

        let outData = DiffPipeData()
        let errData = DiffPipeData()
        let captureLimit = maxBytes + 1
        let readers = DispatchGroup()
        // Pipe EOF is part of this synchronous Git operation. Matching the
        // caller avoids a user-initiated diff load waiting on utility readers.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            // Drain the pipe so Git cannot deadlock, but retain at most one
            // byte beyond the limit. The index may change between cat-file's
            // size check and this read while an agent is working.
            while true {
                let chunk: Data
                do {
                    guard let next = try stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                let remaining = captureLimit - outData.value.count
                if remaining > 0 {
                    outData.value.append(chunk.prefix(remaining))
                }
            }
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            outData.value,
            String(data: errData.value, encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func isUnmerged(path: String, in root: String) -> Bool {
        let run = GitStatusModel.runGit(
            ["--literal-pathspecs", "ls-files", "--unmerged", "--", path], in: root
        )
        return run.status == 0 && !run.stdout.isEmpty
    }

    /// Editing is limited to regular worktree files. In particular, writing a
    /// symlink atomically would replace the link itself with a regular file.
    private nonisolated static func isEditableWorktreeFile(root: String, path: String) -> Bool {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return false }
        return true
    }

    private nonisolated static func readWorktreeFile(
        root: String, path: String, error: inout String?
    ) -> String {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            guard destination.utf8.count <= maxBytes else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            return destination
        }
        do {
            // Keep one descriptor for the whole read: replacing the path while
            // an agent writes cannot redirect us to a different, larger file.
            // Seek checks catch growth without ever loading more than maxBytes.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            try handle.seek(toOffset: 0)

            var data = Data()
            while data.count < maxBytes {
                let remaining = min(64 * 1024, maxBytes - data.count)
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            let finalSize = try handle.seekToEnd()
            guard finalSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                error = String(localized: "Binary file")
                return ""
            }
            return text
        } catch let readError as CocoaError
            where readError.code == .fileNoSuchFile || readError.code == .fileReadNoSuchFile {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        } catch let fileError {
            error = String(
                localized: "Unable to read file: \(fileError.localizedDescription)",
                comment: "Diff error followed by a system-provided error description."
            )
            return ""
        }
    }
}

// MARK: - Root view

/// The AppKit root of a diff tab: banners, the controls bar, and the content
/// area that swaps between placeholders, the loading skeleton, the read-only
/// unified/split panes, and the editable buffer.
final class DiffRootView: NSView, STTextViewDelegate {
    private let diff: DiffTab

    private let conflictBanner = DiffBannerView(
        icon: "arrow.triangle.merge",
        text: String(localized: "Unresolved merge conflict"),
        detail: String(localized: "Resolve before committing"),
        tint: .systemOrange
    )
    private let saveErrorBar = DiffBannerView(
        icon: "exclamationmark.triangle.fill",
        text: "",
        detail: nil,
        tint: NSColor(srgbRed: 0.82, green: 0.60, blue: 0.13, alpha: 1)
    )
    private let controls = DiffControlsNSView()
    private let controlsSkeleton = DiffControlsSkeletonNSView()
    private let placeholder = DiffPlaceholderView()
    private let skeleton = DiffSkeletonNSView()

    /// Review panes, created lazily; edit pane separately (its syntax plugin
    /// cannot be detached, so review and edit never share a text view).
    private var unifiedPane: DiffCodePaneView?
    private var leftPane: DiffCodePaneView?
    private var rightPane: DiffCodePaneView?
    private var splitDivider: NSView?
    private var editPane: DiffCodePaneView?

    /// The side that last had focus, for routing Find.
    private weak var focusedTextView: STTextView?

    private var renderedEditRevision: UInt?
    private var subscriptions: Set<AnyCancellable> = []
    private var renderScheduled = false

    /// Whether this tab is the frontmost one; refresh runs on the rising edge.
    var isSelectedTab = false {
        didSet {
            if isSelectedTab, !oldValue {
                diff.refreshWhenSelected()
            }
            if !isSelectedTab, oldValue {
                // Diff panes stay mounted while other tabs are selected;
                // NSTextFinder's bar and match overlays would keep drawing
                // over whatever replaced them.
                for pane in [unifiedPane, leftPane, rightPane, editPane] {
                    hideFindInterface(on: pane)
                }
            }
        }
    }

    private func hideFindInterface(on pane: DiffCodePaneView?) {
        guard let pane, pane.scrollView.isFindBarVisible else { return }
        pane.textView.textFinder.performAction(.hideFindInterface)
    }

    init(diff: DiffTab) {
        self.diff = diff
        super.init(frame: .zero)
        wantsLayer = true
        diff.hostRootView = self

        for view in [conflictBanner, saveErrorBar, controls, controlsSkeleton, placeholder, skeleton] {
            addSubview(view)
        }

        controls.onLayoutStyleChange = { [weak self] style in
            self?.rememberScrollAnchor()
            self?.diff.setLayoutStyle(style)
        }
        controls.onEditingChange = { [weak self] editing in
            self?.rememberScrollAnchor()
            self?.diff.setEditing(editing)
        }

        // Coalesced re-render on any model change. objectWillChange fires
        // before values update, so hop to the next runloop turn.
        diff.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleRender()
            }
            .store(in: &subscriptions)

        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Base text color is baked per appearance; rebuild the documents when
        // light/dark actually flips (this callback also fires spuriously).
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        diff.refreshDisplayForAppearance(dark: dark)
    }

    // MARK: Layout

    private enum Metrics {
        static let bannerHeight: CGFloat = 28
        static let controlsHeight: CGFloat = 37
    }

    /// Layer colors resolve against the *current drawing appearance*, so they
    /// belong in `updateLayer` — resolving them in layout/update paths bakes
    /// whichever appearance happened to be active (visible as a white
    /// controls bar after switching to dark).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.background.cgColor
    }

    override func layout() {
        super.layout()

        var y: CGFloat = 0
        let width = bounds.width

        func place(_ view: NSView, height: CGFloat) {
            view.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }

        if !conflictBanner.isHidden {
            place(conflictBanner, height: Metrics.bannerHeight)
        }
        if !saveErrorBar.isHidden {
            place(saveErrorBar, height: Metrics.bannerHeight)
        }
        if !controls.isHidden {
            place(controls, height: Metrics.controlsHeight)
        } else if !controlsSkeleton.isHidden {
            place(controlsSkeleton, height: Metrics.controlsHeight)
        }

        let contentFrame = CGRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        placeholder.frame = contentFrame
        skeleton.frame = contentFrame
        unifiedPane?.frame = contentFrame
        editPane?.frame = contentFrame
        if let leftPane, let rightPane, let splitDivider {
            let leftWidth = floor((contentFrame.width - 1) / 2)
            leftPane.frame = CGRect(
                x: 0, y: contentFrame.minY, width: leftWidth, height: contentFrame.height
            )
            splitDivider.frame = CGRect(
                x: leftWidth, y: contentFrame.minY, width: 1, height: contentFrame.height
            )
            rightPane.frame = CGRect(
                x: leftWidth + 1, y: contentFrame.minY,
                width: contentFrame.width - leftWidth - 1, height: contentFrame.height
            )
        }
    }

    override var isFlipped: Bool { true }

    // MARK: Rendering

    private func render() {
        conflictBanner.isHidden = !diff.isUnmerged
        if let saveError = diff.saveError {
            saveErrorBar.text = String(localized: "Could not save: \(saveError)")
            saveErrorBar.isHidden = false
        } else {
            saveErrorBar.isHidden = true
        }

        enum Content {
            case placeholder(icon: String, text: String)
            case skeleton(withControls: Bool)
            case review
            case edit
        }

        let content: Content
        if let error = diff.error {
            content = .placeholder(icon: "exclamationmark.triangle", text: error)
        } else if !diff.hasChanges {
            if diff.isLoading {
                content = .skeleton(withControls: false)
            } else if diff.isUnmerged {
                content = .placeholder(
                    icon: "arrow.triangle.merge",
                    text: String(localized: "Conflict is still unresolved")
                )
            } else {
                content = .placeholder(
                    icon: "checkmark.circle", text: String(localized: "No changes")
                )
            }
        } else if diff.isEditing, diff.isEditable {
            content = .edit
        } else if diff.display != nil {
            content = .review
        } else {
            content = .skeleton(withControls: true)
        }

        var showControls = false
        var showControlsSkeleton = false
        var showPlaceholder = false
        var showSkeleton = false
        var showUnified = false
        var showSplit = false
        var showEdit = false

        switch content {
        case .placeholder(let icon, let text):
            showPlaceholder = true
            placeholder.show(icon: icon, text: text)
        case .skeleton(let withControls):
            showSkeleton = true
            if withControls {
                showControls = true
            } else {
                showControlsSkeleton = true
                controlsSkeleton.update(
                    showsModePlaceholder: diff.commitHash == nil && !diff.staged
                )
            }
        case .review:
            showControls = true
            if diff.layoutStyle == .split {
                showSplit = true
                renderSplit()
            } else {
                showUnified = true
                renderUnified()
            }
        case .edit:
            showControls = true
            showEdit = true
            renderEdit()
        }

        controls.isHidden = !showControls
        controlsSkeleton.isHidden = !showControlsSkeleton
        placeholder.isHidden = !showPlaceholder
        skeleton.isHidden = !showSkeleton
        unifiedPane?.isHidden = !showUnified
        leftPane?.isHidden = !showSplit
        rightPane?.isHidden = !showSplit
        splitDivider?.isHidden = !showSplit
        editPane?.isHidden = !showEdit

        // A pane leaving the screen takes its find bar and match overlays
        // with it (layout/mode switches would otherwise strand them).
        if !showUnified { hideFindInterface(on: unifiedPane) }
        if !showSplit {
            hideFindInterface(on: leftPane)
            hideFindInterface(on: rightPane)
        }
        if !showEdit { hideFindInterface(on: editPane) }

        if showControls {
            controls.update(
                layoutStyle: diff.layoutStyle,
                isEditing: diff.isEditing,
                canEdit: diff.isEditable
            )
        }

        needsLayout = true
    }

    private func typography() -> (font: NSFont, style: NSParagraphStyle, palette: EditorPalette) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = TerminalFont.current()
        return (font, DiffTypography.paragraphStyle(for: font), EditorPalette.theme(dark: dark))
    }

    private func makePane(mode: DiffCodePaneView.Mode, gutter: DiffGutterLayout) -> DiffCodePaneView {
        let pane = DiffCodePaneView(mode: mode, gutterLayout: gutter)
        pane.onFocus = { [weak self, weak pane] in
            self?.focusedTextView = pane?.textView
        }
        pane.onExpandCollapsedRun = { [weak self] fold in
            self?.diff.expandRun(fold)
        }
        addSubview(pane)
        return pane
    }

    private func renderUnified() {
        guard let display = diff.display else { return }
        let pane: DiffCodePaneView
        if let existing = unifiedPane {
            pane = existing
        } else {
            pane = makePane(mode: .review, gutter: .single)
            unifiedPane = pane
        }
        applyReviewDocument(
            display.unifiedText,
            decorations: .review(display.computation.unified),
            to: pane,
            displayID: display.id
        )
        restoreScrollAnchorIfNeeded(to: pane, rows: display.computation.unified.rows)
    }

    private func renderSplit() {
        guard let display = diff.display else { return }
        let left: DiffCodePaneView
        let right: DiffCodePaneView
        if let existingLeft = leftPane, let existingRight = rightPane {
            left = existingLeft
            right = existingRight
        } else {
            left = makePane(mode: .review, gutter: .oldOnly)
            right = makePane(mode: .review, gutter: .newOnly)
            leftPane = left
            rightPane = right
            let divider = DiffThemedDividerView()
            addSubview(divider)
            splitDivider = divider
            left.onVerticalScroll = { [weak right] y in
                right?.setVerticalScrollOffset(y)
            }
            right.onVerticalScroll = { [weak left] y in
                left?.setVerticalScrollOffset(y)
            }
        }
        applyReviewDocument(
            display.leftText,
            decorations: .review(display.computation.splitLeft),
            to: left,
            displayID: display.id
        )
        applyReviewDocument(
            display.rightText,
            decorations: .review(display.computation.splitRight),
            to: right,
            displayID: display.id
        )
        restoreScrollAnchorIfNeeded(to: right, rows: display.computation.splitRight.rows)
        if let anchorOffset = rightPane?.verticalScrollOffset {
            leftPane?.setVerticalScrollOffset(anchorOffset)
        }
    }

    /// Applies a review document to a pane unless it already shows it.
    /// Typography is reapplied every time (guarded setters make that cheap);
    /// the document swap and decoration rebuild only run for a new display.
    private func applyReviewDocument(
        _ text: NSAttributedString,
        decorations: @autoclosure () -> DiffDecorations,
        to pane: DiffCodePaneView,
        displayID: UUID
    ) {
        let (font, style, palette) = typography()
        pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text)
        if pane.renderedDisplayID != displayID {
            pane.renderedDisplayID = displayID
            // The pane re-anchors the swap to the file line the user was
            // reading, so fold expansion and reloads don't move the content
            // under the viewport.
            pane.setReviewDocument(text, decorations: decorations())
        }
    }

    private func renderEdit() {
        let pane: DiffCodePaneView
        var isNewPane = false
        if let existing = editPane {
            pane = existing
        } else {
            pane = makePane(mode: .edit, gutter: .single)
            editPane = pane
            pane.textView.textDelegate = self
            isNewPane = true
        }
        let (font, style, palette) = typography()
        pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text)
        pane.textView.insertionPointColor = palette.insertionPoint

        // Reset the buffer when a reload replaced the content while the pane
        // wasn't editing; while the user types, the text view itself is the
        // source of truth and must not be overwritten.
        if renderedEditRevision != diff.editBufferRevision {
            renderedEditRevision = diff.editBufferRevision
            pane.setEditBufferText(diff.editedNewContent)
            if isNewPane {
                // Tree-sitter highlighting, attached after the text is set so
                // the plugin's initial full-document parse sees the whole
                // document. Attached once — plugins can't detach, which is
                // also why review panes are separate views.
                if let plugin = SyntaxHighlighting.plugin(for: diff.path) {
                    pane.textView.addPlugin(plugin)
                }
            }
        }
        pane.decorations = diff.editDecorations
        if let anchor = pendingScrollAnchor, let newLine = anchor.newLine {
            pendingScrollAnchor = nil
            pane.scrollToRow(newLine - 1)
        }
    }

    // MARK: Mode/layout switch scroll continuity

    /// The first visible row's file position, captured right before a layout
    /// or mode switch and applied to the newly shown pane.
    private var pendingScrollAnchor: (oldLine: Int?, newLine: Int?)?

    private func rememberScrollAnchor() {
        guard diff.hasChanges else { return }
        if diff.isEditing, let pane = editPane {
            if let index = pane.firstVisibleRowIndex {
                pendingScrollAnchor = (nil, index + 1)
            }
            return
        }
        let activePane = diff.layoutStyle == .split ? rightPane : unifiedPane
        guard let pane = activePane, let display = diff.display,
              let index = pane.firstVisibleRowIndex
        else { return }
        let rows = diff.layoutStyle == .split
            ? display.computation.splitRight.rows
            : display.computation.unified.rows
        guard index < rows.count else { return }
        // Walk forward to the nearest row with a concrete file line.
        for row in rows[index...] {
            if row.newLine != nil || row.oldLine != nil {
                pendingScrollAnchor = (row.oldLine, row.newLine)
                return
            }
        }
    }

    private func restoreScrollAnchorIfNeeded(to pane: DiffCodePaneView, rows: [DiffRow]) {
        guard let anchor = pendingScrollAnchor else { return }
        pendingScrollAnchor = nil
        let target = rows.firstIndex { row in
            if let newLine = anchor.newLine, let rowNew = row.newLine {
                return rowNew >= newLine
            }
            if let oldLine = anchor.oldLine, let rowOld = row.oldLine {
                return rowOld >= oldLine
            }
            return false
        }
        if let target {
            pane.scrollToRow(target)
        }
    }

    // MARK: Find

    func performFindAction(_ action: FindAction) {
        // A remembered side can be stale after a layout or mode switch hid it.
        var target = focusedTextView
        if target == nil || target?.window == nil || target?.isHiddenOrHasHiddenAncestor == true {
            target = activeDefaultTextView()
        }
        guard let target else { return }
        let finderAction: NSTextFinder.Action =
            switch action {
            case .show: .showFindInterface
            case .replace: .showReplaceInterface
            case .hide: .hideFindInterface
            case .next: .nextMatch
            case .previous: .previousMatch
            case .useSelection: .setSearchString
            }
        guard target.textFinder.validateAction(finderAction) else { return }
        target.textFinder.performAction(finderAction)
    }

    private func activeDefaultTextView() -> STTextView? {
        if diff.isEditing, diff.isEditable { return editPane?.textView }
        if diff.layoutStyle == .split { return rightPane?.textView }
        return unifiedPane?.textView
    }

    // MARK: STTextViewDelegate (edit pane)

    func textViewDidChangeText(_ notification: Notification) {
        guard let textView = editPane?.textView,
              (notification.object as? STTextView) === textView
        else { return }
        diff.updateEditedContent(textView.text ?? "")
    }
}

// MARK: - Chrome views

/// 1-pixel divider that keeps its theme color correct across appearance
/// switches by resolving it in `updateLayer`.
private final class DiffThemedDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.divider.cgColor
    }
}

/// Thin colored strip with an icon and message (conflict banner, save error).
private final class DiffBannerView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let tint: NSColor

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(icon: String, text: String, detail: String?, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(
            systemSymbolName: icon, accessibilityDescription: nil
        )
        iconView.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        iconView.contentTintColor = tint

        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail

        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail == nil

        for view in [iconView, label, detailLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8
            ),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.1).setFill()
        bounds.fill()
        // Hairline on the banner's visual bottom edge (y = 0: not flipped).
        tint.withAlphaComponent(0.22).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Centered icon + message for error/empty states.
private final class DiffPlaceholderView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.symbolConfiguration = .init(pointSize: 24, weight: .light)
        iconView.contentTintColor = .quaternaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        for view in [iconView, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(icon: String, text: String) {
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        label.stringValue = text
    }
}

/// Code-shaped gray bars shown while the diff content loads, so opening a
/// diff never flashes an empty pane.
private final class DiffSkeletonNSView: NSView {
    /// (indent level, width fraction) per line, repeated to fill the pane.
    private static let pattern: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.42), (1, 0.62), (1, 0.30), (1, 0.55),
        (2, 0.38), (2, 0.50), (1, 0.24), (0, 0.16),
    ]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        var y: CGFloat = 16
        var index = 0
        while y < bounds.height {
            let line = Self.pattern[index % Self.pattern.count]
            let rect = CGRect(
                x: 16 + line.indent * 18,
                y: y,
                width: bounds.width * line.width * 0.55,
                height: 9
            )
            if rect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            y += 18
            index += 1
        }
    }
}

/// Native segmented controls for the diff toolbar.
final class DiffControlsNSView: NSView {
    private let modeControl = NSSegmentedControl(
        labels: [
            String(localized: "Review", comment: "Read-only mode for a diff."),
            String(localized: "Edit", comment: "Editable mode for a diff."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let layoutControl = NSSegmentedControl(
        labels: [
            String(localized: "Unified", comment: "A single-column diff layout."),
            String(localized: "Split", comment: "A side-by-side diff layout."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let divider = DiffThemedDividerView()
    var onLayoutStyleChange: ((DiffLayoutStyle) -> Void)?
    var onEditingChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for control in [modeControl, layoutControl] {
            control.controlSize = .small
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(String(localized: "Diff Mode"))
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.setAccessibilityLabel(String(localized: "Diff Layout"))

        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeControl.trailingAnchor.constraint(equalTo: layoutControl.leadingAnchor, constant: -8),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.background.cgColor
    }

    func update(layoutStyle: DiffLayoutStyle, isEditing: Bool, canEdit: Bool) {
        layoutControl.selectedSegment = layoutStyle == .split ? 1 : 0
        // The layout choice doesn't apply while editing (the editor is a
        // single buffer); keep it visible but disabled.
        layoutControl.isEnabled = !isEditing
        modeControl.isHidden = !canEdit
        modeControl.setEnabled(canEdit, forSegment: 1)
        modeControl.selectedSegment = canEdit && isEditing ? 1 : 0
    }

    @objc private func modeChanged() {
        onEditingChange?(modeControl.selectedSegment == 1)
    }

    @objc private func layoutChanged() {
        onLayoutStyleChange?(layoutControl.selectedSegment == 1 ? .split : .unified)
    }
}

/// Matches the native controls row while the diff metadata is still loading.
final class DiffControlsSkeletonNSView: NSView {
    /// Rounded gray bar standing in for a segmented control; draws (rather
    /// than sets a layer color) so its fill follows appearance switches.
    private final class PlaceholderBar: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }

    private let modePlaceholder = PlaceholderBar()
    private let layoutPlaceholder = PlaceholderBar()
    private let divider = DiffThemedDividerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        for placeholder in [modePlaceholder, layoutPlaceholder] {
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholder)
        }

        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutPlaceholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutPlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutPlaceholder.widthAnchor.constraint(equalToConstant: 111),
            layoutPlaceholder.heightAnchor.constraint(equalToConstant: 20),
            modePlaceholder.trailingAnchor.constraint(
                equalTo: layoutPlaceholder.leadingAnchor, constant: -8
            ),
            modePlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            modePlaceholder.widthAnchor.constraint(equalToConstant: 93),
            modePlaceholder.heightAnchor.constraint(equalToConstant: 20),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.background.cgColor
    }

    func update(showsModePlaceholder: Bool) {
        modePlaceholder.isHidden = !showsModePlaceholder
    }
}

// MARK: - SwiftUI bridge

/// Mount point used by ContentView's (legacy SwiftUI) tab stack; everything
/// on screen is the AppKit `DiffRootView`.
struct DiffViewerView: NSViewRepresentable {
    let diff: DiffTab
    /// The view stays mounted while other tabs are selected (see
    /// ContentView); this flags when it is the frontmost tab so content
    /// refreshes on each re-visit, not just on first mount.
    var isSelected: Bool = true

    init(diff: DiffTab, isSelected: Bool = true) {
        self.diff = diff
        self.isSelected = isSelected
    }

    func makeNSView(context: Context) -> DiffRootView {
        let view = DiffRootView(diff: diff)
        view.isSelectedTab = isSelected
        return view
    }

    func updateNSView(_ view: DiffRootView, context: Context) {
        view.isSelectedTab = isSelected
    }

    /// Fill whatever space SwiftUI proposes (see SourceTextEditor for why
    /// reporting an intrinsic size here would be harmful).
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: DiffRootView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }
}

