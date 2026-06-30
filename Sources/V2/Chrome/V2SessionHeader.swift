// Session header — bound to V2AppState's active tab (a TerminalTab from
// TerminalsController). Shows project name + LIVE badge driven by surface
// state, path subline with model, dock switcher, mode toggle pill, and
// the live Running pill.

import SwiftUI
import Inject

enum V2DockPanel: String, CaseIterable, Identifiable {
    case loop, harness, agents, mcp
    var id: String { rawValue }
}

struct V2SessionHeader: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @Binding var dockPanel: V2DockPanel

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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(headerTitle)
                        .font(.system(size: 19, weight: .medium))
                        .kerning(-0.38)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showLive { liveBadge }
                }
                pathSublineView
            }
            .layoutPriority(1)       // identity wins remaining space over Spacer

            Spacer(minLength: 12)

            HStack(spacing: 10) {
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

    private var headerTitle: String {
        appState.activeTab?.title ?? appState.selectedProjectName.ifEmpty("no project")
    }

    private var pathSublineView: some View {
        HStack(spacing: 6) {
            Text(pathText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
            // Inline chip — the design-spec'd model switcher (Atelier
            // app.dc.html → SWITCH MODEL popover). Always rendered; the
            // chip disables itself when there's no active session.
            V2ModelChip()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pathText: String {
        appState.activeTab?.projectCwd
            ?? appState.selectedProjectCwd?.path
            ?? "—"
    }

    private var showLive: Bool {
        guard let tab = appState.activeTab else { return false }
        switch tab.surface {
        case .modeA: return tab.isLive
        case .modeB:
            guard let s = tab.streamSession else { return false }
            switch s.state {
            case .idle, .terminated: return false
            default: return true
            }
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(v2.ink).frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, design: .monospaced))
                .kerning(0.8)
        }
        .foregroundColor(v2.mute)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
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
            .help("Switch dock panel")
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
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
    }

    private var runningPill: some View {
        Menu {
            // Model selection moved out of this menu — it now lives as an
            // inline chip in the path subline (V2ModelChip), per
            // Atelier app.dc.html spec.
            permissionMenuSection
            Divider()
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

    @ViewBuilder
    private var permissionMenuSection: some View {
        Section("Permission mode") {
            ForEach(V2PermissionMode.allCases) { mode in
                Button {
                    // Routes through V2AppState so bypass (launch-only) gets a
                    // seamless --resume restart instead of silently reverting.
                    appState.changePermissionMode(mode.rawValue)
                } label: {
                    HStack {
                        Text(mode.label)
                        if appState.activeSession?.permissionMode == mode.rawValue {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(appState.activeSession == nil)
            }
        }
    }

    private func restartActiveSession() {
        guard let tab = appState.activeTab,
              let session = tab.streamSession,
              let binary = appState.claudeBinary else { return }
        session.stop()
        // Brief delay to let the previous process clean up. The new
        // StreamSession is built fresh by V2AppState.attachLoop pattern —
        // here we just call session.start again on the existing one.
        let cwd = URL(fileURLWithPath: tab.projectCwd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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
                    case .idle:
                        Circle().stroke(v2.line2, lineWidth: 1).frame(width: 7, height: 7)
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
            case .ready: return "Ready"
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
    var label: String {
        switch self {
        case .plan:              return "plan — read-only, no changes"
        case .default:           return "default — ask for each tool"
        case .acceptEdits:       return "accept edits — auto-allow file edits"
        case .bypassPermissions: return "bypass — allow everything"
        }
    }
}
