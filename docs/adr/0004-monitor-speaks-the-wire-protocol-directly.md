---
status: accepted
---

# The Monitor speaks the wire protocol directly instead of using a client library

The server is socket.io, but the Monitor does not use `socket.io-client`. It
implements the handful of Engine.IO v4 frames it needs — open, namespace
connect, ping/pong, event — on Node's built-in `WebSocket`.

This is deliberate and will look wrong at a glance. The reason is distribution:
this client ships as a Claude Code plugin, and a dependency would mean every
developer running `npm install` inside the plugin directory, then again after
every plugin update, with a `node_modules` tree living in a plugin cache that
updates can wipe. Speaking the protocol directly makes the plugin pure files —
install and it works.

## Consequences

- Requires Node 22+, for the built-in `WebSocket`. The Monitor checks and says
  so rather than failing obscurely.
- We are exposed to an Engine.IO protocol change. The surface used is small and
  stable, and a break is loud (nothing connects) rather than subtle.
- **Do not "fix" this by adding `socket.io-client`.** That reintroduces exactly
  the install step this avoids. If the protocol handling ever becomes a real
  maintenance burden, the honest alternative is an SSE endpoint on the server,
  which the standard library can consume without any protocol code at all.
