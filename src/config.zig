const std = @import("std");
const log = @import("log.zig");

pub const EventFilter = struct {
    event: []const u8,
    field: []const u8,
    op: []const u8,
    value: []const u8,

    fn deinit(self: *const EventFilter, alloc: std.mem.Allocator) void {
        alloc.free(self.event);
        alloc.free(self.field);
        alloc.free(self.op);
        alloc.free(self.value);
    }
};

pub const ContractConfig = struct {
    name: []const u8,
    address: []const u8,
    abi_path: []const u8,
    events: []const []const u8,
    from_block: u64,
    start_block: ?u64,
    poll_interval_ms: ?u32,
    max_reorg_depth: ?u32,
    block_batch_size: ?u32,
    filters: []const EventFilter,

    fn deinit(self: *const ContractConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.address);
        alloc.free(self.abi_path);
        for (self.events) |e| alloc.free(e);
        alloc.free(self.events);
        for (self.filters) |*f| f.deinit(alloc);
        alloc.free(self.filters);
    }
};

pub const GlobalConfig = struct {
    log_level: []const u8,
    log_file: []const u8,
    snapshot_interval: u64,
    etherscan_api_key: []const u8,
    chain: []const u8,            // "ethereum" | "bsc" | "polygon"
    track_blocks: bool,
};

pub const IndexerConfig = struct {
    contracts: []const ContractConfig,
    block_batch_size: u32,
    max_pending_blocks: u32,
    reorg_safe_depth: u32,
};

pub const RpcConfig = struct {
    url: []const u8,
    urls: []const []const u8 = &.{},
    /// Optional WebSocket URL for tip-phase eth_subscribe (ws:// or wss://).
    ws_url: ?[]const u8 = null,
    /// Optional WS failover URLs (same style as `urls`).
    ws_urls: []const []const u8 = &.{},
    retry_count: u32,
    retry_delay_ms: u32,
    request_timeout_ms: u32,
    max_concurrent: u32,
};

pub const HttpConfig = struct {
    host: []const u8,
    port: u16,
    read_timeout_ms: u32,
    write_timeout_ms: u32,
    max_body_size: u32,
    cors_origins: []const []const u8,
    rate_limit_rps: ?u32,
    rate_limit_burst: ?u32,
};

pub const GraphQLConfig = struct {
    enabled: bool,
    host: []const u8,
    port: u16,
    enable_playground: bool,
    max_query_depth: u32,
    max_query_complexity: u32,
    rate_limit_rps: ?u32,
    rate_limit_burst: ?u32,
};

pub const DatabaseConfig = struct {
    db_type: []const u8,
    db_name: []const u8,
    wal_mode: bool,
    busy_timeout_ms: u32,
    max_connections: u32,
};

pub const WidgetConfig = struct {
    id: []const u8,
    title: []const u8,
    widget_type: []const u8,  // "stats" | "table" | "count" | "list"
    endpoint: []const u8,
    refresh: u32,
    columns: []const []const u8,

    fn deinit(self: *const WidgetConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.widget_type);
        alloc.free(self.endpoint);
        for (self.columns) |c| alloc.free(c);
        alloc.free(self.columns);
    }
};

pub const DashboardConfig = struct {
    name: []const u8,
    title: []const u8,
    widgets: []WidgetConfig,

    fn deinit(self: *const DashboardConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.title);
        for (self.widgets) |*w| w.deinit(alloc);
        alloc.free(self.widgets);
    }
};

pub const FactoryConfig = struct {
    name: []const u8,
    address: []const u8,
    abi_path: []const u8,
    creation_event: []const u8,
    child_address_field: []const u8,
    child_abi_path: []const u8,
    child_events: []const []const u8,
    max_children: u64,
    child_poll_interval_ms: ?u32,
    child_batch_size: ?u32,
    template_name: []const u8,

    fn deinit(self: *const FactoryConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.address);
        alloc.free(self.abi_path);
        alloc.free(self.creation_event);
        alloc.free(self.child_address_field);
        alloc.free(self.child_abi_path);
        for (self.child_events) |e| alloc.free(e);
        alloc.free(self.child_events);
        alloc.free(self.template_name);
    }
};

pub const TemplateConfig = struct {
    name: []const u8,
    abi_path: []const u8,
    events: []const []const u8,
    factory_name: []const u8,
    discovery_event: []const u8,
    discovery_address_field: []const u8,
    from_block: u64,
    poll_interval_ms: ?u32,
    block_batch_size: ?u32,
    /// 主 sweep 单次 `eth_getLogs` 携带的最大 clone 地址数（null = 运行期默认值，
    /// 见 `Indexer.setMaxAddressesPerRequest`）。地址数达数千时必须分块，
    /// 否则一次请求必然超 RPC 上限。
    max_addresses_per_request: ?u32,

    fn deinit(self: *const TemplateConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.abi_path);
        for (self.events) |e| alloc.free(e);
        alloc.free(self.events);
        alloc.free(self.factory_name);
        alloc.free(self.discovery_event);
        alloc.free(self.discovery_address_field);
    }
};

pub const QueryParam = struct {
    name: []const u8,
    param_type: []const u8,
    default_value: []const u8,

    fn deinit(self: *const QueryParam, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.param_type);
        alloc.free(self.default_value);
    }
};

pub const QueryConfig = struct {
    name: []const u8,
    path: []const u8,
    sql: []const u8,
    params: []const QueryParam,
    cache_ttl_blocks: u64,

    fn deinit(self: *const QueryConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.sql);
        for (self.params) |*p| p.deinit(alloc);
        alloc.free(self.params);
    }
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    global: GlobalConfig,
    rpc: RpcConfig,
    http: HttpConfig,
    graphql: GraphQLConfig,
    database: DatabaseConfig,
    contracts: []const ContractConfig,
    queries: []const QueryConfig,
    dashboards: []const DashboardConfig,
    factories: []const FactoryConfig,
    templates: []const TemplateConfig,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.global.log_level);
        alloc.free(self.global.log_file);
        alloc.free(self.global.etherscan_api_key);
        alloc.free(self.global.chain);
        alloc.free(self.rpc.url);
        if (self.rpc.urls.len > 0) {
            for (self.rpc.urls) |u| alloc.free(u);
            alloc.free(self.rpc.urls);
        }
        if (self.rpc.ws_url) |wu| alloc.free(wu);
        if (self.rpc.ws_urls.len > 0) {
            for (self.rpc.ws_urls) |u| alloc.free(u);
            alloc.free(self.rpc.ws_urls);
        }
        alloc.free(self.http.host);
        if (self.http.cors_origins.len > 0) {
            for (self.http.cors_origins) |o| alloc.free(o);
            alloc.free(self.http.cors_origins);
        }
        alloc.free(self.graphql.host);
        alloc.free(self.database.db_type);
        alloc.free(self.database.db_name);
        for (self.contracts) |*c| c.deinit(alloc);
        alloc.free(self.contracts);
        for (self.queries) |*q| q.deinit(alloc);
        alloc.free(self.queries);
        for (self.dashboards) |*d| d.deinit(alloc);
        alloc.free(self.dashboards);
        for (self.factories) |*f| f.deinit(alloc);
        alloc.free(self.factories);
        for (self.templates) |*t| t.deinit(alloc);
        alloc.free(self.templates);
    }
};

/// 去掉首尾空白。'\r' 也算空白：CRLF 配置里它会留在行尾，
/// 让 `[[contracts]]\r` 匹配不上节头、`"127.0.0.1"\r` 匹配不上引号。
fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

/// 剥离 TOML 行内注释：只有字符串之外的 `#` 才是注释起点。
/// 不区分引号会把 `host = "a#b"` 截成 `"a`，也会误删 `"""..."""` 多行字符串
/// （本项目 sql 值常用该写法）里的 `#`。
fn stripInlineComment(s: []const u8) []const u8 {
    var i: usize = 0;
    var in_string = false;
    var in_triple = false;
    while (i < s.len) {
        const c = s[i];
        if (in_triple) {
            if (c == '\\') {
                i += 2;
            } else if (c == '"' and i + 2 < s.len and s[i + 1] == '"' and s[i + 2] == '"') {
                in_triple = false;
                i += 3;
            } else {
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '#') return trim(s[0..i]);
        if (c == '"') {
            if (i + 2 < s.len and s[i + 1] == '"' and s[i + 2] == '"') {
                in_triple = true;
                i += 3;
                continue;
            }
            in_string = true;
        }
        i += 1;
    }
    return trim(s);
}

fn parseU64(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, stripInlineComment(s), 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, stripInlineComment(s), 10);
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, stripInlineComment(s), 10);
}

fn isWsScheme(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "ws://") or std.mem.startsWith(u8, url, "wss://");
}

fn parseBool(s: []const u8) bool {
    const t = stripInlineComment(s);
    return std.mem.eql(u8, t, "true");
}

