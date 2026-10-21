//! Minimal WebSocket JSON-RPC client for eth_subscribe("logs").
//! Uses std.http.Client for TCP/TLS; implements WS handshake + framing only.

const std = @import("std");
const eth_rpc = @import("eth_rpc.zig");
const log = @import("log.zig");

const HttpClient = std.http.Client;
const HostName = std.Io.net.HostName;

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Header0 = packed struct(u8) {
    opcode: Opcode,
    rsv3: u1 = 0,
    rsv2: u1 = 0,
    rsv1: u1 = 0,
    fin: bool,
};

pub const Header1 = packed struct(u8) {
    payload_len: enum(u7) {
        len16 = 126,
        len64 = 127,
        _,
    },
    mask: bool,
};

/// Compute Sec-WebSocket-Accept from the client key (unit-testable).
pub fn computeAcceptKey(client_key: []const u8, out: *[28]u8) void {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key);
    sha.update(ws_guid);
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// XOR-mask payload in place (RFC6455 client frames).
pub fn maskPayload(mask: *const [4]u8, payload: []u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask[i % 4];
    }
}

/// Encode a client (masked) WebSocket frame into `out`. Returns bytes written.
pub fn encodeMaskedFrame(op: Opcode, payload: []const u8, mask: *const [4]u8, out: []u8) !usize {
    var i: usize = 0;
    if (out.len < 2) return error.BufferTooSmall;
    out[i] = @bitCast(Header0{ .opcode = op, .fin = true });
    i += 1;

    const len = payload.len;
    if (len <= 125) {
        out[i] = @bitCast(Header1{ .payload_len = @enumFromInt(len), .mask = true });
        i += 1;
    } else if (len <= 0xffff) {
        if (out.len < i + 1 + 2 + 4 + len) return error.BufferTooSmall;
        out[i] = @bitCast(Header1{ .payload_len = .len16, .mask = true });
        i += 1;
        std.mem.writeInt(u16, out[i..][0..2], @intCast(len), .big);
        i += 2;
    } else {
        if (out.len < i + 1 + 8 + 4 + len) return error.BufferTooSmall;
        out[i] = @bitCast(Header1{ .payload_len = .len64, .mask = true });
        i += 1;
        std.mem.writeInt(u64, out[i..][0..8], len, .big);
        i += 8;
    }

    if (out.len < i + 4 + len) return error.BufferTooSmall;
    @memcpy(out[i..][0..4], mask);
    i += 4;
    @memcpy(out[i..][0..len], payload);
    maskPayload(mask, out[i..][0..len]);
    i += len;
    return i;
}

pub const ReadEvent = union(enum) {
    log: eth_rpc.Log,
    ping_handled,
    closed,
};

/// 实时订阅可以长时间没有日志，不能沿用 HTTP 的 `request_timeout_ms`。
/// HTTP 超时关掉时这里也关掉：单测传入 undefined io，安装超时会去读时钟。
pub const idle_timeout_ms: u32 = 120_000;

pub fn idleTimeoutMs(request_timeout_ms: u32) u32 {
    if (request_timeout_ms == 0) return 0;
    return idle_timeout_ms;
}

threadlocal var ws_io_inner: std.Io = undefined;
threadlocal var ws_io_timeout: std.Io.Timeout = .none;

fn wsTimedNetOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    const inner = std.Io{ .userdata = userdata, .vtable = ws_io_inner.vtable };
    switch (operation) {
        .net_read, .net_write, .net_receive, .net_send => {},
        else => return inner.operate(operation),
    }
    if (ws_io_timeout == .none) return inner.operate(operation);
    return inner.operateTimeout(operation, ws_io_timeout) catch |err| switch (err) {
        error.Timeout => return wsNetTimeoutResult(operation),
        error.ConcurrencyUnavailable => return inner.operate(operation),
        else => |e| return e,
    };
}

