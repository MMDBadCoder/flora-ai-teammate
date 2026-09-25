# Configuration

## The rule

```
config/templates/**  →  bin/flora render  →  state/**
     you edit this                            never edit this
```

Everything under `state/` is generated output. A hand edit there survives until
the next render and then vanishes — usually at the worst moment. If you need a
change to stick, it goes in the template.

Two inputs feed the renderer:

| File | Holds | Mode | In git |
|---|---|---|---|
| `flora.env` | ports, hostnames, names, toggles | 0644 | no (`flora.env.example` is) |
| `secrets/flora.env` | passwords, tokens, API keys | 0600 | **never** |

`{{VAR}}` in a template is replaced by the environment variable of that name. A
missing variable is a hard error — the renderer refuses rather than writing a
half-finished config.

## flora.env

### Identity

| Variable | Default | Notes |
|---|---|---|
| `FLORA_HOME` | *derived* | Not set in the file — it is wherever the scripts live |
| `FLORA_DOMAIN` | `flora.com` | Suffix for all hostnames |
| `FLORA_IP` | detected | What clients put in `/etc/hosts` |
| `FLORA_TZ` | `UTC` | Mattermost and the timers use it |
| `FLORA_USER` | `root` | The account the units run as |

### Hostnames

`FLORA_HOST_DASHBOARD`, `_HERMES`, `_OPENCODE`, `_CHAT`, `_TOKENS`. Changing one
means `bin/flora render && bin/flora nginx && bin/flora hosts`, **and** an edit
to every teammate's `/etc/hosts`.

### Networking

| Variable | Default | Notes |
|---|---|---|
| `FLORA_BIND_ADDR` | `127.0.0.1` | Where the backends listen. See below |
| `FLORA_HTTP_PORT` | `80` | The port nginx serves the Flora vhosts on |
| `FLORA_PORT_TOKENRING` | `4000` | |
| `FLORA_PORT_HERMES` | `9119` | |
| `FLORA_PORT_OPENCODE` | `4096` | |
| `FLORA_PORT_MATTERMOST` | `8065` | |

**About `FLORA_BIND_ADDR`.** The UIs are reachable on `0.0.0.0` either way —
nginx is the thing listening on all interfaces, and it proxies to the backends.
The question is only whether the backends *also* answer directly on their own
ports, bypassing nginx and therefore bypassing the login.

Both agent UIs can run shell commands on this machine. An unauthenticated one on
a routable port is a remote shell for anyone who can reach it. So:

- `FLORA_BIND_ADDR=127.0.0.1` + `FLORA_AUTH_MODE=nginx` — the default. One
  account list, one door.
- `FLORA_BIND_ADDR=0.0.0.0` + `FLORA_AUTH_MODE=backend` — direct access too,
  with each backend enforcing its own password.

The renderer **refuses** `0.0.0.0` with `FLORA_AUTH_MODE=nginx`, because that
combination is an open shell and is almost always a mistake.

### Models

| Variable | Default | Notes |
|---|---|---|
| `FLORA_MODEL_MAIN` | `gpt-5.1` | Must be a model name your upstream accepts |
| `FLORA_MODEL_SMALL` | `gpt-5.1-mini` | Summarising, titles, compression |
| `FLORA_TOKENRING_UPSTREAM` | OpenAI | Only seeds the first provider; change it in the TokenRing UI afterwards |

TokenRing passes model names through to the upstream unchanged, so these are
whatever your provider calls them. Changing them needs a render and a restart of
both agents.

### Skills, housekeeping, toggles

| Variable | Default | Notes |
|---|---|---|
| `FLORA_HERMES_SKILL_CATEGORY` | `team` | The Hermes category that maps onto `shared/skills` |
| `FLORA_SKILLS_EXPORT_BUNDLED` | `false` | Also expose Hermes' own bundled skills to OpenCode |
| `FLORA_LOG_KEEP_DAYS` | `30` | |
| `FLORA_SESSION_KEEP_DAYS` | `90` | |
| `FLORA_HOUSEKEEP_DOCKER` | `false` | Global Docker pruning. Leave off on a shared box |
| `FLORA_ENABLE_*` | `true` | Per-service on/off, honoured by `install-systemd.sh` |

Undocumented but honoured: `FLORA_TOKENRING_REPO`, `FLORA_TOKENRING_REF`,
`FLORA_OPENCODE_PACKAGE`, `FLORA_SKILLS_GIT`, `FLORA_UPDATE`.

## secrets/flora.env

Generated on first run; existing values are never overwritten.

| Key | Where it comes from |
|---|---|
| `TOKENRING_ADMIN_PASSWORD` | generated · `bin/flora tokenring password` |
| `TOKENRING_ENCRYPTION_KEY` | generated · **encrypts the pooled provider keys** |
| `MATTERMOST_DB_PASSWORD` | generated |
| `HERMES_DASHBOARD_PASSWORD` | generated · only used in `backend` auth mode |
| `OPENCODE_SERVER_PASSWORD` | generated · only used in `backend` auth mode |
| `FLORA_ADMIN_PASSWORD` | generated · the first UI account |
| `FLORA_TOKENRING_KEY` | **you** · issued in the TokenRing dashboard |
| `MATTERMOST_BOT_TOKEN` | **you** · System Console → Bot Accounts |
| `MATTERMOST_ALLOWED_USERS` | **you** · comma-separated user IDs. Empty = nobody |
| `GERRIT_*`, `CONFLUENCE_*` | **you** · see [07-integrations.md](07-integrations.md) |
| `FLORA_HERMES_BIN` | written by the installer |

```bash
bin/flora secrets show     # masked
bin/flora secrets edit     # $EDITOR, then re-renders
```

`TOKENRING_ENCRYPTION_KEY` deserves special care: lose it and every pooled
provider key in the database is unreadable. It exists in exactly one place —
`secrets/flora.env` — and nothing regenerates it. If you copy one file off this
machine, copy that one.

## Per-file map

| Template | Renders to | Read by |
|---|---|---|
| `hermes/config.yaml.tmpl` | `state/hermes/home/config.yaml` | Hermes |
| `hermes/env.tmpl` | `state/hermes/home/.env` (0600) | Hermes, every invocation |
| `opencode/opencode.json.tmpl` | `state/opencode/config/opencode.json` | OpenCode |
| `tokenring/env.tmpl` | `state/tokenring/tokenring.env` (0600) | the unit |
| `mattermost/docker-compose.yml.tmpl` | `state/mattermost/docker-compose.yml` | docker compose |
| `nginx/flora.conf.tmpl` | `state/nginx/flora.conf` → `/etc/nginx/conf.d/` | nginx |
| `dashboard.html.tmpl` | `web/dashboard/index.html` | browsers |
| `systemd/*.tmpl` | `state/systemd/*` → `/etc/systemd/system/` | systemd |
| `bin/{hermes,opencode}.tmpl` | `state/bin/*` | you and the units |

## Changing something safely

```bash
$EDITOR config/templates/hermes/config.yaml.tmpl
bin/flora render                    # shows exactly which files changed
bin/flora restart hermes gateway
bin/flora status
```

If a change reaches into nginx or systemd:

```bash
sudo bin/flora nginx                # validates before reloading; rolls back on error
sudo bin/flora systemd              # reinstalls units, reloads the daemon
```

## Experimenting

For a quick one-off, Hermes' own CLI is fine:

```bash
bin/flora hermes config set agent.max_iterations 500
```

That writes straight into `state/hermes/home/config.yaml` — and the next
`bin/flora render` will wipe it. When you want it to stick, fold it back into
`config/templates/hermes/config.yaml.tmpl`.
