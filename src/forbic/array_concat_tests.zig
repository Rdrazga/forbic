//! Array concatenation: run-owned results, limits, accounting and admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");
const array_concat = @import("array_concat.zig");

test "array concatenation joins empties nested arrays records and strings in order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Pair:=struct{N:i64=0}\nAppend(Items:[]i64,N:i64)<computes>:[]i64=Items+array{N}\nBuild(S:[]i64)<computes>:[]i64=Append(S,S.Length*10)\nEmpty:[]i64=array{}\nJoined<public>:[]i64=array{1,2}+Empty+array{3}\nGrown<public>:[]i64=Iterate(Build,4,array{0})\nWords<public>:[]string=array{\"a\"}+array{\"b\",\"c\"}\nRows<public>:[][]i64=array{array{1}}+array{array{2,3}}\nPairs<public>:[]Pair=array{Pair{N:=1}}+array{Pair{}}\nBoth<public>:i64=(Joined+Grown).Length\nNone<public>:i64=(Empty+Empty).Length\nPick<public>:i64=Attempt((Joined+Grown)[6],-1)");
    const expected = [_][]const i64{ &.{ 1, 2, 3 }, &.{ 0, 10, 20, 30, 40 } };
    for ([_][]const u8{ "Joined", "Grown" }, expected) |name, wanted| {
        const items = x.elements(x.get(name).?).?;
        try std.testing.expectEqual(wanted.len, items.len);
        for (wanted, items) |want, got| try std.testing.expectEqual(want, got.integer);
    }
    const words = x.elements(x.get("Words").?).?;
    for ([_][]const u8{ "a", "b", "c" }, words) |want, got| try std.testing.expectEqualStrings(want, got.string);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("Rows").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("Pairs").?).?.len);
    try std.testing.expectEqual(@as(i64, 8), x.get("Both").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("None").?.integer);
    try std.testing.expectEqual(@as(i64, 30), x.get("Pick").?.integer);
}

/// The least work budget (below 64) that lets the program finish.
fn exactWork(h: *harness.Harness, source: []const u8) !u32 {
    const program = try h.compile(source);
    for (1..64) |budget| {
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, @intCast(budget));
        const actual = h.runtime.evaluate(program, @intCast(budget));
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .ok) return @intCast(budget);
    }
    return error.NoBudgetFits;
}

test "concatenation charges one unit per appended element and exhausts the member pool as a checked diagnostic" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // A copy appends both operands: the node costs 1 and 5 elements are produced.
    const apart = try exactWork(h, "A:[]i64=array{1,2,3}\nGap:[]i64=array{9}\nB:[]i64=array{4,5}\nValue<public>:[]i64=A+B");
    const apart_plain = try exactWork(h, "A:[]i64=array{1,2,3}\nGap:[]i64=array{9}\nB:[]i64=array{4,5}");
    try std.testing.expectEqual(apart_plain + 1 + 5, apart);
    // Neighbouring spans already hold the joined elements, so only the node is charged.
    const next_to = try exactWork(h, "A:[]i64=array{1,2,3}\nB:[]i64=array{4,5}\nValue<public>:[]i64=A+B");
    const next_to_plain = try exactWork(h, "A:[]i64=array{1,2,3}\nB:[]i64=array{4,5}");
    try std.testing.expectEqual(next_to_plain + 1, next_to);
    // A left operand at the pool tail grows in place: only the right operand is appended.
    const grown = try exactWork(h, "A:[]i64=array{1,2,3}\nB:[]i64=array{4,5}\nValue<public>:[]i64=B+A");
    try std.testing.expectEqual(next_to_plain + 1 + 3, grown);
    // An empty operand hands the other back without charging.
    const empty = try exactWork(h, "A:[]i64=array{1,2,3}\nE:[]i64=array{}\nValue<public>:[]i64=A+E+E");
    const empty_plain = try exactWork(h, "A:[]i64=array{1,2,3}\nE:[]i64=array{}");
    try std.testing.expectEqual(empty_plain + 2, empty);
    const doubling = try h.compile("Double(S:[]i64)<computes>:[]i64=S+S\nBig<public>:[]i64=Iterate(Double,20,array{1,2})");
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithRuntimeStorage(doubling, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 20).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, h.runtime.evaluate(doubling, 1 << 20).failed.code);
    const x = try h.execute("Double(S:[]i64)<computes>:[]i64=S+S\nOk<public>:i64=Iterate(Double,6,array{1,2}).Length");
    try std.testing.expectEqual(@as(i64, 128), x.get("Ok").?.integer);
}

