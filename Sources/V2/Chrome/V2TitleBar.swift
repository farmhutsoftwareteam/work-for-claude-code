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

    private var statusLine: String {
        // Compact one-liner replacing the old "workshop" placeholder text +
        // the workbench tile grid in the left rail. Reads real counts from
        // Store; clicking it is reserved for the future Workshop window.
        var parts: [String] = []
        if totalMCPs > 0 { parts.append("\(totalMCPs) mcp\(totalMCPs == 1 ? "" : "s")") }
        if store.plugins.count > 0 {
            parts.append("\(store.plugins.count) plugin\(store.plugins.count == 1 ? "" : "s")")
        }
        if totalSkills > 0 { parts.append("\(totalSkills) skill\(totalSkills == 1 ? "" : "s")") }
        if store.hooks.count > 0 {
            parts.append("\(store.hooks.count) hook\(store.hooks.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 16) {
            // macOS traffic lights live in the system chrome; leave room.
            Spacer().frame(width: 70)

            // App-level icon buttons.
            HStack(spacing: 4) {
                V2IconButton(systemImage: "plus", help: "New session") { }
                V2IconButton(systemImage: "house", help: "Home") { }
                V2IconButton(systemImage: "sidebar.left", help: "Toggle sidebar") { }
            }

            // Brand badge.
            HStack(spacing: 9) {
                V2DovetailMark(size: 18)
                Text("atelier")
                    .font(.system(size: 16, weight: .medium))
                    .kerning(-0.16)
            }
            .foregroundColor(v2.ink)
            .padding(.leading, 4)

            Spacer()

            // Right cluster.
            HStack(spacing: 12) {
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

                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .help("Configured MCPs, plugins, skills, hooks. Workshop window coming.")
                }
            }
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

private struct V2IconButton: View {
    @Environment(\.v2) private var v2
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(v2.mute)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
