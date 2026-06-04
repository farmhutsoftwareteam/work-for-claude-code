import SwiftUI
import AppKit
import SwiftTerm

/// Thin SwiftUI wrapper that *displays* the `LocalProcessTerminalView` the
/// controller already owns. The view itself is NOT created here — we fetch
/// it by id so that SwiftUI can tear this wrapper down and re-create it
/// without killing the PTY.
///
/// If the controller has no view for the given id (e.g. the tab was closed
/// while we were rendering), we show a small placeholder rather than crash.
struct EmbeddedTerminalView: NSViewRepresentable {
    let tabId: UUID
    @EnvironmentObject var terminals: TerminalsController

    /// Containing box — lets us swap in the underlying view if the controller
    /// reassigns it (rare, but keeps the tree robust).
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Re-attach if the controller handed back a new view instance (e.g.
        // after a respawn) or if SwiftUI moved us to a different parent.
        // Find our terminal subview specifically rather than asserting
        // `count == 1` — a sibling NSView (debug overlay, a11y element)
        // would otherwise cause an unnecessary detach-reattach churn.
        let currentTerm = container.subviews.compactMap { $0 as? LocalProcessTerminalView }.first
        if currentTerm !== terminals.view(for: tabId) {
            currentTerm?.removeFromSuperview()
            attach(to: container)
        }

        // When the tab becomes active, make the terminal first responder so
        // keystrokes go straight to the PTY.
        guard terminals.activeTabId == tabId,
              let term = terminals.view(for: tabId),
              let window = container.window,
              window.firstResponder !== term
        else { return }
        let capturedTabId = self.tabId
        let capturedController = terminals
        DispatchQueue.main.async { [weak container, weak term] in
            guard let container,
                  let term,
                  let window = container.window,
                  // Re-check the controller still considers this the active
                  // tab — if the user switched tabs between scheduling and
                  // firing, the old terminal shouldn't steal focus back.
                  capturedController.activeTabId == capturedTabId,
                  window.firstResponder !== term,
                  term.superview === container
            else { return }
            window.makeFirstResponder(term)
        }
    }

    private func attach(to container: NSView) {
        guard let term = terminals.view(for: tabId) else {
            // Fallback placeholder — shouldn't happen in the happy path.
            let label = NSTextField(labelWithString: "Terminal unavailable.")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return
        }
        // BUG-11/70 fix: if the term is already a subview of a different
        // container, detach it first so its prior auto-layout constraints
        // (which reference the old superview) are deactivated cleanly. Re-
        // adding without this can produce "Unable to satisfy constraints" logs.
        if let oldSuperview = term.superview, oldSuperview !== container {
            term.removeFromSuperview()
        }
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
