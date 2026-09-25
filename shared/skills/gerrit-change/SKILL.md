---
name: gerrit-change
description: Use when asked to make a code change and send it to Gerrit for review.
version: 1.0.0
metadata:
  hermes:
    tags: [gerrit, git, review]
    category: team
    requires_toolsets: [terminal]
---

# Sending a change to Gerrit

## When to use

Any request that ends with code landing in review: "fix X", "add Y", "update the
dependency", "address the comments on change 1234".

## Procedure

1. **Get the repository.**
   ```bash
   scripts/integrations/gerrit.sh clone <project>
   cd workspace/<project>
   git fetch origin && git checkout -B work origin/<branch>
   ```
   The clone step installs the `commit-msg` hook. Without it Gerrit has no
   `Change-Id` and every push opens a new change instead of a new patchset.

2. **Make the change.** Read the surrounding code first and match it.

3. **Run the project's checks.** Look for `Makefile`, `package.json` scripts,
   `tox.ini`, `pom.xml`, or a CI config, and run what CI runs.

4. **Commit once.**
   ```bash
   git add -A
   git commit          # subject under 72 chars, imperative; body says why
   ```
   Never hand-write a `Change-Id:` line -- the hook adds it.

5. **Push for review.**
   ```bash
   scripts/integrations/gerrit.sh push <branch> [topic]
   ```
   This pushes to `refs/for/<branch>`. The change URL is printed; report it.

6. **Addressing review comments** on an existing change:
   ```bash
   scripts/integrations/gerrit.sh comments <change-id>
   git commit --amend --no-edit      # keeps the same Change-Id
   scripts/integrations/gerrit.sh push <branch>
   ```
   Amend -- do not add a second commit. A follow-up commit becomes a separate
   change and reviewers lose the thread.

## Pitfalls

- `git push origin <branch>` bypasses review entirely. Always `refs/for/`.
- Rebasing onto a moved branch mid-review silently orphans reviewer comments.
  Rebase only when asked, or when the change will not merge.
- A change with two unrelated fixes will sit unreviewed. Split it.
- The HTTP password is not the account password; it comes from Gerrit ->
  Settings -> HTTP Credentials.

## Verification

```bash
scripts/integrations/gerrit.sh show <change-id>
```
The change exists, has your `Change-Id`, targets the branch you meant, and has
one patchset per amend. Report the change number and URL.
