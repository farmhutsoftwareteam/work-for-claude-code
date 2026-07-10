// Skill create/edit sheet (#62 + #63) — implements the sheet from
// "Skills management.dc.html": three stages for a new skill (describe →
// generating → review-as-form), one stage (form) for editing an existing
// skill. Every save routes through SkillOperations — no shadow state that
// could drift from the real SKILL.md on disk.

import SwiftUI
import Inject

struct V2SkillEditorSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: V2AppState

    enum Mode {
        case new
        case edit(ClaudeSkill)
    }

    enum Stage: Equatable {
        case prompt, generating, form
    }

    let mode: Mode
    var onSaved: () -> Void

    @State private var stage: Stage
    @State private var isAiGenerated = false
    @State private var aiPromptText = ""
    @State private var generationError: String?
    /// Handle to the in-flight generate() Task so closing the sheet mid-
    /// generation can cancel it instead of leaving it running silently —
    /// Task.sleep inside V2SkillGenerator's poll loop is a cooperative
    /// cancellation point, so this actually propagates into the generator
    /// and trips its `defer { session.stop() }`, not just a local no-op
    /// (bug-hunt #14).
    @State private var generateTask: Task<Void, Never>?

    // Form fields
    @State private var name = ""
    @State private var desc = ""
    @State private var whenToUse = ""
    // nil = "inherit" (no model:/effort: line written — the skill runs under
    // whatever model/effort the session already has, which is the correct
    // default per docs.claude.com/en/docs/skills: "model — Model to use when
    // this skill is active... Accepts... or `inherit` to keep the active
    // model." A concrete value is a genuine but TURN-SCOPED override, not a
    // persistent pin — the session reverts on the next prompt.
    @State private var model: String?
    @State private var effort: String?
    @State private var license = ""
    @State private var argumentHint = ""
    @State private var modelInvocable = true
    @State private var userInvocable = true
    @State private var assetsFolder = false
    @State private var bodyText = "## Steps\n\n1. \n"
    @State private var saveError: String?
    /// SKILL.md's on-disk modification date at the moment THIS sheet loaded
    /// it — passed to `updateSkill` so it can detect a concurrent edit from
    /// another window/sheet and refuse to silently clobber it
    /// (bug-hunt #9/M30). nil for a brand-new skill: nothing to conflict with.
    @State private var loadedModificationDate: Date?
    // Secondary/rarely-touched fields (argument-hint, when-to-use, model,
    // effort, license, invocability) collapse behind a disclosure so the
    // body editor — the actual point of this sheet — isn't the 7th of 8
    // fields you scroll past to reach (Serial Position Effect). Defaults
    // open when editing a skill that already has one of them set, so
    // existing configuration is never hidden (Mental Model law).
    @State private var moreOptionsExpanded: Bool

    init(mode: Mode, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .new:
            _stage = State(initialValue: .prompt)
            _moreOptionsExpanded = State(initialValue: false)
        case .edit(let skill):
            _stage = State(initialValue: .form)
            _name = State(initialValue: skill.name)
            _desc = State(initialValue: skill.skillDescription)
            _whenToUse = State(initialValue: skill.whenToUse ?? "")
            // Load exactly what's on disk — nil stays nil (inherit), never
            // defaulted to a concrete model/effort the skill never asked for.
            _model = State(initialValue: skill.model)
            _effort = State(initialValue: skill.effort)
            _license = State(initialValue: skill.license ?? "")
            _argumentHint = State(initialValue: skill.argumentHint ?? "")
            _modelInvocable = State(initialValue: !skill.disableModelInvocation)
            _userInvocable = State(initialValue: skill.userInvocable)
            let skillMdURL = skill.path.appendingPathComponent("SKILL.md")
            _bodyText = State(initialValue: (try? String(
                contentsOf: skillMdURL, encoding: .utf8
            )).flatMap(Self.extractBody) ?? "")
            _loadedModificationDate = State(initialValue: (try? FileManager.default.attributesOfItem(
                atPath: skillMdURL.path
            ))?[.modificationDate] as? Date)
            _moreOptionsExpanded = State(initialValue: !(skill.whenToUse ?? "").isEmpty
                || skill.model != nil || skill.effort != nil
                || !(skill.license ?? "").isEmpty || !(skill.argumentHint ?? "").isEmpty
                || skill.disableModelInvocation || !skill.userInvocable)
        }
    }

    private var isNew: Bool { if case .new = mode { return true }; return false }
    private var editingSkill: ClaudeSkill? { if case .edit(let s) = mode { return s }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch stage {
            case .prompt:     promptStage
            case .generating: generatingStage
            case .form:       formStage
            }
        }
        .frame(width: 780, height: 660)
        .background(v2.paper2)
        .onDisappear { generateTask?.cancel() }
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(sheetTitle)
                .font(.system(size: 15.5, weight: .medium))
                .kerning(-0.15)
            if stage == .prompt || stage == .generating {
                Text("describe it")
                    .font(.system(size: 9.5, design: .monospaced))
                    .kerning(0.5)
                    .foregroundColor(v2.mute)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
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

    private var sheetTitle: String {
        if stage == .prompt || stage == .generating { return "New skill" }
        return isNew ? "New skill" : "Edit skill — \(name)"
    }

    // MARK: - Stage: prompt

    private var promptStage: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("What should this skill do?")
                        .font(.system(size: 18, weight: .medium))
                        .kerning(-0.15)
                    Text("describe it in plain language — Claude drafts the SKILL.md, you review before it saves")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                TextEditor(text: $aiPromptText)
                    .font(.system(size: 13))
                    .frame(height: 96)
                    .padding(8)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    .scrollContentBackground(.hidden)

                if let generationError {
                    Text(generationError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.del)
                }

                HStack {
                    Button("start from a blank template instead") {
                        isAiGenerated = false
                        stage = .form
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .underline()
                    Spacer()
                    Button("generate →") { generate() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.paper)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(aiPromptText.trimmingCharacters(in: .whitespaces).isEmpty ? v2.mute : v2.ink)
                        .disabled(aiPromptText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: 520)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stage: generating

    private var generatingStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                V2PulseDot(size: 7, color: v2.ink)
                Text("writing SKILL.md from your description…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            Text("this can take a little while — the review step opens automatically")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Stage: form

    private var formStage: some View {
        VStack(spacing: 0) {
            if isAiGenerated {
                HStack(spacing: 10) {
                    Text("drafted by Claude from your description — review before saving, nothing is written yet")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.add)
                    Spacer()
                    Button("regenerate") { stage = .prompt }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .underline()
                        .foregroundColor(v2.ink)
                }
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(v2.addBg)
                .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            }

            VStack(alignment: .leading, spacing: 14) {
                field("name") {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .disabled(!isNew)
                        .padding(8)
                        .background(isNew ? v2.card : v2.paper3)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                field("description") {
                    TextField("", text: $desc)
                        .textFieldStyle(.plain).padding(8)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }

                // The actual point of this sheet — dominant size, second
                // field down, never sharing a scroll gesture with the form
                // around it (see the header comment on moreOptionsExpanded).
                field("SKILL.md body") {
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12.5, design: .monospaced)).padding(8)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        .scrollContentBackground(.hidden)
                }
                .frame(maxHeight: .infinity)

                DisclosureGroup(isExpanded: $moreOptionsExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            field("argument-hint") {
                                TextField("<file> [--fix]", text: $argumentHint)
                                    .textFieldStyle(.plain).padding(8)
                                    .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                            }
                            field("license") {
                                TextField("MIT", text: $license)
                                    .textFieldStyle(.plain).padding(8)
                                    .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                            }
                        }
                        field("when to use") {
                            TextEditor(text: $whenToUse)
                                .font(.system(size: 12.5)).frame(height: 46).padding(6)
                                .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                                .scrollContentBackground(.hidden)
                        }
                        HStack(spacing: 14) {
                            field("model") { segmented(["sonnet", "opus", "haiku"], selection: $model) }
                            field("effort") { segmented(["low", "medium", "high"], selection: $effort) }
                        }
                        HStack(spacing: 24) {
                            toggleRow("model-invocable", isOn: $modelInvocable)
                            toggleRow("user-invocable", isOn: $userInvocable)
                        }
                        if isNew {
                            toggleRow("create a references / scripts / assets folder alongside SKILL.md", isOn: $assetsFolder)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("more options")
                        .font(.system(size: 10.5, design: .monospaced))
                        .kerning(0.5)
                        .foregroundColor(v2.mute)
                }
                .tint(v2.ink)

                if let saveError {
                    Text(saveError).font(.system(size: 11, design: .monospaced)).foregroundColor(v2.del)
                }
            }
            .padding(22)
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                if let editingSkill {
                    Button("delete skill") { delete(editingSkill) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.del)
                }
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                Button(isNew ? "save skill" : "save changes") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(v2.ink)
            }
            .padding(.horizontal, 20).padding(.vertical, 13)
            .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
        }
    }

    // MARK: - Field helpers

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "inherit" (nil) is a real, distinct option here, not a placeholder —
    /// it's the correct default per the docs: no model:/effort: line means
    /// the skill just runs under the session's current model/effort. A
    /// concrete pick IS a real override, but scoped to the turn the skill
    /// runs (see the `model`/`effort` @State doc comment above).
    private func segmented(_ options: [String], selection: Binding<String?>) -> some View {
        HStack(spacing: 1) {
            ForEach(["inherit"] + options, id: \.self) { opt in
                let isInherit = opt == "inherit"
                let isSelected = isInherit ? selection.wrappedValue == nil : selection.wrappedValue == opt
                Button(opt == "medium" ? "med" : opt) { selection.wrappedValue = isInherit ? nil : opt }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? v2.paper : v2.mute)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(isSelected ? v2.ink : v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 9) {
                Capsule()
                    .fill(isOn.wrappedValue ? v2.ink : v2.line2)
                    .frame(width: 30, height: 17)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle().fill(v2.paper).frame(width: 13, height: 13).padding(2)
                    }
                Text(label)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.ink)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func generate() {
        guard let binary = appState.claudeBinary else {
            generationError = "Can't find the claude binary."
            return
        }
        generationError = nil
        stage = .generating
        generateTask = Task {
            do {
                let draft = try await V2SkillGenerator.generate(description: aiPromptText, claudeBinary: binary)
                name = draft.name
                desc = draft.description
                whenToUse = draft.whenToUse ?? ""
                // No forced default — if Claude's draft didn't set a model,
                // that means inherit, and the field stays nil.
                model = draft.model
                bodyText = draft.body
                isAiGenerated = true
                stage = .form
            } catch {
                generationError = error.localizedDescription
                stage = .prompt
            }
        }
    }

    private func save() {
        saveError = nil
        do {
            if let editingSkill {
                try SkillOperations.updateSkill(
                    editingSkill, description: desc, whenToUse: whenToUse, model: model,
                    effort: effort, license: license, argumentHint: argumentHint, body: bodyText,
                    sinceModified: loadedModificationDate
                )
                // modelInvocable is the toggle's own sense (true = invocable);
                // disableModelInvocation is the stored, inverted sense — they
                // read as EQUAL exactly when the toggle disagrees with what's
                // on disk, which is the write condition.
                if modelInvocable == editingSkill.disableModelInvocation {
                    try SkillOperations.setDisableModelInvocation(!modelInvocable, for: editingSkill)
                }
                if userInvocable != editingSkill.userInvocable {
                    try SkillOperations.setUserInvocable(userInvocable, for: editingSkill)
                }
            } else {
                let dir = try SkillOperations.createSkill(
                    name: name, description: desc, whenToUse: whenToUse, model: model,
                    includeReferences: assetsFolder, includeScripts: assetsFolder, includeAssets: assetsFolder
                )
                // createSkill only covers the base fields — fill in the rest
                // (effort/license/argument-hint/real body) with the same
                // round-trip-safe writer edit uses, so both paths converge
                // on one SKILL.md shape.
                let created = ClaudeSkill(
                    id: dir.path, name: name, skillDescription: desc, author: nil, version: nil,
                    source: .standalone, path: dir, hasReferences: assetsFolder, hasScripts: assetsFolder,
                    hasAssets: assetsFolder, whenToUse: whenToUse, allowedTools: [], model: model,
                    effort: nil, license: nil, argumentHint: nil, disableModelInvocation: false,
                    userInvocable: true, paths: [], packaging: .directory, rawFrontmatter: [:]
                )
                try SkillOperations.updateSkill(
                    created, description: desc, whenToUse: whenToUse, model: model,
                    effort: effort, license: license, argumentHint: argumentHint, body: bodyText
                )
                if !modelInvocable { try SkillOperations.setDisableModelInvocation(true, for: created) }
                if !userInvocable { try SkillOperations.setUserInvocable(false, for: created) }
            }
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete(_ skill: ClaudeSkill) {
        _ = try? SkillOperations.deleteSkill(skill)
        onSaved()
        dismiss()
    }

    /// Everything after the frontmatter's closing fence — used to seed the
    /// body field when opening an existing skill for edit.
    private static func extractBody(_ content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return content }
        let bodyStart = min(second + 1, lines.count)
        return lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
