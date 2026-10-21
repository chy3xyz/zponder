const std = @import("std");
const utils = @import("utils.zig");
const config = @import("config.zig");
const log = @import("log.zig");

/// 以太坊日志条目
pub const Log = struct {
    address: []const u8,
    topics: []const []const u8,
    data: []const u8,
    block_number: u64,
    transaction_hash: []const u8,
    log_index: u64,
    /// eth_subscribe may mark reorged logs as removed
    removed: bool = false,
};

/// 日志过滤条件
pub const LogFilter = struct {
    /// 地址集合（模板模式下一次 eth_getLogs 覆盖多个 clone 地址）。
    /// null 与长度 0 语义相同，都表示"不过滤地址"：序列化时两者都写成 JSON null，
    /// 不写成 `[]`——部分 RPC 对空地址数组的行为不一致。
    addresses: ?[]const []const u8 = null,
    topics: ?[]const []const u8 = null,
    from_block: ?u64 = null,
    to_block: ?u64 = null,
};

/// RPC 配置
pub const RpcConfig = config.RpcConfig;

/// 熔断器状态
const CircuitState = enum(u8) {
    closed,    // 正常
    open,      // 熔断中
    half_open, // 半开测试
};

/// `getBlockNumber` 短缓存寿命。年龄达到该值即过期（`now - at >= ttl` 未命中）。
pub const block_number_cache_ttl_ms: i64 = 250;

/// 最近一次成功的区块号。`valid == false` 表示还没有成功结果。
pub const BlockNumberSnapshot = struct {
    number: u64 = 0,
    at_ms: i64 = 0,
    valid: bool = false,
};

/// 250ms 内复用同一结果。无效、过期，或 `now_ms` 早于缓存时间（回拨）都返回 null。
/// 纯函数：单测传入毫秒时间戳，不睡眠、不打 RPC。
pub fn lookupBlockNumberCache(snapshot: BlockNumberSnapshot, now_ms: i64) ?u64 {
    if (!snapshot.valid) return null;
    // 有符号减法 999-1000 得到 -1，不会溢出，必须先拒绝回拨。
    if (now_ms < snapshot.at_ms) return null;
    const age = std.math.sub(i64, now_ms, snapshot.at_ms) catch return null;
    if (age >= block_number_cache_ttl_ms) return null;
    return snapshot.number;
}

