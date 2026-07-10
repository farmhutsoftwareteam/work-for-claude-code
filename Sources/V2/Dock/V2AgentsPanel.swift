// Agents dock panel — reads the active tab's project agents + the user-scope
// agents from disk via V2AgentLoader. Scope filter chips at the top.
//
// The "+ new" button and per-card editor sheet are deferred — this is a
// read-mostly panel for now. Right-click on a row to reveal the agent file
// in Finder.

import SwiftUI
import Inject

struct V2AgentsPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var filter: ScopeFilter = .all
    @State private var agents: [V2Agent] = []
    @State private var editing: EditTarget?
    /// Surfaces a failed delete instead of the prior silent `try?` — a
    /// permission/disk error looked identical to success with nothing
    /// telling the user the agent file is still sitting on disk
    /// (bug-hunt #18).
    @State private var deleteError: String?

    enum EditTarget: Identifiable {
        case new(scope: AgentConfigWriter.Scope)
        case edit(V2Agent)

        var id: String {
            switch self {
            case .new:           return "new"
            case .edit(let a):   return "edit-\(a.id.uuidString)"
            }
        }
    }

    enum ScopeFilter: String, CaseIterable, Identifiable {
        case all, user, project
        var id: String { rawValue }
        var label: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeChips
            content
        }
        .task(id: appState.activeTab?.id) {
            reload()
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new(let scope):
                V2AgentEditorSheet(
                    mode: .new,
                    scope: scope,
                    onSaved: { _ in
                        editing = nil
                        reload()
                    },
                    onCancel: { editing = nil }
                )
            case .edit(let agent):
                V2AgentEditorSheet(
                    mode: .edit(agent),
                    scope: agent.scope == .user
                        ? .user
                        : .project(cwd: URL(fileURLWithPath: appState.activeTab?.projectCwd ?? "/")),
                    onSaved: { _ in
                        editing = nil
                        reload()
                    },
                    onCancel: { editing = nil }
                )
            }
        }
        .alert("Couldn't delete agent", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agents")
                    .font(.system(size: 15, weight: .medium))
                    .kerning(-0.15)
                Spacer()
                if !filtered.isEmpty {
                    Text("\(filtered.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("Reload from disk")
                Button { editing = .new(scope: defaultNewScope()) } label: {
                    Text("+ new")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Create a new agent in the current project (or user scope)")
            }
            Text("Specialised sub-claudes the main session can delegate to — each runs isolated, only the summary returns.")
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

    private func defaultNewScope() -> AgentConfigWriter.Scope {
        // Match the scope filter the user has selected: a 'project' filter
        // implies they want to write a project agent. Otherwise user.
        switch filter {
        case .project:
            if let cwd = appState.activeTab?.projectCwd {
                return .project(cwd: URL(fileURLWithPath: cwd))
            }
            return .user
        default:
            return .user
        }
    }

    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(ScopeFilter.allCases) { f in
                Button { filter = f } label: {
                    Text(f.label)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                        .foregroundColor(filter == f ? v2.paper : v2.mute)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(filter == f ? v2.ink : v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.activeTab == nil {
            noTabState
        } else if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("main session → delegates to ↓")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.bottom, 12)

                    VStack(spacing: 10) {
                        ForEach(filtered) { agent in
                            card(agent)
                        }
                    }

                    Text("Each runs in its own context. Only the summary returns to your window — the exploration noise never lands here.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(10.5 * 0.6)
                        .foregroundColor(v2.faint)
                        .padding(.top, 16)
                        .overlay(alignment: .top) {
                            Rectangle().fill(v2.line).frame(height: 1)
                        }
                        .padding(.top, 16)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var noTabState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No active tab.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Open a Mode-B tab to see the agents it can delegate to.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyMessage)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Drop a markdown file with YAML frontmatter into:\n  ~/.claude/agents/   (user)\n  <project>/.claude/agents/   (project)")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyMessage: String {
        switch filter {
        case .all:     return "No agents found in user or project scope."
        case .user:    return "No agents in ~/.claude/agents/."
        case .project: return "No agents in this project's .claude/agents/."
        }
    }

    // MARK: - Card

    private func card(_ agent: V2Agent) -> some View {
        Button { editing = .edit(agent) } label: {
            cardContent(agent)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editing = .edit(agent) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.path])
            }
            Button("Copy slug") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(agent.slug, forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                deleteAgent(agent)
            }
        }
    }

    private func cardContent(_ agent: V2Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                if let color = agent.color {
                    Circle()
                        .fill(swiftColor(for: color))
                        .frame(width: 6, height: 6)
                }
                Text(agent.name)
                    .font(.system(size: 14, weight: .medium))
                    .kerning(-0.14)
                Spacer()
                HStack(spacing: 6) {
                    Text(agent.scope.label)
                        .font(.system(size: 9.5, design: .monospaced))
                        .kerning(0.76)
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Text("isolated")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.mute)
                }
            }
            Text(agent.summaryLine)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(11 * 0.55)
                .foregroundColor(v2.faint)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func deleteAgent(_ agent: V2Agent) {
        let scope: AgentConfigWriter.Scope
        switch agent.scope {
        case .user:
            scope = .user
        case .project:
            if let cwd = appState.activeTab?.projectCwd {
                scope = .project(cwd: URL(fileURLWithPath: cwd))
            } else {
                return
            }
        }
        do {
            try AgentConfigWriter.delete(slug: agent.slug, from: scope)
            reload()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private var filtered: [V2Agent] {
        switch filter {
        case .all:     return agents
        case .user:    return agents.filter { $0.scope == .user }
        case .project: return agents.filter { $0.scope == .project }
        }
    }

    private func reload() {
        let cwd = appState.activeTab.map { URL(fileURLWithPath: $0.projectCwd) }
        agents = V2AgentLoader.load(projectCwd: cwd)
    }

    private func swiftColor(for token: String) -> Color {
        // Convention from Claude Code: limited named palette. Map to v2
        // palette so colors stay consistent with the rest of the chrome.
        switch token.lowercased() {
        case "red", "rose":      return v2.del
        case "green", "emerald": return v2.add
        case "yellow", "amber":  return Color(red: 0.95, green: 0.73, blue: 0.20)
        case "blue", "sky":      return Color(red: 0.30, green: 0.55, blue: 0.85)
        case "purple", "violet": return Color(red: 0.60, green: 0.40, blue: 0.80)
        case "orange":           return Color(red: 0.90, green: 0.55, blue: 0.25)
        default:                 return v2.mute
        }
    }
}