/// 解析 TOML 字符串值，支持转义序列（\" \\ \n \t \r）
fn unquote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const t = trim(s);
    // 多行字符串 """..."""
    if (t.len >= 6 and std.mem.startsWith(u8, t, "\"\"\"") and std.mem.endsWith(u8, t, "\"\"\"")) {
        return try alloc.dupe(u8, t[3 .. t.len - 3]);
    }
    // 普通引号字符串 "..."
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') {
        const inner = t[1 .. t.len - 1];
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(alloc);
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                switch (inner[i + 1]) {
                    '"' => try result.append(alloc, '"'),
                    '\\' => try result.append(alloc, '\\'),
                    'n' => try result.append(alloc, '\n'),
                    't' => try result.append(alloc, '\t'),
                    'r' => try result.append(alloc, '\r'),
                    else => {
                        try result.append(alloc, '\\');
                        try result.append(alloc, inner[i + 1]);
                    },
                }
                i += 2;
            } else {
                try result.append(alloc, inner[i]);
                i += 1;
            }
        }
        return try result.toOwnedSlice(alloc);
    }
    return try alloc.dupe(u8, t);
}

fn splitKeyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = trim(line[0..eq]), .value = trim(line[eq + 1 ..]) };
}

/// 数组字面量的括号必须成对。解析器按行读取，多行数组（`events = [` 换行续写）
/// 一律解析不出来——此前的后果是静默退化成单个字面量（`events = ["Transfer"`
/// 会变成一个叫 `["Transfer"` 的事件名，永远匹配不到任何日志），所以直接报错。
fn checkArraySyntax(value: []const u8) !void {
    const t = trim(value);
    if (t.len == 0) return;
    if ((t[0] == '[') != (t[t.len - 1] == ']')) return error.InvalidArraySyntax;
}

fn parseEvents(alloc: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    try checkArraySyntax(value);
    const t = trim(value);
    if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
        const inner = t[1 .. t.len - 1];
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| alloc.free(item);
            list.deinit(alloc);
        }
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const name = trim(part);
            if (name.len == 0) continue;
            try list.append(alloc, try unquote(alloc, name));
        }
        return list.toOwnedSlice(alloc);
    }
    const single = try unquote(alloc, t);
    const arr = try alloc.alloc([]const u8, 1);
    arr[0] = single;
    return arr;
}

fn parseFilters(alloc: std.mem.Allocator, value: []const u8) ![]const EventFilter {
    try checkArraySyntax(value);
    const t = trim(value);
    if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
        const inner = t[1 .. t.len - 1];
        var list: std.ArrayList(EventFilter) = .empty;
        errdefer {
            for (list.items) |f| {
                alloc.free(f.event);
                alloc.free(f.field);
                alloc.free(f.op);
                alloc.free(f.value);
            }
            list.deinit(alloc);
        }
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const item = trim(part);
            if (item.len == 0) continue;
            const unquoted = try unquote(alloc, item);
            defer alloc.free(unquoted);
            var fit = std.mem.splitScalar(u8, unquoted, ':');
            const evt = fit.next() orelse continue;
            const field = fit.next() orelse continue;
            const op = fit.next() orelse continue;
            const val = fit.next() orelse continue;
            try list.append(alloc, .{
                .event = try alloc.dupe(u8, evt),
                .field = try alloc.dupe(u8, field),
                .op = try alloc.dupe(u8, op),
                .value = try alloc.dupe(u8, val),
            });
        }
        return list.toOwnedSlice(alloc);
    }
    return &.{};
}

fn parseQueryParams(alloc: std.mem.Allocator, value: []const u8) ![]const QueryParam {
    try checkArraySyntax(value);
    const t = trim(value);
    if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
        const inner = t[1 .. t.len - 1];
        var list: std.ArrayList(QueryParam) = .empty;
        errdefer {
            for (list.items) |p| {
                alloc.free(p.name);
                alloc.free(p.param_type);
                alloc.free(p.default_value);
            }
            list.deinit(alloc);
        }
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const item = trim(part);
            if (item.len == 0) continue;
            const unquoted = try unquote(alloc, item);
            defer alloc.free(unquoted);
            var pit = std.mem.splitScalar(u8, unquoted, ':');
            const param_name = pit.next() orelse continue;
            const param_type = pit.next() orelse continue;
            const param_default = pit.next() orelse "";
            try list.append(alloc, .{
                .name = try alloc.dupe(u8, param_name),
                .param_type = try alloc.dupe(u8, param_type),
                .default_value = try alloc.dupe(u8, param_default),
            });
        }
        return list.toOwnedSlice(alloc);
    }
    return &.{};
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, config_path: []const u8) !Config {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(1024 * 1024));
    defer alloc.free(content);
    var cfg = try loadFromString(alloc, content);
    // validate 失败时释放已解析的 cfg（此前 InvalidConfig 路径泄漏所有字段）
    errdefer cfg.deinit(alloc);
    try validate(&cfg);
    return cfg;
}

