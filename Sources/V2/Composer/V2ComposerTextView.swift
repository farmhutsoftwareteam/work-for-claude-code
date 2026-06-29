// NSTextView wrapper that gives the composer the keystroke behaviour SwiftUI
// TextField can't model on macOS:
//
//   • Enter         → submit
//   • Shift+Enter   → insert literal newline
//   • Cmd+Enter     → also submit (matches iMessage / Discord)
//   • Cmd+V image   → caught before AppKit pastes "[image]", emitted as
//                     NSImage via onImagePasted
//   • Drag & drop   → image-like file URLs delivered via onFilesDropped;
//                     in-memory image data (e.g. screenshot drag from
//                     Preview) routed through onImagePasted
//
// Plain monospaced text otherwise — no rich-text, no font menu, no
// automatic substitution.

import SwiftUI
import AppKit

struct V2ComposerTextView: NSViewRepresentable {

    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let isEnabled: Bool
    let foregroundColor: NSColor
    let placeholderColor: NSColor
    let onSubmit: () -> Void
    let onImagePasted: (NSImage) -> Void
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
        tv.placeholderString = placeholder

        if tv.string != text {
            let selected = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(selected.location, text.count), length: 0))
        }
        tv.textColor = foregroundColor
        tv.placeholderColor = placeholderColor
        tv.isEditable = isEnabled

        if focused && tv.window?.firstResponder !== tv {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: $focused)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var focusedBinding: Binding<Bool>
        weak var textView: NSTextView?
        var submitCallback: () -> Void = {}
        var imageCallback: (NSImage) -> Void = { _ in }
        var fileDropCallback: ([URL]) -> Void = { _ in }
        var popoverOpen: () -> Bool = { false }
        var popoverMove: (Int) -> Void = { _ in }
        var popoverPick: () -> Void = {}
        var popoverDismiss: () -> Void = {}
        var backspaceAtStart: () -> Bool = { false }

        init(text: Binding<String>, focused: Binding<Bool>) {
            self.textBinding = text
            self.focusedBinding = focused
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView else { return }
            textBinding.wrappedValue = tv.string
            tv.needsDisplay = true   // refresh placeholder visibility
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
        // 1. In-memory image data (screenshot, copy from preview, etc.)
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first,
           first.isValid {
            coordinator?.imageCallback(first)
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
        sender.draggingPasteboard.canReadObject(forClasses: [NSImage.self, NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return handlePasteboard(sender.draggingPasteboard)
    }

    static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"].contains(ext.lowercased())
    }
}
