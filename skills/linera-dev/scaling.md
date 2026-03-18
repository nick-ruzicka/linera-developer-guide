# Multi-Process Scaling for Linera Applications

When running many microchains from a single machine — automated bots, multi-user services, or any system that manages chains on behalf of others — you will hit GRPC channel limits if all chains live in one wallet.

## The Problem

A Linera wallet is a client-side abstraction that holds keys for one or more microchains. Each microchain maintains GRPC connections to validators. Google's GRPC implementation caps the number of channels allowed per connection.

When a single wallet holds too many microchains, the total GRPC channel count exceeds this limit. The result: **all operations on that wallet start failing**, not just the newest chains.

### Symptoms

- Bots or processes crash with GRPC transport errors
- Operations that previously worked start failing after adding more chains
- Errors appear to be network-related but the node is healthy
- The problem gets worse as you add chains, and may appear suddenly after a Linera update changes connection behavior

## The Fix: Partition Across Multiple Wallets

Instead of one wallet holding all your chains, split them into groups — each group gets its own wallet and runs in its own `linera service` process.

### Before (broken at scale)

```
┌─────────────────────────────┐
│  Single Wallet              │
│  CHAIN_1, CHAIN_2, ...      │
│  CHAIN_N (too many)         │
│                             │
│  linera service --port 8080 │
└─────────────────────────────┘
        │
        ▼
   GRPC limit hit → all chains fail
```

### After (scales)

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Wallet A        │  │  Wallet B        │  │  Wallet C        │
│  CHAIN_1–10      │  │  CHAIN_11–20     │  │  CHAIN_21–30     │
│                  │  │                  │  │                  │
│  linera service  │  │  linera service  │  │  linera service  │
│  --port 8080     │  │  --port 8081     │  │  --port 8082     │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

### How to Set Up Multiple Wallets

1. **Create separate wallet directories** for each group:

```bash
# Wallet A
mkdir -p wallets/group-a
LINERA_WALLET=wallets/group-a/wallet.json \
LINERA_STORAGE=rocksdb:wallets/group-a/client.db \
  linera wallet init --with-new-chain --faucet <FAUCET_URL>

# Wallet B
mkdir -p wallets/group-b
LINERA_WALLET=wallets/group-b/wallet.json \
LINERA_STORAGE=rocksdb:wallets/group-b/client.db \
  linera wallet init --with-new-chain --faucet <FAUCET_URL>
```

2. **Assign chains to wallets** when creating them:

```bash
# Create chains in wallet A
LINERA_WALLET=wallets/group-a/wallet.json \
LINERA_STORAGE=rocksdb:wallets/group-a/client.db \
  linera open-chain
```

3. **Run a separate `linera service` per wallet**, each on its own port:

```bash
LINERA_WALLET=wallets/group-a/wallet.json \
LINERA_STORAGE=rocksdb:wallets/group-a/client.db \
  linera service --port 8080 &

LINERA_WALLET=wallets/group-b/wallet.json \
LINERA_STORAGE=rocksdb:wallets/group-b/client.db \
  linera service --port 8081 &
```

4. **Point each bot/process at the correct port** for its wallet group.

## How Many Chains Per Wallet?

There is no single documented threshold — it depends on the number of validators, the GRPC implementation version, and connection multiplexing behavior. The limit has changed across Linera updates.

**Practical guidance:**

- If you have fewer than ~10 chains, a single wallet is usually fine
- If you're running dozens of chains, partition proactively — don't wait for failures
- Start with 10–15 chains per wallet and increase cautiously if needed
- Monitor for GRPC transport errors as your signal to split further

## Key Points

- **RocksDB locking**: each wallet's storage directory can only be opened by one `linera service` process at a time. Separate directories are mandatory, not optional.
- **Chain funding**: each wallet's initial chain needs native tokens. Fund them via faucet or transfer from an existing chain before creating sub-chains.
- **Cross-wallet communication**: chains in different wallets communicate the same way as any cross-chain messaging — there's no difference from the protocol's perspective.
- **Identical apps**: you can deploy the same application across chains in different wallets. The app ID is determined by the bytecode, not the wallet.
