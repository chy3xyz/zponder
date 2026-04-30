//! zponder - 基于 Zig 的以太坊事件索引器
//!
//! 核心模块根文件，重新导出所有公共 API。

const std = @import("std");

pub const config = @import("config.zig");
pub const log = @import("log.zig");
pub const utils = @import("utils.zig");
pub const abi = @import("abi.zig");
pub const eth_rpc = @import("eth_rpc.zig");
pub const db = @import("db.zig");
pub const indexer = @import("indexer.zig");
pub const http_server = @import("http_server.zig");
pub const cache = @import("cache.zig");

test {
    // 运行所有子模块的测试
    _ = config;
    _ = utils;
    _ = abi;
    _ = eth_rpc;
    _ = db;
    _ = indexer;
    _ = http_server;
}
