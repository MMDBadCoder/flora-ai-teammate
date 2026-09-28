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
SHIPPED = os.path.join(HOME, "seed", "mcp", "servers.json")
LOCAL = os.path.join(HOME, "shared", "mcp", "servers.json")


def load():
    """Servers that are enabled AND have every credential they declare.

    requires_env exists so a server can ship enabled and simply not appear until
    it is usable. Offering an agent a tool server whose credentials are blank
    means it discovers the problem by calling the tool and failing, which is a
    worse place to find out than here.
    """
    # The registry is the shipped list with the local one layered on top. A plain
    # copy would mean a server added in a new release never reaches an existing
    # install, because `flora seed` deliberately never overwrites a live file;
    # merging by key gets new servers there while keeping local edits and local
    # additions, which is what a registry wants and a free-text skill does not.
    merged = {}
    for path in (SHIPPED, LOCAL):
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            merged.update(json.load(fh).get("servers", {}))
    out = {}
    for name, spec in merged.items():
        if not spec.get("enabled", True):
            continue
        required = spec.get("requires_env", [])
        missing = [v for v in required if not os.environ.get(v, "").strip()]
        if missing:
            # Nothing configured at all is the normal case for an integration a
            # team does not use -- silent. Some but not all is a half-finished
            # setup that will look like the server simply never appeared, so say so.
            if len(missing) < len(required):
                sys.stderr.write(
                    "mcp: %r not configured -- set %s in secrets/flora.env to enable it\n"
                    % (name, ", ".join(missing)))
            continue
        out[name] = spec
    return out


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
    """`hermes mcp add` lines.

    The command is wrapped in env(1) with the server's variables spelled out,
    rather than trusting the child to inherit them from whatever process Hermes
    happens to spawn it from. Inheritance may well work; depending on it means a
    credential problem shows up as a tool failing at use time.
    """
    lines = []
    for name, s in servers.items():
        if s.get("type") == "remote":
            lines.append("hermes mcp add %s --url %s" % (shlex.quote(name), shlex.quote(expand(s["url"]))))
            continue
        parts = []
        env = expand(s.get("env", {}))
        if env:
            parts.append("env")
            parts.extend("%s=%s" % (k, v) for k, v in sorted(env.items()))
        parts.append(expand(s["command"]))
        parts.extend(expand(s.get("args", [])))
        cmd = " ".join(shlex.quote(x) for x in parts)
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
