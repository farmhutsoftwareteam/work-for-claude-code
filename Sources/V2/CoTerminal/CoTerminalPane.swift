// Co-driven terminal panes in the session column (#56 — placeholder chrome;
// final dual-driver design lands with Co-driven terminal.dc.html / #58).
// Header: command chip · running elapsed / exit valence · secure badge ·
// agent-input attribution · close. Body: the shared SwiftTerm view — click
// to type; Claude reads/writes through the bridge.

import SwiftUI
import SwiftTerm
import Inject

/// Stacked panes for the active session, mounted between transcript and
/// composer. Renders nothing when the session has no co-driven terminals.
struct CoTerminalStrip: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject private var manager = CoTerminalManager.shared
    let session: StreamSession

    var body: some View {
        let terms = manager.terminals(for: session)
        VStack(spacing: 10) {
            ForEach(terms) { t in
                CoTerminalPaneView(terminal: t) {
                    manager.close(t, scope: ObjectIdentifier(session))
                }
            }
        }
        .padding(.horizontal, terms.isEmpty ? 0 : 26)
        .padding(.bottom, terms.isEmpty ? 0 : 10)
        .enableInjection()
    }
}

struct CoTerminalPaneView: View {
    @Environment(\.v2) private var v2
    @ObservedObject var terminal: CoTerminal
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if terminal.secureInput { secureBanner }
            TerminalHostView(terminal: terminal)
                .frame(height: 280)
            if !terminal.agentInputs.isEmpty { attributionStrip }
        }
        .background(v2.card)
        .overlay(Rectangle().stroke(terminal.secureInput ? v2.del : v2.line2,
                                    lineWidth: terminal.secureInput ? 2 : 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            V2CommandChip(terminal.command)
            Spacer(minLength: 8)
            if terminal.isRunning {
                HStack(spacing: 7) {
                    V2PulseDot(size: 6, color: v2.ink)
                    TimelineView(.periodic(from: terminal.startedAt, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(terminal.startedAt)))
                        Text("\(s / 60):" + String(format: "%02d", s % 60))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(v2.mute)
                            .monospacedDigit()
                    }
                }
            } else {
                let code = terminal.exitCode ?? -1
                Text(code == 0 ? "✓ exit 0" : "✗ exit \(code)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(code == 0 ? v2.add : v2.del)
            }
            // Agent-watching hint: recent tool reads → the mark is "looking".
            if let read = terminal.lastAgentReadAt, Date().timeIntervalSince(read) < 10 {
                V2DovetailMark(size: 12).foregroundColor(v2.mute)
                    .help("Claude is watching this terminal")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal (terminates the process)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var secureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("secure prompt — type directly · hidden from the agent")
                .font(.system(size: 10.5, design: .monospaced))
            Spacer()
        }
        .foregroundColor(v2.del)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(v2.delBg)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    /// Attribution: what the AGENT typed (user input shows in the terminal
    /// itself). Secure writes are rejected upstream, so no secret can land here.
    private var attributionStrip: some View {
        HStack(spacing: 8) {
            V2DovetailMark(size: 10).foregroundColor(v2.faint)
            Text(terminal.agentInputs.suffix(3).joined(separator: "   "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.mute)
                .lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(v2.paper2)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }
}

/// Hosts the CoTerminal's SwiftTerm view. The view instance belongs to the
/// CoTerminal (it must survive SwiftUI churn); this wrapper only mounts it.
private struct TerminalHostView: NSViewRepresentable {
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
