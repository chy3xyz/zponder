const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
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

pub const DecodedField = struct {
    name: []const u8,
    value: []const u8,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    config: *const DatabaseConfig,
    backend_type: BackendType,
    db: ?*c.sqlite3,
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
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) return error.DatabaseOpenFailed;
        try checkPragma(db, "PRAGMA foreign_keys = ON;");
        try checkPragma(db, "PRAGMA journal_mode = WAL;");
        try checkPragma(db, "PRAGMA synchronous = NORMAL;");
        return .{ .alloc = alloc, .config = config, .backend_type = .sqlite, .db = db, .rocks = null, .pgconn = null };
    }

    fn initRocksDB(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        const path = if (config.db_name.len > 0) config.db_name else "rocksdb_data";
        const rc = try rocksdb.Client.init(alloc, path);
        return .{ .alloc = alloc, .config = config, .backend_type = .rocksdb, .db = null, .rocks = rc, .pgconn = null };
    }

    fn initPostgreSQL(alloc: std.mem.Allocator, config: *const DatabaseConfig) !Client {
        const conninfo = if (config.db_name.len > 0) config.db_name else "host=localhost port=5432 dbname=zponder";
        const conn = try pg.Client.init(alloc, conninfo);
        return .{ .alloc = alloc, .config = config, .backend_type = .postgresql, .db = null, .rocks = null, .pgconn = conn };
    }

    pub fn deinit(self: *Client) void {
        switch (self.backend_type) {
            .sqlite => { if (self.db) |db| { _ = c.sqlite3_close(db); self.db = null; } },
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
        ;
        try self.exec(sql);
    }

    pub fn autoMigrateContract(
        self: *Client,
        contract_name: []const u8,
        abi_contract: *const abi.AbiContract,
        event_names: []const []const u8,
    ) !void {
        if (self.backend_type == .rocksdb) return;
        if (self.backend_type == .postgresql) return self.autoMigrateContractPG(contract_name, abi_contract, event_names);
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
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{ contract_name, evt.name, contract_name, evt.name });
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
    ) !void {
        if (self.backend_type == .rocksdb) return self.insertEventLogRocks(contract_name, event_name, fields, block_number, tx_hash, log_index);
        if (self.backend_type == .postgresql) return self.insertEventLogPG(contract_name, event_name, fields, block_number, tx_hash, log_index);

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
            if (c.sqlite3_bind_text(stmt, col_idx, f.value.ptr, @intCast(f.value.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
            col_idx += 1;
        }
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(block_number)) != c.SQLITE_OK) return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_text(stmt, col_idx, tx_hash.ptr, @intCast(tx_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed;
        col_idx += 1;
        if (c.sqlite3_bind_int64(stmt, col_idx, @intCast(log_index)) != c.SQLITE_OK) return error.BindFailed;
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
    ) !void {
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
        limit: u32,
        offset: u32,
        order_desc: bool,
    ) ![]u8 {
        if (self.backend_type == .rocksdb) return self.queryEventLogsRocks(contract_name, event_name, block_from, block_to, tx_hash, limit, offset, order_desc);
        if (self.backend_type == .postgresql) return self.queryEventLogsPG(contract_name, event_name, block_from, block_to, tx_hash, limit, offset, order_desc);

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
        if (block_from) |bf| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bf)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (block_to) |bt| { if (c.sqlite3_bind_int64(stmt, bind_idx, @intCast(bt)) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
        if (tx_hash) |th| { if (c.sqlite3_bind_text(stmt, bind_idx, th.ptr, @intCast(th.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.BindFailed; bind_idx += 1; }
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
        limit: u32,
        offset: u32,
        _: bool,
    ) ![]u8 {
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
        var rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
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
        ;
        try self.pgconn.?.exec(sql);
    }

    fn autoMigrateContractPG(
        self: *Client,
        contract_name: []const u8,
        abi_contract: *const abi.AbiContract,
        event_names: []const []const u8,
    ) !void {
        for (event_names) |evt_name| {
            const evt = abi_contract.findEventByName(evt_name) orelse continue;
            try self.createEventTablePG(contract_name, evt);
        }
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
        try w.writeAll("\n  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,");
        try w.print("\n  UNIQUE(tx_hash, log_index)\n);", .{});
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_block ON event_{s}_{s}(block_number);", .{ contract_name, evt.name, contract_name, evt.name });
        try w.print("\nCREATE INDEX IF NOT EXISTS idx_{s}_{s}_tx ON event_{s}_{s}(tx_hash);", .{ contract_name, evt.name, contract_name, evt.name });
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
            try w.print("${d}", .{i + 1});
        }
        try w.print(",${d},${d},${d});", .{ fields.len + 1, fields.len + 2, fields.len + 3 });
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var params = try std.ArrayList([]const u8).initCapacity(self.alloc, fields.len + 3);
        defer params.deinit(self.alloc);
        for (fields) |f| try params.append(self.alloc, f.value);
        var block_buf: [21]u8 = undefined;
        const block_str = try std.fmt.bufPrint(&block_buf, "{}", .{block_number});
        try params.append(self.alloc, block_str);
        try params.append(self.alloc, tx_hash);
        var logidx_buf: [21]u8 = undefined;
        const li_str = try std.fmt.bufPrint(&logidx_buf, "{}", .{log_index});
        try params.append(self.alloc, li_str);

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

    fn queryEventLogsPG(
        self: *Client,
        contract_name: []const u8,
        event_name: []const u8,
        block_from: ?u64,
        block_to: ?u64,
        tx_hash: ?[]const u8,
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
        try w.writeAll(" ORDER BY block_number DESC");
        try w.print(" LIMIT ${d} OFFSET ${d};", .{ param_idx, param_idx + 1 });
        var sql_list = sql_buf.toArrayList();
        defer sql_list.deinit(self.alloc);

        var params = std.ArrayList([]const u8).empty;
        defer params.deinit(self.alloc);
        if (block_from) |bf| {
            var buf: [21]u8 = undefined;
            try params.append(self.alloc, try std.fmt.bufPrint(&buf, "{}", .{bf}));
        }
        if (block_to) |bt| {
            var buf: [21]u8 = undefined;
            try params.append(self.alloc, try std.fmt.bufPrint(&buf, "{}", .{bt}));
        }
        if (tx_hash) |th| try params.append(self.alloc, th);
        {
            var buf: [21]u8 = undefined;
            try params.append(self.alloc, try std.fmt.bufPrint(&buf, "{}", .{limit}));
        }
        {
            var buf: [21]u8 = undefined;
            try params.append(self.alloc, try std.fmt.bufPrint(&buf, "{}", .{offset}));
        }

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

test "db event table insert and query" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = .{0} ** 32 };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});
    const fields = &.{ DecodedField{ .name = "from", .value = "0x1111" }, DecodedField{ .name = "to", .value = "0x2222" }, DecodedField{ .name = "value", .value = "0x64" } };
    try client.insertEventLog("test", "Transfer", fields, 100, "0xtxhash", 0);
    const result = try client.queryEventLogs("test", "Transfer", 0, null, null, 10, 0, true);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0xtxhash") != null);
    const fields2 = &.{ DecodedField{ .name = "from", .value = "0xaaaa" }, DecodedField{ .name = "to", .value = "0xbbbb" }, DecodedField{ .name = "value", .value = "0x96" } };
    try client.insertEventLog("test", "Transfer", fields2, 200, "0xtxhash2", 1);
    const r1 = try client.queryEventLogs("test", "Transfer", 150, null, null, 10, 0, true);
    defer alloc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "0xtxhash2") != null);
    const r2 = try client.queryEventLogs("test", "Transfer", null, 150, null, 10, 0, true);
    defer alloc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "0xtxhash") != null);
    const r3 = try client.queryEventLogs("test", "Transfer", null, null, "0xtxhash2", 10, 0, true);
    defer alloc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "0xtxhash2") != null);
    const r4 = try client.queryEventLogs("test", "Transfer", null, null, null, 1, 0, true);
    defer alloc.free(r4);
    try std.testing.expect(std.mem.indexOf(u8, r4, "},{") == null);
    const r5 = try client.queryEventLogs("test", "Transfer", null, null, null, 10, 0, false);
    defer alloc.free(r5);
    try std.testing.expect(std.mem.indexOf(u8, r5, "0xtxhash") != null);
}

