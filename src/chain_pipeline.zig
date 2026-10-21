const std = @import("std");

/// 一条日志在链上的位置，外加产出它的合约下标（排序键不含 contract_index，
/// 相等位置靠稳定排序保留原来的相对顺序）。
pub const LogPos = struct {
    block: u64,
    tx_index: u32,
    log_index: u32,
    contract_index: u16,
};

fn logPosLess(_: void, a: LogPos, b: LogPos) bool {
    if (a.block != b.block) return a.block < b.block;
    if (a.tx_index != b.tx_index) return a.tx_index < b.tx_index;
    return a.log_index < b.log_index;
}

/// 按 block、tx_index、log_index 升序稳定排序。
pub fn orderLogs(items: []LogPos) void {
    std.mem.sort(LogPos, items, {}, logPosLess);
}

/// 同一条链上两条日志谁先发生。`log_index` 是块内序号，所以块号加它就是全序。
pub fn logBefore(a_block: u64, a_index: u64, b_block: u64, b_index: u64) bool {
    if (a_block != b_block) return a_block < b_block;
    return a_index < b_index;
}

/// 地址按 `max_per_request` 切块后的块数。
/// 空地址返回 0；`max_per_request == 0` 按 1 处理，避免除零并把每个地址单独成块。
pub fn chunkAddresses(addresses: []const []const u8, max_per_request: usize) usize {
    if (addresses.len == 0) return 0;
    const max = if (max_per_request == 0) 1 else max_per_request;
    return (addresses.len + max - 1) / max;
}

test "orderLogs 乱序按 block、tx、log 排序" {
    var items = [_]LogPos{
        .{ .block = 3, .tx_index = 0, .log_index = 0, .contract_index = 1 },
        .{ .block = 1, .tx_index = 2, .log_index = 0, .contract_index = 2 },
        .{ .block = 1, .tx_index = 2, .log_index = 1, .contract_index = 3 },
        .{ .block = 1, .tx_index = 0, .log_index = 9, .contract_index = 4 },
        .{ .block = 2, .tx_index = 0, .log_index = 0, .contract_index = 5 },
    };
    orderLogs(&items);
    const expect = [_]LogPos{
        .{ .block = 1, .tx_index = 0, .log_index = 9, .contract_index = 4 },
        .{ .block = 1, .tx_index = 2, .log_index = 0, .contract_index = 2 },
        .{ .block = 1, .tx_index = 2, .log_index = 1, .contract_index = 3 },
        .{ .block = 2, .tx_index = 0, .log_index = 0, .contract_index = 5 },
        .{ .block = 3, .tx_index = 0, .log_index = 0, .contract_index = 1 },
    };
    try std.testing.expectEqualSlices(LogPos, &expect, &items);
}

test "orderLogs 相同位置保持相对顺序" {
    var items = [_]LogPos{
        .{ .block = 2, .tx_index = 0, .log_index = 1, .contract_index = 10 },
        .{ .block = 1, .tx_index = 0, .log_index = 0, .contract_index = 1 },
        .{ .block = 2, .tx_index = 0, .log_index = 1, .contract_index = 11 },
        .{ .block = 1, .tx_index = 5, .log_index = 0, .contract_index = 2 },
        .{ .block = 2, .tx_index = 0, .log_index = 0, .contract_index = 9 },
        .{ .block = 1, .tx_index = 0, .log_index = 0, .contract_index = 3 },
    };
    orderLogs(&items);
    const expect = [_]LogPos{
        .{ .block = 1, .tx_index = 0, .log_index = 0, .contract_index = 1 },
        .{ .block = 1, .tx_index = 0, .log_index = 0, .contract_index = 3 },
        .{ .block = 1, .tx_index = 5, .log_index = 0, .contract_index = 2 },
        .{ .block = 2, .tx_index = 0, .log_index = 0, .contract_index = 9 },
        .{ .block = 2, .tx_index = 0, .log_index = 1, .contract_index = 10 },
        .{ .block = 2, .tx_index = 0, .log_index = 1, .contract_index = 11 },
    };
    try std.testing.expectEqualSlices(LogPos, &expect, &items);
}

test "logBefore 先比区块再比 log index" {
    try std.testing.expect(logBefore(1, 9, 2, 0));
    try std.testing.expect(!logBefore(2, 0, 1, 9));
    try std.testing.expect(logBefore(5, 1, 5, 2));
    try std.testing.expect(!logBefore(5, 2, 5, 2));
}

test "chunkAddresses 空地址与分块" {
    const addrs = [_][]const u8{ "a", "b", "c", "d", "e" };
    try std.testing.expectEqual(@as(usize, 0), chunkAddresses(&[_][]const u8{}, 200));
    try std.testing.expectEqual(@as(usize, 0), chunkAddresses(&[_][]const u8{}, 0));
    try std.testing.expectEqual(@as(usize, 5), chunkAddresses(&addrs, 0));
    try std.testing.expectEqual(@as(usize, 5), chunkAddresses(&addrs, 1));
    try std.testing.expectEqual(@as(usize, 3), chunkAddresses(&addrs, 2));
    try std.testing.expectEqual(@as(usize, 2), chunkAddresses(&addrs, 3));
    try std.testing.expectEqual(@as(usize, 1), chunkAddresses(&addrs, 5));
    try std.testing.expectEqual(@as(usize, 1), chunkAddresses(&addrs, 200));
}
