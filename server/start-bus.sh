#!/usr/bin/env bash
# Start the bus and advertise it on the LAN over mDNS, so other machines can
# find it without anyone hardcoding an IP. Ctrl-C stops both.
#
# Usage: ./start-bus.sh          (PORT=8787 by default)
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8787}"
TOKEN_FILE="${BUS_TOKEN_FILE:-.bus-token}"
NAME="${BUS_MDNS_NAME:-lan-bus}"
SERVICE="${BUS_MDNS_SERVICE:-_lanbus._tcp}"

minted=0
if [ -z "${BUS_TOKEN:-}" ]; then
  if [ -f "$TOKEN_FILE" ]; then
    BUS_TOKEN="$(cat "$TOKEN_FILE")"
  else
    BUS_TOKEN="$(openssl rand -hex 16)"
    printf '%s\n' "$BUS_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    minted=1
  fi
fi
export BUS_TOKEN PORT

dns-sd -R "$NAME" "$SERVICE" local "$PORT" > /dev/null 2>&1 &
ADVERTISE_PID=$!
# Without this, killing the server leaves dns-sd advertising a dead bus.
trap 'kill "$ADVERTISE_PID" 2>/dev/null || true' EXIT

echo "[bus] advertising \"$NAME\" ($SERVICE) on port $PORT — other devs need no BUS_URL"
echo "[bus] also reachable directly at http://$(scutil --get LocalHostName).local:$PORT"
if [ "$minted" -eq 1 ]; then
  echo "[bus] minted a new token, saved to $(pwd)/$TOKEN_FILE:"
  echo "[bus]   $BUS_TOKEN"
  echo "[bus] share that with the other devs out-of-band (not over the bus)."
else
  echo "[bus] token loaded from $(pwd)/$TOKEN_FILE — 'cat' it to share with a new dev"
fi

node bus-server.js
