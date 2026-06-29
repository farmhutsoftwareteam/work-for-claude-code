// MCP panel — Mode-B contextual view of the servers Claude actually loaded
// for this session. Reads V2AppState.activeSession.mcpServers — sourced from
// the `system/init` event the binary emits at session start.
//
// Different from the deep MCPEditor in v1's ExtensionsView (which is the full
// CRUD surface over ~/.claude.json). This panel is read-mostly + at-a-glance.

import SwiftUI
import AppKit
import Darwin
import Inject

struct V2McpPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var store: Store
    @State private var addingMCP = false
    @State private var authing: Set<String> = []   // servers mid sign-in
    @State private var authNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let note = authNote {
                Text(note)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(v2.card)
                    .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            }
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
                if serverCount > 0 {
                    Text("\(serverCount)")
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
        if let session = appState.activeSession, isInitializing(session.state) {
            initializingState
        } else if let session = appState.activeSession, isRunning(session.state), !session.mcpServers.isEmpty {
            liveContent(for: session)
        } else {
            // No live session data — show what's CONFIGURED for this project
            // (.mcp.json + ~/.claude.json local + global) so the project home
            // reflects reality instead of looking empty.
            configuredContent
        }
    }

    private func isInitializing(_ s: StreamSession.LifecycleState) -> Bool {
        switch s { case .spawning, .initializing: return true; default: return false }
    }
    private func isRunning(_ s: StreamSession.LifecycleState) -> Bool {
        switch s { case .working, .ready, .awaitingPermission: return true; default: return false }
    }

    // MARK: - Configured servers (from project + user config)

    private var projectCwd: String? {
        appState.selectedProjectCwd?.path ?? appState.activeTab?.projectCwd
    }

    /// MCPs configured for this project — `<cwd>/.mcp.json` (team, "project"),
    /// `~/.claude.json projects.<cwd>` (private, "local"), and the top-level
    /// global servers that load everywhere. Deduped by name (project first).
    private var configuredServers: [MCPServer] {
        var out: [MCPServer] = []
        var seen = Set<String>()
        func add(_ list: [MCPServer]) { for s in list where seen.insert(s.name).inserted { out.append(s) } }
        if let cwd = projectCwd {
            add(store.projectMCPs[cwd] ?? [])
            add(store.localUserMCPs[cwd] ?? [])
        }
        add(store.standaloneMCPs)
        return out
    }

    private var serverCount: Int {
        if let s = appState.activeSession, isRunning(s.state), !s.mcpServers.isEmpty { return s.mcpServers.count }
        return configuredServers.count
    }

    private var configuredContent: some View {
        let servers = configuredServers
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if servers.isEmpty {
                    Text("No MCP servers configured for this project.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 18).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(servers, id: \.id) { configuredRow($0) }
                }
                Text("From .mcp.json (project) and ~/.claude.json (local + user). Start a session to see live connection status.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(10.5 * 0.6)
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .padding(.vertical, 8)
        }
    }

    private func configuredRow(_ server: MCPServer) -> some View {
        HStack(spacing: 11) {
            Rectangle().stroke(v2.line2, lineWidth: 1).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 13.5, weight: .medium)).kerning(-0.13)
                Text("\(scopeLabel(server.source)) · \(transportLabel(server.transport))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            // OAuth-capable servers (http/sse) get a Sign in affordance; stdio
            // servers don't authenticate.
            if isOAuthCapable(server.transport) {
                authButton(server.name)
            } else {
                Text("configured")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func isOAuthCapable(_ t: MCPServer.Transport) -> Bool {
        switch t { case .http, .sse: return true; default: return false }
    }

    // MARK: - Authenticate (claude mcp login)

    private func authButton(_ name: String) -> some View {
        let busy = authing.contains(name)
        return Button { authenticate(name) } label: {
            Text(busy ? "signing in…" : "sign in")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(busy ? v2.faint : v2.ink)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(v2.card)
                .overlay(Rectangle().stroke(busy ? v2.line2 : v2.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Sign in to this MCP server (OAuth in your browser)")
    }

    private func authenticate(_ name: String) {
        guard let binary = appState.claudeBinary else { authNote = "Can't find the claude binary."; return }
        let cwd = projectCwd ?? NSHomeDirectory()
        authing.insert(name)
        authNote = "\(name): opening your browser — authorise there to finish."
        Task {
            let r = await V2MCPAuth.login(claudeBinary: binary, name: name, cwd: cwd)
            authing.remove(name)
            if r.ok {
                authNote = "\(name): authenticated ✓ — restart the session to reconnect it."
                await store.load()
            } else {
                // Fall back to the visible terminal if the headless flow can't
                // complete (e.g. a server with no loopback that needs the paste).
                let reason = r.output.isEmpty ? "couldn't complete sign-in" : String(r.output.suffix(140))
                authNote = "\(name): \(reason) — opening a terminal to finish manually."
                appState.openMCPLogin(serverName: name)
            }
        }
    }

    private func scopeLabel(_ s: MCPServer.Source) -> String {
        switch s {
        case .global:        return "user"
        case .localUser:     return "local"
        case .project:       return "project"
        case .plugin(let n): return "plugin · \(n)"
        }
    }

    private func transportLabel(_ t: MCPServer.Transport) -> String {
        switch t {
        case .stdio(let cmd, _): return (cmd as NSString).lastPathComponent
        case .http:              return "http"
        case .sse:               return "sse"
        case .sdk:               return "sdk"
        case .unknown(let type): return type
        }
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
            if needsAuth {
                authButton(server.name)
            } else {
                Text(statusLabel(status))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(statusColor(isConnected: isConnected, needsAuth: needsAuth, failed: isFailed))
            }
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

// MARK: - MCP OAuth via `claude mcp login` (hidden PTY)

enum V2MCPAuth {
    /// Run `claude mcp login <name> --no-browser` attached to a HIDDEN
    /// pseudo-terminal — the CLI's TTY check passes, but nothing is rendered.
    /// We parse the authorization URL it prints and open the browser ourselves;
    /// the CLI's localhost loopback captures the callback and the process exits
    /// 0 on success. No paste, no visible terminal. Capped by `timeout`.
    static func login(claudeBinary: URL, name: String, cwd: String, timeout: TimeInterval = 180) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var master: Int32 = 0, slave: Int32 = 0
                guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                    cont.resume(returning: (false, "couldn't allocate a terminal")); return
                }
                let p = Process()
                p.executableURL = claudeBinary
                p.arguments = ["mcp", "login", name, "--no-browser"]
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE") { env.removeValue(forKey: k) }
                env["TERM"] = "xterm-256color"
                p.environment = env
                let slaveFH = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                p.standardInput = slaveFH
                p.standardOutput = slaveFH
                p.standardError = slaveFH
                do { try p.run() } catch {
                    close(master); close(slave)
                    cont.resume(returning: (false, "couldn't launch claude")); return
                }
                close(slave)   // child owns it; closing here lets master EOF on exit
                let masterFH = FileHandle(fileDescriptor: master, closeOnDealloc: false)

                let group = DispatchGroup()
                var outData = Data()
                var openedURL = false
                group.enter()
                DispatchQueue.global().async {
                    var buffer = ""
                    while true {
                        let chunk = masterFH.availableData
                        if chunk.isEmpty { break }            // EOF — child closed slave
                        outData.append(chunk)
                        if !openedURL, let s = String(data: chunk, encoding: .utf8) {
                            buffer += s
                            if let url = extractAuthURL(buffer) {
                                openedURL = true
                                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    group.leave()
                }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    p.terminate()
                    group.wait()
                }
                p.waitUntilExit()
                close(master)
                let clean = stripANSI(String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (p.terminationStatus == 0, clean))
            }
        }
    }

    private static func extractAuthURL(_ s: String) -> URL? {
        // Pull every https URL out of the (possibly prefixed/wrapped) output and
        // pick the OAuth one. Matches "Open this URL: https://…/authorize?…".
        guard let re = try? NSRegularExpression(pattern: "https://[^\\s\"'<>]+") else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let str = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,)]"))
            let lower = str.lowercased()
            if lower.contains("authorize") || lower.contains("oauth") || lower.contains("/auth"),
               let u = URL(string: str) {
                return u
            }
        }
        return nil
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
