const std = @import("std");
const c = @import("c");
const log = @import("log.zig");
const db = @import("db.zig");

pub const default_db_path = "webhook_outbox.db";
pub const max_attempts: u32 = 8;

/// 第 n 次失败后的等待（n 从 1 起）：1s、2s、4s…封顶 60s。
pub fn retryDelayMs(failed_attempts: u32) u64 {
    if (failed_attempts == 0) return 1000;
    const exp: u6 = @intCast(@min(failed_attempts - 1, 6));
    return @min(@as(u64, 1000) << exp, 60_000);
}

const Row = struct {
    id: i64,
    url: []u8,
    payload: []u8,
    attempts: u32,

    fn deinit(self: *Row, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.payload);
    }
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    db_path: []u8,
    db: *c.sqlite3,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, db_path: []const u8) !*Manager {
        const m = try create(alloc, io, db_path);
        errdefer m.destroy();
        m.thread = try std.Thread.spawn(.{}, workerLoop, .{m});
        return m;
    }

    /// 不启动投递线程。测试和 `init` 共用。
    pub fn create(alloc: std.mem.Allocator, io: std.Io, db_path: []const u8) !*Manager {
        const path_z = try alloc.allocSentinel(u8, db_path.len, 0);
        defer alloc.free(path_z);
        @memcpy(path_z, db_path);

        var raw: ?*c.sqlite3 = null;
        const flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &raw, flags, null) != c.SQLITE_OK) {
            log.err("webhook 发件箱打开失败 path={s}", .{db_path});
            if (raw) |opened| _ = c.sqlite3_close(opened);
            return error.DatabaseOpenFailed;
        }
        const conn = raw.?;
        errdefer _ = c.sqlite3_close(conn);
        try exec(conn, "PRAGMA journal_mode = WAL;");
        try exec(conn, "PRAGMA synchronous = NORMAL;");
        try exec(conn, "PRAGMA busy_timeout = 5000;");
        try exec(conn,
            \\CREATE TABLE IF NOT EXISTS webhook_outbox (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  url TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  attempts INTEGER NOT NULL DEFAULT 0,
            \\  next_attempt_ms INTEGER NOT NULL DEFAULT 0,
            \\  dead INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT NOT NULL DEFAULT ''
            \\);
        );
        try exec(conn, "CREATE INDEX IF NOT EXISTS idx_webhook_due ON webhook_outbox(dead, next_attempt_ms);");

        const path_dup = try alloc.dupe(u8, db_path);
        errdefer alloc.free(path_dup);
        const m = try alloc.create(Manager);
        m.* = .{
            .alloc = alloc,
            .io = io,
            .db_path = path_dup,
            .db = conn,
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };
        return m;
    }

    pub fn deinit(self: *Manager) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.destroy();
    }

    fn destroy(self: *Manager) void {
        _ = c.sqlite3_close(self.db);
        self.alloc.free(self.db_path);
        self.alloc.destroy(self);
    }

    pub fn enqueueEvent(
        self: *Manager,
        url: []const u8,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) void {
        if (!self.running.load(.acquire)) return;
        if (url.len == 0) return;

        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();
        const w = &buf.writer;
        w.print(
            "{{\"contract\":\"{s}\",\"event\":\"{s}\",\"block_number\":{d},\"fields\":{{",
            .{ contract_name, event_name, block_number },
        ) catch return;
        for (fields, 0..) |f, i| {
            if (i > 0) w.writeByte(',') catch return;
            w.print("\"{s}\":\"{s}\"", .{ f.name, f.value }) catch return;
        }
        w.writeAll("}}}") catch return;

        const payload = self.alloc.dupe(u8, buf.written()) catch return;
        defer self.alloc.free(payload);
        _ = self.enqueue(url, payload, 0) catch |err| {
            log.err("webhook 入队失败: {s}", .{@errorName(err)});
        };
    }

    pub fn enqueue(self: *Manager, url: []const u8, payload: []const u8, now_ms: i64) !i64 {
        const sql = "INSERT INTO webhook_outbox(url, payload, attempts, next_attempt_ms, dead, last_error) VALUES(?1,?2,0,?3,0,'');";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, payload.ptr, @intCast(payload.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 3, now_ms) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn noteFailure(self: *Manager, id: i64, prev_attempts: u32, now_ms: i64, err_msg: []const u8) !void {
        const attempts = prev_attempts + 1;
        const dead: i64 = if (attempts >= max_attempts) 1 else 0;
        const delay: i64 = @intCast(retryDelayMs(attempts));
        const next = if (dead == 1) now_ms else now_ms + delay;
        const sql = "UPDATE webhook_outbox SET attempts=?1, dead=?2, next_attempt_ms=?3, last_error=?4 WHERE id=?5;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, attempts) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, dead) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 3, next) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 4, err_msg.ptr, @intCast(err_msg.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 5, id) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    pub fn noteSuccess(self: *Manager, id: i64) !void {
        const sql = "DELETE FROM webhook_outbox WHERE id=?1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    pub fn countStatus(self: *Manager, dead: bool) !usize {
        const sql = "SELECT COUNT(*) FROM webhook_outbox WHERE dead=?1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, if (dead) 1 else 0) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.ExecFailed;
        const n = c.sqlite3_column_int64(stmt, 0);
        return @intCast(n);
    }

    fn claimDue(self: *Manager, now_ms: i64) !?Row {
        const sql = "SELECT id, url, payload, attempts FROM webhook_outbox WHERE dead=0 AND next_attempt_ms<=?1 ORDER BY id LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, now_ms) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const id = c.sqlite3_column_int64(stmt, 0);
        const url = try columnText(self.alloc, stmt, 1);
        errdefer self.alloc.free(url);
        const payload = try columnText(self.alloc, stmt, 2);
        const attempts: u32 = @intCast(c.sqlite3_column_int64(stmt, 3));
        return .{ .id = id, .url = url, .payload = payload, .attempts = attempts };
    }

    fn workerLoop(self: *Manager) void {
        var http_client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer http_client.deinit();

        while (self.running.load(.acquire)) {
            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            const row_opt = self.claimDue(now) catch |err| {
                log.warn("webhook 读取发件箱失败: {s}", .{@errorName(err)});
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
                continue;
            };
            if (row_opt) |row| {
                var owned = row;
                defer owned.deinit(self.alloc);
                self.deliver(&http_client, &owned, now);
            } else {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
            }
        }
    }

    fn deliver(self: *Manager, http_client: *std.http.Client, row: *const Row, now_ms: i64) void {
        var response_writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer response_writer.deinit();
        const result = http_client.fetch(.{
            .location = .{ .url = row.url },
            .method = .POST,
            .payload = row.payload,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
        }) catch |err| {
            self.noteFailure(row.id, row.attempts, now_ms, @errorName(err)) catch |e| {
                log.err("webhook 记录失败状态出错: {s}", .{@errorName(e)});
            };
            log.warn("webhook 推送失败 ({s}): {s}", .{ row.url, @errorName(err) });
            return;
        };
        const code = @intFromEnum(result.status);
        if (code < 200 or code >= 300) {
            var err_buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "HTTP {d}", .{code}) catch "HTTP error";
            self.noteFailure(row.id, row.attempts, now_ms, msg) catch {};
            log.warn("webhook 推送失败 ({s}): HTTP {d}", .{ row.url, code });
            return;
        }
        self.noteSuccess(row.id) catch |err| {
            log.err("webhook 删除已投递记录失败 id={d}: {s}", .{ row.id, @errorName(err) });
        };
    }
};

