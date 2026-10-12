const std = @import("std");
const c = @import("c");
const abi = @import("abi.zig");
const cache = @import("cache.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const rocksdb = @import("rocksdb.zig");
const pg = @import("pg.zig");

pub const DatabaseConfig = @import("config.zig").DatabaseConfig;
pub const BackendType = enum { sqlite, rocksdb, postgresql };

pub const SyncState = struct {
    contract_address: []const u8,
    last_synced_block: u64,
    status: []const u8,
};

pub const AccountState = struct {
    contract_address: []const u8,
    account_address: []const u8,
    balance: []const u8,
    last_updated_block: u64,
};

pub const Snapshot = struct {
    contract_address: []const u8,
    block_number: u64,
    snapshot_data: []const u8,
};

/// 模板模式下动态发现的 clone 地址。
/// `address` 是堆分配副本，随 Client.listTemplateAddresses 的返回值一起由调用方释放。
pub const TemplateAddress = struct {
    address: []u8,
    from_block: u64,
    backfilled: bool,
};

pub const DecodedField = struct {
    name: []const u8,
    value: []const u8,
};

/// ponder.db 参数/结果值模型（js_engine 负责 JS 值 <-> SqlValue 转换）
pub const SqlValue = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
};

/// ponder.db 查询结果行；names/values 归调用方所有，经 Client.freeQueryRows 释放。
pub const QueryRow = struct {
    names: [][]const u8,
    values: []SqlValue,
};

pub const BlockRecord = struct {
    chain: []const u8,
    block_number: u64,
    block_hash: []const u8,
    timestamp: u64,
    miner: []const u8,
    gas_used: u64,
    gas_limit: u64,
    base_fee_per_gas: []const u8,
    transaction_count: u64,
};

