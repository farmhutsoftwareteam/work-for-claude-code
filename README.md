# Work

**The native macOS companion app for [Claude Code](https://www.anthropic.com/claude-code).**

Six live Claude sessions in one window. Embedded terminals with real PTYs. A polished UI for MCPs, skills, plugins, and usage analytics — all the things Claude Code can do, surfaced where you can see them.

[Download for macOS →](https://work.munyamakosa.com)
[Read the latest release notes →](https://work.munyamakosa.com/releases.html)

---

## What it does

- **Tabbed Claude sessions** — run multiple Claude Code sessions side-by-side in one window. Each tab is a real PTY hosting a real `claude` process, not a subprocess wrapper. Drag to reorder. Cmd+1–9 to switch.
- **MCPs tab** — every MCP feature Claude Code exposes, with a UI: three real scopes (User / Local / Project), HTTP headers + Bearer-token masking, OAuth fields, `alwaysLoad` toggle, per-server timeouts, `${VAR}` env expansion. Matches what Claude Code's docs describe; saves you from hand-editing `~/.claude.json`.
- **Skills tab** — browse personal, project, and plugin skills with full SKILL.md preview. See which copy actually wins when a name exists at multiple scopes. Create, clone, toggle auto-invoke.
- **Marketplace tab** — browse plugin marketplaces, install/update/uninstall plugins.
- **Usage tab** — GitHub-style daily heatmap, week/month/year views, today vs yesterday delta, K/M/B/T token formatting.
- **Restart session** — in-place SIGTERM + respawn so a Claude session picks up newly-added MCPs / hooks / skills without leaving the terminal.
- **Sparkle auto-update** — signed, notarized, EdDSA-verified releases shipped silently in the background.

## Install

Download the latest signed + notarized DMG from **[work.munyamakosa.com](https://work.munyamakosa.com)** and drag Work.app to /Applications.

That's it. No Homebrew tap (yet), no extra setup. The app uses Sparkle for auto-updates — once installed, new versions land silently and the badge flips to "Relaunch to update" when ready.

## Build from source

Requirements:
- macOS 15.0+
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
git clone https://github.com/farmhutsoftwareteam/work-for-claude-code
cd work-for-claude-code
xcodegen generate
open Work.xcodeproj
```

Build & run in Xcode (⌘R). For a release build matching the published DMG, run `./release.sh <version>` — but note that requires your own Apple Developer ID, signing identity, and a configured `notarytool` keychain profile (see `NOTARIZATION-INSTRUCTIONS.md`).

## Project layout

```
Sources/                  All Swift source (~45 files)
├── Store.swift           Single source of truth — parses ~/.claude/, watches for changes
├── ContentView.swift     Root SwiftUI scene + tab routing
├── ExtensionsView.swift  MCPs/Skills/Marketplace tabs
├── TerminalsController.swift
│                         Owns all embedded SwiftTerm PTYs, idle/busy detection, tab lifecycle
├── MCPEditor.swift       The MCP add/edit sheet
├── MCPConfigWriter.swift NSFileCoordinator-protected writer for ~/.claude.json + .mcp.json
├── UsageView.swift       Heatmap + activity charts
└── …
project.yml               xcodegen project descriptor
Work.entitlements         Sandbox-off + AppleEvents-on entitlements
release.sh                Build → sign → DMG → notarize → staple pipeline
docs/                     Marketing + distribution site (deployed to work.munyamakosa.com)
├── index.html
├── appcast.xml           Sparkle feed
├── releases.html         Auto-generated from appcast.xml
└── …
scripts/build-releases.js Regenerates releases.html from appcast.xml
recipes/                  Marketplace recipes for one-click MCP installs
resources/                Icons, DMG background, etc.
```

## How Work talks to Claude Code

Work never re-implements anything Claude Code already does. It's a UI layer over Claude Code's existing files:

- Reads `~/.claude/projects/<cwd-hash>/*.jsonl` for session history + token counts
- Reads `~/.claude.json` (top-level + `projects.<cwd>.mcpServers`) for user/local MCPs
- Reads `<cwd>/.mcp.json` for project-scoped MCPs
- Reads `~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/plugins/` for skills/agents/plugins
- Spawns `claude` / `claude --resume` / `claude --continue` via embedded SwiftTerm PTYs
- Writes back to `~/.claude.json` and `.mcp.json` through `NSFileCoordinator` so the CLI and the app cooperate cleanly

When Claude Code's data model changes, Work follows. There is no proprietary database, no cloud service, no telemetry.

## Architecture notes

- **SwiftUI + AppKit hybrid.** The embedded terminal is a `LocalProcessTerminalView` from [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) wrapped in `NSViewRepresentable`. Everything else is pure SwiftUI.
- **No tests** at the moment. The codebase is small enough that the dogfood loop (every change ships through a live release) catches regressions quickly. Contributions to add an XCTest target are welcome.
- **Self-relocates to /Applications.** First-launch from any location outside /Applications triggers an offer to move + relaunch — Sparkle can't update an app running from a translocated quarantine path, and this avoids the "Work can't be updated" trap.
- **No CI yet.** Releases are built locally on the maintainer's machine because they require an Apple Developer ID signing identity. CI signing is on the roadmap.

## Contributing

PRs welcome. Some ground rules:

- **One feature per PR.** Easier to review, easier to revert if it ships a bug.
- **No new dependencies without discussion.** The dependency surface today is intentionally tiny: SwiftTerm, Sparkle, swift-markdown-ui.
- **Match the existing voice in copy.** Buttons, tooltips, and release-notes copy in this repo follow a deliberate plain-English style (no "Awesome!", no emoji, no marketing fluff). Read a few existing sheets before writing new copy.
- **No code-signed builds in PRs.** The signing identity is the maintainer's. Submit unsigned changes; the maintainer signs the release build.

If you find a bug: open an issue with the symptom, your macOS version, and (if possible) the steps to reproduce. The [bug-hunt skill](https://github.com/farmhutsoftwareteam/lead-eng) plays well with this repo if you want to triage in your own Claude session before filing.

## What this is not

- **Not affiliated with Anthropic.** Work is a third-party companion app. Claude Code is a separate product made by Anthropic.
- **Not a Claude Code replacement.** It runs Claude Code; you still need `claude` installed (Work helps you find / install it if missing).
- **Not a chat interface.** There's no Work-owned chat — every conversation lives in a real Claude Code session in a real PTY.

## License

MIT — see [LICENSE](./LICENSE).

## Author

Built by [Munyaradzi Makosa](https://github.com/munyamakosa) in public. Issues and PRs at the [issues page](../../issues).
