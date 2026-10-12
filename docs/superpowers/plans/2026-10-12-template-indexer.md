# 模板索引器 + 事件地址列 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 zponder 支撑几千个 clone（launchpad：每币一 curve、毕业后每币一 pair）：事件表带 `contract_address` 列，模板索引器用一套表 + 动态地址集合索引全部 clone。

**Architecture:** 表身份由"模板"决定（`event_{template}_{event}`），行归属由 `contract_address` 列决定；模板索引器持动态地址集合（工厂发现 + 落库 `template_addresses`），`eth_getLogs` 一次传地址数组，新地址从创建区块补扫后并入主循环。

**Tech Stack:** Zig 0.17、QuickJS、SQLite/PostgreSQL/RocksDB、stdlib `std.Io`、测试用 `zig build test`（Zig 内建 test 块）。

设计文档：`docs/superpowers/specs/2026-10-12-template-indexer-design.md`

## Global Constraints

- Zig 版本：0.17.0（`build.zig.zon` 的 `minimum_zig_version`）——`std.fs.cwd()` 等旧 API 不存在，文件/目录操作走 `std.Io.Dir.cwd().*` 且需传 `io`
- 所有 C 字符串 API（sqlite3_*/PQ*/rocksdb_open）不接受非 NUL 结尾的 Zig 切片：一律 `allocSentinel` 复制后再传 `.ptr`
- 表名/列名只允许 `[A-Za-z0-9_]`（`sanitizeColumnName`、`isValidTableName`）
- 事务边界：`rollbackFromBlock` 内所有删除必须同一事务（已有 `BEGIN;`/`COMMIT;`）
- 每个任务结束必须 `zig build test` 全绿（当前基线 98 个测试）
- 提交信息格式：`<type>: <中文摘要>`（type ∈ feat/fix/refactor/test/docs/chore）

---

## 文件结构

| 文件 | 职责 | 本计划改动 |
|------|------|------------|
| `src/db.zig` | 存储层：建表/迁移/插入/查询/回滚 | Phase 1 全部 + `template_addresses` |
| `src/indexer.zig` | 单合约同步循环；本计划扩展为支持模板模式 | Phase 1 传址 + Phase 2 模板模式 |
| `src/eth_rpc.zig` | RPC：LogFilter/getLogs/WSS 订阅 | Phase 2 地址数组 |
| `src/config.zig` | TOML 解析 | Phase 2 `[[templates]]` |
| `src/factory.zig` | 工厂发现（child 索引器或喂模板地址集合） | Phase 2 增加 template 分发 |
| `src/main.zig` | 装配 | Phase 1/2 装配 |
| `src/http_server.zig` | REST `/events/:contract/:event` | Phase 3 地址过滤 |
| `src/graphql.zig` | `latestEvents` | Phase 3 地址字段/参数 |
| `src/js_engine.zig` | JS 事件对象 | Phase 3 `event.contractAddress` |
| `src/event_bus.zig` | SSE 事件载荷 | Phase 3 地址字段 |

---

# Phase 1：事件地址列（可独立发布，顺带修掉表名碰撞）

## Task 1: 事件表新增 `contract_address` 列与新唯一键

**Files:**
- Modify: `src/db.zig:258-280`（`createEventTable`）
- Modify: `src/db.zig:299-345`（`insertEventLog` SQLite 版）
- Test: `src/db.zig`（文件末尾追加 test 块）

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `Client.insertEventLog(contract_name, event_name, fields, block_number, tx_hash, log_index, contract_address: []const u8) !void`（**新增第 7 个参数**）
  - 表结构：`event_{name}_{event}` 含 `contract_address TEXT NOT NULL DEFAULT ''`，`UNIQUE(contract_address, tx_hash, log_index)`，索引 `idx_{name}_{event}_addr_block (contract_address, block_number)`

- [ ] **Step 1: 写失败测试**

在 `src/db.zig` 末尾追加（`DatabaseConfig` 与 `Client` 已在文件内可见）：

```zig
test "db 事件表 contract_address 列：同 tx 不同合约都能落库" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"});

    const fields = [_]DecodedField{
        .{ .name = "from", .value = "0xaaa" },
        .{ .name = "value", .value = "1" },
    };
    // 同一 tx_hash/log_index，两个不同 clone：都必须存在（旧唯一键会把第二条顶掉）
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_A");
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_B");

    const rows = try client.ponderQuery("SELECT contract_address, COUNT(*) AS n FROM event_curve_Transfer GROUP BY contract_address;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
}
```

> 注：Zig 里 `db.DecodedField` 在本文件内就是 `DecodedField`，把类型别名写成 `DecodedField` 即可（去掉 `db_` 前缀）。

- [ ] **Step 2: 运行测试确认失败**

Run: `zig build test -- --test-filter "同 tx 不同合约"`
Expected: FAIL —— `insertEventLog` 参数数量不匹配（`member function expected 6 argument(s), found 7`）

- [ ] **Step 3: 改 `createEventTable`**

