// Inline model picker for the session header's path subline. Matches the
// Atelier app.dc.html spec: chip-styled trigger button next to the path, a
// popover with one row per model (active dot · name · tag chip · description),
// active model highlighted with a card background + inset ink shadow, footer
// hint that the switch lands on the next user turn.

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

struct V2ModelPicker: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @Binding var isPresented: Bool

    private var activeId: String {
        // Live session's model, else the persisted spawn default — so the
        // checkmark is honest in both modes ("" default ⇒ the CLI default row).
        appState.activeSession?.model ?? appState.defaultSpawnModel
    }

    /// The binary's own model catalog — the authoritative, current list (new
    /// models appear here the day the CLI ships them, no history required).
    /// Live session's copy first; otherwise the app-wide persisted catalog, so
    /// the picker works with NO session (sets the default for future spawns).
    private var available: [V2AvailableModel] {
        if let live = appState.activeSession?.availableModels, !live.isEmpty { return live }
        return appState.modelCatalog
    }

    private var models: [V2DiscoveredModel] {
        // Prefer what THIS binary says it supports. The id is the alias
        // set_model accepts ("sonnet", "opus[1m]"); the tag shows the concrete
        // model it resolves to.
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
        // Fallback (no live catalog yet): discovered from history + the
        // currently-active model if claude reports one we haven't seen.
        var seen = Set(appState.discoveredModels.map(\.id))
        var list = appState.discoveredModels
        let activeBare = String(activeId.split(separator: "[").first ?? Substring(activeId))
        if !activeBare.isEmpty, activeBare.contains("-"), !seen.contains(activeBare) {
            list.insert(
                V2DiscoveredModel(
                    id: activeBare,
                    displayName: activeBare,
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

    /// "claude-sonnet-5[1m]" → "sonnet-5" for the row's right-hand tag.
    private static func shortResolved(_ id: String) -> String {
        var s = String(id.split(separator: "[").first ?? Substring(id))
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if models.isEmpty {
                Text("No model catalog yet — start one session to populate it.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
            } else {
                ForEach(models) { option in
                    row(for: option)
                    if option.id != models.last?.id {
                        Divider().background(v2.line)
                    }
                }
            }
            footer
        }
        .frame(width: 320)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .enableInjection()
    }

    private var sectionHeader: some View {
        Text("SWITCH MODEL")
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(v2.faint)
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        Text(appState.activeSession == nil ? "applies to new sessions" : "takes effect on next message")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(v2.faint)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper2)
            .overlay(alignment: .top) {
                Rectangle().fill(v2.line).frame(height: 1)
            }
    }

    private func row(for option: V2DiscoveredModel) -> some View {
        let isActive = isActive(option)
        return Button {
            // Live session (if any) switches now; the pick ALWAYS persists as
            // the spawn default so new tabs/sessions keep it. Picking
            // "Default (recommended)" persists as empty, which start() treats
            // as "omit --model" so the CLI's own default applies.
            appState.activeSession?.setModel(option.id)
            appState.defaultSpawnModel = (option.id == "default") ? "" : option.id
            isPresented = false
        } label: {
            VStack(alignment: .leading, spacing: 3) {
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
                HStack(spacing: 7) {
                    Text(option.description)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                    if option.usageCount > 0 {
                        Text("· \(V2Format.count(option.usageCount)) turns")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(v2.faint.opacity(0.7))
                    }
                }
                .padding(.leading, 16)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? v2.card : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle().fill(v2.ink).frame(width: 2)
                }
            }
            // Make the WHOLE row the hit target, not just the text. Without
            // this a .plain Button only registers clicks on its glyphs.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isActive(_ option: V2DiscoveredModel) -> Bool {
        let raw = normalize(activeId)
        // No session + empty default ⇒ the CLI's own default is in effect.
        if appState.activeSession == nil && raw.isEmpty { return option.id == "default" }
        // Catalog rows: the option id is an alias ("sonnet") — compare the
        // concrete model it RESOLVES to against what the session reports, and
        // the alias itself against a persisted default.
        if let avail = available.first(where: { $0.value == option.id }) {
            return normalize(avail.resolvedModel) == raw || normalize(avail.value) == raw
        }
        let opt = normalize(option.id)
        if raw == opt { return true }
        // Tolerate the "claude-sonnet-4-8" / "sonnet" / "claude-sonnet-4-8[1m]"
        // variants — match if either string is a prefix of the other.
        return raw.hasPrefix(opt) || opt.hasPrefix(raw)
    }

    /// Lowercase + strip a "[1m]"-style suffix so variants compare equal.
    private func normalize(_ s: String) -> String {
        String(s.lowercased().split(separator: "[").first ?? Substring(s.lowercased()))
    }
}

// MARK: - Trigger chip used inside V2SessionHeader's path subline

struct V2ModelChip: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var open = false

    /// Chip label: live session's model, else the persisted spawn default
    /// ("" ⇒ the CLI's own default).
    private var chipLabel: String {
        if let m = appState.activeSession?.model { return V2ModelOption.displayLabel(for: m) }
        let d = appState.defaultSpawnModel
        return d.isEmpty ? "default" : V2ModelOption.displayLabel(for: d)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(chipLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            // Never let the model id wrap vertically (one char per line) when
            // the header column is squeezed — keep it on one line, truncating.
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        // Usable without a session once a catalog is known — picking then sets
        // the default for future spawns.
        .disabled(appState.activeSession == nil && appState.modelCatalog.isEmpty)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            V2ModelPicker(isPresented: $open)
                .environmentObject(appState)
        }
    }
}
