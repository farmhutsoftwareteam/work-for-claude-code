// Auto-open the Atelier v2 (preview) window on first appear of the v1 main
// window, then immediately miniaturise v1 so the user lands on v2 by
// default. Same behaviour ships in Debug + Release now — v2 IS the main
// surface; v1 stays accessible via the Dock for emergency fallback.
//
// Why not just remove the v1 WindowGroup? Two reasons:
//   1. WindowGroup is the only macOS scene type that auto-opens on launch;
//      Window scenes have to be opened by explicit action. We need
//      WindowGroup → v1 to keep WorkApp launching at all, then we steer
//      focus to v2 once both windows exist.
//   2. v1 still owns several editors (Extensions, Plugins) we haven't
//      ported to v2 yet. Keeping it un-deleted means the user can pop it
//      back open via the Dock if they need those surfaces.

import SwiftUI
import AppKit

struct V2AutoOpenInDebug: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpen = false

    func body(content: Content) -> some View {
        content.task {
            guard !didOpen else { return }
            didOpen = true
            openWindow(id: "v2-preview")

            // Bring v2 to the front and miniaturise v1 so the session
            // lands on v2 immediately. The user can un-miniaturise v1 via
            // the Dock or ⌘W out of v2 to fall back to v1. Tiny delay so
            // the new window has time to materialise.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for window in NSApp.windows {
                    if window.title == "Atelier v2 (preview)" {
                        window.makeKeyAndOrderFront(nil)
                    } else if window.identifier == nil
                                || (window.identifier?.rawValue.isEmpty ?? true) {
                        window.miniaturize(nil)
                    }
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
