// Session tabs strip — one chip per TerminalTab, with the four-state status
// language from the "Tab states" design. Selection (card bg + inset border) is
// SEPARATE from status (the dot + underline):
//
//   • Idle       — hollow ring, no motion.
//   • Working    — ink dot + pulsing radar ring + an indeterminate line under
//                  the tab + a live elapsed timer.
//   • Done·unseen— sage dot + sage underline. A turn finished while you were on
//                  another tab; clears when you view it (V2AppState.unseenDone).
//   • Needs you  — clay dot with a glowing halo + clay underline. Blocked on you.
//
// Done / Needs-you also fire an attention sound for BACKGROUND tabs (V2Sound).

import SwiftUI
import Inject

// workingBackground (#69/#71 design "tab signaling"): the turn itself
// finished, but a background task the turn started is still running in
// this tab's project. Same dot as .working, deliberately calmer ring —
// present, not urgent, so it never competes with a tab that's actually
// replying right now.
enum V2TabStatus { case idle, working, workingBackground, needsYou, doneUnseen }

struct V2SessionTabs: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var terminals: TerminalsController

    var body: some View {
        if allTabs.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(allTabs) { tab in
                        V2TabChip(
                            tab: tab,
                            status: appState.tabStatus(tab),
                            isActive: tab.id == appState.activeTabId,
                            showProject: multipleProjectsOpen,
                            onActivate: { appState.activate(tabId: tab.id) },
                            onClose: { appState.close(tabId: tab.id) }
                        )
                    }
                    newTabButton
                }
            }
            .frame(height: 52)
            .background(v2.paper2)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            .enableInjection()
        }
    }

    private var newTabButton: some View {
        Button { appState.newTab() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(v2.faint)
                .frame(width: 40, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New chat in \(appState.selectedProjectName.isEmpty ? "this project" : appState.selectedProjectName) (⌘N)")
    }

    /// All open tabs across every project — nothing is hidden (browser model).
    private var allTabs: [TerminalTab] { terminals.tabs }

    private var multipleProjectsOpen: Bool {
        Set(terminals.tabs.map { $0.projectCwd }).count > 1
    }
}

// MARK: - Tab chip

private struct V2TabChip: View {
    @Environment(\.v2) private var v2
    @ObservedObject private var iconLoader = ProjectIconLoader.shared
    let tab: TerminalTab
    let status: V2TabStatus
    let isActive: Bool
    var showProject: Bool = false
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            statusGlyph
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 14))
                    .fontWeight(isActive ? .medium : .regular)
                    .kerning(-0.14)
                    .foregroundColor(v2.ink)
                    .lineLimit(1).truncationMode(.tail)
                if showProject {
                    Text(projectLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: 128, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(isActive ? v2.card : Color.clear)
        .overlay { if isActive { Rectangle().stroke(v2.line2, lineWidth: 1) } }
        // Status underline (done/needs) OR the working indeterminate line —
        // mutually exclusive, both pinned to the tab's bottom edge.
        .overlay(alignment: .bottom) { statusUnderline }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        // Chrome's favicon↔spinner pattern: the project logo is the RESTING
        // visual; status overlays it (radar ring while working, clay glow when
        // blocked). No logo (or none that passed the quality gates) → the
        // original dot language, unchanged.
        if let icon = iconLoader.icon(for: tab.projectCwd) {
            ZStack {
                if status == .needsYou {
                    V2PulseDot(size: 19, color: v2.del.opacity(0.45))
                }
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
                if status == .working {
                    V2RadarRing(color: v2.ink)
                }
                if status == .workingBackground {
                    V2RadarRing(color: v2.ink, slow: true)
                }
                if status == .doneUnseen {
                    // Sage corner tick — the underline carries the state; this
                    // keeps it legible even when the underline is off-screen.
                    Circle().fill(v2.add).frame(width: 6, height: 6)
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 14, height: 14)
        } else {
            ZStack {
                switch status {
                case .idle:
                    Circle().stroke(v2.faint, lineWidth: 1).frame(width: 9, height: 9)
                case .working:
                    V2PulseDot(size: 9, color: v2.ink)
                    V2RadarRing(color: v2.ink)
                case .workingBackground:
                    // Dot holds steady — the turn already said what it had
                    // to say. Only the ring, slower, signals "still going."
                    Circle().fill(v2.ink).frame(width: 9, height: 9)
                    V2RadarRing(color: v2.ink, slow: true)
                case .doneUnseen:
                    Circle().fill(v2.add).frame(width: 9, height: 9)
                case .needsYou:
                    V2GlowDot(color: v2.del)
                }
            }
            .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if status == .working, let started = tab.streamSession?.turnStartedAt {
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                Text(Self.elapsed(since: started, now: ctx.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .monospacedDigit()
            }
            .frame(minWidth: 30, alignment: .trailing)
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor((hover || isActive) ? v2.mute : v2.faint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusUnderline: some View {
        switch status {
        case .doneUnseen:
            Rectangle().fill(v2.add).frame(height: 2).padding(.horizontal, 10)
        case .needsYou:
            Rectangle().fill(v2.del).frame(height: 2).padding(.horizontal, 10)
        case .working:
            V2IndeterminateLine(color: v2.ink)
        case .idle, .workingBackground:
            // Deliberately no underline for the background-task case — the
            // busy progress-bar reads as active foreground work, which is
            // exactly what this state isn't. The dot+ring alone carries it.
            EmptyView()
        }
    }

    private var projectLabel: String { (tab.projectCwd as NSString).lastPathComponent }

    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Status animations (GeometryReader-free, per PERFORMANCE.md)

/// A ring that scales out and fades — the "working" radar pulse.
private struct V2RadarRing: View {
    let color: Color
    /// The background-task variant: slower (2.6s vs 1.8s), dimmer at rest
    /// (.32 vs .55), and a smaller max scale (2.3 vs 2.6) — matches the
    /// design's radarslow keyframe exactly. "Present, not urgent."
    var slow: Bool = false
    @State private var animate = false
    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1)
            .frame(width: 9, height: 9)
            .scaleEffect(animate ? (slow ? 2.3 : 2.6) : 1)
            .opacity(animate ? 0 : (slow ? 0.32 : 0.55))
            .onAppear {
                withAnimation(.easeOut(duration: slow ? 2.6 : 1.8).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

/// Filled dot with a soft expanding halo — the "needs you" cue.
private struct V2GlowDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .background(
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 9, height: 9)
                    .scaleEffect(on ? 2.0 : 1.0)
                    .opacity(on ? 0 : 0.85)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// A 2pt bar sliding left→right under a working tab. Fixed-width bar offset
/// across a clipped full-width track — no GeometryReader (the slide range
/// covers the max tab width; the clip hides the overflow).
private struct V2IndeterminateLine: View {
    let color: Color
    @State private var slide = false
    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            Rectangle()
                .fill(color)
                .frame(width: 64, height: 2)
                .offset(x: slide ? 240 : -72)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 2)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { slide = true }
        }
    }
}
