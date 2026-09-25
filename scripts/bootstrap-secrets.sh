#!/usr/bin/env bash
# Creates secrets/flora.env with strong random values on first run.
# Existing values are never touched, so this is safe to re-run: it only fills
# in what is missing. Placeholders for the integrations you have not wired up
# yet are seeded empty so config rendering never fails on an unset variable.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Secrets"
ensure_dir "$FLORA_HOME/secrets" 0700

# --- generated -------------------------------------------------------------
secret_set flora.env TOKENRING_ADMIN_PASSWORD
secret_set flora.env TOKENRING_ENCRYPTION_KEY "$(openssl rand -hex 32)"
secret_set flora.env MATTERMOST_DB_PASSWORD
secret_set flora.env HERMES_DASHBOARD_PASSWORD
secret_set flora.env OPENCODE_SERVER_PASSWORD
secret_set flora.env FLORA_ADMIN_PASSWORD

# --- filled in by hand or by a later step ----------------------------------
# The sk-ring key is issued in the TokenRing dashboard and pasted back with:
#   bin/flora tokenring key sk-ring-...
secret_set flora.env FLORA_TOKENRING_KEY "sk-ring-REPLACE-ME"
# The Mattermost bot token, from System Console -> Integrations -> Bot Accounts.
secret_set flora.env MATTERMOST_BOT_TOKEN ""
# Comma-separated Mattermost user IDs Flora will answer. EMPTY MEANS NOBODY.
secret_set flora.env MATTERMOST_ALLOWED_USERS ""

# --- integrations ----------------------------------------------------------
secret_set flora.env GERRIT_URL ""
secret_set flora.env GERRIT_USER "flora"
secret_set flora.env GERRIT_HTTP_PASSWORD ""
secret_set flora.env CONFLUENCE_URL ""
secret_set flora.env CONFLUENCE_USER ""
secret_set flora.env CONFLUENCE_TOKEN ""

chmod 0600 "$FLORA_HOME/secrets/flora.env"
ok "secrets/flora.env ready (mode 0600, git-ignored)"
echo
missing="$(grep -E '^[A-Z_]+=$|^FLORA_TOKENRING_KEY=sk-ring-REPLACE-ME$' "$FLORA_HOME/secrets/flora.env" | cut -d= -f1 || true)"
if [[ -n "$missing" ]]; then
  log "Still to fill in by hand (bin/flora secrets edit):"
  sed 's/^/    /' <<< "$missing"
  log "Where each comes from: docs/03-configuration.md#secretsfloraenv"
else
  ok "every secret is set"
fi
