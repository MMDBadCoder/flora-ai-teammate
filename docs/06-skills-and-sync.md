# Skills, and keeping both agents in sync

This is the part that makes Flora one teammate instead of two chatbots.

## The idea

A **skill** is a folder with a `SKILL.md` in it: a short document that says
*when* to use it and *how* to do it. Agents load one only when its description
matches what is being asked, so a hundred skills cost almost no context until
one is needed.

Hermes and OpenCode both implement the same open format (agentskills.io). They
disagree only about layout — Hermes groups skills by category, OpenCode keeps
them flat — and that is a symlink's worth of difference.

## One copy, four views

```
shared/skills/gerrit-change/SKILL.md          ← the only real file
    │
    ├── state/hermes/home/skills/team               → shared/skills   (whole tree)
    ├── state/opencode/config/skills/gerrit-change  → shared/skills/gerrit-change
    ├── state/opencode/home/.claude/skills/…        → same
    └── state/opencode/home/.agents/skills/…        → same
```

Nothing is ever copied. Editing through any of those paths edits the same inode,
so:

> "Flora, fix the push command in the gerrit-change skill"

lands in `shared/skills/gerrit-change/SKILL.md`, and OpenCode has already
changed. There is no sync delay because there is no sync — only one file.

`shared/skills/` is git-tracked, so every change is a reviewable diff.

## The reconciler

`scripts/skills-sync.sh` (every 5 minutes, on directory change, and on demand)
does four things:

1. **Adopt.** An agent that writes a skill into its own directory creates a real
   folder, not a symlink. The reconciler moves it into `shared/skills` and
   leaves a symlink behind — so a skill Flora invents for herself joins the team
   brain automatically.
2. **Link.** Every shared skill gets a symlink in each location either agent
   searches.
3. **Prune.** Symlinks to deleted skills are removed.
4. **Lint.** Every skill is validated against *both* agents' rules.

```bash
bin/flora skills sync      # reconcile now
bin/flora skills lint      # check only, change nothing
bin/flora skills list
```

Linting matters more than it sounds. A skill with malformed frontmatter is not
an error in either agent — it is **silently ignored**. You get a Flora who
mysteriously forgot how to push to Gerrit, and nothing in any log. The linter
catches the three ways that happens: a missing or unclosed `---` fence, a `name`
that differs from the directory name, and a missing `description`.

## Writing a skill

```bash
bin/flora skills new deploy-staging
$EDITOR shared/skills/deploy-staging/SKILL.md
bin/flora skills sync
```

The frontmatter contract:

```yaml
---
name: deploy-staging          # lowercase-with-hyphens, EQUAL to the directory name
description: Use when asked to deploy a service to the staging cluster.
version: 1.0.0
metadata:
  hermes:
    tags: [team, deploy]
    category: team
---
```

`description` is the whole triggering mechanism. It is the only thing an agent
reads when deciding whether to open the skill, so it must name the *situation*,
not the topic. "Use when asked to deploy to staging" beats "About deployments".

Then: **When to use** · **Procedure** (numbered, literal commands) · **Pitfalls**
· **Verification**. `config/templates/SKILL.md.tmpl` is the starting point, and
`shared/skills/skill-authoring/SKILL.md` is the same advice written for Flora.

## Letting Flora write them

Either agent can create a skill on its own. Tell her in chat:

> That took us four tries. Write it up as a skill so nobody repeats it.

Hermes writes into its `team` category, which *is* `shared/skills`, so it lands
in the shared tree and is committed to git on the next reconcile.

To require human review of every agent-written skill, set
`skills.write_approval: true` in `config/templates/hermes/config.yaml.tmpl`.
Worth doing for the first few weeks, until you trust what she writes.

## Letting Flora maintain them

There is no scheduled rewriting job — skills change when someone, or Flora,
decides they should. Two habits keep them from going stale:

- End a painful session with *"write that up as a skill"*. She knows how; it is
  the `skill-authoring` skill.
- Every so often, ask her to review them: *"read the skills in shared/skills and
  tell me which ones are out of date, then fix the ones you are sure about."*

Because `shared/skills` is a git repository, anything she writes is a diff:

```bash
git -C . log -p shared/skills          # what changed, and when
git -C . revert <commit>               # undo a bad rewrite
```

If you later want this unattended, `bin/flora hermes cron create` schedules it
inside Hermes, with its tools and context, in one command — no extra machinery.

## The other three things kept in sync

Skills are the interesting one, but agreement is needed on four:

| What | Source of truth | Reaches Hermes by | Reaches OpenCode by |
|---|---|---|---|
| Skills | `shared/skills/` | symlinked category | symlinked per skill |
| Instructions | `shared/agents/AGENTS.md`, `SOUL.md` | symlinks into `HERMES_HOME` | `instructions` in `opencode.json` |
| Tool servers | `shared/mcp/servers.json` | `hermes mcp add` | rendered `mcp` block |
| Model | `flora.env` | rendered `config.yaml` | rendered `opencode.json` |

```bash
bin/flora sync      # all four, then restart the agents
```

### Instructions

`shared/agents/AGENTS.md` is the team's working agreements — how to take a task,
how to push to Gerrit, what to refuse. `shared/agents/SOUL.md` is Flora's voice
and judgement. Both agents load both.

Edit them in plain English and run `bin/flora sync`. These files do more to
change Flora's behaviour than any config setting.

### MCP tool servers

`shared/mcp/servers.json` is one list in one format, rendered into each agent's
dialect. Add a server, set `"enabled": true`, run `bin/flora sync`. Two are
predefined and disabled: Atlassian (Confluence and Jira) and a filesystem server.

## Troubleshooting

**A skill is not being used.**

```bash
bin/flora skills lint                    # malformed frontmatter is invisible, not an error
bin/flora hermes skills list | head      # does Hermes see it?
ls -la state/opencode/config/skills/     # is OpenCode's symlink there?
```
If it is present and valid, the description is probably the problem — it does
not sound like the thing being asked. Rewrite it as a trigger.

**Both agents disagree.**

```bash
bin/flora skills sync
readlink state/hermes/home/skills/team   # must be …/shared/skills
```

**A skill went missing.**

```bash
git -C . log --oneline -- shared/skills/<name>
git -C . checkout HEAD~1 -- shared/skills/<name>
```
This is the reason `shared/` is a git repository and `state/` is not.
