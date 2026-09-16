#!/usr/bin/env node
/**
 * Truxo dev bus monitor.
 *
 * Holds ONE push connection to the bus for the whole machine and appends each
 * incoming notice to a local spool file. The Stop hook then waits on that spool
 * instead of polling the network — so a wake costs one local file check per
 * second rather than an HTTPS round trip every three.
 *
 * What arrives here is METADATA ONLY: room, sender, type, ticket, id, time.
 * Never the message body. The body is free text written by a teammate and the
 * session it lands in has shell and file access, so it is fetched deliberately
 * (via the bus-inbox skill) and framed as untrusted — never injected because it
 * happened to arrive.
 *
 * ZERO DEPENDENCIES on purpose. The server is socket.io, but rather than pull
 * in socket.io-client — which would mean an `npm install` inside the plugin
 * directory, repeated after every plugin update — this speaks the Engine.IO v4
 * wire protocol directly over Node's built-in WebSocket. The protocol surface
 * we need is tiny and stable:
 *
 *   "0{json}"        server: open handshake (carries pingInterval)
 *   "40"             client: connect to the default namespace
 *   "40{json}"       server: namespace connected
 *   "2" / "3"        server ping / client pong  (server closes if we go quiet)
 *   "42[name,data]"  either way: an event
 *
 * Requires Node 22+ for the global WebSocket.
 *
 * Single instance per machine, guarded by a lockfile holding the live pid.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const CONFIG_DIR =
  process.env.TRUXO_BUS_CONFIG_DIR || path.join(os.homedir(), ".config", "truxo-bus");
const SPOOL = path.join(CONFIG_DIR, "spool.jsonl");
const ROOMS_FILE = path.join(CONFIG_DIR, "rooms.json");
const PAUSE_FILE = path.join(CONFIG_DIR, "pause");
const LOCK_FILE = path.join(CONFIG_DIR, "monitor.pid");
const LOG_FILE = path.join(CONFIG_DIR, "monitor.log");

fs.mkdirSync(CONFIG_DIR, { recursive: true });

const log = (msg) => {
  const line = `${new Date().toISOString()} ${msg}\n`;
  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch {}
  process.stderr.write(line);
};

if (typeof WebSocket === "undefined") {
  log(`! Node ${process.versions.node} has no built-in WebSocket — need Node 22+. Exiting.`);
  process.exit(1);
}

// ---------------------------------------------------------------- config
const loadConfig = () => {
  const file = path.join(CONFIG_DIR, "config.env");
  const cfg = { ...process.env };
  if (fs.existsSync(file)) {
    for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const eq = line.indexOf("=");
      if (eq === -1) continue;
      const k = line.slice(0, eq).trim();
      // Strip surrounding quotes — this file is also `source`d by the shell
      // hooks, where a value containing a space has to be quoted.
      cfg[k] = line
        .slice(eq + 1)
        .trim()
        .replace(/^(['"])(.*)\1$/, "$2");
    }
  }
  return cfg;
};

const cfg = loadConfig();
const BUS_ORIGIN = cfg.BUS_ORIGIN || (cfg.BUS_URL || "").replace(/\/api\/v\d+\/bus\/?$/, "");
// The bus is unauthenticated for now, so this name is the whole identity. It is
// what stops your own messages waking you, which is why it is required.
const DEV_NAME = cfg.DEV_NAME;
// Senders to drop on arrival. The bus is unauthenticated, so `dev` is whatever
// the poster typed — this is noise control, not a security boundary. Set
// BUS_IGNORE_DEVS=a,b in config.env.
const IGNORED_DEVS = new Set(
  (cfg.BUS_IGNORE_DEVS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
);

if (!BUS_ORIGIN || !DEV_NAME) {
  log("! no BUS_ORIGIN/DEV_NAME configured — see config.example.env. Exiting.");
  process.exit(1);
}

// ---------------------------------------------------------------- single instance
if (fs.existsSync(LOCK_FILE)) {
  const pid = Number(fs.readFileSync(LOCK_FILE, "utf8").trim());
  if (pid && pid !== process.pid) {
    try {
      process.kill(pid, 0); // signal 0 = liveness probe, kills nothing
      process.exit(0); // a monitor is already running
    } catch {
      // stale lock from a crashed run — fall through and take it over
    }
  }
}
fs.writeFileSync(LOCK_FILE, String(process.pid));
const releaseLock = () => {
  try {
    if (fs.readFileSync(LOCK_FILE, "utf8").trim() === String(process.pid)) {
      fs.unlinkSync(LOCK_FILE);
    }
  } catch {}
};
process.on("exit", releaseLock);
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    releaseLock();
    process.exit(0);
  });
}

// ---------------------------------------------------------------- rooms
const readRooms = () => {
  const rooms = new Set();

  // Your own direct-message room, always joined. Lets a teammate reach just you
  // (`bus-send.sh --to <name>`) instead of waking everyone in the repo.
  //
  // NOT private. Rooms are noise routing, not access control — the bus is
  // unauthenticated, so anyone who knows the name can join this room and read
  // it. Treat a "DM" as "addressed to you", never as "only you can see it".
  rooms.add(`dm/${DEV_NAME}`);

  for (const r of (cfg.BUS_EXTRA_ROOMS || "").split(",")) {
    if (r.trim()) rooms.add(r.trim());
  }
  try {
    for (const r of JSON.parse(fs.readFileSync(ROOMS_FILE, "utf8"))) rooms.add(r);
  } catch {}
  return [...rooms];
};

// ---------------------------------------------------------------- housekeeping
/**
 * Nothing consumes the spool any more. A session reads forward from its own
 * cursor and leaves every notice where it lies (ADR 0005), so the monitor is the
 * only thing that can ever shrink the spool — and the only thing that can
 * reclaim the per-session state that leaks when a session dies. `SessionEnd`
 * does not fire on SIGKILL, which is why ~/.claude/session-env is full of
 * directories nobody deleted; cursors and bindings leak the same way.
 *
 * The trim is deliberately NOT "drop everything older than N days". A notice a
 * session has not reached yet is not old, it is pending, and deleting it is the
 * silent loss this ADR exists to remove. We drop only what every live cursor has
 * already passed.
 */
