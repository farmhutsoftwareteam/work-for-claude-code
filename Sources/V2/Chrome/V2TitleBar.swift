// Title bar (46px) — traffic-light spacer, theme toggle, brand on right.
// Everything else (counts, configuration entry points) lives in the
// workbench tile grid in the left rail — the title bar stays minimal.

import SwiftUI
import Inject

struct V2TitleBar: View {
    @ObserveInjection private var inject
    @Binding var themeRaw: String
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @AppStorage("v2.soundEnabled") private var soundEnabled = true

    private var theme: V2ThemeChoice {
        V2ThemeChoice(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 14) {
            // Everything lives in the top-right corner; the left is the
            // system's traffic-light chrome.
            Spacer()

            summary
            soundToggle

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

    // MARK: - Summary readout + sound toggle

    /// Per the Tab-states design: a live tally of what's working / finished
    /// unseen / blocked on you, across every open tab. Only non-zero counts show.
    @ViewBuilder
    private var summary: some View {
        let c = appState.tabStatusCounts
        if c.working + c.done + c.needs > 0 {
            HStack(spacing: 14) {
                if c.working > 0 { summaryItem(c.working, "working", color: v2.ink, pulse: true) }
                if c.done > 0    { summaryItem(c.done, "done", color: v2.add, pulse: false) }
                if c.needs > 0   { summaryItem(c.needs, "needs you", color: v2.del, pulse: false) }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(v2.mute)
        }
    }

    private func summaryItem(_ count: Int, _ label: String, color: Color, pulse: Bool) -> some View {
        HStack(spacing: 6) {
            if pulse {
                V2PulseDot(size: 7, color: color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text("\(count) \(label)")
        }
    }

    private var soundToggle: some View {
        Button { soundEnabled.toggle() } label: {
            Image(systemName: soundEnabled ? "speaker.wave.2" : "speaker.slash")
                .font(.system(size: 12))
                .foregroundColor(v2.mute)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(soundEnabled ? "Attention sounds on — click to mute" : "Attention sounds muted — click to enable")
    }
}
