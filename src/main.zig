const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const log = @import("log.zig");
const eth_rpc = @import("eth_rpc.zig");
const db = @import("db.zig");
const indexer = @import("indexer.zig");
const http_server = @import("http_server.zig");
const graphql = @import("graphql.zig");
const factory = @import("factory.zig");
const cache = @import("cache.zig");
const etherscan = @import("etherscan.zig");
const abi = @import("abi.zig");
const script_engine = @import("script_engine.zig");
const js_engine = @import("js_engine.zig");

var g_running = std.atomic.Value(bool).init(true);

const posix = std.posix;

fn signalHandler(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    g_running.store(false, .monotonic);
}

fn setupSignals() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    setupSignals();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    var config_path: []const u8 = "./config.toml";

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            const ver_msg = try std.fmt.allocPrint(alloc,
                \\zponder v{s} (commit: {s})
                \\Built with Zig 0.17.0-dev
                \\Features: QuickJS, SQLite, RocksDB, PostgreSQL, GraphQL, Webhook Queue, SSE Streaming, WSS Subscribe
                \\
            , .{ build_options.version, build_options.git_commit });
            defer alloc.free(ver_msg);
            std.Io.File.stdout().writeStreamingAll(init.io, ver_msg) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "add-script") or std.mem.eql(u8, arg, "new-script")) {
            var script_name: []const u8 = "my_handler";
            var is_json = false;
            if (arg_idx + 1 < args.len and !std.mem.startsWith(u8, args[arg_idx + 1], "-")) {
                script_name = args[arg_idx + 1];
                arg_idx += 1;
            }
            if (arg_idx + 1 < args.len and std.mem.eql(u8, args[arg_idx + 1], "--json")) {
                is_json = true;
            }
            try cmdAddScript(alloc, init.io, script_name, is_json);
            return;
        }
        if (std.mem.eql(u8, arg, "init")) {
            try cmdInit(alloc, init.io);
            return;
        }
        if (std.mem.eql(u8, arg, "check")) {
            if (arg_idx + 1 < args.len and (std.mem.eql(u8, args[arg_idx + 1], "-c") or std.mem.eql(u8, args[arg_idx + 1], "--config"))) {
                if (arg_idx + 2 < args.len) config_path = args[arg_idx + 2];
            }
            try cmdCheck(alloc, init.io, config_path);
            return;
        }
        if (std.mem.eql(u8, arg, "install")) {
            try cmdInstall(alloc, init.io);
            return;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            const help =
                \\zponder — 高性能 Zig 以太坊事件索引器
                \\
                \\用法:
                \\  zponder <子命令> [选项]
                \\
                \\子命令:
                \\  start                        启动索引器服务 (默认)
                \\  add-script <名称> [--json]    生成业务脚本模版 (存入 ./handlers/)
                \\  check                        校验配置文件、RPC 连接与数据库 Migration
                \\  dev                          开发调试模式运行 (输出 Debug 日志与 Handler 扫描)
                \\  init                         交互式配置生成向导
                \\  install                      将 zponder 二进制安装至系统 PATH
                \\  version, -v, --version       显示版本与 Git 提交信息
                \\  help, -h, --help             显示帮助信息
                \\
                \\选项:
                \\  -c, --config <路径>          配置文件路径 (默认: ./config.toml)
                \\
            ;
            std.Io.File.stdout().writeStreamingAll(init.io, help) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
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
    var resolved = try resolveEvents(alloc, init.io, &cfg);
    defer resolved.deinit();

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
            alloc,
            init.io,
            &rpc,
            &database,
            &resolved.contracts[i],
            cfg.global.snapshot_interval,
            cfg.global.track_blocks,
            cfg.global.chain,
            null,
            null,
            0,
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

    // 工厂合约管理
    var factory_manager: ?factory.FactoryManager = null;
    if (cfg.factories.len > 0) {
        factory_manager = try factory.FactoryManager.init(
            alloc,
            init.io,
            &rpc,
            &database,
            cfg.factories,
            cfg.global.snapshot_interval,
            cfg.global.chain,
            cfg.global.track_blocks,
        );

        // 将工厂回调关联到匹配的索引器
        for (cfg.factories, 0..) |fc, fi| {
            for (indexers.items) |*idx| {
                if (std.mem.eql(u8, fc.address, idx.contract.address)) {
                    idx.factory_ctx = &factory_manager.?;
                    idx.factory_callback = factory.FactoryManager.onFactoryEventCallback;
                    idx.factory_idx = fi;
                    log.info("工厂 {s}: 已关联到索引器 {s}", .{ fc.name, idx.contract.name });
                    break;
                }
            }
        }
    }

    // 自动扫描与挂载 Handler 动态脚本
    var script_eng = script_engine.ScriptEngine.init(alloc, init.io);
    defer script_eng.deinit();

    var js_eng = try js_engine.JsEngine.init(alloc, init.io);
    defer js_eng.deinit();

    script_eng.loadDirectory("./handlers") catch {};
    script_eng.loadDirectory("./examples/handlers") catch {};
    js_eng.loadDirectory("./handlers") catch {};
    js_eng.loadDirectory("./examples/handlers") catch {};

    const CombinedHook = struct {
        script_eng: *script_engine.ScriptEngine,

        fn callback(
            ctx_ptr: ?*anyopaque,
            contract_name: []const u8,
            event_name: []const u8,
            fields: []const db.DecodedField,
            block_number: u64,
        ) void {
            if (ctx_ptr) |ptr| {
                const self_ptr: *@This() = @ptrCast(@alignCast(ptr));
                self_ptr.script_eng.processEvent(contract_name, event_name, fields, block_number);
            }
        }
    };
    var combined_hook: CombinedHook = .{
        .script_eng = &script_eng,
    };
    for (indexers.items) |*idx| {
        idx.setEventCallback(&combined_hook, CombinedHook.callback);
    }

    // 8. 启动
    for (indexers.items) |*idx| try idx.start();

    var server = http_server.Server.init(alloc, init.io, &cfg.http, &database, &query_cache, indexer_ptrs.items, cfg.queries, cfg.dashboards);
    defer server.deinit();
    try server.start();

    // GraphQL server (optional)
    var graphql_shutdown = std.atomic.Value(bool).init(false);
    var graphql_thread: ?std.Thread = null;
    if (cfg.graphql.enabled) {
        const gql_ctx = graphql.Context{
            .database = &database,
            .indexers = indexer_ptrs.items,
            .chain = cfg.global.chain,
            .shutdown_flag = &graphql_shutdown,
            .rpc = &rpc,
        };
        graphql_thread = graphql.start(alloc, &cfg.graphql, gql_ctx) catch null;
        if (graphql_thread == null) {
            log.warn("GraphQL 服务启动失败", .{});
        }
    }

    log.info("所有模块已启动，索引器运行中...", .{});

    while (g_running.load(.monotonic)) {
        std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), .real) catch {};

        // GraphQL server 收到 SIGINT 后自行退出，设置此标志触发主循环退出
        if (graphql_shutdown.load(.acquire)) {
            log.info("GraphQL 服务已退出，开始优雅关闭...", .{});
            break;
        }
    }

    log.info("收到终止信号，开始优雅退出...", .{});
    server.stop();
    if (factory_manager) |*fm| {
        log.info("停止所有工厂子索引器...", .{});
        fm.stopChildren();
        log.info("工厂子索引器已停止", .{});
    }
    for (indexers.items) |*idx| idx.stop();
    log.info("优雅退出完成", .{});
}

