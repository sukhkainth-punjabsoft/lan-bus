#!/usr/bin/env bash
# Shared helpers for the LAN bus hooks. Meant to be sourced, not run.

# Browse mDNS for a bus advertised on the LAN and echo "host:port".
# Costs BUS_MDNS_TIMEOUT seconds (default 3) because dns-sd streams and
# never exits on its own, so it has to be backgrounded and killed.
discover_bus() {
  local name="${BUS_MDNS_NAME:-lan-bus}"
  local service="${BUS_MDNS_SERVICE:-_lanbus._tcp}"
  local log pid hostport
  log="$(mktemp)"

  dns-sd -L "$name" "$service" local > "$log" 2>&1 &
  pid=$!
  sleep "${BUS_MDNS_TIMEOUT:-3}"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # "...can be reached at some-mac.local.:8787" -> "some-mac.local:8787"
  hostport="$(grep -oE '[A-Za-z0-9.-]+\.local\.?:[0-9]+' "$log" | head -1 | sed 's/\.local\.:/.local:/')"
  rm -f "$log"

  [ -n "$hostport" ] || return 1
  printf '%s\n' "$hostport"
}

# Set BUS_URL, in priority order:
#   1. BUS_URL already set        — explicit wins, costs nothing
#   2. BUS_HOST (+ BUS_PORT)      — hostname only, e.g. some-mac.local
#   3. mDNS discovery             — zero config, costs ~3s
# Returns 1 if none of the three produced a URL.
resolve_bus_url() {
  [ -n "${BUS_URL:-}" ] && return 0

  if [ -n "${BUS_HOST:-}" ]; then
    BUS_URL="http://${BUS_HOST}:${BUS_PORT:-8787}"
    return 0
  fi

  local found
  found="$(discover_bus)" || return 1
  BUS_URL="http://${found}"
}
