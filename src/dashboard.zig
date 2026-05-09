const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig");

pub fn renderDashboard(
    alloc: std.mem.Allocator,
    d: config.DashboardConfig,
    all_dashboards: []const config.DashboardConfig,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n");
    try buf.appendSlice(alloc, "<meta charset=\"UTF-8\">\n");
    try buf.appendSlice(alloc, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try buf.print(alloc, "<title>zponder — {s}</title>\n", .{d.title});
    try buf.appendSlice(alloc, "<script src=\"https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js\"></script>\n");
    try buf.appendSlice(alloc, "<script defer src=\"https://cdn.jsdelivr.net/npm/alpinejs@3.14.9/dist/cdn.min.js\"></script>\n");
    try buf.appendSlice(alloc, "<script type=\"module\">\n");
    try buf.appendSlice(alloc, "import { twind, observe } from 'https://esm.sh/@twind/core';\n");
    try buf.appendSlice(alloc, "import { presetTailwind } from 'https://esm.sh/@twind/preset-tailwind';\n");
    try buf.appendSlice(alloc, "const tw = twind({ presets: [presetTailwind()] });\n");
    try buf.appendSlice(alloc, "observe(tw);\n");
    try buf.appendSlice(alloc, "</script>\n");
    try buf.appendSlice(alloc,
        \\<style>
        \\  body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; margin: 0; }
        \\  .card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 16px; }
        \\  .widget-title { color: #94a3b8; font-size: 14px; margin: 0 0 12px 0; }
        \\  .loading { color: #64748b; font-size: 12px; }
        \\  table { width: 100%%; border-collapse: collapse; font-size: 13px; }
        \\  th { text-align: left; color: #64748b; font-weight: 500; padding: 6px 8px; border-bottom: 1px solid #334155; }
        \\  td { padding: 6px 8px; border-bottom: 1px solid #1e293b; font-family: monospace; font-size: 12px; }
        \\  .nav { border-bottom: 1px solid #334155; padding: 12px 24px; display: flex; gap: 24px; align-items: center; }
        \\  .nav a { color: #94a3b8; text-decoration: none; font-size: 14px; }
        \\  .nav a.active { color: #34d399; border-bottom: 2px solid #34d399; padding-bottom: 4px; }
        \\  .count-num { font-size: 36px; font-weight: bold; color: #34d399; }
        \\  .tab-btn { padding: 6px 14px; border-radius: 6px; font-size: 13px; cursor: pointer; border: 1px solid #334155; background: #1e293b; color: #94a3b8; }
        \\  .tab-btn.active { background: #34d399; color: #0f172a; border-color: #34d399; }
        \\  .collapsible-header { cursor: pointer; display: flex; justify-content: space-between; align-items: center; user-select: none; }
        \\  .collapsible-arrow { transition: transform 0.2s; }
        \\  .collapsed .collapsible-arrow { transform: rotate(-90deg); }
        \\  .dropdown-btn { padding: 6px 12px; border-radius: 6px; font-size: 13px; border: 1px solid #334155; background: #1e293b; color: #e2e8f0; cursor: pointer; }
        \\  .dropdown-menu { position: absolute; top: 100%%; left: 0; margin-top: 4px; background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 4px; min-width: 160px; z-index: 50; }
        \\  .dropdown-item { padding: 6px 12px; border-radius: 4px; font-size: 13px; cursor: pointer; color: #e2e8f0; }
        \\  .dropdown-item:hover { background: #334155; }
        \\  .x-cloak { display: none !important; }
    );
    try buf.appendSlice(alloc, "\n</style>\n</head>\n<body x-data=\"dashboard\" x-cloak>\n");

    // Nav with Alpine.js
    try buf.appendSlice(alloc, "<div class=\"nav\" x-data=\"{open: false}\">\n");
    try buf.appendSlice(alloc, "<b>zponder</b>\n");
    for (all_dashboards) |ad| {
        const cls: []const u8 = if (std.mem.eql(u8, ad.name, d.name)) " class=\"active\"" else "";
        try buf.print(alloc, "<a href=\"/dashboards/{s}\"{s}>{s}</a>\n", .{ ad.name, cls, ad.title });
    }
    try buf.appendSlice(alloc,
        \\<span style="flex:1"></span>
        \\<div style="position:relative">
        \\  <button class="dropdown-btn" @click="open=!open">⚙ 设置</button>
        \\  <div class="dropdown-menu" x-show="open" @click.outside="open=false">
        \\    <div class="dropdown-item" @click="autoRefresh=!autoRefresh">
        \\      <span x-text="autoRefresh?'✅ 自动刷新:开':'⏸ 自动刷新:关'"></span>
        \\    </div>
        \\    <div class="dropdown-item" @click="collapseAll=!collapseAll">
        \\      <span x-text="collapseAll?'📂 全部展开':'📁 全部折叠'"></span>
        \\    </div>
        \\  </div>
        \\</div>
    );
    try buf.appendSlice(alloc, "</div>\n");

    // Widgets
    try buf.appendSlice(alloc, "<div style=\"max-width:1200px; margin:24px auto; padding:0 24px; display:grid; grid-template-columns:repeat(auto-fill,minmax(360px,1fr)); gap:16px;\">\n");

    for (d.widgets) |w| {
        try buf.appendSlice(alloc, "<div class=\"card\" x-data=\"{collapsed:false}\" :class=\"collapsed?'collapsed':''\">\n");
        try buf.print(alloc, "<h3 class=\"widget-title collapsible-header\" @click=\"collapsed=!collapsed\">{s} <span class=\"collapsible-arrow\">▼</span></h3>\n", .{w.title});
        try buf.print(alloc, "<div id=\"{s}\" hx-get=\"{s}\" hx-trigger=\"every {d}s\" hx-swap=\"innerHTML\">\n", .{ w.id, w.endpoint, w.refresh });

        if (std.mem.eql(u8, w.widget_type, "count")) {
            try buf.appendSlice(alloc, "<div class=\"count-num loading\">...</div>\n");
        } else if (std.mem.eql(u8, w.widget_type, "table")) {
            try buf.appendSlice(alloc, "<table><thead><tr>");
            for (w.columns) |col| {
                try buf.print(alloc, "<th>{s}</th>", .{col});
            }
            try buf.appendSlice(alloc, "</tr></thead></table>\n");
            try buf.appendSlice(alloc, "<div class=\"loading\">等待数据...</div>\n");
        } else if (std.mem.eql(u8, w.widget_type, "stats")) {
            try buf.appendSlice(alloc, "<div class=\"loading\">等待数据...</div>\n");
        } else {
            try buf.appendSlice(alloc, "<div class=\"loading\">等待数据...</div>\n");
        }

        try buf.appendSlice(alloc, "</div>\n</div>\n");
    }

    try buf.appendSlice(alloc, "</div>\n");
    // Alpine.js global state
    try buf.appendSlice(alloc,
        \\<script>
        \\  document.addEventListener('alpine:init', () => {
        \\    Alpine.data('dashboard', () => ({
        \\      autoRefresh: true,
        \\      collapseAll: false,
        \\      init() {
        \\        this.$watch('collapseAll', v => {
        \\          document.querySelectorAll('[x-data]').forEach(el => {
        \\            if (el.__x && el.__x.$data && 'collapsed' in el.__x.$data) {
        \\              el.__x.$data.collapsed = v;
        \\            }
        \\          });
        \\        });
        \\        this.$watch('autoRefresh', v => {
        \\          document.querySelectorAll('[hx-trigger]').forEach(el => {
        \\            if (v) {
        \\              htmx.process(el);
        \\            } else {
        \\              el.removeAttribute('hx-trigger');
        \\            }
        \\          });
        \\        });
        \\      }
        \\    }));
        \\  });
        \\</script>
    );
    try buf.appendSlice(alloc, "\n</body>\n</html>");
    return try buf.toOwnedSlice(alloc);
}
