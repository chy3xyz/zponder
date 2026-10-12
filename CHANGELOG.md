# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.3] - 2026-10-12

### Added
- **`ponder.db` 业务投影 API**：JS handler 内 `ponder.db.exec/query` 参数化写读派生表
  （SQLite/PostgreSQL；RocksDB 无 SQL 明确报错）。支持 number/string/boolean/null/
  ArrayBuffer 全类型绑定与结果映射。
- **投影表重组级联回滚**：`proj_` 前缀 + `block_number` 列的约定表，在
  `rollbackFromBlock` 事务内按 `block_number >= fork_point` 级联删除。
- **`event.block.timestamp`**：事件对象携带链上区块时间，有 JS handler 时按需拉取
  并缓存（无 handler 零额外 RPC），K 线/时序投影不再依赖 `track_blocks`。
- `zponder_projection_errors_total` 指标；handler 抛错与 SQL 失败均记录日志并可观测。
- 示例 `examples/handlers/erc20_projection.js`（逐笔明细 + 每块 K 线聚合）。
- **事件表新增 `contract_address` 列与新唯一键**：`UNIQUE(contract_address, tx_hash, log_index)`
  取代 `UNIQUE(tx_hash, log_index)`，并加 `(contract_address, block_number)` 索引；同一
  tx/log 在不同合约下不再互相顶掉。老库幂等迁移：SQLite 重建事件表并回填地址，
  PostgreSQL 走 `ALTER TABLE ADD COLUMN` + 唯一约束 DROP/ADD。
- **`[[templates]]` 配置段 + 模板索引器**：一个 Indexer 持动态 clone 地址集合，一套
  `event_{模板名}_{事件}` 表承载全部 clone；`LogFilter` 支持地址数组，一次 `eth_getLogs`
  覆盖多地址；新地址从发现区块补扫后并入主循环。
- **模板地址集合持久化**：`template_addresses(template, address, from_block, backfilled)`
  （`PRIMARY KEY (template, address)`），重启恢复地址集合与补扫进度。
- **`[[factories]]` 新增 `template_name`**：指向 `[[templates]]`，与 `child_abi_path` 互斥；
  命中时把发现的子地址喂给模板，不再为每个 clone 建子索引器。
- **按地址查询/返回**：REST `GET /events/:contract/:event?address=0x…`；
  GraphQL `latestEvents(..., address: String)` 且 `Event.contractAddress: String!`。
- **JS handler `event.contractAddress` 与 SSE `contract_address`**：事件对象新增地址字段，
  SSE `/stream` 载荷同步携带。
- **launchpad 模板验收示例**：`examples/local-demo/launchpad-demo/`（工厂 + 3 clone，
  证明只产生一套 `event_curve_*` 表且按地址可区分）。
- **`[[templates]].max_addresses_per_request`**（默认 200）：主 sweep 按地址数分块
  发 `eth_getLogs`，避免几千 clone 时单请求超 RPC 上限。
- **工厂↔模板启动期一致性校验**：反向校验模板的 `factory_name`、拒绝重复工厂地址，
  避免错配时"进程显示 running 却零索引"。

### Changed
- **`autoMigrateContract` 变为 4 参**（末参 `contract_address`）：单合约传合约地址，
  模板模式传 `""`；调用方需同步签名。
- **老事件表迁移会重建表**（SQLite）：首次启动对老库就地重建并回填 `contract_address`，
  幂等，仅执行一次。
- 老 factory（`child_abi_path` 逐个 clone 建子索引器）行为保留不变；但对几千 clone 的
  场景推荐改用模板模式（单表多地址，避免每 clone 一张表/一个线程）。

### Fixed
- **PG 悬垂切片**：`queryEventLogsPG` 的参数格式化结果此前放在块作用域的栈数组
  `[21]u8` 里，函数返回后切片失效，调用方读到已回收栈帧，导致块号/分页条件静默错乱；
  现改用与 `params` 同生命周期的 arena。
- **`ponderQuerySqlite` / `ponderQueryPG` 行内部分填充泄漏**：多列映射中途分配失败时，
  当前行已 dupe 的列名/值未释放；现按已填充计数清理。
- **工厂子索引器悬垂 `*ContractConfig`**：`ChildIndexer` 先在栈上建再拷贝进堆，
  同步线程与 `idx.contract` 指向函数返回后失效的栈帧；现将子索引器直接建在堆上。
