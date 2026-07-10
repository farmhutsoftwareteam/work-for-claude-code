// ACPSession — the @MainActor ObservableObject the v2 UI binds to, wrapping
// the Foundation-only ACPClient. Phase 4 of the ACP migration.
//
// Deliberately NOT a drop-in for StreamSession's model: we're migrating TO
// ACP, so this exposes an ACP-native published surface (messages, toolCalls,
// plan, permission) that a dedicated ACP chat view renders. The legacy
// StreamSession path is untouched and keeps shipping until ACP reaches
// parity and we flip the default.
//
// ACPClient delivers every consumer callback on the main thread already, so
// the @Published mutations here are main-actor-safe.

import Foundation
import SwiftUI

@MainActor
final class ACPSession: ObservableObject {

    enum Status: Equatable {
        case idle          // not started
        case connecting    // spawning + initialize + session/new
        case ready         // alive, awaiting a prompt
        case working       // a turn is in flight
        case failed(String)
    }

    // MARK: - Published surface (what the ACP chat view renders)

    @Published private(set) var status: Status = .idle
    /// One ordered transcript so messages and tool calls interleave in the
    /// order they actually happened.
    @Published private(set) var transcript: [ACPItem] = []
    @Published private(set) var plan: [ACPPlanEntry] = []
    @Published private(set) var pendingPermission: ACPPermissionRequest?
    @Published private(set) var availableModels: [ACPModel] = []
    @Published private(set) var currentModeId: String = "default"
    @Published private(set) var commands: [ACPCommand] = []
    @Published private(set) var sessionId: String?

    private let client = ACPClient()
    private let cwd: URL
    /// Index of the in-progress assistant message item, so streamed chunks
    /// append to one bubble instead of spawning a new item per chunk.
    private var streamingAssistantIndex: Int?

    /// Coalescing accumulator for onAgentText, mirroring StreamSession's
    /// streamBuffer/commitStreamBuffer pattern (CLAUDE.md streaming rule 1).
    /// Chunks accumulate here — a plain, uniquely-owned String var, O(1)
    /// amortized append — and only get written into the @Published
    /// `transcript` array at ~30fps. The prior code did `m.text += chunk`
    /// on a copy extracted from `transcript[i]` on EVERY network chunk: an
    /// O(message-length) COW copy per delta, i.e. quadratic over a reply —
    /// the exact anti-pattern the project's own performance contract exists
    /// to prevent (bug-hunt #10/M31).
    private var agentTextBuffer = ""
    private var agentTextFlushPending = false
    private static let streamFlushInterval: TimeInterval = 0.033

    init(cwd: URL) {
        self.cwd = cwd
        wireCallbacks()
    }

    // MARK: - Lifecycle

    /// Resolve node + claude-code-acp and connect. `onReady` fires with
    /// success once the session is live.
    func start(onReady: ((Bool) -> Void)? = nil) {
        guard status == .idle else { onReady?(status == .ready); return }
        status = .connecting
        // node()/acpIndexJS() shell out synchronously (`which`, `npm root
        // -g` via a login shell) — on a slow shell rc (nvm/rbenv init) that
        // visibly hitches the UI if run on this @MainActor-isolated class.
        // Resolve them off-main, then hop back to touch state (bug-hunt
        // #13/M34).
        //
        // A plain `Task {}` (not `.detached`) inherits this method's
        // @MainActor isolation, so `onReady`/`self` never get handed into a
        // @Sendable closure — the inner `Task.detached` below only ever
        // touches the pure static `ACPBinaries` resolution, which is what
        // actually needs to leave the main actor. Nesting `MainActor.run`
        // with a `[weak self]`/captured-closure inside `Task.detached` is
        // exactly the shape Swift 6 strict concurrency flags as "sending
        // risks causing data races."
        Task {
            let (node, acp) = await Task.detached {
                (ACPBinaries.node(), ACPBinaries.acpIndexJS())
            }.value
            guard let node, let acp else {
                status = .failed("Couldn't find node or claude-code-acp. Run: npm i -g @zed-industries/claude-code-acp")
                onReady?(false)
                return
            }
            client.start(nodeURL: node, acpIndexJS: acp, cwd: cwd) { [weak self] ok in
                // Already on main (ACPClient hops there).
                guard let self else { return }
                self.status = ok ? .ready : .failed("Failed to start ACP session")
                self.sessionId = self.client.sessionId
                onReady?(ok)
            }
        }
    }

