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
    var compactLabel: String {
        switch self {
        case .claude: return "CLD"
        case .codex: return "CDX"
        }
    }

    func badgeLabel(density: V2ProviderBadgeDensity) -> String {
        density == .full ? displayName.uppercased() : compactLabel
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

/// Persistent provider identity for tabs, header controls, composers, and
/// overflow rows. Text + distinct geometry + color deliberately provide
/// redundant cues; color is never the only way Claude and Codex differ.
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
                .padding(.horizontal, density == .full ? 6 : 4)
                .padding(.vertical, 2)
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
        HStack(spacing: density == .full ? 5 : 4) {
            providerMark
            Text(provider.badgeLabel(density: density))
                .font(.system(size: density == .full ? 9.5 : 8.5, weight: .semibold, design: .monospaced))
                .kerning(density == .full ? 0.55 : 0.35)
                .lineLimit(1)
        }
        .foregroundColor(accent)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var providerMark: some View {
        switch provider {
        case .claude:
            Rectangle()
                .fill(accent)
                .frame(width: 5.5, height: 5.5)
                .rotationEffect(.degrees(45))
        case .codex:
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
        }
    }
}
