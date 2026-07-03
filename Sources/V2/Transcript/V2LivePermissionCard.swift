// Permission UI bound to a real StreamSession. Surfaces when the session is
// `awaitingPermission` and a pendingPermission is set.
//
// V2PermissionModal is the window-level presentation (dimmed backdrop +
// centred card) used by V2RootView. V2LivePermissionCard is the bare card
// it wraps, kept separate so it can also be embedded inline if needed.

import SwiftUI
import Inject

/// Full-window modal: vibrancy backdrop + centred permission card. Replaces
/// the old inline card that users scrolled past without noticing — a tool
/// request now blocks the surface until you Approve or Deny.
struct V2PermissionModal: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
                // Intentionally NOT tap-to-dismiss — a permission request
                // must be explicitly resolved, not dismissed by a misclick.

            V2LivePermissionCard(session: session)
                .frame(width: 520)
                .shadow(color: .black.opacity(0.32), radius: 40, x: 0, y: 20)
        }
    }
}

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

                // Interactive command → offer the co-driven pane (#57). Deny
                // with steering: Claude re-runs it via terminal_run and you
                // both drive one visible terminal.
                if let cmd = pending.interactiveCommand {
                    Button {
                        session.respondToPermission(
                            allow: false,
                            message: InteractiveCommandDetector.steering(command: cmd)
                        )
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11, weight: .medium))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Run co-driven")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text("this command asks questions — run it in a shared terminal")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(v2.mute)
                            }
                            Spacer()
                        }
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

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
                            .foregroundColor(v2.del)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
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
