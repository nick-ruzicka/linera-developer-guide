# Linera Markets API Reference

GraphQL queries and mutations for the Linera prediction market apps (`pm-parimutuel`, `pm-fungible`, `pm-faucet`).

## Endpoint URLs

Each app has its own GraphQL endpoint:

```
pm-parimutuel: http://<node>:<port>/chains/<chain_id>/applications/<parimutuel_app_id>
pm-fungible:   http://<node>:<port>/chains/<chain_id>/applications/<token_app_id>
pm-faucet:     http://<faucet_host>:<faucet_port>/
```

Token app IDs (YES, NO, base GMIC) are discovered via `getParameters` on the parimutuel app.

---

## Schema Discovery

Run this to verify field names on any endpoint:

```bash
source scripts/linera-api.sh
introspect_schema | jq '.data.__schema.types[] | select(.fields != null) | {name, fields: [.fields[].name]}'
```

---

## pm-parimutuel Queries

### Get Market State (pools, generation, config)

**Request:**
```graphql
{
  yesPool
  noPool
  currentGeneration
  generationConfig
  resolutionDelay
  readInformation {
    title
    category
    description
    rules
    keywords
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "yesPool": "6000.00000000",
    "noPool": "4000.00000000",
    "currentGeneration": 42,
    "generationConfig": {
      "start": 1707580800000000,
      "duration_secs": 300,
      "num_generations": 288
    },
    "resolutionDelay": null,
    "readInformation": {
      "title": "BTC 5-min: Will price close higher?",
      "category": "Crypto",
      "description": "Predict whether BTC closes above its opening price in this 5-minute window.",
      "rules": "YES wins if close > open. NO wins if close <= open.",
      "keywords": ["BTC", "bitcoin", "5min"]
    }
  }
}
```

**Notes:**
- `yesPool` and `noPool` are `Amount` strings (up to 18 decimal places, display with 8)
- `generationConfig` is a JSON scalar: `{start: Timestamp, duration_secs: u64, num_generations: u64}`
- `Timestamp` is microseconds since Unix epoch
- `currentGeneration` is `null` when market hasn't started or all generations are done
- Multiplier = `(yesPool + noPool) / sidePool` — no house fee

### Get Market Parameters

**Request:**
```graphql
{
  getParameters {
    baseToken
    outcomeTokens
    eventChainId
    priceScale
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "getParameters": {
      "baseToken": "91aaf5fddbf0c1b977158345509bf73127cd359af16d2cc6417696b9d425d604",
      "outcomeTokens": [
        "a1b2c3d4e5f6...yes_token_app_id",
        "f6e5d4c3b2a1...no_token_app_id"
      ],
      "eventChainId": "e476187f6ddfeb9d588c7b45d3df334d5501d6499b3f9ad5595cae86cce16a65",
      "priceScale": 1000
    }
  }
}
```

**Notes:**
- `outcomeTokens[0]` = YES token app ID, `outcomeTokens[1]` = NO token app ID
- `priceScale` = 1000 means price integer 1000 = 1.0, 500 = 0.5
- Use these app IDs to construct token balance endpoints

### Get Pool Sizes Only (lightweight)

**Request:**
```graphql
{
  yesPool
  noPool
  currentGeneration
}
```

### Get Resolution for a Generation

**Request:**
```graphql
{
  resolutions {
    entry(key: 42) {
      value {
        resolution
        timestamp
      }
    }
  }
  payoutPrices {
    entry(key: 42) {
      value
    }
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "resolutions": {
      "entry": {
        "value": {
          "resolution": "Yes",
          "timestamp": 1707582300000000
        }
      }
    },
    "payoutPrices": {
      "entry": {
        "value": 1667
      }
    }
  }
}
```

**Notes:**
- `resolution`: `"Yes"` = HIGHER won, `"No"` = LOWER won
- `payoutPrices.value`: payout per winning token in price_scale units (1667 / 1000 = 1.667x)
- Entry is `null` if generation hasn't been resolved yet

### Get Trade History for an Owner

**Request:**
```graphql
{
  trades {
    entry(key: "User:abc123def456...") {
      value {
        entries {
          nature
          amount
          costBasis
          generation
        }
      }
    }
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "trades": {
      "entry": {
        "value": {
          "entries": [
            {
              "nature": "YesAsk",
              "amount": "33.34000000",
              "costBasis": "20.00000000",
              "generation": 41
            },
            {
              "nature": "NoAsk",
              "amount": "0.",
              "costBasis": "15.00000000",
              "generation": 40
            }
          ]
        }
      }
    }
  }
}
```

