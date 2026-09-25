#!/usr/bin/env bash
# Every login Flora has, in one place.
#
# There are three separate account systems here on purpose -- nginx guards the
# agent UIs, TokenRing and Mattermost each have their own -- which makes "what
# is the password for the dashboard?" harder to answer than it should be.
#
# This prints secrets to your terminal. Run it where nobody is reading over your
# shoulder, and remember your shell history and scrollback keep a copy.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

admin_pw="$(secret_get flora.env FLORA_ADMIN_PASSWORD || echo '(not generated yet)')"
ring_pw="$(secret_get flora.env TOKENRING_ADMIN_PASSWORD || echo '(not generated yet)')"

step "Flora logins"

printf '\n%sDashboard, Hermes, OpenCode%s\n' "$_c_bold" "$_c_reset"
printf '  dashboard %s\n' "$FLORA_URL_DASHBOARD"
printf '  hermes    %s\n' "$FLORA_URL_HERMES"
printf '  opencode  %s\n' "$FLORA_URL_OPENCODE"
if [[ "$FLORA_AUTH_MODE" == "nginx" ]]; then
  printf '  username  %s\n' "$FLORA_ADMIN_USER"
  printf '  password  %s\n' "$admin_pw"
  if [[ -s "$FLORA_STATE/nginx/htpasswd" ]]; then
    printf '  accounts  %s\n' "$(cut -d: -f1 "$FLORA_STATE/nginx/htpasswd" | tr '\n' ' ')"
  else
    printf '  %saccounts  none yet -- created by: sudo bin/flora nginx%s\n' "$_c_ylw" "$_c_reset"
  fi
  printf '  add more  bin/flora user add <name>\n'
else
  printf '  auth mode "backend": each service enforces its own password\n'
  printf '  hermes    %s / %s\n' "$FLORA_ADMIN_USER" "$(secret_get flora.env HERMES_DASHBOARD_PASSWORD || echo '?')"
  printf '  opencode  opencode / %s\n' "$(secret_get flora.env OPENCODE_SERVER_PASSWORD || echo '?')"
fi

printf '\n%sTokenRing%s  %s\n' "$_c_bold" "$_c_reset" "$FLORA_URL_TOKENS"
printf '  password  %s\n' "$ring_pw"
printf '            (no username; change it in Settings, which signs everyone out)\n'

printf '\n%sMattermost%s %s\n' "$_c_bold" "$_c_reset" "$FLORA_URL_CHAT"
printf '  Its own accounts. The FIRST one you create in the browser becomes the\n'
printf '  system admin -- use %s.\n' "$FLORA_ADMIN_EMAIL"
if [[ -n "$(secret_get flora.env MATTERMOST_BOT_TOKEN || true)" ]]; then
  printf '  bot token set; Flora answers users in MATTERMOST_ALLOWED_USERS\n'
else
  printf '  %sbot token not set yet -- Flora cannot answer in chat (docs/07-integrations.md)%s\n' "$_c_ylw" "$_c_reset"
fi

printf '\n%sStored in%s  secrets/flora.env (mode 0600, never committed)\n' "$_c_dim" "$_c_reset"
printf '%sRotate%s     bin/flora secrets edit  ->  bin/flora render  ->  bin/flora restart\n' "$_c_dim" "$_c_reset"
echo
