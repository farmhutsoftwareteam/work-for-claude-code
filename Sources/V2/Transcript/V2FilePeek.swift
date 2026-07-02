// File peek — the in-app modal that previews a local file mentioned in chat
// (design: "File peek.dc.html"). Opened by clicking a file token in the
// transcript. Five body variants: rendered markdown, code with line numbers,
// image on a checker, too-big (first 200 lines + escalation), and binary
// (no-preview empty state). Esc / click-outside dismiss; the session keeps
// streaming behind it.

import SwiftUI
import AppKit

// MARK: - Controller

/// Window-level presentation state. A singleton so the NSTextView link
/// coordinator (static context) can present without threading app state.
@MainActor
final class V2FilePeekController: ObservableObject {
    static let shared = V2FilePeekController()
    @Published var file: V2PeekFile?

    static func present(_ url: URL) {
        shared.file = V2PeekFile.load(url)
    }
    func close() { file = nil }
}

// MARK: - File model + loader

struct V2PeekFile {
    enum Variant {
        case markdown(String)
        case code(lines: [String], truncationNote: String?)
        case image(NSImage)
        case binary
    }

    let url: URL
    let variant: Variant
    let meta: String

    /// Whole-content copy for the header's "copy text" action (text variants).
    var copyText: String? {
        switch variant {
        case .markdown(let t):        return t
        case .code(let lines, _):     return lines.joined(separator: "\n")
        case .image, .binary:         return nil
        }
    }

    var name: String { url.lastPathComponent }
    var dir: String {
        let d = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return (d.hasPrefix(home) ? "~" + d.dropFirst(home.count) : d) + "/"
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff", "bmp", "icns"]
    private static let mdExts: Set<String> = ["md", "markdown"]
    private static let bigThreshold = 1_500_000       // bytes — beyond this, peek shows the head
    private static let headBytes = 262_144
    private static let maxRenderLines = 5_000          // hard cap even for full reads

    // Only touched from the main actor (present() is @MainActor).
    nonisolated(unsafe) private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    static func load(_ url: URL) -> V2PeekFile {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        let modified = attrs[.modificationDate] as? Date
        let ext = url.pathExtension.lowercased()
        let sizeLabel = bytes.string(fromByteCount: Int64(size))
        let modLabel = modified.map { "modified \(relative.localizedString(for: $0, relativeTo: Date()))" } ?? ""

        func meta(_ kind: String, _ detail: String?) -> String {
            [kind, sizeLabel, detail, modLabel].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        }

        // Image
        if imageExts.contains(ext), let img = NSImage(contentsOf: url) {
            let dims = "\(Int(img.size.width)) × \(Int(img.size.height))"
            return V2PeekFile(url: url, variant: .image(img), meta: meta(ext, dims))
        }

        // Read (capped for huge files)
        let isBig = size > bigThreshold
        var data: Data?
        if isBig {
            if let fh = try? FileHandle(forReadingFrom: url) {
                data = try? fh.read(upToCount: headBytes)
                try? fh.close()
            }
        } else {
            data = try? Data(contentsOf: url)
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            let kind = ext.isEmpty ? "binary" : "\(ext) · binary"
            return V2PeekFile(url: url, variant: .binary, meta: meta(kind, nil))
        }

        // Markdown (only when we have the whole file — a truncated doc renders
        // misleadingly, so a huge .md falls through to the code-head variant).
        if mdExts.contains(ext), !isBig {
            let lines = text.components(separatedBy: "\n").count
            return V2PeekFile(url: url, variant: .markdown(text), meta: meta("markdown", "\(lines) lines"))
        }

        // Code / plain text
        var lines = text.components(separatedBy: "\n")
        var note: String?
        if isBig {
            lines = Array(lines.prefix(200))
            note = "Showing the first 200 lines of \(sizeLabel) — open in editor for the rest"
        } else if lines.count > maxRenderLines {
            let total = lines.count
            lines = Array(lines.prefix(maxRenderLines))
            note = "Showing first \(maxRenderLines) of \(total) lines — open in editor for the rest"
        }
        let kind = ext.isEmpty ? "text" : ext
        let detail = isBig ? nil : "\(text.components(separatedBy: "\n").count) lines"
        return V2PeekFile(url: url, variant: .code(lines: lines, truncationNote: note), meta: meta(kind, detail))
    }
}

// MARK: - Modal

struct V2FilePeekModal: View {
    @Environment(\.v2) private var v2
    let file: V2PeekFile
    let onClose: () -> Void
    @State private var copiedPath = false
    @State private var copiedText = false

    var body: some View {
        ZStack {
            Color(red: 0x1b/255, green: 0x1c/255, blue: 0x1e/255).opacity(0.46)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                body_
                footer
            }
            .frame(width: 860, height: 620)
            .background(v2.paper2)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 56, y: 18)

