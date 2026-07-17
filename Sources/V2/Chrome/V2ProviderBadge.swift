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
