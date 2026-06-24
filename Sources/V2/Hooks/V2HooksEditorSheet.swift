// V2 hooks editor — modal sheet listing every hook event with the user's
// configured commands. Add / edit / delete commands; writes through
// HookConfigWriter atomically.
//
// Scope: user (~/.claude/settings.json) by default; project scope toggle
// added in a follow-up once we have a project-scope hook reader.

import SwiftUI
import Inject

struct V2HooksEditorSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store

    let onClose: () -> Void

    @State private var editing: EditState?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 700, height: 640)
        .background(v2.paper)
        .environment(\.v2, v2)
        .sheet(item: $editing) { state in
            V2HookCommandSheet(
                state: state,
                onSave: { result in
                    apply(result: result)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text("Hooks")
                .font(.system(size: 18, weight: .medium))
                .kerning(-0.25)
            Text("user scope · ~/.claude/settings.json")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.leading, 8)
            Spacer()
            Button {
                editing = .new
            } label: {
                Text("+ new")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(v2.ink)
            }
            .buttonStyle(.plain)
            Button { onClose() } label: {
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let msg = errorMessage {
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

                if store.hooks.isEmpty {
                    emptyState
                } else {
                    ForEach(store.hooks) { hook in
                        eventSection(hook)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No hooks configured yet.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Hooks fire shell commands at specific lifecycle events — PreToolUse, Stop, SessionStart, etc. Click '+ new' to add one.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.55)
                .foregroundColor(v2.faint)
        }
    }

    private func eventSection(_ hook: ClaudeHook) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text(hook.event.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .kerning(0.84)
                    .foregroundColor(v2.ink)
                Text(eventSummary(hook.event))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                Spacer()
                Text("\(hook.commands.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }

            VStack(spacing: 8) {
                ForEach(hook.commands) { cmd in
                    commandRow(event: hook.event, command: cmd)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func commandRow(event: String, command: ClaudeHook.HookCommand) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                if let m = command.matcher, !m.isEmpty {
                    Text("matcher: \(m)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                } else {
                    Text("matcher: (any)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Spacer()
                Button {
                    editing = .edit(event: event, command: command)
                } label: {
                    Text("edit")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    delete(event: event, matcher: command.matcher, command: command.command)
                } label: {
                    Text("delete")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.del)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text(command.command)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(11.5 * 0.55)
                .foregroundColor(v2.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                .textSelection(.enabled)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(v2.line2).frame(width: 2)
        }
    }

    private var footer: some View {
        HStack {
            Text("Writes are atomic — unrelated keys in settings.json are preserved.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
            Button { onClose() } label: {
                Text("Done")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(v2.ink)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    // MARK: - Mutations

    private func apply(result: V2HookCommandSheet.Result) {
        do {
            switch result {
            case .new(let event, let matcher, let command):
                try HookConfigWriter.upsert(scope: .user, event: event, matcher: matcher, command: command)
            case .updated(let event, let oldMatcher, let oldCommand, let newMatcher, let newCommand):
                try HookConfigWriter.update(
                    scope: .user,
                    event: event,
                    oldMatcher: oldMatcher,
                    oldCommand: oldCommand,
                    newMatcher: newMatcher,
                    newCommand: newCommand
                )
            }
            // The Store's file watcher picks up the change asynchronously,
            // but we kick a reload immediately so the sheet reflects right
            // away.
            Task { await store.load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(event: String, matcher: String?, command: String) {
        do {
            try HookConfigWriter.remove(scope: .user, event: event, matcher: matcher, command: command)
            Task { await store.load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func eventSummary(_ event: String) -> String {
        ClaudeHookEvent(rawValue: event)?.summary ?? ""
    }

    // MARK: - Edit state

    enum EditState: Identifiable {
        case new
        case edit(event: String, command: ClaudeHook.HookCommand)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let e, let c): return "edit-\(e)-\(c.id.uuidString)"
            }
        }
    }
}

// MARK: - Per-command edit sheet

struct V2HookCommandSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    enum Result {
        case new(event: String, matcher: String?, command: String)
        case updated(event: String, oldMatcher: String?, oldCommand: String, newMatcher: String?, newCommand: String)
    }

    let state: V2HooksEditorSheet.EditState
    let onSave: (Result) -> Void
    let onCancel: () -> Void

    @State private var event: ClaudeHookEvent = .preToolUse
    @State private var matcher: String = ""
    @State private var command: String = ""

    private var isEditing: Bool {
        if case .edit = state { return true } else { return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isEditing ? "Edit hook command" : "New hook command")
                    .font(.system(size: 16, weight: .medium))
                    .kerning(-0.2)
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
                VStack(alignment: .leading, spacing: 20) {
                    eventField
                    matcherField
                    commandField
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
                Button { save() } label: {
                    Text(isEditing ? "Save" : "Add")
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
        .frame(width: 540, height: 520)
        .background(v2.paper)
        .environment(\.v2, v2)
        .onAppear { seed() }
        .enableInjection()
    }

    private var eventField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("EVENT")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            Picker("", selection: $event) {
                ForEach(ClaudeHookEvent.allCases) { e in
                    Text(e.label).tag(e)
                }
            }
            .labelsHidden()
            .disabled(isEditing)
            Text(event.summary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
    }

    private var matcherField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MATCHER")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            TextField("(blank = match any)", text: $matcher)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            Text("Optional. For tool events, matches the tool name (regex / glob). E.g. \"Bash\", \"Edit|Write\".")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
    }

    private var commandField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("COMMAND")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            TextEditor(text: $command)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.ink)
                .scrollContentBackground(.hidden)
                .background(v2.card)
                .frame(minHeight: 110)
                .padding(8)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            Text("Shell command to run when this event fires. The event payload is passed as JSON on stdin. Use `set -e` to fail fast.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func seed() {
        switch state {
        case .new:
            // Defaults already set by @State initializers.
            return
        case .edit(let eventName, let cmd):
            if let e = ClaudeHookEvent(rawValue: eventName) { event = e }
            matcher = cmd.matcher ?? ""
            command = cmd.command
        }
    }

    private func save() {
        let normMatcher = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatcher: String? = normMatcher.isEmpty ? nil : normMatcher
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        switch state {
        case .new:
            onSave(.new(event: event.rawValue, matcher: trimmedMatcher, command: trimmedCommand))
        case .edit(let eventName, let cmd):
            onSave(.updated(
                event: eventName,
                oldMatcher: cmd.matcher,
                oldCommand: cmd.command,
                newMatcher: trimmedMatcher,
                newCommand: trimmedCommand
            ))
        }
    }
}
