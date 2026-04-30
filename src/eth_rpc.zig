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
};

/// 日志过滤条件
pub const LogFilter = struct {
    address: ?[]const u8 = null,
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

/// 以太坊 RPC 客户端（带熔断器和指数退避）
pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    config: *const RpcConfig,
    http_client: std.http.Client,
    next_id: std.atomic.Value(u64),
    // 并发限制
    concurrent_requests: std.atomic.Value(u32),
    // 熔断器状态
    circuit_state: std.atomic.Value(CircuitState),
    circuit_failures: std.atomic.Value(u32),
    circuit_last_failure: std.atomic.Value(i64), // 毫秒时间戳
    const CIRCUIT_THRESHOLD = 5;    // 连续失败 5 次后熔断
    const CIRCUIT_TIMEOUT_SEC = 30; // 熔断 30 秒后尝试半开

    pub fn init(alloc: std.mem.Allocator, io: std.Io, rpc_config: *const RpcConfig) Client {
        return .{
            .alloc = alloc,
            .io = io,
            .config = rpc_config,
            .http_client = .{ .allocator = alloc, .io = io },
            .next_id = std.atomic.Value(u64).init(1),
            .concurrent_requests = std.atomic.Value(u32).init(0),
            .circuit_state = std.atomic.Value(CircuitState).init(.closed),
            .circuit_failures = std.atomic.Value(u32).init(0),
            .circuit_last_failure = std.atomic.Value(i64).init(0),
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// 获取最新区块号
    pub fn getBlockNumber(self: *Client) !u64 {
        const raw = try self.rpcCallWithRetry("eth_blockNumber", "[]");
        defer self.alloc.free(raw);
        return try extractHexU64Result(self.alloc, raw);
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

    /// 获取日志列表
    pub fn getLogs(self: *Client, filter: LogFilter) ![]Log {
        const params = try self.formatLogFilter(filter);
        defer self.alloc.free(params);

        const raw = try self.rpcCallWithRetry("eth_getLogs", params);
        defer self.alloc.free(raw);

        return try parseLogs(self.alloc, raw);
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
                attempt += 1;
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
    ///
    /// 注意：Zig 0.16 的 `std.http.Client.fetch` 尚未暴露 `timeout` 参数
    /// （`Request.timeout` 字段在标准库中已声明但未实际使用）。
    /// 超时控制需等待标准库后续版本支持，当前依赖熔断器和指数退避
    /// 来缓解长时间挂起的问题。
    fn rpcCall(self: *Client, method: []const u8, params: []const u8) ![]u8 {
        self.acquireSlot();
        defer self.releaseSlot();

        const id = self.next_id.fetchAdd(1, .monotonic);

        var req_buf: std.ArrayList(u8) = .empty;
        defer req_buf.deinit(self.alloc);

        try req_buf.print(self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s},\"id\":{d}}}",
            .{ method, params, id },
        );

        var response_writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer response_writer.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = self.config.url },
            .method = .POST,
            .payload = req_buf.items,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
        });

        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
            return error.HttpError;
        }

        var body = response_writer.toArrayList();
        defer body.deinit(self.alloc);

        return try self.alloc.dupe(u8, body.items);
    }

    /// 格式化日志过滤条件为 JSON 参数
    fn formatLogFilter(self: *Client, filter: LogFilter) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        try buf.writer.writeAll("[{\"address\":");
        if (filter.address) |addr| {
            try buf.writer.print("\"{s}\"", .{addr});
        } else {
            try buf.writer.writeAll("null");
        }

        if (filter.from_block) |fb| {
            try buf.writer.print(",\"fromBlock\":\"0x{x}\"", .{fb});
        }
        if (filter.to_block) |tb| {
            try buf.writer.print(",\"toBlock\":\"0x{x}\"", .{tb});
        }

        if (filter.topics) |topics| {
            try buf.writer.writeAll(",\"topics\":[");
            for (topics, 0..) |t, i| {
                if (i > 0) try buf.writer.writeByte(',');
                try buf.writer.print("\"{s}\"", .{t});
            }
            try buf.writer.writeAll("]");
        }

        try buf.writer.writeAll("}]");
        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }
};

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

/// 解析日志列表 JSON
fn parseLogs(alloc: std.mem.Allocator, raw: []const u8) ![]Log {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    // 检查 JSON-RPC 错误
    if (parsed.value.object.get("error")) |err| {
        const code = if (err.object.get("code")) |c| c.integer else -1;
        const msg = if (err.object.get("message")) |m| m.string else "unknown";
        log.err("RPC error: code={d}, msg={s}", .{ code, msg });
        return error.RpcError;
    }

    const result = parsed.value.object.get("result") orelse return try alloc.alloc(Log, 0);
    if (result != .array) return try alloc.alloc(Log, 0);

    var logs: std.ArrayList(Log) = .empty;
    errdefer {
        for (logs.items) |l| {
            alloc.free(l.topics);
        }
        logs.deinit(alloc);
    }

    for (result.array.items) |item| {
        const obj = item.object;

        var topics: std.ArrayList([]const u8) = .empty;
        errdefer topics.deinit(alloc);

        if (obj.get("topics")) |t| {
            if (t == .array) {
                for (t.array.items) |topic| {
                    try topics.append(alloc, try alloc.dupe(u8, topic.string));
                }
            }
        }

        const block_number = blk: {
            if (obj.get("blockNumber")) |bn| {
                break :blk utils.parseHexU64(bn.string) catch 0;
            }
            break :blk 0;
        };

        const log_index = blk: {
            if (obj.get("logIndex")) |li| {
                break :blk utils.parseHexU64(li.string) catch 0;
            }
            break :blk 0;
        };

        try logs.append(alloc, .{
            .address = try alloc.dupe(u8, if (obj.get("address")) |a| a.string else ""),
            .topics = try topics.toOwnedSlice(alloc),
            .data = try alloc.dupe(u8, if (obj.get("data")) |d| d.string else ""),
            .block_number = block_number,
            .transaction_hash = try alloc.dupe(u8, if (obj.get("transactionHash")) |th| th.string else ""),
            .log_index = log_index,
        });
    }

    return try logs.toOwnedSlice(alloc);
}

/// 释放日志列表内存
pub fn freeLogs(alloc: std.mem.Allocator, logs: []Log) void {
    for (logs) |l| {
        alloc.free(l.address);
        for (l.topics) |t| alloc.free(t);
        alloc.free(l.topics);
        alloc.free(l.data);
        alloc.free(l.transaction_hash);
    }
    alloc.free(logs);
}

// ============================================================================
// 单元测试
// ============================================================================

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
        .address = "0xabc",
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
