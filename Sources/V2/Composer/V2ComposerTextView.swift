// NSTextView wrapper that gives the composer the keystroke behaviour SwiftUI
// TextField can't model on macOS:
//
//   • Enter         → submit
//   • Shift+Enter   → insert literal newline
//   • Cmd+Enter     → also submit (matches iMessage / Discord)
//   • Cmd+V image   → caught before AppKit pastes "[image]", emitted as
//                     raw bytes via onImagePasted (see the note on that
//                     property below for why NOT NSImage)
//   • Drag & drop   → image-like file URLs delivered via onFilesDropped;
//                     in-memory image data (e.g. screenshot drag from
//                     Preview) routed through onImagePasted
//
// Plain monospaced text otherwise — no rich-text, no font menu, no
// automatic substitution.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct V2ComposerTextView: NSViewRepresentable {

    @Binding var text: String
    @Binding var focused: Bool
    /// Caret position, AppKit → SwiftUI only — updated on every real
    /// selection change so trigger detection can read "what's around the
    /// cursor" instead of assuming it's always at the end of the draft.
    @Binding var cursorPosition: Int
    /// SwiftUI → AppKit one-shot: set alongside a programmatic `text` edit
    /// (a splice) to land the caret at a specific spot instead of the
    /// default "clamp the old selection into the new bounds" behavior.
    /// Consumed and reset to nil the next time `updateNSView` sees it.
    @Binding var pendingCursorTarget: Int?
    let placeholder: String
    let isEnabled: Bool
    let foregroundColor: NSColor
    let placeholderColor: NSColor
    let onSubmit: () -> Void
    /// Raw pasteboard bytes, NOT a decoded NSImage — measured on a real
    /// 48MP paste (2026-07-21): NSImage.tiffRepresentation alone blocks the
    /// main thread for 1.3s and allocates a 1.5GB intermediate buffer,
    /// which is exactly the "attaching an image hangs the app" report this
    /// fixes. `pb.data(forType:)` below is a cheap memory copy — no decode
    /// — so the main thread never touches image pixels at all; every
    /// expensive step (decode, downsample, encode) moves into
    /// V2AttachmentStore's existing off-actor Task.
    let onImagePasted: (Data) -> Void
    let onFilesDropped: ([URL]) -> Void
    // Slash-command popover hooks. When `popoverOpen` is true, the arrow
    // keys / Enter / Tab / Esc drive the popover instead of the text field.
    var popoverOpen: Bool = false
    var onPopoverMove: (Int) -> Void = { _ in }   // -1 up, +1 down
    var onPopoverPick: () -> Void = {}
    var onPopoverDismiss: () -> Void = {}
    // Backspace with the caret at the very start of an empty field. Returns
    // true if it was handled (e.g. it popped the active command chip), in
    // which case the delete is swallowed.
    var onBackspaceAtStart: () -> Bool = { false }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.autohidesScrollers = true

        let tv = ComposerNSTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.isEditable = isEnabled
        tv.allowsUndo = true
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = foregroundColor
        tv.insertionPointColor = foregroundColor
        tv.string = text
        tv.placeholderString = placeholder
        tv.placeholderColor = placeholderColor

        // Image + file drop targets.
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])

        scroll.documentView = tv

        // Make the text view fill the scroll view horizontally.
        tv.translatesAutoresizingMaskIntoConstraints = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Big pastes: lay out only what's visible instead of the whole
        // document per edit — a giant single paragraph otherwise re-wraps
        // end-to-end on every keystroke.
        tv.layoutManager?.allowsNonContiguousLayout = true

        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ComposerNSTextView else { return }

        // Refresh callbacks so SwiftUI's latest closures reach the
        // delegate / subclass.
        context.coordinator.submitCallback = onSubmit
        context.coordinator.imageCallback = onImagePasted
        context.coordinator.fileDropCallback = onFilesDropped
        context.coordinator.popoverOpen = { popoverOpen }
        context.coordinator.popoverMove = onPopoverMove
        context.coordinator.popoverPick = onPopoverPick
        context.coordinator.popoverDismiss = onPopoverDismiss
        context.coordinator.backspaceAtStart = onBackspaceAtStart

        // Guard every AppKit setter: the composer re-renders on each streamed
        // token (it observes the session for state/context), but none of these
        // change mid-stream — assigning them anyway dirties the text view and
        // forces redundant redraws.
        if tv.placeholderString != placeholder { tv.placeholderString = placeholder }
        if tv.string != text {
            let selected = tv.selectedRange()
            tv.string = text
            // NSRange/selectedRange are UTF-16 offsets — text.count (grapheme
            // clusters) undercounts for any multi-UTF16-unit character
            // (emoji, some CJK), which would clamp the caret short and throw
            // off the pendingCursorTarget math splice/dismiss now rely on.
            let length = (text as NSString).length
            // A pending target (set alongside a programmatic splice) wins
            // over "clamp the old selection" — that default is only right
            // when the text changed for some OTHER external reason.
            let target = pendingCursorTarget ?? min(selected.location, length)
            tv.setSelectedRange(NSRange(location: min(max(0, target), length), length: 0))
            if pendingCursorTarget != nil {
                DispatchQueue.main.async { pendingCursorTarget = nil }
            }
        }
        if tv.textColor != foregroundColor { tv.textColor = foregroundColor }
        if tv.placeholderColor != placeholderColor { tv.placeholderColor = placeholderColor }
        if tv.isEditable != isEnabled { tv.isEditable = isEnabled }

        // Claim focus ONLY on a rising edge of the binding (false→true), never
        // on a routine re-render. This view re-renders per streamed token, and
        // `focused` was write-only-true — so once the user clicked into the
        // transcript or a co-driven terminal mid-stream, EVERY token yanked
        // first-responder back into the composer: text selection broke, the
        // terminal dropped keystrokes, and interaction felt haunted. The
        // coordinator now syncs the binding false on resign (textDidEndEditing),
        // so intentional focus requests (send, tab switch, ⌘L) still land.
        if focused && !context.coordinator.lastFocusRequest && tv.window?.firstResponder !== tv {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
        context.coordinator.lastFocusRequest = focused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: $focused, cursor: $cursorPosition)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var focusedBinding: Binding<Bool>
        var cursorBinding: Binding<Int>
        weak var textView: NSTextView?
        var submitCallback: () -> Void = {}
        var imageCallback: (Data) -> Void = { _ in }
        var fileDropCallback: ([URL]) -> Void = { _ in }
        var popoverOpen: () -> Bool = { false }
        var popoverMove: (Int) -> Void = { _ in }
        var popoverPick: () -> Void = {}
        var popoverDismiss: () -> Void = {}
        var backspaceAtStart: () -> Bool = { false }
        /// Last value of `focused` seen by updateNSView — focus is claimed
        /// only when this flips false→true (rising edge).
        var lastFocusRequest = false

        init(text: Binding<String>, focused: Binding<Bool>, cursor: Binding<Int>) {
            self.textBinding = text
            self.focusedBinding = focused
            self.cursorBinding = cursor
        }

        /// Fires on every selection change, including as a side effect of
        /// typing — the live source of truth for "where's the caret right
        /// now," which trigger detection reads. Deferred: this can fire
        /// synchronously from `setSelectedRange` called inside
        /// `updateNSView` (the pendingCursorTarget consumption above), and
        /// mutating a binding synchronously from within a view update
        /// triggers a SwiftUI "modified during update" warning.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let loc = tv.selectedRange().location
            guard cursorBinding.wrappedValue != loc else { return }
            DispatchQueue.main.async { [cursorBinding] in cursorBinding.wrappedValue = loc }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView else { return }
            textBinding.wrappedValue = tv.string
            tv.needsDisplay = true   // refresh placeholder visibility
        }

        /// Focus moved elsewhere (transcript selection, co-driven terminal,
        /// another field) — reflect reality in the binding so the next
        /// intentional `focused = true` is a real rising edge.
        func textDidEndEditing(_ notification: Notification) {
            if focusedBinding.wrappedValue { focusedBinding.wrappedValue = false }
        }

        /// Catch Enter / Shift+Enter / Cmd+Enter — and, when the slash
        /// popover is open, the arrow keys / Tab / Esc to drive it.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Backspace at the very start of an empty field pops the active
            // command chip (if any) instead of doing nothing.
            if selector == #selector(NSResponder.deleteBackward(_:)) {
                let r = textView.selectedRange()
                if r.location == 0, r.length == 0, backspaceAtStart() { return true }
            }
            let popover = popoverOpen()
            if popover {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    popoverMove(-1); return true
                case #selector(NSResponder.moveDown(_:)):
                    popoverMove(1); return true
                case #selector(NSResponder.insertTab(_:)):
                    popoverPick(); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    popoverDismiss(); return true
                case #selector(NSResponder.insertNewline(_:)):
                    // Enter completes the highlighted command rather than
                    // sending, unless Shift is held (then insert a newline).
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    if mods.contains(.shift) {
                        textView.insertNewlineIgnoringFieldEditor(self); return true
                    }
                    popoverPick(); return true
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(self)
                    return true
                }
                submitCallback()
                return true
            }
            return false
        }
    }
}

