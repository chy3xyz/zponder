const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const cache = @import("cache.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const template = @import("template.zig");
const dashboard = @import("dashboard.zig");

const build_options = @import("build_options");

const MAX_CONCURRENT_CONNECTIONS = 256;
const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

/// URL 解码查询参数值（调用者负责释放返回值）
fn urlDecodeAlloc(alloc: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try alloc.dupe(u8, input);
    const decoded = std.Uri.percentDecodeInPlace(@constCast(buf));
    if (decoded.len == buf.len) return buf;
    const result = try alloc.dupe(u8, decoded);
    alloc.free(buf);
    return result;
}

/// 全局令牌桶速率限制器
const RateLimiter = struct {
    mutex: std.atomic.Mutex = .unlocked,
    tokens: f64,
    last_update_ms: i64,
    rate_per_sec: f64,
    burst: f64,

    pub fn init(rate_per_sec: f64, burst: f64) RateLimiter {
        return .{
            .tokens = burst,
            .last_update_ms = 0,
            .rate_per_sec = rate_per_sec,
            .burst = burst,
        };
    }

    /// 尝试获取一个令牌。返回 true 表示允许，false 表示应拒绝（429）。
    pub fn allow(self: *RateLimiter, now_ms: i64) bool {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        if (self.rate_per_sec <= 0) return true;

        if (self.last_update_ms > 0) {
            const elapsed_sec = @as(f64, @floatFromInt(now_ms - self.last_update_ms)) / 1000.0;
            self.tokens = @min(self.burst, self.tokens + elapsed_sec * self.rate_per_sec);
        }
        self.last_update_ms = now_ms;

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

/// HTTP 服务器
pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    config: *const config.HttpConfig,
    database: *db.Client,
    cache: *cache.Cache,
    indexers: []*indexer.Indexer,
    queries: []const config.QueryConfig,
    dashboards: []const config.DashboardConfig,
    listen_socket: ?std.Io.net.Server,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32),
    rate_limiter: RateLimiter,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        cfg: *const config.HttpConfig,
        database: *db.Client,
        c: *cache.Cache,
        indexers: []*indexer.Indexer,
        queries: []const config.QueryConfig,
        dashboards: []const config.DashboardConfig,
    ) Server {
        const rps = @as(f64, @floatFromInt(cfg.rate_limit_rps orelse 0));
        const burst = @as(f64, @floatFromInt(cfg.rate_limit_burst orelse 0));
        return .{
            .alloc = alloc,
            .io = io,
            .config = cfg,
            .database = database,
            .cache = c,
            .indexers = indexers,
            .queries = queries,
            .dashboards = dashboards,
            .listen_socket = null,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
            .rate_limiter = RateLimiter.init(rps, if (burst > 0) burst else rps),
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // 等待所有连接处理线程结束（最多 5 秒）
        var wait_ms: u32 = 0;
        while (self.active_connections.load(.monotonic) > 0 and wait_ms < 5000) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
            wait_ms += 10;
        }
        if (self.active_connections.load(.monotonic) > 0) {
            log.warn("HTTP 优雅退出超时，仍有 {d} 个活跃连接", .{self.active_connections.load(.monotonic)});
        }
    }

    pub fn start(self: *Server) !void {
        if (self.running.load(.monotonic)) return;

        const addr_str = try std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ self.config.host, self.config.port });
        defer self.alloc.free(addr_str);
        const addr = try std.Io.net.IpAddress.parseLiteral(addr_str);

        self.listen_socket = try addr.listen(self.io, .{ .kernel_backlog = 128 });
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, Server.runLoop, .{self});
        log.info("HTTP 服务已启动: http://{s}:{d}", .{ self.config.host, self.config.port });
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (self.listen_socket) |*s| {
            s.deinit(self.io);
            self.listen_socket = null;
        }
    }

    fn runLoop(self: *Server) void {
        var server = self.listen_socket.?;

        while (self.running.load(.monotonic)) {
            const stream = server.accept(self.io) catch |e| {
                if (self.running.load(.monotonic)) {
                    log.warn("accept 失败: {any}", .{e});
                }
                continue;
            };

            // 限制并发连接数，防止 OOM
            const current = self.active_connections.load(.monotonic);
            if (current >= MAX_CONCURRENT_CONNECTIONS) {
                log.warn("并发连接数已达上限 ({d})，拒绝新连接", .{MAX_CONCURRENT_CONNECTIONS});
                stream.close(self.io);
                continue;
            }
            _ = self.active_connections.fetchAdd(1, .monotonic);

            // 每个连接独立线程处理（简单线程池）
            const t = std.Thread.spawn(.{}, handleConnectionTracked, .{ self, stream }) catch |e| {
                log.warn("spawn worker 失败: {any}", .{e});
                _ = self.active_connections.fetchSub(1, .monotonic);
                stream.close(self.io);
                continue;
            };
            t.detach();
        }
    }

    fn handleConnectionTracked(self: *Server, stream: std.Io.net.Stream) void {
        defer _ = self.active_connections.fetchSub(1, .monotonic);
        handleConnection(self, stream);
    }

    fn handleConnection(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        var read_buf: [65536]u8 = undefined;
        var write_buf: [65536]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buf);
        var stream_writer = stream.writer(self.io, &write_buf);
        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        while (self.running.load(.monotonic)) {
            var request = http_server.receiveHead() catch |e| {
                if (e != error.EndOfStream) {
                    log.debug("HTTP 请求接收失败: {any}", .{e});
                }
                break;
            };

            self.handleRequest(&request) catch |e| {
                log.warn("请求处理失败: {any}", .{e});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch {};
            };

            if (!request.head.keep_alive) break;
        }
    }

    fn handleRequest(self: *Server, request: *std.http.Server.Request) !void {
        const target = request.head.target;
        const method = request.head.method;

        // 速率限制
        if (self.config.rate_limit_rps) |rps| {
            _ = rps;
            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            if (!self.rate_limiter.allow(now)) {
                try self.sendJson(request, "{\"error\":\"Too Many Requests\"}", .too_many_requests);
                return;
            }
        }

        // 限制请求体大小
        if (request.head.content_length) |cl| {
            if (cl > MAX_BODY_SIZE) {
                try self.sendJson(request, "{\"error\":\"Payload Too Large\"}", .payload_too_large);
                return;
            }
        }

        // CORS 预检请求
        if (method == .OPTIONS) {
            try self.sendCorsResponse(request, .no_content);
            return;
        }

        if (method == .GET and (std.mem.eql(u8, target, "/dashboards") or std.mem.startsWith(u8, target, "/dashboards/"))) {
            try self.handleDashboard(request);
        } else if (method == .GET and std.mem.startsWith(u8, target, "/pages/")) {
            try self.handlePage(request);
        } else if (method == .GET and (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/kline"))) {
            try self.handlePagePath(request, "pages/kline.html");
        } else if (method == .GET and std.mem.eql(u8, target, "/health")) {
            try self.handleHealth(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/sync_state")) {
            try self.handleSyncState(request);
        } else if (method == .GET and std.mem.startsWith(u8, target, "/events/")) {
            try self.handleEvents(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/contracts")) {
            try self.handleContracts(request);
        } else if (method == .GET and std.mem.startsWith(u8, target, "/balance/")) {
            try self.handleBalance(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/schema")) {
            try self.handleSchema(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/cache/stats")) {
            try self.handleCacheStats(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/metrics")) {
            try self.handleMetrics(request);
        } else if (method == .GET and std.mem.eql(u8, target, "/version")) {
            try self.handleVersion(request);
        } else if (method == .POST and std.mem.eql(u8, target, "/replay")) {
            try self.handleReplay(request);
        } else if (method == .GET and std.mem.startsWith(u8, target, "/queries/")) {
            try self.handleQuery(request);
        } else {
            try self.sendJson(request, "{\"error\":\"Not Found\"}", .not_found);
        }
    }

    /// 根据配置和请求的 Origin 头返回允许的 CORS origin
    fn corsOrigin(self: *Server, request: *std.http.Server.Request) []const u8 {
        const origins = self.config.cors_origins;
        if (origins.len == 0) return "*";
        if (origins.len == 1) return origins[0];

        // 多个 origin 时，尝试从请求头中匹配
        const origin_hdr = extractOriginHeader(request.head_buffer);
        if (origin_hdr.len > 0) {
            for (origins) |o| {
                if (std.mem.eql(u8, o, origin_hdr)) return o;
            }
        }
        // 不匹配时返回第一个配置 origin（避免反射攻击）
        return origins[0];
    }

    fn sendCorsResponse(self: *Server, request: *std.http.Server.Request, status: std.http.Status) !void {
        const origin = self.corsOrigin(request);
        try request.respond("", .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = origin },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
            },
        });
    }

    fn sendJson(self: *Server, request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
        const origin = self.corsOrigin(request);
        try request.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Access-Control-Allow-Origin", .value = origin },
            },
        });
    }

    fn handleSyncState(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        try buf.writer.writeAll("[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try buf.writer.writeByte(',');
            const status_str = switch (idx.getStatus()) {
                .running => "running",
                .stopped => "stopped",
                .error_state => "error",
                .replaying => "replaying",
            };
            try buf.writer.writeAll("{\"name\":\"");
            try utils.jsonEscapeString(&buf.writer, idx.contract.name);
            try buf.writer.writeAll("\",\"address\":\"");
            try utils.jsonEscapeString(&buf.writer, idx.contract.address);
            try buf.writer.print("\",\"current_block\":{},\"status\":\"{s}\"}}", .{ idx.getCurrentBlock(), status_str });
        }
        try buf.writer.writeAll("]");

        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.sendJson(request, list.items, .ok);
    }

    fn handleBalance(self: *Server, request: *std.http.Server.Request) !void {
        const prefix = "/balance/";
        const rest = request.head.target[prefix.len..];

        var path_it = std.mem.splitSequence(u8, rest, "/");
        const contract_name = path_it.next() orelse "";
        const account_address = path_it.next() orelse "";

        if (contract_name.len == 0 or account_address.len == 0) {
            try self.sendJson(request, "{\"error\":\"invalid path, use /balance/:contract/:account\"}", .bad_request);
            return;
        }

        // 查找合约地址
        var contract_address: []const u8 = "";
        for (self.indexers) |idx| {
            if (std.mem.eql(u8, idx.contract.name, contract_name)) {
                contract_address = idx.contract.address;
                break;
            }
        }
        if (contract_address.len == 0) {
            try self.sendJson(request, "{\"error\":\"contract not found\"}", .not_found);
            return;
        }

        // URL 解码账户地址
        const decoded_account = urlDecodeAlloc(self.alloc, account_address) catch |e| {
            log.warn("URL 解码 account 失败: {any}", .{e});
            try self.sendJson(request, "{\"error\":\"invalid account address\"}", .bad_request);
            return;
        };
        defer self.alloc.free(decoded_account);

        if (self.database.getAccountBalance(contract_address, decoded_account)) |balance| {
            defer if (balance) |b| self.alloc.free(b);
            if (balance) |b| {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                try buf.print(self.alloc, "{{\"contract\":\"{s}\",\"account\":\"{s}\",\"balance\":\"{s}\"}}", .{ contract_name, decoded_account, b });
                try self.sendJson(request, buf.items, .ok);
            } else {
                try self.sendJson(request, "{\"error\":\"account not found\"}", .not_found);
            }
        } else |e| {
            log.err("查询余额失败: {any}", .{e});
            try self.sendJson(request, "{\"error\":\"query failed\"}", .internal_server_error);
        }
    }

    fn handleEvents(self: *Server, request: *std.http.Server.Request) !void {
        const prefix = "/events/";
        const rest = request.head.target[prefix.len..];

        const path_only = if (std.mem.indexOf(u8, rest, "?")) |qs| rest[0..qs] else rest;
        var path_it = std.mem.splitSequence(u8, path_only, "/");
        const contract_name = path_it.next() orelse "";
        const event_name = path_it.next() orelse "";

        if (contract_name.len == 0 or event_name.len == 0) {
            try self.sendJson(request, "{\"error\":\"invalid path, use /events/:contract/:event\"}", .bad_request);
            return;
        }

        // 白名单校验：只允许已配置合约和事件
        var found_contract = false;
        var found_event = false;
        for (self.indexers) |idx| {
            if (std.mem.eql(u8, idx.contract.name, contract_name)) {
                found_contract = true;
                for (idx.contract.events) |evt| {
                    if (std.mem.eql(u8, evt, event_name)) {
                        found_event = true;
                        break;
                    }
                }
                break;
            }
        }
        if (!found_contract or !found_event) {
            try self.sendJson(request, "{\"error\":\"contract or event not configured\"}", .not_found);
            return;
        }

        // 解析查询参数
        var block_from: ?u64 = null;
        var block_to: ?u64 = null;
        var tx_hash: ?[]const u8 = null;
        var tx_hash_owned = false;
        var limit: u32 = 100;
        var offset: u32 = 0;
        var order_desc: bool = true;

        const query_start = std.mem.indexOf(u8, request.head.target, "?");
        if (query_start) |qs| {
            const query = request.head.target[qs + 1 ..];
            var param_it = std.mem.splitSequence(u8, query, "&");
            while (param_it.next()) |param| {
                var kv = std.mem.splitSequence(u8, param, "=");
                const key = kv.next() orelse continue;
                const val = kv.next() orelse continue;

                // URL 解码参数值
                const decoded = urlDecodeAlloc(self.alloc, val) catch continue;
                defer self.alloc.free(decoded);

                if (std.mem.eql(u8, key, "block_from")) {
                    block_from = std.fmt.parseInt(u64, decoded, 10) catch null;
                } else if (std.mem.eql(u8, key, "block_to")) {
                    block_to = std.fmt.parseInt(u64, decoded, 10) catch null;
                } else if (std.mem.eql(u8, key, "tx_hash")) {
                    tx_hash = try self.alloc.dupe(u8, decoded);
                    tx_hash_owned = true;
                } else if (std.mem.eql(u8, key, "limit")) {
                    limit = std.fmt.parseInt(u32, decoded, 10) catch 100;
                    if (limit > 1000) limit = 1000;
                } else if (std.mem.eql(u8, key, "offset")) {
                    offset = std.fmt.parseInt(u32, decoded, 10) catch 0;
                } else if (std.mem.eql(u8, key, "order")) {
                    order_desc = !std.mem.eql(u8, decoded, "asc");
                }
            }
        }
        defer if (tx_hash_owned) self.alloc.free(tx_hash.?);

        // 计算当前同步区块
        var current_sync_block: u64 = 0;
        for (self.indexers) |idx| {
            if (std.mem.eql(u8, idx.contract.name, contract_name)) {
                current_sync_block = idx.getCurrentBlock();
                break;
            }
        }

        const cache_key = try std.fmt.allocPrint(self.alloc, "{s}:{s}:bf={?d}:bt={?d}:tx={s}:l={d}:o={d}:od={}", .{
            contract_name, event_name, block_from, block_to, tx_hash orelse "", limit, offset, order_desc,
        });
        defer self.alloc.free(cache_key);

        if (self.cache.get(cache_key, current_sync_block)) |cached| {
            try self.sendJson(request, cached, .ok);
            return;
        }

        const result = self.database.queryEventLogs(
            contract_name, event_name,
            block_from, block_to, tx_hash,
            limit, offset, order_desc,
        ) catch |e| {
            log.warn("查询事件日志失败 {s}.{s}: {any}", .{ contract_name, event_name, e });
            try self.sendJson(request, "{\"error\":\"query failed\"}", .internal_server_error);
            return;
        };
        defer self.alloc.free(result);

        self.cache.put(cache_key, result, current_sync_block) catch |e| {
            log.debug("缓存写入失败: {any}", .{e});
        };

        try self.sendJson(request, result, .ok);
    }

    fn handleContracts(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        try buf.writer.writeAll("[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try buf.writer.writeByte(',');
            try buf.writer.writeAll("{\"name\":\"");
            try utils.jsonEscapeString(&buf.writer, idx.contract.name);
            try buf.writer.writeAll("\",\"address\":\"");
            try utils.jsonEscapeString(&buf.writer, idx.contract.address);
            try buf.writer.writeAll("\",\"abi_path\":\"");
            try utils.jsonEscapeString(&buf.writer, idx.contract.abi_path);
            try buf.writer.print("\",\"from_block\":{d},\"events\":[", .{idx.contract.from_block});
            for (idx.contract.events, 0..) |evt, j| {
                if (j > 0) try buf.writer.writeByte(',');
                try buf.writer.writeByte('"');
                try utils.jsonEscapeString(&buf.writer, evt);
                try buf.writer.writeByte('"');
            }
            try buf.writer.writeAll("]}");
        }
        try buf.writer.writeAll("]");

        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.sendJson(request, list.items, .ok);
    }

    fn handleSchema(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        try buf.writer.writeAll("{\"endpoints\":[");
        try buf.writer.writeAll("{\"path\":\"/health\",\"method\":\"GET\",\"description\":\"服务健康检查\"},");
        try buf.writer.writeAll("{\"path\":\"/sync_state\",\"method\":\"GET\",\"description\":\"获取所有合约同步状态\"},");
        try buf.writer.writeAll("{\"path\":\"/contracts\",\"method\":\"GET\",\"description\":\"列出所有监听合约\"},");
        try buf.writer.writeAll("{\"path\":\"/schema\",\"method\":\"GET\",\"description\":\"API 自动生成文档\"},");
        try buf.writer.writeAll("{\"path\":\"/cache/stats\",\"method\":\"GET\",\"description\":\"缓存统计\"},");
        try buf.writer.writeAll("{\"path\":\"/metrics\",\"method\":\"GET\",\"description\":\"Prometheus 指标\"},");
        try buf.writer.writeAll("{\"path\":\"/version\",\"method\":\"GET\",\"description\":\"版本信息\"},");
        try buf.writer.writeAll("{\"path\":\"/queries/:name\",\"method\":\"GET\",\"description\":\"执行自定义 SQL 查询\"},");
        try buf.writer.writeAll("{\"path\":\"/events/:contract/:event\",\"method\":\"GET\",\"description\":\"查询事件日志\",\"params\":[");
        try buf.writer.writeAll("{\"name\":\"block_from\",\"type\":\"integer\",\"optional\":true,\"description\":\"起始区块\"},");
        try buf.writer.writeAll("{\"name\":\"block_to\",\"type\":\"integer\",\"optional\":true,\"description\":\"结束区块\"},");
        try buf.writer.writeAll("{\"name\":\"tx_hash\",\"type\":\"string\",\"optional\":true,\"description\":\"交易哈希过滤\"},");
        try buf.writer.writeAll("{\"name\":\"limit\",\"type\":\"integer\",\"optional\":true,\"default\":100,\"max\":1000,\"description\":\"返回条数\"},");
        try buf.writer.writeAll("{\"name\":\"offset\",\"type\":\"integer\",\"optional\":true,\"default\":0,\"description\":\"分页偏移\"},");
        try buf.writer.writeAll("{\"name\":\"order\",\"type\":\"string\",\"optional\":true,\"default\":\"desc\",\"enum\":[\"asc\",\"desc\"],\"description\":\"排序方向\"}]},");
        try buf.writer.writeAll("{\"path\":\"/replay\",\"method\":\"POST\",\"description\":\"重放指定区块范围\"}");
        try buf.writer.writeAll("],\"contracts\":[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try buf.writer.writeByte(',');
            try buf.writer.print("{{\"name\":\"{s}\",\"address\":\"{s}\",\"events\":[", .{ idx.contract.name, idx.contract.address });
            for (idx.contract.events, 0..) |evt, j| {
                if (j > 0) try buf.writer.writeByte(',');
                try buf.writer.print("\"{s}\"", .{evt});
            }
            try buf.writer.writeAll("]}");
        }
        try buf.writer.writeAll("]}");

        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.sendJson(request, list.items, .ok);
    }

    fn handleCacheStats(self: *Server, request: *std.http.Server.Request) !void {
        const stats = self.cache.stats();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.print(self.alloc,
            "{{\"cached_entries\":{d},\"total_bytes\":{d}}}",
            .{ stats.count, stats.total_bytes },
        );
        try self.sendJson(request, buf.items, .ok);
    }

    fn handleMetrics(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        const stats = self.cache.stats();

        try buf.writer.print(
            "# HELP zponder_cache_entries 缓存条目数\n" ++
            "# TYPE zponder_cache_entries gauge\n" ++
            "zponder_cache_entries {d}\n" ++
            "# HELP zponder_cache_bytes 缓存占用字节数\n" ++
            "# TYPE zponder_cache_bytes gauge\n" ++
            "zponder_cache_bytes {d}\n" ++
            "# HELP zponder_indexers 索引器数量\n" ++
            "# TYPE zponder_indexers gauge\n" ++
            "zponder_indexers {d}\n",
            .{ stats.count, stats.total_bytes, self.indexers.len },
        );

        for (self.indexers) |idx| {
            const status_str = switch (idx.getStatus()) {
                .running => @as(u8, 1),
                .stopped => @as(u8, 0),
                .error_state => @as(u8, 2),
                .replaying => @as(u8, 3),
            };
            try buf.writer.print(
                "# HELP zponder_indexer_current_block 索引器当前区块\n" ++
                "# TYPE zponder_indexer_current_block gauge\n" ++
                "zponder_indexer_current_block{{contract=\"{s}\"}} {d}\n" ++
                "# HELP zponder_indexer_status 索引器状态码\n" ++
                "# TYPE zponder_indexer_status gauge\n" ++
                "zponder_indexer_status{{contract=\"{s}\"}} {d}\n",
                .{ idx.contract.name, idx.getCurrentBlock(), idx.contract.name, status_str },
            );
        }

        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        const origin = self.corsOrigin(request);
        try request.respond(list.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Access-Control-Allow-Origin", .value = origin },
            },
        });
    }

    fn handleHealth(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();

        const cache_stats = self.cache.stats();

        try buf.writer.writeAll("{\"status\":\"ok\",\"indexers\":[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try buf.writer.writeByte(',');
            const status_str = switch (idx.getStatus()) {
                .running => "running",
                .stopped => "stopped",
                .error_state => "error",
                .replaying => "replaying",
            };
            try buf.writer.print(
                "{{\"name\":\"{s}\",\"current_block\":{d},\"status\":\"{s}\"}}",
                .{ idx.contract.name, idx.getCurrentBlock(), status_str },
            );
        }
        try buf.writer.print(
            "],\"cache\":{{\"entries\":{d},\"bytes\":{d}}}}}",
            .{ cache_stats.count, cache_stats.total_bytes },
        );

        var list = buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.sendJson(request, list.items, .ok);
    }

    /// 模板变量 (返回值由调用方负责 deinit)
    fn buildTemplateVars(self: *Server) !template.VarMap {
        var vars = try template.VarMap.init(self.alloc, 5);
        errdefer vars.deinit(self.alloc);

        try vars.putOwned(self.alloc, 0, "API", try std.fmt.allocPrint(self.alloc, "http://{s}:{d}", .{ self.config.host, self.config.port }));
        try vars.putOwned(self.alloc, 1, "VERSION", try std.fmt.allocPrint(self.alloc, "{s} ({s})", .{ build_options.version, build_options.git_commit }));

        // 合约列表
        var cb = std.ArrayList(u8).empty;
        try cb.appendSlice(self.alloc, "[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try cb.appendSlice(self.alloc, ",");
            try cb.print(self.alloc, "{{\"name\":\"{s}\",\"address\":\"{s}\",\"block\":{}}}", .{
                idx.contract.name, idx.contract.address, idx.getCurrentBlock(),
            });
        }
        try cb.appendSlice(self.alloc, "]");
        try vars.putOwned(self.alloc, 2, "CONTRACTS", cb.items);

        // 同步状态
        var sb = std.ArrayList(u8).empty;
        try sb.appendSlice(self.alloc, "[");
        for (self.indexers, 0..) |idx, i| {
            if (i > 0) try sb.appendSlice(self.alloc, ",");
            try sb.print(self.alloc, "{{\"name\":\"{s}\",\"block\":{},\"state\":\"syncing\"}}", .{ idx.contract.name, idx.getCurrentBlock() });
        }
        try sb.appendSlice(self.alloc, "]");
        try vars.putOwned(self.alloc, 3, "SYNC_STATE", sb.items);

        const cs = self.cache.stats();
        try vars.putOwned(self.alloc, 4, "CACHE_STATS", try std.fmt.allocPrint(self.alloc, "{{\"entries\":{},\"bytes\":{}}}", .{ cs.count, cs.total_bytes }));

        return vars;
    }

    fn deinitTemplateVars(self: *Server, v: *template.VarMap) void {
        for (v.values) |val| self.alloc.free(val);
        for (v.keys) |key| self.alloc.free(key);
        v.deinit(self.alloc);
    }

    fn handleDashboard(self: *Server, request: *std.http.Server.Request) !void {
        // 重定向到静态页面，由 HTMX 拉取数据
        const prefix = "/dashboards/";
        const name = if (request.head.target.len >= prefix.len)
            request.head.target[prefix.len..]
        else
            "";

        if (name.len == 0) {
            var buf: std.Io.Writer.Allocating = .init(self.alloc);
            defer buf.deinit();
            try buf.writer.writeAll("[");
            for (self.dashboards, 0..) |d, i| {
                if (i > 0) try buf.writer.writeByte(',');
                try buf.writer.print("{{\"name\":\"{s}\",\"title\":\"{s}\",\"widgets\":{d}}}", .{ d.name, d.title, d.widgets.len });
            }
            try buf.writer.writeAll("]");
            var list = buf.toArrayList();
            defer list.deinit(self.alloc);
            self.alloc.free(list.items); // 自由 JSON allocPrint 分配的内存... fix later
            try self.sendJson(request, list.items, .ok);
            return;
        }

        // Serve static dashboard page with template vars
        try self.handlePagePath(request, "pages/dashboard.html");
    }

    fn handlePage(self: *Server, request: *std.http.Server.Request) !void {
        const prefix = "/pages/";
        const page_name = request.head.target[prefix.len..];
        if (page_name.len == 0) {
            try self.sendJson(request, "{\"error\":\"usage: /pages/:name\"}", .bad_request);
            return;
        }
        var path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "pages/{s}.html", .{page_name});
        try self.handlePagePath(request, file_path);
    }

    fn handlePagePath(self: *Server, request: *std.http.Server.Request, file_path: []const u8) !void {
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.alloc, .limited(256 * 1024)) catch {
            try self.sendJson(request, "{\"error\":\"page not found\"}", .not_found);
            return;
        };
        defer self.alloc.free(raw);

        var vars = self.buildTemplateVars() catch template.VarMap{ .keys = &.{}, .values = &.{} };
        defer {
            for (vars.keys) |k| self.alloc.free(k);
            for (vars.values) |v| self.alloc.free(v);
            vars.deinit(self.alloc);
        }

        const rendered = template.render(self.alloc, self.io, raw, vars) catch raw;
        defer if (rendered.ptr != raw.ptr) self.alloc.free(rendered);

        try request.respond(rendered, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            },
        });
    }

    fn handleVersion(self: *Server, request: *std.http.Server.Request) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.print(self.alloc,
            "{{\"version\":\"{s}\",\"commit\":\"{s}\",\"zig_version\":\"{s}\"}}",
            .{ build_options.version, build_options.git_commit, @import("builtin").zig_version_string },
        );
        try self.sendJson(request, buf.items, .ok);
    }

    fn handleReplay(self: *Server, request: *std.http.Server.Request) !void {
        // 解析查询参数（简化版 replay）
        const query_start = std.mem.indexOf(u8, request.head.target, "?");
        var contract_name: []const u8 = "";
        var contract_name_owned = false;
        var from_block: u64 = 0;
        var to_block: u64 = 0;

        if (query_start) |qs| {
            const query = request.head.target[qs + 1 ..];
            var param_it = std.mem.splitSequence(u8, query, "&");
            while (param_it.next()) |param| {
                var kv = std.mem.splitSequence(u8, param, "=");
                const key = kv.next() orelse continue;
                const val = kv.next() orelse continue;

                const decoded = urlDecodeAlloc(self.alloc, val) catch continue;
                defer self.alloc.free(decoded);

                if (std.mem.eql(u8, key, "contract")) {
                    contract_name = try self.alloc.dupe(u8, decoded);
                    contract_name_owned = true;
                } else if (std.mem.eql(u8, key, "from_block")) {
                    from_block = std.fmt.parseInt(u64, decoded, 10) catch 0;
                } else if (std.mem.eql(u8, key, "to_block")) {
                    to_block = std.fmt.parseInt(u64, decoded, 10) catch 0;
                }
            }
        }
        defer if (contract_name_owned) self.alloc.free(contract_name);

        if (contract_name.len == 0 or from_block == 0) {
            try self.sendJson(request, "{\"error\":\"missing contract or from_block\"}", .bad_request);
            return;
        }

        var found = false;
        for (self.indexers) |idx| {
            if (std.mem.eql(u8, idx.contract.name, contract_name)) {
                idx.setReplay(from_block, to_block) catch |e| {
                    log.err("重放失败 {s}: {any}", .{ contract_name, e });
                    try self.sendJson(request, "{\"error\":\"replay failed\"}", .internal_server_error);
                    return;
                };
                found = true;
                break;
            }
        }

        if (!found) {
            try self.sendJson(request, "{\"error\":\"contract not found\"}", .not_found);
            return;
        }

        try self.sendJson(request, "{\"status\":\"replaying\"}", .ok);
    }

    // ========================================================================
    // 自定义 SQL 查询 (config-driven)
    // ========================================================================
    fn handleQuery(self: *Server, request: *std.http.Server.Request) !void {
        const prefix = "/queries/";
        const rest = request.head.target[prefix.len..];
        const query_name = if (std.mem.indexOf(u8, rest, "?")) |qs| rest[0..qs] else rest;

        if (query_name.len == 0) {
            try self.sendJson(request, "{\"error\":\"missing query name, use /queries/:name\"}", .bad_request);
            return;
        }

        // 查找配置的查询定义
        var query_cfg: ?*const config.QueryConfig = null;
        for (self.queries) |*q| {
            if (std.mem.eql(u8, q.name, query_name)) {
                query_cfg = q;
                break;
            }
        }
        const qc = query_cfg orelse {
            try self.sendJson(request, "{\"error\":\"query not found\"}", .not_found);
            return;
        };

        if (self.database.backend_type == .rocksdb) {
            try self.sendJson(request, "{\"error\":\"SQL queries require SQLite or PostgreSQL backend\"}", .bad_request);
            return;
        }

        // 解析查询参数
        var param_values = std.ArrayList([]const u8).empty;
        defer {
            for (param_values.items) |v| self.alloc.free(v);
            param_values.deinit(self.alloc);
        }
        var param_names = std.ArrayList([]const u8).empty;
        defer param_names.deinit(self.alloc);

        const query_start = std.mem.indexOf(u8, request.head.target, "?");
        if (query_start) |qs| {
            const query = request.head.target[qs + 1 ..];
            var param_it = std.mem.splitSequence(u8, query, "&");
            while (param_it.next()) |param| {
                var kv = std.mem.splitSequence(u8, param, "=");
                const key = kv.next() orelse continue;
                const val = kv.next() orelse continue;
                const decoded = urlDecodeAlloc(self.alloc, val) catch continue;

                // 检查是否为配置的参数
                var matched = false;
                for (qc.params) |p| {
                    if (std.mem.eql(u8, key, p.name)) {
                        try param_names.append(self.alloc, p.name);
                        try param_values.append(self.alloc, decoded);
                        matched = true;
                        break;
                    }
                }
                if (!matched) self.alloc.free(decoded);
            }
        }

        // 补全未提供的参数（使用默认值）
        for (qc.params) |p| {
            var found = false;
            for (param_names.items) |n| {
                if (std.mem.eql(u8, n, p.name)) { found = true; break; }
            }
            if (!found) {
                try param_names.append(self.alloc, p.name);
                try param_values.append(self.alloc, try self.alloc.dupe(u8, p.default_value));
            }
        }

        // 转换 SQL：将 $param_name 替换为后端口占位符
        var translated_sql = std.ArrayList(u8).empty;
        defer translated_sql.deinit(self.alloc);
        var i: usize = 0;
        while (i < qc.sql.len) {
            if (qc.sql[i] == '$' and i + 1 < qc.sql.len) {
                // 尝试匹配参数名
                const rest_sql = qc.sql[i + 1 ..];
                var param_idx: ?usize = null;
                var name_len: usize = 0;
                for (param_names.items, 0..) |name, pi| {
                    if (std.mem.startsWith(u8, rest_sql, name)) {
                        // 确保是单词边界
                        const after = i + 1 + name.len;
                        if (after >= qc.sql.len or !std.ascii.isAlphanumeric(qc.sql[after]) and qc.sql[after] != '_') {
                            param_idx = pi;
                            name_len = name.len;
                            break;
                        }
                    }
                }
                if (param_idx) |pi| {
                    if (self.database.backend_type == .postgresql) {
                        try translated_sql.print(self.alloc, "${d}", .{pi + 1});
                    } else {
                        try translated_sql.append(self.alloc, '?');
                    }
                    i += 1 + name_len;
                    continue;
                }
            }
            try translated_sql.append(self.alloc, qc.sql[i]);
            i += 1;
        }

        // 缓存键
        var cache_key_buf = std.ArrayList(u8).empty;
        defer cache_key_buf.deinit(self.alloc);
        try cache_key_buf.print(self.alloc, "q:{s}:", .{query_name});
        for (param_values.items) |v| {
            try cache_key_buf.print(self.alloc, "{s}:", .{v});
        }

        const cache_key = try cache_key_buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(cache_key);

        // 缓存检查
        var current_sync_block: u64 = 0;
        for (self.indexers) |idx| {
            const b = idx.getCurrentBlock();
            if (b > current_sync_block) current_sync_block = b;
        }
        if (self.cache.get(cache_key, current_sync_block)) |cached| {
            try self.sendJson(request, cached, .ok);
            return;
        }

        // 执行查询
        const result = self.database.execQuery(
            translated_sql.items,
            param_names.items,
            param_values.items,
        ) catch |e| {
            log.warn("自定义查询 {s} 失败: {any}", .{ query_name, e });
            try self.sendJson(request, "{\"error\":\"query execution failed\"}", .internal_server_error);
            return;
        };
        defer self.alloc.free(result);

        // 写入缓存
        _ = self.cache.put(cache_key, result, current_sync_block) catch {
            log.debug("查询缓存写入失败: {s}", .{query_name});
        };

        try self.sendJson(request, result, .ok);
    }
};

