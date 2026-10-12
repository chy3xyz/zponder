# zponder v0.8.6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 JS handler 拿到事件的 `tx_hash`/`log_index`，让发布二进制不再动态依赖 librocksdb/libpq，并让 `[[factories]]` 能用「模板」而不是「合约地址」作为发现源。

**Architecture:** 三条互不耦合的改动。(A) 把 `eth_rpc` 日志里已有的 `transaction_hash`/`log_index` 沿「索引器 → 事件回调 → JS 引擎/SSE」补齐，纯加参数、不改数据流。(B) 新增构建特性 `-Drocksdb`/`-Dpostgres`（默认 on），关闭时用同名 stub 顶替真实实现，`src/c.h` 按宏条件 include；CI 用 off 构建 + 依赖检查作为发布门禁。(C) `[[factories]]` 新增 `from_template` 发现源（与 `address` 互斥），运行时把「一个索引器只能挂一个 factory_idx」改成可挂多条，使「clone 发出的事件 → 喂给另一个模板」成立。

**Tech Stack:** Zig 0.17.0、内嵌 QuickJS（C）、SQLite（系统库）、RocksDB/PostgreSQL（可选 C 库）、zgraphql 0.7.0、GitHub Actions。

## Global Constraints

- 语言/版本：Zig 0.17.0；`build.zig.zon` 的 `.version` 是唯一版本源（`build.zig` 用 grep 读它）。
- 测试基线：改动前 `zig build test --summary all` = **300/300 通过**（其中 PG 用例在无本地 PG 时按设计 `SkipZigTest`）。每个任务结束时该命令必须仍全绿。
- e2e 基线：`bash examples/local-demo/launchpad-demo/run.sh` 必须始终 **All assertions passed**（A1–A7），它在 8590/8591 端口、仓库根目录写 `demo.db`，跑完需 `rm -f demo.db*`。
- 注释与日志：**中文**，风格对齐现有代码（解释「为什么」，不复述「做了什么」）。
- 向后兼容：既有配置、既有 API 的字段一律不删不改语义；新增字段只能加。
- 提交粒度：一个任务一个 commit，message 用 `type: 中文摘要`（见各任务末尾给出的示例）。
- 不要动用户的 anvil（127.0.0.1:8545）与 `/Users/n0x/w3_proj/__doing_prj/3stock/**` 里的任何文件。

参考阅读（改前必读）：
- `AGENTS.md`（模块地图）、`docs/ARCHITECTURE.md`、`docs/API.md`、`docs/superpowers/plans/2026-10-12-template-indexer.md`（模板机制的原始设计）。

---

# Part A — 事件对象补 `tx_hash` / `log_index`

现状（已核实）：`src/js_engine.zig:548-571` 构造的 event 对象只有 `{ contractAddress, args, block:{number,timestamp} }`；`EventHookCallback`（`src/indexer.zig:27-35`）与调用点（`src/indexer.zig:1252-1255`）都没带这两个值，而它们在同一函数上一行的 `insertEventLog(...)`（`src/indexer.zig:1229-1239`）里就在手边。SSE 载荷（`src/http_server.zig:126-135`）同样没有。

### Task A1: 把 tx_hash / log_index 贯通到 JS event 对象

**Files:**
- Modify: `src/indexer.zig:27-35`（回调类型）、`src/indexer.zig:1252-1255`（调用点）
- Modify: `src/main.zig:403-418`（`CombinedHook.callback`）
- Modify: `src/js_engine.zig:536-573`（`handleEvent`）
- Test: `src/js_engine.zig`（已有 `test "js engine event.contractAddress 注入"`，line 1049 附近）

**Interfaces:**
- Produces: `EventHookCallback = *const fn (ctx: ?*anyopaque, contract_name: []const u8, event_name: []const u8, fields: []const db.DecodedField, block_number: u64, block_timestamp: u64, contract_address: []const u8, tx_hash: []const u8, log_index: u64) void`
- Produces: `JsEngine.handleEvent(self: *JsEngine, contract_name: []const u8, event_name: []const u8, fields: []const db.DecodedField, block_number: u64, block_timestamp: u64, contract_address: []const u8, tx_hash: []const u8, log_index: u64) void`
- Produces（JS 侧可见字段，扁平命名以与既有 `contractAddress` 一致）：`event.transactionHash`（`0x` + 64 hex 字符串）、`event.logIndex`（number）

- [ ] **Step 1: 写失败测试**

在 `src/js_engine.zig` 的 `test "js engine event.contractAddress 注入"` 之后新增：

```zig
test "js engine event.transactionHash / logIndex 注入" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\var th = null, li = null;
        \\ponder.on("Transfer", function(event) {
        \\  th = event.transactionHash;
        \\  li = event.logIndex;
        \\});
    , "test.js");

    const fields = [_]db.DecodedField{.{ .name = "value", .value = "100" }};
    engine.handleEvent(
        "dai",
        "Transfer",
        &fields,
        123,
        1700000000,
        "0xDAI",
        "0xabc0000000000000000000000000000000000000000000000000000000000001",
        7,
    );

    try engine.evalScript(
        \\if (th !== "0xabc0000000000000000000000000000000000000000000000000000000000001")
        \\  throw new Error("txHash = " + th);
        \\if (li !== 7) throw new Error("logIndex = " + li);
    , "check.js");
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: 编译错误 `error: expected 7 arguments, found 9`（`handleEvent` 还没有新参数）。

- [ ] **Step 3: 改回调类型与调用点**

`src/indexer.zig:27-35` 在 `contract_address` 之后加两行：

```zig
pub const EventHookCallback = *const fn (
    ctx: ?*anyopaque,
    contract_name: []const u8,
    event_name: []const u8,
    fields: []const db.DecodedField,
    block_number: u64,
    block_timestamp: u64,
    contract_address: []const u8,
    /// 日志在交易内的位置：`(tx_hash, log_index)` 唯一确定一条日志，
    /// 投影表要靠它给出可跳区块浏览器的稳定主键。
    tx_hash: []const u8,
    log_index: u64,
) void;
```

`src/indexer.zig:1252-1255`：

```zig
                    if (self.factory_callback) |cb| {
                        if (self.factory_ctx) |fctx| {
                            cb(fctx, self.factory_idx, evt.name, db_fields.items, lg.block_number);
                        }
                    }
                    if (self.event_callback) |cb| {
                        const block_ts = self.resolveBlockTimestamp(lg.block_number);
                        cb(
                            self.event_callback_ctx,
                            self.contract.name,
                            evt.name,
                            db_fields.items,
                            lg.block_number,
                            block_ts,
                            source_address,
                            lg.transaction_hash,
                            lg.log_index,
                        );
                    }
