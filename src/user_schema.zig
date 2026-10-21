//! 用户表定义解析器。
//!
//! 把一段简单文本解析成表结构，并生成带 `user_` 前缀的 CREATE TABLE
//! 以及按主键查一行的 SELECT。`apply` 负责在数据库里建表。

const std = @import("std");
const db = @import("db.zig");

const table_prefix = "user_";

pub const Column = struct {
    name: []u8,
    sql_type: []u8,
    primary_key: bool,
    not_null: bool,

    pub fn deinit(self: *Column, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.sql_type);
    }
};

pub const Table = struct {
    name: []u8,
    columns: []Column,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        for (self.columns) |*col| col.deinit(alloc);
        alloc.free(self.columns);
        alloc.free(self.name);
    }
};

/// 释放 `parse` 返回的表切片及其内部字符串。
pub fn deinitTables(alloc: std.mem.Allocator, tables: []Table) void {
    for (tables) |*table| table.deinit(alloc);
    alloc.free(tables);
}

/// 解析零张或多张表。调用方用 `deinitTables` 释放返回值。
/// 列的 `sql_type` 存的是规范 SQL 类型：`TEXT` / `INTEGER` / `BLOB`。
pub fn parse(alloc: std.mem.Allocator, src: []const u8) ![]Table {
    var parser = Parser{ .alloc = alloc, .src = src, .i = 0 };
    return parser.parseSchema();
}

/// `CREATE TABLE IF NOT EXISTS user_<name> (...)`.
pub fn createSql(alloc: std.mem.Allocator, table: Table) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "CREATE TABLE IF NOT EXISTS ");
    try buf.appendSlice(alloc, table_prefix);
    try buf.appendSlice(alloc, table.name);
    try buf.appendSlice(alloc, " (\n");

    for (table.columns, 0..) |col, i| {
        try buf.appendSlice(alloc, "  ");
        try buf.appendSlice(alloc, col.name);
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, col.sql_type);
        if (col.primary_key) try buf.appendSlice(alloc, " PRIMARY KEY");
        if (col.not_null) try buf.appendSlice(alloc, " NOT NULL");
        if (i + 1 != table.columns.len) try buf.append(alloc, ',');
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, ");");
    return buf.toOwnedSlice(alloc);
}

/// 在数据库里执行每张表的 `CREATE TABLE IF NOT EXISTS`。成功后表结构由调用方 `deinitTables`。
pub fn apply(alloc: std.mem.Allocator, database: *db.Client, src: []const u8) ![]Table {
    const tables = try parse(alloc, src);
    errdefer deinitTables(alloc, tables);
    for (tables) |table| {
        const sql = try createSql(alloc, table);
        defer alloc.free(sql);
        _ = try database.ponderExec(sql, &.{});
    }
    return tables;
}

/// 按表名查找。名字是定义里的短名，不含 `user_` 前缀。
pub fn find(tables: []const Table, name: []const u8) ?*const Table {
    for (tables) |*table| {
        if (std.mem.eql(u8, table.name, name)) return table;
    }
    return null;
}

/// `SELECT * FROM user_<name> WHERE <pk> = ?`
/// 没有主键时返回 `error.NoPrimaryKey`。
pub fn selectByPkSql(alloc: std.mem.Allocator, table: Table) ![]u8 {
    const pk_name = try primaryKeyName(table.columns);
    return std.fmt.allocPrint(alloc, "SELECT * FROM {s}{s} WHERE {s} = ?", .{
        table_prefix,
        table.name,
        pk_name,
    });
}

