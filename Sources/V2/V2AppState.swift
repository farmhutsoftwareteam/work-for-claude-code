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
import OSLog

@MainActor
final class V2AppState: ObservableObject {
    private let log = Logger(subsystem: "com.munyamakosa.work", category: "workspace")
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
    /// Lifecycle history is provider-scoped because a dual-slot tab retains
    /// both sessions. An inactive provider may finish teardown after the active
    /// provider has already started a turn; sharing one value would corrupt the
    /// active provider's working -> ready completion transition.
    private var lastTabState: [UUID: [V2AgentProvider: StreamSession.LifecycleState]] = [:]

    /// Project the left rail is currently focused on. New tabs spawn here.
    @Published var selectedProjectCwd: URL?
    @Published var selectedProjectName: String = ""

    /// Cached on first appear.
    @Published var claudeBinary: URL?
    @Published var claudeVersion: SemVer?
    @Published var codexBinary: URL?
    @Published var codexVersion: SemVer?

    /// Claude's real sign-in status/flow — see ClaudeAuthManager's header
    /// for why this exists as its own object rather than living on
    /// StreamSession: auth has to be checkable/fixable BEFORE any session
    /// spawn is attempted, not discovered from one failing.
    let claudeAuth = ClaudeAuthManager()

    /// Runtime used by the plain + button / ⌘N. Menus can still explicitly
    /// create either provider without changing this preference.
    @AppStorage("v2.defaultAgentProvider") var defaultAgentProviderRaw = V2AgentProvider.claude.rawValue
    @AppStorage("v2.defaultCodexModel") var defaultCodexModel = ""
    @AppStorage("v2.defaultCodexEffort") var defaultCodexEffort = ""
    @AppStorage("v2.defaultCodexApprovalPolicy") var defaultCodexApprovalPolicy = "on-request"

    var defaultAgentProvider: V2AgentProvider {
        get { V2AgentProvider(rawValue: defaultAgentProviderRaw) ?? .claude }
        set { defaultAgentProviderRaw = newValue.rawValue }
    }

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

    /// Codex's native thread id is a different namespace from Claude session
    /// UUIDs. Keeping it in a typed sibling map prevents a provider switch from
    /// overwriting (or accidentally passing) the other provider's identity.
    @Published private(set) var codexResumeIds: [UUID: String] = [:]

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

    /// Default `--effort` passed on spawn. "" omits the flag — the CLI's own
    /// default applies. Unlike model, there's no live switch for an ALREADY
    /// running session (verified: no set_effort-style control request
    /// exists, and system/init never reports an effort catalog) — see
    /// changeEffort(_:), which always restarts rather than picking a
    /// live-switchable subset the way changePermissionMode does.
    @AppStorage("v2.defaultSpawnEffort") var defaultSpawnEffort: String = ""

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
    private var codexSessionStateSubs: [UUID: AnyCancellable] = [:]
    private var workspacePersistTask: Task<Void, Never>?

    /// In-flight stop-then-restart Tasks (reconnect / permission-mode change
    /// / clear conversation), keyed by tab id so close(tabId:) can cancel one
    /// instead of letting a captured `session` restart into a process
    /// nothing references anymore (bug-hunt H2).
    private var pendingRestarts: [UUID: Task<Void, Never>] = [:]

    /// Per-tab subscriptions to a loop/harness orchestrator's objectWillChange
    /// (same discipline as `sessionStateSubs`). Keyed by tab id so attaching a
    /// new loop/harness — or clearing one via `attachLoop(nil, …)` /
    /// `attachHarness(nil, …)` — replaces rather than stacks a duplicate sub
    /// into the unbounded `cancellables` Set, and close(tabId:) can cancel it.
    /// Assigning `nil` cancels the previous subscription (AnyCancellable
    /// cancels on dealloc).
    private var loopSubs: [UUID: AnyCancellable] = [:]
    private var harnessSubs: [UUID: AnyCancellable] = [:]

