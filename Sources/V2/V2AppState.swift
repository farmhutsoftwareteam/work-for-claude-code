// Multi-session state for the v2 window. One V2Tab per pane, each owning its
// own StreamSession in the project's cwd. Selection in the left rail picks
// the active project; the session tabs strip switches between live tabs.
//
// Each tab carries a `mode` — Mode B (native stream-json chat, default) or
// Mode A (existing SwiftTerm terminal, spawned via TerminalsController). The
// flip is non-destructive at the project level — the cwd stays — but the
// process backing the visible surface terminates when switching modes.

import Foundation
import SwiftUI
import Combine

@MainActor
final class V2AppState: ObservableObject {
    @Published var tabs: [V2Tab] = []
    @Published var activeTabId: V2Tab.ID?

    /// Project the left rail is currently focused on. New tabs spawn in this
    /// project's cwd. Defaults to the first project in Store.
    @Published var selectedProjectCwd: URL?
    @Published var selectedProjectName: String = ""

    /// Resolved on first appear; cached until app restart.
    @Published var claudeBinary: URL?
    @Published var claudeVersion: SemVer?

    /// Reference to the existing v1 TerminalsController. Mode-A tabs delegate
    /// process management to it; flipMode wires through here. Set once on
    /// first appear of V2RootView (see `.attach(terminals:)`).
    weak var terminals: TerminalsController?

    /// Bubbles up StreamSession state changes so the UI can react without
    /// every view subscribing to every tab.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Active tab access

    var activeTab: V2Tab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    var activeSession: StreamSession? { activeTab?.session }

    // MARK: - Setup

    func attach(terminals: TerminalsController) {
        self.terminals = terminals
    }

    // MARK: - Project selection

    func selectProject(cwd: String, name: String) {
        selectedProjectCwd = URL(fileURLWithPath: cwd)
        selectedProjectName = name
    }

    // MARK: - Tab management

    /// Create a new tab in the currently-selected project. Default mode = B.
    func newTab() {
        guard let cwd = selectedProjectCwd else { return }
        let session = StreamSession()
        let tab = V2Tab(
            cwd: cwd,
            projectName: selectedProjectName,
            session: session
        )
        tabs.append(tab)
        activeTabId = tab.id

        // Re-publish StreamSession changes through V2AppState so the chrome
        // (tab chips / session header) reacts to lifecycle transitions.
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Re-publish V2Tab.mode changes too.
        tab.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func activate(tabId: V2Tab.ID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
    }

    func close(tabId: V2Tab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[idx]
        // Tear down whatever surface is active.
        switch tab.mode {
        case .modeB:
            tab.session.stop()
        case .modeA(let terminalTabId):
            terminals?.close(terminalTabId)
        }
        tabs.remove(at: idx)
        if activeTabId == tabId {
            activeTabId = tabs.last?.id
        }
    }

    /// Start the active tab's session if it's still idle (Mode B only).
    func startActiveSession() {
        guard let tab = activeTab,
              case .modeB = tab.mode,
              let binary = claudeBinary,
              tab.session.state == .idle else { return }
        tab.session.start(cwd: tab.cwd, claudeURL: binary)
    }

    /// Flip the active tab between Mode A (SwiftTerm) and Mode B (native chat).
    /// Idempotent on no active tab. Terminates the outgoing surface's process.
    func flipActiveMode() {
        guard let tab = activeTab else { return }
        flipMode(tab: tab)
    }

    func flipMode(tab: V2Tab) {
        switch tab.mode {
        case .modeB:
            // Going B → A. Stop the StreamSession (it'll be idle after) and
            // spawn a fresh SwiftTerm session in the same cwd.
            tab.session.stop()
            guard let terminals else { return }
            let termId = terminals.openNew(
                projectCwd: tab.cwd.path,
                title: tab.projectName
            )
            tab.mode = .modeA(terminalTabId: termId)

        case .modeA(let terminalTabId):
            // Going A → B. Close the terminal tab in the existing controller
            // (kills the PTY), reset the StreamSession to a fresh idle one so
            // the user can `Start session` again without zombie state.
            terminals?.close(terminalTabId)
            tab.session = StreamSession()
            tab.mode = .modeB

            // Re-subscribe to the new session's changes.
            tab.session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Binary resolution

    func resolveBinary() {
        guard claudeBinary == nil else { return }
        let url = ClaudeBinary.locate()
        claudeBinary = url
        if let url { claudeVersion = ClaudeBinary.version(at: url) }
    }
}

// MARK: - Mode

enum V2Mode: Equatable {
    case modeB
    case modeA(terminalTabId: UUID)

    var isModeA: Bool {
        if case .modeA = self { return true }
        return false
    }
}

// MARK: - Tab

@MainActor
final class V2Tab: Identifiable, ObservableObject {
    let id = UUID()
    let cwd: URL
    var projectName: String
    @Published var session: StreamSession
    @Published var mode: V2Mode = .modeB

    var displayName: String {
        projectName.isEmpty ? cwd.lastPathComponent : projectName
    }

    init(cwd: URL, projectName: String, session: StreamSession) {
        self.cwd = cwd
        self.projectName = projectName
        self.session = session
    }
}
