// Sheet to configure a new loop on the active tab.
// Captures goal + verifier prompt + turn budget, then hands a freshly-built
// LoopOrchestrator back to the caller via onStart.

import SwiftUI
import Inject

struct V2NewLoopSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    let cwd: URL
    let doer: StreamSession
    let claudeURL: URL
    let onStart: (LoopOrchestrator) -> Void
    let onCancel: () -> Void

    @State private var goal: String = ""
    @State private var verifierPrompt: String = LoopConfig.testsPassPreset.verifierPrompt
    @State private var maxTurns: Int = LoopConfig.testsPassPreset.maxTurns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New loop")
                    .font(.system(size: 18, weight: .medium))
                    .kerning(-0.25)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(v2.mute)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(v2.line).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field(
                        label: "GOAL",
                        hint: "What should the agent achieve? The doer will work toward this until the verifier passes."
                    ) {
                        TextEditor(text: $goal)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .scrollContentBackground(.hidden)
                            .background(v2.card)
                            .frame(minHeight: 96)
                            .padding(8)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }

                    field(
                        label: "VERIFIER PROMPT",
                        hint: "Sent to a one-shot `claude -p` after each doer turn, along with the doer's output. Must say PASS or FAIL: <reason> on the first line."
                    ) {
                        TextEditor(text: $verifierPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .scrollContentBackground(.hidden)
                            .background(v2.card)
                            .frame(minHeight: 110)
                            .padding(8)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }

                    field(
                        label: "TURN BUDGET",
                        hint: "Maximum doer-verifier round trips before the loop gives up."
                    ) {
                        HStack(spacing: 12) {
                            Stepper(value: $maxTurns, in: 1...100) {
                                Text("\(maxTurns) turns")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(v2.ink)
                            }
                            .labelsHidden()
                            Text("\(maxTurns) turns")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(v2.ink)
                            Spacer()
                        }
                    }

                    Text("Spawning: doer runs in this tab's existing chat session at \(cwd.path). Verifier is a separate one-shot `claude -p` invocation per cycle — no second persistent session.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(10.5 * 0.5)
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
            }

            HStack(spacing: 10) {
                Spacer()
                Button { onCancel() } label: {
                    Text("Cancel")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button { startLoop() } label: {
                    Text("Start loop")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(canStart ? v2.paper : v2.faint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(canStart ? v2.ink : v2.line2)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(v2.line).frame(height: 1)
            }
        }
        .frame(width: 600, height: 600)
        .background(v2.paper)
        .environment(\.v2, v2)
        .enableInjection()
    }

    private var canStart: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !verifierPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && maxTurns >= 1
    }

    private func field<Content: View>(label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            content()
            Text(hint)
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
    }

    private func startLoop() {
        let config = LoopConfig(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            verifierPrompt: verifierPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            maxTurns: maxTurns
        )
        let loop = LoopOrchestrator(
            config: config,
            doer: doer,
            cwd: cwd,
            claudeURL: claudeURL
        )
        onStart(loop)
    }
}
