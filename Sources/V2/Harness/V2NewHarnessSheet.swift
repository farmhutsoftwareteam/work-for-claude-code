// Sheet to configure a new HarnessOrchestrator on the active tab.

import SwiftUI
import Inject

struct V2NewHarnessSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    let cwd: URL
    let claudeURL: URL
    let onStart: (HarnessOrchestrator) -> Void
    let onCancel: () -> Void

    @State private var goal: String = ""
    @State private var maxIterations: Int = HarnessConfig.defaults.maxIterations
    @State private var skipPermissions: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New harness")
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
                        hint: "Be specific. The plan phase will turn this into a Markdown plan; work phases execute it iteratively."
                    ) {
                        TextEditor(text: $goal)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .scrollContentBackground(.hidden)
                            .background(v2.card)
                            .frame(minHeight: 120)
                            .padding(8)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }

                    field(
                        label: "ITERATION BUDGET",
                        hint: "Each iteration is one work-then-review cycle in a fresh claude -p process."
                    ) {
                        HStack(spacing: 12) {
                            Stepper(value: $maxIterations, in: 1...20) {
                                EmptyView()
                            }
                            .labelsHidden()
                            Text("\(maxIterations) iterations")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(v2.ink)
                            Spacer()
                        }
                    }

                    field(
                        label: "PERMISSIONS",
                        hint: "Skip permission prompts during the work phase — the agent will edit files / run commands without asking. Use this only for projects you trust and intend to babysit."
                    ) {
                        Toggle(isOn: $skipPermissions) {
                            HStack(spacing: 7) {
                                if skipPermissions {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(v2.del)
                                        .font(.system(size: 11))
                                }
                                Text(skipPermissions ? "skip-permissions ON" : "skip-permissions off")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(skipPermissions ? v2.del : v2.ink)
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(.vertical, 4)
                    }

                    Text("Storage: ~/Library/Application Support/com.munyamakosa.work/harnesses/<id>/")
                        .font(.system(size: 10.5, design: .monospaced))
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

                Button { startHarness() } label: {
                    Text("Start harness")
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
        .frame(width: 600, height: 540)
        .background(v2.paper)
        .environment(\.v2, v2)
        .enableInjection()
    }

    private var canStart: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && maxIterations >= 1
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

    private func startHarness() {
        let config = HarnessConfig(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            maxIterations: maxIterations,
            skipPermissions: skipPermissions
        )
        let harness = HarnessOrchestrator(
            config: config,
            cwd: cwd,
            claudeURL: claudeURL
        )
        onStart(harness)
    }
}
