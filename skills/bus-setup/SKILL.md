---
name: bus-setup
description: Set up the Truxo dev bus for this machine — pick a bus name, write the config, start the monitor. Use when the user asks to set up or configure the bus, or when a session-start notice says the bus is not configured yet.
---

# Set up the dev bus

One config file. The hooks already came with the plugin, so there is nothing to
wire by hand.

## 1. Check whether it's already done

```bash
cat "${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}/config.env" 2>/dev/null \
  || echo "NOT CONFIGURED"
```

If it exists, don't rewrite it — show the user their `DEV_NAME` and skip to
step 4.

## 2. Pick a bus name

Suggest `git config user.name` lowercased, or `whoami`. Then **confirm it with
the user** before writing, because:

- it is how teammates see them, and
- it must be **unique across the team** — two people sharing a name become one
  identity and silently stop seeing each other's messages. If their natural name
  is something generic like `dev` or `admin`, say so and suggest a distinct one.

## 3. Write the config

```bash
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.env" <<'EOF'
BUS_URL=https://dev.truxo.app/api/v1/bus
BUS_ORIGIN=https://dev.truxo.app
DEV_NAME=<their-name>
DEV_LABEL="<Their Display Name>"
BUS_WAIT_MINUTES=30
EOF
chmod 600 "$CONFIG_DIR/config.env"
```

For a locally-running `apps/auth`, use `http://localhost:7003` for both
`BUS_ORIGIN` and the host in `BUS_URL` instead.

`DEV_LABEL` must be **quoted** — the shell hooks `source` this file, so an
unquoted value containing a space breaks the whole config.

There is no token: the bus is unauthenticated and exists only on the dev host.
Say that plainly — anyone who can reach it can read and post, so nothing
sensitive belongs on it.

## 4. Start the monitor and confirm it works

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/bus-monitor-start.sh"
sleep 3
tail -3 "${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}/monitor.log"
```

Look for `listening as <name> on: <room>`. Anything else means it did not
connect — read the log and tell the user what it says rather than guessing.

`joined no rooms after 15s` means the server refused the join, almost always
because the bus isn't enabled on that host (it exists on dev only).

## 5. Prove it end to end

The bus never wakes someone with their own message, so testing as themselves
proves nothing. Post as a throwaway second identity:

```bash
CONFIG_DIR="${TRUXO_BUS_CONFIG_DIR:-$HOME/.config/truxo-bus}"
ME="$(grep -E '^DEV_NAME=' "$CONFIG_DIR/config.env" | cut -d= -f2 | tr -d ' "')"
FAKE="$(mktemp -d)"
sed 's/^DEV_NAME=.*/DEV_NAME=setup-test/; s/^DEV_LABEL=.*/DEV_LABEL="Setup Test"/' \
  "$CONFIG_DIR/config.env" > "$FAKE/config.env"
TRUXO_BUS_CONFIG_DIR="$FAKE" "${CLAUDE_PLUGIN_ROOT}/hooks/bus-send.sh" \
  --to "$ME" "bus-setup test — if this wakes you, it works"
rm -rf "$FAKE"
```

`--to "$ME"` keeps the test in your own inbox. Without it the test lands in the
repo room and wakes the whole team — every time anybody sets the bus up.

Then tell them: the message is queued, and their session will surface it when
the current turn ends. They'll see the sender and a count — not the text, which
is fetched on purpose with `/bus-inbox`.

## Done

Tell them what they can now do, briefly: the bus wakes them when a teammate
posts, `/bus-send` posts a message, `/bus-inbox` reads what's waiting, and
`touch ~/.config/truxo-bus/pause` silences it.
