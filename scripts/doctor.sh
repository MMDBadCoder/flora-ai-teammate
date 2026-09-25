#!/usr/bin/env bash
# Full diagnostic sweep. Read-only -- it changes nothing and is safe any time.
# This is the first thing to run when something looks wrong.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

problems=0
bad() { err "$*"; problems=$((problems+1)); }

step "1. Layout"
for d in shared/skills shared/agents state/hermes/home state/opencode/config \
         state/tokenring/data state/mattermost secrets workspace; do
  [[ -d "$FLORA_HOME/$d" ]] && ok "$d" || bad "missing $d"
done
[[ "$(stat -c %a "$FLORA_HOME/secrets")" == "700" ]] && ok "secrets/ is 0700" || bad "secrets/ should be mode 0700"
if [[ -f "$FLORA_HOME/secrets/flora.env" ]]; then
  [[ "$(stat -c %a "$FLORA_HOME/secrets/flora.env")" == "600" ]] && ok "secrets/flora.env is 0600" || bad "secrets/flora.env should be 0600"
fi

step "2. Nothing escaped the directory"
# The whole point of the layout: no agent state outside FLORA_HOME.
for stray in "$HOME/.hermes" "$HOME/.config/opencode" "$HOME/.local/share/opencode"; do
  if [[ -e "$stray" ]] && [[ "$(readlink -f "$stray")" != "$FLORA_HOME"* ]]; then
    bad "$stray exists outside the Flora tree -- something ran the agent without the wrapper;
       move it in, or delete it if it is empty:  ls -la $stray"
  else
    ok "no stray state at $stray"
  fi
done

step "3. Binaries"
[[ -x "$FLORA_STATE/bin/hermes" ]] && ok "hermes wrapper" || bad "missing state/bin/hermes (run: bin/flora render)"
[[ -x "$FLORA_STATE/bin/opencode" ]] && ok "opencode wrapper" || bad "missing state/bin/opencode"
"$FLORA_STATE/bin/hermes" --version >/dev/null 2>&1 && ok "hermes: $("$FLORA_STATE/bin/hermes" --version 2>&1 | head -1)" \
  || bad "hermes does not run (scripts/install-hermes.sh)"
"$FLORA_STATE/bin/opencode" --version >/dev/null 2>&1 && ok "opencode: $("$FLORA_STATE/bin/opencode" --version 2>&1 | head -1)" \
  || bad "opencode does not run (scripts/install-opencode.sh)"
[[ -f "$FLORA_STATE/tokenring/src/server/dist/main.js" ]] && ok "tokenring built" || bad "tokenring not built (scripts/install-tokenring.sh)"

step "4. Configuration"
[[ -f "$HERMES_HOME/config.yaml" ]] && ok "hermes config.yaml" || bad "hermes config.yaml missing (bin/flora render)"
if [[ -f "$OPENCODE_CONFIG_DIR/opencode.json" ]]; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OPENCODE_CONFIG_DIR/opencode.json" 2>/dev/null \
    && ok "opencode.json is valid JSON" || bad "opencode.json is not valid JSON"
else bad "opencode.json missing"; fi
key="$(secret_get flora.env FLORA_TOKENRING_KEY || true)"
[[ "$key" == "sk-ring-REPLACE-ME" || -z "$key" ]] \
  && bad "FLORA_TOKENRING_KEY is still a placeholder -- issue a key in the TokenRing
       dashboard (http://$FLORA_HOST_TOKENS) and run: bin/flora tokenring key sk-ring-..." \
  || ok "TokenRing key is set"
[[ -z "$(secret_get flora.env MATTERMOST_BOT_TOKEN || true)" ]] \
  && warn "MATTERMOST_BOT_TOKEN is empty -- Flora cannot answer in chat yet (docs/07-integrations.md)" \
  || ok "Mattermost bot token is set"
[[ -z "$(secret_get flora.env MATTERMOST_ALLOWED_USERS || true)" ]] \
  && warn "MATTERMOST_ALLOWED_USERS is empty -- Flora will ignore everyone in chat" \
  || ok "Mattermost allow-list is set"

step "5. Services"
"$FLORA_HOME/scripts/health.sh" || true

step "6. Skills"
"$FLORA_HOME/scripts/skills-sync.sh" --check || bad "the skill tree has drifted (run: bin/flora skills sync)"

step "7. Routing"
if have_cmd nginx; then
  nginx -t >/dev/null 2>&1 && ok "nginx config is valid" || bad "nginx -t fails"
  [[ -f /etc/nginx/conf.d/flora.conf ]] && ok "flora.conf installed" || bad "flora vhosts not installed (bin/flora nginx)"
fi
for h in "$FLORA_HOST_DASHBOARD" "$FLORA_HOST_HERMES" "$FLORA_HOST_OPENCODE" "$FLORA_HOST_CHAT" "$FLORA_HOST_TOKENS"; do
  getent hosts "$h" >/dev/null && ok "$h resolves" || bad "$h does not resolve here (bin/flora hosts)"
done
if [[ "$FLORA_AUTH_MODE" == "nginx" ]]; then
  [[ -s "$FLORA_STATE/nginx/htpasswd" ]] && ok "$(wc -l < "$FLORA_STATE/nginx/htpasswd") UI account(s)" \
    || bad "no UI accounts (bin/flora user add <name>)"
fi

echo
if [[ "$problems" -eq 0 ]]; then ok "no problems found"; else err "$problems problem(s) above"; exit 1; fi
