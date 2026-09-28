#!/usr/bin/env bash
# Renders every template into state/. Idempotent: unchanged files are left
# alone and reported as [same], so you can watch exactly what a config change
# actually touched.
#
# This is the ONLY writer of the live configs. Never edit state/**/config files
# by hand -- edit config/templates/** and re-run this.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Render configuration"

# Must run before anything is written. It used to run at the end of this
# script, after the systemd unit files were already staged in state/systemd/
# -- so a die() here still left a ready-to-install, unauthenticated-shell
# config on disk for a subsequent `bin/flora systemd` (which does no
# validation of its own) to happily activate. A render that refuses to
# proceed should refuse before producing anything, not after.
check_bind_safety

T="$FLORA_HOME/config/templates"

# --- directories ------------------------------------------------------------
ensure_dir "$FLORA_STATE/hermes/home"
ensure_dir "$FLORA_STATE/hermes/xdg"
ensure_dir "$FLORA_STATE/opencode/config"
ensure_dir "$FLORA_STATE/opencode/home"
ensure_dir "$FLORA_STATE/opencode/xdg"
ensure_dir "$FLORA_STATE/tokenring/data"
ensure_dir "$FLORA_STATE/mattermost"
ensure_dir "$FLORA_STATE/nginx"
ensure_dir "$FLORA_STATE/systemd"
ensure_dir "$FLORA_STATE/dashboard"
ensure_dir "$FLORA_STATE/logs"
ensure_dir "$FLORA_STATE/bin"
ensure_dir "$FLORA_SHARED/skills"
ensure_dir "$FLORA_SHARED/agents"
ensure_dir "$FLORA_SHARED/mcp"

# Install any shipped default that is not there yet. Never overwrites a live file.
"$FLORA_HOME/scripts/seed.sh" | sed 's/^/  /'


# --- MCP: one shared list, injected into OpenCode's config ------------------
# Hermes gets the same servers through scripts/agents-sync.sh, which calls
# `hermes mcp add`. The single source of truth is shared/mcp/servers.json.
OPENCODE_MCP_JSON="$(python3 "$FLORA_HOME/scripts/lib/mcp_render.py" opencode)"
export OPENCODE_MCP_JSON

# --- wrappers ---------------------------------------------------------------
render "$T/bin/hermes.tmpl"   "$FLORA_STATE/bin/hermes"   0755
render "$T/bin/opencode.tmpl" "$FLORA_STATE/bin/opencode" 0755

# --- agents -----------------------------------------------------------------
render "$T/hermes/config.yaml.tmpl" "$HERMES_HOME/config.yaml"      0644
render "$T/hermes/env.tmpl"         "$HERMES_HOME/.env"             0600
render "$T/opencode/opencode.json.tmpl" "$OPENCODE_CONFIG_DIR/opencode.json" 0644

# --- services ---------------------------------------------------------------
render "$T/tokenring/env.tmpl" "$FLORA_STATE/tokenring/tokenring.env" 0600
render "$T/mattermost/docker-compose.yml.tmpl" "$FLORA_STATE/mattermost/docker-compose.yml" 0644

# --- dashboard --------------------------------------------------------------
# A port-mode tile gets data-port so the page can rebuild its link against
# whatever host the browser used; a subdomain tile must keep its absolute URL.
for svc in HERMES OPENCODE CHAT TOKENS SCRIBE; do
  port_var="FLORA_PUBLIC_$svc"
  if [[ "$(flora_route_mode "$svc")" == "port" ]]; then
    printf -v "FLORA_TILE_$svc" 'data-port="%s"' "${!port_var}"
  else
    printf -v "FLORA_TILE_$svc" '%s' ""
  fi
  export "FLORA_TILE_$svc"
done

# Optional modules contribute a whole tile or nothing at all, rather than a
# dead link to a service that is not running.
if [[ "$FLORA_ENABLE_SCRIBE" == "true" ]]; then
  FLORA_TILE_SCRIBE_HTML=$(cat <<TILE

    <li><a class="tile" href="$FLORA_URL_SCRIBE" data-svc="scribe" $FLORA_TILE_SCRIBE>
      <div><div class="name">Scribe <kbd>5</kbd></div>
           <div class="what">Meeting audio &rarr; Persian text</div></div>
      <div class="state"><span class="dot"></span><span class="txt">…</span></div></a></li>
TILE
)
else
  FLORA_TILE_SCRIBE_HTML=""
fi
export FLORA_TILE_SCRIBE_HTML

# Generated, therefore under state/: a generated file in the repository shows up
# as an uncommitted change on every machine whose settings differ, and then blocks
# the next git pull.
render "$T/dashboard.html.tmpl" "$FLORA_STATE/dashboard/index.html" 0644

# --- scribe (optional) ------------------------------------------------------
if [[ "$FLORA_ENABLE_SCRIBE" == "true" ]]; then
  ensure_dir "$FLORA_STATE/scribe/data"
  ensure_dir "$FLORA_STATE/scribe/models"
  render "$T/scribe/docker-compose.override.yml.tmpl" \
         "$FLORA_STATE/scribe/docker-compose.override.yml" 0644
  # Upstream reads .env from beside its own compose file, so it goes in the
  # checkout -- which only exists once install-scribe.sh has cloned it.
  if [[ -d "$FLORA_STATE/scribe/src" ]]; then
    render "$T/scribe/env.tmpl" "$FLORA_STATE/scribe/src/.env" 0600
  else
    skip "scribe not cloned yet; its .env is written by bin/flora install scribe"
  fi
