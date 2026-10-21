const std = @import("std");
const zg = @import("zgraphql");
const config = @import("config.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const eth_rpc = @import("eth_rpc.zig");
const abi = @import("abi.zig");
const build_options = @import("build_options");
const auth = @import("auth.zig");

const log = std.log.scoped(.graphql);

/// Context passed to all GraphQL resolvers via user_data.
pub const Context = struct {
    database: *db.Client,
    indexers: []const *indexer.Indexer,
    chain: []const u8,
    shutdown_flag: *std.atomic.Value(bool),
    rpc: *eth_rpc.Client,
};

/// Schema definition using comptime SchemaBuilder.
const Builder = zg.SchemaBuilder(.{
    .Query = .{
        .health = .{ .type = "String!" },
        .version = .{ .type = "String!" },
        .contracts = .{ .type = "[Contract!]!" },
        .contract = .{
            .type = "Contract",
            .args = .{ .name = .{ .type = "String!" } },
        },
        .syncStates = .{ .type = "[SyncState!]!" },
        .latestEvents = .{
            .type = "[Event!]",
            .args = .{
                .contract = .{ .type = "String!" },
                .event = .{ .type = "String!" },
                .limit = .{ .type = "Int", .default_value = "10" },
                .offset = .{ .type = "Int", .default_value = "0" },
                .blockFrom = .{ .type = "Int" },
                .blockTo = .{ .type = "Int" },
                .address = .{ .type = "String" },
            },
        },
        .contractCall = .{
            .type = "String",
            .args = .{
                .contract = .{ .type = "String!" },
                .method = .{ .type = "String!" },
                .args = .{ .type = "[String!]" },
                .blockNumber = .{ .type = "Int" },
            },
        },
    },
    .Contract = .{
        .name = .{ .type = "String!" },
        .address = .{ .type = "String!" },
        .chain = .{ .type = "String!" },
        .fromBlock = .{ .type = "Int!" },
        .events = .{ .type = "[String!]!" },
    },
    .SyncState = .{
        .contractName = .{ .type = "String!" },
        .currentBlock = .{ .type = "Int!" },
        .status = .{ .type = "IndexerStatus!" },
    },
    .IndexerStatus = .{
        .kind = "enum",
        .RUNNING = .{},
        .STOPPED = .{},
        .ERROR = .{},
        .REPLAYING = .{},
    },
    .Event = .{
        .blockNumber = .{ .type = "Int!" },
        .transactionHash = .{ .type = "String!" },
        .eventName = .{ .type = "String!" },
        .contractAddress = .{ .type = "String!" },
        .fields = .{ .type = "[EventField!]!" },
    },
    .EventField = .{
        .key = .{ .type = "String!" },
        .value = .{ .type = "String!" },
    },
    .Subscription = .{
        .newBlocks = .{ .type = "Int!" },
    },
});

/// 鉴权代理监听对外端口，GraphQL 本体绑在 127.0.0.1 的错开端口上。
pub fn internalGraphqlPort(public_port: u16) u16 {
    if (public_port < 45536) return public_port + 20000;
    return public_port - 20000;
}

/// 主线程在 `listen` 返回前持有的停止把手。`Gate` 比服务线程活得久，由 `stop` 释放。
pub const Gate = struct {
    mu: std.atomic.Mutex = .unlocked,
    alive: bool = true,
    server: *zg.GraphQLServer,
    bind: std.Io.net.IpAddress,
};

pub const Service = struct {
    thread: std.Thread,
    gate: *Gate,
    alloc: std.mem.Allocator,

    /// 连一下监听地址，让堵在 `accept` 里的 `listen` 返回去看 `shutdown` 标志。
    pub fn poke(self: *const Service, io: std.Io) bool {
        const addr = pokeAddress(self.gate.bind);
        const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
        stream.close(io);
        return true;
    }

    pub fn stop(self: *Service, io: std.Io) void {
        lockGate(&self.gate.mu);
        const still = self.gate.alive;
        if (still) self.gate.server.shutdown();
        self.gate.mu.unlock();
        if (still) _ = self.poke(io);
        self.thread.join();
        self.alloc.destroy(self.gate);
        self.gate = undefined;
    }
};

fn lockGate(mu: *std.atomic.Mutex) void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

fn pokeAddress(addr: std.Io.net.IpAddress) std.Io.net.IpAddress {
    return switch (addr) {
        .ip4 => |ip4| .{
            .ip4 = if (ip4.bytes[0] == 0 and ip4.bytes[1] == 0 and ip4.bytes[2] == 0 and ip4.bytes[3] == 0)
                .loopback(ip4.port)
            else
                ip4,
        },
        .ip6 => addr,
    };
}

pub fn start(alloc: std.mem.Allocator, cfg: *const config.GraphQLConfig, ctx: Context, api_token: []const u8) !Service {
    if (!cfg.enabled) {
        log.info("GraphQL 服务未启用", .{});
        return error.GraphQLDisabled;
    }

    var schema_def = try Builder.init(alloc);
    errdefer schema_def.deinit();

    attachResolvers(&schema_def);

    const public_addr = try std.Io.net.IpAddress.parseIp4(cfg.host, cfg.port);
    const token_copy = try alloc.dupe(u8, api_token);
    errdefer alloc.free(token_copy);
    const internal_port: u16 = if (token_copy.len > 0) internalGraphqlPort(cfg.port) else cfg.port;
    const bind_addr = if (token_copy.len > 0)
        try std.Io.net.IpAddress.parseIp4("127.0.0.1", internal_port)
    else
        public_addr;

    const ctx_ptr = try alloc.create(Context);
    errdefer alloc.destroy(ctx_ptr);
    ctx_ptr.* = ctx;

    // Setup rate limiter if configured.
    var rate_limiter: ?zg.RateLimiter = null;
    if (cfg.rate_limit_rps) |rps| {
        const burst = cfg.rate_limit_burst orelse rps * 10;
        rate_limiter = zg.RateLimiter.init(alloc, burst, rps);
        log.info("GraphQL 速率限制: {d} req/s, burst {d}", .{ rps, burst });
    }

    const server = zg.GraphQLServer.init(alloc, &schema_def, .{
        .bind_address = bind_addr,
        .max_query_depth = if (cfg.max_query_depth > 0) cfg.max_query_depth else null,
        .max_query_complexity = if (cfg.max_query_complexity > 0) cfg.max_query_complexity else null,
        .enable_playground = cfg.enable_playground,
        .rate_limiter = if (rate_limiter) |*rl| rl else null,
        .user_data = @constCast(@ptrCast(ctx_ptr)),
    });

    const ServerWrapper = struct {
        server: zg.GraphQLServer,
        schema_def: zg.schema.Schema,
        allocator: std.mem.Allocator,
        address: std.Io.net.IpAddress,
        enable_playground: bool,
        ctx_ptr: *Context,
        rate_limiter: ?zg.RateLimiter,
        api_token: []u8,
        internal_port: u16,
        proxy_running: std.atomic.Value(bool),
        proxy_ready: std.atomic.Value(bool),
        proxy_ok: std.atomic.Value(bool),
        proxy_io: std.Io,
        proxy_listener: ?std.Io.net.Server,
        gate: *Gate,

        fn run(self: *@This()) void {
            defer {
                lockGate(&self.gate.mu);
                self.gate.alive = false;
                self.gate.mu.unlock();
                self.allocator.free(self.api_token);
                self.ctx_ptr.shutdown_flag.store(true, .release);
                self.schema_def.deinit();
                if (self.rate_limiter) |*rl| rl.deinit();
                self.allocator.destroy(self.ctx_ptr);
                self.allocator.destroy(self);
            }

            // 统一使用 Threaded backend（跨平台）；std.Io.Uring 在 0.17-dev 无静态构造器
            var backend = std.Io.Threaded.init(self.allocator, .{});
            defer backend.deinit();
            const backend_io = backend.io();

            if (self.enable_playground) {
                log.info("GraphQL Playground: http://{f}/graphql/playground", .{self.address});
            }

            if (self.api_token.len == 0) {
                log.info("GraphQL 服务已启动: http://{f}/graphql", .{self.address});
                self.server.listen(backend_io) catch |err| {
                    log.err("GraphQL 服务异常退出: {s}", .{@errorName(err)});
                };
                return;
            }

            self.proxy_running.store(true, .release);
            const proxy_thread = std.Thread.spawn(.{}, @This().authProxyMain, .{self}) catch |err| {
                log.err("GraphQL 鉴权代理启动失败: {s}", .{@errorName(err)});
                return;
            };
            while (!self.proxy_ready.load(.acquire)) std.atomic.spinLoopHint();
            if (!self.proxy_ok.load(.acquire)) {
                log.err("GraphQL 鉴权代理未能监听 {f}", .{self.address});
                proxy_thread.join();
                return;
            }

            log.info("GraphQL 服务已启动: http://{f}/graphql（Bearer 鉴权）", .{self.address});
            self.server.listen(backend_io) catch |err| {
                log.err("GraphQL 服务异常退出: {s}", .{@errorName(err)});
            };
            self.proxy_running.store(false, .release);
            if (self.proxy_listener) |*ls| {
                ls.deinit(self.proxy_io);
                self.proxy_listener = null;
            }
            proxy_thread.join();
        }

        fn authProxyMain(self: *@This()) void {
            var threaded = std.Io.Threaded.init(self.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            self.proxy_io = io;

            var listener = self.address.listen(io, .{ .kernel_backlog = 128 }) catch |err| {
                log.err("GraphQL 鉴权代理绑定失败: {s}", .{@errorName(err)});
                self.proxy_ready.store(true, .release);
                return;
            };
            self.proxy_listener = listener;
            self.proxy_ok.store(true, .release);
            self.proxy_ready.store(true, .release);

            var http_client: std.http.Client = .{ .allocator = self.allocator, .io = io };
            defer http_client.deinit();
            while (self.proxy_running.load(.acquire)) {
                const stream = listener.accept(io) catch break;
                self.handleProxyClient(io, &http_client, stream);
            }
        }

        fn handleProxyClient(self: *@This(), io: std.Io, http_client: *std.http.Client, stream: std.Io.net.Stream) void {
            defer stream.close(io);
            var read_buf: [65536]u8 = undefined;
            var write_buf: [65536]u8 = undefined;
            var stream_reader = stream.reader(io, &read_buf);
            var stream_writer = stream.writer(io, &write_buf);
            var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

            var request = http_server.receiveHead() catch return;
            const target = request.head.target;
            const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const path = target[0..path_end];
            const method = request.head.method;

            if (method == .OPTIONS) {
                request.respond("", .{
                    .status = .no_content,
                    .extra_headers = &.{
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
                    },
                }) catch {};
                return;
            }
            if (!auth.routeAllowed(self.api_token, false, path, request.head_buffer)) {
                request.respond("{\"error\":\"Unauthorized\"}", .{
                    .status = .unauthorized,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/json" },
                        .{ .name = "WWW-Authenticate", .value = "Bearer" },
                    },
                }) catch {};
                return;
            }
            if (request.upgradeRequested() == .websocket) {
                request.respond("{\"error\":\"api_token is set; WebSocket subscriptions are not forwarded\"}", .{
                    .status = .not_implemented,
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                }) catch {};
                return;
            }

            var body_buf: [4096]u8 = undefined;
            var body_storage: std.ArrayList(u8) = .empty;
            defer body_storage.deinit(self.allocator);
            if ((request.head.content_length orelse 0) > 0) {
                const body_reader = request.server.reader.bodyReader(&body_buf, request.head.transfer_encoding, request.head.content_length);
                var writer = std.Io.Writer.Allocating.init(self.allocator);
                defer writer.deinit();
                _ = body_reader.stream(&writer.writer, std.Io.Limit.limited(1024 * 1024)) catch return;
                body_storage = writer.toArrayList();
            }

            const url = std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ self.internal_port, target }) catch return;
            defer self.allocator.free(url);
            var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer response_writer.deinit();
            const result = http_client.fetch(.{
                .location = .{ .url = url },
                .method = method,
                .payload = if (body_storage.items.len > 0) body_storage.items else null,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                .response_writer = &response_writer.writer,
            }) catch {
                request.respond("{\"error\":\"Bad Gateway\"}", .{
                    .status = .bad_gateway,
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                }) catch {};
                return;
            };
            const content_type: []const u8 = if (std.mem.indexOf(u8, path, "/playground") != null)
                "text/html; charset=utf-8"
            else
                "application/json; charset=utf-8";
            request.respond(response_writer.written(), .{
                .status = result.status,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = content_type },
                    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                },
            }) catch {};
        }
    };

    const wrapper = try alloc.create(ServerWrapper);
    wrapper.* = .{
        .server = server,
        .schema_def = schema_def,
        .allocator = alloc,
        .address = public_addr,
        .enable_playground = cfg.enable_playground,
        .ctx_ptr = ctx_ptr,
        .rate_limiter = rate_limiter,
        .api_token = token_copy,
        .internal_port = internal_port,
        .proxy_running = std.atomic.Value(bool).init(false),
        .proxy_ready = std.atomic.Value(bool).init(false),
        .proxy_ok = std.atomic.Value(bool).init(false),
        .proxy_io = undefined,
        .proxy_listener = null,
        .gate = undefined,
    };
    // Fix: the server's schema_def pointer must point to the heap copy in wrapper,
    // not the stack-local schema_def which goes out of scope when start() returns.
    wrapper.server.schema_def = &wrapper.schema_def;

    const gate = alloc.create(Gate) catch |err| {
        if (rate_limiter) |*rl| rl.deinit();
        alloc.destroy(wrapper);
        return err;
    };
    gate.* = .{
        .server = &wrapper.server,
        .bind = bind_addr,
    };
    wrapper.gate = gate;

    const thread = std.Thread.spawn(.{}, ServerWrapper.run, .{wrapper}) catch |err| {
        if (rate_limiter) |*rl| rl.deinit();
        alloc.destroy(gate);
        alloc.destroy(wrapper);
        return err;
    };
    return .{
        .thread = thread,
        .gate = gate,
        .alloc = alloc,
    };
}