/// 以太坊 RPC 客户端（带熔断器和指数退避）
pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    config: *const RpcConfig,
    http_client: std.http.Client,
    // std.http.Client 非线程安全：多个索引器线程并发 fetch 同一实例会
    // 数据竞争（TlsInitializationFailed / segfault / abort，4 合约 + WSS 复现）。
    // 用互斥锁串行化 RPC 请求（RPC 本身是网络瓶颈，串行对吞吐影响有限）。
    http_mutex: std.Io.Mutex = .init,
    next_id: std.atomic.Value(u64),
    url_index: std.atomic.Value(usize),
    // 指标：请求/错误计数（metrics 端点暴露）
    total_requests: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),
    // 并发限制
    concurrent_requests: std.atomic.Value(u32),
    // 熔断器状态
    circuit_state: std.atomic.Value(CircuitState),
    circuit_failures: std.atomic.Value(u32),
    circuit_last_failure: std.atomic.Value(i64), // 毫秒时间戳
    // getBlockNumber 短缓存。不用 http_mutex：rpcCall 会再锁它，重入会死锁，
    // 也会把缓存检查卷进 HTTP 串行。这把锁只护住 block_number_cache 的读写。
    block_number_mutex: std.atomic.Mutex = .unlocked,
    block_number_cache: BlockNumberSnapshot = .{},
    // 缓存命中次数。命中不走 rpcCall，因此不增加 total_requests / total_errors。
    block_number_cache_hits: std.atomic.Value(u64) = .init(0),
    const CIRCUIT_THRESHOLD = 5;    // 连续失败 5 次后熔断
    const CIRCUIT_TIMEOUT_SEC = 30; // 熔断 30 秒后尝试半开

    pub fn init(alloc: std.mem.Allocator, io: std.Io, rpc_config: *const RpcConfig) Client {
        return .{
            .alloc = alloc,
            .io = io,
            .config = rpc_config,
            .http_client = .{ .allocator = alloc, .io = io },
            .next_id = std.atomic.Value(u64).init(1),
            .url_index = std.atomic.Value(usize).init(0),
            .total_requests = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
            .concurrent_requests = std.atomic.Value(u32).init(0),
            .circuit_state = std.atomic.Value(CircuitState).init(.closed),
            .circuit_failures = std.atomic.Value(u32).init(0),
            .circuit_last_failure = std.atomic.Value(i64).init(0),
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// 获取最新区块号。250ms 内重复调用直接返回缓存，不打 RPC、不计入 total_requests。
    pub fn getBlockNumber(self: *Client) !u64 {
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        return self.getBlockNumberAt(now_ms);
    }

    /// 与 `getBlockNumber` 相同，但时间由调用方传入，单测不必睡眠。
    /// 未命中才走 `rpcCallWithRetry`（故障转移、熔断、重试保持原样）。
    /// 只有解析成功才写入缓存；失败不缓存，也不记一次缓存命中。
    pub fn getBlockNumberAt(self: *Client, now_ms: i64) !u64 {
        if (self.loadCachedBlockNumber(now_ms)) |number| {
            _ = self.block_number_cache_hits.fetchAdd(1, .monotonic);
            return number;
        }

        const raw = try self.rpcCallWithRetry("eth_blockNumber", "[]");
        defer self.alloc.free(raw);
        const number = try extractHexU64Result(self.alloc, raw);
        self.storeCachedBlockNumber(number, now_ms);
        return number;
    }

    fn lockBlockNumberCache(self: *Client) void {
        while (!self.block_number_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn loadCachedBlockNumber(self: *Client, now_ms: i64) ?u64 {
        self.lockBlockNumberCache();
        defer self.block_number_mutex.unlock();
        return lookupBlockNumberCache(self.block_number_cache, now_ms);
    }

    fn storeCachedBlockNumber(self: *Client, number: u64, now_ms: i64) void {
        self.lockBlockNumberCache();
        defer self.block_number_mutex.unlock();
        self.block_number_cache = .{
            .number = number,
            .at_ms = now_ms,
            .valid = true,
        };
    }

    /// 获取区块 hash（返回调用者拥有的字符串，需释放）
    pub fn getBlockHash(self: *Client, block_number: u64) !?[]u8 {
        const params = try std.fmt.allocPrint(self.alloc, "[\"0x{x}\",false]", .{block_number});
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_getBlockByNumber", params);
        defer self.alloc.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return null;
        if (result != .object) return null;
        const hash_val = result.object.get("hash") orelse return null;
        if (hash_val != .string) return null;
        return try self.alloc.dupe(u8, hash_val.string);
    }

    pub const BlockData = struct {
        hash: []const u8,
        number: u64,
        timestamp: u64,
        miner: []const u8,
        gas_used: u64,
        gas_limit: u64,
        base_fee_per_gas: []const u8,
        transaction_count: u64,
    };

    pub fn getBlockData(self: *Client, block_number: u64) !?BlockData {
        const params = try std.fmt.allocPrint(self.alloc, "[\"0x{x}\",false]", .{block_number});
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_getBlockByNumber", params);
        defer self.alloc.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return null;
        if (result != .object) return null;
        const obj = result.object;

        const hash_val = obj.get("hash") orelse return null;
        if (hash_val != .string) return null;

        const number_str = obj.get("number") orelse return null;
        const block_num = if (number_str == .string) utils.parseHexU64(number_str.string) catch return null else return null;

        const timestamp_str = obj.get("timestamp") orelse return null;
        const ts = if (timestamp_str == .string) utils.parseHexU64(timestamp_str.string) catch return null else return null;

        const miner_str = if (obj.get("miner")) |m| blk: {
            if (m == .string) break :blk try self.alloc.dupe(u8, m.string);
            break :blk try self.alloc.dupe(u8, "");
        } else try self.alloc.dupe(u8, "");

        const gas_used_str = obj.get("gasUsed") orelse return null;
        const gu = if (gas_used_str == .string) utils.parseHexU64(gas_used_str.string) catch return null else return null;

        const gas_limit_str = obj.get("gasLimit") orelse return null;
        const gl = if (gas_limit_str == .string) utils.parseHexU64(gas_limit_str.string) catch return null else return null;

        const base_fee = if (obj.get("baseFeePerGas")) |bf| blk: {
            if (bf == .string) break :blk try self.alloc.dupe(u8, bf.string);
            break :blk try self.alloc.dupe(u8, "0x0");
        } else try self.alloc.dupe(u8, "0x0");

        var tx_count: u64 = 0;
        if (obj.get("transactions")) |txs| {
            if (txs == .array) {
                tx_count = txs.array.items.len;
            }
        }

        return BlockData{
            .hash = try self.alloc.dupe(u8, hash_val.string),
            .number = block_num,
            .timestamp = ts,
            .miner = miner_str,
            .gas_used = gu,
            .gas_limit = gl,
            .base_fee_per_gas = base_fee,
            .transaction_count = tx_count,
        };
    }

    pub fn freeBlockData(alloc: std.mem.Allocator, data: BlockData) void {
        alloc.free(data.hash);
        alloc.free(data.miner);
        alloc.free(data.base_fee_per_gas);
    }

    /// 调用合约方法 (eth_call)。返回原始 hex 结果字符串。
    pub fn ethCall(self: *Client, to: []const u8, data: []const u8, block_number: ?u64) ![]u8 {
        const block_tag = if (block_number) |bn|
            try std.fmt.allocPrint(self.alloc, "\"0x{x}\"", .{bn})
        else
            try self.alloc.dupe(u8, "\"latest\"");
        defer self.alloc.free(block_tag);

        const params = try std.fmt.allocPrint(self.alloc,
            \\[{{"to":"{s}","data":"{s}"}},{s}]
        , .{ to, data, block_tag });
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_call", params);
        defer self.alloc.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.NoResult;
        if (result != .string) return error.InvalidResponse;
        return try self.alloc.dupe(u8, result.string);
    }

    /// 获取日志列表
    pub fn getLogs(self: *Client, filter: LogFilter) ![]Log {
        const filter_obj = try self.formatLogFilter(filter);
        defer self.alloc.free(filter_obj);

        const params = try std.fmt.allocPrint(self.alloc, "[{s}]", .{filter_obj});
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_getLogs", params);
        defer self.alloc.free(raw);

        return try parseLogs(self.alloc, raw);
    }

    /// 单块的 `eth_getLogs` 被节点截断时，用收据把这一块的日志拿全，再按地址和 topic0 过滤。
    /// 调用方拥有返回的切片。
    pub fn getBlockReceiptLogs(
        self: *Client,
        block_number: u64,
        addresses: []const []const u8,
        topics: ?[]const []const u8,
    ) ![]Log {
        const params = try std.fmt.allocPrint(self.alloc, "[\"0x{x}\"]", .{block_number});
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_getBlockReceipts", params);
        defer self.alloc.free(raw);

        return try parseBlockReceiptLogs(self.alloc, raw, block_number, addresses, topics);
    }

    /// 带指数退避重试的 RPC 调用
    fn rpcCallWithRetry(self: *Client, method: []const u8, params: []const u8) ![]u8 {
        // 检查熔断器
        const state = self.circuit_state.load(.monotonic);
        if (state == .open) {
            const last = self.circuit_last_failure.load(.monotonic);
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (now - last < CIRCUIT_TIMEOUT_SEC) {
                return error.CircuitOpen;
            }
            // 超时后进入半开状态
            self.circuit_state.store(.half_open, .monotonic);
        }

        var attempt: u32 = 0;
        while (true) {
            const result = self.rpcCall(method, params);
            if (result) |data| {
                // 成功：重置熔断器
                self.circuit_failures.store(0, .monotonic);
                self.circuit_state.store(.closed, .monotonic);
                return data;
            } else |e| {
                // RPC limit exceeded 不需要重试（批次问题，重试无意义）
                if (e == error.RpcLimitExceeded) return e;

                attempt += 1;
                _ = self.url_index.fetchAdd(1, .monotonic);
                const failures = self.circuit_failures.fetchAdd(1, .monotonic) + 1;

                if (failures >= CIRCUIT_THRESHOLD) {
                    self.circuit_state.store(.open, .monotonic);
                    self.circuit_last_failure.store(std.Io.Timestamp.now(self.io, .real).toSeconds(), .monotonic);
                    log.err("RPC 熔断器触发：连续失败 {d} 次", .{failures});
                }

                if (attempt > self.config.retry_count) return e;

                // 指数退避：500ms * 2^attempt，上限 16s
                const backoff_ms = 500 * std.math.pow(u32, 2, @min(attempt, 5));
                log.warn("RPC 调用失败（{d}/{d}），{d}ms 后退避重试: {any}", .{ attempt, self.config.retry_count, backoff_ms, e });
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(backoff_ms), .real) catch {};
                // 半开状态下一次成功就关闭，再次失败则重新熔断
                if (state == .half_open) {
                    self.circuit_state.store(.open, .monotonic);
                    self.circuit_last_failure.store(std.Io.Timestamp.now(self.io, .real).toSeconds(), .monotonic);
                    return e;
                }
            }
        }
    }

    /// 获取并发槽位（spin-wait，直到有可用槽位）
    fn acquireSlot(self: *Client) void {
        const max = self.config.max_concurrent;
        if (max == 0) return; // 0 表示无限制
        while (true) {
            const current = self.concurrent_requests.load(.monotonic);
            if (current < max) {
                if (self.concurrent_requests.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |_| {
                    continue;
                } else {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    fn releaseSlot(self: *Client) void {
        _ = self.concurrent_requests.fetchSub(1, .monotonic);
    }

    /// 执行一次 RPC 调用
    fn rpcCall(self: *Client, method: []const u8, params: []const u8) ![]u8 {
        self.acquireSlot();
        defer self.releaseSlot();

        // 串行化 http_client 访问（非线程安全，见 http_mutex 注释）。
        // 用有界等待：std.Io.Mutex.lockUncancelable 在高争用下 futex 唤醒可能
        // 丢失导致线程永久卡住（4 合约并发复现）；tryLock + 让出 + 超时返回
        // RpcBusy，由上层 rpcCallWithRetry 重试，避免索引器静默卡死。
        var acquired = false;
        var attempts: u32 = 0;
        while (attempts < 1000) : (attempts += 1) {
            if (self.http_mutex.tryLock()) {
                acquired = true;
                break;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
        }
        if (!acquired) return error.RpcBusy;
        defer self.http_mutex.unlock(self.io);

        const id = self.next_id.fetchAdd(1, .monotonic);

        var req_buf: std.ArrayList(u8) = .empty;
        defer req_buf.deinit(self.alloc);

        try req_buf.print(self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s},\"id\":{d}}}",
            .{ method, params, id },
        );

        var response_writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer response_writer.deinit();

        const target_url = if (self.config.urls.len > 0)
            self.config.urls[self.url_index.load(.monotonic) % self.config.urls.len]
        else
            self.config.url;

        _ = self.total_requests.fetchAdd(1, .monotonic);
        // std.http.Client.fetch 没有超时参数。request_timeout_ms 为 0 时保持
        // 原来的 fetch（单测传入 undefined io，不能碰时钟）。非 0 时只替换
        // 这一次请求的 Io.operate：net_read / net_write 走 operateTimeout。
        // 连接仍走系统 connect；对端收下 TCP 但不发字节时，读会在超时后返回。
        const timeout = rpcIoTimeout(self.config.request_timeout_ms);
        var timed_vtable: std.Io.VTable = undefined;
        if (timeout != .none) {
            timed_vtable = self.io.vtable.*;
            timed_vtable.operate = timedNetOperate;
            rpc_io_inner = self.io;
            rpc_io_timeout = timeout;
            self.http_client.io = .{
                .userdata = self.io.userdata,
                .vtable = &timed_vtable,
            };
        }
        defer if (timeout != .none) {
            self.http_client.io = self.io;
            rpc_io_timeout = .none;
        };
        const result = self.http_client.fetch(.{
            .location = .{ .url = target_url },
            .method = .POST,
            .payload = req_buf.items,
            // 复用池内陈旧连接会导致读永久挂起。禁用 keep_alive，每次新建连接。
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
        }) catch |err| {
            _ = self.total_errors.fetchAdd(1, .monotonic);
            return err;
        };

        const status_int = @intFromEnum(result.status);
        // 客户端错误：不可重试
        if (status_int == 413) return error.RpcLimitExceeded;
        if (status_int >= 400 and status_int < 500 and status_int != 429) {
            return error.HttpClientError;
        }
        if (status_int < 200 or status_int >= 300) {
            return error.HttpError;
        }

        var body = response_writer.toArrayList();
        defer body.deinit(self.alloc);

        // 检查 JSON-RPC 错误码（HTTP 200 也可能包含错误）
        if (std.json.parseFromSlice(std.json.Value, self.alloc, body.items, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value != .object) {
                // 非标准 JSON-RPC 响应，返回原始 body
                return try self.alloc.dupe(u8, body.items);
            }
            if (parsed.value.object.get("error")) |err| {
                if (err != .object) return error.RpcError;
                const code = if (err.object.get("code")) |c| switch (c) { .integer => |v| v, else => -1 } else -1;
                const msg = if (err.object.get("message")) |m| switch (m) { .string => |v| v, else => "unknown" } else "unknown";
                log.warn("RPC error: code={d}, msg={s}", .{ code, msg });
                if (rpcRangeTooWide(code, msg)) return error.RpcLimitExceeded;
                return error.RpcError;
            }
        } else |_| {}

        return try self.alloc.dupe(u8, body.items);
    }

    /// 格式化 eth_getLogs 过滤条件为 JSON 参数
    pub fn formatLogFilter(self: *Client, filter: LogFilter) ![]u8 {
        return formatLogFilterObject(self.alloc, filter, true);
    }

    /// 格式化 eth_subscribe("logs") 过滤对象（不含区块范围，外层由调用方包 params）
    pub fn formatSubscribeLogsFilter(self: *Client, filter: LogFilter) ![]u8 {
        return formatLogFilterObject(self.alloc, filter, false);
    }
};

/// 将 LogFilter 格式化为 JSON 对象字符串（非数组包裹）。
/// `include_block_range` 为 true 时写入 fromBlock/toBlock（eth_getLogs）；
/// addresses 写成 `"address":["0xA","0xB"]`（单元素也是数组；null/空数组都写 `null`）；
/// topics 按 topic0 OR 语义写成 `[["sig1","sig2",...]]`。
pub fn formatLogFilterObject(alloc: std.mem.Allocator, filter: LogFilter, include_block_range: bool) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    try buf.writer.writeAll("{\"address\":");
    if (filter.addresses) |addrs| {
        // 空数组与 null 等价：都输出 null（见 LogFilter.addresses 注释）。
        if (addrs.len == 0) {
            try buf.writer.writeAll("null");
        } else {
            try buf.writer.writeByte('[');
            for (addrs, 0..) |a, i| {
                if (i > 0) try buf.writer.writeByte(',');
                try buf.writer.print("\"{s}\"", .{a});
            }
            try buf.writer.writeByte(']');
        }
    } else {
        try buf.writer.writeAll("null");
    }

    if (include_block_range) {
        if (filter.from_block) |fb| {
            try buf.writer.print(",\"fromBlock\":\"0x{x}\"", .{fb});
        }
        if (filter.to_block) |tb| {
            try buf.writer.print(",\"toBlock\":\"0x{x}\"", .{tb});
        }
    }

    if (filter.topics) |topics| {
        // topic0 OR: [["0xaaa","0xbbb"]]
        try buf.writer.writeAll(",\"topics\":[[");
        for (topics, 0..) |t, i| {
            if (i > 0) try buf.writer.writeByte(',');
            try buf.writer.print("\"{s}\"", .{t});
        }
        try buf.writer.writeAll("]]");
    }

    try buf.writer.writeByte('}');
    var list = buf.toArrayList();
    defer list.deinit(alloc);
    return try alloc.dupe(u8, list.items);
}

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// 区间太大，缩小批次再要。限流不算：原样重试即可，不该把批次砍掉。
fn rpcRangeTooWide(code: i64, msg: []const u8) bool {
    if (containsFold(msg, "rate limit") or containsFold(msg, "too many requests")) return false;
    if (code == -32005) return true;
    const needles = [_][]const u8{
        "returned more than",
        "response size",
        "too many logs",
        "too many results",
        "too many blocks",
        "log limit",
        "block range",
        "exceed max",
        "exceeds max",
        "maximum block",
        "query exceeds",
        "result limit",
        "size exceeded",
    };
    for (needles) |needle| {
        if (containsFold(msg, needle)) return true;
    }
    return false;
}

/// 从 JSON-RPC 响应中提取十六进制 u64 结果
fn extractHexU64Result(alloc: std.mem.Allocator, raw: []const u8) !u64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    // 检查 JSON-RPC 错误
    if (parsed.value.object.get("error")) |err| {
        const code = if (err.object.get("code")) |c| c.integer else -1;
        const msg = if (err.object.get("message")) |m| m.string else "unknown";
        log.err("RPC error: code={d}, msg={s}", .{ code, msg });
        return error.RpcError;
    }

    const result = parsed.value.object.get("result") orelse return error.NoResult;
    const hex_str = result.string;
    return utils.parseHexU64(hex_str);
}

/// 解析单条日志 JSON 对象（eth_getLogs 元素或 eth_subscription result）
pub fn parseLogObject(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Log {
    var topics: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (topics.items) |t| alloc.free(t);
        topics.deinit(alloc);
    }

    if (obj.get("topics")) |t| {
        if (t == .array) {
            for (t.array.items) |topic| {
                if (topic != .string) continue;
                try topics.append(alloc, try alloc.dupe(u8, topic.string));
            }
        }
    }

    const block_number = blk: {
        if (obj.get("blockNumber")) |bn| {
            if (bn == .string) break :blk utils.parseHexU64(bn.string) catch 0;
        }
        break :blk 0;
    };

    const log_index = blk: {
        if (obj.get("logIndex")) |li| {
            if (li == .string) break :blk utils.parseHexU64(li.string) catch 0;
        }
        break :blk 0;
    };

    const address_str = if (obj.get("address")) |a| switch (a) {
        .string => |v| v,
        else => "",
    } else "";
    const data_str = if (obj.get("data")) |d| switch (d) {
        .string => |v| v,
        else => "",
    } else "";
    const tx_str = if (obj.get("transactionHash")) |th| switch (th) {
        .string => |v| v,
        else => "",
    } else "";
    const removed = if (obj.get("removed")) |r| switch (r) {
        .bool => |v| v,
        else => false,
    } else false;

    return .{
        .address = try alloc.dupe(u8, address_str),
        .topics = try topics.toOwnedSlice(alloc),
        .data = try alloc.dupe(u8, data_str),
        .block_number = block_number,
        .transaction_hash = try alloc.dupe(u8, tx_str),
        .log_index = log_index,
        .removed = removed,
    };
}

/// 解析日志列表 JSON（eth_getLogs 完整响应）
fn parseLogs(alloc: std.mem.Allocator, raw: []const u8) ![]Log {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        log.err("RPC 返回非对象 JSON", .{});
        return error.InvalidResponse;
    }

    if (parsed.value.object.get("error")) |err| {
        if (err != .object) return error.InvalidResponse;
        const code = if (err.object.get("code")) |c| switch (c) {
            .integer => |v| v,
            else => -1,
        } else -1;
        const msg = if (err.object.get("message")) |m| switch (m) {
            .string => |v| v,
            else => "unknown",
        } else "unknown";
        log.err("RPC error: code={d}, msg={s}", .{ code, msg });
        if (rpcRangeTooWide(code, msg)) return error.RpcLimitExceeded;
        return error.RpcError;
    }

    const result = parsed.value.object.get("result") orelse return try alloc.alloc(Log, 0);
    if (result != .array) return try alloc.alloc(Log, 0);

    var logs: std.ArrayList(Log) = .empty;
    errdefer {
        for (logs.items) |l| freeLog(alloc, l);
        logs.deinit(alloc);
    }

    for (result.array.items) |item| {
        if (item != .object) continue;
        try logs.append(alloc, try parseLogObject(alloc, item.object));
    }

    return try logs.toOwnedSlice(alloc);
}

fn receiptLogWanted(addresses: []const []const u8, topics: ?[]const []const u8, lg: Log) bool {
    var address_ok = false;
    for (addresses) |want| {
        if (std.ascii.eqlIgnoreCase(want, lg.address)) {
            address_ok = true;
            break;
        }
    }
    if (!address_ok) return false;
    const want_topics = topics orelse return true;
    if (want_topics.len == 0) return true;
    if (lg.topics.len == 0) return false;
    for (want_topics) |topic| {
        if (std.ascii.eqlIgnoreCase(topic, lg.topics[0])) return true;
    }
    return false;
}

/// 解析 `eth_getBlockReceipts` 响应，只留下这一块里地址和 topic0 都命中的日志。
pub fn parseBlockReceiptLogs(
    alloc: std.mem.Allocator,
    raw: []const u8,
    block_number: u64,
    addresses: []const []const u8,
    topics: ?[]const []const u8,
) ![]Log {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("error")) |err| {
        if (err != .object) return error.InvalidResponse;
        const code = if (err.object.get("code")) |c| switch (c) {
            .integer => |v| v,
            else => -1,
        } else -1;
        const msg = if (err.object.get("message")) |m| switch (m) {
            .string => |v| v,
            else => "unknown",
        } else "unknown";
        log.err("RPC error: code={d}, msg={s}", .{ code, msg });
        if (rpcRangeTooWide(code, msg)) return error.RpcLimitExceeded;
        return error.RpcError;
    }

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result == .null) return error.BlockNotFound;
    if (result != .array) return error.InvalidResponse;

    var logs: std.ArrayList(Log) = .empty;
    errdefer {
        for (logs.items) |l| freeLog(alloc, l);
        logs.deinit(alloc);
    }

    for (result.array.items) |receipt| {
        if (receipt != .object) continue;
        const receipt_logs = receipt.object.get("logs") orelse continue;
        if (receipt_logs != .array) continue;
        for (receipt_logs.array.items) |item| {
            if (item != .object) continue;
            const lg = try parseLogObject(alloc, item.object);
            if (lg.block_number != block_number or !receiptLogWanted(addresses, topics, lg)) {
                freeLog(alloc, lg);
                continue;
            }
            try logs.append(alloc, lg);
        }
    }

    return try logs.toOwnedSlice(alloc);
}

/// 解析 eth_subscription 通知；若不是订阅推送则返回 null。
/// 调用方拥有返回的 Log，需 freeLog。
pub fn parseSubscriptionNotification(alloc: std.mem.Allocator, raw: []const u8) !?Log {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const method = parsed.value.object.get("method") orelse return null;
    if (method != .string or !std.mem.eql(u8, method.string, "eth_subscription")) return null;

    const params = parsed.value.object.get("params") orelse return null;
    if (params != .object) return null;
    const result = params.object.get("result") orelse return null;
    if (result != .object) return null;

    return try parseLogObject(alloc, result.object);
}

/// 释放单条日志内存
pub fn freeLog(alloc: std.mem.Allocator, l: Log) void {
    alloc.free(l.address);
    for (l.topics) |t| alloc.free(t);
    alloc.free(l.topics);
    alloc.free(l.data);
    alloc.free(l.transaction_hash);
}

/// 释放日志列表内存
pub fn freeLogs(alloc: std.mem.Allocator, logs: []Log) void {
    for (logs) |l| freeLog(alloc, l);
    alloc.free(logs);
}

/// `0` 表示不安装读超时，调用方继续走原来的 `fetch`。
fn rpcIoTimeout(ms: u32) std.Io.Timeout {
    if (ms == 0) return .none;
    return .{
        .duration = .{
            .raw = .fromMilliseconds(@as(i64, ms)),
            .clock = .awake,
        },
    };
}

/// 当前线程正在进行的那一次 RPC。`http_client.io` 的 userdata 仍是原来的
/// Threaded，超时值放在这里，避免包一层完整 Io vtable。
threadlocal var rpc_io_inner: std.Io = undefined;
threadlocal var rpc_io_timeout: std.Io.Timeout = .none;

fn timedNetOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    const inner = std.Io{ .userdata = userdata, .vtable = rpc_io_inner.vtable };
    switch (operation) {
        .net_read, .net_write, .net_receive, .net_send => {},
        else => return inner.operate(operation),
    }
    if (rpc_io_timeout == .none) return inner.operate(operation);
    return inner.operateTimeout(operation, rpc_io_timeout) catch |err| switch (err) {
        error.Timeout => return netTimeoutResult(operation),
        error.ConcurrencyUnavailable => return inner.operate(operation),
        else => |e| return e,
    };
}

fn netTimeoutResult(operation: std.Io.Operation) std.Io.Operation.Result {
    return switch (operation) {
        .net_read => .{ .net_read = error.ConnectionTimedOut },
        .net_write => .{ .net_write = error.ConnectionTimedOut },
        .net_receive => .{ .net_receive = .{ error.ConnectionTimedOut, 0 } },
        .net_send => .{ .net_send = .{ error.ConnectionTimedOut, 0 } },
        else => unreachable,
    };
}

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

// ============================================================================
// 单元测试
// ============================================================================

// chain_pipeline 尚未接入索引循环，root.zig 也不在本次改动范围。
// 从这里引用，`zig build test` 才会编译并运行它的测试。
test {
    _ = @import("chain_pipeline.zig");
}

test "lookupBlockNumberCache 250ms 窗口" {
    const fresh = BlockNumberSnapshot{ .number = 42, .at_ms = 1_000, .valid = true };
    try std.testing.expectEqual(@as(?u64, 42), lookupBlockNumberCache(fresh, 1_000));
    try std.testing.expectEqual(@as(?u64, 42), lookupBlockNumberCache(fresh, 1_249));
    try std.testing.expectEqual(@as(?u64, null), lookupBlockNumberCache(fresh, 1_250));
    try std.testing.expectEqual(@as(?u64, null), lookupBlockNumberCache(fresh, 1_500));
    try std.testing.expectEqual(@as(?u64, null), lookupBlockNumberCache(fresh, 999));
    try std.testing.expectEqual(@as(?u64, null), lookupBlockNumberCache(.{ .number = 42, .at_ms = 1_000 }, 1_000));
}

test "getBlockNumberAt 缓存命中不计入请求与失败" {
    const alloc = std.testing.allocator;
    var rpc_cfg = RpcConfig{
        .url = "",
        .retry_count = 0,
        .retry_delay_ms = 0,
        .request_timeout_ms = 0,
        .max_concurrent = 1,
    };
    var client = Client.init(alloc, undefined, &rpc_cfg);
    defer client.deinit();

    client.block_number_cache = .{ .number = 99, .at_ms = 1_000, .valid = true };

    try std.testing.expectEqual(@as(?u64, null), client.loadCachedBlockNumber(1_250));
    try std.testing.expectEqual(@as(u64, 0), client.block_number_cache_hits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), client.total_requests.load(.monotonic));

    const n = try client.getBlockNumberAt(1_249);
    try std.testing.expectEqual(@as(u64, 99), n);
    const n2 = try client.getBlockNumberAt(1_000);
    try std.testing.expectEqual(@as(u64, 99), n2);
    try std.testing.expectEqual(@as(u64, 2), client.block_number_cache_hits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), client.total_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), client.total_errors.load(.monotonic));
}

