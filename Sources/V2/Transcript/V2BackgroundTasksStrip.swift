// Running-tasks strip (#69) — implements the strip from
// "Background tasks.dc.html". Renders nothing when session.backgroundTasks
// is empty. Caps at 3 rows + a folded "+N more" summary; running tasks
// sort first (oldest first), then finished ones; a finished row lingers
// ~30s (matching the design's real-ship timing — the artifact's own demo
// speeds this up for visibility, this doesn't) then drops out.

import SwiftUI
import Inject

struct V2BackgroundTasksStrip: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession
    @State private var peeking: V2BackgroundTask?
    /// task id -> (last tail line seen, when it last changed). Local to the
    /// strip's lifetime — a fresh session/tab naturally starts clean.
    @State private var tailTracking: [String: (line: String, changedAt: Date)] = [:]

    /// No new output for this long ⇒ shown as hung. Real-world threshold,
    /// not the demo artifact's compressed one — long enough that a normal
    /// quiet moment (e.g. a compiler pass) never falsely reads as stalled.
    private static let hungThreshold: TimeInterval = 45
    private static let lingerAfterFinish: TimeInterval = 30
    private static let maxRows = 3

    var body: some View {
        if !visibleTasks.isEmpty {
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
            .sheet(item: $peeking) { task in
                V2BackgroundTaskPeekSheet(task: task)
            }
        }
    }

    // MARK: - Rows

    private enum Row {
        case task(V2BackgroundTask)
        case summary(running: Int, done: Int, failed: Int)
    }

    private func cappedRows(at now: Date) -> [Row] {
        let visible = visibleTasks
        let capped = visible.prefix(Self.maxRows).map(Row.task)
        let overflow = visible.dropFirst(Self.maxRows)
        guard !overflow.isEmpty else { return capped }
        let running = overflow.filter { $0.state == .running }.count
        let done = overflow.filter { if case .completed = $0.state { return true }; return false }.count
        let failed = overflow.count - running - done
        return capped + [.summary(running: running, done: done, failed: failed)]
    }

    /// Running tasks first (oldest first, so the longest-waiting is most
    /// visible), then finished ones still within their linger window.
    private var visibleTasks: [V2BackgroundTask] {
        let now = Date()
        return session.backgroundTasks
            .filter { task in
                if task.state == .running { return true }
                guard let finishedAt = task.finishedAt else { return true }
                return now.timeIntervalSince(finishedAt) < Self.lingerAfterFinish
            }
            .sorted { a, b in
                let ra = a.state == .running, rb = b.state == .running
                if ra != rb { return ra }
                return a.startedAt < b.startedAt
            }
    }

    @ViewBuilder
    private func rowView(_ row: Row, now: Date) -> some View {
        switch row {
        case .task(let task):
            taskRow(task, now: now)
        case .summary(let running, let done, let failed):
            let parts = [
                running > 0 ? "\(running) running" : nil,
                done > 0 ? "\(done) done" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            Text("+\(running + done + failed) more — \(parts)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
        }
    }

    private func taskRow(_ task: V2BackgroundTask, now: Date) -> some View {
        let running = task.state == .running
        let tail = updatedTail(for: task, now: now)
        let hung = running && now.timeIntervalSince(tail.changedAt) >= Self.hungThreshold
        let fading = !running && (task.finishedAt.map { now.timeIntervalSince($0) >= Self.lingerAfterFinish - 5 } ?? false)

        return Button { peeking = task } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(dotColor(task, hung: hung))
                        .frame(width: 7, height: 7)
                        .opacity(hung ? 0.55 : 1)
                    if running && !hung {
                        V2RadarRingPublic(color: v2.ink)
                    }
                }
                .frame(width: 14, height: 9)

                V2CommandChip(task.command.isEmpty ? "task" : task.command)

                Text(elapsedText(task, now: now))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(width: 44, alignment: .leading)

                Text(hung ? "last output \(Self.agoText(now.timeIntervalSince(tail.changedAt))) ago" : "› \(tail.line)")
                    .font(.system(size: 11, design: .monospaced))
                    .italic(hung)
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !running {
                    HStack(spacing: 4) {
                        Text(valenceGlyph(task)).foregroundColor(valenceColor(task))
                        Text(Self.durationText(task)).foregroundColor(v2.faint)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card)
            .contentShape(Rectangle())
            .opacity(fading ? 0.3 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tail tracking

    /// Reads the task's current tail line and updates the local "last
    /// changed" clock only when it actually differs — this is what makes
    /// hung-detection honest (a line repeating because nothing new arrived
    /// must NOT reset the clock).
    private func updatedTail(for task: V2BackgroundTask, now: Date) -> (line: String, changedAt: Date) {
        guard task.state == .running, let path = task.outputPath else {
            return tailTracking[task.id] ?? ("", task.startedAt)
        }
        let line = V2BackgroundTaskTail.lastLine(path: path) ?? ""
        let prior = tailTracking[task.id]
        if prior?.line != line {
            let entry = (line, now)
            tailTracking[task.id] = entry
            return entry
        }
        return prior ?? (line, task.startedAt)
    }

    // MARK: - Formatting

    private func dotColor(_ task: V2BackgroundTask, hung: Bool) -> Color {
        switch task.state {
        case .running: return v2.ink
        case .completed: return v2.add
        case .failed, .orphaned: return v2.del
        }
    }
    private func valenceGlyph(_ task: V2BackgroundTask) -> String {
        if case .completed = task.state { return "✓" }
        return "✗"
    }
    private func valenceColor(_ task: V2BackgroundTask) -> Color {
        if case .completed = task.state { return v2.add }
        return v2.del
    }
    private func elapsedText(_ task: V2BackgroundTask, now: Date) -> String {
        let end = task.finishedAt ?? now
        return Self.mmss(end.timeIntervalSince(task.startedAt))
    }
    private static func durationText(_ task: V2BackgroundTask) -> String {
        guard let finishedAt = task.finishedAt else { return "" }
        return mmss(finishedAt.timeIntervalSince(task.startedAt))
    }
    private static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    static func agoText(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}

/// Same visual as the tab strip's radar ring — duplicated locally (private
/// there) rather than exported, since the two call sites have unrelated
/// lifetimes; small enough that sharing isn't worth the coupling.
private struct V2RadarRingPublic: View {
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
