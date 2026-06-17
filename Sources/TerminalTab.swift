import Foundation

/// One embedded terminal tab inside Work. Metadata only — the actual
/// `LocalProcessTerminalView` is owned by `TerminalsController` so SwiftUI
/// re-renders can't destroy the PTY.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    /// Claude session id (nil when the tab was spawned for a *new* session —
    /// we learn the id later from the JSONL stream).
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

    enum ProcessState: Equatable {
        case running
        case exited(code: Int32?)
        case killed
    }

    init(
        id: UUID = UUID(),
        sessionId: String? = nil,
        projectCwd: String,
        title: String,
        state: ProcessState = .running,
        createdAt: Date = Date(),
        skipPermissions: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectCwd = projectCwd
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.skipPermissions = skipPermissions
    }

    /// True while the PTY child is alive. Dimmed UI when false.
    var isLive: Bool {
        if case .running = state { return true }
        return false
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