```

- [ ] **Step 4: 改 main 的 CombinedHook**

`src/main.zig:403-418` 的 `callback` 加两个参数并转发：

```zig
        fn callback(
            ctx_ptr: ?*anyopaque,
            contract_name: []const u8,
            event_name: []const u8,
            fields: []const db.DecodedField,
            block_number: u64,
            block_timestamp: u64,
            contract_address: []const u8,
            tx_hash: []const u8,
            log_index: u64,
        ) void {
            if (ctx_ptr) |ptr| {
                const self_ptr: *@This() = @ptrCast(@alignCast(ptr));
                self_ptr.script_eng.processEvent(contract_name, event_name, fields, block_number);
                self_ptr.js_eng.handleEvent(contract_name, event_name, fields, block_number, block_timestamp, contract_address, tx_hash, log_index);
                self_ptr.bus.publish(contract_name, event_name, contract_address, fields, block_number, block_timestamp);
            }
        }
```

（`bus.publish` 这一行保持 7 参不变 —— SSE 的补齐是 Task A2。）

- [ ] **Step 5: 改 JS 引擎构造对象**

`src/js_engine.zig:536` 改签名；在 `contractAddress`（line 565）之后、block 对象之前插入：

```zig
        // 交易位置（与 contractAddress 同样是扁平字段，便于 handler 直接拼投影主键）
        const th = c.JS_NewStringLen(ctx, tx_hash.ptr, tx_hash.len);
        _ = c.JS_SetPropertyStr(ctx, event_obj, "transactionHash", th);
        const li = c.JS_NewInt64(ctx, @intCast(log_index));
        _ = c.JS_SetPropertyStr(ctx, event_obj, "logIndex", li);
```

（`JS_NewStringLen` 的用法照抄同函数里 `contractAddress` 那几行的写法：值对象的所有权随 `JS_SetPropertyStr` 转移，不要自己 Free。）

- [ ] **Step 6: 跑测试确认通过**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: `Build Summary: ... tests passed`，无 failed/leaked。

- [ ] **Step 7: 提交**

```bash
git add src/indexer.zig src/main.zig src/js_engine.zig
git commit -m "feat: JS 事件对象注入 transactionHash / logIndex（投影可用真实主键）"
```

### Task A2: SSE 载荷补 tx_hash / log_index

**Files:**
- Modify: `src/event_bus.zig`（`Event` 结构、`publish`、`clone`、`deinit`——照 `contract_address` 的现有写法照抄）
- Modify: `src/main.zig:413`（`bus.publish(...)` 传参）
- Modify: `src/http_server.zig:126-135`（`writeSsePayload`）
- Test: `src/event_bus.zig`（已有 `test "EventBus publish/clone 深拷贝 contract_address 且 deinit 不泄漏"`）

**Interfaces:**
- Produces: `EventBus.publish(self, contract_name, event_name, contract_address, fields, block_number, block_timestamp, tx_hash: []const u8, log_index: u64) void`
- Produces（SSE JSON 新增键）：`"tx_hash":"0x…","log_index":7`

- [ ] **Step 1: 写失败测试**

在 `src/event_bus.zig` 现有 publish/clone 测试之后新增：

```zig
test "EventBus 深拷贝 tx_hash / log_index" {
    const alloc = std.testing.allocator;
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    const fields = [_]db.DecodedField{.{ .name = "v", .value = "1" }};
    bus.publish("dai", "Transfer", "0xDAI", &fields, 10, 1700000000, "0xdead", 3);

    var sub = bus.subscribe(alloc) catch return error.SkipZigTest;
    _ = &sub;
    // 见 Step 3：断言订阅者拿到的 Event 里 tx_hash 是 dupe 出来的独立切片，
    // 且释放原字符串后仍可读。
}
```

> 实现者注意：`EventBus` 的订阅 API 以现有测试（`src/event_bus.zig:171` 起）为准 —— 先照抄那个测试的订阅/取事件写法，再把断言换成本任务要验的三条：`tx_hash` 内容相等、`log_index == 3`、`tx_hash.ptr` 不等于传入的字面量指针（证明深拷贝）。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: 编译错误（`publish` 参数个数不符）。

- [ ] **Step 3: 实现**

- `Event` 加字段 `tx_hash: []const u8, log_index: u64`；`Event.clone` 里 `tx_hash` 用 `alloc.dupe`（同 `contract_address`）；`Event.deinit` 里释放（同 `contract_address`）。
- `publish` 加两个参数并透传给 `clone`。
- `src/main.zig:413` 改为 `self_ptr.bus.publish(contract_name, event_name, contract_address, fields, block_number, block_timestamp, tx_hash, log_index);`
- `src/http_server.zig:126-135` 的 `writeSsePayload` 在 `block_number` 之后加：

```zig
    try w.print("{{\"contract\":\"{s}\",\"contract_address\":\"{s}\",\"block_number\":{d},\"tx_hash\":\"{s}\",\"log_index\":{d},\"fields\":{{", .{
        ev.contract_name,
        ev.contract_address,
        ev.block_number,
        ev.tx_hash,
        ev.log_index,
    });
```

- [ ] **Step 4: 跑测试确认通过 + 手工看一次 SSE 输出**

Run: `zig build test --summary all 2>&1 | tail -20` → 全绿。
Run（可选冒烟）：在 `examples/local-demo/launchpad-demo/` 目录按 run.sh 的方式起一次，`curl -N http://127.0.0.1:8591/stream` 应能看到 `"tx_hash":"0x…","log_index":N`。

