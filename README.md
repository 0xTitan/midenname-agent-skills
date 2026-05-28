# Miden Name — Agent Skills

Agent skills that let an AI assistant **check availability** and **register**
[Miden Name](https://miden.name) domains (`*.miden`) on the Miden testnet on a
user's behalf — useful for testnet/airdrop farming and for any agent that needs
to claim human-readable names on Miden.

The skills run entirely against the **public Miden testnet with no backend service**,
and **without modifying [`midenid-contracts`](https://github.com/Digine-Labs/midenid-contracts)**:

- **Availability, create-account, and balance** are handled by a small helper crate
  bundled in this repo (`tools/miden-name/`) that path-depends on the
  `midenid-contracts` crate and reuses its helpers (domain encoding, client init,
  account creation) to read/build chain state directly.
- **Registration** (and consuming a faucet note) uses the existing `register` /
  `find-and-consume-notes` subcommands of the `midenid-contracts` CLI.

Both talk directly to the Miden node — no REST backend is involved. One keystore
(`./keystore` in the contracts clone) signs everything.

## Skills

| Skill | What it does | Cost |
|-------|--------------|------|
| [`check-domain-availability`](skills/check-domain-availability/SKILL.md) | Look up whether a `.miden` name is free and its yearly price. | Free, read-only |
| [`register-domain`](skills/register-domain/SKILL.md) | Register/claim a `.miden` name, paying the fee in the MIDEN token. | Spends testnet tokens, submits a tx |

Scope is intentionally **availability + registration** today. The structure is built
to extend to `activate`, `renew/extend`, `transfer`, and `resolve` — each maps to an
existing note script in `midenid-contracts`.

## Compatibility / format

Each skill is a self-contained folder with a `SKILL.md` that has YAML frontmatter
(`name`, `description`) followed by Markdown instructions — the
[Agent Skills](https://www.anthropic.com/news/skills) format used by Claude (Claude
Code, Claude apps, and the Agent SDK). The same folder-plus-`SKILL.md` layout is
portable to other agent runtimes: the `description` is the trigger, and the body plus
`references/` are progressively disclosed. Bundled executables live in `scripts/`.

```
midenname-agent-skills/
├── README.md
├── scripts/
│   └── miden-name.sh                     # stable wrapper the skills call
├── tools/
│   └── miden-name/                       # helper crate: availability, create-account, balance
│       ├── Cargo.toml.template           # rendered to Cargo.toml with your contracts path
│       └── src/main.rs
└── skills/
    ├── check-domain-availability/
    │   └── SKILL.md
    └── register-domain/
        ├── SKILL.md
        └── references/
            ├── protocol.md               # rules, prices, addresses, lifecycle, encoding
            └── setup.md                  # install, keystore, funding
```

## Commands (via `scripts/miden-name.sh`)

| Command | Engine | Notes |
|---------|--------|-------|
| `availability <name>` | helper crate | read-only; free |
| `create-account` | helper crate | new wallet, key → `./keystore`, prints address |
| `balance <account>` | helper crate | balance of the MIDEN payment token |
| `register <name> --account <id>` | contracts CLI | spends MIDEN, submits tx |
| `consume <account>` | contracts CLI | pull a faucet mint note into the account |

## Requirements

- **Rust toolchain** (`cargo`) — builds the helper crate and the contracts CLI.
- **git** + network egress — the wrapper auto-clones the contracts repo and reaches
  the Miden testnet node (`rpc.testnet.miden.io`).
- For registration only: **`miden-faucet-client`** (`cargo install miden-faucet-client`)
  to fund an account, plus a writable filesystem for the keystore + synced state.

You do **not** need to clone the contracts repo or set any env var yourself — see below.

## Quick start — availability (no account, free, zero setup)

```bash
# Just run it. On first use the wrapper auto-clones midenid-contracts
# (branch simple-naming-0.14) into ~/.cache/midenname and builds the helper crate.
./scripts/miden-name.sh availability alice
```

The contracts clone is resolved automatically: an existing clone if you point
`MIDENNAME_CONTRACTS_DIR` at one (or one sitting beside this repo), otherwise a cached
auto-clone. To reuse a clone you already have:

```bash
export MIDENNAME_CONTRACTS_DIR="/abs/path/to/midenid-contracts"   # optional
```

> ⚠️ Auto-clone uses branch **`simple-naming-0.14`**, not `main` — the repo's default
> branch is an older version that lacks the helpers this crate needs and won't compile.
> Override with `MIDENNAME_CONTRACTS_REF` if that changes.

## Quick start — register a name (spends testnet tokens)

```bash
S=./scripts/miden-name.sh               # path to the wrapper in this repo

$S create-account                       # new wallet; note the printed 0x... hex id
cargo install miden-faucet-client       # one-time
miden-faucet-client mint --target-account 0xYOUR_HEX --amount 100000000 --no-consume
$S consume 0xYOUR_HEX                    # pull the minted note into the account
$S balance 0xYOUR_HEX                    # confirm it holds the token (100000000)
$S register myname --account 0xYOUR_HEX  # register/claim myname.miden
$S availability myname                   # → available=false (wait a few seconds for commit)
```

Full walkthrough and the payment-token gotcha:
[`skills/register-domain/references/setup.md`](skills/register-domain/references/setup.md).

## Installing the skills into Claude Code

1. **Copy the skill folders** into a skills directory Claude Code loads:

   ```bash
   mkdir -p ~/.claude/skills
   cp -r skills/* ~/.claude/skills/
   ```

2. **Tell the skill where the wrapper is** (this is the only var that matters, and only
   because the agent needs the script's path). ⚠️ Claude Code's Bash tool does **not**
   source `~/.zshrc` / `~/.bashrc`, so vars set there read as **empty** inside skills —
   put it in `~/.claude/settings.json` under `env` (injected into every Bash call), then
   start a new session:

   ```json
   {
     "env": {
       "MIDENNAME_SKILLS_DIR": "/abs/path/to/midenname-agent-skills"
     }
   }
   ```

   The contracts clone is handled automatically (auto-cloned/cached), so
   `MIDENNAME_CONTRACTS_DIR` is **optional** — set it only to reuse an existing clone.
   If you skip `MIDENNAME_SKILLS_DIR` too, the skill instructs the agent to locate
   `miden-name.sh` with `find`. Verify any var with `echo $VAR` *inside a Bash tool
   call* — not your terminal.

3. Then ask, e.g., *"Is alice.miden available?"* or *"Register foo.miden from my account."*

## Configuration

Everything has a default — **no variable is required**.

| Env var | Purpose | Default |
|---------|---------|---------|
| `MIDENNAME_SKILLS_DIR` | Path to this repo (helps the agent find the wrapper; wrapper self-locates) | — |
| `MIDENNAME_CONTRACTS_DIR` | Reuse an existing `midenid-contracts` clone | auto-cloned to `~/.cache/midenname` |
| `MIDENNAME_CONTRACTS_REF` | Branch/tag to auto-clone | `simple-naming-0.14` (not `main`) |
| `MIDENNAME_CACHE_DIR` | Where to auto-clone | `~/.cache/midenname` |
| `MIDENNAME_NETWORK` | `testnet` or `devnet` | `testnet` |
| `MIDENNAME_NAMING_ACCOUNT` | Naming registry account id | `0x3b9988ed8357964061b97efe6a42b5` |
| `MIDENNAME_FAUCET_ID` | MIDEN payment-token faucet id | `0x0a7d175ed63ec5200fb2ced86f6aa5` |

Explorer: https://testnet.midenscan.com

> The registry prices in `0x0a7d…` (the public faucet token, **verified on-chain**) —
> not the `0x37d5…` listed in `midenid-backend/.env`. Addresses change on redeploy;
> trust the registry's on-chain `naming::prices` map. See `references/protocol.md`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Skill says env not set / `/scripts/miden-name.sh: not found` | `MIDENNAME_SKILLS_DIR` is empty. In Claude Code it must be in `~/.claude/settings.json` → `env`, not `~/.zshrc` (the Bash tool doesn't source shell profiles). Verify with `echo $MIDENNAME_SKILLS_DIR` inside a Bash tool call. |
| Auto-clone compiles with errors (missing `encode_domain_masm_key`, etc.) | A clone on the wrong branch. The code lives on `simple-naming-0.14`; `main` is older and won't compile. Set `MIDENNAME_CONTRACTS_REF=simple-naming-0.14` or remove the bad clone from `~/.cache/midenname`. |
| `register` says `Insufficient balance` but `balance` shows tokens | You hold the wrong token. The registry prices in `0x0a7d…`; fund from the public faucet and keep `MIDENNAME_FAUCET_ID` at the default. The error prints the vault's actual faucet ids. |
| `availability` still shows `true` right after `register` | Commit/sync lag — the registry state hasn't propagated yet. Wait a few seconds and re-run. |
| `register`/`consume` can't find the account or its key | `create-account`, `consume`, and `register` must resolve the **same** contracts clone (same keystore). Keep `MIDENNAME_CONTRACTS_DIR` consistent, or rely on the cached clone for all of them. |

## Status

Miden Name is in active development on testnet; contract addresses and behavior may
change. These skills target the current testnet deployment, have been verified
end-to-end (create → fund → register), and should be treated as experimental.

## License

MIT (declared in each skill's `SKILL.md` frontmatter). Add a top-level `LICENSE` file
before publishing if you want it explicit.
