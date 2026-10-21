//! 原始日志缓存的区间运算。
//!
//! 覆盖区间存在 `sync.chain_log_ranges`，原始行在 `sync.chain_logs`。
//! SQLite 把 `sync` 挂成旁边的 `.sync.db`；PostgreSQL 用同一个库里的 schema。
//! 本文件只放与后端无关的区间计算。

const std = @import("std");

pub const BlockSpan = struct {
    from_block: u64,
    to_block: u64,
};

/// 写入缓存的一条原始日志。topics 是逗号分隔的 hex，调用期间保持有效。
pub const ChainLogIn = struct {
    address: []const u8,
    block_number: u64,
    tx_hash: []const u8,
    log_index: u64,
    topics: []const u8,
    data: []const u8,
};

/// 从缓存读出的一行。字符串归调用方，用 `db.Client.freeChainLogs` 释放。
pub const ChainLogRow = struct {
    address: []u8,
    block_number: u64,
    tx_hash: []u8,
    log_index: u64,
    topics: []u8,
    data: []u8,
};

pub const sqlite_ddl =
    \\CREATE TABLE IF NOT EXISTS sync.chain_logs (
    \\  chain TEXT NOT NULL,
    \\  address TEXT NOT NULL,
    \\  block_number INTEGER NOT NULL,
    \\  tx_hash TEXT NOT NULL,
    \\  log_index INTEGER NOT NULL,
    \\  topics TEXT NOT NULL,
    \\  data TEXT NOT NULL,
    \\  PRIMARY KEY (chain, tx_hash, log_index)
    \\);
    \\CREATE INDEX IF NOT EXISTS sync.idx_sync_chain_logs_lookup
    \\  ON chain_logs(chain, address, block_number);
    \\CREATE TABLE IF NOT EXISTS sync.chain_log_ranges (
    \\  chain TEXT NOT NULL,
    \\  address TEXT NOT NULL,
    \\  topics_key TEXT NOT NULL,
    \\  from_block INTEGER NOT NULL,
    \\  to_block INTEGER NOT NULL,
    \\  PRIMARY KEY (chain, address, topics_key, from_block)
    \\);
;

pub const pg_schema_ddl = "CREATE SCHEMA IF NOT EXISTS sync;";

