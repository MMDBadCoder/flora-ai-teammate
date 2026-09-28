#!/usr/bin/env bash
# Writes the Flora hostnames into this machine's /etc/hosts, and prints the
# exact line every teammate needs on their own machine.
#
# /etc/hosts has NO wildcard support: *.flora.com is not a thing, so each
# hostname is listed explicitly. Adding a service later means adding its name
# here and on every client -- which is the one real cost of the no-DNS setup.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "/etc/hosts"

# Only services actually addressed by name need to resolve. In a mixed setup
# that is a subset, and listing the others would be noise on every teammate's
# machine.
NAMES=""
for svc in DASHBOARD HERMES OPENCODE CHAT TOKENS; do
  [[ "$(flora_route_mode "$svc")" == "subdomain" ]] || continue
  host_var="FLORA_HOST_$svc"
  NAMES="${NAMES:+$NAMES }${!host_var}"
done

if [[ -z "$NAMES" ]]; then
  skip "every service is addressed by port -- nothing to add to /etc/hosts, here or anywhere"
  log "Services are reached by address and port:"
  for u in "$FLORA_URL_DASHBOARD" "$FLORA_URL_HERMES" "$FLORA_URL_OPENCODE" "$FLORA_URL_CHAT" "$FLORA_URL_TOKENS"; do
    printf '    %s\n' "$u"
  done
  exit 0
fi

: "${FLORA_IP:?set FLORA_IP in flora.env to the address clients will reach this server on}"
OLD_NAMES=NAMES="$FLORA_HOST_DASHBOARD $FLORA_HOST_HERMES $FLORA_HOST_OPENCODE $FLORA_HOST_CHAT $FLORA_HOST_TOKENS"
LINE="$FLORA_IP $NAMES"

if [[ "${1:-}" == "--print" ]]; then printf '%s\n' "$LINE"; exit 0; fi

need_root
# On the server itself the services answer on loopback, so point the names at
# 127.0.0.1 locally; only clients need the routable address.
printf '%s\n' "127.0.0.1 $NAMES" | ensure_block /etc/hosts hostnames

echo
log "On every teammate's machine, add this line:"
echo
printf '    %s\n' "$LINE"
echo
log "  Linux/macOS:  sudo sh -c 'echo \"$LINE\" >> /etc/hosts'"
log "  Windows:      Notepad (as Administrator) -> C:\\Windows\\System32\\drivers\\etc\\hosts"
echo
log "Verify from a client:  curl -I http://$FLORA_HOST_DASHBOARD"
