import SwiftUI
import ServiceManagement

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case project(String)
    case plugins
    case skills
    case mcps
    case hooks
    case usage
    case marketplace
}

// MARK: - Sheet state (single sheet driver to avoid SwiftUI conflicts)

enum ActiveSheet: Identifiable {
    case onboarding

    var id: String { "onboarding" }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updateState: UpdateStateObserver
    @EnvironmentObject var terminals: TerminalsController
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var sidebarSelection: SidebarSelection?
    @State private var showAddProjectSheet = false
    @State private var searchText = ""
    /// Debounced mirror of `searchText` — actual filtering reads from this
    /// so we don't run two O(n·m) scans per keystroke. Updates 200ms after
    /// the user stops typing.
    @State private var debouncedSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Memoized search outputs. Recomputed only when `debouncedSearch` or the
    /// underlying store changes — not on every body re-eval. Without this the
    /// O(n·m) scans ran multiple times per render after each debounce flush.
    @State private var filteredProjects: [Project] = []
    @State private var sessionSearchResults: [(session: Session, project: Project)] = []

    private var isSearching: Bool {
        !debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Recompute search outputs from `debouncedSearch` and the current store.
    /// Cheap to call on demand — does the work once and caches it.
    private func rebuildSearchResults() {
        if !isSearching {
            filteredProjects = store.projects
            sessionSearchResults = []
            return
        }
        filteredProjects = store.projects.filter {
            $0.displayName.localizedCaseInsensitiveContains(debouncedSearch) ||
            $0.cwd.localizedCaseInsensitiveContains(debouncedSearch)
        }
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        sessionSearchResults = store.allSessionsWithProjects(includeHidden: false).filter { pair in
            let name = store.displayName(for: pair.session).lowercased()
            let preview = pair.session.lastMessagePreview.lowercased()
            let proj = pair.project.displayName.lowercased()
            return name.contains(q) || preview.contains(q) || proj.contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $sidebarSelection) {
                    if store.isLoading && store.projects.isEmpty {
                        ForEach(0..<8, id: \.self) { _ in SkeletonProjectRow() }
                    } else if isSearching {
                        sessionSearchSection
                        projectMatchesSection
                    } else {
                        ForEach(filteredProjects) { project in
                            ProjectRow(project: project)
                                .tag(SidebarSelection.project(project.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search projects & sessions")

                Divider()

                // Pinned config bar — always visible, never scrolls
                ConfigBar(selection: $sidebarSelection)
                    .environmentObject(store)
            }
            .navigationTitle("Atelier")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddProjectSheet = true
                    } label: {
                        Image(systemName: "plus.square.dashed")
                    }
                    .help("Add a project — open a folder, clone a repo, or start fresh (⌘N)")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }
                if updateState.hasUpdate {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            if updateState.isDownloaded { updateState.presentUpdate() }
                        } label: {
                            HStack(spacing: 4) {
                                if updateState.isDownloaded {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                } else {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.6)
                                        .frame(width: 10, height: 10)
                                }
                                Text(updateState.compactActionLabel)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!updateState.isDownloaded)
                        .help(
                            updateState.isDownloaded
                                ? "Click to relaunch and install \(updateState.availableVersion ?? "update")"
                                : "Downloading \(updateState.availableVersion ?? "update") in the background…"
                        )
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        sidebarSelection = nil
                        store.selectedProject = nil
                        store.selectedSessionForViewing = nil
                        searchText = ""
                    } label: {
                        Image(systemName: "house")
                    }
                    .help("Go home")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await store.load()
                            await store.loadExtensions() // manual refresh reloads extensions too
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                    .disabled(store.isLoading)
                }
                ToolbarItem(placement: .automatic) {
                    PreferencesButton()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            detailPane
        }
        .sheet(isPresented: $showAddProjectSheet) {
            AddProjectSheet(isPresented: $showAddProjectSheet)
                .environmentObject(store)
                .environmentObject(terminals)
        }
        .onChange(of: sidebarSelection) { _, newValue in
            switch newValue {
            case .project(let id):
                let project = store.projects.first { $0.id == id }
                store.selectedProject = project
                // If the previously-viewed session belongs to a different
                // project, clear it so the detail pane shows this project's
                // session list rather than a stale conversation.
                if let viewing = store.selectedSessionForViewing,
                   viewing.projectCwd != project?.cwd {
                    store.selectedSessionForViewing = nil
                }
            case .plugins, .skills, .mcps, .hooks, .usage, .marketplace:
                // Config tabs always take over the detail pane — clear any
                // session view so the user actually navigates there.
                store.selectedProject = nil
                store.selectedSessionForViewing = nil
            case .none:
                // Going home — clear everything so the welcome screen shows.
                store.selectedProject = nil
                store.selectedSessionForViewing = nil
            }
        }
        // Keep `selectedSessionForViewing` in lockstep with the active tab.
        // Opening a new tab or switching via Cmd+1…9 updates both.
        .onChange(of: terminals.activeTabId) { _, newTabId in
            guard let newTabId,
                  let tab = terminals.tabs.first(where: { $0.id == newTabId })
            else { return }
            handleTabClick(tab)
        }
        // Keep the sidebar visually in sync with whatever session the user is
        // viewing. Without this, clicking a session from any non-project
        // context (search results, tab bar while in Plugins, Resume from home)
        // navigated correctly in the detail pane but left the sidebar still
        // highlighting the previous destination — making the app feel lost
        // about its own state.
        .onChange(of: store.selectedSessionForViewing) { _, newSession in
            guard let newSession,
                  let project = store.projects.first(where: { $0.cwd == newSession.projectCwd })
            else { return }
            if sidebarSelection != .project(project.id) {
                sidebarSelection = .project(project.id)
            }
        }
        // BUG-69 fix: debounce search input so typing doesn't trigger two
        // O(n·m) scans per keystroke for large project/session counts.
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            // Empty → flush immediately (fast clear).
            if newValue.isEmpty {
                debouncedSearch = ""
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
            }
        }
        // Refresh the memoized search results once per actual data shift —
        // not on every body render.
        .onAppear { rebuildSearchResults() }
        .onChange(of: debouncedSearch) { _, _ in rebuildSearchResults() }
        .onChange(of: store.projects) { _, _ in rebuildSearchResults() }
        // BUG-28/42 fix: don't auto-complete onboarding on every dismissal —
        // only the OnboardingView's explicit "Done" callback should mark it
        // complete. The binding's setter intentionally ignores `false` writes
        // so Escape / outside-click can't bypass onboarding.
        .sheet(isPresented: Binding(
            get: { !onboardingComplete },
            set: { _ in /* completion handled by OnboardingView callback only */ }
        )) {
            OnboardingView { onboardingComplete = true }
                .interactiveDismissDisabled(true)
        }
        .task {
            await store.load()
            store.startWatching()
        }
        .confirmationDialog(
            "Start this Claude session with --dangerously-skip-permissions?",
            isPresented: Binding(
                get: { terminals.pendingStart != nil },
                set: { newValue in if !newValue { terminals.cancelPendingStart() } }
            ),
            titleVisibility: .visible,
            presenting: terminals.pendingStart
        ) { pending in
            Button("Skip permissions for this session", role: .destructive) {
                terminals.confirmPendingStart(skipPermissions: true)
            }
            Button("Use normal permissions") {
                terminals.confirmPendingStart(skipPermissions: false)
            }
            Button("Cancel", role: .cancel) {
                terminals.cancelPendingStart()
            }
        } message: { pending in
            Text("\(pending.displayLabel)\n\nSkip mode runs Claude without asking before tool use. Faster, but only safe in projects you fully trust. You can stop being asked from Preferences → Ask before starting.")
        }
        .frame(minWidth: 700, minHeight: 440)
    }

