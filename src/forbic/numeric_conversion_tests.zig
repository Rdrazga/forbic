//! Float/integer conversions: rounding oracles, range failure, typing and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn floorDiv4(k: i64) i64 {
    return @divFloor(k, 4);
}

test "conversions on exact quarter steps agree with an independent integer oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x51ab);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    for (0..3000) |_| {
        const k = random.intRangeAtMost(i64, -4000, 4000);
        const x = @as(f64, @floatFromInt(k)) / 4.0;
        const q = floorDiv4(k);
        const r = k - 4 * q;
        const round_even: i64 = if (r < 2) q else if (r > 2) q + 1 else if (@mod(q, 2) == 0) q else q + 1;
        const ceil: i64 = if (r == 0) q else q + 1;
        const truncate: i64 = @divTrunc(k, 4);
        var out = std.Io.Writer.fixed(&buffer);
        try out.print("X:float={d:.2};F<public>:i64=Attempt(Floor[X],999999);C<public>:i64=Attempt(Ceil[X],999999);R<public>:i64=Attempt(Round[X],999999);T<public>:i64=Attempt(Int[X],999999)", .{x});
        const result = try h.execute(out.buffered());
        try std.testing.expectEqual(q, result.get("F").?.integer);
        try std.testing.expectEqual(ceil, result.get("C").?.integer);
        try std.testing.expectEqual(round_even, result.get("R").?.integer);
        try std.testing.expectEqual(truncate, result.get("T").?.integer);
    }
}

test "float to integer fails for non finite values and outside the exact i64 range" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Inf2:float=Inf;Low:float=-Inf;Nan:float=NaN;Max:float=9223372036854774784.0;Over:float=9223372036854775808.0;Min:float=-9223372036854775808.0;Under:float=-9223372036854777856.0;A<public>:i64=Attempt(Floor[Inf2],-1);B<public>:i64=Attempt(Ceil[Low],-1);C<public>:i64=Attempt(Round[Nan],-1);D<public>:i64=Attempt(Int[Max],-1);E<public>:i64=Attempt(Floor[Over],-1);F<public>:i64=Attempt(Floor[Min],-1);G<public>:i64=Attempt(Ceil[Under],-1)");
    try std.testing.expectEqual(@as(i64, -1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 9223372036854774784), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("G").?.integer);
}

test "integer to float rounds to nearest even beyond 2 to the 53 and preserves exact values" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("A<public>:float=ToFloat(0);B<public>:float=ToFloat(-7);C<public>:float=ToFloat(9007199254740993);D<public>:float=ToFloat(9223372036854775807);E<public>:float=ToFloat(-9223372036854775807-1)");
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), @as(u64, @bitCast(x.get("A").?.floating)));
    try std.testing.expectEqual(@as(f64, -7.0), x.get("B").?.floating);
    try std.testing.expectEqual(@as(f64, @floatFromInt(@as(i64, 9007199254740993))), x.get("C").?.floating);
    try std.testing.expectEqual(@as(f64, 9223372036854775808.0), x.get("D").?.floating);
    try std.testing.expectEqual(@as(f64, -9223372036854775808.0), x.get("E").?.floating);
}

test "failed conversions roll back transacting writes and compose with floats and decides functions" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0;Bad:float=NaN;Try(X:float)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Floor[X]},Cell);Step(X:float)<computes><decides>:i64=Round[X*2.0];A<public>:i64=Try(2.5);B<public>:i64=Try(Bad);C<public>:i64=Attempt(Step[1.25],-1);D<public>:i64=Attempt(Step[Bad],-1);E<public>:float=ToFloat(Attempt(Floor[3.9],0))*0.5");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Cell").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
    try std.testing.expectEqual(@as(f64, 1.5), x.get("E").?.floating);
}

test "conversion builtins are reserved require failure contexts and check argument types" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "A:i64=Floor[1.5]", .failure_context_required },
        .{ "F(X:float)<computes>:i64=Round[X]", .failure_context_required },
        .{ "A:i64=Attempt(Floor[1],0)", .type_mismatch },
        .{ "A:float=ToFloat(1.5)", .type_mismatch },
        .{ "A:i64=Attempt(Ceil[1.5,2.5],0)", .argument_count },
        .{ "A:i64=Attempt(Int[],0)", .expected_expression },
        // Parentheses are the total rational form (RFC-0070), which a float does not fit.
        .{ "A:i64=Attempt(Floor(1.5),0)", .type_mismatch },
        .{ "A:float=ToFloat[1]", .expected_call },
        .{ "Floor(X:float)<computes>:i64=1", .expected_name },
        .{ "Round:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected conversion admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("conversion diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
}

test "forged unguarded conversions trap and forged operand types are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Big:float=1.0e30;Value<public>:i64=Attempt(Floor[Big],9);Also<public>:float=ToFloat(Value)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var target: ?usize = null;
    var demand: ?usize = null;
    for (nodes, 0..) |node, index| {
        if (node.kind == .float_to_int) target = index;
        if (node.kind == .demand) demand = index;
    }
    try std.testing.expect(target != null and demand != null);
    // Keep the demand (and its control accounting) but make its predicate always true.
    nodes[nodes[demand.?].kind.demand].kind = .{ .boolean = true };
    var forged = p;
    forged.nodes = nodes;
    const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
    const actual = h.runtime.evaluate(forged, 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, actual.failed.code);
    // A trap reports the offending conversion; admission failures would span the whole program.
    try std.testing.expectEqualDeep(nodes[target.?].span, reference.failed.span);
    try std.testing.expectEqualDeep(nodes[target.?].span, actual.failed.span);
    for (0..2) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[target.?].value_type = .float,
            1 => nodes[target.?].kind.float_to_int.operand = @intCast(target.?),
            else => unreachable,
        }
        var invalid_program = p;
        invalid_program.nodes = nodes;
        try harness.invalid(h, invalid_program);
    }
}

test "conversion edge values agree between both machines and the exact expectations" {
    const h = try harness.create();
    defer scratch.release(h);
    const Edge = struct { []const u8, i64, i64, i64, i64 };
    // text, floor, ceil, round (ties to even), truncate
    for ([_]Edge{
        .{ "-0.0", 0, 0, 0, 0 },
        .{ "-0.49999999999999994", -1, 0, 0, 0 },
        .{ "5e-324", 0, 1, 0, 0 },
        .{ "-5e-324", -1, 0, 0, 0 },
        .{ "4503599627370495.5", 4503599627370495, 4503599627370496, 4503599627370496, 4503599627370495 },
        .{ "-4503599627370495.5", -4503599627370496, -4503599627370495, -4503599627370496, -4503599627370495 },
        .{ "9223372036854774784.0", 9223372036854774784, 9223372036854774784, 9223372036854774784, 9223372036854774784 },
        .{ "-9223372036854774784.0", -9223372036854774784, -9223372036854774784, -9223372036854774784, -9223372036854774784 },
    }) |edge| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "X:float={s};F<public>:i64=Attempt(Floor[X],77);C<public>:i64=Attempt(Ceil[X],77);R<public>:i64=Attempt(Round[X],77);T<public>:i64=Attempt(Int[X],77)", .{edge[0]});
        const result = try h.execute(source);
        try std.testing.expectEqual(edge[1], result.get("F").?.integer);
        try std.testing.expectEqual(edge[2], result.get("C").?.integer);
        try std.testing.expectEqual(edge[3], result.get("R").?.integer);
        try std.testing.expectEqual(edge[4], result.get("T").?.integer);
    }
}
