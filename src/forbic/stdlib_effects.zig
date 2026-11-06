//! The effect natives behind the Book's `Print`, `GetRandomInt`, `GetRandomFloat` and `Shuffle`
//! (RFC-0079), and the one pure kernel `Shuffle` needs.
//!
//! An effect native does nothing to the world itself. `print` hands its text to the run's
//! effect log, which shows it only once no rollback can undo it; the draws read the run's
//! stream, which is a function of the run's seed. Each is a function of scalar and string
//! arguments, which is what lets a report replay run it again and require the same result.
//! `Shuffle` is therefore two calls: one draw, and a pure permutation keyed by what was drawn.
const std = @import("std");
const types = @import("types.zig");
const native = @import("native.zig");
const effects = @import("effects.zig");

const Context = native.Context;
const Error = native.Error;

/// One line of output. Nothing is visible until the outermost region around the call commits.
fn print(ctx: *Context, text: []const u8) Error!void {
    try ctx.act(text);
}

/// A uniform integer in `[Low, High]`, both included, the bounds in either order (api:302).
fn randomInt(ctx: *Context, low: i64, high: i64) Error!i64 {
    return ctx.drawInteger(low, high);
}

/// A uniform float in `[Low, High]`, the bounds in either order (api:288).
fn randomFloat(ctx: *Context, low: f64, high: f64) Error!f64 {
    return ctx.drawFloat(low, high);
}

/// One word of the stream as an integer: the key of a `Shuffle`.
fn randomWord(ctx: *Context) Error!i64 {
    return @bitCast(try ctx.draw());
}

/// The elements of `items` in the order the key decides: a Fisher-Yates pass over the stream
/// the key names. Pure: the same array and key give the same order on every host, and a key
/// names one of at most 2^64 orders, which is all a 64-bit seed can name anyway.
fn shuffled(ctx: *Context, items: native.AnyArray, key: i64) Error!native.AnyOut {
    const first = ctx.used;
    for (items.items) |item| try ctx.append(item);
    const out = ctx.pool[first..ctx.used];
    var stream: effects.Stream = .{ .seed = @bitCast(key) };
    var index = out.len;
    while (index > 1) {
        index -= 1;
        const before = stream.position;
        const other = stream.below(index + 1) orelse return error.Failed;
        // The declared cost pays for the first word of each element; a rejected one is extra.
        try ctx.spend(stream.position - before - 1);
        std.mem.swap(types.Value, &out[index], &out[@intCast(other)]);
    }
    return .{ .span = .{ .start = @intCast(first), .end = @intCast(ctx.used) }, .items = out };
}

fn predicting(comptime made: native.Entry) native.Entry {
    var entry = made;
    entry.predicts = true;
    return entry;
}

/// Unix time in seconds (RFC-0086 I5): one reading of the world per tick of the virtual clock,
/// which never goes back. The run's input log decides whether this call asks the world.
fn clockSeconds(ctx: *Context) Error!f64 {
    return @bitCast((try ctx.input(.clock, 0)).bits);
}

/// The next line of the reader's stream (RFC-0086 I6, I7), copied into the run's strings and
/// charged as a string of its length is; null at the end of the stream. The run's input log
/// decides whether the line comes from the world or from the record of an earlier run.
fn readLine(ctx: *Context, reader: native.Reader) Error!?[]const u8 {
    const answer = try ctx.input(.line, reader.grant);
    if (answer.status == .end) return null;
    const line = try ctx.text(answer.bytes.len);
    @memcpy(line, answer.bytes);
    return line;
}

/// One line on the writer's channel (RFC-0086 H5): an action, as `print`'s is on channel 0.
fn writeLine(ctx: *Context, writer: native.Writer, text: []const u8) Error!void {
    // Saturating: a forged index past every grant is refused by `actOn`, not by arithmetic.
    try ctx.actOn(writer.grant +| 1, text);
}

