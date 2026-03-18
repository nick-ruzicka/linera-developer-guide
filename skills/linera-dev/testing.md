# Testing Linera Applications

## Test Setup

Add test dependencies to `Cargo.toml`:

```toml
[dev-dependencies]
linera-sdk = { version = "0.15", features = ["test", "wasmer"] }
tokio = { version = "1", features = ["rt", "macros"] }
assert_matches = "1.5"
```

## Unit Testing State

Test state logic in isolation:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use linera_sdk::views::memory::create_memory_context;

    #[tokio::test]
    async fn test_state_initialization() {
        let context = create_memory_context();
        let mut state = MyAppState::load(context).await.unwrap();

        // Initial state should be empty/default
        assert_eq!(*state.counter.get(), 0);
    }

    #[tokio::test]
    async fn test_state_persistence() {
        let context = create_memory_context();
        let mut state = MyAppState::load(context.clone()).await.unwrap();

        state.counter.set(42);
        state.save().await.unwrap();

        // Reload and verify
        let state2 = MyAppState::load(context).await.unwrap();
        assert_eq!(*state2.counter.get(), 42);
    }

    #[tokio::test]
    async fn test_map_operations() {
        let context = create_memory_context();
        let mut state = MyAppState::load(context).await.unwrap();

        let owner = Owner::from(PublicKey::test_key(1));

        state.balances.insert(&owner, 100);
        assert_eq!(state.balances.get(&owner).await.unwrap(), Some(100));

        state.balances.remove(&owner).unwrap();
        assert_eq!(state.balances.get(&owner).await.unwrap(), None);
    }
}
```

## Testing GraphQL Service

Test the service's GraphQL handling:

```rust
#[cfg(test)]
mod service_tests {
    use super::*;
    use async_graphql::Request;
    use linera_sdk::test::TestServiceRuntime;

    #[tokio::test]
    async fn test_query_counter() {
        let runtime = TestServiceRuntime::new();
        let service = MyAppService::new(runtime).await;

        let request = Request::new("{ counter }");
        let response = service.handle_query(request).await;

        assert!(response.errors.is_empty());
        let data = response.data.into_json().unwrap();
        assert_eq!(data["counter"], 0);
    }

    #[tokio::test]
    async fn test_query_balance() {
        let runtime = TestServiceRuntime::new();
        let service = MyAppService::new(runtime).await;

        let request = Request::new(r#"{ balance(owner: "user123") }"#);
        let response = service.handle_query(request).await;

        assert!(response.errors.is_empty());
    }
}
```

## Testing Contract Logic

Test contract operations:

```rust
#[cfg(test)]
mod contract_tests {
    use super::*;
    use linera_sdk::test::{TestContractRuntime, mock_key_pair};

    #[tokio::test]
    async fn test_instantiate() {
        let runtime = TestContractRuntime::new();
        let mut contract = MyAppContract::load(runtime).await;

        contract.instantiate(42).await;

        assert_eq!(*contract.state.counter.get(), 42);
    }

    #[tokio::test]
    async fn test_execute_operation() {
        let runtime = TestContractRuntime::new();
        let mut contract = MyAppContract::load(runtime).await;
        contract.instantiate(0).await;

        let result = contract
            .execute_operation(Operation::Increment { value: 10 })
            .await;

        assert_eq!(result, 10);
        assert_eq!(*contract.state.counter.get(), 10);
    }

    #[tokio::test]
    async fn test_multiple_operations() {
        let runtime = TestContractRuntime::new();
        let mut contract = MyAppContract::load(runtime).await;
        contract.instantiate(0).await;

        contract.execute_operation(Operation::Increment { value: 5 }).await;
        contract.execute_operation(Operation::Increment { value: 3 }).await;

        assert_eq!(*contract.state.counter.get(), 8);
    }
}
```

## Testing Cross-Chain Messages

```rust
#[cfg(test)]
mod message_tests {
    use super::*;
    use linera_sdk::test::TestContractRuntime;
    use linera_sdk::base::ChainId;

    #[tokio::test]
    async fn test_send_message() {
        let runtime = TestContractRuntime::new();
        let mut contract = MyAppContract::load(runtime.clone()).await;

        let target_chain = ChainId::root(1);
        contract.execute_operation(Operation::Transfer {
            target_chain,
            amount: 100,
        }).await;

        // Check message was queued
        let messages = runtime.sent_messages();
        assert_eq!(messages.len(), 1);
    }

    #[tokio::test]
    async fn test_receive_message() {
        let runtime = TestContractRuntime::new();
        let mut contract = MyAppContract::load(runtime).await;
        contract.instantiate(0).await;

        let owner = Owner::from(PublicKey::test_key(1));
        contract.execute_message(Message::Credit {
            amount: 50,
            target: owner.clone(),
            source: owner.clone(),
        }).await;

        let balance = contract.state.balances.get(&owner).await.unwrap();
        assert_eq!(balance, Some(50));
    }

    #[tokio::test]
    async fn test_bounced_message() {
        let mut runtime = TestContractRuntime::new();
        runtime.set_message_is_bouncing(true);

        let mut contract = MyAppContract::load(runtime).await;
        contract.instantiate(0).await;

        let source = Owner::from(PublicKey::test_key(1));
        let target = Owner::from(PublicKey::test_key(2));

        // When bouncing, should credit source not target
        contract.execute_message(Message::Credit {
            amount: 50,
            target,
            source: source.clone(),
        }).await;

        let source_balance = contract.state.balances.get(&source).await.unwrap();
        assert_eq!(source_balance, Some(50));
    }
}
```

## Integration Testing with CLI

Test deployment and interaction:

```bash
#!/bin/bash
set -e

# Build
cargo build --release --target wasm32-unknown-unknown

# Start services (in background)
linera-storage-service &
STORAGE_PID=$!
sleep 2

linera wallet init --with-new-chain
linera service --port 8080 &
SERVICE_PID=$!
sleep 2

# Deploy
APP_ID=$(linera project publish-and-create . --json-argument "0" 2>&1 | grep -oP 'Application ID: \K.*')
CHAIN_ID=$(linera wallet show | grep "Chain ID" | head -1 | awk '{print $3}')

# Test query
RESULT=$(curl -s http://localhost:8080/chains/$CHAIN_ID/applications/$APP_ID \
  -H "Content-Type: application/json" \
  -d '{"query": "{ counter }"}')

echo "Query result: $RESULT"

# Test mutation
curl -s http://localhost:8080/chains/$CHAIN_ID/applications/$APP_ID \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { increment(value: 5) }"}'

# Verify
RESULT=$(curl -s http://localhost:8080/chains/$CHAIN_ID/applications/$APP_ID \
  -H "Content-Type: application/json" \
  -d '{"query": "{ counter }"}')

echo "After increment: $RESULT"

# Cleanup
kill $SERVICE_PID $STORAGE_PID
```

## Running Tests

```bash
# Unit tests (no network needed)
cargo test

# With all features
cargo test --features test,wasmer

# Specific test
cargo test test_execute_operation

# With output
cargo test -- --nocapture
```

## Best Practices

1. **Test state separately** from contract logic
2. **Mock runtime** for deterministic tests
3. **Test edge cases** - empty state, zero amounts, max values
4. **Test error conditions** - insufficient balance, invalid operations
5. **Use descriptive test names** - `test_transfer_fails_with_insufficient_balance`
6. **Clean up resources** in integration tests
