// Title bar (46px) — traffic-light spacer, app-level buttons, brand badge,
// theme toggle, workspace label, forward chevron. Owns nothing stateful
// except the theme binding it forwards from the root.

import SwiftUI
import Inject

struct V2TitleBar: View {
    @ObserveInjection private var inject
    @Binding var themeRaw: String
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState
    @State private var showingHooksEditor = false
    @State private var showingMCPSheet = false

    private var theme: V2ThemeChoice {
        V2ThemeChoice(rawValue: themeRaw) ?? .system
    }

    private var totalSkills: Int {
        store.standaloneSkills.count
            + store.pluginSkills.values.reduce(0) { $0 + $1.count }
    }

    private var totalMCPs: Int {
        store.standaloneMCPs.count
            + store.pluginMCPs.values.reduce(0) { $0 + $1.count }
    }

    /// Per-segment status chips. Hover for an explanation, click to land
    /// on the surface that manages that thing. Replaces the old workbench
    /// tile grid.
    private var statusSegments: [StatusSegment] {
        var out: [StatusSegment] = []
        if totalMCPs > 0 {
            out.append(.init(
                text: "\(totalMCPs) mcp\(totalMCPs == 1 ? "" : "s")",
                help: """
                MCP servers — Model Context Protocol providers claude loads
                at session start. Click to open the MCP panel.
                """,
                action: { openMCPPanel() }
            ))
        }
        if store.plugins.count > 0 {
            out.append(.init(
                text: "\(store.plugins.count) plugin\(store.plugins.count == 1 ? "" : "s")",
                help: """
                Plugins — installed bundles that ship skills, MCPs, and
                hooks together. No v2 manager yet — open the Extensions
                tab in the v1 window to add or remove.
                """,
                action: nil
            ))
        }
        if totalSkills > 0 {
            out.append(.init(
                text: "\(totalSkills) skill\(totalSkills == 1 ? "" : "s")",
                help: """
                Skills — reusable instruction packs claude can load
                mid-session. No v2 manager yet — open the Extensions
                tab in the v1 window to add or remove.
                """,
                action: nil
            ))
        }
        if store.hooks.count > 0 {
            out.append(.init(
                text: "\(store.hooks.count) hook\(store.hooks.count == 1 ? "" : "s")",
                help: """
                Hooks — shell commands that fire on tool events
                (PreToolUse, PostToolUse, etc.). Click to open the
                hooks editor.
                """,
                action: { showingHooksEditor = true }
            ))
        }
        return out
    }

    private struct StatusSegment {
        let text: String
        let help: String
        let action: (() -> Void)?
    }

    /// Expand the right dock and switch to the MCP panel. The dock binding
    /// lives at V2RootView level so we can't toggle the panel directly
    /// from here — open the v1 MCP sheet instead as a quick route.
    private func openMCPPanel() {
        appState.dockCollapsed = false
        showingMCPSheet = true
    }

    var body: some View {
        HStack(spacing: 16) {
            // macOS traffic lights live in the system chrome; leave room.
            Spacer().frame(width: 70)

            // Status cluster on the left (theme + counts). Brand moves to
            // the right edge so the wordmark anchors the window like a
            // bookend instead of competing with the traffic lights.
            Button {
                themeRaw = theme.next.rawValue
            } label: {
                Image(systemName: theme.icon)
                    .font(.system(size: 13))
                    .foregroundColor(v2.mute)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Theme: \(theme.label) (click to cycle)")

            // Usage view trigger — replaces the old workbench Usage tile.
            Button { appState.mainView = .usage } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(appState.mainView == .usage ? v2.ink : v2.mute)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Usage — tokens, spend, sessions across time")

            let segments = statusSegments
            if !segments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                        if let action = segment.action {
                            Button(action: action) {
                                Text(segment.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(v2.mute)
                                    .underline(false)
                            }
                            .buttonStyle(.plain)
                            .help(segment.help)
                        } else {
                            Text(segment.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.faint)
                                .help(segment.help)
                        }
                        if idx < segments.count - 1 {
                            Text("·")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.line2)
                        }
                    }
                }
            }

            Spacer()

            // Brand badge anchored to the right.
            HStack(spacing: 9) {
                V2DovetailMark(size: 18)
                Text("atelier")
                    .font(.system(size: 16, weight: .medium))
                    .kerning(-0.16)
            }
            .foregroundColor(v2.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(v2.paper2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .sheet(isPresented: $showingHooksEditor) {
            V2HooksEditorSheet(onClose: { showingHooksEditor = false })
                .environmentObject(store)
        }
        .sheet(isPresented: $showingMCPSheet) {
            MCPEditor(mode: .add(defaultScope: .user)) {
                showingMCPSheet = false
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .enableInjection()
    }
}

