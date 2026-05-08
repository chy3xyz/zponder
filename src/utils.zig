const std = @import("std");

/// 将以太坊地址转为小写（原地修改）
pub fn toLowerAddress(addr: []u8) void {
    for (addr) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
}

/// 将以太坊地址转为校验和格式（EIP-55）
pub fn toChecksumAddress(alloc: std.mem.Allocator, addr: []const u8) ![]u8 {
    if (addr.len != 42 or addr[0] != '0' or addr[1] != 'x') {
        return error.InvalidAddress;
    }

    var lower: [40]u8 = undefined;
    for (addr[2..], 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }

    // EIP-55: keccak256(lower_hex) 决定每个字符的大小写
    var hash: [32]u8 = undefined;
    keccak256(&lower, &hash);

    var result = try alloc.dupe(u8, addr);
    for (result[2..], 0..) |*c, i| {
        if (std.ascii.isAlphabetic(c.*)) {
            const hash_nibble = if (i % 2 == 0) hash[i / 2] >> 4 else hash[i / 2] & 0x0f;
            if (hash_nibble >= 8) {
                c.* = std.ascii.toUpper(c.*);
            } else {
                c.* = std.ascii.toLower(c.*);
            }
        }
    }
    return result;
}

/// 解析十六进制字符串为 u64
pub fn parseHexU64(hex_str: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, hex_str, " \t\n\r\"");
    const prefix = if (trimmed.len >= 2 and trimmed[0] == '0' and trimmed[1] == 'x') trimmed[2..] else trimmed;
    return std.fmt.parseInt(u64, prefix, 16);
}

/// 解析十六进制字符串为 u256
pub fn parseHexU256(hex_str: []const u8) !u256 {
    const trimmed = std.mem.trim(u8, hex_str, " \t\n\r\"");
    const prefix = if (trimmed.len >= 2 and trimmed[0] == '0' and trimmed[1] == 'x') trimmed[2..] else trimmed;
    return std.fmt.parseInt(u256, prefix, 16);
}

/// 将 u64 格式化为十六进制字符串（带 0x 前缀）
pub fn formatHexU64(buf: []u8, value: u64) ![]u8 {
    return try std.fmt.bufPrint(buf, "0x{x}", .{value});
}

/// 将字符串中的特殊字符转义为 JSON 安全格式，写入 writer
pub fn jsonEscapeString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (ch == '\\') {
            try w.writeAll("\\\\");
        } else if (ch == '"') {
            try w.writeAll("\\\"");
        } else if (ch == '\n') {
            try w.writeAll("\\n");
        } else if (ch == '\r') {
            try w.writeAll("\\r");
        } else if (ch == '\t') {
            try w.writeAll("\\t");
        } else if (ch <= 0x1F) {
            try w.print("\\u{x:0>4}", .{ch});
        } else {
            try w.writeByte(ch);
        }
    }
}

/// 验证以太坊地址格式（42 字符，0x 前缀）
pub fn isValidAddress(addr: []const u8) bool {
    if (addr.len != 42) return false;
    if (addr[0] != '0' or addr[1] != 'x') return false;
    for (addr[2..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// 计算 keccak256 哈希（简化占位，实际需要 SHA3-256）
pub fn keccak256(data: []const u8, out: *[32]u8) void {
    // 以太坊使用 Keccak-256（分隔符 0x01），不是 NIST SHA3-256（分隔符 0x06）
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    hasher.final(out);
}

test "parseHexU64" {
    try std.testing.expectEqual(@as(u64, 255), try parseHexU64("0xff"));
    try std.testing.expectEqual(@as(u64, 12345), try parseHexU64("0x3039"));
}

test "isValidAddress" {
    try std.testing.expect(isValidAddress("0x6b175474e89094c44da98b954eedeac495271d0f"));
    try std.testing.expect(!isValidAddress("0x6b175474e89094c44da98b954eedeac495271d0"));
    try std.testing.expect(!isValidAddress("6b175474e89094c44da98b954eedeac495271d0f"));
}

test "toChecksumAddress EIP-55" {
    const alloc = std.testing.allocator;
    // 已知 EIP-55 校验和地址
    const checksummed = try toChecksumAddress(alloc, "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    defer alloc.free(checksummed);
    try std.testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", checksummed);
}
