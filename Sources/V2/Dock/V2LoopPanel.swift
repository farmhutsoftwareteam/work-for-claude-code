// Loop panel — header + goal card + verifier/budget grid + the loop diagram +
// turns log + pause/stop footer. Mock data; engine wiring lands in Phase 5 (#24).

import SwiftUI
import Inject

struct V2LoopPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    goalSection
                    metaGrid
                    loopDiagramSection
                    turnsSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text("Loop runner")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            HStack(spacing: 6) {
                V2PulseDot(size: 7, color: v2.ink)
                Text("running")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("GOAL")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            Text("all tests in tests/unit pass · no files outside src/ · lint clean")
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(12 * 0.6)
                .foregroundColor(v2.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .padding(.bottom, 18)
    }

    private var metaGrid: some View {
        HStack(spacing: 10) {
            metaCell(label: "VERIFIER", value: "haiku")
            metaCell(label: "BUDGET", value: "4 / 25 turns")
        }
        .padding(.bottom, 20)
    }

    private func metaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(0.76)
                .foregroundColor(v2.faint)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(v2.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
    }

    private var loopDiagramSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THE LOOP")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)

            VStack(spacing: 0) {
                loopStep("goal", subtitle: "define done")
                arrow
                loopStep("work", subtitle: "doer · 1 turn")
                arrow
                loopStep("check", subtitle: "verifier")
                failArrow
                Text("↓ pass")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.vertical, 2)
                doneStep
            }
        }
        .padding(.bottom, 22)
    }

    private func loopStep(_ label: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            V2PulseDot(size: 8, color: v2.ink)
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle).foregroundColor(v2.faint)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var doneStep: some View {
        HStack(spacing: 11) {
            V2PulseDot(size: 8, color: v2.paper)
            Text("done").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            Text("✓ verified").font(.system(size: 12, design: .monospaced))
        }
        .foregroundColor(v2.paper)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(v2.ink)
        .overlay(Rectangle().stroke(v2.ink, lineWidth: 2))
    }

    private var arrow: some View {
        Text("↓")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(v2.faint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private var failArrow: some View {
        HStack(spacing: 8) {
            Rectangle().fill(v2.line2).frame(height: 1)
            Text("fail ↻ within budget")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
            Rectangle().fill(v2.line2).frame(height: 1)
        }
        .padding(.vertical, 6)
    }

    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TURNS")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
                .padding(.bottom, 10)

            ForEach(Array(V2Mock.loopTurns.enumerated()), id: \.element.id) { idx, turn in
                turnRow(turn, isLast: idx == V2Mock.loopTurns.count - 1)
            }
        }
    }

    private func turnRow(_ turn: V2LoopTurn, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Text(turn.number)
                .foregroundColor(turn.state == .running ? v2.ink : v2.faint)
            Text(turn.title)
                .foregroundColor(turn.state == .running ? v2.ink : v2.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch turn.state {
            case .fail:
                Text("✗ fail").foregroundColor(v2.mute)
            case .pass:
                Text("✓ pass").foregroundColor(v2.add)
            case .running:
                HStack(spacing: 5) {
                    V2PulseDot(size: 6, color: v2.ink)
                    Text("running")
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(v2.line).frame(height: 1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { } label: {
                Text("pause")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button { } label: {
                Text("stop loop")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(v2.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }
}
