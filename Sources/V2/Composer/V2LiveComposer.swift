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
    /// Caret position (NSString/UTF-16 offset, matching NSTextView's own
    /// selectedRange) — the live source of truth trigger detection reads.
    @State private var cursorPosition: Int = 0
    /// Set alongside a programmatic draft edit (a splice) to land the caret
    /// at a specific spot instead of the text view's default "clamp the old
    /// selection" behavior. Consumed once by V2ComposerTextView.
    @State private var pendingCursorTarget: Int?
    /// Cursor position when the "/" icon or ⌘/ was pressed — non-nil means
    /// the palette is force-open independent of any "/" the user typed.
    /// Typing after opening this way narrows the query, same as a real
    /// slash trigger (see `paletteQuery`).
    @State private var forcedOpenAnchor: Int?
    @State private var slashActive: Int = 0   // highlighted row in the popover
    /// User-authored commands loaded from .claude/commands + ~/.claude/commands.
    @State private var customCommands: [V2SlashCommand] = []
    /// Commands the real agent process reported (ACP's
    /// `available_commands_update` → `ACPSession.commands`) — always empty
    /// today, since this composer is still on the pre-migration
    /// `StreamSession` path with no ACP session to source them from. Real
    /// state, not a stub: this IS the documented fallback (baseline only,
    /// unchanged from before). Wiring it up once the composer moves to
    /// ACPSession is a one-line change to whatever sets this.
    @State private var agentReportedCommands: [ACPCommand] = []
    /// `allCommands`, cached — rebuilt only when `customCommands` changes (see
    /// `rebuildAllCommands`), not on every access. This view @ObservedObjects
    /// `session` and re-renders per streamed token, so a live computed
    /// property here rebuilt a `[String: V2SlashCommand]` dictionary on every
    /// delta while the slash popover was open (PERFORMANCE.md rule 4).
    @State private var allCommandsCache: [V2SlashCommand] = V2SlashCatalog.builtins
    /// Slash-filter results, cached alongside `allCommandsCache` — recomputed
    /// only on a real draft edit or command-set reload (`recomputeSlashResults`),
    /// not as a live computed property re-filtered/re-sorted on every render.
    @State private var cachedSlashResults: [V2SlashMatch] = []
    @State private var cachedGroupedResults: [(V2SlashCategory, [V2SlashMatch])] = []
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
        V2ComposerChrome(
            attachments: attachments.items,
            onRemoveAttachment: attachments.remove
        ) {
            // Slash-command popover floats above the composer when the draft
            // starts with "/" and no space has been typed yet.
            ZStack(alignment: .bottomLeading) {
                composerBox
                if paletteOpen {
                    slashPopover
                        .offset(y: -(cachedHeight + 36))
                }
            }
        } helper: {
            helperRow
        }
        .onAppear {
            inputFocused = true
            // Restore the draft saved for this tab (the composer's @State was
            // torn down while the tab was off-screen).
            if draft.isEmpty { draft = session.composerDraft }
        }
        .task(id: session.cwd) { await loadCustomCommands() }
        // system/init lands asynchronously after this view appears — rebuild
        // once the session's real command list actually arrives, not just
        // on the cwd-driven custom-command reload above.
        .onChange(of: session.reportedSlashCommands) { _, _ in rebuildAllCommands() }
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
        V2ComposerBoxChrome {
            HStack(alignment: .top, spacing: 12) {
            // Always-visible entry point — not conditional on the box being
            // empty, unlike the old "/ for commands" helper-row hint. Opens
            // the palette at the cursor regardless of what's already typed.
            Button(action: openPaletteAtCursor) {
                Text("/")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("/", modifiers: .command)
            .disabled(!canType || activeCommand != nil)
            .padding(.top, 6)
            .help("Command palette (⌘/)")

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
                cursorPosition: $cursorPosition,
                pendingCursorTarget: $pendingCursorTarget,
                placeholder: composerPlaceholder,
                isEnabled: canType,
                foregroundColor: NSColor(v2.ink),
                placeholderColor: NSColor(v2.faint),
                onSubmit: sendCurrent,
                onImagePasted: { image in attachments.addImage(image) },
                onFilesDropped: { urls in attachments.addFiles(urls) },
                popoverOpen: paletteOpen,
                onPopoverMove: moveSlashSelection,
                onPopoverPick: pickSlashCommand,
                onPopoverDismiss: dismissSlash,
                onBackspaceAtStart: backspaceAtStart
            )
            .onChange(of: draft) { _, _ in
                // Recompute the slash-filter cache once per EDIT (not live per
                // render) — same reasoning as cachedHeight below.
                recomputeSlashResults()
                // Keep the highlighted row in range as the filter narrows.
                if slashActive >= cachedSlashResults.count { slashActive = 0 }
                // Persist the draft on the session so it survives a tab switch.
                session.composerDraft = draft
                appState.scheduleWorkspacePersist()
                // Height is O(draft) to compute (newline + wrap scan) — do it
                // once per EDIT here, not in body: the composer re-renders per
                // streamed token, and re-scanning a big pasted draft 30×/s
                // was part of the long-paste glitch.
                cachedHeight = V2ComposerMetrics.height(for: draft)
            }
            .onChange(of: cursorPosition) { _, _ in
                // The trigger span and query are cursor-relative — moving
                // the caret (arrow keys, click) without typing can still
                // change which command, if any, is being searched for.
                recomputeSlashResults()
                if slashActive >= cachedSlashResults.count { slashActive = 0 }
            }
            .onAppear {
                cachedHeight = V2ComposerMetrics.height(for: draft)
                recomputeSlashResults()
            }
            // Size to actual text content. 19pt per line approximates the
            // monospaced 13pt with default leading + the scrollview's 4pt
            // top inset. Cap at 8 lines — beyond that, the inner NSScrollView
            // kicks in.
            .frame(height: cachedHeight)

                V2ComposerAttachButton(enabled: canType, action: openImagePicker)
                V2ComposerTurnButton(
                    isWorking: isWorking,
                    canSend: canSend,
                    onSend: sendCurrent,
                    onStop: session.interrupt
                )
            }
        }
    }

    // MARK: - Slash command popover

    /// Every command available right now: the built-in catalog plus the
    /// user's own commands loaded off disk (project overrides personal by
    /// name; both override a built-in of the same name). Backed by
    /// `allCommandsCache` — see `rebuildAllCommands`.
    private var allCommands: [V2SlashCommand] { allCommandsCache }

    private struct SlashTrigger {
        let sliceStart: Int   // NSString offset of the "/" itself
        let query: String     // text between the "/" and the cursor
    }

    /// Scans back from the cursor for a "/" that's a valid trigger position
    /// — the very start of the draft, or right after whitespace/newline —
    /// never mid-word, so a literal "/" inside a URL or path doesn't hijack
    /// the composer. Matches Slack/Discord/Notion/Linear's own convention.
    /// Stops (no trigger) the moment it crosses a word boundary without
    /// finding "/" first — cursor-relative, not "does the WHOLE draft start
    /// with /" like the old check.
    private var slashTrigger: SlashTrigger? {
        let ns = draft as NSString
        let cursor = min(max(0, cursorPosition), ns.length)
        var i = cursor
        while i > 0 {
            let ch = ns.character(at: i - 1)
            if ch == 0x2F {   // "/"
                let atBoundary = (i - 1 == 0) || Self.isBoundary(ns.character(at: i - 2))
                guard atBoundary else { return nil }
                return SlashTrigger(sliceStart: i - 1, query: ns.substring(with: NSRange(location: i, length: cursor - i)))
            }
            if Self.isBoundary(ch) { return nil }   // crossed a completed word — no trigger here
            i -= 1
        }
        return nil
    }

    private static func isBoundary(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D   // space, tab, \n, \r
    }

    /// Open via a typed "/" in a valid trigger position, OR forced open by
    /// the icon/⌘/ regardless of what's typed. Either way, opening never
    /// touches `draft` — see `openPaletteAtCursor` and `slashTrigger`.
    private var paletteOpen: Bool {
        guard activeCommand == nil, canType else { return false }
        return slashTrigger != nil || forcedOpenAnchor != nil
    }

    /// The filter query: the typed trigger's span if there is one, else
    /// whatever's been typed since a forced-open anchor (so search narrows
    /// as you type after clicking the icon, same as after typing "/").
    private var paletteQuery: String {
        if let trigger = slashTrigger { return trigger.query }
        guard let anchor = forcedOpenAnchor else { return "" }
        let ns = draft as NSString
        let cursor = min(max(0, cursorPosition), ns.length)
        guard cursor >= anchor, anchor <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: anchor, length: cursor - anchor))
    }

    /// Filtered, category-then-name ordered results. The flat order here
    /// matches the grouped render order, so `slashActive` indexes both.
    /// Backed by `cachedSlashResults` — see `recomputeSlashResults`.
    private var slashResults: [V2SlashMatch] { cachedSlashResults }

    private var groupedResults: [(V2SlashCategory, [V2SlashMatch])] { cachedGroupedResults }

    /// Rebuild the name→command dictionary — only called when
    /// `customCommands` actually changes (after a load), not on every access.
    /// Builtins and custom commands still override by name (project beats
    /// personal beats built-in, unchanged); agent-reported commands layer on
    /// top via `V2SlashCatalog.merged` — append-only, never overriding.
    private func rebuildAllCommands() {
        var byName: [String: V2SlashCommand] = [:]
        for c in V2SlashCatalog.builtins { byName[c.name] = c }
        for c in customCommands { byName[c.name] = c }
        allCommandsCache = V2SlashCatalog.merged(
            builtins: Array(byName.values),
            agentReported: agentReportedCommands,
            sessionReported: session.reportedSlashCommands
        )
        // The command set changed, so the current filter/sort is stale too.
        recomputeSlashResults()
    }

    /// Re-filter + re-sort into `cachedSlashResults`/`cachedGroupedResults`.
    /// Called on a real draft/cursor edit or command-set reload — never as a
    /// live computed property, so streamed-token re-renders while the
    /// popover is open don't re-run the filter + double-sort on every delta.
    private func recomputeSlashResults() {
        let results = V2SlashCatalog.matched(paletteQuery, in: allCommandsCache)
        cachedSlashResults = results
        cachedGroupedResults = V2SlashCategory.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { cat in
                let items = results.filter { $0.command.category == cat }
                return items.isEmpty ? nil : (cat, items)
            }
    }

    private var highlightedCommand: V2SlashCommand? {
        slashResults.indices.contains(slashActive) ? slashResults[slashActive].command : nil
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
                    ForEach(items) { match in
                        commandRow(match)
                    }
                }
            }
        }
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: -6)
        .frame(maxWidth: .infinity)
    }

    private func commandRow(_ match: V2SlashMatch) -> some View {
        let cmd = match.command
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
                // Only shown for a fuzzy hit NOT on the name — an unexplained
                // result (matched only because the description mentions it)
                // would otherwise read as arbitrary.
                if match.matchedOn == .desc {
                    Text("matched: desc")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
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

    /// True when the current trigger (typed "/" or the icon/⌘/ anchor) spans
    /// the WHOLE meaningful draft — nothing but whitespace before it or after
    /// the cursor. Only then does the classic "locked chip, args-only field"
    /// command mode make sense; a command picked out of the middle of a
    /// longer message has no business taking over the whole composer.
    private func isWholeDraftTrigger() -> Bool {
        let ns = draft as NSString
        let cursor = min(max(0, cursorPosition), ns.length)
        guard let start = slashTrigger?.sliceStart ?? forcedOpenAnchor, start <= cursor, start <= ns.length else {
            return false
        }
        let before = ns.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        return before.isEmpty && after.isEmpty
    }

    /// Selecting a command. Whole-draft trigger: unchanged classic flow — an
    /// arg-less command fires immediately, one that takes arguments enters
    /// "command mode". Mid-draft or icon-opened-with-surrounding-text: never
    /// auto-runs (that would silently execute or send mid-sentence) and never
    /// locks the composer — just completes the name inline and leaves the
    /// rest of the draft exactly as it was.
    private func activate(_ cmd: V2SlashCommand) {
        guard isWholeDraftTrigger() else {
            spliceCommandName(cmd)
            return
        }
        if cmd.takesArguments {
            beginCommand(cmd)
        } else {
            run(cmd, args: "")
        }
    }

    private func beginCommand(_ cmd: V2SlashCommand) {
        activeCommand = cmd
        draft = ""
        forcedOpenAnchor = nil
        slashActive = 0
        inputFocused = true
    }

    /// Replaces the trigger span (typed "/query", or nothing if opened via
    /// icon/⌘/ with no query yet) with "/name ", leaving every other
    /// character in the draft untouched, and lands the caret right after it.
    private func spliceCommandName(_ cmd: V2SlashCommand) {
        let ns = draft as NSString
        let cursor = min(max(0, cursorPosition), ns.length)
        let start = min(max(0, slashTrigger?.sliceStart ?? forcedOpenAnchor ?? cursor), cursor)
        let replacement = "/\(cmd.name) "
        draft = ns.replacingCharacters(in: NSRange(location: start, length: cursor - start), with: replacement)
        pendingCursorTarget = start + (replacement as NSString).length
        forcedOpenAnchor = nil
        slashActive = 0
        inputFocused = true
    }

    /// Open the palette at the current cursor regardless of what's typed —
    /// the "/" icon and ⌘/ entry point. Never touches `draft`.
    private func openPaletteAtCursor() {
        guard activeCommand == nil, canType else { return }
        forcedOpenAnchor = cursorPosition
        slashActive = 0
        recomputeSlashResults()
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

    /// Closes the popover without touching anything outside the trigger
    /// span — deletes just the "/" (and whatever was typed after it) that
    /// opened it, same as backspacing it out yourself, never the rest of a
    /// longer draft. A forced-open (icon/⌘/) with nothing typed yet just
    /// closes with no draft change at all.
    private func dismissSlash() {
        let ns = draft as NSString
        let cursor = min(max(0, cursorPosition), ns.length)
        if let trigger = slashTrigger {
            draft = ns.replacingCharacters(in: NSRange(location: trigger.sliceStart, length: cursor - trigger.sliceStart), with: "")
            pendingCursorTarget = trigger.sliceStart
        } else if let anchor = forcedOpenAnchor, cursor > anchor {
            draft = ns.replacingCharacters(in: NSRange(location: anchor, length: cursor - anchor), with: "")
            pendingCursorTarget = anchor
        }
        forcedOpenAnchor = nil
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
        await MainActor.run {
            self.customCommands = loaded
            self.rebuildAllCommands()
        }
    }

    // MARK: - Helper row

    private var helperRow: some View {
        HStack(spacing: 14) {
            V2ProviderBadge(
                provider: .claude,
                density: .compact
            )
            .layoutPriority(2)

            if activeCommand != nil {
                Text("⌫ at start removes the command · ⏎ runs it")
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Button { session.cyclePermissionMode() } label: {
                    Text(helperTight
                         ? "/ · \(permissionLabel)"
                         : "⌘/ opens commands · \(permissionLabel) · shift+tab to cycle")
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

            // Plan-usage meter (5h/weekly quota %) — real state, hidden
            // entirely until the first get_usage reply lands.
            V2ComposerUsageMeter(limits: session.usageLimits, isTight: helperTight)
                .layoutPriority(1)

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
        let window = appState.contextWindow(for: session.model)
        return V2ComposerContextMeter(
            model: session.model,
            used: used,
            window: window,
            isTight: helperTight,
            helpText: "Claude model and current context usage. /clear resets it; /compact summarises."
        )
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
