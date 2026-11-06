//! RFC-0087, P5.3 (E9): the oracle of the JSON codec, test-only. An encoder and a strict decoder
//! written from E2 and E3 alone, as the design prototype (`persist_model.py` of RFC-0087's
//! Appendix A) has them, with its generators of persistable types and values, ported to Zig and
//! independent of `persist_json.zig`: a model type is a tree, a model value is a tree, the model
//! decoder parses the whole text into a tree before it reads it as a type, and it recurses.
//!
//! `persist_json.zig` must agree with it on every case (RFC-0087 test plan):
//!   PM1  decode(T, encode(T, v)) is v, bit for bit, `-0.0` and NaN included;
//!   PM2  encode(T, v) is the model's canonical text, and the decoder accepts the same text with
//!        any whitespace, members in any order, metadata absent and strings escaped otherwise;
//!   PM3  every refusal of E3 is refused by both, fixed cases for the scalar rules and generated
//!        ones for objects; and texts mutated at random are accepted by both or by neither,
//!        with the same value when both accept.
const std = @import("std");
const types = @import("types.zig");
const persist_json = @import("persist_json.zig");
const run_strings = @import("run_strings.zig");
const keys = @import("map_keys.zig");
const scratch = @import("scratch.zig");

const Allocator = std.mem.Allocator;

// --- model types and values ---------------------------------------------------------------------

const package_names = [_][]const u8{ "/", "/Progress", "/Kit/Save" };
const field_names = [_][]const u8{ "Level", "Score", "Title", "Mode", "Best", "Seen", "Pair", "Flag" };
const type_names = [_][]const u8{ "stats", "profile", "slot", "item", "record" };
const case_names = [_][]const u8{ "Easy", "Normal", "Hard", "Expert", "Mythic" };

const Field = struct { name: u8, value_type: *const MType, default: ?*const MValue };
const Object = struct { package: u8, name: u8, fields: []const Field };
/// `cases` are the first names of `case_names`; P5.6 adds `open`, and `order` for the names an
/// evolved enum has, in its order (`caseName`).
const Enumeration = struct { package: u8, name: u8, cases: u8, open: bool = false, order: ?[]const u8 = null };
const MType = union(enum) {
    logic,
    int,
    float,
    string,
    char,
    char32,
    array: *const MType,
    option: *const MType,
    map: [2]*const MType,
    tuple: []const *const MType,
    record: Object,
    class: Object,
    enumeration: Enumeration,
};
const MValue = union(enum) {
    logic: bool,
    int: i64,
    float: f64,
    string: []const u8,
    char: u32,
    array: []const MValue,
    option: ?*const MValue,
    map: []const [2]MValue,
    tuple: []const MValue,
    object: []const MValue,
    case: u32,
};

fn reachesClass(t: *const MType) bool {
    return switch (t.*) {
        .class => true,
        .array, .option => |inner| reachesClass(inner),
        .map => |pair| reachesClass(pair[0]) or reachesClass(pair[1]),
        .tuple => |elements| for (elements) |element| {
            if (reachesClass(element)) break true;
        } else false,
        .record => |object| for (object.fields) |field| {
            if (reachesClass(field.value_type)) break true;
        } else false,
        else => false,
    };
}

/// The language's `==` on values: one NaN, one zero.
fn same(a: MValue, b: MValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .float => |x| (types.isNan(x) and types.isNan(b.float)) or x == b.float,
        .logic => |x| x == b.logic,
        .int => |x| x == b.int,
        .string => |x| std.mem.eql(u8, x, b.string),
        .char => |x| x == b.char,
        .case => |x| x == b.case,
        .option => |x| if (x == null or b.option == null) x == null and b.option == null else same(x.?.*, b.option.?.*),
        .array, .tuple, .object => |xs| {
            const ys = switch (b) {
                .array, .tuple, .object => |ys| ys,
                else => unreachable,
            };
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| if (!same(x, y)) return false;
            return true;
        },
        .map => |xs| {
            if (xs.len != b.map.len) return false;
            for (xs, b.map) |x, y| if (!same(x[0], y[0]) or !same(x[1], y[1])) return false;
            return true;
        },
    };
}

/// Bit for bit, for round trips: `-0.0` stays `-0.0`.
fn identical(a: MValue, b: MValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .float => |x| if (types.isNan(x) or types.isNan(b.float)) types.isNan(x) and types.isNan(b.float) else @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .option => |x| if (x == null or b.option == null) x == null and b.option == null else identical(x.?.*, b.option.?.*),
        .array, .tuple, .object => |xs| {
            const ys = switch (b) {
                .array, .tuple, .object => |ys| ys,
                else => unreachable,
            };
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| if (!identical(x, y)) return false;
            return true;
        },
        .map => |xs| {
            if (xs.len != b.map.len) return false;
            for (xs, b.map) |x, y| if (!identical(x[0], y[0]) or !identical(x[1], y[1])) return false;
            return true;
        },
        else => same(a, b),
    };
}

// --- the model encoder (E2) ---------------------------------------------------------------------

fn floatText(out: *std.ArrayList(u8), a: Allocator, x: f64) !void {
    if (types.isNan(x)) return out.appendSlice(a, "\"NaN\"");
    if (std.math.isInf(x)) return out.appendSlice(a, if (x < 0) "\"-Inf\"" else "\"Inf\"");
    var buffer: [400]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buffer, "{d}", .{x}));
}

fn stringText(out: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0x08 => try out.appendSlice(a, "\\b"),
        0x0C => try out.appendSlice(a, "\\f"),
        else => if (c < 0x20) {
            var buffer: [6]u8 = undefined;
            try out.appendSlice(a, try std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{c}));
        } else try out.append(a, c),
    };
    try out.append(a, '"');
}

fn objectName(object: Object) []const u8 {
    return type_names[object.name];
}
fn enumName(enumeration: Enumeration) []const u8 {
    return type_names[enumeration.name];
}

fn encode(out: *std.ArrayList(u8), a: Allocator, t: *const MType, v: MValue) Allocator.Error!void {
    var buffer: [32]u8 = undefined;
    switch (t.*) {
        .logic => try out.appendSlice(a, if (v.logic) "true" else "false"),
        .int => try out.appendSlice(a, std.fmt.bufPrint(&buffer, "{d}", .{v.int}) catch unreachable),
        .float => floatText(out, a, v.float) catch return error.OutOfMemory,
        .string => stringText(out, a, v.string) catch return error.OutOfMemory,
        .char, .char32 => try out.appendSlice(a, std.fmt.bufPrint(&buffer, "{d}", .{v.char}) catch unreachable),
        .array => |element| {
            try out.append(a, '[');
            for (v.array, 0..) |x, i| {
                if (i != 0) try out.append(a, ',');
                try encode(out, a, element, x);
            }
            try out.append(a, ']');
        },
        .option => |element| if (v.option) |x| {
            try out.appendSlice(a, "{\"\":");
            try encode(out, a, element, x.*);
            try out.append(a, '}');
        } else try out.appendSlice(a, "false"),
        .map => |pair| {
            try out.append(a, '[');
            for (v.map, 0..) |entry, i| {
                if (i != 0) try out.append(a, ',');
                try out.appendSlice(a, "{\"k\":{\"\":");
                try encode(out, a, pair[0], entry[0]);
                try out.appendSlice(a, "},\"v\":{\"\":");
                try encode(out, a, pair[1], entry[1]);
                try out.appendSlice(a, "}}");
            }
            try out.append(a, ']');
        },
        .tuple => |elements| {
            try out.append(a, '[');
            for (elements, v.tuple, 0..) |element, x, i| {
                if (i != 0) try out.append(a, ',');
                try encode(out, a, element, x);
            }
            try out.append(a, ']');
        },
        .record, .class => |object| {
            try out.appendSlice(a, "{\"$package_name\":");
            stringText(out, a, package_names[object.package]) catch return error.OutOfMemory;
            try out.appendSlice(a, ",\"$class_name\":");
            stringText(out, a, objectName(object)) catch return error.OutOfMemory;
            for (object.fields, v.object) |field, x| {
                try out.appendSlice(a, ",\"x_");
                try out.appendSlice(a, field_names[field.name]);
                try out.appendSlice(a, "\":");
                try encode(out, a, field.value_type, x);
            }
            try out.append(a, '}');
        },
        .enumeration => |enumeration| {
            try out.append(a, '"');
            try out.appendSlice(a, enumName(enumeration));
            try out.appendSlice(a, "::");
            try out.appendSlice(a, caseName(enumeration, v.case));
            try out.append(a, '"');
        },
    }
}

// --- the model decoder (E3): a JSON tree, then a typed walk ---------------------------------------

const Json = union(enum) {
    object: []const Member,
    array: []const Json,
    string: []const u8,
    number: []const u8,
    true_,
    false_,
    null_,
};
const Member = struct { name: []const u8, value: Json };

const Fail = error{ Fail, OutOfMemory };

