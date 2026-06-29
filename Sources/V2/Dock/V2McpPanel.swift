// MCP panel — Mode-B contextual view of the servers Claude actually loaded
// for this session. Reads V2AppState.activeSession.mcpServers — sourced from
// the `system/init` event the binary emits at session start.
//
// Different from the deep MCPEditor in v1's ExtensionsView (which is the full
// CRUD surface over ~/.claude.json). This panel is read-mostly + at-a-glance.

import SwiftUI
import Inject

struct V2McpPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var store: Store
    @State private var addingMCP = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .sheet(isPresented: $addingMCP) {
            MCPEditor(mode: .add(defaultScope: .user)) {
                addingMCP = false
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MCP servers")
                    .font(.system(size: 15, weight: .medium))
                    .kerning(-0.15)
                Spacer()
                if let session = appState.activeSession, !session.mcpServers.isEmpty {
                    Text("\(session.mcpServers.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Button { addingMCP = true } label: {
                    Text("+ add")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Add a new MCP server")
            }
            Text("Tool providers claude loads on spawn — filesystem, github, etc.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineSpacing(2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    // MARK: - Content (binds to active session)

    @ViewBuilder
    private var content: some View {
        if let session = appState.activeSession {
            switch session.state {
            case .idle, .terminated:
                idleState
            case .spawning, .initializing:
                initializingState
            default:
                liveContent(for: session)
            }
        } else {
            noTabState
        }
    }

    // MARK: - States

    private var noTabState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No active tab.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Open a tab to see the MCP servers Claude loads for it.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session not running.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("MCP servers are reported by Claude on `system/init` — start the session to see what it loaded.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var initializingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                V2Spinner(size: 11)
                Text("Waiting for system/init…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func liveContent(for session: StreamSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.mcpServers, id: \.name) { server in
                    serverRow(server)
                }
                if session.mcpServers.isEmpty {
                    Text("No MCP servers loaded for this session.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Reported by the binary at session start. Open the Extensions tab in the v1 window to edit servers.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(10.5 * 0.6)
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Row

    private func serverRow(_ server: MCPServerInfo) -> some View {
        let status = (server.status ?? "unknown").lowercased()
        let isConnected = status == "connected" || status == "ready"
        let isPending = status == "pending"
        let needsAuth = status == "needs-auth"
        let isFailed = status == "failed" || status == "error"

        return HStack(spacing: 11) {
            stateSquare(connected: isConnected, pending: isPending, failed: isFailed, needsAuth: needsAuth)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(server.name))
                    .font(.system(size: 13.5, weight: .medium))
                    .kerning(-0.13)
                Text(scopeHint(server.name))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            Text(statusLabel(status))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(statusColor(isConnected: isConnected, needsAuth: needsAuth, failed: isFailed))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isFailed ? 0.55 : 1.0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func stateSquare(connected: Bool, pending: Bool, failed: Bool, needsAuth: Bool) -> some View {
        if pending || needsAuth {
            Rectangle()
                .stroke(v2.line2, lineWidth: 1)
                .frame(width: 11, height: 11)
        } else if failed {
            Rectangle()
                .fill(v2.del)
                .frame(width: 11, height: 11)
        } else if connected {
            Rectangle()
                .fill(v2.ink)
                .frame(width: 11, height: 11)
        } else {
            Rectangle()
                .stroke(v2.line2, lineWidth: 1)
                .frame(width: 11, height: 11)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "connected", "ready":   return "on"
        case "pending":              return "starting"
        case "needs-auth":           return "needs auth"
        case "failed", "error":      return "failed"
        default:                     return status
        }
    }

    private func statusColor(isConnected: Bool, needsAuth: Bool, failed: Bool) -> Color {
        if failed       { return v2.del }
        if needsAuth    { return v2.del.opacity(0.75) }
        if isConnected  { return v2.mute }
        return v2.faint
    }

    /// MCP names from system/init can be raw ("filesystem") or qualified
    /// ("plugin:supabase:supabase", "claude.ai Gmail"). Show the human-readable
    /// suffix in the title and the prefix as scope hint.
    private func displayName(_ name: String) -> String {
        if let colonIdx = name.lastIndex(of: ":") {
            return String(name[name.index(after: colonIdx)...])
        }
        return name
    }

    private func scopeHint(_ name: String) -> String {
        if name.hasPrefix("plugin:") {
            let parts = name.split(separator: ":")
            if parts.count >= 2 { return "plugin · \(parts[1])" }
            return "plugin"
        }
        if name.contains(":") {
            let parts = name.split(separator: ":")
            return parts.dropLast().joined(separator: " · ")
        }
        return "user scope"
    }
}
