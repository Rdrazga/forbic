//! Comparable types, structural keys and key removal (RFC-0065): `==` and `!=` on composite
//! values, maps keyed by any comparable type, `Without[M, K]`, and `T:comparable`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const keys = @import("map_keys.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");
const bytecode = @import("bytecode.zig");

const shapes =
    \\Color:=enum{Red,Green}
    \\Pt:=struct{X:i64,Y:i64}
    \\Box:=class<unique>{var N:i64}
    \\
;

const Expected = struct { []const u8, i64 };

fn expectIntegers(x: anytype, expected: []const Expected) !void {
    for (expected) |entry| {
        const value = x.get(entry[0]).?.integer;
        if (value != entry[1]) std.debug.print("{s}: expected {d}, found {d}\n", .{ entry[0], entry[1], value });
        try std.testing.expectEqual(entry[1], value);
    }
}

fn expectLogic(x: anytype, names: []const []const u8, expected: bool) !void {
    for (names) |name| {
        const value = x.get(name).?.boolean;
        if (value != expected) std.debug.print("{s}: expected {}\n", .{ name, expected });
        try std.testing.expectEqual(expected, value);
    }
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    try std.testing.expect(r.failed.span.end <= source.len);
}

test "maps are keyed by tuples records enums options arrays maps instances and nestings of them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(shapes ++
        \\Tuples:map(tuple(i64,string),i64)=map{tuple{1,"a"}=>10,tuple{1,"b"}=>11,tuple{2,"a"}=>20}
        \\T1:i64=Attempt(Tuples[tuple{1,"b"}],-1)
        \\T2:i64=Attempt(Tuples[tuple{2,"b"}],-1)
        \\Points:map(Pt,i64)=map{Pt{X:=1,Y:=2}=>12,Pt{X:=2,Y:=1}=>21}
        \\P1:i64=Attempt(Points[Pt{X:=2,Y:=1}],-1)
        \\P2:i64=Attempt(Points[Pt{X:=2,Y:=2}],-1)
        \\Colors:map(Color,i64)=map{Color.Green=>1}
        \\C1:i64=Attempt(Colors[Color.Green],-1)
        \\C2:i64=Attempt(Colors[Color.Red],-1)
        \\Options:map(option(i64),i64)=map{option{}=>0,option{5}=>5}
        \\O1:i64=Attempt(Options[option{5}],-1)
        \\O2:i64=Attempt(Options[option{}],-1)
        \\O3:i64=Attempt(Options[option{6}],-1)
        \\Arrays:map([]i64,i64)=map{array{1,2}=>12,array{}=>0,array{1}=>1}
        \\A1:i64=Attempt(Arrays[array{1}],-1)
        \\A2:i64=Attempt(Arrays[array{}],-1)
        \\A3:i64=Attempt(Arrays[array{2,1}],-1)
        \\Nested:map(tuple(Pt,[]option(string)),i64)=map{tuple{Pt{X:=1,Y:=1},array{option{"x"},option{}}}=>7}
        \\N1:i64=Attempt(Nested[tuple{Pt{X:=1,Y:=1},array{option{"x"},option{}}}],-1)
        \\N2:i64=Attempt(Nested[tuple{Pt{X:=1,Y:=1},array{option{},option{"x"}}}],-1)
        \\N3:i64=Attempt(Nested[tuple{Pt{X:=1,Y:=1},array{option{"y"},option{}}}],-1)
        \\Maps:map(map(string,i64),i64)=map{map{"a"=>1,"b"=>2}=>1}
        \\M1:i64=Attempt(Maps[map{"a"=>1,"b"=>2}],-1)
        \\M2:i64=Attempt(Maps[map{"b"=>2,"a"=>1}],-1)
        \\B1:=Box{N:=1}
        \\B2:=Box{N:=1}
        \\Boxes:map(Box,i64)=map{B1=>1,B2=>2}
        \\X1:i64=Attempt(Boxes[B2],-1)
        \\X2:i64=Attempt(Boxes[Box{N:=1}],-1)
        \\Floats:map(tuple(float,float),i64)=map{tuple{0.0,NaN}=>1,tuple{Inf,1.0}=>2}
        \\F1:i64=Attempt(Floats[tuple{-0.0,NaN}],-1)
        \\F2:i64=Attempt(Floats[tuple{Inf,1.0}],-1)
        \\F3:i64=Attempt(Floats[tuple{-Inf,1.0}],-1)
        \\L1:option(i64)=Lookup(Tuples,tuple{2,"a"})
        \\L2:option(i64)=Lookup(Tuples,tuple{3,"a"})
    );
    try expectIntegers(x, &.{
        .{ "T1", 11 }, .{ "T2", -1 }, .{ "P1", 21 }, .{ "P2", -1 }, .{ "C1", 1 },  .{ "C2", -1 },
        .{ "O1", 5 },  .{ "O2", 0 },  .{ "O3", -1 }, .{ "A1", 1 },  .{ "A2", 0 },  .{ "A3", -1 },
        .{ "N1", 7 },  .{ "N2", -1 }, .{ "N3", -1 }, .{ "M1", 1 },  .{ "M2", -1 }, .{ "X1", 2 },
        .{ "X2", -1 }, .{ "F1", 1 },  .{ "F2", 2 },  .{ "F3", -1 },
    });
    try std.testing.expectEqual(@as(i64, 20), x.elements(x.get("L1").?).?[0].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("L2").?).?.len);
}

test "a subclass instance is a key of a map over its superclass and stays the same instance" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class<unique>{Legs:i64}
        \\Dog:=class<unique>(Animal){Name:string}
        \\Rex:=Dog{Legs:=4,Name:="Rex"}
        \\Tom:=Animal{Legs:=4}
        \\var Seen:map(Animal,i64)=map{Rex=>1}
        \\set Seen[Tom]=2
        \\set Seen[Rex]=3
        \\A:i64=Attempt(Seen[Rex],-1)
        \\B:i64=Attempt(Or(Lookup(Seen,Rex),-1)+Seen[Tom],-1)
        \\C:i64=Seen.Length
        \\D:i64=Attempt(Without[Seen,Rex].Length,-1)
    );
    try expectIntegers(x, &.{ .{ "A", 3 }, .{ "B", 5 }, .{ "C", 2 }, .{ "D", 1 } });
}

