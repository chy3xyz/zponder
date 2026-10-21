const std = @import("std");

/// ABI 事件输入参数
pub const AbiEventInput = struct {
    name: []const u8,
    type: []const u8,
    indexed: bool,
};

/// ABI 事件定义
pub const AbiEvent = struct {
    name: []const u8,
    inputs: []const AbiEventInput,
    signature: [32]u8,

    pub fn deinit(self: *AbiEvent, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.inputs) |*inp| {
            alloc.free(inp.name);
            alloc.free(inp.type);
        }
        alloc.free(self.inputs);
        self.* = undefined;
    }
};

/// ABI 函数参数（inputs / outputs 通用）
pub const AbiParam = struct {
    name: []const u8,
    type: []const u8,
};

/// ABI 函数定义（含返回类型）
pub const AbiFunction = struct {
    name: []const u8,
    inputs: []AbiParam,
    outputs: []AbiParam,

    pub fn deinit(self: *AbiFunction, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.inputs) |*p| {
            alloc.free(p.name);
            alloc.free(p.type);
        }
        alloc.free(self.inputs);
        for (self.outputs) |*p| {
            alloc.free(p.name);
            alloc.free(p.type);
        }
        alloc.free(self.outputs);
        self.* = undefined;
    }

    /// 返回类型：单个 output 返回其类型，多个返回 "(type1,type2)"，无返回返回 null。
    pub fn returnType(self: *const AbiFunction, alloc: std.mem.Allocator) ?[]const u8 {
        if (self.outputs.len == 0) return null;
        if (self.outputs.len == 1) return self.outputs[0].type;
        // 多返回值 → 元组
        var buf: std.ArrayList(u8) = .empty;
        buf.append(alloc, '(') catch return null;
        for (self.outputs, 0..) |o, i| {
            if (i > 0) buf.append(alloc, ',') catch return null;
            buf.appendSlice(alloc, o.type) catch return null;
        }
        buf.append(alloc, ')') catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }
};

/// ABI 合约定义
pub const AbiContract = struct {
    events: []AbiEvent,
    functions: []AbiFunction,

    pub fn deinit(self: *AbiContract, alloc: std.mem.Allocator) void {
        for (self.events) |*e| {
            e.deinit(alloc);
        }
        alloc.free(self.events);
        for (self.functions) |*f| {
            f.deinit(alloc);
        }
        alloc.free(self.functions);
        self.* = undefined;
    }

    /// 根据事件签名哈希查找事件定义
    pub fn findEventByTopic0(self: *const AbiContract, topic0: []const u8) ?*const AbiEvent {
        for (self.events) |*e| {
            if (std.mem.eql(u8, &e.signature, topic0)) {
                return e;
            }
        }
        return null;
    }

    /// 根据事件名称查找事件定义
    pub fn findEventByName(self: *const AbiContract, name: []const u8) ?*const AbiEvent {
        for (self.events) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                return e;
            }
        }
        return null;
    }

    /// 根据函数名（不含参数）查找函数定义（首个匹配，忽略重载）
    pub fn findFunctionByName(self: *const AbiContract, name: []const u8) ?*const AbiFunction {
        for (self.functions) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f;
            }
        }
        return null;
    }
};

/// 解析 ABI JSON 文件，提取事件定义
pub fn parseAbiFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !AbiContract {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        io, path, alloc, std.Io.Limit.limited(1024 * 1024),
    );
    defer alloc.free(content);
    return try parseAbiJson(alloc, content);
}

/// 解析 ABI JSON 字符串
pub fn parseAbiJson(alloc: std.mem.Allocator, content: []const u8) !AbiContract {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var events: std.ArrayList(AbiEvent) = .empty;
    errdefer {
        for (events.items) |*e| {
            e.deinit(alloc);
        }
        events.deinit(alloc);
    }
    var functions: std.ArrayList(AbiFunction) = .empty;
    errdefer {
        for (functions.items) |*f| {
            f.deinit(alloc);
        }
        functions.deinit(alloc);
    }

    const root = parsed.value.array;
    for (root.items) |item| {
        const obj = item.object;
        const type_val = obj.get("type") orelse continue;
        const type_str = type_val.string;

        if (std.mem.eql(u8, type_str, "event")) {
            const name = obj.get("name").?.string;

            var inputs: std.ArrayList(AbiEventInput) = .empty;
            errdefer {
                for (inputs.items) |inp| {
                    alloc.free(inp.name);
                    alloc.free(inp.type);
                }
                inputs.deinit(alloc);
            }

            const inputs_arr = obj.get("inputs").?.array;
            for (inputs_arr.items) |inp| {
                const inp_obj = inp.object;
                const cname = try alloc.dupe(u8, inp_obj.get("name").?.string);
                const ctype = canonicalAbiType(alloc, inp) catch |e| {
                    alloc.free(cname);
                    return e;
                };
                inputs.append(alloc, .{
                    .name = cname,
                    .type = ctype,
                    .indexed = if (inp_obj.get("indexed")) |v| v.bool else false,
                }) catch |e| {
                    alloc.free(cname);
                    alloc.free(ctype);
                    return e;
                };
            }

            // 计算事件签名：keccak256("EventName(type1,type2,...)")
            const owned_inputs = try inputs.toOwnedSlice(alloc);
            errdefer {
                for (owned_inputs) |inp| {
                    alloc.free(inp.name);
                    alloc.free(inp.type);
                }
                alloc.free(owned_inputs);
            }
            const sig_str = try formatEventSignature(alloc, name, owned_inputs);
            defer alloc.free(sig_str);
            var signature: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(sig_str, &signature, .{});

            try events.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .inputs = owned_inputs,
                .signature = signature,
            });
        } else if (std.mem.eql(u8, type_str, "function")) {
            // 函数（含返回类型）：contractCall 用它解析 eth_call 返回值
            const name = obj.get("name").?.string;

            var inputs: std.ArrayList(AbiParam) = .empty;
            errdefer inputs.deinit(alloc);
            const inputs_arr = if (obj.get("inputs")) |v| v.array.items else &.{};
            for (inputs_arr) |inp| {
                const inp_obj = inp.object;
                try inputs.append(alloc, .{
                    .name = if (inp_obj.get("name")) |n| try alloc.dupe(u8, n.string) else try alloc.dupe(u8, ""),
                    .type = try alloc.dupe(u8, inp_obj.get("type").?.string),
                });
            }

            var outputs: std.ArrayList(AbiParam) = .empty;
            errdefer {
                for (outputs.items) |p| {
                    alloc.free(p.name);
                    alloc.free(p.type);
                }
                outputs.deinit(alloc);
            }
            const outputs_arr = if (obj.get("outputs")) |v| v.array.items else &.{};
            for (outputs_arr) |out| {
                const out_obj = out.object;
                const oname = if (out_obj.get("name")) |n| try alloc.dupe(u8, n.string) else try alloc.dupe(u8, "");
                const otype = canonicalAbiType(alloc, out) catch |e| {
                    alloc.free(oname);
                    return e;
                };
                outputs.append(alloc, .{
                    .name = oname,
                    .type = otype,
                }) catch |e| {
                    alloc.free(oname);
                    alloc.free(otype);
                    return e;
                };
            }

            try functions.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .inputs = try inputs.toOwnedSlice(alloc),
                .outputs = try outputs.toOwnedSlice(alloc),
            });
        }
    }

    return AbiContract{
        .events = try events.toOwnedSlice(alloc),
        .functions = try functions.toOwnedSlice(alloc),
    };
}

