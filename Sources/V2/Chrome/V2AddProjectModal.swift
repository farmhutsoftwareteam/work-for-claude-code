// Add Project modal (design: "Atelier add project.dc.html"). Centered
// overlay with two sources — Open folder and Clone repo — a "detected"
// panel (git / CLAUDE.md / stack), and the action that registers the
// project and lands on its home.

import SwiftUI
import AppKit
import Inject

// MARK: - Model

@MainActor
final class V2AddProjectModel: ObservableObject {
    enum Source { case local, clone }

    @Published var source: Source = .local

    // Open folder
    @Published var folderPath = ""
    @Published var name = ""
    @Published var detected: Detected?
    @Published var scanning = false

    /// The default model to spawn for this add. Seeded from the app default and
    /// applied to `appState.defaultSpawnModel` only on a successful add — so
    /// browsing the menu (or cancelling) no longer rewrites the global default.
    @Published var selectedModel = ""

    // Clone repo
    @Published var repoURL = ""
    @Published var cloneBase = NSHomeDirectory() + "/dev"
    @Published var branch = ""
    @Published var cloning = false

    @Published var error: String?

    struct Detected {
        var isGitRepo: Bool
        var branch: String?
        var ahead: Int
        var hasClaudeMd: Bool
        var stack: String?
    }

    var repoName: String {
        var s = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }   // strip trailing slash(es) first
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.isEmpty ? "repo" : last
    }
    var cloneInto: String { cloneBase + "/" + repoName }
    var canAddLocal: Bool { !folderPath.isEmpty }
    var canClone: Bool { repoURL.contains("/") && !cloning }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder to work in. Claude will run rooted there."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
        name = url.lastPathComponent
        error = nil
        Task { await scan(url.path) }
    }

    func chooseCloneBase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Where to clone into."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { cloneBase = url.path }
    }

    func scan(_ path: String) async {
        scanning = true
        defer { scanning = false }
        let isRepo = await V2Git.isRepo(cwd: path)
        var branch: String?, ahead = 0
        if isRepo, let s = await V2Git.status(cwd: path) {
            branch = s.branch; ahead = s.ahead
        }
        let fm = FileManager.default
        let hasClaude = fm.fileExists(atPath: path + "/CLAUDE.md")
        let stack = Self.detectStack(path, fm: fm)
        detected = Detected(isGitRepo: isRepo, branch: branch, ahead: ahead, hasClaudeMd: hasClaude, stack: stack)
    }

    private static func detectStack(_ path: String, fm: FileManager) -> String? {
        let checks: [(String, String)] = [
            ("pnpm-lock.yaml", "node · pnpm"), ("yarn.lock", "node · yarn"),
            ("package-lock.json", "node · npm"), ("package.json", "node"),
            ("Cargo.toml", "rust · cargo"), ("go.mod", "go"),
            ("Package.swift", "swift"), ("requirements.txt", "python"),
            ("pyproject.toml", "python"), ("Gemfile", "ruby"),
        ]
        for (file, label) in checks where fm.fileExists(atPath: path + "/" + file) { return label }
        return nil
    }
}

// MARK: - View