fn primaryKeyName(columns: []const Column) error{ NoPrimaryKey, MultiplePrimaryKey }![]const u8 {
    var found: ?[]const u8 = null;
    for (columns) |col| {
        if (!col.primary_key) continue;
        if (found != null) return error.MultiplePrimaryKey;
        found = col.name;
    }
    return found orelse error.NoPrimaryKey;
}

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    i: usize,

    fn parseSchema(self: *Parser) ![]Table {
        var tables: std.ArrayList(Table) = .empty;
        errdefer {
            for (tables.items) |*table| table.deinit(self.alloc);
            tables.deinit(self.alloc);
        }

        while (!self.eof()) {
            const table = try self.parseTable();
            tables.append(self.alloc, table) catch |err| {
                var tmp = table;
                tmp.deinit(self.alloc);
                return err;
            };
        }
        return tables.toOwnedSlice(self.alloc);
    }

    fn parseTable(self: *Parser) !Table {
        const kw = self.ident() orelse return error.InvalidSyntax;
        if (!std.mem.eql(u8, kw, "table")) return error.InvalidSyntax;

        self.skip();
        if (self.i >= self.src.len or self.src[self.i] == '{') return error.EmptyTableName;

        const name_src = self.ident() orelse return error.InvalidName;
        if (!self.consume('{')) return error.InvalidSyntax;

        var cols: std.ArrayList(Column) = .empty;
        errdefer {
            for (cols.items) |*col| col.deinit(self.alloc);
            cols.deinit(self.alloc);
        }

        while (true) {
            self.skip();
            if (self.i >= self.src.len) return error.InvalidSyntax;
            if (self.src[self.i] == '}') {
                self.i += 1;
                break;
            }

            const col = try self.parseColumn();
            if (columnNameTaken(cols.items, col.name)) {
                var tmp = col;
                tmp.deinit(self.alloc);
                return error.DuplicateColumn;
            }
            if (col.primary_key and hasPrimaryKey(cols.items)) {
                var tmp = col;
                tmp.deinit(self.alloc);
                return error.MultiplePrimaryKey;
            }
            cols.append(self.alloc, col) catch |err| {
                var tmp = col;
                tmp.deinit(self.alloc);
                return err;
            };
        }

        if (cols.items.len == 0) return error.NoColumns;

        const name = try self.alloc.dupe(u8, name_src);
        errdefer self.alloc.free(name);
        const columns = try cols.toOwnedSlice(self.alloc);
        return .{
            .name = name,
            .columns = columns,
        };
    }

    fn parseColumn(self: *Parser) !Column {
        const name_src = self.ident() orelse return error.InvalidSyntax;
        const type_src = self.ident() orelse return error.InvalidSyntax;
        const sql_type_src = canonicalSqlType(type_src) orelse return error.InvalidType;

        var primary_key = false;
        var not_null = false;
        try self.parseModifiers(&primary_key, &not_null);

        const name = try self.alloc.dupe(u8, name_src);
        errdefer self.alloc.free(name);
        const sql_type = try self.alloc.dupe(u8, sql_type_src);
        return .{
            .name = name,
            .sql_type = sql_type,
            .primary_key = primary_key,
            .not_null = not_null,
        };
    }

    fn parseModifiers(self: *Parser, primary_key: *bool, not_null: *bool) !void {
        while (true) {
            const save = self.i;
            const word = self.ident() orelse return;
            if (std.mem.eql(u8, word, "primary")) {
                const key = self.ident() orelse return error.InvalidSyntax;
                if (!std.mem.eql(u8, key, "key")) return error.InvalidSyntax;
                if (primary_key.*) return error.InvalidSyntax;
                primary_key.* = true;
            } else if (std.mem.eql(u8, word, "not")) {
                const nul = self.ident() orelse return error.InvalidSyntax;
                if (!std.mem.eql(u8, nul, "null")) return error.InvalidSyntax;
                if (not_null.*) return error.InvalidSyntax;
                not_null.* = true;
            } else {
                self.i = save;
                return;
            }
        }
    }

    fn eof(self: *Parser) bool {
        self.skip();
        return self.i >= self.src.len;
    }

    fn skip(self: *Parser) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn consume(self: *Parser, ch: u8) bool {
        self.skip();
        if (self.i < self.src.len and self.src[self.i] == ch) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn ident(self: *Parser) ?[]const u8 {
        self.skip();
        if (self.i >= self.src.len) return null;
        if (!isIdentStart(self.src[self.i])) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.src.len and isIdentCont(self.src[self.i])) : (self.i += 1) {}
        return self.src[start..self.i];
    }
};

fn columnNameTaken(cols: []const Column, name: []const u8) bool {
    for (cols) |col| {
        if (std.mem.eql(u8, col.name, name)) return true;
    }
    return false;
}

fn hasPrimaryKey(cols: []const Column) bool {
    for (cols) |col| {
        if (col.primary_key) return true;
    }
    return false;
}

fn canonicalSqlType(tok: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tok, "text")) return "TEXT";
    if (std.mem.eql(u8, tok, "integer")) return "INTEGER";
    if (std.mem.eql(u8, tok, "blob")) return "BLOB";
    return null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const account_src =
    \\table account {
    \\  address text primary key
    \\  balance text not null
    \\  block_number integer not null
    \\}
;

const account_create =
    \\CREATE TABLE IF NOT EXISTS user_account (
    \\  address TEXT PRIMARY KEY,
    \\  balance TEXT NOT NULL,
    \\  block_number INTEGER NOT NULL
    \\);
;

test "parse account schema" {
    const alloc = std.testing.allocator;
    const tables = try parse(alloc, account_src);
    defer deinitTables(alloc, tables);

    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqualStrings("account", tables[0].name);
    try std.testing.expectEqual(@as(usize, 3), tables[0].columns.len);

    const address = tables[0].columns[0];
    try std.testing.expectEqualStrings("address", address.name);
    try std.testing.expectEqualStrings("TEXT", address.sql_type);
    try std.testing.expect(address.primary_key);
    try std.testing.expect(!address.not_null);

    const balance = tables[0].columns[1];
    try std.testing.expectEqualStrings("balance", balance.name);
    try std.testing.expectEqualStrings("TEXT", balance.sql_type);
    try std.testing.expect(!balance.primary_key);
    try std.testing.expect(balance.not_null);

    const block_number = tables[0].columns[2];
    try std.testing.expectEqualStrings("block_number", block_number.name);
    try std.testing.expectEqualStrings("INTEGER", block_number.sql_type);
    try std.testing.expect(!block_number.primary_key);
    try std.testing.expect(block_number.not_null);
}

