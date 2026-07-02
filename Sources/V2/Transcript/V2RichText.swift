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
    /// Project cwd for resolving relative file mentions ("src/a.ts",
    /// "PLAN.md"). nil ⇒ only absolute/~ paths can be file links.
    var baseDir: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastKey: String = ""

        /// file:// links preview in Quick Look (stay in the app, Esc closes);
        /// everything else falls through to the default browser open.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.isFileURL else { return false }
            V2QuickLook.preview(url)
            return true
        }
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
        tv.delegate = context.coordinator
        // Links are styled per-run in the builder (web = blue underline,
        // file = token chip) — a uniform linkTextAttributes would blue-ify both.
        tv.linkTextAttributes = [:]
        return tv
    }

    func updateNSView(_ tv: V2ProseTextView, context: Context) {
        let dark = (v2.ink == V2Theme.dark.ink)
        let key = "\(size)|\(dark)|\(baseDir ?? "")|\(markdown)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        tv.textStorage?.setAttributedString(
            Self.attributed(markdown, size: size, palette: v2, dark: dark, baseDir: baseDir)
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

    static func attributed(_ s: String, size: CGFloat, palette: V2Palette, dark: Bool, baseDir: String? = nil) -> NSAttributedString {
        let key = "\(size)|\(dark)|\(baseDir ?? "")|\(s)"
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
            if let link = run.link {
                // Web link: blue underline, hand cursor (styled per-run since
                // file links below get the token treatment instead).
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.cursor] = NSCursor.pointingHand
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        linkifyFileMentions(out, baseDir: baseDir, palette: palette)

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = out
        return out
    }

    // MARK: - File mentions → Quick Look links

    /// Path-shaped candidates: multi-segment paths (src/a/b.ts, /abs, ~/x) or
    /// bare filenames with an extension (PLAN.md). Existence is verified
    /// before linkifying, so prose like "e.g." can never become a dead link —
    /// only files that are really on disk light up.
    nonisolated(unsafe) private static let fileRegex = try? NSRegularExpression(
        pattern: #"(?:~?/?[\w.@\-]+(?:/[\w.@\-]+)+|\b[\w@\-][\w.@\-]*\.[A-Za-z][A-Za-z0-9]{0,7}\b)"#
    )
    nonisolated(unsafe) private static var fileURLCache: [String: URL?] = [:]

    private static func linkifyFileMentions(_ out: NSMutableAttributedString, baseDir: String?, palette: V2Palette) {
        guard let regex = fileRegex else { return }
        let plain = out.string as NSString
        for match in regex.matches(in: out.string, range: NSRange(location: 0, length: plain.length)) {
            // Don't stomp an existing (web) link — e.g. a path inside a URL.
            if out.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { continue }
            let token = plain.substring(with: match.range)
            guard let url = resolveFile(token, baseDir: baseDir) else { continue }
            out.addAttributes([
                // The agent-vocabulary token chip, now alive: click → Quick Look.
                .link: url,
                .backgroundColor: NSColor(palette.tok),
                .foregroundColor: NSColor(palette.tokInk),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
                .toolTip: url.path,
            ], range: match.range)
        }
    }

    /// Resolve a mention to an existing file (absolute, ~, or relative to the
    /// project cwd). Cached — existence checks must not run per render.
    private static func resolveFile(_ token: String, baseDir: String?) -> URL? {
        let key = "\(baseDir ?? "")|\(token)"
        if let hit = fileURLCache[key] { return hit }
        var candidates: [String] = []
        if token.hasPrefix("~") {
            candidates.append(NSHomeDirectory() + token.dropFirst())
        } else if token.hasPrefix("/") {
            candidates.append(token)
        } else if let baseDir {
            var t = token
            if t.hasPrefix("./") { t.removeFirst(2) }
            candidates.append(baseDir + "/" + t)
        }
        let fm = FileManager.default
        let resolved = candidates.first(where: { fm.fileExists(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
        if fileURLCache.count >= cacheLimit { fileURLCache.removeAll(keepingCapacity: true) }
        fileURLCache[key] = resolved
        return resolved
    }
}

// MARK: - Quick Look

import Quartz

/// One-shot Quick Look preview for a local file — the native "just let me see
/// it" affordance (renders markdown, code, images, PDFs; Esc closes).
final class V2QuickLook: NSObject, QLPreviewPanelDataSource {
    // Only ever touched from the main thread (panel + link clicks), so the
    // unsynchronised singleton is safe.
    nonisolated(unsafe) static let shared = V2QuickLook()
    private var url: URL?

    @MainActor
    static func preview(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
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