- **RocksDB 静默忽略地址过滤**：带 `address` 的查询在 RocksDB 后端（其 key 不含地址列）
  此前静默返回全量，现与模板模式一致明确返回 `error.UnsupportedOperation`。
- **C 字符串终止符越界读取（多处）**：`config.db_name` 等 Zig 切片直接以 `.ptr`
  传给 `sqlite3_open_v2` / `sqlite3_exec` / `rocksdb_open` / `PQconnectdb` / `PQexec`，
  这些 C API 按 NUL 结尾解析，切片无终止符时会读到越界内存——表现为随机
  `DatabaseOpenFailed (CANTOPEN)`、构造失败等布局相关故障。现统一复制并补终止符，
  并加回归测试覆盖。
- JS 事件 handler 抛出的异常此前被静默吞掉，现记录 `log.err` 并计入指标。
- **重复事件日志静默去重**：分块请求或补扫重叠导致的重取，此前会因唯一键冲突走入
  错误路径并往 `raw_logs` 写死信行（该表语义是"未被静默丢弃的日志"）；现
  `insertEventLog` 返回"是否真的新插入"，重复时整体跳过状态更新与回调——
  既不污染死信表，也不会二次执行 handler（投影不会重复累加）。

## [0.8.2] - 2026-10-05

### Changed
- zgraphql 依赖引用改为 **`git+https` URL 直连**（build.zig.zon 内
  `#fa62443…` commit 锁定 + 内容哈希校验），取代拷贝式 vendor 目录与
  git submodule；`zig fetch` 原生支持，clone 无需 `--recursive`。

## [0.8.1] - 2026-10-04

### Changed
- **zgraphql 0.7.0 → 0.8.0**：并发 sibling-field 执行（无 API 变更）；改为 vendor 到
  `vendor/zgraphql-0.8.0/` 本地路径，规避 GitHub tarball 哈希不稳定导致的重复下载失败。
- **QuickJS-ng 0.15.1 → 0.17.0**：vendored C 源码整体替换（register-based regexp 引擎、
  多个 UAF/越界修复）；移除残留的 `-DCONFIG_VERSION="0.8.0"` 编译定义（0.17.0 已不使用）。
- **发布 CI 修复**：改用 Zig 0.17.0 稳定版（旧 dev 构建已从 ziglang.org/builds
  下架导致 404）；本地依赖在 build.zig.zon 中使用 `.path` 字段（0.17.0 稳定版
  不接受相对路径 `.url`）。

## [0.8.0] - 2026-08-13

### Added
- **`ponder.http` 完整框架**（Hono 风格自定义 HTTP 端点，在 JS handler 内定义）：
  - `get/post/put/delete` 路由，`use` 中间件洋葱模型（`next()` 前进）
  - `c.req.param/query/body`、`c.json/c.text`、`c.status/c.header`
  - handler 异常返回 500（含错误信息），Content-Type 区分 JSON/文本
- **业务示例**：DEX Swap 价格、ERC20 鲸鱼、NFT 追踪、自定义 API + middleware 鉴权
  （`examples/handlers/`），文档与实现 API 完全对齐。

### Fixed
- `jsUndefined` 返回 int 0 而非 undefined，破坏 `=== undefined` 判断。
- `event_bus.Event.clone` OOM 时泄漏已 dupe 的前序字段/名称。

## [0.7.0] - 2026-08-13

### Added
- **GraphQL Subscription**：新增 `Subscription.newBlocks`（WebSocket `graphql-transport-ws`），
  实时推送索引器同步到的最新区块号。
- **SSE 实时事件流**：新增线程安全事件总线（`event_bus.zig`），`/stream` 现在持续推送
  索引器解码的事件（此前只发 `connected` 就断开）。
- **QuickJS `ponder.on` handler 引擎**：注入全局 `ponder` 对象，`ponder.on("Contract:Event", fn)`
  注册的 JS handler 现在会在事件到达时真实执行（此前 `ponder is not defined`）。
- **`contractCall` 真实返回类型**：从合约 ABI 解析函数返回类型（单返回/多返回 tuple），
  替代硬编码 `uint256`。
