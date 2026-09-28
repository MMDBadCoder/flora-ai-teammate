#!/usr/bin/env python3
"""A Model Context Protocol server for Gerrit, over stdio.

WHY THIS EXISTS RATHER THAN AN OFF-THE-SHELF ONE. Flora's rule is to depend only
on other projects' official interfaces (docs/01-architecture.md). For Gerrit that
is its REST API, which is documented, stable and already what
scripts/integrations/gerrit.sh uses. The npm packages offering a Gerrit MCP
server are a 404, an unpublished name, and a single 0.0.1 release from an
unknown author -- not something to hand Gerrit credentials to on a team's
review system. This is ~300 lines of standard library against the documented API.

PROTOCOL. JSON-RPC 2.0, one JSON object per line on stdin/stdout, per the MCP
stdio transport. Implements initialize, notifications/initialized, ping,
tools/list and tools/call, which is the whole surface a tools-only server needs.
Anything written to stdout that is not a response corrupts the stream, so all
diagnostics go to stderr.

CREDENTIALS. GERRIT_URL, GERRIT_USER and GERRIT_HTTP_PASSWORD, the same three
Flora already stores in secrets/flora.env. The HTTP password comes from Gerrit ->
Settings -> HTTP Credentials, and is not the account password.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "flora-gerrit", "title": "Gerrit (Flora)", "version": "1.0.0"}

GERRIT_URL = os.environ.get("GERRIT_URL", "").rstrip("/")
GERRIT_USER = os.environ.get("GERRIT_USER", "")
GERRIT_PASSWORD = os.environ.get("GERRIT_HTTP_PASSWORD", "")
TIMEOUT = float(os.environ.get("GERRIT_TIMEOUT", "30"))


def log(msg):
    print("flora-gerrit: %s" % msg, file=sys.stderr, flush=True)


# --------------------------------------------------------------- Gerrit REST --

class GerritError(Exception):
    pass


def gerrit(method, path, payload=None, params=None):
    """Call an authenticated Gerrit endpoint and return the parsed JSON.

    Authenticated endpoints live under /a/. Gerrit prefixes every JSON response
    with )]}' to defeat naive cross-site script inclusion, so it is stripped.
    """
    if not GERRIT_URL:
        raise GerritError("GERRIT_URL is not set")
    url = "%s/a%s" % (GERRIT_URL, path)
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json; charset=UTF-8")
    if GERRIT_USER or GERRIT_PASSWORD:
        cred = base64.b64encode(("%s:%s" % (GERRIT_USER, GERRIT_PASSWORD)).encode()).decode()
        req.add_header("Authorization", "Basic " + cred)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        if exc.code in (401, 403):
            raise GerritError(
                "Gerrit refused the credentials (HTTP %s). GERRIT_HTTP_PASSWORD must be "
                "the HTTP password from Gerrit -> Settings -> HTTP Credentials, not the "
                "account password.\n%s" % (exc.code, detail))
        raise GerritError("HTTP %s from %s %s\n%s" % (exc.code, method, path, detail))
    except urllib.error.URLError as exc:
        raise GerritError("cannot reach %s: %s" % (GERRIT_URL, exc.reason))
    if body.startswith(")]}'"):
        body = body.split("\n", 1)[1] if "\n" in body else ""
    return json.loads(body) if body.strip() else {}


def text_of(path):
    """Fetch a plain-text (non-JSON) endpoint, e.g. a base64 patch."""
    url = "%s/a%s" % (GERRIT_URL, path)
    req = urllib.request.Request(url, method="GET")
    if GERRIT_USER or GERRIT_PASSWORD:
        cred = base64.b64encode(("%s:%s" % (GERRIT_USER, GERRIT_PASSWORD)).encode()).decode()
        req.add_header("Authorization", "Basic " + cred)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raise GerritError("HTTP %s fetching %s" % (exc.code, path))
    except urllib.error.URLError as exc:
        raise GerritError("cannot reach %s: %s" % (GERRIT_URL, exc.reason))


# ------------------------------------------------------------------- tools ----

def t_list_changes(args):
    query = args.get("query") or "status:open"
    limit = int(args.get("limit") or 25)
    res = gerrit("GET", "/changes/", params={"q": query, "n": limit, "o": "CURRENT_REVISION"})
    if not res:
        return "No changes match: %s" % query
    lines = ["%-8s %-20s %-9s %s" % ("NUMBER", "PROJECT", "STATUS", "SUBJECT")]
    for c in res:
        lines.append("%-8s %-20s %-9s %s" % (
            c.get("_number", "?"), (c.get("project") or "")[:20],
            c.get("status", ""), (c.get("subject") or "")[:70]))
    return "\n".join(lines)


def t_get_change(args):
    cid = str(args["change_id"])
    c = gerrit("GET", "/changes/%s/detail" % urllib.parse.quote(cid, safe=""))
    out = ["#%s  %s" % (c.get("_number"), c.get("subject")),
           "project %s   branch %s   status %s" % (c.get("project"), c.get("branch"), c.get("status")),
           "owner   %s" % (c.get("owner", {}).get("name", "?")),
           ""]
    for label, info in sorted((c.get("labels") or {}).items()):
        votes = ", ".join("%s %+d" % (v.get("name", "?"), v.get("value", 0))
                          for v in info.get("all", []) if v.get("value"))
        out.append("  %-16s %s" % (label, votes or "-"))
    out.append("")
    for m in (c.get("messages") or [])[-10:]:
        out.append("--- %s (%s)" % (m.get("author", {}).get("name", "?"), (m.get("date") or "")[:16]))
        out.append(m.get("message", "").strip()[:1500])
        out.append("")
    return "\n".join(out)


def t_get_diff(args):
    cid = urllib.parse.quote(str(args["change_id"]), safe="")
    raw = text_of("/changes/%s/revisions/current/patch" % cid)
    try:
        patch = base64.b64decode(raw).decode("utf-8", "replace")
    except Exception:
        patch = raw
    limit = int(args.get("max_chars") or 40000)
    if len(patch) > limit:
        patch = patch[:limit] + "\n\n[truncated at %d characters; raise max_chars for more]" % limit
    return patch


def t_get_comments(args):
    cid = urllib.parse.quote(str(args["change_id"]), safe="")
    res = gerrit("GET", "/changes/%s/comments" % cid)
    if not res:
        return "No inline comments on this change."
    lines = []
    for path, items in res.items():
        for c in items:
            lines.append("%s:%s  %s: %s" % (
                path, c.get("line", "-"), c.get("author", {}).get("name", "?"),
                (c.get("message") or "").strip().replace("\n", " ")[:300]))
    return "\n".join(lines)


def t_post_review(args):
    cid = urllib.parse.quote(str(args["change_id"]), safe="")
    message = args["message"]
    score = int(args.get("code_review") or 0)
    if score not in (-2, -1, 0, 1, 2):
        raise GerritError("code_review must be one of -2, -1, 0, +1, +2")
    payload = {"message": message, "labels": {"Code-Review": score}}
    gerrit("POST", "/changes/%s/revisions/current/review" % cid, payload)
    return "Posted review on change %s with Code-Review %+d" % (args["change_id"], score)


def t_list_projects(args):
    limit = int(args.get("limit") or 50)
    res = gerrit("GET", "/projects/", params={"n": limit})
    names = sorted(res.keys()) if isinstance(res, dict) else []
    return "\n".join(names) if names else "No projects visible to this account."


TOOLS = [
    {
        "name": "gerrit_list_changes",
        "title": "List Gerrit changes",
        "description": "Search Gerrit changes with a query. Use for 'what is open', "
                       "'what is waiting on me', 'find the change that touched X'. "
                       "Query syntax is Gerrit's own, e.g. 'status:open project:platform/api', "
                       "'owner:self', 'reviewer:self status:open'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Gerrit query. Default: status:open"},
                "limit": {"type": "integer", "description": "Maximum changes to return. Default 25."},
            },
        },
        "handler": t_list_changes,
    },
    {
        "name": "gerrit_get_change",
        "title": "Get a Gerrit change",
        "description": "Full detail for one change: subject, project, branch, status, "
                       "label votes and the last ten review messages. Takes the change "
                       "number or the Change-Id.",
        "inputSchema": {
            "type": "object",
            "properties": {"change_id": {"type": "string", "description": "Change number or Change-Id"}},
            "required": ["change_id"],
        },
        "handler": t_get_change,
    },
    {
        "name": "gerrit_get_diff",
        "title": "Get a change's diff",
        "description": "The unified diff of a change's current patchset. Use before "
                       "reviewing so the review is based on the actual code.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "change_id": {"type": "string", "description": "Change number or Change-Id"},
                "max_chars": {"type": "integer", "description": "Truncate beyond this. Default 40000."},
            },
            "required": ["change_id"],
        },
        "handler": t_get_diff,
    },
    {
        "name": "gerrit_get_comments",
        "title": "Get inline comments",
        "description": "Inline comments on a change, as file:line author: message. Use to "
                       "see what reviewers asked for before addressing feedback.",
        "inputSchema": {
            "type": "object",
            "properties": {"change_id": {"type": "string", "description": "Change number or Change-Id"}},
            "required": ["change_id"],
        },
        "handler": t_get_comments,
    },
    {
        "name": "gerrit_post_review",
        "title": "Post a review",
        "description": "Post a review message on a change, optionally with a Code-Review "
                       "vote. Use 0 to comment without voting. Do not +2 or review your own change.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "change_id": {"type": "string", "description": "Change number or Change-Id"},
                "message": {"type": "string", "description": "The review message"},
                "code_review": {"type": "integer",
                                "description": "Code-Review vote: -2, -1, 0, 1 or 2. Default 0."},
            },
            "required": ["change_id", "message"],
        },
        "handler": t_post_review,
    },
    {
        "name": "gerrit_list_projects",
        "title": "List Gerrit projects",
        "description": "Projects visible to this account. Use to find the exact project "
                       "name before cloning or querying.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "description": "Maximum to return. Default 50."}},
        },
        "handler": t_list_projects,
    },
]
BY_NAME = {t["name"]: t for t in TOOLS}


# ----------------------------------------------------------------- JSON-RPC --

def respond(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    rid = msg.get("id")
    params = msg.get("params") or {}

    # Notifications carry no id and must never be answered.
    if rid is None:
        return

    if method == "initialize":
        # Echo the client's version when we speak it, else offer ours.
        asked = params.get("protocolVersion")
        version = asked if asked == PROTOCOL_VERSION else PROTOCOL_VERSION
        respond(rid, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER_INFO,
            "instructions": "Gerrit code review for Flora. Read a change and its diff "
                            "before reviewing it. Never +2 or submit your own change.",
        })
    elif method == "ping":
        respond(rid, {})
    elif method == "tools/list":
        respond(rid, {"tools": [{k: v for k, v in t.items() if k != "handler"} for t in TOOLS]})
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = BY_NAME.get(name)
        if tool is None:
            respond(rid, error={"code": -32602, "message": "Unknown tool: %s" % name})
            return
        try:
            text = tool["handler"](args)
            respond(rid, {"content": [{"type": "text", "text": text}], "isError": False})
        except KeyError as exc:
            # A missing required argument is the caller's error, not a crash.
            respond(rid, {"content": [{"type": "text",
                                       "text": "Missing required argument: %s" % exc}],
                          "isError": True})
        except GerritError as exc:
            respond(rid, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
        except Exception as exc:  # never take the whole server down for one bad call
            log("unhandled error in %s: %r" % (name, exc))
            respond(rid, {"content": [{"type": "text", "text": "%s failed: %s" % (name, exc)}],
                          "isError": True})
    else:
        respond(rid, error={"code": -32601, "message": "Method not found: %s" % method})


def main():
    if not GERRIT_URL:
        log("GERRIT_URL is not set; tools will report an error when called")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            log("ignoring malformed line: %s" % exc)
            continue
        try:
            handle(msg)
        except Exception as exc:
            log("handler crashed: %r" % exc)
            if msg.get("id") is not None:
                respond(msg["id"], error={"code": -32603, "message": "Internal error: %s" % exc})


if __name__ == "__main__":
    main()
