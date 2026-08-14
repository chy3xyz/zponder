const std = @import("std");
const c = @import("c");
const log = @import("log.zig");
const db = @import("db.zig");

/// JS undefined 值（立即数，无堆分配）。
/// 注意：c.JS_UNDEFINED 宏在 Zig 0.17 的 zeroInit 有兼容问题，手动构造；
/// 不能用 JS_NewInt32(0)，那会返回 int 0 而非 undefined，破坏 === undefined 判断。
fn jsUndefined(ctx: ?*c.JSContext) c.JSValue {
    _ = ctx;
    return .{ .u = .{ .int32 = 0 }, .tag = @as(i64, c.JS_TAG_UNDEFINED) };
}

/// ponder.http 路由（Hono-like 最小实现）
pub const HttpRoute = struct {
    method: HttpMethod,
    path: []const u8,
    handler: c.JSValue,
};

pub const HttpMethod = enum { get, post, put, delete };

pub const ContentType = enum { json, text };

/// handleHttpRequest 的响应（body 由调用者 free）
pub const HttpResponse = struct {
    body: []u8,
    content_type: ContentType,
    status: u16 = 200,
    headers: std.ArrayList([]const u8) = .empty,
};

/// HTTP 请求上下文（供 c.req.param/query/body 回调读取）
const HttpRequestCtx = struct {
    params: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    body: []const u8,
};

/// middleware 分发上下文（handleHttpRequest 期间有效）
const DispatchCtx = struct {
    c_obj: c.JSValue,
    next_fn: c.JSValue,
    middlewares: []const c.JSValue,
    final_handler: c.JSValue,
    index: usize,
};

