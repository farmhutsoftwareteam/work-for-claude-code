// Session header — bound to V2AppState's active tab (a TerminalTab from
// TerminalsController). Shows project name + LIVE badge driven by surface
// state, path subline with model, dock switcher, mode toggle pill, and
// the live Running pill.

import SwiftUI
import Inject

enum V2DockPanel: String, CaseIterable, Identifiable {
    case loop, harness, agents, mcp
    var id: String { rawValue }
}

struct V2SessionHeader: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @Binding var dockPanel: V2DockPanel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            V2DovetailMark(size: 30)
                .foregroundColor(v2.ink)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(headerTitle)
                        .font(.system(size: 19, weight: .medium))
                        .kerning(-0.38)
                    if showLive { liveBadge }
                }
                Text(pathSubline)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 10) {
                modePill
                dockSwitcher
                runningPill
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
    }

    private var headerTitle: String {
        appState.activeTab?.title ?? appState.selectedProjectName.ifEmpty("no project")
    }

    private var pathSubline: String {
        let path = appState.activeTab?.projectCwd
            ?? appState.selectedProjectCwd?.path
            ?? "—"
        let model = appState.activeSession?.model ?? "claude"
        return "\(path) · \(model)"
    }

    private var showLive: Bool {
        guard let tab = appState.activeTab else { return false }
        switch tab.surface {
        case .modeA: return tab.isLive
        case .modeB:
            guard let s = tab.streamSession else { return false }
            switch s.state {
            case .idle, .terminated: return false
            default: return true
            }
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(v2.ink).frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, design: .monospaced))
                .kerning(0.8)
        }
        .foregroundColor(v2.mute)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var modePill: some View {
        let isModeA = appState.activeTab?.surface == .modeA
        let label = isModeA ? "terminal" : "chat"
        let help = isModeA
            ? "Switch to native chat (Mode B)"
            : "Switch to embedded terminal (Mode A)"

        return Button {
            appState.flipActiveMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isModeA ? "terminal" : "text.bubble")
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .kerning(0.22)
            }
            .foregroundColor(v2.ink)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(appState.activeTab == nil)
        .keyboardShortcut("y", modifiers: [.command, .shift])
    }

    private var dockSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(V2DockPanel.allCases) { panel in
                Button {
                    dockPanel = panel
                } label: {
                    Text(panel.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                        .foregroundColor(dockPanel == panel ? v2.paper : v2.mute)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(dockPanel == panel ? v2.ink : v2.card)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var runningPill: some View {
        HStack(spacing: 7) {
            stateDot
            Text(stateLabel)
                .font(.system(size: 11.5, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .medium))
                .padding(.leading, 2)
        }
        .foregroundColor(v2.ink)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    @ViewBuilder
    private var stateDot: some View {
        if let tab = appState.activeTab {
            switch tab.surface {
            case .modeA:
                if tab.isLive {
                    V2PulseDot(size: 7, color: v2.ink)
                } else {
                    Circle().fill(v2.del).frame(width: 7, height: 7)
                }
            case .modeB:
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
        } else {
            Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
        }
    }

    private var stateLabel: String {
        guard let tab = appState.activeTab else { return "No session" }
        switch tab.surface {
        case .modeA:
            return tab.isLive ? "Terminal" : "Ended"
        case .modeB:
            guard let s = tab.streamSession else { return "Idle" }
            switch s.state {
            case .idle: return "Idle"
            case .spawning: return "Spawning"
            case .initializing: return "Initializing"
            case .working: return s.isRetrying ? "Retrying" : "Running"
            case .awaitingPermission: return "Awaiting permission"
            case .closing: return "Closing"
            case .terminated: return "Ended"
            }
        }
    }
}

// MARK: - Pulse dot (used across v2 surfaces)

struct V2PulseDot: View {
    let size: CGFloat
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 0.25 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
