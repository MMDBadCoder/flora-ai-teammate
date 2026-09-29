#!/usr/bin/env python3
"""Emit the nginx server blocks, one per service, honouring each service's mode.

Flora can be addressed two ways, and -- since a team rarely wants all or nothing --
the choice is per service:

    port      listen <public port>;  server_name _;      http://<ip>:7083
    subdomain listen <http port>;    server_name <host>;  http://chat.flora.com

FLORA_ROUTING sets the default; FLORA_ROUTE_<SERVICE> overrides it for one
service. Mixing is the point: Mattermost on a memorable subdomain while the
agent UIs stay on ports nobody has to add to a hosts file, say.

This replaced two near-identical templates that differed only in their listen
and server_name lines. Everything that actually matters -- the proxy headers,
the websocket plumbing, the auth includes -- was duplicated between them, which
is how they drift.

A NOTE ON WEBSOCKETS, which is the usual worry with name-based routing:
Mattermost's realtime channel is a WebSocket, and a WebSocket starts as an
ordinary HTTP request carrying a Host header and an Upgrade: websocket header.
nginx routes it by name exactly like any other request. What genuinely cannot be
name-routed is Mattermost's optional Calls plugin, whose WebRTC media is UDP and
never passes through nginx at all -- in either mode. See docs/01-architecture.md.
"""
import os
import sys

SERVICES = ["dashboard", "hermes", "opencode", "chat", "tokens"]
# Optional modules appear only when switched on.
if os.environ.get("FLORA_ENABLE_SCRIBE", "false") == "true":
    SERVICES.append("scribe")

PROXY_COMMON = """        proxy_http_version 1.1;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
"""


def env(name, default=""):
    return os.environ.get(name, default)


def mode_of(service):
    """port | subdomain, per service, defaulting to FLORA_ROUTING."""
    default = "subdomain" if env("FLORA_ROUTING", "ports") == "hosts" else "port"
    chosen = env("FLORA_ROUTE_%s" % service.upper(), "").strip().lower()
    if not chosen:
        return default
    if chosen in ("port", "ports"):
        return "port"
    if chosen in ("subdomain", "host", "hosts", "domain"):
        return "subdomain"
    sys.exit("nginx_render: FLORA_ROUTE_%s must be 'port' or 'subdomain', got %r"
             % (service.upper(), chosen))


def listener(service):
    """The listen/server_name pair for this service's mode."""
    key = service.upper()
    if mode_of(service) == "subdomain":
        return "    listen %s;\n    server_name %s;" % (
            env("FLORA_HTTP_PORT", "80"), env("FLORA_HOST_%s" % key))
    return "    listen %s;\n    server_name _;" % env("FLORA_PUBLIC_%s" % key)


def canonical_host(service):
    """host[:port] of the URL Flora advertises for this service."""
    url = env("FLORA_URL_%s" % service.upper())
    if not url:
        return ""
    rest = url.split("://", 1)[-1]
    return rest.split("/", 1)[0]


def canonical_redirect(service):
    """Send every other address to the one this service considers canonical.

    Mattermost builds its websocket URL from SiteURL, and Hermes validates the
    Host header against its configured public URL. Both therefore work on
    exactly one address and misbehave on any other -- Mattermost with a
    "check connection" banner while every page still loads, Hermes with a flat
    400. Reaching the same server by IP and by name is completely normal, so
    without this the second address is quietly broken.

    A redirect makes that visible and self-correcting instead: the other address
    still works, it just bounces to the canonical one first. `if` plus `return`
    is one of the uses nginx documents as safe.

    Set FLORA_CANONICAL_REDIRECT=false to serve every address as-is -- wanted
    when a NAT or proxy means different people legitimately arrive by different
    names and the advertised one is not reachable for all of them.
    """
    if env("FLORA_CANONICAL_REDIRECT", "true") != "true":
        return ""
    host = canonical_host(service)
    url = env("FLORA_URL_%s" % service.upper())
    if not host or not url:
        return ""
    return """
    # %s only works on one address; anything else lands here and is sent there.
    if ($http_host != "%s") {
        return 301 %s$request_uri;
    }
""" % (service.capitalize(), host, url)


