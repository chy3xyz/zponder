const std = @import("std");
const log = @import("log.zig");
const db = @import("db.zig");

pub const WebhookMessage = struct {
    contract_name: []const u8,
    event_name: []const u8,
    block_number: u64,
    payload_json: []const u8,

    pub fn deinit(self: *WebhookMessage, alloc: std.mem.Allocator) void {
        alloc.free(self.contract_name);
        alloc.free(self.event_name);
        alloc.free(self.payload_json);
    }
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    target_url: []const u8,
    queue: std.ArrayList(WebhookMessage),
    mutex: std.atomic.Mutex,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, target_url: []const u8) !*Manager {
        const m = try alloc.create(Manager);
        m.* = .{
            .alloc = alloc,
            .io = io,
            .target_url = try alloc.dupe(u8, target_url),
            .queue = .empty,
            .mutex = .unlocked,
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };
        m.thread = try std.Thread.spawn(.{}, workerLoop, .{m});
        return m;
    }

    pub fn deinit(self: *Manager) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.mutex.unlock();
            for (self.queue.items) |*msg| {
                msg.deinit(self.alloc);
            }
            self.queue.deinit(self.alloc);
        }
        self.alloc.free(self.target_url);
        self.alloc.destroy(self);
    }

    pub fn enqueueEvent(
        self: *Manager,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) void {
        if (!self.running.load(.acquire)) return;
        if (self.target_url.len == 0) return;

        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer buf.deinit();
        const w = &buf.writer;
        w.print(
            "{{\"contract\":\"{s}\",\"event\":\"{s}\",\"block_number\":{d},\"fields\":{{",
            .{ contract_name, event_name, block_number },
        ) catch return;

        for (fields, 0..) |f, i| {
            if (i > 0) w.writeByte(',') catch return;
            w.print("\"{s}\":\"{s}\"", .{ f.name, f.value }) catch return;
        }
        w.writeAll("}}}") catch return;

        const payload = self.alloc.dupe(u8, buf.written()) catch return;

        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        if (self.queue.items.len < 1000) {
            self.queue.append(self.alloc, .{
                .contract_name = self.alloc.dupe(u8, contract_name) catch return,
                .event_name = self.alloc.dupe(u8, event_name) catch return,
                .block_number = block_number,
                .payload_json = payload,
            }) catch return;
        } else {
            self.alloc.free(payload);
        }
    }

    fn workerLoop(self: *Manager) void {
        var http_client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer http_client.deinit();

        while (self.running.load(.acquire)) {
            var msg_opt: ?WebhookMessage = null;
            {
                while (!self.mutex.tryLock()) {
                    std.atomic.spinLoopHint();
                }
                if (self.queue.items.len > 0) {
                    msg_opt = self.queue.orderedRemove(0);
                }
                self.mutex.unlock();
            }

            if (msg_opt) |*msg| {
                defer msg.deinit(self.alloc);
                var response_writer: std.Io.Writer.Allocating = .init(self.alloc);
                defer response_writer.deinit();

                _ = http_client.fetch(.{
                    .location = .{ .url = self.target_url },
                    .method = .POST,
                    .payload = msg.payload_json,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/json" },
                    },
                    .response_writer = &response_writer.writer,
                }) catch |err| {
                    log.warn("Webhook 推送失败 ({s}): {any}", .{ self.target_url, err });
                };
            } else {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
            }
        }
    }
};

test "webhook queue enqueue and deinit" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = threaded.io();
    var mgr = try Manager.init(alloc, io, "");
    defer mgr.deinit();

    mgr.enqueueEvent("pancake", "Swap", &.{}, 100);
}
