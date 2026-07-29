import SwiftUI

enum TerminalProjectPanel: String, CaseIterable, Identifiable {
    case files = "Files"
    case git = "Git"

    var id: Self { self }
}

struct TerminalProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var project: RemoteProjectModel
    @State private var selectedPanel: TerminalProjectPanel

    init(
        session: TerminalSessionModel,
        initialPanel: TerminalProjectPanel
    ) {
        _project = ObservedObject(wrappedValue: session.remoteProject)
        _selectedPanel = State(initialValue: initialPanel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Project panel", selection: $selectedPanel) {
                    ForEach(TerminalProjectPanel.allCases) { panel in
                        Text(panel.rawValue).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("project-panel-picker")
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch selectedPanel {
                case .files:
                    RemoteFilesView(project: project)
                case .git:
                    RemoteGitView(project: project)
                }
            }
            .navigationTitle(project.projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .disabled(
                        project.isLoadingFiles
                            || project.isLoadingGit
                            || project.isRunningGitAction
                    )
                }
            }
        }
        .task(id: selectedPanel) {
            switch selectedPanel {
            case .files where project.files.isEmpty:
                await project.refreshFiles()
            case .git where !project.hasLoadedGit:
                await project.refreshGit()
            default:
                break
            }
        }
    }

    private func refresh() {
        Task {
            switch selectedPanel {
            case .files:
                await project.refreshFiles()
            case .git:
                await project.refreshGit()
            }
        }
    }
}

private struct RemoteFilesView: View {
    @ObservedObject var project: RemoteProjectModel

