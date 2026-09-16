#!/usr/bin/env bash
# Shared helpers for the LAN bus hooks. Meant to be sourced, not run.
#
# Two eras live in this file. discover_bus/resolve_bus_url belong to the original
# LAN bus and are still sourced by announce.sh and bus-poll-rewake.sh — leave
# them as they are. Everything prefixed bus_ is the per-Session machinery from
# ADR 0005 (cursors are per-Session, the Spool is never consumed) and is shared
# by bus-wake.sh, the announce hook and the join skill.
#
# Nothing here runs at source time and nothing here sets a variable in the
# caller's shell: sourcing this file gets you functions and nothing else. Every
# caller runs `set -euo pipefail`, so every expansion below is defaulted.

# Browse mDNS for a bus advertised on the LAN and echo "host:port".
# Costs BUS_MDNS_TIMEOUT seconds (default 3) because dns-sd streams and
# never exits on its own, so it has to be backgrounded and killed.
discover_bus() {
  local name="${BUS_MDNS_NAME:-lan-bus}"
  local service="${BUS_MDNS_SERVICE:-_lanbus._tcp}"
  local log pid hostport
  log="$(mktemp)"

  dns-sd -L "$name" "$service" local > "$log" 2>&1 &
  pid=$!
  sleep "${BUS_MDNS_TIMEOUT:-3}"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # "...can be reached at some-mac.local.:8787" -> "some-mac.local:8787"
  hostport="$(grep -oE '[A-Za-z0-9.-]+\.local\.?:[0-9]+' "$log" | head -1 | sed 's/\.local\.:/.local:/')"
  rm -f "$log"

  [ -n "$hostport" ] || return 1
  printf '%s\n' "$hostport"
}

# Set BUS_URL, in priority order:
#   1. BUS_URL already set        — explicit wins, costs nothing
#   2. BUS_HOST (+ BUS_PORT)      — hostname only, e.g. some-mac.local
#   3. mDNS discovery             — zero config, costs ~3s
# Returns 1 if none of the three produced a URL.
resolve_bus_url() {
  [ -n "${BUS_URL:-}" ] && return 0

  if [ -n "${BUS_HOST:-}" ]; then
    BUS_URL="http://${BUS_HOST}:${BUS_PORT:-8787}"
    return 0
  fi

  local found
  found="$(discover_bus)" || return 1
  BUS_URL="http://${found}"
}

# ============================================================ ADR 0005 helpers

# ------------------------------------------------------------------- basics

# Where every file on this machine lives. One definition, because a second one
# that drifts is a bus quietly reading the wrong Spool.
bus_config_dir() {
  printf '%s' "${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
}

bus_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One line into hooks.log, alongside the monitor's own log. Never fails the
# caller: a Stop hook that dies because it could not append a log line is a
# worse outcome than the missing line.
bus_log() {
  printf '%s %s\n' "$(bus_now_iso)" "$*" >> "$(bus_config_dir)/hooks.log" 2>/dev/null || true
}

# Size and mtime of a file, as one opaque string that changes whenever the file
# does. A poll compares this instead of parsing the Spool every second, which is
# what keeps a Wake at the cost of a stat().
#
# macOS stat and GNU stat take different flags and neither tolerates the other's,
# so try BSD first — and if neither works, return something that changes every
# second. That degrades to parsing on every poll, which is merely expensive; a
# constant would be a stamp that never changes again and a Session that never
# wakes again, which is the failure this whole file is about.
bus_file_stamp() {
  local f="${1:-}"
  [ -e "$f" ] || { printf 'absent'; return 0; }
  stat -f '%z:%m' "$f" 2>/dev/null \
    || stat -c '%s:%Y' "$f" 2>/dev/null \
    || printf 'nostat:%s' "$(date +%s)"
}

# --------------------------------------------------------------- hook payload

# One field off a hook's stdin JSON. Empty when the payload is absent, the field
# is absent, or the JSON does not parse — every field except session_id and
# hook_event_name is optional in practice, so callers must tolerate empty.
#
# Booleans come back as the strings "true"/"false" rather than through jq's
# `//`, which treats false as absent and would turn stop_hook_active=false into
# an empty string indistinguishable from a client that never sent it.
bus_hook_field() {
  [ -n "${1:-}" ] || return 0
  printf '%s' "$1" | jq -r --arg f "${2:-}" '
    if (type == "object") and (.[$f] != null)
    then (.[$f] | if type == "string" then . else tojson end)
    else empty end' 2>/dev/null || true
}

