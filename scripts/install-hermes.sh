#!/usr/bin/env bash
# Installs / updates the Hermes agent.
#
# The binary and its runtime (Python venv, node deps) are installed by the
# upstream installer in the usual place, ~/.local. That is SOFTWARE and can be
# reinstalled from the internet in one command. Everything that cannot -- config,
# sessions, memories, skills, cron jobs, credentials -- is forced into
# state/hermes/home by HERMES_HOME, so it travels with this directory.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Hermes"
record_external_installs
ensure_dir "$HERMES_HOME"
ensure_dir "$FLORA_STATE/hermes/xdg/data"
ensure_dir "$FLORA_STATE/hermes/xdg/cache"
ensure_dir "$FLORA_STATE/hermes/xdg/state"

export HERMES_HOME

if [[ -x "$FLORA_STATE/bin/hermes" ]] && "$FLORA_STATE/bin/hermes" --version >/dev/null 2>&1; then
  ver="$("$FLORA_STATE/bin/hermes" --version 2>&1 | head -1)"
  skip "Hermes already installed ($ver)"
  if [[ "${FLORA_UPDATE:-0}" == "1" ]]; then
    # The binary is shared with any personal Hermes on this machine -- only the
    # data directories are separate -- so an update here updates theirs too.
    if is_external_known "$HOME/.hermes"; then
      warn "this machine also has a personal Hermes ($HOME/.hermes).
       The binary is shared, so this upgrade affects that install as well.
       Only the data is separate. Ctrl-C now if that is not what you want."
      sleep 4
    fi
    log "updating Hermes"
    "$FLORA_STATE/bin/hermes" update --backup || warn "hermes update failed; keeping $ver"
  fi
else
  log "running the upstream installer (installs Python/Node deps as needed)"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash \
    || die "Hermes installer failed. Install it by hand, then re-run this script;
     it only needs \`hermes\` to be on PATH or at ~/.local/bin/hermes."
fi

# Resolve the binary once and remember it for the wrapper and the units.
for c in "$HOME/.local/bin/hermes" "/usr/local/bin/hermes" "$(command -v hermes 2>/dev/null || true)"; do
  [[ -n "$c" && -x "$c" ]] && { secret_set flora.env FLORA_HERMES_BIN "$c" >/dev/null || true; HB="$c"; break; }
done
[[ -n "${HB:-}" ]] || die "hermes is installed but I cannot find the binary; add FLORA_HERMES_BIN=/path/to/hermes to secrets/flora.env"
ok "hermes binary: $HB"

# A first run creates the skills tree and the state database.
"$FLORA_STATE/bin/hermes" doctor >/dev/null 2>&1 || true
ensure_dir "$HERMES_HOME/skills"
ok "HERMES_HOME=$HERMES_HOME"
