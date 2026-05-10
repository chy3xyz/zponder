# zponder HTTP API Documentation

[English](#english-api-reference) | [中文](#中文-api-参考)

---

<a name="english-api-reference"></a>
## English API Reference

Base URL: `http://localhost:8080` (configurable via `config.toml`)

All responses include CORS headers (`Access-Control-Allow-Origin: *`).

---

### `GET /health`

Health check with indexer and cache status.

**Response:**
```json
{
  "status": "ok",
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

---

### `GET /version`

Version information.

**Response:**
```json
{
  "version": "0.1.0",
  "commit": "a1b2c3d",
  "zig_version": "0.16.0"
}
```

---

### `GET /sync_state`

Sync state for all configured contracts.

**Response:**
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

Status values: `running`, `stopped`, `error`, `replaying`.

---

### `GET /contracts`

List of configured contracts.

**Response:**
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

---

### `GET /events/:contract/:event`

Query event logs with optional filters.

**Path Parameters:**
- `contract` — contract name (as configured in `config.toml`)
- `event` — event name (must be in the contract's `events` list)

**Query Parameters:**
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `block_from` | integer | — | Start block (inclusive) |
| `block_to` | integer | — | End block (inclusive) |
| `tx_hash` | string | — | Filter by transaction hash |
| `limit` | integer | 100 | Max results (max 1000) |
| `offset` | integer | 0 | Pagination offset |
| `order` | string | `desc` | Sort order: `asc` or `desc` |

**Response:**
```json
[
  {
    "block_number": 20000001,
    "transaction_hash": "0xabc...",
    "log_index": 0,
    "from": "0x1111...",
    "to": "0x2222...",
    "value": "1000000000000000000"
  }
]
```

**Notes:**
- Results are cached in memory (LRU). Cache is invalidated on new block insert.
- Only configured `contract` + `event` pairs are allowed (whitelist check).

---

### `GET /cache/stats`

Cache statistics.

**Response:**
```json
{
  "cached_entries": 42,
  "total_bytes": 16384
}
```

---

### `GET /metrics`

Prometheus-compatible metrics.

**Response:** (text/plain)
```
# HELP zponder_cache_entries Cache entry count
# TYPE zponder_cache_entries gauge
zponder_cache_entries 42
# HELP zponder_cache_bytes Cache size in bytes
# TYPE zponder_cache_bytes gauge
zponder_cache_bytes 16384
# HELP zponder_indexers Number of indexers
# TYPE zponder_indexers gauge
zponder_indexers 2
# HELP zponder_indexer_current_block Current block per indexer
# TYPE zponder_indexer_current_block gauge
zponder_indexer_current_block{contract="dai"} 20123456
# HELP zponder_indexer_status Indexer status code
# TYPE zponder_indexer_status gauge
zponder_indexer_status{contract="dai"} 1
```

Status codes: `1 = running`, `0 = stopped`, `2 = error`, `3 = replaying`.

---

### `GET /schema`

Auto-generated API documentation.

**Response:**
```json
{
  "endpoints": [...],
  "contracts": [...]
}
```

---

### `POST /replay`

Replay a block range for a contract.

**Query Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `contract` | string | yes | Contract name |
| `from_block` | integer | yes | Start block |
| `to_block` | integer | yes | End block |

**Response:**
```json
{ "status": "replaying" }
```

**Notes:**
- The indexer stops current sync, deletes events in the range, and re-syncs.
- Returns error if contract not found.

---

### `OPTIONS /*`

CORS preflight. Returns `204 No Content` with CORS headers.

---

## GraphQL API Reference

When `[graphql].enabled = true`, a GraphQL server is available at the configured port (default `8081`).

**Endpoint:** `POST /graphql`
**Playground:** `GET /graphql/playground` (when `enable_playground = true`)
**Health:** `GET /health`
**Ready:** `GET /ready`
**Metrics:** `GET /graphql/metrics`

---

### Query Fields

#### `health`

Returns server health status.

```graphql
query { health }
```

**Response:** `{ "data": { "health": "ok" } }`

---

#### `version`

Returns version and git commit.

```graphql
query { version }
```

**Response:** `{ "data": { "version": "0.1.0 (a1b2c3d)" } }`

---

#### `contracts`

Returns all configured contracts with metadata.

```graphql
query {
  contracts {
    name
    address
    chain
    fromBlock
    events
  }
}
```

**Response:**
```json
{
  "data": {
    "contracts": [
      {
        "name": "dai",
        "address": "0x6b175474e89094c44da98b954eedeac495271d0f",
        "chain": "ethereum",
        "fromBlock": 20000000,
        "events": ["Transfer", "Approval"]
      }
    ]
  }
}
```

---

#### `contract(name: String!)`

Returns a single contract by name. Returns `null` if not found.

```graphql
query {
  contract(name: "dai") {
    address
    fromBlock
  }
}
```

---

#### `syncStates`

Returns sync status for all configured contracts.

```graphql
query {
  syncStates {
    contractName
    currentBlock
    status
  }
}
```

Status values (enum `IndexerStatus`): `RUNNING`, `STOPPED`, `ERROR`, `REPLAYING`.

---

#### `latestEvents`

Paginated event log queries with optional block-range filters.

**Arguments:**

| Arg          | Type     | Default | Description                          |
|--------------|----------|---------|--------------------------------------|
| `contract`   | String!  | —       | Contract name (required)             |
| `event`      | String!  | —       | Event name (required)                |
| `limit`      | Int      | 10      | Max results (clamped to 1–1000)      |
| `offset`     | Int      | 0       | Pagination offset                    |
| `blockFrom`  | Int      | null    | Start block filter (inclusive)       |
| `blockTo`    | Int      | null    | End block filter (inclusive)         |

**Example:**

```graphql
query {
  latestEvents(contract: "dai", event: "Transfer", limit: 5, blockFrom: 20000000) {
    blockNumber
    transactionHash
    eventName
    fields {
      key
      value
    }
  }
}
```

**Response:**
```json
{
  "data": {
    "latestEvents": [
      {
        "blockNumber": 20000001,
        "transactionHash": "0xabc123...",
        "eventName": "Transfer",
        "fields": [
          { "key": "from", "value": "0x1111..." },
          { "key": "to", "value": "0x2222..." },
          { "key": "value", "value": "1000000000000000000" }
        ]
      }
    ]
  }
}
```

**Notes:**
- The `fields` array contains all event parameters as key-value string pairs.
- Contract name and event name are validated against alphanumeric + underscore characters (SQL injection prevention).
- Returns `null` (and errors in `errors[]`) on database query failure.
- Validator enforces argument types before resolver execution.

---

#### `contractCall`

Calls a contract method via `eth_call` at a specific block height. Results are cached.

**Arguments:**

| Arg           | Type     | Default | Description                              |
|---------------|----------|---------|------------------------------------------|
| `contract`    | String!  | —       | Contract name (required)                 |
| `method`      | String!  | —       | Method signature, e.g. `balanceOf(address)` |
| `args`        | [String!]| —       | Hex-encoded arguments (optional)         |
| `blockNumber` | Int      | null    | Block height (null = latest)             |

**Example:**

```graphql
query {
  contractCall(
    contract: "dai"
    method: "balanceOf(address)"
    args: ["0x6B175474E89094C44Da98b954EedeAC495271d0F"]
  )
}
```

```graphql
query {
  contractCall(
    contract: "dai"
    method: "totalSupply()"
    blockNumber: 20000000
  )
}
```

**Notes:**
- Method signature format: `functionName(type1,type2,...)`. Only alphanumeric + parens + commas + underscores allowed.
- Arguments must be hex-encoded (0x-prefixed), left-padded to 64 chars per argument.
- Results are cached in the `call_cache` table keyed by `{contract_address}:{call_data}:{block_number}`.
- Returns the decoded result as a string (uint256 → decimal, address → 0x format, bool → "true"/"false").
- Returns `null` if the contract is not found, method signature is invalid, or the RPC call fails.

---

### GraphQL Types

```graphql
type Query {
  health: String!
  version: String!
  contracts: [Contract!]!
  contract(name: String!): Contract
  syncStates: [SyncState!]!
  latestEvents(
    contract: String!,
    event: String!,
    limit: Int = 10,
    offset: Int = 0,
    blockFrom: Int,
    blockTo: Int
  ): [Event!]
  contractCall(
    contract: String!,
    method: String!,
    args: [String!],
    blockNumber: Int
  ): String
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
  eventName: String!
  fields: [EventField!]!
}

type EventField {
  key: String!
  value: String!
}
```

---

### Rate Limiting

When `rate_limit_rps` is configured, the GraphQL server enforces a token-bucket rate limit per client IP. Exceeding the limit returns:

```json
{
  "errors": [{ "message": "Rate limit exceeded" }]
}
```

HTTP status: `429 Too Many Requests`.

---

<a name="中文-api-参考"></a>
## 中文 API 参考

基础 URL: `http://localhost:8080`（可通过 `config.toml` 配置）

所有响应均包含 CORS 头（`Access-Control-Allow-Origin: *`）。

---

### `GET /health`

健康检查，返回索引器和缓存状态。

**响应示例：**
```json
{
  "status": "ok",
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

---

### `GET /version`

版本信息。

**响应示例：**
```json
{
  "version": "0.1.0",
  "commit": "a1b2c3d",
  "zig_version": "0.16.0"
}
```

---

### `GET /sync_state`

所有配置合约的同步状态。

**响应示例：**
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

状态值：`running`（运行中）、`stopped`（已停止）、`error`（错误）、`replaying`（重放中）。

---

### `GET /contracts`

已配置的合约列表。

**响应示例：**
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

---

### `GET /events/:contract/:event`

查询事件日志，支持过滤条件。

**路径参数：**
- `contract` — 合约名称（与 `config.toml` 中配置一致）
- `event` — 事件名称（必须在合约的 `events` 列表中）

**查询参数：**
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `block_from` | 整数 | — | 起始区块（含） |
| `block_to` | 整数 | — | 结束区块（含） |
| `tx_hash` | 字符串 | — | 按交易哈希过滤 |
| `limit` | 整数 | 100 | 最大返回条数（上限 1000） |
| `offset` | 整数 | 0 | 分页偏移 |
| `order` | 字符串 | `desc` | 排序方向：`asc` 或 `desc` |

**响应示例：**
```json
[
  {
    "block_number": 20000001,
    "transaction_hash": "0xabc...",
    "log_index": 0,
    "from": "0x1111...",
    "to": "0x2222...",
    "value": "1000000000000000000"
  }
]
```

**说明：**
- 结果缓存在内存（LRU），新块写入时自动失效。
- 只允许查询已配置的 `contract` + `event` 组合（白名单校验）。

---

### `GET /cache/stats`

缓存统计。

**响应示例：**
```json
{
  "cached_entries": 42,
  "total_bytes": 16384
}
```

---

### `GET /metrics`

Prometheus 兼容指标。

**响应示例：**（text/plain）
```
# HELP zponder_cache_entries 缓存条目数
# TYPE zponder_cache_entries gauge
zponder_cache_entries 42
# HELP zponder_cache_bytes 缓存占用字节数
# TYPE zponder_cache_bytes gauge
zponder_cache_bytes 16384
# HELP zponder_indexers 索引器数量
# TYPE zponder_indexers gauge
zponder_indexers 2
# HELP zponder_indexer_current_block 索引器当前区块
# TYPE zponder_indexer_current_block gauge
zponder_indexer_current_block{contract="dai"} 20123456
# HELP zponder_indexer_status 索引器状态码
# TYPE zponder_indexer_status gauge
zponder_indexer_status{contract="dai"} 1
```

状态码：`1 = running`，`0 = stopped`，`2 = error`，`3 = replaying`。

---

### `GET /schema`

自动生成的 API 文档。

**响应示例：**
```json
{
  "endpoints": [...],
  "contracts": [...]
}
```

---

### `POST /replay`

对指定合约重放区块范围。

**查询参数：**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `contract` | 字符串 | 是 | 合约名称 |
| `from_block` | 整数 | 是 | 起始区块 |
| `to_block` | 整数 | 是 | 结束区块 |

**响应示例：**
```json
{ "status": "replaying" }
```

**说明：**
- 索引器会停止当前同步，删除指定范围内的已有事件，然后重新同步。
- 合约不存在时返回错误。

---

### `OPTIONS /*`

CORS 预检请求。返回 `204 No Content` 及 CORS 响应头。
