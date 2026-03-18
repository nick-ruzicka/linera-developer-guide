# Linera Deployment Guide

## Local Development

### Start Services

**Terminal 1: Storage Service (local net only — not needed for testnet)**
```bash
# Only required when using `linera net up` for local development.
# Testnet wallets use RocksDB storage and don't need this.
linera-storage-service
```

**Terminal 2: Wallet and Service**
```bash
# Initialize wallet with new chain
linera wallet init --with-new-chain

# Start GraphQL service
linera service --port 8080
```

### Build Application

```bash
cargo build --release --target wasm32-unknown-unknown
```

Outputs:
- `target/wasm32-unknown-unknown/release/myapp_contract.wasm`
- `target/wasm32-unknown-unknown/release/myapp_service.wasm`

### Deploy Locally

```bash
# From project directory (uses Cargo.toml metadata)
linera project publish-and-create . --json-argument '"initial_value"'

# Or with explicit paths
linera publish-and-create \
  target/wasm32-unknown-unknown/release/myapp_contract.wasm \
  target/wasm32-unknown-unknown/release/myapp_service.wasm \
  --json-argument '42'
```

### Verify Deployment

```bash
# Get chain and app IDs
linera wallet show

# Test GraphQL endpoint
curl http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID> \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __typename }"}'
```

## Testnet Deployment

### Get Testnet Access

```bash
# Initialize wallet with testnet faucet (creates RocksDB-backed wallet — no storage service needed)
linera wallet init --with-new-chain --faucet https://faucet.testnet-conway.linera.net
```

To claim additional chains (e.g. for multi-chain setups), use the faucet's GraphQL API directly:

```bash
# 1. Generate a new keypair
OWNER=$(linera keygen)

# 2. Claim a chain from the faucet
CHAIN_ID=$(curl -s https://faucet.testnet-conway.linera.net \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { claim(publicKey: \\\"$OWNER\\\") }\"}" \
  | jq -r '.data.claim')

# 3. Assign the chain to your wallet
linera assign --owner "$OWNER" --chain-id "$CHAIN_ID"
```

### Deploy to Testnet

```bash
# Build in release mode
cargo build --release --target wasm32-unknown-unknown

# Deploy
linera project publish-and-create . --json-argument '"init_value"'
```

### Connect to Testnet Service

The testnet runs validators. Your local `linera service` connects to them:

```bash
linera service --port 8080
```

Now queries go through testnet validators.

## Multi-Chain Deployment

### Create Additional Chains

```bash
# Create a new chain owned by your wallet
linera open-chain

# View all your chains
linera wallet show
```

### Deploy Same App to Multiple Chains

```bash
# Deploy to specific chain
linera project publish-and-create . \
  --json-argument '"value"' \
  --chain <TARGET_CHAIN_ID>
```

### Cross-Chain App Interaction

Each chain gets its own application instance with separate state. Use cross-chain messaging to coordinate.

## GraphQL Service Configuration

### Port Configuration

```bash
linera service --port 8080
```

### Multiple Apps

One service exposes all deployed apps:

```
http://localhost:8080/chains/<CHAIN1>/applications/<APP1>
http://localhost:8080/chains/<CHAIN1>/applications/<APP2>
http://localhost:8080/chains/<CHAIN2>/applications/<APP1>
```

### Endpoint Structure

```
http://localhost:<PORT>/chains/<CHAIN_ID>/applications/<APP_ID>
```

- `PORT`: What you passed to `--port` (default 8080)
- `CHAIN_ID`: Hex string from `linera wallet show`
- `APP_ID`: Application ID from deployment output

## Troubleshooting

### "Storage service not found"

Only applies to local network development (`linera net up`). Start `linera-storage-service` in a separate terminal. Testnet wallets use RocksDB and don't need this.

### "Chain not found"

Ensure you've initialized a wallet with a chain:
```bash
linera wallet init --with-new-chain
```

### "Application not found"

Check app was deployed to the chain you're querying:
```bash
linera wallet show  # Lists apps per chain
```

### Build Failures

```bash
# Ensure wasm target installed
rustup target add wasm32-unknown-unknown

# Check Rust version
rustc --version  # Should be 1.86.0

# Try clean build
cargo clean
cargo build --release --target wasm32-unknown-unknown
```

### GraphQL 404

1. Verify service is running: `curl http://localhost:8080/`
2. Check chain ID is correct (case-sensitive hex)
3. Check app ID is correct
4. Ensure app is deployed to that specific chain

## Production Considerations

### State Management

- State persists across service restarts
- Wallet file contains keys - back it up
- Each chain's state is independent

### Performance

- Use `--release` builds for production
- Monitor GraphQL query complexity
- Consider indexing for large datasets

### Security

- Don't expose service publicly without authentication
- Wallet private keys should be protected
- Validate all user inputs in contract code