/// 从字符串加载配置（用于测试）
pub fn loadFromString(alloc: std.mem.Allocator, content: []const u8) !Config {
    var global = GlobalConfig{
        .log_level = try alloc.dupe(u8, "info"),
        .log_file = try alloc.dupe(u8, ""),
        .snapshot_interval = 0,
        .etherscan_api_key = try alloc.dupe(u8, ""),
        .chain = try alloc.dupe(u8, "ethereum"),
        .track_blocks = false,
    };
    errdefer {
        alloc.free(global.log_level);
        alloc.free(global.log_file);
        alloc.free(global.etherscan_api_key);
        alloc.free(global.chain);
    }
    var rpc = RpcConfig{
        .url = try alloc.dupe(u8, ""),
        .retry_count = 3,
        .retry_delay_ms = 1000,
        .request_timeout_ms = 10000,
        .max_concurrent = 10,
    };
    errdefer alloc.free(rpc.url);
    var http = HttpConfig{
        .host = try alloc.dupe(u8, "0.0.0.0"),
        .port = 8080,
        .read_timeout_ms = 30000,
        .write_timeout_ms = 30000,
        .max_body_size = 1024 * 1024,
        .cors_origins = &.{},
        .rate_limit_rps = null,
        .rate_limit_burst = null,
    };
    errdefer alloc.free(http.host);
    var graphql = GraphQLConfig{
        .enabled = false,
        .host = try alloc.dupe(u8, "0.0.0.0"),
        .port = 8081,
        .enable_playground = false,
        .max_query_depth = 20,
        .max_query_complexity = 1000,
        .rate_limit_rps = null,
        .rate_limit_burst = null,
    };
    errdefer alloc.free(graphql.host);
    var database = DatabaseConfig{
        .db_type = try alloc.dupe(u8, "sqlite"),
        .db_name = try alloc.dupe(u8, "eth_indexer.db"),
        .wal_mode = true,
        .busy_timeout_ms = 5000,
        .max_connections = 10,
    };
    errdefer {
        alloc.free(database.db_type);
        alloc.free(database.db_name);
    }

    var contracts: std.ArrayList(ContractConfig) = .empty;
    errdefer {
        for (contracts.items) |*c| c.deinit(alloc);
        contracts.deinit(alloc);
    }

    var queries: std.ArrayList(QueryConfig) = .empty;
    errdefer {
        for (queries.items) |*q| q.deinit(alloc);
        queries.deinit(alloc);
    }

    var dashboards: std.ArrayList(DashboardConfig) = .empty;
    errdefer {
        for (dashboards.items) |*d| d.deinit(alloc);
        dashboards.deinit(alloc);
    }

    var factories: std.ArrayList(FactoryConfig) = .empty;
    errdefer {
        for (factories.items) |*f| f.deinit(alloc);
        factories.deinit(alloc);
    }

    var templates: std.ArrayList(TemplateConfig) = .empty;
    errdefer {
        for (templates.items) |*t| t.deinit(alloc);
        templates.deinit(alloc);
    }

    const Section = enum {
        none,
        global,
        rpc,
        database,
        http,
        graphql,
        contracts,
        queries,
        dashboards,
        dashboard_widgets,
        factories,
        templates,
    };
    var section: Section = .none;
    var current_contract: ?ContractConfig = null;
    var current_query: ?QueryConfig = null;
    var current_dashboard: ?DashboardConfig = null;
    var current_widget: ?WidgetConfig = null;
    var current_widgets: std.ArrayList(WidgetConfig) = .empty;
    var current_factory: ?FactoryConfig = null;
    var current_template: ?TemplateConfig = null;

    // 解析中途出错（数字非法、数组括号不配对……）时，"正在拼装"的这一节还没被
    // append 进上面的列表，任何 errdefer 都够不着它——此前会整份泄漏。
    // 释放时要**先元素、后容器**：current_widgets 里的元素归它自己，不在容器里。
    errdefer {
        if (current_contract) |*cc| cc.deinit(alloc);
        if (current_query) |*cq| cq.deinit(alloc);
        if (current_factory) |*cf| cf.deinit(alloc);
        if (current_template) |*ct| ct.deinit(alloc);
        if (current_widget) |*cw| cw.deinit(alloc);
        for (current_widgets.items) |*cw| cw.deinit(alloc);
        current_widgets.deinit(alloc);
        if (current_dashboard) |*cd| cd.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        // 行内注释必须在这里就剥掉：否则 `host = "127.0.0.1" # 反代` 会把注释并进
        // 值里（引号配对失败 → 整串当字面量），`[[contracts]] # 注释` 更是连节头
        // 都识别不出来——后面的键值会被静默归到上一个节。
        const line = stripInlineComment(line_raw);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]")) {
            // 保存之前的合约/查询/dashboard/factory/template
            if (current_factory) |cf| {
                try factories.append(alloc, cf);
                current_factory = null;
            }
            if (current_template) |ct| {
                try templates.append(alloc, ct);
                current_template = null;
            }
            if (current_contract) |cc| {
                try contracts.append(alloc, cc);
                current_contract = null;
            }
            if (current_query) |cq| {
                try queries.append(alloc, cq);
                current_query = null;
            }
            if (current_widget) |cw| {
                try current_widgets.append(alloc, cw);
                current_widget = null;
            }
            // 处理 [[section]] 和 [section] 两种格式
            var section_name = line[1 .. line.len - 1];
            if (std.mem.startsWith(u8, section_name, "[")) section_name = section_name[1..];
            if (std.mem.endsWith(u8, section_name, "]")) section_name = section_name[0 .. section_name.len - 1];

            // dashboard.widgets 是 dashboards 的子节，不 flush 父级
            const is_dashboard_widget = std.mem.eql(u8, section_name, "dashboards.widgets");

            if (!is_dashboard_widget) {
                if (current_dashboard) |*cd| {
                    cd.widgets = try current_widgets.toOwnedSlice(alloc);
                    try dashboards.append(alloc, cd.*);
                    current_dashboard = null;
                    current_widgets = .empty;
                }
            }

            if (std.mem.eql(u8, section_name, "global")) {
                section = .global;
            } else if (std.mem.eql(u8, section_name, "rpc")) {
                section = .rpc;
            } else if (std.mem.eql(u8, section_name, "database")) {
                section = .database;
            } else if (std.mem.eql(u8, section_name, "http")) {
                section = .http;
            } else if (std.mem.eql(u8, section_name, "graphql")) {
                section = .graphql;
            } else if (std.mem.eql(u8, section_name, "contracts")) {
                section = .contracts;
                current_contract = ContractConfig{
                    .name = try alloc.dupe(u8, ""),
                    .address = try alloc.dupe(u8, ""),
                    .abi_path = try alloc.dupe(u8, ""),
                    .events = try alloc.alloc([]const u8, 0),
                    .from_block = 0,
                    .start_block = null,
                    .poll_interval_ms = null,
                    .max_reorg_depth = null,
                    .block_batch_size = null,
                    .filters = &.{},
                };
            } else if (std.mem.eql(u8, section_name, "queries")) {
                section = .queries;
                current_query = QueryConfig{
                    .name = try alloc.dupe(u8, ""),
                    .path = try alloc.dupe(u8, ""),
                    .sql = try alloc.dupe(u8, ""),
                    .params = &.{},
                    .cache_ttl_blocks = 0,
                };
            } else if (std.mem.eql(u8, section_name, "dashboards")) {
                section = .dashboards;
                current_dashboard = DashboardConfig{
                    .name = try alloc.dupe(u8, ""),
                    .title = try alloc.dupe(u8, ""),
                    .widgets = &.{},
                };
            } else if (std.mem.eql(u8, section_name, "dashboards.widgets")) {
                section = .dashboard_widgets;
                current_widget = WidgetConfig{
                    .id = try alloc.dupe(u8, ""),
                    .title = try alloc.dupe(u8, ""),
                    .widget_type = try alloc.dupe(u8, "stats"),
                    .endpoint = try alloc.dupe(u8, ""),
                    .refresh = 30,
                    .columns = &.{},
                };
            } else if (std.mem.eql(u8, section_name, "factories")) {
                section = .factories;
                current_factory = FactoryConfig{
                    .name = try alloc.dupe(u8, ""),
                    .address = try alloc.dupe(u8, ""),
                    .abi_path = try alloc.dupe(u8, ""),
                    .creation_event = try alloc.dupe(u8, ""),
                    .child_address_field = try alloc.dupe(u8, ""),
                    .child_abi_path = try alloc.dupe(u8, ""),
                    .child_events = try alloc.alloc([]const u8, 0),
                    .max_children = 1000,
                    .child_poll_interval_ms = null,
                    .child_batch_size = null,
                    .template_name = try alloc.dupe(u8, ""),
                };
            } else if (std.mem.eql(u8, section_name, "templates")) {
                section = .templates;
                current_template = TemplateConfig{
                    .name = try alloc.dupe(u8, ""),
                    .abi_path = try alloc.dupe(u8, ""),
                    .events = try alloc.alloc([]const u8, 0),
                    .factory_name = try alloc.dupe(u8, ""),
                    .discovery_event = try alloc.dupe(u8, ""),
                    .discovery_address_field = try alloc.dupe(u8, ""),
                    .from_block = 0,
                    .poll_interval_ms = null,
                    .block_batch_size = null,
                    .max_addresses_per_request = null,
                };
            } else {
                section = .none;
            }
            continue;
        }

        const kv = splitKeyValue(line) orelse continue;
        const key = kv.key;
        const value = kv.value;

        if (current_factory) |*cf| {
            if (std.mem.eql(u8, key, "name")) {
                if (cf.name.len > 0) alloc.free(cf.name);
                cf.name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "address")) {
                if (cf.address.len > 0) alloc.free(cf.address);
                cf.address = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "abi_path")) {
                if (cf.abi_path.len > 0) alloc.free(cf.abi_path);
                cf.abi_path = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "creation_event")) {
                if (cf.creation_event.len > 0) alloc.free(cf.creation_event);
                cf.creation_event = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "child_address_field")) {
                if (cf.child_address_field.len > 0) alloc.free(cf.child_address_field);
                cf.child_address_field = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "child_abi_path")) {
                if (cf.child_abi_path.len > 0) alloc.free(cf.child_abi_path);
                cf.child_abi_path = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "child_events")) {
                cf.child_events = try parseEvents(alloc, value);
            } else if (std.mem.eql(u8, key, "max_children")) {
                cf.max_children = try parseU64(value);
            } else if (std.mem.eql(u8, key, "child_poll_interval_ms")) {
                cf.child_poll_interval_ms = try parseU32(value);
            } else if (std.mem.eql(u8, key, "child_batch_size")) {
                cf.child_batch_size = try parseU32(value);
            } else if (std.mem.eql(u8, key, "template_name")) {
                if (cf.template_name.len > 0) alloc.free(cf.template_name);
                cf.template_name = try unquote(alloc, value);
            }
            continue;
        }

        if (current_template) |*ct| {
            if (std.mem.eql(u8, key, "name")) {
                if (ct.name.len > 0) alloc.free(ct.name);
                ct.name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "abi_path")) {
                if (ct.abi_path.len > 0) alloc.free(ct.abi_path);
                ct.abi_path = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "events")) {
                ct.events = try parseEvents(alloc, value);
            } else if (std.mem.eql(u8, key, "factory_name")) {
                if (ct.factory_name.len > 0) alloc.free(ct.factory_name);
                ct.factory_name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "discovery_event")) {
                if (ct.discovery_event.len > 0) alloc.free(ct.discovery_event);
                ct.discovery_event = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "discovery_address_field")) {
                if (ct.discovery_address_field.len > 0) alloc.free(ct.discovery_address_field);
                ct.discovery_address_field = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "from_block")) {
                ct.from_block = try parseU64(value);
            } else if (std.mem.eql(u8, key, "poll_interval_ms")) {
                ct.poll_interval_ms = try parseU32(value);
            } else if (std.mem.eql(u8, key, "block_batch_size")) {
                ct.block_batch_size = try parseU32(value);
            } else if (std.mem.eql(u8, key, "max_addresses_per_request")) {
                ct.max_addresses_per_request = try parseU32(value);
            }
            continue;
        }

        if (current_contract) |*cc| {
            if (std.mem.eql(u8, key, "name")) {
                if (cc.name.len > 0) alloc.free(cc.name);
                cc.name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "address")) {
                if (cc.address.len > 0) alloc.free(cc.address);
                cc.address = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "abi_path")) {
                if (cc.abi_path.len > 0) alloc.free(cc.abi_path);
                cc.abi_path = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "from_block")) {
                cc.from_block = try parseU64(value);
            } else if (std.mem.eql(u8, key, "events")) {
                cc.events = try parseEvents(alloc, value);
            } else if (std.mem.eql(u8, key, "filters")) {
                cc.filters = try parseFilters(alloc, value);
            } else if (std.mem.eql(u8, key, "poll_interval_ms")) {
                cc.poll_interval_ms = try parseU32(value);
            } else if (std.mem.eql(u8, key, "max_reorg_depth")) {
                cc.max_reorg_depth = try parseU32(value);
            } else if (std.mem.eql(u8, key, "block_batch_size")) {
                cc.block_batch_size = try parseU32(value);
            }
            continue;
        }

        if (current_query) |*cq| {
            if (std.mem.eql(u8, key, "name")) {
                if (cq.name.len > 0) alloc.free(cq.name);
                cq.name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "path")) {
                if (cq.path.len > 0) alloc.free(cq.path);
                cq.path = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "sql")) {
                if (cq.sql.len > 0) alloc.free(cq.sql);
                cq.sql = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "params")) {
                cq.params = try parseQueryParams(alloc, value);
            } else if (std.mem.eql(u8, key, "cache_ttl_blocks")) {
                cq.cache_ttl_blocks = try parseU64(value);
            }
            continue;
        }

        // Widget checking before Dashboard (both have "title" field)
        if (current_widget) |*cw| {
            if (std.mem.eql(u8, key, "id")) {
                if (cw.id.len > 0) alloc.free(cw.id);
                cw.id = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "title")) {
                if (cw.title.len > 0) alloc.free(cw.title);
                cw.title = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "type")) {
                if (cw.widget_type.len > 0) alloc.free(cw.widget_type);
                cw.widget_type = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "endpoint")) {
                if (cw.endpoint.len > 0) alloc.free(cw.endpoint);
                cw.endpoint = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "refresh")) {
                cw.refresh = try parseU32(value);
            } else if (std.mem.eql(u8, key, "columns")) {
                cw.columns = try parseEvents(alloc, value);
            }
            continue;
        }

        if (current_dashboard) |*cd| {
            if (std.mem.eql(u8, key, "name")) {
                if (cd.name.len > 0) alloc.free(cd.name);
                cd.name = try unquote(alloc, value);
            } else if (std.mem.eql(u8, key, "title")) {
                if (cd.title.len > 0) alloc.free(cd.title);
                cd.title = try unquote(alloc, value);
            }
            continue;
        }

        switch (section) {
            .global => {
                if (std.mem.eql(u8, key, "log_level")) {
                    alloc.free(global.log_level);
                    global.log_level = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "log_file")) {
                    alloc.free(global.log_file);
                    global.log_file = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "snapshot_interval")) {
                    global.snapshot_interval = try parseU64(value);
                } else if (std.mem.eql(u8, key, "etherscan_api_key")) {
                    alloc.free(global.etherscan_api_key);
                    global.etherscan_api_key = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "chain")) {
                    alloc.free(global.chain);
                    global.chain = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "track_blocks")) {
                    global.track_blocks = parseBool(value);
                }
            },
            .rpc => {
                if (std.mem.eql(u8, key, "url")) {
                    alloc.free(rpc.url);
                    rpc.url = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "urls")) {
                    rpc.urls = try parseEvents(alloc, value);
                } else if (std.mem.eql(u8, key, "ws_url")) {
                    if (rpc.ws_url) |wu| alloc.free(wu);
                    rpc.ws_url = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "ws_urls")) {
                    if (rpc.ws_urls.len > 0) {
                        for (rpc.ws_urls) |u| alloc.free(u);
                        alloc.free(rpc.ws_urls);
                    }
                    rpc.ws_urls = try parseEvents(alloc, value);
                } else if (std.mem.eql(u8, key, "timeout")) {
                    rpc.request_timeout_ms = try parseU32(value);
                } else if (std.mem.eql(u8, key, "retry_count")) {
                    rpc.retry_count = try parseU32(value);
                } else if (std.mem.eql(u8, key, "retry_delay_ms")) {
                    rpc.retry_delay_ms = try parseU32(value);
                } else if (std.mem.eql(u8, key, "max_concurrent")) {
                    rpc.max_concurrent = try parseU32(value);
                }
            },
            .database => {
                if (std.mem.eql(u8, key, "type")) {
                    alloc.free(database.db_type);
                    database.db_type = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "db_name")) {
                    alloc.free(database.db_name);
                    database.db_name = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "max_connections")) {
                    database.max_connections = try parseU32(value);
                } else if (std.mem.eql(u8, key, "wal_mode")) {
                    database.wal_mode = parseBool(value);
                } else if (std.mem.eql(u8, key, "busy_timeout_ms")) {
                    database.busy_timeout_ms = try parseU32(value);
                }
            },
            .http => {
                if (std.mem.eql(u8, key, "port")) {
                    http.port = try parseU16(value);
                } else if (std.mem.eql(u8, key, "host")) {
                    alloc.free(http.host);
                    http.host = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "cors")) {
                    if (parseBool(value)) {
                        if (http.cors_origins.len > 0) {
                            for (http.cors_origins) |o| alloc.free(o);
                            alloc.free(http.cors_origins);
                        }
                        // 必须 dupe 内容：deinit 会对每个元素 alloc.free，
                        // 若直接放字面量 "*" 会 free 静态内存 → Bus error
                        const star = try alloc.dupe(u8, "*");
                        http.cors_origins = try alloc.dupe([]const u8, &[_][]const u8{star});
                    }
                } else if (std.mem.eql(u8, key, "cors_origins")) {
                    if (http.cors_origins.len > 0) {
                        for (http.cors_origins) |o| alloc.free(o);
                        alloc.free(http.cors_origins);
                    }
                    http.cors_origins = try parseEvents(alloc, value);
                } else if (std.mem.eql(u8, key, "read_timeout_ms")) {
                    http.read_timeout_ms = try parseU32(value);
                } else if (std.mem.eql(u8, key, "write_timeout_ms")) {
                    http.write_timeout_ms = try parseU32(value);
                } else if (std.mem.eql(u8, key, "max_body_size")) {
                    http.max_body_size = try parseU32(value);
                } else if (std.mem.eql(u8, key, "rate_limit_rps")) {
                    http.rate_limit_rps = try parseU32(value);
                } else if (std.mem.eql(u8, key, "rate_limit_burst")) {
                    http.rate_limit_burst = try parseU32(value);
                }
            },
            .graphql => {
                if (std.mem.eql(u8, key, "enabled")) {
                    graphql.enabled = parseBool(value);
                } else if (std.mem.eql(u8, key, "port")) {
                    graphql.port = try parseU16(value);
                } else if (std.mem.eql(u8, key, "host")) {
                    alloc.free(graphql.host);
                    graphql.host = try unquote(alloc, value);
                } else if (std.mem.eql(u8, key, "enable_playground")) {
                    graphql.enable_playground = parseBool(value);
                } else if (std.mem.eql(u8, key, "max_query_depth")) {
                    graphql.max_query_depth = try parseU32(value);
                } else if (std.mem.eql(u8, key, "max_query_complexity")) {
                    graphql.max_query_complexity = try parseU32(value);
                } else if (std.mem.eql(u8, key, "rate_limit_rps")) {
                    graphql.rate_limit_rps = try parseU32(value);
                } else if (std.mem.eql(u8, key, "rate_limit_burst")) {
                    graphql.rate_limit_burst = try parseU32(value);
                }
            },
            else => {},
        }
    }

    if (current_factory) |cf| {
        try factories.append(alloc, cf);
    }
    if (current_template) |ct| {
        try templates.append(alloc, ct);
    }
    if (current_contract) |cc| {
        try contracts.append(alloc, cc);
    }
    if (current_query) |cq| {
        try queries.append(alloc, cq);
    }
    if (current_widget) |cw| {
        try current_widgets.append(alloc, cw);
    }
    if (current_dashboard) |*cd| {
        cd.widgets = try current_widgets.toOwnedSlice(alloc);
        try dashboards.append(alloc, cd.*);
    }

    var final_contracts = try alloc.alloc(ContractConfig, contracts.items.len);
    for (contracts.items, 0..) |c, i| {
        final_contracts[i] = c;
    }
    contracts.deinit(alloc);

    var final_queries = try alloc.alloc(QueryConfig, queries.items.len);
    for (queries.items, 0..) |q, i| {
        final_queries[i] = q;
    }
    queries.deinit(alloc);

    var final_dashboards = try alloc.alloc(DashboardConfig, dashboards.items.len);
    for (dashboards.items, 0..) |d, i| {
        final_dashboards[i] = d;
    }
    dashboards.deinit(alloc);

    var final_factories = try alloc.alloc(FactoryConfig, factories.items.len);
    for (factories.items, 0..) |f, i| {
        final_factories[i] = f;
    }
    factories.deinit(alloc);

    var final_templates = try alloc.alloc(TemplateConfig, templates.items.len);
    for (templates.items, 0..) |t, i| {
        final_templates[i] = t;
    }
    templates.deinit(alloc);

    const cfg = Config{
        .alloc = alloc,
        .global = global,
        .rpc = rpc,
        .http = http,
        .graphql = graphql,
        .database = database,
        .contracts = final_contracts,
        .queries = final_queries,
        .dashboards = final_dashboards,
        .factories = final_factories,
        .templates = final_templates,
    };

    return cfg;
}

