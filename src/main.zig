const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const log = @import("log.zig");
const eth_rpc = @import("eth_rpc.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const http_server = @import("http_server.zig");
const cache = @import("cache.zig");
const etherscan = @import("etherscan.zig");
const abi = @import("abi.zig");

var g_running = std.atomic.Value(bool).init(true);

const c_signal = @cImport({
    @cInclude("signal.h");
});

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_running.store(false, .monotonic);
}

fn setupSignals() void {
    var sa: c_signal.struct_sigaction = undefined;
    if (@import("builtin").os.tag.isDarwin()) {
        sa.__sigaction_u.__sa_handler = signalHandler;
    } else {
        sa.sa_handler = signalHandler;
    }
    _ = c_signal.sigemptyset(&sa.sa_mask);
    sa.sa_flags = c_signal.SA_RESTART;
    _ = c_signal.sigaction(c_signal.SIGINT, &sa, null);
    _ = c_signal.sigaction(c_signal.SIGTERM, &sa, null);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    setupSignals();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    var config_path: []const u8 = "./config.toml";

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (std.mem.eql(u8, args[arg_idx], "init")) {
            try cmdInit(alloc, init.io);
            return;
        }
        if (std.mem.eql(u8, args[arg_idx], "-h") or std.mem.eql(u8, args[arg_idx], "--help")) {
            const help =
                \\zponder — Zig 以太坊事件索引器
                \\
                \\用法:
                \\  zponder init                 交互式配置向导
                \\  zponder [选项]               启动索引器
                \\
                \\选项:
                \\  -c, --config <路径>          配置文件路径 (默认: ./config.toml)
                \\  -h, --help                   显示此帮助信息
                \\
                \\最小配置示例 (config.toml):
                \\  [global]
                \\  etherscan_api_key = "YOUR_KEY"
                \\
                \\  [rpc]
                \\  url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
                \\
                \\  [database]
                \\  type = "sqlite"
                \\
                \\  [[contracts]]
                \\  name = "dai"
                \\  address = "0x6b175474e89094c44da98b954eedeac495271d0f"
                \\  # abi_path 留空 → 从 Etherscan 自动获取
                \\  # events 留空 → 索引所有 ABI 事件
                \\
            ;
            std.Io.File.stdout().writeStreamingAll(init.io, help) catch {};
            return;
        }
        if (std.mem.eql(u8, args[arg_idx], "-c") or std.mem.eql(u8, args[arg_idx], "--config")) {
            if (arg_idx + 1 < args.len) {
                config_path = args[arg_idx + 1];
                arg_idx += 1;
            }
        }
    }

    // 1. 加载配置
    var cfg = try config.load(alloc, init.io, config_path);
    defer cfg.deinit(alloc);

    // 2. 初始化日志
    try log.init(alloc, init.io, cfg.global.log_level, if (cfg.global.log_file.len > 0) cfg.global.log_file else null);
    defer log.deinit(alloc, init.io);

    log.info("🚀 启动 zponder v{s} ({s})", .{ build_options.version, build_options.git_commit });
    log.info("RPC: {s}, 数据库: {s}", .{ cfg.rpc.url, cfg.database.db_type });

    // 3. 自动获取 ABI + 自动发现事件
    const resolved = try resolveEvents(alloc, init.io, &cfg);
    // ABI auto-fetch is done inside resolveEvents if needed

    // 4. 初始化查询缓存
    var query_cache = cache.Cache.init(alloc, 1000, 64 * 1024 * 1024);
    defer query_cache.deinit();
    log.info("查询缓存已初始化", .{});

    // 5. 初始化数据库
    var database = try db.Client.init(alloc, &cfg.database);
    defer database.deinit();
    database.setCache(&query_cache);
    try database.migrate();
    log.info("数据库初始化完成", .{});

    // 6. RPC 客户端
    var rpc = eth_rpc.Client.init(alloc, init.io, &cfg.rpc);
    defer rpc.deinit();
    log.info("RPC 客户端已初始化", .{});

    const latest_block = rpc.getBlockNumber() catch |e| blk: {
        log.warn("RPC 连接测试失败: {any}，继续启动", .{e});
        break :blk 0;
    };
    if (latest_block > 0) log.info("RPC 连接成功，最新区块: {d}", .{latest_block});

    // 7. 初始化索引器
    var indexers: std.ArrayList(indexer.Indexer) = .empty;
    defer {
        for (indexers.items) |*idx| idx.deinit();
        indexers.deinit(alloc);
    }
    var indexer_ptrs: std.ArrayList(*indexer.Indexer) = .empty;
    defer indexer_ptrs.deinit(alloc);

    for (cfg.contracts, 0..) |_, i| {
        const idx = try indexer.Indexer.init(
            alloc, init.io, &rpc, &database,
            &resolved.contracts[i], cfg.global.snapshot_interval,
        );
        try indexers.append(alloc, idx);
        log.info("索引器: {s} ({s}) 起始={d} 事件={d}", .{
            resolved.contracts[i].name,
            resolved.contracts[i].address,
            resolved.contracts[i].from_block,
            resolved.contracts[i].events.len,
        });
    }
    for (indexers.items) |*idx| try indexer_ptrs.append(alloc, idx);

    // 8. 启动
    for (indexers.items) |*idx| try idx.start();

    var server = http_server.Server.init(alloc, init.io, &cfg.http, &database, &query_cache, indexer_ptrs.items, cfg.queries);
    defer server.deinit();
    try server.start();

    log.info("所有模块已启动，索引器运行中...", .{});

    while (g_running.load(.monotonic)) {
        std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), .real) catch {};
    }

    log.info("收到终止信号，开始优雅退出...", .{});
    server.stop();
    for (indexers.items) |*idx| idx.stop();
    log.info("优雅退出完成", .{});
}

