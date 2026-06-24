// Mock data driving every v2 view while the StreamSession engine is being
// built in parallel. When Phase 4 (#22) lands, these structs get replaced
// with real event-stream-derived state. The shape stays the same.

import Foundation

// MARK: - Sidebar projects

struct V2Project: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: String
    let live: Bool
}

// MARK: - Workbench tiles

struct V2WorkbenchTile: Identifiable {
    let id = UUID()
    let label: String
    let count: String
    let hint: String
}

// MARK: - Sessions

struct V2Session: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let live: Bool
}

// MARK: - MCP servers (right dock)

struct V2McpServer: Identifiable {
    let id = UUID()
    let name: String
    let transport: String
    let toolCount: Int
    let on: Bool
}

// MARK: - Agents (right dock)

struct V2Agent: Identifiable {
    let id = UUID()
    let name: String
    let summary: String
}

// MARK: - Loop runner (right dock)

struct V2LoopTurn: Identifiable {
    let id = UUID()
    let number: String
    let title: String
    let state: V2LoopTurnState
}

enum V2LoopTurnState {
    case fail, pass, running
}

// MARK: - Fixtures

enum V2Mock {
    static let projects: [V2Project] = [
        .init(name: "hubflo-workflow", size: "12.9B", live: true),
        .init(name: "freyt365-v2", size: "594.5M", live: true),
        .init(name: "winpal", size: "911.0M", live: false),
        .init(name: "munyamakosa", size: "18.8M", live: false),
        .init(name: "talking-treasures", size: "44.0M", live: false),
        .init(name: "fifa-wc26", size: "2.0B", live: false),
        .init(name: "ai-integrate", size: "5.2B", live: false),
        .init(name: "savemymusic", size: "618.8M", live: false),
        .init(name: "raysuncapital", size: "120.1M", live: false),
        .init(name: "zw-wp-research", size: "847.4M", live: false),
        .init(name: "spotifything", size: "1.5B", live: false)
    ]

    static let workbenchTiles: [V2WorkbenchTile] = [
        .init(label: "Plugins", count: "4",  hint: "installed"),
        .init(label: "Skills",  count: "44", hint: "available"),
        .init(label: "MCPs",    count: "7",  hint: "connected"),
        .init(label: "Hooks",   count: "12", hint: "active"),
        .init(label: "Usage",   count: "—",  hint: "this month"),
        .init(label: "Market",  count: "∞",  hint: "browse")
    ]

    static let sessions: [V2Session] = [
        .init(name: "auth-svc", live: true),
        .init(name: "web-refactor", live: false)
    ]

    static let mcpServers: [V2McpServer] = [
        .init(name: "filesystem", transport: "npx",    toolCount: 9,  on: true),
        .init(name: "github",     transport: "npx",    toolCount: 14, on: true),
        .init(name: "postgres",   transport: "docker", toolCount: 6,  on: false),
        .init(name: "linear",     transport: "sse",    toolCount: 11, on: true)
    ]

    static let agents: [V2Agent] = [
        .init(name: "reviewer",    summary: "opus · read · grep · git. Blocks on standard violations."),
        .init(name: "explorer",    summary: "haiku · read · grep. Maps the codebase, returns a summary only."),
        .init(name: "test-runner", summary: "sonnet · bash · read. Runs suites, reports red/green.")
    ]

    static let loopTurns: [V2LoopTurn] = [
        .init(number: "01", title: "write failing test for null cursor", state: .fail),
        .init(number: "02", title: "patch re-baseline guard",            state: .fail),
        .init(number: "03", title: "add operator call site",             state: .fail),
        .init(number: "04", title: "run full suite + lint",              state: .running)
    ]
}