fn getCtx(user_data: ?*anyopaque) *const Context {
    return @ptrCast(@alignCast(user_data.?));
}

fn isValidTableName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn attachResolvers(schema_def: *zg.schema.Schema) void {
    // GraphQL Subscription：实时推送索引器同步到的最新区块号。
    if (schema_def.subscription_type) |sub_type| {
        if (sub_type.kind.object.fields.getPtr("newBlocks")) |field| {
            field.subscribe = struct {
                const StreamCtx = struct {
                    ctx: *const Context,
                    last_block: u64,

                    fn next(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?zg.Value {
                        const s = @as(*StreamCtx, @ptrCast(@alignCast(ptr)));
                        // 轮询各索引器当前区块，取最大值；有新块则推送，
                        // 否则短暂让出后重查（阻塞语义，见 zgraphql consumeSubscription）。
                        while (true) {
                            var max_block: u64 = 0;
                            for (s.ctx.indexers) |idx| {
                                const b = idx.getCurrentBlock();
                                if (b > max_block) max_block = b;
                            }
                            if (max_block > s.last_block) {
                                s.last_block = max_block;
                                return zg.Value.fromInt(alloc, @intCast(max_block));
                            }
                            std.Io.sleep(s.ctx.rpc.io, std.Io.Duration.fromMilliseconds(500), .real) catch {};
                        }
                    }

                    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const s = @as(*StreamCtx, @ptrCast(@alignCast(ptr)));
                        alloc.destroy(s);
                    }
                };

                fn subscribe(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.schema.SubscriptionStream {
                    const c = getCtx(ctx);
                    const s = try alloc.create(StreamCtx);
                    s.* = .{ .ctx = c, .last_block = 0 };
                    return zg.schema.SubscriptionStream{
                        .ptr = s,
                        .vtable = &.{
                            .next = StreamCtx.next,
                            .deinit = StreamCtx.deinit,
                        },
                    };
                }
            }.subscribe;
        }
    }

    if (schema_def.query_type.kind.object.fields.getPtr("health")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                _ = ctx;
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "ok"));
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("version")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                _ = ctx;
                const version_str = try std.fmt.allocPrint(alloc, "{s} ({s})", .{ build_options.version, build_options.git_commit });
                return zg.Value.fromString(alloc, version_str);
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("contracts")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                const c = getCtx(ctx);
                var list = zg.Value.initList(alloc);
                errdefer list.deinit(alloc);

                for (c.indexers) |idx| {
                    var obj = zg.Value.initObject(alloc);
                    try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, idx.contract.name)));
                    try obj.data.object.put(try alloc.dupe(u8, "address"), zg.Value.fromString(alloc, try alloc.dupe(u8, idx.contract.address)));
                    try obj.data.object.put(try alloc.dupe(u8, "chain"), zg.Value.fromString(alloc, try alloc.dupe(u8, c.chain)));
                    try obj.data.object.put(try alloc.dupe(u8, "fromBlock"), zg.Value.fromInt(alloc, @intCast(idx.contract.from_block)));
                    var event_list = zg.Value.initList(alloc);
                    for (idx.contract.events) |evt| {
                        try event_list.data.list.append(zg.Value.fromString(alloc, try alloc.dupe(u8, evt)));
                    }
                    try obj.data.object.put(try alloc.dupe(u8, "events"), event_list);
                    try list.data.list.append(obj);
                }
                return list;
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("contract")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                const c = getCtx(ctx);
                const name_val = args.get("name") orelse return zg.Value.fromNull(alloc);
                const target_name = name_val.data.string;

                for (c.indexers) |idx| {
                    if (std.mem.eql(u8, idx.contract.name, target_name)) {
                        var obj = zg.Value.initObject(alloc);
                        try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, idx.contract.name)));
                        try obj.data.object.put(try alloc.dupe(u8, "address"), zg.Value.fromString(alloc, try alloc.dupe(u8, idx.contract.address)));
                        try obj.data.object.put(try alloc.dupe(u8, "chain"), zg.Value.fromString(alloc, try alloc.dupe(u8, c.chain)));
                        try obj.data.object.put(try alloc.dupe(u8, "fromBlock"), zg.Value.fromInt(alloc, @intCast(idx.contract.from_block)));
                        var event_list = zg.Value.initList(alloc);
                        for (idx.contract.events) |evt| {
                            try event_list.data.list.append(zg.Value.fromString(alloc, try alloc.dupe(u8, evt)));
                        }
                        try obj.data.object.put(try alloc.dupe(u8, "events"), event_list);
                        return obj;
                    }
                }
                return zg.Value.fromNull(alloc);
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("syncStates")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                const c = getCtx(ctx);
                var list = zg.Value.initList(alloc);
                errdefer list.deinit(alloc);

                for (c.indexers) |idx| {
                    var obj = zg.Value.initObject(alloc);
                    try obj.data.object.put(try alloc.dupe(u8, "contractName"), zg.Value.fromString(alloc, try alloc.dupe(u8, idx.contract.name)));
                    try obj.data.object.put(try alloc.dupe(u8, "currentBlock"), zg.Value.fromInt(alloc, @intCast(idx.getCurrentBlock())));
                    const status_str: []const u8 = switch (idx.getStatus()) {
                        .running => "RUNNING",
                        .stopped => "STOPPED",
                        .error_state => "ERROR",
                        .replaying => "REPLAYING",
                    };
                    try obj.data.object.put(try alloc.dupe(u8, "status"), zg.Value.fromString(alloc, try alloc.dupe(u8, status_str)));
                    try list.data.list.append(obj);
                }
                return list;
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("latestEvents")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                const c = getCtx(ctx);
                const contract_name = (args.get("contract") orelse return zg.Value.fromNull(alloc)).data.string;
                const event_name = (args.get("event") orelse return zg.Value.fromNull(alloc)).data.string;

                if (!isValidTableName(contract_name) or !isValidTableName(event_name)) {
                    log.warn("非法的合约名或事件名被拒绝: '{s}' / '{s}'", .{ contract_name, event_name });
                    return zg.Value.fromNull(alloc);
                }

                const limit: u32 = if (args.get("limit")) |lv| @intCast(@max(1, @min(lv.data.int, 1000))) else 10;
                // offset 加上限防 @intCast(i64→u32) 溢出 panic（limit 已有 @min 保护）
                const offset: u32 = if (args.get("offset")) |ov| @intCast(@max(0, @min(ov.data.int, 1_000_000_000))) else 0;
                const block_from: ?u64 = if (args.get("blockFrom")) |bf| @intCast(@max(0, bf.data.int)) else null;
                const block_to: ?u64 = if (args.get("blockTo")) |bt| @intCast(@max(0, bt.data.int)) else null;
                // address 过滤：非字符串值视为未提供（空串是合法地址，模板索引器行即以 "" 出现）
                const address: ?[]const u8 = if (args.get("address")) |av| (if (av.data == .string) av.data.string else null) else null;

                const json_str = try c.database.queryEventLogs(contract_name, event_name, block_from, block_to, null, address, limit, offset, true);
                defer alloc.free(json_str);

                const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
                defer parsed.deinit();

                var list = zg.Value.initList(alloc);
                errdefer list.deinit(alloc);

                if (parsed.value == .array) {
                    for (parsed.value.array.items) |row| {
                        if (row != .object) continue;

                        var obj = zg.Value.initObject(alloc);

                        if (row.object.get("block_number")) |bn| {
                            const bn_int: i64 = switch (bn) {
                                .integer => |i| i,
                                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                                else => 0,
                            };
                            try obj.data.object.put(try alloc.dupe(u8, "blockNumber"), zg.Value.fromInt(alloc, bn_int));
                        }

                        if (row.object.get("tx_hash") orelse row.object.get("transaction_hash")) |txh| {
                            if (txh == .string) {
                                try obj.data.object.put(try alloc.dupe(u8, "transactionHash"), zg.Value.fromString(alloc, try alloc.dupe(u8, txh.string)));
                            }
                        }

                        try obj.data.object.put(try alloc.dupe(u8, "eventName"), zg.Value.fromString(alloc, try alloc.dupe(u8, event_name)));

                        const ca = if (row.object.get("contract_address")) |v| (if (v == .string) v.string else "") else "";
                        try obj.data.object.put(try alloc.dupe(u8, "contractAddress"), zg.Value.fromString(alloc, try alloc.dupe(u8, ca)));

                        var fields = zg.Value.initList(alloc);
                        var iter = row.object.iterator();
                        while (iter.next()) |entry| {
                            var field_obj = zg.Value.initObject(alloc);
                            try field_obj.data.object.put(try alloc.dupe(u8, "key"), zg.Value.fromString(alloc, try alloc.dupe(u8, entry.key_ptr.*)));
                            const val_str = switch (entry.value_ptr.*) {
                                .null => try alloc.dupe(u8, "null"),
                                .bool => |b| try alloc.dupe(u8, if (b) "true" else "false"),
                                .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
                                .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
                                .number_string => |s| try alloc.dupe(u8, s),
                                .string => |s| try alloc.dupe(u8, s),
                                else => try alloc.dupe(u8, ""),
                            };
                            try field_obj.data.object.put(try alloc.dupe(u8, "value"), zg.Value.fromString(alloc, val_str));
                            try fields.data.list.append(field_obj);
                        }
                        try obj.data.object.put(try alloc.dupe(u8, "fields"), fields);
                        try list.data.list.append(obj);
                    }
                }

                return list;
            }
        }.resolve;
    }

    if (schema_def.query_type.kind.object.fields.getPtr("contractCall")) |field| {
        field.resolve = struct {
            fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                const c = getCtx(ctx);
                const contract_name = (args.get("contract") orelse return zg.Value.fromNull(alloc)).data.string;
                const method = (args.get("method") orelse return zg.Value.fromNull(alloc)).data.string;

                // Validate method signature: alphanumeric + parens + commas
                if (!isValidMethodSignature(method)) {
                    return zg.Value.fromNull(alloc);
                }

                // Find the contract's address + indexer (for ABI return-type lookup)
                var contract_idx: ?*indexer.Indexer = null;
                var contract_addr: ?[]const u8 = null;
                for (c.indexers) |idx| {
                    if (std.mem.eql(u8, idx.contract.name, contract_name)) {
                        contract_idx = idx;
                        contract_addr = idx.contract.address;
                        break;
                    }
                }
                const to = contract_addr orelse return zg.Value.fromNull(alloc);

                // Build arg list — count first, then alloc
                var arg_count: usize = 0;
                if (args.get("args")) |raw_args| {
                    if (raw_args.data == .list) {
                        arg_count = raw_args.data.list.items.len;
                    }
                }
                var call_args_list = try alloc.alloc([]const u8, arg_count);
                defer alloc.free(call_args_list);
                var call_arg_idx: usize = 0;
                if (args.get("args")) |raw_args| {
                    if (raw_args.data == .list) {
                        for (raw_args.data.list.items) |item| {
                            if (item.data == .string) {
                                call_args_list[call_arg_idx] = item.data.string;
                                call_arg_idx += 1;
                            }
                        }
                    }
                }
                const call_args = call_args_list[0..call_arg_idx];

                const block_number: ?u64 = if (args.get("blockNumber")) |bn| @intCast(@max(0, bn.data.int)) else null;

                // Encode function call
                const data = try abi.encodeFunctionCall(alloc, method, call_args);
                defer alloc.free(data);

                // Check call cache
                const cache_key = try std.fmt.allocPrint(alloc, "{s}:{s}:{?d}", .{ to, data, block_number });
                defer alloc.free(cache_key);

                if (try c.database.getCachedCall(cache_key)) |cached| {
                    defer alloc.free(cached);
                    return zg.Value.fromString(alloc, cached);
                }

                // Execute eth_call
                const result_hex = c.rpc.ethCall(to, data, block_number) catch |err| {
                    log.warn("eth_call 失败 {s}.{s}: {s}", .{ contract_name, method, @errorName(err) });
                    return zg.Value.fromNull(alloc);
                };
                defer alloc.free(result_hex);

                // Decode result: look up the real return type from the contract ABI
                // (fallback to "uint256" for unknown/constructor-style signatures).
                const paren = std.mem.indexOfScalar(u8, method, '(') orelse method.len;
                const method_name = method[0..paren];
                const fn_def = if (contract_idx) |idx|
                    if (idx.abi_contract) |*ac| ac.findFunctionByName(method_name) else null
                else
                    null;
                // 多个返回值拼成最外层元组，直接展开。单个动态结构体先读偏移。
                const decoded = decoded: {
                    const f = fn_def orelse break :decoded try abi.decodeCallResult(alloc, "uint256", result_hex);
                    if (f.outputs.len <= 1) {
                        const t = f.returnType(alloc) orelse "uint256";
                        break :decoded try abi.decodeSingleOutput(alloc, t, result_hex);
                    }
                    const t = f.returnType(alloc) orelse "uint256";
                    defer alloc.free(t);
                    break :decoded try abi.decodeCallResult(alloc, t, result_hex);
                };
                defer alloc.free(decoded);

                // Cache result
                const bn: u64 = block_number orelse 0;
                c.database.setCachedCall(cache_key, decoded, bn) catch |e| {
                    log.warn("缓存 eth_call 结果失败: {s}", .{@errorName(e)});
                };

                return zg.Value.fromString(alloc, try alloc.dupe(u8, decoded));
            }
        }.resolve;
    }
}

