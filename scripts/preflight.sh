#!/usr/bin/env bash
# Checks the machine can host Flora before anything is installed.
# Read-only: it never changes the system. Exit 1 means "do not continue".
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

fail=0
note() { warn "$*"; fail=1; }

step "Preflight"

# --- commands ---------------------------------------------------------------
for c in curl git node npm python3 openssl ss awk sed tar; do
  if have_cmd "$c"; then ok "found $c"; else note "missing $c"; fi
done
have_cmd nginx   || note "missing nginx (apt install nginx)"
have_cmd docker  || note "missing docker (Mattermost needs it)"
have_cmd htpasswd || warn "missing htpasswd (apt install apache2-utils) -- needed for FLORA_AUTH_MODE=nginx"
docker compose version >/dev/null 2>&1 || note "docker compose v2 plugin not available"

# --- versions ---------------------------------------------------------------
if have_cmd node; then
  nodemajor=$(node -p 'process.versions.node.split(".")[0]')
  [[ "$nodemajor" -ge 20 ]] && ok "node $(node -v)" || note "node >= 20.11 required (found $(node -v))"
fi
if have_cmd python3; then
  pyok=$(python3 -c 'import sys; print(1 if sys.version_info>=(3,11) else 0)')
  [[ "$pyok" == 1 ]] && ok "python $(python3 -V 2>&1 | awk '{print $2}')" || note "python >= 3.11 required"
fi

# --- ports ------------------------------------------------------------------
for p in "$FLORA_PORT_TOKENRING tokenring" "$FLORA_PORT_HERMES hermes" \
         "$FLORA_PORT_OPENCODE opencode" "$FLORA_PORT_MATTERMOST mattermost"; do
  set -- $p
  if port_free "$1"; then ok "port $1 free ($2)"
  else
    if ss -ltnp 2>/dev/null | grep -qE "[:.]$1 .*flora|[:.]$1 .*docker"; then
      skip "port $1 already held by Flora ($2)"
    else
      note "port $1 is in use by something else -- change FLORA_PORT_${2^^} in flora.env"
    fi
  fi
done

# --- resources --------------------------------------------------------------
free_gb=$(df -BG --output=avail "$FLORA_HOME" | tail -1 | tr -dc '0-9')
[[ "$free_gb" -ge 15 ]] && ok "${free_gb}G free on $FLORA_HOME" \
  || note "only ${free_gb}G free on $FLORA_HOME (15G+ recommended: Mattermost, node_modules, sessions, clones)"
mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
[[ "$mem_mb" -ge 3500 ]] && ok "${mem_mb}MB RAM" || note "only ${mem_mb}MB RAM (4GB+ recommended)"

# --- nginx sanity -----------------------------------------------------------
if have_cmd nginx; then
  if [[ -d /etc/nginx/conf.d ]]; then ok "/etc/nginx/conf.d exists"
  else note "/etc/nginx/conf.d missing -- adjust scripts/install-nginx.sh"; fi
  if nginx -T 2>/dev/null | grep -qE "listen\s+${FLORA_HTTP_PORT}(\s|;).*default_server"; then
    warn "another vhost owns :${FLORA_HTTP_PORT} as default_server -- fine, Flora uses name-based vhosts and will not take it over"
  fi
fi

echo
if [[ "$fail" -eq 0 ]]; then ok "preflight passed"; else die "preflight found blocking problems (see above)"; fi
