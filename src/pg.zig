const std = @import("std");
const log = @import("log.zig");

const c = @import("c");

pub const Client = struct {
    alloc: std.mem.Allocator,
    conn: *c.PGconn,

    pub fn init(alloc: std.mem.Allocator, conninfo: []const u8) !Client {
        // PQconnectdb 需要 NUL 结尾；conninfo 来自配置切片，不保证终止符
        const conninfo_z = try alloc.allocSentinel(u8, conninfo.len, 0);
        defer alloc.free(conninfo_z);
        @memcpy(conninfo_z, conninfo);
        const conn = c.PQconnectdb(conninfo_z.ptr);
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
        // PQexec 需要 NUL 结尾；调用方可能传 bufPrint 结果（无终止符）
        const sql_z = try self.alloc.allocSentinel(u8, sql.len, 0);
        defer self.alloc.free(sql_z);
        @memcpy(sql_z, sql);
        const res = c.PQexec(self.conn, sql_z.ptr);
        defer c.PQclear(res);
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            const err = std.mem.sliceTo(c.PQresultErrorMessage(res), 0);
            log.err("PostgreSQL 执行失败: {s}", .{err});
            return error.ExecFailed;
        }
    }

    /// 执行带参数的 SQL（params 为 NUL 结尾的 C 字符串）
    pub fn execParams(
        self: *Client,
        sql: []const u8,
        params: []const []const u8,
    ) !PgResult {
        const wrapped = try self.alloc.alloc(?[]const u8, params.len);
        defer self.alloc.free(wrapped);
        for (params, 0..) |p, i| wrapped[i] = p;
        return self.execParamsNull(sql, wrapped);
    }

    /// 执行带参数的 SQL；params 中 null 元素绑定为 SQL NULL。
    /// 注意：libpq 的 SQL 文本与 text 格式参数都按 NUL 结尾解析（忽略 length），
    /// 这里统一复制并补终止符，调用方传普通 Zig 切片即可。
    pub fn execParamsNull(
        self: *Client,
        sql: []const u8,
        params: []const ?[]const u8,
    ) !PgResult {
        if (params.len > 32) return error.TooManyParams;

        const sql_z = try self.alloc.allocSentinel(u8, sql.len, 0);
        defer self.alloc.free(sql_z);
        @memcpy(sql_z, sql);

        var values: [32][*c]const u8 = undefined;
        var lengths: [32]c_int = undefined;
        var owned: [32]?[:0]u8 = @splat(null);
        defer {
            for (owned[0..params.len]) |o| {
                if (o) |buf| self.alloc.free(buf);
            }
        }

        for (params, 0..) |p, i| {
            if (p) |pval| {
                const buf = try self.alloc.allocSentinel(u8, pval.len, 0);
                @memcpy(buf, pval);
                owned[i] = buf;
                values[i] = @ptrCast(buf.ptr);
                lengths[i] = @intCast(pval.len);
            } else {
                values[i] = null;
                lengths[i] = 0;
            }
        }

        const values_ptr: [*c]const [*c]const u8 = @ptrCast(&values);
        const lengths_ptr: [*c]const c_int = @ptrCast(&lengths);

        const res = c.PQexecParams(
            self.conn,
            sql_z.ptr,
            @intCast(params.len),
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

    /// 列类型 OID（20/21/23 整数、700/701/1700 浮点、17 bytea、16 bool 等）
    pub fn colType(self: *PgResult, idx: c_int) u32 {
        return @intCast(c.PQftype(self.inner, idx));
    }

    /// 受影响行数（INSERT/UPDATE/DELETE），COMMAND_OK 结果才有意义
    pub fn cmdTuples(self: *PgResult) []const u8 {
        return std.mem.sliceTo(c.PQcmdTuples(self.inner), 0);
    }

    pub fn isNull(self: *PgResult, row: c_int, col: c_int) bool {
        return c.PQgetisnull(self.inner, row, col) != 0;
    }
};
