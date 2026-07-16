---
title: "GPT-5.6 changed the plan"
slug: gpt-5-6-changed-the-plan
type: announcement
description: One excellent model built the workshop. GPT-5.6 was good enough that the second bench could not stay empty.
seoTitle: "Why I added OpenAI models to Atelier after GPT-5.6"
metaDescription: "Why GPT-5.6 convinced me to add OpenAI and Codex as a first-class provider in Atelier, without replacing Claude or breaking the work already in progress."
date: 2026-07-16
updated: 2026-07-16
readTime: 7
tags: [announcement, atelier, openai, codex, gpt-5.6]
keywords:
  - GPT-5.6
  - GPT-5.6 Sol
  - Codex Mac app
  - Claude and Codex
  - Atelier OpenAI models
ogAccent: "#10a37f"
ogMonogram: "5.6"
ogDomain: "atelier.munyamakosa.com"
ogProviderMarks: true
providerStory: true
imageAlt: "GPT-5.6 changed the plan, framed by the Claude and ChatGPT marks"
---

Atelier started as a workshop for Claude Code. That was not a temporary description or a safe launch position. It was the whole idea.

Claude did the heavy lifting while I built this app. It helped shape the interface, chase down bugs, hold large parts of the codebase in its head, and turn vague product instincts into working software. A lot of important work is still running through Claude inside Atelier today.

Then I spent real time with GPT-5.6.

Not a benchmark. Not a launch demo. Real work, in the same repositories, with the same half-finished ideas, old decisions, fragile release scripts, and small details that actually decide whether something ships.

It was good enough that the plan had to change.

## The honest reason

There were two pressures at the same time.

The first was practical. We were reaching Claude limits too early, often while the work mattered most. A long implementation would be moving well, the context would finally be rich, and suddenly the scarce thing was no longer the idea or the engineering time. It was access to the model already carrying the work.

That is a bad dependency for a workshop. Important work should not stop because one bench is full.

The second pressure was more interesting. GPT-5.6 did not feel like a weaker substitute waiting behind Claude. It felt like a model I wanted to choose on purpose.

That distinction is the reason OpenAI models are now in Atelier.

## The threshold GPT-5.6 crossed

The useful question is not whether a model can write code. Almost every serious model can produce a plausible function now. The question is whether it can stay oriented while the work becomes inconvenient.

Can it inspect the project before making claims? Can it understand that a UI fix may also touch session persistence, logs, release metadata, and the website? Can it keep moving through implementation and verification without turning every safe step into another question? Can it notice when the thing that technically works still feels unfinished?

GPT-5.6 kept answering those questions well.

The improvement I felt most was judgment. It was better at inferring the actual job behind the sentence I typed. It could take a rough instruction and find the surrounding work that made the result complete. It was also unusually good at frontend detail, which matters in Atelier because the product is not only an agent runner. It is a Mac app people have to look at for hours.

That experience lines up with [OpenAI's own guidance for GPT-5.6](https://developers.openai.com/api/docs/guides/latest-model), which calls out intent understanding, token efficiency, and stronger layout, visual hierarchy, and design judgment. The flagship model is [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), and that is the model that made this feel less like an integration request and more like a product decision.

I did not add OpenAI because a comparison table told me to. I added it because the model earned a place on the bench.

## This is not Claude being replaced

I want to be precise about this because model launches tend to flatten every conversation into a horse race.

Claude is still excellent. It still has workflows inside Atelier that are deeper and more mature. Agents, loops, harnesses, hooks, skills, and plugins have years of Claude-shaped thinking behind them. Existing Claude sessions keep their native history, their authentication, and their tools.

Codex does not need to pretend to be Claude to belong here.

The goal is choice without amnesia. Claude can remain the right tool for one part of the work. GPT-5.6 Sol can be the right tool for another. The workshop should let you make that choice without opening a different product, rebuilding the context by hand, or abandoning the session that got you there.

This is addition, not replacement.

## Atelier should be the workshop

The original version of Atelier wrapped one provider very closely. That closeness was useful. It made the app native to Claude Code instead of becoming a thin generic chat window with ten logos in a dropdown.

But there is a difference between being deeply integrated and being permanently owned by one model family.

The name Atelier helped make that obvious. A workshop is defined by the work and the craft, not by the company that made every tool in it. You keep the tools that earn their place. You understand what each one is good at. You reach for the right one without rearranging the whole room.

So the new architecture keeps the provider-native parts native. Claude still runs through Claude Code. OpenAI models run through the local Codex app server. Atelier sits above both, preserving the visible conversation, the project, attachments, checkpoints, and the handoff between them.

That is the product now: one workshop, more than one excellent mind.

## Your subscription, not another meter

I also did not want adding Codex to mean asking everyone for another API key and putting a new usage meter beside the send button.

Codex supports [signing in with ChatGPT for subscription access](https://learn.chatgpt.com/docs/auth#sign-in-with-chatgpt). Atelier uses that local Codex path. If your ChatGPT or Codex account exposes GPT-5.6 Sol, Atelier can show it in the model picker and let Codex use the subscription you already have.

There is no proxy service in the middle and no Atelier account holding your model credentials. Claude authentication remains Claude's. Codex authentication remains OpenAI's. MCP credentials and OAuth state stay with the provider that owns them.

That separation is less magical than copying everything into one shared file. It is also much safer and much easier to trust.

## Context has to survive the switch

Model choice is useless if changing the model destroys the work.

This was the part I cared about most before calling the integration real. When you switch from Claude to Codex in the same Atelier tab, the visible transcript stays with you. The project and attachments stay with you. Atelier creates a provider-neutral checkpoint so the next model receives the decisions, constraints, open questions, and current state of the work.

Behind that handoff, both native sessions remain intact. Switching back does not replace the Claude session with a Codex imitation. It resumes Claude. Switching again resumes Codex. Atelier carries the shared thread while each provider keeps the state only it can understand.

It is not perfect telepathy between two models. It is a deliberate handoff, and that is the honest way to build it.

## What is real today

In Atelier v2.10.1, you can:

- choose Claude or Codex when you start a tab
- select models exposed by the signed-in provider, including GPT-5.6 Sol when your OpenAI account makes it available
- use the same SwiftUI conversation surface for both providers
- stream replies, send attachments, load history, and resume provider sessions
- switch providers with a continuity checkpoint instead of starting from an empty prompt
- keep Claude and Codex authentication separate
- discover compatible MCP servers without silently moving OAuth credentials between providers

There are still differences. Some of Atelier's deepest workflow tools remain Claude-native today. Codex has its own capabilities, its own session format, and its own evolving tool surface. I would rather show those edges clearly than claim false parity.

The shared layer is real. The provider-specific layer is allowed to stay specific.

## What changes from here

Atelier is no longer a Claude wrapper with an OpenAI tab attached to the side. The model picker is becoming part of the workshop itself.

That means the next work is not simply adding more names to a menu. It is making the choice legible. You should know at a glance whether Claude or Codex is active. You should understand what context will move when you switch. MCP compatibility should be visible before a turn fails. Logs should explain what happened without making you read a protocol transcript.

Most importantly, Atelier should help you choose based on the job. There will be moments when Claude is the better collaborator. There will be moments when GPT-5.6 Sol is the one I trust with the next pass. There will be long days when the best feature is simply that one provider can keep working when the other reaches a limit.

That is not indecision. It is resilience.

## Open the workshop

[Download Atelier for Mac](/Work.dmg). It is free, native, and built for macOS 15 or later.

Claude is still here. Codex now has a real bench beside it. GPT-5.6 is the reason I stopped treating that as a future milestone and built it now.

The work was too important to wait.
