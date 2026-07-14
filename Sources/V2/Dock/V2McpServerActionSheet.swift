// One well-designed modal for "what do I want to do with this MCP server" —
// replaces the split between a single quiet inline button (only ever ONE
// action visible at a time, whichever the row's state picked) and a
// right-click context menu most people never discover. Tapping a configured
// server row now opens this instead: every real action in one place, same
// bordered-row visual language V2ModelPicker already established.

import SwiftUI
import Inject

struct V2McpServerActionSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss

    let server: MCPServer
    let scopeLabel: String
    let isOAuth: Bool
    let needsAuth: Bool
    let isSupabasePlugin: Bool
    let canCopyToProject: Bool
    let canEditOrDelete: Bool
    let isDeleting: Bool

    let onSignIn: () -> Void
    let onConnectSupabase: () -> Void
    let onUseInProject: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 0) {
                if isSupabasePlugin {
                    row(label: "Connect & choose project…", detail: "sign in, then pick a real Supabase project") {
                        onConnectSupabase(); dismiss()
                    }
                } else if needsAuth {
                    row(label: "Sign in", detail: "opens your browser to authorize") {
                        onSignIn(); dismiss()
                    }
                } else if isOAuth {
                    row(label: "Sign in again…", detail: "switch account, or re-auth an expired token") {
                        onSignIn(); dismiss()
                    }
                }
                if canCopyToProject {
                    row(label: "Use in this project…", detail: "copy to project scope, e.g. to point it at this project's resources") {
                        onUseInProject(); dismiss()
                    }
                }
                if canEditOrDelete {
                    row(label: "Edit…", detail: "change command, URL, env, or headers") {
                        onEdit(); dismiss()
                    }
                    row(label: "Delete…", detail: "removed from your config — can't be undone from the app", destructive: true) {
                        onDelete(); dismiss()
                    }
                }
            }
            Button { dismiss() } label: {
                Text("cancel")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
        }
        .frame(width: 360)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .enableInjection()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                V2ServiceLogo(name: server.name, host: V2ServiceLogo.host(of: server.transport), size: 16, tint: v2.ink)
                Text(server.name)
                    .font(.system(size: 14, weight: .medium))
                    .kerning(-0.13)
            }
            Text(scopeLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func row(label: String, detail: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(destructive ? v2.del : v2.ink)
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(V2McpActionRowStyle())
        .disabled(isDeleting)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }
}

/// Hover/press feedback for a full-width row button — same "acknowledge the
/// click immediately" reasoning as V2ChipButtonStyle, just for a row instead
/// of a chip.
private struct V2McpActionRowStyle: ButtonStyle {
    @Environment(\.v2) private var v2
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? v2.card : Color.clear)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