/// 复制并补 0 终止符（libpq text 参数按 NUL 结尾解析，Zig 切片无终止符）
fn allocSentinelCopy(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

pub const Client = struct {
    alloc: std.mem.Allocator,
    config: *const DatabaseConfig,
    backend_type: BackendType,
    db: ?*c.sqlite3,
    read_db: ?*c.sqlite3 = null,
    rocks: ?rocksdb.Client,
    pgconn: ?pg.Client,
    cache: ?*cache.Cache = null,

    pub fn init(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        if (std.mem.eql(u8, config.db_type, "sqlite")) {
            return initSqlite(alloc, config);
        } else if (std.mem.eql(u8, config.db_type, "rocksdb")) {
            return initRocksDB(alloc, config);
        } else if (std.mem.eql(u8, config.db_type, "postgresql") or std.mem.eql(u8, config.db_type, "postgres")) {
            return initPostgreSQL(alloc, config);
        }
        return error.UnsupportedDatabaseType;
    }

    fn initSqlite(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        var db: ?*c.sqlite3 = null;
        const path = if (config.db_name.len > 0) config.db_name else ":memory:";
        // sqlite3_open_v2 需要 NUL 结尾的 C 字符串；config.db_name 是 TOML 切片，
        // 不保证终止符（此前偶发 CANTOPEN / 读到越界垃圾即源于此）。
        const path_z = try alloc.allocSentinel(u8, path.len, 0);
        defer alloc.free(path_z);
        @memcpy(path_z, path);
        // 写连接用 FULLMUTEX：多个索引器线程并发写同一连接，sqlite3 连接
        // 本身非线程安全（默认无内部锁），FULLMUTEX 使其线程安全。
        const w_flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(path_z.ptr, &db, w_flags, null);
        if (rc != c.SQLITE_OK) {
            log.err("SQLite 打开失败 path={s} rc={d} errmsg={s}", .{ path, rc, std.mem.sliceTo(c.sqlite3_errmsg(db), 0) });
            return error.DatabaseOpenFailed;
        }
        try checkPragma(db, "PRAGMA foreign_keys = ON;");
        try checkPragma(db, "PRAGMA journal_mode = WAL;");
        try checkPragma(db, "PRAGMA synchronous = NORMAL;");
        // 多索引器线程并发写时的锁等待（默认 0 会立刻失败丢写入）
        const busy_ms = config.busy_timeout_ms;
        var busy_pragma_buf: [64]u8 = undefined;
        const written = try std.fmt.bufPrint(&busy_pragma_buf, "PRAGMA busy_timeout = {d};", .{busy_ms});
        // sqlite3_exec 需要 C 字符串（null 结尾），bufPrint 不保证
        busy_pragma_buf[written.len] = 0;
        try checkPragma(db, busy_pragma_buf[0..written.len]);

        var read_db: ?*c.sqlite3 = null;
        if (!std.mem.eql(u8, path, ":memory:")) {
            const flags: c_int = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX;
            if (c.sqlite3_open_v2(path_z.ptr, &read_db, flags, null) != c.SQLITE_OK) {
                read_db = null;
            }
        }
        return .{ .alloc = alloc, .config = config, .backend_type = .sqlite, .db = db, .read_db = read_db, .rocks = null, .pgconn = null };
    }

    fn initRocksDB(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        const path = if (config.db_name.len > 0) config.db_name else "rocksdb_data";
        const rc = try rocksdb.Client.init(alloc, path);
        return .{ .alloc = alloc, .config = config, .backend_type = .rocksdb, .db = null, .read_db = null, .rocks = rc, .pgconn = null };
    }

    fn initPostgreSQL(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        const conninfo = if (config.db_name.len > 0) config.db_name else "host=localhost port=5432 dbname=zponder";
        const conn = try pg.Client.init(alloc, conninfo);
        return .{ .alloc = alloc, .config = config, .backend_type = .postgresql, .db = null, .read_db = null, .rocks = null, .pgconn = conn };
    }

    pub fn getReadDb(self: *Client) ?*c.sqlite3 {
        return self.read_db orelse self.db;
    }

    pub fn deinit(self: *Client) void {
        switch (self.backend_type) {
            .sqlite => {
                if (self.read_db) |rdb| { _ = c.sqlite3_close(rdb); self.read_db = null; }
                if (self.db) |db| { _ = c.sqlite3_close(db); self.db = null; }
            },
            .rocksdb => { if (self.rocks) |*r| { r.deinit(); self.rocks = null; } },
            .postgresql => { if (self.pgconn) |*p| { p.deinit(); self.pgconn = null; } },
        }
    }

    pub fn setCache(self: *Client, cc: *cache.Cache) void {
        self.cache = cc;
    }

    pub fn migrate(self: *Client) !void {
        if (self.backend_type == .rocksdb) return;
        if (self.backend_type == .postgresql) return self.migratePG();
        const sql =
            \\CREATE TABLE IF NOT EXISTS sync_state (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  contract_address TEXT NOT NULL UNIQUE,
            \\  last_synced_block INTEGER NOT NULL DEFAULT 0,
            \\  status TEXT NOT NULL DEFAULT 'stopped',
            \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_sync_state_address ON sync_state(contract_address);
            \\
            \\CREATE TABLE IF NOT EXISTS account_states (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  contract_address TEXT NOT NULL,
            \\  account_address TEXT NOT NULL,
            \\  balance TEXT NOT NULL DEFAULT '0',
            \\  last_updated_block INTEGER NOT NULL DEFAULT 0,
            \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(contract_address, account_address)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_account_states ON account_states(contract_address, account_address);
            \\
            \\CREATE TABLE IF NOT EXISTS snapshots (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  contract_address TEXT NOT NULL,
            \\  block_number INTEGER NOT NULL,
            \\  snapshot_data TEXT NOT NULL,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_snapshots ON snapshots(contract_address, block_number);

            \\CREATE TABLE IF NOT EXISTS raw_logs (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  contract_address TEXT NOT NULL,
            \\  block_number INTEGER NOT NULL,
            \\  tx_hash TEXT NOT NULL,
            \\  log_index INTEGER NOT NULL,
            \\  topics TEXT NOT NULL,
            \\  data TEXT NOT NULL,
            \\  reason TEXT NOT NULL DEFAULT 'abi_mismatch',
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_raw_logs ON raw_logs(contract_address, block_number);

            \\CREATE TABLE IF NOT EXISTS block_hashes (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  contract_address TEXT NOT NULL,
            \\  block_number INTEGER NOT NULL,
            \\  block_hash TEXT NOT NULL,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(contract_address, block_number)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_block_hashes ON block_hashes(contract_address, block_number);

            \\CREATE TABLE IF NOT EXISTS blocks (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  block_number INTEGER NOT NULL,
            \\  block_hash TEXT NOT NULL,
            \\  timestamp INTEGER NOT NULL,
            \\  miner TEXT DEFAULT '',
            \\  gas_used INTEGER DEFAULT 0,
            \\  gas_limit INTEGER DEFAULT 0,
            \\  base_fee_per_gas TEXT DEFAULT '0',
            \\  transaction_count INTEGER DEFAULT 0,
            \\  chain TEXT NOT NULL DEFAULT '',
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(chain, block_number)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_blocks_chain_number ON blocks(chain, block_number);

            \\CREATE TABLE IF NOT EXISTS call_cache (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  cache_key TEXT NOT NULL UNIQUE,
            \\  result TEXT NOT NULL,
            \\  block_number INTEGER NOT NULL,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_call_cache_key ON call_cache(cache_key);

            \\CREATE TABLE IF NOT EXISTS template_addresses (
            \\  template TEXT NOT NULL,
            \\  address TEXT NOT NULL,
            \\  from_block INTEGER NOT NULL,
            \\  backfilled INTEGER NOT NULL DEFAULT 0,
            \\  PRIMARY KEY (template, address)
            \\);
        ;
        try self.exec(sql);
    }

    pub fn autoMigrateContract(
        self: *Client,
        contract_name: []const u8,
        abi_contract: *const abi.AbiContract,
        event_names: []const []const u8,
        contract_address: []const u8,
    ) !void {
        if (self.backend_type == .rocksdb) return;
        if (self.backend_type == .postgresql) return self.autoMigrateContractPG(contract_name, abi_contract, event_names, contract_address);
        for (event_names) |evt_name| {
            const evt = abi_contract.findEventByName(evt_name) orelse continue;
            // 老库（Task 1 之前建的表）缺 contract_address 列、唯一键也不含地址，先就地升级
            try self.migrateEventTableAddress(contract_name, evt, contract_address);
            try self.createEventTable(contract_name, evt); // 新建时是空操作（IF NOT EXISTS）
        }
    }

    /// 老库升级：确保事件表带 contract_address 列且唯一键含地址。
    /// 幂等：列已存在且唯一键已更新时是空操作。SQLite 无法 ALTER 唯一约束，
    /// 因此需要重建表并搬数据（回填 contract_address）。
    pub fn migrateEventTableAddress(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent, contract_address: []const u8) !void {
        if (self.backend_type == .rocksdb) return;
        if (self.backend_type == .postgresql) return self.migrateEventTableAddressPG(contract_name, evt, contract_address);

        const table = try std.fmt.allocPrint(self.alloc, "event_{s}_{s}", .{ contract_name, evt.name });
        defer self.alloc.free(table);

        // 1) 表不存在：按新结构建（IF NOT EXISTS，随后 createEventTable 是空操作）
        if (!try self.sqliteTableExists(table)) return self.createEventTable(contract_name, evt);

        // 2) 已有列 + 建表 DDL：两者都符合新结构时是空操作
        var old_cols: std.ArrayList([]u8) = .empty;
        defer {
            for (old_cols.items) |col| self.alloc.free(col);
            old_cols.deinit(self.alloc);
        }
        try self.sqliteTableColumns(table, &old_cols);
        const has_address = columnIndex(old_cols.items, "contract_address") != null;
        const ddl = try self.sqliteTableDdl(table);
        defer if (ddl) |d| self.alloc.free(d);
        const unique_ok = if (ddl) |d| blk: {
            break :blk (try ddlHasAddressUnique(self.alloc, d)) and !(try ddlHasLegacyUnique(self.alloc, d));
        } else false;
        if (has_address and unique_ok) return;

        // 3) 新结构列序（不含 contract_address：该列一律回填，不搬旧值）
        var owned_cols: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_cols.items) |col| self.alloc.free(col);
            owned_cols.deinit(self.alloc);
        }
        var new_cols: std.ArrayList([]const u8) = .empty;
        defer new_cols.deinit(self.alloc);
        try new_cols.append(self.alloc, "id");
        for (evt.inputs) |input| {
            const col = try self.sanitizeColumnName(input.name);
            try owned_cols.append(self.alloc, col);
            try new_cols.append(self.alloc, col);
        }
        try new_cols.append(self.alloc, "block_number");
        try new_cols.append(self.alloc, "tx_hash");
        try new_cols.append(self.alloc, "log_index");
        try new_cols.append(self.alloc, "created_at");

        // 只搬新旧结构都有的列（老表可能有 ABI 已删掉的列，或少列）
        var copy_cols: std.ArrayList([]const u8) = .empty;
        defer copy_cols.deinit(self.alloc);
        for (new_cols.items) |col| {
            if (columnIndex(old_cols.items, col) != null) try copy_cols.append(self.alloc, col);
        }

        const new_table = try std.fmt.allocPrint(self.alloc, "event_{s}_{s}__new", .{ contract_name, evt.name });
        defer self.alloc.free(new_table);

        // 4) 重建整个过程包在一个事务里：中途失败不留半张表
        try self.exec("BEGIN;");
        errdefer { _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, null); }

        {
            var ddl_buf: std.Io.Writer.Allocating = .init(self.alloc);
            defer ddl_buf.deinit();
            const w = &ddl_buf.writer;
            // 上一次中断可能留下半张 __new 表；在事务内清掉，避免整个迁移卡死
            try w.print("DROP TABLE IF EXISTS {s};\n", .{new_table});
            try w.print("CREATE TABLE {s} (", .{new_table});
            try self.writeEventTableBody(w, evt);
            try w.writeAll(";");
            var list = ddl_buf.toArrayList();
            defer list.deinit(self.alloc);
            try self.exec(list.items);
        }

        var moved: c_int = 0;
        {
            var ins_buf: std.Io.Writer.Allocating = .init(self.alloc);
            defer ins_buf.deinit();
            const w = &ins_buf.writer;
            try w.print("INSERT INTO {s} (", .{new_table});
            for (copy_cols.items) |col| try w.print("{s},", .{col});
            try w.writeAll("contract_address) SELECT ");
            for (copy_cols.items) |col| try w.print("{s},", .{col});
            if (has_address) {
                // 老表已有地址列：只回填空值，绝不覆盖已写入的真实地址
                try w.writeAll("CASE WHEN contract_address IS NULL OR contract_address = '' THEN ? ELSE contract_address END");
            } else {
                try w.writeAll("?");
            }
            try w.print(" FROM {s};", .{table});
            var list = ins_buf.toArrayList();
            defer list.deinit(self.alloc);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, list.items.ptr, @intCast(list.items.len), &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
            moved = c.sqlite3_changes(self.db);
        }

        {
            var ddl_buf: std.Io.Writer.Allocating = .init(self.alloc);
            defer ddl_buf.deinit();
            const w = &ddl_buf.writer;
            try w.print("DROP TABLE {s};\n", .{table});
            try w.print("ALTER TABLE {s} RENAME TO {s};", .{ new_table, table });
            try writeEventTableIndexes(w, contract_name, evt.name);
            var list = ddl_buf.toArrayList();
            defer list.deinit(self.alloc);
            try self.exec(list.items);
        }

        try self.exec("COMMIT;");
        log.info("事件表 {s} 已迁移：补 contract_address 列 + 地址唯一键（回填 {d} 行）", .{ table, moved });
    }

    fn sqliteTableExists(self: *Client, table: []const u8) !bool {
        const sql = try std.fmt.allocPrint(self.alloc, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='{s}';", .{table});
        defer self.alloc.free(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    fn sqliteTableColumns(self: *Client, table: []const u8, out: *std.ArrayList([]u8)) !void {
        const sql = try std.fmt.allocPrint(self.alloc, "PRAGMA table_info({s});", .{table});
        defer self.alloc.free(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.sliceTo(c.sqlite3_column_text(stmt, 1), 0);
            const dup = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(dup);
            try out.append(self.alloc, dup);
        }
    }

    fn sqliteTableDdl(self: *Client, table: []const u8) !?[]u8 {
        const sql = try std.fmt.allocPrint(self.alloc, "SELECT sql FROM sqlite_master WHERE type='table' AND name='{s}';", .{table});
        defer self.alloc.free(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
        return try self.alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0));
    }

    /// 事件表列定义 + 唯一键（CREATE TABLE 括号内部分）。
    /// 新建表与老表重建共用，避免两处 DDL 漂移。
    fn writeEventTableBody(self: *Client, w: *std.Io.Writer, evt: *const abi.AbiEvent) !void {
        try w.writeAll("\n  id INTEGER PRIMARY KEY AUTOINCREMENT,");
        for (evt.inputs) |input| {
            const col_name = try self.sanitizeColumnName(input.name);
            defer self.alloc.free(col_name);
            const sql_type = abi.abiTypeToSqlType(input.type);
            try w.print("\n  {s} {s},", .{ col_name, sql_type });
        }
        try w.writeAll("\n  block_number INTEGER NOT NULL,");
        try w.writeAll("\n  tx_hash TEXT NOT NULL,");
        try w.writeAll("\n  log_index INTEGER NOT NULL,");
        try w.writeAll("\n  contract_address TEXT NOT NULL DEFAULT '',");
        try w.writeAll("\n  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,");
        try w.writeAll("\n  UNIQUE(contract_address, tx_hash, log_index)\n)");
    }

    fn createEventTable(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent) !void {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("CREATE TABLE IF NOT EXISTS event_{s}_{s} (", .{ contract_name, evt.name });
        try self.writeEventTableBody(w, evt);
        try w.writeAll(";");
        try writeEventTableIndexes(w, contract_name, evt.name);
        var list = sql_buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.exec(list.items);
    }

    fn sanitizeColumnName(self: *Client, param_name: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, "evt_");
        for (param_name) |ch| {
            if (std.ascii.isAlphanumeric(ch)) {
                try buf.append(self.alloc, std.ascii.toLower(ch));
            } else {
                try buf.append(self.alloc, '_');
            }
        }
        return try self.alloc.dupe(u8, buf.items);
    }

    // ========================================================================
    // insertEventLog
    // ========================================================================
    pub fn insertEventLog(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const DecodedField,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        contract_address: []const u8,
    ) !void {
        if (self.backend_type == .rocksdb) return self.insertEventLogRocks(contract_name, event_name, fields, block_number, tx_hash, log_index, contract_address);
        if (self.backend_type == .postgresql) return self.insertEventLogPG(contract_name, event_name, fields, block_number, tx_hash, log_index, contract_address);

        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("INSERT INTO event_{s}_{s} (", .{ contract_name, event_name });
        for (fields, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            const col = try self.sanitizeColumnName(f.name);
            defer self.alloc.free(col);
            try w.writeAll(col);
        }
        try w.writeAll(",block_number,tx_hash,log_index,contract_address) VALUES (");
        for (fields, 0..) |_, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('?');
        }
        try w.writeAll(",?,?,?,?);");
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql_list.items.ptr, @intCast(sql_list.items.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var col_idx: c_int = 1;
        for (fields) |f| {
            if (c.sqlite3_bind_text(stmt, col_idx, f.value.ptr, @intCast(f.value.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            col_idx += 1;
        }
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_text(stmt, col_idx, tx_hash.ptr, @intCast(tx_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(log_index)) != c.SQLITE_OK) return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_text(stmt, col_idx, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    fn insertEventLogRocks(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const DecodedField,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        contract_address: []const u8,
    ) !void {
        // RocksDB 无 SQL，不支持模板模式/地址列（延后项，见 docs/superpowers/specs/2026-10-12-template-indexer-design.md）
        _ = contract_address;
        var key_buf: [512]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "e:{s}:{s}:{d:0>20}:{s}:{d:0>20}", .{ contract_name, event_name, block_number, tx_hash, log_index });
        var val_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer val_buf.deinit();
        try val_buf.writer.writeAll("{");
        for (fields, 0..) |f, i| {
            if (i > 0) try val_buf.writer.writeByte(',');
            try val_buf.writer.writeByte('"');
            try utils.jsonEscapeString(&val_buf.writer, f.name);
            try val_buf.writer.writeAll("\":\"");
            try utils.jsonEscapeString(&val_buf.writer, f.value);
            try val_buf.writer.writeByte('"');
        }
        try val_buf.writer.print(",\"block_number\":{d},\"tx_hash\":\"", .{block_number});
        try utils.jsonEscapeString(&val_buf.writer, tx_hash);
        try val_buf.writer.print("\",\"log_index\":{d}", .{log_index});
        try val_buf.writer.writeAll("}");
        var vl = val_buf.toArrayList();
        defer vl.deinit(self.alloc);
        try self.rocks.?.put(key, vl.items);
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    // ========================================================================
    // insertRawLog
    // ========================================================================
    pub fn insertRawLog(
        self: *Client,
        contract_address: []const u8,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        topics: []const u8,
        data: []const u8,
        reason: []const u8,
    ) !void {
        if (self.backend_type == .rocksdb) return self.insertRawLogRocks(contract_address, block_number, tx_hash, log_index, topics, data, reason);
        if (self.backend_type == .postgresql) return self.insertRawLogPG(contract_address, block_number, tx_hash, log_index, topics, data, reason);

        const sql = "INSERT INTO raw_logs (contract_address, block_number, tx_hash, log_index, topics, data, reason) VALUES (?, ?, ?, ?, ?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, tx_hash.ptr, @intCast(tx_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 4, @intCast(log_index)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 5, topics.ptr, @intCast(topics.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 6, data.ptr, @intCast(data.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 7, reason.ptr, @intCast(reason.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn insertRawLogRocks(
        self: *Client,
        contract_address: []const u8,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        topics: []const u8,
        data: []const u8,
        reason: []const u8,
    ) !void {
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "r:{s}:{d:0>20}:{s}:{d:0>20}", .{ contract_address, block_number, tx_hash, log_index });
        var val_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer val_buf.deinit();
        try val_buf.writer.print("{{\"topics\":\"", .{});
        try utils.jsonEscapeString(&val_buf.writer, topics);
        try val_buf.writer.print("\",\"data\":\"", .{});
        try utils.jsonEscapeString(&val_buf.writer, data);
        try val_buf.writer.print("\",\"reason\":\"", .{});
        try utils.jsonEscapeString(&val_buf.writer, reason);
        try val_buf.writer.writeAll("\"}");
        var vl = val_buf.toArrayList();
        defer vl.deinit(self.alloc);
        try self.rocks.?.put(key, vl.items);
    }

    // ========================================================================
    // queryEventLogs
    // ========================================================================
    pub fn queryEventLogs(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
        address: ?[]const u8,
        limit: u32,
        offset: u32,
        order_desc: bool,
    ) ![]u8 {
        if (self.backend_type == .rocksdb) return self.queryEventLogsRocks(contract_name, event_name, block_from, block_to, tx_hash, address, limit, offset, order_desc);
        if (self.backend_type == .postgresql) return self.queryEventLogsPG(contract_name, event_name, block_from, block_to, tx_hash, address, limit, offset, order_desc);

        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("SELECT * FROM event_{s}_{s} WHERE 1=1", .{ contract_name, event_name });
        if (block_from) |_| try w.writeAll(" AND block_number >= ?");
        if (block_to) |_| try w.writeAll(" AND block_number <= ?");
        if (tx_hash) |_| try w.writeAll(" AND tx_hash = ?");
        if (address) |_| try w.writeAll(" AND contract_address = ?");
        try w.writeAll(if (order_desc) " ORDER BY block_number DESC" else " ORDER BY block_number ASC");
        try w.writeAll(" LIMIT ? OFFSET ?;");
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql_list.items.ptr, @intCast(sql_list.items.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var bind_idx: c_int = 1;
        if (block_from) |bf| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bf)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (block_to) |bt| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bt)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (tx_hash) |th| { if (c.sqlite3_bind_text(stmt, bind_idx, th.ptr, @intCast(th.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (address) |ad| { if (c.sqlite3_bind_text(stmt, bind_idx, ad.ptr, @intCast(ad.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(limit)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1;
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(offset)) != c.SQLITE_OK) return error.BindFailed;
        var result_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer result_buf.deinit();
        const rw = &result_buf.writer;
        try rw.writeByte('[');
        var row_count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (row_count > 0) try rw.writeByte(',');
            try rw.writeByte('{');
            const col_count = c.sqlite3_column_count(stmt);
            var col_idx: c_int = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                if (col_idx > 0) try rw.writeByte(',');
                const col_name = std.mem.sliceTo(c.sqlite3_column_name(stmt, col_idx), 0);
                try rw.print("\"{s}\":", .{col_name});
                const col_type = c.sqlite3_column_type(stmt, col_idx);
                switch (col_type) {
                    c.SQLITE_INTEGER => { try rw.print("{}", .{c.sqlite3_column_int64(stmt, col_idx)}); },
                    c.SQLITE_FLOAT => { try rw.print("{}", .{c.sqlite3_column_double(stmt, col_idx)}); },
                    c.SQLITE_NULL => try rw.writeAll("null"),
                    else => {
                        const val = std.mem.sliceTo(c.sqlite3_column_text(stmt, col_idx), 0);
                        try rw.writeByte('"');
                        try utils.jsonEscapeString(rw, val);
                        try rw.writeByte('"');
                    },
                }
            }
            try rw.writeByte('}');
            row_count += 1;
        }
        try rw.writeByte(']');
        var list = result_buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }

    fn queryEventLogsRocks(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
        address: ?[]const u8,
        limit: u32,
        offset: u32,
        _: bool,
    ) ![]u8 {
        // RocksDB 事件 key 不含地址列（见 task-3 遗留项）。带地址过滤时无法只返回
        // 该地址的行——静默返回全量会给出错误答案，故与模板模式的 RocksDB 行为一致
        // 直接报不支持；地址为 null 时行为不变。
        if (address != null) return error.UnsupportedOperation;
        var prefix_buf: [256]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "e:{s}:{s}:", .{ contract_name, event_name });
        var seek_buf: [256]u8 = undefined;
        const seek_key = if (block_from) |bf|
            try std.fmt.bufPrint(&seek_buf, "e:{s}:{s}:{d:0>20}:", .{ contract_name, event_name, bf })
        else
            prefix;
        var end_buf: [256]u8 = undefined;
        const end_key = if (block_to) |bt|
            try std.fmt.bufPrint(&end_buf, "e:{s}:{s}:{d:0>20}:\xff", .{ contract_name, event_name, bt })
        else
            try std.fmt.bufPrint(&end_buf, "e:{s}:{s}:\xff", .{ contract_name, event_name });

        var iter = self.rocks.?.iterator();
        defer iter.deinit();
        iter.seek(seek_key);

        var result_buf = std.ArrayList(u8).empty;
        defer result_buf.deinit(self.alloc);
        try result_buf.append(self.alloc, '[');

        var row_count: u32 = 0;
        var skipped: u32 = 0;
        while (iter.valid() and row_count < limit) {
            const key = iter.key();
            if (std.mem.order(u8, key, end_key) != .lt) break;

            if (skipped < offset) {
                skipped += 1;
                iter.next();
                continue;
            }

            const val = iter.value();
            if (tx_hash) |th| {
                if (std.mem.indexOf(u8, val, th) == null) { iter.next(); continue; }
            }

            if (row_count > 0) try result_buf.append(self.alloc, ',');
            try result_buf.appendSlice(self.alloc, val);
            row_count += 1;
            iter.next();
        }
        try result_buf.append(self.alloc, ']');
        return try result_buf.toOwnedSlice(self.alloc);
    }

    // ========================================================================
    // sync_state
    // ========================================================================
    pub fn getSyncState(self: *Client, contract_address: []const u8) !?SyncState {
        if (self.backend_type == .rocksdb) return self.getSyncStateRocks(contract_address);
        if (self.backend_type == .postgresql) return self.getSyncStatePG(contract_address);

        const sql = "SELECT contract_address, last_synced_block, status FROM sync_state WHERE contract_address = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const addr = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            const block = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 1)));
            const status = std.mem.sliceTo(c.sqlite3_column_text(stmt, 2), 0);
            return SyncState{ .contract_address = try self.alloc.dupe(u8, addr), .last_synced_block = block, .status = try self.alloc.dupe(u8, status) };
        }
        return null;
    }

    fn getSyncStateRocks(self: *Client, contract_address: []const u8) !?SyncState {
        var key_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "s:{s}", .{contract_address});
        const val = try self.rocks.?.get(key) orelse return null;
        defer self.alloc.free(val);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, val, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const block_val = obj.get("last_synced_block") orelse return error.InvalidData;
        const block: u64 = switch (block_val) {
            .integer => |v| @intCast(v),
            .float => |v| @intFromFloat(v),
            else => return error.InvalidData,
        };
        const status = if (obj.get("status")) |s| switch (s) { .string => |v| v, else => "stopped" } else "stopped";
        return SyncState{ .contract_address = try self.alloc.dupe(u8, contract_address), .last_synced_block = block, .status = try self.alloc.dupe(u8, status) };
    }

    pub fn upsertSyncState(self: *Client, state: SyncState) !void {
        if (self.backend_type == .rocksdb) return self.upsertSyncStateRocks(state);
        if (self.backend_type == .postgresql) return self.upsertSyncStatePG(state);

        const sql =
            \\INSERT INTO sync_state (contract_address, last_synced_block, status, updated_at)
            \\VALUES (?, ?, ?, CURRENT_TIMESTAMP)
            \\ON CONFLICT(contract_address) DO UPDATE SET
            \\  last_synced_block = excluded.last_synced_block,
            \\  status = excluded.status,
            \\  updated_at = CURRENT_TIMESTAMP;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, state.contract_address.ptr, @intCast(state.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(state.last_synced_block)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, state.status.ptr, @intCast(state.status.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn upsertSyncStateRocks(self: *Client, state: SyncState) !void {
        var key_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "s:{s}", .{state.contract_address});
        var val_buf: [256]u8 = undefined;
        const val = try std.fmt.bufPrint(&val_buf, "{{\"last_synced_block\":{d},\"status\":\"{s}\"}}", .{ state.last_synced_block, state.status });
        try self.rocks.?.put(key, val);
    }

    // ========================================================================
    // template_addresses：模板模式下动态发现的 clone 地址集合
    // 表由 Client.migrate() 建（SQLite / PostgreSQL），RocksDB 未实现。
    // 读写走 ponderExec/ponderQuery 参数化路径，占位符随后端切换（? / $n）。
    // ========================================================================

    /// 登记模板动态发现的 clone 地址（幂等）。
    /// ON CONFLICT(template, address) DO NOTHING：同一地址重复发现不覆盖已有
    /// from_block/backfilled 进度。落库失败向上返回，由调用方决定是否阻断。
    pub fn addTemplateAddress(self: *Client, template: []const u8, address: []const u8, from_block: u64) !void {
        if (self.backend_type == .rocksdb) return error.UnsupportedOperation;
        const sql = if (self.backend_type == .postgresql)
            "INSERT INTO template_addresses (template, address, from_block) VALUES ($1, $2, $3) ON CONFLICT(template, address) DO NOTHING;"
        else
            "INSERT INTO template_addresses (template, address, from_block) VALUES (?, ?, ?) ON CONFLICT(template, address) DO NOTHING;";
        _ = try self.ponderExec(sql, &.{ .{ .text = template }, .{ .text = address }, .{ .integer = @intCast(from_block) } });
    }

    /// 列出模板持有的全部 clone 地址（按 from_block、address 排序，仅供稳定/可复现输出）。
    /// 不得据此推断同块内的发现顺序：同块发现的行 from_block 相同，排序退化为地址字典序
    /// （跨后端 collation 还不一致），也表达不出 log_index。
    /// 内存约定同 getSyncState：返回堆数组，调用方负责释放——
    /// `for (list) |item| alloc.free(item.address);` 之后 `alloc.free(list)`。
    pub fn listTemplateAddresses(self: *Client, template: []const u8) ![]TemplateAddress {
        if (self.backend_type == .rocksdb) return error.UnsupportedOperation;
        const sql = if (self.backend_type == .postgresql)
            "SELECT address, from_block, backfilled FROM template_addresses WHERE template = $1 ORDER BY from_block, address;"
        else
            "SELECT address, from_block, backfilled FROM template_addresses WHERE template = ? ORDER BY from_block, address;";
        const rows = try self.ponderQuery(sql, &.{.{ .text = template }});
        defer self.freeQueryRows(rows);

        const list = try self.alloc.alloc(TemplateAddress, rows.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |item| self.alloc.free(item.address);
            self.alloc.free(list);
        }
        for (rows, 0..) |row, i| {
            const addr_text = switch (row.values[0]) {
                .text => |t| t,
                else => return error.InvalidData,
            };
            const from_block = switch (row.values[1]) {
                .integer => |v| @as(u64, @intCast(v)),
                else => return error.InvalidData,
            };
            const backfilled = switch (row.values[2]) {
                .integer => |v| v != 0,
                else => return error.InvalidData,
            };
            list[i] = .{
                .address = try self.alloc.dupe(u8, addr_text),
                .from_block = from_block,
                .backfilled = backfilled,
            };
            filled = i + 1;
        }
        return list;
    }

    /// 标记某 clone 的历史区间已回填完成。
    pub fn markTemplateAddressBackfilled(self: *Client, template: []const u8, address: []const u8) !void {
        if (self.backend_type == .rocksdb) return error.UnsupportedOperation;
        const sql = if (self.backend_type == .postgresql)
            "UPDATE template_addresses SET backfilled = 1 WHERE template = $1 AND address = $2;"
        else
            "UPDATE template_addresses SET backfilled = 1 WHERE template = ? AND address = ?;";
        _ = try self.ponderExec(sql, &.{ .{ .text = template }, .{ .text = address } });
    }

    /// reorg 回滚：删除该模板中 from_block >= 给定块的 clone 地址。
    pub fn deleteTemplateAddressesFromBlock(self: *Client, template: []const u8, from_block: u64) !void {
        if (self.backend_type == .rocksdb) return error.UnsupportedOperation;
        const sql = if (self.backend_type == .postgresql)
            "DELETE FROM template_addresses WHERE template = $1 AND from_block >= $2;"
        else
            "DELETE FROM template_addresses WHERE template = ? AND from_block >= ?;";
        _ = try self.ponderExec(sql, &.{ .{ .text = template }, .{ .integer = @intCast(from_block) } });
    }

    // ========================================================================
    // account_states
    // ========================================================================
    pub fn upsertAccountState(self: *Client, state: AccountState) !void {
        if (self.backend_type == .rocksdb) return self.upsertAccountStateRocks(state);
        if (self.backend_type == .postgresql) return self.upsertAccountStatePG(state);

        const sql =
            \\INSERT INTO account_states (contract_address, account_address, balance, last_updated_block, updated_at)
            \\VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
            \\ON CONFLICT(contract_address, account_address) DO UPDATE SET
            \\  balance = excluded.balance,
            \\  last_updated_block = excluded.last_updated_block,
            \\  updated_at = CURRENT_TIMESTAMP;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, state.contract_address.ptr, @intCast(state.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, state.account_address.ptr, @intCast(state.account_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, state.balance.ptr, @intCast(state.balance.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 4, @intCast(state.last_updated_block)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn upsertAccountStateRocks(self: *Client, state: AccountState) !void {
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "a:{s}:{s}", .{ state.contract_address, state.account_address });
        var val_buf: [256]u8 = undefined;
        const val = try std.fmt.bufPrint(&val_buf, "{{\"balance\":\"{s}\",\"last_updated_block\":{d}}}", .{ state.balance, state.last_updated_block });
        try self.rocks.?.put(key, val);
    }

    pub fn getAccountBalance(self: *Client, contract_address: []const u8, account_address: []const u8) !?[]const u8 {
        if (self.backend_type == .rocksdb) return self.getAccountBalanceRocks(contract_address, account_address);
        if (self.backend_type == .postgresql) return self.getAccountBalancePG(contract_address, account_address);

        const sql = "SELECT balance FROM account_states WHERE contract_address = ? AND account_address = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.getReadDb(), sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, account_address.ptr, @intCast(account_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const bal = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            return try self.alloc.dupe(u8, bal);
        }
        return null;
    }

    fn getAccountBalanceRocks(self: *Client, contract_address: []const u8, account_address: []const u8) !?[]const u8 {
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "a:{s}:{s}", .{ contract_address, account_address });
        const val = try self.rocks.?.get(key) orelse return null;
        defer self.alloc.free(val);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, val, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("balance")) |b| {
            if (b == .string) return try self.alloc.dupe(u8, b.string);
        }
        return null;
    }

    // ========================================================================
    // deleteEventLogsInRange
    // ========================================================================
    pub fn deleteEventLogsInRange(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        if (self.backend_type == .rocksdb) return self.deleteEventLogsInRangeRocks(contract_name, event_name, from_block, to_block);
        if (self.backend_type == .postgresql) return self.deleteEventLogsInRangePG(contract_name, event_name, from_block, to_block);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "DELETE FROM event_{s}_{s} WHERE block_number >= ? AND block_number <= ?;", .{ contract_name, event_name });
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, @intCast(from_block)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(to_block)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    fn deleteEventLogsInRangeRocks(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        var prefix_buf: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "e:{s}:{s}:", .{ contract_name, event_name });
        var seek_buf: [256]u8 = undefined;
        const seek_key = try std.fmt.bufPrint(&seek_buf, "e:{s}:{s}:{d:0>20}:", .{ contract_name, event_name, from_block });
        var end_buf: [256]u8 = undefined;
        const end_key = try std.fmt.bufPrint(&end_buf, "e:{s}:{s}:{d:0>20}:\xff", .{ contract_name, event_name, to_block });

        var batch = rocksdb.WriteBatch.init();
        defer batch.deinit();
        var iter = self.rocks.?.iterator();
        defer iter.deinit();
        iter.seek(seek_key);
        while (iter.valid()) {
            const key = iter.key();
            if (std.mem.order(u8, key, end_key) != .lt) break;
            batch.delete(key);
            iter.next();
        }
        try self.rocks.?.writeBatch(&batch);
        _ = prefix; // suppress unused warning
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    // ========================================================================
    // snapshots
    // ========================================================================
    pub fn createSnapshot(self: *Client, snapshot: Snapshot) !void {
        if (self.backend_type == .rocksdb) return self.createSnapshotRocks(snapshot);
        if (self.backend_type == .postgresql) return self.createSnapshotPG(snapshot);

        const sql = "INSERT INTO snapshots (contract_address, block_number, snapshot_data) VALUES (?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, snapshot.contract_address.ptr, @intCast(snapshot.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(snapshot.block_number)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, snapshot.snapshot_data.ptr, @intCast(snapshot.snapshot_data.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn createSnapshotRocks(self: *Client, snapshot: Snapshot) !void {
        var key_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "p:{s}:{d:0>20}", .{ snapshot.contract_address, snapshot.block_number });
        try self.rocks.?.put(key, snapshot.snapshot_data);
    }

    pub fn getLatestSnapshot(self: *Client, contract_address: []const u8) !?Snapshot {
        if (self.backend_type == .rocksdb) return self.getLatestSnapshotRocks(contract_address);
        if (self.backend_type == .postgresql) return self.getLatestSnapshotPG(contract_address);

        const sql = "SELECT contract_address, block_number, snapshot_data FROM snapshots WHERE contract_address = ? ORDER BY block_number DESC LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const addr = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            const block = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 1)));
            const data = std.mem.sliceTo(c.sqlite3_column_text(stmt, 2), 0);
            return Snapshot{ .contract_address = try self.alloc.dupe(u8, addr), .block_number = block, .snapshot_data = try self.alloc.dupe(u8, data) };
        }
        return null;
    }

    fn getLatestSnapshotRocks(self: *Client, contract_address: []const u8) !?Snapshot {
        var prefix_buf: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "p:{s}:", .{contract_address});
        var iter = self.rocks.?.iterator();
        defer iter.deinit();
        // seek to latest: use prefix + max key
        var seek_buf: [256]u8 = undefined;
        const seek_key = try std.fmt.bufPrint(&seek_buf, "p:{s}:\xff", .{contract_address});
        iter.seek(seek_key);
        // seek_to_last not in C API; seek past prefix and walk backwards
        // For simplicity: seek to prefix and walk to last
        iter.seek(prefix);
        var last_key: ?[]const u8 = null;
        var last_val: ?[]const u8 = null;
        while (iter.valid()) {
            const k = iter.key();
            if (!std.mem.startsWith(u8, k, prefix)) break;
            last_key = k;
            last_val = iter.value();
            iter.next();
        }
        if (last_val) |v| {
            if (last_key) |k| {
                // extract block number from key: "p:{addr}:{block}"
                const block_str = k[prefix.len..];
                const block = std.fmt.parseInt(u64, block_str, 10) catch 0;
                return Snapshot{ .contract_address = try self.alloc.dupe(u8, contract_address), .block_number = block, .snapshot_data = try self.alloc.dupe(u8, v) };
            }
        }
        return null;
    }

    // ========================================================================
    // block_hashes
    // ========================================================================
    pub fn upsertBlockHash(self: *Client, contract_address: []const u8, block_number: u64, block_hash: []const u8) !void {
        if (self.backend_type == .rocksdb) return self.upsertBlockHashRocks(contract_address, block_number, block_hash);
        if (self.backend_type == .postgresql) return self.upsertBlockHashPG(contract_address, block_number, block_hash);

        const sql =
            \\INSERT INTO block_hashes (contract_address, block_number, block_hash)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(contract_address, block_number) DO UPDATE SET
            \\  block_hash = excluded.block_hash;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, block_hash.ptr, @intCast(block_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn upsertBlockHashRocks(self: *Client, contract_address: []const u8, block_number: u64, block_hash: []const u8) !void {
        var key_buf: [192]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "h:{s}:{d:0>20}", .{ contract_address, block_number });
        try self.rocks.?.put(key, block_hash);
    }

    pub fn getBlockHash(self: *Client, contract_address: []const u8, block_number: u64) !?[]u8 {
        if (self.backend_type == .rocksdb) return self.getBlockHashRocks(contract_address, block_number);
        if (self.backend_type == .postgresql) return self.getBlockHashPG(contract_address, block_number);

        const sql = "SELECT block_hash FROM block_hashes WHERE contract_address = ? AND block_number = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const hash = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            return try self.alloc.dupe(u8, hash);
        }
        return null;
    }

    fn getBlockHashRocks(self: *Client, contract_address: []const u8, block_number: u64) !?[]u8 {
        var key_buf: [192]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "h:{s}:{d:0>20}", .{ contract_address, block_number });
        return try self.rocks.?.get(key);
    }

    // ========================================================================
    // blocks
    // ========================================================================
    pub fn upsertBlock(self: *Client, block: BlockRecord) !void {
        if (self.backend_type == .rocksdb) return self.upsertBlockRocks(block);
        if (self.backend_type == .postgresql) return self.upsertBlockPG(block);

        const sql =
            \\INSERT INTO blocks (block_number, block_hash, timestamp, miner, gas_used, gas_limit, base_fee_per_gas, transaction_count, chain)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(chain, block_number) DO UPDATE SET
            \\  block_hash = excluded.block_hash,
            \\  timestamp = excluded.timestamp,
            \\  miner = excluded.miner,
            \\  gas_used = excluded.gas_used,
            \\  gas_limit = excluded.gas_limit,
            \\  base_fee_per_gas = excluded.base_fee_per_gas,
            \\  transaction_count = excluded.transaction_count;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, @intCast(block.block_number)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, block.block_hash.ptr, @intCast(block.block_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 3, @intCast(block.timestamp)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 4, block.miner.ptr, @intCast(block.miner.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 5, @intCast(block.gas_used)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 6, @intCast(block.gas_limit)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 7, block.base_fee_per_gas.ptr, @intCast(block.base_fee_per_gas.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 8, @intCast(block.transaction_count)) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 9, block.chain.ptr, @intCast(block.chain.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.ExecFailed;
    }

    fn upsertBlockRocks(self: *Client, block: BlockRecord) !void {
        var key_buf: [192]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "b:{s}:{d:0>20}", .{ block.chain, block.block_number });
        const value = try std.json.Stringify.valueAlloc(self.alloc, block, .{});
        defer self.alloc.free(value);
        try self.rocks.?.put(key, value);
    }

    fn upsertBlockPG(self: *Client, block: BlockRecord) !void {
        const sql =
            \\INSERT INTO blocks (block_number, block_hash, timestamp, miner, gas_used, gas_limit, base_fee_per_gas, transaction_count, chain)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            \\ON CONFLICT(chain, block_number) DO UPDATE SET
            \\  block_hash = EXCLUDED.block_hash,
            \\  timestamp = EXCLUDED.timestamp,
            \\  miner = EXCLUDED.miner,
            \\  gas_used = EXCLUDED.gas_used,
            \\  gas_limit = EXCLUDED.gas_limit,
            \\  base_fee_per_gas = EXCLUDED.base_fee_per_gas,
            \\  transaction_count = EXCLUDED.transaction_count;
        ;
        var block_num_buf: [32]u8 = undefined;
        var ts_buf: [32]u8 = undefined;
        var gu_buf: [32]u8 = undefined;
        var gl_buf: [32]u8 = undefined;
        var tc_buf: [32]u8 = undefined;
        const args = [_][]const u8{
            try std.fmt.bufPrint(&block_num_buf, "{d}", .{block.block_number}),
            block.block_hash,
            try std.fmt.bufPrint(&ts_buf, "{d}", .{block.timestamp}),
            block.miner,
            try std.fmt.bufPrint(&gu_buf, "{d}", .{block.gas_used}),
            try std.fmt.bufPrint(&gl_buf, "{d}", .{block.gas_limit}),
            block.base_fee_per_gas,
            try std.fmt.bufPrint(&tc_buf, "{d}", .{block.transaction_count}),
            block.chain,
        };
        _ = try self.pgconn.?.execParams(sql, &args);
    }

    pub fn queryBlocks(
        self: *Client,
        chain: []const u8,
        from_block: ?u64,
        to_block: ?u64,
        limit: u32,
        offset: u32,
    ) ![]u8 {
        if (self.backend_type == .rocksdb) return self.queryBlocksRocks(chain, from_block, to_block, limit, offset);
        if (self.backend_type == .postgresql) return self.queryBlocksPG(chain, from_block, to_block, limit, offset);

        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.writeAll("SELECT * FROM blocks WHERE chain = ?");
        if (from_block) |_| try w.writeAll(" AND block_number >= ?");
        if (to_block) |_| try w.writeAll(" AND block_number <= ?");
        try w.writeAll(" ORDER BY block_number DESC LIMIT ? OFFSET ?;");
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.getReadDb(), sql_list.items.ptr, @intCast(sql_list.items.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var bind_idx: c_int = 1;
        if (c.sqlite3_bind_text(stmt, bind_idx, chain.ptr, @intCast(chain.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        bind_idx += 1;
        if (from_block) |bf| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bf)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (to_block) |bt| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bt)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(limit)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1;
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(offset)) != c.SQLITE_OK) return error.BindFailed;

        var result_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer result_buf.deinit();
        const rw = &result_buf.writer;
        try rw.writeByte('[');
        var row_count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (row_count > 0) try rw.writeByte(',');
            try rw.writeByte('{');
            const col_count = c.sqlite3_column_count(stmt);
            var col_idx: c_int = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                if (col_idx > 0) try rw.writeByte(',');
                const col_name = std.mem.sliceTo(c.sqlite3_column_name(stmt, col_idx), 0);
                try rw.print("\"{s}\":", .{col_name});
                const col_type = c.sqlite3_column_type(stmt, col_idx);
                switch (col_type) {
                    c.SQLITE_INTEGER => try rw.print("{}", .{c.sqlite3_column_int64(stmt, col_idx)}),
                    c.SQLITE_FLOAT => try rw.print("{}", .{c.sqlite3_column_double(stmt, col_idx)}),
                    c.SQLITE_NULL => try rw.writeAll("null"),
                    else => {
                        const val = std.mem.sliceTo(c.sqlite3_column_text(stmt, col_idx), 0);
                        try rw.writeByte('"');
                        try utils.jsonEscapeString(rw, val);
                        try rw.writeByte('"');
                    },
                }
            }
            try rw.writeByte('}');
            row_count += 1;
        }
        try rw.writeByte(']');
        var list = result_buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }

    fn queryBlocksRocks(self: *Client, chain: []const u8, from_block: ?u64, to_block: ?u64, limit: u32, offset: u32) ![]u8 {
        var prefix_buf: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "b:{s}:", .{chain});
        var seek_buf: [256]u8 = undefined;
        const seek_key = if (from_block) |bf|
            try std.fmt.bufPrint(&seek_buf, "b:{s}:{d:0>20}", .{ chain, bf })
        else
            prefix;
        var end_buf: [256]u8 = undefined;
        const end_key = if (to_block) |bt|
            try std.fmt.bufPrint(&end_buf, "b:{s}:{d:0>20}:\xff", .{ chain, bt })
        else
            try std.fmt.bufPrint(&end_buf, "b:{s}:\xff", .{chain});

        var iter = self.rocks.?.iterator();
        defer iter.deinit();
        iter.seek(seek_key);

        var result_buf = std.ArrayList(u8).empty;
        defer result_buf.deinit(self.alloc);
        try result_buf.append(self.alloc, '[');
        var row_count: u32 = 0;
        var skipped: u32 = 0;
        while (iter.valid() and row_count < limit) {
            const key = iter.key();
            if (std.mem.order(u8, key, end_key) != .lt) break;
            if (skipped < offset) { skipped += 1; iter.next(); continue; }
            if (row_count > 0) try result_buf.append(self.alloc, ',');
            try result_buf.appendSlice(self.alloc, iter.value());
            row_count += 1;
            iter.next();
        }
        try result_buf.append(self.alloc, ']');
        return try result_buf.toOwnedSlice(self.alloc);
    }

    fn queryBlocksPG(self: *Client, chain: []const u8, from_block: ?u64, to_block: ?u64, limit: u32, offset: u32) ![]u8 {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.writeAll("SELECT * FROM blocks WHERE chain = $1");
        var param_count: usize = 1;
        if (from_block != null) { param_count += 1; try w.print(" AND block_number >= ${d}", .{param_count}); }
        if (to_block != null) { param_count += 1; try w.print(" AND block_number <= ${d}", .{param_count}); }
        param_count += 1; try w.print(" ORDER BY block_number DESC LIMIT ${d}", .{param_count});
        param_count += 1; try w.print(" OFFSET ${d}", .{param_count});
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var args = std.ArrayList([]const u8).init(self.alloc);
        defer args.deinit();
        try args.append(chain);
        if (from_block) |fb| {
            const buf = try self.alloc.alloc(u8, 32);
            _ = try std.fmt.bufPrint(buf, "{d}", .{fb});
            try args.append(buf);
        }
        if (to_block) |tb| {
            const buf = try self.alloc.alloc(u8, 32);
            _ = try std.fmt.bufPrint(buf, "{d}", .{tb});
            try args.append(buf);
        }
        {
            const buf = try self.alloc.alloc(u8, 32);
            _ = try std.fmt.bufPrint(buf, "{d}", .{limit});
            try args.append(buf);
        }
        {
            const buf = try self.alloc.alloc(u8, 32);
            _ = try std.fmt.bufPrint(buf, "{d}", .{offset});
            try args.append(buf);
        }
        defer for (args.items) |a| self.alloc.free(a);
        return try self.pgconn.?.execParams(sql_list.items, args.items);
    }

    // ========================================================================
    // call_cache
    // ========================================================================
    pub fn getCachedCall(self: *Client, cache_key: []const u8) !?[]u8 {
        if (self.backend_type == .rocksdb) {
            var key_buf: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "c:{s}", .{cache_key});
            return try self.rocks.?.get(key);
        }
        if (self.backend_type == .postgresql) {
            const sql = "SELECT result FROM call_cache WHERE cache_key = $1;";
            var result = try self.pgconn.?.execParams(sql, &.{cache_key});
            defer result.deinit();
            if (result.rows() > 0 and !result.isNull(0, 0)) {
                const val = result.get(0, 0);
                return try self.alloc.dupe(u8, val);
            }
            return null;
        }
        const sql = "SELECT result FROM call_cache WHERE cache_key = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.getReadDb(), sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, cache_key.ptr, @intCast(cache_key.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const val = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            return try self.alloc.dupe(u8, val);
        }
        return null;
    }

    pub fn setCachedCall(self: *Client, cache_key: []const u8, result: []const u8, block_number: u64) !void {
        if (self.backend_type == .rocksdb) {
            var key_buf: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "c:{s}", .{cache_key});
            const value = try std.fmt.allocPrint(self.alloc, "{{\"result\":\"{s}\",\"block_number\":{d}}}", .{ result, block_number });
            defer self.alloc.free(value);
            try self.rocks.?.put(key, value);
            return;
        }
        if (self.backend_type == .postgresql) {
            var bn_buf: [32]u8 = undefined;
            const bn_str = try std.fmt.bufPrint(&bn_buf, "{d}", .{block_number});
            const sql =
                \\INSERT INTO call_cache (cache_key, result, block_number)
                \\VALUES ($1, $2, $3)
                \\ON CONFLICT(cache_key) DO UPDATE SET result = EXCLUDED.result, block_number = EXCLUDED.block_number;
            ;
            _ = try self.pgconn.?.execParams(sql, &.{ cache_key, result, bn_str });
            return;
        }
        const sql =
            \\INSERT INTO call_cache (cache_key, result, block_number)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(cache_key) DO UPDATE SET result = excluded.result, block_number = excluded.block_number;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, cache_key.ptr, @intCast(cache_key.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, result.ptr, @intCast(result.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 3, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.ExecFailed;
    }

    // ========================================================================
    // rollback
    // ========================================================================
    pub fn rollbackFromBlock(self: *Client, contract_address: []const u8, contract_name: []const u8, event_names: []const []const u8, from_block: u64) !void {
        if (self.backend_type == .rocksdb) return self.rollbackFromBlockRocks(contract_address, contract_name, event_names, from_block);
        if (self.backend_type == .postgresql) return self.rollbackFromBlockPG(contract_address, contract_name, event_names, from_block);

        try self.exec("BEGIN;");
        errdefer { _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, null); }
        for (event_names) |evt_name| {
            var sql_buf: [256]u8 = undefined;
            const sql = try std.fmt.bufPrint(&sql_buf, "DELETE FROM event_{s}_{s} WHERE block_number >= ?;", .{ contract_name, evt_name });
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_int64(stmt, 1, @intCast(from_block)) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        }
        {
            const sql = "DELETE FROM snapshots WHERE contract_address = ? AND block_number >= ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_bind_int64(stmt, 2, @intCast(from_block)) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        }
        {
            const sql = "DELETE FROM block_hashes WHERE contract_address = ? AND block_number >= ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_bind_int64(stmt, 2, @intCast(from_block)) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        }
        {
            const sql = "UPDATE sync_state SET last_synced_block = ? - 1, status = 'reorg_rollback' WHERE contract_address = ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_int64(stmt, 1, @intCast(from_block)) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_bind_text(stmt, 2, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.ExecFailed;
        }
        // 业务投影表级联回滚：proj_* 前缀约定 + block_number 列
        {
            var proj_names: std.ArrayList([]u8) = .empty;
            defer {
                for (proj_names.items) |n| self.alloc.free(n);
                proj_names.deinit(self.alloc);
            }
            {
                const sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'proj\\_%' ESCAPE '\\';";
                var stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) == c.SQLITE_OK) {
                    defer _ = c.sqlite3_finalize(stmt);
                    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                        const name = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
                        const dup = self.alloc.dupe(u8, name) catch continue;
                        proj_names.append(self.alloc, dup) catch self.alloc.free(dup);
                    }
                }
            }
            for (proj_names.items) |tbl| {
                var del_buf: [512]u8 = undefined;
                const del_sql = std.fmt.bufPrint(&del_buf, "DELETE FROM \"{s}\" WHERE block_number >= ?;", .{tbl}) catch continue;
                var dstmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, del_sql.ptr, @intCast(del_sql.len), &dstmt, null) != c.SQLITE_OK) continue;
                defer _ = c.sqlite3_finalize(dstmt);
                if (c.sqlite3_bind_int64(dstmt, 1, @intCast(from_block)) != c.SQLITE_OK) continue;
                if (c.sqlite3_step(dstmt) != c.SQLITE_DONE) continue;
            }
            if (proj_names.items.len > 0) {
                log.info("重组回滚：级联清理 {d} 张投影表 (block >= {d})", .{ proj_names.items.len, from_block });
            }
        }
        try self.exec("COMMIT;");
    }

    fn rollbackFromBlockRocks(self: *Client, contract_address: []const u8, contract_name: []const u8, event_names: []const []const u8, from_block: u64) !void {
        var batch = rocksdb.WriteBatch.init();
        defer batch.deinit();
        for (event_names) |evt_name| {
            var prefix_buf: [128]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "e:{s}:{s}:", .{ contract_name, evt_name });
            var seek_buf: [256]u8 = undefined;
            const seek_key = try std.fmt.bufPrint(&seek_buf, "e:{s}:{s}:{d:0>20}:", .{ contract_name, evt_name, from_block });
            var iter = self.rocks.?.iterator();
            iter.seek(seek_key);
            while (iter.valid()) {
                const k = iter.key();
                if (!std.mem.startsWith(u8, k, prefix)) break;
                batch.delete(k);
                iter.next();
            }
            iter.deinit();
        }
        // delete snapshots >= from_block
        {
            var prefix_buf: [128]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "p:{s}:", .{contract_address});
            var seek_buf: [256]u8 = undefined;
            const seek_key = try std.fmt.bufPrint(&seek_buf, "p:{s}:{d:0>20}", .{ contract_address, from_block });
            var iter = self.rocks.?.iterator();
            iter.seek(seek_key);
            while (iter.valid()) {
                const k = iter.key();
                if (!std.mem.startsWith(u8, k, prefix)) break;
                batch.delete(k);
                iter.next();
            }
            iter.deinit();
        }
        // delete block_hashes >= from_block
        {
            var prefix_buf: [128]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "h:{s}:", .{contract_address});
            var seek_buf: [256]u8 = undefined;
            const seek_key = try std.fmt.bufPrint(&seek_buf, "h:{s}:{d:0>20}", .{ contract_address, from_block });
            var iter = self.rocks.?.iterator();
            iter.seek(seek_key);
            while (iter.valid()) {
                const k = iter.key();
                if (!std.mem.startsWith(u8, k, prefix)) break;
                batch.delete(k);
                iter.next();
            }
            iter.deinit();
        }
        try self.rocks.?.writeBatch(&batch);
        // update sync state
        var key_buf: [128]u8 = undefined;
        const sync_key = try std.fmt.bufPrint(&key_buf, "s:{s}", .{contract_address});
        var val_buf: [128]u8 = undefined;
        const sync_val = try std.fmt.bufPrint(&val_buf, "{{\"last_synced_block\":{d},\"status\":\"reorg_rollback\"}}", .{from_block - 1});
        try self.rocks.?.put(sync_key, sync_val);
    }

    // ========================================================================
    // countEventRows
    // ========================================================================
    pub fn countEventRows(self: *Client, contract_name: []const u8, event_name: []const u8) !u64 {
        if (self.backend_type == .rocksdb) return self.countEventRowsRocks(contract_name, event_name);
        if (self.backend_type == .postgresql) return self.countEventRowsPG(contract_name, event_name);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "SELECT COUNT(*) FROM event_{s}_{s};", .{ contract_name, event_name });
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) return @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
        return 0;
    }

    fn countEventRowsRocks(self: *Client, contract_name: []const u8, event_name: []const u8) !u64 {
        var prefix_buf: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "e:{s}:{s}:", .{ contract_name, event_name });
        var count: u64 = 0;
        var iter = self.rocks.?.iterator();
        defer iter.deinit();
        iter.seek(prefix);
        while (iter.valid()) {
            const k = iter.key();
            if (!std.mem.startsWith(u8, k, prefix)) break;
            count += 1;
            iter.next();
        }
        return count;
    }

    // ========================================================================
    // PostgreSQL 后端实现
    // ========================================================================

    fn migratePG(self: *Client) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS sync_state (
            \\  id SERIAL PRIMARY KEY,
            \\  contract_address TEXT NOT NULL UNIQUE,
            \\  last_synced_block BIGINT NOT NULL DEFAULT 0,
            \\  status TEXT NOT NULL DEFAULT 'stopped',
            \\  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_sync_state_address ON sync_state(contract_address);
            \\
            \\CREATE TABLE IF NOT EXISTS account_states (
            \\  id SERIAL PRIMARY KEY,
            \\  contract_address TEXT NOT NULL,
            \\  account_address TEXT NOT NULL,
            \\  balance TEXT NOT NULL DEFAULT '0',
            \\  last_updated_block BIGINT NOT NULL DEFAULT 0,
            \\  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(contract_address, account_address)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_account_states ON account_states(contract_address, account_address);
            \\
            \\CREATE TABLE IF NOT EXISTS snapshots (
            \\  id SERIAL PRIMARY KEY,
            \\  contract_address TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL,
            \\  snapshot_data TEXT NOT NULL,
            \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_snapshots ON snapshots(contract_address, block_number);
            \\
            \\CREATE TABLE IF NOT EXISTS raw_logs (
            \\  id SERIAL PRIMARY KEY,
            \\  contract_address TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL,
            \\  tx_hash TEXT NOT NULL,
            \\  log_index BIGINT NOT NULL,
            \\  topics TEXT NOT NULL,
            \\  data TEXT NOT NULL,
            \\  reason TEXT NOT NULL DEFAULT 'abi_mismatch',
            \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_raw_logs ON raw_logs(contract_address, block_number);
            \\
            \\CREATE TABLE IF NOT EXISTS block_hashes (
            \\  id SERIAL PRIMARY KEY,
            \\  contract_address TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL,
            \\  block_hash TEXT NOT NULL,
            \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(contract_address, block_number)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_block_hashes ON block_hashes(contract_address, block_number);

            \\CREATE TABLE IF NOT EXISTS blocks (
            \\  id SERIAL PRIMARY KEY,
            \\  block_number BIGINT NOT NULL,
            \\  block_hash TEXT NOT NULL,
            \\  timestamp BIGINT NOT NULL,
            \\  miner TEXT DEFAULT '',
            \\  gas_used BIGINT DEFAULT 0,
            \\  gas_limit BIGINT DEFAULT 0,
            \\  base_fee_per_gas TEXT DEFAULT '0',
            \\  transaction_count BIGINT DEFAULT 0,
            \\  chain TEXT NOT NULL DEFAULT '',
            \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            \\  UNIQUE(chain, block_number)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_blocks_chain_number ON blocks(chain, block_number);

            \\CREATE TABLE IF NOT EXISTS call_cache (
            \\  id SERIAL PRIMARY KEY,
            \\  cache_key TEXT NOT NULL UNIQUE,
            \\  result TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL,
            \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_call_cache_key ON call_cache(cache_key);

            \\CREATE TABLE IF NOT EXISTS template_addresses (
            \\  template TEXT NOT NULL,
            \\  address TEXT NOT NULL,
            \\  from_block BIGINT NOT NULL,
            \\  backfilled INTEGER NOT NULL DEFAULT 0,
            \\  PRIMARY KEY (template, address)
            \\);
        ;
        try self.pgconn.?.exec(sql);
    }

    fn autoMigrateContractPG(
        self: *Client,
        contract_name: []const u8,
        abi_contract: *const abi.AbiContract,
        event_names: []const []const u8,
        contract_address: []const u8,
    ) !void {
        for (event_names) |evt_name| {
            const evt = abi_contract.findEventByName(evt_name) orelse continue;
            // 老库先补列 + 换唯一键（PG 可直接改约束，无需重建表）
            try self.migrateEventTableAddressPG(contract_name, evt, contract_address);
            try self.createEventTablePG(contract_name, evt);
        }
    }

    /// 老库升级（PG）：补 contract_address 列 + 回填 + 唯一键换成含地址的版本。
    /// 幂等：列与唯一键都已就位时直接返回。
    /// 作用域一致性：先把表解析成「search_path 可见的那张表」的 schema 限定名，之后探测
    /// （列 / 唯一约束）与改动（ALTER / UPDATE / DROP / ADD）全用同一个名字——否则同库
    /// 别 schema 的同名表会被算进来，出现「探测说已就位、改动落空」→ 本表退化成无唯一键。
    fn migrateEventTableAddressPG(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent, contract_address: []const u8) !void {
        const table = try std.fmt.allocPrint(self.alloc, "event_{s}_{s}", .{ contract_name, evt.name });
        defer self.alloc.free(table);

        // 1) 表不存在（search_path 不可见）：按新结构建（IF NOT EXISTS，随后 createEventTablePG 是空操作）
        const target = (try self.pgResolveVisibleTable(table)) orelse return self.createEventTablePG(contract_name, evt);
        defer self.alloc.free(target);

        // 2) 是否已有地址列（限定到同一张表）
        const has_address = blk: {
            const sql = "SELECT COUNT(*) FROM pg_catalog.pg_attribute WHERE attrelid = $1::regclass AND attname = 'contract_address' AND attnum > 0 AND NOT attisdropped;";
            var res = try self.pgconn.?.execParams(sql, &.{target});
            defer res.deinit();
            break :blk res.rows() > 0 and !res.isNull(0, 0) and !std.mem.eql(u8, res.get(0, 0), "0");
        };

        // 3) 这张表上的唯一约束：目标是含地址三元组那一个；只有形态「正好等于」旧键
        //    UNIQUE(tx_hash, log_index) 的才允许 DROP，用户自加的其他唯一约束一律不动
        var stale_names: std.ArrayList([]u8) = .empty;
        defer {
            for (stale_names.items) |nm| self.alloc.free(nm);
            stale_names.deinit(self.alloc);
        }
        var has_target = false;
        {
            const sql = "SELECT c.conname, pg_get_constraintdef(c.oid) FROM pg_catalog.pg_constraint c WHERE c.conrelid = $1::regclass AND c.contype = 'u';";
            var res = try self.pgconn.?.execParams(sql, &.{target});
            defer res.deinit();
            var i: c_int = 0;
            while (i < res.rows()) : (i += 1) {
                const def = res.get(i, 1);
                if (try constraintDefEquals(self.alloc, def, "unique(contract_address,tx_hash,log_index)")) {
                    has_target = true;
                } else if (try constraintDefEquals(self.alloc, def, "unique(tx_hash,log_index)")) {
                    const nm = try self.alloc.dupe(u8, res.get(i, 0));
                    errdefer self.alloc.free(nm);
                    try stale_names.append(self.alloc, nm);
                }
            }
        }
        if (has_address and has_target and stale_names.items.len == 0) return;

        try self.pgconn.?.exec("BEGIN;");
        errdefer self.pgconn.?.exec("ROLLBACK;") catch {};

        if (!has_address) {
            const add_sql = try std.fmt.allocPrint(self.alloc, "ALTER TABLE {s} ADD COLUMN IF NOT EXISTS contract_address TEXT NOT NULL DEFAULT '';", .{target});
            defer self.alloc.free(add_sql);
            try self.pgconn.?.exec(add_sql);
            // 老行地址为空串，用本合约地址回填（新行不会命中：插入时已带真实地址）
            const upd_sql = try std.fmt.allocPrint(self.alloc, "UPDATE {s} SET contract_address = $1 WHERE contract_address = '';", .{target});
            defer self.alloc.free(upd_sql);
            var res = try self.pgconn.?.execParams(upd_sql, &.{contract_address});
            res.deinit();
        }

        if (!has_target or stale_names.items.len > 0) {
            var ddl_buf: std.Io.Writer.Allocating = .init(self.alloc);
            defer ddl_buf.deinit();
            const w = &ddl_buf.writer;
            for (stale_names.items) |nm| {
                try w.print("ALTER TABLE {s} DROP CONSTRAINT IF EXISTS \"{s}\";\n", .{ target, nm });
            }
            if (!has_target) {
                try w.print("ALTER TABLE {s} ADD CONSTRAINT event_{s}_{s}_addr_uniq UNIQUE (contract_address, tx_hash, log_index);\n", .{ target, contract_name, evt.name });
            }
            var list = ddl_buf.toArrayList();
            defer list.deinit(self.alloc);
            try self.pgconn.?.exec(list.items);
        }

        try self.pgconn.?.exec("COMMIT;");
        log.info("事件表 {s} 已迁移（PG）：补 contract_address 列 + 地址唯一键", .{target});
    }

    /// 把不带 schema 的表名解析成「search_path 可见的那张表」的 schema 限定名
    /// （= 非限定 `ALTER TABLE event_x` 的解析结果）；不可见则返回 null。
    fn pgResolveVisibleTable(self: *Client, table: []const u8) !?[]u8 {
        const sql =
            \\SELECT pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(c.relname)
            \\FROM pg_catalog.pg_class c
            \\JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            \\WHERE c.relname = lower($1) AND c.relkind IN ('r', 'p') AND pg_catalog.pg_table_is_visible(c.oid)
            \\LIMIT 1;
        ;
        var res = try self.pgconn.?.execParams(sql, &.{table});
        defer res.deinit();
        if (res.rows() == 0 or res.isNull(0, 0)) return null;
        return try self.alloc.dupe(u8, res.get(0, 0));
    }

    fn createEventTablePG(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent) !void {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("CREATE TABLE IF NOT EXISTS event_{s}_{s} (", .{ contract_name, evt.name });
        try w.writeAll("\n  id SERIAL PRIMARY KEY,");
        for (evt.inputs) |input| {
            const col_name = try self.sanitizeColumnName(input.name);
            defer self.alloc.free(col_name);
            const sql_type = abi.abiTypeToSqlType(input.type);
            try w.print("\n  {s} {s},", .{ col_name, sql_type });
        }
        try w.writeAll("\n  block_number BIGINT NOT NULL,");
        try w.writeAll("\n  tx_hash TEXT NOT NULL,");
        try w.writeAll("\n  log_index BIGINT NOT NULL,");
        try w.writeAll("\n  contract_address TEXT NOT NULL DEFAULT '',");
        try w.writeAll("\n  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,");
        try w.print("\n  UNIQUE(contract_address, tx_hash, log_index)\n);", .{});
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_addr_block ON event_{s}_{s}(contract_address, block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        var list = sql_buf.toArrayList();
        defer list.deinit(self.alloc);
        try self.pgconn.?.exec(list.items);
    }

    fn insertEventLogPG(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const DecodedField,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        contract_address: []const u8,
    ) !void {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("INSERT INTO event_{s}_{s} (", .{ contract_name, event_name });
        for (fields, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            const col = try self.sanitizeColumnName(f.name);
            defer self.alloc.free(col);
            try w.writeAll(col);
        }
        try w.writeAll(",block_number,tx_hash,log_index,contract_address) VALUES (");
        for (fields, 0..) |_, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("${d}", .{i + 1});
        }
        try w.print(",${d},${d},${d},${d});", .{ fields.len + 1, fields.len + 2, fields.len + 3, fields.len + 4 });
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var params = try std.ArrayList([]const u8).initCapacity(self.alloc, fields.len + 4);
        defer params.deinit(self.alloc);
        for (fields) |f| try params.append(self.alloc, f.value);
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{block_number});
        try params.append(self.alloc, block_str);
        try params.append(self.alloc, tx_hash);
        var logidx_buf: [21]u8 = undefined;
        const li_str = try std.fmt.bufPrint(&logidx_buf, "{}", .{log_index});
        try params.append(self.alloc, li_str);
        try params.append(self.alloc, contract_address);

        var result = try self.pgconn.?.execParams(sql_list.items, params.items);
        defer result.deinit();
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    fn insertRawLogPG(
        self: *Client,
        contract_address: []const u8,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
        topics: []const u8,
        data: []const u8,
        reason: []const u8,
    ) !void {
        const sql = "INSERT INTO raw_logs (contract_address, block_number, tx_hash, log_index, topics, data, reason) VALUES ($1,$2,$3,$4,$5,$6,$7);";
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{block_number});
        var li_buf: [21]u8 = undefined;
        const li_str = try std.fmt.bufPrint(&li_buf, "{}", .{log_index});
        const params = &.{ contract_address, block_str, tx_hash, li_str, topics, data, reason };
        var result = try self.pgconn.?.execParams(sql, params);
        defer result.deinit();
    }

    /// 构建 queryEventLogsPG 的文本参数（顺序与 SQL 占位符一致）。
    ///
    /// `arena` 必须比 `params` 活得久：格式化结果在 arena 上，切片在函数返回后仍有效。
    /// 修复前这里是块作用域里的栈上 `[21]u8` —— 函数一返回切片即失效（调用方读到的
    /// 是已回收的栈帧内容，块号/分页条件静默错乱）。
    fn buildEventLogsPgParams(
        self: *Client,
        arena: std.mem.Allocator,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
        address: ?[]const u8,
        limit: u32,
        offset: u32,
        params: *std.ArrayList([]const u8),
    ) !void {
        if (block_from) |bf| try params.append(self.alloc, try std.fmt.allocPrint(arena, "{}", .{bf}));
        if (block_to) |bt| try params.append(self.alloc, try std.fmt.allocPrint(arena, "{}", .{bt}));
        if (tx_hash) |th| try params.append(self.alloc, th);
        if (address) |ad| try params.append(self.alloc, ad);
        try params.append(self.alloc, try std.fmt.allocPrint(arena, "{}", .{limit}));
        try params.append(self.alloc, try std.fmt.allocPrint(arena, "{}", .{offset}));
    }

    fn queryEventLogsPG(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
        address: ?[]const u8,
        limit: u32,
        offset: u32,
        _: bool,
    ) ![]u8 {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;
        try w.print("SELECT * FROM event_{s}_{s} WHERE 1=1", .{ contract_name, event_name });
        var param_idx: usize = 1;
        if (block_from) |_| { try w.print(" AND block_number >= ${d}", .{param_idx}); param_idx += 1; }
        if (block_to) |_| { try w.print(" AND block_number <= ${d}", .{param_idx}); param_idx += 1; }
        if (tx_hash) |_| { try w.print(" AND tx_hash = ${d}", .{param_idx}); param_idx += 1; }
        if (address) |_| { try w.print(" AND contract_address = ${d}", .{param_idx}); param_idx += 1; }
        try w.writeAll(" ORDER BY block_number DESC");
        try w.print(" LIMIT ${d} OFFSET ${d};", .{ param_idx, param_idx + 1 });
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        // 参数的格式化结果必须活到 execParams 调用为止（见 buildEventLogsPgParams）。
        var param_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer param_arena.deinit();
        var params = std.ArrayList([]const u8).empty;
        defer params.deinit(self.alloc);
        try self.buildEventLogsPgParams(param_arena.allocator(), block_from, block_to, tx_hash, address, limit, offset, &params);

        var result = try self.pgconn.?.execParams(sql_list.items, params.items);
        defer result.deinit();

        var result_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer result_buf.deinit();
        const rw = &result_buf.writer;
        try rw.writeByte('[');
        const nrows = result.rows();
        for (0..@intCast(nrows)) |row| {
            if (row > 0) try rw.writeByte(',');
            try rw.writeByte('{');
            const ncols = result.cols();
            for (0..@intCast(ncols)) |col| {
                if (col > 0) try rw.writeByte(',');
                const col_name = result.colName(@intCast(col));
                try rw.print("\"{s}\":", .{col_name});
                if (result.isNull(@intCast(row), @intCast(col))) {
                    try rw.writeAll("null");
                } else {
                    const val = result.get(@intCast(row), @intCast(col));
                    try rw.writeByte('"');
                    try utils.jsonEscapeString(rw, val);
                    try rw.writeByte('"');
                }
            }
            try rw.writeByte('}');
        }
        try rw.writeByte(']');
        var list = result_buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }

    fn getSyncStatePG(self: *Client, contract_address: []const u8) !?SyncState {
        const sql = "SELECT contract_address, last_synced_block, status FROM sync_state WHERE contract_address = $1;";
        var result = try self.pgconn.?.execParams(sql, &.{contract_address});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const addr = result.get(0, 0);
        const block_str = result.get(0, 1);
        const status = result.get(0, 2);
        return SyncState{
            .contract_address = try self.alloc.dupe(u8, addr),
            .last_synced_block = std.fmt.parseInt(u64, block_str, 10) catch 0,
            .status = try self.alloc.dupe(u8, status),
        };
    }

    fn upsertSyncStatePG(self: *Client, state: SyncState) !void {
        const sql =
            \\INSERT INTO sync_state (contract_address, last_synced_block, status, updated_at)
            \\VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            \\ON CONFLICT(contract_address) DO UPDATE SET
            \\  last_synced_block = EXCLUDED.last_synced_block,
            \\  status = EXCLUDED.status,
            \\  updated_at = CURRENT_TIMESTAMP;
        ;
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{state.last_synced_block});
        var result = try self.pgconn.?.execParams(sql, &.{ state.contract_address, block_str, state.status });
        defer result.deinit();
    }

    fn upsertAccountStatePG(self: *Client, state: AccountState) !void {
        const sql =
            \\INSERT INTO account_states (contract_address, account_address, balance, last_updated_block, updated_at)
            \\VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
            \\ON CONFLICT(contract_address, account_address) DO UPDATE SET
            \\  balance = EXCLUDED.balance,
            \\  last_updated_block = EXCLUDED.last_updated_block,
            \\  updated_at = CURRENT_TIMESTAMP;
        ;
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{state.last_updated_block});
        var result = try self.pgconn.?.execParams(sql, &.{ state.contract_address, state.account_address, state.balance, block_str });
        defer result.deinit();
    }

    fn getAccountBalancePG(self: *Client, contract_address: []const u8, account_address: []const u8) !?[]const u8 {
        const sql = "SELECT balance FROM account_states WHERE contract_address = $1 AND account_address = $2;";
        var result = try self.pgconn.?.execParams(sql, &.{ contract_address, account_address });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try self.alloc.dupe(u8, result.get(0, 0));
    }

    fn deleteEventLogsInRangePG(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "DELETE FROM event_{s}_{s} WHERE block_number >= $1 AND block_number <= $2;", .{ contract_name, event_name });
        var bf_buf: [21]u8 = undefined;
        var bt_buf: [21]u8 = undefined;
        var result = try self.pgconn.?.execParams(sql, &.{
            try std.fmt.bufPrint(&bf_buf, "{}", .{from_block}),
            try std.fmt.bufPrint(&bt_buf, "{}", .{to_block}),
        });
        defer result.deinit();
        if (self.cache) |cc| cc.invalidate(contract_name, event_name);
    }

    fn createSnapshotPG(self: *Client, snapshot: Snapshot) !void {
        const sql = "INSERT INTO snapshots (contract_address, block_number, snapshot_data) VALUES ($1, $2, $3);";
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{snapshot.block_number});
        var result = try self.pgconn.?.execParams(sql, &.{ snapshot.contract_address, block_str, snapshot.snapshot_data });
        defer result.deinit();
    }

    fn getLatestSnapshotPG(self: *Client, contract_address: []const u8) !?Snapshot {
        const sql = "SELECT contract_address, block_number, snapshot_data FROM snapshots WHERE contract_address = $1 ORDER BY block_number DESC LIMIT 1;";
        var result = try self.pgconn.?.execParams(sql, &.{contract_address});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const block_str = result.get(0, 1);
        return Snapshot{
            .contract_address = try self.alloc.dupe(u8, result.get(0, 0)),
            .block_number = std.fmt.parseInt(u64, block_str, 10) catch 0,
            .snapshot_data = try self.alloc.dupe(u8, result.get(0, 2)),
        };
    }

    fn upsertBlockHashPG(self: *Client, contract_address: []const u8, block_number: u64, block_hash: []const u8) !void {
        const sql =
            \\INSERT INTO block_hashes (contract_address, block_number, block_hash)
            \\VALUES ($1, $2, $3)
            \\ON CONFLICT(contract_address, block_number) DO UPDATE SET
            \\  block_hash = EXCLUDED.block_hash;
        ;
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{block_number});
        var result = try self.pgconn.?.execParams(sql, &.{ contract_address, block_str, block_hash });
        defer result.deinit();
    }

    fn getBlockHashPG(self: *Client, contract_address: []const u8, block_number: u64) !?[]u8 {
        const sql = "SELECT block_hash FROM block_hashes WHERE contract_address = $1 AND block_number = $2;";
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{block_number});
        var result = try self.pgconn.?.execParams(sql, &.{ contract_address, block_str });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try self.alloc.dupe(u8, result.get(0, 0));
    }

    fn rollbackFromBlockPG(self: *Client, contract_address: []const u8, contract_name: []const u8, event_names: []const []const u8, from_block: u64) !void {
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{from_block});

        for (event_names) |evt_name| {
            var sql_buf: [256]u8 = undefined;
            const sql = try std.fmt.bufPrint(&sql_buf, "DELETE FROM event_{s}_{s} WHERE block_number >= $1;", .{ contract_name, evt_name });
            var result = try self.pgconn.?.execParams(sql, &.{block_str});
            defer result.deinit();
        }
        {
            const sql = "DELETE FROM snapshots WHERE contract_address = $1 AND block_number >= $2;";
            var result = try self.pgconn.?.execParams(sql, &.{ contract_address, block_str });
            defer result.deinit();
        }
        {
            const sql = "DELETE FROM block_hashes WHERE contract_address = $1 AND block_number >= $2;";
            var result = try self.pgconn.?.execParams(sql, &.{ contract_address, block_str });
            defer result.deinit();
        }
        // 业务投影表级联回滚：proj_* 前缀约定 + block_number 列
        {
            const sql = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name LIKE 'proj\\_%' ESCAPE '\\';";
            var result = try self.pgconn.?.execParams(sql, &.{});
            defer result.deinit();
            const nrows = result.rows();
            var i: c_int = 0;
            while (i < nrows) : (i += 1) {
                const tbl = result.get(i, 0);
                // 标识符内出现双引号则跳过（避免 SQL 拼接被破坏）
                if (std.mem.indexOfScalar(u8, tbl, '"') != null) continue;
                var del_buf: [512]u8 = undefined;
                const del_sql = std.fmt.bufPrint(&del_buf, "DELETE FROM \"{s}\" WHERE block_number >= $1;", .{tbl}) catch continue;
                var del_result = self.pgconn.?.execParams(del_sql, &.{block_str}) catch continue;
                del_result.deinit();
            }
        }
        {
            var rollback_buf: [21]u8 = undefined;
            const rollback_block = if (from_block > 0) from_block - 1 else 0;
            const rollback_str = try std.fmt.bufPrint(&rollback_buf, "{}", .{rollback_block});
            const sql = "UPDATE sync_state SET last_synced_block = $1, status = 'reorg_rollback' WHERE contract_address = $2;";
            var result = try self.pgconn.?.execParams(sql, &.{ rollback_str, contract_address });
            defer result.deinit();
        }
    }

    fn countEventRowsPG(self: *Client, contract_name: []const u8, event_name: []const u8) !u64 {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "SELECT COUNT(*) FROM event_{s}_{s};", .{ contract_name, event_name });
        var result = try self.pgconn.?.execParams(sql, &.{});
        defer result.deinit();
        if (result.rows() == 0) return 0;
        return std.fmt.parseInt(u64, result.get(0, 0), 10) catch 0;
    }

    // ========================================================================
    // execQuery — 自定义 SQL 查询（SQLite / PG 后端，RocksDB 不支持）
    // ========================================================================
    pub fn execQuery(
        self: *Client,
        sql: []const u8,
        param_names: []const []const u8,
        param_values: []const []const u8,
    ) ![]u8 {
        switch (self.backend_type) {
            .sqlite => return self.execQuerySqlite(sql, param_names, param_values),
            .postgresql => return self.execQueryPG(sql, param_names, param_values),
            .rocksdb => return error.UnsupportedOperation,
        }
    }

    fn execQuerySqlite(
        self: *Client,
        sql: []const u8,
        param_names: []const []const u8,
        param_values: []const []const u8,
    ) ![]u8 {
        _ = param_names; // SQLite uses positional ? placeholders
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        for (param_values, 0..) |val, i| {
            if (c.sqlite3_bind_text(stmt, @intCast(i + 1), val.ptr, @intCast(val.len), c.SQLITE_STATIC) != c.SQLITE_OK)
                return error.BindFailed;
        }

        var result_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer result_buf.deinit();
        const rw = &result_buf.writer;
        try rw.writeByte('[');
        var row_count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (row_count > 0) try rw.writeByte(',');
            try rw.writeByte('{');
            const col_count = c.sqlite3_column_count(stmt);
            var col_idx: c_int = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                if (col_idx > 0) try rw.writeByte(',');
                const col_name = std.mem.sliceTo(c.sqlite3_column_name(stmt, col_idx), 0);
                try rw.print("\"{s}\":", .{col_name});
                const col_type = c.sqlite3_column_type(stmt, col_idx);
                switch (col_type) {
                    c.SQLITE_INTEGER => try rw.print("{}", .{c.sqlite3_column_int64(stmt, col_idx)}),
                    c.SQLITE_FLOAT => try rw.print("{}", .{c.sqlite3_column_double(stmt, col_idx)}),
                    c.SQLITE_NULL => try rw.writeAll("null"),
                    else => {
                        const val = std.mem.sliceTo(c.sqlite3_column_text(stmt, col_idx), 0);
                        try rw.writeByte('"');
                        try utils.jsonEscapeString(rw, val);
                        try rw.writeByte('"');
                    },
                }
            }
            try rw.writeByte('}');
            row_count += 1;
        }
        try rw.writeByte(']');
        var list = result_buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }

    fn execQueryPG(
        self: *Client,
        sql: []const u8,
        param_names: []const []const u8,
        param_values: []const []const u8,
    ) ![]u8 {
        _ = param_names; // PG uses positional $N placeholders
        var result = try self.pgconn.?.execParams(sql, param_values);
        defer result.deinit();

        var result_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer result_buf.deinit();
        const rw = &result_buf.writer;
        try rw.writeByte('[');
        const nrows = result.rows();
        for (0..@intCast(nrows)) |row| {
            if (row > 0) try rw.writeByte(',');
            try rw.writeByte('{');
            const ncols = result.cols();
            for (0..@intCast(ncols)) |col| {
                if (col > 0) try rw.writeByte(',');
                const col_name = result.colName(@intCast(col));
                try rw.print("\"{s}\":", .{col_name});
                if (result.isNull(@intCast(row), @intCast(col))) {
                    try rw.writeAll("null");
                } else {
                    const val = result.get(@intCast(row), @intCast(col));
                    try rw.writeByte('"');
                    try utils.jsonEscapeString(rw, val);
                    try rw.writeByte('"');
                }
            }
            try rw.writeByte('}');
        }
        try rw.writeByte(']');
        var list = result_buf.toArrayList();
        defer list.deinit(self.alloc);
        return try self.alloc.dupe(u8, list.items);
    }

    // ========================================================================
    // ponder.db：JS handler 业务投影 API（参数化 exec/query，与 QuickJS 解耦）
    // ========================================================================

    /// 执行写语句（CREATE/INSERT/UPDATE/DELETE），返回 affected rows。
    /// 注意：text/blob 参数按 SQLITE_STATIC 绑定，调用期间须保持有效。
    pub fn ponderExec(self: *Client, sql: []const u8, params: []const SqlValue) !usize {
        switch (self.backend_type) {
            .sqlite => return self.ponderExecSqlite(sql, params),
            .postgresql => return self.ponderExecPG(sql, params),
            .rocksdb => return error.UnsupportedOperation,
        }
    }

    /// 执行查询，返回行数组（调用方负责 freeQueryRows）。非 SELECT 返回空数组。
    pub fn ponderQuery(self: *Client, sql: []const u8, params: []const SqlValue) ![]QueryRow {
        switch (self.backend_type) {
            .sqlite => return self.ponderQuerySqlite(sql, params),
            .postgresql => return self.ponderQueryPG(sql, params),
            .rocksdb => return error.UnsupportedOperation,
        }
    }

    pub fn freeQueryRows(self: *Client, rows: []QueryRow) void {
        for (rows) |row| self.freeQueryRow(row);
        self.alloc.free(rows);
    }

    fn freeQueryRow(self: *Client, row: QueryRow) void {
        for (row.names) |n| self.alloc.free(n);
        self.alloc.free(row.names);
        for (row.values) |v| switch (v) {
            .text => |t| self.alloc.free(t),
            .blob => |b| self.alloc.free(b),
            else => {},
        };
        self.alloc.free(row.values);
    }

    fn bindParamsSqlite(stmt: ?*c.sqlite3_stmt, params: []const SqlValue) !void {
        for (params, 0..) |p, i| {
            const idx: c_int = @intCast(i + 1);
            const rc = switch (p) {
                .null => c.sqlite3_bind_null(stmt, idx),
                .integer => |v| c.sqlite3_bind_int64(stmt, idx, v),
                .float => |v| c.sqlite3_bind_double(stmt, idx, v),
                // SQLITE_STATIC：调用期间参数缓冲区由 js_engine 持有，禁止提前释放
                .text => |v| c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                .blob => |v| c.sqlite3_bind_blob(stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
            };
            if (rc != c.SQLITE_OK) return error.BindFailed;
        }
    }

    fn ponderExecSqlite(self: *Client, sql: []const u8, params: []const SqlValue) !usize {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        try bindParamsSqlite(stmt, params);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return error.ExecFailed;
        return @intCast(c.sqlite3_changes(self.db));
    }

    fn ponderQuerySqlite(self: *Client, sql: []const u8, params: []const SqlValue) ![]QueryRow {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        try bindParamsSqlite(stmt, params);

        var rows: std.ArrayList(QueryRow) = .empty;
        errdefer {
            for (rows.items) |row| self.freeQueryRow(row);
            rows.deinit(self.alloc);
        }
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const ncols: usize = @intCast(c.sqlite3_column_count(stmt));
            const names = try self.alloc.alloc([]const u8, ncols);
            errdefer self.alloc.free(names);
            const values = try self.alloc.alloc(SqlValue, ncols);
            errdefer self.alloc.free(values);

            // 部分填充清理：names/values 数组本身由上面的 errdefer 释放，这里释放
            // "当前行已 dupe 出来的列名与值"。缺了它，行内元素 dupe 中途 OOM 时已入数组的
            // 字符串会泄漏（ponderQuery 是 JS 投影查询的公共路径）。
            var names_filled: usize = 0;
            var values_filled: usize = 0;
            errdefer {
                for (names[0..names_filled]) |nm| self.alloc.free(nm);
                for (values[0..values_filled]) |v| switch (v) {
                    .text => |t| self.alloc.free(t),
                    .blob => |b| self.alloc.free(b),
                    else => {},
                };
            }

            for (0..ncols) |i| {
                const ci: c_int = @intCast(i);
                names[i] = try self.alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_column_name(stmt, ci), 0));
                names_filled = i + 1;
                values[i] = switch (c.sqlite3_column_type(stmt, ci)) {
                    c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(stmt, ci) },
                    c.SQLITE_FLOAT => .{ .float = c.sqlite3_column_double(stmt, ci) },
                    c.SQLITE_NULL => .null,
                    c.SQLITE_BLOB => blk: {
                        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, ci));
                        const raw = c.sqlite3_column_blob(stmt, ci);
                        if (raw == null or len == 0) break :blk .{ .blob = try self.alloc.dupe(u8, &.{}) };
                        break :blk .{ .blob = try self.alloc.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..len]) };
                    },
                    else => .{ .text = try self.alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_column_text(stmt, ci), 0)) },
                };
                values_filled = i + 1;
            }
            try rows.append(self.alloc, .{ .names = names, .values = values });
        }
        return rows.toOwnedSlice(self.alloc);
    }

    /// SqlValue -> PG 文本参数（null 表示 SQL NULL）。
    /// 注意：libpq 的 text 格式参数按 NUL 结尾解析（忽略 length），
    /// 所有格式化结果必须补终止符（Zig 切片本身无 0 结尾）。
    fn toPgParams(self: *Client, arena: std.mem.Allocator, params: []const SqlValue) ![]const ?[]const u8 {
        _ = self;
        const out = try arena.alloc(?[]const u8, params.len);
        for (params, 0..) |p, i| {
            out[i] = switch (p) {
                .null => null,
                .integer => |v| try allocSentinelCopy(arena, try std.fmt.allocPrint(arena, "{d}", .{v})),
                .float => |v| try allocSentinelCopy(arena, try std.fmt.allocPrint(arena, "{d}", .{v})),
                // JS 侧字符串来自 JS_ToCStringLen，已是 NUL 结尾，可直接透传
                .text => |v| v,
                .blob => |v| blk: {
                    var buf: std.ArrayList(u8) = .empty;
                    try buf.appendSlice(arena, "\\x");
                    const hex = "0123456789abcdef";
                    for (v) |byte| {
                        try buf.append(arena, hex[byte >> 4]);
                        try buf.append(arena, hex[byte & 0x0f]);
                    }
                    break :blk try allocSentinelCopy(arena, buf.items);
                },
            };
        }
        return out;
    }

    /// PG 后端：按结果 OID 映射类型（int/float -> 数值，bytea -> blob，其余 -> 文本）
    fn pgValueFromText(alloc: std.mem.Allocator, oid: u32, text: []const u8) !SqlValue {
        return switch (oid) {
            20, 21, 23 => .{ .integer = std.fmt.parseInt(i64, text, 10) catch return .{ .text = try alloc.dupe(u8, text) } },
            700, 701, 1700 => .{ .float = std.fmt.parseFloat(f64, text) catch return .{ .text = try alloc.dupe(u8, text) } },
            17 => blk: {
                // PG text 格式 bytea 为 \x<hex>
                const hex_part = if (std.mem.startsWith(u8, text, "\\x")) text[2..] else text;
                if (hex_part.len % 2 != 0) break :blk .{ .text = try alloc.dupe(u8, text) };
                const out = try alloc.alloc(u8, hex_part.len / 2);
                _ = std.fmt.hexToBytes(out, hex_part) catch {
                    alloc.free(out);
                    break :blk .{ .text = try alloc.dupe(u8, text) };
                };
                break :blk .{ .blob = out };
            },
            else => .{ .text = try alloc.dupe(u8, text) },
        };
    }

    fn ponderExecPG(self: *Client, sql: []const u8, params: []const SqlValue) !usize {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const pgparams = try self.toPgParams(arena.allocator(), params);
        var res = try self.pgconn.?.execParamsNull(sql, pgparams);
        defer res.deinit();
        const tuples = res.cmdTuples();
        return std.fmt.parseInt(usize, std.mem.trim(u8, tuples, " \t\r\n"), 10) catch 0;
    }

    fn ponderQueryPG(self: *Client, sql: []const u8, params: []const SqlValue) ![]QueryRow {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const pgparams = try self.toPgParams(arena.allocator(), params);
        var res = try self.pgconn.?.execParamsNull(sql, pgparams);
        defer res.deinit();

        const nrows: usize = @intCast(res.rows());
        const ncols: usize = @intCast(res.cols());
        const rows = try self.alloc.alloc(QueryRow, nrows);
        var filled: usize = 0;
        errdefer {
            for (rows[0..filled]) |row| self.freeQueryRow(row);
            self.alloc.free(rows);
        }
        for (0..nrows) |r| {
            const names = try self.alloc.alloc([]const u8, ncols);
            errdefer self.alloc.free(names);
            const values = try self.alloc.alloc(SqlValue, ncols);
            errdefer self.alloc.free(values);

            // 部分填充清理（与 ponderQuerySqlite 镜像）：数组本身由上面的 errdefer 释放，
            // 这里释放"当前行已 dupe 出来的列名与值"。缺了它，行内填充中途 OOM 时已入数组的
            // 字符串/字节会泄漏（ponderQuery 是 JS 投影查询的公共路径）。
            var names_filled: usize = 0;
            var values_filled: usize = 0;
            errdefer {
                for (names[0..names_filled]) |nm| self.alloc.free(nm);
                for (values[0..values_filled]) |v| switch (v) {
                    .text => |t| self.alloc.free(t),
                    .blob => |b| self.alloc.free(b),
                    else => {},
                };
            }

            for (0..ncols) |col| {
                const ci: c_int = @intCast(col);
                names[col] = try self.alloc.dupe(u8, res.colName(ci));
                names_filled = col + 1;
                if (res.isNull(@intCast(r), ci)) {
                    values[col] = .null;
                } else {
                    values[col] = try pgValueFromText(self.alloc, res.colType(ci), res.get(@intCast(r), ci));
                }
                values_filled = col + 1;
            }
            rows[r] = .{ .names = names, .values = values };
            filled = r + 1;
        }
        return rows;
    }

    // ===== 内部辅助函数 =====

    fn checkPragma(db: ?*c.sqlite3, pragma: []const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, pragma.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                defer _ = c.sqlite3_free(msg);
                log.err("SQLite PRAGMA 失败 '{s}': {s}", .{ pragma, msg });
            } else {
                log.err("SQLite PRAGMA 失败 '{s}': 错误码 {}", .{ pragma, rc });
            }
            return error.ExecFailed;
        }
    }

    fn exec(self: *Client, sql: []const u8) !void {
        // sqlite3_exec 需要 NUL 结尾；调用方会传 bufPrint/拼装的 SQL
        const sql_z = try self.alloc.allocSentinel(u8, sql.len, 0);
        defer self.alloc.free(sql_z);
        @memcpy(sql_z, sql);
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                defer _ = c.sqlite3_free(msg);
                log.err("SQL error: {s}", .{msg});
            }
            return error.ExecFailed;
        }
    }
};

