# Integrations

## Mattermost — talking to Flora

The Hermes gateway holds a websocket to Mattermost and answers as a bot.

**Setup** (also in [02-install.md](02-install.md#4-finish-mattermost)):

1. System Console → Integrations → Bot Accounts → **Enable**.
2. Add a bot named `flora`. Copy the token — shown once.
3. Collect the Mattermost user IDs of everyone allowed to talk to her
   (Profile → Settings → Security → View ID, 26 characters).
4. ```bash
   bin/flora secrets edit
   #   MATTERMOST_BOT_TOKEN=...
   #   MATTERMOST_ALLOWED_USERS=id1,id2,id3
   bin/flora restart gateway
   ```
5. `/invite @flora` in a channel.

**Behaviour**

| Where | Trigger | Session |
|---|---|---|
| DM | every message | per user |
| Channel | `@flora` mention | per thread |
| Thread | replies in a thread she is in | isolated |

`MATTERMOST_REPLY_MODE=thread` keeps her answers threaded instead of flooding
the channel. `group_sessions_per_user` keeps two people's context apart in a
shared channel.

**She is ignoring me.** In order: is her ID in `MATTERMOST_ALLOWED_USERS`
(empty means nobody); is the bot in the channel; `bin/flora logs gateway -f`.

## Gerrit — changing code

`scripts/integrations/gerrit.sh` is the single entry point; the `gerrit-change`
and `gerrit-review` skills tell Flora how to use it.

**Setup**

1. Create a Gerrit account for Flora (or reuse a service account).
2. In Gerrit → Settings → **HTTP Credentials** → Generate password. This is
   *not* the account password.
3. ```bash
   bin/flora secrets edit
   #   GERRIT_URL=https://gerrit.example.com
   #   GERRIT_USER=flora
   #   GERRIT_HTTP_PASSWORD=...
   ```
4. Give the account normal contributor rights: push to `refs/for/*`, read the
   projects it needs. **Not** submit rights, and not +2 — a teammate's change
   should be reviewed by a person.

**Use**

```bash
scripts/integrations/gerrit.sh clone <project>        # into workspace/, with the hook
scripts/integrations/gerrit.sh push <branch> [topic]  # to refs/for/<branch>
scripts/integrations/gerrit.sh list "status:open owner:self"
scripts/integrations/gerrit.sh show 1234
scripts/integrations/gerrit.sh comments 1234
scripts/integrations/gerrit.sh review 1234 "looks good, one nit on line 40" 0
```

The clone installs Gerrit's `commit-msg` hook. Without it there is no
`Change-Id`, and every `git commit --amend` opens a *new* change instead of a
new patchset — the single most common way to make a mess on Gerrit.

Ask her in chat:

> Flora, clone platform/api, fix the null check in `UserService.load`, run the
> tests, and push it for review on master.

**SSH instead of HTTP.** Flora has her own `$HOME` and therefore her own
`~/.ssh` — she does not inherit yours. Give her a key of her own:

```bash
ssh-keygen -t ed25519 -f state/hermes/fs-home/.ssh/id_ed25519 -C "flora@flora.com" -N ""
cat state/hermes/fs-home/.ssh/id_ed25519.pub     # add this to Flora's Gerrit account
```

OpenCode's `$HOME` is `state/opencode/home`; symlink or copy the same key there
if she should push from that side too. Keeping the key inside the tree means it
travels with the directory, and that revoking Flora's access is one key, not yours.

## Confluence — writing docs

`scripts/integrations/confluence.py` (standard library only, no pip install),
driven by the `confluence-docs` skill.

**Setup**

```bash
bin/flora secrets edit
#   CONFLUENCE_URL=https://confluence.example.com     # or https://x.atlassian.net/wiki
#   CONFLUENCE_USER=flora@example.com                 # empty when using a PAT
#   CONFLUENCE_TOKEN=...                              # API token or personal access token
```

Cloud uses email + API token (Basic). Data Center usually uses a personal access
token with no user (Bearer). The script handles both: leave `CONFLUENCE_USER`
empty for Bearer.

**Use**

```bash
scripts/integrations/confluence.py search "deployment runbook"
scripts/integrations/confluence.py get ENG:Deployment Runbook
scripts/integrations/confluence.py get 123456
scripts/integrations/confluence.py create ENG "New page" body.md --parent 123456
scripts/integrations/confluence.py update 123456 body.md
scripts/integrations/confluence.py append 123456 section.md
```

Confluence rejects an update whose version is not exactly current + 1, which is
what stops two writers overwriting each other. If you see that error, someone
edited the page while Flora worked: re-read and redo the edit on top.

**Via MCP instead.** `shared/mcp/servers.json` has an Atlassian MCP entry. Set
`"enabled": true`, run `bin/flora sync`, then `bin/flora hermes mcp login
atlassian` once. That gives richer Jira and Confluence tools; the script stays
useful because it works in a cron job with no OAuth session.

## TokenRing — the model pool

Both agents point at `http://127.0.0.1:4000/v1` and authenticate with the
`sk-ring-…` key in `secrets/flora.env`. Neither ever sees a real provider key.

Day to day:

- **Add a provider key**: dashboard → Upstream keys → Add.
- **Issue a key per person or tool**: Virtual keys → Issue. Usage is then
  attributable, and revoking one affects nobody else.
- **Watch spend**: the dashboard shows requests, prompt/completion tokens, error
  rate and latency per key.
- **Quotas**: requests/minute, requests/day, tokens/day, expiry, model allowlists.

Anything else that speaks OpenAI — a script, an IDE plugin, a CI job — can use
the same pool:

```python
client = OpenAI(base_url="http://tokens.flora.com/v1", api_key="sk-ring-…")
```

## Adding an integration

The pattern, in order:

1. Credentials → `secrets/flora.env`, referenced from
   `config/templates/hermes/env.tmpl`.
2. A helper in `scripts/integrations/` that reads them. One command per verb,
   text in and text out.
3. A skill in `shared/skills/` that tells Flora when and how to use it.
4. `bin/flora render && bin/flora sync`.

Keeping the credentials in the helper rather than in the skill means the skill
can be committed and read by anyone, and rotating a secret touches one file.
