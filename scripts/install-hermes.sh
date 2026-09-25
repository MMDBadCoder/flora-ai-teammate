#!/usr/bin/env bash
# Installs a Hermes that belongs to Flora and to nothing else.
#
# ISOLATION. The upstream installer puts the agent in $HERMES_HOME/hermes-agent
# and the real launcher at $INSTALL_DIR/.hermes/bin/hermes -- the ~/.local/bin
# entry is only a PATH shim. So pointing HERMES_HOME, HERMES_INSTALL_DIR and
# HERMES_RUNTIME_DIR into state/hermes gives Flora her own copy of the code, her
# own Python runtime and her own tools, sharing nothing with a Hermes that was
# already on this machine.
#
# HOME is redirected too. The installer appends PATH lines to ~/.bashrc and
# ~/.profile and drops shims in ~/.local/bin; with HOME pointed at
# state/hermes/fs-home those edits land inside the Flora tree instead of in the
# operator's dotfiles. It also means Flora does not silently inherit ~/.ssh or
# ~/.gitconfig -- see docs/07-integrations.md for giving her a key of her own.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

AGENT_DIR="$FLORA_STATE/hermes/agent"          # the checkout + venv
FS_HOME="$FLORA_STATE/hermes/fs-home"          # the HOME the installer sees
TOOLS_DIR="$FLORA_STATE/hermes/tools"          # uv, ripgrep, playwright, ...
PRIVATE_BIN="$AGENT_DIR/.hermes/bin/hermes"

step "Hermes"
record_external_installs

ensure_dir "$HERMES_HOME"
ensure_dir "$AGENT_DIR"
ensure_dir "$FS_HOME/.local/bin"
ensure_dir "$TOOLS_DIR"
ensure_dir "$FLORA_STATE/hermes/xdg/data"
ensure_dir "$FLORA_STATE/hermes/xdg/cache"
ensure_dir "$FLORA_STATE/hermes/xdg/state"

# ---------------------------------------------------------- already private --
if [[ -x "$PRIVATE_BIN" ]]; then
  ver="$("$FLORA_STATE/bin/hermes" --version 2>/dev/null | head -1 || echo unknown)"
  if [[ "${FLORA_UPDATE:-0}" != "1" ]]; then
    skip "Hermes is installed privately ($ver)"
    ok "binary: ${PRIVATE_BIN/#$FLORA_HOME/.}"
    exit 0
  fi
  log "updating Flora's own Hermes (this does not touch any other install)"
  "$FLORA_STATE/bin/hermes" update --backup || warn "hermes update failed; keeping $ver"
  exit 0
fi

# --------------------------------- cleaning up an earlier, non-isolated install --
# Before isolation, the installer was run with only HERMES_HOME set, so the
# agent landed at $HERMES_HOME/hermes-agent and the shims went into the
# operator's ~/.local/bin. Anything left from that is removed here: it is a
# re-downloadable checkout, and leaving it costs a couple of gigabytes and a
# `hermes` on PATH that quietly is not the one Flora runs.
LEGACY_AGENT="$HERMES_HOME/hermes-agent"
if [[ -d "$LEGACY_AGENT" ]]; then
  warn "found an earlier, non-isolated install at ${LEGACY_AGENT/#$FLORA_HOME/.}"
  log "removing it; the private install below replaces it"
  rm -rf "$LEGACY_AGENT"
  ok "removed ${LEGACY_AGENT/#$FLORA_HOME/.}"
fi
for shim in "$HOME/.local/bin/hermes" "$HOME/.local/bin/hermes-gateway"; do
  if [[ -e "$shim" ]] && ! is_external_known "$HOME/.hermes"; then
    warn "an earlier run left a shim at $shim.
       It is not what Flora uses. Remove it if you do not run Hermes yourself:
         rm -f $shim"
  fi
