const std = @import("std");

/// 模板变量映射
pub const VarMap = struct {
    keys: [][]const u8,
    values: [][]const u8,

    pub fn init(alloc: std.mem.Allocator, count: usize) !VarMap {
        return .{
            .keys = try alloc.alloc([]const u8, count),
            .values = try alloc.alloc([]const u8, count),
        };
    }

    pub fn deinit(self: *VarMap, alloc: std.mem.Allocator) void {
        alloc.free(self.keys);
        alloc.free(self.values);
    }

    /// 存储键值对（浅拷贝指针，调用方负责内存生命周期）
    pub fn put(self: *VarMap, idx: usize, key: []const u8, value: []const u8) void {
        self.keys[idx] = key;
        self.values[idx] = value;
    }

    /// 存储键值对（深拷贝，VarMap 接管所有权）
    pub fn putOwned(self: *VarMap, alloc: std.mem.Allocator, idx: usize, key: []const u8, value: []const u8) !void {
        self.keys[idx] = try alloc.dupe(u8, key);
        self.values[idx] = try alloc.dupe(u8, value);
    }

    pub fn get(self: VarMap, key: []const u8) ?[]const u8 {
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }
};

/// 渲染模板：替换 {$VAR} 为值，{#include FILE} 为文件内容
pub fn render(
    alloc: std.mem.Allocator,
    io: std.Io,
    template: []const u8,
    vars: VarMap,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < template.len) {
        // {#include FILE}
        if (i + 10 <= template.len and std.mem.startsWith(u8, template[i..], "{#include ")) {
            const start = i + 10;
            const end = std.mem.indexOfScalarPos(u8, template, start, '}') orelse {
                try out.appendSlice(alloc, template[i..]);
                break;
            };
            const include_path = std.mem.trim(u8, template[start..end], " \t");
            if (std.Io.Dir.cwd().access(io, include_path, .{})) {
                const content = std.Io.Dir.cwd().readFileAlloc(io, include_path, alloc, .limited(1024 * 1024)) catch "";
                try out.appendSlice(alloc, content);
            } else |_| {
                try out.print(alloc, "<!-- include not found: {s} -->", .{include_path});
            }
            i = end + 1;
            continue;
        }

        // {$VAR}
        if (i + 2 <= template.len and template[i] == '{' and template[i + 1] == '$') {
            const end = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse {
                try out.appendSlice(alloc, template[i..]);
                break;
            };
            const var_name = template[i + 2 .. end];
            if (vars.get(var_name)) |val| {
                try out.appendSlice(alloc, val);
            } else {
                // 未知变量保留原样
                try out.appendSlice(alloc, template[i .. end + 1]);
            }
            i = end + 1;
            continue;
        }

        try out.append(alloc, template[i]);
        i += 1;
    }

    return try out.toOwnedSlice(alloc);
}

test "render basic vars" {
    const alloc = std.testing.allocator;
    var vars = try VarMap.init(alloc, 2);
    defer vars.deinit(alloc);
    vars.put(0, "API", "http://localhost:8080");
    vars.put(1, "TITLE", "Dashboard");

    {
        const result = try render(alloc, undefined, "API: {$API} - {$TITLE}", vars);
        defer alloc.free(result);
        try std.testing.expectEqualStrings("API: http://localhost:8080 - Dashboard", result);
    }
    {
        const result = try render(alloc, undefined, "{$UNKNOWN}", vars);
        defer alloc.free(result);
        try std.testing.expectEqualStrings("{$UNKNOWN}", result);
    }
}

test "render json vars" {
    const alloc = std.testing.allocator;
    var vars = try VarMap.init(alloc, 2);
    defer vars.deinit(alloc);
    vars.put(0, "CONTRACTS", "[{\"name\":\"dai\"},{\"name\":\"busd\"}]");
    vars.put(1, "VERSION", "0.1.0");

    const result = try render(alloc, undefined, "const V={$VERSION}; const C={$CONTRACTS};", vars);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"dai\"") != null);
}