```zig
    fn createEventTable(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent) !void {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("CREATE TABLE IF NOT EXISTS event_{s}_{s} (", .{ contract_name, evt.name });
        try w.writeAll("\n  id INTEGER PRIMARY KEY AUTOINCREMENT,");
        for (evt.inputs) |input| {
            const col_name = try self.sanitizeColumnName(input.name);
            defer self.alloc.free(col_name);
            const sql_type = abi.abiTypeToSqlType(input.type);
            try w.print("\n  {s} {s},", .{ col_name, sql_type });
        }
        try w.writeAll("\n  block_number INTEGER NOT NULL,");
        try w.writeAll("\n  tx_hash TEXT NOT NULL,");
        try w.writeAll("\n  log_index INTEGER NOT NULL,");
        try w.writeAll("\n  contract_address TEXT NOT NULL DEFAULT '',");
        try w.writeAll("\n  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,");
        try w.print("\n  UNIQUE(contract_address, tx_hash, log_index)\n);", .{});
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_addr_block ON event_{s}_{s}(contract_address, block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        var list = sql_buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.exec(list.items);
    }
```

- [ ] **Step 4: 改 `insertEventLog`（SQLite 分支）**

```zig
    pub fn insertEventLog(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const DecodedField,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        contract_address: []const u8,
    ) !void {
        if (self.backend_type == .rocksdb) return self.insertEventLogRocks(contract_name, event_name, fields, block_number, tx_hash, log_index, contract_address);
        if (self.backend_type == .postgresql) return self.insertEventLogPG(contract_name, event_name, fields, block_number, tx_hash, log_index, contract_address);

        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("INSERT INTO event_{s}_{s} (", .{ contract_name, event_name });
        for (fields, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            const col = try self.sanitizeColumnName(f.name);
            defer self.alloc.free(col);
            try w.writeAll(col);
        }
        try w.writeAll(",block_number,tx_hash,log_index,contract_address) VALUES (");
        for (fields, 0..) |_, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('?');
        }
        try w.writeAll(",?,?,?,?);");
        // …（prepare / bind 前 4 段保持原样）…
        // 在 bind log_index 之后追加：
        // col_idx += 1;
        // if (c.sqlite3_bind_text(stmt, col_idx, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        // if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        // if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }
```

> 实施时保留原 prepare/bind 代码，仅把 `,?,?,?);` 改为 `,?,?,?,?);`，并在 `log_index` bind 之后补一段 `contract_address` 的 bind（常量用 `c.SQLITE_STATIC`）。

- [ ] **Step 5: 同步三个调用点编译通过**

- `src/indexer.zig:661-668`（`insertEventLog(...)` 调用）末尾补 `, self.contract.address`
  （单合约模式即该合约地址；模板模式在 Task 7 改为 `lg.address`）
- `src/db.zig` 内 `insertEventLogRocks` / `insertEventLogPG` 签名加第 7 个参数
  （本任务先接收并忽略，Task 4 落地各后端的真实存储）

- [ ] **Step 6: 运行测试确认通过**

Run: `zig build test -- --test-filter "同 tx 不同合约"` → PASS
Run: `zig build test` → 全绿（原 98 + 1）

- [ ] **Step 7: 提交**

```bash
git add src/db.zig src/indexer.zig
git commit -m "feat: 事件表新增 contract_address 列与地址唯一键"
```

---

## Task 2: 老表迁移（补列 + 重建唯一键 + 地址回填）

**Files:**
- Modify: `src/db.zig:244-256`（`autoMigrateContract` 调用迁移）
- Modify: `src/db.zig`（新增 `migrateEventTableAddress`）
- Test: `src/db.zig`

**Interfaces:**
- Consumes: Task 1 的表结构
- Produces: `Client.migrateEventTableAddress(contract_name: []const u8, evt: *const abi.AbiEvent, contract_address: []const u8) !void`（幂等；老表带数据升级）

- [ ] **Step 1: 写失败测试**

```zig
test "db 老事件表迁移：补地址列并回填，行数不变" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    // 手工造"旧结构"表（无 contract_address、旧唯一键）
    try client.exec(
        \\CREATE TABLE event_dai_Transfer (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  evt_from TEXT, evt_value TEXT,
        \\  block_number INTEGER NOT NULL, tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(tx_hash, log_index));
    );
    try client.exec("INSERT INTO event_dai_Transfer (evt_from, evt_value, block_number, tx_hash, log_index) VALUES ('0xa','1',10,'0xt',0);");

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    // 迁移两次：必须幂等
    try client.migrateEventTableAddress("dai", &test_evt, "0xDAI");
    try client.migrateEventTableAddress("dai", &test_evt, "0xDAI");

    const rows = try client.ponderQuery("SELECT contract_address, evt_from, block_number FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0xDAI", rows[0].values[0].text);
    try std.testing.expectEqualStrings("0xa", rows[0].values[1].text);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test -- --test-filter "老事件表迁移"` → FAIL（`no member named 'migrateEventTableAddress'`）

- [ ] **Step 3: 实现迁移**

