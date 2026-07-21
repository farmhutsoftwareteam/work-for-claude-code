// Portable session bundles — moving a conversation between machines.
//
// The blocker this exists to solve is NOT the transcript, which is just a
// file. It's the path: Claude scopes session-id lookup to the current
// project directory ("a session created elsewhere reports `No conversation
// found with session ID`"), and the directory name is derived from the
// ABSOLUTE working directory. Copy a transcript to a second Mac whose
// username differs and the derived name differs, so nothing resolves.
// Importing therefore has to rewrite the destination for the target
// machine's path — which is the whole job.
//
// Format: one file, first line a JSON manifest, every remaining line the
// transcript verbatim.
//
//   {"atelierBundle":1,"provider":"claude","sessionId":"…","projectCwd":"…"}
//   {"type":"user", …}
//   {"type":"assistant", …}
//
// Deliberately not a zip and not JSON-with-embedded-transcript: real
// sessions reach tens of megabytes (71 MB observed on this machine), so
// the transcript is copied line-for-line rather than parsed, re-encoded,
// or base64'd. It also means a bundle stays greppable, and a truncated
// one still has a readable manifest.
//
// Credentials are deliberately NOT included. Claude's live in the login
// Keychain and Codex's in ~/.codex/auth.json; a bundle that carried them
// would turn "send me that session" into "send me your account".

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "session-bundle")

struct V2SessionBundle {
    static let fileExtension = "ateliersession"
    /// Bumped only for a breaking manifest change. Import refuses a version
    /// it doesn't understand rather than writing a transcript it may have
    /// misread.
    static let currentVersion = 1

    struct Manifest: Codable, Equatable, Sendable {
        var atelierBundle: Int = V2SessionBundle.currentVersion
        /// "claude" | "codex" — the provider whose store the transcript
        /// belongs in on the far side.
        let provider: String
        /// Claude's session id / Codex's thread id.
        let sessionId: String
        /// Where the session RAN when exported. Kept for display and as the
        /// import default's basename; never used as a destination directly,
        /// because that's precisely what doesn't transfer.
        let projectCwd: String
        let title: String?
        let draft: String?
        let exportedAt: Date
        /// Informational: what wrote this, for diagnosing a bad import.
        let exportedBy: String?

        var agentProvider: V2AgentProvider? {
            switch provider {
            case "claude": return .claude
            case "codex": return .codex
            default: return nil
            }
        }
    }