const Parser = struct {
    text: []const u8,
    at: usize = 0,
    a: Allocator,

    fn ws(self: *Parser) void {
        while (self.at < self.text.len and std.mem.indexOfScalar(u8, " \t\n\r", self.text[self.at]) != null) self.at += 1;
    }
    fn value(self: *Parser) Fail!Json {
        self.ws();
        if (self.at >= self.text.len) return error.Fail;
        const c = self.text[self.at];
        if (c == '{') {
            self.at += 1;
            var members: std.ArrayList(Member) = .empty;
            self.ws();
            if (self.at < self.text.len and self.text[self.at] == '}') {
                self.at += 1;
                return .{ .object = members.items };
            }
            while (true) {
                const key = try self.value();
                if (key != .string) return error.Fail;
                self.ws();
                if (self.at >= self.text.len or self.text[self.at] != ':') return error.Fail;
                self.at += 1;
                try members.append(self.a, .{ .name = key.string, .value = try self.value() });
                self.ws();
                if (self.at < self.text.len and self.text[self.at] == ',') {
                    self.at += 1;
                    continue;
                }
                if (self.at < self.text.len and self.text[self.at] == '}') {
                    self.at += 1;
                    return .{ .object = members.items };
                }
                return error.Fail;
            }
        }
        if (c == '[') {
            self.at += 1;
            var items: std.ArrayList(Json) = .empty;
            self.ws();
            if (self.at < self.text.len and self.text[self.at] == ']') {
                self.at += 1;
                return .{ .array = items.items };
            }
            while (true) {
                try items.append(self.a, try self.value());
                self.ws();
                if (self.at < self.text.len and self.text[self.at] == ',') {
                    self.at += 1;
                    continue;
                }
                if (self.at < self.text.len and self.text[self.at] == ']') {
                    self.at += 1;
                    return .{ .array = items.items };
                }
                return error.Fail;
            }
        }
        if (c == '"') return .{ .string = try self.string() };
        inline for (.{ .{ "true", Json.true_ }, .{ "false", Json.false_ }, .{ "null", Json.null_ } }) |word| {
            if (std.mem.startsWith(u8, self.text[self.at..], word[0])) {
                self.at += word[0].len;
                return word[1];
            }
        }
        const start = self.at;
        while (self.at < self.text.len and std.mem.indexOfScalar(u8, "-+0123456789.eE", self.text[self.at]) != null) self.at += 1;
        const number = self.text[start..self.at];
        if (!jsonNumber(number)) return error.Fail;
        return .{ .number = number };
    }
    /// A JSON string, decoded to UTF-8; a lone surrogate is no string.
    fn string(self: *Parser) Fail![]const u8 {
        self.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.at >= self.text.len) return error.Fail;
            const c = self.text[self.at];
            self.at += 1;
            if (c == '"') return out.items;
            if (c < 0x20) return error.Fail;
            if (c != '\\') {
                try out.append(self.a, c);
                continue;
            }
            if (self.at >= self.text.len) return error.Fail;
            const e = self.text[self.at];
            self.at += 1;
            const simple: ?u8 = switch (e) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 8,
                'f' => 12,
                'n' => 10,
                'r' => 13,
                't' => 9,
                'u' => null,
                else => return error.Fail,
            };
            if (simple) |byte| {
                try out.append(self.a, byte);
                continue;
            }
            var code = try self.hex4();
            if (code >= 0xDC00 and code <= 0xDFFF) return error.Fail;
            if (code >= 0xD800 and code <= 0xDBFF) {
                if (self.at + 2 > self.text.len or !std.mem.eql(u8, self.text[self.at .. self.at + 2], "\\u")) return error.Fail;
                self.at += 2;
                const low = try self.hex4();
                if (low < 0xDC00 or low > 0xDFFF) return error.Fail;
                code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00);
            }
            var bytes: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(@intCast(code), &bytes) catch return error.Fail;
            try out.appendSlice(self.a, bytes[0..length]);
        }
    }
    fn hex4(self: *Parser) Fail!u32 {
        if (self.at + 4 > self.text.len) return error.Fail;
        for (self.text[self.at .. self.at + 4]) |c| if (!std.ascii.isHex(c)) return error.Fail;
        const code = std.fmt.parseInt(u32, self.text[self.at .. self.at + 4], 16) catch return error.Fail;
        self.at += 4;
        return code;
    }
};

/// RFC 8259's number grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
fn jsonNumber(text: []const u8) bool {
    var at: usize = 0;
    if (at < text.len and text[at] == '-') at += 1;
    if (at >= text.len) return false;
    if (text[at] == '0') at += 1 else if (std.ascii.isDigit(text[at])) {
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
    } else return false;
    if (at < text.len and text[at] == '.') {
        at += 1;
        const digits = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == digits) return false;
    }
    if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
        at += 1;
        if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;
        const digits = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == digits) return false;
    }
    return at == text.len;
}

fn parse(a: Allocator, text: []const u8) Fail!Json {
    var parser: Parser = .{ .text = text, .a = a };
    const value = try parser.value();
    parser.ws();
    if (parser.at != text.len) return error.Fail;
    return value;
}

fn decode(a: Allocator, t: *const MType, text: []const u8) Fail!MValue {
    return walk(a, t, try parse(a, text));
}

fn walk(a: Allocator, t: *const MType, j: Json) Fail!MValue {
    switch (t.*) {
        .logic => return switch (j) {
            .true_ => .{ .logic = true },
            .false_ => .{ .logic = false },
            else => error.Fail,
        },
        .int, .char, .char32 => {
            if (j != .number or std.mem.indexOfAny(u8, j.number, ".eE") != null) return error.Fail;
            const n = std.fmt.parseInt(i128, j.number, 10) catch return error.Fail;
            const low: i128, const high: i128 = switch (t.*) {
                .int => .{ std.math.minInt(i64), std.math.maxInt(i64) },
                .char => .{ 0, 255 },
                else => .{ 0, 0x10FFFF },
            };
            if (n < low or n > high or (t.* == .char32 and n >= 0xD800 and n <= 0xDFFF)) return error.Fail;
            return if (t.* == .int) .{ .int = @intCast(n) } else .{ .char = @intCast(n) };
        },
        .float => {
            if (j == .string) {
                if (std.mem.eql(u8, j.string, "NaN")) return .{ .float = std.math.nan(f64) };
                if (std.mem.eql(u8, j.string, "Inf")) return .{ .float = std.math.inf(f64) };
                if (std.mem.eql(u8, j.string, "-Inf")) return .{ .float = -std.math.inf(f64) };
                return error.Fail;
            }
            if (j != .number) return error.Fail;
            const x = std.fmt.parseFloat(f64, j.number) catch return error.Fail;
            if (std.math.isInf(x)) return error.Fail;
            return .{ .float = x };
        },
        .string => return if (j == .string) .{ .string = j.string } else error.Fail,
        .array => |element| {
            if (j != .array) return error.Fail;
            const out = try a.alloc(MValue, j.array.len);
            for (j.array, out) |x, *y| y.* = try walk(a, element, x);
            return .{ .array = out };
        },
        .option => |element| {
            if (j == .false_) return .{ .option = null };
            if (j != .object or j.object.len != 1 or j.object[0].name.len != 0) return error.Fail;
            const inner = try a.create(MValue);
            inner.* = try walk(a, element, j.object[0].value);
            return .{ .option = inner };
        },
        .map => |pair| {
            if (j != .array) return error.Fail;
            var entries: std.ArrayList([2]MValue) = .empty;
            for (j.array) |entry| {
                if (entry != .object or entry.object.len != 2) return error.Fail;
                const first = entry.object[0];
                const second = entry.object[1];
                const k_first = std.mem.eql(u8, first.name, "k") and std.mem.eql(u8, second.name, "v");
                const v_first = std.mem.eql(u8, first.name, "v") and std.mem.eql(u8, second.name, "k");
                if (!k_first and !v_first) return error.Fail;
                const key_option: MType = .{ .option = pair[0] };
                const value_option: MType = .{ .option = pair[1] };
                const key = try walk(a, &key_option, if (k_first) first.value else second.value);
                const value = try walk(a, &value_option, if (k_first) second.value else first.value);
                if (key.option == null or value.option == null) return error.Fail;
                for (entries.items) |earlier| if (same(earlier[0], key.option.?.*)) return error.Fail;
                try entries.append(a, .{ key.option.?.*, value.option.?.* });
            }
            return .{ .map = entries.items };
        },
        .tuple => |elements| {
            if (j != .array or j.array.len != elements.len) return error.Fail;
            const out = try a.alloc(MValue, elements.len);
            for (elements, j.array, out) |element, x, *y| y.* = try walk(a, element, x);
            return .{ .tuple = out };
        },
        .record, .class => |object| {
            if (j != .object) return error.Fail;
            for (j.object, 0..) |m, i| for (j.object[0..i]) |earlier| if (std.mem.eql(u8, m.name, earlier.name)) return error.Fail;
            for (j.object) |m| {
                if (std.mem.eql(u8, m.name, "$package_name")) {
                    if (m.value != .string or !std.mem.eql(u8, m.value.string, package_names[object.package])) return error.Fail;
                } else if (std.mem.eql(u8, m.name, "$class_name")) {
                    if (m.value != .string or !std.mem.eql(u8, m.value.string, objectName(object))) return error.Fail;
                } else {
                    const known = for (object.fields) |field| {
                        if (std.mem.startsWith(u8, m.name, "x_") and std.mem.eql(u8, m.name[2..], field_names[field.name])) break true;
                    } else false;
                    if (!known) return error.Fail;
                }
            }
            const out = try a.alloc(MValue, object.fields.len);
            for (object.fields, out) |field, *y| {
                const given = for (j.object) |m| {
                    if (std.mem.startsWith(u8, m.name, "x_") and std.mem.eql(u8, m.name[2..], field_names[field.name])) break m.value;
                } else null;
                if (given) |x| y.* = try walk(a, field.value_type, x) else if (field.default) |d| y.* = d.* else return error.Fail;
            }
            return .{ .object = out };
        },
        .enumeration => |enumeration| {
            if (j != .string) return error.Fail;
            const name = enumName(enumeration);
            if (!std.mem.startsWith(u8, j.string, name) or !std.mem.startsWith(u8, j.string[name.len..], "::")) return error.Fail;
            const case = j.string[name.len + 2 ..];
            for (0..caseCount(enumeration)) |i| if (std.mem.eql(u8, case, caseName(enumeration, @intCast(i)))) return .{ .case = @intCast(i) };
            return error.Fail;
        },
    }
}

// --- generators -----------------------------------------------------------------------------------

