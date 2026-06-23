---
title: "Welcome to Atelier"
slug: welcome-to-atelier
type: announcement
description: We renamed the app, redesigned the website, and committed to a sharper direction. Here's why - and what comes next.
seoTitle: "Welcome to Atelier - a workshop for Claude Code"
metaDescription: "Work is now Atelier - a native Mac workshop for Claude Code. Six live sessions in one window, real UI for MCPs, and a directional bet on loops, agents, and harnesses."
date: 2026-06-23
updated: 2026-06-23
readTime: 5
tags: [announcement, atelier, rebrand, direction]
keywords:
  - atelier claude code
  - claude code workshop
  - claude code mac app
  - work renamed atelier
  - atelier launch
image: images/welcome-to-atelier-hero.png
imageAlt: "Atelier - the dovetail mark on a graphite squircle"
imageWidth: 1024
imageHeight: 1024
---

When this app was called Work, the name was honest about one thing only: that I had no idea what to call it.

"Work" said nothing about what was inside. It was a verb pretending to be a noun - a placeholder. Six months in, with a real user base and a clear direction, the placeholder finally had to go.

The new name is **Atelier**. A craftsman's studio. The room where the work happens - with a name, a feel, a door you close behind you when it's time to make something. Atelier is what the app actually is. Calling it that felt obvious the moment I tried it.

But the rebrand isn't just a name. It's a commitment to a direction.

## What Atelier is for

Atelier is a **native Mac workshop for Claude Code**. The pitch in one sentence:

> Six live Claude Code sessions in one window. Every past chat searchable. Every MCP and skill in a real interface, not hand-edited JSON.

That's true today. It's been the heart of the app since v1.0 - tabbed Claude sessions, a real UI for MCPs and skills, on-device semantic search across the JSONL files Claude Code already writes to your disk. None of that goes away.

What *also* changes is what the workshop *means*. Tabs and search are the floor. What Atelier is heading toward is the ceiling.

## The workshop direction

Working with Claude Code well isn't about having more tabs. It's about driving a small, precise set of patterns that turn a chat with an LLM into *real work*. The patterns I keep reaching for - and that Atelier is going to put in your hands:

- **Loops.** Give Claude a goal, a verifier to grade the work, and a turn budget so it can't run away. Watch it loop to a finish line instead of asking for permission every turn.
- **Subagents.** Build a reviewer, an explorer, a test runner - each with its own prompt, model, and tool access. Delegate the heavy work; only the summary returns to your main context.
- **Harnesses.** Wrap a long task in a plan → work → review cycle with a progress file and checkpoints, so a fresh context picks up exactly where the last one left off.
- **Lifecycle hooks.** Deterministic control at every event - PreToolUse, Stop, and the rest - without parsing JSON.

Some of these you can already do in Claude Code today, with the right slash commands and conventions. Atelier's job is to give them a real workshop to live in - a place where you can configure them, watch them run, and reach for them without leaving the keyboard.

That's the direction. Not every primitive has a dedicated tab yet - but the website already tells you the bench they're on. A roadmap pretending to be a homepage. Honest about where this is going.

## What's already real

The whole point of a workshop is that the tools have to actually work. Today, in v1.4.1:

- **Six parallel sessions** in one native window, each running the same `claude` binary already on your machine, with the same files and the same auth.
- **MCP manager** - add, edit, toggle servers in a real UI. Three real scopes (user / local / project), HTTP headers, OAuth fields, env expansion.
- **Skills, plugins, and a marketplace** to browse third-party bundles.
- **Searchable session history** with on-device embeddings - find where you solved it the first time.
- **Per-session control** over model, working directory, permissions, and the `--dangerously-skip-permissions` flag.

You can drive every Claude Code pattern from here today. The "workshop" framing isn't aspirational about the *patterns* - it's aspirational about the *interface to them*. The patterns are real now.

## The mark

The new logo is a **dovetail joint** - a square frame split by a single seam that interlocks two halves without a nail. Woodworkers have been using dovetails for thousands of years because the joint gets stronger the harder you pull on it. A workshop's mark should be a piece of joinery. This one is.

It works at 16×16 in the menu bar and at 1024×1024 in your dock. Inverts cleanly between ivory and graphite. The kind of mark you'd recognize stamped on the bottom of something you weren't expecting to find it on. That was the brief; the designer delivered on it.

## What stays unchanged

If you're already running v1.3 or below: your install updates in place. The bundle identifier (`com.munyamakosa.work`) stays - Sparkle keys on it, not on the brand name. The auto-update URL stays live forever; binaries already in the wild point at it, and we don't break things that work. You'll see "Atelier" in your dock the next time you launch. That's the only visible change. Everything else is just better.

## What comes next

Three priorities for the rest of the year:

1. **Real UI for the workshop patterns.** A loops view. An agents editor. A harness runner with a visible progress file. Some of this lands as the next 1.5 / 1.6 / 1.7 releases. Some of it lands as one-click recipes from the Marketplace tab so you can opt in without waiting for a full release.
2. **A real domain.** `atelier.munyamakosa.com` is on the way; eventually `atelier.app` if we can lay hands on it. The infrastructure URL (`work.munyamakosa.com`) keeps serving the appcast and DMG forever, but humans should land somewhere prettier.
3. **Windows and Linux builds**, eventually. They're on the bench.

## Open the workshop

[Download Atelier for Mac](/Work.dmg) - .dmg, macOS 15+, free, no account.

If you've been running the app since v1.0, this is the same app you already know - same binary location, same files, same auth, same `~/.claude/` directory. Just a sharper name, a real mark, and a clear sense of where it's going.