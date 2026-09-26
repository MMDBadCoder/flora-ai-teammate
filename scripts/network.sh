#!/usr/bin/env bash
# Why can other machines not reach Flora?
#
#   network.sh            diagnose and print the fix for THIS environment
#
# Read-only. It checks, in order: what is listening and on which address, whether
# a local firewall is in the way, and whether this host is behind NAT (WSL, or a
# cloud VM with a security group). Those are the three things that break it, and
# they need completely different fixes.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

PORTS=("$FLORA_PUBLIC_DASHBOARD dashboard" "$FLORA_PUBLIC_HERMES hermes"
       "$FLORA_PUBLIC_OPENCODE opencode" "$FLORA_PUBLIC_CHAT mattermost"
       "$FLORA_PUBLIC_TOKENS tokenring")
[[ "${FLORA_ROUTING:-ports}" == "hosts" ]] && PORTS=("$FLORA_HTTP_PORT all-services")

PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IS_WSL=0
grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && IS_WSL=1

step "1. Is anything listening, and where?"
all_bound_locally=1
for entry in "${PORTS[@]}"; do
  set -- $entry
  line="$(ss -ltn 2>/dev/null | grep -E "[:.]$1 " | head -1 || true)"
  if [[ -z "$line" ]]; then
    err "$1 ($2): nothing is listening -- run: sudo bin/flora nginx"
    all_bound_locally=0
    continue
  fi
  addr="$(awk '{print $4}' <<< "$line")"
  case "$addr" in
    '0.0.0.0:'*|'*:'*|'[::]:'*) ok "$1 ($2): listening on all interfaces ($addr)" ;;
    '127.0.0.1:'*|'[::1]:'*)
      err "$1 ($2): bound to loopback only ($addr) -- unreachable from any other machine"
      all_bound_locally=0 ;;
    *) warn "$1 ($2): bound to $addr only" ;;
  esac
done

step "2. Can this machine reach itself on its own address?"
if [[ -z "$PRIMARY_IP" ]]; then
  warn "could not determine this machine's IP"
else
  log "primary address: $PRIMARY_IP"
  for entry in "${PORTS[@]}"; do
    set -- $entry
    code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://$PRIMARY_IP:$1/" 2>/dev/null || true)"
    if [[ "$code" =~ ^[2345] ]]; then ok "$PRIMARY_IP:$1 answers (HTTP $code)"
    else err "$PRIMARY_IP:$1 does not answer -- a local firewall is the usual cause"; fi
  done
fi

step "3. Local firewall"
fw_found=0
if have_cmd ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  fw_found=1
  warn "ufw is ACTIVE. Allow the Flora ports:"
  for entry in "${PORTS[@]}"; do set -- $entry; printf '       sudo ufw allow %s/tcp   # %s\n' "$1" "$2"; done
  printf '       sudo ufw reload\n'
elif have_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
  fw_found=1
  warn "firewalld is ACTIVE. Allow the Flora ports:"
  for entry in "${PORTS[@]}"; do set -- $entry; printf '       sudo firewall-cmd --permanent --add-port=%s/tcp\n' "$1"; done
  printf '       sudo firewall-cmd --reload\n'
elif have_cmd nft && nft list ruleset 2>/dev/null | grep -qE 'policy drop'; then
  fw_found=1
  warn "nftables has a drop policy. Open the ports there, or check: sudo nft list ruleset"
elif have_cmd iptables && iptables -S 2>/dev/null | grep -qE '^-P INPUT DROP'; then
  fw_found=1
  warn "iptables INPUT policy is DROP. Open the ports, or check: sudo iptables -S"
fi
[[ "$fw_found" == 0 ]] && ok "no active local firewall found"

step "4. Is this host behind NAT?"
if [[ "$IS_WSL" == "1" ]]; then
  err "This is WSL, and that is almost certainly the problem."
  cat <<WSL

  WSL2 runs in a NAT'd virtual machine with its own address. Windows reaches it
  through localhost forwarding, which is why the dashboard works on this PC and
  nowhere else: $PRIMARY_IP is not an address the rest of your network can route to.

  Flora is fine. The fix is in Windows, and there are two.

  ---- Option A: mirrored networking (Windows 11, WSL 2.0+) -- recommended ----

  WSL then shares the Windows machine's network interfaces, so ports bound here
  are reachable on the PC's own LAN address, with nothing to redo on reboot.

  1. In Windows, create or edit  %USERPROFILE%\\.wslconfig  :

         [wsl2]
         networkingMode=mirrored

  2. In PowerShell as Administrator:

         wsl --shutdown
         New-NetFirewallRule -DisplayName "Flora" -Direction Inbound \\
           -Action Allow -Protocol TCP -LocalPort ${FLORA_PUBLIC_DASHBOARD}-${FLORA_PUBLIC_TOKENS}

  3. Reopen this terminal. Teammates then use the WINDOWS PC's LAN address:

         ipconfig            # in Windows, find the IPv4 address
         http://<that address>:${FLORA_PUBLIC_DASHBOARD}

  4. Set FLORA_IP in flora.env to that same address, then: bin/flora render

  ---- Option B: port forwarding (Windows 10, or if A is unavailable) --------

  Forward each port from Windows into WSL. Note the WSL address changes on every
  restart, so this has to be redone or scripted.

      wsl hostname -I                       # -> the WSL address, e.g. $PRIMARY_IP

  Then in PowerShell as Administrator:

WSL
  for entry in "${PORTS[@]}"; do
    set -- $entry
    printf '      netsh interface portproxy add v4tov4 listenport=%s listenaddress=0.0.0.0 connectport=%s connectaddress=%s\n' "$1" "$1" "$PRIMARY_IP"
  done
  cat <<WSL2

      New-NetFirewallRule -DisplayName "Flora" -Direction Inbound \\
        -Action Allow -Protocol TCP -LocalPort ${FLORA_PUBLIC_DASHBOARD}-${FLORA_PUBLIC_TOKENS}

  To undo it later:
      netsh interface portproxy reset

WSL2
elif [[ -n "$PRIMARY_IP" ]] && [[ "$PRIMARY_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
  pub="$(curl -s -m 4 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$pub" && "$pub" != "$PRIMARY_IP" ]]; then
    warn "this machine has a private address ($PRIMARY_IP) and a different public one ($pub)."
    log  "On the same LAN, teammates use $PRIMARY_IP. From outside it, whatever sits in"
    log  "front (a cloud security group, a router) has to forward the Flora ports."
  else
    ok "private address $PRIMARY_IP -- fine for a LAN"
  fi
else
  ok "not behind NAT as far as I can tell"
fi

step "Verdict"
if [[ "$IS_WSL" == "1" ]]; then
  log "Follow the WSL section above. Nothing in Flora needs changing."
elif [[ "$all_bound_locally" == "0" ]]; then
  log "Something is not listening publicly. Start with: sudo bin/flora nginx"
else
  log "Flora is listening on every interface. If a teammate still cannot connect,"
  log "the block is between them and this machine -- firewall, security group or route."
  log "Have them run:  curl -v http://$PRIMARY_IP:$FLORA_PUBLIC_DASHBOARD/nginx-health"
  log "  'connection refused' = something rejected it;  a hang = a firewall dropping it."
fi
echo
log "Unauthenticated liveness endpoint, useful from anywhere:"
log "    curl http://$PRIMARY_IP:$FLORA_PUBLIC_DASHBOARD/nginx-health"