fi

# --- nginx ------------------------------------------------------------------
# The server blocks are generated per service, because routing mode is a
# per-service choice; the template holds only what they share.
FLORA_NGINX_SERVERS="$(python3 "$FLORA_HOME/scripts/lib/nginx_render.py")" \
  || die "could not generate the nginx server blocks"
export FLORA_NGINX_SERVERS
render "$T/nginx/flora.conf.tmpl" "$FLORA_STATE/nginx/flora.conf" 0644

# Flora's own nginx, when she runs one.
if [[ "${FLORA_NGINX:-docker}" == "docker" ]]; then
  render "$T/nginx/docker-compose.yml.tmpl" "$FLORA_STATE/nginx/docker-compose.yml" 0644

  # Docker bind-mounts flora.conf as a single file (see the compose template),
  # and write_if_changed() replaces files via mktemp (a different filesystem)
  # + mv -- a rename, which gives the target a NEW inode. A single-file bind
  # mount keeps pointing at the inode it saw at mount time, so the running
  # container would silently keep serving whatever flora.conf said the moment
  # nginx last started, no matter how many times it changes after that.
  # Confirmed live: a routing change here was validated, "reloaded" logged
  # success, and the container kept the previous config anyway.
  #
  # The directory mount two lines below this one in the compose file (the
  # whole of state/nginx, read-only) does NOT have this problem -- a
  # directory mount resolves the name inside it fresh on every access, so
  # auth.conf and dashboard-auth.conf, which are only ever reached through
  # that mount, always see current content. This loader is the fix: its own
  # content never changes across renders (FLORA_HOME doesn't change without
  # also changing the compose file, which does force a full container
  # recreation), so IT can safely be the thing bind-mounted as a single file,
  # and it simply hands off to the real, frequently-regenerated flora.conf by
  # `include`, resolved through the always-live directory mount instead.
  cat <<LOADER | write_if_changed "$FLORA_STATE/nginx/loader.conf"
# GENERATED, and deliberately near-constant -- see the comment in render.sh
# above the call that writes this file for why it exists at all.
include $FLORA_HOME/state/nginx/flora.conf;
LOADER
fi

case "$FLORA_AUTH_MODE" in
  nginx)
    cat <<AUTH | write_if_changed "$FLORA_STATE/nginx/auth.conf"
# GENERATED. FLORA_AUTH_MODE=nginx: one account list guards the agent UIs.
# Manage accounts with: bin/flora user add <name>
auth_basic "Flora";
auth_basic_user_file $FLORA_STATE/nginx/htpasswd;
AUTH
    ;;
  backend)
    cat <<AUTH | write_if_changed "$FLORA_STATE/nginx/auth.conf"
# GENERATED. FLORA_AUTH_MODE=backend: each backend enforces its own password
# (HERMES_DASHBOARD_BASIC_AUTH_*, OPENCODE_SERVER_PASSWORD), nginx only proxies.
AUTH
    ;;
  *) die "FLORA_AUTH_MODE must be 'nginx' or 'backend' (got: $FLORA_AUTH_MODE)" ;;
esac

# The dashboard is static content with no backend of its own to enforce a
# password -- in FLORA_AUTH_MODE=backend, auth.conf above is deliberately a
# no-op for the services that DO have their own gate, but the dashboard has
# none, so that same no-op would leave it wide open. It costs nothing to keep
# gated regardless of mode (no backend password to conflict with), so it gets
# its own always-on account-list file instead of sharing auth.conf.
cat <<AUTH | write_if_changed "$FLORA_STATE/nginx/dashboard-auth.conf"
# GENERATED. The dashboard has no backend of its own, so it stays behind the
# account list in every FLORA_AUTH_MODE. Manage accounts with: bin/flora user add <name>
auth_basic "Flora";
auth_basic_user_file $FLORA_STATE/nginx/htpasswd;
AUTH

# --- systemd ----------------------------------------------------------------
for tmpl in "$T"/systemd/*.tmpl; do
  unit="$(basename "$tmpl" .tmpl)"
  # The nginx unit only makes sense when Flora runs her own.
  if [[ "$unit" == "flora-nginx.service" && "${FLORA_NGINX:-docker}" != "docker" ]]; then
    rm -f "$FLORA_STATE/systemd/$unit"
    continue
  fi
  # An optional module that is switched off leaves no unit behind, so
  # `bin/flora systemd` cannot install and start something nobody asked for.
  if [[ "$unit" == "flora-scribe.service" && "$FLORA_ENABLE_SCRIBE" != "true" ]]; then
    rm -f "$FLORA_STATE/systemd/$unit"
    continue
  fi
  render "$tmpl" "$FLORA_STATE/systemd/$unit" 0644
done

ensure_ownership

echo
ok "configuration rendered into state/"