**Notes:**
- `nature`: `YesAsk` = sold YES tokens (cashed out), `NoAsk` = sold NO tokens
- `amount` = how much GMIC was received from the sale
- `costBasis` = how much GMIC was originally spent
- Profit = amount - costBasis (negative = loss)
- Trades only appear after `closeAllContracts` is called

---

## pm-parimutuel Mutations

### Place a Bet (executeOrder)

**Request:**
```graphql
mutation {
  executeOrder(
    order: {quantity: "20.00000000", nature: "YesBid"},
    owner: "User:abc123def456...",
    generation: 42
  )
}
```

**Sample Response (success):**
```json
{
  "data": {
    "executeOrder": null
  }
}
```

**Sample Response (error):**
```json
{
  "errors": [
    {
      "message": "Cannot add bet to a different generation",
      "locations": [{"line": 2, "column": 3}]
    }
  ]
}
```

**Notes:**
- `nature` values: `"YesBid"` (HIGHER), `"NoBid"` (LOWER), `"YesAsk"` (redeem YES), `"NoAsk"` (redeem NO)
- `quantity` is an Amount string — must be a valid decimal with up to 18 decimal places
- `owner` must be the AccountOwner string (e.g., `"User:abc123..."`)
- `generation` must match `currentGeneration` — betting on past/future generations fails
- Success returns `null` for the mutation field (no return value)
- Errors appear in the `errors` array

### Close All Contracts (redeem tokens)

**Request:**
```graphql
mutation {
  closeAllContracts(
    owner: "User:abc123def456...",
    generation: 41
  )
}
```

**Sample Response:**
```json
{
  "data": {
    "closeAllContracts": null
  }
}
```

**Notes:**
- Call this after a generation resolves to collect winnings
- Redeems ALL YES and NO tokens for the specified generation
- Winning tokens get paid out at the payout price; losing tokens pay 0
- The payout shows up in `trades` history as a `YesAsk` or `NoAsk` entry

---

## pm-fungible Queries (Token Balances)

### GMIC (Base Token) Balance

The base token uses the standard Linera fungible token ABI. Key is just the owner:

**Request (to base token endpoint):**
```graphql
{
  accounts {
    entry(key: "User:abc123def456...") {
      value
    }
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "accounts": {
      "entry": {
        "value": "1500.00000000"
      }
    }
  }
}
```

### YES/NO Token Balance

YES and NO tokens use `pm-fungible` with a `GenerationOwner` key (generation + owner):

**Request (to YES or NO token endpoint):**
```graphql
{
  accounts {
    entry(key: {generation: 42, owner: "User:abc123def456..."}) {
      value
    }
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "accounts": {
      "entry": {
        "value": "20.00000000"
      }
    }
  }
}
```

**Notes:**
- `entry` is `null` if no balance exists
- YES token balance = how many YES contracts you hold for that generation
- NO token balance = how many NO contracts you hold

### Cost Basis

**Request (to YES or NO token endpoint):**
```graphql
{
  costBasis {
    entry(key: {generation: 42, owner: "User:abc123def456..."}) {
      value
    }
  }
}
```

**Sample Response:**
```json
{
  "data": {
    "costBasis": {
      "entry": {
        "value": "20.00000000"
      }
    }
  }
}
```

### Ticker Symbol

**Request (to any pm-fungible endpoint):**
```graphql
{
  tickerSymbol
}
```

**Response:** `{"data": {"tickerSymbol": "YES"}}` or `"NO"`

---

## pm-faucet Queries and Mutations

The faucet is a standalone HTTP server (NOT a Linera on-chain app).

### Check Last Claim

**Request:**
```graphql
query {
  lastClaim(owner: "User:abc123def456...") {
    chainId
    timestamp
  }
}
```

**Sample Response (never claimed):**
```json
{
  "data": {
    "lastClaim": null
  }
}
```

**Sample Response (already claimed):**
```json
{
  "data": {
    "lastClaim": {
      "chainId": "e476187f6ddfeb9d588c7b45d3df334d5501d6499b3f9ad5595cae86cce16a65",
      "timestamp": 1707580000000000
    }
  }
}
```

### Claim Tokens

**Request:**
```graphql
mutation {
  claim(owner: "User:abc123def456...", chainId: "e476187f6ddfeb9d588c7b45d3df334d5501d6499b3f9ad5595cae86cce16a65") {
    chainId
    certificateHash
    amount
  }
}
```

**Sample Response (success):**
```json
{
  "data": {
    "claim": {
      "chainId": "e476187f6ddfeb9d588c7b45d3df334d5501d6499b3f9ad5595cae86cce16a65",
      "certificateHash": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
      "amount": "1000.00000000"
    }
  }
}
```

