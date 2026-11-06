//! Map indexing (`M[K]`), option unwrapping (`Maybe?`) and map updates (`set M[K] = V`).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn pairAt(x: anytype, name: []const u8, pair: usize) struct { types.Value, types.Value } {
    const elements = x.elements(x.get(name).?).?;
    return .{ elements[2 * pair], elements[2 * pair + 1] };
}

test "map indexing and option unwrapping fail when the key or value is absent" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Color:=enum{Red,Green}\nPt:=struct{V:i64=3}\nScores:map(string,i64)=map{\"a\"=>1,\"b\"=>2}\nNames:map(i64,string)=map{7=>\"seven\"}\nShades:map(Color,Pt)=map{Color.Green=>Pt{V:=9}}\nMaybe:option(i64)=option{7}\nNothing:option(i64)=option{}\nLook(K:string)<computes>:i64=Attempt(Scores[K],-1)\nA<public>:i64=Look(\"a\")\nB<public>:i64=Look(\"zz\")\nC<public>:string=Attempt(Names[7],\"?\")\nD<public>:string=Attempt(Names[8],\"?\")\nE<public>:i64=Attempt(Shades[Color.Green].V,0)\nF<public>:i64=Attempt(Shades[Color.Red].V,0)\nG<public>:i64=Attempt(Maybe?,-5)\nH<public>:i64=Attempt(Nothing?,-5)\nI<public>:i64=Attempt(Scores[\"a\"]+Scores[\"b\"],0)\nJ<public>:i64=Attempt(Scores[\"a\"]+Scores[\"z\"],0)");
    const expected = [_]struct { []const u8, i64 }{ .{ "A", 1 }, .{ "B", -1 }, .{ "E", 9 }, .{ "F", 0 }, .{ "G", 7 }, .{ "H", -5 }, .{ "I", 3 }, .{ "J", 0 } };
    for (expected) |entry| try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
    try std.testing.expectEqualStrings("seven", x.get("C").?.string);
    try std.testing.expectEqualStrings("?", x.get("D").?.string);
}

test "set on map keys inserts replaces and keeps insertion order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Rec:=struct{Table:map(string,i64)=map{\"x\"=>1}}\nvar Scores:map(string,i64)=map{\"a\"=>1,\"b\"=>2}\nvar R:Rec=Rec{}\nvar Lists:map(string,[]i64)=map{\"l\"=>array{1,2}}\nset Scores[\"c\"]=30\nset Scores[\"a\"]=10\nset R.Table[\"y\"]=5\nA<public>:map(string,i64)=Scores\nBump(K:string)<transacts><decides>:i64=Block{set Scores[K]+=100;Scores[K]}\nB<public>:i64=Attempt(Bump[\"b\"],-1)\nC<public>:i64=Attempt(Bump[\"nope\"],-1)\nD<public>:i64=Attempt(Block{set Lists[\"l\"][1]=99;Lists[\"l\"][1]},-1)\nE<public>:i64=Attempt(Block{set Lists[\"m\"][0]=1;1},-1)\nTotal<public>:map(string,i64)=Scores\nTable<public>:map(string,i64)=R.Table\nMade<public>:map(string,i64)=WithIndex[Scores,\"made\",1]");
    // Replacing keeps the position of the key; inserting appends. "b" was bumped by 100.
    const total = x.elements(x.get("Total").?).?;
    try std.testing.expectEqual(@as(usize, 6), total.len);
    try std.testing.expectEqualStrings("a", total[0].string);
    try std.testing.expectEqual(@as(i64, 10), total[1].integer);
    try std.testing.expectEqualStrings("b", total[2].string);
    try std.testing.expectEqual(@as(i64, 102), total[3].integer);
    try std.testing.expectEqualStrings("c", total[4].string);
    try std.testing.expectEqual(@as(i64, 30), total[5].integer);
    // The first snapshot predates the bump.
    const snapshot = x.elements(x.get("A").?).?;
    try std.testing.expectEqual(@as(i64, 2), snapshot[3].integer);
    try std.testing.expectEqual(@as(i64, 102), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 99), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("E").?.integer);
    const table = x.elements(x.get("Table").?).?;
    try std.testing.expectEqual(@as(usize, 4), table.len);
    try std.testing.expectEqualStrings("y", table[2].string);
    const made = x.elements(x.get("Made").?).?;
    try std.testing.expectEqualStrings("made", made[made.len - 2].string);
}

test "a failed map update rolls back with its attempt" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Scores:map(string,i64)=map{\"a\"=>1}\nTry(K:string)<transacts>:i64=Attempt(Block{set Scores[K]=50;Scores[\"missing\"]},Scores.Length)\nA<public>:i64=Try(\"new\")\nB<public>:i64=Scores.Length");
    // The write of the new key is undone when the lookup of a missing key fails.
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
}