# The Session this hook belongs to (ADR 0005). Prints the id, and returns 1 when
# it had to fall back to the shared pseudo-id so the caller can say so out loud.
#
#   CLAUDE_CODE_REMOTE_SESSION_ID  Claude Code Remote mints a fresh session_id
#                                  every turn; this one survives them.
#   stdin session_id               the documented contract, verified present on
#                                  Stop (docs/research/session-identity-in-hooks.md).
#   CLAUDE_CODE_SESSION_ID         real but undocumented — for a helper spawned
#                                  by a hook, which inherits the environment but
#                                  not the payload.
#   shared-no-session-id           degraded: every Session on the machine shares
#                                  one Cursor, i.e. the bug ADR 0005 exists to
#                                  fix. Still better than a Stop hook that dies,
#                                  and the caller logs it.
bus_session_id() {
  local raw="${CLAUDE_CODE_REMOTE_SESSION_ID:-}"
  [ -n "$raw" ] || raw="$(bus_hook_field "${1:-}" session_id)"
  [ -n "$raw" ] || raw="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$raw" ]; then
    printf 'shared-no-session-id'
    return 1
  fi
  # Ids are UUIDs today, but nothing in the hook protocol promises that and this
  # value arrives from outside the hook. It becomes a JSON key and part of a
  # lock path, so scrub it and bound its length.
  printf '%s' "$raw" | LC_ALL=C sed 's#[^A-Za-z0-9._-]#_#g' | cut -c1-128
}

# ------------------------------------------------------------------- locking
#
# Several Sessions Stop at once — that is the premise of the whole system — so
# every read-modify-write of a shared JSON file is serialised. mkdir is the lock
# because it is atomic everywhere and macOS ships no flock(1).
bus_lock() {
  local dir="${1:?bus_lock needs a lock path}" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    # A hook killed mid-write leaves the directory behind, and a lock nobody
    # holds would block every Stop on this machine from then on. These writes
    # take milliseconds, so anything a minute old is a corpse.
    if [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null || true)" ]; then
      rmdir "$dir" 2>/dev/null || true
      continue
    fi
    [ "$waited" -lt 50 ] || return 1
    waited=$((waited + 1))
    sleep 0.1
  done
}

bus_unlock() { rmdir "${1:-}" 2>/dev/null || true; }

# Locked read-modify-write of a JSON file.
#   bus_json_update <file> <empty> <jq filter> [jq args...]
# <empty> is the document the file starts as when it is missing — "{}" or "[]".
# The result is renamed into place, so a concurrent reader never sees half of it.
bus_json_update() {
  local file="${1:?bus_json_update needs a file}" empty="${2:?bus_json_update needs an empty document}"
  shift 2
  local filter="${1:?bus_json_update needs a filter}"
  shift
  local lock="$file.lock" current tmp rc=0

  bus_lock "$lock" || return 1
  current="$(cat "$file" 2>/dev/null || true)"
  [ -n "$current" ] || current="$empty"

  tmp="$(mktemp "$file.XXXXXX")" || { bus_unlock "$lock"; return 1; }
  if ! printf '%s' "$current" | jq "$@" "$filter" > "$tmp" 2>/dev/null; then
    # What is on disk is not JSON this filter can use. Rebuild from empty rather
    # than leaving a corrupt document to fail every write from here on.
    printf '%s' "$empty" | jq "$@" "$filter" > "$tmp" 2>/dev/null || rc=1
  fi
  if [ "$rc" = 0 ] && [ -s "$tmp" ]; then mv "$tmp" "$file"; else rm -f "$tmp"; rc=1; fi

  bus_unlock "$lock"
  return "$rc"
}

# --------------------------------------------------------------------- rooms

# The Rooms in a JSON array, normalised the way the server normalises every Room
# name it is handed. A Binding has to hold the normalised form or it will never
# match the room on an incoming Notice. Same rules as bus-rooms.sh slug() —
# change both together.
_bus_slug_filter() {
  printf '%s' 'map(select(type == "string")
                   | ascii_downcase
                   | gsub("[^a-z0-9._/-]+"; "-")
                   | gsub("-{2,}"; "-")
                   | sub("^[-/.]+"; "")
                   | sub("[-/.]+$"; ""))
               | map(select(length > 0))
               | unique'
}

bus_slug_room() {
  local slug
  slug="$(_bus_slug_filter)"
  jq -rn --arg r "${1:-}" '[$r] | '"$slug"' | .[0] // empty'
}

_bus_nonempty_array() {
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1" | jq -e 'type == "array" and ([.[] | select(length > 0)] | length) > 0' \
    >/dev/null 2>&1
}