/// 将 ABI 类型映射为 SQLite 列类型
pub fn abiTypeToSqlType(abi_type: []const u8) []const u8 {
    if (std.mem.eql(u8, abi_type, "address")) return "TEXT";
    if (std.mem.eql(u8, abi_type, "bool")) return "INTEGER";
    if (std.mem.startsWith(u8, abi_type, "uint")) return "TEXT"; // uint256 等大数用 TEXT
    if (std.mem.startsWith(u8, abi_type, "int")) return "TEXT";
    if (std.mem.eql(u8, abi_type, "bytes32")) return "TEXT";
    if (std.mem.eql(u8, abi_type, "string")) return "TEXT";
    if (std.mem.eql(u8, abi_type, "bytes")) return "TEXT";
    return "TEXT"; // 默认兜底
}

/// 格式化事件签名字符串（用于计算 topic0）。元组写成 `(uint256,address)`。
fn formatEventSignature(alloc: std.mem.Allocator, name: []const u8, inputs: []const AbiEventInput) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, name);
    try buf.append(alloc, '(');
    for (inputs, 0..) |inp, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, inp.type);
    }
    try buf.append(alloc, ')');
    return try buf.toOwnedSlice(alloc);
}

fn canonicalAbiType(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value != .object) return error.InvalidAbi;
    const obj = value.object;
    const type_val = obj.get("type") orelse return error.InvalidAbi;
    if (type_val != .string) return error.InvalidAbi;
    const type_str = type_val.string;
    const comps_val = obj.get("components") orelse return try alloc.dupe(u8, type_str);
    if (comps_val != .array) return try alloc.dupe(u8, type_str);

    var inner: std.ArrayList(u8) = .empty;
    errdefer inner.deinit(alloc);
    try inner.append(alloc, '(');
    for (comps_val.array.items, 0..) |comp, i| {
        if (i > 0) try inner.append(alloc, ',');
        const part = try canonicalAbiType(alloc, comp);
        defer alloc.free(part);
        try inner.appendSlice(alloc, part);
    }
    try inner.append(alloc, ')');
    const tuple_s = try inner.toOwnedSlice(alloc);
    defer alloc.free(tuple_s);
    if (type_str.len < 5) return try alloc.dupe(u8, tuple_s);
    const at = std.mem.indexOf(u8, type_str, "tuple") orelse return try alloc.dupe(u8, tuple_s);
    const out = try alloc.alloc(u8, type_str.len - 5 + tuple_s.len);
    @memcpy(out[0..at], type_str[0..at]);
    @memcpy(out[at..][0..tuple_s.len], tuple_s);
    @memcpy(out[at + tuple_s.len ..], type_str[at + 5 ..]);
    return out;
}

/// 解析后的日志事件数据
pub const DecodedLog = struct {
    event_name: []const u8,
    fields: []const DecodedField,

    pub const DecodedField = struct {
        name: []const u8,
        value: []const u8,
    };
};

const max_array_len: usize = 1024;

const ArrayBound = struct {
    inner: []const u8,
    /// null 表示 `T[]`。有值表示 `T[k]`。
    fixed: ?usize,
};

/// 最右边一对括号是最外层维度。`uint256[2][]` 的内层是 `uint256[2]`。
fn parseArray(abi_type: []const u8) ?ArrayBound {
    if (abi_type.len < 3 or abi_type[abi_type.len - 1] != ']') return null;
    const bracket = std.mem.lastIndexOfScalar(u8, abi_type, '[') orelse return null;
    if (bracket == 0) return null;
    const inside = abi_type[bracket + 1 .. abi_type.len - 1];
    if (inside.len == 0) return .{ .inner = abi_type[0..bracket], .fixed = null };
    const n = std.fmt.parseInt(usize, inside, 10) catch return null;
    return .{ .inner = abi_type[0..bracket], .fixed = n };
}

/// data 里要不要用偏移量。`uint256[2]` 和 `(uint256,uint256)` 直接排在头部。
fn isDynamicType(abi_type: []const u8) bool {
    if (std.mem.eql(u8, abi_type, "string") or std.mem.eql(u8, abi_type, "bytes")) return true;
    if (parseArray(abi_type)) |arr| {
        if (arr.fixed == null) return true;
        return isDynamicType(arr.inner);
    }
    if (tupleInner(abi_type)) |inner| return tupleHasDynamic(inner);
    return false;
}

/// indexed 的数组、元组、string、bytes 在 topic 里只有 keccak，放不进 32 字节。
fn indexedAsHash(abi_type: []const u8) bool {
    if (std.mem.eql(u8, abi_type, "string") or std.mem.eql(u8, abi_type, "bytes")) return true;
    if (abi_type.len > 0 and abi_type[0] == '(') return true;
    return std.mem.indexOfScalar(u8, abi_type, '[') != null;
}

fn staticWordCount(abi_type: []const u8) usize {
    if (parseArray(abi_type)) |arr| {
        const n = arr.fixed orelse return 1;
        const inner = staticWordCount(arr.inner);
        if (inner != 0 and n > std.math.maxInt(usize) / inner) return std.math.maxInt(usize);
        return n * inner;
    }
    if (tupleInner(abi_type)) |inner| return tupleStaticWords(inner);
    return 1;
}

fn tupleInner(abi_type: []const u8) ?[]const u8 {
    if (abi_type.len >= 2 and abi_type[0] == '(' and abi_type[abi_type.len - 1] == ')') return abi_type[1 .. abi_type.len - 1];
    return null;
}

fn nextTupleField(inner: []const u8, i: usize) ?struct { field: []const u8, next: usize } {
    if (i >= inner.len) return null;
    const start = i;
    var depth: usize = 0;
    var j = i;
    while (j < inner.len) : (j += 1) {
        switch (inner[j]) {
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) break,
            else => {},
        }
    }
    const field = std.mem.trim(u8, inner[start..j], " \t");
    var next = j;
    if (next < inner.len and inner[next] == ',') next += 1;
    if (field.len == 0) return null;
    return .{ .field = field, .next = next };
}

fn tupleHasDynamic(inner: []const u8) bool {
    var i: usize = 0;
    while (nextTupleField(inner, i)) |step| {
        if (isDynamicType(step.field)) return true;
        i = step.next;
    }
    return false;
}

fn tupleStaticWords(inner: []const u8) usize {
    var sum: usize = 0;
    var i: usize = 0;
    while (nextTupleField(inner, i)) |step| {
        sum +|= staticWordCount(step.field);
        i = step.next;
    }
    return sum;
}

/// 将 64 字符 hex word 解析为 u256（大端序）
fn hexWordToU256(hex_word: []const u8) u256 {
    if (hex_word.len < 64) return 0;
    var result: u256 = 0;
    for (hex_word[0..64]) |ch| {
        result = result * 16 + hexDigit(ch);
    }
    return result;
}

fn hexDigit(ch: u8) u256 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0,
    };
}

/// 从 data hex 字符串的指定 offset（hex 字符数）处解码动态值（string/bytes）
fn decodeDynamicValue(alloc: std.mem.Allocator, data: []const u8, offset_hex: usize) ![]u8 {
    // data 格式: "0x..."
    const hex_start: usize = blk: {
        if (std.mem.startsWith(u8, data, "0x")) break :blk 2;
        break :blk 0;
    };
    const hex_data = data[hex_start..];

    // 防溢出：offset_hex + 64
    if (offset_hex > std.math.maxInt(usize) - 64 or offset_hex + 64 > hex_data.len)
        return try alloc.dupe(u8, "0x");
    const len_word = hex_data[offset_hex .. offset_hex + 64];
    const len_u256 = hexWordToU256(len_word);
    // 恶意链上数据可能给出超大 u256 长度，@intCast 到 usize 会溢出 panic
    if (len_u256 > std.math.maxInt(usize)) return try alloc.dupe(u8, "0x");
    const len: usize = @intCast(len_u256);

    // 防溢出：len * 2
    if (len > std.math.maxInt(usize) / 2) return try alloc.dupe(u8, "0x");
    const hex_len = len * 2;

    const data_start = offset_hex + 64;
    // 防溢出：data_start + hex_len
    if (data_start > std.math.maxInt(usize) - hex_len or data_start + hex_len > hex_data.len)
        return try alloc.dupe(u8, "0x");

    const result_hex = hex_data[data_start .. data_start + hex_len];
    // 返回完整 hex 字符串（带 0x 前缀）
    var result = try alloc.alloc(u8, 2 + result_hex.len);
    result[0] = '0';
    result[1] = 'x';
    @memcpy(result[2..], result_hex);
    return result;
}

