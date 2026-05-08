const std = @import("std");
const log = @import("log.zig");

pub const Chain = enum {
    ethereum,
    bsc,
    polygon,

    pub fn apiUrl(c: Chain) []const u8 {
        return switch (c) {
            .ethereum => "https://api.etherscan.io/api",
            .bsc => "https://api.bscscan.com/api",
            .polygon => "https://api.polygonscan.com/api",
        };
    }

    pub fn defaultRpc(c: Chain) []const u8 {
        return switch (c) {
            .ethereum => "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
            .bsc => "https://bsc-dataseed.binance.org",
            .polygon => "https://polygon-rpc.com",
        };
    }

    pub fn name(c: Chain) []const u8 {
        return switch (c) {
            .ethereum => "Ethereum",
            .bsc => "BNB Smart Chain",
            .polygon => "Polygon PoS",
        };
    }

    pub fn fromString(s: []const u8) ?Chain {
        const lower = s;
        if (std.mem.eql(u8, lower, "ethereum") or std.mem.eql(u8, lower, "eth") or std.mem.eql(u8, lower, "mainnet")) return .ethereum;
        if (std.mem.eql(u8, lower, "bsc") or std.mem.eql(u8, lower, "bnb") or std.mem.eql(u8, lower, "binance")) return .bsc;
        if (std.mem.eql(u8, lower, "polygon") or std.mem.eql(u8, lower, "matic")) return .polygon;
        return null;
    }

    /// 知名合约 (address, name) — 用于 init 向导快捷选择
    pub fn knownContracts(c: Chain) []const KnownContract {
        return switch (c) {
            .ethereum => &.{
                .{ .name = "DAI", .address = "0x6b175474e89094c44da98b954eedeac495271d0f" },
                .{ .name = "USDC", .address = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" },
                .{ .name = "USDT", .address = "0xdac17f958d2ee523a2206206994597c13d831ec7" },
                .{ .name = "WETH", .address = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" },
                .{ .name = "UNI", .address = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" },
            },
            .bsc => &.{
                .{ .name = "PancakeSwap-Router", .address = "0x10ed43c718714eb63d5aa57b78b54704e256024e" },
                .{ .name = "PancakeSwap-Factory", .address = "0xca143ce32fe78f1f7019d7d551a6402fc5350c73" },
                .{ .name = "BUSD", .address = "0xe9e7cea3dedca5984780bafc599bd69add087d56" },
                .{ .name = "WBNB", .address = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c" },
                .{ .name = "USDT-BSC", .address = "0x55d398326f99059ff775485246999027b3197955" },
                .{ .name = "CAKE", .address = "0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82" },
            },
            .polygon => &.{
                .{ .name = "USDC-Polygon", .address = "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" },
                .{ .name = "USDT-Polygon", .address = "0xc2132d05d31c914a87c6611c10748aeb04b58e8f" },
                .{ .name = "WMATIC", .address = "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" },
            },
        };
    }
};

pub const KnownContract = struct {
    name: []const u8,
    address: []const u8,
};

/// 从区块浏览器 API 获取合约 ABI
/// 支持 Etherscan / BscScan / PolygonScan (同一 API 格式)
pub fn fetchAbi(
    alloc: std.mem.Allocator,
    io: std.Io,
    chain: Chain,
    api_key: []const u8,
    contract_address: []const u8,
) ![]u8 {
    const base_url = chain.apiUrl();

    var url_buf: std.Io.Writer.Allocating = .init(alloc);
    defer url_buf.deinit();
    try url_buf.writer.print(
        "{s}?module=contract&action=getabi&address={s}&apikey={s}",
        .{ base_url, contract_address, api_key },
    );
    var url_list = url_buf.toArrayList();
    defer url_list.deinit(alloc);

    var http_client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http_client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(alloc);
    defer response_writer.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url_list.items },
        .method = .GET,
        .response_writer = &response_writer.writer,
    }) catch |e| {
        log.err("{s} HTTP 请求失败: {any}", .{ chain.name(), e });
        return error.ABIFetchFailed;
    };

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        log.err("{s} 返回 HTTP {d}", .{ chain.name(), @intFromEnum(result.status) });
        return error.ABIFetchFailed;
    }

    var body = response_writer.toArrayList();
    defer body.deinit(alloc);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body.items, .{}) catch |e| {
        log.err("{s} 响应 JSON 解析失败: {any}", .{ chain.name(), e });
        return error.ABIFetchFailed;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const status = if (obj.get("status")) |s| switch (s) { .string => |v| v, else => "0" } else "0";
    if (!std.mem.eql(u8, status, "1")) {
        const msg = if (obj.get("result")) |r| switch (r) { .string => |v| v, else => "unknown" } else "unknown";
        log.err("{s} API 错误: {s}", .{ chain.name(), msg });
        return error.ABIFetchFailed;
    }

    const abi_result = obj.get("result") orelse {
        log.err("{s} 响应缺少 result 字段", .{chain.name()});
        return error.ABIFetchFailed;
    };
    const abi_str = switch (abi_result) { .string => |v| v, else => {
        log.err("{s} result 不是字符串", .{chain.name()});
        return error.ABIFetchFailed;
    } };

    return try alloc.dupe(u8, abi_str);
}

/// 缓存 ABI 到本地文件
pub fn cacheAbi(alloc: std.mem.Allocator, io: std.Io, contract_name: []const u8, abi_json: []const u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}.abi", .{contract_name});

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |e| {
        log.warn("创建 ABI 缓存文件 {s} 失败: {any}", .{ path, e });
        return e;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, abi_json);
    return try alloc.dupe(u8, path);
}
