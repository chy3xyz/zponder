const std = @import("std");

/// 从原始 HTTP 头里取指定头的值。找不到返回空切片。
pub fn headerValue(head_buffer: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return "";
}

/// 长度不同也扫完较长的一侧，避免在第一个不同字节上返回。
pub fn timingSafeEql(a: []const u8, b: []const u8) bool {
    const n = @max(a.len, b.len);
    var diff: u8 = if (a.len == b.len) 0 else 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: u8 = if (i < a.len) a[i] else 0;
        const y: u8 = if (i < b.len) b[i] else 0;
        diff |= x ^ y;
    }
    return diff == 0;
}

pub fn bearerMatches(expected: []const u8, authorization: []const u8) bool {
    const prefix = "Bearer ";
    if (authorization.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(authorization[0..prefix.len], prefix)) return false;
    const presented = std.mem.trim(u8, authorization[prefix.len..], " \t");
    return timingSafeEql(expected, presented);
}

/// `expected` 为空表示不鉴权。
pub fn requestAllowed(expected: []const u8, head_buffer: []const u8) bool {
    if (expected.len == 0) return true;
    return bearerMatches(expected, headerValue(head_buffer, "Authorization"));
}

/// OPTIONS 预检和精确路径 `/health` 不要求 token。`path` 不含 query。
pub fn routeAllowed(expected: []const u8, method_is_options: bool, path: []const u8, head_buffer: []const u8) bool {
    if (method_is_options) return true;
    if (std.mem.eql(u8, path, "/health")) return true;
    return requestAllowed(expected, head_buffer);
}

test "auth 空 token 放行" {
    const head = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(routeAllowed("", false, "/events", head));
}

test "auth /health 与 OPTIONS 免 token" {
    const head = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(routeAllowed("secret", false, "/health", head));
    try std.testing.expect(routeAllowed("secret", true, "/events", head));
    try std.testing.expect(!routeAllowed("secret", false, "/healthz", head));
}

test "auth Bearer 匹配与拒绝" {
    const ok = "GET /events HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n";
    const wrong = "GET /events HTTP/1.1\r\nAuthorization: Bearer nope\r\n\r\n";
    const missing = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const lower = "GET /graphql HTTP/1.1\r\nauthorization: bearer secret\r\n\r\n";
    try std.testing.expect(routeAllowed("secret", false, "/events", ok));
    try std.testing.expect(routeAllowed("secret", false, "/graphql", lower));
    try std.testing.expect(!routeAllowed("secret", false, "/events", wrong));
    try std.testing.expect(!routeAllowed("secret", false, "/events", missing));
    try std.testing.expect(!timingSafeEql("secret", "secre"));
    try std.testing.expect(timingSafeEql("secret", "secret"));
}