    enum BundleError: LocalizedError {
        case unreadable
        case unwritable
        case notABundle
        case unsupportedVersion(Int)
        case unknownProvider(String)
        case sourceMissing(String)
        case codexRolloutMissing
        /// A transcript for this session already exists here. Import
        /// refuses by default: the destination is deterministic from the
        /// session id, so a re-import would otherwise silently destroy the
        /// local copy — including one a running CLI still has open.
        case alreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file couldn't be read."
            case .unwritable:
                return "That location couldn't be written to."
            case .notABundle:
                return "That isn't an Atelier session file."
            case .unsupportedVersion(let v):
                return "That session file was written by a newer Atelier (format \(v)). Update Atelier to open it."
            case .unknownProvider(let p):
                return "That session is for \"\(p)\", which this version of Atelier doesn't know how to import."
            case .sourceMissing(let path):
                return "The transcript for this session is no longer on disk (\(path)). Claude removes transcripts after 30 days by default."
            case .codexRolloutMissing:
                return "Couldn't find this thread's rollout file in ~/.codex/sessions."
            case .alreadyExists:
                return "This session already exists on this Mac."
            }
        }
    }

    // MARK: - Export

    /// Streams manifest + transcript into `destination`. Returns the number
    /// of transcript lines written.
    ///
    /// The transcript is copied line-for-line and never parsed: its entry
    /// format is explicitly internal to Claude Code and changes between
    /// releases, so a bundle that re-encoded it would rot. Copying verbatim
    /// means a bundle is exactly as resumable as the original was.
    /// Runs OFF the main actor — a real transcript is tens of megabytes
    /// (71 MB observed here), and copying that on the main thread trips
    /// HangWatchdog's 3s threshold, which responds by running `sample`,
    /// suspending the process at kernel level for another 3s. A big export
    /// would beachball and then be deliberately frozen by our own watchdog.
    @discardableResult
    static func export(
        manifest: Manifest,
        transcriptAt source: URL,
        to destination: URL
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BundleError.sourceMissing(source.lastPathComponent)
        }
        var header = try JSONEncoder.bundleEncoder.encode(manifest)
        header.append(0x0A)  // newline

        // Staged through a sibling temp file and moved into place only on
        // success. Writing straight at `destination` left a TRUNCATED
        // bundle behind when a copy failed part-way — and because the
        // manifest is written first, that stub still parses, so importing
        // it would silently restore half a conversation.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).ateliersession-partial")
        var lines = 0
        do {
            guard FileManager.default.createFile(atPath: staging.path, contents: nil),
                  let out = try? FileHandle(forWritingTo: staging)
            else { throw BundleError.unwritable }
            defer { try? out.close() }
            try out.write(contentsOf: header)

            // Chunked copy so a 70MB transcript never lands in memory whole.
            guard let input = try? FileHandle(forReadingFrom: source) else { throw BundleError.unreadable }
            defer { try? input.close() }
            var lastByte: UInt8?
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                lines += countNewlines(chunk)
                lastByte = chunk.last
            }
            // A final record without a trailing newline is still a record.
            if let lastByte, lastByte != 0x0A { lines += 1 }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        log.notice("exported session bundle: \(lines) entries")
        return lines
    }

    /// memchr rather than a byte-at-a-time reduce: the old version ran one
    /// closure per byte, which on a 71 MB transcript is 71 million calls.
    static func countNewlines(_ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            var count = 0
            var offset = 0
            while offset < raw.count,
                  let hit = memchr(base + offset, 0x0A, raw.count - offset) {
                count += 1
                offset = UnsafeRawPointer(hit) - base + 1
            }
            return count
        }
    }

    // MARK: - Import

    /// Reads just the manifest — cheap enough to run on selection, so the
    /// import sheet can show what a file contains before committing.
    static func readManifest(at url: URL) throws -> Manifest {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw BundleError.unreadable }
        defer { try? handle.close() }
        // A manifest is a few hundred bytes; cap the search so a wrong file
        // (a whole transcript, a video) can't be slurped looking for one.
        guard let head = try handle.read(upToCount: 64 * 1024),
              let newline = head.firstIndex(of: 0x0A)
        else { throw BundleError.notABundle }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder.bundleDecoder.decode(Manifest.self, from: head[..<newline])
        } catch {
            throw BundleError.notABundle
        }
        guard manifest.atelierBundle <= currentVersion else {
            throw BundleError.unsupportedVersion(manifest.atelierBundle)
        }
        guard manifest.agentProvider != nil else {
            throw BundleError.unknownProvider(manifest.provider)
        }
        return manifest
    }

    /// Writes the bundle's transcript into the right store for
    /// `targetProjectCwd` ON THIS MACHINE and returns the file it wrote.
    ///
    /// This is the path rewrite the whole feature exists for: the
    /// destination directory is derived from the TARGET path, not the
    /// exporting machine's.
    /// `replaceExisting` defaults to false on purpose. The Claude
    /// destination is deterministic from the session id, so the most
    /// natural way anyone tests this — export a session, import it straight
    /// back to check the round trip — targets the very file the running
    /// `claude` child still has open for append. Truncating that mid-flight
    /// leaves an unparseable transcript. The caller asks first.
    @discardableResult
    static func importBundle(
        at url: URL,
        intoProjectCwd targetProjectCwd: String,
        replaceExisting: Bool = false
    ) throws -> URL {
        let manifest = try readManifest(at: url)
        guard let provider = manifest.agentProvider else {
            throw BundleError.unknownProvider(manifest.provider)
        }
        let destination = try destinationURL(
            provider: provider, sessionId: manifest.sessionId, projectCwd: targetProjectCwd,
            // Codex names rollouts with a timestamp; reuse the EXISTING
            // file's name when one is already there, so a re-import
            // replaces that thread instead of littering a second rollout
            // for it on every attempt.
            existingCodexRollout: findCodexRollout(threadId: manifest.sessionId)
        )
        if FileManager.default.fileExists(atPath: destination.path), !replaceExisting {
            throw BundleError.alreadyExists(destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        guard let input = try? FileHandle(forReadingFrom: url) else { throw BundleError.unreadable }
        defer { try? input.close() }
        // Skip the manifest line, then copy the rest verbatim.
        guard let head = try input.read(upToCount: 64 * 1024),
              let newline = head.firstIndex(of: 0x0A)
        else { throw BundleError.notABundle }

        // Same staging discipline as export: a half-written import must
        // never replace a good local transcript.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).jsonl-partial")
        do {
            guard FileManager.default.createFile(atPath: staging.path, contents: nil),
                  let out = try? FileHandle(forWritingTo: staging)
            else { throw BundleError.unwritable }
            defer { try? out.close() }
            let remainderOfHead = head[head.index(after: newline)...]
            if !remainderOfHead.isEmpty { try out.write(contentsOf: remainderOfHead) }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        log.notice("imported session bundle → \(destination.path, privacy: .public)")
        return destination
    }

    /// Codex rollouts are filed by date, not by thread, so an existing one
    /// can only be found by the id embedded in its filename. Bounded: the
    /// tree is one directory per day (74 files / 7 directories here) and
    /// enumeration only stats, never reads.
    static func findCodexRollout(threadId: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix("-\(threadId).jsonl") {
            return url
        }
        return nil
    }

    /// Where a session's transcript belongs on THIS machine.
    ///
    /// Claude: ~/.claude/projects/<encoded target cwd>/<id>.jsonl.
    /// Codex: ~/.codex/sessions/<Y>/<M>/<D>/rollout-<stamp>-<id>.jsonl —
    /// filed by date and thread id rather than by path, so nothing about
    /// the working directory has to be rewritten for it.
    /// `existingCodexRollout`, when supplied, is reused verbatim so a
    /// re-import REPLACES that thread's rollout instead of writing a second
    /// one under a fresh timestamp every attempt.
    static func destinationURL(
        provider: V2AgentProvider, sessionId: String, projectCwd: String,
        now: Date = Date(), existingCodexRollout: URL? = nil
    ) throws -> URL {
        switch provider {
        case .claude:
            return SessionHistoryLoader.projectsRoot()
                .appendingPathComponent(SessionHistoryLoader.projectDirName(for: projectCwd))
                .appendingPathComponent(sessionId + ".jsonl")
        case .codex:
            if let existingCodexRollout { return existingCodexRollout }
            let home = FileManager.default.homeDirectoryForCurrentUser
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
            func pad(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
            let year = String(parts.year ?? 2026)
            let stamp = "\(year)-\(pad(parts.month))-\(pad(parts.day))T\(pad(parts.hour))-\(pad(parts.minute))-\(pad(parts.second))"
            return home
                .appendingPathComponent(".codex/sessions/\(year)/\(pad(parts.month))/\(pad(parts.day))")
                .appendingPathComponent("rollout-\(stamp)-\(sessionId).jsonl")
        }
    }

    /// A filename a person can recognise months later, without leaking the
    /// full path into it.
    static func suggestedFilename(for manifest: Manifest) -> String {
        let project = (manifest.projectCwd as NSString).lastPathComponent
        // "/" survives lastPathComponent and would put a path separator
        // into a FILENAME field.
        let safeProject = (project.isEmpty || project == "/") ? "session" : project
        let shortId = String(manifest.sessionId.prefix(8))
        return "\(safeProject)-\(shortId).\(fileExtension)"
    }
}

private extension JSONEncoder {
    static var bundleEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // Sorted keys keep a manifest diffable and its bytes reproducible.
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var bundleDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
