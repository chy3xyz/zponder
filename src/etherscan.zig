const std = @import("std");
const log = @import("log.zig");

/// 从 Etherscan API 获取合约 ABI
/// 文档: https://docs.etherscan.io/api-endpoints/contracts#get-contract-abi
pub fn fetchAbi(
    alloc: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    contract_address: []const u8,
) ![]u8 {
    const base_url = "https://api.etherscan.io/api";

    // 构建 URL: /api?module=contract&action=getabi&address=0x...&apikey=...
    var url_buf: std.Io.Writer.Allocating = .init(alloc);
    defer url_buf.deinit();
    try url_buf.writer.print(
        "{s}?module=contract&action=getabi&address={s}&apikey={s}",
        .{ base_url, contract_address, api_key },
    );
    var url_list = url_buf.toArrayList();
    defer url_list.deinit(alloc);

    // HTTP fetch
    var http_client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http_client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(alloc);
    defer response_writer.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url_list.items },
        .method = .GET,
        .response_writer = &response_writer.writer,
    }) catch |e| {
        log.err("Etherscan HTTP 请求失败: {any}", .{e});
        return error.ABIFetchFailed;
    };

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        log.err("Etherscan 返回 HTTP {d}", .{@intFromEnum(result.status)});
        return error.ABIFetchFailed;
    }

    var body = response_writer.toArrayList();
    defer body.deinit(alloc);

    // 解析 JSON: {"status":"1","message":"OK","result":"[...]"}
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body.items, .{}) catch |e| {
        log.err("Etherscan 响应 JSON 解析失败: {any}", .{e});
        return error.ABIFetchFailed;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const status = if (obj.get("status")) |s| switch (s) { .string => |v| v, else => "0" } else "0";
    if (!std.mem.eql(u8, status, "1")) {
        const msg = if (obj.get("result")) |r| switch (r) { .string => |v| v, else => "unknown" } else "unknown";
        log.err("Etherscan API 错误: {s}", .{msg});
        return error.ABIFetchFailed;
    }

    const abi_result = obj.get("result") orelse {
        log.err("Etherscan 响应缺少 result 字段", .{});
        return error.ABIFetchFailed;
    };
    const abi_str = switch (abi_result) { .string => |v| v, else => {
        log.err("Etherscan result 不是字符串", .{});
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
