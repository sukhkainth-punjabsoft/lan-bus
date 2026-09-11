#!/usr/bin/env node
// Minimal LAN-only event bus. No deps. One Mac runs this; both Macs' hooks talk to it.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8787;
const TOKEN = process.env.BUS_TOKEN;
const DATA_FILE = process.env.BUS_DATA_FILE || path.join(__dirname, 'events.jsonl');

if (!TOKEN) {
  console.error('Set BUS_TOKEN before starting the server (shared secret for the LAN).');
  process.exit(1);
}

let events = [];
let nextId = 1;

if (fs.existsSync(DATA_FILE)) {
  for (const line of fs.readFileSync(DATA_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    const ev = JSON.parse(line);
    events.push(ev);
    nextId = Math.max(nextId, ev.id + 1);
  }
}

function send(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(json) });
  res.end(json);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => (data += chunk));
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  console.log(`[bus] ${req.method} ${req.url} from ${req.socket.remoteAddress}`);

  if (req.headers['x-bus-token'] !== TOKEN) {
    console.log(`[bus] rejected bad token from ${req.socket.remoteAddress}`);
    return send(res, 401, { error: 'bad token' });
  }

  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    return send(res, 200, { ok: true, events: events.length });
  }

  if (req.method === 'GET' && url.pathname === '/events') {
    const since = Number(url.searchParams.get('since') || 0);
    const excludeDev = url.searchParams.get('excludeDev');
    const matched = events.filter((e) => e.id > since && e.dev !== excludeDev);
    console.log(`[bus] /events since=${since} excludeDev=${excludeDev} -> ${matched.length} matched`);
    return send(res, 200, matched);
  }

  if (req.method === 'POST' && url.pathname === '/events') {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return send(res, 400, { error: 'invalid json' });
    }
    if (!body.dev || !body.message) {
      return send(res, 400, { error: 'dev and message are required' });
    }
    const ev = {
      id: nextId++,
      ts: new Date().toISOString(),
      dev: body.dev,
      ticket: body.ticket || null,
      type: body.type || 'announce',
      message: body.message,
    };
    events.push(ev);
    fs.appendFileSync(DATA_FILE, JSON.stringify(ev) + '\n');
    console.log(`[bus] +event #${ev.id} from ${ev.dev}: ${ev.message}`);
    return send(res, 201, ev);
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[bus] listening on 0.0.0.0:${PORT}, ${events.length} events loaded from ${DATA_FILE}`);
});
