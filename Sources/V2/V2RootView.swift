// V2 root — wires V2AppState (multi-tab StreamSession controller) into the
// three-column layout. Real projects from Store, real session tabs, active
// tab's StreamSession drives the transcript / composer / permission card.

import SwiftUI
import Inject

struct V2RootView: View {
    @ObserveInjection private var inject
    @EnvironmentObject private var store: Store
    @StateObject private var appState = V2AppState()
    @State private var theme: V2ThemeChoice = .light
    @State private var dockPanel: V2DockPanel = .loop

    private var palette: V2Palette {
        theme == .dark ? V2Theme.dark : V2Theme.light
    }

    var body: some View {
        VStack(spacing: 0) {
            V2TitleBar(theme: $theme)

            HStack(spacing: 0) {
                V2LeftRail()
                    .frame(width: 264)

                VStack(spacing: 0) {
                    V2SessionTabs()
                    V2SessionHeader(dockPanel: $dockPanel)

                    mainBody

                    composerOrControls
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
        .environmentObject(appState)
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .task {
            appState.resolveBinary()
            // Seed initial project selection from Store on first appear.
            if appState.selectedProjectCwd == nil, let first = store.projects.first {
                appState.selectProject(cwd: first.cwd, name: first.displayName)
            }
        }
        .enableInjection()
    }

    // MARK: - Body content

    @ViewBuilder
    private var mainBody: some View {
        if let tab = appState.activeTab {
            VStack(spacing: 0) {
                V2LiveTranscript(session: tab.session)
                V2LivePermissionCard(session: tab.session)
                    .padding(.horizontal, 36)
                    .padding(.bottom, tab.session.pendingPermission == nil ? 0 : 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var composerOrControls: some View {
        if let tab = appState.activeTab {
            switch tab.session.state {
            case .idle, .terminated:
                startCTA(tab: tab)
            default:
                V2LiveComposer(session: tab.session)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            V2DovetailMark(size: 40).foregroundColor(palette.line2)
            VStack(spacing: 6) {
                Text("Pick a project on the left, then ⌘N for a new tab.")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(palette.mute)
                if let v = appState.claudeVersion {
                    Text("claude v\(v) ready")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(palette.faint)
                } else if appState.claudeBinary == nil {
                    Text("`claude` not found on PATH — install Claude Code")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(palette.del)
                }
            }

            if appState.selectedProjectCwd != nil {
                Button { appState.newTab() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                        Text("New tab in \(appState.selectedProjectName)")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(palette.ink)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.paper)
    }

    // MARK: - Start CTA per tab

    private func startCTA(tab: V2Tab) -> some View {
        let canStart = appState.claudeBinary != nil
            && (appState.claudeVersion ?? .init(major: 0, minor: 0, patch: 0)) >= ClaudeBinary.minimumSupported

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { appState.startActiveSession() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        Text("Start session in \(tab.displayName)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(palette.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(canStart ? palette.ink : palette.line2)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)

                Text(tab.cwd.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }

            if case .terminated(let reason) = tab.session.state {
                Text("Last session ended: \(reason)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.faint)
            } else if appState.claudeBinary == nil {
                Text("Couldn't find `claude`. Install Claude Code or set ~/.claude/local/claude.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            } else if !canStart {
                Text("Mode-B needs ≥ \(ClaudeBinary.minimumSupported.description). Update Claude Code.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
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