done
# A failed interactive run can leave a user unit behind, pointing at a binary
# that is about to be replaced.
for unit in "$HOME"/.config/systemd/user/hermes-gateway-*.service; do
  [[ -e "$unit" ]] || continue
  warn "an earlier run left a systemd user unit: $unit
       Flora supervises its own gateway (flora-hermes-gateway.service). Remove it:
         rm -f $unit"
done

# --------------------------------------------- migrating off a shared binary --
old_bin="$(secret_get flora.env FLORA_HERMES_BIN 2>/dev/null || true)"
if [[ -n "$old_bin" && "$old_bin" != "$FLORA_HOME"* ]]; then
  warn "Flora was using a Hermes binary outside its tree:
       $old_bin
     Installing a private copy now. The other install is left exactly as it is,
     and Flora's sessions and skills in state/hermes/home are unaffected."
  sed -i '/^FLORA_HERMES_BIN=/d' "$FLORA_HOME/secrets/flora.env"
fi

# ------------------------------------------------------------------ install --
need_cmd curl "apt install curl"
need_cmd git "apt install git"

args=(--non-interactive)
# Playwright is a large download and the most common way a first install fails
# on a restricted network. Off by default; set FLORA_HERMES_BROWSER=true in
# flora.env if you want Flora to be able to drive a browser.
if [[ "${FLORA_HERMES_BROWSER:-false}" != "true" ]]; then
  args+=(--skip-browser)
  log "browser tooling skipped (FLORA_HERMES_BROWSER=true to include it)"
fi

log "installing Hermes into ${AGENT_DIR/#$FLORA_HOME/.} (a few minutes)"
installer="$(mktemp)"; trap 'rm -f "$installer"' EXIT
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$installer" \
  || die "could not download the Hermes installer"

env -i \
  HOME="$FS_HOME" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  TERM="${TERM:-dumb}" \
  LANG="${LANG:-C.UTF-8}" \
  HERMES_HOME="$HERMES_HOME" \
  HERMES_INSTALL_DIR="$AGENT_DIR" \
  HERMES_RUNTIME_DIR="$TOOLS_DIR" \
  NON_INTERACTIVE=true \
  bash "$installer" "${args[@]}" \
  || die "the Hermes installer failed. Its log is at:
     $HERMES_HOME/logs/install.log
     Re-run with FLORA_HERMES_VERBOSE=1 for more, or install by hand and set
     FLORA_HERMES_BIN=/path/to/hermes in secrets/flora.env."

[[ -x "$PRIVATE_BIN" ]] || die "the installer finished but $PRIVATE_BIN is missing.
     Check $HERMES_HOME/logs/install.log"

secret_set flora.env FLORA_HERMES_BIN "$PRIVATE_BIN"
ok "Hermes installed privately: ${PRIVATE_BIN/#$FLORA_HOME/.}"

# The wrapper is what everything else calls; make sure it can see the binary.
"$FLORA_STATE/bin/hermes" --version >/dev/null 2>&1 \
  && ok "hermes: $("$FLORA_STATE/bin/hermes" --version 2>&1 | head -1)" \
  || warn "the wrapper cannot run the binary yet; run bin/flora render and retry"

# Hermes ships a background skill curator, enabled by default, that prunes and
# archives skills on its own every 7 days. Flora's skills are SHARED with
# OpenCode and tracked in git, so nothing gets to rewrite them unattended.
# Re-enable it deliberately with: bin/flora hermes curator resume
if "$FLORA_STATE/bin/hermes" curator status 2>/dev/null | grep -qi 'ENABLED'; then
  "$FLORA_STATE/bin/hermes" curator pause >/dev/null 2>&1 \
    && ok "paused Hermes' built-in skill curator (shared skills are not rewritten unattended)" \
    || warn "could not pause the built-in curator; do it with: bin/flora hermes curator pause"
fi

ensure_dir "$HERMES_HOME/skills"
ok "HERMES_HOME=${HERMES_HOME/#$FLORA_HOME/.}"
