// V2 window state. After #22 the tab list itself lives in TerminalsController
// (one source of truth for both v1 and v2). V2AppState is the per-window
// view-model around it: which project the left rail is focused on, which tab
// is active in *this* window, and the cached `claude` binary resolution.
//
// v1 and v2 may show the same TerminalTab simultaneously. Closing in either
// kills the shared process. Filtering: v1 chrome only renders Mode-A tabs,
// v2 chrome shows both (rendering each according to its surface).

import Foundation
import SwiftUI
import Combine

@MainActor
final class V2AppState: ObservableObject {
    /// Window-local active tab id. Independent of TerminalsController's
    /// activeTabId so the v1 and v2 windows can focus different tabs.
    @Published var activeTabId: UUID? {
        didSet {
            // Viewing a tab marks its result seen — clears the "done · unseen"
            // sage cue. (Design: selecting a done tab clears its sage.)
            if let id = activeTabId { unseenDone.remove(id) }
        }
    }

    /// Tabs whose turn finished while you were looking at a DIFFERENT tab — the
    /// "done · unseen" state. Cleared when the tab is viewed (activeTabId didSet).
    @Published private(set) var unseenDone: Set<UUID> = []

    /// Last seen lifecycle state per tab, so we can detect transitions
    /// (working → ready = a turn finished; → awaitingPermission = blocked).
    private var lastTabState: [UUID: StreamSession.LifecycleState] = [:]

    /// Project the left rail is currently focused on. New tabs spawn here.
    @Published var selectedProjectCwd: URL?
    @Published var selectedProjectName: String = ""

    /// Cached on first appear.
    @Published var claudeBinary: URL?
    @Published var claudeVersion: SemVer?

    /// Left-rail tab — projects list or session-history timeline.
    @Published var railTab: RailTab = .projects

    /// Which main column to render — the chat surface (transcript +
    /// composer) or the full-width Usage report. Toggled by the Usage
    /// workbench tile and the back button in the Usage header.
    @Published var mainView: MainView = .chat

    /// Presents the Add Project modal (triggered from the rail's add buttons
    /// and the empty-state CTA).
    @Published var showAddProject = false

    /// ⌘K search overlay visibility + current query.
    @Published var searchOpen: Bool = false
    @Published var searchQuery: String = ""

    /// Per-tab claude session id we should pass via `--resume` when the tab's
    /// StreamSession starts. Set when a history row opens a new tab; cleared
    /// on tab close.
    @Published private(set) var resumeIds: [UUID: String] = [:]

    /// Models the user has actually used, discovered by scanning
    /// ~/.claude/projects/**/*.jsonl. Empty until the first scan completes;
    /// picker falls back to the active session's model when empty.
    @Published private(set) var discoveredModels: [V2DiscoveredModel] = []

    /// Last-known model catalog from any session's initialize reply — the
    /// binary's own list (aliases, resolved ids, display names). Persisted so
    /// model pickers work BEFORE any session is live and across launches;
    /// refreshed the moment any session inits.
    @Published private(set) var modelCatalog: [V2AvailableModel] = []
    private static let modelCatalogKey = "v2.modelCatalog"

