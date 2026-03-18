---
name: linera-markets
description: Interact with Linera prediction markets. Query markets, place predictions, check positions, read results.
---

# Linera Markets — Developer Guide

A guide for developers who want to interact with **Linera Markets** programmatically — a real-time prediction market platform on the Linera blockchain.

## How Linera Markets Works

- **Parimutuel pricing**: all bets pool together; winners split the entire pool
- **Currency**: GMIC tokens (testnet)
- **Assets**: BTC, ETH, SOL
- **Durations**: 1-minute, 3-minute, 5-minute markets (each is a separate app instance)
- **Directions**: HIGHER = YesBid, LOWER = NoBid

**Key concepts:**

- **Generation**: each market round is called a "generation". `currentGeneration` gives the active one.
- **Multi-timeframe**: 3 simultaneous markets run on separate chains, each with its own generation config, YES/NO token pair, and app endpoint. The GMIC base token and oracle are shared.
- **Price scale**: prices are fixed-point integers. PRICE_SCALE = 1000 means price 1000 = 1.0, price 500 = 0.5.
- **Token precision**: 8 decimal places for display; internally Linera uses 18 decimals (attos).

**Market lifecycle:**

1. **OPEN** — `currentGeneration` is `Some(n)`, trading is active
2. **RESOLVED** — `resolutions.entry(key: n)` returns a `TimedResolution` with Yes or No
3. **NEXT** — generation advances automatically based on `generationConfig`

**Payout math:** If the YES pool is 6,000 GMIC and the NO pool is 4,000 GMIC, the total is 10,000. If YES wins, payout per YES token = 10,000 / 6,000 = **1.667x**. The less popular side always pays more.

## Architecture

Each timeframe runs as a **separate pm-parimutuel app instance** on its **own Linera chain** with dedicated YES/NO token pairs. The GMIC base token and oracle are shared across all markets.

| Market | Chain | App | YES Token | NO Token |
|--------|-------|-----|-----------|----------|
| **1-minute** | `CHAIN_1M` | `PM_APP_1M` | `YES_1M_APP_ID` | `NO_1M_APP_ID` |
| **3-minute** | `CHAIN_3M` | `PM_APP_3M` | `YES_3M_APP_ID` | `NO_3M_APP_ID` |
| **5-minute** | `CHAIN_5M` | `PM_APP_5M` | `YES_5M_APP_ID` | `NO_5M_APP_ID` |

Your code talks to **3 types of GraphQL endpoints**:

| App | Purpose |
|-----|---------|
| **pm-parimutuel** | Market state, betting, resolutions, trade history |
| **pm-fungible** | Token balances (YES, NO, GMIC) |
| **pm-faucet** | Free GMIC tokens for new users |

Each market has its own parimutuel endpoint: `http://host:port/chains/{CHAIN}/applications/{PM_APP}`.

Token endpoints (YES, NO, base GMIC) are **derived** from the parimutuel endpoint by querying `getParameters` and replacing the app ID in the URL. Override with `LINERA_FUNGIBLE_ENDPOINT` if tokens are on a different node.

## Configuration

Set these environment variables before making API calls:

| Variable | Description |
|----------|-------------|
| `LINERA_PARIMUTUEL_ENDPOINT` | Full URL to parimutuel app: `http://host:port/chains/CHAIN/applications/APP` |
| `LINERA_FAUCET_ENDPOINT` | URL to pm-faucet HTTP server (required for claiming tokens) |
| `LINERA_FUNGIBLE_ENDPOINT` | Override base URL for token apps (default: derived from parimutuel URL) |
| `LINERA_OWNER` | Your AccountOwner, e.g. `User:abc123...` |
| `LINERA_CHAIN_ID` | Your chain ID (required for faucet claims) |

### Helper Script

A convenience script is included at [`scripts/linera-api.sh`](../../scripts/linera-api.sh) that wraps common GraphQL calls into shell functions. Source it to get `query_market_state`, `place_prediction`, `get_positions`, and other helpers (assumes CWD is the repo root):

```bash
source scripts/linera-api.sh
```

The sections below show both the raw GraphQL and the shell helper equivalents.

## Core Operations

### 1. Query Active Markets

Get the current market state — pool sizes, generation, and config:

**GraphQL:**

```graphql
query {
  currentGeneration
  yesPool
  noPool
  generationConfig {
    numGenerations
    generationDuration
  }
  readInformation
}
```

**curl:**