- [ ] **Step 5: 提交**

```bash
git add src/event_bus.zig src/main.zig src/http_server.zig
git commit -m "feat: SSE 载荷注入 tx_hash / log_index"
```

### Task A3: 文档同步（A 部分）

**Files:**
- Modify: `docs/API.md`（`/stream` 的 SSE 载荷示例、Handler 事件对象说明）
- Modify: `README.md`（handler 可用字段表，若有）
- Modify: `AGENTS.md`（若其模块表提到 event 对象字段）

- [ ] **Step 1: 找出需要改的位置**
Run: `grep -rn "contractAddress\|block.timestamp" README.md docs/*.md AGENTS.md | head -20`
- [ ] **Step 2: 补 `transactionHash` / `logIndex` 两行，SSE 示例补两个键**
- [ ] **Step 3: 提交**

```bash
git add README.md docs/API.md AGENTS.md
git commit -m "docs: 补 transactionHash / logIndex（事件对象与 SSE 载荷）"
```

---

# Part B — RocksDB / PostgreSQL 可选 + 发布门禁

现状（已核实）：`src/c.h:2` 无条件 `#include <rocksdb/c.h>`；`build.zig:100-102`、`126-128` 无条件 `linkSystemLibrary("rocksdb")`/`("pq")`；`src/rocksdb.zig`（152 行，唯一碰 C API 的文件，被 `db.zig:7` 与 `root.zig:17` 引用）；`src/pg.zig` 同理碰 libpq。因此发布二进制动态依赖 `librocksdb.11.dylib`（CI 用 brew rocksdb 11.8.1 构建）与 `libpq.5.dylib`，在干净机器上跑不起来 —— 实测 `zponder@0.8.5` 的 `bin/darwin-arm64/zponder` 直接 dyld 报错。

**设计要点（照抄）**：关闭特性时**不删** `.rocksdb` / `.postgresql` 这两个 `BackendType` 枚举值（删了要改 ~30 处 switch 与比较），而是让打开后端时报 `error.RocksDbSupportNotCompiled` / `error.PostgresSupportNotCompiled`。实现方式是把真实实现**原样搬到** `src/rocksdb_impl.zig`（`src/pg_impl.zig`），新增极小的 `src/rocksdb_stub.zig`（`src/pg_stub.zig`）提供同签名的报错实现，`src/rocksdb.zig`（`src/pg.zig`）只做 comptime 分发。

### Task B1: build.zig 开关 + c.h 宏守卫 + 依赖检查

**Files:**
- Modify: `build.zig:24-33`（选项）、`40-67`（路径表）、`69-78`（translate-c）、`100-108`、`126-134`（链接与路径）
- Modify: `src/c.h`
- Test: 命令行验证（无单测）

**Interfaces:**
- Produces: 构建选项 `-Drocksdb=<bool>`、`-Dpostgres=<bool>`（默认 `true`）；`build_options.rocksdb` / `build_options.postgres`（`@import("build_options")` 可见）

- [ ] **Step 1: 加选项与 options 字段**

`build.zig` 在 `const options = b.addOptions();` 之后：

```zig
    // 发布二进制不许动态依赖 librocksdb / libpq（干净机器上根本没有），
    // 故这两条后端做成可选；关闭时由 *_stub.zig 顶替真实实现并报错。
    const rocksdb = b.option(bool, "rocksdb", "编译 RocksDB 后端（关闭后不再链接 librocksdb）") orelse true;
    const postgres = b.option(bool, "postgres", "编译 PostgreSQL 后端（关闭后不再链接 libpq）") orelse true;
    options.addOption(bool, "rocksdb", rocksdb);
    options.addOption(bool, "postgres", postgres);
```

- [ ] **Step 2: c.h 条件 include**

`src/c.h` 全文替换为：

```c
#include <sqlite3.h>
#include "quickjs/quickjs.h"

// 可选后端：宏由 build.zig 的 -Drocksdb / -Dpostgres 决定（未定义时按开启处理，
// 保证 IDE/手工 translate-c 不受影响）。
#ifndef ZPONDER_ROCKSDB
#define ZPONDER_ROCKSDB 1
#endif
#ifndef ZPONDER_POSTGRES
#define ZPONDER_POSTGRES 1
#endif

#if ZPONDER_ROCKSDB
#include <rocksdb/c.h>
#endif

#if ZPONDER_POSTGRES
#include <libpq-fe.h>
#endif
```

- [ ] **Step 3: translate-c 传宏 + 路径/链接条件化**

- `c_translate.defineCMacro("ZPONDER_ROCKSDB", if (rocksdb) "1" else "0");` 与 `..._POSTGRES` 同理（`defineCMacro` 在 `std.Build.Step.TranslateC`，line 156）。
- 把 `include_paths` / `lib_paths` 拆成 `common_*` 与后端各自的两项：rocksdb 的 `/opt/homebrew/opt/rocksdb/{include,lib}`、`/usr/local/opt/rocksdb/{include,lib}` 只在 `rocksdb` 为真时加入；libpq 的 `/opt/homebrew/opt/libpq/lib`、`/usr/local/opt/libpq/lib` 只在 `postgres` 为真时加入（注意：`addLibraryPath`/`addIncludePath` 对不存在的目录会报错，所以**必须**条件化，不能只是留着不用）。
- 四处 `linkSystemLibrary("rocksdb"/"pq")`（100/101、126/127）分别包在 `if (rocksdb) { ... }` / `if (postgres) { ... }` 里；`sqlite3` 保持无条件。

- [ ] **Step 4: 验证两种构建**

```bash
zig build test --summary all 2>&1 | tail -5                 # 默认（两个后端 on）→ 仍全绿
zig build -Doptimize=ReleaseFast                            # 默认构建
otool -L zig-out/bin/zponder | grep -E "rocksdb|libpq"      # 应有两条
zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false
otool -L zig-out/bin/zponder | grep -E "rocksdb|libpq" || echo "OK: 无 rocksdb/libpq 依赖"
./zig-out/bin/zponder version
```

