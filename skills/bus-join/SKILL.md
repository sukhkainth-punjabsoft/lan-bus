---
name: bus-join
description: Bind this Claude Code Session to a Workstream room on the Truxo dev Bus, so it is woken by one ticket's traffic instead of everything in the repo. Use when the user says which ticket or piece of work this Session is on ("this session is on truxo-3663"), when they ask to join or leave a Room, or when two Sessions in one repo keep waking each other.
---

# Bind this session to a room

A **Binding** is the set of Rooms that Wake **this Session** — not this machine,
not this directory. Bind a Session to the Workstream room for the ticket it is
actually on, and the other Session you have open on the same repo stops
interrupting it.

Binding is always explicit. Room names are arbitrary: nothing about
`truxo-3663` can be read off a checkout, so nobody — not this skill, not the
wake hook — can guess it. Somebody has to say it.

**The normal case is mid-session.** Which ticket a Session ends up on is rarely
known when it starts, so bind the moment it becomes clear: the user names a
ticket, picks up a hotfix, or says "that's what I'm on now". You do not need to
be asked in those words. Confirm the Room name with them before writing, though
— a Binding to a Room nobody else is in is silence that looks like a working Bus.

## Bind

Set `ROOM` to what the user named and run it. One Room per run; run it again to
add a second.

```bash
set -euo pipefail
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"

ROOM="truxo-3663"   # <- the Room, as the user named it

# Which Session this is. A skill has no hook stdin, so it reads the env var that
# mirrors the `session_id` bus-wake.sh reads from its own stdin. Under Claude
# Code Remote the plain id is reminted every turn while the remote one survives,
# so the remote one wins — this is the same precedence bus-wake.sh uses, and if
# the two ever disagree the Binding is written for a Session that never wakes.
SESSION_ID="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SESSION_ID" ] || { echo "no session id in the environment — cannot bind" >&2; exit 1; }
# It becomes a JSON key and arrives from outside this script. Ids are UUIDs in
# practice, but nothing in the hook protocol promises that.
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"

# The same normalisation the server applies (and hooks/bus-rooms.sh), so the
# Room in a Binding is byte-identical to the one on an arriving Notice. A
# Binding that differs by one character wakes nobody and reads as "the bus is
# down".
ROOM="$(printf '%s' "$ROOM" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's#[^a-z0-9._/-]+#-#g; s#-{2,}#-#g; s#^[-/.]+##; s#[-/.]+$##')"
[ -n "$ROOM" ] || { echo "that room name normalises to nothing" >&2; exit 1; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$CONFIG_DIR"

# The Repo room, from the git remote and not the folder name — the same sed
# chain as hooks/bus-wake.sh, because <repo> is half of the branch-binding key
# and the two must agree character for character.
REPO=""
remote="$(git remote get-url origin 2>/dev/null || true)"
if [ -n "$remote" ]; then
  REPO="$(printf '%s' "$remote" \
    | sed -E 's#^git@([^:]+):#https://\1/#' \
    | sed -E 's#^[a-z+]+://[^/]+/##' \
    | sed -E 's#\.git$##' \
    | tr '[:upper:]' '[:lower:]')"
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# Every Session on this machine writes these two files, and so does the wake
# hook when it refreshes `seen`. A lost read-modify-write here does not corrupt
# anything — it silently deletes somebody else's Binding, which is the exact
# class of failure this design exists to remove. macOS has no flock(1); mkdir is
# the atomic test-and-set that exists everywhere.
LOCK="$CONFIG_DIR/bus-join.lock"
tries=0
while ! mkdir "$LOCK" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || { echo "cannot take $LOCK" >&2; exit 1; }
  # 5s is orders of magnitude longer than two jq rewrites, so a lock still held
  # by then belongs to a shell that died holding it. Break it rather than hang.
  [ "$tries" -ne 50 ] || rmdir "$LOCK" 2>/dev/null || true
  sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

BINDINGS="$CONFIG_DIR/bindings.json"
# Unreadable is already lost; starting clean beats every future write failing.
jq -e . "$BINDINGS" >/dev/null 2>&1 || echo '{}' > "$BINDINGS"
tmp="$(mktemp)"
# Touch this Session's key and nothing else: every other live Session on this
# machine keeps its Binding in the same file, and rewriting the document whole
# is precisely the bug being fixed one file over.
#
# The first bind seeds the Repo room alongside the new one, because a Session
# that HAS a Binding no longer falls back to it — without this, saying "I am on
# truxo-3663" would quietly stop all repo-wide traffic reaching you, which is
# not what anyone means by it.
jq --arg s "$SESSION_ID" --arg room "$ROOM" --arg repo "$REPO" --arg now "$NOW" '
  .[$s].rooms = (((.[$s].rooms) // (if $repo == "" then [] else [$repo] end))
                 + [$room] | unique)
  | .[$s].seen = $now
' "$BINDINGS" > "$tmp"
mv "$tmp" "$BINDINGS"

# Sticky, so the ritual is paid once per ticket rather than once per Session:
# the next Session started on this branch rebinds itself from here. The name is
# still never derived from the checkout, only recalled. Skipped on a detached
# HEAD, which is a checkout state and not a piece of work.
if [ -n "$REPO" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ]; then
  BRANCH_BINDINGS="$CONFIG_DIR/branch-bindings.json"
  jq -e . "$BRANCH_BINDINGS" >/dev/null 2>&1 || echo '{}' > "$BRANCH_BINDINGS"
  tmp="$(mktemp)"
  jq --arg k "$REPO#$BRANCH" --arg room "$ROOM" --arg now "$NOW" '
    .[$k].rooms = (((.[$k].rooms) // []) + [$room] | unique)
    | .[$k].seen = $now
  ' "$BRANCH_BINDINGS" > "$tmp"
  mv "$tmp" "$BRANCH_BINDINGS"
fi

rmdir "$LOCK" 2>/dev/null || true
trap - EXIT

# A Binding decides which Notices reach this Session; it does not put the
# machine on the Bus. The Monitor has to JOIN the Room or the Notice never
# arrives here at all, and the Binding waits forever for something nobody is
# listening for. Join is the Monitor's word, bind is the Session's.
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-rooms.sh" join "$ROOM"

echo "bound to $ROOM"
jq --arg s "$SESSION_ID" '.[$s]' "$BINDINGS"
```