struct V2AddProjectModal: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState
    @StateObject private var model = V2AddProjectModel()
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0x1b/255, green: 0x1c/255, blue: 0x1e/255).opacity(0.46)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
        }
        .onAppear {
            if model.selectedModel.isEmpty { model.selectedModel = appState.defaultSpawnModel }
        }
        .enableInjection()
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            sourceTabs
            Group {
                switch model.source {
                case .local: localBody
                case .clone: cloneBody
                }
            }
            footer
        }
        .frame(width: 560)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 48, y: 16)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            V2DovetailMark(size: 20).foregroundColor(v2.ink)
            Text("Add a project")
                .font(.system(size: 16, weight: .medium)).kerning(-0.16)
                .foregroundColor(v2.ink)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute).frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var sourceTabs: some View {
        HStack(spacing: 2) {
            tab("Open folder", .local)
            tab("Clone repo", .clone)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func tab(_ title: String, _ which: V2AddProjectModel.Source) -> some View {
        let on = model.source == which
        return Button { model.source = which; model.error = nil } label: {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(on ? v2.ink : v2.mute)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(on ? v2.ink : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Open folder

    private var localBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: "folder") {
                HStack(spacing: 9) {
                    Text(model.folderPath.isEmpty ? "No folder chosen" : model.folderPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(model.folderPath.isEmpty ? v2.faint : v2.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Button { model.browse() } label: {
                        Text("Browse…").font(.system(size: 12, design: .monospaced)).foregroundColor(v2.ink)
                            .padding(.horizontal, 16).frame(maxHeight: .infinity)
                            .background(v2.paper3).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(height: 38)
                }
            }
            HStack(spacing: 10) {
                field(label: "name") {
                    TextField("project name", text: $model.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced)).foregroundColor(v2.ink)
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                field(label: "default model") {
                    Menu {
                        ForEach(modelOptions, id: \.self) { m in
                            Button(m) { model.selectedModel = m }
                        }
                    } label: {
                        HStack {
                            Text(effectiveModel).font(.system(size: 12.5, design: .monospaced)).foregroundColor(v2.ink)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundColor(v2.mute)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }.menuStyle(.borderlessButton)
                }
            }
            detectedPanel
        }
        .padding(20)
    }

    private var detectedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DETECTED").font(.system(size: 10, design: .monospaced)).kerning(1.2).foregroundColor(v2.faint)
            if model.folderPath.isEmpty {
                Text("Choose a folder to inspect it.").font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.faint)
            } else if model.scanning {
                Text("Scanning…").font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.faint)
            } else if let d = model.detected {
                detectRow(on: d.isGitRepo, "git repository", d.isGitRepo ? "\(d.branch ?? "—")\(d.ahead > 0 ? " · \(d.ahead) ahead" : "")" : "none")
                detectRow(on: d.hasClaudeMd, "CLAUDE.md", d.hasClaudeMd ? "found" : "none — will offer /init")
                detectRow(on: d.stack != nil, d.stack ?? "stack", d.stack != nil ? "will index" : "unknown")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.card).overlay(Rectangle().stroke(v2.line, lineWidth: 1))
    }

    private func detectRow(on: Bool, _ label: String, _ value: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(on ? v2.ink : .clear).overlay(Circle().stroke(on ? .clear : v2.line2, lineWidth: 1)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11.5, design: .monospaced)).foregroundColor(on ? v2.ink : v2.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.mute)
        }
    }

    // MARK: Clone repo

    private var cloneBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: "repository url") {
                TextField("git@github.com:you/repo.git", text: $model.repoURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced)).foregroundColor(v2.ink)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(v2.card).overlay(Rectangle().stroke(model.repoURL.isEmpty ? v2.line2 : v2.ink, lineWidth: 1))
            }
            HStack(spacing: 10) {
                field(label: "clone into") {
                    HStack(spacing: 8) {
                        Text(model.cloneInto).font(.system(size: 12.5, design: .monospaced)).foregroundColor(v2.mute)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.chooseCloneBase() } label: {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundColor(v2.mute).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                field(label: "branch") {
                    TextField("default", text: $model.branch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced)).foregroundColor(v2.ink)
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }.frame(width: 150)
            }
            HStack(spacing: 10) {
                if model.cloning {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Cloning \(model.repoName)…").font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.mute)
                } else {
                    Text("Will clone, then index the repo + read CLAUDE.md.")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.mute)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card).overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        }
        .padding(20)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let err = model.error {
                Text(err).font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.del)
                    .lineLimit(2).truncationMode(.middle)
            } else {
                Text("Registers the folder so Claude can run rooted there.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Text("Cancel").font(.system(size: 12, design: .monospaced)).foregroundColor(v2.ink)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: primaryAction) {
                Text(primaryLabel).font(.system(size: 12, design: .monospaced))
                    .foregroundColor(primaryEnabled ? v2.paper : v2.faint)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(primaryEnabled ? v2.ink : v2.card)
                    .overlay(Rectangle().stroke(primaryEnabled ? .clear : v2.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!primaryEnabled)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var primaryLabel: String {
        model.source == .clone ? (model.cloning ? "Cloning…" : "Clone & add") : "Add project"
    }
    private var primaryEnabled: Bool {
        model.source == .clone ? model.canClone : model.canAddLocal
    }

    private func primaryAction() {
        switch model.source {
        case .local: addLocal()
        case .clone: cloneAndAdd()
        }
    }

    private func addLocal() {
        guard let project = store.registerProject(at: model.folderPath) else {
            model.error = "That folder couldn't be registered."
            return
        }
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist the typed name so it survives reloads and shows in the rail —
        // not just in the transient header label.
        if !name.isEmpty { store.setProjectName(name, for: project.cwd) }
        applySelectedModel()
        appState.selectProject(cwd: project.cwd, name: name.isEmpty ? project.displayName : name)
        onClose()
    }

    private func cloneAndAdd() {
        model.error = nil
        model.cloning = true
        Task {
            let r = await V2Git.clone(url: model.repoURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                      into: model.cloneBase, name: model.repoName,
                                      branch: model.branch.trimmingCharacters(in: .whitespacesAndNewlines))
            model.cloning = false
            if let path = r.path, let project = store.registerProject(at: path) {
                applySelectedModel()
                appState.selectProject(cwd: project.cwd, name: project.displayName)
                onClose()
            } else {
                model.error = r.error ?? "Clone failed."
            }
        }
    }

    /// Commit the model picked in the dialog to the app default — only ever
    /// called from a successful add, so cancelling leaves the default untouched.
    private func applySelectedModel() {
        let m = model.selectedModel
        if !m.isEmpty { appState.defaultSpawnModel = m }
    }

    // MARK: Helpers

    /// The model shown/used in the dialog: the in-dialog pick, falling back to
    /// the current app default until the user has touched the menu.
    private var effectiveModel: String {
        model.selectedModel.isEmpty ? appState.defaultSpawnModel : model.selectedModel
    }

    private var modelOptions: [String] {
        let discovered = appState.discoveredModels.map(\.id)
        var seen = Set<String>(), out: [String] = []
        for m in [effectiveModel] + discovered where seen.insert(m).inserted { out.append(m) }
        return out
    }

    private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.system(size: 10, design: .monospaced)).kerning(1.0).foregroundColor(v2.faint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