/// These follow every other entry of the standard table, whose indices they leave alone.
pub const table = [_]native.Entry{
    // The output of a string predicts, as the Book's API has it (RFC-0085, V22).
    predicting(native.effectEntry("std.print", print, .{ .base = 2 }, .output)),
    native.effectEntry("std.random_int", randomInt, .{ .base = 2 }, .draw),
    native.effectEntry("std.random_float", randomFloat, .{ .base = 2 }, .draw),
    native.effectEntry("std.random_word", randomWord, .{ .base = 1 }, .draw),
    native.entry("std.array_shuffled", shuffled, .{ .base = 2, .per_element = 1 }),
    // RFC-0086, P2.2: appended, so that no index moves.
    native.effectEntry("std.clock_seconds", clockSeconds, .{ .base = 2 }, .input),
    // RFC-0086, P2.3: appended, so that no index moves. Neither predicts: a reader is the
    // authority's input, and a writer's channel the authority's output (D15).
    native.effectEntry("std.read_line", readLine, .{ .base = 2 }, .input),
    native.effectEntry("std.write_line", writeLine, .{ .base = 2 }, .output),
};

test "the effect entries are well formed and declare what they do" {
    for (table) |entry| try std.testing.expect(native.wellFormed(entry));
    try std.testing.expectEqual(native.Effect.output, table[0].effect);
    try std.testing.expectEqual(native.Shape{ .element = .i64, .kind = .unit }, table[0].result);
    for (table[1..4]) |entry| try std.testing.expectEqual(native.Effect.draw, entry.effect);
    try std.testing.expectEqual(native.Effect.none, table[4].effect);
    // What the table refuses: an action that answers, a draw that yields nothing or a string,
    // an effect over an aggregate, and a pure native that yields nothing.
    var forged = table[0];
    forged.result = .{ .element = .i64, .kind = .scalar };
    try std.testing.expect(!native.wellFormed(forged));
    forged = table[1];
    forged.result = .{ .element = .i64, .kind = .unit };
    try std.testing.expect(!native.wellFormed(forged));
    forged.result = .{ .element = .string, .kind = .scalar };
    try std.testing.expect(!native.wellFormed(forged));
    forged = table[1];
    forged.params = &.{.{ .element = .i64, .kind = .array }};
    try std.testing.expect(!native.wellFormed(forged));
    forged = table[0];
    forged.effect = .none;
    try std.testing.expect(!native.wellFormed(forged));
    forged = table[4];
    forged.effect = .draw;
    try std.testing.expect(!native.wellFormed(forged));
}

test "the shuffle kernel permutes, is a function of its key and visits every order of three" {
    var pool: [64]types.Value = undefined;
    for (0..5) |index| pool[index] = .{ .integer = @intCast(index) };
    var no_bytes: [0]u8 = .{};
    var text = @import("run_strings.zig").Pool.init(no_bytes[0..0], &no_bytes);
    const items: native.AnyArray = .{ .items = pool[0..5] };
    var ctx: Context = .{ .pool = &pool, .used = 5, .remaining = 1000, .strings = &text };
    const one = try shuffled(&ctx, items, 42);
    const again = try shuffled(&ctx, items, 42);
    var present: [5]bool = @splat(false);
    for (one.items, again.items) |a, b| {
        try std.testing.expectEqual(a.integer, b.integer);
        present[@intCast(a.integer)] = true;
    }
    for (present) |found| try std.testing.expect(found);
    // The argument is untouched: arrays are values.
    for (pool[0..5], 0..) |value, index| try std.testing.expectEqual(@as(i64, @intCast(index)), value.integer);
    // Empty and single arrays need no word.
    ctx.used = 5;
    try std.testing.expectEqual(@as(usize, 0), (try shuffled(&ctx, .{ .items = pool[0..0] }, 1)).items.len);
    try std.testing.expectEqual(@as(i64, 0), (try shuffled(&ctx, .{ .items = pool[0..1] }, 1)).items[0].integer);
    // All six orders of three elements come up, about equally often.
    var counts: [27]u32 = @splat(0);
    for (0..6000) |key| {
        ctx.used = 5;
        ctx.remaining = 1000;
        const out = try shuffled(&ctx, .{ .items = pool[0..3] }, @intCast(key));
        counts[@intCast(out.items[0].integer * 9 + out.items[1].integer * 3 + out.items[2].integer)] += 1;
    }
    var orders: u32 = 0;
    for (counts) |count| if (count != 0) {
        orders += 1;
        try std.testing.expect(count > 850 and count < 1150);
    };
    try std.testing.expectEqual(@as(u32, 6), orders);
}

