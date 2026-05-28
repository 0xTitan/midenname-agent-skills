---
name: register-domain
description: Register a Miden Name domain (e.g. "alice.miden") on the Miden testnet on behalf of a user, paying the registration fee in the MIDEN token from their account. Use when a user asks to register/claim/buy/mint a .miden name or domain. This submits a real on-chain transaction that spends tokens, so always check availability first and confirm with the user before paying. Useful for airdrop/testnet farming where many names are claimed.
license: MIT
---

# Register a Miden Name Domain

Registers a `.miden` domain by sending an on-chain registration note that pays the
fee in the MIDEN payment token. Runs entirely against the public Miden testnet — no
backend service is required. This **spends real testnet tokens and submits a
transaction**, so treat it as a costly, hard-to-reverse action.

## When to use

- "Register `alice.miden` for me."
- "Claim the name `foo`."
- "Mint these names: a, b, c." (loop the flow once per name)

## Safety rules (follow in order)

1. **Validate** the name: lowercase; strip trailing `.miden`; must be 1–20 chars,
   `a–z`/`0–9` only. Reject anything else without calling the CLI.
2. **Check availability first** using the `check-domain-availability` skill. If
   `available=false`, stop and tell the user — registering a taken name will fail
   and may still consume the payment note.
3. **Confirm with the user** before paying: state the name, the yearly price (from
   the availability check), and which account will pay. Do not auto-register
   unless the user has explicitly authorized batch/unattended registration.
4. Only then submit the registration.

## Prerequisites

This skill drives the `midenid-contracts` Rust CLI. Before it can succeed:

1. Rust toolchain + `git`. The contracts clone is resolved automatically by the wrapper
   (auto-cloned/cached if you haven't set `MIDENNAME_CONTRACTS_DIR`).
2. The paying **account's signing key in the contracts clone's `keystore`** — created
   with `miden-name.sh create-account`.
3. That account **funded with the MIDEN payment token** (faucet
   `0x0a7d175ed63ec5200fb2ced86f6aa5`) ≥ the domain price, and the mint note **consumed**
   (`miden-name.sh consume <account>`).

If the user has no funded account, run the full setup flow in `references/setup.md`
(`create-account` → faucet mint → `consume` → `balance`) rather than guessing.

## How to run

```bash
"$MIDENNAME_SKILLS_DIR/scripts/miden-name.sh" register alice --account 0xYOUR_ACCOUNT_ID
```

The wrapper supplies network, naming-registry, and faucet defaults (testnet). The
underlying CLI:
- computes the price from the name length and **checks the account balance first**
  (it errors out with "Insufficient balance" rather than partially paying),
- builds and submits the `register_name` note,
- prints MidenScan links for the note and transaction.

## After registering

- Report the transaction / note IDs and the MidenScan link the CLI prints.
- Tell the user the domain is **registered (owned) but not yet active**. Activation
  (linking the name to an account so it resolves) is a separate step —
  `activate_domain` — not yet wired into this skill. See `references/protocol.md`
  for the lifecycle. (This skill is intentionally scoped to availability +
  registration; activation/renewal/transfer are planned extensions.)

## Failure handling

- **"Insufficient balance"** → the account lacks enough MIDEN token. Direct the user
  to fund it (see `references/setup.md`) and retry.
- **"Domain not available" / tx rejected** → someone registered it first; re-check
  availability and pick another name.
- **Account not in keystore / not found** → complete account setup first.

## Reference material

- `references/protocol.md` — naming rules, length→price table, contract addresses,
  domain lifecycle, on-chain encoding.
- `references/setup.md` — installing the CLI, creating/importing an account, funding
  it with the MIDEN token.
