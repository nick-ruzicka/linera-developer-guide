---
name: linera-dev
description: Build real-time Web3 applications on Linera using Rust, linera-sdk, linera-views, and GraphQL. Covers on-chain contracts, services, microchains, cross-chain messaging, and MCP integration.
user-invocable: true
---

# Linera Development Skill

Use this skill for building decentralized applications on Linera—a protocol designed for real-time Web3 applications with microchain architecture.

## When to Use

- Creating Linera on-chain applications (contracts + services)
- Building GraphQL APIs for Linera apps
- Implementing cross-chain messaging between microchains
- Setting up MCP integration for AI-assisted blockchain interaction
- Testing and deploying Linera applications

## Learning from Examples

The canonical reference for working Linera apps is the [`examples/` directory in linera-protocol](https://github.com/linera-io/linera-protocol/tree/testnet_conway/examples) on the `testnet_conway` branch. Before inventing patterns, check how the examples do it.

- **`counter`** — the simplest complete app. Start here to understand the basic structure (ABI, state, contract, service, deployment).
- **`fungible`** — token operations and cross-chain transfers. Shows `MapView` for balances and authenticated messaging.
- **`crowd-funding`** — a more complex multi-party pattern with pledges, deadlines, and cross-app calls.
- **`social`** — subscription-based cross-chain messaging between users.

When in doubt about how an API works, read the example code rather than guessing.

## Default Stack Decisions

1. **Language**: Rust compiled to WebAssembly (wasm32-unknown-unknown target). No other languages are supported for on-chain code.

2. **Framework**: `linera-sdk` is the only option. Use the latest version matching your Linera CLI.

3. **Storage**: `linera-views` for all persistent state. Never use raw key-value storage or in-memory state that won't persist.

4. **API Layer**: GraphQL via `async-graphql`. Every Linera app exposes queries through a Service. Mutations schedule operations.

5. **Client Integration**: GraphQL over HTTP at `http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID>`. Use MCP for AI assistants.

6. **External Data**: Linera contracts can call external web services via `perform_http_request` in `BaseRuntime`. Domain access is restricted on validators — check the Linera documentation for currently allowed domains.

## Prerequisites

### Testnet Branch

**Important**: For current testnet compatibility, use the `testnet_conway` branch of linera-protocol, not `main`:

```bash
git clone https://github.com/linera-io/linera-protocol.git
cd linera-protocol
git checkout testnet_conway
```

### Required Versions

```toml
# rust-toolchain.toml
[toolchain]
channel = "1.86.0"
components = ["clippy", "rustfmt", "rust-src"]
targets = ["wasm32-unknown-unknown"]
```

### System Dependencies

| Dependency | Version | Install Command |
|------------|---------|-----------------|
| Rust | 1.86.0 | `rustup default 1.86.0` |
| Wasm target | - | `rustup target add wasm32-unknown-unknown` |
| protoc | 21.x (not 28+) | macOS: `brew install protobuf@21` / Linux: download v21.12 from GitHub releases |
| Linera CLI | 0.15.8 | `cargo install linera-service linera-storage-service` |

### macOS Additional Setup

```bash
# Install LLVM (required for compilation)
brew install llvm@18
export PATH="/opt/homebrew/opt/llvm@18/bin:$PATH"
```

### Linux Additional Setup

```bash
sudo apt-get install g++ libclang-dev libssl-dev
```

## Application Structure

Every Linera application has three components:

```
my-app/
├── Cargo.toml
└── src/
    ├── lib.rs      # ABI definitions (Operation, Message types)
    ├── state.rs    # State using linera-views
    ├── contract.rs # On-chain logic (Contract trait)
    └── service.rs  # GraphQL API (Service trait)
```

### Cargo.toml Template

```toml
[package]
name = "my-app"
version = "0.1.0"
edition = "2021"

[dependencies]
async-graphql = { version = "7.0", default-features = false }
linera-sdk = "0.15"
serde = { version = "1.0", features = ["derive"] }

[[bin]]
name = "my-app_contract"
path = "src/contract.rs"

[[bin]]
name = "my-app_service"
path = "src/service.rs"

[dev-dependencies]
linera-sdk = { version = "0.15", features = ["test", "wasmer"] }
tokio = { version = "1", features = ["rt", "macros"] }
```

## Quick Start Walkthrough

End-to-end sequence for building a Linera app. Each step references the detailed section below it.

1. **Create project directory and `Cargo.toml`** — use the template in "Application Structure" above. Two `[[bin]]` targets: `<name>_contract` and `<name>_service`.
2. **Add `rust-toolchain.toml`** — pin Rust 1.86.0 with `wasm32-unknown-unknown` target. See "Prerequisites > Required Versions".
3. **Define ABI in `src/lib.rs`** — declare `Operation`, `Message` enums and implement `ContractAbi` + `ServiceAbi`. See "Define ABI" below.
4. **Define state in `src/state.rs`** — derive `RootView` and `SimpleObject`, use `RegisterView`/`MapView` for persistent fields. See "Define State" below.
5. **Implement contract in `src/contract.rs`** — implement the `Contract` trait (`load`, `instantiate`, `execute_operation`, `execute_message`, `store`). See "Implement Contract" below.
6. **Implement service in `src/service.rs`** — implement the `Service` trait, build a GraphQL schema with query root (state) and mutation root. See "Implement Service" below.
7. **Build** — `cargo build --release --target wasm32-unknown-unknown`
8. **Start local services** — run `linera-storage-service` (local dev only), then `linera wallet init --with-new-chain` and `linera service --port 8080`. See "Build, Deploy, Test" below.
9. **Deploy** — `linera project publish-and-create . --json-argument '<INIT_ARG>'`
10. **Test via GraphQL** — query `http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID>` with a GraphQL client or curl.

## Core Patterns

### 1. Define ABI (lib.rs)

```rust
use async_graphql::{Request, Response};
use linera_sdk::base::{ContractAbi, ServiceAbi};
use serde::{Deserialize, Serialize};

// Operations users can perform
#[derive(Debug, Deserialize, Serialize)]
pub enum Operation {
    DoSomething { value: u64 },
}

// Messages for cross-chain communication
#[derive(Debug, Deserialize, Serialize)]
pub enum Message {
    Credit { amount: u64, target: Owner },
}

pub struct MyAppAbi;

impl ContractAbi for MyAppAbi {
    type Operation = Operation;
    type Response = u64;
}

impl ServiceAbi for MyAppAbi {
    type Query = Request;
    type QueryResponse = Response;
}
```

### 2. Define State (state.rs)

```rust
use linera_sdk::views::{linera_views, RegisterView, MapView, RootView, ViewStorageContext};

#[derive(RootView, async_graphql::SimpleObject)]
#[view(context = ViewStorageContext)]
pub struct MyAppState {
    // Single value storage
    pub counter: RegisterView<u64>,
    // Key-value mapping
    pub balances: MapView<Owner, u64>,
}
```

**Available View Types:**

| View Type | Use Case |
|-----------|----------|
| `RegisterView<T>` | Single value storage |
| `MapView<K, V>` | Key-value pairs |
| `CollectionView<K, V>` | Nested views per key |
| `LogView<T>` | Append-only log |
| `QueueView<T>` | FIFO queue |
| `SetView<T>` | Unique values |

### 3. Implement Contract (contract.rs)

```rust
#![cfg_attr(target_arch = "wasm32", no_main)]

use linera_sdk::{base::WithContractAbi, Contract, ContractRuntime};
use my_app::{Operation, Message, MyAppAbi};

pub struct MyAppContract {
    state: MyAppState,
    runtime: ContractRuntime<Self>,
}

linera_sdk::contract!(MyAppContract);

impl WithContractAbi for MyAppContract {
    type Abi = MyAppAbi;
}

impl Contract for MyAppContract {
    type Message = Message;
    type Parameters = ();
    type InstantiationArgument = u64;

    async fn load(runtime: ContractRuntime<Self>) -> Self {
        let state = MyAppState::load(runtime.root_view_storage_context())
            .await
            .expect("Failed to load state");
        Self { state, runtime }
    }

    async fn instantiate(&mut self, initial_value: u64) {
        self.state.counter.set(initial_value);
    }

    async fn execute_operation(&mut self, operation: Operation) -> u64 {
        match operation {
            Operation::DoSomething { value } => {
                let current = self.state.counter.get();
                self.state.counter.set(current + value);
                *self.state.counter.get()
            }
        }
    }

    async fn execute_message(&mut self, message: Message) {
        match message {
            Message::Credit { amount, target } => {
                // Handle incoming cross-chain message
                let balance = self.state.balances.get(&target).await.unwrap_or(0);
                self.state.balances.insert(&target, balance + amount);
            }
        }
    }

    async fn store(mut self) {
        self.state.save().await.expect("Failed to save state");
    }
}
```

### 4. Implement Service (service.rs)

```rust
#![cfg_attr(target_arch = "wasm32", no_main)]

use std::sync::Arc;
use async_graphql::{EmptySubscription, Object, Schema};
use linera_sdk::{base::WithServiceAbi, Service, ServiceRuntime};
use my_app::MyAppAbi;

pub struct MyAppService {
    state: Arc<MyAppState>,
    runtime: Arc<ServiceRuntime<Self>>,
}

linera_sdk::service!(MyAppService);

impl WithServiceAbi for MyAppService {
    type Abi = MyAppAbi;
}

impl Service for MyAppService {
    type Parameters = ();

    async fn new(runtime: ServiceRuntime<Self>) -> Self {
        let state = MyAppState::load(runtime.root_view_storage_context())
            .await
            .expect("Failed to load state");
        Self {
            state: Arc::new(state),
            runtime: Arc::new(runtime),
        }
    }

    async fn handle_query(&self, request: Request) -> Response {
        let schema = Schema::build(
            self.state.clone(),
            MutationRoot { runtime: self.runtime.clone() },
            EmptySubscription,
        )
        .finish();
        schema.execute(request).await
    }
}

struct MutationRoot {
    runtime: Arc<ServiceRuntime<MyAppService>>,
}

#[Object]
impl MutationRoot {
    async fn do_something(&self, value: u64) -> Vec<u8> {
        self.runtime.schedule_operation(&Operation::DoSomething { value });
        vec![]
    }
}
```

## Cross-Chain Messaging

Send messages to other chains:

```rust
self.runtime
    .prepare_message(Message::Credit { amount, target: owner })
    .with_authentication()
    .with_tracking()
    .send_to(target_chain);
```

Handle received messages in `execute_message`. Use `.with_tracking()` for automatic
bounce handling.

For subscription patterns, token transfers, and bounce handling, see
[cross-chain-messaging.md](./cross-chain-messaging.md).

## Build, Deploy, Test

### Build

```bash
cargo build --release --target wasm32-unknown-unknown
```

### Local Development Setup

```bash
# Initialize wallet and start service
linera wallet init --with-new-chain
linera service --port 8080
```

> **Note**: For local network development (`linera net up`), also run `linera-storage-service`
> in a separate terminal. Testnet wallets use RocksDB and don't need it. See
> [deployment.md](./deployment.md) for full setup.

### Deploy

```bash
# From project root
linera project publish-and-create . --json-argument '"initial_value"'

# Or with explicit bytecode paths
linera publish-and-create \
  target/wasm32-unknown-unknown/release/my_app_contract.wasm \
  target/wasm32-unknown-unknown/release/my_app_service.wasm \
  --json-argument '42'
```

### Verify Deployment

```bash
# Check wallet for chain and app IDs
linera wallet show

# Test GraphQL endpoint
curl http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID> \
  -H "Content-Type: application/json" \
  -d '{"query": "{ counter }"}'
```

## GraphQL Patterns

### Query State

```graphql
query {
  counter
  balances(owner: "user123")
}
```

### Execute Mutation

```graphql
mutation {
  doSomething(value: 10)
}
```

### Introspect Schema

```bash
curl http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID> \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __schema { types { name fields { name } } } }"}'
```

## MCP Integration

Linera apps expose GraphQL, which AI assistants access via the Apollo MCP Server.

For full setup instructions (building the server, creating schema files, configuring
Claude Desktop), see [mcp-integration.md](./mcp-integration.md).

**Key MCP Notes:**
- Use `stdio` transport (default) for Claude Desktop—streamable HTTP has issues
- Always include `--introspection` for schema discovery
- `--allow-mutations all` enables write operations

## Testing

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use linera_sdk::test::mock_application_state;

    #[tokio::test]
    async fn test_increment() {
        let mut state = mock_application_state::<MyAppState>();
        state.counter.set(0);

        let new_value = *state.counter.get() + 5;
        state.counter.set(new_value);

        assert_eq!(*state.counter.get(), 5);
    }
}
```

For service tests, message tests, integration testing, and dev-dependency setup, see
[testing.md](./testing.md).

## Common Pitfalls

### 1. Missing linera-storage-service (local dev only)

**Symptom**: `linera service` fails or wallet commands hang when using `linera net up`

**Fix**: Run `linera-storage-service` in a separate terminal before using the CLI. This is only needed for local network development — testnet wallets use RocksDB storage and don't need it.

### 2. Wrong Rust Version

**Symptom**: Compilation errors, missing features

**Fix**: Use Rust 1.86.0:
```bash
rustup override set 1.86.0
rustup target add wasm32-unknown-unknown
```

### 3. Wrong Branch

**Symptom**: Version mismatches, incompatible APIs, deployment failures

**Fix**: Use the `testnet_conway` branch for current testnet compatibility:
```bash
git checkout testnet_conway
```

### 4. Missing protoc

**Symptom**: Build fails with protobuf errors

**Fix**: Install protoc v21.11+:
```bash
# macOS
brew install protobuf

