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

/// ABI 合约定义
pub const AbiContract = struct {
    events: []AbiEvent,

    pub fn deinit(self: *AbiContract, alloc: std.mem.Allocator) void {
        for (self.events) |*e| {
            e.deinit(alloc);
        }
        alloc.free(self.events);
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

    const root = parsed.value.array;
    for (root.items) |item| {
        const obj = item.object;
        const type_val = obj.get("type") orelse continue;
        if (!std.mem.eql(u8, type_val.string, "event")) continue;

        const name = obj.get("name").?.string;

        var inputs: std.ArrayList(AbiEventInput) = .empty;
        errdefer inputs.deinit(alloc);

        const inputs_arr = obj.get("inputs").?.array;
        for (inputs_arr.items) |inp| {
            const inp_obj = inp.object;
            try inputs.append(alloc, .{
                .name = try alloc.dupe(u8, inp_obj.get("name").?.string),
                .type = try alloc.dupe(u8, inp_obj.get("type").?.string),
                .indexed = if (inp_obj.get("indexed")) |v| v.bool else false,
            });
        }

        // 计算事件签名：keccak256("EventName(type1,type2,...)")
        var sig_buf: [256]u8 = undefined;
        const sig_str = try formatEventSignature(&sig_buf, name, inputs.items);
        var signature: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(sig_str, &signature, .{});

        try events.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .inputs = try inputs.toOwnedSlice(alloc),
            .signature = signature,
        });
    }

    return AbiContract{
        .events = try events.toOwnedSlice(alloc),
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

/// 格式化事件签名字符串（用于计算 topic0）
fn formatEventSignature(buf: []u8, name: []const u8, inputs: []const AbiEventInput) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll(name);
    try w.writeByte('(');
    for (inputs, 0..) |inp, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(inp.type);
    }
    try w.writeByte(')');
    return buf[0..w.end];
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

/// 判断 ABI 类型是否为动态类型（需要偏移量解析）
fn isDynamicType(abi_type: []const u8) bool {
    if (std.mem.eql(u8, abi_type, "string")) return true;
    if (std.mem.eql(u8, abi_type, "bytes")) return true;
    // 数组类型（固定大小或动态）都是动态的
    if (std.mem.indexOfScalar(u8, abi_type, '[') != null) return true;
    return false;
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

    // 读取偏移量指向的 length（前 64 hex 字符 = 32 字节）
    if (offset_hex + 64 > hex_data.len) return try alloc.dupe(u8, "0x");
    const len_word = hex_data[offset_hex .. offset_hex + 64];
    const len = @as(usize, @intCast(hexWordToU256(len_word)));

    const data_start = offset_hex + 64;
    const hex_len = len * 2; // 每字节 2 个 hex 字符
    if (data_start + hex_len > hex_data.len) return try alloc.dupe(u8, "0x");

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
                if (isDynamicType(input.type)) {
                    // 动态类型的 indexed 参数存储的是 keccak256 hash
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
                if (word_start + 64 <= hex_data.len) {
                    const offset_word = hex_data[word_start .. word_start + 64];
                    const offset_bytes = @as(usize, @intCast(hexWordToU256(offset_word)));
                    const offset_hex = offset_bytes * 2; // 转为 hex 字符数
                    const decoded = try decodeDynamicValue(alloc, data, offset_hex);
                    try fields.append(alloc, .{ .name = input.name, .value = decoded });
                } else {
                    try fields.append(alloc, .{ .name = input.name, .value = try alloc.dupe(u8, "0x") });
                }
                data_word_idx += 1;
            } else {
                // 静态类型：直接取 64 hex 字符
                if (word_start + 64 <= hex_data.len) {
                    const word = hex_data[word_start .. word_start + 64];
                    const decoded = try decodeStaticValue(alloc, input.type, word);
                    try fields.append(alloc, .{ .name = input.name, .value = decoded });
                } else if (word_start < hex_data.len) {
                    const word = hex_data[word_start..];
                    const decoded = try decodeStaticValue(alloc, input.type, word);
                    try fields.append(alloc, .{ .name = input.name, .value = decoded });
                } else {
                    try fields.append(alloc, .{ .name = input.name, .value = try alloc.dupe(u8, "0x0") });
                }
                data_word_idx += 1;
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
        .signature = .{0} ** 32,
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
        .signature = .{0} ** 32,
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
        .signature = .{0} ** 32,
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
    try std.testing.expect(isDynamicType("uint256[4]"));
    try std.testing.expect(!isDynamicType("address"));
    try std.testing.expect(!isDynamicType("bool"));
    try std.testing.expect(!isDynamicType("uint256"));
    try std.testing.expect(!isDynamicType("bytes32"));
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

    const contract = AbiContract{ .events = events };

    try std.testing.expect(contract.findEventByName("Transfer") != null);
    try std.testing.expect(contract.findEventByName("Approval") != null);
    try std.testing.expect(contract.findEventByName("NonExistent") == null);

    try std.testing.expect(contract.findEventByTopic0(&sig1) != null);
    try std.testing.expect(contract.findEventByTopic0(&sig2) != null);
    var sig3: [32]u8 = undefined;
    @memset(&sig3, 0xCC);
    try std.testing.expect(contract.findEventByTopic0(&sig3) == null);
}
