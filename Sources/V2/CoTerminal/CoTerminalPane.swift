// Co-driven terminal panes (#58 — implements Co-driven terminal.dc.html).
// One terminal, two drivers: header carries the command chip, the secure-
// prompt state, the agent-watching dovetail, and running/exit status; the
// body is a real SwiftTerm view (dark in both themes); the attribution strip
// logs what the AGENT typed — user input shows in the terminal itself.
//
// Design deviation, deliberate: the artifact's footer hint says "esc returns
// to composer", but ESC must reach the PTY (TUIs need it) — so the hint is
// "click to type" only.

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
        VStack(spacing: 14) {
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
        VStack(alignment: .leading, spacing: 7) {
            VStack(spacing: 0) {
                header
                if terminal.isCollapsed {
                    // Folded: keep a live one-line tail while it runs, so the
                    // collapsed pane still says what's happening. On exit the
                    // header's ✓/✗ carries the outcome.
                    if terminal.isRunning { collapsedTail }
                } else {
                    TerminalHostView(terminal: terminal)
                        .frame(height: 262)
                    if !terminal.agentInputs.isEmpty || terminal.secureInput {
                        attributionStrip
                    }
                }
            }
            // A secure prompt needs the USER's keyboard — never stay folded.
            .onChange(of: terminal.secureInput) { _, secure in
                if secure { terminal.isCollapsed = false }
            }
            .background(v2.card)
            // Secure prompt = doubled clay border (1px inner + 1px outer ring,
            // 2px apart) — the design's "impossible to skim past" treatment.
            .overlay(Rectangle().stroke(terminal.secureInput ? v2.del : v2.line2, lineWidth: 1))
            .overlay {
                if terminal.secureInput {
                    Rectangle().stroke(v2.del, lineWidth: 1).padding(-3)
                }
            }

            if !terminal.isCollapsed {
                Text("click to type")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
        }
    }

    /// Last meaningful output line, ANSI-stripped — the folded pane's pulse.
    /// Refreshes once a second (the ring updates without publishes by design).
    private var collapsedTail: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(Self.lastLine(of: terminal))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.mute)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(v2.paper2)
                .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
        }
    }

    // Hoisted (bug-hunt LOW): `replacingOccurrences(…, options: .regularExpression)`
    // compiles a fresh NSRegularExpression internally on every call. This runs
    // off a 1Hz TimelineView tick per COLLAPSED terminal (PERFORMANCE.md §4:
    // no regex construction in a per-row/per-tick path) — compile once here
    // instead.
    nonisolated(unsafe) private static let oscEscapeRegex = try? NSRegularExpression(pattern: "\u{1B}\\][^\u{07}]*\u{07}")
    nonisolated(unsafe) private static let csiEscapeRegex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    private static func lastLine(of terminal: CoTerminal) -> String {
        let raw = terminal.ring.read(since: nil).text
        var clean = raw
        for regex in [oscEscapeRegex, csiEscapeRegex] {
            guard let regex else { continue }
            clean = regex.stringByReplacingMatches(
                in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        return clean
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? "…"
    }

    // MARK: Header (36px, paper2)

    private var header: some View {
        HStack(spacing: 11) {
            V2CommandChip(terminal.command)

            if terminal.secureInput {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("secure prompt — type directly · hidden from the agent")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundColor(v2.del)
            }

            Spacer(minLength: 8)

            // Agent-watching dovetail: pulses when the agent read the screen
            // recently, dims when idle; hidden during secure (locked out) and
            // after exit.
            if terminal.isRunning && !terminal.secureInput {
                WatchingMark(lastReadAt: terminal.lastAgentReadAt)
            }

            if terminal.isRunning {
                HStack(spacing: 7) {
                    V2PulseDot(size: 7, color: v2.add)
                    TimelineView(.periodic(from: terminal.startedAt, by: 1)) { ctx in
                        Text(Self.mmss(ctx.date.timeIntervalSince(terminal.startedAt)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.mute)
                            .monospacedDigit()
                    }
                }
            } else {
                let code = terminal.exitCode ?? -1
                let dur = Self.mmss((terminal.endedAt ?? Date()).timeIntervalSince(terminal.startedAt))
                HStack(spacing: 7) {
                    Text(code == 0 ? "✓" : "✗").foregroundColor(code == 0 ? v2.add : v2.del)
                    Text("exit \(code) · \(dur)").foregroundColor(code == 0 ? v2.mute : v2.del)
                }
                .font(.system(size: 11, design: .monospaced))
                // A real, labeled dismiss — the old 18px bare ✕ was easy to
                // miss, and finished panes otherwise stack forever.
                Button(action: onClose) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                        Text("dismiss")
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss this terminal")
            }

            // Fold/unfold — collapse the terminal to this header while it works;
            // the header keeps the timer and flips ✓/✗ when done.
            Button { terminal.isCollapsed.toggle() } label: {
                Image(systemName: terminal.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(terminal.isCollapsed ? "Expand terminal" : "Collapse to header — keeps running")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(v2.paper2)
        .contentShape(Rectangle())
        .onTapGesture { terminal.isCollapsed.toggle() }
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: Attribution strip — what the AGENT typed

    private var attributionStrip: some View {
        HStack(spacing: 14) {
            Text("INPUT")
                .font(.system(size: 9.5, design: .monospaced)).kerning(1.0)
                .foregroundColor(v2.faint)
            ForEach(Array(terminal.agentInputs.suffix(4).enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 5) {
                    V2DovetailMark(size: 10).foregroundColor(v2.mute)
                    Text(entry)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .lineLimit(1)
                }
                .help("typed by the agent")
            }
            Spacer(minLength: 8)
            if terminal.secureInput {
                Text("agent locked out")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.del)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(v2.paper2)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// The header's agent-watching indicator: dovetail pulses while reads are
/// recent (<10s), dims to faint when the agent hasn't looked lately.
private struct WatchingMark: View {
    @Environment(\.v2) private var v2
    let lastReadAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let recent = lastReadAt.map { ctx.date.timeIntervalSince($0) < 10 } ?? false
            V2DovetailMark(size: 13)
                .foregroundColor(recent ? v2.ink : v2.faint)
                .opacity(recent ? 1 : 0.8)
                .modifier(PulseWhile(active: recent))
                .help(recent ? "agent watching — read the screen recently"
                             : "agent idle — hasn't read the screen recently")
        }
    }
}

/// Soft opacity pulse while `active` (the design's 1.6s ease pulse).
private struct PulseWhile: ViewModifier {
    let active: Bool
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.25 : 1)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { if active { dim = true } }
            .onChange(of: active) { _, now in dim = now }
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
