#!/usr/bin/env bash
# Post an event to the bus. The message is the only required argument.
#
# Usage:
#   announce.sh "heads up, I'm restarting staging"
#   announce.sh -t PHASE-2 "auth endpoint merged"
#   announce.sh --type question "anyone know why CI is red?"
#   announce.sh --type deploy -t OPS-4 "shipped v1.2.0"
#
# Options:
#   -t, --ticket <id>   optional ticket/reference tag
#       --type <type>   event type, free-form (default: announce)
#   -h, --help          show this help
set -euo pipefail

ENV_FILE="${LAN_BUS_ENV_FILE:-${CLAUDE_PROJECT_DIR:-.}/.claude/dev.env}"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

source "$(dirname "${BASH_SOURCE[0]}")/bus-lib.sh"
resolve_bus_url || true

: "${BUS_URL:?no bus found — set BUS_URL or BUS_HOST in $ENV_FILE, or start the host with server/start-bus.sh so it advertises itself}"
: "${BUS_TOKEN:?set BUS_TOKEN in $ENV_FILE}"
: "${DEV_NAME:?set DEV_NAME in $ENV_FILE}"

TICKET=""
TYPE="announce"

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--ticket) TICKET="${2:?--ticket needs a value}"; shift 2 ;;
    --type)      TYPE="${2:?--type needs a value}"; shift 2 ;;
    -h|--help)   awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"; exit 0 ;;
    --)          shift; break ;;
    -*)          echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)           break ;;
  esac
done

MESSAGE="${1:?usage: announce.sh [-t TICKET] [--type TYPE] \"<message>\"}"

payload="$(jq -n \
  --arg dev "$DEV_NAME" \
  --arg type "$TYPE" \
  --arg message "$MESSAGE" \
  --arg ticket "$TICKET" \
  '{dev: $dev, type: $type, message: $message}
   + (if $ticket == "" then {} else {ticket: $ticket} end)')"

curl -sf -X POST "${BUS_URL}/events" \
  -H "X-Bus-Token: ${BUS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" | jq .