/// 事件表的三条索引；新建表与老表重建共用。
fn writeEventTableIndexes(w: *std.Io.Writer, contract_name: []const u8, event_name: []const u8) !void {
    try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{ contract_name, event_name, contract_name, event_name });
    try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{ contract_name, event_name, contract_name, event_name });
    try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_addr_block ON event_{s}_{s}(contract_address, block_number);", .{ contract_name, event_name, contract_name, event_name });
}

fn columnIndex(cols: []const []u8, name: []const u8) ?usize {
    for (cols, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return i;
    }
    return null;
}

/// 建表 DDL 里唯一键是否已含地址列（SQLite：约束内嵌在 CREATE TABLE 语句里，用子串匹配）。
fn ddlHasAddressUnique(alloc: std.mem.Allocator, ddl: []const u8) !bool {
    return ddlHasUniqueKey(alloc, ddl, "unique(contract_address,tx_hash,log_index)");
}

/// 建表 DDL 里是否还带着 Task 1 之前的唯一键 `UNIQUE(tx_hash, log_index)`。
/// 光有地址列还不够：旧键留着会把同 tx 不同合约的事件顶掉。
fn ddlHasLegacyUnique(alloc: std.mem.Allocator, ddl: []const u8) !bool {
    return ddlHasUniqueKey(alloc, ddl, "unique(tx_hash,log_index)");
}

