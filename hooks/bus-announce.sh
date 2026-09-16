#!/usr/bin/env bash
# Announce this Session's own pushes to the Bus (ADR 0006, the factual trigger).
#
# ADR 0006 splits announcing in two. Whether a piece of work unblocks a teammate
# is a judgement and lives in the bus-send skill's prose. Whether a push happened
# is a fact, and lives here — in a hook, because no judgement is involved and a
# hook cannot be talked out of it.
#
# Two modes, registered as two different hooks in hooks.json:
#
#   record   PostToolUse(Bash). Notices that the Bash tool just pushed, and
#            writes the push down as PENDING. Posts nothing.
#   flush    Stop. Posts the pending push — unless a guard says otherwise.
#
# WHY TWO MODES, WHEN ONE POSTTOOLUSE HOOK WOULD DO.
# The hard loop guard (ADR 0006) is `stop_hook_active`, and that flag exists ONLY
# on Stop stdin — it is absent from the PostToolUse payload (verified below). So
# a PostToolUse hook cannot know whether the turn it is running in was begun by
# a Wake, and a hook that cannot know that must not post. Deferring the post to
# Stop is what makes the flag readable at the moment of decision. Collapsing
# these two modes back into one PostToolUse hook does not simplify this file; it
# deletes the loop guard.
#
# VERIFIED AGAINST claude 2.1.272 (darwin arm64, 2026-09-16) by registering a
# throwaway PostToolUse hook that dumped its raw stdin. Captured payload:
#
#   { "session_id": "...", "transcript_path": "...", "cwd": "...",
#     "scratchpad_dir": "...", "prompt_id": "...", "permission_mode": "default",
#     "hook_event_name": "PostToolUse",
#     "tool_name": "Bash",
#     "tool_input":    { "command": "git push origin main", "description": "..." },
#     "tool_response": { "stdout": "...", "stderr": "", "interrupted": false,
#                        "isImage": false, "noOutputExpected": false,
#                        "gitOperation": { "push": { "branch": "main" } } },
#     "tool_use_id": "toolu_...", "duration_ms": 334 }
#
# Five things that probe established, each of which this script leans on:
#
#   1. The result field is `tool_response`, NOT `tool_result`. The plugin-dev
#      skill on this machine documents PostToolUse as carrying `tool_result`;
#      the installed binary sends `tool_response`, and so does Anthropic's own
#      stripe plugin. The docs are wrong here — trust the binary.
#   2. `tool_response.gitOperation.push.branch` is set by Claude Code itself when
#      it recognises the command as a push, and it resolves the real branch name
#      even from `git push -u origin HEAD`. It survives compound commands:
#      `git add -A && git commit -m … && git push` produced BOTH
#      `gitOperation.commit` and `gitOperation.push`. That is a far better signal
#      than grepping the command string, so it is the primary one. It is
#      UNDOCUMENTED, which is why the command-string fallback below exists.
#   3. `git push --dry-run` produced `gitOperation: null`. Claude Code already
#      draws the distinction we want.
#   4. A REJECTED push (non-fast-forward) fired no PostToolUse event at all —
#      nothing was captured. Good, but not relied upon: every push is confirmed
#      against git itself before anything is announced.
#   5. There is no `stop_hook_active` anywhere in that payload. That single
#      absence is the whole reason for the record/flush split.
#
# Manual use (testing only — nothing here is meant to be run by hand):
#   echo '{"session_id":"x","stop_hook_active":false}' | bus-announce.sh flush
set -euo pipefail

MODE="${1:?usage: bus-announce.sh record|flush  (registered as a hook, not run by hand)}"

# The hook payload arrives on stdin and there is exactly one copy of it, so read
# it FIRST — anything else that touches stdin consumes it. The -t 0 guard is for
# a by-hand run, where cat would otherwise block forever on a terminal that never
# sends EOF. Same idiom as bus-wake.sh.
HOOK_INPUT=""
[ -t 0 ] || HOOK_INPUT="$(cat 2>/dev/null || true)"

# BUS_ROOM points a Session at a Workstream room at launch, so it is a property
# of the launch and not of the machine: capture it before config.env is sourced,
# or a stray BUS_ROOM left in that file would silently outrank it. Same reasoning
# as bus-wake.sh, and the two must agree or a push announces into a different
# Room from the one the Session is Woken for.
BUS_ROOM_AT_LAUNCH="${BUS_ROOM:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/bus-lib.sh
source "$HERE/bus-lib.sh"

