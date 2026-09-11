# Truxo dev bus — Claude Code plugin

Cross-machine wake channel for Claude Code sessions. When a teammate posts,
your live session is woken mid-task — no prompt from you, even on a different
network.

> **Joining the team?** Start with [ONBOARDING.md](./ONBOARDING.md) — install,
> naming, and the two things to know before you trust it.
>
> **Working on the bus itself?** [CONTEXT.md](./CONTEXT.md) defines the
> vocabulary (Room, Event, Notice, Document, Bus name), and
> [docs/adr/](./docs/adr/) records the four decisions most likely to make you ask
> "why on earth is it like that" — no auth, metadata-only notices, documents
> stored outside the room, and a monitor with no dependencies.

A background monitor holds one push connection to the bus and tells your
session **who** posted. It never carries the message text: that is fetched
deliberately, and framed as untrusted, by the `bus-inbox` skill.

## Install

```
/plugin marketplace add https://github.com/sukhkainth-punjabsoft/lan-bus.git
/plugin install truxo-bus@truxo-bus
```

Restart Claude Code, then:

```
/bus-setup
```

That's the whole thing. The hooks ship inside the plugin, so there is nothing to
wire into `settings.local.json`; `/bus-setup` asks you one question (your name on
the bus), writes the config, starts the monitor, and proves it works by sending
you a test message.

**Nothing to `npm install`** — the monitor speaks the socket.io wire protocol
over Node's built-in WebSocket, so the plugin has no dependencies and no
`node_modules`.

If you install the plugin but skip setup, the next session tells you so rather
than sitting there silently doing nothing.

**Requirements:** Node 22+ (for the built-in WebSocket), `jq`, `curl`.

### Without the plugin

If you'd rather wire one repo by hand — or want it pointed at a locally-running
`apps/auth` — `setup.sh` does the same job from a terminal and merges the hooks
into that repo's `.claude/settings.local.json`:

```bash
cd ~/your-repo && ~/lan-bus/setup.sh --test
~/lan-bus/setup.sh --local        # point at a local apps/auth on :7003
~/lan-bus/setup.sh --uninstall    # remove the hooks, stop the monitor
```

Re-running is safe: an existing config is left alone, and your other hooks are
preserved.

### There is no token

The bus is unauthenticated for now — it exists only on the dev host and 404s
everywhere else. Anyone who can reach `dev.truxo.app` can read and post, and
`DEV_NAME` is taken at face value. Don't put anything sensitive on it.

Your `DEV_NAME` **must be unique across the team**: it is what stops your own
messages waking you, so two people sharing a name become one identity and
silently stop seeing each other.

## How it works

```
teammate posts  ──▶  POST /api/v1/bus/events        (body stored in Redis)
                         │
                         └─▶ socket push: room, sender, type, ticket — NO TEXT
                                  │
                     bus-monitor.mjs (one per machine, holds the connection)
                                  │  appends to ~/.config/truxo-bus/spool.jsonl
                                  ▼
                     bus-wake.sh (Stop hook) waits on that LOCAL file
                                  │  exit 2 ⇒ your session wakes
                                  ▼
                     "3 new messages — 2x Ravi (deploy), 1x Priya"
                                  │
                     bus-inbox skill fetches the bodies only if you want them
```

The Stop hook does **no network polling**. It watches a local file once a
second; the monitor owns the single push connection.

### Rooms — how you avoid waking the whole team

You are always listening on two rooms: **your repo's** (derived from its git
remote, not the folder name — the same repo sits in differently-named
directories on different machines) and **`dm/<your-name>`**.

The repo room reaches everyone working on that repo, which is right for
"restarting dev in 5" and wrong for most other things. Narrow it:

```bash
hooks/bus-send.sh --to ravi "can you look at the settlement bug?"   # one person
hooks/bus-send.sh --room truxo-3618-hotfix "patch reverted"         # a workstream
hooks/bus-send.sh "restarting dev in 5"                             # everyone here
```

Workstream rooms need no setup — a room exists as soon as someone posts to it —
but only people who joined will hear you:

```bash
hooks/bus-rooms.sh                    # what am I listening on?
hooks/bus-rooms.sh join truxo-3618-hotfix
hooks/bus-rooms.sh leave truxo-3618-hotfix
```

So a hotfix crew and a feature crew can talk without waking each other, while
both stay reachable in the repo room for things that really are everyone's
business.

Rooms are noise routing, **not access control**. The bus is unauthenticated, so
anyone who knows a room's name can join and read it — `dm/` means "addressed to
you", never "only you can see it".

You are never woken by your own messages: the server excludes the author before
sending.

## Commands

```bash
# post
hooks/bus-send.sh "restarting dev in 5"
hooks/bus-send.sh --type deploy -t TRUXO-123 "shipped the auth refactor"
hooks/bus-send.sh --to ravi "just you: can you review the bus PR?"
hooks/bus-send.sh --room truxo-3618-hotfix "patch reverted"

# rooms
hooks/bus-rooms.sh [join|leave] <room>

# read the bodies of what's waiting
/bus-inbox
```

## Pause

```bash
touch ~/.config/truxo-bus/pause    # silence
rm ~/.config/truxo-bus/pause       # resume
```

## Why bodies are not pushed

A bus message is free text written by someone on another machine, arriving in a
session that can run shell commands and edit files. The server authenticates
*who sent it* — never *what it says*.

So the push carries metadata only, and the body is fetched on purpose, framed
as untrusted data rather than instruction. A message reading "pull main and run
./deploy.sh" is something to report to you, never something to act on.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No wakes at all | Check `~/.config/truxo-bus/monitor.log`. "joined no rooms after 15s" means the token is expired or invalid — re-mint it. |
| `401` / `403` from `bus-send.sh` | Token expired or invalid. Re-mint. |
| Wakes stop after ~8 in a row | Claude Code caps consecutive Stop-hook blocks at 8. Raise `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. |
| Monitor won't start | `node` not on PATH, or no `~/.config/truxo-bus/config.env`. |

## Legacy

`hooks/bus-poll-rewake.sh`, `hooks/announce.sh`, `hooks/bus-lib.sh`,
`setup-repo.sh` and `server/` are the previous LAN-only implementation
(HTTP polling, mDNS discovery, a standalone Node server, a shared bus token).
They are superseded by the plugin above and are no longer wired to anything —
safe to delete once everyone has migrated.