fn wsNetTimeoutResult(operation: std.Io.Operation) std.Io.Operation.Result {
    return switch (operation) {
        .net_read => .{ .net_read = error.ConnectionTimedOut },
        .net_write => .{ .net_write = error.ConnectionTimedOut },
        .net_receive => .{ .net_receive = .{ error.ConnectionTimedOut, 0 } },
        .net_send => .{ .net_send = .{ error.ConnectionTimedOut, 0 } },
        else => unreachable,
    };
}

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Long-lived WSS/WS JSON-RPC session for log subscriptions.
pub const Session = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    http: HttpClient,
    connection: ?*HttpClient.Connection = null,
    next_id: u64 = 1,
    /// 同一条连接上的多路 `eth_subscribe`。地址按块切开后每块一个 id。
    subscription_ids: std.ArrayListUnmanaged([]u8) = .empty,
    /// 等回执时已经推过来的日志最高块。索引线程用 HTTP 把 `[游标, 该块]` 补上后再读。
    dropped_live_hi: ?u64 = null,
    /// 半开连接上的读超时。`.none` 时不改 Io（单测的 undefined io 不能碰时钟）。
    read_timeout: std.Io.Timeout = .none,
    /// 连接上的 stream 持有这份 vtable 的指针，Session 不能在安装后再被移动。
    timed_vtable: std.Io.VTable = undefined,
    /// Set by close() from another thread to unblock readers.
    closing: std.atomic.Value(bool) = .init(false),
    url_index: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Session {
        return .{
            .alloc = alloc,
            .io = io,
            .http = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *Session) void {
        self.close();
        self.detachConnection();
        self.clearSubscriptionIds();
        self.subscription_ids.deinit(self.alloc);
        self.http.deinit();
    }

    /// 关掉底层连接，让堵在 `readEvent` 里的索引线程返回。不释放订阅 id，
    /// 清理仍由持有 Session 的那条线程做。
    pub fn interrupt(self: *Session) void {
        const conn = self.connection orelse return;
        conn.stream_reader.stream.shutdown(self.io, .both) catch {};
    }

    /// 关掉底层连接，让堵在 `readEvent` 里的索引线程返回。
    /// 不碰订阅 id：`stop` 会从别的线程调用这里，id 由持有 Session 的线程释放。
    pub fn close(self: *Session) void {
        self.closing.store(true, .monotonic);
        if (self.connection) |conn| {
            conn.closing = true;
            // Shutdown unblocks readers without double-close on later destroy().
            conn.stream_reader.stream.shutdown(self.io, .both) catch {};
        }
    }

    fn clearSubscriptionIds(self: *Session) void {
        for (self.subscription_ids.items) |sid| self.alloc.free(sid);
        self.subscription_ids.clearRetainingCapacity();
    }

    pub fn detachConnection(self: *Session) void {
        if (self.connection) |conn| {
            conn.closing = true;
            self.http.connection_pool.release(conn, self.io);
            self.connection = null;
        }
    }

    fn ensureCaBundle(self: *Session) !void {
        {
            try self.http.ca_bundle_lock.lockShared(self.io);
            defer self.http.ca_bundle_lock.unlockShared(self.io);
            if (self.http.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(self.alloc);
        const now = std.Io.Clock.real.now(self.io);
        try bundle.rescan(self.alloc, self.io, now);
        try self.http.ca_bundle_lock.lock(self.io);
        defer self.http.ca_bundle_lock.unlock(self.io);
        self.http.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &self.http.ca_bundle, &bundle);
    }

    /// Connect and complete WebSocket handshake to `url` (ws:// or wss://).
    pub fn connect(self: *Session, url: []const u8) !void {
        self.close();
        self.clearSubscriptionIds();
        self.detachConnection();
        self.closing.store(false, .monotonic);
        self.installReadTimeout();

        const uri = try std.Uri.parse(url);
        const protocol = HttpClient.Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedUriScheme;
        if (protocol == .tls) try self.ensureCaBundle();

        var host_buf: [HostName.max_len]u8 = undefined;
        const host = try HostName.fromUri(uri, &host_buf);
        const port = uri.port orelse switch (protocol) {
            .tls => @as(u16, 443),
            .plain => @as(u16, 80),
        };

        const conn = try self.http.connectTcp(host, port, protocol);
        errdefer {
            conn.closing = true;
            self.http.connection_pool.release(conn, self.io);
        }

        // Build Sec-WebSocket-Key
        var key_raw: [16]u8 = undefined;
        self.io.random(&key_raw);
        var key_b64: [24]u8 = undefined;
        const key_len = std.base64.standard.Encoder.encode(&key_b64, &key_raw).len;
        const client_key = key_b64[0..key_len];

        var accept_expected: [28]u8 = undefined;
        computeAcceptKey(client_key, &accept_expected);

        // Request target: path + query
        var path_buf: [2048]u8 = undefined;
        const path = try formatRequestTarget(uri, &path_buf);

        const w = conn.writer();
        try w.print("GET {s} HTTP/1.1\r\n", .{path});
        try w.print("Host: {s}\r\n", .{host.bytes});
        try w.writeAll("Upgrade: websocket\r\n");
        try w.writeAll("Connection: Upgrade\r\n");
        try w.print("Sec-WebSocket-Key: {s}\r\n", .{client_key});
        try w.writeAll("Sec-WebSocket-Version: 13\r\n");
        try w.writeAll("\r\n");
        try conn.flush();

        // Read handshake response
        const r = conn.reader();
        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.alloc);
        while (true) {
            const chunk = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.StreamTooLong => return error.HandshakeFailed,
                else => |err| return err,
            };
            try header_buf.appendSlice(self.alloc, chunk);
            if (std.mem.endsWith(u8, header_buf.items, "\r\n\r\n") or
                std.mem.endsWith(u8, header_buf.items, "\n\n")) break;
            if (header_buf.items.len > 8192) return error.HandshakeFailed;
        }

        if (!std.mem.startsWith(u8, header_buf.items, "HTTP/1.1 101") and
            !std.mem.startsWith(u8, header_buf.items, "HTTP/1.0 101"))
        {
            log.err("WebSocket 握手失败，响应头: {s}", .{header_buf.items[0..@min(header_buf.items.len, 200)]});
            return error.HandshakeFailed;
        }

        // Verify Accept (case-insensitive header scan)
        var accept_ok = false;
        var line_it = std.mem.splitScalar(u8, header_buf.items, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (std.ascii.startsWithIgnoreCase(trimmed, "sec-websocket-accept:")) {
                const val = std.mem.trim(u8, trimmed["sec-websocket-accept:".len..], " \t");
                if (std.mem.eql(u8, val, &accept_expected)) accept_ok = true;
                break;
            }
        }
        if (!accept_ok) {
            log.err("WebSocket Sec-WebSocket-Accept 校验失败", .{});
            return error.HandshakeFailed;
        }

        self.connection = conn;
        log.info("WebSocket 已连接: {s}", .{url});
    }

    fn installReadTimeout(self: *Session) void {
        if (self.read_timeout == .none) {
            self.http.io = self.io;
            ws_io_timeout = .none;
            return;
        }
        self.timed_vtable = self.io.vtable.*;
        self.timed_vtable.operate = wsTimedNetOperate;
        ws_io_inner = self.io;
        ws_io_timeout = self.read_timeout;
        self.http.io = .{
            .userdata = self.io.userdata,
            .vtable = &self.timed_vtable,
        };
    }

    pub fn setReadTimeoutMs(self: *Session, ms: u32) void {
        if (ms == 0) {
            self.read_timeout = .none;
            return;
        }
        self.read_timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(@as(i64, ms)),
                .clock = .awake,
            },
        };
    }

    /// Connect using primary ws_url or failover ws_urls.
    pub fn connectWithFailover(self: *Session, ws_url: ?[]const u8, ws_urls: []const []const u8) !void {
        if (ws_urls.len > 0) {
            var attempt: usize = 0;
            while (attempt < ws_urls.len) : (attempt += 1) {
                const idx = (self.url_index + attempt) % ws_urls.len;
                if (self.connect(ws_urls[idx])) |_| {
                    self.url_index = idx;
                    return;
                } else |e| {
                    log.warn("WSS 连接失败 ({s}): {any}", .{ ws_urls[idx], e });
                }
            }
            return error.ConnectFailed;
        }
        const url = ws_url orelse return error.NoWsUrl;
        try self.connect(url);
    }

    fn writeText(self: *Session, text: []const u8) !void {
        const conn = self.connection orelse return error.NotConnected;
        var mask: [4]u8 = undefined;
        self.io.random(&mask);

        // header(2) + ext(8) + mask(4) + payload
        const need = 2 + 8 + 4 + text.len;
        const buf = try self.alloc.alloc(u8, need);
        defer self.alloc.free(buf);
        const n = try encodeMaskedFrame(.text, text, &mask, buf);
        const w = conn.writer();
        try w.writeAll(buf[0..n]);
        try conn.flush();
    }

    /// Read next server frame payload (caller frees). Handles ping→pong internally by looping.
    fn readFramePayload(self: *Session) !struct { opcode: Opcode, data: []u8 } {
        const conn = self.connection orelse return error.NotConnected;
        const r = conn.reader();

        while (true) {
            if (self.closing.load(.monotonic)) return error.Closed;

            const h0: Header0 = @bitCast(try r.takeByte());
            const h1: Header1 = @bitCast(try r.takeByte());

            if (h1.mask) return error.UnexpectedServerMask;

            const len: usize = switch (h1.payload_len) {
                .len16 => try r.takeInt(u16, .big),
                .len64 => std.math.cast(usize, try r.takeInt(u64, .big)) orelse return error.MessageOversize,
                else => @intFromEnum(h1.payload_len),
            };

            const payload = try self.alloc.alloc(u8, len);
            errdefer self.alloc.free(payload);
            if (len > 0) {
                const got = try r.take(len);
                if (got.len != len) {
                    // take() may return a view into reader buffer — copy out
                    @memcpy(payload, got);
                } else {
                    @memcpy(payload, got);
                }
            }

            switch (h0.opcode) {
                .ping => {
                    // Reply pong with same payload (must mask as client)
                    var mask: [4]u8 = undefined;
                    self.io.random(&mask);
                    const need = 2 + 8 + 4 + payload.len;
                    const buf = try self.alloc.alloc(u8, need);
                    defer self.alloc.free(buf);
                    const n = try encodeMaskedFrame(.pong, payload, &mask, buf);
                    self.alloc.free(payload);
                    const w = conn.writer();
                    try w.writeAll(buf[0..n]);
                    try conn.flush();
                    continue;
                },
                .pong => {
                    self.alloc.free(payload);
                    continue;
                },
                .connection_close => {
                    self.alloc.free(payload);
                    return error.Closed;
                },
                .text, .binary => {
                    if (!h0.fin) {
                        // MVP: reject fragmented messages
                        self.alloc.free(payload);
                        return error.FragmentedNotSupported;
                    }
                    return .{ .opcode = h0.opcode, .data = payload };
                },
                else => {
                    self.alloc.free(payload);
                    return error.UnexpectedOpCode;
                },
            }
        }
    }

    /// eth_subscribe("logs", filter_obj). `filter_obj` is a JSON object string.
    pub fn subscribeLogs(self: *Session, filter_obj: []const u8) ![]const u8 {
        const id = self.next_id;
        self.next_id += 1;
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"eth_subscribe\",\"params\":[\"logs\",{s}]}}",
            .{ id, filter_obj },
        );
        defer self.alloc.free(req);
        try self.writeText(req);

        // Wait for matching response (ignore unrelated notifications)
        while (true) {
            const frame = try self.readFramePayload();
            defer self.alloc.free(frame.data);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, frame.data, .{});
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            if (parsed.value.object.get("id")) |rid| {
                const got_id: ?i64 = switch (rid) {
                    .integer => |v| v,
                    .float => |v| @intFromFloat(v),
                    else => null,
                };
                if (got_id == null or got_id.? != @as(i64, @intCast(id))) {
                    self.observeHandshakePayload(frame.data);
                    continue;
                }

                if (parsed.value.object.get("error")) |_| return error.SubscribeFailed;
                const result = parsed.value.object.get("result") orelse return error.SubscribeFailed;
                if (result != .string) return error.SubscribeFailed;

                const copy = try self.alloc.dupe(u8, result.string);
                errdefer self.alloc.free(copy);
                try self.subscription_ids.append(self.alloc, copy);
                log.info("eth_subscribe(logs) 成功, id={s}", .{copy});
                return copy;
            }
            // 前一路订阅已经在推日志。先记下块号，订完后按闭区间补扫，不能直接丢掉。
            self.observeHandshakePayload(frame.data);
        }
    }

    fn observeHandshakePayload(self: *Session, raw: []const u8) void {
        const maybe = eth_rpc.parseSubscriptionNotification(self.alloc, raw) catch return;
        const lg = maybe orelse return;
        defer eth_rpc.freeLog(self.alloc, lg);
        self.dropped_live_hi = if (self.dropped_live_hi) |hi| @max(hi, lg.block_number) else lg.block_number;
    }

    pub fn unsubscribe(self: *Session) void {
        for (self.subscription_ids.items) |sid| {
            const id = self.next_id;
            self.next_id += 1;
            const req = std.fmt.allocPrint(
                self.alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"eth_unsubscribe\",\"params\":[\"{s}\"]}}",
                .{ id, sid },
            ) catch continue;
            defer self.alloc.free(req);
            self.writeText(req) catch {};
        }
        self.clearSubscriptionIds();
    }

    /// Block until a log notification, ping handled, or close.
    pub fn readEvent(self: *Session) !ReadEvent {
        while (true) {
            if (self.closing.load(.monotonic)) return .{ .closed = {} };

            const frame = self.readFramePayload() catch |e| switch (e) {
                error.Closed => return .{ .closed = {} },
                else => |err| return err,
            };
            defer self.alloc.free(frame.data);

            if (eth_rpc.parseSubscriptionNotification(self.alloc, frame.data)) |maybe| {
                if (maybe) |lg| return .{ .log = lg };
            } else |_| {}
            // Non-subscription JSON (acks etc.) — ignore
        }
    }
};

