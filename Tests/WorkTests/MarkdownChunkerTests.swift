import XCTest
@testable import Work

/// The block chunker against the constructs REAL Codex replies use.
/// Counted across 67 rollout files (2026-07-20): 4,729 ordered-list lines
/// that don't start at 1 (previously renumbered from the render loop's own
/// index), 2,550 standalone `---` rules (previously literal dashes), 2,500
/// nested-bullet lines (previously flattened), 1,212 blockquote lines,
/// 293 `####` headings, 69 `N)` ordered lines. Claude's flatter style never
/// exposed these; Codex's house style is built on them.
final class MarkdownChunkerTests: XCTestCase {
    private func blocks(_ text: String) -> [V2MarkdownText.MDBlock] {
        V2MarkdownText.chunk(text).map(\.block)
    }

    // MARK: - Ordered lists keep their source numbers

    func testOrderedListKeepsSourceNumbersInsteadOfRenumbering() {
        let md = "2. second step\n3. third step"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.number), [2, 3],
                       "\"3. Run tests\" must not render as \"1. Run tests\"")
    }

    func testParenDelimitedOrderedItemsParse() {
        let md = "1) first\n2) second"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.number), [1, 2])
        XCTAssertEqual(items.map(\.text), ["first", "second"])
    }

    func testYearLikeNumbersAreNotListMarkers() {
        // "2026. A big year." starts with digits+dot but 5+ digits is prose,
        // not a list marker.
        guard case .paragraph = blocks("20261. not a list").first else {
            return XCTFail("a 5-digit prefix must stay a paragraph")
        }
    }

    // MARK: - Nesting

    func testNestedBulletsKeepTheirDepth() {
        let md = "- top\n  - middle\n    - deep"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.depth), [0, 1, 2],
                       "trimming before matching is what flattened every nested list")
    }

    func testMixedOrderedChildrenUnderBulletsStayOneList() {
        let md = "- parent\n  1. child one\n  2. child two"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected one list") }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.depth), [0, 1, 1])
        XCTAssertEqual(items.map(\.number), [nil, 1, 2])
    }

    func testIndentedContinuationLineBelongsToItsItem() {
        let md = "- item text\n  continued on the next line\n- second"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "item text\ncontinued on the next line")
    }

    // MARK: - Rules and setext headings

    func testStandaloneRuleBecomesADividerNotLiteralDashes() {
        let md = "before\n\n---\n\nafter"
        let out = blocks(md)
        XCTAssertEqual(out.count, 3)
        guard case .divider = out[1] else { return XCTFail("--- must be a divider, not a paragraph of dashes") }
    }

    func testSetextUnderlinePromotesTheLineAboveToAHeading() {
        let out = blocks("Section title\n---")
        guard case .heading(let level, let text) = out.first else { return XCTFail("expected a heading") }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(text, "Section title")
        XCTAssertEqual(out.count, 1, "the underline must be consumed, not re-emitted as a divider")
    }

    func testEqualsUnderlineIsALevelOneHeading() {
        guard case .heading(1, "Big title") = blocks("Big title\n===").first else {
            return XCTFail("=== underline should promote to a level-1 heading")
        }
    }

    func testBoldTextIsNotARule() {
        guard case .paragraph = blocks("***emphasis***").first else {
            return XCTFail("***text*** is emphasis, not a thematic break")
        }
    }

    // MARK: - Quotes and deep headings

    func testConsecutiveQuoteLinesCollapseIntoOneQuote() {
        guard case .quote(let text) = blocks("> first line\n> second line").first else {
            return XCTFail("expected a quote block")
        }
        XCTAssertEqual(text, "first line\nsecond line")
    }

    func testDeepHeadingsClampToLevelThreeInsteadOfLiteralHashes() {
        guard case .heading(3, "Deep section") = blocks("#### Deep section").first else {
            return XCTFail("#### must render as a heading, not a paragraph starting with hashes")
        }
    }

    // MARK: - Real Codex reply shape (verbatim structure from the winpal thread)

    func testRealCodexReplyChunksCleanly() {
        let md = """
        No. `staging` has diverged from `main`:

        - `staging` is missing **10 commits** from `main`.
        - `staging` has **2 commits** not yet in `main`.

        So `main` should be merged into `staging` before continuing integration work.
        """
        let out = blocks(md)
        XCTAssertEqual(out.count, 3)
        guard case .paragraph = out[0], case .list(let items) = out[1], case .paragraph = out[2] else {
            return XCTFail("expected paragraph / list / paragraph, got \(out)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.depth), [0, 0])
    }

    // MARK: - Second sweep (corpus-driven): task lists, CRLF, fences in lists

    func testTaskListCheckboxesParse() {
        // 1,990 real corpus lines — Codex writes plans as GFM task lists,
        // which previously rendered their brackets literally.
        let md = "- [ ] buy milk\n- [x] ship release\n- plain item"
        guard case .list(let items) = blocks(md).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.checked), [false, true, nil])
        XCTAssertEqual(items.map(\.text), ["buy milk", "ship release", "plain item"])
    }

    func testCarriageReturnsAreInvisible() {
        // 784 real corpus lines carry \r; CharacterSet.whitespaces does NOT
        // strip it, so without normalization "---\r" fails the rule check
        // and item text keeps a trailing CR.
        let md = "- alpha\r\n- beta\r\n\r\n---\r"
        let out = blocks(md)
        guard case .list(let items) = out.first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.text), ["alpha", "beta"])
        guard case .divider = out.last else { return XCTFail("CR after --- must not demote the divider") }
    }

    func testFenceUnderAListItemBecomesASiblingCodeBlock() {
        // 151 real corpus lines: a fence indented beneath a list item is a
        // code block, not literal backticks inside the item's text.
        let md = "- run this:\n  ```bash\n  git status\n  ```"
        let out = blocks(md)
        XCTAssertEqual(out.count, 2)
        guard case .list(let items) = out[0], case .codeFence(let lang, let body) = out[1] else {
            return XCTFail("expected list then fence, got \(out)")
        }
        XCTAssertEqual(items.map(\.text), ["run this:"])
        XCTAssertEqual(lang, "bash")
        XCTAssertTrue(body.contains("git status"))
    }

    func testClosingHashSequenceIsDecorationNotContent() {
        guard case .heading(2, "Title") = blocks("## Title ##").first else {
            return XCTFail("closing hashes must be stripped from the heading text")
        }
    }

    func testCheckboxStateFeedsTheSharedMarker() {
        XCTAssertEqual(V2MarkdownText.listMarker(.init(text: "a", depth: 0, number: nil, checked: false)), "☐")
        XCTAssertEqual(V2MarkdownText.listMarker(.init(text: "a", depth: 0, number: nil, checked: true)), "☑")
        XCTAssertEqual(V2MarkdownText.listMarker(.init(text: "a", depth: 0, number: 3, checked: nil)), "3.")
        XCTAssertEqual(V2MarkdownText.listMarker(.init(text: "a", depth: 1, number: nil, checked: nil)), "◦")
    }

    // MARK: - Regressions: what already worked must keep working

    func testTablesStillParse() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        guard case .table(let header, let rows) = blocks(md).first else { return XCTFail("expected a table") }
        XCTAssertEqual(header, ["a", "b"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func testCodeFencesStillParseAndDashesInsideThemStayLiteral() {
        let md = "```bash\ngit merge main\n---\n```"
        guard case .codeFence(let lang, let body) = blocks(md).first else { return XCTFail("expected a fence") }
        XCTAssertEqual(lang, "bash")
        XCTAssertTrue(body.contains("---"), "rule detection must not reach inside fences")
    }

    func testGroupRunsTreatsDividerAsChromeAndListAsProse() {
        let runs = V2MarkdownText.groupRuns(V2MarkdownText.chunk("- a\n\n---\n\ntext"))
        XCTAssertEqual(runs.count, 3)
        guard case .prose = runs[0].kind, case .chrome = runs[1].kind, case .prose = runs[2].kind else {
            return XCTFail("expected prose / chrome(divider) / prose")
        }
    }
}
