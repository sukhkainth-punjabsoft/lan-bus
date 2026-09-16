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

# The cursors document, normalised, as jq source. Shared by the read and the
# commit below so that both agree on what is on disk: if one rebuilt a malformed
# document and the other did not, the compare-and-set in bus_commit_cursor could
# never match and the Session would quietly stop reporting anything.
#
# The shape check is also the migration. The only other shape cursors.json has
# ever had is Room-keyed ({"<room>": "<id>"}), which carries no Session in it and
# so cannot be converted to one — it is discarded, and every Session then starts
# at the tail of the Spool, which is exactly where a Session with no Cursor
# starts anyway.
_bus_cursor_state_filter() {
  printf '%s' '
    (if type == "object" then . else {} end)
    | (if (to_entries | all(.value | (type == "object") and has("rooms")))
       then . else {} end)
  '
}

# The unread-and-next-Cursor calculation, emitted as jq source so that the two
# entry points below share one copy. They MUST agree exactly: a peek that
# computed `next` differently from the commit that writes it would advance the
# Cursor past a Notice nobody ever reported, which is the silent loss this whole
# project exists to prevent.
#
# Inputs: -R -n over the Spool, --arg sid/now, --argjson bound/state.
# Output: {unread, have, next, state}.
#   unread  the Notices this Session has not seen, in Spool order
#   have    the Cursor as it was read, or null when this Session had none — the
#           value a compare-and-set commit checks against
#   next    the Cursor once those Notices are read, i.e. what to commit
#   state   the whole cursors document with `next` already written in
_bus_unread_program() {
  local st
  st="$(_bus_cursor_state_filter)"
  # No single quotes anywhere in the body: it is carried as a single-quoted
  # shell string, spliced around $st.
  printf '%s' '
    [inputs | fromjson? // empty | select(type == "object")] as $spool
    | ($state | '"$st"') as $st
    | (if (($st[$sid].rooms?) | type) == "object" then $st[$sid].rooms else null end) as $have
    # Tail of the Spool: the last Notice id seen in each Room, right now.
    | (reduce $spool[] as $n ({};
         if (($n.room? // null) != null) and (($n.id? // null) != null)
         then .[$n.room] = $n.id else . end)) as $tail
    # A Session with no Cursor starts at the TAIL, never at zero, or every
    # /clear, every --fork-session and every Claude Code Remote turn (a fresh
    # session_id each time) replays the whole backlog as stale Wakes.
    | ($have // $tail) as $cur
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
    | {unread: $unread, have: $have, next: $next,
       state: ($st | .[$sid] = {rooms: $next, seen: $now})}
  '
}

# Run that program over the Spool. Shared by the two entry points; not called
# directly, and it takes no lock of its own — the locking caller holds one.
#
#   _bus_unread_compute <cursors file> <session id> <spool file> <bound rooms JSON>
#
# -R -n: every Spool line is read as raw text and parsed on its own, so one torn
# or half-written line costs that line rather than the whole read.
_bus_unread_compute() {
  local cursors="${1:?}" sid="${2:?}" spool="${3:?}" bound="${4:?}"
  local state src

  # jq refuses a file that is not there; an absent Spool is simply an empty one.
  src="$spool"
  [ -f "$spool" ] || src=/dev/null

  state="$(cat "$cursors" 2>/dev/null || true)"
  [ -n "$state" ] || state='{}'
  # --argjson rejects anything that is not JSON at all, which would fail the
  # whole read rather than degrade to an empty document.
  printf '%s' "$state" | jq -e . >/dev/null 2>&1 || state='{}'

  jq -n -R -c --arg sid "$sid" --arg now "$(bus_now_iso)" \
    --argjson bound "$bound" --argjson state "$state" \
    "$(_bus_unread_program)" "$src" 2>/dev/null
}

# Read forward from this Session's Cursor WITHOUT moving it.
#
#   bus_peek_unread <cursors file> <session id> <spool file> <bound rooms JSON>
#
# Prints one JSON object: {unread, have, next, state}. A caller reports `unread`
# and then commits `next` with bus_commit_cursor as the very last thing it does
# — see the ordering note there.
#
# The Spool is NEVER touched: no mv, no truncate, no delete. That is the whole of
# ADR 0005 — every Session reads the same lines independently, so there is no
# contest to win and nothing for a sibling Session to swallow, and the old
# mv-then-truncate window in which an arriving Notice was destroyed cannot exist.
#
# No lock is taken, because nothing is written. cursors.json is only ever
# replaced by rename, so a reader sees one whole version or another, never half.
bus_peek_unread() {
  local out
  out="$(_bus_unread_compute "$@")" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Advance this Session's Cursor from `have` to `next`, but ONLY if it still
# reads `have`.
#
#   bus_commit_cursor <cursors file> <session id> <have JSON> <next JSON>
#
# Returns 0 when the Cursor moved, which means the caller now owns those Notices
# and MUST report them; non-zero when it did not — either another waiter for this
# Session committed first (the compare-and-set failed) or the write did, and
# either way the Notices are still unread and are somebody else's to announce.
#
# ORDERING. A caller must build its whole report BEFORE calling this, print it
# immediately AFTER, and block signals across both. A Cursor advanced by a
# process that is then killed before it reports says a Notice was read when
# nobody ever saw it, and a Notice lost that way is the one failure this system
# cannot detect or recover from. A duplicate Wake is merely annoying, so every
# trade-off here leans that way.
#
# The compare-and-set is what stops a straggler — a waiter that outlived
# retirement, for instance one belonging to another installed plugin version —
# reporting the same Notices a second time. Splitting peek from commit gave up
# the single-lock atomicity bus_claim_unread has; this buys it back.
bus_commit_cursor() {
  local cursors="${1:?}" sid="${2:?}" have="${3:?}" next="${4:?}"
  local lock="$cursors.lock" state tmp rc=0 filter

  filter="$(_bus_cursor_state_filter)"

  bus_lock "$lock" || return 1

  state="$(cat "$cursors" 2>/dev/null || true)"
  [ -n "$state" ] || state='{}'

  tmp="$(mktemp "$cursors.XXXXXX")" || { bus_unlock "$lock"; return 1; }
  # Emits nothing at all when the Cursor on disk is not the one that was peeked,
  # which the -s test below turns into a non-zero return.
  if printf '%s' "$state" | jq -c --arg sid "$sid" --arg now "$(bus_now_iso)" \
       --argjson have "$have" --argjson next "$next" '
         ('"$filter"') as $st
         | (if (($st[$sid].rooms?) | type) == "object" then $st[$sid].rooms else null end) as $on_disk
         | if $on_disk == $have then ($st | .[$sid] = {rooms: $next, seen: $now}) else empty end
       ' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$cursors"
  else
    rm -f "$tmp"
    rc=1
  fi

  bus_unlock "$lock"
  return "$rc"
}

# Read forward from this Session's Cursor and advance it past whatever it finds,
# both inside one lock. Prints the unread Notices as JSONL (nothing at all when
# there are none) and always leaves cursors.json holding an entry for this
# Session with a fresh `seen` for the GC.
#
#   bus_claim_unread <cursors file> <session id> <spool file> <bound rooms JSON>
#
# Pass an empty bound array to register a Session without reading anything, which
# is what bus-wake.sh uses this for: it seeds an unknown Session at the tail of
# the Spool and refreshes `seen`, and reads nothing at all.
#
# A caller that intends to REPORT wants bus_peek_unread + bus_commit_cursor
# instead. Doing the read and the advance in one step marks the Notices read
# before the caller has said a word about them, so anything that kills it in
# between — including being retired by its own successor — loses them outright.
bus_claim_unread() {
  local cursors="${1:?}" sid="${2:?}" spool="${3:?}" bound="${4:?}"
  local lock="$cursors.lock" out tmp rc=0

  bus_lock "$lock" || return 1

  if out="$(_bus_unread_compute "$cursors" "$sid" "$spool" "$bound")" && [ -n "$out" ]; then
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

# ------------------------------------------------------------------- waiters
#
# Every turn spawns a Wake hook that waits up to BUS_WAIT_MINUTES, and nothing
# ever retired the previous one: ten were found alive on one machine at once, the
# oldest 21 minutes old, spread across two plugin versions installed side by
# side. Claiming the Spool with `mv` had been hiding what that cost — however
# many waiters were alive, exactly one could ever fire. ADR 0005 removed the
# claim, so the only thing now keeping N waiters for one Session from reporting
# the same Notice N times is the Cursor step, and which of the N wins it is
# arbitrary. That is a lock standing in for a lifecycle: the pile still grows by
# one every turn, every one of them polls, and the winner is whoever happens to
# look first. A waiter therefore records its pid against its Session and retires
# its predecessor before it starts waiting.
#
# Only ever for the SAME Session. Another Session's waiter is none of our
# business, and killing it is exactly the cross-talk ADR 0005 removed.

# Where a Session's live waiter records itself. Session ids are scrubbed by
# bus_session_id before they reach here, so they are safe as a path component.
bus_waiter_file() {
  printf '%s/waiters/%s.pid' "${1:?bus_waiter_file needs a config dir}" \
                             "${2:?bus_waiter_file needs a session id}"
}

# A live process's start time, as one comparable string. Empty and non-zero when
# the pid is gone.
#
# A pid on its own is NOT safe to signal. Pids are recycled, and by the time one
# is read back it may belong to something else entirely; killing an unrelated
# process because a pid was reused would be far worse than leaving a stray
# waiter alive. Worse still, the recycler could be ANOTHER Session's waiter,
# which really is a bus-wake.sh and so passes any check made on the command
# alone. Start time settles both: the pid must still be the same process that
# wrote the file.
_bus_pid_identity() {
  local pid="${1:-}" line
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # ps fails and prints nothing for a pid that is gone.
  line="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  # BSD ps pads lstart, so squeeze the spaces — a recorded value has to compare
  # equal to one read back later.
  printf '%s' "$line" | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# True when <pid> is a live process really running <script basename>, rather
# than one that merely mentions it. A shell one-liner, a grep, an editor with
# the file open — all of them carry the name on their command line, and
# signalling one of those is the failure this guard exists for.
#
# The rule is "the command is the script, optionally behind an interpreter":
# walk the command line and the FIRST token that is not an interpreter must be
# the script itself. That accepts `bus-wake.sh`, `bash /path/bus-wake.sh` and
# the `/usr/bin/env bash /path/bus-wake.sh` a `#!/usr/bin/env bash` shebang
# produces, and rejects `zsh -c "...bus-wake.sh..."` — which would otherwise
# slip through on the interpreter name alone.
bus_pid_runs_script() {
  local pid="${1:-}" script="${2:?bus_pid_runs_script needs a script name}" cmd tok
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1

  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1

  while [ -n "$cmd" ]; do
    tok="${cmd%% *}"
    case "$cmd" in *" "*) cmd="${cmd#* }" ;; *) cmd="" ;; esac
    [ -n "$tok" ] || continue
    case "${tok##*/}" in
      "$script") return 0 ;;
      sh|bash|zsh|dash|ksh|env) ;;
      # Anything else — another program, or a flag such as -c — means this is
      # not an interpreter running the script, whatever else is on the line.
      *) return 1 ;;
    esac
  done
  return 1
}

# Retire this Session's previous waiter, if it still has one, and record
# ourselves in its place.
#
#   bus_waiter_takeover <config dir> <session id> <script basename>
#
# Read, signal and write are one locked step. Two waiters starting at the same
# moment would otherwise both read the same predecessor and both write
# themselves, and the loser would stay alive with nothing naming it — a stray
# nobody can ever retire, which is the bug this exists to remove.
#
# The predecessor is not waited for. It may be inside the window where it has
# committed a Cursor and not yet reported, where it ignores TERM on purpose; it
# finishes that and exits on its own, and its cleanup leaves our file alone
# because the file no longer names it.
bus_waiter_takeover() {
  local cfg="${1:?}" sid="${2:?}" script="${3:?}"
  local file lock dir old old_pid old_start tmp rc=0

  file="$(bus_waiter_file "$cfg" "$sid")"
  dir="$(dirname "$file")"
  lock="$file.lock"
  mkdir -p "$dir" 2>/dev/null || return 1

  bus_lock "$lock" || return 1

  old="$(cat "$file" 2>/dev/null || true)"
  old_pid="${old%% *}"
  old_start="${old#* }"
  # No space in the record at all means no start time was written: refuse to
  # signal on a bare pid rather than guess.
  [ "$old_start" != "$old" ] || old_start=""
  if [ -n "$old_pid" ] && [ -n "$old_start" ] \
     && bus_pid_runs_script "$old_pid" "$script" \
     && [ "$(_bus_pid_identity "$old_pid" || true)" = "$old_start" ]; then
    kill -TERM "$old_pid" 2>/dev/null || true
    bus_log "wake: retired waiter pid $old_pid for session $sid (superseded by pid $$)"
  fi

  tmp="$(mktemp "$file.XXXXXX")" || { bus_unlock "$lock"; return 1; }
  if printf '%s %s\n' "$$" "$(_bus_pid_identity "$$" || true)" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    rc=1
  fi

  # Opportunistic sweep, inside the lock already held. A waiter lives at most
  # BUS_WAIT_MINUTES, so anything a day old was left behind by a SIGKILL and
  # names a process long gone. SessionEnd does not fire on SIGKILL either, so
  # without this nothing would ever clear them.
  find "$dir" -type f -name '*.pid' -mtime +1 -delete 2>/dev/null || true

  bus_unlock "$lock"
  return "$rc"
}

# Give up this Session's waiter slot on the way out.
#
#   bus_waiter_release <config dir> <session id>
#
# Removes the file ONLY while it still names us. By the time a retired waiter
# runs its cleanup its successor has already written itself in, and deleting
# that would leave the successor unretirable: the next waiter would find no
# file, retire nobody, and the two would pile up exactly as before.
#
# Locked for the same reason the takeover is — a release that read the file just
# before a successor rewrote it would otherwise delete the successor.
bus_waiter_release() {
  local cfg="${1:?}" sid="${2:?}"
  local file lock current

  file="$(bus_waiter_file "$cfg" "$sid")"
  lock="$file.lock"
  [ -f "$file" ] || return 0

  # A lock we cannot take is not worth failing an exit path over. The file we
  # would have removed names a dead process, and every reader proves liveness
  # before it signals anything.
  bus_lock "$lock" || return 0
  current="$(cat "$file" 2>/dev/null || true)"
  # An `if`, not `[ ... ] && rm`. This is the last real work an exiting waiter
  # does, and a bare AND-list would leave "the file is not ours" — the ordinary
  # case for a waiter that has already been superseded — looking like a failure
  # to whatever reads the status next.
  if [ "${current%% *}" = "$$" ]; then rm -f "$file"; fi
  bus_unlock "$lock"
  return 0
}