```zig
    /// 老库升级：确保事件表带 contract_address 列且唯一键含地址。
    /// 幂等：列已存在且唯一键已更新时是空操作。SQLite 无法 ALTER 唯一约束，
    /// 因此需要重建表并搬数据（回填 contract_address）。
    pub fn migrateEventTableAddress(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent, contract_address: []const u8) !void {
        if (self.backend_type == .rocksdb) return;
        // 1) 表不存在则直接按新结构建
        //    2) 查 pragma table_info：无 contract_address 列 → 走重建
        //    3) 重建：CREATE event_X_new(新结构) → INSERT SELECT 旧列 + 回填地址 → DROP 旧表 → RENAME → 建索引
    }
```

实施要点（照此写全）：
- 用 `c.sqlite3_prepare_v2("PRAGMA table_info(event_{s}_{s});")` + `sqlite3_column_text(1)` 收集列名，判断是否已有 `contract_address`
- 无该列时用 `std.Io.Writer.Allocating` 拼：
  1. `CREATE TABLE event_X__new (…与 createEventTable 相同列序…, UNIQUE(contract_address, tx_hash, log_index));`
  2. `INSERT INTO event_X__new (旧列…, contract_address) SELECT 旧列…, ? FROM event_X;`（地址用 `?` 绑定）
  3. `DROP TABLE event_X;`
  4. `ALTER TABLE event_X__new RENAME TO event_X;`
  5. `CREATE INDEX … _addr_block`（`createEventTable` 里的三条索引）
- 全程包在一个事务里：`try self.exec("BEGIN;")` + `errdefer` ROLLBACK + 结尾 `COMMIT;`（与 `rollbackFromBlock` 同风格）
- 已有列但唯一键是旧的（`UNIQUE(tx_hash, log_index)`）也走重建——判断方式：`SELECT sql FROM sqlite_master WHERE name='event_X';` 里是否含 `contract_address,` 于 UNIQUE 内
- PG 分支：`ALTER TABLE ADD COLUMN IF NOT EXISTS` + `ALTER TABLE … DROP CONSTRAINT IF EXISTS` / `ADD CONSTRAINT UNIQUE(...)`（PG 可直接改约束，无需重建）

- [ ] **Step 4: 接到 `autoMigrateContract`**

```zig
        for (event_names) |evt_name| {
            const evt = abi_contract.findEventByName(evt_name) orelse continue;
            try self.migrateEventTableAddress(contract_name, evt, contract_address);
            try self.createEventTable(contract_name, evt); // 新建时是空操作（IF NOT EXISTS）
        }
```

`autoMigrateContract` 签名加 `contract_address: []const u8` 参数（单合约模式传 `self.contract.address`；模板模式传 `""`）。调用点：`src/indexer.zig:86`。

- [ ] **Step 5: 运行测试**

Run: `zig build test` → 全绿（99 + 1 = 100）

- [ ] **Step 6: 提交**

```bash
git add src/db.zig src/indexer.zig
git commit -m "feat: 老事件表迁移到带地址唯一键的结构（幂等 + 地址回填）"
```

---

## Task 3: 查询按地址过滤

**Files:**
- Modify: `src/db.zig:439-508`（`queryEventLogs` SQLite）
- Test: `src/db.zig`

**Interfaces:**
- Consumes: Task 1 表结构
- Produces: `Client.queryEventLogs(contract_name, event_name, block_from, block_to, tx_hash, address: ?[]const u8, limit, offset, order_desc) ![]u8`（**新增第 6 参数**，返回 JSON 数组，行内含 `contract_address`）

- [ ] **Step 1: 写失败测试**

```zig
test "db queryEventLogs 支持按地址过滤且返回 contract_address" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{.{ .name = "value", .type = "uint256", .indexed = false }}, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"}, "");
    const fields = [_]DecodedField{.{ .name = "value", .value = "7" }};
    try client.insertEventLog("curve", "Transfer", &fields, 10, "0xt1", 0, "0xA");
    try client.insertEventLog("curve", "Transfer", &fields, 11, "0xt2", 0, "0xB");

    const all = try client.queryEventLogs("curve", "Transfer", null, null, null, null, 10, 0, true);
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "contract_address") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xA") != null);

    const only_b = try client.queryEventLogs("curve", "Transfer", null, null, null, "0xB", 10, 0, true);
    defer alloc.free(only_b);
    try std.testing.expect(std.mem.indexOf(u8, only_b, "0xA") == null);
    try std.testing.expect(std.mem.indexOf(u8, only_b, "0xB") != null);
}
```

- [ ] **Step 2: 运行确认失败** → `zig build test -- --test-filter "按地址过滤"` FAIL

- [ ] **Step 3: 改 SQL 与绑定**

在现有 `WHERE 1=1` 之后追加地址条件，并按同样顺序绑定：

```zig
        if (tx_hash) |_| try w.writeAll(" AND tx_hash = ?");
        if (address) |_| try w.writeAll(" AND contract_address = ?");   // 新增
```

```zig
        if (tx_hash) |th| { …bind… bind_idx += 1; }
        if (address) |ad| { if (c.sqlite3_bind_text(stmt, bind_idx, ad.ptr, @intCast(ad.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }  // 新增
```

`SELECT *` 已含新列，JSON 序列化无需改（列名会带出 `contract_address`）。

- [ ] **Step 4: 同步调用点**（先传 `null`，Phase 3 再暴露）
- `src/http_server.zig:554-558`
- `src/graphql.zig:352`
- PG/RocksDB 分支同样加参数（PG 用 `$N`，RocksDB 暂忽略并加注释）

