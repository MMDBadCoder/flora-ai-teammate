# Installing Flora

About 30 minutes, most of it waiting for downloads.

## Before you start

- A Linux server with **systemd**, **nginx**, **Docker** and **Node ≥ 20.11**.
- **4 GB RAM** and **15 GB free disk** as a floor. Mattermost and Postgres want
  about 1 GB between them; the rest is npm trees, sessions and repository clones.
- Root on that server, and its IP address.
- At least one API key for an OpenAI-compatible provider.

```bash
sudo apt install -y nginx docker.io docker-compose-plugin git curl apache2-utils
```

## 1. Configure

```bash
cd /opt/flora
cp flora.env.example flora.env
```

Edit `flora.env`. Only two lines usually need changing:

```ini
FLORA_IP=192.0.2.10        # what clients will connect to
FLORA_DOMAIN=flora.com     # the suffix for all five hostnames
```

Check the ports are free on your box (`bin/flora preflight` does this) and
adjust `FLORA_PORT_*` if something already owns 4000, 9119, 4096 or 8065.

## 2. Bootstrap

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

## 3. Finish TokenRing

Open **http://tokens.flora.com** (on the server: `curl` it, or add the hosts
line to your own machine first — step 5).

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

## 4. Finish Mattermost

Open **http://chat.flora.com**.

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

On every teammate's machine:

```bash
bin/flora hosts --print          # run this on the server to get the exact line
```

```bash
# Linux / macOS
sudo sh -c 'echo "192.0.2.10 flora.com hermes.flora.com opencode.flora.com chat.flora.com tokens.flora.com" >> /etc/hosts'

# Windows: open Notepad as Administrator, edit
#   C:\Windows\System32\drivers\etc\hosts
```

Then create their UI accounts:

```bash
bin/flora user add sara          # prints a generated password, once
bin/flora user list
```

Send each person their password over Mattermost, and the dashboard URL:
**http://flora.com**.

## 6. Verify

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
