import Foundation
import AppKit
import SwiftTerm
import Darwin

/// Owns the lifetime of every in-app `LocalProcessTerminalView`. SwiftUI
/// re-renders the representable wrapper freely, but the view itself only
/// lives here — so the PTY stays open even when the user switches tabs.
///
/// Public surface is small: open a tab, close one, focus one. Everything
/// else (process spawning, delegate wiring, graceful shutdown) is internal.
@MainActor
final class TerminalsController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?

    /// Set when a `request*` entry point fires while the "ask before starting"
    /// preference is on. The root view's confirmation dialog binds to this and
    /// calls `confirmPendingStart(skipPermissions:)` or `cancelPendingStart()`.
    @Published var pendingStart: PendingChatStart?

    /// UserDefaults key for the "ask before starting" preference. True by
    /// default — explicit opt-out via Preferences turns the dialog off.
    static let askDangerousModeKey = "askDangerousModeOnStart"

    struct PendingChatStart: Identifiable, Equatable {
        let id: UUID = UUID()
        let kind: Kind
        let projectCwd: String
        let title: String

        enum Kind: Equatable {
            case new
            case continueLast
            case resume(sessionId: String)
        }

        /// One-line label shown in the confirmation dialog above the buttons,
        /// so the user knows which session they're about to spawn.
        var displayLabel: String {
            switch kind {
            case .new:           return "New session in \(title)"
            case .continueLast:  return "Continue last session in \(title)"
            case .resume:        return "Resume \(title)"
            }
        }
    }

    /// Bumped whenever a `LocalProcessTerminalView` is swapped in/out so the
    /// SwiftUI wrapper has something to observe and force-rebuild on.
    @Published private(set) var viewsEpoch: Int = 0

    /// Tab ids currently "cooking" — received PTY data within the last
    /// `idleThreshold` seconds. UI uses this to paint the chip orange while
    /// Claude is streaming, green when it goes quiet.
    @Published private(set) var busyTabIds: Set<UUID> = []

    // MARK: - Internal state

    /// Backing `LocalProcessTerminalView` per tab. The dictionary keys match
    /// `tabs[i].id`. Views are long-lived — SwiftUI fetches by id.
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var delegates: [UUID: TerminalProcessDelegate] = [:]

    /// Per-tab pending "go idle" work items. Each PTY-read cancels and
    /// reschedules. When one fires, we flip the tab out of `busyTabIds`.
    private var idleWorkItems: [UUID: DispatchWorkItem] = [:]

    /// Generation counter per tab, bumped on every `markActivity` call. Work
    /// items capture their generation at schedule time; if the counter has
    /// moved by the time they fire, a later activity already superseded them
    /// and the idle-flip is skipped. Guards against the DispatchWorkItem
    /// cancel-no-op race where a cancelled item still executes because it
    /// entered the main queue before cancel() landed.
    private var activityGenerations: [UUID: Int] = [:]

    /// How long of PTY silence qualifies as "Claude is ready." Short enough
    /// that the chip flips back fast after the response completes, long
    /// enough that we don't flicker during natural streaming gaps.
    private let idleThreshold: TimeInterval = 0.7

    /// Scrollback cap per terminal. Tweakable later via TerminalSettings.
    private let defaultScrollback: Int = 5000

    // MARK: - Public API

    /// Retrieve (but do not create) the view for a tab id. Called by the
    /// SwiftUI wrapper on `makeNSView`.
    func view(for id: UUID) -> LocalProcessTerminalView? {
        views[id]
    }

    /// Open an embedded terminal that resumes an existing Claude session. If
    /// the session already has an open tab, focuses it instead of spawning a
    /// duplicate (matches the old `Launcher.resumeOrFocus` behavior).
    @discardableResult
    func openResume(sessionId: String, projectCwd: String, title: String, skipPermissions: Bool = false) -> UUID {
        if let existing = tabs.first(where: { $0.sessionId == sessionId && $0.isLive }) {
            focus(existing.id)
            return existing.id
        }
        // Prune any exited tabs for this session id before respawning — otherwise
        // each resume of a previously-exited session leaves a dead chip in the
        // tab bar. The PTY is already reaped, so we can just drop the entries.
        let stale = tabs.filter { $0.sessionId == sessionId && !$0.isLive }.map(\.id)
        for id in stale {
            views.removeValue(forKey: id)
            delegates.removeValue(forKey: id)
            idleWorkItems[id]?.cancel()
            idleWorkItems.removeValue(forKey: id)
            busyTabIds.remove(id)
            tabs.removeAll { $0.id == id }
        }
        if !stale.isEmpty { viewsEpoch += 1 }
        let command = "cd \(shellQuote(projectCwd)) && \(shellQuote(Self.claudeBinary))\(Self.skipFlag(skipPermissions)) --resume \(shellQuote(sessionId))"
        return spawn(command: command, tab: TerminalTab(
            sessionId: sessionId,
            projectCwd: projectCwd,
            title: title,
            skipPermissions: skipPermissions
        ))
    }

    /// Open a fresh Claude session in the given directory.
    @discardableResult
    func openNew(projectCwd: String, title: String, skipPermissions: Bool = false) -> UUID {
        let command = "cd \(shellQuote(projectCwd)) && \(shellQuote(Self.claudeBinary))\(Self.skipFlag(skipPermissions))"
        return spawn(command: command, tab: TerminalTab(
            projectCwd: projectCwd,
            title: title,
            skipPermissions: skipPermissions
        ))
    }

    /// Re-attach to the most recently used session in the given directory
    /// via `claude --continue`. Used by `restart(tabId:)` when the tab being
    /// restarted has no `sessionId` yet — typically a brand-new session
    /// where the user already typed some prompts but Claude hadn't written
    /// the JSONL header by the time we killed it. `--continue` reaches into
    /// `~/.claude/projects/<cwd-hash>/` and resumes whatever Claude
    /// flushed-on-SIGTERM, so the user doesn't silently lose their context.
    @discardableResult
    func openContinue(projectCwd: String, title: String, skipPermissions: Bool = false) -> UUID {
        let command = "cd \(shellQuote(projectCwd)) && \(shellQuote(Self.claudeBinary))\(Self.skipFlag(skipPermissions)) --continue"
        return spawn(command: command, tab: TerminalTab(
            projectCwd: projectCwd,
            title: title,
            skipPermissions: skipPermissions
        ))
    }

    // MARK: - Mode-B entry points (v2-redesign)

    /// Create a new Mode-B tab in the given project. No PTY is spawned — the
    /// tab carries a fresh `StreamSession` which the v2 UI starts on demand.
    /// Returns the tab id so the caller can route activation / focus.
    @discardableResult
    func openModeB(projectCwd: String, title: String) -> UUID {
        let session = StreamSession()
        let tab = TerminalTab(
            projectCwd: projectCwd,
            title: title,
            state: .running, // Mode-B isLive defers to streamSession.state
            surface: .modeB,
            streamSession: session
        )
        tabs.append(tab)
        activeTabId = tab.id
        viewsEpoch += 1
        return tab.id
    }

    /// Attach or detach a LoopOrchestrator on a Mode-B tab. Stopping any
    /// previous loop is the caller's responsibility (V2AppState handles it).
    func setLoop(_ loop: LoopOrchestrator?, on tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].loop = loop
    }

    /// Flip a tab between Mode-A (SwiftTerm) and Mode-B (StreamSession).
    /// Terminates the outgoing surface's process; the incoming surface is
    /// spawned fresh (PTY for A, idle StreamSession for B). Idempotent on
    /// missing ids.
    func flipSurface(tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[idx]

        switch tab.surface {
        case .modeA:
            // Going A → B. SIGTERM the PTY child (if any), drop the view, and
            // mark the tab as Mode-B with a fresh idle StreamSession.
            if tab.isLive, let view = views[tabId] {
                let pid = view.process.shellPid
                if pid > 0 { kill(pid, SIGTERM) }
            }
            views.removeValue(forKey: tabId)
            delegates.removeValue(forKey: tabId)
            idleWorkItems[tabId]?.cancel()
            idleWorkItems.removeValue(forKey: tabId)
            activityGenerations.removeValue(forKey: tabId)
            busyTabIds.remove(tabId)

            tabs[idx].surface = .modeB
            tabs[idx].streamSession = StreamSession()
            tabs[idx].state = .running
            viewsEpoch += 1

        case .modeB:
            // Going B → A. Stop the StreamSession and spawn a fresh PTY in
            // the same cwd.
            tab.streamSession?.stop()
            tabs[idx].streamSession = nil
            tabs[idx].surface = .modeA
            tabs[idx].state = .running
            viewsEpoch += 1

            // Reuse the existing spawn path so PTY setup, PATH inheritance,
            // skip-permissions handling, etc. all flow through one branch.
            let command = "cd \(shellQuote(tab.projectCwd)) && \(shellQuote(Self.claudeBinary))\(Self.skipFlag(tab.skipPermissions))"
            spawnInto(existingTabId: tabId, command: command)
        }
    }

    // MARK: - User-initiated entry points (route through skip-permissions prompt)
    //
    // The three `request*` methods below are the ones every UI surface should
    // call — they check the "ask before starting" preference and, if it's on,
    // stage a `PendingChatStart` for the root view's confirmation dialog.
    // Direct callers (the integrations panel's programmatic OAuth flow, the
    // tab-restart code path) keep using the lower-level open* methods so they
    // don't pop a dialog the user didn't initiate.

    func requestOpenNew(projectCwd: String, title: String) {
        if Self.shouldAskBeforeStart() {
            pendingStart = PendingChatStart(kind: .new, projectCwd: projectCwd, title: title)
        } else {
            openNew(projectCwd: projectCwd, title: title)
        }
    }

    func requestOpenContinue(projectCwd: String, title: String) {
        if Self.shouldAskBeforeStart() {
            pendingStart = PendingChatStart(kind: .continueLast, projectCwd: projectCwd, title: title)
        } else {
            openContinue(projectCwd: projectCwd, title: title)
        }
    }

    func requestOpenResume(sessionId: String, projectCwd: String, title: String) {
        // Focus-existing wins over prompt — if the session is already open we
        // never spawn a second process, so there's nothing to skip permissions
        // for. Mirror the early return inside openResume so the dialog doesn't
        // pop spuriously and then noop.
        if let existing = tabs.first(where: { $0.sessionId == sessionId && $0.isLive }) {
            focus(existing.id)
            return
        }
        if Self.shouldAskBeforeStart() {
            pendingStart = PendingChatStart(kind: .resume(sessionId: sessionId), projectCwd: projectCwd, title: title)
        } else {
            openResume(sessionId: sessionId, projectCwd: projectCwd, title: title)
        }
    }

    /// Called by the root view's confirmation dialog when the user picks
    /// either "Skip permissions" or "Use normal permissions."
    func confirmPendingStart(skipPermissions: Bool) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        switch pending.kind {
        case .new:
            openNew(projectCwd: pending.projectCwd, title: pending.title, skipPermissions: skipPermissions)
        case .continueLast:
            openContinue(projectCwd: pending.projectCwd, title: pending.title, skipPermissions: skipPermissions)
        case .resume(let sid):
            openResume(sessionId: sid, projectCwd: pending.projectCwd, title: pending.title, skipPermissions: skipPermissions)
        }
    }

    /// Called when the user dismisses the confirmation dialog without picking
    /// either option. Drops the pending start; no process is spawned.
    func cancelPendingStart() {
        pendingStart = nil
    }

    private static func shouldAskBeforeStart() -> Bool {
        // .object(forKey:) returns nil for an unwritten key, so a fresh user
        // gets the prompt by default. Only when the user has explicitly
        // unchecked the toggle in Preferences (writing `false`) do we skip it.
        guard let raw = UserDefaults.standard.object(forKey: askDangerousModeKey) as? Bool else { return true }
        return raw
    }

    private static func skipFlag(_ skipPermissions: Bool) -> String {
        skipPermissions ? " --dangerously-skip-permissions" : ""
    }

    /// Restart a single tab in place — SIGTERMs the PTY, then respawns the
    /// same Claude session (preserves sessionId so the conversation
    /// continues). Used by the "Restart session" tab-chip action so users
    /// can pick up newly-added MCPs / tools without leaving the terminal.
    /// If the tab has no sessionId yet (brand-new session, JSONL header not
    /// written), uses `claude --continue` to pick up whatever Claude
    /// flushed-on-exit — otherwise the user's just-typed prompts would
    /// orphan into a dormant session and the tab would silently start blank.
    /// The new tab is moved back to the original tab's slot so tab order is
    /// preserved.
    func restart(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let sessionId = tab.sessionId
        let projectCwd = tab.projectCwd
        let title = tab.title
        let skipPermissions = tab.skipPermissions
        let originalIndex = tabs.firstIndex(where: { $0.id == tabId })

        close(tabId, force: true)

        // 800ms grace so the PTY actually exits before we respawn on the
        // same JSONL — matches the pattern in ProjectIntegrationsPanel's
        // restartLiveSessions().
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            let newId: UUID = sessionId.map {
                self.openResume(sessionId: $0, projectCwd: projectCwd, title: title, skipPermissions: skipPermissions)
            } ?? self.openContinue(projectCwd: projectCwd, title: title, skipPermissions: skipPermissions)

            // Preserve tab position. spawn() appends to the end; nudge back
            // to the slot the killed tab occupied. Clamp to the current
            // bounds because other tabs may have been opened/closed during
            // the 800ms grace window.
            if let origIdx = originalIndex,
               let curIdx = self.tabs.firstIndex(where: { $0.id == newId }) {
                let target = max(0, min(origIdx, self.tabs.count - 1))
                if target != curIdx {
                    self.move(from: curIdx, to: target)
                }
            }
        }
    }

    /// Make `id` the active/focused tab. Creates no view; only selection.
    /// No-op when the tab is already active so we don't fire @Published events
    /// (which would re-trigger our SwiftUI onChange observers needlessly).
    func focus(_ id: UUID) {
        guard activeTabId != id, tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
    }

    /// Close a tab, SIGTERM the PTY child if still running. Callers must
    /// confirm with the user first when the child is live; pass `force: true`
    /// after they agree. Passing `force: false` while `tab.isLive` is a no-op —
    /// the caller should show their confirm dialog and retry.
    @discardableResult
    func close(_ id: UUID, force: Bool = true) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[idx]
        if tab.isLive && !force { return false }

        // Mode-B tabs: terminate the StreamSession before removing the tab so
        // the child `claude` process exits cleanly and the file handles are
        // released. Also stop any orchestrator (loop) running on this tab so
        // its verifier task doesn't outlive the tab.
        if tab.surface == .modeB {
            tab.loop?.stop()
            tab.streamSession?.stop()
        }

        if tab.isLive, let view = views[id] {
            let pid = view.process.shellPid
            if pid > 0 {
                kill(pid, SIGTERM)
                // Escalate to SIGKILL after 3s if still running. The kill-0
                // check is racy (PIDs recycle), so we additionally confirm the
                // process exec path still belongs to our child before sending
                // the lethal signal.
                let pidCopy = pid
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3) {
                    guard kill(pidCopy, 0) == 0 else { return }
                    guard Self.isOurDescendant(pid: pidCopy) else { return }
                    _ = kill(pidCopy, SIGKILL)
                }
            }
        }

        views.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        idleWorkItems[id]?.cancel()
        idleWorkItems.removeValue(forKey: id)
        activityGenerations.removeValue(forKey: id)
        busyTabIds.remove(id)
        tabs.remove(at: idx)
        viewsEpoch += 1

        // Preserve activeTabId when possible; otherwise pick the neighbor
        if activeTabId == id {
            activeTabId = tabs.indices.contains(idx) ? tabs[idx].id
                        : tabs.last?.id
        }
        return true
    }

    /// Reorder a tab (drag-to-reorder in the tab bar).
    func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source),
              destination >= 0, destination <= tabs.count,
              source != destination else { return }
        let tab = tabs.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        tabs.insert(tab, at: dest)
    }

    /// Switch to the next/previous tab for Cmd+] / Cmd+[ style nav.
    /// v1 nav restricted to Mode-A tabs (the v1 tab bar is the only place
    /// these shortcuts trigger from; v2 has its own navigation).
    func cycleFocus(delta: Int) {
        let modeA = tabs.filter { $0.surface == .modeA }
        guard !modeA.isEmpty,
              let currentId = activeTabId,
              let currentIdx = modeA.firstIndex(where: { $0.id == currentId })
        else { return }
        let next = (currentIdx + delta + modeA.count) % modeA.count
        activeTabId = modeA[next].id
    }

    /// Jump to the Nth Mode-A tab (1-based for Cmd+1 … Cmd+9).
    func focus(index oneBased: Int) {
        let modeA = tabs.filter { $0.surface == .modeA }
        let i = oneBased - 1
        guard modeA.indices.contains(i) else { return }
        activeTabId = modeA[i].id
    }

    /// Inject text directly into a tab's PTY, as if the user typed it.
    /// Used by the integrations panel to auto-trigger `/mcp` after install
    /// so users get end-to-end OAuth without leaving Work or memorizing
    /// slash commands.
    func sendInput(_ text: String, to tabId: UUID) {
        guard let view = views[tabId] else { return }
        view.send(txt: text)
    }

    /// Wait until a tab's process is alive AND has shown the Claude prompt,
    /// then inject `text`. Returns false if the tab disappears or we time
    /// out (default 10s). The wait is loose — we only need the PTY to be
    /// reading input by the time we send.
    func sendInputWhenReady(_ text: String, to tabId: UUID, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // Claude takes ~1-2s to draw its banner + prompt after spawn. Pre-wait
        // up to 3.5s but never past the caller's deadline — otherwise a short
        // timeout is meaningless because we'd sleep past it.
        let preWait = min(3.5, max(0, timeout - 0.2))
        if preWait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(preWait * 1_000_000_000))
        }
        while Date() < deadline {
            guard let tab = tabs.first(where: { $0.id == tabId }), tab.isLive else {
                return false
            }
            if views[tabId] != nil {
                sendInput(text, to: tabId)
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// SIGTERM every live child. Called by AppDelegate on
    /// `applicationShouldTerminate` so nothing is left orphaned.
    func shutdownAll() {
        for view in views.values {
            let pid = view.process.shellPid
            if pid > 0 { kill(pid, SIGTERM) }
        }
    }

    /// Update the human-readable title of a tab (e.g. after a rename).
    func rename(_ id: UUID, to newTitle: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].title = newTitle
    }

    /// Is any live tab running this session id? UI uses this to draw a pulse.
    func isSessionLive(_ sessionId: String) -> Bool {
        tabs.contains { $0.sessionId == sessionId && $0.isLive }
    }

    /// Is any live tab running in this project cwd? UI uses this for a
    /// small "this project has work running" dot next to the project row.
    func isProjectLive(_ cwd: String) -> Bool {
        tabs.contains { $0.projectCwd == cwd && $0.isLive }
    }

    /// Count of running sessions globally — drives the floating dock.
    var liveCount: Int {
        tabs.filter { $0.isLive }.count
    }

    /// Flat list of all live tabs — used by the floating dock to render.
    var liveTabs: [TerminalTab] {
        tabs.filter { $0.isLive }
    }

    // MARK: - Internals

    /// Spawn a new terminal view running the given shell command. Returns the
    /// tab id so the caller can focus / rename later.
    private func spawn(command: String, tab: TerminalTab) -> UUID {
        tabs.append(tab)
        attachPTY(tabId: tab.id, command: command)
        activeTabId = tab.id
        return tab.id
    }

    /// Attach a fresh `LocalProcessTerminalView` to an existing tab id —
    /// used by `flipSurface(B→A)` where the tab already lives in `tabs` but
    /// has no PTY yet, and by the common spawn path that appends a brand-new
    /// tab and then attaches.
    private func spawnInto(existingTabId: UUID, command: String) {
        guard tabs.contains(where: { $0.id == existingTabId }) else { return }
        attachPTY(tabId: existingTabId, command: command)
        activeTabId = existingTabId
    }

    private func attachPTY(tabId: UUID, command: String) {
        let view = WorkTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.onData = { [weak self] in
            Task { @MainActor [weak self] in
                self?.markActivity(tabId: tabId)
            }
        }
        view.feed(text: "")  // force first-render init

        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // GitHub Dark palette — matches what most devs already live in via
        // Cursor/VS Code's "GitHub Dark" theme.
        view.nativeBackgroundColor = NSColor(srgbRed: 36/255, green: 41/255, blue: 46/255, alpha: 1)   // #24292e
        view.nativeForegroundColor = NSColor(srgbRed: 209/255, green: 213/255, blue: 218/255, alpha: 1) // #d1d5da
        // Cap scrollback so a chatty session doesn't grow the in-memory
        // buffer unboundedly. SwiftTerm exposes `changeScrollback` on the
        // underlying Terminal — the previous build assigned the constant
        // to `_` and forgot to apply it.
        view.getTerminal().changeScrollback(defaultScrollback)

        let delegate = TerminalProcessDelegate(tabId: tabId, controller: self)
        view.processDelegate = delegate
        delegates[tabId] = delegate

        let env = Self.enrichedEnvironment()
        view.startProcess(
            executable: "/bin/bash",
            args: ["-l", "-c", command],
            environment: env
        )

        views[tabId] = view
        viewsEpoch += 1
    }

    /// Called by the delegate on the main actor when a PTY child exits.
    fileprivate func handleProcessExit(tabId: UUID, exitCode: Int32?) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].state = .exited(code: exitCode)
        idleWorkItems[tabId]?.cancel()
        idleWorkItems.removeValue(forKey: tabId)
        activityGenerations.removeValue(forKey: tabId)
        busyTabIds.remove(tabId)
    }

    /// Called on every PTY read. Cheapest-possible activity signal:
    /// if the tab isn't already marked busy, flip it on (publishes once);
    /// cancel any pending idle-flip and reschedule it for `idleThreshold`
    /// seconds out. A natural gap in streaming flips us back to ready.
    private func markActivity(tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId && $0.isLive }) else { return }
        if !busyTabIds.contains(tabId) {
            busyTabIds.insert(tabId)
        }
        let newGen = (activityGenerations[tabId] ?? 0) &+ 1
        activityGenerations[tabId] = newGen
        idleWorkItems[tabId]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activityGenerations[tabId] == newGen
                else { return }
                self.busyTabIds.remove(tabId)
            }
        }
        idleWorkItems[tabId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleThreshold, execute: item)
    }

    /// SwiftTerm returns env as `["KEY=value", ...]`. Rebuild it, splicing
    /// in an enriched PATH that includes the usual dev-tool install paths
    /// GUI apps miss (launchd inherits a stripped PATH). This is why
    /// `claude` otherwise prints "Native installation exists but
    /// ~/.local/bin is not in your PATH" on every spawn.
    private static func enrichedEnvironment() -> [String] {
        let raw = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        var result: [String] = []
        var foundPath = false
        let enriched = enrichedPathValue(current: currentPathFrom(env: raw))
        for entry in raw {
            if entry.hasPrefix("PATH=") {
                result.append("PATH=\(enriched)")
                foundPath = true
            } else {
                result.append(entry)
            }
        }
        if !foundPath {
            result.append("PATH=\(enriched)")
        }
        return result
    }

    private static func currentPathFrom(env: [String]) -> String? {
        for entry in env where entry.hasPrefix("PATH=") {
            return String(entry.dropFirst("PATH=".count))
        }
        return nil
    }

    /// Prepend (not append) the common dev-tool install locations so these
    /// beat any stripped launchd default. Only existing directories are
    /// added, keeping PATH tidy.
    private static func enrichedPathValue(current: String?) -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin",          // Anthropic native claude install
            "\(home)/.claude/local",       // alt native location
            "\(home)/.cargo/bin",          // uv / uvx
            "\(home)/.volta/bin",          // volta node manager
            "\(home)/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]
        let fm = FileManager.default
        var prefix: [String] = []
        for path in candidates where fm.fileExists(atPath: path) {
            prefix.append(path)
        }
        let base = current ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = Set(base.split(separator: ":").map(String.init))
        let additions = prefix.filter { !existing.contains($0) }
        if additions.isEmpty { return base }
        return additions.joined(separator: ":") + ":" + base
    }

    /// Belt-and-braces PID-recycle guard before SIGKILL: check that the given
    /// pid is still a descendant of Work.app via `kern.proc.pid` sysctl. If
    /// kernel says this pid's parent (or ancestor chain) isn't us, the pid
    /// has been recycled to an unrelated process — do not signal it.
    fileprivate static func isOurDescendant(pid: pid_t) -> Bool {
        let ourPid = getpid()
        var cur = pid
        // Walk up the parent chain at most a few hops. Anything more is
        // pathological for a spawned bash.
        for _ in 0..<8 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cur]
            let err = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
                sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
            }
            guard err == 0, size > 0 else { return false }
            let ppid = info.kp_eproc.e_ppid
            if ppid == ourPid { return true }
            if ppid <= 1 { return false }
            cur = ppid
        }
        return false
    }

    // MARK: - Binary + helpers (mirror Launcher)

    /// Resolved on every spawn so a fresh `brew install claude` after Work
    /// launched picks up the new path without an app restart. The handful of
    /// stat() calls is cheap.
    private static var claudeBinary: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "claude"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Local process delegate

/// Bridges SwiftTerm's AppKit-y delegate to our controller. We register one
/// delegate per tab so the controller can route exit events back by id.
private final class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let tabId: UUID
    weak var controller: TerminalsController?

    init(tabId: UUID, controller: TerminalsController) {
        self.tabId = tabId
        self.controller = controller
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Intentionally left: we keep the user's tab title, not the shell's
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        let id = tabId
        Task { @MainActor [weak controller] in
            controller?.handleProcessExit(tabId: id, exitCode: exitCode)
        }
    }
}