CONFIG_DIR="$(bus_config_dir)"
PENDING_DIR="$CONFIG_DIR/announce-pending"
RATE_FILE="$CONFIG_DIR/announce-rate.json"
# Same "<file>.lock" convention bus_json_update uses, so anything else that ever
# touches this file takes the same lock rather than a second one beside it.
RATE_LOCK="$RATE_FILE.lock"

# Max automatic posts per Session per hour (ADR 0006). This is the BACKSTOP, not
# the primary guard — `stop_hook_active` is. It exists so that a loop guard lost
# to some future payload change costs the team six interruptions an hour instead
# of six thousand. A post a HUMAN asked for goes out through the bus-send skill,
# which never touches announce-rate.json, so human posts are never capped.
RATE_LIMIT=6
RATE_WINDOW_SECONDS=3600

# A pending push older than this is dropped rather than posted: it means the
# Session died between the push and its next Stop, so the news is no longer news.
PENDING_MAX_AGE_SECONDS=3600

# Branches the whole repo builds on. A push to one of these is everyone's
# business and goes to the Repo room; anything else is one Session's workstream
# and goes only to the Rooms that Session is Bound to.
SHARED_BRANCHES="main master dev stage"

# ---------------------------------------------------------------------------
# Guards common to both modes
# ---------------------------------------------------------------------------

