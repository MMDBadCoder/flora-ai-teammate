#!/usr/bin/env bash
# What is deployed, and what is available upstream.
#
#   update.sh                 report only -- changes nothing
#   update.sh --apply         apply every available update
#   update.sh --apply hermes  just one (tokenring|hermes|opencode|mattermost)
#
# Checking is always separate from applying. All four components come from
# different channels with different release habits, so this is the one place
# that knows how to ask each of them.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

APPLY=0; ONLY=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    tokenring|hermes|opencode|mattermost) ONLY="$a" ;;
    *) die "usage: update.sh [--apply] [tokenring|hermes|opencode|mattermost]" ;;
  esac
done
want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

pending=0
row() { printf '  %-12s %-22s %-22s %s\n' "$1" "$2" "$3" "$4"; }

step "Versions"
printf '  %-12s %-22s %-22s %s\n' COMPONENT DEPLOYED AVAILABLE ""
printf '  %-12s %-22s %-22s %s\n' --------- -------- --------- ""

# --- TokenRing: a git checkout, no releases upstream ------------------------
if want tokenring; then
  src="$FLORA_STATE/tokenring/src"
  ref="${FLORA_TOKENRING_REF:-main}"
  if [[ -d "$src/.git" ]]; then
    have="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo '?')" || true
    up="$(git ls-remote "${FLORA_TOKENRING_REPO:-https://github.com/MMDBadCoder/tokenring.git}" \
          "$ref" "refs/tags/$ref" 2>/dev/null | head -1 | awk '{print $1}' || true)"
    if [[ -z "$up" ]]; then row tokenring "${have:0:8} ($ref)" "unreachable" "cannot reach the remote"
    elif [[ "$have" == "$up" ]]; then row tokenring "${have:0:8} ($ref)" "${up:0:8}" "current"
    else row tokenring "${have:0:8} ($ref)" "${up:0:8}" "UPDATE"; pending=$((pending+1)); fi
  else
    row tokenring "not installed" "-" "run: bin/flora install tokenring"
  fi
fi

# --- Hermes: upstream installer with its own check --------------------------
if want hermes; then
  if [[ -x "$FLORA_STATE/bin/hermes" ]]; then
    have="$("$FLORA_STATE/bin/hermes" --version 2>/dev/null | head -1 | tr -d '\n' || true)"
    if [[ -z "$have" ]]; then
      row hermes "wrapper only" "-" "binary missing: bin/flora install hermes"
    else
      chk="$("$FLORA_STATE/bin/hermes" update --check 2>&1 | tail -3 | tr '\n' ' ' || true)"
      if grep -qiE 'up to date|latest|no update' <<< "$chk"; then row hermes "$have" "$have" "current"
      else row hermes "$have" "see below" "CHECK"; pending=$((pending+1)); fi
    fi
  else
    row hermes "not installed" "-" "run: bin/flora install hermes"
  fi
fi

# --- OpenCode: an npm package ----------------------------------------------
if want opencode; then
  pkgjson="$FLORA_STATE/opencode/npm/node_modules/opencode-ai/package.json"
  if [[ -f "$pkgjson" ]]; then
    have="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$pkgjson" 2>/dev/null || echo '?')"
    up="$(npm view opencode-ai version 2>/dev/null || echo '')"
    if [[ -z "$up" ]]; then row opencode "$have" "unreachable" "npm registry unreachable"
    elif [[ "$have" == "$up" ]]; then row opencode "$have" "$up" "current"
    else row opencode "$have" "$up" "UPDATE"; pending=$((pending+1)); fi
  else
    row opencode "not installed" "-" "run: bin/flora install opencode"
  fi
fi

# --- Mattermost: a pinned image tag ----------------------------------------
if want mattermost; then
  tag="$(grep -oP 'mattermost-team-edition:\K[\w.-]+' \
        "$FLORA_HOME/config/templates/mattermost/docker-compose.yml.tmpl" 2>/dev/null || echo '?')" || true
  running="$(docker inspect --format '{{.Config.Image}}' flora-mattermost 2>/dev/null | sed 's/.*://' || true)"
  running="${running:-not running}"
  row mattermost "$running" "$tag (pinned)" "edit the template to move"
fi

echo
if [[ "$APPLY" != "1" ]]; then
  if [[ "$pending" -gt 0 ]]; then
    warn "$pending component(s) have updates. Nothing was changed."
    log  "Apply them with:  bin/flora update --apply"
    log  "Read what changed first -- these run the agents that touch your repositories."
  else
    ok "everything is current"
  fi
  exit 0
fi

# --------------------------------------------------------------- applying ---
step "Applying"
warn "Copy state/ aside first if you have not: this is the only way back."
export FLORA_UPDATE=1
failed=0
want tokenring && { "$FLORA_HOME/scripts/install-tokenring.sh" || { err "TokenRing update failed"; failed=1; }; }
want hermes    && { "$FLORA_HOME/scripts/install-hermes.sh"    || { err "Hermes update failed";    failed=1; }; }
want opencode  && { "$FLORA_HOME/scripts/install-opencode.sh"  || { err "OpenCode update failed";  failed=1; }; }
if want mattermost; then
  docker compose -f "$FLORA_STATE/mattermost/docker-compose.yml" pull
  ok "images pulled; they take effect on the next restart"
fi

"$FLORA_HOME/scripts/render.sh" >/dev/null
step "Done"
[[ "${failed:-0}" == "1" ]] && warn "at least one component did not update -- see above"
log "restart and verify:  bin/flora restart && bin/flora doctor"
