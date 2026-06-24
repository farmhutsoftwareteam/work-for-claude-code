// V2 root — owns a StreamSession instance and feeds it to the live transcript,
// composer, and permission card. Start CTA spawns `claude` in the user's home
// directory until project routing lands in Phase 4.
//
// Hot reload: every view in V2/ uses @ObserveInjection so InjectionIII can
// swap view bodies live without rebuilding.

import SwiftUI
import Inject

struct V2RootView: View {
    @ObserveInjection private var inject
    @StateObject private var session = StreamSession()
    @State private var theme: V2ThemeChoice = .light
    @State private var activeProject: V2Project = V2Mock.projects[0]
    @State private var activeSession: V2Session = V2Mock.sessions[0]
    @State private var dockPanel: V2DockPanel = .loop
    @State private var binaryURL: URL?
    @State private var binaryVersion: SemVer?

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

                    VStack(spacing: 0) {
                        V2LiveTranscript(session: session)
                        V2LivePermissionCard(session: session)
                            .padding(.horizontal, 36)
                            .padding(.bottom, session.pendingPermission == nil ? 0 : 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    sessionControlsOrComposer
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
        .task { resolveBinary() }
        .enableInjection()
    }

    // MARK: - Composer / start button

    @ViewBuilder
    private var sessionControlsOrComposer: some View {
        switch session.state {
        case .idle, .terminated:
            startCTA
        default:
            V2LiveComposer(session: session)
        }
    }

    private var startCTA: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: startSession) {
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("Start a session")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(palette.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(binaryURL == nil ? palette.line2 : palette.ink)
                }
                .buttonStyle(.plain)
                .disabled(binaryURL == nil)

                if let binaryURL {
                    Text(binaryURL.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let version = binaryVersion {
                    Text("v\(version.description)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(palette.faint)
                }

                Spacer()
            }

            if binaryURL == nil {
                Text("Couldn't find `claude` on your PATH. Install Claude Code or set ~/.claude/local/claude.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            } else if let version = binaryVersion, version < ClaudeBinary.minimumSupported {
                Text("Mode-B needs ≥ \(ClaudeBinary.minimumSupported.description). Update Claude Code.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            } else {
                Text("Mode-B spawns the binary with structured stream-json — Phase 4 will route per-project.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.faint)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    private func resolveBinary() {
        guard binaryURL == nil else { return }
        let url = ClaudeBinary.locate()
        binaryURL = url
        if let url { binaryVersion = ClaudeBinary.version(at: url) }
    }

    private func startSession() {
        guard let binaryURL else { return }
        let cwd = FileManager.default.homeDirectoryForCurrentUser
        session.start(cwd: cwd, claudeURL: binaryURL)
    }
}

enum V2ThemeChoice { case light, dark }

// MARK: - Dovetail mark (brand glyph used everywhere)

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