**Sample Response (already claimed):**
```json
{
  "errors": [
    {
      "message": "This user has already claimed tokens"
    }
  ]
}
```

**Sample Response (rate limited):**
```json
{
  "errors": [
    {
      "message": "Not enough unlocked balance; try again later."
    }
  ]
}
```

---

## curl Examples

### Query market state (pm-parimutuel)

```bash
curl -s -X POST "$LINERA_PARIMUTUEL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ yesPool noPool currentGeneration generationConfig resolutionDelay }"}' \
  | jq .
```

### Place a HIGHER bet (pm-parimutuel)

```bash
curl -s -X POST "$LINERA_PARIMUTUEL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { executeOrder(order: {quantity: \\\"20.00000000\\\", nature: \\\"YesBid\\\"}, owner: \\\"$LINERA_OWNER\\\", generation: 42) }\"}" \
  | jq .
```

### Check GMIC balance (base token)

```bash
curl -s -X POST "$BASE_TOKEN_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"{ accounts { entry(key: \\\"$LINERA_OWNER\\\") { value } } }\"}" \
  | jq .
```

### Check YES token balance for generation 42

```bash
curl -s -X POST "$YES_TOKEN_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"{ accounts { entry(key: {generation: 42, owner: \\\"$LINERA_OWNER\\\"}) { value } } }\"}" \
  | jq .
```

### Check resolution for generation 42

```bash
curl -s -X POST "$LINERA_PARIMUTUEL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ resolutions { entry(key: 42) { value { resolution timestamp } } } payoutPrices { entry(key: 42) { value } } }"}' \
  | jq .
```

### Claim faucet tokens

```bash
curl -s -X POST "$LINERA_FAUCET_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { claim(owner: \\\"$LINERA_OWNER\\\", chainId: \\\"$LINERA_CHAIN_ID\\\") { chainId certificateHash amount } }\"}" \
  | jq .
```

### Close all contracts for generation 41

```bash
curl -s -X POST "$LINERA_PARIMUTUEL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { closeAllContracts(owner: \\\"$LINERA_OWNER\\\", generation: 41) }\"}" \
  | jq .
```

---

## Type Reference

### Amount
String with up to 18 decimal places. Display with 8. Examples: `"100."`, `"20.00000000"`, `"0.50000000"`

### AccountOwner
String: `"User:<hex_public_key>"`. Example: `"User:abc123def456789..."`

### ChainId
Hex string (64 chars). Example: `"e476187f6ddfeb9d588c7b45d3df334d5501d6499b3f9ad5595cae86cce16a65"`

### Timestamp
Integer: microseconds since Unix epoch. Example: `1707580800000000` = 2024-02-10T16:00:00Z

### Price
Integer (u64). Divide by PRICE_SCALE (1000) for display. Example: `1667` = 1.667x payout

### OrderNature (scalar)
One of: `"YesBid"`, `"YesAsk"`, `"NoBid"`, `"NoAsk"`

### Resolution (scalar)
One of: `"Yes"`, `"No"`

### GenerationConfig (scalar)
JSON: `{"start": <Timestamp>, "duration_secs": <u64>, "num_generations": <u64>}`

### Order (InputObject)
```graphql
{quantity: "<Amount>", nature: "<OrderNature>"}
```

### GenerationOwner (InputObject — pm-fungible key)
```graphql
{generation: <u64>, owner: "<AccountOwner>"}
```

---

## Trade Log Format

Each trade is stored as a JSON line in `trade-log.jsonl`:

**Entry at placement time:**
```json
{
  "timestamp": "2026-01-15T14:32:00Z",
  "direction": "HIGHER",
  "nature": "YesBid",
  "amount": "20.00000000",
  "generation": 42,
  "multiplier_at_entry": 1.667,
  "paper": false,
  "result": null,
  "payout": null
}
```

**After settlement (WIN):**
```json
{
  "timestamp": "2026-01-15T14:32:00Z",
  "direction": "HIGHER",
  "nature": "YesBid",
  "amount": "20.00000000",
  "generation": 42,
  "multiplier_at_entry": 1.667,
  "paper": false,
  "result": "WIN",
  "payout": 33.34
}
```

**After settlement (LOSS):**
```json
{
  "timestamp": "2026-01-15T14:32:00Z",
  "direction": "HIGHER",
  "nature": "YesBid",
  "amount": "20.00000000",
  "generation": 42,
  "multiplier_at_entry": 1.667,
  "paper": false,
  "result": "LOSS",
  "payout": 0
}
```