test "equality of composite values is structural and identical in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(shapes ++
        \\Holder:=struct{B:Box,Tag:Color}
        \\B1:=Box{N:=1}
        \\B2:=Box{N:=1}
        \\Empty:[]i64=array{}
        \\Some:option(i64)=option{4}
        \\None:option(i64)=option{}
        \\Deep:tuple(Pt,[]option(string))=tuple{Pt{X:=1,Y:=1},array{option{"x"},option{}}}
        \\T1:logic=tuple{1,"a"}==tuple{1,"a"}
        \\T2:logic=tuple{1,"a"}!=tuple{1,"b"}
        \\T3:logic=Pt{X:=1,Y:=2}==Pt{X:=1,Y:=2}
        \\T4:logic=array{1,2,3}==array{1,2,3}
        \\T5:logic=Empty==Empty
        \\T6:logic=Some==option{4}
        \\T7:logic=None==None
        \\T8:logic=Some!=None
        \\T9:logic=map{"a"=>1,"b"=>2}==map{"a"=>1,"b"=>2}
        \\T10:logic=map{"a"=>1,"b"=>2}!=map{"b"=>2,"a"=>1}
        \\T11:logic=Deep==tuple{Pt{X:=1,Y:=1},array{option{"x"},option{}}}
        \\T12:logic=tuple{0.0,NaN}==tuple{-0.0,NaN}
        \\T13:logic=Holder{B:=B1,Tag:=Color.Red}==Holder{B:=B1,Tag:=Color.Red}
        \\T14:logic=array{Color.Red,Color.Green}==array{Color.Red,Color.Green}
        \\T15:logic=array{array{1},array{2,3}}!=array{array{1,2},array{3}}
        \\F1:logic=tuple{1,"a"}==tuple{1,"b"}
        \\F2:logic=tuple{1,"a"}!=tuple{1,"a"}
        \\F3:logic=Pt{X:=1,Y:=2}==Pt{X:=1,Y:=3}
        \\F4:logic=array{1,2,3}==array{1,2}
        \\F5:logic=Some==None
        \\F6:logic=Some==option{5}
        \\F7:logic=map{"a"=>1,"b"=>2}==map{"b"=>2,"a"=>1}
        \\F8:logic=map{"a"=>1}==map{"a"=>1,"b"=>2}
        \\F9:logic=Deep==tuple{Pt{X:=1,Y:=1},array{option{"x"},option{"x"}}}
        \\F10:logic=Holder{B:=B1,Tag:=Color.Red}==Holder{B:=B2,Tag:=Color.Red}
        \\F11:logic=Holder{B:=B1,Tag:=Color.Red}==Holder{B:=B1,Tag:=Color.Green}
        \\F12:logic=tuple{1.0,2.0}==tuple{1.0,NaN}
        \\Same(A:[]Pt,B:[]Pt)<computes>:logic=A==B
        \\Pick(A:tuple(i64,string),B:tuple(i64,string))<computes>:i64=If(A!=B,1,0)
        \\T16:logic=Same(array{Pt{X:=1,Y:=2},Pt{X:=3,Y:=4}},array{Pt{X:=1,Y:=2},Pt{X:=3,Y:=4}})
        \\F13:logic=Same(array{Pt{X:=1,Y:=2},Pt{X:=3,Y:=4}},array{Pt{X:=1,Y:=2},Pt{X:=3,Y:=5}})
        \\P1:i64=Pick(tuple{1,"a"},tuple{1,"a"})
        \\P2:i64=Pick(tuple{1,"a"},tuple{2,"a"})
    );
    try expectLogic(x, &.{ "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "T9", "T10", "T11", "T12", "T13", "T14", "T15", "T16" }, true);
    try expectLogic(x, &.{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13" }, false);
    try expectIntegers(x, &.{ .{ "P1", 0 }, .{ "P2", 1 } });
}

/// The least fuel at which `source` completes; below it both machines stop with `work_limit`
/// and at every budget they agree, which `Harness.run` checks.
fn threshold(h: *harness.Harness, source: []const u8, ceiling: u64) !u64 {
    const p = try h.compile(source);
    var first: ?u64 = null;
    var budget: u64 = 0;
    while (budget <= ceiling) : (budget += 1) {
        const r = try h.run(p, budget);
        if (r == .failed) {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, r.failed.code);
            // Fuel is monotonic: once a budget suffices, every larger one does.
            try std.testing.expect(first == null);
        } else if (first == null) {
            first = budget;
        }
    }
    return first orelse error.CeilingTooLow;
}

test "structural equality and structural keys charge fuel by what they visit at every budget" {
    const h = try harness.create();
    defer scratch.release(h);
    // Straight-line code without a map: the comparison is not covered by the node count.
    const equal = try threshold(h, "A:logic=tuple{1,2,3}==tuple{1,2,3}", 64);
    const longer = try threshold(h, "A:logic=tuple{1,2,3,4,5}==tuple{1,2,3,4,5}", 64);
    // Two more members on each side: four nodes, four copied members, two visited pairs.
    try std.testing.expectEqual(equal + 10, longer);
    // A difference in the first member ends the walk there.
    const early = try threshold(h, "A:logic=tuple{9,2,3,4,5}==tuple{1,2,3,4,5}", 64);
    try std.testing.expectEqual(longer - 4, early);
    // An array of another length is unequal before any member is visited: one member less
    // to build, and one visit instead of two.
    const short = try threshold(h, "A:logic=array{1,2,3,4,5}==array{1,2,3,4}", 64);
    try std.testing.expectEqual(early - 3, short);
    // The same walk inside a function body and under an Attempt.
    _ = try threshold(h, "Same(A:[]tuple(i64,string),B:[]tuple(i64,string))<computes>:logic=A==B\nR:logic=Same(array{tuple{1,\"ab\"}},array{tuple{1,\"ab\"}})", 128);
    // Keys: a literal, a lookup, an update and a removal with two-part keys.
    _ = try threshold(h, "var M:map(tuple(i64,string),i64)=map{tuple{1,\"a\"}=>1,tuple{2,\"b\"}=>2}\nset M[tuple{3,\"c\"}]=3\nR:i64=Attempt(Without[M,tuple{2,\"b\"}].Length+M[tuple{1,\"a\"}],-1)", 512);
    const p = try h.compile("A:logic=tuple{1,2,3}==tuple{1,2,3}");
    try std.testing.expectEqual(@as(u32, 1), p.string_comparisons);
    // The count that sends this program down the charged path cannot be forged away.
    var forged = p;
    forged.string_comparisons = 0;
    try harness.invalid(h, forged);
}

test "values nested deeper than the near stack compare hash and serve as keys" {
    const h = try harness.create();
    defer scratch.release(h);
    const depth = 40;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("Deep:=");
    for (0..depth) |_| try out.writeAll("option(");
    try out.writeAll("i64");
    for (0..depth) |_| try out.writeAll(")");
    for ([_]struct { []const u8, i64 }{ .{ "X", 1 }, .{ "Y", 1 }, .{ "Z", 2 } }) |binding| {
        try out.print("\n{s}:Deep=", .{binding[0]});
        for (0..depth) |_| try out.writeAll("option{");
        try out.print("{d}", .{binding[1]});
        for (0..depth) |_| try out.writeAll("}");
    }
    // The innermost option of this one is empty: a difference at the very bottom.
    try out.writeAll("\nW:Deep=");
    for (0..depth) |_| try out.writeAll("option{");
    for (0..depth) |_| try out.writeAll("}");
    try out.writeAll("\nA:logic=X==Y\nB:logic=X==Z\nC:logic=X!=W\nTable:map(Deep,i64)=map{X=>1,Z=>2,W=>3}\nD:i64=Attempt(Table[Y],-1)\nE:i64=Attempt(Without[Table,Y].Length,-1)\nF:i64=Attempt(Table[W],-1)");
    const x = try h.execute(out.buffered());
    try expectLogic(x, &.{ "A", "C" }, true);
    try expectLogic(x, &.{"B"}, false);
    try expectIntegers(x, &.{ .{ "D", 1 }, .{ "E", 2 }, .{ "F", 3 } });
}

fn expectPairs(x: anytype, name: []const u8, expected: []const [3]i64) !void {
    const elements = x.elements(x.get(name).?).?;
    try std.testing.expectEqual(2 * expected.len, elements.len);
    for (expected, 0..) |entry, index| {
        const key = x.elements(elements[2 * index]).?;
        try std.testing.expectEqual(entry[0], key[0].integer);
        try std.testing.expectEqual(entry[1], key[1].integer);
        try std.testing.expectEqual(entry[2], elements[2 * index + 1].integer);
    }
}

test "Without removes the first a middle and the last entry keeps the order and leaves the old map alone" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Grid:=map(tuple(i64,i64),i64)
        \\M:Grid=map{tuple{1,1}=>10,tuple{2,2}=>20,tuple{3,3}=>30,tuple{4,4}=>40}
        \\First:Grid=Attempt(Without[M,tuple{1,1}],map{})
        \\Middle:Grid=Attempt(Without[M,tuple{3,3}],map{})
        \\Last:Grid=Attempt(Without[M,tuple{4,4}],map{})
        \\Absent:i64=Attempt(Without[M,tuple{9,9}].Length,-1)
        \\Total:Grid=Attempt(Without[M,tuple{9,9}],M)
        \\Unchanged:logic=Total==M
        \\Two:Grid=Attempt(Without[Without[M,tuple{2,2}],tuple{1,1}],map{})
        \\Twice:i64=Attempt(Without[Without[M,tuple{2,2}],tuple{2,2}].Length,-1)
        \\None:Grid=Attempt(Without[Without[Two,tuple{4,4}],tuple{3,3}],M)
        \\Nothing:i64=Attempt(Without[None,tuple{3,3}].Length,-1)
        \\Before:Grid=M
        \\Gone:i64=Attempt(Middle[tuple{3,3}],-1)
        \\Kept:i64=Attempt(Middle[tuple{4,4}],-1)
        \\Drop(T:map(string,i64),K:string)<computes><decides>:map(string,i64)=Without[T,K]
        \\Names:map(string,i64)=map{"a"=>1,"b"=>2,"c"=>3}
        \\Fewer:i64=Attempt(Drop[Names,"b"].Length,-1)
        \\Missing:i64=Attempt(Drop[Names,"z"].Length,-1)
        \\Again:map(string,i64)=Attempt(WithIndex[Drop[Names,"a"],"a",9],Names)
    );
    try expectPairs(x, "First", &.{ .{ 2, 2, 20 }, .{ 3, 3, 30 }, .{ 4, 4, 40 } });
    try expectPairs(x, "Middle", &.{ .{ 1, 1, 10 }, .{ 2, 2, 20 }, .{ 4, 4, 40 } });
    try expectPairs(x, "Last", &.{ .{ 1, 1, 10 }, .{ 2, 2, 20 }, .{ 3, 3, 30 } });
    try expectPairs(x, "Two", &.{ .{ 3, 3, 30 }, .{ 4, 4, 40 } });
    try expectPairs(x, "None", &.{});
    try expectPairs(x, "Before", &.{ .{ 1, 1, 10 }, .{ 2, 2, 20 }, .{ 3, 3, 30 }, .{ 4, 4, 40 } });
    try expectPairs(x, "Total", &.{ .{ 1, 1, 10 }, .{ 2, 2, 20 }, .{ 3, 3, 30 }, .{ 4, 4, 40 } });
    try expectLogic(x, &.{"Unchanged"}, true);
    try expectIntegers(x, &.{ .{ "Absent", -1 }, .{ "Twice", -1 }, .{ "Nothing", -1 }, .{ "Gone", -1 }, .{ "Kept", 40 }, .{ "Fewer", 2 }, .{ "Missing", -1 } });
    // A removed key that is set again goes to the end.
    const again = x.elements(x.get("Again").?).?;
    try std.testing.expectEqual(@as(usize, 6), again.len);
    try std.testing.expectEqualStrings("b", again[0].string);
    try std.testing.expectEqualStrings("c", again[2].string);
    try std.testing.expectEqualStrings("a", again[4].string);
    try std.testing.expectEqual(@as(i64, 9), again[5].integer);
}

