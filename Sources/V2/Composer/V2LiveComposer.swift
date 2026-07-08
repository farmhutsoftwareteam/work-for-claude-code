// Live composer bound to a real StreamSession. Send / Stop based on state.
//
// Text input is a custom NSTextView wrapper (V2ComposerTextView) so:
//   • Enter submits, Shift+Enter inserts a newline (matches modern chat UX)
//   • Cmd+V'd / dragged images get caught and emitted as attachments
//   • Drag & drop file URLs from Finder land as attachments
//
// Attachments aren't sent over the wire as base64 — we prepend "@<path>"
// references to the user turn so claude reads them via its Read tool.
// Same mechanism Claude Code uses for any file mention; no protocol change.

import SwiftUI
import AppKit
import Inject

struct V2LiveComposer: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @ObservedObject var session: StreamSession
    @StateObject private var attachments = V2AttachmentStore()
    @State private var draft: String = ""
    /// Composer height, recomputed only when the draft EDITS (O(draft) scan)
    /// — read O(1) in body, which re-runs per streamed token. 27 = one line.
    @State private var cachedHeight: CGFloat = 27
    @State private var inputFocused: Bool = false
    @State private var slashActive: Int = 0   // highlighted row in the popover
    /// User-authored commands loaded from .claude/commands + ~/.claude/commands.
    @State private var customCommands: [V2SlashCommand] = []
    /// The command picked for an arguments-taking command. While set, the
    /// composer is in "command mode": a locked chip shows the command and the
    /// text field holds only its arguments.
    @State private var activeCommand: V2SlashCommand?

    /// Measured width of the helper row, so it can shed hints as it narrows
    /// (same responsive contract as the session header).
    @State private var helperWidth: CGFloat = 0
    private var helperCompact: Bool { helperWidth > 0 && helperWidth < 620 }
    private var helperTight: Bool { helperWidth > 0 && helperWidth < 470 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !attachments.items.isEmpty {
                attachmentStrip
            }
            // Slash-command popover floats above the composer when the draft
            // starts with "/" and no space has been typed yet.
            ZStack(alignment: .bottomLeading) {
                composerBox
                if slashOpen {
                    slashPopover
                        .offset(y: -(cachedHeight + 36))
                }
            }
            helperRow
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .onAppear {
            inputFocused = true
            // Restore the draft saved for this tab (the composer's @State was
            // torn down while the tab was off-screen).
            if draft.isEmpty { draft = session.composerDraft }
        }
        .task(id: session.cwd) { await loadCustomCommands() }
        // Focus once on appear, then leave the user alone. The previous
        // onChange(of: session.state) yanked focus back on every transition
        // — when you clicked a rail/tab to switch projects, the new
        // composer's onChange fired as its session reached .ready and
        // stole focus right back, which felt like the click had failed.
        //
        // ⎋ to interrupt — the placeholder + helper row have always
        // advertised this, but it was never actually wired; only the Stop
        // button worked. Hidden zero-size button in the responder chain
        // makes the escape key interrupt the running turn.
        .background(
            Button("Interrupt") { if isWorking { session.interrupt() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .disabled(!isWorking)
        )
        .enableInjection()
    }

    // MARK: - Composer box

    private var composerBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("›")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(v2.mute)
                .padding(.top, 6)

            if let cmd = activeCommand {
                commandChip(cmd).padding(.top, 3)
            }

            V2ComposerTextView(
                text: $draft,
                focused: $inputFocused,
                placeholder: composerPlaceholder,
                isEnabled: canType,
                foregroundColor: NSColor(v2.ink),
                placeholderColor: NSColor(v2.faint),
                onSubmit: sendCurrent,
                onImagePasted: { image in attachments.addImage(image) },
                onFilesDropped: { urls in attachments.addFiles(urls) },
                popoverOpen: slashOpen,
                onPopoverMove: moveSlashSelection,
                onPopoverPick: pickSlashCommand,
                onPopoverDismiss: dismissSlash,
                onBackspaceAtStart: backspaceAtStart
            )
            .onChange(of: draft) { _, _ in
                // Keep the highlighted row in range as the filter narrows.
                if slashActive >= slashResults.count { slashActive = 0 }
                // Persist the draft on the session so it survives a tab switch.
                session.composerDraft = draft
                // Height is O(draft) to compute (newline + wrap scan) — do it
                // once per EDIT here, not in body: the composer re-renders per
                // streamed token, and re-scanning a big pasted draft 30×/s
                // was part of the long-paste glitch.
                cachedHeight = Self.height(for: draft)
            }
            .onAppear { cachedHeight = Self.height(for: draft) }
            // Size to actual text content. 19pt per line approximates the
            // monospaced 13pt with default leading + the scrollview's 4pt
            // top inset. Cap at 8 lines — beyond that, the inner NSScrollView
            // kicks in.
            .frame(height: cachedHeight)

            attachButton

            if isWorking {
                Button { session.interrupt() } label: {
                    HStack(spacing: 7) {
                        Rectangle().fill(v2.ink).frame(width: 8, height: 8)
                        Text("Stop")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(v2.paper2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: sendCurrent) {
                    Text("⏎ send")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(canSend ? v2.ink : v2.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    // MARK: - Slash command popover

    /// Every command available right now: the built-in catalog plus the
    /// user's own commands loaded off disk (project overrides personal by
    /// name; both override a built-in of the same name).
    private var allCommands: [V2SlashCommand] {
        var byName: [String: V2SlashCommand] = [:]
        for c in V2SlashCatalog.builtins { byName[c.name] = c }
        for c in customCommands { byName[c.name] = c }
        return Array(byName.values)
    }

    /// Open when the draft is a bare "/query" (no space yet — once a command
    /// is completed to "/name " we close so it doesn't show "no matches").
    private var slashOpen: Bool {
        activeCommand == nil && draft.hasPrefix("/") && !draft.contains(" ") && canType
    }

    /// Filtered, category-then-name ordered results. The flat order here
    /// matches the grouped render order, so `slashActive` indexes both.
    private var slashResults: [V2SlashCommand] {
        V2SlashCatalog.filtered(String(draft.dropFirst()), in: allCommands)
    }

    private var groupedResults: [(V2SlashCategory, [V2SlashCommand])] {
        let results = slashResults
        return V2SlashCategory.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { cat in
                let items = results.filter { $0.category == cat }
                return items.isEmpty ? nil : (cat, items)
            }
    }

    private var highlightedCommand: V2SlashCommand? {
        slashResults.indices.contains(slashActive) ? slashResults[slashActive] : nil
    }

    private var slashPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("COMMANDS")
                    .font(.system(size: 9.5, design: .monospaced)).kerning(1.2)
                    .foregroundColor(v2.faint)
                Spacer()
                Text("↑↓ navigate · ⏎ run · esc dismiss")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }

            if slashResults.isEmpty {
                Text("no commands match · ⏎ sends it anyway")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
            } else {
                ForEach(groupedResults, id: \.0) { cat, items in
                    Text(cat.rawValue)
                        .font(.system(size: 8.5, design: .monospaced)).kerning(1.3)
                        .foregroundColor(v2.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)
                    ForEach(items) { cmd in
                        commandRow(cmd)
                    }
                }
            }
        }
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: -6)
        .frame(maxWidth: .infinity)
    }

    private func commandRow(_ cmd: V2SlashCommand) -> some View {
        let active = cmd.id == highlightedCommand?.id
        return Button { activate(cmd) } label: {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("/\(cmd.name)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(v2.ink)
                    if let hint = cmd.argumentHint {
                        Text(hint)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(v2.faint)
                    }
                }
                .frame(width: 210, alignment: .leading)
                Text(cmd.desc)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(cmd.runTag)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? v2.card : Color.clear)
            .overlay(alignment: .leading) {
                if active { Rectangle().fill(v2.ink).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moveSlashSelection(_ delta: Int) {
        let n = slashResults.count
        guard n > 0 else { return }
        slashActive = (slashActive + delta + n) % n
    }

    /// Enter / Tab while the popover is open. A command with no arguments runs
    /// immediately; one that takes arguments completes to "/name " so you can
    /// type them. With no match, Enter falls through and sends the literal
    /// text (it might be a command we don't model).
    private func pickSlashCommand() {
        guard let cmd = highlightedCommand else {
            sendCurrent()
            return
        }
        activate(cmd)
    }

    /// Selecting a command: an arg-less one fires immediately; one that takes
    /// arguments enters "command mode" — the name locks into a chip and the
    /// field clears to hold only the arguments.
    private func activate(_ cmd: V2SlashCommand) {
        if cmd.takesArguments {
            beginCommand(cmd)
        } else {
            run(cmd, args: "")
        }
    }

    private func beginCommand(_ cmd: V2SlashCommand) {
        activeCommand = cmd
        draft = ""
        slashActive = 0
        inputFocused = true
    }

    /// Pop the locked command chip. The text already typed stays in the
    /// field, becoming a plain message. Called by the ✕ and by backspace at
    /// the start of an empty field.
    private func removeActiveCommand() {
        activeCommand = nil
        inputFocused = true
    }

    private func backspaceAtStart() -> Bool {
        guard activeCommand != nil else { return false }
        removeActiveCommand()
        return true
    }

    private func dismissSlash() {
        // Clear the leading "/" so the popover closes but keep nothing stale.
        if draft.hasPrefix("/") { draft = "" }
        slashActive = 0
    }

    /// The locked command token shown at the head of the composer in command
    /// mode. Inverse (ink fill / paper text) so it reads as committed.
    private func commandChip(_ cmd: V2SlashCommand) -> some View {
        HStack(spacing: 6) {
            Text("/\(cmd.name)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(v2.paper)
            Button(action: removeActiveCommand) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(v2.paper.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove command (⌫ at start)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(v2.ink)
        .fixedSize()
    }

    // MARK: - Command resolution & execution

    /// If `text` is "/name [args]" and name is a known command, return it.
    /// Returns nil for plain text or an unknown "/foo" (which we send as-is).
    private func matchedSlashCommand(_ text: String) -> (V2SlashCommand, String)? {
        guard text.hasPrefix("/") else { return nil }
        let body = String(text.dropFirst())
        let prefix = String(body.prefix(while: { $0 != " " }))
        let name = prefix.lowercased()
        guard !name.isEmpty else { return nil }
        guard let cmd = allCommands.first(where: { $0.name.lowercased() == name }) else { return nil }
        // Slice args by the ORIGINAL prefix length (lowercasing can change the
        // grapheme count for some scripts).
        let args = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cmd, args)
    }

    /// Run a command end-to-end: client actions execute in-app, prompt
    /// commands expand their template and send a real turn.
    private func run(_ cmd: V2SlashCommand, args: String) {
        // Prompt commands send a real turn — hold them while one is in flight
        // (don't interleave turns). Bail BEFORE clearing the chip/args so a
        // command picked mid-stream survives instead of silently vanishing.
        if case .prompt = cmd.kind, isWorking { return }
        slashActive = 0
        activeCommand = nil
        switch cmd.kind {
        case .client(let action):
            runClient(action, args: args)
            draft = ""
            inputFocused = true
        case .prompt(let body, _):
            let expanded = V2CommandRegistry.expand(body, args: args)
            guard !expanded.isEmpty else { draft = ""; return }
            draft = ""
            attachments.clear()
            session.send(text: expanded)
            inputFocused = true
        }
    }

    private func runClient(_ action: V2ClientCommand, args: String) {
        switch action {
        case .clear:
            appState.clearConversation()
        case .cost:
            session.appendSystemNote(costSummary())
        case .model:
            applyModelCommand(args)
        case .permissions:
            applyPermissionCommand(args)
        case .mcp:
            appState.openDock(.mcp)
        case .agents:
            appState.openDock(.agents)
        case .help:
            session.appendSystemNote(helpText())
        }
    }

    private func costSummary() -> String {
        let tokens = V2Format.count(session.tokensUsed)
        guard let r = session.latestResult else {
            return "cost · \(tokens) tokens this session · no completed turn yet"
        }
        let cost = V2Format.usd(r.totalCostUsd ?? 0)
        let turns = r.numTurns ?? 0
        let secs = Double(r.durationMs ?? 0) / 1000
        return "cost · \(cost) · \(turns) turn\(turns == 1 ? "" : "s") · \(tokens) tokens · \(String(format: "%.1f", secs))s"
    }

    private func applyModelCommand(_ args: String) {
        let query = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            let list = appState.discoveredModels.isEmpty
                ? session.model
                : appState.discoveredModels.map { "\($0.displayName) (\($0.id))" }.joined(separator: ", ")
            session.appendSystemNote("model · current: \(session.model) · available: \(list) · type /model <name>")
            return
        }
        // Match a discovered model by id or display name; else treat the
        // typed value as a raw model id and pass it straight through.
        let match = appState.discoveredModels.first {
            $0.id.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
        }
        let target = match?.id ?? args.trimmingCharacters(in: .whitespacesAndNewlines)
        session.setModel(target)
        appState.defaultSpawnModel = target
        session.appendSystemNote("model → \(target)")
    }

    private func applyPermissionCommand(_ args: String) {
        let query = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            session.appendSystemNote(
                "permissions · current: \(session.permissionMode) · options: plan, default, acceptEdits, bypassPermissions · type /permissions <mode>")
            return
        }
        // Forgiving matching: "bypass" → bypassPermissions, "accept"/"edit" →
        // acceptEdits, prefix match otherwise.
        let mode: String?
        if query.hasPrefix("bypass") { mode = "bypassPermissions" }
        else if query.hasPrefix("accept") || query.contains("edit") { mode = "acceptEdits" }
        else { mode = StreamSession.permissionModes.first { $0.lowercased().hasPrefix(query) } }
        guard let resolved = mode else {
            session.appendSystemNote("permissions · unknown mode “\(args)” · options: plan, default, acceptEdits, bypassPermissions")
            return
        }
        // Route through app state so bypassPermissions restarts the session
        // (it's launch-only) while the others switch live.
        appState.changePermissionMode(resolved)
        session.appendSystemNote("permissions → \(resolved)")
    }

    private func helpText() -> String {
        var lines = ["Commands — type / in the composer."]
        for cat in V2SlashCategory.allCases.sorted(by: { $0.rank < $1.rank }) {
            let cmds = allCommands.filter { $0.category == cat }.sorted { $0.name < $1.name }
            guard !cmds.isEmpty else { continue }
            lines.append("")
            lines.append(cat.rawValue)
            for c in cmds {
                let hint = c.argumentHint.map { " \($0)" } ?? ""
                lines.append("  /\(c.name)\(hint) — \(c.desc) [\(c.runTag)]")
            }
        }
        lines.append("")
        lines.append("“app” runs here in Atelier · “→ agent” / “project” / “user” send a prompt to Claude.")
        return lines.joined(separator: "\n")
    }

    private func loadCustomCommands() async {
        let root = appState.activeTab.map { URL(fileURLWithPath: $0.projectCwd) }
            ?? session.cwd.map { URL(fileURLWithPath: $0) }
        let loaded = await Task.detached(priority: .utility) {
            V2CommandRegistry.load(projectRoot: root)
        }.value
        await MainActor.run { self.customCommands = loaded }
    }

    private var attachButton: some View {
        Button(action: openImagePicker) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.mute)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Attach an image or file (or drag one in / paste with ⌘V)")
        .disabled(!canType)
    }

    // MARK: - Attachment strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.items) { item in
                    attachmentChip(item)
                }
            }
        }
    }

    private func attachmentChip(_ item: V2Attachment) -> some View {
        HStack(spacing: 8) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipped()
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(v2.mute)
                    .frame(width: 24, height: 24)
                    .background(v2.paper3)
            }
            Text(item.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button { attachments.remove(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    // MARK: - Helper row

    private var helperRow: some View {
        HStack(spacing: 14) {
            if activeCommand != nil {
                Text("⌫ at start removes the command · ⏎ runs it")
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Button { session.cyclePermissionMode() } label: {
                    Text(helperTight
                         ? "/ · \(permissionLabel)"
                         : "/ for commands · \(permissionLabel) · shift+tab to cycle")
                        .foregroundColor(v2.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
            }

            // Secondary hint — first to go when the row gets narrow.
            if !helperCompact {
                Text("⇧⏎ newline · ⌘V paste image")
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }

            if isWorking {
                Text("esc to interrupt")
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // The context meter is the one thing that always stays — it carries
            // real state (how full the window is), not a static hint.
            contextMeter
                .layoutPriority(1)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(v2.faint)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: V2WidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(V2WidthKey.self) { helperWidth = $0 }
    }

    /// Model + how full the context is. Shows a % gauge only when we have a
    /// provider-sourced window (Anthropic Models API); otherwise it degrades
    /// to honest raw "Nk in context" with no invented denominator.
    private var contextMeter: some View {
        let used = session.contextTokens
        let usedLabel = V2Format.count(used)
        let window = appState.contextWindow(for: session.model)
        return HStack(spacing: 8) {
            // Model name is the first thing the meter sheds when space is tight
            // — the gauge + percentage matter more than the id.
            if !helperTight {
                Text(session.model)
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            if used == 0 {
                Text("context idle").foregroundColor(v2.faint).lineLimit(1)
            } else if let window, window > 0 {
                let frac = min(1, Double(used) / Double(window))
                let high = frac >= 0.85
                let pct = Int((frac * 100).rounded())
                ZStack(alignment: .leading) {
                    Rectangle().fill(v2.line2).frame(width: 46, height: 4)
                    Rectangle().fill(high ? v2.del : v2.ink)
                        .frame(width: 46 * max(0, frac), height: 4)
                }
                Text(helperTight ? "\(pct)%" : "\(pct)% · \(usedLabel)/\(V2Format.count(window))")
                    .foregroundColor(high ? v2.del : v2.faint)
                    .lineLimit(1)
                    .help("Context: \(usedLabel) of \(V2Format.count(window)) tokens (\(pct)%). /clear resets it, /compact summarises.")
            } else {
                // This model isn't in the bundled snapshot — never fake a %.
                Text(helperTight ? usedLabel : "\(usedLabel) in context")
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
                    .help("Tokens in context. No context-window on file for \(session.model) — run scripts/sync-model-windows.sh to refresh the snapshot from Anthropic.")
            }
        }
        // Never let the meter wrap or get truncated — it sheds its own bits
        // (model id, byte counts) via helperTight instead.
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Image picker

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .text, .data]
        panel.message = "Attach to the next message"
        if panel.runModal() == .OK {
            attachments.addFiles(panel.urls)
        }
    }

    // MARK: - State

    /// Placeholder the text field actually shows — the command's argument
    /// hint while in command mode, otherwise the session-state prompt.
    private var composerPlaceholder: String {
        if let cmd = activeCommand {
            if let hint = cmd.argumentHint { return "\(hint) — ⏎ to run /\(cmd.name)" }
            return "⏎ to run /\(cmd.name)"
        }
        return placeholder
    }

    private var placeholder: String {
        switch session.state {
        case .idle, .terminated:    return "Ask, or / for commands, or set a goal to run a loop…"
        case .ready:                return "Reply, or / for commands…"
        case .hibernated:           return "Reply to wake this session…"
        case .spawning:             return "Spawning…"
        case .initializing:         return "Initializing…"
        case .working:              return "Reply, or ⎋ to interrupt…"
        case .awaitingPermission:   return "Resolve permission above to continue"
        case .closing:              return "Closing…"
        }
    }

    private var canType: Bool {
        switch session.state {
        // .hibernated: typing IS the wake gesture — send() respawns via
        // --resume and delivers the message.
        case .idle, .working, .initializing, .ready, .hibernated: return true
        default: return false
        }
    }

    private var canSend: Bool {
        // Don't allow a send while a turn is in flight — pressing Enter
        // mid-stream used to fire a SECOND user turn into the same session,
        // interleaving with the reply that was still streaming, even though
        // the visible button said "Stop". You can keep typing your next
        // message (canType stays true); it sends once the turn finishes.
        guard canType, !isWorking else { return false }
        // In command mode, arguments are optional — the command can run with
        // an empty field, so Send stays enabled.
        if activeCommand != nil { return true }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !attachments.items.isEmpty
    }

    private var isWorking: Bool { session.state == .working || session.state == .awaitingPermission }

    private var permissionLabel: String {
        switch session.permissionMode {
        case "bypassPermissions": return "bypass permissions on"
        case "acceptEdits":       return "accept edits"
        case "plan":              return "plan mode"
        case "dontAsk":           return "don't ask"
        case "auto":              return "auto"
        default:                  return "default permissions"
        }
    }

    // MARK: - Sizing

    /// One line by default; grows with explicit newlines up to 8 lines.
    /// Soft-wrapped long lines also count via a rough column estimate so
    /// pasted paragraphs don't snap to a single row. Computed once per edit
    /// into `cachedHeight` (see onChange) — NOT in body, which re-runs per
    /// streamed token.
    private static func height(for draft: String) -> CGFloat {
        let lineHeight: CGFloat = 19
        let topBottomPadding: CGFloat = 8
        let newlines = draft.filter { $0 == "\n" }.count
        // Rough soft-wrap estimate: 80 chars per visible line.
        let wrapped = max(0, (draft.count / 80) - newlines)
        let lines = max(1, min(8, 1 + newlines + wrapped))
        return CGFloat(lines) * lineHeight + topBottomPadding
    }

    // MARK: - Send

    private func sendCurrent() {
        // In command mode the chip holds the command; the field is its args.
        if let cmd = activeCommand {
            run(cmd, args: draft)
            return
        }
        // A "/name [args]" submit for a known command runs the command
        // instead of sending the literal text to the agent. Unknown "/foo"
        // and plain text fall through to a normal turn.
        if let (cmd, args) = matchedSlashCommand(draft.trimmingCharacters(in: .whitespacesAndNewlines)) {
            run(cmd, args: args)
            return
        }
        guard canSend else { return }
        let body = draft
        let prefix = attachments.outboundPrefix()
        let full = prefix + body
        // Pre-authorise Reads for paths the user just attached. Without
        // this claude prompts for permission to read a file the user
        // literally picked seconds ago — even when the file lives outside
        // the project cwd (Desktop screenshots, etc.).
        for item in attachments.items {
            session.preApproveRead(path: item.url.path)
        }
        draft = ""
        attachments.clear()
        session.send(text: full)
        inputFocused = true
    }
}
