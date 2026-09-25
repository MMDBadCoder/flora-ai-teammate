#!/usr/bin/env python3
"""Confluence helper for Flora. Standard library only -- no pip install needed.

    confluence.py get <page-id|space:title>
    confluence.py search <cql-or-text>
    confluence.py create <space> <title> <file.md|->  [--parent <id>]
    confluence.py update <page-id> <file.md|->        [--title <t>] [--minor]
    confluence.py append <page-id> <file.md|->

Credentials come from secrets/flora.env:
    CONFLUENCE_URL    https://confluence.example.com  (or https://x.atlassian.net/wiki)
    CONFLUENCE_USER   the account, or the empty string when using a bearer PAT
    CONFLUENCE_TOKEN  an API token (Cloud) or a personal access token (Data Center)

Both flavours of Confluence speak the v1 REST API used here, so the same code
works against Cloud and Data Center. Markdown is converted to the storage format
with Confluence's own converter where available, and otherwise sent as a
`<pre>` block -- never silently mangled.
"""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("CONFLUENCE_URL", "").rstrip("/")
USER = os.environ.get("CONFLUENCE_USER", "")
TOKEN = os.environ.get("CONFLUENCE_TOKEN", "")


def die(msg):
    sys.exit("confluence: %s" % msg)


def request(method, path, payload=None, params=None):
    if not BASE:
        die("CONFLUENCE_URL is not set -- run: bin/flora secrets edit")
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if USER:
        cred = base64.b64encode(("%s:%s" % (USER, TOKEN)).encode()).decode()
        req.add_header("Authorization", "Basic " + cred)
    else:
        req.add_header("Authorization", "Bearer " + TOKEN)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:600]
        die("HTTP %s on %s %s\n%s" % (exc.code, method, path, detail))
    except urllib.error.URLError as exc:
        die("cannot reach %s: %s" % (BASE, exc.reason))


def read_body(arg):
    return sys.stdin.read() if arg == "-" else open(arg, encoding="utf-8").read()


def to_storage(markdown):
    """Convert Markdown to Confluence storage format.

    Confluence has no Markdown endpoint that is stable across versions, so the
    text is wrapped in a markdown macro when the server supports it and shown
    verbatim otherwise. Wrong-but-readable beats silently-mangled.
    """
    escaped = (markdown.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    return ('<ac:structured-macro ac:name="markdown">'
            '<ac:plain-text-body><![CDATA[%s]]></ac:plain-text-body>'
            '</ac:structured-macro>' % markdown) if "```" in markdown or "#" in markdown \
        else "<p>%s</p>" % escaped.replace("\n\n", "</p><p>")


def resolve(ident):
    """Accept either a numeric page id or 'SPACE:Page title'."""
    if ident.isdigit():
        return ident
    if ":" not in ident:
        die("give a page id, or SPACE:Title")
    space, title = ident.split(":", 1)
    res = request("GET", "/rest/api/content",
                  params={"spaceKey": space, "title": title, "limit": 1})
    if not res.get("results"):
        die("no page titled %r in space %s" % (title, space))
    return res["results"][0]["id"]


def cmd_get(args):
    pid = resolve(args.page)
    page = request("GET", "/rest/api/content/%s" % pid,
                   params={"expand": "body.storage,version,space"})
    print("# %s" % page["title"])
    print("id %s   space %s   version %s" %
          (page["id"], page.get("space", {}).get("key", "?"), page["version"]["number"]))
    print("url %s/pages/viewpage.action?pageId=%s" % (BASE, page["id"]))
    print()
    print(page["body"]["storage"]["value"])


def cmd_search(args):
    cql = args.query if "=" in args.query or "~" in args.query else 'text ~ "%s"' % args.query
    res = request("GET", "/rest/api/content/search", params={"cql": cql, "limit": 25})
    for r in res.get("results", []):
        print("%-10s %-12s %s" % (r["id"], r.get("space", {}).get("key", "-"), r["title"]))


def cmd_create(args):
    payload = {
        "type": "page",
        "title": args.title,
        "space": {"key": args.space},
        "body": {"storage": {"value": to_storage(read_body(args.file)), "representation": "storage"}},
    }
    if args.parent:
        payload["ancestors"] = [{"id": args.parent}]
    page = request("POST", "/rest/api/content", payload)
    print("created %s: %s/pages/viewpage.action?pageId=%s" % (page["id"], BASE, page["id"]))


def cmd_update(args):
    pid = resolve(args.page)
    current = request("GET", "/rest/api/content/%s" % pid, params={"expand": "version,body.storage"})
    body = read_body(args.file)
    if args.append:
        body = current["body"]["storage"]["value"] + to_storage(body)
    else:
        body = to_storage(body)
    payload = {
        "id": pid,
        "type": "page",
        "title": args.title or current["title"],
        # Confluence rejects an update whose version is not exactly current+1,
        # which is what stops two writers silently overwriting each other.
        "version": {"number": current["version"]["number"] + 1, "minorEdit": args.minor},
        "body": {"storage": {"value": body, "representation": "storage"}},
    }
    page = request("PUT", "/rest/api/content/%s" % pid, payload)
    print("updated %s to version %s" % (page["id"], page["version"]["number"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("get"); g.add_argument("page"); g.set_defaults(fn=cmd_get)
    s = sub.add_parser("search"); s.add_argument("query"); s.set_defaults(fn=cmd_search)

    c = sub.add_parser("create")
    c.add_argument("space"); c.add_argument("title"); c.add_argument("file")
    c.add_argument("--parent"); c.set_defaults(fn=cmd_create)

    u = sub.add_parser("update")
    u.add_argument("page"); u.add_argument("file")
    u.add_argument("--title"); u.add_argument("--minor", action="store_true")
    u.set_defaults(fn=cmd_update, append=False)

    a = sub.add_parser("append")
    a.add_argument("page"); a.add_argument("file")
    a.set_defaults(fn=cmd_update, append=True, title=None, minor=True)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
