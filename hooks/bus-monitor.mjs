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
connect();