/// 从原始 HTTP 头缓冲区中提取 Origin 头值（大小写不敏感）
fn extractOriginHeader(head_buffer: []const u8) []const u8 {
    var it = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = it.next(); // 跳过请求行
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Origin:")) {
            var val = line["Origin:".len..];
            // 跳过前导空格
            while (val.len > 0 and val[0] == ' ') val = val[1..];
            return val;
        }
    }
    return "";
}

// ============================================================================
// 单元测试
// ============================================================================

test "urlDecodeAlloc basic" {
    const alloc = std.testing.allocator;
    {
        const decoded = try urlDecodeAlloc(alloc, "hello%20world");
        defer alloc.free(decoded);
        try std.testing.expectEqualStrings("hello world", decoded);
    }
    {
        const decoded = try urlDecodeAlloc(alloc, "0xabc%3Ddef");
        defer alloc.free(decoded);
        try std.testing.expectEqualStrings("0xabc=def", decoded);
    }
    {
        // 无编码时返回原样
        const decoded = try urlDecodeAlloc(alloc, "plain");
        defer alloc.free(decoded);
        try std.testing.expectEqualStrings("plain", decoded);
    }
}

test "extractOriginHeader" {
    const buf = "GET /events/test/Transfer HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.com\r\n\r\n";
    const origin = extractOriginHeader(buf);
    try std.testing.expectEqualStrings("http://example.com", origin);

    const buf2 = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const origin2 = extractOriginHeader(buf2);
    try std.testing.expectEqualStrings("", origin2);
}

test "RateLimiter token bucket" {
    var rl = RateLimiter.init(10.0, 5.0);
    const now: i64 = 1000;

    // 初始有 burst 个令牌
    try std.testing.expect(rl.allow(now));
    try std.testing.expect(rl.allow(now));
    try std.testing.expect(rl.allow(now));
    try std.testing.expect(rl.allow(now));
    try std.testing.expect(rl.allow(now));
    // 第 6 个应被拒绝
    try std.testing.expect(!rl.allow(now));

    // 100ms 后恢复 1 个令牌 (10 tokens/sec = 1 token/100ms)
    try std.testing.expect(rl.allow(now + 100));
    try std.testing.expect(!rl.allow(now + 100));
}

test "RateLimiter zero rate means unlimited" {
    var rl = RateLimiter.init(0.0, 0.0);
    try std.testing.expect(rl.allow(1000));
    try std.testing.expect(rl.allow(1000));
}