test "for visits composite keys in order and a failed attempt rolls back updates and removals of a map cell" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Grid:=map(tuple(i64,i64),i64)
        \\var Cells:Grid=map{tuple{0,1}=>5,tuple{2,3}=>7}
        \\set Cells[tuple{4,5}]=9
        \\set Cells[tuple{0,1}]=6
        \\Sums:[]i64=For(K->V:Cells,K(0)+K(1)+V)
        \\Kept:[]i64=For(K->V:Cells,K!=tuple{2,3},V)
        \\Keys:[]tuple(i64,i64)=For(K->V:Cells,K)
        \\Try(K:tuple(i64,i64))<transacts>:i64=Attempt(Block{set Cells[K]=50;set Cells=Without[Cells,tuple{0,1}];Cells[tuple{7,7}]},Cells.Length)
        \\A:i64=Try(tuple{8,8})
        \\Rolled:Grid=Cells
        \\Keep(K:tuple(i64,i64))<transacts>:i64=Attempt(Block{set Cells[K]=50;set Cells=Without[Cells,tuple{0,1}];Cells[K]},-1)
        \\B:i64=Keep(tuple{8,8})
        \\Done:Grid=Cells
        \\set Cells=Attempt(Without[Cells,tuple{1,1}],Cells)
        \\set Cells=Attempt(Without[Cells,tuple{2,3}],Cells)
        \\Final:Grid=Cells
    );
    const sums = x.elements(x.get("Sums").?).?;
    try std.testing.expectEqual(@as(usize, 3), sums.len);
    for ([_]i64{ 7, 12, 18 }, sums) |want, got| try std.testing.expectEqual(want, got.integer);
    const kept = x.elements(x.get("Kept").?).?;
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    for ([_]i64{ 6, 9 }, kept) |want, got| try std.testing.expectEqual(want, got.integer);
    const key_list = x.elements(x.get("Keys").?).?;
    try std.testing.expectEqual(@as(usize, 3), key_list.len);
    try std.testing.expectEqual(@as(i64, 4), x.elements(key_list[2]).?[0].integer);
    // The lookup of an absent key failed after the update and the removal: both are undone.
    try expectIntegers(x, &.{ .{ "A", 3 }, .{ "B", 50 } });
    try expectPairs(x, "Rolled", &.{ .{ 0, 1, 6 }, .{ 2, 3, 7 }, .{ 4, 5, 9 } });
    try expectPairs(x, "Done", &.{ .{ 2, 3, 7 }, .{ 4, 5, 9 }, .{ 8, 8, 50 } });
    try expectPairs(x, "Final", &.{ .{ 4, 5, 9 }, .{ 8, 8, 50 } });
}

test "functions and anything holding one are rejected as keys and equality operands with exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "F(X:i64)<computes>:i64=X\nFs:=struct{G:function(tuple(i64),i64),N:i64}\nM:map(tuple(i64,i64),i64)=map{tuple{1,2}=>3}\nItems:[]i64=array{1}\n";
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "A:map(function(tuple(i64),i64),i64)=map{}", .invalid_map_key },
        .{ "A:map(Fs,i64)=map{}", .invalid_map_key },
        .{ "A:map([]Fs,i64)=map{}", .invalid_map_key },
        .{ "A:map(tuple(i64,option(function(tuple(i64),i64))),i64)=map{}", .invalid_map_key },
        .{ "A:map(map(string,function(tuple(i64),i64)),i64)=map{}", .invalid_map_key },
        .{ "A:=map{F=>1}", .invalid_map_key },
        .{ "A:=map{Fs{G:=F,N:=1}=>1}", .invalid_map_key },
        .{ "A:logic=F==F", .not_comparable },
        .{ "A:logic=Fs{G:=F,N:=1}==Fs{G:=F,N:=1}", .not_comparable },
        .{ "A:logic=array{F}!=array{F}", .not_comparable },
        .{ "A:logic=map{\"a\"=>F}==map{\"a\"=>F}", .not_comparable },
        .{ "A:logic=option{tuple{1,F}}==option{tuple{1,F}}", .not_comparable },
        .{ "A:logic=tuple{1,2}<tuple{1,3}", .type_mismatch },
        .{ "A:logic=tuple{1,2}==tuple{1,2.0}", .type_mismatch },
        .{ "A:logic=array{1}==tuple{1}", .type_mismatch },
        .{ "A:map(tuple(i64,i64),i64)=Without[M,tuple{1,2}]", .failure_context_required },
        .{ "A:i64=Attempt(Without[M,1].Length,0)", .type_mismatch },
        .{ "A:i64=Attempt(Without[M,tuple{1,\"a\"}].Length,0)", .type_mismatch },
        .{ "A:i64=Attempt(Without[Items,0].Length,0)", .type_mismatch },
        .{ "A:i64=Attempt(Without[1,0],0)", .type_mismatch },
        .{ "A:i64=Attempt(Without[M].Length,0)", .argument_count },
        .{ "A:i64=Attempt(Without[M,tuple{1,2},3].Length,0)", .argument_count },
        .{ "A:i64=Attempt(Without(M,tuple{1,2}).Length,0)", .expected_call },
        .{ "A:i64=Attempt(M[tuple{1,2,3}],0)", .tuple_arity },
        .{ "Without:i64=1", .expected_name },
        .{ "Same[T:comparable](A:T,B:T)<computes>:logic{A==B}\nA:logic=Same[function(tuple(i64),i64)](F,F)", .not_comparable },
        .{ "Same[T:comparable](A:T,B:T)<computes>:logic{A==B}\nA:logic=Same[Fs](Fs{G:=F,N:=1},Fs{G:=F,N:=1})", .not_comparable },
        .{ "Same[T:type](A:T,B:T)<computes>:logic{A==B}\nA:logic=Same[Fs](Fs{G:=F,N:=1},Fs{G:=F,N:=1})", .not_comparable },
        .{ "Same[comparable:type](A:comparable)<computes>:i64{1}", .expected_parameter },
        .{ "Same[T:compare](A:T)<computes>:i64{1}", .unsupported_type },
    }) |case| {
        var buffer: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] });
        try expectCode(h, source, case[1]);
        _ = try h.execute("A:i64=42");
    }
}