// ============================================================================
// init — 交互式配置向导
// ============================================================================
fn cmdInit(alloc: std.mem.Allocator, io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();

    const prompt =
        \\╔══════════════════════════════════════════╗
        \\║      zponder 交互式配置向导              ║
        \\╚══════════════════════════════════════════╝
        \\
        \\按提示输入，直接回车使用默认值。
        \\
    ;
    stdout.writeStreamingAll(io, prompt) catch {};

    // Chain
    try stdout.writeStreamingAll(io,
        \\1. 区块链:
        \\   ethereum | bsc | polygon
        \\
    );
    const chain_str = try readLine(alloc, io, stdin, "ethereum");
    defer alloc.free(chain_str);
    const chain = etherscan.Chain.fromString(chain_str) orelse etherscan.Chain.ethereum;

    // Show known contracts for this chain
    const known = chain.knownContracts();
    if (known.len > 0) {
        try stdout.writeStreamingAll(io, "   知名合约 (可直接输入地址):\n");
        for (known) |kc| {
            var line_buf: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "     {s}: {s}\n", .{ kc.name, kc.address });
            try stdout.writeStreamingAll(io, line);
        }
    }

    // RPC URL
    try stdout.writeStreamingAll(io, "\n2. RPC URL:\n   ");
    const rpc_url = try readLine(alloc, io, stdin, chain.defaultRpc());
    defer alloc.free(rpc_url);

    // Explorer API key
    const explorer_name = switch (chain) {
        .ethereum => "Etherscan",
        .bsc => "BscScan",
        .polygon => "PolygonScan",
    };
    {
        var prompt_buf: [128]u8 = undefined;
        const p = try std.fmt.bufPrint(&prompt_buf, "3. {s} API Key (用于自动获取 ABI):\n   ", .{explorer_name});
        try stdout.writeStreamingAll(io, p);
    }
    const explorer_key = try readLine(alloc, io, stdin, "");
    defer alloc.free(explorer_key);

    // Contract address
    try stdout.writeStreamingAll(io, "4. 合约地址:\n   ");
    const default_addr = if (known.len > 0) known[0].address else "0x...";
    const contract_addr = try readLine(alloc, io, stdin, default_addr);
    defer alloc.free(contract_addr);

    // Contract name
    try stdout.writeStreamingAll(io, "5. 合约名称 (用于表名前缀):\n   ");
    const default_name = if (known.len > 0) known[0].name else "contract";
    const contract_name = try readLine(alloc, io, stdin, default_name);
    defer alloc.free(contract_name);

    // Events
    try stdout.writeStreamingAll(io, "6. 监听事件 (逗号分隔, * 表示全部):\n   ");
    const events_str = try readLine(alloc, io, stdin, "*");
    defer alloc.free(events_str);

    // Database
    try stdout.writeStreamingAll(io, "7. 数据库类型 (sqlite / rocksdb / postgresql):\n   ");
    const db_type = try readLine(alloc, io, stdin, "sqlite");
    defer alloc.free(db_type);

    // From block
    try stdout.writeStreamingAll(io, "8. 起始区块 (0 = 从头开始):\n   ");
    const from_block_str = try readLine(alloc, io, stdin, "0");
    defer alloc.free(from_block_str);

    // Write config.toml
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    try buf.writer.print(
        \\# zponder 配置 — 由 `zponder init` 生成 ({s})
        \\
        \\[global]
        \\log_level = "info"
        \\log_file = "./logs/indexer.log"
        \\snapshot_interval = 3600
        \\etherscan_api_key = "{s}"
        \\chain = "{s}"
        \\
        \\[rpc]
        \\url = "{s}"
        \\timeout = 10000
        \\retry_count = 3
        \\
        \\[database]
        \\type = "{s}"
        \\db_name = "{s}_indexer.db"
        \\
        \\[http]
        \\port = 8080
        \\host = "0.0.0.0"
        \\
        \\[[contracts]]
        \\name = "{s}"
        \\address = "{s}"
        \\from_block = {s}
        \\events = [{s}]
        \\
    , .{
        chain.name(),
        explorer_key,
        chain_str,
        rpc_url,
        db_type,
        chain_str,
        contract_name,
        contract_addr,
        from_block_str,
        if (std.mem.eql(u8, events_str, "*")) "" else events_str,
    });

    var list = buf.toArrayList();
    defer list.deinit(alloc);

    const file = try std.Io.Dir.cwd().createFile(io, "config.toml", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, list.items);

    try stdout.writeStreamingAll(io, "\n✅ config.toml 已生成\n");
    try stdout.writeStreamingAll(io, "🚀 运行 zponder 启动索引器\n\n");
}

