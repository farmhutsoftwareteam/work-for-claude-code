import SwiftUI
import AppKit

/// Single sheet with three modes for starting a new project in Work:
///
/// - **Open existing folder**: user picks a dir already on disk. We insert
///   it into `store.projects`, register it in `~/.claude.json`, and
///   optionally start a Claude session.
/// - **Clone from GitHub**: paste a repo URL, clone via `GitCloner`, then
///   treat the result as an "open existing folder" entry.
/// - **New empty folder**: pick a parent + a folder name, we create the dir,
///   register it, and optionally start a session.
///
/// All three flows land in the same end state: the project appears in the
/// sidebar, is persisted in `~/.claude.json`, and is ready for sessions.
struct AddProjectSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @Binding var isPresented: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case existing = "Open folder"
        case clone = "Clone"
        case new = "New folder"
        var id: Self { self }

        var icon: String {
            switch self {
            case .existing: return "folder.fill"
            case .clone:    return "arrow.triangle.branch"
            case .new:      return "folder.badge.plus"
            }
        }
    }

    @State private var mode: Mode = .existing

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Add Project")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }

            // Mode picker — segmented control, easy to scan
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Label(m.rawValue, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            // Mode content
            switch mode {
            case .existing:
                OpenExistingFolderTab(isPresented: $isPresented)
                    .environmentObject(store)
                    .environmentObject(terminals)
            case .clone:
                CloneFromGitHubTab(isPresented: $isPresented)
                    .environmentObject(store)
            case .new:
                CreateNewFolderTab(isPresented: $isPresented)
                    .environmentObject(store)
                    .environmentObject(terminals)
            }
        }
        .padding(22)
        .frame(width: 540)
        .animation(nil, value: mode)
    }
}

// MARK: - Shared helpers

/// Register a project path in `~/.claude.json`'s `projects` dict + insert
/// into `store.projects` so it appears in the sidebar immediately.
/// Idempotent — no-op if the path is already tracked.
@MainActor
private func registerProject(at path: String, store: Store) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return
    }

    let displayName = (path as NSString).lastPathComponent
    let project = Project(
        id: path,
        cwd: path,
        displayName: displayName,
        sessions: [],
        isActive: false
    )
    if !store.projects.contains(where: { $0.cwd == path }) {
        store.projects.insert(project, at: 0)
    }
    store.selectedProject = project

    // Append to ~/.claude.json so the project survives a Work restart even
    // before Claude writes any JSONL for it.
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")
    guard let data = try? Data(contentsOf: url),
          var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return
    }
    var projects = (root["projects"] as? [String: Any]) ?? [:]
    if projects[path] == nil {
        projects[path] = [
            "allowedTools": [],
            "hasTrustDialogAccepted": true
        ] as [String: Any]
        root["projects"] = projects
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Open existing folder tab

private struct OpenExistingFolderTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @Binding var isPresented: Bool

    @State private var chosen: URL?
    @State private var sessionName: String = ""
    @State private var startImmediately = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a directory you already have on disk. Work will track it as a project and register it with Claude Code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sectionLabel("FOLDER")
            HStack(spacing: 6) {
                Text(chosen?.path ?? "No folder chosen")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(chosen == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { pickFolder() }
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)
            }

            startSessionControls(
                startImmediately: $startImmediately,
                sessionName: $sessionName,
                show: chosen != nil
            )

            footerButtons(
                isPresented: $isPresented,
                primaryLabel: "Add Project",
                primaryEnabled: chosen != nil,
                onPrimary: commit
            )
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a project directory"
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            chosen = url
        }
    }

    private func commit() {
        guard let url = chosen else { return }
        registerProject(at: url.path, store: store)
        if startImmediately {
            let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                store.queuePendingRename(trimmed, for: url.path)
            }
            let title = trimmed.isEmpty ? url.lastPathComponent : trimmed
            terminals.requestOpenNew(projectCwd: url.path, title: title)
        }
        isPresented = false
    }
}

// MARK: - Clone from GitHub tab

private struct CloneFromGitHubTab: View {
    @EnvironmentObject var store: Store
    @Binding var isPresented: Bool

    @AppStorage("cloneDefaultParentPath") private var defaultParentPath: String = ""

    @State private var rawURL: String = ""
    @State private var parentDir: URL = CloneFromGitHubTab.defaultParent()
    @State private var folderName: String = ""
    @State private var autoFolderName = true
    @State private var startAfter = true
    @State private var sessionName: String = ""
    @State private var cloning = false
    @State private var log: [String] = []
    @State private var error: String?
    @FocusState private var urlFocused: Bool

    private var parsed: (gitURL: String, name: String)? {
        GitCloner.parse(rawURL).map { ($0.gitURL, $0.defaultName) }
    }

