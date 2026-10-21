# zponder

EVM event indexer written in Zig 0.17.0. `zponder` indexes contract logs into SQLite, PostgreSQL, or RocksDB, runs QuickJS event handlers (`ponder.on`, `ponder.db`, `ponder.http`), and serves REST, GraphQL, and Server-Sent Events (SSE) from a single binary.

[![Release](https://img.shields.io/github/v/release/chy3xyz/zponder)](https://github.com/chy3xyz/zponder/releases)
[![License: MIT](https://img.shields.io/github/license/chy3xyz/zponder)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/chy3xyz/zponder/test.yml)](https://github.com/chy3xyz/zponder/actions)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)

## Capabilities

- **Embedded QuickJS-ng v0.17.0**: register event handlers with `ponder.on("Contract:Event", fn)`, write derived tables with `ponder.db.exec` and `ponder.db.query`, and mount custom HTTP routes with `ponder.http.get/post/put/delete/use`.
- **Transactional projections and reorg rollback**: event inserts, balance updates, and `ponder.db` writes run inside one SQLite or PostgreSQL transaction. Tables prefixed with `proj_` that contain a `block_number` column roll back automatically when a chain reorganization is detected (default `max_reorg_depth = 64`).
- **Raw log cache (`database.log_cache = true`)**: saves `eth_getLogs` responses and covered `[from_block, to_block]` intervals in `sync.chain_logs` and `sync.chain_log_ranges` (an attached `.sync.db` sidecar file on SQLite, or schema `sync` on PostgreSQL) so replays do not re-fetch covered blocks from the RPC node.
- **RPC range splitting and receipt fallback**: shrinks block batches on `-32005` / HTTP `413` / 10,000-log truncation, bisects address and `topic0` filters on single-block overflows, and falls back to `eth_getBlockReceipts` when a single address and single topic still exceed the RPC limit.
- **WebSocket live subscriptions (`ws_url`)**: switches to `eth_subscribe("logs")` after HTTP catch-up, splits large template clone sets into multiple subscriptions (`max_addresses_per_request`, default `200`), fills skipped blocks over HTTP, and enforces a 120-second idle read timeout.
- **Factory and template indexing (`[[factories]]`, `[[templates]]`)**: discovers child contracts from factory events (`address`) or from events emitted by template clones (`from_template`), storing all clone events in shared `event_<template>_<Event>` tables.
- **Full ABI decoding**: decodes static types, `string`, `bytes`, fixed and dynamic arrays, and Solidity `tuple` structs (both in event logs and `eth_call` single or multi-output returns, including signed `int*` values).
- **APIs and webhooks**: REST endpoints (`/events`, `/sync_state`, `/balance`, `/user`, `/queries`, `/replay`, `/health`, `/metrics`), `/stream` SSE, GraphQL (`zgraphql` v0.8.0) with `contractCall` and `Subscription.newBlocks`, optional `Authorization: Bearer <api_token>` authentication, and a persistent SQLite webhook outbox (`webhook_outbox.db`).

## Install

```bash
# Prebuilt binary via npm (SQLite backend, no external dynamic library dependencies)
npm install -g zponder

# Or build and install from source
git clone https://github.com/chy3xyz/zponder.git
cd zponder
./install.sh
```

### Build options

RocksDB and PostgreSQL are compile-time options (both enabled by default):

| Build mode | Command | Dynamic libraries |
|---|---|---|
| Default (all backends) | `zig build -Doptimize=ReleaseFast` | `sqlite3`, `librocksdb`, `libpq` |
| SQLite only (release binary) | `zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false` | `sqlite3` |
| Disable RocksDB only | `zig build -Doptimize=ReleaseFast -Drocksdb=false` | `sqlite3`, `libpq` |
| Disable PostgreSQL only | `zig build -Doptimize=ReleaseFast -Dpostgres=false` | `sqlite3`, `librocksdb` |

When a backend is disabled at compile time, setting `database.type` to that backend fails at startup with `RocksDbSupportNotCompiled` or `PostgresSupportNotCompiled`.

## Quick start

```bash
zponder init
zponder add-script swap_alert
zponder check -c config.toml
zponder start -c config.toml
```

Query indexed events over GraphQL:

```bash
curl -X POST http://localhost:8081/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ latestEvents(contract: \"dai\", event: \"Transfer\", limit: 5) { blockNumber transactionHash contractAddress fields { key value } } }"}'
```

## Example handler (`./handlers/whale_alert.js`)

```javascript
ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  const usd = (Number(BigInt(value || "0x0")) / 1e18) * 1800;

  if (usd >= 1_000_000) {
    console.log(
      `Whale transfer: ${from} -> ${to} ($${usd.toLocaleString()}) at block ${event.block.number} (${event.transactionHash}:${event.logIndex})`,
    );
  }
});
```

## Documentation

Build the documentation site with [`zdoc`](https://github.com/chy3xyz/zdoc):

```bash
zdoc docs docs --output public --force --strict
```

- [docs/index.md](docs/index.md) — Documentation home
- [docs/dev.md](docs/dev.md) — Configuration, CLI, JS handlers, projections, and templates
- [docs/API.md](docs/API.md) — REST, SSE, and GraphQL API reference
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Module layout, database schema, and data flow
- [docs/WSS.md](docs/WSS.md) — WebSocket `eth_subscribe` live indexing
- [docs/EVALUATION.md](docs/EVALUATION.md) — Engineering audit and resolved defects
- [examples/](examples/) — Local Anvil demos and handler scripts

## Testing

```bash
zig build test -Drocksdb=false -Dpostgres=false --summary all
```

## License

MIT
