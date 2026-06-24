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
        HStack(spacing: 0) {
            ForEach(terminals.tabs) { tab in
                V2TabChip(
                    tab: tab,
                    isActive: tab.id == appState.activeTabId,
                    onActivate: { appState.activate(tabId: tab.id) },
                    onClose: { appState.close(tabId: tab.id) }
                )
            }

            Button { appState.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(appState.selectedProjectCwd == nil)
            .help(appState.selectedProjectCwd == nil ? "Select a project first" : "New tab")

            Spacer()
        }
        .frame(height: 40)
        .background(v2.paper2)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
    }
}

private struct V2TabChip: View {
    @Environment(\.v2) private var v2
    let tab: TerminalTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 9) {
                stateDot
                Text(tab.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(isActive ? v2.ink : v2.mute)
                if hover {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(v2.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle().fill(v2.ink).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
