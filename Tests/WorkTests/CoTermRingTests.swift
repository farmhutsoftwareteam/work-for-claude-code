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
}