test "a comparable type parameter admits equality and keys over it and nothing incomparable" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(shapes ++
        \\Same[T:comparable](A:T,B:T)<computes>:logic{A==B}
        \\Count[K:comparable](M:map(K,i64),Key:K)<computes>:i64{Attempt(M[Key],0)}
        \\Drop[K:comparable,V:type](M:map(K,V),Key:K)<computes>:map(K,V){Attempt(Without[M,Key],M)}
        \\Index[T:comparable](Items:[]T)<computes>:map(T,i64){map{ElementAt(Items,0)=>0}}
        \\A:logic=Same[tuple(i64,string)](tuple{1,"a"},tuple{1,"a"})
        \\B:logic=Same[[]i64](array{1},array{2})
        \\C:i64=Count[tuple(i64,i64)](map{tuple{1,2}=>3},tuple{1,2})
        \\D:map(Pt,string)=Drop[Pt,string](map{Pt{X:=1,Y:=1}=>"a",Pt{X:=2,Y:=2}=>"b"},Pt{X:=1,Y:=1})
        \\E:logic=Same[Color](Color.Red,Color.Red)
        \\G:map(option(string),i64)=Index[option(string)](array{option{"k"}})
        \\H:i64=Attempt(G[option{"k"}],-1)
        \\I:logic=Same[i64](1,2)
    );
    try expectLogic(x, &.{ "A", "E" }, true);
    try expectLogic(x, &.{ "B", "I" }, false);
    try expectIntegers(x, &.{ .{ "C", 3 }, .{ "H", 0 } });
    const d = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqualStrings("b", d[1].string);
}

fn bindingNode(p: types.Program, name: []const u8) u32 {
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), name)) return binding.node;
    unreachable;
}

test "forged removals are rejected by both admissions and an unguarded absent key traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("M:map(i64,string)=map{1=>\"a\",2=>\"b\"}\nK:i64=1\nS:string=\"s\"\nR:map(i64,string)=Attempt(Without[M,K],M)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var removal: ?usize = null;
    for (nodes, 0..) |node, index| if (node.kind == .map_remove) {
        removal = index;
    };
    const at = removal.?;
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 10_000);
    for (0..6) |variant| {
        @memcpy(nodes, p.nodes);
        forged.control_ops = p.control_ops;
        switch (variant) {
            // A result that is not the map's type.
            0 => nodes[at].value_type = .i64,
            // A key of another type, and a subject that is not a map.
            1 => nodes[at].kind.map_remove.key = bindingNode(p, "S"),
            2 => nodes[at].kind.map_remove.map = bindingNode(p, "K"),
            // Operands that are not earlier values.
            3 => nodes[at].kind.map_remove.key = @intCast(at),
            4 => nodes[at].kind.map_remove.map = @intCast(nodes.len),
            // A removal allocates, so it counts as a control operation.
            5 => forged.control_ops -= 1,
            else => unreachable,
        }
        try harness.invalid(h, forged);
    }
    @memcpy(nodes, p.nodes);
    forged.control_ops = p.control_ops;
    _ = try h.run(forged, 10_000);

    // The key is absent and the guard is forged to pass: the removal itself refuses.
    const absent = try h.compile("M:map(tuple(i64,i64),i64)=map{tuple{1,1}=>2}\nR:i64=Attempt(Without[M,tuple{5,5}].Length,-1)");
    try std.testing.expectEqual(@as(i64, -1), (try h.run(absent, 10_000)).ok.get("R").?.integer);
    const unguarded = try std.testing.allocator.dupe(types.Node, absent.nodes);
    defer std.testing.allocator.free(unguarded);
    var demands: usize = 0;
    for (unguarded) |node| if (node.kind == .demand) {
        unguarded[node.kind.demand].kind = .{ .boolean = true };
        demands += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), demands);
    var trapped = absent;
    trapped.nodes = unguarded;
    try harness.traps(h, trapped, 10_000);

    // The same two forgeries inside a function body.
    const q = try h.compile("Drop(T:map(i64,i64),K:i64)<computes>:map(i64,i64)=Attempt(Without[T,K],T)\nR:map(i64,i64)=Drop(map{1=>2},5)");
    _ = try h.run(q, 10_000);
    const body = try std.testing.allocator.dupe(types.FunctionNode, q.function_nodes);
    defer std.testing.allocator.free(body);
    var inner = q;
    inner.function_nodes = body;
    var subject: u32 = 0;
    for (body, 0..) |entry, index| if (entry.input == .operation and entry.node.kind == .map_remove) {
        subject = entry.node.kind.map_remove.map;
        body[index].node.kind.map_remove.key = subject;
    };
    try harness.invalid(h, inner);
    @memcpy(body, q.function_nodes);
    demands = 0;
    for (body) |entry| if (entry.input == .operation and entry.node.kind == .demand) {
        body[entry.node.kind.demand].node.kind = .{ .boolean = true };
        demands += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), demands);
    try harness.traps(h, inner, 10_000);
}

