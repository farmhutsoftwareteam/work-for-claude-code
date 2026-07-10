// Ring buffer coverage for CoTerminal's output store (#56 test plan item:
// "XCTest: ring buffer (append/cursor/tail/cap eviction)"). CoTermRing is a
// plain locked class, not @MainActor — no actor hopping needed here.

import XCTest
@testable import Work

final class CoTermRingTests: XCTestCase {

    // MARK: - Append + read basics

    func test_appendAndRead_returnsBytesWithCursorAtTotal() {
        let ring = CoTermRing()
        ring.append(Data("hello".utf8))

        let result = ring.read(since: nil)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.cursor, 5)
        XCTAssertEqual(ring.total, 5)
        XCTAssertFalse(result.gapped)
    }

    // MARK: - Cursor semantics

    func test_read_sinceCursor_returnsOnlyBytesAppendedAfterIt() {
        let ring = CoTermRing()
        ring.append(Data("AAAA".utf8))
        let first = ring.read(since: nil)
        XCTAssertEqual(first.cursor, 4)

        ring.append(Data("BBBB".utf8))
        let second = ring.read(since: first.cursor)
        XCTAssertEqual(second.text, "BBBB")
        XCTAssertEqual(second.cursor, 8)

        // Nothing new since the last read: empty text, cursor unchanged.
        let third = ring.read(since: second.cursor)
        XCTAssertEqual(third.text, "")
        XCTAssertEqual(third.cursor, 8)
    }

    // MARK: - Tail behavior when since is nil

    func test_read_sinceNil_returnsOnlyTailNotWholeBuffer() {
        let ring = CoTermRing()
        let full = String(repeating: "0123456789", count: 1000) // 10_000 bytes, ASCII
        ring.append(Data(full.utf8))

        let result = ring.read(since: nil)
        XCTAssertEqual(result.cursor, 10_000)
        XCTAssertLessThanOrEqual(result.text.utf8.count, 8_192)
        XCTAssertEqual(result.text, String(full.suffix(result.text.utf8.count)))
    }

    // MARK: - Cap eviction

    func test_capEviction_advancesBaseAndGapsStaleCursor() {
        let ring = CoTermRing()
        // 5 x 500KB crosses the 2_000_000 cap while staying fast (single-byte
        // repeating chunks avoid building large random payloads per test run).
        let chunk = Data(repeating: 0x61, count: 500_000)
        for _ in 0..<5 { ring.append(chunk) }

        XCTAssertEqual(ring.total, 2_500_000, "total tracks cumulative bytes appended, independent of eviction")

        // Cursor 0 predates the evicted base — read must clamp up, not crash.
        let result = ring.read(since: 0)
        XCTAssertTrue(result.gapped, "since < base must report a gap")
        XCTAssertFalse(result.text.isEmpty, "should read from the clamped base forward, not return nothing")
        XCTAssertEqual(result.cursor, 2_500_000)
    }

    // MARK: - markSecure / clearSecure boundary withholding

    func test_markSecure_withholdsBytesAppendedAfterBoundary() {
        let ring = CoTermRing()
        ring.append(Data("AAAA".utf8))
        ring.markSecure()
        ring.append(Data("BBBBBB".utf8))

        let tail = ring.read(since: nil)
        XCTAssertEqual(tail.text, "AAAA")
        XCTAssertEqual(tail.cursor, 4, "cursor should freeze at the secure boundary, not the true total")

        let sinceStart = ring.read(since: 0)
        XCTAssertEqual(sinceStart.text, "AAAA")
        XCTAssertFalse(sinceStart.text.contains("BBBBBB"))

        ring.clearSecure()
        ring.append(Data("CCCC".utf8))

        let afterClear = ring.read(since: nil)
        XCTAssertEqual(afterClear.cursor, 14, "cursor should advance past the old boundary once cleared")
        XCTAssertTrue(afterClear.text.contains("CCCC"))
    }

    // MARK: - clearSecure redacts buffered secure-window bytes (bug-hunt M21)

    /// The secure boundary is a temporary READ CLAMP, not permanent
    /// redaction on its own — `clearSecure()` used to just drop the
    /// boundary, so anything the child process printed while echo was off
    /// (e.g. a manual `*` mask) became readable again the instant echo
    /// returned. `clearSecure()` now overwrites those bytes in place before
    /// dropping the boundary, so they never resurface even via a read that
    /// spans straight through the old secure window.
    func test_clearSecure_redactsBufferedSecureWindowBytes() {
        let ring = CoTermRing()
        ring.append(Data("AAAA".utf8))
        ring.markSecure()
        ring.append(Data("SECRET".utf8))   // buffered while echo was off
        ring.clearSecure()
        ring.append(Data("CCCC".utf8))

        let result = ring.read(since: 0)
        XCTAssertFalse(result.text.contains("SECRET"), "bytes buffered during the secure window must stay redacted after clearSecure()")
        XCTAssertTrue(result.text.hasPrefix("AAAA"), "bytes before the secure window are untouched")
        XCTAssertTrue(result.text.hasSuffix("CCCC"), "bytes appended after clearSecure() are untouched")
        XCTAssertEqual(result.text.count, 14, "redaction overwrites in place — the byte length/cursor arithmetic must not shift")
    }

    // MARK: - markSecure is idempotent

    func test_markSecure_secondCallDoesNotMoveBoundary() {
        let ring = CoTermRing()
        ring.append(Data("AAAA".utf8))
        ring.markSecure() // boundary = 4
        ring.append(Data("BBBB".utf8))
        ring.markSecure() // no-op: boundary already set

        let result = ring.read(since: nil)
        XCTAssertEqual(result.cursor, 4, "first markSecure() call wins; the second must not move the boundary")
    }

    // MARK: - since beyond total

    func test_read_sinceBeyondTotal_clampsInsteadOfCrashing() {
        let ring = CoTermRing()
        ring.append(Data("AAAA".utf8))

        let result = ring.read(since: 1_000)
        XCTAssertEqual(result.text, "")
        XCTAssertLessThanOrEqual(result.cursor, ring.total)
    }

    // MARK: - cap eviction past a stale secure boundary (bug-hunt H3)

    /// A long-running raw-mode program (vim/htop/tmux — anything with echo
    /// off, not just password prompts) can push enough output through the
    /// ring that cap eviction advances `base` past `secureBoundary`. Before
    /// the fix, `end` stayed pinned below `base` and the slice subscript
    /// went negative — a crash reachable every second by the collapsed-pane
    /// tail read, with zero agent activity required.
    func test_capEvictionPastStaleSecureBoundary_doesNotCrash() {
        let ring = CoTermRing()
        ring.append(Data("secret-prompt".utf8))
        ring.markSecure() // boundary set early, before the flood below

        let chunk = Data(repeating: 0x61, count: 500_000)
        for _ in 0..<6 { ring.append(chunk) } // 3,000,000 bytes, cap is 2,000,000

        XCTAssertGreaterThan(ring.total - 2_000_000, 13, "base must have advanced past the 13-byte secure boundary for this test to be meaningful")

        // Must not crash, and must fail closed (empty) rather than leak
        // whatever now sits in the buffer past the stale boundary.
        let result = ring.read(since: nil)
        XCTAssertEqual(result.text, "")

        let resultSinceZero = ring.read(since: 0)
        XCTAssertEqual(resultSinceZero.text, "")
    }
}
