#!/usr/bin/env bash
# Checks this machine can host Flora, before anything is installed or changed.
# Read-only throughout. Exit 1 means "do not continue".
#
# Two severities, and they look different on purpose:
#   [must]  blocks the install. Listed again at the end with the fix.
#   [warn]  worth knowing, does not block.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

# Each blocker is recorded as "one-line title" + "an indented fix", so the run
# ends with a numbered list of exactly what to do rather than a wall of output
# the reader has to re-scan for the lines that mattered.
declare -a BLOCKERS=()
BLOCK_COUNT=0
must() {
  printf '%s[must]%s %s\n' "$_c_red" "$_c_reset" "$1" >&2
  BLOCKERS+=("$1"$'\x1f'"$2")
  BLOCK_COUNT=$((BLOCK_COUNT+1))
}

# True only when the process really is part of this Flora install.
proc_belongs_to_flora() {
  local pid="$1"
  [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$FLORA_HOME" && return 0
  [[ -r "/proc/$pid/environ" ]] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "FLORA_HOME=$FLORA_HOME" && return 0
  return 1
}

step "Preflight"

# --- commands ---------------------------------------------------------------
APT_MISSING=()
for c in curl git python3 openssl awk sed tar; do
  if have_cmd "$c"; then ok "found $c"; else
    APT_MISSING+=("$c")
    must "missing $c" "sudo apt install -y $c"
  fi
done
have_cmd ss || warn "missing ss (apt install iproute2) -- port checks will be skipped"

# --- Node: the most common reason this script stops -------------------------
# TokenRing and OpenCode are both Node programs, and the version in Debian and
# Ubuntu's own repositories is usually too old, so the fix is not `apt install
# nodejs` and saying so saves a second failed attempt.
NODE_FIX='# Ubuntu/Debian ship an older Node; use NodeSource for 22.x:
     curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
     sudo apt install -y nodejs
     # or, without root:  https://github.com/nvm-sh/nvm  then  nvm install 22'
if ! have_cmd node; then
  must "Node.js is missing -- TokenRing and OpenCode both need it (>= 20.11)" "$NODE_FIX"
elif ! have_cmd npm; then
  must "npm is missing (node is present) -- install the full Node distribution" "$NODE_FIX"
else
  nodemajor="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  nodeminor="$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)"
  if [[ "$nodemajor" -gt 20 ]] || { [[ "$nodemajor" -eq 20 ]] && [[ "$nodeminor" -ge 11 ]]; }; then
    ok "node $(node -v), npm $(npm -v 2>/dev/null)"
  else
    must "node $(node -v) is too old -- TokenRing requires >= 20.11" "$NODE_FIX"
  fi
fi

# --- python -----------------------------------------------------------------
if have_cmd python3; then
  if python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,11) else 1)'; then
    ok "python $(python3 -V 2>&1 | awk '{print $2}')"
  else
    must "python $(python3 -V 2>&1 | awk '{print $2}') is too old -- these scripts need >= 3.11" \
         "sudo apt install -y python3
     (Hermes installs its own Python runtime separately; this is for Flora's scripts.)"
  fi
fi

# --- nginx ------------------------------------------------------------------
if have_cmd nginx; then
  ok "found nginx"
  if [[ -d /etc/nginx/conf.d ]]; then ok "/etc/nginx/conf.d exists"
  else must "/etc/nginx/conf.d is missing -- this nginx has an unusual layout" \
            "Create it and make sure nginx.conf has:  include /etc/nginx/conf.d/*.conf;"; fi
else
  must "nginx is missing -- it is the only way the five hostnames get routed" "sudo apt install -y nginx"
fi
have_cmd htpasswd || warn "no htpasswd (apt install apache2-utils) -- accounts will use an
       SHA-512 hash from openssl instead of bcrypt, which nginx accepts fine"

# --- docker: only when Mattermost is switched on ----------------------------
if [[ "${FLORA_ENABLE_MATTERMOST:-true}" == "true" ]]; then
  if ! have_cmd docker; then
    must "docker is missing -- Mattermost runs in containers" \
         "sudo apt install -y docker.io docker-compose-v2
     Or set FLORA_ENABLE_MATTERMOST=false in flora.env to run without team chat."
  elif ! docker compose version >/dev/null 2>&1; then
    must "the docker compose v2 plugin is missing" \
         "sudo apt install -y docker-compose-v2      # or docker-compose-plugin"
  elif ! docker info >/dev/null 2>&1; then
    must "docker is installed but not usable by $(whoami)" \
         "sudo systemctl start docker
     sudo usermod -aG docker $(whoami) && newgrp docker   # then re-run"
  else
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) with compose v2"
  fi
