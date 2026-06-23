import AppKit
import Foundation

/// Detects when Work is running from a location Sparkle refuses to update from
/// (mounted DMG, Downloads folder, Desktop, etc.) and offers to self-relocate
/// into `/Applications`. Without this, users who open the DMG and launch Work
/// directly from the mounted volume get a dead-end Sparkle dialog next time we
/// ship an update.
///
/// Inspired by Potion Factory's `LetsMove`, ported to Swift and stripped down
/// to what Work actually needs. One-shot: if the user declines, we record that
/// and never ask again (they can undo via "Offer to move to Applications…" in
/// the Help menu — future enhancement).
enum ApplicationsFolderMigrator {

    /// UserDefaults key scoped to the running app's major.minor version.
    /// A user who clicks "Don't Ask Again" on 1.0.x stops getting prompted
    /// for that release line; when we ship 1.1 (or 2.0) the key changes,
    /// resetting the decline so any prompt-worthy install changes can be
    /// re-evaluated. No UI affordance needed for "reset prompts."
    private static var declineKey: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let parts = version.split(separator: ".")
        let majorMinor = parts.count >= 2
            ? "\(parts[0]).\(parts[1])"
            : version
        return "workAppMoveDeclined-\(majorMinor)"
    }

    /// Call once during app launch. No-op if we're already in a valid
    /// Applications folder, if the user has previously declined, or if
    /// relocation isn't safe (e.g. running from Xcode's DerivedData).
    static func offerIfNeeded() {
        // Skip in Debug / DerivedData builds — developers run from the build
        // folder deliberately and do not want a "move to /Applications" alert.
        let path = Bundle.main.bundlePath
        if path.contains("/DerivedData/") || path.contains("/Xcode/") {
            return
        }

        if isInApplicationsFolder(path) { return }

        // **App Translocation handling.** When macOS Gatekeeper detects an
        // app launched from a downloaded location (DMG, ~/Downloads, etc.)
        // for the first time, it silently copies the bundle to a randomized
        // read-only path under `/private/var/folders/.../AppTranslocation/`
        // and runs it from there. Our bundle path then looks nothing like
        // `/Applications/Work.app` even when a copy DOES exist there. If we
        // naively prompt, the user goes "but I already moved it!" and we
        // burn their trust. So: if /Applications/Work.app already exists
        // (or the user has explicitly declined), offer to re-launch from
        // /Applications instead of re-copying.
        let installedPath = "/Applications/\(Bundle.main.bundleURL.lastPathComponent)"
        let alreadyInstalled = FileManager.default.fileExists(atPath: installedPath)
        let translocated = isTranslocated(path)

        if UserDefaults.standard.bool(forKey: declineKey) {
            // User previously said no. Don't nag, but Sparkle will still
            // surface its own error if they try to update from here.
            return
        }

        if translocated, alreadyInstalled {
            // We're a translocated copy and /Applications/Work.app exists.
            // The user has already done the install — they just launched
            // the wrong copy. Quietly relaunch from /Applications and exit;
            // no need for a dialog every time.
            relaunchFromApplications(installedPath: installedPath)
            return
        }

        let runningFromDMG = path.hasPrefix("/Volumes/")
        promptAndMaybeMove(
            runningFromDMG: runningFromDMG,
            translocated: translocated,
            alreadyInstalled: alreadyInstalled,
            installedPath: installedPath
        )
    }

    // MARK: - Detection

    /// True when the bundle lives in a well-known Applications folder — the
    /// one place Sparkle is happy to update in place.
    private static func isInApplicationsFolder(_ path: String) -> Bool {
        let canonical = (path as NSString).standardizingPath
        let candidates = [
            "/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
        return candidates.contains { canonical.hasPrefix($0 + "/") }
    }

    /// macOS App Translocation hides newly-downloaded apps in a randomized
    /// path. The reliable canonical marker is `/AppTranslocation/` in the
    /// bundle path; that's what we look for. (An earlier version also
    /// flagged any path under `/private/var/folders/` but that's too
    /// broad — sandboxed apps and App Store containers can also live
    /// there, so the loose match caused false positives.)
    private static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    // MARK: - Prompt

    private static func promptAndMaybeMove(
        runningFromDMG: Bool,
        translocated: Bool,
        alreadyInstalled: Bool,
        installedPath: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        if translocated {
            // First-launch translocation, no copy in /Applications yet.
            alert.messageText = "Drag Atelier to your Applications folder"
            alert.informativeText = """
            macOS is currently running Atelier from a temporary location to \
            keep you safe. To get automatic updates and keep Atelier between \
            restarts, drag it from the disk image into the Applications \
            folder, then launch it from there.

            I can do this move for you now if you'd like.
            """
        } else if runningFromDMG {
            alert.messageText = "Move Atelier to your Applications folder?"
            alert.informativeText = "Atelier is running from a mounted disk image. It needs to live in /Applications to receive automatic updates."
        } else {
            alert.messageText = "Move Atelier to your Applications folder?"
            alert.informativeText = "Atelier isn't in /Applications. If you leave it here, automatic updates will fail. Move it for me?"
        }

        alert.addButton(withTitle: alreadyInstalled
            ? "Quit and use the copy in Applications"
            : "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if alreadyInstalled {
                relaunchFromApplications(installedPath: installedPath)
            } else {
                moveAndRelaunch()
            }
        case .alertSecondButtonReturn:
            break
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: declineKey)
        default:
            break
        }
    }

    /// Quit this translocated copy and launch the existing
    /// /Applications/Work.app. No copy, no overwrite — the user already
    /// installed it, we just need to use the right binary.
    private static func relaunchFromApplications(installedPath: String) {
        let url = URL(fileURLWithPath: installedPath)
        launchAndExit(at: url, failureMessage: "Couldn't launch \(installedPath):")
    }

    /// Launch `url` as a fresh app instance, then exit this process. Handles
    /// three race conditions explicitly:
    ///
    /// 1. **Slow new copy.** Apple's `openApplication` completion handler
    ///    fires when the new process reports as launched. Once that lands
    ///    we wait a short 150ms grace so the new copy has a chance to
    ///    install its event handlers and present a window before this
    ///    process disappears (was 500ms — shaved without observable harm).
    ///
    /// 2. **Callback never fires.** Under heavy load or weird Gatekeeper
    ///    interactions the completion handler can be dropped. Without a
    ///    fallback we'd leave the old translocated copy running forever.
    ///    A 5-second watchdog calls exit anyway — by then the new copy
    ///    has either launched (and the user sees it) or genuinely failed
    ///    (and they relaunch manually), either way the old one shouldn't
    ///    linger.
    ///
    ///  3. **Launch error.** Surface the error and do NOT exit — leave the
    ///     translocated copy running so the user isn't stranded.
    private static func launchAndExit(at url: URL, failureMessage: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        // Watchdog: exit at most 5s after we asked NSWorkspace to launch the
        // replacement, regardless of whether the callback fires.
        let watchdog = DispatchWorkItem { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: watchdog)

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                watchdog.cancel()  // stay alive so the user can see the alert
                Task { @MainActor in
                    showError("\(failureMessage) \(error.localizedDescription)")
                }
                return
            }
            // Happy path: cancel the watchdog and exit on a tighter 150ms
            // grace so the new copy can take focus first.
            watchdog.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                exit(0)
            }
        }
    }

    // MARK: - Move + relaunch

    private static func moveAndRelaunch() {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let appName = source.lastPathComponent
        let dest = URL(fileURLWithPath: "/Applications/\(appName)")

        do {
            // If a previous copy is already in /Applications (e.g. older
            // version that didn't get overwritten by this DMG install),
            // trash it first so we install cleanly rather than copy-over.
            if fm.fileExists(atPath: dest.path) {
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: dest, resultingItemURL: &trashed)
                } catch {
                    // If trash fails (permissions, locked), try a direct remove
                    // so the copy below doesn't hit a "file exists" error.
                    try fm.removeItem(at: dest)
                }
            }

            try fm.copyItem(at: source, to: dest)

            // Unregister the old bundle with LaunchServices so re-launching
            // finds the new copy reliably (avoids "you have two Work.apps"
            // confusion and quirky icon caches).
            LSRegisterURL(dest as CFURL, true)

            // Launch the new copy. Shared helper handles the
            // completion / watchdog / exit sequence (see launchAndExit
            // above).
            launchAndExit(at: dest, failureMessage: "Couldn't launch Atelier from /Applications:")
        } catch {
            showError("Couldn't move Atelier to /Applications: \(error.localizedDescription)\n\nYou can drag it over manually from the DMG or Downloads.")
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
