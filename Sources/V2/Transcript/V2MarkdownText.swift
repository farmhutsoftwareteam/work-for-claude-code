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
    /// Project cwd for resolving relative file mentions into Quick Look links.
    var baseDir: String? = nil

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
            // NSTextView-backed prose: pointing-hand cursor on links, native
            // selection, click-to-open (SwiftUI Text can't do per-run cursors).
            V2RichText(markdown: text, baseDir: baseDir)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                        V2RichText(markdown: item, baseDir: baseDir)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                        V2RichText(markdown: item, baseDir: baseDir)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .codeFence(let lang, let body):
            V2CodeBlock(lang: lang, code: body)
        case .table(let header, let rows):
            V2MarkdownTable(header: header, rows: rows)
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
        // Inline code shares the agent-vocabulary "token" swatch.
        Self.inlineAttributed(s, codeBg: v2.tok, ink: v2.tokInk)
    }

    /// Inline markdown (**bold**, *italic*, `code`, [links]) → AttributedString,
    /// with the paper3 swatch on inline code. Static so table cells reuse it.
    ///
    /// The expensive step — `AttributedString(markdown:)` — is CACHED by the raw
    /// string (theme-independent). While a reply streams in, the stable prefix
    /// paragraphs hash to the same strings every frame, so they hit the cache
    /// for free and only the growing tail paragraph re-parses. Without this the
    /// whole message re-parsed every token (O(n²) per reply). Colours are applied
    /// fresh each call (cheap run walk) so the cache survives light/dark switches.
    static func inlineAttributed(_ s: String, codeBg: Color, ink: Color) -> AttributedString {
        var out = parsedMarkdown(s)
        for run in out.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range].backgroundColor = codeBg
                out[run.range].foregroundColor = ink
            }
            // Make links LOOK clickable (SwiftUI Text opens .link attributes in
            // the default browser; without styling they were invisible as
            // links). System link blue, matching the NSTextView prose renderer.
            if run.link != nil {
                out[run.range].foregroundColor = Color(nsColor: .linkColor)
                out[run.range].underlineStyle = .single
            }
        }
        return out
    }

    // Parse cache. Touched only from the main actor (view rendering), so the
    // unsynchronised dictionary is safe; worst case under contention is a
    // redundant parse, never corruption.
    nonisolated(unsafe) private static var parseCache: [String: AttributedString] = [:]
    private static let parseCacheLimit = 1024

    private static func parsedMarkdown(_ s: String) -> AttributedString {
        if let hit = parseCache[s] { return hit }
        var parsed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        linkifyBareURLs(&parsed)
        // Coarse eviction: when full, drop everything. The stable prefix re-warms
        // on the next frame; a transient spike beats unbounded growth.
        if parseCache.count >= parseCacheLimit { parseCache.removeAll(keepingCapacity: true) }
        parseCache[s] = parsed
        return parsed
    }

    /// Claude usually emits URLs bare (https://…), not as [markdown](links) —
    /// and Apple's inline parser only links the latter. Detect bare URLs /
    /// emails and attach .link so they're clickable. Runs once per unique
    /// string (inside the parse cache), so it costs nothing while streaming.
    private static func linkifyBareURLs(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        guard plain.contains("://") || plain.contains("www.") || plain.contains("@") else { return }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let range = Range(match.range, in: attr),
                  attr[range].link == nil   // don't stomp real markdown links
            else { continue }
            attr[range].link = url
        }
    }

    // MARK: - Block chunker

    private var blocks: [MDBlock] {
        Self.cachedChunk(text)
    }

    // Block-splitting cache. The transcript re-renders every token (the whole
    // VStack), so without this every stable message re-chunks on every token of
    // the reply currently streaming. Keyed by the message text → cache hit for
    // anything not actively growing.
    nonisolated(unsafe) private static var chunkCache: [String: [MDBlock]] = [:]

    private static func cachedChunk(_ text: String) -> [MDBlock] {
        if let hit = chunkCache[text] { return hit }
        let result = chunk(text)
        if chunkCache.count >= parseCacheLimit { chunkCache.removeAll(keepingCapacity: true) }
        chunkCache[text] = result
        return result
    }

    enum MDBlock {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case ordered([String])
        case codeFence(lang: String, body: String)
        case table(header: [String], rows: [[String]])
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

            // GFM table: a header row of pipes immediately followed by a
            // delimiter row (|---|:--:|). Without this, tables fell through to
            // the paragraph branch and rendered as raw "| a | b |" text.
            if isTableRow(trimmed), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                let header = parseTableRow(raw)
                i += 2  // consume header + delimiter
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
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
                if isTableRow(t), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) { break }
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

    // MARK: - Table parsing

    private static func isTableRow(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).contains("|")
    }

    /// A GFM delimiter row: only |, -, :, and spaces, with at least one dash.
    private static func isTableDelimiter(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split a "| a | b |" row into trimmed cells, dropping the outer pipes.
    private static func parseTableRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Table

/// Renders a GFM table. Columns auto-size to content via Grid; if the table is
/// wider than the column it scrolls horizontally (the standard chat behaviour)
/// rather than breaking the layout. Header row gets the paper3 swatch; rows are
/// separated by thin rules.
private struct V2MarkdownTable: View {
    @Environment(\.v2) private var v2
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(value(header, c), isHeader: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    Divider().overlay(idx == 0 ? v2.line2 : v2.line)
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { c in
                            cell(value(row, c), isHeader: false)
                        }
                    }
                }
            }
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .padding(1)   // keep the outer stroke from clipping under scroll
        }
    }

    private func value(_ row: [String], _ c: Int) -> String {
        row.indices.contains(c) ? row[c] : ""
    }

    private func cell(_ text: String, isHeader: Bool) -> some View {
        // Vocabulary: header is tertiary (faint, medium), cells are primary
        // (ink), and a verdict-word cell carries valence (sage/clay).
        let color = isHeader ? v2.faint : (Self.valence(text).map { $0 ? v2.add : v2.del } ?? v2.ink)
        return Text(V2MarkdownText.inlineAttributed(text, codeBg: v2.tok, ink: v2.tokInk))
            .font(.system(size: 12, design: .monospaced))
            .fontWeight(isHeader ? .medium : .regular)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A whole-cell verdict word → valence (true = good/sage, false = bad/clay,
    /// nil = neutral). Only matches when the cell IS the word, so "additive" in
    /// a sentence isn't colored.
    private static func valence(_ text: String) -> Bool? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let good: Set<String> = ["safe", "pass", "passed", "ok", "done", "yes", "✓", "good", "stable", "green"]
        let bad: Set<String> = ["watch", "fail", "failed", "error", "no", "✗", "blocked", "broken", "risk", "warning", "unsafe", "red"]
        if good.contains(t) { return true }
        if bad.contains(t) { return false }
        return nil
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
