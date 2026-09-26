# Architecture

## A design rule: official interfaces only, never internals

Flora installs and configures Hermes, OpenCode, Mattermost and TokenRing
exclusively through the interface each one publishes for exactly that purpose:
Hermes' own official installer script, OpenCode's published npm package,
Mattermost's official Docker image driven by its documented `MM_*` environment
variables, TokenRing's own REST API (the same one its dashboard calls). Nothing
here reads another project's source to learn an undocumented behavior and
depends on it, patches a vendored file, or drives a private/internal endpoint
not meant for scripted use. That is deliberate: an internal detail can change
in any release without notice, and code depending on it breaks silently,
whereas a documented interface is the one contract each project actually
commits to keeping stable.

The corollary: **when a step has no official, scriptable interface, Flora does
not script it.** Issuing a Mattermost bot token and wiring up TokenRing's first
provider and upstream keys are exactly this — there is no supported
non-interactive way to do either, so [02-install.md](02-install.md) has you do
them yourself, through each product's own web UI, and Flora's role is limited
to storing what you produce (`bin/flora tokenring key`, `bin/flora secrets
edit`) and then verifying health and connectivity (`bin/flora doctor`) — never
attempting the configuration itself by another route. If you ever find a
script here reasoning about *why* something behaves a certain way in Hermes,
OpenCode or Mattermost rather than just calling their documented interface and
checking the result, that is a bug in this repository, not a feature.

## The four long-running services

| # | Service | What it is | You browse | Backend | Supervised by |
|---|---------|-----------|------------|---------|---------------|
| — | **Dashboard** | a launcher listing the four | `:7080` | static | nginx |
| 1 | **TokenRing** | OpenAI-compatible proxy over a pool of provider API keys | `:7084` | 127.0.0.1:4000 | `flora-tokenring.service` |
| 2 | **Hermes** | The agent: chat UI, sessions, memory, skills, cron | `:7081` | 127.0.0.1:9119 | `flora-hermes-dashboard.service` |
| 3 | **OpenCode** | Browser coding agent | `:7082` | 127.0.0.1:4096 | `flora-opencode.service` |
| 4 | **Mattermost** | Team chat, where Flora answers as a bot | `:7083` | 127.0.0.1:8065 | `flora-mattermost.service` |

Plus two supporting processes:

- **Hermes gateway** (`flora-hermes-gateway.service`) — the process that holds
  the Mattermost connection. Separate from the dashboard because restarting the
  UI should not drop the chat bot, and the reverse.
- **nginx** (`flora-nginx.service`) — by default Flora runs her own, in a
  container, with host networking. Nothing is written to `/etc/nginx` and the
  machine does not need nginx installed. `FLORA_NGINX=host` uses the host's
  nginx instead, via `/etc/nginx/conf.d/flora.conf`.

So: four things the team sees, **seven** units to keep alive (six with a host
nginx). `flora.target`
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

## Addressing

Default (`FLORA_ROUTING=ports`): **nginx listens on one port per service**, and
you reach each at `http://<server ip>:<port>`.

```
http://192.0.2.10:7080     dashboard — the only link anyone needs
http://192.0.2.10:7081     Hermes
http://192.0.2.10:7082     OpenCode
http://192.0.2.10:7083     Mattermost
http://192.0.2.10:7084     TokenRing
```

No DNS, no `/etc/hosts`, nothing for a teammate to configure — they open the
dashboard and click. It also works over `localhost`, a VPN address or a LAN IP
with no extra configuration, because the dashboard rebuilds its links against
whatever host the browser used to reach it.

**Hermes is the one tile that does not share this flexibility.** It enforces
DNS-rebinding protection and only accepts the exact address declared in
`FLORA_IP`, so a team reaching Flora by more than one address will find the
other three services and the dashboard itself work from all of them, while
Hermes gives a "Invalid Host header" 400 to everyone except whoever used that
one address. See [08-troubleshooting.md](08-troubleshooting.md#hermes-says-invalid-host-header).

The backends stay on `127.0.0.1`. nginx is the only thing listening publicly,
which is what lets one account list guard both agent UIs — and both of them can
run shell commands on this machine.

Ports are set by `FLORA_PUBLIC_*` in `flora.env`; change any that clash.

### Whose nginx

`FLORA_NGINX=docker` (default) runs `nginx:1.27-alpine` from
`state/nginx/docker-compose.yml`. It uses **host networking**, for a specific
reason: the backends listen on `127.0.0.1`, and a bridge-networked container
cannot reach a host loopback socket — the alternative would be binding the
backends to `0.0.0.0`, which is exactly what this design avoids. Host networking
also means the generated `flora.conf` is byte-identical under either runtime:
one file, two ways to serve it.

Two consequences worth knowing:

- The image ships its own `default.conf` on port 80. Under host networking that
  collides with anything already on `:80`, so the compose file masks it with
  `/dev/null`.
- Only four paths are mounted, read-only except the logs. `secrets/` is not one
  of them.

`FLORA_NGINX=host` writes `/etc/nginx/conf.d/flora.conf` and reloads the host's
nginx, validating first and restoring the previous file if validation fails.

### The alternative: hostnames

`FLORA_ROUTING=hosts` switches to name-based virtual hosts on a single port
(`http://hermes.flora.com`). It is tidier to read and it needs a line in
`/etc/hosts` **on every machine that browses it**:

```
192.0.2.10  flora.com hermes.flora.com opencode.flora.com chat.flora.com tokens.flora.com
```

Hosts files have no wildcards, so every name is listed explicitly and adding a
service later means editing every client. `bin/flora hosts --print` gives you the
line. Port mode exists because that coordination is rarely worth it for a team
on one server.

## Where the data is

| Path | Holds | In git | Recreatable |
|---|---|---|---|
| `shared/` | skills, instructions, MCP servers | **yes** | from git |
| `state/hermes/home/` | sessions, memories, cron jobs, credentials | no | **no** |
| `state/hermes/agent/`, `tools/` | Flora's own Hermes checkout, Python runtime and tools (~2.5G) | no | yes, reinstall |
| `state/opencode/` | sessions, auth, the binary itself (~700M) | no | binary yes, sessions no |
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

`state/bin/hermes` and `state/bin/opencode` are generated wrappers. Each exports
`HOME` and the `XDG_*` variables into the Flora tree before exec'ing a binary
that also lives in the tree:

| | Binary | `HOME` |
|---|---|---|
| Hermes | `state/hermes/agent/.hermes/bin/hermes` | `state/hermes/fs-home` |
| OpenCode | `state/opencode/npm/node_modules/.bin/opencode` | `state/opencode/home` |

Neither wrapper falls back to a binary on `PATH`. If this machine already had
Hermes or OpenCode installed, those installs are untouched and unused — Flora
builds her own copy of each, including Hermes' Python runtime and tools. The
only things shared with the rest of the system are the language runtimes
themselves (`node`, and the `git`/`curl` the installers call).

**Always go through the wrappers.** A bare `hermes` is the other install, if
there is one. `bin/flora hermes …`, `bin/flora opencode …` and `bin/flora shell`
do it for you.

## What is deliberately not here

- **No TLS.** Plain HTTP, addressed by IP. If this ever gets a public address,
  see [09-security.md](09-security.md) first.
- **No SSO.** HTTP basic auth on the agent UIs, real accounts in Mattermost and
  TokenRing. [05-accounts-and-auth.md](05-accounts-and-auth.md) explains how to
  upgrade.
- **No high availability.** One box, and no backup machinery — see
  [04-operations.md](04-operations.md#moving-or-copying-the-platform) for what
  copying the directory does and does not cover.