const Gen = struct {
    r: std.Random,
    a: Allocator,

    fn chance(self: Gen, p: f64) bool {
        return self.r.float(f64) < p;
    }
    fn make(self: Gen, t: MType) Allocator.Error!*const MType {
        const out = try self.a.create(MType);
        out.* = t;
        return out;
    }
    fn typeOf(self: Gen, depth: u32, comparable: bool) Allocator.Error!*const MType {
        if (comparable or depth > 2 or self.chance(0.45)) {
            if (self.chance(0.15)) return self.make(.{ .enumeration = .{ .package = self.r.uintLessThan(u8, 3), .name = self.r.uintLessThan(u8, type_names.len), .cases = self.r.intRangeAtMost(u8, 1, 3) } });
            return self.make(switch (self.r.uintLessThan(u8, 6)) {
                0 => .logic,
                1 => .int,
                2 => .float,
                3 => .string,
                4 => .char,
                else => .char32,
            });
        }
        switch (self.r.uintLessThan(u8, 6)) {
            0 => return self.make(.{ .array = try self.typeOf(depth + 1, false) }),
            1 => return self.make(.{ .option = try self.typeOf(depth + 1, false) }),
            2 => return self.make(.{ .map = .{ try self.typeOf(depth + 1, true), try self.typeOf(depth + 1, false) } }),
            3 => {
                const elements = try self.a.alloc(*const MType, self.r.uintAtMost(u8, 3));
                for (elements) |*element| element.* = try self.typeOf(depth + 1, false);
                return self.make(.{ .tuple = elements });
            },
            else => |kind| {
                var names: [field_names.len]u8 = undefined;
                for (&names, 0..) |*name, i| name.* = @intCast(i);
                self.r.shuffle(u8, &names);
                const fields = try self.a.alloc(Field, self.r.uintAtMost(u8, 3));
                for (fields, 0..) |*field, i| {
                    const value_type = try self.typeOf(depth + 1, false);
                    var default: ?*const MValue = null;
                    if (self.chance(0.5) and !reachesClass(value_type)) {
                        const made = try self.a.create(MValue);
                        made.* = try self.valueOf(value_type, 0);
                        default = made;
                    }
                    field.* = .{ .name = names[i], .value_type = value_type, .default = default };
                }
                const object: Object = .{ .package = self.r.uintLessThan(u8, 3), .name = self.r.uintLessThan(u8, type_names.len), .fields = fields };
                return self.make(if (kind == 4) .{ .record = object } else .{ .class = object });
            },
        }
    }
    fn valueOf(self: Gen, t: *const MType, depth: u32) Allocator.Error!MValue {
        const r = self.r;
        switch (t.*) {
            .logic => return .{ .logic = r.boolean() },
            .int => return .{ .int = switch (r.uintLessThan(u8, 7)) {
                0 => 0,
                1 => 1,
                2 => -1,
                3 => std.math.minInt(i64),
                4 => std.math.maxInt(i64),
                5 => r.intRangeAtMost(i64, -1000, 1000),
                else => r.int(i64),
            } },
            .float => return .{ .float = switch (r.uintLessThan(u8, 10)) {
                0 => 0.0,
                1 => -0.0,
                2 => 1.5,
                3 => -2.25e-300,
                4 => 1e300,
                5 => types.canonicalFloat(std.math.nan(f64)),
                6 => std.math.inf(f64),
                7 => -std.math.inf(f64),
                8 => 5e-324,
                else => r.float(f64) * std.math.pow(f64, 10, @floatFromInt(r.intRangeAtMost(i32, -20, 20))),
            } },
            .string => {
                const pieces = [_][]const u8{ "a", "z", "\"", "\\", "\n", "\x01", "\u{e9}", "\u{96ea}", "\u{1F600}", "/", "\x7f" };
                var out: std.ArrayList(u8) = .empty;
                for (0..r.uintAtMost(u8, 5)) |_| try out.appendSlice(self.a, pieces[r.uintLessThan(usize, pieces.len)]);
                return .{ .string = out.items };
            },
            .char => return .{ .char = r.uintAtMost(u8, 255) },
            .char32 => return .{ .char = ([_]u32{ 0, 0x41, 0xE9, 0x96EA, 0x10FFFF, 0x1F600 })[r.uintLessThan(usize, 6)] },
            .array => |element| {
                const out = try self.a.alloc(MValue, if (depth < 3) r.uintAtMost(u8, 3) else 0);
                for (out) |*x| x.* = try self.valueOf(element, depth + 1);
                return .{ .array = out };
            },
            .option => |element| {
                if (self.chance(0.4)) return .{ .option = null };
                const inner = try self.a.create(MValue);
                inner.* = try self.valueOf(element, depth + 1);
                return .{ .option = inner };
            },
            .map => |pair| {
                var entries: std.ArrayList([2]MValue) = .empty;
                for (0..r.uintAtMost(u8, 3)) |_| {
                    const key = try self.valueOf(pair[0], depth + 1);
                    for (entries.items) |earlier| {
                        if (same(earlier[0], key)) break;
                    } else try entries.append(self.a, .{ key, try self.valueOf(pair[1], depth + 1) });
                }
                return .{ .map = entries.items };
            },
            .tuple => |elements| {
                const out = try self.a.alloc(MValue, elements.len);
                for (elements, out) |element, *x| x.* = try self.valueOf(element, depth + 1);
                return .{ .tuple = out };
            },
            .record, .class => |object| {
                const out = try self.a.alloc(MValue, object.fields.len);
                for (object.fields, out) |field, *x| x.* = try self.valueOf(field.value_type, depth + 1);
                return .{ .object = out };
            },
            .enumeration => |enumeration| return .{ .case = r.uintLessThan(u32, caseCount(enumeration)) },
        }
    }
};

/// The same JSON with other whitespace, object members in another order, absent metadata and
/// strings escaped otherwise: still the same value (PM2).
fn noisy(out: *std.ArrayList(u8), a: Allocator, r: std.Random, j: Json) Allocator.Error!void {
    const spaces = [_][]const u8{ "", " ", "\n\t", "\r\n " };
    const ws = spaces[r.uintLessThan(usize, spaces.len)];
    switch (j) {
        .object => |members| {
            const order = try a.dupe(Member, members);
            r.shuffle(Member, order);
            try out.append(a, '{');
            var first = true;
            for (order) |m| {
                // Metadata may be left out (17:367).
                if (m.name.len != 0 and m.name[0] == '$' and r.boolean()) continue;
                if (!first) try out.append(a, ',');
                first = false;
                try out.appendSlice(a, ws);
                try noisyString(out, a, r, m.name);
                try out.appendSlice(a, ws);
                try out.append(a, ':');
                try noisy(out, a, r, m.value);
            }
            try out.appendSlice(a, ws);
            try out.append(a, '}');
        },
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |x, i| {
                if (i != 0) try out.append(a, ',');
                try out.appendSlice(a, ws);
                try noisy(out, a, r, x);
            }
            try out.appendSlice(a, ws);
            try out.append(a, ']');
        },
        .string => |s| try noisyString(out, a, r, s),
        .number => |n| try out.appendSlice(a, n),
        .true_ => try out.appendSlice(a, "true"),
        .false_ => try out.appendSlice(a, "false"),
        .null_ => try out.appendSlice(a, "null"),
    }
}

/// A string with some of its characters written as escapes: `\uXXXX` (a surrogate pair above
/// the BMP, either case of hex) or `\/`.
fn noisyString(out: *std.ArrayList(u8), a: Allocator, r: std.Random, s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const code = std.unicode.utf8Decode(slice) catch unreachable;
        const plain = code >= 0x20 and code != '"' and code != '\\';
        if (plain and r.uintLessThan(u8, 4) != 0) {
            try out.appendSlice(a, slice);
            continue;
        }
        if (code == '/' and r.boolean()) {
            try out.appendSlice(a, "\\/");
            continue;
        }
        var buffer: [12]u8 = undefined;
        const upper = r.boolean();
        if (code >= 0x10000) {
            const high = 0xD800 + ((code - 0x10000) >> 10);
            const low = 0xDC00 + ((code - 0x10000) & 0x3FF);
            try out.appendSlice(a, if (upper) std.fmt.bufPrint(&buffer, "\\u{X:0>4}\\u{X:0>4}", .{ high, low }) catch unreachable else std.fmt.bufPrint(&buffer, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable);
        } else try out.appendSlice(a, if (upper) std.fmt.bufPrint(&buffer, "\\u{X:0>4}", .{code}) catch unreachable else std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{code}) catch unreachable);
    }
    try out.append(a, '"');
}

// --- the catalogue and values the codec reads ------------------------------------------------------

const region_bytes = 1 << 14;
/// Source text: the root's names, then the nested module `Progress`, then `Kit` with `Save` in it.
const progress_start = region_bytes;
const kit_start = 2 * region_bytes;
const save_start = 3 * region_bytes;
const source_bytes = 4 * region_bytes;

