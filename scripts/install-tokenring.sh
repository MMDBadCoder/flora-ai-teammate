#!/usr/bin/env bash
# Installs / updates TokenRing from source into state/tokenring/src.
#
# WHY SOURCE. Upstream publishes no tagged releases and no container image (its
# own compose file builds locally), so a git checkout is the only channel there
# is. Building it here also keeps the SQLite database in TOKENRING_DATA_DIR,
# inside this directory, rather than in a Docker volume under /var/lib/docker.
#
# WHAT VERSION. FLORA_TOKENRING_REF picks it, and accepts a branch, a tag or a
# full commit SHA. It defaults to `main` because that is all upstream offers
# today; the moment tags appear, pin one:
#
#     FLORA_TOKENRING_REF=v1.2.0      in flora.env
#
# UPDATING IS EXPLICIT. Without FLORA_UPDATE=1 this script never moves an
# existing checkout -- it reports what is deployed and whether upstream has
# moved, and stops. Every agent's model access goes through this service, so it
# does not get to change under you during an unrelated `bin/flora install`.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

REPO="${FLORA_TOKENRING_REPO:-https://github.com/MMDBadCoder/tokenring.git}"
REF="${FLORA_TOKENRING_REF:-main}"
SRC="$FLORA_STATE/tokenring/src"
STAMP="$FLORA_STATE/tokenring/deployed.txt"

step "TokenRing"
need_cmd git "apt install git"
need_cmd npm "install Node.js 20.11+"
ensure_dir "$FLORA_STATE/tokenring/data" 0700

# What does upstream have for this ref? One network call, no checkout needed.
remote_sha() {
  local out
  # An ANNOTATED tag (git tag -a, what `gh release create` and most release
  # workflows use) is its own object with its own SHA, distinct from the commit
  # it points at -- ls-remote's plain "refs/tags/$REF" line gives the tag
  # object, not the commit, and comparing that against `git rev-parse HEAD`
  # would never match, so every check would wrongly claim an update is
  # available. The "^{}" (peeled) form is ls-remote's dereferenced commit; try
  # that first and only fall back to the direct lookup for lightweight tags,
  # branches, or a raw SHA.
  out="$(git ls-remote "$REPO" "refs/tags/$REF^{}" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$out" ]]; then
    out="$(git ls-remote "$REPO" "$REF" "refs/tags/$REF" "refs/heads/$REF" 2>/dev/null | head -1 | awk '{print $1}')"
  fi
  # A ref that resolves to nothing is probably already a raw commit SHA.
  [[ -z "$out" && "$REF" =~ ^[0-9a-f]{7,40}$ ]] && out="$REF"
  echo "$out"
}

build() {
  log "installing dependencies (this takes a minute)"
  ( cd "$SRC" && npm install --no-audit --no-fund )
  log "building server + dashboard"
  ( cd "$SRC" && npm run build )
  [[ -f "$SRC/server/dist/main.js" ]] || die "build finished but server/dist/main.js is missing"
}

checkout() {
  local sha="$1"
  git -C "$SRC" fetch --depth 1 origin "$REF" --quiet 2>/dev/null \
    || git -C "$SRC" fetch --depth 1 origin "$sha" --quiet \
    || die "could not fetch '$REF' from $REPO"
  git -C "$SRC" checkout --quiet FETCH_HEAD
}

# ---------------------------------------------------------------- first run --
if [[ ! -d "$SRC/.git" ]]; then
  log "cloning $REPO ($REF)"
  if ! git clone --depth 1 --branch "$REF" "$REPO" "$SRC" --quiet 2>/dev/null; then
    # --branch does not take a raw SHA, so fall back to clone-then-fetch.
    git clone --depth 1 "$REPO" "$SRC" --quiet \
      || die "clone failed. If the repo is private, add an SSH key and put the ssh
     URL in FLORA_TOKENRING_REPO inside flora.env."
    checkout "$REF"
  fi
  build
  git -C "$SRC" rev-parse HEAD > "$STAMP"
  ok "TokenRing built at $(cut -c1-8 "$STAMP") ($REF)"
  exit 0
fi

# ------------------------------------------------------------- already built --
have="$(git -C "$SRC" rev-parse HEAD)"
want="$(remote_sha)"

if [[ -z "$want" ]]; then
  warn "cannot reach $REPO to check for updates; leaving the deployed build alone"
  want="$have"
fi

if [[ "$have" == "$want" && -f "$SRC/server/dist/main.js" ]]; then
  skip "TokenRing is current: ${have:0:8} ($REF)"
  exit 0
fi

if [[ ! -f "$SRC/server/dist/main.js" ]]; then
  log "the build output is missing; rebuilding ${have:0:8}"
  build
  ok "rebuilt ${have:0:8}"
  exit 0
fi

if [[ "${FLORA_UPDATE:-0}" != "1" ]]; then
  echo
  warn "A newer TokenRing is available on '$REF':"
  printf '    deployed  %s\n    upstream  %s\n\n' "${have:0:8}" "${want:0:8}"
  log "Nothing was changed. To review first:"
  printf '    git -C %s log --oneline %s..%s\n' "$SRC" "${have:0:8}" "${want:0:8}"
  log "To apply it:"
  printf '    FLORA_UPDATE=1 bin/flora install tokenring\n'
  exit 0
fi

# ------------------------------------------------------------------ updating --
# TokenRing migrates its schema on boot, and migrations only run forwards. If a
# new build turns out to be wrong, the old binary may not read the migrated
# database -- so the database is copied aside first. It is a few MB of SQLite.
SAFE="$FLORA_STATE/tokenring/data.pre-${have:0:8}"
rm -rf "$FLORA_STATE"/tokenring/data.pre-* 2>/dev/null || true
cp -a "$FLORA_STATE/tokenring/data" "$SAFE"
ok "copied the key pool aside: $(basename "$SAFE")"

log "updating ${have:0:8} -> ${want:0:8}"
checkout "$want"
build
git -C "$SRC" rev-parse HEAD > "$STAMP"
ok "TokenRing updated to $(cut -c1-8 "$STAMP") ($REF)"
echo
log "restart it and confirm the pool still answers:"
log "    bin/flora restart tokenring && bin/flora status"
log "if it does not, roll back with:"
log "    FLORA_TOKENRING_REF=$have FLORA_UPDATE=1 bin/flora install tokenring"
log "    rm -rf state/tokenring/data && mv $SAFE state/tokenring/data"
