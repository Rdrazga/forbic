//! Native kernels of the Book's standard functions (RFC-0077): the math functions, and the
//! array, map and string operations whose guest loop would cost a dispatch per element.
//!
//! Every kernel is pure and deterministic across hosts. The floating-point ones call
//! `stdlib_math_kernels.zig` or pure Zig code of the pinned library, never a builtin that binds
//! to a host C library. The generic ones move values of a type variable without looking inside
//! them and compare them with the structural equality `==` uses, charged as `==` charges.
//! A program reaches them by the Book's names (`Sqrt(X)`, `Items.Find[V]`), which the compiler
//! lowers to `native_call` nodes; the concrete ones can also be bound with `native{"id"}`.
const std = @import("std");
const types = @import("types.zig");
const native = @import("native.zig");
const kernels = @import("stdlib_math_kernels.zig");
const keys = @import("map_keys.zig");
const search = @import("text_search.zig");

const Context = native.Context;
const Error = native.Error;
const Any = native.Any;
const AnyArray = native.AnyArray;
const AnyOut = native.AnyOut;

// Math. The Book's rules where it states them (api:158 and following); IEEE-754 elsewhere.

fn power(ctx: *Context, base: f64, exponent: f64) f64 {
    _ = ctx;
    // The Book pins `Pow(NaN, 0.0)` and `Pow(1.0, NaN)` to one, as C's `pow` has them.
    if (exponent == 0 or base == 1) return 1;
    return kernels.pow_kernel.pow(f64, base, exponent);
}
fn exponential(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.exp_kernel.exp_f64(x);
}
fn naturalLog(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.log_kernel.log_f64(x);
}
/// `Log(Base, X)`: the base comes first.
fn logarithm(ctx: *Context, base: f64, x: f64) f64 {
    _ = ctx;
    return kernels.log_kernel.log_f64(x) / kernels.log_kernel.log_f64(base);
}
fn sine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.sin_kernel.sin_f64(x);
}
fn cosine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.cos_kernel.cos_f64(x);
}
fn tangent(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.tan_kernel.tan_f64(x);
}
/// Outside `[-1, 1]` the Book leaves the result unspecified (its engine clamps, also a NaN).
/// Here it is NaN, so that a bad argument stays visible.
fn arcSine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return std.math.asin(x);
}
fn arcCosine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return std.math.acos(x);
}
fn arcTangent(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return std.math.atan(x);
}
/// `ArcTan(Y, X)`: the angle of the direction `(X, Y)`, zero at the origin whatever the
/// signs of its zeros (api:8414).
fn arcTangent2(ctx: *Context, y: f64, x: f64) f64 {
    _ = ctx;
    if (x == 0 and y == 0) return 0;
    return std.math.atan2(y, x);
}
fn hyperbolicSine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.sinh_kernel.sinh64(x);
}
fn hyperbolicCosine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.cosh_kernel.cosh64(x);
}
fn hyperbolicTangent(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return std.math.tanh(x);
}
fn areaSine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.asinh_kernel.asinh64(x);
}
fn areaCosine(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return kernels.acosh_kernel.acosh64(x);
}
fn areaTangent(ctx: *Context, x: f64) f64 {
    _ = ctx;
    return std.math.atanh(x);
}
/// `From*(1 - Parameter) + To*Parameter`: exact at both ends (api:210).
fn lerp(ctx: *Context, from: f64, to: f64, parameter: f64) f64 {
    _ = ctx;
    return from * (1 - parameter) + to * parameter;
}
fn absoluteInteger(ctx: *Context, x: i64) Error!i64 {
    _ = ctx;
    // The least `i64` has no magnitude: the Book's 64-bit runtime stops there too (api:358).
    if (x == std.math.minInt(i64)) return error.Overflow;
    return if (x < 0) -x else x;
}
fn minimumInteger(ctx: *Context, a: i64, b: i64) i64 {
    _ = ctx;
    return @min(a, b);
}
fn maximumInteger(ctx: *Context, a: i64, b: i64) i64 {
    _ = ctx;
    return @max(a, b);
}
/// NaN is a value like any other and comes out (02:383). Of the two zeros the smaller is the
/// negative one, so the result does not depend on the order of the arguments.
fn minimumFloat(ctx: *Context, a: f64, b: f64) f64 {
    _ = ctx;
    if (types.isNan(a) or types.isNan(b)) return std.math.nan(f64);
    if (a < b) return a;
    if (b < a) return b;
    return if (std.math.signbit(a)) a else b;
}
fn maximumFloat(ctx: *Context, a: f64, b: f64) f64 {
    _ = ctx;
    if (types.isNan(a) or types.isNan(b)) return std.math.nan(f64);
    if (a > b) return a;
    if (b > a) return b;
    return if (std.math.signbit(a)) b else a;
}
/// The median of the three: the bounds may come in either order (api:8299).
fn clampInteger(ctx: *Context, value: i64, a: i64, b: i64) i64 {
    _ = ctx;
    return @max(@min(a, b), @min(value, @max(a, b)));
}
fn clampFloat(ctx: *Context, value: f64, a: f64, b: f64) f64 {
    return maximumFloat(ctx, minimumFloat(ctx, a, b), minimumFloat(ctx, value, maximumFloat(ctx, a, b)));
}
fn isFinite(ctx: *Context, x: f64) bool {
    _ = ctx;
    return std.math.isFinite(x);
}

