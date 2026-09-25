#!/usr/bin/env bash
# Installs / updates TokenRing from source into state/tokenring/src.
#
# Source rather than the published Docker image because the SQLite database
# then lives in the Flora tree (TOKENRING_DATA_DIR) instead of a Docker volume
# under /var/lib/docker, outside this directory.
#
# Idempotent: re-running fetches, and only rebuilds when the checkout moved or
# the build output is missing.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

REPO="${FLORA_TOKENRING_REPO:-https://github.com/MMDBadCoder/tokenring.git}"
REF="${FLORA_TOKENRING_REF:-main}"
SRC="$FLORA_STATE/tokenring/src"

step "TokenRing"
need_cmd git "apt install git"
need_cmd npm "install Node.js 20.11+"

ensure_dir "$FLORA_STATE/tokenring/data" 0700

before=""
if [[ -d "$SRC/.git" ]]; then
  before="$(git -C "$SRC" rev-parse HEAD)"
  log "fetching $REF"
  git -C "$SRC" fetch --depth 1 origin "$REF" --quiet
  git -C "$SRC" checkout --quiet FETCH_HEAD
else
  log "cloning $REPO ($REF)"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC" --quiet \
    || die "clone failed. If the repo is private, set up an SSH key and put the
     ssh URL in FLORA_TOKENRING_REPO inside flora.env."
fi
after="$(git -C "$SRC" rev-parse HEAD)"

if [[ "$before" == "$after" && -f "$SRC/server/dist/main.js" ]]; then
  skip "TokenRing already built at ${after:0:8}"
else
  log "installing dependencies (this takes a minute)"
  ( cd "$SRC" && npm install --no-audit --no-fund )
  log "building server + dashboard"
  ( cd "$SRC" && npm run build )
  [[ -f "$SRC/server/dist/main.js" ]] || die "build finished but server/dist/main.js is missing"
  ok "TokenRing built at ${after:0:8}"
fi