- **Metrics 增强**：`/metrics` 新增 `zponder_rpc_requests_total`、`zponder_rpc_errors_total`、
  `zponder_indexer_lag{contract}`。
- **`dev` 子命令**：强制 debug 日志级别运行。
- **CI**：`publish.yml` 增加 `zig build test`。

### Changed
- **zgraphql 0.4.0 → 0.7.0**：适配 `Value` API（`deinit`/`toJson` 显式 allocator）；
  移除 WS `user_data` workaround（0.4.1 已修复）。

### Fixed
- **SQLite 写连接线程安全**：写连接此前无 `FULLMUTEX`，多索引器线程并发写会数据竞争；
  现以 `SQLITE_OPEN_FULLMUTEX` 打开。
- **ABI 解码溢出**：恶意/畸形链上数据（超大 `u256` 偏移/长度）此前会导致 `@intCast` panic；
  转换前加边界检查。
- **GraphQL `latestEvents.offset` 溢出**：无上限的 `@intCast(i64→u32)` 在超大输入时 panic。
- **webhook `enqueueEvent` OOM 泄漏**：dupe/append 失败路径未释放已分配的 payload。
- **WSS 多合约并发崩溃**（0.6.2 续）：RPC 请求互斥锁改为有界等待（futex 唤醒丢失导致
  单索引器永久卡死）。
- **`check` 退出 Bus error**：`cors = true` 释放静态字面量（0.6.2 续）；`cmdCheck` RPC 客户端泄漏。

## [0.6.2] - 2026-08-08

### Fixed
- **WSS 多合约并发崩溃（segfault / abort）**：`std.http.Client` 非线程安全，
  多个索引器线程并发调用 `eth_rpc.Client.rpcCall` 造成数据竞争（TLS 初始化
  失败、崩溃）。RPC 请求现通过 `std.Io.Mutex` 串行化。
- **`zponder check` 退出 Bus error**：`config.toml` 的 `cors = true` 把字符串
  字面量 `"*"` 存入 `cors_origins`，`deinit` 时释放静态内存。现改为 dup 内容；
  并修复 `cmdCheck` 未释放 RPC 客户端（TLS 连接泄漏）。
- **SQLite 并发写偶发 ExecFailed**：初始化未设置 `PRAGMA busy_timeout`
  （默认 0，锁竞争时立即失败）。现从配置设置（默认 5000ms）。

### Changed
- `zponder check` 成功路径现在可干净退出（此前 Bus error，退出码非 0）。

## [0.6.1] - 2026-08-07

### Changed
- **升级 zgraphql 至 v0.4.0**：
  - 依赖从本地路径引用（`../zgraphql`）改为锁定 GitHub 发布包（`.url` + `.hash`），
    实现可复现构建（克隆即构建、版本可审计）。
  - v0.4.0 为纯修复版本：APQ use-after-free / 双重释放、QueryCache 线程安全
    （原为无锁实现）、Response Cache 泄漏、跨请求执行器变量泄漏、mutation
    错误缓存等。
  - **错误可观测性**：GraphQL 错误响应现在包含具体错误名与 `locations`
    （line/column），替代 v0.3.1 的泛化 "Execution error"。
- 修复测试收集缺口：`src/root.zig` 测试块补全 8 个模块强制引用
  （cache / rocksdb / pg / etherscan / template / dashboard / graphql / factory），
  这些模块的测试此前从未被执行。测试总数 77 → 82，全部通过。
- `build.zig`：`mod` 模块补 `build_options` 导入，与 exe 模块保持一致。

### Added
- `src/graphql.zig` 单元测试：
  - 纯函数校验逻辑（`isValidTableName` / `isValidMethodSignature` / `extractReturnType`）
  - Schema 构建与 resolver 挂载完整性
  - 端到端执行（zgraphql v0.4.0 解析 → 验证 → 执行 → JSON 序列化）

### Verified
- `zig build` 清缓存全新构建通过（依赖来自 v0.4.0 发布包）
- `zig build test`：82/82 通过
- 真实进程端到端：`zponder start` 后
  - `{ health version }` → `{"data":{"health":"ok","version":"0.6.1 (…)"}}`
  - `{ unknownField }` → `{"errors":[{"locations":[{"column":16,"line":1}],…}]}`
    （v0.4.0 `locations` 行为确认生效）
