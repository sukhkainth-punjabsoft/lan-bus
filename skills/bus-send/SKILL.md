---
name: bus-send
description: Post a one-line Message to the Truxo dev Bus, waking teammates' Claude Code Sessions. Use PROACTIVELY, without being asked, the moment work lands that changes what someone else should do right now — a phase others were blocked on is finished, a shared contract broke, you found something that changes how the rest of the work should be done. Also use when the user asks to tell, notify or update the team.
---

# Post to the dev bus

Sends a one-line **Message** to everyone bound to a **Room**. Their Sessions are
woken mid-task with the Author and the Room — never the text, which they fetch
on purpose with `/bus-inbox`.

You post **without being asked** when the work warrants it. That is the feature,
not a liberty: the person here cannot know their change unblocked someone on
another machine, and you can. The whole of it rests on you judging one question
correctly, so read the next section before anything else.

## The test: does this change what someone else should do RIGHT NOW?

Not "what did I do". Not "is this interesting". **What must someone else now do
differently?** If the honest answer is "nothing, but they'd like to know",
that is a no.

**Post:**

- A phase others were blocked on is finished — "auth middleware merged to main —
  rebase before you touch anything under api/v1".
- A shared contract moved — "the events payload drops `bodyBytes` for documents
  over 256KB; anyone parsing it needs a fallback".
- You discovered something that changes how the rest of the work should be done
  — "the Spool is machine-global, so per-Room cursor files won't fix the theft —
  don't build on that".
- A shared environment is about to move under people — "restarting dev in 5".
- A blocking question for whoever owns an area — you are stopped until they
  answer.
- You are handing work over — attach the handoff as a **Document**.

**Say nothing:**

- "first pass on bus-wake.sh done", "tests pass", "all green", "committed" —
  progress. Nobody is waiting on it.
- "pushed to my branch" — and pushes to shared branches are posted by the
  announce hook already, so posting one yourself is a duplicate Wake.
- "I've read the ADRs, starting on the cursor fix" — an intention, not a change.
- "renamed a variable", "added a test", "tidied the comments".
- Anything you would open with "FYI", "just a heads up", or "quick update".
- Even **"the ticket is done"**, if nobody was waiting on it. Finishing is not
  the trigger; someone else being unblocked is. This is the boundary case people
  get wrong most often.

The bar in one sentence: **would you interrupt three people mid-task to say this
out loud?** If not, silence.

### Why the negatives matter more

An announcement nobody needed is worse than no announcement. It does not cost
one interruption — it teaches the team that the Bus is noise, and the next
Message, the one that really was blocking someone, gets ignored or the machine
gets Paused. You are spending the team's attention, and the balance is not
yours.

The errors are not symmetric, so do not treat them as a coin flip. A post cannot
be recalled. A Message you wrongly withheld can be sent by hand thirty seconds
later, by a person who has all the context you were missing. **When unsure, stay
silent** — and, if it seems close, say in one line what you would have posted
and let the user decide.

## Never announce in a turn that began with a Wake

If this turn started with a Bus Wake — the `Truxo bus: N new message(s)` notice,
or anything you then read with `/bus-inbox` — **do not post automatically in
it.** Finish the work the teammate's Notice prompted, and say nothing back.

This is the loop guard, and it is not politeness. Your post Wakes them, their
Session does work and announces, which Wakes you: agents interrupting each other
with no person in the loop, at machine speed, across the whole team. The hook
enforces the same rule with `stop_hook_active`; you are the half of it that
handles a Session acting on a Notice several turns later.

If the user explicitly asks you to reply to a teammate in such a turn, post it —
that is a human in the loop, which is exactly what the guard exists to require.

## Posting automatically

Check Pause and the rate cap first, send, then record the post. Automatic posts
are capped per Session per hour; posts the user asked for are never capped and
skip this block.