# This repository's Room. Derived from the git REMOTE, not the folder name — the
# same repo is checked out under different directory names on different
# machines. Empty when there is no remote (or no repo).
bus_repo_room() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$remote" ] || return 0
  printf '%s' "$remote" \
    | sed -E 's#^git@([^:]+):#https://\1/#' \
    | sed -E 's#^[a-z+]+://[^/]+/##' \
    | sed -E 's#\.git$##' \
    | tr '[:upper:]' '[:lower:]'
}

# Key for a sticky Binding: "<repo>#<branch>". Empty when either half is
# unknown, including a detached HEAD — there is no branch to be sticky about.
#
# symbolic-ref, not `rev-parse --abbrev-ref HEAD`: rev-parse answers "HEAD" for
# both a detached head and a branch with no commits on it yet, and a fresh
# ticket branch usually has no commits on it yet.
bus_branch_key() {
  local repo="${1:-}" branch
  [ -n "$repo" ] || return 0
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || return 0
  printf '%s#%s' "$repo" "$branch"
}

# Add Rooms to the Monitor's join set. A Room the Monitor never joined delivers
# nothing to this machine at all — the silent failure this system fears most —
# so every Room a Session binds to is registered here, and Rooms are only ever
# added (bus-rooms.sh leave is the only thing that removes one).
bus_register_rooms() {
  local file="${1:?bus_register_rooms needs rooms.json}" rooms="${2:?bus_register_rooms needs a JSON array}"
  bus_json_update "$file" '[]' \
    'if type == "array" then . else [] end
     | . + ($add | map(select(type == "string" and length > 0)))
     | unique' \
    --argjson add "$rooms"
}

# ------------------------------------------------------------------ bindings

# Which Rooms Wake this Session, in the precedence ADR 0005 fixes. Prints
# {"level": "<level>", "rooms": [...]}. The level is part of the answer because
# the caller has to tell a choice somebody made from a fallback nobody did: only
# the first is worth remembering against the git branch.
#
#   session   bindings.json[<session>].rooms, written by the join skill
#             mid-session. That is the case that matters: which ticket a Session
#             ends up on is rarely known when it starts. Note bus-wake.sh writes
#             the resolved Binding back here at every level, so from a Session's
#             second Stop onwards this level always answers — it means "this
#             Session has a Binding", not "somebody chose one".
#   bus_room  BUS_ROOM=a,b at launch.
#   branch    branch-bindings.json[<repo>#<branch>] — a Binding recalled from an
#             earlier Session on this branch, so the ritual is paid once per
#             ticket instead of once per Session.
#   repo      the Repo room, derived from the git remote.
#
# The Direct room is added AT every level, never INSTEAD of one: a Direct room is
# addressed to the person and not to the ticket, so every live Session of theirs
# Wakes for it.
bus_resolve_binding() { # <config dir> <session id> <repo room> <dev name> <BUS_ROOM value>
  local cfg="${1:?}" sid="${2:?}" repo_room="${3:-}" dev="${4:-}" bus_room="${5:-}"
  local slug level rooms key
  slug="$(_bus_slug_filter)"

  level="session"
  rooms="$(jq -c --arg s "$sid" '(.[$s].rooms? // []) | map(select(type == "string"))' \
             "$cfg/bindings.json" 2>/dev/null || true)"

  if ! _bus_nonempty_array "$rooms"; then
    level="bus_room"
    rooms="$(jq -cn --arg v "$bus_room" '[$v | split(",")[] | gsub("^\\s+|\\s+$"; "")]')"
  fi

  if ! _bus_nonempty_array "$rooms"; then
    level="branch"
    rooms="[]"
    key="$(bus_branch_key "$repo_room")"
    if [ -n "$key" ]; then
      rooms="$(jq -c --arg k "$key" '(.[$k].rooms? // []) | map(select(type == "string"))' \
                 "$cfg/branch-bindings.json" 2>/dev/null || true)"
    fi
  fi

  if ! _bus_nonempty_array "$rooms"; then
    level="repo"
    rooms="$(jq -cn --arg r "$repo_room" '[$r]')"
  fi

  jq -cn --argjson rooms "$rooms" --arg dm "${dev:+dm/$dev}" --arg level "$level" \
    '{level: $level, rooms: (($rooms + [$dm]) | '"$slug"')}'
}

# ------------------------------------------------------------------- cursors