fn formatRequestTarget(uri: std.Uri, buf: []u8) ![]const u8 {
    var i: usize = 0;
    const path_slice: []const u8 = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    const path = if (path_slice.len == 0) "/" else path_slice;
    if (path.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    i = path.len;

    if (uri.query) |q| {
        const qs: []const u8 = switch (q) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        if (i + 1 + qs.len > buf.len) return error.NameTooLong;
        buf[i] = '?';
        i += 1;
        @memcpy(buf[i..][0..qs.len], qs);
        i += qs.len;
    }
    return buf[0..i];
}

// ============================================================================
// 单元测试
// ============================================================================

test "computeAcceptKey RFC6455 example" {
    // From RFC6455 §1.3
    var out: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "maskPayload roundtrip" {
    var data = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f }; // Hello
    const mask = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    maskPayload(&mask, &data);
    try std.testing.expect(!std.mem.eql(u8, &data, "Hello"));
    maskPayload(&mask, &data);
    try std.testing.expectEqualStrings("Hello", &data);
}

test "WSS 空闲超时不沿用 HTTP 的短超时" {
    try std.testing.expectEqual(@as(u32, 0), idleTimeoutMs(0));
    try std.testing.expectEqual(idle_timeout_ms, idleTimeoutMs(10_000));
}

test "WSS 读超时切断只接受不回应的握手" {
    const alloc = std.testing.allocator;
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{});
    var release = std.atomic.Value(bool).init(false);
    const holder = try std.Thread.spawn(.{}, struct {
        fn run(listen: *std.Io.net.Server, io_: std.Io, release_: *std.atomic.Value(bool)) void {
            const stream = listen.accept(io_) catch return;
            defer stream.close(io_);
            var waited_ms: u32 = 0;
            while (!release_.load(.acquire) and waited_ms < 3000) : (waited_ms += 20) {
                std.Io.sleep(io_, .fromMilliseconds(20), .awake) catch return;
            }
        }
    }.run, .{ &server, io, &release });
    defer {
        release.store(true, .release);
        server.deinit(io);
        holder.join();
    }

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{server.socket.address.getPort()}) catch unreachable;
    var session = Session.init(alloc, io);
    defer session.deinit();
    session.setReadTimeoutMs(200);

    const started = monoMs();
    const result = session.connect(url);
    const elapsed = monoMs() - started;
    try std.testing.expect(elapsed < 2000);
    if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.ReadFailed, error.WriteFailed => {},
        else => return err,
    }
}