```bash
curl "$LINERA_PARIMUTUEL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ currentGeneration yesPool noPool generationConfig { numGenerations generationDuration } readInformation }"}'
```

**Shell helper:**

```bash
source scripts/linera-api.sh
query_market_state
```

Compute multipliers from the pools: `total_pool / side_pool`. Example output:

```
Market: Will BTC close higher than opening price?
Generation: 42 of 288 | Duration: 300s (5m)
Status: OPEN

YES (HIGHER) Pool | NO (LOWER) Pool | YES Mult | NO Mult
6,000.00 GMIC     | 4,000.00 GMIC   | 1.667x   | 2.500x
```

### 2. Place a Prediction

Submit an order for the current generation:

**GraphQL mutation:**

```graphql
mutation {
  executeOrder(
    order: { quantity: "20.00000000", nature: "YesBid" }
    owner: "User:abc123..."
    generation: 42
  )
}
```

- `YesBid` = HIGHER (price will close above open)
- `NoBid` = LOWER (price will close below open)

**Shell helper:**

```bash
source scripts/linera-api.sh
place_prediction "HIGHER" "20.00000000"
```

Always check that `currentGeneration` is not null before placing an order.

### 3. Check Positions

Query your token balances and trade history:

**YES token balance** (query the YES fungible app):

```graphql
query {
  accounts {
    entry(key: { generation: 42, owner: "User:abc123..." }) {
      value
    }
  }
}
```

**NO token balance** (query the NO fungible app): same query structure.

**GMIC balance** (query the base fungible app):

```graphql
query {
  accounts {
    entry(key: "User:abc123...") {
      value
    }
  }
}
```

**Trade history** (query the parimutuel app):

```graphql
query {
  trades {
    entry(key: "User:abc123...") {
      value
    }
  }
}
```

**Shell helper:**

```bash
source scripts/linera-api.sh
get_positions
```

### 4. Get Settlement Results

Check how a specific generation resolved:

**GraphQL:**

```graphql
query {
  resolutions {
    entry(key: 42) {
      value {
        resolution
        timestamp
      }
    }
  }
}
```

Returns `resolution: "Yes"` (HIGHER won) or `"No"` (LOWER won).

For payout details:

```graphql
query {
  closedPools { entry(key: 42) { value } }
  payoutPrices { entry(key: 42) { value } }
}
```

**Shell helper:**

```bash
source scripts/linera-api.sh
get_market_result 42
```

### 5. Claim Free Tokens

Get testnet GMIC from the faucet (one-time per user):

**GraphQL mutation** (sent to the faucet endpoint):

```graphql
mutation {
  claim(owner: "User:abc123...", chainId: "YOUR_CHAIN_ID")
}
```

Returns `chainId`, `certificateHash`, and `amount`.

Check if you've already claimed:

```graphql
query {
  lastClaim(owner: "User:abc123...")
}
```

**Shell helper:**

```bash
source scripts/linera-api.sh
claim_faucet_tokens
```

### 6. Close Contracts (Redeem Winnings)

After a market resolves, redeem your winning tokens for GMIC:

**GraphQL mutation:**

```graphql
mutation {
  closeAllContracts(owner: "User:abc123...", generation: 42)
}
```

This redeems all YES and NO tokens held for that generation, paying out GMIC for winning positions.

**Shell helper:**

```bash
source scripts/linera-api.sh
close_all_contracts 42
```

## Direction Mapping

| User Term | API OrderNature | Token | Meaning |
|-----------|----------------|-------|---------|
| HIGHER | `YesBid` | YES | Bet that price closes above opening |
| LOWER | `NoBid` | NO | Bet that price closes below opening |
| (redeem YES) | `YesAsk` | YES | Sell YES tokens back after resolution |
| (redeem NO) | `NoAsk` | NO | Sell NO tokens back after resolution |

## GraphQL Reference

See `api-reference.md` for complete query and mutation examples with sample responses.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `LINERA_PARIMUTUEL_ENDPOINT` not set | Set it: `export LINERA_PARIMUTUEL_ENDPOINT=http://host:port/chains/CHAIN/applications/APP` |
| Connection refused | Linera node may be down. Verify with `curl $LINERA_PARIMUTUEL_ENDPOINT` |
| `currentGeneration` is null | All generations completed or market hasn't started. Check `generationConfig` |
| GraphQL errors | Schema may have changed. Run an introspection query (see `api-reference.md`) |
| "already claimed" from faucet | Each owner can only claim once |
| Token endpoint fails | Check that `getParameters` returns valid app IDs and the node URL is correct |
