const std = @import("std");
const log = @import("log.zig");
const db = @import("db.zig");

pub const Action = union(enum) {
    log_msg: []const u8,
    webhook_url: []const u8,
    update_account: struct {
        contract: []const u8,
        account_field: []const u8,
        balance_field: []const u8,
    },
};

pub const Rule = struct {
    contract: []const u8,
    event: []const u8,
    field: []const u8,
    op: []const u8, // "eq", "gt", "gte", "lt", "lte", "always"
    val: []const u8,
    action: Action,

    pub fn deinit(self: *Rule, alloc: std.mem.Allocator) void {
        alloc.free(self.contract);
        alloc.free(self.event);
        alloc.free(self.field);
        alloc.free(self.op);
        alloc.free(self.val);
        switch (self.action) {
            .log_msg => |m| alloc.free(m),
            .webhook_url => |u| alloc.free(u),
            .update_account => |ua| {
                alloc.free(ua.contract);
                alloc.free(ua.account_field);
                alloc.free(ua.balance_field);
            },
        }
    }
};

pub const ScriptEngine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    rules: std.ArrayList(Rule),
    mutex: std.atomic.Mutex,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) ScriptEngine {
        return .{
            .alloc = alloc,
            .io = io,
            .rules = .empty,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *ScriptEngine) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        for (self.rules.items) |*r| {
            r.deinit(self.alloc);
        }
        self.rules.deinit(self.alloc);
    }

    /// 从 JSON / Rule 机制动态添加一个处理器规则
    pub fn addRule(self: *ScriptEngine, rule: Rule) !void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        try self.rules.append(self.alloc, rule);
    }

    /// 从 Handler 脚本文件（如 handlers/rules.json）中加载脚本规则
    pub fn loadScriptFile(self: *ScriptEngine, path: []const u8) !void {
        const file_contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1024 * 1024)) catch |err| {
            log.warn("未找到 Handler 脚本文件 {s}: {any}", .{ path, err });
            return;
        };
        defer self.alloc.free(file_contents);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, file_contents, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const contract = obj.get("contract") orelse continue;
            const event = obj.get("event") orelse continue;
            const field = obj.get("field") orelse continue;
            const op = obj.get("op") orelse continue;
            const val = obj.get("val") orelse continue;
            const action_obj = obj.get("action") orelse continue;

            if (contract != .string or event != .string or field != .string or op != .string or val != .string or action_obj != .object) continue;

            const action_type = action_obj.object.get("type") orelse continue;
            if (action_type != .string) continue;

            const act: Action = if (std.mem.eql(u8, action_type.string, "log")) blk: {
                const msg = action_obj.object.get("msg") orelse continue;
                if (msg != .string) continue;
                break :blk .{ .log_msg = try self.alloc.dupe(u8, msg.string) };
            } else if (std.mem.eql(u8, action_type.string, "webhook")) blk: {
                const url = action_obj.object.get("url") orelse continue;
                if (url != .string) continue;
                break :blk .{ .webhook_url = try self.alloc.dupe(u8, url.string) };
            } else continue;

            try self.addRule(.{
                .contract = try self.alloc.dupe(u8, contract.string),
                .event = try self.alloc.dupe(u8, event.string),
                .field = try self.alloc.dupe(u8, field.string),
                .op = try self.alloc.dupe(u8, op.string),
                .val = try self.alloc.dupe(u8, val.string),
                .action = act,
            });
        }
        log.info("成功加载 {d} 条动态 Handler 脚本规则 ({s})", .{ self.rules.items.len, path });
    }

    /// 自动扫描并加载指定目录下的所有 .json 脚本规则文件
    pub fn loadDirectory(self: *ScriptEngine, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                const full_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir_path, entry.name });
                defer self.alloc.free(full_path);

                self.loadScriptFile(full_path) catch |err| {
                    log.err("扫描加载 JSON Handler 规则失败 ({s}): {any}", .{ full_path, err });
                };
            }
        }
    }

    /// 执行脚本引擎：匹配事件并触发动作
    pub fn processEvent(
        self: *ScriptEngine,
        contract_name: []const u8,
        event_name: []const u8,
        fields: []const db.DecodedField,
        block_number: u64,
    ) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        for (self.rules.items) |r| {
            if (!std.mem.eql(u8, r.contract, "*") and !std.mem.eql(u8, r.contract, contract_name)) continue;
            if (!std.mem.eql(u8, r.event, "*") and !std.mem.eql(u8, r.event, event_name)) continue;

            var matched = std.mem.eql(u8, r.op, "always");

            if (!matched) {
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, r.field)) {
                        if (std.mem.eql(u8, r.op, "eq") and std.mem.eql(u8, f.value, r.val)) {
                            matched = true;
                        } else if (std.mem.eql(u8, r.op, "gt") or std.mem.eql(u8, r.op, "gte")) {
                            const f_num = std.fmt.parseInt(u256, f.value, 10) catch 0;
                            const r_num = std.fmt.parseInt(u256, r.val, 10) catch 0;
                            if (std.mem.eql(u8, r.op, "gt") and f_num > r_num) matched = true;
                            if (std.mem.eql(u8, r.op, "gte") and f_num >= r_num) matched = true;
                        }
                    }
                }
            }

            if (matched) {
                switch (r.action) {
                    .log_msg => |m| {
                        log.info("[ScriptEngine Handler] {s} | {s}.{s} @ 区块 {d}", .{ m, contract_name, event_name, block_number });
                    },
                    .webhook_url => |u| {
                        log.info("[ScriptEngine Webhook] 触发 Webhook 目标 {s} @ 区块 {d}", .{ u, block_number });
                    },
                    .update_account => {},
                }
            }
        }
    }
};

test "script engine add and process rule" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = threaded.io();
    var engine = ScriptEngine.init(alloc, io);
    defer engine.deinit();

    try engine.addRule(.{
        .contract = try alloc.dupe(u8, "dai"),
        .event = try alloc.dupe(u8, "Transfer"),
        .field = try alloc.dupe(u8, "value"),
        .op = try alloc.dupe(u8, "always"),
        .val = try alloc.dupe(u8, "0"),
        .action = .{ .log_msg = try alloc.dupe(u8, "Test event matched") },
    });

    const fields = [_]db.DecodedField{
        .{ .name = "value", .value = "100" },
    };
    engine.processEvent("dai", "Transfer", &fields, 12345);
}

test "script engine scan loadDirectory" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = threaded.io();

    var engine = ScriptEngine.init(alloc, io);
    defer engine.deinit();

    try engine.loadDirectory("examples/handlers");
}
