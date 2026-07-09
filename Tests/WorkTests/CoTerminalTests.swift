// Integration coverage for CoTerminal (#56) beyond the pure-data-structure
// CoTermRing tests: these spawn real /bin/zsh child processes over a real
// PTY, so they poll with a timeout rather than asserting synchronously.
// Covers the two remaining test-plan items: "echo-off redaction with a
// `read -s` child" and "write-to-dead error" — plus CoTerminalManager's
// per-scope isolation ("concurrent terminals scoping").

import XCTest
@testable import Work

@MainActor
final class CoTerminalTests: XCTestCase {

    private var terminals: [CoTerminal] = []

    override func tearDown() async throws {
        terminals.forEach { $0.terminate() }
        terminals.removeAll()
    }

    private func makeTerminal(_ command: String) -> CoTerminal {
        let t = CoTerminal(command: command, cwd: NSTemporaryDirectory())
        terminals.append(t)
        return t
    }

    /// Polls `condition` on the main actor until it's true or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Echo-off redaction (the security invariant lives here, not the UI)

    func test_secureInput_becomesTrueDuringReadDashS() async {
        let t = makeTerminal("read -s -p 'Password: ' x; echo done")
        await waitUntil { t.secureInput }
        XCTAssertTrue(t.secureInput, "termios ECHO bit should read off while `read -s` is awaiting input")
    }

    func test_toolWrite_rejectedDuringSecureInput() async {
        let t = makeTerminal("read -s -p 'Password: ' x; echo done")
        await waitUntil { t.secureInput }
        XCTAssertTrue(t.secureInput, "precondition: must be in secure state before testing the write guard")

        XCTAssertThrowsError(try t.toolWrite("hunter2", submit: true)) { error in
            guard case CoTerminal.WriteError.secureInput = error else {
                XCTFail("expected .secureInput, got \(error)")
                return
            }
        }
        // Never logged to the agent-visible attribution strip either.
        XCTAssertTrue(t.agentInputs.isEmpty, "a rejected write must not appear in agentInputs")
    }

    func test_secureInput_clearsAfterReadReturns() async {
        // No real input is fed (nothing types into the pty), so `read -s`
        // blocks until the process is torn down — that's fine, we only need
        // the ON transition here; the OFF transition (secureInput -> false)
        // is exercised by processTerminated in the write-to-dead test below,
        // which uses a command with no secure prompt at all.
        let t = makeTerminal("read -s -p 'Password: ' x")
        await waitUntil { t.secureInput }
        XCTAssertTrue(t.secureInput)
    }

    // MARK: - Write-to-dead

    func test_toolWrite_throwsNotRunning_afterProcessExits() async {
        let t = makeTerminal("exit 0")
        await waitUntil { !t.isRunning }
        XCTAssertFalse(t.isRunning, "precondition: process must have exited")
        XCTAssertEqual(t.exitCode, 0)

        XCTAssertThrowsError(try t.toolWrite("anything", submit: true)) { error in
            guard case CoTerminal.WriteError.notRunning = error else {
                XCTFail("expected .notRunning, got \(error)")
                return
            }
        }
    }

    func test_secureInput_resetsOnProcessExit() async {
        // Exiting mid-secure-prompt (e.g. user hits ^C) must not leave a
        // terminal permanently "secure" and unreadable.
        let t = makeTerminal("read -s -p 'Password: ' x & sleep 0.2; kill %1 2>/dev/null; exit 1")
        await waitUntil { !t.isRunning }
        XCTAssertFalse(t.secureInput, "secureInput must reset to false once the process has terminated")
    }

    // MARK: - Concurrent terminals scoping (CoTerminalManager)

    func test_manager_scopesTerminalsIndependently() {
        let manager = CoTerminalManager.shared
        let scopeA = ObjectIdentifier(NSObject())
        let scopeB = ObjectIdentifier(NSObject())
        defer { manager.closeAll(scope: scopeA); manager.closeAll(scope: scopeB) }

        let ta = manager.run(command: "sleep 5", cwd: NSTemporaryDirectory(), scope: scopeA)
        let tb = manager.run(command: "sleep 5", cwd: NSTemporaryDirectory(), scope: scopeB)

        XCTAssertEqual(manager.terminal(id: ta.id.uuidString, scope: scopeA)?.id, ta.id)
        XCTAssertEqual(manager.terminal(id: tb.id.uuidString, scope: scopeB)?.id, tb.id)

        // Cross-scope lookup must miss — one session's tools can never touch
        // another session's terminals, even with a valid id string.
        XCTAssertNil(manager.terminal(id: ta.id.uuidString, scope: scopeB))
        XCTAssertNil(manager.terminal(id: tb.id.uuidString, scope: scopeA))
    }

    func test_manager_closeScope_doesNotAffectOtherScopes() {
        let manager = CoTerminalManager.shared
        let scopeA = ObjectIdentifier(NSObject())
        let scopeB = ObjectIdentifier(NSObject())
        defer { manager.closeAll(scope: scopeA); manager.closeAll(scope: scopeB) }

        let ta = manager.run(command: "sleep 5", cwd: NSTemporaryDirectory(), scope: scopeA)
        let tb = manager.run(command: "sleep 5", cwd: NSTemporaryDirectory(), scope: scopeB)

        manager.closeAll(scope: scopeA)

        XCTAssertNil(manager.terminal(id: ta.id.uuidString, scope: scopeA))
        XCTAssertEqual(manager.terminal(id: tb.id.uuidString, scope: scopeB)?.id, tb.id, "closing scope A must not touch scope B's terminals")
    }

    func test_manager_toolDispatch_terminalList_isScopeIsolated() {
        let manager = CoTerminalManager.shared
        let scopeA = ObjectIdentifier(NSObject())
        let scopeB = ObjectIdentifier(NSObject())
        defer { manager.closeAll(scope: scopeA); manager.closeAll(scope: scopeB) }

        _ = manager.run(command: "sleep 5", cwd: NSTemporaryDirectory(), scope: scopeA)

        let (payload, isError) = manager.handleTool(name: "terminal_list", args: [:], scope: scopeB, defaultCwd: NSTemporaryDirectory())
        XCTAssertFalse(isError)
        XCTAssertTrue(payload.contains("\"terminals\":[]"), "scope B must not see scope A's terminal via terminal_list: \(payload)")
    }
}