/// A catalogue built for one model type, with what the codec needs to read and write it.
const Built = struct {
    a: Allocator,
    source: []u8,
    ends: [4]usize = .{ 64, progress_start, kit_start, save_start },
    definitions: std.ArrayList(types.Definition) = .empty,
    fields: std.ArrayList(types.Field) = .empty,
    cases: std.ArrayList(types.Span) = .empty,
    tuple_elements: std.ArrayList(types.Type) = .empty,
    constants: std.ArrayList(types.Constant) = .empty,
    constant_members: std.ArrayList(u32) = .empty,
    strings: std.ArrayList(u8) = .empty,
    nested: [3]types.NestedModule = undefined,

    fn init(a: Allocator) !Built {
        var built: Built = .{ .a = a, .source = try a.alloc(u8, source_bytes) };
        @memset(built.source, ' ');
        @memcpy(built.source[0..8], "Progress");
        @memcpy(built.source[9..12], "Kit");
        @memcpy(built.source[13..17], "Save");
        built.nested = .{
            .{ .name = .{ .start = 0, .end = 8 }, .source = .{ .start = progress_start, .end = kit_start - 1 }, .parent = types.no_parent, .is_public = true },
            .{ .name = .{ .start = 9, .end = 12 }, .source = .{ .start = kit_start, .end = source_bytes }, .parent = types.no_parent, .is_public = true },
            .{ .name = .{ .start = 13, .end = 17 }, .source = .{ .start = save_start, .end = source_bytes - 1 }, .parent = 1, .is_public = true },
        };
        return built;
    }
    fn name(self: *Built, region: usize, text: []const u8) types.Span {
        const start = self.ends[region];
        @memcpy(self.source[start..][0..text.len], text);
        self.ends[region] += text.len + 1;
        return .{ .start = @intCast(start), .end = @intCast(start + text.len) };
    }
    /// The region of a package: `/` the root, `/Progress`, `/Kit/Save`.
    fn regionOf(package: u8) usize {
        return if (package == 0) 0 else if (package == 1) 1 else 3;
    }
    fn add(self: *Built, definition: types.Definition) !types.Type {
        try self.definitions.append(self.a, definition);
        return @fromBackingInt(@as(u16, @intCast(self.definitions.items.len - 1 + 4)));
    }
    fn define(self: *Built, t: *const MType) Allocator.Error!types.Type {
        switch (t.*) {
            .logic => return .logic,
            .int => return .i64,
            .float => return .float,
            .string => return .string,
            .char => return types.Type.char,
            .char32 => return types.Type.char32,
            .array => |element| {
                const inner = try self.define(element);
                return self.add(.{ .array = inner });
            },
            .option => |element| {
                const inner = try self.define(element);
                return self.add(.{ .option = inner });
            },
            .map => |pair| {
                const key = try self.define(pair[0]);
                const value = try self.define(pair[1]);
                return self.add(.{ .map = .{ .key = key, .value = value } });
            },
            .tuple => |elements| {
                const parts = try self.a.alloc(types.Type, elements.len);
                for (elements, parts) |element, *part| part.* = try self.define(element);
                const start: u32 = @intCast(self.tuple_elements.items.len);
                try self.tuple_elements.appendSlice(self.a, parts);
                return self.add(.{ .tuple = .{ .start = start, .end = @intCast(self.tuple_elements.items.len) } });
            },
            .record, .class => |object| {
                const parts = try self.a.alloc(types.Field, object.fields.len);
                for (object.fields, parts) |field, *part| {
                    const value_type = try self.define(field.value_type);
                    const default_constant: ?u32 = if (field.default) |d| try self.constant(field.value_type, value_type, d.*) else null;
                    part.* = .{ .name = self.name(0, field_names[field.name]), .value_type = value_type, .constant = default_constant };
                }
                const start: u32 = @intCast(self.fields.items.len);
                try self.fields.appendSlice(self.a, parts);
                const span: types.Span = .{ .start = start, .end = @intCast(self.fields.items.len) };
                const type_name = self.name(regionOf(object.package), objectName(object));
                return self.add(if (t.* == .record) .{ .record = .{ .name = type_name, .fields = span, .is_public = true, .persistable = true } } else .{ .class = .{ .name = type_name, .fields = span, .is_public = true, .is_final = true, .persistable = true } });
            },
            .enumeration => |enumeration| {
                const start: u32 = @intCast(self.cases.items.len);
                for (0..caseCount(enumeration)) |i| try self.cases.append(self.a, self.name(0, caseName(enumeration, @intCast(i))));
                const type_name = self.name(regionOf(enumeration.package), enumName(enumeration));
                return self.add(.{ .enumeration = .{ .name = type_name, .cases = .{ .start = start, .end = @intCast(self.cases.items.len) }, .is_public = true, .is_open = enumeration.open, .persistable = true } });
            },
        }
    }
    /// The default `v` of a field of model type `t` (defined as `value_type`) as constants.
    fn constant(self: *Built, t: *const MType, value_type: types.Type, v: MValue) Allocator.Error!u32 {
        const kind: @FieldType(types.Constant, "kind") = switch (t.*) {
            .logic => .{ .boolean = v.logic },
            .int => .{ .integer = v.int },
            .float => .{ .floating = types.canonicalFloat(v.float) },
            .string => string: {
                const start: u32 = @intCast(self.strings.items.len);
                try self.strings.appendSlice(self.a, v.string);
                break :string .{ .string = .{ .start = start, .end = @intCast(self.strings.items.len) } };
            },
            .char, .char32 => .{ .character = v.char },
            .enumeration => .{ .enumeration = v.case },
            .array, .option, .map, .tuple, .record => aggregate: {
                var parts: std.ArrayList(u32) = .empty;
                const shape = self.definitions.items[@backingInt(value_type) - 4];
                switch (t.*) {
                    .array => |element| for (v.array) |x| try parts.append(self.a, try self.constant(element, shape.array, x)),
                    .option => |element| if (v.option) |x| try parts.append(self.a, try self.constant(element, shape.option, x.*)),
                    .map => |pair| for (v.map) |entry| {
                        try parts.append(self.a, try self.constant(pair[0], shape.map.key, entry[0]));
                        try parts.append(self.a, try self.constant(pair[1], shape.map.value, entry[1]));
                    },
                    .tuple => |elements| for (elements, v.tuple, 0..) |element, x, i| try parts.append(self.a, try self.constant(element, self.tuple_elements.items[shape.tuple.start + i], x)),
                    .record => |object| for (object.fields, v.object, 0..) |field, x, i| try parts.append(self.a, try self.constant(field.value_type, self.fields.items[shape.record.fields.start + i].value_type, x)),
                    else => unreachable,
                }
                const start: u32 = @intCast(self.constant_members.items.len);
                try self.constant_members.appendSlice(self.a, parts.items);
                break :aggregate .{ .aggregate = .{ .start = start, .end = @intCast(self.constant_members.items.len) } };
            },
            .class => unreachable,
        };
        try self.constants.append(self.a, .{ .value_type = value_type, .kind = kind });
        return @intCast(self.constants.items.len - 1);
    }
    fn catalogue(self: *const Built) persist_json.Catalogue {
        return .{ .source = self.source, .strings = self.strings.items, .definitions = self.definitions.items, .fields = self.fields.items, .cases = self.cases.items, .tuple_elements = self.tuple_elements.items, .paths = "", .modules = &.{}, .nested = &self.nested, .constants = self.constants.items, .constant_members = self.constant_members.items };
    }
};

/// The codec's machine: a member pool, a string pool, instance cells and its stack.
const Machine = struct {
    stack: *persist_json.Stack,
    members: []types.Value,
    count: usize = 0,
    bytes: []u8,
    pool: run_strings.Pool,
    cells: []types.Value,
    host: persist_json.TestHost,
    work: keys.Work = .{},

    fn init() !Machine {
        const cells = scratch.alloc(types.Value, 1 << 16) orelse return error.OutOfMemory;
        const bytes = scratch.alloc(u8, 1 << 20) orelse return error.OutOfMemory;
        return .{ .stack = try scratch.storage(persist_json.Stack), .members = scratch.alloc(types.Value, 1 << 16) orelse return error.OutOfMemory, .bytes = bytes, .pool = run_strings.Pool.init(bytes[0..0], bytes), .cells = cells, .host = .{ .cells = cells } };
    }
    fn deinit(self: *Machine) void {
        self.work.release();
        scratch.release(self.stack);
        scratch.free(self.members);
        scratch.free(self.bytes);
        scratch.free(self.cells);
    }
    fn reset(self: *Machine) void {
        self.count = 0;
        self.pool.used = self.pool.base;
        self.host.count = 0;
        self.host.instances = 0;
    }
    /// A model value as the machines hold it: members laid out before what holds them.
    fn build(self: *Machine, built: *const Built, t: *const MType, value_type: types.Type, v: MValue) !types.Value {
        switch (t.*) {
            .logic => return .{ .boolean = v.logic },
            .int => return .{ .integer = v.int },
            .float => return .{ .floating = types.canonicalFloat(v.float) },
            .string => return .{ .string = v.string },
            .char, .char32 => return types.characterValue(value_type, v.char),
            .enumeration => return .{ .enumeration = .{ .value_type = value_type, .index = v.case } },
            else => {},
        }
        const shape = built.definitions.items[@backingInt(value_type) - 4];
        var parts: [64]types.Value = undefined;
        var count: usize = 0;
        switch (t.*) {
            .array => |element| for (v.array) |x| {
                parts[count] = try self.build(built, element, shape.array, x);
                count += 1;
            },
            .option => |element| if (v.option) |x| {
                parts[0] = try self.build(built, element, shape.option, x.*);
                count = 1;
            },
            .map => |pair| for (v.map) |entry| {
                parts[count] = try self.build(built, pair[0], shape.map.key, entry[0]);
                parts[count + 1] = try self.build(built, pair[1], shape.map.value, entry[1]);
                count += 2;
            },
            .tuple => |elements| for (elements, v.tuple, 0..) |element, x, i| {
                parts[i] = try self.build(built, element, built.tuple_elements.items[shape.tuple.start + i], x);
                count += 1;
            },
            .record, .class => |object| {
                const span = if (t.* == .record) shape.record.fields else shape.class.fields;
                for (object.fields, v.object, 0..) |field, x, i| {
                    parts[i] = try self.build(built, field.value_type, built.fields.items[span.start + i].value_type, x);
                    count += 1;
                }
                if (t.* == .class) {
                    var cells: [65]types.Value = undefined;
                    cells[0] = .{ .integer = @backingInt(value_type) };
                    @memcpy(cells[1..][0..count], parts[0..count]);
                    const id = try self.host.instance(value_type, cells[0 .. count + 1], 0);
                    return .{ .object = .{ .value_type = value_type, .id = id } };
                }
            },
            else => unreachable,
        }
        const start = self.count;
        @memcpy(self.members[start..][0..count], parts[0..count]);
        self.count += count;
        return .{ .aggregate = .{ .value_type = value_type, .elements = .{ .start = @intCast(start), .end = @intCast(self.count) } } };
    }
    /// A value the codec built, as a model value.
    fn read(self: *Machine, a: Allocator, built: *const Built, t: *const MType, value_type: types.Type, value: types.Value) !MValue {
        switch (t.*) {
            .logic => return .{ .logic = value.boolean },
            .int => return .{ .int = value.integer },
            .float => return .{ .float = value.floating },
            .string => return .{ .string = value.string },
            .char, .char32 => {
                try std.testing.expectEqual(value_type, value.enumeration.value_type);
                return .{ .char = value.enumeration.index };
            },
            .enumeration => return .{ .case = value.enumeration.index },
            else => {},
        }
        const shape = built.definitions.items[@backingInt(value_type) - 4];
        if (t.* == .class) {
            const object = t.class;
            try std.testing.expectEqual(value_type, value.object.value_type);
            const out = try a.alloc(MValue, object.fields.len);
            for (object.fields, out, 0..) |field, *x, i| x.* = try self.read(a, built, field.value_type, built.fields.items[shape.class.fields.start + i].value_type, self.host.cells[value.object.id + 1 + i]);
            return .{ .object = out };
        }
        try std.testing.expectEqual(value_type, value.aggregate.value_type);
        const parts = self.members[value.aggregate.elements.start..value.aggregate.elements.end];
        switch (t.*) {
            .array => |element| {
                const out = try a.alloc(MValue, parts.len);
                for (parts, out) |part, *x| x.* = try self.read(a, built, element, shape.array, part);
                return .{ .array = out };
            },
            .option => |element| {
                if (parts.len == 0) return .{ .option = null };
                const inner = try a.create(MValue);
                inner.* = try self.read(a, built, element, shape.option, parts[0]);
                return .{ .option = inner };
            },
            .map => |pair| {
                const out = try a.alloc([2]MValue, parts.len / 2);
                for (out, 0..) |*entry, i| entry.* = .{ try self.read(a, built, pair[0], shape.map.key, parts[2 * i]), try self.read(a, built, pair[1], shape.map.value, parts[2 * i + 1]) };
                return .{ .map = out };
            },
            .tuple => |elements| {
                const out = try a.alloc(MValue, elements.len);
                for (elements, out, 0..) |element, *x, i| x.* = try self.read(a, built, element, built.tuple_elements.items[shape.tuple.start + i], parts[i]);
                return .{ .tuple = out };
            },
            .record => |object| {
                const out = try a.alloc(MValue, object.fields.len);
                for (object.fields, out, 0..) |field, *x, i| x.* = try self.read(a, built, field.value_type, built.fields.items[shape.record.fields.start + i].value_type, parts[i]);
                return .{ .object = out };
            },
            else => unreachable,
        }
    }
    fn encodeValue(self: *Machine, built: *const Built, value_type: types.Type, value: types.Value) ![]const u8 {
        var remaining: u64 = 1 << 40;
        return persist_json.encode(built.catalogue(), &self.host, self.members[0..self.count], value_type, value, &self.pool, self.stack, &remaining);
    }
    /// The decoded value, or null when the codec refuses the text.
    fn decodeText(self: *Machine, built: *const Built, option_type: types.Type, text: []const u8) !?types.Value {
        return self.decodeWithin(persist_json.json_depth, built, option_type, text);
    }
    /// The text with at most `limit` containers open, or null when the value nests deeper.
    fn encodeWithin(self: *Machine, limit: u32, built: *const Built, value_type: types.Type, value: types.Value) !?[]const u8 {
        var remaining: u64 = 1 << 40;
        return persist_json.encodeWithin(limit, built.catalogue(), &self.host, self.members[0..self.count], value_type, value, &self.pool, self.stack, &remaining) catch |err| switch (err) {
            error.DepthLimit => null,
            else => err,
        };
    }
    fn decodeWithin(self: *Machine, limit: u32, built: *const Built, option_type: types.Type, text: []const u8) !?types.Value {
        var remaining: u64 = 1 << 40;
        const got = try persist_json.decodeWithin(limit, built.catalogue(), &self.host, .{ .slots = self.members, .count = &self.count }, option_type, text, &self.pool, self.stack, &self.work, &remaining);
        const span = got.aggregate.elements;
        if (span.start == span.end) return null;
        return self.members[span.start];
    }
};