test "等订阅回执时记下推送日志的最高块" {
    var session = Session.init(std.testing.allocator, undefined);
    defer session.subscription_ids.deinit(std.testing.allocator);
    session.observeHandshakePayload(
        \\{"jsonrpc":"2.0","id":1,"result":"0xsub"}
    );
    try std.testing.expect(session.dropped_live_hi == null);
    session.observeHandshakePayload(
        \\{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x1","result":{"address":"0xabc","topics":["0xt0"],"data":"0x","blockNumber":"0x10","transactionHash":"0xtx","logIndex":"0x0","removed":false}}}
    );
    try std.testing.expectEqual(@as(u64, 16), session.dropped_live_hi.?);
    session.observeHandshakePayload(
        \\{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x2","result":{"address":"0xdef","topics":[],"data":"0x","blockNumber":"0x12","transactionHash":"0xty","logIndex":"0x1","removed":false}}}
    );
    try std.testing.expectEqual(@as(u64, 18), session.dropped_live_hi.?);
}

test "encodeMaskedFrame text" {
    const payload = "hi";
    const mask = [_]u8{ 1, 2, 3, 4 };
    var out: [64]u8 = undefined;
    const n = try encodeMaskedFrame(.text, payload, &mask, &out);
    try std.testing.expect(n >= 2 + 4 + payload.len);
    const h0: Header0 = @bitCast(out[0]);
    try std.testing.expect(h0.fin);
    try std.testing.expect(h0.opcode == .text);
    const h1: Header1 = @bitCast(out[1]);
    try std.testing.expect(h1.mask);
    try std.testing.expectEqual(@as(u7, 2), @intFromEnum(h1.payload_len));
}
