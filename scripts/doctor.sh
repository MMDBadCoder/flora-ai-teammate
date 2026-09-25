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
# Flora's own state must all be under FLORA_HOME. Agent directories that were
# already on this machine before Flora was installed are recorded in
# state/external-installs.txt and are left alone -- they belong to whoever was
# using Hermes or OpenCode here first.
while IFS= read -r stray; do
  if [[ ! -e "$stray" ]]; then
    ok "nothing at $stray"
  elif [[ "$(readlink -f "$stray")" == "$FLORA_HOME"* ]]; then
    ok "$stray points inside the Flora tree"
  elif is_external_known "$stray"; then
    skip "$stray is a pre-existing personal install; not Flora's"
  else
    warn "$stray appeared outside the Flora tree.
       Either something ran the agent without the wrapper (use bin/flora hermes /
       bin/flora opencode, or bin/flora shell), or it predates Flora and was
       never recorded. If it is yours and not Flora's, say so once with:
         echo '$stray' >> $FLORA_HOME/$EXTERNAL_LIST_REL"
  fi
done < <(external_paths)

# Shims Flora may have left in the operator's PATH during an earlier, less
# isolated install. Harmless, but they are a `hermes` that is not Flora's.
for shim in "$HOME"/.local/bin/hermes "$HOME"/.local/bin/hermes-acp "$HOME"/.local/bin/hermes-agent; do
  [[ -e "$shim" ]] || continue
  case "$(classify_shim "$shim")" in
    flora)    warn "$shim points into the Flora tree ($(shim_target "$shim")).
       Left by an earlier install. Flora uses state/bin/hermes; delete it:  rm -f $shim" ;;
    external) skip "$shim is your own Hermes, not Flora's" ;;
  esac
done

step "3. Binaries"
[[ -x "$FLORA_STATE/bin/hermes" ]] && ok "hermes wrapper" || bad "missing state/bin/hermes (run: bin/flora render)"
[[ -x "$FLORA_STATE/bin/opencode" ]] && ok "opencode wrapper" || bad "missing state/bin/opencode"
"$FLORA_STATE/bin/hermes" --version >/dev/null 2>&1 && ok "hermes: $("$FLORA_STATE/bin/hermes" --version 2>&1 | head -1)" \
  || bad "hermes does not run (scripts/install-hermes.sh)"
"$FLORA_STATE/bin/opencode" --version >/dev/null 2>&1 && ok "opencode: $("$FLORA_STATE/bin/opencode" --version 2>&1 | head -1)" \
  || bad "opencode does not run (scripts/install-opencode.sh)"
if [[ -f "$FLORA_STATE/tokenring/src/server/dist/main.js" ]]; then
  ok "tokenring built at $(cut -c1-8 "$FLORA_STATE/tokenring/deployed.txt" 2>/dev/null || echo unknown) (ref ${FLORA_TOKENRING_REF:-main})"
else
  bad "tokenring not built (scripts/install-tokenring.sh)"
fi

step "4. Configuration"
# New releases add settings. Missing ones fall back to a built-in default, so
# nothing breaks -- but it is worth knowing which knobs you have not seen.
if [[ -f "$FLORA_HOME/flora.env" && -f "$FLORA_HOME/flora.env.example" ]]; then
  missing="$(comm -23 \
    <(grep -oE '^[A-Z_]+=' "$FLORA_HOME/flora.env.example" | tr -d '=' | sort -u) \
    <(grep -oE '^[A-Z_]+=' "$FLORA_HOME/flora.env" | tr -d '=' | sort -u) || true)"
  if [[ -n "$missing" ]]; then
    warn "flora.env predates these settings; defaults are in use:
$(sed 's/^/         /' <<< "$missing")
       See docs/03-configuration.md, or copy the new blocks from flora.env.example."
  else
    ok "flora.env has every setting the current version knows about"
  fi
fi
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
if [[ "${FLORA_NGINX:-docker}" == "docker" ]]; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx flora-nginx; then
    ok "flora-nginx container is running (nothing written to /etc/nginx)"
  else
    bad "flora-nginx is not running (sudo bin/flora nginx)"
  fi
elif have_cmd nginx; then
  nginx -t >/dev/null 2>&1 && ok "host nginx config is valid" || bad "nginx -t fails"
  [[ -f /etc/nginx/conf.d/flora.conf ]] && ok "flora.conf installed" || bad "flora vhosts not installed (bin/flora nginx)"
fi
if [[ "${FLORA_ROUTING:-ports}" == "hosts" ]]; then
  for h in "$FLORA_HOST_DASHBOARD" "$FLORA_HOST_HERMES" "$FLORA_HOST_OPENCODE" "$FLORA_HOST_CHAT" "$FLORA_HOST_TOKENS"; do
    getent hosts "$h" >/dev/null && ok "$h resolves" || bad "$h does not resolve here (bin/flora hosts)"
  done
else
  ok "addressing by port -- no DNS or /etc/hosts involved"
  for pair in "$FLORA_PUBLIC_DASHBOARD dashboard" "$FLORA_PUBLIC_HERMES hermes" \
              "$FLORA_PUBLIC_OPENCODE opencode" "$FLORA_PUBLIC_CHAT mattermost" \
              "$FLORA_PUBLIC_TOKENS tokenring"; do
    set -- $pair
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; then
      ok "nginx is listening on $1 ($2)"
    else
      bad "nothing is listening on $1 ($2) -- run: sudo bin/flora nginx"
    fi
  done
fi
if [[ "$FLORA_AUTH_MODE" == "nginx" ]]; then
  [[ -s "$FLORA_STATE/nginx/htpasswd" ]] && ok "$(wc -l < "$FLORA_STATE/nginx/htpasswd") UI account(s)" \
    || bad "no UI accounts (bin/flora user add <name>)"
fi

echo
if [[ "$problems" -eq 0 ]]; then ok "no problems found"; else err "$problems problem(s) above"; exit 1; fi
