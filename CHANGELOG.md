# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
