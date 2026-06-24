// Inline model picker for the session header's path subline. Matches the
// Atelier app.dc.html spec: chip-styled trigger button next to the path, a
// popover with one row per model (active dot · name · tag chip · description),
// active model highlighted with a card background + inset ink shadow, footer
// hint that the switch lands on the next user turn.

import SwiftUI
import Inject

struct V2ModelOption: Identifiable, Equatable {
    /// What we pass to `claude --model` / `set_model`. Catalog mirrors the
    /// design spec one-for-one; the actual CLI accepts either family aliases
    /// or these explicit version IDs.
    let id: String
    let displayName: String
    let tag: String
    let description: String

    static let catalog: [V2ModelOption] = [
        .init(
            id: "claude-opus-4-5",
            displayName: "claude-opus-4-5",
            tag: "most capable",
            description: "Best for complex, multi-step tasks"
        ),
        .init(
            id: "claude-sonnet-4-5",
            displayName: "claude-sonnet-4-5",
            tag: "balanced",
            description: "Speed + quality for everyday work"
        ),
        .init(
            id: "claude-haiku-4-5",
            displayName: "claude-haiku-4-5",
            tag: "fast",
            description: "Lightweight checks & quick edits"
        ),
        .init(
            id: "claude-opus-4",
            displayName: "claude-opus-4",
            tag: "previous",
            description: "Stable, proven on long sessions"
        ),
        .init(
            id: "claude-sonnet-4",
            displayName: "claude-sonnet-4",
            tag: "previous",
            description: "Previous-gen balanced model"
        ),
    ]

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
        appState.activeSession?.model ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            ForEach(V2ModelOption.catalog) { option in
                row(for: option)
                if option.id != V2ModelOption.catalog.last?.id {
                    Divider().background(v2.line)
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
        Text("takes effect on next message")
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

    private func row(for option: V2ModelOption) -> some View {
        let isActive = isActive(option)
        return Button {
            appState.activeSession?.setModel(option.id)
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
                Text(option.description)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
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
        }
        .buttonStyle(.plain)
        .disabled(appState.activeSession == nil)
    }

    private func isActive(_ option: V2ModelOption) -> Bool {
        let raw = activeId.lowercased()
        let opt = option.id.lowercased()
        if raw == opt { return true }
        // Tolerate the "claude-sonnet-4-8" / "sonnet" / "claude-sonnet-4-8[1m]"
        // variants — match if either string is a prefix of the other.
        return raw.hasPrefix(opt) || opt.hasPrefix(raw)
    }
}

// MARK: - Trigger chip used inside V2SessionHeader's path subline

struct V2ModelChip: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(V2ModelOption.displayLabel(for: appState.activeSession?.model ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(appState.activeSession == nil)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            V2ModelPicker(isPresented: $open)
                .environmentObject(appState)
        }
    }
}
