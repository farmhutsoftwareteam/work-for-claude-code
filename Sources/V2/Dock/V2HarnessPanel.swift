// Harness dock panel — live view of the active tab's HarnessOrchestrator.
// Five states: no active tab / Mode-A tab / no harness / configuring /
// running with phase indicator + plan + per-iteration log + progress preview.

import SwiftUI
import Inject

/// Reused short date+time formatter (building one per row was wasteful).
private enum V2HarnessFormat {
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
}

struct V2HarnessPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var showingNewHarness = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .sheet(isPresented: $showingNewHarness) {
            if let tab = appState.activeTab,
               let binary = appState.claudeBinary {
                V2NewHarnessSheet(
                    cwd: URL(fileURLWithPath: tab.projectCwd),
                    claudeURL: binary,
                    onStart: { harness in
                        appState.attachHarness(harness, toTab: tab.id)
                        showingNewHarness = false
                        harness.start()
                    },
                    onCancel: { showingNewHarness = false }
                )
            }
        }
        .enableInjection()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Harness")
                    .font(.system(size: 15, weight: .medium))
                    .kerning(-0.15)
                Spacer()
                statusIndicator
            }
            Text("Multi-phase plan → work → review pipeline with persisted progress notes between phases.")
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

    @ViewBuilder
    private var statusIndicator: some View {
        if let harness = appState.activeTab?.harness {
            HStack(spacing: 6) {
                switch harness.phase {
                case .planning, .working, .reviewing:
                    V2PulseDot(size: 7, color: v2.ink)
                    Text(phaseLabel(harness.phase))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                case .completed:
                    Circle().fill(v2.add).frame(width: 7, height: 7)
                    Text("completed").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.add)
                case .failed:
                    Circle().fill(v2.del).frame(width: 7, height: 7)
                    Text("failed").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.del)
                case .stopped:
                    Circle().fill(v2.faint).frame(width: 7, height: 7)
                    Text("stopped").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
                case .idle:
                    Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
                    Text("idle").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = appState.activeTab {
            if tab.surface != .modeB {
                modeAExplainer
            } else if let harness = tab.harness {
                V2HarnessLiveView(harness: harness, panel: self)
            } else {
                emptyState(tab: tab)
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
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modeAExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Harnesses need Mode B.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Switch this tab to chat (⌘⇧Y) to run an autonomous harness.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyState(tab: TerminalTab) -> some View {
        let canStart = appState.claudeBinary != nil
            && (appState.claudeVersion ?? .init(major: 0, minor: 0, patch: 0)) >= ClaudeBinary.minimumSupported

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No harness running on this tab.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.mute)

                    Text("A harness runs Plan → Work → Review across fresh `claude -p` sessions. State persists in progress.md so the work survives context limits.")
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(11 * 0.55)
                        .foregroundColor(v2.faint)

                    Button { showingNewHarness = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("Configure harness")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundColor(canStart ? v2.paper : v2.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(canStart ? v2.ink : v2.line2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .padding(.top, 4)
                }

                savedHarnessesSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var savedHarnessesSection: some View {
        let saved = HarnessOrchestrator.listSaved()
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("SAVED")
                        .font(.system(size: 10, design: .monospaced))
                        .kerning(1.0)
                        .foregroundColor(v2.faint)
                    Spacer()
                    Text("\(saved.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    Rectangle().fill(v2.line).frame(height: 1)
                }
                .padding(.top, 8)

                VStack(spacing: 8) {
                    ForEach(saved) { saved in
                        savedHarnessRow(saved)
                    }
                }
            }
        }
    }

    private func savedHarnessRow(_ saved: HarnessOrchestrator.SavedHarness) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([saved.url])
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(saved.summary.isEmpty ? "(no plan recorded)" : saved.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .lineLimit(2)
                    HStack(spacing: 9) {
                        Text(formatDate(saved.createdAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(v2.faint)
                        if saved.hasProgress {
                            Text("· progress saved")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(v2.faint)
                        }
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Reveal harness directory in Finder")
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([saved.url])
            }
            Button("Copy path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(saved.url.path, forType: .string)
            }
        }
    }

    private func formatDate(_ d: Date) -> String {
        V2HarnessFormat.dateTime.string(from: d)
    }

    // MARK: - Live sections (used by V2HarnessLiveView)

    fileprivate func goalSection(_ harness: HarnessOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("GOAL")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            Text(harness.config.goal.isEmpty ? "(empty)" : harness.config.goal)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(12 * 0.6)
                .foregroundColor(v2.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .padding(.bottom, 18)
    }

    fileprivate func phaseDiagram(_ harness: HarnessOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PHASES")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)

            VStack(spacing: 0) {
                phaseStep("plan", subtitle: "→ plan.md", active: harness.phase == .planning, done: !harness.plan.isEmpty)
                arrow
                phaseStep("work", subtitle: workSubtitle(harness), active: isWorking(harness), done: harness.iterations.contains { $0.passed != nil })
                arrow
                phaseStep("review", subtitle: reviewSubtitle(harness), active: isReviewing(harness), done: harness.iterations.contains { $0.passed == true })
            }
        }
        .padding(.bottom, 20)
    }

    fileprivate func planSection(_ harness: HarnessOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("PLAN")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            if harness.plan.isEmpty {
                Text(harness.phase == .planning ? "Generating…" : "(no plan yet)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            } else {
                Text(harness.plan.prefix(1200))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(11.5 * 0.55)
                    .foregroundColor(v2.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                    .textSelection(.enabled)
            }
        }
        .padding(.bottom, 18)
    }

    fileprivate func iterationsSection(_ harness: HarnessOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ITERATIONS")
                    .font(.system(size: 10, design: .monospaced))
                    .kerning(1.0)
                    .foregroundColor(v2.faint)
                Spacer()
                Text("budget: \(harness.config.maxIterations)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.bottom, 10)

            if harness.iterations.isEmpty {
                Text(harness.phase == .planning ? "Waiting on plan…" : "No iterations yet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
            } else {
                ForEach(Array(harness.iterations.enumerated()), id: \.element.id) { idx, it in
                    iterationRow(it, isLast: idx == harness.iterations.count - 1)
                }
            }
        }
        .padding(.bottom, 18)
    }

    fileprivate func progressFileSection(_ harness: HarnessOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("PROGRESS.MD")
                    .font(.system(size: 10, design: .monospaced))
                    .kerning(1.0)
                    .foregroundColor(v2.faint)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([harness.storageRoot]) } label: {
                    Text("show in Finder")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            if harness.progress.isEmpty {
                Text("(empty)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
            } else {
                Text(harness.progress.suffix(1500))
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(11 * 0.55)
                    .foregroundColor(v2.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                    .textSelection(.enabled)
            }
        }
    }

    fileprivate func footer(_ harness: HarnessOrchestrator) -> some View {
        HStack(spacing: 10) {
            switch harness.phase {
            case .planning, .working, .reviewing:
                Button { harness.stop() } label: {
                    Text("stop harness")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.paper)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(v2.ink)
                }
                .buttonStyle(.plain)
            default:
                Button {
                    if let tab = appState.activeTab {
                        appState.attachHarness(nil, toTab: tab.id)
                    }
                } label: {
                    Text("clear")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button { showingNewHarness = true } label: {
                    Text("new harness")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.paper)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(v2.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    // MARK: - Phase helpers

    private func phaseLabel(_ phase: HarnessOrchestrator.Phase) -> String {
        switch phase {
        case .planning: return "planning"
        case .working(let n): return "work · iter \(n)"
        case .reviewing(let n): return "review · iter \(n)"
        default: return ""
        }
    }

    private func isWorking(_ h: HarnessOrchestrator) -> Bool {
        if case .working = h.phase { return true }
        return false
    }

    private func isReviewing(_ h: HarnessOrchestrator) -> Bool {
        if case .reviewing = h.phase { return true }
        return false
    }

    private func workSubtitle(_ h: HarnessOrchestrator) -> String {
        if case .working(let n) = h.phase { return "iter \(n) · running" }
        let lastWorking = h.iterations.last?.number
        return lastWorking.map { "iter \($0)" } ?? "queued"
    }

    private func reviewSubtitle(_ h: HarnessOrchestrator) -> String {
        if case .reviewing(let n) = h.phase { return "iter \(n) · checking" }
        let lastReview = h.iterations.last(where: { $0.passed != nil })
        return lastReview.map { it in
            it.passed == true ? "iter \(it.number) · pass" : "iter \(it.number) · fail"
        } ?? "queued"
    }

    private func phaseStep(_ label: String, subtitle: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 11) {
            if active {
                V2PulseDot(size: 8, color: v2.ink)
            } else if done {
                Circle().fill(v2.add).frame(width: 8, height: 8)
            } else {
                Circle().stroke(v2.line2, lineWidth: 1).frame(width: 8, height: 8)
            }
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle).foregroundColor(v2.faint)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(active ? v2.card : Color.clear)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var arrow: some View {
        Text("↓")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(v2.faint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private func iterationRow(_ it: HarnessIteration, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", it.number))
                .foregroundColor(it.passed == nil ? v2.ink : v2.faint)
            Text(rowSummary(it))
                .foregroundColor(v2.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            statusIcon(it)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(v2.line).frame(height: 1)
            }
        }
    }

    private func rowSummary(_ it: HarnessIteration) -> String {
        if !it.reviewVerdict.isEmpty { return it.reviewVerdict }
        if !it.workSummary.isEmpty { return String(it.workSummary.prefix(140)) }
        return "in progress"
    }

    @ViewBuilder
    private func statusIcon(_ it: HarnessIteration) -> some View {
        switch it.passed {
        case .some(true):  Text("✓ pass").foregroundColor(v2.add)
        case .some(false): Text("✗ fail").foregroundColor(v2.mute)
        case .none:
            HStack(spacing: 5) {
                V2PulseDot(size: 6, color: v2.ink)
                Text("running")
            }
            .foregroundColor(v2.mute)
        }
    }
}

// MARK: - Live observer wrapper

private struct V2HarnessLiveView: View {
    @ObservedObject var harness: HarnessOrchestrator
    let panel: V2HarnessPanel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    panel.goalSection(harness)
                    panel.phaseDiagram(harness)
                    panel.planSection(harness)
                    panel.iterationsSection(harness)
                    panel.progressFileSection(harness)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            panel.footer(harness)
        }
    }
}
