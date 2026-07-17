// Live transcript driven off a real session. Replaces V2TranscriptView's mock
// content. Each TranscriptItem maps to a SwiftUI row; assistant text blocks
// render token-by-token as deltas arrive.

import SwiftUI
import Inject

/// Provider-neutral surface this view renders against. StreamSession
/// (Claude) and CodexSession both conform, so Codex renders through this
/// EXACT view — not a lookalike copy — per fix design §1/§3 in
/// .agents/research/2026-07-16-bug-codex-transcript-parity.md: "one shared
/// transcript, not further styling of a second Codex transcript." Every
/// requirement here is something the body below actually reads; a provider
/// with no equivalent concept (Codex has no retry banner, no session-dir
/// peek) just supplies the neutral default (nil/empty/false) and the
/// relevant branch never renders — no special-casing inside the view itself.
@MainActor
protocol V2TranscriptSource: ObservableObject {
    var transcript: [TranscriptItem] { get }
    var endError: String? { get }
    var preloadOmittedTurns: Int { get }
    var subagentRuns: [V2SubagentRun] { get }
    var sessionDir: URL? { get }
    var state: StreamSession.LifecycleState { get }
    var toolOutcomes: [String: Bool] { get }
    var toolLiveStatus: [String: String] { get }
    var toolStartTimes: [String: Date] { get }
    var taskItems: [V2TaskItem] { get }
    var baseDir: String? { get }
    var isRetrying: Bool { get }
    var lastRetry: StreamSession.RetryInfo? { get }
    var latestResult: ResultEvent? { get }
    var sessionId: String? { get }
    var isResuming: Bool { get }
    var instanceId: UUID { get }
    var lastStreamActivityAt: Date { get }
    var turnStartedAt: Date? { get }
    var provider: V2AgentProvider { get }

    func retryLastTurn()
}

