import SwiftUI
import UniformTypeIdentifiers

struct V2CodexChatView: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: CodexSession
    let projectCwd: String

    var body: some View {
        Group {
            if session.requiresChatGPTLogin {
                loginView
            } else {
                transcriptView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
    }

    private var loginView: some View {
        VStack(spacing: 15) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(v2.mute)
            Text("Connect your ChatGPT subscription")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(v2.ink)
            Text("Atelier opens Codex's official browser sign-in. Codex stores and refreshes the credentials; Atelier never receives your tokens.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.mute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button { session.beginChatGPTLogin() } label: {
                Text(session.loginInProgress ? "Waiting for browser sign-in…" : "Sign in with ChatGPT")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(v2.ink)
            }
            .buttonStyle(.plain)
            .disabled(session.loginInProgress)
        }
        .padding(32)
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if session.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Codex is ready")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(v2.ink)
                            Text("\(session.account?.label ?? "Codex") · \(session.model.isEmpty ? "loading models" : session.model)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.faint)
                            Text(projectCwd)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(v2.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Positional ids are stable for this append-only live list.
                    // Iterating indices avoids allocating a complete
                    // Array(enumerated()) on every coalesced streaming update.
                    ForEach(session.transcript.indices, id: \.self) { index in
                        row(session.transcript[index])
                    }
                    if session.state == .working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Codex is working…")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(v2.mute)
                        }
                    }
                    Color.clear.frame(height: 1).id("codex-bottom")
                }
                .padding(.horizontal, 36).padding(.vertical, 30)
            }
            .onChange(of: session.transcript.count) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("codex-bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .userText(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text("YOU").font(.system(size: 9.5, design: .monospaced)).foregroundColor(v2.faint)
                Text(text).font(.system(size: 14)).foregroundColor(v2.ink).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .assistantBlock(let block):
            assistantBlock(block)
        case .compactBoundary:
            Text("context compacted").font(.system(size: 10, design: .monospaced)).foregroundColor(v2.faint)
        case .systemNote(let kind, let text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(kind == .error ? v2.del : v2.mute)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(kind == .error ? v2.del : v2.line2, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func assistantBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text).font(.system(size: 14)).foregroundColor(v2.ink)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text, _):
            DisclosureGroup("Reasoning") {
                Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.mute).textSelection(.enabled)
            }
        case .toolUse(_, let name, let input):
            VStack(alignment: .leading, spacing: 6) {
                Text(name.uppercased()).font(.system(size: 9.5, design: .monospaced)).foregroundColor(v2.faint)
                Text(input.preview).font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.ink).textSelection(.enabled)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        case .toolResult(_, let content, let isError):
            Text(content.asString).font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(isError == true ? v2.del : v2.mute)
        case .image:
            Label("Image", systemImage: "photo").foregroundColor(v2.mute)
        case .fallback(let from, let to):
            Text("Model changed: \(from ?? "?") → \(to ?? "?")").foregroundColor(v2.mute)
        case .unknown(let type):
            Text(type).foregroundColor(v2.faint)
        }
    }
}

