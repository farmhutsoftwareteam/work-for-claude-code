import Foundation
import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

struct PendingCodexApproval: Identifiable, Equatable {
    enum Kind: Equatable { case command, fileChange, permissions, mcp }
    let id = UUID()
    let requestId: String
    let kind: Kind
    let title: String
    let previewText: String
}

struct CodexInputQuestion: Identifiable, Equatable {
    enum ValueType: Equatable { case string, number, boolean }
    let id: String
    let header: String
    let prompt: String
    let options: [String]
    let isSecret: Bool
    let required: Bool
    let valueType: ValueType
}

struct PendingCodexUserInput: Identifiable, Equatable {
    enum Kind: Equatable { case tool, mcp }
    let id = UUID()
    let requestId: String
    let kind: Kind
    let title: String
    let questions: [CodexInputQuestion]
}

@MainActor
final class CodexSession: ObservableObject, V2TranscriptSource {
    private let log = Logger(subsystem: "com.munyamakosa.work", category: "codex-session")

    /// Stable per-instance identity — mirrors StreamSession.instanceId. A
    /// freshly-`start()`ed session is a new object, but tab-switch/render-
    /// window resets in the shared transcript view key off this rather than
    /// ObjectIdentifier, which malloc can alias onto a just-deallocated
    /// session's address (see StreamSession.instanceId's own doc comment).
    nonisolated let instanceId = UUID()

    @Published private(set) var state: StreamSession.LifecycleState = .idle {
        didSet { lastActivityAt = Date() }
    }
    @Published private(set) var transcript: [TranscriptItem] = []
    @Published private(set) var model = ""
    @Published private(set) var effort = ""
    @Published private(set) var permissionMode = "on-request"
    @Published private(set) var availableModels: [CodexModel] = []
    @Published private(set) var account: CodexAccount?
    @Published private(set) var requiresChatGPTLogin = false
    @Published private(set) var pendingPermission: PendingCodexApproval?
    @Published private(set) var pendingUserInput: PendingCodexUserInput?
    @Published private(set) var mcpServers: [CodexMCPServer] = []
    @Published private(set) var endError: String?
    @Published private(set) var loginInProgress = false
    @Published private(set) var totalTokens = 0
    @Published private(set) var contextWindow: Int?
    /// Plan-usage meters (window usedPercent, reset times, plan type) from
    /// account/rateLimits/read + the account/rateLimits/updated push —
    /// same surface the ChatGPT app's meter reads. Drives the composer's
    /// compact meter + the session-config LIMITS section.
    @Published private(set) var usageLimits: V2UsageLimits?
    /// Whether codex's workspace-write sandbox allows outbound network —
    /// read from the app-server's effective config. nil until a live
    /// client has answered. With this false (codex's default), every
    /// `git push` / `gh` / package install inside a session dies instantly
    /// with "Could not resolve host", and nothing in the product said why —
    /// a real user hit exactly that wall (winpal, 2026-07-20) and it took
    /// rollout-log archaeology to explain. Surfacing the switch is the fix.
    @Published private(set) var sandboxNetworkAccess: Bool?
    /// nil = still running, true = failed, false = succeeded — same valence
    /// convention V2LiveToolWidget/StreamSession.toolOutcomes already use.
    /// Keyed by ThreadItem id (commandExecution/fileChange/mcpToolCall/
    /// dynamicToolCall/collabAgentToolCall).
    @Published private(set) var toolOutcomes: [String: Bool] = [:]
    /// itemId → call start, for V2LiveToolWidget's in-flight elapsed readout.
    private(set) var toolStartTimes: [String: Date] = [:]
    /// Live task checklist sourced from turn/plan/updated — routed through
    /// the exact same V2LiveTaskChecklist Claude's TaskCreate/TaskUpdate
    /// tool calls render, via one synthetic TaskUpdate toolUse block (see
    /// handlePlanUpdated).
    @Published private(set) var taskItems: [V2TaskItem] = []
    /// Touched on every reasoning/agentMessage delta — drives the shared
    /// transcript's "still working / stalled" TimelineView the same way
    /// StreamSession.lastStreamActivityAt does.
    private(set) var lastStreamActivityAt = Date()
    /// Cumulative unified diff for the in-flight turn (turn/diff/updated).
    /// Not rendered as its own row today — per-file diffs already surface
    /// through completed fileChange items — but tracked (rather than
    /// silently dropped) so a future "review all changes" surface has
    /// something real to read.
    @Published private(set) var latestTurnDiff: String?

    private(set) var threadId: String?
    private(set) var turnId: String?
    /// Timestamp for the active model turn. Kept separate from process startup
    /// so the tab timer never counts account/model/MCP initialization time.
    private(set) var turnStartedAt: Date?
    private(set) var cwd: URL?
    var composerDraft = ""

    // MARK: - V2TranscriptSource conformance
    //
    // CodexSession has no equivalent yet for a handful of Claude-only
    // concepts (delegation cards, session-dir peek, the retry banner,
    // preloaded-turn windowing at the transport layer) — each supplies the
    // neutral default below rather than a fake implementation, so the
    // corresponding branch in V2LiveTranscript's shared body just never
    // renders for a Codex session instead of rendering something wrong.
    var baseDir: String? { cwd?.path }
    /// Populated live from collab spawns + sub-agent activity (see
    /// applySubagentEvent). Was hardcoded empty, which is why Codex tabs
    /// had no delegation cards and no runs strip while Claude tabs did.
    @Published private(set) var subagentRuns: [V2SubagentRun] = []
    var subagentRunsPublisher: Published<[V2SubagentRun]>.Publisher { $subagentRuns }
    var sessionDir: URL? { nil }
    var preloadOmittedTurns: Int { 0 }
    var isRetrying: Bool { false }
    var lastRetry: StreamSession.RetryInfo? { nil }
    var latestResult: ResultEvent? { nil }
    /// V2TranscriptSource's provider-neutral name for the native identifier
    /// StreamSession calls sessionId — Codex's own is threadId.
    var sessionId: String? { threadId }
    /// Covers both "reading history off the app-server before we're live"
    /// (launch restore) and "resuming a thread through a spawning process"
    /// (the original live-resume meaning). The stored half has to exist
    /// separately: a purely computed flag can't act as the re-entrancy
    /// latch that stops a double restore appending the transcript twice,
    /// and during an off-process preload the state is still `.idle`.
    var isResuming: Bool {
        isPreloadingHistory || (state == .initializing && resumeThreadId != nil)
    }
    @Published private(set) var isPreloadingHistory = false
    var provider: V2AgentProvider { .codex }
    func retryLastTurn() {}

    /// Drives the idle-hibernation scanner. Deliberately NOT @Published —
    /// it changes on every lifecycle transition, and republishing that would
    /// fan out into every observing view for a value nothing renders
    /// (PERFORMANCE.md rule 2, same reasoning as StreamSession's).
    private(set) var lastActivityAt = Date()

    private var client: CodexAppServerClient?
    private var binary: URL?
    private var resumeThreadId: String?
    /// Everything needed to respawn transparently after hibernation,
    /// captured on every start() exactly like StreamSession's.
    private var wakeCwd: URL?
    private var wakeBinary: URL?
    private var wakeModel: String?
    private var wakePermissionMode: String?
    private var wakeEffort: String?
    /// Text (and attachments) typed into a hibernated tab, buffered through
    /// the respawn and flushed once the thread is live again.
    private var pendingWakeSend: (text: String, attachments: [URL])?
    private var streamBuffer = ""
    private var streamingIndex: Int?
    private var streamingItemId: String?
    /// True while the open streaming block is `.thinking` rather than
    /// `.text` — agentMessage/plan deltas and reasoning deltas both stream
    /// through the same buffer, so finalizing/flushing must know which
    /// ContentBlock case to commit into.
    private var streamingIsThinking = false
    private var flushPending = false
    private let streamFlushInterval: TimeInterval = 0.033
    private var renderedItemIDs: Set<String> = []
    private var requestedPermissionGrant: [String: Any]?
    private var pendingProviderHandoffContext: String?
    private var mcpRefreshInFlight = false
    private var mcpRefreshQueued = false
    /// itemId → transcript index, for items shown eagerly on item/started
    /// (commandExecution/fileChange/mcpToolCall/dynamicToolCall/
    /// collabAgentToolCall) so item/completed can append the paired result
    /// instead of re-appending the call itself.
    private var startedItemIndex: [String: Int] = [:]
    /// itemId → accumulated live output, a safety net for outputDelta/
    /// progress notifications in case a completed item's own aggregated
    /// field is ever missing — not rendered live (see handleNotification's
    /// case comment for why not: Claude's own Bash tool_result isn't
    /// streamed live either, so holding off here is parity, not a gap).
    private var liveItemOutput: [String: String] = [:]
    /// threadId → agentPath for sub-agents seen this session, so collab
    /// tool results can name the agents they targeted instead of printing
    /// raw thread UUIDs. Accumulated live; history rebuilds its own index
    /// up front (see transcript(from:)).
    private var subAgentNames: [String: String] = [:]
    /// itemId → latest MCP progress message, shown next to the spinner via
    /// V2LiveToolWidget's liveStatus.
    @Published private(set) var toolLiveStatus: [String: String] = [:]
    private var sawPlanUpdate = false

