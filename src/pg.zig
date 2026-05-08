const std = @import("std");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const Client = struct {
    alloc: std.mem.Allocator,
    conn: *c.PGconn,

    pub fn init(alloc: std.mem.Allocator, conninfo: []const u8) !Client {
        const conn = c.PQconnectdb(conninfo.ptr);
        const status = c.PQstatus(conn);
        if (status != c.CONNECTION_OK) {
            const err = std.mem.sliceTo(c.PQerrorMessage(conn), 0);
            log.err("PostgreSQL 连接失败: {s}", .{err});
            c.PQfinish(conn);
            return error.DatabaseOpenFailed;
        }
        return .{ .alloc = alloc, .conn = conn.? };
    }

    pub fn deinit(self: *Client) void {
        c.PQfinish(self.conn);
    }

    /// 执行不带参数的 SQL (DDL)
    pub fn exec(self: *Client, sql: []const u8) !void {
        const res = c.PQexec(self.conn, sql.ptr);
        defer c.PQclear(res);
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            const err = std.mem.sliceTo(c.PQresultErrorMessage(res), 0);
            log.err("PostgreSQL 执行失败: {s}", .{err});
            return error.ExecFailed;
        }
    }

    /// 执行带参数的 SQL
    pub fn execParams(
        self: *Client,
        sql: []const u8,
        params: []const []const u8,
    ) !PgResult {
        var values: [32][*c]const u8 = undefined;
        var lengths: [32]c_int = undefined;
        var nparams: c_int = 0;

        for (params, 0..) |p, i| {
            values[i] = @ptrCast(p.ptr);
            lengths[i] = @intCast(p.len);
            nparams = @intCast(i + 1);
        }

        const values_ptr: [*c]const [*c]const u8 = @ptrCast(&values);
        const lengths_ptr: [*c]const c_int = @ptrCast(&lengths);

        const res = c.PQexecParams(
            self.conn,
            sql.ptr,
            nparams,
            null,
            values_ptr,
            lengths_ptr,
            null,
            0,
        );
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
            const err = std.mem.sliceTo(c.PQresultErrorMessage(res), 0);
            log.err("PostgreSQL 参数化查询失败: {s}", .{err});
            c.PQclear(res);
            return error.ExecFailed;
        }
        return PgResult{ .inner = res.? };
    }
};

pub const PgResult = struct {
    inner: *c.PGresult,

    pub fn deinit(self: *PgResult) void {
        c.PQclear(self.inner);
    }

    pub fn rows(self: *PgResult) c_int {
        return c.PQntuples(self.inner);
    }

    pub fn cols(self: *PgResult) c_int {
        return c.PQnfields(self.inner);
    }

    pub fn colName(self: *PgResult, idx: c_int) []const u8 {
        const name = c.PQfname(self.inner, idx);
        return std.mem.sliceTo(name, 0);
    }

    pub fn get(self: *PgResult, row: c_int, col: c_int) []const u8 {
        return std.mem.sliceTo(c.PQgetvalue(self.inner, row, col), 0);
    }

    pub fn isNull(self: *PgResult, row: c_int, col: c_int) bool {
        return c.PQgetisnull(self.inner, row, col) != 0;
    }
};
