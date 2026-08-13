const std = @import("std");
const c = @import("c");
const log = @import("log.zig");
const db = @import("db.zig");

/// JS undefined 值（c.JS_UNDEFINED 宏在 Zig 0.17 的 zeroInit 有兼容问题，改用 JS_NewInt32）
fn jsUndefined(ctx: ?*c.JSContext) c.JSValue {
    return c.JS_NewInt32(ctx, 0);
}

pub const JsEngine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    rt: ?*c.JSRuntime,
    ctx: ?*c.JSContext,
    // event_name -> handler 函数（JS_DupValue 保持引用，避免被 GC）
    handlers: std.StringHashMap(c.JSValue),
    // QuickJS runtime 非线程安全；多索引器线程并发触发需串行化
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !*JsEngine {
        const engine = try alloc.create(JsEngine);
        const rt = c.JS_NewRuntime() orelse return error.JsRuntimeFailed;
        const ctx = c.JS_NewContext(rt) orelse {
            c.JS_FreeRuntime(rt);
            return error.JsContextFailed;
        };

        engine.* = .{
            .alloc = alloc,
            .io = io,
            .rt = rt,
            .ctx = ctx,
            .handlers = std.StringHashMap(c.JSValue).init(alloc),
        };
        // 存 engine 指针供 C 回调取回
        c.JS_SetRuntimeOpaque(rt, engine);
        try engine.injectPonder();
        return engine;
    }

    pub fn deinit(self: *JsEngine) void {
        // 释放已注册 handler 的引用
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            if (self.ctx) |ctx| c.JS_FreeValue(ctx, entry.value_ptr.*);
        }
        self.handlers.deinit();
        if (self.ctx) |ctx| c.JS_FreeContext(ctx);
        if (self.rt) |rt| c.JS_FreeRuntime(rt);
        self.alloc.destroy(self);
    }

    /// 注入全局 ponder 对象 + ponder.on(event, handler)
    fn injectPonder(self: *JsEngine) !void {
        const ctx = self.ctx orelse return error.NoContext;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);

        const ponder = c.JS_NewObject(ctx);
        const on_fn = c.JS_NewCFunction2(ctx, ponderOnCallback, "on", 2, 0, 0);
        _ = c.JS_SetPropertyStr(ctx, ponder, "on", on_fn);
        _ = c.JS_SetPropertyStr(ctx, global, "ponder", ponder);
        // 注意：JS_SetPropertyStr 接管 val 所有权，on_fn/ponder 无需（也不能）再 FreeValue
    }

    /// ponder.on(event, handler) 的 C 回调：注册 handler
    fn ponderOnCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 2) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));

        const event_val = argv[0];
        const handler_val = argv[1];
        if (!c.JS_IsString(event_val) or !c.JS_IsFunction(ctx, handler_val)) return jsUndefined(ctx);

        const evt_cstr = c.JS_ToCString(ctx, event_val) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, evt_cstr);
        const evt_name = std.mem.span(evt_cstr);

        engine.registerHandler(evt_name, handler_val);
        return jsUndefined(ctx);
    }

    fn registerHandler(self: *JsEngine, event_name: []const u8, handler_val: c.JSValue) void {
        const ctx = self.ctx orelse return;
        const key = self.alloc.dupe(u8, event_name) catch return;
        // 替换同名 handler（先释放旧的）
        if (self.handlers.getPtr(event_name)) |old| {
            c.JS_FreeValue(ctx, old.*);
            old.* = c.JS_DupValue(ctx, handler_val);
            self.alloc.free(key);
        } else {
            self.handlers.put(key, c.JS_DupValue(ctx, handler_val)) catch {
                self.alloc.free(key);
            };
        }
    }

    /// 事件触发入口（indexer 线程）：查找匹配 handler 并执行
    pub fn handleEvent(self: *JsEngine, contract_name: []const u8, event_name: []const u8, fields: []const db.DecodedField, block_number: u64) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        const ctx = self.ctx orelse return;

        // 匹配 "Contract:Event" 或 "Event" 两种写法
        const full_key_buf = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ contract_name, event_name }) catch return;
        defer self.alloc.free(full_key_buf);

        const handler = self.handlers.get(full_key_buf) orelse self.handlers.get(event_name) orelse return;

        // 构造 event 对象: { args: {field: value}, block: { number } }
        var event_obj = c.JS_NewObject(ctx);
        defer c.JS_FreeValue(ctx, event_obj);
        const args_obj = c.JS_NewObject(ctx);
        for (fields) |f| {
            const v = c.JS_NewStringLen(ctx, f.value.ptr, f.value.len);
            // JS_SetPropertyStr 需要 null 结尾 key，f.name 不保证
            const name_z = self.alloc.dupeSentinel(u8, f.name, 0) catch {
                c.JS_FreeValue(ctx, v);
                continue;
            };
            defer self.alloc.free(name_z);
            // JS_SetPropertyStr 接管 v 所有权，无需再 FreeValue
            _ = c.JS_SetPropertyStr(ctx, args_obj, name_z.ptr, v);
        }
        _ = c.JS_SetPropertyStr(ctx, event_obj, "args", args_obj);
        const block_obj = c.JS_NewObject(ctx);
        const bn = c.JS_NewInt64(ctx, @intCast(block_number));
        _ = c.JS_SetPropertyStr(ctx, block_obj, "number", bn);
        _ = c.JS_SetPropertyStr(ctx, event_obj, "block", block_obj);

        // 调用 handler(event)
        const result = c.JS_Call(ctx, handler, jsUndefined(ctx), 1, &event_obj);
        c.JS_FreeValue(ctx, result);

        // 驱动 async handler 的 pending jobs（有限次，避免长任务阻塞索引）
        var job_ctx: ?*c.JSContext = null;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const ret = c.JS_ExecutePendingJob(self.rt, &job_ctx);
            if (ret < 0) break;
            if (ret == 0) break;
        }
    }

    /// 执行 JavaScript 脚本代码
    pub fn evalScript(self: *JsEngine, script_code: []const u8, filename: []const u8) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        const ctx = self.ctx orelse return error.NoContext;
        const fn_z = try self.alloc.dupeSentinel(u8, filename, 0);
        defer self.alloc.free(fn_z);

        const val = c.JS_Eval(ctx, script_code.ptr, script_code.len, fn_z.ptr, c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(val)) {
            const exception_val = c.JS_GetException(ctx);
            const str = c.JS_ToCString(ctx, exception_val);
            if (str != null) {
                defer c.JS_FreeCString(ctx, str);
                log.err("JS 执行异常 ({s}): {s}", .{ filename, str });
            }
            c.JS_FreeValue(ctx, exception_val);
            return error.JsEvalException;
        }
        c.JS_FreeValue(ctx, val);
    }

    /// 从文件加载并执行 JS Handler 脚本
    pub fn loadScriptFile(self: *JsEngine, file_path: []const u8) !void {
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.alloc, .limited(1024 * 1024)) catch |err| {
            log.warn("JS Handler 脚本读取失败 {s}: {any}", .{ file_path, err });
            return;
        };
        defer self.alloc.free(contents);

        try self.evalScript(contents, file_path);
        log.info("成功编译并运行原生 QuickJS Handler 脚本: {s}", .{file_path});
    }

    /// 自动扫描并加载指定目录下的所有 .js 脚本文件
    pub fn loadDirectory(self: *JsEngine, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            log.warn("JS Handler 目录打开失败 {s}: {any}", .{ dir_path, err });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
            const full_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir_path, entry.name });
            defer self.alloc.free(full_path);
            self.loadScriptFile(full_path) catch {};
        }
    }
};

test "js engine ponder.on 注册与事件触发" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    // 注册 handler：把收到的 block.number 存到全局变量
    try engine.evalScript(
        \\var received = null;
        \\ponder.on("Transfer", function(event) { received = event.block.number; });
    , "test.js");

    // 触发事件（Contract:Event 与 Event 两种写法都应匹配）
    const fields = [_]db.DecodedField{.{ .name = "value", .value = "100" }};
    engine.handleEvent("dai", "Transfer", &fields, 123);

    // 验证 handler 被调用
    try engine.evalScript("if (received !== 123) throw new Error('handler not called: ' + received);", "check.js");
}

test "js engine ponder.on Contract:Event 全名匹配" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\var hit = 0;
        \\ponder.on("Dai:Transfer", function(event) { hit = event.args.value; });
    , "test.js");

    const fields = [_]db.DecodedField{.{ .name = "value", .value = "0x64" }};
    engine.handleEvent("Dai", "Transfer", &fields, 1);

    try engine.evalScript("if (hit !== '0x64') throw new Error('not hit: ' + hit);", "check.js");
}
