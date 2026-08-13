const std = @import("std");
const db = @import("db.zig");

/// 实时事件（索引器解码后的事件），深拷贝到订阅者队列。
pub const Event = struct {
    contract_name: []const u8,
    event_name: []const u8,
    block_number: u64,
    fields: []db.DecodedField,

    pub fn clone(alloc: std.mem.Allocator, contract_name: []const u8, event_name: []const u8, fields: []const db.DecodedField, block_number: u64) !Event {
        const fields_copy = try alloc.alloc(db.DecodedField, fields.len);
        var filled: usize = 0;
        errdefer {
            // OOM 时释放已 dupe 的前序字段（否则泄漏）
            for (fields_copy[0..filled]) |f| {
                alloc.free(f.name);
                alloc.free(f.value);
            }
            alloc.free(fields_copy);
        }
        for (fields, 0..) |f, i| {
            fields_copy[i] = .{
                .name = try alloc.dupe(u8, f.name),
                .value = try alloc.dupe(u8, f.value),
            };
            filled = i + 1;
        }
        const cn = try alloc.dupe(u8, contract_name);
        errdefer alloc.free(cn);
        const en = try alloc.dupe(u8, event_name);
        errdefer alloc.free(en);
        return .{
            .contract_name = cn,
            .event_name = en,
            .block_number = block_number,
            .fields = fields_copy,
        };
    }

    pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
        alloc.free(self.contract_name);
        alloc.free(self.event_name);
        for (self.fields) |f| {
            alloc.free(f.name);
            alloc.free(f.value);
        }
        alloc.free(self.fields);
        self.* = undefined;
    }
};

/// 单个订阅者（一个 SSE 连接），持有有界事件队列。
pub const Subscriber = struct {
    alloc: std.mem.Allocator,
    queue: std.ArrayList(Event),
    mutex: std.atomic.Mutex = .unlocked,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    const max_queue = 1000;

    pub fn init(alloc: std.mem.Allocator) Subscriber {
        return .{ .alloc = alloc, .queue = .empty };
    }

    pub fn deinit(self: *Subscriber) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.queue.items) |*e| e.deinit(self.alloc);
        self.queue.deinit(self.alloc);
    }

    /// 生产端推入（indexer 线程）；队列满则丢弃最旧。
    fn push(self: *Subscriber, ev: Event) void {
        var ev_mut = ev; // 参数默认 const，deinit 需要可变
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.closed.load(.acquire)) {
            ev_mut.deinit(self.alloc);
            return;
        }
        if (self.queue.items.len >= max_queue) {
            var old = self.queue.orderedRemove(0);
            old.deinit(self.alloc);
        }
        self.queue.append(self.alloc, ev_mut) catch {
            ev_mut.deinit(self.alloc);
        };
    }

    /// 消费端阻塞读取（SSE 线程）；返回 null 表示已关闭。
    pub fn next(self: *Subscriber, io: std.Io) ?Event {
        while (!self.closed.load(.acquire)) {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.queue.items.len > 0) {
                const ev = self.queue.orderedRemove(0);
                self.mutex.unlock();
                return ev;
            }
            self.mutex.unlock();
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
        }
        return null;
    }

    pub fn close(self: *Subscriber) void {
        self.closed.store(true, .release);
    }
};

/// 事件广播：indexer 生产，SSE 订阅者消费。
pub const EventBus = struct {
    alloc: std.mem.Allocator,
    subscribers: std.ArrayList(*Subscriber),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(alloc: std.mem.Allocator) EventBus {
        return .{ .alloc = alloc, .subscribers = .empty };
    }

    pub fn deinit(self: *EventBus) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        for (self.subscribers.items) |s| {
            s.close();
            s.deinit();
            self.alloc.destroy(s);
        }
        self.mutex.unlock();
        self.subscribers.deinit(self.alloc);
    }

    pub fn subscribe(self: *EventBus) !*Subscriber {
        const s = try self.alloc.create(Subscriber);
        s.* = Subscriber.init(self.alloc);
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.subscribers.append(self.alloc, s);
        return s;
    }

    pub fn unsubscribe(self: *EventBus, s: *Subscriber) void {
        s.close();
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.subscribers.items, 0..) |sub, i| {
            if (sub == s) {
                _ = self.subscribers.orderedRemove(i);
                break;
            }
        }
    }

    /// 广播事件到所有订阅者（每个订阅者深拷贝一份）。
    pub fn publish(self: *EventBus, contract_name: []const u8, event_name: []const u8, fields: []const db.DecodedField, block_number: u64) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.subscribers.items) |s| {
            const ev = Event.clone(self.alloc, contract_name, event_name, fields, block_number) catch continue;
            s.push(ev);
        }
    }
};