- [ ] **Step 5: 运行测试** → `zig build test` 全绿（101）

- [ ] **Step 6: 提交**

```bash
git add src/db.zig src/http_server.zig src/graphql.zig
git commit -m "feat: queryEventLogs 支持按 contract_address 过滤"
```

---

## Task 4: 模板模式的存储支撑（`template_addresses`）

**Files:**
- Modify: `src/db.zig`（`migrate` 内建表；新增 4 个方法）
- Test: `src/db.zig`

**Interfaces:**
- Produces:
  - `Client.addTemplateAddress(template: []const u8, address: []const u8, from_block: u64) !void`（幂等 upsert）
  - `Client.listTemplateAddresses(template: []const u8) ![]TemplateAddress`（`{ address: []u8, from_block: u64, backfilled: bool }`，调用方 free）
  - `Client.markTemplateAddressBackfilled(template, address) !void`
  - `Client.deleteTemplateAddressesFromBlock(template, from_block) !void`

- [ ] **Step 1: 写失败测试**

```zig
test "db template_addresses 增删查与回滚" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.addTemplateAddress("curve", "0xA", 100);
    try client.addTemplateAddress("curve", "0xA", 100); // 幂等
    try client.addTemplateAddress("curve", "0xB", 200);
    {
        const list = try client.listTemplateAddresses("curve");
        defer alloc.free(list);
        try std.testing.expectEqual(@as(usize, 2), list.len);
    }
    try client.markTemplateAddressBackfilled("curve", "0xA");
    try client.deleteTemplateAddressesFromBlock("curve", 150);
    const after = try client.listTemplateAddresses("curve");
    defer alloc.free(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("0xA", after[0].address);
    try std.testing.expect(after[0].backfilled);
}
```

- [ ] **Step 2: 运行确认失败** → FAIL（无 `addTemplateAddress`）

- [ ] **Step 3: 实现**

建表（`migrate()` 的 SQLite 段与 PG 段各加一份，RocksDB 跳过）：

```sql
CREATE TABLE IF NOT EXISTS template_addresses (
  template   TEXT NOT NULL,
  address    TEXT NOT NULL,
  from_block INTEGER NOT NULL,
  backfilled INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (template, address)
);
```

四个方法照 `upsertSyncState`/`getSyncState`（`src/db.zig:590-640`）的写法实现；`addTemplateAddress` 用 `INSERT … ON CONFLICT(template, address) DO NOTHING`（重复发现不动已有进度）；`listTemplateAddresses` 返回堆数组（`address` 为 dupe，调用方 `alloc.free(list)` + 逐个 `free(address)`，与 `getSyncState` 的约定一致）。

- [ ] **Step 4: 运行测试** → `zig build test` 全绿（102）

- [ ] **Step 5: 提交**

```bash
git add src/db.zig
git commit -m "feat: template_addresses 表与地址集合读写（模板模式持久化）"
```

---

# Phase 2：模板索引器

## Task 5: `LogFilter` 支持地址数组

**Files:**
- Modify: `src/eth_rpc.zig:18-24`（`LogFilter`）
- Modify: `src/eth_rpc.zig:395-429`（`formatLogFilterObject`）
- Modify: 构造点 `src/indexer.zig:581-586`、`src/indexer.zig:477-480`
- Test: `src/eth_rpc.zig`（文件末尾 test 块）

**Interfaces:**
- Produces: `LogFilter{ addresses: ?[]const []const u8 = null, topics, from_block, to_block }`（**`address` 改名并改为切片**）；JSON 输出 `"address":["0xA","0xB"]`（单元素也输出数组；`null` 时输出 `null`）

- [ ] **Step 1: 写失败测试**

```zig
test "eth_rpc LogFilter 地址数组序列化" {
    const alloc = std.testing.allocator;
    const addrs = [_][]const u8{ "0xA", "0xB" };
    const f1 = LogFilter{ .addresses = &addrs, .from_block = 1, .to_block = 2 };
    const s1 = try formatLogFilterObject(alloc, f1, true);
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("{\"address\":[\"0xA\",\"0xB\"],\"fromBlock\":\"0x1\",\"toBlock\":\"0x2\"}", s1);

    const f2 = LogFilter{ .from_block = 1 };
    const s2 = try formatLogFilterObject(alloc, f2, true);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("{\"address\":null,\"fromBlock\":\"0x1\"}", s2);
}
```

- [ ] **Step 2: 运行确认失败** → `zig build test -- --test-filter "地址数组序列化"` FAIL

- [ ] **Step 3: 实现**

```zig
pub const LogFilter = struct {
    addresses: ?[]const []const u8 = null,
    topics: ?[]const []const u8 = null,
    from_block: ?u64 = null,
    to_block: ?u64 = null,
};
```

```zig
    try buf.writer.writeAll("{\"address\":");
    if (filter.addresses) |addrs| {
        try buf.writer.writeByte('[');
        for (addrs, 0..) |a, i| {
            if (i > 0) try buf.writer.writeByte(',');
            try buf.writer.print("\"{s}\"", .{a});
        }
        try buf.writer.writeByte(']');
    } else {
        try buf.writer.writeAll("null");
    }
```

