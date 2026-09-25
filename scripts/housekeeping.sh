#!/usr/bin/env bash
# Weekly tidy-up. Everything here is safe to run while Flora is serving.
#
# Deliberately conservative about Docker: this VPS runs other people's
# containers too, so Flora never calls a global `docker system prune`. Set
# FLORA_HOUSEKEEP_DOCKER=true in flora.env if this box is Flora's alone.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

step "Housekeeping"

# --- logs -------------------------------------------------------------------
keep="${FLORA_LOG_KEEP_DAYS:-30}"
rotated=0
for f in "$FLORA_STATE"/logs/*.log; do
  [[ -e "$f" ]] || continue
  size=$(stat -c %s "$f")
  if [[ "$size" -gt 52428800 ]]; then          # 50MB
    mv "$f" "$f.$(date +%Y%m%d)"
    gzip -f "$f.$(date +%Y%m%d)" &
    : > "$f"
    rotated=$((rotated+1))
  fi
done
wait
[[ "$rotated" -gt 0 ]] && ok "rotated $rotated oversized log(s)" || skip "no log over 50MB"
n=$(find "$FLORA_STATE/logs" -name '*.gz' -mtime "+$keep" -print -delete 2>/dev/null | wc -l)
[[ "$n" -gt 0 ]] && ok "deleted $n archived log(s) older than $keep days" || skip "no old archived logs"

# --- agent sessions ---------------------------------------------------------
sess="${FLORA_SESSION_KEEP_DAYS:-90}"
for d in "$HERMES_HOME/sessions" "$FLORA_STATE/opencode/xdg/data/opencode/storage"; do
  [[ -d "$d" ]] || continue
  n=$(find "$d" -type f -mtime "+$sess" -print -delete 2>/dev/null | wc -l)
  [[ "$n" -gt 0 ]] && ok "pruned $n session file(s) older than $sess days from $(basename "$d")"
done

# --- SQLite maintenance -----------------------------------------------------
python3 - "$FLORA_STATE" <<'PY'
import os, sqlite3, sys
root = sys.argv[1]
done = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ("node_modules", "cache", "postgres", "bleve-indexes")]
    for fn in filenames:
        if fn.endswith((".db", ".sqlite", ".sqlite3")):
            p = os.path.join(dirpath, fn)
            try:
                con = sqlite3.connect(p, timeout=5)
                con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                con.execute("VACUUM")
                con.close()
                done += 1
            except sqlite3.Error:
                pass       # a database in use is skipped; next week will get it
print("  vacuumed %d database(s)" % done)
PY

# --- docker (opt-in) --------------------------------------------------------
if [[ "${FLORA_HOUSEKEEP_DOCKER:-false}" == "true" ]] && have_cmd docker; then
  docker image prune -f --filter 'until=720h' >/dev/null && ok "pruned dangling Docker images older than 30 days"
else
  skip "Docker pruning disabled (FLORA_HOUSEKEEP_DOCKER)"
fi

# --- git --------------------------------------------------------------------
if [[ -d "$FLORA_HOME/.git" ]]; then
  git -C "$FLORA_HOME" gc --quiet --auto && ok "git gc"
fi

# --- reconcile --------------------------------------------------------------
"$FLORA_HOME/scripts/skills-sync.sh" --quiet | sed 's/^/  /' || true
echo
ok "housekeeping done"
