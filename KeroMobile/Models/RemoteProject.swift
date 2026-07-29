import Combine
import Foundation

struct RemoteFileItem: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
    let depth: Int
}

struct RemoteGitEntry: Identifiable, Equatable, Sendable {
    var id: String { path }

    let path: String
    let stagedStatus: Character
    let worktreeStatus: Character

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    var isConflict: Bool {
        stagedStatus == "U"
            || worktreeStatus == "U"
            || (stagedStatus == "A" && worktreeStatus == "A")
            || (stagedStatus == "D" && worktreeStatus == "D")
    }

    var isStaged: Bool {
        stagedStatus != "." && stagedStatus != "?"
    }

    var hasWorktreeChange: Bool {
        worktreeStatus != "." || stagedStatus == "?"
    }
}

struct RemoteGitSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let entries: [RemoteGitEntry]

    var conflicts: [RemoteGitEntry] {
        entries.filter(\.isConflict)
    }

    var staged: [RemoteGitEntry] {
        entries.filter { $0.isStaged && !$0.isConflict }
    }

    var changed: [RemoteGitEntry] {
        entries.filter { $0.hasWorktreeChange && !$0.isConflict }
    }
}

enum RemoteProjectError: LocalizedError {
    case invalidDirectory
    case commandFailed(String)
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "The remote shell did not report a project directory."
        case .commandFailed(let message):
            message.isEmpty ? "The remote command failed." : message
        case .binaryFile:
            "This file appears to be binary and can’t be previewed as text."
        }
    }
}

@MainActor
final class RemoteProjectModel: ObservableObject {
    typealias Executor = @MainActor (String) async throws -> SSHCommandResult

    @Published private(set) var workingDirectory: String?
    @Published private(set) var projectRoot: String?
    @Published private(set) var files: [RemoteFileItem] = []
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var filesError: String?
    @Published private(set) var git: RemoteGitSnapshot?
    @Published private(set) var hasLoadedGit = false
    @Published private(set) var canInitializeGit = false
    @Published private(set) var isLoadingGit = false
    @Published private(set) var gitError: String?
    @Published private(set) var isRunningGitAction = false

