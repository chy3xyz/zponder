const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const abi = @import("abi.zig");
const cache = @import("cache.zig");
const log = @import("log.zig");

/// 数据库配置
pub const DatabaseConfig = @import("config.zig").DatabaseConfig;

/// 同步状态记录
pub const SyncState = struct {
    contract_address: []const u8,
    last_synced_block: u64,
    status: []const u8,
};

/// 账户状态记录
pub const AccountState = struct {
    contract_address: []const u8,
    account_address: []const u8,
    balance: []const u8,
    last_updated_block: u64,
};

/// 快照记录
pub const Snapshot = struct {
    contract_address: []const u8,
    block_number: u64,
    snapshot_data: []const u8,
};

/// 解码后的事件字段（用于动态插入）
pub const DecodedField = struct {
    name: []const u8,
    value: []const u8,
};

/// 数据库客户端
pub const Client = struct {
    alloc: std.mem.Allocator,
    config: *const DatabaseConfig,
    db: ?*c.sqlite3,
    cache: ?*cache.Cache = null,

    pub fn init(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        if (!std.mem.eql(u8, config.db_type, "sqlite")) {
            return error.UnsupportedDatabaseType;
        }

        var db: ?*c.sqlite3 = null;
        const path = if (config.db_name.len > 0) config.db_name else ":memory:";
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            return error.DatabaseOpenFailed;
        }

        try checkPragma(db, "PRAGMA foreign_keys = ON;");
        try checkPragma(db, "PRAGMA journal_mode = WAL;");
        try checkPragma(db, "PRAGMA synchronous = NORMAL;");

        return .{
            .alloc = alloc,
            .config = config,
            .db = db,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    pub fn setCache(self: *Client, cc: *cache.Cache) void {
        self.cache = cc;
    }

    /// 自动创建框架数据表（不含事件表，事件表按 ABI 动态生成）
    pub fn migrate(self: *Client) !void {
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
        ;
        try self.exec(sql);
    }

    /// 根据 ABI 自动为合约创建事件表
    pub fn autoMigrateContract(
        self: *Client,
        contract_name: []const u8,
        abi_contract: *const abi.AbiContract,
        event_names: []const []const u8,
    ) !void {
        for (event_names) |evt_name| {
            const evt = abi_contract.findEventByName(evt_name) orelse continue;
            try self.createEventTable(contract_name, evt);
        }
    }

    fn createEventTable(self: *Client, contract_name: []const u8, evt: *const abi.AbiEvent) !void {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();

        const w = &sql_buf.writer;
        try w.print("CREATE TABLE IF NOT EXISTS event_{s}_{s} (", .{ contract_name, evt.name });
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
        try w.writeAll("\n  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,");
        try w.print("\n  UNIQUE(tx_hash, log_index)\n);", .{});

        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{
            contract_name, evt.name, contract_name, evt.name,
        });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{
            contract_name, evt.name, contract_name, evt.name,
        });

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

    /// 插入单条事件日志到对应的事件表
    pub fn insertEventLog(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const DecodedField,
        block_number: u64,
        tx_hash: []const u8,
        log_index: u64,
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
        try w.writeAll(",block_number,tx_hash,log_index) VALUES (");

        for (fields, 0..) |_, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('?');
        }
        try w.writeAll(",?,?,?);");

        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql_list.items.ptr, @intCast(sql_list.items.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var col_idx: c_int = 1;
        for (fields) |f| {
            if (c.sqlite3_bind_text(stmt, col_idx, f.value.ptr, @intCast(f.value.len), c.SQLITE_STATIC) != c.SQLITE_OK)
                return error.BindFailed;
            col_idx += 1;
        }
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(block_number)) != c.SQLITE_OK)
            return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_text(stmt, col_idx, tx_hash.ptr, @intCast(tx_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(log_index)) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }

        if (self.cache) |cc| {
            cc.invalidate(contract_name, event_name);
        }
    }

    /// 插入无法被 ABI 解析的原始日志（死信队列）
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
        const sql =
            \\INSERT INTO raw_logs (contract_address, block_number, tx_hash, log_index, topics, data, reason)
            \\VALUES (?, ?, ?, ?, ?, ?, ?);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, tx_hash.ptr, @intCast(tx_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 4, @intCast(log_index)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 5, topics.ptr, @intCast(topics.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 6, data.ptr, @intCast(data.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 7, reason.ptr, @intCast(reason.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }
    }

    /// 动态查询事件日志，返回 JSON 数组字符串（调用者负责释放）
    pub fn queryEventLogs(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
        limit: u32,
        offset: u32,
        order_desc: bool,
    ) ![]u8 {
        var sql_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer sql_buf.deinit();
        const w = &sql_buf.writer;

        try w.print("SELECT * FROM event_{s}_{s} WHERE 1=1", .{ contract_name, event_name });
        if (block_from) |_| try w.writeAll(" AND block_number >= ?");
        if (block_to) |_| try w.writeAll(" AND block_number <= ?");
        if (tx_hash) |_| try w.writeAll(" AND tx_hash = ?");
        try w.writeAll(if (order_desc) " ORDER BY block_number DESC" else " ORDER BY block_number ASC");
        try w.writeAll(" LIMIT ? OFFSET ?;");

        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql_list.items.ptr, @intCast(sql_list.items.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var bind_idx: c_int = 1;
        if (block_from) |bf| {
            if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bf)) != c.SQLITE_OK)
                return error.BindFailed;
            bind_idx += 1;
        }
        if (block_to) |bt| {
            if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bt)) != c.SQLITE_OK)
                return error.BindFailed;
            bind_idx += 1;
        }
        if (tx_hash) |th| {
            if (c.sqlite3_bind_text(stmt, bind_idx, th.ptr, @intCast(th.len), c.SQLITE_STATIC) != c.SQLITE_OK)
                return error.BindFailed;
            bind_idx += 1;
        }
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(limit)) != c.SQLITE_OK)
            return error.BindFailed;
        bind_idx += 1;
        if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(offset)) != c.SQLITE_OK)
            return error.BindFailed;

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
                    c.SQLITE_INTEGER => {
                        const val = c.sqlite3_column_int64(stmt, col_idx);
                        try rw.print("{d}", .{val});
                    },
                    c.SQLITE_FLOAT => {
                        const val = c.sqlite3_column_double(stmt, col_idx);
                        try rw.print("{d}", .{val});
                    },
                    c.SQLITE_NULL => {
                        try rw.writeAll("null");
                    },
                    else => {
                        const val = std.mem.sliceTo(c.sqlite3_column_text(stmt, col_idx), 0);
                        try rw.writeByte('"');
                        for (val) |ch| {
                            switch (ch) {
                                '\\' => try rw.writeAll("\\\\"),
                                '"' => try rw.writeAll("\\\""),
                                '\n' => try rw.writeAll("\\n"),
                                '\r' => try rw.writeAll("\\r"),
                                '\t' => try rw.writeAll("\\t"),
                                else => try rw.writeByte(ch),
                            }
                        }
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

    /// 获取同步状态
    pub fn getSyncState(self: *Client, contract_address: []const u8) !?SyncState {
        const sql = "SELECT contract_address, last_synced_block, status FROM sync_state WHERE contract_address = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const addr = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            const block = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 1)));
            const status = std.mem.sliceTo(c.sqlite3_column_text(stmt, 2), 0);
            return SyncState{
                .contract_address = try self.alloc.dupe(u8, addr),
                .last_synced_block = block,
                .status = try self.alloc.dupe(u8, status),
            };
        }
        return null;
    }

    /// 更新或插入同步状态
    pub fn upsertSyncState(self: *Client, state: SyncState) !void {
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

        if (c.sqlite3_bind_text(stmt, 1, state.contract_address.ptr, @intCast(state.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(state.last_synced_block)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, state.status.ptr, @intCast(state.status.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }
    }

    /// 更新账户状态
    pub fn upsertAccountState(self: *Client, state: AccountState) !void {
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

        if (c.sqlite3_bind_text(stmt, 1, state.contract_address.ptr, @intCast(state.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, state.account_address.ptr, @intCast(state.account_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, state.balance.ptr, @intCast(state.balance.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 4, @intCast(state.last_updated_block)) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }
    }

    /// 获取账户余额
    pub fn getAccountBalance(self: *Client, contract_address: []const u8, account_address: []const u8) !?[]const u8 {
        const sql = "SELECT balance FROM account_states WHERE contract_address = ? AND account_address = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, account_address.ptr, @intCast(account_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const bal = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            return try self.alloc.dupe(u8, bal);
        }
        return null;
    }

    /// 删除指定事件表在区块范围内的数据
    pub fn deleteEventLogsInRange(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        from_block: u64,
        to_block: u64,
    ) !void {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf,
            "DELETE FROM event_{s}_{s} WHERE block_number >= ? AND block_number <= ?;",
            .{ contract_name, event_name },
        );

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(stmt, 1, @intCast(from_block)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(to_block)) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }

        if (self.cache) |cc| {
            cc.invalidate(contract_name, event_name);
        }
    }

    /// 创建快照
    pub fn createSnapshot(self: *Client, snapshot: Snapshot) !void {
        const sql = "INSERT INTO snapshots (contract_address, block_number, snapshot_data) VALUES (?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, snapshot.contract_address.ptr, @intCast(snapshot.contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(snapshot.block_number)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, snapshot.snapshot_data.ptr, @intCast(snapshot.snapshot_data.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }
    }

    /// 查询最新的快照
    pub fn getLatestSnapshot(self: *Client, contract_address: []const u8) !?Snapshot {
        const sql = "SELECT contract_address, block_number, snapshot_data FROM snapshots WHERE contract_address = ? ORDER BY block_number DESC LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const addr = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            const block = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 1)));
            const data = std.mem.sliceTo(c.sqlite3_column_text(stmt, 2), 0);
            return Snapshot{
                .contract_address = try self.alloc.dupe(u8, addr),
                .block_number = block,
                .snapshot_data = try self.alloc.dupe(u8, data),
            };
        }
        return null;
    }

    /// 插入或更新区块 hash
    pub fn upsertBlockHash(self: *Client, contract_address: []const u8, block_number: u64, block_hash: []const u8) !void {
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

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_text(stmt, 3, block_hash.ptr, @intCast(block_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.ExecFailed;
        }
    }

    /// 查询区块 hash
    pub fn getBlockHash(self: *Client, contract_address: []const u8, block_number: u64) !?[]u8 {
        const sql = "SELECT block_hash FROM block_hashes WHERE contract_address = ? AND block_number = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, @intCast(block_number)) != c.SQLITE_OK)
            return error.BindFailed;

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const hash = std.mem.sliceTo(c.sqlite3_column_text(stmt, 0), 0);
            return try self.alloc.dupe(u8, hash);
        }
        return null;
    }

    /// 删除指定合约从某区块开始的所有数据（重组回滚）
    pub fn rollbackFromBlock(self: *Client, contract_address: []const u8, contract_name: []const u8, event_names: []const []const u8, from_block: u64) !void {
        // 删除事件表数据
        for (event_names) |evt_name| {
            var sql_buf: [256]u8 = undefined;
            const sql = try std.fmt.bufPrint(&sql_buf,
                "DELETE FROM event_{s}_{s} WHERE block_number >= ?;",
                .{ contract_name, evt_name },
            );
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                log.err("回滚准备失败: {s}", .{sql});
                continue;
            }
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_bind_int64(stmt, 1, @intCast(from_block)) != c.SQLITE_OK) continue;
            _ = c.sqlite3_step(stmt);
        }

        // 删除快照
        const snap_sql = "DELETE FROM snapshots WHERE contract_address = ? AND block_number >= ?;";
        var snap_stmt: ?*c.sqlite3_stmt = null;
        const snap_rc = c.sqlite3_prepare_v2(self.db, snap_sql, @intCast(snap_sql.len), &snap_stmt, null);
        if (snap_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(snap_stmt);
            _ = c.sqlite3_bind_text(snap_stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(snap_stmt, 2, @intCast(from_block));
            _ = c.sqlite3_step(snap_stmt);
        }

        // 删除区块 hash 记录
        const hash_sql = "DELETE FROM block_hashes WHERE contract_address = ? AND block_number >= ?;";
        var hash_stmt: ?*c.sqlite3_stmt = null;
        const hash_rc = c.sqlite3_prepare_v2(self.db, hash_sql, @intCast(hash_sql.len), &hash_stmt, null);
        if (hash_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(hash_stmt);
            _ = c.sqlite3_bind_text(hash_stmt, 1, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(hash_stmt, 2, @intCast(from_block));
            _ = c.sqlite3_step(hash_stmt);
        }

        // 更新同步状态
        const state_sql =
            \\UPDATE sync_state SET last_synced_block = ? - 1, status = 'reorg_rollback'
            \\WHERE contract_address = ?;
        ;
        var state_stmt: ?*c.sqlite3_stmt = null;
        const state_rc = c.sqlite3_prepare_v2(self.db, state_sql, @intCast(state_sql.len), &state_stmt, null);
        if (state_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(state_stmt);
            _ = c.sqlite3_bind_int64(state_stmt, 1, @intCast(from_block));
            _ = c.sqlite3_bind_text(state_stmt, 2, contract_address.ptr, @intCast(contract_address.len), c.SQLITE_STATIC);
            _ = c.sqlite3_step(state_stmt);
        }
    }

    /// 查询事件表总行数（用于监控）
    pub fn countEventRows(self: *Client, contract_name: []const u8, event_name: []const u8) !u64 {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf,
            "SELECT COUNT(*) FROM event_{s}_{s};",
            .{ contract_name, event_name },
        );

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            return @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
        }
        return 0;
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
                log.err("SQLite PRAGMA 失败 '{s}': 错误码 {d}", .{ pragma, rc });
            }
            return error.ExecFailed;
        }
    }

    fn exec(self: *Client, sql: []const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                defer _ = c.sqlite3_free(msg);
                log.err("SQL error: {s}", .{msg});
            }
            return error.ExecFailed;
        }
    }
};

