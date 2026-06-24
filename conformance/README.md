# Atelier stream-json conformance

Captured `claude -p --output-format stream-json` NDJSON used to verify Atelier's parser doesn't regress when the binary's wire protocol evolves.

Anthropic does not commit to documenting the protocol ([#24612](https://github.com/anthropics/claude-code/issues/24612), [#24594](https://github.com/anthropics/claude-code/issues/24594)), so we test against captured fixtures from each supported version.

## Layout

```
conformance/
  fixtures/
    <version>/
      <scenario>.ndjson         ← captured stdout, one JSON object per line
```

`<version>` matches the `claude --version` major.minor.patch (e.g. `v2-1-187` — dashes used so the path is shell-safe).

`<scenario>` describes what the fixture covers (e.g. `happy-path`, `with-tool-use`, `permission-deny`).

## How fixtures are captured

`AtelierSpike` (the Phase 0 CLI in `AtelierSpike/main.swift`) spawns `claude` with the full Mode-B flag set and tees stdout to `/tmp/atelier-spike-out.ndjson`. Run it, observe the output, sanitize, drop the file under `conformance/fixtures/<version>/<scenario>.ndjson`.

Sanitization rules:
- Replace the user's home directory with `/Users/USER`
- Leave UUIDs, claude_code_version, model strings, plugin paths under `~/.claude/plugins/cache/` — these are stable / public
- If a fixture would capture a private project name, swap it for a placeholder

## Running locally

```
xcodebuild -scheme Work test -destination 'platform=macOS' -only-testing:WorkTests/ConformanceTests
```

## CI

`.github/workflows/ci.yml` runs the test target on every push to `main` and `v2-redesign`, and on every PR. The runner does not invoke `claude` itself — it only replays fixtures through the parser. Live-binary conformance is a runtime check inside the app (planned).

## Adding a new fixture

1. Run AtelierSpike to capture the scenario.
2. Sanitize per the rules above.
3. Drop the file under `conformance/fixtures/<version>/<descriptive-name>.ndjson`.
4. Write or extend a test in `Tests/WorkTests/ConformanceTests.swift` that asserts the shape this fixture exercises.
5. Commit both the fixture and the test.