    private struct FileNode: Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
    }

    private let execute: Executor
    private var childrenByDirectory: [String: [FileNode]] = [:]
    private var expandedDirectories: Set<String> = []
    private var contextGeneration: UInt = 0
    private var contextTask: Task<Void, Never>?

    init(execute: @escaping Executor) {
        self.execute = execute
    }

    var projectName: String {
        guard let projectRoot else {
            return "Project"
        }
        let name = (projectRoot as NSString).lastPathComponent
        return name.isEmpty ? projectRoot : name
    }

    func setWorkingDirectory(_ rawValue: String?) {
        guard let directory = Self.normalizedDirectory(rawValue),
              directory != workingDirectory else {
            return
        }
        workingDirectory = directory
        beginResolvingContext(for: directory)
    }

    func discoverInitialDirectory() async {
        if workingDirectory == nil {
            do {
                let result = try await execute("pwd -P")
                guard result.exitStatus == 0 else {
                    throw Self.commandError(result)
                }
                setWorkingDirectory(result.stdoutString)
            } catch {
                filesError = error.localizedDescription
                gitError = error.localizedDescription
            }
        } else if projectRoot == nil, let workingDirectory {
            beginResolvingContext(for: workingDirectory)
        }
        await waitForContext()
    }

    func refreshFiles() async {
        await ensureContext()
        guard let projectRoot else {
            filesError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }
        await loadChildren(of: projectRoot, replacingRoot: true)
    }

    func toggleDirectory(_ item: RemoteFileItem) async {
        guard item.isDirectory else {
            return
        }
        if expandedDirectories.remove(item.path) != nil {
            rebuildVisibleFiles()
            return
        }
        expandedDirectories.insert(item.path)
        if childrenByDirectory[item.path] == nil {
            await loadChildren(of: item.path, replacingRoot: false)
        } else {
            rebuildVisibleFiles()
        }
    }

    func isExpanded(_ item: RemoteFileItem) -> Bool {
        expandedDirectories.contains(item.path)
    }

    func loadFile(_ item: RemoteFileItem) async throws -> String {
        guard !item.isDirectory else {
            return ""
        }
        let result = try await execute(
            "LC_ALL=C head -c 262144 -- \(Self.shellQuote(item.path))"
        )
        guard result.exitStatus == 0 else {
            throw Self.commandError(result)
        }
        guard !result.stdout.contains(0) else {
            throw RemoteProjectError.binaryFile
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func refreshGit() async {
        await ensureContext()
        guard let projectRoot else {
            git = nil
            hasLoadedGit = true
            canInitializeGit = false
            gitError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }

        isLoadingGit = true
        gitError = nil
        canInitializeGit = false
        defer {
            isLoadingGit = false
            hasLoadedGit = true
        }
        do {
            let result = try await execute(
                "env LC_ALL=C git -C \(Self.shellQuote(projectRoot)) "
                    + "status --porcelain=v2 --branch -z --untracked-files=all"
            )
            guard result.exitStatus == 0 else {
                git = nil
                if Self.isMissingRepository(result) {
                    canInitializeGit = true
                    return
                }
                throw Self.commandError(result)
            }
            git = Self.parseGitStatus(
                result.stdout,
                repositoryRoot: projectRoot
            )
        } catch {
            git = nil
            canInitializeGit = false
            gitError = error.localizedDescription
        }
    }

    func initializeRepository() async {
        guard let projectRoot else {
            gitError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }
        isRunningGitAction = true
        gitError = nil
        defer { isRunningGitAction = false }
        do {
            let result = try await execute(
                "git -C \(Self.shellQuote(projectRoot)) init"
            )
            guard result.exitStatus == 0 else {
                throw Self.commandError(result)
            }
            canInitializeGit = false
            await refreshGit()
        } catch {
            canInitializeGit = true
            gitError = error.localizedDescription
        }
    }

    func stage(_ entry: RemoteGitEntry) async {
        await runGitAction(
            arguments: "--literal-pathspecs add -- \(Self.shellQuote(entry.path))"
        )
    }

    func unstage(_ entry: RemoteGitEntry) async {
        await runGitAction(
            arguments: "--literal-pathspecs restore --staged -- "
                + Self.shellQuote(entry.path)
        )
    }

    func loadDiff(
        for entry: RemoteGitEntry,
        staged: Bool
    ) async throws -> String {
        guard let root = git?.repositoryRoot ?? projectRoot else {
            throw RemoteProjectError.invalidDirectory
        }
        let cached = staged ? "--cached " : ""
        let result = try await execute(
            "git -C \(Self.shellQuote(root)) diff --no-ext-diff --no-color "
                + cached + "-- \(Self.shellQuote(entry.path))"
        )
        guard result.exitStatus == 0 else {
            throw Self.commandError(result)
        }
        return result.stdoutString
    }

    #if DEBUG
    func installPreview(
        root: String,
        files: [RemoteFileItem],
        git: RemoteGitSnapshot?
    ) {
        contextTask?.cancel()
        workingDirectory = root
        projectRoot = root
        self.files = files
        self.git = git
        hasLoadedGit = true
        canInitializeGit = git == nil
        gitError = nil
    }
    #endif

    private func beginResolvingContext(for directory: String) {
        contextTask?.cancel()
        contextGeneration &+= 1
        let generation = contextGeneration
        contextTask = Task { [weak self] in
            guard let self else {
                return
            }
            let resolvedRoot: String
            do {
                let result = try await execute(
                    "git -C \(Self.shellQuote(directory)) "
                        + "rev-parse --show-toplevel 2>/dev/null"
                )
                if result.exitStatus == 0,
                   let value = Self.normalizedDirectory(
                       result.stdoutString
                   ) {
                    resolvedRoot = value
                } else {
                    resolvedRoot = directory
                }
            } catch {
                resolvedRoot = directory
            }
            guard !Task.isCancelled,
                  contextGeneration == generation else {
                return
            }
            applyProjectRoot(resolvedRoot)
            contextTask = nil
        }
    }

    private func applyProjectRoot(_ root: String) {
        guard root != projectRoot else {
            return
        }
        projectRoot = root
        files = []
        filesError = nil
        childrenByDirectory = [:]
        expandedDirectories = []
        git = nil
        hasLoadedGit = false
        canInitializeGit = false
        gitError = nil
    }

    private func waitForContext() async {
        await contextTask?.value
    }

    private func ensureContext() async {
        await discoverInitialDirectory()
        await waitForContext()
    }

    private func loadChildren(
        of directory: String,
        replacingRoot: Bool
    ) async {
        isLoadingFiles = true
        filesError = nil
        defer { isLoadingFiles = false }
        do {
            let result = try await execute(
                Self.directoryListingCommand(directory)
            )
            guard result.exitStatus == 0 else {
                throw Self.commandError(result)
            }
            childrenByDirectory[directory] = Self.parseDirectoryListing(
                result.stdout,
                parent: directory
            )
            if replacingRoot {
                expandedDirectories = []
            }
            rebuildVisibleFiles()
        } catch {
            filesError = error.localizedDescription
            rebuildVisibleFiles()
        }
    }

    private func rebuildVisibleFiles() {
        guard let projectRoot else {
            files = []
            return
        }
        var result: [RemoteFileItem] = []
        appendChildren(
            of: projectRoot,
            depth: 0,
            result: &result
        )
        files = result
    }

    private func appendChildren(
        of directory: String,
        depth: Int,
        result: inout [RemoteFileItem]
    ) {
        guard depth < 32,
              let children = childrenByDirectory[directory] else {
            return
        }
        for child in children {
            let item = RemoteFileItem(
                name: child.name,
                path: child.path,
                isDirectory: child.isDirectory,
                depth: depth
            )
            result.append(item)
            if child.isDirectory,
               expandedDirectories.contains(child.path) {
                appendChildren(
                    of: child.path,
                    depth: depth + 1,
                    result: &result
                )
            }
        }
    }

    private func runGitAction(arguments: String) async {
        guard let root = git?.repositoryRoot ?? projectRoot else {
            gitError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }
        isRunningGitAction = true
        gitError = nil
        defer { isRunningGitAction = false }
        do {
            let result = try await execute(
                "git -C \(Self.shellQuote(root)) \(arguments)"
            )
            guard result.exitStatus == 0 else {
                throw Self.commandError(result)
            }
            await refreshGit()
        } catch {
            gitError = error.localizedDescription
        }
    }

    private static func directoryListingCommand(_ directory: String) -> String {
        let script = """
        dir=$1
        for p in "$dir"/.[!.]* "$dir"/..?* "$dir"/*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          name=${p##*/}
          [ "$name" = ".git" ] && continue
          if [ -d "$p" ] && [ ! -L "$p" ]; then kind=d; else kind=f; fi
          printf '%s\\0%s\\0' "$kind" "$name"
        done
        """
        // SSH exec requests are interpreted by the account's login shell.
        // Run this POSIX script explicitly so fish and other non-POSIX shells
        // never have to parse its assignments or parameter expansion.
        return "/bin/sh -c \(shellQuote(script)) sh \(shellQuote(directory))"
    }

    private static func parseDirectoryListing(
        _ data: Data,
        parent: String
    ) -> [FileNode] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var nodes: [FileNode] = []
        var index = 0
        while index + 1 < fields.count {
            let kind = String(decoding: fields[index], as: UTF8.self)
            let name = String(decoding: fields[index + 1], as: UTF8.self)
            index += 2
            guard !name.isEmpty, name != ".git" else {
                continue
            }
            let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
            nodes.append(
                FileNode(
                    name: name,
                    path: path,
                    isDirectory: kind == "d"
                )
            )
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func parseGitStatus(
        _ data: Data,
        repositoryRoot: String
    ) -> RemoteGitSnapshot {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var branch = "Detached HEAD"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [RemoteGitEntry] = []
        var skipRenameSource = false

        for bytes in records {
            if skipRenameSource {
                skipRenameSource = false
                continue
            }
            let record = String(decoding: bytes, as: UTF8.self)
            if record.hasPrefix("# branch.head ") {
                branch = String(record.dropFirst("# branch.head ".count))
                if branch == "(detached)" {
                    branch = "Detached HEAD"
                }
                continue
            }
            if record.hasPrefix("# branch.upstream ") {
                upstream = String(
                    record.dropFirst("# branch.upstream ".count)
                )
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let values = record.split(separator: " ")
                if values.count >= 4 {
                    ahead = Int(values[2].dropFirst()) ?? 0
                    behind = Int(values[3].dropFirst()) ?? 0
                }
                continue
            }

            let parsed: (Character, Character, String)?
            if record.hasPrefix("1 ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 8,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 9
                    ? statusEntry(xy: values[1], path: values[8])
                    : nil
            } else if record.hasPrefix("2 ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 9,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 10
                    ? statusEntry(xy: values[1], path: values[9])
                    : nil
                skipRenameSource = true
            } else if record.hasPrefix("u ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 10,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 11
                    ? statusEntry(xy: values[1], path: values[10])
                    : nil
            } else if record.hasPrefix("? ") {
                parsed = ("?", ".", String(record.dropFirst(2)))
            } else {
                parsed = nil
            }

            if let parsed {
                entries.append(
                    RemoteGitEntry(
                        path: parsed.2,
                        stagedStatus: parsed.0,
                        worktreeStatus: parsed.1
                    )
                )
            }
        }

        entries.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return RemoteGitSnapshot(
            repositoryRoot: repositoryRoot,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            entries: entries
        )
    }

    private static func statusEntry(
        xy: Substring,
        path: Substring
    ) -> (Character, Character, String)? {
        guard xy.count >= 2 else {
            return nil
        }
        let characters = Array(xy)
        return (characters[0], characters[1], String(path))
    }

    private static func normalizedDirectory(_ rawValue: String?) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), url.isFileURL {
            return url.path
        }
        guard value.hasPrefix("/") else {
            return nil
        }
        return value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func commandError(
        _ result: SSHCommandResult
    ) -> RemoteProjectError {
        let message = result.stderrString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(message)
    }

    private static func isMissingRepository(
        _ result: SSHCommandResult
    ) -> Bool {
        guard result.exitStatus != 0 else {
            return false
        }
        let output = "\(result.stderrString)\n\(result.stdoutString)"
            .lowercased()
        return output.contains("not a git repository")
    }
}
