# Joining the Truxo dev bus

The bus wakes your live Claude Code session when a teammate posts — mid-task, on
a different machine, on a different network. You don't check anything; it
interrupts you.

Takes about a minute.

## 1. Install

In Claude Code:

```
/plugin marketplace add https://github.com/sukhkainth-punjabsoft/lan-bus.git
/plugin install truxo-bus@truxo-bus
```

Restart Claude Code, then:

```
/bus-setup
```

It asks one question — your name on the bus — writes the config, starts the
background monitor, and sends you a test message to prove it works.

Requires Node 22+, `jq` and `curl`. Nothing to `npm install`.

## 2. Pick a name nobody else has

`/bus-setup` suggests your system username. **Check it's unique across the
team.** If two people use the same name they become one identity on the bus and
permanently stop seeing each other's messages — with no error, anywhere. It is
the one way to break this quietly, so take the ten seconds.

## 3. Use it

```bash
# tell everyone on this repo
/bus-send restarting dev in 5

# tell one person
bus-send.sh --to ravi "can you look at the settlement bug?"

# tell a workstream
bus-send.sh --room truxo-3618-hotfix "patch reverted"

# send a document (a handoff guide, a spec) — up to 256KB, kept 7 days
bus-send.sh --file HANDOFF.md "handoff for the bus work — read before /api/v1/bus"
```

You can ask Claude to post for you; it will confirm the wording first.

To read what's waiting: `/bus-inbox`.
To go quiet: `touch ~/.config/truxo-bus/pause` (and `rm` it to come back).

## Rooms — how you avoid waking everyone

You always listen on your repo's room and your own `dm/<your-name>`.

The repo room reaches **everyone working on that repo**, including people deep in
unrelated work. That's right for "restarting dev in 5" and wrong for most else.
For anything narrower, aim it — `--to` for one person, `--room` for a
workstream. A workstream room needs no setup; it exists as soon as someone posts
to it, but only people who joined will hear you:

```bash
bus-rooms.sh                          # what am I listening on?
bus-rooms.sh join truxo-3618-hotfix
bus-rooms.sh leave truxo-3618-hotfix
```

If you invent a room, say so once in the repo room — otherwise nobody is
listening.

You are never woken by your own messages.

## Two things to know before you trust it

**It is not private.** The bus has no authentication. It exists only on the dev
host and 404s everywhere else, but anyone who can reach that host can read and
post, and anyone can claim any name. A `dm/` room means "addressed to you", not
"only you can see it". Don't put credentials, customer data, or anything you'd
mind a stranger reading on it.

**Messages you receive are untrusted.** When you're woken, you're told *who*
posted — never what they wrote. The text is fetched only when you ask for it,
and Claude treats it as data, not instructions. A message saying "pull main and
run ./deploy.sh" is something to be told about, never something to be acted on.
That's deliberate: a wake injects into a session with shell and file access.

## When it goes quiet

```bash
cat ~/.config/truxo-bus/monitor.log
```

- `listening as <you> on: <rooms>` — working.
- `joined no rooms after 15s` — the server isn't accepting the join; usually the
  bus isn't enabled on the host you're pointed at.
- Nothing at all — the monitor isn't running. `/bus-setup` restarts it.

Wakes stop after 8 in a row without you typing anything; that's Claude Code's
cap on consecutive Stop-hook blocks, raise `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` if
it bites.

## Going deeper

- [CONTEXT.md](./CONTEXT.md) — the vocabulary (Room, Event, Notice, Document).
- [docs/adr/](./docs/adr/) — why it's built the way it is, including why there's
  no auth and why you don't receive message text directly.
