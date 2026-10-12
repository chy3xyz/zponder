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
) void;

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

    /// Called from factory Indexer's processLog after successful event insert.
    /// Thread-safe: acquires mutex to modify children list.
    pub fn onFactoryEvent(
        self: *FactoryManager,
        factory_idx: usize,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) void {
        if (!self.running.load(.monotonic)) return;
        if (factory_idx >= self.factory_configs.len) return;

        const fc = self.factory_configs[factory_idx];
        if (!std.mem.eql(u8, event_name, fc.creation_event)) return;

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
            return;
        };

        // Validate address format: must be 0x + 40 hex chars
        if (addr.len != 42 or !std.mem.startsWith(u8, addr, "0x")) {
            log.warn("工厂 {s}: 无效的子地址: {s}", .{ fc.name, addr });
            return;
        }

        onFactoryEventInner(self, fc, addr, block_number) catch |e| {
            log.err("工厂 {s}: 创建子索引器失败 ({s}): {any}", .{ fc.name, addr, e });
        };
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
            if (self.template_hook) |hook| {
                if (self.template_ctx) |ctx| hook(ctx, fc.template_name, child_addr, block_number);
                return;
            }
            log.err("工厂 {s}: 配了 template_name={s} 但未注册模板分发表", .{ fc.name, fc.template_name });
            return;
        }

        // Idempotency: check if this child is already indexed
        if (try self.database.getSyncState(child_addr)) |existing| {
            self.alloc.free(existing.contract_address);
            self.alloc.free(existing.status);
            return; // Already tracking this child
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

        // Check idempotency again after acquiring lock
        for (self.children.items) |existing| {
            if (std.mem.eql(u8, existing.address, child_addr)) {
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
    ) void {
        const self: *FactoryManager = @ptrCast(@alignCast(ctx));
        self.onFactoryEvent(factory_idx, event_name, fields, block_number);
    }
};

// ---------------------------------------------------------------------------
// Task 8：模板分发（template_name 非空时喂模板地址集合，不再建子索引器）
// ---------------------------------------------------------------------------

const TestTemplateHook = struct {
    calls: usize = 0,
    template_name: []const u8 = "",
    address: []const u8 = "",
    from_block: u64 = 0,

    fn onDiscovery(ctx: *anyopaque, template_name: []const u8, address: []const u8, from_block: u64) void {
        const self: *TestTemplateHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.template_name = template_name;
        self.address = address;
        self.from_block = from_block;
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
    fm.onFactoryEvent(0, "CurveCreated", &fields, 777);

    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try std.testing.expectEqualStrings("curve", hook.template_name);
    try std.testing.expectEqualStrings("0xAbCdEf0123456789AbCdEf0123456789AbCdEf01", hook.address);
    try std.testing.expectEqual(@as(u64, 777), hook.from_block);
    // 不得为 clone 建子索引器
    try std.testing.expectEqual(@as(usize, 0), fm.children.items.len);

    // 非创建事件 / 字段名不匹配：不触发
    fm.onFactoryEvent(0, "OtherEvent", &fields, 778);
    const wrong_fields = [_]db.DecodedField{.{ .name = "other", .value = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01" }};
    fm.onFactoryEvent(0, "CurveCreated", &wrong_fields, 779);
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
    fm.onFactoryEvent(0, "CurveCreated", &fields, 777);

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
    fm.onFactoryEvent(0, "CurveCreated", &fields, 777);
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
