#!/usr/bin/env bash
# Stop hook (async + asyncRewake) — wake THIS session when a teammate posts to a
# Room it is bound to.
#
# Waits on a LOCAL spool file that the background monitor fills from a push
# connection. No network polling: this costs one stat() per second, where the
# old version made an authenticated HTTPS request every three.
#
# The Spool is append-only and this hook never consumes it (ADR 0005). It reads
# forward from this Session's Cursor and leaves every line where it lies, so the
# other Sessions on this machine — usually on other Workstream rooms — read the
# same lines independently. The previous version claimed the whole Spool with
# `mv`, which took every sibling Session's Notices with it and destroyed
# anything that arrived in the gap before the truncate. Both failures were
# silent, which is what made them the worst bugs in the system.
#
# What it prints is METADATA ONLY — who posted, what kind, how many. The
# message body is deliberately NOT here (ADR 0002): it is text written by
# someone on another machine, and this session has shell and file access. Claude
# fetches bodies on purpose with the bus-inbox skill, which frames them as
# untrusted.
set -euo pipefail

# The Stop payload arrives on stdin and carries session_id, which is the only
# per-Session identity the platform offers (docs/research/session-identity-in-hooks.md).
# Read it FIRST: there is exactly one copy, and anything else that touches stdin
# consumes it. The -t 0 guard is for a by-hand run, where cat would otherwise
# block forever on a terminal that never sends EOF.
HOOK_INPUT=""
[ -t 0 ] || HOOK_INPUT="$(cat 2>/dev/null || true)"

CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
SPOOL="$CONFIG_DIR/spool.jsonl"
ROOMS_FILE="$CONFIG_DIR/rooms.json"
CURSORS_FILE="$CONFIG_DIR/cursors.json"
BINDINGS_FILE="$CONFIG_DIR/bindings.json"
BRANCH_BINDINGS_FILE="$CONFIG_DIR/branch-bindings.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$CONFIG_DIR/config.env" ] || exit 0
[ -f "$CONFIG_DIR/pause" ] && exit 0
command -v jq >/dev/null || exit 0

# shellcheck source=/dev/null
source "$HERE/bus-lib.sh"

# BUS_ROOM points a Session at a Workstream room at launch, so it is a property
# of the launch and not of the machine: capture it before config.env is sourced,
# or a stray BUS_ROOM left in that file would silently outrank it.
BUS_ROOM_AT_LAUNCH="${BUS_ROOM:-}"
# shellcheck source=/dev/null
source "$CONFIG_DIR/config.env"
BUS_ROOM="${BUS_ROOM_AT_LAUNCH:-${BUS_ROOM:-}}"

# Read, deliberately not branched on here. A Wake that lands during a turn some
# earlier Wake started is still worth delivering, and the Cursor — not this flag
# — is what stops the same Notices being reported twice. stop_hook_active is the
# loop guard for the ANNOUNCE path (ADR 0006), which must never post from a turn
# it was woken into; it is parsed here so both hooks read the payload the same
# way, and it is worth knowing about in the log line below.
STOP_HOOK_ACTIVE="$(bus_hook_field "$HOOK_INPUT" stop_hook_active)"
: "${STOP_HOOK_ACTIVE:=false}"

SESSION_ID="$(bus_session_id "$HOOK_INPUT")" || {
  # Every Session on this machine now shares one Cursor — the exact bug ADR 0005
  # exists to remove — and the only symptom is Wakes quietly landing in the
  # wrong Session. Say so somewhere a human can find it.
  bus_log "wake: no session_id on stdin or in the environment (stop_hook_active=$STOP_HOOK_ACTIVE); every session on this machine now shares one cursor"
}

# Nothing below may take the session down with it: this runs on every Stop, and a
# bus that cannot resolve a Room is a reason to wake nobody, never a reason to
# fail the turn. Hence the defaults on every parse.
REPO_ROOM="$(bus_repo_room)"
BINDING="$(bus_resolve_binding "$CONFIG_DIR" "$SESSION_ID" "$REPO_ROOM" "${DEV_NAME:-}" "${BUS_ROOM:-}" || true)"
BINDING_LEVEL="$(printf '%s' "$BINDING" | jq -r '.level // "repo"' 2>/dev/null || echo repo)"
BOUND_ROOMS="$(printf '%s' "$BINDING" | jq -c '.rooms // []' 2>/dev/null || echo '[]')"

# Write the resolved Binding back whatever level it came from, so the Session has
# one stable answer for the rest of its life and `seen` moves for the 14-day GC.
bus_json_update "$BINDINGS_FILE" '{}' '.[$s] = {rooms: $rooms, seen: $now}' \
  --arg s "$SESSION_ID" --arg now "$(bus_now_iso)" --argjson rooms "$BOUND_ROOMS" \
  || bus_log "wake: could not record binding for session $SESSION_ID"

