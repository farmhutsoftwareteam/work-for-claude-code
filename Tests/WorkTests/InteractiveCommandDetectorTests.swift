// Table-driven coverage for the Bash-gate classifier (#57). Grounded in the
// seed list + overrides in InteractiveCommandDetector.swift — every case here
// should map 1:1 to an acceptance-criteria example from the issue.

import XCTest
@testable import Work

final class InteractiveCommandDetectorTests: XCTestCase {

    // MARK: - Flagged (should offer co-driven)

    func test_flaggedCommands() {
        let commands = [
            "eas submit -p ios",
            "eas build --platform ios",
            "eas login",
            "eas credentials",
            "npx testflight",
            "bunx fastlane beta",
            "npm login",
            "npm adduser",
            "npm init",
            "yarn login",
            "pnpm login",
            "gh auth login",
            "vercel login",
            "vercel link",
            "firebase login",
            "firebase init",
            "aws configure",
            "docker login",
            "gcloud auth login",
            "gcloud init",
            "heroku login",
            "netlify login",
            "netlify init",
            "supabase login",
            "git rebase -i HEAD~3",
            "git add -i",
            "git add -p",
            "wrangler login",
            "stripe login",
            "flyctl auth login",
            "fly auth login",
            "ssh user@host",
            "ssh -p 2222 user@host",
        ]
        for cmd in commands {
            XCTAssertTrue(InteractiveCommandDetector.looksInteractive(cmd), "expected flagged: \(cmd)")
        }
    }

    // MARK: - Generic trailing-verb heuristic

    func test_genericTrailingVerbs() {
        let commands = [
            "some-cli login",
            "some-cli init",
            "some-cli configure",
            "some-cli adduser",
        ]
        for cmd in commands {
            XCTAssertTrue(InteractiveCommandDetector.looksInteractive(cmd), "expected flagged: \(cmd)")
        }
    }

    // MARK: - Overrides win outright, even over a seed match

    func test_nonInteractiveOverrides() {
        let commands = [
            "eas submit -p ios --non-interactive",
            "npm init --yes",
            "npm init -y",
            "aws configure --no-input",
            "gh auth login CI=1",
            "gh auth login CI=true",
            "some-cli login -y",
            "git rebase -i HEAD~3 --no-input",
        ]
        for cmd in commands {
            XCTAssertFalse(InteractiveCommandDetector.looksInteractive(cmd), "expected NOT flagged: \(cmd)")
        }
    }

    // MARK: - ssh explicitly batched

    func test_sshBatchModeNotFlagged() {
        XCTAssertFalse(InteractiveCommandDetector.looksInteractive("ssh -o BatchMode=yes user@host --non-interactive"))
    }

    // MARK: - Ordinary commands

    func test_ordinaryCommandsNotFlagged() {
        let commands = [
            "ls -la",
            "cat package.json",
            "npm run build",
            "npm test",
            "git status",
            "git commit -m \"fix\"",
            "swift build",
            "curl https://example.com",
            "echo hello",
        ]
        for cmd in commands {
            XCTAssertFalse(InteractiveCommandDetector.looksInteractive(cmd), "expected NOT flagged: \(cmd)")
        }
    }

    // MARK: - Steering message

    func test_steeringMessage_namesToolAndEchoesCommand() {
        let command = "eas submit -p ios"
        let msg = InteractiveCommandDetector.steering(command: command)
        XCTAssertTrue(msg.contains("mcp__atelier-terminal__terminal_run"), "must name the exact tool")
        XCTAssertTrue(msg.contains(command), "must echo the original command")
        XCTAssertTrue(msg.lowercased().contains("do not retry"), "must forbid a Bash retry")
    }

    func test_steeringMessage_escapesQuotesInCommand() {
        let command = "echo \"hi\""
        let msg = InteractiveCommandDetector.steering(command: command)
        XCTAssertTrue(msg.contains("\\\"hi\\\""), "command with quotes must be JSON-escaped in the embedded payload")
    }
}
