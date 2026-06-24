// Live transcript driven off a real StreamSession. Replaces V2TranscriptView's
// mock content. Each TranscriptItem maps to a SwiftUI row; assistant text
// blocks render token-by-token as deltas arrive.

import SwiftUI
import Inject

struct V2LiveTranscript: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if session.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(session.transcript) { item in
                        row(for: item)
                            .id(item.id)
                    }

                    if session.isRetrying {
                        V2ApiRetryInline(info: session.lastRetry)
                            .animation(.easeOut(duration: 0.2), value: session.isRetrying)
                    }

                    if let result = session.latestResult {
                        V2LiveResultFooter(result: result, sessionId: session.sessionId)
                    }

                    if session.state == .working {
                        V2LoadingSkeleton()
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 24)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .onChange(of: session.transcript.count) { _, _ in
                if let last = session.transcript.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
        .enableInjection()
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .userText(let text):
            V2UserTurn(text: text)
        case .assistantBlock(let block):
            V2AssistantBlock(block: block)
        case .compactBoundary:
            V2CompactBoundary()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            V2DovetailMark(size: 28).foregroundColor(v2.faint)
            Text(emptyHint)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.faint)
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

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            V2DovetailMark(size: 18)
                .foregroundColor(v2.ink)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .text(let s):
            V2MarkdownText(text: s)
                .foregroundColor(v2.ink)
        case .toolUse(_, let name, let input):
            V2LiveToolWidget(name: name, input: input)
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

    var body: some View {
        HStack(spacing: 11) {
            V2Pill(text: name.uppercased())
            Text(previewText)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("running")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var previewText: String {
        switch name {
        case "Bash":           return input.dig("command")?.asString ?? input.preview
        case "Edit", "Write":  return input.dig("file_path")?.asString ?? input.preview
        case "Read":           return input.dig("file_path")?.asString ?? input.preview
        case "Grep":           return input.dig("pattern")?.asString ?? input.preview
        case "Glob":           return input.dig("pattern")?.asString ?? input.preview
        default:               return input.preview
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

    var body: some View {
        HStack(spacing: 16) {
            Text("\(result.numTurns ?? 0) turns")
            Text(durationText)
            if let cost = result.totalCostUsd {
                Text(String(format: "$%.4f", cost))
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