// Arrays of any element type. A result is built member by member behind the pool's used part,
// so it takes exactly the members it has and stops with `aggregate_limit` only when they do
// not fit.

fn finish(ctx: *Context, start: usize) AnyOut {
    return .{ .span = .{ .start = @intCast(start), .end = @intCast(ctx.used) }, .items = ctx.pool[start..ctx.used] };
}

fn appendAll(ctx: *Context, items: []const types.Value) Error!void {
    for (items) |item| try ctx.append(item);
}

/// The range `start..end` of an array of `length` elements, when it is one.
fn range(length: usize, start: i64, end: i64) ?[2]usize {
    if (start < 0 or end < start) return null;
    const last = std.math.cast(usize, end) orelse return null;
    if (last > length) return null;
    return .{ @intCast(start), last };
}

/// The index of the first element equal to `wanted`.
fn arrayFind(ctx: *Context, items: AnyArray, wanted: Any) Error!?i64 {
    for (items.items, 0..) |item, index| if (try ctx.equal(item, wanted.value)) return @intCast(index);
    return null;
}
/// The elements `start..end`. The compiler guards the call with the range check that makes
/// `Slice` fail, so a range that is none is a fault of the caller.
fn arraySlice(ctx: *Context, items: AnyArray, start: i64, end: i64) Error!AnyOut {
    const bounds = range(items.items.len, start, end) orelse return error.Failed;
    const first = ctx.used;
    try appendAll(ctx, items.items[bounds[0]..bounds[1]]);
    return finish(ctx, first);
}
/// The array without the elements `start..end`.
fn arrayRemove(ctx: *Context, items: AnyArray, start: i64, end: i64) Error!AnyOut {
    const bounds = range(items.items.len, start, end) orelse return error.Failed;
    const first = ctx.used;
    try appendAll(ctx, items.items[0..bounds[0]]);
    try appendAll(ctx, items.items[bounds[1]..]);
    return finish(ctx, first);
}
/// The array with `added` in front of the element at `at`.
fn arrayInsert(ctx: *Context, items: AnyArray, at: i64, added: AnyArray) Error!AnyOut {
    const bounds = range(items.items.len, at, at) orelse return error.Failed;
    const first = ctx.used;
    try appendAll(ctx, items.items[0..bounds[0]]);
    try appendAll(ctx, added.items);
    try appendAll(ctx, items.items[bounds[0]..]);
    return finish(ctx, first);
}
/// The array without the elements equal to `wanted`.
fn arrayRemoveAll(ctx: *Context, items: AnyArray, wanted: Any) Error!AnyOut {
    const first = ctx.used;
    for (items.items) |item| {
        if (!try ctx.equal(item, wanted.value)) try ctx.append(item);
    }
    return finish(ctx, first);
}
/// The array with `with` in place of every element equal to `wanted`.
fn arrayReplaceEach(ctx: *Context, items: AnyArray, wanted: Any, with: Any) Error!AnyOut {
    const first = ctx.used;
    for (items.items) |item| try ctx.append(if (try ctx.equal(item, wanted.value)) with.value else item);
    return finish(ctx, first);
}
/// The array with `replacement` in place of every occurrence of the run `pattern`, found
/// from the left without overlap. An empty pattern occurs nowhere.
fn arrayReplaceAll(ctx: *Context, items: AnyArray, pattern: AnyArray, replacement: AnyArray) Error!AnyOut {
    const first = ctx.used;
    const source = items.items;
    const wanted = pattern.items;
    var at: usize = 0;
    while (at < source.len) {
        const found = wanted.len != 0 and wanted.len <= source.len - at and matched: {
            for (wanted, source[at..][0..wanted.len]) |want, have| {
                if (!try ctx.equal(have, want)) break :matched false;
            }
            break :matched true;
        };
        if (found) {
            try appendAll(ctx, replacement.items);
            at += wanted.len;
        } else {
            try ctx.append(source[at]);
            at += 1;
        }
    }
    return finish(ctx, first);
}
/// The elements of every row, in order.
fn arrayConcatenate(ctx: *Context, rows: native.AnyNested) Error!AnyOut {
    const first = ctx.used;
    for (0..rows.rows.len) |index| {
        // The declared cost counts the rows; an empty row still costs its visit.
        try appendAll(ctx, rows.row(index));
    }
    return finish(ctx, first);
}