    /// Same bug class as StreamSession.permissionQueue (#49), found by
    /// checking this file specifically after that fix: Codex's app-server
    /// can fire multiple concurrent approval/input requests within one turn
    /// (parallel tool calls), and pendingPermission/pendingUserInput were
    /// single scalars a second arrival silently overwrote — orphaning the
    /// first request's requestId forever, identical to the real munga-ai
    /// deadlock that motivated #49.
    private enum PendingCodexRequest {
        case permission(PendingCodexApproval, grant: [String: Any]?)
        case userInput(PendingCodexUserInput)
    }
    private var codexRequestQueue: [PendingCodexRequest] = []

    var selectedModel: CodexModel? {
        availableModels.first { $0.id == model || $0.model == model }
    }

    func start(
        cwd: URL,
        codexURL: URL,
        resumeId: String? = nil,
        model: String? = nil,
        permissionMode: String = "on-request",
        effort: String = ""
    ) {
        guard client == nil else { return }
        self.cwd = cwd
        self.binary = codexURL
        // A stopped CodexSession retains its native thread id. A fresh
        // app-server connection must explicitly resume that thread before it
        // can accept another turn; merely retaining `threadId` locally is not
        // enough for the new server process.
        let threadToResume = resumeId ?? threadId
        self.resumeThreadId = threadToResume
        if threadToResume != nil { self.threadId = nil }
        self.model = model ?? ""
        self.permissionMode = permissionMode
        self.effort = effort
        // Lets the sub-agent peek read a thread later without plumbing the
        // binary through the view tree.
        CodexHistoryReader.shared.rememberBinary(codexURL)
        // Capture the wake recipe — hibernation respawns with exactly these.
        wakeCwd = cwd
        wakeBinary = codexURL
        wakeModel = model
        wakePermissionMode = permissionMode
        wakeEffort = effort
        endError = nil
        state = .spawning

        let client = CodexAppServerClient(binary: codexURL)
        self.client = client
        client.onNotification = { [weak self] method, params in
            Task { @MainActor in self?.handleNotification(method: method, params: params.raw) }
        }
        client.onServerRequest = { [weak self] id, method, params in
            Task { @MainActor in self?.handleServerRequest(id: id, method: method, params: params.raw) }
        }
        client.onTermination = { [weak self] reason in
            Task { @MainActor in self?.handleTermination(reason) }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.start()
                self.state = .initializing
                let accountChecked = await self.refreshAccount()
                await self.refreshModels()
                guard accountChecked else {
                    // Unknown auth state — do NOT fall through to
                    // openThreadIfNeeded() on the unverified assumption
                    // that requiresChatGPTLogin's stale/default value means
                    // "authenticated". Surface a real, retryable error
                    // instead of either silently guessing or showing the
                    // sign-in screen to someone who's actually logged in.
                    self.fail("Couldn't verify your Codex account — check your connection and try again.")
                    return
                }
                if !self.requiresChatGPTLogin {
                    try await self.openThreadIfNeeded()
                    // Wake-from-hibernation: the message that triggered this
                    // respawn goes out only now, once the thread is actually
                    // resumed and state is .ready — send() rejects anything
                    // earlier. Chained in THIS task rather than a second one
                    // so there is a real ordering guarantee (the bug
                    // StreamSession.start documents at its own flush point).
                    self.flushPendingWakeSend()
                } else { self.state = .idle }
                // MCP discovery must never gate thread creation or history
                // restore. Slow/startup-heavy servers update independently.
                Task { [weak self] in await self?.refreshMCPStatus() }
                // Seed the plan-usage meters once; the account/rateLimits/
                // updated push keeps them fresh from here without polling.
                Task { [weak self] in await self?.refreshRateLimits() }
                Task { [weak self] in await self?.refreshSandboxNetwork() }
            } catch {
                client.stop()
                if self.client === client { self.client = nil }
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard client != nil else { state = .terminated(reason: "Stopped"); return }
        state = .closing
        finalizeStreamingText()
        clearPendingRequests()
        client?.stop()
        client = nil
        state = .terminated(reason: "Stopped")
    }

    // MARK: - Hibernation

    /// Restore a thread's conversation WITHOUT starting it — the launch
    /// path. Reads history through the shared CodexHistoryReader (one
    /// app-server for every restored tab, `thread/read` leaves the thread
    /// `notLoaded`) and lands in `.hibernated`: transcript on screen,
    /// composer live, ZERO processes owned by this session. The first
    /// message wakes it via thread/resume.
    ///
    /// Before this, only the single active Codex tab was started at launch
    /// and every other restored Codex tab sat at `.idle` behind a "Start
    /// session" button, while Claude tabs came back with their conversation
    /// already on screen.
    func restoreHibernated(
        threadId: String,
        cwd: URL,
        codexURL: URL,
        model: String? = nil,
        permissionMode: String = "on-request",
        effort: String = ""
    ) {
        guard !isPreloadingHistory, case .idle = state else { return }
        isPreloadingHistory = true
        self.cwd = cwd
        self.binary = codexURL
        // The wake recipe, and the id wake() resumes. Set eagerly because
        // wake() reads self.threadId rather than a stored copy.
        wakeCwd = cwd
        wakeBinary = codexURL
        wakeModel = model
        wakePermissionMode = permissionMode
        wakeEffort = effort
        self.threadId = threadId
        self.model = model ?? ""
        self.permissionMode = permissionMode
        self.effort = effort

        Task { [weak self] in
            let thread = await CodexHistoryReader.shared.read(threadId: threadId, binary: codexURL)
            guard let self else { return }
            if let turns = thread?["turns"] as? [[String: Any]], !turns.isEmpty, self.transcript.isEmpty {
                self.transcript = Self.transcript(from: turns)
            }
            self.isPreloadingHistory = false
            // Land hibernated even if the read failed: the thread id is
            // still valid, so waking works and thread/resume returns the
            // history anyway. Dropping back to .idle would put the Start
            // button back — the exact thing this removes.
            self.state = .hibernated
        }
    }

    /// Drop the app-server process while keeping the conversation on screen.
    /// Entered from `.ready` by the idle scanner; the thread id is what
    /// makes the later wake resumable, so it's a hard precondition.
    func hibernate() {
        guard state == .ready, threadId != nil else { return }
        finalizeStreamingText()
        clearPendingRequests()
        // Clear the handler BEFORE stopping: this teardown is deliberate,
        // and handleTermination would otherwise read the resulting exit as
        // a crash and fail() the session out of hibernation.
        let dying = client
        client = nil
        dying?.onTermination = nil
        dying?.stop()
        state = .hibernated
    }

    /// Respawn after hibernation, buffering the message until the thread is
    /// resumed and ready to accept a turn.
    private func wake(thenSend text: String, attachments: [URL]) {
        guard let cwd = wakeCwd, let binary = wakeBinary else {
            state = .terminated(reason: "can't wake: no spawn recipe")
            return
        }
        pendingWakeSend = (text, attachments)
        start(
            cwd: cwd,
            codexURL: binary,
            resumeId: threadId,
            model: wakeModel,
            permissionMode: wakePermissionMode ?? "on-request",
            effort: wakeEffort ?? ""
        )
    }

    /// Deliver the buffered wake message now that the thread is live. State
    /// is `.ready` by this point, so the re-entrant send() takes the normal
    /// path and cannot recurse back into wake().
    private func flushPendingWakeSend() {
        guard let queued = pendingWakeSend else { return }
        pendingWakeSend = nil
        send(text: queued.text, attachments: queued.attachments)
    }

    /// A wake that never reached a live thread must not swallow what the
    /// user typed. StreamSession's equivalent leaves the text stranded in
    /// memory — invisible in the UI but live enough to be flushed as a user
    /// turn by some later successful spawn. Put it back in the composer
    /// instead, where it's visible and the user decides.
    private func returnPendingWakeSendToComposer() {
        guard let queued = pendingWakeSend else { return }
        pendingWakeSend = nil
        guard !queued.text.isEmpty else { return }
        composerDraft = composerDraft.isEmpty
            ? queued.text
            : composerDraft + "\n" + queued.text
    }

    /// Synchronous process teardown used during app termination/update, when
    /// an asynchronous cleanup task may never get another run-loop turn.
    func terminateNow() {
        finalizeStreamingText()
        clearPendingRequests()
        client?.terminateNow()
        client = nil
        state = .terminated(reason: "Stopped")
    }

    /// A dead/dying process can't receive a control_response for any
    /// request — currently-shown or queued — so every requestId still held
    /// here is moot. Drop them rather than leave a stale permission card
    /// (or an invisibly queued one) hovering over a session that's gone.
    private func clearPendingRequests() {
        pendingPermission = nil
        pendingUserInput = nil
        requestedPermissionGrant = nil
        codexRequestQueue.removeAll()
    }

    func beginChatGPTLogin() {
        guard let client else { return }
        loginInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.request("account/login/start", params: [
                    "type": "chatgpt",
                    "appBrand": "codex",
                    "codexStreamlinedLogin": true,
                    "useHostedLoginSuccessPage": true
                ])
                guard let raw = result["authUrl"] as? String,
                      let url = URL(string: raw) else {
                    throw CodexAppServerError.invalidResponse
                }
                NSWorkspace.shared.open(url)
            } catch {
                self.loginInProgress = false
                self.fail(error.localizedDescription, terminal: false)
            }
        }
    }

    /// Returns whether the check actually completed. Callers that gate
    /// real actions on `requiresChatGPTLogin` (start()'s decision to open a
    /// thread) must check this — on failure requiresChatGPTLogin is left at
    /// its previous value, which for a first-ever call is the type's
    /// `false` default, i.e. UNKNOWN reads as "authenticated". A transient
    /// account/read failure during startup must not silently fall through
    /// to openThreadIfNeeded() on that unverified assumption.
    @discardableResult
    /// One-time seed read of the plan meters; live updates arrive via the
    /// account/rateLimits/updated notification. Failure is non-fatal — an
    /// unauthenticated or API-key account may simply not have limits, and
    /// the meter not rendering is the correct representation of that.
    func refreshRateLimits() async {
        guard let client else { return }
        do {
            let response = try await client.requestWithNullParams("account/rateLimits/read")
            if let snapshot = response["rateLimits"] as? [String: Any],
               let parsed = V2UsageLimits.fromCodex(snapshot) {
                for window in V2UsageLimits.crossings(from: usageLimits, to: parsed) {
                    transcript.append(.systemNote(kind: .info, text: V2UsageLimits.crossingMessage(for: window)))
                }
                usageLimits = parsed
            }
        } catch {
            log.debug("account/rateLimits/read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True while this session owns a live app-server that can answer
    /// config reads/writes — the sandbox-network control disables itself
    /// on a resting/ended session instead of no-oping silently.
    var hasLiveClient: Bool { client != nil }

    func refreshSandboxNetwork() async {
        guard let client else { return }
        guard let response = try? await client.request("config/read", params: [:]) else { return }
        sandboxNetworkAccess = Self.sandboxNetworkAccess(fromConfigRead: response.raw)
    }

    /// Pure parse of config/read — snake_case keys verified against a live
    /// codex-cli 0.144.4 response (2026-07-20). An absent table means
    /// codex's default, which is network OFF.
    static func sandboxNetworkAccess(fromConfigRead response: [String: Any]) -> Bool? {
        guard let config = response["config"] as? [String: Any] else { return nil }
        let sandbox = config["sandbox_workspace_write"] as? [String: Any]
        return sandbox?["network_access"] as? Bool ?? false
    }

    /// Writes through the app-server's own config writer (config/value/write
    /// → user config.toml) rather than hand-editing TOML. The setting is
    /// read at app-server spawn, so it takes effect from the next session
    /// start — resting tabs pick it up on wake.
    func setSandboxNetworkAccess(_ enabled: Bool) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.request("config/value/write", params: CodexJSONObject([
                "keyPath": "sandbox_workspace_write.network_access",
                "value": enabled,
                "mergeStrategy": "upsert"
            ]))
            sandboxNetworkAccess = enabled
            return true
        } catch {
            log.error("config/value/write sandbox network failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Recovers from an abandoned browser sign-in — closing the OAuth tab
    /// without finishing it left loginInProgress stuck true forever (no
    /// timeout, no server-pushed "you gave up" notification exists), so
    /// the "Sign in with ChatGPT" button stayed permanently disabled on
    /// "Waiting for browser sign-in…" with no way back short of restarting
    /// the whole session. account/login/cancel is a real RPC the app-server
    /// already supports; this just calls it and clears the local flag so a
    /// fresh attempt is possible either way even if the cancel itself fails.
    func cancelChatGPTLogin() {
        guard loginInProgress else { return }
        loginInProgress = false
        Task { [weak self] in try? await self?.client?.requestWithNullParams("account/login/cancel") }
    }

    func refreshAccount() async -> Bool {
        guard let client else { return false }
        do {
            let response = try await client.request("account/read", params: ["refreshToken": false])
            let requires = response["requiresOpenaiAuth"] as? Bool ?? true
            if let raw = response["account"] as? [String: Any] {
                let type = raw["type"] as? String
                account = CodexAccount(
                    email: raw["email"] as? String,
                    planType: type == "apiKey" ? "API key" : raw["planType"] as? String
                )
            } else {
                account = nil
            }
            requiresChatGPTLogin = requires && account == nil
            return true
        } catch {
            log.error("account/read failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func refreshModels() async {
        guard let client else { return }
        do {
            var cursor: String?
            var collected: [CodexModel] = []
            repeat {
                var params: [String: Any] = ["includeHidden": false, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request("model/list", params: CodexJSONObject(params))
                let page = (response["data"] as? [[String: Any]] ?? []).compactMap(Self.decodeModel)
                collected.append(contentsOf: page)
                cursor = response["nextCursor"] as? String
            } while cursor != nil
            availableModels = collected
            if model.isEmpty {
                model = collected.first(where: \.isDefault)?.id ?? collected.first?.id ?? ""
            }
            if effort.isEmpty { effort = selectedModel?.defaultReasoningEffort ?? "" }
        } catch {
            log.error("model/list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func send(text: String, attachments: [URL] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptiness is checked BEFORE the wake branch on purpose: sending
        // pure whitespace into a hibernated tab must not spawn a whole
        // app-server just to discard the message on the far side.
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Typing into a hibernated tab IS the wake gesture — respawn,
        // resume the thread, and deliver this message once it's live.
        if state == .hibernated {
            wake(thenSend: text, attachments: attachments)
            return
        }
        guard state == .ready, let client, let threadId else { return }
        finalizeStreamingText()
        let attachmentNames = attachments.map(\.lastPathComponent)
        let displayText = text + (attachmentNames.isEmpty ? "" : "\n\nAttached: \(attachmentNames.joined(separator: ", "))")
        transcript.append(.userText(displayText))
        endError = nil
        turnStartedAt = Date()
        state = .working
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        for url in attachments {
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if contentType?.conforms(to: .image) == true {
                input.append(["type": "localImage", "path": url.path])
            } else {
                input.append(["type": "mention", "name": url.lastPathComponent, "path": url.path])
            }
        }
        let handoffContext = pendingProviderHandoffContext
        let params = Self.turnStartParams(
            threadId: threadId,
            input: input,
            model: model,
            approvalPolicy: permissionMode,
            effort: effort,
            handoffContext: handoffContext
        )
        Task { [weak self] in
            do {
                let response = try await client.request("turn/start", params: CodexJSONObject(params))
                self?.turnId = (response["turn"] as? [String: Any])?["id"] as? String
                if self?.pendingProviderHandoffContext == handoffContext {
                    self?.pendingProviderHandoffContext = nil
                }
            } catch {
                self?.state = .ready
                self?.turnStartedAt = nil
                self?.log.error("turn/start failed: \(error.localizedDescription, privacy: .private)")
                self?.appendError("Send failed: \(error.localizedDescription)")
            }
        }
    }

    func setProviderHandoffContext(_ context: String) {
        pendingProviderHandoffContext = context
    }

    /// Keep the whole visible conversation on screen while the destination
    /// provider receives only the bounded ProviderHandoff checkpoint. This is
    /// display state, not an attempt to reuse another provider's native thread.
    func adoptProviderTimeline(_ items: [TranscriptItem], from provider: V2AgentProvider) {
        finalizeStreamingText()
        transcript = items
        transcript.append(.systemNote(kind: .info, text: "Continuing with Codex from \(provider.displayName)."))
        renderedItemIDs.removeAll()
    }

    /// Versioned app-server wire shape for a turn. Kept as a pure builder so
    /// tests can validate it against Codex's generated schema without starting
    /// a real paid turn.
    static func turnStartParams(
        threadId: String,
        input: [[String: Any]],
        model: String,
        approvalPolicy: String,
        effort: String,
        handoffContext: String?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
            "model": model,
            "approvalPolicy": approvalPolicy
        ]
        if !effort.isEmpty { params["effort"] = effort }
        if let handoffContext {
            // Codex 0.144.4 TurnStartParams.additionalContext is a MAP keyed
            // by an opaque source id, not an array of entries.
            let entry: [String: Any] = ["kind": "untrusted", "value": handoffContext]
            params["additionalContext"] = ["atelier-provider-handoff": entry] as [String: Any]
        }
        return params
    }

    /// Read local Codex history through the same official app-server protocol
    /// used for live chats. This starts no model turn and consumes no tokens.
    static func listThreads(codexURL: URL) async throws -> [CodexThreadSummary] {
        let client = CodexAppServerClient(binary: codexURL)
        try await client.start()
        defer { client.stop() }

        var cursor: String?
        var threadsByID: [String: CodexThreadSummary] = [:]
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "limit": 100,
                "sortKey": "updated_at",
                "sortDirection": "desc"
            ]
            if let cursor { params["cursor"] = cursor }
            let response = try await client.request("thread/list", params: CodexJSONObject(params))
            for raw in response["data"] as? [[String: Any]] ?? [] {
                if let thread = decodeThreadSummary(raw) {
                    threadsByID[thread.id] = thread
                }
            }
            cursor = response["nextCursor"] as? String
        } while cursor != nil

        return threadsByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func decodeThreadSummary(_ raw: [String: Any]) -> CodexThreadSummary? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let cwd = raw["cwd"] as? String, !cwd.isEmpty else { return nil }
        let timestamp = (raw["updatedAt"] as? NSNumber)?.doubleValue
            ?? (raw["createdAt"] as? NSNumber)?.doubleValue
            ?? 0
        let explicitName = (raw["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (raw["preview"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let explicitName, !explicitName.isEmpty {
            title = explicitName
        } else if !preview.isEmpty {
            title = String(preview.split(whereSeparator: \.isNewline).first?.prefix(72) ?? Substring(preview.prefix(72)))
        } else {
            title = "thread \(String(id.prefix(8)))"
        }
        return CodexThreadSummary(
            id: id,
            cwd: cwd,
            title: title,
            updatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    func interrupt() {
        Task { @MainActor [weak self] in
            guard let self, let client = self.client,
                  let threadId = self.threadId, let turnId = self.turnId else { return }
            _ = try? await client.request("turn/interrupt", params: ["threadId": threadId, "turnId": turnId])
        }
    }

    /// Show a request immediately if nothing is currently up, otherwise
    /// queue it — the fix for the clobber bug described on codexRequestQueue.
    private func presentOrQueue(_ request: PendingCodexRequest) {
        guard pendingPermission == nil, pendingUserInput == nil else {
            codexRequestQueue.append(request)
            return
        }
        show(request)
    }

    private func show(_ request: PendingCodexRequest) {
        switch request {
        case .permission(let approval, let grant):
            pendingPermission = approval
            requestedPermissionGrant = grant
        case .userInput(let input):
            pendingUserInput = input
        }
        state = .awaitingPermission
    }

    /// Called after either respondTo* below clears its slot — promotes the
    /// next queued request (of either kind) instead of dropping straight to
    /// .working, so a second concurrent request never sits invisibly queued
    /// forever the way the pre-fix single-scalar version could.
    private func promoteNextPendingRequest() {
        guard !codexRequestQueue.isEmpty else { state = .working; return }
        show(codexRequestQueue.removeFirst())
    }

    /// Requests queued behind whichever one is currently shown — mirrors
    /// StreamSession.queuedPermissionCount so both permission modals can
    /// show the same "N more waiting" hint.
    var queuedRequestCount: Int { codexRequestQueue.count }

    func respondToPermission(allow: Bool) {
        guard let pending = pendingPermission, let client else { return }
        // Captured BEFORE promoting the next queued request — promotion can
        // overwrite requestedPermissionGrant with a DIFFERENT queued
        // .permissions request's grant, which must never leak into this
        // reply for the request actually being answered right now.
        let grantForThisReply = requestedPermissionGrant
        pendingPermission = nil
        promoteNextPendingRequest()
        let result: [String: Any]
        switch pending.kind {
        case .command, .fileChange:
            result = ["decision": allow ? "accept" : "decline"]
        case .permissions:
            result = [
                "permissions": allow ? (grantForThisReply ?? [:]) : [:],
                "scope": "turn"
            ]
        case .mcp:
            result = ["action": allow ? "accept" : "decline"]
        }
        do { try client.respond(id: pending.requestId, result: result) }
        catch {
            // Only roll back to .ready if nothing else took over the slot —
            // promoteNextPendingRequest() may have legitimately moved state
            // to .awaitingPermission for an unrelated queued request, which
            // this reply's failure must not clobber.
            if pendingPermission == nil, pendingUserInput == nil { state = .ready }
            appendError("Approval reply failed: \(error.localizedDescription)")
        }
    }

    func respondToUserInput(answers: [String: String], cancelled: Bool = false) {
        guard let pending = pendingUserInput, let client else { return }
        pendingUserInput = nil
        promoteNextPendingRequest()
        do {
            switch pending.kind {
            case .tool:
                let payload = Dictionary(uniqueKeysWithValues: pending.questions.map { question in
                    (question.id, ["answers": cancelled ? [] : [answers[question.id, default: ""]]])
                })
                try client.respond(id: pending.requestId, result: ["answers": payload])
            case .mcp:
                guard !cancelled else {
                    try client.respond(id: pending.requestId, result: ["action": "cancel"])
                    return
                }
                var content: [String: Any] = [:]
                for question in pending.questions {
                    let raw = answers[question.id, default: ""]
                    switch question.valueType {
                    case .string: content[question.id] = raw
                    case .number: content[question.id] = Double(raw) ?? 0
                    case .boolean: content[question.id] = ["true", "yes", "1"].contains(raw.lowercased())
                    }
                }
                try client.respond(id: pending.requestId, result: ["action": "accept", "content": content])
            }
        } catch {
            if pendingPermission == nil, pendingUserInput == nil { state = .ready }
            appendError("Input reply failed: \(error.localizedDescription)")
        }
    }

    func setModel(_ id: String) {
        model = id
        if let selected = selectedModel,
           !selected.supportedReasoningEfforts.contains(where: { $0.id == effort }) {
            effort = selected.defaultReasoningEffort
        }
    }

    func setEffort(_ value: String) { effort = value }
    func setPermissionMode(_ value: String) { permissionMode = value }

    func refreshMCPStatus() async {
        guard let client else { return }
        guard !mcpRefreshInFlight else {
            mcpRefreshQueued = true
            return
        }
        mcpRefreshInFlight = true
        defer {
            mcpRefreshInFlight = false
            if mcpRefreshQueued {
                mcpRefreshQueued = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    await self?.refreshMCPStatus()
                }
            }
        }
        do {
            var cursor: String?
            var collected: [CodexMCPServer] = []
            repeat {
                var params: [String: Any] = ["detail": "full", "limit": 100]
                if let threadId { params["threadId"] = threadId }
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request("mcpServerStatus/list", params: CodexJSONObject(params))
                collected.append(contentsOf: (response["data"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let name = raw["name"] as? String else { return nil }
                return CodexMCPServer(
                    name: name,
                    authStatus: raw["authStatus"] as? String ?? "unsupported",
                    toolCount: (raw["tools"] as? [String: Any])?.count ?? 0,
                    resourceCount: (raw["resources"] as? [Any])?.count ?? 0
                )
                })
                cursor = response["nextCursor"] as? String
            } while cursor != nil
            mcpServers = collected
        } catch {
            log.error("mcpServerStatus/list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loginMCP(name: String) {
        guard let client else { return }
        Task { [weak self] in
            do {
                var params: [String: Any] = ["name": name]
                if let threadId = self?.threadId { params["threadId"] = threadId }
                let response = try await client.request("mcpServer/oauth/login", params: CodexJSONObject(params))
                guard let raw = response["authorizationUrl"] as? String,
                      let url = URL(string: raw) else { throw CodexAppServerError.invalidResponse }
                NSWorkspace.shared.open(url)
            } catch {
                self?.appendError("MCP login failed: \(error.localizedDescription)")
            }
        }
    }

    func writeMCPServer(name: String, value: [String: Any]?, projectScoped: Bool) async throws {
        guard let client else { throw CodexAppServerError.notRunning }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CodexAppServerError.rpc(code: nil, message: "Server names may contain letters, numbers, hyphens, and underscores.")
        }
        var params: [String: Any] = [
            "keyPath": "mcp_servers.\(name)",
            "mergeStrategy": "upsert",
            "value": value ?? NSNull()
        ]
        if projectScoped, let cwd {
            let configDir = cwd.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            params["filePath"] = configDir.appendingPathComponent("config.toml").path
        }
        _ = try await client.request("config/value/write", params: CodexJSONObject(params))
        _ = try await client.requestWithNullParams("config/mcpServer/reload")
        await refreshMCPStatus()
    }

    /// Explicit one-way bridge for a repo's checked-in Claude MCP file. Codex
    /// has its own config hierarchy, so copying is opt-in and never touches
    /// Claude's user-level secrets or auth cache.
    func importClaudeProjectMCPServers() async throws -> Int {
        guard let client, let cwd else { throw CodexAppServerError.notRunning }
        let source = cwd.appendingPathComponent(".mcp.json")
        let data = try Data(contentsOf: source)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.rpc(code: nil, message: ".mcp.json is not a JSON object.")
        }
        let rawServers = root["mcpServers"] as? [String: Any] ?? root
        let destinationDirectory = cwd.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("config.toml").path
        var imported = 0
        let allowedNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        for name in rawServers.keys.sorted() {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowedNameCharacters.contains),
                  let raw = rawServers[name] as? [String: Any],
                  let mapped = Self.codexMCPConfig(fromClaude: raw) else { continue }
            _ = try await client.request("config/value/write", params: [
                "keyPath": "mcp_servers.\(name)",
                "mergeStrategy": "upsert",
                "value": mapped,
                "filePath": destination
            ])
            imported += 1
        }
        _ = try await client.requestWithNullParams("config/mcpServer/reload")
        await refreshMCPStatus()
        return imported
    }

    private static func codexMCPConfig(fromClaude raw: [String: Any]) -> [String: Any]? {
        var mapped: [String: Any] = ["enabled": raw["disabled"] as? Bool != true]
        if let command = raw["command"] as? String, !command.isEmpty {
            mapped["command"] = command
            if let args = raw["args"] as? [String] { mapped["args"] = args }
            if let env = raw["env"] as? [String: String] { mapped["env"] = env }
            if let cwd = raw["cwd"] as? String { mapped["cwd"] = cwd }
            return mapped
        }
        if let url = raw["url"] as? String, !url.isEmpty {
            mapped["url"] = url
            if let headers = raw["headers"] as? [String: String] { mapped["http_headers"] = headers }
            return mapped
        }
        return nil
    }

    private func openThreadIfNeeded() async throws {
        guard threadId == nil, let client, let cwd else { state = .ready; return }
        var params: [String: Any] = [
            "cwd": cwd.path,
            "approvalPolicy": permissionMode,
            "sandbox": "workspace-write"
        ]
        if !model.isEmpty { params["model"] = model }
        let response: CodexJSONObject
        if let resumeThreadId {
            params["threadId"] = resumeThreadId
            response = try await client.request("thread/resume", params: CodexJSONObject(params))
        } else {
            response = try await client.request("thread/start", params: CodexJSONObject(params))
        }
        if let thread = response["thread"] as? [String: Any] {
            threadId = thread["id"] as? String
            if transcript.isEmpty,
               let turns = thread["turns"] as? [[String: Any]], !turns.isEmpty {
                transcript = Self.transcript(from: turns)
            }
        }
        if let actual = response["model"] as? String { model = actual }
        if let actual = response["reasoningEffort"] as? String { effort = actual }
        state = .ready
    }

    /// Internal, not private: exercised directly by CodexSessionMappingTests
    /// with synthetic wire payloads so the live notification path (reasoning
    /// deltas, item/started pairing, turn/plan/updated → taskItems,
    /// structured warnings) is regression-tested without a real app-server
    /// process — the same reasoning turnStartParams already documents for
    /// staying a pure builder.
    func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "account/login/completed", "account/updated":
            loginInProgress = false
            Task { [weak self] in
                guard let self else { return }
                await self.refreshAccount()
                await self.refreshModels()
                if !self.requiresChatGPTLogin { try? await self.openThreadIfNeeded() }
            }
        case "mcpServer/oauthLogin/completed", "mcpServer/startupStatus/updated":
            Task { [weak self] in await self?.refreshMCPStatus() }
        case "account/rateLimits/updated":
            if let snapshot = params["rateLimits"] as? [String: Any],
               let parsed = V2UsageLimits.fromCodex(snapshot) {
                for window in V2UsageLimits.crossings(from: usageLimits, to: parsed) {
                    transcript.append(.systemNote(kind: .info, text: V2UsageLimits.crossingMessage(for: window)))
                }
                usageLimits = parsed
            }
        case "turn/started":
            turnId = (params["turn"] as? [String: Any])?["id"] as? String
            if turnStartedAt == nil { turnStartedAt = Date() }
            state = .working
        case "turn/completed":
            finalizeStreamingText()
            let turn = params["turn"] as? [String: Any]
            if let error = turn?["error"] as? [String: Any] {
                appendError(error["message"] as? String ?? "Codex turn failed.")
            }
            // A turn genuinely finishing means every approval it could have
            // needed is settled — any card still up (or anything still
            // queued behind it) belongs to this now-dead turn.
            pendingPermission = nil
            pendingUserInput = nil
            requestedPermissionGrant = nil
            codexRequestQueue.removeAll()
            turnId = nil
            turnStartedAt = nil
            state = .ready
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String,
               let itemId = params["itemId"] as? String {
                appendTextDelta(delta, itemId: itemId, thinking: false)
            }
        case "item/plan/delta":
            if let delta = params["delta"] as? String,
               let itemId = params["itemId"] as? String {
                appendTextDelta(delta, itemId: itemId, thinking: false)
            }
        // Live reasoning — the schema splits it three ways (summary parts,
        // summary text, raw content text); all three stream into the same
        // .thinking block so Codex gets a genuinely live disclosure like
        // Claude's, not just the completed-item summary.
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String,
               let itemId = params["itemId"] as? String {
                appendTextDelta(delta, itemId: itemId, thinking: true)
            }
        case "item/reasoning/summaryPartAdded":
            if let itemId = params["itemId"] as? String, streamingItemId == itemId {
                appendTextDelta("\n\n", itemId: itemId, thinking: true)
            }
        case "item/started":
            if let item = params["item"] as? [String: Any] { handleStartedItem(item) }
        // Output/progress deltas for in-progress items. Buffered as a
        // fallback for the completed item's own aggregated field, not
        // rendered live token-by-token — Atelier doesn't stream Bash
        // tool_result live for Claude either, so this matches existing
        // behavior rather than inventing a new live surface.
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            if let itemId = params["itemId"] as? String, let delta = params["delta"] as? String {
                liveItemOutput[itemId, default: ""] += delta
            }
        case "item/mcpToolCall/progress":
            if let itemId = params["itemId"] as? String, let message = params["message"] as? String {
                toolLiveStatus[itemId] = message
            }
        case "item/fileChange/patchUpdated":
            if let itemId = params["itemId"] as? String,
               let changes = params["changes"] as? [[String: Any]] {
                liveItemOutput[itemId] = Self.diffSummary(changes)
            }
        case "turn/diff/updated":
            latestTurnDiff = params["diff"] as? String
        case "turn/plan/updated":
            if let steps = params["plan"] as? [[String: Any]] { handlePlanUpdated(steps) }
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] {
                contextWindow = usage["modelContextWindow"] as? Int
                totalTokens = ((usage["total"] as? [String: Any])?["totalTokens"] as? Int) ?? totalTokens
            }
        case "thread/compacted":
            finalizeStreamingText()
            transcript.append(.compactBoundary)
        case "model/rerouted":
            let from = params["fromModel"] as? String
            let to = params["toModel"] as? String
            transcript.append(.assistantBlock(.fallback(fromModel: from, toModel: to)))
            if let to { model = to }
        case "item/completed":
            if let item = params["item"] as? [String: Any] { handleCompletedItem(item) }
        // Structured warnings/errors the schema exposes independently of
        // turn/completed's own inline error field — surfaced as system
        // notes so they're seen rather than logged at debug level only.
        case "warning", "guardianWarning":
            if let message = params["message"] as? String { appendWarning(message) }
        case "configWarning", "deprecationNotice":
            if let summary = params["summary"] as? String {
                let details = params["details"] as? String
                appendWarning(details.map { "\(summary) — \($0)" } ?? summary)
            }
        case "error":
            if let error = params["error"] as? [String: Any], let message = error["message"] as? String {
                let willRetry = params["willRetry"] as? Bool ?? false
                appendError(willRetry ? "\(message) (retrying)" : message)
            }
        default:
            log.debug("Unhandled Codex notification: \(method, privacy: .public)")
        }
    }

    /// One synthetic TaskUpdate call the first time a plan arrives — the
    /// shared V2AssistantBlock TaskCreate/TaskUpdate branch always renders
    /// the session's CURRENT taskItems regardless of which row triggered
    /// it (see its doc comment), so one anchor row is enough for the
    /// checklist to stay live across every subsequent update.
    private func handlePlanUpdated(_ steps: [[String: Any]]) {
        taskItems = steps.map { step in
            let rawStatus = step["status"] as? String ?? "pending"
            let status = rawStatus == "inProgress" ? "in_progress" : rawStatus
            let text = step["step"] as? String ?? ""
            return V2TaskItem(id: "plan-\(text.hashValue)", subject: text, status: status)
        }
        if !sawPlanUpdate {
            sawPlanUpdate = true
            transcript.append(.assistantBlock(.toolUse(id: "codex-plan", name: "TaskUpdate", input: .object([:]))))
        }
    }

    private func appendWarning(_ text: String) {
        transcript.append(.systemNote(kind: .info, text: text))
    }

    /// Internal, not private — same reasoning as handleNotification: lets
    /// CodexSessionMappingTests drive concurrent approval requests directly
    /// without a real app-server client (respondToPermission/
    /// respondToUserInput both need a live client to go further, so the
    /// promote-on-respond half isn't unit-testable here, but the
    /// queue-rather-than-clobber half — the actual bug — is).
    func handleServerRequest(id: String, method: String, params: [String: Any]) {
        switch method {
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap(Self.decodeToolQuestion)
            guard !questions.isEmpty else {
                try? client?.respond(id: id, result: ["answers": [:]])
                return
            }
            presentOrQueue(.userInput(PendingCodexUserInput(
                requestId: id, kind: .tool, title: "Codex needs your input", questions: questions
            )))
            return
        case "mcpServer/elicitation/request":
            if params["mode"] as? String == "url" {
                let url = params["url"] as? String ?? ""
                presentOrQueue(.permission(PendingCodexApproval(
                    requestId: id, kind: .mcp, title: "MCP authorization",
                    previewText: [params["message"] as? String, url].compactMap { $0 }.joined(separator: "\n")
                ), grant: nil))
                return
            }
            let questions = Self.decodeMCPQuestions(params["requestedSchema"] as? [String: Any] ?? [:])
            presentOrQueue(.userInput(PendingCodexUserInput(
                requestId: id, kind: .mcp,
                title: params["message"] as? String ?? "MCP server needs information",
                questions: questions
            )))
            return
        case "currentTime/read":
            try? client?.respond(id: id, result: ["currentTimeAt": Int(Date().timeIntervalSince1970)])
            return
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            break
        default:
            log.error("Unsupported Codex server request: \(method, privacy: .public)")
            try? client?.respondError(id: id, code: -32601, message: "Atelier does not support server request \(method)")
            return
        }
        let lower = method.lowercased()
        let preview: String
        let kind: PendingCodexApproval.Kind
        let title: String
        var grant: [String: Any]?
        if lower.contains("commandexecution") || params["command"] != nil {
            kind = .command; title = "Run command"
            preview = params["command"] as? String ?? params["reason"] as? String ?? "Command execution"
        } else if lower.contains("filechange") {
            kind = .fileChange; title = "Apply file changes"
            preview = params["reason"] as? String ?? params["grantRoot"] as? String ?? "Workspace file changes"
        } else if lower.contains("permission") {
            kind = .permissions; title = "Grant permissions"
            preview = params["reason"] as? String ?? params["cwd"] as? String ?? "Additional permissions"
            grant = params["permissions"] as? [String: Any]
        } else {
            kind = .mcp; title = "MCP request"
            preview = params["message"] as? String ?? "An MCP server needs confirmation"
        }
        presentOrQueue(.permission(
            PendingCodexApproval(requestId: id, kind: kind, title: title, previewText: preview),
            grant: grant
        ))
    }

    private static func decodeToolQuestion(_ raw: [String: Any]) -> CodexInputQuestion? {
        guard let id = raw["id"] as? String, let prompt = raw["question"] as? String else { return nil }
        let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return CodexInputQuestion(
            id: id, header: raw["header"] as? String ?? id, prompt: prompt,
            options: options, isSecret: raw["isSecret"] as? Bool ?? false,
            required: true, valueType: .string
        )
    }

    private static func decodeMCPQuestions(_ schema: [String: Any]) -> [CodexInputQuestion] {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().map { key in
            let raw = properties[key] ?? [:]
            let type = raw["type"] as? String ?? "string"
            let valueType: CodexInputQuestion.ValueType = type == "boolean" ? .boolean : (type == "number" || type == "integer" ? .number : .string)
            let options = raw["enum"] as? [String] ?? (valueType == .boolean ? ["true", "false"] : [])
            return CodexInputQuestion(
                id: key, header: raw["title"] as? String ?? key,
                prompt: raw["description"] as? String ?? raw["title"] as? String ?? key,
                options: options, isSecret: (raw["format"] as? String) == "password",
                required: required.contains(key), valueType: valueType
            )
        }
    }

    private func appendTextDelta(_ delta: String, itemId: String, thinking: Bool) {
        // A reasoning item and its eventual agentMessage never share an
        // itemId, so switching FROM thinking TO text (or vice versa) for a
        // genuinely new itemId still finalizes the previous block correctly
        // via the itemId check below — the thinking flag only matters for
        // which ContentBlock case the CURRENT stream commits into.
        if streamingItemId != itemId {
            finalizeStreamingText()
            streamingItemId = itemId
            streamingIsThinking = thinking
            streamBuffer = ""
            transcript.append(.assistantBlock(thinking ? .thinking(text: "", signature: nil) : .text("")))
            streamingIndex = transcript.count - 1
        }
        streamBuffer.append(delta)
        lastStreamActivityAt = Date()
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + streamFlushInterval) { [weak self] in
            self?.flushStreamingText()
        }
    }

    private func flushStreamingText() {
        flushPending = false
        guard let index = streamingIndex, transcript.indices.contains(index) else { return }
        transcript[index] = .assistantBlock(streamingIsThinking ? .thinking(text: streamBuffer, signature: nil) : .text(streamBuffer))
    }

    private func finalizeStreamingText() {
        flushStreamingText()
        if let streamingItemId { renderedItemIDs.insert(streamingItemId) }
        streamingIndex = nil
        streamingItemId = nil
        streamingIsThinking = false
        streamBuffer = ""
    }

    /// Item lifecycle start — shown immediately for calls that take real
    /// time (command/file/MCP/dynamic-tool/collab-agent), mirroring how
    /// Claude's tool_use block appears before its tool_result. Text-bearing
    /// types (userMessage/agentMessage/plan/reasoning) are intentionally
    /// skipped here — those stream in via their own delta notifications and
    /// would otherwise double-render an empty row.
    private func handleStartedItem(_ item: [String: Any]) {
        guard let id = item["id"] as? String, !renderedItemIDs.contains(id),
              startedItemIndex[id] == nil else { return }
        let type = item["type"] as? String ?? ""
        let liveTypes: Set<String> = [
            "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall",
        ]
        guard liveTypes.contains(type), let call = Self.toolUseItem(from: item, type: type) else { return }
        transcript.append(.assistantBlock(call))
        startedItemIndex[id] = transcript.count - 1
        toolStartTimes[id] = Date()
    }

    private func handleCompletedItem(_ item: [String: Any]) {
        guard let id = item["id"] as? String, !renderedItemIDs.contains(id) else { return }
        // The sent message is already on screen — send() appends it the
        // moment you hit return. The app-server then echoes that same
        // message back as a completed userMessage item, and rendering the
        // echo painted every sentence twice. Only the LIVE path skips it:
        // history (thread/read preload, thread/resume turns) doesn't pass
        // through here and still renders user rows via transcriptItem.
        if item["type"] as? String == "userMessage" {
            renderedItemIDs.insert(id)
            return
        }
        if id == streamingItemId { finalizeStreamingText(); return }
        // Learn this agent's name before mapping, so a subAgentActivity
        // item names itself and every later collab result can resolve it.
        if item["type"] as? String == "subAgentActivity",
           let threadId = item["agentThreadId"] as? String,
           let path = item["agentPath"] as? String {
            subAgentNames[threadId] = path
        }
        Self.applySubagentEvent(item, to: &subagentRuns, names: subAgentNames, now: Date())
        let mapped = Self.transcriptItem(
            from: item,
            alreadyStarted: startedItemIndex[id] != nil,
            liveOutput: liveItemOutput[id],
            agentNames: subAgentNames
        )
        guard !mapped.isEmpty else { return }
        transcript.append(contentsOf: mapped)
        renderedItemIDs.insert(id)
        startedItemIndex.removeValue(forKey: id)
        liveItemOutput.removeValue(forKey: id)
        toolLiveStatus.removeValue(forKey: id)
        if let outcome = Self.terminalOutcome(for: item) {
            toolOutcomes[id] = outcome
        } else {
            toolStartTimes.removeValue(forKey: id)
        }
    }

    /// true = failed, false = succeeded, nil = this item type has no
    /// pass/fail concept (e.g. userMessage) — callers treat nil as "clear
    /// the running-state timer without recording an outcome".
    private static func terminalOutcome(for item: [String: Any]) -> Bool? {
        switch item["type"] as? String ?? "" {
        case "commandExecution":
            switch item["status"] as? String {
            case "completed": return false
            case "failed", "declined": return true
            default: return nil
            }
        case "fileChange":
            switch item["status"] as? String {
            case "completed": return false
            case "failed", "declined": return true
            default: return nil
            }
        case "mcpToolCall", "dynamicToolCall":
            switch item["status"] as? String {
            case "completed": return false
            case "failed": return true
            default: return nil
            }
        case "collabAgentToolCall":
            switch item["status"] as? String {
            case "completed": return false
            case "failed": return true
            default: return nil
            }
        // These three ThreadItem types have no in-progress phase surfaced to
        // us (no item/started handling, no status field) — they arrive via
        // item/completed already finished, so V2LiveToolWidget must see a
        // resolved outcome immediately or it renders a spinner that can
        // never resolve.
        case "webSearch", "imageView", "imageGeneration":
            return false
        default:
            return nil
        }
    }

    private func handleTermination(_ reason: String) {
        guard state != .closing else { return }
        if case .terminated = state { return }
        // .hibernated: WE dropped that process on purpose. The exit is
        // expected and the state has to survive it — failing here would
        // undo every hibernation the moment it happened.
        if state == .hibernated { return }
        client = nil
        fail(reason)
    }

    private func fail(_ message: String, terminal: Bool = true) {
        // Covers every failure path out of start() — spawn error,
        // unverifiable account, process death — so a wake that never
        // reached a live thread hands the typed message back rather than
        // losing it.
        returnPendingWakeSendToComposer()
        endError = message
        appendError(message)
        if terminal { state = .terminated(reason: message) }
    }

    private func appendError(_ message: String) {
        transcript.append(.systemNote(kind: .error, text: message))
    }

    static func decodeModel(_ raw: [String: Any]) -> CodexModel? {
        guard let id = raw["id"] as? String else { return nil }
        let efforts = (raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { effort -> CodexReasoningEffort? in
            guard let id = effort["reasoningEffort"] as? String else { return nil }
            return CodexReasoningEffort(id: id, description: effort["description"] as? String ?? "")
        }
        return CodexModel(
            id: id,
            model: raw["model"] as? String ?? id,
            displayName: raw["displayName"] as? String ?? id,
            description: raw["description"] as? String ?? "",
            isDefault: raw["isDefault"] as? Bool ?? false,
            defaultReasoningEffort: raw["defaultReasoningEffort"] as? String ?? efforts.first?.id ?? "",
            supportedReasoningEfforts: efforts,
            inputModalities: raw["inputModalities"] as? [String] ?? ["text"]
        )
    }

    static func transcript(from turns: [[String: Any]]) -> [TranscriptItem] {
        let items = turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        // Two passes: only subAgentActivity carries the threadId→name
        // mapping, and it can land AFTER the collab call that targeted
        // that agent. Indexing first means a restored transcript always
        // renders names, never raw thread ids.
        let names = agentNameIndex(items)
        return items.flatMap { transcriptItem(from: $0, agentNames: names) }
    }

    /// threadId → agentPath, harvested from subAgentActivity items.
    static func agentNameIndex(_ items: [[String: Any]]) -> [String: String] {
        var index: [String: String] = [:]
        for item in items where item["type"] as? String == "subAgentActivity" {
            if let id = item["agentThreadId"] as? String, let path = item["agentPath"] as? String {
                index[id] = path
            }
        }
        return index
    }

    /// Maps a completed ThreadItem to zero or more transcript rows. Two-item
    /// results (toolUse + toolResult) mirror Claude's own tool_use/
    /// tool_result pairing so they render through the identical
    /// V2LiveToolWidget/V2LiveToolResult path. `alreadyStarted`/`liveOutput`
    /// let a live session skip re-appending a call already shown via
    /// item/started and fall back to buffered deltas when a field the
    /// completed item was expected to carry is missing.
    ///
    /// Every one of the schema's 18 ThreadItem variants is handled — no
    /// known type may silently return nil (regression coverage below tests
    /// this directly against the installed app-server's discriminators).
    static func transcriptItem(
        from item: [String: Any], alreadyStarted: Bool = false, liveOutput: String? = nil,
        agentNames: [String: String] = [:]
    ) -> [TranscriptItem] {
        let type = item["type"] as? String ?? ""
        let id = item["id"] as? String ?? UUID().uuidString

        func call() -> TranscriptItem? {
            guard !alreadyStarted, let block = toolUseItem(from: item, type: type) else { return nil }
            return .assistantBlock(block)
        }
        func result(content: String, isError: Bool) -> TranscriptItem {
            .assistantBlock(.toolResult(toolUseId: id, content: .text(content), isError: isError))
        }

        switch type {
        case "userMessage":
            let text = (item["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? [] : [.userText(text)]

        case "hookPrompt":
            let text = (item["fragments"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String ?? $0["content"] as? String }
                .joined(separator: "\n")
            return text.isEmpty ? [] : [.systemNote(kind: .hook, text: text)]

        case "agentMessage", "plan":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.assistantBlock(.text(text))]

        case "reasoning":
            let summary = ((item["summary"] as? [String]) ?? []).joined(separator: "\n")
            let content = ((item["content"] as? [String]) ?? []).joined(separator: "\n")
            let text = summary.isEmpty ? content : summary
            return text.isEmpty ? [] : [.assistantBlock(.thinking(text: text, signature: nil))]

        case "commandExecution":
            let status = item["status"] as? String
            guard status == "completed" || status == "failed" || status == "declined" else {
                return [call()].compactMap { $0 }
            }
            let output = item["aggregatedOutput"] as? String ?? liveOutput ?? ""
            let exitCode = (item["exitCode"] as? NSNumber)?.intValue
            let text = exitCode.map { "\(output)\n\nexit code \($0)" } ?? output
            return [call(), result(content: text, isError: status != "completed")].compactMap { $0 }

        case "fileChange":
            let status = item["status"] as? String
            guard status == "completed" || status == "failed" || status == "declined" else {
                return [call()].compactMap { $0 }
            }
            let changes = item["changes"] as? [[String: Any]] ?? []
            let text = liveOutput ?? diffSummary(changes)
            return [call(), result(content: text, isError: status != "completed")].compactMap { $0 }

        case "mcpToolCall":
            let status = item["status"] as? String
            guard status == "completed" || status == "failed" else {
                return [call()].compactMap { $0 }
            }
            if let error = item["error"] as? [String: Any], let message = error["message"] as? String {
                return [call(), result(content: message, isError: true)].compactMap { $0 }
            }
            let resultPayload = item["result"] as? [String: Any]
            let contentBlocks = resultPayload?["content"] as? [[String: Any]] ?? []
            let text = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return [call(), result(content: text.isEmpty ? liveOutput ?? "(no output)" : text, isError: status == "failed")]
                .compactMap { $0 }

        case "dynamicToolCall":
            let status = item["status"] as? String
            guard status == "completed" || status == "failed" else {
                return [call()].compactMap { $0 }
            }
            let items = item["contentItems"] as? [[String: Any]] ?? []
            let text = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let success = item["success"] as? Bool ?? (status == "completed")
            return [call(), result(content: text.isEmpty ? "(no output)" : text, isError: !success)].compactMap { $0 }

        case "collabAgentToolCall":
            let status = item["status"] as? String
            guard status == "completed" || status == "failed" else {
                return [call()].compactMap { $0 }
            }
            return [call(), result(
                content: collabResultText(item, agentNames: agentNames),
                isError: status == "failed"
            )].compactMap { $0 }

        case "subAgentActivity":
            let kind = item["kind"] as? String ?? "activity"
            let path = item["agentPath"] as? String ?? "sub-agent"
            // Was "\(path) \(kind)" — which rendered as the bare, baffling
            // line "/root interacted". Name the category and use the
            // agent's own leaf name.
            let phrase: String
            switch kind {
            case "started": phrase = "started"
            case "interrupted": phrase = "was interrupted"
            default: phrase = kind
            }
            return [.systemNote(kind: .info, text: "sub-agent \(agentDisplayName(path)) \(phrase)")]

        case "webSearch":
            let query = item["query"] as? String ?? ""
            return [.assistantBlock(.toolUse(id: id, name: "WebSearch", input: .object(["query": .string(query)])))]

        case "imageView":
            let path = item["path"] as? String ?? ""
            return [.assistantBlock(.toolUse(id: id, name: "Read", input: .object(["file_path": .string(path)])))]

        case "sleep":
            let ms = (item["durationMs"] as? NSNumber)?.intValue ?? 0
            return [.systemNote(kind: .info, text: "waited \(ms)ms")]

        case "imageGeneration":
            var input: [String: JSONValue] = ["result": .string(item["result"] as? String ?? "")]
            if let prompt = item["revisedPrompt"] as? String { input["revisedPrompt"] = .string(prompt) }
            if let saved = item["savedPath"] as? String { input["savedPath"] = .string(saved) }
            return [.assistantBlock(.toolUse(id: id, name: "ImageGeneration", input: .object(input)))]

        case "enteredReviewMode":
            return [.systemNote(kind: .info, text: "entered review mode: \(item["review"] as? String ?? "")")]
        case "exitedReviewMode":
            return [.systemNote(kind: .info, text: "exited review mode: \(item["review"] as? String ?? "")")]

        case "contextCompaction":
            return [.compactBoundary]

        default:
            // Genuinely unknown future variant — an honest fallback row
            // beats silently vanishing (fix design §2's explicit rule).
            return [.systemNote(kind: .info, text: "[\(type.isEmpty ? "unknown item" : type)]")]
        }
    }

    /// The initial toolUse block for a live or completed call — factored out
    /// of transcriptItem so item/started (call-only) and item/completed
    /// (call+result) build the identical call representation.
    private static func toolUseItem(from item: [String: Any], type: String) -> ContentBlock? {
        let id = item["id"] as? String ?? UUID().uuidString
        switch type {
        case "commandExecution":
            let input: JSONValue = .object([
                "command": .string(item["command"] as? String ?? ""),
                "cwd": .string(item["cwd"] as? String ?? ""),
            ])
            return .toolUse(id: id, name: "Bash", input: input)
        case "fileChange":
            return .toolUse(id: id, name: "Edit", input: jsonValue(item["changes"] ?? []))
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            return .toolUse(id: id, name: "mcp__\(server)__\(tool)", input: jsonValue(item["arguments"] ?? [:]))
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            return .toolUse(id: id, name: tool, input: jsonValue(item["arguments"] ?? [:]))
        case "collabAgentToolCall":
            let tool = item["tool"] as? String ?? "collab"
            var input: [String: JSONValue] = [:]
            if let prompt = item["prompt"] as? String { input["prompt"] = .string(prompt) }
            if let model = item["model"] as? String { input["model"] = .string(model) }
            return .toolUse(id: id, name: "collab.\(tool)", input: .object(input))
        default:
            return nil
        }
    }

    /// Folds one ThreadItem into the sub-agent run registry, keyed by the
    /// spawning collab call's item id (what an inline delegation card looks
    /// itself up by) with the agent's thread id carried alongside (what
    /// every later status update is keyed by).
    ///
    /// Pure and static so the whole lifecycle is testable without a live
    /// app-server. Live-only by design, exactly like Claude's registry —
    /// a restored transcript renders its delegation blocks from history and
    /// the card degrades to a static row.
    static func applySubagentEvent(
        _ item: [String: Any],
        to runs: inout [V2SubagentRun],
        names: [String: String],
        now: Date
    ) {
        func indexOf(threadId: String) -> Int? {
            runs.firstIndex { $0.threadId == threadId }
        }
        func finish(_ idx: Int, _ state: V2SubagentRun.State, message: String?) {
            guard runs[idx].state == .running else { return }
            runs[idx].state = state
            runs[idx].finishedAt = now
            if let message, !message.isEmpty { runs[idx].resultText = message }
        }

        switch item["type"] as? String {
        case "collabAgentToolCall":
            let tool = item["tool"] as? String ?? ""
            let receivers = item["receiverThreadIds"] as? [String] ?? []
            if tool == "spawnAgent", let callId = item["id"] as? String {
                for threadId in receivers where indexOf(threadId: threadId) == nil {
                    let name = names[threadId].map(agentDisplayName)
                    runs.append(V2SubagentRun(
                        toolUseId: callId,
                        description: spawnDescription(item, fallback: name),
                        agentType: name ?? "sub-agent",
                        // Codex sub-agents always run concurrently with the
                        // parent — there's no synchronous variant.
                        isBackground: true,
                        startedAt: now,
                        threadId: threadId
                    ))
                }
            }
            // Any collab call can report status for agents it touched.
            for (threadId, raw) in item["agentsStates"] as? [String: [String: Any]] ?? [:] {
                guard let idx = indexOf(threadId: threadId) else { continue }
                let message = (raw["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                switch raw["status"] as? String {
                case "completed":
                    finish(idx, .completed, message: message)
                case "errored", "interrupted":
                    finish(idx, .failed, message: message)
                case "shutdown", "notFound":
                    // The agent is gone and can no longer report back —
                    // never leave it claiming to still be running.
                    finish(idx, .orphaned, message: message)
                default:
                    if let message, !message.isEmpty { runs[idx].resultText = message }
                }
            }

        case "subAgentActivity":
            guard let threadId = item["agentThreadId"] as? String else { return }
            // A name may arrive only now; backfill it onto a run spawned
            // before the agent identified itself.
            if let idx = indexOf(threadId: threadId) {
                if let path = item["agentPath"] as? String {
                    let name = agentDisplayName(path)
                    runs[idx].agentType = name
                    if runs[idx].description.isEmpty { runs[idx].description = name }
                }
                if item["kind"] as? String == "interrupted" {
                    finish(idx, .failed, message: "interrupted")
                }
            }

        default:
            break
        }
    }

    /// A spawn's prompt is the closest thing Codex has to Claude's
    /// `description` — take its first meaningful line so a card reads like
    /// a task, not a wall of prompt.
    private static func spawnDescription(_ item: [String: Any], fallback: String?) -> String {
        let prompt = (item["prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = prompt.split(separator: "\n").first.map(String.init), !first.isEmpty else {
            return fallback ?? "sub-agent"
        }
        return first.count > 90 ? String(first.prefix(89)) + "…" : first
    }

    /// Codex names agents by path: "/root" is the main thread (verified in
    /// real rollouts — list_agents reports it as `{"agent_name":"/root",
    /// …,"last_task_message":"Main thread"}`), and children are
    /// "/root/<name>". Show the leaf, not the path, so a delegation row
    /// reads "audit_measure_backend" rather than a filesystem-looking string.
    static func agentDisplayName(_ path: String) -> String {
        if path == "/root" { return "main thread" }
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return leaf.isEmpty ? path : leaf
    }

    /// A thread id shown when no name is known yet — the full UUIDv7 is
    /// unreadable in a transcript row.
    static func shortThreadId(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// The result row for a collab (multi-agent) tool call.
    ///
    /// Replaces a literal "(no agent state)" placeholder that fired often
    /// and told the user nothing. Three real problems, all fixed here:
    /// `agentsStates` is documented "when available" so an empty map is
    /// NORMAL rather than an error worth a mystery string; the map's keys
    /// are raw thread UUIDs, which need resolving to agent names; and
    /// iterating a Swift dictionary is order-UNSTABLE, so the same call
    /// could render its agents in a different order on every re-render.
    static func collabResultText(_ item: [String: Any], agentNames: [String: String]) -> String {
        func label(_ threadId: String) -> String {
            agentNames[threadId].map(agentDisplayName) ?? shortThreadId(threadId)
        }

        let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
        if !states.isEmpty {
            // Sorted by resolved label so the order is stable across
            // renders and restores.
            return states.keys
                .map { (label: label($0), state: states[$0] ?? [:]) }
                .sorted { $0.label < $1.label }
                .map { entry in
                    let status = entry.state["status"] as? String ?? "unknown"
                    let message = (entry.state["message"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = (message?.isEmpty == false) ? ": \(message!)" : ""
                    return "\(entry.label) — \(status)\(detail)"
                }
                .joined(separator: "\n")
        }

        // No state reported: say what the call DID, from the fields that
        // are always present, instead of claiming there's nothing to show.
        let verb: String
        switch item["tool"] as? String ?? "" {
        case "spawnAgent":  verb = "spawned"
        case "sendInput":   verb = "sent input to"
        case "resumeAgent": verb = "resumed"
        case "closeAgent":  verb = "closed"
        case "wait":        verb = "waited for"
        default:            verb = "targeted"
        }
        let targets = (item["receiverThreadIds"] as? [String] ?? []).map(label)
        guard !targets.isEmpty else { return "no agent state reported for this call" }
        return "\(verb) \(targets.joined(separator: ", "))"
    }

    /// Compact multi-file diff summary — path + change kind + the diff body,
    /// rendered through V2LiveToolResult's plain monospaced text exactly
    /// like Claude's own tool_result content.
    private static func diffSummary(_ changes: [[String: Any]]) -> String {
        changes.map { change in
            let path = change["path"] as? String ?? "?"
            let kindRaw = change["kind"] as? [String: Any]
            let kind = kindRaw?["type"] as? String ?? "update"
            let diff = change["diff"] as? String ?? ""
            return "\(kind) \(path)\n\(diff)"
        }.joined(separator: "\n\n")
    }

    private static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(jsonValue))
        case let value as [String: Any]: return .object(value.mapValues(jsonValue))
        default: return .string(String(describing: any))
        }
    }
}
