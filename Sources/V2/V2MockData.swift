// Formerly the mock-data fixtures file backing every v2 view before
// StreamSession landed. Everything else in here (V2Project, V2Session,
// V2McpServer, V2LoopTurn/State, the V2Mock fixture enum) was confirmed
// unreferenced anywhere else in Sources/ and deleted. V2WorkbenchTile is
// the one survivor — it's a real, still-used view model for V2LeftRail's
// workbench tiles (see V2LeftRail.swift), not a fixture.

import Foundation

// MARK: - Workbench tiles

struct V2WorkbenchTile: Identifiable {
    let id = UUID()
    let label: String
    let count: String
    let hint: String
}
