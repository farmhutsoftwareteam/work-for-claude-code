// Every content block referenced by V2TranscriptView, faithful to
// design/chat-states.dc.html. Mock data — Phase 4 replaces with event-driven.

import SwiftUI
import Inject

// MARK: - Thinking (collapsible)

struct V2ThinkingBlock: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Text("Thought for 4s")
                        .font(.system(size: 11.5, design: .monospaced))
                    Spacer()
                    Text("reasoning")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundColor(v2.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if open {
                Text("The flood fix is about *when* to re-baseline the cursor. The new fields only add to the event shape, so the two concerns are separable — I should confirm by reading the guard and the contract test rather than assuming.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .italic()
                    .lineSpacing(11.5 * 0.7)
                    .foregroundColor(v2.mute)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
                    .padding(.leading, 32 - 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundColor(v2.line2)
        )
        .enableInjection()
    }
}

// MARK: - Markdown prose

struct V2ProseBlock: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Short answer: no").bold() + Text(" — the change is additive. Here's what I checked and why it's safe."))
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(13 * 0.66)
                .foregroundColor(v2.ink)

            Text("FINDINGS")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.48)
                .foregroundColor(v2.mute)
                .padding(.top, 14)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 5) {
                bullet("The new fields detected_at and name_date are appended, never replacing.")
                bullet("The re-baseline guard reads only the cursor — untouched by the event shape.")
                bullet("One coupling to watch: the seeded trigger's sample_data.")
            }
        }
        .enableInjection()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 13, design: .monospaced))
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(13 * 0.7)
        }
        .foregroundColor(v2.ink)
    }
}

// MARK: - Tool rows (single-line widgets)

struct V2ToolRowREAD: View {
    @Environment(\.v2) private var v2
    var body: some View {
        V2ToolRow(pill: "READ", content: "src/poll/cursor.ts", status: .done(detail: "324 lines"))
    }
}

struct V2ToolRowGREP: View {
    @Environment(\.v2) private var v2
    var body: some View {
        V2ToolRow(pill: "GREP", content: "\"reBaseline\" · src/**", status: .running(detail: "searching"))
    }
}

struct V2ToolRowMCP: View {
    var body: some View {
        V2ToolRow(pill: "MCP", content: "github · create_pull_request", status: .done(detail: "#641"))
    }
}

struct V2ToolRowWEB: View {
    var body: some View {
        V2ToolRow(pill: "WEB", content: "search · \"dropbox cursor pagination semantics\"", status: .done(detail: "5 results"))
    }
}

enum V2ToolRowStatus {
    case running(detail: String)
    case done(detail: String)
}

struct V2ToolRow: View {
    @Environment(\.v2) private var v2
    let pill: String
    let content: String
    let status: V2ToolRowStatus

    var body: some View {
        HStack(spacing: 11) {
            V2Pill(text: pill)
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            statusView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .running(let detail):
            HStack(spacing: 7) {
                V2Spinner(size: 11)
                Text(detail).font(.system(size: 12, design: .monospaced))
            }
            .foregroundColor(v2.mute)
        case .done(let detail):
            HStack(spacing: 6) {
                Text(detail).foregroundColor(v2.mute)
                Text("✓").foregroundColor(v2.ink)
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Bash (collapsible)

struct V2ToolBASH: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 11) {
                    V2Pill(text: "BASH")
                    Text("pnpm test cursor.spec.ts")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        Text("28 lines").foregroundColor(v2.mute)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    Text("PASS  src/poll/cursor.spec.ts")
                    Text("  cursor re-baseline")
                    Text("    ✓ holds baseline when fields added (12 ms)")
                    Text("    ✓ ignores detected_at for cursor math (4 ms)")
                    Text("  Tests: 18 passed, 18 total").foregroundColor(v2.ink)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(11.5 * 0.7)
                .foregroundColor(v2.mute)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
                .overlay(alignment: .top) {
                    Rectangle().fill(v2.line).frame(height: 1)
                }
            }
        }
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .enableInjection()
    }
}

// MARK: - Gap analysis table

