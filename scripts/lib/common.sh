#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Flora shared shell library.
#
# Every script sources this. It provides:
#   - configuration loading (flora.env + secrets/*.env)
#   - logging with consistent prefixes
#   - idempotent primitives: ensure_dir, ensure_line, ensure_symlink, write_if_changed
#   - template rendering ({{VAR}} substitution from the environment)
#   - secret generation / reading
#
# Every primitive here is safe to run repeatedly. That is the whole design:
# `flora up` on a clean machine and on a machine that is already running must
# both end in the same state, and the second one must print "unchanged".
# ---------------------------------------------------------------------------
set -euo pipefail

FLORA_CHANGED=0
FLORA_HOME="${FLORA_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export FLORA_HOME

# --- logging ---------------------------------------------------------------
_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
_c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'; _c_bold=$'\033[1m'
[[ -t 1 ]] || { _c_reset=; _c_dim=; _c_red=; _c_grn=; _c_ylw=; _c_blu=; _c_bold=; }

log()   { printf '%s[flora]%s %s\n' "$_c_blu" "$_c_reset" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n'  "$_c_grn" "$_c_reset" "$*"; }
skip()  { printf '%s[same]%s %s\n'  "$_c_dim" "$_c_reset" "$*"; }
warn()  { printf '%s[warn]%s %s\n'  "$_c_ylw" "$_c_reset" "$*" >&2; }
err()   { printf '%s[fail]%s %s\n'  "$_c_red" "$_c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$_c_bold" "$*" "$_c_reset"; }

# --- configuration ---------------------------------------------------------
load_env() {
  local env_file="$FLORA_HOME/flora.env" detected_home="$FLORA_HOME"
  if [[ ! -f "$env_file" ]]; then
    if [[ -f "$FLORA_HOME/flora.env.example" ]]; then
      warn "flora.env missing; creating it from flora.env.example"
      cp "$FLORA_HOME/flora.env.example" "$env_file"
    else
      die "no flora.env and no flora.env.example in $FLORA_HOME"
    fi
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  local s
  for s in "$FLORA_HOME"/secrets/*.env; do
    [[ -e "$s" ]] || continue
    # shellcheck disable=SC1090
    source "$s"
  done
  set +a

  # --- 1. defaults ----------------------------------------------------------
  # A flora.env written against an older version of Flora must keep working
  # after a pull. Without these, adding one setting breaks every command in the
  # platform with "unbound variable" for anyone who upgrades.
  : "${FLORA_DOMAIN:=flora.local}"
  : "${FLORA_ROUTING:=ports}"
  : "${FLORA_NGINX:=docker}"
  : "${FLORA_PUBLIC_DASHBOARD:=7080}"
  : "${FLORA_PUBLIC_HERMES:=7081}"
  : "${FLORA_PUBLIC_OPENCODE:=7082}"
  : "${FLORA_PUBLIC_CHAT:=7083}"
  : "${FLORA_PUBLIC_TOKENS:=7084}"
  : "${FLORA_HTTP_PORT:=80}"
  : "${FLORA_BIND_ADDR:=127.0.0.1}"
  : "${FLORA_AUTH_MODE:=nginx}"
  : "${FLORA_ADMIN_USER:=admin}"
  : "${FLORA_ADMIN_EMAIL:=admin@${FLORA_DOMAIN}}"
  # The account that owns the tree and runs the services. Under sudo this is the
  # person who invoked it, not root: a platform whose files belong to root cannot
  # be operated by the human who installed it, and every later `flora render`
  # fails with "permission denied".
  : "${FLORA_USER:=${SUDO_USER:-$(id -un)}}"
  : "${FLORA_TZ:=UTC}"
  : "${FLORA_IP:=127.0.0.1}"
  : "${FLORA_HOST_DASHBOARD:=${FLORA_DOMAIN}}"
  : "${FLORA_HOST_HERMES:=hermes.${FLORA_DOMAIN}}"
  : "${FLORA_HOST_OPENCODE:=opencode.${FLORA_DOMAIN}}"
  : "${FLORA_HOST_CHAT:=chat.${FLORA_DOMAIN}}"
  : "${FLORA_HOST_TOKENS:=tokens.${FLORA_DOMAIN}}"
  : "${FLORA_PORT_TOKENRING:=4000}"
  : "${FLORA_PORT_HERMES:=9119}"
  : "${FLORA_PORT_OPENCODE:=4096}"
  : "${FLORA_PORT_MATTERMOST:=8065}"
  : "${FLORA_MODEL_MAIN:=gpt-5.1}"
  : "${FLORA_MODEL_SMALL:=gpt-5.1-mini}"
  : "${FLORA_TOKENRING_UPSTREAM:=https://api.openai.com/v1}"
  : "${FLORA_HERMES_SKILL_CATEGORY:=team}"
  : "${FLORA_SKILLS_EXPORT_BUNDLED:=false}"
  : "${FLORA_HERMES_BROWSER:=false}"
  : "${FLORA_LOG_KEEP_DAYS:=30}"
  : "${FLORA_SESSION_KEEP_DAYS:=90}"
  : "${FLORA_ENABLE_TOKENRING:=true}"
  : "${FLORA_ENABLE_HERMES:=true}"
  : "${FLORA_ENABLE_OPENCODE:=true}"
  : "${FLORA_ENABLE_MATTERMOST:=true}"
  export FLORA_DOMAIN FLORA_ROUTING FLORA_NGINX FLORA_PUBLIC_DASHBOARD \
         FLORA_PUBLIC_HERMES FLORA_PUBLIC_OPENCODE FLORA_PUBLIC_CHAT \
         FLORA_PUBLIC_TOKENS FLORA_HTTP_PORT FLORA_BIND_ADDR FLORA_AUTH_MODE \
         FLORA_ADMIN_USER FLORA_ADMIN_EMAIL FLORA_USER FLORA_TZ FLORA_IP \
         FLORA_HOST_DASHBOARD FLORA_HOST_HERMES FLORA_HOST_OPENCODE \
         FLORA_HOST_CHAT FLORA_HOST_TOKENS FLORA_PORT_TOKENRING \
         FLORA_PORT_HERMES FLORA_PORT_OPENCODE FLORA_PORT_MATTERMOST \
         FLORA_MODEL_MAIN FLORA_MODEL_SMALL FLORA_TOKENRING_UPSTREAM \
         FLORA_HERMES_SKILL_CATEGORY FLORA_SKILLS_EXPORT_BUNDLED \
         FLORA_HERMES_BROWSER FLORA_LOG_KEEP_DAYS FLORA_SESSION_KEEP_DAYS \
         FLORA_ENABLE_TOKENRING FLORA_ENABLE_HERMES FLORA_ENABLE_OPENCODE \
         FLORA_ENABLE_MATTERMOST

  # --- 2. paths -------------------------------------------------------------
  # FLORA_HOME is where these scripts live, so a stale value in flora.env (after
  # a move or a copy) can never send the platform somewhere that does not exist.
  FLORA_HOME="$detected_home"
  export FLORA_HOME
  export FLORA_STATE="$FLORA_HOME/state"
  export FLORA_SHARED="$FLORA_HOME/shared"
  export HERMES_HOME="$FLORA_STATE/hermes/home"
  export OPENCODE_CONFIG_DIR="$FLORA_STATE/opencode/config"
  export FLORA_BIN_DIR="$FLORA_STATE/bin"

  # --- 3. URLs --------------------------------------------------------------
  # Derived in one place so the addressing mode is decided once, not in every
  # script and template.
  if [[ "$FLORA_HTTP_PORT" == "80" ]]; then export FLORA_URL_PORT=""
  else export FLORA_URL_PORT=":$FLORA_HTTP_PORT"; fi
  if [[ "$FLORA_ROUTING" == "hosts" ]]; then
    export FLORA_URL_DASHBOARD="http://${FLORA_HOST_DASHBOARD}${FLORA_URL_PORT}"
    export FLORA_URL_HERMES="http://${FLORA_HOST_HERMES}${FLORA_URL_PORT}"
    export FLORA_URL_OPENCODE="http://${FLORA_HOST_OPENCODE}${FLORA_URL_PORT}"
    export FLORA_URL_CHAT="http://${FLORA_HOST_CHAT}${FLORA_URL_PORT}"
    export FLORA_URL_TOKENS="http://${FLORA_HOST_TOKENS}${FLORA_URL_PORT}"
  else
    export FLORA_URL_DASHBOARD="http://${FLORA_IP}:${FLORA_PUBLIC_DASHBOARD}"
    export FLORA_URL_HERMES="http://${FLORA_IP}:${FLORA_PUBLIC_HERMES}"
    export FLORA_URL_OPENCODE="http://${FLORA_IP}:${FLORA_PUBLIC_OPENCODE}"
    export FLORA_URL_CHAT="http://${FLORA_IP}:${FLORA_PUBLIC_CHAT}"
    export FLORA_URL_TOKENS="http://${FLORA_IP}:${FLORA_PUBLIC_TOKENS}"
  fi

  # --- 4. authentication ----------------------------------------------------
  # Exactly one account list decides who gets in. Both agents will gate
  # themselves if they find a password in the environment, and secrets/flora.env
  # reaches them through the units, so in nginx mode the browser's credentials
  # would arrive at a backend expecting a different password and every request
  # would 401. Two lists with two passwords is not defence in depth.
  if [[ "$FLORA_AUTH_MODE" == "nginx" ]]; then
    # OpenCode has no separate API gate, so simply dropping its password is enough.
    export FLORA_OPENCODE_AUTH_DIRECTIVE="UnsetEnvironment=OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME"
    # Hermes is different: it gates its own /api routes even on a loopback bind,
    # and it does so with a cookie session from its own login page, not with a
    # header on every request. So it keeps its own single login, and the nginx
    # gate sits in front of it. A team member sees two prompts on their first
    # visit: their own account, then Hermes' login, once per browser session.
    export FLORA_HERMES_DASHBOARD_USER="flora"
    export FLORA_HERMES_DASHBOARD_PW="${HERMES_DASHBOARD_PASSWORD:-}"
  else
    export FLORA_OPENCODE_AUTH_DIRECTIVE="Environment=OPENCODE_SERVER_USERNAME=${FLORA_ADMIN_USER}"
    export FLORA_HERMES_DASHBOARD_USER="${FLORA_ADMIN_USER}"
    export FLORA_HERMES_DASHBOARD_PW="${HERMES_DASHBOARD_PASSWORD:-}"
  fi
  export FLORA_HERMES_PUBLIC_URL_LINE="HERMES_DASHBOARD_PUBLIC_URL=${FLORA_URL_HERMES}"

  # --- 5. OpenCode's model map ------------------------------------------------
  # A plain {{FLORA_MODEL_MAIN}}/{{FLORA_MODEL_SMALL}} pair of JSON object keys
  # silently collapses to one entry when both point at the same model id (a
  # perfectly reasonable choice for a cost-conscious pool) -- JSON just keeps
  # the last of two duplicate keys, so the first label disappears with no
  # error. Computed here, once, the way FLORA_OPENCODE_AUTH_DIRECTIVE is.
  if [[ "$FLORA_MODEL_MAIN" == "$FLORA_MODEL_SMALL" ]]; then
    export FLORA_OPENCODE_MODELS_JSON="{ \"${FLORA_MODEL_MAIN}\": { \"name\": \"Flora\" } }"
  else
    export FLORA_OPENCODE_MODELS_JSON="{ \"${FLORA_MODEL_MAIN}\": { \"name\": \"Flora main\" }, \"${FLORA_MODEL_SMALL}\": { \"name\": \"Flora small\" } }"
  fi
}

# --- idempotent primitives -------------------------------------------------

# ensure_dir <path> [mode]
ensure_dir() {
  local d="$1" mode="${2:-}"
  if [[ -d "$d" ]]; then
    [[ -n "$mode" ]] && chmod "$mode" "$d"
  else
    mkdir -p "$d"
    [[ -n "$mode" ]] && chmod "$mode" "$d"
    ok "created $d"
  fi
  return 0
}

# write_if_changed <path> < content-on-stdin
# Writes only when the content differs, so mtimes stay stable and "nothing
# changed" runs are visible in the output.
write_if_changed() {
  local target="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"; skip "$target"
    FLORA_CHANGED=0; return 0
  fi
  ensure_dir "$(dirname "$target")"
  if ! mv "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    local owner; owner="$(stat -c %U "$target" 2>/dev/null || echo unknown)"
    die "cannot write $target -- it is owned by '$owner' and you are '$(id -un)'.
     This happens when an earlier step ran under sudo. Hand the tree back:
       sudo $FLORA_HOME/bin/flora fix-perms"
  fi
  chmod "$mode" "$target"
  ok "wrote $target"
  FLORA_CHANGED=1; return 0
}

# ensure_line <file> <line>  -- append the line unless it is already present
ensure_line() {
  local file="$1" line="$2"
  ensure_dir "$(dirname "$file")"
  touch "$file"
  if grep -qxF "$line" "$file"; then
    skip "$file already contains: $line"
    FLORA_CHANGED=0; return 0
  fi
  printf '%s\n' "$line" >> "$file"
  ok "appended to $file: $line"
  FLORA_CHANGED=1; return 0
}

# ensure_block <file> <marker> < content-on-stdin
# Replaces the region between "# >>> flora:<marker> >>>" and its end marker,
# leaving everything else in the file untouched. Used for /etc/hosts.
ensure_block() {
  local file="$1" marker="$2" begin end body tmp
  begin="# >>> flora:$marker >>>"
  end="# <<< flora:$marker <<<"
  body="$(cat)"
  ensure_dir "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1} !skip {print} $0==e {skip=0}
  ' "$file" > "$tmp"
  printf '%s\n%s\n%s\n' "$begin" "$body" "$end" >> "$tmp"
  # collapse >1 consecutive blank lines
  awk 'NF==0{blank++; if(blank>1) next} NF{blank=0} {print}' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"; skip "$file block '$marker'"
    FLORA_CHANGED=0; return 0
  fi
  cp "$file" "$file.flora.bak"
  mv "$tmp" "$file"
  chmod 0644 "$file"
  ok "updated $file block '$marker' (backup: $file.flora.bak)"
  FLORA_CHANGED=1; return 0
}

# ensure_ownership -- hand the tree back to FLORA_USER.
#
# Some steps need root (systemd units, /etc/nginx in host mode), and anything
# they create is root-owned. Left that way, the next `flora render` run by the
# person who installed it cannot write, so the whole platform becomes
# sudo-only. This is called at the end of the steps that write, and is a no-op
# when not running as root.
ensure_ownership() {
  [[ "$(id -u)" -eq 0 ]] || return 0
  local owner="${FLORA_USER:-root}"
  id -u "$owner" >/dev/null 2>&1 || { warn "FLORA_USER=$owner does not exist; leaving ownership alone"; return 0; }
  [[ "$owner" == "root" ]] && return 0
  local group; group="$(id -gn "$owner")"
  local changed=0 d
  for d in "$FLORA_HOME/state" "$FLORA_HOME/shared" "$FLORA_HOME/secrets" "$FLORA_HOME/flora.env"; do
    [[ -e "$d" ]] || continue
    # Mattermost's bind mounts must stay uid 2000 or the container cannot start.
    if [[ "$d" == "$FLORA_HOME/state" ]]; then
      find "$d" -path "$d/mattermost" -prune -o ! -user "$owner" -print0 2>/dev/null \
        | xargs -0 --no-run-if-empty chown -h "$owner:$group" && changed=1
    else
      chown -R -h "$owner:$group" "$d" && changed=1
    fi
  done
  chmod 0700 "$FLORA_HOME/secrets" 2>/dev/null || true
  [[ "$changed" == 1 ]] && ok "tree owned by $owner:$group (Mattermost mounts left at uid 2000)"
  return 0
}

# remove_block <file> <marker>  -- the inverse of ensure_block
remove_block() {
  local file="$1" marker="$2" begin end tmp
  begin="# >>> flora:$marker >>>"
  end="# <<< flora:$marker <<<"
  [[ -f "$file" ]] || { skip "$file does not exist"; FLORA_CHANGED=0; return 0; }
  grep -qxF "$begin" "$file" || { skip "$file has no flora block"; FLORA_CHANGED=0; return 0; }
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '$0==b {skip=1} !skip {print} $0==e {skip=0}' "$file" > "$tmp"
  cp "$file" "$file.flora.bak"
  mv "$tmp" "$file"; chmod 0644 "$file"
  ok "removed the flora block from $file (backup: $file.flora.bak)"
  FLORA_CHANGED=1; return 0
}

# ensure_symlink <link> <target>
# Replaces a wrong link, refuses to clobber a real directory unless ADOPT=1,
# in which case the real content is moved to the target first (this is how a
# skill created directly by an agent gets adopted into shared/).
ensure_symlink() {
  local link="$1" target="$2" adopt="${ADOPT:-0}"
  ensure_dir "$(dirname "$link")"
  if [[ -L "$link" ]]; then
    local cur; cur="$(readlink -f "$link" || true)"
    if [[ "$cur" == "$(readlink -f "$target")" ]]; then skip "symlink $link"; FLORA_CHANGED=0; return 0; fi
    rm -f "$link"
  elif [[ -e "$link" ]]; then
    if [[ "$adopt" == "1" ]]; then
      if [[ -e "$target" ]]; then
        die "cannot adopt $link -> $target: both exist. Merge them by hand."
      fi
      ensure_dir "$(dirname "$target")"
      mv "$link" "$target"
      ok "adopted $link into $target"
    else
      die "$link exists and is not a symlink (set ADOPT=1 to move it into $target)"
    fi
  fi
  ln -s "$target" "$link"
  ok "symlink $link -> $target"
  FLORA_CHANGED=1; return 0
}

# render <template> <output> [mode]
# Substitutes {{VAR}} with the value of $VAR from the environment.
# An unset variable is a hard error: a half-rendered config is worse than none.
# render() keeps a hash of what it last wrote. If the file on disk no longer
# matches, somebody edited it by hand, and overwriting that silently is how a
# tuned config disappears during an upgrade. The edit is saved beside the file
# and named in the output instead.
render() {
  local tmpl="$1" out="$2" mode="${3:-0644}" tmp hashfile
  [[ -f "$tmpl" ]] || die "template not found: $tmpl"
  hashfile="$FLORA_HOME/state/.rendered/$(printf '%s' "$out" | sha256sum | cut -c1-32)"
  if [[ -f "$out" && -f "$hashfile" ]]; then
    local now was
    now="$(sha256sum "$out" | cut -d" " -f1)"
    was="$(cat "$hashfile")"
    if [[ "$now" != "$was" ]]; then
      local keep="$out.local-$(date +%Y%m%d-%H%M%S)"
      cp -p "$out" "$keep"
      warn "$out was edited by hand since it was generated.
       Your version is kept at:  ${keep/#$FLORA_HOME/.}
       The generated one is being written over it. To make an edit permanent,
       put it in the template: ${tmpl/#$FLORA_HOME/.}"
    fi
  fi
  tmp="$(mktemp)"
  if ! FLORA_TMPL="$tmpl" python3 "$FLORA_HOME/scripts/lib/render.py" > "$tmp"; then
    rm -f "$tmp"
    die "could not render $tmpl (see unset variables above; add them to flora.env)"
  fi
  write_if_changed "$out" "$mode" < "$tmp"
  rm -f "$tmp"
  # The hash record is an aid, not a requirement: if it cannot be written the
  # render still succeeded, so this warns rather than aborting.
  if ! ( ensure_dir "$(dirname "$hashfile")" >/dev/null && \
         sha256sum "$out" | cut -d" " -f1 > "$hashfile" ) 2>/dev/null; then
    warn "could not record a checksum for $out (hand-edit detection is off for it).
       Usually an ownership problem after a sudo step:  sudo bin/flora fix-perms"
  fi
}

# --- secrets ---------------------------------------------------------------
gen_secret() { openssl rand -hex "${1:-24}"; }

# secret_set <FILE.env> <KEY> [value]
#   two arguments  -> generate a strong random value
#   three arguments -> use it verbatim, INCLUDING the empty string
# An existing key is never overwritten, which is what makes this re-runnable.
# The empty-string case matters: keys like MATTERMOST_BOT_TOKEN must be seeded
# blank so rendering does not fail on an unset variable, and must stay blank so
# `flora doctor` can tell you they still need filling in.
secret_set() {
  local file="$FLORA_HOME/secrets/$1" key="$2" val
  if [[ $# -ge 3 ]]; then val="$3"; else val="$(gen_secret 24)"; fi
  ensure_dir "$FLORA_HOME/secrets" 0700
  touch "$file"; chmod 0600 "$file"
  if grep -qE "^${key}=" "$file"; then skip "secret $key already set in secrets/$1"; FLORA_CHANGED=0; return 0; fi
  printf '%s=%s\n' "$key" "$val" >> "$file"
  if [[ -n "$val" ]]; then ok "set $key in secrets/$1"; else ok "seeded $key in secrets/$1 (empty -- fill it in)"; fi
  FLORA_CHANGED=1; return 0
}
secret_get() {
  local file="$FLORA_HOME/secrets/$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -1
}

# --- pre-existing installs -------------------------------------------------
# Plenty of people already run Hermes or OpenCode for themselves before Flora
# turns up. Their ~/.hermes and ~/.config/opencode are none of Flora's business,
# but `doctor` also has to be able to spot a NEW directory appearing there,
# which means something ran an agent without the wrapper and started a second,
# invisible brain. The difference is only knowable if it is written down before
# Flora installs anything, which is what this file is.
EXTERNAL_LIST_REL="state/external-installs.txt"

external_paths() {
  printf '%s\n' "$HOME/.hermes" "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                 "$HOME/.config/hermes" "$HOME/.claude/skills"
}

# Call before installing. Records what already exists; never overwrites.
record_external_installs() {
  local f="$FLORA_HOME/$EXTERNAL_LIST_REL" p found=0
  [[ -f "$f" ]] && { skip "pre-existing installs already recorded"; return 0; }
  ensure_dir "$(dirname "$f")"
  : > "$f"
  while IFS= read -r p; do
    if [[ -e "$p" ]] && [[ "$(readlink -f "$p")" != "$FLORA_HOME"* ]]; then
      printf '%s\n' "$p" >> "$f"
      found=$((found+1))
    fi
  done < <(external_paths)
  if [[ "$found" -gt 0 ]]; then
    ok "noted $found pre-existing agent director$([[ $found -eq 1 ]] && echo y || echo ies) outside Flora"
    sed 's/^/       /' "$f"
    log "Flora will not read, write or upgrade those. Its own state lives in state/."
  else
    skip "no pre-existing Hermes or OpenCode state outside Flora"
  fi
}

# git_remote_sha <repo> <ref>  -- the commit SHA <ref> resolves to on <repo>,
# without a local checkout. Used by anything comparing a deployed commit
# against upstream (install-tokenring.sh, update.sh).
#
# An ANNOTATED tag (git tag -a -- what `gh release create` and most release
# workflows produce) is its own object with its own SHA, distinct from the
# commit it points at. ls-remote's plain "refs/tags/$REF" line gives the tag
# object, not the commit, and comparing that against `git rev-parse HEAD`
# would never match, wrongly claiming an update is always available. The
# "^{}" (peeled) form is ls-remote's dereferenced commit; try that first and
# only fall back to the direct lookup for lightweight tags, branches, or a
# raw SHA.
git_remote_sha() {
  local repo="$1" ref="$2" out
  out="$(git ls-remote "$repo" "refs/tags/$ref^{}" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$out" ]]; then
    out="$(git ls-remote "$repo" "$ref" "refs/tags/$ref" "refs/heads/$ref" 2>/dev/null | head -1 | awk '{print $1}')"
  fi
  # A ref that resolves to nothing is probably already a raw commit SHA.
  [[ -z "$out" && "$ref" =~ ^[0-9a-f]{7,40}$ ]] && out="$ref"
  echo "$out"
}

is_external_known() {
  local f="$FLORA_HOME/$EXTERNAL_LIST_REL"
  [[ -f "$f" ]] && grep -qxF "$1" "$f"
}

# --- misc ------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 ($2)"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "this step needs root (${1:-it touches /etc or systemd})"; }

port_free() { ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

# systemd helpers that tolerate a non-systemd box (docker, WSL) gracefully.
has_systemd() { [[ -d /run/systemd/system ]] && have_cmd systemctl; }
sd() { has_systemd || { warn "systemd unavailable; skipped: systemctl $*"; return 0; }; systemctl "$@"; }

flora_units() {
  local u=(flora-tokenring.service flora-hermes-dashboard.service
           flora-hermes-gateway.service flora-opencode.service flora-mattermost.service)
  # Flora's own nginx is a service like any other; a host nginx is not hers to manage.
  [[ "${FLORA_NGINX:-docker}" == "docker" ]] && u+=(flora-nginx.service)
  printf '%s\n' "${u[@]}"
}
flora_timers() {
  printf '%s\n' flora-skills-sync.timer flora-health.timer flora-housekeeping.timer
}