/// 解码静态类型的 32 字节值
fn decodeStaticValue(alloc: std.mem.Allocator, abi_type: []const u8, hex_word: []const u8) ![]u8 {
    if (std.mem.eql(u8, abi_type, "address")) {
        // address: 最后 20 字节 = 40 hex 字符
        if (hex_word.len >= 40) {
            const addr_hex = hex_word[hex_word.len - 40 ..];
            var result = try alloc.alloc(u8, 2 + 40);
            result[0] = '0';
            result[1] = 'x';
            @memcpy(result[2..], addr_hex);
            return result;
        }
    } else if (std.mem.eql(u8, abi_type, "bool")) {
        const val = hexWordToU256(hex_word);
        return try alloc.dupe(u8, if (val != 0) "true" else "false");
    } else if (std.mem.startsWith(u8, abi_type, "uint") or std.mem.startsWith(u8, abi_type, "int")) {
        // 直接返回 hex 表示（保留精度）
        if (hex_word.len >= 64) {
            const word = hex_word[hex_word.len - 64 ..];
            var result = try alloc.alloc(u8, 2 + 64);
            result[0] = '0';
            result[1] = 'x';
            @memcpy(result[2..], word);
            return result;
        }
    } else if (std.mem.startsWith(u8, abi_type, "bytes")) {
        // bytesN: 内联存储，返回 hex
        if (hex_word.len >= 64) {
            const word = hex_word[hex_word.len - 64 ..];
            var result = try alloc.alloc(u8, 2 + 64);
            result[0] = '0';
            result[1] = 'x';
            @memcpy(result[2..], word);
            return result;
        }
    }
    // 兜底：直接返回 hex word
    if (std.mem.startsWith(u8, hex_word, "0x")) {
        return try alloc.dupe(u8, hex_word);
    }
    var result = try alloc.alloc(u8, 2 + hex_word.len);
    result[0] = '0';
    result[1] = 'x';
    @memcpy(result[2..], hex_word);
    return result;
}

fn joinJsonArray(alloc: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(alloc, ',');
        if (it.len > 0 and it[0] == '[') {
            try buf.appendSlice(alloc, it);
        } else {
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, it);
            try buf.append(alloc, '"');
        }
    }
    try buf.append(alloc, ']');
    return try buf.toOwnedSlice(alloc);
}

fn decodeStaticType(alloc: std.mem.Allocator, abi_type: []const u8, hex_data: []const u8, word_index: usize) std.mem.Allocator.Error![]u8 {
    if (parseArray(abi_type)) |arr| {
        const n = arr.fixed orelse return try alloc.dupe(u8, "0x");
        if (n > max_array_len) return try alloc.dupe(u8, "0x");
        if (word_index > std.math.maxInt(usize) / 64) return try alloc.dupe(u8, "0x");
        return decodeArray(alloc, arr.inner, n, hex_data, word_index * 64, false);
    }
    if (tupleInner(abi_type)) |inner| {
        if (word_index > std.math.maxInt(usize) / 64) return try alloc.dupe(u8, "0x");
        return decodeLogTuple(alloc, inner, hex_data, word_index * 64);
    }
    if (word_index > std.math.maxInt(usize) / 64) return try alloc.dupe(u8, "0x0");
    const start = word_index * 64;
    if (start >= hex_data.len) return try alloc.dupe(u8, "0x0");
    if (start + 64 <= hex_data.len) return decodeStaticValue(alloc, abi_type, hex_data[start .. start + 64]);
    return decodeStaticValue(alloc, abi_type, hex_data[start..]);
}

/// `start_hex` 起是数组体。静态元素紧挨着排；动态元素先放相对这里的字节偏移。
fn decodeArray(
    alloc: std.mem.Allocator,
    inner: []const u8,
    count: usize,
    hex_data: []const u8,
    start_hex: usize,
    heads_are_offsets: bool,
) std.mem.Allocator.Error![]u8 {
    if (count > max_array_len) return try alloc.dupe(u8, "0x");
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| alloc.free(it);
        items.deinit(alloc);
    }
    if (!heads_are_offsets) {
        if (start_hex % 64 != 0) return try alloc.dupe(u8, "0x");
        var word_index = start_hex / 64;
        const words = staticWordCount(inner);
        for (0..count) |_| {
            const elem = try decodeStaticType(alloc, inner, hex_data, word_index);
            items.append(alloc, elem) catch |e| {
                alloc.free(elem);
                return e;
            };
            word_index +|= words;
        }
    } else {
        for (0..count) |i| {
            const word_at = start_hex +| (i *| 64);
            if (word_at > std.math.maxInt(usize) - 64 or word_at + 64 > hex_data.len) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const off = hexWordToU256(hex_data[word_at .. word_at + 64]);
            if (off > @as(u256, std.math.maxInt(usize) / 2)) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const hex_off: usize = @as(usize, @intCast(off)) * 2;
            if (start_hex > std.math.maxInt(usize) - hex_off) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const elem = try decodeDynamicPayload(alloc, inner, hex_data, start_hex + hex_off);
            items.append(alloc, elem) catch |e| {
                alloc.free(elem);
                return e;
            };
        }
    }
    const owned = try items.toOwnedSlice(alloc);
    defer {
        for (owned) |it| alloc.free(it);
        alloc.free(owned);
    }
    return joinJsonArray(alloc, owned);
}

fn decodeDynamicPayload(alloc: std.mem.Allocator, abi_type: []const u8, hex_data: []const u8, offset_hex: usize) std.mem.Allocator.Error![]u8 {
    if (std.mem.eql(u8, abi_type, "string") or std.mem.eql(u8, abi_type, "bytes")) {
        return decodeDynamicValue(alloc, hex_data, offset_hex);
    }
    if (tupleInner(abi_type)) |inner| return decodeLogTuple(alloc, inner, hex_data, offset_hex);
    const arr = parseArray(abi_type) orelse return try alloc.dupe(u8, "0x");
    if (arr.fixed) |n| {
        return decodeArray(alloc, arr.inner, n, hex_data, offset_hex, isDynamicType(arr.inner));
    }
    if (offset_hex > std.math.maxInt(usize) - 64 or offset_hex + 64 > hex_data.len) return try alloc.dupe(u8, "0x");
    const len_u256 = hexWordToU256(hex_data[offset_hex .. offset_hex + 64]);
    if (len_u256 > max_array_len) return try alloc.dupe(u8, "0x");
    const n: usize = @intCast(len_u256);
    return decodeArray(alloc, arr.inner, n, hex_data, offset_hex + 64, isDynamicType(arr.inner));
}

/// 元组体从 `base_hex` 开始。动态成员的偏移相对这里，不相对整段 data。
fn decodeLogTuple(alloc: std.mem.Allocator, inner: []const u8, hex_data: []const u8, base_hex: usize) std.mem.Allocator.Error![]u8 {
    if (base_hex % 64 != 0) return try alloc.dupe(u8, "0x");
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| alloc.free(it);
        items.deinit(alloc);
    }
    var cursor = base_hex / 64;
    var i: usize = 0;
    var n: usize = 0;
    while (nextTupleField(inner, i)) |step| {
        if (n >= max_array_len) break;
        n += 1;
        i = step.next;
        if (isDynamicType(step.field)) {
            const start = cursor *| 64;
            cursor +|= 1;
            if (start > std.math.maxInt(usize) - 64 or start + 64 > hex_data.len) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const off = hexWordToU256(hex_data[start .. start + 64]);
            if (off > @as(u256, std.math.maxInt(usize) / 2)) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const rel: usize = @as(usize, @intCast(off)) * 2;
            if (base_hex > std.math.maxInt(usize) - rel) {
                try items.append(alloc, try alloc.dupe(u8, "0x"));
                continue;
            }
            const elem = try decodeDynamicPayload(alloc, step.field, hex_data, base_hex + rel);
            items.append(alloc, elem) catch |e| {
                alloc.free(elem);
                return e;
            };
        } else {
            const elem = try decodeStaticType(alloc, step.field, hex_data, cursor);
            items.append(alloc, elem) catch |e| {
                alloc.free(elem);
                return e;
            };
            cursor +|= staticWordCount(step.field);
        }
    }
    const owned = try items.toOwnedSlice(alloc);
    defer {
        for (owned) |it| alloc.free(it);
        alloc.free(owned);
    }
    return joinJsonArray(alloc, owned);
}

