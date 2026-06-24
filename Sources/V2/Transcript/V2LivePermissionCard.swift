// Inline permission card bound to a real StreamSession. Surfaces when the
// session is `awaitingPermission` and a pendingPermission is set.

import SwiftUI
import Inject

struct V2LivePermissionCard: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession

    var body: some View {
        if let pending = session.pendingPermission {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text("PERMISSION")
                        .font(.system(size: 10, design: .monospaced))
                        .kerning(0.8)
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
                    Text("Claude wants to use \(pending.toolName)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.mute)
                }

                Text(pending.previewText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(v2.paper2)
                    .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                    .textSelection(.enabled)

                HStack(spacing: 9) {
                    Button { session.respondToPermission(allow: true) } label: {
                        Text("Approve")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(v2.paper)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(v2.ink)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])

                    Button { session.respondToPermission(allow: false) } label: {
                        Text("Deny")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.delete, modifiers: [.command])

                    Spacer()
                    Text("⌥ to always allow")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.ink, lineWidth: 2))
            .enableInjection()
        }
    }
}
