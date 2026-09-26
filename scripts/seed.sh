#!/usr/bin/env bash
# Installs the shipped defaults from seed/ into shared/, which is live data.
#
#   seed.sh              add anything missing; never overwrite
#   seed.sh --diff       show where a live file has drifted from its default
#   seed.sh --force <p>  replace one live file with the shipped default
#
# WHY THE SPLIT. shared/ is Flora's brain and both agents write to it. Tracking
# it in the repository the platform is pulled from means every `git pull` fights
# the platform's own data -- which is exactly what happens. So seed/ is shipped
# and tracked, shared/ is yours and ignored, and nothing here overwrites your
# work: a newer default is reported, not applied.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

SEED="$FLORA_HOME/seed"
[[ -d "$SEED" ]] || die "no seed/ directory -- is this a complete checkout?"

MODE=add
[[ "${1:-}" == "--diff" ]] && MODE=diff
if [[ "${1:-}" == "--force" ]]; then
  MODE=force
  TARGET="${2:?usage: seed.sh --force <path relative to shared/>}"
fi

added=0; drifted=0; same=0
while IFS= read -r src; do
  rel="${src#$SEED/}"
  dst="$FLORA_SHARED/$rel"

  if [[ "$MODE" == "force" ]]; then
    [[ "$rel" == "$TARGET" ]] || continue
    ensure_dir "$(dirname "$dst")" >/dev/null
    [[ -f "$dst" ]] && cp -p "$dst" "$dst.replaced-$(date +%Y%m%d-%H%M%S)"
    cp -p "$src" "$dst"
    ok "replaced shared/$rel with the shipped default (your copy kept alongside)"
    exit 0
  fi

  if [[ ! -e "$dst" ]]; then
    if [[ "$MODE" == "diff" ]]; then
      warn "shared/$rel is missing (run: bin/flora seed)"
    else
      ensure_dir "$(dirname "$dst")" >/dev/null
      cp -p "$src" "$dst"
      ok "added shared/$rel"
    fi
    added=$((added+1))
  elif cmp -s "$src" "$dst"; then
    same=$((same+1))
  else
    drifted=$((drifted+1))
    if [[ "$MODE" == "diff" ]]; then
      printf '\n%s--- shared/%s differs from the shipped default ---%s\n' "$_c_bold" "$rel" "$_c_reset"
      diff -u "$src" "$dst" | sed -n '3,40p' || true
    fi
  fi
done < <(find "$SEED" -type f | sort)

[[ "$MODE" == "force" ]] && die "no seed file at $TARGET"

echo
if [[ "$MODE" == "diff" ]]; then
  log "$same unchanged, $drifted modified locally, $added missing"
  [[ "$drifted" -gt 0 ]] && log "Yours win. To take a shipped default instead: bin/flora seed --force <path>"
else
  [[ "$added" -gt 0 ]] && ok "seeded $added file(s) into shared/" || skip "shared/ already has every default"
  [[ "$drifted" -gt 0 ]] && log "$drifted file(s) differ from the defaults, and were left alone (bin/flora seed --diff)"
fi
exit 0