pub const JsEngine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    rt: ?*c.JSRuntime,
    ctx: ?*c.JSContext,
    // event_name -> handler 函数（JS_DupValue 保持引用，避免被 GC）
    handlers: std.StringHashMap(c.JSValue),
    // ponder.http 路由表
    http_routes: std.ArrayList(HttpRoute),
    // ponder.http middleware 链（use 注册）
    http_middlewares: std.ArrayList(c.JSValue),
    // 当前 HTTP 请求上下文（handleHttpRequest 期间有效，供 C 回调读取）
    current_req: ?*const HttpRequestCtx = null,
    // 当前 middleware 分发上下文
    dispatch_ctx: ?*DispatchCtx = null,
    // 当前响应的 content type / status / headers（c.json/c.text/c.status/c.header 设置）
    current_content_type: ContentType = .json,
    current_status: u16 = 200,
    current_headers: std.ArrayList([]const u8) = .empty,
    // handler 的返回值（middleware 链可能不 return，需独立记录）
    final_response: ?c.JSValue = null,
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
            .http_routes = .empty,
            .http_middlewares = .empty,
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
        // 释放 http 路由
        for (self.http_routes.items) |*r| {
            self.alloc.free(r.path);
            if (self.ctx) |ctx| c.JS_FreeValue(ctx, r.handler);
        }
        self.http_routes.deinit(self.alloc);
        // 释放 middleware
        for (self.http_middlewares.items) |*m| {
            if (self.ctx) |ctx| c.JS_FreeValue(ctx, m.*);
        }
        self.http_middlewares.deinit(self.alloc);
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

        // ponder.http（Hono-like）：.use/.get/.post/.put/.delete(path, handler)
        const http_obj = c.JS_NewObject(ctx);
        const use_fn = c.JS_NewCFunction2(ctx, httpUseCallback, "use", 1, 0, 0);
        const get_fn = c.JS_NewCFunction2(ctx, httpGetCallback, "get", 2, 0, 0);
        const post_fn = c.JS_NewCFunction2(ctx, httpPostCallback, "post", 2, 0, 0);
        const put_fn = c.JS_NewCFunction2(ctx, httpPutCallback, "put", 2, 0, 0);
        const del_fn = c.JS_NewCFunction2(ctx, httpDeleteCallback, "delete", 2, 0, 0);
        _ = c.JS_SetPropertyStr(ctx, http_obj, "use", use_fn);
        _ = c.JS_SetPropertyStr(ctx, http_obj, "get", get_fn);
        _ = c.JS_SetPropertyStr(ctx, http_obj, "post", post_fn);
        _ = c.JS_SetPropertyStr(ctx, http_obj, "put", put_fn);
        _ = c.JS_SetPropertyStr(ctx, http_obj, "delete", del_fn);
        _ = c.JS_SetPropertyStr(ctx, ponder, "http", http_obj);

        _ = c.JS_SetPropertyStr(ctx, global, "ponder", ponder);
        // 注意：JS_SetPropertyStr 接管 val 所有权，on_fn/ponder 等无需（也不能）再 FreeValue
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

    /// ponder.http.get(path, handler) 回调
    fn httpGetCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        return httpRouteCallback(ctx, argc, argv, .get);
    }

    /// ponder.http.post(path, handler) 回调
    fn httpPostCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        return httpRouteCallback(ctx, argc, argv, .post);
    }

    /// ponder.http.put(path, handler) 回调
    fn httpPutCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        return httpRouteCallback(ctx, argc, argv, .put);
    }

    /// ponder.http.delete(path, handler) 回调
    fn httpDeleteCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        return httpRouteCallback(ctx, argc, argv, .delete);
    }

    /// ponder.http.use(middleware) 回调
    fn httpUseCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        const mw = argv[0];
        if (!c.JS_IsFunction(ctx, mw)) return jsUndefined(ctx);
        engine.http_middlewares.append(engine.alloc, c.JS_DupValue(ctx, mw)) catch {};
        return jsUndefined(ctx);
    }

    /// next()：middleware 洋葱模型，前进到下一个处理器
    fn nextCallback(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        _ = argc;
        _ = argv;
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        const d = engine.dispatch_ctx orelse return jsUndefined(ctx);
        d.index += 1;
        if (d.index < d.middlewares.len) {
            var args = [_]c.JSValue{ d.c_obj, d.next_fn };
            return c.JS_Call(ctx, d.middlewares[d.index], this_val, 2, &args);
        }
        // 最终 handler：记录返回值（middleware 可能不 return，需独立传递）
        var harg = [_]c.JSValue{d.c_obj};
        const r = c.JS_Call(ctx, d.final_handler, this_val, 1, &harg);
        if (engine.final_response) |fr| c.JS_FreeValue(ctx, fr);
        engine.final_response = c.JS_DupValue(ctx, r);
        return r;
    }

    /// c.status(code)：设置响应状态码
    fn cStatusCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        if (argc >= 1) {
            var code: i32 = 0;
            if (c.JS_ToInt32(ctx, &code, argv[0]) == 0 and code > 0 and code < 600) {
                engine.current_status = @intCast(code);
            }
        }
        return jsUndefined(ctx);
    }

    /// c.header(name, value)：设置响应头
    fn cHeaderCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 2) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        const name_cstr = c.JS_ToCString(ctx, argv[0]) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, name_cstr);
        const val_cstr = c.JS_ToCString(ctx, argv[1]) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, val_cstr);
        engine.current_headers.append(engine.alloc, engine.alloc.dupe(u8, std.mem.span(name_cstr)) catch return jsUndefined(ctx)) catch return jsUndefined(ctx);
        engine.current_headers.append(engine.alloc, engine.alloc.dupe(u8, std.mem.span(val_cstr)) catch return jsUndefined(ctx)) catch return jsUndefined(ctx);
        return jsUndefined(ctx);
    }

    fn httpRouteCallback(ctx: ?*c.JSContext, argc: c_int, argv: [*c]c.JSValue, method: HttpMethod) c.JSValue {
        if (argc < 2) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));

        const path_val = argv[0];
        const handler_val = argv[1];
        if (!c.JS_IsString(path_val) or !c.JS_IsFunction(ctx, handler_val)) return jsUndefined(ctx);

        const path_cstr = c.JS_ToCString(ctx, path_val) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, path_cstr);
        const path = std.mem.span(path_cstr);

        engine.registerHttpRoute(method, path, handler_val);
        return jsUndefined(ctx);
    }

    fn registerHttpRoute(self: *JsEngine, method: HttpMethod, path: []const u8, handler_val: c.JSValue) void {
        const ctx = self.ctx orelse return;
        const path_copy = self.alloc.dupe(u8, path) catch return;
        self.http_routes.append(self.alloc, .{
            .method = method,
            .path = path_copy,
            .handler = c.JS_DupValue(ctx, handler_val),
        }) catch {
            self.alloc.free(path_copy);
        };
    }

    /// c.req.param(name) 回调
    fn reqParamCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        const name_cstr = c.JS_ToCString(ctx, argv[0]) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, name_cstr);
        const name = std.mem.span(name_cstr);

        if (engine.current_req) |req| {
            if (req.params.get(name)) |v| {
                return c.JS_NewStringLen(ctx, v.ptr, v.len);
            }
        }
        return jsUndefined(ctx);
    }

    /// c.req.query(name) 回调
    fn reqQueryCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return jsUndefined(ctx);
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        const name_cstr = c.JS_ToCString(ctx, argv[0]) orelse return jsUndefined(ctx);
        defer c.JS_FreeCString(ctx, name_cstr);
        const name = std.mem.span(name_cstr);

        if (engine.current_req) |req| {
            if (req.query.get(name)) |v| {
                return c.JS_NewStringLen(ctx, v.ptr, v.len);
            }
        }
        return jsUndefined(ctx);
    }

    /// c.json(obj)：把 obj JSON 序列化后作为响应体返回
    fn cJsonCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        engine.current_content_type = .json;

        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const json_obj = c.JS_GetPropertyStr(ctx, global, "JSON");
        defer c.JS_FreeValue(ctx, json_obj);
        const stringify = c.JS_GetPropertyStr(ctx, json_obj, "stringify");
        defer c.JS_FreeValue(ctx, stringify);

        var target = if (argc >= 1) argv[0] else jsUndefined(ctx);
        // JSON.stringify(target)
        return c.JS_Call(ctx, stringify, jsUndefined(ctx), 1, &target);
    }

    /// c.text(str)：直接返回字符串作为响应体
    fn cTextCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        engine.current_content_type = .text;

        if (argc < 1) return jsUndefined(ctx);
        return c.JS_DupValue(ctx, argv[0]);
    }

    /// c.req.body()：返回请求体字符串
    fn reqBodyCallback(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const rt = c.JS_GetRuntime(ctx);
        const engine = @as(*JsEngine, @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(rt) orelse return jsUndefined(ctx))));
        if (engine.current_req) |req| {
            if (req.body.len > 0) {
                return c.JS_NewStringLen(ctx, req.body.ptr, req.body.len);
            }
        }
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

    /// HTTP 动态路由入口：匹配 ponder.http 注册的路由并执行 handler。
    /// 返回 alloc 的响应体（调用者 free）；null 表示无匹配路由。
    pub fn handleHttpRequest(self: *JsEngine, method: HttpMethod, path: []const u8, query_string: []const u8, req_body: []const u8) ?HttpResponse {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        const ctx = self.ctx orelse return null;

        // 匹配路由并捕获路径参数
        var params = std.StringHashMap([]const u8).init(self.alloc);
        defer {
            var it = params.iterator();
            while (it.next()) |e| self.alloc.free(e.key_ptr.*);
            params.deinit();
        }
        const route = matchRoute(self.alloc, self.http_routes.items, method, path, &params) orelse return null;

        // 解析 query string 到 map
        var query = std.StringHashMap([]const u8).init(self.alloc);
        defer {
            var it = query.iterator();
            while (it.next()) |e| {
                self.alloc.free(e.key_ptr.*);
                self.alloc.free(e.value_ptr.*);
            }
            query.deinit();
        }
        parseQueryString(self.alloc, query_string, &query);

        // 构造 c 对象：{ req: { param, query, body }, json, text }
        var c_obj = c.JS_NewObject(ctx);
        defer c.JS_FreeValue(ctx, c_obj);
        const req_obj = c.JS_NewObject(ctx);
        const param_fn = c.JS_NewCFunction2(ctx, reqParamCallback, "param", 1, 0, 0);
        const query_fn = c.JS_NewCFunction2(ctx, reqQueryCallback, "query", 1, 0, 0);
        const body_fn = c.JS_NewCFunction2(ctx, reqBodyCallback, "body", 0, 0, 0);
        _ = c.JS_SetPropertyStr(ctx, req_obj, "param", param_fn);
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", query_fn);
        _ = c.JS_SetPropertyStr(ctx, req_obj, "body", body_fn);
        _ = c.JS_SetPropertyStr(ctx, c_obj, "req", req_obj);
        const json_fn = c.JS_NewCFunction2(ctx, cJsonCallback, "json", 1, 0, 0);
        const text_fn = c.JS_NewCFunction2(ctx, cTextCallback, "text", 1, 0, 0);
        const status_fn = c.JS_NewCFunction2(ctx, cStatusCallback, "status", 1, 0, 0);
        const header_fn = c.JS_NewCFunction2(ctx, cHeaderCallback, "header", 2, 0, 0);
        _ = c.JS_SetPropertyStr(ctx, c_obj, "json", json_fn);
        _ = c.JS_SetPropertyStr(ctx, c_obj, "text", text_fn);
        _ = c.JS_SetPropertyStr(ctx, c_obj, "status", status_fn);
        _ = c.JS_SetPropertyStr(ctx, c_obj, "header", header_fn);

        // 设置当前请求上下文（供 c.req.param/query/body 回调读取）
        var req_ctx = HttpRequestCtx{ .params = params, .query = query, .body = req_body };
        self.current_req = &req_ctx;
        defer self.current_req = null;
        // 重置响应状态（每请求独立）
        self.current_content_type = .json;
        self.current_status = 200;
        for (self.current_headers.items) |h| self.alloc.free(h);
        self.current_headers.clearRetainingCapacity();

        // middleware 洋葱链：use 注册的中间件依次执行，next() 前进
        const next_fn = c.JS_NewCFunction2(ctx, nextCallback, "next", 0, 0, 0);
        defer c.JS_FreeValue(ctx, next_fn);
        var disp = DispatchCtx{
            .c_obj = c_obj,
            .next_fn = next_fn,
            .middlewares = self.http_middlewares.items,
            .final_handler = route.handler,
            .index = 0,
        };
        self.dispatch_ctx = &disp;
        defer self.dispatch_ctx = null;

        // 重置最终响应（handler 的返回值独立于 middleware 链传递）
        if (self.final_response) |fr| c.JS_FreeValue(ctx, fr);
        self.final_response = null;

        // 调用第一个 middleware（或无 middleware 时直接调 handler）
        var mw_args = [_]c.JSValue{ c_obj, next_fn };
        const result = if (disp.middlewares.len > 0)
            c.JS_Call(ctx, disp.middlewares[0], jsUndefined(ctx), 2, &mw_args)
        else blk: {
            const r = c.JS_Call(ctx, disp.final_handler, jsUndefined(ctx), 1, &c_obj);
            self.final_response = c.JS_DupValue(ctx, r);
            break :blk r;
        };
        defer c.JS_FreeValue(ctx, result);

        // 驱动 async pending jobs
        var job_ctx: ?*c.JSContext = null;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const ret = c.JS_ExecutePendingJob(self.rt, &job_ctx);
            if (ret <= 0) break;
        }

        // 最终响应：handler 的返回值（middleware 可能不 return）
        const resp_val = self.final_response orelse result;

        if (c.JS_IsException(resp_val)) {
            // handler 抛异常 → 500
            const exc = c.JS_GetException(ctx);
            const exc_cstr = c.JS_ToCString(ctx, exc) orelse null;
            c.JS_FreeValue(ctx, exc);
            defer if (exc_cstr) |s| c.JS_FreeCString(ctx, s);
            const msg_body = if (exc_cstr) |s|
                (self.alloc.dupe(u8, std.mem.span(s)) catch return null)
            else
                (self.alloc.dupe(u8, "Internal Server Error") catch return null);
            return HttpResponse{
                .body = msg_body,
                .content_type = .text,
                .status = 500,
                .headers = self.takeCurrentHeaders(),
            };
        }
        // 返回值是字符串（c.json/c.text 的结果）或 undefined
        if (!c.JS_IsString(resp_val)) return null;
        const body_cstr = c.JS_ToCString(ctx, resp_val) orelse return null;
        defer c.JS_FreeCString(ctx, body_cstr);
        const body_dup = self.alloc.dupe(u8, std.mem.span(body_cstr)) catch return null;
        return HttpResponse{
            .body = body_dup,
            .content_type = self.current_content_type,
            .status = self.current_status,
            .headers = self.takeCurrentHeaders(),
        };
    }

    /// 转移当前响应头到返回值（move 语义，调用者负责 free）
    fn takeCurrentHeaders(self: *JsEngine) std.ArrayList([]const u8) {
        const h = self.current_headers;
        self.current_headers = .empty;
        return h;
    }

    fn matchRoute(alloc: std.mem.Allocator, routes: []const HttpRoute, method: HttpMethod, path: []const u8, params: *std.StringHashMap([]const u8)) ?*const HttpRoute {
        for (routes) |*r| {
            if (r.method != method) continue;
            if (matchPath(alloc, r.path, path, params)) return r;
        }
        return null;
    }

    fn matchPath(alloc: std.mem.Allocator, pattern: []const u8, path: []const u8, params: *std.StringHashMap([]const u8)) bool {
        var p_it = std.mem.splitScalar(u8, pattern, '/');
        var a_it = std.mem.splitScalar(u8, path, '/');
        while (true) {
            const p_seg = p_it.next();
            const a_seg = a_it.next();
            if (p_seg == null and a_seg == null) return true;
            if (p_seg == null or a_seg == null) return false;
            const p = p_seg.?;
            const a = a_seg.?;
            if (p.len > 0 and p[0] == ':') {
                const key = p[1..];
                if (params.get(key) == null) {
                    params.put(alloc.dupe(u8, key) catch return false, a) catch return false;
                }
            } else if (!std.mem.eql(u8, p, a)) {
                return false;
            }
        }
    }

    fn parseQueryString(alloc: std.mem.Allocator, qs: []const u8, map: *std.StringHashMap([]const u8)) void {
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = pair[0..eq];
            const val = if (eq < pair.len) pair[eq + 1 ..] else "";
            if (map.get(key) != null) continue;
            const k = alloc.dupe(u8, key) catch continue;
            const v = alloc.dupe(u8, val) catch {
                alloc.free(k);
                continue;
            };
            map.put(k, v) catch {
                alloc.free(k);
                alloc.free(v);
            };
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

test "js engine ponder.http 动态路由" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\ponder.http.get("/api/token/:address", function(c) {
        \\  const address = c.req.param("address");
        \\  const q = c.req.query("name");
        \\  return c.json({ address: address, name: q });
        \\});
    , "routes.js");

    const resp = engine.handleHttpRequest(.get, "/api/token/0x123", "name=alice", "").?;
    defer alloc.free(resp.body);
    try std.testing.expectEqual(ContentType.json, resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "0x123") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "alice") != null);

    // 无匹配路由返回 null
    try std.testing.expect(engine.handleHttpRequest(.get, "/nope", "", "") == null);
}