/// `ConcatenateMaps`: the entries of `first` in their order, each with the value `second` has
/// for its key if it has one, and then the entries of `second` under keys `first` lacks. Each
/// map is indexed once, so the work is in proportion to the entries, not to their product.
fn mapConcatenate(ctx: *Context, first: native.AnyMap, second: native.AnyMap) Error!native.AnyMapOut {
    const start = ctx.used;
    var slots: [keys.small_slots]u32 = undefined;
    var position: usize = 0;
    {
        const overrides = try ctx.mapIndex(&slots, second.pairs);
        while (position < first.pairs.len) : (position += 2) {
            const key = first.pairs[position];
            try ctx.append(key);
            try ctx.append(if (try ctx.mapFind(overrides, key)) |at| second.pairs[at] else first.pairs[position + 1]);
        }
    }
    // The table of `second` is no longer needed: its slots hold the one of `first` now.
    const present = try ctx.mapIndex(&slots, first.pairs);
    position = 0;
    while (position < second.pairs.len) : (position += 2) {
        const key = second.pairs[position];
        if (try ctx.mapFind(present, key) != null) continue;
        try ctx.append(key);
        try ctx.append(second.pairs[position + 1]);
    }
    return .{ .out = finish(ctx, start) };
}

// Strings. Positions are code units, as everywhere (RFC-0069).

/// The position of the first code unit equal to `unit`.
fn stringFindUnit(ctx: *Context, text: []const u8, unit: i64) ?i64 {
    _ = ctx;
    const byte = std.math.cast(u8, unit) orelse return null;
    return if (std.mem.indexOfScalar(u8, text, byte)) |at| @intCast(at) else null;
}

/// `text` with `replacement` in place of every occurrence of `pattern`, found from the left
/// without overlap. An empty pattern occurs nowhere. A match of text in text starts and ends
/// between scalar values, so the result is text. The search is the two-way one: the text is
/// passed twice, once to size the result and once to build it, each in time linear in it
/// whatever the pattern, which is what the declared cost per byte pays for.
fn stringReplaceAll(ctx: *Context, text: []const u8, pattern: []const u8, replacement: []const u8) Error![]const u8 {
    if (pattern.len == 0 or pattern.len > text.len) return text;
    const prepared = search.Pattern.init(pattern);
    var count: usize = 0;
    var from: usize = 0;
    while (prepared.find(text, from)) |at| : (from = at + pattern.len) count += 1;
    if (count == 0) return text;
    const kept = text.len - count * pattern.len;
    const added = std.math.mul(usize, count, replacement.len) catch return error.StringLimit;
    const out = try ctx.text(std.math.add(usize, kept, added) catch return error.StringLimit);
    var to: usize = 0;
    from = 0;
    while (prepared.find(text, from)) |at| : (from = at + pattern.len) {
        @memcpy(out[to..][0 .. at - from], text[from..at]);
        to += at - from;
        @memcpy(out[to..][0..replacement.len], replacement);
        to += replacement.len;
    }
    @memcpy(out[to..], text[from..]);
    std.debug.assert(to + (text.len - from) == out.len);
    return out;
}