test "db rollbackFromBlock" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "sqlite", .db_name = ":memory:", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();
    try client.migrate();
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = .{0} ** 32 };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});
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
    const test_evt = abi.AbiEvent{ .name = "Transfer", .inputs = &.{ .{ .name = "from", .type = "address", .indexed = true }, .{ .name = "to", .type = "address", .indexed = true }, .{ .name = "value", .type = "uint256", .indexed = false } }, .signature = .{0} ** 32 };
    var events = try alloc.alloc(abi.AbiEvent, 1);
    events[0] = test_evt;
    defer alloc.free(events);
    const test_contract = abi.AbiContract{ .events = events };
    try client.autoMigrateContract("test", &test_contract, &.{"Transfer"});
    const f = &.{ DecodedField{ .name = "from", .value = "0x1111" }, DecodedField{ .name = "to", .value = "0x2222" }, DecodedField{ .name = "value", .value = "0x64" } };
    try client.insertEventLog("test", "Transfer", f, 100, "0xtx1", 0);
    try client.insertEventLog("test", "Transfer", f, 200, "0xtx2", 1);
    try client.insertEventLog("test", "Transfer", f, 300, "0xtx3", 2);
    try client.deleteEventLogsInRange("test", "Transfer", 150, 250);
    const r = try client.queryEventLogs("test", "Transfer", null, null, null, 10, 0, true);
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
    try client.insertEventLog("test", "Transfer", fields, 100, "0xtxhash", 0);

    const result = try client.queryEventLogs("test", "Transfer", 0, null, null, 10, 0, true);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0xtxhash") != null);
}

test "db rocksdb count and delete" {
    const alloc = std.testing.allocator;
    const cfg = DatabaseConfig{ .db_type = "rocksdb", .db_name = "/tmp/zponder_test_rocksdb3", .wal_mode = true, .busy_timeout_ms = 5000, .max_connections = 10 };
    var client = try Client.init(alloc, &cfg);
    defer client.deinit();

    const f = &.{ DecodedField{ .name = "from", .value = "0xaa" }, DecodedField{ .name = "to", .value = "0xbb" } };
    try client.insertEventLog("t", "Evt", f, 100, "0x1", 0);
    try client.insertEventLog("t", "Evt", f, 200, "0x2", 1);
    try client.insertEventLog("t", "Evt", f, 300, "0x3", 2);

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
