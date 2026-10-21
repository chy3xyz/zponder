---
order: 3
---

# Architecture

`zponder` is organized into five layers: configuration and logging, storage and caching, Ethereum RPC and ABI decoding, per-contract and template indexing, and HTTP/GraphQL servers.

```
┌──────────────────────────────────────────────────────────────┐
│  API Layer (http_server.zig, graphql.zig, auth.zig)          │
│  REST / GraphQL / SSE / Bearer Auth / Rate Limiter / Metrics │
├──────────────────────────────────────────────────────────────┤
│  Scripting & Webhooks (js_engine.zig, script_engine.zig,     │
│  webhook.zig)                                                │
│  QuickJS ponder.on / ponder.db / ponder.http / Outbox Queue  │
├──────────────────────────────────────────────────────────────┤
│  Factory & Template Layer (factory.zig, template.zig)        │
│  Clone discovery / Template address sets / Child lifecycle   │
├──────────────────────────────────────────────────────────────┤
│  Indexer Layer (indexer.zig)                                 │
│  Per-contract sync / WSS live subscribe / Reorg / Replay     │
├──────────────────────────────────────────────────────────────┤
│  Ethereum Layer (eth_rpc.zig, ws_rpc.zig, abi.zig)           │
│  JSON-RPC / Block receipts fallback / WSS / ABI decode       │
├──────────────────────────────────────────────────────────────┤
│  Data Layer (db.zig, log_cache.zig, projection.zig, cache.zig│
│  user_schema.zig)                                            │
│  SQLite WAL / PostgreSQL / RocksDB / sync.* Log Cache / LRU  │
└──────────────────────────────────────────────────────────────┘
```

## Modules

### `config.zig` and `log.zig`

- `config.zig` parses `config.toml` and validates RPC URLs, contract addresses, ABI paths, factory-to-template pairings, and backend constraints.
- `log.zig` writes structured text or JSON logs to `stderr` and an optional log file under an atomic mutex.

### `eth_rpc.zig` and `ws_rpc.zig`

- `eth_rpc.zig` executes HTTP JSON-RPC calls (`eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs`, `eth_getBlockReceipts`, `eth_call`) with node rotation, exponential backoff, and a three-state circuit breaker.
- When `request_timeout_ms` is non-zero, `rpcCall` installs a per-request `Io.operateTimeout` on socket reads and writes so a stalled TCP connection returns `ConnectionTimedOut` instead of blocking the indexer thread.
- When an RPC node rejects a block range as too wide (Geth `-32005`, HTTP `413`, or provider range-limit messages) or returns a full 10,000-log page stuck in a single block, the indexer shrinks the block batch, bisects the address list, bisects the `topic0` list, and falls back to `eth_getBlockReceipts` when a single address and single topic still overflow one block.
- `ws_rpc.zig` implements RFC 6455 WebSocket framing, `eth_subscribe("logs")`, `eth_unsubscribe`, ping/pong replies, and a 120-second idle read timeout (`idle_timeout_ms`) when `request_timeout_ms > 0`.

### `abi.zig`

- Parses ABI JSON files and canonicalizes Solidity `tuple` inputs and outputs using their `components` array (for example, `(uint256,address)` or `(uint256,uint256)[]`).
- Computes 32-byte Keccak-256 event topic0 hashes from canonical signatures.
- `decodeLog` decodes static words, `string`, `bytes`, fixed arrays `T[k]`, dynamic arrays `T[]`, and static or dynamic tuples into hex strings or JSON arrays.
- `encodeFunctionCall`, `decodeCallResult`, and `decodeSingleOutput` handle `eth_call` selectors, multi-output tuples, single dynamic struct outputs, arrays, and two's-complement signed integers (`int8` through `int256`).

### `db.zig`, `log_cache.zig`, `projection.zig`, and `user_schema.zig`