// ============================================================================
// check — 校验配置与环境
// ============================================================================
fn cmdCheck(alloc: std.mem.Allocator, io: std.Io, config_path: []const u8) !void {
    try log.init(alloc, io, "info", null);
    defer log.deinit(alloc, io);

    log.info("🔍 开始校验 zponder 配置与依赖...", .{});

    var cfg = config.load(alloc, io, config_path) catch |err| {
        log.err("✗ [1/4] 配置文件 [{s}] 解析错误: {any}", .{ config_path, err });
        return;
    };
    defer cfg.deinit(alloc);
    log.info("✓ [1/4] 配置文件格式校验通过: {s}", .{config_path});

    var rpc = eth_rpc.Client.init(alloc, io, &cfg.rpc);
    const block_num = rpc.getBlockNumber() catch |err| {
        log.err("✗ [2/4] RPC 节点连接失败 ({s}): {any}", .{ cfg.rpc.url, err });
        return;
    };
    log.info("✓ [2/4] RPC 节点连接正常, 当前最新区块: {d}", .{block_num});

    var database = db.Client.init(alloc, &cfg.database) catch |err| {
        log.err("✗ [3/4] 数据库初始化失败: {any}", .{err});
        return;
    };
    defer database.deinit();
    try database.migrate();
    log.info("✓ [3/4] 数据库 ({s}) 结构迁移校验通过", .{cfg.database.db_type});

    var resolved = resolveEvents(alloc, io, &cfg) catch |err| {
        log.err("✗ [4/4] ABI 与合约事件解析错误: {any}", .{err});
        return;
    };
    defer resolved.deinit();
    log.info("✓ [4/4] 所有 {d} 个合约 ABI 解析正常", .{resolved.contracts.len});

    log.info("🎉 校验全部完成，系统具备启动条件！", .{});
}

// ============================================================================
// install — 一键安装二进制至系统 PATH
// ============================================================================
fn cmdInstall(alloc: std.mem.Allocator, io: std.Io) !void {
    try log.init(alloc, io, "info", null);
    defer log.deinit(alloc, io);

    log.info("📦 开始将 zponder 安装至系统 PATH...", .{});

    const exe_path = try alloc.dupe(u8, "./zig-out/bin/zponder");
    defer alloc.free(exe_path);

    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    const local_bin = try std.fmt.allocPrint(alloc, "{s}/.local/bin", .{home});
    defer alloc.free(local_bin);

    const local_target = try std.fmt.allocPrint(alloc, "{s}/zponder", .{local_bin});
    defer alloc.free(local_target);

    std.Io.Dir.cwd().copyFile(exe_path, std.Io.Dir.cwd(), local_target, io, .{}) catch |err| {
        log.err("复制二进制文件至 {s} 失败: {any}", .{ local_target, err });
        return;
    };

    log.info("🎉 成功安装 zponder 二进制文件至: {s}", .{local_target});
    log.info("提示: 请确保 {s} 已经在系统的 PATH 环境变量中。", .{local_bin});
}

