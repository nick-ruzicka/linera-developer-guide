# Validation: AI-Assisted Linera Development

Last validated: March 2026 | SDK: linera-sdk 0.15 | Rust: 1.86.0

## Results

| Metric | Without Guide | With Guide |
|--------|:---:|:---:|
| Files that compile | 0 / 4 | 3-4 / 4 |
| Correct SDK version | No | Yes |
| Correct contract trait | No | Yes |
| Correct service trait | No | Yes |
| Correct deployment flow | No | Yes |
| Cross-chain messaging | Partial | Yes |

## Methodology

A token balance tracker application was generated twice using an AI coding assistant: once with only the official Linera documentation available, and once with this guide loaded as a Claude Code skill. Both runs targeted the same SDK version (linera-sdk 0.15) and the same application requirements. The generated files (`lib.rs`, `state.rs`, `contract.rs`, `service.rs`) were compared for correctness against the current Linera API surface.

### Reproducibility

To rerun this test, generate a Linera application using only the official docs, then again with this guide loaded as a Claude Code skill. Compare compilation output against linera-sdk 0.15 on the `testnet_conway` branch.

## What the Guide Prevents

Linera's SDK has evolved rapidly and its API surface differs significantly from patterns in other blockchain frameworks. Without production-tested reference patterns, these are the most common failure modes:

**Wrong SDK version.** AI models default to outdated versions (e.g., 0.12). The guide pins linera-sdk 0.15 with matching dependency versions.

**Wrong Cargo.toml structure.** Linera requires two separate `[[bin]]` targets (contract + service), not a `[lib]` crate with `cdylib` output. This is unique to Linera and not obvious from other Rust/Wasm frameworks.

**Wrong Contract trait signature.** The current Contract trait uses `load`, `instantiate`, `execute_operation`, `execute_message`, and `store`. Earlier SDK versions used different method names, return types, and associated types. AI models frequently generate the old signatures.

**Wrong Service trait.** The Service trait takes `ServiceRuntime`, not `QueryContext` (which does not exist in the current SDK). This is a compile-breaking error with no helpful error message.

**Plain fields instead of views.** Persistent state requires `RegisterView<T>`, `MapView<K, V>`, and other view types from `linera-views`. Plain Rust struct fields compile but silently lose data between operations.

**Missing deployment infrastructure.** Local development with `linera net up` requires `linera-storage-service` running in a separate terminal. Omitting this causes silent failures. Testnet wallets use RocksDB and do not need it — the distinction is critical.

**Wrong GraphQL endpoint pattern.** The endpoint must be `http://localhost:PORT/chains/CHAIN_ID/applications/APP_ID`. Without the exact chain and application ID in the path, all queries return 404.

**No cross-chain bounce handling.** Token transfers between chains require `.with_tracking()` and bounce handling in `execute_message`. Without it, failed transfers lose funds permanently.

## Areas for Contribution

The following areas are not yet covered in depth. Community contributions are welcome:

- **Owner/ChainId parsing in GraphQL resolvers** — converting string inputs to Linera types in service query handlers
- **Error handling patterns** — custom error types and propagation in contracts and services
- **u64 vs u128 for token amounts** — guidance on when each precision level is appropriate
- **Complex initialization patterns** — when to use `instantiate()` vs. a dedicated `Initialize` operation
