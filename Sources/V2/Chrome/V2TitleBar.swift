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

    /// Per-segment status chips with their own tooltips so a new user can
    /// hover any one of them to learn what it is. Replaces the old static
    /// "workshop" placeholder + the workbench tile grid.
    private var statusSegments: [StatusSegment] {
        var out: [StatusSegment] = []
        if totalMCPs > 0 {
            out.append(.init(
                text: "\(totalMCPs) mcp\(totalMCPs == 1 ? "" : "s")",
                help: """
                MCP servers — Model Context Protocol providers claude loads
                at session start. Each server exposes a set of tools
                (filesystem, github, linear, sentry, …) the session can call.
                """
            ))
        }
        if store.plugins.count > 0 {
            out.append(.init(
                text: "\(store.plugins.count) plugin\(store.plugins.count == 1 ? "" : "s")",
                help: """
                Plugins — installed bundles that ship one or more skills,
                MCP servers, and hooks together. Distributed via the plugin
                marketplace; configured per project or globally.
                """
            ))
        }
        if totalSkills > 0 {
            out.append(.init(
                text: "\(totalSkills) skill\(totalSkills == 1 ? "" : "s")",
                help: """
                Skills — reusable instruction packs ("how to do X") claude
                can load mid-session when the task matches. Lighter-weight
                than MCPs; no subprocess, just text + maybe a tool.
                """
            ))
        }
        if store.hooks.count > 0 {
            out.append(.init(
                text: "\(store.hooks.count) hook\(store.hooks.count == 1 ? "" : "s")",
                help: """
                Hooks — shell commands that fire on tool events (PreToolUse,
                PostToolUse, etc.). Use to lint before commits, log every
                Edit, block dangerous Bash, etc.
                """
            ))
        }
        return out
    }

    private struct StatusSegment {
        let text: String
        let help: String
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

            let segments = statusSegments
            if !segments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                        Text(segment.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.faint)
                            .help(segment.help)
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
        .enableInjection()
    }
}

