const std = @import("std");
const config = @import("config.zig");
const eth_rpc = @import("eth_rpc.zig");
const ws_rpc = @import("ws_rpc.zig");
const db = @import("db.zig");
const abi = @import("abi.zig");
const utils = @import("utils.zig");
const log = @import("log.zig");

/// 单个合约的索引器状态
pub const IndexerState = enum(u8) {
    running,
    stopped,
    error_state,
    replaying,
};

/// Callback invoked after a factory contract event is successfully recorded.
pub const FactoryCallback = *const fn (
    ctx: *anyopaque,
    factory_idx: usize,
    event_name: []const u8,
    fields: []const db.DecodedField,
    block_number: u64,
) void;

pub const EventHookCallback = *const fn (
    ctx: ?*anyopaque,
    contract_name: []const u8,
    event_name: []const u8,
    fields: []const db.DecodedField,
    block_number: u64,
    block_timestamp: u64,
) void;

/// 模板模式下一个待补扫的 clone：发现区块起，补扫到"探测时的游标"为止。
pub const PendingBackfill = struct { address: []const u8, from_block: u64 };

/// 模板模式的动态地址集合（去重 + 补扫队列），独立可测。
///
/// 语义：`add` 只把新地址放入 `pending`（补扫队列），补扫完成后由 `markBackfilled`
/// 移入 `live`（纳入主 sweep 的地址过滤）。`all()` 只给主 sweep 用的 live 地址，
/// `count()` 是已知总数（live + pending）。
/// 本类型不做地址归一化——归一化唯一发生在 `Indexer.discoverAddress` 入口
/// （携转约束 3：template_addresses 主键精确 TEXT 比较，大小写不同会各占一行）。
pub const TemplateAddressSet = struct {
    alloc: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty,
    pending_list: std.ArrayList(PendingBackfill) = .empty,

    pub fn init(alloc: std.mem.Allocator) TemplateAddressSet {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TemplateAddressSet) void {
        for (self.live.items) |a| self.alloc.free(a);
        for (self.pending_list.items) |p| self.alloc.free(p.address);
        self.live.deinit(self.alloc);
        self.pending_list.deinit(self.alloc);
    }

    /// 已存在（live 或 pending）返回 false；新地址 dupe 进 pending，返回 true。
    /// 分配失败返回 false（签名只有 bool，此时调用方不会落库，等同未发现）。
    pub fn add(self: *TemplateAddressSet, address: []const u8, from_block: u64) bool {
        for (self.live.items) |a| {
            if (std.mem.eql(u8, a, address)) return false;
        }
        for (self.pending_list.items) |p| {
            if (std.mem.eql(u8, p.address, address)) return false;
        }
        const copy = self.alloc.dupe(u8, address) catch return false;
        self.pending_list.append(self.alloc, .{ .address = copy, .from_block = from_block }) catch {
            self.alloc.free(copy);
            return false;
        };
        return true;
    }

    /// 已知地址总数（live + 待补扫 pending）。
    /// 注意与 `all()` 的区别：`all()` 只给主 sweep 用的 live 地址。
    pub fn count(self: *TemplateAddressSet) usize {
        return self.live.items.len + self.pending_list.items.len;
    }

    /// 主 sweep 使用的 live 地址集合。
    pub fn all(self: *TemplateAddressSet) []const []const u8 {
        return self.live.items;
    }

    /// 待补扫队列（按加入顺序，不依赖同块发现顺序）。
    pub fn pending(self: *TemplateAddressSet) []const PendingBackfill {
        return self.pending_list.items;
    }

    /// pending → live（补扫完成，或发现区块已被主 sweep 覆盖而无需补扫）。
    /// 幂等：地址不在 pending 时不作任何事（不会重复并入 live）。
    pub fn markBackfilled(self: *TemplateAddressSet, address: []const u8) void {
        for (self.pending_list.items, 0..) |p, i| {
            if (!std.mem.eql(u8, p.address, address)) continue;
            const moved = self.pending_list.orderedRemove(i);
            self.live.append(self.alloc, moved.address) catch {
                // 并入 live 失败：已从 pending 摘除，释放避免泄漏（该地址本轮到不了 live）
                self.alloc.free(moved.address);
            };
            return;
        }
    }
};

/// 补扫区间：发现区块 → 探测时的游标（半开区间 `[from, to)`）。
/// 上界取游标（不含游标块）——`[0, cursor)` 都已同步，游标块及其后由主 sweep 覆盖，
/// 因此既不漏块也不与主 sweep 重叠。`{0, 0}` 表示无需补扫（合法区间必有 to > from）。
fn computeBackfillRange(discovered_at_block: u64, current_cursor: u64) [2]u64 {
    if (discovered_at_block >= current_cursor) return .{ 0, 0 };
    return .{ discovered_at_block, current_cursor };
}

/// 补扫分块推进：`from` 起、闭区间上界 `last`，返回本块闭区间 `[from, end]`。
/// 返回 null 表示已越过末尾。`eth_getLogs` 的 toBlock 是闭区间，补扫的"半开上界 - 1"
/// 由调用方换算成 `last`，本函数只负责按 batch_size 切连续的块。
fn nextBackfillChunk(from: u64, batch_size: u64, last: u64) ?[2]u64 {
    if (from > last) return null;
    return .{ from, @min(from +| (batch_size - 1), last) };
}

/// 地址归一化（小写 hex）——模板模式的**唯一**归一化点。
/// 合法地址必须是 `0x` + 40 hex；否则返回 null（调用方不得落库，避免主键分裂）。
fn normalizeHexAddress(out: *[42]u8, address: []const u8) ?[]const u8 {
    if (address.len != 42 or !std.mem.startsWith(u8, address, "0x")) return null;
    return std.ascii.lowerString(out, address);
}

/// 构造一批 eth_getLogs / eth_subscribe 的地址过滤器。
/// 地址集合为空时返回 null：空集合在 LogFilter 层序列化为 `"address":null`，
/// 语义是"不过滤地址"，会拉回整段区块内全部合约的日志（放大面极大）——
/// 构造层据此短路，绝不对空集合发起 RPC（携转约束 1）。
fn makeLogFilter(
    addresses: []const []const u8,
    topics: ?[]const []const u8,
    from_block: u64,
    to_block: u64,
) ?eth_rpc.LogFilter {
    if (addresses.len == 0) return null;
    return .{
        .addresses = addresses,
        .topics = topics,
        .from_block = from_block,
        .to_block = to_block,
    };
}

/// 启动时从库恢复模板地址集合：`backfilled` 的立即并入 live，其余留在 pending 重新补扫。
/// 读库错误（含 RocksDB 后端的 `error.UnsupportedOperation`）**原样上抛**，
/// 由 Task 8 在启动期转成 fail-fast——绝不吞掉当成空集合继续跑（携转约束 2）。
/// 仅启动期调用（start 之前），故内部不加锁。
fn loadTemplateAddressesInto(set: *TemplateAddressSet, client: *db.Client, template: []const u8) !void {
    const list = try client.listTemplateAddresses(template);
    defer {
        for (list) |item| client.alloc.free(item.address);
        client.alloc.free(list);
    }
    for (list) |item| {
        _ = set.add(item.address, item.from_block);
        if (item.backfilled) set.markBackfilled(item.address);
    }
}

