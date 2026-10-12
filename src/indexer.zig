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
    contract_address: []const u8,
    /// 日志在交易内的位置：`(tx_hash, log_index)` 唯一确定一条日志，
    /// 投影表要靠它给出可跳区块浏览器的稳定主键。
    tx_hash: []const u8,
    log_index: u64,
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
    /// live 地址（主 sweep 的过滤集合），与 `live_blocks` 一一对应。
    live: std.ArrayList([]const u8) = .empty,
    /// 每个 live 地址的发现区块（与 `live` 同长），供重组按块作废使用。
    live_blocks: std.ArrayList(u64) = .empty,
    pending_list: std.ArrayList(PendingBackfill) = .empty,

    pub fn init(alloc: std.mem.Allocator) TemplateAddressSet {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TemplateAddressSet) void {
        for (self.live.items) |a| self.alloc.free(a);
        for (self.pending_list.items) |p| self.alloc.free(p.address);
        self.live.deinit(self.alloc);
        self.live_blocks.deinit(self.alloc);
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
                return;
            };
            self.live_blocks.append(self.alloc, moved.from_block) catch {
                // 保持 live / live_blocks 等长：回滚刚追加的 live 项
                const dropped = self.live.pop().?;
                self.alloc.free(dropped);
                return;
            };
            return;
        }
    }

    /// 重组：作废发现区块 >= `from_block` 的条目（与 DB 的
    /// `deleteTemplateAddressesFromBlock` 同语义），pending 与 live 都移除并释放，
    /// 使内存集合与 DB 一致。`from_block < from_block` 的真实 clone 保留。
    ///
    /// 若不这样做：fork 之后创建的 clone 在 DB 里被删、内存 live 仍留着；新链上重新发现
    /// 同一地址时 `add` 因去重返回 false → 不再落库；本进程内无碍，但**重启后**该地址
    /// 从库里消失 → 不再进 live → 主 sweep 从已越过其发现块的游标开始 → 该 clone 后续
    /// 事件静默不再索引（跨重启漏索引）。
    pub fn removeFromBlock(self: *TemplateAddressSet, from_block: u64) void {
        var i: usize = 0;
        while (i < self.pending_list.items.len) {
            if (self.pending_list.items[i].from_block >= from_block) {
                const removed = self.pending_list.orderedRemove(i);
                self.alloc.free(removed.address);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.live.items.len) {
            if (self.live_blocks.items[i] >= from_block) {
                const removed = self.live.orderedRemove(i);
                _ = self.live_blocks.orderedRemove(i);
                self.alloc.free(removed);
            } else {
                i += 1;
            }
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

/// 补扫的闭区间上界：把半开上界（= 探测时游标，不含游标块）换算成 eth_getLogs
/// 的 `toBlock`。调用方须保证 `to_exclusive > from_block >= 0`，故不欠账。
/// 单点收敛该换算，测试可直接断言 `backfillLast(cursor) == cursor - 1`。
fn backfillLast(to_exclusive: u64) u64 {
    return to_exclusive - 1;
}

/// 补扫分块推进：`from` 起、半开上界 `to_exclusive`，返回本块**闭区间** `[from, end]`。
/// 返回 null 表示已越过末尾。eth_getLogs 的 toBlock 是闭区间，故内部经 `backfillLast`
/// 做一次上界换算；这样"补扫恰好覆盖 [from, 游标)"的换算不会漏在调用方里。
/// `batch_size` 在读取侧已夹紧为 >=1，这里再防御性夹紧一次：0 若漏进来，`batch_size - 1`
/// 会下溢，或（若只判 null）退化成"零推进却标记完成"→ 永久漏扫。
fn nextBackfillChunk(from: u64, batch_size: u64, to_exclusive: u64) ?[2]u64 {
    const batch = clampBatchSize(batch_size);
    if (from >= to_exclusive) return null;
    return .{ from, @min(from +| (batch - 1), backfillLast(to_exclusive)) };
}

/// 批次大小下限夹紧：`block_batch_size = 0` 视为逐块（1），绝不退化为 0。
fn clampBatchSize(raw: u64) u64 {
    return @max(1, raw);
}

/// 主 sweep 单次 `eth_getLogs` 的默认地址数上限（`[[templates]]` 未配
/// `max_addresses_per_request` 时）。目标规模是几千 clone，一次全塞进请求会
/// 必然超 RPC 上限，故默认就分块。
pub const default_max_addresses_per_request: u32 = 200;

/// 单次请求的地址数上限夹紧：0 视为 1（上限为 0 若不夹紧会让分块循环零推进）。
fn clampAddressBatch(raw: u32) usize {
    return @max(1, raw);
}

/// 第 `index` 块在地址集里的半开区间 `[start, end)`；已越过末尾返回 null。
/// 相邻块首尾相接（下一块起点 == 上一块终点）、步长恒为上限，
/// 因此各块恰好铺满 `[0, len)`：既不重叠也不遗漏。
fn addressChunkAt(len: usize, max_raw: u32, index: usize) ?[2]usize {
    const max = clampAddressBatch(max_raw);
    const start = index *| max;
    if (start >= len) return null;
    return .{ start, @min(start +| max, len) };
}

/// `loadTemplateAddresses` 的前置校验：未开模板模式必须报错。
/// 若静默返回，Task 8 把 `setTemplateMode(true)` 写在 `loadTemplateAddresses()` 之后时，
/// 携转约束 2 的启动期 fail-fast（RocksDB 也含在内）会失效；地址集合恒为空 → 空集短路
/// 让主 sweep 照常推进游标 → 进程"看起来在跑"却什么都没索引。
fn ensureTemplateMode(template_mode: bool) !void {
    if (!template_mode) return error.NotTemplateMode;
}

/// `setTemplateMode` 的前置校验：运行中不得再切换模板模式（游标 key/运行态都依赖它）。
fn ensureNotRunning(state: IndexerState) !void {
    if (state == .running or state == .replaying) return error.AlreadyRunning;
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

/// 复制 pending 队列为可独立使用的切片（调用方可在释放锁后安全迭代/做 RPC）。
/// 每个 `address` 都是新 dupe；调用方须逐个 `alloc.free(p.address)` 再 `alloc.free(切片)`。
/// 调用方须保证持有 `template_set` 的锁（或处于单线程启动期）。
fn dupePending(set: *TemplateAddressSet, alloc: std.mem.Allocator) ![]PendingBackfill {
    const src = set.pending();
    const out = try alloc.alloc(PendingBackfill, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |p| alloc.free(p.address);
        alloc.free(out);
    }
    for (src, 0..) |p, i| {
        out[i] = .{ .address = try alloc.dupe(u8, p.address), .from_block = p.from_block };
        filled = i + 1;
    }
    return out;
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
    /// 本索引器作为发现源时，挂在其上的工厂规则下标（可多条：一个发现源可以
    /// 有多条规则，各有 creation_event / child_address_field / 目标模板）。
    factory_idxs: std.ArrayListUnmanaged(usize) = .empty,
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
    /// 主 sweep 单次 `eth_getLogs` 携带的最大 clone 地址数（见 setMaxAddressesPerRequest）。
    /// 默认 `default_max_addresses_per_request`；测试用的结构体字面量省略该字段即取默认值。
    max_addresses_per_request: u32 = default_max_addresses_per_request,

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

        // block_batch_size = 0 是合法配置输入（parseU32 接受 "0"，validate 不校验）：
        // 夹紧为 1（逐块，与主 sweep "0 退化为逐块" 的既有行为一致）。
        // 若不夹紧，nextBackfillChunk 会退化成"零推进"→ processPendingBackfills 仍标记
        // 补扫完成 → [from_block, cursor) 永不扫描，历史事件永久丢失且无告警。
        const batch_size = clampBatchSize(contract.block_batch_size orelse 500);
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
    /// 必须在 `start()` 之前调用；运行中调用会被拒绝（log.err 后 no-op）。开启后：
    /// - 游标/hash/快照改用合成 key `template:<模板名>`（模板的 contract.address 是空串，
    ///   直接用会与"无地址"发生碰撞；合成 key 与设计文档 §2.2.1 的约定一致）；
    /// - 重新按该 key 载入断点（`init` 时还不知道模板模式，读的是空地址的键）。
    pub fn setTemplateMode(self: *Indexer, enabled: bool) void {
        // 运行中切换会让游标 key 与已推进的 state 不一致，直接拒绝（Task 8 有启动顺序 bug 时能立刻暴露）
        ensureNotRunning(self.state.load(.monotonic)) catch |e| {
            log.err("模板 {s}: setTemplateMode 必须在 start() 之前调用，已忽略: {any}", .{ self.contract.name, e });
            return;
        };

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

        // getSyncState 返回 `!?SyncState`，必须分两步解包：先 catch 掉错误（告警后按
        // 配置起始区块继续，不阻断启动），再对 `?SyncState` 做 if 捕获。
        // 直接写 `if (db.getSyncState(key)) |state|` 会把整个 error union 当错误分支解包，
        // state 的类型是 `?SyncState`，字段访问编译不过（且因无调用方而被惰性分析掩盖）。
        // 注意 `try` 在 `void` 函数里非法，故用 catch。
        const existing = self.database.getSyncState(key) catch |e| {
            log.warn("模板 {s} 读取断点失败: {any}，从配置起始区块开始", .{ self.contract.name, e });
            return;
        };
        if (existing) |state| {
            self.current_block.store(state.last_synced_block, .monotonic);
            self.last_tip.store(state.last_synced_block, .monotonic);
            log.info("模板 {s} 从断点续传: 区块 {}", .{ self.contract.name, state.last_synced_block });
            self.alloc.free(state.contract_address);
            self.alloc.free(state.status);
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

    /// 设置模板主 sweep 的地址分块上限（`null` 用默认值；0 视为 1）。
    /// 地址集合按该上限切块、逐块 `eth_getLogs`：几千 clone 时一次全量请求必然超 RPC 上限。
    /// 必须在 `start()` 之前调用（运行中改会让同一次 sweep 的块边界漂移）。
    pub fn setMaxAddressesPerRequest(self: *Indexer, raw: ?u32) void {
        self.max_addresses_per_request = @intCast(clampAddressBatch(raw orelse default_max_addresses_per_request));
    }

    /// 当前生效的地址分块上限（状态展示/测试用）。
    pub fn getMaxAddressesPerRequest(self: *Indexer) u32 {
        return self.max_addresses_per_request;
    }

    /// 启动时从库恢复模板地址集合。必须在 `start()` 之前调用。
    /// 未开模板模式时返回 `error.NotTemplateMode`（**不静默返回**：Task 8 若把
    /// `setTemplateMode(true)` 写在后面，这里会立刻炸，携转约束 2 的 fail-fast 不会失效）。
    /// 读库错误（含 RocksDB 后端的 `error.UnsupportedOperation`）原样上抛，
    /// 由 Task 8 在启动期转成 fail-fast——不会等到发现第一个 clone 才炸（携转约束 2）。
    pub fn loadTemplateAddresses(self: *Indexer) !void {
        try ensureTemplateMode(self.template_mode);
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
        self.factory_idxs.deinit(self.alloc);
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
    /// 模板模式额外作废 `from_block >= fork_block` 的 clone 记录——DB 与内存集合
    /// **一起**删（fork 之后创建的 clone 与它们的全部事件一致作废，无需地址谓词）。
    /// 两者在 `template_mutex` 内串行，故与并发 `discoverAddress` 不会交错出内存/DB 分叉。
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
            self.lockTemplateSet();
            defer self.unlockTemplateSet();
            self.database.deleteTemplateAddressesFromBlock(self.contract.name, fork_block) catch |e| {
                log.warn("清理克隆地址记录失败: {any}", .{e});
            };
            self.template_set.removeFromBlock(fork_block);

            // 补偿并发插入：`rollbackFromBlock` 是多语句事务，工厂线程的
            // `addTemplateAddress`（单语句）若恰好落在同一事务里，回滚（失败时的
            // ROLLBACK）会把这条**不该删**的地址行一起丢弃——内存里该 clone 仍存活，
            // 但重启后库里没有它 → 不再进 live → 主 sweep 不再覆盖它（跨重启不自愈）。
            // 这里把内存中仍存活的 live 地址幂等补回：`ON CONFLICT DO NOTHING` 不会覆盖
            // 已有进度；`removeFromBlock` 已先删掉 fork 之后的条目，故补回的恰是该留的那批。
            // 全程持锁 → 与 `discoverAddress` 不会交错（其插入不受本次补偿影响）。
            for (self.template_set.live.items, self.template_set.live_blocks.items) |addr, from_block| {
                self.database.addTemplateAddress(self.contract.name, addr, from_block) catch |e| {
                    log.warn("模板 {s}: 回滚后补回 clone 地址失败 {s}: {any}", .{ self.contract.name, addr, e });
                };
            }
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
                                self.stateKey(),
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
    ///
    /// 地址集合按 `max_addresses_per_request` 分块（模板模式地址数可达数千，一次请求必然
    /// 超 RPC 上限）：块与块恰好铺满整个集合，每块对**同一个** `[from_block, to_block]`
    /// 独立 `getLogs`。因此区间内不遗漏（分块铺满、每块都处理），正常路径也不重复（地址互斥，
    /// getLogs 按地址过滤）。
    ///
    /// 但若前几块已落库、后面的块失败，整轮 `try` 中断后下一轮会重取整段，重复日志仍会到达
    /// `processLog`。此时靠 `insertEventLog` 返回 false 把重复**静默跳过**：行不重复写，
    /// 且跳过时**不**执行余额追踪、**不**触发 factory/event 回调与投影——所以既不会污染
    /// raw_logs 死信表，也不会二次累加。
    fn syncRangeWithAddresses(
        self: *Indexer,
        addresses: []const []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        if (addresses.len == 0) {
            log.debug("模板 {s}: 地址集合为空，跳过区块 {}~{}（不发请求）", .{ self.contract.name, from_block, to_block });
            return;
        }

        const topics = try self.buildEventTopics();
        defer self.freeEventTopics(topics);
        const topics_opt: ?[]const []const u8 = if (topics.len > 0) topics else null;

        // 分块只影响"一次请求带多少地址"；区间边界（from/to）与单块路径完全一致。
        var chunk: usize = 0;
        while (addressChunkAt(addresses.len, self.max_addresses_per_request, chunk)) |b| : (chunk += 1) {
            try self.syncRangeChunk(addresses[b[0]..b[1]], topics_opt, from_block, to_block);
        }
    }

    /// 单块地址的实际拉取 + 落库（分块由 `syncRangeWithAddresses` 负责）。
    fn syncRangeChunk(
        self: *Indexer,
        addresses: []const []const u8,
        topics: ?[]const []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        const filter = makeLogFilter(addresses, topics, from_block, to_block) orelse return;

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
    /// 失败则保持 pending、下一轮重试——边界重叠产生的重复日志由 `insertEventLog` 返回
    /// false 静默跳过（不落第二行、不跑回调），因此补扫与主 sweep 不会重复投影。
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
    /// 闭区间换算与分块都在 `nextBackfillChunk` 内（含 batch_size==0 保护）。
    fn backfillRange(self: *Indexer, address: []const u8, from_block: u64, to_block: u64) !void {
        const one = [_][]const u8{address};
        var from = from_block;
        while (nextBackfillChunk(from, self.batch_size, to_block)) |chunk| {
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
        return dupePending(&self.template_set, self.alloc);
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
        // 日志来源地址只归一化这一次，落库/回调/余额追踪共用同一个形态。
        // 模板模式下必须与 `discoverAddress` 落 `template_addresses` 的形态一致（都是小写
        // hex）：`?address=` 与 GraphQL 是精确匹配，同一 clone 若两处大小写不同就永远查不到。
        // 非 `0x` + 40 hex 的形态（如单测里的哨兵值）保持原样——单合约模式下它本就是
        // 配置里的 contract.address，不得改写。
        var addr_buf: [42]u8 = undefined;
        const source_address = normalizeHexAddress(&addr_buf, lg.address) orelse lg.address;

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

                    // 去重判定：`insertEventLog` 返回 false 表示该
                    // `(contract_address, tx_hash, log_index)` 已存在（分块 getLogs 局部失败后
                    // 重取整段时必然出现）。此时必须**整体早退**：不写 raw_logs（它不是"未静默
                    // 丢弃的日志"）、不跑余额追踪、不触发 factory/event 回调——否则投影会二次累加。
                    const inserted = try self.database.insertEventLog(
                        self.contract.name,
                        evt.name,
                        db_fields.items,
                        lg.block_number,
                        lg.transaction_hash,
                        lg.log_index,
                        // 日志来源地址：模板模式下即该事件所属的 clone（已归一化，与
                        // discoverAddress 落库的形态一致）；单合约模式下 getLogs 只过滤
                        // 单地址，lg.address == contract.address。
                        source_address,
                    );
                    if (!inserted) {
                        log.debug("跳过重复日志 {s}.{s} @ 区块 {}（tx: {s}, log_index: {}）", .{ self.contract.name, evt.name, lg.block_number, lg.transaction_hash, lg.log_index });
                        return;
                    }

                    if (std.mem.eql(u8, evt.name, "Transfer")) {
                        self.trackTokenTransferState(source_address, db_fields.items, lg.block_number);
                    }

                    log.debug("已写入 {s}.{s} @ 区块 {}", .{ self.contract.name, evt.name, lg.block_number });

                    if (self.factory_callback) |cb| {
                        if (self.factory_ctx) |fctx| {
                            // 一个发现源可以挂多条规则（各有 creation_event /
                            // child_address_field / 目标模板），逐条喂给工厂管理器。
                            for (self.factory_idxs.items) |fi| {
                                cb(fctx, fi, evt.name, db_fields.items, lg.block_number);
                            }
                        }
                    }
                    if (self.event_callback) |cb| {
                        const block_ts = self.resolveBlockTimestamp(lg.block_number);
                        // 事件来源地址：模板模式下是该事件所属的 clone；单合约模式下
                        // getLogs 只过滤 contract.address，故 lg.address 即 contract.address
                        // （与上方 insertEventLog 同一条不变量，共用同一归一化结果）。
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

test "template backfillLast = 游标 - 1（不含游标块）" {
    // eth_getLogs 的 toBlock 是闭区间；半开上界（游标）换算成 toBlock 必须减 1，
    // 否则补扫会多扫游标块、与主 sweep 重叠（UNIQUE 冲突 → raw_logs 死信噪声）。
    try std.testing.expectEqual(@as(u64, 249), backfillLast(250));
    try std.testing.expectEqual(@as(u64, 99), backfillLast(100));
    try std.testing.expectEqual(@as(u64, 0), backfillLast(1));
    // 与分块联动：终块的闭区间上界必须是 游标-1，绝不含游标块
    try std.testing.expectEqual(@as(u64, 249), nextBackfillChunk(100, 500, 250).?[1]);
}

test "template 补扫分块连续无重叠（闭区间换算）" {
    // 游标 25（半开 [5, 25)）→ eth_getLogs 闭区间上界 24；batch=10 → [5,14] [15,24]
    var from: u64 = 5;
    var chunks: [8][2]u64 = undefined;
    var n: usize = 0;
    while (nextBackfillChunk(from, 10, 25)) |c| {
        chunks[n] = c;
        n += 1;
        from = c[1] + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual([2]u64{ 5, 14 }, chunks[0]);
    try std.testing.expectEqual([2]u64{ 15, 24 }, chunks[1]); // 不含游标块 25

    // 单块（batch 足够大）：终块恰好到 游标-1，绝不含游标块
    try std.testing.expectEqual([2]u64{ 100, 249 }, nextBackfillChunk(100, 500, 250).?);
    // 起点即游标 → 无块
    try std.testing.expect(nextBackfillChunk(250, 500, 250) == null);
    // batch_size == 0 夹紧为逐块：必须真的推进（不是 null，否则零 RPC 却标记完成）
    try std.testing.expectEqual([2]u64{ 0, 0 }, nextBackfillChunk(0, 0, 100).?);
}

test "template batch_size = 0 时补扫仍逐块推进（不得零推进却标记完成）" {
    // batch=0 若不夹紧会返回 null → backfillRange 的 while 体一次都不执行
    // （零 RPC）→ processPendingBackfills 仍 markAddressBackfilled → [from,cursor) 永不扫描。
    // 这里用纯分块循环证明"真的推进到底"：5 块、逐块、恰好覆盖 [0, 5)。
    var from: u64 = 0;
    var iterations: usize = 0;
    while (nextBackfillChunk(from, 0, 5)) |c| {
        try std.testing.expectEqual(from, c[0]);
        try std.testing.expectEqual(c[0], c[1]); // batch 夹紧为 1 → 每块恰好 1 个
        from = c[1] + 1;
        iterations += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), iterations);
    try std.testing.expectEqual(@as(u64, 5), from);

    // 读取侧夹紧：block_batch_size = 0 → 1（逐块），不得为 0
    try std.testing.expectEqual(@as(u64, 1), clampBatchSize(0));
    try std.testing.expectEqual(@as(u64, 1), clampBatchSize(1));
    try std.testing.expectEqual(@as(u64, 500), clampBatchSize(500));
}

test "template 地址分块不重不漏（整除/有余/max>len/max==0 防御）" {
    const addrs = [_][]const u8{ "0xA", "0xB", "0xC", "0xD", "0xE" };
    const per_one = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 5 } };
    const Case = struct { max: u32, bounds: []const [2]usize };
    const cases = [_]Case{
        .{ .max = 5, .bounds = &.{.{ 0, 5 }} }, // 整除：恰好一块
        .{ .max = 3, .bounds = &.{ .{ 0, 3 }, .{ 3, 5 } } }, // 有余：末块短
        .{ .max = 2, .bounds = &.{ .{ 0, 2 }, .{ 2, 4 }, .{ 4, 5 } } },
        .{ .max = 1, .bounds = &per_one }, // 逐地址
        .{ .max = 10, .bounds = &.{.{ 0, 5 }} }, // max > len：单块
        .{ .max = 0, .bounds = &per_one }, // 防御：夹紧为 1，绝不能零推进（否则永不前进）
    };
    for (cases) |cs| {
        var chunk: usize = 0;
        while (addressChunkAt(addrs.len, cs.max, chunk)) |b| : (chunk += 1) {
            try std.testing.expect(chunk < cs.bounds.len);
            try std.testing.expectEqual(cs.bounds[chunk], b);
        }
        // 块数精确匹配：少一块（漏地址）或多一块（重复）都会在这里红
        try std.testing.expectEqual(cs.bounds.len, chunk);
    }

    // 空集合：一块都没有 → 主 sweep 一次请求都不发（携转约束 1 的纯函数侧）
    try std.testing.expect(addressChunkAt(0, 5, 0) == null);
    // 上限夹紧（0 视为 1）
    try std.testing.expectEqual(@as(usize, 1), clampAddressBatch(0));
    try std.testing.expectEqual(@as(usize, 200), clampAddressBatch(200));
    try std.testing.expectEqual(@as(u32, 200), default_max_addresses_per_request);
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
    // 注意：此用例在**任何分配之前**就返回错误，故它只证明"错误上抛"，
    // 不构成"释放约定无泄漏"的证据——后者由下面的成功路径用例负责。
    if (loadTemplateAddressesInto(&set, &client, "curve")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), set.count());
}

test "template loadTemplateAddresses 成功路径（约束 5：释放约定无泄漏）" {
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
    try client.migrate();

    try client.addTemplateAddress("curve", "0xaa", 100);
    try client.addTemplateAddress("curve", "0xbb", 200);
    try client.addTemplateAddress("curve", "0xcc", 300);
    try client.markTemplateAddressBackfilled("curve", "0xaa");
    try client.markTemplateAddressBackfilled("curve", "0xbb");

    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();
    try loadTemplateAddressesInto(&set, &client, "curve");

    // 2 行已回填 → live；1 行未回填 → pending 重新补扫
    try std.testing.expectEqual(@as(usize, 2), set.all().len);
    try std.testing.expectEqualStrings("0xaa", set.all()[0]);
    try std.testing.expectEqualStrings("0xbb", set.all()[1]);
    try std.testing.expectEqual(@as(usize, 1), set.pending().len);
    try std.testing.expectEqualStrings("0xcc", set.pending()[0].address);
    try std.testing.expectEqual(@as(u64, 300), set.pending()[0].from_block);
    // 释放约定（逐个 free address + free 数组）若写错，testing.allocator 在退出时判失败
}

test "template 地址集合 deinit 释放 pending 与 live（无泄漏）" {
    const alloc = std.testing.allocator;
    var set = TemplateAddressSet.init(alloc);
    try std.testing.expect(set.add("0xaaa", 1));
    set.markBackfilled("0xaaa"); // live 非空
    try std.testing.expect(set.add("0xbbb", 2)); // 故意留一个 pending 到 deinit
    try std.testing.expectEqual(@as(usize, 1), set.pending().len);
    try std.testing.expectEqual(@as(usize, 2), set.count());
    set.deinit(); // 覆盖 live + pending 两个释放分支；漏任一个即 leak 失败
}

test "template dupePending 复制 pending 且调用方可独立释放" {
    const alloc = std.testing.allocator;
    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();
    try std.testing.expect(set.add("0xaaa", 10));
    try std.testing.expect(set.add("0xbbb", 20));

    const snap = try dupePending(&set, alloc);
    defer {
        for (snap) |p| alloc.free(p.address);
        alloc.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("0xaaa", snap[0].address);
    try std.testing.expectEqual(@as(u64, 10), snap[0].from_block);
    try std.testing.expectEqualStrings("0xbbb", snap[1].address);

    // 复制独立：原集合流转不影响快照（若 dupePending 偷懒共享指针，这里会 double-free）
    set.markBackfilled("0xaaa");
    try std.testing.expectEqualStrings("0xaaa", snap[0].address);
}

test "template 重组作废发现块 >= fork 的条目（含连续多项 + 等长不变量）" {
    const alloc = std.testing.allocator;
    var set = TemplateAddressSet.init(alloc);
    defer set.deinit();

    // 保留侧（from_block < fork）
    try std.testing.expect(set.add("0xold", 50));
    set.markBackfilled("0xold"); // live, 50
    try std.testing.expect(set.add("0xkeep", 100));
    set.markBackfilled("0xkeep"); // live, 100
    // 作废侧 live：**连续两项**都命中（101 == fork 含边界、102）
    try std.testing.expect(set.add("0xdrop_a", 101));
    set.markBackfilled("0xdrop_a"); // live, 101
    try std.testing.expect(set.add("0xdrop_b", 102));
    set.markBackfilled("0xdrop_b"); // live, 102
    // 作废侧 pending：**连续两项**都命中（120、130）
    try std.testing.expect(set.add("0xpend_a", 120));
    try std.testing.expect(set.add("0xpend_b", 130));

    // live / live_blocks 等长不变量（任何一处漏维护都会破坏它）
    try std.testing.expectEqual(set.live.items.len, set.live_blocks.items.len);

    set.removeFromBlock(101); // fork = 101

    // 保留 from_block < 101
    try std.testing.expectEqual(@as(usize, 2), set.all().len);
    try std.testing.expectEqualStrings("0xold", set.all()[0]);
    try std.testing.expectEqualStrings("0xkeep", set.all()[1]);
    // pending 连续两项都必须被移除（"移除分支里多 i+=1"会漏掉第二项 → 这里会红）
    try std.testing.expectEqual(@as(usize, 0), set.pending().len);
    try std.testing.expectEqual(@as(usize, 2), set.count());
    // live 连续两项都被移除后仍等长
    try std.testing.expectEqual(set.live.items.len, set.live_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), set.live_blocks.items.len);
}

test "template 模式守卫（未开模板模式 / 运行中切换）" {
    // loadTemplateAddresses 在未开模板模式时必须报错，不能静默返回
    try std.testing.expectError(error.NotTemplateMode, ensureTemplateMode(false));
    try ensureTemplateMode(true);
    // setTemplateMode 运行中必须拒绝
    try ensureNotRunning(.stopped);
    try ensureNotRunning(.error_state);
    try std.testing.expectError(error.AlreadyRunning, ensureNotRunning(.running));
    try std.testing.expectError(error.AlreadyRunning, ensureNotRunning(.replaying));
}

// 用真实 db.Client 构造一个 Indexer，覆盖模板模式整条公有 API 的**函数体**。
// 目的：Zig 惰性分析——没有调用方的函数体不会被语义分析，`setTemplateMode` 曾因此
// 带着 `optional type does not support field access` 的编译错误"全绿"至今，直到 Task 8
// 第一次调用才炸。这里的调用是防止同类回归的接线防线。
fn testIndexerWithDb(alloc: std.mem.Allocator, database: *db.Client, rpc: *eth_rpc.Client, contract: *const config.ContractConfig) Indexer {
    return .{
        .alloc = alloc,
        .rpc = rpc,
        .database = database,
        .contract = contract,
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
        .chain = "bsc",
        .factory_ctx = null,
        .factory_callback = null,
        .template_set = TemplateAddressSet.init(alloc),
    };
}

test "template 模板模式 API 接线（真实调用，杜绝惰性分析漏编译）" {
    const alloc = std.testing.allocator;
    const db_cfg = db.DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var database = try db.Client.init(alloc, &db_cfg);
    defer database.deinit();
    try database.migrate();

    var rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var rpc = eth_rpc.Client.init(alloc, undefined, &rpc_cfg);
    defer rpc.deinit();

    const contract = config.ContractConfig{
        .name = "curve",
        .address = "",
        .abi_path = "",
        .from_block = 0,
        .events = &.{},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = &.{},
    };

    var idx = testIndexerWithDb(alloc, &database, &rpc, &contract);
    defer idx.deinit();

    // 直接调用真实函数体（编译期必须能实例化）
    idx.setTemplateMode(true);
    try std.testing.expectEqualStrings("template:curve", idx.stateKey());
    try std.testing.expectEqual(@as(usize, 0), idx.templateAddressCount());

    // loadTemplateAddresses 走真实读库路径（空表）
    try idx.loadTemplateAddresses();
    try std.testing.expectEqual(@as(usize, 0), idx.templateAddressCount());

    // discoverAddress：入口归一化 + 幂等 + 落库
    idx.discoverAddress("0xAbCdEf0123456789AbCdEf0123456789AbCdEf01", 100);
    idx.discoverAddress("0xabcdef0123456789abcdef0123456789abcdef01", 100); // 归一化后同地址 → 幂等
    try std.testing.expectEqual(@as(usize, 1), idx.templateAddressCount());
    {
        const list = try database.listTemplateAddresses("curve");
        defer {
            for (list) |item| alloc.free(item.address);
            alloc.free(list);
        }
        try std.testing.expectEqual(@as(usize, 1), list.len);
        try std.testing.expectEqualStrings("0xabcdef0123456789abcdef0123456789abcdef01", list[0].address);
    }

    // 断点续传分支：合成 key 下已有记录 → 覆盖游标（含 SyncState 内存释放路径）
    try database.upsertSyncState(.{ .contract_address = "template:curve", .last_synced_block = 123, .status = "running" });
    idx.setTemplateMode(true);
    try std.testing.expectEqual(@as(u64, 123), idx.getCurrentBlock());
    try std.testing.expectEqual(@as(u64, 123), idx.last_tip.load(.monotonic));
}

// 事件回调必须携带"日志来源地址"（Task 10 的第一跳）：真实走 processLog 的解码→落库→回调，
// 断言回调拿到的 contract_address 就是 lg.address（单合约模式下即 contract.address）。
test "事件回调携带日志来源地址（真实 processLog 路径）" {
    const alloc = std.testing.allocator;
    const db_cfg = db.DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var database = try db.Client.init(alloc, &db_cfg);
    defer database.deinit();
    try database.migrate();

    var rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var rpc = eth_rpc.Client.init(alloc, undefined, &rpc_cfg);
    defer rpc.deinit();

    const contract = config.ContractConfig{
        .name = "curve",
        .address = "0xSINGLE",
        .abi_path = "",
        .from_block = 0,
        .events = &.{"CurveCreated"},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = &.{},
    };

    // 构造 ABI 并建表（所有内存交给 Indexer.deinit 释放，与生产所有权一致）
    const inputs = try alloc.alloc(abi.AbiEventInput, 1);
    inputs[0] = .{ .name = try alloc.dupe(u8, "curve"), .type = try alloc.dupe(u8, "uint256"), .indexed = false };
    const events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = .{ .name = try alloc.dupe(u8, "CurveCreated"), .inputs = inputs, .signature = std.mem.zeroes([32]u8) };
    var ac = abi.AbiContract{ .events = events, .functions = try alloc.alloc(abi.AbiFunction, 0) };
    try database.autoMigrateContract("curve", &ac, &.{"CurveCreated"}, "0xSINGLE");

    var idx = testIndexerWithDb(alloc, &database, &rpc, &contract);
    defer idx.deinit();
    idx.abi_contract = ac;

    var seen_addr: ?[]const u8 = null;
    var seen_event: ?[]const u8 = null;
    var cb_count: u32 = 0;
    const Ctx = struct {
        addr: *?[]const u8,
        event: *?[]const u8,
        count: *u32,
        fn cb(ctx: ?*anyopaque, _: []const u8, event_name: []const u8, _: []const db.DecodedField, _: u64, _: u64, contract_address: []const u8, _: []const u8, _: u64) void {
            const self_ptr: *@This() = @ptrCast(@alignCast(ctx.?));
            self_ptr.addr.* = contract_address;
            self_ptr.event.* = event_name;
            self_ptr.count.* += 1;
        }
    };
    var ctx = Ctx{ .addr = &seen_addr, .event = &seen_event, .count = &cb_count };
    idx.setEventCallback(&ctx, Ctx.cb);

    // topic0 = 全零签名（与上面 events[0].signature 匹配）；data 一个 uint256 word
    var topic0_buf: [66]u8 = undefined;
    @memset(&topic0_buf, '0');
    topic0_buf[0] = '0';
    topic0_buf[1] = 'x';
    var data_buf: [66]u8 = undefined;
    @memset(&data_buf, '0');
    data_buf[0] = '0';
    data_buf[1] = 'x';
    data_buf[65] = '7';

    var topics = [_][]const u8{&topic0_buf};
    const lg: eth_rpc.Log = .{
        .address = "0xSINGLE",
        .topics = &topics,
        .data = &data_buf,
        .block_number = 7,
        .transaction_hash = "0xtx",
        .log_index = 0,
    };

    try idx.processLog(lg);

    try std.testing.expectEqualStrings("CurveCreated", seen_event.?);
    try std.testing.expectEqualStrings("0xSINGLE", seen_addr.?);
    try std.testing.expectEqual(@as(u32, 1), cb_count);

    // 集成级去重（分块 getLogs 局部失败后重取整段会复现）：同一条 Log 再处理一次，
    // 必须整体静默 no-op——不重复落库、不再触发回调（否则投影/K 线二次累加），
    // 也不产生任何 raw_logs 死信行。
    try idx.processLog(lg);

    try std.testing.expectEqual(@as(u32, 1), cb_count);
    try std.testing.expectEqualStrings("CurveCreated", seen_event.?);
    try std.testing.expectEqualStrings("0xSINGLE", seen_addr.?);

    const evt_rows = try database.ponderQuery("SELECT COUNT(*) AS n FROM event_curve_CurveCreated;", &.{});
    defer database.freeQueryRows(evt_rows);
    try std.testing.expectEqual(@as(i64, 1), evt_rows[0].values[0].integer);

    const raw_rows = try database.ponderQuery("SELECT COUNT(*) AS n FROM raw_logs;", &.{});
    defer database.freeQueryRows(raw_rows);
    try std.testing.expectEqual(@as(i64, 0), raw_rows[0].values[0].integer);
}

// 同一形态不变量（Task 12）：事件行 / 回调里的来源地址与 discoverAddress 落
// template_addresses 的形态必须一致（都是小写 hex）——`?address=` 与 GraphQL 是精确匹配，
// 大小写不同会让同一 clone 的数据"查得到一行、查不到另一行"（Anvil 全小写所以 e2e 测不出）。
test "processLog 落库地址归一化：与 discoverAddress 同形态（精确匹配查得到）" {
    const alloc = std.testing.allocator;
    const db_cfg = db.DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var database = try db.Client.init(alloc, &db_cfg);
    defer database.deinit();
    try database.migrate();

    var rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var rpc = eth_rpc.Client.init(alloc, undefined, &rpc_cfg);
    defer rpc.deinit();

    const contract = config.ContractConfig{
        .name = "curve",
        .address = "",
        .abi_path = "",
        .from_block = 0,
        .events = &.{"Buy"},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = &.{},
    };

    const inputs = try alloc.alloc(abi.AbiEventInput, 1);
    inputs[0] = .{ .name = try alloc.dupe(u8, "curve"), .type = try alloc.dupe(u8, "uint256"), .indexed = false };
    const events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = .{ .name = try alloc.dupe(u8, "Buy"), .inputs = inputs, .signature = std.mem.zeroes([32]u8) };
    var ac = abi.AbiContract{ .events = events, .functions = try alloc.alloc(abi.AbiFunction, 0) };
    try database.autoMigrateContract("curve", &ac, &.{"Buy"}, "");

    var idx = testIndexerWithDb(alloc, &database, &rpc, &contract);
    defer idx.deinit();
    idx.abi_contract = ac;
    idx.setTemplateMode(true);

    // 节点返回的 raw 形态是 mixed-case（Anvil 全小写，真实链上常见 mixed-case）
    const MIXED = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01";

    var topic0_buf: [66]u8 = undefined;
    @memset(&topic0_buf, '0');
    topic0_buf[0] = '0';
    topic0_buf[1] = 'x';
    var data_buf: [66]u8 = undefined;
    @memset(&data_buf, '0');
    data_buf[0] = '0';
    data_buf[1] = 'x';
    data_buf[65] = '7';
    var topics = [_][]const u8{&topic0_buf};

    // 回调里的地址切片只在本次回调期间有效（消费者要么当场建 JS 字符串、要么 dupe：
    // 见 js_engine.handleEvent / event_bus.Event.clone），故测试当场拷贝出来再断言。
    var seen_buf: [42]u8 = undefined;
    var seen_len: usize = 0;
    const Ctx = struct {
        buf: *[42]u8,
        len: *usize,
        fn cb(ctx: ?*anyopaque, _: []const u8, _: []const u8, _: []const db.DecodedField, _: u64, _: u64, contract_address: []const u8, _: []const u8, _: u64) void {
            const p: *@This() = @ptrCast(@alignCast(ctx.?));
            const n = @min(contract_address.len, p.buf.len);
            @memcpy(p.buf[0..n], contract_address[0..n]);
            p.len.* = n;
        }
    };
    var ctx = Ctx{ .buf = &seen_buf, .len = &seen_len };
    idx.setEventCallback(&ctx, Ctx.cb);

    try idx.processLog(.{
        .address = MIXED,
        .topics = &topics,
        .data = &data_buf,
        .block_number = 7,
        .transaction_hash = "0xtx",
        .log_index = 0,
    });

    // 事件行必须是归一化（小写）形态，而不是 raw 的 mixed-case
    const rows = try database.ponderQuery("SELECT contract_address FROM event_curve_Buy;", &.{});
    defer database.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0xabcdef0123456789abcdef0123456789abcdef01", rows[0].values[0].text);
    // 回调（→ handler / SSE / GraphQL 过滤）与落库共用同一形态
    try std.testing.expectEqualStrings("0xabcdef0123456789abcdef0123456789abcdef01", seen_buf[0..seen_len]);
}

// 模板模式下 `rollbackFromBlock` 是多语句事务，工厂线程的单语句 `addTemplateAddress`
// 若落在同一事务里，回滚（失败时的 ROLLBACK）会把这条**不该删**的地址行一起丢弃：
// 内存里该 clone 仍存活，但重启后库里没有它 → 不再进 live → 主 sweep 不再覆盖它。
// 这里用同一连接上的 BEGIN / INSERT / ROLLBACK 确定性地复现该状态。
test "rollbackTo 把仍存活的 clone 地址幂等补回（被回滚吞掉的插入）" {
    const alloc = std.testing.allocator;
    const db_cfg = db.DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var database = try db.Client.init(alloc, &db_cfg);
    defer database.deinit();
    try database.migrate();

    var rpc_cfg = config.RpcConfig{ .url = "", .retry_count = 0, .retry_delay_ms = 0, .request_timeout_ms = 0, .max_concurrent = 0 };
    var rpc = eth_rpc.Client.init(alloc, undefined, &rpc_cfg);
    defer rpc.deinit();

    const contract = config.ContractConfig{
        .name = "curve",
        .address = "",
        .abi_path = "",
        .from_block = 0,
        .events = &.{},
        .start_block = null,
        .block_batch_size = null,
        .poll_interval_ms = null,
        .max_reorg_depth = null,
        .filters = &.{},
    };
    var idx = testIndexerWithDb(alloc, &database, &rpc, &contract);
    defer idx.deinit();
    idx.setTemplateMode(true);

    const live = "0xabcdef0123456789abcdef0123456789abcdef01";
    const after_fork = "0x1111111111111111111111111111111111111111";

    // 工厂线程发现 clone：插入恰好落在回滚已开启的事务里
    _ = try database.ponderExec("BEGIN;", &.{});
    idx.discoverAddress(live, 100);
    // 回滚 → 同一连接上的插入被一起丢弃（内存集合仍认为该 clone 存活）
    _ = try database.ponderExec("ROLLBACK;", &.{});

    {
        const list = try database.listTemplateAddresses("curve");
        defer {
            for (list) |item| alloc.free(item.address);
            alloc.free(list);
        }
        // 前提：DB 里这一行没了（内存里还在 pending）
        try std.testing.expectEqual(@as(usize, 0), list.len);
    }

    idx.markAddressBackfilled(live); // 补扫完成 → 并入 live（此时 DB 里没有行可标）
    try std.testing.expectEqual(@as(usize, 1), idx.templateAddressCount());

    // fork 之后发现的 clone：回滚应当作废它，且补偿逻辑不得把它复活
    idx.discoverAddress(after_fork, 300);

    idx.rollbackTo(200);

    const list = try database.listTemplateAddresses("curve");
    defer {
        for (list) |item| alloc.free(item.address);
        alloc.free(list);
    }
    // 仍存活的 live 地址被幂等补回，from_block 保持发现块（不覆盖已有进度）
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings(live, list[0].address);
    try std.testing.expectEqual(@as(u64, 100), list[0].from_block);
    // 补回走的是 `addTemplateAddress`（INSERT ... DO NOTHING），新行的 backfilled 是默认 0：
    // 本进程内存里它已是 live，不受影响；重启后它会重新进 pending 补扫一次——与
    // `markAddressBackfilled` 落库失败时的既有降级一致（幂等，重复日志由 insertEventLog
    // 返回 false 静默跳过）。
    try std.testing.expect(!list[0].backfilled);
    // 内存集合与 DB 一致
    try std.testing.expectEqual(@as(usize, 1), idx.templateAddressCount());
    try std.testing.expectEqualStrings(live, idx.template_set.all()[0]);
}