/// The most JSON containers open at once in a text (E6): what the codec counts for its limit.
fn jsonDepth(j: Json) u32 {
    var deepest: u32 = 0;
    switch (j) {
        .object => |members| {
            for (members) |m| deepest = @max(deepest, jsonDepth(m.value));
            return deepest + 1;
        },
        .array => |items| {
            for (items) |x| deepest = @max(deepest, jsonDepth(x));
            return deepest + 1;
        },
        else => return 0,
    }
}

/// The cases of E3 that need no generated type (the prototype's `FIXED_REFUSALS`).
const Fixed = struct { t: MType, text: []const u8 };
const int: MType = .int;
const float: MType = .float;
const fixed_refusals = [_]Fixed{
    .{ .t = .int, .text = "{" },
    .{ .t = .{ .array = &int }, .text = "[1,]" },
    .{ .t = .int, .text = "1 2" },
    .{ .t = .logic, .text = "true false" },
    .{ .t = .int, .text = "null" },
    .{ .t = .string, .text = "1" },
    .{ .t = .logic, .text = "\"true\"" },
    .{ .t = .int, .text = "1.0" },
    .{ .t = .int, .text = "1e3" },
    .{ .t = .int, .text = "9223372036854775808" },
    .{ .t = .int, .text = "-9223372036854775809" },
    .{ .t = .char, .text = "256" },
    .{ .t = .char, .text = "-1" },
    .{ .t = .char32, .text = "1114112" },
    .{ .t = .char32, .text = "55296" },
    .{ .t = .char32, .text = "57343" },
    .{ .t = .float, .text = "1e400" },
    .{ .t = .float, .text = "-1e400" },
    .{ .t = .float, .text = "\"Infinity\"" },
    .{ .t = .string, .text = "\"\\ud800\"" },
    .{ .t = .string, .text = "\"a\\udfff\"" },
    .{ .t = .string, .text = "\"\\x41\"" },
    .{ .t = .{ .option = &int }, .text = "{\"x\":1}" },
    .{ .t = .{ .option = &int }, .text = "{\"\":1,\"\":2}" },
    .{ .t = .{ .option = &int }, .text = "true" },
    .{ .t = .{ .tuple = &.{ &int, &int } }, .text = "[1]" },
    .{ .t = .{ .tuple = &.{} }, .text = "[1]" },
    .{ .t = .{ .map = .{ &int, &int } }, .text = "[{\"k\":{\"\":1}}]" },
    .{ .t = .{ .map = .{ &int, &int } }, .text = "[{\"k\":1,\"v\":{\"\":2}}]" },
    .{ .t = .{ .map = .{ &int, &int } }, .text = "[{\"k\":{\"\":1},\"v\":{\"\":2}},{\"k\":{\"\":1},\"v\":{\"\":3}}]" },
    .{ .t = .{ .map = .{ &float, &int } }, .text = "[{\"k\":{\"\":0},\"v\":{\"\":2}},{\"k\":{\"\":-0},\"v\":{\"\":3}}]" },
    .{ .t = .{ .map = .{ &float, &int } }, .text = "[{\"k\":{\"\":\"NaN\"},\"v\":{\"\":2}},{\"k\":{\"\":\"NaN\"},\"v\":{\"\":3}}]" },
    .{ .t = .{ .enumeration = .{ .package = 0, .name = 0, .cases = 1 } }, .text = "\"stats::Hard\"" },
    .{ .t = .{ .enumeration = .{ .package = 0, .name = 0, .cases = 1 } }, .text = "\"profile::Easy\"" },
    .{ .t = .{ .enumeration = .{ .package = 0, .name = 0, .cases = 1 } }, .text = "\"Easy\"" },
};

/// Texts that break one rule of E3 for a generated object `v` of `t` (the prototype's
/// `object_refusals`).
fn objectRefusals(a: Allocator, t: *const MType, v: MValue, text: []const u8) ![]const []const u8 {
    const object = switch (t.*) {
        .record, .class => |object| object,
        else => unreachable,
    };
    var out: std.ArrayList([]const u8) = .empty;
    const body = text[0 .. text.len - 1];
    try out.append(a, try std.mem.concat(a, u8, &.{ body, ",\"x_Unknown\":1}" }));
    var class_name: std.ArrayList(u8) = .empty;
    try stringText(&class_name, a, objectName(object));
    var package: std.ArrayList(u8) = .empty;
    try stringText(&package, a, package_names[object.package]);
    const class_member = try std.mem.concat(a, u8, &.{ "\"$class_name\":", class_name.items });
    const package_member = try std.mem.concat(a, u8, &.{ "\"$package_name\":", package.items });
    const at_class = std.mem.indexOf(u8, text, class_member).?;
    try out.append(a, try std.mem.concat(a, u8, &.{ text[0..at_class], "\"$class_name\":\"other\"", text[at_class + class_member.len ..] }));
    const at_package = std.mem.indexOf(u8, text, package_member).?;
    try out.append(a, try std.mem.concat(a, u8, &.{ text[0..at_package], "\"$package_name\":\"/elsewhere\"", text[at_package + package_member.len ..] }));
    try out.append(a, try std.mem.concat(a, u8, &.{ body, ",", class_member, "}" }));
    if (object.fields.len != 0) {
        var again: std.ArrayList(u8) = .empty;
        try encode(&again, a, object.fields[0].value_type, v.object[0]);
        try out.append(a, try std.mem.concat(a, u8, &.{ body, ",\"x_", field_names[object.fields[0].name], "\":", again.items, "}" }));
    }
    for (object.fields, 0..) |field, i| if (field.default == null) {
        // The text without the field that has no default.
        var reduced: std.ArrayList(u8) = .empty;
        try reduced.appendSlice(a, "{");
        var first = true;
        for (object.fields, v.object, 0..) |other, x, j| {
            if (j == i) continue;
            if (!first) try reduced.append(a, ',');
            first = false;
            try reduced.appendSlice(a, "\"x_");
            try reduced.appendSlice(a, field_names[other.name]);
            try reduced.appendSlice(a, "\":");
            try encode(&reduced, a, other.value_type, x);
        }
        try reduced.append(a, '}');
        try out.append(a, reduced.items);
        break;
    };
    return out.items;
}

/// One random edit of a text: a byte removed, inserted or replaced.
fn mutate(a: Allocator, r: std.Random, text: []const u8) ![]const u8 {
    const alphabet = "{}[],:\"\\ 0123456789-.eEtrufalsnxk_$/";
    const at = r.uintAtMost(usize, text.len);
    return switch (r.uintLessThan(u8, 3)) {
        0 => if (at == text.len) a.dupe(u8, text) else std.mem.concat(a, u8, &.{ text[0..at], text[at + 1 ..] }),
        1 => std.mem.concat(a, u8, &.{ text[0..at], &.{alphabet[r.uintLessThan(usize, alphabet.len)]}, text[at..] }),
        else => if (at == text.len) a.dupe(u8, text) else std.mem.concat(a, u8, &.{ text[0..at], &.{alphabet[r.uintLessThan(usize, alphabet.len)]}, text[at + 1 ..] }),
    };
}

