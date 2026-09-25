# Accounts and access

## Where are my passwords?

```bash
bin/flora creds
```

Prints every login: the account nginx checks for the dashboard and both agent
UIs, the TokenRing dashboard password, and what Mattermost expects. It reads
`secrets/flora.env`, so it only works on the server.

The short version: the **username** is `FLORA_ADMIN_USER` in `flora.env`
(`admin` by default) and the **password** is `FLORA_ADMIN_PASSWORD` in
`secrets/flora.env`, generated on first install. `sudo bin/flora nginx` turns
that pair into the first entry of `state/nginx/htpasswd`, which is the file
nginx actually reads.

## Three separate account systems

There is no single sign-on here. Each surface authenticates its own way, and
that is worth knowing before you hand out passwords.

| Surface | Auth | Accounts live in | Admin |
|---|---|---|---|
| Dashboard, Hermes, OpenCode | HTTP basic, via nginx | `state/nginx/htpasswd` | whoever you name in `FLORA_ADMIN_USER` |
| Mattermost | real accounts, sessions, optional MFA | Mattermost's own database | the first account created |
| TokenRing | one shared dashboard password | its SQLite database | anyone with the password |

## The agent UIs

Hermes and OpenCode were built to run on a laptop. Neither has per-user
accounts, roles or an audit trail: whoever gets in is the same "user" to them.
So the account layer sits in nginx, where it can be per-person.

```bash
bin/flora user add sara          # generates and prints a password, once
bin/flora user add sara hunter2  # or set one
bin/flora user list
bin/flora user del sara
```

The file is a standard Apache `htpasswd` with bcrypt hashes. `bin/flora user`
writes it; nginx reads it on every request, so changes take effect immediately —
no reload.

**What this does and does not give you.** It controls *who gets in*. It does not
separate what they can do once inside: everyone shares the same Hermes sessions
and the same OpenCode workspace, and the logs show which account made the HTTP
request but not which person drove a given agent turn. For a team that already
trusts each other with repository access this is proportionate. If you need
real per-user separation, run a second Hermes profile per person, or put an
identity proxy in front — see below.

Removing someone means `bin/flora user del`, and rotating anything they saw.

### Upgrading to real SSO

Two paths, both without touching Flora's own config:

- **An identity proxy.** Put Authelia or oauth2-proxy in front and replace the
  `auth_basic` lines in `state/nginx/auth.conf` with an `auth_request`. That
  gets you OIDC, group rules and MFA for the agent UIs.
- **Hermes' own OIDC.** Hermes' dashboard supports OIDC directly when it binds
  to a non-loopback address. Set `FLORA_AUTH_MODE=backend`, configure the OIDC
  keys in `state/hermes/home/.env`, and let nginx just proxy.

## Mattermost

Proper accounts: email invites, roles, channels, MFA, session revocation.

- **Admin**: the first account created during install.
- **Adding people**: System Console → Users → Add, or invite links.
- **Open sign-up is off** (`MM_TEAMSETTINGS_ENABLEOPENSERVER=false`). Invite only.
- **Email is off** — there is no SMTP server on an offline network, so invites
  are links you send by hand.

Who Flora will actually talk to is a separate list, in
`MATTERMOST_ALLOWED_USERS`. A Mattermost account is not enough; a user ID must
be on that list. Empty means nobody, which is the safe default and also the most
common reason for "Flora is ignoring me".

```bash
bin/flora secrets edit      # MATTERMOST_ALLOWED_USERS=abc...,def...
bin/flora restart gateway
```

Remember this is a capability, not a courtesy: anyone on that list can make
Flora run shell commands on this server.

## TokenRing

One password for the dashboard, shared by whoever administers the pool.

```bash
bin/flora tokenring password
```

Per-person accountability comes from **virtual keys** instead: issue one key per
person or per tool, and the dashboard shows requests, tokens, error rate and
latency for each. Revoking a key is instant and affects nobody else.

Flora's own key is in `secrets/flora.env`. Rotating it:

```bash
# issue a new key in the dashboard, then
bin/flora tokenring key sk-ring-newvalue
# revoke the old one in the dashboard
```

## The admin's set of keys

| What | Where |
|---|---|
| UI account | `bin/flora user list`, password in `secrets/flora.env` as `FLORA_ADMIN_PASSWORD` |
| Mattermost system admin | created during install, in Mattermost's database |
| TokenRing dashboard | `bin/flora tokenring password` |
| Server root | your own SSH key |
| Everything else | `secrets/flora.env`, mode 0600 |

## Hardening checklist

- [ ] `FLORA_BIND_ADDR=127.0.0.1` unless you deliberately changed it
- [ ] `bin/flora user list` contains only current teammates
- [ ] `MATTERMOST_ALLOWED_USERS` likewise
- [ ] Mattermost open sign-up is off
- [ ] `secrets/` is 0700, `secrets/flora.env` is 0600
- [ ] `git status` shows nothing from `secrets/` or `state/`
- [ ] Backups are copied off this machine
- [ ] The server's firewall exposes only what the team needs

More on the underlying risks in [09-security.md](09-security.md).
