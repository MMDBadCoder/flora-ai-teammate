#!/usr/bin/env bash
# Moves a running Flora onto the code currently checked out, keeping all data.
#
#   git pull --rebase origin main     <-- do this FIRST, by hand
#   sudo bin/flora upgrade
#
# The pull is deliberately not done here: bash reads a script as it runs, so a
# script that rewrites itself mid-execution is a good way to get half of two
# versions.
#
# What is preserved: everything in state/ and secrets/ -- TokenRing's key pool,
# Hermes' sessions, memories and config, OpenCode's sessions, Mattermost's
# database, every credential -- and shared/, which is in git.
#
# What changes: the rendered configs, the systemd units, and whatever nginx
# arrangement the current settings ask for.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env
need_root

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

step "Upgrade"
log "checked out: $(git -C "$FLORA_HOME" log --oneline -1 2>/dev/null || echo 'not a git repository')"

# --- 1. uncommitted skill work ---------------------------------------------
if [[ -d "$FLORA_HOME/.git" ]]; then
  dirty="$(git -C "$FLORA_HOME" status --porcelain -- shared/ 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    warn "shared/ has uncommitted changes:"
    sed 's/^/       /' <<< "$dirty"
    log "committing them so they are not lost in a later rebase"
    git -C "$FLORA_HOME" add shared/
    git -C "$FLORA_HOME" -c user.name=Flora -c user.email="flora@${FLORA_DOMAIN}" \
      commit -q -m "skills: local changes before upgrade" && ok "committed"
  else
    ok "shared/ is clean"
  fi
fi

# --- 2. a snapshot to fall back to -----------------------------------------
SNAP="/tmp/flora-preupgrade-$(date +%Y%m%d-%H%M%S).tar.gz"
log "snapshotting the data that cannot be reinstalled"
if tar czf "$SNAP" -C "$FLORA_HOME" \
     --exclude='state/hermes/agent' --exclude='state/hermes/tools' \
     --exclude='state/opencode/npm' --exclude='state/tokenring/src' \
     --exclude='state/*/xdg/cache' --exclude='state/mattermost/bleve-indexes' \
     secrets shared flora.env state 2>/dev/null; then
  chmod 0600 "$SNAP"
  ok "snapshot: $SNAP ($(du -h "$SNAP" | cut -f1))"
  log "it holds your secrets; delete it once the upgrade looks right"
else
  warn "could not write a snapshot; continuing without one"
fi

if [[ "$ASSUME_YES" != "1" ]]; then
  echo
  read -rp "Stop the services and upgrade? [y/N]: " answer
  [[ "$answer" =~ ^[Yy] ]] || die "aborted; nothing was changed"
fi

# --- 3. remove the old system integration ----------------------------------
# Not --purge: this keeps state/ and secrets/. It matters because the previous
# version may have installed things the current one does not use -- a host nginx
# config, a unit that has been renamed -- and those would otherwise linger.
"$FLORA_HOME/scripts/uninstall.sh" --yes | sed 's/^/  /'

# --- 4. put the current version in place -----------------------------------
step "Reinstalling on the current code"
"$FLORA_HOME/scripts/bootstrap-secrets.sh" | sed 's/^/  /'
"$FLORA_HOME/scripts/render.sh"            | sed 's/^/  /'
"$FLORA_HOME/scripts/install-tokenring.sh" | sed 's/^/  /'
"$FLORA_HOME/scripts/install-hermes.sh"    | sed 's/^/  /'
"$FLORA_HOME/scripts/install-opencode.sh"  | sed 's/^/  /'
[[ "$FLORA_ENABLE_MATTERMOST" == "true" ]] && "$FLORA_HOME/scripts/install-mattermost.sh" | sed 's/^/  /'
"$FLORA_HOME/scripts/render.sh"            | sed 's/^/  /'
"$FLORA_HOME/scripts/skills-sync.sh"       | sed 's/^/  /'
"$FLORA_HOME/scripts/install-hosts.sh"     | sed 's/^/  /'
"$FLORA_HOME/scripts/install-nginx.sh"     | sed 's/^/  /'
"$FLORA_HOME/scripts/install-systemd.sh"   | sed 's/^/  /'
sd start flora.target || true

step "Result"
sleep 3
"$FLORA_HOME/scripts/health.sh" || true
echo
"$FLORA_HOME/scripts/doctor.sh" || true
echo
log "If anything is wrong, the pre-upgrade data is in $SNAP"
log "Restore it with:  tar xzf $SNAP -C $FLORA_HOME"
