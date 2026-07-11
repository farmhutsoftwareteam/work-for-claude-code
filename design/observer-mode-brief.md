# Design brief — Observer mode

Companion to [#77](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/77). Engineering has shipped the engine and safety rails with interim chrome (commit `0717929`); this brief commissions the final visual design for the four surfaces below, same playbook as `Co-driven terminal.dc.html` (#59) and `Background tasks.dc.html` (#71).

## Why this matters

Atelier could only ever show you a session you started yourself. If you launch Claude from a terminal, from another machine, or from a tool other than Atelier, Atelier was blind to it — no transcript, no progress, nothing, even though the session is writing its history to disk right now. Observer mode tails that file live and reuses Atelier's entire event pipeline to render it, read-only. The remaining gap is visual: the interim chrome borrows vocabulary built for other states (background tasks, working tabs) and doesn't yet say "you are watching, not driving" on its own terms.

## The user

**Munya, catching a session mid-flight** — he kicked off a release script from his terminal 20 minutes ago, or a teammate's Claude session is running in a different app entirely. He opens Atelier's history rail, spots the one row that's actually happening right now (not just recent), clicks in, and needs three things instantly: this is live, this is not mine to type into, and — a beat later — whether it's still moving or went quiet while he was looking away.

## What exists today (interim chrome, real code — the floor this brief builds on)

**1. History rail row** — `Sources/V2/Chrome/V2HistoryRail.swift`
A session is "live" if its file grew in the last 120s and it isn't already open in a tab (`V2HistoryRail.swift:46-47`). Live rows swap the normal status dot + relative-time text for a `V2PulseDot` (7px, ink) + a bordered "live" chip (9pt mono, 0.5 kerning, 1px stroke). No transition when a row flips live→stale — it just silently reverts on the next render pass.

**2. Session tab chip** — `Sources/V2/Chrome/V2SessionTabs.swift`
There is no observer-specific tab status. `V2AppState.tabStatus` maps an observing session onto the existing four-state vocabulary (`enum V2TabStatus { idle, working, workingBackground, needsYou, doneUnseen }`): fresh (<90s since last file growth) → `.workingBackground` (the same calm/slow radar ring used for "a background task is still running while you're elsewhere" — 9px ring, 2.6s pulse, 0.32 opacity); stale → `.idle` (hollow ring, no motion). Visually indistinguishable from an actual background task you started.

**3. Composer replacement strip** — `Sources/V2/V2RootView.swift:274-303` (`observingStrip`)
Fresh (file grew <90s ago): `V2PulseDot` (6px, ink) + "observing — this session is running in another app" (11pt mono, `mute`). Stale: static dot (`line2` fill, no pulse) + "observing — went quiet Xm ago" (11pt mono, `faint`). Trailing "read-only" badge (9.5pt mono, 0.5 kerning, bordered). Sits where the composer normally lives, card background, 1px hairline top border, 16h/12v padding. This is the most-finished interim surface — it correctly replaces rather than disables the composer, but has exactly one static layout for both states (dot swaps, nothing else moves).

**4. Session header + transcript provenance** — `Sources/V2/Chrome/V2SessionHeader.swift`, `Sources/V2/Transcript/V2LiveTranscript.swift`
Neither file has any observer-mode branch at all. The header (dovetail mark, 19pt title, path/model subline, mode pill, dock switcher) renders identically to a live session you're driving — same controls visible, even though restart/send are gated off underneath. The transcript has zero "you're watching, not driving" signal once you scroll past the top strip. **This is the real gap** — surfaces 1–3 have a floor to redesign from; this one is designed from nothing.

## Existing system vocabulary to build with

- **Dovetail mark** (`V2DovetailMark`, `V2RootView.swift:437`) — the agent-presence glyph. Used at header scale (30px) and pulses at co-terminal scale (13px) to mean "the agent is actively reading/present here."
- **Radar ring family** (`V2SessionTabs.swift:223`) — working (9px, 1.8s, opacity 0.55) vs. the slow/background variant (2.6s, opacity 0.32, scale 2.3) = "present, not urgent." Observer mode currently borrows the slow variant; the brief should decide whether it deserves its own timing/weight or stays in this family on purpose.
- **Valence pair** — sage (`add`: `#3f6f57` light / `#7fb89a` dark) = done/healthy, clay (`del`: `#9c5249` light / `#d39189` dark) = needs-you/failed. Observer mode is neither — deliberately avoid both; it's a third, neutral state.
- **Chip/token language** — bordered mono labels at 9–10pt with ~0.5 kerning (`tok` bg `#dde0db`/`#333532`) for inline metadata (the "live" and "read-only" chips already use this).
- **Type + palette** — IBM Plex Mono for all chip/meta/mono text, system sans for titles, 1px hairlines at `line` (`black/white @ 14–16%`) and `line2` (`@ 26–30%`) for structure, `faint`/`mute` (`@ 38–40%` / `54–56%`) for de-emphasized text. Light + dark both required.

## Deliverable

`Observer mode.dc.html` in the Atelier design project — all four surfaces below, all states, both palettes, try-it controls to step through them.

## Paste-ready brief for the designer agent

```
DESIGN BRIEF — "Observer mode.dc.html" (Atelier design system project)

WHAT IT IS
A read-only live view of a Claude Code session that something OTHER than
this Atelier tab owns — started from a terminal, another machine, another
app. Atelier tails the session's history file and renders it through the
same transcript pipeline as a normal chat, but nothing you do in this tab
can reach the real session: no composer, no restart, no resume. The
design's job: at every zoom level (rail row, tab, strip, transcript),
make "this is live" and "you cannot drive this" both unmistakable, and
distinguish "live and fresh" from "live but gone quiet" without alarming
the user — going quiet is normal (the agent is thinking, or the owning
app is just idle), not an error.

CONVENTIONS
Same system as Tab states / Agent vocabulary / Background tasks: IBM Plex
Mono + system sans, 1px hairline structure, sage/clay valence RESERVED for
done/needs-you (do not reuse for observer states — this is a third,
neutral mode). Light + dark themeVars. Reuse existing primitives (pulse
dot, radar ring, dovetail mark, bordered mono chip) rather than inventing
new ones unless a surface genuinely needs it.

SURFACE 1 — HISTORY RAIL LIVE BADGE (row width ~280px)
Today: pulse dot + "live" chip replaces the dot + relative-time text.
Design: the resting (non-live) row, the live row, AND the live→stale
transition (a row that was live 10 seconds ago going quiet while visible
in the list — should it hold the live look briefly, cross-fade, or snap?
no layout jolt either way).

SURFACE 2 — TAB CHIP (52px tall, ~128px title column)
Today: observer tabs borrow the "background task" ring, indistinguishable
from a tab where YOU started something that's still running elsewhere.
Design: a fifth tab status, "observing," visually related to but distinct
from working/workingBackground/needsYou/doneUnseen — fresh and gone-quiet
variants. Should read as calm and neutral, never competing with a tab
that's actually replying to you right now.

SURFACE 3 — COMPOSER REPLACEMENT STRIP (full width, ~50px tall)
Today: one line of copy + a pulse dot + a "read-only" chip, static layout,
dot swaps between pulsing/still for fresh/stale. Design: fresh state,
gone-quiet state (with elapsed "went quiet Xm ago"), and make the
transition between them feel like a state change, not a random dot
flicker. This is the surface most likely to be stared at for minutes —
it must stay quiet and legible at a glance, not demand attention.

SURFACE 4 — SESSION HEADER + TRANSCRIPT PROVENANCE (no existing design)
Header: currently identical whether you're driving or observing. Design
what changes — does the dovetail mark itself communicate it, does the
path subline gain an "observing" chip, do the mode pill / dock switcher
/ running pill need to visually deactivate? Transcript: a subtle,
PERSISTENT cue while scrolled anywhere in the conversation that this is
someone else's session (header-only badge? edge tint? watermark?) —
must not compete with or degrade message readability at any scroll
position, including deep in a long transcript with no header in view.

STATES TO DESIGN (per surface, as applicable)
1. Fresh / actively growing (file wrote in the last ~90s).
2. Gone quiet (stale but not ended — the common case; agent thinking,
   or the owning process is just idle between turns).
3. Ended (the observed session's process exited — still viewable, but
   no longer "live" in any sense).
4. Not found (the session file never existed or was deleted mid-watch —
   see adversarial states below).

DEMO CONTROLS
Buttons: fresh / gone quiet / ended / not found, per surface where it
applies. Theme toggle.

NAME IT: Observer mode.dc.html
```

## Adversarial states to design for

- **Goes quiet mid-thought.** The common case, not an error — the copy and visual weight must stay calm (see "gone quiet" throughout, not "disconnected" or a warning color).
- **Observed file disappears.** The session was cleaned up (deleted, moved) while being watched. Today the engine has no explicit handling for this — worth a "this session is no longer available" empty/end state distinct from "gone quiet."
- **Session never existed / not found.** If the session ID Atelier tries to watch has no history file at all (e.g. a stale link, a typo'd ID), today the observer tab silently sits empty forever with no signal. Needs a "couldn't find this session" state — this is currently a real gap, not just an edge case to future-proof.
- **Opened as observer in two windows/tabs at once.** Should both just work identically (each tails independently) — confirm the design doesn't imply any kind of exclusivity or locking between them.
- **A session you're already driving live in one tab shows up in the history rail.** Today it's simply excluded from the "live" badge (no explanation). Designer's call whether that's sufficient or deserves its own "open in another tab" treatment.

## Out of scope

- Any control that lets an observer tab become a driving tab (no "take over" affordance — that's a deliberate product decision, not a design gap).
- The discovery *mechanism* (how Atelier decides a session is live) — that's engine work (#74/#75), not visual design.
- Cross-window/cross-machine session listing — observer mode only watches sessions Atelier can already see in this machine's history.
