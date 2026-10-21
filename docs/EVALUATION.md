---
order: 5
---

# Engineering evaluation

This document records the defects identified and resolved across `zponder`'s RPC client, ABI decoder, storage backends, indexer loop, and HTTP/GraphQL servers.

## Critical issues (resolved)

- **C1. `parseLogs` returned a static empty slice (`src/eth_rpc.zig`)**: callers freed the returned slice with `freeLogs`, crashing when a block range returned zero logs. `parseLogs` now allocates an empty slice from the caller's allocator.
- **C2. Unchecked `topic0[2..]` slice (`src/indexer.zig`)**: logs with a `topic0` shorter than 66 characters caused an out-of-bounds panic. `processLog` validates `topic0.len >= 66` before slicing.
- **C3. Unbounded HTTP worker threads (`src/http_server.zig`)**: `runLoop` spawned a detached thread per connection without a cap. `active_connections` now enforces `MAX_CONCURRENT_CONNECTIONS = 256`.
- **C4. Ignored SQLite WAL pragma errors (`src/db.zig`)**: `PRAGMA journal_mode=WAL` failures were discarded. `init` now checks the return code and enables `PRAGMA synchronous=NORMAL`, `PRAGMA foreign_keys=ON`, and `PRAGMA busy_timeout`.

## High-severity issues (resolved)

- **H1. $O(n)$ LRU eviction (`src/cache.zig`)**: replaced linear array scans with `std.DoublyLinkedList` and `std.StringHashMap` for $O(1)$ lookup, promotion, and eviction.
- **H2. Silent 4096-byte log truncation (`src/log.zig`)**: switched to `std.fmt.allocPrint` with a stack fallback.
- **H3. Network timeouts (`src/eth_rpc.zig`, `src/ws_rpc.zig`, `src/http_server.zig`)**:
  - HTTP JSON-RPC (`request_timeout_ms`) wraps per-request `Io.operate` calls with `operateTimeout` so stalled connections fail with `ConnectionTimedOut`.
  - WebSocket live subscriptions (`ws_rpc.idle_timeout_ms = 120_000`) time out silent connections after 120 seconds without reusing the shorter HTTP timeout.
  - HTTP server connections enforce both `read_timeout_ms` (via `operateTimeout`) and `write_timeout_ms` (via `O_NONBLOCK` + `MSG_DONTWAIT` `send` and `poll` deadlines when the socket send buffer fills up).
- **H4. Undecodable logs and handler failures dropped (`src/indexer.zig`, `src/db.zig`)**: failed logs are recorded in `raw_logs` with `attempts` and exponential-backoff `retry_after` timestamps (`1s` to `256s`), exposed on `/health` (`dead_letters`) and `/metrics` (`zponder_dead_letters`).
- **H5. Unescaped URL query parameters (`src/http_server.zig`)**: added `urlDecodeAlloc` before parsing query parameters.
- **H6. Unbounded HTTP request bodies (`src/http_server.zig`)**: enforced `MAX_BODY_SIZE = 1048576` (`413 Payload Too Large`).
- **H7. Unchecked `hexToBytes` return value (`src/indexer.zig`)**: invalid hex strings in `topic0` are logged and skipped instead of matching against uninitialized bytes.

## Medium-severity issues and parity improvements (resolved)

- **M1. TOML parser (`src/config.zig`)**: handles inline `#` comments outside quotes, multiline `"""` strings, CRLF line endings, unclosed array syntax errors, and `errdefer` cleanup on partial parse failures.
- **M2. Account balances (`src/db.zig`, `src/http_server.zig`, `src/indexer.zig`)**: `Transfer` events update `account_states` (skipped during `.replaying` to avoid double-counting), and `GET /balance/:contract/:account` queries the state.
- **M3. Snapshots (`src/indexer.zig`)**: periodic snapshots serialize contract address, block number, and timestamp as JSON.
- **M4 & M5. Configurable batching and RPC concurrency (`src/config.zig`, `src/eth_rpc.zig`, `src/indexer.zig`)**: `block_batch_size`, `poll_interval_ms`, and `max_concurrent` are wired from `config.toml`.
- **M6. Reorg detection and cascade rollback (`src/indexer.zig`, `src/db.zig`, `src/factory.zig`)**:
  - `max_reorg_depth` defaults to `64` (`0` disables).
  - On a fork at block `N`, `rollbackFromBlock` deletes `event_*`, `proj_*`, `blocks`, and `sync.chain_logs` rows with `block_number >= N` and shrinks `sync.chain_log_ranges` in a single SQLite or PostgreSQL transaction.
  - Factory child indexers discovered at or after `N` are stopped and removed; earlier child indexers are rewound to `N` and restarted.
- **M7, M8, M9. Memory leaks, structured logging, and dynamic column sanitization (`src/db.zig`, `src/indexer.zig`)**: fixed `getSyncState` string ownership, routed database errors through `log.zig`, and replaced fixed-size column buffers with `std.ArrayList(u8)`.
- **M10. Full ABI decoding (`src/abi.zig`, `src/graphql.zig`)**:
  - Event inputs and function outputs with `"type": "tuple"` and `components` are canonicalized to `(T1,T2,...)`, `(T1,T2)[]`, or `(T1,T2)[k]`.
  - Event `topic0` hashes the canonical tuple signature.
  - `decodeLog` decodes static values, `string`, `bytes`, fixed and dynamic arrays, and static or dynamic tuples (with tuple-relative offsets for dynamic fields) into hex strings or JSON arrays.
  - `decodeCallResult` and `decodeSingleOutput` decode multi-output tuples, single dynamic struct outputs, arrays, and signed two's-complement `int*` values for `eth_call`.
- **Raw log cache and RPC range recovery (`src/log_cache.zig`, `src/indexer.zig`, `src/eth_rpc.zig`)**:
  - When `database.log_cache = true`, raw logs and covered `[from_block, to_block]` ranges per `(chain, address, topics_key)` are stored in `sync.chain_logs` and `sync.chain_log_ranges`.
  - Covered ranges are replayed locally without calling `eth_getLogs`.
  - When a single block exceeds the RPC log limit (10,000 logs or `-32005`), the indexer bisects the address list, bisects the `topic0` list, and falls back to `eth_getBlockReceipts` when a single address and single topic still overflow.
- **Transactional handlers and reentrant write lock (`src/db.zig`, `src/indexer.zig`)**:
  - `db.Client` uses a reentrant pthread mutex (`write_mu`) so `processLog` wraps event insertion, balance tracking, and `ponder.db.exec` calls from QuickJS inside one database transaction.
  - Duplicate `(contract_address, tx_hash, log_index)` logs skip balance updates and JS handlers while still running factory discovery callbacks.
- **Graceful shutdown ordering (`src/main.zig`, `src/graphql.zig`, `src/factory.zig`)**:
  - Signal handling (`SIGINT` / `SIGTERM`) stops the HTTP server, GraphQL server (via a TCP wake poke and thread join), parent indexers, and factory child indexers before closing the database and freeing engines.

## Test suite

Run the SQLite test suite (used in CI):

```bash
zig build test -Drocksdb=false -Dpostgres=false --summary all
```

401 of 429 tests pass across the module and executable test binaries; the 28 skipped tests are the optional PostgreSQL and RocksDB backend suites when built with `-Drocksdb=false -Dpostgres=false`.
