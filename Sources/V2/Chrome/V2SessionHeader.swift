// Session header — bound to V2AppState's active tab (a TerminalTab from
// TerminalsController). Shows the project path subline, the unified
// session-config pill (model/effort/permissions), dock switcher, mode
// toggle pill, and the live Running pill. Session name and live state
// live on the tab strip now, not duplicated here.

import SwiftUI
import Inject

enum V2DockPanel: String, CaseIterable, Identifiable {
    case loop, harness, agents, mcp, skills
    var id: String { rawValue }
}

struct V2SessionHeader: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var store: Store
    @Binding var dockPanel: V2DockPanel

    /// The active session has a live MCP server that's failed / needs auth, or
    /// the current project has a configured server that needs sign-in. Drives
    /// the red badge on the dock's `mcp` control.
    private var mcpAlert: Bool {
        if let servers = appState.activeSession?.mcpServers, !servers.isEmpty {
            let bad = servers.contains {
                let s = ($0.status ?? "").lowercased()
                return s == "needs-auth" || s == "failed" || s == "error"
            }
            if bad { return true }
        }
        let cwd = appState.activeTab?.projectCwd ?? appState.selectedProjectCwd?.path ?? ""
        return store.projectHasUnconnectedMCP(cwd)
    }

    /// Measured header width, used to choose how much the right-side controls
    /// collapse. The identity block (title + path + model) always truncates
    /// first; below the breakpoint the controls shed their labels too.
    @State private var headerWidth: CGFloat = 0
    private var isCompact: Bool { headerWidth > 0 && headerWidth < 700 }
    private var isTight: Bool { headerWidth > 0 && headerWidth < 520 }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            V2DovetailMark(size: 30)
                .foregroundColor(v2.ink)
                .layoutPriority(2)   // the mark never gets squeezed

            // Session name dropped — the tab strip already names it, showing
            // it twice just squeezed everything else in a narrow header.
            pathSublineView
                .layoutPriority(1)       // identity wins remaining space over Spacer

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                V2SessionConfigChip(isCompact: isCompact, isTight: isTight)
                modePill
                dockSwitcher
                runningPill
            }
            .layoutPriority(2)       // controls keep their (compact) size
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: V2WidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(V2WidthKey.self) { headerWidth = $0 }
        .enableInjection()
    }

    private var pathSublineView: some View {
        // The model chip that used to live here (V2ModelChip) moved into
        // V2SessionConfigChip in the top-right controls — one unified
        // model/effort/permissions pill instead of an inert subline chip
        // (Session config.dc.html).
        Text(pathText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(v2.faint)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pathText: String {
        appState.activeTab?.projectCwd
            ?? appState.selectedProjectCwd?.path
            ?? "—"
    }

    private var modePill: some View {
        let isModeA = appState.activeTab?.surface == .modeA
        let label = isModeA ? "terminal" : "chat"
        let help = isModeA
            ? "Switch to native chat (Mode B)"
            : "Switch to embedded terminal (Mode A)"

        return Button {
            appState.flipActiveMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isModeA ? "terminal" : "text.bubble")
                    .font(.system(size: 10, weight: .medium))
                if !isCompact {
                    Text(label)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                }
            }
            .foregroundColor(v2.ink)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, isCompact ? 8 : 11)
            .padding(.vertical, 7)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(appState.activeTab == nil)
        .keyboardShortcut("y", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var dockSwitcher: some View {
        if isCompact {
            // Collapsed: a single dropdown that names the current panel. Frees
            // ~170px versus the four-segment control while keeping every panel
            // one click away and showing which one is active.
            Menu {
                ForEach(V2DockPanel.allCases) { panel in
                    Button {
                        dockPanel = panel
                    } label: {
                        HStack {
                            Text(panel.rawValue)
                            if dockPanel == panel { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(dockPanel.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                        .foregroundColor(v2.ink)
                    if mcpAlert {
                        Circle().fill(v2.del).frame(width: 6, height: 6)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(v2.mute)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .help(mcpAlert ? "An MCP server needs sign-in" : "Switch dock panel")
        } else {
            HStack(spacing: 0) {
                ForEach(V2DockPanel.allCases) { panel in
                    Button {
                        dockPanel = panel
                    } label: {
                        Text(panel.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .kerning(0.22)
                            .foregroundColor(dockPanel == panel ? v2.paper : v2.mute)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(dockPanel == panel ? v2.ink : v2.card)
                    }
                    .buttonStyle(.plain)
                    // Red badge on the MCP tab when a server needs sign-in /
                    // isn't connected — visible whichever panel is open.
                    .overlay(alignment: .topTrailing) {
                        if panel == .mcp && mcpAlert {
                            Circle().fill(v2.del).frame(width: 6, height: 6)
                                .offset(x: -3, y: 3)
                                .help("An MCP server needs sign-in")
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
    }

    private var runningPill: some View {
        Menu {
            // Model + permission mode both moved out of this menu — they
            // live in the unified V2SessionConfigChip now (Session
            // config.dc.html consolidates model/effort/permissions into one
            // popover instead of three separate patterns).
            Button("Restart session") { restartActiveSession() }
                .disabled(appState.activeSession == nil)
            Button("Switch to terminal (Mode A)") { appState.flipActiveMode() }
                .disabled(appState.activeTab == nil)
        } label: {
            HStack(spacing: 7) {
                stateDot
                if !isTight {
                    Text(stateLabel)
                        .font(.system(size: 11.5, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .padding(.leading, isTight ? 0 : 2)
            }
            .foregroundColor(v2.ink)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, isTight ? 9 : 12)
            .padding(.vertical, 7)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(stateLabel)
    }

    private func restartActiveSession() {
        guard let tab = appState.activeTab,
              let session = tab.streamSession,
              let binary = appState.claudeBinary else { return }
        // Polls for teardown to actually finish instead of guessing a fixed
        // delay — a bare asyncAfter here could fire start() before stop()'s
        // async cleanup finished (silent no-op) or after the tab closed
        // (orphaned process). See V2AppState.restartAfterStop.
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        appState.restartAfterStop(tabId: tab.id, session: session) {
            session.start(cwd: cwd, claudeURL: binary)
        }
    }

    @ViewBuilder
    private var stateDot: some View {
        if let tab = appState.activeTab {
            switch tab.surface {
            case .modeA:
                if tab.isLive {
                    V2PulseDot(size: 7, color: v2.ink)
                } else {
                    Circle().fill(v2.del).frame(width: 7, height: 7)
                }
            case .modeB:
                if let s = tab.streamSession {
                    switch s.state {
                    case .working, .awaitingPermission:
                        V2PulseDot(size: 7, color: v2.ink)
                    case .terminated:
                        Circle().fill(v2.del).frame(width: 7, height: 7)
                    case .idle, .hibernated:
                        // Resting reads as quiet, not dead — hollow like idle.
                        Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
                    case .ready where appState.tabStatus(tab) == .workingBackground:
                        // The FOREGROUND turn is done, but a delegated
                        // subagent or a `run_in_background` shell command
                        // it started is still going. This is the header —
                        // the one indicator that's always on screen
                        // regardless of scroll position — so it used to go
                        // straight to a flat "Ready" the instant the reply
                        // landed, even while real work continued off-screen
                        // (the tab strip's own calmer ring was the only
                        // surviving cue, and it's easy to miss). Same slow
                        // ring language as the tab chip, not the vivid
                        // working pulse — still present, not urgent.
                        ZStack {
                            Circle().fill(v2.ink).frame(width: 7, height: 7)
                            V2RadarRing(color: v2.ink, slow: true)
                        }
                    default:
                        Circle().fill(v2.ink).frame(width: 7, height: 7)
                    }
                } else {
                    Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
                }
            }
        } else {
            Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
        }
    }

    private var stateLabel: String {
        guard let tab = appState.activeTab else { return "No session" }
        switch tab.surface {
        case .modeA:
            return tab.isLive ? "Terminal" : "Ended"
        case .modeB:
            guard let s = tab.streamSession else { return "Idle" }
            switch s.state {
            case .idle: return "Idle"
            case .ready:
                return appState.tabStatus(tab) == .workingBackground ? "Working in background" : "Ready"
            case .hibernated: return "Resting"
            case .spawning: return "Spawning"
            case .initializing: return "Initializing"
            case .working: return s.isRetrying ? "Retrying" : "Running"
            case .awaitingPermission: return "Awaiting permission"
            case .closing: return "Closing"
            case .terminated: return "Ended"
            }
        }
    }
}

// MARK: - Width measurement

/// Reports a view's measured width up the tree so the header can pick a
/// responsive layout. Uses `max` so a transient zero never wins.
struct V2WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Pulse dot (used across v2 surfaces)

struct V2PulseDot: View {
    let size: CGFloat
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 0.25 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Model + permission catalogs (used by the running pill menu)

enum V2PermissionMode: String, CaseIterable, Identifiable {
    // Only the modes claude actually accepts on --permission-mode /
    // set_permission_mode. The old enum had "dontAsk" / "auto" which aren't
    // real and would make the spawn reject the flag. Ordered least → most
    // permissive so "increase" reads top-to-bottom.
    case plan
    case `default`
    case acceptEdits
    case bypassPermissions
    var id: String { rawValue }
    /// Row/chip label for V2SessionConfigChip — no dash-suffixed description,
    /// that's carried by the row's own warn line (bypassPermissions) instead.
    var shortLabel: String {
        switch self {
        case .plan:              return "Plan"
        case .default:           return "Default"
        case .acceptEdits:       return "Accept edits"
        case .bypassPermissions: return "Bypass permissions"
        }
    }
}