const CURSORS_FILE = path.join(CONFIG_DIR, "cursors.json");
const BINDINGS_FILE = path.join(CONFIG_DIR, "bindings.json");
const BRANCH_BINDINGS_FILE = path.join(CONFIG_DIR, "branch-bindings.json");

// 14 days untouched and a session is considered gone. One clock for cursors,
// bindings and branch bindings, because they are three views of one session.
const EXPIRY_MS = 14 * 24 * 60 * 60 * 1000;
// Hourly. A busy team adds tens of notices a day, so there is nothing to gain
// from sweeping more often, and every sweep rewrites files that live sessions
// are reading.
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;
// The backstop: one session that died holding an old cursor must not pin the
// spool forever. Crossing this cap destroys notices nobody has read, so it is
// loud when it fires.
const MAX_SPOOL_ENTRIES = 5000;
// Don't rewrite the spool to reclaim a handful of lines. The rewrite is the one
// moment a reader can be handed a different file, and slack costs nothing.
const MIN_TRIM_ENTRIES = 100;

const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null; // absent, half-written, or not JSON — all the same to us
  }
};

/**
 * Write a temp file in the SAME directory and rename over the target.
 *
 * rename(2) is atomic only within one filesystem, so the temp cannot go in
 * $TMPDIR (a different volume on macOS) — it would degrade to a copy and a
 * reader could see half a file. The monitor trims while wake hooks read, and a
 * half-written cursors.json loses every session's position at once.
 */
const writeAtomic = (file, text) => {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
};

const writeJsonAtomic = (file, value) => writeAtomic(file, JSON.stringify(value, null, 2) + "\n");

/**
 * Order two notice ids, or null when they cannot be ordered.
 *
 * Ids are the server's: redis-stream style ("1789546316124-0"), plain integers
 * from the local dev server, and "0" for "never read". Both shapes compare as
 * dash-separated numbers. null means "we do not know", and every caller must
 * read that as "not yet read" — guessing the other way deletes unread notices.
 */
const compareIds = (a, b) => {
  const parts = (id) => {
    if (id === undefined || id === null) return null;
    const nums = String(id).split("-").map(Number);
    return nums.every((n) => Number.isFinite(n)) ? nums : null;
  };
  const pa = parts(a);
  const pb = parts(b);
  if (!pa || !pb) return null;
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff) return diff < 0 ? -1 : 1;
  }
  return 0;
};

