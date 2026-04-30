const std = @import("std");
const log = @import("log.zig");

/// 内存查询缓存条目（LRU 节点）
const CacheEntry = struct {
    key: []const u8,
    data: []u8,
    valid_up_to: u64,
    node: std.DoublyLinkedList.Node,
};

/// 轻量级内存缓存（线程安全，LRU 驱逐，内存上限）
pub const Cache = struct {
    alloc: std.mem.Allocator,
    mutex: std.atomic.Mutex,
    map: std.StringHashMap(*CacheEntry),
    lru: std.DoublyLinkedList,
    max_entries: usize,
    max_bytes: usize,
    total_bytes: usize,

    pub fn init(alloc: std.mem.Allocator, max_entries: usize, max_bytes: usize) Cache {
        return .{
            .alloc = alloc,
            .mutex = .unlocked,
            .map = std.StringHashMap(*CacheEntry).init(alloc),
            .lru = .{},
            .max_entries = max_entries,
            .max_bytes = max_bytes,
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *Cache) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            const ce = entry.value_ptr.*;
            self.alloc.free(ce.data);
            self.alloc.destroy(ce);
        }
        self.map.deinit();
    }

    /// 获取缓存
    pub fn get(
        self: *Cache,
        key: []const u8,
        current_sync_block: u64,
    ) ?[]const u8 {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        const entry = self.map.get(key) orelse return null;

        if (current_sync_block > entry.valid_up_to) {
            return null;
        }

        // 移动到 LRU 队尾（最近使用）
        self.lru.remove(&entry.node);
        self.lru.append(&entry.node);

        return entry.data;
    }

    /// 写入缓存
    pub fn put(
        self: *Cache,
        key: []const u8,
        data: []const u8,
        valid_up_to: u64,
    ) !void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        const data_size = data.len;

        // 如果单条数据超过上限的 1/4，直接跳过
        if (data_size > self.max_bytes / 4) return;

        // 删除旧条目（如果存在）
        if (self.map.fetchRemove(key)) |old| {
            self.removeEntry(old.key, old.value);
        }

        // 容量控制：按内存和条目数双重限制驱逐
        while ((self.map.count() >= self.max_entries or self.total_bytes + data_size > self.max_bytes) and self.lru.first != null) {
            const node = self.lru.first.?;
            const ce: *CacheEntry = @fieldParentPtr("node", node);
            self.removeEntryFromMapAndList(ce);
        }

        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);

        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);

        const ce = try self.alloc.create(CacheEntry);
        errdefer self.alloc.destroy(ce);

        ce.* = .{
            .key = key_copy,
            .data = data_copy,
            .valid_up_to = valid_up_to,
            .node = .{},
        };

        try self.map.put(key_copy, ce);
        self.lru.append(&ce.node);
        self.total_bytes += data_size;
    }

    /// 按合约+事件失效
    pub fn invalidate(self: *Cache, contract: []const u8, event: []const u8) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        const prefix = std.fmt.allocPrint(self.alloc, "{s}:{s}:", .{ contract, event }) catch return;
        defer self.alloc.free(prefix);

        var to_remove: std.ArrayList([]const u8) = .empty;
        defer {
            for (to_remove.items) |k| self.alloc.free(k);
            to_remove.deinit(self.alloc);
        }

        var it = self.map.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, prefix)) {
                to_remove.append(self.alloc, self.alloc.dupe(u8, k.*) catch continue) catch break;
            }
        }

        for (to_remove.items) |k| {
            if (self.map.fetchRemove(k)) |old| {
                self.removeEntry(old.key, old.value);
            }
        }
    }

    /// 按合约失效
    pub fn invalidateContract(self: *Cache, contract: []const u8) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        const prefix = std.fmt.allocPrint(self.alloc, "{s}:", .{contract}) catch return;
        defer self.alloc.free(prefix);

        var to_remove: std.ArrayList([]const u8) = .empty;
        defer {
            for (to_remove.items) |k| self.alloc.free(k);
            to_remove.deinit(self.alloc);
        }

        var it = self.map.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, prefix)) {
                to_remove.append(self.alloc, self.alloc.dupe(u8, k.*) catch continue) catch break;
            }
        }

        for (to_remove.items) |k| {
            if (self.map.fetchRemove(k)) |old| {
                self.removeEntry(old.key, old.value);
            }
        }
    }

    /// 统计缓存大小
    pub fn stats(self: *Cache) struct { count: usize, total_bytes: usize } {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        return .{ .count = self.map.count(), .total_bytes = self.total_bytes };
    }

    fn removeEntry(self: *Cache, key: []const u8, ce: *CacheEntry) void {
        self.alloc.free(key);
        self.total_bytes -= ce.data.len;
        self.alloc.free(ce.data);
        self.lru.remove(&ce.node);
        self.alloc.destroy(ce);
    }

    fn removeEntryFromMapAndList(self: *Cache, ce: *CacheEntry) void {
        // O(1) 直接通过 key 移除，无需线性扫描
        if (self.map.fetchRemove(ce.key)) |old| {
            self.removeEntry(old.key, old.value);
        }
    }
};

// ============================================================================
// 单元测试
// ============================================================================

test "cache basic get/put" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 1024 * 1024);
    defer c.deinit();

    try c.put("k1", "hello", 100);
    try std.testing.expectEqualStrings("hello", c.get("k1", 100).?);
    try std.testing.expectEqualStrings("hello", c.get("k1", 99).?);
    try std.testing.expect(c.get("k1", 101) == null); // 过期
    try std.testing.expect(c.get("k2", 100) == null); // 不存在
}