# Not configured, or no jq: the Bus does nothing at all on this machine.
[ -f "$CONFIG_DIR/config.env" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# PAUSE IS BIDIRECTIONAL (ADR 0006). The Monitor already discards inbound Notices
# while this file exists; it has to silence outbound announcements too, or
# "pause" means "stop hearing the team but keep shouting at them". One switch,
# both directions.
[ -f "$CONFIG_DIR/pause" ] && exit 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A ticket key read out of a branch name — feat/TRUXO-3663-foo -> TRUXO-3663.
# Best-effort, and empty when there is nothing to find: the ticket is only a tag
# on the Event, so a miss costs a teammate nothing.
ticket_from_branch() {
  printf '%s' "${1:-}" \
    | grep -oiE '[a-z][a-z0-9]{1,9}-[0-9]{1,6}' \
    | head -1 \
    | tr '[:lower:]' '[:upper:]' 2>/dev/null || true
}

# Claim one automatic post for this Session. Returns 0 if the post may go ahead
# (and records it), 1 if the hour's allowance is spent.
#
# Hand-rolled rather than bus_json_update because this is a read-modify-write
# whose ANSWER matters: bus_json_update reports whether it wrote, not whether the
# Session was under its limit, and appending a timestamp before knowing that
# would spend the slot it is deciding about. The lock and the lock path are the
# library's, so the two stay serialised against each other.
rate_take() {
  local sid="${1:?}" tmp allowed=false

  # FAIL CLOSED. A lock we cannot take within bus_lock's five seconds means a lot
  # of Sessions are posting at once — which is the announcement storm this limit
  # exists to stop — so the right answer is silence. ADR 0006 accepts a swallowed
  # announcement (a human can resend it); it does not accept a storm.
  bus_lock "$RATE_LOCK" || return 1

  tmp="$(mktemp "$RATE_FILE.XXXXXX")" || { bus_unlock "$RATE_LOCK"; return 1; }

  # Timestamps are jq's own `todate` — ISO8601 UTC, fixed width — so the window
  # is a string comparison and no date(1) arithmetic is needed (BSD date has no
  # `-d`). Sessions whose timestamps have all aged out are dropped on the way
  # past, which is the whole of this file's GC.
  if printf '%s' "$(cat "$RATE_FILE" 2>/dev/null || echo '{}')" \
     | jq --arg sid "$sid" --argjson limit "$RATE_LIMIT" --argjson window "$RATE_WINDOW_SECONDS" '
        (now - $window | todate) as $cut
        | (if type == "object" then . else {} end)
        | with_entries(.value |= ((. // []) | map(select(type == "string" and . > $cut))))
        | with_entries(select(.value | length > 0))
        | if ((.[$sid] // []) | length) >= $limit
          then { allowed: false, state: . }
          else { allowed: true,  state: (.[$sid] = ((.[$sid] // []) + [now | todate])) }
          end' > "$tmp" 2>/dev/null && [ -s "$tmp" ]
  then
    allowed="$(jq -r '.allowed' "$tmp" 2>/dev/null || echo false)"
    if [ "$allowed" = "true" ]; then
      # Renamed into place from the same directory, so a concurrent reader never
      # sees half a rate file.
      if jq -c '.state' "$tmp" > "$tmp.state" 2>/dev/null && [ -s "$tmp.state" ]; then
        mv "$tmp.state" "$RATE_FILE"
      else
        allowed=false
      fi
    fi
  else
    # Unreadable or corrupt. Reset it rather than leave a document that fails
    # every future write — but skip THIS post, because a rate file we could not
    # read is a rate file we cannot claim a slot in.
    echo '{}' > "$RATE_FILE"
  fi

  rm -f "$tmp" "$tmp.state"
  bus_unlock "$RATE_LOCK"
  [ "$allowed" = "true" ]
}

# ---------------------------------------------------------------------------
# record — PostToolUse(Bash). Write the push down; post nothing.
# ---------------------------------------------------------------------------
record() {
  local sid cwd branch cmd head remote remote_ref subject repo ticket pending prior
  local input="$HOOK_INPUT"

  [ -n "$input" ] || exit 0
  sid="$(bus_session_id "$input")" \
    || bus_log "announce: PostToolUse carried no session_id; pending push is machine-wide"

  cwd="$(bus_hook_field "$input" cwd)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
  cd "$cwd"

  # Primary signal: Claude Code's own classification of the command. See the
  # header — it handles `git push -u origin HEAD`, survives compound
  # `commit && push`, and already returns null for `--dry-run`. Read with jq
  # directly rather than bus_hook_field, which reads top-level fields only.
  branch="$(printf '%s' "$input" \
    | jq -r '.tool_response.gitOperation.push.branch // empty' 2>/dev/null || true)"

  if [ -z "$branch" ]; then
    # Fallback, because gitOperation is undocumented and could disappear without
    # notice. Deliberately crude — it over-matches, `echo "git push"` included —
    # and safe only because every candidate is confirmed against git below.
    cmd="$(bus_hook_field "$input" tool_input | jq -r '.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] || exit 0
    # `-n` is git push's short --dry-run. Matching it anywhere in a compound
    # command over-excludes, which is the safe direction: a missed announcement
    # is recoverable, a wrong one is already in everybody's session.
    printf '%s' "$cmd" | grep -qE -- '(--dry-run|[[:space:]]-n([[:space:]]|$))' && exit 0
    printf '%s' "$cmd" \
      | grep -qE '(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?push([[:space:]]|$)' \
      || exit 0
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

  # CONFIRM IT AGAINST GIT, not against the tool's output text. A push that
  # succeeded has moved the remote-tracking ref up to the branch tip; a push that
  # was rejected, or was a no-op, or never ran at all, has not. This is what
  # makes the trigger factual instead of a guess at what the terminal printed,
  # and it is why scraping stdout for "->" is not good enough.
  head="$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)"
  [ -n "$head" ] || exit 0
  remote="$(git config --get "branch.$branch.remote" 2>/dev/null || true)"
  remote="${remote:-origin}"
  remote_ref="$(git rev-parse --verify --quiet "refs/remotes/$remote/$branch" 2>/dev/null || true)"
  [ -n "$remote_ref" ] && [ "$head" = "$remote_ref" ] || exit 0

  repo="$(bus_repo_room)"
  [ -n "$repo" ] || exit 0

  subject="$(git log -1 --pretty=%s "refs/heads/$branch" -- 2>/dev/null || true)"
  [ -n "$subject" ] || exit 0
  ticket="$(ticket_from_branch "$branch")"

  mkdir -p "$PENDING_DIR"
  pending="$PENDING_DIR/$sid.json"

  # announced_sha outlives each flush so the same commit is never announced
  # twice — a second `git push` with nothing new to send must not read as a
  # second piece of news.
  prior="$(jq -r '.announced_sha // empty' "$pending" 2>/dev/null || true)"
  [ "$prior" = "$head" ] && exit 0

  # One pending push per Session, last write wins. Several pushes in one turn are
  # one piece of news to a teammate, and posting each of them separately is the
  # announcement storm ADR 0006 is trying to avoid. cwd is recorded because the
  # push may have happened in a different checkout from the one the Session ends
  # the turn in, and the Room has to be resolved against the pushed repo.
  jq -n --arg branch "$branch" --arg sha "$head" --arg subject "$subject" \
        --arg repo "$repo" --arg ticket "$ticket" --arg cwd "$cwd" --arg prior "$prior" \
        '{branch: $branch, sha: $sha, subject: $subject, repo: $repo,
          ticket: $ticket, cwd: $cwd, at: (now | todate)}
         + (if $prior == "" then {} else {announced_sha: $prior} end)' \
    > "$pending.tmp" && mv "$pending.tmp" "$pending"

  exit 0
}

# ---------------------------------------------------------------------------
# flush — Stop. Post the pending push, if every guard allows it.
# ---------------------------------------------------------------------------
flush() {
  local sid pending active branch sha subject repo ticket cwd at cutoff
  local binding level rooms room shared posted err rc detail b
  local input="$HOOK_INPUT"

  [ -n "$input" ] || exit 0
  sid="$(bus_session_id "$input")" || true
  pending="$PENDING_DIR/$sid.json"

  # Cheap GC. Cursors and Bindings are swept on a 14-day clock; a pending push is
  # worthless within the hour, so a week is already generous. SessionEnd does not
  # fire on SIGKILL, so nothing else will ever clear these up.
  [ -d "$PENDING_DIR" ] && find "$PENDING_DIR" -type f -mtime +7 -delete 2>/dev/null || true

  [ -f "$pending" ] || exit 0

  # =========================================================================
  # THE LOOP GUARD. DO NOT REMOVE. IT LOOKS REMOVABLE AND IT IS NOT.
  #
  # `stop_hook_active` is true when this turn is itself the continuation of a
  # turn some Stop hook blocked — which, on this machine, means bus-wake.sh Woke
  # us because a teammate posted. Announcing from such a turn is how the Bus
  # cascades with no person anywhere in it:
  #
  #     A announces -> Wakes B -> B works -> B announces -> Wakes A -> ...
  #
  # Nothing downstream stops that. The rate limit below only slows it to six
  # interruptions per Session per hour, on every machine, forever. This `if` is
  # the only thing standing between the team and that.
  #
  # The pending push is DISCARDED rather than held for a later turn. Holding it
  # would be defensible — the next human turn does have a human in it — but it
  # opens a path by which Wake-driven work still reaches the Bus, and a loop
  # guard with a path through it is not a loop guard. ADR 0006 already accepts
  # losing the occasional legitimate announcement: a missed post can be sent by
  # hand, an announcement storm cannot be recalled.
  #
  # bus_hook_field returns booleans as the strings "true"/"false" and an absent
  # field as empty, precisely so that those two cases can be told apart here.
  # Do not "simplify" this to `jq -r '.stop_hook_active // false'`: jq's `//`
  # treats false as absent, which collapses exactly the distinction below.
  # =========================================================================
  active="$(bus_hook_field "$input" stop_hook_active)"
  if [ -z "$active" ]; then
    # FAIL CLOSED on a payload that does not carry the flag at all. It was
    # verified present on Stop in claude 2.1.272, so its absence means the
    # contract moved underneath us and the guard can no longer be evaluated.
    # Losing announcements is visible and reversible; losing the guard silently
    # is the cascade in ADR 0006's last consequence. Prefer the loud failure —
    # and note that this line, not a cascade, is the symptom to look for if
    # automatic announcements ever stop appearing.
    bus_log "announce: no stop_hook_active on Stop payload — loop guard cannot be evaluated, discarding pending push"
    rm -f "$pending"
    exit 0
  fi
  if [ "$active" = "true" ]; then
    bus_log "announce: suppressed, this turn was begun by a Wake (stop_hook_active)"
    rm -f "$pending"
    exit 0
  fi

  branch="$(jq -r  '.branch  // empty' "$pending" 2>/dev/null || true)"
  sha="$(jq -r     '.sha     // empty' "$pending" 2>/dev/null || true)"
  subject="$(jq -r '.subject // empty' "$pending" 2>/dev/null || true)"
  repo="$(jq -r    '.repo    // empty' "$pending" 2>/dev/null || true)"
  ticket="$(jq -r  '.ticket  // empty' "$pending" 2>/dev/null || true)"
  cwd="$(jq -r     '.cwd     // empty' "$pending" 2>/dev/null || true)"
  at="$(jq -r      '.at      // empty' "$pending" 2>/dev/null || true)"
  if [ -z "$branch" ] || [ -z "$sha" ] || [ -z "$subject" ] || [ -z "$repo" ]; then
    rm -f "$pending"; exit 0
  fi

  # Both sides are jq `todate` output, so a string comparison IS a time
  # comparison and BSD date's missing `-d` never comes up.
  # -r is load-bearing: without it jq emits a QUOTED string, and the leading `"`
  # (0x22) sorts below every digit, so every pending push would compare as fresh
  # and this check would silently never fire.
  cutoff="$(jq -rn --argjson w "$PENDING_MAX_AGE_SECONDS" '(now - $w) | todate')"
  if [ -z "$at" ] || ! [[ "$at" > "$cutoff" ]]; then
    rm -f "$pending"; exit 0
  fi

  # Resolve the Room against the checkout the push happened in, not wherever the
  # Session happens to be standing now.
  [ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd"

  # ROUTING (ADR 0006). A shared branch is everyone's business and goes to the
  # Repo room. Anything else is this Session's workstream and goes only to the
  # Rooms it is Bound to. No membership lookup is needed: if no teammate is in
  # that Room the Notice Wakes nobody and rests in the Spool (ADR 0005).
  shared=""
  for b in $SHARED_BRANCHES; do
    [ "$branch" = "$b" ] && shared="yes"
  done

  if [ -n "$shared" ]; then
    rooms="$repo"
  else
    # bus_resolve_binding, not a direct read of bindings.json, so an announcement
    # lands in the same Room this Session is Woken for — including a Binding
    # recalled from branch-bindings.json, which is the common case for a ticket
    # picked up by a later Session. Read-only here; the Wake path owns writing it.
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/config.env"
    BUS_ROOM="${BUS_ROOM_AT_LAUNCH:-${BUS_ROOM:-}}"
    binding="$(bus_resolve_binding "$CONFIG_DIR" "$sid" "$repo" "${DEV_NAME:-}" "${BUS_ROOM:-}" 2>/dev/null || true)"
    level="$(printf '%s' "$binding" | jq -r '.level // empty' 2>/dev/null || true)"

    if [ "$level" = "repo" ] || [ -z "$level" ]; then
      # No real Binding — bus_resolve_binding fell all the way back to the Repo
      # room. Silence, not the Repo room: a feature-branch push waking everyone
      # on the repo is precisely the noise that teaches people to mute the Bus,
      # and it is what ADR 0006 reserves the Repo room against.
      rm -f "$pending"; exit 0
    fi

    # The Repo room and this developer's own Direct room are dropped: the first
    # for the reason above, the second because a Direct room is addressed to its
    # owner, and the server never Wakes an Author with their own Event.
    rooms="$(printf '%s' "$binding" | jq -r --arg repo "$repo" --arg dm "dm/${DEV_NAME:-}" '
      (.rooms // []) | map(select(. != $repo and . != $dm)) | .[]' 2>/dev/null || true)"
  fi

  # Nothing left to speak into.
  if [ -z "$rooms" ]; then
    rm -f "$pending"; exit 0
  fi

  posted=""
  while IFS= read -r room; do
    [ -n "$room" ] || continue
    # Claimed per Event, because a post is what interrupts someone: a fan-out to
    # three Rooms is three interruptions, not one.
    if ! rate_take "$sid"; then
      bus_log "announce: rate limit reached for this Session, dropping push to $room"
      continue
    fi

    err="$(mktemp)"
    rc=0
    # Reuse bus-send.sh rather than reimplementing the POST: one place builds the
    # payload, one place knows the URL, one place learns about new fields.
    # -t is omitted entirely when there is no ticket — bus-send.sh parses it with
    # ${2:?...}, which rejects an empty string as hard as a missing one.
    if [ -n "$ticket" ]; then
      "$HERE/bus-send.sh" --room "$room" --type push -t "$ticket" "$subject" >/dev/null 2>"$err" || rc=$?
    else
      "$HERE/bus-send.sh" --room "$room" --type push "$subject" >/dev/null 2>"$err" || rc=$?
    fi

    # The EXIT STATUS is the test, not whether anything was written to stderr.
    # bus-send.sh runs `set -e` over a `code="$(curl -s …)"`, so an unreachable
    # Bus kills it at that line with a silent curl and an empty stderr. Trusting
    # stderr alone would read that as a success, mark the sha announced, and lose
    # the push for good.
    if [ "$rc" -ne 0 ]; then
      detail="$(head -1 "$err" 2>/dev/null || true)"
      [ -n "$detail" ] || detail="bus-send.sh exited $rc (bus unreachable?)"
      # One line on stderr, and we still exit 0: an announcement that could not
      # be sent must never fail the turn. Staying silent would be worse — the
      # feature would look like it was working.
      echo "truxo-bus: could not announce the push to $room: $detail" >&2
      bus_log "announce: post to $room failed: $detail"
    else
      posted="yes"
      bus_log "announce: posted push $sha ($branch) to $room"
    fi
    rm -f "$err"
    # A here-string, not a pipe: a pipe would run this loop in a subshell and
    # `posted` would not survive it.
  done <<< "$rooms"

  # The sha is remembered only if something actually went out, so a post lost to
  # an unreachable Bus is retried on the next push instead of being deduped away.
  if [ -n "$posted" ]; then
    jq -n --arg sha "$sha" '{announced_sha: $sha}' > "$pending.tmp" && mv "$pending.tmp" "$pending"
  else
    rm -f "$pending"
  fi

  exit 0
}

case "$MODE" in
  record) record ;;
  flush)  flush ;;
  *) echo "bus-announce.sh: unknown mode '$MODE' (expected record|flush)" >&2; exit 0 ;;
esac
