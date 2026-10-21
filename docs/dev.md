---
order: 1
---

# Configuration and handlers

`zponder` reads runtime settings from `config.toml` and loads event handlers from `./handlers/`.

## CLI commands

| Command | Action |
|---|---|
| `zponder start [-c config.toml]` | Start the indexer, HTTP server, and optional GraphQL server. |
| `zponder check [-c config.toml]` | Validate `config.toml`, parse ABI files, test RPC connectivity, and run database migrations. Returns a non-zero exit code on failure. |
| `zponder dev [-c config.toml]` | Run with `debug` log level and scan `./handlers/` on startup. |
| `zponder init` | Interactive wizard that writes a starter `config.toml`. |
| `zponder add-script <name> [--json]` | Write a `.js` handler or `.json` webhook rule template into `./handlers/`. |
| `zponder install` | Copy the compiled binary to `$HOME/.local/bin/zponder`. |
| `zponder version` | Print version, git commit, Zig version, and compiled storage backends. |

## Configuration (`config.toml`)

### `[global]`

```toml
[global]
log_level = "info"              # debug | info | warn | error
log_file = "./logs/indexer.log"
snapshot_interval = 3600        # seconds; 0 disables periodic snapshots
etherscan_api_key = ""          # optional; fetches missing ABIs from Etherscan-compatible APIs
chain = "ethereum"              # default chain name
schema_path = "schema.zp"       # optional; creates user_* tables for GET /user/:table/:pk
```

### `[rpc]` and `[[chains]]`

Single-chain deployments configure `[rpc]`:

```toml
[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
urls = [
  "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
  "https://rpc.ankr.com/eth"
]
ws_url = "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
ws_urls = ["wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"]
request_timeout_ms = 10000      # per-request HTTP read/write timeout; 0 disables
retry_count = 3
retry_delay_ms = 500
max_concurrent = 10
```

Multi-chain deployments define `[[chains]]` entries (`name`, `chain_id`, `rpc_url`, `ws_url`) and set `chain = "<name>"` on each `[[contracts]]` entry. When `[[chains]]` is omitted, `zponder` synthesizes one chain from `[global].chain` and `[rpc]`. Templates, factories, and GraphQL `contractCall` use the first configured chain.

### `[database]`

```toml
[database]
type = "sqlite"                 # sqlite | postgresql | rocksdb
db_name = "eth_indexer.db"      # SQLite file path, RocksDB directory, or PostgreSQL conninfo
wal_mode = true
busy_timeout_ms = 5000
max_connections = 10            # SQLite read pool size
log_cache = true                # store raw logs and covered ranges in sync schema
```

When `log_cache = true`:

- **SQLite** attaches `<stem>.sync.db` (for example, `eth_indexer.sync.db`) as schema `sync`.
- **PostgreSQL** creates schema `sync` in the same database.
- **RocksDB** is not supported with `log_cache = true` and exits at startup.

The cache records `sync.chain_logs` and `sync.chain_log_ranges` keyed by `(chain, address, topics_key, from_block)`. Covered ranges are not re-fetched from `eth_getLogs` during replay or restart.

### `[http]` and `[graphql]`

```toml
[http]
host = "0.0.0.0"
port = 8080
read_timeout_ms = 30000         # closes idle connections; 0 disables
write_timeout_ms = 30000        # aborts stalled writes when send buffer is full; 0 disables
max_body_size = 1048576
cors = true                     # or cors_origins = ["https://app.example"]
rate_limit_rps = 100
rate_limit_burst = 200
api_token = ""                  # when non-empty, requires Authorization: Bearer <token>

[graphql]
enabled = true
host = "0.0.0.0"
port = 8081
enable_playground = true
max_query_depth = 20
max_query_complexity = 1000
rate_limit_rps = 10
rate_limit_burst = 100
```

When `api_token` is non-empty, both the REST server and the GraphQL server require `Authorization: Bearer <api_token>` on all requests except `GET /health` and CORS `OPTIONS` preflight requests.

### `[[contracts]]`

```toml
[[contracts]]
name = "dai"
address = "0x6b175474e89094c44da98b954eedeac495271d0f"
abi_path = "./abis/erc20.abi"
from_block = 20000000
block_batch_size = 500
poll_interval_ms = 2000
max_reorg_depth = 64            # default 64; set 0 to disable block hash checks
events = ["Transfer", "Approval"]
filters = ["Transfer:value:gt:1000000000000000000"]
```

