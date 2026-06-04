---
title: "I used Opus 4.7 for 24 hours. Here's what I actually found."
slug: opus-4-7-upgrade-guide
type: workflow
description: "A day with Claude Opus 4.7. What felt different, what broke, and the four things my old code was silently depending on."
seoTitle: "Opus 4.7 after 24 hours: an honest Claude Code field report"
metaDescription: "A day-one field report on Claude Opus 4.7. What felt different, what cost more, and the four API shapes that broke in my own code."
date: 2026-04-17
updated: 2026-04-17
readTime: 6
tags: [opus, claude-code, models, upgrade]
keywords:
  - claude opus 4.7
  - opus 4.7 claude code
  - xhigh effort claude
  - claude opus 4.7 vs 4.6
  - opus 4.7 upgrade
---

Opus 4.7 dropped yesterday.

I've been using it inside Claude Code for about a day now, through a real project, not a benchmark.

The project is an app called Work. It's a native macOS companion for Claude Code, built in SwiftUI, with a menu-bar presence and the whole thing. The core idea is that I was sick of juggling eight Terminal.app windows to run parallel Claude sessions, granting Automation permission every time Sparkle auto-updated the bundle, and losing track of which tab was which project. Work embeds real PTY terminals as tabs inside one window, wraps a proper project + session model around them (with [resume/continue](./claude-continue-and-resume.html) handled natively), and turns Claude Code from "a thing in my terminal" into a workspace.

I'm the only person building it. One week in, solo, no team. That matters for what follows, because when I say "Opus 4.7 felt like hiring a second developer," it's not a figure of speech. A week ago I was a solo dev. Today I'm a solo dev with a collaborator who doesn't sleep.

This isn't a recap of Anthropic's post. It's what I noticed.

## Opus 4.7 thinks longer before acting (and it shows)

4.6 used to fire off tool calls early. Read a file, read another, grep, grep, edit, edit. It felt busy.

4.7 sits still for longer. I'd ask it to refactor a feature, and for the first ten seconds nothing visible happens. Then it moves, and when it moves it's usually closer to right.

That matched something in the release notes I only half-believed: on Anthropic's internal 93-task coding eval, 4.7 solved four problems that neither 4.6 nor Sonnet 4.6 could finish. I assumed that was benchmark theatre. After a day, I think it's real.

SWE-bench Verified went from 80.8 to 87.6. CursorBench 58 to 70. On paper those are just numbers. In my editor, the difference shows up as "the refactor compiled on the first try."

**The bigger the task, the more obvious the gap.**

On a one-line fix I couldn't tell 4.6 from 4.7. But Work's terminal system is the hardest thing in the codebase: a `TerminalsController` holding a dictionary of live `LocalProcessTerminalView` instances, each one a forked bash process, all of it wrapped in SwiftUI state that loves to redraw at the wrong moment. When I asked 4.6 to refactor the tab-close flow to route live tabs through a confirm dialog and dead tabs straight through, it got most of it right three times in a row. Always *almost*. Focus would land on the wrong chip, or the NSAlert would crop its destructive button on dark mode. I'd nudge, it'd fix one thing and regress another.

4.7 got the whole thing in one shot and replaced the flaky NSAlert with a SwiftUI `.alert` without being asked, because it noticed the cropped-button bug in the surrounding code and fixed it on its way through. That's the difference. Not smarter at small tasks. *Aware* on big ones.

## Turn on `xhigh`: Opus 4.7's new effort level

There's a new effort level between `high` and `max`. It's called `xhigh` and 4.7 was tuned around it.

Inside Claude Code, `/effort` → `xhigh`. Do it once.

I tried all four levels on the same task: Work has a per-project Integrations panel where you can two-click install an MCP like Linear into a project, and when you install it while a session is already running, the banner at the top of that session needs to tell you "restart to pick this up", and ideally do the restart for you. `low` shipped a banner that compiled but only covered the happy path. `high` got the edge case (installed into a project with no active session) but wired the restart to the wrong controller. `xhigh` got both and wrote a reasonable test for the restart path. `max` did the same as `xhigh` but took noticeably longer for no extra quality.

`xhigh` is the setting. Not `high`. Not `max`. `xhigh`.

