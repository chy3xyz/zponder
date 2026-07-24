# AGENTS.md — zponder Project Guide

> AI coding assistant reference for the zponder codebase: current state, conventions, and module map.

---

## Project Overview

**zponder** is a production-grade EVM event indexer written in Zig 0.17.0, inspired by [Ponder](https://ponder.sh). It indexes smart contract events from EVM-compatible chains and stores them in SQLite, RocksDB, or PostgreSQL. Includes a built-in REST API, GraphQL API, QuickJS JavaScript Handler Engine, Async Webhook Worker Queue, SSE Stream, optional WSS `eth_subscribe` live indexing, dashboard UI, factory contract support, and eth_call for reading on-chain state.

---

## Current Project State

| Item                    | Status       |
|-------------------------|--------------|
| `build.zig` + `build.zig.zon` | Complete (embeds QuickJS + zgraphql v0.3.1) |
| `src/` source files     | 22+ Zig files |
| `config.toml`           | Complete (`ws_url` / `ws_urls` optional) |
| Unit tests              | 70+ passing  |
| QuickJS Script Engine   | Production (Ponder-style `ponder.on` JS API) |
| Async Webhook Queue     | Production   |
| SSE Stream API          | Production (`/stream`, `/api/v1/stream`) |
| WSS Live Subscribe      | Production (HTTP catch-up → tip `eth_subscribe(logs)`) |
| CLI Tools               | `start`, `check`, `dev`, `add-script`, `install`, `version` |
| REST & GraphQL API      | Production   |
| Factory contracts       | Implemented  |
| Docs                    | README, API, ARCHITECTURE, WSS, dev.md, EVALUATION, examples |

---

## Tech Stack

| Layer              | Technology                                    |
|--------------------|-----------------------------------------------|
| Language           | Zig 0.17.0-dev                                |
| Script Engine      | Native Embedded QuickJS C Runtime             |
| Storage            | SQLite (with `read_db` pool) / RocksDB / PostgreSQL |
| HTTP Server        | `std.http.Server` + `std.Io`                 |
| GraphQL Engine     | [zgraphql](https://github.com/chy3xyz/zgraphql) v0.3.1 |
| RPC Client         | HTTP JSON-RPC failover + optional WSS `eth_subscribe` |
| Build              | `build.zig` + `build.zig.zon`                 |

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
│   └── root.zig          # Public API re-exports
├── quickjs/              # Native C QuickJS engine sources embedded
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

# Install fast release binary
./install.sh
```

---

## License

MIT
