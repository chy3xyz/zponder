//! 投影写入约束。
//! 重组回滚按 `block_number >= 分叉点` 删行，还原不了就地 UPDATE。

const std = @import("std");

/// 检查一条将交给 `ponder.db.exec` 的 SQL。
/// 忽略前导空白和 `--` 行注释；关键字不区分大小写。
/// SELECT / WITH / CREATE / DROP 以及未识别语句放行。
/// UPDATE 一律拒绝。DELETE 文本必须包含 `block_number`。
/// INSERT 的目标表若以 `proj_` 开头，文本也必须包含 `block_number`。
pub fn checkWrite(sql: []const u8) error{UnsafeProjectionWrite}!void {
    const kw = firstKeyword(sql) orelse return;
    if (eqlKw(kw, "select") or eqlKw(kw, "with") or eqlKw(kw, "create") or eqlKw(kw, "drop")) return;
    if (eqlKw(kw, "update")) return error.UnsafeProjectionWrite;
    if (eqlKw(kw, "delete")) {
        if (!containsIgnoreCase(sql, "block_number")) return error.UnsafeProjectionWrite;
        return;
    }
    if (eqlKw(kw, "insert")) {
        if (insertTargetsProj(sql) and !containsIgnoreCase(sql, "block_number")) {
            return error.UnsafeProjectionWrite;
        }
        return;
    }
}

const Name = struct { name: []const u8, end: usize };

fn eqlKw(a: []const u8, comptime b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 跳过空白和 `--` 行注释。
fn skipTrivia(sql: []const u8, start: usize) usize {
    var i = start;
    while (i < sql.len) {
        if (std.ascii.isWhitespace(sql[i])) {
            i += 1;
            continue;
        }
        if (sql[i] == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            i += 2;
            while (i < sql.len and sql[i] != '\n') i += 1;
            continue;
        }
        break;
    }
    return i;
}

fn firstKeyword(sql: []const u8) ?[]const u8 {
    const i = skipTrivia(sql, 0);
    if (i >= sql.len) return null;
    // 引号包起来的首词不当关键字，交给「未识别语句放行」。
    if (sql[i] == '"' or sql[i] == '`' or sql[i] == '[') return null;
    const name = readName(sql, i) orelse return null;
    return name.name;
}

fn insertTargetsProj(sql: []const u8) bool {
    var i = skipTrivia(sql, 0);
    const insert_kw = readName(sql, i) orelse return false;
    i = skipTrivia(sql, insert_kw.end);
    if (readName(sql, i)) |w| {
        if (eqlKw(w.name, "or")) {
            i = skipTrivia(sql, w.end);
            if (readName(sql, i)) |action| {
                i = skipTrivia(sql, action.end);
            }
        }
    }
    if (readName(sql, i)) |w| {
        if (eqlKw(w.name, "into")) {
            i = skipTrivia(sql, w.end);
        }
    }
    const table = readQualifiedName(sql, &i) orelse return false;
    return table.len >= 5 and std.ascii.eqlIgnoreCase(table[0..5], "proj_");
}

/// 读 `schema.table`（可带引号），返回最后一段，即表名。
fn readQualifiedName(sql: []const u8, i: *usize) ?[]const u8 {
    var last = readName(sql, i.*) orelse return null;
    i.* = last.end;
    while (true) {
        const after = skipTrivia(sql, i.*);
        if (after >= sql.len or sql[after] != '.') break;
        const part = readName(sql, skipTrivia(sql, after + 1)) orelse break;
        last = part;
        i.* = part.end;
    }
    return last.name;
}

fn readName(sql: []const u8, start: usize) ?Name {
    if (start >= sql.len) return null;
    switch (sql[start]) {
        '"' => return readDelimited(sql, start, '"'),
        '`' => return readDelimited(sql, start, '`'),
        '[' => return readDelimited(sql, start, ']'),
        else => {
            if (!isIdentStart(sql[start])) return null;
            var j = start + 1;
            while (j < sql.len and isIdentCont(sql[j])) j += 1;
            return .{ .name = sql[start..j], .end = j };
        },
    }
}

fn readDelimited(sql: []const u8, start: usize, close: u8) Name {
    var j = start + 1;
    while (j < sql.len) {
        if (sql[j] == close) {
            // SQL 用成对引号转义；方括号标识符不这样转义。
            if (close != ']' and j + 1 < sql.len and sql[j + 1] == close) {
                j += 2;
                continue;
            }
            return .{ .name = sql[start + 1 .. j], .end = j + 1 };
        }
        j += 1;
    }
    return .{ .name = sql[start + 1 ..], .end = sql.len };
}

test "projection UPDATE 拒绝" {
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("UPDATE proj_t SET v = 'x' WHERE block_number = 1"));
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("  -- note\nupdate balances set amount = 1"));
}

test "projection proj_ INSERT 缺 block_number 拒绝" {
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("INSERT INTO proj_t (v) VALUES ('x')"));
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("insert into PROJ_kline (close) values ('1')"));
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("INSERT OR REPLACE INTO \"proj_t\" (v) VALUES ('x')"));
}

test "projection 带 block_number 的 INSERT 通过" {
    try checkWrite("INSERT INTO proj_t (block_number, v) VALUES (?, ?);");
    try checkWrite("INSERT INTO proj_t (BLOCK_NUMBER, v) VALUES (1, 'x')");
    try checkWrite("INSERT OR REPLACE INTO proj_erc20_flow (block_number, ts, amount) VALUES (1, 2, '3')");
    try checkWrite("INSERT INTO balances (amount) VALUES (1)");
    try checkWrite("  -- leading\nSELECT * FROM proj_t");
    try checkWrite("WITH t AS (SELECT 1) SELECT * FROM t");
}

test "projection 不带 block_number 的 DELETE 拒绝" {
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("DELETE FROM proj_t WHERE v = 'x'"));
    try std.testing.expectError(error.UnsafeProjectionWrite, checkWrite("delete from other where id = 1"));
    try checkWrite("DELETE FROM proj_t WHERE block_number >= 10");
}

test "projection CREATE 通过" {
    try checkWrite("CREATE TABLE proj_t (block_number INTEGER NOT NULL, v TEXT);");
    try checkWrite("CREATE TABLE IF NOT EXISTS proj_t (id INTEGER)");
    try checkWrite("CREATE INDEX idx ON proj_t (block_number)");
    try checkWrite("DROP TABLE proj_t");
    try checkWrite("PRAGMA journal_mode = WAL");
}