/// 解码日志（支持静态类型、string、bytes 等动态类型）
pub fn decodeLog(alloc: std.mem.Allocator, event: *const AbiEvent, topics: []const []const u8, data: []const u8) !DecodedLog {
    var fields: std.ArrayList(DecodedLog.DecodedField) = .empty;
    errdefer {
        for (fields.items) |f| alloc.free(f.value);
        fields.deinit(alloc);
    }

    var topic_idx: usize = 1; // topic0 是事件签名，从 topic1 开始
    var data_word_idx: usize = 0; // 当前读取的 32 字节 word 索引
    const hex_start: usize = @as(usize, @intFromBool(std.mem.startsWith(u8, data, "0x"))) * 2;
    const hex_data = data[hex_start..];

    for (event.inputs) |input| {
        if (input.indexed) {
            if (topic_idx < topics.len) {
                const topic = topics[topic_idx];
                if (indexedAsHash(input.type)) {
                    // 数组和动态类型的 indexed 参数存储的是 keccak256 hash
                    var result = try alloc.alloc(u8, topic.len + 10);
                    const prefix = "hash:0x";
                    @memcpy(result[0..prefix.len], prefix);
                    @memcpy(result[prefix.len..], topic);
                    try fields.append(alloc, .{ .name = input.name, .value = result });
                } else {
                    // 静态类型：topic 中直接是 32 字节值（带 0x 前缀）
                    // 去掉 0x 前缀后取最后 64 个 hex 字符
                    const topic_hex = if (std.mem.startsWith(u8, topic, "0x")) topic[2..] else topic;
                    const word = if (topic_hex.len >= 64) topic_hex[topic_hex.len - 64 ..] else topic_hex;
                    const decoded = try decodeStaticValue(alloc, input.type, word);
                    try fields.append(alloc, .{ .name = input.name, .value = decoded });
                }
                topic_idx += 1;
            }
        } else {
            // 从 data 中解析
            const word_start = data_word_idx * 64;
            if (isDynamicType(input.type)) {
                // 动态类型：当前 word 是偏移量（以字节为单位）
                if (word_start <= std.math.maxInt(usize) - 64 and word_start + 64 <= hex_data.len) {
                    const offset_word = hex_data[word_start .. word_start + 64];
                    const offset_u256 = hexWordToU256(offset_word);
                    // 恶意链上数据可能给出超大 u256 偏移，@intCast 到 usize 会溢出 panic
                    if (offset_u256 > std.math.maxInt(usize)) {
                        try fields.append(alloc, .{ .name = input.name, .value = try alloc.dupe(u8, "0x") });
                    } else {
                        const offset_bytes: usize = @intCast(offset_u256);
                        if (offset_bytes > std.math.maxInt(usize) / 2) {
                            try fields.append(alloc, .{ .name = input.name, .value = try alloc.dupe(u8, "0x") });
                        } else {
                            const offset_hex = offset_bytes * 2; // 转为 hex 字符数
                            const decoded = try decodeDynamicPayload(alloc, input.type, hex_data, offset_hex);
                            try fields.append(alloc, .{ .name = input.name, .value = decoded });
                        }
                    }
                } else {
                    try fields.append(alloc, .{ .name = input.name, .value = try alloc.dupe(u8, "0x") });
                }
                data_word_idx += 1;
            } else {
                const decoded = try decodeStaticType(alloc, input.type, hex_data, data_word_idx);
                try fields.append(alloc, .{ .name = input.name, .value = decoded });
                data_word_idx +|= staticWordCount(input.type);
            }
        }
    }

    return DecodedLog{
        .event_name = event.name,
        .fields = try fields.toOwnedSlice(alloc),
    };
}

test "parseAbiJson basic" {
    const alloc = std.testing.allocator;
    const abi_json =
        \\[{"type":"event","name":"Transfer","inputs":[
        \\  {"name":"from","type":"address","indexed":true},
        \\  {"name":"to","type":"address","indexed":true},
        \\  {"name":"value","type":"uint256","indexed":false}
        \\]}]
    ;

    var contract = try parseAbiJson(alloc, abi_json);
    defer contract.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), contract.events.len);
    try std.testing.expectEqualStrings("Transfer", contract.events[0].name);
    try std.testing.expectEqual(@as(usize, 3), contract.events[0].inputs.len);
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("address"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("uint256"));
    try std.testing.expectEqualStrings("INTEGER", abiTypeToSqlType("bool"));
}