/// Appended to the standard table (`native_std.table`), so the entries before them keep their
/// indices. The costs of the generic entries cover the visit of each element of their array
/// arguments; members built and values compared are charged as they happen.
pub const table = [_]native.Entry{
    native.entry("std.pow", power, .{ .base = 4 }),
    native.entry("std.exp", exponential, .{ .base = 4 }),
    native.entry("std.ln", naturalLog, .{ .base = 4 }),
    native.entry("std.log", logarithm, .{ .base = 8 }),
    native.entry("std.sin", sine, .{ .base = 4 }),
    native.entry("std.cos", cosine, .{ .base = 4 }),
    native.entry("std.tan", tangent, .{ .base = 4 }),
    native.entry("std.arc_sin", arcSine, .{ .base = 4 }),
    native.entry("std.arc_cos", arcCosine, .{ .base = 4 }),
    native.entry("std.arc_tan", arcTangent, .{ .base = 4 }),
    native.entry("std.arc_tan2", arcTangent2, .{ .base = 4 }),
    native.entry("std.sinh", hyperbolicSine, .{ .base = 4 }),
    native.entry("std.cosh", hyperbolicCosine, .{ .base = 4 }),
    native.entry("std.tanh", hyperbolicTangent, .{ .base = 4 }),
    native.entry("std.ar_sinh", areaSine, .{ .base = 4 }),
    native.entry("std.ar_cosh", areaCosine, .{ .base = 4 }),
    native.entry("std.ar_tanh", areaTangent, .{ .base = 4 }),
    native.entry("std.lerp", lerp, .{ .base = 1 }),
    native.entry("std.abs_int", absoluteInteger, .{ .base = 1 }),
    native.entry("std.min_int", minimumInteger, .{ .base = 1 }),
    native.entry("std.max_int", maximumInteger, .{ .base = 1 }),
    native.entry("std.min_float", minimumFloat, .{ .base = 1 }),
    native.entry("std.max_float", maximumFloat, .{ .base = 1 }),
    native.entry("std.clamp_int", clampInteger, .{ .base = 1 }),
    native.entry("std.clamp_float", clampFloat, .{ .base = 1 }),
    native.entry("std.is_finite", isFinite, .{ .base = 1 }),
    native.comparableEntry("std.array_find", arrayFind, .{ .base = 2, .per_element = 1 }),
    native.entry("std.array_slice", arraySlice, .{ .base = 2 }),
    native.entry("std.array_remove", arrayRemove, .{ .base = 2 }),
    native.entry("std.array_insert", arrayInsert, .{ .base = 2 }),
    native.comparableEntry("std.array_remove_all", arrayRemoveAll, .{ .base = 2, .per_element = 1 }),
    native.comparableEntry("std.array_replace_each", arrayReplaceEach, .{ .base = 2, .per_element = 1 }),
    native.comparableEntry("std.array_replace_all", arrayReplaceAll, .{ .base = 2, .per_element = 1 }),
    native.entry("std.array_concatenate", arrayConcatenate, .{ .base = 2, .per_element = 1 }),
    native.entry("std.map_concatenate", mapConcatenate, .{ .base = 2, .per_element = 1 }),
    native.entry("std.string_find_unit", stringFindUnit, .{ .base = 2, .per_element = 1 }),
    // Two linear passes over the text, the preparation of the pattern and the copy.
    native.entry("std.string_replace_all", stringReplaceAll, .{ .base = 4, .per_element = 4 }),
};

/// The entry with this id in `natives`, which is the host's table: a host that replaces the
/// standard table without these entries leaves the names that need them undefined.
pub fn find(natives: []const native.Entry, id: []const u8) ?u16 {
    for (natives, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.id, id)) return std.math.cast(u16, index);
    }
    return null;
}

test "every entry is well formed and declares the shapes its kernel has" {
    for (table) |entry| try std.testing.expect(native.wellFormed(entry));
    const find_entry = table[find(&table, "std.array_find").?];
    try std.testing.expect(find_entry.comparable);
    try std.testing.expectEqual(native.Shape{ .element = .any, .kind = .array }, find_entry.params[0]);
    try std.testing.expectEqual(native.Shape{ .element = .any, .kind = .scalar }, find_entry.params[1]);
    try std.testing.expectEqual(native.Shape{ .element = .i64, .kind = .option }, find_entry.result);
    const maps = table[find(&table, "std.map_concatenate").?];
    try std.testing.expectEqual(native.Shape{ .element = .any, .kind = .map }, maps.result);
    const rows = table[find(&table, "std.array_concatenate").?];
    try std.testing.expectEqual(native.Shape{ .element = .any, .kind = .nested }, rows.params[0]);
    try std.testing.expect(!rows.comparable);
}

