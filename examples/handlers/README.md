# Handler scripts and rules

Files placed in `./handlers/` are loaded at startup without recompiling `zponder`.

## Quick setup

1. Configure your contract (`name`, `address`, `abi_path`, `events`) in `config.toml`.
2. Copy one of the scripts in this directory into `./handlers/` and adjust the contract and field names.
3. Run `zponder start -c config.toml`.

## JavaScript event handlers (`ponder.on`)

```javascript
ponder.on("ContractName:EventName", (event) => {
  const { field1, field2 } = event.args;
  const blockNumber = event.block.number;
  const timestamp = event.block.timestamp;
});
```

- `uint` and `int` values in `event.args` are `0x`-prefixed hex strings; parse them with `BigInt(...)`.
- `address` is a `"0x..."` hex string; `bool` is `"true"` or `"false"`.
- Fixed arrays, dynamic arrays, and Solidity `tuple` structs are JSON array strings (`["0x...","0x..."]`).
- `event.block.number` and `event.block.timestamp` are numbers.
- `event.contractAddress` is the emitting contract address (the specific clone address in template mode).
- `event.transactionHash` and `event.logIndex` identify the log within its transaction; use `(transactionHash, logIndex)` as a primary key in projection tables.
- Handlers can match `"Contract:Event"` or the bare event name `"Event"`. If multiple scripts register the same key, the last registered handler wins.

| File | Description |
|---|---|
| `dex_swap_monitor.js` | Computes swap price and direction for a USDC/ETH pair. |
| `erc20_whale_alert.js` | Logs large ERC-20 transfers, mints, and burns. |
| `nft_tracker.js` | Tracks ERC-721 mints, transfers, and burns. |
| `erc20_projection.js` | Writes per-transfer rows and per-block aggregates with `ponder.db`. |
| `custom_api.js` | Registers custom HTTP endpoints and middleware with `ponder.http`. |

## Declarative webhook rules (`.json`)

JSON files in `./handlers/` trigger logs or outbound webhooks when an event field crosses a threshold:

```json
[
  {
    "contract": "USDC",
    "event": "Transfer",
    "field": "value",
    "op": "gte",
    "val": "1000000000000",
    "action": {
      "type": "webhook",
      "url": "https://api.telegram.org/botYOUR_TOKEN/sendMessage"
    }
  }
]
```

- Supported `op` values: `gt`, `gte`, `lt`, `lte`, `eq`.
- Supported `action.type` values: `log` and `webhook`.
- See `whale_alert.json` and `multi_contract_rules.json`.

## Custom HTTP routes (`ponder.http`)

```javascript
ponder.http.use((c, next) => {
  if (c.req.query("api_key") !== "secret123") {
    c.status(401);
    return c.json({ error: "invalid api_key" });
  }
  next();
});

ponder.http.get("/api/wei/:amount", (c) => {
  const wei = c.req.param("amount");
  return c.json({ eth: Number(wei) / 1e18 });
});

ponder.http.post("/api/echo", (c) => {
  return c.json({ received: c.req.body() });
});
```

Routes are served on the main HTTP server (default `http://localhost:8080`) alongside the built-in REST endpoints.

## Database projections (`ponder.db`)

```javascript
ponder.db.exec(`
  CREATE TABLE IF NOT EXISTS proj_erc20_kline (
    block_number INTEGER NOT NULL PRIMARY KEY,
    ts           INTEGER NOT NULL,
    total        TEXT NOT NULL,
    tx_count     INTEGER NOT NULL DEFAULT 0
  );
`);

ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  const amount = String(BigInt(value || "0x0"));

  ponder.db.exec(
    "INSERT OR REPLACE INTO proj_erc20_flow (block_number, ts, from_addr, to_addr, amount) VALUES (?, ?, ?, ?, ?);",
    event.block.number,
    event.block.timestamp,
    from,
    to,
    amount,
  );

  ponder.db.exec(
    `INSERT INTO proj_erc20_kline (block_number, ts, total, tx_count) VALUES (?, ?, ?, 1)
     ON CONFLICT(block_number) DO UPDATE SET
       total = CAST(CAST(total AS INTEGER) + CAST(excluded.total AS INTEGER) AS TEXT),
       tx_count = tx_count + 1;`,
    event.block.number,
    event.block.timestamp,
    amount,
  );
});
```

| Method | Behavior |
|---|---|
| `ponder.db.exec(sql, ...params)` | Executes DDL or DML statements and returns the number of affected rows. |
| `ponder.db.query(sql, ...params)` | Executes a `SELECT` query and returns an array of row objects keyed by column name. |

- Placeholders use `?` on SQLite and `$1..$n` on PostgreSQL. Supported parameter types: `number`, `string`, `boolean`, `null`, and `ArrayBuffer` (`BLOB`).
- Supported on SQLite and PostgreSQL; calling `ponder.db` on RocksDB throws an error.
- Tables named `proj_*` with a `block_number` column are automatically rolled back (`DELETE FROM proj_* WHERE block_number >= fork_point`) inside the reorg transaction.

## Template mode (`[[templates]]`)

When a factory contract deploys many clones that share one ABI, declare a `[[templates]]` section instead of adding each clone to `[[contracts]]`. All clones write into `event_<template>_<Event>` and store the emitting clone address in `contract_address`.

Run the local Anvil launchpad demo (1 factory + 3 clones + downstream pair template):

```bash
bash examples/local-demo/launchpad-demo/run.sh
```

```toml
[[contracts]]
name = "launchpad"
address = "0xLaunchpad..."
abi_path = "./abis/Launchpad.abi"
events = ["CurveCreated"]

[[factories]]
name = "launchpad_factory"
address = "0xLaunchpad..."
abi_path = "./abis/Launchpad.abi"
creation_event = "CurveCreated"
child_address_field = "curve"
template_name = "curve"

[[templates]]
name = "curve"
abi_path = "./abis/Curve.abi"
events = ["Buy"]
factory_name = "launchpad_factory"
from_block = 0
poll_interval_ms = 200
block_batch_size = 500
max_addresses_per_request = 200
```

- Filter events for a specific clone with `GET /events/curve/Buy?address=0xCLONE` or GraphQL `latestEvents(contract: "curve", event: "Buy", address: "0xCLONE")`.
- Inside `ponder.on("curve:Buy", fn)`, `event.contractAddress` holds the lowercase hex address of the clone that emitted the event.
