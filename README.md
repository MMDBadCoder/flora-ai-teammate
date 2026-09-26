# Flora

Flora is an AI teammate for the **Flamingo** engineering team. She lives on one
server, in one directory, and the team reaches her four ways: a chat UI, a
coding UI, Mattermost, and the CLI.

She can take a task, change code and push it to Gerrit for review, answer
technical questions, edit Confluence pages, and learn from what she does — the
things she learns become **skills**, which are shared between her two agent
runtimes so she never knows something in one place and not the other.

```
                     http://<server ip>:7080          the only link to share
                                  │
                  ┌───────────────▼────────────────┐
                  │  nginx    one port per service │
                  │  (Flora's own container)       │
                  └──┬────────┬────────┬────────┬──┘
                :7081│   :7082│   :7083│   :7084│
             ┌───────▼──┐ ┌───▼────┐ ┌─▼──────┐ ┌▼──────────┐
             │ Hermes   │ │OpenCode│ │Matter- │ │ TokenRing │
             │ dashboard│ │  web   │ │ most   │ │ key pool  │
             │ + gateway├─┼────────┼─┘        │ └─────▲─────┘
             └────┬─────┘ └───┬────┘          │       │
                  │           │    every LLM call ────┘
                  └── shared/ ┘
                   skills · instructions · MCP
```

No DNS and no `/etc/hosts`: every service is reached by address and port, and
the dashboard links to the rest. nginx runs in Flora's own container, so nothing
is written to `/etc/nginx` and the machine does not need nginx installed.

## Start here

| I want to… | Read |
|---|---|
| understand how the pieces fit | [docs/01-architecture.md](docs/01-architecture.md) |
| set it up from nothing | [docs/02-install.md](docs/02-install.md) |
| change a setting | [docs/03-configuration.md](docs/03-configuration.md) |
| run it day to day | [docs/04-operations.md](docs/04-operations.md) |
| add a teammate / manage logins | [docs/05-accounts-and-auth.md](docs/05-accounts-and-auth.md) |
| teach Flora something | [docs/06-skills-and-sync.md](docs/06-skills-and-sync.md) |
| wire up Gerrit, Confluence, chat | [docs/07-integrations.md](docs/07-integrations.md) |
| fix something that broke | [docs/08-troubleshooting.md](docs/08-troubleshooting.md) |
| know what the risks are | [docs/09-security.md](docs/09-security.md) |

## Quick start

```bash
cd /opt/flora
cp flora.env.example flora.env     # set FLORA_IP
sudo ./bin/flora bootstrap         # installs, configures, routes, starts
./bin/flora doctor                 # tells you what is still missing
```

Then finish the three manual steps `bootstrap` prints: issue a TokenRing key,
create the Mattermost admin, create Flora's bot account.

## The directory

```
flora/
├── bin/flora            one command for everything
├── docs/                the manual you are reading
├── flora.env            every knob (git-ignored; flora.env.example is tracked)
├── secrets/             credentials, 0600, never committed
├── config/templates/    the source of truth for every config file
├── scripts/             one job per script, all idempotent
├── shared/              THE BRAIN — skills, instructions, MCP servers (tracked)
├── state/               everything the four services write (git-ignored)
├── workspace/           repositories Flora works in
└── web/dashboard/       the launcher page
```

Two rules keep this manageable:

1. **Nothing lives outside this directory.** `HERMES_HOME`, `OPENCODE_CONFIG_DIR`,
   `XDG_*` and `HOME` are redirected into `state/`, and Mattermost uses bind
   mounts rather than Docker volumes. Copy this directory and you have copied
   Flora, whole.
2. **Configs are generated, never hand-edited.** Edit `config/templates/**`,
   then `bin/flora render`. Anything under `state/` is disposable output.

## The daily commands

```bash
bin/flora status                 # is everything up?
bin/flora logs gateway -f        # why isn't Flora answering in chat?
bin/flora skills list            # what does she know?
bin/flora skills new <name>      # teach her something
bin/flora creds                  # every login and link, in one place
bin/flora update                 # what is deployed vs available upstream
bin/flora doctor                 # what is wrong?
bin/flora network                # why can't other machines reach it?
bin/flora upgrade                # move onto the code you just pulled, keeping data
bin/flora uninstall              # remove the system integration (--purge wipes data)
```
