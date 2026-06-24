// MCP panel — Mode-B contextual server toggles. Different from the deep
// ExtensionsView editor — this is the at-a-glance / quick-toggle for the
// running pane. Mock data; engine wiring lands in Phase 3 (#34).

import SwiftUI
import Inject

struct V2McpPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(V2Mock.mcpServers) { server in
                        serverRow(server)
                    }

                    Text("Toggling never rewrites unrelated keys in ~/.claude.json.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(10.5 * 0.6)
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                .padding(.vertical, 8)
            }
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text("MCP servers")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            Button { } label: {
                Text("+ add")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private func serverRow(_ server: V2McpServer) -> some View {
        HStack(spacing: 11) {
            Rectangle()
                .fill(server.on ? v2.ink : Color.clear)
                .overlay(Rectangle().stroke(server.on ? Color.clear : v2.line2, lineWidth: 1))
                .frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .kerning(-0.13)
                Text("\(server.transport) · \(server.toolCount) tools")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            Text(server.on ? "on" : "off")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(server.on ? v2.mute : v2.faint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(server.on ? 1.0 : 0.55)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }
}
