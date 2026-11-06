//! Native Zig functions: signatures, cost, fatal errors, pool limits and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn dot(ctx: *native.Context, a: native.Array(f64), b: native.Array(f64)) f64 {
    _ = ctx;
    var total: f64 = 0;
    for (0..@min(a.len(), b.len())) |i| total += a.at(i) * b.at(i);
    return total;
}
fn sum(ctx: *native.Context, items: native.Array(i64)) native.Error!i64 {
    _ = ctx;
    var total: i64 = 0;
    for (0..items.len()) |i| total = std.math.add(i64, total, items.at(i)) catch return error.Failed;
    return total;
}
fn sorted(ctx: *native.Context, items: native.Array(i64)) native.Error!native.ArrayOut(i64) {
    const out = try ctx.array(i64, items.len());
    for (0..items.len()) |i| out.set(i, items.at(i));
    std.mem.sort(types.Value, out.items, {}, struct {
        fn less(_: void, a: types.Value, b: types.Value) bool {
            return a.integer < b.integer;
        }
    }.less);
    return out;
}
fn find(ctx: *native.Context, items: native.Array(i64), wanted: i64) ?i64 {
    _ = ctx;
    for (0..items.len()) |i| if (items.at(i) == wanted) return @intCast(i);
    return null;
}
fn measure(ctx: *native.Context, text: []const u8) i64 {
    _ = ctx;
    return @intCast(text.len);
}
fn flip(ctx: *native.Context, value: bool) bool {
    _ = ctx;
    return !value;
}
fn scale(ctx: *native.Context, x: f64, factor: f64) f64 {
    _ = ctx;
    return x * factor;
}
fn explode(ctx: *native.Context, x: i64) native.Error!i64 {
    _ = ctx;
    if (x < 0) return error.Failed;
    return x;
}
fn range(ctx: *native.Context, count: i64) native.Error!native.ArrayOut(i64) {
    if (count < 0) return error.Failed;
    const out = try ctx.array(i64, @intCast(count));
    for (0..out.items.len) |i| out.set(i, @intCast(i));
    return out;
}
// A misbehaving native used to prove results are re-validated.
fn liar(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = ctx;
    _ = args;
    return .{ .scalar = .{ .boolean = true } };
}

const table = [_]native.Entry{
    native.entry("t.dot", dot, .{ .base = 4, .per_element = 1 }),
    native.entry("t.sum", sum, .{ .base = 2, .per_element = 1 }),
    native.entry("t.sorted", sorted, .{ .base = 8, .per_element = 2 }),
    native.entry("t.find", find, .{ .base = 2, .per_element = 1 }),
    native.entry("t.measure", measure, .{ .base = 1 }),
    native.entry("t.flip", flip, .{ .base = 1 }),
    native.entry("t.scale", scale, .{ .base = 1 }),
    native.entry("t.explode", explode, .{ .base = 1 }),
    native.entry("t.range", range, .{ .base = 1 }),
    .{ .id = "t.liar", .params = &.{.{ .element = .i64, .kind = .scalar }}, .result = .{ .element = .i64, .kind = .scalar }, .cost = .{}, .call = liar },
};

const binds = "Dot:=native{\"t.dot\"}\nSum:=native{\"t.sum\"}\nSorted:=native{\"t.sorted\"}\nFind:=native{\"t.find\"}\nMeasure:=native{\"t.measure\"}\nFlip:=native{\"t.flip\"}\nScale:=native{\"t.scale\"}\nExplode:=native{\"t.explode\"}\nRange:=native{\"t.range\"}\nLiar:=native{\"t.liar\"}\n";

/// The returned execution borrows the formatted source, so it must outlive this call.
var program_source: [8192]u8 = undefined;

fn execute(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    h.front.natives = &table;
    return h.execute(try std.fmt.bufPrint(&program_source, "{s}{s}", .{ binds, source }));
}

test "native calls evaluate scalars strings arrays and options identically in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try execute(h, "A:[]float=array{1.5,2.0,4.0}\nB:[]float=array{2.0,3.0,0.5}\nI:[]i64=array{9,3,7,3}\nProduct<public>:float=Dot(A,B)\nTotal<public>:i64=Sum(I)\nOrdered<public>:[]i64=Sorted(I)\nSmallest<public>:i64=Attempt(Ordered[0],-1)\nWhere<public>:option(i64)=Find(I,7)\nMiss<public>:option(i64)=Find(I,100)\nIndex<public>:i64=Or(Where,-1)\nNone<public>:i64=Or(Miss,-1)\nLength<public>:i64=Measure(\"雪snow\")\nOpposite<public>:logic=Flip(false)\nScaled<public>:float=Scale(2.5,4.0)\nCount<public>:i64=Ordered.Length");
    try std.testing.expectEqual(@as(f64, 1.5 * 2.0 + 2.0 * 3.0 + 4.0 * 0.5), x.get("Product").?.floating);
    try std.testing.expectEqual(@as(i64, 22), x.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Smallest").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Index").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("None").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Length").?.integer);
    try std.testing.expect(x.get("Opposite").?.boolean);
    try std.testing.expectEqual(@as(f64, 10.0), x.get("Scaled").?.floating);
    try std.testing.expectEqual(@as(i64, 4), x.get("Count").?.integer);
    const ordered = x.elements(x.get("Ordered").?).?;
    for ([_]i64{ 3, 3, 7, 9 }, ordered) |expected, actual| try std.testing.expectEqual(expected, actual.integer);
}

