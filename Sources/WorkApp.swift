import SwiftUI
import Sparkle

private struct CheckForUpdatesView: View {
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
    }
}

@main
struct WorkApp: App {
    @StateObject private var store = Store()
    @StateObject private var updateState: UpdateStateObserver
    @StateObject private var terminals = TerminalsController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    /// Sticky once we've offered the PATH fix — true whether the user
    /// accepted, declined, or it was already correct. Stops us re-prompting
    /// on every launch.
    @AppStorage("pathFixOffered") private var pathFixOffered = false
    @State private var showPermissionAlert = false
    @State private var showPathFixAlert = false
    @State private var pathFixResult: PathFixResult?

    enum PathFixResult: Identifiable {
        case success(URL)
        case failure(String)
        var id: String {
            switch self {
            case .success(let url): return "success-\(url.path)"
            case .failure(let msg): return "failure-\(msg)"
            }
        }
    }

    private let updaterController: SPUStandardUpdaterController

    init() {
        // Create the observer, wire it as Sparkle's delegate, then hand it to @StateObject
        let observer = UpdateStateObserver()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: observer,
            userDriverDelegate: nil
        )
        observer.updater = controller.updater
        // Industry-standard visible updates: check automatically, but PROMPT
        // with Sparkle's dialog instead of silently installing. Set at runtime
        // too because Sparkle persists these in user defaults — existing
        // installs were seeded with silent mode by the old Info.plist and
        // would otherwise keep updating invisibly.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        self.updaterController = controller
        _updateState = StateObject(wrappedValue: observer)
    }

    var body: some Scene {
        // Atelier — THE app, and the primary scene: first in the body and
        // explicitly presented at launch. The old arrangement launched the
        // legacy v1 terminal window first (then tried to miniaturise it away),
        // which is why "the black terminal app" kept appearing at startup.
        Window("Atelier", id: "v2-preview") {
            V2RootView()
                .environmentObject(store)
                .environmentObject(updateState)
                .environmentObject(terminals)
                .onAppear {
                    AppDelegate.sharedTerminals = terminals
                    checkTerminalPermission()
                    checkPathFix()
                }
                .onChange(of: onboardingComplete) { _, completed in
                    if completed {
                        checkTerminalPermission()
                        checkPathFix()
                    }
                }
                .alert("Terminal Access Required", isPresented: $showPermissionAlert) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Later", role: .cancel) { }
                } message: {
                    Text("Atelier needs permission to control Terminal. Please enable it in System Settings → Privacy & Security → Automation → Atelier → Terminal.")
                }
                .alert("Add Claude to your shell PATH?", isPresented: $showPathFixAlert) {
                    Button("Add to PATH") { applyPathFix() }
                    Button("Skip", role: .cancel) { pathFixOffered = true }
                } message: {
                    Text("Claude is installed at ~/.local/bin/claude but that folder isn't in your shell PATH. Atelier can add one line to your shell config so you can run `claude` from any terminal. Existing terminals need a reload — new ones get it automatically.")
                }
                .alert(item: $pathFixResult) { result in
                    switch result {
                    case .success(let url):
                        return Alert(
                            title: Text("PATH updated"),
                            message: Text("Added one line to \(url.lastPathComponent). Open a new terminal or run `source \(url.path)` to apply it now."),
                            dismissButton: .default(Text("OK"))
                        )
                    case .failure(let message):
                        return Alert(
                            title: Text("Couldn't update PATH"),
                            message: Text(message),
                            dismissButton: .default(Text("OK"))
                        )
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            // Terminal tab shortcuts — mirrors Terminal.app / browsers
            CommandGroup(after: .windowArrangement) {
                Button("New Terminal Tab") { newTerminalTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    if let id = terminals.activeTabId {
                        terminals.close(id)
                    } else {
                        // No tab to close — fall through to system Cmd+W (close
                        // window). SwiftUI `.disabled` on a command keeps
                        // claiming the shortcut without executing, which would
                        // block the window-close default. Instead we handle
                        // both cases explicitly.
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Tab") { terminals.cycleFocus(delta: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { terminals.cycleFocus(delta: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1..<10) { i in
                    Button("Jump to Tab \(i)") { terminals.focus(index: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
            }

            CommandGroup(replacing: .help) {
                Button("Welcome to Atelier…") {
                    onboardingComplete = false
                }
            }
        }

        // Legacy v1 terminal window — kept reachable (the v2 chrome still
        // points at its Extensions editor) but it NEVER auto-opens: launch is
        // suppressed and state restoration disabled, so it only appears when
        // explicitly opened from the Window menu. Both scenes share the same
        // Store / TerminalsController / Update state — separate Scene =
        // separate SwiftUI environment, so we wire them explicitly here.
        Window("Atelier — legacy terminal", id: "v1-legacy") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updateState)
                .environmentObject(terminals)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1010, height: 670)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    private func checkTerminalPermission() {
        // Only check after onboarding — don't nag on first launch
        guard onboardingComplete else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            let hasPermission = PermissionCheck.hasTerminalPermission
            DispatchQueue.main.async {
                if !hasPermission {
                    showPermissionAlert = true
                }
            }
        }
    }

    /// One-time check on launch: if Claude is installed natively but the
    /// user's shell rc doesn't have ~/.local/bin in PATH, offer to fix it.
    /// `pathFixOffered` is sticky — we never re-prompt after the user has
    /// answered (yes or no) once.
    private func checkPathFix() {
        guard onboardingComplete, !pathFixOffered else { return }
        // Defer to the next runloop tick so SwiftUI has time to mount the
        // alert sheet — and so we don't fight with the Terminal-permission
        // alert if both fire on the same launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !pathFixOffered, PathFixer.needsFix() else { return }
            showPathFixAlert = true
        }
    }

    private func applyPathFix() {
        do {
            let url = try PathFixer.applyFix()
            pathFixResult = .success(url)
        } catch {
            pathFixResult = .failure(error.localizedDescription)
        }
        pathFixOffered = true
    }

    /// Spawn a new terminal tab in the most sensible project — the currently
    /// selected one if any, else the most-recently-active project.
    private func newTerminalTab() {
        let project = store.selectedProject ?? store.projects.first
        guard let project else {
            NSSound.beep()
            return
        }
        terminals.requestOpenNew(projectCwd: project.cwd, title: project.displayName)
    }
}

// MARK: - App delegate: graceful terminal shutdown

/// When the user quits the app, SIGTERM every live PTY child so no orphans
/// survive. `sharedTerminals` is populated by WorkApp on first appear.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var sharedTerminals: TerminalsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never run two instances of this app: after a Sparkle update replaces
        // the bundle, the OLD process keeps running from the replaced bundle —
        // and LaunchServices no longer matches it to the on-disk app, so
        // launching the new version starts a SECOND instance with the stale one
        // ghosting in the background. Same story for duplicate copies on disk.
        // Policy: the newest build wins; the other instance is asked to quit.
        enforceSingleInstance()

        // Offer to self-relocate into /Applications if we're running from a
        // DMG / Downloads / elsewhere. Sparkle refuses to update from those
        // locations, so catching it at first launch saves users the
        // dead-end "can't be updated" dialog later.
        ApplicationsFolderMigrator.offerIfNeeded()

        // Refresh pricing in the background. Silent on failure; the Usage
        // tab is always usable from the embedded pricing table.
        Task.detached(priority: .utility) {
            await PricingFetcher.shared.fetchIfStale()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.sharedTerminals?.shutdownAll()
        return .terminateNow
    }

    /// Quit when the last window closes. Without this the process lingers
    /// invisibly after the window is closed — the user believes the app is
    /// quit, an update then replaces the bundle underneath it, and the next
    /// launch runs alongside the stale ghost. Closed window = quit app, so a
    /// windowless instance can never be the "old version in the background".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// If another instance of THIS app (same bundle identifier — dev and prod
    /// have different ids and coexist on purpose) is already running, keep the
    /// newest build and quit the other. Handles the post-update ghost (old
    /// process from a replaced bundle) and duplicate on-disk copies.
    private func enforceSingleInstance() {
        guard let myId = Bundle.main.bundleIdentifier else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

        for other in NSRunningApplication.runningApplications(withBundleIdentifier: myId)
        where other.processIdentifier != myPid {
            // Best-effort read of the other instance's build. If its bundle was
            // replaced by an update this reads the NEW plist — the comparison
            // ties, and ties go to us (the fresh launch), which is correct.
            let otherBuild = other.bundleURL
                .flatMap { Bundle(url: $0) }
                .flatMap { $0.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
                .flatMap(Int.init) ?? 0

            if otherBuild > myBuild {
                // The running instance is newer than us — the user launched a
                // stale copy. Hand over and bow out.
                other.activate()
                NSApp.terminate(nil)
                return
            }
            // Stale or duplicate instance — polite quit (its own
            // applicationShouldTerminate SIGTERMs its children), force only
            // if it's still around after a grace period.
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if !other.isTerminated { other.forceTerminate() }
            }
        }
    }
}
