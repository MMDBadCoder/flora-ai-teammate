#!/usr/bin/env bash
# Team accounts for the agent UIs (FLORA_AUTH_MODE=nginx).
#
#   users.sh add <name> [password]   -- create or reset; a password is generated
#                                       and printed once when you omit it
#   users.sh del <name>
#   users.sh list
#
# These accounts guard flora.com, hermes.flora.com and opencode.flora.com.
# Mattermost and TokenRing have their own account systems and are not listed here.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

HT="$FLORA_STATE/nginx/htpasswd"
ensure_dir "$(dirname "$HT")"

hash_pw() {
  # nginx checks a hash with crypt_r(), so anything glibc/libxcrypt understands
  # works. Preference order, strongest first:
  #   bcrypt  -- needs apache2-utils (apt install apache2-utils)
  #   SHA-512 -- openssl, supported everywhere nginx runs on Linux
  #   apr1    -- last resort; MD5-based, weak, but universally accepted
  local user="$1" pw="$2"
  if have_cmd htpasswd; then
    htpasswd -nbB "$user" "$pw"
  elif openssl passwd -6 "$pw" >/dev/null 2>&1; then
    printf '%s:%s\n' "$user" "$(openssl passwd -6 "$pw")"
  else
    warn "falling back to the weak apr1 hash -- install apache2-utils for bcrypt"
    printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pw")"
  fi
}

case "${1:-list}" in
  add)
    user="${2:?usage: users.sh add <name> [password]}"
    pw="${3:-}"
    generated=0
    if [[ -z "$pw" ]]; then pw="$(openssl rand -base64 15 | tr -d '/+=' | head -c 16)"; generated=1; fi
    touch "$HT"
    tmp="$(mktemp)"; grep -v "^${user}:" "$HT" > "$tmp" 2>/dev/null || true
    hash_pw "$user" "$pw" >> "$tmp"
    mv "$tmp" "$HT"; chmod 0644 "$HT"
    ok "account '$user' set"
    if [[ "$generated" == 1 ]]; then
      echo
      printf '    username: %s\n    password: %s\n' "$user" "$pw"
      printf '    (shown once -- write it down, then send it over Mattermost)\n\n'
    fi
    [[ "$user" == "$FLORA_ADMIN_USER" ]] && log "this is the admin account named in flora.env"
    ;;
  del)
    user="${2:?usage: users.sh del <name>}"
    [[ -f "$HT" ]] || die "no account file yet"
    [[ "$user" == "$FLORA_ADMIN_USER" ]] && die "refusing to delete the admin account; change FLORA_ADMIN_USER first"
    tmp="$(mktemp)"; grep -v "^${user}:" "$HT" > "$tmp" || true; mv "$tmp" "$HT"; chmod 0644 "$HT"
    ok "account '$user' removed"
    ;;
  list)
    if [[ -s "$HT" ]]; then
      log "accounts for the agent UIs:"
      cut -d: -f1 "$HT" | sed 's/^/    /'
      log "admin: $FLORA_ADMIN_USER"
    else
      warn "no accounts yet -- run: bin/flora user add <name>"
    fi
    ;;
  *) die "usage: users.sh {add|del|list}" ;;
esac