fn isValidMethodSignature(sig: []const u8) bool {
    if (sig.len == 0 or sig.len > 256) return false;
    for (sig) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '(' and c != ')' and c != ',') return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "graphql: 纯函数校验逻辑" {
    // isValidTableName — 仅允许字母数字与下划线
    try std.testing.expect(isValidTableName("usdc_transfer"));
    try std.testing.expect(isValidTableName("a"));
    try std.testing.expect(!isValidTableName(""));
    try std.testing.expect(!isValidTableName("usdc;drop"));
    try std.testing.expect(!isValidTableName("usdc-table"));
    try std.testing.expect(!isValidTableName("usdc transfer"));

    // isValidMethodSignature — 仅允许字母数字、下划线、括号与逗号
    try std.testing.expect(isValidMethodSignature("balanceOf(address)"));
    try std.testing.expect(isValidMethodSignature("transfer(address,uint256)"));
    try std.testing.expect(!isValidMethodSignature(""));
    try std.testing.expect(!isValidMethodSignature("balanceOf(address); DROP TABLE x"));
    try std.testing.expect(!isValidMethodSignature("balanceOf(address) OR 1=1"));
}

test "graphql: schema 构建与 resolver 挂载" {
    const alloc = std.testing.allocator;
    var schema_def = try Builder.init(alloc);
    defer schema_def.deinit();

    attachResolvers(&schema_def);

    const query_fields = schema_def.query_type.kind.object.fields;
    const query_names = [_][]const u8{ "health", "version", "contracts", "contract", "syncStates", "latestEvents", "contractCall" };
    for (query_names) |name| {
        const field = query_fields.get(name) orelse return error.GraphQLQueryFieldMissing;
        // 每个 Query 字段都必须挂载 resolver，否则运行时返回 "Cannot return null"
        try std.testing.expect(field.resolve != null);
    }

    // Subscription 根类型 + newBlocks subscribe 挂载
    const sub_type = schema_def.subscription_type orelse return error.GraphQLSubscriptionTypeMissing;
    const new_blocks = sub_type.kind.object.fields.get("newBlocks") orelse return error.GraphQLSubscriptionFieldMissing;
    try std.testing.expect(new_blocks.subscribe != null);
}