Expected: 最后一条打印 `OK: 无 rocksdb/libpq 依赖`，`version` 正常输出（此步还会因 Task B2 未做而**链接期报错**——B2 做完后再回来重跑本步，届时必须通过）。

- [ ] **Step 5: 提交**

```bash
git add build.zig src/c.h
git commit -m "build: -Drocksdb / -Dpostgres 可选后端（发布二进制不再动态依赖 librocksdb/libpq）"
```

### Task B2: 源码侧 guard（stub 顶替）+ 测试跳过

**Files:**
- Rename: `src/rocksdb.zig` → `src/rocksdb_impl.zig`；新增 `src/rocksdb_stub.zig`；`src/rocksdb.zig` 重写为分发器
- Rename: `src/pg.zig` → `src/pg_impl.zig`；新增 `src/pg_stub.zig`；`src/pg.zig` 重写为分发器
- Modify: `src/db.zig`（`initRocksDB`/PG 初始化处的错误语义；5 个 rocksdb 测试 + PG 测试加特性跳过）
- Test: 两种构建模式下 `zig build test`

**Interfaces:**
- Produces: `src/rocksdb.zig` 导出与今天**完全一致**的 `Client` / `WriteBatch` / `Iterator` API（调用方不用改）
- Produces: 关闭特性时的错误 `error.RocksDbSupportNotCompiled` / `error.PostgresSupportNotCompiled`

- [ ] **Step 1: 先确认 stub 的 API 面**

```bash
grep -n "^pub \|pub fn " src/rocksdb.zig src/pg.zig | head -40
```

- [ ] **Step 2: 移动实现并写分发器**

```bash
git mv src/rocksdb.zig src/rocksdb_impl.zig
git mv src/pg.zig src/pg_impl.zig
```

`src/rocksdb.zig`（新内容）：

```zig
//! RocksDB 后端入口：按构建特性在真实实现与 stub 之间编译期分发。
//! 关闭 `-Drocksdb` 时 `rocksdb_impl.zig` 不会被分析，因此不需要系统里有 librocksdb。
const build_options = @import("build_options");

const impl = if (build_options.rocksdb) @import("rocksdb_impl.zig") else @import("rocksdb_stub.zig");

pub const Client = impl.Client;
pub const WriteBatch = impl.WriteBatch;
pub const Iterator = impl.Iterator;
pub const Status = impl.Status;
```

（`Status` 等其它导出名按 Step 1 的清单补齐；stub 必须导出**同一个名字集合**，否则这里的 `impl.X` 会编译失败。）

`src/rocksdb_stub.zig`：

```zig
//! `-Drocksdb=false` 时的占位实现：签名与 rocksdb_impl 一致，调用即报错。
//! 保留 `.rocksdb` 这个 BackendType 枚举值是为了不牵动 db.zig 里 ~30 处
//! `backend_type == .rocksdb` 分支；真正的拦截点在 Client.open()。
const std = @import("std");

pub const Client = struct {
    pub fn open(path: []const u8) !Client {
        _ = path;
        return error.RocksDbSupportNotCompiled;
    }
    pub fn close(self: *Client) void {
        _ = self;
    }
    // ...其余方法按 Step 1 清单逐个补齐，函数体一律 return error.RocksDbSupportNotCompiled
};
```

- [ ] **Step 3: db.zig 的错误语义与测试跳过**

- `src/db.zig` 打开 rocksdb 的分支（line 92-93 一带）保持不变（错误自己冒上来）；在 `initRocksDB`（137-141）里把 stub 的报错换成更可读的信息：

```zig
fn initRocksDB(path: []const u8) !rocksdb.Client {
    if (!@import("build_options").rocksdb) {
        log.err("此二进制未编译 RocksDB 后端（构建时用了 -Drocksdb=false），请改用 sqlite/postgresql 或自行构建", .{});
        return error.RocksDbSupportNotCompiled;
    }
    return rocksdb.Client.open(path);
}
```

- 5 个 rocksdb 测试（`src/db.zig:3061`、`3081`、`3095`、`3114`、`3760`）在函数体第一行加：

```zig
    if (!@import("build_options").rocksdb) return error.SkipZigTest;
```

- PG 测试（`src/db.zig` 中所有 `return error.SkipZigTest` 的 PG 用例，含 2803/3203 等）同样在首行加：

```zig
    if (!@import("build_options").postgres) return error.SkipZigTest;
```

- `src/main.zig` 的两个 rocksdb 校验测试（1025、1076）**不需要**改：它们只解析 TOML，不碰 C API；但如果 Step 4 显示 `rocks_plain` 的期望被打破（`checkTemplateBackendSupport` 用 `db_type="rocksdb"` 的配置做「合法」对照），则把该断言改成「特性关闭时同样应报错」，并保持测试名不变。

- [ ] **Step 4: 两种模式全量测试**

```bash
zig build test --summary all 2>&1 | tail -5                                  # 默认 on
zig build test -Drocksdb=false -Dpostgres=false --summary all 2>&1 | tail -5 # 两个 off
zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false
otool -L zig-out/bin/zponder | grep -E "rocksdb|libpq" || echo "OK: 无 rocksdb/libpq 依赖"
./zig-out/bin/zponder version
sqlite3 --version >/dev/null && echo "sqlite3 仍在（唯一允许的系统库）"
```

Expected: 两种模式都全绿（off 模式会有若干 skipped，属预期）；`otool -L` 只剩 `libSystem.B.dylib` 与 `libsqlite3.dylib`。

- [ ] **Step 5: 提交**

```bash
git add -A src/
git commit -m "build: RocksDB/PostgreSQL 关闭时用 stub 顶替实现，测试按特性跳过"
```

### Task B3: CI 用 off 构建 + 发布门禁

