---
title: "What broke at GitHub on April 23, explained without jargon"
slug: github-april-23-merge-queue-explained
type: workflow
description: "GitHub silently undid 2,092 pull requests of code last week. Most explanations assume you already know what a merge queue is. This one doesn't."
seoTitle: "GitHub merge queue bug, April 23 2026, explained in plain English"
metaDescription: "GitHub silently undid 2,092 pull requests across 658 repos on April 23. Here is what actually broke, in plain English, with no jargon."
date: 2026-04-30
updated: 2026-04-30
readTime: 6
tags: [github, incident, explainer, devops]
keywords:
  - github outage april 23 2026
  - merge queue bug
  - github merge queue regression
  - what happened to github
  - github incident explained
---

A week ago, GitHub silently undid 2,092 people's code.

Not deleted. Not lost. Worse: it appeared to merge their work, marked the pull requests as "merged", and then quietly reverted the changes a few minutes later. People walked away from their laptops thinking the job was done. The job was not done.

Almost four hours passed before anyone at GitHub noticed.

If you've read other write-ups, they probably assumed you already know what a "merge queue" is, what "squash merge" means, and what a "three-way merge" is. This one starts from zero. By the end, you'll understand exactly what broke and why it matters.

## What Git is, in a paragraph

Imagine a notebook. Every time you finish a thought, you start a new page and write down what changed since the last page. Page 1 is the first draft. Page 2 says "I changed paragraph 3." Page 3 says "I deleted the second sentence."

Git is that notebook for code. Every "save" is called a *commit*. Each commit knows what came before it. The whole project is the chain of every commit, all the way back to the very first one.

That's it. Git is just a chain of saves where each save knows what changed.

## What GitHub is

Git lives on your computer. Your notebook is in your hands.

GitHub is the cloud version. Push your local notebook up there, and now your team can see it, copy it, and propose changes to it. GitHub didn't invent Git. It made Git social.

If Git is a notebook, **GitHub is the shared cabinet where everyone's notebooks live**.

## What a branch is

Now imagine you want to try something risky. You don't want to scribble all over the main notebook in case it doesn't work out.

So you grab a fresh notebook and copy page 1 through 47 into it. Now you have two notebooks: the original *main* one, and your *experiment* one. You can scribble in the experiment notebook all you want. The main notebook stays clean.

That's a **branch**. A separate copy where you can try things without affecting the main version.

## What a pull request is

Your experiment worked. The new feature is great. Now you want it to live in the main notebook.

You don't just walk over and rip out pages. You raise your hand. You say: "Hey team, can someone read pages 48 through 53 of my experiment notebook and tell me if they look good? If yes, please add them to the main notebook."

That's a **pull request** (a "PR"). A proposed change, waiting for human review.

## What a merge is

The team approves your PR. Now someone has to actually copy your changes into the main notebook.

Combining two notebooks back together is called a **merge**. Sounds simple, but Git does something subtle: it doesn't just paste your pages on top of the main notebook. It reads what *both* notebooks did since they split, then writes a new page that combines the two streams.

Most of the time this is automatic. Sometimes both notebooks edited the same paragraph and Git asks a human to decide which version wins. That's a *merge conflict*.

## What a squash merge is

Real PRs aren't five clean pages. They're forty messy ones: "first attempt", "fix typo", "actually use the right variable", "ignore the last commit, I was wrong", "ok now it works".

Forty pages of confused thinking is fine while you're working alone. It's noise once it's in the main notebook. So GitHub offers an alternative.

A **squash merge** rolls all forty pages into one clean page that says "added the new feature." Same end result, much less mess.

The original forty messy pages still exist in your branch. The main notebook just gets the one tidy summary page.

## What a merge queue is

Now imagine a busy team. Twenty people all want to merge their PRs into the main notebook at the same time. If they all do it in parallel, chaos: each person's merge is based on a slightly different "main notebook", and combining them gets messy.

So GitHub built a **merge queue**. Like a queue at a coffee shop. PRs line up. They get merged one at a time, in order. Each PR is freshly tested against the main notebook *as it stands right now* before it gets in. By the time it reaches the front of the line, it's been re-validated against everything that went in ahead of it.

Merge queues are the boring engineering plumbing that lets a thousand engineers ship code into the same repo without stepping on each other.

This is the system that broke.

## What actually went wrong

Here's the bug in one sentence.

**The merge queue's "where did this branch start from" calculation got the wrong answer, so when it bundled multiple PRs in a row, each PR's tidy summary page accidentally erased pieces of the PR ahead of it.**

