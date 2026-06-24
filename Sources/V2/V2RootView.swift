// V2 root — owns V2AppState (per-window state) and reads the tab list from
// TerminalsController (the single source of truth after #22). Active tab's
// surface decides whether the main column renders the embedded terminal
// (Mode A) or the live chat (Mode B).

import SwiftUI
import Inject

struct V2RootView: View {
    @ObserveInjection private var inject
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terminals: TerminalsController
    @StateObject private var appState = V2AppState()
    @AppStorage("v2.theme") private var themeRaw: String = V2ThemeChoice.system.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var dockPanel: V2DockPanel = .loop

    private var theme: V2ThemeChoice {
        V2ThemeChoice(rawValue: themeRaw) ?? .system
    }

    private var palette: V2Palette {
        theme.palette(systemColorScheme: systemColorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            V2TitleBar(themeRaw: $themeRaw)

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
        .preferredColorScheme(theme.preferredColorScheme)
        // ⌘W: close the active v2 tab when v2 window is key. The system
        // resolves the shortcut against the focused responder chain, so
        // this only fires here when v2 is foreground. Falls through to the
        // standard window close when no tab is active.
        .background(
            Button("Close v2 Tab") { closeActiveTabOrWindow() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .task {
            appState.attach(terminals: terminals)
            appState.resolveBinary()
            if appState.selectedProjectCwd == nil, let first = store.projects.first {
                appState.selectProject(cwd: first.cwd, name: first.displayName)
            }
        }
        .enableInjection()
    }

    // MARK: - Main body

    @ViewBuilder
    private var mainBody: some View {
        if let tab = appState.activeTab {
            switch tab.surface {
            case .modeA:
                EmbeddedTerminalView(tabId: tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            case .modeB:
                if let session = tab.streamSession {
                    VStack(spacing: 0) {
                        V2LiveTranscript(session: session)
                        V2LivePermissionCard(session: session)
                            .padding(.horizontal, 36)
                            .padding(.bottom, session.pendingPermission == nil ? 0 : 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    invalidStateView
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var composerOrControls: some View {
        if let tab = appState.activeTab {
            switch tab.surface {
            case .modeA:
                modeAFooter(tab: tab)
            case .modeB:
                if let session = tab.streamSession {
                    switch session.state {
                    case .idle, .terminated:
                        // .idle = never started; .terminated = previous
                        // session ended. Both want the Start CTA.
                        startCTA(tab: tab, session: session)
                    default:
                        // .spawning / .initializing / .working / .ready /
                        // .awaitingPermission / .closing all show composer.
                        V2LiveComposer(session: session)
                    }
                }
            }
        }
    }

    private var invalidStateView: some View {
        Text("Mode-B tab missing StreamSession — close and reopen.")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(palette.del)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modeAFooter(tab: TerminalTab) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundColor(palette.mute)
            Text("Terminal session in \(tab.projectCwd)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(palette.faint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button { appState.flipMode(tabId: tab.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11))
                    Text("Switch to chat")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(palette.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(palette.paper2)
                .overlay(Rectangle().stroke(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    // MARK: - Empty / start states

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

    private func closeActiveTabOrWindow() {
        if let id = appState.activeTabId {
            appState.close(tabId: id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    private func startCTA(tab: TerminalTab, session: StreamSession) -> some View {
        let canStart = appState.claudeBinary != nil
            && (appState.claudeVersion ?? .init(major: 0, minor: 0, patch: 0)) >= ClaudeBinary.minimumSupported

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { appState.startActiveSession() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        Text("Start session in \(tab.title)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(palette.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(canStart ? palette.ink : palette.line2)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)

                Text(tab.projectCwd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }

            if case .terminated(let reason) = session.state {
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

// MARK: - Dovetail mark

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