**Files:**
- Modify: `.github/workflows/publish.yml:49-77`（依赖安装、Build、Test、新增门禁步骤）
- Modify（可选）：`npm/zponder/README.md`（缺后端时的报错说明）

- [ ] **Step 1: 依赖只留 sqlite3**

- macOS：`brew install sqlite3`（删掉 `rocksdb libpq`）
- Linux：`sudo apt-get install -y -qq libsqlite3-dev`（删掉 `librocksdb-dev libpq-dev` 及那段 `test -f .../libpq-fe.h` 检查）

- [ ] **Step 2: Build/Test 带 off 开关，加依赖门禁**

```yaml
      - name: Build
        run: zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false

      - name: Test
        run: zig build test -Drocksdb=false -Dpostgres=false

      # 门禁：发布出去的二进制必须在干净机器上能跑 —— 不许动态依赖 librocksdb/libpq。
      # 只"能运行"不算证据（runner 上恰好装了这些库），必须查动态依赖表。
      - name: Assert binary has no optional-backend deps
        run: |
          set -e
          BIN=zig-out/bin/zponder
          ./"$BIN" version
          if [ "$RUNNER_OS" = "macOS" ]; then
            otool -L "$BIN"
            ! otool -L "$BIN" | grep -E "rocksdb|libpq"
          else
            ldd "$BIN"
            ! ldd "$BIN" | grep -E "rocksdb|libpq"
          fi
```

- [ ] **Step 3: 本地预演门禁命令**

```bash
zig build -Doptimize=ReleaseFast -Drocksdb=false -Dpostgres=false
./zig-out/bin/zponder version && ! otool -L zig-out/bin/zponder | grep -E "rocksdb|libpq" && echo "GATE OK"
```

- [ ] **Step 4: 提交**

```bash
git add .github/workflows/publish.yml npm/zponder/README.md
git commit -m "ci: 发布改用无 rocksdb/libpq 的构建，并加动态依赖门禁"
```

### Task B4: 文档（B 部分）

**Files:**
- Modify: `README.md`（构建矩阵：默认带两个后端；发布包为 sqlite-only，缺后端时怎么自建）
- Modify: `AGENTS.md`（Build & Run 一节补 `-Drocksdb=false`）

- [ ] **Step 1: 补构建矩阵与「npm 包为什么没有 rocksdb/postgres」说明**
- [ ] **Step 2: 提交**

```bash
git add README.md AGENTS.md
git commit -m "docs: 可选后端构建矩阵（默认含 rocksdb/postgres，发布包为 sqlite-only）"
```

---

# Part C — `[[factories]]` 支持以模板为发现源

现状（已核实）：发现只在「具体合约地址」上成立 —— `src/main.zig:352-368` 的关联循环用 `fc.address == idx.contract.address` 匹配，而模板索引器的合成配置 `address = ""`（`src/main.zig:288-303`）永远匹配不上，于是 `factory_callback` 恒为 null，clone 的事件永远进不了发现钩子。同时 `idx.factory_idx: usize` 是单值，同地址配两条规则会被 validate 拒绝（`src/config.zig:1205`），且运行时后者覆盖前者。真实场景：pair 地址来自 clone 的 `LiquidityMigrated`（3stock 的 `BondingCurve.sol:577`），所以 pair 发现今天无解。

新配置形态（互斥于 `address`）：

```toml
[[factories]]
name = "pair_discovery"
from_template = "curve"        # 新增：发现源是本模板地址集合里的事件
creation_event = "Paired"
child_address_field = "pair"
template_name = "pair"         # 目标模板（语义不变）
```

### Task C1: config 解析 + 校验 + 单测

**Files:**
- Modify: `src/config.zig`：`FactoryConfig`（98-110）、工厂解析分支（718 一带）、validate 工厂段（1206 起）、`FactoryConfig.deinit`、`hasDuplicateFactoryAddress`
- Test: `src/config.zig` 末尾测试区（已有 `loadTemplateFixture` 辅助可复用）

**Interfaces:**
- Produces: `FactoryConfig.from_template: []const u8`（空串 = 用 `address` 作发现源）
- 语义：`address` 与 `from_template` **恰有其一**；`from_template` 必须指向已定义的 `[[templates]]`；`from_template` 与 `address` 都只能配一个发现源的场景下，`child_abi_path` 与 `from_template` 互斥（模板源只能喂模板，避免重新引入无界子索引器）

- [ ] **Step 1: 写失败测试**

```zig
test "config factories from_template 解析与校验" {
    const alloc = std.testing.allocator;

    // 合法：模板源 + 模板目标，互斥字段都没配
    const ok_sql = "[[factories]]\nname = \"pair_disc\"\nfrom_template = \"curve\"\ncreation_event = \"Paired\"\nchild_address_field = \"pair\"\ntemplate_name = \"pair\"\n";
    var ok = try loadTemplateFixture(alloc, ok_sql, "curve_disc_tpl");
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("curve", ok.factories[1].from_template);
    try validate(&ok);

    // address 与 from_template 同时配 → 拒
    const both = "[[factories]]\nname = \"x\"\naddress = \"0x1\"\nfrom_template = \"curve\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\ntemplate_name = \"pair\"\n";
    var b = try loadTemplateFixture(alloc, both, "curve_disc_tpl");
    defer b.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&b));

    // from_template 指向不存在的模板 → 拒
    const ghost = "[[factories]]\nname = \"x\"\nfrom_template = \"nope\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\ntemplate_name = \"pair\"\n";
    var g = try loadTemplateFixture(alloc, ghost, "curve_disc_tpl");
    defer g.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&g));

    // 都不要（既无 address 又无 from_template）→ 拒
    const none = "[[factories]]\nname = \"x\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\ntemplate_name = \"pair\"\n";
    var n = try loadTemplateFixture(alloc, none, "curve_disc_tpl");
    defer n.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&n));
}
```

> 实现者注意：`loadTemplateFixture(alloc, extra_factory_sql, ...)` 的现有签名与它注入的 `[[templates]]` 名字，以 `src/config.zig` 里既有用法（`test "config validate: 重复的工厂 address 被拒"`，line 1928 附近）为准，按其实际语义调整上面的调用；`ok.factories[1]` 的下标同理。