A behavioural change I want to flag: 4.7 calls tools less than 4.6. It thinks more, acts less. If you liked watching Claude rapid-fire grep, you'll notice the quiet. I ended up liking it.

If it feels sluggish on something you know is hard, raise the effort. The density comes back.

## The Opus 4.7 tokenizer quietly raises your bill

Anthropic kept the sticker price flat. $5 per million input, $25 per million output. Same as 4.6.

But 4.7 ships with a new tokenizer, and the same prose counts as up to 35% more tokens than it did on 4.6.

I caught this when my `max_tokens=32000` budget started truncating the end of long refactors mid-function. Watching Claude draft a ninety-line SwiftUI view and then cut off at line 74 because the tokens-per-sentence math changed under me was, not going to lie, a bad twenty minutes. Anthropic's guidance now: 64,000 as the floor at `xhigh` or `max`. I bumped it.

If you're on Claude Max, this doesn't touch you. You don't pay per token.

If you're on API-key billing, your next invoice is going to be 0 to 35% higher for the same workload. Not a crisis. Worth knowing before it shows up.

If you use prompt caching, your old cache entries don't match anymore. Mine cold-hit for half a day then settled.

**A price that technically didn't change is still a price that changed.**

## Claude Code switches to Opus 4.7 by default on April 23

On April 23, 2026, Claude Code's default Opus model becomes 4.7 for Enterprise PAYG and API users.

If you're mid-project and don't want to find out on a Wednesday that your agent's output shape changed:

```bash
export ANTHROPIC_MODEL="claude-opus-4-6"
```

Or `--model claude-opus-4-6` per session. `/model` inside a running session shows you where you are.

Claude Max on Auto mode is already on whatever's active. Nothing to pin.

I pinned one of my two machines to 4.6 just to have a clean baseline for the week. It's the machine I cut Work's release DMGs from. If something weird shows up in notarization or in Sparkle's update feed between now and the 23rd, I want to be sure it's not the model changing under me. Recommend doing the same if you're in the middle of anything load-bearing.

## Four Anthropic API shapes that break on Opus 4.7

This is the bit I didn't expect.

If you only use Claude Code in the terminal, the upgrade is invisible. The CLI ships an update, your day continues.

If you've wired Claude into your own app (API, proxy, agent framework), there are four request shapes from 4.6 that 4.7's server rejects. Your request never runs. You just see an error in your logs.

The four that bit me:

1. **`temperature`, `top_p`, `top_k`.** All gone. I had `temperature: 0.2` sitting in a config from 2024. First request under 4.7 returned an error. Strip them.

2. **The old extended thinking shape.** `thinking: { type: "enabled", budget_tokens: 8000 }` is gone. Replace with `thinking: { type: "adaptive" }` and move the budget into `output_config.effort`.

3. **Assistant-message prefilling.** The old trick of starting the model's response in the messages array. Gone. Move the priming into your system prompt.

4. **Top-level `output_format`.** Now nested under `output_config.format`.

One silent change that got me: on 4.6, if you didn't ask for thinking, you got a small thinking budget by default. On 4.7, if you don't ask, you get none. Work has a tiny status view in the tab chip that pulses while Claude is streaming. On 4.7 it sat dark for a visible beat on every response before text started flowing, because the model was thinking and not streaming its thoughts. I was three minutes into rewriting my stream handler when I realised nothing on *my* side was broken. The model had just gone quiet and I hadn't asked it not to.

**The bugs you can't see are always the worst ones.**

Actual fix that saved me a chunk of time: inside Claude Code, `/claude-api migrate this project to claude-opus-4-7`. It found and patched most of it. The rest I caught when the first error landed in my logs.

## Opus 4.7 changes that didn't make the release notes

**Vision images got bigger.** Max image size went from 1568px to 2576px. Bounding-box coordinates are now exact pixel coordinates, no more scale math. If you feed full-res screenshots, they tokenize to about 3× the tokens. Budget for it.

**Auto mode on Claude Max got 4.7.** `/auto` inside Claude Code, if you're on Max.

**4.7 refuses red-team and pen-test prompts more aggressively.** If you do legit security work, apply to the Cyber Verification Program before you migrate, not after you hit refusals.

