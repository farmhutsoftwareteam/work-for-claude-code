// Output peek (#70) — live-tailing view of a background task's output file.
// Answers "is it hung or just quiet?" (the epic's adversarial case): while
// running, content follows the bottom as the task prints; if nothing new
// has arrived in a while, the header says exactly how long, instead of
// leaving a stalled task looking identical to a healthy one.

import SwiftUI
import Inject

struct V2BackgroundTaskPeekSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss

    let task: V2BackgroundTask

    @State private var lines: [String] = []
    @State private var lastChangedAt = Date()
    private static let hungThreshold: TimeInterval = 45

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                header(now: ctx.date)
                body_(now: ctx.date)
                footer
            }
            .frame(width: 780, height: 520)
            .background(v2.paper2)
            .task(id: ctx.date) { refreshIfRunning() }
        }
        .task { refresh() }
        .onExitCommand { dismiss() }
        .enableInjection()
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        let running = task.state == .running
        let hung = running && now.timeIntervalSince(lastChangedAt) >= Self.hungThreshold
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                V2CommandChip(task.command.isEmpty ? "task" : task.command)
                Text(metaText(now: now))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            if running && !hung {
                HStack(spacing: 6) {
                    V2PulseDot(size: 6, color: v2.ink)
                    Text("following")
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.mute)
            } else if hung {
                Text("last output \(V2BackgroundTasksStrip.agoText(now.timeIntervalSince(lastChangedAt))) ago")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func metaText(now: Date) -> String {
        switch task.state {
        case .running:
            return "running · \(V2BackgroundTasksStrip.agoText(now.timeIntervalSince(task.startedAt))) elapsed"
        case .completed(let code):
            return "finished · exit \(code ?? 0) · \(finishedDuration()) total"
        case .failed(let code):
            return "failed · exit \(code ?? 1) · \(finishedDuration()) total"
        case .orphaned:
            return "session ended while this was running — outcome unknown"
        }
    }

    private func finishedDuration() -> String {
        guard let f = task.finishedAt else { return "—" }
        let s = max(0, Int(f.timeIntervalSince(task.startedAt)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: - Body

    private func body_(now: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Color.clear.frame(height: 1).id("bg-peek-bottom")
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color.black.opacity(0.03))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(task.outputPath ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("esc to close")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Polling

    private func refreshIfRunning() {
        guard task.state == .running else { return }
        refresh()
    }

    private func refresh() {
        guard let path = task.outputPath else { return }
        let fresh = V2BackgroundTaskTail.fullTail(path: path)
        if fresh != lines {
            lines = fresh
            lastChangedAt = Date()
        }
    }
}
