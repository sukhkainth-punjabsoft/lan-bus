#!/usr/bin/env bash
# One-command setup for the Truxo dev bus.
#
# Writes your config, wires the hooks into a repo, starts the monitor, and
# verifies the whole path actually works before it claims success.
#
# Usage:
#   ./setup.sh                        # wire the current repo, point at dev.truxo.app
#   ./setup.sh --local                # ... point at a local apps/auth on :7003
#   ./setup.sh ~/code/other-repo      # ... wire a different repo
#   ./setup.sh --name manjodh            # ... override the bus name (default: whoami)
#   ./setup.sh --test                 # after setup, post as a fake teammate to prove wakes work
#   ./setup.sh --uninstall            # remove hooks from the repo and stop the monitor
#
# Safe to re-run: an existing config is left alone, and the hooks are MERGED
# into .claude/settings.local.json rather than overwriting it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
CONFIG="$CONFIG_DIR/config.env"

REPO=""; LOCAL=0; NAME=""; DO_TEST=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local)     LOCAL=1; shift ;;
    --name)      NAME="${2:?--name needs a value}"; shift 2 ;;
    --test)      DO_TEST=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   awk 'NR>1 && /^#/ {print substr($0,3); next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)           REPO="$1"; shift ;;
  esac
done

REPO="${REPO:-$PWD}"
SETTINGS="$REPO/.claude/settings.local.json"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31m✗\033[0m %s\n\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ uninstall
if [ "$UNINSTALL" = 1 ]; then
  echo
  if [ -f "$SETTINGS" ]; then
    tmp="$(mktemp)"
    # Strip only OUR hooks; anything else in the file is left untouched.
    jq '(.hooks.SessionStart, .hooks.Stop) |= (map(
          .hooks |= map(select((.command // "") | contains("lan-bus/hooks") | not))
        ) | map(select((.hooks | length) > 0)))
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end' \
      "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    # An empty object left behind is just noise.
    [ "$(jq -c . "$SETTINGS")" = "{}" ] && rm -f "$SETTINGS"
    ok "hooks removed from $REPO"
  fi
  if [ -f "$CONFIG_DIR/monitor.pid" ]; then
    kill "$(cat "$CONFIG_DIR/monitor.pid")" 2>/dev/null || true
    rm -f "$CONFIG_DIR/monitor.pid"
    ok "monitor stopped"
  fi
  say "config kept at $CONFIG (delete it yourself if you want it gone)"
  echo; exit 0
fi

echo
echo "  Truxo dev bus setup"
echo "  ───────────────────"

# ------------------------------------------------------------------ prereqs
command -v jq   >/dev/null || die "jq is required: brew install jq"
command -v node >/dev/null || die "node is required (v22+)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || die "node $NODE_MAJOR found, but v22+ is required (the monitor uses the built-in WebSocket)"
ok "jq and node v$NODE_MAJOR"

[ -d "$REPO/.git" ] || die "not a git repo: $REPO"
REMOTE="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
[ -n "$REMOTE" ] || die "no git remote 'origin' in $REPO — the room name comes from it"
ROOM="$(printf '%s' "$REMOTE" \
  | sed -E 's#^git@([^:]+):#https://\1/#' \
  | sed -E 's#^[a-z+]+://[^/]+/##' \
  | sed -E 's#\.git$##' \
  | tr '[:upper:]' '[:lower:]')"
ok "repo $REPO"
ok "room $ROOM"

# ------------------------------------------------------------------ config
if [ "$LOCAL" = 1 ]; then
  ORIGIN="http://localhost:7003"
else
  ORIGIN="https://dev.truxo.app"
fi
URL="$ORIGIN/api/v1/bus"

mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG" ]; then
  ok "config exists, leaving it alone: $CONFIG"
  # shellcheck disable=SC1090
  source "$CONFIG"
  URL="$BUS_URL"
else
  # whoami ends in a newline, which `tr -cs` counts as a complement character
  # and folds into a "-" — so an unnamed setup produced "sukh-", not "sukh", and
  # DMs to the clean name went to a room nobody listened on. Strip it first, then
  # trim stray separators so this matches the slug() in hooks/bus-rooms.sh.
  DEV_NAME="${NAME:-$(whoami)}"
  DEV_NAME="$(printf '%s' "$DEV_NAME" | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9._-' '-' | sed -E 's/^[-._]+//; s/[-._]+$//')"
  cat > "$CONFIG" <<EOF
# Truxo dev bus. Written by setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
BUS_URL=$URL
BUS_ORIGIN=$ORIGIN

# Your identity on the bus. MUST be unique across the team — two people sharing
# a name become one identity and silently stop seeing each other's messages.
DEV_NAME=$DEV_NAME
DEV_LABEL="$(git -C "$REPO" config user.name 2>/dev/null || echo "$DEV_NAME")"

# How long a finished turn waits for a teammate before giving up.
BUS_WAIT_MINUTES=30
EOF
  chmod 600 "$CONFIG"
  ok "config written: $CONFIG (you are '$DEV_NAME')"
fi

# ------------------------------------------------------------------ reachable?
if curl -sf -m 8 "$URL/rooms" >/dev/null 2>&1; then
  ok "bus reachable at $URL"
else
  warn "bus NOT reachable at $URL"
  if [ "$LOCAL" = 1 ]; then
    say "  start it with: cd apps/auth && npm run dev"
  else
    say "  it may not be deployed yet, or you're off the network"
  fi
  say "  setup continues — the monitor retries on its own"
fi

# ------------------------------------------------------------------ hooks
mkdir -p "$REPO/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

tmp="$(mktemp)"
jq --arg start "$HERE/hooks/bus-monitor-start.sh" \
   --arg wake  "$HERE/hooks/bus-wake.sh" '
  # Drop any previous bus hooks first so re-running never stacks duplicates,
  # then append ours. Every other hook in the file is preserved untouched.
  def strip: map(.hooks |= map(select((.command // "") | contains("lan-bus/hooks") | not)))
             | map(select((.hooks | length) > 0));
  .hooks //= {}
  | .hooks.SessionStart = ((.hooks.SessionStart // []) | strip)
      + [{hooks: [{type: "command", command: $start, timeout: 15}]}]
  | .hooks.Stop = ((.hooks.Stop // []) | strip)
      + [{hooks: [{type: "command", command: $wake,
                   async: true, asyncRewake: true, timeout: 1860}]}]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
ok "hooks wired into $SETTINGS"

# ------------------------------------------------------------------ monitor
# Register this repo's room up front so the monitor joins it immediately,
# instead of waiting for the first Stop hook to add it.
ROOMS_FILE="$CONFIG_DIR/rooms.json"
tmp="$(mktemp)"
if [ -f "$ROOMS_FILE" ]; then
  jq --arg r "$ROOM" '. + [$r] | unique' "$ROOMS_FILE" > "$tmp" 2>/dev/null \
    || jq -n --arg r "$ROOM" '[$r]' > "$tmp"
else
  jq -n --arg r "$ROOM" '[$r]' > "$tmp"
fi
mv "$tmp" "$ROOMS_FILE"

# Restart so it picks up a changed config/room set.
[ -f "$CONFIG_DIR/monitor.pid" ] && kill "$(cat "$CONFIG_DIR/monitor.pid")" 2>/dev/null || true
rm -f "$CONFIG_DIR/monitor.pid"
"$HERE/hooks/bus-monitor-start.sh" || true

joined=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if grep -q "listening as" "$CONFIG_DIR/monitor.log" 2>/dev/null; then joined=1; break; fi
done
if [ "$joined" = 1 ]; then
  ok "$(grep 'listening as' "$CONFIG_DIR/monitor.log" | tail -1 | sed 's/^[^ ]* //')"
else
  warn "monitor hasn't joined yet — see $CONFIG_DIR/monitor.log"
fi

# ------------------------------------------------------------------ test
if [ "$DO_TEST" = 1 ]; then
  echo
  echo "  Test"
  echo "  ────"
  FAKE="$(mktemp -d)"
  # A second identity, because the bus deliberately never wakes you with your
  # own messages — testing with your own name would prove nothing.
  sed 's/^DEV_NAME=.*/DEV_NAME=test-teammate/; s/^DEV_LABEL=.*/DEV_LABEL="Test Teammate"/' \
    "$CONFIG" > "$FAKE/config.env"
  ( cd "$REPO" && TRUXO_BUS_CONFIG_DIR="$FAKE" "$HERE/hooks/bus-send.sh" \
      --type deploy -t TRUXO-000 "setup.sh test — if you can read this, the bus works" ) \
    && ok "posted as test-teammate" || warn "post failed"
  sleep 2
  if [ -s "$CONFIG_DIR/spool.jsonl" ]; then
    ok "received: $(tail -1 "$CONFIG_DIR/spool.jsonl" | jq -r '"\(.devName) in \(.room)"')"
    say "it is queued — your session will surface it when the current turn ends"
  else
    warn "nothing arrived; check $CONFIG_DIR/monitor.log"
  fi
  rm -rf "$FAKE"
fi

echo
echo "  Done. Restart Claude Code so the hooks load."
echo
echo "  post      $HERE/hooks/bus-send.sh \"your message\""
echo "  attach    $HERE/hooks/bus-send.sh --file NOTES.md \"summary line\""
echo "  read      ask Claude to run the bus-inbox skill"
echo "  pause     touch $CONFIG_DIR/pause"
echo "  remove    $HERE/setup.sh --uninstall"
echo
