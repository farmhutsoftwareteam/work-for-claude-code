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
    @ObservedObject private var filePeek = V2FilePeekController.shared
    @AppStorage("v2.theme") private var themeRaw: String = V2ThemeChoice.system.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    // dockPanel lives on appState so /mcp, /agents can open the panel.
    /// Phase-4 dogfood: ⌘⌃A opens the self-contained ACP-backed chat surface
    /// as an overlay. Off by default; the shipping StreamSession chat is
    /// untouched whether this is open or not.
    @State private var showACPPreview = false

    private var theme: V2ThemeChoice {
        V2ThemeChoice(rawValue: themeRaw) ?? .system
    }

    private var palette: V2Palette {
        theme.palette(systemColorScheme: systemColorScheme)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                V2TitleBar(themeRaw: $themeRaw)

                HStack(spacing: 0) {
                    V2LeftRail()
                        .frame(width: 264)

                    Group {
                        switch appState.mainView {
                        case .chat:
                            VStack(spacing: 0) {
                                V2SessionTabs()
                                // The per-session header only makes sense with
                                // a live session. On the project-home screen
                                // (no active tab) V2ProjectHome draws its own
                                // header, so suppress this one.
                                if appState.activeTab != nil {
                                    V2SessionHeader(dockPanel: $appState.dockPanel)
                                }

                                mainBody

                                composerOrControls
                            }
                        case .usage:
                            V2UsageView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.paper)

                    V2RightDock(panel: $appState.dockPanel)
                        // Width comes from the dock itself (40pt collapsed,
                        // 360pt expanded). Animate the swap so the transcript
                        // smoothly reflows when the dock opens/closes.
                        .animation(
                            .spring(response: 0.28, dampingFraction: 0.86),
                            value: appState.dockCollapsed
                        )
                }
                .frame(maxHeight: .infinity)
            }

            // Window-level permission modal — dims the whole window and
            // floats the request front-and-centre so it can't be missed.
            if let session = appState.activeSession, session.pendingPermission != nil {
                V2PermissionModal(session: session)
                    .transition(.opacity)
                    .zIndex(100)
            }

            // Phase-4 ACP dogfood surface (⌘⌃A). Full-bleed overlay over the
            // whole window so it's a clean isolated test of the ACP path.
            if showACPPreview {
                V2ACPChatView(
                    cwd: appState.selectedProjectCwd ?? URL(fileURLWithPath: NSHomeDirectory()),
                    projectName: appState.selectedProjectName,
                    onClose: { showACPPreview = false }
                )
                .environment(\.v2, palette)
                .transition(.opacity)
                .zIndex(200)
            }

            // Hidden ⌘⌃A toggle.
            Button("Toggle ACP preview") { showACPPreview.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .opacity(0).frame(width: 0, height: 0)

            // Add Project modal — window-level centered overlay.
            if appState.showAddProject {
                V2AddProjectModal(onClose: { appState.showAddProject = false })
                    .environment(\.v2, palette)
                    .environmentObject(store)
                    .environmentObject(appState)
                    .transition(.opacity)
                    .zIndex(300)
            }

            // File peek modal — previews a local file clicked in the transcript
            // (File peek.dc.html). The session keeps streaming behind it.
            if let peeked = filePeek.file {
                V2FilePeekModal(file: peeked, onClose: { filePeek.close() })
                    .environment(\.v2, palette)
                    .transition(.opacity)
                    .zIndex(250)
            }
        }
        .animation(.easeOut(duration: 0.15), value: appState.activeSession?.pendingPermission?.id)
        .background(palette.paper)
        .environment(\.v2, palette)
        .environmentObject(appState)
        .preferredColorScheme(theme.preferredColorScheme)
        // ⌘W: close the active v2 tab when v2 window is key. The system
        // resolves the shortcut against the focused responder chain, so
        // this only fires here when v2 is foreground. Falls through to the
        // standard window close when no tab is active.
        .background(
            ZStack {
                Button("Close v2 Tab") { closeActiveTabOrWindow() }
                    .keyboardShortcut("w", modifiers: .command)
                // ⌘K opens the cross-project session search overlay.
                Button("Open search") { appState.searchOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .task {
            appState.attach(terminals: terminals)
            appState.resolveBinary()
            appState.refreshDiscoveredModels()
            appState.refreshModelCatalog()
            // Aged composer pastes (>24h) get cleaned up here rather than
            // on every send — clearing post-send was deleting PNGs out from
            // under an in-flight Read tool call.
            V2AttachmentStore.purgeOldAttachments()
            // v1's ContentView normally triggers Store.load on appear, but in
            // DEBUG we miniaturize v1 immediately so its .task may not fire
            // before we read store.projects. Kick off our own load — it's
            // idempotent and dedups via Store's isLoading flag.
            if store.projects.isEmpty {
                await store.load()
            }
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
                    // Permission request is now a window-level modal overlay
                    // (see body's ZStack) rather than an inline card that was
                    // easy to scroll past / miss entirely.
                    VStack(spacing: 0) {
                        V2LiveTranscript(session: session, projectCwd: tab.projectCwd)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Co-driven terminal panes (#56) — shared PTYs Claude
                        // and the user drive together; empty ⇒ renders nothing.
                        CoTerminalStrip(session: session)
                    }
                    // Key by tab so each tab keeps its own scroll
                    // position — without this, switching tabs reuses the
                    // same transcript view identity and the scroll state
                    // bleeds between conversations.
                    .id(tab.id)
                } else {
                    invalidStateView
                }
            }
        } else if appState.selectedProjectCwd != nil {
            V2ProjectHome()
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
                    if session.isResuming {
                        // History is loading off disk — the transcript shows a
                        // "Loading conversation…" overlay; don't flash the
                        // Start CTA underneath it.
                        EmptyView()
                    } else {
                    switch session.state {
                    case .idle, .terminated:
                        // .idle = never started; .terminated = previous
                        // session ended. Both want the Start CTA.
                        startCTA(tab: tab, session: session)
                    default:
                        // .spawning / .initializing / .working / .ready /
                        // .awaitingPermission / .closing all show composer.
                        // Key by tab so the draft text + pending attachments
                        // are per-tab. Without this, the composer keeps one
                        // @State across tab switches and your half-typed
                        // message (and attachments) bleed into other tabs.
                        V2LiveComposer(session: session)
                            .id(tab.id)
                    }
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
            // (A selected project now routes to V2ProjectHome, which carries
            // its own "+ New session" / ⌘N — so this empty state only shows
            // with NO project selected. The old "New tab" button here was
            // unreachable and has been removed.)
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
                        Text(session.endError != nil
                             ? "Start a fresh session in \(tab.title)"
                             : "Start session in \(tab.title)")
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

            if let err = session.endError {
                Text(err)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
                    .lineLimit(2)
            } else if case .terminated(let reason) = session.state {
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