    private var canClone: Bool {
        !cloning && parsed != nil && !folderName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("REPOSITORY")
            TextField("github.com/anthropics/claude-code · foo/bar · git@github.com:…", text: $rawURL)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onAppear { urlFocused = true }
                .onChange(of: rawURL) { _, _ in
                    if autoFolderName, let p = parsed { folderName = p.name }
                }
                .onSubmit { if canClone { clone() } }

            if let p = parsed {
                Text("→ will fetch \(p.gitURL)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if !rawURL.isEmpty {
                Text("Paste a GitHub URL, SSH URL, or owner/repo shorthand")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            sectionLabel("CLONE INTO")
            HStack(spacing: 6) {
                Text(parentDir.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { pickParent() }
                    .controlSize(.small)
            }
            HStack(spacing: 4) {
                Text("/")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                TextField("folder-name", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: folderName) { _, _ in
                        autoFolderName = parsed?.name == folderName
                    }
            }

            startSessionControls(
                startImmediately: $startAfter,
                sessionName: $sessionName,
                show: canClone || cloning
            )

            if cloning || !log.isEmpty || error != nil {
                logPanel
            }

            footerButtons(
                isPresented: $isPresented,
                primaryLabel: cloning ? "Cloning…" : "Clone",
                primaryEnabled: canClone,
                onPrimary: clone
            )
        }
    }

    @ViewBuilder
    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if cloning {
                    ProgressView().controlSize(.mini)
                    Text("Cloning…").font(.caption).foregroundStyle(.secondary)
                } else if error != nil {
                    Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    Text("Failed").font(.caption).foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(log.indices, id: \.self) { i in
                        Text(log[i])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                .padding(8)
            }
            .frame(height: 120)
            .background(Color.secondary.opacity(0.04))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentDir
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            parentDir = url
            defaultParentPath = url.path
        }
    }

    private func clone() {
        guard let parsed else { return }
        let gitURL = parsed.gitURL
        let name = folderName
        let parent = parentDir
        log.removeAll()
        error = nil
        cloning = true
        let start = startAfter
        let sName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let dest = try await GitCloner.clone(
                    sourceURL: gitURL,
                    destinationParent: parent,
                    folderName: name,
                    onOutput: { line in Task { @MainActor in log.append(line) } }
                )
                await MainActor.run {
                    registerProject(at: dest.path, store: store)
                    if start {
                        if !sName.isEmpty {
                            store.queuePendingRename(sName, for: dest.path)
                        }
                        Launcher.newSession(atPath: dest.path)
                    }
                    cloning = false
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    self.cloning = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private static func defaultParent() -> URL {
        let stored = UserDefaults.standard.string(forKey: "cloneDefaultParentPath") ?? ""
        if !stored.isEmpty, FileManager.default.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent("Projects")
        if FileManager.default.fileExists(atPath: projects.path) { return projects }
        return home
    }
}

// MARK: - New folder tab

private struct CreateNewFolderTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @Binding var isPresented: Bool

    @AppStorage("newProjectDefaultParentPath") private var defaultParentPath: String = ""

    @State private var parentDir: URL = CreateNewFolderTab.defaultParent()
    @State private var folderName: String = ""
    @State private var sessionName: String = ""
    @State private var startImmediately = true
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var destination: URL? {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parentDir.appendingPathComponent(trimmed)
    }

    private var canCreate: Bool {
        guard let dest = destination else { return false }
        return !FileManager.default.fileExists(atPath: dest.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Work will create an empty folder on disk and register it as a project. Great for starting something new from scratch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sectionLabel("CREATE UNDER")
            HStack(spacing: 6) {
                Text(parentDir.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { pickParent() }
                    .controlSize(.small)
            }

            sectionLabel("FOLDER NAME")
            HStack(spacing: 4) {
                Text("/")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                TextField("my-new-project", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                    .onSubmit { if canCreate { commit() } }
            }
            if let dest = destination {
                if FileManager.default.fileExists(atPath: dest.path) {
                    Text("→ \(dest.path) already exists")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("→ \(dest.path)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            startSessionControls(
                startImmediately: $startImmediately,
                sessionName: $sessionName,
                show: canCreate
            )

            if let error {
                Text(error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            footerButtons(
                isPresented: $isPresented,
                primaryLabel: "Create Project",
                primaryEnabled: canCreate,
                onPrimary: commit
            )
        }
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentDir
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            parentDir = url
            defaultParentPath = url.path
        }
    }

    private func commit() {
        guard let dest = destination else { return }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            registerProject(at: dest.path, store: store)
            if startImmediately {
                let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.queuePendingRename(trimmed, for: dest.path)
                }
                let title = trimmed.isEmpty ? dest.lastPathComponent : trimmed
                terminals.requestOpenNew(projectCwd: dest.path, title: title)
            }
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func defaultParent() -> URL {
        let stored = UserDefaults.standard.string(forKey: "newProjectDefaultParentPath") ?? ""
        if !stored.isEmpty, FileManager.default.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent("Projects")
        if FileManager.default.fileExists(atPath: projects.path) { return projects }
        return home
    }
}

// MARK: - Shared UI helpers

private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(.tertiary)
}

@ViewBuilder
private func startSessionControls(
    startImmediately: Binding<Bool>,
    sessionName: Binding<String>,
    show: Bool
) -> some View {
    if show {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Start a Claude session immediately", isOn: startImmediately)
                .toggleStyle(.checkbox)
                .font(.callout)
            if startImmediately.wrappedValue {
                TextField("Session name (optional)", text: sessionName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }
}

private func footerButtons(
    isPresented: Binding<Bool>,
    primaryLabel: String,
    primaryEnabled: Bool,
    onPrimary: @escaping () -> Void
) -> some View {
    HStack {
        Spacer()
        Button("Cancel") { isPresented.wrappedValue = false }
            .keyboardShortcut(.cancelAction)
        Button(action: onPrimary) {
            Text(primaryLabel)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!primaryEnabled)
    }
}
