#!/usr/bin/env bash
# SessionStart hook — make sure the machine-wide bus monitor is running.
#
# Cheap and idempotent: the monitor takes a pid lockfile, so a second copy
# exits immediately. Detached with nohup so it outlives this session.
set -euo pipefail

CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Not configured: say so on stdout so the session knows to offer setup, rather
# than the plugin being installed and silently doing nothing forever. This is
# the only case where this hook speaks — a working bus stays quiet.
if [ ! -f "$CONFIG_DIR/config.env" ]; then
  echo "The Truxo dev bus plugin is installed but not configured yet, so this"
  echo "session will not be woken when teammates post. Offer to run the"
  echo "bus-setup skill — it takes one question and about ten seconds."
  exit 0
fi

[ -f "$CONFIG_DIR/pause" ] && exit 0        # paused

# Already alive?
if [ -f "$CONFIG_DIR/monitor.pid" ] && kill -0 "$(cat "$CONFIG_DIR/monitor.pid" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi

command -v node >/dev/null || { echo "truxo-bus: node not on PATH" >&2; exit 0; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "truxo-bus: node v$NODE_MAJOR found, but the bus monitor needs v22+" >&2
  exit 0
fi

nohup node "$HERE/bus-monitor.mjs" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