test "native calls compose with functions loops options and rollback" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try execute(h, "var Cell:i64=0\nItems:[]i64=array{5,1,4}\nScore(A:[]i64,Bias:i64)<computes>:i64=Sum(A)+Bias\nStep(N:i64)<computes>:i64=Sum(Items)+N\nTry(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Items[N]},Sum(Items))\nOne<public>:i64=Score(Items,100)\nMany<public>:i64=Iterate(Step,3,0)\nKept<public>:i64=Try(1)\nDropped<public>:i64=Try(9)\nFloored<public>:i64=Attempt(Floor[Scale(7.5,0.5)],-1)");
    try std.testing.expectEqual(@as(i64, 110), x.get("One").?.integer);
    try std.testing.expectEqual(@as(i64, 30), x.get("Many").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("Dropped").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Cell").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Floored").?.integer);
}

test "native cost is charged exactly before the call and exhausts at the boundary" {
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &table;
    const p = try h.compile(binds ++ "Items:[]i64=array{1,2,3,4}\nTotal<public>:i64=Sum(Items)");
    var exact: ?u32 = null;
    for (1..64) |budget| {
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, @intCast(budget));
        const actual = h.runtime.evaluate(p, @intCast(budget));
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .failed) {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, reference.failed.code);
            try std.testing.expectEqual(reference.failed.code, actual.failed.code);
        } else if (exact == null) exact = @intCast(budget);
    }
    try std.testing.expect(exact != null);
    // One unit less than the exact budget must fail before the Zig function runs.
    const short = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, exact.? - 1);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, short.failed.code);
    // Sum costs 2 + 1 per element, so the budget exceeds a plain Length read by exactly 6.
    const plain = try h.compile("Items:[]i64=array{1,2,3,4}\nTotal<public>:i64=Items.Length");
    var plain_exact: ?u32 = null;
    for (1..64) |budget| {
        if (h.runtime.evaluate(plain, @intCast(budget)) == .ok) {
            plain_exact = @intCast(budget);
            break;
        }
    }
    try std.testing.expectEqual(plain_exact.? + 6, exact.?);
}

test "native fatal errors and pool exhaustion are checked diagnostics with healthy reuse" {
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &table;
    const failing = try h.compile(binds ++ "Value<public>:i64=Explode(-1)");
    const reference = evaluator.evaluateWithRuntimeStorage(failing, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
    const actual = h.runtime.evaluate(failing, 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.native_failed, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.native_failed, actual.failed.code);
    const caught = try h.compile(binds ++ "Value<public>:i64=Attempt(Explode(-1),7)");
    try std.testing.expectEqual(types.Diagnostic.Code.native_failed, h.runtime.evaluate(caught, 4096).failed.code);
    // One element more than the run pool holds, with fuel to spare.
    const huge = try h.compile(binds ++ std.fmt.comptimePrint("Big<public>:[]i64=Range({d})", .{types.limits.aggregate_elements + 1}));
    const ample = 4 * types.limits.aggregate_elements;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, h.runtime.evaluate(huge, ample).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithRuntimeStorage(huge, &h.values, &h.members, &h.control, &h.state, &h.frames, ample).failed.code);
    const costly = try h.compile(binds ++ "Big<public>:[]i64=Range(1000)");
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, h.runtime.evaluate(costly, 500).failed.code);
    const fine = try execute(h, "Small<public>:[]i64=Range(5)\nTotal<public>:i64=Sum(Small)");
    try std.testing.expectEqual(@as(i64, 10), fine.get("Total").?.integer);
}

