// V2 preview window root. Three-column layout — left rail / main column / right dock.
// Commit 1: placeholders. Each region gets its real content as we land sub-issues.
//
// Hot reload: every view in V2/ uses @ObserveInjection so InjectionIII can swap
// the SwiftUI body live without rebuilding. Install InjectionIII from
// https://github.com/krzysztofzablocki/Inject for the live-edit loop.

import SwiftUI
import Inject

struct V2RootView: View {
    @ObserveInjection private var inject
    @State private var theme: V2ThemeChoice = .light

    private var palette: V2Palette {
        theme == .dark ? V2Theme.dark : V2Theme.light
    }

    var body: some View {
        VStack(spacing: 0) {
            V2TitleBar(theme: $theme)
            V2BodyLayout()
        }
        .background(palette.paper)
        .environment(\.v2, palette)
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .enableInjection()
    }
}

enum V2ThemeChoice { case light, dark }

// MARK: - Title bar (46px)

private struct V2TitleBar: View {
    @ObserveInjection private var inject
    @Binding var theme: V2ThemeChoice
    @Environment(\.v2) private var v2

    var body: some View {
        HStack(spacing: 16) {
            // macOS traffic lights live in the system chrome; we leave space for them.
            Spacer().frame(width: 70)

            // Brand badge.
            HStack(spacing: 9) {
                V2DovetailMark(size: 18)
                Text("atelier")
                    .font(.system(size: 16, weight: .medium))
                    .kerning(-0.16)
                Text("preview")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.leading, 6)
            }
            .foregroundColor(v2.ink)

            Spacer()

            // Right cluster — theme toggle + workspace label.
            HStack(spacing: 12) {
                Button {
                    theme = theme == .dark ? .light : .dark
                } label: {
                    Image(systemName: theme == .dark ? "sun.max" : "moon")
                        .font(.system(size: 13))
                        .foregroundColor(v2.mute)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Toggle theme")

                Text("workshop")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
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

// MARK: - Body layout (three columns)

private struct V2BodyLayout: View {
    @ObserveInjection private var inject

    var body: some View {
        HStack(spacing: 0) {
            V2LeftRailPlaceholder()
                .frame(width: 264)
            V2MainColumnPlaceholder()
                .frame(maxWidth: .infinity)
            V2RightDockPlaceholder()
                .frame(width: 360)
        }
        .frame(maxHeight: .infinity)
        .enableInjection()
    }
}

// MARK: - Region placeholders

private struct V2LeftRailPlaceholder: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    var body: some View {
        V2RegionPlaceholder(title: "LEFT RAIL", subtitle: "search · projects · workbench tiles", side: .trailing)
            .background(v2.paper2)
            .enableInjection()
    }
}

private struct V2MainColumnPlaceholder: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    var body: some View {
        V2RegionPlaceholder(title: "MAIN COLUMN", subtitle: "tabs · session header · transcript · composer", side: .none)
            .background(v2.paper)
            .enableInjection()
    }
}

private struct V2RightDockPlaceholder: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    var body: some View {
        V2RegionPlaceholder(title: "RIGHT DOCK", subtitle: "loop · agents · mcp panels", side: .leading)
            .background(v2.paper2)
            .enableInjection()
    }
}

private struct V2RegionPlaceholder: View {
    @Environment(\.v2) private var v2
    let title: String
    let subtitle: String
    let side: PlaceholderBorderSide

    enum PlaceholderBorderSide { case leading, trailing, none }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)
            Text(subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.mute)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: side == .leading ? .leading : (side == .trailing ? .trailing : .top)) {
            if side != .none {
                Rectangle().fill(v2.line).frame(width: 1)
            }
        }
    }
}

// MARK: - Dovetail mark (the brand glyph)

struct V2DovetailMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width
            let stroke = StrokeStyle(lineWidth: s * 0.094, lineCap: .square, lineJoin: .miter)

            // Outer square — rect(7,7,50,50) in a 64×64 viewBox = inset 0.109 from edge,
            // side length 0.781.
            let inset = s * 0.109
            let side = s * 0.781
            let rect = Path(CGRect(x: inset, y: inset, width: side, height: side))
            context.stroke(rect, with: .color(.primary), style: stroke)

            // Inner dovetail path: M32 7 L32 24 L46 28 L46 36 L32 40 L32 57
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x / 64) * s, y: (y / 64) * s)
            }
            var path = Path()
            path.move(to: pt(32, 7))
            path.addLine(to: pt(32, 24))
            path.addLine(to: pt(46, 28))
            path.addLine(to: pt(46, 36))
            path.addLine(to: pt(32, 40))
            path.addLine(to: pt(32, 57))
            context.stroke(path, with: .color(.primary), style: stroke)
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview("V2 root — light") {
    V2RootView()
        .frame(width: 1440, height: 900)
}

#Preview("Dovetail mark") {
    V2DovetailMark(size: 64).padding(40)
}
#endif
