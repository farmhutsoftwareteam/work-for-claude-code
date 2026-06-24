// Auto-open the Atelier v2 preview window on first appear of the main window
// in DEBUG builds. Without this, the v2 window only opens via Window menu —
// easy to miss when reviewing progress.

import SwiftUI

struct V2AutoOpenInDebug: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpen = false

    func body(content: Content) -> some View {
        content.task {
            #if DEBUG
            guard !didOpen else { return }
            didOpen = true
            openWindow(id: "v2-preview")
            #endif
        }
    }
}
