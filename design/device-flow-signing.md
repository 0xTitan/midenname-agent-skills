# Design — agent-proposes / user-signs via device flow

**Status:** draft for review · **Owners:** skills + backend + frontend · **Last updated:** 2026-06-09

## Summary

Add a second signing mode for the Miden Name agent skills in which the **agent
proposes a transaction** and the **user signs it in their own browser wallet** —
without the agent ever holding the user's private key, without browser-extension
plumbing, and without an open browser tab on the agent host. Modeled on the
OAuth 2.0 Device Authorization Grant (RFC 8628) — the same flow GitHub CLI,
Stripe CLI, Vercel CLI, and Claude in VS Code already use.

Keeps the existing **local-keystore mode** as default (unattended airdrop loops);
adds an opt-in **web-confirm mode** for users who want to sign with their real
wallet on every tx.

## Motivation

- Today the agent signs with a Falcon512 key it owns on disk (`FilesystemKeyStore`).
  Great for throwaway farming accounts, wrong for any account a user actually cares
  about — there's no per-tx approval and the key is at rest on the agent host.
- Browser-wallet extensions only expose signing to **same-origin web pages**, not to
  external CLI processes. There is no Miden equivalent of WalletConnect today.
- A small **relay + confirmation page**, addressed by a one-shot URL the CLI prints,
  cleanly bridges the gap and matches a UX pattern users already recognize.

## Goals

1. The agent can request a signature for a Miden Name transaction without holding
   the user's key.
2. The user signs in **their own wallet** (browser extension or in-page wallet),
   exactly the same flow miden.name uses today.
3. Works when the **agent and the user's browser are on different machines** (cloud
   agent, mobile approval).
4. The **key never reaches** the agent, the relay, or the confirmation page.
5. Defaults are unchanged: existing local-keystore mode keeps working with no
   migration required.

## Non-goals

- A generic Miden transaction signer. v1 supports **Miden Name `register`** only
  (the existing tx the backend already knows how to build). Extending to other
  ops is a follow-up shaped the same way.
- Multi-party / threshold approval.
- Replacing local-keystore mode. Both coexist; user picks per call.
- Persistent agent ↔ wallet session ("approve once for an hour"). Each tx is a
  fresh, one-shot request.

## High-level flow

```
agent (CLI)              relay (api.miden.name)         /sign/:id page (browser)         wallet
───────────              ──────────────────────         ─────────────────────────         ──────
1. build UNSIGNED tx
   (reuse existing
    midenid-backend
    /prepare endpoint)
2. POST /v1/sign-requests ─►  store, set status=pending
3. ◄── { id, user_url, exp }
4. print user_url + summary
5. short-poll /v1/.../:id ─►   returns status                 ◄── 6. user opens user_url
                                                                   7. GET /v1/sign-requests/:id
                                                                      derive + render summary
                                                                      from unsigned_tx_hex
                                                                   8. click Approve
                                                                   9. wallet adapter:
                                                                      requestTransaction(unsigned)
                                                                                            ─► 10. popup, user confirms
                                                                                                11. sign + submit to node
                                                                                            ◄── 12. tx_hash, note_id
                                                                  13. PATCH /v1/.../signed
                              status=signed, tx_hash
14. ◄── { status: signed,
          tx_hash, note_id }
15. wait for commit
16. print MidenScan link
```

## Feasibility findings (verified against the live code, 2026-06-09)

**The flow is architecturally sound — the wallet adapter is purpose-built to sign a
tx it didn't construct, and the team already designed a server-built-tx path.**

- **`CustomTransaction` carries externally-built bytes.** In
  `miden-wallet-adapter/packages/core/base/transaction.ts`, `CustomTransaction`
  serializes a `TransactionRequest` to bytes and base64-encodes it
  (`transactionRequest.serialize()` → `u8ToB64(...)`). The wallet receives the
  base64, deserializes, signs, and submits. The wallet does **not** care who built
  the bytes — that is exactly what the `Custom` transaction type is for. So a
  Rust-built `TransactionRequest` is precisely what this path expects.
- **A dormant backend path already proves the pattern.** `midenid-frontend`
  `src/api/domains.ts` documents *"Backend builds the full Note and returns a
  serialized TransactionRequest"* and `src/types/api/responses.ts` carries
  `transaction_request_hex: string`. That is the device-flow shape, already
  envisioned by the team. (It is currently dormant: the live `RegisterModal` uses
  `src/lib/transactionCreator.ts`, which builds the tx **in-browser** and hands it
  to the same `CustomTransaction` path — so today the bytes are built and consumed
  by the *same* SDK version.)
