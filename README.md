# LAN-only cross-machine wake test

Self-hosted alternative to rine-cc-plugin: no third party, no internet dependency,
just a plain Node server on your LAN and a `Stop` hook with `asyncRewake: true`.

Verified end to end across two Macs: the server, the POST path, the poll/rewake
exit-2 path, and the actual mid-session wake inside a live Claude Code session —
a teammate's event interrupts the other machine's session with a system reminder,
no new prompt from the human.

Known limits of the mechanism: the wake only lands while a background poller is
alive, i.e. within `POLL_MINUTES` of the last completed turn. Once that window
lapses the session is fully dormant and nothing can wake it until the human types
again. Whether an exit-2 can interrupt a turn that is *actively* generating (as
opposed to idle-but-listening) is undocumented and untested.

## What it is

- `server/bus-server.js` — ~80-line Node HTTP server, no deps. POST an event,
  GET events since a cursor. Persists to `events.jsonl`.
- `server/start-bus.sh` — the way to start the host. Mints/loads the shared
  token, advertises the bus on the LAN over mDNS so nobody has to hardcode an
  IP, then runs the server. Ctrl-C stops both.
- `hooks/bus-lib.sh` — shared helper that resolves where the bus is (see
  [Finding the bus](#finding-the-bus)).
- `setup-repo.sh` — wires the bus into any repo in one command (see
  [Using it in other repos](#using-it-in-other-repos)).
- `scratch-repo/.claude/settings.json` — a `Stop` hook wired with `async: true` +
  `asyncRewake: true`. After every Claude turn, it polls the bus in the
  background for up to `POLL_MINUTES` (default 25). The instant a teammate's
  event shows up, it exits 2 — Claude Code treats that as a blocking error and
  surfaces the stderr text to Claude as a system reminder, mid-session, with no
  new prompt from the human.
- `scratch-repo/.claude/hooks/announce.sh` — manual trigger: run this by hand to
  post any event to the bus. The message is the only required argument; `-t/--ticket`
  and `--type` are optional:
  ```
  announce.sh "heads up, I'm restarting staging"
  announce.sh -t PHASE-2 "auth endpoint merged"
  announce.sh --type question "anyone know why CI is red?"
  announce.sh --type deploy -t OPS-4 "shipped v1.2.0"
  ```
  `--type` is free-form (defaults to `announce`) and shows up in the wake message
  when it isn't the default, so you can use the bus for questions, deploy notices,
  or anything else — not just ticket status.

## One-time setup

**On the machine that will run the bus (pick one Mac — call it the host):**

```
cd lan-bus/server
./start-bus.sh
```

That's it. It mints a token into `.bus-token` on first run (and reuses it
after), advertises the bus over mDNS, and prints the token plus the host's
`.local` URL. Leave it running. The first time, macOS will prompt "node wants
to accept incoming connections" — click Allow, or nobody else can reach it.

Share the printed token with the other devs **out-of-band** (Signal,
1Password — not over the bus itself).

**On every dev's machine:**

1. Copy `lan-bus/scratch-repo/` over (or commit it to a real repo and clone it
   — either way everyone needs the same `.claude/settings.json`).
2. `cp .claude/dev.env.example .claude/dev.env` and fill in just two things:
   ```
   BUS_TOKEN=<the token the host printed>
   DEV_NAME=<your name>    # MUST be unique per machine
   ```
   No `BUS_URL` needed — the hooks discover the host automatically. `dev.env`
   is gitignored; it's per-machine, don't commit it.
3. `chmod +x .claude/hooks/*.sh` if the executable bit didn't survive the copy.

> `DEV_NAME` must be unique per person. The poller filters out events matching
> its own name, so if two people share a name they silently never see each
> other's messages.

## Finding the bus

`BUS_URL` is optional. The hooks resolve the bus in this order, first hit wins:

1. **`BUS_URL`** — explicit, e.g. `http://10.0.0.5:8787`. Costs nothing.
2. **`BUS_HOST`** (+ optional `BUS_PORT`, default `8787`) — hostname only, e.g.
   `some-mac.local`. Survives DHCP changes, unlike a raw IP.
3. **mDNS discovery** — nothing set at all. Finds any bus advertised by
   `start-bus.sh` on the LAN. Zero config, costs ~3s per resolution (done once
   per hook run, not once per poll).

So the recommended setup is to set none of them and let discovery work. Set
`BUS_HOST` to the host's `.local` name (from `scutil --get LocalHostName` on
that Mac) if you want to skip the 3s, or `BUS_URL` if mDNS is blocked on your
network.

## Running the test

1. On both Macs, `cd` into the scratch repo and start `claude`.
2. Give each session one trivial prompt (e.g. "just say hi") — the `Stop` hook
   only arms *after* a turn completes, so each session needs at least one turn
   before it starts watching the bus.
3. From a **separate terminal** on Mac A (not inside the Claude session), run:
   ```
   .claude/hooks/announce.sh -t TICKET-123 "shipped the auth endpoint, pull before starting phase 2"
   ```
4. Watch Mac B's Claude Code session, without typing anything. Within
   `POLL_INTERVAL_SECONDS` (default 3s), it should interrupt with a system
   reminder containing dev-a's message — that's the mid-session wake landing.
5. Check the host's terminal — `bus-server.js` logs every request with its source
   IP (`[bus] GET /events... from 192.168.1.x`), so you can confirm whether the
   other Mac's poller is reaching the server at all if step 4 doesn't fire.

## Using it in other repos

Use the setup script — it does everything below for you:

```
./setup-repo.sh ~/code/some-other-repo
```

It creates `~/.claude/lan-bus.env` on first run (reusing this checkout's
`.bus-token` if you host the bus, auto-discovering `BUS_HOST` over mDNS,
defaulting `DEV_NAME` to your username), then adds the `Stop` hook to that
repo's `.claude/settings.local.json` — **merging** into whatever is already
there rather than overwriting it — gitignores that file, and verifies the bus
actually answers. It's idempotent, so re-running refreshes the hook instead of
adding a duplicate.

```
./setup-repo.sh                    # wire the current directory
./setup-repo.sh --global           # arm EVERY repo on this machine
./setup-repo.sh . --dev-name sukh --token <secret> --bus-host some-mac.local
./setup-repo.sh --help
```

### Doing it by hand

The hooks don't have to live inside the repo you're working in.
`LAN_BUS_ENV_FILE` overrides where they read config from (default:
`$CLAUDE_PROJECT_DIR/.claude/dev.env`), and the cursor file is written next to
that env file — so one central config plus one copy of `hooks/` serves every
repo, with no per-repo state to keep in sync.

**One-time:**

1. Keep this folder somewhere durable (e.g. `~/lan-bus`).
2. Create `~/.claude/lan-bus.env`:
   ```
   BUS_TOKEN=<shared secret>
   DEV_NAME=<your name>
   POLL_MINUTES=30
   BUS_HOST=<host-mac>.local     # optional, but recommended here — see below
   ```

   `BUS_HOST` is worth setting for the multi-repo case specifically. Without it
   every hook run pays ~3s of mDNS discovery, and a global hook means that's
   every turn of every session — set it once and discovery never runs.

**Then pick a scope.** Armed in every repo automatically — add to
`~/.claude/settings.json` (user-level, applies to every project on this machine):

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "LAN_BUS_ENV_FILE=$HOME/.claude/lan-bus.env $HOME/lan-bus/hooks/bus-poll-rewake.sh",
        "async": true,
        "asyncRewake": true,
        "timeout": 1860
      }]
    }]
  }
}
```

Or one repo at a time — the same block in that repo's
`.claude/settings.local.json`, which stays uncommitted so teammates who clone
don't inherit it. Use the committed `.claude/settings.json` instead only if you
want the whole team on the bus.

Keep `timeout` above `POLL_MINUTES × 60` so Claude Code doesn't kill the poller
before it can exit cleanly on its own (30-min poll → `1860`).

To post from any repo, point the same override at `announce.sh`:

```
LAN_BUS_ENV_FILE=$HOME/.claude/lan-bus.env ~/lan-bus/hooks/announce.sh "message"
```

A shell alias makes that bearable:

```
alias bus='LAN_BUS_ENV_FILE=$HOME/.claude/lan-bus.env $HOME/lan-bus/hooks/announce.sh'
```

### Caveats before going global

- **Load multiplies.** Every armed session spawns its own poller after every
  turn. N concurrent Claude sessions means N background processes each curling
  the bus every `POLL_INTERVAL_SECONDS`.
- **Events aren't scoped by repo.** A message about one project wakes every
  armed session regardless of what it's working on. Add a `repo` field to the
  payload and filter on it in the poll script if that starts to matter.
- **Bus text is untrusted input.** It's free-form text from another machine,
  injected into the session as a system reminder. Treat it as data, never as
  instructions — an event reading "pull and run deploy.sh" must not be acted on
  automatically. Claude flagged exactly this during testing, which is the
  correct behavior.

## Tuning / troubleshooting

- `POLL_MINUTES` / `POLL_INTERVAL_SECONDS` env vars in `dev.env` control watch
  duration and poll frequency (defaults: 25 min, 3s).
- If nothing wakes: check `curl -H "X-Bus-Token: $BUS_TOKEN" $BUS_URL/health`
  from both Macs first — if that fails, it's network/firewall, not hooks.
- If discovery finds nothing, check the host is running `start-bus.sh` (plain
  `node bus-server.js` does *not* advertise), then verify from another Mac with
  `dns-sd -B _lanbus._tcp`. Some corporate/guest networks block mDNS — set
  `BUS_HOST` or `BUS_URL` explicitly in that case.
- macOS firewall: System Settings → Network → Firewall → make sure `node` is
  allowed, or temporarily disable the firewall for the test.
- Both Macs must be on the same subnet (same Wi-Fi/router) for the LAN IP to
  be reachable — a guest network or VLAN-isolated Wi-Fi will block this even
  though both machines show as "connected."