/// 子串匹配（用于整条 CREATE TABLE 语句）：去空白 + 转小写，兼容 `UNIQUE(a, b, c)` 与 `UNIQUE (a,b,c)`。
fn ddlHasUniqueKey(alloc: std.mem.Allocator, ddl: []const u8, needle: []const u8) !bool {
    const norm = try normalizeSql(alloc, ddl);
    defer alloc.free(norm);
    return std.mem.indexOf(u8, norm, needle) != null;
}

/// PG 的 `pg_get_constraintdef()` 输出是否「正好是」某个唯一键形态。
/// 这里必须精确相等而不是子串：DROP 只允许针对形态等于旧键的约束，用户自加的其他唯一约束要留着。
fn constraintDefEquals(alloc: std.mem.Allocator, def: []const u8, needle: []const u8) !bool {
    const norm = try normalizeSql(alloc, def);
    defer alloc.free(norm);
    return std.mem.eql(u8, norm, needle);
}

/// 归一化 SQL 文本：去掉所有空白字符并转小写。
fn normalizeSql(alloc: std.mem.Allocator, sql: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, sql.len);
    for (sql) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        try buf.append(alloc, std.ascii.toLower(ch));
    }
    return buf.toOwnedSlice(alloc);
}

// ============================================================================
// 集成测试
// ============================================================================

