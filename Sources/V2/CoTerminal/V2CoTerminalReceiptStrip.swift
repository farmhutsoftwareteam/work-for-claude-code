// Co-driven terminal receipt strip — the transcript-side half of the
// floating-window redesign (see V2FloatingTerminalWindow). Mirrors
// V2BackgroundTasksStrip's exact contract (capped rows + folded summary,
// running-first sort, 30s linger after finish) so a co-driven shell gets the
// SAME lightweight "it happened, here's where" receipt as a background task
// — instead of the old full terminal pane inline. Tapping a row never opens
// anything here; it raises the floating window and selects that shell,
// exactly like the design's receipt row wiring its button straight to
// raiseWin.

import SwiftUI
import Inject

struct V2CoTerminalReceiptStrip: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    // CoTerminalManager's own state changes are inherently low-frequency
    // (process start/exit, secure toggles) — unlike StreamSession, observing
    // it directly costs nothing extra; CoTerminalStrip did the same before
    // this file replaced it.
    @ObservedObject private var manager = CoTerminalManager.shared
    let session: StreamSession

    private static let lingerAfterFinish: TimeInterval = 30
    private static let maxRows = 3

    var body: some View {
        Group {
            if !visibleTerminals.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 1) {
                        ForEach(Array(cappedRows(at: ctx.date).enumerated()), id: \.offset) { _, row in
                            rowView(row, now: ctx.date)
                        }
                    }
                    .background(v2.line)
                    .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
            }
        }
        .enableInjection()
    }

    // MARK: - Rows

    private enum Row {
        case terminal(CoTerminal)
        case summary(running: Int, needsInput: Int, done: Int, failed: Int)
    }

    private var visibleTerminals: [CoTerminal] {
        let now = Date()
        return manager.terminals(for: session)
            .filter { t in
                if t.status == .running || t.status == .needsInput { return true }
                guard let endedAt = t.endedAt else { return true }
                return now.timeIntervalSince(endedAt) < Self.lingerAfterFinish
            }
            .sorted { a, b in
                let liveA = a.status == .running || a.status == .needsInput
                let liveB = b.status == .running || b.status == .needsInput
                if liveA != liveB { return liveA }
                return a.startedAt < b.startedAt
            }
    }

    private func cappedRows(at now: Date) -> [Row] {
        let visible = visibleTerminals
        let capped = visible.prefix(Self.maxRows).map(Row.terminal)
        let overflow = visible.dropFirst(Self.maxRows)
        guard !overflow.isEmpty else { return Array(capped) }
        let running = overflow.filter { $0.status == .running }.count
        let needsInput = overflow.filter { $0.status == .needsInput }.count
        let done = overflow.filter { $0.status == .done }.count
        let failed = overflow.count - running - needsInput - done
        return capped + [.summary(running: running, needsInput: needsInput, done: done, failed: failed)]
    }

    @ViewBuilder
    private func rowView(_ row: Row, now: Date) -> some View {
        switch row {
        case .terminal(let t):
            terminalRow(t, now: now)
        case .summary(let running, let needsInput, let done, let failed):
            let parts = [
                needsInput > 0 ? "\(needsInput) need you" : nil,
                running > 0 ? "\(running) running" : nil,
                done > 0 ? "\(done) done" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            Text("+\(running + needsInput + done + failed) more shells — \(parts)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(needsInput > 0 ? v2.del : v2.faint)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
        }
    }

    private func terminalRow(_ t: CoTerminal, now: Date) -> some View {
        let fading = t.status != .running && t.status != .needsInput
            && (t.endedAt.map { now.timeIntervalSince($0) >= Self.lingerAfterFinish - 5 } ?? false)

        return Button { act(t) } label: {
            HStack(spacing: 10) {
                statusDot(t)
                V2CommandChip(t.command.isEmpty ? "shell" : t.command)
                Text(elapsedText(t, now: now))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(width: 44, alignment: .leading)
                Text(rowDetail(t))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(t.status == .needsInput ? v2.del : v2.faint)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(actionLabel(t))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(t.status == .needsInput || isError(t) ? v2.del : v2.mute)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Rectangle().stroke(actionBorderColor(t), lineWidth: 1))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card)
            .contentShape(Rectangle())
            .opacity(fading ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .help(t.status == .needsInput ? "This shell needs you — click to open it" : "Open in the shell window")
    }

    /// Bug-hunt: the row's action button used to always just raise the
    /// window, regardless of its own label — "retry" on a failed shell
    /// opened the window onto the SAME stale failure instead of actually
    /// retrying anything, silently promising an action it didn't take.
    /// "answer"/"open"/"log" are honestly satisfied by raising (you answer/
    /// read/watch IN the window) — only "retry" needed a real action behind it.
    private func act(_ t: CoTerminal) {
        if isError(t) {
            let fresh = manager.run(command: t.command, cwd: t.cwd, scope: ObjectIdentifier(session))
            raise(fresh)
        } else {
            raise(t)
        }
    }

    private func raise(_ t: CoTerminal) {
        manager.select(t, for: session)
        manager.setWindowOpen(true, for: session)
    }

    // MARK: - Formatting

    @ViewBuilder
    private func statusDot(_ t: CoTerminal) -> some View {
        ZStack {
            Circle().fill(dotColor(t)).frame(width: 7, height: 7)
            if t.status == .running {
                V2ReceiptRadarRing(color: v2.ink)
            }
        }
        .frame(width: 14, height: 9)
    }

    private func dotColor(_ t: CoTerminal) -> Color {
        switch t.status {
        case .running:    return v2.ink
        case .needsInput: return v2.del
        case .done:       return v2.add
        case .error:      return v2.del
        }
    }

    private func rowDetail(_ t: CoTerminal) -> String {
        switch t.status {
        case .needsInput: return "waiting on you — click to answer"
        case .error(let code): return "exit \(code) · \(t.lastOutputLine())"
        case .done: return "exit 0 · done"
        case .running: return "› \(t.lastOutputLine())"
        }
    }

    private func actionLabel(_ t: CoTerminal) -> String {
        switch t.status {
        case .needsInput: return "answer"
        case .error: return "retry"
        case .done: return "log"
        case .running: return "open"
        }
    }

    private func actionBorderColor(_ t: CoTerminal) -> Color {
        (t.status == .needsInput || isError(t)) ? v2.del : v2.line2
    }

    private func isError(_ t: CoTerminal) -> Bool {
        if case .error = t.status { return true }
        return false
    }

    private func elapsedText(_ t: CoTerminal, now: Date) -> String {
        let end = t.endedAt ?? now
        return Self.mmss(end.timeIntervalSince(t.startedAt))
    }

    private static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Same visual as the background-tasks strip's radar ring — small enough
/// that duplicating (rather than exporting the other strip's private type)
/// is the right call; the two call sites have unrelated lifetimes.
private struct V2ReceiptRadarRing: View {
    let color: Color
    @State private var animate = false
    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1)
            .frame(width: 7, height: 7)
            .scaleEffect(animate ? 2.6 : 1)
            .opacity(animate ? 0 : 0.55)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}
