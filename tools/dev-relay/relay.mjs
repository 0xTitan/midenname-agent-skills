#!/usr/bin/env node
// Local DEV stub of the device-flow sign-request relay.
// Implements the API in design/device-flow-signing.md (POST/GET/PATCH
// /v1/sign-requests) with in-memory storage and a 5-minute TTL.
//
// NOT for production: no auth, single process, no persistence. It exists so the
// agent side (`miden-name.sh register --sign web`) and the `/sign/:id` page can be
// developed and demoed before the real relay lands in midenid-backend.
//
// Usage:  node tools/dev-relay/relay.mjs [port] [frontendBase]
//   port          default 8787
//   frontendBase  default http://localhost:5173  (used to build user_url)
import http from 'node:http';
import { randomBytes } from 'node:crypto';

const PORT = Number(process.argv[2] || 8787);
const FRONTEND = (process.argv[3] || 'http://localhost:5173').replace(/\/$/, '');
// Dev TTL is generous (20 min) so a slow wallet connect/sync on testnet doesn't
// expire the request mid-test. The production relay keeps the doc's 5-min default.
const TTL_MS = Number(process.env.RELAY_TTL_MS || 20 * 60 * 1000);

const store = new Map();
const newId = () => randomBytes(12).toString('base64url').slice(0, 16);
const expireStale = () => {
  for (const r of store.values()) {
    if (r.status === 'pending' && r.expires_at < Date.now()) r.status = 'expired';
  }
};

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,PATCH,OPTIONS',
  'access-control-allow-headers': 'content-type',
};
const send = (res, code, obj) => {
  res.writeHead(code, { 'content-type': 'application/json', ...CORS });
  res.end(JSON.stringify(obj));
};

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, CORS); return res.end(); }
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname.split('/').filter(Boolean); // ['v1','sign-requests', id?, action?]
  expireStale();

  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    let data = {};
    if (body) { try { data = JSON.parse(body); } catch { return send(res, 400, { error: 'bad json' }); } }

    const isReqs = p[0] === 'v1' && p[1] === 'sign-requests';
    if (!isReqs) return send(res, 404, { error: 'no route' });

    // POST /v1/sign-requests
    if (req.method === 'POST' && p.length === 2) {
      if (!data.unsigned_tx_hex) return send(res, 400, { error: 'unsigned_tx_hex required' });
      const id = newId();
      const rec = {
        id,
        kind: data.kind || 'register-name@v1',
        unsigned_tx_hex: data.unsigned_tx_hex,
        summary: data.summary || {},
        status: 'pending',
        tx_hash: null,
        note_id: null,
        created_at: new Date().toISOString(),
        expires_at: Date.now() + TTL_MS,
      };
      store.set(id, rec);
      console.log(`[relay] + ${id}  name=${rec.summary.name ?? '?'}  hex=${rec.unsigned_tx_hex.length} chars`);
      // No poll_url: the agent builds it from the relay base it already uses, so the
      // relay never needs to know its own public URL (matches the real backend).
      return send(res, 201, {
        id,
        user_url: `${FRONTEND}/sign/${id}`,
        expires_in: Math.floor(TTL_MS / 1000),
      });
    }

    const rec = p[2] && store.get(p[2]);
    if (!rec) return send(res, 404, { error: 'not found' });

    // GET /v1/sign-requests/:id
    if (req.method === 'GET' && p.length === 3) return send(res, 200, rec);

    // PATCH /v1/sign-requests/:id/(signed|rejected)
    if (req.method === 'PATCH' && p.length === 4) {
      if (rec.status !== 'pending') return send(res, 409, { error: `already ${rec.status}` });
      if (p[3] === 'signed') {
        rec.status = 'signed';
        rec.tx_hash = data.tx_hash || null;
        rec.note_id = data.note_id || null;
        console.log(`[relay] ✓ ${rec.id} signed  tx=${rec.tx_hash}`);
        return send(res, 200, rec);
      }
      if (p[3] === 'rejected') {
        rec.status = 'rejected';
        console.log(`[relay] ✗ ${rec.id} rejected`);
        return send(res, 200, rec);
      }
    }
    return send(res, 404, { error: 'no route' });
  });
});

server.listen(PORT, () => console.log(`[relay] dev stub on http://localhost:${PORT}  ->  frontend ${FRONTEND}`));