    /// Tabs still finishing their launch-restore preload (each lands in
    /// .hibernated at a staggered async moment). While this is non-empty a
    /// restore burst is in flight: a BACKGROUND tab landing shouldn't
    /// republish the whole window, because each republish re-renders the
    /// ACTIVE tab's transcript mid-settle — and with N restored tabs that's
    /// N−1 extra re-renders, each nudging the bottom-anchored LazyVStack's
    /// still-unstable height estimate. That is the multi-tab launch scroll
    /// bounce. We collapse the burst into ONE republish (emitted when the
    /// last restore lands, or by the safety timeout) instead of one per tab.
    /// Empty in all normal (non-launch) operation, so live use is unaffected.
    private var restorePendingTabs: Set<UUID> = []

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
            .sink { [weak self] newState in
                self?.handleStateTransition(tabId: tabId, provider: .claude, to: newState)
            }
        let otherSignals: [AnyPublisher<Void, Never>] = [
            session.$model.map { _ in () }.eraseToAnyPublisher(),
            session.$permissionMode.map { _ in () }.eraseToAnyPublisher(),
            session.$mcpServers.map { _ in () }.eraseToAnyPublisher(),
            session.$isRetrying.map { _ in () }.eraseToAnyPublisher(),
            // Without these two, a background task/subagent finishing while
            // $state stays .ready never republishes chrome — the tab strip's
            // workingBackground pill and title-bar tally go stale until an
            // unrelated re-render coincidentally fires (M17).
            session.$backgroundTasks.map { _ in () }.eraseToAnyPublisher(),
            session.$subagentRuns.map { _ in () }.eraseToAnyPublisher(),
            // Plan-usage meters land at turn-end cadence — low-frequency by
            // construction, safe to fan into chrome republish (perf §2).
            session.$usageLimits.map { _ in () }.eraseToAnyPublisher(),
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

    /// Codex follows the same low-frequency fan-out rule as Claude: chrome
    /// observes lifecycle/config/MCP changes, never transcript deltas.
    private func observeCodexSessionState(_ session: CodexSession, tabId: UUID) {
        let stateSub = session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleStateTransition(tabId: tabId, provider: .codex, to: state)
            }
        let otherSub = Publishers.MergeMany([
            session.$model.map { _ in () }.eraseToAnyPublisher(),
            session.$effort.map { _ in () }.eraseToAnyPublisher(),
            session.$permissionMode.map { _ in () }.eraseToAnyPublisher(),
            session.$account.map { _ in () }.eraseToAnyPublisher(),
            session.$mcpServers.map { _ in () }.eraseToAnyPublisher(),
            session.$usageLimits.map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        codexSessionStateSubs[tabId] = AnyCancellable { stateSub.cancel(); otherSub.cancel() }
    }

    /// Detect tab-status transitions and fire the matching attention cue.
    private func handleStateTransition(
        tabId: UUID,
        provider: V2AgentProvider,
        to newState: StreamSession.LifecycleState
    ) {
        let old = lastTabState[tabId]?[provider]
        lastTabState[tabId, default: [:]][provider] = newState

        // A restoring tab reaching any non-idle state has finished its
        // preload — drop it from the in-flight set (see restorePendingTabs).
        var settledIdle = true
        if case .idle = newState { settledIdle = false }
        if settledIdle, restorePendingTabs.contains(tabId) {
            restorePendingTabs.remove(tabId)
        }
        // Collapse the launch-restore burst: while restore is in flight,
        // suppress a BACKGROUND tab's republish (it only cosmetically flips a
        // tab-strip dot, but it re-renders the active transcript mid-settle).
        // The active tab still republishes — that's a single, wanted render —
        // and the last-restore-to-land republishes once for everyone else.
        let restoreInFlight = !restorePendingTabs.isEmpty
        let suppressRepublish = restoreInFlight && tabId != activeTabId
        defer { if !suppressRepublish { objectWillChange.send() } }

        // Persist on every lifecycle transition — this is what captures a new
        // session's id the moment the init reply reports it (newTab spawns
        // before any id exists), plus hibernations, terminations, restarts.
        persistWorkspace()

        // Skip the publisher's initial replay (no real transition yet).
        guard let old else { return }
        // Retained inactive sessions still publish teardown states. Persist
        // those native ids, but never let them drive the active tab's sounds or
        // unseen markers.
        guard tabs.first(where: { $0.id == tabId })?.provider == provider else { return }
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
            // Suppress the "done" chime while a background task/subagent this
            // turn kicked off is still running — the tab isn't actually done
            // yet (tabStatus shows .workingBackground for exactly this case),
            // so playing the completion sound here would be a false cue. The
            // unseenDone mark stays so .doneUnseen still surfaces once that
            // background work finishes (see tabStatus's M16 comment).
            let session = tabs.first(where: { $0.id == tabId })?.streamSession
            let hasActiveBackgroundWork = session.map {
                $0.backgroundTasks.contains(where: { $0.state == .running })
                    || $0.subagentRuns.contains(where: { $0.state == .running && $0.isBackground })
            } ?? false
            if !hasActiveBackgroundWork {
                V2Sound.play(.done)
            }
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
            guard tab.id != activeTabId else { continue }
            if let session = tab.streamSession,
               session.state == .ready,
               now.timeIntervalSince(session.lastActivityAt) > Self.hibernateAfterSeconds,
               // A running co-driven terminal is live user-visible work.
               CoTerminalManager.shared.terminals(for: session).allSatisfy({ !$0.isRunning }) {
                session.hibernate()
            }
            // A Codex app-server is a real process too, and an idle one on a
            // background tab is as reclaimable as an idle claude. Both slots
            // are checked because a tab retains both independently of which
            // provider is currently active on it.
            if let codex = tab.codexSession,
               codex.state == .ready,
               now.timeIntervalSince(codex.lastActivityAt) > Self.hibernateAfterSeconds {
                codex.hibernate()
            }
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

    var activeSession: StreamSession? {
        guard activeTab?.provider == .claude else { return nil }
        return activeTab?.streamSession
    }

    var activeCodexSession: CodexSession? {
        guard activeTab?.provider == .codex else { return nil }
        return activeTab?.codexSession
    }

    /// The four-state status for a tab (shared by the tab strip + the title-bar
    /// summary). Selection is separate — that's `activeTabId`.
    func tabStatus(_ tab: TerminalTab) -> V2TabStatus {
        switch tab.surface {
        case .modeA:
            return tab.isLive ? .working : .idle
        case .modeB:
            if tab.provider == .codex {
                guard let s = tab.codexSession else { return .idle }
                switch s.state {
                case .working, .spawning, .initializing: return .working
                case .awaitingPermission: return .needsYou
                default: return unseenDone.contains(tab.id) ? .doneUnseen : .idle
                }
            }
            guard let s = tab.streamSession else { return .idle }
            // Observer tabs: never .working (that implies OUR process is
            // busy) — "present, not urgent" while the observed file is
            // fresh, idle once it's gone quiet.
            if s.isObserving {
                if let grew = s.observedFileLastGrewAt, Date().timeIntervalSince(grew) < 90 {
                    return .workingBackground
                }
                return .idle
            }
            switch s.state {
            case .working, .spawning, .initializing: return .working
            case .awaitingPermission:                return .needsYou
            default:
                // Background task/subagent takes precedence over unseenDone:
                // handleStateTransition marks a finished-while-backgrounded
                // turn as unseenDone unconditionally, so checking that first
                // would show "done" even while a task it started is still
                // running — masking the intended "present, not urgent"
                // workingBackground state until the tab is manually viewed
                // once (M16). Once the task finishes, this falls through to
                // the unseenDone check below and .doneUnseen still surfaces.
                if s.backgroundTasks.contains(where: { $0.state == .running }) { return .workingBackground }
                if s.subagentRuns.contains(where: { $0.state == .running && $0.isBackground }) { return .workingBackground }
                if unseenDone.contains(tab.id) { return .doneUnseen }
                return .idle
            }
        }
    }

    /// Counts for the title-bar summary readout.
    var tabStatusCounts: (working: Int, done: Int, needs: Int) {
        var w = 0, d = 0, n = 0
        for tab in tabs {
            switch tabStatus(tab) {
            case .working:            w += 1
            case .doneUnseen:         d += 1
            case .needsYou:           n += 1
            case .idle, .workingBackground: break
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

    // MARK: - Workspace restore (Chrome-style, process-free)

    /// What survives a quit: each Mode-B tab that has a real claude session
    /// behind it. Mode-A tabs are live PTYs — nothing to restore them TO —
    /// and a Mode-B tab that never started a session isn't worth a slot.
    struct WorkspaceSnapshot: Codable {
        struct TabEntry: Codable {
            let projectCwd: String
            let title: String
            /// Legacy/current active-provider id. Retained so v2.10.0
            /// snapshots continue to decode and older builds have a fallback.
            let sessionId: String
            /// Optional so snapshots written before multi-provider support
            /// continue to decode as Claude.
            let provider: V2AgentProvider?
            let draft: String?
            /// Typed provider slots added after v2.10.0. Optional fields make
            /// decoding the original single-id snapshot format non-breaking.
            let claudeSessionId: String?
            let codexThreadId: String?
            let claudeDraft: String?
            let codexDraft: String?
            let providerSlotsVersion: Int?
        }
        let tabs: [TabEntry]
        let activeSessionId: String?
    }
    private static let workspaceKey = "v2.workspace"
    private static var workspaceFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.munyamakosa.work", isDirectory: true)
            .appendingPathComponent("v2-workspace.json")
    }

    /// Continuously persisted (every tab open/close/activate + every session
    /// state transition), not saved-on-quit — a crash or force-quit loses
    /// nothing. The payload is a handful of strings; encoding it on these
    /// low-frequency events is effectively free.
    func persistWorkspace() {
        let entries: [WorkspaceSnapshot.TabEntry] = tabs.compactMap { tab in
            guard tab.surface == .modeB else { return nil }
            // Observer tabs never persist — restoring one later as a normal
            // hibernated tab would give it a wake-via-resume path into a
            // session another process owns (#76's takeover rule).
            guard tab.streamSession?.isObserving != true else { return nil }
            let claudeId = tab.streamSession?.sessionId ?? resumeIds[tab.id]
            let codexId = tab.codexSession?.threadId ?? codexResumeIds[tab.id]
            let activeId = tab.provider == .codex ? codexId : claudeId
            guard let sid = activeId ?? claudeId ?? codexId else { return nil }
            let draft = tab.provider == .codex ? tab.codexSession?.composerDraft : tab.streamSession?.composerDraft
            return .init(
                projectCwd: tab.projectCwd,
                title: tab.title,
                sessionId: sid,
                provider: tab.provider,
                draft: draft,
                claudeSessionId: claudeId,
                codexThreadId: codexId,
                claudeDraft: tab.streamSession?.composerDraft,
                codexDraft: tab.codexSession?.composerDraft,
                providerSlotsVersion: 1
            )
        }
        let active = activeTabId
            .flatMap { id in tabs.first { $0.id == id } }
            .flatMap { tab in
                tab.provider == .codex
                    ? (tab.codexSession?.threadId ?? codexResumeIds[tab.id])
                    : (tab.streamSession?.sessionId ?? resumeIds[tab.id])
            }
        let snapshot = WorkspaceSnapshot(tabs: entries, activeSessionId: active)
        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: Self.workspaceKey)
            let url = Self.workspaceFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Workspace checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Draft edits are high-frequency; checkpoint after a short quiet window
    /// instead of encoding and writing on every keystroke.
    func scheduleWorkspacePersist() {
        workspacePersistTask?.cancel()
        workspacePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persistWorkspace()
        }
    }

    /// Reopen the previous workspace — every tab lands HIBERNATED: transcript
    /// preloaded from disk (one bounded file read per tab), composer live,
    /// header reading "Resting", and NO claude subprocess until the first
    /// message wakes that tab via --resume. Restoring six tabs costs six
    /// file reads and zero of the 0.4-0.6GB processes — the performance
    /// concern that blocked this feature is what hibernation already solved.
    func restoreWorkspaceIfNeeded() {
        guard tabs.isEmpty, let terminals else { return }
        let candidates = [
            UserDefaults.standard.data(forKey: Self.workspaceKey),
            try? Data(contentsOf: Self.workspaceFileURL)
        ].compactMap { $0 }
        guard let snapshot = candidates.lazy.compactMap({ try? JSONDecoder().decode(WorkspaceSnapshot.self, from: $0) }).first,
              !snapshot.tabs.isEmpty else { return }

        var activeCandidate: UUID?
        for entry in snapshot.tabs {
            let preferredProvider = entry.provider ?? .claude
            let hasTypedSlots = entry.providerSlotsVersion != nil
            let claudeId = hasTypedSlots
                ? entry.claudeSessionId
                : (preferredProvider == .claude ? entry.sessionId : nil)
            let codexId = hasTypedSlots
                ? entry.codexThreadId
                : (preferredProvider == .codex ? entry.sessionId : nil)

            let claudeTranscript = claudeId.map {
                SessionHistoryLoader.jsonlURL(sessionId: $0, projectCwd: entry.projectCwd)
            }
            let claudeAvailable = claudeId != nil
                && claudeBinary != nil
                && claudeTranscript.map { FileManager.default.fileExists(atPath: $0.path) } == true
            let codexAvailable = codexId != nil && codexBinary != nil
            guard let provider = Self.restoredProvider(
                preferred: preferredProvider,
                claudeAvailable: claudeAvailable,
                codexAvailable: codexAvailable
            ) else { continue }

            let id = terminals.openModeB(
                projectCwd: entry.projectCwd,
                title: entry.title,
                provider: provider
            )

            if claudeAvailable, let claudeId, let binary = claudeBinary {
                resumeIds[id] = claudeId
                let session = terminals.tabs.first(where: { $0.id == id })?.streamSession ?? StreamSession()
                session.composerDraft = entry.claudeDraft
                    ?? (provider == .claude ? entry.draft : nil)
                    ?? ""
                terminals.setClaudeSession(session, on: id, activate: false)
                // Mark BEFORE the async restore is kicked off so its later,
                // staggered .hibernated landing is collapsed into one chrome
                // republish even when Claude is the retained inactive slot.
                restorePendingTabs.insert(id)
                observeSessionState(session, tabId: id)
                session.restoreHibernated(
                    cwd: URL(fileURLWithPath: entry.projectCwd), claudeURL: binary,
                    sessionId: claudeId, model: defaultSpawnModel,
                    permissionMode: defaultPermissionMode, effort: defaultSpawnEffort
                )
            }

            if codexAvailable, let codexId, let binary = codexBinary {
                codexResumeIds[id] = codexId
                let session = terminals.tabs.first(where: { $0.id == id })?.codexSession ?? CodexSession()
                session.composerDraft = entry.codexDraft
                    ?? (provider == .codex ? entry.draft : nil)
                    ?? ""
                terminals.setCodexSession(session, on: id, activate: false)
                // Same burst-collapse marking as the Claude slot above —
                // staggered .hibernated landings are one chrome republish,
                // not one per tab.
                restorePendingTabs.insert(id)
                observeCodexSessionState(session, tabId: id)
                // Hibernate rather than start: the conversation comes back
                // on screen and the first message wakes it. Previously only
                // the active Codex tab was started and every other restored
                // Codex tab showed a "Start session" button over an empty
                // pane, while Claude tabs restored their transcript.
                session.restoreHibernated(
                    threadId: codexId,
                    cwd: URL(fileURLWithPath: entry.projectCwd),
                    codexURL: binary,
                    model: defaultCodexModel,
                    permissionMode: defaultCodexApprovalPolicy,
                    effort: defaultCodexEffort
                )
            }
            if entry.sessionId == snapshot.activeSessionId { activeCandidate = id }
        }
        guard let id = activeCandidate ?? tabs.last?.id else { return }
        activeTabId = id
        mainView = .chat
        if let tab = tabs.first(where: { $0.id == id }) {
            selectedProjectCwd = URL(fileURLWithPath: tab.projectCwd)
            selectedProjectName = (tab.projectCwd as NSString).lastPathComponent
            // The active Codex tab used to be started here — the one tab
            // that escaped the Start-button problem. It now hibernates with
            // every other tab (above), so launch spawns no agent at all and
            // the first message wakes whichever tab you actually use.
        }
        // Safety net: if any restore never lands (transcript vanished mid-
        // launch, spawn wedged), don't leave the burst permanently "in
        // flight" — that would suppress every future background-tab republish.
        // Clear it after a bounded window and do one catch-up republish.
        if !restorePendingTabs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.restorePendingTabs.isEmpty else { return }
                self.restorePendingTabs.removeAll()
                self.objectWillChange.send()
            }
        }
    }

    /// Pick the saved active provider when possible, but never discard a valid
    /// retained slot just because that preferred runtime is missing today.
    static func restoredProvider(
        preferred: V2AgentProvider,
        claudeAvailable: Bool,
        codexAvailable: Bool
    ) -> V2AgentProvider? {
        switch preferred {
        case .claude:
            if claudeAvailable { return .claude }
            if codexAvailable { return .codex }
        case .codex:
            if codexAvailable { return .codex }
            if claudeAvailable { return .claude }
        }
        return nil
    }

    // MARK: - Tab management

    /// Open a READ-ONLY live view of a session another process owns (#74) —
    /// the observed transcript streams in off its growing .jsonl; no claude
    /// process is spawned and nothing can be sent (see StreamSession's
    /// isObserving gates). If the session is already open in ANY tab
    /// (normal or observer), focus that instead of double-opening.
    func openObserver(projectCwd: String, sessionId: String, title: String) {
        guard let terminals else { return }
        if let existing = tabs.first(where: {
            $0.surface == .modeB &&
            ($0.streamSession?.sessionId == sessionId || resumeIds[$0.id] == sessionId)
        }) {
            activate(tabId: existing.id)
            return
        }
        let id = terminals.openModeB(projectCwd: projectCwd, title: title)
        guard let session = terminals.tabs.first(where: { $0.id == id })?.streamSession else { return }
        observeSessionState(session, tabId: id)
        session.startObserving(cwd: URL(fileURLWithPath: projectCwd), sessionId: sessionId)
        activate(tabId: id)
    }

    /// Create a new Mode-B tab in the selected project. Auto-activates it in
    /// the v2 window (without touching v1's activeTabId).
    func newTab(provider explicitProvider: V2AgentProvider? = nil) {
        guard let cwd = selectedProjectCwd, let terminals else { return }
        let provider = explicitProvider ?? defaultAgentProvider
        let id = terminals.openModeB(
            projectCwd: cwd.path,
            title: selectedProjectName.ifEmpty(cwd.lastPathComponent),
            provider: provider
        )
        activeTabId = id
        mainView = .chat

        let tab = terminals.tabs.first(where: { $0.id == id })
        switch provider {
        case .claude:
            guard let session = tab?.streamSession else { return }
            observeSessionState(session, tabId: id)
            if let binary = claudeBinary {
                session.start(
                    cwd: cwd, claudeURL: binary, model: defaultSpawnModel,
                    permissionMode: defaultPermissionMode, effort: defaultSpawnEffort
                )
            }
        case .codex:
            guard let session = tab?.codexSession else { return }
            observeCodexSessionState(session, tabId: id)
            if let binary = codexBinary {
                session.start(
                    cwd: cwd, codexURL: binary, model: defaultCodexModel,
                    permissionMode: defaultCodexApprovalPolicy, effort: defaultCodexEffort
                )
            }
        }
    }

    /// Continue the active tab with the other runtime. Provider-native thread
    /// IDs are not portable, so the destination receives a bounded checkpoint
    /// of the visible transcript on its next user turn.
    func switchActiveProvider(to target: V2AgentProvider) {
        guard let tab = activeTab, tab.surface == .modeB, tab.provider != target,
              let terminals else { return }
        switch target {
        case .claude: guard claudeBinary != nil else { return }
        case .codex: guard codexBinary != nil else { return }
        }

        let sourceTranscript: [TranscriptItem]
        switch tab.provider {
        case .claude:
            guard let source = tab.streamSession else { return }
            switch source.state {
            case .working, .awaitingPermission, .spawning, .initializing, .closing: return
            default: break
            }
            sourceTranscript = source.transcript
            if let id = source.sessionId { resumeIds[tab.id] = id }
            source.stop()
        case .codex:
            guard let source = tab.codexSession else { return }
            switch source.state {
            case .working, .awaitingPermission, .spawning, .initializing, .closing: return
            default: break
            }
            sourceTranscript = source.transcript
            if let id = source.threadId { codexResumeIds[tab.id] = id }
            source.stop()
        }

        let checkpoint = ProviderHandoff.checkpoint(
            from: tab.provider, projectCwd: tab.projectCwd, transcript: sourceTranscript
        )
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        switch target {
        case .claude:
            guard let binary = claudeBinary else { return }
            let replacement = tab.streamSession ?? StreamSession()
            replacement.setProviderHandoffContext(checkpoint)
            replacement.adoptProviderTimeline(sourceTranscript, from: tab.provider)
            terminals.setClaudeSession(replacement, on: tab.id)
            observeSessionState(replacement, tabId: tab.id)
            replacement.start(
                cwd: cwd, claudeURL: binary,
                resumeId: replacement.sessionId ?? resumeIds[tab.id],
                model: defaultSpawnModel,
                permissionMode: defaultPermissionMode, effort: defaultSpawnEffort
            )
        case .codex:
            guard let binary = codexBinary else { return }
            let replacement = tab.codexSession ?? CodexSession()
            replacement.setProviderHandoffContext(checkpoint)
            replacement.adoptProviderTimeline(sourceTranscript, from: tab.provider)
            terminals.setCodexSession(replacement, on: tab.id)
            observeCodexSessionState(replacement, tabId: tab.id)
            replacement.start(
                cwd: cwd, codexURL: binary,
                resumeId: replacement.threadId ?? codexResumeIds[tab.id],
                model: defaultCodexModel,
                permissionMode: defaultCodexApprovalPolicy, effort: defaultCodexEffort
            )
        }
        let retained = terminals.tabs.first(where: { $0.id == tab.id })
        log.notice("Provider switch retained tab \(tab.id.uuidString, privacy: .private): \(tab.provider.displayName, privacy: .public) -> \(target.displayName, privacy: .public); Claude slot=\(retained?.streamSession != nil, privacy: .public), Codex slot=\(retained?.codexSession != nil, privacy: .public)")
        persistWorkspace()
        objectWillChange.send()
    }

    func activate(tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
        mainView = .chat
        persistWorkspace()
    }

    /// ⌘1…⌘9 — jump to the Nth open tab, 1-based, in strip order (both
    /// surfaces mixed, same order V2SessionTabs renders `tabs` in).
    func activateTab(atPosition oneBased: Int) {
        let i = oneBased - 1
        guard tabs.indices.contains(i) else { return }
        activate(tabId: tabs[i].id)
    }

    /// ⌘]/⌘[ — cycle the active tab by `delta` (+1 / -1), wrapping.
    func cycleActiveTab(delta: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = activeTabId, let idx = tabs.firstIndex(where: { $0.id == current }) else {
            activate(tabId: tabs[0].id)
            return
        }
        let next = (idx + delta + tabs.count) % tabs.count
        activate(tabId: tabs[next].id)
    }

    /// Open `claude mcp login <server>` in an embedded terminal tab so the
    /// OAuth flow gets a real TTY. Activates it so the user lands on the
    /// terminal and can complete sign-in there.
    func openMCPLogin(serverName: String) {
        guard let terminals else { return }
        // Active tab wins — same reasoning as V2McpPanel.projectCwd: the rail's
        // selectedProjectCwd is a stale, unrelated selection once a tab is
        // open, and this sign-in terminal must land in whichever project the
        // needs-auth server actually belongs to.
        let cwd = activeTab?.projectCwd ?? selectedProjectCwd?.path ?? NSHomeDirectory()
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
            // An observer has no process of ours to reconnect — and
            // restart-with-resume here IS the takeover path it must never
            // take (its replayed init events can make state read .ready).
            guard !session.isObserving else { continue }
            // Only a live session needs reconnecting.
            switch session.state {
            case .idle, .terminated: continue
            default: break
            }
            let cwd = URL(fileURLWithPath: tab.projectCwd)
            let resume = session.sessionId ?? resumeIds[tab.id]
            let model = defaultSpawnModel
            let mode = defaultPermissionMode
            restartAfterStop(tabId: tab.id, session: session) {
                session.start(cwd: cwd, claudeURL: binary, resumeId: resume, model: model, permissionMode: mode)
                session.appendSystemNote("\(serverName) signed in — reconnected.")
            }
            count += 1
        }
        return count
    }

    /// Stops `session`, waits for teardown to actually finish (polls
    /// `state` instead of guessing a fixed delay), then runs `restart`.
    /// The old fixed 0.45s wait either fired the restart too early —
    /// silently no-op'ing against StreamSession.start()'s state guard when
    /// teardown ran long — or too late, after a tab close, spawning a fresh
    /// process for a `session` nothing references anymore (bug-hunt H2).
    /// Storing the Task in `pendingRestarts` lets close(tabId:) cancel it.
    /// Internal (not private) — V2SessionHeader.restartActiveSession had its
    /// own separate, still-broken copy of this exact pattern; it now calls
    /// this one instead of carrying a 4th duplicate.
    func restartAfterStop(tabId: UUID, session: StreamSession, restart: @escaping () -> Void) {
        pendingRestarts[tabId]?.cancel()
        session.stop()
        pendingRestarts[tabId] = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(3)
            while !Task.isCancelled, Date() < deadline {
                switch session.state {
                case .terminated, .idle:
                    restart()
                    self?.pendingRestarts[tabId] = nil
                    return
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            // Timed out or cancelled — don't restart into a half-torn-down
            // session; leave it for the user to retry rather than guess.
            self?.pendingRestarts[tabId] = nil
        }
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
        codexResumeIds.removeValue(forKey: tabId)
        sessionStateSubs[tabId] = nil   // cancel the state subscription (was leaked)
        codexSessionStateSubs[tabId] = nil
        loopSubs[tabId] = nil           // cancel any loop objectWillChange sub (was leaked)
        harnessSubs[tabId] = nil        // cancel any harness objectWillChange sub (was leaked)
        pendingRestarts[tabId]?.cancel()
        pendingRestarts[tabId] = nil
        lastTabState[tabId] = nil
        unseenDone.remove(tabId)
        if wasActive {
            activeTabId = tabs.last?.id
        }
        persistWorkspace()
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
        if let codex = activeCodexSession {
            defaultCodexApprovalPolicy = mode
            codex.setPermissionMode(mode)
            return
        }
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
        let model = defaultSpawnModel
        let effort = session.effort
        restartAfterStop(tabId: tab.id, session: session) {
            session.start(cwd: cwd, claudeURL: binary, resumeId: resume, model: model, permissionMode: mode, effort: effort)
        }
    }

    /// Change the active session's effort level. Always a restart — unlike
    /// permission mode, there is no live-switchable subset: verified against
    /// the real binary that no set_effort-style control request exists (every
    /// plausible subtype name returns "Unsupported control request subtype"),
    /// and system/init never reports an effort catalog to switch within.
    /// Same seamless --resume restart changePermissionMode uses for
    /// bypassPermissions — conversation carries over, only the launch flag
    /// changes.
    func changeEffort(_ effort: String) {
        if let codex = activeCodexSession {
            defaultCodexEffort = effort
            codex.setEffort(effort)
            return
        }
        defaultSpawnEffort = effort  // persist for next spawn (AppStorage)
        guard let tab = activeTab, let session = tab.streamSession, let binary = claudeBinary else { return }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        let resume = session.sessionId ?? resumeIds[tab.id]
        let model = defaultSpawnModel
        let permissionMode = session.permissionMode
        restartAfterStop(tabId: tab.id, session: session) {
            session.start(cwd: cwd, claudeURL: binary, resumeId: resume, model: model, permissionMode: permissionMode, effort: effort)
        }
    }

    /// Reset the active conversation to a clean slate (the `/clear` command).
    /// Unlike clearing only the UI, this restarts the underlying claude
    /// process WITHOUT --resume so the agent's context is genuinely gone —
    /// matching what `/clear` does in the terminal. The transcript is wiped
    /// and a fresh session spawns in the same project / model / mode.
    func clearConversation() {
        if let tab = activeTab, tab.provider == .codex,
           let session = tab.codexSession, let binary = codexBinary {
            session.stop()
            codexResumeIds.removeValue(forKey: tab.id)
            let replacement = CodexSession()
            guard let terminals else { return }
            terminals.setCodexSession(replacement, on: tab.id)
            observeCodexSessionState(replacement, tabId: tab.id)
            replacement.start(
                cwd: URL(fileURLWithPath: tab.projectCwd), codexURL: binary,
                model: defaultCodexModel, permissionMode: defaultCodexApprovalPolicy,
                effort: defaultCodexEffort
            )
            return
        }
        guard let tab = activeTab,
              let session = tab.streamSession,
              let binary = claudeBinary else { return }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        // Drop any stashed resume id so the restart can't resurrect context.
        resumeIds.removeValue(forKey: tab.id)
        let model = defaultSpawnModel
        let mode = defaultPermissionMode
        restartAfterStop(tabId: tab.id, session: session) {
            session.resetTranscript()
            session.start(cwd: cwd, claudeURL: binary, resumeId: nil, model: model, permissionMode: mode)
            session.appendSystemNote("Conversation cleared — fresh context.")
        }
    }

    /// Start the active Mode-B tab's session if it's still idle. If the tab
    /// was opened from history we have a resume id stashed in `resumeIds`,
    /// which gets passed to claude as `--resume <id>` so the previous
    /// conversation replays before new turns.
    func startActiveSession() {
        guard let tab = activeTab, tab.surface == .modeB else { return }
        if tab.provider == .codex {
            guard let session = tab.codexSession, let binary = codexBinary else { return }
            switch session.state { case .idle, .terminated: break; default: return }
            session.start(
                cwd: URL(fileURLWithPath: tab.projectCwd), codexURL: binary,
                resumeId: codexResumeIds[tab.id], model: defaultCodexModel, permissionMode: defaultCodexApprovalPolicy,
                effort: defaultCodexEffort
            )
            return
        }
        guard let session = tab.streamSession, let binary = claudeBinary else { return }
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
            permissionMode: defaultPermissionMode,
            effort: defaultSpawnEffort
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
                                   permissionMode: defaultPermissionMode, effort: defaultSpawnEffort)
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
                permissionMode: defaultPermissionMode,
                effort: defaultSpawnEffort
            )
        }
    }

    /// Open a closed Codex thread from the unified History rail. Thread
    /// discovery and resume both go through the user's local Codex app-server;
    /// no API key or paid model turn is used until the user sends a message.
    func openCodexHistoryThread(threadId: String, projectCwd: String, title: String) {
        guard let terminals, let binary = codexBinary else { return }
        let projectName = (projectCwd as NSString).lastPathComponent

        if let existing = tabs.first(where: {
            codexResumeIds[$0.id] == threadId || $0.codexSession?.threadId == threadId
        }) {
            activeTabId = existing.id
            mainView = .chat
            selectedProjectCwd = URL(fileURLWithPath: projectCwd)
            selectedProjectName = projectName
            if existing.provider != .codex {
                switchActiveProvider(to: .codex)
            } else if let session = existing.codexSession {
                switch session.state {
                case .idle, .terminated:
                    session.start(
                        cwd: URL(fileURLWithPath: projectCwd), codexURL: binary,
                        resumeId: threadId, model: defaultCodexModel,
                        permissionMode: defaultCodexApprovalPolicy, effort: defaultCodexEffort
                    )
                default:
                    break
                }
            }
            return
        }

        let id = terminals.openModeB(
            projectCwd: projectCwd,
            title: title.isEmpty ? projectName : title,
            provider: .codex
        )
        codexResumeIds[id] = threadId
        activeTabId = id
        mainView = .chat
        selectedProjectCwd = URL(fileURLWithPath: projectCwd)
        selectedProjectName = projectName
        if let session = terminals.tabs.first(where: { $0.id == id })?.codexSession {
            observeCodexSessionState(session, tabId: id)
            session.start(
                cwd: URL(fileURLWithPath: projectCwd), codexURL: binary,
                resumeId: threadId, model: defaultCodexModel,
                permissionMode: defaultCodexApprovalPolicy, effort: defaultCodexEffort
            )
        }
    }

    /// Flip the active tab between Mode A and Mode B.
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

        // Keyed replacement: assigning into the dict cancels whatever sub was
        // there before (including on `attachLoop(nil, …)`, which just clears
        // the entry) instead of piling another sink into `cancellables` that
        // never gets removed.
        loopSubs[tabId] = loop.map { loop in
            loop.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        objectWillChange.send()
    }

    func attachHarness(_ harness: HarnessOrchestrator?, toTab tabId: UUID) {
        guard let terminals,
              let existing = terminals.tabs.first(where: { $0.id == tabId }) else { return }
        existing.harness?.stop()
        terminals.setHarness(harness, on: tabId)

        harnessSubs[tabId] = harness.map { harness in
            harness.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        objectWillChange.send()
    }

    // MARK: - Binary resolution

    /// `async` so callers that need claudeBinary resolved before proceeding
    /// (restoreWorkspaceIfNeeded() at launch) can `await` it. The actual
    /// shell-out is dispatched to a detached task (M8, bug-hunt 2026-07-10):
    /// ClaudeBinary.locate()'s PATH fallback runs the user's login shell —
    /// even with the timeout added in BinaryVersion.swift, running it inline
    /// on this actor would still block the MainActor (and app launch) for up
    /// to that timeout. Hopping off lets the MainActor keep processing other
    /// work (e.g. rendering) while this awaits.
    func resolveBinary() async {
        guard claudeBinary == nil || codexBinary == nil else { return }
        async let claudeResolved: (URL?, SemVer?) = Task.detached(priority: .userInitiated) {
            let url = ClaudeBinary.locate()
            return (url, url.flatMap { ClaudeBinary.version(at: $0) })
        }.value
        async let codexResolved: (URL?, SemVer?) = Task.detached(priority: .userInitiated) {
            let url = CodexBinary.locate()
            return (url, url.flatMap { CodexBinary.version(at: $0) })
        }.value
        let (claude, codex) = await (claudeResolved, codexResolved)
        claudeBinary = claude.0
        claudeVersion = claude.1
        codexBinary = codex.0
        codexVersion = codex.1
        // Known BEFORE any session spawn is attempted — the whole point
        // is not discovering "not authenticated" from a failed launch.
        if let claudeBinary {
            Task { await claudeAuth.checkStatus(binary: claudeBinary) }
        }
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
