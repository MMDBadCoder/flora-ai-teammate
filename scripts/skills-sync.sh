#!/usr/bin/env bash
# Reconcile the shared skill tree across both agents. See docs/06-skills-and-sync.md.
# Run by the flora-skills-sync timer every five minutes, by the path unit when a
# skill directory changes, and by hand via `bin/flora skills sync`.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env
exec python3 "$FLORA_HOME/scripts/lib/skills_sync.py" "$@"
