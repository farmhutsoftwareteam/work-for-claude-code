// V2ACPChatView — self-contained ACP-backed chat surface (Phase 4 dogfood).
//
// Owns an ACPSession and renders its transcript, tool calls, plan, a
// permission modal, and a composer. Gated behind a flag and shown as an
// overlay so it can't disturb the shipping StreamSession chat. When this
// reaches parity in real use, the cutover is just routing the main surface
// here.

import SwiftUI
import Inject

struct V2ACPChatView: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @StateObject private var session: ACPSession
    @State private var draft = ""
    let projectName: String
    let onClose: () -> Void

    init(cwd: URL, projectName: String, onClose: @escaping () -> Void) {
        _session = StateObject(wrappedValue: ACPSession(cwd: cwd))
        self.projectName = projectName
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            if !session.plan.isEmpty { planBar }
            composer
        }
        .background(v2.paper)
        .overlay {
            if let req = session.pendingPermission {
                permissionModal(req)
            }
        }
        .task { session.start() }
        // stop() exists on both ACPSession and ACPClient but nothing ever
        // called it — the node subprocess outlived this view on every close
        // (bug-hunt H4). Neither class has a deinit either, so this hook is
        // the only teardown path.
        .onDisappear { session.stop() }
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("ACP preview")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(v2.ink)
            statusPill
            Spacer()
            modeMenu
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close ACP preview")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var statusPill: some View {
        let (label, dot): (String, Color) = {
            switch session.status {
            case .idle:        return ("idle", v2.line2)
            case .connecting:  return ("connecting…", v2.mute)
            case .ready:       return ("ready", v2.ink)
            case .working:     return ("working…", v2.ink)
            case .failed:      return ("error", v2.del)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.mute)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var modeMenu: some View {
        Menu {
            ForEach(["plan", "default", "acceptEdits", "bypassPermissions"], id: \.self) { m in
                Button {
                    session.setMode(m)
                } label: {
                    HStack {
                        Text(m)
                        if session.currentModeId == m { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Text(session.currentModeId)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Transcript

    private var transcript: some View {
        // Same scroll architecture as the main transcript (see
        // V2LiveTranscript): LAZY rows + system bottom anchoring. The old
        // shape here — eager VStack + an ANIMATED scrollTo fired per streamed
        // token, unconditionally — was the exact bug class that made the main
        // chat unusable (stacked animations, fights the user's scroll).
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(session.transcript) { item in
                    row(item).id(item.id)
                }
                Color.clear.frame(height: 1).id("acp-bottom")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ item: ACPItem) -> some View {
        switch item {
        case .message(let m): messageRow(m)
        case .tool(let t):    toolRow(t)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ACPMessage) -> some View {
        switch m.role {
        case .user:
            HStack(alignment: .top, spacing: 12) {
                Text("you").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.faint)
                    .frame(width: 48, alignment: .leading).padding(.top, 2)
                Text(m.text).font(.system(size: 13, design: .monospaced)).foregroundColor(v2.ink)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .assistant:
            V2MarkdownText(text: m.text).foregroundColor(v2.ink)
        case .thinking:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain").font(.system(size: 10)).foregroundColor(v2.faint).padding(.top, 2)
                Text(m.text).font(.system(size: 11.5, design: .monospaced)).italic()
                    .foregroundColor(v2.mute).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .system:
            Text(m.text).font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.del)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolRow(_ t: ACPToolCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: toolIcon(t.kind)).font(.system(size: 10, weight: .medium)).foregroundColor(v2.mute)
                Text(t.title.isEmpty ? t.kind : t.title)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundColor(v2.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(t.status).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(t.status == "failed" ? v2.del : v2.faint)
            }
            ForEach(Array(t.content.enumerated()), id: \.offset) { _, c in
                toolContent(c)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(v2.paper2)
        .overlay(alignment: .leading) { Rectangle().fill(v2.line2).frame(width: 2) }
    }

    @ViewBuilder
    private func toolContent(_ c: ACPToolContent) -> some View {
        switch c {
        case .text(let s):
            Text(s).font(.system(size: 11, design: .monospaced)).foregroundColor(v2.mute)
                .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
        case .diff(let path, _, _):
            Text("± \(path)").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.mute)
        case .terminal:
            Text("terminal output").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.faint)
        }
    }

    private func toolIcon(_ kind: String) -> String {
        switch kind {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "execute": return "terminal"
        case "search": return "magnifyingglass"
        case "fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    // MARK: - Plan bar

    private var planBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PLAN").font(.system(size: 9, design: .monospaced)).kerning(1.2).foregroundColor(v2.faint)
            ForEach(Array(session.plan.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 7) {
                    Image(systemName: e.status == "completed" ? "checkmark.circle.fill"
                          : e.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                        .font(.system(size: 9)).foregroundColor(e.status == "completed" ? v2.ink : v2.mute)
                    Text(e.content).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(e.status == "completed" ? v2.faint : v2.ink)
                        .strikethrough(e.status == "completed")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper3)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 12) {
            Text("›").font(.system(size: 14, design: .monospaced)).foregroundColor(v2.mute)
            TextField("Message the ACP session…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundColor(v2.ink)
                .lineLimit(1...6).onSubmit(send)
                .disabled(session.status == .connecting)
            if session.status == .working {
                Button { session.interrupt() } label: {
                    Text("stop").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }.buttonStyle(.plain)
            } else {
                Button(action: send) {
                    Text("⏎ send").font(.system(size: 11, design: .monospaced))
                        .foregroundColor(canSend ? v2.ink : v2.faint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }.buttonStyle(.plain).disabled(!canSend)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(v2.card)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var canSend: Bool {
        session.status == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let t = draft; draft = ""
        session.prompt(t)
    }

    // MARK: - Permission modal

    private func permissionModal(_ req: ACPPermissionRequest) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.06).ignoresSafeArea())
            VStack(alignment: .leading, spacing: 14) {
                Text("PERMISSION").font(.system(size: 9.5, design: .monospaced)).kerning(1.5).foregroundColor(v2.faint)
                Text(req.toolName).font(.system(size: 15, weight: .semibold)).foregroundColor(v2.ink)
                if let detail = req.detail {
                    Text(detail).font(.system(size: 12, design: .monospaced)).foregroundColor(v2.mute)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(v2.paper3).textSelection(.enabled)
                }
                VStack(spacing: 8) {
                    ForEach(req.options) { opt in
                        Button { session.resolvePermission(opt.id) } label: {
                            Text(opt.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(opt.isAllow ? v2.paper : v2.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(opt.isAllow ? v2.ink : v2.card)
                                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20).frame(width: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(v2.line2, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
    }
}
