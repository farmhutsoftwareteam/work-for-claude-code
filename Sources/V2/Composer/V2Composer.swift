// Composer box + helper telemetry row underneath.
// Design canvas shows the "working" state — Stop button + blinking cursor.

import SwiftUI
import Inject

struct V2Composer: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            composerBox
            helperRow
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .enableInjection()
    }

    private var composerBox: some View {
        HStack(spacing: 12) {
            Text("›")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Reply, or ⎋ to interrupt…")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.faint)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { } label: {
                HStack(spacing: 7) {
                    Rectangle().fill(v2.ink).frame(width: 8, height: 8)
                    Text("Stop")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(v2.paper2)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var helperRow: some View {
        HStack(spacing: 18) {
            Text("bypass permissions on · shift+tab to cycle")
            Text("esc to interrupt")
            Spacer()
            Text("sonnet · 38.2k / 200k")
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(v2.faint)
    }
}