/// 核心索引器
pub const Indexer = struct {
    alloc: std.mem.Allocator,
    rpc: *eth_rpc.Client,
    database: *db.Client,
    contract: *const config.ContractConfig,
    snapshot_interval: u64,
    state: std.atomic.Value(IndexerState),
    current_block: std.atomic.Value(u64),
    last_tip: std.atomic.Value(u64),
    last_snapshot_time: std.atomic.Value(i64),
    batch_size: u64,
    poll_interval_ms: u32,
    abi_contract: ?abi.AbiContract,
    thread: ?std.Thread,
    track_blocks: bool,
    chain: []const u8,
    factory_ctx: ?*anyopaque,
    factory_callback: ?FactoryCallback,
    factory_idx: usize,
    event_callback_ctx: ?*anyopaque = null,
    event_callback: ?EventHookCallback = null,
    /// 事件回调是否需要链上区块时间戳（JS handler 存在时开启）；
    /// 关闭时不产生任何额外 RPC。
    event_ts_needed: bool = false,
    /// block_number -> block timestamp 缓存（惰性拉取；上限后整体清空）
    block_ts_cache: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Set while runLiveWs owns a Session (for stop() to unblock).
    ws_session: ?*ws_rpc.Session = null,
    /// 模板模式：一个 Indexer 持有多个动态发现的 clone 地址，共用一套事件表。
    template_mode: bool = false,
    /// 动态地址集合（去重 + 补扫队列）。
    template_set: TemplateAddressSet,
    /// 保护 template_set：discoverAddress 可被工厂线程并发调用，runLoop 读 pending /
    /// 写 live。持有期间不得发起 RPC。
    template_mutex: std.atomic.Mutex = .unlocked,
    /// 模板模式下 sync_state / block_hashes / snapshots 的合成 key：`template:<模板名>`
    /// （模板模式下 contract.address 是空串，不能直接当 key；详见 setTemplateMode）。
    template_state_key: [256]u8 = undefined,
    template_state_key_len: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        rpc: *eth_rpc.Client,
        database: *db.Client,
        contract: *const config.ContractConfig,
        snapshot_interval: u64,
        track_blocks: bool,
        chain: []const u8,
        factory_ctx: ?*anyopaque,
        factory_callback: ?FactoryCallback,
        factory_idx: usize,
    ) !Indexer {
        // 加载 ABI
        var abi_contract: ?abi.AbiContract = null;
        if (std.Io.Dir.cwd().access(io, contract.abi_path, .{})) {
            abi_contract = abi.parseAbiFile(alloc, io, contract.abi_path) catch |e| blk: {
                log.warn("ABI 解析失败 {s}: {any}，将使用原始日志数据", .{ contract.abi_path, e });
                break :blk null;
            };
        } else |_| {
            log.warn("ABI 文件不存在: {s}", .{contract.abi_path});
        }

        // 根据 ABI 自动创建事件表
        if (abi_contract) |*ac| {
            database.autoMigrateContract(contract.name, ac, contract.events, contract.address) catch |e| {
                log.err("合约 {s} 自动迁移失败: {any}", .{ contract.name, e });
            };
            log.info("合约 {s} 事件表已创建/检查", .{contract.name});
        }

        // 从数据库读取断点。
        // 注意：模板模式下 contract.address 是空串，这里读到的是非模板键；
        // setTemplateMode(true) 会用合成键 `template:<名>` 重新载入断点。
        var start_block = contract.from_block;
        if (try database.getSyncState(contract.address)) |sync_state| {
            start_block = sync_state.last_synced_block;
            log.info("合约 {s} 从断点续传: 区块 {}", .{ contract.name, start_block });
            alloc.free(sync_state.contract_address);
            alloc.free(sync_state.status);
        } else {
            log.info("合约 {s} 从起始区块开始: {}", .{ contract.name, start_block });
        }

        const batch_size = contract.block_batch_size orelse 500;
        const poll_interval_ms = contract.poll_interval_ms orelse 2000;

        return .{
            .alloc = alloc,
            .rpc = rpc,
            .database = database,
            .contract = contract,
            .snapshot_interval = snapshot_interval,
            .state = std.atomic.Value(IndexerState).init(.stopped),
            .current_block = std.atomic.Value(u64).init(start_block),
            .last_tip = std.atomic.Value(u64).init(start_block),
            .last_snapshot_time = std.atomic.Value(i64).init(0),
            .batch_size = batch_size,
            .poll_interval_ms = poll_interval_ms,
            .abi_contract = abi_contract,
            .thread = null,
            .track_blocks = track_blocks,
            .chain = chain,
            .factory_ctx = factory_ctx,
            .factory_callback = factory_callback,
            .factory_idx = factory_idx,
            .template_set = TemplateAddressSet.init(alloc),
        };
    }

    pub fn setEventCallback(self: *Indexer, ctx: ?*anyopaque, cb: EventHookCallback) void {
        self.event_callback_ctx = ctx;
        self.event_callback = cb;
    }

    /// 开启后事件回调携带链上区块时间戳（含惰性 RPC + 缓存）；默认关闭零开销。
    pub fn setEventTimestampsEnabled(self: *Indexer, enabled: bool) void {
        self.event_ts_needed = enabled;
        if (!enabled) {
            self.block_ts_cache.deinit(self.alloc);
            self.block_ts_cache = .empty;
        }
    }

    /// 开启模板模式：一个 Indexer 承载一批动态发现的 clone 地址，共用一套事件表。
    /// 必须在 `start()` 之前调用。开启后：
    /// - 游标/hash/快照改用合成 key `template:<模板名>`（模板的 contract.address 是空串，
    ///   直接用会与"无地址"发生碰撞；合成 key 与设计文档 §2.2.1 的约定一致）；
    /// - 重新按该 key 载入断点（`init` 时还不知道模板模式，读的是空地址的键）。
    pub fn setTemplateMode(self: *Indexer, enabled: bool) void {
        self.template_mode = enabled;
        if (!enabled) {
            self.template_state_key_len = 0;
            return;
        }

        const key = std.fmt.bufPrint(&self.template_state_key, "template:{s}", .{self.contract.name}) catch |e| {
            // 名称长到放不下合成 key：退回空 key（保持旧行为）并显式报错，避免静默用错键。
            log.err("模板 {s}: 生成状态 key 失败，回退为 contract.address: {any}", .{ self.contract.name, e });
            self.template_state_key_len = 0;
            return;
        };
        self.template_state_key_len = key.len;

        if (self.database.getSyncState(key)) |state| {
            self.current_block.store(state.last_synced_block, .monotonic);
            self.last_tip.store(state.last_synced_block, .monotonic);
            log.info("模板 {s} 从断点续传: 区块 {}", .{ self.contract.name, state.last_synced_block });
            self.alloc.free(state.contract_address);
            self.alloc.free(state.status);
        } else |e| {
            log.warn("模板 {s} 读取断点失败: {any}，从配置起始区块开始", .{ self.contract.name, e });
        }
    }

    /// `sync_state` / `block_hashes` / `snapshots` 使用的 key。
    /// 模板模式返回合成 key `template:<名>`；单合约模式返回合约地址（行为不变）。
    fn stateKey(self: *Indexer) []const u8 {
        if (self.template_mode and self.template_state_key_len > 0) {
            return self.template_state_key[0..self.template_state_key_len];
        }
        return self.contract.address;
    }

    fn lockTemplateSet(self: *Indexer) void {
        while (!self.template_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockTemplateSet(self: *Indexer) void {
        self.template_mutex.unlock();
    }

    /// 登记一个新发现的 clone 地址（线程安全，可被工厂线程调用）。
    /// 入口统一归一化为小写 hex（携转约束 3：template_addresses 主键精确 TEXT 比较）。
    /// 新地址先入内存 pending，再落库；落库失败只告警、不阻断发现（内存集合仍可用）。
    pub fn discoverAddress(self: *Indexer, address: []const u8, from_block: u64) void {
        if (!self.template_mode) return;

        var lower_buf: [42]u8 = undefined;
        const normalized = normalizeHexAddress(&lower_buf, address) orelse {
            log.warn("模板 {s}: 忽略非法 clone 地址: {s}", .{ self.contract.name, address });
            return;
        };

        self.lockTemplateSet();
        defer self.unlockTemplateSet();

        if (!self.template_set.add(normalized, from_block)) return; // 已存在，幂等

        // 持锁落库：保证补扫完成前的 markTemplateAddressBackfilled 不会作用于尚不存在的行。
        self.database.addTemplateAddress(self.contract.name, normalized, from_block) catch |e| {
            log.warn("模板 {s}: clone 地址落库失败 {s}: {any}（内存集合仍生效，重启后可能丢失）", .{ self.contract.name, normalized, e });
        };
    }

    /// 当前已知的 clone 地址总数（live + 待补扫），用于状态/指标展示。
    pub fn templateAddressCount(self: *Indexer) usize {
        self.lockTemplateSet();
        defer self.unlockTemplateSet();
        return self.template_set.count();
    }

    /// 启动时从库恢复模板地址集合。必须在 `start()` 之前调用。
    /// 读库错误（含 RocksDB 后端的 `error.UnsupportedOperation`）原样上抛，
    /// 由 Task 8 在启动期转成 fail-fast——不会等到发现第一个 clone 才炸（携转约束 2）。
    pub fn loadTemplateAddresses(self: *Indexer) !void {
        if (!self.template_mode) return;
        try loadTemplateAddressesInto(&self.template_set, self.database, self.contract.name);
        log.info("模板 {s}: 从库恢复 {d} 个 clone 地址", .{ self.contract.name, self.template_set.count() });
    }

    /// 解析区块时间戳（惰性拉取 + 缓存）；失败或未开启返回 0。
    fn resolveBlockTimestamp(self: *Indexer, block_number: u64) u64 {
        if (!self.event_ts_needed) return 0;
        if (self.block_ts_cache.get(block_number)) |ts| return ts;
        const block_data = (self.rpc.getBlockData(block_number) catch return 0) orelse return 0;
        defer {
            self.alloc.free(block_data.hash);
            self.alloc.free(block_data.miner);
            self.alloc.free(block_data.base_fee_per_gas);
        }
        const ts = block_data.timestamp;
        // 上限保护：缓存过大时整体清空（最坏回退为重新拉取）
        if (self.block_ts_cache.count() > 4096) self.block_ts_cache.clearRetainingCapacity();
        self.block_ts_cache.put(self.alloc, block_number, ts) catch {};
        return ts;
    }

    pub fn deinit(self: *Indexer) void {
        self.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.abi_contract) |*ac| {
            ac.deinit(self.alloc);
            self.abi_contract = null;
        }
        self.template_set.deinit();
        self.block_ts_cache.deinit(self.alloc);
        self.block_ts_cache = .empty;
    }

    /// 启动同步协程
    pub fn start(self: *Indexer) !void {
        if (self.state.load(.monotonic) == .running) return;
        if (self.thread != null) return;
        self.state.store(.running, .monotonic);
        self.thread = try std.Thread.spawn(.{}, Indexer.runLoop, .{self});
        log.info("索引器已启动: {s} ({s})", .{ self.contract.name, self.contract.address });
    }

    /// 停止同步
    pub fn stop(self: *Indexer) void {
        self.state.store(.stopped, .monotonic);
        if (self.ws_session) |s| s.close();
    }

    fn hasWsConfig(self: *Indexer) bool {
        const c = self.rpc.config;
        if (c.ws_urls.len > 0) return true;
        if (c.ws_url) |u| return u.len > 0;
        return false;
    }

    /// 设置重放模式
    pub fn setReplay(self: *Indexer, from_block: u64, to_block: u64) !void {
        self.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // 删除各事件表在目标范围内的数据
        for (self.contract.events) |evt_name| {
            self.database.deleteEventLogsInRange(self.contract.name, evt_name, from_block, to_block) catch |e| {
                log.warn("删除事件日志失败 {s}.{s}: {any}", .{ self.contract.name, evt_name, e });
            };
        }

        self.state.store(.replaying, .monotonic);
        self.current_block.store(from_block, .monotonic);
        log.info("合约 {s} 开始重放，从区块 {}", .{ self.contract.name, from_block });

        self.state.store(.running, .monotonic);
        self.thread = try std.Thread.spawn(.{}, Indexer.runLoop, .{self});
    }

    /// 获取当前同步状态
    pub fn getStatus(self: *Indexer) IndexerState {
        return self.state.load(.monotonic);
    }

    /// 获取当前区块
    pub fn getCurrentBlock(self: *Indexer) u64 {
        return self.current_block.load(.monotonic);
    }

    /// 核心同步循环
    fn runLoop(self: *Indexer) void {
        while (self.state.load(.monotonic) == .running or self.state.load(.monotonic) == .replaying) {
            const latest_block = self.rpc.getBlockNumber() catch |e| {
                log.err("获取最新区块失败: {any}，{d}ms 后重试", .{ e, self.poll_interval_ms });
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(self.poll_interval_ms), .real) catch {};
                continue;
            };
            self.last_tip.store(latest_block, .monotonic);

            // 模板模式：先把新发现 clone 的历史区间补扫完（并入 live），再推进主游标。
            // 放在 tip 判断之前：已追上 tip 时也要处理补扫。
            if (self.template_mode) self.processPendingBackfills();

            const current = self.current_block.load(.monotonic);
            if (current >= latest_block) {
                // 模板模式的 WSS 订阅需要随地址集合变化重订阅（Task 8+），暂不启用。
                if (!self.template_mode and self.hasWsConfig()) {
                    log.info("合约 {s} 已追上 tip (#{d})，切换到 WSS 订阅模式", .{ self.contract.name, latest_block });
                    self.runLiveWs();
                    // runLiveWs 仅在停止时返回
                    break;
                }
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(self.poll_interval_ms), .real) catch {};
                continue;
            }

            // 链重组检测：检查上一个已同步区块的 hash 是否变化
            if (current > self.contract.from_block) {
                if (self.detectAndHandleReorg(current - 1)) |fork_block| {
                    if (fork_block < current - 1) {
                        log.warn("合约 {s} 检测到链重组，回滚到区块 {}", .{ self.contract.name, fork_block });
                        self.current_block.store(fork_block, .monotonic);
                        continue;
                    }
                } else |e| {
                    log.err("重组检测失败: {any}", .{e});
                }
            }

            const to_block = @min(current + self.batch_size, latest_block);
            log.debug("同步 {s}: 区块 {} ~ {}", .{ self.contract.name, current, to_block });

            self.syncRange(current, to_block) catch |e| {
                if (e == error.RpcLimitExceeded) {
                    const new_batch = @max(self.batch_size / 2, 100);
                    log.warn("RPC limit exceeded, reducing batch_size from {} to {}", .{ self.batch_size, new_batch });
                    self.batch_size = new_batch;
                    // 已经是最小批次仍超限，等待更长时间让 RPC 冷却
                    if (self.batch_size == 100) {
                        log.warn("已达最小批次 100，等待 10s 后重试", .{});
                        std.Io.sleep(self.rpc.io, std.Io.Duration.fromSeconds(10), .real) catch {};
                    }
                    continue;
                }
                log.err("同步区块 {}~{} 失败: {any}", .{ current, to_block, e });
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(self.poll_interval_ms), .real) catch {};
                continue;
            };

            // 记录本批次最后一个区块的 hash（用于下次重组检测）
            if (self.rpc.getBlockHash(to_block)) |hash| {
                defer if (hash) |h| self.alloc.free(h);
                if (hash) |h| {
                    self.database.upsertBlockHash(self.stateKey(), to_block, h) catch |e| {
                        log.warn("记录区块 hash 失败: {any}", .{e});
                    };
                }
            } else |e| {
                log.warn("获取区块 {d} hash 失败: {any}", .{ to_block, e });
            }

            if (self.track_blocks and to_block > 0) {
                self.storeBlockMetadata(to_block) catch |e| {
                    log.warn("存储区块 {d} 元数据失败: {any}", .{ to_block, e });
                };
            }

            self.current_block.store(to_block + 1, .monotonic);

            self.database.upsertSyncState(.{
                .contract_address = self.stateKey(),
                .last_synced_block = to_block,
                .status = "running",
            }) catch |e| {
                log.err("更新同步状态失败: {any}", .{e});
            };

            self.checkSnapshot() catch |e| {
                log.err("创建快照失败: {any}", .{e});
            };

            if (self.state.load(.monotonic) == .replaying and to_block >= latest_block) {
                self.state.store(.running, .monotonic);
                log.info("合约 {s} 重放完成", .{self.contract.name});
            }
        }

        self.database.upsertSyncState(.{
            .contract_address = self.stateKey(),
            .last_synced_block = self.current_block.load(.monotonic),
            .status = "stopped",
        }) catch |db_err| {
            log.warn("索引器停止时更新同步状态失败: {any}", .{db_err});
        };

        log.info("索引器已停止: {s}", .{self.contract.name});
    }

    /// 构建合约事件 topic0 列表（调用方释放每个元素及 slice）
    fn buildEventTopics(self: *Indexer) ![][]const u8 {
        var topics: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (topics.items) |t| self.alloc.free(t);
            topics.deinit(self.alloc);
        }

        if (self.abi_contract) |ac| {
            for (self.contract.events) |evt_name| {
                if (ac.findEventByName(evt_name)) |evt| {
                    var hex_buf: [70]u8 = undefined;
                    const hex_bytes = std.fmt.bytesToHex(&evt.signature, .lower);
                    const hex_str = try std.fmt.bufPrint(&hex_buf, "0x{s}", .{&hex_bytes});
                    try topics.append(self.alloc, try self.alloc.dupe(u8, hex_str));
                }
            }
        }
        return try topics.toOwnedSlice(self.alloc);
    }

    fn freeEventTopics(self: *Indexer, topics: [][]const u8) void {
        for (topics) |t| self.alloc.free(t);
        self.alloc.free(topics);
    }

    /// HTTP 追到 tip，用于切入/重连 WSS 前的 gap bridge
    fn bridgeToTip(self: *Indexer) !void {
        while (self.state.load(.monotonic) == .running or self.state.load(.monotonic) == .replaying) {
            const latest = try self.rpc.getBlockNumber();
            const current = self.current_block.load(.monotonic);
            if (current >= latest) return;

            const to_block = @min(current + self.batch_size, latest);
            self.syncRange(current, to_block) catch |e| {
                if (e == error.RpcLimitExceeded) {
                    self.batch_size = @max(self.batch_size / 2, 100);
                    continue;
                }
                return e;
            };

            if (self.rpc.getBlockHash(to_block)) |hash| {
                defer if (hash) |h| self.alloc.free(h);
                if (hash) |h| {
                    self.database.upsertBlockHash(self.stateKey(), to_block, h) catch {};
                }
            } else |_| {}

            self.current_block.store(to_block + 1, .monotonic);
            self.database.upsertSyncState(.{
                .contract_address = self.stateKey(),
                .last_synced_block = to_block,
                .status = "running",
            }) catch {};
        }
    }

    fn advanceAfterLiveLog(self: *Indexer, block_number: u64) void {
        const cur = self.current_block.load(.monotonic);
        if (block_number + 1 > cur) {
            self.current_block.store(block_number + 1, .monotonic);
        }
        self.database.upsertSyncState(.{
            .contract_address = self.stateKey(),
            .last_synced_block = block_number,
            .status = "running",
        }) catch |e| {
            log.warn("WSS 更新同步状态失败: {any}", .{e});
        };

        if (self.rpc.getBlockHash(block_number)) |hash| {
            defer if (hash) |h| self.alloc.free(h);
            if (hash) |h| {
                self.database.upsertBlockHash(self.stateKey(), block_number, h) catch {};
            }
        } else |_| {}

        if (self.track_blocks and block_number > 0) {
            self.storeBlockMetadata(block_number) catch {};
        }
    }

    fn handleRemovedLog(self: *Indexer, block_number: u64) void {
        log.warn("合约 {s} 收到 removed 日志 @ 区块 {d}，回滚", .{ self.contract.name, block_number });
        self.rollbackTo(block_number);
        self.current_block.store(block_number, .monotonic);
        self.database.upsertSyncState(.{
            .contract_address = self.stateKey(),
            .last_synced_block = if (block_number > 0) block_number - 1 else 0,
            .status = "running",
        }) catch {};
    }

    /// 回滚到 `fork_block`（含）：事件表删 `block_number >= fork_block`，
    /// 快照/区块 hash/sync_state 按 `stateKey()` 清理。
    /// 模板模式额外删除 `from_block >= fork_block` 的 clone 记录——fork 之后创建的
    /// clone 与它们的全部事件一致作废（模板内所有地址都是链级事实，无需地址谓词）。
    fn rollbackTo(self: *Indexer, fork_block: u64) void {
        self.database.rollbackFromBlock(
            self.stateKey(),
            self.contract.name,
            self.contract.events,
            fork_block,
        ) catch |e| {
            log.err("回滚数据失败: {any}", .{e});
        };
        if (self.template_mode) {
            self.database.deleteTemplateAddressesFromBlock(self.contract.name, fork_block) catch |e| {
                log.warn("清理克隆地址记录失败: {any}", .{e});
            };
        }
    }

    /// Tip 阶段：WSS eth_subscribe(logs)，断线后 HTTP bridge + 重连
    fn runLiveWs(self: *Indexer) void {
        var session = ws_rpc.Session.init(self.alloc, self.rpc.io);
        self.ws_session = &session;
        defer {
            self.ws_session = null;
            session.unsubscribe();
            session.deinit();
        }

        var reconnect_attempt: u32 = 0;
        var last_reorg_check_ms: i64 = 0;

        while (self.state.load(.monotonic) == .running or self.state.load(.monotonic) == .replaying) {
            self.bridgeToTip() catch |e| {
                log.err("WSS bridge 失败: {any}", .{e});
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(self.poll_interval_ms), .real) catch {};
                continue;
            };

            if (self.state.load(.monotonic) != .running and self.state.load(.monotonic) != .replaying) break;

            session.connectWithFailover(self.rpc.config.ws_url, self.rpc.config.ws_urls) catch |e| {
                reconnect_attempt += 1;
                const backoff_ms = 500 * std.math.pow(u32, 2, @min(reconnect_attempt, 5));
                log.warn("WSS 连接失败（{d}），{d}ms 后重试: {any}", .{ reconnect_attempt, backoff_ms, e });
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(backoff_ms), .real) catch {};
                continue;
            };

            const topics = self.buildEventTopics() catch |e| {
                log.err("构建 WSS topics 失败: {any}", .{e});
                session.close();
                session.detachConnection();
                break;
            };
            defer self.freeEventTopics(topics);

            const addrs = [_][]const u8{self.contract.address};
            const filter = eth_rpc.LogFilter{
                .addresses = &addrs,
                .topics = if (topics.len > 0) topics else null,
            };
            const filter_obj = self.rpc.formatSubscribeLogsFilter(filter) catch |e| {
                log.err("格式化 WSS filter 失败: {any}", .{e});
                session.close();
                session.detachConnection();
                break;
            };
            defer self.alloc.free(filter_obj);

            _ = session.subscribeLogs(filter_obj) catch |e| {
                reconnect_attempt += 1;
                const backoff_ms = 500 * std.math.pow(u32, 2, @min(reconnect_attempt, 5));
                log.warn("eth_subscribe 失败，{d}ms 后重试: {any}", .{ backoff_ms, e });
                session.close();
                session.detachConnection();
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(backoff_ms), .real) catch {};
                continue;
            };

            reconnect_attempt = 0;
            log.info("合约 {s} WSS 订阅已激活", .{self.contract.name});

            // 二次 bridge：覆盖 subscribe 前后可能漏掉的块
            self.bridgeToTip() catch |e| {
                log.warn("订阅后 bridge 失败: {any}", .{e});
            };

            while (self.state.load(.monotonic) == .running or self.state.load(.monotonic) == .replaying) {
                const event = session.readEvent() catch |e| {
                    log.warn("WSS 读事件失败: {any}，准备重连", .{e});
                    break;
                };

                switch (event) {
                    .closed => break,
                    .ping_handled => {},
                    .log => |lg| {
                        defer eth_rpc.freeLog(self.alloc, lg);

                        if (lg.removed) {
                            self.handleRemovedLog(lg.block_number);
                            continue;
                        }

                        self.processLog(lg) catch |e| {
                            log.warn("WSS 日志处理失败 (tx: {s}): {any}", .{ lg.transaction_hash, e });
                            const topics_json = formatTopicsJson(self.alloc, lg.topics) catch continue;
                            defer self.alloc.free(topics_json);
                            self.database.insertRawLog(
                                self.contract.address,
                                lg.block_number,
                                lg.transaction_hash,
                                lg.log_index,
                                topics_json,
                                lg.data,
                                @errorName(e),
                            ) catch {};
                            continue;
                        };

                        self.advanceAfterLiveLog(lg.block_number);

                        // 周期性重组检测（约每 30s）
                        const now_ms = std.Io.Timestamp.now(self.rpc.io, .real).toMilliseconds();
                        if (now_ms - last_reorg_check_ms >= 30_000) {
                            last_reorg_check_ms = now_ms;
                            const cur = self.current_block.load(.monotonic);
                            if (cur > self.contract.from_block) {
                                if (self.detectAndHandleReorg(cur - 1)) |fork| {
                                    if (fork < cur - 1) {
                                        log.warn("WSS 模式检测到重组，回滚到 {}", .{fork});
                                        self.current_block.store(fork, .monotonic);
                                        break; // 退出读循环，bridge 再追上
                                    }
                                } else |_| {}
                            }
                        }

                        self.checkSnapshot() catch {};
                    },
                }
            }

            session.unsubscribe();
            session.close();
            session.detachConnection();

            if (self.state.load(.monotonic) != .running and self.state.load(.monotonic) != .replaying) break;

            reconnect_attempt += 1;
            const backoff_ms = 500 * std.math.pow(u32, 2, @min(reconnect_attempt, 5));
            log.info("合约 {s} WSS 将在 {d}ms 后重连", .{ self.contract.name, backoff_ms });
            std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(backoff_ms), .real) catch {};
        }
    }

    /// 同步指定区块范围。
    /// - 单合约模式：只过滤该合约地址
    /// - 模板模式：过滤全部 live clone 地址（空集合不发请求，见 makeLogFilter）
    fn syncRange(self: *Indexer, from_block: u64, to_block: u64) !void {
        if (self.template_mode) {
            return self.syncRangeWithAddresses(self.template_set.all(), from_block, to_block);
        }
        const addrs = [_][]const u8{self.contract.address};
        return self.syncRangeWithAddresses(&addrs, from_block, to_block);
    }

    /// 用给定地址集合拉取并处理 `[from_block, to_block]` 的日志。
    /// 地址集合为空时**直接返回、不发起任何 RPC**——空集合等价于"不过滤地址"（携转约束 1）。
    fn syncRangeWithAddresses(
        self: *Indexer,
        addresses: []const []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        const topics = try self.buildEventTopics();
        defer self.freeEventTopics(topics);

        const filter = makeLogFilter(addresses, if (topics.len > 0) topics else null, from_block, to_block) orelse {
            log.debug("模板 {s}: 地址集合为空，跳过区块 {}~{}（不发请求）", .{ self.contract.name, from_block, to_block });
            return;
        };

        const logs = try self.rpc.getLogs(filter);
        defer eth_rpc.freeLogs(self.alloc, logs);

        if (logs.len == 0) return;

        log.info("合约 {s} 获取到 {d} 条日志 ({}~{})", .{ self.contract.name, logs.len, from_block, to_block });

        for (logs) |lg| {
            self.processLog(lg) catch |e| {
                log.warn("日志处理失败 (tx: {s}): {any}", .{ lg.transaction_hash, e });
                // 写入 raw_logs 死信表，避免静默丢弃
                const topics_json = formatTopicsJson(self.alloc, lg.topics) catch |fmt_err| {
                    log.warn("topics JSON 构建失败: {any}", .{fmt_err});
                    continue;
                };
                defer self.alloc.free(topics_json);

                self.database.insertRawLog(
                    self.stateKey(),
                    lg.block_number,
                    lg.transaction_hash,
                    lg.log_index,
                    topics_json,
                    lg.data,
                    @errorName(e),
                ) catch |db_err| {
                    log.err("raw_logs 写入失败 (tx: {s}): {any}", .{ lg.transaction_hash, db_err });
                };
                continue;
            };
        }
    }

    /// 模板模式：处理新发现 clone 的补扫队列。
    /// 逐个 pending：区间 = `computeBackfillRange(发现块, 当前游标)`；补扫成功（或该区间已被
    /// 主 sweep 覆盖、无需补扫）后标记 backfilled → 并入 live，由主 sweep 接管后续区块。
    /// 失败则保持 pending、下一轮重试——重复写入由 `(contract_address, tx_hash, log_index)`
    /// 唯一键兜底，因此补扫与主 sweep 的边界重叠不会产生重复行。
    fn processPendingBackfills(self: *Indexer) void {
        const pending = self.snapshotPending() catch |e| {
            log.warn("模板 {s}: 补扫队列快照失败: {any}", .{ self.contract.name, e });
            return;
        };
        defer {
            for (pending) |p| self.alloc.free(p.address);
            self.alloc.free(pending);
        }
        if (pending.len == 0) return;

        for (pending) |p| {
            const cursor = self.current_block.load(.monotonic);
            const range = computeBackfillRange(p.from_block, cursor);
            if (range[0] < range[1]) {
                self.backfillRange(p.address, range[0], range[1]) catch |e| {
                    if (e == error.RpcLimitExceeded) {
                        const new_batch = @max(self.batch_size / 2, 100);
                        log.warn("模板 {s}: 补扫触发 RPC limit，batch_size {} → {}", .{ self.contract.name, self.batch_size, new_batch });
                        self.batch_size = new_batch;
                    } else {
                        log.warn("模板 {s}: 补扫 {s} 失败 ({d}~{d}): {any}，保持 pending 下轮重试", .{ self.contract.name, p.address, range[0], range[1], e });
                    }
                    continue; // 保持 pending
                };
                log.info("模板 {s}: 补扫完成 {s} ({d}~{d})", .{ self.contract.name, p.address, range[0], range[1] });
            }
            // 无需补扫（发现块已被主 sweep 覆盖）或补扫成功 → 并入 live
            self.markAddressBackfilled(p.address);
        }
    }

    /// 按 batch_size 分块补扫半开区间 `[from_block, to_block)`。
    /// eth_getLogs 的 toBlock 是**闭区间**，故把上界换算为 `to_block - 1`——补扫恰好覆盖
    /// "发现块 .. 游标-1"，与主 sweep（从游标块起，闭区间）无缝衔接且不重叠。
    fn backfillRange(self: *Indexer, address: []const u8, from_block: u64, to_block: u64) !void {
        // 调用方保证 to_block > from_block，故 last 不欠账
        const last = to_block - 1;
        const one = [_][]const u8{address};
        var from = from_block;
        while (nextBackfillChunk(from, self.batch_size, last)) |chunk| {
            try self.syncRangeWithAddresses(&one, chunk[0], chunk[1]);
            from = chunk[1] + 1;
        }
    }

    /// 补扫完成：落库标记 + 内存 pending → live。
    /// DB 标记失败只告警：内存已并入 live，重启后会按 backfilled=0 重新补扫（幂等）。
    fn markAddressBackfilled(self: *Indexer, address: []const u8) void {
        self.database.markTemplateAddressBackfilled(self.contract.name, address) catch |e| {
            log.warn("模板 {s}: 标记补扫完成失败 {s}: {any}", .{ self.contract.name, address, e });
        };
        self.lockTemplateSet();
        defer self.unlockTemplateSet();
        self.template_set.markBackfilled(address);
    }

    /// 在锁内快照 pending 队列（`discoverAddress` 可能从工厂线程并发追加），
    /// 释放锁后再做 RPC，避免阻塞发现路径。
    fn snapshotPending(self: *Indexer) ![]PendingBackfill {
        self.lockTemplateSet();
        defer self.unlockTemplateSet();

        const src = self.template_set.pending();
        const out = try self.alloc.alloc(PendingBackfill, src.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |p| self.alloc.free(p.address);
            self.alloc.free(out);
        }
        for (src, 0..) |p, i| {
            out[i] = .{ .address = try self.alloc.dupe(u8, p.address), .from_block = p.from_block };
            filled = i + 1;
        }
        return out;
    }

    /// 解析字符串为 u256（支持十进制和 0x 十六进制）
    fn parseU256(s: []const u8) !u256 {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (std.mem.startsWith(u8, trimmed, "0x")) {
            return std.fmt.parseInt(u256, trimmed[2..], 16);
        }
        return std.fmt.parseInt(u256, trimmed, 10);
    }

    /// 检查事件是否满足配置的过滤条件（无匹配 filter 时默认通过）
    fn shouldRecordEvent(self: *Indexer, event_name: []const u8, fields: []const db.DecodedField) bool {
        for (self.contract.filters) |filter| {
            if (!std.mem.eql(u8, filter.event, event_name)) continue;
            for (fields) |field| {
                if (!std.mem.eql(u8, field.name, filter.field)) continue;
                const field_val = parseU256(field.value) catch {
                    log.warn("过滤字段值解析失败: {s}={s}，默认通过", .{ field.name, field.value });
                    return true;
                };
                const filter_val = parseU256(filter.value) catch {
                    log.warn("过滤器值解析失败: {s}={s}，默认通过", .{ filter.field, filter.value });
                    return true;
                };
                if (std.mem.eql(u8, filter.op, "gt")) return field_val > filter_val;
                if (std.mem.eql(u8, filter.op, "gte")) return field_val >= filter_val;
                if (std.mem.eql(u8, filter.op, "lt")) return field_val < filter_val;
                if (std.mem.eql(u8, filter.op, "lte")) return field_val <= filter_val;
                if (std.mem.eql(u8, filter.op, "eq")) return field_val == filter_val;
            }
        }
        return true;
    }

    /// 处理单条日志：解码、过滤并写入对应事件表
    fn processLog(self: *Indexer, lg: eth_rpc.Log) !void {
        if (self.abi_contract) |ac| {
            if (lg.topics.len > 0) {
                const topic0 = lg.topics[0];
                if (topic0.len != 66 or !std.mem.startsWith(u8, topic0, "0x")) {
                    log.warn("畸形 topic0 (tx: {s}): 长度={d}, 内容={s}", .{ lg.transaction_hash, topic0.len, topic0 });
                    return error.InvalidTopic;
                }
                var sig_buf: [32]u8 = undefined;
                const written = try std.fmt.hexToBytes(&sig_buf, topic0[2..]);
                if (written.len != 32) {
                    log.warn("topic0 解码不完整 (tx: {s}): 期望 32 字节, 实际 {d} 字节", .{ lg.transaction_hash, written.len });
                    return error.InvalidTopic;
                }
                if (ac.findEventByTopic0(&sig_buf)) |evt| {
                    const decoded = try abi.decodeLog(self.alloc, evt, lg.topics, lg.data);
                    defer {
                        for (decoded.fields) |f| {
                            self.alloc.free(f.value);
                        }
                        self.alloc.free(decoded.fields);
                    }

                    // 将 DecodedField 转为 db.DecodedField
                    var db_fields: std.ArrayList(db.DecodedField) = .empty;
                    defer db_fields.deinit(self.alloc);

                    for (decoded.fields) |f| {
                        try db_fields.append(self.alloc, .{
                            .name = f.name,
                            .value = f.value,
                        });
                    }

                    // 应用配置的过滤条件
                    if (!self.shouldRecordEvent(evt.name, db_fields.items)) {
                        log.debug("跳过 {s}.{s} @ 区块 {}（不满足过滤条件）", .{ self.contract.name, evt.name, lg.block_number });
                        return;
                    }

                    try self.database.insertEventLog(
                        self.contract.name,
                        evt.name,
                        db_fields.items,
                        lg.block_number,
                        lg.transaction_hash,
                        lg.log_index,
                        // 日志来源地址：模板模式下即该事件所属的 clone；
                        // 单合约模式下 getLogs 只过滤单地址，lg.address == contract.address。
                        lg.address,
                    );

                    if (std.mem.eql(u8, evt.name, "Transfer")) {
                        self.trackTokenTransferState(lg.address, db_fields.items, lg.block_number);
                    }

                    log.debug("已写入 {s}.{s} @ 区块 {}", .{ self.contract.name, evt.name, lg.block_number });

                    if (self.factory_callback) |cb| {
                        if (self.factory_ctx) |fctx| {
                            cb(fctx, self.factory_idx, evt.name, db_fields.items, lg.block_number);
                        }
                    }
                    if (self.event_callback) |cb| {
                        const block_ts = self.resolveBlockTimestamp(lg.block_number);
                        cb(self.event_callback_ctx, self.contract.name, evt.name, db_fields.items, lg.block_number, block_ts);
                    }
                    return;
                }
            }
        }

        // ABI 无法解析：返回错误让调用方记录，避免静默丢弃
        return error.AbiMismatch;
    }

    /// 自动追踪 ERC-20 / Token 的 Transfer 事件，更新 account_states 表余额。
    /// `contract_address` 是日志来源地址（模板模式下区分各 clone 的余额）。
    fn trackTokenTransferState(self: *Indexer, contract_address: []const u8, fields: []const db.DecodedField, block_number: u64) void {
        var from_addr: ?[]const u8 = null;
        var to_addr: ?[]const u8 = null;
        var val_str: ?[]const u8 = null;

        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "from") or std.mem.eql(u8, f.name, "_from")) {
                from_addr = f.value;
            } else if (std.mem.eql(u8, f.name, "to") or std.mem.eql(u8, f.name, "_to")) {
                to_addr = f.value;
            } else if (std.mem.eql(u8, f.name, "value") or std.mem.eql(u8, f.name, "_value") or std.mem.eql(u8, f.name, "tokens") or std.mem.eql(u8, f.name, "amount")) {
                val_str = f.value;
            }
        }

        const transfer_val = parseU256(val_str orelse return) catch return;
        const zero_addr = "0x0000000000000000000000000000000000000000";

        if (from_addr) |fa| {
            if (!std.mem.eql(u8, fa, zero_addr) and fa.len > 0) {
                const current_bal_str = (self.database.getAccountBalance(contract_address, fa) catch null) orelse "0";
                defer if (current_bal_str.ptr != "0".ptr) self.alloc.free(current_bal_str);
                const current_bal = parseU256(current_bal_str) catch 0;
                const new_bal = if (current_bal > transfer_val) current_bal - transfer_val else 0;
                var buf: [128]u8 = undefined;
                const new_bal_str = std.fmt.bufPrint(&buf, "{d}", .{new_bal}) catch return;
                self.database.upsertAccountState(.{
                    .contract_address = contract_address,
                    .account_address = fa,
                    .balance = new_bal_str,
                    .last_updated_block = block_number,
                }) catch |e| {
                    log.warn("更新账户 {s} 余额失败: {any}", .{ fa, e });
                };
            }
        }

        if (to_addr) |ta| {
            if (!std.mem.eql(u8, ta, zero_addr) and ta.len > 0) {
                const current_bal_str = (self.database.getAccountBalance(contract_address, ta) catch null) orelse "0";
                defer if (current_bal_str.ptr != "0".ptr) self.alloc.free(current_bal_str);
                const current_bal = parseU256(current_bal_str) catch 0;
                const new_bal = current_bal + transfer_val;
                var buf: [128]u8 = undefined;
                const new_bal_str = std.fmt.bufPrint(&buf, "{d}", .{new_bal}) catch return;
                self.database.upsertAccountState(.{
                    .contract_address = contract_address,
                    .account_address = ta,
                    .balance = new_bal_str,
                    .last_updated_block = block_number,
                }) catch |e| {
                    log.warn("更新账户 {s} 余额失败: {any}", .{ ta, e });
                };
            }
        }
    }

    /// 存储区块元数据到 blocks 表
    fn storeBlockMetadata(self: *Indexer, block_number: u64) !void {
        const block_data = (try self.rpc.getBlockData(block_number)) orelse return;
        defer {
            self.alloc.free(block_data.hash);
            self.alloc.free(block_data.miner);
            self.alloc.free(block_data.base_fee_per_gas);
        }
        try self.database.upsertBlock(.{
            .chain = self.chain,
            .block_number = block_data.number,
            .block_hash = block_data.hash,
            .timestamp = block_data.timestamp,
            .miner = block_data.miner,
            .gas_used = block_data.gas_used,
            .gas_limit = block_data.gas_limit,
            .base_fee_per_gas = block_data.base_fee_per_gas,
            .transaction_count = block_data.transaction_count,
        });
        // 顺手喂给事件时间戳缓存（track_blocks 已拉取过，避免重复 RPC）
        if (self.event_ts_needed) {
            self.block_ts_cache.put(self.alloc, block_data.number, block_data.timestamp) catch {};
        }
    }

    /// 检查并创建快照
    fn checkSnapshot(self: *Indexer) !void {
        if (self.snapshot_interval == 0) return;

        const now = std.Io.Timestamp.now(self.rpc.io, .real).toSeconds();
        const last = self.last_snapshot_time.load(.monotonic);
        if (now - last < @as(i64, @intCast(self.snapshot_interval))) return;

        const current = self.current_block.load(.monotonic);
        if (current == 0) return;

        // 构建有意义的快照数据（JSON）
        var snap_buf = std.ArrayList(u8).empty;
        snap_buf.print(self.alloc,
            "{{\"block_number\":{d},\"timestamp\":{d},\"contract_address\":\"{s}\",\"contract_name\":\"{s}\"}}",
            .{ current - 1, now, self.stateKey(), self.contract.name },
        ) catch |e| {
            log.warn("快照 JSON 构建失败: {any}", .{e});
            snap_buf.deinit(self.alloc);
            return;
        };
        defer snap_buf.deinit(self.alloc);

        try self.database.createSnapshot(.{
            .contract_address = self.stateKey(),
            .block_number = current - 1,
            .snapshot_data = snap_buf.items,
        });

        self.last_snapshot_time.store(now, .monotonic);
        log.info("合约 {s} 快照已创建 @ 区块 {}", .{ self.contract.name, current - 1 });
    }

    /// 将 topics 数组格式化为 JSON 字符串（调用者负责释放返回值）
    fn formatTopicsJson(alloc: std.mem.Allocator, topics: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(alloc);
        try buf.append(alloc, '[');
        for (topics, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(alloc, ",");
            try buf.append(alloc, '"');
            for (t) |ch| {
                if (ch == '\\') {
                    try buf.appendSlice(alloc, "\\\\");
                } else if (ch == '"') {
                    try buf.appendSlice(alloc, "\\\"");
                } else if (ch == '\n') {
                    try buf.appendSlice(alloc, "\\n");
                } else if (ch == '\r') {
                    try buf.appendSlice(alloc, "\\r");
                } else if (ch == '\t') {
                    try buf.appendSlice(alloc, "\\t");
                } else if (ch <= 0x1F) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{ch});
                    try buf.appendSlice(alloc, esc);
                } else {
                    try buf.append(alloc, ch);
                }
            }
            try buf.append(alloc, '"');
        }
        try buf.append(alloc, ']');
        return try buf.toOwnedSlice(alloc);
    }

    /// 检测链重组并执行回滚。
    /// 返回应该恢复到的区块号（即 fork_point）。
    /// 如果没有检测到重组，返回传入的 block_number（表示无需回滚）。
    fn detectAndHandleReorg(self: *Indexer, block_number: u64) !u64 {
        const reorg_depth = self.contract.max_reorg_depth orelse return block_number;
        if (reorg_depth == 0) return block_number;

        // 获取 RPC 上的当前 hash
        const rpc_hash = self.rpc.getBlockHash(block_number) catch |e| {
            log.warn("获取区块 {d} hash 失败: {any}", .{ block_number, e });
            return block_number; // 无法检测，假设无重组
        };
        defer if (rpc_hash) |h| self.alloc.free(h);
        if (rpc_hash == null) return block_number;

        // 获取本地存储的 hash
        const local_hash = self.database.getBlockHash(self.stateKey(), block_number) catch |e| {
            log.warn("读取区块 {d} hash 失败: {any}", .{ block_number, e });
            return block_number;
        };
        defer if (local_hash) |h| self.alloc.free(h);
        if (local_hash == null) return block_number; // 没有历史记录，无法检测

        // hash 一致，无重组
        if (std.mem.eql(u8, rpc_hash.?, local_hash.?)) return block_number;

        // hash 不一致，发生重组。向后扫描找到分叉点
        log.warn("区块 {d} hash 不匹配: rpc={s}, local={s}", .{ block_number, rpc_hash.?, local_hash.? });
        var scan_block = block_number;
        const min_block = if (block_number > reorg_depth) block_number - reorg_depth else 0;
        while (scan_block > min_block) {
            scan_block -= 1;
            const scan_rpc = self.rpc.getBlockHash(scan_block) catch continue;
            defer if (scan_rpc) |h| self.alloc.free(h);
            if (scan_rpc == null) continue;

            const scan_local = self.database.getBlockHash(self.stateKey(), scan_block) catch continue;
            defer if (scan_local) |h| self.alloc.free(h);
            if (scan_local == null) continue;

            if (std.mem.eql(u8, scan_rpc.?, scan_local.?)) {
                // 找到匹配点，fork_point = scan_block + 1
                const fork_point = scan_block + 1;
                log.warn("找到分叉点 @ 区块 {d}，回滚到 {d}", .{ scan_block, fork_point });
                self.rollbackTo(fork_point);
                return fork_point;
            }
        }

        // 在 safe_depth 内未找到匹配点，回滚到 safe_depth 之前
        const safe_block = min_block;
        log.warn("在 safe_depth({d}) 内未找到匹配点，回滚到 {d}", .{ reorg_depth, safe_block });
        self.rollbackTo(safe_block);
        return safe_block;
    }
};