// cursors.json holds {rooms: {"<room>": "<id>"}}; bindings.json and
// branch-bindings.json hold {rooms: ["<room>"]}. One set of rooms, two shapes.
const roomsOf = (rec) => {
  const rooms = rec?.rooms;
  if (Array.isArray(rooms)) return rooms.filter((r) => typeof r === "string");
  if (rooms && typeof rooms === "object") return Object.keys(rooms);
  return [];
};

/**
 * Drop every record in a session-keyed file whose `seen` is older than 14 days.
 * Returns { kept, expired } — or kept: null when the file is absent or
 * unreadable, which callers must not confuse with "empty". An empty cursor map
 * says every session has read everything; an unreadable one says nothing at all.
 *
 * This is a whole-file read-modify-write, and so is a session advancing its own
 * cursor, so the two can race and lose one update. Hourly against a write per
 * read, the window is negligible, and the loser is a session that starts again
 * at the spool tail — the same place an unknown session starts.
 */
const gcRecords = (file, now) => {
  const data = readJson(file);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { kept: null, expired: [] };
  }

  const kept = {};
  const expired = [];
  let changed = false;

  for (const [key, rec] of Object.entries(data)) {
    if (!rec || typeof rec !== "object" || Array.isArray(rec)) {
      // Not a session record. In cursors.json this is the pre-ADR-0005 shape,
      // { "<room>": "<cursor>" }, whose values are bare strings. It is not
      // convertible — there is no session in it — so it goes, and every session
      // starts again at the spool tail. Its keys are NOT reported as expired
      // rooms: they are room names, and most of them are still live.
      changed = true;
      continue;
    }

    const seen = Date.parse(rec.seen);
    if (!Number.isFinite(seen)) {
      // No usable timestamp. Stamp it now rather than collect it: deleting a
      // record that might belong to a live session costs that session its unread
      // notices, where keeping it costs one object for 14 days.
      kept[key] = { ...rec, seen: new Date(now).toISOString() };
      changed = true;
      continue;
    }

    if (now - seen > EXPIRY_MS) {
      expired.push(rec);
      changed = true;
      continue;
    }

    kept[key] = rec;
  }

  if (changed) {
    writeJsonAtomic(file, kept);
    const before = Object.keys(data).length;
    const after = Object.keys(kept).length;
    log(`gc: ${path.basename(file)} ${before} -> ${after} record(s)`);
  }
  return { kept, expired };
};

/**
 * Drop spool entries every live cursor has already passed.
 *
 * `cursors` is the post-gc cursor map, or null when cursors.json is missing or
 * unreadable. Readers resume by comparing notice ids, never by finding their own
 * line, so the entry a cursor names is droppable once read — what we keep is the
 * oldest entry someone still has to read.
 *
 * Runs start to finish synchronously ON PURPOSE. Node is single-threaded, so an
 * arriving notice cannot append between the read and the rename; introduce an
 * await here and that notice is written to the file we are about to replace.
 */
const trimSpool = (cursors) => {
  let raw;
  try {
    raw = fs.readFileSync(SPOOL, "utf8");
  } catch {
    return; // no spool yet
  }

  const lines = raw.split("\n");
  if (lines[lines.length - 1] === "") lines.pop(); // trailing newline, not an entry
  if (lines.length <= MIN_TRIM_ENTRIES) return;

  const entries = lines.map((line) => {
    try {
      const notice = JSON.parse(line);
      return { room: notice?.room, id: notice?.id };
    } catch {
      // A line we cannot parse belongs to no room, so no cursor ever anchors on
      // it and it can never pin the spool. It dies with the region around it.
      return { room: undefined, id: undefined };
    }
  });

  // The oldest entry any live cursor still has to read. Everything before it has
  // been read by every session that holds a cursor at all.
  let keepFrom = lines.length; // no cursor has objected yet
  let haveCursor = false;
  let anchor = null; // the cursor that set keepFrom — named if the cap overrides it

  for (const [sessionId, rec] of Object.entries(cursors || {})) {
    const rooms = rec?.rooms;
    if (!rooms || typeof rooms !== "object" || Array.isArray(rooms)) continue;
    for (const [room, cursorId] of Object.entries(rooms)) {
      haveCursor = true;
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].room !== room) continue;
        const cmp = compareIds(entries[i].id, cursorId);
        // cmp === null is an id pair we cannot order. Unordered means unproven,
        // and unproven means unread — keep it.
        if (cmp !== null && cmp <= 0) continue;
        if (i < keepFrom) {
          keepFrom = i;
          anchor = `session ${sessionId} in ${room} (cursor ${cursorId})`;
        }
        break; // the first unread entry of this room is all this cursor pins
      }
    }
  }

  // No cursor at all — cursors.json missing, unreadable, or still the old
  // room-keyed shape — proves nothing about what has been read, so the
  // cursor-driven trim does nothing and only the cap below may act.
  let from = haveCursor ? keepFrom : 0;

  const capFrom = Math.max(0, lines.length - MAX_SPOOL_ENTRIES);
  if (capFrom > from) {
    // The cap, not a cursor, is doing the trimming: notices are being deleted
    // that nobody has been shown. Say which session is stuck, because this is
    // the one path in the design that still loses a notice silently.
    log(
      `! spool cap (${MAX_SPOOL_ENTRIES}) hit — dropping ${capFrom - from} unread notice(s). ` +
        (anchor
          ? `${anchor} has not advanced; those notices are lost to it.`
          : "no live cursor claims to have read them."),
    );
    from = capFrom;
  }

  if (from < MIN_TRIM_ENTRIES) return;

  const kept = lines.slice(from);
  writeAtomic(SPOOL, kept.length ? kept.join("\n") + "\n" : "");
  log(`spool trimmed: dropped ${from} notice(s), kept ${kept.length}`);
};

