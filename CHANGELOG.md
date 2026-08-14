# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