test "db getLatestSnapshot empty" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const snap = try client.getLatestSnapshot("0xnonexistent");
    try std.testing.expect(snap == null);
}

test "db migrate and sync_state" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.upsertSyncState(.{ .contract_address = "0x1234", .last_synced_block = 100, .status = "running" });
    const state = try client.getSyncState("0x1234");
    try std.testing.expect(state != null);
    try std.testing.expectEqual(@as(u64, 100), state.?.last_synced_block);
    alloc.free(state.?.contract_address);
    alloc.free(state.?.status);
}

/// 测试用：按 listTemplateAddresses 的约定释放（address 逐个 free，再 free 数组）
fn freeTemplateAddressList(alloc: std.mem.Allocator, list: []TemplateAddress) void {
    for (list) |item| alloc.free(item.address);
    alloc.free(list);
}

test "db template_addresses 增删查与回滚" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.migrate(); // 建表幂等
    try client.addTemplateAddress("curve", "0xA", 100);
    try client.addTemplateAddress("curve", "0xA", 100); // 幂等
    try client.addTemplateAddress("curve", "0xA", 999); // 重复发现不得覆盖已有 from_block
    try client.addTemplateAddress("curve", "0xB", 200);
    try client.addTemplateAddress("other", "0xC", 50); // 模板维度隔离
    {
        const list = try client.listTemplateAddresses("curve");
        defer freeTemplateAddressList(alloc, list);
        try std.testing.expectEqual(@as(usize, 2), list.len);
        try std.testing.expectEqualStrings("0xA", list[0].address);
        try std.testing.expectEqual(@as(u64, 100), list[0].from_block);
        try std.testing.expect(!list[0].backfilled);
        try std.testing.expectEqualStrings("0xB", list[1].address);
        try std.testing.expectEqual(@as(u64, 200), list[1].from_block);
    }
    try client.markTemplateAddressBackfilled("curve", "0xA");
    try client.deleteTemplateAddressesFromBlock("curve", 150);
    const after = try client.listTemplateAddresses("curve");
    defer freeTemplateAddressList(alloc, after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("0xA", after[0].address);
    try std.testing.expect(after[0].backfilled);

    const empty = try client.listTemplateAddresses("nope");
    defer freeTemplateAddressList(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try client.deleteTemplateAddressesFromBlock("curve", 0);
    const gone = try client.listTemplateAddresses("curve");
    defer freeTemplateAddressList(alloc, gone);
    try std.testing.expectEqual(@as(usize, 0), gone.len);
}

test "db template_addresses 落库失败向上返回" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    // 未 migrate：表不存在，addTemplateAddress 必须把错误上抛而非吞掉（错误码随后端而异）
    if (client.addTemplateAddress("curve", "0xA", 100)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "db template_addresses list 分配失败路径不泄漏" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.addTemplateAddress("curve", "0xA", 100);
    try client.addTemplateAddress("curve", "0xB", 200);

    // 库与数据先用稳定的 testing.allocator 建好，只把 listTemplateAddresses 自身的分配切到
    // 注入分配器：Client.init / migrate / ponderQuery 里另有既存的 OOM 泄漏点，直接对整条
    // 调用跑 std.testing.checkAllAllocationFailures 会先撞上它们，无法隔离本函数的 errdefer
    // （实测见 task-4-report §5）。故只对 listTemplateAddresses 自己的分配点逐个注入。

    // 先数出一次成功调用的分配点数（含 ponderQuery 的开销，仅供定位尾部用）
    var counter = std.testing.FailingAllocator.init(alloc, .{});
    client.alloc = counter.allocator();
    {
        const list = try client.listTemplateAddresses("curve");
        freeTemplateAddressList(counter.allocator(), list);
    }
    try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    const total = counter.alloc_index;

    // listTemplateAddresses 自己的分配点都在末尾：结果数组 1 次 + 每行一次 address dupe（2 行）
    const own_alloc_points = 1 + 2;
    try std.testing.expect(total > own_alloc_points);
    for (total - own_alloc_points..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        client.alloc = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, client.listTemplateAddresses("curve"));
        // 注入失败后 errdefer 必须释放已填充的 address 与结果数组：分配/释放字节数必须相等
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "db template_addresses list 列类型漂移的部分填充失败路径" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.addTemplateAddress("curve", "0xA", 100);
    // backfilled 是 INTEGER 亲和性列，写入非数字文本 'x' 时 SQLite 原样存为 TEXT：
    // 第二行会在第一行已填充之后命中 switch 的 error.InvalidData 分支
    _ = try client.ponderExec("INSERT INTO template_addresses (template, address, from_block, backfilled) VALUES ('curve', '0xB', 200, 'x');", &.{});

    try std.testing.expectError(error.InvalidData, client.listTemplateAddresses("curve"));
    // 该路径上 errdefer 必须释放已填充的 list[0].address 与结果数组；
    // 若漏掉，std.testing.allocator 会在本测试结束时以泄漏判失败
}

test "db template_addresses PostgreSQL 后端" {
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    // 独立测试库，避免污染 postgres 库
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_tmpl_addr_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_tmpl_addr_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_tmpl_addr_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();
    try client.addTemplateAddress("curve", "0xA", 100);
    try client.addTemplateAddress("curve", "0xA", 999); // ON CONFLICT DO NOTHING 不覆盖已有进度
    try client.addTemplateAddress("curve", "0xB", 200);

    const list = try client.listTemplateAddresses("curve");
    defer freeTemplateAddressList(alloc, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("0xA", list[0].address);
    try std.testing.expectEqual(@as(u64, 100), list[0].from_block);
    try std.testing.expectEqualStrings("0xB", list[1].address);

    try client.markTemplateAddressBackfilled("curve", "0xA");
    try client.deleteTemplateAddressesFromBlock("curve", 150);
    const after = try client.listTemplateAddresses("curve");
    defer freeTemplateAddressList(alloc, after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("0xA", after[0].address);
    try std.testing.expect(after[0].backfilled);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_tmpl_addr_test;", &.{}) catch {};
    cleanup.deinit();
}

test "db snapshot and block_hash" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.createSnapshot(.{ .contract_address = "0xabcd", .block_number = 50, .snapshot_data = "{\"test\":true}" });
    const snap = try client.getLatestSnapshot("0xabcd");
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 50), snap.?.block_number);
    alloc.free(snap.?.contract_address);
    alloc.free(snap.?.snapshot_data);
    try client.upsertBlockHash("0xabcd", 50, "0xdeadbeef");
    const hash = try client.getBlockHash("0xabcd", 50);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("0xdeadbeef", hash.?);
    alloc.free(hash.?);
}