test "cache LRU eviction by count" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 3, 1024 * 1024);
    defer c.deinit();

    try c.put("a", "1", 100);
    try c.put("b", "2", 100);
    try c.put("c", "3", 100);
    try c.put("d", "4", 100); // 应驱逐最早的 a

    try std.testing.expect(c.get("a", 100) == null);
    try std.testing.expectEqualStrings("2", c.get("b", 100).?);
    try std.testing.expectEqualStrings("3", c.get("c", 100).?);
    try std.testing.expectEqualStrings("4", c.get("d", 100).?);
}

test "cache LRU eviction by bytes" {
    const alloc = std.testing.allocator;
    // max_bytes = 40，单条上限 1/4 = 10 字节
    var c = Cache.init(alloc, 100, 40);
    defer c.deinit();

    try c.put("a", "1234567890", 100); // 10 bytes
    try c.put("b", "1234567890", 100); // 10 bytes, total = 20
    try c.put("c", "12345", 100);      // 5 bytes, total = 25
    try c.put("d", "1234567890", 100); // 10 bytes, total = 35
    try c.put("e", "1234567890", 100); // 10 bytes, total would be 45 > 40, evict a

    const stats = c.stats();
    // a 被驱逐后，剩余 b(10)+c(5)+d(10)+e(10)=35
    try std.testing.expectEqual(@as(usize, 4), stats.count);
    try std.testing.expectEqual(@as(usize, 35), stats.total_bytes);
    try std.testing.expect(c.get("a", 100) == null);
    try std.testing.expectEqualStrings("1234567890", c.get("b", 100).?);
    try std.testing.expectEqualStrings("12345", c.get("c", 100).?);
    try std.testing.expectEqualStrings("1234567890", c.get("d", 100).?);
    try std.testing.expectEqualStrings("1234567890", c.get("e", 100).?);
}

test "cache LRU promotes on get" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 2, 1024 * 1024);
    defer c.deinit();

    try c.put("a", "1", 100);
    try c.put("b", "2", 100);
    _ = c.get("a", 100); // 访问 a，a 变为最近使用
    try c.put("c", "3", 100); // 应驱逐 b（因为 a 被访问过更热）

    try std.testing.expectEqualStrings("1", c.get("a", 100).?);
    try std.testing.expect(c.get("b", 100) == null);
    try std.testing.expectEqualStrings("3", c.get("c", 100).?);
}

test "cache update existing key" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 1024 * 1024);
    defer c.deinit();

    try c.put("k1", "old", 100);
    try c.put("k1", "new", 200);

    try std.testing.expectEqualStrings("new", c.get("k1", 200).?);
    try std.testing.expectEqualStrings("new", c.get("k1", 150).?);
    try std.testing.expect(c.get("k1", 201) == null);
}

test "cache invalidate by contract:event" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 1024 * 1024);
    defer c.deinit();

    try c.put("dai:Transfer:q1", "a", 100);
    try c.put("dai:Approval:q2", "b", 100);
    try c.put("bayc:Transfer:q3", "c", 100);

    c.invalidate("dai", "Transfer");

    try std.testing.expect(c.get("dai:Transfer:q1", 100) == null);
    try std.testing.expectEqualStrings("b", c.get("dai:Approval:q2", 100).?);
    try std.testing.expectEqualStrings("c", c.get("bayc:Transfer:q3", 100).?);
}

test "cache stats" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 1024 * 1024);
    defer c.deinit();

    try c.put("k1", "hello", 100);
    try c.put("k2", "world", 100);
    const s = c.stats();
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqual(@as(usize, 10), s.total_bytes);
}

test "cache skip oversized entry" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 100);
    defer c.deinit();

    // 单条超过 max_bytes/4 = 25
    try c.put("k1", "123456789012345678901234567890", 100);
    try std.testing.expect(c.get("k1", 100) == null);
}

test "cache concurrent put/get" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 1000, 1024 * 1024);
    defer c.deinit();

    const Worker = struct {
        fn run(cache: *Cache, thread_id: usize) void {
            var key_buf: [32]u8 = undefined;
            var val_buf: [32]u8 = undefined;
            for (0..50) |i| {
                const key = std.fmt.bufPrint(&key_buf, "t{d}:k{d}", .{ thread_id, i }) catch continue;
                const val = std.fmt.bufPrint(&val_buf, "v{d}", .{i}) catch continue;
                cache.put(key, val, 1000) catch continue;
                _ = cache.get(key, 999);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &c, i });
    }
    for (&threads) |t| t.join();

    // 验证每个线程的数据至少部分存在
    var found: usize = 0;
    for (0..4) |tid| {
        for (0..50) |i| {
            var buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "t{d}:k{d}", .{ tid, i }) catch continue;
            if (c.get(key, 1000) != null) found += 1;
        }
    }
    // 并发测试的核心目标是验证无崩溃/数据竞争，
    // 不要求所有条目都保留（LRU 可能在并发插入时发生驱逐）
    try std.testing.expect(found > 0);
}


test "cache invalidate nonexistent" {
    const alloc = std.testing.allocator;
    var c = Cache.init(alloc, 100, 1024 * 1024);
    defer c.deinit();

    // 对空缓存调用 invalidate 不应崩溃
    c.invalidate("nonexistent", "event");
    try std.testing.expectEqual(@as(usize, 0), c.stats().count);

    try c.put("k1", "v1", 100);
    c.invalidate("other", "event");
    try std.testing.expectEqualStrings("v1", c.get("k1", 100).?);
}
