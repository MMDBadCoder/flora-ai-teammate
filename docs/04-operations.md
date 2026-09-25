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

Check first, apply second. They are separate commands because these components
come from three different channels with three different release habits.

```bash
bin/flora update                    # report only -- changes nothing
bin/flora update --apply            # apply everything
bin/flora update --apply opencode   # or just one
```

```
COMPONENT    DEPLOYED               AVAILABLE
tokenring    3242aefe (main)        7c11b0a2               UPDATE
hermes       0.9.4                  0.9.4                  current
opencode     1.4.2                  1.5.0                  UPDATE
mattermost   10.5                   10.5 (pinned)          edit the template to move
```

### Where each one comes from

| Component | Channel | Pinned by |
|---|---|---|
| **TokenRing** | a git checkout built from source | `FLORA_TOKENRING_REF` in `flora.env` |
| **Hermes** | the upstream installer's own updater | not pinned; `hermes update` moves it |
| **OpenCode** | the `opencode-ai` npm package | `FLORA_OPENCODE_PACKAGE` (e.g. `opencode-ai@1.4.2`) |
| **Mattermost** | a Docker image tag | the tag in `config/templates/mattermost/docker-compose.yml.tmpl` |

### TokenRing in particular

It is built from source because upstream publishes no tagged releases and no
container image — its own compose file builds locally. So `FLORA_TOKENRING_REF`
tracks `main` by default, and it accepts a branch, a tag or a full commit SHA:

```ini
FLORA_TOKENRING_REF=main        # tip of the branch (the default today)
FLORA_TOKENRING_REF=v1.2.0      # a tag, once upstream cuts them
FLORA_TOKENRING_REF=3242aefe…   # an exact commit — fully reproducible
```

**Pin it as soon as there is something to pin to.** Every model call from both
agents goes through this service; it is the last thing that should move without
you deciding it should.

`bin/flora install tokenring` never moves an existing checkout on its own. It
reports the gap and stops:

```
[warn] A newer TokenRing is available on 'main':
    deployed  3242aefe
    upstream  7c11b0a2
[flora] Nothing was changed. To review first:
    git -C state/tokenring/src log --oneline 3242aefe..7c11b0a2
```

Applying it is `FLORA_UPDATE=1 bin/flora install tokenring`, which:

1. copies `state/tokenring/data` aside as `data.pre-<sha>` — TokenRing migrates
   its schema on boot and migrations only run forwards, so the old build may not
   read a database the new one has touched;
2. fetches, checks out and rebuilds;
3. records the deployed SHA in `state/tokenring/deployed.txt`;
4. prints the exact rollback commands, with the old SHA already filled in.

```bash
bin/flora restart tokenring && bin/flora status
```

If the pool stops answering, the rollback it printed is two lines: reinstall the
old SHA, move the old data directory back.

### The others

```bash
FLORA_UPDATE=1 bin/flora install hermes      # runs `hermes update --backup`
FLORA_UPDATE=1 bin/flora install opencode    # npm install opencode-ai@latest
bin/flora render && bin/flora restart && bin/flora doctor
```

To hold OpenCode at a known-good version, set
`FLORA_OPENCODE_PACKAGE=opencode-ai@1.4.2` in `flora.env`.

Mattermost's image tag is pinned in its template on purpose — a major upgrade
migrates the database and is not reversible. Change the tag, then
`bin/flora render && bin/flora restart mattermost`, and read Mattermost's own
upgrade notes for the version you are jumping to.

Upgrades are not reversible on their own. Before a big one, copy the state aside:

```bash
bin/flora down
tar czf /tmp/flora-state-$(date +%F).tar.gz state shared secrets flora.env
bin/flora up
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
