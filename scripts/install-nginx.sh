#!/usr/bin/env bash
# Brings the Flora vhosts up, either in Flora's own nginx container
# (FLORA_NGINX=docker, the default) or in the host's nginx (FLORA_NGINX=host).
#
# Both paths validate the configuration before anything serving is touched.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

SRC="$FLORA_STATE/nginx/flora.conf"
[[ -f "$SRC" ]] || die "run scripts/render.sh first"

step "nginx (${FLORA_NGINX:-docker})"

# --- the account file (FLORA_AUTH_MODE=nginx) -------------------------------
if [[ "$FLORA_AUTH_MODE" == "nginx" && ! -s "$FLORA_STATE/nginx/htpasswd" ]]; then
  log "creating the first account: $FLORA_ADMIN_USER"
  "$FLORA_HOME/scripts/users.sh" add "$FLORA_ADMIN_USER" "$(secret_get flora.env FLORA_ADMIN_PASSWORD)"
fi

# nginx runs as an unprivileged user in both cases and has to traverse into the
# tree; a 0700 directory anywhere on the path yields a silent 403.
p="$FLORA_HOME"
while [[ "$p" != "/" ]]; do
  if [[ "$(stat -c %a "$p")" =~ ^[0-7][0-7][0-6]$ ]]; then
    chmod o+x "$p" && ok "chmod o+x $p (nginx needs to traverse it)"
  fi
  p="$(dirname "$p")"
done
chmod -R a+rX "$FLORA_STATE/dashboard"
for d in "$FLORA_STATE/dashboard" "$FLORA_STATE/logs" "$FLORA_STATE/nginx"; do
  ensure_dir "$d"; chmod a+rx "$d"
done
[[ -f "$FLORA_STATE/nginx/htpasswd" ]] && chmod a+r "$FLORA_STATE/nginx/htpasswd"

print_urls() {
  echo
  log "Flora is reachable at:"
  printf '    %-12s %s\n' dashboard  "$FLORA_URL_DASHBOARD"
  printf '    %-12s %s\n' hermes     "$FLORA_URL_HERMES"
  printf '    %-12s %s\n' opencode   "$FLORA_URL_OPENCODE"
  printf '    %-12s %s\n' mattermost "$FLORA_URL_CHAT"
  printf '    %-12s %s\n' tokenring  "$FLORA_URL_TOKENS"
  if [[ "${FLORA_ROUTING:-ports}" == "ports" ]]; then
    echo
    log "No DNS and no /etc/hosts needed. Send the team the dashboard link."
  fi
}

# ============================================================ docker nginx ===
if [[ "${FLORA_NGINX:-docker}" == "docker" ]]; then
  need_cmd docker "apt install docker.io docker-compose-v2"
  COMPOSE="$FLORA_STATE/nginx/docker-compose.yml"
  [[ -f "$COMPOSE" ]] || die "run scripts/render.sh first (no docker-compose.yml for nginx)"

  # Validate the generated config in a throwaway container before it can take
  # a serving one down.
  log "validating the configuration"
  if ! docker run --rm \
        -v /dev/null:/etc/nginx/conf.d/default.conf:ro \
        -v "$SRC:/etc/nginx/conf.d/flora.conf:ro" \
        -v "$FLORA_STATE/nginx:$FLORA_STATE/nginx:ro" \
        
        -v "$FLORA_STATE/dashboard:$FLORA_STATE/dashboard:ro" \
        -v "$FLORA_STATE/logs:$FLORA_STATE/logs:rw" \
        nginx:1.27-alpine nginx -t 2>&1 | sed 's/^/    /'; then
    die "nginx rejected the generated config (see above); nothing was started"
  fi

  log "starting Flora's nginx"
  docker compose -f "$COMPOSE" up -d --remove-orphans
  ok "flora-nginx is up"
  log "nothing was written to /etc/nginx; this nginx is Flora's own"
  print_urls
  exit 0
fi

# ============================================================== host nginx ===
need_root
need_cmd nginx "apt install nginx -- or set FLORA_NGINX=docker and let Flora run her own"
DST=/etc/nginx/conf.d/flora.conf

backup=""
if [[ -f "$DST" ]] && ! cmp -s "$SRC" "$DST"; then
  backup="$(mktemp)"; cp "$DST" "$backup"
fi

if cmp -s "$SRC" "$DST" 2>/dev/null; then
  skip "$DST unchanged"
else
  cp "$SRC" "$DST"
  if nginx -t 2>&1 | sed 's/^/    /'; then
    ok "config valid"
  else
    if [[ -n "$backup" ]]; then cp "$backup" "$DST"; err "restored the previous $DST"; else rm -f "$DST"; fi
    die "nginx rejected the generated config (see above); nothing was reloaded"
  fi
fi

nginx -t >/dev/null 2>&1 || die "nginx config is broken (not by Flora); fix it before reloading"
systemctl reload nginx 2>/dev/null || nginx -s reload
ok "host nginx reloaded"
print_urls
