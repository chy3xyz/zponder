const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer.zig");
const db = @import("db.zig");
const eth_rpc = @import("eth_rpc.zig");
const abi = @import("abi.zig");

const log = std.log.scoped(.factory);

/// Heap-allocated wrapper around a child contract's Indexer.
/// Owns all config strings and the Indexer itself.
pub const ChildIndexer = struct {
    name: []const u8,
    address: []const u8,
    abi_path: []const u8,
    events: []const []const u8,
    contract_config: config.ContractConfig,
    idx: indexer.Indexer,

    pub fn deinit(self: *ChildIndexer, alloc: std.mem.Allocator) void {
        self.idx.deinit();
        alloc.free(self.name);
        alloc.free(self.address);
        alloc.free(self.abi_path);
        for (self.events) |e| alloc.free(e);
        alloc.free(self.events);
    }
};

/// 模板发现回调：工厂事件里发现的 clone 地址 → 模板索引器的动态地址集合。
/// ctx 由装配方（main）持有，工厂层不感知 Indexer 的任何内部。
pub const TemplateHook = *const fn (
    ctx: *anyopaque,
    template_name: []const u8,
    address: []const u8,
    from_block: u64,
) bool;

/// Manages factory contract detection and child indexer lifecycle.
pub const FactoryManager = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    rpc: *eth_rpc.Client,
    database: *db.Client,
    factory_configs: []const config.FactoryConfig,
    snapshot_interval: u64,
    chain: []const u8,
    track_blocks: bool,

    children: std.ArrayList(*ChildIndexer),
    mutex: std.atomic.Mutex,
    running: std.atomic.Value(bool),
    /// 模板分发表（Task 8 装配）。为 null 时，配了 template_name 的工厂只告警、不建子索引器。
    template_ctx: ?*anyopaque = null,
    template_hook: ?TemplateHook = null,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        rpc: *eth_rpc.Client,
        database: *db.Client,
        factory_configs: []const config.FactoryConfig,
        snapshot_interval: u64,
        chain: []const u8,
        track_blocks: bool,
    ) !FactoryManager {
        const children: std.ArrayList(*ChildIndexer) = .empty;
        return FactoryManager{
            .alloc = alloc,
            .io = io,
            .rpc = rpc,
            .database = database,
            .factory_configs = factory_configs,
            .snapshot_interval = snapshot_interval,
            .chain = chain,
            .track_blocks = track_blocks,
            .children = children,
            .mutex = .unlocked,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *FactoryManager) void {
        self.stopChildren();
        self.joinChildren();
        for (self.children.items) |child| {
            child.deinit(self.alloc);
            self.alloc.destroy(child);
        }
        self.children.deinit(self.alloc);
    }

    /// 注册模板分发表（必须在 `Indexer.start()` 之前调用）。
    /// hook 在工厂索引器线程里被调用，ctx 的生命周期必须覆盖整个运行期。
    pub fn setTemplateHook(self: *FactoryManager, ctx: *anyopaque, hook: TemplateHook) void {
        self.template_ctx = ctx;
        self.template_hook = hook;
    }

    /// Snapshot current children (thread-safe). Caller must NOT free the returned pointers.
    pub fn getCurrentChildren(self: *FactoryManager, alloc: std.mem.Allocator) ![]*indexer.Indexer {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        const result = try alloc.alloc(*indexer.Indexer, self.children.items.len);
        for (self.children.items, 0..) |child, i| {
            result[i] = &child.idx;
        }
        return result;
    }

    pub fn stopChildren(self: *FactoryManager) void {
        self.running.store(false, .monotonic);
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        for (self.children.items) |child| {
            child.idx.stop();
        }
    }

    /// 等子索引器线程退出。必须在放下工厂锁之后调用：子线程不拿这把锁，
    /// 但父索引器的发现回调会拿。持锁 join 会和还在 `onFactoryEvent` 里的父线程死锁。
    fn joinChildren(self: *FactoryManager) void {
        for (self.children.items) |child| {
            if (child.idx.thread) |t| {
                t.join();
                child.idx.thread = null;
            }
        }
    }

    /// Called from factory Indexer's processLog after the event row is durable.
    /// Thread-safe: acquires mutex to modify children list.
    /// 返回 false 表示发现没有持久化，调用方应记死信后重试。
    pub fn onFactoryEvent(
        self: *FactoryManager,
        factory_idx: usize,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) bool {
        if (!self.running.load(.monotonic)) return true;
        if (factory_idx >= self.factory_configs.len) return true;

        const fc = self.factory_configs[factory_idx];
        if (!std.mem.eql(u8, event_name, fc.creation_event)) return true;

        // Extract child address from event fields
        var child_addr: ?[]const u8 = null;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, fc.child_address_field)) {
                child_addr = f.value;
                break;
            }
        }
        const addr = child_addr orelse {
            log.warn("工厂 {s}: 事件 {s} 中未找到子地址字段 '{s}'", .{ fc.name, event_name, fc.child_address_field });
            return true;
        };

        // Validate address format: must be 0x + 40 hex chars
        if (addr.len != 42 or !std.mem.startsWith(u8, addr, "0x")) {
            log.warn("工厂 {s}: 无效的子地址: {s}", .{ fc.name, addr });
            return true;
        }

        onFactoryEventInner(self, fc, addr, block_number) catch |e| {
            log.err("工厂 {s}: 创建子索引器失败 ({s}): {any}", .{ fc.name, addr, e });
            return false;
        };
        return true;
    }

    fn onFactoryEventInner(
        self: *FactoryManager,
        fc: config.FactoryConfig,
        child_addr: []const u8,
        block_number: u64,
    ) !void {
        // 模板模式：发现的 clone 交给模板索引器的动态地址集合，不再建子索引器。
        // 必须在幂等检查之前返回——模板地址不落 sync_state，走老路径会被误判成"已索引"。
        if (fc.template_name.len > 0) {
            const hook = self.template_hook orelse {
                log.err("工厂 {s}: 配了 template_name={s} 但未注册模板分发表", .{ fc.name, fc.template_name });
                return error.DiscoveryFailed;
            };
            const ctx = self.template_ctx orelse {
                log.err("工厂 {s}: 配了 template_name={s} 但未注册模板分发表", .{ fc.name, fc.template_name });
                return error.DiscoveryFailed;
            };
            if (!hook(ctx, fc.template_name, child_addr, block_number)) return error.DiscoveryFailed;
            return;
        }

        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        // Check max children
        if (self.children.items.len >= fc.max_children) {
            log.warn("工厂 {s}: 子索引器数量已达上限 {d}", .{ fc.name, fc.max_children });
            return;
        }

        // 同一进程里同一地址只建一个子索引器。重启后列表是空的，
        // 即使 sync_state 已有断点也要再 start()，由 Indexer.init 从断点续传。
        for (self.children.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.address, child_addr)) {
                return;
            }
        }

        // Build child indexer name: factoryName_childAddrSuffix
        const addr_suffix = child_addr[child_addr.len - 6 ..];
        const child_name = try std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ fc.name, addr_suffix });

        // Build owned copies of config fields
        const child_abi = try self.alloc.dupe(u8, fc.child_abi_path);
        errdefer self.alloc.free(child_abi);
        const child_addr_owned = try self.alloc.dupe(u8, child_addr);
        errdefer self.alloc.free(child_addr_owned);

        const child_events = try self.alloc.alloc([]const u8, fc.child_events.len);
        errdefer {
            for (child_events) |e| self.alloc.free(e);
            self.alloc.free(child_events);
        }
        for (fc.child_events, 0..) |evt, i| {
            child_events[i] = try self.alloc.dupe(u8, evt);
        }

        // Build the ContractConfig
        const child_config = config.ContractConfig{
            .name = child_name,
            .address = child_addr_owned,
            .abi_path = child_abi,
            .events = child_events,
            .from_block = block_number,
            .start_block = null,
            .poll_interval_ms = fc.child_poll_interval_ms,
            .max_reorg_depth = null,
            .block_batch_size = fc.child_batch_size,
            .filters = &.{},
        };

        // 子索引器必须直接建在堆上：`Indexer.start()` 以自身地址起同步线程，且
        // `runLoop` 长期读 `self.contract.name` / `self.contract.events`。若先建栈局部
        // 再拷贝进 ChildIndexer，线程与 `idx.contract` 都指向本函数返回后失效的栈帧
        // （表名/事件错乱或崩溃）。`child.contract_config` 就在堆上，地址稳定。
        const child = try self.alloc.create(ChildIndexer);
        errdefer self.alloc.destroy(child);
        child.name = child_name;
        child.address = child_addr_owned;
        child.abi_path = child_abi;
        child.events = child_events;
        child.contract_config = child_config;
        child.idx = try indexer.Indexer.init(
            self.alloc, self.io, self.rpc, self.database,
            &child.contract_config, self.snapshot_interval,
            self.track_blocks, self.chain,
            null, null,
        );
        errdefer child.idx.deinit();

        try child.idx.start();
        try self.children.append(self.alloc, child);

        log.info("工厂 {s}: 发现新子合约 {s} (地址={s}, 起始区块={d})", .{ fc.name, child_name, child_addr, block_number });
    }

    /// Static callback adapter for use with Indexer's FactoryCallback type.
    pub fn onFactoryEventCallback(
        ctx: *anyopaque,
        factory_idx: usize,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) bool {
        const self: *FactoryManager = @ptrCast(@alignCast(ctx));
        return self.onFactoryEvent(factory_idx, event_name, fields, block_number);
    }

    /// 进程重启后，创建事件已经在父合约的事件表里，父游标不会再扫到它们。
    /// 按每条工厂规则把已落库的子地址重新拉起；`Indexer.init` 会读子地址自己的
    /// `sync_state` 从断点继续。模板工厂不走这里。RocksDB 没有 SQL，跳过。
    pub fn resumeChildren(self: *FactoryManager, sources: []const config.ContractConfig) !void {
        if (self.database.backend_type == .rocksdb) return;
        for (self.factory_configs) |fc| {
            if (fc.template_name.len > 0) continue;
            if (!sqlIdent(fc.creation_event)) {
                log.err("工厂 {s}: 事件名不是合法标识符，跳过子索引器恢复", .{fc.name});
                continue;
            }
            const source = findFactorySource(sources, fc.address) orelse {
                log.warn("工厂 {s}: 找不到地址 {s} 对应的合约，跳过子索引器恢复", .{ fc.name, fc.address });
                continue;
            };
            if (!sqlIdent(source.name)) {
                log.err("工厂 {s}: 来源合约名 {s} 不是合法标识符，跳过子索引器恢复", .{ fc.name, source.name });
                continue;
            }
            const col = db.Client.eventColumnName(self.alloc, fc.child_address_field) catch |e| {
                log.err("工厂 {s}: 地址字段列名失败: {any}", .{ fc.name, e });
                continue;
            };
            defer self.alloc.free(col);
            if (!sqlIdent(col)) {
                log.err("工厂 {s}: 地址列 {s} 不是合法标识符，跳过子索引器恢复", .{ fc.name, col });
                continue;
            }
            const sql = try std.fmt.allocPrint(
                self.alloc,
                "SELECT {s}, MIN(block_number) FROM event_{s}_{s} GROUP BY {s};",
                .{ col, source.name, fc.creation_event, col },
            );
            defer self.alloc.free(sql);
            const rows = self.database.ponderQuery(sql, &.{}) catch |e| {
                if (e == error.PrepareFailed) continue;
                return e;
            };
            defer self.database.freeQueryRows(rows);
            for (rows) |row| {
                if (row.values.len < 2) continue;
                const addr = switch (row.values[0]) {
                    .text => |t| t,
                    else => continue,
                };
                if (!validChildAddress(addr)) {
                    log.warn("工厂 {s}: 跳过非法子地址", .{fc.name});
                    continue;
                }
                const block: u64 = switch (row.values[1]) {
                    .integer => |n| if (n > 0) @intCast(n) else 0,
                    else => 0,
                };
                onFactoryEventInner(self, fc, addr, block) catch |e| {
                    log.err("工厂 {s}: 恢复子索引器失败 ({s}): {any}", .{ fc.name, addr, e });
                };
            }
        }
    }

    /// 父链回滚后调用。发现区块落在分叉上的子索引器停掉并删掉断点；
    /// 更早发现的子合约从分叉点重新同步。链名不一致时不做任何事。
    pub fn onReorgCallback(ctx: *anyopaque, chain: []const u8, fork_block: u64) void {
        const self: *FactoryManager = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, chain, self.chain)) return;
        self.reconcileChildren(fork_block);
    }

    pub fn reconcileChildren(self: *FactoryManager, fork_block: u64) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();

        var doomed: std.ArrayList(*ChildIndexer) = .empty;
        defer doomed.deinit(self.alloc);
        var i: usize = 0;
        while (i < self.children.items.len) {
            const child = self.children.items[i];
            if (child.contract_config.from_block >= fork_block) {
                _ = self.children.orderedRemove(i);
                doomed.append(self.alloc, child) catch {
                    self.discardChild(child);
                    continue;
                };
            } else {
                i += 1;
            }
        }

        var survivors: std.ArrayList(*indexer.Indexer) = .empty;
        defer survivors.deinit(self.alloc);
        for (self.children.items) |child| {
            survivors.append(self.alloc, &child.idx) catch break;
        }
        self.mutex.unlock();

        for (doomed.items) |child| self.discardChild(child);

        for (survivors.items) |idx| rewindChild(idx, fork_block);
    }

    fn discardChild(self: *FactoryManager, child: *ChildIndexer) void {
        const address = child.address;
        log.info("工厂重组: 移除子合约 {s}（发现块 {d}）", .{ address, child.contract_config.from_block });
        child.idx.stop();
        if (child.idx.thread) |t| {
            t.join();
            child.idx.thread = null;
        }
        child.idx.applyReorg(child.contract_config.from_block);
        self.database.deleteSyncState(address) catch |e| {
            log.warn("工厂重组: 删除子合约断点失败 {s}: {any}", .{ address, e });
        };
        child.deinit(self.alloc);
        self.alloc.destroy(child);
    }

    fn rewindChild(idx: *indexer.Indexer, fork_block: u64) void {
        log.info("工厂重组: 子合约 {s} 回退到区块 {d}", .{ idx.contract.address, fork_block });
        idx.stop();
        if (idx.thread) |t| {
            t.join();
            idx.thread = null;
        }
        idx.applyReorg(fork_block);
        idx.start() catch |e| {
            log.err("工厂重组: 子合约 {s} 重新启动失败: {any}", .{ idx.contract.address, e });
        };
    }
};

