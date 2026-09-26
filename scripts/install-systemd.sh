#!/usr/bin/env bash
# Installs the rendered units into /etc/systemd/system and enables the ones
# the feature switches in flora.env turn on. Re-running it picks up template
# changes; units whose content did not change are not restarted.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env
need_root
has_systemd || die "no systemd on this machine. See docs/09-troubleshooting.md for the
     docker-compose fallback that supervises the same four services."
check_bind_safety

step "systemd units"
changed=0
for src in "$FLORA_STATE"/systemd/*; do
  unit="$(basename "$src")"
  dst="/etc/systemd/system/$unit"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then skip "$unit"; continue; fi
  cp "$src" "$dst"; ok "installed $unit"; changed=1
done
[[ "$changed" == 1 ]] && systemctl daemon-reload && ok "daemon-reload"

enable_if() { # enable_if <flag> <unit...>
  local flag="$1"; shift
  if [[ "$flag" == "true" ]]; then systemctl enable "$@" >/dev/null 2>&1 && ok "enabled $*"
  else systemctl disable "$@" >/dev/null 2>&1 || true; skip "disabled $*"; fi
}
enable_if "$FLORA_ENABLE_TOKENRING"  flora-tokenring.service
enable_if "$FLORA_ENABLE_HERMES"     flora-hermes-dashboard.service flora-hermes-gateway.service
enable_if "$FLORA_ENABLE_OPENCODE"   flora-opencode.service
enable_if "$FLORA_ENABLE_MATTERMOST" flora-mattermost.service
if [[ "${FLORA_NGINX:-docker}" == "docker" ]]; then
  enable_if true flora-nginx.service
fi
systemctl enable flora.target >/dev/null 2>&1 && ok "enabled flora.target"

for t in $(flora_timers) flora-skills-sync.path; do
  systemctl enable --now "$t" >/dev/null 2>&1 && ok "enabled $t" || warn "could not enable $t"
done
ensure_ownership
ok "units installed"
