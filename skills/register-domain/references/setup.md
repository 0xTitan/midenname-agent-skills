# Setup — running the Miden Name skills (no backend)

These skills talk directly to the public Miden **testnet** — there is deliberately no
backend service to run, and `midenid-contracts` itself is not modified:

- **availability / create-account / balance** → a bundled helper crate
  (`tools/miden-name/`) that path-depends on the `midenid-contracts` crate and reuses
  its helpers to read/build chain state.
- **register / consume** → the existing subcommands of the `midenid-contracts` CLI.

## 1. The contracts repo (automatic)

You normally don't clone anything. On first use, `scripts/miden-name.sh` resolves the
`midenid-contracts` clone for you, in order:

1. `$MIDENNAME_CONTRACTS_DIR` if set,
2. a `midenid-contracts` clone sitting next to this repo,
3. otherwise it auto-clones from GitHub (branch **`simple-naming-0.14`**, not `main`)
   into `~/.cache/midenname` and reuses it thereafter.

It then renders `tools/miden-name/Cargo.toml` from its template (pointing the path
dependency at that clone) and runs `cargo`. The first compile is slow (it pulls the
Miden client crates); later runs reuse the cached build.

> ⚠️ The repo's default `main` branch is an **older version** that lacks the helpers
> this crate needs and will not compile — auto-clone deliberately uses
> `simple-naming-0.14` (override via `MIDENNAME_CONTRACTS_REF`).

To reuse a clone you already have (e.g. one you develop in), point at it explicitly:

```bash
export MIDENNAME_CONTRACTS_DIR="/absolute/path/to/midenid-contracts"
```

Then point the skills at it. In a **plain terminal**, exporting works:

```bash
export MIDENNAME_CONTRACTS_DIR="/absolute/path/to/midenid-contracts"
export MIDENNAME_SKILLS_DIR="/absolute/path/to/midenname-agent-skills"
```

**In Claude Code, exporting in `~/.zshrc` is NOT enough.** The Bash tool that skills
run through does not source your interactive shell profile, so vars set only in
`~/.zshrc`/`~/.bashrc` read as empty and the skill reports its tooling isn't set up.
Put them in `~/.claude/settings.json` under `env` (injected into every Bash call) and
start a new session:

```json
{ "env": {
    "MIDENNAME_CONTRACTS_DIR": "/absolute/path/to/midenid-contracts",
    "MIDENNAME_SKILLS_DIR": "/absolute/path/to/midenname-agent-skills"
} }
```

If you have more than one copy of either repo on disk, pick one canonical path and use
it for both vars consistently. (The wrapper can auto-detect a `midenid-contracts` clone
sitting next to the skills repo, but setting the var explicitly is the reliable path.)

Quick check (read-only, needs no account):

```bash
"$MIDENNAME_SKILLS_DIR/scripts/miden-name.sh" availability alice
```

## 2. State and keystore locations

The CLI uses **relative paths inside `MIDENNAME_CONTRACTS_DIR`**:

- `./store.sqlite3` — local client state / synced chain data.
- `./keystore/` — `FilesystemKeyStore`; one file per account, named by the account's
  numeric id, holding its Falcon512 signing key.

To register, the **paying account's signing key must be present in `./keystore`** and
the account must exist on testnet. (Note: a separate `cli-keystore` + `cli-store.sqlite3`
referenced by `miden-client.toml` is for the standalone `miden` client and is *not*
what the registration CLI reads.)

## 3. Get a funded account whose key is in `./keystore` (verified flow)

Registration needs an account that (a) has its key in `./keystore` and (b) holds
enough of the MIDEN payment token (faucet `0x0a7d175ed63ec5200fb2ced86f6aa5`) to cover
the domain price (see `protocol.md`). The full flow, verified end-to-end on testnet:

```bash
S="$MIDENNAME_SKILLS_DIR/scripts/miden-name.sh"

# 1. Create a wallet — key is written to ./keystore. Note the printed address + hex id.
"$S" create-account
#    -> Account id (hex): 0x...    Account address: mtst1...

# 2. Mint the payment token to it. Either:
#    (a) the official faucet client (handles the faucet's proof-of-work):
cargo install miden-faucet-client          # one-time
miden-faucet-client mint --target-account 0xYOUR_ACCOUNT_HEX --amount 100000000 --no-consume
#    (b) or the web UI at https://faucet.testnet.miden.io (paste the mtst1... address,
#        request a PUBLIC note). Both mint token 0x0a7d175ed63ec5200fb2ced86f6aa5.

# 3. Consume the minted note into your account (signs with ./keystore):
"$S" consume 0xYOUR_ACCOUNT_HEX

# 4. Confirm the balance, then register:
"$S" balance 0xYOUR_ACCOUNT_HEX           # expect the minted amount in base units
"$S" register farmer123 --account 0xYOUR_ACCOUNT_HEX
```

`--amount 100000000` (100 tokens) comfortably covers a 5+ char name (20,000,000/yr).
The `register` CLI checks the balance first and aborts with `Insufficient balance`
rather than partially paying.

> **Payment-token gotcha.** The token the registry prices in is **not** always what a
> config file says. The live registry `0x3b9988…` prices in `0x0a7d175ed63ec5200fb2ced86f6aa5`
> (the public faucet token) — verified on-chain — even though `midenid-backend/.env`
> lists `0x37d5…`. If `register` reports `Insufficient balance` while `balance` shows
> tokens, you're holding the wrong token: re-check `MIDENNAME_FAUCET_ID` against the
> registry's actual `naming::prices` map (`register`'s error prints the vault's faucet ids).

## 4. Configuration summary

| Env var | Purpose | Default |
|---------|---------|---------|
| `MIDENNAME_CONTRACTS_DIR` | Path to the `midenid-contracts` clone | *(required)* |
| `MIDENNAME_SKILLS_DIR` | Path to this skills repo | *(used in examples)* |
| `MIDENNAME_NETWORK` | `testnet` or `devnet` | `testnet` |
| `MIDENNAME_NAMING_ACCOUNT` | Naming registry account id | `0x3b9988ed8357964061b97efe6a42b5` |
| `MIDENNAME_FAUCET_ID` | MIDEN payment-token faucet id | `0x0a7d175ed63ec5200fb2ced86f6aa5` |
