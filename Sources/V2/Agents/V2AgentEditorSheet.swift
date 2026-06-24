// Sheet to create or edit a Claude Code subagent (.md file with YAML
// frontmatter). Writes go through AgentConfigWriter atomically.

import SwiftUI
import Inject

struct V2AgentEditorSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    let mode: Mode
    let scope: AgentConfigWriter.Scope
    let onSaved: (URL) -> Void
    let onCancel: () -> Void

    enum Mode {
        case new
        case edit(V2Agent)
    }

    @State private var draft: AgentConfigWriter.Draft = .empty
    @State private var toolsCSV: String = ""
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true } else { return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let msg = errorMessage {
                        errorBanner(msg)
                    }
                    field(label: "SLUG", hint: "Filename stem. Lowercase, dashes only. The binary uses this as the agent's identifier.") {
                        TextField("reviewer", text: $draft.slug)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                            .disabled(isEditing)
                    }
                    field(label: "NAME", hint: "Human-readable label.") {
                        TextField("Reviewer", text: $draft.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    field(label: "DESCRIPTION", hint: "One-line summary.") {
                        TextField("Catches standard violations", text: $draft.description)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    field(label: "MODEL", hint: "opus / sonnet / haiku, or leave blank for the session default.") {
                        TextField("(default)", text: $draft.model)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    field(label: "TOOLS", hint: "Comma-separated. E.g. Read, Grep, Bash") {
                        TextField("Read, Grep, Bash", text: $toolsCSV)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    field(label: "COLOR", hint: "Optional. red / green / yellow / blue / purple / orange.") {
                        TextField("(none)", text: $draft.color)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    field(label: "SYSTEM PROMPT", hint: "Markdown body. This is what the agent reads when invoked.") {
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .scrollContentBackground(.hidden)
                            .background(v2.card)
                            .frame(minHeight: 160)
                            .padding(8)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    Text("Path: \(scope.url(forSlug: draft.slug.isEmpty ? "<slug>" : draft.slug).path)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
            }
            footer
        }
        .frame(width: 640, height: 720)
        .background(v2.paper)
        .environment(\.v2, v2)
        .onAppear { seed() }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit agent" : "New agent")
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
    }

    private var footer: some View {
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
            Button { save() } label: {
                Text(isEditing ? "Save" : "Create")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(canSave ? v2.paper : v2.faint)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(canSave ? v2.ink : v2.line2)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(v2.del)
            Text(msg)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.del)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.delBg)
        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
    }

    private var canSave: Bool {
        !draft.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func seed() {
        if case .edit(let agent) = mode {
            draft = AgentConfigWriter.Draft.from(agent: agent)
            toolsCSV = agent.tools.joined(separator: ", ")
        } else {
            draft = .empty
            toolsCSV = ""
        }
    }

    private func save() {
        // Re-parse the comma-separated tools field into draft.tools at save
        // time so the user can type loosely and we'll clean up.
        let tools = toolsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var d = draft
        d.tools = tools

        do {
            let url = try AgentConfigWriter.save(draft: d, to: scope)
            onSaved(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
