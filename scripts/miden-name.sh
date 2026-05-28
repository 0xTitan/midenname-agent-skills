#!/usr/bin/env bash
#
# miden-name.sh — stable command wrapper for the Miden Name skills.
#
# Runs entirely against the public Miden testnet — no backend service — and does
# NOT modify midenid-contracts. Commands split across two engines:
#
#   availability <name>            read-only: is <name>.miden free? + price
#   create-account                 make a wallet, key -> ./keystore, print address
#   balance <account>              account's balance of the MIDEN payment token
#       ^ these run the helper crate in this repo (tools/miden-name), which reuses
#         midenid-contracts helpers to read/build chain state.
#
#   register <name> --account <id> register/claim a name (spends MIDEN, submits tx)
#   consume <account>              consume pending notes (e.g. a faucet mint) into <account>
#       ^ these run the existing midenid-contracts CLI.
#
# Zero required setup: the contracts clone is resolved automatically —
#   1. $MIDENNAME_CONTRACTS_DIR if set, else
#   2. a sibling midenid-contracts clone next to this repo, else
#   3. cloned once from GitHub into $MIDENNAME_CACHE_DIR (default ~/.cache/midenname).
#
# Optional environment (testnet defaults shown — these CHANGE on redeploy, see
# references/setup.md for how to find the current values):
#   MIDENNAME_CONTRACTS_DIR   Path to an existing midenid-contracts clone (skips auto-clone)
#   MIDENNAME_CONTRACTS_REPO  Git URL to clone (default Digine-Labs/midenid-contracts)
#   MIDENNAME_CONTRACTS_REF   Branch/tag to clone (default simple-naming-0.14; NOT main,
#                             which is an older version that will not compile)
#   MIDENNAME_CACHE_DIR       Where to auto-clone (default ~/.cache/midenname)
#   MIDENNAME_NETWORK         "testnet" (default) or "devnet"
#   MIDENNAME_NAMING_ACCOUNT  Naming registry account id
#                             (default 0x3b9988ed8357964061b97efe6a42b5)
#   MIDENNAME_FAUCET_ID       MIDEN payment-token faucet id
#                             (default 0x0a7d175ed63ec5200fb2ced86f6aa5)
#
# Funding a test account (one-time):
#   1. create-account                         -> prints an address (mtst1...)
#   2a. miden-faucet-client mint --target-account <hex> --amount 100000000 --no-consume
#       (install once: cargo install miden-faucet-client), OR
#   2b. paste the address at https://faucet.testnet.miden.io (PUBLIC note)
#   3. consume <account-hex>                  -> pulls the minted note into the account
#   4. balance <account-hex>                  -> confirm it holds the token
#   5. register <name> --account <account-hex>
#
set -euo pipefail

NETWORK="${MIDENNAME_NETWORK:-testnet}"
NAMING_ACCOUNT="${MIDENNAME_NAMING_ACCOUNT:-0x3b9988ed8357964061b97efe6a42b5}"
# Token the registry prices in. Verified on-chain: registry 0x3b9988... prices in
# 0x0a7d... (the PUBLIC testnet faucet token), which is what faucet.testnet.miden.io
# and `miden-faucet-client` mint. (The backend .env's 0x37d5... is NOT this registry's
# payment token.)
FAUCET_ID="${MIDENNAME_FAUCET_ID:-0x0a7d175ed63ec5200fb2ced86f6aa5}"

die() { echo "error: $*" >&2; exit 1; }

# Resolve this repo (the script lives in <repo>/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_DIR="$REPO_ROOT/tools/miden-name"

# Show help without requiring any setup.
case "${1:-}" in
  ""|-h|--help) sed -n '2,42p' "$0"; exit 0 ;;
esac

# Resolve the contracts clone with zero required setup, in priority order:
#   1. $MIDENNAME_CONTRACTS_DIR (explicit)
#   2. a sibling clone next to this repo
#   3. a cached auto-clone of the public repo (cloned once, then reused)
looks_like_contracts() { [ -f "$1/Cargo.toml" ] && [ -d "$1/masm" ]; }

