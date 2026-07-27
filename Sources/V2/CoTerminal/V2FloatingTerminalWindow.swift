// Floating co-driven terminal window (implements "Floating terminal
// window.dc.html"). Replaces the old inline CoTerminalStrip, which stacked a
// full 262pt+ pane per shell directly above the composer — sharing its exact
// card/border chrome, 10pt away — so it read as "another input box crashing
// into the real one" even with zero actual overlap. This is a single
// fixed-size panel, floated top-right over the whole window (not inline in
// any tab's flow), with a shell-tab strip on live shells instead of stacking
// their panes. It never touches the composer's layout at all.
//
// Auto-raise is narrow and deliberate (per the design): only a shell that
// NEEDS the user's keystrokes forces this open and steals focus — see
// CoTerminalManager.noteNeedsInput. Running/done/error never do; you find
// out about those from the transcript's receipt strip (V2CoTerminalReceiptStrip)
// and open this window on your own terms.

import SwiftUI
import Inject

/// Terminal-chrome colours — dark in both app themes, same posture as
/// CoTerminal's own SwiftTerm view (a terminal is a terminal).
private enum TermChrome {
    static let bg = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x19 / 255)
    static let titleBar = Color(red: 0x23 / 255, green: 0x24 / 255, blue: 0x27 / 255)
    static let tabStrip = Color(red: 0x1e / 255, green: 0x1f / 255, blue: 0x21 / 255)
    static let ink = Color(red: 0xd9 / 255, green: 0xda / 255, blue: 0xd6 / 255)
    static let mute = Color(red: 0xd9 / 255, green: 0xda / 255, blue: 0xd6 / 255).opacity(0.52)
    static let faint = Color(red: 0xd9 / 255, green: 0xda / 255, blue: 0xd6 / 255).opacity(0.34)
    static let done = Color(red: 0x7f / 255, green: 0xb8 / 255, blue: 0x9a / 255)
    static let need = Color(red: 0xd3 / 255, green: 0x91 / 255, blue: 0x89 / 255)
    static let hairline = Color.white.opacity(0.08)
}

struct V2FloatingTerminalWindow: View {
    @ObserveInjection private var inject
    @ObservedObject private var manager = CoTerminalManager.shared
    let session: StreamSession

    @State private var dragOffset: CGSize = .zero
    @State private var savedOffset: CGSize = .zero

    private var terminals: [CoTerminal] { manager.terminals(for: session) }
    private var active: CoTerminal? { manager.selectedTerminal(for: session) }

