#!/usr/bin/env bash
# One-time migration: shared/ used to be tracked by the platform repository and
# is now live data that the repository ignores.
#
# Tracked live data was a mistake: both agents write to shared/, so `git pull`
# collided with the platform's own data and refused to run. This moves your
# shared/ out of git's way, without losing anything.
#
# It runs in two phases, because a git pull sits between them.
#
#   bin/flora migrate-shared     # phase 1, BEFORE the pull
#   git pull --rebase origin main
#   bin/flora migrate-shared     # phase 2, after it -- puts your files back
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

ASIDE="$FLORA_HOME/shared.mine"
tracked() { [[ -n "$(git -C "$FLORA_HOME" ls-files shared/ 2>/dev/null | head -1)" ]]; }

[[ -d "$FLORA_HOME/.git" ]] || die "not a git checkout; nothing to migrate"

# ---------------------------------------------------------------- phase 2 ----
if [[ -d "$ASIDE" ]] && ! tracked; then
  step "Restoring your shared/ (phase 2)"
  "$FLORA_HOME/scripts/seed.sh" | sed 's/^/  /'
  log "copying your files back over the defaults"
  cp -a "$ASIDE/." "$FLORA_SHARED/"
  ok "restored $(find "$ASIDE" -type f | wc -l) file(s) from shared.mine/"
  "$FLORA_HOME/scripts/skills-sync.sh" | sed 's/^/  /'
  echo
  ok "done. shared/ is yours now and the repository ignores it."
  log "Check it, then remove the copy:  rm -rf $ASIDE"
  log "Want a history of your skills?   git init shared && git -C shared add -A && git -C shared commit -m skills"
  exit 0
fi

# ---------------------------------------------------------------- phase 1 ----
if ! tracked; then
  ok "shared/ is already untracked -- nothing to migrate"
  [[ -d "$ASIDE" ]] && warn "an old copy is still at shared.mine/; remove it when you are happy: rm -rf $ASIDE"
  exit 0
fi

step "Moving your shared/ out of git's way (phase 1)"
[[ -e "$ASIDE" ]] && die "$ASIDE already exists; move or remove it first"

n="$(find "$FLORA_SHARED" -type f 2>/dev/null | wc -l)"
log "$n file(s) in shared/ -- skills, instructions, MCP servers"
cp -a "$FLORA_SHARED" "$ASIDE"
ok "copied to shared.mine/ (nothing deleted yet)"

# Put the tracked copies back exactly as the repository has them, so the working
# tree is clean and the pull can run. Your versions are already safe in
# shared.mine/, and phase 2 copies them back over the top.
git -C "$FLORA_HOME" checkout -- shared/ 2>/dev/null || true
if [[ -n "$(git -C "$FLORA_HOME" status --porcelain -- shared/ 2>/dev/null)" ]]; then
  warn "shared/ still has changes git cannot discard on its own:"
  git -C "$FLORA_HOME" status --porcelain -- shared/ | sed 's/^/       /'
  log "They are saved in shared.mine/. Clear them with:"
  log "    git -C $FLORA_HOME clean -fd shared/"
else
  ok "shared/ matches the repository; the working tree is clean"
fi

echo
step "Next"
log "1.  git pull --rebase origin main"
log "2.  bin/flora migrate-shared        # puts your files back"
log "3.  sudo bin/flora upgrade          # if you also want the newer platform"
