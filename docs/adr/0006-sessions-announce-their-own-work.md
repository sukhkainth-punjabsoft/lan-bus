---
status: accepted
---

# Sessions announce their own work, and judge what is worth announcing

A Session posts Events without being asked. Two triggers, and they are not the
same kind of thing: a push to a branch someone else is working on is a fact, so
a hook posts it; whether a piece of work unblocks a teammate is a judgement, so
the Session decides and posts through the send skill.

The test the Session applies is **"does this change what someone else should do
right now?"** — a phase finished that others were waiting on, a discovery that
changes how the rest of the work should be done. Not "what did I do." Routine
progress is silence. That distinction is the whole feature: an announcement
nobody needed is worse than no announcement, because it teaches people to
ignore the Bus.

Announcing on Stop was the obvious implementation and is wrong. Stop fires after
**every** turn, so it would post several times a minute, and the Bus would be
muted by everyone within a day. Stop stdin does carry `last_assistant_message`,
so a hook could pattern-match prose for signs of completion — but that is a bash
script guessing at intent, and its errors are broadcast to the team. Judgement
belongs to the thing capable of it.

Posting without a human reviewing each one is acceptable only because of
ADR 0002. A Notice carries who and where, never the Message, so a misjudged
announcement costs a teammate one line — "Sukh posted in truxo-3663" — and the
text is read only if they choose to fetch it. A confirmation step would buy
little and cost the immediacy that makes the feature worth having.

Automatic announcement introduces a hazard manual posting does not have. A
Session that announces can Wake a teammate's Session, which does work, which
announces, which Wakes the first — agents waking each other with no person in
the loop. Two guards, because the first is exact and the second is a backstop: a
Session never announces in a turn that was itself begun by a Wake, using the
`stop_hook_active` flag Claude Code already passes for this class of problem;
and automatic posts are capped per Session per hour. Posts a human explicitly
asked for are never capped.

## Consequences

- Pushes to shared branches go to the Repo room; work on a Workstream branch and
  judgement calls go to the Room the Session is bound to. No membership lookup is
  needed — if no teammate is in that Room, the Notice wakes nobody and rests in
  the Spool (ADR 0005).
- The send skill's description is now load-bearing. It is what the Session reads
  to decide whether to post, so the criterion above lives there, not in code.
- Pause silences a machine in both directions: it already discards inbound
  Notices, and it now suppresses automatic announcements too.
- The rate limit will occasionally swallow a legitimate announcement during a
  burst of real work. Accepted: a missed automatic post can be sent by hand, an
  announcement storm cannot be recalled.
- If an automatic post is ever made from a turn where `stop_hook_active` is set,
  the loop guard has been lost and the Bus can cascade.