/// 实体闸门：至少一个 [[contracts]] / [[factories]] / [[templates]] 才构成可索引配置。
/// 携转约束 3：只配 [[templates]] 的配置此前被误判为"没有任何实体"。
fn hasIndexableEntity(cfg: *const Config) bool {
    return cfg.contracts.len > 0 or cfg.factories.len > 0 or cfg.templates.len > 0;
}

fn hasFactoryNamed(cfg: *const Config, name: []const u8) bool {
    for (cfg.factories) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn hasTemplateNamed(cfg: *const Config, name: []const u8) bool {
    for (cfg.templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

fn findFactoryByName(cfg: *const Config, name: []const u8) ?*const FactoryConfig {
    for (cfg.factories) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// 工厂 address 是否与更早声明的工厂重复（大小写不敏感：`0xAbC` 与 `0xabc` 是同一个
/// 地址，但 main 的"工厂 → 索引器"关联只保留最后一个 factory_idx，先配的工厂会静默
/// 停止发现，其喂入的模板地址集合也随之断流）。
fn hasDuplicateFactoryAddress(cfg: *const Config, index: usize) bool {
    const addr = cfg.factories[index].address;
    if (addr.len == 0) return false;
    for (cfg.factories[0..index]) |prev| {
        if (prev.address.len > 0 and std.ascii.eqlIgnoreCase(prev.address, addr)) return true;
    }
    return false;
}

pub fn validate(cfg: *const Config) !void {
    var errors: u32 = 0;

    // GraphQL 配置验证
    if (cfg.graphql.enabled) {
        if (cfg.graphql.port == 0) {
            log.err("配置错误: graphql.port 不能为 0", .{});
            errors += 1;
        }
        if (cfg.graphql.host.len == 0) {
            log.err("配置错误: graphql.host 不能为空", .{});
            errors += 1;
        }
    }

    if (cfg.rpc.url.len == 0) {
        log.err("配置错误: rpc.url 不能为空", .{});
        errors += 1;
    }
    if (cfg.rpc.ws_url) |wu| {
        if (!isWsScheme(wu)) {
            log.err("配置错误: rpc.ws_url 必须以 ws:// 或 wss:// 开头", .{});
            errors += 1;
        }
    }
    for (cfg.rpc.ws_urls) |wu| {
        if (!isWsScheme(wu)) {
            log.err("配置错误: rpc.ws_urls 中的 URL 必须以 ws:// 或 wss:// 开头: {s}", .{wu});
            errors += 1;
        }
    }
    if (cfg.database.db_name.len == 0) {
        log.err("配置错误: database.db_name 不能为空", .{});
        errors += 1;
    }
    if (!hasIndexableEntity(cfg)) {
        log.err("配置错误: 必须至少配置一个合约、工厂合约或模板", .{});
        errors += 1;
    }
    for (cfg.contracts) |contract| {
        if (contract.name.len == 0) {
            log.err("配置错误: 合约名不能为空", .{});
            errors += 1;
        }
        if (contract.address.len == 0) {
            log.err("配置错误: 合约 {s} 的 address 不能为空", .{contract.name});
            errors += 1;
        }
        if (contract.abi_path.len == 0 and cfg.global.etherscan_api_key.len == 0) {
            log.err("配置错误: 合约 {s} 缺少 abi_path 且未配置 etherscan_api_key 进行自动获取", .{contract.name});
            errors += 1;
        }
        // events 为空时自动索引 ABI 中所有事件（不再报错）
    }

    for (cfg.queries) |q| {
        if (q.name.len == 0) {
            log.err("配置错误: 查询名不能为空", .{});
            errors += 1;
        }
        if (q.path.len == 0) {
            log.err("配置错误: 查询 {s} 的 path 不能为空", .{q.name});
            errors += 1;
        }
        if (q.sql.len == 0) {
            log.err("配置错误: 查询 {s} 的 sql 不能为空", .{q.name});
            errors += 1;
        }
        // 安全校验：只允许 SELECT 查询
        const sql_upper = trim(q.sql);
        if (!std.ascii.startsWithIgnoreCase(sql_upper, "select")) {
            log.err("配置错误: 查询 {s} 只允许 SELECT 语句", .{q.name});
            errors += 1;
        }
    }

    for (cfg.factories, 0..) |f, fi| {
        if (f.name.len == 0) {
            log.err("配置错误: 工厂合约名不能为空", .{});
            errors += 1;
        }
        if (f.address.len == 0) {
            log.err("配置错误: 工厂合约 {s} 的 address 不能为空", .{f.name});
            errors += 1;
        } else if (hasDuplicateFactoryAddress(cfg, fi)) {
            // 同一工厂声明两次：main 的关联循环按地址匹配且只留最后一个 factory_idx，
            // 先配的那个工厂再也不会被喂事件（发现静默停止）
            log.err("配置错误: 工厂 {s} 的 address {s} 与前面的工厂重复（同一工厂只能声明一次）", .{ f.name, f.address });
            errors += 1;
        }
        if (f.creation_event.len == 0) {
            log.err("配置错误: 工厂合约 {s} 的 creation_event 不能为空", .{f.name});
            errors += 1;
        }
        if (f.child_address_field.len == 0) {
            log.err("配置错误: 工厂合约 {s} 的 child_address_field 不能为空", .{f.name});
            errors += 1;
        }
        if (f.child_abi_path.len > 0 and f.template_name.len > 0) {
            // 携转约束 7：同一发现事件不能既建老 factory 子索引器、又喂模板地址集合
            // （否则同一批 clone 被两套索引器重复索引）
            log.err("配置错误: 工厂合约 {s} 不能同时配置 child_abi_path 与 template_name", .{f.name});
            errors += 1;
        } else if (f.template_name.len > 0) {
            if (!hasTemplateNamed(cfg, f.template_name)) {
                log.err("配置错误: 工厂合约 {s} 的 template_name '{s}' 未在 [[templates]] 中定义", .{ f.name, f.template_name });
                errors += 1;
            }
        } else if (f.child_abi_path.len == 0) {
            // 配了 template_name 时发现路径交给模板，不再要求 child_abi_path
            log.err("配置错误: 工厂合约 {s} 的 child_abi_path 不能为空", .{f.name});
            errors += 1;
        }
        if (f.max_children < 1) {
            log.err("配置错误: 工厂合约 {s} 的 max_children 必须 >= 1", .{f.name});
            errors += 1;
        }
        if (f.max_children > 100000) {
            log.warn("工厂合约 {s} 的 max_children 较大 ({d})，建议限制", .{ f.name, f.max_children });
        }
    }

    for (cfg.templates, 0..) |t, ti| {
        if (t.name.len == 0) {
            log.err("配置错误: 模板名不能为空", .{});
            errors += 1;
        }
        for (cfg.templates[0..ti]) |prev| {
            if (prev.name.len > 0 and std.mem.eql(u8, prev.name, t.name)) {
                // 携转约束 4：name 是分发表 key，重复会静默覆盖
                log.err("配置错误: 模板名 '{s}' 重复", .{t.name});
                errors += 1;
                break;
            }
        }
        if (t.abi_path.len == 0) {
            log.err("配置错误: 模板 {s} 的 abi_path 不能为空", .{t.name});
            errors += 1;
        }
        for (cfg.contracts) |c| {
            // 事件表名是 event_{name}_{event}：模板与合约同名会写进同一张表
            if (std.mem.eql(u8, c.name, t.name)) {
                log.err("配置错误: 模板名 '{s}' 与 [[contracts]] 中的合约名重复（事件表前缀相同）", .{t.name});
                errors += 1;
                break;
            }
        }
        if (t.factory_name.len == 0) {
            log.err("配置错误: 模板 {s} 的 factory_name 不能为空（地址集合由该工厂喂入）", .{t.name});
            errors += 1;
        } else if (!hasFactoryNamed(cfg, t.factory_name)) {
            // 携转约束 5：启动期就报错，不留到运行期
            log.err("配置错误: 模板 {s} 的 factory_name '{s}' 未在 [[factories]] 中定义", .{ t.name, t.factory_name });
            errors += 1;
        } else if (findFactoryByName(cfg, t.factory_name)) |f| {
            // 反向一致性（工厂↔模板必须一对一）：喂地址集合的工厂必须指回本模板。
            // 若它的 template_name 指向别的模板、或根本没配 template_name（走老
            // child_abi_path 路径），本模板的地址集合永远为空 → 空集短路 + 游标照常推进
            // → 进程显示 running 却一个事件都不索引。
            if (!std.mem.eql(u8, f.template_name, t.name)) {
                log.err("配置错误: 模板 {s} 的 factory_name '{s}' 指向的工厂其 template_name 是 '{s}'，未反向指回该模板（工厂↔模板必须一一对应）", .{ t.name, t.factory_name, f.template_name });
                errors += 1;
            }
        }
    }

    if (errors > 0) {
        return error.InvalidConfig;
    }

    log.info("配置验证通过: {d} 个合约, {d} 个工厂, {d} 个模板, {d} 个自定义查询", .{ cfg.contracts.len, cfg.factories.len, cfg.templates.len, cfg.queries.len });
}

// ============================================================================
// 单元测试
// ============================================================================

test "config parse basic" {
        const alloc = std.testing.allocator;
        const toml =
        \\[global]
        \\log_level = "debug"
        \\snapshot_interval = 3600
        \\
        \\[rpc]
        \\url = "https://example.com"
        \\timeout = 5000
        \\retry_count = 5
        \\
        \\[database]
        \\type = "sqlite"
        \\db_name = "test.db"
        \\max_connections = 5
        \\
        \\[http]
        \\port = 9090
        \\host = "127.0.0.1"
        \\
        \\[[contracts]]
        \\name = "dai"
        \\address = "0x6b175474e89094c44da98b954eedeac495271d0f"
        \\abi_path = "./abis/erc20.abi"
        \\from_block = 20000000
        \\events = ["Transfer", "Approval"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try validate(&cfg);

    try std.testing.expectEqualStrings("debug", cfg.global.log_level);
    try std.testing.expectEqual(@as(u64, 3600), cfg.global.snapshot_interval);
    try std.testing.expectEqualStrings("https://example.com", cfg.rpc.url);
    try std.testing.expect(cfg.rpc.ws_url == null);
    try std.testing.expectEqual(@as(u32, 5000), cfg.rpc.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5), cfg.rpc.retry_count);
    try std.testing.expectEqualStrings("test.db", cfg.database.db_name);
    try std.testing.expectEqual(@as(u16, 9090), cfg.http.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.http.host);
    try std.testing.expectEqual(@as(usize, 1), cfg.contracts.len);
    try std.testing.expectEqualStrings("dai", cfg.contracts[0].name);
    try std.testing.expectEqual(@as(u64, 20000000), cfg.contracts[0].from_block);
    try std.testing.expectEqual(@as(usize, 2), cfg.contracts[0].events.len);
    try std.testing.expectEqualStrings("Transfer", cfg.contracts[0].events[0]);
    try std.testing.expectEqualStrings("Approval", cfg.contracts[0].events[1]);
}

test "config parse multiple contracts" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://rpc.example.com"
        \\
        \\[[contracts]]
        \\name = "a"
        \\address = "0x1111111111111111111111111111111111111111"
        \\abi_path = "./a.abi"
        \\from_block = 100
        \\events = ["Evt"]
        \\
        \\[[contracts]]
        \\name = "b"
        \\address = "0x2222222222222222222222222222222222222222"
        \\abi_path = "./b.abi"
        \\from_block = 200
        \\events = ["Evt1", "Evt2"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try validate(&cfg);

    try std.testing.expectEqual(@as(usize, 2), cfg.contracts.len);
    try std.testing.expectEqualStrings("a", cfg.contracts[0].name);
    try std.testing.expectEqualStrings("b", cfg.contracts[1].name);
}

test "config parse ws_url" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://rpc.example.com"
        \\ws_url = "wss://rpc.example.com/ws"
        \\
        \\[[contracts]]
        \\name = "a"
        \\address = "0x1111111111111111111111111111111111111111"
        \\abi_path = "./a.abi"
        \\from_block = 100
        \\events = ["Evt"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try validate(&cfg);
    try std.testing.expectEqualStrings("wss://rpc.example.com/ws", cfg.rpc.ws_url.?);
}

test "config validate rejects invalid ws_url scheme" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://rpc.example.com"
        \\ws_url = "https://rpc.example.com/ws"
        \\
        \\[[contracts]]
        \\name = "a"
        \\address = "0x1111111111111111111111111111111111111111"
        \\abi_path = "./a.abi"
        \\from_block = 100
        \\events = ["Evt"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "config validate rejects empty rpc url" {
    const alloc = std.testing.allocator;
    const toml =
        \\[[contracts]]
        \\name = "x"
        \\address = "0x1111111111111111111111111111111111111111"
        \\abi_path = "./x.abi"
        \\from_block = 0
        \\events = ["E"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);

    alloc.free(cfg.rpc.url);
    cfg.rpc.url = try alloc.dupe(u8, "");
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "config validate rejects no contracts" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://example.com"
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);

    for (cfg.contracts) |c| {
        alloc.free(c.name);
        alloc.free(c.address);
        alloc.free(c.abi_path);
        for (c.events) |e| alloc.free(e);
        alloc.free(c.events);
    }
    alloc.free(cfg.contracts);
    cfg.contracts = try alloc.alloc(ContractConfig, 0);
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "config helper functions" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
    {
        const s = try unquote(alloc, "\"hello\"");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello", s);
    }
    {
        const s = try unquote(alloc, "hello");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello", s);
    }
    {
        const s = try unquote(alloc, "\"say \\\"hi\\\"\"");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("say \"hi\"", s);
    }
    {
        // 多行字符串
        const s = try unquote(alloc, "\"\"\"hello\nworld\"\"\"");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello\nworld", s);
    }
    {
        // 转义序列
        const s = try unquote(alloc, "\"a\\tb\\nc\\rd\\\\e\"");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("a\tb\nc\rd\\e", s);
    }
    try std.testing.expectEqual(@as(u64, 42), try parseU64("42"));
    try std.testing.expectEqual(@as(u32, 100), try parseU32("100"));
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(!parseBool("false"));

    // parseEvents
    {
        const evts = try parseEvents(alloc, "[\"Transfer\", \"Approval\"]");
        defer {
            for (evts) |e| alloc.free(e);
            alloc.free(evts);
        }
        try std.testing.expectEqual(@as(usize, 2), evts.len);
        try std.testing.expectEqualStrings("Transfer", evts[0]);
        try std.testing.expectEqualStrings("Approval", evts[1]);
    }
    {
        const evts = try parseEvents(alloc, "\"Transfer\"");
        defer {
            for (evts) |e| alloc.free(e);
            alloc.free(evts);
        }
        try std.testing.expectEqual(@as(usize, 1), evts.len);
        try std.testing.expectEqualStrings("Transfer", evts[0]);
    }
    {
        const evts = try parseEvents(alloc, "[]");
        defer alloc.free(evts);
        try std.testing.expectEqual(@as(usize, 0), evts.len);
    }

    // parseFilters
    {
        const filters = try parseFilters(alloc, "[\"Transfer:value:gt:500\",\"Approval:value:gt:1000\"]");
        defer {
            for (filters) |f| {
                alloc.free(f.event);
                alloc.free(f.field);
                alloc.free(f.op);
                alloc.free(f.value);
            }
            alloc.free(filters);
        }
        try std.testing.expectEqual(@as(usize, 2), filters.len);
        try std.testing.expectEqualStrings("Transfer", filters[0].event);
        try std.testing.expectEqualStrings("value", filters[0].field);
        try std.testing.expectEqualStrings("gt", filters[0].op);
        try std.testing.expectEqualStrings("500", filters[0].value);
    }
    {
        const filters = try parseFilters(alloc, "[]");
        defer alloc.free(filters);
        try std.testing.expectEqual(@as(usize, 0), filters.len);
    }
}

test "stripInlineComment：字符串之外的 # 才是注释" {
    // 引号外的 # 及其后内容属于注释
    try std.testing.expectEqualStrings("\"127.0.0.1\"", stripInlineComment("  \"127.0.0.1\"   # 只监听本地 "));
    try std.testing.expectEqualStrings("42", stripInlineComment("42 # 注释"));
    try std.testing.expectEqualStrings("true", stripInlineComment("true\t# 开关"));
    try std.testing.expectEqualStrings("", stripInlineComment("   # 整行注释"));
    try std.testing.expectEqualStrings("[[contracts]]", stripInlineComment("[[contracts]] # 合约"));
    // 引号内的 # 是值的一部分
    try std.testing.expectEqualStrings("\"a#b\"", stripInlineComment("\"a#b\""));
    try std.testing.expectEqualStrings("\"a#b\"", stripInlineComment("\"a#b\" # 注释"));
    // 转义引号不结束字符串，其后的 # 仍属值
    try std.testing.expectEqualStrings("\"say \\\"#\\\"\"", stripInlineComment("\"say \\\"#\\\"\" # 注释"));
    // 多行字符串（sql 值常用该写法）整段保留，只有其后的注释被剥掉
    const sql = "sql = \"\"\"SELECT 1 FROM t WHERE n = '#'\"\"\"";
    try std.testing.expectEqualStrings(sql, stripInlineComment(sql));
    try std.testing.expectEqualStrings("sql = \"\"\"SELECT 1\"\"\"", stripInlineComment("sql = \"\"\"SELECT 1\"\"\" # 查询"));
    // CRLF 行尾
    try std.testing.expectEqualStrings("host = \"127.0.0.1\"", stripInlineComment("host = \"127.0.0.1\"\r"));
}

test "config: 未闭合的数组字面量报错而非静默降级" {
    const alloc = std.testing.allocator;

    // 正常形态不受影响
    try checkArraySyntax("\"Transfer\"");
    try checkArraySyntax("[]");
    try checkArraySyntax("[\"Transfer\", \"Approval\"]");
    try checkArraySyntax("[\"A\",]"); // TOML 允许尾逗号
    try checkArraySyntax("[::1]"); // 裸字面量里出现方括号

    // 括号不配对（含多行数组写法）→ 明确报错
    try std.testing.expectError(error.InvalidArraySyntax, checkArraySyntax("[\"Transfer\""));
    try std.testing.expectError(error.InvalidArraySyntax, checkArraySyntax("Transfer]"));
    try std.testing.expectError(error.InvalidArraySyntax, parseEvents(alloc, "[\"Transfer\""));
    try std.testing.expectError(error.InvalidArraySyntax, parseFilters(alloc, "[\"Transfer:value:gt:1\""));
    try std.testing.expectError(error.InvalidArraySyntax, parseQueryParams(alloc, "[\"limit:u32:50\""));

    // 端到端：解析中途报错时，"正在拼装"的那一节 + 已 append 的合约 filters 都必须
    // 被释放（回归：此前 current_* 不在任何 errdefer 管辖内，且 contracts 的 errdefer
    // 漏了 filters）。
    const toml =
        \\[rpc]
        \\url = "https://example.com"
        \\
        \\[[contracts]]
        \\name = "dai"
        \\address = "0x6b175474e89094c44da98b954eedeac495271d0f"
        \\abi_path = "./abis/erc20.abi"
        \\events = ["Transfer"]
        \\filters = ["Transfer:value:gt:1"]
        \\
        \\[[contracts]]
        \\name = "bad"
        \\address = "0x1111111111111111111111111111111111111111"
        \\abi_path = "./b.abi"
        \\events = ["Transfer"
    ;
    try std.testing.expectError(error.InvalidArraySyntax, loadFromString(alloc, toml));
}

test "config: 解析中途出错时 dashboard/widget 也一并释放（回归）" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://example.com"
        \\
        \\[[dashboards]]
        \\name = "d"
        \\title = "面板"
        \\
        \\[[dashboards.widgets]]
        \\id = "w1"
        \\title = "W1"
        \\type = "stats"
        \\endpoint = "/api/a"
        \\columns = ["a"]
        \\
        \\[[dashboards.widgets]]
        \\id = "w2"
        \\title = "W2"
        \\type = "stats"
        \\endpoint = "/api/b"
        \\columns = ["a"
    ;
    // 出错点在第 2 个 widget 内：current_widget（在拼）、current_widgets（已收 1 个）
    // 与 current_dashboard 三者都必须被释放，否则 SafeAllocator 报泄漏
    try std.testing.expectError(error.InvalidArraySyntax, loadFromString(alloc, toml));
}

test "config: 行内注释不污染值（回归：host/数组/bool/节头）" {
    const alloc = std.testing.allocator;
    const toml =
        \\[global] # 全局
        \\log_level = "info" # 日志级别
        \\track_blocks = true # 需要事件时间戳
        \\
        \\[rpc] # RPC
        \\url = "https://example.com" # 主节点
        \\timeout = 5000
        \\
        \\[database]
        \\type = "sqlite"
        \\db_name = "commented#1.db" # 引号内的 # 不是注释
        \\
        \\[http]
        \\port = 9090 # 端口
        \\host = "127.0.0.1" # 只监听本地，前面由 Nginx/Caddy 反代
        \\
        \\[[contracts]] # 合约
        \\name = "dai" # 名字
        \\address = "0x6b175474e89094c44da98b954eedeac495271d0f"
        \\abi_path = "./abis/erc20.abi" # ABI 路径
        \\from_block = 20000000
        \\events = ["Transfer", "Approval"] # 只索引这两个
        \\max_reorg_depth = 20 # 重组深度
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try validate(&cfg);

    try std.testing.expectEqualStrings("info", cfg.global.log_level);
    try std.testing.expect(cfg.global.track_blocks);
    try std.testing.expectEqualStrings("https://example.com", cfg.rpc.url);
    try std.testing.expectEqual(@as(u32, 5000), cfg.rpc.request_timeout_ms);
    try std.testing.expectEqualStrings("commented#1.db", cfg.database.db_name);
    try std.testing.expectEqual(@as(u16, 9090), cfg.http.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.http.host);
    try std.testing.expectEqual(@as(usize, 1), cfg.contracts.len);
    try std.testing.expectEqualStrings("dai", cfg.contracts[0].name);
    try std.testing.expectEqual(@as(u64, 20000000), cfg.contracts[0].from_block);
    try std.testing.expectEqual(@as(?u32, 20), cfg.contracts[0].max_reorg_depth);
    try std.testing.expectEqual(@as(usize, 2), cfg.contracts[0].events.len);
    try std.testing.expectEqualStrings("Transfer", cfg.contracts[0].events[0]);
    try std.testing.expectEqualStrings("Approval", cfg.contracts[0].events[1]);
}

test "config load empty string" {
    const alloc = std.testing.allocator;
    var cfg = try loadFromString(alloc, "");
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), cfg.contracts.len);
    try std.testing.expectEqualStrings("info", cfg.global.log_level);
}

test "config parse queries" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://example.com"
        \\
        \\[[queries]]
        \\name = "top_transfers"
        \\path = "/queries/top_transfers"
        \\sql = "SELECT evt_from, SUM(CAST(evt_value AS DECIMAL)) AS total FROM event_dai_Transfer GROUP BY evt_from ORDER BY total DESC LIMIT $limit"
        \\params = ["limit:u32:100", "min_value:string:"]
        \\cache_ttl_blocks = 50
        \\
        \\[[queries]]
        \\name = "holder_balance"
        \\path = "/queries/holder_balance"
        \\sql = "SELECT * FROM event_dai_Transfer WHERE evt_from = $address LIMIT 100"
        \\params = ["address:string:0x0"]
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), cfg.queries.len);
    try std.testing.expectEqualStrings("top_transfers", cfg.queries[0].name);
    try std.testing.expectEqualStrings("/queries/top_transfers", cfg.queries[0].path);
    try std.testing.expectEqual(@as(usize, 2), cfg.queries[0].params.len);
    try std.testing.expectEqualStrings("limit", cfg.queries[0].params[0].name);
    try std.testing.expectEqualStrings("u32", cfg.queries[0].params[0].param_type);
    try std.testing.expectEqualStrings("100", cfg.queries[0].params[0].default_value);
    try std.testing.expectEqual(@as(u64, 50), cfg.queries[0].cache_ttl_blocks);
}

