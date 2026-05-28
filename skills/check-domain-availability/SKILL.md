---
name: check-domain-availability
description: Check whether a Miden Name domain (e.g. "alice.miden") is available for registration on the Miden testnet, and report its yearly price. Read-only — needs no wallet, funds, or transaction. Use when a user asks if a .miden name is free/taken/available, wants to look up a domain, or asks the price of a Miden name before registering.
license: MIT
---

# Check Miden Name Domain Availability

Checks if a `.miden` domain is unregistered and reports its yearly price. This is a
read-only on-chain lookup against the public Miden testnet — no keystore, no funds,
and no transaction are involved.

## When to use

- "Is `alice.miden` available?"
- "Is the name `foo` taken?"
- "How much does `bob.miden` cost?"
- As a mandatory pre-check before running the `register-domain` skill.

## Prerequisites

This skill reads chain state with a small bundled helper crate
(`tools/miden-name/`) that reuses the `midenid-contracts` crate's helpers — no
backend server, and `midenid-contracts` itself is not modified:

1. Rust toolchain installed (`cargo --version`) and `git`.
2. Network access to the Miden testnet node.

The `midenid-contracts` clone is **resolved automatically** by the wrapper (an existing
clone if `MIDENNAME_CONTRACTS_DIR` is set or one sits beside this repo, else a cached
auto-clone of branch `simple-naming-0.14`). The helper crate compiles on first use
(slow once, fast after). No env var is required to run.

**Finding the wrapper.** The one thing the agent needs is the path to
`scripts/miden-name.sh`, via `MIDENNAME_SKILLS_DIR`. In Claude Code, vars set only in
`~/.zshrc`/`~/.bashrc` read as **empty** (the Bash tool doesn't source them) — set it in
`~/.claude/settings.json` under `env`. If it's unset, locate the script with `find`
(below). See `../register-domain/references/setup.md`.

## How to run

Normalize the name first: lowercase, strip any trailing `.miden`. Valid names are
**1–20 characters, `a–z` and `0–9` only** (see `../register-domain/references/protocol.md`).
If the name contains other characters, tell the user it is invalid and stop — do not call the CLI.

Then run the wrapper:

```bash
"$MIDENNAME_SKILLS_DIR/scripts/miden-name.sh" availability alice
```

If `$MIDENNAME_SKILLS_DIR` is empty (prints `/scripts/miden-name.sh`), the env isn't
set up — don't guess a path. Either locate the script (`find ~ -name miden-name.sh -path '*midenname*' 2>/dev/null`)
or ask the user to set the vars in `~/.claude/settings.json` (see setup.md), then retry.

## Interpreting output

The command prints a human-readable block and a final machine-readable line:

```
RESULT available=true domain=alice price=20000000
```

- `available=true`  → the domain is unregistered and can be registered now.
- `available=false` → the domain already has an owner; it cannot be registered
  (offer to check a different name).
- `price` is in the payment token's **base units per year** (MIDEN faucet token).
  Divide by 1,000,000 for whole tokens. See `../register-domain/references/protocol.md`
  for the length→price table.

Report availability plainly. If the user then wants to register, hand off to the
`register-domain` skill.

## Notes

- Defaults target Miden **testnet** and naming registry
  `0x3b9988ed8357964061b97efe6a42b5`. Override with `MIDENNAME_NETWORK` /
  `MIDENNAME_NAMING_ACCOUNT` if needed.
- A reported price is the *list* price for that length; multi-year discounts
  (3+ yrs: 30% off, 5+ yrs: 50% off) apply only at registration.
