// Markdown renderer for assistant text blocks. Matches the chat-states.dc.html
// spec: paragraphs in monospace 13/1.66, ## headings styled as helv uppercase
// section labels in mute color, bullets with hanging indent, inline `code` in
// the paper3 swatch, **bold**/*italic*/links via AttributedString(markdown:).
//
// Apple's AttributedString markdown init handles inline syntax only — block
// elements (headings, lists, fences) we chunk out by line ourselves before
// passing each paragraph through the inline parser.

import SwiftUI
import AppKit

struct V2MarkdownText: View {
    @Environment(\.v2) private var v2
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(13 * 0.66)
                .foregroundColor(v2.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                        Text(inlineAttributed(item))
                            .font(.system(size: 13, design: .monospaced))
                            .lineSpacing(13 * 0.66)
                            .foregroundColor(v2.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                        Text(inlineAttributed(item))
                            .font(.system(size: 13, design: .monospaced))
                            .lineSpacing(13 * 0.66)
                            .foregroundColor(v2.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .codeFence(let lang, let body):
            V2CodeBlock(lang: lang, code: body)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        if level >= 2 {
            // ## / ### → section label per design (helv uppercase, mute).
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.48)
                .foregroundColor(v2.mute)
                .padding(.top, 3)
        } else {
            // # — larger, monospaced ink. Rare in claude output but spec'd.
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.top, 3)
        }
    }

    // MARK: - Inline attributed string

    private func inlineAttributed(_ s: String) -> AttributedString {
        // Apple's parser is the cheapest way to get **bold**, *italic*,
        // `code`, and [links](…) without rolling our own. Preserve whitespace
        // so streaming partial deltas don't collapse spacing.
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return styleInlineCode(attr)
        }
        return AttributedString(s)
    }

    /// Apply the paper3 background swatch to runs marked as inline code so
    /// they match the design's `code` styling.
    private func styleInlineCode(_ input: AttributedString) -> AttributedString {
        var out = input
        for run in out.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range].backgroundColor = v2.paper3
                out[run.range].foregroundColor = v2.ink
            }
        }
        return out
    }

    // MARK: - Block chunker

    private var blocks: [MDBlock] {
        Self.chunk(text)
    }

    enum MDBlock {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case ordered([String])
        case codeFence(lang: String, body: String)
    }

    static func chunk(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("```") { break }
                    body.append(lines[i])
                    i += 1
                }
                i += 1  // consume closing fence
                out.append(.codeFence(lang: lang, body: body.joined(separator: "\n")))
                continue
            }

            // Heading
            if trimmed.hasPrefix("# ") {
                out.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                out.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("### ") {
                out.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                i += 1
                continue
            }

            // Bullet list
            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append(.bullet(items))
                continue
            }

            // Ordered list
            if isOrdered(trimmed) {
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripOrdered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append(.ordered(items))
                continue
            }

            // Blank line — separator, skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — accumulate until blank or block boundary
            var para: [String] = [raw]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ") { break }
                if t.hasPrefix("```") { break }
                if isBullet(t) || isOrdered(t) { break }
                para.append(l)
                i += 1
            }
            out.append(.paragraph(para.joined(separator: "\n")))
        }
        return out
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2))
    }

    private static func isOrdered(_ s: String) -> Bool {
        // 1. … / 12. …
        guard let dot = s.firstIndex(of: ".") else { return false }
        let prefix = s[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return false }
        let after = s.index(after: dot)
        return after < s.endIndex && s[after] == " "
    }

    private static func stripOrdered(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let after = s.index(after: dot)
        guard after < s.endIndex else { return "" }
        return String(s[s.index(after: after)...])
    }
}

// MARK: - Code block with one-click copy

/// A fenced code block with a header bar that always carries a Copy button —
/// the universal "copy the snippet" affordance (ChatGPT / Claude.ai / GitHub).
/// The body stays text-selectable too, so partial copies still work.
private struct V2CodeBlock: View {
    @Environment(\.v2) private var v2
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                        Text(copied ? "copied" : "copy")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(copied ? v2.ink : v2.mute)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper3)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line2).frame(height: 1) }

            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(v2.card)
                .textSelection(.enabled)
        }
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func copy() {
        V2Clipboard.copy(code)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Clipboard helper

enum V2Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
