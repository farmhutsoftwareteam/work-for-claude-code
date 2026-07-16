import SwiftUI

struct V2CodexMcpPanel: View {
    @Environment(\.v2) private var v2
    @ObservedObject var session: CodexSession
    @State private var showAdd = false
    @State private var name = ""
    @State private var transport = "stdio"
    @State private var endpoint = ""
    @State private var arguments = ""
    @State private var projectScoped = true
    @State private var errorText: String?
    @State private var saving = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CODEX MCP").font(.system(size: 10, design: .monospaced)).kerning(1).foregroundColor(v2.faint)
                    Text("\(session.mcpServers.count) configured").font(.system(size: 12)).foregroundColor(v2.ink)
                }
                Spacer()
                Button { Task { await session.refreshMCPStatus() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                Button(importing ? "Importing…" : "Import .mcp.json") { importClaudeProjectConfig() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, design: .monospaced))
                    .disabled(importing)
                    .help("Copy this repo's Claude project MCP entries into .codex/config.toml")
                Button { showAdd.toggle() } label: { Image(systemName: showAdd ? "xmark" : "plus") }
                    .buttonStyle(.plain)
            }
            .padding(14)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }

            if showAdd { editor }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if session.mcpServers.isEmpty {
                        Text("No Codex MCP servers are configured. Add one here, or edit ~/.codex/config.toml.")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(v2.faint)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(session.mcpServers) { server in
                        serverRow(server)
                    }
                }
            }
        }
        .background(v2.paper2)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("server name", text: $name)
            Picker("Transport", selection: $transport) {
                Text("stdio").tag("stdio")
                Text("HTTP").tag("http")
            }.pickerStyle(.segmented)
            TextField(transport == "stdio" ? "command (for example npx)" : "https://…", text: $endpoint)
            if transport == "stdio" { TextField("arguments, separated by spaces", text: $arguments) }
            Toggle("Store in this project's .codex/config.toml", isOn: $projectScoped)
                .toggleStyle(.checkbox)
            if let errorText { Text(errorText).foregroundColor(v2.del).font(.system(size: 10, design: .monospaced)) }
            Button(saving ? "Saving…" : "Save and reload") { save() }
                .buttonStyle(.plain).foregroundColor(v2.paper)
                .padding(.horizontal, 12).padding(.vertical, 7).background(v2.ink)
                .disabled(saving || name.isEmpty || endpoint.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11.5, design: .monospaced))
        .padding(14)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func serverRow(_ server: CodexMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(server.needsLogin ? v2.del : v2.ink).frame(width: 7, height: 7)
                Text(server.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(v2.ink)
                Spacer()
                if server.needsLogin {
                    Button("Sign in") { session.loginMCP(name: server.name) }.buttonStyle(.plain).foregroundColor(v2.del)
                }
            }
            Text("\(server.authStatus) · \(server.toolCount) tools · \(server.resourceCount) resources")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(v2.faint)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func save() {
        saving = true; errorText = nil
        let value: [String: Any]
        if transport == "stdio" {
            value = ["command": endpoint, "args": arguments.split(separator: " ").map(String.init), "enabled": true]
        } else {
            value = ["url": endpoint, "enabled": true]
        }
        Task {
            do {
                try await session.writeMCPServer(name: name, value: value, projectScoped: projectScoped)
                name = ""; endpoint = ""; arguments = ""; showAdd = false
            } catch { errorText = error.localizedDescription }
            saving = false
        }
    }

    private func importClaudeProjectConfig() {
        importing = true
        errorText = nil
        Task {
            do {
                let count = try await session.importClaudeProjectMCPServers()
                if count == 0 { errorText = "No compatible command/url MCP entries found in .mcp.json." }
            } catch {
                errorText = error.localizedDescription
            }
            importing = false
        }
    }
}
