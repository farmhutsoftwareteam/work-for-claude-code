// Right dock host (360px) — swaps between Loop / Agents / MCP panels based on
// the V2DockPanel binding owned by V2RootView and driven by V2SessionHeader.

import SwiftUI
import Inject

struct V2RightDock: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Binding var panel: V2DockPanel

    var body: some View {
        Group {
            switch panel {
            case .loop:   V2LoopPanel()
            case .agents: V2AgentsPanel()
            case .mcp:    V2McpPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper2)
        .overlay(alignment: .leading) {
            Rectangle().fill(v2.line).frame(width: 1)
        }
        .enableInjection()
    }
}