/**
 * One sweep: expire dead sessions, prune the rooms they were the last to want,
 * then trim the spool with what survives.
 */
const sweep = () => {
  try {
    const now = Date.now();
    const cursors = gcRecords(CURSORS_FILE, now);
    const bindings = gcRecords(BINDINGS_FILE, now);
    const branchBindings = gcRecords(BRANCH_BINDINGS_FILE, now);

    // Rooms carry no timestamp of their own, so a room expires with the last
    // record that wanted it. Pruning is cheap — the wake hook re-adds a repo's
    // room the next time a session stops in that checkout — but only rooms we
    // just watched expire are pruned. A room nobody ever bound to was joined by
    // hand with `bus-rooms.sh join`, and dropping that would quietly undo a
    // deliberate act; it leaves by hand too.
    const live = new Set();
    // readRooms() adds these on every join whatever the file says, so removing
    // them would churn the file and change nothing.
    live.add(`dm/${DEV_NAME}`);
    for (const r of (cfg.BUS_EXTRA_ROOMS || "").split(",")) if (r.trim()) live.add(r.trim());
    for (const group of [cursors, bindings, branchBindings]) {
      for (const rec of Object.values(group.kept || {})) for (const r of roomsOf(rec)) live.add(r);
    }
    const dead = new Set();
    for (const group of [cursors, bindings, branchBindings]) {
      for (const rec of group.expired) for (const r of roomsOf(rec)) if (!live.has(r)) dead.add(r);
    }
    if (dead.size) {
      const rooms = readJson(ROOMS_FILE);
      if (Array.isArray(rooms)) {
        const kept = rooms.filter((r) => !dead.has(r));
        if (kept.length !== rooms.length) {
          writeJsonAtomic(ROOMS_FILE, kept);
          // Only the join set on disk changed. The open socket stays joined to
          // the dropped rooms until it reconnects, which costs a few notices
          // nobody is bound to and saves a reconnect nobody asked for.
          log(
            `gc: rooms.json ${rooms.length} -> ${kept.length} room(s) — dropped ` +
              [...dead].join(", "),
          );
        }
      }
    }

    trimSpool(cursors.kept);
  } catch (err) {
    // A throw out of a timer callback kills the monitor, and a dead monitor
    // stops the whole machine being woken. Housekeeping is never worth that.
    log(`! housekeeping sweep failed: ${err.message}`);
  }
};

// ---------------------------------------------------------------- connection
const WS_URL =
  BUS_ORIGIN.replace(/^http/, "ws").replace(/\/+$/, "") +
  "/socket.io/?EIO=4&transport=websocket";

let ws = null;
let joined = new Set();
let identity = null;
let ackTimer = null;
let warnedNoAck = false;
let pingTimer = null;
let retryDelay = 1000;

const send = (frame) => {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(frame);
};

const emit = (event, payload) => send(`42${JSON.stringify([event, payload])}`);