fn sqlIdent(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |ch, i| {
        if (std.ascii.isAlphabetic(ch) or ch == '_') continue;
        if (i > 0 and std.ascii.isDigit(ch)) continue;
        return false;
    }
    return true;
}

fn validChildAddress(addr: []const u8) bool {
    if (addr.len != 42 or !std.mem.startsWith(u8, addr, "0x")) return false;
    for (addr[2..]) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn findFactorySource(sources: []const config.ContractConfig, address: []const u8) ?config.ContractConfig {
    for (sources) |src| {
        if (std.ascii.eqlIgnoreCase(src.address, address)) return src;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Task 8：模板分发（template_name 非空时喂模板地址集合，不再建子索引器）
// ---------------------------------------------------------------------------

const TestTemplateHook = struct {
    calls: usize = 0,
    template_name: []const u8 = "",
    address: []const u8 = "",
    from_block: u64 = 0,

    fn onDiscovery(ctx: *anyopaque, template_name: []const u8, address: []const u8, from_block: u64) bool {
        const self: *TestTemplateHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.template_name = template_name;
        self.address = address;
        self.from_block = from_block;
        return true;
    }
};

fn testFactoryConfig(template_name: []const u8) config.FactoryConfig {
    return .{
        .name = "launchpad_factory",
        .address = "0x1",
        .abi_path = "./abis/launchpad.abi",
        .creation_event = "CurveCreated",
        .child_address_field = "curve",
        .child_abi_path = "./abis/curve.abi",
        .child_events = &.{},
        .max_children = 1000,
        .child_poll_interval_ms = null,
        .child_batch_size = null,
        .template_name = template_name,
        .from_template = "",
    };
}

/// sqlite :memory: + 真实 eth_rpc.Client（url 为空，测试不发起请求）。
/// rpc_cfg 必须由调用方持有（eth_rpc.Client 存的是指针）。
const FactoryTestEnv = struct {
    database: db.Client,
    rpc: eth_rpc.Client,

    fn init(alloc: std.mem.Allocator, io: std.Io, rpc_cfg: *const config.RpcConfig) !FactoryTestEnv {
        const db_cfg = db.DatabaseConfig{
            .db_type = "sqlite",
            .db_name = ":memory:",
            .wal_mode = true,
            .busy_timeout_ms = 5000,
            .max_connections = 10,
        };
        var database = try db.Client.init(alloc, &db_cfg);
        errdefer database.deinit();
        try database.migrate();
        return .{ .database = database, .rpc = eth_rpc.Client.init(alloc, io, rpc_cfg) };
    }

    fn deinit(self: *FactoryTestEnv) void {
        self.rpc.deinit();
        self.database.deinit();
    }
};

test "factory 有 template_name 时走 hook 而非建子索引器" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var env = try FactoryTestEnv.init(alloc, undefined, &rpc_cfg);
    defer env.deinit();

    const factories = [_]config.FactoryConfig{testFactoryConfig("curve")};
    var fm = try FactoryManager.init(alloc, undefined, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    var hook = TestTemplateHook{};
    // 默认不注册分发表。配了 template_name 却未注册时该分支会打 std.log 的 err 日志，
    // 而测试运行器把任何 err 日志记为失败，故这里只断言默认值、不触发那条日志。
    try std.testing.expect(fm.template_hook == null);
    fm.setTemplateHook(&hook, TestTemplateHook.onDiscovery);
    try std.testing.expect(fm.template_hook != null);

    const fields = [_]db.DecodedField{.{ .name = "curve", .value = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01" }};
    // 该 clone 之前可能被老 factory 路径索引过（sync_state 已有行）：模板分支必须在
    // 幂等检查**之前**，否则这次发现会被当成"已索引"而丢掉。
    try env.database.upsertSyncState(.{ .contract_address = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01", .last_synced_block = 1, .status = "running" });
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields, 777));

    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try std.testing.expectEqualStrings("curve", hook.template_name);
    try std.testing.expectEqualStrings("0xAbCdEf0123456789AbCdEf0123456789AbCdEf01", hook.address);
    try std.testing.expectEqual(@as(u64, 777), hook.from_block);
    // 不得为 clone 建子索引器
    try std.testing.expectEqual(@as(usize, 0), fm.children.items.len);

    // 非创建事件 / 字段名不匹配：不触发
    try std.testing.expect(fm.onFactoryEvent(0, "OtherEvent", &fields, 778));
    const wrong_fields = [_]db.DecodedField{.{ .name = "other", .value = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01" }};
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &wrong_fields, 779));
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
}

test "factory 无 template_name 时仍走老路径（不查模板分发表）" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var env = try FactoryTestEnv.init(alloc, undefined, &rpc_cfg);
    defer env.deinit();

    // max_children = 0：老路径在"建子索引器"之前就返回（测试里不能真的起线程）
    var fc = testFactoryConfig("");
    fc.max_children = 0;
    const factories = [_]config.FactoryConfig{fc};
    var fm = try FactoryManager.init(alloc, undefined, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    var hook = TestTemplateHook{};
    fm.setTemplateHook(&hook, TestTemplateHook.onDiscovery);

    const fields = [_]db.DecodedField{.{ .name = "curve", .value = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01" }};
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields, 777));

    try std.testing.expectEqual(@as(usize, 0), hook.calls);
    try std.testing.expectEqual(@as(usize, 0), fm.children.items.len);
}

test "factory 老路径发现子合约：子索引器的 contract 指向堆上稳定存储" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    // max_children >= 1 会真的起子索引器线程，io 必须可用（url 为空 → 首轮 RPC 就失败，
    // 不做网络等待）。日志模块在测试里未 init，故这些失败不产生输出。
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();
    var env = try FactoryTestEnv.init(alloc, io, &rpc_cfg);
    defer env.deinit();

    // max_children = 1：走"建并启动子索引器"这条路径（这条路径此前只被 max_children = 0 绕开）
    var fc = testFactoryConfig("");
    fc.max_children = 1;
    fc.child_events = &.{"Transfer"};
    fc.child_poll_interval_ms = 1;
    const factories = [_]config.FactoryConfig{fc};
    var fm = try FactoryManager.init(alloc, io, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    const addr = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01";
    const expected_name = try std.fmt.allocPrint(alloc, "launchpad_factory_{s}", .{addr[addr.len - 6 ..]});
    defer alloc.free(expected_name);

    const fields = [_]db.DecodedField{.{ .name = "curve", .value = addr }};
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields, 777));
    fm.stopChildren();

    try std.testing.expectEqual(@as(usize, 1), fm.children.items.len);
    const child = fm.children.items[0];

    // 修复前 child.idx.contract 指向 onFactoryEventInner 的栈局部 child_config：
    // 函数返回后读 name/events 就是读失效栈帧（表名/事件错乱或崩溃）。
    try std.testing.expect(child.idx.contract == &child.contract_config);
    try std.testing.expectEqualStrings(expected_name, child.idx.contract.name);
    try std.testing.expectEqual(@as(usize, 1), child.idx.contract.events.len);
    try std.testing.expectEqualStrings("Transfer", child.idx.contract.events[0]);
    try std.testing.expectEqualStrings(addr, child.idx.contract.address);
    try std.testing.expectEqual(@as(u64, 777), child.idx.contract.from_block);
    // 同步线程也必须挂在这个堆上对象上（修复前 start() 起在栈副本上）
    try std.testing.expect(child.idx.thread != null);
    // 工厂快照拿到的是同一个稳定地址
    const snapshot = try fm.getCurrentChildren(alloc);
    defer alloc.free(snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expect(snapshot[0] == &child.idx);
}

test "重启后从事件表恢复子索引器，并接着已有断点" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();
    var env = try FactoryTestEnv.init(alloc, io, &rpc_cfg);
    defer env.deinit();

    const inputs = try alloc.alloc(abi.AbiEventInput, 1);
    inputs[0] = .{ .name = try alloc.dupe(u8, "curve"), .type = try alloc.dupe(u8, "address"), .indexed = false };
    const events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = .{ .name = try alloc.dupe(u8, "CurveCreated"), .inputs = inputs, .signature = std.mem.zeroes([32]u8) };
    var ac = abi.AbiContract{ .events = events, .functions = try alloc.alloc(abi.AbiFunction, 0) };
    defer ac.deinit(alloc);
    try env.database.autoMigrateContract("launchpad", &ac, &.{"CurveCreated"}, "0x1");

    const addr = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01";
    _ = try env.database.ponderExec(
        "INSERT INTO event_launchpad_CurveCreated (evt_curve, block_number, tx_hash, log_index, contract_address) VALUES (?, ?, ?, ?, ?);",
        &.{
            .{ .text = addr },
            .{ .integer = 777 },
            .{ .text = "0xtx" },
            .{ .integer = 0 },
            .{ .text = "0x1" },
        },
    );
    try env.database.upsertSyncState(.{ .contract_address = addr, .last_synced_block = 900, .status = "running" });

    var fc = testFactoryConfig("");
    fc.max_children = 1;
    fc.child_poll_interval_ms = 1;
    const factories = [_]config.FactoryConfig{fc};
    var fm = try FactoryManager.init(alloc, io, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    const sources = [_]config.ContractConfig{.{
        .name = "launchpad",
        .address = "0x1",
        .abi_path = "",
        .events = &.{"CurveCreated"},
        .from_block = 0,
        .start_block = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .block_batch_size = null,
        .filters = &.{},
    }};
    try fm.resumeChildren(&sources);
    try fm.resumeChildren(&sources);

    try std.testing.expectEqual(@as(usize, 1), fm.children.items.len);
    const child = fm.children.items[0];
    try std.testing.expectEqualStrings(addr, child.idx.contract.address);
    try std.testing.expectEqual(@as(u64, 777), child.idx.contract.from_block);
    try std.testing.expectEqual(@as(u64, 900), child.idx.getCurrentBlock());
}

test "父链重组移除分叉后发现的子合约，并回退更早的子合约" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();
    var env = try FactoryTestEnv.init(alloc, io, &rpc_cfg);
    defer env.deinit();

    var fc = testFactoryConfig("");
    fc.max_children = 2;
    fc.child_poll_interval_ms = 1;
    const factories = [_]config.FactoryConfig{fc};
    var fm = try FactoryManager.init(alloc, io, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    const early = "0x1111111111111111111111111111111111111111";
    const late = "0x2222222222222222222222222222222222222222";
    const fields_early = [_]db.DecodedField{.{ .name = "curve", .value = early }};
    const fields_late = [_]db.DecodedField{.{ .name = "curve", .value = late }};
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields_early, 100));
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields_late, 777));
    try std.testing.expectEqual(@as(usize, 2), fm.children.items.len);
    try env.database.upsertSyncState(.{ .contract_address = late, .last_synced_block = 800, .status = "running" });

    FactoryManager.onReorgCallback(&fm, "ethereum", 200);
    try std.testing.expectEqual(@as(usize, 2), fm.children.items.len);

    const parent_cfg = config.ContractConfig{
        .name = "parent",
        .address = "0x1",
        .abi_path = "",
        .events = &.{},
        .from_block = 0,
        .start_block = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .block_batch_size = null,
        .filters = &.{},
    };
    var parent = try indexer.Indexer.init(alloc, io, &env.rpc, &env.database, &parent_cfg, 0, false, "bsc", null, null);
    defer parent.deinit();
    parent.setReorgHook(&fm, FactoryManager.onReorgCallback);
    parent.applyReorg(200);

    try std.testing.expectEqual(@as(usize, 1), fm.children.items.len);
    try std.testing.expectEqualStrings(early, fm.children.items[0].address);
    try std.testing.expectEqual(@as(u64, 200), fm.children.items[0].idx.getCurrentBlock());
    const stale = try env.database.getSyncState(late);
    if (stale) |st| {
        alloc.free(st.contract_address);
        alloc.free(st.status);
    }
    try std.testing.expect(stale == null);
}

test "退出时等子索引器写下 stopped 断点" {
    const alloc = std.testing.allocator;
    const rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();
    var env = try FactoryTestEnv.init(alloc, io, &rpc_cfg);
    defer env.deinit();

    var fc = testFactoryConfig("");
    fc.max_children = 1;
    fc.child_poll_interval_ms = 1;
    const factories = [_]config.FactoryConfig{fc};
    var fm = try FactoryManager.init(alloc, io, &env.rpc, &env.database, &factories, 0, "bsc", false);
    defer fm.deinit();

    const addr = "0x3333333333333333333333333333333333333333";
    const fields = [_]db.DecodedField{.{ .name = "curve", .value = addr }};
    try std.testing.expect(fm.onFactoryEvent(0, "CurveCreated", &fields, 50));
    try std.testing.expectEqual(@as(usize, 1), fm.children.items.len);

    fm.stopChildren();
    fm.joinChildren();
    const state = (try env.database.getSyncState(addr)) orelse return error.MissingSyncState;
    defer alloc.free(state.contract_address);
    defer alloc.free(state.status);
    try std.testing.expectEqualStrings("stopped", state.status);
}