// ============================================================================
// add-script — 生成业务 Handler 脚本模版
// ============================================================================
fn cmdAddScript(alloc: std.mem.Allocator, io: std.Io, name: []const u8, is_json: bool) !void {
    try log.init(alloc, io, "info", null);
    defer log.deinit(alloc, io);

    var d = std.Io.Dir.cwd().openDir(io, "handlers", .{}) catch blk: {
        std.Io.Dir.cwd().createDir(io, "handlers", @enumFromInt(0o755)) catch {};
        break :blk std.Io.Dir.cwd().openDir(io, "handlers", .{}) catch return;
    };
    d.close(io);

    const ext = if (is_json) ".json" else ".js";
    const filename = try std.fmt.allocPrint(alloc, "handlers/{s}{s}", .{ name, ext });
    defer alloc.free(filename);

    const content = if (is_json) try std.fmt.allocPrint(alloc,
        \\[
        \\  {{
        \\    "contract": "PancakePair",
        \\    "event": "Swap",
        \\    "field": "amount0In",
        \\    "op": "gte",
        \\    "val": "1000000000000000000000",
        \\    "action": {{
        \\      "type": "log",
        \\      "msg": "🚨 [{s}] 触发大额 Swap 业务规则"
        \\    }}
        \\  }},
        \\  {{
        \\    "contract": "PancakePair",
        \\    "event": "Swap",
        \\    "field": "amount0In",
        \\    "op": "gte",
        \\    "val": "1000000000000000000000",
        \\    "action": {{
        \\      "type": "webhook",
        \\      "url": "http://127.0.0.1:3000/api/webhook"
        \\    }}
        \\  }}
        \\]
        \\
    , .{name}) else try std.fmt.allocPrint(alloc,
        \\/**
        \\ * zponder Handler 动态脚本: {s}
        \\ * 由 `zponder add-script` 自动生成
        \\ */
        \\
        \\ponder.on("PancakePair:Swap", async ({{ event, context }}) => {{
        \\  const {{ sender, amount0In, amount1Out }} = event.args;
        \\  const blockNumber = event.block.number;
        \\
        \\  console.log(`[{s}] Event triggered at block #${{blockNumber}} | Sender: ${{sender}}`);
        \\
        \\  // 示例 1: 异步 Webhook POST 通知
        \\  // await context.webhook.post("http://127.0.0.1:3000/api/alerts", {{ sender, blockNumber }});
        \\
        \\  // 示例 2: SSE 实时长连接推流至 Web 前端大屏
        \\  // context.sse.broadcast({{ type: "{s}_EVENT", sender, blockNumber }});
        \\}});
        \\
    , .{ name, name, name });
    defer alloc.free(content);

    const file = std.Io.Dir.cwd().createFile(io, filename, .{}) catch |err| {
        log.err("创建脚本模版文件 [{s}] 失败: {any}", .{ filename, err });
        return;
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
        log.err("写入脚本模版内容失败: {any}", .{err});
        return;
    };

    log.info("🎉 成功生成业务脚本模版文件: {s}", .{filename});
    log.info("提示: zponder 启动时将自动扫描并加载 handlers/ 目录下的所有脚本。", .{});
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
        \\# [graphql]
        \\# enabled = true
        \\# port = 8081
        \\# host = "0.0.0.0"
        \\# enable_playground = true
        \\# rate_limit_rps = 10
        \\# rate_limit_burst = 100
        \\
        \\# [[factories]]
        \\# name = "factory_name"
        \\# address = "0x..."
        \\# abi_path = "./abis/factory.abi"
        \\# creation_event = "ContractCreated"
        \\# child_address_field = "newContract"
        \\# child_abi_path = "./abis/child.abi"
        \\# child_events = ["Event1", "Event2"]
        \\# max_children = 1000
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
    owned: []bool, // 标记哪些 contracts 的 events 是 resolveEvents 分配的
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ResolvedConfig) void {
        for (self.contracts, self.owned) |*c, owned| {
            if (owned) {
                for (c.events) |e| self.alloc.free(e);
                self.alloc.free(c.events);
            }
        }
        self.alloc.free(self.contracts);
        self.alloc.free(self.owned);
    }
};

fn resolveEvents(alloc: std.mem.Allocator, io: std.Io, cfg: *const config.Config) !ResolvedConfig {
    var resolved = try alloc.alloc(config.ContractConfig, cfg.contracts.len);
    errdefer alloc.free(resolved);
    var owned = try alloc.alloc(bool, cfg.contracts.len);
    errdefer alloc.free(owned);
    @memset(owned, false);

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
        owned[i] = true; // 标记为 resolveEvents 分配
        log.info("合约 {s}: 自动发现 {d} 个事件", .{ c.name, resolved[i].events.len });
    }

    return .{ .contracts = resolved, .owned = owned, .alloc = alloc };
}