// ============================================================================
// 单元测试
// ============================================================================

test "formatTopicsJson" {
    const alloc = std.testing.allocator;
    {
        const json = try Indexer.formatTopicsJson(alloc, &.{});
        defer alloc.free(json);
        try std.testing.expectEqualStrings("[]", json);
    }
    {
        const json = try Indexer.formatTopicsJson(alloc, &.{"0xabc"});
        defer alloc.free(json);
        try std.testing.expectEqualStrings("[\"0xabc\"]", json);
    }
    {
        const json = try Indexer.formatTopicsJson(alloc, &.{"0xabc", "0xdef"});
        defer alloc.free(json);
        try std.testing.expectEqualStrings("[\"0xabc\",\"0xdef\"]", json);
    }
}

test "shouldRecordEvent filtering" {
    const alloc = std.testing.allocator;

    var filters = try alloc.alloc(config.EventFilter, 1);
    filters[0] = .{
        .event = try alloc.dupe(u8, "Transfer"),
        .field = try alloc.dupe(u8, "value"),
        .op = try alloc.dupe(u8, "gt"),
        .value = try alloc.dupe(u8, "500"),
    };
    defer {
        for (filters) |f| {
            alloc.free(f.event);
            alloc.free(f.field);
            alloc.free(f.op);
            alloc.free(f.value);
        }
        alloc.free(filters);
    }

    const contract = config.ContractConfig{
        .name = "test",
        .address = "0xabc",
        .abi_path = "",
        .from_block = 0,
        .events = &.{},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = filters,
    };

    var idx = Indexer{
        .alloc = alloc,
        .rpc = undefined,
        .database = undefined,
        .contract = &contract,
        .snapshot_interval = 0,
        .state = std.atomic.Value(IndexerState).init(.stopped),
        .current_block = std.atomic.Value(u64).init(0),
        .last_tip = std.atomic.Value(u64).init(0),
        .last_snapshot_time = std.atomic.Value(i64).init(0),
        .batch_size = 100,
        .poll_interval_ms = 1000,
        .abi_contract = null,
        .thread = null,
        .track_blocks = false,
        .chain = "ethereum",
        .factory_ctx = null,
        .factory_callback = null,
        .factory_idx = 0,
        .template_set = TemplateAddressSet.init(alloc),
    };

    // value = 0x3e8 (1000) > 500 → 通过
    const fields_pass = &.{
        db.DecodedField{ .name = "from", .value = "0x1111" },
        db.DecodedField{ .name = "value", .value = "0x00000000000000000000000000000000000000000000000000000000000003e8" },
    };
    try std.testing.expect(idx.shouldRecordEvent("Transfer", fields_pass));

    // value = 0x64 (100) < 500 → 跳过
    const fields_skip = &.{
        db.DecodedField{ .name = "from", .value = "0x1111" },
        db.DecodedField{ .name = "value", .value = "0x0000000000000000000000000000000000000000000000000000000000000064" },
    };
    try std.testing.expect(!idx.shouldRecordEvent("Transfer", fields_skip));

    // 无 filter 匹配的事件 → 默认通过
    try std.testing.expect(idx.shouldRecordEvent("Approval", fields_pass));
}