struct V2GapTable: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GAP ANALYSIS")
                .font(.system(size: 10.5, design: .monospaced))
                .kerning(0.84)
                .foregroundColor(v2.faint)

            VStack(spacing: 0) {
                row("change", "kind", "risk", isHeader: true)
                row("date fields", "additive", "safe", riskColor: v2.add)
                row("date operators", "additive", "safe", riskColor: v2.add)
                row("sample_data", "coupled", "watch", riskColor: v2.del, lastRow: true)
            }
        }
    }

    @ViewBuilder
    private func row(_ a: String, _ b: String, _ c: String, isHeader: Bool = false, riskColor: Color? = nil, lastRow: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(maxWidth: .infinity, alignment: .leading)
            Text(c).foregroundColor(riskColor ?? v2.mute).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: isHeader ? 10.5 : 12, weight: isHeader ? .regular : .regular, design: .monospaced))
        .kerning(isHeader ? 0.84 : 0)
        .foregroundColor(isHeader ? v2.mute : v2.ink)
        .textCase(isHeader ? .uppercase : nil)
        .padding(.vertical, isHeader ? 7 : 8)
        .padding(.trailing, 14)
        .overlay(alignment: .bottom) {
            if !lastRow {
                Rectangle().fill(isHeader ? v2.line2 : v2.line).frame(height: 1)
            }
        }
    }
}

// MARK: - Edit diff

struct V2ToolEDIT: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                V2Pill(text: "EDIT")
                Text("triggers/folder.seed.ts")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("+3").foregroundColor(v2.add)
                Text("−1").foregroundColor(v2.del)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) {
                Rectangle().fill(v2.line).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                diffLine("−  output_fields: [\"name\",\"path\"]", color: v2.del, bg: v2.delBg)
                diffLine("+  output_fields: [\"name\",\"path\",\"detected_at\",\"name_date\"]", color: v2.add, bg: v2.addBg)
                diffLine("+  // keep sample_data ⊇ output_fields", color: v2.add, bg: v2.addBg)
                diffLine("+  sample_data: { ...base, detected_at, name_date }", color: v2.add, bg: v2.addBg)
            }
        }
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func diffLine(_ text: String, color: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
    }
}

// MARK: - Permission card (pending)

struct V2PermissionCard: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2

    enum PermissionState { case pending, approved, denied }
    @SwiftUI.State private var state: PermissionState = .pending

    var body: some View {
        Group {
            switch state {
            case .pending:  pending
            case .approved: approved
            case .denied:   denied
            }
        }
        .enableInjection()
    }

    private var pending: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text("PERMISSION")
                    .font(.system(size: 10, design: .monospaced))
                    .kerning(0.8)
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
                Text("Claude wants to run a command")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.mute)
            }

            Text("rm -rf build/ && pnpm build")
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.paper2)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))

            HStack(spacing: 9) {
                Button { state = .approved } label: {
                    Text("Approve")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.paper)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(v2.ink)
                }
                .buttonStyle(.plain)

                Button { state = .denied } label: {
                    Text("Deny")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()
                Text("⌥ to always allow")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
        }
        .padding(16)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.ink, lineWidth: 2))
    }

    private var approved: some View {
        HStack(spacing: 10) {
            V2Pill(text: "BASH")
            Text("rm -rf build/ && pnpm build")
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("✓ approved · ran")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.add)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var denied: some View {
        HStack(spacing: 10) {
            Text("command denied — skipped")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.del)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { state = .pending } label: {
                Text("undo")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(v2.delBg)
        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
    }
}

// MARK: - Todo list

struct V2TodoList: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TASKS · 2 / 4")
                .font(.system(size: 10.5, design: .monospaced))
                .kerning(0.84)
                .foregroundColor(v2.faint)

            VStack(alignment: .leading, spacing: 7) {
                todoDone("read cursor + contract test")
                todoDone("confirm re-baseline guard")
                todoRunning("update sample_data + poll contract test")
                todoPending("run full suite")
            }
        }
        .padding(16)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func todoDone(_ text: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle().fill(v2.ink)
                Text("✓").font(.system(size: 9)).foregroundColor(v2.paper)
            }
            .frame(width: 13, height: 13)
            Text(text)
                .strikethrough()
                .foregroundColor(v2.mute)
        }
        .font(.system(size: 12.5, design: .monospaced))
    }

    private func todoRunning(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .stroke(v2.ink, lineWidth: 1)
                .frame(width: 13, height: 13)
                .overlay(V2PulseDot(size: 5, color: v2.ink))
            Text(text).foregroundColor(v2.ink)
        }
        .font(.system(size: 12.5, design: .monospaced))
    }

    private func todoPending(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .stroke(v2.line2, lineWidth: 1)
                .frame(width: 13, height: 13)
            Text(text).foregroundColor(v2.faint)
        }
        .font(.system(size: 12.5, design: .monospaced))
    }
}

