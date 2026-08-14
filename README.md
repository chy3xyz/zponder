<div align="center">

# ⚡ zponder

**Production-grade EVM event indexer in a single static binary — pure Zig, zero Node.js, zero Docker, zero external services.**

Index any smart contract on any EVM chain, react to events with Ponder-style JavaScript handlers,
and query everything through REST, GraphQL, and SSE — all in one process.

[![Release](https://img.shields.io/github/v/release/chy3xyz/zponder)](https://github.com/chy3xyz/zponder/releases)
[![License: MIT](https://img.shields.io/github/license/chy3xyz/zponder)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/chy3xyz/zponder/publish.yml)](https://github.com/chy3xyz/zponder/actions)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey)

*Inspired by [Ponder](https://ponder.sh) — rebuilt from the ground up in Zig.*

</div>

---

## Why zponder?

| | `zponder` | Typical JS indexer |
|---|---|---|
| **Runtime** | Single static binary, native machine code | Node.js + Docker + npm deps |
| **Handler scripts** | Embedded QuickJS — JS runs **inside** the Zig process | Separate process / VM |
| **Startup** | ~instant, no container orchestration | minutes of toolchain setup |
| **RPC cost** | Optional `eth_subscribe` live mode after catch-up | constant HTTP polling |
| **Storage** | SQLite / RocksDB / PostgreSQL out of the box | bring-your-own |

**One command to index:** write a handler, point at an RPC, go.

---

## ✨ Key Features

### 🚀 Indexing & Scripting
- **Embedded QuickJS Engine** — native JS runtime for event handlers:
  ```js
  ponder.on("PancakePair:Swap", (event) => { /* event.args, event.block */ });
  ```
- **Custom HTTP routes** — `ponder.http.get/post/use(...)` define your own API (Hono-style) right in handlers.
- **Auto Handler Scanning** — drop `.js` / `.json` files into `./handlers/`, they just work.
- **Multi-Contract Parallel Sync** — threaded per-contract loops with **reorg rollback** safety.
- **WSS Live Subscribe** — after HTTP catch-up, switch to `eth_subscribe("logs")` and cut RPC cost ([docs/WSS.md](docs/WSS.md)).
- **Async Webhook Queue** — non-blocking worker pool pushes event payloads to Telegram / Slack / your API.
- **Auto ABI Fetch** — pull ABIs straight from Etherscan / BscScan / PolygonScan.

### 💾 Storage & Resilience
- **Multi-Backend** — SQLite (WAL + isolated `read_db` pool), RocksDB, or PostgreSQL.
- **Multi-RPC Failover** — node rotation, retry, and circuit breaker built in.
- **LRU Query Cache** — thread-safe, memory-bounded, block-aware TTL invalidation.
- **State Tracking** — ERC-20 transfer & balance tracking out of the box.

### 📡 APIs & Tooling
- **GraphQL + Playground** — type-safe schema powered by `zgraphql`, with built-in IDE.
- **REST + SSE Stream** — filtered logs, balances, health, metrics, real-time event stream.
- **Declarative SQL Queries** — named, parameterized queries straight from `config.toml`.
- **CLI** — `start`, `check`, `dev`, `add-script`, `init`, `install`, `version`.

---

## 🚀 Quick Start

### Install (choose one)

```bash
# npm (recommended, auto-selects platform binary)
npm install -g zponder

# or from source
git clone https://github.com/chy3xyz/zponder.git && cd zponder && ./install.sh
```

### Index your first contract

```bash
zponder init          # interactive config wizard
zponder add-script swap_alert   # generate a handler template in ./handlers/
zponder start -c config.toml
```

That's it — blocks are flowing into SQLite, your JS handler is firing on every event,
and you can query it all:

```bash
curl -X POST localhost:8081/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ latestEvents(contract: \"uniswap_v2\", event: \"Swap\", limit: 5) { transactionHash fields { key value } } }"}'
```

---

## 🎯 Example: Whale Alert Handler

Drop this in `./handlers/whale_alert.js` — `zponder` picks it up automatically:

```javascript
ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  // uint 参数是 hex 字符串，用 BigInt 解析；按 18 位小数、$1800/ETH 估算
  const usd = Number(BigInt(value || "0x0")) / 1e18 * 1800;

  if (usd >= 1_000_000) {
    console.log(`🐋 Whale: ${from} → ${to} | $${usd.toLocaleString()} @ block ${event.block.number}`);
  }
});
```

Prefer declarative rules? Use a `.json` rule instead — no code required (webhook alerts to
Telegram/Slack are declarative JSON rules). See [`examples/handlers/`](examples/handlers/).

---

## 🧱 Architecture at a Glance

```
┌─────────────┐    eth_getLogs / eth_subscribe    ┌──────────────┐
│  RPC nodes  │ ────────────────────────────────► │  eth_rpc     │
└─────────────┘                                    │  + ws_rpc    │
                                                   └──────┬───────┘
                                                          ▼
                                              ┌─────────────────────┐
                                              │ indexer (per-contract│
                                              │  sync loop + reorg)  │
                                              └──────┬──────┬────────┘
                                                     ▼      ▼
                                       ┌───────────────────────────┐
                                       │ QuickJS / script engine   │
                                       │  → webhook queue          │
                                       └──────┬────────────┬───────┘
                                              ▼            ▼
                                     ┌────────────┐  ┌────────────┐
                                     │ SQLite /   │  │ REST +     │
                                     │ RocksDB /  │  │ GraphQL +  │
                                     │ PostgreSQL │  │ SSE        │
                                     └────────────┘  └────────────┘
```

---

## 📖 Documentation

| Doc | Content |
| :--- | :--- |
| [docs/API.md](docs/API.md) | REST + GraphQL + SSE API reference |
| [docs/WSS.md](docs/WSS.md) | WSS `eth_subscribe` live indexing & ops tips |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layered architecture (EN / 中文) |
| [docs/dev.md](docs/dev.md) | Design notes & config walkthrough |
| [examples/](examples/) | Local Anvil demo & production handler examples |

## 🧪 Testing

```bash
zig build test    # 83 unit + integration tests
```

---

<div align="center">

Built with ❤️ in [Zig](https://ziglang.org) · MIT License

</div>
