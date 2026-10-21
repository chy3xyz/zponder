---
order: 2
---

# API reference

`zponder` exposes a REST server (default port `8080`) and an optional GraphQL server (default port `8081`).

When `[http].api_token` is set in `config.toml`, every REST and GraphQL endpoint except `GET /health` and `OPTIONS` preflight requests requires the header `Authorization: Bearer <api_token>`.

## REST API

Base URL: `http://localhost:8080`

### `GET /health`

Returns indexer progress, dead-letter count (`raw_logs`), and LRU cache statistics. Exempt from `api_token` authentication.

```json
{
  "status": "ok",
  "dead_letters": 0,
  "indexers": [
    {
      "name": "dai",
      "current_block": 20123456,
      "status": "running"
    }
  ],
  "cache": {
    "entries": 42,
    "bytes": 16384
  }
}
```

### `GET /stream` (or `GET /api/v1/stream`)

Server-Sent Events (SSE) stream that pushes newly indexed logs in real time.

Response headers:
- `Content-Type: text/event-stream`
- `Cache-Control: no-cache`
- `Connection: keep-alive`

```text
retry: 3000

event: connected
data: {"status":"connected","service":"zponder SSE real-time stream"}

event: log
data: {"contract":"PancakePair","contract_address":"0xabc...","block_number":20123456,"tx_hash":"0xdef...","log_index":12,"fields":{"amount0In":"0x0","amount1Out":"0x1f4"}}
```

### `GET /version`

Returns the binary version, git commit, and Zig compiler version.

```json
{
  "version": "0.9.0",
  "commit": "d15a333",
  "zig_version": "0.17.0"
}
```

### `GET /sync_state`

Returns sync progress for each contract or template indexer.

```json
[
  {
    "name": "dai",
    "address": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "current_block": 20123456,
    "status": "running"
  }
]
```

Status values: `running`, `stopped`, `error`, `replaying`. Note that `current_block` is the next block to scan.

### `GET /contracts`

Lists configured contracts and templates. Template entries have `"address": ""`.

```json
[
  {
    "name": "dai",
    "address": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "abi_path": "./abis/erc20.abi",
    "from_block": 20000000,
    "events": ["Transfer", "Approval"]
  }
]
```

### `GET /events/:contract/:event`

Queries decoded event rows from `event_<contract>_<event>`.

| Query parameter | Type | Default | Description |
|---|---|---|---|
| `block_from` | integer | — | Inclusive start block |
| `block_to` | integer | — | Inclusive end block |
| `tx_hash` | string | — | Exact transaction hash match |
| `address` | string | — | Exact `contract_address` match (unsupported on RocksDB) |
| `limit` | integer | `100` | Maximum rows returned (clamped to `1..1000`) |
| `offset` | integer | `0` | Pagination offset |
| `order` | string | `desc` | Sort order by `block_number`: `asc` or `desc` |

```json
[
  {
    "block_number": 20000001,
    "tx_hash": "0xabc...",
    "log_index": 0,
    "contract_address": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "evt_from": "0x1111...",
    "evt_to": "0x2222...",
    "evt_value": "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000"
  }
]
```

### `GET /balance/:contract/:account`

Queries tracked token balances from `account_states`.

### `GET /user/:table/:pk`

Queries a row by primary key from a `user_<table_name>` table defined in `schema_path`.

### `GET /queries/:name`

Executes a named SQL query configured under `[[queries]]` in `config.toml`. Query parameters match the declared `params = ["name:type:default"]` list.

### `POST /replay`

Rewinds a contract or template indexer and re-indexes a block range. When `log_cache = true`, blocks already stored in `sync.chain_log_ranges` are replayed from local storage without calling `eth_getLogs`.

| Query parameter | Type | Required | Description |
|---|---|---|---|
| `contract` | string | yes | Contract or template name |
| `from_block` | integer | yes | Inclusive start block |
| `to_block` | integer | no | Inclusive end block (`0` or omitted replays through the chain tip) |

```json
{ "status": "replaying" }
```

### `GET /cache/stats`

Returns in-memory LRU response cache usage.

```json
{
  "cached_entries": 42,
  "total_bytes": 16384
}
```

### `GET /metrics`

Prometheus text exposition format. Includes `zponder_cache_entries`, `zponder_cache_bytes`, `zponder_indexers`, `zponder_indexer_current_block`, `zponder_indexer_lag`, `zponder_indexer_status`, `zponder_rpc_requests_total`, `zponder_rpc_errors_total`, `zponder_projection_errors_total`, and `zponder_dead_letters`.

### `GET /schema`

Returns JSON metadata describing available REST endpoints and configured contracts.

## GraphQL API

When `[graphql].enabled = true`, the GraphQL server listens on `[graphql].port` (default `8081`).

- `POST /graphql` — query execution
- `GET /graphql/playground` — interactive GraphQL IDE (when `enable_playground = true`)
- `GET /health` and `GET /ready` — health probes
- `GET /graphql/metrics` — GraphQL server metrics

### Schema

```text
type Query {
  health: String!
  version: String!
  contracts: [Contract!]!
  contract(name: String!): Contract
  syncStates: [SyncState!]!
  latestEvents(
    contract: String!
    event: String!
    limit: Int = 10
    offset: Int = 0
    blockFrom: Int
    blockTo: Int
    address: String
  ): [Event!]
  contractCall(
    contract: String!
    method: String!
    args: [String!]
    blockNumber: Int
  ): String
}

type Subscription {
  newBlocks: Int!
}

type Contract {
  name: String!
  address: String!
  chain: String!
  fromBlock: Int!
  events: [String!]!
}

enum IndexerStatus {
  RUNNING
  STOPPED
  ERROR
  REPLAYING
}

type SyncState {
  contractName: String!
  currentBlock: Int!
  status: IndexerStatus!
}

type Event {
  blockNumber: Int!
  transactionHash: String!
  contractAddress: String!
  eventName: String!
  fields: [EventField!]!
}

type EventField {
  key: String!
  value: String!
}
```

### `contractCall`

`contractCall` encodes the method selector and 32-byte arguments, calls `eth_call` on the contract's address, decodes the return value using the contract ABI, and caches the result in `call_cache`.

- Scalar return types decode to decimal strings (`uint*`, signed two's-complement `int*`), `0x` addresses, `true`/`false`, or `0x` hex bytes.
- Multi-output functions, static and dynamic arrays, and Solidity `tuple` structs decode to JSON array strings (for example, `["9","0x6b17..."]` or `[["1","2"],"9"]`).
