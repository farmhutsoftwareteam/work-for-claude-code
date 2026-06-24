// Rich session header — 30px dovetail, project name, LIVE badge, project path
// subline, right cluster with dock switcher (loop/agents/mcp) and the
// pulsing Running status pill.

import SwiftUI
import Inject

enum V2DockPanel: String, CaseIterable, Identifiable {
    case loop, agents, mcp
    var id: String { rawValue }
}

struct V2SessionHeader: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Binding var dockPanel: V2DockPanel
    let activeProject: V2Project

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            V2DovetailMark(size: 30)
                .foregroundColor(v2.ink)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(activeProject.name)
                        .font(.system(size: 19, weight: .medium))
                        .kerning(-0.38)
                    liveBadge
                }
                Text("~/dev/\(activeProject.name) · main · claude-sonnet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
            }

            Spacer()

            HStack(spacing: 10) {
                dockSwitcher
                runningPill
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
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

    private var dockSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(V2DockPanel.allCases) { panel in
                Button {
                    dockPanel = panel
                } label: {
                    Text(panel.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                        .foregroundColor(dockPanel == panel ? v2.paper : v2.mute)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(dockPanel == panel ? v2.ink : v2.card)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var runningPill: some View {
        HStack(spacing: 7) {
            V2PulseDot(size: 7, color: v2.ink)
            Text("Running")
                .font(.system(size: 11.5, design: .monospaced))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .medium))
                .padding(.leading, 2)
        }
        .foregroundColor(v2.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

// MARK: - Pulse dot used in multiple places

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