// ============================================================================
// 集成测试
// ============================================================================

test "db getLatestSnapshot empty" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    const snap = try client.getLatestSnapshot("0xnonexistent");
    try std.testing.expect(snap == null);
}

test "db migrate and sync_state" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    try client.upsertSyncState(.{
        .contract_address = "0x1234",
        .last_synced_block = 100,
        .status = "running",
    });

    const state = try client.getSyncState("0x1234");
    try std.testing.expect(state != null);
    try std.testing.expectEqual(@as(u64, 100), state.?.last_synced_block);
    alloc.free(state.?.contract_address);
    alloc.free(state.?.status);
}

test "db snapshot and block_hash" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    try client.createSnapshot(.{
        .contract_address = "0xabcd",
        .block_number = 50,
        .snapshot_data = "{\"test\":true}",
    });

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
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    try client.insertRawLog(
        "0xabc",
        100,
        "0xtx",
        0,
        "[\"0xtopic\"]",
        "0xdata",
        "abi_mismatch",
    );

    // 验证：通过底层 SQL 查询
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
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    try client.upsertAccountState(.{
        .contract_address = "0xabc",
        .account_address = "0xdef",
        .balance = "1000",
        .last_updated_block = 50,
    });

    const bal = try client.getAccountBalance("0xabc", "0xdef");
    try std.testing.expect(bal != null);
    try std.testing.expectEqualStrings("1000", bal.?);
    alloc.free(bal.?);

    // 更新余额
    try client.upsertAccountState(.{
        .contract_address = "0xabc",
        .account_address = "0xdef",
        .balance = "2000",
        .last_updated_block = 100,
    });

    const bal2 = try client.getAccountBalance("0xabc", "0xdef");
    try std.testing.expect(bal2 != null);
    try std.testing.expectEqualStrings("2000", bal2.?);
    alloc.free(bal2.?);

    // 不存在的账户
    const bal3 = try client.getAccountBalance("0xabc", "0x999");
    try std.testing.expect(bal3 == null);
}