test "concatenation rejects mismatched operands and forged nodes are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "A:[]i64=array{1}+array{\"a\"}", .type_mismatch },
        .{ "A:[]i64=array{1}+1", .type_mismatch },
        .{ "A:[]i64=array{1}-array{1}", .type_mismatch },
        .{ "A:[]i64=array{1}*array{1}", .type_mismatch },
        .{ "A:[][]i64=array{array{1}}+array{1}", .type_mismatch },
        .{ "A:option(i64)=option{1}+option{2}", .type_mismatch },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected concat admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("concat diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
    const p = try h.compile("A:[]i64=array{1}\nB:[]i64=array{2}\nS:[]string=array{\"x\"}\nValue<public>:[]i64=A+B");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var target: ?usize = null;
    for (nodes, 0..) |node, index| if (node.kind == .array_concat) {
        target = index;
    };
    const strings: ?usize = p.bindings[2].node;
    try std.testing.expect(target != null);
    for (0..3) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[target.?].kind.array_concat.rhs = @intCast(strings.?),
            1 => nodes[target.?].value_type = .string,
            2 => nodes[target.?].kind.array_concat.lhs = @intCast(target.?),
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
}

test "building an array by repeated appends uses linear pool space" {
    const h = try harness.create();
    defer scratch.release(h);
    // 900 appends would need about 400,000 members if every join copied both sides; the
    // bootstrap pool holds 8,192. Each appended literal sits right behind the accumulator.
    const x = try h.execute("Grow(S:[]i64)<computes>:[]i64=S+array{S.Length*2}\nBig:[]i64=Iterate(Grow,900,array{0})\nSize<public>:i64=Big.Length\nLast<public>:i64=Attempt(Big[900],-1)\nMid<public>:i64=Attempt(Big[450],-1)");
    try std.testing.expectEqual(@as(i64, 901), x.get("Size").?.integer);
    try std.testing.expectEqual(@as(i64, 1800), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 900), x.get("Mid").?.integer);
}

/// The least fuel with which both machines finish `source`, found by halving.
fn leastFuel(h: *harness.Harness, source: []const u8, ceiling: u64) !u64 {
    const program = try h.compile(source);
    var low: u64 = 0;
    var high: u64 = ceiling;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, middle);
        const actual = h.runtime.evaluate(program, middle);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .ok) high = middle else low = middle + 1;
    }
    _ = try h.run(program, low);
    return low;
}