test "extractHexU64Result" {
    const alloc = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x10\"}";
    const val = try extractHexU64Result(alloc, raw);
    try std.testing.expectEqual(@as(u64, 16), val);
}

test "extractHexU64Result error" {
    const alloc = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}";
    try std.testing.expectError(error.RpcError, extractHexU64Result(alloc, raw));
}

test "parseLogs basic" {
    const alloc = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"address\":\"0x6b175474e89094c44da98b954eedeac495271d0f\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x000...\"],\"data\":\"0x0000000000000000000000000000000000000000000000000000000000000001\",\"blockNumber\":\"0x100\",\"transactionHash\":\"0xabc\",\"logIndex\":\"0x0\"}]}";
    const logs = try parseLogs(alloc, raw);
    defer freeLogs(alloc, logs);

    try std.testing.expectEqual(@as(usize, 1), logs.len);
    try std.testing.expectEqualStrings("0x6b175474e89094c44da98b954eedeac495271d0f", logs[0].address);
    try std.testing.expectEqual(@as(u64, 256), logs[0].block_number);
    try std.testing.expectEqual(@as(usize, 2), logs[0].topics.len);
    try std.testing.expect(!logs[0].removed);
}

test "parseSubscriptionNotification removed" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x1","result":{"address":"0xabc","topics":["0xt0"],"data":"0x","blockNumber":"0x10","transactionHash":"0xtx","logIndex":"0x0","removed":true}}}
    ;
    const maybe = try parseSubscriptionNotification(alloc, raw);
    try std.testing.expect(maybe != null);
    defer freeLog(alloc, maybe.?);
    try std.testing.expect(maybe.?.removed);
    try std.testing.expectEqual(@as(u64, 16), maybe.?.block_number);
}