```bash
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
[ -f "$CONFIG_DIR/config.env" ] && source "$CONFIG_DIR/config.env"

# Pause silences this machine in BOTH directions. Inbound Notices are already
# discarded; an automatic post out would break the one promise Pause makes.
[ -f "$CONFIG_DIR/pause" ] && { echo "paused — do not announce"; exit 0; }

RATE="$CONFIG_DIR/announce-rate.json"
# Missing OR half-written: the announce hook writes this file too, so a torn
# read must reset the budget rather than abort the send path silently.
jq -e . "$RATE" >/dev/null 2>&1 || echo '{}' > "$RATE"
# Session-keyed, so one busy Session cannot spend another's budget. The env var
# is undocumented but verified present; the fallback deliberately pools every
# Session on this machine into one bucket, which over-suppresses rather than
# storms.
SID="${CLAUDE_CODE_SESSION_ID:-unknown-session}"
# BSD date — no GNU `-d`. ISO-8601 Z strings sort lexicographically, which is
# why the window is a plain string comparison and not arithmetic.
CUTOFF="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

recent="$(jq --arg sid "$SID" --arg cutoff "$CUTOFF" \
  '[(.[$sid] // [])[] | select(. > $cutoff)] | length' "$RATE")"
[ "$recent" -lt "${BUS_ANNOUNCE_MAX_PER_HOUR:-3}" ] || {
  echo "already announced $recent times this hour — hold it"; exit 0; }

# --room is the Workstream room this Session is bound to; drop the flag and it
# goes to the Repo room, which is a much wider Wake — choose it deliberately.
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" --room "<room>" "<one-line message>"

# Only this Session's key is rewritten, and old timestamps are dropped in the
# same pass so the file stays bounded without a GC. Two Sessions recording at
# once can lose an entry; the cost is one extra post, never a lost Notice, so
# this is not worth a lock.
tmp="$(mktemp)"
jq --arg sid "$SID" --arg cutoff "$CUTOFF" --arg now "$NOW" \
  '.[$sid] = [((.[$sid] // [])[] | select(. > $cutoff)), $now]' "$RATE" > "$tmp" \
  && mv "$tmp" "$RATE"
```

The cap will occasionally swallow a real announcement during a burst of genuine
work. That is the trade on purpose: a missed post can be sent by hand, an
announcement storm cannot be recalled. If you hit the cap on something that
truly blocks someone, tell the user — they can post it themselves.

## Posting because the user asked

No rate cap, and no Pause check — Pause suppresses announcements you decided to
make, not a person deciding to post from their own machine. No confirmation
either when they have told you what to say: send their words, and don't
paraphrase them into something they didn't say. If you are composing the wording
yourself, show them the line first.

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" "restarting dev in 5"
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" --to ravi "can you look at the settlement bug?"
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" --room truxo-3618-hotfix --type deploy -t TRUXO-3618 "patch reverted"
```

It prints `posted to <room> as <name>` on success. `bus not available` means the
Bus isn't on this host — it exists on the dev host only; don't retry. Anything
else, report the code and stop.

Use `--type` when it is more specific than a plain announcement (`deploy`,
`question`, `incident`, `handoff`) and `-t` for a TRUXO key, because both show up
in the Wake line before anyone fetches the Message.

## Choose the narrowest Room that reaches the right people

The Repo room wakes **everyone working on this repo**, including people deep in
unrelated work. Default narrower whenever you can:

| Who needs this | Room |
|---|---|
| One person | `--to <their-name>` — a Direct room only they are bound to |
| A workstream (a hotfix crew, one ticket) | `--room truxo-3618-hotfix` — a Workstream room |
| Everyone on the repo | the default: the Repo room, from the git remote |
| A standing channel | `--room deploys`, `--room incidents` |

A judgement call goes to the Room **this Session is bound to** — the Workstream
room if you joined one for this ticket, the Repo room otherwise. If no teammate
is bound to that Room the Notice wakes nobody and rests in the Spool, which is
fine; that is cheaper than widening to the Repo room to be sure someone hears.

A Workstream room needs no setup — it exists as soon as someone posts to it. But
only Sessions bound to it are woken, and binding is explicit
(`hooks/bus-rooms.sh join <room>`), so if you invent a new Room, say so once in
the Repo room or you are talking to nobody.

Rooms are noise routing, **not** access control: the Bus is unauthenticated, so
anyone who knows a Room's name can join and read it. A Direct room means
"addressed to one person", never "private".

## One line, and a Document for the rest

A **Message** is the headline someone reads to decide whether they care, so it
stays one line — what changed, and what they should do about it, written for
someone with none of your context. "merged the auth refactor — rebase before
touching middleware" beats "done with auth". Never paste a diff, a stack trace,
a file list or a summary of your turn into it.

Long-form goes in a **Document**: up to 256KB, kept 7 days, stored apart from the
Event so it never lands in anyone's Session uninvited.

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" --type handoff --file ./HANDOFF.md \
  "handoff for the bus work — read before touching /api/v1/bus"
```

Teammates see `+ 8KB document` and fetch it deliberately, so write the Message to
stand alone: they must be able to decide whether the Document is worth opening
without opening it.

You are never woken by your own Events; the server filters them out.
