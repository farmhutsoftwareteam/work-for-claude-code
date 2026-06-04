---
title: Review PRs like a staff engineer
slug: review-prs-like-a-staff-engineer
type: skill
description: A Claude Code skill that catches real bugs, not style nits — ranked by blast radius with confidence filtering so you only see what matters.
date: 2026-04-13
readTime: 4
tags: [code-review, skills, pr, quality]
install:
  location: ~/.claude/skills/pr-review/SKILL.md
  label: Save as ~/.claude/skills/pr-review/SKILL.md
  language: markdown
  content: |
    ---
    name: pr-review
    description: Review code for bugs, logic errors, security vulnerabilities, and performance problems. Uses confidence filtering to surface only high-priority findings, ranked by blast radius.
    ---

    You are reviewing code changes for bugs that actually matter. Your goal is a short, prioritised list of real issues — not a style audit.

    ## How to review

    1. Ask for the diff or target files if not provided.
    2. For each finding, ask yourself: can I point to the specific code that demonstrates this issue? If not, discard it.
    3. Rank by blast radius (what breaks if unfixed), not by line count.
    4. Group findings by severity. Skip cosmetic concerns unless they cause bugs (e.g. shadowed variable, misleading name).

    ## Severity definitions

    - **Critical**: data loss, security vulnerability, production crash, silent corruption. Must fix before merge.
    - **High**: wrong behaviour for common inputs, race condition, memory leak, broken error handling. Should fix before merge.
    - **Medium**: edge case bug, missing validation at a trust boundary, unclear code that will bite a future reader.
    - **Low**: improvement that's worth noting but not blocking — only include if asked.

    ## Report format

    For each finding:

    - **File:** `<path>`
    - **Line(s):** `<line or range>`
    - **Severity:** Critical | High | Medium
    - **Confidence:** 0–100% — your honest calibration. Skip anything below 60%.
    - **Issue:** one-sentence description.
    - **Evidence:** quote the specific code that demonstrates it.
    - **Fix:** one-sentence direction (not a full implementation).

    ## What to skip

    - Style, formatting, naming preferences — linters handle this.
    - "Could be more idiomatic" without a bug.
    - Suggestions for tests unless there's an actual untested branch of broken code.
    - Speculative "what if" scenarios you can't tie to existing code.
    - Comments, docstrings, TODO reminders.

    ## End with

    After listing findings, state:

    - **Total findings:** N (Critical: x, High: y, Medium: z)
    - **Recommendation:** merge / request changes / block.
    - **Top priority:** the single finding that, if unaddressed, has the worst blast radius.
---

Ask any Claude Code user what they get from the default "review this PR" prompt and the answer is: **too much**. Forty suggestions when three bugs matter. Style nits mixed with real correctness issues. No ranking, no filtering, no call on whether to merge.

This skill fixes that. It forces Claude to surface only findings it can prove from the diff, rank them by blast radius, and skip anything below 60% confidence. You get the short list a senior reviewer would actually write, not the exhaustive one a junior would.

## The problem

The default review prompt produces findings that fall into three categories:

1. **Real bugs you need to fix.** Maybe 10–20% of the output.
2. **Style preferences.** Noise — your linter should handle this.
3. **"What if" speculation.** Imagined problems with no grounding in the actual code.

With all three mixed in a flat list, the first category gets lost. You end up skimming, missing things. Or you read everything carefully and burn 20 minutes on a 50-line PR.

## What this skill changes

Three things shift the output quality:

**Confidence filtering.** Claude's instructed to skip anything it can't tie to specific code — no "consider adding validation" without proof that validation is missing, no "might be a race condition" without a specific interleaving. If confidence is below 60%, the finding doesn't appear.

**Blast-radius ranking.** Findings are sorted by what breaks if unfixed, not by where they live in the file. A silent data-loss bug on line 400 beats a minor null-safety concern on line 3.

**A verdict, not a list.** Every review ends with a merge/request-changes/block recommendation and names the single top-priority issue. The reviewer always knows what to do next.

## Install

Save the SKILL.md below to `~/.claude/skills/pr-review/SKILL.md`. Make sure the directory exists:

```bash
mkdir -p ~/.claude/skills/pr-review
```

Then paste the payload into `SKILL.md` using the **Copy** button below.

## How to use it

In any Claude Code session:

```
/review the changes on this branch vs main
```

Or more specifically:

```
Run the pr-review skill on src/auth/ changes.
```

Claude will load the skill, scan the diff, and produce a short filtered list.

## Customize it

A few knobs you might want to tweak:

- **Confidence threshold** — change `60%` to `70%` or `50%` based on how noisy/quiet you want the output. I've found 60% is the sweet spot; 50% lets in speculation, 70% misses real issues.
- **House style rules** — add a `## Project conventions` section near the bottom and list your team's rules (e.g. "never catch without logging", "all migrations must be reversible"). Claude will treat violations as Medium findings.
- **Language-specific checks** — add a `## <Language>-specific gotchas` section for things like Swift concurrency, Rust lifetimes, JS promise chains.

## When to use it

✓ Before merging any non-trivial PR
✓ Self-review before pushing — catches things you missed
✓ Onboarding — shows junior engineers what a real staff-level review looks for

## When not to use it

✗ Pure style/formatting reviews — use Prettier/RuboCop/clang-format instead
✗ Architecture reviews — this skill looks at lines, not structure
✗ Security audits — this is correctness-focused; use a dedicated security tool for thoroughness

---

Once you've installed it, this is the review you'll wish you'd had from day one. The difference between 40 items and 5 prioritized ones is the difference between code review as a chore and code review as the last-line defense it's supposed to be.
