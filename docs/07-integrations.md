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

`MATTERMOST_REPLY_MODE` controls threading: `thread` nests her answers instead
of flooding the channel; `off` (Flora's default) posts them directly, top-level.
Change it in `config/templates/hermes/env.tmpl`, then
`bin/flora render && bin/flora restart gateway`.
`group_sessions_per_user` keeps two people's context apart in a shared channel.

**"Mattermost unreachable" banner.** Its websocket is built from `SiteURL`, which
Flora derives from `FLORA_IP`. If people reach it by a different name, set
`FLORA_URL_CHAT_OVERRIDE` to the address they type. `bin/flora doctor` compares
the two. See
[08-troubleshooting.md](08-troubleshooting.md#please-check-connection-mattermost-unreachable--websocket-port).

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

### Gerrit as an MCP tool server

Setting `GERRIT_URL` and `GERRIT_HTTP_PASSWORD` is all it takes: a Gerrit MCP
server is configured for **both** agents automatically on the next
`bin/flora render`. Nothing to enable, and if either value is blank it simply
does not appear, rather than showing up and failing on first use.

```bash
bin/flora secrets edit      # GERRIT_URL, GERRIT_USER, GERRIT_HTTP_PASSWORD
bin/flora sync
```

Six tools: `gerrit_list_changes`, `gerrit_get_change`, `gerrit_get_diff`,
`gerrit_get_comments`, `gerrit_post_review`, `gerrit_list_projects`. That is
enough for Flora to read a change and its diff, see what reviewers asked for, and
post a review — while pushing changes stays with git and the `gerrit-change`
skill, since that needs a working tree.

### Is it up?

It is never "up" — and that is not a fault. An MCP stdio server is **not a
service**: the agent starts it as a child process when it needs a tool, talks
JSON-RPC over stdin and stdout, and it exits. Nothing listens on a port, nothing
appears in `systemctl`, and `ps` shows it only during a tool call.

```bash
bin/flora mcp              # what is configured, and what is waiting on what
bin/flora mcp --probe      # start each one and actually use it
```

```
gerrit       ready    in opencode.json
             ✓ starts and answers -- flora-gerrit, 6 tools;
               gerrit_list_projects returned: infra/flora
```

`--probe` does more than start the server. A handshake alone proves nothing
useful: `initialize` and `tools/list` never reach Gerrit, so they succeed with
completely wrong credentials. Each server therefore names a read-only
`probe_tool` in `shared/mcp/servers.json`, and the probe calls it, so the three
outcomes are distinguishable:

```
✓ ... gerrit_list_projects returned: infra/flora
✗ ... gerrit_list_projects failed: Gerrit refused the credentials (HTTP 401) ...
✗ ... gerrit_list_projects failed: cannot reach http://... Connection refused
```

It is Flora's own server (`scripts/mcp/gerrit_mcp.py`), standard library only,
speaking Gerrit's documented REST API — the same API `scripts/integrations/gerrit.sh`
uses. The npm packages offering this are a 404, an unpublished name, and a single
0.0.1 release from an unknown author, which is not what should hold a team's
review credentials.

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

## Scribe — meeting audio to text

Offline Persian transcription, upstream [voice-2-text](https://github.com/MMDBadCoder/voice-2-text).
Optional and off by default.

```bash
# flora.env
FLORA_ENABLE_SCRIBE=true
FLORA_SCRIBE_REF=0.2.0              # a pinned upstream release
FLORA_SCRIBE_ASR_BACKEND=stub       # or faster_whisper, once a model is in place
```

```bash
bin/flora install scribe            # clone at the tag, render, build the image
bin/flora render && sudo bin/flora nginx && sudo bin/flora systemd
bin/flora up scribe
```

It appears on the dashboard as a fifth tile and at `http://<ip>:7085`. It has
**its own accounts**, so like Mattermost and TokenRing it is not put behind
Flora's account list; set `SCRIBE_ADMIN_PHONE` and `SCRIBE_ADMIN_PASSWORD` in
`secrets/flora.env` before the first start to bootstrap an administrator, or
leave them blank and register through its UI.

### stub versus real transcription

`stub` needs no model and fabricates text. Everything else is real — the queue,
progress, cancellation, the exports — so it is the honest way to decide whether
the module is worth a model download. For real transcription, follow upstream's
`docs/SETUP.md` to place a model in `state/scribe/models`, then set
`FLORA_SCRIBE_ASR_BACKEND=faster_whisper` and re-render.

Upstream sizes one accurate-model worker at about **8GB RAM**; preflight warns
when a real backend is selected on a machine with less.

### What Flora does and does not do

It pins a released tag, builds with upstream's own `docker-compose.yml`, and
configures it through the `.env` keys upstream publishes — the same black-box
treatment TokenRing gets. The single addition is a Compose override file that
moves `data` and `models` to `state/scribe/`, so reinstalling or moving to a new
release never touches recordings and transcripts. Nothing reads upstream's
source to decide what to do.

Worker pool sizing is upstream's rule, exposed as two settings:
`FLORA_SCRIBE_WORKERS` x `FLORA_SCRIBE_CPU_THREADS` should stay at or below
cores − 1.

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
