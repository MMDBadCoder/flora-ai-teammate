# Troubleshooting

Start here, always:

```bash
bin/flora doctor
```

It checks layout, permissions, stray state outside the tree, binaries, config
validity, service health, skill drift, routing and accounts, and names
the script that fixes whatever it finds.

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

## Something wrote outside the directory

```bash
bin/flora doctor          # section 2 checks this
ls -la ~/.hermes ~/.config/opencode ~/.local/share/opencode 2>/dev/null
```

Cause: something ran `hermes` or `opencode` directly instead of through the
wrapper. Merge the stray state back in (or delete it if it is empty) and use
`bin/flora hermes …` / `bin/flora shell` from then on.

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
