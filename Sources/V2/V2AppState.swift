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

    /// Set once by V2RootView on first appear.
    weak var terminals: TerminalsController?

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
        selectedProjectCwd = URL(fileURLWithPath: cwd)
        selectedProjectName = name
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
        if wasActive {
            activeTabId = tabs.last?.id
        }
    }

    /// Start the active Mode-B tab's session if it's still idle.
    func startActiveSession() {
        guard let tab = activeTab,
              tab.surface == .modeB,
              let session = tab.streamSession,
              let binary = claudeBinary,
              session.state == .idle else { return }
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        session.start(cwd: cwd, claudeURL: binary)
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
