# zponder

A production-grade EVM event indexer written in Zig, inspired by [Ponder](https://ponder.sh).

---

## Features

### Core Indexing
- **High Performance** — Zero-cost abstractions, no GC, native machine code
- **Multi-contract** — Parallel indexing with per-contract threads
- **Resumable** — Auto-resumes from last synced block on restart
- **Chain Reorg Detection** — Detects and rolls back stale blocks on fork
- **Auto ABI Fetch** — Downloads ABIs from Etherscan/BscScan/PolygonScan
- **Auto Event Discovery** — Detects all events from ABI when `events` list is empty

### Storage
- **Multi-backend** — SQLite (WAL mode), RocksDB, or PostgreSQL
- **LRU Query Cache** — Thread-safe, memory-bounded cache with per-event invalidation
- **Automatic Snapshots** — Configurable-interval snapshots for point-in-time recovery

### Query APIs
- **REST API** — Paginated event queries, health checks, metrics, replay
- **GraphQL API** — Full GraphQL schema with contracts, events, sync state, eth_call
- **GraphQL Playground** — Built-in zero-dependency Playground IDE
- **Custom SQL Queries** — Config-driven named queries with typed parameters
- **Prometheus Metrics** — Standard metrics endpoint (`/metrics`)

### Advanced
- **Factory Contracts** — Auto-discovers and indexes child contracts created by factory contracts
- **Block-level Indexing** — Stores block metadata (timestamp, miner, gas) for time-series analysis
- **Read Contract State** — `eth_call` support with result caching, exposed via GraphQL
- **GraphQL Rate Limiting** — Token-bucket rate limiter, configurable per endpoint

### Resilience
- **Circuit Breaker** — Exponential backoff + circuit breaker for RPC calls
- **Rate Limiting** — Token-bucket rate limiters for both REST and GraphQL
- **RPC Limit Detection** — Auto batch-size reduction on RPC rate limits
- **Dead Letter Queue** — Undecodable logs stored in `raw_logs` table (never silently dropped)

---

## Tech Stack

| Layer              | Technology                                          |
|--------------------|-----------------------------------------------------|
| Language           | Zig 0.16.0+                                         |
| Storage            | SQLite / RocksDB / PostgreSQL                       |
| HTTP Server        | `std.http.Server` + `std.Io` (io_uring on Linux)   |
| GraphQL Engine     | [zgraphql](https://github.com/chy3xyz/zgraphql) v0.2.0 |
| RPC Client         | Custom JSON-RPC with retry + circuit breaker         |
| GraphQL Frontend   | Built-in zero-dependency Playground                  |
| Build              | `build.zig` + `build.zig.zon`                        |

---

## Project Structure

```
zponder/
├── src/
│   ├── main.zig          # Entry point: signal handling, module orchestration
│   ├── config.zig        # TOML config parser with validation (all sections)
│   ├── log.zig           # Structured logging (JSON/text, file+stderr)
│   ├── eth_rpc.zig       # JSON-RPC client: eth_getLogs/blocks/call, retry, circuit breaker
│   ├── db.zig            # Database client: SQLite + RocksDB + PostgreSQL
│   ├── rocksdb.zig       # RocksDB C bindings
│   ├── pg.zig            # PostgreSQL C bindings (libpq)
│   ├── indexer.zig       # Per-contract sync loop, reorg handling, replay, snapshot
│   ├── factory.zig       # Factory contract manager: child discovery + lifecycle
│   ├── http_server.zig   # REST API: routing, CORS, cache, metrics, dashboards
│   ├── graphql.zig       # GraphQL API: zgraphql schema, resolvers, rate limiting
│   ├── abi.zig           # ABI parsing, log decoding, eth_call encoding/decoding
│   ├── cache.zig         # Thread-safe LRU cache
│   ├── etherscan.zig     # Etherscan/BscScan/PolygonScan ABI fetcher
│   ├── template.zig      # Server-side HTML template rendering
│   ├── dashboard.zig     # Dashboard widget logic
│   ├── utils.zig         # Hex parsing, JSON escaping, address validation
│   └── root.zig          # Public API re-exports
├── abis/                 # Contract ABI JSON files
├── pages/                # Static HTML pages (dashboard, kline, etc.)
├── docs/                 # Documentation
│   ├── API.md            # REST + GraphQL API reference
│   ├── ARCHITECTURE.md   # Architecture overview and data flow
│   └── dev.md            # Developer guide
├── config.toml           # Runtime configuration
├── build.zig             # Build script (embeds git commit + version)
└── build.zig.zon         # Package manifest
```

---

## Quick Start

### 1. Prerequisites

```bash
# macOS
brew install zig sqlite3 rocksdb libpq

# Verify
zig version  # >= 0.16.0
```

### 2. Build

```bash
zig build
```

### 3. Configure

Create or edit `config.toml`:

```toml
[global]
log_level = "info"
chain = "ethereum"
track_blocks = true               # optional: store block metadata

[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
timeout = 10000
retry_count = 3

[database]
type = "sqlite"                   # sqlite | rocksdb | postgresql
db_name = "eth_indexer.db"

[http]
port = 8080
host = "0.0.0.0"
cors = true

# GraphQL API (optional)
[graphql]
enabled = true
port = 8081
enable_playground = true
rate_limit_rps = 10

# Static contracts
[[contracts]]
name = "dai"
address = "0x6b175474e89094c44da98b954eedeac495271d0f"
abi_path = "./abis/erc20.abi"
from_block = 20000000
events = ["Transfer", "Approval"]

# Factory contracts (optional)
# [[factories]]
# name = "uniswap_v2_factory"
# address = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"
# creation_event = "PairCreated"
# child_address_field = "pair"
# child_abi_path = "./abis/uniswap_v2_pair.abi"
# child_events = ["Swap", "Mint", "Burn", "Sync"]
```

### 4. Run

```bash
zig build run -- -c config.toml
# or
./zig-out/bin/zponder -c config.toml
```

### 5. Query

**REST API** (`http://localhost:8080`):

```bash
curl http://localhost:8080/events/dai/Transfer?limit=5
curl http://localhost:8080/sync_state
curl http://localhost:8080/metrics
```

**GraphQL API** (`http://localhost:8081/graphql`):

```graphql
# Contract list with sync states
{
  contracts { name address chain fromBlock events }
  syncStates { contractName currentBlock status }
}

# Latest events with pagination
{
  latestEvents(contract: "dai", event: "Transfer", limit: 5, offset: 0) {
    blockNumber
    transactionHash
    fields { key value }
  }
}

# Read on-chain contract state
{
  contractCall(contract: "dai", method: "balanceOf(address)", args: ["0x6B175474E89094C44Da98b954EedeAC495271d0F"])
}
```

### 6. Tests

```bash
zig build test
```

### 7. Production Build

```bash
zig build -Doptimize=ReleaseFast
```

---

## HTTP API Reference

| Endpoint                        | Method | Description                                    |
|---------------------------------|--------|------------------------------------------------|
| `/health`                       | GET    | Health check + indexer & cache status          |
| `/version`                      | GET    | Version, git commit, Zig version               |
| `/sync_state`                   | GET    | All contract sync states                       |
| `/contracts`                    | GET    | Configured contract list                       |
| `/events/:contract/:event`      | GET    | Query event logs with filters & pagination     |
| `/cache/stats`                  | GET    | Cache entry count & bytes                      |
| `/metrics`                      | GET    | Prometheus-compatible metrics                  |
| `/schema`                       | GET    | Auto-generated API documentation               |
| `/queries/:name`                | GET    | Config-driven custom SQL query                 |
| `/balance/:contract/:account`   | GET    | Query account balance for a contract           |
| `/replay`                       | POST   | Replay a block range for a contract            |
| `/dashboards/:name`             | GET    | Dashboard page (HTML)                          |

**Query parameters for `/events/:contract/:event`:**
- `block_from` — start block (optional)
- `block_to` — end block (optional)
- `tx_hash` — filter by transaction hash (optional)
- `limit` — max results, default 100, max 1000 (optional)
- `offset` — pagination offset, default 0 (optional)
- `order` — `asc` or `desc`, default `desc` (optional)

## GraphQL API Reference

### Endpoint: `POST /graphql`

#### Query Fields

| Field              | Args                                                       | Returns       | Description                          |
|--------------------|------------------------------------------------------------|---------------|--------------------------------------|
| `health`           | —                                                          | `String!`     | Server health status                 |
| `version`          | —                                                          | `String!`     | Version and git commit               |
| `contracts`        | —                                                          | `[Contract!]!`| All configured contracts             |
| `contract`         | `name: String!`                                            | `Contract`    | Single contract by name              |
| `syncStates`       | —                                                          | `[SyncState!]!`| Indexer sync status per contract   |
| `latestEvents`     | `contract, event, limit, offset, blockFrom, blockTo`       | `[Event!]`    | Paginated event logs                 |
| `contractCall`     | `contract, method, args, blockNumber`                      | `String`      | Call a contract method (eth_call)    |

#### Types

```graphql
type Contract {
  name: String!
  address: String!
  chain: String!
  fromBlock: Int!
  events: [String!]!
}

enum IndexerStatus {
  RUNNING
  STOPPED
  ERROR
  REPLAYING
}

type SyncState {
  contractName: String!
  currentBlock: Int!
  status: IndexerStatus!
}

type Event {
  blockNumber: Int!
  transactionHash: String!
  eventName: String!
  fields: [EventField!]!
}

type EventField {
  key: String!
  value: String!
}
```

---

## Configuration Reference

### `[global]`

| Key                | Type   | Default       | Description                                |
|--------------------|--------|---------------|--------------------------------------------|
| `log_level`        | string | `"info"`      | debug / info / warn / error                |
| `log_file`         | string | `""`          | Log file path (empty = stderr only)        |
| `snapshot_interval`| u64    | `0`           | Snapshot interval in seconds (0 = off)     |
| `etherscan_api_key`| string | `""`          | Explorer API key for auto ABI fetching     |
| `chain`            | string | `"ethereum"`  | ethereum / bsc / polygon                   |
| `track_blocks`     | bool   | `false`       | Store block metadata to `blocks` table     |

### `[rpc]`

| Key                | Type   | Default | Description                      |
|--------------------|--------|---------|----------------------------------|
| `url`              | string | —       | JSON-RPC endpoint URL (required) |
| `timeout`          | u32    | `10000` | Request timeout in ms            |
| `retry_count`      | u32    | `3`     | Retry count per RPC call         |
| `retry_delay_ms`   | u32    | `1000`  | Base delay for exponential backoff |
| `max_concurrent`   | u32    | `10`    | Max concurrent RPC connections   |

### `[database]`

| Key                | Type   | Default     | Description                           |
|--------------------|--------|-------------|---------------------------------------|
| `type`             | string | `"sqlite"`  | sqlite / rocksdb / postgresql         |
| `db_name`          | string | —           | File path (SQLite) or connection URI  |
| `wal_mode`         | bool   | `true`      | Enable WAL mode (SQLite only)         |
| `busy_timeout_ms`  | u32    | `5000`      | SQLite busy timeout                   |
| `max_connections`  | u32    | `10`        | Maximum connections                   |

### `[http]`

| Key                | Type   | Default     | Description                   |
|--------------------|--------|-------------|-------------------------------|
| `host`             | string | `"0.0.0.0"` | Bind address                  |
| `port`             | u16    | `8080`      | Listen port                   |
| `cors`             | bool   | `false`     | Enable CORS (`*`)             |
| `cors_origins`     | array  | `[]`        | Specific CORS origins         |
| `rate_limit_rps`   | u32    | —           | Requests per second (optional)|
| `rate_limit_burst` | u32    | —           | Burst capacity (optional)     |

### `[graphql]`

| Key                  | Type   | Default     | Description                              |
|----------------------|--------|-------------|------------------------------------------|
| `enabled`            | bool   | `false`     | Enable GraphQL server                     |
| `host`               | string | `"0.0.0.0"` | Bind address                              |
| `port`               | u16    | `8081`      | Listen port                               |
| `enable_playground`  | bool   | `false`     | Serve GraphQL Playground at `/graphql/playground` |
| `max_query_depth`    | u32    | `20`        | Max query nesting depth                   |
| `max_query_complexity`| u32   | `1000`      | Max query complexity score                |
| `rate_limit_rps`     | u32    | —           | Requests per second (optional)            |
| `rate_limit_burst`   | u32    | —           | Burst capacity (optional)                 |

### `[[contracts]]`

| Key              | Type   | Default | Description                                    |
|------------------|--------|---------|------------------------------------------------|
| `name`           | string | —       | Contract name (used in table names) (required) |
| `address`        | string | —       | Contract address (required)                    |
| `abi_path`       | string | —       | ABI file path (auto-fetched if empty)          |
| `from_block`     | u64    | `0`     | Start block for indexing                       |
| `events`         | array  | `[]`    | Event names to index (empty = all)             |
| `filters`        | array  | `[]`    | Event-level filters (see below)                |
| `poll_interval_ms`| u32   | `2000`  | Poll interval when caught up                   |
| `block_batch_size`| u32   | `500`   | Max blocks per RPC batch                       |
| `max_reorg_depth`| u32    | —       | Max reorg scan depth (null = disabled)         |

**Filters format:** `"EventName:field:op:value"` where `op` is `gt`, `gte`, `lt`, `lte`, or `eq`.

Example: `filters = ["Transfer:value:gt:1000000000000000000"]`

### `[[factories]]`

| Key                     | Type   | Default | Description                                  |
|-------------------------|--------|---------|----------------------------------------------|
| `name`                  | string | —       | Factory name (required)                      |
| `address`               | string | —       | Factory contract address (required)          |
| `abi_path`              | string | —       | Factory ABI file path                        |
| `creation_event`        | string | —       | Event name that signals child creation       |
| `child_address_field`   | string | —       | Event field containing the child address     |
| `child_abi_path`        | string | —       | ABI path for child contracts                 |
| `child_events`          | array  | `[]`    | Events to index on child contracts           |
| `max_children`          | u64    | `1000`  | Maximum number of children to index           |
| `child_poll_interval_ms`| u32    | —       | Poll interval for child indexers              |
| `child_batch_size`      | u32    | —       | Batch size for child indexers                 |

### `[[queries]]`

Custom SQL queries exposed at `/queries/:name`. Parameters use `$name` placeholders.

```toml
[[queries]]
name = "top_transfers"
path = "/queries/top_transfers"
sql = """
  SELECT evt_from, SUM(CAST(evt_value AS DECIMAL)) AS total
  FROM event_dai_Transfer
  GROUP BY evt_from ORDER BY total DESC LIMIT $limit
"""
params = ["limit:u32:10"]
cache_ttl_blocks = 50
```

---

## Database Schema

### System Tables

| Table             | Purpose                                           |
|-------------------|---------------------------------------------------|
| `sync_state`      | Per-contract sync progress (resume support)       |
| `account_states`  | Per-account balance snapshots                     |
| `snapshots`       | Indexer snapshots at configurable intervals       |
| `raw_logs`        | Dead letter queue for undecodable logs            |
| `block_hashes`    | Per-contract block hashes for reorg detection    |
| `blocks`          | Chain-wide block metadata (timestamp, miner, gas)|
| `call_cache`      | eth_call result cache                             |

### Event Tables

Auto-generated as `event_{contract_name}_{event_name}` with ABI-derived columns:
- Input parameters become `evt_{param}` columns (lowercased, sanitized)
- Every table includes: `block_number`, `tx_hash`, `log_index`, `created_at`
- Unique constraint on `(tx_hash, log_index)` for idempotent inserts
- Indexes on `block_number` and `tx_hash` for query performance

---

## Design Principles

1. **Fail-safe** — Errors are logged, not silenced. Undecodable logs go to `raw_logs`.
2. **Resumable** — Every block range is committed with sync state; restart picks up where it left off.
3. **Backend-agnostic** — All database operations go through a unified `db.Client` interface.
4. **Resource-bounded** — LRU cache, rate limiters, connection caps, batch size limits.
5. **Observable** — Structured logging, Prometheus metrics, health endpoints.
6. **Thread-safe** — Atomic state, spinlock mutexes, per-thread indexer isolation.
7. **Comptime where possible** — GraphQL schema generated at compile time via `SchemaBuilder`.
