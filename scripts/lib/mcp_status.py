#!/usr/bin/env python3
"""Report which MCP tool servers are configured, and optionally probe them.

An MCP stdio server has no daemon and no port: it is started by the agent on
demand and exits when the agent is done. "Is it up?" therefore has no meaning;
"is it configured, and does it start and answer?" does, and the probe answers it
by performing the real handshake -- initialize, then tools/list -- exactly as an
agent would.
"""
import json
import os
import subprocess
import sys

HOME = os.environ["FLORA_HOME"]
sys.path.insert(0, os.path.join(HOME, "scripts", "lib"))

SHIPPED = os.path.join(HOME, "seed", "mcp", "servers.json")
LOCAL = os.path.join(HOME, "shared", "mcp", "servers.json")
OPENCODE_CFG = os.path.join(HOME, "state", "opencode", "config", "opencode.json")

C_OK, C_BAD, C_DIM, C_WARN, C_OFF = "\033[32m", "\033[31m", "\033[2m", "\033[33m", "\033[0m"
if not sys.stdout.isatty():
    C_OK = C_BAD = C_DIM = C_WARN = C_OFF = ""


def expand(v):
    if isinstance(v, str):
        return os.path.expandvars(v)
    if isinstance(v, list):
        return [expand(x) for x in v]
    if isinstance(v, dict):
        return {k: expand(x) for k, x in v.items()}
    return v


def registry():
    merged = {}
    for path in (SHIPPED, LOCAL):
        if os.path.exists(path):
            with open(path) as fh:
                merged.update(json.load(fh).get("servers", {}))
    return merged


def probe(name, spec, timeout=45):
    """Run the handshake an agent would, plus the server's declared probe call.

    Every request is written up front and stdin is closed, so the whole exchange
    is read with one timeout. Reading reply-by-reply would block forever against
    a server that never answers -- a Gerrit whose packets are dropped rather than
    refused, say -- and a status command that can hang is not a status command.

    Returns (ok, detail); ok is None when the server is not probeable.
    """
    if spec.get("type") == "remote":
        return None, "remote server; not probed"
    argv = [expand(spec["command"])] + expand(spec.get("args", []))
    env = dict(os.environ)
    env.update({k: str(v) for k, v in expand(spec.get("env", {})).items()})

    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "flora-mcp-status", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    pt = spec.get("probe_tool")
    if pt:
        requests.append({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                         "params": {"name": pt["name"], "arguments": pt.get("arguments", {})}})

    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, env=env)
    except OSError as exc:
        return False, "cannot start: %s" % exc

    try:
        out, err = p.communicate("\n".join(json.dumps(r) for r in requests) + "\n",
                                 timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        return False, "no reply within %ds -- the server started but is not answering" % timeout

    replies = {}
    for line in out.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") is not None:
            replies[msg["id"]] = msg

    if 1 not in replies:
        tail = (err or "").strip().splitlines()
        return False, "no response to initialize: %s" % (tail[-1] if tail else "server exited")
    info = replies[1].get("result", {}).get("serverInfo", {})
    tools = replies.get(2, {}).get("result", {}).get("tools", [])
    summary = "%s, %d tool%s" % (info.get("name", "?"), len(tools),
                                 "" if len(tools) == 1 else "s")

    # Starting is not working: initialize and tools/list never reach the system
    # behind the server, so a handshake-only probe stays green with completely
    # wrong credentials. A server names a read-only call to prove it end to end.
    if not pt:
        return True, summary + (" (handshake only -- no probe_tool declared,"
                                " so credentials are not exercised)")
    res = replies.get(3, {}).get("result", {})
    text = (res.get("content") or [{}])[0].get("text", "").strip().splitlines()
    first = text[0][:110] if text else ""
    if res.get("isError"):
        return False, "%s, but %s failed: %s" % (summary, pt["name"], first)
    return True, "%s; %s returned: %s" % (summary, pt["name"], first)


def main():
    do_probe = "--probe-flag" in sys.argv and sys.argv[sys.argv.index("--probe-flag") + 1] == "1"
    servers = registry()
    if not servers:
        print("  no servers defined in shared/mcp/servers.json")
        return 0

    configured = {}
    if os.path.exists(OPENCODE_CFG):
        with open(OPENCODE_CFG) as fh:
            configured = json.load(fh).get("mcp", {}) or {}

    problems = 0
    for name in sorted(servers):
        spec = servers[name]
        if not spec.get("enabled", True):
            print("  %s%-12s off%s      disabled in servers.json" % (C_DIM, name, C_OFF))
            continue
        missing = [v for v in spec.get("requires_env", []) if not os.environ.get(v, "").strip()]
        if missing:
            print("  %s%-12s waiting%s  needs %s in secrets/flora.env"
                  % (C_WARN, name, C_OFF, ", ".join(missing)))
            continue
        live = name in configured
        mark = "%sready%s  " % (C_OK, C_OFF) if live else "%sMISSING%s" % (C_BAD, C_OFF)
        detail = "in opencode.json" if live else "not in opencode.json -- run: bin/flora render"
        if not live:
            problems += 1
        print("  %-12s %s  %s" % (name, mark, detail))

        if do_probe:
            ok, note = probe(name, spec)
            if ok is None:
                print("               %s%s%s" % (C_DIM, note, C_OFF))
            elif ok:
                print("               %s✓ starts and answers%s -- %s" % (C_OK, C_OFF, note))
            else:
                print("               %s✗ %s%s" % (C_BAD, note, C_OFF))
                problems += 1

    if not do_probe:
        print("\n  A server is started by the agent on demand, not left running --")
        print("  nothing listens on a port. To actually start one and ask for its")
        print("  tools:  bin/flora mcp --probe")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
