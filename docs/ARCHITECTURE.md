# zponder Architecture

[English](#english-architecture) | [中文](#中文架构)

---

<a name="english-architecture"></a>
## English Architecture

### Overview

zponder is a layered Ethereum event indexer. Each layer has a single responsibility and communicates through well-defined interfaces.

```
┌─────────────────────────────────────────────┐
│  HTTP Layer   (http_server.zig)             │
│  REST API / CORS / Cache / Metrics          │
├─────────────────────────────────────────────┤
│  Indexer Layer (indexer.zig)                │
│  Per-contract sync loop / Replay / Snapshot │
├─────────────────────────────────────────────┤
│  Ethereum Layer (eth_rpc.zig + abi.zig)     │
│  JSON-RPC / Retry / Circuit Breaker / ABI   │
├─────────────────────────────────────────────┤
│  Data Layer   (db.zig + cache.zig)          │
│  SQLite WAL / Auto-migration / LRU Cache    │
├─────────────────────────────────────────────┤
│  Foundation   (config.zig + log.zig)        │
│  TOML Config / Structured Logging           │
└─────────────────────────────────────────────┘
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

- Built on `std.http.Client`
- **Retry**: exponential backoff (500ms × 2^attempt, capped at 16s)
- **Circuit Breaker**: 5 consecutive failures → OPEN for 30s
- **Half-Open**: one trial request after timeout; closes on success, re-opens on failure
- Parses JSON-RPC errors and returns `error.RpcError`
- Parses log arrays with memory-safe allocation

#### 4. DB (`db.zig`)

- SQLite with WAL mode, foreign keys, NORMAL synchronous
- **Auto-migration**: reads ABI events and creates tables dynamically
  - Table name: `event_{contract_name}_{EventName}`
  - Columns: block_number, transaction_hash, log_index, + event fields
- **Bind safety**: all `sqlite3_bind_*` calls check return value
- **Sync state table**: stores `last_synced_block` per contract
- **Snapshot table**: stores periodic JSON snapshots
- Invalidates cache on insert

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

#### 8. ABI (`abi.zig`)

- Parses ABI JSON arrays; extracts `type: "event"` entries
- Computes event signature hash with **Keccak-256** (not SHA3-256)
  - `EventName(type1,type2,...)` → 32-byte topic0
- Decodes logs: indexed params from topics[1..], non-indexed from data
- Maps ABI types to SQLite types (`address` → `TEXT`, `bool` → `INTEGER`, etc.)

#### 9. Utils (`utils.zig`)

- `parseHexU64` / `parseHexU256`: hex string → integer
- `isValidAddress`: 42 chars, `0x` prefix, hex digits
- `toChecksumAddress`: EIP-55 checksum using Keccak-256
- `keccak256`: wrapper around `std.crypto.hash.sha3.Keccak256`

---

### Data Flow

```
config.toml ──► config.zig ──► main.zig
                                   │
                                   ▼
                    ┌────────────────────────────┐
                    │      indexer.zig           │
                    │  (per-contract thread)     │
                    └────────────┬───────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            ▼                    ▼                    ▼
     eth_rpc.zig          abi.zig               db.zig
   (fetch logs)      (decode events)      (insert / query)
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 ▼
                          cache.zig
                      (invalidate / put)
                                 │
                                 ▼
                    http_server.zig
                 (GET /events → cache → db)
```

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
  └── Signal handler (SIGINT / SIGTERM → g_running = false)
  └── HTTP accept thread
        └── handler thread per TCP connection
  └── Indexer thread #1 (contract A)
  └── Indexer thread #2 (contract B)
  └── ...
```

- Shared data (`cache`, `db`, `indexers`) protected by:
  - `cache.zig`: `std.atomic.Mutex` spinlock
  - `db.zig`: SQLite WAL handles read concurrency; writes are serialized by SQLite
  - `log.zig`: `std.atomic.Mutex` spinlock
- Atomic values for simple state: `std.atomic.Value(bool)`, `std.atomic.Value(u64)`, etc.

---

### Error Handling Strategy

| Layer | Strategy |
|-------|----------|
| Config | Validation returns `error.InvalidConfig` with log messages |
| RPC | Retry + circuit breaker; unrecoverable → propagate error |
| DB | `sqlite3_*` errors mapped to Zig error unions |
| HTTP | 4xx for client errors, 5xx for server errors, always JSON |
| Indexer | Log warning and continue; never crash the sync loop |

---

<a name="中文架构"></a>
## 中文架构

### 总体概述

zponder 采用分层架构，每层职责单一，通过明确的接口通信。

```
┌─────────────────────────────────────────────┐
│  HTTP 层   (http_server.zig)                │
│  REST API / CORS / 缓存 / 指标              │
├─────────────────────────────────────────────┤
│  索引器层 (indexer.zig)                     │
│  单合约同步循环 / 重放 / 快照               │
├─────────────────────────────────────────────┤
│  以太坊层 (eth_rpc.zig + abi.zig)           │
│  JSON-RPC / 重试 / 熔断器 / ABI 解析        │
├─────────────────────────────────────────────┤
│  数据层   (db.zig + cache.zig)              │
│  SQLite WAL / 自动迁移 / LRU 缓存           │
├─────────────────────────────────────────────┤
│  基础层   (config.zig + log.zig)            │
│  TOML 配置 / 结构化日志                     │
└─────────────────────────────────────────────┘
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

#### 8. ABI 模块 (`abi.zig`)

- 解析 ABI JSON 数组，提取 `type: "event"` 的条目
- 使用 **Keccak-256**（非 SHA3-256）计算事件签名哈希
  - `EventName(type1,type2,...)` → 32 字节 topic0
- 解码日志：indexed 参数从 topics[1..] 取，non-indexed 从 data 取
- ABI 类型映射到 SQLite 类型（`address` → `TEXT`，`bool` → `INTEGER` 等）

#### 9. 工具模块 (`utils.zig`)

- `parseHexU64` / `parseHexU256`：十六进制字符串转整数
- `isValidAddress`：42 字符、`0x` 前缀、十六进制字符
- `toChecksumAddress`：EIP-55 校验和地址（Keccak-256）
- `keccak256`：`std.crypto.hash.sha3.Keccak256` 的包装

---

### 数据流

```
config.toml ──► config.zig ──► main.zig
                                   │
                                   ▼
                    ┌────────────────────────────┐
                    │      indexer.zig           │
                    │  (per-contract thread)     │
                    └────────────┬───────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            ▼                    ▼                    ▼
     eth_rpc.zig          abi.zig               db.zig
   (拉取日志)          (解码事件)            (写入 / 查询)
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 ▼
                          cache.zig
                      (失效 / 写入)
                                 │
                                 ▼
                    http_server.zig
              (GET /events → 缓存 → 数据库)
```

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
  └── 信号处理器 (SIGINT / SIGTERM → g_running = false)
  └── HTTP accept 线程
        └── 每 TCP 连接一个 handler 线程
  └── 索引器线程 #1 (合约 A)
  └── 索引器线程 #2 (合约 B)
  └── ...
```

- 共享数据（`cache`、`db`、`indexers`）的保护机制：
  - `cache.zig`：`std.atomic.Mutex` 自旋锁
  - `db.zig`：SQLite WAL 处理读并发；写入由 SQLite 内部串行化
  - `log.zig`：`std.atomic.Mutex` 自旋锁
- 简单状态使用原子值：`std.atomic.Value(bool)`、`std.atomic.Value(u64)` 等

---

### 错误处理策略

| 层级 | 策略 |
|------|------|
| 配置 | 验证返回 `error.InvalidConfig` 并打印日志 |
| RPC | 重试 + 熔断；不可恢复时向上传播错误 |
| 数据库 | `sqlite3_*` 错误映射为 Zig 错误联合类型 |
| HTTP | 4xx 客户端错误，5xx 服务端错误，始终返回 JSON |
| 索引器 | 打印警告并继续；同步循环永不崩溃 |
