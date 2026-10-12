# 设计：模板索引器 + 事件地址列（launchpad 多 clone 场景）

日期：2026-10-12
状态：待评审
目标规模：几千个 clone（每币一 curve、毕业后每币一 pair）

## 1. 问题

zponder 现模型"一个合约 = 一套表"，且**事件表没有地址列**（`db.zig:262-276`
createEventTable：id + 事件参数 + block_number/tx_hash/log_index）。对 launchpad：

- N 个币 → N×事件数 张表，配置无界
- 表内无法区分事件来自哪个 clone（地址不在列里）
- 现行 factory 子合约表名只用地址后 6 hex（`factory.zig:176-177`），
  16^6≈1670 万，**√ 后约 4000 个子合约即生日碰撞** → 两个币写进同一张表
- 按每币一线程（`indexer.zig:184`）扩到几千，线程/RPC/单写连接都撞墙
- 子合约建表发生在工厂回调线程内（`Indexer.init` → `autoMigrateContract`），运行期 DDL

结论：热重载注册（factory）机制本身够用；**缺的是地址维度**。

## 2. 设计

### 2.1 事件表增加地址列（地基，非可选）

`event_{name}_{event}` 新增 `contract_address TEXT NOT NULL DEFAULT ''`：

- 唯一键 `UNIQUE(tx_hash, log_index)` → `UNIQUE(contract_address, tx_hash, log_index)`
  （同一 tx 内不同合约的事件不再互相顶掉；补扫/WSS 重放天然幂等）
- 新增索引 `(contract_address, block_number)`
- `insertEventLog` 增 `contract_address` 参数；`queryEventLogs` 支持按地址过滤
- 回滚/重放：
  - 单合约模式（`[[contracts]]`）：谓词不变，地址列仅记录
  - 模板模式：**整模板按 `block_number >= fork` 回滚**（模板内所有地址都是链级事实，
    fork 之后创建的 clone 与它们的全部事件一致作废，无需地址谓词，语义最简且不会漏删）
  - replay/`deleteEventLogsInRange`（indexer.zig:202-215）：按 `[from,to]` 区间删除，
    模板模式下可选 `address` 收窄到单个 clone

**迁移**（老库）：`ALTER TABLE ADD COLUMN`（幂等，查 `pragma table_info` /
PG `ADD COLUMN IF NOT EXISTS`）；唯一键 SQLite 不能直接改 → 建新表 + `INSERT SELECT`
+ `DROP` + `RENAME`，地址按"该表原属合约"回填。RocksDB 分支键前缀加地址。

### 2.2 模板维度：一个 indexer，多个地址

配置新增 `[[templates]]`（与 `[[contracts]]` 并存，老配置行为不变）：

```toml
[[templates]]
name = "curve"              # 表前缀：event_curve_*
abi_path = "./abis/bonding_curve.abi"
events = ["Buy", "Sell"]
# 地址来源：工厂发现（复用现有 factory 的字段语义）
discover_from = "launchpad"          # 关联的 [[factories]] name
discovery_event = "TokenCreated"
discovery_address_field = "curve"
```

- `LogFilter.address: []const u8` → `addresses: []const []const u8`；
  `formatLogFilterObject`（eth_rpc.zig:395-410）输出 JSON 数组；地址集合为空时跳过轮询
- 毕业后的 Pancake pair 用**同一个机制**再开一个模板：`discover_from` 指向
  同一工厂、`discovery_event` 换成毕业事件（如 `Graduated`）、字段取 pair 地址
- **与老 factory 互斥**：同一发现事件不要同时配 `[[factories]]` 的 `child_*` 和
  模板的 `discover_from`（否则同一批 clone 会被两套索引器重复索引）。老 factory
  保留但标注为 legacy（适合 N 小）；本文档的模式面向几千规模
- 游标：沿用 `current_block` 单调推进 + `syncRange`
- **地址集合增长（核心难点）**：发现 `(addr, from_block)` → 入 `pending_backfill`；
  每轮先把 pending 按 `[from_block, 探到时的 current_block)` 区间批量补扫（受 batch_size 限制），
  完成后并入 live 集合、由主循环接管。UNIQUE 键保证补扫/主循环重叠不重复
- RPC 自适应：现有 batch_size 减半逻辑扩展为按 `地址数 × 区块跨度` 估算，命中
  provider limit 即降批
- 重组：模板级检测（`block_hashes` 键改 `(template_name, block_number)`，链级事实）；
  回滚对该模板的事件表按 `block_number >= fork` 整模板回滚（模板内所有地址一致回滚，语义最简且正确）
- 建表在模板 indexer 启动时一次完成 → 无运行期 DDL（消除隐患）
- 线程数 = 模板数（个位数），表数 = 模板×事件数

### 2.3 对外接口

- REST `/events/:template/:event` 增加可选 `?address=0x…`；响应每行含 `contract_address`
- GraphQL 事件类型暴露 `contract_address`（可查询/可过滤）
- JS event 对象加 `event.contractAddress`（投影脚本据此区分币，配合 `ponder.db`
  即可写"每币一张 proj 行/按币 agg"）

## 3. 不做（YAGNI）

- 不重写现有 `[[contracts]]` 单地址模式（兼容保留）
- 不做运行期增删**模板**（模板是启动期概念；只有地址集合是动态的）
- 不给 RocksDB 做 SQL 能力（模板模式在 RocksDB 后端仅存原始事件，投影仍限 SQL）

## 4. 风险

| 风险 | 处置 |
|------|------|
| SQLite 唯一键不能 ALTER | 建新表搬数据；迁移前校验（行数一致 + 抽查） |
| 补扫与主循环边界漏/重 | UNIQUE 键兜重复；补扫区间上界取"探测时游标"；加单测覆盖 |
| 公共 RPC 对地址数组/结果数有限制 | 自适应降批 + `max_addresses_per_request` 配置 |
| 老库地址回填不准 | 老表按原合约地址回填；无法判定时留 `''` 并在文档标注 |

## 5. 验证

- 单测：迁移幂等；唯一键允许"同 tx 不同合约"两行；补扫区间无缺口/无重复；
  按地址回滚只删目标地址；地址数组 filter JSON 正确
- 端到端（Anvil）：工厂 + 多 clone，验证一套表多地址、`WHERE contract_address`
  分币正确、重组回滚不误删
- 规模：1000 地址的 filter/SQL 构造与内存；Anvil 验证数组过滤可用

## 6. 工作量

| 项 | human | 本侧 |
|----|-------|------|
| 地址列 + 迁移 + 回滚谓词 | ~1 天 | ~20-30 分钟 |
| 模板 indexer（地址数组 + 补扫 + 配置） | ~2 天 | ~40-60 分钟 |
| API/GraphQL/JS 暴露 | ~0.5 天 | ~15 分钟 |
| 测试 + e2e | ~0.5-1 天 | ~30 分钟 |

实施顺序：2.1（地址列，独立可发布）→ 2.2（模板）→ 2.3（接口暴露）。
