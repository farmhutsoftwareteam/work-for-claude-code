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
    @State private var showSessionPortAlert = false
    @State private var sessionPortTitle = "Session"
    @State private var sessionPortMessage = ""
    /// True from panel-open until the copy finishes — one port operation
    /// at a time, and a second menu press during a panel is a no-op
    /// rather than a second stacked modal.
    @State private var sessionPortBusy = false
    @State private var showClaudeInstall = false
    @State private var showCodexInstall = false
    @State private var showClaudeSignIn = false

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
            if let session = appState.activeCodexSession, session.pendingPermission != nil {
                V2CodexPermissionModal(session: session)
                    .transition(.opacity)
                    .zIndex(100)
            }
            if let session = appState.activeCodexSession, session.pendingUserInput != nil {
                V2CodexUserInputModal(session: session)
                    .transition(.opacity)
                    .zIndex(101)
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
        .animation(.easeOut(duration: 0.15), value: appState.activeCodexSession?.pendingPermission?.id)
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
        // ⌘1–9 / ⌘]/⌘[ — WorkApp's Window-menu commands can't reach
        // V2AppState directly (it's owned here, not by WorkApp), so they
        // stage a request on `terminals` instead; dispatch it into
        // V2AppState the moment it lands, then clear it (one-shot).
        .onChange(of: terminals.tabJumpRequest) { _, request in
            switch request {
            case .position(let n): appState.activateTab(atPosition: n)
            case .cycle(let delta): appState.cycleActiveTab(delta: delta)
            case nil: break
            }
            if request != nil { terminals.tabJumpRequest = nil }
        }
        .onChange(of: terminals.sessionPortRequest) { _, request in
            guard let request else { return }
            // Cleared BEFORE handling, not after: the handlers spin modal
            // panels, and a request left set during that nested run loop
            // could re-enter this handler on the next change. (The command
            // itself carries a nonce, so re-issuing after a wedge is
            // always an observable change.)
            terminals.sessionPortRequest = nil
            guard !sessionPortBusy else { return }
            // Hop out of the SwiftUI update transaction: runModal() spins
            // a nested run loop, and doing that inside onChange re-enters
            // body evaluation mid-transaction (AttributeGraph cycles).
            switch request {
            case .exportActive: DispatchQueue.main.async { exportActiveSession() }
            case .importBundle: DispatchQueue.main.async { importSessionBundle() }
            }
        }
        .alert(sessionPortTitle, isPresented: $showSessionPortAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sessionPortMessage)
        }
        .task {
            appState.attach(terminals: terminals)
            // Awaited (M8, bug-hunt 2026-07-10): resolveBinary() now hops off
            // the MainActor internally so a slow shell rc (nvm/asdf/corporate
            // init scripts) can't hang app launch — but restoreWorkspaceIfNeeded
            // below still needs claudeBinary set before it runs, so this
            // `.task` awaits the result rather than firing it off unordered.
            await appState.resolveBinary()
            // Reopen the previous workspace — tabs come back HIBERNATED
            // (transcript preloaded, zero subprocesses; first message wakes
            // each via --resume). Must run after attach + resolveBinary:
            // restore needs the terminals controller and the wake recipe's
            // binary path.
            appState.restoreWorkspaceIfNeeded()
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
                if tab.provider == .codex, let session = tab.codexSession {
                    V2CodexChatView(session: session, projectCwd: tab.projectCwd)
                } else if let session = tab.streamSession {
                    // Permission request is now a window-level modal overlay
                    // (see body's ZStack) rather than an inline card that was
                    // easy to scroll past / miss entirely.
                    VStack(spacing: 0) {
                        V2LiveTranscript(session: session, projectCwd: tab.projectCwd)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Background task visibility (#69) — every
                        // run_in_background shell command, live; empty ⇒
                        // renders nothing.
                        V2BackgroundTasksStrip(session: session)
                        // Monitor watches, live off task_started/task_updated/
                        // task_notification — empty ⇒ renders nothing.
                        V2MonitorTasksStrip(session: session)
                        // Subagent delegations (Task/Agent) — stays visible
                        // once the inline delegation card has scrolled past;
                        // empty ⇒ renders nothing.
                        V2SubagentRunsStrip(session: session)
                        // Co-driven terminal panes (#56) — shared PTYs Claude
                        // and the user drive together; empty ⇒ renders nothing.
                        CoTerminalStrip(session: session)
                    }
                    // Deliberately NOT keyed by tab id. Keying tore down and
                    // rebuilt the ENTIRE transcript tree on every tab switch —
                    // every visible row's NSTextView recreated + laid out
                    // synchronously on main = the switch lag. Keeping one view
                    // identity lets SwiftUI update rows IN PLACE (cheap); the
                    // transcript handles the switch itself (detects the
                    // session change, resets its window, jumps to the bottom)
                    // so scroll state still never bleeds between conversations.
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
                if tab.provider == .codex, let session = tab.codexSession {
                    if session.requiresChatGPTLogin {
                        EmptyView()
                    } else if session.isResuming {
                        // History is loading off the app-server — the
                        // transcript shows its "Loading conversation…"
                        // overlay; don't flash the Start CTA underneath it.
                        EmptyView()
                    } else {
                        switch session.state {
                        case .idle, .terminated:
                            codexStartCTA(tab: tab, session: session)
                        default:
                            V2CodexComposer(session: session).id(tab.id)
                        }
                    }
                } else if let session = tab.streamSession {
                    if session.isObserving {
                        // Observer tabs REPLACE the composer, never merely
                        // disable it — read-only must read as a deliberate
                        // mode, and no input field means no takeover
                        // temptation (#76). send() is gated too; this is
                        // the visible half of that rule.
                        observingStrip(session: session)
                    } else if session.isResuming {
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

    /// The observer tab's composer replacement (#76 interim chrome, ahead of
    /// design #77): one quiet line saying what this is — no input field.
    /// 1Hz TimelineView only while the tab is visible; drives the
    /// observing / went-quiet language off the observed file's freshness.
    private func observingStrip(session: StreamSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 9) {
                let fresh = session.observedFileLastGrewAt.map { ctx.date.timeIntervalSince($0) < 90 } ?? false
                if fresh {
                    V2PulseDot(size: 6, color: palette.ink)
                    Text("observing — this session is running in another app")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.mute)
                } else {
                    Circle().fill(palette.line2).frame(width: 6, height: 6)
                    Text("observing — went quiet \(quietAge(session, now: ctx.date)) ago")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.faint)
                }
                Spacer()
                Text("read-only")
                    .font(.system(size: 9.5, design: .monospaced))
                    .kerning(0.5)
                    .foregroundColor(palette.faint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(palette.line2, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(palette.card)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }

    private func quietAge(_ session: StreamSession, now: Date) -> String {
        guard let grew = session.observedFileLastGrewAt else { return "a while" }
        let s = max(0, Int(now.timeIntervalSince(grew)))
        return s < 60 ? "\(s)s" : "\(s / 60)m"
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
                HStack(spacing: 10) {
                    providerAvailability(
                        .claude,
                        version: appState.claudeVersion,
                        isAvailable: appState.claudeBinary != nil
                    )
                    providerAvailability(
                        .codex,
                        version: appState.codexVersion,
                        isAvailable: appState.codexBinary != nil
                    )
                }
            }
            // (A selected project now routes to V2ProjectHome, which carries
            // its own "+ New session" / ⌘N — so this empty state only shows
            // with NO project selected. The old "New tab" button here was
            // unreachable and has been removed.)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.paper)
        .sheet(isPresented: $showClaudeInstall) {
            V2ProviderInstallSheet(provider: .claude).environmentObject(appState)
        }
        .sheet(isPresented: $showCodexInstall) {
            V2ProviderInstallSheet(provider: .codex).environmentObject(appState)
        }
    }

    private func providerAvailability(
        _ provider: V2AgentProvider,
        version: SemVer?,
        isAvailable: Bool
    ) -> some View {
        let status = isAvailable
            ? version.map { "v\($0.description) ready" } ?? "ready"
            : "not found"
        return Button {
            guard !isAvailable else { return }
            if provider == .claude { showClaudeInstall = true } else { showCodexInstall = true }
        } label: {
            HStack(spacing: 6) {
                V2ProviderMark(provider: provider, size: 11)
                Text(status)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(isAvailable ? palette.faint : palette.del)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.providerBackground(provider))
            .overlay(Rectangle().stroke(palette.providerAccent(provider).opacity(0.60), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isAvailable)
        .help("\(provider.displayName) \(isAvailable ? "is ready" : "was not found — click to install")")
    }

    /// Replaces a plain, unclickable "not found" sentence with an actual
    /// next step — the whole point of this pass (user report, 2026-07-18:
    /// a fresh user with no binary or no auth had nowhere to go from here).
    private func actionableNotice(_ text: String, action: String, onTap: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(palette.del)
            Button(action: onTap) {
                Text(action)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(palette.ink)
                    .underline()
            }
            .buttonStyle(.plain)
        }
    }

    private func closeActiveTabOrWindow() {
        if let id = appState.activeTabId {
            appState.close(tabId: id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    // MARK: - Session portability

    /// Writes the active tab's conversation to a portable bundle. The
    /// transcript is copied verbatim; credentials never leave this Mac,
    /// and neither does the unsent composer draft — the panel promises
    /// "the conversation only" and the manifest honours it.
    private func exportActiveSession() {
        guard !sessionPortBusy else { return }
        guard let tab = appState.activeTab, tab.surface == .modeB else {
            return report(title: "Export", "Open a chat tab to export its session.")
        }
        let provider = tab.provider
        let sessionId: String? = provider == .codex
            ? (tab.codexSession?.threadId ?? appState.codexResumeIds[tab.id])
            : (tab.streamSession?.sessionId ?? appState.resumeIds[tab.id])
        guard let sessionId else {
            return report(title: "Export", "This tab hasn't started a session yet, so there's nothing to export.")
        }
        // Resolve the real transcript up front, with a provider-correct
        // error. (The Codex fallback used to be a freshly-timestamped path
        // that could never exist, producing a Claude-specific "30 days"
        // message for a Codex miss.)
        let source: URL
        if provider == .codex {
            guard let rollout = V2SessionBundle.findCodexRollout(threadId: sessionId) else {
                return report(title: "Export failed", V2SessionBundle.BundleError.codexRolloutMissing.localizedDescription)
            }
            source = rollout
        } else {
            source = SessionHistoryLoader.jsonlURL(sessionId: sessionId, projectCwd: tab.projectCwd)
        }

        let manifest = V2SessionBundle.Manifest(
            provider: provider == .codex ? "codex" : "claude",
            sessionId: sessionId,
            projectCwd: tab.projectCwd,
            title: tab.title,
            draft: nil,
            exportedAt: Date(),
            exportedBy: "Atelier \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        )

        let panel = NSSavePanel()
        panel.nameFieldStringValue = V2SessionBundle.suggestedFilename(for: manifest)
        panel.canCreateDirectories = true
        panel.title = "Export Session"
        panel.message = "The conversation only — your sign-in and unsent draft stay on this Mac."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        sessionPortBusy = true
        // Off the main thread: a real transcript is tens of MB (71MB seen
        // here), and copying it inline tripped the 3s hang watchdog —
        // which then froze the app a further 3s to sample it.
        Task.detached(priority: .userInitiated) {
            let result = Result { try V2SessionBundle.export(manifest: manifest, transcriptAt: source, to: destination) }
            await MainActor.run {
                sessionPortBusy = false
                switch result {
                case .success(let entries):
                    report(title: "Exported", "\(entries) entr\(entries == 1 ? "y" : "ies") → \(destination.lastPathComponent)")
                case .failure(let error):
                    report(title: "Export failed", error.localizedDescription)
                }
            }
        }
    }

    /// Reads a bundle and files its transcript under the project you pick
    /// ON THIS MACHINE — the path rewrite that makes a session from another
    /// Mac resolvable here at all.
    private func importSessionBundle() {
        guard !sessionPortBusy else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.init(filenameExtension: V2SessionBundle.fileExtension)].compactMap { $0 }
        open.canChooseDirectories = false
        open.title = "Import Session"
        open.message = "Choose an Atelier session file (.\(V2SessionBundle.fileExtension))."
        guard open.runModal() == .OK, let bundle = open.url else { return }

        let manifest: V2SessionBundle.Manifest
        do {
            manifest = try V2SessionBundle.readManifest(at: bundle)
        } catch {
            return report(title: "Import failed", error.localizedDescription)
        }
        // The provider's runtime is needed to OPEN the session afterwards —
        // check before writing anything, or the import "succeeds" invisibly
        // (transcript lands on disk, the open bails, no tab, no message).
        if manifest.agentProvider == .codex, appState.codexBinary == nil {
            return report(title: "Import", "This is a Codex session, but the Codex CLI isn't installed on this Mac.")
        }
        if manifest.agentProvider == .claude, appState.claudeBinary == nil {
            return report(title: "Import", "This is a Claude session, but Claude Code isn't installed on this Mac.")
        }

        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = false
        picker.title = "Project for this session"
        picker.message = "It was exported from \(manifest.projectCwd). Choose the matching folder on this Mac."
        picker.directoryURL = appState.selectedProjectCwd
        guard picker.runModal() == .OK, let target = picker.url else { return }

        sessionPortBusy = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try V2SessionBundle.importBundle(at: bundle, intoProjectCwd: target.path) }
            await MainActor.run { finishImport(result, bundle: bundle, manifest: manifest, target: target) }
        }
    }

    private func finishImport(
        _ result: Result<URL, Error>,
        bundle: URL, manifest: V2SessionBundle.Manifest, target: URL
    ) {
        sessionPortBusy = false
        switch result {
        case .success:
            openImported(manifest: manifest, target: target)
        case .failure(let error):
            if case V2SessionBundle.BundleError.alreadyExists = error {
                // The one refusal with a real user decision behind it.
                let alert = NSAlert()
                alert.messageText = "This session already exists on this Mac"
                alert.informativeText = "Importing will replace the local copy. If that session is open anywhere, close it first."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                sessionPortBusy = true
                Task.detached(priority: .userInitiated) {
                    let retry = Result { try V2SessionBundle.importBundle(at: bundle, intoProjectCwd: target.path, replaceExisting: true) }
                    await MainActor.run {
                        sessionPortBusy = false
                        switch retry {
                        case .success: openImported(manifest: manifest, target: target)
                        case .failure(let error): report(title: "Import failed", error.localizedDescription)
                        }
                    }
                }
            } else {
                report(title: "Import failed", error.localizedDescription)
            }
        }
    }

    /// Open it straight away — an import that leaves you hunting for the
    /// session in a list hasn't finished the job.
    private func openImported(manifest: V2SessionBundle.Manifest, target: URL) {
        let name = target.lastPathComponent
        switch manifest.agentProvider {
        case .codex:
            appState.openCodexHistoryThread(
                threadId: manifest.sessionId, projectCwd: target.path, title: manifest.title ?? name
            )
        default:
            appState.openHistorySession(
                sessionId: manifest.sessionId, projectCwd: target.path,
                projectName: name, title: manifest.title ?? name
            )
        }
        report(title: "Imported", "\(manifest.title ?? name) is ready.")
    }

    private func report(title: String, _ message: String) {
        sessionPortTitle = title
        sessionPortMessage = message
        showSessionPortAlert = true
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
                actionableNotice("Claude Code isn't installed.", action: "Install") { showClaudeInstall = true }
            } else if !canStart {
                Text("Mode-B needs ≥ \(ClaudeBinary.minimumSupported.description). Update Claude Code.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            } else if case .loggedOut = appState.claudeAuth.status {
                actionableNotice("Not signed in to Claude.", action: "Sign in") { showClaudeSignIn = true }
            } else if case .checkFailed(let message) = appState.claudeAuth.status {
                Text(message)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.del)
            }
        }
        .sheet(isPresented: $showClaudeInstall) {
            V2ProviderInstallSheet(provider: .claude).environmentObject(appState)
        }
        .sheet(isPresented: $showClaudeSignIn) {
            V2ClaudeSignInSheet(auth: appState.claudeAuth).environmentObject(appState)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    private func codexStartCTA(tab: TerminalTab, session: CodexSession) -> some View {
        let canStart = appState.codexBinary != nil
        return HStack(spacing: 12) {
            Button { appState.startActiveSession() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("Start session in \(tab.title)")
                        .font(.system(size: 12, design: .monospaced))
                }
                .foregroundColor(canStart ? palette.paper : palette.faint)
                .padding(.horizontal, 15).padding(.vertical, 9)
                .background(canStart ? palette.ink : palette.line2)
            }
            .buttonStyle(.plain).disabled(!canStart)
            if !canStart {
                actionableNotice("Codex CLI isn't installed.", action: "Install") { showCodexInstall = true }
            } else if let error = session.endError {
                Text(error).font(.system(size: 10.5, design: .monospaced)).foregroundColor(palette.del).lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 26).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        .sheet(isPresented: $showCodexInstall) {
            V2ProviderInstallSheet(provider: .codex).environmentObject(appState)
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
