# Troubleshooting

Start here, always:

```bash
bin/flora doctor
```

It checks layout, permissions, stray state outside the tree, binaries, config
validity, service health, skill drift, routing and accounts, and names
the script that fixes whatever it finds.

## Preflight says "problem(s) to fix before installing"

It lists them again at the end, numbered, each with the command that fixes it.
Only `[must]` lines block; `[warn]` lines are advisory and the run continues
past them.

The usual one is **Node.js**. `apt install nodejs` on Debian and most Ubuntu
releases installs a version older than the 20.11 TokenRing needs, so:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v
```

Others worth knowing:

| `[must]` line | What it means |
|---|---|
| `docker is installed but not usable by <user>` | the daemon is stopped, or you are not in the `docker` group |
| `port 4000 (tokenring) is taken by …` | set `FLORA_PORT_TOKENRING` in `flora.env`, or stop the other process |
| `/etc/nginx/conf.d is missing` | unusual nginx layout; create it and `include` it from `nginx.conf` |
| `only 8G free …` | Mattermost, npm trees and clones need room |

And one `[warn]` that alarms people and should not: *"another vhost already owns
:80 as default_server"*. That is expected on a server that already hosts
something. Flora adds name-based vhosts and never claims `default_server`, so
the existing site keeps working.

Preflight changes nothing, so it is safe to run as often as you like:

```bash
bin/flora preflight
```

## The Hermes install failed at "gateway installation"

Symptom, usually on WSL:

```
Failed to connect to bus: No medium found
✗ Could not start the gateway service; systemd reported an error.
✗ gateway installation failed
```

The upstream installer asked whether to install and start a *systemd user
service* for its gateway, and there was no systemd user bus to talk to.

Flora does not want that service at all — it supervises the gateway itself with
`flora-hermes-gateway.service`. The installer is therefore run with
`--non-interactive`, which skips the setup and gateway stages entirely. If you
saw this, you were on a build from before that change:

```bash
git pull --rebase origin main
bin/flora install hermes
```

The installer now also removes what the failed run left behind: the non-isolated
checkout and tool store under `state/hermes/home/`, and it classifies any
`~/.local/bin/hermes` shim for you.

### Is `~/.local/bin/hermes` mine or Flora's?

It is a two-line script that names the install it runs, so read it:

```bash
cat ~/.local/bin/hermes
#!/bin/sh
exec /path/to/whatever/.hermes/bin/hermes "$@"
```

| The path points at | What it is | Do |
|---|---|---|
| somewhere under your Flora directory | left by an earlier, non-isolated Flora run | `rm -f ~/.local/bin/hermes` — Flora does not use it |
| `~/.hermes/hermes-agent/…` | your own personal Hermes | leave it, unless you no longer want that install |

`bin/flora doctor` makes the same call for you, along with `hermes-acp` and
`hermes-agent`, which the installer drops beside it.

A current Flora install never writes there at all: it runs the upstream
installer with `HOME` pointed at `state/hermes/fs-home`, so the shims land at
`state/hermes/fs-home/.local/bin/` and the PATH lines go into that directory's
own `.bashrc`.

## Running on WSL

Everything works, but **systemd is not on by default**, and without it nothing
keeps the four services alive — `flora up` would report success and supervise
nothing. Preflight now blocks on this. To enable it:

```bash
printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
# then, from Windows:
wsl --shutdown
```

Reopen the terminal and check with `systemctl is-system-running`.

Without systemd you can still run the services by hand — one per terminal, or in
tmux — using the `ExecStart` lines from `state/systemd/*.service`:

```bash
tmux new -s flora-tokenring 'cd state/tokenring/src && node server/dist/main.js'
tmux new -s flora-hermes    'state/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open'
tmux new -s flora-gateway   'state/bin/hermes gateway run'
tmux new -s flora-opencode  'state/bin/opencode web --hostname 127.0.0.1 --port 4096'
docker compose -f state/mattermost/docker-compose.yml up -d
```

Everything else — render, sync, health, housekeeping — works unchanged.

## A page does not load at all

```bash
curl -I http://hermes.flora.com          # from a client
getent hosts hermes.flora.com            # does the name resolve?
```

| Symptom | Cause | Fix |
|---|---|---|
| `Could not resolve host` | the client has no `/etc/hosts` line | `bin/flora hosts --print`, paste it on the client |
| Connection refused | nginx is not listening on `FLORA_HTTP_PORT` | `systemctl status nginx`, `nginx -t` |
| 404 from another site | a `default_server` vhost caught it — the `Host` header is wrong | check the spelling in `/etc/hosts` |
| 502 Bad Gateway | the backend is down | `bin/flora status`, then `bin/flora logs <service>` |
| 403 on the dashboard | nginx cannot traverse into the directory | `sudo bin/flora nginx` (it fixes the `o+x` bits) |
| Endless password prompt | wrong account, or no account file | `bin/flora user list`, `bin/flora user add <name>` |

## A service will not stay up

```bash
bin/flora logs tokenring
systemctl status flora-tokenring.service
journalctl -u flora-tokenring.service -n 50
```

| Service | Usual cause |
|---|---|
| tokenring | port 4000 taken, or the build is missing → `bin/flora install tokenring` |
| hermes | `HERMES_HOME` unwritable, or the binary moved → `bin/flora install hermes` |
| opencode | node too old, or `opencode web` unsupported in that build (swap the `ExecStart` comment in the unit template) |
| mattermost | the bind mounts are not owned by uid 2000 → `bin/flora install mattermost` |
| gateway | `MATTERMOST_BOT_TOKEN` empty or wrong |

## Flora does not answer in chat

In this order:

1. `bin/flora status` — is `gateway` up?
2. Is the asker's user ID in `MATTERMOST_ALLOWED_USERS`? **Empty means nobody.**
3. Is the bot in the channel? `/invite @flora`.
4. In a channel she needs an `@flora` mention; in a DM she does not.
5. `bin/flora logs gateway -f`, then send a message and watch.

## Flora answers, but every model call fails

```bash
curl http://127.0.0.1:4000/health
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $(bin/flora secrets show | grep TOKEN)" | head
```

| Message | Cause |
|---|---|
| `401` from TokenRing | `FLORA_TOKENRING_KEY` is still the placeholder → `bin/flora tokenring key sk-ring-…` |
| `no upstream keys available` | the pool is empty → add provider keys in the dashboard |
| `model not found` | `FLORA_MODEL_MAIN` is not a name the upstream knows |
| Upstream 4xx/5xx | the provider itself — the TokenRing dashboard shows which key failed |

## A skill is not being used

Malformed frontmatter makes a skill **silently invisible** to both agents. No
error, no log line, just an agent that appears to have forgotten something.

```bash
bin/flora skills lint
```

If it lints clean, the `description` is the problem: it does not sound like what
is being asked. Rewrite it as a trigger — "Use when asked to deploy to staging",
not "About deployments".

## The two agents disagree

```bash
bin/flora sync
readlink state/hermes/home/skills/team            # → …/shared/skills
ls -la state/opencode/config/skills/ | head
```

If one of them has a real directory where a symlink belongs, the reconciler says
so and refuses to guess. Move it aside and re-run.

## "X appeared outside the Flora tree"

```bash
bin/flora doctor          # section 2 checks this
```

Two different situations, and doctor tells them apart using
`state/external-installs.txt`, written when Flora was first installed:

- **It was there before Flora.** Reported as `[same] … pre-existing personal
  install`. Nothing to do; Flora never reads or writes it.
- **It appeared afterwards.** Reported as `[warn]`. Something ran `hermes` or
  `opencode` directly instead of through the wrapper, and started a second,
  invisible brain. Use `bin/flora hermes …`, `bin/flora opencode …` or
  `bin/flora shell` instead, then merge anything worth keeping into `state/` and
  delete the stray directory.

If a directory predates Flora but was never recorded — because you installed
Flora before this check existed — tell it once:

```bash
echo "$HOME/.hermes" >> state/external-installs.txt
```

## The disk filled up

```bash
du -sh state/* | sort -h | tail
bin/flora housekeep
```

Usual suspects: agent sessions (`FLORA_SESSION_KEEP_DAYS`), logs
(`FLORA_LOG_KEEP_DAYS`), Mattermost uploads, and `workspace/` clones — the last
are safe to delete, they are in Gerrit.

## nginx will not reload

```bash
nginx -t
```

`bin/flora nginx` validates before touching the running server and restores the
previous file if validation fails, so a broken Flora config cannot take down
other sites. If `nginx -t` fails on something outside `conf.d/flora.conf`, that
is a pre-existing problem.

## No systemd on this machine

The four services are plain processes; systemd is convenience, not a dependency.
Either run the `ExecStart` lines from `state/systemd/*.service` under any
supervisor (supervisord, runit, tmux in a pinch), or wrap them in a compose file
of your own. Everything else — render, sync, health, housekeeping — works unchanged.

## Starting over on one service

```bash
bin/flora down opencode
rm -rf state/opencode
bin/flora install opencode && bin/flora render && bin/flora skills sync
bin/flora up opencode
```

Sessions for that agent are lost; the shared brain is not, because it lives in
`shared/`.

## Reading the source

Every script has a header comment saying what it does and why. In rough order of
usefulness when debugging:

| File | |
|---|---|
| `scripts/lib/common.sh` | the idempotent primitives everything else uses |
| `scripts/render.sh` | what turns into what |
| `scripts/lib/skills_sync.py` | the sharing model, explained in the docstring |
| `scripts/health.sh` | what "up" actually means |
| `scripts/doctor.sh` | every invariant worth checking, in one place |