test "forged key types comparisons and constraints over functions are rejected by both admissions" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "F(X:i64)<computes>:i64=X\nG:function(tuple(i64),i64)=F\nFs:=struct{H:function(tuple(i64),i64)}\nV:Fs=Fs{H:=F}\nM:map(string,i64)=map{\"a\"=>1}\nL:i64=1\nE:logic=L==L";
    const p = try h.compile(source);
    _ = try h.run(p, 10_000);
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.definitions = definitions;
    forged.nodes = nodes;
    var map_index: ?usize = null;
    for (definitions, 0..) |item, index| if (item == .map) {
        map_index = index;
    };
    const function_type = p.nodes[bindingNode(p, "G")].value_type;
    const record_type = p.nodes[bindingNode(p, "V")].value_type;
    try std.testing.expect(@backingInt(function_type) - 4 < map_index.? and @backingInt(record_type) - 4 < map_index.?);
    // A map keyed by a function, and by a record that holds one.
    definitions[map_index.?].map.key = function_type;
    try harness.invalid(h, forged);
    definitions[map_index.?].map.key = record_type;
    try harness.invalid(h, forged);
    @memcpy(definitions, p.definitions);
    _ = try h.run(forged, 10_000);
    // `==` between two functions, and between two records that hold one.
    const compare = bindingNode(p, "E");
    try std.testing.expect(nodes[compare].kind == .compare);
    nodes[compare].kind.compare = .{ .op = .equal, .lhs = bindingNode(p, "G"), .rhs = bindingNode(p, "G") };
    try harness.invalid(h, forged);
    nodes[compare].kind.compare = .{ .op = .unequal, .lhs = bindingNode(p, "V"), .rhs = bindingNode(p, "V") };
    try harness.invalid(h, forged);
    @memcpy(nodes, p.nodes);
    _ = try h.run(forged, 10_000);

    // A specialization of a `comparable` parameter whose recorded argument is a function type.
    // The same forgery of a plain `type` parameter stays admitted: the constraint is what rejects.
    inline for (.{ "comparable", "type" }) |kind| {
        const generic = try h.compile("F(X:i64)<computes>:i64=X\nG:function(tuple(i64),i64)=F\nOne[T:" ++ kind ++ "](A:T,B:i64)<computes>:i64{B}\nR:i64=One[string](\"a\",1)");
        _ = try h.run(generic, 10_000);
        const elements = try std.testing.allocator.dupe(types.Type, generic.tuple_elements);
        defer std.testing.allocator.free(elements);
        var respecialized = generic;
        respecialized.tuple_elements = elements;
        var key: ?types.Span = null;
        for (generic.functions) |f| if (f.specialization) |specialization| {
            key = catalogue.definition(specialization, generic.definitions).?.tuple;
        };
        try std.testing.expectEqual(@as(u32, 1), key.?.end - key.?.start);
        try std.testing.expectEqual(types.Type.string, elements[key.?.start]);
        elements[key.?.start] = generic.nodes[bindingNode(generic, "G")].value_type;
        if (comptime std.mem.eql(u8, kind, "comparable")) {
            try harness.invalid(h, respecialized);
        } else {
            _ = try h.run(respecialized, 10_000);
        }
    }
}

test "the report replays a removal member by member and rejects a forged result" {
    const h = try harness.create();
    defer scratch.release(h);
    const limits: reporting.Limits = .{ .work = 1024 * 1024 };
    // At the root, and inside a traced call.
    for ([_][]const u8{
        "M:map(tuple(i64,i64),i64)=map{tuple{1,1}=>10,tuple{2,2}=>20,tuple{3,3}=>30}\nR:map(tuple(i64,i64),i64)=Attempt(Without[M,tuple{2,2}],M)",
        "Drop(T:map(tuple(i64,i64),i64),K:tuple(i64,i64))<computes>:map(tuple(i64,i64),i64)=Attempt(Without[T,K],T)\nR:map(tuple(i64,i64),i64)=Drop(map{tuple{1,1}=>10,tuple{2,2}=>20,tuple{3,3}=>30},tuple{2,2})",
    }) |source| {
        const r = try h.run(try h.compile(source), 10_000);
        const span = r.ok.get("R").?.aggregate.elements;
        try std.testing.expectEqual(@as(u32, 4), span.end - span.start);
        _ = try reporting.validate(r.ok, false, limits);
        const members = &h.runtime.machine.aggregate_values;
        // The kept values in the wrong order, then the removed value kept in place of another.
        const first = members[span.start + 1];
        members[span.start + 1] = members[span.start + 3];
        members[span.start + 3] = first;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
        members[span.start + 3] = members[span.start + 1];
        members[span.start + 1] = first;
        _ = try reporting.validate(r.ok, false, limits);
        members[span.start + 3] = .{ .integer = 20 };
        try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
        members[span.start + 3] = .{ .integer = 30 };
        _ = try reporting.validate(r.ok, false, limits);
        // A report with too little work to check the structural keys says so instead of trusting them.
        try std.testing.expectError(error.ReportLimit, reporting.validate(r.ok, false, .{ .work = 8 }));
    }
}

test "the comparable predicate follows parts through the catalogue and refuses malformed ones" {
    var store: catalogue.Storage = .{};
    const source = "Plain Holder Wrap A B Bare Keep";
    const parameters = try store.internTuple(&.{.i64});
    const function = try store.internCallable(.{ .parameters = parameters, .result = .i64 });
    const plain = try store.addRecord(.{ .start = 0, .end = 5 }, &.{ .{ .name = .{ .start = 18, .end = 19 }, .value_type = .i64 }, .{ .name = .{ .start = 20, .end = 21 }, .value_type = .string } }, false, source);
    const holder = try store.addRecord(.{ .start = 6, .end = 12 }, &.{ .{ .name = .{ .start = 18, .end = 19 }, .value_type = .i64 }, .{ .name = .{ .start = 20, .end = 21 }, .value_type = function } }, false, source);
    const class = try store.reserveClass(.{ .start = 13, .end = 17 }, false, source, .{ .start = 0, .end = @intCast(source.len) });
    // Only a `class<unique>` is comparable (RFC-0076): by identity whatever it holds, even before
    // its fields are known. A class that does not say so is not, and neither is what holds one.
    store.markUnique(class);
    const bare = try store.reserveClass(.{ .start = 22, .end = 26 }, false, source, .{ .start = 0, .end = @intCast(source.len) });
    const check = struct {
        fn comparable(s: *const catalogue.Storage, value_type: types.Type) bool {
            // The pass over the whole catalogue, as an admission runs it, against the answer
            // the store recorded when each definition was added.
            var answers: [64]bool = undefined;
            catalogue.comparableTypes(s.definitions[0..s.count], s.fields[0..s.field_count], s.tuple_elements[0..s.tuple_count], answers[0..s.count]);
            return catalogue.comparableIn(value_type, answers[0..s.count]);
        }
    }.comparable;
    try std.testing.expect(check(&store, class));
    try std.testing.expect(!check(&store, bare));
    try store.completeClass(class, .{}, &.{.{ .name = .{ .start = 18, .end = 19 }, .value_type = function }}, source);
    try store.completeClass(bare, .{}, &.{.{ .name = .{ .start = 18, .end = 19 }, .value_type = .i64 }}, source);
    try std.testing.expect(!check(&store, bare) and !store.comparableType(bare));
    const bare_holder = try store.addRecord(.{ .start = 27, .end = 31 }, &.{.{ .name = .{ .start = 18, .end = 19 }, .value_type = bare }}, false, source);
    for ([_]types.Type{ .i64, .logic, .string, .float, plain, class }) |value_type| try std.testing.expect(check(&store, value_type));
    for ([_]types.Type{ function, holder, parameters }) |value_type| try std.testing.expectEqual(value_type == parameters, check(&store, value_type));
    const good = try store.internTuple(&.{ plain, try store.internArray(try store.internOption(class)), try store.internMap(plain, .string) });
    try std.testing.expect(check(&store, good));
    for ([_]types.Type{
        try store.internArray(function),
        try store.internOption(holder),
        try store.internTuple(&.{ .i64, try store.internArray(holder) }),
        try store.internMap(.i64, function),
        try store.internMap(good, try store.internOption(function)),
        // A class that is not unique, and every container of one (RFC-0076).
        bare,
        bare_holder,
        try store.internArray(bare),
        try store.internOption(bare),
        try store.internTuple(&.{ .i64, bare }),
        try store.internMap(.i64, bare),
        try store.internArray(bare_holder),
    }) |value_type| {
        try std.testing.expect(!check(&store, value_type));
        try std.testing.expectError(error.InvalidKey, store.internMap(value_type, .i64));
        try std.testing.expect(!catalogue.walkedEquality(function, store.definitions[0..store.count]));
    }
    try std.testing.expect(catalogue.walkedEquality(good, store.definitions[0..store.count]) and catalogue.walkedEquality(.string, store.definitions[0..store.count]));
    try std.testing.expect(!catalogue.walkedEquality(class, store.definitions[0..store.count]) and !catalogue.walkedEquality(.i64, store.definitions[0..store.count]));
    _ = try store.internMap(good, .i64);
    try std.testing.expect(catalogue.validateAll(store.definitions[0..store.count], store.fields[0..store.field_count], &.{}, store.tuple_elements[0..store.tuple_count], source));
    // What the store decided as each definition was added is what the pass over all of them says.
    for (0..store.count + 4) |id| try std.testing.expectEqual(check(&store, @fromBackingInt(@intCast(id))), store.comparableType(@fromBackingInt(@intCast(id))));
    // Unknown types, and a definition that names itself or a later one, are not comparable.
    try std.testing.expect(!check(&store, @fromBackingInt(@intCast(4 + store.count))));
    const array = try store.internArray(.logic);
    store.definitions[@backingInt(array) - 4] = .{ .array = array };
    try std.testing.expect(!check(&store, array));
    store.definitions[@backingInt(array) - 4] = .{ .option = @fromBackingInt(@backingInt(array) + 1) };
    try std.testing.expect(!check(&store, array));
}