    var body: some View {
        Group {
            if project.isLoadingFiles && project.files.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if project.files.isEmpty {
                ContentUnavailableView {
                    Label(
                        project.filesError == nil
                            ? "No Files"
                            : "Couldn’t Load Files",
                        systemImage: project.filesError == nil
                            ? "folder"
                            : "folder.badge.questionmark"
                    )
                } description: {
                    Text(
                        project.filesError
                            ?? "This project directory is empty."
                    )
                } actions: {
                    Button("Try Again") {
                        Task {
                            await project.refreshFiles()
                        }
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(project.files) { item in
                            RemoteFileRow(
                                project: project,
                                item: item
                            )
                        }
                    } header: {
                        if let root = project.projectRoot {
                            Label(root, systemImage: "folder")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textCase(nil)
                                .accessibilityIdentifier(
                                    "remote-project-root"
                                )
                        }
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .top) {
                    if project.isLoadingFiles {
                        ProgressView()
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
        }
    }
}

private struct RemoteFileRow: View {
    @ObservedObject var project: RemoteProjectModel
    let item: RemoteFileItem

    var body: some View {
        Group {
            if item.isDirectory {
                Button {
                    Task {
                        await project.toggleDirectory(item)
                    }
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    RemoteFilePreviewView(
                        project: project,
                        item: item
                    )
                } label: {
                    rowLabel
                }
            }
        }
        .accessibilityIdentifier("remote-file-\(item.path)")
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(item.depth) * 16)

            if item.isDirectory {
                Image(
                    systemName: project.isExpanded(item)
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }

            Image(
                systemName: item.isDirectory
                    ? "folder.fill"
                    : fileSymbol
            )
            .foregroundStyle(item.isDirectory ? .blue : .secondary)
            .frame(width: 20)

            Text(item.name)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var fileSymbol: String {
        switch (item.name as NSString).pathExtension.lowercased() {
        case "swift":
            "swift"
        case "md", "txt":
            "doc.text"
        case "json", "yaml", "yml", "toml":
            "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp":
            "photo"
        default:
            "doc"
        }
    }
}

private struct RemoteFilePreviewView: View {
    @ObservedObject var project: RemoteProjectModel
    let item: RemoteFileItem

    @State private var contents: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let contents {
                ScrollView([.horizontal, .vertical]) {
                    Text(contents.isEmpty ? "This file is empty." : contents)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                        .padding()
                }
                .privacySensitive()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t Open File",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading \(item.name)…")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                contents = try await project.loadFile(item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RemoteGitView: View {
    @ObservedObject var project: RemoteProjectModel

    var body: some View {
        Group {
            if project.isLoadingGit && project.git == nil {
                ProgressView("Loading Git status…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let git = project.git {
                gitList(git)
            } else if project.canInitializeGit {
                ContentUnavailableView {
                    Label(
                        "No Git Repository",
                        systemImage: "arrow.triangle.branch"
                    )
                } description: {
                    VStack(spacing: 8) {
                        Text(
                            "Initialize the terminal’s current directory "
                                + "to start tracking changes."
                        )
                        if let error = project.gitError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } actions: {
                    Button("Initialize Repository") {
                        Task {
                            await project.initializeRepository()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(project.isRunningGitAction)
                    .accessibilityIdentifier("initialize-git-repository")
                }
            } else {
                ContentUnavailableView {
                    Label(
                        "Couldn’t Load Git",
                        systemImage: "arrow.triangle.branch"
                    )
                } description: {
                    Text(
                        project.gitError
                            ?? "The remote Git status could not be loaded."
                    )
                } actions: {
                    Button("Try Again") {
                        Task {
                            await project.refreshGit()
                        }
                    }
                }
            }
        }
    }

    private func gitList(_ git: RemoteGitSnapshot) -> some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Label(git.branch, systemImage: "arrow.triangle.branch")
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if git.ahead > 0 {
                        Label(
                            "\(git.ahead)",
                            systemImage: "arrow.up"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if git.behind > 0 {
                        Label(
                            "\(git.behind)",
                            systemImage: "arrow.down"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let upstream = git.upstream {
                    Text(upstream)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if git.entries.isEmpty {
                Section {
                    Label(
                        "Working tree clean",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            }

            gitSection(
                "Conflicts",
                entries: git.conflicts,
                staged: false,
                tint: .red
            )
            gitSection(
                "Staged",
                entries: git.staged,
                staged: true,
                tint: .green
            )
            gitSection(
                "Changes",
                entries: git.changed,
                staged: false,
                tint: .orange
            )
        }
        .listStyle(.insetGrouped)
        .overlay {
            if project.isRunningGitAction {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = project.gitError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private func gitSection(
        _ title: String,
        entries: [RemoteGitEntry],
        staged: Bool,
        tint: Color
    ) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    NavigationLink {
                        RemoteGitDiffView(
                            project: project,
                            entry: entry,
                            staged: staged
                        )
                    } label: {
                        RemoteGitEntryLabel(
                            entry: entry,
                            staged: staged,
                            tint: tint
                        )
                    }
                    .accessibilityIdentifier(
                        "remote-git-\(staged ? "staged" : "changed")-\(entry.path)"
                    )
                    .swipeActions(
                        edge: .trailing,
                        allowsFullSwipe: true
                    ) {
                        if staged {
                            Button("Unstage", systemImage: "minus") {
                                Task {
                                    await project.unstage(entry)
                                }
                            }
                            .tint(.orange)
                        } else {
                            Button("Stage", systemImage: "plus") {
                                Task {
                                    await project.stage(entry)
                                }
                            }
                            .tint(.green)
                        }
                    }
                }
            }
        }
    }
}

private struct RemoteGitEntryLabel: View {
    let entry: RemoteGitEntry
    let staged: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.directory.isEmpty {
                    Text(entry.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var status: String {
        let value = staged ? entry.stagedStatus : entry.worktreeStatus
        return value == "?" ? "U" : String(value)
    }
}

private struct RemoteGitDiffView: View {
    @ObservedObject var project: RemoteProjectModel
    let entry: RemoteGitEntry
    let staged: Bool

    @State private var diff: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let diff {
                ScrollView([.horizontal, .vertical]) {
                    Text(
                        diff.isEmpty
                            ? "No textual diff is available for this file."
                            : diff
                    )
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .padding()
                }
                .privacySensitive()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Diff",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading diff…")
            }
        }
        .navigationTitle(entry.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                diff = try await project.loadDiff(
                    for: entry,
                    staged: staged
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
