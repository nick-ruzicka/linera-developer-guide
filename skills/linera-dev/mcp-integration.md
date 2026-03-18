# MCP Integration for Linera Applications

Model Context Protocol (MCP) enables AI assistants like Claude to interact with Linera applications through GraphQL.

## Architecture

```
Claude Desktop <-> Apollo MCP Server <-> Linera GraphQL Service <-> On-Chain App
     (MCP)             (Bridge)              (HTTP)                (Wasm)
```

## Prerequisites

1. Linera application deployed and running
2. `linera service --port 8080` exposing GraphQL
3. Apollo MCP Server built from source
4. Claude Desktop installed

## Step 1: Build Apollo MCP Server

```bash
git clone https://github.com/apollographql/apollo-mcp-server.git
cd apollo-mcp-server
cargo build --release

# Binary at: ./target/release/apollo-mcp-server
```

## Step 2: Get Your Linera Endpoint

```bash
# Get chain and app IDs
linera wallet show

# Your endpoint will be:
# http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID>
```

Test it works:

```bash
curl http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID> \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __typename }"}'
```

## Step 3: Create GraphQL Schema File

Apollo MCP Server needs a schema file. Export from your app or write manually.

**Option A: Introspect from running service**

```bash
# Get schema
curl http://localhost:8080/chains/<CHAIN_ID>/applications/<APP_ID> \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __schema { types { name kind fields { name type { name } } } } }"}' \
  > schema-introspection.json

# Convert to SDL (you may need to format manually)
```

**Option B: Write schema manually**

Create `app.graphql`:

```graphql
type Query {
  counter: Int!
  balance(owner: String!): Int!
}

type Mutation {
  increment(value: Int!): [Int!]!
  transfer(to: String!, amount: Int!): [Int!]!
}
```

## Step 4: Configure Claude Desktop

Edit Claude Desktop config:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
**Windows**: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "linera-counter": {
      "command": "/absolute/path/to/apollo-mcp-server/target/release/apollo-mcp-server",
      "args": [
        "--schema", "/absolute/path/to/app.graphql",
        "--endpoint", "http://localhost:8080/chains/YOUR_CHAIN_ID/applications/YOUR_APP_ID",
        "--allow-mutations", "all",
        "--introspection"
      ]
    }
  }
}
```

**Critical Notes:**
- Use **absolute paths** everywhere
- Replace `YOUR_CHAIN_ID` and `YOUR_APP_ID` with actual values
- `--allow-mutations all` enables write operations
- `--introspection` helps with schema discovery

## Step 5: Restart Claude Desktop

Completely quit and reopen Claude Desktop. Check for MCP connection in settings.

## Step 6: Test

Ask Claude:
- "What's the current counter value?"
- "Increment the counter by 5"
- "Show me my balance"

## Troubleshooting

### MCP Server Won't Connect

1. **Check Linera service is running:**
   ```bash
   curl http://localhost:8080/
   ```

2. **Verify endpoint with direct query:**
   ```bash
   curl http://localhost:8080/chains/<CHAIN>/applications/<APP> \
     -H "Content-Type: application/json" \
     -d '{"query": "{ __typename }"}'
   ```

3. **Check paths are absolute** in Claude config

4. **Restart Claude Desktop** after any config change

### Mutations Not Working

1. Ensure `--allow-mutations all` is in args
2. Check your Linera wallet has funds
3. Verify mutation names match schema exactly

### Schema Mismatch Errors

1. Re-export schema from running application
2. Ensure field names match exactly (case-sensitive)
3. Types must align (Int vs Int!, String vs ID)

## YAML Config Alternative

Apollo MCP Server also supports YAML config files. Create `mcp-config.yaml`:

```yaml
schema: /path/to/app.graphql
endpoint: http://localhost:8080/chains/CHAIN_ID/applications/APP_ID
allowMutations: all
introspection: true
```

Then in Claude config:

```json
{
  "mcpServers": {
    "linera-app": {
      "command": "/path/to/apollo-mcp-server",
      "args": ["--config", "/path/to/mcp-config.yaml"]
    }
  }
}
```

## Multiple Applications

Add multiple MCP servers for different apps:

```json
{
  "mcpServers": {
    "linera-counter": {
      "command": "/path/to/apollo-mcp-server",
      "args": ["--schema", "/path/to/counter.graphql", "--endpoint", "http://localhost:8080/chains/CHAIN1/applications/APP1", "--allow-mutations", "all"]
    },
    "linera-token": {
      "command": "/path/to/apollo-mcp-server",
      "args": ["--schema", "/path/to/token.graphql", "--endpoint", "http://localhost:8080/chains/CHAIN2/applications/APP2", "--allow-mutations", "all"]
    }
  }
}
```

## Best Practices

1. **Use stdio transport** (default) - more reliable than HTTP for Claude Desktop
2. **Keep schemas minimal** - only expose what AI needs
3. **Use descriptive mutation names** - helps AI understand available actions
4. **Test queries manually first** - ensure endpoint works before MCP setup
5. **Monitor linera service logs** - helps debug query issues
