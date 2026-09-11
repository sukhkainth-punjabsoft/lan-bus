#!/usr/bin/env bash
# Post a message to the bus. Replaces announce.sh.
#
# Your DEV_NAME is sent with the message. The bus is unauthenticated for now, so
# that name IS your identity — it is what stops your own messages waking you,
# and it is trusted as-is. Keep it unique across the team.
#
# Usage:
#   bus-send.sh "restarting dev in 5"
#   bus-send.sh --type deploy -t TRUXO-123 "shipped the auth refactor"
#   bus-send.sh --file HANDOFF.md "handoff for the bus work — read before touching /api/v1/bus"
#
# --file attaches a long document (up to 256KB). It is stored separately and
# kept for 7 days: teammates see only your one-line message until they ask for
# the document, so a large paste never lands in someone's session uninvited.
set -euo pipefail

CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
[ -f "$CONFIG_DIR/config.env" ] && source "$CONFIG_DIR/config.env"

: "${BUS_URL:?set BUS_URL in $CONFIG_DIR/config.env}"
: "${DEV_NAME:?set DEV_NAME in $CONFIG_DIR/config.env}"

TICKET=""; TYPE="announce"; ROOM=""; FILE=""; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--ticket) TICKET="${2:?--ticket needs a value}"; shift 2 ;;
    --type)      TYPE="${2:?--type needs a value}"; shift 2 ;;
    --room)      ROOM="${2:?--room needs a value}"; shift 2 ;;
    --to)        TO="${2:?--to needs a name}"; shift 2 ;;
    --file)      FILE="${2:?--file needs a path}"; shift 2 ;;
    -h|--help)   awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 1 ;;
    *)           break ;;
  esac
done

MESSAGE="${1:?usage: bus-send.sh [--to NAME | --room R] [--type T] [-t TICKET] [--file F] \"<message>\"}"

[ -n "$TO" ] && [ -n "$ROOM" ] && { echo "use --to or --room, not both" >&2; exit 1; }

if [ -n "$TO" ]; then
  # One person's inbox instead of the whole repo. Their monitor always listens
  # on dm/<their-name>.
  ROOM="dm/$TO"
elif [ -z "$ROOM" ]; then
  # Default to this repo's room, derived from the git remote (not the folder).
  remote="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$remote" ] || { echo "no git remote and no --room/--to given" >&2; exit 1; }
  ROOM="$(printf '%s' "$remote" \
    | sed -E 's#^git@([^:]+):#https://\1/#' \
    | sed -E 's#^[a-z+]+://[^/]+/##' \
    | sed -E 's#\.git$##' \
    | tr '[:upper:]' '[:lower:]')"
fi

DOC=""
if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }
  DOC="$(cat "$FILE")"
fi

# --rawfile would reread the file; DOC is already in memory and jq handles the
# JSON escaping, so a document with quotes/newlines/UTF-8 survives intact.
payload="$(mktemp)"
jq -n --arg room "$ROOM" --arg type "$TYPE" --arg message "$MESSAGE" \
  --arg ticket "$TICKET" --arg dev "$DEV_NAME" --arg devName "${DEV_LABEL:-$DEV_NAME}" \
  --arg body "$DOC" \
  '{room: $room, type: $type, message: $message, dev: $dev, devName: $devName}
   + (if $ticket == "" then {} else {ticket: $ticket} end)
   + (if $body == "" then {} else {body: $body} end)' > "$payload"

out="$(mktemp)"
code="$(curl -s -o "$out" -w '%{http_code}' -X POST "${BUS_URL}/events" \
  -H "Content-Type: application/json" \
  --data-binary @"$payload")"
rm -f "$payload"

case "$code" in
  201) jq -r '"posted to " + .room + " as " + .dev
             + (if .bodyBytes then " (+ \(.bodyBytes / 1024 | floor)KB document)" else "" end)' "$out" ;;
  404) echo "bus not available at $BUS_URL (it exists on the dev host only)" >&2
       rm -f "$out"; exit 1 ;;
  *)   echo "bus post failed ($code): $(cat "$out")" >&2; rm -f "$out"; exit 1 ;;
esac
rm -f "$out"
