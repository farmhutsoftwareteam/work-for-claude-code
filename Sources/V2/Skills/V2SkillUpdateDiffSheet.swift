// Update-available diff (#65) — shown when a personal skill Atelier cloned
// from a plugin has drifted from its current upstream content. Never
// auto-applies: the acceptance criterion is explicit confirmation before a
// locally-edited copy can be overwritten.

import SwiftUI
import Inject

struct V2SkillUpdateDiffSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss

    let skill: ClaudeSkill
    let newContent: String
    var onApplied: () -> Void

    @State private var currentContent: String = ""
    /// Surfaces a failed `applyUpdate` — was `try?`, which dismissed and
    /// reported success even if the write actually failed (bug-hunt
    /// #12/M33). Shown in place of the footer's normal caption below.
    @State private var applyError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                column(title: "yours (installed)", content: currentContent)
                Rectangle().fill(v2.line).frame(width: 1)
                column(title: "upstream (current)", content: newContent)
            }
            footer
        }
        .frame(width: 820, height: 560)
        .background(v2.paper2)
        .task {
            currentContent = (try? String(
                contentsOf: skill.path.appendingPathComponent("SKILL.md"), encoding: .utf8
            )) ?? ""
        }
        .enableInjection()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Update available — \(skill.name)")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func column(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            ScrollView {
                Text(content)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .background(v2.card)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(applyError ?? "Your local edits (if any) are only lost if you choose “take upstream.”")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(applyError != nil ? v2.del : v2.faint)
            Spacer()
            Button("keep mine") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            Button("take upstream") {
                do {
                    try SkillOperations.applyUpdate(skill, newContent: newContent)
                    onApplied()
                    dismiss()
                } catch {
                    applyError = error.localizedDescription
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(v2.paper)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(v2.ink)
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }
}
