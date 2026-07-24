# zponder

A production-grade EVM event indexer written in Zig 0.17.0, inspired by [Ponder](https://ponder.sh).

---

## Key Features

### 🚀 Core Indexing & Scripting
- **High Performance** — Zero-cost abstractions, no GC, native machine code.
- **Embedded QuickJS Engine** — Native embedded JavaScript runtime for dynamic event handlers (`ponder.on("Contract:Event", ...)`).
- **Auto Handler Scanning** — Automatically scans and executes `.js` & `.json` scripts placed under `./handlers/`.
- **Async Webhook Queue** — Non-blocking worker queue for pushing event payloads asynchronously.
- **Server-Sent Events (SSE)** — Real-time event streaming endpoint (`GET /api/v1/stream`).
- **Multi-Contract & Parallel Sync** — Threaded per-contract syncing loops.
- **WSS Live Subscribe** — Optional `ws_url` / `eth_subscribe("logs")` at tip to cut HTTP polling RPC cost ([docs/WSS.md](docs/WSS.md)).
- **Chain Reorg Handling** — Auto-detects chain reorganizations and safely rolls back stale blocks.
- **Auto ABI Fetch** — Downloads contract ABIs automatically from Etherscan / BscScan / PolygonScan.

### 💾 Storage & Failover
- **Multi-Backend Storage** — SQLite (with isolated `read_db` pool in WAL mode), RocksDB, or PostgreSQL.
- **Multi-RPC Failover** — Multi-node HTTP URL array rotation; optional WSS URL failover for live subscribe.
- **LRU Query Cache** — Thread-safe, memory-bounded cache with block-aware TTL invalidation.
- **State Tracking** — ERC-20 token transfer state & balance tracking out-of-the-box.

### 📡 APIs & Developer Tooling
- **CLI Subcommands** — Built-in `start`, `check`, `dev`, `add-script <name>`, `install`, `version`, `init`.
- **GraphQL API & Playground** — Full GraphQL schema engine powered by `zgraphql` with Playground IDE.
- **REST API & SSE Stream** — Filtered logs, account balances, health, metrics, and Server-Sent Events stream.
- **Custom SQL Queries** — Declarative config-driven named queries with typed parameters (`[[queries]]`).

---

## Tech Stack

| Layer              | Technology                                          |
|--------------------|-----------------------------------------------------|
| Language           | Zig 0.17.0-dev                                      |
| Script Engine      | Native Embedded QuickJS (C Runtime)                 |
| Storage            | SQLite / RocksDB / PostgreSQL                       |
| HTTP / SSE Server  | `std.http.Server` + `std.Io`                        |
| GraphQL Engine     | [zgraphql](https://github.com/chy3xyz/zgraphql) v0.3.1 |
| RPC Client         | HTTP JSON-RPC failover + optional WSS `eth_subscribe` |
| Build              | `build.zig` + `build.zig.zon`                        |

---

## Project Structure

```
zponder/
├── src/
│   ├── main.zig          # Entry point: CLI subcommands, module orchestration
│   ├── js_engine.zig     # QuickJS embedded JavaScript runtime wrapper
│   ├── script_engine.zig # Dynamic JSON rule & script engine + dir scanner
│   ├── webhook.zig       # Async Webhook queue & worker thread pool
│   ├── config.zig        # TOML config parser with validation (all sections)
│   ├── log.zig           # Structured logging (JSON/text, file+stderr)
│   ├── eth_rpc.zig       # JSON-RPC client: multi-node failover, retry, circuit breaker
│   ├── ws_rpc.zig        # WebSocket client: eth_subscribe(logs), ping/pong, reconnect
│   ├── db.zig            # Database client: SQLite (isolated read pool) + RocksDB + PostgreSQL
│   ├── rocksdb.zig       # RocksDB C bindings
│   ├── pg.zig            # PostgreSQL C bindings (libpq)
│   ├── indexer.zig       # Per-contract sync loop, WSS live mode, reorg handling, event hooks
│   ├── factory.zig       # Factory contract manager: child discovery + lifecycle
│   ├── http_server.zig   # REST API: routing, CORS, SSE stream (/stream), metrics
│   ├── graphql.zig       # GraphQL API: zgraphql schema, resolvers, rate limiting
│   ├── abi.zig           # ABI parsing, log decoding, eth_call encoding/decoding
│   ├── cache.zig         # Thread-safe LRU cache
│   └── root.zig          # Public API re-exports
├── quickjs/              # Native C QuickJS engine sources embedded
├── handlers/             # Auto-scanned user handler scripts (.js and .json)
├── examples/             # Production handler script examples & docs
├── install.sh            # One-command fast binary installer script
├── config.toml           # Runtime configuration file
├── build.zig             # Build script
└── build.zig.zon         # Package manifest
```

---

## Quick Start

### 1. Installation

```bash
# Clone repository
git clone https://github.com/chy3xyz/zponder.git
cd zponder

# One-command build & install to ~/.local/bin/zponder
./install.sh
```

Or build manually using Zig:
```bash
zig build -Doptimize=ReleaseFast
```

### 2. Generate a Business Handler Script

Use `zponder add-script` to generate a new handler script template in `./handlers/`:

```bash
# Generate a JavaScript Handler template
zponder add-script dex_swap

# Generate a JSON Rule template
zponder add-script transfer_rule --json
```

### 3. Configure RPC (HTTP + optional WSS)

```toml
[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
# Optional: after catch-up, switch tip sync to eth_subscribe(logs)
ws_url = "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

See [docs/WSS.md](docs/WSS.md) for hybrid indexing, failover (`ws_urls`), and ops tips.

### 4. Verify Configuration & Environment

```bash
zponder check -c config.toml
```

### 5. Start Indexing

```bash
zponder -c config.toml
```

---

## JavaScript Handler API (Ponder-Style)

Place `.js` script files under `./handlers/`. `zponder` automatically scans and loads them:

```javascript
/**
 * handlers/swap_handler.js
 */
ponder.on("PancakePair:Swap", async ({ event, context }) => {
  const { sender, amount0In, amount1Out } = event.args;
  const blockNumber = event.block.number;

  const in0 = BigInt(amount0In || "0");
  const out1 = BigInt(amount1Out || "0");

  if (in0 > 0n && out1 > 0n) {
    const price = Number(out1) / Number(in0);
    console.log(`[DEX Swap] Block #${blockNumber} | Price: ${price.toFixed(6)}`);

    // Trigger Telegram / Slack Webhook alert for large swaps
    if (in0 >= 100000000000000000000n) {
      await context.webhook.post("https://api.telegram.org/botYOUR_KEY/sendMessage", {
        text: `🚨 Large Swap Alert @ Block #${blockNumber}: ${sender}`
      });
    }
  }
});
```

---

## CLI Command Reference

| Subcommand | Description | Example |
| :--- | :--- | :--- |
| `zponder start` | Starts the indexing daemon (default) | `zponder -c config.toml` |
| `zponder check` | Validates config.toml, RPC connectivity & DB migrations | `zponder check -c config.toml` |
| `zponder dev` | Runs in debug mode with auto-scanning of `./handlers` | `zponder dev` |
| `zponder add-script <name>` | Generates a business handler template (`.js` or `--json`) | `zponder add-script dex_swap` |
| `zponder init` | Interactive configuration wizard | `zponder init` |
| `zponder install` | Installs the binary to system PATH (`~/.local/bin/zponder`) | `zponder install` |
| `zponder version` | Displays version, git commit, and feature flags | `zponder version` |

---

## Documentation

| Doc | Content |
| :--- | :--- |
| [docs/WSS.md](docs/WSS.md) | Optional WSS `eth_subscribe` live indexing (config, reconnect, ops) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layered architecture (EN / 中文) |
| [docs/API.md](docs/API.md) | REST + GraphQL + SSE API reference |
| [docs/dev.md](docs/dev.md) | Design notes & config walkthrough |
| [examples/](examples/) | Local Anvil demo & handler examples |

---

## Testing

Run full test suite (70+ unit tests, including WS frame / Accept-key helpers):

```bash
zig build test
```

---

## License

MIT
