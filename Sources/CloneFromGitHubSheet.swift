import SwiftUI
import AppKit

// MARK: - Clone-from-GitHub sheet
//
// Paste a repo URL, pick where it lands, optionally name the first session.
// Runs `git clone` off the main actor and streams progress into a live log.

struct CloneFromGitHubSheet: View {
    @EnvironmentObject var store: Store
    @Binding var isPresented: Bool

    @AppStorage("cloneDefaultParentPath") private var defaultParentPath: String = ""

    @State private var rawURL: String = ""
    @State private var parentDir: URL = CloneFromGitHubSheet.defaultParent()
    @State private var folderName: String = ""
    @State private var startSessionAfter: Bool = true
    @State private var initialSessionName: String = ""

    @State private var cloning = false
    @State private var log: [String] = []
    @State private var error: String?
    @FocusState private var urlFocused: Bool

    /// Once the user types, we auto-fill the folder name from the parsed URL
    /// — but only while they haven't manually edited it.
    @State private var autoFolderName: Bool = true

    private var parsed: (gitURL: String, name: String)? {
        GitCloner.parse(rawURL).map { ($0.gitURL, $0.defaultName) }
    }

    private var destinationPreview: URL? {
        guard !folderName.isEmpty else { return nil }
        return parentDir.appendingPathComponent(folderName)
    }

    private var canClone: Bool {
        !cloning && parsed != nil && !folderName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Clone from GitHub")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }

            // URL input
            VStack(alignment: .leading, spacing: 4) {
                Text("REPOSITORY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                TextField("github.com/anthropics/claude-code · foo/bar · git@github.com:…", text: $rawURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onAppear { urlFocused = true }
                    .onSubmit { if canClone { clone() } }
                    .onChange(of: rawURL) { _, _ in
                        if autoFolderName, let p = parsed {
                            folderName = p.name
                        }
                    }
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
            }

            // Destination
            VStack(alignment: .leading, spacing: 4) {
                Text("CLONE INTO")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Text(parentDir.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
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
                if let dest = destinationPreview {
                    Text("→ \(dest.path)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // After-clone options
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Start a Claude Code session after cloning", isOn: $startSessionAfter)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                if startSessionAfter {
                    TextField("Session name (optional)", text: $initialSessionName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }

            // Log panel (only when we've run something)
            if cloning || !log.isEmpty || error != nil {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if cloning {
                            ProgressView().controlSize(.mini)
                            Text("Cloning…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if error != nil {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text("Failed")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("Done")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 100)
                    .background(Color.black.opacity(0.25))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(cloning)
                Button {
                    clone()
                } label: {
                    if cloning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Cloning…")
                        }
                    } else {
                        Text("Clone")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canClone)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    // MARK: - Actions

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

        let startAfter = startSessionAfter
        let sessionName = initialSessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let dest = try await GitCloner.clone(
                    sourceURL: gitURL,
                    destinationParent: parent,
                    folderName: name,
                    onOutput: { line in
                        Task { @MainActor in
                            log.append(line)
                        }
                    }
                )
                // Refresh projects so the new one appears in the sidebar
                await store.load()

                // Queue a named session if requested
                if startAfter {
                    if !sessionName.isEmpty {
                        store.queuePendingRename(sessionName, for: dest.path)
                    }
                    Launcher.newSession(atPath: dest.path)
                }

                await MainActor.run {
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

    // MARK: - Defaults

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
