import Foundation

/// One tab inside Work. Two flavors:
///
/// - `.modeA` — embedded SwiftTerm session running `claude` interactively.
///   The `LocalProcessTerminalView` is owned by `TerminalsController` so
///   SwiftUI re-renders can't destroy the PTY. This is the v1.x default
///   and what every existing UI path produces unless explicitly opted out.
///
/// - `.modeB` — Mode-B native chat backed by a `StreamSession` actor that
///   speaks `claude -p --output-format stream-json`. No PTY. The
///   StreamSession reference lives directly on the tab so the controller is
///   a single source of truth for both surfaces (v2-redesign branch, #22).
struct TerminalTab: Identifiable {
    let id: UUID
    /// Claude session id (nil when the tab was spawned for a *new* session —
    /// we learn the id later from the JSONL stream or the StreamSession's
    /// `system/init` event).
    var sessionId: String?
    var projectCwd: String
    /// What the tab label shows. Falls back to project name when session is
    /// new and unnamed.
    var title: String
    var state: ProcessState
    let createdAt: Date
    /// Whether this tab's Claude process was spawned with
    /// `--dangerously-skip-permissions`. Preserved across `restart()` so a tab
    /// the user explicitly opted into skip-mode for stays in skip-mode.
    let skipPermissions: Bool

    /// Which UI surface this tab is currently presenting. v1 windows ignore
    /// Mode-B tabs; v2 renders both surfaces depending on this field.
    var surface: Surface = .modeA

    /// Native-chat runtime. Existing tabs decode/behave as Claude; Codex tabs
    /// keep their own app-server session alongside the unchanged Claude path.
    var provider: V2AgentProvider = .claude

    /// Mode-B StreamSession reference. Always non-nil while `surface == .modeB`.
    /// Reference type — the controller stores it here so callers don't have
    /// to keep a sibling dictionary.
    var streamSession: StreamSession?

    /// Mode-B Codex app-server session. Non-nil when provider == .codex.
    var codexSession: CodexSession?

    /// Active loop orchestrator on this tab (issue #24). Non-nil while a loop
    /// is configured or running; cleared when the loop reaches a terminal
    /// state and the user dismisses it.
    var loop: LoopOrchestrator?

    /// Active harness orchestrator on this tab (issue #25). Independent of
    /// `streamSession` — the harness spawns its own per-phase claude -p
    /// processes and persists state to disk.
    var harness: HarnessOrchestrator?

    enum ProcessState: Equatable {
        case running
        case exited(code: Int32?)
        case killed
    }

    enum Surface: String, Equatable, Codable {
        case modeA
        case modeB
    }

    init(
        id: UUID = UUID(),
        sessionId: String? = nil,
        projectCwd: String,
        title: String,
        state: ProcessState = .running,
        createdAt: Date = Date(),
        skipPermissions: Bool = false,
        surface: Surface = .modeA,
        provider: V2AgentProvider = .claude,
        streamSession: StreamSession? = nil,
        codexSession: CodexSession? = nil,
        loop: LoopOrchestrator? = nil,
        harness: HarnessOrchestrator? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectCwd = projectCwd
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.skipPermissions = skipPermissions
        self.surface = surface
        self.provider = provider
        self.streamSession = streamSession
        self.codexSession = codexSession
        self.loop = loop
        self.harness = harness
    }

    /// True while the underlying process is alive. For Mode-A that means the
    /// PTY child is running; for Mode-B it means the StreamSession is past
    /// initialization and hasn't terminated.
    @MainActor
    var isLive: Bool {
        switch surface {
        case .modeA:
            if case .running = state { return true }
            return false
        case .modeB:
            let lifecycle: StreamSession.LifecycleState?
            switch provider {
            case .claude: lifecycle = streamSession?.state
            case .codex: lifecycle = codexSession?.state
            }
            guard let lifecycle else { return false }
            switch lifecycle {
            case .terminated, .idle: return false
            default: return true
            }
        }
    }

    /// Short status suffix shown next to the title when the process has exited.
    var statusSuffix: String {
        switch state {
        case .running:                      return ""
        case .exited(let code) where code == 0: return "(exited)"
        case .exited(let code):             return "(exit \(code.map(String.init) ?? "?"))"
        case .killed:                       return "(killed)"
        }
    }
}

// Identity-by-id equality — needed because the new `streamSession` field is
// a reference type without Equatable, so the compiler can't synthesize ==.
// All existing call sites that compared tabs were comparing identity, so
// this matches semantics.
extension TerminalTab: Equatable {
    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
}
