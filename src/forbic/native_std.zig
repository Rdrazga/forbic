//! Standard native functions: small pure kernels that every Forbic host offers by
//! default. Each is deterministic across hosts (no libm, no allocation beyond the
//! context) and declares an exact cost. Hosts may replace or extend the table.
const std = @import("std");
const types = @import("types.zig");
const native = @import("native.zig");
const search = @import("text_search.zig");

const Context = native.Context;

fn sum(ctx: *Context, items: native.Array(i64)) native.Error!i64 {
    _ = ctx;
    var total: i64 = 0;
    for (0..items.len()) |i| total = std.math.add(i64, total, items.at(i)) catch return error.Failed;
    return total;
}
fn sumFloat(ctx: *Context, items: native.Array(f64)) f64 {
    _ = ctx;
    var total: f64 = 0;
    for (0..items.len()) |i| total += items.at(i);
    return total;
}
fn minimum(ctx: *Context, items: native.Array(i64)) ?i64 {
    _ = ctx;
    if (items.len() == 0) return null;
    var best = items.at(0);
    for (1..items.len()) |i| best = @min(best, items.at(i));
    return best;
}
fn maximum(ctx: *Context, items: native.Array(i64)) ?i64 {
    _ = ctx;
    if (items.len() == 0) return null;
    var best = items.at(0);
    for (1..items.len()) |i| best = @max(best, items.at(i));
    return best;
}
fn sorted(ctx: *Context, items: native.Array(i64)) native.Error!native.ArrayOut(i64) {
    const out = try ctx.array(i64, items.len());
    for (0..items.len()) |i| out.set(i, items.at(i));
    std.mem.sort(types.Value, out.items, {}, struct {
        fn less(_: void, a: types.Value, b: types.Value) bool {
            return a.integer < b.integer;
        }
    }.less);
    return out;
}
fn reversed(ctx: *Context, items: native.Array(i64)) native.Error!native.ArrayOut(i64) {
    const out = try ctx.array(i64, items.len());
    for (0..items.len()) |i| out.set(i, items.at(items.len() - 1 - i));
    return out;
}
fn range(ctx: *Context, count: i64) native.Error!native.ArrayOut(i64) {
    if (count < 0) return error.Failed;
    const wanted = std.math.cast(usize, count) orelse return error.AggregateLimit;
    const out = try ctx.array(i64, wanted);
    for (0..out.items.len) |i| out.set(i, @intCast(i));
    return out;
}
fn find(ctx: *Context, items: native.Array(i64), wanted: i64) ?i64 {
    _ = ctx;
    for (0..items.len()) |i| if (items.at(i) == wanted) return @intCast(i);
    return null;
}
fn dot(ctx: *Context, a: native.Array(f64), b: native.Array(f64)) native.Error!f64 {
    _ = ctx;
    if (a.len() != b.len()) return error.Failed;
    var total: f64 = 0;
    for (0..a.len()) |i| total += a.at(i) * b.at(i);
    return total;
}
fn squareRoot(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return @sqrt(x);
}
fn absolute(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return @abs(x);
}
fn byteLength(ctx: *Context, text: []const u8) i64 {
    _ = ctx;
    return @intCast(text.len);
}

