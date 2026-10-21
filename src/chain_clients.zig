//! 按配置里的链建立 RPC 客户端。
//!
//! 端点与 `[rpc]` 完全相同的链直接复用那份配置（含 `urls` / `ws_urls` 故障转移）。
//! 其余链只用自己的 `rpc_url` / `ws_url`，重试和超时仍跟 `[rpc]`。
//! 字符串不在这里复制：它们指向 `Config`，池的生命周期必须短于配置。

const std = @import("std");
const config = @import("config.zig");
const eth_rpc = @import("eth_rpc.zig");

/// 空名字用第一条链。名字对不上返回 `error.UnknownChain`。
pub fn indexOf(chains: []const config.ChainConfig, name: []const u8) error{UnknownChain}!usize {
    if (chains.len == 0) return error.UnknownChain;
    if (name.len == 0) return 0;
    for (chains, 0..) |ch, i| {
        if (std.mem.eql(u8, ch.name, name)) return i;
    }
    return error.UnknownChain;
}

/// 解析后的链名。空名字得到第一条链的名字。
pub fn resolvedName(chains: []const config.ChainConfig, name: []const u8) error{UnknownChain}![]const u8 {
    return chains[try indexOf(chains, name)].name;
}

/// HTTP 与 WSS 都和 `[rpc]` 一致时，沿用故障转移列表。
pub fn usesPrimaryRpc(primary: config.RpcConfig, chain: config.ChainConfig) bool {
    if (!std.mem.eql(u8, primary.url, chain.rpc_url)) return false;
    if (primary.ws_url) |primary_ws| {
        const chain_ws = chain.ws_url orelse return false;
        return std.mem.eql(u8, primary_ws, chain_ws);
    }
    return chain.ws_url == null;
}

/// 非主端点：url / ws 指向链配置，重试参数复制自 `[rpc]`。
pub fn rpcForChain(primary: config.RpcConfig, chain: config.ChainConfig) config.RpcConfig {
    return .{
        .url = chain.rpc_url,
        .ws_url = chain.ws_url,
        .retry_count = primary.retry_count,
        .retry_delay_ms = primary.retry_delay_ms,
        .request_timeout_ms = primary.request_timeout_ms,
        .max_concurrent = primary.max_concurrent,
    };
}

pub const Pool = struct {
    alloc: std.mem.Allocator,
    configs: []config.RpcConfig,
    clients: []eth_rpc.Client,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: *const config.Config) error{ NoChains, OutOfMemory }!Pool {
        if (cfg.chains.len == 0) return error.NoChains;
        const configs = try alloc.alloc(config.RpcConfig, cfg.chains.len);
        errdefer alloc.free(configs);
        const clients = try alloc.alloc(eth_rpc.Client, cfg.chains.len);
        errdefer alloc.free(clients);

        for (cfg.chains, 0..) |ch, i| {
            configs[i] = if (usesPrimaryRpc(cfg.rpc, ch)) cfg.rpc else rpcForChain(cfg.rpc, ch);
            clients[i] = eth_rpc.Client.init(alloc, io, &configs[i]);
        }
        return .{
            .alloc = alloc,
            .configs = configs,
            .clients = clients,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.clients) |*rpc| rpc.deinit();
        self.alloc.free(self.clients);
        self.alloc.free(self.configs);
    }

    pub fn client(self: *Pool, chains: []const config.ChainConfig, name: []const u8) error{UnknownChain}!*eth_rpc.Client {
        return &self.clients[try indexOf(chains, name)];
    }
};

test "空链名用第一条，未知链名拒绝" {
    const chains = [_]config.ChainConfig{
        .{ .name = "ethereum", .chain_id = 1, .rpc_url = "https://eth.example", .ws_url = null },
        .{ .name = "bsc", .chain_id = 56, .rpc_url = "https://bsc.example", .ws_url = null },
    };
    try std.testing.expectEqual(@as(usize, 0), try indexOf(&chains, ""));
    try std.testing.expectEqual(@as(usize, 1), try indexOf(&chains, "bsc"));
    try std.testing.expectError(error.UnknownChain, indexOf(&chains, "nope"));
    try std.testing.expectError(error.UnknownChain, indexOf(&[_]config.ChainConfig{}, ""));
    try std.testing.expectEqualStrings("ethereum", try resolvedName(&chains, ""));
    try std.testing.expectEqualStrings("bsc", try resolvedName(&chains, "bsc"));
}

test "与 [rpc] 相同的端点沿用故障转移，其余链只用自己的 url" {
    const primary = config.RpcConfig{
        .url = "https://rpc.example",
        .urls = &.{ "https://fallback.example" },
        .ws_url = "wss://rpc.example",
        .retry_count = 3,
        .retry_delay_ms = 10,
        .request_timeout_ms = 20,
        .max_concurrent = 4,
    };
    const same = config.ChainConfig{
        .name = "ethereum",
        .chain_id = 1,
        .rpc_url = "https://rpc.example",
        .ws_url = "wss://rpc.example",
    };
    const other = config.ChainConfig{
        .name = "bsc",
        .chain_id = 56,
        .rpc_url = "https://bsc.example",
        .ws_url = null,
    };
    const ws_mismatch = config.ChainConfig{
        .name = "ethereum",
        .chain_id = 1,
        .rpc_url = "https://rpc.example",
        .ws_url = "wss://other.example",
    };

    try std.testing.expect(usesPrimaryRpc(primary, same));
    try std.testing.expect(!usesPrimaryRpc(primary, other));
    try std.testing.expect(!usesPrimaryRpc(primary, ws_mismatch));

    const built = rpcForChain(primary, other);
    try std.testing.expectEqualStrings(other.rpc_url, built.url);
    try std.testing.expect(built.url.ptr == other.rpc_url.ptr);
    try std.testing.expect(built.ws_url == null);
    try std.testing.expectEqual(@as(usize, 0), built.urls.len);
    try std.testing.expectEqual(primary.retry_count, built.retry_count);
    try std.testing.expectEqual(primary.request_timeout_ms, built.request_timeout_ms);
}
