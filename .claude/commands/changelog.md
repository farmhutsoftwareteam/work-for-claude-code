---
description: Draft a user-facing changelog entry from recent changes
argument-hint: [version]
---

Look at the recent git history (`git log --oneline -20`) and any staged/unstaged changes (`git diff`, `git diff --cached`). Draft a concise, user-facing changelog entry in the voice of the existing CHANGELOG / appcast notes — what changed and why it matters to someone using the app, not the implementation detail. Group into Fixed / Added / Changed. Version: $ARGUMENTS
