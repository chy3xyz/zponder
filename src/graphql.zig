const std = @import("std");
const zg = @import("zgraphql");
const config = @import("config.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const eth_rpc = @import("eth_rpc.zig");
const abi = @import("abi.zig");
const build_options = @import("build_options");

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
        .fields = .{ .type = "[EventField!]!" },
    },
    .EventField = .{
        .key = .{ .type = "String!" },
        .value = .{ .type = "String!" },
    },
});

pub fn start(alloc: std.mem.Allocator, cfg: *const config.GraphQLConfig, ctx: Context) !std.Thread {
    if (!cfg.enabled) {
        log.info("GraphQL 服务未启用", .{});
        return error.GraphQLDisabled;
    }

    var schema_def = try Builder.init(alloc);
    errdefer schema_def.deinit();

    attachResolvers(&schema_def);

    const addr = try std.Io.net.IpAddress.parseIp4(cfg.host, cfg.port);

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
        .bind_address = addr,
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

        fn run(self: *@This()) void {
            defer {
                self.ctx_ptr.shutdown_flag.store(true, .release);
                self.schema_def.deinit();
                if (self.rate_limiter) |*rl| rl.deinit();
                self.allocator.destroy(self.ctx_ptr);
                self.allocator.destroy(self);
            }

            const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
            var backend = IoBackend.init(self.allocator, .{});
            defer backend.deinit();
            const backend_io = backend.io();

            log.info("GraphQL 服务已启动: http://{f}/graphql", .{self.address});
            if (self.enable_playground) {
                log.info("GraphQL Playground: http://{f}/graphql/playground", .{self.address});
            }

            self.server.listen(backend_io) catch |err| {
                log.err("GraphQL 服务异常退出: {s}", .{@errorName(err)});
            };
        }
    };

    const wrapper = try alloc.create(ServerWrapper);
    wrapper.* = .{
        .server = server,
        .schema_def = schema_def,
        .allocator = alloc,
        .address = addr,
        .enable_playground = cfg.enable_playground,
        .ctx_ptr = ctx_ptr,
        .rate_limiter = rate_limiter,
    };
    // Fix: the server's schema_def pointer must point to the heap copy in wrapper,
    // not the stack-local schema_def which goes out of scope when start() returns.
    wrapper.server.schema_def = &wrapper.schema_def;

    const thread = std.Thread.spawn(.{}, ServerWrapper.run, .{wrapper}) catch |err| {
        if (rate_limiter) |*rl| rl.deinit();
        alloc.destroy(wrapper);
        return err;
    };
    return thread;
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
                errdefer list.deinit();

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
                errdefer list.deinit();

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
                const offset: u32 = if (args.get("offset")) |ov| @intCast(@max(0, ov.data.int)) else 0;
                const block_from: ?u64 = if (args.get("blockFrom")) |bf| @intCast(@max(0, bf.data.int)) else null;
                const block_to: ?u64 = if (args.get("blockTo")) |bt| @intCast(@max(0, bt.data.int)) else null;

                const json_str = try c.database.queryEventLogs(contract_name, event_name, block_from, block_to, null, limit, offset, true);
                defer alloc.free(json_str);

                const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
                defer parsed.deinit();

                var list = zg.Value.initList(alloc);
                errdefer list.deinit();

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

                // Find the contract's address
                var contract_addr: ?[]const u8 = null;
                for (c.indexers) |idx| {
                    if (std.mem.eql(u8, idx.contract.name, contract_name)) {
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

                // Decode result: extract return type from method signature
                const return_type = extractReturnType(method);
                const decoded = try abi.decodeCallResult(alloc, return_type, result_hex);
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

fn extractReturnType(method: []const u8) []const u8 {
    _ = method;
    // Simplified: return types are not part of the selector.
    // Default to "uint256" for numeric methods, "bytes32" otherwise.
    return "uint256";
}
