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
render "$T/dashboard.html.tmpl" "$FLORA_HOME/web/dashboard/index.html" 0644

# --- nginx ------------------------------------------------------------------
case "${FLORA_ROUTING:-ports}" in
  ports) render "$T/nginx/flora-ports.conf.tmpl" "$FLORA_STATE/nginx/flora.conf" 0644 ;;
  hosts) render "$T/nginx/flora-hosts.conf.tmpl" "$FLORA_STATE/nginx/flora.conf" 0644 ;;
  *) die "FLORA_ROUTING must be 'ports' or 'hosts' (got: $FLORA_ROUTING)" ;;
esac

# Flora's own nginx, when she runs one.
if [[ "${FLORA_NGINX:-docker}" == "docker" ]]; then
  render "$T/nginx/docker-compose.yml.tmpl" "$FLORA_STATE/nginx/docker-compose.yml" 0644
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

# --- systemd ----------------------------------------------------------------
for tmpl in "$T"/systemd/*.tmpl; do
  unit="$(basename "$tmpl" .tmpl)"
  render "$tmpl" "$FLORA_STATE/systemd/$unit" 0644
done

# --- safety check on the bind address --------------------------------------
if [[ "$FLORA_BIND_ADDR" != "127.0.0.1" && "$FLORA_AUTH_MODE" != "backend" ]]; then
  die "FLORA_BIND_ADDR=$FLORA_BIND_ADDR exposes the agent UIs directly, but
     FLORA_AUTH_MODE=nginx only protects the nginx route. Anyone who reaches
     port $FLORA_PORT_OPENCODE or $FLORA_PORT_HERMES would get an unauthenticated
     shell on this machine. Set FLORA_AUTH_MODE=backend, or keep
     FLORA_BIND_ADDR=127.0.0.1."
fi

echo
ok "configuration rendered into state/"