resolve_contracts_dir() {
  # 1. explicit
  if [ -n "${MIDENNAME_CONTRACTS_DIR:-}" ]; then
    looks_like_contracts "$MIDENNAME_CONTRACTS_DIR" \
      || die "MIDENNAME_CONTRACTS_DIR (${MIDENNAME_CONTRACTS_DIR}) is not a midenid-contracts clone (no Cargo.toml/masm)."
    CONTRACTS_DIR="$(cd "$MIDENNAME_CONTRACTS_DIR" && pwd)"; return
  fi
  # 2. sibling
  for cand in "$REPO_ROOT/../midenid-contracts" "$REPO_ROOT/../../midenid-contracts"; do
    if looks_like_contracts "$cand"; then
      CONTRACTS_DIR="$(cd "$cand" && pwd)"
      echo "note: using auto-detected contracts clone at $CONTRACTS_DIR" >&2
      return
    fi
  done
  # 3. cached auto-clone
  #    NOTE: the working code lives on the `simple-naming-0.14` branch — the repo's
  #    default `main` branch is an older version that lacks the helpers this crate
  #    needs (encode_domain_masm_key, two-arg initiate_client, ...) and will NOT compile.
  local cache="${MIDENNAME_CACHE_DIR:-$HOME/.cache/midenname}"
  local dest="$cache/midenid-contracts"
  local repo="${MIDENNAME_CONTRACTS_REPO:-https://github.com/Digine-Labs/midenid-contracts}"
  local ref="${MIDENNAME_CONTRACTS_REF:-simple-naming-0.14}"
  if looks_like_contracts "$dest"; then
    CONTRACTS_DIR="$(cd "$dest" && pwd)"; return
  fi
  command -v git >/dev/null 2>&1 || die "git not found and no contracts clone available. Install git or set MIDENNAME_CONTRACTS_DIR."
  echo "note: no contracts clone found — cloning $repo ($ref) into $dest (one-time)..." >&2
  mkdir -p "$cache"
  git clone --depth 1 --branch "$ref" "$repo" "$dest" 1>&2 \
    || die "auto-clone failed. Set MIDENNAME_CONTRACTS_DIR to a manual clone, or check MIDENNAME_CONTRACTS_REF=$ref exists."
  looks_like_contracts "$dest" || die "cloned repo at $dest does not look like midenid-contracts."
  CONTRACTS_DIR="$(cd "$dest" && pwd)"
}

resolve_contracts_dir

NET_FLAG=()
[ "$NETWORK" = "testnet" ] && NET_FLAG=(--testnet)

normalize_name() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/\.miden$//'; }

# Render the helper crate's Cargo.toml from its template, pointing the path
# dependency at the user's contracts clone. Regenerated only when missing or stale.
render_helper_manifest() {
  local tmpl="$HELPER_DIR/Cargo.toml.template"
  local out="$HELPER_DIR/Cargo.toml"
  [ -f "$tmpl" ] || die "missing $tmpl"
  local desired
  desired="$(sed "s#__MIDENNAME_CONTRACTS_DIR__#${CONTRACTS_DIR}#g" "$tmpl")"
  if [ ! -f "$out" ] || [ "$desired" != "$(cat "$out")" ]; then
    printf '%s\n' "$desired" > "$out"
  fi
}

# Run the helper crate. Runs from the contracts dir so it shares the same synced
# ./store.sqlite3 and ./keystore that the contracts CLI uses (one keystore for all).
run_helper() {
  render_helper_manifest
  cd "$CONTRACTS_DIR"
  exec cargo run --quiet --release --manifest-path "$HELPER_DIR/Cargo.toml" -- \
    "${NET_FLAG[@]}" "$@"
}

# Run the existing contracts CLI.
run_contracts() {
  cd "$CONTRACTS_DIR"
  exec cargo run --quiet --release -- "${NET_FLAG[@]}" "$@"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  availability)
    name="${1:-}"; shift || true
    [ -n "$name" ] || die "usage: miden-name.sh availability <name>"
    run_helper availability --name "$(normalize_name "$name")" --naming-account "$NAMING_ACCOUNT"
    ;;
  create-account)
    run_helper create-account
    ;;
  balance)
    account="${1:-}"; shift || true
    [ -n "$account" ] || die "usage: miden-name.sh balance <account_id>"
    run_helper balance --account "$account" --faucet-id "$FAUCET_ID"
    ;;
  register)
    name="${1:-}"; shift || true
    [ -n "$name" ] || die "usage: miden-name.sh register <name> --account <id>"
    name="$(normalize_name "$name")"
    account=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --account) account="$2"; shift 2 ;;
        --faucet-id) FAUCET_ID="$2"; shift 2 ;;
        --naming-account) NAMING_ACCOUNT="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    [ -n "$account" ] || die "register requires --account <your_account_id>"
    run_contracts register \
      --account "$account" \
      --naming-account "$NAMING_ACCOUNT" \
      --faucet-id "$FAUCET_ID" \
      --name "$name"
    ;;
  consume)
    account="${1:-}"; shift || true
    [ -n "$account" ] || die "usage: miden-name.sh consume <account_id>"
    run_contracts find-and-consume-notes --account "$account"
    ;;
  *)
    die "unknown command: $cmd (expected: availability | create-account | balance | register | consume)"
    ;;
esac
