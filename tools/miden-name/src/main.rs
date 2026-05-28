//! miden-name-helper — local, backend-free helpers for the Miden Name skills.
//!
//! Reuses the `midenname-contracts` crate's helpers (domain encoding, client
//! init, account creation, storage slots) and talks straight to the Miden node.
//! No backend service, and `midenid-contracts` itself is not modified.
//!
//! It is meant to run with its working directory inside the contracts clone, so
//! it shares the same `./store.sqlite3` and `./keystore` that the contracts CLI
//! (`register`, `find-and-consume-notes`) uses — one keystore signs everything.
//!
//! Subcommands:
//!   availability   — is a name free? (read-only, no key/funds)
//!   create-account — make a wallet, store its key in ./keystore, print its address
//!   balance        — report an account's balance of a given faucet token

use anyhow::Context;
use clap::{Parser, Subcommand};
use miden_client::account::AccountId;
use miden_crypto::Word;
use miden_protocol::address::NetworkId;
use midenname_contracts::{
    accounts::{create_deployer_account, safe_account_import},
    client::{create_keystore, initiate_client},
    domain::encode_domain_masm_key,
    storage::slot_name,
    utils::get_price_by_length,
};

#[derive(Parser)]
#[command(name = "miden-name-helper", about = "Backend-free Miden Name helpers", long_about = None)]
struct Cli {
    /// Use testnet (default: devnet, matching the contracts CLI convention)
    #[arg(long, global = true)]
    testnet: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Check whether a name is available (read-only)
    Availability {
        #[arg(long)]
        name: String,
        #[arg(long)]
        naming_account: String,
    },
    /// Create a wallet account, store its key in ./keystore, print its address
    CreateAccount,
    /// Report an account's balance of a faucet token
    Balance {
        #[arg(long)]
        account: String,
        #[arg(long)]
        faucet_id: String,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let net = if cli.testnet { NetworkId::Testnet } else { NetworkId::Devnet };

    match cli.command {
        Commands::Availability { name, naming_account } => availability(name, naming_account, cli.testnet).await,
        Commands::CreateAccount => create_account(cli.testnet, net).await,
        Commands::Balance { account, faucet_id } => balance(account, faucet_id, cli.testnet).await,
    }
}

async fn availability(name: String, naming_account: String, testnet: bool) -> anyhow::Result<()> {
    // Storage convention: `register` loads the domain word via `mem_loadw_be`, so
    // the stored map key is the reversed (big-endian) word.
    let key = encode_domain_masm_key(name.clone());

    let keystore = create_keystore()?;
    let mut client = initiate_client(keystore, testnet).await?;

    let naming_account = AccountId::from_hex(&naming_account)
        .with_context(|| format!("invalid naming-account id: {naming_account}"))?;
    safe_account_import(&mut client, naming_account).await?;
    client.sync_state().await?;

    let record = client
        .get_account(naming_account)
        .await?
        .with_context(|| format!("naming account {} not found on network (stale address?)", naming_account.to_hex()))?;
    let account: miden_protocol::account::Account = record.try_into()?;

    let owner: Word = account
        .storage()
        .get_map_item(&slot_name("naming::domain_to_owner"), key)?
        .into();

    let available = owner == Word::default();
    let price = get_price_by_length(&name);

    println!("\n=================================================");
    println!("Domain:    {name}.miden");
    println!("Length:    {} character(s)", name.len());
    println!("Available: {available}");
    if !available {
        println!("Owner word: {owner}");
    }
    println!("Price:     {price} base units / year (protocol list price)");
    println!("=================================================\n");
    println!("RESULT available={available} domain={name} price={price}");
    Ok(())
}

async fn create_account(testnet: bool, net: NetworkId) -> anyhow::Result<()> {
    let mut keystore = create_keystore()?;
    let mut client = initiate_client(keystore.clone(), testnet).await?;

    // Reuse the contracts helper: builds a BasicWallet (Falcon512) account, adds it
    // to the local store, and writes its key into ./keystore. (It prints its own
    // "Deployer account ID" line; the lines below are the ones to use.)
    let account = create_deployer_account(&mut client, &mut keystore).await?;
    let id = account.id();
    let bech32 = id.to_bech32(net);

    println!("\n=================================================");
    println!("Created account (key stored in ./keystore)");
    println!("Account id (hex):    {}", id.to_hex());
    println!("Account address:     {bech32}");
    println!("=================================================");
    println!("Next: fund this address from the faucet, then consume the minted note.");
    println!("RESULT account_hex={} account_bech32={bech32}", id.to_hex());
    Ok(())
}

async fn balance(account: String, faucet_id: String, testnet: bool) -> anyhow::Result<()> {
    let keystore = create_keystore()?;
    let mut client = initiate_client(keystore, testnet).await?;

    let account_id = AccountId::from_hex(&account)
        .with_context(|| format!("invalid account id: {account}"))?;
    let faucet = AccountId::from_hex(&faucet_id)
        .with_context(|| format!("invalid faucet id: {faucet_id}"))?;

    safe_account_import(&mut client, account_id).await?;
    client.sync_state().await?;

    let record = client
        .get_account(account_id)
        .await?
        .with_context(|| format!("account {} not found on network", account_id.to_hex()))?;
    let full: miden_protocol::account::Account = record.try_into()?;
    let bal = full.vault().get_balance(faucet)?;

    println!("\n=================================================");
    println!("Account: {}", account_id.to_hex());
    println!("Faucet:  {}", faucet.to_hex());
    println!("Balance: {bal} base units");
    println!("=================================================");
    println!("RESULT account={} faucet={} balance={bal}", account_id.to_hex(), faucet.to_hex());
    Ok(())
}
