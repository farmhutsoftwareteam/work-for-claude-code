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
    @Published var activeTabId: UUID?

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
    func refreshModelCatalog() {
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
        if modelId.lowercased().contains("1m") { return 1_000_000 }
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

        // Re-publish per-tab StreamSession changes so v2 chrome reacts to
        // streaming/permission state transitions.
        if let session = terminals.tabs.first(where: { $0.id == id })?.streamSession {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func activate(tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
    }

    func close(tabId: UUID) {
        let wasActive = (activeTabId == tabId)
        _ = terminals?.close(tabId, force: true)
        resumeIds.removeValue(forKey: tabId)
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
              let binary = claudeBinary,
              session.state == .idle else { return }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        session.start(
            cwd: cwd,
            claudeURL: binary,
            resumeId: resumeIds[tab.id],
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
            selectedProjectCwd = URL(fileURLWithPath: projectCwd)
            selectedProjectName = projectName.isEmpty
                ? (projectCwd as NSString).lastPathComponent
                : projectName
            return
        }
        let id = terminals.openModeB(projectCwd: projectCwd, title: title.isEmpty ? projectName : title)
        resumeIds[id] = sessionId
        activeTabId = id
        // Keep the rail's project selection in sync with the tab we just
        // opened, so the PROJECTS highlight + the ⌘N "new chat" target
        // follow you into the resumed session's project.
        selectedProjectCwd = URL(fileURLWithPath: projectCwd)
        selectedProjectName = projectName.isEmpty
            ? (projectCwd as NSString).lastPathComponent
            : projectName

        if let session = terminals.tabs.first(where: { $0.id == id })?.streamSession {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        // Eagerly start — user explicitly picked this session.
        if let session = terminals.tabs.first(where: { $0.id == id })?.streamSession,
           let binary = claudeBinary {
            // Preload prior turns BEFORE start so the transcript opens with
            // context. Claude's --resume gets the same id, so the next user
            // message has full history; the preload is for the human.
            if let preload = SessionHistoryLoader.load(
                sessionId: sessionId,
                projectCwd: projectCwd
            ) {
                session.preloadHistory(preload)
            }
            session.start(
                cwd: URL(fileURLWithPath: projectCwd),
                claudeURL: binary,
                resumeId: sessionId,
                model: defaultSpawnModel,
                permissionMode: defaultPermissionMode
            )
        }
    }

    /// Flip the active tab between Mode A and Mode B.
    func flipActiveMode() {
        guard let id = activeTabId else { return }
        terminals?.flipSurface(tabId: id)

        // Re-subscribe to the new StreamSession's changes (B→A creates one,
        // A→B nils it).
        if let session = terminals?.tabs.first(where: { $0.id == id })?.streamSession {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func flipMode(tabId: UUID) {
        terminals?.flipSurface(tabId: tabId)
        if let session = terminals?.tabs.first(where: { $0.id == tabId })?.streamSession {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
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
