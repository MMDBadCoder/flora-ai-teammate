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
# Generated, therefore under state/: a generated file in the repository shows up
# as an uncommitted change on every machine whose settings differ, and then blocks
# the next git pull.
render "$T/dashboard.html.tmpl" "$FLORA_STATE/dashboard/index.html" 0644

# --- nginx ------------------------------------------------------------------
case "${FLORA_ROUTING:-ports}" in
  ports) render "$T/nginx/flora-ports.conf.tmpl" "$FLORA_STATE/nginx/flora.conf" 0644 ;;
  hosts) render "$T/nginx/flora-hosts.conf.tmpl" "$FLORA_STATE/nginx/flora.conf" 0644 ;;
  *) die "FLORA_ROUTING must be 'ports' or 'hosts' (got: $FLORA_ROUTING)" ;;
esac

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
  render "$tmpl" "$FLORA_STATE/systemd/$unit" 0644
done

ensure_ownership

echo
ok "configuration rendered into state/"