struct V2CodexComposer: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @ObservedObject var session: CodexSession
    @StateObject private var attachments = V2AttachmentStore()
    @State private var draft = ""
    @State private var cachedHeight: CGFloat = 27
    @State private var inputFocused = false
    @State private var cursorPosition = 0
    @State private var pendingCursorTarget: Int?
    @State private var helperWidth: CGFloat = 0

    private var helperCompact: Bool { helperWidth > 0 && helperWidth < 620 }
    private var helperTight: Bool { helperWidth > 0 && helperWidth < 470 }

    var body: some View {
        V2ComposerChrome(
            attachments: attachments.items,
            onRemoveAttachment: attachments.remove
        ) {
            composerBox
        } helper: {
            helperRow
        }
        .onAppear {
            inputFocused = true
            if draft.isEmpty { draft = session.composerDraft }
            cachedHeight = V2ComposerMetrics.height(for: draft)
        }
        .background(
            Button("Interrupt") { if isWorking { session.interrupt() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .disabled(!isWorking)
        )
    }

    private var composerBox: some View {
        V2ComposerBoxChrome {
            HStack(alignment: .top, spacing: 12) {
                Text("›")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .padding(.top, 6)

                V2ComposerTextView(
                    text: $draft,
                    focused: $inputFocused,
                    cursorPosition: $cursorPosition,
                    pendingCursorTarget: $pendingCursorTarget,
                    placeholder: placeholder,
                    isEnabled: canType,
                    foregroundColor: NSColor(v2.ink),
                    placeholderColor: NSColor(v2.faint),
                    onSubmit: send,
                    onImagePasted: attachments.addImage,
                    onFilesDropped: attachments.addFiles
                )
                .onChange(of: draft) { _, value in
                    session.composerDraft = value
                    appState.scheduleWorkspacePersist()
                    cachedHeight = V2ComposerMetrics.height(for: value)
                }
                .frame(height: cachedHeight)

                V2ComposerAttachButton(enabled: canType, action: chooseAttachments)
                V2ComposerTurnButton(
                    isWorking: isWorking,
                    canSend: canSend,
                    onSend: send,
                    onStop: session.interrupt
                )
            }
        }
    }

    private var helperRow: some View {
        HStack(spacing: 14) {
            V2ProviderBadge(
                provider: .codex,
                density: helperTight ? .compact : .full
            )
            .layoutPriority(2)

            if !helperTight {
                Text(permissionLabel)
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }

            if !helperCompact {
                Text("⇧⏎ newline · ⌘V paste image")
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }

            if isWorking {
                Text("esc to interrupt").lineLimit(1)
            }

            Spacer(minLength: 8)

            V2ComposerContextMeter(
                model: session.model,
                used: session.totalTokens,
                window: session.contextWindow,
                isTight: helperTight,
                helpText: "Codex model and current context usage"
            )
            .layoutPriority(1)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(v2.faint)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: V2WidthKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(V2WidthKey.self) { helperWidth = $0 }
    }

    private func send() {
        guard canSend else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = attachments.items.map(\.url)
        draft = ""
        session.composerDraft = ""
        attachments.clear()
        session.send(text: message, attachments: urls)
        inputFocused = true
    }

    private var isWorking: Bool {
        session.state == .working || session.state == .awaitingPermission
    }

    private var canType: Bool {
        switch session.state {
        case .initializing, .working, .ready: return true
        default: return false
        }
    }

    private var canSend: Bool {
        guard session.state == .ready else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty
    }

    private var placeholder: String {
        switch session.state {
        case .idle, .terminated:  return "Ask Codex…"
        case .ready:              return "Reply to Codex…"
        case .hibernated:         return "Reply to wake this session…"
        case .spawning:           return "Spawning Codex…"
        case .initializing:       return "Initializing Codex…"
        case .working:            return "Reply, or ⎋ to interrupt…"
        case .awaitingPermission: return "Resolve permission above to continue"
        case .closing:            return "Closing…"
        }
    }

    private var permissionLabel: String {
        switch session.permissionMode {
        case "never": return "never ask"
        case "on-failure": return "ask on failure"
        case "untrusted": return "ask for untrusted commands"
        default: return "ask when needed"
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .data]
        panel.message = "Attach to the next message"
        guard panel.runModal() == .OK else { return }
        attachments.addFiles(panel.urls)
    }
}

struct V2CodexPermissionModal: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: CodexSession

    var body: some View {
        if let request = session.pendingPermission {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(request.title).font(.system(size: 17, weight: .medium)).foregroundColor(v2.ink)
                    Text(request.previewText).font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.mute).textSelection(.enabled)
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(v2.card).overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    HStack {
                        Spacer()
                        Button("Deny") { session.respondToPermission(allow: false) }.buttonStyle(.plain)
                        Button("Allow") { session.respondToPermission(allow: true) }
                            .buttonStyle(.plain).foregroundColor(v2.paper)
                            .padding(.horizontal, 15).padding(.vertical, 8).background(v2.ink)
                    }
                }
                .padding(20).frame(width: 520).background(v2.paper2)
                .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
            }
        }
    }
}

struct V2CodexUserInputModal: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: CodexSession
    @State private var answers: [String: String] = [:]

    var body: some View {
        if let request = session.pendingUserInput {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(request.title).font(.system(size: 17, weight: .medium)).foregroundColor(v2.ink)
                    ForEach(request.questions) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.header.uppercased())
                                .font(.system(size: 9.5, design: .monospaced)).foregroundColor(v2.faint)
                            Text(question.prompt).font(.system(size: 12)).foregroundColor(v2.ink)
                            if question.options.isEmpty {
                                if question.isSecret {
                                    SecureField(question.required ? "Required" : "Optional", text: answerBinding(question.id))
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    TextField(question.required ? "Required" : "Optional", text: answerBinding(question.id))
                                        .textFieldStyle(.roundedBorder)
                                }
                            } else {
                                Picker("", selection: answerBinding(question.id)) {
                                    ForEach(question.options, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.menu)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { session.respondToUserInput(answers: answers, cancelled: true) }
                            .buttonStyle(.plain)
                        Button("Continue") { session.respondToUserInput(answers: answers) }
                            .buttonStyle(.plain).foregroundColor(v2.paper)
                            .padding(.horizontal, 15).padding(.vertical, 8).background(v2.ink)
                            .disabled(!requiredAnswersPresent(request.questions))
                    }
                }
                .padding(20).frame(width: 540).background(v2.paper2)
                .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
                .onAppear {
                    for question in request.questions where answers[question.id] == nil {
                        answers[question.id] = question.options.first ?? ""
                    }
                }
            }
        }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id, default: ""] }, set: { answers[id] = $0 })
    }

    private func requiredAnswersPresent(_ questions: [CodexInputQuestion]) -> Bool {
        questions.allSatisfy { !$0.required || !(answers[$0.id] ?? "").isEmpty }
    }
}