test "config validate rejects non-select query" {
    const alloc = std.testing.allocator;
    const toml =
        \\[rpc]
        \\url = "https://example.com"
        \\
        \\[[queries]]
        \\name = "bad"
        \\path = "/queries/bad"
        \\sql = "DELETE FROM event_dai_Transfer"
        \\params = []
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "config: 无效配置 load 失败路径无泄漏" {
    // 回归测试：此前 load() 在 validate 失败时泄漏已解析的全部 cfg 字段
    // （SafeAllocator 在 `zponder start -c bad` 时报告泄漏）。
    const alloc = std.testing.allocator;
    var backend = std.Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    const path = "/tmp/zp_invalid_config.toml";
    const bad =
        \\[global]
        \\log_level = "info"
        \\
        \\[rpc]
        \\url = "http://127.0.0.1:1"
        \\
        \\[database]
        \\type = "sqlite"
        \\db_name = "/tmp/zp_x.db"
        \\
        \\[http]
        \\port = 18080
        \\host = "127.0.0.1"
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bad });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // 无合约 → validate 失败；若 errdefer 缺失，testing allocator 在此报泄漏
    try std.testing.expectError(error.InvalidConfig, load(alloc, io, path));
}

test "config: cors=true 的 cfg deinit 不崩溃（回归：释放静态字面量）" {
    // 修复前：cors=true 把字面量 "*" 放入 cors_origins，
    // deinit 时 alloc.free("*") 释放静态内存 → Bus error（check/start 退出时崩溃）
    const alloc = std.testing.allocator;
    const toml =
        \\[http]
        \\cors = true
        \\
        \\[rpc]
        \\url = "https://example.com"
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("*", cfg.http.cors_origins[0]);
}