    // MARK: - Sidebar search sections (shown only when typing)

    @ViewBuilder
    private var sessionSearchSection: some View {
        let sessions = sessionSearchResults
        if !sessions.isEmpty {
            Section {
                ForEach(Array(sessions.prefix(30)), id: \.session.id) { pair in
                    SidebarSessionRow(session: pair.session, project: pair.project)
                        .environmentObject(store)
                }
            } header: {
                Text("Sessions · \(sessions.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
    }

    @ViewBuilder
    private var projectMatchesSection: some View {
        let projs = filteredProjects
        if !projs.isEmpty {
            Section {
                ForEach(projs) { project in
                    ProjectRow(project: project)
                        .tag(SidebarSelection.project(project.id))
                }
            } header: {
                Text("Projects · \(projs.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            // Chrome-style tab strip — sits above everything whenever any
            // session is open. Click a tab → that session takes over below.
            if terminals.tabs.contains(where: { $0.surface == .modeA }) {
                TerminalTabBar(
                    onClickTab: handleTabClick,
                    onOpenInTerminalApp: handleOpenExternal
                )
                .environmentObject(terminals)
                .environmentObject(store)
            }

            detailContent
        }
    }

    // MARK: - Tab bar actions

    /// Clicking a tab flips `selectedSessionForViewing` so the SessionDetailView
    /// shows the right session. For new-session tabs (no JSONL yet → no
    /// `sessionId`), navigate the sidebar to the tab's project and clear the
    /// viewing session so `detailContent` falls through to the live-terminal
    /// branch. Without this step, clicking a brand-new tab from a different
    /// project was a no-op — the user saw the chip but couldn't get to it.
    private func handleTabClick(_ tab: TerminalTab) {
        // Resolve the project from the store if it's there. For fresh
        // directories opened via the directory picker, the project may not
        // yet be in `store.projects` — fall back to a synthetic one keyed
        // off the tab's cwd so navigation still works. Also insert that
        // synthetic project into the store so SessionListView's lookup
        // `store.projects.first { $0.id == projectId }` doesn't miss and
        // render "Project Not Found".
        let project: Project = {
            if let existing = store.projects.first(where: { $0.cwd == tab.projectCwd }) {
                return existing
            }
            let synthetic = Project(
                id: tab.projectCwd,
                cwd: tab.projectCwd,
                displayName: (tab.projectCwd as NSString).lastPathComponent,
                sessions: [],
                isActive: false
            )
            store.projects.insert(synthetic, at: 0)
            return synthetic
        }()

        if let sessionId = tab.sessionId,
           let session = project.sessions.first(where: { $0.id == sessionId }) {
            store.selectedProject = project
            store.selectedSessionForViewing = session
            return
        }

        // Session-less tab (new session before Claude has written JSONL).
        store.selectedProject = project
        store.selectedSessionForViewing = nil
        if sidebarSelection != .project(project.id) {
            sidebarSelection = .project(project.id)
        }
    }

    /// Detach a tab's session into Terminal.app. Launch Terminal first; only
    /// close the in-app PTY if the external launch actually succeeds. If the
    /// user has denied Automation permission, we keep the in-app session
    /// alive rather than orphaning them with nothing at all.
    private func handleOpenExternal(_ tabId: UUID) {
        guard let tab = terminals.tabs.first(where: { $0.id == tabId }) else { return }
        let project = store.projects.first { $0.cwd == tab.projectCwd }
        let cwd = tab.projectCwd
        let sid = tab.sessionId

        let launched: Bool
        if let sid, let project,
           let session = project.sessions.first(where: { $0.id == sid }) {
            launched = Launcher.resume(session, in: project)
        } else {
            launched = Launcher.newSession(atPath: cwd)
        }

        guard launched else {
            // Keep the in-app tab alive so the user isn't stranded. Launcher
            // has already surfaced whatever error dialog it needed.
            return
        }
        // External Terminal.app has the prompt; safe to reap the embedded PTY.
        terminals.close(tabId, force: true)
    }

    @ViewBuilder
    private var detailContent: some View {
        // Active tab is a brand-new session (no JSONL yet → no session id) and
        // its project is the one the user just picked: render the live
        // terminal directly. Gates on `store.selectedProject` (which the
        // popover sets synchronously before `openNew`) rather than on
        // `sidebarSelection`, which only catches up after an onChange cycle —
        // that one-frame gap was showing the user the OLD session's view.
        if let activeId = terminals.activeTabId,
           let active = terminals.tabs.first(where: { $0.id == activeId }),
           active.isLive,
           active.sessionId == nil,
           store.selectedProject?.cwd == active.projectCwd {
            EmbeddedTerminalView(tabId: active.id)
                .id("live-new-\(active.id)")
        } else if let session = store.selectedSessionForViewing {
            SessionDetailView(session: session)
                .environmentObject(store)
                .environmentObject(terminals)
        } else {
            switch sidebarSelection {
            case .project(let id):
                SessionListView(projectId: id)
            case .plugins:
                PluginsListView()
            case .skills:
                SkillsListView()
            case .mcps:
                MCPsListView()
            case .hooks:
                HooksListView()
            case .usage:
                UsageView()
            case .marketplace:
                MarketplaceView()
            case nil:
                ContinueEmptyState()
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - "Continue where you left off" empty state

/// App-Store-style feature card with a second tier of recent sessions below.
/// When there's a recent session: shows a featured card with hero presence.
/// When there's nothing: shows a welcome message.
private struct ContinueEmptyState: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updateState: UpdateStateObserver
    @State private var showNewSessionPopover = false
    @State private var showCloneSheet = false
    @State private var renameTarget: Session?
    @State private var renameDraft: String = ""

    private var recent: (session: Session, project: Project)? {
        store.mostRecentSession()
    }

    private func beginRename(_ session: Session) {
        renameDraft = store.displayName(for: session)
        renameTarget = session
    }

    /// Up to 4 additional sessions beyond the "most recent" to show as quick-resume chips.
    /// BUG-48 fix: if the "most recent" session can't be found in `all` (rare
    /// race when filters/hidden flags shift between calls), fall back to
    /// "the next 4 sessions overall" instead of returning empty.
    private var otherRecentSessions: [(session: Session, project: Project)] {
        let all = store.allSessionsWithProjects(includeHidden: false)
        guard let first = recent else { return [] }
        if let firstIdx = all.firstIndex(where: { $0.session.id == first.session.id }) {
            return Array(all.dropFirst(firstIdx + 1).prefix(4))
        }
        // Fallback: just return the top 4 (skipping at most one to avoid
        // duplicating the visible feature card session).
        return Array(all.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Update banner (shown only when an update is waiting)
                if updateState.hasUpdate {
                    UpdateBanner()
                        .environmentObject(updateState)
                }

                // Eyebrow
                Text("PICK UP WHERE YOU LEFT OFF")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentColor)

                if let (session, project) = recent {
                    ContinueFeatureCard(
                        session: session,
                        project: project,
                        onRename: { beginRename(session) }
                    )
                    .environmentObject(store)

                    // Primary new session card — sits right below the feature card
                    StartNewSessionCard(
                        defaultProject: project,
                        showPopover: $showNewSessionPopover
                    )
                    .environmentObject(store)

                    // Clone from GitHub card — for starting work on a new repo
                    CloneFromGitHubCard(showSheet: $showCloneSheet)

                    if !otherRecentSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Jump back in")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(otherRecentSessions, id: \.session.id) { pair in
                                    ContinueMiniCard(
                                        session: pair.session,
                                        project: pair.project,
                                        onRename: { beginRename(pair.session) }
                                    )
                                    .environmentObject(store)
                                }
                            }
                        }
                    }
                } else {
                    emptyWelcome
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .environmentObject(store)
        }
        .sheet(isPresented: $showCloneSheet) {
            CloneFromGitHubSheet(isPresented: $showCloneSheet)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private var emptyWelcome: some View {
        if let firstProject = store.projects.first {
            VStack(spacing: 20) {
                Image(systemName: "terminal")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("No recent sessions yet")
                    .font(.system(size: 16, weight: .semibold))
                Text("Start a new Claude Code session below — it'll appear here next time.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                StartNewSessionCard(
                    defaultProject: firstProject,
                    showPopover: $showNewSessionPopover
                )
                .environmentObject(store)
                .padding(.top, 8)

                CloneFromGitHubCard(showSheet: $showCloneSheet)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("No sessions yet")
                    .font(.system(size: 16, weight: .semibold))
                Text("Start a Claude Code session in any directory, or clone a repo to get going.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                CloneFromGitHubCard(showSheet: $showCloneSheet)
                    .frame(maxWidth: 360)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }
}

// MARK: - Update banner (shown on home when a Sparkle update is ready)

private struct UpdateBanner: View {
    @EnvironmentObject var updateState: UpdateStateObserver
    @State private var hovering = false

    private var headline: String {
        let version = updateState.availableVersion ?? "A newer version"
        return updateState.isDownloaded
            ? "Version \(version) is ready — relaunch to install"
            : "Downloading version \(version) in the background"
    }

    private var subheadline: String {
        updateState.isDownloaded
            ? "Quick restart, no waiting — the update is already downloaded"
            : "We'll let you know the moment it's ready to install"
    }

    var body: some View {
        Button {
            if updateState.isDownloaded { updateState.presentUpdate() }
        } label: {
            HStack(spacing: 12) {
                if updateState.isDownloaded {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subheadline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if updateState.isDownloaded {
                    Text("Relaunch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering && updateState.isDownloaded ? 0.12 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!updateState.isDownloaded)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Start new session card (opens NewSessionPopover)

private struct StartNewSessionCard: View {
    let defaultProject: Project
    @Binding var showPopover: Bool
    @EnvironmentObject var store: Store
    @State private var hovering = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 48, height: 48)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a new session")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Launch Claude Code in any project")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("⌘")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text("N")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovering ? 0.1 : 0.07), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        // BUG-53 fix: ⌘T already opens a new tab globally via WorkApp's
        // CommandGroup. The card itself doesn't need to bind ⌘N, which
        // would silently die when off-screen.
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            NewSessionPopover(currentProject: defaultProject, isPresented: $showPopover)
                .environmentObject(store)
        }
    }
}

// MARK: - Clone from GitHub card (opens CloneFromGitHubSheet)

private struct CloneFromGitHubCard: View {
    @Binding var showSheet: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(hovering ? 0.15 : 0.1))
                        .frame(width: 48, height: 48)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clone from GitHub")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Pull a repo and start coding with Claude in one step")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.08 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(hovering ? 0.2 : 0.12), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        // BUG-54 fix: ⌘⇧G shadows macOS's Go-to-Folder. Drop the shortcut
        // (clone-from-GitHub is rare enough not to need a chord).
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Feature card (hero, App-Store-style)

private struct ContinueFeatureCard: View {
    let session: Session
    let project: Project
    let onRename: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @State private var hovering = false
    @State private var titleHovering = false

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: session.lastActivity, relativeTo: Date())
    }

    private var tokenCount: String? {
        let total = store.usageTotals.bySession[session.id]?.usage.total ?? 0
        return total > 0 ? UsageAggregator.format(total) : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // Left: icon orb
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.7)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 14, y: 6)

                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 2)  // Optical centering
            }

            // Middle: content
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(store.displayName(for: session))
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if store.hasAlias(session) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                            .help("Renamed in Atelier")
                    }

                    // Hover-revealed rename affordance — discoverable but never noisy.
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(titleHovering ? 0.08 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .help("Rename session")
                    .onHover { titleHovering = $0 }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)

                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                    Text(project.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(relativeTime)
                        .font(.system(size: 12))
                    if let tokens = tokenCount {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(tokens) tokens")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !session.lastMessagePreview.isEmpty {
                    Text(session.lastMessagePreview)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            // Right: primary action
            Button {
                terminals.requestOpenResume(
                    sessionId: session.id,
                    projectCwd: project.cwd,
                    title: store.displayName(for: session)
                )
                store.selectedProject = project
                store.selectedSessionForViewing = session
            } label: {
                HStack(spacing: 6) {
                    Text("Resume")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(hovering ? 0.08 : 0.05),
                            Color.accentColor.opacity(hovering ? 0.04 : 0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(0.18),
                            lineWidth: 0.5
                        )
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            sessionContextMenu(session: session, store: store, onRename: onRename)
        }
    }
}

// MARK: - Mini card (secondary recent sessions)

private struct ContinueMiniCard: View {
    let session: Session
    let project: Project
    let onRename: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController
    @State private var hovering = false

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: session.lastActivity, relativeTo: Date())
    }

    var body: some View {
        Button {
            terminals.requestOpenResume(
                sessionId: session.id,
                projectCwd: project.cwd,
                title: store.displayName(for: session)
            )
            store.selectedProject = project
            store.selectedSessionForViewing = session
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor.opacity(0.85))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(store.displayName(for: session))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if store.hasAlias(session) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor.opacity(0.55))
                        }
                    }

                    HStack(spacing: 4) {
                        Text(project.displayName)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(relativeTime)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            sessionContextMenu(session: session, store: store, onRename: onRename)
        }
    }
}

// MARK: - Shared session context menu (used by home-screen cards)

@MainActor
@ViewBuilder
private func sessionContextMenu(session: Session, store: Store, onRename: @escaping () -> Void) -> some View {
    Button(action: onRename) {
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
    } label: {
        Label("Copy session ID", systemImage: "doc.on.doc")
    }
}

// MARK: - Pinned config bar at bottom of sidebar

struct ConfigBar: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            ConfigBarItem(
                icon: "puzzlepiece.extension",
                label: "Plugins",
                count: store.plugins.filter(\.isEnabled).count,
                isSelected: selection == .plugins
            ) { selection = .plugins }