    var body: some View {
        Group {
            if !terminals.isEmpty {
                if manager.isWindowOpen(for: session) {
                    panel
                } else {
                    reopenPill
                }
            }
        }
        .enableInjection()
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            titleBar
            if let active {
                TerminalHostView(terminal: active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !active.agentInputs.isEmpty || active.secureInput {
                    attributionStrip(active)
                }
            }
            if terminals.count > 1 {
                shellTabStrip
            }
        }
        .frame(width: 520, height: 400)
        .background(TermChrome.bg)
        .overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 58).padding(.trailing, 24)
        .offset(dragOffset)
        // Bug-hunt: reset to the default slot every time the panel goes from
        // hidden to visible — the only escape hatch if a drag ever puts it
        // somewhere bad (off-screen, behind other chrome, stuck after a
        // window resize). There's no bounds-clamping on the drag itself, so
        // without this "close it and reopen it" would do nothing.
        .onAppear {
            dragOffset = .zero
            savedOffset = .zero
            stealFocusIfNeedsInput()
        }
        // Steal focus the instant a shell starts needing keystrokes WHILE the
        // panel is already visible — the one case where staying passive
        // actively strands the session (the agent can't answer a secure
        // prompt; only the user's typing can).
        //
        // Bug-hunt: this alone missed the case that matters most. SwiftUI's
        // onChange does NOT fire on a view's first mount — it only compares
        // against a value recorded from a PRIOR appearance. The auto-raise
        // path (CoTerminalManager.noteNeedsInput) flips windowOpen AND
        // selected together, so exactly when a closed window needs to pop
        // back open because of a secure prompt, `panel` mounts fresh with
        // `active?.status` ALREADY == .needsInput — onChange's baseline IS
        // that value, so it silently never fires and focus never moves. The
        // onAppear above covers that fresh-mount case; this covers a
        // transition while the panel was already on screen.
        .onChange(of: active?.status) { _, status in
            guard status == .needsInput else { return }
            stealFocusIfNeedsInput()
        }
    }

    private func stealFocusIfNeedsInput() {
        guard active?.status == .needsInput, let view = active?.view else { return }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text(active?.command ?? "terminal")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(TermChrome.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            statusBadge
            Button { manager.setWindowOpen(false, for: session) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(TermChrome.mute)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close — shells keep running; reopen from the ↑ pill or a receipt row")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(TermChrome.titleBar)
        .overlay(alignment: .bottom) { Rectangle().fill(TermChrome.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        // Drag anywhere on the title bar to reposition — the ONLY thing this
        // gesture does; it never reaches the PTY, so it can't eat a click
        // meant for the terminal body below.
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(
                        width: savedOffset.width + value.translation.width,
                        height: savedOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in savedOffset = dragOffset }
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch active?.status {
        case .needsInput:
            Text("needs you")
                .foregroundColor(TermChrome.need)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Rectangle().stroke(TermChrome.need, lineWidth: 1))
        case .error(let code):
            Text("exit \(code)").foregroundColor(TermChrome.need)
        case .running:
            Text("running").foregroundColor(TermChrome.faint)
        case .done:
            Text("exit 0").foregroundColor(TermChrome.faint)
        case nil:
            EmptyView()
        }
    }

    private func attributionStrip(_ terminal: CoTerminal) -> some View {
        HStack(spacing: 12) {
            Text("AGENT TYPED")
                .font(.system(size: 9, design: .monospaced)).kerning(0.8)
                .foregroundColor(TermChrome.faint)
            ForEach(Array(terminal.agentInputs.suffix(3).enumerated()), id: \.offset) { _, entry in
                Text(entry)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TermChrome.mute)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if terminal.secureInput {
                Text("agent locked out")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(TermChrome.need)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TermChrome.titleBar)
        .overlay(alignment: .top) { Rectangle().fill(TermChrome.hairline).frame(height: 1) }
    }

    // MARK: - Shell tabs (only shown with >1 concurrent shell)

    private var shellTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(terminals) { t in
                    shellTab(t)
                }
            }
        }
        .frame(height: 32)
        .background(TermChrome.tabStrip)
        .overlay(alignment: .top) { Rectangle().fill(TermChrome.hairline).frame(height: 1) }
    }

    private func shellTab(_ t: CoTerminal) -> some View {
        let isActive = t.id == active?.id
        return Button { manager.select(t, for: session) } label: {
            HStack(spacing: 7) {
                statusDot(t)
                Text(t.command)
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isActive ? TermChrome.ink : TermChrome.mute)
            .padding(.horizontal, 13)
            .frame(maxWidth: 170)
            .frame(height: 32)
            .background(isActive ? TermChrome.bg : Color.clear)
            .overlay(alignment: .trailing) { Rectangle().fill(TermChrome.hairline).frame(width: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusDot(_ t: CoTerminal) -> some View {
        Circle().fill(dotColor(t)).frame(width: 6, height: 6)
            .modifier(V2PulseWhile(active: t.status == .running || t.status == .needsInput))
    }

    private func dotColor(_ t: CoTerminal) -> Color {
        switch t.status {
        case .running:    return TermChrome.done
        case .needsInput: return TermChrome.need
        case .error:      return TermChrome.need
        case .done:       return TermChrome.faint
        }
    }

    // MARK: - Reopen affordance (manually closed, shells still alive)

    private var reopenPill: some View {
        Button { manager.setWindowOpen(true, for: session) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .medium))
                Text("reopen shell window")
                if terminals.contains(where: { $0.status == .needsInput }) {
                    Circle().fill(TermChrome.need).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background(Color.black.opacity(0.82))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 58).padding(.trailing, 24)
    }
}

/// Soft opacity pulse while `active` — shared small helper (the design's
/// 1.5s ease pulse), local to this file since it's specific to the dark
/// terminal-tab dots and not worth exporting.
private struct V2PulseWhile: ViewModifier {
    let active: Bool
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { if active { dim = true } }
            .onChange(of: active) { _, now in dim = now }
    }
}