test "config 解析 [[templates]]" {
    const alloc = std.testing.allocator;
    const toml =
        \\[global]
        \\chain = "bsc"
        \\[rpc]
        \\url = "http://localhost:8545"
        \\[[contracts]]
        \\name = "launchpad"
        \\address = "0x1"
        \\abi_path = "./abis/launchpad.abi"
        \\events = ["CurveCreated"]
        \\[[factories]]
        \\name = "launchpad_factory"
        \\address = "0x1"
        \\abi_path = "./abis/launchpad.abi"
        \\creation_event = "CurveCreated"
        \\child_address_field = "curve"
        \\child_abi_path = "./abis/curve.abi"
        \\child_events = ["Buy"]
        \\[[templates]]
        \\name = "curve"
        \\abi_path = "./abis/curve.abi"
        \\events = ["Buy", "Sell"]
        \\factory_name = "launchpad_factory"
        \\discovery_event = "CurveCreated"
        \\discovery_address_field = "curve"
        \\from_block = 100
        \\
    ;
    var cfg = try loadFromString(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cfg.templates.len);
    try std.testing.expectEqualStrings("curve", cfg.templates[0].name);
    try std.testing.expectEqual(@as(usize, 2), cfg.templates[0].events.len);
    try std.testing.expectEqual(@as(u64, 100), cfg.templates[0].from_block);
}