fn readLine(alloc: std.mem.Allocator, io: std.Io, stdin_file: std.Io.File, default: []const u8) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(io, &read_buf);
    var write_buf: std.Io.Writer.Allocating = .init(alloc);
    defer write_buf.deinit();

    _ = reader.streamMode(&write_buf.writer, .limited(4096), .streaming) catch |e| {
        if (e == error.EndOfStream) return try alloc.dupe(u8, default);
        return e;
    };

    var list = write_buf.toArrayList();
    defer list.deinit(alloc);
    const input = std.mem.trim(u8, list.items, " \t\r\n");
    if (input.len == 0) return try alloc.dupe(u8, default);
    return try alloc.dupe(u8, input);
}

/// 解析 ABI 并自动发现事件（当 events 为空时），同时自动获取 ABI
const ResolvedConfig = struct {
    contracts: []config.ContractConfig,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ResolvedConfig) void {
        for (self.contracts) |*c| {
            for (c.events) |e| self.alloc.free(e);
            self.alloc.free(c.events);
        }
        self.alloc.free(self.contracts);
    }
};

fn resolveEvents(alloc: std.mem.Allocator, io: std.Io, cfg: *const config.Config) !ResolvedConfig {
    var resolved = try alloc.alloc(config.ContractConfig, cfg.contracts.len);
    errdefer alloc.free(resolved);

    for (cfg.contracts, 0..) |c, i| {
        resolved[i] = c;

        // 自动获取 ABI（如果 abi_path 为空且有 etherscan key）
        if (c.abi_path.len == 0) {
            if (cfg.global.etherscan_api_key.len > 0) {
                const chain = etherscan.Chain.fromString(cfg.global.chain) orelse .ethereum;
                const abi_json = etherscan.fetchAbi(alloc, io, chain, cfg.global.etherscan_api_key, c.address) catch |e| {
                    log.err("获取合约 {s} ABI 失败: {any}", .{ c.name, e });
                    return e;
                };
                defer alloc.free(abi_json);

                const cached_path = etherscan.cacheAbi(alloc, io, c.name, abi_json) catch |e| {
                    log.err("缓存合约 {s} ABI 失败: {any}", .{ c.name, e });
                    return e;
                };

                if (resolved[i].abi_path.len > 0) alloc.free(resolved[i].abi_path);
                resolved[i].abi_path = cached_path;
                log.info("合约 {s}: ABI 已获取 → {s}", .{ c.name, cached_path });
            } else {
                log.warn("合约 {s}: 跳过（无 abi_path 且无 etherscan_api_key）", .{c.name});
                continue;
            }
        }

        // 已有事件列表，继续
        if (c.events.len > 0) continue;

        // 解析 ABI 并提取所有事件名
        var ac = abi.parseAbiFile(alloc, io, resolved[i].abi_path) catch |e| {
            log.warn("解析 ABI {s} 失败: {any}", .{ resolved[i].abi_path, e });
            continue;
        };
        defer ac.deinit(alloc);

        if (ac.events.len == 0) {
            log.warn("合约 {s}: ABI 中未发现事件", .{c.name});
            continue;
        }

        var events = try std.ArrayList([]const u8).initCapacity(alloc, ac.events.len);
        for (ac.events) |*evt| {
            try events.append(alloc, try alloc.dupe(u8, evt.name));
        }

        if (resolved[i].events.len > 0) {
            for (resolved[i].events) |e| alloc.free(e);
            alloc.free(resolved[i].events);
        }
        resolved[i].events = try events.toOwnedSlice(alloc);
        log.info("合约 {s}: 自动发现 {d} 个事件", .{ c.name, resolved[i].events.len });
    }

    return .{ .contracts = resolved, .alloc = alloc };
}