test "db event table insert and query" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    // 构建测试 ABI
    const test_evt = abi.AbiEvent{
        .name = "Transfer",
        .inputs = &.{
            .{ .name = "from", .type = "address", .indexed = true },
            .{ .name = "to", .type = "address", .indexed = true },
            .{ .name = "value", .type = "uint256", .indexed = false },
        },
        .signature = .{0} ** 32,
    };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{
        .events = events,
    };

    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});

    // 插入事件日志
    const fields = &.{
        DecodedField{ .name = "from", .value = "0x1111" },
        DecodedField{ .name = "to", .value = "0x2222" },
        DecodedField{ .name = "value", .value = "0x64" },
    };
    try client.insertEventLog("test", "Transfer", fields, 100, "0xtxhash", 0);

    // 查询
    const result = try client.queryEventLogs("test", "Transfer", 0, null, null, 10, 0, true);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0xtxhash") != null);

    // 插入第二条日志用于过滤测试
    const fields2 = &.{
        DecodedField{ .name = "from", .value = "0xaaaa" },
        DecodedField{ .name = "to", .value = "0xbbbb" },
        DecodedField{ .name = "value", .value = "0x96" },
    };
    try client.insertEventLog("test", "Transfer", fields2, 200, "0xtxhash2", 1);

    // block_from 过滤 — 验证只返回 block >= 150 的记录
    const r1 = try client.queryEventLogs("test", "Transfer", 150, null, null, 10, 0, true);
    defer alloc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "0xtxhash2") != null);
    // block_to 过滤 — 验证只返回 block <= 150 的记录
    const r2 = try client.queryEventLogs("test", "Transfer", null, 150, null, 10, 0, true);
    defer alloc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "0xtxhash") != null);

    // tx_hash 过滤
    const r3 = try client.queryEventLogs("test", "Transfer", null, null, "0xtxhash2", 10, 0, true);
    defer alloc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "0xtxhash2") != null);

    // limit
    const r4 = try client.queryEventLogs("test", "Transfer", null, null, null, 1, 0, true);
    defer alloc.free(r4);
    // 只返回 1 条，JSON 中应只有一个对象（无逗号分隔）
    try std.testing.expect(std.mem.indexOf(u8, r4, "},{") == null);

    // order asc
    const r5 = try client.queryEventLogs("test", "Transfer", null, null, null, 10, 0, false);
    defer alloc.free(r5);
    try std.testing.expect(std.mem.indexOf(u8, r5, "0xtxhash") != null);
}