            ConfigBarItem(
                icon: "sparkles",
                label: "Skills",
                count: store.standaloneSkills.count,
                isSelected: selection == .skills
            ) { selection = .skills }

            ConfigBarItem(
                icon: "server.rack",
                label: "MCPs",
                count: store.standaloneMCPs.count,
                isSelected: selection == .mcps
            ) { selection = .mcps }

            ConfigBarItem(
                icon: "bolt",
                label: "Hooks",
                count: store.hooks.count,
                isSelected: selection == .hooks
            ) { selection = .hooks }

            ConfigBarItem(
                icon: "chart.bar.fill",
                label: "Usage",
                count: 0,
                isSelected: selection == .usage
            ) { selection = .usage }

            ConfigBarItem(
                icon: "bag",
                label: "Market",
                count: 0,
                isSelected: selection == .marketplace
            ) { selection = .marketplace }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct ConfigBarItem: View {
    let icon: String
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // ViewThatFits picks the first layout that fits the available
            // width: full (icon + label below) → compact (icon only). No
            // GeometryReader, no hardcoded breakpoints — SwiftUI evaluates
            // each layout's intrinsic size against the parent constraint.
            ViewThatFits(in: .horizontal) {
                fullLayout
                compactLayout
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// Wide layout: icon stacked above its label. Used when the sidebar
    /// has room (typical default width).
    private var fullLayout: some View {
        VStack(spacing: 3) {
            iconWithBadge
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? .primary : .tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Narrow layout: icon only. Tooltip carries the label name for a11y.
    /// Kicks in automatically when the sidebar is dragged narrow.
    private var compactLayout: some View {
        iconWithBadge
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var iconWithBadge: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .symbolVariant(isSelected ? .fill : .none)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(
                        isSelected ? Color.accentColor : Color.secondary,
                        in: Capsule()
                    )
                    .offset(x: 8, y: -4)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Project row

struct ProjectRow: View {
    let project: Project
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController

    private var projectTokens: Int? {
        let t = store.usageTotals.byProject[project.cwd]?.usage.total ?? 0
        return t > 0 ? t : nil
    }

    /// True if *any* session in this project is running (externally or in Work).
    private var isLive: Bool {
        project.isActive || terminals.isProjectLive(project.cwd)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isLive ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(project.displayName)
                .lineLimit(1)
            Spacer()
            if isLive {
                LivePulseDot(size: 7)
            }
            if let tokens = projectTokens {
                Text(UsageAggregator.format(tokens))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("\(tokens.formatted()) tokens across \(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
            } else {
                Text("\(project.sessions.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sidebar session row (shown when searching)

struct SidebarSessionRow: View {
    let session: Session
    let project: Project
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController

    var body: some View {
        Button {
            store.selectedProject = project
            store.selectedSessionForViewing = session
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName(for: session))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(project.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    terminals.requestOpenResume(
                        sessionId: session.id,
                        projectCwd: project.cwd,
                        title: store.displayName(for: session)
                    )
                    store.selectedProject = project
                    store.selectedSessionForViewing = session
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Resume in place")
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skeleton row

struct SkeletonProjectRow: View {
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 16, height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 13)
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 18, height: 11)
        }
        .padding(.vertical, 6)
        .shimmering()
    }
}

// MARK: - Shimmer

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

struct ShimmerModifier: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.3 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Preferences popover

private struct PreferencesButton: View {
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "gearshape")
        }
        .help("Preferences")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PreferencesPopover()
        }
    }
}

private struct PreferencesPopover: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(TerminalsController.askDangerousModeKey) private var askDangerousMode = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PREFERENCES")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { print("[Work] LaunchAtLogin: \(error)") }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Ask before starting", isOn: $askDangerousMode)
                Text("Pick normal or --dangerously-skip-permissions for every new chat. Turn off to always use normal mode without asking.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 280)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}
