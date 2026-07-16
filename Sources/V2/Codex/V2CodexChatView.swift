import SwiftUI

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
                    ForEach(Array(session.transcript.enumerated()), id: \.offset) { _, item in
                        row(item)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(attachments.items) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.thumbnail == nil ? "doc" : "photo")
                                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                                Button { attachments.remove(item) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(v2.mute)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { chooseAttachments() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).foregroundColor(v2.mute)
                    .padding(.vertical, 10)
                    .disabled(session.state != .ready)
                    .help("Attach images or files")
                TextField("Ask Codex…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .padding(10)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    .disabled(session.state != .ready)
                    .onSubmit(send)
                if session.state == .working || session.state == .awaitingPermission {
                    Button("Stop") { session.interrupt() }
                        .buttonStyle(.plain).foregroundColor(v2.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
                } else {
                    Button("Send") { send() }
                        .buttonStyle(.plain).foregroundColor(v2.paper)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(v2.ink)
                        .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.items.isEmpty) || session.state != .ready)
                }
            }
            if session.totalTokens > 0 {
                Text(usageLabel)
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(v2.faint)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
        .onAppear { if draft.isEmpty { draft = session.composerDraft } }
        .onChange(of: draft) { _, value in
            session.composerDraft = value
            appState.scheduleWorkspacePersist()
        }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = attachments.items.map(\.url)
        guard !message.isEmpty || !urls.isEmpty else { return }
        draft = ""
        session.composerDraft = ""
        attachments.clear()
        session.send(text: message, attachments: urls)
    }

    private var usageLabel: String {
        if let window = session.contextWindow, window > 0 {
            return "context · \(session.totalTokens.formatted()) / \(window.formatted()) tokens"
        }
        return "usage · \(session.totalTokens.formatted()) tokens"
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
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
