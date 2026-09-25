#!/usr/bin/env bash
# Gerrit helper. Flora uses this instead of calling the API by hand, so the
# credentials stay in exactly one place and the review workflow is always the
# same one the team agreed on.
#
#   gerrit.sh clone <project> [branch]     clone into workspace/ with the hook
#   gerrit.sh push [branch] [topic]        push HEAD for review (refs/for/...)
#   gerrit.sh list [query]                 open changes (default: Flora's own)
#   gerrit.sh show <change-id>             one change with its messages
#   gerrit.sh comments <change-id>         inline comments on the latest patchset
#   gerrit.sh review <change-id> <msg> [score]   post a review (score: -1|0|+1)
#
# Credentials: GERRIT_URL, GERRIT_USER, GERRIT_HTTP_PASSWORD in secrets/flora.env.
# The HTTP password comes from Gerrit -> Settings -> HTTP Credentials, and is NOT
# the account password.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env

: "${GERRIT_URL:?GERRIT_URL is not set -- run: bin/flora secrets edit}"
: "${GERRIT_USER:?GERRIT_USER is not set}"
: "${GERRIT_HTTP_PASSWORD:?GERRIT_HTTP_PASSWORD is not set}"

BASE="${GERRIT_URL%/}"

# Authenticated endpoints live under /a/. Gerrit prefixes every JSON response
# with )]}' to break naive cross-site script inclusion, so it is stripped here.
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --fail-with-body -u "$GERRIT_USER:$GERRIT_HTTP_PASSWORD" -X "$method"
              -H "Content-Type: application/json; charset=UTF-8")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "$BASE/a$path" | sed "1s/^)]}'//"
}

case "${1:-help}" in

  clone)
    project="${2:?usage: gerrit.sh clone <project> [branch]}"
    branch="${3:-}"
    dest="$FLORA_HOME/workspace/$(basename "$project")"
    if [[ -d "$dest/.git" ]]; then
      log "already cloned; fetching"
      git -C "$dest" fetch --all --prune
    else
      log "cloning $project"
      git clone ${branch:+-b "$branch"} \
        "https://$GERRIT_USER:$GERRIT_HTTP_PASSWORD@${BASE#https://}/a/$project" "$dest"
      # Remove the credentials from .git/config; they are supplied per-command.
      git -C "$dest" remote set-url origin "$BASE/$project"
    fi
    # The commit-msg hook generates the Change-Id trailer Gerrit matches
    # patchsets by. Without it, every amend opens a brand new change.
    hook="$dest/.git/hooks/commit-msg"
    if [[ ! -x "$hook" ]]; then
      curl -sS -u "$GERRIT_USER:$GERRIT_HTTP_PASSWORD" -o "$hook" "$BASE/tools/hooks/commit-msg" \
        && chmod +x "$hook" && ok "installed the commit-msg hook"
    fi
    git -C "$dest" config user.name  "Flora"
    git -C "$dest" config user.email "${FLORA_ADMIN_EMAIL%@*}+flora@${FLORA_DOMAIN}"
    ok "ready: $dest" ;;

  push)
    branch="${2:-}"
    topic="${3:-}"
    [[ -z "$branch" ]] && branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')"
    branch="${branch:-master}"
    git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
    git log -1 --format=%B | grep -q '^Change-Id:' \
      || die "HEAD has no Change-Id. The commit-msg hook is missing or the commit
     predates it. Fix with:  git commit --amend --no-edit"
    ref="refs/for/$branch"
    [[ -n "$topic" ]] && ref="$ref%topic=$topic"
    log "pushing HEAD to $ref"
    git push "https://$GERRIT_USER:$GERRIT_HTTP_PASSWORD@${BASE#https://}/a/$(basename "$(git rev-parse --show-toplevel)")" \
      "HEAD:$ref" 2>&1 | sed "s|$GERRIT_HTTP_PASSWORD|***|g" ;;

  list)
    q="${2:-owner:self status:open}"
    api GET "/changes/?q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$q")&o=CURRENT_REVISION" \
      | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print("%-8s %-14s %-9s %s" % (c["_number"], c["project"][:14], c["status"], c["subject"][:60]))' ;;

  show)
    id="${2:?usage: gerrit.sh show <change-id>}"
    api GET "/changes/$id/detail" | python3 -c '
import json, sys
c = json.load(sys.stdin)
print("#%s  %s" % (c["_number"], c["subject"]))
print("project %s   branch %s   status %s" % (c["project"], c["branch"], c["status"]))
for label, info in sorted(c.get("labels", {}).items()):
    votes = ", ".join("%s %+d" % (v.get("name","?"), v.get("value",0))
                      for v in info.get("all", []) if v.get("value"))
    print("  %-14s %s" % (label, votes or "-"))
print()
for m in c.get("messages", [])[-10:]:
    print("--- %s (%s)" % (m.get("author", {}).get("name", "?"), m.get("date", "")[:16]))
    print(m["message"].strip()[:1500])
    print()' ;;

  comments)
    id="${2:?usage: gerrit.sh comments <change-id>}"
    api GET "/changes/$id/comments" | python3 -c '
import json, sys
for path, items in json.load(sys.stdin).items():
    for c in items:
        print("%s:%s  %s: %s" % (path, c.get("line", "-"),
                                 c.get("author", {}).get("name", "?"),
                                 c["message"].strip().replace("\n", " ")[:300]))' ;;

  review)
    id="${2:?usage: gerrit.sh review <change-id> <message> [score]}"
    msg="${3:?a review needs a message}"
    score="${4:-0}"
    body="$(python3 -c '
import json, sys
print(json.dumps({"message": sys.argv[1], "labels": {"Code-Review": int(sys.argv[2])}}))' "$msg" "$score")"
    api POST "/changes/$id/revisions/current/review" "$body" >/dev/null
    ok "posted review on change $id (Code-Review $score)" ;;

  *) sed -n '2,20p' "$0" | sed 's/^# \?//' ;;
esac
