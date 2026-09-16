# Dev Bus

A cross-machine wake channel for Claude Code sessions. A developer posts; their
teammates' live sessions are interrupted mid-task and told someone has something
for them. It exists so that work happening on one machine can reach a person
working on another, without either of them checking anything.

The server lives in the Truxo monorepo (`apps/auth`, mounted at
`/api/v1/bus`); the client — hooks, skills, the monitor — lives here. This
glossary is shared by both.

## Language

### The channel

**Bus**:
The channel as a whole: the server, the rooms, and every machine listening.
_Avoid_: queue, feed, channel (a "channel" is a Room here)

**Room**:
A named stream that events are posted to and listened on. The unit of routing,
and the only way to control who gets woken.
_Avoid_: channel, topic, group

**Repo room**:
The room every developer working on a git repository shares, named after its
remote. Joined automatically; the default destination for a post.
_Avoid_: project room, team room

**Direct room**:
A room belonging to one person, which only they join by default. Addressed, not
private — anyone who knows its name can listen.
_Avoid_: DM, private message, inbox

**Workstream room**:
A room created ad hoc for a piece of work — a hotfix, a ticket, a migration — so
the people on it can talk without waking everyone in the Repo room. Exists as
soon as someone posts to it.
_Avoid_: ad-hoc channel, thread

### What gets sent

**Event**:
One posted item: who sent it, to which room, when, and what they wrote. The
durable thing a Room holds.
_Avoid_: message (that is the headline only), post, item

**Message**:
The one-line headline of an Event — what a person reads to decide whether they
care. Deliberately short.
_Avoid_: body, text, content

**Document**:
Optional long-form text attached to an Event: a handoff guide, a spec, a log.
Stored apart from the Event and kept for a limited time.
_Avoid_: body, attachment, payload, blob

**Announcement**:
An Event a Session posts on its own initiative rather than at a person's request
— a push, or a judgement that the work changes what someone else should do now.
Never capped when a human asked for it; capped per Session per hour when not.
_Avoid_: auto-post, notification, broadcast

**Notice**:
What the Bus pushes to a listening machine when an Event is posted: who sent it,
to which Room, and whether a Document is attached — never the Message or the
Document itself.
_Avoid_: notification, alert, ping, event (a Notice is not an Event)

### Who is who

**Bus name**:
The identity a person posts under and is addressed by. Self-asserted and
normalised, so it must be unique across the team — two people sharing one become
a single identity and stop seeing each other.
_Avoid_: username, dev, handle, user id

**Label**:
The human-readable name shown to teammates alongside a Bus name.
_Avoid_: display name, nickname

**Author**:
The Bus name that posted an Event. Never woken by their own Events.
_Avoid_: sender, owner

> **Note on "dev".** The field carrying a Bus name is `dev`, and the environment
> the Bus runs in is also called dev (`deployEnv === "dev"`, `dev.truxo.app`).
> They are unrelated. Prefer **Bus name** for the person and **the dev host** for
> the environment; `dev` on its own is ambiguous in this codebase.

### On each machine

**Monitor**:
The single background process per machine that holds the Bus connection and
records incoming Notices. Independent of any one session.
_Avoid_: daemon, listener, client, agent

**Spool**:
The local record of Notices that have arrived but not yet been shown to a
session.
_Avoid_: queue, buffer, inbox

**Wake**:
The interruption of a live Claude Code session to tell it Notices are waiting.
The point of the whole system.
_Avoid_: notify, ping, trigger, rewake

**Session**:
One live Claude Code conversation, identified by the id its hooks are handed.
The thing a Wake interrupts and a Cursor belongs to. Several run at once on one
machine, usually on different Rooms — which is why neither is a property of the
machine.
_Avoid_: window, tab, conversation, client

**Binding**:
The set of Rooms a Session is woken for. Always explicit, because Room names are
arbitrary and nothing about a Workstream room can be read off a checkout.
Distinct from the Monitor's join: the Monitor joins every Room the machine
listens to, a Binding decides which of them reach a given Session.
_Avoid_: subscription, membership, join (that is the Monitor's word)

**Cursor**:
How far through a Room one Session has already read. Kept per Session and Room,
so two Sessions on one machine stay caught up independently and neither consumes
the other's Notices.
_Avoid_: offset, position, watermark

**Pause**:
The state in which a Monitor stays connected but discards Notices instead of
recording them. Nothing is banked to arrive later.
_Avoid_: mute, snooze, disable
