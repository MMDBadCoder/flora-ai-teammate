---
name: gerrit-review
description: Use when asked to review someone else's Gerrit change.
version: 1.0.0
metadata:
  hermes:
    tags: [gerrit, review]
    category: team
---

# Reviewing a change on Gerrit

## When to use

"Review change 1234", "what do you think of this patch", "is this safe to merge".

## Procedure

1. Read the change and its history:
   ```bash
   scripts/integrations/gerrit.sh show <change-id>
   scripts/integrations/gerrit.sh comments <change-id>
   ```
2. Fetch it locally so you review the real tree, not a diff in isolation:
   ```bash
   cd workspace/<project>
   git fetch origin refs/changes/<last-2-digits>/<change-number>/<patchset> && git checkout FETCH_HEAD
   ```
3. Look, in this order, for:
   - **Correctness**: does it do what the commit message says, in every branch
     of the code, including the error paths?
   - **Blast radius**: what else calls this? `git grep` the symbols it changes.
   - **Tests**: is the new behaviour covered? Would the test fail without the fix?
   - **Consistency**: does it match how this repository already does things?
4. Post the review:
   ```bash
   scripts/integrations/gerrit.sh review <change-id> "..." 0
   ```
   Use `-1` only for something you can name concretely. Use `+1` when you have
   actually read it all.

## Pitfalls

- Reviewing the diff alone and missing a caller the change breaks.
- Style opinions dressed as blockers. Say "nit:" and move on.
- Never `+2` or submit a change you wrote.

## Verification

Your review names specific lines, and every objection has a reason a reader can
act on without asking you a follow-up question.
