// Title bar (46px) — traffic-light spacer, theme toggle, brand on right.
// Everything else (counts, configuration entry points) lives in the
// workbench tile grid in the left rail — the title bar stays minimal.

import SwiftUI
import Inject

struct V2TitleBar: View {
    @ObserveInjection private var inject
    @Binding var themeRaw: String
    @Environment(\.v2) private var v2

    private var theme: V2ThemeChoice {
        V2ThemeChoice(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 14) {
            // Everything lives in the top-right corner; the left is the
            // system's traffic-light chrome.
            Spacer()

            // Theme picker: a menu showing Light / Dark / System with the
            // current mode checked — one click to any mode, instead of a
            // single button that cycled through all three ambiguously.
            Menu {
                Picker("Theme", selection: $themeRaw) {
                    Label("Light", systemImage: "sun.max").tag(V2ThemeChoice.light.rawValue)
                    Label("Dark", systemImage: "moon").tag(V2ThemeChoice.dark.rawValue)
                    Label("System", systemImage: "circle.lefthalf.filled").tag(V2ThemeChoice.system.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: theme.icon)
                    .font(.system(size: 13))
                    .foregroundColor(v2.mute)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Theme: \(theme.label.capitalized)")

            // Brand badge — sits just right of the theme control in the corner.
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
