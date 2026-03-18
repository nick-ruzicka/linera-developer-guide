# Faucet Claim Recipe

How to claim chains from a Linera faucet and transfer native tokens to a target chain. This is the primary mechanism for funding execution fees on testnet.

> **Native tokens vs GMIC**: The faucet gives you **native Linera tokens** used for blockchain execution fees (gas). These are completely separate from **GMIC tokens** used for betting in prediction markets. Both must be funded independently. If your agents have GMIC but no native tokens, transactions will fail with a Wasm unreachable error. If they have native tokens but no GMIC, bets will fail. Fund both.

---

## Prerequisites

- `linera` binary in PATH (version must match the target network)
- Faucet URL (e.g. `https://faucet.testnet-conway.linera.net` for Conway testnet)
- Target chain ID (the chain you want to fund with native tokens)

---

## Step-by-Step Recipe

Each faucet claim creates a new chain with ~100 native tokens. The flow is: generate a keypair, claim from faucet, discover the chain ID, assign it to your wallet, transfer native tokens out.

### 1. Generate a new keypair

```bash
linera keygen
```

**Output:** A public key / owner address, e.g.:
```
0x6a8b3f...
```

Save this as `$OWNER`.

### 2. Claim from faucet

HTTP POST to the faucet's GraphQL endpoint:

```bash
curl -s -X POST "$FAUCET_URL" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { claim(owner: \"'$OWNER'\") }"}'
```

**Response:**
```json
{"data": {"claim": "e3b0c442..."}}
```

The faucet creates a new chain owned by `$OWNER` with ~100 native tokens.

### 3. Query chain ID from faucet

```bash
curl -s -X POST "$FAUCET_URL" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ chainId(owner: \"'$OWNER'\") }"}'
```

**Response:**
```json
{"data": {"chainId": "a1b2c3d4e5f6..."}}
```

Save this as `$CHAIN_ID`.

### 4. Assign the chain to your wallet

```bash
linera assign --owner "$OWNER" --chain-id "$CHAIN_ID"
```

> **Warning: This step is slow.** `assign` iterates all validators to sync the chain state. Expect 60-90 seconds on Conway testnet. Set a 120s timeout if automating.

### 5. Transfer native tokens to target chain

```bash
linera transfer 95 --from "$CHAIN_ID" --to "$TARGET_CHAIN"
```

Transfer 95 of the ~100 native tokens, keeping 5 on the claimed chain to cover the transfer's own execution fee.

### 6. Deliver the transfer

The target chain must process its inbox to receive the tokens. If `linera service` is running with auto-inbox processing (default), this happens automatically. Otherwise:

```graphql
mutation { processInbox(chainId: "TARGET_CHAIN_ID") }
```

> **Note:** `processInbox` is a mutation on the **root service endpoint** (`http://localhost:8090`), NOT a chain-specific application endpoint.

---

## Using a Temp Wallet (Zero Downtime)

If your prod `linera service` is running and you can't stop it (RocksDB lock), use a temporary wallet for the entire faucet operation. The temp wallet is isolated — no conflict with the prod wallet or service.

```bash
# Create temp directory
TMPDIR=$(mktemp -d -t faucet-XXXX)

# Set env vars for temp wallet
export LINERA_WALLET="$TMPDIR/wallet.json"
export LINERA_KEYSTORE="$TMPDIR"
export LINERA_STORAGE="rocksdb:$TMPDIR/client.db"

# Initialize temp wallet from faucet (downloads genesis config)
linera wallet init --faucet "$FAUCET_URL"

# Now run the claim recipe (steps 1-5) — all commands use the temp wallet
# ...

# Clean up when done
rm -rf "$TMPDIR"
```

In Python:

```python
env = {
    **os.environ,
    "LINERA_WALLET": os.path.join(tmpdir, "wallet.json"),
    "LINERA_KEYSTORE": tmpdir,
    "LINERA_STORAGE": f"rocksdb:{os.path.join(tmpdir, 'client.db')}",
}
subprocess.run(["linera", "keygen"], env=env, capture_output=True, text=True)
```

After all transfers complete, use the **prod** service to process the target chain's inbox (the prod service owns that chain):

```graphql
mutation { processInbox(chainId: "TARGET_CHAIN_ID") }
```

---

## Batch Claiming

To fund a chain with more than ~95 native tokens, claim multiple faucet chains in sequence:

```python
chains_needed = math.ceil((target - current_balance) / 95)
for i in range(chains_needed):
    claim_and_transfer()  # steps 1-5
    time.sleep(2)         # rate limit — avoid hammering faucet
```

After all claims, call `processInbox` once — it delivers all pending transfers in one batch.

---

## Common Pitfalls

- **`assign` is the bottleneck** — 60-90s per chain. Budget for this when automating batch claims.
- **Keep 5 native for tx fee** — Transferring all 100 tokens will fail because the transfer itself costs a fee. Transfer 95.
- **Faucet rate limits** — Not explicitly documented. Add 2s sleep between claims to avoid rejections.
- **Faucet may be down** — HTTP POST returns connection error or 5xx. Log and retry on the next monitoring cycle.
- **Partial success is fine** — If 2 of 4 claims succeed, still call `processInbox` for the 2 that worked.
- **Chain IDs are unique** — Each `claim` creates a brand new chain. You can't claim the same chain twice.