test "graphql latestEvents 暴露 contractAddress 与 address 参数" {
    const alloc = std.testing.allocator;
    var schema_def = try Builder.init(alloc);
    defer schema_def.deinit();
    attachResolvers(&schema_def);

    const le = schema_def.query_type.kind.object.fields.getPtr("latestEvents") orelse return error.MissingLatestEvents;
    try std.testing.expect(le.arguments.get("address") != null); // 新增参数
    const ev = schema_def.types.get("Event") orelse return error.MissingEventType;
    try std.testing.expect(ev.kind.object.fields.get("contractAddress") != null);
}

test "graphql: latestEvents address 参数落到数据库过滤并填充 contractAddress" {
    const alloc = std.testing.allocator;

    const cfg = db.DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try db.Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    const evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{.{ .name = "value", .type = "uint256", .indexed = false }}, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"}, "");
    const fields = [_]db.DecodedField{.{ .name = "value", .value = "7" }};
    _ = try client.insertEventLog("curve", "Transfer", &fields, 10, "0xt1", 0, "0xA");
    _ = try client.insertEventLog("curve", "Transfer", &fields, 11, "0xt2", 0, "0xB");

    var schema_def = try Builder.init(alloc);
    defer schema_def.deinit();
    attachResolvers(&schema_def);

    var shutdown = std.atomic.Value(bool).init(false);
    const ctx = Context{
        .database = &client,
        .indexers = &.{},
        .chain = "bsc",
        .shutdown_flag = &shutdown,
        .rpc = undefined,
    };

    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    var parser = try zg.Parser.init(alloc, "{ latestEvents(contract: \"curve\", event: \"Transfer\", address: \"0xB\") { blockNumber contractAddress eventName } }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var executor = zg.Executor.init(alloc, &schema_def, io);
    defer executor.deinit();
    executor.setUserData(@constCast(@ptrCast(&ctx)));
    var result = try executor.execute(&doc);
    defer result.deinit(alloc);

    const json_str = try result.toJson(alloc);
    defer alloc.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"contractAddress\":\"0xB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "0xA") == null);
}

test "graphql: 端到端执行（zgraphql v0.4.0）" {
    const alloc = std.testing.allocator;

    var schema_def = try Builder.init(alloc);
    defer schema_def.deinit();
    attachResolvers(&schema_def);

    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    // 1) 正常查询：health + version resolver 真实执行（解析→验证→执行→JSON）
    {
        var parser = try zg.Parser.init(alloc, "{ health version }");
        defer parser.deinit();
        var doc = try parser.parseDocument();
        defer doc.deinit();

        var validator = zg.Validator.init(alloc, &schema_def);
        defer validator.deinit();
        // 注意：ValidationResult 为浅拷贝，借用 validator 内部状态，
        // 必须在 validator.deinit() 之前消费（此处仅立即读取 isValid）。
        const vresult = try validator.validate(&doc);
        try std.testing.expect(vresult.isValid());

        var executor = zg.Executor.init(alloc, &schema_def, io);
        defer executor.deinit();
        var result = try executor.execute(&doc);
        defer result.deinit(alloc);

        const json_str = try result.toJson(alloc);
        defer alloc.free(json_str);
        try std.testing.expect(std.mem.indexOf(u8, json_str, "\"health\":\"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json_str, "\"version\"") != null);
    }

    // 2) 验证错误：未知字段被 validator 拒绝（0.4.0 验证路径）
    {
        var parser = try zg.Parser.init(alloc, "{ unknownField }");
        defer parser.deinit();
        var doc = try parser.parseDocument();
        defer doc.deinit();

        var validator = zg.Validator.init(alloc, &schema_def);
        defer validator.deinit();
        // 注意：ValidationResult 为浅拷贝，借用 validator 内部状态，
        // 必须在 validator.deinit() 之前消费（此处仅立即读取 isValid）。
        const vresult = try validator.validate(&doc);
        try std.testing.expect(!vresult.isValid());
    }
}

test "graphql internal port 与对外端口错开" {
    try std.testing.expectEqual(@as(u16, 28081), internalGraphqlPort(8081));
    try std.testing.expect(internalGraphqlPort(8081) != 8081);
    try std.testing.expectEqual(@as(u16, 30000), internalGraphqlPort(50000));
}

test "graphql stop 能从堵住的 accept 返回" {
    const alloc = std.testing.allocator;
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    const probe_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var probe = try probe_addr.listen(io, .{});
    const port = probe.socket.address.getPort();
    probe.deinit(io);

    const cfg = db.DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 2,
    };
    var database = try db.Client.init(alloc, &cfg);
    defer database.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    const gql_cfg = config.GraphQLConfig{
        .enabled = true,
        .host = "127.0.0.1",
        .port = port,
        .enable_playground = false,
        .max_query_depth = 8,
        .max_query_complexity = 100,
        .rate_limit_rps = null,
        .rate_limit_burst = null,
    };
    var svc = try start(alloc, &gql_cfg, .{
        .database = &database,
        .indexers = &.{},
        .chain = "bsc",
        .shutdown_flag = &shutdown,
        .rpc = undefined,
    }, "");
    var stopped = false;
    defer if (!stopped) svc.stop(io);

    var up = false;
    var wait: u32 = 0;
    while (wait < 50) : (wait += 1) {
        if (svc.poke(io)) {
            up = true;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    try std.testing.expect(up);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const started = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    svc.stop(io);
    stopped = true;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const elapsed = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000) - started;
    try std.testing.expect(elapsed < 2000);
}