- **Invariant #2 (page re-derives summary from the bytes) is feasible** for the
  same reason: the WASM SDK can `TransactionRequest.deserialize()` the bytes and
  read the output notes / assets to reconstruct the summary.

**The serialization round-trip risk is now RESOLVED (verified 2026-06-09).**

The concern was a version skew: the format that the WASM SDK / wallet deserialize
with must match the `miden-client` version that the Rust helper serializes with
(Miden's `Serializable` byte format is not stable across 0.x minors). Both sides
are now aligned:

| Side | miden version |
|------|---------------|
| Frontend `@miden-sdk/miden-sdk` (+ wallet-adapter 0.14.3) | **0.14.4** |
| This repo's helper crate + `midenid-contracts` | **miden-client 0.14.4** |

**Spike result (step 0, done):** the hex emitted by `miden-name.sh` /
`prepare-register` (a real testnet `register` tx, `miden-client 0.14.4`) was loaded
into `@miden-sdk/miden-sdk@0.14.4` via `TransactionRequest.deserialize()`:

- `deserialize()` succeeded; `expectedOutputOwnNotes()` returned the 1 register note.
- From that note the SDK read back `metadata.sender()` = the paying account
  (→ invariant #5, sender pinning), and `assets.fungibleAssets()` = faucet
  `0x0a7d…aa5` + amount `20000000` (→ invariant #2, price + payment token). The
  domain is recoverable from `note.recipient()` inputs, which the page can compare
  against its own `encodeDomain`.
- A re-serialize is non-deterministic (internal map/set ordering) and differs from
  the input bytes — this is cosmetic and irrelevant, because the wallet signs the
  **original** bytes it receives, never a re-serialization.

**End-to-end verified with a real wallet (2026-06-11).** A full run — agent
`register --sign web` → dev relay → `/sign/:id` page → user approved in the **Miden
wallet browser extension** → wallet signed + submitted → page `PATCH /signed` →
agent poll detected `signed` and exited 0 — completed successfully. The wallet
accepted the agent-built (Rust `miden-client 0.14.4`) `TransactionRequest`,
confirming the whole chain works against a deployed wallet, not just the SDK in
Node. (The wallet's `requestTransaction` returns its internal transaction id, a
UUID — not the on-chain tx hash; the relay/agent just store whatever it returns.
On-chain *registration* landing is a separate concern: it depends on the payer
account being deployed + funded and the registry network account consuming the
register note, which can lag.)

If the deployed wallet ever pins a different 0.14.x patch, re-pin the helper crate's
`miden-client` to match and re-seed its `Cargo.lock` (the wrapper does this from the
contracts clone's lock automatically).

## Components and responsibilities

### Agent (skills repo)

- New helper subcommand `prepare-register`: builds the unsigned `TransactionRequest`
  for a registration (mirrors `register` minus the submit + balance-check signing).
  Output: hex-encoded `TransactionRequest` + summary metadata.
- New wrapper command flag `register --sign web ...`:
  1. `prepare-register` → hex + summary
  2. `POST /v1/sign-requests`
  3. print `user_url` + human summary
  4. short-poll `{MIDENNAME_RELAY_URL}/v1/sign-requests/:id` (every 2–3 s) until
     terminal status (signed / rejected / expired) — the poll URL is built from the
     relay base the CLI already used, not returned by the relay
  5. on `signed`: print the register-note MidenScan link, wait for commit
- `MIDENNAME_SIGN_MODE=local|web` (default `local`); `--sign web` overrides per call.
- `MIDENNAME_RELAY_URL` (default `https://api.miden.name`) — overridable for staging.

### Relay (midenid-backend, new routes)

A small, ephemeral key/value with TTL — does **not** persist keys or signed txs
beyond a TTL window. Reuses existing infra.

| Route | Method | Caller | Purpose |
|-------|--------|--------|---------|
| `/v1/sign-requests` | POST | agent | create a pending sign request |
| `/v1/sign-requests/:id` | GET | page + agent | fetch summary / poll status |
| `/v1/sign-requests/:id/signed` | PATCH | page | submit `tx_hash` + `note_id` |
| `/v1/sign-requests/:id/rejected` | PATCH | page | user cancelled |

Storage shape (per request, in-memory or Redis):

```jsonc
{
  "id": "abc123",                       // 16 chars, url-safe base32
  "kind": "register-name@v1",           // version pin, future-proofs payload schema
  "unsigned_tx_hex": "0x…",             // serialized TransactionRequest
  "summary": {                          // shown on the page, NOT trusted for signing
    "name": "alice",
    "sender_account": "0x…",
    "naming_account": "0x…",
    "faucet_id": "0x…",
    "price": "20000000"
  },
  "status": "pending|signed|rejected|expired",
  "tx_hash": null,
  "note_id": null,
  "created_at": "…",
  "expires_at": "…"                     // +5 min default
}
```

### Confirmation page (midenid-frontend, new route `/sign/:id`)

1. `GET /v1/sign-requests/:id` → fetches the unsigned tx + relay summary.
2. **Re-derives the summary from the unsigned tx itself** (decode the
   `TransactionRequest`, extract domain word, payment asset, sender), and
   **displays the re-derived values** — *not* the relay-supplied `summary`.
   If they differ → render a red warning, do not allow Approve.
3. Connects the user's wallet via the existing `@miden-sdk/miden-wallet-adapter`
   (same code path as the dApp's register page today).
4. On Approve: `requestTransaction(deserialized)` → wallet popup → wallet signs +
   submits → returns `tx_hash`/`note_id`.
5. `PATCH /v1/sign-requests/:id/signed { tx_hash, note_id }`.
6. Show confirmation + MidenScan link.

Reject button → `PATCH .../rejected`.

## API details

### POST `/v1/sign-requests`

Request:
```jsonc
{
  "kind": "register-name@v1",
  "unsigned_tx_hex": "0x…",
  "summary": {
    "name": "alice",
    "sender_account": "0x…",
    "naming_account": "0x…",
    "faucet_id": "0x…",
    "price": "20000000"
  }
}
```

Response (201):
```jsonc
{
  "id": "abc123",
  "user_url": "https://miden.name/sign/abc123",   // {SIGN_FRONTEND_URL}/sign/:id
  "expires_in": 300
}
```

There is intentionally **no `poll_url`**: the agent already knows the relay base it
POSTed to and builds the poll URL itself (`{relay}/v1/sign-requests/:id`), so the
backend never needs to know — or be configured with — its own public URL. (An
earlier draft returned `poll_url` from a `SIGN_RELAY_BASE_URL` config; that was
redundant and a footgun — a wrong base silently broke the agent's polling.)

### GET `/v1/sign-requests/:id`

Returns the full record above. The agent polls this; the page reads it once.
Polling interval: agent picks 2–3 s; relay may support `?wait=30` long-polling.

### PATCH `/v1/sign-requests/:id/signed`

Page-only. Body: `{ "tx_hash": "0x…", "note_id": "0x…" }`. Transitions
`pending → signed`. Idempotent on the first call; rejects on second.

### PATCH `/v1/sign-requests/:id/rejected`

Page-only. Transitions `pending → rejected`. Same idempotency.

## State machine

```
              POST /v1/sign-requests
                       │
                       ▼
                   ┌─────────┐
                   │ pending │ ── TTL elapsed ──► expired (terminal)
                   └─────────┘
                  /           \
       PATCH /signed         PATCH /rejected
                  │           │
                  ▼           ▼
              signed       rejected     (both terminal; one-shot)
```

Terminal states are immutable; further PATCHes return 409.

## Security invariants

1. **The key never leaves the wallet.** The agent, relay, and page only see
   unsigned bytes one way and the `tx_hash`/`note_id` the other.
2. **Trusted display.** The page renders the summary it derives from
   `unsigned_tx_hex` *itself*, not the relay-supplied `summary`. A compromised
   relay cannot swap in a different tx without the page detecting the mismatch.
   *Verified (step 0):* the WASM SDK `TransactionRequest.deserialize()`s the bytes
   and reads the output note's sender / payment faucet / amount back out, so the
   summary can be re-derived independently of the relay.
3. **One-shot consumption.** `requestId` is invalid after the first terminal
   transition; replays return 409.
4. **Short TTL.** Default 5 min. The agent's poll loop times out cleanly when
   the request expires.
5. **Sender pinning.** The page checks `walletAdapter.connectedAccount` matches
   the sender encoded in `unsigned_tx_hex`; mismatch blocks Approve.
6. **Origin trust.** `/sign/:id` is only served from `miden.name` (no embedding
   on other origins). The CLI prints the full URL so the user can verify the
   origin before clicking.
7. **No signing tokens.** The agent never receives a credential it could use to
   sign on its own afterward — each tx requires a fresh user-driven flow.
8. **Versioned payload.** `"kind": "register-name@v1"` lets the page refuse to
   render older/unknown payload schemas.

## Threat model

| Threat | Mitigation |
|--------|------------|
| Compromised relay swaps the tx | Page re-derives summary from hex; mismatch → no Approve |
| Compromised agent proposes a malicious tx | User sees the real summary on the page; clicking Approve is informed consent |
| Phishing site mimicking `/sign/:id` | CLI prints the full URL; origin is `miden.name` (no embedding) |
| Replay / race | One-shot terminal transitions; 409 on second PATCH |
| Long-lived secrets stolen from the relay | There are no signing secrets in the relay — only unsigned tx bytes (already public-domain shape) and a public `tx_hash` after signing |
| Agent holds a token to sign later | The flow issues no such token; each tx is its own request |

What the design does **not** defend against:
- A malicious browser extension / wallet that displays one thing and signs another. Out of scope; this is a generic wallet trust issue.
- The user approving a tx without reading the summary. Mitigated only by clear UX.

## Decisions (resolved 2026-06-09)

1. **Tx source — agent builds locally.** The helper crate serializes the unsigned
   `TransactionRequest`; the relay only stores + serves it. Keeps web-mode on the
   same "no-backend" stance as local-mode `register`, and means one code path builds
   the tx in both modes.
2. **Polling — short-polling.** The CLI hits `GET /v1/sign-requests/:id` every 2–3 s
   until terminal. No `?wait=` long-poll in v1.
3. **CLI UX — print URL + short code, no auto-open.** The CLI prints the full
   `https://miden.name/sign/:id` URL plus a typeable short code; it does **not** run
   `open`/`xdg-open`. Works for remote/cloud/SSH agents and lets the user eyeball the
   origin before clicking.
4. **Relay storage — in-memory, single replica.** Records expire in 5 min, so
   persistence is unnecessary. Revisit to Redis-with-TTL only if the backend is
   later run with > 1 replica behind a load balancer.

## Open questions

1. **`consume` after a faucet mint.** Same shape if needed — but consume currently
   uses the local keystore, and web-mode register implies the user's wallet account
   already holds tokens, so consume isn't on the critical path for the v1 use case.
   Left open until a user actually needs web-mode consume.

## Rollout / compatibility

- New mode is opt-in via `--sign web` / `MIDENNAME_SIGN_MODE=web`.
- Default remains `local` (current behavior, no changes for existing users).
- Skills repo can ship `register --sign web` ahead of the relay/page being live
  if the relay URL points at a staging environment; the wrapper errors cleanly
  if the relay is unreachable.

## Build plan (after this doc is agreed)

0. **Serialization round-trip spike (gating) — ✅ DONE 2026-06-09.** The helper's
   `prepare-register` hex (`miden-client 0.14.4`) deserializes cleanly in
   `@miden-sdk/miden-sdk@0.14.4` (`TransactionRequest.deserialize()`), and the
   sender / faucet / price read back correctly (see Feasibility findings above).
   Versions are aligned at 0.14.4 on both sides. The only part not yet exercised is
   an actual wallet-extension signature in a browser (step 3 covers it).
1. **Skills repo** (`tools/miden-name` + `scripts/miden-name.sh`):
   - `prepare-register` (helper crate) — serialize unsigned tx + emit summary.
   - `register --sign web` (wrapper) — POST + poll loop.
2. **midenid-backend** — ✅ DONE 2026-06-11.
   - `POST/GET/PATCH /v1/sign-requests` with a 5-min TTL, in-memory store
     (`AppState.sign_requests`, decision #4). New `handlers/sign_handler.rs` +
     `models/sign_request.rs`; `user_url` built from the single new config
     `SIGN_FRONTEND_URL` (the response carries no `poll_url` — the agent builds it);
     `Method::PATCH` added to the production CORS allow-list (the page PATCHes
     cross-origin). Integration tests in `tests/sign_request_test.rs` cover the full
     lifecycle, one-shot 409, 404, and 400.
3. **midenid-frontend**:
   - `/sign/:id` route reusing the existing wallet-adapter integration; summary
     re-derivation from `unsigned_tx_hex`.

Each lands as its own small PR. The skills wrapper can be developed against a
stub relay; the relay can be developed and unit-tested standalone; the page can
be developed against the relay with the wallet adapter mocked.

## Out of scope / explicitly deferred

- Activate / extend / transfer name flows (mirror the same shape once register
  works).
- WalletConnect-style persistent sessions.
- Mobile-specific UX beyond "open the URL on your phone."
- Audit / logging UI for the relay.
