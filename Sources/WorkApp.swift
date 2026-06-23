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
        self.updaterController = controller
        _updateState = StateObject(wrappedValue: observer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        .defaultSize(width: 1010, height: 670)
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
}
