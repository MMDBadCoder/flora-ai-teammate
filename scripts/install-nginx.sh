#!/usr/bin/env bash
# Installs the Flora vhosts into nginx and reloads it.
#
# Safety: the config is validated with `nginx -t` BEFORE the running server is
# touched, and the previous file is restored if validation fails. An existing
# nginx serving other sites keeps serving them -- Flora only adds name-based
# vhosts and never claims default_server.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env
need_root
need_cmd nginx "apt install nginx"

step "nginx"
SRC="$FLORA_STATE/nginx/flora.conf"
DST=/etc/nginx/conf.d/flora.conf
[[ -f "$SRC" ]] || die "run scripts/render.sh first"

# --- the account file (FLORA_AUTH_MODE=nginx) -------------------------------
if [[ "$FLORA_AUTH_MODE" == "nginx" && ! -s "$FLORA_STATE/nginx/htpasswd" ]]; then
  log "creating the first account: $FLORA_ADMIN_USER"
  "$FLORA_HOME/scripts/users.sh" add "$FLORA_ADMIN_USER" "$(secret_get flora.env FLORA_ADMIN_PASSWORD)"
fi

# --- nginx must be able to traverse into the Flora directory ----------------
# It runs as www-data; a 0700 parent anywhere on the path yields a silent 403.
p="$FLORA_HOME"
while [[ "$p" != "/" ]]; do
  if [[ "$(stat -c %a "$p")" =~ ^[0-7][0-7][0-6]$ ]]; then
    chmod o+x "$p" && ok "chmod o+x $p (nginx needs to traverse it)"
  fi
  p="$(dirname "$p")"
done
chmod -R a+rX "$FLORA_HOME/web/dashboard"
ensure_dir "$FLORA_STATE/dashboard"; chmod a+rx "$FLORA_STATE/dashboard"
ensure_dir "$FLORA_STATE/logs";      chmod a+rx "$FLORA_STATE/logs"
[[ -f "$FLORA_STATE/nginx/htpasswd" ]] && chmod a+r "$FLORA_STATE/nginx/htpasswd"
chmod a+rx "$FLORA_STATE/nginx"

# --- install with rollback --------------------------------------------------
backup=""
if [[ -f "$DST" ]]; then
  if cmp -s "$SRC" "$DST"; then
    skip "$DST unchanged"
  else
    backup="$(mktemp)"; cp "$DST" "$backup"
  fi
fi

if ! cmp -s "$SRC" "$DST"; then
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
ok "nginx reloaded"

echo
log "Flora is served on port $FLORA_HTTP_PORT for these names:"
for h in "$FLORA_HOST_DASHBOARD" "$FLORA_HOST_HERMES" "$FLORA_HOST_OPENCODE" "$FLORA_HOST_CHAT" "$FLORA_HOST_TOKENS"; do
  printf '    http://%s%s\n' "$h" "$FLORA_URL_PORT"
done
