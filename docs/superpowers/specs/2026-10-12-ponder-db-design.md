# 设计：ponder.db —— JS Handler 业务投影写库 API

日期：2026-10-12
状态：待评审
背景：外部反馈核实（ard.md §2.2/§2.3 设想的"handler 里写投影"当前无法实现）

## 1. 问题定义

JS handler 的全局 `ponder` 只有 `on()` 和 `http.*`（js_engine.zig:121-146），无任何写库
API。业务投影（K 线、余额快照、聚合表）无处落地。配套短板：`event.block` 无 timestamp
（K 线必需），重组回滚只清内部表。

## 2. 现状约束（已核实）

| 事实 | 位置 | 对设计的影响 |
|------|------|--------------|
| 单 QuickJS runtime，`handleEvent` 全程持有 engine mutex | js_engine.zig:364 | ponder.db 同步调用天然串行，无需额外锁 |
| 事件先 `insertEventLog` 提交，再触发 JS 回调 | indexer.zig:661-682 | JS 写库与事件写入顺序天然一致；失败不阻断事件落库 |
| DB 三后端：SQLite / RocksDB / PostgreSQL | db.zig:49 | 裸 SQL API 覆盖 SQLite+PG；RocksDB 调用时明确报错 |
| 重组回滚 `rollbackFromBlock` 单事务删事件/快照/哈希 | db.zig:1152-1199 | 投影表级联删除在此扩展，原子性白拿 |
| 回调签名仅传 `block_number` | indexer.zig:682, main.zig:244 | 加 timestamp 需贯通 EventHookCallback / CombinedHook / EventBus |

## 3. API 设计（v1 最小面）

```js
// 写语句：CREATE/INSERT/UPDATE/DELETE，返回 changes 数
ponder.db.exec("INSERT INTO proj_kline (ts, open, close) VALUES (?, ?)", ts, close);

// 查询：返回行数组，列名为 key
const rows = ponder.db.query("SELECT * FROM proj_kline WHERE ts >= ?", fromTs);
```

- 位置参数 `?` 绑定（prepared statement，禁字符串拼接——这是注入防线，不是摆设）
- 类型映射：number→INTEGER（整数值走 int64）/REAL、string→TEXT、boolean→0/1、
  null→NULL、ArrayBuffer/TypedArray→BLOB
- 结果集：INTEGER/REAL→number、TEXT→string、BLOB→ArrayBuffer、NULL→null
- `query()` 不做语句类型强制：非 SELECT 语句返回空数组（changes 不计入返回值，
  需要 affected rows 时用 `exec`）；v1 信任调用方，不在引擎里做 SQL 解析
- RocksDB 后端：调用即抛 `ponder.db requires a SQL backend (current: rocksdb)`

## 4. 投影表约定与重组回滚

约定：投影表以 `proj_` 前缀命名，且**必须**含 `block_number INTEGER NOT NULL`。

`rollbackFromBlock`（db.zig:1152）在同一事务内追加：

```sql
-- SQLite
SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'proj\_%' ESCAPE '\';
-- 逐表: DELETE FROM <name> WHERE block_number >= ?
```

PG 后端用 `information_schema.tables`。与事件表删除同事务提交，回滚原子性不变。

不提供 `createProjection()` 助手——用户直接 `CREATE TABLE` 即可，前缀约定足够（YAGNI）。

## 5. 失败语义

handler 抛错 / SQL 失败：catch → `log.error`（含 contract/event/block_number）→
**继续索引**。理由：与现有 log-and-continue 一致；事件原始数据在 `event_*` 表，
修复路径 = 删 proj 表 + 从 fork 点重同步。顺手加 metric
`zponder_projection_errors_total`。

明确不做（v1）：多语句事务 API（`ponder.db.transaction`）、结构化 `ponder.store`
封装、RocksDB 支持。逐条 autocommit，单线程引擎下无竞态。

## 6. 配套：`event.block.timestamp`

- `EventHookCallback` 签名加 `block_timestamp: u64`；indexer 循环内 `block_data`
  已有 timestamp（indexer.zig:763 证明在作用域），贯通成本一行
- JS event 对象升级为 `{ args, block: { number, timestamp } }`
- 连带：CombinedHook（main.zig:239）、script_engine.processEvent（可忽略）、
  EventBus.publish、SSE payload

## 7. 改动清单

| 文件 | 改动 |
|------|------|
| js_engine.zig | `injectPonder` 加 `ponder.db`；exec/query 两个 C 回调；`setDb()`；event 对象加 timestamp |
| indexer.zig | EventHookCallback 签名 + timestamp 实参 |
| main.zig | CombinedHook 持有 `*db.Client` 注入 js_eng |
| db.zig | `rollbackFromBlock` 三后端级联 proj 表；exec/query 走现有 prepare 封装 |
| event_bus.zig | publish 签名 + payload 加 timestamp |
| docs/API.md、AGENTS.md | API 文档；projection 约定与 reorg 语义 |

## 8. 测试

- js_engine 单测：exec/query 参数绑定映射、类型往返、SQL 错误路径、RocksDB 报错
- db 单测：rollback 级联 proj 表（含无 proj 表的空库）
- 集成冒烟：handlers/ 下加 K 线投影示例 handler，事件 → proj_kline 行可查