**Claude Code needs v2.1.111 or newer.** v2.1.112 fixed an "Opus 4.7 temporarily unavailable" error on Auto mode. Update before you flip.

## Should you upgrade

A day in, the honest answer:

If you write code with Claude, yes. Turn on `xhigh`. Try one multi-file refactor, or let it [review a PR for you](./review-prs-like-a-staff-engineer.html). You'll feel it inside an hour.

If you're on Claude Max, yes. You don't see the token math anyway.

If you're on API-key billing, yes. Expect a small bill bump. Plan for it.

If you call Anthropic's API from your own app, fix the four breaking shapes first. Then upgrade.

If you use Claude mostly for facts or research, wait a week and test with prompts that matter to you. The coding numbers moved. The factual ones didn't.

If you maintain an API product with strict output contracts, pin 4.6 past April 23 and migrate on your own clock.

## Frequently asked questions about Opus 4.7

### What's new in Claude Opus 4.7?

Opus 4.7 ships a sharper coding model (SWE-bench Verified 80.8 to 87.6, CursorBench 58 to 70), a new `xhigh` effort level between `high` and `max`, a new tokenizer that counts the same prose as up to 35% more tokens, and four breaking API changes. It also refuses red-team prompts more aggressively, accepts 2576px images (up from 1568px), and adds Auto mode on Claude Max. The model ID is `claude-opus-4-7`, available on the Anthropic API, Bedrock, Vertex, and Microsoft Foundry as of April 16, 2026.

### Should I upgrade to Opus 4.7?

If you write code with Claude, yes: the multi-file refactor quality jumped noticeably. If you're on Claude Max, yes: you don't pay per token so the tokenizer change doesn't matter. If you call Anthropic's API from your own app, fix the four breaking request shapes first (strip `temperature`, `top_p`, `top_k`; update the extended thinking shape; remove assistant prefills; nest `output_format` under `output_config.format`). If you use Claude mostly for facts or research, wait a week because the factual benchmarks didn't move.

### How do I stay on Claude Opus 4.6?

Export `ANTHROPIC_MODEL="claude-opus-4-6"` in your shell, or pass `--model claude-opus-4-6` per Claude Code session. Run `/model` inside a session to confirm. Claude Code's default flips from 4.6 to 4.7 on April 23, 2026 for Enterprise PAYG and API users, so pin before that date if you don't want the change mid-project. Claude Max subscribers on Auto mode stay on whatever Anthropic has active.

### Why is my Claude Opus API bill higher after upgrading?

The sticker price didn't change ($5 per million input, $25 per million output), but Opus 4.7 ships with a new tokenizer that counts the same text as 0 to 35% more tokens than 4.6. Your cached prompts also cold-hit for a day until the cache re-warms. Bump `max_tokens` to at least 64,000 if you're running at `xhigh` or `max` effort, because responses will otherwise truncate mid-output at the old 32k budget.

## My end-of-day checklist

1. Update Claude Code to v2.1.112 or newer.
2. `/effort` → `xhigh`.
3. On API-key billing, expect 0 to 35% cost bump from the new tokenizer. Recalibrate.
4. Custom API code: strip `temperature`, `top_p`, `top_k`. Update the thinking shape. Remove assistant prefills. Nest `output_format` under `output_config.format`.
5. Not ready? Pin 4.6: `ANTHROPIC_MODEL="claude-opus-4-6"`.
6. Default flips April 23. Ride it or pin it. Decide before then.

Model ID is `claude-opus-4-7`. Available on the Anthropic API, Bedrock, Vertex, and Microsoft Foundry as of April 16. 4.6 stays callable. No retirement date announced.

**Most model upgrades are noise. A few genuinely change what the tool can do.** After a day, this feels like one of the second kind.

Work ships 1.0.9 this week with the embedded terminal tabs, the Integrations panel, and proper 4.7 defaults baked in. If you've been Cmd+Tabbing between eight Terminal.app windows to keep your Claude sessions organized, give it a try.

**[Try Work →](/)**

---

*Written by Munya Makosa, building [Work](/) in public. Shipping a macOS companion for Claude Code, one release at a time.*