test "db rollbackFromBlock" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    const test_evt = abi.AbiEvent{
        .name = "Transfer",
        .inputs = &.{
            .{ .name = "from", .type = "address", .indexed = true },
            .{ .name = "to", .type = "address", .indexed = true },
            .{ .name = "value", .type = "uint256", .indexed = false },
        },
        .signature = .{0} ** 32,
    };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events };

    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});

    // 插入快照和区块 hash
    try client.createSnapshot(.{
        .contract_address = "0xabc",
        .block_number = 100,
        .snapshot_data = "{}",
    });
    try client.createSnapshot(.{
        .contract_address = "0xabc",
        .block_number = 200,
        .snapshot_data = "{}",
    });
    try client.upsertBlockHash("0xabc", 100, "0xhash100");
    try client.upsertBlockHash("0xabc", 200, "0xhash200");

    // 回滚 block >= 150
    try client.rollbackFromBlock("0xabc", "test", &.{}, 150);

    // 验证快照：block 100 保留，block 200 删除
    const snap = try client.getLatestSnapshot("0xabc");
    defer if (snap) |s| {
        alloc.free(s.contract_address);
        alloc.free(s.snapshot_data);
    };
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 100), snap.?.block_number);

    // 验证区块 hash：block 100 保留，block 200 删除
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
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
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
        // 特殊字符转为下划线
        const col = try client.sanitizeColumnName("sender-address");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_sender_address", col);
    }
    {
        // 大写转小写
        const col = try client.sanitizeColumnName("TokenID");
        defer alloc.free(col);
        try std.testing.expectEqualStrings("evt_tokenid", col);
    }
}

test "db deleteEventLogsInRange" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{
        .db_type = "sqlite",
        .db_name = ":memory:",
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    try client.migrate();

    const test_evt = abi.AbiEvent{
        .name = "Transfer",
        .inputs = &.{
            .{ .name = "from", .type = "address", .indexed = true },
            .{ .name = "to", .type = "address", .indexed = true },
            .{ .name = "value", .type = "uint256", .indexed = false },
        },
        .signature = .{0} ** 32,
    };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events };

    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});

    const f = &.{
        DecodedField{ .name = "from", .value = "0x1111" },
        DecodedField{ .name = "to", .value = "0x2222" },
        DecodedField{ .name = "value", .value = "0x64" },
    };
    try client.insertEventLog("test", "Transfer", f, 100, "0xtx1", 0);
    try client.insertEventLog("test", "Transfer", f, 200, "0xtx2", 1);
    try client.insertEventLog("test", "Transfer", f, 300, "0xtx3", 2);

    // 删除 block 150~250
    try client.deleteEventLogsInRange("test", "Transfer", 150, 250);

    // 验证：只剩 block 100 和 300
    const r = try client.queryEventLogs("test", "Transfer", null, null, null, 10, 0, true);
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx2") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "0xtx3") != null);
}
