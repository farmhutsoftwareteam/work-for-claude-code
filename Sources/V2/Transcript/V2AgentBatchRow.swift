// Collapses a fan-out of sibling sub-agents (a batch) into ONE transcript
// row — a receipt, not a dashboard. The failure mode this fixes: 20 parallel
// Task spawns rendering as 20 stacked V2DelegationCards that push the
// conversation off-screen. Here the whole batch is one row — overall glyph,
// "AGENTS · N", a title, live counts, and a per-agent cell grid whose colours
// ARE the progress. Tapping expands to the individual delegation cards
// (unchanged), so drill-down is one click, not the default.
//
// A batch of one never reaches here (the transcript keeps rendering a lone
// V2DelegationCard for single delegations); this is strictly the ≥2 case.

import SwiftUI
import Inject

struct V2AgentBatchRow: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    let runs: [V2SubagentRun]
    let sessionDir: URL?
    @State private var expanded = false

    private var total: Int { runs.count }
    private var running: Int { runs.filter { $0.state == .running }.count }
    private var done: Int { runs.filter { $0.state == .completed }.count }
    private var failed: Int { runs.filter { $0.state == .failed || $0.state == .orphaned }.count }
    private var live: Bool { running > 0 }

    /// "7 general-purpose agents" when they share a type, else "7 agents".
    private var title: String {
        let types = Set(runs.map { $0.agentType })
        if types.count == 1, let t = types.first, t != "agent", t != "sub-agent", !t.isEmpty {
            return "\(total) \(t) agents"
        }
        return "\(total) agents"
    }

    private var countsText: String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) done") }
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "\(total) agents" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            headerButton
            if expanded {
                ForEach(runs) { run in
                    V2DelegationCard(
                        run: run,
                        toolUseId: run.toolUseId,
                        fallbackDescription: run.description,
                        fallbackAgentType: run.agentType,
                        sessionDir: sessionDir
                    )
                }
            }
        }
        .enableInjection()
    }

    private var headerButton: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 11) {
                    statusGlyph
                    Text("AGENTS · \(total)")
                        .font(.system(size: 10, design: .monospaced)).kerning(0.6)
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Text(title)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(countsText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(failed > 0 ? v2.del : v2.mute)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(v2.faint)
                }
                cellGrid
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(live ? v2.card : v2.paper2)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide agents" : "Show the \(total) agents in this batch")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if live {
            V2PulseDot(size: 8, color: v2.ink)
        } else if failed > 0 {
            Text("✗").font(.system(size: 12, weight: .medium)).foregroundColor(v2.del)
        } else {
            Text("✓").font(.system(size: 12, weight: .medium)).foregroundColor(v2.add)
        }
    }

    /// One cell per agent, coloured by state — the grid IS the progress bar.
    /// Running cells breathe together, driven by a TimelineView that only
    /// exists while something's live, so a settled batch has zero idle redraws.
    @ViewBuilder
    private var cellGrid: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                cells(pulseOn: on)
            }
        } else {
            cells(pulseOn: true)
        }
    }

    private func cells(pulseOn: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(runs) { run in
                Rectangle()
                    .fill(cellColor(run.state))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
                    .opacity(run.state == .running ? (pulseOn ? 1 : 0.45) : 1)
            }
        }
    }

    private func cellColor(_ s: V2SubagentRun.State) -> Color {
        switch s {
        case .completed:          return v2.add
        case .failed, .orphaned:  return v2.del
        case .running:            return v2.ink
        }
    }
}
