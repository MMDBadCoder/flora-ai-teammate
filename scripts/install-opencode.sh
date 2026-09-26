#!/usr/bin/env bash
# Installs an OpenCode that belongs to Flora and to nothing else.
#
# ISOLATION. A local npm prefix keeps the binary inside state/opencode, and the
# wrapper redirects HOME and the XDG variables so sessions, credentials and
# caches live there too.
#
# The npm install itself also runs isolated, which is not optional: the
# opencode-ai package has a postinstall step that touches $HOME, and with the
# operator's HOME in scope it silently creates ~/.config/opencode and
# ~/.local/share/opencode on their account. Redirecting HOME for the install
# command is what keeps Flora's footprint genuinely inside its own directory.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "OpenCode"
if [[ "${FLORA_ENABLE_OPENCODE:-true}" != "true" ]]; then
  skip "OpenCode is disabled (FLORA_ENABLE_OPENCODE=false); not installing"
  exit 0
fi
record_external_installs
need_cmd npm "install Node.js 20+"

NPM_ROOT="$FLORA_STATE/opencode/npm"
OC_HOME="$FLORA_STATE/opencode/home"
PKG="${FLORA_OPENCODE_PACKAGE:-opencode-ai@latest}"

ensure_dir "$NPM_ROOT"
ensure_dir "$OC_HOME"
ensure_dir "$FLORA_STATE/opencode/config/skills"
ensure_dir "$FLORA_STATE/opencode/npm-cache"
ensure_dir "$FLORA_STATE/opencode/xdg/config"
ensure_dir "$FLORA_STATE/opencode/xdg/data"

# npm, with every path it might write to pointed inside the Flora tree.
oc_npm() {
  env HOME="$OC_HOME" \
      XDG_CONFIG_HOME="$FLORA_STATE/opencode/xdg/config" \
      XDG_DATA_HOME="$FLORA_STATE/opencode/xdg/data" \
      XDG_STATE_HOME="$FLORA_STATE/opencode/xdg/state" \
      XDG_CACHE_HOME="$FLORA_STATE/opencode/xdg/cache" \
      npm_config_cache="$FLORA_STATE/opencode/npm-cache" \
      OPENCODE_CONFIG_DIR="$FLORA_STATE/opencode/config" \
      OPENCODE_DISABLE_AUTOUPDATE=1 \
      PATH="$PATH" \
      npm "$@"
}

current=""
if [[ -f "$NPM_ROOT/node_modules/opencode-ai/package.json" ]]; then
  current="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
    "$NPM_ROOT/node_modules/opencode-ai/package.json" 2>/dev/null || true)"
fi

if [[ -n "$current" && "${FLORA_UPDATE:-0}" != "1" ]]; then
  skip "OpenCode $current already installed (FLORA_UPDATE=1 to upgrade)"
else
  log "npm install $PKG --prefix ${NPM_ROOT/#$FLORA_HOME/.}"
  oc_npm install --prefix "$NPM_ROOT" --no-audit --no-fund "$PKG"
fi

BIN="$NPM_ROOT/node_modules/.bin/opencode"
[[ -x "$BIN" ]] || BIN="$NPM_ROOT/bin/opencode"
[[ -x "$BIN" ]] || die "opencode binary not found under $NPM_ROOT after install"
ok "opencode binary: ${BIN/#$FLORA_HOME/.}"

# The OpenAI-compatible provider driver OpenCode loads for TokenRing.
if [[ ! -d "$NPM_ROOT/node_modules/@ai-sdk/openai-compatible" ]]; then
  log "installing @ai-sdk/openai-compatible (the TokenRing provider driver)"
  oc_npm install --prefix "$NPM_ROOT" --no-audit --no-fund @ai-sdk/openai-compatible \
    || warn "could not preinstall the provider driver; OpenCode will fetch it on first use"
fi

# Flora's git identity, used for every commit and every Gerrit push.
git config --file "$OC_HOME/.gitconfig" user.name  "Flora"
git config --file "$OC_HOME/.gitconfig" user.email "${FLORA_ADMIN_EMAIL%@*}+flora@${FLORA_DOMAIN}"

# Nothing should have escaped. If it did, say so rather than let it rot.
for leaked in "$HOME/.config/opencode" "$HOME/.local/share/opencode"; do
  if [[ -e "$leaked" ]] && ! is_external_known "$leaked"; then
    warn "the install created $leaked outside the Flora tree.
       Flora does not use it. Remove it if it is not yours:  rm -rf $leaked"
  fi
done

ok "OpenCode installed"
