//! Iterating maps: `For(Value:Map, ...)` visits the values and `For(Key->Value:Map, ...)` the
//! entries, in insertion order; `KeyAt` / `ElementAt` read one entry by position.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "for visits map entries in insertion order with keys values and filters" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Scores:map(string,i64)=map{"b"=>2,"a"=>1}
        \\set Scores["c"]=30
        \\set Scores["b"]=20
        \\Values:[]i64=For(V:Scores,V)
        \\Keys:[]string=For(K->V:Scores,K)
        \\Lines:[]string=For(K->V:Scores,"{K}={V}")
        \\Big:[]string=For(K->V:Scores,V>5,K)
        \\Odd:[]i64=For(V:Scores,V!=20,V*2)
        \\Bumped(Table:map(string,i64))<computes>:[]i64=For(V:Table,V+1)
        \\Count:i64=Bumped(Scores).Length
        \\Empty:map(i64,i64)=map{}
        \\None:[]i64=For(K->V:Empty,K+V)
        \\First:string=KeyAt(Scores,0)
        \\Last:i64=ElementAt(Scores,2)
        \\Squares:map(i64,i64)=map{3=>9,4=>16}
        \\Pairs:[]i64=For(N->S:Squares,N*100+S)
        \\Indexed:[]i64=For(I->V:array{7,8},I*10+V)
    );
    const expectIntegers = struct {
        fn check(run: anytype, name: []const u8, expected: []const i64) !void {
            const range = run.get(name).?.aggregate.elements;
            try std.testing.expectEqual(expected.len, range.end - range.start);
            for (expected, run.aggregate_values[range.start..range.end]) |want, got| try std.testing.expectEqual(want, got.integer);
        }
    }.check;
    const expectStrings = struct {
        fn check(run: anytype, name: []const u8, expected: []const []const u8) !void {
            const range = run.get(name).?.aggregate.elements;
            try std.testing.expectEqual(expected.len, range.end - range.start);
            for (expected, run.aggregate_values[range.start..range.end]) |want, got| try std.testing.expectEqualStrings(want, got.string);
        }
    }.check;
    try expectIntegers(x, "Values", &.{ 20, 1, 30 });
    try expectStrings(x, "Keys", &.{ "b", "a", "c" });
    try expectStrings(x, "Lines", &.{ "b=20", "a=1", "c=30" });
    try expectStrings(x, "Big", &.{ "b", "c" });
    try expectIntegers(x, "Odd", &.{ 2, 60 });
    try expectIntegers(x, "None", &.{});
    try expectIntegers(x, "Pairs", &.{ 309, 416 });
    try expectIntegers(x, "Indexed", &.{ 7, 18 });
    try std.testing.expectEqual(@as(i64, 3), x.get("Count").?.integer);
    try std.testing.expectEqualStrings("b", x.get("First").?.string);
    try std.testing.expectEqual(@as(i64, 30), x.get("Last").?.integer);
}

test "an entry position outside the map is fatal and forged entry reads are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const fatal = h.front.compile("Scores:map(string,i64)=map{\"a\"=>1}\nBad:i64=Attempt(ElementAt(Scores,1),0)");
    try std.testing.expect(fatal == .ok);
    const reference = h.runtime.evaluate(fatal.ok, 10_000);
    try std.testing.expect(reference == .failed);

    const p = try h.compile("Scores:map(string,i64)=map{\"a\"=>1}\nK:string=KeyAt(Scores,0)\nV:i64=ElementAt(Scores,0)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    var key: usize = 0;
    var value: usize = 0;
    for (nodes, 0..) |node, index| {
        if (node.kind == .map_key) key = index;
        if (node.kind == .map_value) value = index;
    }
    _ = try h.run(forged, 10_000);
    // A key read typed as the value, and the reverse.
    nodes[key].value_type = .i64;
    try harness.invalid(h, forged);
    nodes[key] = p.nodes[key];
    nodes[value].value_type = .string;
    try harness.invalid(h, forged);
    nodes[value] = p.nodes[value];
    // A position that is not a number, and a subject that is not a map.
    nodes[key].kind.map_key.index = nodes[key].kind.map_key.array;
    try harness.invalid(h, forged);
    nodes[key] = p.nodes[key];
    nodes[value].kind.map_value.array = nodes[value].kind.map_value.index;
    try harness.invalid(h, forged);
    nodes[value] = p.nodes[value];
    _ = try h.run(forged, 10_000);
}