test "区间超限与限流分开" {
    try std.testing.expect(rpcRangeTooWide(-32005, "limit exceeded"));
    try std.testing.expect(rpcRangeTooWide(-32602, "Log response size exceeded. up to a 2,000 block range"));
    try std.testing.expect(rpcRangeTooWide(-32000, "query returned more than 10000 results"));
    try std.testing.expect(!rpcRangeTooWide(-32602, "invalid argument"));
    try std.testing.expect(!rpcRangeTooWide(429, "Too Many Requests"));
    try std.testing.expect(!rpcRangeTooWide(-32005, "rate limit exceeded"));
}

test "parseLogs 把区间超限从普通 RPC 错误里分出来" {
    const alloc = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Log response size exceeded\"}}";
    try std.testing.expectError(error.RpcLimitExceeded, parseLogs(alloc, raw));
}

test "eth_getBlockReceipts 只留下地址和 topic0 都命中的日志" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":[{"logs":[{"address":"0xAbC","topics":["0xT1"],"data":"0x01","blockNumber":"0x10","transactionHash":"0xtx1","logIndex":"0x0"},{"address":"0xdef","topics":["0xT1"],"data":"0x02","blockNumber":"0x10","transactionHash":"0xtx2","logIndex":"0x1"},{"address":"0xabc","topics":["0xT2"],"data":"0x03","blockNumber":"0x10","transactionHash":"0xtx3","logIndex":"0x2"}]},{"logs":[{"address":"0xabc","topics":["0xt1","0xpad"],"data":"0x04","blockNumber":"0x10","transactionHash":"0xtx4","logIndex":"0x3"},{"address":"0xabc","topics":["0xT1"],"data":"0x05","blockNumber":"0x11","transactionHash":"0xtx5","logIndex":"0x0"}]}]}
    ;
    const addrs = [_][]const u8{"0xabc"};
    const topics = [_][]const u8{"0xT1"};
    const logs = try parseBlockReceiptLogs(alloc, raw, 0x10, &addrs, &topics);
    defer freeLogs(alloc, logs);
    try std.testing.expectEqual(@as(usize, 2), logs.len);
    try std.testing.expectEqual(@as(u64, 0), logs[0].log_index);
    try std.testing.expectEqual(@as(u64, 3), logs[1].log_index);
    try std.testing.expectEqualStrings("0xtx4", logs[1].transaction_hash);

    const missing = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    try std.testing.expectError(error.BlockNotFound, parseBlockReceiptLogs(alloc, missing, 1, &addrs, null));
    const rpc_err = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}";
    try std.testing.expectError(error.RpcError, parseBlockReceiptLogs(alloc, rpc_err, 1, &addrs, null));
}

