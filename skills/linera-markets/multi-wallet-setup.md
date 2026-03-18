# Multi-Wallet / Multi-Environment Setup

How to run multiple Linera wallets on one machine — devnet and prod simultaneously, temp wallets for faucet operations, and isolated agent environments. Getting this wrong causes silent failures, corrupted state, or locked databases.

---

## Why Multiple Wallets

- **Devnet + prod coexistence** — Test on devnet (port 8080) while prod runs on Conway (port 8090)
- **Temp operations** — Faucet claims, chain creation without stopping prod service (see [RocksDB Locking](rocksdb-locking.md))
- **Agent isolation** — Each `linera service` process needs its own wallet+database

---

## The 3 Environment Variables

Every `linera` CLI command and `linera service` instance reads these:

| Variable | Points To | Example |
|----------|-----------|---------|
| `LINERA_WALLET` | `wallet.json` file path | `/home/nick/.prod/wallet.json` |
| `LINERA_KEYSTORE` | Directory containing key files | `/home/nick/.prod/` |
| `LINERA_STORAGE` | RocksDB database URI | `rocksdb:/home/nick/.prod/client.db` |

> **All three must be set together.** If you set `LINERA_WALLET` but not `LINERA_KEYSTORE`, the CLI may find keys from a different wallet and silently use the wrong keypair.

```bash
# Prod environment
export LINERA_WALLET="$HOME/.prod-deploy/wallet.json"
export LINERA_KEYSTORE="$HOME/.prod-deploy/"
export LINERA_STORAGE="rocksdb:$HOME/.prod-deploy/client.db"

# Devnet environment (in a different shell)
export LINERA_WALLET="$HOME/.local-deploy/wallet.json"
export LINERA_KEYSTORE="$HOME/.local-deploy/"
export LINERA_STORAGE="rocksdb:$HOME/.local-deploy/client.db"
```

---

## Creating Fresh Wallets

**Always create wallets from scratch. Never copy an existing `wallet.json`.**

```bash
# Set env vars first, then init
export LINERA_WALLET="/path/to/new/wallet.json"
export LINERA_KEYSTORE="/path/to/new/"
export LINERA_STORAGE="rocksdb:/path/to/new/client.db"

linera wallet init --faucet "https://faucet.testnet-conway.linera.net"
```

This creates `wallet.json`, generates initial keys in the keystore directory, creates the RocksDB database, and claims an initial chain from the faucet (which also downloads the genesis config for the network).

> **Why not copy?** A copied `wallet.json` references chain states that exist in the old RocksDB database. A fresh database has no chain state, so the wallet and database are out of sync. Operations will silently fail or return wrong data.

---

## Devnet + Prod Coexistence

Running both environments on the same VPS:

| | Devnet | Prod (Conway) |
|---|--------|--------------|
| **Binary** | `/path/to/devnet/linera` | `/path/to/prod/linera` |
| **Service port** | 8080 | 8090 |
| **State dir** | `.local-deploy/` | `.prod-deploy/` |
| **Faucet** | `http://localhost:8079` (local) | `https://faucet.testnet-conway.linera.net` |

```bash
# Terminal 1: Devnet
export PATH="/path/to/devnet/bin:$PATH"
source .local-deploy/state.env
linera service --port 8080

# Terminal 2: Prod
export PATH="/path/to/prod/bin:$PATH"
source .prod-deploy/state.env
linera service --port 8090
```

> **Binary version must match the network.** Using a devnet binary against Conway testnet (or vice versa) will fail with protocol version mismatch errors. Always set PATH to the correct binary first.

---

## Read-Only Chain Access

To query market state from chains you don't own (no keypair in your wallet):

```bash
linera wallet follow-chain CHAIN_ID --sync
```

This adds the chain as read-only and syncs all existing blocks. Once followed, `linera service` receives real-time updates via gRPC push from validators.

**Performance impact:** Local queries to followed chains: ~4ms. Queries via Conway RPC endpoint: hundreds of ms.

```bash
# Follow all 9 market chains (do this once)
for chain in $BTC_1M_CHAIN $BTC_3M_CHAIN $BTC_5M_CHAIN \
             $ETH_1M_CHAIN $ETH_3M_CHAIN $ETH_5M_CHAIN \
             $SOL_1M_CHAIN $SOL_3M_CHAIN $SOL_5M_CHAIN; do
    linera wallet follow-chain "$chain" --sync
done
```

> **Requires stopping the service** (RocksDB lock). Follow chains during initial setup, not while agents are running.

---

## `linera_spawn` Trap

The `linera_spawn` bash helper (used in deploy scripts) creates its own temp directory and overrides `LINERA_TMP_DIR`:

```bash
# WRONG — value will be overwritten by linera_spawn
LINERA_TMP_DIR=$(mktemp -d)
linera_spawn ...  # creates its own temp dir, sets EXIT trap

# CORRECT — read the value AFTER spawn
linera_spawn ...
echo "Temp dir is: $LINERA_TMP_DIR"  # now has the spawn-created path
```

`linera_spawn` also sets a shell EXIT trap to clean up its temp directory. If you set your own EXIT trap before calling spawn, it will be overwritten.

---

## Common Pitfalls

- **`LINERA_KEYSTORE` is required with multiple wallets** — Without it, `linera` searches default paths and may find keys from a different wallet. Always set all three env vars.

- **One `linera service` per wallet** — Two services can't open the same `client.db`. Use different wallets AND different ports.

- **Copied wallets silently fail** — The most common mistake. `wallet.json` + fresh RocksDB = broken state. Always `linera wallet init --faucet`.

- **PID recycling fools process monitors** — If you kill agent processes, the OS may assign their PIDs to new processes. A naive `os.kill(pid, 0)` check returns True for any process at that PID, even a completely different one. **Always kill the supervisor first**, then kill agents. Order matters. A proper fix verifies the process command line, not just PID existence.

- **State files store env vars** — Deploy scripts write `LINERA_WALLET`, `LINERA_KEYSTORE`, `LINERA_STORAGE` to `state.env`. Source this file to restore the correct environment:
  ```bash
  source .prod-deploy/state.env
  ```

- **Wasm unreachable on unfunded chains** — Sending a transaction from a chain with zero native tokens causes a Wasm trap (not a graceful error). Fund chains with native tokens BEFORE starting agents.
