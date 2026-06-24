# Atelier design canvases

Source-of-truth design files for the v2 redesign. Each `.dc.html` was authored in [Claude Design](https://claude.ai/design) and exported via the `DesignSync` MCP tool. To render visually, open in claude.ai/design or paste into the project's design canvas — the `<x-dc>` / `<sc-if>` / `{{ … }}` syntax does not render in a regular browser.

## Project

| Field | Value |
|---|---|
| Project ID | `923827b0-a237-4193-9877-2bdedafe242a` |
| Project name | Atelier brand mark concept |
| Owner | Munya Makosa |
| URL | https://claude.ai/design/p/923827b0-a237-4193-9877-2bdedafe242a |

## Files

| File | Purpose | Maps to |
|---|---|---|
| `chat-states.dc.html` | The full chat surface: every state for transcript, tool widgets, permissions, composer, status. Light + dark themes. | Epic [#8](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/8) → Phase 3 issues [#17](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/17) – [#21](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/21) |

## Engineering note (not implemented, kept as reference)

The `Atelier engineering notes.dc.html` in the source project is the **architecture brief** behind the v2 redesign — it explains the two output modes, the wire protocol, Path A vs Path B, and the build order. It lives in the design project for context; the build plan it underpins is fully captured in Epic [#8](https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/8) and its sub-issues.

## How designs land here

1. Author / iterate in claude.ai/design.
2. Pull via the `DesignSync` MCP tool (`get_file` against this project).
3. Save the raw `.dc.html` under `design/` — preserves the source.
4. Map every state to acceptance criteria on the relevant GitHub issues so the design constraints survive even if someone reads only the issues.

Do not edit `.dc.html` files locally — they round-trip through claude.ai/design.
