//! `-Dpostgres=false` 时的占位实现：导出的名字与签名和 pg_impl 完全一致，调用即报错。
//! 保留 `.postgresql` 这个 BackendType 枚举值是为了不牵动 db.zig 里成片的
//! `backend_type == .postgresql` 分支；真正的拦截点是 Client.init —— 打开 PostgreSQL
//! 时返回 `error.PostgresSupportNotCompiled`，由 db.initPostgreSQL 补上可读的日志。
//!
//! 无返回错误的 getter 做成空值实现：只有拿到 PgResult（必然来自一次成功查询）才会被调用。
const std = @import("std");

pub const Client = struct {
    pub fn init(alloc: std.mem.Allocator, conninfo: []const u8) !Client {
        _ = alloc;
        _ = conninfo;
        return error.PostgresSupportNotCompiled;
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn exec(self: *Client, sql: []const u8) !void {
        _ = self;
        _ = sql;
        return error.PostgresSupportNotCompiled;
    }

    pub fn execParams(
        self: *Client,
        sql: []const u8,
        params: []const []const u8,
    ) !PgResult {
        _ = self;
        _ = sql;
        _ = params;
        return error.PostgresSupportNotCompiled;
    }

    pub fn execParamsNull(
        self: *Client,
        sql: []const u8,
        params: []const ?[]const u8,
    ) !PgResult {
        _ = self;
        _ = sql;
        _ = params;
        return error.PostgresSupportNotCompiled;
    }
};

pub const PgResult = struct {
    pub fn deinit(self: *PgResult) void {
        _ = self;
    }

    pub fn rows(self: *PgResult) c_int {
        _ = self;
        return 0;
    }

    pub fn cols(self: *PgResult) c_int {
        _ = self;
        return 0;
    }

    pub fn colName(self: *PgResult, idx: c_int) []const u8 {
        _ = self;
        _ = idx;
        return "";
    }

    pub fn get(self: *PgResult, row: c_int, col: c_int) []const u8 {
        _ = self;
        _ = row;
        _ = col;
        return "";
    }

    pub fn colType(self: *PgResult, idx: c_int) u32 {
        _ = self;
        _ = idx;
        return 0;
    }

    pub fn cmdTuples(self: *PgResult) []const u8 {
        _ = self;
        return "";
    }

    pub fn isNull(self: *PgResult, row: c_int, col: c_int) bool {
        _ = self;
        _ = row;
        _ = col;
        return true;
    }
};