test "map and option indexing report exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "Scores:map(string,i64)=map{\"a\"=>1}\nMaybe:option(i64)=option{1}\nN:i64=1\nvar M:map(string,i64)=map{\"a\"=>1}\n";
    for ([_]Case{
        .{ prelude ++ "A:i64=Scores[\"a\"]", .failure_context_required },
        .{ prelude ++ "A:i64=Maybe?", .failure_context_required },
        .{ prelude ++ "A:i64=Attempt(Scores[1],0)", .type_mismatch },
        .{ prelude ++ "A:i64=Attempt(N?,0)", .type_mismatch },
        .{ prelude ++ "A:string=Attempt(Maybe?,\"x\")", .type_mismatch },
        .{ prelude ++ "A:i64=Attempt(Scores[],0)", .expected_expression },
        .{ prelude ++ "A:i64=Attempt(Scores[\"a\",\"b\"],0)", .argument_count },
        .{ prelude ++ "set M[1]=2", .type_mismatch },
        .{ prelude ++ "set M[\"a\"]=\"x\"", .type_mismatch },
        .{ prelude ++ "A:map(string,i64)=WithIndex[Scores,\"k\",true]", .type_mismatch },
        .{ prelude ++ "A:map(string,i64)=WithIndex[Scores,\"k\"]", .argument_count },
        .{ prelude ++ "A:i64=Attempt(Block{set Scores[\"a\"]=2;1},0)", .not_mutable },
        .{ prelude ++ "A:i64=Attempt(Maybe??,0)", .type_mismatch },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected map admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("map diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

const Entry = struct { key: i64, value: i64 };

test "two thousand generated updates agree with an insertion ordered oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x6d61);
    const random = prng.random();
    var buffer: [1024]u8 = undefined;
    for (0..2000) |_| {
        var model: [8]Entry = undefined;
        var count: usize = 0;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("var M:map(i64,i64)=map{");
        const initial = random.uintLessThan(usize, 5);
        for (0..initial) |_| {
            const key = random.intRangeAtMost(i64, 0, 9);
            var seen = false;
            for (model[0..count]) |entry| seen = seen or entry.key == key;
            if (seen) continue;
            const value = random.intRangeAtMost(i64, -50, 50);
            try out.print("{s}{d}=>{d}", .{ if (count == 0) "" else ",", key, value });
            model[count] = .{ .key = key, .value = value };
            count += 1;
        }
        try out.writeAll("}\n");
        const updates = random.uintLessThan(usize, 4) + 1;
        for (0..updates) |_| {
            const key = random.intRangeAtMost(i64, 0, 9);
            const value = random.intRangeAtMost(i64, -50, 50);
            try out.print("set M[{d}]={d}\n", .{ key, value });
            var found = false;
            for (model[0..count]) |*entry| if (entry.key == key) {
                entry.value = value;
                found = true;
            };
            if (!found) {
                model[count] = .{ .key = key, .value = value };
                count += 1;
            }
        }
        try out.writeAll("Out<public>:map(i64,i64)=M\n");
        const result = try h.execute(out.buffered());
        const elements = result.elements(result.get("Out").?).?;
        try std.testing.expectEqual(2 * count, elements.len);
        for (model[0..count], 0..) |entry, index| {
            try std.testing.expectEqual(entry.key, elements[2 * index].integer);
            try std.testing.expectEqual(entry.value, elements[2 * index + 1].integer);
        }
    }
}

test "forged map updates and option reads are rejected by independent admission" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Scores:map(string,i64)=map{\"a\"=>1}\nName:string=\"x\"\nMaybe:option(i64)=option{4}\nUpdated<public>:map(string,i64)=WithIndex[Scores,\"k\",5]\nValue<public>:i64=Attempt(Maybe?,0)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var set_node: ?usize = null;
    var unwrap_node: ?usize = null;
    var string_node: ?u32 = null;
    for (nodes, 0..) |node, index| {
        if (node.kind == .map_set) set_node = index;
        if (node.kind == .option_value) unwrap_node = index;
        if (node.kind == .string and string_node == null) string_node = @intCast(index);
    }
    try std.testing.expect(set_node != null and unwrap_node != null and string_node != null);
    for (0..6) |variant| {
        @memcpy(nodes, p.nodes);
        switch (variant) {
            0 => nodes[set_node.?].value_type = .string,
            1 => nodes[set_node.?].kind.map_set.key = nodes[set_node.?].kind.map_set.value,
            2 => nodes[set_node.?].kind.map_set.value = string_node.?,
            3 => nodes[set_node.?].kind.map_set.map = @intCast(nodes.len),
            4 => nodes[unwrap_node.?].value_type = .string,
            5 => nodes[unwrap_node.?].kind.option_value = string_node.?,
            else => unreachable,
        }
        var forged = p;
        forged.nodes = nodes;
        try harness.invalid(h, forged);
    }
}

test "a forged unguarded read of an empty option traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Nothing:option(i64)=option{}\nValue<public>:i64=Attempt(Nothing?,0)");
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