test "config factory template_name 解析" {
    const alloc = std.testing.allocator;
    var cfg = try loadTemplateFixture(alloc, "", "");
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("curve", cfg.factories[0].template_name);
    // 配了 template_name 时不再要求 child_abi_path（发现路径交给模板）
    try std.testing.expectEqualStrings("", cfg.factories[0].child_abi_path);
}

// ---------------------------------------------------------------------------
// Task 8：[[templates]] 装配的启动期校验（携转约束 3/4/5/7）
// ---------------------------------------------------------------------------

/// 模板装配的配置骨架：工厂用 template_name 指向模板（默认**不**配 child_abi_path）。
/// `factory_lines` / `template_lines` 用于注入变体，后者可以追加新的 `[[templates]]` 段。
fn loadTemplateFixture(alloc: std.mem.Allocator, factory_lines: []const u8, template_lines: []const u8) !Config {
    const toml = try std.fmt.allocPrint(alloc,
        \\[rpc]
        \\url = "http://localhost:8545"
        \\
        \\[database]
        \\type = "sqlite"
        \\db_name = "t.db"
        \\
        \\[[factories]]
        \\name = "launchpad_factory"
        \\address = "0x1"
        \\abi_path = "./abis/launchpad.abi"
        \\creation_event = "CurveCreated"
        \\child_address_field = "curve"
        \\template_name = "curve"
        \\{s}
        \\
        \\[[templates]]
        \\name = "curve"
        \\abi_path = "./abis/curve.abi"
        \\events = ["Buy"]
        \\factory_name = "launchpad_factory"
        \\from_block = 100
        \\{s}
        \\
    , .{ factory_lines, template_lines });
    defer alloc.free(toml);
    return loadFromString(alloc, toml);
}