test "decodeLog static types" {
    const alloc = std.testing.allocator;
    const event = AbiEvent{
        .name = "Transfer",
        .inputs = &.{
            .{ .name = "from", .type = "address", .indexed = true },
            .{ .name = "to", .type = "address", .indexed = true },
            .{ .name = "value", .type = "uint256", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };

    // topic0 = 事件签名，topic1 = from，topic2 = to
    const topics = &.{
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        "0x0000000000000000000000001111111111111111111111111111111111111111",
        "0x0000000000000000000000002222222222222222222222222222222222222222",
    };
    // value = 0x1234, padded to 32 bytes
    const data = "0x0000000000000000000000000000000000000000000000000000000000001234";

    const decoded = try decodeLog(alloc, &event, topics, data);
    defer {
        for (decoded.fields) |f| alloc.free(f.value);
        alloc.free(decoded.fields);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded.fields.len);
    try std.testing.expectEqualStrings("from", decoded.fields[0].name);
    try std.testing.expectEqualStrings("0x1111111111111111111111111111111111111111", decoded.fields[0].value);
    try std.testing.expectEqualStrings("to", decoded.fields[1].name);
    try std.testing.expectEqualStrings("0x2222222222222222222222222222222222222222", decoded.fields[1].value);
    try std.testing.expectEqualStrings("value", decoded.fields[2].name);
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000000000000000000000001234", decoded.fields[2].value);
}

test "decodeLog string dynamic type" {
    const alloc = std.testing.allocator;
    const event = AbiEvent{
        .name = "Message",
        .inputs = &.{
            .{ .name = "sender", .type = "address", .indexed = false },
            .{ .name = "content", .type = "string", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };

    const topics = &.{};
    // ABI encoding for: address + string
    // Heads: [address, offset_to_string]
    // Tails: [length, data]
    // offset = 64 (0x40) = 2 head words
    const data = "0x" ++
        "000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ // address (word 0)
        "0000000000000000000000000000000000000000000000000000000000000040" ++ // offset = 64 (word 1)
        "0000000000000000000000000000000000000000000000000000000000000005" ++ // length = 5 (word 2)
        "68656c6c6f000000000000000000000000000000000000000000000000000000"; // "hello" (word 3)

    const decoded = try decodeLog(alloc, &event, topics, data);
    defer {
        for (decoded.fields) |f| alloc.free(f.value);
        alloc.free(decoded.fields);
    }

    try std.testing.expectEqual(@as(usize, 2), decoded.fields.len);
    try std.testing.expectEqualStrings("sender", decoded.fields[0].name);
    try std.testing.expectEqualStrings("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", decoded.fields[0].value);
    try std.testing.expectEqualStrings("content", decoded.fields[1].name);
    // string 解码返回 hex 格式：0x68656c6c6f
    try std.testing.expectEqualStrings("0x68656c6c6f", decoded.fields[1].value);
}

test "decodeLog bytes dynamic type" {
    const alloc = std.testing.allocator;
    const event = AbiEvent{
        .name = "Data",
        .inputs = &.{
            .{ .name = "payload", .type = "bytes", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };

    const topics = &.{};
    // bytes: 1 dynamic param, offset = 32 (0x20), length = 3, data = 0x112233
    const data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++ // offset = 32
        "0000000000000000000000000000000000000000000000000000000000000003" ++ // length = 3
        "1122330000000000000000000000000000000000000000000000000000000000"; // data

    const decoded = try decodeLog(alloc, &event, topics, data);
    defer {
        for (decoded.fields) |f| alloc.free(f.value);
        alloc.free(decoded.fields);
    }

    try std.testing.expectEqual(@as(usize, 1), decoded.fields.len);
    try std.testing.expectEqualStrings("payload", decoded.fields[0].name);
    try std.testing.expectEqualStrings("0x112233", decoded.fields[0].value);
}

test "abiTypeToSqlType" {
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("address"));
    try std.testing.expectEqualStrings("INTEGER", abiTypeToSqlType("bool"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("uint256"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("int128"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("bytes32"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("string"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("bytes"));
    try std.testing.expectEqualStrings("TEXT", abiTypeToSqlType("unknown"));
}

test "isDynamicType" {
    try std.testing.expect(isDynamicType("string"));
    try std.testing.expect(isDynamicType("bytes"));
    try std.testing.expect(isDynamicType("bytes32[]"));
    try std.testing.expect(isDynamicType("uint256[]"));
    try std.testing.expect(isDynamicType("string[2]"));
    try std.testing.expect(isDynamicType("uint256[][2]"));
    try std.testing.expect(!isDynamicType("uint256[4]"));
    try std.testing.expect(!isDynamicType("uint256[2][3]"));
    try std.testing.expect(!isDynamicType("address"));
    try std.testing.expect(!isDynamicType("bool"));
    try std.testing.expect(!isDynamicType("uint256"));
    try std.testing.expect(!isDynamicType("bytes32"));
    try std.testing.expect(indexedAsHash("uint256[4]"));
    try std.testing.expect(indexedAsHash("string"));
    try std.testing.expect(!indexedAsHash("uint256"));
    try std.testing.expect(!indexedAsHash("bytes32"));
    try std.testing.expect(!isDynamicType("(uint256,uint256)"));
    try std.testing.expect(isDynamicType("(uint256,string)"));
    try std.testing.expect(isDynamicType("(uint256,uint256)[]"));
    try std.testing.expect(!isDynamicType("(uint256,uint256)[2]"));
    try std.testing.expect(indexedAsHash("(uint256,uint256)"));
    try std.testing.expectEqual(@as(usize, 2), staticWordCount("(uint256,uint256)"));
    try std.testing.expectEqual(@as(usize, 4), staticWordCount("(uint256,uint256)[2]"));
    try std.testing.expectEqual(@as(usize, 2), staticWordCount("(uint256,string)"));
    try std.testing.expectEqual(@as(usize, 2), staticWordCount("uint256[2]"));
    try std.testing.expectEqual(@as(usize, 6), staticWordCount("uint256[2][3]"));
    try std.testing.expectEqual(@as(usize, 1), staticWordCount("uint256[]"));
}

test "decodeLog 数组按元素解码" {
    const alloc = std.testing.allocator;
    const w1 = "0000000000000000000000000000000000000000000000000000000000000001";
    const w2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const w9 = "0000000000000000000000000000000000000000000000000000000000000009";
    const pair = "[\"0x" ++ w1 ++ "\",\"0x" ++ w2 ++ "\"]";

    const fixed = AbiEvent{
        .name = "Fixed",
        .inputs = &.{
            .{ .name = "nums", .type = "uint256[2]", .indexed = false },
            .{ .name = "after", .type = "uint256", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };
    const fixed_log = try decodeLog(alloc, &fixed, &.{}, "0x" ++ w1 ++ w2 ++ w9);
    defer {
        for (fixed_log.fields) |f| alloc.free(f.value);
        alloc.free(fixed_log.fields);
    }
    try std.testing.expectEqualStrings(pair, fixed_log.fields[0].value);
    try std.testing.expectEqualStrings("0x" ++ w9, fixed_log.fields[1].value);

    const dyn = AbiEvent{
        .name = "Dyn",
        .inputs = &.{
            .{ .name = "nums", .type = "uint256[]", .indexed = false },
            .{ .name = "after", .type = "uint256", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };
    // 头部两个 word：偏移 64，然后是 after。数组体在偏移处：长度 2、两个元素。
    const dyn_data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        w9 ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        w1 ++ w2;
    const dyn_log = try decodeLog(alloc, &dyn, &.{}, dyn_data);
    defer {
        for (dyn_log.fields) |f| alloc.free(f.value);
        alloc.free(dyn_log.fields);
    }
    try std.testing.expectEqualStrings(pair, dyn_log.fields[0].value);
    try std.testing.expectEqualStrings("0x" ++ w9, dyn_log.fields[1].value);

    const empty = AbiEvent{
        .name = "Empty",
        .inputs = &.{.{ .name = "nums", .type = "uint256[]", .indexed = false }},
        .signature = std.mem.zeroes([32]u8),
    };
    const empty_data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000000";
    const empty_log = try decodeLog(alloc, &empty, &.{}, empty_data);
    defer {
        for (empty_log.fields) |f| alloc.free(f.value);
        alloc.free(empty_log.fields);
    }
    try std.testing.expectEqualStrings("[]", empty_log.fields[0].value);

    const texts = AbiEvent{
        .name = "Texts",
        .inputs = &.{.{ .name = "parts", .type = "string[]", .indexed = false }},
        .signature = std.mem.zeroes([32]u8),
    };
    const text_data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "6162000000000000000000000000000000000000000000000000000000000000";
    const text_log = try decodeLog(alloc, &texts, &.{}, text_data);
    defer {
        for (text_log.fields) |f| alloc.free(f.value);
        alloc.free(text_log.fields);
    }
    try std.testing.expectEqualStrings("[\"0x6162\"]", text_log.fields[0].value);

    const huge = AbiEvent{
        .name = "Huge",
        .inputs = &.{.{ .name = "nums", .type = "uint256[]", .indexed = false }},
        .signature = std.mem.zeroes([32]u8),
    };
    const huge_data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000401";
    const huge_log = try decodeLog(alloc, &huge, &.{}, huge_data);
    defer {
        for (huge_log.fields) |f| alloc.free(f.value);
        alloc.free(huge_log.fields);
    }
    try std.testing.expectEqualStrings("0x", huge_log.fields[0].value);
}

test "decodeLog 元组按成员解码且签名用展开类型" {
    const alloc = std.testing.allocator;
    const w1 = "0000000000000000000000000000000000000000000000000000000000000001";
    const w2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const w9 = "0000000000000000000000000000000000000000000000000000000000000009";

    const fixed = AbiEvent{
        .name = "Filled",
        .inputs = &.{
            .{ .name = "order", .type = "(uint256,uint256)", .indexed = false },
            .{ .name = "tip", .type = "uint256", .indexed = false },
        },
        .signature = std.mem.zeroes([32]u8),
    };
    const fixed_log = try decodeLog(alloc, &fixed, &.{}, "0x" ++ w1 ++ w2 ++ w9);
    defer {
        for (fixed_log.fields) |f| alloc.free(f.value);
        alloc.free(fixed_log.fields);
    }
    try std.testing.expectEqualStrings("[\"0x" ++ w1 ++ "\",\"0x" ++ w2 ++ "\"]", fixed_log.fields[0].value);
    try std.testing.expectEqualStrings("0x" ++ w9, fixed_log.fields[1].value);

    const dyn = AbiEvent{
        .name = "Note",
        .inputs = &.{.{ .name = "body", .type = "(uint256,string)", .indexed = false }},
        .signature = std.mem.zeroes([32]u8),
    };
    const dyn_data = "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        w9 ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "6162000000000000000000000000000000000000000000000000000000000000";
    const dyn_log = try decodeLog(alloc, &dyn, &.{}, dyn_data);
    defer {
        for (dyn_log.fields) |f| alloc.free(f.value);
        alloc.free(dyn_log.fields);
    }
    try std.testing.expectEqualStrings("[\"0x" ++ w9 ++ "\",\"0x6162\"]", dyn_log.fields[0].value);

    const json =
        \\[{"type":"event","name":"Filled","inputs":[
        \\  {"name":"order","type":"tuple","indexed":false,"components":[
        \\    {"name":"maker","type":"uint256"},
        \\    {"name":"taker","type":"uint256"}
        \\  ]},
        \\  {"name":"tip","type":"uint256","indexed":false}
        \\]}]
    ;
    var contract = try parseAbiJson(alloc, json);
    defer contract.deinit(alloc);
    const ev = contract.findEventByName("Filled").?;
    try std.testing.expectEqualStrings("(uint256,uint256)", ev.inputs[0].type);
    try std.testing.expectEqualStrings("uint256", ev.inputs[1].type);
    var expect_sig: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("Filled((uint256,uint256),uint256)", &expect_sig, .{});
    try std.testing.expect(std.mem.eql(u8, &ev.signature, &expect_sig));
}

test "hexWordToU256" {
    try std.testing.expectEqual(@as(u256, 0), hexWordToU256(""));
    try std.testing.expectEqual(@as(u256, 0), hexWordToU256("0000"));
    try std.testing.expectEqual(@as(u256, 1), hexWordToU256("0000000000000000000000000000000000000000000000000000000000000001"));
    try std.testing.expectEqual(@as(u256, 255), hexWordToU256("00000000000000000000000000000000000000000000000000000000000000ff"));
    try std.testing.expectEqual(@as(u256, 0xABCD), hexWordToU256("000000000000000000000000000000000000000000000000000000000000ABCD"));
}

test "AbiContract findEventByName and findEventByTopic0" {
    const alloc = std.testing.allocator;

    // 构造两个事件（内存所有权转移给 events，由 events.deinit 统一释放）
    var evt1_inputs = try alloc.alloc(AbiEventInput, 2);
    evt1_inputs[0] = .{ .name = try alloc.dupe(u8, "from"), .type = try alloc.dupe(u8, "address"), .indexed = true };
    evt1_inputs[1] = .{ .name = try alloc.dupe(u8, "to"), .type = try alloc.dupe(u8, "address"), .indexed = true };

    var evt2_inputs = try alloc.alloc(AbiEventInput, 1);
    evt2_inputs[0] = .{ .name = try alloc.dupe(u8, "owner"), .type = try alloc.dupe(u8, "address"), .indexed = true };

    var sig1: [32]u8 = undefined;
    @memset(&sig1, 0xAA);
    var sig2: [32]u8 = undefined;
    @memset(&sig2, 0xBB);

    var events = try alloc.alloc(AbiEvent, 2);
    events[0] = .{ .name = try alloc.dupe(u8, "Transfer"), .inputs = evt1_inputs, .signature = sig1 };
    events[1] = .{ .name = try alloc.dupe(u8, "Approval"), .inputs = evt2_inputs, .signature = sig2 };
    defer {
        for (events) |*e| e.deinit(alloc);
        alloc.free(events);
    }

    const contract = AbiContract{ .events = events, .functions = &.{} };

    try std.testing.expect(contract.findEventByName("Transfer") != null);
    try std.testing.expect(contract.findEventByName("Approval") != null);
    try std.testing.expect(contract.findEventByName("NonExistent") == null);

    try std.testing.expect(contract.findEventByTopic0(&sig1) != null);
    try std.testing.expect(contract.findEventByTopic0(&sig2) != null);
    var sig3: [32]u8 = undefined;
    @memset(&sig3, 0xCC);
    try std.testing.expect(contract.findEventByTopic0(&sig3) == null);
}

// ============================================================================
// eth_call ABI encoding / decoding
// ============================================================================

/// Compute the 4-byte function selector from a signature like "balanceOf(address)".
pub fn encodeFunctionCall(alloc: std.mem.Allocator, signature: []const u8, args: []const []const u8) ![]u8 {
    // Compute selector: keccak256(signature)[0..4]
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(signature, &hash, .{});

    // Build result: "0x" + 8-char selector + 64-char-per-arg
    const prefix = "0x";
    const total_len = prefix.len + 8 + (64 * args.len);
    const result = try alloc.alloc(u8, total_len);
    errdefer alloc.free(result);
    @memcpy(result[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    // Append selector (first 4 bytes as hex)
    for (hash[0..4]) |byte| {
        result[pos] = std.fmt.digitToChar(byte >> 4, .lower);
        result[pos + 1] = std.fmt.digitToChar(byte & 0x0F, .lower);
        pos += 2;
    }

    for (args) |arg| {
        const clean = if (std.mem.startsWith(u8, arg, "0x") or std.mem.startsWith(u8, arg, "0X")) arg[2..] else arg;
        const pad_count = if (clean.len < 64) 64 - clean.len else 0;
        @memset(result[pos .. pos + pad_count], '0');
        pos += pad_count;
        @memcpy(result[pos .. pos + clean.len], clean);
        pos += clean.len;
    }

    return result;
}

/// Decode the result of an eth_call into a human-readable string.
/// abi_type is like "uint256", "address", "(uint256,address)", "uint256[]".
pub fn decodeCallResult(alloc: std.mem.Allocator, abi_type: []const u8, result_hex: []const u8) ![]u8 {
    const hex = if (std.mem.startsWith(u8, result_hex, "0x") or std.mem.startsWith(u8, result_hex, "0X"))
        result_hex[2..]
    else
        result_hex;

    // 多返回值的括号就是最外层元组，成员直接排在返回值开头。
    // 单个动态结构体不是这条路径：它外面还有一层偏移，走 decodeSingleOutput。
    if (tupleInner(abi_type)) |inner| {
        var cursor: usize = 0;
        return decodeCallTuple(alloc, inner, hex, &cursor, 0);
    }
    if (callTypeIsStructured(abi_type)) {
        var cursor: usize = 0;
        return decodeCallAt(alloc, abi_type, hex, &cursor, 0);
    }
    return decodeCallScalar(alloc, abi_type, hex);
}

/// 函数只有一个返回值。动态类型（含动态结构体）先读偏移，静态结构体直接展开。
pub fn decodeSingleOutput(alloc: std.mem.Allocator, abi_type: []const u8, result_hex: []const u8) ![]u8 {
    const hex = if (std.mem.startsWith(u8, result_hex, "0x") or std.mem.startsWith(u8, result_hex, "0X"))
        result_hex[2..]
    else
        result_hex;
    if (isDynamicType(abi_type)) {
        var cursor: usize = 0;
        return decodeCallAt(alloc, abi_type, hex, &cursor, 0);
    }
    return decodeCallResult(alloc, abi_type, result_hex);
}

fn callTypeIsStructured(abi_type: []const u8) bool {
    if (abi_type.len >= 2 and abi_type[0] == '(' and abi_type[abi_type.len - 1] == ')') return true;
    if (parseArray(abi_type) != null) return true;
    return isDynamicType(abi_type);
}

fn callWord(hex: []const u8, word_index: usize) ?[]const u8 {
    if (word_index > std.math.maxInt(usize) / 64) return null;
    const start = word_index * 64;
    if (start > hex.len or start + 64 > hex.len) return null;
    return hex[start .. start + 64];
}

fn decodeCallAt(alloc: std.mem.Allocator, abi_type: []const u8, hex: []const u8, word_index: *usize, base_hex: usize) std.mem.Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, abi_type, " \t");
    if (isDynamicType(trimmed)) {
        const word = callWord(hex, word_index.*) orelse return try alloc.dupe(u8, "0x");
        const off = hexWordToU256(word);
        word_index.* +|= 1;
        if (off > @as(u256, std.math.maxInt(usize) / 2)) return try alloc.dupe(u8, "0x");
        const rel: usize = @as(usize, @intCast(off)) * 2;
        if (base_hex > std.math.maxInt(usize) - rel) return try alloc.dupe(u8, "0x");
        return decodeCallTail(alloc, trimmed, hex, base_hex + rel);
    }
    if (tupleInner(trimmed)) |inner| {
        const start_hex = if (word_index.* > std.math.maxInt(usize) / 64) base_hex else word_index.* * 64;
        return decodeCallTuple(alloc, inner, hex, word_index, start_hex);
    }
    const value = try decodeCallStatic(alloc, trimmed, hex, word_index.*);
    word_index.* +|= staticWordCount(trimmed);
    return value;
}

/// `base_hex` 是当前元组编码的起点。动态成员的偏移相对这里。
fn decodeCallTuple(alloc: std.mem.Allocator, inner: []const u8, hex: []const u8, word_index: *usize, base_hex: usize) std.mem.Allocator.Error![]u8 {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| alloc.free(it);
        items.deinit(alloc);
    }
    var i: usize = 0;
    while (nextTupleField(inner, i)) |step| {
        i = step.next;
        const val = try decodeCallAt(alloc, step.field, hex, word_index, base_hex);
        items.append(alloc, val) catch |e| {
            alloc.free(val);
            return e;
        };
    }
    const owned = try items.toOwnedSlice(alloc);
    defer {
        for (owned) |it| alloc.free(it);
        alloc.free(owned);
    }
    return joinJsonArray(alloc, owned);
}

fn decodeCallStatic(alloc: std.mem.Allocator, abi_type: []const u8, hex: []const u8, word_index: usize) std.mem.Allocator.Error![]u8 {
    if (parseArray(abi_type)) |arr| {
        const n = arr.fixed orelse return try alloc.dupe(u8, "0x");
        if (n > max_array_len) return try alloc.dupe(u8, "0x");
        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |it| alloc.free(it);
            items.deinit(alloc);
        }
        var w = word_index;
        const words = staticWordCount(arr.inner);
        for (0..n) |_| {
            const elem = try decodeCallStatic(alloc, arr.inner, hex, w);
            items.append(alloc, elem) catch |e| {
                alloc.free(elem);
                return e;
            };
            w +|= words;
        }
        const owned = try items.toOwnedSlice(alloc);
        defer {
            for (owned) |it| alloc.free(it);
            alloc.free(owned);
        }
        return joinJsonArray(alloc, owned);
    }
    if (tupleInner(abi_type)) |inner| {
        if (word_index > std.math.maxInt(usize) / 64) return try alloc.dupe(u8, "0x");
        var cursor = word_index;
        return decodeCallTuple(alloc, inner, hex, &cursor, word_index * 64);
    }
    const word = callWord(hex, word_index) orelse return try alloc.dupe(u8, "0x");
    return decodeCallScalar(alloc, abi_type, word);
}

fn decodeCallTail(alloc: std.mem.Allocator, abi_type: []const u8, hex: []const u8, offset_hex: usize) std.mem.Allocator.Error![]u8 {
    if (std.mem.eql(u8, abi_type, "string") or std.mem.eql(u8, abi_type, "bytes")) {
        return decodeDynamicValue(alloc, hex, offset_hex);
    }
    if (tupleInner(abi_type)) |inner| {
        if (offset_hex % 64 != 0) return try alloc.dupe(u8, "0x");
        var cursor = offset_hex / 64;
        return decodeCallTuple(alloc, inner, hex, &cursor, offset_hex);
    }
    const arr = parseArray(abi_type) orelse return try alloc.dupe(u8, "0x");
    if (arr.fixed) |n| {
        if (isDynamicType(arr.inner)) return decodeCallOffsetArray(alloc, arr.inner, n, hex, offset_hex);
        if (offset_hex % 64 != 0) return try alloc.dupe(u8, "0x");
        return decodeCallStatic(alloc, abi_type, hex, offset_hex / 64);
    }
    if (offset_hex > std.math.maxInt(usize) - 64 or offset_hex + 64 > hex.len) return try alloc.dupe(u8, "0x");
    const len_u256 = hexWordToU256(hex[offset_hex .. offset_hex + 64]);
    if (len_u256 > max_array_len) return try alloc.dupe(u8, "0x");
    const n: usize = @intCast(len_u256);
    const body = offset_hex + 64;
    if (isDynamicType(arr.inner)) return decodeCallOffsetArray(alloc, arr.inner, n, hex, body);
    if (body % 64 != 0) return try alloc.dupe(u8, "0x");
    return decodeCallElems(alloc, arr.inner, n, hex, body / 64);
}

fn decodeCallElems(alloc: std.mem.Allocator, inner: []const u8, count: usize, hex: []const u8, word_index: usize) std.mem.Allocator.Error![]u8 {
    if (count > max_array_len) return try alloc.dupe(u8, "0x");
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| alloc.free(it);
        items.deinit(alloc);
    }
    var w = word_index;
    const words = staticWordCount(inner);
    for (0..count) |_| {
        const elem = try decodeCallStatic(alloc, inner, hex, w);
        items.append(alloc, elem) catch |e| {
            alloc.free(elem);
            return e;
        };
        w +|= words;
    }
    const owned = try items.toOwnedSlice(alloc);
    defer {
        for (owned) |it| alloc.free(it);
        alloc.free(owned);
    }
    return joinJsonArray(alloc, owned);
}

fn decodeCallScalar(alloc: std.mem.Allocator, abi_type: []const u8, hex: []const u8) ![]u8 {
    if (std.mem.eql(u8, abi_type, "bool")) {
        if (hex.len >= 64) {
            for (hex[0..64]) |c| {
                if (c != '0') return try alloc.dupe(u8, "true");
            }
        }
        return try alloc.dupe(u8, "false");
    }

    if (std.mem.eql(u8, abi_type, "address")) {
        if (hex.len >= 64) {
            const word = hex[0..64];
            return try std.fmt.allocPrint(alloc, "0x{s}", .{word[word.len - 40 ..]});
        }
    }

    if (std.mem.startsWith(u8, abi_type, "uint") or std.mem.startsWith(u8, abi_type, "int")) {
        if (hex.len >= 64) {
            const word = hex[0..64];
            var start: usize = 0;
            while (start < word.len and word[start] == '0') : (start += 1) {}
            if (start == word.len) return try alloc.dupe(u8, "0");
            const trimmed = word[start..];
            const val = std.fmt.parseInt(u256, trimmed, 16) catch return try alloc.dupe(u8, hex);
            const signed = std.mem.startsWith(u8, abi_type, "int");
            if (signed and callWordNegative(word)) {
                return try std.fmt.allocPrint(alloc, "-{d}", .{0 -% val});
            }
            return try std.fmt.allocPrint(alloc, "{d}", .{val});
        }
    }

    if (std.mem.eql(u8, abi_type, "bytes32") or std.mem.startsWith(u8, abi_type, "bytes")) {
        if (hex.len >= 64) {
            return try std.fmt.allocPrint(alloc, "0x{s}", .{hex[0..64]});
        }
    }

    return try std.fmt.allocPrint(alloc, "0x{s}", .{hex});
}

fn callWordNegative(word: []const u8) bool {
    if (word.len == 0) return false;
    return switch (word[0]) {
        '8'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}
fn decodeCallOffsetArray(alloc: std.mem.Allocator, inner: []const u8, count: usize, hex: []const u8, start_hex: usize) std.mem.Allocator.Error![]u8 {
    if (count > max_array_len) return try alloc.dupe(u8, "0x");
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |it| alloc.free(it);
        items.deinit(alloc);
    }
    for (0..count) |i| {
        const word_at = start_hex +| (i *| 64);
        if (word_at > std.math.maxInt(usize) - 64 or word_at + 64 > hex.len) {
            try items.append(alloc, try alloc.dupe(u8, "0x"));
            continue;
        }
        const off = hexWordToU256(hex[word_at .. word_at + 64]);
        if (off > @as(u256, std.math.maxInt(usize) / 2)) {
            try items.append(alloc, try alloc.dupe(u8, "0x"));
            continue;
        }
        const hex_off: usize = @as(usize, @intCast(off)) * 2;
        if (start_hex > std.math.maxInt(usize) - hex_off) {
            try items.append(alloc, try alloc.dupe(u8, "0x"));
            continue;
        }
        const elem = try decodeCallTail(alloc, inner, hex, start_hex + hex_off);
        items.append(alloc, elem) catch |e| {
            alloc.free(elem);
            return e;
        };
    }
    const owned = try items.toOwnedSlice(alloc);
    defer {
        for (owned) |it| alloc.free(it);
        alloc.free(owned);
    }
    return joinJsonArray(alloc, owned);
}

test "encodeFunctionCall basic" {
    const alloc = std.testing.allocator;

    // balanceOf(address)
    const result = try encodeFunctionCall(alloc, "balanceOf(address)", &.{"0x6b175474e89094c44da98b954eedeac495271d0f"});
    defer alloc.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "0x"));
    try std.testing.expectEqual(@as(usize, 74), result.len); // 2 + 8 + 64
}

test "encodeFunctionCall multi-arg" {
    const alloc = std.testing.allocator;

    const result = try encodeFunctionCall(alloc, "transfer(address,uint256)", &.{ "0x1111111111111111111111111111111111111111", "0x00000000000000000000000000000000000000000000000000000000000003e8" });
    defer alloc.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "0x"));
    try std.testing.expectEqual(@as(usize, 2 + 8 + 64 + 64), result.len);
}

test "decodeCallResult uint256" {
    const alloc = std.testing.allocator;

    const result = try decodeCallResult(alloc, "uint256", "0x00000000000000000000000000000000000000000000000000000000000003e8");
    defer alloc.free(result);

    try std.testing.expectEqualStrings("1000", result);
}

test "decodeCallResult address" {
    const alloc = std.testing.allocator;

    const result = try decodeCallResult(alloc, "address", "0x0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f");
    defer alloc.free(result);

    try std.testing.expectEqualStrings("0x6b175474e89094c44da98b954eedeac495271d0f", result);
}

test "decodeCallResult bool" {
    const alloc = std.testing.allocator;

    const t = try decodeCallResult(alloc, "bool", "0x0000000000000000000000000000000000000000000000000000000000000001");
    defer alloc.free(t);
    try std.testing.expectEqualStrings("true", t);

    const f = try decodeCallResult(alloc, "bool", "0x0000000000000000000000000000000000000000000000000000000000000000");
    defer alloc.free(f);
    try std.testing.expectEqualStrings("false", f);
}

test "decodeCallResult 元组、数组和负数" {
    const alloc = std.testing.allocator;
    const w1 = "0000000000000000000000000000000000000000000000000000000000000001";
    const w2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const w9 = "0000000000000000000000000000000000000000000000000000000000000009";
    const addr = "0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f";

    const pair = try decodeCallResult(alloc, "(uint256,address)", "0x" ++ w9 ++ addr);
    defer alloc.free(pair);
    try std.testing.expectEqualStrings("[\"9\",\"0x6b175474e89094c44da98b954eedeac495271d0f\"]", pair);

    const fixed = try decodeCallResult(alloc, "uint256[2]", "0x" ++ w1 ++ w2);
    defer alloc.free(fixed);
    try std.testing.expectEqualStrings("[\"1\",\"2\"]", fixed);

    const dyn = try decodeCallResult(alloc, "uint256[]", "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        w1 ++ w2);
    defer alloc.free(dyn);
    try std.testing.expectEqualStrings("[\"1\",\"2\"]", dyn);

    const mixed = try decodeCallResult(alloc, "(uint256[],uint256)", "0x" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        w9 ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        w1 ++ w2);
    defer alloc.free(mixed);
    try std.testing.expectEqualStrings("[[\"1\",\"2\"],\"9\"]", mixed);

    const neg = try decodeCallResult(alloc, "int256", "0x" ++ "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    defer alloc.free(neg);
    try std.testing.expectEqualStrings("-1", neg);
}

test "parseAbiJson 解析 function 与 returnType" {
    const alloc = std.testing.allocator;
    const json =
        \\[
        \\  {"type":"function","name":"balanceOf","inputs":[{"name":"","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
        \\  {"type":"function","name":"getPair","inputs":[],"outputs":[{"name":"a","type":"uint256"},{"name":"b","type":"address"}]},
        \\  {"type":"event","name":"Transfer","inputs":[],"anonymous":false}
        \\]
    ;
    var contract = try parseAbiJson(alloc, json);
    defer contract.deinit(alloc);

    // 单返回值：直接返回类型
    const bal = contract.findFunctionByName("balanceOf").?;
    try std.testing.expectEqualStrings("uint256", bal.returnType(alloc).?);

    // 多返回值：tuple 类型（heap 分配）
    const gp = contract.findFunctionByName("getPair").?;
    const t = gp.returnType(alloc).?;
    defer alloc.free(t);
    try std.testing.expectEqualStrings("(uint256,address)", t);

    // 事件仍正常解析
    try std.testing.expect(contract.findEventByName("Transfer") != null);
}

test "函数结构体返回值按单个输出和多返回值分开解码" {
    const alloc = std.testing.allocator;
    const w1 = "0000000000000000000000000000000000000000000000000000000000000001";
    const w2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const w7 = "0000000000000000000000000000000000000000000000000000000000000007";
    const w9 = "0000000000000000000000000000000000000000000000000000000000000009";
    const off20 = "0000000000000000000000000000000000000000000000000000000000000020";
    const off40 = "0000000000000000000000000000000000000000000000000000000000000040";
    const len2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const ab = "6162000000000000000000000000000000000000000000000000000000000000";

    const json =
        \\[{"type":"function","name":"quote","inputs":[],"outputs":[
        \\  {"name":"order","type":"tuple","components":[
        \\    {"name":"maker","type":"uint256"},
        \\    {"name":"taker","type":"address"}
        \\  ]}
        \\]}]
    ;
    var contract = try parseAbiJson(alloc, json);
    defer contract.deinit(alloc);
    const quote = contract.findFunctionByName("quote").?;
    try std.testing.expectEqualStrings("(uint256,address)", quote.outputs[0].type);
    try std.testing.expectEqualStrings("(uint256,address)", quote.returnType(alloc).?);

    const fixed = try decodeSingleOutput(alloc, "(uint256,uint256)", "0x" ++ w1 ++ w2);
    defer alloc.free(fixed);
    try std.testing.expectEqualStrings("[\"1\",\"2\"]", fixed);

    const one = try decodeSingleOutput(alloc, "(uint256,string)", "0x" ++ off20 ++ w9 ++ off40 ++ len2 ++ ab);
    defer alloc.free(one);
    try std.testing.expectEqualStrings("[\"9\",\"0x6162\"]", one);

    const nested = try decodeCallResult(alloc, "(uint256,(uint256,string))", "0x" ++ w7 ++ off40 ++ w9 ++ off40 ++ len2 ++ ab);
    defer alloc.free(nested);
    try std.testing.expectEqualStrings("[\"7\",[\"9\",\"0x6162\"]]", nested);
}