test "parseLogs empty result" {
    const alloc = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}";
    const logs = try parseLogs(alloc, raw);
    defer freeLogs(alloc, logs);
    try std.testing.expectEqual(@as(usize, 0), logs.len);
}

test "formatLogFilter" {
    const alloc = std.testing.allocator;
    var rpc_cfg = config.RpcConfig{
        .url = "",
        .retry_count = 3,
        .retry_delay_ms = 1000,
        .request_timeout_ms = 10000,
        .max_concurrent = 10,
    };
    var client = Client.init(alloc, undefined, &rpc_cfg);
    const filter = LogFilter{
        .addresses = &[_][]const u8{"0xabc"},
        .from_block = 100,
        .to_block = 200,
        .topics = &[_][]const u8{"0x123", "0x456"},
    };
    const params = try client.formatLogFilter(filter);
    defer alloc.free(params);
    try std.testing.expect(std.mem.indexOf(u8, params, "0xabc") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "0x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "0xc8") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "0x123") != null);
    // topic0 OR 语义
    try std.testing.expect(std.mem.indexOf(u8, params, "[[\"0x123\",\"0x456\"]]") != null);
}

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

    // 单元素也输出数组（不做回退成字符串）
    const one = [_][]const u8{"0xA"};
    const f3 = LogFilter{ .addresses = &one };
    const s3 = try formatLogFilterObject(alloc, f3, false);
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("{\"address\":[\"0xA\"]}", s3);

    // 空数组与 null 等价：都输出 null（部分 RPC 对空地址数组行为不一致）
    const empty = [_][]const u8{};
    const f4 = LogFilter{ .addresses = &empty };
    const s4 = try formatLogFilterObject(alloc, f4, false);
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("{\"address\":null}", s4);
}

