// Live subagent-delegation strip — same pattern as V2BackgroundTasksStrip/
// V2MonitorTasksStrip (scoped publisher subscription, cap + fold, linger
// after finish), for Task/Agent delegations. Background bash tasks and
// Monitor watches both got a persistent, always-visible strip that survives
// scrolling; subagent delegations never did — a running one only ever
// showed as an inline card at the exact point it was spawned, so once
// enough had streamed past to scroll it out of view, there was no other
// way to check on it. Reported live, with two agents actually running:
// "where will we ever find those agents again? ... our whole agents thing
// is so so broken" (2026-07-15) — compounded by the dock's "Agents" panel
// being an entirely different feature (V2AgentsPanel: static *.md agent-
// type definitions on disk, not live running instances at all).
//
// Reuses V2DelegationCard directly as the row — same live tail, same peek
// sheet — rather than re-deriving that logic; the strip's whole job is
// just "keep it visible after the inline card has scrolled past."

import SwiftUI
import Inject

struct V2SubagentRunsStrip: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    /// Not @ObservedObject — same reasoning as the other strips: this
    /// mounts beside the transcript and only cares about `subagentRuns`,
    /// so it tracks just that one publisher instead of the session's
    /// blanket objectWillChange (PERFORMANCE.md §2).
    let session: StreamSession
    @State private var runs: [V2SubagentRun] = []

    private static let lingerAfterFinish: TimeInterval = 30
    private static let maxRows = 3

    var body: some View {
        Group {
            if !visibleRuns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(cappedRows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
            }
        }
        // Keyed on instanceId, not ObjectIdentifier(session) — same
        // malloc-reuse pitfall documented on the sibling strips.
        .task(id: session.instanceId) {
            runs = session.subagentRuns
            for await r in session.$subagentRuns.values {
                runs = r
            }
        }
        .enableInjection()
    }

    // MARK: - Rows

    private enum Row {
        case run(V2SubagentRun)
        case summary(running: Int, done: Int, failed: Int)
    }

    private var visibleRuns: [V2SubagentRun] {
        let now = Date()
        return runs
            .filter { run in
                if run.state == .running { return true }
                guard let finishedAt = run.finishedAt else { return true }
                return now.timeIntervalSince(finishedAt) < Self.lingerAfterFinish
            }
            .sorted { a, b in
                let ra = a.state == .running, rb = b.state == .running
                if ra != rb { return ra }
                return a.startedAt < b.startedAt
            }
    }

    private var cappedRows: [Row] {
        let visible = visibleRuns
        let capped = visible.prefix(Self.maxRows).map(Row.run)
        let overflow = visible.dropFirst(Self.maxRows)
        guard !overflow.isEmpty else { return Array(capped) }
        let running = overflow.filter { $0.state == .running }.count
        let done = overflow.filter { $0.state == .completed }.count
        let failed = overflow.count - running - done
        return capped + [.summary(running: running, done: done, failed: failed)]
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .run(let run):
            V2DelegationCard(
                run: run,
                toolUseId: run.toolUseId,
                fallbackDescription: run.description,
                fallbackAgentType: run.agentType,
                sessionDir: session.sessionDir
            )
        case .summary(let running, let done, let failed):
            let parts = [
                running > 0 ? "\(running) running" : nil,
                done > 0 ? "\(done) done" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            Text("+\(running + done + failed) more agent\(running + done + failed == 1 ? "" : "s") — \(parts)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
    }
}
