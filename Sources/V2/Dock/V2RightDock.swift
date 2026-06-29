// Right dock host. Two modes:
//   • collapsed (default) — 40pt vertical strip with one icon per panel
//     plus an expand chevron. Clicking an icon both opens the dock and
//     switches to that panel.
//   • expanded — full 360pt panel host, with a collapse chevron at the top.
//
// State lives in V2AppState.dockCollapsed (@AppStorage, survives launches).
// Loop / harness running-indicator badges show on the collapsed strip so
// the user knows something needs attention without having to expand.

import SwiftUI
import Inject

struct V2RightDock: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @Binding var panel: V2DockPanel

    var body: some View {
        Group {
            if appState.dockCollapsed {
                collapsedStrip
            } else {
                expanded
            }
        }
        .background(v2.paper2)
        .overlay(alignment: .leading) {
            Rectangle().fill(v2.line).frame(width: 1)
        }
        .enableInjection()
    }

    // MARK: - Collapsed

    private var collapsedStrip: some View {
        VStack(spacing: 2) {
            Button { appState.dockCollapsed = false } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand dock")

            Rectangle().fill(v2.line).frame(height: 1).padding(.horizontal, 8)

            ForEach(V2DockPanel.allCases) { p in
                Button {
                    panel = p
                    appState.dockCollapsed = false
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: icon(for: p))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(panel == p ? v2.ink : v2.mute)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                        if hasActivity(for: p) {
                            Circle()
                                .fill(v2.ink)
                                .frame(width: 6, height: 6)
                                .padding(.top, 8)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(label(for: p))
            }
            Spacer()
        }
        .frame(width: 40)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { appState.dockCollapsed = true } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse dock")
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(v2.line).frame(height: 1)
            }

            Group {
                switch panel {
                case .loop:    V2LoopPanel()
                case .harness: V2HarnessPanel()
                case .agents:  V2AgentsPanel()
                case .mcp:     V2McpPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func icon(for p: V2DockPanel) -> String {
        switch p {
        case .loop:    return "arrow.triangle.2.circlepath"
        case .harness: return "checkerboard.rectangle"
        case .agents:  return "person.3"
        case .mcp:     return "powerplug"
        }
    }

    /// Help text shown on hover — one-line description so the icons aren't
    /// cryptic to a new user. macOS surfaces these as system tooltips
    /// after the standard hover delay.
    private func label(for p: V2DockPanel) -> String {
        switch p {
        case .loop:
            return """
            Loop runner — auto-iterate on a goal until a verifier passes.
            You set a target ("all tests pass"), a verifier prompt, and a
            turn budget; the doer takes a turn, the verifier grades it,
            failures critique back into the doer until it passes or the
            budget runs out.
            """
        case .harness:
            return """
            Harness — multi-phase plan → work → review pipeline. Each
            phase spawns a fresh `claude -p` process with a persisted
            progress.md, so long-running work survives restarts.
            """
        case .agents:
            return """
            Agents — specialized claude sub-instances the main session
            can delegate to (reviewer, explorer, test-runner, …). Each
            runs in its own context; only the summary returns to your
            window, so exploration noise stays out.
            """
        case .mcp:
            return """
            MCP servers — Model Context Protocol tool providers claude
            loads at session start (filesystem, github, linear, etc.).
            This panel shows what's connected for the active session
            and lets you add new ones to your global config.
            """
        }
    }

    /// Pulsing badge cue when something is actually running. Loop + harness
    /// are session-attached; agents + MCP are static config.
    private func hasActivity(for p: V2DockPanel) -> Bool {
        guard let tab = appState.activeTab else { return false }
        switch p {
        case .loop:
            switch tab.loop?.state {
            case .running, .verifying: return true
            default:                   return false
            }
        case .harness:
            switch tab.harness?.phase {
            case .planning, .working, .reviewing: return true
            default:                                return false
            }
        default:
            return false
        }
    }
}