- [ ] **Step 4: 同步两处构造点**

`indexer.zig:581-586` 与 `477-480` 改为：

```zig
        const addrs = [_][]const u8{self.contract.address};
        const filter = eth_rpc.LogFilter{
            .addresses = &addrs,
            .topics = if (topics.len > 0) topics else null,
            .from_block = from_block,
            .to_block = to_block,
        };
```

- [ ] **Step 5: 运行测试** → `zig build test` 全绿（103）

- [ ] **Step 6: 提交**

```bash
git add src/eth_rpc.zig src/indexer.zig
git commit -m "feat: LogFilter 支持地址数组（多 clone 一次 getLogs）"
```

---

## Task 6: 配置 `[[templates]]`

**Files:**
- Modify: `src/config.zig`（结构体 + 段解析 + 默认值 + `Config` 字段 + 释放）
- Test: `src/config.zig`

**Interfaces:**
- Produces: `TemplateConfig{ name, abi_path, events: []const []const u8, factory_name: []const u8, discovery_event: []const u8, discovery_address_field: []const u8, from_block: u64, poll_interval_ms: ?u32, block_batch_size: ?u32 }`；`Config.templates: []TemplateConfig`

- [ ] **Step 1: 写失败测试**

```zig
test "config 解析 [[templates]]" {
    const alloc = std.testing.allocator;
    const toml =
        \\[global]
        \\chain = "bsc"
        \\[rpc]
        \\url = "http://localhost:8545"
        \\[[contracts]]
        \\name = "launchpad"
        \\address = "0x1"
        \\abi_path = "./abis/launchpad.abi"
        \\events = ["CurveCreated"]
        \\[[factories]]
        \\name = "launchpad_factory"
        \\address = "0x1"
        \\abi_path = "./abis/launchpad.abi"
        \\creation_event = "CurveCreated"
        \\child_address_field = "curve"
        \\child_abi_path = "./abis/curve.abi"
        \\child_events = ["Buy"]
        \\template_name = "curve"
        \\[[templates]]
        \\name = "curve"
        \\abi_path = "./abis/curve.abi"
        \\events = ["Buy", "Sell"]
        \\factory_name = "launchpad_factory"
        \\discovery_event = "CurveCreated"
        \\discovery_address_field = "curve"
        \\from_block = 100
        \\
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cfg.templates.len);
    try std.testing.expectEqualStrings("curve", cfg.templates[0].name);
    try std.testing.expectEqual(@as(usize, 2), cfg.templates[0].events.len);
    try std.testing.expectEqual(@as(u64, 100), cfg.templates[0].from_block);
    try std.testing.expectEqualStrings("curve", cfg.factories[0].template_name);
}
```

> `loadFromString` 已存在（`src/config.zig:399`），`deinit` 的签名与调用方式照 `src/config.zig:1296` 的既有测试。

- [ ] **Step 2: 运行确认失败** → FAIL（`templates` 不存在）

- [ ] **Step 3: 实现**（照 `[[factories]]` 的三段式：结构体 / 段起始默认值 / 字段名映射 / flush）

```zig
pub const TemplateConfig = struct {
    name: []const u8,
    abi_path: []const u8,
    events: []const []const u8,
    factory_name: []const u8,
    discovery_event: []const u8,
    discovery_address_field: []const u8,
    from_block: u64,
    poll_interval_ms: ?u32,
    block_batch_size: ?u32,
};
```

- 段头：`else if (std.mem.eql(u8, section_name, "templates"))`
- 字段映射照 `i`（`name/abi_path/events/factory_name/discovery_event/discovery_address_field/from_block/poll_interval_ms/block_batch_size`）
- `Config` 加 `templates: []TemplateConfig`，`deinit` 释放（照 `factories` 的释放段）

- [ ] **Step 4: 运行测试** → 全绿（104）

- [ ] **Step 5: 提交**

```bash
git add src/config.zig
git commit -m "feat: 新增 [[templates]] 配置段"
```

---

## Task 7: Indexer 模板模式（地址集合 + 补扫）

**Files:**
- Modify: `src/indexer.zig`（结构体字段 + `setTemplateMode`/`addTemplateAddress` + `syncRange`/`processLog` 分支）
- Test: `src/indexer.zig`

**Interfaces:**
- Consumes: Task 1/3/4/5（表结构、地址过滤、`template_addresses`、地址数组）
- Produces:
  - `Indexer.setTemplateMode(self, enabled: bool) void`
  - `Indexer.discoverAddress(self, address: []const u8, from_block: u64) void`
    （**注意与 `Client.addTemplateAddress` 区分**：本方法入内存队列并落库，线程安全）
  - `Indexer.templateAddressCount(self) usize`
  - `Indexer.loadTemplateAddresses(self) !void`（启动时从库恢复）
  - `fn computeBackfillRange(discovered_at_block: u64, current_cursor: u64) [2]u64`（**纯函数，供单测**）

- [ ] **Step 1: 写失败测试（纯函数 + 集合语义）**

