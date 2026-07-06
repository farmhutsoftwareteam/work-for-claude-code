// Live transcript driven off a real StreamSession. Replaces V2TranscriptView's
// mock content. Each TranscriptItem maps to a SwiftUI row; assistant text
// blocks render token-by-token as deltas arrive.

import SwiftUI
import Inject

struct V2LiveTranscript: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession
    /// Project cwd — resolves relative file mentions in prose to Quick Look
    /// links. Falls back to what the session reports (nil until system/init).
    var projectCwd: String? = nil

    private let bottomAnchorID = "v2-transcript-bottom"

    /// Whether the view is "pinned" to the bottom — the ONLY state in which
    /// auto-scroll may fire. Scrolling up unpins (so reading during a
    /// streaming turn is never fought); scrolling back to the bottom re-pins;
    /// sending a message always re-pins. Without this, the scrollKey change
    /// (~30×/s while streaming) yanked the user to the bottom continuously —
    /// the transcript was unreadable during long turns.
    @State private var pinned = true

    var body: some View {
        // Profiling marker: one Point-of-Interest per transcript render. During
        // a stream this should track the ~30fps flush cadence, not the token
        // rate. (Swap for `Self._printChanges()` to see WHAT caused a render.)
        let _ = V2Signpost.signposter.emitEvent("transcript-render")
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy so a long transcript only builds the rows on screen. The
                // bottom anchor + scrollTo still pin the view to the latest as a
                // reply streams in.
                LazyVStack(alignment: .leading, spacing: 26) {
                    if session.transcript.isEmpty {
                        emptyState
                    } else if let err = session.endError {
                        // Resume/turn failed but history was preloaded — show
                        // the reason as a banner (the empty-state branch covers
                        // the no-history case).
                        errorBanner(err)
                    }
                    if session.preloadOmittedTurns > 0 {
                        earlierMessagesHint
                    }
                    // Index-keyed identity: the transcript is append-only with
                    // the last text block mutated in place while streaming.
                    // Content-hash ids changed every token (tearing down and
                    // rebuilding the streaming row + resetting text selection);
                    // a stable index keeps the row alive as its text grows.
                    ForEach(session.transcript.indices, id: \.self) { i in
                        row(for: session.transcript[i])
                    }

                    if session.isRetrying {
                        V2ApiRetryInline(info: session.lastRetry)
                            .animation(.easeOut(duration: 0.2), value: session.isRetrying)
                    }

                    if let result = session.latestResult {
                        V2LiveResultFooter(
                            result: result,
                            sessionId: session.sessionId,
                            onRetry: { session.retryLastTurn() }
                        )
                    }

                    if session.state == .working {
                        workingIndicator
                    }

                    // Zero-height anchor pinned to the very bottom. We scroll
                    // to THIS rather than the last transcript item, so
                    // streaming text (which mutates the last item in place
                    // without changing transcript.count) still keeps the view
                    // pinned, and the result footer / loading skeleton stay
                    // visible while a reply streams in.
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 24)
                // Full-width transcript: no readability cap, so the content
                // spans the whole pane and meets the scrollbar at the edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Pinned tracking: within 60pt of the content bottom counts as
            // pinned (covers padding + the anchor row). This is the feedback
            // loop auto-scroll was missing — scroll up and it stops fighting
            // you; return to the bottom and tracking resumes.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, atBottom in
                if pinned != atBottom { pinned = atBottom }
            }
            // scrollKey changes on every signal that grows the content: new
            // item, streaming growth of the last text block, state change,
            // result arrival. Auto-scroll ONLY while pinned, and NOT animated:
            // an animated scrollTo fired per token stacks dozens of competing
            // animations a second and stutters.
            .onChange(of: scrollKey) { _, _ in
                guard pinned else { return }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            // Sending a message is an unambiguous "take me to the reply" —
            // re-pin even if the user had scrolled up. Only fires on .userText
            // appends: tool rows the agent appends mid-turn never steal the
            // scroll position.
            .onChange(of: session.transcript.count) { _, _ in
                if case .userText = session.transcript.last {
                    pinned = true
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onAppear {
                // Jump to the bottom when a tab first shows — matters for
                // resumed sessions that open with preloaded history. Two
                // passes: LazyVStack hasn't laid out row heights on the first,
                // so a single scrollTo undershoots and opens mid-history.
                pinned = true
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
        .overlay { if session.isResuming { resumingOverlay } }
        .enableInjection()
    }

    /// Shown while a resumed session reads its history off disk — so clicking
    /// a session registers immediately instead of looking frozen.
    private var resumingOverlay: some View {
        VStack(spacing: 11) {
            V2PulseDot(size: 9, color: v2.ink)
            Text("Loading conversation…")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
    }

    /// Immediate, unmistakable "claude is working" cue shown the instant
    /// state flips to .working. Before its first token arrives we show a
    /// labelled pulsing row ("Working…") so there's never dead air after
    /// send; once text is streaming the shimmer skeleton carries the load.
    @ViewBuilder
    private var workingIndicator: some View {
        let hasStreamingText: Bool = {
            if case .assistantBlock(.text) = session.transcript.last { return true }
            return false
        }()
        if hasStreamingText {
            // Reply is already streaming — the growing text is the indicator, so
            // keep just a single cheap pulse. (The old 3× GeometryReader shimmer
            // re-ran a layout pass on every token.)
            V2PulseDot(size: 6, color: v2.faint)
                .padding(.top, 2)
        } else {
            // Nothing back yet — explicit labelled cue with a live elapsed
            // counter so a slow first token reads as "alive", not "stuck".
            HStack(spacing: 9) {
                V2PulseDot(size: 7, color: v2.ink)
                if let started = session.turnStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        let secs = Int(ctx.date.timeIntervalSince(started))
                        Text(secs >= 1 ? "Working… \(secs)s" : "Working…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                    }
                } else {
                    Text("Working…")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(v2.mute)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Cheap signature of everything that should trigger an auto-scroll.
    /// Includes the last block's character count so streaming growth (which
    /// leaves transcript.count untouched) still moves the view.
    private var scrollKey: String {
        // streamTick replaces the old O(n) grapheme count of the streaming
        // block — same "content grew" signal, O(1) to read.
        let working = session.state == .working ? 1 : 0
        let hasResult = session.latestResult == nil ? 0 : 1
        return "\(session.transcript.count)-\(session.streamTick)-\(working)-\(hasResult)-\(session.isRetrying ? 1 : 0)"
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .userText(let text):
            V2UserTurn(text: text)
        case .assistantBlock(let block):
            V2AssistantBlock(block: block, toolOutcomes: session.toolOutcomes,
                             baseDir: session.cwd ?? projectCwd)
        case .compactBoundary:
            V2CompactBoundary()
        case .systemNote(let kind, let text):
            V2SystemNote(kind: kind, text: text)
        }
    }

    private var earlierMessagesHint: some View {
        HStack(spacing: 9) {
            Rectangle().fill(v2.line).frame(height: 1).frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .medium))
                Text(earlierMessagesText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .kerning(0.4)
            }
            .foregroundColor(v2.faint)
            Rectangle().fill(v2.line).frame(height: 1).frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
    }

    private var earlierMessagesText: String {
        let n = session.preloadOmittedTurns
        if n == 1 { return "1 EARLIER MESSAGE NOT SHOWN" }
        return "\(n) EARLIER MESSAGES NOT SHOWN"
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundColor(v2.del).padding(.top, 1)
            Text(text)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(v2.del)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.delBg)
        .overlay(alignment: .leading) { Rectangle().fill(v2.del).frame(width: 2) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let err = session.endError {
                Text("⚠ Couldn’t open this conversation")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(v2.ink)
                Text(err)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Start a fresh session below to keep working in this project.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            } else {
                V2DovetailMark(size: 28).foregroundColor(v2.faint)
                Text(emptyHint)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
        }
        .padding(.vertical, 40)
    }

    private var emptyHint: String {
        switch session.state {
        case .idle:               return "Type a message to start the session."
        case .spawning:           return "Spawning claude…"
        case .initializing:      return "Initializing — waiting for system/init…"
        case .terminated(let r):  return "Session ended: \(r)"
        default:                  return "…"
        }
    }
}

// MARK: - User turn

struct V2UserTurn: View {
    @Environment(\.v2) private var v2
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text("you")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 3)

            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(13 * 0.6)
                .foregroundColor(v2.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper3)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Assistant content block

struct V2AssistantBlock: View {
    @Environment(\.v2) private var v2
    let block: ContentBlock
    var toolOutcomes: [String: Bool] = [:]
    var baseDir: String? = nil
    @State private var buttonHover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            V2DovetailMark(size: 18)
                .foregroundColor(v2.ink)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            // Message + a quiet copy action BELOW it, left-aligned with the
            // text. Always visible — hover-reveal kept dropping the button
            // mid-reach (the NSTextView prose runs its own mouse tracking, and
            // streaming auto-scroll moves content under the cursor, both of
            // which flip a row-level hover to false). A stable target beats a
            // clever one.
            VStack(alignment: .leading, spacing: 6) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if textForCopy != nil {
                    copyButton
                }
            }
        }
    }

    /// Raw text to copy, when this block is a text block.
    private var textForCopy: String? {
        if case .text(let s) = block { return s }
        return nil
    }

    private var copyButton: some View {
        Button {
            guard let t = textForCopy else { return }
            V2Clipboard.copy(t)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(copied ? "copied" : "copy")
                    .font(.system(size: 10.5, design: .monospaced))
            }
            // Quiet at rest, ink when the BUTTON itself is hovered/just used.
            .foregroundColor(copied || buttonHover ? v2.ink : v2.faint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(buttonHover ? v2.paper2 : Color.clear)
            .overlay(Rectangle().stroke(buttonHover || copied ? v2.line2 : v2.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { buttonHover = $0 }
        .help("Copy message")
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .text(let s):
            V2MarkdownText(text: s, baseDir: baseDir)
                .foregroundColor(v2.ink)
        case .toolUse(let id, let name, let input):
            if name == "TodoWrite", let todos = input.dig("todos")?.asArray {
                V2LiveTodoBlock(todos: todos)
            } else {
                V2LiveToolWidget(name: name, input: input, outcome: toolOutcomes[id])
            }
        case .toolResult(_, let content, let isError):
            V2LiveToolResult(content: content, isError: isError ?? false)
        case .thinking(let text, _):
            V2LiveThinkingBlock(text: text)
        case .unknown(let type):
            Text("[unknown block: \(type)]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
        }
    }
}

// MARK: - Live thinking

struct V2LiveThinkingBlock: View {
    @Environment(\.v2) private var v2
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Text("Thinking")
                        .font(.system(size: 11.5, design: .monospaced))
                    Spacer()
                    Text("reasoning")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundColor(v2.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if open {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .italic()
                    .lineSpacing(11.5 * 0.7)
                    .foregroundColor(v2.mute)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
                    .padding(.leading, 19)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundColor(v2.line2)
        )
    }
}

// MARK: - Live tool widget (dispatches per tool name)

struct V2LiveToolWidget: View {
    @Environment(\.v2) private var v2
    let name: String
    let input: JSONValue
    /// nil = still running, false = done, true = error. Drives the row's valence.
    var outcome: Bool? = nil

    var body: some View {
        // Agent vocabulary: uppercase tag · target as a token (path/ref) or an
        // ink command chip (Bash) · status carries valence (spinner → ✓ / ✗).
        HStack(spacing: 11) {
            V2Pill(text: name.uppercased())
            target.frame(maxWidth: .infinity, alignment: .leading)
            status
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    @ViewBuilder
    private var status: some View {
        switch outcome {
        case .none:        V2Spinner(size: 11)
        case .some(false): Text("✓").foregroundColor(v2.add)
        case .some(true):  Text("✗").foregroundColor(v2.del)
        }
    }

    @ViewBuilder
    private var target: some View {
        switch name {
        case "Bash":
            V2CommandChip(input.dig("command")?.asString ?? input.preview)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            V2Token(input.dig("file_path")?.asString ?? input.preview)
        case "Glob":
            V2Token(input.dig("pattern")?.asString ?? input.preview)
        case "Grep":
            HStack(spacing: 8) {
                Text("“\(input.dig("pattern")?.asString ?? "")”")
                    .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
                if let path = input.dig("path")?.asString ?? input.dig("glob")?.asString {
                    Text("·").foregroundColor(v2.faint)
                    V2Token(path)
                }
            }
        default:
            Text(input.preview)
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Agent-vocabulary atoms

/// A "token" chip — file paths, refs, shas, globs. The unifying primitive of
/// the agent action vocabulary.
struct V2Token: View {
    @Environment(\.v2) private var v2
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(v2.tokInk)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(v2.tok)
    }
}

/// An ink-filled chip for a command (Bash) — the loud, executed instruction.
struct V2CommandChip: View {
    @Environment(\.v2) private var v2
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(v2.paper)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(v2.ink)
    }
}

// MARK: - Todo state block (TodoWrite)

/// The agent-vocabulary todo state block — a TodoWrite call rendered as a
/// checklist: completed = sage fill + strikethrough, in-progress = pulsing dot,
/// pending = empty box.
struct V2LiveTodoBlock: View {
    @Environment(\.v2) private var v2
    let todos: [JSONValue]

    private struct Todo { let content: String; let status: String }
    private var items: [Todo] {
        todos.map { Todo(content: $0.dig("content")?.asString ?? "",
                         status: $0.dig("status")?.asString ?? "pending") }
    }
    private var doneCount: Int { items.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("TASKS · \(doneCount) / \(items.count)")
                .font(.system(size: 10, design: .monospaced)).kerning(0.8)
                .foregroundColor(v2.faint)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 10) {
                        box(t.status).padding(.top, 1)
                        Text(t.content)
                            .font(.system(size: 12.5, design: .monospaced))
                            .strikethrough(t.status == "completed")
                            .foregroundColor(textColor(t.status))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func textColor(_ status: String) -> Color {
        switch status {
        case "completed":   return v2.faint
        case "in_progress": return v2.ink
        default:            return v2.mute
        }
    }

    @ViewBuilder
    private func box(_ status: String) -> some View {
        switch status {
        case "completed":
            ZStack {
                Rectangle().fill(v2.add)
                Text("✓").font(.system(size: 9)).foregroundColor(v2.paper)
            }
            .frame(width: 13, height: 13)
        case "in_progress":
            Rectangle().stroke(v2.ink, lineWidth: 1).frame(width: 13, height: 13)
                .overlay(V2PulseDot(size: 5, color: v2.ink))
        default:
            Rectangle().stroke(v2.line2, lineWidth: 1).frame(width: 13, height: 13)
        }
    }
}

// MARK: - Live tool result

struct V2LiveToolResult: View {
    @Environment(\.v2) private var v2
    let content: ToolResultContent
    let isError: Bool

    var body: some View {
        let summary = content.asString.prefix(500)
        Text(String(summary))
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(11.5 * 0.65)
            .foregroundColor(isError ? v2.del : v2.mute)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? v2.delBg : v2.paper2)
            .overlay(Rectangle().stroke(isError ? v2.del : v2.line, lineWidth: 1))
            .textSelection(.enabled)
    }
}

// MARK: - Compact boundary marker

struct V2CompactBoundary: View {
    @Environment(\.v2) private var v2

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(v2.line2).frame(height: 1)
            Text("compact boundary")
                .font(.system(size: 10, design: .monospaced))
                .kerning(0.8)
                .foregroundColor(v2.faint)
            Rectangle().fill(v2.line2).frame(height: 1)
        }
    }
}

// MARK: - Live result footer

struct V2LiveResultFooter: View {
    @Environment(\.v2) private var v2
    let result: ResultEvent
    let sessionId: String?
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            Text("\(V2Format.count(result.numTurns ?? 0)) turns")
            Text(durationText)
            if let cost = result.totalCostUsd {
                Text(V2Format.usd(cost))
            }
            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                        Text("retry")
                    }
                    .foregroundColor(v2.mute)
                }
                .buttonStyle(.plain)
                .help("Re-send the last message")
            }
            Spacer()
            if let sid = sessionId {
                Text("session \(String(sid.prefix(8)))")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(v2.faint)
        .padding(.top, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private var durationText: String {
        guard let ms = result.durationMs else { return "" }
        let seconds = ms / 1000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

// MARK: - System note

/// Subtle inline row for claude `system` events we used to drop — stop-hook
/// output, informational notices, non-retryable errors. Icon + tint by kind,
/// monospaced body, indented under a hairline so it reads as chrome, not as
/// an assistant message.
struct V2SystemNote: View {
    @Environment(\.v2) private var v2
    let kind: TranscriptItem.SystemNoteKind
    let text: String

    private var icon: String {
        switch kind {
        case .info:  return "info.circle"
        case .hook:  return "bolt.horizontal.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch kind {
        case .info:  return v2.faint
        case .hook:  return v2.mute
        case .error: return v2.del
        }
    }

    private var isError: Bool { if case .error = kind { return true }; return false }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(isError ? v2.mute : tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Errors get the vocabulary's boxed treatment (clay border + clay-bg);
        // info / hook stay subtle with a left tint bar.
        .background(isError ? v2.delBg : v2.paper2)
        .overlay {
            if isError { Rectangle().stroke(v2.del, lineWidth: 1) }
        }
        .overlay(alignment: .leading) {
            if !isError { Rectangle().fill(tint.opacity(0.4)).frame(width: 2) }
        }
    }
}
