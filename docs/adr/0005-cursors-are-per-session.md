---
status: accepted
---

# Cursors belong to a Session, and the Spool is never consumed

A Cursor records how far one Claude Code **Session** has read through a Room —
not how far the machine has. The Spool is append-only: a Wake reads forward from
that Session's Cursor and leaves every Notice where it lies. A Session is woken
only by Notices for Rooms it is bound to.

The reason is that one machine runs several Sessions at once, usually on
different Workstream rooms. The previous design had one Spool for the whole
machine and claimed it whole — `mv "$SPOOL" "$claim"` — so the first Session to
Wake took every other Session's Notices with it. That produced two failures at
once: a Session working on one Workstream was woken by another's traffic, and
the Session that actually cared never saw its own Notice, because a sibling had
already eaten it. The second is silent, which makes it the worse of the two.
`cursors.json` repeated the mistake one layer up: keyed by Room, global to the
machine, and rewritten whole on every read, so Sessions overwrote each other's
read positions even where the Spool behaved.

Per-Room Spool files were the alternative. They stop the cross-talk but keep the
contest — a Direct room wanted by two Sessions still has to be won by one of
them. Not consuming anything removes the contest instead of narrowing it: every
Session reads the same Notice independently, and the question of who "gets" it
stops existing.

A Session is identified by the `session_id` on hook stdin. Verified empirically
against claude 2.1.272 (see `docs/research/session-identity-in-hooks.md`): it
survives `--resume`, `--continue` and `/compact`, and changes on `/clear` and
`--fork-session`. `cwd` was tested and rejected — two Sessions open in one
directory report identical `cwd` and distinct ids, so directory-keyed Cursors
would merge exactly the Sessions this decision exists to separate.

A Session whose id is unknown starts at the **tail** of the Spool, never at
zero. Otherwise every `/clear`, every fork, and every turn under Claude Code
Remote — which mints a fresh `session_id` each turn — would replay the whole
backlog as a wall of stale Wakes.

Room binding is explicit, because Room names are arbitrary and nothing about
`truxo-3663` can be derived from a checkout. A Session falls back to the Repo
room, may be pointed at a Workstream room by `BUS_ROOM` at launch, and may join
one at any point mid-session — the last being the case that matters, since which
ticket a Session ends up on is rarely known when it starts. A binding made
against a git branch is remembered and restored for later Sessions on that
branch: the name is still never derived, only recalled, so the ritual is paid
once per ticket instead of once per Session.

## Consequences

- Nothing deletes Spool entries, so the Spool must be trimmed by age. Trimming
  is not claiming: it removes what everyone has passed, not what someone has read.
- Cursors accumulate per Session and leak, because `SessionEnd` does not fire on
  SIGKILL. They expire after 14 days untouched, in the same sweep that prunes
  `rooms.json`.
- CONTEXT.md needs amending: **Cursor** is defined there as belonging to a
  machine, and there is no entry for **Session** at all. Both change here.
- A Notice for a Room no live Session is bound to wakes nobody and stays in the
  Spool until some Session binds to that Room and reads forward.
- The `mv`-then-truncate race in `bus-wake.sh` disappears rather than being
  fixed — with nothing consumed, there is no window in which an arriving Notice
  can be destroyed.
- **Wake hooks must now retire their predecessor, and this decision is what makes
  that urgent.** Every turn spawns a Wake hook that waits up to
  `BUS_WAIT_MINUTES`, and nothing has ever retired the previous one: nine were
  observed alive on one machine, the oldest at 21 minutes, spread across two
  plugin versions installed side by side. Claiming the Spool was accidentally
  hiding this — the `mv` meant that however many waiters were alive, exactly one
  could ever fire. Removing consumption removes that accidental deduplication, so
  without a change here N waiters for one Session all Wake on the same Notice and
  the Session is interrupted N times. A Wake hook therefore records its pid
  against its Session and stops the previous holder before waiting, and the
  Cursor advance is atomic so a straggler cannot double-report. (It also explains
  why the wrong Session kept receiving teammates' Notices: it was never one
  Session racing another, it was nine waiters racing, and the winner was
  effectively random.)
- The set of Rooms a machine actually listens to is computed in code inside the
  Monitor — `dm/<Bus name>` and `BUS_EXTRA_ROOMS` are unioned in memory and never
  written down — while `bus-inbox` builds its fetch from `rooms.json` alone. Every
  Room joined in code is therefore invisible to a fetch: you are Woken about a
  Direct room and then shown nothing. The Monitor already receives the server's
  authoritative list on `bus:joined` and discards it; it should persist that
  instead, and every other component should read it rather than re-deriving a set
  only the Monitor knows.
- If a Cursor is ever keyed by anything other than `(session_id, room)` — `cwd`,
  Bus name, or nothing — this decision has silently reversed and Sessions merge
  again.