# Linux
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v21.11/protoc-21.11-linux-x86_64.zip
unzip protoc-21.11-linux-x86_64.zip -d ~/.local
```

### 5. State Not Persisting

**Symptom**: Data disappears between operations

**Fix**: Always call `self.state.save().await` in the `store()` method. Use `RegisterView`/`MapView` instead of plain Rust types.

### 6. GraphQL Endpoint Wrong

**Symptom**: 404 or connection refused

**Fix**: URL must be exactly: `http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID>`

Get IDs from: `linera wallet show`

### 7. Cross-Chain Messages Not Arriving

**Symptom**: Messages sent but never received

**Fix**:
- Ensure target chain exists and is active
- Use `.with_authentication()` for authenticated messages
- Use `.with_tracking()` to enable bounce handling
- Recipient must explicitly accept messages in their inbox

### 8. MCP Server Connection Issues

**Symptom**: Claude can't connect to MCP server

**Fix**:
- Verify `linera service --port 8080` is running
- Test endpoint manually with curl first
- Use absolute paths in Claude Desktop config
- Restart Claude Desktop after config changes

### 9. GRPC Failures With Many Microchains

**Symptom**: Bots or processes crash with GRPC errors when a single wallet holds many microchains. Often appears after a Linera update, or when scaling up the number of chains.

**Root cause**: Each microchain in a wallet opens GRPC channels to validators. Google's GRPC implementation limits the number of channels per connection. Packing too many microchains into one wallet exceeds this limit, causing all operations on that wallet to fail.

**Fix**: Partition your microchains across multiple wallets, each running in its own process. Instead of one wallet with 30 chains, use several wallets with fewer chains each. See [scaling.md](./scaling.md) for the full pattern.

## Microchain Concepts

- **Microchain**: A chain of blocks with its own state. Each user/app can have dedicated chains.
- **Owner**: Controls who can propose blocks. Single-owner (fast), multi-owner, or public.
- **Inbox**: Cross-chain messages arrive in inbox; must be explicitly processed.
- **Fast Rounds**: Super owners can propose with minimal latency.

## Sub-Skills

For detailed patterns, see:

- [storage-views.md](./storage-views.md) - Storage patterns and view types
- [cross-chain-messaging.md](./cross-chain-messaging.md) - Advanced messaging patterns
- [mcp-integration.md](./mcp-integration.md) - Full MCP setup guide
- [testing.md](./testing.md) - Unit and integration testing
- [deployment.md](./deployment.md) - Testnet and production deployment
- [scaling.md](./scaling.md) - Scaling across multiple wallets/processes

## Quick Reference

| Task | Command |
|------|---------|
| Build | `cargo build --release --target wasm32-unknown-unknown` |
| Start storage | `linera-storage-service` |
| Init wallet | `linera wallet init --with-new-chain --faucet <FAUCET_URL>` |
| Start service | `linera service --port 8080` |
| Deploy | `linera project publish-and-create . --json-argument '<ARG>'` |
| Check wallet | `linera wallet show` |
| Query GraphQL | `curl -X POST <ENDPOINT> -H "Content-Type: application/json" -d '{"query": "{ ... }"}'` |

## Resources

- [Linera Documentation](https://linera.dev)
- [Protocol Repository](https://github.com/linera-io/linera-protocol) — use branch `testnet_conway` for current testnet
- [MCP Demo](https://github.com/linera-io/mcp-demo)
- [Apollo MCP Server](https://github.com/apollographql/apollo-mcp-server)
- [Example Applications](https://github.com/linera-io/linera-protocol/tree/testnet_conway/examples)
