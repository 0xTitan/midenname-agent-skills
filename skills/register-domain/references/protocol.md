# Miden Name — protocol reference

Facts an agent needs to register/look up names correctly. Sourced from the
`midenid-contracts` registry contract and frontend encoder.

## Naming rules

- Allowed characters: `a–z` and `0–9` only (lowercase). No `.`, `-`, `_`, unicode, or uppercase.
- Length: **1–20 characters** (the on-chain contract allows up to 21; the frontend
  and these skills cap at 20 — use 20 as the safe maximum).
- The user-facing name is `<name>.miden`; the on-chain value is just `<name>`.
- One active mapping per domain; an account may own many domains.

## Pricing (per year)

Price depends on name length and is paid in the MIDEN payment token's base units
(1 token = 1,000,000 base units). This is the **protocol list price**:

| Length | Base units / year | ≈ Tokens / year |
|--------|-------------------|-----------------|
| 1      | 375,000,000       | 375             |
| 2      | 200,000,000       | 200             |
| 3      | 120,000,000       | 120             |
| 4      | 55,000,000        | 55              |
| 5+     | 20,000,000        | 20              |

> **Verified:** registry `0x3b9988…` uses exactly this length-based pricing — a 5+ char
> name cost 20,000,000 base units (100M minted → 80M left after one registration). A
> *different* deployment could configure other prices; the list price is what the
> `availability` command prints and what the `register` CLI uses for its pre-flight
> balance check, while the actual fee is enforced on-chain by the registry's
> `naming::prices` map.

Multi-year discounts (applied at registration): **3+ years → 30% off, 5+ years →
50% off**. The current `register` CLI path registers for the default term; multi-year
terms are a planned extension.

## Network & contract addresses (testnet)

> ⚠️ **Addresses change on every redeploy.** Miden Name is in active development and
> the registry/faucet are redeployed frequently, so the values below are *current best
> known*, not permanent. Always treat them as configurable and verify before paying.

| Thing | Value (current best known) |
|-------|----------------------------|
| Node RPC (gRPC) | Miden testnet (`Endpoint::testnet()` / `https://rpc.testnet.miden.io`) |
| Naming registry account | `0x3b9988ed8357964061b97efe6a42b5` (verified live) |
| MIDEN payment-token faucet (pay registration with this) | `0x0a7d175ed63ec5200fb2ced86f6aa5` (verified: registry prices in this token) |
| Explorer | `https://testnet.midenscan.com` |

Configure via `MIDENNAME_NAMING_ACCOUNT`, `MIDENNAME_FAUCET_ID`, `MIDENNAME_NETWORK`.

> ⚠️ **The payment token is NOT the one in `midenid-backend/.env`.** That file lists
> `MIDEN_FAUCET_ID_TESTNET=0x37d5…`, but the live registry actually prices in
> `0x0a7d175ed63ec5200fb2ced86f6aa5` (the public testnet faucet token) — confirmed by a
> real registration. Trust the registry's on-chain `naming::prices` map over config files.

**Finding the current addresses** (in order of authority):
1. The registry's on-chain state itself — `availability` resolves only against a live
   registry; `register`'s "Insufficient balance" error prints the vault's actual faucet ids.
2. `midenid-contracts/deployments/` — newest timestamped file holds `REGISTRY_CONTRACT_ID`
   and `PAYMENT_TOKEN_ID`.
3. `midenid-backend/.env` / `midenid-frontend/.env` (can disagree with each other and
   with the on-chain truth — see warning above).
4. `midenid-contracts/ADDRESSES.md` (often stale).

The faucet id used to pay **must** match the token the registry's prices were set in;
if a registration is rejected on payment, that mismatch is the first thing to re-check.

## Domain lifecycle

1. **Register** — pay the fee; you become the domain *owner*; the domain is inactive
   (does not yet resolve to an account). ← what the `register-domain` skill does.
2. **Activate** (`activate_domain`) — owner links the domain to an account id so it
   resolves. Separate transaction; planned extension.
3. **Active** — resolves to the account; extendable before expiry.
4. **Expiry** — after the registration term (1–10 years).
5. **Cleanup** — anyone may call `clear_expired_domain` once expired.
6. **Re-registration** — an expired/cleared domain can be registered again.

## On-chain name encoding (for implementers extending these skills)

Names are packed into one `Word` (4 field elements):

- Per-character code: `a–z = 1–26`, `0–9 = 27–36`.
- 7 characters per felt, 8 bits each: chars 1–7 → felt3, 8–14 → felt2, 15–20 → felt1.
- Word layout (Rust order): `[felt1, felt2, felt3, length]`.
- MASM storage loads this big-endian (`mem_loadw_be`), so the **storage-map key is the
  reversed word** `[length, felt3, felt2, felt1]`. Use that reversed word when reading
  the `naming::domain_to_owner` map to check availability (this is exactly what the
  CLI `availability` command does).

Registry storage slots of interest:
- `naming::domain_to_owner` — domain → owner account (empty/zero ⇒ available).
- `naming::domain_to_account` — domain → resolved account (set on activation).
- `naming::account_to_domain` — reverse mapping.
- `naming::prices` — `[token_suffix, token_prefix, letter_count, 0] → price`.
