# Linera Developer Guide

> The production-tested guide to building real-time applications and prediction markets on Linera.

Linera is a real-time Web3 protocol built on microchain architecture — each user and application gets dedicated blockchains that communicate asynchronously. This guide covers everything needed to build, deploy, and operate Linera applications, from first contract to production-scale systems.

The `skills/` directory contains the full guides, structured for use as [Claude Code](https://claude.ai/code) skills. They are plain markdown and readable directly.

## Validated Results

Without this guide, 0 of 4 AI-generated Linera application files compile against the current SDK. With it, 3-4 of 4 compile on the first attempt. [Full methodology →](VALIDATION.md)

## Quick Start

### Install as Claude Code Skills

```bash
git clone https://github.com/nick-ruzicka/linera-developer-guide.git

# Personal install (available in all projects):
cp -r linera-developer-guide/skills/linera-dev ~/.claude/skills/
cp -r linera-developer-guide/skills/linera-markets ~/.claude/skills/

# Or project-local install:
cp -r linera-developer-guide/skills/linera-dev .claude/skills/
cp -r linera-developer-guide/skills/linera-markets .claude/skills/
```

### Use the Shell Toolkit

```bash
cd linera-developer-guide
source scripts/linera-api.sh
query_market_state
place_prediction HIGHER "20.00000000"
get_positions
```

## Guides

### [Building Applications on Linera](skills/linera-dev/SKILL.md)

Build Rust/WebAssembly applications with on-chain contracts, GraphQL APIs, cross-chain messaging, and MCP integration for AI assistants.

### [Linera Prediction Markets](skills/linera-markets/SKILL.md)

Interact with parimutuel prediction markets — query market state, place predictions, track positions, check resolutions, and redeem winnings.

## What's Inside

| Topic | What You Get |
|-------|-------------|
| Application architecture | Contract + Service pattern, state management, ABI definitions |
| Storage | Complete linera-views guide — RegisterView, MapView, CollectionView, LogView, QueueView, SetView |
| Cross-chain messaging | Transfer patterns, subscription patterns, bounce handling |
| Deployment | Local dev, Conway testnet, multi-chain setups |
| Testing | Unit tests, service tests, contract tests, cross-chain message tests, integration tests |
| MCP integration | Connect AI assistants to on-chain apps via Apollo MCP Server |
| Scaling | Multi-wallet partitioning to stay within GRPC channel limits |
| Prediction markets API | Full GraphQL reference with sample requests and responses |
| Operational patterns | RocksDB locking workarounds, resolution timing, faucet claims, multi-environment setup |
| Shell toolkit | 30+ bash functions — market queries, order placement, position tracking, PnL analysis, safety checks |

## Contributing

Contributions are welcome. See [Areas for Contribution](VALIDATION.md#areas-for-contribution) for known gaps.

## License

[Apache-2.0](LICENSE)
