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
#   MIDENNAME_CONFIG_URL      Live-config endpoint (default https://miden.name/config.json)
#   MIDENNAME_NO_FETCH        Set to 1 to skip the live-config fetch (use fallbacks)
#   MIDENNAME_NAMING_ACCOUNT  Override the registry account id (else: live config, else fallback)
#   MIDENNAME_FAUCET_ID       Override the payment-token faucet id (else: live config, else fallback)
#
# Addresses are resolved in priority order:
#   1. $MIDENNAME_NAMING_ACCOUNT / $MIDENNAME_FAUCET_ID (explicit)
#   2. https://miden.name/config.json (canonical live values)
#   3. hardcoded fallbacks baked into this script (may become stale on redeploy)
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

# Hardcoded fallbacks (kept current; used only if both the env var and the live
# config fetch are unavailable). Token: 0x0a7d... is the PUBLIC testnet faucet
# token, what the registry prices in — verified on-chain — and what
# faucet.testnet.miden.io / `miden-faucet-client` mint.
FALLBACK_NAMING_ACCOUNT="0x88f63686037e63406bbb8f5d01adb0"
FALLBACK_FAUCET_ID="0x0a7d175ed63ec5200fb2ced86f6aa5"

# Best-effort fetch of the canonical live config (miden.name/config.json).
# Skips the network call when both env vars are already set or MIDENNAME_NO_FETCH=1.
# Populates LIVE_NAMING_ACCOUNT and LIVE_FAUCET_ID on success; silent on failure.
LIVE_NAMING_ACCOUNT=""; LIVE_FAUCET_ID=""
fetch_live_config() {
  [ -n "${MIDENNAME_NAMING_ACCOUNT:-}" ] && [ -n "${MIDENNAME_FAUCET_ID:-}" ] && return 0
  [ "${MIDENNAME_NO_FETCH:-0}" = "1" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local url="${MIDENNAME_CONFIG_URL:-https://miden.name/config.json}"
  local json
  json="$(curl -fsS --max-time 5 "$url" 2>/dev/null)" || return 0
  LIVE_NAMING_ACCOUNT="$(printf '%s' "$json" \
    | grep -oE '"contractAddress"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' \
    | sed -E 's/.*"(0x[0-9a-fA-F]+)"$/\1/')"
  LIVE_FAUCET_ID="$(printf '%s' "$json" \
    | grep -oE '"faucetAddress"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' \
    | sed -E 's/.*"(0x[0-9a-fA-F]+)"$/\1/')"
}
fetch_live_config

NAMING_ACCOUNT="${MIDENNAME_NAMING_ACCOUNT:-${LIVE_NAMING_ACCOUNT:-$FALLBACK_NAMING_ACCOUNT}}"
FAUCET_ID="${MIDENNAME_FAUCET_ID:-${LIVE_FAUCET_ID:-$FALLBACK_FAUCET_ID}}"

# Note the source on stderr so it's easy to debug a wrong address.
if [ -n "${MIDENNAME_NAMING_ACCOUNT:-}" ] && [ -n "${MIDENNAME_FAUCET_ID:-}" ]; then
  : # fully overridden, no fetch needed
elif [ -n "$LIVE_NAMING_ACCOUNT" ] && [ -n "$LIVE_FAUCET_ID" ]; then
  echo "note: using live config from ${MIDENNAME_CONFIG_URL:-https://miden.name/config.json}" >&2
else
  echo "note: live config unavailable; using built-in fallback addresses" >&2
fi

die() { echo "error: $*" >&2; exit 1; }

# Resolve this repo (the script lives in <repo>/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_DIR="$REPO_ROOT/tools/miden-name"

# Show help without requiring any setup.
case "${1:-}" in
  ""|-h|--help) sed -n '2,49p' "$0"; exit 0 ;;
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
