// Transcript scroll region — renders the mock user turn + assistant turn with
// every content block type the design canvas shows. When Phase 4 lands, this
// scrolls the same content blocks driven off StreamSession.events.

import SwiftUI
import Inject

struct V2TranscriptView: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                userTurn
                assistantTurn
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
        .enableInjection()
    }

    private var userTurn: some View {
        HStack(alignment: .top, spacing: 13) {
            Text("you")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 3)

            (Text("the date-on-folder-events change — does it break the flood fix? read ")
                + Text("src/poll/cursor.ts").font(.system(size: 13, design: .monospaced))
                + Text(" and the contract test, then summarise."))
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(13 * 0.6)
                .foregroundColor(v2.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper3)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        }
    }

    private var assistantTurn: some View {
        HStack(alignment: .top, spacing: 13) {
            V2DovetailMark(size: 18)
                .foregroundColor(v2.ink)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 16) {
                V2ThinkingBlock()
                V2ProseBlock()
                V2ToolRowREAD()
                V2ToolRowGREP()
                V2ToolBASH()
                V2GapTable()
                V2ToolEDIT()
                V2PermissionCard()
                V2TodoList()
                V2SubagentBlock()
                V2ToolRowMCP()
                V2ToolRowWEB()
                V2ApiRetryInline()
                V2ErrorBlock()
                V2FinalProse()
                V2StreamingLine()
                V2ResultFooter()
                V2LoadingSkeleton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
