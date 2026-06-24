// Agents panel — header + delegation caption + agent cards with isolated badge
// + bottom trust caption. Mock data; engine wiring lands in Phase 5 (#26).

import SwiftUI
import Inject

struct V2AgentsPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("main session → delegates to ↓")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.bottom, 12)

                    VStack(spacing: 10) {
                        ForEach(V2Mock.agents) { agent in
                            agentCard(agent)
                        }
                    }

                    Text("Each runs in its own context. Only the summary returns to your window — the exploration noise never lands here.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(10.5 * 0.6)
                        .foregroundColor(v2.faint)
                        .padding(.top, 12)
                        .padding(.top, 4)
                        .overlay(alignment: .top) {
                            Rectangle().fill(v2.line).frame(height: 1)
                        }
                        .padding(.top, 12)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text("Agents")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            Button { } label: {
                Text("+ new")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private func agentCard(_ agent: V2Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.name)
                    .font(.system(size: 14, weight: .medium))
                    .kerning(-0.14)
                Spacer()
                Text("isolated")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            Text(agent.summary)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(11 * 0.6)
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}