test "a For grows into the room its copies leave: the same values, linear work and pool" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Ys` fills the room behind `Xs`; `Zs`, a second join of `Xs`, finds the room taken and
    // copies. All three read as they always did.
    const x = try h.execute("Xs:[]i64=For(K:1..40,K*2)\nYs<public>:[]i64=Xs+array{100}\nZs<public>:[]i64=Xs+array{200}\nN<public>:i64=Xs.Length\nA<public>:i64=Attempt(Ys[40],0)+Attempt(Ys[39],0)\nB<public>:i64=Attempt(Zs[40],0)+Attempt(Zs[39],0)\nC<public>:i64=Attempt(Xs[39],0)");
    try std.testing.expectEqual(@as(i64, 40), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 180), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 280), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 80), x.get("C").?.integer);
    const xs = x.get("Ys").?.aggregate.elements;
    const zs = x.get("Zs").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 41), xs.end - xs.start);
    try std.testing.expectEqual(@as(u32, 41), zs.end - zs.start);
    try std.testing.expectEqual(x.get("Xs").?.aggregate.elements.start, xs.start);
    try std.testing.expect(zs.start > xs.end);
    for (x.elements(x.get("Ys").?).?[0..40], x.elements(x.get("Zs").?).?[0..40], 1..) |a, b, k| {
        try std.testing.expectEqual(@as(i64, @intCast(2 * k)), a.integer);
        try std.testing.expectEqual(a.integer, b.integer);
    }
    // Work is linear in the length: twice the elements, at most twice the fuel and a little
    // more. Copying the accumulator at every element charged 136,771 units for 500 of them.
    var work: [2]u64 = undefined;
    for ([_]u32{ 200, 400 }, &work) |count, *least| {
        var buffer: [128]u8 = undefined;
        least.* = try leastFuel(h, try std.fmt.bufPrint(&buffer, "Xs:[]i64=For(K:1..{d},K)\nN<public>:i64=Xs.Length", .{count}), 1 << 20);
    }
    try std.testing.expect(work[0] < 30 * 200);
    try std.testing.expect(work[1] <= 2 * work[0] + 100);
    const many = try h.execute("Xs:[]i64=For(K:1..400,K)\nN<public>:i64=Xs.Length");
    try std.testing.expectEqual(@as(i64, 400), many.get("N").?.integer);
    // About four members an element in a stored run, where every copy stayed in the pool.
    try std.testing.expect(many.aggregate_values.len < 6 * 400);
}

test "arrays of arrays, closures, skipped iterations and instances keep their values when a For grows" {
    const h = try harness.create();
    defer scratch.release(h);
    // An element that names members above the growing array's start is never written below it:
    // such arrays are copied, as before rooms, and read the same.
    const x = try h.execute("P:=class{N:i64}\nXs:[]i64=For(K:1..50,K)\nRows:[][]i64=For(K:1..40,array{K,K*K})\nFs:[]function(tuple(i64),i64)=For(K:1..30,Fn(X:i64){X+K})\nCalled:[]i64=For(F:Fs,F(1000))\nSkipped:[]i64=For(I:0..80,Xs[I]*2)\nAll:[]P=For(K:1..60,P{N:=K})\nR<public>:i64=Attempt(Rows[39][1],0)+Attempt(Rows[0][0],0)*10\nC<public>:i64=Attempt(Called[29],0)+Called.Length\nS<public>:i64=Skipped.Length*1000+Attempt(Skipped[49],0)\nA<public>:i64=All.Length");
    try std.testing.expectEqual(@as(i64, 1600 + 10), x.get("R").?.integer);
    try std.testing.expectEqual(@as(i64, 1030 + 30), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 50 * 1000 + 100), x.get("S").?.integer);
    try std.testing.expectEqual(@as(i64, 60), x.get("A").?.integer);
    const rows = x.elements(x.get("Rows").?).?;
    for (rows, 1..) |row, k| {
        const pair = x.elements(row).?;
        try std.testing.expectEqual(@as(i64, @intCast(k)), pair[0].integer);
        try std.testing.expectEqual(@as(i64, @intCast(k * k)), pair[1].integer);
    }
}

test "a replay refuses a run that says it joined into a room it had not, or into one already filled" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Xs:[]i64=For(K:1..40,K)\nYs<public>:[]i64=Xs+array{7}\nZs<public>:[]i64=Xs+array{7}\nA1:[]i64=array{1}\nGap:[]i64=array{0}\nB2:[]i64=array{2,3}\nW:[]i64=A1+B2\nG:[]i64=array{9}\nV<public>:[]i64=W+array{4}");
    const x = (try h.run(p, 1 << 20)).ok;
    _ = try reporting.validate(x, false, .{});
    const ys = x.get("Ys").?.aggregate.elements;
    const zs = x.get("Zs").?.aggregate.elements;
    const v = x.get("V").?.aggregate.elements;
    // `Ys` went into the room behind `Xs`, so `Zs` was copied. `W` was copied once, which left
    // only its last placeholder behind it, so `V` was copied too (and left a room).
    try std.testing.expectEqual(x.get("Xs").?.aggregate.elements.start, ys.start);
    try std.testing.expect(zs.start > ys.end and v.start > x.get("W").?.aggregate.elements.end);
    const values = try std.testing.allocator.dupe(types.Value, x.values);
    defer std.testing.allocator.free(values);
    var forged = x;
    forged.values = values;
    const zs_node = p.bindings[2].node;
    const v_node = p.bindings[8].node;
    // `Zs` claims the room `Ys` filled: the elements are the same, the layout is not the plan.
    values[zs_node].aggregate.elements = ys;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    values[zs_node] = x.values[zs_node];
    // `V` claims a room behind `W`, where the run left only the placeholder no join fills.
    const w = x.get("W").?.aggregate.elements;
    values[v_node].aggregate.elements = .{ .start = w.start, .end = w.end + 1 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    values[v_node] = x.values[v_node];
    _ = try reporting.validate(forged, false, .{});
    // A placeholder is no value: one inside an array in use is refused, and one where a run left
    // it is admitted whatever it says, since the replay knows its rooms without reading them.
    const members = try std.testing.allocator.dupe(types.Value, x.aggregate_values);
    defer std.testing.allocator.free(members);
    forged = x;
    forged.aggregate_values = members;
    members[ys.start] = array_concat.placeholder(ys.end);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    members[ys.start] = x.aggregate_values[ys.start];
    var placeholders: usize = 0;
    for (members, 0..) |*member, index| if (array_concat.placeholderLimit(member.*)) |_| {
        member.* = array_concat.placeholder(@intCast(index));
        placeholders += 1;
    };
    try std.testing.expect(placeholders > 2);
    _ = try reporting.validate(forged, false, .{});
}
