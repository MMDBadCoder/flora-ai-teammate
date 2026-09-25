#!/usr/bin/env bash
# Prepares the Mattermost bind mounts and pulls the images.
# Starting/stopping is systemd's job (flora-mattermost.service).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Mattermost"
need_cmd docker "apt install docker.io, or follow docs.docker.com"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing"

MM="$FLORA_STATE/mattermost"
for d in config data logs plugins client-plugins bleve-indexes; do ensure_dir "$MM/$d"; done
ensure_dir "$MM/postgres"

# The official image runs as uid/gid 2000 and will not start if it cannot write
# these paths. Postgres keeps its own uid, so it is left alone.
if [[ "$(stat -c %u "$MM/data")" != "2000" ]]; then
  chown -R 2000:2000 "$MM/config" "$MM/data" "$MM/logs" "$MM/plugins" "$MM/client-plugins" "$MM/bleve-indexes"
  ok "chowned Mattermost mounts to 2000:2000"
else
  skip "Mattermost mounts already owned by 2000:2000"
fi
chmod 0700 "$MM/postgres"

[[ -f "$MM/docker-compose.yml" ]] || die "run scripts/render.sh first (docker-compose.yml not rendered yet)"

log "pulling images"
docker compose -f "$MM/docker-compose.yml" pull --quiet || warn "pull failed; will retry on start"
ok "Mattermost ready to start"
