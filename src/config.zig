const std = @import("std");
const log = @import("log.zig");

pub const EventFilter = struct {
    event: []const u8,
    field: []const u8,
    op: []const u8,
    value: []const u8,
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
};

pub const GlobalConfig = struct {
    log_level: []const u8,
    log_file: []const u8,
    snapshot_interval: u64,
    etherscan_api_key: []const u8,
    chain: []const u8,            // "ethereum" | "bsc" | "polygon"
};

pub const IndexerConfig = struct {
    contracts: []const ContractConfig,
    block_batch_size: u32,
    max_pending_blocks: u32,
    reorg_safe_depth: u32,
};

pub const RpcConfig = struct {
    url: []const u8,
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
};

pub const DashboardConfig = struct {
    name: []const u8,
    title: []const u8,
    widgets: []WidgetConfig,
};

pub const QueryParam = struct {
    name: []const u8,
    param_type: []const u8,
    default_value: []const u8,
};

pub const QueryConfig = struct {
    name: []const u8,
    path: []const u8,
    sql: []const u8,
    params: []const QueryParam,
    cache_ttl_blocks: u64,
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    global: GlobalConfig,
    rpc: RpcConfig,
    http: HttpConfig,
    database: DatabaseConfig,
    contracts: []const ContractConfig,
    queries: []const QueryConfig,
    dashboards: []const DashboardConfig,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.global.log_level);
        alloc.free(self.global.log_file);
        alloc.free(self.global.etherscan_api_key);
        alloc.free(self.global.chain);
        alloc.free(self.rpc.url);
        alloc.free(self.http.host);
        if (self.http.cors_origins.len > 0) {
            for (self.http.cors_origins) |o| alloc.free(o);
            alloc.free(self.http.cors_origins);
        }
        alloc.free(self.database.db_type);
        alloc.free(self.database.db_name);
        for (self.contracts) |c| {
            alloc.free(c.name);
            alloc.free(c.address);
            alloc.free(c.abi_path);
            for (c.events) |e| alloc.free(e);
            alloc.free(c.events);
            for (c.filters) |f| {
                alloc.free(f.event);
                alloc.free(f.field);
                alloc.free(f.op);
                alloc.free(f.value);
            }
            alloc.free(c.filters);
        }
        alloc.free(self.contracts);
        for (self.queries) |q| {
            alloc.free(q.name);
            alloc.free(q.path);
            alloc.free(q.sql);
            for (q.params) |p| {
                alloc.free(p.name);
                alloc.free(p.param_type);
                alloc.free(p.default_value);
            }
            alloc.free(q.params);
        }
        alloc.free(self.queries);
        for (self.dashboards) |d| {
            alloc.free(d.name);
            alloc.free(d.title);
            for (d.widgets) |w| {
                alloc.free(w.id);
                alloc.free(w.title);
                alloc.free(w.widget_type);
                alloc.free(w.endpoint);
                for (w.columns) |c| alloc.free(c);
                alloc.free(w.columns);
            }
            alloc.free(d.widgets);
        }
        alloc.free(self.dashboards);
    }
};

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[start..end];
}

fn parseU64(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, trim(s), 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, trim(s), 10);
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, trim(s), 10);
}

fn parseBool(s: []const u8) bool {
    const t = trim(s);
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

fn parseEvents(alloc: std.mem.Allocator, value: []const u8) ![]const []const u8 {
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
        for (contracts.items) |c| {
            alloc.free(c.name);
            alloc.free(c.address);
            alloc.free(c.abi_path);
            for (c.events) |e| alloc.free(e);
            alloc.free(c.events);
        }
        contracts.deinit(alloc);
    }

    var queries: std.ArrayList(QueryConfig) = .empty;
    errdefer {
        for (queries.items) |q| {
            alloc.free(q.name);
            alloc.free(q.path);
            alloc.free(q.sql);
            for (q.params) |p| {
                alloc.free(p.name);
                alloc.free(p.param_type);
                alloc.free(p.default_value);
            }
            alloc.free(q.params);
        }
        queries.deinit(alloc);
    }

    var dashboards: std.ArrayList(DashboardConfig) = .empty;
    errdefer {
        for (dashboards.items) |d| {
            alloc.free(d.name);
            alloc.free(d.title);
            for (d.widgets) |w| {
                alloc.free(w.id);
                alloc.free(w.title);
                alloc.free(w.widget_type);
                alloc.free(w.endpoint);
                for (w.columns) |c| alloc.free(c);
                alloc.free(w.columns);
            }
            alloc.free(d.widgets);
        }
        dashboards.deinit(alloc);
    }

    const Section = enum {
        none,
        global,
        rpc,
        database,
        http,
        contracts,
        queries,
        dashboards,
        dashboard_widgets,
    };
    var section: Section = .none;
    var current_contract: ?ContractConfig = null;
    var current_query: ?QueryConfig = null;
    var current_dashboard: ?DashboardConfig = null;
    var current_widget: ?WidgetConfig = null;
    var current_widgets: std.ArrayList(WidgetConfig) = .empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = trim(line_raw);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]")) {
            // 保存之前的合约/查询/dashboard
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
            } else {
                section = .none;
            }
            continue;
        }

        const kv = splitKeyValue(line) orelse continue;
        const key = kv.key;
        const value = kv.value;

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
                }
            },
            .rpc => {
                if (std.mem.eql(u8, key, "url")) {
                    alloc.free(rpc.url);
                    rpc.url = try unquote(alloc, value);
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
                        http.cors_origins = try alloc.dupe([]const u8, &[_][]const u8{"*"});
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
            else => {},
        }
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

    const cfg = Config{
        .alloc = alloc,
        .global = global,
        .rpc = rpc,
        .http = http,
        .database = database,
        .contracts = final_contracts,
        .queries = final_queries,
        .dashboards = final_dashboards,
    };

    return cfg;
}

pub fn validate(cfg: *const Config) !void {
    var errors: u32 = 0;

    if (cfg.rpc.url.len == 0) {
        log.err("配置错误: rpc.url 不能为空", .{});
        errors += 1;
    }
    if (cfg.database.db_name.len == 0) {
        log.err("配置错误: database.db_name 不能为空", .{});
        errors += 1;
    }
    if (cfg.contracts.len == 0) {
        log.err("配置错误: 必须至少配置一个合约", .{});
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

    if (errors > 0) {
        return error.InvalidConfig;
    }

    log.info("配置验证通过: 发现 {d} 个合约, {d} 个自定义查询", .{cfg.contracts.len, cfg.queries.len});
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
