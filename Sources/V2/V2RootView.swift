// V2 root — the entire app window composed from real components.
// Mock data via V2MockData drives every region until Phase 4 wires the
// real StreamSession engine.
//
// Hot reload: every view uses @ObserveInjection + .enableInjection() so
// InjectionIII can swap view bodies live without rebuilding.

import SwiftUI
import Inject

struct V2RootView: View {
    @ObserveInjection private var inject
    @State private var theme: V2ThemeChoice = .light
    @State private var activeProject: V2Project = V2Mock.projects[0]
    @State private var activeSession: V2Session = V2Mock.sessions[0]
    @State private var dockPanel: V2DockPanel = .loop

    private var palette: V2Palette {
        theme == .dark ? V2Theme.dark : V2Theme.light
    }

    var body: some View {
        VStack(spacing: 0) {
            V2TitleBar(theme: $theme)
            HStack(spacing: 0) {
                V2LeftRail(activeProject: $activeProject)
                    .frame(width: 264)

                VStack(spacing: 0) {
                    V2SessionTabs(activeSession: $activeSession)
                    V2SessionHeader(dockPanel: $dockPanel, activeProject: activeProject)
                    V2TranscriptView()
                    V2Composer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.paper)

                V2RightDock(panel: $dockPanel)
                    .frame(width: 360)
            }
            .frame(maxHeight: .infinity)
        }
        .background(palette.paper)
        .environment(\.v2, palette)
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .enableInjection()
    }
}

enum V2ThemeChoice { case light, dark }

// MARK: - Dovetail mark (the brand glyph)

struct V2DovetailMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width
            let stroke = StrokeStyle(lineWidth: s * 0.094, lineCap: .square, lineJoin: .miter)

            let inset = s * 0.109
            let side = s * 0.781
            let rect = Path(CGRect(x: inset, y: inset, width: side, height: side))
            context.stroke(rect, with: .color(.primary), style: stroke)

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
#endif