test "db raw_logs insert" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.insertRawLog("0xabc", 100, "0xtx", 0, "[\"0xtopic\"]", "0xdata", "abi_mismatch");
    const sql = "SELECT COUNT(*) FROM raw_logs WHERE tx_hash = '0xtx';";
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(client.db, sql, @intCast(sql.len), &stmt, null);
    try std.testing.expect(rc == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(stmt);
    const step_rc = c.sqlite3_step(stmt);
    try std.testing.expect(step_rc == c.SQLITE_ROW);
    const count = c.sqlite3_column_int64(stmt, 0);
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "db account_states" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    try client.upsertAccountState(.{ .contract_address = "0xabc", .account_address = "0xdef", .balance = "1000", .last_updated_block = 50 });
    const bal = try client.getAccountBalance("0xabc", "0xdef");
    try std.testing.expect(bal != null);
    try std.testing.expectEqualStrings("1000", bal.?);
    alloc.free(bal.?);
    try client.upsertAccountState(.{ .contract_address = "0xabc", .account_address = "0xdef", .balance = "2000", .last_updated_block = 100 });
    const bal2 = try client.getAccountBalance("0xabc", "0xdef");
    try std.testing.expect(bal2 != null);
    try std.testing.expectEqualStrings("2000", bal2.?);
    alloc.free(bal2.?);
    const bal3 = try client.getAccountBalance("0xabc", "0x999");
    try std.testing.expect(bal3 == null);
}

