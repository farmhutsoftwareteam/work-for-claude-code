// Agents dock panel — three sub-tabs (design: "Agent runs panel.dc.html"):
//
//   • running     — the LIVE roster of sub-agents the active session has
//                    delegated to (state · elapsed · kind · status), running
//                    first. This is where control lives — "stop all" up top.
//   • session     — every fan-out this session, newest first; each batch is
//                    an expandable V2AgentBatchRow (same object as the
//                    transcript's batch row).
//   • definitions — the static *.md agent DEFINITIONS from disk
//                    (~/.claude/agents + <project>/.claude/agents), unchanged
//                    from the old panel. A sibling view, not a replacement.
//
// Live runs come off whichever session is active (Claude or Codex) via the
// shared V2TranscriptSource.subagentRunsPublisher — the same scoped
// subscription the runs strip uses, so this panel never re-renders per token.

import SwiftUI
import Inject

struct V2AgentsPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var sub: SubTab = .running

    // Live roster, streamed from the active session.
    @State private var runs: [V2SubagentRun] = []

    // Definitions state (unchanged from the old panel).
    @State private var filter: ScopeFilter = .all
    @State private var agents: [V2Agent] = []
    @State private var editing: EditTarget?
    @State private var deleteError: String?

    enum SubTab: String, CaseIterable, Identifiable {
        case running, session, definitions
        var id: String { rawValue }
    }

    enum EditTarget: Identifiable {
        case new(scope: AgentConfigWriter.Scope)
        case edit(V2Agent)
        var id: String {
            switch self {
            case .new:         return "new"
            case .edit(let a): return "edit-\(a.id.uuidString)"
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
            subTabStrip
            Group {
                switch sub {
                case .running:     runningView
                case .session:     sessionView
                case .definitions: definitionsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Live runs: re-subscribe whenever the active session changes.
        .task(id: activeInstanceId) { await subscribeRuns() }
        // Definitions: reload from disk when the active tab (project) changes.
        .task(id: appState.activeTab?.id) { reload() }
        .sheet(item: $editing) { target in
            switch target {
            case .new(let scope):
                V2AgentEditorSheet(mode: .new, scope: scope,
                                   onSaved: { _ in editing = nil; reload() },
                                   onCancel: { editing = nil })
            case .edit(let agent):
                V2AgentEditorSheet(
                    mode: .edit(agent),
                    scope: agent.scope == .user
                        ? .user
                        : .project(cwd: URL(fileURLWithPath: appState.activeTab?.projectCwd ?? "/")),
                    onSaved: { _ in editing = nil; reload() },
                    onCancel: { editing = nil })
            }
        }
        .alert("Couldn't delete agent", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
        .enableInjection()
    }

    // MARK: - Live-run subscription

    private var activeInstanceId: UUID? {
        appState.activeSession?.instanceId ?? appState.activeCodexSession?.instanceId
    }
    private var sessionDir: URL? {
        appState.activeSession?.sessionDir ?? appState.activeCodexSession?.sessionDir
    }

    private func subscribeRuns() async {
        if let s = appState.activeSession {
            runs = s.subagentRuns
            for await r in s.subagentRunsPublisher.values { runs = r }
        } else if let c = appState.activeCodexSession {
            runs = c.subagentRuns
            for await r in c.subagentRunsPublisher.values { runs = r }
        } else {
            runs = []
        }
    }

    private func stopAll() {
        // No per-sub-agent kill exists — sub-agents are the main turn's Task
        // calls, so interrupting the turn is the only lever that stops the
        // fan-out. Honest mapping of "stop all".
        appState.activeSession?.interrupt()
        appState.activeCodexSession?.interrupt()
    }

    private var running: Int { runs.filter { $0.state == .running }.count }
    private var done: Int { runs.filter { $0.state == .completed }.count }
    private var failed: Int { runs.filter { $0.state == .failed || $0.state == .orphaned }.count }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agents")
                .font(.system(size: 15, weight: .medium)).kerning(-0.15)
            if !runs.isEmpty {
                Text(runCounts)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(failed > 0 ? v2.del : v2.faint)
            }
            Spacer(minLength: 8)
            if running > 0 {
                Button(action: stopAll) {
                    Text("stop all")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.del)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Interrupt the turn — stops the running agents")
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var runCounts: String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "\(runs.count) this session" : parts.joined(separator: " · ")
    }

    // MARK: - Sub-tab strip

    private var subTabStrip: some View {
        HStack(spacing: 0) {
            subTab("running", .running, count: running > 0 ? running : nil)
            subTab("session", .session, count: runs.isEmpty ? nil : runs.count)
            subTab("definitions", .definitions, count: nil)
            Spacer()
        }
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func subTab(_ title: String, _ which: SubTab, count: Int?) -> some View {
        let on = sub == which
        return Button { sub = which } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, design: .monospaced)).kerning(0.22)
                    .foregroundColor(on ? v2.ink : v2.mute)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
            }
            .padding(.trailing, 18).padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(on ? v2.ink : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Running roster

    private var roster: [V2SubagentRun] {
        runs.sorted { a, b in
            let ra = a.state == .running, rb = b.state == .running
            if ra != rb { return ra }
            return a.startedAt > b.startedAt
        }
    }

    @ViewBuilder
    private var runningView: some View {
        if roster.isEmpty {
            rosterEmpty
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(roster) { run in
                        V2DelegationCard(
                            run: run, toolUseId: run.toolUseId,
                            fallbackDescription: run.description,
                            fallbackAgentType: run.agentType,
                            sessionDir: sessionDir
                        )
                    }
                }
                .padding(18)
            }
        }
    }

    private var rosterEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No agents running.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("When the session delegates work (the Task tool / a fan-out), each sub-agent shows here live — with its state, timing, and what it's doing.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Session (batches, newest first)

    /// Group runs by batchId; runs without one are their own singleton.
    /// Ordered newest-first by the batch's latest spawn.
    private var batches: [[V2SubagentRun]] {
        var byBatch: [String: [V2SubagentRun]] = [:]
        var singles: [[V2SubagentRun]] = []
        for r in runs {
            if let b = r.batchId { byBatch[b, default: []].append(r) }
            else { singles.append([r]) }
        }
        let all = Array(byBatch.values) + singles
        return all
            .map { $0.sorted { $0.startedAt < $1.startedAt } }
            .sorted { ($0.map { $0.startedAt }.max() ?? .distantPast) > ($1.map { $0.startedAt }.max() ?? .distantPast) }
    }

    @ViewBuilder
    private var sessionView: some View {
        if runs.isEmpty {
            rosterEmpty
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(batches.enumerated()), id: \.offset) { _, members in
                        if members.count >= 2 {
                            V2AgentBatchRow(runs: members, sessionDir: sessionDir)
                        } else if let run = members.first {
                            V2DelegationCard(
                                run: run, toolUseId: run.toolUseId,
                                fallbackDescription: run.description,
                                fallbackAgentType: run.agentType,
                                sessionDir: sessionDir
                            )
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: - Definitions (unchanged from the old panel)

    @ViewBuilder
    private var definitionsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(ScopeFilter.allCases) { f in
                    Button { filter = f } label: {
                        Text(f.label)
                            .font(.system(size: 11, design: .monospaced)).kerning(0.22)
                            .foregroundColor(filter == f ? v2.paper : v2.mute)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(filter == f ? v2.ink : v2.card)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(v2.mute)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                }
                .buttonStyle(.plain).help("Reload from disk")
                Button { editing = .new(scope: defaultNewScope()) } label: {
                    Text("+ new")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.ink)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain).help("Create a new agent")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }

            definitionsContent
        }
    }

    @ViewBuilder
    private var definitionsContent: some View {
        if filtered.isEmpty {
            definitionsEmpty
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("main session → delegates to ↓")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.bottom, 12)
                    VStack(spacing: 10) {
                        ForEach(filtered) { agent in card(agent) }
                    }
                    Text("Each runs in its own context. Only the summary returns to your window — the exploration noise never lands here.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(10.5 * 0.6)
                        .foregroundColor(v2.faint)
                        .padding(.top, 16)
                        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
                        .padding(.top, 16)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var definitionsEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyMessage)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(v2.mute)
            Text("Drop a markdown file with YAML frontmatter into:\n  ~/.claude/agents/   (user)\n  <project>/.claude/agents/   (project)")
                .font(.system(size: 10.5, design: .monospaced)).lineSpacing(10.5 * 0.5)
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

    private func defaultNewScope() -> AgentConfigWriter.Scope {
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
            Button("Move to Trash", role: .destructive) { deleteAgent(agent) }
        }
    }

    private func cardContent(_ agent: V2Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                if let color = agent.color {
                    Circle().fill(swiftColor(for: color)).frame(width: 6, height: 6)
                }
                Text(agent.name)
                    .font(.system(size: 14, weight: .medium)).kerning(-0.14)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                HStack(spacing: 6) {
                    Text(agent.scope.label)
                        .font(.system(size: 9.5, design: .monospaced)).kerning(0.76)
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Text("isolated")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(v2.mute)
                }
            }
            Text(agent.summaryLine)
                .font(.system(size: 11, design: .monospaced)).lineSpacing(11 * 0.55)
                .foregroundColor(v2.faint).lineLimit(3)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
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
            } else { return }
        }
        do {
            try AgentConfigWriter.delete(slug: agent.slug, from: scope)
            reload()
        } catch {
            deleteError = error.localizedDescription
        }
    }

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
