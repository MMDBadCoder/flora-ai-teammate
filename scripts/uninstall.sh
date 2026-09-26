#!/usr/bin/env bash
# Removes Flora from the system.
#
#   uninstall.sh              system integration only -- DATA IS KEPT
#   uninstall.sh --purge      also deletes state/, secrets/ and workspace clones
#   uninstall.sh --yes        skip the confirmation prompt
#
# Without --purge this is the reset you want before reinstalling: services,
# units, nginx config and /etc/hosts go, while sessions, memories, skills, the
# key pool and the chat history stay exactly where they are.
#
# It never touches the git checkout, so `git pull` afterwards is safe.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

PURGE=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) die "usage: uninstall.sh [--purge] [--yes]" ;;
  esac
done

step "What will be removed"
echo
echo "  systemd     $(flora_units | tr '\n' ' ')"
echo "              $(flora_timers | tr '\n' ' ') flora-skills-sync.path flora.target"
echo "  nginx       /etc/nginx/conf.d/flora.conf   (then a reload)"
echo "  /etc/hosts  the flora block"
echo "  docker      flora-mattermost, flora-mm-postgres, flora-nginx"
echo
if [[ "$PURGE" == "1" ]]; then
  printf '  %sDELETED TOO (--purge):%s\n' "$_c_red$_c_bold" "$_c_reset"
  printf '    state/      %s   sessions, memories, key pool, chat history, both agents\n' "$(du -sh state 2>/dev/null | cut -f1 || echo '-')"
  printf '    secrets/    every credential, including TOKENRING_ENCRYPTION_KEY\n'
  printf '    workspace/  %s   repository clones\n' "$(du -sh workspace 2>/dev/null | cut -f1 || echo '-')"
  echo
  printf '  %sThere is no backup tooling. Anything not pushed to Gerrit or git is gone.%s\n' "$_c_ylw" "$_c_reset"
else
  echo "  KEPT        state/ secrets/ workspace/ shared/ -- reinstall picks up where it left off"
fi
echo
echo "  NEVER TOUCHED   the git checkout, your own Hermes/OpenCode, other nginx sites"
echo

if [[ "$ASSUME_YES" != "1" ]]; then
  if [[ "$PURGE" == "1" ]]; then
    read -rp "Type 'purge' to delete all of it: " answer
    [[ "$answer" == "purge" ]] || die "aborted; nothing was changed"
  else
    read -rp "Remove the system integration? [y/N]: " answer
    [[ "$answer" =~ ^[Yy] ]] || die "aborted; nothing was changed"
  fi
fi

# --- services ---------------------------------------------------------------
step "Services"
if has_systemd; then
  for u in $(flora_units) $(flora_timers) flora-skills-sync.path flora.target; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      ok "stopped and disabled $u"
    fi
  done
  removed=0
  for f in /etc/systemd/system/flora-*.service /etc/systemd/system/flora-*.timer \
           /etc/systemd/system/flora-*.path /etc/systemd/system/flora.target; do
    [[ -e "$f" ]] || continue
    rm -f "$f"; removed=$((removed+1))
  done
  if [[ "$removed" -gt 0 ]]; then
    systemctl daemon-reload
    # A unit that was failing when it was removed lingers in the listing as
    # "not-found failed" until its state is cleared, which looks like leftovers.
    systemctl reset-failed 'flora*' 2>/dev/null || true
    ok "removed $removed unit file(s)"
  else
    skip "no unit files installed"
  fi
else
  warn "no systemd here; stop any processes you started by hand"
fi

# --- containers -------------------------------------------------------------
step "Containers"
if have_cmd docker; then
  for c in "$FLORA_STATE/mattermost/docker-compose.yml:Mattermost" "$FLORA_STATE/nginx/docker-compose.yml:nginx"; do
    file="${c%:*}"; label="${c##*:}"
    [[ -f "$file" ]] || continue
    docker compose -f "$file" down --remove-orphans >/dev/null 2>&1 \
      && ok "stopped and removed the $label container(s)" \
      || skip "no $label containers running"
  done
else
  skip "no docker here"
fi

# --- nginx ------------------------------------------------------------------
step "host nginx"
if [[ -f /etc/nginx/conf.d/flora.conf ]]; then
  rm -f /etc/nginx/conf.d/flora.conf
  ok "removed /etc/nginx/conf.d/flora.conf"
  if have_cmd nginx && nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    ok "nginx reloaded; your other sites are unaffected"
  else
    warn "nginx -t fails for reasons unrelated to Flora; did not reload"
  fi
else
  skip "nothing in /etc/nginx (Flora ran her own nginx)"
fi

# --- /etc/hosts -------------------------------------------------------------
step "/etc/hosts"
remove_block /etc/hosts hostnames

# --- data -------------------------------------------------------------------
if [[ "$PURGE" == "1" ]]; then
  step "Data"
  # Explicit paths only. Never a variable that could be empty and turn this into
  # `rm -rf /`.
  for d in "$FLORA_HOME/state" "$FLORA_HOME/secrets"; do
    [[ -d "$d" ]] || continue
    [[ "$d" == "$FLORA_HOME"/* ]] || die "refusing to delete $d: outside $FLORA_HOME"
    rm -rf "$d"; ok "deleted ${d/#$FLORA_HOME/.}"
  done
  if [[ -d "$FLORA_HOME/workspace" ]]; then
    find "$FLORA_HOME/workspace" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
    ok "emptied ./workspace"
  fi
  rm -f "$FLORA_HOME/flora.env"; ok "deleted ./flora.env"

fi

step "Done"
if [[ "$PURGE" == "1" ]]; then
  log "Flora is gone. To start over:"
  log "    git pull --rebase origin main"
  log "    cp flora.env.example flora.env   &&   \$EDITOR flora.env"
  log "    sudo ./bin/flora bootstrap"
else
  log "System integration removed; your data is still in state/ and secrets/."
  log "To reinstall on the current code:"
  log "    git pull --rebase origin main"
  log "    sudo ./bin/flora bootstrap"
  log "To delete the data too:  bin/flora uninstall --purge"
fi
