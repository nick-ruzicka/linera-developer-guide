# RocksDB Locking Patterns and Workarounds

`linera service` holds an exclusive lock on its RocksDB database (`client.db`). While the service is running, no CLI commands can access the same wallet. This is the single biggest operational constraint when building on Linera.

This doc covers three patterns for working around the lock, and a reference table of which operations need which pattern.

---

## The Problem

```
$ linera transfer 10 --from CHAIN_A --to CHAIN_B
Error: Could not acquire lock on client.db
```

RocksDB allows only one process to open a database at a time. Since `linera service` keeps the database open for its entire lifetime, any `linera` CLI command using the same wallet will fail.

---

## Pattern 1: GraphQL Mutations Through Running Service

**Best option when available.** Send GraphQL mutations to the running `linera service` HTTP endpoint. No lock conflict because you're talking to the service, not opening the database directly.

### GMIC token transfer

```graphql
# Endpoint: http://localhost:8090/chains/{FROM_CHAIN}/applications/{TOKEN_APP_ID}
mutation {
  transfer(
    owner: "User:abc123..."
    amount: "1000."
    targetAccount: {
      chainId: "DEST_CHAIN_ID"
      owner: "User:def456..."
    }
  )
}
```

### Process inbox (deliver pending messages)

```graphql
# Endpoint: http://localhost:8090 (ROOT endpoint, not chain-specific)
mutation {
  processInbox(chainId: "CHAIN_ID")
}
```

> **Common mistake:** `processInbox` must be sent to the **root** service URL, not a chain application endpoint. It only works for chains in the service's wallet.

### Execute a prediction market order

```graphql
# Endpoint: http://localhost:8090/chains/{USER_CHAIN}/applications/{PM_APP_ID}
mutation {
  executeOrder(
    order: { quantity: "5.", nature: "YesBid" }
    owner: "User:abc123..."
    generation: 42
  )
}
```

### Query native balance

```graphql
# Endpoint: http://localhost:8090 (root)
{
  chain(chainId: "CHAIN_ID") {
    executionState { system { balance } }
  }
}
```

---

## Pattern 2: Stop Service → CLI → Restart

**Required for native token transfers** (no GraphQL equivalent exists). Causes 3-5s downtime — agents miss one generation.

```python
# 1. Kill the service
subprocess.run(["pkill", "-9", "-f", f"linera service.*{port}"])
time.sleep(3)

# 2. Run CLI command (now has exclusive lock)
subprocess.run(["linera", "transfer", "10", "--from", chain_a, "--to", chain_b])

# 3. Restart service
proc = subprocess.Popen(
    ["linera", "service", "--port", port],
    stdout=log_file, stderr=subprocess.STDOUT)

# 4. Wait until healthy
for _ in range(15):
    time.sleep(2)
    if service_responds():  # HTTP GET to service URL
        break
```

> **Warning:** Between steps 1 and 3, all agents lose their GraphQL endpoint. Bets in flight will fail. Time this during low-activity windows if possible.

---

## Pattern 3: Temp Wallet Isolation

**Best for operations that don't need the prod wallet** — faucet claims, chain creation, one-off transfers from disposable chains. Zero downtime because the temp wallet has its own database.

```python
tmpdir = tempfile.mkdtemp(prefix="linera-tmp-")
env = {
    **os.environ,
    "LINERA_WALLET": os.path.join(tmpdir, "wallet.json"),
    "LINERA_KEYSTORE": tmpdir,
    "LINERA_STORAGE": f"rocksdb:{os.path.join(tmpdir, 'client.db')}",
}

# Initialize from faucet (downloads genesis config)
subprocess.run(["linera", "wallet", "init", "--faucet", faucet_url], env=env)

# All subsequent commands use the temp wallet — no conflict with prod
subprocess.run(["linera", "keygen"], env=env)
subprocess.run(["linera", "assign", "--owner", owner, "--chain-id", chain_id], env=env)
subprocess.run(["linera", "transfer", "95", "--from", chain_id, "--to", target], env=env)

# Clean up
shutil.rmtree(tmpdir)
```

After the temp wallet completes its transfers, use the **prod** service's GraphQL to `processInbox` on the receiving chain (since the prod service owns it).

---

## CLI vs GraphQL Reference Table

| Operation | Method | Endpoint / Command | Downtime? |
|-----------|--------|--------------------|-----------|
| **GMIC transfer** | GraphQL mutation | `chains/{chain}/applications/{token_app}` | No |
| **Native token transfer** | CLI (Pattern 2) | `linera transfer N --from A --to B` | Yes (3-5s) |
| **Process inbox** | GraphQL mutation | Root endpoint: `mutation { processInbox(...) }` | No |
| **Execute order (bet)** | GraphQL mutation | `chains/{chain}/applications/{pm_app}` | No |
| **Query balance (GMIC)** | GraphQL query | `chains/{chain}/applications/{token_app}` | No |
| **Query balance (native)** | GraphQL query | Root: `chain(chainId) { executionState { system { balance } } }` | No |
| **Chain creation** | CLI (Pattern 3) | `linera open-chain` / faucet claim | No (temp wallet) |
| **Wallet init** | CLI (Pattern 3) | `linera wallet init --faucet URL` | No (temp wallet) |
| **Faucet claim** | CLI (Pattern 3) | `linera keygen` + `linera assign` | No (temp wallet) |
| **Follow remote chain** | CLI (Pattern 2) | `linera wallet follow-chain CHAIN --sync` | Yes |
| **Key generation** | CLI (Pattern 3) | `linera keygen` | No (temp wallet) |

---

## Common Pitfalls

- **Never copy `wallet.json`** — A copied wallet.json with a fresh RocksDB database will silently fail. The wallet state and database state must be created together. Always use `linera wallet init --faucet` for fresh wallets.

- **`LINERA_KEYSTORE` must be set** — When multiple wallets exist on the same machine, the CLI may pick the wrong keystore. Always set all three env vars (`LINERA_WALLET`, `LINERA_KEYSTORE`, `LINERA_STORAGE`) together.

- **Service restart is not instant** — After `Popen`, poll the HTTP endpoint every 2s until it responds. Budget 2-30s depending on wallet size and number of followed chains.

- **`linera service` auto-processes inboxes** — This is the default behavior. No need for a separate inbox processor. Only disabled with `--listener-skip-process-inbox`.

- **One service per wallet** — You cannot run two `linera service` instances against the same wallet.json. Use different ports AND different wallets for devnet vs prod.
