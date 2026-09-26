# Installing Flora

About 30 minutes, most of it waiting for downloads.

## Before you start

- A Linux server with **systemd**, and root on it.
- **4 GB RAM** and **15 GB free disk** as a floor. Mattermost and Postgres want
  about 1 GB between them; the rest is npm trees, sessions and repository clones.
- The server's IP address.
- At least one API key for an OpenAI-compatible provider.

### Prerequisites

```bash
sudo apt update
sudo apt install -y git curl python3 openssl apache2-utils \
                    docker.io docker-compose-v2
```

nginx is **not** in that list: by default Flora runs her own in a container
(`FLORA_NGINX=docker`), writes nothing to `/etc/nginx`, and leaves any nginx
already on the machine alone. Set `FLORA_NGINX=host` to use the host's instead,
and then `apt install nginx` as well.

On Debian, or with Docker's own repository, the compose package is called
`docker-compose-plugin` instead of `docker-compose-v2`.

**Node.js needs its own step.** TokenRing and OpenCode are both Node programs
and need **≥ 20.11**, which is newer than what Debian and most Ubuntu releases
ship. `apt install nodejs` will usually give you something too old:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v      # must print v20.11 or newer
```

Or, if you would rather not install it system-wide, use
[nvm](https://github.com/nvm-sh/nvm) and `nvm install 22` — but then the systemd
units need `node` on their `PATH`, so a system install is the simpler path.

### Check before you commit to anything

```bash
./bin/flora preflight
```

It changes nothing. Anything it marks `[must]` blocks the install and is listed
again at the end with the exact command that fixes it; `[warn]` is advisory and
can be ignored. A `[warn]` about another vhost owning `:80` as `default_server`
is expected and harmless — Flora only adds name-based vhosts.

## If you already run Hermes or OpenCode

Flora installs her own copy of each and uses nothing you already have. Your
installs are not read, not written, not upgraded and not even looked at.

| | Yours | Flora's |
|---|---|---|
| Hermes binary | `~/.local/bin/hermes` | `state/hermes/agent/.hermes/bin/hermes` |
| Hermes runtime + tools | yours | `state/hermes/tools` (its own Python, ripgrep, …) |
| Hermes data | `~/.hermes` | `state/hermes/home` |
| Hermes `$HOME` | yours | `state/hermes/fs-home` |
| OpenCode binary | wherever you put it | `state/opencode/npm/…` |
| OpenCode data | `~/.config/opencode`, `~/.local/share/opencode` | `state/opencode/**` |

The wrappers **do not fall back to `PATH`**. If Flora's copy is missing they
fail with an error telling you to install it, rather than silently running yours
against her data.

What genuinely is shared: `node`, `git`, `curl` and the C library — the language
runtimes any program on the machine uses. Flora installs no npm or pip packages
globally; both agents' dependency trees live under `state/`.

That isolation costs disk: about **2.5 GB** for Hermes (it brings its own Python
runtime and tool store) and **700 MB** for OpenCode.

```bash
hermes                 # still your install
bin/flora hermes       # Flora's
bin/flora shell        # a shell where `hermes` and `opencode` mean Flora's
```

Two consequences worth knowing:

- **Ports.** If your own OpenCode or Hermes UI is on 4096 or 9119, preflight
  blocks with the pid holding it. Stop it, or set `FLORA_PORT_OPENCODE=4097`.
- **Flora has her own `~/.ssh` and `~/.gitconfig`.** She will not use your keys.
  Give her one of her own if she needs to push over SSH — see
  [07-integrations.md](07-integrations.md).

## 1. Configure

```bash
cd /opt/flora
cp flora.env.example flora.env
```

Edit `flora.env`. Usually one line:

```ini
FLORA_IP=192.0.2.10        # the address people will type
```

That is all, because the default addressing needs no DNS:

```ini
FLORA_ROUTING=ports        # http://<ip>:<port> per service
FLORA_PUBLIC_DASHBOARD=7080
FLORA_PUBLIC_HERMES=7081
FLORA_PUBLIC_OPENCODE=7082
FLORA_PUBLIC_CHAT=7083
FLORA_PUBLIC_TOKENS=7084
```

`bin/flora preflight` checks every one of those ports, plus the internal
4000/9119/4096/8065, and names anything holding them.

Prefer `http://hermes.flora.com` to a port number? Set `FLORA_ROUTING=hosts` and
see [01-architecture.md](01-architecture.md#the-alternative-hostnames) — it
works, but it needs an `/etc/hosts` line on every machine that browses it.

## What's automated and what's yours to do

| | Who does it | How |
|---|---|---|
| §2 Bootstrap | **`bin/flora`, fully automated** | installs and starts all four services |
| §3 Finish TokenRing | **you, in TokenRing's own web UI** | Flora cannot add your provider keys for you — there is no supported way to do that except through its dashboard |
| §4 Finish Mattermost | **you, in Mattermost's own web UI** | same reason: issuing a bot token has no scriptable interface |
| §6 Verify | **`bin/flora doctor`, fully automated** | confirms what you did in §3/§4 actually works — it never performs those steps itself |

§3 and §4 are not gaps to be scripted around later. See
[01-architecture.md](01-architecture.md#a-design-rule-official-interfaces-only-never-internals)
for why Flora deliberately stops at the edge of what each product's own
interface actually supports.

## 2. Bootstrap — automated

```bash
sudo ./bin/flora bootstrap
```

That runs, in order, and each step is safe to re-run on its own:

| Step | Script | What it does |
|---|---|---|
| preflight | `scripts/preflight.sh` | checks commands, versions, ports, disk. Changes nothing |
| secrets | `scripts/bootstrap-secrets.sh` | generates passwords and keys into `secrets/flora.env` |
| render | `scripts/render.sh` | turns `config/templates/**` into live configs |
| tokenring | `scripts/install-tokenring.sh` | clones and builds TokenRing |
| hermes | `scripts/install-hermes.sh` | runs the upstream installer with `HERMES_HOME` set |
| opencode | `scripts/install-opencode.sh` | `npm install` into `state/opencode/npm` |
| mattermost | `scripts/install-mattermost.sh` | creates bind mounts, chowns to uid 2000, pulls images |
| skills | `scripts/skills-sync.sh` | links the shared brain into both agents |
| hosts | `scripts/install-hosts.sh` | writes `/etc/hosts` here, prints the client line |
| nginx | `scripts/install-nginx.sh` | installs the vhosts, validates, reloads |
| systemd | `scripts/install-systemd.sh` | installs and enables units and timers |

At the end it starts `flora.target` and prints what is still missing.

## 3. Finish TokenRing -- manual, in TokenRing's own UI

Open **http://&lt;your ip&gt;:7084** — `bin/flora creds` prints the exact link.

```bash
bin/flora tokenring password     # the generated dashboard password
```

1. Log in.
2. **Settings → Providers → Default → Edit** — set the base URL of your real
   provider, *including* the `/v1` segment.
3. **Upstream keys** — add everyone's real provider keys. This is the pool.
4. **Virtual keys → Issue** — create one for Flora. Copy the `sk-ring-…` value;
   it is shown once.
5. Store it:

```bash
bin/flora tokenring key sk-ring-xxxxxxxxxxxx
```

That writes it to `secrets/flora.env`, re-renders both agent configs and
restarts them. Both now authenticate to the pool with that key.

## 4. Finish Mattermost -- manual, in Mattermost's own UI

Open **http://&lt;your ip&gt;:7083**.

1. Create the first account — it becomes the **system admin**. Use the address
   in `FLORA_ADMIN_EMAIL`.
2. Create the team (call it `flamingo`).
3. **System Console → Integrations → Bot Accounts → Enable**, then save.
4. **Integrations → Bot Accounts → Add** — username `flora`. Copy the token;
   it is shown once.
5. **Profile → Settings → Security → View ID** for each person who should be
   allowed to talk to Flora. Collect those 26-character IDs.
6. Store both:

```bash
bin/flora secrets edit
#   MATTERMOST_BOT_TOKEN=<the bot token>
#   MATTERMOST_ALLOWED_USERS=<id>,<id>,<id>      # empty means nobody
bin/flora restart gateway
```

7. Invite the bot into a channel (`/invite @flora`) and say hello. In a channel
   she answers when mentioned; in a DM she answers everything.

## 5. Give the team access

```bash
bin/flora user add sara          # prints a generated password, once
bin/flora user list
bin/flora creds                  # every login and link, in one place
```

Send each person their password and one link — the dashboard:

```
http://<your ip>:7080
```

Nothing to install or configure on their side. The dashboard lists the four
services and links to them, rebuilding each link against whatever address they
used to reach it, so the same page works over the LAN, a VPN or `localhost`.

(If you chose `FLORA_ROUTING=hosts` instead, this is where each of them needs
the `/etc/hosts` line from `bin/flora hosts --print`.)

## 6. Verify -- automated

```bash
bin/flora doctor
```

Everything should be green. If it is not, the message says which script fixes
it. [08-troubleshooting.md](08-troubleshooting.md) covers the rest.

## 7. Turn it into a git repository

Strongly recommended — it makes every skill and config change reviewable.

```bash
cd /opt/flora
git init && git add -A && git commit -m "Flora platform"
git remote add origin ssh://gerrit.example.com/infra/flora
git push -u origin main
```

`.gitignore` already excludes `state/`, `secrets/`, `flora.env` and `workspace/`.
Confirm before the first push:

```bash
git status --porcelain | grep -E 'secrets/|state/' && echo "STOP — fix .gitignore"
```

## Upgrading later

```bash
FLORA_UPDATE=1 bin/flora install hermes
FLORA_UPDATE=1 bin/flora install opencode
bin/flora install tokenring        # always fetches and rebuilds if it moved
bin/flora render && bin/flora restart
```

Copy `state/`, `shared/`, `secrets/` and `flora.env` aside first — that is the
only way back. See [04-operations.md](04-operations.md#moving-or-copying-the-platform).