- [ ] **Step 2: 跑测试确认失败** → Run: `zig build test --summary all 2>&1 | tail -20`（预期编译错误：`from_template` 不存在）

- [ ] **Step 3: 实现解析与校验**

- `FactoryConfig` 加字段 `from_template: []const u8`；`deinit` 里 `alloc.free(self.from_template)`。
- 解析分支加：

```zig
            } else if (std.mem.eql(u8, key, "from_template")) {
                alloc.free(cf.from_template);
                cf.from_template = try unquote(alloc, value);
```

（`cf` 的初始化处要 `try alloc.dupe(u8, "")`，与 `name`/`abi_path` 一致。）

- validate 工厂段改为：

```zig
        if (f.address.len > 0 and f.from_template.len > 0) {
            log.err("配置错误: 工厂合约 {s} 的 address 与 from_template 互斥（只能选一种发现源）", .{f.name});
            errors += 1;
        } else if (f.address.len == 0 and f.from_template.len == 0) {
            log.err("配置错误: 工厂合约 {s} 必须配置 address 或 from_template 之一作为发现源", .{f.name});
            errors += 1;
        } else if (f.address.len > 0) {
            if (hasDuplicateFactoryAddress(cfg, fi)) {
                // 同一合约地址配两条发现规则时，运行期只会用最后一条（factory_idxs 的旧单值语义），
                // 先配的那条静默不发现；要多条规则请用 from_template 或拆成不同事件。
                log.err("配置错误: 工厂 {s} 的 address {s} 与前面的工厂重复（同一合约地址只能声明一次）", .{ f.name, f.address });
                errors += 1;
            }
        } else if (!hasTemplateNamed(cfg, f.from_template)) {
            log.err("配置错误: 工厂合约 {s} 的 from_template '{s}' 未在 [[templates]] 中定义", .{ f.name, f.from_template });
            errors += 1;
        }
```

- `hasDuplicateFactoryAddress` 只比较 `address`（保持现语义，`from_template` 的重复由「同一目标模板只能被一个工厂喂」（携转约束 5 的反向一致性）间接约束）。
- 保留既有规则：`child_abi_path` 与 `template_name` 互斥、`template_name` 必须存在、模板必须反向指回工厂。再加一条：

```zig
        if (f.from_template.len > 0 and f.child_abi_path.len > 0) {
            log.err("配置错误: 工厂合约 {s} 用 from_template 作发现源时不能再配 child_abi_path（模板源只喂模板）", .{f.name});
            errors += 1;
        }
        if (f.from_template.len > 0 and std.mem.eql(u8, f.from_template, f.template_name)) {
            log.err("配置错误: 工厂合约 {s} 的 from_template 与 template_name 相同（自环发现）", .{f.name});
            errors += 1;
        }
```

- [ ] **Step 4: 跑测试确认通过** → 全绿
- [ ] **Step 5: 提交**

```bash
git add src/config.zig
git commit -m "feat(config): [[factories]] 支持 from_template 发现源（与 address 互斥）"
```

### Task C2: 运行期关联与多条目分发

**Files:**
- Modify: `src/indexer.zig:293-297`（字段）、`329-332`、`388-391`（init）、`1252-1255`（分发）、`1552-1554`/`1629-1631`/`1984-1986`（测试构造）、`Indexer.deinit`
- Modify: `src/main.zig:352-368`（关联循环）
- Test: `src/main.zig`（已有 `test "模板分发表: 工厂发现经 hook 喂入对应模板的地址集合"`）

**Interfaces:**
- Produces: `Indexer.factory_idxs: std.ArrayListUnmanaged(usize)`（替代 `factory_idx: usize`；由 Indexer 自己 deinit，main 追加）
- Produces: 关联规则 —— `fc.address.len > 0` 时按 `fc.address == idx.contract.address` 匹配；`fc.from_template.len > 0` 时按 `fc.from_template == idx.contract.name` 匹配（模板索引器的合成配置 `name` 就是模板名，且 validate 已禁止模板名与合约名重名）

- [ ] **Step 1: 写失败测试**（在既有 hook 测试之后新增）

```zig
test "模板分发表: 由模板事件发现（from_template）喂入第二个模板" {
    const alloc = std.testing.allocator;
    // ...从既有测试照抄 backend/io/db/factory 的装配...
    // 1) 两个模板 indexer：source("curve") 与 dest("pair")
    // 2) 一个 [[factories]] 条目：from_template="curve", template_name="pair",
    //    creation_event="Paired", child_address_field="pair"
    // 3) 断言：对 source 索引器调用它的 factory 回调（等价于它的日志里出现 Paired）
    //    → dest 模板的地址集合里出现该 pair 地址，source 的地址集合不变
}
```

> 实现者注意：既有测试（`src/main.zig:902` 起）已经把「工厂 → 模板」的 hook 路径搭好了，这里只是把工厂条目从 `address` 换成 `from_template`；断言用的 API（`template_addresses` 查询、`registry.find(...)`）照抄既有测试。

- [ ] **Step 2: 跑测试确认失败** → 编译错误（`from_template` 字段现在有了，但关联匹配与多条目还不支持 → 断言失败）

- [ ] **Step 3: 把 factory_idx 改成列表**

- `src/indexer.zig`：字段改 `factory_idxs: std.ArrayListUnmanaged(usize) = .empty`；`init` 参数由 `factory_idx: usize` 改为不再接收（改为 `factory_idxs` 由调用方在 init 之后 append），或接收 `[]const usize` 并 dupe —— **二选一，以改动最小为准**；`Indexer.deinit` 里 `self.factory_idxs.deinit(self.alloc)`。
- 分发点：

