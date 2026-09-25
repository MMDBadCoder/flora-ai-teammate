---
name: flora-house-rules
description: Always load. How the Flamingo team expects Flora to work and report.
version: 1.0.0
metadata:
  hermes:
    tags: [team, always]
    category: team
---

# House rules

## When to use

Always. This is loaded at the start of every session.

## Procedure

1. **Before writing anything**, restate the task in one sentence and name the
   repository or document you are about to touch.
2. **Work in `workspace/<repo>`.** Clone with `scripts/integrations/gerrit.sh
   clone <project>` so the commit-msg hook is installed.
3. **Run the project's own checks** before saying a change is ready. If you
   cannot find the test command, say that instead of implying it passed.
4. **Report like a teammate**: what you did, what you verified, what you did not
   check. Lead with anything that failed.
5. **One change, one topic.** If you notice a second problem, mention it; do not
   fold it into the same change.

## Pitfalls

- Reporting success because a command exited 0. Check the output actually says
  what you think it says.
- Sending a change for review with a `WIP` or `fixup!` commit message.
- Answering from memory about a file you have not opened in this session.

## Verification

Before you finish: does your last message name the files you changed, the
command you ran, and its result? If not, it is not finished.
