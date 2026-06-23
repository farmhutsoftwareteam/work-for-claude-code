import SwiftUI
import AppKit

// MARK: - Session list for the selected project

struct SessionListView: View {
    let projectId: String
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @State private var searchText = ""
    @State private var showNewSessionPopover = false
    @State private var showProjectConfig = false
    @State private var showIntegrations = false
    @State private var showHidden: Bool = false
    @State private var renameTarget: Session? = nil
    @State private var renameDraft: String = ""

    private var project: Project? {
        store.projects.first { $0.id == projectId }
    }

    private var hiddenCount: Int {
        project?.sessions.filter { store.isHidden($0) }.count ?? 0
    }

    private var filteredSessions: [Session] {
        guard let project else { return [] }
        let sessions = project.sessions.filter { showHidden || !store.isHidden($0) }
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { s in
            store.displayName(for: s).localizedCaseInsensitiveContains(searchText) ||
            s.lastMessagePreview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        if let project {
            // Full-pane centered empty state — a List row wrapping the
            // ContentUnavailableView renders it in the top-left corner,
            // which looks abandoned on a wide detail pane. Gate on
            // `!store.isLoading` so we don't flash "No sessions yet" during
            // the initial JSONL parse on app launch.
            if project.sessions.isEmpty && searchText.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label("No sessions yet", systemImage: "terminal")
                } description: {
                    Text("Start a new Claude session in **\(project.displayName)**.")
                } actions: {
                    Button {
                        showNewSessionPopover = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .popover(isPresented: $showNewSessionPopover, arrowEdge: .bottom) {
                        NewSessionPopover(currentProject: project, isPresented: $showNewSessionPopover)
                            .environmentObject(store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(project.displayName)
                .navigationSubtitle(project.cwd)
            } else {
            List {
                if filteredSessions.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredSessions) { session in
                        SessionRow(
                            session: session,
                            onView: { store.selectedSessionForViewing = session },
                            onStart: {
                                terminals.requestOpenResume(
                                    sessionId: session.id,
                                    projectCwd: project.cwd,
                                    title: store.displayName(for: session)
                                )
                                store.selectedSessionForViewing = session
                            }
                        )
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button {
                                renameDraft = store.displayName(for: session)
                                renameTarget = session
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }

                            if store.hasAlias(session) {
                                Button {
                                    Task { await store.clearAlias(for: session) }
                                } label: {
                                    Label("Clear custom name", systemImage: "arrow.counterclockwise")
                                }
                            }

                            Divider()

                            if store.isHidden(session) {
                                Button {
                                    Task { await store.setHidden(false, for: session) }
                                } label: {
                                    Label("Unhide session", systemImage: "eye")
                                }
                            } else {
                                Button {
                                    Task { await store.setHidden(true, for: session) }
                                } label: {
                                    Label("Hide session", systemImage: "eye.slash")
                                }
                            }

                            Divider()

                            Button {
                                Launcher.resumeOrFocus(session, in: project)
                            } label: {
                                Label("Open in Terminal.app", systemImage: "terminal")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.id, forType: .string)
                            } label: {
                                Label("Copy session ID", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }

            }
            .listStyle(.inset)
            // Perf #5: batch-load all slugs for this project in one pass
            .task(id: project.id) {
                // BUG-31 fix: parallelize slug loads. For projects with many
                // sessions, the previous sequential `await` made the row
                // labels trickle in one-by-one. TaskGroup runs all the file
                // reads concurrently — the store mutations themselves still
                // serialize on @MainActor.
                await withTaskGroup(of: Void.self) { group in
                    for session in project.sessions where session.slug == nil {
                        group.addTask { await store.loadSlug(for: session) }
                    }
                }
            }
            .navigationTitle(project.displayName)
            .navigationSubtitle(project.cwd)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search sessions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewSessionPopover = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .help("Start a new Claude session")
                    .popover(isPresented: $showNewSessionPopover, arrowEdge: .bottom) {
                        NewSessionPopover(currentProject: project, isPresented: $showNewSessionPopover)
                            .environmentObject(store)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button { showIntegrations = true } label: {
                        Label("Integrations", systemImage: "puzzlepiece.extension.fill")
                    }
                    .help("Add Linear, Notion, Sentry and other MCPs to this project")
                }
                ToolbarItem(placement: .automatic) {
                    Button { showProjectConfig.toggle() } label: {
                        Label("Project Config", systemImage: "slider.horizontal.3")
                    }
                    .help("MCPs and skills for this project")
                    .popover(isPresented: $showProjectConfig, arrowEdge: .bottom) {
                        ProjectConfigPopover(project: project)
                            .environmentObject(store)
                    }
                }
                if hiddenCount > 0 {
                    ToolbarItem(placement: .automatic) {
                        Toggle(isOn: $showHidden) {
                            Label("Show hidden (\(hiddenCount))", systemImage: showHidden ? "eye" : "eye.slash")
                        }
                        .help(showHidden ? "Hide archived sessions" : "Show \(hiddenCount) hidden session\(hiddenCount == 1 ? "" : "s")")
                    }
                }
            }
            .sheet(item: $renameTarget) { target in
                RenameSessionSheet(
                    session: target,
                    draft: $renameDraft,
                    onSave: { newName in
                        Task {
                            await store.setAlias(newName, for: target)
                            renameTarget = nil
                        }
                    },
                    onClear: {
                        Task {
                            await store.clearAlias(for: target)
                            renameTarget = nil
                        }
                    },
                    onCancel: { renameTarget = nil }
                )
            }
            .sheet(isPresented: $showIntegrations) {
                ProjectIntegrationsPanel(
                    project: project,
                    isPresented: $showIntegrations
                )
                .environmentObject(store)
                .environmentObject(terminals)
            }
            } // close: else branch of the sessions.isEmpty check
        } else if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Project Not Found",
                systemImage: "questionmark.folder"
            )
        }
    }
}

