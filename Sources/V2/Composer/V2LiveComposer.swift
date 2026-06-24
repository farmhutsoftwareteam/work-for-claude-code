// Live composer bound to a real StreamSession. Send / Stop based on state.

import SwiftUI
import Inject

struct V2LiveComposer: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            composerBox
            helperRow
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
    }

    private var composerBox: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("›")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(v2.mute)

            TextField(placeholder, text: $draft, axis: .vertical)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.ink)
                .onSubmit(sendCurrent)
                .lineLimit(1...8)
                .disabled(!canType)

            if isWorking {
                Button { session.interrupt() } label: {
                    HStack(spacing: 7) {
                        Rectangle().fill(v2.ink).frame(width: 8, height: 8)
                        Text("Stop")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(v2.paper2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: sendCurrent) {
                    Text("⏎ send")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(canSend ? v2.ink : v2.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var helperRow: some View {
        HStack(spacing: 18) {
            Button { session.cyclePermissionMode() } label: {
                Text("\(permissionLabel) · shift+tab to cycle")
                    .foregroundColor(v2.faint)
            }
            .buttonStyle(.plain)

            if isWorking {
                Text("esc to interrupt")
            }

            Spacer()

            Text(modelStatus)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(v2.faint)
    }

    // MARK: - Helpers

    private var placeholder: String {
        switch session.state {
        case .idle, .terminated:    return "Ask anything…"
        case .spawning:             return "Spawning…"
        case .initializing:         return "Initializing…"
        case .working:              return "Reply, or ⎋ to interrupt…"
        case .awaitingPermission:   return "Resolve permission above to continue"
        case .closing:              return "Closing…"
        }
    }

    private var canType: Bool {
        switch session.state {
        case .idle, .working, .initializing: return true
        default: return false
        }
    }

    private var canSend: Bool {
        canType && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var modelStatus: String {
        let used = session.tokensUsed
        let usedText = used >= 1000 ? "\(used / 1000)k" : "\(used)"
        return "\(session.model) · \(usedText) tokens"
    }

    private func sendCurrent() {
        guard canSend else { return }
        let text = draft
        draft = ""
        session.send(text: text)
        inputFocused = true
    }
}
