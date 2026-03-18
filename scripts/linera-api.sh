#!/usr/bin/env bash
# linera-api.sh — Bash helper for Linera Markets GraphQL API
# Source this file, then call the functions.
#
# Talks to 3 apps:
#   pm-parimutuel  — market state, betting, resolutions
#   pm-fungible    — YES/NO/GMIC token balances
#   pm-faucet      — free GMIC tokens

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Auto-load .env if env vars aren't already set
# ---------------------------------------------------------------------------
_SKILL_ENV="${LINERA_MARKETS_ENV:-$HOME/.config/linera-markets/.env}"
if [[ -z "${LINERA_PARIMUTUEL_ENDPOINT:-}" && -f "$_SKILL_ENV" ]]; then
  set -a
  source "$_SKILL_ENV"
  set +a
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LINERA_PARIMUTUEL_ENDPOINT="${LINERA_PARIMUTUEL_ENDPOINT:-}"
LINERA_FAUCET_ENDPOINT="${LINERA_FAUCET_ENDPOINT:-}"
LINERA_FUNGIBLE_ENDPOINT="${LINERA_FUNGIBLE_ENDPOINT:-}"
LINERA_OWNER="${LINERA_OWNER:-}"
LINERA_CHAIN_ID="${LINERA_CHAIN_ID:-}"
LINERA_MAX_POSITION="${LINERA_MAX_POSITION:-50}"
LINERA_MAX_DAILY_LOSS="${LINERA_MAX_DAILY_LOSS:-200}"
LINERA_MAX_CONSECUTIVE_LOSSES="${LINERA_MAX_CONSECUTIVE_LOSSES:-3}"
LINERA_PAPER_TRADE="${LINERA_PAPER_TRADE:-false}"
LINERA_TRADE_LOG="${LINERA_TRADE_LOG:-$HOME/.config/linera-markets/trade-log.jsonl}"

# Constants
PRICE_SCALE=1000

# Cache for token app IDs (populated by _init_token_endpoints)
_YES_TOKEN_ENDPOINT=""
_NO_TOKEN_ENDPOINT=""
_BASE_TOKEN_ENDPOINT=""

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_check_parimutuel_endpoint() {
  if [[ -z "$LINERA_PARIMUTUEL_ENDPOINT" ]]; then
    echo "ERROR: LINERA_PARIMUTUEL_ENDPOINT is not set."
    echo "  export LINERA_PARIMUTUEL_ENDPOINT=http://<host>:<port>/chains/<chain>/applications/<app>"
    return 1
  fi
}

_check_faucet_endpoint() {
  if [[ -z "$LINERA_FAUCET_ENDPOINT" ]]; then
    echo "ERROR: LINERA_FAUCET_ENDPOINT is not set."
    echo "  export LINERA_FAUCET_ENDPOINT=http://<host>:<port>"
    return 1
  fi
}

_check_owner() {
  if [[ -z "$LINERA_OWNER" ]]; then
    echo "ERROR: LINERA_OWNER is not set."
    echo "  export LINERA_OWNER='User:abc123...'"
    return 1
  fi
}