test "freeLogs" {
    const alloc = std.testing.allocator;
    const topics = try alloc.alloc([]const u8, 2);
    topics[0] = try alloc.dupe(u8, "0xt1");
    topics[1] = try alloc.dupe(u8, "0xt2");

    const log1 = Log{
        .address = try alloc.dupe(u8, "0xabc"),
        .topics = topics,
        .data = try alloc.dupe(u8, "0x1234"),
        .block_number = 100,
        .transaction_hash = try alloc.dupe(u8, "0xtx"),
        .log_index = 0,
    };

    const logs = try alloc.alloc(Log, 1);
    logs[0] = log1;

    freeLogs(alloc, logs);
    // 只要不崩溃/泄漏即通过（Zig 测试运行器会检测内存泄漏）
}

test "acquireSlot and releaseSlot" {
    const alloc = std.testing.allocator;
    var rpc_cfg = RpcConfig{
        .url = "",
        .retry_count = 0,
        .retry_delay_ms = 0,
        .request_timeout_ms = 0,
        .max_concurrent = 2,
    };
    var client = Client.init(alloc, undefined, &rpc_cfg);
    defer client.deinit();

    try std.testing.expectEqual(@as(u32, 0), client.concurrent_requests.load(.monotonic));

    client.acquireSlot();
    try std.testing.expectEqual(@as(u32, 1), client.concurrent_requests.load(.monotonic));

    client.acquireSlot();
    try std.testing.expectEqual(@as(u32, 2), client.concurrent_requests.load(.monotonic));

    client.releaseSlot();
    try std.testing.expectEqual(@as(u32, 1), client.concurrent_requests.load(.monotonic));

    client.releaseSlot();
    try std.testing.expectEqual(@as(u32, 0), client.concurrent_requests.load(.monotonic));
}