```zig
test "template computeBackfillRange 无缺口" {
    // 发现于 100，当前游标 250 → 补 [100, 250)
    try std.testing.expectEqual([2]u64{ 100, 250 }, computeBackfillRange(100, 250));
    // 发现区块晚于游标（同一批内）→ 空区间
    try std.testing.expectEqual([2]u64{ 0, 0 }, computeBackfillRange(300, 250));
}

test "template 地址集合去重与计数" {
    const alloc = std.testing.allocator;
    const contract = config.ContractConfig{
        .name = "curve", .address = "", .abi_path = "", .events = &.{},
        .from_block = 0, .start_block = null, .poll_interval_ms = null,
        .max_reorg_depth = null, .block_batch_size = null, .filters = &.{},
    };
    var idx = Indexer{
        .alloc = alloc, .rpc = undefined, .database = undefined, .contract = &contract,
        .snapshot_interval = 0,
        .state = std.atomic.Value(IndexerState).init(.stopped),
        .current_block = std.atomic.Value(u64).init(0),
        .last_tip = std.atomic.Value(u64).init(0),
        .last_snapshot_time = std.atomic.Value(i64).init(0),
        .batch_size = 100, .poll_interval_ms = 1000, .abi_contract = null, .thread = null,
        .track_blocks = false, .chain = "ethereum",
        .factory_ctx = null, .factory_callback = null, .factory_idx = 0,
    };
    defer idx.deinit();
    idx.setTemplateMode(true);
    idx.discoverAddress("0xA", 10);
    idx.discoverAddress("0xA", 10);
    try std.testing.expectEqual(@as(usize, 1), idx.templateAddressCount());
}
```

> 该字面量与 `src/indexer.zig:1004-1023` 的既有测试写法一致（新增字段有默认值，无需列出）。
> 注意：`deinit()` 里要释放 `template_addresses` 与 `pending_backfill` 的 dupe 内存，
> 否则 `std.testing.allocator` 会报告泄漏——这是本任务必须实现的一部分。

- [ ] **Step 2: 运行确认失败** → FAIL

- [ ] **Step 3: 实现要点**

```zig
    // 新增字段
    template_mode: bool = false,
    template_addresses: std.ArrayList([]const u8) = .empty,   // 已并入 live 的地址
    template_mutex: std.atomic.Mutex = .unlocked,
    pending_backfill: std.ArrayList(PendingBackfill) = .empty, // { address: []u8, from_block: u64 }
```

```zig
/// 补扫区间：发现区块 -> 探测时的游标（半开区间，避免与主循环重叠）
fn computeBackfillRange(discovered_at_block: u64, current_cursor: u64) [2]u64 {
    if (discovered_at_block >= current_cursor) return .{ 0, 0 };
    return .{ discovered_at_block, current_cursor };
}
```

- `discoverAddress`：去重（线性查 `template_addresses`）→ `pending_backfill.append(.{ .address = dupe, .from_block })` → `database.addTemplateAddress(name, addr, from_block)`；未 `setTemplateMode(true)` 时直接返回
- `deinit`：释放 `template_addresses` 各元素、`pending_backfill` 各元素（`.address` dupe）与两个 ArrayList——漏了会被测试分配器逮住
- 主循环（`runLoop`）每轮：**先**对 `pending_backfill` 逐项 `syncRange(from, to)`（`computeBackfillRange` 取区间）→ 成功后 `database.markTemplateAddressBackfilled` 并移入 `template_addresses` → **再**推进主游标（主 sweep 的 `syncRange` 用 live 地址集合）
- `syncRange` 模板分支：地址取 `self.template_addresses.items`（live）+ 本次补扫地址；`LogFilter.addresses` 传数组；空集合时直接 return（不发 RPC）
- `processLog`：插入事件用 `lg.address`（`Log.address`）作为 `contract_address`；`trackTokenTransferState` 的 `contract_address` 同样用 `lg.address`
- 游标：`sync_state` 的 key 用 `template:<name>`（`self.contract.name` 在模板模式下传模板名即可，无需改表）
- 重组：`detectAndHandleReorg` 模板模式下 `rollbackFromBlock(self.contract.name, …)` + `deleteTemplateAddressesFromBlock(name, fork_point)`

- [ ] **Step 4: 运行测试** → `zig build test` 全绿

- [ ] **Step 5: 提交**

```bash
git add src/indexer.zig
git commit -m "feat: Indexer 模板模式（动态地址集合 + 补扫 + 模板级回滚）"
```

---

## Task 8: 工厂发现喂给模板 + main 装配

**Files:**
- Modify: `src/factory.zig`（`FactoryConfig` 增加 `template_name`；`onFactoryEvent` 分发）
- Modify: `src/config.zig`（`[[factories]]` 解析 `template_name`）
- Modify: `src/main.zig:162-271`（建模板索引器、注册分发表、装配回调）
- Test: `src/config.zig`（解析）+ `src/factory.zig`（分发单测）

**Interfaces:**
- Consumes: Task 6 配置、Task 7 模板 Indexer
- Produces: `FactoryManager.setTemplateHook(ctx: *anyopaque, hook: *const fn (*anyopaque, template_name: []const u8, address: []const u8, from_block: u64) void) void`

- [ ] **Step 1: 写失败测试**

