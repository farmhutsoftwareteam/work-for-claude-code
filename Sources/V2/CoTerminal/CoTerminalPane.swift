// Co-driven terminal hosting (#58, redesigned per "Floating terminal
// window.dc.html"). The per-pane header/attribution/collapse chrome that
// used to stack one full pane per terminal directly above the composer has
// moved to V2FloatingTerminalWindow — a single floating panel with its own
// title bar and a shell-tab strip, so N concurrent shells cost one fixed-size
// window instead of N stacked cards crowding the input. What's left here is
// just the reusable primitive both that window and any future caller mount.

import SwiftUI
import SwiftTerm

/// Hosts the CoTerminal's SwiftTerm view. The view instance belongs to the
/// CoTerminal (it must survive SwiftUI churn); this wrapper only mounts it.
struct TerminalHostView: NSViewRepresentable {
    let terminal: CoTerminal

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let tv = terminal.view!
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The terminal view is long-lived and self-updating — nothing to sync.
    }
}