```zig
                    if (self.factory_callback) |cb| {
                        if (self.factory_ctx) |fctx| {
                            // 一个发现源（合约地址或模板）可以挂多条工厂规则：
                            // 每条规则各有 creation_event / child_address_field / 目标模板。
                            for (self.factory_idxs.items) |fi| {
                                cb(fctx, fi, evt.name, db_fields.items, lg.block_number);
                            }
                        }
                    }
```

- `src/main.zig` 关联循环：

```zig
        // 一个索引器可以是一个或多个工厂条目的发现源：
        //  · address 源 —— 匹配具体合约地址（老语义）
        //  · from_template 源 —— 匹配模板索引器（其合成配置的 name 即模板名）
        for (cfg.factories, 0..) |fc, fi| {
            for (indexers.items) |*idx| {
                const is_source = if (fc.from_template.len > 0)
                    std.mem.eql(u8, fc.from_template, idx.contract.name)
                else
                    std.mem.eql(u8, fc.address, idx.contract.address);
                if (!is_source) continue;
                idx.factory_ctx = &factory_manager.?;
                idx.factory_callback = factory.FactoryManager.onFactoryEventCallback;
                try idx.factory_idxs.append(alloc, fi);
                log.info("工厂 {s}: 已关联到索引器 {s}", .{ fc.name, idx.contract.name });
            }
        }
```

（把 `break` 去掉，让同一索引器把多条规则全收下。）

- [ ] **Step 4: 跑测试确认通过 + 两种构建模式 + e2e**

```bash
zig build test --summary all 2>&1 | tail -5
bash examples/local-demo/launchpad-demo/run.sh 2>&1 | tail -5   # 老语义（address 源）必须仍然全绿
rm -f demo.db*
```

- [ ] **Step 5: 提交**

```bash
git add src/indexer.zig src/main.zig
git commit -m "feat: 工厂发现源支持模板（from_template），一个源可挂多条规则"
```

### Task C3: demo 端到端（clone 事件 → 第二个模板）

**Files:**
- Modify: `examples/local-demo/launchpad-demo/Curve.sol`（加 `event Paired(address indexed pair)` + `function setPair(address)`）
- Create: `examples/local-demo/launchpad-demo/Pair.sol`（`event Swap(uint256 a, uint256 b)` + `function swap(uint256,uint256)`）
- Create: `examples/local-demo/launchpad-demo/Pair.abi`（用 solc 生成，见 Step 2）
- Modify: `examples/local-demo/launchpad-demo/Curve.abi`（同 solc 重新生成）
- Modify: `examples/local-demo/launchpad-demo/config.toml`（加 `pair` 模板 + `from_template` 工厂条目）
- Modify: `examples/local-demo/launchpad-demo/run.sh`（编译 Pair、部署、setPair、swap、断言）

**Interfaces:**
- 新增表：`event_pair_Swap`；新增 `template_addresses` 行 `('pair', <pair 地址>, …)`

- [ ] **Step 1: 加 Solidity**

`Curve.sol` 在 `event Buy(...)` 旁加：

```solidity
    event Paired(address indexed pair);

    function setPair(address pair) external {
        emit Paired(pair);
    }
```

`Pair.sol`：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// demo 里的「毕业后市场」占位合约：只需要发出一个模板要索引的事件。
contract Pair {
    event Swap(uint256 amountIn, uint256 amountOut);

    function swap(uint256 amountIn, uint256 amountOut) external {
        emit Swap(amountIn, amountOut);
    }
}
```

- [ ] **Step 2: 重新生成 ABI 并保证不漂移**

```bash
cd examples/local-demo/launchpad-demo
solc --abi --bin --optimize --overwrite Curve.sol Pair.sol Launchpad.sol -o /tmp/demo-abi
cp /tmp/demo-abi/Curve.abi Curve.abi
cp /tmp/demo-abi/Pair.abi Pair.abi
```

（run.sh 里已有「committed ABI 与 solc 输出比对」的 python 检查，Step 4 需要在它的 `for name in (...)` 里加 `Pair`。）

- [ ] **Step 3: config 加模板与工厂条目**

```toml
# ── 由 clone 事件发现 pair（from_template 发现源）─────────────────────────
[[factories]]
name = "pair_discovery"
from_template = "curve"
creation_event = "Paired"
child_address_field = "pair"
template_name = "pair"
max_children = 100000

[[templates]]
name = "pair"
abi_path = "./examples/local-demo/launchpad-demo/Pair.abi"
events = ["Swap"]
factory_name = "pair_discovery"
from_block = 0
poll_interval_ms = 200
```

- [ ] **Step 4: run.sh 加步骤与断言**

在既有 `[4/7]`（create clones + buys）之后、`[5/7]`（start zponder）之前插入：部署 `Pair`、对 clone #1 调 `setPair(<pair>)`、对 pair 调 `swap(1,2)`；把步骤号从 `[x/7]` 全局改成 `[x/9]`。在断言段追加两条：

```bash
check_eq "A8 pair template Swap rows" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM event_pair_Swap;")"
check_eq "A9 template_addresses pair row" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM template_addresses WHERE template='pair';")"
```

（`check_eq` 的签名与 `$DB` 变量名以 run.sh 现状为准，照抄邻近断言。）

- [ ] **Step 5: 跑 e2e**

```bash
bash examples/local-demo/launchpad-demo/run.sh 2>&1 | tail -15
rm -f demo.db*
```

Expected: `All assertions passed.`（含 A8/A9）

- [ ] **Step 6: 提交**

```bash
git add examples/local-demo/launchpad-demo/
git commit -m "test(demo): clone 事件经 from_template 喂入第二个模板（pair）端到端"
```

### Task C4: 文档（C 部分）

**Files:**
- Modify: `docs/ARCHITECTURE.md`（发现机制一节：两种发现源）
- Modify: `README.md` + `AGENTS.md`（`[[factories]]` 键表补 `from_template`）
- Modify: `docs/API.md` 若涉及 `/contracts` 的工厂字段输出

- [ ] **Step 1: 补说明：`address` / `from_template` 二选一、一个源可多条规则、模板源只能喂模板**
- [ ] **Step 2: 提交**

```bash
git add docs/ README.md AGENTS.md
git commit -m "docs: [[factories]] 的两种发现源（address / from_template）"
```

---

# Part D — 发版 v0.8.6

### Task D1: 版本、CHANGELOG、tag、发布核验

**Files:**
- Modify: `build.zig.zon`（`.version = "0.8.6"`）
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 全量验收（三种构建）**

```bash
zig build test --summary all 2>&1 | tail -5
zig build test -Drocksdb=false -Dpostgres=false --summary all 2>&1 | tail -5
zig build --release=safe 2>&1 | tail -3
bash examples/local-demo/launchpad-demo/run.sh 2>&1 | tail -5 && rm -f demo.db*
```

- [ ] **Step 2: 写 CHANGELOG（Keep a Changelog 风格，中文，对齐既有条目语气）**

```markdown
## [0.8.6] - 2026-10-13

