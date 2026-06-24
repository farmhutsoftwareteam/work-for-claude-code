// Auto-open the Atelier v2 preview window on first appear of the main window
// in DEBUG builds, then immediately hide the v1 window so we're not staring
// at the production chrome we're trying to replace.
//
// Why not just remove the v1 WindowGroup in DEBUG? Two reasons:
//   1. v1 is the actual shipped surface today; testing v2 alongside it is
//      the whole point of running the dev build.
//   2. WindowGroup is the only macOS scene type that auto-opens on launch;
//      Window scenes have to be opened by explicit action. So we need
//      WindowGroup → v1 to keep WorkApp launching at all, then steer focus
//      to v2 once both windows exist.

import SwiftUI
import AppKit

struct V2AutoOpenInDebug: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpen = false

    func body(content: Content) -> some View {
        content.task {
            #if DEBUG
            guard !didOpen else { return }
            didOpen = true
            openWindow(id: "v2-preview")

            // Bring the v2 window to the front and miniaturize the v1 main
            // window so the dev session lands on v2 immediately. The user
            // can un-miniaturize v1 via the Dock or ⌘W to close v2 and fall
            // back to v1. Runs after a tiny delay so the new window has
            // time to materialise.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for window in NSApp.windows {
                    if window.title == "Atelier v2 (preview)" {
                        window.makeKeyAndOrderFront(nil)
                    } else if window.identifier == nil
                                || (window.identifier?.rawValue.isEmpty ?? true) {
                        // The default WindowGroup window — miniaturize it
                        // so the dev session focuses on v2.
                        window.miniaturize(nil)
                    }
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            #endif
        }
    }
}
