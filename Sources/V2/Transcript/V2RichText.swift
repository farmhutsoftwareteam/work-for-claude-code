// Prose renderer for transcript text — an NSTextView-backed view that gives
// the native macOS text behaviours SwiftUI's Text can't: a pointing-hand
// cursor over links (I-beam over prose), click-to-open in the browser, and
// continuous native selection. SwiftUI Text has no per-run cursor control, so
// hovering a link showed the typing cursor.
//
// Perf (PERFORMANCE.md): the AppKit attributed string is CACHED by
// (string, theme), so the stable prefix of a streaming reply never rebuilds;
// updateNSView is guarded by a key compare so re-renders don't touch the
// text storage.

import SwiftUI
import AppKit

struct V2RichText: NSViewRepresentable {
    @Environment(\.v2) private var v2
    let markdown: String
    /// Base point size (13 = paragraph, 11.5 = thinking, …).
    var size: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastKey: String = ""
    }

    func makeNSView(context: Context) -> V2ProseTextView {
        let tv = V2ProseTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isAutomaticLinkDetectionEnabled = false
        return tv
    }

    func updateNSView(_ tv: V2ProseTextView, context: Context) {
        let dark = (v2.ink == V2Theme.dark.ink)
        let key = "\(size)|\(dark)|\(markdown)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        tv.linkTextAttributes = [
            .foregroundColor: NSColor(v2.ink),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        tv.textStorage?.setAttributedString(
            Self.attributed(markdown, size: size, palette: v2, dark: dark)
        )
    }

    /// Self-sizing: lay out at the proposed width, report the used height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: V2ProseTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer, let lm = nsView.layoutManager
        else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    // MARK: - AttributedString(markdown) → NSAttributedString (cached)

    nonisolated(unsafe) private static var cache: [String: NSAttributedString] = [:]
    private static let cacheLimit = 1024

    static func attributed(_ s: String, size: CGFloat, palette: V2Palette, dark: Bool) -> NSAttributedString {
        let key = "\(size)|\(dark)|\(s)"
        if let hit = cache[key] { return hit }

        // Reuse the shared (cached) inline-markdown parse, then map its runs
        // to AppKit attributes — the SwiftUI-scope colors/intents don't carry
        // into NSAttributedString on their own.
        let parsed = V2MarkdownText.inlineAttributed(s, codeBg: palette.tok, ink: palette.tokInk)
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * 0.66

        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed.characters[run.range])
            var attrs: [NSAttributedString.Key: Any] = [
                .font: base,
                .foregroundColor: NSColor(palette.ink),
                .paragraphStyle: para,
            ]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { attrs[.font] = bold }
                if intent.contains(.emphasized) {
                    let f = (attrs[.font] as? NSFont) ?? base
                    attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    attrs[.backgroundColor] = NSColor(palette.tok)
                    attrs[.foregroundColor] = NSColor(palette.tokInk)
                }
            }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = out
        return out
    }
}

/// NSTextView that never claims more than the text's own height and lets
/// clicks outside text fall through naturally.
final class V2ProseTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let lm = layoutManager else { return super.intrinsicContentSize }
        lm.ensureLayout(for: container)
        return lm.usedRect(for: container).size
    }
}
