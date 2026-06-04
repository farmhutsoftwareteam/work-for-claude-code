import Foundation
import Sparkle

/// Observable wrapper around Sparkle's updater state so SwiftUI views can show
/// a persistent "Update available" badge. Listens to the standard updater's
/// delegate callbacks and republishes them on the main actor.
///
/// Because `SUAutomaticallyUpdate` is enabled, Sparkle downloads new versions
/// silently in the background. We track the download state so the UI can say
/// "Downloading…" while it's in flight and "Relaunch to update" once it's
/// finished — matching the Slack/Brave UX where Install is instant.
@MainActor
final class UpdateStateObserver: NSObject, ObservableObject {
    /// Any update state: either downloading or ready.
    @Published var hasUpdate: Bool = false
    /// True when the update has finished downloading and can be installed immediately.
    @Published var isDownloaded: Bool = false
    /// The new version number (e.g. "1.0.5") to show in the banner / badge tooltip.
    @Published var availableVersion: String?

    /// Set by WorkApp after the SPUStandardUpdaterController is initialized.
    weak var updater: SPUUpdater?

    /// Show Sparkle's user-facing update dialog.
    /// If the update is already downloaded (SUAutomaticallyUpdate=YES), the
    /// dialog shows the "Install and Relaunch" button immediately — no wait.
    func presentUpdate() {
        updater?.checkForUpdates()
    }

    /// Label the primary button should show based on current state.
    var primaryActionLabel: String {
        isDownloaded ? "Relaunch to update" : "Downloading…"
    }

    /// Shorter version for the sidebar toolbar pill.
    var compactActionLabel: String {
        isDownloaded ? "Relaunch" : "Updating"
    }
}

// Sparkle calls these from arbitrary threads; hop to @MainActor before touching @Published.
extension UpdateStateObserver: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.hasUpdate = true
            self.isDownloaded = false
            self.availableVersion = item.displayVersionString
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.hasUpdate = true
            self.isDownloaded = true
            self.availableVersion = item.displayVersionString
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.hasUpdate = false
            self.isDownloaded = false
            self.availableVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // About to install — clear the badge so it doesn't flash during restart
        Task { @MainActor in
            self.hasUpdate = false
            self.isDownloaded = false
        }
    }
}
