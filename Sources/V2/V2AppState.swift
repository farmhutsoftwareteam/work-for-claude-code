// Multi-session state for the v2 window. One V2Tab per pane, each owning its
// own StreamSession in the project's cwd. Selection in the left rail picks
// the active project; the session tabs strip switches between live tabs.
//
// This is the Phase 4 integration layer (#22) — it does NOT touch the existing
// Mode-A TerminalsController. v1 window and v2 window run side-by-side; users
// can adopt Mode-B per-tab without losing the existing terminal surface.

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

    /// Bubbles up StreamSession state changes so the UI can react without
    /// every view subscribing to every tab.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Active tab access

    var activeTab: V2Tab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    var activeSession: StreamSession? { activeTab?.session }

    // MARK: - Project selection

    func selectProject(cwd: String, name: String) {
        selectedProjectCwd = URL(fileURLWithPath: cwd)
        selectedProjectName = name
    }

    // MARK: - Tab management

    /// Create a new tab in the currently-selected project. Auto-activates it.
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

        // Re-publish StreamSession changes through V2AppState so any view
        // observing V2AppState picks up state transitions on the active tab.
        session.objectWillChange
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
        tab.session.stop()
        tabs.remove(at: idx)
        if activeTabId == tabId {
            activeTabId = tabs.last?.id
        }
    }

    /// Start the active tab's session if it's still idle. Spawning is
    /// explicit so the user can browse tabs without burning a claude process
    /// per visit.
    func startActiveSession() {
        guard let tab = activeTab,
              let binary = claudeBinary,
              tab.session.state == .idle else { return }
        tab.session.start(cwd: tab.cwd, claudeURL: binary)
    }

    // MARK: - Binary resolution

    func resolveBinary() {
        guard claudeBinary == nil else { return }
        let url = ClaudeBinary.locate()
        claudeBinary = url
        if let url { claudeVersion = ClaudeBinary.version(at: url) }
    }
}

// MARK: - Tab

@MainActor
final class V2Tab: Identifiable, ObservableObject {
    let id = UUID()
    let cwd: URL
    var projectName: String
    @Published var session: StreamSession

    var displayName: String {
        // Show the project leaf name; fall back to cwd lastPath.
        projectName.isEmpty ? cwd.lastPathComponent : projectName
    }

    init(cwd: URL, projectName: String, session: StreamSession) {
        self.cwd = cwd
        self.projectName = projectName
        self.session = session
    }
}
