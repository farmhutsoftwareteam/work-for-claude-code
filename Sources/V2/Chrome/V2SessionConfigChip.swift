// Unified session-config pill — model + effort + permissions in one control.
// Implements "Session config.dc.html": replaces the old inert model-chip
// buried in the path subline with one visible bordered pill in the header's
// top-right controls, opening a single popover with all three as sections —
// same bordered-row visual language the old model-only popover already
// used, just consolidated instead of three separate patterns (model chip +
// runningPill's permission menu + no effort control at all).
//
// Effort's "restarts session" framing isn't a guess the design left open —
// it's resolved: verified live against the real binary that system/init
// never reports an effort catalog, and every plausible set_effort-style
// control request subtype comes back "Unsupported control request subtype."
// --effort is real (confirmed via `claude --help`) but launch-time only, so
// picking a level always restarts (StreamSession.effort / V2AppState.
// changeEffort), the same seamless --resume restart bypassPermissions
// already uses for exactly the same reason.

import SwiftUI
import Inject

enum V2ModelOption {
    /// Best-effort match against StreamSession's model string, which may be
    /// either the bare alias ("sonnet") or the explicit id ("claude-sonnet-4-8")
    /// — claude reports back whatever it resolved.
    static func displayLabel(for raw: String) -> String {
        guard !raw.isEmpty else { return "claude" }
        // Strip cache tags like "claude-opus-4-8[1m]" the system/init emits.
        return String(raw.split(separator: "[").first ?? Substring(raw))
    }
}

/// The real, confirmed `--effort` catalog, straight off `claude --help`.
/// NOT derived from system/init — verified live that event never reports
/// one — so this is the CLI's own documented set, not a guess.
enum V2EffortCatalog {
    static let levels = ["low", "medium", "high", "xhigh", "max"]
}

// MARK: - Trigger chip used inside V2SessionHeader's top-right controls

struct V2SessionConfigChip: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var open = false
    // Same breakpoints V2SessionHeader derives from its own measured width —
    // every other header control (modePill, dockSwitcher, runningPill) sheds
    // detail at these thresholds; this one didn't (shipped with a hardcoded
    // .fixedSize that could never shrink), which is what pinned the whole
    // window's minimum width via .windowResizability(.contentMinSize) —
    // "the app feels bigger, it won't fit" (user report, 2026-07-14).
    let isCompact: Bool
    let isTight: Bool

    private var chipModelLabel: String {
        if let m = appState.activeSession?.model { return V2ModelOption.displayLabel(for: m) }
        let d = appState.defaultSpawnModel
        return d.isEmpty ? "default" : V2ModelOption.displayLabel(for: d)
    }
    private var chipEffortLabel: String {
        let e = appState.activeSession?.effort ?? appState.defaultSpawnEffort
        return e.isEmpty ? "default" : e
    }
    private var chipPermissionLabel: String {
        let mode = appState.activeSession?.permissionMode ?? appState.defaultPermissionMode
        return V2PermissionMode(rawValue: mode)?.shortLabel ?? mode
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: isTight ? 6 : 9) {
                HStack(spacing: 6) {
                    Circle().fill(v2.ink).frame(width: 6, height: 6)
                    // Model name is the one thing that stays even at the
                    // tightest breakpoint — a bare dot + chevron would carry
                    // no information at all (every other header control
                    // keeps at least a glyph or short label this small).
                    // Fixed-width + truncating, NOT auto-sized to content:
                    // an auto-sized label made the pill's own width (and so
                    // its on-screen position, anchored by the header's
                    // trailing controls group) shift every time you picked a
                    // different model — "sonnet" vs "claude-opus-4-8" are
                    // very different lengths. A constant-width truncating
                    // label keeps the pill's footprint constant regardless
                    // of what's selected (user report, 2026-07-14).
                    Text(chipModelLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: isTight ? 50 : 64, alignment: .leading)
                }
                if !isCompact {
                    Rectangle().fill(v2.line2).frame(width: 1, height: 13)
                    Text(chipEffortLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 46, alignment: .leading)
                    Rectangle().fill(v2.line2).frame(width: 1, height: 13)
                    Text(chipPermissionLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 84, alignment: .leading)
                        .foregroundColor(v2.mute)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(v2.ink)
            .padding(.horizontal, isTight ? 8 : 12)
            .padding(.vertical, 7)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Usable without a session once a catalog is known — picking then
        // sets the defaults for future spawns (same as the old model-only
        // chip's behavior, now true of all three sections).
        .disabled(appState.activeSession == nil && appState.modelCatalog.isEmpty)
        .help("\(chipModelLabel) · \(chipEffortLabel) · \(chipPermissionLabel)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            V2SessionConfigPanel()
                .environmentObject(appState)
        }
    }
}

// MARK: - Popover panel