- Supports SQLite (WAL mode, `SQLITE_OPEN_FULLMUTEX` write connection plus a read connection pool), PostgreSQL, and RocksDB.
- Serializes write transactions across threads with a reentrant pthread mutex (`write_mu`), allowing `processLog` to wrap event insertion, ERC-20 balance updates, and `ponder.db.exec` calls from QuickJS inside one `BEGIN` / `COMMIT` transaction.
- When `database.log_cache = true`, raw logs and scanned block intervals are persisted in `sync.chain_logs` and `sync.chain_log_ranges` (an attached `.sync.db` sidecar file on SQLite, or `CREATE SCHEMA sync` on PostgreSQL).
- `projection.zig` discovers `proj_*` tables carrying a `block_number` column and deletes rows with `block_number >= fork_block` inside the reorg transaction.
- `user_schema.zig` parses `.zp` schema files and migrates `user_*` tables queried via `GET /user/:table/:pk`.

### `indexer.zig` and `factory.zig`

- Runs one worker thread per configured contract or template.
- Stores the next block to scan in `sync_state.last_synced_block`.
- Checks block parent/hash continuity up to `max_reorg_depth` (default `64`, disabled when set to `0`). On a fork at block `N`, `rollbackTo` deletes `event_*`, `proj_*`, `blocks`, and `sync.chain_logs` rows from `N` upward and shrinks `sync.chain_log_ranges` in a single transaction, then reconciles factory child indexers.
- When an event handler or factory callback fails, rolls back the event write and records the log in `raw_logs` with an exponential-backoff `retry_after` timestamp (`1s`, `2s`, `4s`, up to `256s`).
- `factory.zig` discovers child contracts either by spawning per-child `Indexer` threads (`child_abi_path`) or by adding clone addresses to a template's dynamic address set (`template_name`). On startup, `resumeChildren` restores child indexers from existing parent event tables.

### `http_server.zig`, `graphql.zig`, `js_engine.zig`, and `webhook.zig`

- `http_server.zig` serves REST routes, static dashboard pages, Prometheus `/metrics`, and `/stream` SSE connections. Each connection applies `read_timeout_ms` and non-blocking `write_timeout_ms` deadlines.
- `graphql.zig` builds the GraphQL schema with `zgraphql` and coordinates clean shutdown through a reference-counted gate before the database closes.
- `js_engine.zig` embeds QuickJS-ng v0.17.0 and exposes `ponder.on`, `ponder.db.exec`, `ponder.db.query`, and `ponder.http`.
- `webhook.zig` persists outbound webhook deliveries in `webhook_outbox.db` and retries failed HTTP posts up to 8 times.

## Database schema

### System tables

| Table | Key | Purpose |
|---|---|---|
| `sync_state` | `UNIQUE(contract_address)` | Next block to scan and current indexer status |
| `account_states` | `UNIQUE(contract, account)` | Tracked ERC-20 balances |
| `snapshots` | `id` | Periodic JSON state snapshots |
| `raw_logs` | `id` | Dead-letter queue with `attempts` and `retry_after` |
| `block_hashes` | `UNIQUE(contract_address, block_number)` | Block hashes for reorg detection |
| `blocks` | `UNIQUE(chain, block_number)` | Cached block timestamps and metadata |
| `call_cache` | `UNIQUE(cache_key)` | Cached `eth_call` responses |
| `template_addresses` | `PRIMARY KEY (template, address)` | Discovered template clone addresses and backfill state |
| `sync.chain_logs` | `PRIMARY KEY (chain, tx_hash, log_index)` | Cached raw logs when `log_cache = true` |
| `sync.chain_log_ranges` | `PRIMARY KEY (chain, address, topics_key, from_block)` | Covered `[from_block, to_block]` intervals |

### Event tables

`autoMigrateContract` creates one table per configured event named `event_<contract>_<EventName>`:

- ABI input columns are sanitized to `evt_<lowercase_alnum>`.
- Metadata columns: `block_number`, `tx_hash`, `log_index`, `contract_address`, `created_at`.
- Unique constraint: `UNIQUE(contract_address, tx_hash, log_index)`.
- Indexes: `(block_number)`, `(tx_hash)`, and `(contract_address, block_number)`.
