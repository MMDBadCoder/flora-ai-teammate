# Architecture

## The four long-running services

| # | Service | What it is | Port | Hostname | Supervised by |
|---|---------|-----------|------|----------|---------------|
| 1 | **TokenRing** | OpenAI-compatible proxy over a pool of provider API keys | 4000 | `tokens.flora.com` | `flora-tokenring.service` |
| 2 | **Hermes** | The agent: chat UI, sessions, memory, skills, cron | 9119 | `hermes.flora.com` | `flora-hermes-dashboard.service` |
| 3 | **OpenCode** | Browser coding agent | 4096 | `opencode.flora.com` | `flora-opencode.service` |
| 4 | **Mattermost** | Team chat, where Flora answers as a bot | 8065 | `chat.flora.com` | `flora-mattermost.service` |

Plus two supporting processes:

- **Hermes gateway** (`flora-hermes-gateway.service`) — the process that holds
  the Mattermost connection. Separate from the dashboard because restarting the
  UI should not drop the chat bot, and the reverse.
- **nginx** — already on the box; Flora adds one config file to it.

So: four things the team sees, **six** units to keep alive. `flora.target`
groups them, which is what `bin/flora up` and `down` actually drive.

## Why TokenRing sits in the middle

Every LLM call from both agents goes to `http://127.0.0.1:4000/v1`, never to a
provider directly. That buys four things:

- **One place for keys.** Everyone's provider key goes into the pool once.
  Neither agent ever holds a real provider key — they hold an `sk-ring-…` key
  that only works against this proxy, on this machine.
- **Rate limits stop hurting.** TokenRing tracks per-key usage windows and routes
  around a saturated credential instead of failing the request.
- **Usage accounting.** Per-key request counts, token counts, error rates and
  latency, in its dashboard. When someone asks what Flora costs, that is the answer.
- **One switch.** Change the upstream provider or model in one place and both
  agents follow.

The trade-off: TokenRing is a single point of failure for the agents. It is a
small Node process with a SQLite database and `Restart=always`; if it is down,
both agents return provider errors and `bin/flora status` shows it immediately.

## Why two agents

They are good at different things, and the team gets to pick:

- **Hermes** is the *teammate*. Persistent memory across sessions, a skills
  system, cron jobs, and it is the one that speaks Mattermost. Ask it questions,
  give it standing jobs.
- **OpenCode** is the *coding surface*. A better editing loop for sitting with
  a repository and driving a change to completion.

They are kept interchangeable on the four things that matter — skills,
instructions, tool servers, model — so the answer does not depend on which tab
you opened. See [06-skills-and-sync.md](06-skills-and-sync.md).

## Routing without DNS

`/etc/hosts` on every client maps five names to the server's IP. nginx then
routes by `Host:` header — classic name-based virtual hosting. No DNS, no
certificates, no coordination with anyone.

```
192.0.2.10  flora.com hermes.flora.com opencode.flora.com chat.flora.com tokens.flora.com
```

**`/etc/hosts` has no wildcards.** `*.flora.com` does not work, in any OS. Every
name is listed explicitly, which means adding a fifth service later costs one
line on each teammate's machine. `bin/flora hosts --print` prints the current line.

On the server itself the names point at `127.0.0.1`, so Flora can reach her own
services by name.

## Where the data is

| Path | Holds | In git | Recreatable |
|---|---|---|---|
| `shared/` | skills, instructions, MCP servers | **yes** | from git |
| `state/hermes/home/` | sessions, memories, cron jobs, credentials | no | **no** |
| `state/opencode/` | sessions, auth, the binary itself | no | binary yes, sessions no |
| `state/tokenring/data/` | the key pool + `master.key` | no | **no** |
| `state/mattermost/` | messages, uploads, Postgres | no | **no** |
| `secrets/` | every credential | no | **no** |
| `workspace/` | repository clones | no | yes, from Gerrit |

The bolded rows are the ones a `rm -rf` would actually cost you. They all sit
under this one directory, which is the point of the layout — see
[04-operations.md](04-operations.md#moving-or-copying-the-platform).

`shared/` is tracked in git on purpose: a skill change is a diff you can read,
blame and revert, including the ones Flora writes herself. `git log shared/skills`
is the record of how her knowledge changed over time — and, since `shared/` is
the only part of the platform that is genuinely hard to recreate by hand, pushing
that repository to a remote is the closest thing here to insurance.

## Process model

```
systemd
├── flora.target
│   ├── flora-tokenring.service         node server/dist/main.js
│   ├── flora-hermes-dashboard.service  state/bin/hermes dashboard
│   ├── flora-hermes-gateway.service    state/bin/hermes gateway run
│   ├── flora-opencode.service          state/bin/opencode web
│   └── flora-mattermost.service        docker compose up -d  (2 containers)
└── timers
    ├── flora-skills-sync.timer   every 5 min   reconcile the shared brain
    ├── flora-skills-sync.path    on change     same, but immediate
    ├── flora-health.timer        every 1 min   write the dashboard snapshot
    └── flora-housekeeping.timer  Sun 04:00     rotate, prune, vacuum
```

`state/bin/hermes` and `state/bin/opencode` are generated wrappers. They export
`HERMES_HOME`, `OPENCODE_CONFIG_DIR`, the `XDG_*` variables and (for OpenCode)
`HOME` before exec'ing the real binary. **Always go through them** — a bare
`hermes` call would read `~/.hermes` and start building a second, un-backed-up
brain beside this one. `bin/flora hermes …` and `bin/flora shell` do this for you.

## What is deliberately not here

- **No TLS.** Plain HTTP on an offline network. If this ever gets a public
  address, see [09-security.md](09-security.md) first.
- **No SSO.** HTTP basic auth on the agent UIs, real accounts in Mattermost and
  TokenRing. [05-accounts-and-auth.md](05-accounts-and-auth.md) explains how to
  upgrade.
- **No high availability.** One box, and no backup machinery — see
  [04-operations.md](04-operations.md#moving-or-copying-the-platform) for what
  copying the directory does and does not cover.