_graphql() {
  # Execute a GraphQL request against an endpoint.
  # Args: $1 = endpoint URL, $2 = query/mutation string
  local endpoint="$1"
  local query="$2"

  local payload
  payload=$(jq -n --arg q "$query" '{query: $q}')

  curl -s -X POST "$endpoint" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

_endpoint_base() {
  # Extract base URL from parimutuel endpoint (everything up to and including /applications/)
  # e.g., http://host:port/chains/CHAIN/applications/APP -> http://host:port/chains/CHAIN/applications/
  local base="${LINERA_FUNGIBLE_ENDPOINT:-}"
  if [[ -z "$base" ]]; then
    base=$(echo "$LINERA_PARIMUTUEL_ENDPOINT" | sed 's|/applications/.*|/applications/|')
  fi
  echo "$base"
}

_user_chain_endpoint() {
  # Construct the parimutuel endpoint on the USER's chain (CHAIN_1) instead of
  # the market chain (CHAIN_0). Linera parimutuel requires mutations to go through
  # user chains — the contract asserts chain_id != creator_chain_id.
  #
  # Queries go to CHAIN_0 (market state), mutations go to CHAIN_1 (user chain).
  if [[ -z "$LINERA_CHAIN_ID" ]]; then
    # Fallback to market endpoint if no user chain configured
    echo "$LINERA_PARIMUTUEL_ENDPOINT"
    return
  fi
  local app_id
  app_id=$(echo "$LINERA_PARIMUTUEL_ENDPOINT" | sed 's|.*/applications/||')
  local host_port
  host_port=$(echo "$LINERA_PARIMUTUEL_ENDPOINT" | sed 's|/chains/.*||')
  echo "${host_port}/chains/${LINERA_CHAIN_ID}/applications/${app_id}"
}

_token_endpoint() {
  # Construct a token endpoint from an app ID.
  # Args: $1 = application ID
  local app_id="$1"
  local base
  base=$(_endpoint_base)
  # If base already ends with /, don't double up
  if [[ "$base" == */ ]]; then
    echo "${base}${app_id}"
  else
    echo "${base}/${app_id}"
  fi
}

_init_token_endpoints() {
  # Fetch market parameters and construct token endpoints.
  # Caches results so we only call getParameters once per session.
  if [[ -n "$_YES_TOKEN_ENDPOINT" ]]; then
    return 0
  fi

  _check_parimutuel_endpoint || return 1

  local params_result
  params_result=$(_graphql "$LINERA_PARIMUTUEL_ENDPOINT" '{ getParameters { baseToken outcomeTokens priceScale } }')

  local base_token yes_token no_token
  base_token=$(echo "$params_result" | jq -r '.data.getParameters.baseToken // empty')
  yes_token=$(echo "$params_result" | jq -r '.data.getParameters.outcomeTokens[0] // empty')
  no_token=$(echo "$params_result" | jq -r '.data.getParameters.outcomeTokens[1] // empty')

  if [[ -z "$base_token" || -z "$yes_token" || -z "$no_token" ]]; then
    echo "ERROR: Failed to fetch market parameters. Response:"
    echo "$params_result" | jq . 2>/dev/null || echo "$params_result"
    return 1
  fi

  _BASE_TOKEN_ENDPOINT=$(_token_endpoint "$base_token")
  _YES_TOKEN_ENDPOINT=$(_token_endpoint "$yes_token")
  _NO_TOKEN_ENDPOINT=$(_token_endpoint "$no_token")

  # Update PRICE_SCALE from parameters if available
  local ps
  ps=$(echo "$params_result" | jq -r '.data.getParameters.priceScale // empty')
  if [[ -n "$ps" ]]; then
    PRICE_SCALE="$ps"
  fi
}

_log_trade() {
  # Append a trade entry to the trade log. Args: JSON string of trade data.
  local entry="$1"
  mkdir -p "$(dirname "$LINERA_TRADE_LOG")"
  echo "$entry" >> "$LINERA_TRADE_LOG"
}

_today() {
  date -u +"%Y-%m-%d"
}

_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------

check_position_size() {
  local amount="$1"
  if (( $(echo "$amount > $LINERA_MAX_POSITION" | bc -l) )); then
    echo "SAFETY: Amount $amount GMIC exceeds max position size of $LINERA_MAX_POSITION GMIC"
    return 1
  fi
}

check_daily_loss() {
  if [[ ! -f "$LINERA_TRADE_LOG" ]]; then
    return 0
  fi

  local today
  today=$(_today)

  local daily_loss
  daily_loss=$(grep "$today" "$LINERA_TRADE_LOG" 2>/dev/null \
    | jq -r 'select(.result == "LOSS") | .amount' \
    | paste -sd+ - \
    | bc -l 2>/dev/null || echo "0")

  if (( $(echo "$daily_loss >= $LINERA_MAX_DAILY_LOSS" | bc -l) )); then
    echo "SAFETY: Daily loss of $daily_loss GMIC has reached the limit of $LINERA_MAX_DAILY_LOSS GMIC"
    return 1
  fi
}

check_consecutive_losses() {
  if [[ ! -f "$LINERA_TRADE_LOG" ]]; then
    return 0
  fi

  local streak
  streak=$(tail -n "$LINERA_MAX_CONSECUTIVE_LOSSES" "$LINERA_TRADE_LOG" \
    | jq -r '.result // empty' \
    | grep -c "LOSS" || true)

  if (( streak >= LINERA_MAX_CONSECUTIVE_LOSSES )); then
    echo "SAFETY: $streak consecutive losses — circuit breaker tripped (limit: $LINERA_MAX_CONSECUTIVE_LOSSES)"
    return 1
  fi
}

run_safety_checks() {
  local amount="$1"
  check_position_size "$amount" || return 1
  check_daily_loss || return 1
  check_consecutive_losses || return 1
}

# ---------------------------------------------------------------------------
# API functions — pm-parimutuel
# ---------------------------------------------------------------------------

query_market_state() {
  # Query current market state: pools, generation, config, and info.
  _check_parimutuel_endpoint || return 1

  _graphql "$LINERA_PARIMUTUEL_ENDPOINT" '{
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
  }'
}