/**
 * A join that is never acknowledged is SILENT, not an error: the server simply
 * ignores a `bus:join` it won't honour (wrong environment, missing name), and
 * the connection stays happily open. A bus that quietly stops waking you is the
 * worst failure this system has, so say so out loud instead.
 *
 * The timer is scheduled ONCE and deliberately never rescheduled while pending:
 * the re-join interval below fires every 10s for as long as no room is joined,
 * so clearing the timer on each attempt reset it forever and the warning could
 * never fire — which is exactly the silent failure it exists to prevent.
 */
const scheduleAckCheck = () => {
  if (ackTimer || warnedNoAck) return;
  ackTimer = setTimeout(() => {
    ackTimer = null;
    if (identity) return;
    warnedNoAck = true;
    log(
      "! joined no rooms after 15s — the server is not accepting this join. " +
        "Most likely the bus is not enabled on that host (it exists on dev " +
        `only). Check with: curl ${cfg.BUS_URL}/rooms`,
    );
  }, 15000);
};

const joinRooms = () => {
  const rooms = readRooms();
  if (!rooms.length) return;
  emit("bus:join", { rooms, dev: DEV_NAME });
  scheduleAckCheck();
};

const onEvent = (name, data) => {
  if (name === "bus:joined") {
    clearTimeout(ackTimer);
    ackTimer = null;
    warnedNoAck = false; // a later outage may legitimately warn again
    identity = data?.dev ?? null;
    joined = new Set(data?.rooms ?? []);
    log(`listening as ${identity} on: ${[...joined].join(", ") || "(none)"}`);
    return;
  }

  if (name === "bus:event") {
    // Paused? Drop it rather than spooling — a paused monitor that silently
    // banks notices would dump the whole backlog the moment you resume.
    if (fs.existsSync(PAUSE_FILE)) return;
    if (IGNORED_DEVS.has(data?.dev)) {
      log(`ignored event from ${data.dev} (BUS_IGNORE_DEVS)`);
      return;
    }
    try {
      fs.appendFileSync(SPOOL, JSON.stringify(data) + "\n");
    } catch (err) {
      log(`! failed to spool notice: ${err.message}`);
    }
  }
};

const connect = () => {
  ws = new WebSocket(WS_URL);

  ws.addEventListener("open", () => {
    retryDelay = 1000;
    identity = null;
  });

  ws.addEventListener("message", (ev) => {
    const frame = typeof ev.data === "string" ? ev.data : String(ev.data);

    // "0{...}" — Engine.IO open. Reply "40" to join the default namespace, and
    // take pingInterval so we can answer the server's heartbeats.
    if (frame[0] === "0") {
      try {
        const open = JSON.parse(frame.slice(1));
        clearInterval(pingTimer);
        // Engine.IO v4 has the SERVER ping and the client pong, so no timer is
        // strictly needed — but a idle-safety pong keeps proxies from closing
        // a quiet connection.
        if (open.pingInterval) {
          pingTimer = setInterval(() => send("3"), open.pingInterval);
        }
      } catch {}
      send("40");
      return;
    }

    // "2" — server ping. Must answer "3" or it drops us.
    if (frame === "2") return send("3");

    // "40..." — namespace connected. Safe to emit now.
    if (frame.startsWith("40")) {
      log(`connected to ${BUS_ORIGIN}`);
      joinRooms();
      return;
    }

    // "42[name, data]" — an event, possibly namespaced ("42/ns,[...]").
    if (frame.startsWith("42")) {
      const start = frame.indexOf("[");
      if (start === -1) return;
      try {
        const [name, data] = JSON.parse(frame.slice(start));
        onEvent(name, data);
      } catch (err) {
        log(`! unparseable event frame: ${err.message}`);
      }
    }
  });

  ws.addEventListener("error", () => {
    /* surfaced by the close handler below */
  });

  ws.addEventListener("close", () => {
    clearInterval(pingTimer);
    identity = null;
    joined = new Set();
    log(`disconnected — retrying in ${Math.round(retryDelay / 1000)}s`);
    setTimeout(connect, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 30000); // capped backoff
  });
};

// Re-join when the rooms file changes (the wake hook adds a repo's room the
// first time a session runs there) — cheap, and avoids a restart per repo.
setInterval(() => {
  if (!identity) return joinRooms();
  const want = readRooms();
  if (want.some((r) => !joined.has(r))) joinRooms();
}, 10000);

log(`monitor up (pid ${process.pid})`);
// Sweep at startup as well as hourly: the 14-day clock keeps running while
// the machine is off, so the first run after a week away has the most to do.
sweep();
setInterval(sweep, SWEEP_INTERVAL_MS);
connect();