### `[[factories]]` and `[[templates]]`

Use `[[templates]]` when a factory deploys many clone contracts that share one ABI. All clones write to a single `event_<template>_<Event>` table with a `contract_address` column.

```toml
[[contracts]]
name = "launchpad"
address = "0x1111111111111111111111111111111111111111"
abi_path = "./abis/Launchpad.abi"
events = ["CurveCreated"]

[[factories]]
name = "launchpad_factory"
address = "0x1111111111111111111111111111111111111111"
abi_path = "./abis/Launchpad.abi"
creation_event = "CurveCreated"
child_address_field = "curve"
template_name = "curve"

[[templates]]
name = "curve"
abi_path = "./abis/Curve.abi"
events = ["Buy", "Sell", "LiquidityMigrated"]
factory_name = "launchpad_factory"
from_block = 0
poll_interval_ms = 2000
block_batch_size = 500
max_addresses_per_request = 200
```

If a clone contract itself emits an event announcing a downstream contract (such as a liquidity pair), set `from_template = "curve"` instead of `address` on a second `[[factories]]` entry.

## JavaScript handlers (`./handlers/*.js`)

Files in `./handlers/` are executed by the embedded QuickJS-ng engine.

### `ponder.on`

```javascript
ponder.on("dai:Transfer", (event) => {
  const { from, to, value } = event.args;
  const blockNumber = event.block.number;
  const timestamp = event.block.timestamp;
  const txHash = event.transactionHash;
  const logIndex = event.logIndex;
  const address = event.contractAddress;
});
```

- `uint` and `int` event arguments are `0x`-prefixed hex strings; parse them with `BigInt(value)`.
- Static arrays, dynamic arrays, and Solidity structs (`tuple`) are JSON array strings, such as `["0x...","0x..."]`.
- Indexed dynamic values (`string`, `bytes`, arrays, tuples) are stored as `"hash:0x..."` because the EVM log topic only contains the 32-byte Keccak-256 digest.
- When a handler throws an exception, `processLog` rolls back the SQLite or PostgreSQL write transaction for that log and records the log in `raw_logs` for exponential-backoff retry.

### `ponder.db` projections

```javascript
ponder.db.exec(`
  CREATE TABLE IF NOT EXISTS proj_daily_volume (
    block_number INTEGER NOT NULL,
    tx_hash      TEXT NOT NULL,
    log_index    INTEGER NOT NULL,
    volume       TEXT NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
  );
`);

ponder.on("dai:Transfer", (event) => {
  ponder.db.exec(
    "INSERT OR REPLACE INTO proj_daily_volume (block_number, tx_hash, log_index, volume) VALUES (?, ?, ?, ?);",
    event.block.number,
    event.transactionHash,
    event.logIndex,
    String(BigInt(event.args.value || "0x0")),
  );
});
```

Tables whose names start with `proj_` and include a `block_number` column participate in reorg rollback: when a fork is detected at block `N`, `rollbackFromBlock` deletes rows with `block_number >= N` inside the same database transaction as the `event_*` tables.

### `ponder.http` custom routes

```javascript
ponder.http.get("/api/volume/:tx", (c) => {
  const tx = c.req.param("tx");
  const rows = ponder.db.query(
    "SELECT volume FROM proj_daily_volume WHERE tx_hash = ?;",
    tx,
  );
  return c.json(rows);
});
```

Supported methods: `ponder.http.get`, `post`, `put`, `delete`, and `use` middleware. Context methods: `c.req.param(name)`, `c.req.query(name)`, `c.req.body()`, `c.status(code)`, `c.header(k, v)`, `c.json(val)`, and `c.text(str)`.

## Declarative webhook rules (`./handlers/*.json`)

JSON files in `./handlers/` define threshold rules without JavaScript:

```json
[
  {
    "contract": "dai",
    "event": "Transfer",
    "field": "value",
    "op": "gte",
    "val": "100000000000000000000000",
    "action": {
      "type": "webhook",
      "url": "https://example.com/webhook"
    }
  }
]
```

Supported operators: `gt`, `gte`, `lt`, `lte`, `eq`. Outbound webhooks are persisted in `webhook_outbox.db` and retried up to 8 attempts by background worker threads.