private struct V2SessionConfigPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState

    private var activeModelId: String {
        appState.activeSession?.model ?? appState.defaultSpawnModel
    }
    private var available: [V2AvailableModel] {
        if let live = appState.activeSession?.availableModels, !live.isEmpty { return live }
        return appState.modelCatalog
    }
    private var models: [V2DiscoveredModel] {
        if !available.isEmpty {
            return available.map { m in
                V2DiscoveredModel(
                    id: m.value,
                    displayName: m.displayName,
                    tag: Self.shortResolved(m.resolvedModel),
                    description: m.description,
                    usageCount: 0
                )
            }
        }
        var seen = Set(appState.discoveredModels.map(\.id))
        var list = appState.discoveredModels
        let activeBare = String(activeModelId.split(separator: "[").first ?? Substring(activeModelId))
        if !activeBare.isEmpty, activeBare.contains("-"), !seen.contains(activeBare) {
            list.insert(
                V2DiscoveredModel(
                    id: activeBare, displayName: activeBare,
                    tag: V2DiscoveredModel.tag(for: activeBare),
                    description: V2DiscoveredModel.description(for: activeBare),
                    usageCount: 0
                ),
                at: 0
            )
            seen.insert(activeBare)
        }
        return list
    }
    private static func shortResolved(_ id: String) -> String {
        var s = String(id.split(separator: "[").first ?? Substring(id))
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        return s
    }
    private func isActiveModel(_ option: V2DiscoveredModel) -> Bool {
        let raw = normalize(activeModelId)
        if appState.activeSession == nil && raw.isEmpty { return option.id == "default" }
        if let avail = available.first(where: { $0.value == option.id }) {
            return normalize(avail.resolvedModel) == raw || normalize(avail.value) == raw
        }
        let opt = normalize(option.id)
        if raw == opt { return true }
        return raw.hasPrefix(opt) || opt.hasPrefix(raw)
    }
    private func normalize(_ s: String) -> String {
        String(s.lowercased().split(separator: "[").first ?? Substring(s.lowercased()))
    }

    private var activeEffort: String { appState.activeSession?.effort ?? appState.defaultSpawnEffort }
    private var activePermission: String { appState.activeSession?.permissionMode ?? appState.defaultPermissionMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("MODEL")
            if models.isEmpty {
                Text("No model catalog yet — start one session to populate it.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
            } else {
                ForEach(models) { option in
                    modelRow(option)
                    if option.id != models.last?.id { Divider().background(v2.line) }
                }
            }

            HStack {
                sectionHeader("EFFORT")
                Spacer()
                Text("restarts session")
                    .font(.system(size: 9.5, design: .monospaced))
                    .kerning(0.4)
                    .foregroundColor(v2.del)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
            }
            .padding(.trailing, 13)
            .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
            effortControl

            sectionHeader("PERMISSIONS")
                .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
            ForEach(V2PermissionMode.allCases) { mode in
                permissionRow(mode)
            }

            footer
        }
        .frame(width: 340)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .enableInjection()
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(v2.faint)
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func modelRow(_ option: V2DiscoveredModel) -> some View {
        let isActive = isActiveModel(option)
        return Button {
            appState.activeSession?.setModel(option.id)
            appState.defaultSpawnModel = (option.id == "default") ? "" : option.id
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(isActive ? v2.ink : Color.clear)
                    .overlay(Circle().stroke(isActive ? Color.clear : v2.line2, lineWidth: 1))
                    .frame(width: 7, height: 7)
                Text(option.displayName)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(v2.ink)
                Spacer()
                Text(option.tag)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? v2.card : Color.clear)
            .overlay(alignment: .leading) {
                if isActive { Rectangle().fill(v2.ink).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var effortControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(V2EffortCatalog.levels, id: \.self) { level in
                    let active = level == activeEffort
                    Button {
                        appState.changeEffort(level)
                    } label: {
                        Text(level)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(active ? v2.paper : v2.mute)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(active ? v2.ink : v2.paper2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            Text(appState.activeSession == nil
                ? "applies to new sessions"
                : "changing effort starts a new session — current context is preserved, in-flight work is not")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
    }

    private func permissionRow(_ mode: V2PermissionMode) -> some View {
        let isActive = mode.rawValue == activePermission
        return Button {
            appState.changePermissionMode(mode.rawValue)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isActive ? v2.ink : Color.clear)
                        .overlay(Circle().stroke(isActive ? Color.clear : v2.line2, lineWidth: 1))
                        .frame(width: 6, height: 6)
                    Text(mode.shortLabel)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(v2.ink)
                }
                if mode == .bypassPermissions {
                    Text("no safety rails")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.del)
                        .padding(.leading, 13)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? v2.card : Color.clear)
            .overlay(alignment: .leading) {
                if isActive { Rectangle().fill(v2.ink).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        Text("model & permissions apply next message · effort restarts the session")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(v2.faint)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper2)
            .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }
}
