// Session tabs strip (40px) — one chip per TerminalTab in
// TerminalsController, "+" new-tab button (creates Mode-B tabs by default).

import SwiftUI
import Inject

struct V2SessionTabs: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var terminals: TerminalsController

    var body: some View {
        // Global tab strip: EVERY open chat is a visible tab, regardless of
        // which project the rail is focused on — same model as browser tabs
        // and every modern chat app. The previous per-project filter hid
        // tabs from other projects, so opening a chat in project B made your
        // project-A tab "disappear" from the strip — it felt like the new
        // chat had REPLACED the old one even though both were still alive.
        // Each chip carries a small project sub-label so you always know
        // which project a tab belongs to.
        if allTabs.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(allTabs) { tab in
                        V2TabChip(
                            tab: tab,
                            isActive: tab.id == appState.activeTabId,
                            showProject: multipleProjectsOpen,
                            onActivate: { appState.activate(tabId: tab.id) },
                            onClose: { appState.close(tabId: tab.id) }
                        )
                    }

                    Button { appState.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(v2.faint)
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("New chat in \(appState.selectedProjectName.isEmpty ? "this project" : appState.selectedProjectName) (⌘N)")
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 40)
            .background(v2.paper2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(v2.line).frame(height: 1)
            }
            .enableInjection()
        }
    }

    /// All open tabs across every project — nothing is hidden.
    private var allTabs: [TerminalTab] { terminals.tabs }

    /// Show the per-tab project label only when tabs span more than one
    /// project — no need to repeat the same project name on every chip.
    private var multipleProjectsOpen: Bool {
        Set(terminals.tabs.map { $0.projectCwd }).count > 1
    }
}

private struct V2TabChip: View {
    @Environment(\.v2) private var v2
    let tab: TerminalTab
    let isActive: Bool
    var showProject: Bool = false
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        // SwiftUI on macOS doesn't route taps cleanly through nested
        // Buttons — the previous structure had a Button-inside-a-Button
        // for the hover-only close target, which created a dead zone
        // around the chip's right edge AND made layout shift on every
        // hover toggle (close button appears → chip widens → cursor
        // target moves out from under the press). Switch to:
        //   • outer tap target = a clear rectangle with .onTapGesture
        //   • close button = a separate Button laid on top via overlay,
        //     reserved space so layout doesn't shift when it appears
        HStack(spacing: 8) {
            stateDot
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(isActive ? v2.ink : v2.mute)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showProject {
                    Text(projectLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            closeSlot
        }
        .padding(.horizontal, 11)
        // Chrome-style: fixed-width tabs that truncate their title rather
        // than growing. Bottom-aligned in the 40pt strip with a rounded top
        // so the active tab reads as "raised" into the content below.
        .frame(width: 184, height: 34, alignment: .leading)
        .background(tabShape.fill(isActive ? v2.paper : (hover ? v2.paper3 : Color.clear)))
        .overlay(isActive ? tabShape.stroke(v2.line2, lineWidth: 1) : nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { hover = $0 }
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 8, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 8, style: .continuous
        )
    }

    private var projectLabel: String {
        (tab.projectCwd as NSString).lastPathComponent
    }

    /// Always reserves space so the chip width doesn't twitch. Shown on hover
    /// and always on the active tab (Chrome keeps × visible on the open tab).
    private var closeSlot: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(v2.faint)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity((hover || isActive) ? 1 : 0)
        .allowsHitTesting(hover || isActive)
    }

    @ViewBuilder
    private var stateDot: some View {
        switch tab.surface {
        case .modeA:
            // PTY surface: pulse while live (process running), red when exited.
            if tab.isLive {
                V2PulseDot(size: 7, color: v2.ink)
            } else {
                Circle().fill(v2.del).frame(width: 7, height: 7)
            }
        case .modeB:
            // Reflect StreamSession lifecycle.
            if let s = tab.streamSession {
                switch s.state {
                case .working, .awaitingPermission:
                    V2PulseDot(size: 7, color: v2.ink)
                case .terminated:
                    Circle().fill(v2.del).frame(width: 7, height: 7)
                case .idle:
                    Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
                default:
                    Circle().fill(v2.ink).frame(width: 7, height: 7)
                }
            } else {
                Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
            }
        }
    }
}
