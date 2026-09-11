#!/usr/bin/env bash
# Stop hook (async + asyncRewake). Fires after every Claude turn on this machine,
# then keeps polling the bus in the background for up to POLL_MINUTES. The moment
# a teammate's event shows up, it exits 2 — which is what wakes the session with
# a system reminder, even if the human at this machine hasn't typed anything.
set -euo pipefail

ENV_FILE="${LAN_BUS_ENV_FILE:-${CLAUDE_PROJECT_DIR:-.}/.claude/dev.env}"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# Resolved once here, not per poll — discovery costs a few seconds.
source "$(dirname "${BASH_SOURCE[0]}")/bus-lib.sh"
resolve_bus_url || true

: "${BUS_URL:?no bus found — set BUS_URL or BUS_HOST in $ENV_FILE, or start the host with server/start-bus.sh so it advertises itself}"
: "${BUS_TOKEN:?set BUS_TOKEN in $ENV_FILE}"
: "${DEV_NAME:?set DEV_NAME in $ENV_FILE, e.g. dev-a}"

CURSOR_FILE="$(dirname "$ENV_FILE")/.bus-cursor-${DEV_NAME}"
POLL_INTERVAL="${POLL_INTERVAL_SECONDS:-3}"
POLL_MINUTES="${POLL_MINUTES:-25}"
deadline=$(( $(date +%s) + POLL_MINUTES * 60 ))

cursor=0
[ -f "$CURSOR_FILE" ] && cursor="$(cat "$CURSOR_FILE")"

while [ "$(date +%s)" -lt "$deadline" ]; do
  resp="$(curl -sf --max-time 5 \
    -H "X-Bus-Token: ${BUS_TOKEN}" \
    "${BUS_URL}/events?since=${cursor}&excludeDev=${DEV_NAME}" || echo '[]')"

  count="$(echo "$resp" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$count" -gt 0 ]; then
    new_cursor="$(echo "$resp" | jq '[.[].id] | max')"
    echo "$new_cursor" > "$CURSOR_FILE"
    {
      echo "Teammate update via LAN bus:"
      echo "$resp" | jq -r '.[]
        | "- [\(.dev)]"
        + (if .type and .type != "announce" then " (\(.type))" else "" end)
        + " \(.message)"
        + (if .ticket then " (ticket \(.ticket))" else "" end)'
    } >&2
    exit 2
  fi

  sleep "$POLL_INTERVAL"
done

exit 0
