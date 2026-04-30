const std = @import("std");
const config = @import("config.zig");
const eth_rpc = @import("eth_rpc.zig");
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

/// 核心索引器
pub const Indexer = struct {
    alloc: std.mem.Allocator,
    rpc: *eth_rpc.Client,
    database: *db.Client,
    contract: *const config.ContractConfig,
    snapshot_interval: u64,
    state: std.atomic.Value(IndexerState),
    current_block: std.atomic.Value(u64),
    last_snapshot_time: std.atomic.Value(i64),
    batch_size: u64,
    poll_interval_ms: u32,
    abi_contract: ?abi.AbiContract,
    thread: ?std.Thread,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        rpc: *eth_rpc.Client,
        database: *db.Client,
        contract: *const config.ContractConfig,
        snapshot_interval: u64,
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
            database.autoMigrateContract(contract.name, ac, contract.events) catch |e| {
                log.err("合约 {s} 自动迁移失败: {any}", .{ contract.name, e });
            };
            log.info("合约 {s} 事件表已创建/检查", .{contract.name});
        }

        // 从数据库读取断点
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
            .last_snapshot_time = std.atomic.Value(i64).init(0),
            .batch_size = batch_size,
            .poll_interval_ms = poll_interval_ms,
            .abi_contract = abi_contract,
            .thread = null,
        };
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

            const current = self.current_block.load(.monotonic);
            if (current >= latest_block) {
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
                log.err("同步区块 {}~{} 失败: {any}", .{ current, to_block, e });
                std.Io.sleep(self.rpc.io, std.Io.Duration.fromMilliseconds(self.poll_interval_ms), .real) catch {};
                continue;
            };

            // 记录本批次最后一个区块的 hash（用于下次重组检测）
            if (self.rpc.getBlockHash(to_block)) |hash| {
                defer if (hash) |h| self.alloc.free(h);
                if (hash) |h| {
                    self.database.upsertBlockHash(self.contract.address, to_block, h) catch |e| {
                        log.warn("记录区块 hash 失败: {any}", .{e});
                    };
                }
            } else |e| {
                log.warn("获取区块 {d} hash 失败: {any}", .{ to_block, e });
            }

            self.current_block.store(to_block + 1, .monotonic);

            self.database.upsertSyncState(.{
                .contract_address = self.contract.address,
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
            .contract_address = self.contract.address,
            .last_synced_block = self.current_block.load(.monotonic),
            .status = "stopped",
        }) catch |db_err| {
            log.warn("索引器停止时更新同步状态失败: {any}", .{db_err});
        };

        log.info("索引器已停止: {s}", .{self.contract.name});
    }

    /// 同步指定区块范围
    fn syncRange(self: *Indexer, from_block: u64, to_block: u64) !void {
        // 构建事件 topic0 过滤
        var topics: std.ArrayList([]const u8) = .empty;
        defer topics.deinit(self.alloc);

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

        const filter = eth_rpc.LogFilter{
            .address = self.contract.address,
            .topics = if (topics.items.len > 0) topics.items else null,
            .from_block = from_block,
            .to_block = to_block,
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
                    self.contract.address,
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

    /// 处理单条日志：解码并写入对应事件表
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

                    try self.database.insertEventLog(
                        self.contract.name,
                        evt.name,
                        db_fields.items,
                        lg.block_number,
                        lg.transaction_hash,
                        lg.log_index,
                    );

                    log.debug("已写入 {s}.{s} @ 区块 {}", .{ self.contract.name, evt.name, lg.block_number });
                    return;
                }
            }
        }

        // ABI 无法解析：返回错误让调用方记录，避免静默丢弃
        return error.AbiMismatch;
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
            .{ current - 1, now, self.contract.address, self.contract.name },
        ) catch |e| {
            log.warn("快照 JSON 构建失败: {any}", .{e});
            snap_buf.deinit(self.alloc);
            return;
        };
        defer snap_buf.deinit(self.alloc);

        try self.database.createSnapshot(.{
            .contract_address = self.contract.address,
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
            try buf.appendSlice(alloc, t);
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
        const local_hash = self.database.getBlockHash(self.contract.address, block_number) catch |e| {
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

            const scan_local = self.database.getBlockHash(self.contract.address, scan_block) catch continue;
            defer if (scan_local) |h| self.alloc.free(h);
            if (scan_local == null) continue;

            if (std.mem.eql(u8, scan_rpc.?, scan_local.?)) {
                // 找到匹配点，fork_point = scan_block + 1
                const fork_point = scan_block + 1;
                log.warn("找到分叉点 @ 区块 {d}，回滚到 {d}", .{ scan_block, fork_point });
                self.database.rollbackFromBlock(
                    self.contract.address,
                    self.contract.name,
                    self.contract.events,
                    fork_point,
                ) catch |e| {
                    log.err("回滚数据失败: {any}", .{e});
                };
                return fork_point;
            }
        }

        // 在 safe_depth 内未找到匹配点，回滚到 safe_depth 之前
        const safe_block = min_block;
        log.warn("在 safe_depth({d}) 内未找到匹配点，回滚到 {d}", .{ reorg_depth, safe_block });
        self.database.rollbackFromBlock(
            self.contract.address,
            self.contract.name,
            self.contract.events,
            safe_block,
        ) catch |e| {
            log.err("回滚数据失败: {any}", .{e});
        };
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
    };

    var idx = Indexer{
        .alloc = alloc,
        .rpc = &rpc,
        .database = &database,
        .contract = &contract,
        .snapshot_interval = 0,
        .state = std.atomic.Value(IndexerState).init(.stopped),
        .current_block = std.atomic.Value(u64).init(100),
        .last_snapshot_time = std.atomic.Value(i64).init(0),
        .batch_size = 100,
        .poll_interval_ms = 1000,
        .abi_contract = null,
        .thread = null,
    };

    try std.testing.expectEqual(IndexerState.stopped, idx.getStatus());
    try std.testing.expectEqual(@as(u64, 100), idx.getCurrentBlock());

    idx.state.store(.running, .monotonic);
    try std.testing.expectEqual(IndexerState.running, idx.getStatus());

    idx.current_block.store(200, .monotonic);
    try std.testing.expectEqual(@as(u64, 200), idx.getCurrentBlock());
}
