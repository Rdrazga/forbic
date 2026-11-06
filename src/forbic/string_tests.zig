//! Run-owned strings: concatenation, length, conversion, pool limits and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

test "concatenation joins literals functions and unicode with byte lengths" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Name:string=\"雪\"\nGreeting<public>:string=\"hello, \"+Name+\"!\"\nSize<public>:i64=Greeting.Length\nEmpty<public>:i64=(\"\"+\"\").Length\nJoin(A:string,B:string)<computes>:string=A+\"-\"+B\nPair<public>:string=Join(\"x\",Join(\"y\",\"z\"))\nWrap(S:string)<computes>:string=\"(\"+S+\")\"\nChain<public>:string=Iterate(Wrap,3,\"a\")");
    try std.testing.expectEqualStrings("hello, 雪!", x.get("Greeting").?.string);
    try std.testing.expectEqual(@as(i64, 11), x.get("Size").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("Empty").?.integer);
    try std.testing.expectEqualStrings("x-y-z", x.get("Pair").?.string);
    try std.testing.expectEqualStrings("(((a)))", x.get("Chain").?.string);
}

test "ToString renders integers logic and floats exactly" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Inf2:float=Inf\nLow:float=-Inf\nNan:float=NaN\nA<public>:string=ToString(0)+\"|\"+ToString(-7)+\"|\"+ToString(9223372036854775807)+\"|\"+ToString(-9223372036854775807-1)\nB<public>:string=ToString(true)+\"|\"+ToString(false)\nC<public>:string=ToString(3.5)+\"|\"+ToString(-0.25)+\"|\"+ToString(100.0)+\"|\"+ToString(0.1)\nD<public>:string=ToString(Inf2)+\"|\"+ToString(Low)+\"|\"+ToString(Nan)");
    try std.testing.expectEqualStrings("0|-7|9223372036854775807|-9223372036854775808", x.get("A").?.string);
    try std.testing.expectEqualStrings("true|false", x.get("B").?.string);
    try std.testing.expectEqualStrings("3.5|-0.25|100|0.1", x.get("C").?.string);
    try std.testing.expectEqualStrings("Inf|-Inf|NaN", x.get("D").?.string);
}

test "dynamic strings compare by content and work as map keys" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Key:string=\"a\"+\"b\"\nTable:map(string,i64)=map{\"ab\"=>1,\"cd\"=>2}\nSame<public>:logic=(Key==\"ab\")\nOther<public>:logic=(Key==\"abc\")\nFound<public>:i64=Or(Lookup(Table,Key),-1)\nMissed<public>:i64=Or(Lookup(Table,Key+\"x\"),-1)\nBuilt<public>:i64=Or(Lookup(Table,\"c\"+\"d\"),-1)");
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expect(!x.get("Other").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), x.get("Found").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Missed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Built").?.integer);
}

test "string pool exhaustion is a checked diagnostic in both machines with healthy reuse" {
    const h = try harness.create();
    defer scratch.release(h);
    // Doubling until the text alone is larger than the pool, with fuel to spare.
    const doublings = comptime std.math.log2_int(usize, types.limits.string_bytes) + 1;
    const p = try h.compile(std.fmt.comptimePrint("Double(S:string)<computes>:string=S+S\nBig<public>:string=Iterate(Double,{d},\"ab\")", .{doublings}));
    const ample = 8 * types.limits.string_bytes;
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, ample);
    const actual = h.runtime.evaluate(p, ample);
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, actual.failed.code);
    // Work is charged per byte: a small budget runs out before the pool does.
    const starved = h.runtime.evaluate(p, 40);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, starved.failed.code);
    // The workspace recovers: a program that stays within the pool succeeds afterwards.
    const x = try h.execute("Double(S:string)<computes>:string=S+S\nOk<public>:i64=Iterate(Double,10,\"ab\").Length");
    try std.testing.expectEqual(@as(i64, 2048), x.get("Ok").?.integer);
}

