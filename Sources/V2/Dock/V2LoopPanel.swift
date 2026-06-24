// Loop dock panel — live view of the active tab's LoopOrchestrator.
// Empty state if none is configured; live state machine + turns log when one
// is running or finished. Pause is not yet supported (deferred); Stop is.
//
// Mode-A tabs and tabs without a StreamSession show an explanation —
// loops need a long-lived doer, which is what Mode B provides.

import SwiftUI
import Inject

struct V2LoopPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var showingNewLoop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .sheet(isPresented: $showingNewLoop) {
            if let tab = appState.activeTab,
               let session = tab.streamSession,
               let binary = appState.claudeBinary {
                V2NewLoopSheet(
                    cwd: URL(fileURLWithPath: tab.projectCwd),
                    doer: session,
                    claudeURL: binary,
                    onStart: { loop in
                        appState.attachLoop(loop, toTab: tab.id)
                        showingNewLoop = false
                        loop.start()
                    },
                    onCancel: { showingNewLoop = false }
                )
            }
        }
        .enableInjection()
    }

    private var header: some View {
        HStack {
            Text("Loop runner")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            statusIndicator
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let loop = appState.activeTab?.loop {
            HStack(spacing: 6) {
                switch loop.state {
                case .running, .verifying:
                    V2PulseDot(size: 7, color: v2.ink)
                    Text(loop.state == .verifying(turn: 0) ? "verifying" : "running")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                case .passed:
                    Circle().fill(v2.add).frame(width: 7, height: 7)
                    Text("passed").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.add)
                case .failed, .budgetExhausted:
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
            } else if let loop = tab.loop {
                liveLoopView(loop)
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
            Text("Loops need Mode B.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Switch this tab to chat (⌘⇧Y) to run a goal-driven loop.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyState(tab: TerminalTab) -> some View {
        let canStart = tab.streamSession != nil
            && appState.claudeBinary != nil
            && (appState.claudeVersion ?? .init(major: 0, minor: 0, patch: 0)) >= ClaudeBinary.minimumSupported

        return VStack(alignment: .leading, spacing: 12) {
            Text("No loop running on this tab.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)

            Text("A loop drives the chat session to a finish line: you set a goal, a verifier prompt, and a turn budget. The verifier grades each attempt; failures critique back into the doer until it passes or the budget runs out.")
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(11 * 0.55)
                .foregroundColor(v2.faint)

            Button { showingNewLoop = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("Configure loop")
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
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Live loop

    private func liveLoopView(_ loop: LoopOrchestrator) -> some View {
        V2LoopLiveView(loop: loop, panel: self)
    }

    fileprivate func goalSection(_ config: LoopConfig) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("GOAL")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
            Text(config.goal.isEmpty ? "(empty)" : config.goal)
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

    fileprivate func metaGrid(_ loop: LoopOrchestrator) -> some View {
        HStack(spacing: 10) {
            metaCell(label: "VERIFIER", value: "claude -p")
            metaCell(label: "BUDGET", value: "\(currentTurnNumber(loop)) / \(loop.config.maxTurns) turns")
        }
        .padding(.bottom, 20)
    }

    private func currentTurnNumber(_ loop: LoopOrchestrator) -> Int {
        switch loop.state {
        case .running(let n), .verifying(let n): return n
        case .passed:               return loop.turns.last?.number ?? 1
        case .budgetExhausted:      return loop.config.maxTurns
        case .stopped, .failed, .idle: return loop.turns.last?.number ?? 0
        }
    }

    private func metaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(0.76)
                .foregroundColor(v2.faint)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(v2.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
    }

    fileprivate func turnsSection(_ loop: LoopOrchestrator) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TURNS")
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
                .padding(.bottom, 10)

            if loop.turns.isEmpty {
                Text("No turns yet — kicking off the goal…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
            } else {
                ForEach(Array(loop.turns.enumerated()), id: \.element.id) { idx, turn in
                    turnRow(turn, isLast: idx == loop.turns.count - 1)
                }
            }
        }
    }

    private func turnRow(_ turn: LoopTurn, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", turn.number))
                .foregroundColor(turn.state == .running ? v2.ink : v2.faint)
            Text(turn.title)
                .foregroundColor(v2.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            statusIcon(turn.state)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(v2.line).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: LoopTurn.TurnState) -> some View {
        switch state {
        case .running:
            HStack(spacing: 5) {
                V2PulseDot(size: 6, color: v2.ink)
                Text("running")
            }
            .foregroundColor(v2.mute)
        case .pass:
            Text("✓ pass").foregroundColor(v2.add)
        case .fail:
            Text("✗ fail").foregroundColor(v2.mute)
        }
    }

    fileprivate func footer(loop: LoopOrchestrator) -> some View {
        HStack(spacing: 10) {
            switch loop.state {
            case .running, .verifying:
                Button { loop.stop() } label: {
                    Text("stop loop")
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
                        appState.attachLoop(nil, toTab: tab.id)
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

                Button { showingNewLoop = true } label: {
                    Text("new loop")
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
}

// MARK: - LoopOrchestrator observer wrapper

/// Holds the @ObservedObject so SwiftUI rebuilds when the loop publishes.
/// Re-uses the panel's section builders so we don't duplicate styling.
private struct V2LoopLiveView: View {
    @ObservedObject var loop: LoopOrchestrator
    let panel: V2LoopPanel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    panel.goalSection(loop.config)
                    panel.metaGrid(loop)
                    panel.turnsSection(loop)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            panel.footer(loop: loop)
        }
    }
}
