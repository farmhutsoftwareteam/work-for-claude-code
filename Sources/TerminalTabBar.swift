import SwiftUI
import AppKit

/// Chrome-style persistent tab strip that sits at the top of the detail
/// pane whenever any session is open. One chip per tab + trailing "+".
/// Reorder via drag, close via hover X, right-click for more actions.
///
/// The "+" button anchors a NewSessionPopover where the user can pick the
/// project, (optionally) name the session, or open a fresh directory via
/// NSOpenPanel — matching the "new tab page" affordance in a browser.
struct TerminalTabBar: View {
    @EnvironmentObject var terminals: TerminalsController
    @EnvironmentObject var store: Store
    let onClickTab: (TerminalTab) -> Void
    let onOpenInTerminalApp: (UUID) -> Void

    @State private var draggingTabId: UUID?
    @State private var showNewSessionPopover = false
    /// Tab awaiting the "close confirm" alert. Non-nil ⇒ alert is visible.
    @State private var tabPendingClose: TerminalTab?

    private var pickerProject: Project? {
        store.selectedProject ?? store.projects.first
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(terminals.tabs) { tab in
                    TerminalTabChip(
                        tab: tab,
                        isActive: terminals.activeTabId == tab.id,
                        isBusy: terminals.busyTabIds.contains(tab.id),
                        onClick: {
                            // If activeTabId actually changes, `focus` fires
                            // ContentView's onChange handler which runs
                            // handleTabClick — no need to do it again.
                            // If activeTabId is unchanged (re-clicking the
                            // already-active tab), the user is asking to
                            // come back to this tab from elsewhere in the
                            // sidebar; call onClickTab directly for that.
                            // Previously we called both, doubling work on
                            // every click and producing visible lag.
                            let wasAlreadyActive = terminals.activeTabId == tab.id
                            terminals.focus(tab.id)
                            if wasAlreadyActive { onClickTab(tab) }
                        },
                        onClose: { askClose(tab) },
                        onRestart: { terminals.restart(tabId: tab.id) },
                        onOpenInTerminalApp: { onOpenInTerminalApp(tab.id) }
                    )
                    .onDrag {
                        draggingTabId = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        targetId: tab.id,
                        draggingId: $draggingTabId,
                        terminals: terminals
                    ))
                }

                Button {
                    showNewSessionPopover = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .help("New session… (⌘T)")
                .disabled(pickerProject == nil)
                .popover(isPresented: $showNewSessionPopover, arrowEdge: .bottom) {
                    if let project = pickerProject {
                        NewSessionPopover(
                            currentProject: project,
                            isPresented: $showNewSessionPopover
                        )
                        .environmentObject(store)
                        .environmentObject(terminals)
                    } else {
                        Text("No projects found. Start a Claude session in any directory to create one.")
                            .font(.caption)
                            .padding(14)
                            .frame(width: 260)
                    }
                }

                // End-of-bar drop sink — accepts drops in the trailing space
                // so users can drag a tab "to the end" without having to land
                // it precisely on the last chip.
                Spacer(minLength: 0)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: TabEndDropDelegate(
                        draggingId: $draggingTabId,
                        terminals: terminals
                    ))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.7)
        }
        // SwiftUI alert — always shows both buttons, respects dark mode,
        // destructive button gets proper red tint.
        .alert(
            "Close this session?",
            isPresented: Binding(
                get: { tabPendingClose != nil },
                set: { if !$0 { tabPendingClose = nil } }
            ),
            presenting: tabPendingClose
        ) { tab in
            Button("Close session", role: .destructive) {
                terminals.close(tab.id, force: true)
                tabPendingClose = nil
            }
            Button("Cancel", role: .cancel) {
                tabPendingClose = nil
            }
        } message: { tab in
            Text("The Claude process for '\(tab.title)' is still running. Closing will terminate it.")
        }
    }

    private func askClose(_ tab: TerminalTab) {
        // Exited tabs close immediately — no confirmation needed for a dead
        // process. Live ones route through a SwiftUI alert so the buttons
        // render consistently across macOS versions (the old NSAlert path
        // sometimes cropped the primary button depending on theme).
        guard tab.isLive else {
            terminals.close(tab.id)
            return
        }
        tabPendingClose = tab
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggingId: UUID?
    let terminals: TerminalsController

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingId else { return false }
        guard let src = terminals.tabs.firstIndex(where: { $0.id == draggingId }),
              let dst = terminals.tabs.firstIndex(where: { $0.id == targetId })
        else { return false }
        if src != dst {
            terminals.move(from: src, to: dst + (src < dst ? 1 : 0))
        }
        self.draggingId = nil
        return true
    }
}

/// Drop sink for the trailing empty area of the bar — moves the dragged tab
/// to the very end of the list. Without this users have to land precisely on
/// the last chip to "move to end", which is fiddly.
private struct TabEndDropDelegate: DropDelegate {
    @Binding var draggingId: UUID?
    let terminals: TerminalsController

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingId else { return false }
        guard let src = terminals.tabs.firstIndex(where: { $0.id == draggingId }) else { return false }
        // Only move if not already at the end
        if src != terminals.tabs.count - 1 {
            terminals.move(from: src, to: terminals.tabs.count)
        }
        self.draggingId = nil
        return true
    }
}

// MARK: - Single tab chip

private struct TerminalTabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    let isBusy: Bool
    let onClick: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void
    let onOpenInTerminalApp: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 6) {
                statusDot
                Text(tab.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(tab.isLive ? .primary : .secondary)
                    .lineLimit(1)
                if !tab.statusSuffix.isEmpty {
                    Text(tab.statusSuffix)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 200)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18)
                                   : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            // Restart only meaningful on a live tab — exited ones already
            // need a full Resume from the session list to come back.
            if tab.isLive {
                Button("Restart session") { onRestart() }
                    .help("Kill and respawn this Claude session so it picks up newly-added MCPs, hooks, or skills")
            }
            Button("Close tab") { onClose() }
            Divider()
            Button("Open in Terminal.app") { onOpenInTerminalApp() }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        switch tab.state {
        case .running:              return isBusy ? .orange : .green
        case .exited(let code) where code == 0: return .secondary
        case .exited:               return .red
        case .killed:               return .red
        }
    }
}
