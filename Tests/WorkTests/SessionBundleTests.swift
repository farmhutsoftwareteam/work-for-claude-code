import XCTest
@testable import Work

/// Porting a session between Macs. The transcript is just a file; the hard
/// part is the PATH. Claude scopes session-id lookup to the current project
/// directory, and that directory's name is derived from the absolute
/// working directory — so a bundle written on one machine has to be
/// rewritten for the other machine's path or nothing resolves.
final class SessionBundleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-bundle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func manifest(
        provider: String = "claude",
        sessionId: String = "11111111-2222-3333-4444-555555555555",
        cwd: String = "/Users/alice/Projects/Work"
    ) -> V2SessionBundle.Manifest {
        .init(provider: provider, sessionId: sessionId, projectCwd: cwd,
              title: "Ship the release", draft: nil,
              exportedAt: Date(timeIntervalSince1970: 1_784_300_000), exportedBy: "test")
    }

    // MARK: - Path encoding (the reason imports work at all)

    func testProjectDirEncodingReplacesEveryNonAlphanumeric() {
        // Verified against a real directory on this machine:
        //   ~/Downloads/Mbira Tension Stems (1)
        //   → -Users-…-Downloads-Mbira-Tension-Stems--1-
        // which pins spaces, both parens, no dash-collapsing, no trim.
        XCTAssertEqual(
            SessionHistoryLoader.projectDirName(for: "/Users/m/Downloads/Mbira Tension Stems (1)"),
            "-Users-m-Downloads-Mbira-Tension-Stems--1-"
        )
    }

    func testDotsAndUnderscoresBecomeDashesToo() {
        // The old rule replaced only "/", so these two silently produced
        // directories that don't exist.
        XCTAssertEqual(SessionHistoryLoader.projectDirName(for: "/Users/m/Wan2.2"), "-Users-m-Wan2-2")
        XCTAssertEqual(SessionHistoryLoader.projectDirName(for: "/Users/m/my_app"), "-Users-m-my-app")
    }

    func testNonASCIILettersAlsoBecomeDashes() {
        // Character.isLetter is Unicode-aware and would have kept these;
        // the rule is [a-zA-Z0-9].
        XCTAssertEqual(SessionHistoryLoader.projectDirName(for: "/Users/m/café"), "-Users-m-caf-")
    }

    func testCaseIsPreserved() {
        XCTAssertEqual(SessionHistoryLoader.projectDirName(for: "/Users/M/Projects/Work"), "-Users-M-Projects-Work")
    }

    // MARK: - Round trip

    func testExportThenImportReproducesTheTranscriptByteForByte() throws {
        let source = tmp.appendingPathComponent("source.jsonl")
        // Deliberately awkward content: the transcript must be copied
        // verbatim, never parsed and re-encoded (its format is internal to
        // Claude Code and changes between releases).
        let body = #"{"type":"user","text":"héllo — ünicode"}"# + "\n"
            + #"{"type":"assistant","text":"line with \"quotes\" and \\backslashes"}"# + "\n"
        try body.write(to: source, atomically: true, encoding: .utf8)

        let bundle = tmp.appendingPathComponent("out.ateliersession")
        let lines = try V2SessionBundle.export(manifest: manifest(), transcriptAt: source, to: bundle)
        XCTAssertEqual(lines, 2)

        let readBack = try V2SessionBundle.readManifest(at: bundle)
        XCTAssertEqual(readBack.sessionId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(readBack.projectCwd, "/Users/alice/Projects/Work")
        XCTAssertEqual(readBack.agentProvider, .claude)

        // Import into a DIFFERENT path — the cross-machine case.
        let target = tmp.appendingPathComponent("imported.jsonl")
        try importBundle(bundle, to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), body,
                       "the transcript must survive a round trip unchanged")
    }

    /// Mirrors importBundle's copy without touching the real ~/.claude.
    private func importBundle(_ bundle: URL, to destination: URL) throws {
        let data = try Data(contentsOf: bundle)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        try data[data.index(after: newline)...].write(to: destination)
    }

    func testEmptyTranscriptStillProducesAReadableBundle() throws {
        let source = tmp.appendingPathComponent("empty.jsonl")
        try Data().write(to: source)
        let bundle = tmp.appendingPathComponent("empty.ateliersession")
        XCTAssertEqual(try V2SessionBundle.export(manifest: manifest(), transcriptAt: source, to: bundle), 0)
        XCTAssertEqual(try V2SessionBundle.readManifest(at: bundle).sessionId,
                       "11111111-2222-3333-4444-555555555555")
    }

    // MARK: - Destination rewriting

    func testClaudeDestinationUsesTheTARGETPathNotTheExportedOne() throws {
        // The bundle says /Users/alice/…; importing on Bob's Mac must land
        // in Bob's directory or `claude --resume` reports "No conversation
        // found with session ID".
        let url = try V2SessionBundle.destinationURL(
            provider: .claude, sessionId: "sess-1", projectCwd: "/Users/bob/code/Work"
        )
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "-Users-bob-code-Work")
        XCTAssertEqual(url.lastPathComponent, "sess-1.jsonl")
        XCTAssertFalse(url.path.contains("alice"))
    }

    func testCodexDestinationIsDateAndThreadKeyedNotPathKeyed() throws {
        let when = Date(timeIntervalSince1970: 1_784_300_000)
        let url = try V2SessionBundle.destinationURL(
            provider: .codex, sessionId: "019f6f7e-abcd", projectCwd: "/Users/bob/code/Work", now: when
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("rollout-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-019f6f7e-abcd.jsonl"))
        // Codex files aren't organised by working directory at all, so
        // nothing about the path needs rewriting for them.
        XCTAssertFalse(url.path.contains("code-Work"))
        XCTAssertTrue(url.path.contains("/.codex/sessions/"))
    }

    // MARK: - Refusals

    func testARandomFileIsRejectedRatherThanHalfImported() throws {
        let junk = tmp.appendingPathComponent("notes.txt")
        try "just some notes\nnothing to see\n".write(to: junk, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try V2SessionBundle.readManifest(at: junk)) { error in
            guard case V2SessionBundle.BundleError.notABundle = error else {
                return XCTFail("expected notABundle, got \(error)")
            }
        }
    }

    func testABundleWithNoNewlineAtAllIsRejected() throws {
        let weird = tmp.appendingPathComponent("weird.ateliersession")
        try Data(repeating: 0x41, count: 4096).write(to: weird)
        XCTAssertThrowsError(try V2SessionBundle.readManifest(at: weird))
    }

    func testANewerFormatIsRefusedRatherThanMisread() throws {
        let future = tmp.appendingPathComponent("future.ateliersession")
        let header = #"{"atelierBundle":99,"provider":"claude","sessionId":"s","projectCwd":"/p","exportedAt":"2026-07-20T00:00:00Z"}"#
        try (header + "\n{}\n").write(to: future, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try V2SessionBundle.readManifest(at: future)) { error in
            guard case V2SessionBundle.BundleError.unsupportedVersion(99) = error else {
                return XCTFail("expected unsupportedVersion(99), got \(error)")
            }
        }
    }

    func testAnUnknownProviderIsRefused() throws {
        let alien = tmp.appendingPathComponent("alien.ateliersession")
        let header = #"{"atelierBundle":1,"provider":"gemini","sessionId":"s","projectCwd":"/p","exportedAt":"2026-07-20T00:00:00Z"}"#
        try (header + "\n{}\n").write(to: alien, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try V2SessionBundle.readManifest(at: alien)) { error in
            guard case V2SessionBundle.BundleError.unknownProvider("gemini") = error else {
                return XCTFail("expected unknownProvider, got \(error)")
            }
        }
    }

    func testExportingAVanishedTranscriptSaysSoInsteadOfWritingAnEmptyBundle() {
        // Claude deletes transcripts after 30 days by default
        // (cleanupPeriodDays), so this is a real, reachable state.
        let missing = tmp.appendingPathComponent("gone.jsonl")
        let out = tmp.appendingPathComponent("out.ateliersession")
        XCTAssertThrowsError(try V2SessionBundle.export(manifest: manifest(), transcriptAt: missing, to: out)) { error in
            guard case V2SessionBundle.BundleError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "a failed export must not leave a stub bundle behind")
    }

    func testSuggestedFilenameIsRecognisableWithoutLeakingTheFullPath() {
        let name = V2SessionBundle.suggestedFilename(for: manifest())
        XCTAssertEqual(name, "Work-11111111.ateliersession")
        XCTAssertFalse(name.contains("Users"), "a filename shouldn't carry the exporting machine's paths")
    }
}