test "key equality and hashing agree on every pair of a mixed set of structural values" {
    // Members: two equal pairs built apart, a pair that differs late, and options.
    const text = "abab";
    const pool = [_]types.Value{
        .{ .integer = 1 }, .{ .string = text[0..2] }, // 0..2
        .{ .integer = 1 }, .{ .string = text[2..4] }, // 2..4
        .{ .integer = 1 }, .{ .string = text[1..3] }, // 4..6
        .{ .floating = 0.0 }, .{ .floating = -0.0 }, // 6..8
        .{ .aggregate = .{ .value_type = @fromBackingInt(4), .elements = .{ .start = 0, .end = 2 } } }, // 8
        .{ .aggregate = .{ .value_type = @fromBackingInt(4), .elements = .{ .start = 2, .end = 4 } } }, // 9
    };
    const value = struct {
        fn of(start: u32, end: u32) types.Value {
            return .{ .aggregate = .{ .value_type = @fromBackingInt(4), .elements = .{ .start = start, .end = end } } };
        }
    }.of;
    const same = [_][2]types.Value{ .{ value(0, 2), value(2, 4) }, .{ value(6, 7), value(7, 8) }, .{ value(8, 9), value(9, 10) }, .{ value(3, 3), value(9, 9) } };
    const different = [_][2]types.Value{ .{ value(0, 2), value(4, 6) }, .{ value(0, 2), value(0, 1) }, .{ value(8, 9), value(8, 8) }, .{ value(0, 1), value(1, 2) } };
    var work: keys.Work = .{};
    defer work.release();
    for (same) |pair| {
        var fuel: u64 = 1000;
        try std.testing.expect(try keys.equal(&work, &pool, pair[0], pair[1], &fuel));
        const members = [_]types.Value{ pair[0], .{ .integer = 0 }, pair[1], .{ .integer = 0 } };
        try std.testing.expectError(error.DuplicateKey, keys.unique(&work, &pool, &members, &fuel));
        try std.testing.expectEqual(@as(?usize, 1), try keys.lookup(&work, &pool, &members, pair[1], &fuel));
    }
    for (different) |pair| {
        var fuel: u64 = 1000;
        try std.testing.expect(!try keys.equal(&work, &pool, pair[0], pair[1], &fuel));
        const members = [_]types.Value{ pair[0], .{ .integer = 0 }, pair[1], .{ .integer = 0 } };
        try keys.unique(&work, &pool, &members, &fuel);
        try std.testing.expectEqual(@as(?usize, 3), try keys.lookup(&work, &pool, &members, pair[1], &fuel));
    }
    // One unit for each value visited and one for each string byte compared; nothing after
    // the first difference, whose byte is charged. Equal pairs: the aggregate, two members, two bytes.
    for ([_]struct { [2]types.Value, u64 }{ .{ same[0], 5 }, .{ different[0], 4 }, .{ different[1], 1 }, .{ same[2], 6 } }) |case| {
        var fuel: u64 = case[1];
        _ = try keys.equal(&work, &pool, case[0][0], case[0][1], &fuel);
        try std.testing.expectEqual(@as(u64, 0), fuel);
        fuel = case[1] - 1;
        try std.testing.expectError(error.WorkLimit, keys.equal(&work, &pool, case[0][0], case[0][1], &fuel));
    }
}

const Key = struct { number: i64, letter: ?u8 };
const Entry = struct { key: Key, value: i64 };

fn sameKey(a: Key, b: Key) bool {
    return a.number == b.number and a.letter == b.letter;
}

fn writeKey(out: *std.Io.Writer, key: Key) !void {
    if (key.letter) |letter| {
        try out.print("tuple{{{d},option{{\"{c}\"}}}}", .{ key.number, letter });
    } else try out.print("tuple{{{d},option{{}}}}", .{key.number});
}

test "four thousand generated inserts updates removals and lookups with composite keys agree with a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x6b657973);
    const random = prng.random();
    const programs = 200;
    const operations = 20;
    var buffer: [8192]u8 = undefined;
    var removed: usize = 0;
    var missed: usize = 0;
    for (0..programs) |_| {
        var model: [12]Entry = undefined;
        var count: usize = 0;
        var looked: [operations]i64 = undefined;
        var lengths: [operations]usize = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Table:=map(tuple(i64,option(string)),i64)\nvar M:Table=map{}\n");
        for (0..operations) |step| {
            const key: Key = .{ .number = random.intRangeAtMost(i64, 0, 3), .letter = switch (random.uintLessThan(u8, 3)) {
                0 => null,
                1 => 'a',
                else => 'b',
            } };
            var found: ?usize = null;
            for (model[0..count], 0..) |entry, index| if (sameKey(entry.key, key)) {
                found = index;
            };
            looked[step] = -1;
            switch (random.uintLessThan(u8, 4)) {
                0, 1 => {
                    const value = random.intRangeAtMost(i64, 0, 99);
                    try out.writeAll("set M[");
                    try writeKey(&out, key);
                    try out.print("]={d}\n", .{value});
                    if (found) |index| {
                        model[index].value = value;
                    } else {
                        model[count] = .{ .key = key, .value = value };
                        count += 1;
                    }
                },
                2 => {
                    try out.writeAll("set M=Attempt(Without[M,");
                    try writeKey(&out, key);
                    try out.writeAll("],M)\n");
                    if (found) |index| {
                        std.mem.copyForwards(Entry, model[index .. count - 1], model[index + 1 .. count]);
                        count -= 1;
                        removed += 1;
                    } else missed += 1;
                },
                else => {
                    try out.print("L{d}:i64=Attempt(M[", .{step});
                    try writeKey(&out, key);
                    try out.writeAll("],-1)\n");
                    looked[step] = if (found) |index| model[index].value else -1;
                    // A lookup that finds nothing is told apart from one that was not made.
                    if (found == null) looked[step] = -2;
                },
            }
            try out.print("S{d}:i64=M.Length\n", .{step});
            lengths[step] = count;
        }
        try out.writeAll("Out:Table=M\n");
        const x = try h.execute(out.buffered());
        var name: [16]u8 = undefined;
        for (0..operations) |step| {
            try std.testing.expectEqual(@as(i64, @intCast(lengths[step])), x.get(try std.fmt.bufPrint(&name, "S{d}", .{step})).?.integer);
            if (looked[step] == -1) continue;
            try std.testing.expectEqual(@max(looked[step], -1), x.get(try std.fmt.bufPrint(&name, "L{d}", .{step})).?.integer);
        }
        const elements = x.elements(x.get("Out").?).?;
        try std.testing.expectEqual(2 * count, elements.len);
        for (model[0..count], 0..) |entry, index| {
            const key = x.elements(elements[2 * index]).?;
            try std.testing.expectEqual(entry.key.number, key[0].integer);
            const letter = x.elements(key[1]).?;
            try std.testing.expectEqual(@as(usize, @intFromBool(entry.key.letter != null)), letter.len);
            if (entry.key.letter) |byte| try std.testing.expectEqualStrings(&.{byte}, letter[0].string);
            try std.testing.expectEqual(entry.value, elements[2 * index + 1].integer);
        }
    }
    // The generator reached both outcomes of a removal many times.
    try std.testing.expect(removed > 100 and missed > 100);
}