Then tell the user, in one line, which Rooms this Session now wakes for — the
Repo room is still in the list unless they ask for it gone.

### What that wrote

| File | Key | Why |
|---|---|---|
| `bindings.json` | `<session_id>` | Which Rooms Wake **this** Session. Merged, never replaced — siblings live here too. |
| `branch-bindings.json` | `<repo>#<branch>` | Remembered for the next Session on this branch. |
| `rooms.json` | — | The Monitor's join set, machine-wide. Without this the Notice never reaches the machine. |

`seen` on both is refreshed on every write; a Binding untouched for 14 days is
swept, because `SessionEnd` does not fire on a `kill -9` and these would
otherwise accumulate forever.

## A new Room starts at the tail of the Spool

Binding to a Room does **not** replay what it has already carried. The Cursor
for a newly bound Room starts at the current end of the Spool, so you are woken
by what arrives from now on and not by a wall of history from before you were
interested — which is what joining a busy ticket mid-flight would otherwise
cost.

That is deliberate, and it means a Binding is not how you catch up. To read what
was said in a Room before you bound to it, use `/bus-inbox`, which fetches
history on purpose and frames it as the untrusted third-party text it is.

## List what this Session is bound to

```bash
set -euo pipefail
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
BINDINGS="$CONFIG_DIR/bindings.json"
[ -f "$BINDINGS" ] || echo '{}' > "$BINDINGS"

SESSION_ID="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"

echo "this Session ($SESSION_ID) is bound to:"
jq -r --arg s "$SESSION_ID" '
  (.[$s].rooms // []) as $r
  | if ($r | length) == 0 then "  (nothing — falls back to the Repo room)"
    else $r[] | "  " + . end' "$BINDINGS"

# Shown because this is the file two Sessions are meant to share without
# treading on each other — if a sibling has vanished from it, something is
# rewriting the document whole again.
echo
echo "other Sessions on this machine:"
jq -r --arg s "$SESSION_ID" '
  (to_entries | map(select(.key != $s))) as $o
  | if ($o | length) == 0 then "  (none)"
    else $o[] | "  " + .key + "  " + ((.value.rooms // []) | join(", "))
               + "   (seen " + (.value.seen // "?") + ")" end' "$BINDINGS"

remote="$(git remote get-url origin 2>/dev/null || true)"
REPO=""
if [ -n "$remote" ]; then
  REPO="$(printf '%s' "$remote" \
    | sed -E 's#^git@([^:]+):#https://\1/#' \
    | sed -E 's#^[a-z+]+://[^/]+/##' \
    | sed -E 's#\.git$##' \
    | tr '[:upper:]' '[:lower:]')"
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -n "$REPO" ] && [ -n "$BRANCH" ]; then
  echo
  echo "remembered for $REPO#$BRANCH (restored for the next Session here):"
  jq -r --arg k "$REPO#$BRANCH" '
    (.[$k].rooms // []) as $r
    | if ($r | length) == 0 then "  (nothing)" else $r[] | "  " + . end' \
    "$CONFIG_DIR/branch-bindings.json" 2>/dev/null || echo "  (nothing)"
fi

echo
echo "the Monitor is joined to (machine-wide, every Session):"
jq -r '.[] | "  " + .' "$CONFIG_DIR/rooms.json" 2>/dev/null || echo "  (no rooms.json yet)"
```