// MARK: - New Session Popover
// Command-palette aesthetic: monospaced accents, clear hierarchy, keyboard-native feel

struct NewSessionPopover: View {
    let currentProject: Project
    @Binding var isPresented: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController

    @State private var searchText = ""
    @State private var sessionName = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var searchFocused: Bool

    /// Per-row height used by the scroll-area frame calculation. Scales with
    /// the subheadline body size so the frame stays correct on Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeightEstimate: CGFloat = 40

    private var otherProjects: [Project] {
        let rest = store.projects.filter { $0.id != currentProject.id }
        guard !searchText.isEmpty else { return rest }
        return rest.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.cwd.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Section header ───────────────────────────────────────
            Text("NEW SESSION")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // ── Name (optional) ──────────────────────────────────────
            HStack(spacing: 7) {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                TextField("Name this session (optional)", text: $sessionName)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($nameFocused)

                if !sessionName.isEmpty {
                    Button { sessionName = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            // ── Primary action — current project ─────────────────────
            // Serial Position Effect + Pareto: 80% of clicks land here
            Button {
                let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.queuePendingRename(trimmed, for: currentProject.cwd)
                }
                let title = trimmed.isEmpty ? currentProject.displayName : trimmed
                terminals.requestOpenNew(projectCwd: currentProject.cwd, title: title)
                isPresented = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentProject.displayName)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Current project")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // Keyboard hint — implies this is the "return" action
                    Text("⏎")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .keyboardShortcut(.return, modifiers: [])

            // ── Divider with label — the memorable design moment ─────
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                Text("OR PICK A PROJECT")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .fixedSize()

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // ── Search ────────────────────────────────────────────────
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                TextField("Filter projects…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($searchFocused)

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)

            // ── Project list ──────────────────────────────────────────
            ScrollView {
                VStack(spacing: 1) {
                    if otherProjects.isEmpty {
                        // Empty state — either no other projects or search found nothing
                        Group {
                            if searchText.isEmpty {
                                Text("No other projects")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("No results for \"\(searchText)\"")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(otherProjects) { project in
                            ProjectPickerRow(project: project) {
                                let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    store.queuePendingRename(trimmed, for: project.cwd)
                                }
                                store.selectedProject = project
                                let title = trimmed.isEmpty ? project.displayName : trimmed
                                terminals.requestOpenNew(projectCwd: project.cwd, title: title)
                                isPresented = false
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            // Roughly sized by number of rows. Uses a dynamic-type-aware
            // estimate: each picker row is ~1.75× the body line height plus
            // its vertical padding; 192pt caps at ~5 rows before scrolling.
            .frame(height: min(CGFloat(max(otherProjects.count, 1)) * rowHeightEstimate + 12, 192))

            // ── Footer divider + open directory ───────────────────────
            Divider()
                .padding(.top, 2)

            Button {
                isPresented = false
                // Brief delay so the popover fully closes before the panel appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    openDirectoryPicker()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)
                    Text("Open directory…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        // BUG-35 fix: focus the name field first — it's the primary input
        // when starting a session in the current project. The user can tab
        // into the project search if they want a different project.
        .onAppear { nameFocused = true }
    }

    private func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a project directory"
        panel.prompt = "Start Session"
        panel.message = "Select the folder you want to start a Claude session in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = Project(
            id: url.path,
            cwd: url.path,
            displayName: url.lastPathComponent,
            sessions: [],
            isActive: false
        )
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.queuePendingRename(trimmed, for: project.cwd)
        }
        // Insert the ephemeral project into the store synchronously so the
        // sidebar shows it AND `selectedProject` reflects it BEFORE the new
        // tab spawns. Without this, `detailContent`'s "active live tab" guard
        // (`selectedProject?.cwd == active.projectCwd`) fails and the user
        // sees the tab in the chip bar but can't get to the terminal.
        if !store.projects.contains(where: { $0.cwd == project.cwd }) {
            store.projects.insert(project, at: 0)
        }
        store.selectedProject = project
        // Also register the project in `~/.claude.json` so it survives a
        // Work restart even if Claude hasn't written JSONL yet. Best-effort.
        Self.registerProjectWithClaude(cwd: project.cwd)
        let title = trimmed.isEmpty ? project.displayName : trimmed
        terminals.requestOpenNew(projectCwd: project.cwd, title: title)
        // No manual reload — the sessions-directory file watcher picks up
        // the real JSONL the moment Claude writes it, and Store.load() now
        // preserves the ephemeral project until then. The old reload here
        // was triggering an `isLoading = true` flash + layout shift.
    }

    /// Append a project entry to `~/.claude.json`'s top-level `projects`
    /// dict so the directory is remembered even if Claude never writes a
    /// JSONL for it. Idempotent — no-op if the path is already present.
    private static func registerProjectWithClaude(cwd: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var projects = (root["projects"] as? [String: Any]) ?? [:]
        if projects[cwd] != nil { return }
        projects[cwd] = [
            "allowedTools": [],
            "hasTrustDialogAccepted": true
        ] as [String: Any]
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else {
            return
        }
        try? out.write(to: url, options: .atomic)
    }
}

// MARK: - Project picker row

struct ProjectPickerRow: View {
    let project: Project
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(project.isActive ? Color.green : Color.secondary)
                    .frame(width: 22, alignment: .center)

                Text(project.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Session count + active dot
                HStack(spacing: 4) {
                    if project.isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                    }
                    Text("\(project.sessions.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session
    let onView: () -> Void
    let onStart: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @State private var isHovered = false

    private var sessionTokens: Int? {
        let t = store.usageTotals.bySession[session.id]?.usage.total ?? 0
        return t > 0 ? t : nil
    }

    private var isLive: Bool {
        terminals.isSessionLive(session.id) || session.isActive
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.displayName(for: session))
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(store.isHidden(session) ? .secondary : .primary)

                    if store.hasAlias(session) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Custom name — original: \(session.slug ?? String(session.id.prefix(8)))")
                    }

                    if store.isHidden(session) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Hidden — right-click to unhide")
                    }

                    if isLive {
                        HStack(spacing: 4) {
                            LivePulseDot(size: 5)
                            Text("live")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Spacer(minLength: 8)

                    if let tokens = sessionTokens {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.grid.2x2.fill")
                                .font(.system(size: 8))
                            Text(UsageAggregator.format(tokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.tertiary)
                        .help("\(tokens.formatted()) tokens")
                    }

                    Text(session.lastActivity, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if !session.lastMessagePreview.isEmpty {
                    Text(session.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 2) {
                RowActionButton(icon: "eye", tooltip: "Read conversation", action: onView)
                RowActionButton(
                    icon: session.isActive ? "arrow.right.circle.fill" : "play.fill",
                    tooltip: session.isActive ? "Attach to running session" : "Resume in Terminal",
                    tint: session.isActive ? .green : .accentColor,
                    action: onStart
                )
            }
            .opacity(isHovered ? 1 : 0.2)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Project config popover (toolbar button)

struct ProjectConfigPopover: View {
    let project: Project
    @EnvironmentObject var store: Store

    private var projMCPs: [MCPServer] { store.projectMCPs[project.cwd] ?? [] }
    private var projSkills: [ClaudeSkill] { store.projectSkills[project.cwd] ?? [] }
    private var globalMCPs: [MCPServer] { store.standaloneMCPs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("PROJECT CONFIG")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // Project MCPs
                    if !projMCPs.isEmpty {
                        configSection("Project MCPs", icon: "server.rack", color: .blue) {
                            ForEach(projMCPs) { mcp in
                                ProjectMCPRow(mcp: mcp, scope: "project")
                            }
                        }
                    }

                    // Global MCPs
                    if !globalMCPs.isEmpty {
                        configSection("Global MCPs", icon: "globe", color: .secondary) {
                            ForEach(globalMCPs) { mcp in
                                ProjectMCPRow(mcp: mcp, scope: "global")
                            }
                        }
                    }

                    // Project Skills
                    if !projSkills.isEmpty {
                        configSection("Project Skills", icon: "sparkles", color: .purple) {
                            ForEach(projSkills) { skill in
                                ProjectSkillRow(skill: skill)
                            }
                        }
                    }

                    // Empty state
                    if projMCPs.isEmpty && projSkills.isEmpty && globalMCPs.isEmpty {
                        Text("No MCPs or skills configured")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 360)

            Divider()

            // Path hint
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(project.cwd + "/.claude/")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    private func configSection<Content: View>(
        _ title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                content()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Per-project config rows

struct ProjectMCPRow: View {
    let mcp: MCPServer
    let scope: String
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .foregroundStyle(scope == "project" ? .blue : .secondary)
                .frame(width: 14)
            Text(mcp.name)
                .font(.callout)
            Spacer()
            MCPStatusBadge(status: store.mcpStatuses[mcp.statusKey])
            Text(mcp.transportLabel)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }
}

struct ProjectSkillRow: View {
    let skill: ClaudeSkill

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .foregroundStyle(.purple)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .font(.callout.weight(.medium))
                if !skill.skillDescription.isEmpty {
                    Text(skill.skillDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Reusable icon button for row actions

struct RowActionButton: View {
    let icon: String
    let tooltip: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Rename session sheet

struct RenameSessionSheet: View {
    let session: Session
    @Binding var draft: String
    let onSave: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject var store: Store
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename session")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. auth-migration-thursday", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        // BUG-58 fix: don't silently swallow Enter on empty
                        // input — treat it as a cancel so the sheet closes.
                        if trimmed.isEmpty {
                            onCancel()
                        } else {
                            onSave(trimmed)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Original: \(session.slug ?? String(session.id.prefix(8)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("Only changes the name shown in Atelier. Claude Code still sees the original.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if store.hasAlias(session) {
                    Button("Reset to original") { onClear() }
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onSave(trimmed) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