fn onBoundary(text: []const u8, index: usize) bool {
    return index == text.len or (text[index] & 0xC0) != 0x80;
}
fn substring(ctx: *Context, text: []const u8, start: i64, length: i64) ?[]const u8 {
    _ = ctx;
    if (start < 0 or length < 0) return null;
    const from: usize = @intCast(start);
    const count: usize = @intCast(length);
    if (from > text.len or count > text.len - from) return null;
    if (!onBoundary(text, from) or !onBoundary(text, from + count)) return null;
    return text[from .. from + count];
}
fn indexOf(ctx: *Context, text: []const u8, needle: []const u8) ?i64 {
    _ = ctx;
    return if (search.indexOfPos(text, 0, needle)) |at| @intCast(at) else null;
}
fn contains(ctx: *Context, text: []const u8, needle: []const u8) bool {
    _ = ctx;
    return search.indexOfPos(text, 0, needle) != null;
}
fn startsWith(ctx: *Context, text: []const u8, prefix: []const u8) bool {
    _ = ctx;
    return std.mem.startsWith(u8, text, prefix);
}
fn endsWith(ctx: *Context, text: []const u8, suffix: []const u8) bool {
    _ = ctx;
    return std.mem.endsWith(u8, text, suffix);
}
fn upper(ctx: *Context, text: []const u8) native.Error![]const u8 {
    const out = try ctx.text(text.len);
    for (text, out) |byte, *slot| slot.* = std.ascii.toUpper(byte);
    return out;
}
fn lower(ctx: *Context, text: []const u8) native.Error![]const u8 {
    const out = try ctx.text(text.len);
    for (text, out) |byte, *slot| slot.* = std.ascii.toLower(byte);
    return out;
}
fn trim(ctx: *Context, text: []const u8) []const u8 {
    _ = ctx;
    return std.mem.trim(u8, text, " \t\r\n");
}
fn repeat(ctx: *Context, text: []const u8, count: i64) native.Error![]const u8 {
    if (count < 0) return error.Failed;
    const times = std.math.cast(usize, count) orelse return error.StringLimit;
    const total = std.math.mul(usize, text.len, times) catch return error.StringLimit;
    const out = try ctx.text(total);
    for (0..times) |i| @memcpy(out[i * text.len ..][0..text.len], text);
    return out;
}
fn join(ctx: *Context, parts: native.Array([]const u8), separator: []const u8) native.Error![]const u8 {
    var total: usize = 0;
    for (0..parts.len()) |i| {
        total = std.math.add(usize, total, parts.at(i).len) catch return error.StringLimit;
        if (i != 0) total = std.math.add(usize, total, separator.len) catch return error.StringLimit;
    }
    const out = try ctx.text(total);
    var at: usize = 0;
    for (0..parts.len()) |i| {
        if (i != 0) {
            @memcpy(out[at..][0..separator.len], separator);
            at += separator.len;
        }
        const part = parts.at(i);
        @memcpy(out[at..][0..part.len], part);
        at += part.len;
    }
    return out;
}
fn split(ctx: *Context, text: []const u8, separator: []const u8) native.Error!native.ArrayOut([]const u8) {
    if (separator.len == 0) {
        const single = try ctx.array([]const u8, 1);
        single.set(0, text);
        return single;
    }
    var count: usize = 1;
    var scan: usize = 0;
    // The two-way search (RFC-0077): linear in the text whatever the separator is.
    const prepared = search.Pattern.init(separator);
    while (prepared.find(text, scan)) |at| : (scan = at + separator.len) count += 1;
    const out = try ctx.array([]const u8, count);
    var index: usize = 0;
    var from: usize = 0;
    while (prepared.find(text, from)) |at| : (from = at + separator.len) {
        out.set(index, text[from..at]);
        index += 1;
    }
    out.set(index, text[from..]);
    return out;
}
fn parseInt(ctx: *Context, text: []const u8) ?i64 {
    _ = ctx;
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// Names follow `std.<name>`; bind with `Sum := native{"std.sum"}`. The kernels of the Book's
/// standard functions (RFC-0077) follow the entries of this file, which keep their indices.
pub const table = base ++ @import("stdlib_natives.zig").table ++ @import("stdlib_effects.zig").table;

const base = [_]native.Entry{
    native.entry("std.sum", sum, .{ .base = 2, .per_element = 1 }),
    native.entry("std.sum_float", sumFloat, .{ .base = 2, .per_element = 1 }),
    native.entry("std.min", minimum, .{ .base = 2, .per_element = 1 }),
    native.entry("std.max", maximum, .{ .base = 2, .per_element = 1 }),
    // Upper bound for an O(n log n) sort over at most 8192 members (about 13 comparisons each).
    native.entry("std.sorted", sorted, .{ .base = 8, .per_element = 16 }),
    native.entry("std.reversed", reversed, .{ .base = 2, .per_element = 1 }),
    native.entry("std.range", range, .{ .base = 2 }),
    native.entry("std.find", find, .{ .base = 2, .per_element = 1 }),
    native.entry("std.dot", dot, .{ .base = 4, .per_element = 1 }),
    native.entry("std.sqrt", squareRoot, .{ .base = 1 }),
    native.entry("std.abs", absolute, .{ .base = 1 }),
    native.entry("std.byte_length", byteLength, .{ .base = 1 }),
    native.entry("std.substring", substring, .{ .base = 2, .per_element = 0 }),
    native.entry("std.index_of", indexOf, .{ .base = 2, .per_element = 1 }),
    native.entry("std.contains", contains, .{ .base = 2, .per_element = 1 }),
    native.entry("std.starts_with", startsWith, .{ .base = 2, .per_element = 0 }),
    native.entry("std.ends_with", endsWith, .{ .base = 2, .per_element = 0 }),
    native.entry("std.upper", upper, .{ .base = 2, .per_element = 1 }),
    native.entry("std.lower", lower, .{ .base = 2, .per_element = 1 }),
    native.entry("std.trim", trim, .{ .base = 2, .per_element = 1 }),
    native.entry("std.repeat", repeat, .{ .base = 2, .per_element = 1 }),
    native.entry("std.join", join, .{ .base = 4, .per_element = 1 }),
    native.entry("std.split", split, .{ .base = 4, .per_element = 1 }),
    native.entry("std.parse_int", parseInt, .{ .base = 2, .per_element = 1 }),
};

test "standard table entries are unique and well formed" {
    for (table, 0..) |entry, index| {
        try std.testing.expect(native.wellFormed(entry));
        for (table[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
    }
}
