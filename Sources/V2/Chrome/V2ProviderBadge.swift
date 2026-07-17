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
/// positions on switch. The MECHANIC is the user-supplied Apple Music
/// reference (2026-07-17: both options visible, filled sliding selection);
/// the GEOMETRY is Atelier's own — sharp rectangles and hairline strokes,
/// flat, no capsules or shadows (explicitly confirmed over the rounded
/// literal reading of the reference).
struct V2ProviderTabs: View {
    @Environment(\.v2) private var v2
    let selected: V2AgentProvider
    /// Target availability — a provider whose binary isn't installed stays
    /// visible but inert (dimmed), same rule the old text link enforced.
    var isAvailable: (V2AgentProvider) -> Bool = { _ in true }
    /// Switching restarts session plumbing — blocked mid-turn, same
    /// condition the old "Continue this work with…" link disabled on.
    var busy: Bool = false
    let onSelect: (V2AgentProvider) -> Void
    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 0) {
            segment(.claude)
            segment(.codex)
        }
        .padding(3)
        .background(Rectangle().fill(v2.paper3))
        .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    @ViewBuilder
    private func segment(_ provider: V2AgentProvider) -> some View {
        let isSelected = provider == selected
        let enabled = isSelected || (!busy && isAvailable(provider))
        Button {
            guard !isSelected, enabled else { return }
            onSelect(provider)
        } label: {
            HStack(spacing: 7) {
                V2ProviderMark(provider: provider, size: 12)
                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(isSelected ? v2.ink : (enabled ? v2.mute : v2.faint))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Rectangle()
                        .fill(v2.paper)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        .matchedGeometryEffect(id: "provider-pill", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(provider, isSelected: isSelected, enabled: enabled))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func helpText(_ provider: V2AgentProvider, isSelected: Bool, enabled: Bool) -> String {
        if isSelected { return "\(provider.displayName) is active" }
        if busy { return "Finish or interrupt the current turn to switch providers" }
        if !enabled { return "\(provider.displayName) was not found on PATH" }
        return "Continue this work with \(provider.displayName)"
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
