#!/usr/bin/env bash
# Administer Mattermost without knowing any Mattermost credentials.
#
#   mattermost-admin.sh users                        who exists
#   mattermost-admin.sh create-admin <user> <email> [password]
#   mattermost-admin.sh admin <user>                 promote an existing user
#   mattermost-admin.sh passwd <user> [password]     reset a forgotten password
#
# Flora does not create Mattermost's administrator: the FIRST account registered
# in the browser becomes system admin, which is Mattermost's own design. That
# leaves an obvious hole -- nobody registered, or whoever did has forgotten the
# password -- so Flora's compose file enables Mattermost's local mode, which
# exposes mmctl over a unix socket inside the container. Anything reached that
# way is already root-equivalent on this host, so it needs no login of its own.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

have_cmd docker || die "docker is not available"
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx flora-mattermost \
  || die "the flora-mattermost container is not running (bin/flora up mattermost)"

mm() { docker exec flora-mattermost mmctl --local "$@"; }

gen_pw() { printf 'Fl%s!%s' "$(openssl rand -base64 9 | tr -d '/+=')" "$(date +%Y)"; }

case "${1:-users}" in
  users)
    step "Mattermost accounts"
    mm user list
    echo
    log "'calls' and 'playbooks' are Mattermost's own plugin accounts, not people."
    ;;

  create-admin)
    user="${2:?usage: create-admin <username> <email> [password]}"
    email="${3:?an email address is required}"
    pw="${4:-}"; generated=0
    if [[ -z "$pw" ]]; then pw="$(gen_pw)"; generated=1; fi
    step "Creating system administrator '$user'"
    mm user create --email "$email" --username "$user" --password "$pw" --system-admin
    ok "created and granted system_admin"
    if [[ "$generated" == 1 ]]; then
      echo
      printf '    username: %s\n    password: %s\n' "$user" "$pw"
      printf '    (shown once -- write it down, then sign in at %s)\n\n' "$FLORA_URL_CHAT"
    fi
    ;;

  admin)
    user="${2:?usage: admin <username>}"
    step "Promoting '$user'"
    mm roles system-admin "$user"
    ;;

  passwd)
    user="${2:?usage: passwd <username> [password]}"
    pw="${3:-}"; generated=0
    if [[ -z "$pw" ]]; then pw="$(gen_pw)"; generated=1; fi
    step "Resetting the password for '$user'"
    mm user change-password "$user" --password "$pw"
    if [[ "$generated" == 1 ]]; then
      echo
      printf '    username: %s\n    password: %s\n' "$user" "$pw"
      printf '    (shown once)\n\n'
    fi
    ;;

  *) die "usage: {users|create-admin <user> <email> [pw]|admin <user>|passwd <user> [pw]}" ;;
esac
