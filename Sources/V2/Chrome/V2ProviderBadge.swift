import SwiftUI

enum V2ProviderBadgeDensity: Equatable {
    case full
    case compact
}

enum V2ProviderBadgeStyle: Equatable {
    case outlined
    case plain
}

extension V2AgentProvider {
    var logoAssetName: String {
        switch self {
        case .claude: return "LogoClaude"
        case .codex: return "LogoChatGPT"
        }
    }
}

extension V2Palette {
    func providerAccent(_ provider: V2AgentProvider) -> Color {
        provider == .claude ? claude : codex
    }

    func providerBackground(_ provider: V2AgentProvider) -> Color {
        provider == .claude ? claudeBg : codexBg
    }
}

/// The provider's real product mark, tinted with Atelier's accessible provider
/// accent. The mark's geometry and accessibility label keep color from being
/// the only distinction between Claude and ChatGPT-backed Codex sessions.
struct V2ProviderMark: View {
    @Environment(\.v2) private var v2
    let provider: V2AgentProvider
    var size: CGFloat = 13

    var body: some View {
        Image(provider.logoAssetName)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundColor(v2.providerAccent(provider))
            .accessibilityLabel("\(provider.displayName) provider")
    }
}

/// Segmented provider switcher: both providers always visible in a shared
/// track, the selected one carried by a filled segment that slides between
/// positions. The MECHANIC is the user-supplied Apple Music reference
/// (2026-07-17: both options visible, filled sliding selection); the
/// GEOMETRY is Atelier's own — sharp rectangles, hairline strokes, no
/// capsules or shadows. Behavior is "Provider switcher and limits.dc.html"
/// option 1a (Claude Design project 923827b0-…, recommended combination):
/// clicking the inactive segment ARMS it rather than switching immediately
/// — switching restarts the session (context re-sent, in-flight work
/// lost), a real cost a plain toggle would hide. The armed state prints
/// that cost and requires an explicit "switch & restart".
struct V2ProviderTabs: View {
    @Environment(\.v2) private var v2
    let selected: V2AgentProvider
    /// Target availability — a provider whose binary isn't installed stays
    /// visible but inert (dimmed), same rule the old text link enforced.
    var isAvailable: (V2AgentProvider) -> Bool = { _ in true }
    /// Switching restarts session plumbing — blocked mid-turn, same
    /// condition the old "Continue this work with…" link disabled on.
    var busy: Bool = false
    /// Short plan/account identity shown inside each segment ("max",
    /// "plus") — per the design, this is the identity of what you'd be
    /// talking to, not metadata, so it lives in the control itself.
    var subtitle: (V2AgentProvider) -> String? = { _ in nil }
    let onSelect: (V2AgentProvider) -> Void
    @Namespace private var selectionNS
    @State private var armed: V2AgentProvider?
    @State private var justSwitched = false
    @State private var justSwitchedWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                segment(.claude)
                segment(.codex)
            }
            .padding(3)
            .background(Rectangle().fill(v2.paper3))
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
            footer
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .animation(.easeOut(duration: 0.15), value: armed)
        // A switch that lands (state.selected changes) while armed is the
        // confirm path completing — clear the arm and flash "switched".
        .onChange(of: selected) { _, _ in
            guard armed != nil || justSwitched == false else { return }
            armed = nil
        }
    }

    @ViewBuilder
    private func segment(_ provider: V2AgentProvider) -> some View {
        let isSelected = provider == selected
        let enabled = isSelected || (!busy && isAvailable(provider))
        Button {
            if isSelected {
                // Clicking the active segment while something is armed is
                // the disarm gesture — otherwise a genuine no-op.
                armed = nil
                return
            }
            guard enabled else { return }
            armed = provider
        } label: {
            VStack(spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle = subtitle(provider) {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .opacity(0.62)
                }
            }
            .foregroundColor(isSelected ? v2.ink : (enabled ? v2.mute : v2.faint))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Rectangle().fill(v2.ink)
                        .matchedGeometryEffect(id: "provider-pill", in: selectionNS)
                } else if armed == provider {
                    Rectangle().fill(v2.delBg)
                        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? v2.paper : nil)
        .help(helpText(provider, isSelected: isSelected, enabled: enabled))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Idle hint / armed confirm box / post-switch confirmation — printed
    /// inline below the segments rather than behind a tooltip, matching
    /// the design's "the popover has room; tooltips hide the answer."
    @ViewBuilder
    private var footer: some View {
        if let armed {
            VStack(alignment: .leading, spacing: 8) {
                Text("switching to \(armed.displayName) restarts the session — context is re-sent, in-flight work is lost")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Button("switch & restart") {
                        justSwitched = true
                        onSelect(armed)
                        scheduleJustSwitchedClear()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.paper)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(v2.ink)

                    Button("cancel") { self.armed = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
            }
            .padding(9)
            .background(v2.delBg)
            .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
        } else if justSwitched {
            Text("✓ switched — new session started, context carried over")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.add)
                .padding(.top, 7)
        } else if busy {
            Text("available when this turn finishes")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.top, 7)
        } else if let unavailable = [V2AgentProvider.claude, .codex].first(where: { $0 != selected && !isAvailable($0) }) {
            Text("\(unavailable.displayName) was not found on PATH")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.top, 7)
        } else {
            Text("switching restarts the session")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.top, 7)
        }
    }

    /// The "✓ switched" line reads once and clears — a stale confirmation
    /// sitting under the control forever would stop meaning anything.
    private func scheduleJustSwitchedClear() {
        justSwitchedWorkItem?.cancel()
        let item = DispatchWorkItem { justSwitched = false }
        justSwitchedWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func helpText(_ provider: V2AgentProvider, isSelected: Bool, enabled: Bool) -> String {
        if isSelected { return "\(provider.displayName) is active" }
        if busy { return "Finish or interrupt the current turn to switch providers" }
        if !enabled { return "\(provider.displayName) was not found on PATH" }
        return "Switch to \(provider.displayName)"
    }
}

/// Persistent provider identity for tabs, header controls, composers, and
/// overflow rows. Compact surfaces use the recognizable mark without repeating
/// the provider name; full badges retain text for selection and account views.
struct V2ProviderBadge: View {
    @Environment(\.v2) private var v2
    let provider: V2AgentProvider
    var density: V2ProviderBadgeDensity = .full
    var style: V2ProviderBadgeStyle = .outlined

    private var accent: Color { v2.providerAccent(provider) }

    @ViewBuilder
    var body: some View {
        if style == .outlined {
            label
                .padding(.horizontal, density == .full ? 6 : 5)
                .padding(.vertical, density == .full ? 3 : 4)
                .background(v2.providerBackground(provider))
                .overlay(Rectangle().stroke(accent.opacity(0.72), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(provider.displayName) provider")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(provider.displayName) provider")
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            V2ProviderMark(provider: provider, size: density == .full ? 12 : 11)
            if density == .full {
                Text(provider.displayName.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .kerning(0.55)
                    .lineLimit(1)
            }
        }
        .foregroundColor(accent)
        .fixedSize(horizontal: true, vertical: true)
    }
}