### Added
- **JS 事件对象新增 `event.transactionHash` / `event.logIndex`**，SSE 载荷同步新增
  `tx_hash` / `log_index`：投影表可用 `(tx_hash, log_index)` 作真实主键并跳区块浏览器。
- **`[[factories]]` 支持 `from_template` 发现源**：以某个模板地址集合里的事件作为发现源
  （与 `address` 互斥），一个发现源可挂多条规则 —— clone 发出的事件终于可以喂给第二个模板
  （例：`LiquidityMigrated.pair` → pair 模板）。

### Changed
- **RocksDB / PostgreSQL 变为可选构建特性**（`-Drocksdb=false -Dpostgres=false`）。关闭时对应
  后端在启动时明确报错，不再链接 librocksdb / libpq。npm 预编译二进制改用该模式构建 ——
  此前它们动态依赖 `librocksdb.11.dylib`（CI 的 brew rocksdb）与 `libpq.5.dylib`，在干净机器上
  直接 dyld 失败，等于不可用。
- CI 新增发布门禁：构建后 `otool -L` / `ldd` 检查二进制不得依赖 rocksdb/libpq，并实跑
  `zponder version`。
```

- [ ] **Step 3: bump 版本 + 提交 + 打 tag + 推送**

```bash
# build.zig.zon: .version = "0.8.6"
git add build.zig.zon CHANGELOG.md
git commit -m "release: v0.8.6 - 事件交易位置字段、可选后端、模板发现源"
git tag -a v0.8.6 -m "zponder v0.8.6"
git push origin main && git push origin v0.8.6
```

- [ ] **Step 4: 核验发布（必须等 CI 跑完）**

```bash
gh run list --limit 3 --json displayTitle,status,conclusion -q '.[] | "\(.status)/\(.conclusion // "-") \(.displayTitle)"'
curl -s -o /dev/null -w "%{http_code}\n" https://registry.npmjs.org/zponder/0.8.6
curl -s -H 'Cache-Control: no-cache' https://registry.npmjs.org/zponder | python3 -c "import json,sys;print(json.load(sys.stdin)['dist-tags'])"
# 抽验 macOS 二进制真的能跑（这是本次发布的核心目的）
cd /tmp && rm -rf npcheck086 && mkdir npcheck086 && cd npcheck086
curl -sL -o z.tgz https://registry.npmjs.org/zponder/-/zponder-0.8.6.tgz && tar -xzf z.tgz
./package/bin/darwin-arm64/zponder version
```

Expected: `0.8.6`；`dist-tags.latest = 0.8.6`；最后一条打印版本信息而**不是** dyld 报错。
（注意：本机 npm 走代理会缓存，`npm view` 可能落后；以 `/zponder/0.8.6` 端点与 `?no-cache` 的 packument 为准。）

- [ ] **Step 5: 更新本机 PATH 上的二进制**

```bash
cd /Users/n0x/w4_proj/zig_ws/zponder
zig build -Doptimize=ReleaseFast && ./zig-out/bin/zponder install && zponder version
```

---

## Self-Review

**1. Spec coverage**

| 需求 | 落在哪个任务 |
|---|---|
| JS 事件对象补 tx_hash/log_index | A1（SSE 见 A2，文档 A3） |
| RocksDB 可选 | B1（开关+守卫）、B2（stub+测试）、B4（文档） |
| 二进制自带依赖 / 发布门禁 | B1（构建）、B3（CI 门禁+实跑）、D1 Step 4（发布后抽验 macOS 二进制能跑） |
| `[[factories]]` 模板发现源 | C1（配置+校验）、C2（运行期分发）、C3（demo e2e）、C4（文档） |
| 一个源多条规则 | C2（`factory_idxs` 列表 + 去掉 `break`） |

**2. Placeholder scan**：B2 的 stub 方法清单与 C2/C3 的测试装配标注为「照抄既有写法」并给出确切锚点（文件:行），这是让实现者去读真实代码，不是遗留待定项；其余步骤都给了可直接粘贴的代码或命令。

**3. Type consistency**：`EventHookCallback` / `handleEvent` 的 9 参签名在 A1 定义、A2 的 `publish` 保持 7 参（SSE 单独走 8 参的 `publish`），两处不同是刻意的（JS 需要 `block_timestamp`，SSE 载荷当前不下发时间戳）；`FactoryConfig.from_template` 在 C1 定义、C2/C3 使用；`Indexer.factory_idxs` 在 C2 内自洽替换 `factory_idx`。

**4. 已知风险 / 留痕**
- B2 的 comptime 分发依赖「未使用的 comptime 分支不被语义分析」；若 Zig 0.17 对某些转义（如 `Iterator.next` 返回 `?[]const u8`）仍然报错，退路是在 stub 里把这些签名逐一对齐（Step 1 的清单就是为此）。
- C2 让「同一合约地址配两条规则」仍然被 validate 拒绝（老语义不变），只放开 `from_template`；如果实际需要「同一合约的多个事件各自发现不同模板」，那是另一个特性（多规则同地址），本计划不做。
- `libsqlite3` 仍是动态依赖（macOS 系统自带；Linux 上由发行版提供）。若将来要连它一起静态化，另开任务。
