# Operations

## Daily

```bash
bin/flora status                 # health table: HTTP probe + systemd state
bin/flora doctor                 # the full sweep, when something looks off
bin/flora logs gateway -f        # follow a log
```

`status` calls each service over HTTP. A process that is running but wedged
still reports `down`, which is the point — systemd's `active` alone is not health.

## Starting and stopping

```bash
bin/flora up                     # everything (systemctl start flora.target)
bin/flora up opencode            # just one
bin/flora restart hermes gateway
bin/flora down                   # everything
```

Service names: `tokenring`, `hermes` (the dashboard), `gateway` (the chat bot),
`opencode`, `mattermost`.

Start order matters once: TokenRing should be up before the agents, or their
first model call fails. The units declare it, and `Restart=always` cleans up the
race anyway.

## Logs

| Command | File |
|---|---|
| `bin/flora logs tokenring` | `state/logs/tokenring.log` |
| `bin/flora logs hermes` | `state/logs/hermes-dashboard.log` |
| `bin/flora logs gateway` | `state/logs/hermes-gateway.log` |
| `bin/flora logs opencode` | `state/logs/opencode.log` |
| `bin/flora logs mattermost` | `docker compose logs` |
| `bin/flora logs nginx` | `state/logs/nginx-*.log` |

Add `-f` to follow, or a number for that many lines. Everything is also in
`journalctl -u flora-*`. Logs over 50 MB are rotated and gzipped weekly, and
archives older than `FLORA_LOG_KEEP_DAYS` are deleted.

## Scheduled work

```bash
systemctl list-timers 'flora-*'
```

| Timer | When | Does |
|---|---|---|
| `flora-health` | every minute | writes `state/dashboard/health.json` for the launcher |
| `flora-skills-sync` | every 5 min | reconciles the shared brain |
| `flora-skills-sync.path` | on change | same, immediately, when a skill directory changes |
| `flora-housekeeping` | Sun 04:00 | rotate logs, prune sessions, vacuum databases |

Run any of them now:

```bash
bin/flora housekeep
sudo systemctl start flora-skills-sync.service
```

The path unit watches the skill *directories*, so a new or deleted skill fires
at once; an edit inside an existing skill is picked up by the five-minute timer.
Recursive watching is not something systemd does, and polling every file would
cost more than it saves.

### Hermes' own cron

Separate from the systemd timers, and for a different job. The systemd timers
run **infrastructure** work — shell scripts with no judgement in them. Hermes'
cron runs **agent** work: jobs that need context, tools and a model.

```bash
bin/flora hermes cron create --name standup \
  --schedule '0 9 * * 1-5' \
  --prompt 'Summarise yesterday's merged Gerrit changes and post it to the flamingo channel.'
bin/flora hermes cron list
bin/flora hermes cron run standup      # test it now
```

Good candidates: a morning digest of open reviews, a nightly check that the main
branch still builds, a weekly note of which docs have gone stale.

## Updating

```bash
FLORA_UPDATE=1 bin/flora install hermes
FLORA_UPDATE=1 bin/flora install opencode
bin/flora install tokenring
bin/flora render
bin/flora restart
bin/flora doctor
```

`install` without `FLORA_UPDATE=1` is a no-op when something is already present,
so it is safe to run at any time. TokenRing always fetches, and rebuilds only if
the checkout moved.

Upgrades are not reversible on their own. Before a big one, copy `state/` aside:

```bash
tar czf /tmp/flora-state-$(date +%F).tar.gz state shared secrets flora.env
```

## Adding a fifth service

The shape is deliberately repetitive:

1. `config/templates/systemd/flora-<name>.service.tmpl`
2. A `server { }` block in `config/templates/nginx/flora.conf.tmpl`
3. `FLORA_HOST_<NAME>` and `FLORA_PORT_<NAME>` in `flora.env.example`
4. A hostname in `scripts/install-hosts.sh`
5. A row in `SERVICES` in `scripts/health.sh`
6. An `<li>` in `config/templates/dashboard.html.tmpl`

Then `bin/flora render && sudo bin/flora nginx && sudo bin/flora systemd`, and
one line on each teammate's `/etc/hosts`.

## Moving or copying the platform

There is no backup tooling here by design — the layout is the backup story.
Everything Flora is lives under one directory, so copying that directory copies
Flora entire: skills, sessions, memories, credentials, chat history, the key pool.

```bash
bin/flora down
tar czf /tmp/flora.tar.gz \
  --exclude='state/opencode/npm' \
  --exclude='state/tokenring/src' \
  --exclude='state/*/xdg/cache' \
  -C /opt flora
bin/flora up
```

The exclusions are things `bin/flora install` re-downloads. Everything else goes.

**Two things a plain copy does not handle well**, worth knowing before you rely
on one:

- **Mattermost's Postgres.** A file-level copy of a running database can be
  inconsistent. Stop it first (`bin/flora down`), or dump it:
  ```bash
  docker exec flora-mm-postgres pg_dump -U mmuser -d mattermost | gzip > /tmp/mm.sql.gz
  ```
- **SQLite in WAL mode** (Hermes and TokenRing). Same rule: stop the services, or
  accept that the copy may be a few writes behind.

Stopping first for ten seconds avoids both.

### On the new machine

```bash
tar xzf /tmp/flora.tar.gz -C /opt      # or wherever
cd /opt/flora
sudo ./bin/flora install               # re-fetch the excluded software
$EDITOR flora.env                      # FLORA_IP for the new box
sudo ./bin/flora render
sudo ./bin/flora hosts && sudo ./bin/flora nginx && sudo ./bin/flora systemd
./bin/flora doctor
```

`FLORA_HOME` is derived from where the scripts live, so the directory can land
at a different path without editing anything. Update every teammate's
`/etc/hosts` with the new IP.

### If you want scheduled copies back

One `rsync` line from another machine is most of what the removed tooling did:

```bash
rsync -az --delete \
  --exclude='state/opencode/npm' --exclude='state/tokenring/src' \
  flora-server:/opt/flora/ /srv/flora/
```

Note that this pulls `secrets/` too, so the destination needs to be as trusted
as the server itself.

## What "good" looks like

```
$ bin/flora status
SERVICE      STATUS   SYSTEMD    URL
tokenring    up       active     http://tokens.flora.com
hermes       up       active     http://hermes.flora.com
opencode     up       active     http://opencode.flora.com
mattermost   up       active     http://chat.flora.com
gateway      up       active     http://chat.flora.com
[ ok ] all services up
```