test "native binding diagnostics and scope rules are exact" {
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &table;
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Nope:=native{\"t.missing\"}", .unknown_native },
        .{ "Dup:=native{\"t.sum\"}\nDup:=native{\"t.dot\"}", .duplicate_name },
        .{ "Sum:=native{\"t.sum\"}\nSum(X:i64)<computes>:i64=X", .duplicate_name },
        .{ "Sum:=native{\"t.sum\"}\nValue:i64=Sum(1)", .type_mismatch },
        .{ "Sum:=native{\"t.sum\"}\nValue:i64=Sum(array{1},2)", .argument_count },
        .{ "Sum:=native{\"t.sum\"}\nValue:string=Sum(array{1})", .type_mismatch },
        .{ "Sum:=native{\"t.sum\"}\nValue:i64=Sum[array{1}]", .expected_call },
        .{ "Sum<public>:=native{\"t.sum\"}", .unsupported_specifier },
        .{ "Sum:=native{\"t.sum\"}\nValue:i64=Sum", .unknown_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected native admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("native diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
    h.front.natives = &.{};
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, h.front.compile("Sum:=native{\"t.sum\"}").failed.code);
}

test "forged native nodes are rejected by both machines and lying natives are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &table;
    const p = try h.compile(binds ++ "Items:[]i64=array{1,2}\nTotal<public>:i64=Sum(Items)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var target: ?usize = null;
    for (nodes, 0..) |node, index| if (node.kind == .native_call) {
        target = index;
    };
    try std.testing.expect(target != null);
    for (0..5) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[target.?].kind.native_call.native = 200,
            1 => nodes[target.?].kind.native_call.count = 2,
            2 => nodes[target.?].kind.native_call.args[0] = @intCast(target.?),
            3 => nodes[target.?].value_type = .string,
            4 => nodes[target.?].kind.native_call.native = 9,
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
    // A native whose scalar result disagrees with its declared type is a checked diagnostic.
    const lying = try h.compile(binds ++ "Lied<public>:i64=Liar(3)");
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, evaluator.evaluateWithRuntimeStorage(lying, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, h.runtime.evaluate(lying, 4096).failed.code);
}

test "allocating natives work inside function frames loops and rollback with exact replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try execute(h, "var Cell:i64=0\nStep(S:i64)<computes>:i64=Sum(Range(S))+S\nPick(S:i64)<computes>:i64=Or(Find(Range(5),S),-1)+S\nGrow(S:[]i64)<computes>:[]i64=Sorted(array{S.Length,5,1})\nTry(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Sum(Range(N))+Range(N)[N-1]},Cell)\nUp<public>:i64=Iterate(Step,3,2)\nIndex<public>:i64=Iterate(Pick,4,1)\nShape<public>:[]i64=Iterate(Grow,2,array{9})\nOk<public>:i64=Try(4)\nBad<public>:i64=Try(0)\nCells<public>:i64=Cell");
    try std.testing.expectEqual(@as(i64, 21), x.get("Up").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Index").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("Ok").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Bad").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Cells").?.integer);
    const shape = x.elements(x.get("Shape").?).?;
    for ([_]i64{ 1, 3, 5 }, shape) |expected, actual| try std.testing.expectEqual(expected, actual.integer);
}

fn nanNative(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = ctx;
    _ = args;
    return .{ .scalar = .{ .floating = @bitCast(@as(u64, 0xFFF8000000000000)) } };
}
fn inflater(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = args;
    ctx.remaining = std.math.maxInt(u64);
    return .{ .scalar = .{ .integer = 1 } };
}
fn unchargedMembers(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = args;
    const start = ctx.used;
    ctx.used += 2;
    ctx.pool[start] = .{ .integer = 1 };
    ctx.pool[start + 1] = .{ .integer = 2 };
    return .{ .members = .{ .start = @intCast(start), .end = @intCast(start + 2) } };
}
fn strayBytes(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = args;
    _ = ctx.text(16) catch return .{ .fault = .string_limit };
    return .{ .scalar = .{ .integer = 3 } };
}

const rogue = [_]native.Entry{
    .{ .id = "r.nan", .params = &.{}, .result = .{ .element = .float, .kind = .scalar }, .cost = .{}, .call = nanNative },
    .{ .id = "r.inflate", .params = &.{}, .result = .{ .element = .i64, .kind = .scalar }, .cost = .{}, .call = inflater },
    .{ .id = "r.free", .params = &.{}, .result = .{ .element = .i64, .kind = .array }, .cost = .{}, .call = unchargedMembers },
    .{ .id = "r.stray", .params = &.{}, .result = .{ .element = .i64, .kind = .scalar }, .cost = .{}, .call = strayBytes },
};

test "misbehaving natives cannot inflate work skip charges leak bytes or smuggle non-canonical floats" {
    const h = try harness.create();
    defer scratch.release(h);
    h.front.natives = &rogue;
    for ([_][]const u8{
        "N:=native{\"r.nan\"}\nValue<public>:float=N()",
        "N:=native{\"r.inflate\"}\nValue<public>:i64=N()",
        "N:=native{\"r.free\"}\nValue<public>:[]i64=N()",
        "N:=native{\"r.stray\"}\nValue<public>:i64=N()",
    }) |source| {
        const p = try h.compile(source);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, h.runtime.evaluate(p, 4096).failed.code);
    }
    // Standard natives still pass the stricter checks, including mismatched dot lengths.
    h.front.natives = &native_std_table;
    const bad = try h.compile("Dot:=native{\"std.dot\"}\nValue<public>:float=Dot(array{1.0,2.0},array{3.0})");
    try std.testing.expectEqual(types.Diagnostic.Code.native_failed, h.runtime.evaluate(bad, 4096).failed.code);
}

const native_std_table = @import("native_std.zig").table;
