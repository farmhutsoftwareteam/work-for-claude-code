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
    /// True for the one message whose text is still growing (~30fps flushes).
    /// Streaming renders per-BLOCK, not merged runs: a merged run's key
    /// changes on every flush, so the whole message's prose — one giant
    /// NSTextView by then — was rebuilt, re-set, and re-measured per flush.
    /// That's O(message-length) work per delta (PERFORMANCE.md rule 1) and
    /// its full-document height re-measure is what made streaming replies
    /// visibly jump and blank ("things disappearing while it replies").
    /// Per-block, only the tail paragraph's small view churns; everything
    /// stable is a key-guarded no-op. The message flips to merged runs the
    /// moment it stops being the streaming row — one rebuild, then
    /// cross-paragraph selection (#72) works exactly as before.
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if isStreaming {
                // Per-block path (pre-#72 layout, M24 source-line identity).
                // Selection across paragraphs doesn't matter mid-stream —
                // the text is moving; it matters the second the reply lands,
                // which is when this switches to the merged-run path below.
                ForEach(blocks) { item in
                    blockView(item.block)
                }
            } else {
                // Rows are RUNS, not individual blocks (#72): contiguous prose
                // blocks (paragraphs, headings, bullets, ordered lists) merge
                // into ONE NSTextView so drag-selection flows across them —
                // per-block NSTextViews bounded every selection to a single
                // paragraph ("the text highlighter can only select one line").
                // Code fences and tables keep their own chrome (copy button,
                // grid) and bound selection there, which matches expectation.
                //
                // Identity is the run's first block's SOURCE START LINE, same
                // scheme as the per-block ids before it (bug-hunt M24) — a
                // table materializing mid-stream splits a run without shifting
                // the ids of anything whose source position didn't move.
                ForEach(runs) { run in
                    switch run.kind {
                    case .prose(let blocks):
                        V2ProseRunView(blocks: blocks, runKey: run.key, baseDir: baseDir)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .chrome(let block):
                        blockView(block)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private var runs: [IDRun] {
        Self.cachedRuns(text)
    }

    /// Chrome blocks (code fences, tables) always render here; the prose
    /// cases are the live path while a message STREAMS (isStreaming above)
    /// and a fallback otherwise — finalized prose renders via merged runs
    /// (V2ProseRunView).
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
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.number.map { "\($0)." } ?? Self.bulletGlyph(depth: item.depth))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(v2.mute)
                        V2RichText(markdown: item.text, baseDir: baseDir)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }
        case .divider:
            Rectangle().fill(v2.line)
                .frame(height: 1)
                .padding(.vertical, 3)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(v2.line2).frame(width: 2)
                V2RichText(markdown: text, baseDir: baseDir)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.82)
            }
        case .codeFence(let lang, let body):
            V2CodeBlock(lang: lang, code: body)
        case .table(let header, let rows):
            V2MarkdownTable(header: header, rows: rows)
        }
    }

    /// Nesting markers: • at the top level, ◦ then · below it — the depth
    /// has to be visible in the glyph as well as the indent or deep lists
    /// read as accidental spacing.
    static func bulletGlyph(depth: Int) -> String {
        switch depth {
        case 0: return "•"
        case 1: return "◦"
        default: return "·"
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

    private var blocks: [IDBlock] {
        Self.cachedChunk(text)
    }

    // Block-splitting cache. The transcript re-renders every token (the whole
    // VStack), so without this every stable message re-chunks on every token of
    // the reply currently streaming. Keyed by the message text → cache hit for
    // anything not actively growing.
    //
    // Known residual gap (bug-hunt M25, prior-audit M11): the message that is
    // ACTIVELY streaming right now always misses here, because its cache key
    // (the full text) changes on every ~30fps flush — so it re-chunks from
    // line 0 every time, bounded to that one message's length (not the whole
    // transcript, since M11's original fix moved this from a per-transcript
    // to a per-message cache). A real fix would reuse every block except the
    // last one across flushes (only the last block can still be "open" given
    // this app's append-only streaming invariant) and re-chunk just the tail
    // — but doing that correctly means threading a `startLine` offset through
    // every branch of `chunk()` and re-validating the table-lookahead and
    // paragraph-continuation logic against a moved window, which is enough
    // surface area to get subtly wrong in a fix pass with no build to verify
    // against. Left as-is rather than risk landing a worse bug in exchange
    // for a MEDIUM-severity, already-bounded cost.
    nonisolated(unsafe) private static var chunkCache: [String: [IDBlock]] = [:]

    private static func cachedChunk(_ text: String) -> [IDBlock] {
        if let hit = chunkCache[text] { return hit }
        let result = chunk(text)
        if chunkCache.count >= parseCacheLimit { chunkCache.removeAll(keepingCapacity: true) }
        chunkCache[text] = result
        return result
    }

    /// One list row. `depth` is the nesting level (0-based, from leading
    /// indentation); `number` carries an ordered item's SOURCE number.
    /// Both exist because of what real Codex replies do constantly and
    /// Claude's flatter style never exposed (counted across 67 real
    /// rollouts, 2026-07-20): 2,500 nested-bullet lines were flattened to
    /// top level, and 4,729 ordered lines don't start at 1 — a renderer
    /// that renumbers from its own loop index rewrites "3. Run tests"
    /// into "1. Run tests".
    struct ListItem: Equatable {
        var text: String
        let depth: Int
        var number: Int?
    }

    enum MDBlock: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// Bullets and ordered items share one block so mixed nesting
        /// (an ordered child under a bullet parent) stays one list.
        case list([ListItem])
        case codeFence(lang: String, body: String)
        case table(header: [String], rows: [[String]])
        case divider
        case quote(String)
    }

    /// A block plus the SOURCE LINE it starts at, used as ForEach identity
    /// (bug-hunt M24) — see the comment on `body` above for why the array
    /// index alone isn't stable across a mid-stream reclassification.
    struct IDBlock: Identifiable {
        let id: Int
        let block: MDBlock
    }

    // MARK: - Prose runs (#72)

    /// A render row: either a merged run of contiguous prose blocks (one
    /// NSTextView — selection flows across all of them) or a single chrome
    /// block (code fence / table) with its own custom view.
    enum RunKind {
        case prose([MDBlock])
        case chrome(MDBlock)
    }

    /// `id` is the run's first block's source start line (M24 semantics).
    /// `key` is a stable serialization of the run's CONTENT — the run
    /// view's updateNSView compares it to skip rebuilds, and the assembled
    /// NSAttributedString is cached by it, so stable runs cost nothing
    /// while a sibling streams.
    struct IDRun: Identifiable {
        let id: Int
        let kind: RunKind
        let key: String
    }

    /// Cached alongside chunkCache with the same key + lifecycle: grouping
    /// (and key-string building) runs once per unique message text, never
    /// per render.
    nonisolated(unsafe) private static var runsCache: [String: [IDRun]] = [:]

    private static func cachedRuns(_ text: String) -> [IDRun] {
        if let hit = runsCache[text] { return hit }
        let result = groupRuns(cachedChunk(text))
        if runsCache.count >= parseCacheLimit { runsCache.removeAll(keepingCapacity: true) }
        runsCache[text] = result
        return result
    }

    static func groupRuns(_ blocks: [IDBlock]) -> [IDRun] {
        var out: [IDRun] = []
        var pending: [MDBlock] = []
        var pendingId: Int?
        var keyParts: [String] = []

        func flush() {
            if let id = pendingId, !pending.isEmpty {
                out.append(IDRun(id: id, kind: .prose(pending), key: keyParts.joined(separator: "\u{02}")))
            }
            pending = []; pendingId = nil; keyParts = []
        }

        for item in blocks {
            switch item.block {
            // Dividers join fences and tables as chrome: an NSTextView run
            // can't draw a horizontal rule, and a rule is a section break —
            // bounding selection at it matches how it reads.
            case .codeFence, .table, .divider:
                flush()
                out.append(IDRun(id: item.id, kind: .chrome(item.block), key: ""))
            case .paragraph(let s):
                if pendingId == nil { pendingId = item.id }
                pending.append(item.block)
                keyParts.append("p:\(s)")
            case .heading(let level, let text):
                if pendingId == nil { pendingId = item.id }
                pending.append(item.block)
                keyParts.append("h\(level):\(text)")
            case .list(let items):
                if pendingId == nil { pendingId = item.id }
                pending.append(item.block)
                // Depth and source number are part of the rendered output,
                // so they must be part of the cache key.
                keyParts.append("l:" + items.map { "\($0.depth)/\($0.number.map(String.init) ?? "-")/\($0.text)" }
                    .joined(separator: "\u{01}"))
            case .quote(let text):
                if pendingId == nil { pendingId = item.id }
                pending.append(item.block)
                keyParts.append("q:\(text)")
            }
        }
        flush()
        return out
    }

    static func chunk(_ text: String) -> [IDBlock] {
        var out: [IDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let blockStart = i
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
                out.append(IDBlock(id: blockStart, block: .codeFence(lang: lang, body: body.joined(separator: "\n"))))
                continue
            }

            // Thematic break (--- / *** / ___). Checked before lists: "---"
            // can't match a bullet ("- " needs the space) but the ordering
            // makes the intent explicit. A dash rule directly UNDER text is
            // setext and handled inside paragraph accumulation below.
            if isRule(trimmed) {
                out.append(IDBlock(id: blockStart, block: .divider))
                i += 1
                continue
            }

            // ATX heading, any depth — #### and deeper clamp to the level-3
            // style rather than falling through as a literal "#### Foo"
            // paragraph.
            if let (level, headingText) = atxHeading(trimmed) {
                out.append(IDBlock(id: blockStart, block: .heading(level: min(level, 3), text: headingText)))
                i += 1
                continue
            }

            // Blockquote — consecutive "> " lines collapse into one quote.
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(IDBlock(id: blockStart, block: .quote(quote.joined(separator: "\n"))))
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
                out.append(IDBlock(id: blockStart, block: .table(header: header, rows: rows)))
                continue
            }

            // List — bullets and ordered items together, depth from the RAW
            // line's indentation (trimming first is what flattened every
            // nested list), numbers from the source (renumbering from the
            // render loop's own index is what rewrote "3." as "1.").
            if isBullet(trimmed) || orderedItem(trimmed) != nil {
                var items: [ListItem] = []
                while i < lines.count {
                    let rawLine = lines[i]
                    let t = rawLine.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    let depth = depthFor(leadingIndent(rawLine))
                    if let (number, rest) = orderedItem(t) {
                        items.append(ListItem(text: rest, depth: depth, number: number))
                    } else if isBullet(t) {
                        items.append(ListItem(text: stripBullet(t), depth: depth, number: nil))
                    } else if leadingIndent(rawLine) >= 2, !items.isEmpty {
                        // Lazy continuation: an indented plain line belongs
                        // to the item above it, not to a fresh paragraph.
                        items[items.count - 1].text += "\n" + t
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(IDBlock(id: blockStart, block: .list(items)))
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
                // Setext underline: "Title\n---" (or ===) is a heading, not
                // a paragraph carrying literal dashes. Only a single-line
                // paragraph promotes; under a longer one the rule reads as
                // a divider and the outer loop picks it up.
                if para.count == 1, isSetextUnderline(t) {
                    out.append(IDBlock(id: blockStart, block: .heading(
                        level: t.hasPrefix("=") ? 1 : 2,
                        text: para[0].trimmingCharacters(in: .whitespaces)
                    )))
                    i += 1
                    para = []
                    break
                }
                if isRule(t) { break }
                if atxHeading(t) != nil { break }
                if t.hasPrefix("```") || t.hasPrefix(">") { break }
                if isBullet(t) || orderedItem(t) != nil { break }
                if isTableRow(t), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) { break }
                para.append(l)
                i += 1
            }
            if !para.isEmpty {
                out.append(IDBlock(id: blockStart, block: .paragraph(para.joined(separator: "\n"))))
            }
        }
        return out
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2))
    }

    /// "3. text" / "3) text" → (3, "text"). Codex emits both delimiters
    /// (69 "N)" lines in the real corpus) and lists that continue across
    /// message boundaries, so the source number is data, not decoration.
    private static func orderedItem(_ s: String) -> (number: Int, text: String)? {
        guard let mark = s.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let prefix = s[..<mark]
        guard !prefix.isEmpty, prefix.count <= 4, prefix.allSatisfy(\.isNumber),
              let number = Int(prefix) else { return nil }
        let after = s.index(after: mark)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return (number, String(s[s.index(after: after)...]))
    }

    /// Leading indentation in spaces (tab = 4) measured on the RAW line.
    private static func leadingIndent(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    /// Two-space indents per level (Codex's convention), clamped so a
    /// pathological indent can't push text off the pane.
    private static func depthFor(_ indent: Int) -> Int {
        min(indent / 2, 4)
    }

    /// Thematic break: 3+ of the same -, *, or _ and nothing else.
    private static func isRule(_ s: String) -> Bool {
        guard s.count >= 3, let first = s.first, "-*_".contains(first) else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// Setext underline: 2+ dashes or equals signs and nothing else.
    private static func isSetextUnderline(_ s: String) -> Bool {
        guard s.count >= 2, let first = s.first, first == "-" || first == "=" else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// "## Title" → (2, "Title") for any 1–6 hash prefix.
    private static func atxHeading(_ s: String) -> (level: Int, text: String)? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = s.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, String(rest.dropFirst()))
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