test "db sqlite file read pool" {
    const alloc = std.testing.allocator;
    const db_path = "test_read_pool.db";
    defer _ = c.remove(db_path.ptr);

    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = db_path, .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    try std.testing.expect(client.read_db != null);

    try client.upsertAccountState(.{ .contract_address = "0xtoken", .account_address = "0xuser", .balance = "500", .last_updated_block = 10 });
    const bal = try client.getAccountBalance("0xtoken", "0xuser");
    try std.testing.expect(bal != null);
    try std.testing.expectEqualStrings("500", bal.?);
    alloc.free(bal.?);
}

test "db event table insert and query" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"}, "0xtest");
    const fields = &.{ DecodedField{ .name = "from", .value = "0x1111" }, DecodedField{ .name = "to", .value = "0x2222" }, DecodedField{ .name = "value", .value = "0x64" } };
    try client.insertEventLog("test", "Transfer", fields, 100, "0xtxhash", 0, "0xtest");
    const result = try client.queryEventLogs("test", "Transfer", 0, null, null, null, 10, 0, true);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0xtxhash") != null);
    const fields2 = &.{ DecodedField{ .name = "from", .value = "0xaaaa" }, DecodedField{ .name = "to", .value = "0xbbbb" }, DecodedField{ .name = "value", .value = "0x96" } };
    try client.insertEventLog("test", "Transfer", fields2, 200, "0xtxhash2", 1, "0xtest");
    const r1 = try client.queryEventLogs("test", "Transfer", 150, null, null, null, 10, 0, true);
    defer alloc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "0xtxhash2") != null);
    const r2 = try client.queryEventLogs("test", "Transfer", null, 150, null, null, 10, 0, true);
    defer alloc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "0xtxhash") != null);
    const r3 = try client.queryEventLogs("test", "Transfer", null, null, "0xtxhash2", null, 10, 0, true);
    defer alloc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "0xtxhash2") != null);
    const r4 = try client.queryEventLogs("test", "Transfer", null, null, null, null, 1, 0, true);
    defer alloc.free(r4);
    try std.testing.expect(std.mem.indexOf(u8, r4, "},{") == null);
    const r5 = try client.queryEventLogs("test", "Transfer", null, null, null, null, 10, 0, false);
    defer alloc.free(r5);
    try std.testing.expect(std.mem.indexOf(u8, r5, "0xtxhash") != null);
}

test "db queryEventLogs 支持按地址过滤且返回 contract_address" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{.{ .name = "value", .type = "uint256", .indexed = false }}, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"}, "");
    const fields = [_]DecodedField{.{ .name = "value", .value = "7" }};
    try client.insertEventLog("curve", "Transfer", &fields, 10, "0xt1", 0, "0xA");
    try client.insertEventLog("curve", "Transfer", &fields, 11, "0xt2", 0, "0xB");

    const all = try client.queryEventLogs("curve", "Transfer", null, null, null, null, 10, 0, true);
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "contract_address") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xA") != null);

    const only_b = try client.queryEventLogs("curve", "Transfer", null, null, null, "0xB", 10, 0, true);
    defer alloc.free(only_b);
    try std.testing.expect(std.mem.indexOf(u8, only_b, "0xA") == null);
    try std.testing.expect(std.mem.indexOf(u8, only_b, "0xB") != null);
}

test "db rollbackFromBlock" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"}, "0xtest");
    try client.createSnapshot(.{ .contract_address = "0xabc", .block_number = 100, .snapshot_data = "{}" });
    try client.createSnapshot(.{ .contract_address = "0xabc", .block_number = 200, .snapshot_data = "{}" });
    try client.upsertBlockHash("0xabc", 100, "0xhash100");
    try client.upsertBlockHash("0xabc", 200, "0xhash200");
    try client.rollbackFromBlock("0xabc", "test", &.{}, 150);
    const snap = try client.getLatestSnapshot("0xabc");
    defer if (snap) |s| { alloc.free(s.contract_address); alloc.free(s.snapshot_data); };
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 100), snap.?.block_number);
    const h100 = try client.getBlockHash("0xabc", 100);
    defer if (h100) |h| alloc.free(h);
    try std.testing.expect(h100 != null);
    try std.testing.expectEqualStrings("0xhash100", h100.?);
    const h200 = try client.getBlockHash("0xabc", 200);
    defer if (h200) |h| alloc.free(h);
    try std.testing.expect(h200 == null);
}

test "db sanitizeColumnName" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    {
        const col = try client.sanitizeColumnName("from");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_from", col);
    }
    {
        const col = try client.sanitizeColumnName("value");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_value", col);
    }
    {
        const col = try client.sanitizeColumnName("sender-address");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_sender_address", col);
    }
    {
        const col = try client.sanitizeColumnName("TokenID");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_tokenid", col);
    }
}

test "db deleteEventLogsInRange" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"}, "0xtest");
    const f = &.{ DecodedField{ .name = "from", .value = "0x1111" }, DecodedField{ .name = "to", .value = "0x2222" }, DecodedField{ .name = "value", .value = "0x64" } };
    try client.insertEventLog("test", "Transfer", f, 100, "0xtx1", 0, "0xtest");
    try client.insertEventLog("test", "Transfer", f, 200, "0xtx2", 1, "0xtest");
    try client.insertEventLog("test", "Transfer", f, 300, "0xtx3", 2, "0xtest");
    try client.deleteEventLogsInRange("test", "Transfer", 150, 250);
    const r = try client.queryEventLogs("test", "Transfer", null, null, null, null, 10, 0, true);
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx2") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx3") != null);
}

test "db rocksdb sync_state and block_hash" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.upsertSyncState(.{ .contract_address = "0x1234", .last_synced_block = 100, .status = "running" });
    const state = try client.getSyncState("0x1234");
    try std.testing.expect(state != null);
    try std.testing.expectEqual(@as(u64, 100), state.?.last_synced_block);
    alloc.free(state.?.contract_address);
    alloc.free(state.?.status);

    try client.upsertBlockHash("0x1234", 42, "0xdeadbeef");
    const hash = try client.getBlockHash("0x1234", 42);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("0xdeadbeef", hash.?);
    alloc.free(hash.?);
}

test "db rocksdb event insert and query" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb2", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    const fields = &.{ DecodedField{ .name = "from", .value = "0x1111" }, DecodedField{ .name = "to", .value = "0x2222" }, DecodedField{ .name = "value", .value = "0x64" } };
    try client.insertEventLog("test", "Transfer", fields, 100, "0xtxhash", 0, "0xtest");

    const result = try client.queryEventLogs("test", "Transfer", 0, null, null, null, 10, 0, true);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0xtxhash") != null);
}

test "db rocksdb count and delete" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb3", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    const f = &.{ DecodedField{ .name = "from", .value = "0xaa" }, DecodedField{ .name = "to", .value = "0xbb" } };
    try client.insertEventLog("t", "Evt", f, 100, "0x1", 0, "0xt");
    try client.insertEventLog("t", "Evt", f, 200, "0x2", 1, "0xt");
    try client.insertEventLog("t", "Evt", f, 300, "0x3", 2, "0xt");

    const count = try client.countEventRows("t", "Evt");
    try std.testing.expectEqual(@as(u64, 3), count);

    try client.deleteEventLogsInRange("t", "Evt", 150, 250);
    const count2 = try client.countEventRows("t", "Evt");
    try std.testing.expectEqual(@as(u64, 2), count2);
}

test "db rocksdb snapshot" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb4", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.createSnapshot(.{ .contract_address = "0xabc", .block_number = 50, .snapshot_data = "{\"test\":true}" });
    const snap = try client.getLatestSnapshot("0xabc");
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 50), snap.?.block_number);
    alloc.free(snap.?.contract_address);
    alloc.free(snap.?.snapshot_data);
}

test "db ponderExec/ponderQuery 参数绑定与类型往返" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    _ = try client.ponderExec("CREATE TABLE proj_t (a INTEGER, b REAL, c TEXT, d BLOB, e INTEGER);", &.{});
    const changes = try client.ponderExec(
        "INSERT INTO proj_t (a, b, c, d, e) VALUES (?, ?, ?, ?, ?);",
        &.{
            .{ .integer = 42 },
            .{ .float = 3.5 },
            .{ .text = "hello" },
            .{ .blob = &.{ 1, 2, 3 } },
            .null,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), changes);

    const rows = try client.ponderQuery("SELECT a, b, c, d, e FROM proj_t WHERE a = ?;", &.{.{ .integer = 42 }});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0];
    try std.testing.expectEqualStrings("a", row.names[0]);
    try std.testing.expectEqualStrings("e", row.names[4]);
    try std.testing.expectEqual(@as(i64, 42), row.values[0].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), row.values[1].float, 0.0001);
    try std.testing.expectEqualStrings("hello", row.values[2].text);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, row.values[3].blob);
    try std.testing.expect(row.values[4] == .null);

    // 空结果集
    const none = try client.ponderQuery("SELECT * FROM proj_t WHERE a = ?;", &.{.{ .integer = 999 }});
    defer client.freeQueryRows(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // 非 SELECT 走 query 返回空数组；SQL 错误返回错误
    const empty = try client.ponderQuery("UPDATE proj_t SET a = 1 WHERE a = 999;", &.{});
    defer client.freeQueryRows(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.PrepareFailed, client.ponderExec("THIS IS NOT SQL;", &.{}));
}

test "db rollbackFromBlock 级联清理 proj_ 投影表" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    _ = try client.ponderExec("CREATE TABLE proj_kline (block_number INTEGER NOT NULL, close TEXT);", &.{});
    // 非 proj_ 前缀的表不应被级联（用户自建表自行负责）
    _ = try client.ponderExec("CREATE TABLE other_data (block_number INTEGER NOT NULL);", &.{});
    for ([_]u64{ 100, 150, 200 }) |bn| {
        _ = try client.ponderExec("INSERT INTO proj_kline (block_number, close) VALUES (?, ?);", &.{ .{ .integer = @intCast(bn) }, .{ .text = "1.0" } });
        _ = try client.ponderExec("INSERT INTO other_data (block_number) VALUES (?);", &.{.{ .integer = @intCast(bn) }});
    }

    try client.rollbackFromBlock("0xabc", "test", &.{}, 150);

    const proj = try client.ponderQuery("SELECT block_number FROM proj_kline ORDER BY block_number;", &.{});
    defer client.freeQueryRows(proj);
    try std.testing.expectEqual(@as(usize, 1), proj.len);
    try std.testing.expectEqual(@as(i64, 100), proj[0].values[0].integer);

    const other = try client.ponderQuery("SELECT COUNT(*) AS n FROM other_data;", &.{});
    defer client.freeQueryRows(other);
    try std.testing.expectEqual(@as(i64, 3), other[0].values[0].integer);
}

test "db ponderExec/ponderQuery PostgreSQL 后端" {
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    // 独立测试库，避免污染 postgres 库
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_ponder_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_ponder_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_ponder_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    _ = try client.ponderExec("CREATE TABLE proj_pg_test (block_number BIGINT NOT NULL, v TEXT, n BIGINT, f DOUBLE PRECISION, b BYTEA);", &.{});

    const changes = try client.ponderExec(
        "INSERT INTO proj_pg_test (block_number, v, n, f, b) VALUES ($1, $2, $3, $4, $5);",
        &.{ .{ .integer = 100 }, .{ .text = "pg" }, .{ .integer = -5 }, .{ .float = 2.25 }, .{ .blob = &.{ 0xde, 0xad } } },
    );
    try std.testing.expectEqual(@as(usize, 1), changes);
    _ = try client.ponderExec("INSERT INTO proj_pg_test (block_number, v, n) VALUES ($1, $2, $3);", &.{ .{ .integer = 200 }, .null, .{ .integer = 1 } });

    const rows = try client.ponderQuery("SELECT block_number, v, n, f, b FROM proj_pg_test WHERE block_number = $1;", &.{.{ .integer = 100 }});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("block_number", rows[0].names[0]);
    try std.testing.expectEqual(@as(i64, 100), rows[0].values[0].integer);
    try std.testing.expectEqualStrings("pg", rows[0].values[1].text);
    try std.testing.expectEqual(@as(i64, -5), rows[0].values[2].integer);
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), rows[0].values[3].float, 0.0001);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, rows[0].values[4].blob);

    // NULL 往返
    const null_rows = try client.ponderQuery("SELECT v FROM proj_pg_test WHERE block_number = $1;", &.{.{ .integer = 200 }});
    defer client.freeQueryRows(null_rows);
    try std.testing.expect(null_rows[0].values[0] == .null);

    // 级联回滚：proj_ 表按 block_number 清理
    try client.rollbackFromBlock("0xabc", "test", &.{}, 150);
    const after = try client.ponderQuery("SELECT block_number FROM proj_pg_test ORDER BY block_number;", &.{});
    defer client.freeQueryRows(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(i64, 100), after[0].values[0].integer);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_ponder_test;", &.{}) catch {};
    cleanup.deinit();
}

test "db 事件表 contract_address 列：PostgreSQL 同 tx 不同合约与唯一键" {
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    // 独立测试库，避免污染 postgres 库
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_addr_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_addr_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_addr_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"}, "0xCLONE_A");

    const fields = [_]DecodedField{
        .{ .name = "from", .value = "0xaaa" },
        .{ .name = "value", .value = "1" },
    };
    // 同一 tx_hash/log_index，两个不同 clone：都必须存在（旧唯一键会把第二条顶掉）
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_A");
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_B");

    const rows = try client.ponderQuery("SELECT contract_address, COUNT(*) AS n FROM event_curve_Transfer GROUP BY contract_address ORDER BY contract_address;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("0xCLONE_A", rows[0].values[0].text);
    try std.testing.expectEqual(@as(i64, 1), rows[0].values[1].integer);
    try std.testing.expectEqualStrings("0xCLONE_B", rows[1].values[0].text);
    try std.testing.expectEqual(@as(i64, 1), rows[1].values[1].integer);

    // 同一地址重复插入被唯一键拒绝：libpq 返回 duplicate key，pg.zig 归一为 ExecFailed
    try std.testing.expectError(error.ExecFailed, client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_A"));

    // 被拒后库里仍是两条（每地址一行），确认是唯一键拦下而非行被覆盖
    const after = try client.ponderQuery("SELECT COUNT(*) AS n FROM event_curve_Transfer;", &.{});
    defer client.freeQueryRows(after);
    try std.testing.expectEqual(@as(i64, 2), after[0].values[0].integer);

    // 真实查询路径：地址列随 queryEventLogs 一起返回，两条都还在
    const listed = try client.queryEventLogs("curve", "Transfer", null, null, "0xtx1", null, 10, 0, true);
    defer alloc.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "0xCLONE_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "0xCLONE_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"contract_address\":") != null);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_addr_test;", &.{}) catch {};
    cleanup.deinit();
}

test "db 打开非 NUL 结尾路径（回归：C 字符串终止符）" {
    const alloc = std.testing.allocator;
    // 切片后紧跟非 0 字节，复现历史上 sqlite3_open_v2 读到越界垃圾的 CANTOPEN
    const real = "/tmp/_zponder_nul_test.db";
    const buf = try alloc.alloc(u8, real.len + 8);
    defer alloc.free(buf);
    @memcpy(buf[0..real.len], real);
    @memset(buf[real.len..], 'X');
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = buf[0..real.len], .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    _ = try client.ponderExec("CREATE TABLE IF NOT EXISTS nul_regress (a INTEGER);", &.{});
}

test "db 事件表 contract_address 列：同 tx 不同合约都能落库" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("curve", &ac, &.{"Transfer"}, "0xCLONE_A");

    const fields = [_]DecodedField{
        .{ .name = "from", .value = "0xaaa" },
        .{ .name = "value", .value = "1" },
    };
    // 同一 tx_hash/log_index，两个不同 clone：都必须存在（旧唯一键会把第二条顶掉）
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_A");
    try client.insertEventLog("curve", "Transfer", &fields, 100, "0xtx1", 0, "0xCLONE_B");

    const rows = try client.ponderQuery("SELECT contract_address, COUNT(*) AS n FROM event_curve_Transfer GROUP BY contract_address;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
}