def logs(service, home):
    name = {"chat": "chat", "tokens": "tokens"}.get(service, service)
    return ("    access_log %s/state/logs/nginx-%s.access.log flora;\n"
            "    error_log  %s/state/logs/nginx-%s.error.log warn;" % (home, name, home, name))


def block_dashboard(home):
    return """# ---------------------------------------------------------------- Dashboard --
server {
%s

%s

    root %s/state/dashboard;
    index index.html;

    # The dashboard has no backend of its own, so there is no backend password
    # for an account list to conflict with: it stays gated in every auth mode.
    include %s/state/nginx/dashboard-auth.conf;

    # Liveness for the container's healthcheck and any external monitor.
    # Outside the account list on purpose: it proves nginx is up, nothing more.
    location = /nginx-health {
        auth_basic off;
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\\n";
    }

    location = /health.json {
        add_header Cache-Control "no-store";
        default_type application/json;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}""" % (listener("dashboard"), logs("dashboard", home), home, home)


def block_agent(service, home, backend_port, note):
    return """# ---------------------------------------------------------------- %s --
server {
%s

%s

    client_max_body_size 256m;
    include %s/state/nginx/auth.conf;
%s
    location / {
        proxy_pass http://127.0.0.1:%s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $flora_connection_upgrade;
        proxy_set_header Host $http_host;
%s%s        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}""" % (service.capitalize(), listener(service), logs(service, home), home,
        canonical_redirect(service) if service == "hermes" else "",
        backend_port, PROXY_COMMON, note)


def block_chat(home, backend_port):
    return """# --------------------------------------------------------------- Mattermost --
# No HTTP basic auth: Mattermost has real accounts, and basic auth would break
# its desktop and mobile clients.
server {
%s

%s

    client_max_body_size 512m;
%s
    # The realtime channel. A WebSocket handshake is an ordinary HTTP request
    # with a Host header, so this is routed by name like everything else.
    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_pass http://127.0.0.1:%s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
%s        proxy_read_timeout 90s;
        proxy_buffers 256 16k;
    }

    location / {
        proxy_pass http://127.0.0.1:%s;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_buffers 256 16k;
    }
}""" % (listener("chat"), logs("chat", home), canonical_redirect("chat"),
        backend_port, PROXY_COMMON, backend_port)


def block_scribe(home, backend_port):
    return """# ------------------------------------------------------------------- Scribe --
# No HTTP basic auth: Scribe has accounts of its own, and uploads are large.
server {
%s

%s

    # Meeting audio. Upstream's own ceiling is MAX_UPLOAD_MB, which this must
    # not undercut, or nginx rejects the file before the app can say why.
    client_max_body_size 1024m;

    location / {
        proxy_pass http://127.0.0.1:%s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $flora_connection_upgrade;
        proxy_set_header Host $http_host;
%s        # Transcription is minutes of work behind one request, and live
        # microphone text streams back, so nothing here may be buffered.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}""" % (listener("scribe"), logs("scribe", home), backend_port, PROXY_COMMON)


def block_tokens(home, backend_port):
    return """# ---------------------------------------------------------------- TokenRing --
# Its dashboard has a password of its own and /v1 is authenticated by sk-ring
# keys, so no basic auth layer here either.
server {
%s

%s

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:%s;
        proxy_set_header Host $http_host;
%s        # Token streaming: never buffer, never time out mid-completion.
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}""" % (listener("tokens"), logs("tokens", home), backend_port, PROXY_COMMON)


def main():
    home = env("FLORA_HOME")
    if not home:
        sys.exit("nginx_render: FLORA_HOME is not set")

    blocks = [
        block_dashboard(home),
        block_agent("hermes", home, env("FLORA_PORT_HERMES", "9119"), ""),
        block_agent("opencode", home, env("FLORA_PORT_OPENCODE", "4096"),
                    "        # Server-sent events carry the agent's output.\n"),
        block_chat(home, env("FLORA_PORT_MATTERMOST", "8065")),
        block_tokens(home, env("FLORA_PORT_TOKENRING", "4000")),
    ]
    if "scribe" in SERVICES:
        blocks.append(block_scribe(home, env("FLORA_PORT_SCRIBE", "8000")))

    summary = "  ".join("%s=%s" % (s, mode_of(s)) for s in SERVICES)
    print("# Routing: %s\n" % summary)
    print("\n\n".join(blocks))


if __name__ == "__main__":
    main()
