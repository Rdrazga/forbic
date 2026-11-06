//! Failable array element reads: bounds failure, rollback, typing and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

test "array index reads elements and fails outside zero through length with the fallback" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{10,20,30};Pick(I:i64)<computes>:i64=Attempt(Items[I],-1);Shift(Base:[]i64,I:i64)<computes>:i64=Attempt(Base[I+1],-2);A<public>:i64=Pick(0);B<public>:i64=Pick(2);C<public>:i64=Pick(3);D<public>:i64=Pick(-1);E<public>:i64=Shift(Items,1);F<public>:i64=Shift(Items,2);G<public>:i64=Attempt(Items[0]+Items[1],0)");
    for ([_]struct { []const u8, i64 }{ .{ "A", 10 }, .{ "B", 30 }, .{ "C", -1 }, .{ "D", -1 }, .{ "E", 30 }, .{ "F", -2 }, .{ "G", 30 } }) |expected| {
        try std.testing.expectEqual(expected[1], x.get(expected[0]).?.integer);
    }
}

test "array index composes with nested arrays records strings and decides functions" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Grid:[][]i64=array{array{1,2},array{3,4,5}};R:=struct{N:string=\"a\"};Rs:[]R=array{R{N:=\"雪\"},R{}};Names:[]string=array{\"x\",\"y\"};At(Row:i64,Col:i64)<computes><decides>:i64=Grid[Row][Col];A<public>:i64=Attempt(At[1,2],-1);B<public>:i64=Attempt(At[0,2],-1);C<public>:i64=Attempt(At[2,0],-1);D<public>:string=Attempt(Rs[0].N,\"none\");E<public>:string=Attempt(Names[2],\"none\");F<public>:i64=Attempt(Grid[1].Length,-1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("C").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("D").?.string);
    try std.testing.expectEqualStrings("none", x.get("E").?.string);
    try std.testing.expectEqual(@as(i64, 3), x.get("F").?.integer);
}

test "array index failure rolls back transacting writes made in the same attempt" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0;Items:[]i64=array{1,2};Try(I:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+10;Items[I]},Cell);A<public>:i64=Try(1);B<public>:i64=Try(5);C<public>:i64=Try(-1)");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("Cell").?.integer);
}

test "array index requires a failure context an integer index and an array operand" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Items:[]i64=array{1};A:i64=Items[0]", .failure_context_required },
        .{ "Items:[]i64=array{1};F(I:i64)<computes>:i64=Items[I]", .failure_context_required },
        .{ "Items:[]i64=array{1};A:i64=Attempt(Items[true],0)", .type_mismatch },
        .{ "Items:[]i64=array{1};A:i64=Attempt(Items[0.5],0)", .type_mismatch },
        .{ "Items:[]i64=array{1};A:i64=Attempt(Items[],0)", .expected_expression },
        .{ "Items:[]i64=array{1};A:i64=Attempt(Items[0,1],0)", .argument_count },
        .{ "Items:[]i64=array{1};A:i64=Attempt(Items(0),0)", .not_callable },
        .{ "N:i64=1;A:i64=Attempt(N[0],0)", .not_callable },
        .{ "Items:[]i64=array{1};A:string=Attempt(Items[0],\"x\")", .type_mismatch },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected array index admission: {s}\n", .{case[0]});
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "three thousand generated reads agree with an independent bounds oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x1d3a);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    for (0..3000) |_| {
        const length = random.uintLessThan(usize, 7);
        const index = @as(i64, random.uintLessThan(u32, 14)) - 4;
        var values: [7]i64 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Items:[]i64=array{");
        for (0..length) |position| {
            values[position] = random.intRangeAtMost(i64, -50, 50);
            try out.print("{s}{d}", .{ if (position == 0) "" else ",", values[position] });
        }
        try out.writeAll("}");
        try out.print(";Value<public>:i64=Attempt(Items[{d}],999)", .{index});
        const expected: i64 = if (index >= 0 and index < length) values[@intCast(index)] else 999;
        try std.testing.expectEqual(expected, (try h.execute(out.buffered())).get("Value").?.integer);
    }
}

test "forged unguarded out-of-range reads end as a fatal index error in both machines without reading memory" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Items:[]i64=array{1,2};Value<public>:i64=Attempt(Items[5],9)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var demands: usize = 0;
    for (nodes) |node| if (node.kind == .demand) {
        // Keep the demand (and its control accounting) but make its predicate always true.
        nodes[node.kind.demand].kind = .{ .boolean = true };
        demands += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), demands);
    var forged = p;
    forged.nodes = nodes;
    const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
    const actual = h.runtime.evaluate(forged, 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.index_out_of_range, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.index_out_of_range, actual.failed.code);
    // A trap reports the offending read; admission failures would span the whole program.
    var read_span: ?types.Span = null;
    for (nodes) |node| if (node.kind == .array_get) {
        read_span = node.span;
    };
    try std.testing.expectEqualDeep(read_span.?, reference.failed.span);
    try std.testing.expectEqualDeep(read_span.?, actual.failed.span);
}

test "array index forged element types and operands are rejected by independent admission" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Items:[]i64=array{1,2};Name:string=\"x\";Value<public>:i64=Attempt(Items[1],9)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var target: ?usize = null;
    for (nodes, 0..) |node, index| if (node.kind == .array_get) {
        target = index;
    };
    try std.testing.expect(target != null);
    for (0..3) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[target.?].value_type = .string,
            1 => nodes[target.?].kind.array_get.index = nodes[target.?].kind.array_get.array,
            2 => nodes[target.?].kind.array_get.array = nodes[target.?].kind.array_get.index,
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
}

test "ElementAt reads without a failure context and is fatal outside the array" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{10,20,30}\nNames:[]string=array{\"a\",\"b\"}\nGuarded(I:i64)<computes>:i64=If(I<Items.Length,ElementAt(Items,I),-1)\nA<public>:i64=ElementAt(Items,2)\nB<public>:string=ElementAt(Names,1)\nC<public>:i64=Guarded(1)\nD<public>:i64=Guarded(5)\nE<public>:i64=ElementAt(Items,Items.Length-1)+ElementAt(Items,0)");
    try std.testing.expectEqual(@as(i64, 30), x.get("A").?.integer);
    try std.testing.expectEqualStrings("b", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 20), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 40), x.get("E").?.integer);
    // Outside the array the error is fatal and identical in both machines, even under Attempt.
    for ([_][]const u8{ "ElementAt(Items,3)", "ElementAt(Items,-1)", "Attempt(ElementAt(Items,9),0)" }) |read| {
        var source: [160]u8 = undefined;
        const program = try h.compile(try std.fmt.bufPrint(&source, "Items:[]i64=array{{1,2,3}}\nValue<public>:i64={s}", .{read}));
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
        const actual = h.runtime.evaluate(program, 4096);
        try std.testing.expectEqual(types.Diagnostic.Code.index_out_of_range, reference.failed.code);
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
    }
}

test "ElementAt reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Items:[]i64=array{1}\nA:i64=ElementAt(Items)", .argument_count },
        .{ "Items:[]i64=array{1}\nA:i64=ElementAt(Items,0,1)", .argument_count },
        .{ "Items:[]i64=array{1}\nA:i64=ElementAt(Items,true)", .type_mismatch },
        .{ "N:i64=1\nA:i64=ElementAt(N,0)", .type_mismatch },
        .{ "Items:[]i64=array{1}\nA:string=ElementAt(Items,0)", .type_mismatch },
        .{ "ElementAt:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected ElementAt admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("ElementAt diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}
