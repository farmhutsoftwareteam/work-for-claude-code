// Delegation card (#38) + subagent peek (#39) — interim chrome ahead of the
// design artifact (same logic-first path bg-tasks took). A Task/Agent
// tool_use renders as a card that says WHO is working on WHAT, with a live
// one-line tail of the agent's current action; clicking opens a peek that
// follows the agent's own transcript, and shows its final report once done.

import SwiftUI
import Inject

struct V2DelegationCard: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    /// Nil when this block was restored from history (the run registry only
    /// populates from live events) — the card degrades to a static row, and
    /// the peek still works because meta.json resolution is by toolUseId.
    let run: V2SubagentRun?
    let toolUseId: String
    let fallbackDescription: String
    let fallbackAgentType: String
    let sessionDir: URL?

    @State private var peeking = false
    /// Refreshed off the main thread once a second while running — see
    /// `refreshLiveAction()` (bug-hunt M22).
    @State private var liveActionText: String?

    private var description: String { run?.description ?? fallbackDescription }
    private var agentType: String { run?.agentType ?? fallbackAgentType }
    private var isRunning: Bool { run?.state == .running }

    var body: some View {
        Button { peeking = true } label: {
            Group {
                if isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        cardRow(now: ctx.date)
                            .task(id: ctx.date) { await refreshLiveAction() }
                    }
                } else {
                    cardRow(now: Date())
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $peeking) {
            V2SubagentPeekSheet(
                run: run, toolUseId: toolUseId,
                description: description, agentType: agentType,
                sessionDir: sessionDir
            )
        }
        .enableInjection()
    }

    private func cardRow(now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if isRunning {
                    V2PulseDot(size: 7, color: v2.ink)
                } else {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
            }
            .frame(width: 10, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(description)
                        .font(.system(size: 13, weight: .medium))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                        .lineLimit(1)
                    Text("agent · \(agentType)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Spacer(minLength: 4)
                    Text(trailingText(now: now))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(trailingColor)
                }
                if isRunning {
                    Text(liveActionText ?? "working…")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// The agent's most recent action off its transcript tail — bounded
    /// read at the card's 1Hz tick, only while running. Publishes nil until
    /// the transcript file appears on disk (a beat after spawn).
    ///
    /// Off the main thread (bug-hunt M22): this used to stat+read+parse
    /// synchronously on the main actor every tick, once per VISIBLE card —
    /// N concurrent delegation cards multiplied that main-thread cost every
    /// second. A plain `.task {}` here would NOT leave the main actor (this
    /// View, like every SwiftUI View, is implicitly MainActor-isolated by
    /// inference from `body`) — `Task.detached` is what actually hops off,
    /// and we hop back only to publish the result into `@State`.
    private func refreshLiveAction() async {
        guard let sessionDir else { return }
        let toolUseId = toolUseId
        let agentId = run?.agentId
        let text = await Task.detached(priority: .utility) { () -> String? in
            guard let path = V2SubagentTail.transcript(
                sessionDir: sessionDir, toolUseId: toolUseId, agentId: agentId)
            else { return nil }
            return V2SubagentTail.lastAction(path: path)
        }.value
        if !Task.isCancelled { liveActionText = text }
    }

    private var dotColor: Color {
        switch run?.state {
        case .completed:        return v2.add
        case .failed:           return v2.del
        case .orphaned, .none:  return v2.line2
        case .running:          return v2.ink
        }
    }

    private func trailingText(now: Date) -> String {
        guard let run else { return "earlier session" }
        switch run.state {
        case .running:
            return Self.mmss(now.timeIntervalSince(run.startedAt))
        case .completed:
            return "done ✓ \(durationText(run))"
        case .failed:
            return "failed ✗ \(durationText(run))"
        case .orphaned:
            return "session ended — outcome unknown"
        }
    }

    private var trailingColor: Color {
        switch run?.state {
        case .completed: return v2.add
        case .failed:    return v2.del
        default:         return v2.faint
        }
    }

    private func durationText(_ run: V2SubagentRun) -> String {
        guard let f = run.finishedAt else { return "" }
        return Self.mmss(f.timeIntervalSince(run.startedAt))
    }

    private static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Peek sheet (#39)

struct V2SubagentPeekSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss

    let run: V2SubagentRun?
    let toolUseId: String
    let description: String
    let agentType: String
    let sessionDir: URL?

    @State private var feed: [String] = []
    @State private var transcriptPath: URL?

    private var isRunning: Bool { run?.state == .running }

    var body: some View {
        Group {
            if isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    sheetBody(now: ctx.date)
                        .task(id: ctx.date) { await refresh() }
                }
            } else {
                sheetBody(now: Date())
            }
        }
        .frame(width: 780, height: 520)
        .background(v2.paper2)
        .task { await refresh() }
        .onExitCommand { dismiss() }
        .enableInjection()
    }

    private func sheetBody(now: Date) -> some View {
        VStack(spacing: 0) {
            header(now: now)
            content
            footer
        }
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(description)
                    .font(.system(size: 14, weight: .medium))
                    .kerning(-0.14)
                Text(metaText(now: now))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            if isRunning {
                HStack(spacing: 6) {
                    V2PulseDot(size: 6, color: v2.ink)
                    Text("following")
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.mute)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func metaText(now: Date) -> String {
        let base = "agent · \(agentType)"
        guard let run else { return base + " · earlier session" }
        switch run.state {
        case .running:
            return base + " · running · \(Self.mmss(now.timeIntervalSince(run.startedAt))) elapsed"
        case .completed:
            return base + " · finished ✓"
        case .failed:
            return base + " · failed ✗"
        case .orphaned:
            return base + " · session ended while running — outcome unknown"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let result = run?.resultText, !isRunning {
            // Finished: the final report is the payload that matters.
            ScrollView {
                V2MarkdownText(text: result, baseDir: sessionDir?.path)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if feed.isEmpty {
            VStack(spacing: 6) {
                Text(isRunning ? "waiting for the agent's first action…" : "no transcript found for this agent")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(feed.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(line.hasPrefix("›") ? v2.mute : v2.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("subagent-peek-bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color.black.opacity(0.03))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(transcriptPath?.path ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("esc to close")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: Refresh

    /// Off the main thread (bug-hunt M22) — same rationale as
    /// V2DelegationCard.refreshLiveAction(): resolution + a bounded tail
    /// read + JSONL parse, hopped via Task.detached, published on return.
    private func refresh() async {
        guard let sessionDir else { return }
        let toolUseId = toolUseId
        let agentId = run?.agentId
        let knownPath = transcriptPath
        let (path, fresh) = await Task.detached(priority: .utility) { () -> (URL?, [String]) in
            let path = knownPath ?? V2SubagentTail.transcript(
                sessionDir: sessionDir, toolUseId: toolUseId, agentId: agentId)
            guard let path else { return (nil, []) }
            return (path, V2SubagentTail.activity(path: path))
        }.value
        guard !Task.isCancelled else { return }
        if transcriptPath == nil { transcriptPath = path }
        if path != nil, fresh != feed { feed = fresh }
    }

    private static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
