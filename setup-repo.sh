#!/usr/bin/env bash
# Wire the LAN bus into a repo. Idempotent — safe to re-run.
#
# Usage:
#   ./setup-repo.sh [path/to/repo] [options]
#
# With no path, wires the current directory. Creates ~/.claude/lan-bus.env on
# first run (shared by every repo), then adds the Stop hook to the target repo's
# .claude/settings.local.json, merging into whatever is already there.
#
# Options:
#   --token <secret>    shared bus token. Defaults to this checkout's
#                       server/.bus-token if present (i.e. you host the bus),
#                       otherwise you're prompted.
#   --dev-name <name>   your unique name on the bus (default: whoami)
#   --bus-host <host>   machine running the bus, e.g. some-mac.local
#                       (default: auto-discovered over mDNS)
#   --global            arm EVERY repo on this machine via
#                       ~/.claude/settings.json instead of one repo
#   -h, --help          show this help
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/hooks/bus-lib.sh"

REPO=""; TOKEN=""; DEV_NAME=""; HOST=""; GLOBAL=0
ENV_FILE="$HOME/.claude/lan-bus.env"
DEFAULT_POLL_MINUTES=30

while [ $# -gt 0 ]; do
  case "$1" in
    --token)     TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --dev-name)  DEV_NAME="${2:?--dev-name needs a value}"; shift 2 ;;
    --bus-host)  HOST="${2:?--bus-host needs a value}"; shift 2 ;;
    --global)    GLOBAL=1; shift ;;
    -h|--help)   awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)           REPO="$1"; shift ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

# ---------------------------------------------------------------- 1. shared config
if [ -f "$ENV_FILE" ]; then
  echo "==> config already exists, leaving untouched: $ENV_FILE"
else
  if [ -z "$TOKEN" ] && [ -f "$HERE/server/.bus-token" ]; then
    TOKEN="$(cat "$HERE/server/.bus-token")"
    echo "==> token: reusing $HERE/server/.bus-token (this machine hosts the bus)"
  fi
  if [ -z "$TOKEN" ]; then
    read -rp "shared bus token (printed by the host's start-bus.sh): " TOKEN
  fi
  [ -n "$TOKEN" ] || { echo "a token is required" >&2; exit 1; }

  [ -n "$DEV_NAME" ] || DEV_NAME="$(whoami)"

  if [ -z "$HOST" ]; then
    echo "==> looking for a bus on the LAN..."
    if found="$(discover_bus)"; then
      HOST="${found%%:*}"
      echo "==> found bus on $HOST"
    else
      echo "==> no bus advertised (is the host running server/start-bus.sh?)."
      echo "    Leaving BUS_HOST unset — the hooks will retry discovery each run."
    fi
  fi

  mkdir -p "$(dirname "$ENV_FILE")"
  {
    echo "BUS_TOKEN=$TOKEN"
    echo "DEV_NAME=$DEV_NAME"
    echo "POLL_MINUTES=$DEFAULT_POLL_MINUTES"
    [ -n "$HOST" ] && echo "BUS_HOST=$HOST"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "==> wrote $ENV_FILE (dev name: $DEV_NAME)"
fi

# ---------------------------------------------------------------- 2. wire the hook
POLL_MINUTES="$(sed -n 's/^POLL_MINUTES=//p' "$ENV_FILE" | head -1)"
POLL_MINUTES="${POLL_MINUTES:-$DEFAULT_POLL_MINUTES}"
# Must exceed the poll window, or Claude Code kills the poller before it exits.
TIMEOUT=$(( POLL_MINUTES * 60 + 60 ))
CMD="LAN_BUS_ENV_FILE=$ENV_FILE $HERE/hooks/bus-poll-rewake.sh"

if [ "$GLOBAL" -eq 1 ]; then
  SETTINGS="$HOME/.claude/settings.json"
  echo "==> scope: GLOBAL — every repo on this machine"
else
  [ -n "$REPO" ] || REPO="$PWD"
  [ -d "$REPO" ] || { echo "no such directory: $REPO" >&2; exit 1; }
  REPO="$(cd "$REPO" && pwd)"
  SETTINGS="$REPO/.claude/settings.local.json"
  echo "==> scope: $REPO"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e . "$SETTINGS" >/dev/null 2>&1 || { echo "$SETTINGS is not valid JSON — fix it first" >&2; exit 1; }

tmp="$(mktemp)"
if jq -e '(.hooks.Stop // []) | any((.hooks // []) | any((.command? // "") | contains("bus-poll-rewake.sh")))' "$SETTINGS" >/dev/null; then
  # Already wired: refresh command/timeout in place rather than adding a second.
  jq --arg cmd "$CMD" --argjson t "$TIMEOUT" '
    .hooks.Stop |= map(
      if (.hooks // []) | any((.command? // "") | contains("bus-poll-rewake.sh"))
      then .hooks |= map(
        if (.command? // "") | contains("bus-poll-rewake.sh")
        then .command = $cmd | .async = true | .asyncRewake = true | .timeout = $t
        else . end)
      else . end)
  ' "$SETTINGS" > "$tmp"
  echo "==> hook already present, refreshed command and timeout"
else
  jq --arg cmd "$CMD" --argjson t "$TIMEOUT" '
    .hooks //= {} |
    .hooks.Stop //= [] |
    .hooks.Stop += [{hooks: [{
      type: "command", command: $cmd,
      async: true, asyncRewake: true, timeout: $t
    }]}]
  ' "$SETTINGS" > "$tmp"
  echo "==> added Stop hook (timeout ${TIMEOUT}s for a ${POLL_MINUTES}min poll)"
fi
mv "$tmp" "$SETTINGS"
echo "==> updated $SETTINGS"

# Personal config shouldn't be committed.
if [ "$GLOBAL" -eq 0 ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$REPO" check-ignore -q .claude/settings.local.json 2>/dev/null; then
    printf '\n.claude/settings.local.json\n' >> "$REPO/.gitignore"
    echo "==> added .claude/settings.local.json to $REPO/.gitignore"
  fi
fi

# ---------------------------------------------------------------- 3. verify
(
  set +e
  source "$ENV_FILE"
  if ! resolve_bus_url; then
    echo "==> WARNING: no bus found. Start it on the host with server/start-bus.sh."
    exit 0
  fi
  if curl -sf -m 5 -H "X-Bus-Token: $BUS_TOKEN" "$BUS_URL/health" >/dev/null; then
    echo "==> verified: bus reachable at $BUS_URL"
  else
    echo "==> WARNING: $BUS_URL did not answer. Check the host is up and the token matches."
  fi
)

echo
echo "Done. Start 'claude' in that repo and give it one prompt — the Stop hook"
echo "only arms after a turn completes. To post an event from anywhere:"
echo "  LAN_BUS_ENV_FILE=$ENV_FILE $HERE/hooks/announce.sh \"your message\""
