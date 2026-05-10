# zponder

Production-grade EVM event indexer written in Zig. Index any smart contract on any
EVM-compatible chain. Ships with REST API, GraphQL API, and built-in Playground.

```bash
npm install -g zponder
```

## Quick Start

```bash
# Interactive setup wizard
zponder init

# Start indexing
zponder -c config.toml
```

## Features

- **High Performance** — native binary, zero runtime dependencies, < 3MB
- **Multi-chain** — Ethereum, BSC, Polygon, and any EVM chain
- **Multi-storage** — SQLite, RocksDB, or PostgreSQL
- **REST API** — paginated event queries, Prometheus metrics, health checks
- **GraphQL API** — full schema with contracts, events, sync state, eth_call
- **GraphQL Playground** — built-in zero-dependency IDE
- **Factory Contracts** — auto-discover and index child contracts
- **Rate Limiting** — token-bucket for both REST and GraphQL
- **Reorg Detection** — automatic fork detection and rollback

## Platforms

Pre-built binaries for:

| OS | Arch | Status |
|----|------|--------|
| macOS | arm64 (Apple Silicon) | Included |
| macOS | x64 (Intel) | Build from source |
| Linux | x64 | Build from source |
| Linux | arm64 | Build from source |

## Build from Source

```bash
git clone https://github.com/chy3xyz/zponder.git
cd zponder
zig build -Doptimize=ReleaseFast
./zig-out/bin/zponder -c config.toml
```

Requirements: [Zig](https://ziglang.org/) 0.16.0+, sqlite3, rocksdb (optional), libpq (optional for PostgreSQL)

## Documentation

- [README](https://github.com/chy3xyz/zponder)
- [API Reference](https://github.com/chy3xyz/zponder/tree/main/docs/API.md)
- [Architecture](https://github.com/chy3xyz/zponder/tree/main/docs/ARCHITECTURE.md)
