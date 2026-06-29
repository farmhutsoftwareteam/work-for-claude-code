// Git integration for the project-home Changes tab. No library — we shell out
// to `git` in the project's directory, exactly like the app already spawns
// `claude`. Read-only status/diff plus the explicit user actions stage,
// unstage, and commit. (Destructive ops like discard are intentionally left
// out of v1 until there's a confirm flow.)

import Foundation

// MARK: - Models

struct GitFile: Identifiable, Equatable, Sendable {
    let path: String
    let staged: Bool        // which section it belongs to
    let status: String      // single-char index/worktree code: M A D R ? …
    let untracked: Bool
    var added: Int = 0
    var deleted: Int = 0
    var id: String { (staged ? "S:" : "U:") + path }
}

struct GitStatus: Sendable {
    var branch: String
    var upstream: String?
    var ahead: Int
    var behind: Int
    var staged: [GitFile]
    var unstaged: [GitFile]
    var changeCount: Int { staged.count + unstaged.count }
}

enum DiffLineKind: Sendable { case context, add, del, hunk }

struct DiffLine: Identifiable, Sendable {
    let id: Int
    let kind: DiffLineKind
    let text: String
}

// MARK: - Service

enum V2Git {

    private static let gitPath = "/usr/bin/git"

    /// Run a git command in `cwd`. Returns (stdout, exitCode). Off the main
    /// thread; reads the pipe to EOF before waiting so large diffs can't
    /// deadlock on a full pipe buffer.
    static func run(_ args: [String], cwd: String) async -> (out: String, err: String, code: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.isExecutableFile(atPath: gitPath) else {
                    cont.resume(returning: ("", "git not found", 127)); return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: gitPath)
                p.arguments = ["-C", cwd] + args
                let outPipe = Pipe(); let errPipe = Pipe()
                p.standardOutput = outPipe; p.standardError = errPipe
                do { try p.run() } catch { cont.resume(returning: ("", "couldn't launch git", 127)); return }
                // Drain BOTH pipes concurrently. Reading only stdout to EOF can
                // deadlock if git fills the ~64KB stderr buffer first (e.g. a
                // repo emitting per-file warnings) — it blocks writing stderr,
                // never exits, never EOFs stdout.
                let group = DispatchGroup()
                var outData = Data(); var errData = Data()
                group.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    p.terminationStatus
                ))
            }
        }
    }

    /// True if `cwd` is inside a git work tree.
    static func isRepo(cwd: String) async -> Bool {
        let r = await run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return r.code == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Full working-tree status: branch, ahead/behind, staged + unstaged files
    /// with per-file line counts.
    static func status(cwd: String) async -> GitStatus? {
        let r = await run(["status", "--porcelain", "-b", "-uall"], cwd: cwd)
        guard r.code == 0 else { return nil }

        var branch = "—", upstream: String?, ahead = 0, behind = 0
        var staged: [GitFile] = [], unstaged: [GitFile] = []

        for raw in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                (branch, upstream, ahead, behind) = parseBranch(String(line.dropFirst(3)))
                continue
            }
            guard line.count >= 3 else { continue }
            let chars = Array(line)
            let x = String(chars[0])   // index (staged)
            let y = String(chars[1])   // worktree (unstaged)
            var path = String(line.dropFirst(3))
            // Only rename/copy lines carry "old -> new"; don't split a file
            // literally named "a -> b".
            if (x == "R" || x == "C" || y == "R" || y == "C"),
               let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }

            if x == "?" && y == "?" {
                unstaged.append(GitFile(path: path, staged: false, status: "?", untracked: true))
                continue
            }
            if x != " " && x != "?" {
                staged.append(GitFile(path: path, staged: true, status: x, untracked: false))
            }
            if y != " " && y != "?" {
                unstaged.append(GitFile(path: path, staged: false, status: y, untracked: false))
            }
        }

        let stagedCounts = await numstat(cwd: cwd, cached: true)
        let unstagedCounts = await numstat(cwd: cwd, cached: false)
        staged = staged.map { var f = $0; if let c = stagedCounts[f.path] { f.added = c.0; f.deleted = c.1 }; return f }
        unstaged = unstaged.map { var f = $0; if let c = unstagedCounts[f.path] { f.added = c.0; f.deleted = c.1 }; return f }

        return GitStatus(branch: branch, upstream: upstream, ahead: ahead, behind: behind,
                         staged: staged, unstaged: unstaged)
    }

    private static func parseBranch(_ s: String) -> (String, String?, Int, Int) {
        // "main...origin/main [ahead 2, behind 1]"  |  "main"  |  "HEAD (no branch)"
        var branch = s, upstream: String?, ahead = 0, behind = 0
        if let bracket = branch.range(of: " [") {
            let inside = branch[bracket.upperBound...].dropLast()  // "ahead 2, behind 1]"
            for part in inside.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ahead ") { ahead = Int(t.dropFirst(6)) ?? 0 }
                if t.hasPrefix("behind ") { behind = Int(t.dropFirst(7)) ?? 0 }
            }
            branch = String(branch[..<bracket.lowerBound])
        }
        if let sep = branch.range(of: "...") {
            upstream = String(branch[sep.upperBound...])
            branch = String(branch[..<sep.lowerBound])
        }
        return (branch, upstream, ahead, behind)
    }

    /// path → (added, deleted) from `git diff [--cached] --numstat`.
    private static func numstat(cwd: String, cached: Bool) async -> [String: (Int, Int)] {
        var args = ["diff", "--numstat"]
        if cached { args.insert("--cached", at: 1) }
        let r = await run(args, cwd: cwd)
        var map: [String: (Int, Int)] = [:]
        for line in r.out.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2)
            guard cols.count == 3 else { continue }
            map[String(cols[2])] = (Int(cols[0]) ?? 0, Int(cols[1]) ?? 0)
        }
        return map
    }

    /// Parsed unified diff for one file.
    static func diff(cwd: String, path: String, staged: Bool, untracked: Bool) async -> [DiffLine] {
        let args: [String]
        if untracked {
            args = ["diff", "--no-index", "--", "/dev/null", path]   // exits 1 with output
        } else if staged {
            args = ["diff", "--cached", "--", path]
        } else {
            args = ["diff", "--", path]
        }
        let r = await run(args, cwd: cwd)
        var lines: [DiffLine] = []
        var i = 0
        for raw in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git") || line.hasPrefix("index ")
                || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("similarity") || line.hasPrefix("rename ")
                || line.hasPrefix("\\ No newline") { continue }
            let kind: DiffLineKind
            if line.hasPrefix("@@") { kind = .hunk }
            else if line.hasPrefix("+") { kind = .add }
            else if line.hasPrefix("-") { kind = .del }
            else { kind = .context }
            lines.append(DiffLine(id: i, kind: kind, text: line))
            i += 1
        }
        return lines
    }

    // MARK: - Mutations (explicit user actions only)

    /// Clone `url` into `parent`/`name`. `parent` must exist. Captures stderr
    /// (git writes progress + errors there). Returns the cloned path on
    /// success, or an error message.
    static func clone(url: String, into parent: String, name: String, branch: String?) async -> (path: String?, error: String?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                var args = ["-C", parent, "clone"]
                if let branch, !branch.isEmpty { args += ["--branch", branch] }
                args += [url, name]
                let p = Process()
                p.executableURL = URL(fileURLWithPath: gitPath)
                p.arguments = args
                let err = Pipe()
                p.standardError = err
                p.standardOutput = Pipe()
                do { try p.run() } catch { cont.resume(returning: (nil, "couldn't launch git")); return }
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: (parent + "/" + name, nil))
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").last
                    cont.resume(returning: (nil, msg?.isEmpty == false ? msg : "git clone failed"))
                }
            }
        }
    }

    static func stage(cwd: String, path: String) async {
        _ = await run(["add", "--", path], cwd: cwd)
    }
    static func unstage(cwd: String, path: String) async {
        _ = await run(["restore", "--staged", "--", path], cwd: cwd)
    }
    @discardableResult
    static func commit(cwd: String, message: String) async -> (ok: Bool, output: String) {
        let r = await run(["commit", "-m", message], cwd: cwd)
        // On failure surface stderr (hook output, GPG errors) — git puts the
        // reason there, and stdout is usually empty.
        let detail = r.code == 0 ? r.out : (r.err.isEmpty ? r.out : r.err)
        return (r.code == 0, detail)
    }

    /// Draft a commit message by running `claude -p` over the staged diff.
    /// One-shot text generation — no session, no tools. Returns nil on any
    /// failure so the caller can surface a friendly error.
    static func generateCommitMessage(claudeBinary: URL, diff: String) async -> String? {
        let capped = diff.count > 8000 ? String(diff.prefix(8000)) + "\n… (diff truncated)" : diff
        let prompt = """
        Write a git commit message for the staged diff below. Conventional-commits style: a concise `type: summary` subject under 72 characters (types: feat, fix, refactor, docs, test, chore, style, perf), with a short body only if it genuinely helps. Output ONLY the commit message — no preamble, no surrounding quotes or backticks.

        Staged diff:

        \(capped)
        """
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = claudeBinary
                p.arguments = ["-p", prompt, "--output-format", "text"]
                // Clear the nested-session guard vars just in case the app was
                // launched from inside a claude session.
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE") {
                    env.removeValue(forKey: k)
                }
                p.environment = env
                let out = Pipe(); let errPipe = Pipe()
                p.standardOutput = out
                p.standardError = errPipe
                do { try p.run() } catch { cont.resume(returning: nil); return }
                // Drain both pipes concurrently so a chatty stderr can't
                // deadlock the stdout read.
                let group = DispatchGroup()
                var data = Data()
                group.enter(); DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { _ = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                p.waitUntilExit()
                var s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip wrapping backticks/quotes if the model added them.
                if let t = s {
                    s = t.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' \n"))
                }
                cont.resume(returning: (p.terminationStatus == 0 && !(s?.isEmpty ?? true)) ? s : nil)
            }
        }
    }
}