fn nested(member: usize) types.Value {
    return .{ .aggregate = .{ .value_type = @fromBackingInt(4), .elements = .{ .start = @intCast(member), .end = @intCast(member + 1) } } };
}

test "walks below the near levels use what the run keeps and ask the host for nothing per comparison" {
    const allocator = std.testing.allocator;
    // One aggregate inside another, as deep as the deepest type a catalogue can hold, and one
    // level deeper than that for a value no admission lets through.
    const depth = types.limits.user_types;
    const count = 8;
    const stride = depth + 1;
    const pool = try allocator.alloc(types.Value, count * stride);
    defer allocator.free(pool);
    var elements: [2 * count]types.Value = undefined;
    for (0..count) |chain| {
        const base = chain * stride;
        pool[base] = .{ .integer = @intCast(chain) };
        for (1..stride) |level| pool[base + level] = nested(base + level - 1);
        elements[2 * chain] = nested(base + depth - 1);
        elements[2 * chain + 1] = .{ .integer = 0 };
    }
    const wanted = elements[2 * (count - 1)];
    // Every entry is scanned, and every comparison goes to the bottom: `depth` aggregates and
    // the number under them, which is where the keys differ.
    const cost: u64 = count * (depth + 2);

    // A machine without storage of its own takes the far levels once for the whole run.
    var kept: keys.Work = .{};
    defer kept.release();
    var fuel: u64 = cost;
    try std.testing.expectEqual(@as(?usize, 2 * count - 1), try keys.lookup(&kept, pool, &elements, wanted, &fuel));
    try std.testing.expectEqual(@as(u64, 0), fuel);
    try std.testing.expectEqual(@as(u32, 1), kept.host_requests);
    fuel = cost - 1;
    try std.testing.expectError(error.WorkLimit, keys.lookup(&kept, pool, &elements, wanted, &fuel));
    fuel = 1 << 32;
    try keys.unique(&kept, pool, &elements, &fuel);
    const literal_cost = (1 << 32) - fuel;
    try std.testing.expect(try keys.equal(&kept, pool, wanted, wanted, &fuel));
    try std.testing.expectEqual(@as(u32, 1), kept.host_requests);

    // A machine that owns the levels lends them: the host is never asked, so it may have nothing.
    const levels = try allocator.create(keys.FarLevels);
    defer allocator.destroy(levels);
    var lent = keys.Work.lend(levels);
    defer lent.release();
    lent.host_exhausted = true;
    fuel = cost;
    try std.testing.expectEqual(@as(?usize, 2 * count - 1), try keys.lookup(&lent, pool, &elements, wanted, &fuel));
    try std.testing.expectEqual(@as(u64, 0), fuel);
    fuel = literal_cost;
    try keys.unique(&lent, pool, &elements, &fuel);
    try std.testing.expectEqual(@as(u64, 0), fuel);
    try std.testing.expectEqual(@as(u32, 0), lent.host_requests);
    // Deeper than any type nests: cut off, with fuel to spare, and not by the host.
    fuel = cost;
    try std.testing.expectError(error.WorkLimit, keys.equal(&lent, pool, nested(depth), nested(depth), &fuel));
    try std.testing.expect(fuel != 0);

    // A host with nothing to give is its own outcome, and only for a walk that needs it.
    var none: keys.Work = .{ .host_exhausted = true };
    defer none.release();
    fuel = cost;
    try std.testing.expectError(error.ScratchUnavailable, keys.lookup(&none, pool, &elements, wanted, &fuel));
    try std.testing.expect(fuel != 0);
    fuel = cost;
    try std.testing.expect(try keys.equal(&none, pool, nested(15), nested(15), &fuel));
    try std.testing.expectError(error.ScratchUnavailable, keys.equal(&none, pool, nested(16), nested(16), &fuel));
    try std.testing.expectEqual(@as(u32, 0), none.host_requests);

    // A literal too large for the table on the native stack: the run's table, taken once.
    var large: [2 * 300]types.Value = undefined;
    for (0..300) |index| {
        large[2 * index] = .{ .integer = @intCast(index) };
        large[2 * index + 1] = .{ .integer = 0 };
    }
    fuel = 1 << 20;
    try keys.unique(&kept, pool, &large, &fuel);
    try std.testing.expectEqual(@as(u32, 2), kept.host_requests);
    const table_cost = (1 << 20) - fuel;
    try keys.unique(&kept, pool, &large, &fuel);
    try keys.unique(&kept, pool, large[0..520], &fuel);
    try std.testing.expectEqual(@as(u32, 2), kept.host_requests);
    fuel = table_cost;
    try std.testing.expectError(error.ScratchUnavailable, keys.unique(&lent, pool, &large, &fuel));
    try std.testing.expectEqual(table_cost, fuel);
    large[2 * 299] = .{ .integer = 7 };
    fuel = 1 << 20;
    try std.testing.expectError(error.DuplicateKey, keys.unique(&kept, pool, &large, &fuel));
}

test "deep keys cost both machines the same fuel at every budget and the machine only its own levels" {
    const h = try harness.create();
    defer scratch.release(h);
    const depth = 40;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("Deep:=");
    for (0..depth) |_| try out.writeAll("option(");
    try out.writeAll("i64");
    for (0..depth) |_| try out.writeAll(")");
    for ([_]struct { []const u8, i64 }{ .{ "X", 1 }, .{ "Y", 1 }, .{ "Z", 2 } }) |binding| {
        try out.print("\n{s}:Deep=", .{binding[0]});
        for (0..depth) |_| try out.writeAll("option{");
        try out.print("{d}", .{binding[1]});
        for (0..depth) |_| try out.writeAll("}");
    }
    const values = out.buffered().len;
    // Nothing compared; one comparison; a second one. Each visits `depth` options and a number.
    const none = try threshold(h, buffer[0..values], 1024);
    try out.writeAll("\nA:logic=X==Y");
    const one = try threshold(h, out.buffered(), 1024);
    try std.testing.expectEqual(none + 1 + depth + 1, one);
    try out.writeAll("\nB:logic=Y==X");
    try std.testing.expectEqual(one + 1 + depth + 1, try threshold(h, out.buffered(), 1024));
    // As keys: a literal, a hit behind another deep key, and a removal, at every budget.
    out.end = values;
    try out.writeAll("\nTable:map(Deep,i64)=map{Z=>2,X=>1}\nD:i64=Attempt(Table[Y],-1)\nE:i64=Attempt(Without[Table,Y].Length,-1)");
    _ = try threshold(h, out.buffered(), 2048);
    const x = try h.execute(out.buffered());
    try expectIntegers(x, &.{ .{ "D", 1 }, .{ "E", 1 } });
    // Thousands of runs, each comparing below the near levels, and the host was never asked.
    const machine = &h.runtime.machine;
    try std.testing.expectEqual(@as(u32, 0), machine.key_work.host_requests);
    try std.testing.expect(machine.key_work.far_lent and machine.key_work.slots.len == 0);

    // The one thing the machine does take from the host is the table of a map literal too
    // large for the native stack. A host without it is reported as that, not as spent fuel,
    // and the table is returned when the run ends.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "M:map(i64,i64)=map{");
    for (0..300) |index| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (index == 0) "" else ",", index, index });
    try source.appendSlice(std.testing.allocator, "}\nR:i64=Attempt(M[299],-1)");
    const p = try h.compile(source.items);
    const lowered = bytecode.lower(p, &h.runtime.instructions).ok;
    machine.key_work.host_exhausted = true;
    try std.testing.expectEqual(types.Diagnostic.Code.scratch_unavailable, machine.run(lowered, 100_000).failed.code);
    try std.testing.expectEqual(@as(u32, 0), machine.key_work.host_requests);
    machine.key_work.host_exhausted = false;
    try std.testing.expectEqual(@as(i64, 299), (try h.run(p, 100_000)).ok.get("R").?.integer);
    try std.testing.expectEqual(@as(u32, 1), machine.key_work.host_requests);
    try std.testing.expectEqual(@as(usize, 0), machine.key_work.slots.len);
}

