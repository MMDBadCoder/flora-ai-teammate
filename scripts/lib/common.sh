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
  : "${FLORA_PORT_SCRIBE:=8100}"
  : "${FLORA_PUBLIC_SCRIBE:=7085}"
  : "${FLORA_HOST_SCRIBE:=scribe.${FLORA_DOMAIN}}"
  : "${FLORA_ENABLE_SCRIBE:=false}"
  : "${FLORA_SCRIBE_REF:=0.2.0}"
  : "${FLORA_SCRIBE_REPO:=https://github.com/MMDBadCoder/voice-2-text.git}"
  : "${FLORA_SCRIBE_ASR_BACKEND:=stub}"
  : "${FLORA_SCRIBE_WORKERS:=1}"
  : "${FLORA_SCRIBE_CPU_THREADS:=2}"
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
         FLORA_ENABLE_MATTERMOST FLORA_PORT_SCRIBE FLORA_PUBLIC_SCRIBE \
         FLORA_HOST_SCRIBE FLORA_ENABLE_SCRIBE FLORA_SCRIBE_REF FLORA_SCRIBE_REPO \
         FLORA_SCRIBE_ASR_BACKEND FLORA_SCRIBE_WORKERS FLORA_SCRIBE_CPU_THREADS

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
  # Routing is a per-service choice: FLORA_ROUTING is the default and
  # FLORA_ROUTE_<SERVICE> overrides it for one, so a team can put Mattermost on a
  # memorable subdomain while the agent UIs stay on ports nobody has to add to a
  # hosts file. The advertised URL has to follow the same choice, or Hermes'
  # Host check and Mattermost's SiteURL end up pointing at an address that does
  # not route.
  local svc host_var port_var url
  for svc in DASHBOARD HERMES OPENCODE CHAT TOKENS SCRIBE; do
    host_var="FLORA_HOST_$svc"; port_var="FLORA_PUBLIC_$svc"
    if [[ "$(flora_route_mode "$svc")" == "subdomain" ]]; then
      url="http://${!host_var}${FLORA_URL_PORT}"
    else
      url="http://${FLORA_IP}:${!port_var}"
    fi
    printf -v "FLORA_URL_$svc" '%s' "$url"
    export "FLORA_URL_$svc"
  done

  # A NAT gateway, container port-forward or reverse proxy in front of this
  # machine can translate ports (e.g. an external example.com:28001 forwarded
  # to this machine's own 7083) -- FLORA_IP:FLORA_PUBLIC_* has no way to
  # express that, since it assumes whatever port a service listens on here is
  # also the port people type. These let the *advertised* URL differ from the
  # port nginx actually binds, without touching what nginx itself listens on
  # (nginx's own listen port is FLORA_PUBLIC_*, always -- only what gets
  # written into links, Mattermost's SiteURL, etc. changes here).
  : "${FLORA_URL_DASHBOARD_OVERRIDE:=}"
  : "${FLORA_URL_HERMES_OVERRIDE:=}"
  : "${FLORA_URL_OPENCODE_OVERRIDE:=}"
  : "${FLORA_URL_CHAT_OVERRIDE:=}"
  : "${FLORA_URL_TOKENS_OVERRIDE:=}"
  [[ -n "$FLORA_URL_DASHBOARD_OVERRIDE" ]] && FLORA_URL_DASHBOARD="$FLORA_URL_DASHBOARD_OVERRIDE"
  [[ -n "$FLORA_URL_HERMES_OVERRIDE" ]] && FLORA_URL_HERMES="$FLORA_URL_HERMES_OVERRIDE"
  [[ -n "$FLORA_URL_OPENCODE_OVERRIDE" ]] && FLORA_URL_OPENCODE="$FLORA_URL_OPENCODE_OVERRIDE"
  [[ -n "$FLORA_URL_CHAT_OVERRIDE" ]] && FLORA_URL_CHAT="$FLORA_URL_CHAT_OVERRIDE"
  [[ -n "$FLORA_URL_TOKENS_OVERRIDE" ]] && FLORA_URL_TOKENS="$FLORA_URL_TOKENS_OVERRIDE"
  export FLORA_URL_DASHBOARD FLORA_URL_HERMES FLORA_URL_OPENCODE FLORA_URL_CHAT FLORA_URL_TOKENS

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
# secret_ensure <FILE.env> <KEY> -- generate a value when the key is missing OR
# present but empty. secret_set deliberately never touches an existing key, which
# is right for a value someone filled in and wrong for one that must not be blank:
# an empty credential is not "configured", it is a config that cannot work.
secret_ensure() {
  local file="$FLORA_HOME/secrets/$1" key="$2" val
  ensure_dir "$FLORA_HOME/secrets" 0700
  touch "$file"; chmod 0600 "$file"
  if grep -qE "^${key}=.+" "$file"; then FLORA_CHANGED=0; return 0; fi
  val="$(gen_secret 24)"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
  printf -v "$key" '%s' "$val"
  export "$key"
  ok "generated $key (it was empty, and an empty one stops the service starting)"
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

# check_bind_safety -- refuse to proceed if the agent UIs would be reachable
# directly, unauthenticated. FLORA_BIND_ADDR=0.0.0.0 (or any non-loopback
# address) puts Hermes and OpenCode on every interface; FLORA_AUTH_MODE=nginx
# unsets each backend's own password because it assumes nginx is the only way
# in. Together that is an unauthenticated shell, network-reachable. Called
# from render.sh (before anything is written) AND install-systemd.sh (before
# anything is activated) -- both matter: a unit file staged by an older render
# should not become live just because install-systemd.sh trusts state/systemd/.
check_bind_safety() {
  if [[ "$FLORA_BIND_ADDR" != "127.0.0.1" && "$FLORA_AUTH_MODE" != "backend" ]]; then
    die "FLORA_BIND_ADDR=$FLORA_BIND_ADDR exposes the agent UIs directly, but
     FLORA_AUTH_MODE=nginx only protects the nginx route. Anyone who reaches
     port $FLORA_PORT_OPENCODE or $FLORA_PORT_HERMES would get an unauthenticated
     shell on this machine. Set FLORA_AUTH_MODE=backend, or keep
     FLORA_BIND_ADDR=127.0.0.1."
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

# flora_route_mode <SERVICE_UC> -- port | subdomain, per service.
flora_route_mode() {
  local svc_uc="$1" chosen default
  default="port"; [[ "$FLORA_ROUTING" == "hosts" ]] && default="subdomain"
  chosen="$(eval "printf '%s' \"\${FLORA_ROUTE_${svc_uc}:-}\"")"
  case "${chosen,,}" in
    port|ports)                 echo port ;;
    subdomain|host|hosts|domain) echo subdomain ;;
    "")                         echo "$default" ;;
    *) die "FLORA_ROUTE_${svc_uc} must be 'port' or 'subdomain' (got: $chosen)" ;;
  esac
}