The technical version, from [GitHub's own incident report](https://www.githubstatus.com/incidents/zsg1lk7w13cf):

> "The regression was introduced by a new code path that adjusted merge base computation for merge queue ref updates… the gating was incomplete. As a result, the new behavior was inadvertently applied to squash merge groups, producing an incorrect three-way merge."

Translation:

GitHub had shipped a new way of computing what's called the *merge base* (the last point where two branches agreed before they split). The new method was supposed to apply only in a specific case. But the *if-statement* that was supposed to gate it was missing one of its conditions.

So when the merge queue processed three PRs in a row using squash merge, here's what happened:

1. PR #1 squash-merged successfully. Main notebook gets a tidy summary page from PR #1.
2. PR #2 came up. Its squash merge was computed against the *wrong starting point*. The summary page Git wrote effectively said "main notebook + PR #2's changes, but assuming PR #1 hadn't happened yet." Adding that page to the main notebook *un-did* parts of PR #1.
3. PR #3 same problem, but now it un-does parts of PR #2.

PR authors saw the green "Merged" badge on their pull requests. The pages were filed. The main notebook said "merged successfully." But quietly, the work in those pages had been overwritten.

## How big the damage was

- **2,092 pull requests** affected
- **658 repositories** affected
- **4 hours and 38 minutes** of impact (April 23, 2026, 16:05 → 20:43 UTC)
- **3 hours and 45 minutes** between the bug going live and GitHub noticing

The 3h45m gap is the part that should make engineers uncomfortable. GitHub's automated monitoring did not catch it. They learned about it from customer reports. Someone had to notice their own code had silently disappeared, file a bug, get it triaged, before GitHub's incident response even started.

Once they noticed, it took eight minutes to identify the cause and start reverting. Eight minutes of investigation versus three hours and forty-five minutes of "everything looks fine."

That's the gap that kept growing. That's the part that's hard to fix.

## Why this is harder than it sounds to prevent

Reading the post-mortem, it's tempting to say "just write a test." It's never that simple.

The bug only triggered when:
1. The merge queue was used (most repos don't use it)
2. *And* squash merge was the chosen strategy (some repos pick straight merge or rebase instead)
3. *And* a merge group had more than one PR in it (single-PR groups merged fine)
4. *And* the PRs touched related files (otherwise the wrong merge base produced the same result)

That's a deep stack of conditions. You'd need a test that builds a merge queue, fills it with multiple squash-merged PRs that touch overlapping code, processes them, and asserts that the final state of the main branch contains all the changes from all the PRs.

GitHub presumably has tests like that. The new code path slipped through because the *gate condition* was wrong, not the test logic. The test was running, just not on this code path.

## The lesson is bigger than GitHub

Software at this scale fails in a particular shape. Code goes out, monitoring says everything's fine, the bug is real but invisible to the tools watching it, and a human eventually notices something feels off.

The expensive lesson here is not "write better tests." It's **trust your customer reports more than your dashboards**. The dashboards said GitHub was up. The customers said code was disappearing. The customers were right.

GitHub said as much in their availability post-mortem. They're calling it "Availability First." Less feature work, more boring reliability work. More honest status pages. Faster surfacing of "something feels off" signals.

It's the same lesson every infrastructure company eventually learns. GitHub just had a particularly visible week of learning it.

If you spend a lot of time reviewing PRs, you might also like our take on [reviewing pull requests like a staff engineer](./review-prs-like-a-staff-engineer.html). And if you're building with Claude Code through this same chaos, the [Opus 4.7 upgrade guide](./opus-4-7-upgrade-guide.html) covers what's currently shippable.

## Frequently asked questions

### What is a merge queue?

A merge queue is a system that lets a team merge many pull requests into the same branch one at a time, in order, instead of in parallel. Each pull request gets re-validated against the branch as it stands the moment its turn arrives. GitHub introduced merge queues to keep large repositories with hundreds of contributors from breaking each other's work. The April 23 incident affected only repositories using merge queue with squash merges.

### How many repositories were affected by the GitHub merge queue bug?

GitHub's official incident report says 2,092 pull requests across 658 repositories were affected during the impact window of 16:05 to 20:43 UTC on April 23, 2026. The bug only triggered for repositories using merge queue with squash merges where a single merge group contained more than one pull request.

### Was any code permanently lost?

No. Git is designed so commits are never truly deleted. Every messy original commit still exists in the branch each pull request was opened from. The default branches that received the bad squash merges contain reverted state, but the original work can be recovered from the source branches. Recovery takes care because each affected pull request needs to be reconstructed individually.

### How long did it take GitHub to detect the bug?

About three hours and forty-five minutes. The bug went live at 16:05 UTC and GitHub posted the first "investigating" status update at 19:50 UTC. They identified the cause and started reverting eight minutes later. Automated monitoring did not catch it; engineers learned about it from customer reports.

### Was this related to a botnet attack or the CVE-2026-3854 vulnerability?

No. The April 23 merge queue regression is a separate incident from the April 27 Elasticsearch search outage GitHub attributed to a likely botnet attack, and from the unrelated CVE-2026-3854 RCE that Wiz disclosed on April 28. GitHub had a difficult late-April week with three distinct failures, but they have no causal connection.

---

If you write code with a team, and your repo uses a merge queue with squash merge: it's worth running `git log --merges` over the days of April 23 and looking for any merges that touched files where work suddenly went missing. The bug is patched, but the squash commits it produced are still in history. The good news is Git is built so nothing is ever truly gone. Every messy original commit still exists in the branch each PR came from. The bad news is reconstructing them takes care.

The boring infrastructure that makes the modern web work is more fragile than it looks. Worth knowing.

Source: [GitHub Status, Incident zsg1lk7w13cf](https://www.githubstatus.com/incidents/zsg1lk7w13cf)

---

*Written by Munya Makosa, building [Work](/) in public. Plain-English breakdowns of the kind of infrastructure failures most write-ups assume you already understand.*