test "Without scans its map once and a removal handed anything but an entry of its map traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // The last key instead of the first: two more entries scanned, each one unit and one
    // comparison, by the lookup alone. The removal does not search.
    const first = try threshold(h, "M:map(i64,i64)=map{1=>10,2=>20,3=>30}\nR:i64=Attempt(Without[M,1].Length,-1)", 256);
    const last = try threshold(h, "M:map(i64,i64)=map{1=>10,2=>20,3=>30}\nR:i64=Attempt(Without[M,3].Length,-1)", 256);
    try std.testing.expectEqual(first + 4, last);

    // The entry found in another map: an option of the right type that views no value of this one.
    const p = try h.compile("M:map(i64,i64)=map{1=>10,2=>20}\nN:map(i64,i64)=map{5=>50,6=>60,7=>70}\nR:i64=Attempt(Without[M,1].Length+Without[N,6].Length,-1)");
    try std.testing.expectEqual(@as(i64, 3), (try h.run(p, 10_000)).ok.get("R").?.integer);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var removals: [2]usize = undefined;
    var found: usize = 0;
    for (nodes, 0..) |node, index| if (node.kind == .map_remove) {
        removals[found] = index;
        found += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    // What the compiler hands a removal is the lookup of its guard, in the same map.
    for (removals) |at| {
        const lookup = nodes[nodes[at].kind.map_remove.key].kind.map_lookup;
        try std.testing.expectEqual(nodes[at].kind.map_remove.map, lookup.map);
    }
    var forged = p;
    forged.nodes = nodes;
    nodes[removals[1]].kind.map_remove.key = nodes[removals[0]].kind.map_remove.key;
    try harness.traps(h, forged, 10_000);
    // A key where the entry belongs is not admitted at all.
    nodes[removals[1]].kind.map_remove.key = p.nodes[p.nodes[removals[1]].kind.map_remove.key].kind.map_lookup.key;
    try harness.invalid(h, forged);

    // Another entry of the same map is an entry: both machines take that one out, alike.
    const q = try h.compile("M:map(i64,i64)=map{1=>10,2=>20,3=>30}\nR:i64=Attempt(Without[M,1].Length+Without[M,3][1],-1)");
    try std.testing.expectEqual(@as(i64, 12), (try h.run(q, 10_000)).ok.get("R").?.integer);
    const same = try std.testing.allocator.dupe(types.Node, q.nodes);
    defer std.testing.allocator.free(same);
    found = 0;
    for (same, 0..) |node, index| if (node.kind == .map_remove) {
        removals[found] = index;
        found += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    same[removals[1]].kind.map_remove.key = same[removals[0]].kind.map_remove.key;
    forged = q;
    forged.nodes = same;
    // Key 1 is gone from the second copy instead of key 3, so reading it there fails.
    const r = try h.run(forged, 10_000);
    try std.testing.expectEqual(@as(i64, -1), r.ok.get("R").?.integer);

    // The report holds a removal to the entry its operand views: moved to the next entry, the
    // members that were kept are no longer the ones that removal keeps.
    const limits: reporting.Limits = .{ .work = 1024 * 1024 };
    const honest = try h.run(q, 10_000);
    _ = try reporting.validate(honest.ok, false, limits);
    const entry = &h.runtime.machine.values[q.nodes[removals[0]].kind.map_remove.key];
    const view = entry.aggregate.elements;
    entry.aggregate.elements = .{ .start = view.start + 2, .end = view.end + 2 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(honest.ok, false, limits));
    // An empty option, and one that views a key instead of a value.
    entry.aggregate.elements = .{ .start = view.start, .end = view.start };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(honest.ok, false, limits));
    entry.aggregate.elements = .{ .start = view.start - 1, .end = view.start };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(honest.ok, false, limits));
    entry.aggregate.elements = view;
    _ = try reporting.validate(honest.ok, false, limits);
}

/// Forged IR that asks one question of the catalogue as often as a program has nodes: options
/// nested in one another up to the last type a catalogue holds, an empty option of that type,
/// and nothing but comparisons of it with itself. With `holds_function` the innermost part is
/// a function, so the outermost type has no equality.
pub const Comparisons = struct {
    definitions: []types.Definition,
    nodes: []types.Node,
    program: types.Program,

    pub fn create(allocator: std.mem.Allocator, type_count: usize, node_count: usize, holds_function: bool) !Comparisons {
        std.debug.assert(type_count >= 3 and node_count >= 2);
        const definitions = try allocator.alloc(types.Definition, type_count);
        errdefer allocator.free(definitions);
        const nodes = try allocator.alloc(types.Node, node_count);
        definitions[0] = .{ .tuple = .{ .start = 0, .end = 0 } };
        definitions[1] = if (holds_function) .{ .callable = .{ .parameters = @fromBackingInt(4), .result = .i64 } } else .{ .option = .i64 };
        for (definitions[2..], 2..) |*item, index| item.* = .{ .option = @fromBackingInt(@intCast(index + 3)) };
        const origin: types.Span = .{ .start = 0, .end = 0 };
        nodes[0] = .{ .span = origin, .value_type = @fromBackingInt(@intCast(type_count + 3)), .kind = .{ .aggregate = origin } };
        for (nodes[1..]) |*node| node.* = .{ .span = origin, .value_type = .logic, .kind = .{ .compare = .{ .op = .equal, .lhs = 0, .rhs = 0 } } };
        return .{ .definitions = definitions, .nodes = nodes, .program = .{ .source = "", .strings = "", .nodes = nodes, .bindings = &.{}, .definitions = definitions, .string_comparisons = @intCast(node_count - 1) } };
    }

    pub fn destroy(self: Comparisons, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.definitions);
    }

    /// What a run costs: the option, and for each comparison its node and the one value visited.
    pub fn fuel(self: Comparisons) u64 {
        return 1 + 2 * (self.nodes.len - 1);
    }
};

test "a program of nothing but comparisons on the last type of a full catalogue is admitted by one pass over it" {
    const h = try harness.create();
    defer scratch.release(h);
    const forged = try Comparisons.create(std.testing.allocator, types.limits.user_types, types.limits.nodes, false);
    defer forged.destroy(std.testing.allocator);
    // Both admissions accept it and both machines charge it alike, to the unit.
    const r = try h.run(forged.program, forged.fuel());
    try std.testing.expect(r.ok.values[forged.nodes.len - 1].boolean);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(forged.program, forged.fuel() - 1)).failed.code);
    // The same catalogue over a function: the answer for the last type is the innermost part's.
    const refused = try Comparisons.create(std.testing.allocator, types.limits.user_types, 2, true);
    defer refused.destroy(std.testing.allocator);
    try harness.invalid(h, refused.program);
    // The pass itself, at both ends and at the step in between.
    const answers = try std.testing.allocator.alloc(bool, types.limits.user_types);
    defer std.testing.allocator.free(answers);
    catalogue.comparableTypes(forged.definitions, &.{}, &.{}, answers);
    try std.testing.expect(std.mem.allEqual(bool, answers, true));
    catalogue.comparableTypes(refused.definitions, &.{}, &.{}, answers);
    try std.testing.expect(answers[0] and std.mem.allEqual(bool, answers[1..], false));
    try std.testing.expect(!catalogue.comparableIn(@fromBackingInt(@intCast(types.limits.user_types + 4)), answers));
}
