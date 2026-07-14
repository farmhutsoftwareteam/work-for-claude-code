// Live Monitor-watch strip — mirrors V2BackgroundTasksStrip's pattern
// (same reasoning: renders nothing when empty, scoped subscription instead
// of observing the whole session) but for Monitor's structured task_started/
// task_updated/task_notification events instead of Bash's text-parsed ones.
// See V2MonitorTask.swift for the wire format.

import SwiftUI
import Inject

struct V2MonitorTasksStrip: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    /// Not @ObservedObject — same reasoning as V2BackgroundTasksStrip: this
    /// strip mounts beside the transcript and only cares about
    /// `monitorTasks`, so it tracks just that one publisher instead of the
    /// session's blanket objectWillChange (PERFORMANCE.md §2).
    let session: StreamSession
    @State private var monitorTasks: [V2MonitorTask] = []

    private static let lingerAfterFinish: TimeInterval = 30
    private static let maxRows = 3

    var body: some View {
        Group {
            if !visibleTasks.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 1) {
                        ForEach(Array(cappedRows(at: ctx.date).enumerated()), id: \.offset) { _, row in
                            rowView(row)
                        }
                    }
                    .background(v2.line)
                    .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
            }
        }
        // Keyed on instanceId, not ObjectIdentifier(session) — same
        // malloc-reuse pitfall documented on V2BackgroundTasksStrip.
        .task(id: session.instanceId) {
            monitorTasks = session.monitorTasks
            for await tasks in session.$monitorTasks.values {
                monitorTasks = tasks
            }
        }
        .enableInjection()
    }

    // MARK: - Rows

    private enum Row {
        case task(V2MonitorTask)
        case summary(watching: Int, done: Int, failed: Int)
    }

    private func cappedRows(at now: Date) -> [Row] {
        let visible = visibleTasks
        let capped = visible.prefix(Self.maxRows).map(Row.task)
        let overflow = visible.dropFirst(Self.maxRows)
        guard !overflow.isEmpty else { return capped }
        let watching = overflow.filter { $0.state == .watching }.count
        let done = overflow.filter { $0.state == .completed }.count
        let failed = overflow.count - watching - done
        return capped + [.summary(watching: watching, done: done, failed: failed)]
    }

    /// Watching tasks first (oldest first), then finished ones still within
    /// their linger window — same shape as V2BackgroundTasksStrip.
    private var visibleTasks: [V2MonitorTask] {
        let now = Date()
        return monitorTasks
            .filter { task in
                if task.state == .watching { return true }
                guard let finishedAt = task.finishedAt else { return true }
                return now.timeIntervalSince(finishedAt) < Self.lingerAfterFinish
            }
            .sorted { a, b in
                let wa = a.state == .watching, wb = b.state == .watching
                if wa != wb { return wa }
                return a.startedAt < b.startedAt
            }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .task(let task):
            taskRow(task)
        case .summary(let watching, let done, let failed):
            let parts = [
                watching > 0 ? "\(watching) watching" : nil,
                done > 0 ? "\(done) done" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            Text("+\(watching + done + failed) more — \(parts)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
        }
    }

    private func taskRow(_ task: V2MonitorTask) -> some View {
        let watching = task.state == .watching
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(dotColor(task))
                    .frame(width: 7, height: 7)
                if watching {
                    V2MonitorRadarRing(color: v2.ink)
                }
            }
            .frame(width: 14, height: 9)

            V2CommandChip(task.command ?? task.description)

            Text(elapsedText(task))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .frame(width: 44, alignment: .leading)

            Text(rowStatusText(task))
                .font(.system(size: 11, design: .monospaced))
                .italic(watching && task.lastEvent == nil)
                .foregroundColor(v2.faint)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !watching {
                HStack(spacing: 4) {
                    Text(valenceGlyph(task)).foregroundColor(valenceColor(task))
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.card)
    }

    // MARK: - Formatting

    private func rowStatusText(_ task: V2MonitorTask) -> String {
        if let lastEvent = task.lastEvent, !lastEvent.isEmpty { return "› \(lastEvent)" }
        return task.state == .watching ? "watching…" : task.description
    }
    private func dotColor(_ task: V2MonitorTask) -> Color {
        switch task.state {
        case .watching: return v2.ink
        case .completed: return v2.add
        case .failed, .orphaned: return v2.del
        }
    }
    private func valenceGlyph(_ task: V2MonitorTask) -> String {
        task.state == .completed ? "✓" : "✗"
    }
    private func valenceColor(_ task: V2MonitorTask) -> Color {
        task.state == .completed ? v2.add : v2.del
    }
    private func elapsedText(_ task: V2MonitorTask) -> String {
        let end = task.finishedAt ?? Date()
        let s = max(0, Int(end.timeIntervalSince(task.startedAt)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Local copy of the same radar-ring pulse V2BackgroundTasksStrip uses —
/// duplicated for the same reason its own copy is private rather than
/// exported: two unrelated-lifetime call sites, not worth the coupling.
private struct V2MonitorRadarRing: View {
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
