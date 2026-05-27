# AGENTS.md — zponder Project Guide

> AI coding assistant reference for the zponder codebase: current state, conventions, and module map.

---

## Project Overview

**zponder** is a production-grade EVM event indexer written in Zig 0.17.0, inspired by [Ponder](https://ponder.sh). It indexes smart contract events from EVM-compatible chains and stores them in SQLite, RocksDB, or PostgreSQL. Includes a built-in REST API, GraphQL API, dashboard UI, factory contract support, and eth_call for reading on-chain state.

---

## Current Project State

| Item                    | Status       |
|-------------------------|--------------|
| `build.zig` + `build.zig.zon` | Complete |
| `src/` source files     | 19 Zig files |
| `config.toml`           | Complete     |
| Unit tests              | 20+ passing  |
| REST API                | Production   |
| GraphQL API             | Production   |
| Factory contracts       | Implemented  |
| Block-level indexing     | Implemented  |
| eth_call support         | Implemented  |
| Docs                    | README, API, ARCHITECTURE, dev.md, EVALUATION |

---

## Tech Stack

| Layer              | Technology                                    |
|--------------------|-----------------------------------------------|
| Language           | Zig 0.17.0                                    |
| Storage            | SQLite / RocksDB / PostgreSQL                 |
| HTTP Server        | `std.http.Server` + `std.Io`                 |
| GraphQL Engine     | [zgraphql](https://github.com/chy3xyz/zgraphql) v0.2.0 |
| RPC Client         | Custom JSON-RPC (retry + circuit breaker)     |
| Build              | `build.zig` + `build.zig.zon`                 |
| Dependencies       | zgraphql (fetched via `zig fetch`)            |

---

## Directory Structure

```
zponder/
├── src/
│   ├── main.zig          # Entry point: signal handling, module orchestration
│   ├── config.zig        # TOML config parser + validation (all sections)
│   ├── log.zig           # Structured logging (JSON/text, file+stderr, thread-safe)
│   ├── eth_rpc.zig       # JSON-RPC: getLogs, getBlockData, ethCall, retry, circuit breaker
│   ├── db.zig            # Database: SQLite + RocksDB + PostgreSQL, unified interface
│   ├── rocksdb.zig       # RocksDB C bindings wrapper
│   ├── pg.zig            # PostgreSQL libpq wrapper
│   ├── indexer.zig       # Per-contract sync loop, reorg handling, replay, snapshot
│   ├── factory.zig       # Factory contract manager: child discovery + lifecycle
│   ├── http_server.zig   # REST API: routing, CORS, caching, metrics, dashboards
│   ├── graphql.zig       # GraphQL API: zgraphql schema, resolvers, rate limiting
│   ├── abi.zig           # ABI parsing, log decoding, eth_call encode/decode
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
│   ├── dev.md            # Original design document
│   └── EVALUATION.md     # Code quality evaluation report
├── config.toml           # Runtime configuration
├── build.zig             # Build script (embeds git commit + version)
├── build.zig.zon         # Package manifest (includes zgraphql dependency)
└── README.md             # Project readme
```

---

## Module Map

### Foundation
- **config.zig** — TOML parser, validation, Config struct. Sections: global, rpc, database, http, graphql, contracts, factories, queries, dashboards.
- **log.zig** — Thread-safe structured logging. `init(alloc, io, level, file)`, `deinit()`. Supports text and JSON formats.

### Data Layer
- **db.zig** — Multi-backend `Client`. System tables via `migrate()`. Event tables via `autoMigrateContract()`. Methods: insertEventLog, queryEventLogs, upsertBlock, queryBlocks, getCachedCall, setCachedCall, rollbackFromBlock, etc.
- **rocksdb.zig** — RocksDB C API wrapper. Put, get, delete, iterator, write batch.
- **pg.zig** — PostgreSQL libpq wrapper. exec, execParams, PgResult with rows/cols/get.
- **cache.zig** — Thread-safe LRU cache. Dual limits (entries + bytes). Block-aware TTL. Prefix invalidation.

### Ethereum Layer
- **eth_rpc.zig** — JSON-RPC `Client`. Methods: getBlockNumber, getBlockHash, getBlockData, getLogs, ethCall. Circuit breaker + exponential backoff. Concurrency limiting.
- **abi.zig** — ABI JSON parsing, Keccak-256 event signatures, log decoding, encodeFunctionCall, decodeCallResult.
- **etherscan.zig** — ABI fetching from Etherscan/BscScan/PolygonScan. Known contract addresses per chain.

### Indexing Layer
- **indexer.zig** — Per-contract `Indexer`. Threaded runLoop: batch sync, reorg detection, replay, snapshots. Factory callback hook after event insert. Fields: contract, state, current_block, track_blocks, chain.
- **factory.zig** — `FactoryManager` for dynamic child contract discovery. Thread-safe children list (atomic mutex). Idempotency via sync_state check. Callback adapter for Indexer hook.

### API Layer
- **http_server.zig** — REST API. Thread-per-connection model. Whitelist validation. LRU cache integration. CORS. Prometheus metrics. Dashboard HTML rendering.
- **graphql.zig** — zgraphql integration. Compile-time `SchemaBuilder`. Resolvers access db + rpc + indexers via `Context` userdata. Optional rate limiting. Shutdown coordination via atomic flag.

### Entry
- **main.zig** — Config loading, RPC/DB init, Indexer creation (with factory linkage), HTTP server start, GraphQL server start (optional), shutdown orchestration.
- **root.zig** — Public API re-exports for use as a library.

---

## Build & Run

```bash
# Debug build
zig build

# Run
zig build run -- -c config.toml

# Tests
zig build test

# Production build
zig build -Doptimize=ReleaseFast
```

**Dependencies:**
- System libraries: sqlite3, rocksdb, libpq (PostgreSQL)
- Zig package: zgraphql (auto-fetched by `zig fetch`)
- macOS: `brew install sqlite3 rocksdb libpq`

---

## Code Conventions

### Patterns
- **Lifecycle**: `init(alloc, ...)` → use → `deinit()`. All modules follow this.
- **Memory**: Caller allocates, callee takes ownership (or duplicates). `errdefer` for cleanup on error.
- **Threading**: `std.Thread.spawn` for indexers, HTTP handlers, GraphQL server. Atomic values for shared state. Spinlock mutexes for protected sections.
- **Error handling**: Zig error unions throughout. No panics on recoverable failures. Errors are logged, never silently swallowed.
- **Database**: Parameterized queries only (SQL injection prevention). All `sqlite3_bind_*` calls checked.

### Naming
- Functions/variables: `snake_case`
- Types/structs: `PascalCase`
- Constants: `lowercase` (Zig convention)
- Log scopes: `.indexer`, `.graphql`, `.factory`, etc.

### File Organization
- One module per file in `src/`
- Tests co-located with source (Zig `test` blocks within each file)
- Config constants in `config.zig`, not scattered

---

## Database Schema

### System Tables
`schema_version`, `sync_state`, `account_states`, `snapshots`, `raw_logs`, `block_hashes`, `blocks`, `call_cache`

### Event Tables
`event_{contract_name}_{event_name}` — auto-created from ABI. Columns: ABI inputs prefixed `evt_` + `block_number`, `tx_hash`, `log_index`, `created_at`. `UNIQUE(tx_hash, log_index)`.

### RocksDB Key Scheme
`e:` events, `s:` sync state, `a:` account state, `p:` snapshots, `r:` raw logs, `h:` block hashes, `b:` blocks, `c:` call cache.

---

## Config Sections

`[global]` — log_level, chain, etherscan_api_key, snapshot_interval, track_blocks
`[rpc]` — url, timeout, retry_count, retry_delay_ms, max_concurrent
`[database]` — type, db_name, wal_mode, busy_timeout_ms, max_connections
`[http]` — host, port, cors, cors_origins, rate_limit_rps, rate_limit_burst
`[graphql]` — enabled, host, port, enable_playground, max_query_depth, max_query_complexity, rate_limit_rps, rate_limit_burst
`[[contracts]]` — name, address, abi_path, from_block, events, filters, poll_interval_ms, block_batch_size, max_reorg_depth
`[[factories]]` — name, address, creation_event, child_address_field, child_abi_path, child_events, max_children
`[[queries]]` — name, path, sql, params, cache_ttl_blocks
`[[dashboards]]` + `[[dashboards.widgets]]` — name, title, widgets with id, type, endpoint, refresh, columns