test "request_timeout_ms 为 0 时不安装读超时" {
    try std.testing.expect(rpcIoTimeout(0) == .none);
    switch (rpcIoTimeout(200)) {
        .duration => |d| try std.testing.expectEqual(@as(i64, 200), d.raw.toMilliseconds()),
        else => return error.TestUnexpectedResult,
    }
}

test "request_timeout_ms 切断只接受不回应的 RPC" {
    const alloc = std.testing.allocator;
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{});
    var release = std.atomic.Value(bool).init(false);
    const holder = try std.Thread.spawn(.{}, struct {
        fn run(listen: *std.Io.net.Server, io_: std.Io, release_: *std.atomic.Value(bool)) void {
            const stream = listen.accept(io_) catch return;
            defer stream.close(io_);
            var waited_ms: u32 = 0;
            while (!release_.load(.acquire) and waited_ms < 3000) : (waited_ms += 20) {
                std.Io.sleep(io_, .fromMilliseconds(20), .awake) catch return;
            }
        }
    }.run, .{ &server, io, &release });
    defer {
        release.store(true, .release);
        server.deinit(io);
        holder.join();
    }

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()}) catch unreachable;
    var rpc_cfg = RpcConfig{
        .url = url,
        .retry_count = 0,
        .retry_delay_ms = 0,
        .request_timeout_ms = 200,
        .max_concurrent = 1,
    };
    var client = Client.init(alloc, io, &rpc_cfg);
    defer client.deinit();

    const started = monoMs();
    const result = client.rpcCall("eth_blockNumber", "[]");
    const elapsed = monoMs() - started;
    try std.testing.expect(elapsed < 2000);
    if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.ReadFailed, error.WriteFailed => {},
        else => return err,
    }
}
