#!/usr/bin/env bash
# Installs / updates Scribe -- offline Persian meeting transcription.
# Upstream: https://github.com/MMDBadCoder/voice-2-text
#
# OPTIONAL. Does nothing unless FLORA_ENABLE_SCRIBE=true. It is the heaviest
# module Flora can run -- upstream asks for 8GB RAM per accurate-model worker and
# the model is ~1.6GB -- so it is off until someone decides otherwise.
#
# TREATED AS A BLACK BOX, the same way TokenRing is. Flora pins a released tag,
# builds with upstream's own docker-compose.yml, and configures it only through
# the .env keys upstream documents. The one addition is a Compose override file
# moving data and models out of the checkout, which is Compose's own documented
# merge, not a reach into how the app works. Nothing here parses upstream's
# source or depends on anything it has not published.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

SRC="$FLORA_STATE/scribe/src"
STAMP="$FLORA_STATE/scribe/deployed.txt"
REF="${FLORA_SCRIBE_REF}"
REPO="${FLORA_SCRIBE_REPO}"

step "Scribe"

if [[ "${FLORA_ENABLE_SCRIBE}" != "true" ]]; then
  skip "FLORA_ENABLE_SCRIBE=false -- not installed"
  log "Enable it in flora.env, then: bin/flora install scribe"
  exit 0
fi

need_cmd git "apt install git"
need_cmd docker "apt install docker.io docker-compose-v2"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing"

# Data and models live outside the checkout so a version bump never touches them.
ensure_dir "$FLORA_STATE/scribe/data"
ensure_dir "$FLORA_STATE/scribe/models"

# Upstream's image runs as uid 10001 and will not start if it cannot write here.
if [[ "$(stat -c %u "$FLORA_STATE/scribe/data")" != "10001" ]]; then
  chown -R 10001:10001 "$FLORA_STATE/scribe/data" 2>/dev/null \
    && ok "data/ owned by 10001 (what upstream's image runs as)" \
    || warn "could not chown state/scribe/data to 10001; upstream's container may fail to write.
       Run as root, or: sudo chown -R 10001:10001 $FLORA_STATE/scribe/data"
fi

# ------------------------------------------------------------- the checkout --
have=""
if [[ -d "$SRC/.git" ]]; then
  have="$(git -C "$SRC" rev-parse HEAD)"
fi
want="$(git_remote_sha "$REPO" "$REF" 2>/dev/null || true)"

if [[ ! -d "$SRC/.git" ]]; then
  log "cloning $REPO at $REF"
  if ! git clone --depth 1 --branch "$REF" "$REPO" "$SRC" --quiet 2>/dev/null; then
    git clone --depth 1 "$REPO" "$SRC" --quiet || die "clone failed"
    git -C "$SRC" fetch --depth 1 origin "$REF" --quiet || die "no such ref: $REF"
    git -C "$SRC" checkout --quiet FETCH_HEAD
  fi
  have="$(git -C "$SRC" rev-parse HEAD)"
  ok "checked out $REF (${have:0:8})"
elif [[ -n "$want" && "$have" != "$want" ]]; then
  if [[ "${FLORA_UPDATE:-0}" != "1" ]]; then
    warn "Scribe is at ${have:0:8} but $REF is ${want:0:8}"
    log "Apply it with:  FLORA_UPDATE=1 bin/flora install scribe"
  else
    log "updating ${have:0:8} -> ${want:0:8}"
    git -C "$SRC" fetch --depth 1 origin "$REF" --quiet || die "could not fetch $REF"
    git -C "$SRC" checkout --quiet FETCH_HEAD
    have="$(git -C "$SRC" rev-parse HEAD)"
  fi
else
  skip "Scribe checkout is current at $REF (${have:0:8})"
fi
printf '%s\n' "$have" > "$STAMP"

# Upstream reads .env from beside its own compose file, so it can only be written
# once the checkout exists -- which is why it is rendered here rather than left
# to render.sh alone, so a first install is one pass and not two.
render "$FLORA_HOME/config/templates/scribe/env.tmpl" "$SRC/.env" 0600
render "$FLORA_HOME/config/templates/scribe/docker-compose.override.yml.tmpl" \
       "$FLORA_STATE/scribe/docker-compose.override.yml" 0644

compose() {
  docker compose -f "$SRC/docker-compose.yml" \
                 -f "$FLORA_STATE/scribe/docker-compose.override.yml" "$@"
}

log "validating the merged compose configuration"
compose config --quiet || die "upstream's compose file and Flora's override do not merge cleanly"

log "building the image (first time pulls a lot of Python wheels; several minutes)"
compose build || die "image build failed -- see the output above"

ok "Scribe built at ${have:0:8} ($REF)"
if [[ "$FLORA_SCRIBE_ASR_BACKEND" == "stub" ]]; then
  echo
  log "ASR_BACKEND=stub: the UI, queue and exports work, but the text is fabricated."
  log "For real transcription, follow upstream's docs/SETUP.md to put a model in"
  log "    state/scribe/models"
  log "then set FLORA_SCRIBE_ASR_BACKEND=faster_whisper and re-render."
fi