# Read forward from this Session's Cursor and advance it past whatever it finds,
# both inside one lock. Prints the unread Notices as JSONL (nothing at all when
# there are none) and always leaves cursors.json holding an entry for this
# Session with a fresh `seen` for the GC.
#
#   bus_claim_unread <cursors file> <session id> <spool file> <bound rooms JSON>
#
# The Spool is NEVER touched: no mv, no truncate, no delete. That is the whole of
# ADR 0005 — every Session reads the same lines independently, so there is no
# contest to win and nothing for a sibling Session to swallow, and the old
# mv-then-truncate window in which an arriving Notice was destroyed cannot exist.
#
# Pass an empty bound array to register a Session without reading anything: an id
# we have not seen before starts at the TAIL of the Spool, never at zero, or
# every /clear, every --fork-session and every Claude Code Remote turn replays
# the whole backlog as stale Wakes.
#
# The read and the advance are one locked step on purpose. Stop hooks are async,
# so two of them can be alive for the same Session at once; doing this under a
# lock is what stops both reporting the same Notices. It is the job the old
# `mv "$SPOOL"` claim was doing, moved to the Cursor where it belongs — the
# claim was machine-wide and so claimed every OTHER Session's Notices too.
bus_claim_unread() {
  local cursors="${1:?}" sid="${2:?}" spool="${3:?}" bound="${4:?}"
  local lock="$cursors.lock" state now src out tmp rc=0

  now="$(bus_now_iso)"
  # jq refuses a file that is not there; an absent Spool is simply an empty one.
  src="$spool"
  [ -f "$spool" ] || src=/dev/null

  bus_lock "$lock" || return 1

  state="$(cat "$cursors" 2>/dev/null || true)"
  [ -n "$state" ] || state='{}'
  printf '%s' "$state" | jq -e 'type == "object"' >/dev/null 2>&1 || state='{}'

  # -R -n: every Spool line is read as raw text and parsed on its own, so one
  # torn or half-written line costs that line rather than the whole read.
  #
  # The shape check on $state is the migration. The only other shape cursors.json
  # has ever had is Room-keyed ({"<room>": "<id>"}), which carries no Session in
  # it and so cannot be converted to one — it is discarded, and every Session
  # then starts at the tail, which is exactly where a Session with no Cursor
  # starts anyway.
  if out="$(jq -n -R -c \
      --arg sid "$sid" --arg now "$now" \
      --argjson bound "$bound" --argjson state "$state" '
    [inputs | fromjson? // empty | select(type == "object")] as $spool
    | (if ($state | type) == "object" then $state else {} end) as $raw
    | (if ($raw | to_entries | all(.value | (type == "object") and has("rooms")))
       then $raw else {} end) as $st
    # Tail of the Spool: the last Notice id seen in each Room, right now.
    | (reduce $spool[] as $n ({};
         if (($n.room? // null) != null) and (($n.id? // null) != null)
         then .[$n.room] = $n.id else . end)) as $tail
    | (if (($st[$sid].rooms?) | type) == "object" then $st[$sid].rooms else $tail end) as $cur
    | ($spool | to_entries) as $e
    # Where each Room-s Cursor sits in the Spool. A Cursor whose Notice has been
    # trimmed away leaves -1, so everything still present in that Room counts as
    # unread — correct, because trimming only ever removes what is older.
    | (reduce $e[] as $x ({};
         if (($x.value.room? // null) != null)
            and (($x.value.id? // null) != null)
            and (($cur[$x.value.room] // null) == $x.value.id)
         then .[$x.value.room] = $x.key else . end)) as $cut
    # $r is bound before it is used: inside `$bound | index(...)` the dot is
    # $bound, not the entry, and reaching for .value.room there reads the array.
    | [$e[]
       | . as $x
       | ($x.value.room? // null) as $r
       | select($r != null)
       | select(($bound | index($r)) != null)
       | select($x.key > ($cut[$r] // -1))
       | $x.value] as $unread
    | (reduce $unread[] as $n ($cur;
         if ($n.id? // null) != null then .[$n.room] = $n.id else . end)) as $next
    | {unread: $unread, state: ($st | .[$sid] = {rooms: $next, seen: $now})}
  ' "$src" 2>/dev/null)"; then
    tmp="$(mktemp "$cursors.XXXXXX")" || rc=1
    if [ "$rc" = 0 ]; then
      if printf '%s' "$out" | jq -c '.state' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$cursors"
      else
        rm -f "$tmp"
        rc=1
      fi
    fi
    # Emitted even when the Cursor write failed; the caller treats a non-zero
    # return as "did not happen" and will look again, because a Cursor that did
    # not move must not be reported as read.
    printf '%s' "$out" | jq -c '.unread[]' 2>/dev/null || true
  else
    rc=1
  fi

  bus_unlock "$lock"
  return "$rc"
}