```zig
test "config factory template_name 解析" { /* 断言 fc.template_name == "curve" */ }

test "factory 有 template_name 时走 hook 而非建子索引器" {
    // 用计数 hook，断言 onFactoryEvent 后 hook 被调用 1 次、children 为 0
}
```

- [ ] **Step 2: 运行确认失败** → FAIL

- [ ] **Step 3: 实现**

- `FactoryConfig` 加 `template_name: []const u8`（默认 `""`），字段映射加 `template_name`
- `onFactoryEventInner` 开头：

```zig
        if (fc.template_name.len > 0) {
            if (self.template_hook) |hook| {
                if (self.template_ctx) |ctx| hook(ctx, fc.template_name, child_addr, block_number);
                return;
            }
            log.err("工厂 {s}: 配了 template_name={s} 但未注册模板分发表", .{ fc.name, fc.template_name });
            return;
        }
```

- `main.zig`：在建完 `indexers` 后，按 `cfg.templates` 逐个建模板 Indexer（复用 `indexer.Indexer.init`，`contract` 指向一个**堆上长期存活**的合成 `ContractConfig{ .name = 模板名, .address = "", .events, .abi_path, .from_block }`），`setTemplateMode(true)` + `loadTemplateAddresses()`；用一个 `ArrayList(*Indexer)` 作为分发表，注册 hook 按 `template_name` 查找并调用 `idx.discoverAddress(address, from_block)`
- 模板索引器同样挂 `setEventCallback`（与 `[[contracts]]` 循环合并）与 `setEventTimestampsEnabled`
- 校验：`template.factory_name` 必须在 `[[factories]]` 中存在，否则启动报错 `InvalidConfig`（`config.validate` 里加）

- [ ] **Step 4: 运行测试** → `zig build test` 全绿

- [ ] **Step 5: 提交**

```bash
git add src/factory.zig src/config.zig src/main.zig
git commit -m "feat: 工厂发现驱动模板地址集合 + main 装配"
```

---

# Phase 3：对外接口暴露

## Task 9: REST / GraphQL 暴露 `contract_address`

**Files:**
- Modify: `src/http_server.zig:504-567`（`address` 查询参数 + 缓存 key）
- Modify: `src/graphql.zig:32-42`（`latestEvents.address` 参数）、`72-77`（`Event.contractAddress`）、`336-406`（resolver 传参与填充）
- Test: `src/graphql.zig`（schema 断言）

**Interfaces:**
- Consumes: Task 3 的 `queryEventLogs(address)`、Task 1 的列
- Produces: REST `/events/:contract/:event?address=0x…`；GraphQL `latestEvents(contract, event, address: String)` 且 `Event.contractAddress: String!`

- [ ] **Step 1: 写失败测试**

```zig
test "graphql latestEvents 暴露 contractAddress 与 address 参数" {
    const alloc = std.testing.allocator;
    var schema_def = try Builder.init(alloc);
    defer schema_def.deinit();
    attachResolvers(&schema_def);

    const le = schema_def.query_type.kind.object.fields.getPtr("latestEvents") orelse return error.MissingLatestEvents;
    try std.testing.expect(le.args.get("address") != null);          // 新增参数
    const ev = schema_def.types.getPtr("Event") orelse return error.MissingEventType;
    try std.testing.expect(ev.kind.object.fields.get("contractAddress") != null);
}
```

> 断言方式照 `src/graphql.zig:539-559`（现有 "schema 构建与 resolver 挂载" 测试）；
> 类型注册表字段名若与该测试里的写法不同，以文件内实际的 `schema_def` 访问路径为准。

- [ ] **Step 2: 运行确认失败** → FAIL

- [ ] **Step 3: 实现**

- REST：参数解析加 `} else if (std.mem.eql(u8, key, "address")) { address = try self.alloc.dupe(u8, decoded); address_owned = true; }`（照 `tx_hash` 的 dupe/free 写法），缓存 key 追加 `:ad={s}`，调用处传 `address`
- GraphQL：schema 加 `address = .{ .type = "String" }`；`Event` 加 `.contractAddress = .{ .type = "String!" }`；resolver 取 `args.get("address")` → 传 `queryEventLogs`；构造 obj 时补

```zig
                        const ca = if (row.object.get("contract_address")) |v| (if (v == .string) v.string else "") else "";
                        try obj.data.object.put(try alloc.dupe(u8, "contractAddress"), zg.Value.fromString(alloc, try alloc.dupe(u8, ca)));
```

（注意：`fields` 列表遍历会把 `contract_address` 也当成一个 EventField 输出，保持现状即可，不额外过滤。）

- [ ] **Step 4: 运行测试** → 全绿

- [ ] **Step 5: 提交**

```bash
git add src/http_server.zig src/graphql.zig
git commit -m "feat: REST/GraphQL 暴露 contract_address 并支持按地址过滤"
```

---

## Task 10: JS 事件对象带 `event.contractAddress`

**Files:**
- Modify: `src/indexer.zig:27-33`（`EventHookCallback` 增参数）、调用点 `:679-719`
- Modify: `src/main.zig:246-260`（`CombinedHook.callback`）
- Modify: `src/event_bus.zig`（`Event` + `publish`）
- Modify: `src/js_engine.zig:handleEvent`
- Modify: `src/http_server.zig`（SSE 载荷序列化处补 `contract_address`）
- Test: `src/js_engine.zig`

