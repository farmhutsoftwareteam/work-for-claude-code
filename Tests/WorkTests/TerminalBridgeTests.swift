// Integration coverage for TerminalBridge's JSON-RPC wire protocol (#55).
// The bridge is a REAL unix-socket server the instant init() returns — no
// mocks here: tests dial in with raw POSIX socket calls (the same
// primitives TerminalBridge itself uses, see its own `import Darwin`) and
// assert on the actual bytes that cross the wire. Covers framing (partial
// lines, batched lines), the initialize/tools-list golden shapes,
// unknown-method errors, and notification silence — the pieces easy to
// regress silently since the protocol has no compiler-checked schema on
// either end.

import XCTest
@testable import Work
import Darwin

// MARK: - Raw socket test client

/// Minimal AF_UNIX/SOCK_STREAM client for driving TerminalBridge's socket
/// directly. `@unchecked Sendable` for the same reason TerminalBridge
/// itself is: the fd and buffer are only ever touched from one thread at a
/// time per call, mirroring the production class's own annotation.
private final class RawSocketClient: @unchecked Sendable {
    private let fd: Int32
    private var pending = Data()

    init?(path: String) {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            raw[bytes.count] = 0
            return true
        }
        guard ok else { Darwin.close(s); return nil }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, size) }
        }
        guard connected == 0 else { Darwin.close(s); return nil }
        self.fd = s
    }

    /// Appends `\n` and writes in one shot — for well-formed single requests.
    func send(_ jsonLine: String) {
        sendRaw(jsonLine + "\n")
    }

    /// Writes exactly the given bytes with no framing added — lets the
    /// framing tests control newline placement and split points precisely.
    func sendRaw(_ s: String) {
        let data = Data(s.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    /// Reads one newline-delimited line, buffering any bytes read past the
    /// newline for the NEXT call — required so the batched-line test (two
    /// replies landing in a single recv()) doesn't drop the second reply.
    /// Bounded by `timeout` via SO_RCVTIMEO, set fresh on every call, so a
    /// hung server fails the test fast instead of hanging CI.
    func readLine(timeout: TimeInterval = 2.0) -> String? {
        if let line = takeBufferedLine() { return line }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }   // peer closed, or SO_RCVTIMEO expired (EAGAIN)
            pending.append(contentsOf: chunk[0..<n])
            if let line = takeBufferedLine() { return line }
        }
        return nil
    }

    private func takeBufferedLine() -> String? {
        guard let nl = pending.firstIndex(of: 0x0A) else { return nil }
        let line = pending.subdata(in: pending.startIndex..<nl)
        pending.removeSubrange(pending.startIndex...nl)
        return String(data: line, encoding: .utf8)
    }

    func close() {
        Darwin.close(fd)
    }
}

// MARK: - Tests

final class TerminalBridgeTests: XCTestCase {

    private var bridge: TerminalBridge!
    private var scopeToken: NSObject!

    override func setUpWithError() throws {
        scopeToken = NSObject()
        bridge = try TerminalBridge(scope: ObjectIdentifier(scopeToken), defaultCwd: NSTemporaryDirectory())
    }

    override func tearDown() {
        bridge?.closeBridge()
        bridge = nil
        scopeToken = nil
    }

    private func connectClient() throws -> RawSocketClient {
        try XCTUnwrap(RawSocketClient(path: bridge.socketPath), "failed to connect to \(bridge.socketPath)")
    }

    private func decodeObject(_ line: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: initialize / tools-list golden responses

    func test_initialize_goldenResponse() throws {
        let client = try connectClient()
        defer { client.close() }

        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let line = try XCTUnwrap(client.readLine(), "no reply to initialize")
        let obj = try decodeObject(line)

        XCTAssertEqual(obj["id"] as? Int, 1)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "atelier-terminal")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"], "capabilities.tools key must be present")
    }

    func test_toolsList_goldenResponse() throws {
        let client = try connectClient()
        defer { client.close() }

        client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let line = try XCTUnwrap(client.readLine(), "no reply to tools/list")
        let obj = try decodeObject(line)

        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 5)