            // Esc closes (hidden cancel button carries the shortcut).
            Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.tokInk)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(v2.tok)
                        .lineLimit(1)
                    Text(file.dir)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(file.meta)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                actionChip("open in editor", primary: true) { NSWorkspace.shared.open(file.url) }
                actionChip("reveal") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                if let text = file.copyText {
                    actionChip(copiedText ? "copied ✓" : "copy text", tint: copiedText ? v2.add : nil) {
                        V2Clipboard.copy(text)
                        copiedText = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedText = false }
                    }
                }
                actionChip(copiedPath ? "copied ✓" : "copy path", tint: copiedPath ? v2.add : nil) {
                    V2Clipboard.copy(file.url.path)
                    copiedPath = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPath = false }
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(v2.mute)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 14)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func actionChip(_ label: String, primary: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(tint ?? (primary ? v2.ink : v2.mute))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .overlay(Rectangle().stroke(tint ?? (primary ? v2.ink : v2.line2), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Body

    @ViewBuilder
    private var body_: some View {
        Group {
            switch file.variant {
            case .markdown(let text):
                ScrollView {
                    V2MarkdownText(text: text, baseDir: file.url.deletingLastPathComponent().path)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .code(let lines, let note):
                VStack(spacing: 0) {
                    codeBody(lines)
                    if let note { truncationBar(note) }
                }
            case .image(let img):
                imageBody(img)
            case .binary:
                binaryBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
    }

    private func codeBody(_ lines: [String]) -> some View {
        // NSTextView-backed: native cross-line selection + ⌘C (SwiftUI Text
        // rows couldn't be drag-selected across lines, and the drag fought the
        // scroller). Line numbers live in an AppKit ruler, so they scroll in
        // sync but stay OUT of the selection.
        V2CodePeekView(lines: lines)
    }

    private func truncationBar(_ note: String) -> some View {
        HStack(spacing: 12) {
            Text(note)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.mute)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            actionChip("open in editor", primary: true) { NSWorkspace.shared.open(file.url) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(v2.card)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func imageBody(_ img: NSImage) -> some View {
        ZStack {
            V2Checkerboard()
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 720, maxHeight: 480)
                .border(v2.line2, width: 1)
        }
    }

    private var binaryBody: some View {
        VStack(spacing: 15) {
            V2DovetailMark(size: 44).foregroundColor(v2.faint)
            VStack(spacing: 5) {
                Text("No preview for .\(file.url.pathExtension.isEmpty ? "file" : file.url.pathExtension)")
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(v2.mute)
                Text(file.meta)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
            }
            actionChip("reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(file.url.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("esc to close")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }
}

// MARK: - Code view (NSTextView + line-number ruler)

private struct V2CodePeekView: NSViewRepresentable {
    @Environment(\.v2) private var v2
    let lines: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastKey = "" }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 20)
        tv.textContainer?.lineFragmentPadding = 0
        // No wrapping — long lines scroll horizontally, per the design.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv

        let ruler = V2LineNumberRuler(scrollView: scroll, textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let dark = (v2.ink == V2Theme.dark.ink)
        let key = "\(dark)|\(lines.count)|\(lines.first ?? "")|\(lines.last ?? "")"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key

        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 12 * 0.55
        let ink = NSColor(v2.ink), mute = NSColor(v2.mute)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            out.append(NSAttributedString(
                string: line + (i == lines.count - 1 ? "" : "\n"),
                attributes: [
                    .font: mono,
                    .paragraphStyle: para,
                    // Whole-line comments read muted — the design's monochrome
                    // nod to syntax without an IDE rainbow.
                    .foregroundColor: Self.isComment(line) ? mute : ink,
                ]
            ))
        }
        tv.textStorage?.setAttributedString(out)

        if let ruler = scroll.verticalRulerView as? V2LineNumberRuler {
            ruler.numberColor = NSColor(v2.faint)
            ruler.backgroundFill = NSColor(v2.paper)
            ruler.needsDisplay = true
        }
    }

    private static func isComment(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") || t.hasPrefix("#") || t.hasPrefix("/*") || t.hasPrefix("* ") || t.hasPrefix("--")
    }
}

/// Vertical ruler drawing right-aligned line numbers — scrolls with the text
/// but is not part of it, so selection/copy never picks the numbers up.
private final class V2LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var numberColor: NSColor = .tertiaryLabelColor
    var backgroundFill: NSColor = .clear
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 54
    }
    required init(coder: NSCoder) { fatalError("unsupported") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        backgroundFill.setFill()
        bounds.fill()

        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let text = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]

        // Line number of the first visible glyph (no wrapping → fragments = lines).
        let firstChar = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = firstChar == 0
            ? 1
            : text.substring(to: firstChar).components(separatedBy: "\n").count
        var glyphIndex = glyphRange.location

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            let yInTV = frag.minY + tv.textContainerOrigin.y
            let y = convert(NSPoint(x: 0, y: yInTV), from: tv).y + (frag.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y), withAttributes: attrs)
            lineNumber += 1
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
    }
}

/// 22px two-tone checker — the image variant's backdrop.
private struct V2Checkerboard: View {
    @Environment(\.v2) private var v2
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 22
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col) % 2 == 0 {
                    ctx.fill(
                        Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(v2.paper3)
                    )
                }
            }
        }
        .background(v2.paper)
    }
}
