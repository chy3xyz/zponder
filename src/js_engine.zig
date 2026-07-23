const std = @import("std");
const c = @import("c");
const log = @import("log.zig");
const db = @import("db.zig");

pub const JsEngine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    rt: ?*c.JSRuntime,
    ctx: ?*c.JSContext,

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
        };
        return engine;
    }

    pub fn deinit(self: *JsEngine) void {
        if (self.ctx) |ctx| c.JS_FreeContext(ctx);
        if (self.rt) |rt| c.JS_FreeRuntime(rt);
        self.alloc.destroy(self);
    }

    /// 执行 JavaScript 脚本代码
    pub fn evalScript(self: *JsEngine, script_code: []const u8, filename: []const u8) !void {
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
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".js")) {
                const full_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir_path, entry.name });
                defer self.alloc.free(full_path);

                self.loadScriptFile(full_path) catch |err| {
                    log.err("扫描执行 JS Handler 失败 ({s}): {any}", .{ full_path, err });
                };
            }
        }
    }
};

test "quickjs eval basic arithmetic" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = threaded.io();

    var engine = try JsEngine.init(alloc, io);
    defer engine.deinit();

    try engine.evalScript("const x = 10 + 20; if (x !== 30) throw new Error('eval failed');", "test.js");
}

test "quickjs scan loadDirectory" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = threaded.io();

    var engine = try JsEngine.init(alloc, io);
    defer engine.deinit();

    try engine.loadDirectory("examples/handlers");
}