// MARK: - NSTextView subclass

/// Subclass so we can:
///   1. Render a placeholder when empty.
///   2. Intercept paste so Cmd+V on an image hits our callback before
///      AppKit attempts to drop "[image]" into the text.
///   3. Accept drags carrying file URLs or in-memory image data.
final class ComposerNSTextView: NSTextView {
    weak var coordinator: V2ComposerTextView.Coordinator?
    var placeholderString: String = ""
    var placeholderColor: NSColor = .secondaryLabelColor

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: placeholderColor
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: (textContainer?.lineFragmentPadding ?? 0) + inset.width,
                             y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        if handlePasteboard(NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if handlePasteboard(NSPasteboard.general) { return }
        super.pasteAsPlainText(sender)
    }

    private func handlePasteboard(_ pb: NSPasteboard) -> Bool {
        // 1. In-memory image data (screenshot, copy from preview, etc.) —
        // raw bytes, not NSImage. See onImagePasted's doc comment: this is
        // the fix for the app hanging on a large pasted image.
        if let data = Self.rawImageData(from: pb) {
            coordinator?.imageCallback(data)
            return true
        }
        // 2. File URLs that point to image files.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { $0.isFileURL && Self.isImageExtension($0.pathExtension) }
            if !imageURLs.isEmpty {
                coordinator?.fileDropCallback(imageURLs)
                return true
            }
        }
        return false
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Narrowed to what performDragOperation actually handles: in-memory
        // image data, or FILE URLs. Checking bare NSURL readability (the old
        // check) also matched a plain web-link drag (e.g. from Safari's
        // address bar) — the cursor promised a drop that performDragOperation
        // then silently swallowed, since it only reads $0.isFileURL. The
        // .urlReadingFileURLsOnly option makes canReadObject agree with that.
        let pb = sender.draggingPasteboard
        let acceptsImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        let acceptsFileURL = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (acceptsImage || acceptsFileURL) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        // In-memory image data (e.g. a screenshot dragged from Preview).
        if let data = Self.rawImageData(from: pb) {
            coordinator?.imageCallback(data)
            return true
        }
        // Finder drag: accept ALL file URLs, not just images — the composer
        // attaches docs/pdfs/text too (the attach panel allows them). The
        // image-only filter stays on the PASTE path (handlePasteboard) so a
        // ⌘V of a copied file URL doesn't hijack a normal text paste.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty { coordinator?.fileDropCallback(files); return true }
        }
        return false
    }

    static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"].contains(ext.lowercased())
    }

    /// Raw image bytes off the pasteboard — `pb.data(forType:)` is a memory
    /// copy, not a decode, so this is main-thread-safe regardless of source
    /// size... for the type that's genuinely THERE.
    ///
    /// The trap (found by testing, not inspection — 2026-07-21): asking for
    /// a type that ISN'T natively on the pasteboard doesn't fail, it
    /// silently TRANSCODES. `NSPasteboard.types` (the aggregate accessor)
    /// advertises every type AppKit can synthesize on demand, not just what
    /// was written — write only PNG and `pb.types` still lists `.tiff`,
    /// because AppKit can manufacture one. Asking for that manufactured
    /// type is a full decode + uncompressed re-encode: measured at 215ms
    /// for a 4MB source PNG, scaling with resolution — this is EXACTLY the
    /// hang this fix exists to remove, just moved one layer down. A naive
    /// fixed try-order ([.tiff, .png]) silently regresses to the old bug
    /// on every pasteboard that happens to natively hold PNG (which is
    /// most modern screenshot tools).
    ///
    /// `NSPasteboardItem.types` (the PER-ITEM accessor, not the aggregate)
    /// reflects only what was actually written — verified both directions:
    /// a PNG-native item reports .tiff=false, a TIFF-native item reports
    /// .png=false, and reading via that detected type is ~0.04ms either
    /// way regardless of source size. That's the real fix: detect before
    /// reading, never guess-and-ask.
    static func rawImageData(from pb: NSPasteboard) -> Data? {
        let nativeTypes = pb.pasteboardItems?.first?.types ?? []
        for type: NSPasteboard.PasteboardType in [.tiff, .png, Self.jpegType] where nativeTypes.contains(type) {
            if let data = pb.data(forType: type), !data.isEmpty { return data }
        }
        return fallbackViaNSImage(pb)
    }

    /// No dedicated legacy NSPasteboard.PasteboardType constant for JPEG —
    /// bridged from UTType, same UTI space the native-type check above
    /// compares against.
    private static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// Falls back to NSImage only for a source with an image CLASS but no
    /// raw raster bytes at all (a vector-only clipboard entry — the one
    /// case with no ImageIO-decodable type to detect natively). Bounded to
    /// a fixed max dimension before drawing, so even this slow, rare path
    /// can't reproduce the unbounded hang this fix removes.
    private static let fallbackMaxDimension: CGFloat = 4096

    private static func fallbackViaNSImage(_ pb: NSPasteboard) -> Data? {
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first, image.isValid
        else { return nil }
        return boundedPNGData(from: image, maxDimension: fallbackMaxDimension)
    }

    /// Draws into a bitmap capped at `maxDimension` BEFORE drawing, so the
    /// cost is proportional to the output size, not whatever resolution the
    /// source vector content implies — the same shape of bug this whole
    /// fix removes, just for a path rare enough not to warrant the full
    /// off-actor treatment.
    private static func boundedPNGData(from image: NSImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: target))
        return bitmap.representation(using: .png, properties: [:])
    }
}