query_market_pools() {
  # Query just the pool sizes (lightweight).
  _check_parimutuel_endpoint || return 1

  _graphql "$LINERA_PARIMUTUEL_ENDPOINT" '{
    yesPool
    noPool
    currentGeneration
  }'
}

query_parameters() {
  # Get market parameters (token app IDs, price scale, event chain).
  _check_parimutuel_endpoint || return 1

  _graphql "$LINERA_PARIMUTUEL_ENDPOINT" '{
    getParameters {
      baseToken
      outcomeTokens
      eventChainId
      priceScale
    }
  }'
}

query_trade_history() {
  # Get trade history for the current owner.
  # Args: $1 = owner (optional, defaults to LINERA_OWNER)
  _check_parimutuel_endpoint || return 1
  local owner="${1:-$LINERA_OWNER}"
  _check_owner || return 1

  _graphql "$LINERA_PARIMUTUEL_ENDPOINT" "
    {
      trades {
        entry(key: \"$owner\") {
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
  "
}

get_market_result() {
  # Get resolution for a specific generation.
  # Args: $1 = generation number
  _check_parimutuel_endpoint || return 1
  local generation="$1"

  if [[ -z "$generation" ]]; then
    echo "ERROR: Generation number required. Usage: get_market_result <generation>"
    return 1
  fi

  _graphql "$LINERA_PARIMUTUEL_ENDPOINT" "
    {
      resolutions {
        entry(key: $generation) {
          value {
            resolution
            timestamp
          }
        }
      }
      payoutPrices {
        entry(key: $generation) {
          value
        }
      }
    }
  "
}

place_prediction() {
  # Place a prediction (bet) on the current market.
  # Args: $1 = direction (HIGHER/LOWER), $2 = amount (e.g., "20.00000000")
  _check_parimutuel_endpoint || return 1
  _check_owner || return 1
  local direction="$1"
  local amount="$2"

  if [[ -z "$direction" || -z "$amount" ]]; then
    echo "ERROR: Usage: place_prediction <HIGHER|LOWER> <amount>"
    return 1
  fi

  # Map direction to OrderNature
  local nature
  case "$direction" in
    HIGHER|higher|yes|YES) nature="YesBid" ;;
    LOWER|lower|no|NO)     nature="NoBid" ;;
    *) echo "ERROR: Direction must be HIGHER or LOWER, got: $direction"; return 1 ;;
  esac

  # Safety checks
  run_safety_checks "$amount" || return 1

  # Get current generation
  local state
  state=$(query_market_pools)

  local current_gen
  current_gen=$(echo "$state" | jq -r '.data.currentGeneration // empty')

  if [[ -z "$current_gen" || "$current_gen" == "null" ]]; then
    echo "ERROR: No active generation. Market may be between rounds or finished."
    return 1
  fi

  local yes_pool no_pool
  yes_pool=$(echo "$state" | jq -r '.data.yesPool // "0"')
  no_pool=$(echo "$state" | jq -r '.data.noPool // "0"')

  # Compute current multiplier for display
  local total_pool multiplier
  total_pool=$(echo "$yes_pool + $no_pool + $amount" | bc -l 2>/dev/null || echo "0")
  if [[ "$nature" == "YesBid" ]]; then
    local side_pool
    side_pool=$(echo "$yes_pool + $amount" | bc -l 2>/dev/null || echo "$amount")
    multiplier=$(echo "scale=3; $total_pool / $side_pool" | bc -l 2>/dev/null || echo "?")
  else
    local side_pool
    side_pool=$(echo "$no_pool + $amount" | bc -l 2>/dev/null || echo "$amount")
    multiplier=$(echo "scale=3; $total_pool / $side_pool" | bc -l 2>/dev/null || echo "?")
  fi

  # Paper trade mode
  if [[ "$LINERA_PAPER_TRADE" == "true" ]]; then
    local entry
    entry=$(jq -n \
      --arg ts "$(_now_iso)" \
      --arg dir "$direction" \
      --arg nat "$nature" \
      --arg amt "$amount" \
      --argjson gen "$current_gen" \
      --arg mult "$multiplier" \
      '{
        timestamp: $ts, direction: $dir, nature: $nat,
        amount: $amt, generation: $gen,
        multiplier_at_entry: ($mult | tonumber),
        paper: true, result: null, payout: null
      }')
    _log_trade "$entry"
    echo "PAPER TRADE — not executed"
    echo "$entry" | jq .
    return 0
  fi

  # Execute the real mutation (must go through USER chain, not market chain)
  local user_endpoint
  user_endpoint=$(_user_chain_endpoint)
  local result
  result=$(_graphql "$user_endpoint" "
    mutation {
      executeOrder(
        order: {quantity: \"$amount\", nature: \"$nature\"},
        owner: \"$LINERA_OWNER\",
        generation: $current_gen
      )
    }
  ")

  # Check for errors (response may be a string hash on success, or object with .errors)
  local errors
  errors=$(echo "$result" | jq -r '.errors // empty' 2>/dev/null || true)
  if [[ -n "$errors" && "$errors" != "null" ]]; then
    echo "ERROR placing prediction:"
    echo "$result" | jq '.errors' 2>/dev/null || echo "$result"
    return 1
  fi
  local err_field
  err_field=$(echo "$result" | jq -r '.error // empty' 2>/dev/null || true)
  if [[ -n "$err_field" && "$err_field" != "null" ]]; then
    echo "ERROR placing prediction: $err_field"
    return 1
  fi

  # Log the trade
  local entry
  entry=$(jq -n \
    --arg ts "$(_now_iso)" \
    --arg dir "$direction" \
    --arg nat "$nature" \
    --arg amt "$amount" \
    --argjson gen "$current_gen" \
    --arg mult "$multiplier" \
    '{
      timestamp: $ts, direction: $dir, nature: $nat,
      amount: $amt, generation: $gen,
      multiplier_at_entry: ($mult | tonumber),
      paper: false, result: null, payout: null
    }')
  _log_trade "$entry"

  echo "Order placed: $direction ($nature) $amount GMIC on generation $current_gen"
  echo "Estimated multiplier: ${multiplier}x"
  echo "$result" | jq .
}

close_all_contracts() {
  # Redeem all YES/NO tokens for a resolved generation.
  # Args: $1 = generation number
  _check_parimutuel_endpoint || return 1
  _check_owner || return 1
  local generation="$1"

  if [[ -z "$generation" ]]; then
    echo "ERROR: Generation number required. Usage: close_all_contracts <generation>"
    return 1
  fi

  local user_endpoint
  user_endpoint=$(_user_chain_endpoint)
  _graphql "$user_endpoint" "
    mutation {
      closeAllContracts(
        owner: \"$LINERA_OWNER\",
        generation: $generation
      )
    }
  "
}

# ---------------------------------------------------------------------------
# API functions — pm-fungible (token balances)
# ---------------------------------------------------------------------------

query_gmic_balance() {
  # Query GMIC (base token) balance.
  # Args: $1 = owner (optional, defaults to LINERA_OWNER)
  _init_token_endpoints || return 1
  local owner="${1:-$LINERA_OWNER}"
  _check_owner || return 1

  _graphql "$_BASE_TOKEN_ENDPOINT" "
    {
      accounts {
        entry(key: \"$owner\") {
          value
        }
      }
    }
  "
}

query_yes_balance() {
  # Query YES token balance for a specific generation.
  # Args: $1 = generation, $2 = owner (optional)
  _init_token_endpoints || return 1
  local generation="$1"
  local owner="${2:-$LINERA_OWNER}"
  _check_owner || return 1

  if [[ -z "$generation" ]]; then
    echo "ERROR: Generation number required. Usage: query_yes_balance <generation> [owner]"
    return 1
  fi

  _graphql "$_YES_TOKEN_ENDPOINT" "
    {
      accounts {
        entry(key: {generation: $generation, owner: \"$owner\"}) {
          value
        }
      }
    }
  "
}

query_no_balance() {
  # Query NO token balance for a specific generation.
  # Args: $1 = generation, $2 = owner (optional)
  _init_token_endpoints || return 1
  local generation="$1"
  local owner="${2:-$LINERA_OWNER}"
  _check_owner || return 1

  if [[ -z "$generation" ]]; then
    echo "ERROR: Generation number required. Usage: query_no_balance <generation> [owner]"
    return 1
  fi

  _graphql "$_NO_TOKEN_ENDPOINT" "
    {
      accounts {
        entry(key: {generation: $generation, owner: \"$owner\"}) {
          value
        }
      }
    }
  "
}

query_cost_basis() {
  # Query cost basis for YES or NO tokens.
  # Args: $1 = "yes" or "no", $2 = generation, $3 = owner (optional)
  _init_token_endpoints || return 1
  local token_side="$1"
  local generation="$2"
  local owner="${3:-$LINERA_OWNER}"
  _check_owner || return 1

  local endpoint
  case "$token_side" in
    yes|YES) endpoint="$_YES_TOKEN_ENDPOINT" ;;
    no|NO)   endpoint="$_NO_TOKEN_ENDPOINT" ;;
    *) echo "ERROR: Token side must be 'yes' or 'no'"; return 1 ;;
  esac

  _graphql "$endpoint" "
    {
      costBasis {
        entry(key: {generation: $generation, owner: \"$owner\"}) {
          value
        }
      }
    }
  "
}

get_positions() {
  # Get full position summary: trade history + token balances.
  _check_parimutuel_endpoint || return 1
  _check_owner || return 1

  echo "=== Market State ==="
  local state
  state=$(query_market_pools)
  echo "$state" | jq '.data'

  local current_gen
  current_gen=$(echo "$state" | jq -r '.data.currentGeneration // empty')

  if [[ -n "$current_gen" && "$current_gen" != "null" ]]; then
    echo ""
    echo "=== Token Balances (Generation $current_gen) ==="
    echo "--- GMIC (base) ---"
    query_gmic_balance | jq '.data.accounts.entry.value // "0"'

    echo "--- YES tokens ---"
    query_yes_balance "$current_gen" | jq '.data.accounts.entry.value // "0"'

    echo "--- NO tokens ---"
    query_no_balance "$current_gen" | jq '.data.accounts.entry.value // "0"'
  fi

  echo ""
  echo "=== Trade History ==="
  query_trade_history | jq '.data.trades.entry.value.entries // []'

  echo ""
  echo "=== Session P&L ==="
  get_daily_pnl
}

# ---------------------------------------------------------------------------
# API functions — pm-faucet
# ---------------------------------------------------------------------------

check_faucet_claim() {
  # Check if the owner has already claimed faucet tokens.
  # Args: $1 = owner (optional, defaults to LINERA_OWNER)
  _check_faucet_endpoint || return 1
  local owner="${1:-$LINERA_OWNER}"
  _check_owner || return 1

  _graphql "$LINERA_FAUCET_ENDPOINT" "
    query {
      lastClaim(owner: \"$owner\") {
        chainId
        timestamp
      }
    }
  "
}

claim_faucet_tokens() {
  # Claim free GMIC tokens from the faucet.
  _check_faucet_endpoint || return 1
  _check_owner || return 1

  if [[ -z "$LINERA_CHAIN_ID" ]]; then
    echo "ERROR: LINERA_CHAIN_ID is not set."
    echo "  export LINERA_CHAIN_ID='<your-chain-id>'"
    return 1
  fi

  # Check if already claimed
  local last_claim
  last_claim=$(check_faucet_claim)
  local already_claimed
  already_claimed=$(echo "$last_claim" | jq -r '.data.lastClaim // empty')

  if [[ -n "$already_claimed" && "$already_claimed" != "null" ]]; then
    echo "Already claimed. Previous claim:"
    echo "$last_claim" | jq '.data.lastClaim'
    return 1
  fi

  # Execute claim
  _graphql "$LINERA_FAUCET_ENDPOINT" "
    mutation {
      claim(owner: \"$LINERA_OWNER\", chainId: \"$LINERA_CHAIN_ID\") {
        chainId
        certificateHash
        amount
      }
    }
  "
}

# ---------------------------------------------------------------------------
# Schema discovery
# ---------------------------------------------------------------------------

introspect_schema() {
  # Discover the actual GraphQL schema of an endpoint.
  # Args: $1 = endpoint URL (optional, defaults to parimutuel)
  local endpoint="${1:-$LINERA_PARIMUTUEL_ENDPOINT}"

  _graphql "$endpoint" '
    {
      __schema {
        types {
          name
          fields {
            name
            type { name kind ofType { name } }
          }
        }
      }
    }
  '
}

# ---------------------------------------------------------------------------
# Trade log analysis
# ---------------------------------------------------------------------------

get_daily_pnl() {
  # Print today's P&L summary
  if [[ ! -f "$LINERA_TRADE_LOG" ]]; then
    echo '{"trades": 0, "wins": 0, "losses": 0, "pending": 0, "pnl": 0}'
    return 0
  fi

  local today
  today=$(_today)

  local today_trades
  today_trades=$(grep "$today" "$LINERA_TRADE_LOG" 2>/dev/null || true)

  if [[ -z "$today_trades" ]]; then
    echo '{"trades": 0, "wins": 0, "losses": 0, "pending": 0, "pnl": 0}'
    return 0
  fi

  local total wins losses pending
  total=$(echo "$today_trades" | wc -l | tr -d ' ')
  wins=$(echo "$today_trades" | jq -r 'select(.result == "WIN")' 2>/dev/null | jq -s 'length')
  losses=$(echo "$today_trades" | jq -r 'select(.result == "LOSS")' 2>/dev/null | jq -s 'length')
  pending=$(echo "$today_trades" | jq -r 'select(.result == null)' 2>/dev/null | jq -s 'length')

  local total_payouts total_losses_amt
  total_payouts=$(echo "$today_trades" | jq -r 'select(.result == "WIN") | .payout // 0' 2>/dev/null \
    | paste -sd+ - | bc -l 2>/dev/null || echo "0")
  total_losses_amt=$(echo "$today_trades" | jq -r 'select(.result == "LOSS") | .amount // 0' 2>/dev/null \
    | paste -sd+ - | bc -l 2>/dev/null || echo "0")

  local pnl
  pnl=$(echo "$total_payouts - $total_losses_amt" | bc -l 2>/dev/null || echo "0")

  jq -n \
    --argjson trades "$total" \
    --argjson wins "$wins" \
    --argjson losses "$losses" \
    --argjson pending "$pending" \
    --argjson pnl "$pnl" \
    '{trades: $trades, wins: $wins, losses: $losses, pending: $pending, pnl: $pnl}'
}

update_trade_result() {
  # Update a trade in the log with its result.
  # Args: $1 = generation, $2 = result (WIN/LOSS), $3 = payout amount
  local generation="$1"
  local result="$2"
  local payout="$3"

  if [[ ! -f "$LINERA_TRADE_LOG" ]]; then
    echo "ERROR: No trade log found"
    return 1
  fi

  # Use a temp file to update in place — match by generation
  local tmpfile
  tmpfile=$(mktemp)

  jq -c --argjson gen "$generation" --arg res "$result" --argjson pay "$payout" '
    if .generation == $gen and .result == null then .result = $res | .payout = $pay else . end
  ' "$LINERA_TRADE_LOG" > "$tmpfile"

  mv "$tmpfile" "$LINERA_TRADE_LOG"
  echo "Updated generation $generation: $result (payout: $payout GMIC)"
}
