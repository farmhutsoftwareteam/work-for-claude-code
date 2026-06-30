# Atelier — Performance Standards

Atelier is a native macOS SwiftUI app wrapping Claude Code. The hot path is a
chat transcript that streams **token-by-token** while the rest of the window
stays mounted. Every performance problem we've hit traces to one of the rules
below — follow them when adding any view, especially anything that can render
during a live turn.

## The one mental model

A reply can emit **50–100 deltas/second**. So:

- Any work that runs **per delta** and is **O(message length)** becomes **O(n²)
  per reply**.
- Any view that **re-renders per delta** multiplies that cost across the whole
  screen.

Therefore: **keep the streaming path O(1) per delta, and keep per-token
re-renders scoped to the transcript.** Everything below is a corollary.

---

## Rules

### 1. The streaming path is O(1) per delta
- **Never** build the growing message with `existing + delta` (that's O(n²) over
  the reply). Accumulate in a buffer and commit via Swift's copy-on-write — see
  `StreamSession.appendStreamingText` / `commitStreamBuffer`.
- **Coalesce** high-frequency updates to ~30 fps; don't publish/re-render per
  token (`StreamSession` flush throttle, `streamFlushInterval`).
- **Cache** any parse/format keyed on text, so a stable prefix is free and only
  the growing tail re-computes — see the parse + chunk caches in
  `V2MarkdownText`. Any new text renderer (syntax highlighting, links, etc.)
  must cache the same way.

### 2. Observation scope — don't fan high-frequency changes out
- A high-frequency `@Published` (e.g. `transcript`) must only be observed by
  views that actually show it. The transcript and composer `@ObservedObject` the
  session directly; nothing else should.
- **Never** re-publish a child object's blanket `objectWillChange` into a
  window/parent `ObservableObject` — that wakes the whole tree on every token.
  Subscribe to specific **low-frequency** publishers instead. Pattern:
  `V2AppState.observeSessionState` (merges `$state/$model/$permissionMode/
  $mcpServers/$isRetrying` only).
- If a view needs only the slow-changing fields of a fast-changing object, split
  the object or pass plain values down.
- **Key** every Combine subscription so re-subscribing **replaces** (no
  duplicates), and **cancel on teardown** (no leaks): see
  `V2AppState.sessionStateSubs[tabId]` + the `close(tabId:)` cleanup.

### 3. Lists & scrolling
- Use `LazyVStack`/`LazyHStack`/`List` in any `ScrollView` over an unbounded
  collection (`V2LiveTranscript`). A plain `VStack` builds every row every time.
- **Stable identity.** No `UUID()` generated inside an `id`/`Identifiable.id`
  accessor. Don't allocate `Array(enumerated())` per render — iterate `indices`
  or give items stable ids.
- Auto-scroll signals must be **O(1)** (`StreamSession.streamTick`), never
  derived from content length (`s.count` on a streaming string is O(n)).

### 4. `body` and per-row closures allocate nothing expensive
- No `DateFormatter()`, `NSRegularExpression(...)`, JSON decode, `.sorted()`,
  dictionary builds, or heavy `.map` inside `body`, a computed view property, or
  a per-row function. Hoist to a `static let`, compute once, or cache.
- Build per-list lookups **once**, not per row (see `V2ProjectHome`'s `byId`
  map — it used to rebuild the whole dictionary for every visible row).

### 5. GeometryReader discipline
- No `GeometryReader` inside a repeated row or a per-token view — it forces a
  layout pass each time. Measure once at the container with `.onGeometryChange`
  / a `PreferenceKey` (see `V2WidthKey`), or size with frames.

### 6. NSViewRepresentable.updateNSView
- It runs on **every** SwiftUI update. Guard every setter behind an equality
  check so a per-token re-render doesn't dirty the view (see
  `V2ComposerTextView.updateNSView`).

### 7. Animation
- No `withAnimation` on per-token / high-frequency state. Animate **transitions**
  (a card appearing), not streams. An animated `scrollTo` per token stacks dozens
  of competing animations a second and stutters.

---

## How to measure (don't guess)

- **`let _ = Self._printChanges()`** as the first line of a `body` prints exactly
  which dependency caused the re-render. Use it to confirm a view is **not**
  waking on every token.
- Profile in **Release** config. Debug carries InjectionIII hot-reload +
  `-Xlinker -interposable` overhead that is not shipped, so Debug numbers lie.
- **Instruments** → the **SwiftUI** template (View Body counts, hangs) +
  **Time Profiler**. The tell-tale sign of a regression: a view's body-count
  climbing during a *single* stream.
- Optional: `os_signpost` around `StreamSession.handle(event:)` for per-turn cost.

---

## Pre-merge checklist (any new view or feature)

- [ ] Does it render during a live turn? If so, is per-delta cost O(1)?
      (`_printChanges` shows it isn't waking per token — or if it is, the work is
      trivial.)
- [ ] New `ObservableObject` wiring — does a fast-changing field fan out to
      unrelated views? Are subscriptions keyed + cancelled?
- [ ] `ScrollView` over a list → `Lazy*` + stable ids?
- [ ] Any `DateFormatter` / regex / `.sorted` / dict-build in a `body` or row?
      Hoisted or cached?
- [ ] Any `GeometryReader` in a row or hot view? Removed or moved to the
      container?
- [ ] New text/markdown rendering → cached by string?
- [ ] Profiled a long stream in **Release** — no body-count climb, no hangs?

---

## Reference: the audit that produced these

The October 2026 perf pass fixed, in order of blast radius:
1. O(n²) markdown re-parse/re-chunk per token → caches (`V2MarkdownText`).
2. Whole-window re-render per token via a child→parent `objectWillChange`
   re-publish, plus a subscription leak/duplication → scoped, keyed
   subscriptions (`V2AppState`).
3. O(n²) string concat + per-token publish in the stream source → buffered,
   ~30fps-coalesced commit (`StreamSession`); transcript → `LazyVStack`.
4. Bounded per-render waste (composer `updateNSView`, Project Home O(n²) dict,
   inline `DateFormatter`s).