else
  skip "Mattermost is disabled in flora.env; not checking docker"
fi

# --- ports ------------------------------------------------------------------
if have_cmd ss; then
  for p in "$FLORA_PORT_TOKENRING tokenring TOKENRING" "$FLORA_PORT_HERMES hermes HERMES" \
           "$FLORA_PORT_OPENCODE opencode OPENCODE" "$FLORA_PORT_MATTERMOST mattermost MATTERMOST"; do
    set -- $p
    if port_free "$1"; then ok "port $1 free ($2)"
    else
      line="$(ss -ltnp 2>/dev/null | grep -E "[:.]$1 " | head -1 || true)"
      holder="$(grep -oP 'users:\(\("\K[^"]+' <<< "$line" | head -1 || true)"
      pid="$(grep -oP 'pid=\K[0-9]+' <<< "$line" | head -1 || true)"
      # "a node process" is not evidence: a personal OpenCode is also node, and
      # at preflight time Flora may not be installed at all. Only a process that
      # actually references FLORA_HOME counts as ours.
      if [[ -n "$pid" ]] && proc_belongs_to_flora "$pid"; then
        skip "port $1 in use by Flora's own $2 (pid $pid)"
      else
        must "port $1 ($2) is taken by ${holder:-another process}${pid:+ (pid $pid)}" \
             "If that is your own $2, stop it, or give Flora a different port:
       FLORA_PORT_$3=<free port>   in flora.env
     Identify it with:  ss -ltnp | grep :$1"
      fi
    fi
  done
fi

# --- resources --------------------------------------------------------------
free_gb=$(df -BG --output=avail "$FLORA_HOME" | tail -1 | tr -dc '0-9')
if [[ "$free_gb" -ge 15 ]]; then ok "${free_gb}G free on $FLORA_HOME"
else must "only ${free_gb}G free on $FLORA_HOME -- 15G is the working minimum" \
          "Free space, or move the Flora directory to a larger filesystem
     (FLORA_HOME follows the directory; nothing to reconfigure)."; fi
mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
[[ "$mem_mb" -ge 3500 ]] && ok "${mem_mb}MB RAM" \
  || warn "${mem_mb}MB RAM -- Mattermost and Postgres want about 1GB between them;
       4GB+ is comfortable"

# --- systemd / WSL ----------------------------------------------------------
# Flora keeps four services alive with systemd. WSL only has it when it is
# switched on explicitly, and without it `flora up` will report success while
# supervising nothing -- so this is worth saying plainly before the install.
if has_systemd; then
  ok "systemd is running"
else
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    must "this is WSL and systemd is not running -- nothing would keep Flora's services alive" \
         "Enable it, then restart WSL from Windows (wsl --shutdown):
       printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf
     Without systemd you can still run the services by hand, one per terminal or
     tmux window -- see docs/08-troubleshooting.md."
  else
    must "systemd is not running -- Flora uses it to supervise the four services" \
         "Run this on a machine with systemd, or supervise the ExecStart lines in
     state/systemd/*.service yourself (docs/08-troubleshooting.md)."
  fi
fi

# --- existing nginx ---------------------------------------------------------
if have_cmd nginx && nginx -T 2>/dev/null | grep -qE "listen\s+${FLORA_HTTP_PORT}(\s|;).*default_server"; then
  warn "another vhost already owns :${FLORA_HTTP_PORT} as default_server.
       That is fine: Flora adds name-based vhosts and never claims default_server,
       so the site already there keeps working."
fi

# --- verdict ----------------------------------------------------------------
echo
if [[ "$BLOCK_COUNT" -eq 0 ]]; then
  ok "preflight passed -- nothing is blocking the install"
  exit 0
fi

step "$BLOCK_COUNT problem(s) to fix before installing"
i=1
for entry in ${BLOCKERS[@]+"${BLOCKERS[@]}"}; do
  title="${entry%%$'\x1f'*}"
  fix="${entry#*$'\x1f'}"
  printf '\n  %d. %s\n' "$i" "$title"
  printf '     %s\n' "${fix//$'\n'/$'\n'}"
  i=$((i+1))
done
echo
log "Fix those, then run this again:  bin/flora preflight"
log "Nothing has been installed or changed."
exit 1