test "string operators and conversions reject wrong types with exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "A:string=\"a\"+1", .type_mismatch },
        .{ "A:string=1+\"a\"", .type_mismatch },
        .{ "A:string=\"a\"-\"b\"", .type_mismatch },
        .{ "A:string=\"a\"*\"b\"", .type_mismatch },
        // `ToString` of a string is the string (RFC-0077); of a structural value it is no form.
        .{ "A:string=ToString(tuple{\"a\"})", .type_mismatch },
        .{ "A:string=ToString(array{1})", .type_mismatch },
        .{ "A:string=ToString[1]", .expected_call },
        .{ "A:i64=\"a\".Size", .unknown_field },
        .{ "A:i64=\"a\".Length(1)", .not_callable },
        .{ "ToString:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected string admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("string diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
}

test "failed attempts keep strings valid and reports replay them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0\nItems:[]string=array{\"p\",\"q\"}\nTry(N:i64)<transacts>:string=Attempt(Block{set Cell=Cell+1;ToString(N)+Items[N]},\"none:\"+ToString(Cell))\nA<public>:string=Try(1)\nB<public>:string=Try(5)\nC<public>:string=Try(0)\nAll<public>:string=A+\",\"+B+\",\"+C");
    try std.testing.expectEqualStrings("1q", x.get("A").?.string);
    try std.testing.expectEqualStrings("none:1", x.get("B").?.string);
    try std.testing.expectEqualStrings("0p", x.get("C").?.string);
    try std.testing.expectEqualStrings("1q,none:1,0p", x.get("All").?.string);
}

test "forged string nodes are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("S<public>:string=\"a\"+\"b\"\nN<public>:i64=S.Length\nT<public>:string=ToString(N)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var concat: ?usize = null;
    var length: ?usize = null;
    var text: ?usize = null;
    for (nodes, 0..) |node, index| switch (node.kind) {
        .string_concat => concat = index,
        .string_length => length = index,
        .to_string => text = index,
        else => {},
    };
    try std.testing.expect(concat != null and length != null and text != null);
    for (0..5) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[concat.?].value_type = .i64,
            1 => nodes[concat.?].kind.string_concat.rhs = @intCast(length.?),
            2 => nodes[length.?].value_type = .string,
            3 => nodes[text.?].kind.to_string = @intCast(concat.?),
            4 => nodes[text.?].kind.to_string = @intCast(text.?),
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
}

const native = @import("native.zig");

fn outsider(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = ctx;
    _ = args;
    return .{ .scalar = .{ .string = "text that does not live in the run pool" } };
}
fn invalidUtf8(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = args;
    const out = ctx.text(2) catch return .{ .fault = .string_limit };
    out[0] = 0xff;
    out[1] = 0xfe;
    return .{ .scalar = .{ .string = out } };
}
fn emptyLiteral(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = ctx;
    _ = args;
    return .{ .scalar = .{ .string = "" } };
}
fn hog(ctx: *native.Context, count: i64) native.Error![]const u8 {
    const out = try ctx.text(@intCast(count));
    @memset(out, 'x');
    return out;
}

const raw = [_]native.Entry{
    .{ .id = "t.outsider", .params = &.{}, .result = .{ .element = .string, .kind = .scalar }, .cost = .{}, .call = outsider },
    .{ .id = "t.bad_utf8", .params = &.{}, .result = .{ .element = .string, .kind = .scalar }, .cost = .{}, .call = invalidUtf8 },
    .{ .id = "t.empty", .params = &.{}, .result = .{ .element = .string, .kind = .scalar }, .cost = .{}, .call = emptyLiteral },
    native.entry("t.hog", hog, .{ .base = 1 }),
};