struct V2LiveTranscript<Session: V2TranscriptSource>: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: Session
    /// Project cwd — resolves relative file mentions in prose to Quick Look
    /// links. Falls back to what the session reports (nil until system/init).
    var projectCwd: String? = nil

    private let bottomAnchorID = "v2-transcript-bottom"

    /// Render window: only the most recent N transcript items are in the
    /// layout by default. A long chat's scroll weirdness is LazyVStack
    /// ESTIMATING the heights of hundreds of unbuilt rows above the viewport
    /// — every estimate revision recomputes the scrollbar and shifts content,
    /// which is why an old chat felt broken while a fresh tab was fine. With
    /// a capped window, a month-old conversation scrolls exactly like a new
    /// one; "show earlier" extends the window on demand. Data is untouched —
    /// this bounds LAYOUT, not history.
    // Static STORED properties aren't allowed in a generic type — computed
    // instead, same constant value either way.
    private static var renderWindow: Int { 120 }

    /// The window's start index — set ONCE per conversation (init, or the
    /// session-switch handler below), never continuously recomputed from
    /// live transcript.count. It used to be a computed property re-deriving
    /// `count - renderWindow` on every render — meaning in a conversation
    /// past 120 items, EVERY new appended message also dropped the oldest
    /// rendered row off the top to keep the window size constant. Scrolling
    /// near that boundary while a reply was actively streaming meant rows
    /// were appearing/disappearing under the cursor in real time — the
    /// "bounces and bounces" report. The cap only ever needed to bound the
    /// INITIAL layout cost of a long resumed chat; once a conversation is
    /// open, new messages should just extend the window's end, never slide
    /// its start out from under an active scroll.
    @State private var firstVisibleIndex: Int

    init(session: Session, projectCwd: String? = nil) {
        self.session = session
        self.projectCwd = projectCwd
        _firstVisibleIndex = State(initialValue: max(0, session.transcript.count - Self.renderWindow))
    }

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
                    if firstVisibleIndex > 0 {
                        showEarlierButton
                    }
                    // Index-keyed identity: the transcript is append-only with
                    // the last text block mutated in place while streaming.
                    // Content-hash ids changed every token (tearing down and
                    // rebuilding the streaming row + resetting text selection);
                    // a stable ABSOLUTE index keeps the row alive as its text
                    // grows — and stays stable as the render window slides.
                    // Per-list lookups built ONCE here, not per row (perf §4).
                    // uniquingKeysWith, NOT uniqueKeysWithValues: the latter
                    // is a fatal crash on a duplicate key, and this must
                    // never bring down the transcript even if subagentRuns
                    // ever ends up with one (belt-and-suspenders alongside
                    // the append-site guard in StreamSession).
                    let runsById = Dictionary(
                        session.subagentRuns.map { ($0.toolUseId, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    let sessionDir = session.sessionDir
                    // Clamped here, not just reset reactively by the
                    // .onChange below: on the SAME render where a tab switch
                    // swaps `session` to a new object, `firstVisibleIndex` is
                    // still whatever the PREVIOUS tab left it at — .onChange
                    // only fires as a reaction AFTER this render commits.
                    // Switching from a long conversation to a shorter one
                    // could momentarily pair a stale, too-high start index
                    // with the new session's (smaller) transcript.count —
                    // `a..<b` traps if a > b, and a tab that always hits this
                    // during the switch would read as "I moved to a tab and
                    // the messages never show" (the row it settles into
                    // right after recovering is silently wrong too, since
                    // the reactive reset lands one render late). Clamping the
                    // window's bounds to what's actually valid THIS render
                    // makes the row list correct immediately, every time —
                    // the .onChange below still fixes up the @State itself
                    // so scroll position stays sane on the next interaction.
                    let windowStart = min(max(0, firstVisibleIndex), session.transcript.count)
                    // Only the LAST row can be mutating in place (streaming
                    // appends to / grows the tail item); every earlier row is
                    // frozen. The flag routes the streaming row through the
                    // per-block renderer (O(tail-paragraph) per flush) instead
                    // of the merged-run renderer (O(whole-message) per flush —
                    // the "sloppy scroll / content vanishing while replying"
                    // regression #72 shipped with).
                    let streamingIndex = session.state == .working ? session.transcript.count - 1 : -1
                    ForEach(windowStart..<session.transcript.count, id: \.self) { i in
                        row(for: session.transcript[i], runs: runsById, sessionDir: sessionDir,
                            isStreaming: i == streamingIndex)
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
            // Bottom anchoring is the SYSTEM's job, not ours. This is Apple's
            // chat/console API: at the bottom → content stays bottom-anchored
            // as it grows, maintained DURING layout (no scrollTo corrections,
            // so the scrollbar never dances); scrolled up → the view holds
            // still; scrolled back to the bottom → anchoring re-engages.
            // History: v1 scrollTo'd per streamTick unconditionally (yanked
            // the reader ~30×/s); v2 gated it on hand-tracked pinned state,
            // which stopped the yank but kept per-tick post-layout scrollTo
            // corrections + LazyVStack height re-estimation = visible
            // scrollbar jitter even in an idle open chat. Anchoring at layout
            // time replaces both.
            .defaultScrollAnchor(.bottom)
            // Sending a message is an unambiguous "take me to the reply" —
            // jump even if the user had scrolled up. Only fires on .userText
            // appends: rows the agent appends mid-turn never steal the
            // scroll position.
            .onChange(of: session.transcript.count) { _, _ in
                if case .userText = session.transcript.last {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            // Tab switch: the view identity is intentionally kept (rebuilding
            // the whole tree per switch was the tab-lag), so the SESSION
            // changes under this view. Reset the render window and land at
            // the new conversation's bottom — scroll state never bleeds.
            // Keyed on instanceId, NOT ObjectIdentifier(session): malloc can
            // give a new session a deallocated one's address, making the
            // identifiers compare equal — this onChange then never fired for
            // the new session, the stale window rendered zero rows, and the
            // tab showed an empty chat until app restart (see instanceId's
            // doc comment on StreamSession).
            .onChange(of: session.instanceId) { _, _ in
                firstVisibleIndex = max(0, session.transcript.count - Self.renderWindow)
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

    /// Top-of-window expander: the older rows exist in data, just not in the
    /// layout. Extending re-renders with a bigger window; identity is
    /// absolute-index so existing rows don't rebuild.
    private var showEarlierButton: some View {
        Button { firstVisibleIndex = max(0, firstVisibleIndex - 300) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .medium))
                Text("show \(min(firstVisibleIndex, 300)) earlier messages · \(firstVisibleIndex) hidden")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(v2.mute)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(v2.paper2)
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
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
    /// How long a streaming reply can go quiet before the stall cue kicks
    /// in. Short enough to reassure before the user gets anxious; long
    /// enough that normal inter-token/inter-sentence gaps never flash it.
    private static var stallThreshold: TimeInterval { 4 }

    @ViewBuilder
    private var workingIndicator: some View {
        let hasStreamingText: Bool = {
            if case .assistantBlock(.text) = session.transcript.last { return true }
            return false
        }()
        if hasStreamingText {
            // Reply is streaming — normally the growing text IS the
            // indicator, so keep just a single cheap pulse. But a stall
            // mid-reply (rate limiting, a slow tool call embedded in the
            // same turn, a network hiccup) used to be visually IDENTICAL
            // to a finished reply — nothing ticked, nothing said "still
            // alive". Poll once a second (TimelineView, not @Published —
            // no extra republish load) and surface the same "still alive"
            // promise the pre-first-token state already makes once it's
            // actually been quiet a while.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let quiet = ctx.date.timeIntervalSince(session.lastStreamActivityAt)
                if quiet >= Self.stallThreshold {
                    HStack(spacing: 9) {
                        V2PulseDot(size: 7, color: v2.ink)
                        Text("Still working… \(Int(quiet))s since last update")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(v2.mute)
                    }
                    .padding(.top, 2)
                } else {
                    V2PulseDot(size: 6, color: v2.faint)
                        .padding(.top, 2)
                }
            }
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

    @ViewBuilder
    private func row(for item: TranscriptItem, runs: [String: V2SubagentRun], sessionDir: URL?,
                     isStreaming: Bool = false) -> some View {
        switch item {
        case .userText(let text):
            V2UserTurn(text: text)
        case .assistantBlock(let block):
            V2AssistantBlock(block: block, toolOutcomes: session.toolOutcomes,
                             baseDir: session.baseDir ?? projectCwd,
                             subagentRuns: runs, sessionDir: sessionDir,
                             toolStartTimes: session.toolStartTimes,
                             toolLiveStatus: session.toolLiveStatus,
                             taskItems: session.taskItems,
                             isStreaming: isStreaming,
                             provider: session.provider)
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
                // Provider is a visual cue here (accent-colored mark), not a
                // second rendering path — same component Chrome uses for
                // both providers' badges elsewhere in the app.
                V2ProviderMark(provider: session.provider, size: 28)
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
        case .spawning:           return "Spawning \(session.provider.displayName)…"
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
    /// toolUseId → run, for rendering Task/Agent tool calls as delegation
    /// cards (#38). Built once per transcript body eval, not per row.
    var subagentRuns: [String: V2SubagentRun] = [:]
    var sessionDir: URL? = nil
    /// toolUseId → call start, for the in-flight elapsed readout.
    var toolStartTimes: [String: Date] = [:]
    /// toolUseId → latest live progress message (Codex MCP calls only).
    var toolLiveStatus: [String: String] = [:]
    /// Session task checklist, current as of now — every TaskCreate/
    /// TaskUpdate row shows the SAME live list rather than a per-call
    /// historical snapshot (see V2LiveTaskChecklist's doc comment).
    var taskItems: [V2TaskItem] = []
    /// This row's text is still growing — see V2MarkdownText.isStreaming.
    var isStreaming: Bool = false
    /// Visual cue only — every row renders through this identical component
    /// regardless of provider; only the leading mark's asset/accent differs.
    var provider: V2AgentProvider = .claude
    @State private var buttonHover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            V2ProviderMark(provider: provider, size: 18)
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
                    // Right-click → copy the WHOLE message. Finalized prose
                    // selects across paragraphs (#72 merged runs), but code
                    // fences/tables still bound selection to their own view,
                    // and the actively-streaming message renders per-block —
                    // this stays the universal escape hatch either way.
                    .contextMenu {
                        if let t = textForCopy {
                            Button("Copy message") { V2Clipboard.copy(t) }
                        }
                    }
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
            V2MarkdownText(text: s, baseDir: baseDir, isStreaming: isStreaming)
                .foregroundColor(v2.ink)
        case .toolUse(let id, let name, let input):
            if V2SubagentParser.isAgentSpawn(toolName: name) {
                V2DelegationCard(
                    run: subagentRuns[id],
                    toolUseId: id,
                    fallbackDescription: input.dig("description")?.asString ?? "agent",
                    fallbackAgentType: input.dig("subagent_type")?.asString ?? "agent",
                    sessionDir: sessionDir
                )
            } else if name == "TodoWrite", let todos = input.dig("todos")?.asArray {
                V2LiveTaskChecklist(items: todos.map {
                    V2TaskItem(id: $0.dig("content")?.asString ?? UUID().uuidString,
                               subject: $0.dig("content")?.asString ?? "",
                               status: $0.dig("status")?.asString ?? "pending")
                })
            } else if name == "TaskCreate" || name == "TaskUpdate" {
                V2LiveTaskChecklist(items: taskItems)
            } else {
                V2LiveToolWidget(name: name, input: input, outcome: toolOutcomes[id],
                                 startedAt: toolStartTimes[id], liveStatus: toolLiveStatus[id])
            }
        case .toolResult(_, let content, let isError):
            V2LiveToolResult(content: content, isError: isError ?? false)
        case .thinking(let text, _):
            V2LiveThinkingBlock(text: text)
        case .image(let mediaType):
            // A pasted/attached image. The base64 payload is dropped at
            // decode (see ContentBlock.image) so this is a labeled chip,
            // not a thumbnail — honest about what it is without retaining
            // megabytes per screenshot for the window's lifetime.
            HStack(spacing: 7) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(v2.mute)
                Text("image\(mediaType.map { " · \($0.replacingOccurrences(of: "image/", with: ""))" } ?? "")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(v2.paper2)
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        case .fallback(let from, let to):
            // Normally routed to a systemNote before reaching here (see
            // StreamSession); kept renderable so the block is never a
            // bracketed mystery if it arrives through another path.
            Text("model fallback: \(from ?? "?") → \(to ?? "?")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.mute)
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
    /// When the call started (nil for history-preloaded rows). Lets a
    /// long-running call show elapsed time — without it, minute five of a
    /// test run rendered identically to second five, and identically to a
    /// hung command ("I can't see this or its progress").
    var startedAt: Date? = nil
    /// Latest human-readable progress message while still running (Codex's
    /// mcpToolCall/progress notifications carry these; Claude's MCP protocol
    /// doesn't surface an equivalent today, so this stays nil there).
    var liveStatus: String? = nil

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
        case .none:
            if let startedAt {
                // 1Hz tick scoped to THIS row, and only while in flight —
                // at most a handful of tool calls are ever unresolved at
                // once, so this stays within the strip/header's existing
                // TimelineView budget (no per-token cost).
                TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                    let secs = Int(ctx.date.timeIntervalSince(startedAt))
                    HStack(spacing: 6) {
                        V2Spinner(size: 11)
                        if let liveStatus {
                            Text(liveStatus)
                                .foregroundColor(v2.faint)
                                .lineLimit(1).truncationMode(.tail)
                        // Quiet for quick calls — the timer only fades in
                        // once a call has run long enough (≥3s) that "is it
                        // stuck or working?" becomes a real question.
                        } else if secs >= 3 {
                            Text("\(secs / 60):" + String(format: "%02d", secs % 60))
                                .foregroundColor(v2.faint)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                V2Spinner(size: 11)
            }
        case .some(false): Text("✓").foregroundColor(v2.add)
        case .some(true):  Text("✗").foregroundColor(v2.del)
        }
    }

    @ViewBuilder
    private var target: some View {
        switch name {
        case "Bash", "PowerShell":
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
        case "WebFetch":
            V2Token(input.dig("url")?.asString ?? input.preview)
        case "Skill":
            V2Token(input.dig("skill")?.asString ?? input.preview)
        case "AskUserQuestion":
            Text(Self.firstQuestionSummary(input))
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
        case "ReportFindings":
            Text(Self.findingsSummary(input))
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
        case "WaitForMcpServers":
            Text(Self.serverListSummary(input))
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
        // No meaningful arguments to summarise — these are bare "do the
        // thing" calls, so a plain label beats a preview that would just
        // show "{}" with no explanation of what's actually happening.
        case "CronList":
            Text("list scheduled tasks").foregroundColor(v2.mute)
        case "EnterPlanMode":
            Text("entering plan mode").foregroundColor(v2.mute)
        case "ExitWorktree":
            // Verified schema: {action: "keep"|"remove", discard_changes}. Not
            // argless like it looked at first glance — which one happened is
            // exactly the thing worth seeing here.
            Text("exit worktree · \(input.dig("action")?.asString ?? "keep")")
                .foregroundColor(v2.mute)
        case "ShareOnboardingGuide":
            Text("sharing onboarding guide").foregroundColor(v2.mute)
        case "TaskList":
            Text("list tasks").foregroundColor(v2.mute)
        case _ where name.hasPrefix("mcp__"):
            mcpTarget
        default:
            Text(Self.primaryField(for: name, in: input) ?? input.preview)
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
        }
    }

    /// ReportFindings' real shape is `findings: [{file, summary, ...}]` —
    /// the summary text lives inside each array element, not at the top
    /// level, so a primaryFieldsByTool lookup for "summary" can never match.
    private static func findingsSummary(_ input: JSONValue) -> String {
        guard let findings = input.dig("findings")?.asArray, !findings.isEmpty else { return input.preview }
        let first = findings[0].dig("summary")?.asString ?? "finding"
        let suffix = findings.count > 1 ? " (+\(findings.count - 1) more)" : ""
        return Self.truncate(first) + suffix
    }

    /// `servers` is an array of names, not a string — a primaryFieldsByTool
    /// lookup (which only unwraps .string) can never match it either.
    private static func serverListSummary(_ input: JSONValue) -> String {
        guard let servers = input.dig("servers")?.asArray, !servers.isEmpty else { return input.preview }
        return servers.compactMap(\.asString).joined(separator: ", ")
    }

    /// "server · tool" instead of the raw `mcp__server__tool` name — MCP
    /// calls used to fall to the exact same generic path as an unhandled
    /// built-in, with no split between server and tool at all.
    private var mcpTarget: some View {
        // mcp__<server>__<tool> — server/tool can themselves contain
        // underscores, so split only on the double-underscore delimiters,
        // not every underscore.
        let stripped = name.hasPrefix("mcp__") ? String(name.dropFirst(5)) : name
        let components = stripped.components(separatedBy: "__")
        let server = components.first ?? "mcp"
        let tool = components.count > 1 ? components.dropFirst().joined(separator: "__") : ""
        return HStack(spacing: 8) {
            Text(server).foregroundColor(v2.mute)
            if !tool.isEmpty {
                Text("·").foregroundColor(v2.faint)
                Text(tool).foregroundColor(v2.ink)
            }
        }
        .lineLimit(1).truncationMode(.middle)
    }

    /// For tools without a fully custom target view, the primary field to
    /// surface from their JSON input — checked in order, first non-empty
    /// string wins. Keeps new tools cheap to support: one line here instead
    /// of a bespoke view. Anything not listed still gets a real (not
    /// keys-only) preview via JSONValue.preview's fixed object case.
    private static let primaryFieldsByTool: [String: [String]] = [
        // Verified against real tool schemas (ToolSearch) where reachable
        // from this session — CronCreate, CronDelete, ListMcpResourcesTool,
        // ReadMcpResourceTool, SendMessage, TaskGet, and the TaskOutput/
        // TaskStop fix below all came from a live schema, not a guess.
        "Artifact": ["title", "type"],   // unverified — not reachable from here (needs a claude.ai Pro/Max/Team/Enterprise login this session doesn't have)
        "CronCreate": ["prompt"],
        "CronDelete": ["id"],
        "EnterWorktree": ["path", "name"],   // "path" when entering an existing worktree, "name" when creating one
        "ExitPlanMode": ["plan"],
        "ListMcpResourcesTool": ["server"],
        "LSP": ["command", "symbol", "file"],   // unverified — needs a code-intelligence plugin this session doesn't have installed
        "Monitor": ["description", "command"],
        "PushNotification": ["message"],
        "ReadMcpResourceTool": ["uri"],
        "RemoteTrigger": ["action"],
        // ReportFindings and WaitForMcpServers are NOT here — their real
        // fields aren't flat strings (findings[].summary is nested one
        // level deep; servers is an array, not a string), so a lookup in
        // this table could never match either. They get their own cases
        // above instead of a dead entry that looks like coverage but isn't.
        "ScheduleWakeup": ["reason"],
        "SendMessage": ["to", "message"],
        "SendUserFile": ["path", "caption"],   // unverified — needs a Remote Control client or cloud environment this session doesn't have
        // TaskCreate/TaskUpdate are NOT here either — both are intercepted
        // upstream by the checklist routing in V2AssistantBlock.content,
        // before this switch ever sees them.
        "TaskGet": ["taskId"],
        // TaskOutput/TaskStop are a DIFFERENT tool family from TaskCreate/
        // TaskGet/TaskUpdate (background-task management, not the todo
        // checklist) despite the shared "Task" name — confirmed via their
        // real schemas: task_id (snake_case), not taskId. This was a real
        // bug, not just an unverified guess: the original ["taskId"] entry
        // could never match, same class of dead lookup as ReportFindings'
        // original "summary" guess.
        "TaskOutput": ["task_id"],
        "TaskStop": ["task_id"],
        "ToolSearch": ["query"],
        "WebSearch": ["query"],
        "Workflow": ["name"],
    ]

    private static func primaryField(for name: String, in input: JSONValue) -> String? {
        for key in primaryFieldsByTool[name] ?? [] {
            if let s = input.dig(key)?.asString, !s.isEmpty { return Self.truncate(s) }
        }
        return nil
    }

    private static func firstQuestionSummary(_ input: JSONValue) -> String {
        guard let questions = input.dig("questions")?.asArray, let first = questions.first else {
            return input.preview
        }
        let q = first.dig("question")?.asString ?? first.dig("header")?.asString ?? "question"
        let suffix = questions.count > 1 ? " (+\(questions.count - 1) more)" : ""
        return Self.truncate(q) + suffix
    }

    private static func truncate(_ s: String, to limit: Int = 90) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
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

/// The agent-vocabulary task checklist: completed = sage fill + strikethrough,
/// in-progress = pulsing dot, pending = empty box. Shared by both TodoWrite
/// (each call is a complete, self-contained list) and TaskCreate/TaskUpdate
/// (StreamSession.taskItems accumulates the current state across calls,
/// since Claude Code v2.1.142+ replaced TodoWrite's "resend everything"
/// model with incremental create/update calls — see StreamSession's
/// recordTaskToolUse/recordTaskResult).
struct V2LiveTaskChecklist: View {
    @Environment(\.v2) private var v2
    let items: [V2TaskItem]

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
                        Text(t.subject)
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
        // Rounded, not truncated: integer division here silently dropped up
        // to 999ms off every turn's displayed duration (6535ms → "6s"
        // instead of "7s") — a one-time computation from a fixed wire
        // value, unlike a live ticking counter where truncation
        // self-corrects on the next tick.
        let seconds = Int((Double(ms) / 1000).rounded())
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