// MARK: - Subagent delegation

struct V2SubagentBlock: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                V2Pill(text: "TASK")
                Text("→ reviewer agent · isolated context")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("✓ returned").foregroundColor(v2.mute).font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) {
                Rectangle().fill(v2.line).frame(height: 1)
            }

            (Text("Reviewed the diff against the contract: ")
                + Text("output_fields ⊆ sample_data holds").foregroundColor(v2.ink)
                + Text(", dedup id unchanged. No blocking issues; one nit on naming."))
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(11.5 * 0.65)
                .foregroundColor(v2.mute)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(v2.line2).frame(width: 2).padding(.leading, 14)
                }
        }
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

// MARK: - Inline api_retry

struct V2ApiRetryInline: View {
    @Environment(\.v2) private var v2

    var body: some View {
        HStack(spacing: 9) {
            V2Spinner(size: 11)
            Text("overloaded — retrying (attempt 2 of 5)…")
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundColor(v2.faint)
    }
}

// MARK: - Error block

struct V2ErrorBlock: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text("ERROR")
                    .font(.system(size: 10, design: .monospaced))
                    .kerning(0.8)
                    .foregroundColor(v2.del)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
                Text("tool_use · Bash exited 1").foregroundColor(v2.del)
            }
            .font(.system(size: 12, design: .monospaced))

            Text("eslint: 'sample_data' is defined but never used (no-unused-vars) — fixing on next turn.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.delBg)
        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
    }
}

// MARK: - Final prose

struct V2FinalProse: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Net: the change ships safely if two call sites move together.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.bottom, 10)

            Text("Additive in theory can still break in practice — the contract test is the guardrail.")
                .font(.system(size: 13, design: .monospaced))
                .italic()
                .foregroundColor(v2.mute)
                .padding(.vertical, 8)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle().fill(v2.ink).frame(width: 3)
                }
                .padding(.bottom, 11)

            VStack(alignment: .leading, spacing: 0) {
                Text("1. Update sample_data alongside output_fields.")
                Text("2. Keep operator changes in sync across both evaluation sites.")
            }
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(13 * 0.7)
            .foregroundColor(v2.ink)
        }
    }
}

// MARK: - Live streaming line

struct V2StreamingLine: View {
    @Environment(\.v2) private var v2
    @State private var visible = true

    var body: some View {
        HStack(spacing: 2) {
            Text("Writing the follow-up test now")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(v2.ink)
            Rectangle()
                .fill(v2.ink)
                .frame(width: 8, height: 15)
                .opacity(visible ? 1 : 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                        visible = false
                    }
                }
        }
    }
}

// MARK: - Result footer

struct V2ResultFooter: View {
    @Environment(\.v2) private var v2

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                V2PulseDot(size: 6, color: v2.ink)
                Text("working").foregroundColor(v2.mute)
            }
            Text("6 turns")
            Text("1m 11s")
            Text("$0.0341")
            Spacer()
            Text("session 78b4e619")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(v2.faint)
        .padding(.top, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }
}

// MARK: - Loading skeleton

struct V2LoadingSkeleton: View {
    @Environment(\.v2) private var v2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            V2SkeletonBar(width: 0.62)
            V2SkeletonBar(width: 0.84)
            V2SkeletonBar(width: 0.48)
        }
        .padding(.top, 4)
    }
}

private struct V2SkeletonBar: View {
    @Environment(\.v2) private var v2
    let width: CGFloat
    @State private var offset: CGFloat = -380

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(v2.paper3)
                .frame(width: geo.size.width * width, height: 9)
                .overlay(
                    LinearGradient(
                        colors: [v2.paper3.opacity(0), v2.paper2, v2.paper3.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 160, height: 9)
                    .offset(x: offset)
                    .clipShape(Rectangle())
                    .frame(width: geo.size.width * width, height: 9, alignment: .leading)
                    .clipped()
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        offset = geo.size.width * width + 160
                    }
                }
        }
        .frame(height: 9)
    }
}

// MARK: - Shared atoms

struct V2Pill: View {
    @Environment(\.v2) private var v2
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .kerning(0.8)
            .foregroundColor(v2.mute)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

struct V2Spinner: View {
    @Environment(\.v2) private var v2
    let size: CGFloat
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(v2.ink, lineWidth: 1.6)
            .frame(width: size, height: size)
            .background(
                Circle().stroke(v2.line2, lineWidth: 1.6).frame(width: size, height: size)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
