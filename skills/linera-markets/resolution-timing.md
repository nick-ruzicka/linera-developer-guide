# Resolution Timing Semantics

How prediction market generations open, close, and resolve on Linera. Understanding the timing is critical for agents — fetching prices too early returns stale data, too late and pools have already cleared.

---

## Generation Lifecycle Timeline

For a 60-second generation with 60-second `resolutionDelay` (Conway testnet default):

```
T=0s        T=60s              T=120s         T=125-126s
 |            |                  |               |
 GEN OPEN     GEN CLOSE          RESOLUTION      ORACLE DELIVERY
 |            |                  DELAY EXPIRES    COMPLETES
 |            |                  |               |
 ├── betting ─┤                  ├── oracle ─────┤
 |  window    |                  |  polls price  |
 |            |                  |  + publishes  |
 |            |                  |  + cross-chain|
 |            |                  |    message    |
```

- **T=0**: Generation opens. `currentGeneration` advances (but only if a mutation triggers `update_generation_state`).
- **T=60**: Generation closes. No more bets accepted.
- **T=120**: `resolutionDelay` expires. Oracle is now allowed to resolve this generation.
- **T=125-126**: Oracle actually resolves (polling interval + cross-chain message delivery adds 5-6s jitter).

---

## `resolutionDelay` Config

The parimutuel contract adds `resolutionDelay` seconds after generation close before accepting a resolution from the oracle.

- **Conway testnet**: `resolutionDelay: 60` seconds
- **This is set at market creation** and cannot be changed mid-run

> **Warning:** The 60-second delay means resolution happens at T=120, NOT T=60. If your agent sleeps until gen close (T=60) and immediately fetches the resolve price, it will get stale or no data.

---

## Agent Timing Pattern

The correct pattern for waiting for resolution:

```python
# Wait for generation to close
remaining = gen_timer.time_until_next_gen()
if remaining > 0:
    time.sleep(remaining)

# Wait for resolution: resolutionDelay + buffer
time.sleep(resolution_delay + 3)  # e.g. 60 + 3 = 63s for Conway

# NOW fetch the resolve price
resolve_price = get_spot_price(asset)
```

> **The buffer (3s) accounts for oracle polling and cross-chain delivery jitter.** Actual resolution lands 5-6s after the delay expires, but 3s buffer is enough because the oracle starts polling slightly before the delay expires. Tune this if you see agents reading pre-resolution prices.

> **Important:** The `resolution_delay + 3` pattern is tuned to the market's `resolutionDelay` config. If you deploy a market with a different `resolutionDelay` (e.g. 30s), adjust accordingly: `sleep(30 + 3)`, not `sleep(63)`.

---

## Stale `currentGeneration` Pitfall

`update_generation_state` **only runs on mutations**. GraphQL queries are read-only and return stale state.

```graphql
# This may return an OLD generation number:
{ currentGeneration }

# This triggers state update and returns current:
mutation { executeOrder(...) }
# Then query:
{ currentGeneration }
```

**Workaround for agents:** Don't rely on `currentGeneration` from queries to know which generation is active. Instead, calculate it from the generation config:

```python
gen = (now - start_timestamp) // duration_secs
```

---

## Pool State Lifecycle

Pools clear after resolution. The timeline:

| Time | `yesPool` / `noPool` | Notes |
|------|---------------------|-------|
| During generation | Accumulating bets | Query returns current pool sizes |
| After gen close, before resolution | Frozen | Same values as at close |
| After resolution | `0` / `0` | **Cleared** — pool data is gone |

> **Critical for PnL tracking:** If you need pool state for payout calculation, snapshot it BEFORE the generation closes. After resolution, `fetch_pools` returns 0/0 and you've lost the data.

```python
# CORRECT — snapshot before gen close
pools_snapshot = fetch_pools(market_ep)  # save this
time.sleep(remaining + resolution_delay + 3)
# Use pools_snapshot for PnL math

# WRONG — pools already cleared
time.sleep(remaining + resolution_delay + 3)
pools = fetch_pools(market_ep)  # returns (0, 0)!
```

---

## GreaterThan Draw Behavior

The oracle uses `CompareWithPreviousData { GreaterThan }` to determine outcomes:

| Price Movement | Result | Winner |
|---------------|--------|--------|
| Close > Open | YES | HIGHER bettors |
| Close < Open | NO | LOWER bettors |
| Close = Open (DRAW) | **NO** | **LOWER bettors win** |

> **GreaterThan means strictly greater.** Equal price is NOT greater, so it resolves as NO. There is no separate DRAW outcome — it's a NO win.

**Strategic implication:** When pool skew is near the threshold and you're choosing between HIGHER and LOWER, prefer LOWER. You get a free edge on draws. In low-volatility periods (e.g. BTC sideways at night), draws happen more often than you'd expect on 60-second windows.

---

## Generation Config Is Sticky

`generationConfig` is set at market creation and cannot be modified:

```json
{
  "generationConfig": {
    "start": 1707580800000000,
    "duration_secs": 60,
    "num_generations": 18446744073709551615
  }
}
```

- `start`: Microsecond timestamp when generation 0 began
- `num_generations: u64::MAX` = effectively infinite (Conway)
- `duration_secs: 60` = each generation is 60 seconds

**If you need different settings, you must redeploy the market.** This means a new chain, new app ID, new YES/NO tokens — all state is lost. Plan your generation config carefully before deploying.

---

## Quick Reference

| Parameter | Conway Value | Notes |
|-----------|-------------|-------|
| `durationSecs` | 60 | Generation length |
| `resolutionDelay` | 60 | Seconds after gen close before oracle can resolve |
| Actual resolution | T+120 to T+126 | Delay + oracle jitter |
| Agent sleep | `resolutionDelay + 3` | Configurable, not hardcoded 63 |
| Draw outcome | NO wins | GreaterThan → equal is not greater |
| Pool clear | After resolution | Snapshot before gen close |
