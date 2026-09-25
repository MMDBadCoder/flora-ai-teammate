#!/usr/bin/env bash
# Probes every Flora service and prints a status table, or writes the JSON the
# dashboard reads.
#
#   health.sh                      human-readable table
#   health.sh --json <file>        write a snapshot for web/dashboard
#
# A service is "up" only when it answers HTTP. A running-but-wedged process
# still reports down here, which is the point.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

probe() { # probe <url> -> the HTTP status code, or 000 when nothing answered
  # curl already writes 000 for a connection failure and exits non-zero, so the
  # exit status is swallowed rather than appending a second code.
  local code; code="$(curl -o /dev/null -s -m 4 -w '%{http_code}' "$1" 2>/dev/null || true)"
  echo "${code:-000}"
}
unit_state() {
  has_systemd || { echo "n/a"; return; }
  # `systemctl is-active` exits non-zero for anything but "active", so the exit
  # status is discarded and only its word is used.
  local s; s="$(systemctl is-active "$1" 2>/dev/null || true)"
  echo "${s:-unknown}"
}

# name|unit|url|probe-path|hostname
SERVICES=(
  "tokenring|flora-tokenring.service|http://127.0.0.1:${FLORA_PORT_TOKENRING}|/health|${FLORA_URL_TOKENS}"
  "hermes|flora-hermes-dashboard.service|http://127.0.0.1:${FLORA_PORT_HERMES}|/|${FLORA_URL_HERMES}"
  "opencode|flora-opencode.service|http://127.0.0.1:${FLORA_PORT_OPENCODE}|/|${FLORA_URL_OPENCODE}"
  "mattermost|flora-mattermost.service|http://127.0.0.1:${FLORA_PORT_MATTERMOST}|/api/v4/system/ping|${FLORA_URL_CHAT}"
  "gateway|flora-hermes-gateway.service|||${FLORA_URL_CHAT}"
)

json_out=""
[[ "${1:-}" == "--json" ]] && json_out="${2:?usage: health.sh --json <file>}"

rows=""; entries=""
for spec in "${SERVICES[@]}"; do
  IFS='|' read -r name unit base path host <<< "$spec"
  state="$(unit_state "$unit")"
  if [[ -n "$base" ]]; then
    code="$(probe "${base}${path}")"
    # 2xx/3xx is healthy; 401/403 means it is alive and asking for credentials.
    if [[ "$code" =~ ^[23] ]] || [[ "$code" == "401" ]] || [[ "$code" == "403" ]]; then
      status=up
    else
      status=down
    fi
  else
    # The gateway has no HTTP surface; systemd is the only signal.
    code="-"
    [[ "$state" == "active" ]] && status=up || status=down
  fi
  rows+=$(printf '%-12s %-8s %-10s %s\n' "$name" "$status" "$state" "$host")$'\n'
  entries+="$(printf '{"name":"%s","status":"%s","unit":"%s","systemd":"%s","http":"%s","url":"http://%s"}' \
      "$name" "$status" "$unit" "$state" "$code" "$host"),"
done

if [[ -n "$json_out" ]]; then
  ensure_dir "$(dirname "$json_out")"
  printf '{"generated":"%s","services":[%s]}\n' "$(date -Is)" "${entries%,}" > "$json_out.tmp"
  mv "$json_out.tmp" "$json_out"
  chmod 0644 "$json_out"
else
  printf '%-12s %-8s %-10s %s\n' SERVICE STATUS SYSTEMD URL
  printf '%-12s %-8s %-10s %s\n' ------- ------ ------- ---
  printf '%s' "$rows"
  echo
  grep -q ' down ' <<< "$rows" && warn "something is down -- try: bin/flora logs <service>" || ok "all services up"
fi