test "the codec agrees with the model on 20,000 random persistable types and values (PM1 to PM3)" {
    var machine = try Machine.init();
    defer machine.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x0087_0503);
    const r = prng.random();
    // PM3, the fixed cases: refused by the model and by the codec.
    {
        const a = arena.allocator();
        for (fixed_refusals) |case| {
            try std.testing.expectError(error.Fail, decode(a, &case.t, case.text));
            var built = try Built.init(a);
            const value_type = try built.define(&case.t);
            const option_type = try built.add(.{ .option = value_type });
            machine.reset();
            try std.testing.expectEqual(@as(?types.Value, null), try machine.decodeText(&built, option_type, case.text));
        }
    }
    var counts: struct { depths: u32 = 0, round_trips: u32 = 0, noisy: u32 = 0, refused: u32 = 0, bare: u32 = 0, mutated: u32 = 0, mutated_accepted: u32 = 0, classes: u32 = 0 } = .{};
    for (0..20_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const gen: Gen = .{ .r = r, .a = a };
        const t = try gen.typeOf(0, false);
        const v = try gen.valueOf(t, 0);
        var text: std.ArrayList(u8) = .empty;
        try encode(&text, a, t, v);
        // The model agrees with itself (the prototype's PM1 and PM2).
        try std.testing.expect(identical(try decode(a, t, text.items), v));
        var built = try Built.init(a);
        const value_type = try built.define(t);
        const option_type = try built.add(.{ .option = value_type });
        machine.reset();
        const value = try machine.build(&built, t, value_type, v);
        if (reachesClass(t)) counts.classes += 1;
        // PM2: the codec writes the model's canonical text.
        const written = try machine.encodeValue(&built, value_type, value);
        try std.testing.expectEqualStrings(text.items, written);
        // PM1: and reads it back, bit for bit.
        const back = (try machine.decodeText(&built, option_type, text.items)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(identical(try machine.read(a, &built, t, value_type, back), v));
        counts.round_trips += 1;
        // E6: the encoder writes with a limit of the text's own depth, and the decoder reads
        // it there; one container fewer and the encoder refuses the value, the decoder the text.
        // Every text the encoder writes is one the decoder reads, map entries included.
        const depth = jsonDepth(try parse(a, text.items));
        try std.testing.expectEqualStrings(text.items, (try machine.encodeWithin(depth, &built, value_type, value)) orelse return error.TestUnexpectedResult);
        try std.testing.expect(try machine.decodeWithin(depth, &built, option_type, text.items) != null);
        if (depth != 0) {
            try std.testing.expectEqual(@as(?[]const u8, null), try machine.encodeWithin(depth - 1, &built, value_type, value));
            try std.testing.expectEqual(@as(?types.Value, null), try machine.decodeWithin(depth - 1, &built, option_type, text.items));
            counts.depths += 1;
        }
        // PM2: a noisy text of the same value.
        var noise: std.ArrayList(u8) = .empty;
        try noisy(&noise, a, r, try parse(a, text.items));
        const model_noisy = decode(a, t, noise.items) catch |err| switch (err) {
            // Metadata left out of an object is accepted; nothing else is dropped.
            error.Fail => return error.TestUnexpectedResult,
            else => return err,
        };
        try std.testing.expect(identical(model_noisy, v));
        const noisy_back = (try machine.decodeText(&built, option_type, noise.items)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(identical(try machine.read(a, &built, t, value_type, noisy_back), v));
        counts.noisy += 1;
        // PM3: the refusals of an object, by both.
        if (t.* == .record or t.* == .class) {
            for (try objectRefusals(a, t, v, text.items)) |broken| {
                try std.testing.expectError(error.Fail, decode(a, t, broken));
                try std.testing.expectEqual(@as(?types.Value, null), try machine.decodeText(&built, option_type, broken));
                counts.refused += 1;
            }
            // Absent metadata and absent defaulted fields: the defaults (E3, 17:352).
            const object = if (t.* == .record) t.record else t.class;
            var bare: std.ArrayList(u8) = .empty;
            try bare.append(a, '{');
            var first = true;
            for (object.fields, v.object) |field, x| if (field.default == null) {
                if (!first) try bare.append(a, ',');
                first = false;
                try bare.appendSlice(a, "\"x_");
                try bare.appendSlice(a, field_names[field.name]);
                try bare.appendSlice(a, "\":");
                try encode(&bare, a, field.value_type, x);
            };
            try bare.append(a, '}');
            const expected = try decode(a, t, bare.items);
            for (object.fields, expected.object) |field, x| if (field.default) |d| try std.testing.expect(identical(x, d.*));
            const got = (try machine.decodeText(&built, option_type, bare.items)) orelse return error.TestUnexpectedResult;
            try std.testing.expect(identical(try machine.read(a, &built, t, value_type, got), expected));
            counts.bare += 1;
        }
        // PM3: texts edited at random are accepted by both or by neither, with one value.
        for (0..3) |_| {
            const edited = try mutate(a, r, if (r.boolean()) text.items else noise.items);
            const model = decode(a, t, edited) catch |err| switch (err) {
                error.Fail => null,
                else => return err,
            };
            const codec = try machine.decodeText(&built, option_type, edited);
            try std.testing.expectEqual(model == null, codec == null);
            if (model) |expected| {
                try std.testing.expect(identical(try machine.read(a, &built, t, value_type, codec.?), expected));
                counts.mutated_accepted += 1;
            }
            counts.mutated += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 20_000), counts.round_trips);
    // Enough of every kind of case to mean something.
    try std.testing.expect(counts.refused > 5_000 and counts.bare > 2_000 and counts.classes > 1_000 and counts.mutated_accepted > 1_000 and counts.depths > 5_000);
}

// --- schema compatibility (RFC-0087, P5.6, G3 and G4): PM4 to PM6 ---------------------------------
//
// The prototype's evolution generator and its rule, ported: `modelCompatible` is the prototype's
// `compatible`, written from the table of G3 alone; `evolve` makes a change the rules allow or one
// they forbid; `upgrade` is what an old value reads as under a newer type. `persist_schema.zig`
// must agree with the rule on every pair (its check of the two schemas `describe` writes), and
// the codec must read an old text under the newer type as `upgrade` says:
//   PM4  every allowed evolution, and every chain of up to four, passes both, and the first
//        version's text decodes under the last version's type with the history's values; the
//        reverse of each step (a downgrade, G5) is refused by both;
//   PM5  every forbidden change is refused by both;
//   PM6  on random pairs of types both give one verdict, and an accepted pair decodes.

const persist_schema = @import("persist_schema.zig");

fn caseName(enumeration: Enumeration, index: u32) []const u8 {
    return case_names[if (enumeration.order) |order| order[index] else index];
}
fn caseCount(enumeration: Enumeration) u32 {
    return if (enumeration.order) |order| @intCast(order.len) else enumeration.cases;
}

fn sameText(a: Allocator, t: *const MType, x: MValue, u: *const MType, y: MValue) !bool {
    var left: std.ArrayList(u8) = .empty;
    var right: std.ArrayList(u8) = .empty;
    try encode(&left, a, t, x);
    try encode(&right, a, u, y);
    return std.mem.eql(u8, left.items, right.items);
}

/// The prototype's `compatible`: whether data written as `old` may be read as `new` (G3).
fn modelCompatible(a: Allocator, old: *const MType, new: *const MType) Allocator.Error!bool {
    if (std.meta.activeTag(old.*) != std.meta.activeTag(new.*)) return false;
    switch (old.*) {
        .logic, .int, .float, .string, .char, .char32 => return true,
        .array => |element| return modelCompatible(a, element, new.array),
        .option => |element| return modelCompatible(a, element, new.option),
        .map => |pair| return try modelCompatible(a, pair[0], new.map[0]) and try modelCompatible(a, pair[1], new.map[1]),
        .tuple => |elements| {
            if (elements.len != new.tuple.len) return false;
            for (elements, new.tuple) |x, y| if (!try modelCompatible(a, x, y)) return false;
            return true;
        },
        .enumeration => |e| {
            const n = new.enumeration;
            if (e.package != n.package or e.name != n.name or e.open != n.open) return false;
            if (!e.open and caseCount(e) != caseCount(n)) return false;
            if (caseCount(n) < caseCount(e)) return false;
            for (0..caseCount(e)) |i| if (!std.mem.eql(u8, caseName(e, @intCast(i)), caseName(n, @intCast(i)))) return false;
            return true;
        },
        .record, .class => |o| {
            const n = if (new.* == .record) new.record else new.class;
            if (o.package != n.package or o.name != n.name) return false;
            if (old.* == .record) {
                if (o.fields.len != n.fields.len) return false;
                for (o.fields, n.fields) |x, y| if (x.name != y.name or !try modelCompatible(a, x.value_type, y.value_type)) return false;
                return true;
            }
            var last: ?usize = null;
            for (o.fields) |field| {
                const at = for (n.fields, 0..) |other, j| {
                    if (other.name == field.name) break j;
                } else return false;
                if (last) |before| if (at < before) return false;
                last = at;
                const other = n.fields[at];
                if (!try modelCompatible(a, field.value_type, other.value_type)) return false;
                if (field.default) |d| {
                    const kept = other.default orelse return false;
                    if (!try sameText(a, field.value_type, d.*, other.value_type, kept.*)) return false;
                }
            }
            for (n.fields) |other| {
                const known = for (o.fields) |field| {
                    if (field.name == other.name) break true;
                } else false;
                if (!known and other.default == null) return false;
            }
            return true;
        },
    }
}

/// A step of a path from a type to one of its parts.
const Step = union(enum) { element, key, value, tuple: usize, field: usize };

fn collect(a: Allocator, t: *const MType, prefix: []const Step, out: *std.ArrayList([]const Step)) Allocator.Error!void {
    try out.append(a, prefix);
    const extend = struct {
        fn with(alloc: Allocator, base: []const Step, step: Step) Allocator.Error![]const Step {
            const path = try alloc.alloc(Step, base.len + 1);
            @memcpy(path[0..base.len], base);
            path[base.len] = step;
            return path;
        }
    }.with;
    switch (t.*) {
        .array => |element| try collect(a, element, try extend(a, prefix, .element), out),
        .option => |element| try collect(a, element, try extend(a, prefix, .element), out),
        .map => |pair| {
            try collect(a, pair[0], try extend(a, prefix, .key), out);
            try collect(a, pair[1], try extend(a, prefix, .value), out);
        },
        .tuple => |elements| for (elements, 0..) |element, i| try collect(a, element, try extend(a, prefix, .{ .tuple = i }), out),
        .record, .class => |object| for (object.fields, 0..) |field, i| try collect(a, field.value_type, try extend(a, prefix, .{ .field = i }), out),
        else => {},
    }
}

/// A type changed somewhere: one the rules allow, or one they forbid; null when `t` has no place
/// for such a change.
fn evolve(gen: Gen, t: *const MType, allowed: bool) Allocator.Error!?*const MType {
    var places: std.ArrayList([]const Step) = .empty;
    try collect(gen.a, t, &.{}, &places);
    gen.r.shuffle([]const Step, places.items);
    for (places.items) |path| if (try changeAt(gen, t, path, allowed)) |changed| return changed;
    return null;
}

fn unusedNames(gen: Gen, fields: []const Field) Allocator.Error![]const u8 {
    var unused: std.ArrayList(u8) = .empty;
    for (0..field_names.len) |i| {
        const taken = for (fields) |field| {
            if (field.name == i) break true;
        } else false;
        if (!taken) try unused.append(gen.a, @intCast(i));
    }
    return unused.items;
}

fn withFields(gen: Gen, t: *const MType, fields: []const Field) Allocator.Error!*const MType {
    return switch (t.*) {
        .record => |object| gen.make(.{ .record = .{ .package = object.package, .name = object.name, .fields = fields } }),
        .class => |object| gen.make(.{ .class = .{ .package = object.package, .name = object.name, .fields = fields } }),
        else => unreachable,
    };
}

fn caseList(gen: Gen, e: Enumeration) Allocator.Error![]u8 {
    const order = try gen.a.alloc(u8, caseCount(e));
    for (order, 0..) |*slot, i| slot.* = if (e.order) |known| known[i] else @intCast(i);
    return order;
}

fn changeAt(gen: Gen, t: *const MType, path: []const Step, allowed: bool) Allocator.Error!?*const MType {
    const r = gen.r;
    if (path.len != 0) {
        const rest = path[1..];
        switch (path[0]) {
            .element => {
                const inner = (try changeAt(gen, if (t.* == .array) t.array else t.option, rest, allowed)) orelse return null;
                return try gen.make(if (t.* == .array) .{ .array = inner } else .{ .option = inner });
            },
            .key, .value => |_, tag| {
                const pair = t.map;
                const inner = (try changeAt(gen, if (tag == .key) pair[0] else pair[1], rest, allowed)) orelse return null;
                return try gen.make(.{ .map = if (tag == .key) .{ inner, pair[1] } else .{ pair[0], inner } });
            },
            .tuple => |i| {
                const inner = (try changeAt(gen, t.tuple[i], rest, allowed)) orelse return null;
                const elements = try gen.a.dupe(*const MType, t.tuple);
                elements[i] = inner;
                return try gen.make(.{ .tuple = elements });
            },
            .field => |i| {
                const object = if (t.* == .record) t.record else t.class;
                const inner = (try changeAt(gen, object.fields[i].value_type, rest, allowed)) orelse return null;
                const fields = try gen.a.dupe(Field, object.fields);
                if (allowed) if (fields[i].default) |d| if (!try sameText(gen.a, fields[i].value_type, d.*, inner, d.*)) return null;
                // A forbidden change may make the default no value of the field's type: dropped.
                if (!allowed) fields[i].default = null;
                fields[i].value_type = inner;
                return try withFields(gen, t, fields);
            },
        }
    }
    const fields: []const Field = switch (t.*) {
        .record, .class => |object| object.fields,
        else => &.{},
    };
    const unused = try unusedNames(gen, fields);
    if (allowed) {
        switch (t.*) {
            .class => {
                var bare: std.ArrayList(usize) = .empty;
                for (fields, 0..) |field, i| if (field.default == null and !reachesClass(field.value_type)) try bare.append(gen.a, i);
                if (bare.items.len != 0 and gen.chance(0.3)) {
                    const changed = try gen.a.dupe(Field, fields);
                    const i = bare.items[r.uintLessThan(usize, bare.items.len)];
                    const made = try gen.a.create(MValue);
                    made.* = try gen.valueOf(changed[i].value_type, 0);
                    changed[i].default = made;
                    return try withFields(gen, t, changed);
                }
                if (unused.len == 0) return null;
                var value_type = try gen.typeOf(2, false);
                while (reachesClass(value_type)) value_type = try gen.typeOf(2, false);
                const made = try gen.a.create(MValue);
                made.* = try gen.valueOf(value_type, 0);
                const changed = try gen.a.alloc(Field, fields.len + 1);
                @memcpy(changed[0..fields.len], fields);
                changed[fields.len] = .{ .name = unused[r.uintLessThan(usize, unused.len)], .value_type = value_type, .default = made };
                return try withFields(gen, t, changed);
            },
            .enumeration => |e| {
                if (!e.open or caseCount(e) == case_names.len) return null;
                const order = try caseList(gen, e);
                const grown = try gen.a.alloc(u8, order.len + 1);
                @memcpy(grown[0..order.len], order);
                grown[order.len] = for (0..case_names.len) |c| {
                    if (std.mem.indexOfScalar(u8, order, @intCast(c)) == null) break @intCast(c);
                } else unreachable;
                return try gen.make(.{ .enumeration = .{ .package = e.package, .name = e.name, .cases = e.cases, .open = true, .order = grown } });
            },
            else => return null,
        }
    }
    const Option = enum { remove, rename_field, retype, remove_default, change_default, reorder, add_no_default, add_struct_with_default, rename_type, move_type, flip_open, remove_case, swap_cases, add_closed_case, primitive };
    var options: std.ArrayList(Option) = .empty;
    const is_object = t.* == .record or t.* == .class;
    if (is_object and fields.len != 0) try options.appendSlice(gen.a, &.{ .remove, .retype });
    if (is_object and fields.len != 0 and unused.len != 0) try options.append(gen.a, .rename_field);
    if (t.* == .class) for (fields) |field| if (field.default != null) {
        try options.appendSlice(gen.a, &.{ .remove_default, .change_default });
        break;
    };
    if (is_object and fields.len > 1) try options.append(gen.a, .reorder);
    if (is_object and unused.len != 0) try options.append(gen.a, .add_no_default);
    if (t.* == .record and unused.len != 0) try options.append(gen.a, .add_struct_with_default);
    if (is_object or t.* == .enumeration) try options.appendSlice(gen.a, &.{ .rename_type, .move_type });
    if (t.* == .enumeration) {
        const e = t.enumeration;
        try options.append(gen.a, .flip_open);
        if (caseCount(e) > 1) try options.appendSlice(gen.a, &.{ .remove_case, .swap_cases });
        if (!e.open and caseCount(e) < case_names.len) try options.append(gen.a, .add_closed_case);
    }
    switch (t.*) {
        .logic, .int, .float, .string, .char, .char32 => try options.append(gen.a, .primitive),
        else => {},
    }
    if (options.items.len == 0) return null;
    const int_type = try gen.make(.int);
    switch (options.items[r.uintLessThan(usize, options.items.len)]) {
        .remove => {
            const i = r.uintLessThan(usize, fields.len);
            const changed = try gen.a.alloc(Field, fields.len - 1);
            @memcpy(changed[0..i], fields[0..i]);
            @memcpy(changed[i..], fields[i + 1 ..]);
            return try withFields(gen, t, changed);
        },
        .rename_field => {
            const changed = try gen.a.dupe(Field, fields);
            changed[r.uintLessThan(usize, fields.len)].name = unused[r.uintLessThan(usize, unused.len)];
            return try withFields(gen, t, changed);
        },
        .retype => {
            const changed = try gen.a.dupe(Field, fields);
            const i = r.uintLessThan(usize, fields.len);
            changed[i].value_type = if (changed[i].value_type.* == .string) int_type else try gen.make(.string);
            changed[i].default = null;
            return try withFields(gen, t, changed);
        },
        .remove_default, .change_default => |option| {
            var defaulted: std.ArrayList(usize) = .empty;
            for (fields, 0..) |field, i| if (field.default != null) try defaulted.append(gen.a, i);
            const changed = try gen.a.dupe(Field, fields);
            const i = defaulted.items[r.uintLessThan(usize, defaulted.items.len)];
            changed[i].default = null;
            if (option == .change_default) for (0..20) |_| {
                const candidate = try gen.a.create(MValue);
                candidate.* = try gen.valueOf(fields[i].value_type, 0);
                if (!try sameText(gen.a, fields[i].value_type, candidate.*, fields[i].value_type, fields[i].default.?.*)) {
                    changed[i].default = candidate;
                    break;
                }
            };
            return try withFields(gen, t, changed);
        },
        .reorder => {
            const changed = try gen.a.dupe(Field, fields);
            std.mem.swap(Field, &changed[0], &changed[1]);
            return try withFields(gen, t, changed);
        },
        .add_no_default, .add_struct_with_default => |option| {
            const changed = try gen.a.alloc(Field, fields.len + 1);
            @memcpy(changed[0..fields.len], fields);
            var default: ?*const MValue = null;
            if (option == .add_struct_with_default) {
                const zero = try gen.a.create(MValue);
                zero.* = .{ .int = 0 };
                default = zero;
            }
            changed[fields.len] = .{ .name = unused[r.uintLessThan(usize, unused.len)], .value_type = int_type, .default = default };
            return try withFields(gen, t, changed);
        },
        .rename_type, .move_type => |option| switch (t.*) {
            .record, .class => |object| {
                var moved = object;
                if (option == .rename_type) moved.name = @intCast((object.name + 1) % type_names.len) else moved.package = @intCast((object.package + 1) % package_names.len);
                return try gen.make(if (t.* == .record) .{ .record = moved } else .{ .class = moved });
            },
            .enumeration => |e| {
                var moved = e;
                if (option == .rename_type) moved.name = @intCast((e.name + 1) % type_names.len) else moved.package = @intCast((e.package + 1) % package_names.len);
                return try gen.make(.{ .enumeration = moved });
            },
            else => unreachable,
        },
        .flip_open => {
            var flipped = t.enumeration;
            flipped.open = !flipped.open;
            return try gen.make(.{ .enumeration = flipped });
        },
        .remove_case, .swap_cases, .add_closed_case => |option| {
            const e = t.enumeration;
            const order = try caseList(gen, e);
            var changed = e;
            switch (option) {
                .remove_case => {
                    const i = r.uintLessThan(usize, order.len);
                    const fewer = try gen.a.alloc(u8, order.len - 1);
                    @memcpy(fewer[0..i], order[0..i]);
                    @memcpy(fewer[i..], order[i + 1 ..]);
                    changed.order = fewer;
                },
                .swap_cases => {
                    std.mem.swap(u8, &order[0], &order[1]);
                    changed.order = order;
                },
                else => {
                    const grown = try gen.a.alloc(u8, order.len + 1);
                    @memcpy(grown[0..order.len], order);
                    grown[order.len] = for (0..case_names.len) |c| {
                        if (std.mem.indexOfScalar(u8, order, @intCast(c)) == null) break @intCast(c);
                    } else unreachable;
                    changed.order = grown;
                },
            }
            return try gen.make(.{ .enumeration = changed });
        },
        .primitive => return if (t.* == .string) int_type else try gen.make(.string),
    }
}

/// The value `v` of `old` as `new` reads it (G4): added class fields take their defaults, and a
/// case is the case of its name.
fn upgrade(a: Allocator, old: *const MType, new: *const MType, v: MValue) Allocator.Error!MValue {
    switch (old.*) {
        .array => |element| {
            const out = try a.alloc(MValue, v.array.len);
            for (v.array, out) |x, *y| y.* = try upgrade(a, element, new.array, x);
            return .{ .array = out };
        },
        .option => |element| {
            const inner = v.option orelse return .{ .option = null };
            const made = try a.create(MValue);
            made.* = try upgrade(a, element, new.option, inner.*);
            return .{ .option = made };
        },
        .map => |pair| {
            const out = try a.alloc([2]MValue, v.map.len);
            for (v.map, out) |entry, *y| y.* = .{ try upgrade(a, pair[0], new.map[0], entry[0]), try upgrade(a, pair[1], new.map[1], entry[1]) };
            return .{ .map = out };
        },
        .tuple => |elements| {
            const out = try a.alloc(MValue, elements.len);
            for (elements, new.tuple, v.tuple, out) |x, y, part, *made| made.* = try upgrade(a, x, y, part);
            return .{ .tuple = out };
        },
        .record, .class => |object| {
            const n = if (new.* == .record) new.record else new.class;
            const out = try a.alloc(MValue, n.fields.len);
            for (n.fields, out) |field, *made| {
                made.* = for (object.fields, v.object) |known, part| {
                    if (known.name == field.name) break try upgrade(a, known.value_type, field.value_type, part);
                } else field.default.?.*;
            }
            return .{ .object = out };
        },
        .enumeration => |e| {
            const name = caseName(e, v.case);
            const n = new.enumeration;
            for (0..caseCount(n)) |i| if (std.mem.eql(u8, caseName(n, @intCast(i)), name)) return .{ .case = @intCast(i) };
            unreachable;
        },
        else => return v,
    }
}

/// `t` with each enum open or closed at random (the generator of P5.3 makes them closed).
fn opened(gen: Gen, t: *const MType) Allocator.Error!*const MType {
    return switch (t.*) {
        .array => |element| gen.make(.{ .array = try opened(gen, element) }),
        .option => |element| gen.make(.{ .option = try opened(gen, element) }),
        .map => |pair| gen.make(.{ .map = .{ try opened(gen, pair[0]), try opened(gen, pair[1]) } }),
        .tuple => |elements| blk: {
            const out = try gen.a.alloc(*const MType, elements.len);
            for (elements, out) |element, *made| made.* = try opened(gen, element);
            break :blk gen.make(.{ .tuple = out });
        },
        .record, .class => blk: {
            const object = if (t.* == .record) t.record else t.class;
            const fields = try gen.a.dupe(Field, object.fields);
            for (fields) |*field| field.value_type = try opened(gen, field.value_type);
            break :blk withFields(gen, t, fields);
        },
        .enumeration => |e| blk: {
            var changed = e;
            changed.open = gen.chance(0.5);
            break :blk gen.make(.{ .enumeration = changed });
        },
        else => t,
    };
}

/// The schema `persist_schema` writes for one cell of the model type `t`, and the catalogue, or
/// null when two of its named types share an identity (`describe` refuses those, which no program
/// the compiler admits has).
const Described = struct { built: *Built, value_type: types.Type, text: []const u8 };
fn described(a: Allocator, t: *const MType) !?Described {
    const built = try a.create(Built);
    built.* = try Built.init(a);
    const value_type = try built.define(t);
    const name = built.name(0, "Cell");
    const description = persist_schema.describeCells(persist_schema.max_bytes, a, built.catalogue(), &.{.{ .name = name, .value = value_type }}) catch |err| switch (err) {
        error.Ambiguous => return null,
        else => return err,
    };
    return .{ .built = built, .value_type = value_type, .text = description.text };
}

fn accepts(a: Allocator, old: []const u8, new: []const u8) !bool {
    const outcome = try persist_schema.check(a, old, new);
    try std.testing.expect(outcome.unreadable == null);
    return outcome.refusals.len == 0;
}

/// The codec's reading of `text` under `d`'s type, as a model value; null when it refuses it.
fn readAs(machine: *Machine, a: Allocator, d: Described, t: *const MType, text: []const u8) !?MValue {
    const option_type = try d.built.add(.{ .option = d.value_type });
    machine.reset();
    const value = (try machine.decodeText(d.built, option_type, text)) orelse return null;
    return try machine.read(a, d.built, t, d.value_type, value);
}

test "the schema check agrees with the model on every evolution, chain and random pair, and old data reads under the new types (PM4 to PM6)" {
    var machine = try Machine.init();
    defer machine.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x0087_0506);
    const r = prng.random();
    var counts: struct { cases: u32 = 0, ambiguous: u32 = 0, allowed: u32 = 0, chains: u32 = 0, steps: u32 = 0, downgrades: u32 = 0, forbidden: u32 = 0, pairs_accepted: u32 = 0, pairs_refused: u32 = 0, defaults: u32 = 0 } = .{};
    for (0..5_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const gen: Gen = .{ .r = r, .a = a };
        const t = try opened(gen, try gen.typeOf(0, false));
        const v = try gen.valueOf(t, 0);
        var text: std.ArrayList(u8) = .empty;
        try encode(&text, a, t, v);
        const first = (try described(a, t)) orelse {
            counts.ambiguous += 1;
            continue;
        };
        counts.cases += 1;
        // G1: a default in the schema is the text the model encodes for it (E2).
        if (t.* == .record or t.* == .class) {
            const object = if (t.* == .record) t.record else t.class;
            const schema = (try persist_schema.parse(a, first.text)).full;
            const entry = schema.types[schema.cells[0].value];
            const fields = if (entry == .@"struct") entry.@"struct".fields else entry.class.fields;
            for (object.fields, fields) |field, written| {
                if (field.default) |d| {
                    var expected: std.ArrayList(u8) = .empty;
                    try encode(&expected, a, field.value_type, d.*);
                    try std.testing.expectEqualStrings(expected.items, written.default.?);
                    counts.defaults += 1;
                } else try std.testing.expect(written.default == null);
            }
        }
        // PM4: a chain of allowed evolutions, each passed by both; each reversed, refused by both.
        var chain: [5]*const MType = undefined;
        var schemas: [5]Described = undefined;
        chain[0] = t;
        schemas[0] = first;
        var length: usize = 1;
        const wanted = r.intRangeAtMost(usize, 1, 4);
        while (length <= wanted) {
            const next = (try evolve(gen, chain[length - 1], true)) orelse break;
            const next_schema = (try described(a, next)) orelse break;
            try std.testing.expect(try modelCompatible(a, chain[length - 1], next));
            if (!try accepts(a, schemas[length - 1].text, next_schema.text)) {
                std.debug.print("refused an allowed evolution:\n{s}{s}", .{ schemas[length - 1].text, next_schema.text });
                return error.TestUnexpectedResult;
            }
            try std.testing.expect(!try modelCompatible(a, next, chain[length - 1]));
            try std.testing.expect(!try accepts(a, next_schema.text, schemas[length - 1].text));
            counts.downgrades += 1;
            chain[length] = next;
            schemas[length] = next_schema;
            length += 1;
        }
        if (length > 1) {
            counts.allowed += 1;
            // The check is transitive (G4): the first version against the last.
            try std.testing.expect(try accepts(a, schemas[0].text, schemas[length - 1].text));
            var expected = v;
            for (chain[0 .. length - 1], chain[1..length]) |older, newer| expected = try upgrade(a, older, newer, expected);
            const last = chain[length - 1];
            try std.testing.expect(identical(try decode(a, last, text.items), expected));
            const got = (try readAs(&machine, a, schemas[length - 1], last, text.items)) orelse return error.TestUnexpectedResult;
            try std.testing.expect(identical(got, expected));
            if (length > 2) {
                counts.chains += 1;
                counts.steps += @intCast(length - 1);
            }
        }
        // PM5: a forbidden change, refused by both.
        if (try evolve(gen, t, false)) |bad| if (try described(a, bad)) |bad_schema| {
            try std.testing.expect(!try modelCompatible(a, t, bad));
            if (try accepts(a, first.text, bad_schema.text)) {
                std.debug.print("accepted a forbidden change:\n{s}{s}", .{ first.text, bad_schema.text });
                return error.TestUnexpectedResult;
            }
            counts.forbidden += 1;
        };
        // PM6: a random pair, one verdict; when accepted, the old text reads as `upgrade` says.
        const other = try opened(gen, try gen.typeOf(0, false));
        if (try described(a, other)) |other_schema| {
            const verdict = try modelCompatible(a, t, other);
            try std.testing.expectEqual(verdict, try accepts(a, first.text, other_schema.text));
            if (verdict) {
                const expected = try upgrade(a, t, other, v);
                const got = (try readAs(&machine, a, other_schema, other, text.items)) orelse return error.TestUnexpectedResult;
                try std.testing.expect(identical(got, expected));
                counts.pairs_accepted += 1;
            } else counts.pairs_refused += 1;
        }
    }
    // Enough of every kind of case to mean something.
    try std.testing.expect(counts.cases > 4_500 and counts.allowed > 800 and counts.chains > 500 and counts.downgrades > 2_000 and counts.forbidden > 4_000 and counts.pairs_accepted > 80 and counts.defaults > 400);
}