test "the math kernels follow the Book at the edges it names" {
    var pool: [1]types.Value = undefined;
    var bytes: [1]u8 = undefined;
    var strings = @import("run_strings.zig").Pool.init(bytes[0..0], &bytes);
    var ctx: Context = .{ .pool = &pool, .used = 0, .remaining = 0, .strings = &strings };
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(@as(f64, 8), power(&ctx, 2, 3));
    try std.testing.expectEqual(@as(f64, 2), power(&ctx, 4, 0.5));
    try std.testing.expectEqual(@as(f64, 0.5), power(&ctx, 2, -1));
    try std.testing.expectEqual(@as(f64, 1), power(&ctx, 0, 0));
    try std.testing.expectEqual(@as(f64, 1), power(&ctx, nan, 0));
    try std.testing.expectEqual(@as(f64, 1), power(&ctx, 1, nan));
    try std.testing.expect(std.math.isNan(power(&ctx, -8, 1.0 / 3.0)));
    try std.testing.expectEqual(@as(f64, -8), power(&ctx, -2, 3));
    try std.testing.expectEqual(@as(f64, 1), exponential(&ctx, 0));
    try std.testing.expectEqual(@as(f64, 0), exponential(&ctx, -inf));
    try std.testing.expectEqual(inf, exponential(&ctx, inf));
    try std.testing.expectEqual(@as(f64, 0), naturalLog(&ctx, 1));
    try std.testing.expectEqual(@as(f64, 1), naturalLog(&ctx, exponential(&ctx, 1)));
    try std.testing.expectEqual(-inf, naturalLog(&ctx, 0));
    try std.testing.expect(std.math.isNan(naturalLog(&ctx, -1)));
    try std.testing.expectEqual(@as(f64, 2), logarithm(&ctx, 10, 100));
    try std.testing.expectEqual(@as(f64, 3), logarithm(&ctx, 2, 8));
    try std.testing.expectEqual(@as(f64, 0), sine(&ctx, 0));
    try std.testing.expectEqual(@as(f64, 1), sine(&ctx, std.math.pi / 2.0));
    try std.testing.expectEqual(@as(f64, 1), cosine(&ctx, 0));
    try std.testing.expectEqual(@as(f64, -1), cosine(&ctx, std.math.pi));
    try std.testing.expect(std.math.isNan(sine(&ctx, nan)) and std.math.isNan(sine(&ctx, inf)) and std.math.isNan(cosine(&ctx, -inf)) and std.math.isNan(tangent(&ctx, inf)));
    // `PiFloat` is not pi, so these are near zero rather than zero (02:457).
    try std.testing.expect(sine(&ctx, std.math.pi) > 0 and sine(&ctx, std.math.pi) < 0.000001);
    try std.testing.expect(cosine(&ctx, std.math.pi / 2.0) > 0 and cosine(&ctx, std.math.pi / 2.0) < 0.000001);
    try std.testing.expect(tangent(&ctx, std.math.pi / 2.0) > 1e15 and std.math.isFinite(tangent(&ctx, std.math.pi / 2.0)));
    try std.testing.expectEqual(@as(f64, std.math.pi / 2.0), arcSine(&ctx, 1));
    try std.testing.expectEqual(@as(f64, std.math.pi), arcCosine(&ctx, -1));
    try std.testing.expectEqual(@as(f64, std.math.pi / 4.0), arcTangent(&ctx, 1));
    try std.testing.expectEqual(@as(f64, std.math.pi / 2.0), arcTangent(&ctx, inf));
    try std.testing.expect(std.math.isNan(arcSine(&ctx, 2)) and std.math.isNan(arcCosine(&ctx, -2)) and std.math.isNan(arcSine(&ctx, nan)));
    try std.testing.expectEqual(@as(f64, 0), arcTangent2(&ctx, 0, 0));
    try std.testing.expectEqual(@as(f64, 0), arcTangent2(&ctx, 0, -0.0));
    try std.testing.expectEqual(@as(f64, std.math.pi / 4.0), arcTangent2(&ctx, inf, inf));
    try std.testing.expectEqual(@as(f64, 3.0 * std.math.pi / 4.0), arcTangent2(&ctx, inf, -inf));
    try std.testing.expectEqual(@as(f64, std.math.pi), arcTangent2(&ctx, 0, -1));
    try std.testing.expect(std.math.isNan(arcTangent2(&ctx, nan, 1)));
    try std.testing.expectEqual(inf, hyperbolicSine(&ctx, inf));
    try std.testing.expectEqual(-inf, hyperbolicSine(&ctx, -inf));
    try std.testing.expectEqual(@as(f64, 1), hyperbolicCosine(&ctx, 0));
    try std.testing.expectEqual(inf, hyperbolicCosine(&ctx, -inf));
    try std.testing.expectEqual(@as(f64, 1), hyperbolicTangent(&ctx, inf));
    try std.testing.expectEqual(@as(f64, -1), hyperbolicTangent(&ctx, -inf));
    try std.testing.expectEqual(inf, areaSine(&ctx, inf));
    try std.testing.expectEqual(-inf, areaSine(&ctx, -inf));
    try std.testing.expect(std.math.isNan(areaCosine(&ctx, 0.5)) and std.math.isNan(areaCosine(&ctx, -inf)));
    try std.testing.expectEqual(inf, areaCosine(&ctx, inf));
    try std.testing.expectEqual(@as(f64, 2), @round(areaCosine(&ctx, hyperbolicCosine(&ctx, -2)) * 1e9) / 1e9);
    try std.testing.expectEqual(inf, areaTangent(&ctx, 1));
    try std.testing.expectEqual(-inf, areaTangent(&ctx, -1));
    try std.testing.expect(std.math.isNan(areaTangent(&ctx, 2)) and std.math.isNan(areaTangent(&ctx, inf)));
    try std.testing.expectEqual(@as(f64, 3), lerp(&ctx, 3, 7, 0));
    try std.testing.expectEqual(@as(f64, 7), lerp(&ctx, 3, 7, 1));
    try std.testing.expectEqual(@as(f64, 11), lerp(&ctx, 3, 7, 2));
    try std.testing.expectEqual(@as(f64, -1), lerp(&ctx, 3, 7, -1));
    try std.testing.expect(std.math.isNan(maximumFloat(&ctx, nan, 5)) and std.math.isNan(minimumFloat(&ctx, 5, nan)));
    try std.testing.expectEqual(inf, maximumFloat(&ctx, inf, 100));
    try std.testing.expectEqual(-inf, minimumFloat(&ctx, -inf, 100));
    try std.testing.expect(std.math.signbit(minimumFloat(&ctx, 0.0, -0.0)) and std.math.signbit(minimumFloat(&ctx, -0.0, 0.0)));
    try std.testing.expect(!std.math.signbit(maximumFloat(&ctx, 0.0, -0.0)) and !std.math.signbit(maximumFloat(&ctx, -0.0, 0.0)));
    try std.testing.expectEqual(@as(i64, 2), clampInteger(&ctx, 5, 2, -2));
    try std.testing.expectEqual(@as(i64, 2), clampInteger(&ctx, 5, -2, 2));
    try std.testing.expectEqual(@as(i64, -2), clampInteger(&ctx, -9, 2, -2));
    try std.testing.expectEqual(@as(i64, 1), clampInteger(&ctx, 1, 2, -2));
    try std.testing.expectEqual(@as(f64, 2), clampFloat(&ctx, 5, 2, -2));
    try std.testing.expect(std.math.isNan(clampFloat(&ctx, nan, 0, 1)) and std.math.isNan(clampFloat(&ctx, 0, nan, 1)));
    try std.testing.expectError(error.Overflow, absoluteInteger(&ctx, std.math.minInt(i64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try absoluteInteger(&ctx, -std.math.maxInt(i64)));
    try std.testing.expect(isFinite(&ctx, 5) and !isFinite(&ctx, inf) and !isFinite(&ctx, -inf) and !isFinite(&ctx, nan));
}

test "the copied kernels compute what the toolchain's own do" {
    // Where no C library is linked the builtins are the functions the copies were taken from,
    // so the two must agree to the bit; with one linked they are that library's.
    if (@import("builtin").link_libc) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x77_0077);
    const random = prng.random();
    var round: usize = 0;
    while (round < 20000) : (round += 1) {
        // Bit patterns reach every exponent, the subnormals, the infinities and the NaNs;
        // the scaled draws stay where the functions are not flat.
        const x: f64 = switch (round % 4) {
            0 => @bitCast(random.int(u64)),
            1 => (random.float(f64) - 0.5) * 20,
            2 => (random.float(f64) - 0.5) * 1500,
            else => (random.float(f64) - 0.5) * 1e6,
        };
        try expectSameBits(@exp(x), kernels.exp_kernel.exp_f64(x));
        try expectSameBits(@log(x), kernels.log_kernel.log_f64(x));
        try expectSameBits(@sin(x), kernels.sin_kernel.sin_f64(x));
        try expectSameBits(@cos(x), kernels.cos_kernel.cos_f64(x));
        try expectSameBits(@tan(x), kernels.tan_kernel.tan_f64(x));
        try expectSameBits(std.math.sinh(x), kernels.sinh_kernel.sinh64(x));
        try expectSameBits(std.math.cosh(x), kernels.cosh_kernel.cosh64(x));
        try expectSameBits(std.math.asinh(x), kernels.asinh_kernel.asinh64(x));
        try expectSameBits(std.math.acosh(x), kernels.acosh_kernel.acosh64(x));
        const y: f64 = if (round % 3 == 0) @bitCast(random.int(u64)) else (random.float(f64) - 0.5) * 40;
        try expectSameBits(std.math.pow(f64, x, y), kernels.pow_kernel.pow(f64, x, y));
    }
}

fn expectSameBits(expected: f64, actual: f64) !void {
    if (std.math.isNan(expected) and std.math.isNan(actual)) return;
    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
}

test "replacing a pattern in text finds occurrences from the left and hands back text it did not change" {
    var pool: [1]types.Value = undefined;
    var bytes: [256]u8 = undefined;
    const run_strings = @import("run_strings.zig");
    const source = "Hey, this is a string, Hello!";
    @memcpy(bytes[0..source.len], source);
    var strings = run_strings.Pool.init(bytes[0..source.len], bytes[source.len..]);
    var ctx: Context = .{ .pool = &pool, .used = 0, .remaining = 1000, .strings = &strings };
    const text = bytes[0..source.len];
    try std.testing.expectEqualStrings("Applesy, this is a string, Applesllo!", try stringReplaceAll(&ctx, text, "He", "Apples"));
    // Nothing found, an empty pattern and a pattern longer than the text hand the text back.
    const before = strings.used;
    try std.testing.expectEqual(text.ptr, (try stringReplaceAll(&ctx, text, "xyz", "Q")).ptr);
    try std.testing.expectEqual(text.ptr, (try stringReplaceAll(&ctx, text, "", "Q")).ptr);
    try std.testing.expectEqual(text.ptr, (try stringReplaceAll(&ctx, text, source ++ "!", "Q")).ptr);
    try std.testing.expectEqual(before, strings.used);
    try std.testing.expectEqualStrings("Hey, tha string, Hello!", try stringReplaceAll(&ctx, text, "is ", ""));
    // Matches do not overlap: the search goes on after each one.
    try std.testing.expectEqualStrings("bba", try stringReplaceAll(&ctx, "aaaaa", "aa", "b"));
    try std.testing.expectEqualStrings("", try stringReplaceAll(&ctx, "abab", "abab", ""));
    // The kernel charges nothing of its own but the bytes of its result: the search is paid
    // for by the declared cost, which is linear whatever the pattern.
    const charged = ctx.charged;
    try std.testing.expectEqual(@as([*]const u8, "aaaaaaaaaaaaaaaa"), (try stringReplaceAll(&ctx, "aaaaaaaaaaaaaaaa", "aaaab", "c")).ptr);
    try std.testing.expectEqual(charged, ctx.charged);
    try std.testing.expectEqual(@as(?i64, 3), stringFindUnit(&ctx, "José", 0xC3));
    try std.testing.expectEqual(@as(?i64, null), stringFindUnit(&ctx, "José", 256));
    try std.testing.expectEqual(@as(?i64, null), stringFindUnit(&ctx, "José", -1));
    try std.testing.expectEqual(@as(?i64, null), stringFindUnit(&ctx, "", 0));
}
