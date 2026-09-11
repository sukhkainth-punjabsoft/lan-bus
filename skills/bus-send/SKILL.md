---
name: bus-send
description: Post a short message to the Truxo dev bus so teammates' Claude Code sessions are woken. Use when the user asks to tell/notify the team, or when work just landed that other developers need to know about — a merge to a shared branch, a breaking change, a restart of a shared environment.
---

# Post to the dev bus

Sends a one-line heads-up to everyone working in this repo. Their sessions wake
with the sender and type; they fetch the text only if they want it.

## Confirm before sending

This is **outward-facing** — it interrupts other people's live sessions. Unless
the user has already said to post (or told you to stop asking), show them the
message you intend to send and get a yes first. Don't paraphrase their words
into something they didn't say.

## Send it

```bash
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
source "$CONFIG_DIR/config.env"

# Room = this repo, derived from its git remote (not the folder name, which
# differs between machines).
ROOM="$(git remote get-url origin \
  | sed -E 's#^git@([^:]+):#https://\1/#' \
  | sed -E 's#^[a-z+]+://[^/]+/##' \
  | sed -E 's#\.git$##' \
  | tr '[:upper:]' '[:lower:]')"

curl -s -w '\n%{http_code}\n' -X POST "$BUS_URL/events" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
      --arg room "$ROOM" \
      --arg dev "$DEV_NAME" \
      --arg devName "${DEV_LABEL:-$DEV_NAME}" \
      --arg message "MESSAGE HERE" \
      --arg type "announce" \
      --arg ticket "" \
      '{room:$room, dev:$dev, devName:$devName, message:$message, type:$type}
       + (if $ticket == "" then {} else {ticket:$ticket} end)')"
```

`201` means sent. `404` means the bus isn't on this host (it exists on dev
only). `400` means a required field is missing — usually `DEV_NAME` isn't set.

Set `--arg type` to `deploy`, `question`, `incident`, etc. when it is more
specific than a plain announcement, and `--arg ticket` to a TRUXO key when there
is one.

## Choose the narrowest room that reaches the right people

The repo room wakes **everyone working on this repo**, including people deep in
unrelated work. Default to something narrower whenever you can:

| Who needs this | `$ROOM` |
|---|---|
| One person | `dm/<their-name>` — only they are listening |
| A workstream (a hotfix crew, one ticket) | its own room, e.g. `truxo-3618-hotfix` |
| Everyone on the repo | the git-remote room (the default) |
| A standing channel | `deploys`, `incidents` |

A room exists as soon as someone posts to it, so a workstream room needs no
setup — but only people who have **joined** it will hear you
(`hooks/bus-rooms.sh join <room>`). If you invent a new room, say so in the
repo room once so people know to join, or nobody is listening.

Rooms are noise routing, **not** access control: the bus is unauthenticated, so
anyone who knows a room's name can join and read it. A `dm/` room means
"addressed to one person", never "private".

## Attaching a document

To send something long — a handoff guide, a spec, a design note — add a `body`
field. Up to 256KB, kept for 7 days. `message` stays a one-line summary:

```bash
jq -n --arg room "$ROOM" --arg dev "$DEV_NAME" --arg devName "${DEV_LABEL:-$DEV_NAME}" \
      --arg message "handoff for the bus work — read before touching /api/v1/bus" \
      --arg type "handoff" \
      --rawfile body ./HANDOFF.md \
      '{room:$room, dev:$dev, devName:$devName, message:$message, type:$type, body:$body}' \
| curl -s -X POST "$BUS_URL/events" -H "Content-Type: application/json" --data-binary @-
```

The document is stored separately and never appears in anyone's listing — the
response returns `bodyBytes`, and teammates see "+ 8KB document" until they ask
for it. So a long paste never lands in someone's session uninvited.

Write the `message` so it stands alone: someone should be able to decide whether
the document is worth opening without opening it.

## What is worth sending

Other people get interrupted, so the bar is "they would want to be stopped for
this":

- **Yes** — merged something on a shared branch others build on; a breaking
  change to shared types, schema or an API contract; about to restart or
  redeploy a shared environment; a blocking question for whoever owns an area.
- **No** — routine local progress, tests passing, a commit on your own branch,
  anything you'd describe as "FYI". Silence is fine.

Keep it to one line, written for someone with none of your context: what
changed, and what they should do about it. "merged the auth refactor — rebase
before touching middleware" beats "done with auth".

You will never be woken by your own messages; the server filters them out.
