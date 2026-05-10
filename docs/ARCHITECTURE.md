# zponder Architecture

[English](#english-architecture) | [中文](#中文架构)

---

<a name="english-architecture"></a>
## English Architecture

### Overview

zponder is a layered Ethereum event indexer. Each layer has a single responsibility and communicates through well-defined interfaces.

```
┌──────────────────────────────────────────────────────────────┐
│  API Layer    (http_server.zig + graphql.zig)                 │
│  REST API / GraphQL / Playground / CORS / Cache / Metrics     │
├──────────────────────────────────────────────────────────────┤
│  Factory Layer (factory.zig)                                  │
│  Factory event detection / Child indexer lifecycle            │
├──────────────────────────────────────────────────────────────┤
│  Indexer Layer (indexer.zig)                                  │
│  Per-contract sync loop / Reorg handling / Replay / Snapshot │
├──────────────────────────────────────────────────────────────┤
│  Ethereum Layer (eth_rpc.zig + abi.zig)                       │
│  JSON-RPC / eth_call / Retry / Circuit Breaker / ABI encode  │
├──────────────────────────────────────────────────────────────┤
│  Data Layer   (db.zig + cache.zig)                           │
│  SQLite WAL / RocksDB / PostgreSQL / LRU / Call Cache        │
├──────────────────────────────────────────────────────────────┤
│  Foundation   (config.zig + log.zig)                          │
│  TOML Config / Structured Logging                            │
└──────────────────────────────────────────────────────────────┘
```

---

### Module Details

#### 1. Config (`config.zig`)

- Parses `config.toml` with a minimal TOML parser
- Validates all required fields (RPC URL, contracts, events, etc.)
- Provides default values for optional fields
- Separates parsing from validation for testability

#### 2. Log (`log.zig`)

- Thread-safe with a spinlock mutex
- Outputs to stderr and optional log file
- Supports text format (default) and JSON format (`setJsonFormat`)
- JSON format escapes special characters properly
- Gracefully no-ops if uninitialized (safe for tests)

#### 3. ETH RPC (`eth_rpc.zig`)

- Built on `std.http.Client` with `std.Io` async I/O
- **Retry**: exponential backoff (500ms × 2^attempt, capped at 16s)
- **Circuit Breaker**: 5 consecutive failures → OPEN for 30s
- **Half-Open**: one trial request after timeout; closes on success, re-opens on failure
- Parses JSON-RPC errors and returns `error.RpcError`
- Methods:
  - `getBlockNumber()` — eth_blockNumber → u64
  - `getBlockHash(block_number)` — eth_getBlockByNumber → block hash
  - `getBlockData(block_number)` — eth_getBlockByNumber → full block metadata (timestamp, miner, gas, etc.)
  - `getLogs(filter)` — eth_getLogs → parsed log array
  - `ethCall(to, data, block_number)` — eth_call → raw hex result

#### 4. DB (`db.zig`)

- Multi-backend: SQLite, RocksDB, PostgreSQL — unified `Client` interface
- SQLite with WAL mode, foreign keys, NORMAL synchronous
- **System tables**: `sync_state`, `account_states`, `snapshots`, `raw_logs`, `block_hashes`, `blocks`, `call_cache`
- **Auto-migration**: reads ABI events and creates tables dynamically
  - Table name: `event_{contract_name}_{EventName}`
  - Columns: block_number, transaction_hash, log_index, + event fields
- **Bind safety**: all `sqlite3_bind_*` calls check return value
- **Sync state table**: stores `last_synced_block` per contract (resume support)
- **Snapshot table**: stores periodic JSON snapshots
- **blocks table**: chain-wide block metadata with UNIQUE(chain, block_number)
- **call_cache table**: eth_call result cache keyed by `{address}:{data}:{block}`
- Invalidates cache on insert
- **Block methods**: `upsertBlock`, `queryBlocks` (with from/to/limit/offset)
- **Call cache methods**: `getCachedCall`, `setCachedCall`

#### 5. Cache (`cache.zig`)

- Thread-safe with `std.atomic.Mutex`
- **LRU eviction**: `std.DoublyLinkedList` + `std.StringHashMap`
- **Dual limits**: max entries + max total bytes (default 64MB)
- **Block-aware**: cache entries include `valid_up_to` block; stale entries are rejected
- **Prefix invalidation**: `invalidate(contract, event)` removes all matching keys
- Skips entries larger than 25% of max bytes

#### 6. Indexer (`indexer.zig`)

- One thread per contract (`std.Thread.spawn`)
- **Batch sync**: fetches 500 blocks at a time
- **Resume**: reads `sync_state` table on start; falls back to `from_block`
- **Replay**: stops sync, deletes range, restarts from `from_block`
- **Snapshot**: creates JSON snapshot every `snapshot_interval` seconds
- States: `running`, `stopped`, `error`, `replaying`

#### 7. HTTP Server (`http_server.zig`)

- One accept thread + one handler thread per connection
- **Whitelist**: only configured `contract` + `event` pairs allowed
- **Caching**: checks LRU cache before DB query; writes back on miss
- **CORS**: preflight + all responses include `Access-Control-Allow-Origin`
- **Prometheus metrics**: `/metrics` returns gauge metrics
- **Dynamic JSON**: uses `std.Io.Writer.Allocating` (no fixed buffer limit)

#### 8. GraphQL (`graphql.zig`)

- Uses [zgraphql](https://github.com/chy3xyz/zgraphql) for parsing, validation, and execution
- **Compile-time schema**: generated via `zg.SchemaBuilder` from a Zig struct literal
- **Resolvers**: access `db.Client`, `eth_rpc.Client`, and indexer state through `Context` userdata
- **Rate limiting**: optional token-bucket via zgraphql's built-in `RateLimiter`
- **Server**: runs `zg.GraphQLServer.listen()` in a dedicated thread with its own `std.Io` backend
- **Shutdown coordination**: sets a shared atomic flag when server exits, triggering main loop shutdown
- Schema fields:
  - `health`, `version` — static metadata
  - `contracts`, `contract(name)` — contract list from runtime indexers
  - `syncStates` — per-contract sync progress (atomic reads on indexer state)
  - `latestEvents` — paginated DB queries with `blockFrom`, `blockTo`, `offset` filters
  - `contractCall` — eth_call with ABI encoding and result caching

#### 9. Factory (`factory.zig`)

- Manages dynamic child contract discovery from factory contracts
- **`FactoryManager`**: owns child indexer lifecycle, thread-safe child list (atomic mutex)
- **`ChildIndexer`**: heap-allocated wrapper holding an owned `ContractConfig` + `Indexer`
- **Callback pattern**: factory indexer calls `FactoryManager.onFactoryEvent` via `FactoryCallback` function pointer
- **Idempotency**: checks `sync_state` table before creating child; deduplicates in-memory
- **Safety**: validates child address format (42-char hex with `0x` prefix); enforces `max_children` limit
- **Lifecycle**: children are created from `creation_event` field match, started immediately, and stopped during shutdown via `stopChildren()`

#### 10. ABI (`abi.zig`)

- Parses ABI JSON arrays; extracts `type: "event"` entries
- Computes event signature hash with **Keccak-256** (not SHA3-256)
  - `EventName(type1,type2,...)` → 32-byte topic0
- Decodes logs: indexed params from topics[1..], non-indexed from data
- Maps ABI types to SQLite types (`address` → `TEXT`, `bool` → `INTEGER`, etc.)
- **`encodeFunctionCall`**: computes 4-byte selector + ABI-encodes arguments for eth_call
- **`decodeCallResult`**: decodes eth_call hex results (uint256 → decimal, address → 0x format, bool)

#### 11. Utils (`utils.zig`)

- `parseHexU64` / `parseHexU256`: hex string → integer
- `isValidAddress`: 42 chars, `0x` prefix, hex digits
- `toChecksumAddress`: EIP-55 checksum using Keccak-256
- `keccak256`: wrapper around `std.crypto.hash.sha3.Keccak256`

---

### Database Schema

**System Tables** (created by `migrate()`):

| Table            | Key                          | Purpose                                  |
|------------------|------------------------------|------------------------------------------|
| `sync_state`     | `UNIQUE(contract_address)`   | Per-contract sync progress               |
| `account_states` | `UNIQUE(contract, account)`  | Account balance snapshots                |
| `snapshots`      | —                            | Periodic indexer state snapshots         |
| `raw_logs`       | —                            | Dead letter queue for undecodable logs   |
| `block_hashes`   | `UNIQUE(contract, block)`    | Per-contract block hashes (reorg detect) |
| `blocks`         | `UNIQUE(chain, block_number)`| Chain-wide block metadata               |
| `call_cache`     | `UNIQUE(cache_key)`          | eth_call result cache                    |

**Event Tables** (created by `autoMigrateContract()`):
- Named `event_{contract_name}_{event_name}`
- Columns from ABI inputs + `block_number`, `tx_hash`, `log_index`, `created_at`
- `UNIQUE(tx_hash, log_index)` for idempotent inserts
- Indexes on `block_number` and `tx_hash`

**RocksDB Key Scheme**:
| Prefix | Key Pattern                               | Content      |
|--------|-------------------------------------------|--------------|
| `e:`   | `e:{contract}:{event}:{block}:{tx}:{idx}` | JSON fields  |
| `s:`   | `s:{contract_address}`                    | JSON state   |
| `h:`   | `h:{contract}:{block:0>20}`               | block hash   |
| `b:`   | `b:{chain}:{block:0>20}`                 | JSON block   |
| `c:`   | `c:{cache_key}`                           | JSON result  |

---

### Data Flow

```
config.toml ──► config.zig ──► main.zig
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              indexer.zig    http_server.zig   graphql.zig
         (per-contract)     (REST API)       (GraphQL API)
                    │              │              │
                    │              │              ▼
                    │              │        factory.zig
                    │              │     (child discovery)
                    │              │              │
            ┌───────┼──────┐       │              │
            ▼       ▼       ▼       │              │
     eth_rpc.zig  abi.zig  db.zig ◄─┼──────────────┘
   (fetch logs,  (decode,  (insert, │
    eth_call,    encode)   query,   │
    block data)            cache)   │
            │       │       │       │
            └───────┼───────┘       │
                    ▼               │
              cache.zig ◄───────────┘
          (LRU invalidation)
```

**Indexing flow**: RPC → ABI decode → DB insert → cache invalidation
**Query flow (REST)**: HTTP → whitelist check → cache lookup → DB query → JSON response
**Query flow (GraphQL)**: HTTP → parse → validate → execute resolvers → DB/RPC queries → JSON response
**Factory flow**: Indexer processes event → factory callback → extract child address → create child Indexer → start syncing

---

### Memory Model

- **GPA**: `std.heap.GeneralPurposeAllocator` in `main`
- **Per-module allocators**: each module receives the GPA and manages its own allocations
- **Cleanup convention**: `init` → `deinit`, `alloc.dupe` → `alloc.free`, `toOwnedSlice` → `deinit`
- **Test allocator**: `std.testing.allocator` catches leaks in all tests

---

### Concurrency Model

```
Main Thread
  └── Signal handler (SIGINT / SIGTERM → shutdown coordination)
  └── HTTP accept thread (REST API)
        └── handler thread per TCP connection
  └── GraphQL thread (zgraphql server with its own Io backend)
  └── Indexer thread #1 (contract A)
  ├── Indexer thread #2 (contract B)
  ├── Indexer thread #3 (factory: watches creation events)
  └── Child Indexer thread(s) (dynamically created by factory)
```

- Shared data (`cache`, `db`, `indexers`) protected by:
  - `cache.zig`: `std.atomic.Mutex` spinlock
  - `db.zig`: SQLite WAL handles read concurrency; writes are serialized by SQLite
  - `log.zig`: `std.atomic.Mutex` spinlock
- Atomic values for simple state: `std.atomic.Value(bool)`, `std.atomic.Value(u64)`, etc.

---

### Error Handling Strategy

| Layer       | Strategy                                                          |
|-------------|-------------------------------------------------------------------|
| Config      | Validation returns `error.InvalidConfig` with log messages        |
| RPC         | Retry + circuit breaker; unrecoverable → propagate error          |
| DB          | `sqlite3_*` errors mapped to Zig error unions                     |
| REST API    | 4xx for client errors, 5xx for server errors, always JSON         |
| GraphQL     | Resolver errors → field null + errors[] array; never crashes      |
| Indexer     | Log warning and continue; never crash the sync loop               |
| Factory     | Log error and skip child; factory indexer continues               |

---

<a name="中文架构"></a>
## 中文架构

### 总体概述

zponder 采用分层架构，每层职责单一，通过明确的接口通信。

```
┌──────────────────────────────────────────────────────────────┐
│  API 层     (http_server.zig + graphql.zig)                  │
│  REST API / GraphQL / Playground / CORS / 缓存 / 指标        │
├──────────────────────────────────────────────────────────────┤
│  工厂层     (factory.zig)                                    │
│  工厂事件检测 / 子索引器生命周期                             │
├──────────────────────────────────────────────────────────────┤
│  索引器层   (indexer.zig)                                    │
│  单合约同步循环 / 重组处理 / 重放 / 快照                     │
├──────────────────────────────────────────────────────────────┤
│  以太坊层   (eth_rpc.zig + abi.zig)                          │
│  JSON-RPC / eth_call / 重试 / 熔断器 / ABI 编解码            │
├──────────────────────────────────────────────────────────────┤
│  数据层     (db.zig + cache.zig)                             │
│  SQLite WAL / RocksDB / PG / LRU / 调用缓存                  │
├──────────────────────────────────────────────────────────────┤
│  基础层     (config.zig + log.zig)                            │
│  TOML 配置 / 结构化日志                                       │
└──────────────────────────────────────────────────────────────┘
```

---

### 模块详解

#### 1. 配置模块 (`config.zig`)

- 使用最小化 TOML 解析器读取 `config.toml`
- 验证所有必填字段（RPC URL、合约、事件等）
- 为可选字段提供默认值
- 解析与验证分离，便于单元测试

#### 2. 日志模块 (`log.zig`)

- 基于自旋锁的线程安全
- 同时输出到标准错误和可选日志文件
- 支持文本格式（默认）和 JSON 格式（`setJsonFormat` 切换）
- JSON 格式正确转义特殊字符
- 未初始化时安全返回（测试环境不崩溃）

#### 3. RPC 模块 (`eth_rpc.zig`)

- 基于 `std.http.Client`
- **重试机制**：指数退避（500ms × 2^attempt，上限 16s）
- **熔断器**：连续 5 次失败 → OPEN 状态 30s
- **半开状态**：超时后发送试探请求；成功则关闭，失败则重新熔断
- 解析 JSON-RPC error 字段，返回 `error.RpcError`
- 安全分配内存解析日志数组

#### 4. 数据库模块 (`db.zig`)

- SQLite WAL 模式，外键约束，NORMAL 同步级别
- **自动迁移**：读取 ABI 事件定义，动态建表
  - 表名：`event_{合约名}_{事件名}`
  - 列：block_number、transaction_hash、log_index + 事件字段
- **绑定安全**：所有 `sqlite3_bind_*` 均检查返回值
- **同步状态表**：每个合约记录 `last_synced_block`
- **快照表**：定期存储 JSON 快照
- 写入后联动缓存失效

#### 5. 缓存模块 (`cache.zig`)

- 基于 `std.atomic.Mutex` 的线程安全
- **LRU 驱逐**：`std.DoublyLinkedList` + `std.StringHashMap`
- **双上限**：最大条目数 + 最大总字节数（默认 64MB）
- **区块感知**：缓存条目含 `valid_up_to` 区块，过期自动拒绝
- **前缀失效**：`invalidate(contract, event)` 移除所有匹配键
- 超过上限 1/4 的单条数据直接跳过

#### 6. 索引器模块 (`indexer.zig`)

- 每合约一个独立线程（`std.Thread.spawn`）
- **批量同步**：每次拉取 500 个区块
- **断点续传**：启动时读取 `sync_state` 表，否则回退到 `from_block`
- **重放**：停止同步、删除范围数据、从起始区块重新同步
- **快照**：每 `snapshot_interval` 秒创建 JSON 快照
- 状态机：`running`、`stopped`、`error`、`replaying`

#### 7. HTTP 服务模块 (`http_server.zig`)

- 一个 accept 线程 + 每连接一个 handler 线程
- **白名单**：只允许已配置的 `contract` + `event` 组合
- **缓存策略**：先查 LRU 缓存，未命中再查 DB，回写缓存
- **CORS**：预检请求 + 所有响应带 `Access-Control-Allow-Origin`
- **Prometheus 指标**：`/metrics` 返回 gauge 格式指标
- **动态响应**：使用 `std.Io.Writer.Allocating`（无固定缓冲区限制）

#### 8. GraphQL 模块 (`graphql.zig`)

- 使用 [zgraphql](https://github.com/chy3xyz/zgraphql) 进行解析、验证和执行
- **编译时 Schema**：通过 `zg.SchemaBuilder` 从 Zig 结构体字面量生成
- **Resolver**：通过 `Context` 用户数据访问 `db.Client`、`eth_rpc.Client` 和索引器状态
- **速率限制**：通过 zgraphql 内置 `RateLimiter` 实现可选令牌桶
- **服务器**：在独立线程中运行 `zg.GraphQLServer.listen()`，使用自有 `std.Io` 后端
- **优雅关闭**：服务器退出时设置共享原子标志，触发主循环关闭

#### 9. 工厂模块 (`factory.zig`)

- 管理工厂合约创建的子合约的动态发现
- **`FactoryManager`**：所有权管理子索引器生命周期，线程安全的子列表（原子互斥锁）
- **`ChildIndexer`**：堆分配的包装器，持有自有 `ContractConfig` + `Indexer`
- **回调模式**：工厂索引器通过 `FactoryCallback` 函数指针调用 `FactoryManager.onFactoryEvent`
- **幂等性**：创建前检查 `sync_state` 表；内存中已存在则去重

#### 10. ABI 模块 (`abi.zig`)

- 解析 ABI JSON 数组，提取 `type: "event"` 的条目
- 使用 **Keccak-256**（非 SHA3-256）计算事件签名哈希
  - `EventName(type1,type2,...)` → 32 字节 topic0
- 解码日志：indexed 参数从 topics[1..] 取，non-indexed 从 data 取
- ABI 类型映射到 SQLite 类型（`address` → `TEXT`，`bool` → `INTEGER` 等）
- **`encodeFunctionCall`**：计算 4 字节选择器 + ABI 编码参数用于 eth_call
- **`decodeCallResult`**：解码 eth_call 十六进制结果

#### 11. 工具模块 (`utils.zig`)

- `parseHexU64` / `parseHexU256`：十六进制字符串转整数
- `isValidAddress`：42 字符、`0x` 前缀、十六进制字符
- `toChecksumAddress`：EIP-55 校验和地址（Keccak-256）
- `keccak256`：`std.crypto.hash.sha3.Keccak256` 的包装

---

### 数据流

```
config.toml ──► config.zig ──► main.zig
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              indexer.zig    http_server.zig   graphql.zig
           (单合约线程)      (REST API)       (GraphQL API)
                    │              │              │
                    │              │              ▼
                    │              │        factory.zig
                    │              │     (子合约发现)
                    │              │              │
            ┌───────┼──────┐       │              │
            ▼       ▼       ▼       │              │
     eth_rpc.zig  abi.zig  db.zig ◄─┼──────────────┘
   (拉取日志,   (解码,    (写入, │
    eth_call,    编码)    查询,    │
    区块数据)            缓存)     │
            │       │       │       │
            └───────┼───────┘       │
                    ▼               │
              cache.zig ◄───────────┘
           (LRU 缓存失效)
```

**索引流程**：RPC → ABI 解码 → 数据库写入 → 缓存失效
**REST 查询流程**：HTTP → 白名单检查 → 缓存查找 → 数据库查询 → JSON 响应
**GraphQL 查询流程**：HTTP → 解析 → 验证 → 执行 resolver → 数据库/RPC 查询 → JSON 响应
**工厂流程**：索引器处理事件 → 工厂回调 → 提取子地址 → 创建子索引器 → 开始同步

---

### 内存模型

- **GPA**：`main` 中使用 `std.heap.GeneralPurposeAllocator`
- **各模块分配器**：每个模块接收 GPA，自行管理内存
- **清理约定**：`init` → `deinit`，`alloc.dupe` → `alloc.free`，`toOwnedSlice` → `deinit`
- **测试分配器**：`std.testing.allocator` 捕获所有内存泄漏

---

### 并发模型

```
主线程
  └── 信号处理器 (SIGINT / SIGTERM → 关闭协调)
  └── HTTP accept 线程 (REST API)
        └── 每 TCP 连接一个 handler 线程
  └── GraphQL 线程 (zgraphql 服务器，独立 Io 后端)
  └── 索引器线程 #1 (合约 A)
  ├── 索引器线程 #2 (合约 B)
  ├── 索引器线程 #3 (工厂：监听创建事件)
  └── 子索引器线程 (由工厂动态创建)
```

- 共享数据（`cache`、`db`、`indexers`）的保护机制：
  - `cache.zig`：`std.atomic.Mutex` 自旋锁
  - `db.zig`：SQLite WAL 处理读并发；写入由 SQLite 内部串行化
  - `log.zig`：`std.atomic.Mutex` 自旋锁
- 简单状态使用原子值：`std.atomic.Value(bool)`、`std.atomic.Value(u64)` 等

---

### 错误处理策略

| 层级       | 策略                                                      |
|------------|-----------------------------------------------------------|
| 配置       | 验证返回 `error.InvalidConfig` 并打印日志                    |
| RPC        | 重试 + 熔断；不可恢复时向上传播错误                          |
| 数据库     | `sqlite3_*` 错误映射为 Zig 错误联合类型                     |
| REST API   | 4xx 客户端错误，5xx 服务端错误，始终返回 JSON                |
| GraphQL    | Resolver 错误 → 字段为 null + errors[] 数组；永不崩溃        |
| 索引器     | 打印警告并继续；同步循环永不崩溃                            |
| 工厂       | 打印错误并跳过子合约；工厂索引器继续运行                     |