    func prompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(.message(ACPMessage(role: .user, text: trimmed)))
        streamingAssistantIndex = nil  // next agent chunk starts a fresh bubble
        agentTextBuffer = ""           // discard any stale unflushed tail from a prior turn
        agentTextFlushPending = false
        status = .working
        client.prompt(trimmed)
    }

    func resolvePermission(_ optionId: String) {
        guard let req = pendingPermission else { return }
        client.resolvePermission(requestId: req.requestId, optionId: optionId)
        pendingPermission = nil
    }

    func interrupt() { client.cancel() }
    func stop() { client.stop(); status = .idle }
    func setModel(_ id: String) { client.setModel(id) }
    func setMode(_ id: String) { client.setMode(id); currentModeId = id }

    // MARK: - Callback wiring

    private func wireCallbacks() {
        client.onModels = { [weak self] in self?.availableModels = $0 }
        client.onCommands = { [weak self] in self?.commands = $0 }
        client.onModeChanged = { [weak self] in self?.currentModeId = $0 }

        client.onAgentText = { [weak self] chunk in
            guard let self else { return }
            self.agentTextBuffer += chunk
            self.scheduleAgentTextFlush()
        }
        client.onAgentThought = { [weak self] chunk in
            guard let self else { return }
            self.flushAgentTextBuffer()   // preserve transcript order vs. any pending text
            if let last = self.transcript.indices.last,
               case .message(var m) = self.transcript[last], m.role == .thinking {
                m.text += chunk
                self.transcript[last] = .message(m)
            } else {
                self.transcript.append(.message(ACPMessage(role: .thinking, text: chunk)))
            }
            self.streamingAssistantIndex = nil
        }
        client.onToolCall = { [weak self] call in
            guard let self else { return }
            self.flushAgentTextBuffer()   // preserve transcript order vs. any pending text
            if let i = self.transcript.firstIndex(where: {
                if case .tool(let t) = $0 { return t.id == call.id }; return false
            }) {
                self.transcript[i] = .tool(call)
            } else {
                self.transcript.append(.tool(call))
            }
            // A tool call interrupts the current assistant bubble.
            self.streamingAssistantIndex = nil
        }
        client.onPlan = { [weak self] in self?.plan = $0 }
        client.onPermissionRequest = { [weak self] req in self?.pendingPermission = req }
        client.onTurnEnd = { [weak self] _ in
            guard let self else { return }
            self.flushAgentTextBuffer()
            self.status = .ready
            self.streamingAssistantIndex = nil
        }
        client.onError = { [weak self] msg in
            guard let self else { return }
            self.flushAgentTextBuffer()   // preserve transcript order vs. any pending text
            // Surface as a system message; keep the session usable.
            self.transcript.append(.message(ACPMessage(role: .system, text: "⚠ \(msg)")))
            if case .connecting = self.status { self.status = .failed(msg) }
        }
    }

    // MARK: - Streaming text coalescer (see agentTextBuffer doc comment)

    private func scheduleAgentTextFlush() {
        guard !agentTextFlushPending else { return }
        agentTextFlushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamFlushInterval) { [weak self] in
            guard let self, self.agentTextFlushPending else { return }
            self.agentTextFlushPending = false
            self.flushAgentTextBuffer()
        }
    }

    /// Write any buffered-but-uncommitted assistant text into the
    /// transcript now, bypassing the flush timer. Called both by the timer
    /// and by any other transcript-touching event (thought/tool/turn-end/
    /// error) so ordering is preserved — those checks look at
    /// `transcript.indices.last`/`streamingAssistantIndex`, which would be
    /// stale if pending text hasn't landed in the array yet.
    private func flushAgentTextBuffer() {
        agentTextFlushPending = false
        guard !agentTextBuffer.isEmpty else { return }
        let pending = agentTextBuffer
        agentTextBuffer = ""
        if let i = streamingAssistantIndex, transcript.indices.contains(i),
           case .message(var m) = transcript[i], m.role == .assistant {
            m.text += pending
            transcript[i] = .message(m)
        } else {
            transcript.append(.message(ACPMessage(role: .assistant, text: pending)))
            streamingAssistantIndex = transcript.count - 1
        }
    }
}

// MARK: - Transcript model

/// One ordered transcript entry — a chat message or a tool call. Tool calls
/// update in place (matched by toolCallId) as they stream.
enum ACPItem: Identifiable {
    case message(ACPMessage)
    case tool(ACPToolCall)
    var id: String {
        switch self {
        case .message(let m): return "m-\(m.id.uuidString)"
        case .tool(let t):    return "t-\(t.id)"
        }
    }
}

struct ACPMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, thinking, system }
    let id = UUID()
    let role: Role
    var text: String
}

// MARK: - Binary resolution

/// Locates `node` and the `claude-code-acp` entry point. For now resolves
/// installed paths; bundling the Node binary inside the .app is a later
/// Phase-4 hardening step so end users don't need a global install.
enum ACPBinaries {
    static func node() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node",
            "\(NSHomeDirectory())/.nvm/current/bin/node"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        // `which node` against a login shell PATH.
        return which("node")
    }

    static func acpIndexJS() -> URL? {
        let fm = FileManager.default
        // Global npm install locations + a vendored copy next to the app.
        var roots = [
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules",
            "\(NSHomeDirectory())/.npm-global/lib/node_modules"
        ]
        if let npmRoot = which("npm").flatMap({ runCapture($0.deletingLastPathComponent().appendingPathComponent("npm").path, ["root", "-g"]) }) {
            roots.insert(npmRoot.trimmingCharacters(in: .whitespacesAndNewlines), at: 0)
        }
        for root in roots {
            let p = "\(root)/@zed-industries/claude-code-acp/dist/index.js"
            if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    private static func which(_ tool: String) -> URL? {
        guard let out = runCapture("/bin/zsh", ["-lc", "which \(tool)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out)
    }

    private static func runCapture(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