test "the clock is an input entry, and the table refuses an input that yields nothing or a collection" {
    const clock = table[5];
    try std.testing.expectEqualStrings("std.clock_seconds", clock.id);
    try std.testing.expect(native.wellFormed(clock));
    try std.testing.expectEqual(native.Effect.input, clock.effect);
    try std.testing.expectEqual(@as(usize, 0), clock.params.len);
    try std.testing.expectEqual(native.Shape{ .element = .float, .kind = .scalar }, clock.result);
    var forged = clock;
    for ([_]native.Shape{ .{ .element = .i64, .kind = .unit }, .{ .element = .i64, .kind = .array }, .{ .element = .any, .kind = .array }, .{ .element = .float, .kind = .map } }) |result| {
        forged.result = result;
        try std.testing.expect(!native.wellFormed(forged));
    }
    forged = clock;
    forged.params = &.{.{ .element = .i64, .kind = .array }};
    try std.testing.expect(!native.wellFormed(forged));
    // An option of a string is what a line will be (P2.3).
    forged = clock;
    forged.result = .{ .element = .string, .kind = .option };
    try std.testing.expect(native.wellFormed(forged));
}

test "the handle natives are well formed, and a table that misplaces a handle is refused (RFC-0086, P2.3)" {
    const read_line = table[6];
    const write_line = table[7];
    try std.testing.expectEqualStrings("std.read_line", read_line.id);
    try std.testing.expectEqualStrings("std.write_line", write_line.id);
    for ([_]native.Entry{ read_line, write_line }) |entry| {
        try std.testing.expect(native.wellFormed(entry));
        // Neither predicts: both dictate.
        try std.testing.expect(native.dictates(entry));
    }
    try std.testing.expectEqual(native.Effect.input, read_line.effect);
    try std.testing.expectEqual(native.Effect.output, write_line.effect);
    try std.testing.expectEqualSlices(native.Shape, &.{.{ .element = .reader, .kind = .scalar }}, read_line.params);
    try std.testing.expectEqual(native.Shape{ .element = .string, .kind = .option }, read_line.result);
    try std.testing.expectEqualSlices(native.Shape, &.{ .{ .element = .writer, .kind = .scalar }, .{ .element = .string, .kind = .scalar } }, write_line.params);
    const reader: native.Shape = .{ .element = .reader, .kind = .scalar };
    const writer: native.Shape = .{ .element = .writer, .kind = .scalar };
    const text: native.Shape = .{ .element = .string, .kind = .scalar };
    var forged = write_line;
    // A writer that is not first, two writers, a reader to an action.
    for ([_][]const native.Shape{ &.{ text, writer }, &.{ writer, writer }, &.{reader}, &.{ reader, text }, &.{.{ .element = .writer, .kind = .array }} }) |params| {
        forged.params = params;
        try std.testing.expect(!native.wellFormed(forged));
    }
    // A writer to an input, a reader in a collection, a handle that is made.
    forged = read_line;
    for ([_][]const native.Shape{ &.{writer}, &.{.{ .element = .reader, .kind = .option }}, &.{ text, reader } }) |params| {
        forged.params = params;
        try std.testing.expect(!native.wellFormed(forged));
    }
    forged = read_line;
    for ([_]native.Shape{ reader, writer, .{ .element = .reader, .kind = .option }, .{ .element = .writer, .kind = .array } }) |result| {
        forged.result = result;
        try std.testing.expect(!native.wellFormed(forged));
    }
    // A handle to a native that only computes, or that draws.
    forged = read_line;
    forged.effect = .none;
    try std.testing.expect(!native.wellFormed(forged));
    forged.effect = .draw;
    forged.result = .{ .element = .i64, .kind = .scalar };
    try std.testing.expect(!native.wellFormed(forged));
    // A predicting write is refused the bit: only the output of one string predicts.
    forged = write_line;
    forged.predicts = true;
    try std.testing.expect(!native.wellFormed(forged));
}
