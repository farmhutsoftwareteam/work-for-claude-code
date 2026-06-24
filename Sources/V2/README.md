# Atelier v2 (Mode-B chat UI)

Everything under `Sources/V2/` belongs to the v2 redesign — the native chat UI driven off Claude Code's `stream-json` protocol. Tracked under [epic #8](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/8) on the `v2-redesign` branch.

## What's here so far

- `V2Theme.swift` — color palette tokens (light + dark), exposed via `@Environment(\.v2)`.
- `V2RootView.swift` — the three-column window root with placeholders for each region.

## How to see it running

The v2 window only appears in **DEBUG builds** (so production v1 users never see it).

```bash
# from repo root
xcodegen generate
xcodebuild -scheme Work -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Work-*/Build/Products/Debug/Atelier.app
```

In the running app: **Window → Atelier v2 (preview)** opens the new window.

## Hot reload (Inject)

Every view in `V2/` is wired with `@ObserveInjection` + `.enableInjection()`. To see edits live without rebuilding:

1. Install [InjectionIII](https://github.com/krzysztofzablocki/Inject) (download the .app or via brew).
2. Launch InjectionIII — it sits in the menu bar.
3. Run the v2 window once. From then on, editing any view file under `Sources/V2/` updates the running window in ~100ms — no rebuild, no relaunch, session state preserved.

Without InjectionIII running, `.enableInjection()` is a harmless no-op.

## Design source of truth

- `design/app-shell.dc.html` — three-column window IA.
- `design/chat-states.dc.html` — every chat state inside the main column.

Don't deviate from the design tokens in `V2Theme.swift`. If the design changes, update the palette there once, every view reflects automatically.
