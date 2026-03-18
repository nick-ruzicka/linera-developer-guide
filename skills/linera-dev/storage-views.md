# Linera Views Storage Guide

`linera-views` maps complex data structures onto key-value storage with automatic persistence. This is the **only** way to store state in Linera applications.

## View Types

### RegisterView<T>

Single value storage. Use for counters, settings, or any single piece of data.

```rust
use linera_sdk::views::{RegisterView, RootView, ViewStorageContext};

#[derive(RootView)]
#[view(context = ViewStorageContext)]
pub struct State {
    pub count: RegisterView<u64>,
    pub name: RegisterView<String>,
    pub config: RegisterView<Option<Config>>,
}

// Usage
let value = *state.count.get();        // Read (returns &T)
state.count.set(42);                   // Write
```

### MapView<K, V>

Key-value mapping. Keys must implement `Serialize + DeserializeOwned + Send + Sync`.

```rust
pub struct State {
    pub balances: MapView<Owner, u64>,
    pub metadata: MapView<String, String>,
}

// Usage
let balance = state.balances.get(&owner).await.unwrap_or(0);
state.balances.insert(&owner, 100);
state.balances.remove(&owner);

// Iteration
let keys = state.balances.indices().await?;
for key in keys {
    let value = state.balances.get(&key).await;
}
```

### CollectionView<K, V>

Nested views per key. Each key maps to its own view instance. Use when you need complex structures per key.

```rust
pub struct State {
    pub user_data: CollectionView<Owner, UserProfile>,
}

#[derive(View)]
pub struct UserProfile {
    pub name: RegisterView<String>,
    pub posts: LogView<Post>,
}

// Usage
let user_profile = state.user_data.load_entry_mut(&owner).await?;
user_profile.name.set("Alice".to_string());
```

### LogView<T>

Append-only log. Good for event history, audit trails.

```rust
pub struct State {
    pub events: LogView<Event>,
}

// Usage
state.events.push(event);
let count = state.events.count();
let recent = state.events.read(count.saturating_sub(10)..count).await?;
```

### QueueView<T>

FIFO queue. Use for task queues, message buffers.

```rust
pub struct State {
    pub pending_tasks: QueueView<Task>,
}

// Usage
state.pending_tasks.push_back(task);
let next = state.pending_tasks.front().await?;
state.pending_tasks.delete_front();
```

### SetView<T>

Unique value collection.

```rust
pub struct State {
    pub members: SetView<Owner>,
}

// Usage
state.members.insert(&owner);
let is_member = state.members.contains(&owner).await?;
state.members.remove(&owner);
```

## GraphQL Integration

Add `async_graphql::SimpleObject` to expose state in queries:

```rust
#[derive(RootView, async_graphql::SimpleObject)]
#[view(context = ViewStorageContext)]
pub struct State {
    pub counter: RegisterView<u64>,
}
```

For complex types, implement `async_graphql::Object`:

```rust
#[derive(RootView)]
#[view(context = ViewStorageContext)]
pub struct State {
    pub balances: MapView<String, u64>,
}

#[async_graphql::Object]
impl State {
    async fn balance(&self, owner: String) -> async_graphql::Result<u64> {
        Ok(self.balances.get(&owner).await?.unwrap_or(0))
    }

    async fn all_balances(&self) -> async_graphql::Result<Vec<(String, u64)>> {
        let mut result = vec![];
        for key in self.balances.indices().await? {
            if let Some(value) = self.balances.get(&key).await? {
                result.push((key, value));
            }
        }
        Ok(result)
    }
}
```

## Best Practices

1. **Always derive `RootView`** for the main state struct
2. **Use `#[view(context = ViewStorageContext)]`** on all view structs
3. **Never store state in plain Rust fields** - they won't persist
4. **Call `save()` in `store()`** method of Contract
5. **Use appropriate view types** - don't use MapView when RegisterView suffices

## Anti-Patterns

```rust
// WRONG - won't persist
pub struct State {
    pub count: u64,  // Plain field, lost after execution
}

// CORRECT
pub struct State {
    pub count: RegisterView<u64>,
}
```

```rust
// WRONG - unnecessary complexity
pub struct State {
    pub single_value: MapView<(), Config>,  // Use RegisterView instead
}

// CORRECT
pub struct State {
    pub single_value: RegisterView<Config>,
}
```
