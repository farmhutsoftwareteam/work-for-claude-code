import SwiftUI
import UniformTypeIdentifiers

/// Codex's transcript is V2LiveTranscript, the identical view Claude uses —
/// not a lookalike copy. Fix design §1/§3 in .agents/research/2026-07-16-
/// bug-codex-transcript-parity.md: "one shared transcript, not further
/// styling of a second Codex transcript." CodexSession conforms to
/// V2TranscriptSource (see that protocol's doc comment for which concepts
/// it has no equivalent for and what neutral default it supplies instead).
/// Only the login gate is Codex-specific chrome, since Claude has no
/// equivalent screen.
struct V2CodexChatView: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: CodexSession
    let projectCwd: String

    var body: some View {
        Group {
            if session.requiresChatGPTLogin {
                loginView
            } else {
                VStack(spacing: 0) {
                    V2LiveTranscript(session: session, projectCwd: projectCwd)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Multi-agent delegations, live — the same strip Claude
                    // tabs mount. Codex tabs previously had no equivalent,
                    // so concurrent sub-agents were invisible once their
                    // spawn row scrolled away. Empty ⇒ renders nothing.
                    V2SubagentRunsStrip(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
    }

    private var loginView: some View {
        VStack(spacing: 15) {
            V2ProviderMark(provider: .codex, size: 30)
                .padding(14)
                .background(v2.providerBackground(.codex))
                .overlay(Rectangle().stroke(v2.providerAccent(.codex).opacity(0.72), lineWidth: 1))
            Text("Connect your ChatGPT subscription")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(v2.ink)
            Text("Atelier opens Codex's official browser sign-in. Codex stores and refreshes the credentials; Atelier never receives your tokens.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.mute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            // While a browser sign-in is in flight this is a cancel button,
            // not a disabled label — closing the OAuth tab without
            // finishing it used to strand this permanently on "Waiting…"
            // with no way back short of restarting the whole session.
            Button {
                if session.loginInProgress { session.cancelChatGPTLogin() }
                else { session.beginChatGPTLogin() }
            } label: {
                Text(session.loginInProgress ? "Waiting for browser sign-in… (cancel)" : "Sign in with ChatGPT")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(v2.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(32)
    }
}

struct V2CodexComposer: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @ObservedObject var session: CodexSession
    @StateObject private var attachments = V2AttachmentStore()
    @StateObject private var dictation = V2DictationController()
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
            dictation.onUpdate = { draft = $0 }
        }
        .onDisappear {
            // Same reasoning as the Claude composer: the tab going
            // off-screen tears this @StateObject down, so stop the mic
            // rather than leave it recording into an unreachable controller.
            dictation.stop()
        }
        // A failed wake hands the typed message back by writing
        // composerDraft — but this view snapshots that only on appear, so
        // without a signal the restored text existed and never appeared
        // on screen. Scoped subject, not an @Published draft: publishing
        // per keystroke would re-render every observer of the session.
        .onReceive(session.draftRestored) { _ in
            draft = session.composerDraft
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
                    onImagePasted: attachments.addImageData,
                    onFilesDropped: attachments.addFiles
                )
                .onChange(of: draft) { _, value in
                    session.composerDraft = value
                    appState.scheduleWorkspacePersist()
                    cachedHeight = V2ComposerMetrics.height(for: value)
                }
                .frame(height: cachedHeight)

                V2ComposerAttachButton(enabled: canType, action: chooseAttachments)
                V2ComposerDictationButton(controller: dictation, enabled: canType, action: { dictation.toggle(currentDraft: draft) })
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
                density: .compact
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

            V2ComposerUsageMeter(limits: session.usageLimits, isTight: helperTight)
                .layoutPriority(1)

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
        // .hibernated: typing IS the wake gesture — send() respawns,
        // resumes the thread, and delivers the message once it's live.
        // Without it here the placeholder below promises a reply the
        // disabled field can't accept, and the tab is unwakeable.
        case .initializing, .working, .ready, .hibernated: return true
        default: return false
        }
    }

    private var canSend: Bool {
        // Deliberately STRICTER than V2LiveComposer (Claude allows sending
        // during .initializing; Codex's turn/start would just fail there).
        // isWorking is part of the guard so that if .awaitingPermission is
        // ever added to canType ("keep typing while the modal is up"),
        // Send stays blocked during a permission prompt instead of being
        // silently enabled by that unrelated change.
        guard canType, !isWorking, session.state != .initializing else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.items.isEmpty
    }

    private var placeholder: String {
        switch session.state {
        case .idle, .terminated:  return "Ask anything…"
        case .ready:              return "Reply…"
        case .hibernated:         return "Reply to wake this session…"
        case .spawning:           return "Starting…"
        case .initializing:       return "Preparing…"
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
                    HStack(spacing: 8) {
                        Text(request.title).font(.system(size: 17, weight: .medium)).foregroundColor(v2.ink)
                        if session.queuedRequestCount > 0 {
                            Text("· \(session.queuedRequestCount) more waiting")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.faint)
                        }
                    }
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
                    HStack(spacing: 8) {
                        Text(request.title).font(.system(size: 17, weight: .medium)).foregroundColor(v2.ink)
                        if session.queuedRequestCount > 0 {
                            Text("· \(session.queuedRequestCount) more waiting")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.faint)
                        }
                    }
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