    func updateModelCatalog(_ models: [V2AvailableModel]) {
        guard !models.isEmpty, models != modelCatalog else { return }
        modelCatalog = models
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: Self.modelCatalogKey)
        }
    }

    private func loadPersistedModelCatalog() {
        guard modelCatalog.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.modelCatalogKey),
              let cached = try? JSONDecoder().decode([V2AvailableModel].self, from: data)
        else { return }
        modelCatalog = cached
    }

    /// model id → context window (max_input_tokens), sourced from Anthropic's
    /// Models API — NOT hardcoded. Empty until a fetch succeeds; persisted so
    /// a launch without network still has last-known values. When a model
    /// isn't in here, the context meter shows raw tokens with no percentage.
    @Published private(set) var modelContextWindows: [String: Int] = [:]
    private static let modelWindowsKey = "v2.modelContextWindows"

    /// Default model passed to `claude --model X` on every new spawn. The
    /// user can still flip models mid-session via V2ModelPicker; this
    /// just sets the initial model for fresh sessions and resumes.
    @AppStorage("v2.defaultSpawnModel") var defaultSpawnModel: String = "claude-opus-4-8"

    /// Default permission mode passed to `claude --permission-mode X` on
    /// spawn. Defaults to acceptEdits (claude can edit files without a prompt
    /// per edit, but still asks for riskier tools). Persisted with the same
    /// key StreamSession reads/writes, so a mid-conversation change sticks
    /// for the next spawn. Key must match StreamSession.defaultPermissionKey.
    @AppStorage("v2.defaultPermissionMode") var defaultPermissionMode: String = "acceptEdits"

    /// Right dock collapsed by default — set-once-forget panels (agents /
    /// MCP) burn 360px when the user is just chatting. Expanded mode is
    /// for active loop / harness inspection.
    @AppStorage("v2.dockCollapsed") var dockCollapsed: Bool = true

    /// Which right-dock panel is active (loop / harness / agents / mcp). Lives
    /// here (not as V2RootView @State) so slash commands like /mcp and /agents
    /// can open the matching panel.
    @Published var dockPanel: V2DockPanel = .loop

    /// Open a dock panel and expand the dock — used by /mcp, /agents.
    func openDock(_ panel: V2DockPanel) {
        dockPanel = panel
        dockCollapsed = false
    }

    /// Set once by V2RootView on first appear.
    weak var terminals: TerminalsController?

    enum RailTab: String, CaseIterable, Identifiable {
        case projects, history
        var id: String { rawValue }
    }

    enum MainView: String, Equatable {
        case chat
        case usage
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Per-tab subscriptions to a session's LOW-FREQUENCY signals. Keyed by tab
    /// id so re-subscribing (mode flip / reopen) replaces rather than stacks a
    /// duplicate, and close() can cancel it — the old blanket sinks leaked and
    /// duplicated.
    private var sessionStateSubs: [UUID: AnyCancellable] = [:]

    /// Republish chrome when a tab's session changes state/model/permission/MCP/
    /// retry — NOT on its blanket objectWillChange, which fires on every streamed
    /// token and re-rendered the whole window (rail, tabs, header, dock) for
    /// content that didn't change. The transcript and composer @Observe the
    /// session directly, so they still update live per token; only the chrome
    /// that reflects these specific, low-frequency fields needs the nudge.
    private func observeSessionState(_ session: StreamSession, tabId: UUID) {
        // $state drives tab status + the done/needs-you transitions (and a
        // republish); the other low-frequency fields just republish chrome.
        let stateSub = session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in self?.handleStateTransition(tabId: tabId, to: newState) }
        let otherSignals: [AnyPublisher<Void, Never>] = [
            session.$model.map { _ in () }.eraseToAnyPublisher(),
            session.$permissionMode.map { _ in () }.eraseToAnyPublisher(),
            session.$mcpServers.map { _ in () }.eraseToAnyPublisher(),
            session.$isRetrying.map { _ in () }.eraseToAnyPublisher(),
        ]
        let otherSub = Publishers.MergeMany(otherSignals)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Capture the binary's model catalog app-wide whenever a session inits,
        // so pickers stay current even with no live session.
        let catalogSub = session.$availableModels
            .receive(on: RunLoop.main)
            .sink { [weak self] models in self?.updateModelCatalog(models) }
        sessionStateSubs[tabId] = AnyCancellable { stateSub.cancel(); otherSub.cancel(); catalogSub.cancel() }
    }

    /// Detect tab-status transitions and fire the matching attention cue.
    private func handleStateTransition(tabId: UUID, to newState: StreamSession.LifecycleState) {
        let old = lastTabState[tabId]
        lastTabState[tabId] = newState
        defer { objectWillChange.send() }   // republish so the tab strip re-renders

        // Skip the publisher's initial replay (no real transition yet).
        guard let old else { return }
        let isBackground = (tabId != activeTabId)

        // Needs you: entered awaitingPermission from anything else.
        if case .awaitingPermission = newState, !old.isAwaitingPermission {
            if isBackground { V2Sound.play(.needsYou) }
            return
        }
        // Done · unseen: a turn finished (working → ready) on a tab you weren't
        // looking at.
        if case .ready = newState, case .working = old, isBackground {
            unseenDone.insert(tabId)
            V2Sound.play(.done)
        }
    }

    // MARK: - Setup

    func attach(terminals: TerminalsController) {
        guard self.terminals == nil else { return }
        self.terminals = terminals

        // Re-publish controller changes so v2 chrome reacts to tab churn
        // initiated from v1 or from internal lifecycle events.
        terminals.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Sweep ~/.claude/projects/ for every distinct model the user's history
    /// references and publish the result. Cheap on the main actor since the
    /// scan itself runs detached; we only hop back here to assign.
    func refreshDiscoveredModels() {
        Task.detached(priority: .utility) {
            let models = V2ModelDiscovery.scan()
            await MainActor.run { [weak self] in
                self?.discoveredModels = models
            }
        }
    }

    /// Load any persisted context windows, then refresh from Anthropic's
    /// Models API if an API key is available. No key (OAuth/subscription) ⇒
    /// keep whatever's cached (possibly nothing) and let the meter show
    /// tokens-only. Call once at launch.
    // MARK: - Idle-session hibernation

    /// Background tab idle this long → its claude subprocess is terminated
    /// (each holds 0.4–0.6GB doing nothing) and respawned via --resume on the
    /// next message. 10 minutes: long enough to never interrupt a working
    /// rhythm, short enough that six open tabs stop costing 3GB overnight.
    static let hibernateAfterSeconds: TimeInterval = 10 * 60
    private var hibernationTimer: Timer?

    func startHibernationScanner() {
        guard hibernationTimer == nil else { return }
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop is a formality for Swift 6.
            MainActor.assumeIsolated { self?.hibernateIdleSessions() }
        }
    }

    private func hibernateIdleSessions() {
        let now = Date()
        for tab in tabs {
            // Never the tab the user is looking at — the next message is most
            // likely here, and it shouldn't pay respawn latency.
            guard tab.id != activeTabId,
                  let session = tab.streamSession,
                  session.state == .ready,
                  now.timeIntervalSince(session.lastActivityAt) > Self.hibernateAfterSeconds,
                  // A running co-driven terminal is live user-visible work.
                  CoTerminalManager.shared.terminals(for: session).allSatisfy({ !$0.isRunning })
            else { continue }
            session.hibernate()
        }
    }

    func refreshModelCatalog() {
        // Model catalog: restore the last-known list so pickers work pre-session.
        loadPersistedModelCatalog()
        startHibernationScanner()
        // Baseline: the committed snapshot — keyless, ships in the app.
        var map = V2ModelCatalog.bundledWindows() ?? [:]
        // Overlay a previous live pull, if any (fresher than the snapshot).
        if let data = UserDefaults.standard.data(forKey: Self.modelWindowsKey),
           let cached = try? JSONDecoder().decode([String: Int].self, from: data) {
            map.merge(cached) { _, live in live }
        }
        modelContextWindows = map
        // If (and only if) an API key is present, refresh from the provider
        // and override. No key (OAuth/subscription) ⇒ the snapshot stands.
        Task { [weak self] in
            guard let fresh = await V2ModelCatalog.fetch() else { return }
            await MainActor.run {
                self?.modelContextWindows.merge(fresh) { _, live in live }
                if let data = try? JSONEncoder().encode(fresh) {
                    UserDefaults.standard.set(data, forKey: Self.modelWindowsKey)
                }
            }
        }
    }

    /// Provider-sourced context window for a model id, or nil if unknown.
    /// The 1M-context beta is signalled by "1m" in the id (a client-enabled
    /// capability the Models API doesn't report as a separate entry), so it's
    /// the one documented constant here; everything else comes from the API.
    func contextWindow(for modelId: String) -> Int? {
        // Match the 1M beta as a delimited token ("…[1m]", "…-1m"), not a bare
        // "1m" substring that could match an unrelated id and shadow the
        // provider-sourced value.
        let lc = modelId.lowercased()
        if lc.contains("[1m]") || lc.hasSuffix("-1m") || lc.hasSuffix("_1m") { return 1_000_000 }
        return modelContextWindows[modelId]
    }

    // MARK: - Tab access

    /// All tabs (Mode A and Mode B) — v2 shows both surfaces.
    var tabs: [TerminalTab] { terminals?.tabs ?? [] }

    var activeTab: TerminalTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    var activeSession: StreamSession? { activeTab?.streamSession }

    /// The four-state status for a tab (shared by the tab strip + the title-bar
    /// summary). Selection is separate — that's `activeTabId`.
    func tabStatus(_ tab: TerminalTab) -> V2TabStatus {
        switch tab.surface {
        case .modeA:
            return tab.isLive ? .working : .idle
        case .modeB:
            guard let s = tab.streamSession else { return .idle }
            switch s.state {
            case .working, .spawning, .initializing: return .working
            case .awaitingPermission:                return .needsYou
            default: return unseenDone.contains(tab.id) ? .doneUnseen : .idle
            }
        }
    }

    /// Counts for the title-bar summary readout.
    var tabStatusCounts: (working: Int, done: Int, needs: Int) {
        var w = 0, d = 0, n = 0
        for tab in tabs {
            switch tabStatus(tab) {
            case .working:    w += 1
            case .doneUnseen: d += 1
            case .needsYou:   n += 1
            case .idle:       break
            }
        }
        return (w, d, n)
    }

    // MARK: - Project selection

    func selectProject(cwd: String, name: String) {
        // Clicking a project in the rail ALWAYS lands on its project home —
        // the overview/dashboard — never jumping into an open chat. The model
        // is clean: the rail picks the project (→ home), the tab strip holds
        // open conversations (click a tab to return to one). Clearing
        // activeTabId is what routes the main column to V2ProjectHome.
        selectedProjectCwd = URL(fileURLWithPath: cwd)
        selectedProjectName = name
        activeTabId = nil
        mainView = .chat   // leave the Usage view if we were on it
    }

    // MARK: - Tab management

    /// Create a new Mode-B tab in the selected project. Auto-activates it in
    /// the v2 window (without touching v1's activeTabId).
    func newTab() {
        guard let cwd = selectedProjectCwd, let terminals else { return }
        let id = terminals.openModeB(
            projectCwd: cwd.path,
            title: selectedProjectName.ifEmpty(cwd.lastPathComponent)
        )
        activeTabId = id
        mainView = .chat

        // React to this tab's session state transitions (not per-token churn).
        guard let session = terminals.tabs.first(where: { $0.id == id })?.streamSession else { return }
        observeSessionState(session, tabId: id)

        // Just start it. "New session" means a session — not a tab that then
        // makes you click a second "Start session" button.
        if let binary = claudeBinary {
            session.start(
                cwd: cwd,
                claudeURL: binary,
                model: defaultSpawnModel,
                permissionMode: defaultPermissionMode
            )
        }
    }

    func activate(tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
        mainView = .chat
    }

    /// Open `claude mcp login <server>` in an embedded terminal tab so the
    /// OAuth flow gets a real TTY. Activates it so the user lands on the
    /// terminal and can complete sign-in there.
    func openMCPLogin(serverName: String) {
        guard let terminals else { return }
        let cwd = selectedProjectCwd?.path ?? activeTab?.projectCwd ?? NSHomeDirectory()
        let id = terminals.openMCPLogin(projectCwd: cwd, serverName: serverName)
        activeTabId = id
        mainView = .chat
    }

    /// After an MCP server in `projectCwd` is authenticated, seamlessly
    /// reconnect any LIVE session in that project so the now-authorised server
    /// attaches — without a manual "restart" step. We stop + restart with
    /// --resume (transcript stays on screen, claude reloads context), so the
    /// reconnect reads as the session's normal spawn/initialize loading state
    /// and the server just appears. Idle/terminated sessions are left alone —
    /// they'll pick the server up whenever they next start. Returns how many
    /// live sessions were reconnected.
    @discardableResult
    func reconnectSessions(inProject projectCwd: String, afterAuthOf serverName: String) -> Int {
        guard let binary = claudeBinary else { return 0 }
        let target = URL(fileURLWithPath: projectCwd).standardizedFileURL.path
        var count = 0
        for tab in tabs where tab.surface == .modeB {
            guard let session = tab.streamSession,
                  URL(fileURLWithPath: tab.projectCwd).standardizedFileURL.path == target
            else { continue }
            // Only a live session needs reconnecting.
            switch session.state {
            case .idle, .terminated: continue
            default: break
            }
            let cwd = URL(fileURLWithPath: tab.projectCwd)
            let resume = session.sessionId ?? resumeIds[tab.id]
            session.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                session.start(
                    cwd: cwd,
                    claudeURL: binary,
                    resumeId: resume,
                    model: self.defaultSpawnModel,
                    permissionMode: self.defaultPermissionMode
                )
                session.appendSystemNote("\(serverName) signed in — reconnected.")
            }
            count += 1
        }
        return count
    }

    func close(tabId: UUID) {
        let wasActive = (activeTabId == tabId)
        // Tear down any co-driven terminals BEFORE the tab (and its session)
        // goes away — their processes must not outlive the tab.
        if let session = tabs.first(where: { $0.id == tabId })?.streamSession {
            CoTerminalManager.shared.closeAll(scope: ObjectIdentifier(session))
        }
        _ = terminals?.close(tabId, force: true)
        resumeIds.removeValue(forKey: tabId)
        sessionStateSubs[tabId] = nil   // cancel the state subscription (was leaked)
        lastTabState[tabId] = nil
        unseenDone.remove(tabId)
        if wasActive {
            activeTabId = tabs.last?.id
        }
    }

    /// Change the active session's permission mode. Persists the choice as
    /// the default for future spawns, then applies it to the running session
    /// the right way for each mode:
    ///   • plan / default / acceptEdits — switchable at runtime, applied live
    ///     via set_permission_mode (instant, no restart).
    ///   • bypassPermissions — launch-only for safety; claude won't escalate
    ///     a live session to it. So we restart the session with --resume +
    ///     --permission-mode bypassPermissions: the conversation carries over
    ///     (transcript stays on screen, claude reloads context) and bypass
    ///     actually takes effect instead of silently reverting.
    func changePermissionMode(_ mode: String) {
        defaultPermissionMode = mode  // persist for next spawn (AppStorage)
        guard let tab = activeTab, let session = tab.streamSession else { return }

        let liveSwitchable: Set<String> = ["plan", "default", "acceptEdits"]
        if liveSwitchable.contains(mode) {
            session.setPermissionMode(mode)
            return
        }

        // bypassPermissions → seamless restart preserving the conversation.
        guard let binary = claudeBinary else {
            session.setPermissionMode(mode)  // at least persist + reflect
            return
        }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        let resume = session.sessionId ?? resumeIds[tab.id]
        session.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            session.start(
                cwd: cwd,
                claudeURL: binary,
                resumeId: resume,
                model: self.defaultSpawnModel,
                permissionMode: mode
            )
        }
    }

    /// Reset the active conversation to a clean slate (the `/clear` command).
    /// Unlike clearing only the UI, this restarts the underlying claude
    /// process WITHOUT --resume so the agent's context is genuinely gone —
    /// matching what `/clear` does in the terminal. The transcript is wiped
    /// and a fresh session spawns in the same project / model / mode.
    func clearConversation() {
        guard let tab = activeTab,
              let session = tab.streamSession,
              let binary = claudeBinary else { return }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        // Drop any stashed resume id so the restart can't resurrect context.
        resumeIds.removeValue(forKey: tab.id)
        session.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            session.resetTranscript()
            session.start(
                cwd: cwd,
                claudeURL: binary,
                resumeId: nil,
                model: self.defaultSpawnModel,
                permissionMode: self.defaultPermissionMode
            )
            session.appendSystemNote("Conversation cleared — fresh context.")
        }
    }

    /// Start the active Mode-B tab's session if it's still idle. If the tab
    /// was opened from history we have a resume id stashed in `resumeIds`,
    /// which gets passed to claude as `--resume <id>` so the previous
    /// conversation replays before new turns.
    func startActiveSession() {
        guard let tab = activeTab,
              tab.surface == .modeB,
              let session = tab.streamSession,
              let binary = claudeBinary else { return }
        // Works from .idle AND .terminated — clicking Start on an ended
        // session must actually restart it (the old .idle-only guard made the
        // button a no-op after a failed resume, which felt frozen).
        switch session.state {
        case .idle, .terminated: break
        default: return
        }
        // If the previous attempt failed to resume (history gone, etc.), start
        // FRESH — re-resuming the same dead id would just fail again.
        let resume = session.endError == nil ? resumeIds[tab.id] : nil
        if session.endError != nil { resumeIds.removeValue(forKey: tab.id) }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        session.start(
            cwd: cwd,
            claudeURL: binary,
            resumeId: resume,
            model: defaultSpawnModel,
            permissionMode: defaultPermissionMode
        )
    }

    /// Open a tab that resumes a known claude session. Used by V2HistoryRail
    /// and V2SearchOverlay when the user clicks an entry. Auto-starts the
    /// session — there's no point making them click "Start" again on a tab
    /// they explicitly chose to resume.
    func openHistorySession(sessionId: String, projectCwd: String, projectName: String, title: String) {
        guard let terminals else { return }
        // Don't spawn a duplicate. If a tab is already resuming this session
        // (e.g. the user double-clicked the history row), just activate the
        // existing one — clicking twice should never open two identical tabs.
        if let existing = tabs.first(where: {
            resumeIds[$0.id] == sessionId || $0.streamSession?.sessionId == sessionId
        }) {
            activeTabId = existing.id
            mainView = .chat
            selectedProjectCwd = URL(fileURLWithPath: projectCwd)
            selectedProjectName = projectName.isEmpty
                ? (projectCwd as NSString).lastPathComponent
                : projectName
            // The row IS the start button: if that tab's session has ended (or
            // never started), clicking it (re)starts it rather than dropping
            // you on a dead "stream closed" + Start CTA.
            if let session = existing.streamSession, let binary = claudeBinary {
                switch session.state {
                case .idle, .terminated:
                    session.resume(cwd: URL(fileURLWithPath: projectCwd), claudeURL: binary,
                                   sessionId: sessionId, model: defaultSpawnModel,
                                   permissionMode: defaultPermissionMode)
                default:
                    break
                }
            }
            return
        }
        let id = terminals.openModeB(projectCwd: projectCwd, title: title.isEmpty ? projectName : title)
        resumeIds[id] = sessionId
        activeTabId = id
        mainView = .chat
        // Keep the rail's project selection in sync with the tab we just
        // opened, so the PROJECTS highlight + the ⌘N "new chat" target
        // follow you into the resumed session's project.
        selectedProjectCwd = URL(fileURLWithPath: projectCwd)
        selectedProjectName = projectName.isEmpty
            ? (projectCwd as NSString).lastPathComponent
            : projectName

        if let session = terminals.tabs.first(where: { $0.id == id })?.streamSession {
            observeSessionState(session, tabId: id)
        }
        // Eagerly resume — user explicitly picked this session. resume()
        // reads the (possibly large) history OFF the main thread and flips
        // `isResuming` so the UI shows a loading state instead of freezing.
        if let session = terminals.tabs.first(where: { $0.id == id })?.streamSession,
           let binary = claudeBinary {
            session.resume(
                cwd: URL(fileURLWithPath: projectCwd),
                claudeURL: binary,
                sessionId: sessionId,
                model: defaultSpawnModel,
                permissionMode: defaultPermissionMode
            )
        }
    }

    /// Flip the active tab between Mode A and Mode B.
    func flipActiveMode() {
        guard let id = activeTabId else { return }
        terminals?.flipSurface(tabId: id)

        // Re-subscribe to the new StreamSession's state (B→A creates one,
        // A→B nils it). Keyed by tab id, so the flip replaces the prior sub.
        if let session = terminals?.tabs.first(where: { $0.id == id })?.streamSession {
            observeSessionState(session, tabId: id)
        }
    }

    func flipMode(tabId: UUID) {
        terminals?.flipSurface(tabId: tabId)
        if let session = terminals?.tabs.first(where: { $0.id == tabId })?.streamSession {
            observeSessionState(session, tabId: tabId)
        }
    }

    // MARK: - Loop attachment

    /// Set / clear the loop on a tab. Re-publishes loop state changes so
    /// the dock panel reacts to lifecycle transitions.
    func attachLoop(_ loop: LoopOrchestrator?, toTab tabId: UUID) {
        guard let terminals,
              let existing = terminals.tabs.first(where: { $0.id == tabId }) else { return }
        // Stop any previous loop on this tab before swapping.
        existing.loop?.stop()
        terminals.setLoop(loop, on: tabId)

        if let loop {
            loop.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        objectWillChange.send()
    }

    func attachHarness(_ harness: HarnessOrchestrator?, toTab tabId: UUID) {
        guard let terminals,
              let existing = terminals.tabs.first(where: { $0.id == tabId }) else { return }
        existing.harness?.stop()
        terminals.setHarness(harness, on: tabId)

        if let harness {
            harness.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        objectWillChange.send()
    }

    // MARK: - Binary resolution

    func resolveBinary() {
        guard claudeBinary == nil else { return }
        let url = ClaudeBinary.locate()
        claudeBinary = url
        if let url { claudeVersion = ClaudeBinary.version(at: url) }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension StreamSession.LifecycleState {
    var isAwaitingPermission: Bool {
        if case .awaitingPermission = self { return true }
        return false
    }
}
