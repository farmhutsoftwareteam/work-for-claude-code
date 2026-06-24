// Session tabs strip (40px) — chip per running session with filled/outline dot,
// 2px ink underline on the active tab, "+" new-tab button at the end.

import SwiftUI
import Inject

struct V2SessionTabs: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Binding var activeSession: V2Session

    var body: some View {
        HStack(spacing: 0) {
            ForEach(V2Mock.sessions) { session in
                V2TabChip(session: session, isActive: session == activeSession) {
                    activeSession = session
                }
            }
            Button { } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(height: 40)
        .background(v2.paper2)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
    }
}

private struct V2TabChip: View {
    @Environment(\.v2) private var v2
    let session: V2Session
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Circle()
                    .fill(session.live ? v2.ink : Color.clear)
                    .overlay(Circle().stroke(session.live ? Color.clear : v2.line2, lineWidth: 1))
                    .frame(width: 7, height: 7)
                Text(session.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(isActive ? v2.ink : v2.mute)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle().fill(v2.ink).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
