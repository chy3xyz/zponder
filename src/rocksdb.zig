const std = @import("std");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

const ROCKSDB_OK: [*c]u8 = null;

fn check(errptr: [*c][*c]u8) !void {
    if (errptr.*) |msg| {
        defer c.rocksdb_free(msg);
        log.err("RocksDB error: {s}", .{msg});
        return error.RocksDBError;
    }
}

pub const Client = struct {
    alloc: std.mem.Allocator,
    db: *c.rocksdb_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_opts: *c.rocksdb_readoptions_t,

    pub fn init(alloc: std.mem.Allocator, db_path: []const u8) !Client {
        const opts = c.rocksdb_options_create();
        c.rocksdb_options_set_create_if_missing(opts, 1);

        var err: [*c]u8 = ROCKSDB_OK;
        const db = c.rocksdb_open(opts, db_path.ptr, &err);
        c.rocksdb_options_destroy(opts);
        try check(&err);
        if (db == null) return error.RocksDBOpenFailed;

        const write_opts = c.rocksdb_writeoptions_create() orelse return error.RocksDBInitFailed;
        const read_opts = c.rocksdb_readoptions_create() orelse return error.RocksDBInitFailed;

        return .{
            .alloc = alloc,
            .db = db.?,
            .write_opts = write_opts,
            .read_opts = read_opts,
        };
    }

    pub fn deinit(self: *Client) void {
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_readoptions_destroy(self.read_opts);
        c.rocksdb_close(self.db);
    }

    pub fn put(self: *Client, key: []const u8, value: []const u8) !void {
        var err: [*c]u8 = ROCKSDB_OK;
        c.rocksdb_put(self.db, self.write_opts, key.ptr, key.len, value.ptr, value.len, &err);
        try check(&err);
    }

    pub fn get(self: *Client, key: []const u8) !?[]u8 {
        var err: [*c]u8 = ROCKSDB_OK;
        var val_len: usize = 0;
        const val = c.rocksdb_get(self.db, self.read_opts, key.ptr, key.len, &val_len, &err);
        try check(&err);
        if (val == null) return null;
        defer c.rocksdb_free(val);
        return try self.alloc.dupe(u8, val[0..val_len]);
    }

    pub fn delete(self: *Client, key: []const u8) !void {
        var err: [*c]u8 = ROCKSDB_OK;
        c.rocksdb_delete(self.db, self.write_opts, key.ptr, key.len, &err);
        try check(&err);
    }

    pub fn writeBatch(self: *Client, batch: *WriteBatch) !void {
        var err: [*c]u8 = ROCKSDB_OK;
        c.rocksdb_write(self.db, self.write_opts, batch.inner, &err);
        try check(&err);
    }

    pub fn iterator(self: *Client) Iterator {
        const iter = c.rocksdb_create_iterator(self.db, self.read_opts) orelse unreachable;
        return .{ .inner = iter };
    }
};

pub const WriteBatch = struct {
    inner: *c.rocksdb_writebatch_t,

    pub fn init() WriteBatch {
        const inner = c.rocksdb_writebatch_create() orelse @panic("rocksdb_writebatch_create returned null");
        return .{ .inner = inner };
    }

    pub fn deinit(self: *WriteBatch) void {
        c.rocksdb_writebatch_destroy(self.inner);
    }

    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) void {
        c.rocksdb_writebatch_put(self.inner, key.ptr, key.len, value.ptr, value.len);
    }

    pub fn delete(self: *WriteBatch, key: []const u8) void {
        c.rocksdb_writebatch_delete(self.inner, key.ptr, key.len);
    }

    pub fn clear(self: *WriteBatch) void {
        c.rocksdb_writebatch_clear(self.inner);
    }
};

pub const Iterator = struct {
    inner: *c.rocksdb_iterator_t,

    pub fn deinit(self: *Iterator) void {
        c.rocksdb_iter_destroy(self.inner);
    }

    pub fn seekToFirst(self: *Iterator) void {
        c.rocksdb_iter_seek_to_first(self.inner);
    }

    pub fn seek(self: *Iterator, seek_key: []const u8) void {
        c.rocksdb_iter_seek(self.inner, seek_key.ptr, seek_key.len);
    }

    pub fn valid(self: *Iterator) bool {
        return c.rocksdb_iter_valid(self.inner) != 0;
    }

    pub fn next(self: *Iterator) void {
        c.rocksdb_iter_next(self.inner);
    }

    pub fn key(self: *Iterator) []const u8 {
        var klen: usize = 0;
        const k = c.rocksdb_iter_key(self.inner, &klen);
        return if (k != null) k[0..klen] else &.{};
    }

    pub fn value(self: *Iterator) []const u8 {
        var vlen: usize = 0;
        const v = c.rocksdb_iter_value(self.inner, &vlen);
        return if (v != null) v[0..vlen] else &.{};
    }

    pub fn status(self: *Iterator) !void {
        var err: [*c]u8 = ROCKSDB_OK;
        c.rocksdb_iter_get_error(self.inner, &err);
        try check(&err);
    }
};
