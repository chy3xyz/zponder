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
        self.children.deinit();
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

        // Build the ContractConfig (stack allocated, then Indexer copies what it needs)
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

        // Create and start the child indexer
        var child_idx = try indexer.Indexer.init(
            self.alloc, self.io, self.rpc, self.database,
            &child_config, self.snapshot_interval,
            self.track_blocks, self.chain,
            null, null, 0,
        );
        errdefer child_idx.deinit();

        // Heap-allocate the ChildIndexer wrapper
        const child = try self.alloc.create(ChildIndexer);
        errdefer self.alloc.destroy(child);

        child.* = .{
            .name = child_name,
            .address = child_addr_owned,
            .abi_path = child_abi,
            .events = child_events,
            .contract_config = child_config,
            .idx = child_idx,
        };

        try child_idx.start();
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