fn exec(conn: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(conn, sql, null, null, null) != c.SQLITE_OK) return error.ExecFailed;
}

fn columnText(alloc: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) ![]u8 {
    const p = c.sqlite3_column_text(stmt, col);
    if (p == null) return alloc.dupe(u8, "");
    return alloc.dupe(u8, std.mem.span(p));
}

fn removeDb(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var wal_buf: [160]u8 = undefined;
    var shm_buf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path})) |wal| {
        std.Io.Dir.cwd().deleteFile(io, wal) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path})) |shm| {
        std.Io.Dir.cwd().deleteFile(io, shm) catch {};
    } else |_| {}
}

test "webhook retryDelayMs 指数退避并封顶" {
    try std.testing.expectEqual(@as(u64, 1000), retryDelayMs(1));
    try std.testing.expectEqual(@as(u64, 2000), retryDelayMs(2));
    try std.testing.expectEqual(@as(u64, 4000), retryDelayMs(3));
    try std.testing.expectEqual(@as(u64, 60_000), retryDelayMs(20));
}

test "webhook enqueue 落盘且重启后仍在" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "webhook-outbox-enqueue-test.db";
    defer removeDb(io, path);

    var mgr = try Manager.create(alloc, io, path);
    const fields = [_]db.DecodedField{
        .{ .name = "from", .value = "0x1111" },
        .{ .name = "value", .value = "100" },
    };
    mgr.enqueueEvent("http://127.0.0.1:1/hook", "pancake", "Swap", &fields, 123);
    try std.testing.expectEqual(@as(usize, 1), try mgr.countStatus(false));
    mgr.deinit();

    var again = try Manager.create(alloc, io, path);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), try again.countStatus(false));
    var row = (try again.claimDue(0)).?;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/hook", row.url);
    try std.testing.expect(std.mem.indexOf(u8, row.payload, "\"contract\":\"pancake\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.payload, "\"value\":\"100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.payload, "\"block_number\":123") != null);
}

test "webhook 超过 1000 条仍全部保留" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "webhook-outbox-capacity-test.db";
    defer removeDb(io, path);

    var mgr = try Manager.create(alloc, io, path);
    defer mgr.deinit();
    var i: usize = 0;
    while (i < 1001) : (i += 1) {
        _ = try mgr.enqueue("http://127.0.0.1:1/hook", "{}", 0);
    }
    try std.testing.expectEqual(@as(usize, 1001), try mgr.countStatus(false));
}

test "webhook 失败退避，第 8 次标死信" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "webhook-outbox-dead-test.db";
    defer removeDb(io, path);

    var mgr = try Manager.create(alloc, io, path);
    defer mgr.deinit();
    const id = try mgr.enqueue("http://127.0.0.1:1/hook", "{}", 0);
    try mgr.noteFailure(id, 0, 1_000, "down");
    try std.testing.expectEqual(@as(usize, 1), try mgr.countStatus(false));
    try std.testing.expect((try mgr.claimDue(1_000)) == null);
    var row = (try mgr.claimDue(2_000)).?;
    defer row.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), row.attempts);

    var prev: u32 = 1;
    var n: u32 = 1;
    while (n < max_attempts) : (n += 1) {
        try mgr.noteFailure(id, prev, 10_000, "down");
        prev += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), try mgr.countStatus(false));
    try std.testing.expectEqual(@as(usize, 1), try mgr.countStatus(true));
}