test "db 老事件表迁移：补地址列并回填，行数不变" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    // 手工造"旧结构"表（无 contract_address、旧唯一键）
    try client.exec(
        \\CREATE TABLE event_dai_Transfer (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  evt_from TEXT, evt_value TEXT,
        \\  block_number INTEGER NOT NULL, tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(tx_hash, log_index));
    );
    try client.exec("INSERT INTO event_dai_Transfer (evt_from, evt_value, block_number, tx_hash, log_index) VALUES ('0xa','1',10,'0xt',0);");

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    // 迁移两次：必须幂等
    try client.migrateEventTableAddress("dai", &test_evt, "0xDAI");
    try client.migrateEventTableAddress("dai", &test_evt, "0xDAI");

    const rows = try client.ponderQuery("SELECT contract_address, evt_from, block_number FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0xDAI", rows[0].values[0].text);
    try std.testing.expectEqualStrings("0xa", rows[0].values[1].text);

    // 新唯一键已生效：迁移后插入不再报 no such column，且 (tx_hash, log_index) 相同
    // 而地址不同的两条都留得住，真重复才被拒
    const f = [_]DecodedField{.{ .name = "from", .value = "0xb" }};
    try client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER");
    const after = try client.ponderQuery("SELECT COUNT(*) AS n FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(after);
    try std.testing.expectEqual(@as(i64, 2), after[0].values[0].integer);
    try std.testing.expectError(error.ExecFailed, client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER"));
}

test "db 老事件表迁移（PostgreSQL）：补地址列并换唯一键" {
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_mig_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_mig_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_mig_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    // 手工造"旧结构"表（无 contract_address、旧唯一键），外加一条用户自加的唯一约束
    _ = try client.ponderExec(
        \\CREATE TABLE event_dai_Transfer (
        \\  id SERIAL PRIMARY KEY,
        \\  evt_from TEXT, evt_value TEXT,
        \\  block_number BIGINT NOT NULL, tx_hash TEXT NOT NULL, log_index BIGINT NOT NULL,
        \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(tx_hash, log_index),
        \\  UNIQUE(evt_value));
    , &.{});
    _ = try client.ponderExec("INSERT INTO event_dai_Transfer (evt_from, evt_value, block_number, tx_hash, log_index) VALUES ('0xa','1',10,'0xt',0);", &.{});

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };

    // 迁移两次：必须幂等
    try client.autoMigrateContract("dai", &ac, &.{"Transfer"}, "0xDAI");
    try client.autoMigrateContract("dai", &ac, &.{"Transfer"}, "0xDAI");

    const rows = try client.ponderQuery("SELECT contract_address, evt_from FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0xDAI", rows[0].values[0].text);
    try std.testing.expectEqualStrings("0xa", rows[0].values[1].text);

    // 唯一键已含地址：同 tx_hash/log_index 不同地址可共存，同地址重复被拒
    const f = [_]DecodedField{.{ .name = "from", .value = "0xb" }};
    try client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER");
    const after = try client.ponderQuery("SELECT COUNT(*) AS n FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(after);
    try std.testing.expectEqual(@as(i64, 2), after[0].values[0].integer);
    try std.testing.expectError(error.ExecFailed, client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER"));

    // 约束收尾状态：只把旧键换成含地址的键，用户自加的 UNIQUE(evt_value) 必须留着
    const cons = try client.ponderQuery("SELECT pg_get_constraintdef(c.oid) AS def FROM pg_constraint c WHERE c.conrelid = 'event_dai_Transfer'::regclass AND c.contype = 'u' ORDER BY 1;", &.{});
    defer client.freeQueryRows(cons);
    try std.testing.expectEqual(@as(usize, 2), cons.len);
    try std.testing.expectEqualStrings("UNIQUE (contract_address, tx_hash, log_index)", cons[0].values[0].text);
    try std.testing.expectEqualStrings("UNIQUE (evt_value)", cons[1].values[0].text);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_mig_test;", &.{}) catch {};
    cleanup.deinit();
}


test "db 老事件表迁移：已有地址列时保留原地址，只换唯一键" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    // 半迁移状态的表：已有地址列（且行上有真实地址），但唯一键还是旧的
    try client.exec(
        \\CREATE TABLE event_dai_Transfer (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  evt_from TEXT,
        \\  block_number INTEGER NOT NULL, tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
        \\  contract_address TEXT NOT NULL DEFAULT '',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(tx_hash, log_index));
    );
    try client.exec("INSERT INTO event_dai_Transfer (evt_from, block_number, tx_hash, log_index, contract_address) VALUES ('0xa',10,'0xt1',0,'0xAAA'), ('0xb',10,'0xt2',0,'0xBBB');");

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
    }, .signature = std.mem.zeroes([32]u8) };
    try client.migrateEventTableAddress("dai", &test_evt, "0xDAI");

    // 已有地址必须原样保留（不能被 0xDAI 覆盖），行数不变
    const rows = try client.ponderQuery("SELECT contract_address, evt_from FROM event_dai_Transfer ORDER BY id;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("0xAAA", rows[0].values[0].text);
    try std.testing.expectEqualStrings("0xBBB", rows[1].values[0].text);

    // 旧唯一键已被换掉：同 tx_hash/log_index 不同地址可共存
    const f = [_]DecodedField{.{ .name = "from", .value = "0xc" }};
    try client.insertEventLog("dai", "Transfer", &f, 20, "0xt1", 0, "0xCCC");
    const after = try client.ponderQuery("SELECT COUNT(*) AS n FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(after);
    try std.testing.expectEqual(@as(i64, 3), after[0].values[0].integer);
}

test "db 老事件表迁移（PostgreSQL）：别 schema 同名表不得干扰探测与改动" {
    const alloc = std.testing.allocator;
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_mig_schema_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_mig_schema_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_mig_schema_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    // 目标表（当前 schema）：旧结构 + 一行数据
    _ = try client.ponderExec(
        \\CREATE TABLE event_dai_Transfer (
        \\  id SERIAL PRIMARY KEY,
        \\  evt_from TEXT, evt_value TEXT,
        \\  block_number BIGINT NOT NULL, tx_hash TEXT NOT NULL, log_index BIGINT NOT NULL,
        \\  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(tx_hash, log_index));
    , &.{});
    _ = try client.ponderExec("INSERT INTO event_dai_Transfer (evt_from, evt_value, block_number, tx_hash, log_index) VALUES ('0xa','1',10,'0xt',0);", &.{});

    // 另一个 schema 的同名表，且已经带地址三元组唯一键：
    // 不限 schema 的探测会把它算成本表的约束 → 本表旧键被删却不补新键
    _ = try client.ponderExec("CREATE SCHEMA other;", &.{});
    _ = try client.ponderExec(
        \\CREATE TABLE other.event_dai_Transfer (
        \\  id SERIAL PRIMARY KEY,
        \\  evt_from TEXT,
        \\  contract_address TEXT NOT NULL DEFAULT '',
        \\  block_number BIGINT NOT NULL, tx_hash TEXT NOT NULL, log_index BIGINT NOT NULL,
        \\  UNIQUE(contract_address, tx_hash, log_index));
    , &.{});
    _ = try client.ponderExec("INSERT INTO other.event_dai_Transfer (evt_from, contract_address, block_number, tx_hash, log_index) VALUES ('0xz','0xOTHER',10,'0xt',0);", &.{});

    const other_cols_before = try client.ponderQuery("SELECT COUNT(*) AS n FROM information_schema.columns WHERE table_schema = 'other' AND table_name = 'event_dai_transfer';", &.{});
    defer client.freeQueryRows(other_cols_before);

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("dai", &ac, &.{"Transfer"}, "0xDAI");
    try client.autoMigrateContract("dai", &ac, &.{"Transfer"}, "0xDAI");

    // 目标表必须真的换成含地址的唯一键（不是「删了旧的、没补新的」）
    const cons = try client.ponderQuery("SELECT pg_get_constraintdef(c.oid) AS def FROM pg_constraint c WHERE c.conrelid = 'event_dai_Transfer'::regclass AND c.contype = 'u';", &.{});
    defer client.freeQueryRows(cons);
    try std.testing.expectEqual(@as(usize, 1), cons.len);
    try std.testing.expectEqualStrings("UNIQUE (contract_address, tx_hash, log_index)", cons[0].values[0].text);

    // 旧行地址已回填
    const rows = try client.ponderQuery("SELECT contract_address FROM event_dai_Transfer;", &.{});
    defer client.freeQueryRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0xDAI", rows[0].values[0].text);

    // 唯一键真的在起作用：同 (tx_hash, log_index) 不同地址可共存，真重复被拒
    const f = [_]DecodedField{.{ .name = "from", .value = "0xb" }};
    try client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER");
    try std.testing.expectError(error.ExecFailed, client.insertEventLog("dai", "Transfer", &f, 10, "0xt", 0, "0xOTHER"));

    // 别 schema 的同名表必须原封不动：列数、唯一约束、数据都不变
    const other_cols_after = try client.ponderQuery("SELECT COUNT(*) AS n FROM information_schema.columns WHERE table_schema = 'other' AND table_name = 'event_dai_transfer';", &.{});
    defer client.freeQueryRows(other_cols_after);
    try std.testing.expectEqual(other_cols_before[0].values[0].integer, other_cols_after[0].values[0].integer);

    const other_cons = try client.ponderQuery("SELECT pg_get_constraintdef(c.oid) AS def FROM pg_constraint c WHERE c.conrelid = 'other.event_dai_Transfer'::regclass AND c.contype = 'u';", &.{});
    defer client.freeQueryRows(other_cons);
    try std.testing.expectEqual(@as(usize, 1), other_cons.len);
    try std.testing.expectEqualStrings("UNIQUE (contract_address, tx_hash, log_index)", other_cons[0].values[0].text);

    const other_rows = try client.ponderQuery("SELECT evt_from, contract_address FROM other.event_dai_Transfer;", &.{});
    defer client.freeQueryRows(other_rows);
    try std.testing.expectEqual(@as(usize, 1), other_rows.len);
    try std.testing.expectEqualStrings("0xz", other_rows[0].values[0].text);
    try std.testing.expectEqualStrings("0xOTHER", other_rows[0].values[1].text);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_mig_schema_test;", &.{}) catch {};
    cleanup.deinit();
}

test "db queryEventLogs PostgreSQL 区块区间过滤（回归：参数悬垂切片）" {
    // 修复前：queryEventLogsPG 把块号/分页参数格式化进块作用域里的栈上 [21]u8，
    // 切片入 params 时其生存期已结束；四段 buf 共用栈槽，后面的写入覆盖前面的值，
    // 于是 `block_from=150, block_to=250, limit=10, offset=0` 实际过滤成 0~0 行。
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    // 独立测试库，避免污染 postgres 库
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_qlog_pg_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_qlog_pg_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_qlog_pg_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{
        .{ .name = "from", .type = "address", .indexed = true },
        .{ .name = "value", .type = "uint256", .indexed = false },
    }, .signature = std.mem.zeroes([32]u8) };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const ac = abi.AbiContract{ .events = events, .functions = &.{} };
    try client.autoMigrateContract("qlog", &ac, &.{"Transfer"}, "0xADDR");

    const fields = [_]DecodedField{
        .{ .name = "from", .value = "0xaaa" },
        .{ .name = "value", .value = "1" },
    };
    try client.insertEventLog("qlog", "Transfer", &fields, 100, "0xtx1", 0, "0xADDR");
    try client.insertEventLog("qlog", "Transfer", &fields, 200, "0xtx2", 0, "0xADDR");
    try client.insertEventLog("qlog", "Transfer", &fields, 300, "0xtx3", 0, "0xADDR");

    // 无区间过滤：三行都要在（顺带覆盖 limit/offset 参数本身）
    const all = try client.queryEventLogs("qlog", "Transfer", null, null, null, null, 10, 0, true);
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xtx1") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xtx2") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xtx3") != null);

    // 区间 150~250：只剩 block 200 那行；参数被覆盖时这里会变成 0 行或报错
    const ranged = try client.queryEventLogs("qlog", "Transfer", 150, 250, null, null, 10, 0, true);
    defer alloc.free(ranged);
    try std.testing.expect(std.mem.indexOf(u8, ranged, "0xtx2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ranged, "0xtx1") == null);
    try std.testing.expect(std.mem.indexOf(u8, ranged, "0xtx3") == null);

    // 只给 block_from：同样要带上正确的参数值
    const from_only = try client.queryEventLogs("qlog", "Transfer", 250, null, null, null, 10, 0, true);
    defer alloc.free(from_only);
    try std.testing.expect(std.mem.indexOf(u8, from_only, "0xtx3") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_only, "0xtx1") == null);
    try std.testing.expect(std.mem.indexOf(u8, from_only, "0xtx2") == null);

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_qlog_pg_test;", &.{}) catch {};
    cleanup.deinit();
}

test "db rocksdb queryEventLogs 带地址过滤不得静默返回全量" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb_addr_filter", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    const fields = &.{DecodedField{ .name = "from", .value = "0x1111" }};
    try client.insertEventLog("t", "Transfer", fields, 100, "0xaddrfiltertx1", 0, "0xAAA");
    try client.insertEventLog("t", "Transfer", fields, 200, "0xaddrfiltertx2", 0, "0xBBB");

    // 不带地址过滤：行为不变（两条都返回）
    const all = try client.queryEventLogs("t", "Transfer", null, null, null, null, 10, 0, true);
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xaddrfiltertx1") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "0xaddrfiltertx2") != null);

    // 带地址过滤：RocksDB 事件 key 不含地址列，只能报不支持。
    // 修复前这里静默返回上面两条（错答）而不是报错。
    try std.testing.expectError(
        error.UnsupportedOperation,
        client.queryEventLogs("t", "Transfer", null, null, null, "0xAAA", 10, 0, true),
    );
    try std.testing.expectError(
        error.UnsupportedOperation,
        client.queryEventLogs("t", "Transfer", 0, null, null, "0xBBB", 10, 0, true),
    );
}

test "db ponderQuery 行内部分填充失败路径不泄漏" {
    // 修复前：ponderQuerySqlite 逐列填充时，names[i]/values[i] 的 dupe 已入数组，
    // 但内层 errdefer 只释放数组本身、外层 errdefer 只处理已 append 的完整行 →
    // "当前行填到一半"失败会泄漏本行已填充的列名与值。
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();

    _ = try client.ponderExec("CREATE TABLE proj_fill (a TEXT, b TEXT, c TEXT);", &.{});
    _ = try client.ponderExec("INSERT INTO proj_fill (a, b, c) VALUES ('a1','b1','c1'), ('a2','b2','c2'), ('a3','b3','c3');", &.{});

    const sql = "SELECT a, b, c FROM proj_fill ORDER BY a;";

    // 先数出一次成功调用的分配点数
    var counter = std.testing.FailingAllocator.init(alloc, .{});
    client.alloc = counter.allocator();
    {
        const rows = try client.ponderQuery(sql, &.{});
        client.freeQueryRows(rows);
    }
    try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    const total = counter.alloc_index;
    try std.testing.expect(total > 8);

    // 对每个分配点逐个注入失败：必须报 OutOfMemory，且分配/释放字节数相等
    for (0..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        client.alloc = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, client.ponderQuery(sql, &.{}));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    client.alloc = alloc;
}

/// 用同深度的兄弟调用覆写「刚返回的函数用过的栈区」——悬垂栈切片的标准暴露方式
/// （调用方与它调用的函数共用同一片栈地址，兄弟调用会覆盖其内容）。
noinline fn clobberStackRegion() void {
    var junk: [512]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
}

test "db queryEventLogsPG 参数构建不得依赖调用方的栈帧" {
    // 修复前：块号/分页参数被格式化进 buildEventLogsPgParams 里块作用域的栈上 [21]u8，
    // 函数返回后切片失效 → 调用方读到的内容已被后续（同深度）调用覆写。
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var params: std.ArrayList([]const u8) = .empty;
    defer params.deinit(alloc);

    try client.buildEventLogsPgParams(arena.allocator(), 150, 250, "0xtx", "0xAAA", 10, 0, &params);
    clobberStackRegion();

    try std.testing.expectEqual(@as(usize, 6), params.items.len);
    const expected = [_][]const u8{ "150", "250", "0xtx", "0xAAA", "10", "0" };
    for (expected, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, params.items[i]);
    }

    // 只给 block_from（其余为 null）也要正确
    var only_from: std.ArrayList([]const u8) = .empty;
    defer only_from.deinit(alloc);
    try client.buildEventLogsPgParams(arena.allocator(), 42, null, null, null, 5, 7, &only_from);
    clobberStackRegion();
    const expected2 = [_][]const u8{ "42", "5", "7" };
    for (expected2, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, only_from.items[i]);
    }
}

test "db ponderQuery PostgreSQL 行内部分填充失败路径不泄漏" {
    // 与 sqlite 版同型：ponderQueryPG 逐列填充时 names[col]/values[col] 的 dupe 已入数组，
    // 但内层 errdefer 只释放 names/values 数组本身、外层 errdefer 只处理已填满的行 →
    // "当前行填到一半"失败会泄漏本行已 dupe 的列名与值（.text 与 .blob 都要释放）。
    const alloc = std.testing.allocator;
    // 无本地 PG 时跳过（CI 不装 PG）
    const admin_cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=postgres", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var admin = Client.init(alloc, &admin_cfg) catch return error.SkipZigTest;
    // 独立测试库，避免污染 postgres 库
    _ = admin.ponderExec("DROP DATABASE IF EXISTS zponder_pgfill_test;", &.{}) catch {};
    _ = admin.ponderExec("CREATE DATABASE zponder_pgfill_test;", &.{}) catch {
        admin.deinit();
        return error.SkipZigTest;
    };
    admin.deinit();

    const cfg = DatabaseConfig{ .db_type = "postgresql", .db_name = "host=localhost port=5432 dbname=zponder_pgfill_test", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    try client.migrate();

    // 第一列 TEXT、末列 BYTEA：两者都会在 pgValueFromText 里分配（INTEGER 不分配），
    // 于是"第 col>0 列失败"时既有列名也有已分配的值需要清理
    _ = try client.ponderExec("CREATE TABLE proj_pg_fill (v TEXT, n BIGINT, b BYTEA);", &.{});
    _ = try client.ponderExec("INSERT INTO proj_pg_fill (v, n, b) VALUES ('v1', 1, '\\x01'::bytea), ('v2', 2, '\\x0203'::bytea);", &.{});

    const sql = "SELECT v, n, b FROM proj_pg_fill ORDER BY v;";

    // 先数出一次成功调用的分配点数（注：pg.Client 自身的分配不走 client.alloc）
    var counter = std.testing.FailingAllocator.init(alloc, .{});
    client.alloc = counter.allocator();
    {
        const rows = try client.ponderQuery(sql, &.{});
        client.freeQueryRows(rows);
    }
    try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    const total = counter.alloc_index;
    try std.testing.expect(total > 10);

    // 对每个分配点逐个注入失败：必须报 OutOfMemory，且分配/释放字节数相等
    for (0..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        client.alloc = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, client.ponderQuery(sql, &.{}));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    client.alloc = alloc;

    // 清理测试库
    client.deinit();
    var cleanup = Client.init(alloc, &admin_cfg) catch return;
    _ = cleanup.ponderExec("DROP DATABASE IF EXISTS zponder_pgfill_test;", &.{}) catch {};
    cleanup.deinit();
}