test "config 实体闸门纳入 templates（携转约束 3）" {
    const alloc = std.testing.allocator;
    const skeleton =
        \\[rpc]
        \\url = "http://localhost:8545"
        \\[database]
        \\type = "sqlite"
        \\db_name = "t.db"
        \\
    ;
    var empty = try loadFromString(alloc, skeleton);
    defer empty.deinit(alloc);
    try std.testing.expect(!hasIndexableEntity(&empty));

    // 只有 [[templates]]（无 contracts / factories）也构成实体，不再被闸门拒绝
    var only_templates = try loadFromString(alloc, skeleton ++ "[[templates]]\nname = \"curve\"\n");
    defer only_templates.deinit(alloc);
    try std.testing.expect(hasIndexableEntity(&only_templates));
}

test "config validate: 模板装配的合法配置通过（template_name 免除 child_abi_path）" {
    const alloc = std.testing.allocator;
    var cfg = try loadTemplateFixture(alloc, "", "");
    defer cfg.deinit(alloc);
    try validate(&cfg);
}

test "config validate: 模板名重复被拒（携转约束 4）" {
    const alloc = std.testing.allocator;
    var dup = try loadTemplateFixture(alloc, "", "[[templates]]\nname = \"curve\"\nabi_path = \"./abis/curve.abi\"\nfactory_name = \"launchpad_factory\"\n");
    defer dup.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), dup.templates.len);
    try std.testing.expectError(error.InvalidConfig, validate(&dup));

    // 对照：名字不同的第二个模板可以共存——但它必须有自己的工厂反向指回它（一对一）。
    // 沿用同一个工厂会让 curve2 的地址集合永远为空（本文件另有用例覆盖该拒绝）。
    const second_factory =
        "[[factories]]\nname = \"curve2_factory\"\naddress = \"0x2\"\nabi_path = \"./abis/launchpad.abi\"\ncreation_event = \"CurveCreated\"\nchild_address_field = \"curve\"\ntemplate_name = \"curve2\"\n";
    const second_template =
        "[[templates]]\nname = \"curve2\"\nabi_path = \"./abis/curve.abi\"\nfactory_name = \"curve2_factory\"\n";
    var distinct = try loadTemplateFixture(alloc, second_factory, second_template);
    defer distinct.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), distinct.templates.len);
    try std.testing.expectEqual(@as(usize, 2), distinct.factories.len);
    try validate(&distinct);
}

test "config validate: 工厂↔模板必须一对一（工厂必须反向指回模板）" {
    const alloc = std.testing.allocator;
    // 工厂存在、正向校验能过，但它的 template_name 不指回 curve（这里退回老
    // child_abi_path 路径）→ curve 的地址集合永远为空：进程 running 却零索引。
    var not_back = try loadTemplateFixture(
        alloc,
        "template_name = \"\"\nchild_abi_path = \"./abis/curve.abi\"\n",
        "",
    );
    defer not_back.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&not_back));

    // 对照：同一份配置，工厂反向指回 curve 时通过
    var ok = try loadTemplateFixture(alloc, "", "");
    defer ok.deinit(alloc);
    try validate(&ok);
}

test "config validate: 重复的工厂 address 被拒" {
    const alloc = std.testing.allocator;
    const dup_sql = "[[factories]]\nname = \"f2\"\naddress = \"0x1\"\nabi_path = \"./abis/x.abi\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\nchild_abi_path = \"./abis/curve.abi\"\n";
    var dup = try loadTemplateFixture(alloc, dup_sql, "");
    defer dup.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), dup.factories.len);
    try std.testing.expectError(error.InvalidConfig, validate(&dup));

    // 大小写不同但同一地址：同样拒绝
    const case_dup = "[[factories]]\nname = \"f2\"\naddress = \"0X1\"\nabi_path = \"./abis/x.abi\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\nchild_abi_path = \"./abis/curve.abi\"\n";
    var dup_case = try loadTemplateFixture(alloc, case_dup, "");
    defer dup_case.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&dup_case));

    // 对照：地址不同的第二个工厂（老 child_abi_path 路径）可以并存
    const other = "[[factories]]\nname = \"f2\"\naddress = \"0x2\"\nabi_path = \"./abis/x.abi\"\ncreation_event = \"E\"\nchild_address_field = \"c\"\nchild_abi_path = \"./abis/curve.abi\"\n";
    var ok = try loadTemplateFixture(alloc, other, "");
    defer ok.deinit(alloc);
    try validate(&ok);
}

test "config templates 解析 max_addresses_per_request（缺省 null，运行期落默认值）" {
    const alloc = std.testing.allocator;
    var set = try loadTemplateFixture(alloc, "", "max_addresses_per_request = 50\n");
    defer set.deinit(alloc);
    try std.testing.expectEqual(@as(?u32, 50), set.templates[0].max_addresses_per_request);

    var dflt = try loadTemplateFixture(alloc, "", "");
    defer dflt.deinit(alloc);
    try std.testing.expect(dflt.templates[0].max_addresses_per_request == null);
}

test "config validate: template.factory_name 必须存在（携转约束 5）" {
    const alloc = std.testing.allocator;
    var ghost = try loadTemplateFixture(alloc, "", "factory_name = \"ghost_factory\"\n");
    defer ghost.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&ghost));
}

test "config validate: 同一工厂不得同时配 child_abi_path 与 template_name（携转约束 7）" {
    const alloc = std.testing.allocator;
    var both = try loadTemplateFixture(alloc, "child_abi_path = \"./abis/curve.abi\"\n", "");
    defer both.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&both));
}

test "config validate: factory.template_name 必须指向已定义的模板" {
    const alloc = std.testing.allocator;
    var ghost = try loadTemplateFixture(alloc, "template_name = \"ghost_template\"\n", "");
    defer ghost.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&ghost));
}

test "config validate: 模板缺少 name / abi_path 被拒" {
    const alloc = std.testing.allocator;
    var no_name = try loadTemplateFixture(alloc, "", "name = \"\"\n");
    defer no_name.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&no_name));

    var no_abi = try loadTemplateFixture(alloc, "", "abi_path = \"\"\n");
    defer no_abi.deinit(alloc);
    try std.testing.expectError(error.InvalidConfig, validate(&no_abi));
}

test "config validate: 模板名不得与合约名重复（事件表前缀冲突）" {
    const alloc = std.testing.allocator;
    // 追加一个与模板同名的 [[contracts]]：两者的表前缀都是 event_curve_*
    var clash = try loadTemplateFixture(alloc, "", "[[contracts]]\nname = \"curve\"\naddress = \"0x2\"\nabi_path = \"./abis/curve.abi\"\n");
    defer clash.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), clash.contracts.len);
    try std.testing.expectError(error.InvalidConfig, validate(&clash));
}
