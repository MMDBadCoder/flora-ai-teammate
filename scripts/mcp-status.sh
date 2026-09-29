#!/usr/bin/env bash
# What tool servers are configured, and do they actually work?
#
#   mcp-status.sh          configured or not, and why not
#   mcp-status.sh --probe  also start each one and ask it for its tools
#
# There is no "is it running" to check. An MCP stdio server is not a service: the
# agent spawns it as a child process when it needs a tool, talks JSON-RPC over
# stdin and stdout, and it exits afterwards. Nothing listens on a port and
# nothing appears in systemd. So the useful questions are whether it is
# configured, and whether it starts and answers -- which --probe does by running
# the real handshake against it.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

PROBE=0
[[ "${1:-}" == "--probe" ]] && PROBE=1

step "Tool servers (MCP)"

python3 "$FLORA_HOME/scripts/lib/mcp_status.py" ${PROBE:+--probe-flag $PROBE}