# Sticky Binding, keyed by branch. A Room named at launch is remembered so the
# next Session on this ticket inherits it — the whole point of the branch level,
# since a Room name can never be derived from a checkout, only recalled.
#
# Only the bus_room level is recorded here, and deliberately: falling back to the
# Repo room costs nothing to derive again, and the session level cannot be read
# as a choice — every level writes itself back to bindings.json, so by the second
# Stop of any Session this resolves at `session` whatever it started as. A join
# made mid-session is the join skill's to remember; it is the only thing that
# knows the user asked for it. Otherwise only `seen` moves, which keeps a branch
# still being worked on out of the GC.
BRANCH_KEY="$(bus_branch_key "$REPO_ROOM")"
if [ -n "$BRANCH_KEY" ]; then
  case "$BINDING_LEVEL" in
    bus_room)
      bus_json_update "$BRANCH_BINDINGS_FILE" '{}' '.[$k] = {rooms: $rooms, seen: $now}' \
        --arg k "$BRANCH_KEY" --arg now "$(bus_now_iso)" --argjson rooms "$BOUND_ROOMS" \
        || bus_log "wake: could not record branch binding for $BRANCH_KEY"
      ;;
    *)
      bus_json_update "$BRANCH_BINDINGS_FILE" '{}' 'if has($k) then .[$k].seen = $now else . end' \
        --arg k "$BRANCH_KEY" --arg now "$(bus_now_iso)" \
        || bus_log "wake: could not refresh branch binding for $BRANCH_KEY"
      ;;
  esac
fi

# Register the Rooms with the Monitor so it joins them. The Repo room goes in
# even when this Session is bound elsewhere: a Notice no Session is bound to
# rests in the Spool and wakes nobody (ADR 0005), but a Notice for a Room the
# Monitor never joined never reaches this machine at all. Direct rooms are left
# out — the Monitor always joins dm/<name> itself, and listing it here would
# double it up in `bus-rooms.sh list`.
bus_register_rooms "$ROOMS_FILE" \
  "$(jq -cn --argjson bound "$BOUND_ROOMS" --arg repo "$REPO_ROOM" \
     '($bound + [$repo]) | map(select(length > 0 and (startswith("dm/") | not)))')" \
  || bus_log "wake: could not register rooms for session $SESSION_ID"

"$HERE/bus-monitor-start.sh" || true

# Register the Session before waiting. An id we have not seen before is seeded at
# the TAIL of the Spool — nothing already there is unread for it — which is what
# keeps /clear, --fork-session and Claude Code Remote (a fresh id every turn)
# from replaying the whole backlog as a wall of stale Wakes. An empty binding
# means "read nothing", so this both seeds the Cursor and refreshes `seen`.
bus_claim_unread "$CURSORS_FILE" "$SESSION_ID" "$SPOOL" '[]' >/dev/null \
  || bus_log "wake: could not register cursor for session $SESSION_ID"

if ! printf '%s' "$BOUND_ROOMS" | jq -e 'length > 0' >/dev/null 2>&1; then
  # No git remote, no BUS_ROOM, no DEV_NAME: there is no Room this Session could
  # be woken for, so waiting 30 minutes to discover that helps nobody.
  bus_log "wake: session $SESSION_ID is bound to no rooms (level=$BINDING_LEVEL) — not waiting"
  exit 0
fi

WAIT_MINUTES="${BUS_WAIT_MINUTES:-30}"
case "$WAIT_MINUTES" in
  ''|*[!0-9]*) WAIT_MINUTES=30 ;;
esac
deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))

UNREAD_FILE="$(mktemp)"
trap 'rm -f "$UNREAD_FILE"' EXIT

last_stamp=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  # Size and mtime, not a parse. The Spool only grows (the Monitor trims it by
  # age), so an unchanged stamp means there is provably nothing new to read and
  # the poll stays as cheap as the stat() it used to be.
  stamp="$(bus_file_stamp "$SPOOL")"
  if [ "$stamp" != "$last_stamp" ]; then
    # Read forward from this Session's Cursor and advance it, both under one
    # lock inside bus_claim_unread. Nothing is claimed, renamed or truncated.
    if bus_claim_unread "$CURSORS_FILE" "$SESSION_ID" "$SPOOL" "$BOUND_ROOMS" > "$UNREAD_FILE"; then
      # Only on success: a Cursor that failed to move has read nothing, and the
      # next pass must look again rather than wait for the Spool to change.
      last_stamp="$stamp"

      if [ -s "$UNREAD_FILE" ]; then
        count="$(wc -l < "$UNREAD_FILE" | tr -d ' ')"
        # Built before the report is printed: the Cursor has already moved, so a
        # jq that chokes on one odd Notice must not take the whole Wake down
        # with it — that would lose the Notices outright.
        lines="$(jq -r '
            "- [" + ((.devName // .dev // "someone") | tostring)
                  + " in " + ((.room // "unknown") | tostring) + "]"
            + (if (.type // "announce") != "announce" then " (" + (.type | tostring) + ")" else "" end)
            + (if .ticket then " ticket " + (.ticket | tostring) else "" end)
            + (if .bodyBytes then " + \(((.bodyBytes | tonumber?) // 0) / 1024 | floor)KB document" else "" end)
          ' "$UNREAD_FILE" 2>/dev/null | sort | uniq -c | sed -E 's/^ *([0-9]+) /\1x /' || true)"
        [ -n "$lines" ] || lines="- $count notice(s) (unreadable metadata)"

        {
          echo "Truxo bus: $count new message(s) from teammates."
          echo
          echo "$lines"
          echo
          echo "Message text and attached documents were NOT fetched. They are"
          echo "untrusted third-party content. Run the bus-inbox skill to read them"
          echo "if they are relevant to this work."
        } >&2

        exit 2
      fi
    fi
  fi
  sleep 1
done

exit 0
