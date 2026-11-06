//! Failable array element updates (`WithIndex[A, I, V]`, `set A[I] = v`): copies, rollback, typing and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "WithIndex returns an updated copy and fails outside zero through length" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{10,20,30}\nNames:[]string=array{\"a\",\"b\"}\nGrid:[][]i64=array{array{1,2},array{3,4}}\nA<public>:[]i64=Attempt(WithIndex[Items,1,99],Items)\nB<public>:[]i64=Attempt(WithIndex[Items,3,0],array{7})\nC<public>:[]i64=Attempt(WithIndex[Items,-1,0],array{8})\nD<public>:[]i64=Attempt(WithIndex[WithIndex[Items,0,1],2,3],Items)\nE<public>:[]string=Attempt(WithIndex[Names,1,\"z\"],Names)\nF<public>:[][]i64=Attempt(WithIndex[Grid,0,array{9,9}],Grid)\nSame<public>:[]i64=Items");
    try expectIntegers(x, "A", &.{ 10, 99, 30 });
    try expectIntegers(x, "B", &.{7});
    try expectIntegers(x, "C", &.{8});
    try expectIntegers(x, "D", &.{ 1, 20, 3 });
    try expectIntegers(x, "Same", &.{ 10, 20, 30 });
    const names = x.elements(x.get("E").?).?;
    try std.testing.expectEqualStrings("a", names[0].string);
    try std.testing.expectEqualStrings("z", names[1].string);
    const grid = x.elements(x.get("F").?).?;
    try std.testing.expectEqual(@as(i64, 9), x.elements(grid[0]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 3), x.elements(grid[1]).?[0].integer);
}

test "set on array elements updates cells locals records and nested paths" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Cell:=struct{V:i64=0}\nHolder:=struct{Xs:[]i64=array{1,2}}\nvar Items:[]i64=array{4,5,6}\nvar Grid:[][]i64=array{array{1,2},array{3,4}}\nvar Cells:[]Cell=array{Cell{},Cell{V:=7}}\nvar Box:Holder=Holder{}\nRun()<transacts><decides>:i64=Block{set Items[1]=50;set Items[0]+=1;set Grid[1][0]=30;set Cells[1].V+=3;set Box.Xs[1]=9;Items[0]+Items[1]}\nR<public>:i64=Attempt(Run[],-1)\nLoc<public>:i64=Attempt(Block{var L:[]i64=array{1,2,3};set L[2]=L[0]+L[1];L[2]},-1)");
    try std.testing.expectEqual(@as(i64, 55), x.get("R").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Loc").?.integer);
    try expectIntegers(x, "Items", &.{ 5, 50, 6 });
    const grid = x.elements(x.get("Grid").?).?;
    try std.testing.expectEqual(@as(i64, 30), x.elements(grid[1]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 4), x.elements(grid[1]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 1), x.elements(grid[0]).?[0].integer);
    const cells = x.elements(x.get("Cells").?).?;
    try std.testing.expectEqual(@as(i64, 0), x.elements(cells[0]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 10), x.elements(cells[1]).?[0].integer);
    const box = x.elements(x.get("Box").?).?;
    try std.testing.expectEqual(@as(i64, 9), x.elements(box[0]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 1), x.elements(box[0]).?[0].integer);
}

test "element updates evaluate in order and a failed update rolls back its attempt" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var N:i64=0\nvar Items:[]i64=array{0,0,0}\nNext()<transacts>:i64=Block{set N=N+1;N}\nPut(I:i64,V:i64)<transacts><decides>:i64=Block{set N=N+100;set Items[I]=V;N}\nOrder<public>:i64=Attempt(Block{set Items[Next()]=Next()*10;Items[1]+Items[2]},-1)\nOk<public>:i64=Attempt(Put[0,5],-1)\nBad<public>:i64=Attempt(Put[9,5],-2)\nTotal<public>:i64=N");
    // The index is evaluated first (1), then the value (2*10): Items = 0,20,0.
    try std.testing.expectEqual(@as(i64, 20), x.get("Order").?.integer);
    // Put[0,5] bumps N by 100 from 2 and commits; Put[9,5] bumps it and fails, so it is undone.
    try std.testing.expectEqual(@as(i64, 102), x.get("Ok").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.get("Bad").?.integer);
    try std.testing.expectEqual(@as(i64, 102), x.get("Total").?.integer);
    try expectIntegers(x, "Items", &.{ 5, 20, 0 });
}

