//! `-Drocksdb=false` 时的占位实现：导出的名字与签名和 rocksdb_impl 完全一致，调用即报错。
//! 之所以保留 `.rocksdb` 这个 BackendType 枚举值（没有从 db.zig 里删掉），是因为它被
//! ~30 处分支引用；真正的拦截点是 Client.init —— 打开 RocksDB 时返回
//! `error.RocksDbSupportNotCompiled`，由 db.initRocksDB 补上可读的日志。
//!
//! 无返回错误的方法（`WriteBatch.init`、`Client.iterator` 等）做成惰性空实现：
//! 只在 Client 打开成功后才会被调用，而那种情况在这里不可能发生。
const std = @import("std");

pub const Client = struct {
    pub fn init(alloc: std.mem.Allocator, db_path: []const u8) !Client {
        _ = alloc;
        _ = db_path;
        return error.RocksDbSupportNotCompiled;
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn put(self: *Client, key: []const u8, value: []const u8) !void {
        _ = self;
        _ = key;
        _ = value;
        return error.RocksDbSupportNotCompiled;
    }

    pub fn get(self: *Client, key: []const u8) !?[]u8 {
        _ = self;
        _ = key;
        return error.RocksDbSupportNotCompiled;
    }

    pub fn delete(self: *Client, key: []const u8) !void {
        _ = self;
        _ = key;
        return error.RocksDbSupportNotCompiled;
    }

    pub fn writeBatch(self: *Client, batch: *WriteBatch) !void {
        _ = self;
        _ = batch;
        return error.RocksDbSupportNotCompiled;
    }

    pub fn iterator(self: *Client) Iterator {
        _ = self;
        return .{};
    }
};

pub const WriteBatch = struct {
    pub fn init() WriteBatch {
        return .{};
    }

    pub fn deinit(self: *WriteBatch) void {
        _ = self;
    }

    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) void {
        _ = self;
        _ = key;
        _ = value;
    }

    pub fn delete(self: *WriteBatch, key: []const u8) void {
        _ = self;
        _ = key;
    }

    pub fn clear(self: *WriteBatch) void {
        _ = self;
    }
};

pub const Iterator = struct {
    pub fn deinit(self: *Iterator) void {
        _ = self;
    }

    pub fn seekToFirst(self: *Iterator) void {
        _ = self;
    }

    pub fn seek(self: *Iterator, seek_key: []const u8) void {
        _ = self;
        _ = seek_key;
    }

    pub fn valid(self: *Iterator) bool {
        _ = self;
        return false;
    }

    pub fn next(self: *Iterator) void {
        _ = self;
    }

    pub fn key(self: *Iterator) []const u8 {
        _ = self;
        return &.{};
    }

    pub fn value(self: *Iterator) []const u8 {
        _ = self;
        return &.{};
    }

    pub fn status(self: *Iterator) !void {
        _ = self;
        return error.RocksDbSupportNotCompiled;
    }
};
