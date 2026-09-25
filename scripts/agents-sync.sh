#!/usr/bin/env bash
# Keeps the two agents interchangeable.
#
# Four things must match or the team gets different answers from Flora
# depending on which UI they happened to open:
#   1. skills       -- shared/skills, via symlinks (scripts/skills-sync.sh)
#   2. instructions -- shared/agents/AGENTS.md + FLORA.md
#   3. tool servers -- shared/mcp/servers.json, rendered into both configs
#   4. the model    -- both point at the same TokenRing pool
#
# Run after editing anything in shared/, or let the timer do it.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Agent sync"

# --- 1+4: re-render configs (model, provider, MCP block) --------------------
"$FLORA_HOME/scripts/render.sh" | sed 's/^/  /'

# --- 2: shared instructions -------------------------------------------------
# OpenCode reads them through the "instructions" array in opencode.json; Hermes
# reads AGENTS.md from HERMES_HOME and SOUL.md for persona.
ensure_symlink "$HERMES_HOME/AGENTS.md" "$FLORA_SHARED/agents/AGENTS.md"
ensure_symlink "$HERMES_HOME/SOUL.md"   "$FLORA_SHARED/agents/SOUL.md"
ensure_symlink "$FLORA_STATE/opencode/home/AGENTS.md" "$FLORA_SHARED/agents/AGENTS.md"

# --- 3: MCP servers into Hermes --------------------------------------------
# OpenCode gets them from the rendered opencode.json; Hermes keeps its own
# registry, so each server is added through the CLI. Adding one twice is a
# no-op on Hermes' side, and a failure here is a warning, not a stop: a missing
# tool server should never keep the agents from starting.
if [[ -s "$FLORA_SHARED/mcp/servers.json" ]] && [[ -x "$FLORA_STATE/bin/hermes" ]]; then
  existing="$("$FLORA_STATE/bin/hermes" mcp list 2>/dev/null || true)"
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    name="$(awk '{print $4}' <<< "$cmd")"
    if grep -qw "$name" <<< "$existing"; then skip "mcp server $name already registered with Hermes"; continue; fi
    log "registering mcp server with Hermes: $name"
    eval "${cmd/#hermes/$FLORA_STATE/bin/hermes}" >/dev/null 2>&1 \
      || warn "could not register '$name' with Hermes; add it by hand: $cmd"
  done < <(python3 "$FLORA_HOME/scripts/lib/mcp_render.py" hermes)
fi

# --- skills -----------------------------------------------------------------
"$FLORA_HOME/scripts/skills-sync.sh" | sed 's/^/  /'

echo
ok "agents in sync"
log "restart the agents to pick up config changes:  bin/flora restart hermes opencode"