test "create table sql" {
    const alloc = std.testing.allocator;
    const tables = try parse(alloc, account_src);
    defer deinitTables(alloc, tables);

    const sql = try createSql(alloc, tables[0]);
    defer alloc.free(sql);
    try std.testing.expectEqualStrings(account_create, sql);
}

test "select by primary key" {
    const alloc = std.testing.allocator;
    const tables = try parse(alloc, account_src);
    defer deinitTables(alloc, tables);

    const sql = try selectByPkSql(alloc, tables[0]);
    defer alloc.free(sql);
    try std.testing.expectEqualStrings("SELECT * FROM user_account WHERE address = ?", sql);
}

test "two tables blob and both modifiers" {
    const alloc = std.testing.allocator;
    const src =
        \\table note {
        \\  id integer not null primary key
        \\  body blob
        \\}
        \\
        \\table _meta {
        \\  _key text primary key
        \\}
    ;
    const tables = try parse(alloc, src);
    defer deinitTables(alloc, tables);

    try std.testing.expectEqual(@as(usize, 2), tables.len);
    try std.testing.expect(tables[0].columns[0].primary_key);
    try std.testing.expect(tables[0].columns[0].not_null);
    try std.testing.expectEqualStrings("BLOB", tables[0].columns[1].sql_type);
    try std.testing.expect(!tables[0].columns[1].not_null);

    const note_sql = try createSql(alloc, tables[0]);
    defer alloc.free(note_sql);
    const note_expected =
        \\CREATE TABLE IF NOT EXISTS user_note (
        \\  id INTEGER PRIMARY KEY NOT NULL,
        \\  body BLOB
        \\);
    ;
    try std.testing.expectEqualStrings(note_expected, note_sql);

    const meta_sql = try selectByPkSql(alloc, tables[1]);
    defer alloc.free(meta_sql);
    try std.testing.expectEqualStrings("SELECT * FROM user__meta WHERE _key = ?", meta_sql);
}

test "invalid column type" {
    const alloc = std.testing.allocator;
    const src =
        \\table account {
        \\  address varchar primary key
        \\}
    ;
    try std.testing.expectError(error.InvalidType, parse(alloc, src));
}

test "duplicate column name" {
    const alloc = std.testing.allocator;
    const src =
        \\table account {
        \\  address text primary key
        \\  address text
        \\}
    ;
    try std.testing.expectError(error.DuplicateColumn, parse(alloc, src));
}

test "empty table name" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyTableName, parse(alloc, "table { address text primary key }"));
    try std.testing.expectError(error.EmptyTableName, parse(alloc, "table"));
}

test "invalid name and empty column list" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidName, parse(alloc, "table 1abc { id integer primary key }"));
    try std.testing.expectError(error.NoColumns, parse(alloc, "table account {}"));
}

test "select without primary key" {
    const alloc = std.testing.allocator;
    const src =
        \\table account {
        \\  balance text not null
        \\}
    ;
    const tables = try parse(alloc, src);
    defer deinitTables(alloc, tables);
    try std.testing.expectError(error.NoPrimaryKey, selectByPkSql(alloc, tables[0]));
}

test "multiple primary keys" {
    const alloc = std.testing.allocator;
    const src =
        \\table account {
        \\  address text primary key
        \\  id integer primary key
        \\}
    ;
    try std.testing.expectError(error.MultiplePrimaryKey, parse(alloc, src));
}

test "error after a valid table does not leak" {
    const alloc = std.testing.allocator;
    const src =
        \\table ok {
        \\  id integer primary key
        \\}
        \\table bad {
        \\  name text not null
        \\  data varchar
        \\}
    ;
    try std.testing.expectError(error.InvalidType, parse(alloc, src));
}

test "unclosed table does not leak" {
    const alloc = std.testing.allocator;
    const src =
        \\table account {
        \\  address text primary key
    ;
    try std.testing.expectError(error.InvalidSyntax, parse(alloc, src));
}

test "apply 建表后可以按主键写入" {
    const alloc = std.testing.allocator;
    const cfg = db.DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var database = try db.Client.init(alloc, &cfg);
    defer database.deinit();

    const tables = try apply(alloc, &database, account_src);
    defer deinitTables(alloc, tables);
    try std.testing.expect(find(tables, "missing") == null);
    const account = find(tables, "account") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("account", account.name);

    _ = try database.ponderExec(
        "INSERT INTO user_account (address, balance, block_number) VALUES (?, ?, ?)",
        &.{ .{ .text = "0xabc" }, .{ .text = "10" }, .{ .integer = 3 } },
    );
    const rows = try database.ponderQuery(
        "SELECT balance FROM user_account WHERE address = ?",
        &.{.{ .text = "0xabc" }},
    );
    defer database.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("10", rows[0].values[0].text);
}

test "deinit frees all allocations" {
    const alloc = std.testing.allocator;
    const tables = try parse(alloc, account_src);
    const created = try createSql(alloc, tables[0]);
    const selected = try selectByPkSql(alloc, tables[0]);
    alloc.free(selected);
    alloc.free(created);
    deinitTables(alloc, tables);
}
