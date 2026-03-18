# Cross-Chain Messaging in Linera

Linera microchains communicate asynchronously through messages. This enables applications to work across multiple chains while maintaining consistency.

## Message Flow

1. **Sender chain** calls `prepare_message().send_to(target_chain)`
2. Message enters **target chain's inbox**
3. Target chain owner **creates a block** that processes inbox messages
4. **`execute_message`** is called on the contract

## Defining Messages

In `lib.rs`:

```rust
use linera_sdk::base::{ChainId, Owner};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
pub enum Message {
    // Simple notification
    Ping,

    // Transfer with refund capability
    Credit {
        amount: u64,
        target: Owner,
        source: Owner,
    },

    // Subscription confirmation
    SubscriptionConfirmed {
        subscriber: ChainId,
    },
}
```

## Sending Messages

### Basic Send

```rust
async fn execute_operation(&mut self, operation: Operation) -> Response {
    match operation {
        Operation::SendPing { target_chain } => {
            self.runtime
                .prepare_message(Message::Ping)
                .send_to(target_chain);
        }
    }
}
```

### Authenticated Send

Include sender's credentials (required for most operations):

```rust
self.runtime
    .prepare_message(Message::Credit { amount, target, source })
    .with_authentication()
    .send_to(target_chain);
```

### Tracked Send (Enable Bouncing)

Get notified if message delivery fails:

```rust
self.runtime
    .prepare_message(Message::Credit { amount, target, source })
    .with_authentication()
    .with_tracking()
    .send_to(target_chain);
```

## Receiving Messages

```rust
async fn execute_message(&mut self, message: Message) {
    match message {
        Message::Ping => {
            log::info!("Received ping!");
        }

        Message::Credit { amount, target, source } => {
            // Check if message bounced (delivery failed)
            if self.runtime.message_is_bouncing() {
                // Refund to source
                self.credit_account(&source, amount).await;
            } else {
                // Normal credit
                self.credit_account(&target, amount).await;
            }
        }

        Message::SubscriptionConfirmed { subscriber } => {
            self.state.subscribers.insert(&subscriber);
        }
    }
}
```

## Subscription Pattern

Common for social apps, notifications, feeds:

```rust
// In lib.rs
pub enum Operation {
    Subscribe { publisher_chain: ChainId },
    Unsubscribe { publisher_chain: ChainId },
    Post { content: String },
}

pub enum Message {
    Subscribe { subscriber: ChainId },
    Unsubscribe { subscriber: ChainId },
    NewPost { content: String, author: ChainId },
}

// In contract.rs
async fn execute_operation(&mut self, op: Operation) {
    match op {
        Operation::Subscribe { publisher_chain } => {
            self.runtime
                .prepare_message(Message::Subscribe {
                    subscriber: self.runtime.chain_id(),
                })
                .with_authentication()
                .send_to(publisher_chain);
        }

        Operation::Post { content } => {
            // Notify all subscribers
            for subscriber in self.state.subscribers.indices().await? {
                self.runtime
                    .prepare_message(Message::NewPost {
                        content: content.clone(),
                        author: self.runtime.chain_id(),
                    })
                    .send_to(subscriber);
            }
        }
    }
}

async fn execute_message(&mut self, msg: Message) {
    match msg {
        Message::Subscribe { subscriber } => {
            self.state.subscribers.insert(&subscriber);
        }

        Message::NewPost { content, author } => {
            self.state.feed.push(Post { content, author });
        }
    }
}
```

## Token Transfer Pattern

Safe cross-chain transfers with automatic refunds:

```rust
async fn transfer(&mut self, target_chain: ChainId, target_owner: Owner, amount: u64) {
    let source_owner = self.runtime.authenticated_signer().expect("Must be authenticated");

    // Debit source
    self.debit_account(&source_owner, amount).await?;

    // Send with tracking for refunds
    self.runtime
        .prepare_message(Message::Credit {
            amount,
            target: target_owner,
            source: source_owner,
        })
        .with_authentication()
        .with_tracking()
        .send_to(target_chain);
}

async fn execute_message(&mut self, message: Message) {
    match message {
        Message::Credit { amount, target, source } => {
            if self.runtime.message_is_bouncing() {
                // Transfer failed, refund source
                self.credit_account(&source, amount).await;
            } else {
                // Success, credit target
                self.credit_account(&target, amount).await;
            }
        }
    }
}
```

## Common Issues

### Messages Not Arriving

1. **Target chain must be active** - chains with no owners are permanently inactive
2. **Inbox must be processed** - chain owner must create a block that includes inbox messages
3. **Authentication required** - most operations need `.with_authentication()`

### Message Ordering

- Messages between the same two chains maintain order
- Messages from different chains have no ordering guarantees
- Use sequence numbers if you need global ordering

### Debugging

```rust
// Log message details
log::info!(
    "Sending message to chain {:?}: {:?}",
    target_chain,
    message
);

// Check message source in receiver
let source_chain = self.runtime.message_id().chain_id;
log::info!("Message from chain {:?}", source_chain);
```
