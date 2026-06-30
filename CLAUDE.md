# Atelier — project guide

Native macOS SwiftUI app wrapping Claude Code. Build/run the dev app:
`xcodebuild -scheme Work -configuration Debug build`. Adding a new source file
requires `xcodegen generate` (the `.xcodeproj` is gitignored, regenerated from
`project.yml`).

## Performance — must follow (full detail + checklist in PERFORMANCE.md)

The hot path is a transcript that streams 50–100 tokens/sec while the window
stays mounted. Per-delta O(message-length) work → O(n²) per reply; a view that
re-renders per delta multiplies it across the screen. So:

1. **Streaming path is O(1) per delta** — never `existing + delta`; buffer +
   COW-commit, coalesce to ~30fps, cache any text parse/format by string.
2. **Don't fan out high-frequency `@Published`** — never re-publish a child's
   blanket `objectWillChange` into a parent/window object; subscribe to specific
   low-frequency publishers (`$state`, …). Key subscriptions; cancel on teardown.
3. **Lazy lists + stable ids** in any ScrollView over an unbounded collection;
   O(1) scroll signals.
4. **No `DateFormatter()`/regex/`.sorted`/dict-build in `body` or per-row** —
   hoist/cache. Build per-list lookups once, not per row.
5. **No `GeometryReader` in repeated rows / per-token views** — measure once at
   the container.
6. **`updateNSView`** — guard every setter behind an equality check.
7. **No `withAnimation` on per-token state.**

Verify with `let _ = Self._printChanges()` in a body, and profile a long stream
in **Release** (Debug carries Injection/-interposable overhead). Run the
PERFORMANCE.md pre-merge checklist for any new view that can render during a turn.
