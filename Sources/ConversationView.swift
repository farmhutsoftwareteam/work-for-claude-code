import SwiftUI
import MarkdownUI
import AppKit

// MARK: - Conversation view (inline in detail pane)

struct ConversationView: View {
    let session: Session
    @EnvironmentObject var store: Store
    @StateObject private var searchModel = ConversationSearchModel()

    @State private var messages: [ChatMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var handoffState: HandoffGenerator.HandoffState = .idle
    @State private var showHandoff = false

    /// Memoized search-reordered list. Previously rebuilt the Dictionary
    /// and re-sorted every body re-eval — for 500+ message conversations
    /// that's per-frame O(n log n) when search is active.
    @State private var displayedMessages: [ChatMessage] = []

    private var project: Project? {
        store.projects.first { $0.cwd == session.projectCwd }
    }

    private var isSearchActive: Bool {
        !searchModel.query.isEmpty && !searchModel.results.isEmpty
    }

    /// Recompute displayed-message ordering once when inputs change.
    private func rebuildDisplayedMessages() {
        guard !searchModel.query.isEmpty, !searchModel.results.isEmpty else {
            displayedMessages = messages
            return
        }
        let order = Dictionary(uniqueKeysWithValues: searchModel.results.enumerated().map { ($1.messageId, $0) })
        displayedMessages = messages
            .filter { order[$0.id] != nil }
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — visible once indexing is ready
            if case .ready = searchModel.indexingState {
                searchBar
            }

            // Indexing progress bar
            if case .indexing(let progress) = searchModel.indexingState {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("Indexing conversation…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            // Main content
            Group {
                if isLoading {
                    ProgressView("Loading conversation…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = loadError {
                    ContentUnavailableView(
                        "Couldn't load conversation",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if messages.isEmpty {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: "bubble.left",
                        description: Text("This session has no readable text messages.")
                    )
                } else if isSearchActive && displayedMessages.isEmpty {
                    ContentUnavailableView.search(text: searchModel.query)
                } else {
                    messageList
                }
            }
        }
        .navigationTitle(session.slug ?? String(session.id.prefix(8)))
        .navigationSubtitle(project.map { $0.displayName } ?? session.projectCwd)
        .toolbar { toolbarContent }
        .task(id: session.id) {
            searchModel.reset()
            await loadMessages()
        }
        .onChange(of: searchModel.query) { _, _ in
            searchModel.scheduleSearch()
            rebuildDisplayedMessages()
        }
        .onChange(of: searchModel.results.count) { _, _ in
            rebuildDisplayedMessages()
        }
        .onChange(of: messages.count) { _, _ in
            rebuildDisplayedMessages()
        }
        .alert("Handoff Copied", isPresented: $showHandoff) {
            Button("OK") { }
        } message: {
            Text("Session summary copied to clipboard. Paste it into any LLM to continue the work.")
        }
        .alert("Handoff Failed", isPresented: Binding(
            get: { if case .failed = handoffState { return true } else { return false } },
            set: { if !$0 { handoffState = .idle } }
        )) {
            Button("OK") { handoffState = .idle }
        } message: {
            if case .failed(let err) = handoffState {
                Text(err)
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            TextField("Search conversation…", text: $searchModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchModel.query.isEmpty {
                Button {
                    searchModel.query = ""
                    searchModel.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                store.selectedSessionForViewing = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                generateHandoff()
            } label: {
                switch handoffState {
                case .generating:
                    ProgressView()
                        .controlSize(.small)
                default:
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .help("Generate a handoff summary for a teammate")
            .disabled(messages.isEmpty || handoffState == .generating)
        }

        if let project {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Launcher.resumeOrFocus(session, in: project)
                } label: {
                    Label("Start in Terminal", systemImage: "play.fill")
                }
                .help("Resume this session in Terminal")
            }
        }
    }

    private func generateHandoff() {
        handoffState = .generating
        HandoffGenerator.generate(
            session: session,
            project: project,
            messages: messages
        ) { state in
            handoffState = state
            if case .done(let summary) = state {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
                showHandoff = true
            }
        }
    }

    // MARK: - Message list

    /// Determine whether a message starts a new "turn" (speaker changed from previous).
    /// Tool use/results are part of the assistant's turn and don't create new headers.
    private func isNewTurn(at index: Int) -> Bool {
        let msgs = displayedMessages
        guard index > 0 else { return true }
        let current = msgs[index]
        let previous = msgs[index - 1]

        // Tool calls and results are always part of the assistant turn
        switch current.kind {
        case .toolUse: return false
        case .toolResult: return false
        case .text:
            // Text after a tool result is still the same assistant turn
            switch previous.kind {
            case .toolUse, .toolResult:
                return current.role != .assistant
            case .text:
                return current.role != previous.role
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearchActive {
                        Text("\(displayedMessages.count) result\(displayedMessages.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 8)
                    }

                    ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, msg in
                        let newTurn = isNewTurn(at: index)

                        MessageRow(
                            message: msg,
                            isFirstInTurn: newTurn,
                            highlightQuery: isSearchActive ? searchModel.query : nil
                        )
                        .id(msg.id)
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .onAppear {
                guard !isSearchActive else { return }
                DispatchQueue.main.async {
                    // Re-check inside the async block: the user may have
                    // activated search between onAppear and this fire.
                    guard !isSearchActive, let last = messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - JSONL loader

    private func loadMessages() async {
        isLoading = true
        loadError = nil

        let cwd = session.projectCwd
        let sessionId = session.id
        let home = FileManager.default.homeDirectoryForCurrentUser

        let expectedId = session.id
        let result = await Task.detached(priority: .userInitiated) { () -> ([ChatMessage], String?) in
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonlURL = home
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
                .appendingPathComponent(encoded)
                .appendingPathComponent(sessionId + ".jsonl")

            // Memory-map the file and walk line boundaries directly. The old
            // `String(data:encoding:)` + `text.split("\n")` materialised the
            // full file as a native Swift String — a 191MB session JSONL
            // produced a ~400-500MB peak heap allocation just to start
            // parsing. The byte-walk below mirrors UsageAggregator's pattern
            // and emits one `Data` per line, so the mmap'd region is the
            // only large allocation that stays resident.
            guard let data = try? Data(contentsOf: jsonlURL, options: .mappedIfSafe) else {
                return ([], "Session file not found at:\n\(jsonlURL.path)")
            }

            // Track the last tool name for matching results to their calls
            var lastToolNames: [String: String] = [:] // tool_use_id -> tool name
            var parsed: [ChatMessage] = []

            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = rawBuf.count
                var lineStart = 0
                for i in 0..<count where base[i] == 0x0A /* '\n' */ {
                    var lineEnd = i
                    if lineEnd > lineStart && base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                    if lineEnd > lineStart {
                        let lineData = Data(bytes: base.advanced(by: lineStart), count: lineEnd - lineStart)
                        Self.processConversationLine(
                            lineData,
                            parsed: &parsed,
                            lastToolNames: &lastToolNames
                        )
                    }
                    lineStart = i + 1
                }
                if lineStart < count {
                    let tail = Data(bytes: base.advanced(by: lineStart), count: count - lineStart)
                    Self.processConversationLine(
                        tail,
                        parsed: &parsed,
                        lastToolNames: &lastToolNames
                    )
                }
            }

            return (parsed, nil)
        }.value

        guard session.id == expectedId else { return }
        messages = result.0
        loadError = result.1
        isLoading = false

        // Begin indexing for semantic search
        if !messages.isEmpty {
            await searchModel.beginIndexing(sessionId: session.id, cwd: session.projectCwd, messages: messages)
        }
    }

    // MARK: - Per-line parser
    //
    // Decode one JSONL line into 0…N ChatMessage values appended to `parsed`.
    // Pulled out of `loadMessages` so the byte-walk loop stays tight and so
    // the parser is a static, captured-context-free function (no `self`
    // retention from the detached task). `nonisolated` so the detached
    // task can call it without hopping back to the main actor.
    fileprivate nonisolated static func processConversationLine(
        _ lineData: Data,
        parsed: inout [ChatMessage],
        lastToolNames: inout [String: String]
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let typeStr = obj["type"] as? String,
              typeStr == "user" || typeStr == "assistant",
              let message = obj["message"] as? [String: Any] else { return }

        let role: ChatMessage.Role = typeStr == "user" ? .user : .assistant

        // Simple string content (no content-block array)
        guard let contentArray = message["content"] as? [[String: Any]] else {
            if let contentStr = message["content"] as? String {
                let trimmed = contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parsed.append(ChatMessage(id: UUID(), role: role, kind: .text(content: trimmed)))
                }
            }
            return
        }

        for block in contentArray {
            let blockType = block["type"] as? String ?? ""

            switch blockType {
            case "text":
                let txt = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty {
                    parsed.append(ChatMessage(id: UUID(), role: role, kind: .text(content: txt)))
                }

            case "tool_use":
                let toolName = block["name"] as? String ?? "unknown"
                let toolId = block["id"] as? String ?? ""
                lastToolNames[toolId] = toolName
                var inputSummary = ""
                if let input = block["input"] as? [String: Any] {
                    if let cmd = input["command"] as? String {
                        inputSummary = cmd
                    } else if let path = input["file_path"] as? String {
                        inputSummary = path
                    } else if let pattern = input["pattern"] as? String {
                        inputSummary = pattern
                    } else if let prompt = input["prompt"] as? String {
                        inputSummary = String(prompt.prefix(120))
                    } else if let query = input["query"] as? String {
                        inputSummary = query
                    }
                }
                parsed.append(ChatMessage(
                    id: UUID(), role: .assistant,
                    kind: .toolUse(tool: toolName, input: inputSummary)
                ))

            case "tool_result":
                let toolId = block["tool_use_id"] as? String ?? ""
                let toolName = lastToolNames[toolId] ?? "tool"
                let isError = block["is_error"] as? Bool ?? false
                let output: String
                if let content = block["content"] as? String {
                    output = content
                } else if let contentArr = block["content"] as? [[String: Any]] {
                    output = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    output = ""
                }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parsed.append(ChatMessage(
                        id: UUID(), role: .user,
                        kind: .toolResult(tool: toolName, output: trimmed, isError: isError)
                    ))
                }

            default:
                break // skip thinking, image, etc.
            }
        }
    }
}

// MARK: - Message row (session log aesthetic)

struct MessageRow: View {
    let message: ChatMessage
    var isFirstInTurn: Bool = true
    var highlightQuery: String? = nil

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Turn header — only when the speaker changes
            if isFirstInTurn {
                HStack(spacing: 8) {
                    // Accent dot
                    Circle()
                        .fill(isUser ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)

                    Text(isUser ? "You" : "Claude")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isUser ? Color.accentColor : .secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)
                }
                .padding(.horizontal, 28)
                .padding(.top, isFirstInTurn ? 20 : 0)
                .padding(.bottom, 10)
            }

            // Message content — varies by kind
            switch message.kind {
            case .toolUse(let tool, let input):
                toolUseContent(tool: tool, input: input)
            case .toolResult(let tool, let output, let isError):
                toolResultContent(tool: tool, output: output, isError: isError)
            case .text:
                if isUser {
                    userContent
                } else {
                    assistantContent
                }
            }
        }
    }

    // MARK: - User message — left accent border, contained

    private var userContent: some View {
        HStack(spacing: 0) {
            // Accent bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.5))
                .frame(width: 3)

            highlightedText(message.text)
                .font(.system(size: 14.5))
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }

    // MARK: - Tool use (assistant called a tool)

    private func toolUseContent(tool: String, input: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon(tool))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))

                if !input.isEmpty {
                    Text(input)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 2)
    }

    // MARK: - Tool result (output from a tool)

    private func toolResultContent(tool: String, output: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isError ? Color.red : Color.green.opacity(0.7))
                Text(tool)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Output (collapsible if long)
            if output.count > 300 {
                DisclosureGroup {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(10)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Text("\(output.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines))…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 2)
    }

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit": return "pencil"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        case "Skill": return "sparkles"
        default: return "wrench"
        }
    }

    // MARK: - Assistant message — flat, content-first

    @ViewBuilder
    private var assistantContent: some View {
        if highlightQuery != nil {
            VStack(alignment: .leading, spacing: 8) {
                highlightedText(String(message.text.prefix(400)) + (message.text.count > 400 ? "…" : ""))
                    .font(.system(size: 14.5))
                    .lineSpacing(6)
                    .padding(.horizontal, 28)

                DisclosureGroup("Show full message") {
                    markdownBody
                        .padding(.top, 4)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 4)
        } else {
            markdownBody
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
        }
    }

    private var markdownBody: some View {
        Markdown(message.text)
            .markdownTheme(.work)
            .markdownBlockStyle(\.codeBlock) { configuration in
                CodeBlockView(configuration: configuration)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Text highlighting

    private func highlightedText(_ text: String) -> Text {
        guard let query = highlightQuery?.lowercased(), !query.isEmpty else {
            return Text(text)
        }
        let lower = text.lowercased()
        var result = Text("")
        var searchStart = lower.startIndex

        while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
            if range.lowerBound > searchStart {
                result = result + Text(text[searchStart..<range.lowerBound])
            }
            result = result + Text(text[range])
                .foregroundColor(Color.yellow)
                .bold()
            searchStart = range.upperBound
        }
        if searchStart < lower.endIndex {
            result = result + Text(text[searchStart..<text.endIndex])
        }
        return result
    }
}

// MARK: - Code block (premium rendering)

struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text(configuration.language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if hovering || copied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration.content, forType: .string)
                        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_600_000_000)
                            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06))

            // Code body
            ScrollView(.horizontal, showsIndicators: false) {
                Text(configuration.content)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Custom MarkdownUI theme — transparent, clean, no gray bg

extension MarkdownUI.Theme {
    @MainActor static let work = Theme()
        // Body text
        .text {
            ForegroundColor(.primary)
            FontSize(15)
        }
        // Headings
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(22)
                }
                .markdownMargin(top: 20, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(18)
                }
                .markdownMargin(top: 16, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 12, bottom: 4)
        }
        // Paragraphs
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 12)
                .lineSpacing(6)
        }
        // Inline code — styled pill
        .code {
            FontSize(13.5)
            FontFamilyVariant(.monospaced)
            ForegroundColor(Color(light: Color(red: 0.75, green: 0.22, blue: 0.17),
                                  dark: Color(red: 0.95, green: 0.55, blue: 0.45)))
            BackgroundColor(Color(light: Color(red: 0.95, green: 0.94, blue: 0.93),
                                  dark: Color(white: 1, opacity: 0.08)))
        }
        // Links
        .link {
            ForegroundColor(.accentColor)
        }
        // Strong
        .strong {
            FontWeight(.semibold)
        }
        // Blockquotes — left border accent
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontSize(14.5)
                    }
                    .padding(.leading, 12)
            }
            .markdownMargin(top: 8, bottom: 8)
        }
        // Lists
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 3, bottom: 3)
        }
        // Tables
        .table { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(14)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
}
