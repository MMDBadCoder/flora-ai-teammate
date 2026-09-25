#!/usr/bin/env python3
"""Turn shared/mcp/servers.json into per-agent MCP configuration.

One file describes every tool server Flora can reach; each agent gets it in
its own dialect. Adding a server therefore means editing one file and running
`bin/flora sync`, not remembering two formats.

Usage:
    mcp_render.py opencode   # prints the JSON object for opencode.json "mcp"
    mcp_render.py hermes     # prints one shell-quoted `hermes mcp add` per line
"""
import json
import os
import shlex
import sys

HOME = os.environ.get("FLORA_HOME", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(HOME, "shared", "mcp", "servers.json")


def load():
    if not os.path.exists(SRC):
        return {}
    with open(SRC) as fh:
        data = json.load(fh)
    return {k: v for k, v in data.get("servers", {}).items() if v.get("enabled", True)}


def expand(value):
    """Expand ${VAR} against the environment, leaving unknown names intact."""
    if isinstance(value, str):
        return os.path.expandvars(value)
    if isinstance(value, list):
        return [expand(v) for v in value]
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    return value


def for_opencode(servers):
    out = {}
    for name, s in servers.items():
        if s.get("type") == "remote":
            entry = {"type": "remote", "url": expand(s["url"]), "enabled": True}
            if s.get("headers"):
                entry["headers"] = expand(s["headers"])
        else:
            entry = {
                "type": "local",
                "command": [expand(s["command"])] + expand(s.get("args", [])),
                "enabled": True,
            }
            if s.get("env"):
                entry["environment"] = expand(s["env"])
        out[name] = entry
    return out


def for_hermes(servers):
    lines = []
    for name, s in servers.items():
        if s.get("type") == "remote":
            lines.append("hermes mcp add %s --url %s" % (shlex.quote(name), shlex.quote(expand(s["url"]))))
        else:
            cmd = " ".join([expand(s["command"])] + expand(s.get("args", [])))
            lines.append("hermes mcp add %s --command %s" % (shlex.quote(name), shlex.quote(cmd)))
    return "\n".join(lines)


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "opencode"
    servers = load()
    if target == "opencode":
        print(json.dumps(for_opencode(servers), indent=4))
    elif target == "hermes":
        print(for_hermes(servers))
    else:
        sys.exit("unknown target: %s" % target)


if __name__ == "__main__":
    main()