        // Order matters — it's a static array in the source (Self.toolSchemas).
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, [
            "terminal_run", "terminal_read", "terminal_write", "terminal_status", "terminal_list",
        ])
    }

    // MARK: Errors and silent paths

    func test_unknownMethod_returnsJSONRPCError() throws {
        let client = try connectClient()
        defer { client.close() }

        client.send(#"{"jsonrpc":"2.0","id":2,"method":"totally/bogus"}"#)
        let line = try XCTUnwrap(client.readLine(), "no reply to unknown method")
        let obj = try decodeObject(line)

        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("totally/bogus"), "error message should name the unknown method, got: \(message)")
    }

    func test_notification_isSilentlyIgnored_pingStillReplies() throws {
        let client = try connectClient()
        defer { client.close() }

        // No "id" field ⇒ notification, matching normal JSON-RPC shape. Note
        // the source's actual guard (`handle(line:fd:)`) keys off the
        // "notifications/" method prefix, not off id absence — id is simply
        // never echoed back for it either way since `reply`/`replyError`
        // both bail out when id is nil.
        client.send(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        client.send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)

        let line = try XCTUnwrap(client.readLine(), "no reply to ping")
        let obj = try decodeObject(line)
        XCTAssertEqual(obj["id"] as? Int, 3)
        XCTAssertNotNil(obj["result"])

        XCTAssertNil(client.readLine(timeout: 0.4), "notification must not produce a second reply")
    }

    func test_malformedLine_isDroppedWithoutCrashing() throws {
        let client = try connectClient()
        defer { client.close() }

        client.sendRaw("not json at all\n")
        client.send(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)

        let line = try XCTUnwrap(client.readLine(), "no reply to ping after malformed line")
        let obj = try decodeObject(line)
        XCTAssertEqual(obj["id"] as? Int, 5)

        XCTAssertNil(client.readLine(timeout: 0.4), "malformed line must not itself produce a reply")
    }

    // MARK: Framing

    func test_partialLineFraming_splitMidToken_stillParses() throws {
        let client = try connectClient()
        defer { client.close() }

        let full = #"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"# + "\n"
        // Split mid-token, inside the "initialize" string literal itself, to
        // prove the server buffers until it sees `\n` rather than trying to
        // parse on every individual read().
        let marker = "\"method\":\"init"
        let markerRange = try XCTUnwrap(full.range(of: marker), "marker not found in fixture request")
        let firstHalf = String(full[..<markerRange.upperBound])
        let secondHalf = String(full[markerRange.upperBound...])

        client.sendRaw(firstHalf)
        Thread.sleep(forTimeInterval: 0.05)
        client.sendRaw(secondHalf)

        let line = try XCTUnwrap(client.readLine(), "no reply after reassembled partial line")
        let obj = try decodeObject(line)
        XCTAssertEqual(obj["id"] as? Int, 4)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
    }

    func test_batchedLineFraming_twoRequestsOneWrite_twoRepliesCorrelated() throws {
        let client = try connectClient()
        defer { client.close() }

        let combined = #"{"jsonrpc":"2.0","id":10,"method":"ping"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":11,"method":"ping"}"# + "\n"
        client.sendRaw(combined)

        let firstLine = try XCTUnwrap(client.readLine(), "no first reply")
        let secondLine = try XCTUnwrap(client.readLine(), "no second reply")
        let first = try decodeObject(firstLine)
        let second = try decodeObject(secondLine)

        XCTAssertEqual(first["id"] as? Int, 10)
        XCTAssertEqual(second["id"] as? Int, 11)
    }

    // MARK: tools/call — light round trip only (terminal_list, empty scope)

    /// Unlike every method above, tools/call hops to the main actor inside
    /// TerminalBridge via `DispatchQueue.main.sync` (CoTerminalManager runs
    /// there). Doing the blocking socket round trip on the test's own
    /// thread would risk starving that hop if it ever landed on the main
    /// thread, so it runs on a detached task instead, keeping the main
    /// thread free to service the sync call. terminal_list on a fresh scope
    /// is cheap — it just returns an empty list, no process spawn.
    func test_toolsCall_terminalList_onEmptyScope_roundTrips() async throws {
        let client = try connectClient()
        defer { client.close() }

        let replyLine = await Task.detached {
            client.send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"terminal_list","arguments":{}}}"#)
            return client.readLine()
        }.value

        let line = try XCTUnwrap(replyLine, "no reply to tools/call")
        let obj = try decodeObject(line)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "text")

        let payloadText = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try decodeObject(payloadText)
        let terminals = try XCTUnwrap(payload["terminals"] as? [[String: Any]])
        XCTAssertTrue(terminals.isEmpty, "empty scope should list zero terminals")
    }
}