test "indexer getStatus and getCurrentBlock" {
    const alloc = std.testing.allocator;

    var rpc_cfg = config.RpcConfig{
        .url = "",
        .retry_count = 0,
        .retry_delay_ms = 0,
        .request_timeout_ms = 0,
        .max_concurrent = 0,
    };
    var db_cfg = db.DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };

    var rpc = eth_rpc.Client.init(alloc, undefined, &rpc_cfg);
    defer rpc.deinit();

    var database = try db.Client.init(alloc, &db_cfg);
    defer database.deinit();

    const contract = config.ContractConfig{
        .name = "test",
        .address = "0xabc",
        .abi_path = "",
        .from_block = 0,
        .events = &.{},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = &.{},
    };

    var idx = Indexer{
        .alloc = alloc,
        .rpc = &rpc,
        .database = &database,
        .contract = &contract,
        .snapshot_interval = 0,
        .state = std.atomic.Value(IndexerState).init(.stopped),
        .current_block = std.atomic.Value(u64).init(100),
        .last_tip = std.atomic.Value(u64).init(100),
        .last_snapshot_time = std.atomic.Value(i64).init(0),
        .batch_size = 100,
        .poll_interval_ms = 1000,
        .abi_contract = null,
        .thread = null,
        .track_blocks = false,
        .chain = "ethereum",
        .factory_ctx = null,
        .factory_callback = null,
        .factory_idx = 0,
        .template_set = TemplateAddressSet.init(alloc),
    };

    try std.testing.expectEqual(IndexerState.stopped, idx.getStatus());
    try std.testing.expectEqual(@as(u64, 100), idx.getCurrentBlock());

    idx.state.store(.running, .monotonic);
    try std.testing.expectEqual(IndexerState.running, idx.getStatus());

    idx.current_block.store(200, .monotonic);
    try std.testing.expectEqual(@as(u64, 200), idx.getCurrentBlock());
}

