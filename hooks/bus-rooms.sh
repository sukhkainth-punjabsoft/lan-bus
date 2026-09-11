#!/usr/bin/env bash
# Show, join or leave bus rooms.
#
# Rooms are how you control noise. By default you are in your repo's room (so
# everyone working on it can reach you) and your own dm/<name> room. Join a
# room per workstream when the repo room is too broad — a hotfix crew and a
# feature crew can then talk without waking each other.
#
# Usage:
#   bus-rooms.sh                     # list what you're listening on
#   bus-rooms.sh join truxo-3618     # add a room (takes effect within ~10s)
#   bus-rooms.sh leave truxo-3618    # stop listening
#
# Rooms are noise routing, NOT access control: the bus is unauthenticated, so
# anyone who knows a room's name can join it. Don't treat one as private.
set -euo pipefail

CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
ROOMS_FILE="$CONFIG_DIR/rooms.json"
[ -f "$CONFIG_DIR/config.env" ] && source "$CONFIG_DIR/config.env"

command -v jq >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }
mkdir -p "$CONFIG_DIR"
[ -f "$ROOMS_FILE" ] || echo '[]' > "$ROOMS_FILE"

# Same normalisation the server applies, so what you see is what it recorded.
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9._/-]+#-#g; s#-{2,}#-#g; s#^[-/.]+##; s#[-/.]+$##'
}

ACTION="${1:-list}"

case "$ACTION" in
  list)
    echo "listening as: ${DEV_NAME:-(not configured)}"
    echo
    echo "always on:"
    [ -n "${DEV_NAME:-}" ] && echo "  dm/$DEV_NAME          (messages sent to you with --to)"
    for r in $(printf '%s' "${BUS_EXTRA_ROOMS:-}" | tr ',' ' '); do
      [ -n "$r" ] && echo "  $r          (from BUS_EXTRA_ROOMS in config.env)"
    done
    echo
    echo "joined:"
    jq -r '.[] | "  " + .' "$ROOMS_FILE"
    ;;

  join)
    room="$(slug "${2:?usage: bus-rooms.sh join <room>}")"
    [ -n "$room" ] || { echo "that room name normalises to nothing" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg r "$room" '. + [$r] | unique' "$ROOMS_FILE" > "$tmp" && mv "$tmp" "$ROOMS_FILE"
    echo "joined $room — the monitor picks it up within ~10s"
    ;;

  leave)
    room="$(slug "${2:?usage: bus-rooms.sh leave <room>}")"
    tmp="$(mktemp)"
    jq --arg r "$room" 'map(select(. != $r))' "$ROOMS_FILE" > "$tmp" && mv "$tmp" "$ROOMS_FILE"
    # The monitor only ever adds rooms while running, so a leave needs a restart
    # to actually drop the subscription.
    if [ -f "$CONFIG_DIR/monitor.pid" ]; then
      kill "$(cat "$CONFIG_DIR/monitor.pid")" 2>/dev/null || true
      rm -f "$CONFIG_DIR/monitor.pid"
      "$(dirname "${BASH_SOURCE[0]}")/bus-monitor-start.sh" || true
    fi
    echo "left $room"
    ;;

  -h|--help)
    awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"
    ;;

  *)
    echo "unknown action: $ACTION (see --help)" >&2
    exit 1
    ;;
esac