test "js engine ponder.http c.text 与 body" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\ponder.http.post("/echo", function(c) { return c.text(c.req.body()); });
    , "routes.js");

    const resp = engine.handleHttpRequest(.post, "/echo", "", "hello-body").?;
    defer alloc.free(resp.body);
    try std.testing.expectEqual(ContentType.text, resp.content_type);
    try std.testing.expectEqualStrings("hello-body", resp.body);
}

test "js engine ponder.http middleware 洋葱模型" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\var order = [];
        \\ponder.http.use(function(c, next) { order.push("a1"); next(); order.push("a2"); });
        \\ponder.http.use(function(c, next) { order.push("b1"); next(); order.push("b2"); });
        \\ponder.http.get("/x", function(c) { order.push("h"); return c.text("ok"); });
    , "mw.js");

    const resp = engine.handleHttpRequest(.get, "/x", "", "").?;
    defer alloc.free(resp.body);
    try std.testing.expectEqualStrings("ok", resp.body);

    // 验证洋葱顺序：a1 -> b1 -> h -> b2 -> a2
    try engine.evalScript(
        "if (order.join(',') !== 'a1,b1,h,b2,a2') throw new Error('order=' + order.join(','));",
        "check.js",
    );
}

test "js engine ponder.http status 与 header" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\ponder.http.get("/notfound", function(c) {
        \\  c.status(404);
        \\  c.header("X-Custom", "yes");
        \\  return c.json({ error: "nope" });
        \\});
    , "routes.js");

    var resp = engine.handleHttpRequest(.get, "/notfound", "", "").?;
    defer {
        alloc.free(resp.body);
        for (resp.headers.items) |h| alloc.free(h);
        resp.headers.deinit(alloc);
    }
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expectEqual(@as(usize, 2), resp.headers.items.len);
    try std.testing.expectEqualStrings("X-Custom", resp.headers.items[0]);
    try std.testing.expectEqualStrings("yes", resp.headers.items[1]);
}

test "js engine ponder.http handler 异常返回 500" {
    const alloc = std.testing.allocator;
    var engine = try JsEngine.init(alloc, undefined);
    defer engine.deinit();

    try engine.evalScript(
        \\ponder.http.get("/boom", function(c) { throw new Error("kaboom"); });
    , "routes.js");

    var resp = engine.handleHttpRequest(.get, "/boom", "", "").?;
    defer {
        alloc.free(resp.body);
        for (resp.headers.items) |h| alloc.free(h);
        resp.headers.deinit(alloc);
    }
    try std.testing.expectEqual(@as(u16, 500), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "kaboom") != null);
}
