# AGENTS.md — zponder 项目指南

> 本文档面向 AI 编程助手，用于快速了解项目现状、技术选型与开发约定。

---

## 项目概述

**zponder** 是一个基于 Zig 语言开发的生产级以太坊事件索引器，功能对标 TypeScript 生态的 [Ponder](https://ponder.sh)。项目目前处于**极早期/设计阶段**，仓库中仅包含设计文档，尚未创建源代码、构建脚本或测试文件。

核心目标：利用 Zig 的零开销抽象、无 GC、静态编译等特性，打造「轻量、高速、安全、可扩展」的链上数据索引服务，解决 Ponder 在性能、内存占用与部署复杂度上的痛点。

---

## 当前项目状态

| 检查项 | 状态 |
|--------|------|
| `build.zig` | ❌ 不存在 |
| `src/` 源码目录 | ❌ 不存在 |
| 配置文件（`config.toml` 等） | ❌ 不存在 |
| 测试文件 | ❌ 不存在 |
| CI/CD 脚本 | ❌ 不存在 |
| 设计文档 | ✅ `docs/dev.md`（中文，364 行，末尾截断） |
| `README.md` | ❌ 不存在 |

### 唯一现有文件

- `docs/dev.md` — 完整的产品需求与架构设计文档，涵盖：
  - 技术栈选型（Zig 0.16.0 + eth.zig + PostgreSQL/SQLite）
  - 五层架构设计（基础层 → 数据层 → 以太坊层 → 核心业务层 → 接口层）
  - 数据模型（`sync_state`、`events`、`account_states`、`snapshots`）
  - 核心流程（启动、同步、重放、故障自愈）
  -  planned 项目结构（见下方「计划中的目录结构」）
  - 示例 `config.toml` 配置
  - 部分 `main.zig` 入口代码（文档末尾截断，未完结）

> **注意**：`docs/dev.md` 末尾在 `main.zig` 的协程启动代码处中断（`const thread = try`），文档本身不完整。

---

## 计划中的技术栈

| 领域 | 选型 | 说明 |
|------|------|------|
| 主语言 | Zig 0.16.0+ | 零开销抽象、无 GC、手动内存管理、静态编译 |
| 以太坊交互 | [eth.zig](https://github.com/rafaelrcamargo/eth.zig)（最新版） | 纯 Zig 实现，支持 RPC、ABI 编解码、日志过滤 |
| 主存储 | PostgreSQL | 高并发、事务、索引优化，适配生产环境 |
| 轻量存储备选 | SQLite | 单机/开发环境快速部署 |
| HTTP 服务 | Zig `std.http` 或 `zig-http` | 原生异步 I/O，无额外依赖 |
| 日志 | Zig `std.log` + 文件持久化 | 支持 DEBUG/INFO/WARN/ERROR 分级 |
| 监控（可选） | Prometheus | 指标采集（同步进度、QPS 等） |
| 部署 | 单二进制文件 + Docker | 静态编译后 < 1MB，零依赖运行 |

---

## 计划中的目录结构

根据 `docs/dev.md`，项目应组织如下：

```
zponder/
├── src/
│   ├── main.zig          # 入口：启动索引器、协调各模块
│   ├── config.zig        # 配置管理（TOML 解析、全局配置访问）
│   ├── log.zig           # 日志模块（分级、格式化、文件轮转）
│   ├── eth_rpc.zig       # 以太坊 RPC 客户端（基于 eth.zig 封装）
│   ├── db.zig            # 数据库客户端（PostgreSQL/SQLite 抽象）
│   ├── indexer.zig       # 核心索引模块（同步、事件处理、重放、回滚）
│   ├── http_server.zig   # HTTP 查询与监控服务
│   ├── abi.zig           # ABI 解析辅助
│   └── utils.zig         # 工具函数（地址转换、大数字处理等）
├── config.toml           # 运行时配置文件
├── build.zig             # Zig 构建脚本
└── README.md             # 部署与使用说明
```

---

## 计划中的模块职责

### 1. 配置管理（`config.zig`）
- 加载并解析 `config.toml`
- 提供全局配置访问
- 核心配置域：`global`、`rpc`、`database`、`http`、`contracts`（数组）

### 2. 日志（`log.zig`）
- 基于 `std.log` 封装
- 分级输出：DEBUG / INFO / WARN / ERROR
- 输出到控制台 + 文件，按日期分割，限制单文件大小

### 3. 以太坊 RPC（`eth_rpc.zig`）
- 初始化与重连逻辑
- 批量拉取区块与日志（支持按合约地址、事件主题过滤）
- ABI 加载与事件解析
- 辅助接口：获取最新区块号、查询余额、验证地址格式

### 4. 数据持久化（`db.zig`）
- 数据库初始化与自动建表（`migrate`）
- 批量写入事件、更新账户状态、保证幂等性
- 支持 PostgreSQL 与 SQLite 切换
- 快照生成与恢复

### 5. 核心索引（`indexer.zig`）
- 同步管理：断点续传、批量同步、实时追块
- 事件处理：根据事件类型执行状态更新（如 ERC20 Transfer → 余额更新）
- 重放与回滚：指定区块范围重放，异常时回滚到稳定状态
- 多合约并行：每个合约独立协程处理

### 6. HTTP 服务（`http_server.zig`）
- 查询接口：账户余额、事件历史、同步状态、合约信息
- 监控接口：运行状态、同步进度、QPS
- 管理接口（可选）：手动触发重放、回滚、快照

### 7. ABI 辅助（`abi.zig`）
- ABI JSON 解析
- 日志数据解码为 Zig 结构体

### 8. 工具函数（`utils.zig`）
- 以太坊地址大小写转换与校验
- 大数字（uint256）处理辅助

---

## 计划中的数据模型

数据库应包含以下四张核心表：

### `sync_state` — 同步状态
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | SERIAL | 主键 |
| `contract_address` | VARCHAR(42) | 合约地址（小写），索引 |
| `last_synced_block` | BIGINT | 最后同步区块号 |
| `status` | VARCHAR(20) | running / stopped / error |
| `updated_at` | TIMESTAMP | 最后更新时间 |

### `events` — 事件数据
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | SERIAL | 主键 |
| `contract_address` | VARCHAR(42) | 合约地址，索引 |
| `event_name` | VARCHAR(100) | 事件名（如 Transfer），索引 |
| `block_number` | BIGINT | 区块号，索引 |
| `transaction_hash` | VARCHAR(66) | 交易哈希，索引 |
| `log_index` | INT | 日志索引 |
| `data` | JSONB | 解析后的结构化事件数据 |
| `created_at` | TIMESTAMP | 写入时间 |

### `account_states` — 账户状态
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | SERIAL | 主键 |
| `contract_address` | VARCHAR(42) | 合约地址，联合索引 |
| `account_address` | VARCHAR(42) | 账户地址，联合索引 |
| `balance` | NUMERIC(78) | 余额（支持大数字） |
| `last_updated_block` | BIGINT | 最后更新区块号 |
| `updated_at` | TIMESTAMP | 最后更新时间 |

### `snapshots` — 数据快照
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | SERIAL | 主键 |
| `contract_address` | VARCHAR(42) | 合约地址，索引 |
| `block_number` | BIGINT | 快照区块号，索引 |
| `snapshot_data` | JSONB | 账户状态快照 |
| `created_at` | TIMESTAMP | 快照创建时间 |

---

## 计划中的核心流程

### 启动流程
1. 加载 `config.toml`
2. 初始化日志、数据库客户端、RPC 客户端
3. 检查并自动创建数据表（`migrate`）
4. 读取 `sync_state`，获取各合约断点
5. 为每个合约启动独立同步协程
6. 启动 HTTP 服务

### 同步流程（核心循环）
1. 获取链上最新区块号
2. 按 `batch_size` 拉取日志
3. 过滤目标合约与目标事件
4. ABI 解析日志 → Zig 结构体
5. 执行对应状态更新逻辑
6. 批量写入数据库（事件、状态、同步进度），保证事务与幂等
7. 追块完成后，按固定间隔轮询最新区块

### 重放流程
1. 接收重放请求（指定合约、起止区块）
2. 暂停该合约同步，备份当前状态
3. 删除目标区块范围内的事件与状态数据
4. 从起始区块重新同步
5. 完成后恢复常态同步

### 故障自愈
- **RPC 异常**：自动重试（按配置次数），失败后暂停并定时再试
- **数据库异常**：自动重连，恢复后从断点续传
- **解析异常**：跳过单条日志，输出 WARN，不中断整体同步
- **进程崩溃**：重启后读取 `sync_state` 断点续传

---

## 构建与运行（计划中）

由于项目尚未创建源码，以下命令基于设计文档推导，**目前均无法执行**：

```bash
# 克隆依赖（待添加 build.zig 后）
zig build

# 运行索引器
zig build run -- -c config.toml

# 运行测试
zig build test

# 生产构建（静态链接、ReleaseSmall/ReleaseFast）
zig build -Doptimize=ReleaseFast
```

---

## 开发约定（建议）

项目尚未形成正式约定，以下根据设计文档与 Zig 社区最佳实践推导：

- **语言**：源码与注释以**中文**为主（设计文档为中文，面向中文开发者）。
- **内存管理**：使用 `GeneralPurposeAllocator` 或 `ArenaAllocator`；所有模块提供 `init` / `deinit` 对。
- **错误处理**：使用 Zig 错误联合类型（`try` / `catch`），关键路径错误必须记录日志。
- **命名风格**：
  - 函数、变量：`snake_case`
  - 类型、结构体：`PascalCase`
  - 常量：`SCREAMING_SNAKE_CASE`
- **模块依赖**：禁止循环依赖；`main.zig` 负责统筹初始化顺序。
- **数据库迁移**：所有表结构变更必须通过 `db.migrate()` 管理，不支持手动改表。
- **配置敏感信息**：`config.toml` 中的 RPC API Key、数据库密码应支持环境变量覆盖，避免提交密钥到仓库。

---

## 测试策略（计划中）

设计文档中未明确测试细节，建议按以下分层补充：

| 层级 | 范围 | 工具 |
|------|------|------|
| 单元测试 | 各模块内部函数（ABI 解析、工具函数、配置解析） | Zig 内置 `test` |
| 集成测试 | 数据库读写、RPC 客户端交互 | Zig `test` + 本地 PostgreSQL / 模拟 RPC |
| 端到端测试 | 完整同步流程、HTTP API | 本地 Anvil/Hardhat 节点 + 脚本 |

---

## 安全与部署注意事项

- **密钥管理**：`config.toml` 不应提交到版本控制；API Key、数据库密码通过环境变量注入。
- **SQL 注入**：所有数据库查询必须使用参数化语句，禁止字符串拼接 SQL。
- **Docker**：建议使用多阶段构建，基于 `scratch` 或 `distroless` 镜像，利用 Zig 静态编译特性实现最小攻击面。
- **网络**：HTTP 管理接口（如重放、回滚）如需暴露，必须增加鉴权机制。
- **日志**：避免在日志中输出完整 `config.toml` 内容或密钥信息。

---

## 给 AI 助手的快速参考

- 本项目**尚无可用代码**，所有实现需从零开始。
- 唯一权威参考是 `docs/dev.md`，但该文档**末尾截断**，`main.zig` 的协程启动示例未写完。
- 技术栈锁定为 **Zig 0.16.0+** 与 **eth.zig**，请勿引入其他语言运行时（如 Node.js、Python）。
- 如需补全 `docs/dev.md` 中缺失的代码片段，应基于 Zig 0.16 的语法与标准库实现，避免使用已废弃的 API。
- 下一步建议：创建 `build.zig`、初始化 `src/` 目录骨架、补全 `config.toml` 示例、实现 `config.zig` 与 `log.zig` 两个最基础的模块。