**Interfaces:**
- Produces: `EventHookCallback(ctx, contract_name, event_name, fields, block_number, block_timestamp, contract_address: []const u8) void`；JS `event.contractAddress`

- [ ] **Step 1: 写失败测试**

```zig
test "js engine event.contractAddress 注入" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();
    try engine.evalScript("var ca = null; ponder.on('Transfer', function(e) { ca = e.contractAddress; });", "t.js");
    const fields = [_]db.DecodedField{.{ .name = "value", .value = "1" }};
    engine.handleEvent("curve", "Transfer", &fields, 5, 1700000123, "0xCLONE");
    try engine.evalScript("if (ca !== '0xCLONE') throw new Error('ca=' + ca);", "c.js");
}
```

- [ ] **Step 2: 运行确认失败** → FAIL

- [ ] **Step 3: 实现**

- `handleEvent(self, contract_name, event_name, fields, block_number, block_timestamp, contract_address)`；在 `event_obj` 上：
```zig
        const ca = c.JS_NewStringLen(ctx, contract_address.ptr, contract_address.len);
        _ = c.JS_SetPropertyStr(ctx, event_obj, "contractAddress", ca);
```
- `EventHookCallback` 与 `CombinedHook.callback` 同步加参数；`indexer.zig` 回调处传 `lg.address`（单合约模式即 `contract.address`）
- `event_bus.Event` 加 `contract_address` 字段（`clone` dupe），`publish` 加参数；SSE JSON 载荷补一个键
- 更新既有 js_engine 测试里 `handleEvent(...)` 的调用（补第 6 个参数 `"0x0"`）

- [ ] **Step 4: 运行测试** → `zig build test` 全绿

- [ ] **Step 5: 提交**

```bash
git add src/indexer.zig src/main.zig src/event_bus.zig src/js_engine.zig src/http_server.zig
git commit -m "feat: JS 事件对象暴露 contractAddress，SSE 载荷同步"
```

---

## Task 11: 端到端验收（Anvil + 多 clone）

**Files:**
- Create: `examples/local-demo/launchpad-demo/`（最小工厂 + clone 合约、配置、脚本）
- Modify: `examples/handlers/README.md`（模板模式用法）

- [ ] **Step 1: 写 demo 合约与配置**

`Launchpad.sol`：`createCurve()` 部署 `Curve` 并 emit `CurveCreated(address curve, address token)`；`Curve.sol`：`buy(uint256)` emit `Buy(address buyer, uint256 amount)`。

配置要点：

```toml
[[contracts]]
name = "launchpad"
address = "0x…"
abi_path = "./examples/local-demo/launchpad-demo/Launchpad.abi"
events = ["CurveCreated"]

[[factories]]
name = "launchpad_factory"
address = "0x…"
abi_path = "./examples/local-demo/launchpad-demo/Launchpad.abi"
creation_event = "CurveCreated"
child_address_field = "curve"
template_name = "curve"          # 关键：喂模板而非建子索引器

[[templates]]
name = "curve"
abi_path = "./examples/local-demo/launchpad-demo/Curve.abi"
events = ["Buy"]
factory_name = "launchpad_factory"
discovery_event = "CurveCreated"
discovery_address_field = "curve"
from_block = 0
```

- [ ] **Step 2: 运行验收脚本**

```bash
bash examples/local-demo/launchpad-demo/run.sh
```

脚本须断言（失败即非零退出）：
1. 部署 3 个 clone，各自 `buy()` 若干次
2. `sqlite3 demo.db "SELECT COUNT(DISTINCT contract_address) FROM event_curve_Buy;"` → `3`
3. `sqlite3 demo.db "SELECT COUNT(*) FROM event_curve_Buy WHERE contract_address='<clone2>';"` → 该 clone 的买次数
4. `SELECT COUNT(*) FROM template_addresses WHERE template='curve';` → `3`
5. `ls demo.db*` 后确认**只有一套** `event_curve_*` 表：`sqlite3 demo.db ".tables" | tr ' ' '\n' | grep -c '^event_curve_'` → `1`

- [ ] **Step 3: 补文档**

`examples/handlers/README.md` 加"模板模式（几千 clone）"小节：配置示例 + `?address=` 查询 + `event.contractAddress` 用法。

- [ ] **Step 4: 提交**

```bash
git add examples/local-demo/launchpad-demo examples/handlers/README.md AGENTS.md CHANGELOG.md
git commit -m "test: launchpad 多 clone 端到端验收 + 模板模式文档"
```

---

## 收尾检查

- [ ] `zig build test` 全绿；`zig build -Doptimize=ReleaseSafe` 通过
- [ ] `AGENTS.md`：数据模型章节补"模板模式 / 地址列 / `proj_` 约定"
- [ ] `CHANGELOG.md`：`[Unreleased]` 记录地址列、模板模式、`[[templates]]`、`?address=`、`event.contractAddress`
- [ ] 老配置（`[[contracts]]` + 老 factory）行为不变，且有测试覆盖
