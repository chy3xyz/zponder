# zponder

[English](#english) | [中文](#中文)

---

<a name="english"></a>
## English

A production-grade Ethereum event indexer written in Zig, inspired by [Ponder](https://ponder.sh).

### Features

- **High Performance**: Zero-cost abstractions, no GC, native speed
- **Lightweight**: Static binary (< 2MB with SQLite), zero runtime dependencies
- **Multi-contract**: Parallel indexing with per-contract threads
- **Resume Support**: Auto-resumes from last synced block on restart
- **SQLite Persistence**: WAL mode for concurrent read/write safety
- **HTTP Query API**: RESTful endpoints with cache, CORS, and Prometheus metrics
- **Circuit Breaker**: Exponential backoff and circuit breaker for RPC resilience
- **LRU Cache**: Memory-bounded query cache with LRU eviction
- **ABI Auto-migration**: Creates event tables dynamically from contract ABI
- **JSON / Text Logging**: Structured JSON or human-readable log output

### Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Zig 0.16.0+ |
| Storage | SQLite (system library) |
| HTTP Server | `std.http.Server` + per-connection threads |
| RPC Client | Custom JSON-RPC with retry & circuit breaker |
| Build | `build.zig` + `build.zig.zon` |

### Project Structure

```
zponder/
├── src/
│   ├── main.zig          # Entry point: signal handling, module coordination
│   ├── config.zig        # TOML config parser with validation
│   ├── log.zig           # Structured logging (JSON/text, file+stderr)
│   ├── eth_rpc.zig       # JSON-RPC client: retry, circuit breaker, log parsing
│   ├── db.zig            # SQLite client: WAL, auto-migration, bind checks
│   ├── indexer.zig       # Per-contract sync loop, replay, snapshot
│   ├── http_server.zig   # HTTP API: routing, CORS, cache, metrics
│   ├── abi.zig           # ABI JSON parsing, event signature (Keccak-256), log decode
│   ├── cache.zig         # Thread-safe LRU cache with byte limit
│   └── utils.zig         # Hex parsing, address validation, EIP-55 checksum
├── abis/                 # Contract ABI JSON files
├── config.toml           # Runtime configuration
├── build.zig             # Build script (embeds git commit)
└── README.md
```

### Quick Start

#### 1. Build

```bash
zig build
```

#### 2. Configure

Edit `config.toml`:

```toml
[global]
log_level = "info"
log_file = "./logs/indexer.log"
snapshot_interval = 3600

[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
timeout = 10000
retry_count = 3

[database]
type = "sqlite"
db_name = "eth_indexer.db"

[http]
port = 8080
host = "0.0.0.0"

[[contracts]]
name = "dai"
address = "0x6b175474e89094c44da98b954eedeac495271d0f"
abi_path = "./abis/erc20.abi"
from_block = 20000000
events = ["Transfer", "Approval"]
```

#### 3. Run

```bash
zig build run -- -c config.toml
# or
./zig-out/bin/zponder -c config.toml
```

#### 4. HTTP API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check + indexer & cache status |
| `/version` | GET | Version, git commit, Zig version |
| `/sync_state` | GET | All contract sync states |
| `/contracts` | GET | Configured contract list |
| `/events/:contract/:event` | GET | Query event logs with filters |
| `/cache/stats` | GET | Cache entry count & bytes |
| `/metrics` | GET | Prometheus-compatible metrics |
| `/schema` | GET | Auto-generated API documentation |
| `/balance/:contract/:account` | GET | Query account balance for a contract |
| `/replay` | POST | Replay a block range for a contract |

Query parameters for `/events/:contract/:event`:
- `block_from` — start block (optional)
- `block_to` — end block (optional)
- `tx_hash` — filter by transaction hash (optional)
- `limit` — max results, default 100, max 1000 (optional)
- `offset` — pagination offset (optional)
- `order` — `asc` or `desc`, default `desc` (optional)

#### 5. Tests

```bash
zig build test
```

#### 6. Production Build

```bash
zig build -Doptimize=ReleaseFast
```

### Development Notes

- All modules expose `init` / `deinit` lifecycle methods
- Errors use Zig error unions; no panics on recoverable failures
- SQLite uses parameterized statements (all `sqlite3_bind_*` checked)
- Log levels: DEBUG / INFO / WARN / ERROR
- JSON log format: `log.setJsonFormat(true)`

---

<a name="中文"></a>
## 中文

基于 Zig 语言开发的生产级以太坊事件索引器，灵感来自 [Ponder](https://ponder.sh)。

### 核心特性

- **高性能**：零开销抽象、无 GC、原生执行速度
- **轻量部署**：静态编译单二进制文件（< 2MB），零运行时依赖
- **多合约并行**：每个合约独立线程处理，提升索引效率
- **断点续传**：重启后自动从上次同步区块恢复
- **SQLite 持久化**：WAL 模式保障并发读写安全
- **HTTP 查询 API**：RESTful 接口，支持缓存、CORS、Prometheus 指标
- **熔断器机制**：指数退避 + 熔断器保障 RPC 调用韧性
- **LRU 缓存**：带内存上限的线程安全查询缓存
- **ABI 自动建表**：根据合约 ABI 动态创建事件数据表
- **JSON / 文本日志**：结构化 JSON 或人类可读日志输出

### 技术栈

| 层级 | 技术选型 |
|------|---------|
| 主语言 | Zig 0.16.0+ |
| 持久化 | SQLite（系统库） |
| HTTP 服务 | `std.http.Server` + 每连接独立线程 |
| RPC 客户端 | 自定义 JSON-RPC（重试 + 熔断） |
| 构建系统 | `build.zig` + `build.zig.zon` |

### 项目结构

```
zponder/
├── src/
│   ├── main.zig          # 入口：信号处理、模块协调
│   ├── config.zig        # TOML 配置解析 + 验证
│   ├── log.zig           # 结构化日志（JSON/文本、文件+标准错误）
│   ├── eth_rpc.zig       # JSON-RPC 客户端：重试、熔断、日志解析
│   ├── db.zig            # SQLite 客户端：WAL、自动迁移、参数绑定检查
│   ├── indexer.zig       # 单合约同步循环、重放、快照
│   ├── http_server.zig   # HTTP API：路由、CORS、缓存、指标
│   ├── abi.zig           # ABI JSON 解析、事件签名（Keccak-256）、日志解码
│   ├── cache.zig         # 线程安全 LRU 缓存（带字节上限）
│   └── utils.zig         # 十六进制解析、地址校验、EIP-55 校验和
├── abis/                 # 合约 ABI 文件
├── config.toml           # 运行时配置
├── build.zig             # 构建脚本（嵌入 git commit）
└── README.md
```

### 快速开始

#### 1. 构建

```bash
zig build
```

#### 2. 配置

编辑 `config.toml`：

```toml
[global]
log_level = "info"
log_file = "./logs/indexer.log"
snapshot_interval = 3600

[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
timeout = 10000
retry_count = 3

[database]
type = "sqlite"
db_name = "eth_indexer.db"

[http]
port = 8080
host = "0.0.0.0"

[[contracts]]
name = "dai"
address = "0x6b175474e89094c44da98b954eedeac495271d0f"
abi_path = "./abis/erc20.abi"
from_block = 20000000
events = ["Transfer", "Approval"]
```

#### 3. 运行

```bash
zig build run -- -c config.toml
# 或
./zig-out/bin/zponder -c config.toml
```

#### 4. HTTP API

| 端点 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 + 索引器与缓存状态 |
| `/version` | GET | 版本、git commit、Zig 版本 |
| `/sync_state` | GET | 所有合约同步状态 |
| `/contracts` | GET | 已配置合约列表 |
| `/events/:contract/:event` | GET | 带过滤条件查询事件日志 |
| `/cache/stats` | GET | 缓存条目数与字节数 |
| `/metrics` | GET | Prometheus 兼容指标 |
| `/schema` | GET | 自动生成的 API 文档 |
| `/balance/:contract/:account` | GET | 查询指定合约的账户余额 |
| `/replay` | POST | 对指定合约重放区块范围 |

`/events/:contract/:event` 查询参数：
- `block_from` — 起始区块（可选）
- `block_to` — 结束区块（可选）
- `tx_hash` — 按交易哈希过滤（可选）
- `limit` — 最大返回条数，默认 100，上限 1000（可选）
- `offset` — 分页偏移（可选）
- `order` — `asc` 或 `desc`，默认 `desc`（可选）

#### 5. 测试

```bash
zig build test
```

#### 6. 生产构建

```bash
zig build -Doptimize=ReleaseFast
```

### 开发约定

- 所有模块提供 `init` / `deinit` 生命周期管理
- 错误处理使用 Zig 错误联合类型，可恢复故障不 panic
- SQLite 使用参数化语句（所有 `sqlite3_bind_*` 返回值均已检查）
- 日志分级：DEBUG / INFO / WARN / ERROR
- JSON 日志格式切换：`log.setJsonFormat(true)`