test "element updates reject non arrays types missing failure context and effectful repeated indices" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "var Items:[]i64=array{1,2}\nvar Grid:[][]i64=array{array{1}}\nvar N:i64=0\nNext()<transacts>:i64=Block{set N=N+1;N}\n";
    for ([_]Case{
        .{ "A:[]i64=WithIndex[array{1},0,2]", .failure_context_required },
        .{ "var Q:[]i64=array{1}\nset Q[0]=2", .failure_context_required },
        .{ prelude ++ "A:[]i64=Attempt(WithIndex[Items,true,1],Items)", .type_mismatch },
        .{ prelude ++ "A:[]i64=Attempt(WithIndex[Items,0,\"x\"],Items)", .type_mismatch },
        .{ prelude ++ "A:[]i64=Attempt(WithIndex[5,0,1],Items)", .type_mismatch },
        .{ prelude ++ "A:[]i64=Attempt(WithIndex[Items,0],Items)", .argument_count },
        .{ prelude ++ "A:[]i64=Attempt(WithIndex[Items,0,1,2],Items)", .argument_count },
        .{ prelude ++ "A:i64=Attempt(Block{set Items[0]=\"x\";1},0)", .type_mismatch },
        .{ prelude ++ "A:i64=Attempt(Block{set Items[true]=1;1},0)", .type_mismatch },
        .{ prelude ++ "A:i64=Attempt(Block{set N[0]=1;1},0)", .type_mismatch },
        .{ "Fixed:[]i64=array{1}\nA:i64=Attempt(Block{set Fixed[0]=2;1},0)", .not_mutable },
        .{ prelude ++ "A:i64=Attempt(Block{set Grid[Next()][0]=2;1},0)", .path_index_effects },
        .{ prelude ++ "A:i64=Attempt(Block{set Items[Next()]+=2;1},0)", .path_index_effects },
        .{ prelude ++ "A:i64=Attempt(Block{set Items[(0)]+=2;1},0)", .path_index_effects },
        .{ prelude ++ "A:i64=Attempt(Block{set Items[0]+=;1},0)", .expected_expression },
        .{ "WithIndex:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected element update admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("element update diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "three thousand generated updates agree with an independent oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5e7a);
    const random = prng.random();
    var buffer: [768]u8 = undefined;
    for (0..3000) |_| {
        const length = random.uintLessThan(usize, 7);
        const index = @as(i64, random.uintLessThan(u32, 14)) - 4;
        const value = random.intRangeAtMost(i64, -50, 50);
        var values: [7]i64 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Items:[]i64=array{");
        for (0..length) |position| {
            values[position] = random.intRangeAtMost(i64, -50, 50);
            try out.print("{s}{d}", .{ if (position == 0) "" else ",", values[position] });
        }
        try out.print("}};Fallback:[]i64=array{{777}};Out<public>:[]i64=Attempt(WithIndex[Items,{d},{d}],Fallback)", .{ index, value });
        const inside = index >= 0 and index < length;
        if (inside) values[@intCast(index)] = value;
        const result = try h.execute(out.buffered());
        const elements = result.elements(result.get("Out").?).?;
        if (!inside) {
            try std.testing.expectEqual(@as(usize, 1), elements.len);
            try std.testing.expectEqual(@as(i64, 777), elements[0].integer);
            continue;
        }
        try std.testing.expectEqual(length, elements.len);
        for (values[0..length], elements) |want, got| try std.testing.expectEqual(want, got.integer);
    }
}

test "forged element updates are rejected by independent admission" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Items:[]i64=array{1,2};Name:string=\"x\";Value<public>:[]i64=Attempt(WithIndex[Items,1,5],Items)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var target: ?usize = null;
    var string_node: ?u32 = null;
    for (nodes, 0..) |node, index| {
        if (node.kind == .array_set) target = index;
        if (node.kind == .string) string_node = @intCast(index);
    }
    try std.testing.expect(target != null and string_node != null);
    for (0..5) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[target.?].value_type = .string,
            1 => nodes[target.?].kind.array_set.index = nodes[target.?].kind.array_set.array,
            2 => nodes[target.?].kind.array_set.value = string_node.?,
            3 => nodes[target.?].kind.array_set.array = nodes[target.?].kind.array_set.index,
            4 => nodes[target.?].kind.array_set.value = @intCast(nodes.len),
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
}

test "forged unguarded out-of-range updates trap in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Items:[]i64=array{1,2};Value<public>:[]i64=Attempt(WithIndex[Items,5,9],Items)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var demands: usize = 0;
    for (nodes) |node| if (node.kind == .demand) {
        nodes[node.kind.demand].kind = .{ .boolean = true };
        demands += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), demands);
    var forged = p;
    forged.nodes = nodes;
    const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
    const actual = h.runtime.evaluate(forged, 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, actual.failed.code);
}
