#!/usr/bin/env bash
# Installs / updates OpenCode into state/opencode/npm.
#
# A local npm prefix rather than `npm i -g`, so the whole agent -- binary,
# config, sessions, credentials -- sits inside the Flora directory and a
# system-wide npm upgrade cannot change Flora's behaviour behind your back.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "OpenCode"
need_cmd npm "install Node.js 20+"

NPM_ROOT="$FLORA_STATE/opencode/npm"
PKG="${FLORA_OPENCODE_PACKAGE:-opencode-ai@latest}"
ensure_dir "$NPM_ROOT"
ensure_dir "$FLORA_STATE/opencode/home"
ensure_dir "$FLORA_STATE/opencode/config/skills"

current=""
if [[ -f "$NPM_ROOT/node_modules/opencode-ai/package.json" ]]; then
  current="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
    "$NPM_ROOT/node_modules/opencode-ai/package.json" 2>/dev/null || true)"
fi

if [[ -n "$current" && "${FLORA_UPDATE:-0}" != "1" ]]; then
  skip "OpenCode $current already installed (FLORA_UPDATE=1 to upgrade)"
else
  log "npm install $PKG --prefix $NPM_ROOT"
  npm install --prefix "$NPM_ROOT" --no-audit --no-fund "$PKG"
fi

BIN="$NPM_ROOT/node_modules/.bin/opencode"
[[ -x "$BIN" ]] || BIN="$NPM_ROOT/bin/opencode"
[[ -x "$BIN" ]] || die "opencode binary not found under $NPM_ROOT after install"
ok "opencode binary: $BIN"

# The OpenAI-compatible provider driver OpenCode loads for TokenRing.
if [[ ! -d "$NPM_ROOT/node_modules/@ai-sdk/openai-compatible" ]]; then
  log "installing @ai-sdk/openai-compatible (the TokenRing provider driver)"
  npm install --prefix "$NPM_ROOT" --no-audit --no-fund @ai-sdk/openai-compatible || \
    warn "could not preinstall the provider driver; OpenCode will fetch it on first use"
fi

# Flora's git identity, used for every commit and every Gerrit push.
git config --file "$FLORA_STATE/opencode/home/.gitconfig" user.name  "Flora" 
git config --file "$FLORA_STATE/opencode/home/.gitconfig" user.email "${FLORA_ADMIN_EMAIL%@*}+flora@${FLORA_DOMAIN}"
ok "OpenCode installed"
