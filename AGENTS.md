# AGENTS.md — zponder Project Guide

> AI coding assistant reference for the zponder codebase: current state, conventions, and module map.

---

## Project Overview

**zponder** is a production-grade EVM event indexer written in Zig 0.17.0, inspired by [Ponder](https://ponder.sh). It indexes smart contract events from EVM-compatible chains and stores them in SQLite, RocksDB, or PostgreSQL. Includes a built-in REST API, GraphQL API, QuickJS JavaScript Handler Engine, Async Webhook Worker Queue, SSE Stream, optional WSS `eth_subscribe` live indexing, dashboard UI, factory contract support, and eth_call for reading on-chain state.

---

## Current Project State

| Item                    | Status       |
|-------------------------|--------------|
| `build.zig` + `build.zig.zon` | Complete (embeds QuickJS-ng v0.17.0 + zgraphql v0.8.0, vendored) |
| `src/` source files     | 22+ Zig files |
| `config.toml`           | Complete (`ws_url` / `ws_urls` optional) |
| Unit tests              | 288 passing |
| QuickJS Script Engine   | Production (Ponder-style `ponder.on` JS API) |
| 业务投影 (ponder.db)     | Production (`exec`/`query` 参数化写库 + `proj_` 表重组级联回滚) |
| Async Webhook Queue     | Production   |
| SSE Stream API          | Production (`/stream`, `/api/v1/stream`) |
| WSS Live Subscribe      | Production (HTTP catch-up → tip `eth_subscribe(logs)`) |
| CLI Tools               | `start`, `check`, `dev`, `add-script`, `install`, `version` |
| REST & GraphQL API      | Production   |
| Factory contracts       | Implemented  |
| 模板索引器 (templates)   | Production (`[[templates]]` + 工厂发现 clone；一套 `event_{模板}_{事件}` 表承载全部地址) |
| Docs                    | README, API, ARCHITECTURE, WSS, dev.md, EVALUATION, examples |

---

## Tech Stack

| Layer              | Technology                                    |
|--------------------|-----------------------------------------------|
| Language           | Zig 0.17.0                                    |
| Script Engine      | Native Embedded QuickJS-ng C Runtime (v0.17.0) |
| Storage            | SQLite (with `read_db` pool) / RocksDB / PostgreSQL（后两者是可选构建特性，见 Build & Run） |
| HTTP Server        | `std.http.Server` + `std.Io`                 |
| GraphQL Engine     | [zgraphql](https://github.com/chy3xyz/zgraphql) v0.8.0 (vendored) |
| RPC Client         | HTTP JSON-RPC failover + optional WSS `eth_subscribe` |
| 事件时间戳          | 有 JS handler 时惰性拉取 + 缓存（`event.block.timestamp`） |
| Build              | `build.zig` + `build.zig.zon`                 |

---

## Data Model

### Event tables

- Named `event_{contract_name}_{EventName}` (created by `autoMigrateContract`).
- Columns: ABI inputs, then `block_number`, `tx_hash`, `log_index`,
  `contract_address TEXT NOT NULL DEFAULT ''`, `created_at`.
- Unique key `UNIQUE(contract_address, tx_hash, log_index)` — idempotent inserts;
  the same `tx_hash`/`log_index` pair can coexist under different contracts.
- Indexes: `(block_number)`, `(tx_hash)`, `(contract_address, block_number)`.
- **Legacy migration is idempotent**: SQLite rebuilds the table and backfills
  `contract_address` (the rebuild drops the old `UNIQUE(tx_hash, log_index)`);
  PostgreSQL uses `ALTER TABLE ADD COLUMN` + constraint `DROP`/`ADD`.
- `autoMigrateContract(contract_name, abi_contract, event_names, contract_address)`
  takes the address as its 4th argument — a single-contract indexer passes the
  contract address, template mode passes `""`.

### Template mode (`[[templates]]`)

- Config section `[[templates]]`: `name`, `abi_path`, `events`, `factory_name`,
  `discovery_event`, `discovery_address_field`, `from_block`,
  `poll_interval_ms`, `block_batch_size`, `max_addresses_per_request`. `[[factories]]`
  gained `template_name`, which is **mutually exclusive** with `child_abi_path`.
  `discovery_event` / `discovery_address_field` are reserved and currently **not**
  used at runtime — dispatch follows the factory's `creation_event` /
  `child_address_field`. `validate()` enforces the pairing: a factory's
  `template_name` must point back at the template whose `factory_name` names it,
  and duplicate factory addresses are rejected.
- Discovery sources: a `[[factories]]` entry takes **either** `address` (a concrete
  contract: the factory contract whose events announce children) **or**
  `from_template = "<name>"` (a template's address set — for addresses only the
  discovered contract knows, e.g. a clone emitting `Migrated(pair)`). The two are
  mutually exclusive; `from_template` requires `template_name`, forbids
  `child_abi_path` and cannot point at its own target. One source may carry
  several rules (`Indexer.factory_idxs` is a list); the source indexer must have
  the `creation_event` in its `events` list to decode it.
- One `Indexer` holds a dynamic set of clone addresses; every clone's events go
  into one shared `event_{template}_{event}` table set. `LogFilter` accepts an
  **address array**, and the main sweep splits that array into chunks of at most
  `max_addresses_per_request` addresses (default 200) — one `eth_getLogs` per
  chunk over the same block range, so several thousand clones do not exceed RPC
  limits.
- The event row's `contract_address` (and the `event_callback` argument) is the
  log address normalized to lowercase hex, the same form `discoverAddress`
  stores in `template_addresses`.
- Newly discovered addresses are backfilled from their discovery block, then
  merged into the main loop. The address set and backfill progress persist in
  `template_addresses(template, address, from_block, backfilled)` with
  `PRIMARY KEY (template, address)`, so restarts resume without re-scanning.
- Reorg rollback is **template-level**: rows with `block_number >= fork` are
  removed for the whole template, and address rows with `from_block >= fork` are
  deleted. `sync_state` / `block_hashes` use the synthetic key
  `template:<template_name>`. After a rollback, the surviving in-memory live
  addresses are re-inserted idempotently (`ON CONFLICT DO NOTHING`) so a
  concurrent factory insert absorbed into the rollback transaction cannot drop a
  clone that should keep being swept.
- **RocksDB is unsupported in template mode**: `[[templates]]` with
  `database.type = "rocksdb"` fails at startup, and `?address=` filtering
  returns `error.UnsupportedOperation` on the RocksDB backend.

### Projection tables (`proj_`)

- Tables named with a `proj_` prefix and carrying a `block_number` column are
  business projections written via `ponder.db.exec/query` in JS handlers.
- `rollbackFromBlock` cascades-deletes projection rows with
  `block_number >= fork_point` inside the same transaction (SQLite/PostgreSQL;
  RocksDB has no SQL).

### Query surface

- REST: `GET /events/:contract/:event?address=0x…` filters by contract address.
- GraphQL: `latestEvents(..., address: String)` and `Event.contractAddress: String!`.
- JS handlers expose `event.contractAddress`, plus `event.transactionHash` /
  `event.logIndex` (the log's position in its transaction — use them as a stable
  projection primary key); SSE `/stream` payloads carry `contract_address`,
  `tx_hash` and `log_index`.

---

## Directory Structure

```
zponder/
├── src/
│   ├── main.zig          # Entry point: CLI routing (start/check/dev/add-script/install)
│   ├── js_engine.zig     # QuickJS JavaScript runtime wrapper & loadDirectory
│   ├── script_engine.zig # Dynamic JSON rule engine & script directory scanner
│   ├── webhook.zig       # Thread-safe Webhook queue & async worker pool
│   ├── config.zig        # TOML config parser + validation (all sections)
│   ├── log.zig           # Structured logging (JSON/text, file+stderr, thread-safe)
│   ├── eth_rpc.zig       # JSON-RPC: getLogs, getBlockData, ethCall, failover rotation
│   ├── ws_rpc.zig        # WebSocket: eth_subscribe(logs), ping/pong, reconnect
│   ├── db.zig            # Database: SQLite (with read_db isolation) + RocksDB + PostgreSQL
│   ├── indexer.zig       # Per-contract sync loop, WSS live mode, reorg, event_callback
│   ├── factory.zig       # Factory contract manager: child discovery + lifecycle
│   ├── http_server.zig   # REST API: routing, CORS, SSE stream (/stream), metrics
│   ├── graphql.zig       # GraphQL API: zgraphql schema, resolvers, rate limiting
│   ├── abi.zig           # ABI parsing, log decoding, eth_call encode/decode
│   ├── cache.zig         # Thread-safe LRU cache
│   ├── quickjs/          # Native C QuickJS-ng engine sources (v0.17.0) embedded
│   └── root.zig          # Public API re-exports
├── handlers/             # User business handler scripts (.js & .json)
├── examples/             # Practical handler examples & documentation
├── install.sh            # One-command ReleaseFast binary installer
├── abis/                 # Contract ABI JSON files
├── pages/                # Static HTML pages (dashboard, kline, etc.)
├── docs/                 # Documentation (API.md, ARCHITECTURE.md, WSS.md, EVALUATION.md)
├── config.toml           # Runtime configuration
├── build.zig             # Build script (embeds git commit + version)
└── build.zig.zon         # Package manifest
```

---

## CLI Subcommands

- `zponder start [-c config.toml]`: Starts the indexer daemon.
- `zponder check [-c config.toml]`: Validates config syntax, RPC connectivity, DB migrations, and ABI parsing.
- `zponder dev`: Runs in development mode with debug logging and `./handlers` auto-scanning.
- `zponder add-script <name> [--json]`: Generates a business handler script template in `./handlers/`.
- `zponder install`: Self-installs binary to `$HOME/.local/bin/zponder`.
- `zponder version / -v / --version`: Displays version, git commit, and feature flags.

---

## Build & Run

```bash
# Debug build & test
zig build test

# Release build；RocksDB / PostgreSQL 是可选特性（默认 on），
# 关掉后二进制不再链接 librocksdb / libpq（发布包就是这个模式）。
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false
zig build test -Drocksdb=false -Dpostgres=false

# Install fast release binary
./install.sh
```

---

## License

MIT
