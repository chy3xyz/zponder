const std = @import("std");

var g_initialized: bool = false;
var g_log_level: LogLevel = .info;
var g_log_file: ?std.Io.File = null;
var g_mutex: std.atomic.Mutex = .unlocked;
var g_io: std.Io = undefined;
var g_json_format: bool = false;
var g_alloc: std.mem.Allocator = undefined;

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn fromString(s: []const u8) LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return .info;
    }

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

/// 初始化日志模块
pub fn init(alloc: std.mem.Allocator, io: std.Io, level_str: []const u8, log_file_path: ?[]const u8) !void {
    g_initialized = true;
    g_log_level = LogLevel.fromString(level_str);
    g_io = io;
    g_alloc = alloc;

    if (log_file_path) |path| {
        g_log_file = try std.Io.Dir.cwd().createFile(
            io, path, .{ .truncate = false },
        );
    }
}

/// 释放日志资源
pub fn deinit(_: std.mem.Allocator, _: std.Io) void {
    if (g_log_file) |file| {
        file.close(g_io);
        g_log_file = null;
    }
}

/// 设置 JSON 格式输出
pub fn setJsonFormat(enabled: bool) void {
    g_json_format = enabled;
}

/// 获取当前日志级别
pub fn level() LogLevel {
    return g_log_level;
}

fn levelPrefix(lvl: LogLevel) []const u8 {
    return switch (lvl) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}

fn shouldLog(lvl: LogLevel) bool {
    return @intFromEnum(lvl) >= @intFromEnum(g_log_level);
}

fn logInternal(lvl: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!g_initialized) return;
    if (!shouldLog(lvl)) return;

    // 先在外部构建消息，避免在锁内分配失败导致死锁
    var msg_buf = std.ArrayList(u8).empty;
    msg_buf.print(g_alloc, fmt, args) catch {
        msg_buf.deinit(g_alloc);
        return;
    };
    defer msg_buf.deinit(g_alloc);
    const msg = msg_buf.items;

    while (!g_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer g_mutex.unlock();

    const ts = std.Io.Timestamp.now(g_io, .real);
    const secs = @as(u64, @intCast(ts.toSeconds()));
    const hours = @mod(secs / 3600, 24);
    const mins = @mod(secs / 60, 60);
    const s = @mod(secs, 60);

    if (g_json_format) {
        // JSON 结构化日志
        var line = std.ArrayList(u8).empty;
        line.print(g_alloc, "{{\"ts\":\"{d:0>2}:{d:0>2}:{d:0>2}\",\"level\":\"{s}\",\"msg\":\"", .{ hours, mins, s, lvl.asString() }) catch {
            line.deinit(g_alloc);
            return;
        };

        // 简单的 JSON 字符串转义
        for (msg) |ch| {
            switch (ch) {
                '\\' => line.appendSlice(g_alloc, "\\\\") catch {
                    line.deinit(g_alloc);
                    return;
                },
                '"' => line.appendSlice(g_alloc, "\\\"") catch {
                    line.deinit(g_alloc);
                    return;
                },
                '\n' => line.appendSlice(g_alloc, "\\n") catch {
                    line.deinit(g_alloc);
                    return;
                },
                '\r' => line.appendSlice(g_alloc, "\\r") catch {
                    line.deinit(g_alloc);
                    return;
                },
                '\t' => line.appendSlice(g_alloc, "\\t") catch {
                    line.deinit(g_alloc);
                    return;
                },
                else => line.append(g_alloc, ch) catch {
                    line.deinit(g_alloc);
                    return;
                },
            }
        }

        line.appendSlice(g_alloc, "\"}}\n") catch {
            line.deinit(g_alloc);
            return;
        };
        defer line.deinit(g_alloc);
        const line_str = line.items;

        std.Io.File.stderr().writeStreamingAll(g_io, line_str) catch {};
        if (g_log_file) |file| {
            file.writeStreamingAll(g_io, line_str) catch {};
        }
    } else {
        // 传统文本日志
        var line = std.ArrayList(u8).empty;
        line.print(g_alloc, "[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}\n", .{ hours, mins, s, levelPrefix(lvl), msg }) catch {
            line.deinit(g_alloc);
            return;
        };
        defer line.deinit(g_alloc);
        const line_str = line.items;

        std.Io.File.stderr().writeStreamingAll(g_io, line_str) catch {};
        if (g_log_file) |file| {
            file.writeStreamingAll(g_io, line_str) catch {};
        }
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logInternal(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    logInternal(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logInternal(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    logInternal(.err, fmt, args);
}

// ============================================================================
// 单元测试
// ============================================================================

test "LogLevel.fromString" {
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("debug"));
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("info"));
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("warn"));
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("error"));
    // 未知级别回退到 info
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("unknown"));
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString(""));
}

test "LogLevel.asString" {
    try std.testing.expectEqualStrings("debug", LogLevel.debug.asString());
    try std.testing.expectEqualStrings("info", LogLevel.info.asString());
    try std.testing.expectEqualStrings("warn", LogLevel.warn.asString());
    try std.testing.expectEqualStrings("error", LogLevel.err.asString());
}

test "shouldLog respects global level" {
    const saved = g_log_level;
    defer g_log_level = saved;

    g_log_level = .info;
    try std.testing.expect(!shouldLog(.debug));
    try std.testing.expect(shouldLog(.info));
    try std.testing.expect(shouldLog(.warn));
    try std.testing.expect(shouldLog(.err));

    g_log_level = .warn;
    try std.testing.expect(!shouldLog(.debug));
    try std.testing.expect(!shouldLog(.info));
    try std.testing.expect(shouldLog(.warn));
    try std.testing.expect(shouldLog(.err));

    g_log_level = .debug;
    try std.testing.expect(shouldLog(.debug));
    try std.testing.expect(shouldLog(.info));
    try std.testing.expect(shouldLog(.warn));
    try std.testing.expect(shouldLog(.err));
}
