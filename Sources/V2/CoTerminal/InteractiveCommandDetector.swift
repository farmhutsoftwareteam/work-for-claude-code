// Heuristic classifier for "this Bash command will ask questions" (#57), used
// by the permission gate to offer Run co-driven. Deliberately cheap and
// list-based: a false positive costs nothing (Approve is still one click), a
// false negative costs one hung Bash call the user can interrupt.
//
// Grow the seed list freely — one entry per line, tested table-driven.

import Foundation

enum InteractiveCommandDetector {

    /// True when `command` is likely to prompt for input on a TTY.
    static func looksInteractive(_ command: String) -> Bool {
        let lower = command.lowercased()

        // Explicit non-interactive intent wins outright.
        let overrides = ["--non-interactive", "--no-input", "--yes", " -y ", "ci=1", "ci=true", "batchmode=yes"]
        for o in overrides where lower.contains(o) { return false }
        if lower.hasSuffix(" -y") { return false }

        // Seed patterns — substring match against the whole command line so
        // `npx testflight`, `bunx fastlane` etc. hit without first-token games.
        let seeds = [
            "eas submit", "eas build", "eas login", "eas credentials",
            "npx testflight", "testflight",
            "fastlane",
            "npm login", "npm adduser", "npm init",
            "yarn login", "pnpm login",
            "gh auth login",
            "vercel login", "vercel link",
            "firebase login", "firebase init",
            "aws configure",
            "docker login",
            "gcloud auth login", "gcloud init",
            "heroku login",
            "netlify login", "netlify init",
            "supabase login",
            "git rebase -i", "git add -i", "git add -p",
            "wrangler login",
            "stripe login",
            "flyctl auth", "fly auth",
        ]
        for s in seeds where lower.contains(s) { return true }

        // ssh is interactive unless explicitly batched (handled by override above).
        if lower.hasPrefix("ssh ") || lower.contains(" ssh ") { return true }

        // Generic trailing verbs that almost always prompt.
        let firstSegment = lower.split(separator: "|").first.map(String.init) ?? lower
        for verb in [" login", " init", " configure", " adduser"] where firstSegment.hasSuffix(verb) { return true }

        return false
    }

    /// The deny-with-message steering text — prompt engineering, keep precise:
    /// names the exact tool, echoes the command, forbids a Bash retry.
    static func steering(command: String) -> String {
        """
        This command is interactive — it will ask questions on a TTY, and Bash has no TTY, so it would hang. Do NOT retry it with Bash. \
        Run it with the mcp__atelier-terminal__terminal_run tool instead: {"command": \(jsonEscape(command))}. \
        Then loop terminal_read (pass since_cursor) to watch output, answer routine prompts with terminal_write, and ask the user in chat for anything you can't answer yourself. \
        If terminal_read reports secure_input=true, tell the user to type directly in the terminal pane — never attempt to enter secrets.
        """
    }

    private static func jsonEscape(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: d, encoding: .utf8),
              arr.count >= 4 else { return "\"\(s)\"" }
        return String(arr.dropFirst().dropLast())   // strip [ ]
    }
}
