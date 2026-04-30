const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const log = @import("log.zig");
const eth_rpc = @import("eth_rpc.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const http_server = @import("http_server.zig");
const cache = @import("cache.zig");

// 全局优雅退出标志
var g_running = std.atomic.Value(bool).init(true);

// C 信号处理（链接 libc）
const c_signal = @cImport({
    @cInclude("signal.h");
});

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_running.store(false, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    // 注册信号处理器（SIG_ERR 宏在 macOS 上无法被 zig translate-c 解析，故不检查返回值）
    _ = c_signal.signal(c_signal.SIGINT, signalHandler);
    _ = c_signal.signal(c_signal.SIGTERM, signalHandler);

    // 解析命令行参数
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    var config_path: []const u8 = "./config.toml";

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (std.mem.eql(u8, args[arg_idx], "-h") or std.mem.eql(u8, args[arg_idx], "--help")) {
            const help =
                \\zponder - Zig 以太坊事件索引器
                \\
                \\用法: zponder [选项]
                \\
                \\选项:
                \\  -c, --config <路径>  配置文件路径 (默认: ./config.toml)
                \\  -h, --help           显示此帮助信息
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

    log.info("🚀 启动 zponder Zig 以太坊索引器 v{s} ({s})", .{ build_options.version, build_options.git_commit });
    log.info("配置加载完成，RPC: {s}, 数据库: {s}", .{ cfg.rpc.url, cfg.database.db_type });

    // 3. 初始化查询缓存（最大 1000 条，内存上限 64MB）
    var query_cache = cache.Cache.init(alloc, 1000, 64 * 1024 * 1024);
    defer query_cache.deinit();
    log.info("查询缓存已初始化", .{});

    // 4. 初始化数据库
    var database = try db.Client.init(alloc, &cfg.database);
    defer database.deinit();
    database.setCache(&query_cache);
    try database.migrate();
    log.info("数据库初始化完成", .{});

    // 5. 初始化 RPC 客户端
    var rpc = eth_rpc.Client.init(alloc, init.io, &cfg.rpc);
    defer rpc.deinit();
    log.info("RPC 客户端初始化完成，正在测试连接...", .{});

    const latest_block = rpc.getBlockNumber() catch |e| blk: {
        log.warn("RPC 连接测试失败: {any}，继续启动（将在同步循环中重试）", .{e});
        break :blk 0;
    };
    if (latest_block > 0) {
        log.info("RPC 连接成功，当前最新区块: {d}", .{latest_block});
    }

    // 6. 初始化索引器（多合约并行）
    var indexers: std.ArrayList(indexer.Indexer) = .empty;
    defer {
        for (indexers.items) |*idx| {
            idx.deinit();
        }
        indexers.deinit(alloc);
    }

    var indexer_ptrs: std.ArrayList(*indexer.Indexer) = .empty;
    defer indexer_ptrs.deinit(alloc);

    for (cfg.contracts, 0..) |_, i| {
        const idx = try indexer.Indexer.init(alloc, init.io, &rpc, &database, &cfg.contracts[i], cfg.global.snapshot_interval);
        try indexers.append(alloc, idx);
        log.info("初始化合约索引器: {s} (起始区块: {d})", .{ cfg.contracts[i].address, cfg.contracts[i].from_block });
    }

    // 必须在所有 append 完成后才取指针，否则 realloc 会导致指针失效
    for (indexers.items) |*idx| {
        try indexer_ptrs.append(alloc, idx);
    }

    // 7. 启动索引器协程
    for (indexers.items) |*idx| {
        try idx.start();
    }

    // 8. 启动 HTTP 服务
    var server = http_server.Server.init(alloc, init.io, &cfg.http, &database, &query_cache, indexer_ptrs.items);
    defer server.deinit();
    try server.start();

    log.info("所有模块已启动，索引器运行中...", .{});

    // 9. 主线程保持运行，直到收到 SIGINT/SIGTERM
    while (g_running.load(.monotonic)) {
        std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), .real) catch {};
    }

    log.info("收到终止信号，开始优雅退出...", .{});

    // 10. 优雅退出：停止 HTTP 服务 → 停止索引器 → defer 清理资源
    server.stop();
    for (indexers.items) |*idx| {
        idx.stop();
    }
    // deinit 会在 main 返回时通过 defer 执行，自动 join 线程并关闭资源
    log.info("优雅退出完成", .{});
}
