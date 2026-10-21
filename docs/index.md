---
layout: home
description: EVM event indexer in Zig 0.17.0.
hero:
  name: zponder
  text: EVM event indexer in Zig
  tagline: Index smart contract events, run QuickJS handlers, and serve REST, GraphQL, and SSE from one binary.
  actions:
    - theme: brand
      text: Configuration
      link: /dev/
    - theme: alt
      text: API reference
      link: /API/
features:
  - title: Raw log cache
    details: When log_cache = true, eth_getLogs results and scanned block ranges are saved in sync.chain_logs and sync.chain_log_ranges so replays skip RPC calls for covered blocks.
  - title: Live WebSocket subscriptions
    details: After HTTP catch-up, indexers switch to eth_subscribe("logs"), chunk template address sets by max_addresses_per_request, and recover gaps over HTTP.
  - title: Transactional handlers and projections
    details: QuickJS handlers write to proj_* tables with ponder.db.exec; handler failures roll back the event transaction and queue the log in raw_logs for backoff retry.
---

# zponder

`zponder` indexes smart contract events from EVM chains into SQLite, PostgreSQL, or RocksDB. It embeds QuickJS-ng for JavaScript handlers (`ponder.on`, `ponder.db`, `ponder.http`) and exposes REST, GraphQL, and Server-Sent Events (SSE) from the same process.

## Documentation

1. [Configuration and handlers](dev.md) — `config.toml` sections, CLI commands, QuickJS handlers, projections, and templates.
2. [API reference](API.md) — REST endpoints, SSE event stream, and GraphQL queries and subscriptions.
3. [Architecture](ARCHITECTURE.md) — module responsibilities, database schema, reorg rollback, and concurrency model.
4. [WebSocket live indexing](WSS.md) — `ws_url` setup, template multi-subscription chunking, gap fill, and idle timeouts.
5. [Engineering evaluation](EVALUATION.md) — audit log of bugs found and fixed across storage, RPC, ABI decoding, and concurrency.

## Build the docs site

```bash
zdoc docs docs --output public --force --strict
```

Run `zdoc` from the repository root to preview the documentation locally. Site metadata lives in `docs/.zdoc-theme/site.yaml`.