# verify_nginx_references -- every path the generated config names must exist.
#
# `nginx -t` validates syntax, not reality: a vhost pointing at a password file
# or a document root that is not there passes the test and then fails at request
# time, with a status code that describes nothing useful. This closes that gap
# generically -- for auth files, roots and includes alike -- so a future config
# referencing a future file cannot reintroduce the same class of fault.
verify_nginx_references() {
  local conf="${1:-$FLORA_STATE/nginx/flora.conf}"
  [[ -f "$conf" ]] || { err "no generated config at $conf"; return 1; }
  local report
  report="$(python3 "$FLORA_HOME/scripts/lib/nginx_verify.py" "$conf")" || {
    printf '%s\n' "$report" | while IFS= read -r line; do err "$line"; done
    log "    nginx would start and then fail every request touching these."
    log "    Regenerate them with:  bin/flora render"
    return 1
  }
  ok "every path the config references exists"
  return 0
}

# verify_hermes_toolchain -- does the Node that Hermes downloaded actually run?
#
# Hermes brings its own Node rather than using the system one, which is what
# keeps it isolated -- but that binary still needs its shared libraries present.
# A minimal Debian or Ubuntu has no libatomic1, and Node links against it, so the
# download succeeds, the checksum verifies, and every later `node --version`
# exits 127. Hermes reports that as "Building web UI... failed" in a loop, which
# names neither the library nor the package.
#
# Rather than hardcode one library, this runs the binary and reads whichever one
# the loader says is missing.
verify_hermes_toolchain() {
  local node
  node="$(find "$FLORA_STATE/hermes/tools" -maxdepth 3 -type f -name node -perm -u+x 2>/dev/null | head -1)"
  [[ -n "$node" ]] || { skip "Hermes has not downloaded its Node yet"; return 0; }

  # `out=$(cmd)` with a failing cmd aborts the shell under `set -e` before the
  # exit status can be read, so the failure is captured explicitly.
  local out rc=0
  out="$("$node" --version 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "Hermes' bundled Node runs ($out)"
    return 0
  fi

  local lib pkg
  lib="$(grep -oE '[a-zA-Z0-9_.+-]+\.so[0-9.]*' <<< "$out" | head -1)"
  if [[ -z "$lib" ]]; then
    err "Hermes' bundled Node will not run:"
    sed 's/^/       /' <<< "$out"
    return 1
  fi
  case "$lib" in
    libatomic.so*) pkg="libatomic1" ;;
    libstdc++.so*) pkg="libstdc++6" ;;
    libgcc_s.so*)  pkg="libgcc-s1" ;;
    *)             pkg="" ;;
  esac
  err "Hermes' bundled Node cannot start: $lib is missing"
  log "    Hermes downloads its own Node, and that binary needs this library from"
  log "    the system. Without it every build step fails with exit 127, which"
  log "    Hermes reports only as \"Building web UI... failed\"."
  if [[ -n "$pkg" ]]; then
    log "    Fix:  sudo apt install -y $pkg"
  else
    log "    Find the package with:  apt-file search $lib"
  fi
  return 1
}

