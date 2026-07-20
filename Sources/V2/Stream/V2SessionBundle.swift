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

    struct Manifest: Codable, Equatable {
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
        case notABundle
        case unsupportedVersion(Int)
        case unknownProvider(String)
        case sourceMissing(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file couldn't be read."
            case .notABundle:
                return "That isn't an Atelier session file."
            case .unsupportedVersion(let v):
                return "That session file was written by a newer Atelier (format \(v)). Update Atelier to open it."
            case .unknownProvider(let p):
                return "That session is for \"\(p)\", which this version of Atelier doesn't know how to import."
            case .sourceMissing(let path):
                return "The transcript for this session is no longer on disk (\(path)). Claude removes transcripts after 30 days by default."
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

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else { throw BundleError.unreadable }
        defer { try? out.close() }
        try out.write(contentsOf: header)

        // Chunked copy so a 70MB transcript never lands in memory whole.
        guard let input = try? FileHandle(forReadingFrom: source) else { throw BundleError.unreadable }
        defer { try? input.close() }
        var lines = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
            lines += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        log.notice("exported session bundle: \(lines) lines")
        return lines
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
    @discardableResult
    static func importBundle(at url: URL, intoProjectCwd targetProjectCwd: String) throws -> URL {
        let manifest = try readManifest(at: url)
        guard let provider = manifest.agentProvider else {
            throw BundleError.unknownProvider(manifest.provider)
        }
        let destination = try destinationURL(
            provider: provider, sessionId: manifest.sessionId, projectCwd: targetProjectCwd
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        guard let input = try? FileHandle(forReadingFrom: url) else { throw BundleError.unreadable }
        defer { try? input.close() }
        // Skip the manifest line, then copy the rest verbatim.
        guard let head = try input.read(upToCount: 64 * 1024),
              let newline = head.firstIndex(of: 0x0A)
        else { throw BundleError.notABundle }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else { throw BundleError.unreadable }
        defer { try? out.close() }
        let remainderOfHead = head[head.index(after: newline)...]
        if !remainderOfHead.isEmpty { try out.write(contentsOf: remainderOfHead) }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        log.notice("imported session bundle → \(destination.path, privacy: .public)")
        return destination
    }

    /// Where a session's transcript belongs on THIS machine.
    ///
    /// Claude: ~/.claude/projects/<encoded target cwd>/<id>.jsonl.
    /// Codex: ~/.codex/sessions/<Y>/<M>/<D>/rollout-<stamp>-<id>.jsonl —
    /// filed by date and thread id rather than by path, so nothing about
    /// the working directory has to be rewritten for it.
    static func destinationURL(
        provider: V2AgentProvider, sessionId: String, projectCwd: String,
        now: Date = Date()
    ) throws -> URL {
        switch provider {
        case .claude:
            return SessionHistoryLoader.projectsRoot()
                .appendingPathComponent(SessionHistoryLoader.projectDirName(for: projectCwd))
                .appendingPathComponent(sessionId + ".jsonl")
        case .codex:
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
        let safeProject = project.isEmpty ? "session" : project
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