test "native string results are pool references valid UTF-8 and exact in cost" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Substring:=native{\"std.substring\"}\nIndexOf:=native{\"std.index_of\"}\nUpper:=native{\"std.upper\"}\nTrim:=native{\"std.trim\"}\nSplit:=native{\"std.split\"}\nJoin:=native{\"std.join\"}\nRepeat:=native{\"std.repeat\"}\nParseInt:=native{\"std.parse_int\"}\nText:string=\"  Hello, 雪 world  \"\nClean<public>:string=Trim(Text)\nLoud<public>:string=Upper(Clean)\nPart<public>:string=Or(Substring(Clean,7,3),\"?\")\nBad<public>:string=Or(Substring(Clean,8,1),\"?\")\nWhere<public>:i64=Or(IndexOf(Clean,\"world\"),-1)\nWords<public>:[]string=Split(\"a,b,,c\",\",\")\nBack<public>:string=Join(Words,\"+\")\nPad<public>:string=Repeat(\"ab\",3)\nNumber<public>:i64=Or(ParseInt(\"-42\"),0)\nBroken<public>:i64=Or(ParseInt(\"4x2\"),0)\nCount<public>:i64=Words.Length");
    try std.testing.expectEqualStrings("Hello, 雪 world", x.get("Clean").?.string);
    try std.testing.expectEqualStrings("HELLO, 雪 WORLD", x.get("Loud").?.string);
    try std.testing.expectEqualStrings("雪", x.get("Part").?.string);
    try std.testing.expectEqualStrings("?", x.get("Bad").?.string);
    try std.testing.expectEqual(@as(i64, 11), x.get("Where").?.integer);
    try std.testing.expectEqualStrings("a+b++c", x.get("Back").?.string);
    try std.testing.expectEqualStrings("ababab", x.get("Pad").?.string);
    try std.testing.expectEqual(@as(i64, -42), x.get("Number").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("Broken").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("Count").?.integer);
    const words = x.elements(x.get("Words").?).?;
    for ([_][]const u8{ "a", "b", "", "c" }, words) |expected, actual| try std.testing.expectEqualStrings(expected, actual.string);
}

test "lying or invalid string natives are checked diagnostics in both machines" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &raw;
    for ([_][]const u8{ "T:=native{\"t.outsider\"}\nValue<public>:string=T()", "T:=native{\"t.bad_utf8\"}\nValue<public>:string=T()" }) |source| {
        const p = try h.compile(source);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, h.runtime.evaluate(p, 4096).failed.code);
    }
    // An empty literal from Zig is normalised to the pool's empty string and reports cleanly.
    const x = try h.execute("T:=native{\"t.empty\"}\nValue<public>:string=T()\nSize<public>:i64=Value.Length");
    try std.testing.expectEqualStrings("", x.get("Value").?.string);
    try std.testing.expectEqual(@as(i64, 0), x.get("Size").?.integer);
    // Allocating beyond the pool is a string_limit; the charge is per byte.
    const big = try h.compile("Hog:=native{\"t.hog\"}\nValue<public>:string=Hog(100000)");
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, h.runtime.evaluate(big, 1 << 20).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, evaluator.evaluateWithRuntimeStorage(big, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 20).failed.code);
    const fits = try h.compile("Hog:=native{\"t.hog\"}\nValue<public>:i64=Hog(800).Length");
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, h.runtime.evaluate(fits, 50).failed.code);
    try std.testing.expectEqual(@as(i64, 800), (try h.execute("Hog:=native{\"t.hog\"}\nValue<public>:i64=Hog(800).Length")).get("Value").?.integer);
}

fn minimalBudget(h: *harness.Harness, program: types.Program) !u32 {
    for (1..2048) |budget| if (h.runtime.evaluate(program, @intCast(budget)) == .ok) return @intCast(budget);
    return error.NoBudget;
}

test "native cost scales exactly with string argument bytes" {
    const h = try harness.create();
    defer scratch.release(h);
    // The compiler workspace is shared, so measure each program before compiling the next.
    const short = try minimalBudget(h, try h.compile("Contains:=native{\"std.contains\"}\nValue<public>:logic=Contains(\"abcdefgh\",\"b\")"));
    const long = try minimalBudget(h, try h.compile("Contains:=native{\"std.contains\"}\nValue<public>:logic=Contains(\"abcdefghijklmnopqrstuvwxyz0123456789\",\"b\")"));
    // std.contains charges 1 unit per argument byte; the long text has 28 more bytes.
    try std.testing.expectEqual(short + 28, long);
}

test "repeated appends build a long string in linear pool space" {
    const h = try harness.create();
    defer scratch.release(h);
    // A thousand appends copy 2,000 bytes in total; copying both sides each time would need
    // about a million bytes and exhaust the string pool.
    const x = try h.execute("Grow(S:string)<computes>:string=S+\"ab\"\nLong:string=Iterate(Grow,1000,\"\")\nSize<public>:i64=Long.Length\nTwo<public>:i64=(Long+\"c\").Length+(Long+\"d\").Length");
    try std.testing.expectEqual(@as(i64, 2000), x.get("Size").?.integer);
    try std.testing.expectEqual(@as(i64, 4002), x.get("Two").?.integer);
}