// ============================================================================
// 模板模式单测（Task 7）
// 不构造 Indexer 字面量：其 `rpc = undefined`，误触 deinit 会踩未定义指针。
// 地址集合逻辑落在 TemplateAddressSet 上，区间/构造逻辑用纯函数测。
// ============================================================================

test "template computeBackfillRange 无缺口无重叠" {
    // 发现于 100，当前游标 250 → 补 [100, 250)
    try std.testing.expectEqual([2]u64{ 100, 250 }, computeBackfillRange(100, 250));
    // 同一批内发现（发现区块 == 游标）→ 主 sweep 会覆盖，无需补扫
    try std.testing.expectEqual([2]u64{ 0, 0 }, computeBackfillRange(250, 250));
    // 发现区块晚于游标 → 空区间
    try std.testing.expectEqual([2]u64{ 0, 0 }, computeBackfillRange(300, 250));
    // 创世块发现：{0,N} 是合法区间，与空区间哨兵 {0,0} 不冲突（合法区间必 range[1] > 0）
    try std.testing.expectEqual([2]u64{ 0, 1 }, computeBackfillRange(0, 1));
}

test "template 补扫分块连续无重叠（闭区间换算）" {
    // 半开区间 [5, 25) → eth_getLogs 闭区间 [5, 24]；batch=10 → [5,14] [15,24]
    const last: u64 = 24;
    var from: u64 = 5;
    var chunks: [8][2]u64 = undefined;
    var n: usize = 0;
    while (nextBackfillChunk(from, 10, last)) |c| {
        chunks[n] = c;
        n += 1;
        from = c[1] + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual([2]u64{ 5, 14 }, chunks[0]);
    try std.testing.expectEqual([2]u64{ 15, 24 }, chunks[1]);

    // 单块（batch 足够大）；越过末尾返回 null
    try std.testing.expectEqual([2]u64{ 100, 249 }, nextBackfillChunk(100, 500, 249).?);
    try std.testing.expect(nextBackfillChunk(250, 500, 249) == null);
}

test "template 地址集合去重/补扫流转" {
    const alloc = std.testing.allocator;
    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();

    try std.testing.expect(set.add("0xA", 10)); // 新地址 → true
    try std.testing.expect(!set.add("0xA", 10)); // 重复 → false
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expectEqual(@as(usize, 1), set.pending().len);
    try std.testing.expectEqual(@as(usize, 0), set.all().len); // 尚未并入 live
    try std.testing.expectEqual(@as(u64, 10), set.pending()[0].from_block);

    set.markBackfilled("0xA");
    try std.testing.expectEqual(@as(usize, 0), set.pending().len);
    try std.testing.expectEqualStrings("0xA", set.all()[0]);
    // live 中的地址再发现 → false，且不会退回 pending
    try std.testing.expect(!set.add("0xA", 10));
    try std.testing.expectEqual(@as(usize, 0), set.pending().len);
    // 未知地址 markBackfilled 幂等无操作
    set.markBackfilled("0xdead");
    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "template 同块发现的多个 clone 独立补扫（不依赖发现顺序）" {
    const alloc = std.testing.allocator;
    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();

    try std.testing.expect(set.add("0xaaa", 10));
    try std.testing.expect(set.add("0xbbb", 10)); // 同 from_block
    try std.testing.expectEqual(@as(usize, 2), set.pending().len);

    // 后加入的先完成：不影响另一个仍处于 pending（不依赖同块排序）
    set.markBackfilled("0xbbb");
    try std.testing.expectEqual(@as(usize, 1), set.pending().len);
    try std.testing.expectEqualStrings("0xaaa", set.pending()[0].address);
    try std.testing.expectEqual(@as(usize, 1), set.all().len);

    set.markBackfilled("0xaaa");
    try std.testing.expectEqual(@as(usize, 0), set.pending().len);
    try std.testing.expectEqual(@as(usize, 2), set.all().len);
}

test "template 空地址集合不得发起 getLogs（携转约束 1）" {
    // 空集合在 LogFilter 层序列化为 "address":null，语义是"不过滤地址"，
    // 会拉回整段区块内全部合约日志（放大面极大）→ 构造层必须短路。
    try std.testing.expect(makeLogFilter(&.{}, null, 1, 2) == null);

    const one = makeLogFilter(&.{"0xaa"}, null, 1, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), one.addresses.?.len);
    try std.testing.expectEqualStrings("0xaa", one.addresses.?[0]);
    try std.testing.expectEqual(@as(?u64, 1), one.from_block);
    try std.testing.expectEqual(@as(?u64, 2), one.to_block);
    try std.testing.expect(one.topics == null);

    // 与真实集合串起来：空集 → 不查询；加入并回填后 → 可查询
    var set = TemplateAddressSet.init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expect(makeLogFilter(set.all(), null, 1, 2) == null);
    _ = set.add("0xaa", 1);
    try std.testing.expect(makeLogFilter(set.all(), null, 1, 2) == null); // 仅 pending，仍未 live
    set.markBackfilled("0xaa");
    try std.testing.expect(makeLogFilter(set.all(), null, 1, 2) != null);
}

test "template 地址归一化（唯一入口，小写 hex）" {
    const mixed = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01";
    try std.testing.expectEqual(@as(usize, 42), mixed.len);
    var buf: [42]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0xabcdef0123456789abcdef0123456789abcdef01",
        normalizeHexAddress(&buf, mixed).?,
    );
    // 非 42 字符 / 缺 0x 前缀 → 拒绝（不落库，避免主键因大小写或畸形分裂）
    try std.testing.expect(normalizeHexAddress(&buf, "0xA") == null);
    try std.testing.expect(normalizeHexAddress(&buf, "AbCdEf0123456789AbCdEf0123456789AbCdEf01") == null);
    try std.testing.expect(normalizeHexAddress(&buf, "") == null);
}

test "template loadTemplateAddresses 上抛读库错误（携转约束 2：不吞掉）" {
    const alloc = std.testing.allocator;
    const cfg = db.DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try db.Client.init(alloc, &cfg);
    defer client.deinit();

    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();

    // 未 migrate：表不存在。RocksDB 后端则是 error.UnsupportedOperation。
    // 两种情况都必须原样上抛，由 Task 8 在启动期转成 fail-fast——
    // 绝不能吞掉当成"空地址集合"继续跑（那会在第一个 clone 才发现时炸，或静默漏索引）。
    if (loadTemplateAddressesInto(&set, &client, "curve")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), set.count());
}