The last two lists are wider than this Session on purpose. The Monitor joins
every Room the machine listens to; a Binding decides which of them get through
to a given Session. A Room in the join list but not in your Binding is a Room
some other Session here cares about — that is working as intended, not a leak.

## Leave a Room

```bash
set -euo pipefail
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"

ROOM="truxo-3663"   # <- the Room to stop being woken by

SESSION_ID="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"
ROOM="$(printf '%s' "$ROOM" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's#[^a-z0-9._/-]+#-#g; s#-{2,}#-#g; s#^[-/.]+##; s#[-/.]+$##')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

REPO=""
remote="$(git remote get-url origin 2>/dev/null || true)"
if [ -n "$remote" ]; then
  REPO="$(printf '%s' "$remote" \
    | sed -E 's#^git@([^:]+):#https://\1/#' \
    | sed -E 's#^[a-z+]+://[^/]+/##' \
    | sed -E 's#\.git$##' \
    | tr '[:upper:]' '[:lower:]')"
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

LOCK="$CONFIG_DIR/bus-join.lock"
tries=0
while ! mkdir "$LOCK" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || { echo "cannot take $LOCK" >&2; exit 1; }
  [ "$tries" -ne 50 ] || rmdir "$LOCK" 2>/dev/null || true
  sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

BINDINGS="$CONFIG_DIR/bindings.json"
jq -e . "$BINDINGS" >/dev/null 2>&1 || echo '{}' > "$BINDINGS"
BRANCH_BINDINGS="$CONFIG_DIR/branch-bindings.json"
jq -e . "$BRANCH_BINDINGS" >/dev/null 2>&1 || echo '{}' > "$BRANCH_BINDINGS"

tmp="$(mktemp)"
jq --arg s "$SESSION_ID" --arg room "$ROOM" --arg now "$NOW" '
  if has($s)
  then .[$s] = { rooms: ((.[$s].rooms // []) | map(select(. != $room))), seen: $now }
  else . end' "$BINDINGS" > "$tmp"
mv "$tmp" "$BINDINGS"

# Forget it for the branch too, or the next Session on this ticket is handed
# back the Room that was just walked out of.
if [ -n "$REPO" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ]; then
  tmp="$(mktemp)"
  jq --arg k "$REPO#$BRANCH" --arg room "$ROOM" --arg now "$NOW" '
    if has($k)
    then .[$k] = { rooms: ((.[$k].rooms // []) | map(select(. != $room))), seen: $now }
    else . end' "$BRANCH_BINDINGS" > "$tmp"
  mv "$tmp" "$BRANCH_BINDINGS"
fi

# rooms.json is machine-wide. Drop the join only when nothing on this machine
# is bound to the Room any more — otherwise leaving a Room in one Session stops
# its Notices arriving for a sibling Session that is still working in it, and
# that loss is silent.
wanted="$(jq --arg room "$ROOM" --slurpfile b "$BRANCH_BINDINGS" '
  [ (.[]?, ($b[0][]?)) | (.rooms // [])[] | select(. == $room) ] | length' "$BINDINGS")"

rmdir "$LOCK" 2>/dev/null || true
trap - EXIT

# Never unjoin the Repo room: bus-wake.sh re-adds it on the next turn anyway, so
# the churn would restart the Monitor for nothing.
if [ "$wanted" -eq 0 ] && [ "$ROOM" != "$REPO" ]; then
  "${CLAUDE_PLUGIN_ROOT}/hooks/bus-rooms.sh" leave "$ROOM"
else
  echo "unbound this Session from $ROOM ($wanted other binding(s) — the Monitor stays joined)"
fi
```

Unjoining restarts the Monitor, so the machine is off the Bus for a second or
two and anything posted in that window is missed. That is the price of actually
dropping the subscription; it is why the join is kept whenever a sibling Session
still wants the Room.

Leaving your last Room leaves a Binding with an empty room list. That is a
deliberate silence — nothing Wakes this Session — and it is not the same as
having no Binding at all, which is what falls back to the Repo room. If the user
wanted quiet rather than an empty list, `touch ~/.config/truxo-bus/pause`
silences the whole machine in both directions instead.

## Naming a Room, and telling people it exists

A Workstream room exists the moment someone posts to it — there is nothing to
create. Use the ticket key (`truxo-3663`), or the ticket plus a word when one
ticket has two crews (`truxo-3618-hotfix`). Anything that normalises to the same
string is the same Room, so `TRUXO 3663` and `truxo-3663` land together.

Only Sessions bound to a Room are woken in it, so a Room you have just invented
has an audience of one. If the user expects teammates there, say so once in the
Repo room with `/bus-send` — otherwise they are posting into a Room nobody is
listening to and reading the silence as agreement.

Rooms are noise routing, **not** access control: the Bus is unauthenticated, so
anyone who knows a Room's name can join it and read it.