# check_dashboard_servable -- why the dashboard answers 403 after a correct login.
#
# A 403 here is never about the password: 401 is "wrong or missing credentials",
# 403 is "you are in, and nginx still will not serve the file". Exactly three
# things cause it, each with its own signature in nginx's error log:
#
#   1. index.html is not there          -> "directory index of ... is forbidden"
#   2. index.html is not readable       -> open() ... failed (13: Permission denied)
#   3. its directory is not traversable -> "..." is forbidden (13: Permission denied)
#
# Guessing between them costs more than checking, so this checks.
check_dashboard_servable() {
  local root="$FLORA_STATE/dashboard" idx="$FLORA_STATE/dashboard/index.html"
  local ht="$FLORA_STATE/nginx/htpasswd"
  local problems=0

  # The account list, first: a MISSING password file makes nginx challenge and
  # then answer 403 to every credential, right or wrong, which reads as a broken
  # install rather than a missing file. (An unreadable one gives 500 instead.)
  if grep -rqs "auth_basic_user_file" "$FLORA_STATE/nginx/"*.conf 2>/dev/null; then
    if [[ ! -s "$ht" ]]; then
      err "no account file at ${ht/#$FLORA_HOME/.}, but a vhost requires one"
      log "    Every login will be refused with 403, whatever is typed. Create one:"
      log "      bin/flora user add ${FLORA_ADMIN_USER:-admin}"
      problems=1
    elif [[ ! "$(stat -c %a "$ht")" =~ [4567]$ ]]; then
      err "$ht is not readable by nginx (mode $(stat -c %a "$ht")) -- logins will fail with 500"
      log "      sudo chmod a+r $ht"
      problems=1
    fi
  fi

  if [[ ! -f "$idx" ]]; then
    err "the dashboard page is missing: ${idx/#$FLORA_HOME/.}"
    log "    It is generated. Rebuild it with:  bin/flora render"
    problems=1
  else
    # nginx runs as an unprivileged user -- the container's own, or www-data --
    # so "others" is what matters here, not the owner.
    local dmode fmode
    dmode="$(stat -c %a "$root")"; fmode="$(stat -c %a "$idx")"
    if [[ ! "$dmode" =~ [157]$ ]]; then
      err "$root is mode $dmode -- nginx cannot traverse it"
      log "    sudo chmod a+rx $root"
      problems=1
    fi
    if [[ ! "$fmode" =~ [4567]$ ]]; then
      err "$idx is mode $fmode -- nginx cannot read it"
      log "    sudo chmod a+r $idx"
      problems=1
    fi
  fi

  # What the container actually sees can differ from the host: a bind mount whose
  # source did not exist when the container was created shows up empty inside.
  # Only meaningful against a RUNNING container. `docker ps` also lists one that
  # is crash-restarting, and calling that a stale mount would send someone after
  # the wrong problem.
  if have_cmd docker; then
    local state
    state="$(docker inspect -f '{{.State.Status}}' flora-nginx 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      if ! docker exec flora-nginx test -f "$idx" 2>/dev/null; then
        err "flora-nginx is running but cannot see $idx inside the container"
        log "    Its bind mount predates the file -- recreate it:  sudo bin/flora nginx"
        problems=1
      fi
    elif [[ -n "$state" && "$state" != "exited" ]]; then
      warn "flora-nginx is $state, not running -- check why:  bin/flora logs nginx"
    fi
  fi

  [[ "$problems" -eq 0 ]] && ok "the dashboard page is present and servable"
  return "$problems"
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
  # Optional modules are only units when they are switched on.
  [[ "${FLORA_ENABLE_SCRIBE:-false}" == "true" ]] && u+=(flora-scribe.service)
  # Flora's own nginx is a service like any other; a host nginx is not hers to manage.
  [[ "${FLORA_NGINX:-docker}" == "docker" ]] && u+=(flora-nginx.service)
  printf '%s\n' "${u[@]}"
}
flora_timers() {
  printf '%s\n' flora-skills-sync.timer flora-health.timer flora-housekeeping.timer
}
