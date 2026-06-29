// Live composer bound to a real StreamSession. Send / Stop based on state.
//
// Text input is a custom NSTextView wrapper (V2ComposerTextView) so:
//   • Enter submits, Shift+Enter inserts a newline (matches modern chat UX)
//   • Cmd+V'd / dragged images get caught and emitted as attachments
//   • Drag & drop file URLs from Finder land as attachments
//
// Attachments aren't sent over the wire as base64 — we prepend "@<path>"
// references to the user turn so claude reads them via its Read tool.
// Same mechanism Claude Code uses for any file mention; no protocol change.

import SwiftUI
import AppKit
import Inject

struct V2LiveComposer: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @ObservedObject var session: StreamSession
    @StateObject private var attachments = V2AttachmentStore()
    @State private var draft: String = ""
    @State private var inputFocused: Bool = false
    @State private var slashActive: Int = 0   // highlighted row in the popover

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !attachments.items.isEmpty {
                attachmentStrip
            }
            // Slash-command popover floats above the composer when the draft
            // starts with "/" and no space has been typed yet.
            ZStack(alignment: .bottomLeading) {
                composerBox
                if slashOpen {
                    slashPopover
                        .offset(y: -(composerHeight + 36))
                }
            }
            helperRow
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
        .onAppear { inputFocused = true }
        // Focus once on appear, then leave the user alone. The previous
        // onChange(of: session.state) yanked focus back on every transition
        // — when you clicked a rail/tab to switch projects, the new
        // composer's onChange fired as its session reached .ready and
        // stole focus right back, which felt like the click had failed.
        //
        // ⎋ to interrupt — the placeholder + helper row have always
        // advertised this, but it was never actually wired; only the Stop
        // button worked. Hidden zero-size button in the responder chain
        // makes the escape key interrupt the running turn.
        .background(
            Button("Interrupt") { if isWorking { session.interrupt() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .disabled(!isWorking)
        )
        .enableInjection()
    }

    // MARK: - Composer box

    private var composerBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("›")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(v2.mute)
                .padding(.top, 6)

            V2ComposerTextView(
                text: $draft,
                focused: $inputFocused,
                placeholder: placeholder,
                isEnabled: canType,
                foregroundColor: NSColor(v2.ink),
                placeholderColor: NSColor(v2.faint),
                onSubmit: sendCurrent,
                onImagePasted: { image in attachments.addImage(image) },
                onFilesDropped: { urls in attachments.addFiles(urls) },
                popoverOpen: slashOpen,
                onPopoverMove: moveSlashSelection,
                onPopoverPick: pickSlashCommand,
                onPopoverDismiss: dismissSlash
            )
            .onChange(of: draft) { _, _ in
                // Keep the highlighted row in range as the filter narrows.
                if slashActive >= slashResults.count { slashActive = 0 }
            }
            // Size to actual text content. 19pt per line approximates the
            // monospaced 13pt with default leading + the scrollview's 4pt
            // top inset. Cap at 8 lines — beyond that, the inner NSScrollView
            // kicks in.
            .frame(height: composerHeight)

            attachButton

            if isWorking {
                Button { session.interrupt() } label: {
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
            } else {
                Button(action: sendCurrent) {
                    Text("⏎ send")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(canSend ? v2.ink : v2.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    // MARK: - Slash command popover

    /// Open when the draft is a bare "/query" (no space yet — once a command
    /// is completed to "/name " we close so it doesn't show "no matches").
    private var slashOpen: Bool {
        draft.hasPrefix("/") && !draft.contains(" ") && canType
    }

    private var slashResults: [V2SlashCommand] {
        V2SlashCatalog.filtered(String(draft.dropFirst()))
    }

    private var slashPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("COMMANDS")
                    .font(.system(size: 9.5, design: .monospaced)).kerning(1.2)
                    .foregroundColor(v2.faint)
                Spacer()
                Text("↑↓ navigate · ⏎ complete · esc dismiss")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }

            let results = slashResults
            if results.isEmpty {
                Text("no commands match")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, cmd in
                    Button { complete(cmd) } label: {
                        HStack(spacing: 13) {
                            Text("/\(cmd.name)")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(v2.ink)
                                .frame(width: 170, alignment: .leading)
                            Text(cmd.desc)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(v2.mute)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(idx == slashActive ? v2.card : Color.clear)
                        .overlay(alignment: .leading) {
                            if idx == slashActive { Rectangle().fill(v2.ink).frame(width: 2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: -6)
        .frame(maxWidth: .infinity)
    }

    private func moveSlashSelection(_ delta: Int) {
        let n = slashResults.count
        guard n > 0 else { return }
        slashActive = (slashActive + delta + n) % n
    }

    private func pickSlashCommand() {
        let results = slashResults
        guard !results.isEmpty, results.indices.contains(slashActive) else { return }
        complete(results[slashActive])
    }

    private func complete(_ cmd: V2SlashCommand) {
        draft = "/\(cmd.name) "   // trailing space closes the popover
        slashActive = 0
        inputFocused = true
    }

    private func dismissSlash() {
        // Clear the leading "/" so the popover closes but keep nothing stale.
        if draft.hasPrefix("/") { draft = "" }
        slashActive = 0
    }

    private var attachButton: some View {
        Button(action: openImagePicker) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.mute)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Attach an image or file (or drag one in / paste with ⌘V)")
        .disabled(!canType)
    }

    // MARK: - Attachment strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.items) { item in
                    attachmentChip(item)
                }
            }
        }
    }

    private func attachmentChip(_ item: V2Attachment) -> some View {
        HStack(spacing: 8) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipped()
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(v2.mute)
                    .frame(width: 24, height: 24)
                    .background(v2.paper3)
            }
            Text(item.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button { attachments.remove(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    // MARK: - Helper row

    private var helperRow: some View {
        HStack(spacing: 18) {
            Button { session.cyclePermissionMode() } label: {
                Text("/ for commands · \(permissionLabel) · shift+tab to cycle")
                    .foregroundColor(v2.faint)
            }
            .buttonStyle(.plain)

            Text("⇧⏎ newline · ⌘V paste image")
                .foregroundColor(v2.faint)

            if isWorking {
                Text("esc to interrupt")
            }

            Spacer()

            Text(modelStatus)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(v2.faint)
    }

    // MARK: - Image picker

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .text, .data]
        panel.message = "Attach to the next message"
        if panel.runModal() == .OK {
            attachments.addFiles(panel.urls)
        }
    }

    // MARK: - State

    private var placeholder: String {
        switch session.state {
        case .idle, .terminated:    return "Ask, or / for commands, or set a goal to run a loop…"
        case .ready:                return "Reply, or / for commands…"
        case .spawning:             return "Spawning…"
        case .initializing:         return "Initializing…"
        case .working:              return "Reply, or ⎋ to interrupt…"
        case .awaitingPermission:   return "Resolve permission above to continue"
        case .closing:              return "Closing…"
        }
    }

    private var canType: Bool {
        switch session.state {
        case .idle, .working, .initializing, .ready: return true
        default: return false
        }
    }

    private var canSend: Bool {
        // Don't allow a send while a turn is in flight — pressing Enter
        // mid-stream used to fire a SECOND user turn into the same session,
        // interleaving with the reply that was still streaming, even though
        // the visible button said "Stop". You can keep typing your next
        // message (canType stays true); it sends once the turn finishes.
        guard canType, !isWorking else { return false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !attachments.items.isEmpty
    }

    private var isWorking: Bool { session.state == .working || session.state == .awaitingPermission }

    private var permissionLabel: String {
        switch session.permissionMode {
        case "bypassPermissions": return "bypass permissions on"
        case "acceptEdits":       return "accept edits"
        case "plan":              return "plan mode"
        case "dontAsk":           return "don't ask"
        case "auto":              return "auto"
        default:                  return "default permissions"
        }
    }

    private var modelStatus: String {
        "\(session.model) · \(V2Format.count(session.tokensUsed)) tokens"
    }

    // MARK: - Sizing

    /// One line by default; grows with explicit newlines up to 8 lines.
    /// Soft-wrapped long lines also count via a rough column estimate so
    /// pasted paragraphs don't snap to a single row.
    private var composerHeight: CGFloat {
        let lineHeight: CGFloat = 19
        let topBottomPadding: CGFloat = 8
        let newlines = draft.filter { $0 == "\n" }.count
        // Rough soft-wrap estimate: 80 chars per visible line.
        let wrapped = max(0, (draft.count / 80) - newlines)
        let lines = max(1, min(8, 1 + newlines + wrapped))
        return CGFloat(lines) * lineHeight + topBottomPadding
    }

    // MARK: - Send

    private func sendCurrent() {
        guard canSend else { return }
        let body = draft
        let prefix = attachments.outboundPrefix()
        let full = prefix + body
        // Pre-authorise Reads for paths the user just attached. Without
        // this claude prompts for permission to read a file the user
        // literally picked seconds ago — even when the file lives outside
        // the project cwd (Desktop screenshots, etc.).
        for item in attachments.items {
            session.preApproveRead(path: item.url.path)
        }
        draft = ""
        attachments.clear()
        session.send(text: full)
        inputFocused = true
    }
}