pub const pg_ddl =
    \\CREATE TABLE IF NOT EXISTS sync.chain_logs (
    \\  chain TEXT NOT NULL,
    \\  address TEXT NOT NULL,
    \\  block_number BIGINT NOT NULL,
    \\  tx_hash TEXT NOT NULL,
    \\  log_index BIGINT NOT NULL,
    \\  topics TEXT NOT NULL,
    \\  data TEXT NOT NULL,
    \\  PRIMARY KEY (chain, tx_hash, log_index)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_sync_chain_logs_lookup
    \\  ON sync.chain_logs(chain, address, block_number);
    \\CREATE TABLE IF NOT EXISTS sync.chain_log_ranges (
    \\  chain TEXT NOT NULL,
    \\  address TEXT NOT NULL,
    \\  topics_key TEXT NOT NULL,
    \\  from_block BIGINT NOT NULL,
    \\  to_block BIGINT NOT NULL,
    \\  PRIMARY KEY (chain, address, topics_key, from_block)
    \\);
;

/// 事件 topic 集合的稳定键。空集合是 `*`（不过滤）。顺序不同但成员相同得到同一键。
pub fn topicsKey(alloc: std.mem.Allocator, topics: []const []const u8) ![]u8 {
    if (topics.len == 0) return alloc.dupe(u8, "*");
    const copy = try alloc.dupe([]const u8, topics);
    defer alloc.free(copy);
    std.mem.sort([]const u8, copy, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var prev: ?[]const u8 = null;
    for (copy) |topic| {
        if (prev) |p| if (std.mem.eql(u8, p, topic)) continue;
        if (buf.items.len > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, topic);
        prev = topic;
    }
    return buf.toOwnedSlice(alloc);
}

/// `to_block == 0` 或上界小于起点：重放到链尖。否则上界含在重放区间里。
pub fn replayUpper(from_block: u64, to_block: u64) ?u64 {
    if (to_block == 0 or to_block < from_block) return null;
    return to_block;
}

/// 公共节点常见的 eth_getLogs 静默上限。达到这个条数时，最高那个区块可能只回来了一部分。
pub const getlogs_page_limit: usize = 10_000;

/// 返回已经能确认完整的闭区间终点。条数没到上限时就是请求的 `to_block`。
/// 整页都挤在起点这一块、切不开时返回 null，调用方不要把这段记成已覆盖。
pub fn pageEnd(from_block: u64, to_block: u64, max_block: u64, count: usize, limit: usize) ?u64 {
    if (limit == 0 or count < limit) return to_block;
    if (max_block <= from_block) return null;
    const end = max_block - 1;
    return if (end > to_block) to_block else end;
}

/// `0x` + 40 hex 收成小写。其它形态原样返回（指向调用方的切片）。
pub fn cacheAddress(out: *[42]u8, address: []const u8) []const u8 {
    if (address.len != 42 or !std.mem.startsWith(u8, address, "0x")) return address;
    return std.ascii.lowerString(out, address);
}

/// `eth_indexer.db` → `eth_indexer.sync.db`。`:memory:` 仍是内存库。
pub fn syncFileName(alloc: std.mem.Allocator, db_name: []const u8) ![]u8 {
    if (db_name.len == 0 or std.mem.eql(u8, db_name, ":memory:")) {
        return alloc.dupe(u8, ":memory:");
    }
    if (std.mem.endsWith(u8, db_name, ".db")) {
        return std.fmt.allocPrint(alloc, "{s}.sync.db", .{db_name[0 .. db_name.len - 3]});
    }
    return std.fmt.allocPrint(alloc, "{s}.sync.db", .{db_name});
}

fn spansLess(_: void, a: BlockSpan, b: BlockSpan) bool {
    if (a.from_block != b.from_block) return a.from_block < b.from_block;
    return a.to_block < b.to_block;
}

/// 合并重叠或首尾相接的区间。调用方释放返回值。
pub fn mergeSpans(alloc: std.mem.Allocator, spans: []const BlockSpan) ![]BlockSpan {
    if (spans.len == 0) return alloc.alloc(BlockSpan, 0);
    const copy = try alloc.dupe(BlockSpan, spans);
    defer alloc.free(copy);
    std.mem.sort(BlockSpan, copy, {}, spansLess);

    var merged: std.ArrayList(BlockSpan) = .empty;
    errdefer merged.deinit(alloc);
    try merged.append(alloc, copy[0]);
    for (copy[1..]) |span| {
        const prev = &merged.items[merged.items.len - 1];
        const touches = prev.to_block == std.math.maxInt(u64) or span.from_block <= prev.to_block + 1;
        if (touches) {
            if (span.to_block > prev.to_block) prev.to_block = span.to_block;
        } else {
            try merged.append(alloc, span);
        }
    }
    return merged.toOwnedSlice(alloc);
}

/// `covered` 按 from_block 升序、互不重叠。返回 `[from_block, to_block]` 里还没盖住的闭区间。
pub fn uncovered(covered: []const BlockSpan, from_block: u64, to_block: u64, out: []BlockSpan) usize {
    if (from_block > to_block) return 0;
    var cursor = from_block;
    var n: usize = 0;
    for (covered) |span| {
        if (span.to_block < cursor) continue;
        if (span.from_block > to_block) break;
        if (span.from_block > cursor) {
            if (n >= out.len) return n;
            out[n] = .{ .from_block = cursor, .to_block = span.from_block - 1 };
            n += 1;
        }
        if (span.to_block >= to_block) return n;
        if (span.to_block == std.math.maxInt(u64)) return n;
        cursor = span.to_block + 1;
        if (cursor > to_block) return n;
    }
    if (cursor <= to_block and n < out.len) {
        out[n] = .{ .from_block = cursor, .to_block = to_block };
        n += 1;
    }
    return n;
}

test "topicsKey 与重放上界" {
    const alloc = std.testing.allocator;
    const a = try topicsKey(alloc, &.{ "0xbb", "0xaa", "0xbb" });
    defer alloc.free(a);
    const b = try topicsKey(alloc, &.{ "0xaa", "0xbb" });
    defer alloc.free(b);
    try std.testing.expectEqualStrings("0xaa,0xbb", a);
    try std.testing.expectEqualStrings(a, b);
    const all = try topicsKey(alloc, &.{});
    defer alloc.free(all);
    try std.testing.expectEqualStrings("*", all);
    try std.testing.expect(replayUpper(10, 0) == null);
    try std.testing.expect(replayUpper(10, 3) == null);
    try std.testing.expectEqual(@as(?u64, 12), replayUpper(10, 12));
}

test "页满时丢掉可能被截断的最高区块" {
    try std.testing.expectEqual(@as(?u64, 50), pageEnd(1, 50, 40, 3, 10_000));
    try std.testing.expectEqual(@as(?u64, 2), pageEnd(1, 9, 3, 4, 4));
    try std.testing.expect(pageEnd(5, 5, 5, 4, 4) == null);
    try std.testing.expectEqual(@as(?u64, 9), pageEnd(1, 9, 0, 0, 4));
}

test "sync 文件名跟在业务库旁边" {
    const alloc = std.testing.allocator;
    const named = try syncFileName(alloc, "eth_indexer.db");
    defer alloc.free(named);
    try std.testing.expectEqualStrings("eth_indexer.sync.db", named);

    const bare = try syncFileName(alloc, "data/idx");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("data/idx.sync.db", bare);

    const mem = try syncFileName(alloc, ":memory:");
    defer alloc.free(mem);
    try std.testing.expectEqualStrings(":memory:", mem);
}

test "区间合并与缺口" {
    const alloc = std.testing.allocator;
    const spans = [_]BlockSpan{
        .{ .from_block = 10, .to_block = 20 },
        .{ .from_block = 21, .to_block = 30 },
        .{ .from_block = 40, .to_block = 50 },
        .{ .from_block = 45, .to_block = 60 },
    };
    const merged = try mergeSpans(alloc, &spans);
    defer alloc.free(merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(@as(u64, 10), merged[0].from_block);
    try std.testing.expectEqual(@as(u64, 30), merged[0].to_block);
    try std.testing.expectEqual(@as(u64, 40), merged[1].from_block);
    try std.testing.expectEqual(@as(u64, 60), merged[1].to_block);

    var holes: [4]BlockSpan = undefined;
    try std.testing.expectEqual(@as(usize, 0), uncovered(merged, 10, 30, &holes));
    try std.testing.expectEqual(@as(usize, 1), uncovered(merged, 0, 9, &holes));
    try std.testing.expectEqual(@as(u64, 0), holes[0].from_block);
    try std.testing.expectEqual(@as(u64, 9), holes[0].to_block);

    const n = uncovered(merged, 0, 70, &holes);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u64, 31), holes[1].from_block);
    try std.testing.expectEqual(@as(u64, 39), holes[1].to_block);
    try std.testing.expectEqual(@as(u64, 61), holes[2].from_block);
    try std.testing.expectEqual(@as(u64, 70), holes[2].to_block);
}
