//! The Book's standard functions over numbers, arrays, maps and strings (RFC-0077): behaviour
//! at the edges, diagnostics, name resolution against everything a program can declare,
//! forged calls of the generic kernels, and a randomized oracle against plain Zig models. The
//! harness runs every program on both machines and through the report replay and compares them.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const result = h.front.compile(source);
    if (result == .ok) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code) std.debug.print("got {s}, expected {s}: {s}\n", .{ @tagName(result.failed.code), @tagName(code), source });
    try std.testing.expectEqual(code, result.failed.code);
}
fn expectInteger(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    if (value != .integer or value.integer != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.integer);
}
fn expectFloat(x: evaluator.Execution, name: []const u8, expected: f64) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    if (std.math.isNan(expected)) return std.testing.expect(std.math.isNan(value.floating));
    if (@as(u64, @bitCast(value.floating)) != @as(u64, @bitCast(expected))) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.floating, expected });
    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(value.floating)));
}
fn expectString(x: evaluator.Execution, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, value.string);
}
fn expectLogic(x: evaluator.Execution, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    if (value.boolean != expected) std.debug.print("{s}: expected {}\n", .{ name, expected });
    try std.testing.expectEqual(expected, value.boolean);
}
fn expectIntegers(x: evaluator.Execution, name: []const u8, expected: []const i64) !void {
    const range = (x.get(name) orelse return error.TestUnexpectedResult).aggregate.elements;
    if (expected.len != range.end - range.start) std.debug.print("{s}: {d} elements, expected {d}\n", .{ name, range.end - range.start, expected.len });
    try std.testing.expectEqual(expected.len, range.end - range.start);
    for (expected, x.aggregate_values[range.start..range.end], 0..) |want, got, index| {
        if (want != got.integer) std.debug.print("{s}[{d}]: {d}, expected {d}\n", .{ name, index, got.integer, want });
        try std.testing.expectEqual(want, got.integer);
    }
}

fn nativeNode(p: types.Program, id: []const u8) !usize {
    for (p.nodes, 0..) |node, index| {
        if (node.kind == .native_call and std.mem.eql(u8, p.natives[node.kind.native_call.native].id, id)) return index;
    }
    return error.TestUnexpectedResult;
}
fn bindingNode(p: types.Program, name: []const u8) !u32 {
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), name)) return binding.node;
    return error.TestUnexpectedResult;
}
/// The least fuel with which the program completes. Every budget below it must stop both
/// machines with `work_limit`, which the harness compares; so the two charge alike.
fn leastFuel(h: *harness.Harness, p: types.Program, limit: u64) !u64 {
    var low: u64 = 0;
    var high: u64 = limit;
    try std.testing.expect((try h.run(p, high)) == .ok);
    while (low < high) {
        const middle = low + (high - low) / 2;
        const result = try h.run(p, middle);
        if (result == .ok) {
            high = middle;
        } else {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            low = middle + 1;
        }
    }
    return low;
}

test "array methods: the Book's examples" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Nums:[]i64=array{1,2,3,1,2,3}
        \\Tens:[]i64=array{10,20,30,40,50}
        \\Four:[]i64=array{10,20,30,40}
        \\Three:[]i64=array{10,20,40}
        \\Found:i64=Attempt(Nums.Find[2],0-1)
        \\Missing:i64=Attempt(Nums.Find[0],0-1)
        \\Fruit:i64=Attempt(array{"Apple","Orange","Strawberry"}.Find["Strawberry"],0-1)
        \\Mid:[]i64=Attempt(Tens.Slice[1,4],array{})
        \\Tail:[]i64=Attempt(Tens.Slice[2],array{})
        \\Empty:[]i64=Attempt(Tens.Slice[2,2],array{0-1})
        \\Backwards:[]i64=Attempt(Tens.Slice[2,1],array{0-1})
        \\Negative:[]i64=Attempt(Tens.Slice[0-1,2],array{0-1})
        \\Beyond:[]i64=Attempt(Tens.Slice[0,10],array{0-1})
        \\FirstGone:[]i64=Attempt(Nums.RemoveFirstElement[2],array{})
        \\NoneGone:[]i64=Attempt(Nums.RemoveFirstElement[0],array{0-1})
        \\AllGone:[]i64=Nums.RemoveAllElements(2)
        \\Kept:[]i64=Nums.RemoveAllElements(0)
        \\Cut:[]i64=Attempt(Four.Remove[1,2],array{})
        \\CutNegative:[]i64=Attempt(Four.Remove[0-1,0],array{0-1})
        \\CutBeyond:[]i64=Attempt(Four.Remove[6,10],array{0-1})
        \\FirstNew:[]i64=Attempt(Nums.ReplaceFirstElement[2,99],array{})
        \\NoneNew:[]i64=Attempt(Nums.ReplaceFirstElement[0,99],array{0-1})
        \\AllNew:[]i64=Nums.ReplaceAllElements(2,99)
        \\SameNew:[]i64=Nums.ReplaceAllElements(0,99)
        \\At:[]i64=Attempt(Four.ReplaceElement[1,99],array{})
        \\AtNegative:[]i64=Attempt(Four.ReplaceElement[0-1,99],array{0-1})
        \\AtBeyond:[]i64=Attempt(Four.ReplaceElement[10,99],array{0-1})
        \\Runs:[]i64=array{1,2,3,4,2,3,5}.ReplaceAll(array{2,3},array{99})
        \\Longer:[]i64=array{1,2,2,1,2,2,1}.ReplaceAll(array{2,2},array{9,9,9})
        \\In2:[]i64=Attempt(Three.Insert[2,array{30}],array{})
        \\In0:[]i64=Attempt(Three.Insert[0,array{5}],array{})
        \\InEnd:[]i64=Attempt(Three.Insert[Three.Length,array{50}],array{})
        \\InNegative:[]i64=Attempt(Three.Insert[0-1,array{5}],array{0-1})
        \\InBeyond:[]i64=Attempt(Three.Insert[Three.Length+1,array{5}],array{0-1})
        \\One:[]i64=Concatenate(array{array{1,2,3}})
        \\Two:[]i64=Concatenate(array{1,2},array{3,4})
        \\Many:[]i64=Concatenate(array{1},array{2,3},array{4},array{5,6})
        \\Gap:[]i64=Concatenate(array{1,2},array{},array{3})
        \\Same:logic=array{1,2}+array{3,4}+array{5,6}==Concatenate(array{1,2},array{3,4},array{5,6})
        \\Last0:i64=Attempt(Four.Last[],0-1)
        \\Last2:i64=Attempt(Three.Last[2],0-1)
        \\Last3:i64=Attempt(Three.Last[3],0-1)
        \\LastNegative:i64=Attempt(Three.Last[0-1],0-1)
        \\None:[]i64=array{}
        \\LastOfNone:i64=Attempt(None.Last[],0-1)
    );
    try expectInteger(x, "Found", 1);
    try expectInteger(x, "Missing", -1);
    try expectInteger(x, "Fruit", 2);
    try expectIntegers(x, "Mid", &.{ 20, 30, 40 });
    try expectIntegers(x, "Tail", &.{ 30, 40, 50 });
    try expectIntegers(x, "Empty", &.{});
    try expectIntegers(x, "Backwards", &.{-1});
    try expectIntegers(x, "Negative", &.{-1});
    try expectIntegers(x, "Beyond", &.{-1});
    try expectIntegers(x, "FirstGone", &.{ 1, 3, 1, 2, 3 });
    try expectIntegers(x, "NoneGone", &.{-1});
    try expectIntegers(x, "AllGone", &.{ 1, 3, 1, 3 });
    try expectIntegers(x, "Kept", &.{ 1, 2, 3, 1, 2, 3 });
    try expectIntegers(x, "Cut", &.{ 10, 30, 40 });
    try expectIntegers(x, "CutNegative", &.{-1});
    try expectIntegers(x, "CutBeyond", &.{-1});
    try expectIntegers(x, "FirstNew", &.{ 1, 99, 3, 1, 2, 3 });
    try expectIntegers(x, "NoneNew", &.{-1});
    try expectIntegers(x, "AllNew", &.{ 1, 99, 3, 1, 99, 3 });
    try expectIntegers(x, "SameNew", &.{ 1, 2, 3, 1, 2, 3 });
    try expectIntegers(x, "At", &.{ 10, 99, 30, 40 });
    try expectIntegers(x, "AtNegative", &.{-1});
    try expectIntegers(x, "AtBeyond", &.{-1});
    try expectIntegers(x, "Runs", &.{ 1, 99, 4, 99, 5 });
    try expectIntegers(x, "Longer", &.{ 1, 9, 9, 9, 1, 9, 9, 9, 1 });
    try expectIntegers(x, "In2", &.{ 10, 20, 30, 40 });
    try expectIntegers(x, "In0", &.{ 5, 10, 20, 40 });
    try expectIntegers(x, "InEnd", &.{ 10, 20, 40, 50 });
    try expectIntegers(x, "InNegative", &.{-1});
    try expectIntegers(x, "InBeyond", &.{-1});
    try expectIntegers(x, "One", &.{ 1, 2, 3 });
    try expectIntegers(x, "Two", &.{ 1, 2, 3, 4 });
    try expectIntegers(x, "Many", &.{ 1, 2, 3, 4, 5, 6 });
    try expectIntegers(x, "Gap", &.{ 1, 2, 3 });
    try expectLogic(x, "Same", true);
    try expectInteger(x, "Last0", 40);
    try expectInteger(x, "Last2", 10);
    try expectInteger(x, "Last3", -1);
    try expectInteger(x, "LastNegative", -1);
    try expectInteger(x, "LastOfNone", -1);
}

test "array methods at the edges: empty arrays, the ends of i64, overlapping and empty patterns" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Most:i64=9223372036854775807
        \\Least:i64=0-Most-1
        \\None:[]i64=array{}
        \\Xs:[]i64=array{7,8,9}
        \\A1:i64=Attempt(None.Find[1],0-1)
        \\A2:[]i64=None.RemoveAllElements(1)
        \\A3:[]i64=None.ReplaceAllElements(1,2)
        \\A4:[]i64=None.ReplaceAll(array{1},array{2})
        \\A5:[]i64=Attempt(None.Slice[0,0],array{0-1})
        \\A6:[]i64=Attempt(None.Slice[0],array{0-1})
        \\A7:[]i64=Attempt(None.Slice[1],array{0-1})
        \\A8:[]i64=Attempt(None.Remove[0,0],array{0-1})
        \\A9:[]i64=Attempt(None.Insert[0,None],array{0-1})
        \\A10:[]i64=Attempt(None.Insert[0,Xs],array{0-1})
        \\A11:[]i64=Attempt(None.ReplaceElement[0,1],array{0-1})
        \\A12:[]i64=Concatenate(array{None,None})
        \\A13:[]i64=Concatenate(None,None)
        \\B1:[]i64=Attempt(Xs.Slice[Least,Most],array{0-1})
        \\B2:[]i64=Attempt(Xs.Slice[Most],array{0-1})
        \\B3:[]i64=Attempt(Xs.Slice[Least],array{0-1})
        \\B4:[]i64=Attempt(Xs.Remove[Most,Most],array{0-1})
        \\B5:[]i64=Attempt(Xs.Remove[Least,Least],array{0-1})
        \\B6:[]i64=Attempt(Xs.Insert[Most,None],array{0-1})
        \\B7:i64=Attempt(Xs.Last[Most],0-1)
        \\B8:i64=Attempt(Xs.Last[Least],0-1)
        \\B9:[]i64=Attempt(Xs.ReplaceElement[Most,1],array{0-1})
        \\B10:[]i64=Attempt(Xs.ReplaceElement[Least,1],array{0-1})
        \\B11:[]i64=Attempt(Xs.Slice[3],array{0-1})
        \\B12:[]i64=Attempt(Xs.Slice[3,3],array{0-1})
        \\B13:[]i64=Attempt(Xs.Remove[0,3],array{0-1})
        \\B14:[]i64=Attempt(Xs.Remove[3,3],array{0-1})
        \\B15:[]i64=Attempt(Xs.Slice[0,3],array{0-1})
        \\B16:i64=Attempt(Xs.Last[2],0-1)
        \\B17:[]i64=Attempt(Xs.RemoveFirstElement[9],array{0-1})
        \\B18:[]i64=Attempt(Xs.ReplaceFirstElement[9,Least],array{0-1})
        \\C1:[]i64=array{1,1,1,1,1}.ReplaceAll(array{1,1},array{2})
        \\C2:[]i64=Xs.ReplaceAll(None,array{5})
        \\C3:[]i64=Xs.ReplaceAll(array{7,8,9,10},array{5})
        \\C4:[]i64=Xs.ReplaceAll(Xs,None)
        \\C5:[]i64=Xs.ReplaceAll(array{8},None)
        \\C6:[]i64=array{1,2,1,2,1}.ReplaceAll(array{1,2,1},array{0})
        \\C7:[]i64=Xs.ReplaceAll(array{9},array{9,9})
        \\C8:[]i64=array{1,1,2}.ReplaceAll(array{1,2},array{3})
    );
    try expectInteger(x, "A1", -1);
    for ([_][]const u8{ "A2", "A3", "A4", "A5", "A6", "A8", "A9", "A12", "A13" }) |name| try expectIntegers(x, name, &.{});
    try expectIntegers(x, "A7", &.{-1});
    try expectIntegers(x, "A10", &.{ 7, 8, 9 });
    try expectIntegers(x, "A11", &.{-1});
    // The ends of `i64` are positions like any other: outside the array, so the form fails;
    // nothing overflows on the way to finding that out.
    for ([_][]const u8{ "B1", "B2", "B3", "B4", "B5", "B6", "B9", "B10" }) |name| try expectIntegers(x, name, &.{-1});
    try expectInteger(x, "B7", -1);
    try expectInteger(x, "B8", -1);
    try expectIntegers(x, "B11", &.{});
    try expectIntegers(x, "B12", &.{});
    try expectIntegers(x, "B13", &.{});
    try expectIntegers(x, "B14", &.{ 7, 8, 9 });
    try expectIntegers(x, "B15", &.{ 7, 8, 9 });
    try expectInteger(x, "B16", 7);
    try expectIntegers(x, "B17", &.{ 7, 8 });
    try expectIntegers(x, "B18", &.{ 7, 8, std.math.minInt(i64) });
    // Occurrences are found from the left and do not overlap; an empty pattern occurs nowhere.
    try expectIntegers(x, "C1", &.{ 2, 2, 1 });
    try expectIntegers(x, "C2", &.{ 7, 8, 9 });
    try expectIntegers(x, "C3", &.{ 7, 8, 9 });
    try expectIntegers(x, "C4", &.{});
    try expectIntegers(x, "C5", &.{ 7, 9 });
    try expectIntegers(x, "C6", &.{ 0, 2, 1 });
    try expectIntegers(x, "C7", &.{ 7, 8, 9, 9 });
    try expectIntegers(x, "C8", &.{ 1, 3 });
}

test "array methods work on every element type and compare as == does" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Pt:=struct{X:i64,Y:i64}
        \\Color:=enum{Red,Green,Blue}
        \\Animal:=class<unique>{Name:string="a"}
        \\Dog:=class<unique>(Animal){}
        \\Rex:Dog=Dog{}
        \\Tom:Animal=Animal{}
        \\Pets:[]Animal=array{Tom,Rex,Tom}
        \\WhereRex:i64=Attempt(Pets.Find[Rex],0-1)
        \\Strangers:i64=Attempt(Pets.Find[Dog{}],0-1)
        \\NoTom:i64=Pets.RemoveAllElements(Tom).Length
        \\AllRex:i64=Pets.ReplaceAllElements(Tom,Rex).RemoveAllElements(Rex).Length
        \\Pts:[]Pt=array{Pt{X:=1,Y:=2},Pt{X:=3,Y:=4}}
        \\WherePt:i64=Attempt(Pts.Find[Pt{X:=3,Y:=4}],0-1)
        \\NoPt:i64=Attempt(Pts.Find[Pt{X:=4,Y:=3}],0-1)
        \\Fs:[]float=array{1.0,NaN,0.0}
        \\WhereNaN:i64=Attempt(Fs.Find[NaN],0-1)
        \\WhereNegativeZero:i64=Attempt(Fs.Find[0.0*(0.0-1.0)],0-1)
        \\NoNaN:i64=Fs.RemoveAllElements(NaN).Length
        \\Words:[]string=array{"a","bc","","a"}
        \\WhereEmpty:i64=Attempt(Words.Find[""],0-1)
        \\Built:i64=Attempt(Words.Find["b"+"c"],0-1)
        \\NoA:[]string=Words.RemoveAllElements("a")
        \\Shout:[]string=Words.ReplaceAll(array{"bc",""},array{"!"})
        \\Colors:[]Color=array{Color.Red,Color.Blue}
        \\WhereBlue:i64=Attempt(Colors.Find[Color.Blue],0-1)
        \\Pairs:[]tuple(i64,string)=array{tuple{1,"x"},tuple{2,"y"}}
        \\WherePair:i64=Attempt(Pairs.Find[tuple{2,"y"}],0-1)
        \\Opts:[]option(i64)=array{option{1},option{}}
        \\WhereNone:i64=Attempt(Opts.Find[option{}],0-1)
        \\Rows:[][]i64=array{array{1},array{},array{2,3}}
        \\WhereRow:i64=Attempt(Rows.Find[array{2,3}],0-1)
        \\WhereEmptyRow:i64=Attempt(Rows.Find[array{}],0-1)
        \\Flat:[]i64=Concatenate(Rows)
        \\Deep:[][]i64=Concatenate(array{Rows,Rows})
        \\Inner:[]i64=Attempt(Rows.Slice[1].Last[],array{})
        \\Maps:[]map(i64,i64)=array{map{1=>2},map{}}
        \\WhereMap:i64=Attempt(Maps.Find[map{1=>2}],0-1)
        \\Chars:[]char=For(C:"abca",C)
        \\NoAs:[]char=Chars.RemoveAllElements('a')
        \\Back:string=Attempt(string[NoAs],"!")
        \\Twice(V:i64)<computes>:i64=V*2
        \\Thrice(V:i64)<computes>:i64=V*3
        \\Fns:[]function(tuple(i64),i64)=array{Twice,Thrice}
        \\Picked:i64=Attempt(Fns.Last[](5),0)
        \\Sliced:i64=Attempt(Fns.Slice[0,1].Last[](5),0)
        \\Swapped:i64=Attempt(Fns.ReplaceElement[1,Twice].Last[](5),0)
        \\Grown:i64=Attempt(Fns.Insert[1,Fns],array{}).Length
        \\Shrunk:i64=Attempt(Fns.Remove[0,1],array{}).Length
        \\Both:i64=Concatenate(array{Fns,Fns}).Length
    );
    try expectInteger(x, "WhereRex", 1);
    try expectInteger(x, "Strangers", -1);
    try expectInteger(x, "NoTom", 1);
    try expectInteger(x, "AllRex", 0);
    try expectInteger(x, "WherePt", 1);
    try expectInteger(x, "NoPt", -1);
    // One NaN and one zero, as `==` has them (RFC-0067 D4).
    try expectInteger(x, "WhereNaN", 1);
    try expectInteger(x, "WhereNegativeZero", 2);
    try expectInteger(x, "NoNaN", 2);
    try expectInteger(x, "WhereEmpty", 2);
    try expectInteger(x, "Built", 1);
    try expectInteger(x, "WhereBlue", 1);
    try expectInteger(x, "WherePair", 1);
    try expectInteger(x, "WhereNone", 1);
    try expectInteger(x, "WhereRow", 2);
    try expectInteger(x, "WhereEmptyRow", 1);
    try expectIntegers(x, "Flat", &.{ 1, 2, 3 });
    try expectIntegers(x, "Inner", &.{ 2, 3 });
    try expectInteger(x, "WhereMap", 0);
    try expectString(x, "Back", "bc");
    try expectInteger(x, "Picked", 15);
    try expectInteger(x, "Sliced", 10);
    try expectInteger(x, "Swapped", 10);
    try expectInteger(x, "Grown", 4);
    try expectInteger(x, "Shrunk", 1);
    try expectInteger(x, "Both", 4);
    const no_a = x.get("NoA").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 2), no_a.end - no_a.start);
    try std.testing.expectEqualStrings("bc", x.aggregate_values[no_a.start].string);
    try std.testing.expectEqualStrings("", x.aggregate_values[no_a.start + 1].string);
    const shout = x.get("Shout").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 3), shout.end - shout.start);
    try std.testing.expectEqualStrings("!", x.aggregate_values[shout.start + 1].string);
    const deep = x.get("Deep").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 6), deep.end - deep.start);
    // Searching needs an equality; moving does not.
    try expectCode(h, "T(V:i64)<computes>:i64=V\nFs:[]function(tuple(i64),i64)=array{T}\nA:i64=Attempt(Fs.Find[T],0)", .not_comparable);
    try expectCode(h, "T(V:i64)<computes>:i64=V\nFs:[]function(tuple(i64),i64)=array{T}\nA:[]function(tuple(i64),i64)=Fs.RemoveAllElements(T)", .not_comparable);
    try expectCode(h, "T(V:i64)<computes>:i64=V\nFs:[]function(tuple(i64),i64)=array{T}\nA:[]function(tuple(i64),i64)=Fs.ReplaceAll(Fs,Fs)", .not_comparable);
    try expectCode(h, "T(V:i64)<computes>:i64=V\nFs:[]function(tuple(i64),i64)=array{T}\nA:[]function(tuple(i64),i64)=Attempt(Fs.ReplaceFirstElement[T,T],Fs)", .not_comparable);
}

test "string methods keep text text: positions are code units and never split a scalar" {
    const h = try harness.create();
    defer scratch.release(h);
    // "José" is J o s C3 A9: five code units, four scalar values.
    const x = try h.execute(
        \\S:string="José"
        \\E:string=""
        \\Book:string="Hey, this is a string, Hello!".ReplaceAll("He","Apples")
        \\Gone:string=S.ReplaceAll("é","")
        \\Wider:string=S.ReplaceAll("s","é")
        \\Same:string=S.ReplaceAll("x","y")
        \\NoPattern:string=S.ReplaceAll("","y")
        \\TooLong:string=S.ReplaceAll("Joséé","y")
        \\Whole:string=S.ReplaceAll(S,E)
        \\OfEmpty:string=E.ReplaceAll("a","b")
        \\Overlap:string="aaaaa".ReplaceAll("aa","b")
        \\WhereS:i64=Attempt(S.Find['s'],0-1)
        \\WhereLead:i64=Attempt(S.Find[0oC3],0-1)
        \\WhereTrail:i64=Attempt(S.Find[0oA9],0-1)
        \\WhereX:i64=Attempt(S.Find['x'],0-1)
        \\InEmpty:i64=Attempt(E.Find['a'],0-1)
        \\In0:string=Attempt(S.Insert[0,"<"],"!")
        \\In3:string=Attempt(S.Insert[3,"-"],"!")
        \\In4:string=Attempt(S.Insert[4,"-"],"!")
        \\In5:string=Attempt(S.Insert[5,">"],"!")
        \\In6:string=Attempt(S.Insert[6,">"],"!")
        \\InNegative:string=Attempt(S.Insert[0-1,">"],"!")
        \\InNothing:string=Attempt(S.Insert[2,E],"!")
        \\IntoEmpty:string=Attempt(E.Insert[0,S],"!")
        \\Cut:string=Attempt(S.Remove[1,3],"!")
        \\CutScalar:string=Attempt(S.Remove[3,5],"!")
        \\CutHalf:string=Attempt(S.Remove[3,4],"!")
        \\CutOtherHalf:string=Attempt(S.Remove[4,5],"!")
        \\CutNothing:string=Attempt(S.Remove[2,2],"!")
        \\CutNothingInside:string=Attempt(S.Remove[4,4],"!")
        \\CutAll:string=Attempt(S.Remove[0,5],"!")
        \\CutBackwards:string=Attempt(S.Remove[3,1],"!")
        \\CutBeyond:string=Attempt(S.Remove[0,6],"!")
        \\CutNegative:string=Attempt(S.Remove[0-1,2],"!")
        \\LastUnit:char=Attempt(S.Last[],'?')
        \\LastButOne:char=Attempt(S.Last[1],'?')
        \\First:char=Attempt(S.Last[4],'?')
        \\Before:char=Attempt(S.Last[5],'?')
        \\LastNegative:char=Attempt(S.Last[0-1],'?')
        \\LastOfEmpty:char=Attempt(E.Last[],'?')
        \\Joined:string=Join(array{"a","b","c"},", ")
        \\JoinedOne:string=Join(array{"only"},", ")
        \\JoinedNone:string=Join(For(W:array{"a"},W=="b",W),", ")
        \\Glued:string=Concatenate(array{"ab","","cd"})
        \\Chain:string=Concatenate("ab",S,"cd")
        \\Shown:string=ToString(S)+ToString(E)
    );
    try expectString(x, "Book", "Applesy, this is a string, Applesllo!");
    try expectString(x, "Gone", "Jos");
    try expectString(x, "Wider", "Joéé");
    try expectString(x, "Same", "José");
    try expectString(x, "NoPattern", "José");
    try expectString(x, "TooLong", "José");
    try expectString(x, "Whole", "");
    try expectString(x, "OfEmpty", "");
    try expectString(x, "Overlap", "bba");
    try expectInteger(x, "WhereS", 2);
    try expectInteger(x, "WhereLead", 3);
    try expectInteger(x, "WhereTrail", 4);
    try expectInteger(x, "WhereX", -1);
    try expectInteger(x, "InEmpty", -1);
    try expectString(x, "In0", "<José");
    try expectString(x, "In3", "Jos-é");
    try expectString(x, "In4", "!");
    try expectString(x, "In5", "José>");
    try expectString(x, "In6", "!");
    try expectString(x, "InNegative", "!");
    try expectString(x, "InNothing", "José");
    try expectString(x, "IntoEmpty", "José");
    try expectString(x, "Cut", "Jé");
    try expectString(x, "CutScalar", "Jos");
    try expectString(x, "CutHalf", "!");
    try expectString(x, "CutOtherHalf", "!");
    try expectString(x, "CutNothing", "José");
    // An empty range inside a scalar removes nothing, but it is no place in the text.
    try expectString(x, "CutNothingInside", "!");
    try expectString(x, "CutAll", "");
    try expectString(x, "CutBackwards", "!");
    try expectString(x, "CutBeyond", "!");
    try expectString(x, "CutNegative", "!");
    try std.testing.expectEqual(@as(u32, 0xA9), x.get("LastUnit").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 0xC3), x.get("LastButOne").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 'J'), x.get("First").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, '?'), x.get("Before").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, '?'), x.get("LastNegative").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, '?'), x.get("LastOfEmpty").?.enumeration.index);
    try expectString(x, "Joined", "a, b, c");
    try expectString(x, "JoinedOne", "only");
    try expectString(x, "JoinedNone", "");
    try expectString(x, "Glued", "abcd");
    try expectString(x, "Chain", "abJosécd");
    try expectString(x, "Shown", "José");
    // Every string a run holds is valid UTF-8, whatever was replaced or removed.
    for (x.program.bindings) |binding| {
        const value = x.values[binding.node];
        if (value == .string) try std.testing.expect(std.unicode.utf8ValidateSlice(value.string));
    }
    // The element-wise methods are those of a `[]char`: a string does not have them.
    try expectCode(h, "A:string=\"abc\".RemoveAllElements('a')", .unknown_field);
    try expectCode(h, "A:string=Attempt(\"abc\".ReplaceElement[0,'a'],\"\")", .unknown_field);
    try expectCode(h, "A:i64=Attempt(\"abc\".Find[\"b\"],0)", .type_mismatch);
    try expectCode(h, "A:i64=Attempt(\"abc\".Find['é'],0)", .type_mismatch);
    try expectCode(h, "A:string=\"abc\".ReplaceAll('a','b')", .type_mismatch);
    try expectCode(h, "A:string=Attempt(\"abc\".Insert[0,'a'],\"\")", .type_mismatch);
}

test "math functions: the Book's examples, to the bit" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Half:float=PiFloat/2.0
        \\A1:i64=Abs(5)
        \\A2:i64=Abs(0-5)
        \\A3:float=Abs(3.14)
        \\A4:float=Abs(0.0-3.14)
        \\A5:float=Abs(NaN)
        \\A6:float=Abs(0.0*(0.0-1.0))
        \\M1:float=Max(NaN,5.0)
        \\M2:float=Min(NaN,5.0)
        \\M3:float=Max(Inf,100.0)
        \\M4:float=Min(0.0-Inf,100.0)
        \\M5:i64=Min(3,0-4)
        \\M6:i64=Max(3,0-4)
        \\M7:float=Min(2.5,1.5)
        \\M8:float=Max(2.5,1.5)
        \\C1:i64=Clamp(5,2,0-2)
        \\C2:i64=Clamp(5,0-2,2)
        \\C3:i64=Clamp(0-9,2,0-2)
        \\C4:i64=Clamp(1,0-2,2)
        \\C5:float=Clamp(5.0,0.0-2.0,2.0)
        \\C6:float=Clamp(NaN,0.0,1.0)
        \\S1:float=Sqrt(4.0)
        \\S2:float=Sqrt(0.0-1.0)
        \\S3:float=Sqrt(Inf)
        \\S4:float=Sqrt(2.0)
        \\P1:float=Pow(2.0,3.0)
        \\P2:float=Pow(4.0,0.5)
        \\P3:float=Pow(2.0,0.0-1.0)
        \\P4:float=Pow(0.0,0.0)
        \\P5:float=Pow(NaN,0.0)
        \\P6:float=Pow(1.0,NaN)
        \\P7:float=Pow(0.0-8.0,1.0/3.0)
        \\E1:float=Exp(0.0)
        \\E2:float=Exp(0.0-Inf)
        \\E3:float=Ln(1.0)
        \\E4:float=Ln(Exp(1.0))
        \\E5:float=Ln(0.0)
        \\E6:float=Ln(0.0-1.0)
        \\E7:float=Log(10.0,100.0)
        \\E8:float=Log(2.0,8.0)
        \\E9:float=Exp(1.0)
        \\T1:float=Sin(0.0)
        \\T2:float=Sin(Half)
        \\T3:float=Cos(0.0)
        \\T4:float=Cos(PiFloat)
        \\T5:float=Sin(NaN)
        \\T6:float=Sin(Inf)
        \\T7:logic=Sin(PiFloat)>0.0 and Sin(PiFloat)<0.000001
        \\T8:logic=Cos(Half)>0.0 and Cos(Half)<0.000001
        \\T9:float=ArcSin(1.0)
        \\T10:float=ArcCos(0.0-1.0)
        \\T11:float=ArcTan(1.0)
        \\T12:float=ArcTan(1.0,0.0-1.0)
        \\T13:float=ArcTan(0.0,0.0)
        \\T14:float=ArcTan(Inf,Inf)
        \\T15:float=ArcSin(2.0)
        \\T16:float=Tan(0.0)
        \\T17:float=Sin(1.0)
        \\T18:float=Cos(1.0)
        \\T19:float=Tan(1.0)
        \\H1:float=Sinh(0.0)
        \\H2:float=Cosh(0.0)
        \\H3:float=Tanh(Inf)
        \\H4:float=ArSinh(0.0)
        \\H5:float=ArCosh(1.0)
        \\H6:float=ArTanh(0.0)
        \\H7:float=ArCosh(0.5)
        \\H8:float=ArTanh(1.0)
        \\H9:float=Sinh(1.0)
        \\L1:float=Lerp(3.0,7.0,0.0)
        \\L2:float=Lerp(3.0,7.0,1.0)
        \\L3:float=Lerp(3.0,7.0,2.0)
        \\L4:float=Lerp(3.0,7.0,0.0-1.0)
        \\F1:float=Attempt((5.0).IsFinite[],0.0-1.0)
        \\F2:float=Attempt((0.0-100.0).IsFinite[],0.0-1.0)
        \\F3:float=Attempt((Inf).IsFinite[],0.0-1.0)
        \\F4:float=Attempt((0.0-Inf).IsFinite[],0.0-1.0)
        \\F5:float=Attempt((NaN).IsFinite[],0.0-1.0)
        \\F6:float=Attempt((15.16).IsFinite[],0.0-1.0)
        \\SafeDivide(X:float,Y:float)<computes><decides>:float=Block{X.IsFinite[];Y.IsFinite[];(X/Y).IsFinite[]}
        \\F7:float=Attempt(SafeDivide[10.0,4.0],0.0-1.0)
        \\F8:float=Attempt(SafeDivide[10.0,0.0],0.0-1.0)
    );
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const pi = std.math.pi;
    try expectInteger(x, "A1", 5);
    try expectInteger(x, "A2", 5);
    try expectFloat(x, "A3", 3.14);
    try expectFloat(x, "A4", 3.14);
    try expectFloat(x, "A5", nan);
    try expectFloat(x, "A6", 0.0);
    try expectFloat(x, "M1", nan);
    try expectFloat(x, "M2", nan);
    try expectFloat(x, "M3", inf);
    try expectFloat(x, "M4", -inf);
    try expectInteger(x, "M5", -4);
    try expectInteger(x, "M6", 3);
    try expectFloat(x, "M7", 1.5);
    try expectFloat(x, "M8", 2.5);
    try expectInteger(x, "C1", 2);
    try expectInteger(x, "C2", 2);
    try expectInteger(x, "C3", -2);
    try expectInteger(x, "C4", 1);
    try expectFloat(x, "C5", 2.0);
    try expectFloat(x, "C6", nan);
    try expectFloat(x, "S1", 2.0);
    try expectFloat(x, "S2", nan);
    try expectFloat(x, "S3", inf);
    try expectFloat(x, "S4", 1.4142135623730951);
    try expectFloat(x, "P1", 8.0);
    try expectFloat(x, "P2", 2.0);
    try expectFloat(x, "P3", 0.5);
    try expectFloat(x, "P4", 1.0);
    try expectFloat(x, "P5", 1.0);
    try expectFloat(x, "P6", 1.0);
    try expectFloat(x, "P7", nan);
    try expectFloat(x, "E1", 1.0);
    try expectFloat(x, "E2", 0.0);
    try expectFloat(x, "E3", 0.0);
    try expectFloat(x, "E4", 1.0);
    try expectFloat(x, "E5", -inf);
    try expectFloat(x, "E6", nan);
    try expectFloat(x, "E7", 2.0);
    try expectFloat(x, "E8", 3.0);
    // Within an ulp, as the reference implementation has it: not always the nearest float.
    try expectFloat(x, "E9", 2.7182818284590455);
    try expectFloat(x, "T1", 0.0);
    try expectFloat(x, "T2", 1.0);
    try expectFloat(x, "T3", 1.0);
    try expectFloat(x, "T4", -1.0);
    try expectFloat(x, "T5", nan);
    try expectFloat(x, "T6", nan);
    try expectLogic(x, "T7", true);
    try expectLogic(x, "T8", true);
    try expectFloat(x, "T9", pi / 2.0);
    try expectFloat(x, "T10", pi);
    try expectFloat(x, "T11", pi / 4.0);
    try expectFloat(x, "T12", 3.0 * pi / 4.0);
    try expectFloat(x, "T13", 0.0);
    try expectFloat(x, "T14", pi / 4.0);
    // Outside its domain the Book leaves `ArcSin` unspecified; here it is NaN.
    try expectFloat(x, "T15", nan);
    try expectFloat(x, "T16", 0.0);
    // Correctly rounded values of the reference implementation the kernels were copied from.
    try expectFloat(x, "T17", 0.8414709848078965);
    try expectFloat(x, "T18", 0.5403023058681398);
    try expectFloat(x, "T19", 1.5574077246549023);
    try expectFloat(x, "H1", 0.0);
    try expectFloat(x, "H2", 1.0);
    try expectFloat(x, "H3", 1.0);
    try expectFloat(x, "H4", 0.0);
    try expectFloat(x, "H5", 0.0);
    try expectFloat(x, "H6", 0.0);
    try expectFloat(x, "H7", nan);
    try expectFloat(x, "H8", inf);
    try expectFloat(x, "H9", 1.1752011936438014);
    try expectFloat(x, "L1", 3.0);
    try expectFloat(x, "L2", 7.0);
    try expectFloat(x, "L3", 11.0);
    try expectFloat(x, "L4", -1.0);
    try expectFloat(x, "F1", 5.0);
    try expectFloat(x, "F2", -100.0);
    try expectFloat(x, "F3", -1.0);
    try expectFloat(x, "F4", -1.0);
    try expectFloat(x, "F5", -1.0);
    try expectFloat(x, "F6", 15.16);
    try expectFloat(x, "F7", 2.5);
    try expectFloat(x, "F8", -1.0);
    // A result is the canonical NaN or a number: reports and equality know one NaN only.
    for (x.program.bindings) |binding| {
        const value = x.values[binding.node];
        if (value == .floating) try std.testing.expect(types.isCanonicalFloat(value.floating));
    }
}

test "the magnitude of the least i64 is a fatal overflow at the call, which no Attempt catches" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "Least:i64=0-9223372036854775807-1\nA:i64=Attempt(Abs(Least),7)";
    const result = try h.run(try h.compile(source), 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
    try std.testing.expectEqualStrings("Abs", result.failed.span.text(source));
    // Inside a function, a loop and a failed alternative alike.
    for ([_][]const u8{
        "F(V:i64)<computes>:i64=Abs(V)\nA:i64=Attempt(F(0-9223372036854775807-1),7)",
        "Step(S:i64)<computes>:i64=Abs(S)-9223372036854775807-2\nA:i64=Iterate(Step,2,1)",
        "F(V:i64)<computes><decides>:i64=Block{Fail[\"no\"];V}\nA:i64=Attempt(F[1],Abs(0-9223372036854775807-1))",
    }) |fatal| {
        const stopped = try h.run(try h.compile(fatal), 4096);
        try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, stopped.failed.code);
        try std.testing.expectEqualStrings("Abs", stopped.failed.span.text(fatal));
    }
    const x = try h.execute("Most:i64=9223372036854775807\nA:i64=Abs(0-Most)\nB:i64=Min(0-Most-1,Most)\nC:i64=Max(0-Most-1,Most)\nD:i64=Clamp(0,Most,0-Most-1)\nE:i64=Clamp(Most,0-Most-1,0-Most-1)");
    try expectInteger(x, "A", std.math.maxInt(i64));
    try expectInteger(x, "B", std.math.minInt(i64));
    try expectInteger(x, "C", std.math.maxInt(i64));
    try expectInteger(x, "D", 0);
    try expectInteger(x, "E", std.math.minInt(i64));
}

test "ConcatenateMaps: the second map wins on a shared key and keys keep their first position" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Pt:=struct{X:i64,Y:i64}
        \\One:map(i64,string)=map{1=>"one",2=>"two"}
        \\Two:map(i64,string)=map{3=>"three",4=>"four"}
        \\None:map(i64,string)=map{}
        \\Combined:map(i64,string)=ConcatenateMaps(One,Two)
        \\All:map(i64,string)=ConcatenateMaps(ConcatenateMaps(One,Two),map{5=>"five"})
        \\Result:map(i64,string)=ConcatenateMaps(map{1=>"original",2=>"base"},map{2=>"updated",3=>"new"})
        \\Left:map(i64,string)=ConcatenateMaps(One,None)
        \\Right:map(i64,string)=ConcatenateMaps(None,One)
        \\Neither:map(i64,string)=ConcatenateMaps(None,None)
        \\Self:map(i64,string)=ConcatenateMaps(One,One)
        \\SameCombined:logic=Combined==map{1=>"one",2=>"two",3=>"three",4=>"four"}
        \\SameResult:logic=Result==map{1=>"original",2=>"updated",3=>"new"}
        \\Reordered:logic=ConcatenateMaps(Two,One)==Combined
        \\Looked:string=Attempt(Result[2],"?")
        \\ByPoint:map(Pt,[]i64)=ConcatenateMaps(map{Pt{X:=1,Y:=2}=>array{1}},map{Pt{X:=1,Y:=2}=>array{2,3},Pt{X:=0,Y:=0}=>array{}})
        \\AtPoint:i64=Attempt(ByPoint[Pt{X:=1,Y:=2}],array{}).Length
        \\ByText:map(string,float)=ConcatenateMaps(map{"a"=>1.0,"b"=>2.0},map{"b"+""=>NaN})
        \\Sizes:i64=Combined.Length*1000+All.Length*100+Result.Length*10+ByPoint.Length
        \\Keys:[]i64=For(K->V:Result,K)
    );
    try expectLogic(x, "SameCombined", true);
    try expectLogic(x, "SameResult", true);
    // Map equality is ordered (RFC-0065): the first map's keys come first.
    try expectLogic(x, "Reordered", false);
    try expectString(x, "Looked", "updated");
    try expectInteger(x, "AtPoint", 2);
    try expectInteger(x, "Sizes", 4000 + 500 + 30 + 2);
    try expectIntegers(x, "Keys", &.{ 1, 2, 3 });
    for ([_][]const u8{ "Left", "Right", "Self" }) |name| {
        const range = x.get(name).?.aggregate.elements;
        try std.testing.expectEqual(@as(u32, 4), range.end - range.start);
        try std.testing.expectEqual(@as(i64, 1), x.aggregate_values[range.start].integer);
        try std.testing.expectEqualStrings("two", x.aggregate_values[range.start + 3].string);
    }
    const neither = x.get("Neither").?.aggregate.elements;
    try std.testing.expectEqual(neither.start, neither.end);
    const by_text = x.get("ByText").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 4), by_text.end - by_text.start);
    try std.testing.expect(std.math.isNan(x.aggregate_values[by_text.start + 3].floating));
    try expectCode(h, "A:map(i64,i64)=ConcatenateMaps(map{1=>2},map{\"a\"=>2})", .type_mismatch);
    try expectCode(h, "A:map(i64,i64)=ConcatenateMaps(map{1=>2},array{1})", .type_mismatch);
    try expectCode(h, "A:[]i64=ConcatenateMaps(array{1},array{1})", .type_mismatch);
    try expectCode(h, "A:map(i64,i64)=ConcatenateMaps(map{1=>2})", .argument_count);
    try expectCode(h, "A:map(i64,i64)=ConcatenateMaps(map{1=>2},map{1=>2},map{1=>2})", .argument_count);
}

test "diagnostics: argument types and counts, brackets, failure contexts and receivers" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        // A failable form takes brackets and a failure context; a total one takes parentheses.
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Xs.Find[1]", .code = .failure_context_required },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Find(1),0)", .code = .expected_call },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.RemoveAllElements[1],Xs)", .code = .expected_call },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Xs.Slice[0]", .code = .failure_context_required },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Xs.Last[]", .code = .failure_context_required },
        .{ .source = "A:float=(1.0).IsFinite[]", .code = .failure_context_required },
        .{ .source = "A:float=Attempt((1.0).IsFinite(),0.0)", .code = .expected_call },
        .{ .source = "A:float=Attempt(Sqrt[4.0],0.0)", .code = .unknown_name },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Xs.Find", .code = .expected_call },
        // Counts.
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Find[],0)", .code = .expected_expression },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Find[1,2],0)", .code = .argument_count },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Remove[1],Xs)", .code = .argument_count },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Slice[0,1,2],Xs)", .code = .argument_count },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Last[0,1],0)", .code = .argument_count },
        .{ .source = "A:float=Sqrt(1.0,2.0)", .code = .argument_count },
        .{ .source = "A:float=Pow(1.0)", .code = .argument_count },
        .{ .source = "A:float=ArcTan(1.0,2.0,3.0)", .code = .argument_count },
        .{ .source = "A:float=Lerp(1.0,2.0)", .code = .argument_count },
        .{ .source = "A:i64=Clamp(1,2)", .code = .argument_count },
        .{ .source = "A:float=Attempt((1.0).IsFinite[2.0],0.0)", .code = .argument_count },
        // RFC-0080 gives these three a meaning where their place names the type; without one
        // they are what they were.
        .{ .source = "A:=Concatenate()", .code = .array_type_required },
        // An empty literal takes its type from its context, and a first argument has none.
        .{ .source = "A:string=Join(array{1},\",\")", .code = .type_mismatch },
        .{ .source = "A:=Concatenate(array{},array{1})", .code = .array_type_required },
        .{ .source = "A:float=Sqrt()", .code = .expected_expression },
        // Types. There are no implicit conversions between `i64` and `float`.
        .{ .source = "A:float=Sqrt(4)", .code = .type_mismatch },
        .{ .source = "A:float=Pow(2.0,3)", .code = .type_mismatch },
        .{ .source = "A:i64=Min(1,2.0)", .code = .type_mismatch },
        .{ .source = "A:float=Max(1.0,2)", .code = .type_mismatch },
        .{ .source = "A:i64=Clamp(1,2,3.0)", .code = .type_mismatch },
        .{ .source = "A:string=Abs(\"a\")", .code = .type_mismatch },
        .{ .source = "A:logic=Min(true,false)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Find[\"a\"],0)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Xs.ReplaceAllElements(1,2.0)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Xs.ReplaceAll(1,Xs)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Xs.ReplaceAll(Xs,array{\"a\"})", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Insert[0,1],Xs)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Insert[Xs,Xs],Xs)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Slice[1.0],Xs)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Remove[0,true],Xs)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Last[\"a\"],0)", .code = .type_mismatch },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.ReplaceElement[0,\"a\"],Xs)", .code = .type_mismatch },
        .{ .source = "A:[]i64=Concatenate(array{1,2})", .code = .type_mismatch },
        .{ .source = "A:[]i64=Concatenate(array{1},array{\"a\"})", .code = .type_mismatch },
        .{ .source = "A:i64=Concatenate(1,2)", .code = .type_mismatch },
        .{ .source = "A:string=Join(array{1},\",\")", .code = .type_mismatch },
        .{ .source = "A:string=Join(array{\"a\"},1)", .code = .type_mismatch },
        .{ .source = "A:string=Join(\"a\",\",\")", .code = .type_mismatch },
        // A method belongs to its receiver's kind; a function is no method and the reverse.
        .{ .source = "A:i64=Attempt(5.Find[1],0)", .code = .type_mismatch },
        .{ .source = "A:float=Attempt(5.IsFinite[],0.0)", .code = .type_mismatch },
        .{ .source = "M:map(i64,i64)=map{1=>2}\nA:i64=Attempt(M.Find[1],0)", .code = .unknown_field },
        .{ .source = "Xs:[]i64=array{1}\nA:logic=Attempt(Block{Xs.IsFinite[];true},false)", .code = .unknown_field },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=Xs.Concatenate(Xs)", .code = .unknown_field },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Find[Xs,1],0)", .code = .unknown_name },
        .{ .source = "A:float=Attempt(IsFinite[1.0],0.0)", .code = .unknown_name },
        .{ .source = "A:float=(4.0).Sqrt()", .code = .type_mismatch },
        // The names are functions and methods, not values.
        .{ .source = "F:function(tuple(float),float)=Sqrt", .code = .unknown_name },
        .{ .source = "A:float=Lib.Sqrt(4.0)", .code = .unknown_name },
    };
    for (cases) |case| try expectCode(h, case.source, case.code);
    // A diagnostic points at the argument that is wrong, or at the name of the form.
    const wrong = "Xs:[]i64=array{1}\nA:[]i64=Attempt(Xs.Insert[0,7],Xs)";
    try std.testing.expectEqualStrings("7", h.front.compile(wrong).failed.span.text(wrong));
    const bare = "Xs:[]i64=array{1}\nA:i64=Xs.Find[1]";
    try std.testing.expectEqualStrings("Find", h.front.compile(bare).failed.span.text(bare));
}

test "none of the names is reserved: whatever a program declares by one is what it means" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute(
        \\Sqrt(X:float)<computes>:float=X+1.0
        \\Abs:=native{"std.sum"}
        \\var Min:i64=40
        \\Max:=struct{Top:i64}
        \\Lerp:=i64
        \\Clamp[T:type](X:T)<computes>:T{X}
        \\PiFloat:float=3.0
        \\Apply(Pow:function(tuple(i64,i64),i64),Join:i64)<computes>:i64=Pow(Join,2)
        \\Add(Left:i64,Right:i64)<computes>:i64=Left+Right
        \\Local()<computes>:i64=Block{Exp:=Add;Ln:=5;Exp(Ln,1)}
        \\A:float=Sqrt(4.0)
        \\B:i64=Abs(array{1,2,3})
        \\C:i64=Min+2
        \\D:Max=Max{Top:=7}
        \\E:Lerp=9
        \\F:i64=Clamp[i64](11)
        \\G:float=PiFloat
        \\H:i64=Apply(Add,3)
        \\I:i64=Local()
        \\J:float=Cos(0.0)
    );
    try expectFloat(x, "A", 5.0);
    try expectInteger(x, "B", 6);
    try expectInteger(x, "C", 42);
    try expectInteger(x, "E", 9);
    try expectInteger(x, "F", 11);
    try expectFloat(x, "G", 3.0);
    try expectInteger(x, "H", 5);
    try expectInteger(x, "I", 6);
    try expectFloat(x, "J", 1.0);
    // A declaration of the name is the only thing it means: it is not also the standard one.
    try expectCode(h, "Sqrt(X:i64)<computes>:i64=X\nA:float=Sqrt(4.0)", .type_mismatch);
    try expectCode(h, "var Min:i64=40\nA:i64=Min(1,2)", .not_callable);
    // The program's generic `Clamp` is called, its type argument read off the arguments
    // (RFC-0091), and it takes one.
    try expectCode(h, "Clamp[T:type](X:T)<computes>:T{X}\nA:i64=Clamp(5,1,2)", .argument_count);
    try expectCode(h, "Lerp:=i64\nA:float=Lerp(1.0,2.0,0.5)", .unknown_name);
    // An extension method the program declares for a type is what the name means for values
    // of that type, as a member is: the standard method is what it means when nothing else has it.
    x = try h.execute(
        \\(Xs:[]i64).Find(V:i64)<computes>:i64=42
        \\(S:string).Last()<computes>:string="tail"
        \\Bag:=class{
        \\    Slice(A:i64)<computes>:i64=A+100
        \\    Remove:i64=3
        \\}
        \\Xs:[]i64=array{1,2,3}
        \\A:i64=Xs.Find(2)
        \\B:string="abc".Last()
        \\C:i64=Bag{}.Slice(1)
        \\D:[]i64=Attempt(Xs.Slice[1],array{})
        \\E:i64=Attempt(Xs.Last[],0)
    );
    try expectInteger(x, "A", 42);
    try expectString(x, "B", "tail");
    try expectInteger(x, "C", 101);
    try expectIntegers(x, "D", &.{ 2, 3 });
    try expectInteger(x, "E", 3);
    try expectCode(h, "(Xs:[]i64).Find(V:i64)<computes>:i64=42\nXs:[]i64=array{1}\nA:i64=Attempt(Xs.Find[1],0)", .expected_call);
    // One declared for another type leaves this receiver its standard method, and takes its own.
    x = try h.execute("(S:string).Find(V:i64)<computes>:i64=42\nAnimal:=class{}\nDog:=class(Animal){}\n(Pet:Animal).Last()<computes>:i64=7\nXs:[]i64=array{5,6}\nA:i64=Attempt(Xs.Find[6],0-1)\nB:i64=\"ab\".Find(1)\nC:i64=Dog{}.Last()\nD:i64=Attempt(Xs.Last[],0)");
    try expectInteger(x, "A", 1);
    try expectInteger(x, "B", 42);
    try expectInteger(x, "C", 7);
    try expectInteger(x, "D", 6);
    // An extension method leaves the bare name what it was, as it leaves it to the intrinsics.
    x = try h.execute("(V:float).Sqrt()<computes>:float=V+1.0\nA:float=Sqrt(4.0)\nB:float=(4.0).Sqrt()");
    try expectFloat(x, "A", 2.0);
    try expectFloat(x, "B", 5.0);
    // Inside a class with a member of the name the bare name is not the function: a member
    // is reached through `Self`, and the name stays unknown rather than meaning something else.
    try expectCode(h, "Shape:=class{\n    Abs:i64=3\n    Size()<transacts>:i64=Abs(0-2)\n}", .unknown_name);
    try expectCode(h, "Shape:=class{\n    PiFloat:float=3.0\n    Size()<transacts>:float=PiFloat\n}", .unknown_name);
    x = try h.execute("Shape:=class{\n    Abs:i64=3\n    Size()<transacts>:i64=Self.Abs+Max(1,2)\n}\nA:i64=Shape{}.Size()");
    try expectInteger(x, "A", 5);
}

test "names a used module exports win, and each module of a bundle has the standard functions" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const lib = "Sqrt<public>(X:float)<computes>:float=X+1.0\nPiFloat<public>:float=3.0\n(Xs:[]i64).Find<public>(V:i64)<computes>:i64=42\nHidden(X:float)<computes>:float=Cos(X)\nRoot<public>(X:float)<computes>:float=Hidden(X)+Max(1.0,2.0)\nWhere<public>(Xs:[]i64,V:i64)<computes>:i64=Attempt(Xs.Slice[1].RemoveAllElements(V).Last[],0-1)";
    const using = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:float=Sqrt(4.0)\nB<public>:float=PiFloat\nC<public>:i64=array{1,2}.Find(2)\nD<public>:float=Root(0.0)\nE<public>:float=Cos(0.0)\nF<public>:i64=Where(array{5,6,7},7)" },
        .{ .path = "lib.forb", .source = lib },
    };
    var bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &using });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    var x = (try h.run(bundled.ok, 20_000)).ok;
    try expectFloat(x, "A", 5.0);
    try expectFloat(x, "B", 3.0);
    try expectInteger(x, "C", 42);
    try expectFloat(x, "D", 3.0);
    try expectFloat(x, "E", 1.0);
    try expectInteger(x, "F", 6);
    // Without `using`, the module's names are reached by qualification only, and the bare
    // names are the standard ones.
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:float=Sqrt(4.0)\nB<public>:float=L.Sqrt(4.0)\nC<public>:i64=Attempt(array{1,2}.Find[2],0-1)\nD<public>:logic=PiFloat>3.14" },
        .{ .path = "lib.forb", .source = lib },
    };
    bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &plain });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    x = (try h.run(bundled.ok, 20_000)).ok;
    try expectFloat(x, "A", 2.0);
    try expectFloat(x, "B", 5.0);
    try expectInteger(x, "C", 1);
    try expectLogic(x, "D", true);
}

test "standard forms inside functions, generics, loops and failure contexts" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Where[T:comparable](Items:[]T,Wanted:T)<computes><decides>:i64{Items.Find[Wanted]}
        \\Without2[T:comparable](Items:[]T,Wanted:T)<computes>:[]T{Items.RemoveAllElements(Wanted)}
        \\Rest[T:type](Items:[]T)<computes>:[]T{Attempt(Items.Slice[1],Items)}
        \\A:i64=Attempt(Where[i64][array{4,5,6},6],0-1)
        \\B:i64=Attempt(Where[string][array{"a","b"},"b"],0-1)
        \\C:i64=Attempt(Where[string][array{"a","b"},"c"],0-1)
        \\D:[]i64=Without2[i64](array{1,2,1},1)
        \\E:[]i64=Rest[i64](array{1,2,3})
        \\Hyp(X:float,Y:float)<computes>:float=Sqrt(X*X+Y*Y)
        \\F:float=Hyp(3.0,4.0)
        \\Sum(Items:[]i64)<computes>:i64=If(Items.Length==0,0,Attempt(Items.Last[]+Sum(Attempt(Items.Slice[0,Items.Length-1],array{})),0))
        \\G:i64=Sum(array{1,2,3,4})
        \\Halves:[]float=For(V:array{1.0,4.0,9.0},Sqrt(V))
        \\H:float=Attempt(Halves.Last[],0.0)
        \\Evens:[]i64=For(V:array{1,2,3,4},Place:=array{2,4}.Find[V],V*10+Place)
        \\var Cell:[]i64=array{1,2,3}
        \\Drop(V:i64)<transacts><decides>:i64=Block{set Cell=Cell.RemoveFirstElement[V];Cell.Find[99]}
        \\I:i64=Attempt(Drop[2],0-1)
        \\J:[]i64=Cell
        \\Keep(V:i64)<transacts><decides>:i64=Block{set Cell=Cell.RemoveFirstElement[V];Cell.Length}
        \\K:i64=Attempt(Keep[2],0-1)
        \\L:[]i64=Cell
        \\Chain:i64=Attempt(array{3,1,2}.Insert[0,array{9}].Remove[1,2].ReplaceElement[0,7].Find[2],0-1)
        \\Guess:logic=logic{array{1,2}.Find[3]}
        \\Maybe:option(i64)=option{array{1,2}.Find[2]}
        \\Default(Items:[]i64,At:i64=Abs(0-1))<computes>:i64=Attempt(Items.Last[At],0)
        \\M:i64=Default(array{5,6,7})
        \\Text(S:string)<computes>:string=Attempt(S.ReplaceAll("a","b").Insert[0,"<"],S)
        \\N:string=Text("banana")
        \\Step(S:tuple(i64,[]i64))<computes>:tuple(i64,[]i64)=tuple{S(0)+1,Attempt(S(1).Insert[0,array{S(0)}],S(1))}
        \\O:[]i64=Iterate(Step,5,tuple{0,array{}})(1)
    );
    try expectInteger(x, "A", 2);
    try expectInteger(x, "B", 1);
    try expectInteger(x, "C", -1);
    try expectIntegers(x, "D", &.{2});
    try expectIntegers(x, "E", &.{ 2, 3 });
    try expectFloat(x, "F", 5.0);
    try expectInteger(x, "G", 10);
    try expectFloat(x, "H", 3.0);
    try expectIntegers(x, "Evens", &.{ 20, 41 });
    // A failure after a standard form undoes the write that used it.
    try expectInteger(x, "I", -1);
    try expectIntegers(x, "J", &.{ 1, 2, 3 });
    try expectInteger(x, "K", 2);
    try expectIntegers(x, "L", &.{ 1, 3 });
    try expectInteger(x, "Chain", 2);
    try expectLogic(x, "Guess", false);
    try expectInteger(x, "M", 6);
    try expectString(x, "N", "<bbnbnb");
    try expectIntegers(x, "O", &.{ 4, 3, 2, 1, 0 });
    const maybe = x.get("Maybe").?.aggregate.elements;
    try std.testing.expectEqual(@as(i64, 1), x.aggregate_values[maybe.start].integer);
    // A generic that searches needs a comparable parameter, checked when it is specialised.
    try expectCode(h, "Where[T:type](Items:[]T,Wanted:T)<computes><decides>:i64{Items.Find[Wanted]}\nT1(V:i64)<computes>:i64=V\nA:i64=Attempt(Where[function(tuple(i64),i64)][array{T1},T1],0)", .not_comparable);
}

test "both machines charge the standard forms alike at every budget, and costs grow with the work" {
    const h = try harness.create();
    defer scratch.release(h);
    const sources = [_][]const u8{
        "Xs:[]i64=array{1,2,3,4,5,6,7,8}\nA:i64=Attempt(Xs.Find[8],0)\nB:[]i64=Xs.RemoveAllElements(3)\nC:[]i64=Attempt(Xs.Slice[2,6],Xs)\nD:[]i64=Xs.ReplaceAll(array{4,5},array{0})",
        "S:string=\"abcabcabc\"\nA:string=S.ReplaceAll(\"bc\",\"x\")\nB:i64=Attempt(S.Find['c'],0)\nC:string=Attempt(S.Insert[3,\"-\"],S)\nD:string=Join(array{S,A},\"+\")",
        "M:map(i64,i64)=ConcatenateMaps(map{1=>1,2=>2,3=>3},map{3=>4,5=>6})\nF:float=Pow(Sin(1.0)+Exp(0.5),Lerp(1.0,2.0,0.5))\nG:[]i64=Concatenate(array{array{1},array{2,3}})",
        "Rows:[][]string=array{array{\"ab\",\"cd\"},array{\"ef\"}}\nA:i64=Attempt(Rows.Find[array{\"e\"+\"f\"}],0-1)\nB:[]string=Concatenate(Rows)\nC:i64=Abs(0-3)+Min(1,2)",
    };
    for (sources) |source| {
        const p = try h.compile(source);
        const least = try leastFuel(h, p, 4096);
        try std.testing.expect(least > 0);
        // Every budget below the least stops both machines the same way; the harness compares.
        var budget: u64 = 0;
        while (budget < least) : (budget += 1) {
            const result = try h.run(p, budget);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
        }
        _ = try h.run(p, least);
    }
    // A search that visits twice as many elements costs twice as much more.
    var costs: [3]u64 = undefined;
    for ([_]usize{ 16, 32, 64 }, &costs) |count, *cost| {
        var text: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&text);
        try writer.writeAll("Xs:[]i64=array{");
        for (0..count) |index| try writer.print("{s}{d}", .{ if (index == 0) "" else ",", index });
        try writer.print("}}\nBase:i64=Xs.Length\nA:i64=Attempt(Xs.Find[{d}],0-1)", .{count - 1});
        const with = try leastFuel(h, try h.compile(writer.buffered()), 8192);
        // The same program without the search: the difference is the search alone.
        const cut = std.mem.lastIndexOf(u8, writer.buffered(), "\nA:").?;
        const without = try leastFuel(h, try h.compile(writer.buffered()[0..cut]), 8192);
        cost.* = with - without;
    }
    try std.testing.expectEqual(costs[1] - costs[0], (costs[2] - costs[1]) / 2);
    try std.testing.expect(costs[1] > costs[0] and costs[1] - costs[0] <= 16 * 4);
}

test "results that do not fit stop both machines with the pool's limit, and Attempt does not catch it" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // Doubling an array by inserting it into itself fills the member pool.
    const members = "Grow(S:[]i64)<computes>:[]i64=Attempt(S.Insert[0,S],array{})\nA:i64=Attempt(Iterate(Grow,30,array{1,2,3,4}).Length,0-1)";
    var result = try h.run(try h.compile(members), 10_000_000);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, result.failed.code);
    try std.testing.expectEqualStrings("Insert", result.failed.span.text(members));
    const rows = "Grow(S:[]i64)<computes>:[]i64=Concatenate(array{S,S,S})\nA:i64=Attempt(Iterate(Grow,30,array{1,2,3,4}).Length,0-1)";
    result = try h.run(try h.compile(rows), 10_000_000);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, result.failed.code);
    const maps = "Grow(S:[]i64)<computes>:[]i64=S.ReplaceAll(array{1},array{1,1,1})\nA:i64=Attempt(Iterate(Grow,30,array{1}).Length,0-1)";
    result = try h.run(try h.compile(maps), 10_000_000);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, result.failed.code);
    // And a replacement that outgrows the string pool.
    const text = "Grow(S:string)<computes>:string=S.ReplaceAll(\"a\",\"aaaa\")\nA:i64=Attempt(Iterate(Grow,30,\"a\").Length,0-1)";
    result = try h.run(try h.compile(text), 10_000_000);
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, result.failed.code);
    try std.testing.expectEqualStrings("ReplaceAll", result.failed.span.text(text));
}

test "forged calls of the generic kernels are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Twice(V:i64)<computes>:i64=V*2
        \\Xs:[]i64=array{1,2,3}
        \\Ws:[]string=array{"a"}
        \\Fs:[]function(tuple(i64),i64)=array{Twice}
        \\F:function(tuple(i64),i64)=Twice
        \\T:string="x"
        \\Big:i64=99
        \\N:map(string,i64)=map{"a"=>1}
        \\M:map(i64,i64)=map{1=>2}
        \\Rows:[][]i64=array{Xs,Xs}
        \\I:i64=Attempt(Xs.Find[2],0-1)
        \\S:[]i64=Attempt(Xs.Slice[0,2],array{})
        \\R:[]i64=Xs.RemoveAllElements(2)
        \\P:[]i64=Xs.ReplaceAll(Xs,Xs)
        \\C:[]i64=Concatenate(Rows)
        \\Q:map(i64,i64)=ConcatenateMaps(M,M)
        \\G:[]function(tuple(i64),i64)=Attempt(Fs.Slice[0,1],Fs)
    );
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 10_000);
    const xs = try bindingNode(p, "Xs");
    const ws = try bindingNode(p, "Ws");
    const fs = try bindingNode(p, "Fs");
    const f = try bindingNode(p, "F");
    const t = try bindingNode(p, "T");
    const big = try bindingNode(p, "Big");
    const n = try bindingNode(p, "N");
    const m = try bindingNode(p, "M");
    const rows = try bindingNode(p, "Rows");
    const find = try nativeNode(p, "std.array_find");
    const slice = try nativeNode(p, "std.array_slice");
    const remove_all = try nativeNode(p, "std.array_remove_all");
    const replace_all = try nativeNode(p, "std.array_replace_all");
    const concatenate = try nativeNode(p, "std.array_concatenate");
    const maps = try nativeNode(p, "std.map_concatenate");
    const Forgery = struct {
        fn reject(harness_: *harness.Harness, program: types.Program, all: []types.Node, original: []const types.Node, index: usize, changed: types.Node) !void {
            all[index] = changed;
            try harness.invalid(harness_, program);
            all[index] = original[index];
        }
        fn operand(node: types.Node, position: usize, value: u32) types.Node {
            var changed = node;
            changed.kind.native_call.args[position] = value;
            return changed;
        }
        fn typed(node: types.Node, value_type: types.Type) types.Node {
            var changed = node;
            changed.value_type = value_type;
            return changed;
        }
    };
    // The type variable is one type: an element of another type, an array of another type.
    try Forgery.reject(h, forged, nodes, p.nodes, find, Forgery.operand(p.nodes[find], 1, t));
    try Forgery.reject(h, forged, nodes, p.nodes, find, Forgery.operand(p.nodes[find], 0, ws));
    try Forgery.reject(h, forged, nodes, p.nodes, find, Forgery.operand(p.nodes[find], 0, big));
    try Forgery.reject(h, forged, nodes, p.nodes, remove_all, Forgery.operand(p.nodes[remove_all], 1, xs));
    try Forgery.reject(h, forged, nodes, p.nodes, replace_all, Forgery.operand(p.nodes[replace_all], 2, ws));
    try Forgery.reject(h, forged, nodes, p.nodes, replace_all, Forgery.operand(p.nodes[replace_all], 1, big));
    // A search over functions: consistent types, but no equality to search with.
    var search = Forgery.operand(p.nodes[find], 0, fs);
    search.kind.native_call.args[1] = f;
    try Forgery.reject(h, forged, nodes, p.nodes, find, search);
    var removal = Forgery.operand(p.nodes[remove_all], 0, fs);
    removal.kind.native_call.args[1] = f;
    removal.value_type = p.nodes[fs].value_type;
    try Forgery.reject(h, forged, nodes, p.nodes, remove_all, removal);
    // A result of another type than the array that was given.
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.typed(p.nodes[slice], p.nodes[ws].value_type));
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.typed(p.nodes[slice], .i64));
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.typed(p.nodes[slice], p.nodes[m].value_type));
    try Forgery.reject(h, forged, nodes, p.nodes, find, Forgery.typed(p.nodes[find], .i64));
    try Forgery.reject(h, forged, nodes, p.nodes, find, Forgery.typed(p.nodes[find], p.nodes[xs].value_type));
    // Positions that are no integers, and an operand that does not exist.
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.operand(p.nodes[slice], 1, t));
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.operand(p.nodes[slice], 2, xs));
    try Forgery.reject(h, forged, nodes, p.nodes, slice, Forgery.operand(p.nodes[slice], 0, @intCast(nodes.len)));
    // Rows that are no arrays of arrays, and a result that is the rows' type.
    try Forgery.reject(h, forged, nodes, p.nodes, concatenate, Forgery.operand(p.nodes[concatenate], 0, xs));
    try Forgery.reject(h, forged, nodes, p.nodes, concatenate, Forgery.operand(p.nodes[concatenate], 0, m));
    try Forgery.reject(h, forged, nodes, p.nodes, concatenate, Forgery.typed(p.nodes[concatenate], p.nodes[rows].value_type));
    try Forgery.reject(h, forged, nodes, p.nodes, concatenate, Forgery.typed(p.nodes[concatenate], p.nodes[ws].value_type));
    // Maps of two types, a map that is none, and a result of another map type.
    try Forgery.reject(h, forged, nodes, p.nodes, maps, Forgery.operand(p.nodes[maps], 1, n));
    try Forgery.reject(h, forged, nodes, p.nodes, maps, Forgery.operand(p.nodes[maps], 0, xs));
    try Forgery.reject(h, forged, nodes, p.nodes, maps, Forgery.typed(p.nodes[maps], p.nodes[n].value_type));
    try Forgery.reject(h, forged, nodes, p.nodes, maps, Forgery.typed(p.nodes[maps], p.nodes[xs].value_type));
    // A call with an argument too few or too many, and one of another kernel's shape.
    var short = p.nodes[slice];
    short.kind.native_call.count = 2;
    try Forgery.reject(h, forged, nodes, p.nodes, slice, short);
    var long = p.nodes[find];
    long.kind.native_call.count = 3;
    long.kind.native_call.args[2] = big;
    try Forgery.reject(h, forged, nodes, p.nodes, find, long);
    var other = p.nodes[find];
    other.kind.native_call.native = p.nodes[slice].kind.native_call.native;
    try Forgery.reject(h, forged, nodes, p.nodes, find, other);
    var none = p.nodes[find];
    none.kind.native_call.native = @intCast(p.natives.len);
    try Forgery.reject(h, forged, nodes, p.nodes, find, none);
    _ = try h.run(forged, 10_000);
    // A range the guard did not see is admitted, as its types are right, and is then a fatal
    // error of the kernel in both machines: never a read outside the array.
    nodes[slice] = Forgery.operand(p.nodes[slice], 2, big);
    const fatal = try h.run(forged, 10_000);
    try std.testing.expectEqual(types.Diagnostic.Code.native_failed, fatal.failed.code);
    nodes[slice] = p.nodes[slice];
    // The moving kernels take functions; that forgery is only a change of types and runs.
    var moved = Forgery.operand(p.nodes[slice], 0, fs);
    moved.value_type = p.nodes[fs].value_type;
    nodes[slice] = moved;
    _ = try h.run(forged, 10_000);
}

test "a generic native is not bound by name, and a host table without the kernels has no such forms" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectCode(h, "Find:=native{\"std.array_find\"}", .unsupported_type);
    try expectCode(h, "Cat:=native{\"std.map_concatenate\"}", .unsupported_type);
    // The concrete kernels are ordinary natives of the standard table.
    const x = try h.execute("Power:=native{\"std.pow\"}\nReplace:=native{\"std.string_replace_all\"}\nA:float=Power(2.0,10.0)\nB:string=Replace(\"aXa\",\"X\",\"-\")");
    try expectFloat(x, "A", 1024.0);
    try expectString(x, "B", "a-a");
    const native = @import("native.zig");
    const Host = struct {
        fn pow(ctx: *native.Context, x_: i64) i64 {
            _ = ctx;
            return x_;
        }
    };
    // A host that replaced the table: the forms that need a kernel it lacks, or that it
    // registered with another signature, are not available; those built from existing
    // operations still are.
    const custom = [_]native.Entry{native.entry("std.pow", Host.pow, .{})};
    h.front.natives = &custom;
    defer h.front.natives = &@import("native_std.zig").table;
    try expectCode(h, "A:float=Sqrt(4.0)", .unknown_native);
    try expectCode(h, "A:float=Pow(2.0,3.0)", .unknown_native);
    try expectCode(h, "A:i64=Attempt(array{1}.Find[1],0)", .unknown_native);
    const y = try h.execute("A:i64=Attempt(array{1,2}.Last[],0)\nB:[]i64=Concatenate(array{1},array{2})\nC:string=Attempt(\"ab\".Insert[1,\"-\"],\"\")\nD:float=PiFloat");
    try expectInteger(y, "A", 2);
    try expectIntegers(y, "B", &.{ 1, 2 });
    try expectString(y, "C", "a-b");
}

// The oracle: plain Zig models of every array, string and map form, run against programs
// generated from a seed. A model works on the values; nothing in it knows of pools or nodes.

const Model = struct {
    fn find(items: []const i64, wanted: i64) ?usize {
        return std.mem.indexOfScalar(i64, items, wanted);
    }
    fn inRange(length: usize, start: i64, end: i64) bool {
        return start >= 0 and start <= end and end <= @as(i64, @intCast(length));
    }
};

const Oracle = struct {
    random: std.Random,
    source: std.Io.Writer,
    expected: [48]Expectation = undefined,
    count: usize = 0,
    arena: std.mem.Allocator,

    const Expectation = union(enum) { integers: []const i64, integer: i64, text: []const u8 };
    const sentinel: i64 = -77;

    fn literal(self: *Oracle, values: []const i64) !void {
        try self.source.writeAll("array{");
        for (values, 0..) |item, index| try self.source.print("{s}{d}", .{ if (index == 0) "" else ",", item });
        try self.source.writeAll("}");
    }
    fn someItems(self: *Oracle, most: usize) ![]i64 {
        const list = try self.arena.alloc(i64, self.random.uintAtMost(usize, most));
        for (list) |*item| item.* = self.random.intRangeAtMost(i64, 0, 3);
        return list;
    }
    /// A position around the array: mostly inside, sometimes just outside, rarely far away.
    fn position(self: *Oracle, length: usize) i64 {
        return switch (self.random.uintLessThan(u8, 10)) {
            0 => -1,
            1 => @as(i64, @intCast(length)) + 1,
            2 => if (self.random.boolean()) std.math.maxInt(i64) else std.math.minInt(i64),
            else => self.random.intRangeAtMost(i64, 0, @intCast(length)),
        };
    }
    fn expect(self: *Oracle, expectation: Expectation) void {
        self.expected[self.count] = expectation;
        self.count += 1;
    }
    /// `V<n>:[]i64=<call>` with the array `subject` named `Xs` in the call.
    fn bindArray(self: *Oracle, subject: []const i64, comptime call: []const u8, arguments: anytype, result: ?[]const i64) !void {
        try self.source.print("V{d}:[]i64=Block{{Xs:[]i64=", .{self.count});
        try self.literal(subject);
        try self.source.writeAll(";");
        try self.source.print(call, arguments);
        try self.source.writeAll("}\n");
        self.expect(.{ .integers = result orelse &.{sentinel} });
    }
    fn concat(self: *Oracle, parts: []const []const i64) ![]const i64 {
        return std.mem.concat(self.arena, i64, parts);
    }

    fn arrayCase(self: *Oracle) !void {
        const xs = try self.someItems(8);
        const wanted = self.random.intRangeAtMost(i64, 0, 3);
        const with = self.random.intRangeAtMost(i64, 0, 3);
        const start = self.position(xs.len);
        const end = self.position(xs.len);
        const valid = Model.inRange(xs.len, start, end);
        const lower: usize = if (valid) @intCast(start) else 0;
        const upper: usize = if (valid) @intCast(end) else 0;
        switch (self.random.uintLessThan(u8, 12)) {
            0 => {
                try self.source.print("V{d}:i64=Block{{Xs:[]i64=", .{self.count});
                try self.literal(xs);
                try self.source.print(";Attempt(Xs.Find[{d}],{d})}}\n", .{ wanted, sentinel });
                self.expect(.{ .integer = if (Model.find(xs, wanted)) |at| @intCast(at) else sentinel });
            },
            1 => try self.bindArray(xs, "Attempt(Xs.RemoveFirstElement[{d}],array{{{d}}})", .{ wanted, sentinel }, if (Model.find(xs, wanted)) |at| try self.concat(&.{ xs[0..at], xs[at + 1 ..] }) else null),
            2 => {
                var kept: std.ArrayList(i64) = .empty;
                for (xs) |item| if (item != wanted) try kept.append(self.arena, item);
                try self.bindArray(xs, "Xs.RemoveAllElements({d})", .{wanted}, kept.items);
            },
            3 => try self.bindArray(xs, "Attempt(Xs.Remove[{d},{d}],array{{{d}}})", .{ start, end, sentinel }, if (valid) try self.concat(&.{ xs[0..lower], xs[upper..] }) else null),
            4 => {
                const copy = try self.arena.dupe(i64, xs);
                const found = Model.find(xs, wanted);
                if (found) |at| copy[at] = with;
                try self.bindArray(xs, "Attempt(Xs.ReplaceFirstElement[{d},{d}],array{{{d}}})", .{ wanted, with, sentinel }, if (found != null) copy else null);
            },
            5 => {
                const copy = try self.arena.dupe(i64, xs);
                for (copy) |*item| if (item.* == wanted) {
                    item.* = with;
                };
                try self.bindArray(xs, "Xs.ReplaceAllElements({d},{d})", .{ wanted, with }, copy);
            },
            6 => {
                const copy = try self.arena.dupe(i64, xs);
                const inside = start >= 0 and start < @as(i64, @intCast(xs.len));
                if (inside) copy[@intCast(start)] = with;
                try self.bindArray(xs, "Attempt(Xs.ReplaceElement[{d},{d}],array{{{d}}})", .{ start, with, sentinel }, if (inside) copy else null);
            },
            7 => {
                const pattern = try self.someItems(3);
                const replacement = try self.someItems(3);
                var out: std.ArrayList(i64) = .empty;
                var at: usize = 0;
                while (at < xs.len) {
                    if (pattern.len != 0 and std.mem.startsWith(i64, xs[at..], pattern)) {
                        try out.appendSlice(self.arena, replacement);
                        at += pattern.len;
                    } else {
                        try out.append(self.arena, xs[at]);
                        at += 1;
                    }
                }
                try self.source.print("V{d}:[]i64=Block{{Xs:[]i64=", .{self.count});
                try self.literal(xs);
                try self.source.writeAll(";Ps:[]i64=");
                try self.literal(pattern);
                try self.source.writeAll(";Rs:[]i64=");
                try self.literal(replacement);
                try self.source.writeAll(";Xs.ReplaceAll(Ps,Rs)}\n");
                self.expect(.{ .integers = out.items });
            },
            8 => {
                const added = try self.someItems(3);
                const inside = start >= 0 and start <= @as(i64, @intCast(xs.len));
                try self.source.print("V{d}:[]i64=Block{{Xs:[]i64=", .{self.count});
                try self.literal(xs);
                try self.source.writeAll(";Ys:[]i64=");
                try self.literal(added);
                try self.source.print(";Attempt(Xs.Insert[{d},Ys],array{{{d}}})}}\n", .{ start, sentinel });
                self.expect(.{ .integers = if (inside) try self.concat(&.{ xs[0..@intCast(start)], added, xs[@intCast(start)..] }) else &.{sentinel} });
            },
            9 => {
                const back = self.position(xs.len);
                const inside = back >= 0 and back < @as(i64, @intCast(xs.len));
                try self.source.print("V{d}:i64=Block{{Xs:[]i64=", .{self.count});
                try self.literal(xs);
                try self.source.print(";Attempt(Xs.Last[{d}],{d})}}\n", .{ back, sentinel });
                self.expect(.{ .integer = if (inside) xs[xs.len - 1 - @as(usize, @intCast(back))] else sentinel });
            },
            10 => {
                if (self.random.boolean()) {
                    try self.bindArray(xs, "Attempt(Xs.Slice[{d},{d}],array{{{d}}})", .{ start, end, sentinel }, if (valid) xs[lower..upper] else null);
                } else {
                    const open = start >= 0 and start <= @as(i64, @intCast(xs.len));
                    try self.bindArray(xs, "Attempt(Xs.Slice[{d}],array{{{d}}})", .{ start, sentinel }, if (open) xs[@intCast(start)..] else null);
                }
            },
            else => {
                const rows = self.random.uintAtMost(usize, 4);
                var out: std.ArrayList(i64) = .empty;
                try self.source.print("V{d}:[]i64=Block{{Rows:[][]i64=array{{", .{self.count});
                for (0..rows) |index| {
                    const row = try self.someItems(3);
                    if (index != 0) try self.source.writeAll(",");
                    try self.literal(row);
                    try out.appendSlice(self.arena, row);
                }
                try self.source.writeAll("};Concatenate(Rows)}\n");
                self.expect(.{ .integers = out.items });
            },
        }
    }

    const alphabet = [_][]const u8{ "a", "b", "é", "ab", "😀", "" };
    fn text(self: *Oracle, most: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..self.random.uintAtMost(usize, most)) |_| try out.appendSlice(self.arena, alphabet[self.random.uintLessThan(usize, alphabet.len)]);
        return out.items;
    }
    fn boundary(string: []const u8, at: i64) bool {
        if (at < 0 or at > @as(i64, @intCast(string.len))) return false;
        const index: usize = @intCast(at);
        return index == string.len or (string[index] & 0xC0) != 0x80;
    }
    fn stringCase(self: *Oracle) !void {
        const s = try self.text(6);
        const start = self.position(s.len);
        switch (self.random.uintLessThan(u8, 4)) {
            0 => {
                const pattern = try self.text(2);
                const replacement = try self.text(2);
                const expected = if (pattern.len == 0) s else try std.mem.replaceOwned(u8, self.arena, s, pattern, replacement);
                try self.source.print("V{d}:string=\"{s}\".ReplaceAll(\"{s}\",\"{s}\")\n", .{ self.count, s, pattern, replacement });
                self.expect(.{ .text = expected });
            },
            1 => {
                const added = try self.text(2);
                try self.source.print("V{d}:string=Attempt(\"{s}\".Insert[{d},\"{s}\"],\"!\")\n", .{ self.count, s, start, added });
                self.expect(.{ .text = if (boundary(s, start)) try std.mem.concat(self.arena, u8, &.{ s[0..@intCast(start)], added, s[@intCast(start)..] }) else "!" });
            },
            2 => {
                const end = self.position(s.len);
                const valid = boundary(s, start) and boundary(s, end) and start <= end;
                try self.source.print("V{d}:string=Attempt(\"{s}\".Remove[{d},{d}],\"!\")\n", .{ self.count, s, start, end });
                self.expect(.{ .text = if (valid) try std.mem.concat(self.arena, u8, &.{ s[0..@intCast(start)], s[@intCast(end)..] }) else "!" });
            },
            else => {
                const unit: u8 = if (self.random.boolean()) 'a' else if (self.random.boolean()) 'b' else 0xC3;
                try self.source.print("V{d}:i64=Attempt(\"{s}\".Find[0o{X:0>2}],{d})\n", .{ self.count, s, unit, sentinel });
                self.expect(.{ .integer = if (std.mem.indexOfScalar(u8, s, unit)) |at| @intCast(at) else sentinel });
            },
        }
    }

    /// Two maps with keys from a small range; the result as a flat list of key, value.
    fn mapCase(self: *Oracle) !void {
        var maps: [2]std.ArrayList(i64) = .{ .empty, .empty };
        try self.source.print("V{d}:[]i64=Block{{", .{self.count});
        for (&maps, 0..) |*map, which| {
            try self.source.print("M{d}:map(i64,i64)=map{{", .{which});
            var written = false;
            for (0..self.random.uintAtMost(usize, 5)) |_| {
                const key = self.random.intRangeAtMost(i64, 0, 6);
                var present = false;
                var at: usize = 0;
                while (at < map.items.len) : (at += 2) present = present or map.items[at] == key;
                if (present) continue;
                const value = self.random.intRangeAtMost(i64, 10, 99);
                try map.appendSlice(self.arena, &.{ key, value });
                try self.source.print("{s}{d}=>{d}", .{ if (written) "," else "", key, value });
                written = true;
            }
            try self.source.writeAll("};");
        }
        try self.source.writeAll("Joined:=ConcatenateMaps(M0,M1);Concatenate(For(K->V:Joined,array{K,V}))}\n");
        var out: std.ArrayList(i64) = .empty;
        var at: usize = 0;
        while (at < maps[0].items.len) : (at += 2) {
            var value = maps[0].items[at + 1];
            var other: usize = 0;
            while (other < maps[1].items.len) : (other += 2) {
                if (maps[1].items[other] == maps[0].items[at]) value = maps[1].items[other + 1];
            }
            try out.appendSlice(self.arena, &.{ maps[0].items[at], value });
        }
        at = 0;
        while (at < maps[1].items.len) : (at += 2) {
            var present = false;
            var other: usize = 0;
            while (other < maps[0].items.len) : (other += 2) present = present or maps[0].items[other] == maps[1].items[at];
            if (!present) try out.appendSlice(self.arena, maps[1].items[at..][0..2]);
        }
        self.expect(.{ .integers = out.items });
    }
};

test "four hundred random programs agree with plain models of every array, string and map form" {
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x0077_5eed);
    const buffer = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(buffer);
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        _ = arena_state.reset(.retain_capacity);
        var oracle: Oracle = .{ .random = prng.random(), .source = std.Io.Writer.fixed(buffer), .arena = arena_state.allocator() };
        // A handful of forms per program, so that results of one sit in the pool below the next.
        const forms = 4 + oracle.random.uintLessThan(usize, 6);
        for (0..forms) |_| switch (oracle.random.uintLessThan(u8, 10)) {
            0...5 => try oracle.arrayCase(),
            6...8 => try oracle.stringCase(),
            else => try oracle.mapCase(),
        };
        const source = oracle.source.buffered();
        const x = h.execute(source) catch |problem| {
            std.debug.print("round {d}:\n{s}\n", .{ round, source });
            return problem;
        };
        for (oracle.expected[0..oracle.count], 0..) |expectation, index| {
            var name_buffer: [8]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "V{d}", .{index});
            const outcome = switch (expectation) {
                .integers => |want| expectIntegers(x, name, want),
                .integer => |want| expectInteger(x, name, want),
                .text => |want| expectString(x, name, want),
            };
            outcome catch |problem| {
                std.debug.print("round {d}, {s}:\n{s}\n", .{ round, name, source });
                return problem;
            };
        }
    }
}

test "one name has one meaning in a scope: a declaration further down is the module's, not the standard one" {
    const h = try harness.create();
    defer scratch.release(h);
    // A use above the module's own declaration is not quietly the standard function: it is
    // the name that is not in reach yet, as it was before there were standard functions.
    const above = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "A:i64=Max(1,2)\nMax(L:i64,R:i64)<computes>:i64=L+R", .code = .unknown_name },
        // From a body the module's own `Max` further down is in reach (RFC-0091), unless a
        // value lies between; the call then means it, and is refused as such.
        .{ .source = "F()<computes>:i64=Block{Max(1,2)}\nX:i64=1\nMax(L:i64,R:i64)<computes>:i64=L+R", .code = .forward_value_between },
        .{ .source = "A:float=Sqrt(4.0)\nSqrt<public>(X:float)<computes>:float=X", .code = .unknown_name },
        .{ .source = "A:i64=Clamp(1,2,3)\nClamp[T:type](X:T)<computes>:T{X}", .code = .unknown_name },
        .{ .source = "A:i64=Abs(0-1)\nAbs:=native{\"std.sum\"}", .code = .unknown_name },
        .{ .source = "A:i64=Min(1,2)\nvar Min:i64=40", .code = .unknown_name },
        .{ .source = "A:i64=Min(1,2)\nMin:i64=40", .code = .unknown_name },
        .{ .source = "A:float=Lerp(1.0,2.0,0.5)\nLerp:=i64", .code = .unknown_name },
        .{ .source = "A:float=Exp(1.0)\nExp:=struct{Top:i64}", .code = .unknown_name },
        .{ .source = "A:float=PiFloat\nPiFloat:float=3.0", .code = .unknown_name },
        .{ .source = "F()<computes>:float=PiFloat*2.0\nPiFloat<public>:float=3.0", .code = .unknown_name },
        .{ .source = "Xs:[]i64=array{1}\nA:i64=Attempt(Xs.Find[1],0)\n(Ys:[]i64).Find(V:i64)<computes>:i64=42", .code = .unknown_field },
        .{ .source = "A:string=\"ab\".ReplaceAll(\"a\",\"b\")\n(S:string).ReplaceAll(P:string,R:string)<computes>:string=S", .code = .unknown_field },
        .{ .source = "A:float=Attempt((1.0).IsFinite[],0.0)\n(X:float).IsFinite()<computes>:float=X", .code = .type_mismatch },
        // The bit operations of RFC-0072 follow the same rule.
        .{ .source = "A:i64=BitAnd(6,3)\nBitAnd(L:i64,R:i64)<computes>:i64=L+R", .code = .unknown_name },
        .{ .source = "A:i64=BitNot(6)\nBitNot:i64=3", .code = .unknown_name },
    };
    for (above) |case| try expectCode(h, case.source, case.code);
    // A declaration of another kind of thing by the name does not take it: an extension
    // method leaves the bare name alone, one for another kind of receiver leaves this one
    // its method, a member of a class and a name inside a call are no declarations of the
    // module, and neither is a use.
    var x = try h.execute(
        \\Bag:=struct{Items:[]i64}
        \\Xs:[]i64=array{4,5}
        \\A:i64=Attempt(Xs.Find[5],0-1)
        \\B:float=Sqrt(4.0)
        \\C:i64=Max(1,2)+Abs(0-3)+BitAnd(6,3)
        \\D:float=PiFloat
        \\E:i64=Attempt(Xs.Last[],0-1)
        \\(S:string).Find(V:i64)<computes>:i64=42
        \\(B1:Bag).Find(V:i64)<computes>:i64=7
        \\(S:string).Last()<computes>:i64=9
        \\(V:float).Sqrt()<computes>:float=V+1.0
        \\Shape:=class{
        \\    Max:i64=3
        \\    Abs()<computes>:i64=1
        \\}
        \\Twice(Max1:i64)<computes>:i64=Max(Max1,Max1*2)
        \\F:i64=Twice(4)+Bag{Items:=Xs}.Find(0)+"s".Find(0)+"s".Last()
    );
    try expectInteger(x, "A", 1);
    try expectFloat(x, "B", 2.0);
    try expectInteger(x, "C", 2 + 3 + 2);
    try expectFloat(x, "D", std.math.pi);
    try expectInteger(x, "E", 5);
    try expectInteger(x, "F", 8 + 7 + 42 + 9);
    // In a block, a local that takes a standard name before any use of it is a local; one that
    // takes it after the block used it as the standard function gives the name two meanings.
    x = try h.execute(
        \\A()<computes>:i64=Block{Max:=5;Max+1}
        \\B()<computes>:float=Block{PiFloat:=3.0;Sqrt:=PiFloat;Sqrt+1.0}
        \\C()<computes>:i64=If(Max(1,2)==2,Block{Min:=7;Min},Block{Min(8,9)})
        \\D()<computes>:i64=Block{Left:=Block{Abs(0-4)};Right:=Block{Abs:=6;Abs};Left+Right}
        \\E()<computes>:i64=Block{BitOr:=1;BitOr+BitAnd(6,3)}
        \\Va:i64=A()
        \\Vb:float=B()
        \\Vc:i64=C()
        \\Vd:i64=D()
        \\Ve:i64=E()
    );
    try expectInteger(x, "Va", 6);
    try expectFloat(x, "Vb", 4.0);
    try expectInteger(x, "Vc", 7);
    try expectInteger(x, "Vd", 10);
    try expectInteger(x, "Ve", 3);
    const after = [_][]const u8{
        "F()<computes>:i64=Block{A:=Max(1,2);Max:=5;A+Max}",
        "F()<computes>:i64=Block{A:=Block{Max(1,2)};Max:=5;A+Max}",
        "F()<transacts>:i64=Block{A:=If(true,Abs(0-1),0);var Abs:i64=5;A+Abs}",
        "F()<computes>:float=Block{A:=PiFloat;PiFloat:=3.0;A+PiFloat}",
        "F()<computes>:float=Block{A:=Sqrt(PiFloat);B:=A;PiFloat:float=3.0;B+PiFloat}",
        "F()<computes>:i64=Block{A:=BitAnd(6,3);BitAnd:=5;A+BitAnd}",
        "V:i64=Block{A:=Max(1,2);Max:=5;A+Max}",
    };
    for (after) |source| {
        try expectCode(h, source, .used_before_declaration);
        const failed = h.front.compile(source).failed;
        // The diagnostic is at the declaration, which is where the second meaning starts.
        try std.testing.expect(failed.span.start > std.mem.indexOf(u8, source, "A:=").?);
        try std.testing.expect(std.mem.indexOf(u8, failed.message(), "before this declaration") != null);
    }
    // What the program declares by the name outside the block is what the uses meant, so a
    // local of the name there is whatever it was before: no concern of this rule.
    const own = h.front.compile("Max(L:i64,R:i64)<computes>:i64=L+R\nF()<computes>:i64=Block{A:=Max(1,2);Max:=5;A+Max}\nV:i64=F()");
    try std.testing.expect(own == .ok or own.failed.code != .used_before_declaration);
}

test "a private name of a used module is not in reach, so the standard one applies there" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:float=Sqrt(4.0)\nB<public>:float=Root(4.0)\nC<public>:float=PiFloat\nD<public>:float=Turn()\nE<public>:i64=Attempt(array{1,2}.Find[2],0-1)\nF<public>:i64=Where(array{1,2})" },
        // The library means its own `Sqrt`, `PiFloat` and `Find`; none of them is exported.
        .{ .path = "lib.forb", .source = "Sqrt(X:float)<computes>:float=X+1.0\nRoot<public>(X:float)<computes>:float=Sqrt(X)\nPiFloat:float=3.0\nTurn<public>()<computes>:float=PiFloat\n(Xs:[]i64).Find(V:i64)<computes>:i64=42\nWhere<public>(Ys:[]i64)<computes>:i64=Ys.Find(2)" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const x = (try h.run(bundled.ok, 20_000)).ok;
    try expectFloat(x, "A", 2.0);
    try expectFloat(x, "B", 5.0);
    try expectFloat(x, "C", std.math.pi);
    try expectFloat(x, "D", 3.0);
    try expectInteger(x, "E", 1);
    try expectInteger(x, "F", 42);
    // A module declares a name for itself: a use above its own declaration in the library is
    // refused there, whatever the module that uses it does.
    const early = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:float=L.Root(4.0)" },
        .{ .path = "lib.forb", .source = "Root<public>(X:float)<computes>:float=Block{Y:=Sqrt(X);Y}\nSqrt<public>(X:float)<computes>:float=X+1.0\nEarly:float=Root(1.0)" },
    };
    const fine = h.front.compileBundle(.{ .root = "main.forb", .modules = &early });
    // A function body may call a function further down (RFC-0091): the library's own `Sqrt`.
    try std.testing.expect(fine == .ok);
    try expectFloat((try h.run(fine.ok, 20_000)).ok, "A", 5.0);
}

test "inside an extension method, a method call on a value of another type is not the method itself" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Bag:=struct{Items:[]i64}
        \\(B:Bag).Find(V:i64)<computes><decides>:i64=B.Items.Find[V]
        \\(S:string).Last()<computes>:i64=Attempt(array{1,2}.Last[],0)+S.Length
        \\(Xs:[]i64).Slice(N:i64)<computes>:string=Attempt("abcdef".Slice[N],"")
        \\(V:i64).Down()<computes>:i64=If(V<=0,0,1+(V-1).Down())
        \\A:i64=Attempt(Bag{Items:=array{4,5}}.Find[5],0-1)
        \\B:i64="xyz".Last()
        \\C:string=array{1}.Slice(4)
        \\D:i64=3.Down()
    );
    try expectInteger(x, "A", 1);
    try expectInteger(x, "B", 5);
    try expectString(x, "C", "ef");
    try expectInteger(x, "D", 3);
    // On a value of its own type the name is still the method being declared.
    try expectCode(h, "(Xs:[]i64).Find(V:i64)<computes>:i64=Attempt(Xs.Find[V],0)", .expected_call);
}

test "a text search costs the same whatever the bytes are, and finds the same" {
    const h = try harness.create();
    defer scratch.release(h);
    // The pattern that makes a plain search compare half the text at every position, and
    // one of the same length that it would dismiss at once.
    const slow = "T:string=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\nA:string=T.ReplaceAll(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\",\"c\")";
    const fast = "T:string=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\nA:string=T.ReplaceAll(\"bzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\",\"c\")";
    try std.testing.expectEqual(try leastFuel(h, try h.compile(fast), 4096), try leastFuel(h, try h.compile(slow), 4096));
    const x = try h.execute(
        \\Index:=native{"std.index_of"}
        \\Has:=native{"std.contains"}
        \\Split:=native{"std.split"}
        \\T:string="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-aaaaaaaaaaaaaaab"
        \\A:string=T.ReplaceAll("aaaaaaaaaaaaaaab","<>")
        \\B:option(i64)=Index(T,"aaaaaaaaaaaaaaab")
        \\C:logic=Has(T,"ab-aa") and not Has(T,"ba-a")
        \\D:[]string=Split(T,"aab")
        \\E:string="abababab".ReplaceAll("abab","x")+"|"+"aabaabaab".ReplaceAll("aab","b")
    );
    try expectString(x, "A", "aaaaaaaaaaaaaaaa<>-<>");
    try std.testing.expectEqual(@as(i64, 16), x.aggregate_values[x.get("B").?.aggregate.elements.start].integer);
    try expectLogic(x, "C", true);
    const parts = x.get("D").?.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 3), parts.end - parts.start);
    try std.testing.expectEqualStrings("-aaaaaaaaaaaaa", x.aggregate_values[parts.start + 1].string);
    try expectString(x, "E", "xx|bbb");
}

const rogue = struct {
    const native = @import("native.zig");
    /// What a generic kernel must not do: hand on a string that is not one it was given.
    fn halved(ctx: *native.Context, items: native.AnyArray, start: i64, end: i64) native.Error!native.AnyOut {
        _ = start;
        _ = end;
        const first = ctx.used;
        const text = items.items[0].string;
        try ctx.append(.{ .string = text[0 .. text.len - 1] });
        return .{ .span = .{ .start = @intCast(first), .end = @intCast(ctx.used) }, .items = ctx.pool[first..ctx.used] };
    }
    fn foreign(ctx: *native.Context, items: native.AnyArray, start: i64, end: i64) native.Error!native.AnyOut {
        _ = items;
        _ = start;
        _ = end;
        const first = ctx.used;
        try ctx.append(.{ .string = "outside" });
        return .{ .span = .{ .start = @intCast(first), .end = @intCast(ctx.used) }, .items = ctx.pool[first..ctx.used] };
    }
    fn ahead(ctx: *native.Context, items: native.AnyArray, start: i64, end: i64) native.Error!native.AnyOut {
        _ = start;
        _ = end;
        const first = ctx.used;
        // A structural value that names the members being built, not ones that were there.
        var value = items.items[0];
        value.aggregate.elements = .{ .start = @intCast(first), .end = @intCast(first + 1) };
        try ctx.append(value);
        return .{ .span = .{ .start = @intCast(first), .end = @intCast(ctx.used) }, .items = ctx.pool[first..ctx.used] };
    }
};

test "what a generic kernel hands on is checked without reading it: a moved string is a view of the pool between scalars" {
    const h = try harness.create();
    defer scratch.release(h);
    const native = @import("native.zig");
    const standard = @import("native_std.zig").table;
    var table: [standard.len]native.Entry = standard;
    const slot = @import("stdlib_natives.zig").find(&standard, "std.array_slice").?;
    // Text whose last scalar takes two units: cutting one off leaves bytes that are not text.
    const strings = "Ws:[]string=array{\"José\"}\nS:[]string=Attempt(Ws.Slice[0,1],Ws)";
    const rows = "Rs:[][]i64=array{array{1}}\nS:[][]i64=Attempt(Rs.Slice[0,1],Rs)";
    for ([_]struct { source: []const u8, kernel: native.Entry }{
        .{ .source = strings, .kernel = native.entry("std.array_slice", rogue.halved, .{ .base = 2 }) },
        .{ .source = strings, .kernel = native.entry("std.array_slice", rogue.foreign, .{ .base = 2 }) },
        .{ .source = rows, .kernel = native.entry("std.array_slice", rogue.ahead, .{ .base = 2 }) },
    }) |case| {
        table[slot] = case.kernel;
        var forged = try h.compile(case.source);
        forged.natives = &table;
        const result = try h.run(forged, 10_000);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, result.failed.code);
    }
    // The kernel that moves what it was given passes, with the same checks.
    table[slot] = standard[slot];
    var honest = try h.compile(strings);
    honest.natives = &table;
    const x = (try h.run(honest, 10_000)).ok;
    const moved = x.get("S").?.aggregate.elements;
    try std.testing.expectEqualStrings("José", x.aggregate_values[moved.start].string);
}

test "a merge of maps too large for the stack asks the host for its table once, and a host without one is reported as that" {
    const h = try harness.create();
    defer scratch.release(h);
    const bytecode = @import("bytecode.zig");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    // Two literals of 200 entries fit the tables on the stack, and so does their merge; the
    // merged map has 400 entries, and indexing it takes 1,024 slots, which are the run's.
    for ([_][]const u8{ "Low", "High" }, 0..) |name, half| {
        try source.print(std.testing.allocator, "{s}:map(i64,i64)=map{{", .{name});
        for (0..200) |index| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (index == 0) "" else ",", half * 200 + index, index });
        try source.appendSlice(std.testing.allocator, "}\n");
    }
    try source.appendSlice(std.testing.allocator, "All:map(i64,i64)=ConcatenateMaps(Low,High)\nAgain:map(i64,i64)=ConcatenateMaps(All,All)\nSize:i64=Again.Length\nSame:logic=Again==All");
    const p = try h.compile(source.items);
    const machine = &h.runtime.machine;
    const lowered = bytecode.lower(p, &h.runtime.instructions).ok;
    machine.key_work.host_exhausted = true;
    const starved = machine.run(lowered, 1_000_000);
    try std.testing.expectEqual(types.Diagnostic.Code.scratch_unavailable, starved.failed.code);
    try std.testing.expectEqualStrings("ConcatenateMaps", starved.failed.span.text(source.items));
    try std.testing.expect(starved.failed.span.start > std.mem.indexOf(u8, source.items, "Again").?);
    try std.testing.expectEqual(@as(u32, 0), machine.key_work.host_requests);
    machine.key_work.host_exhausted = false;
    const x = (try h.run(p, 1_000_000)).ok;
    try expectInteger(x, "Size", 400);
    try expectLogic(x, "Same", true);
    // One request for the first index of the large map; the second index reuses the table.
    try std.testing.expectEqual(@as(u32, 1), machine.key_work.host_requests);
    try std.testing.expectEqual(@as(usize, 0), machine.key_work.slots.len);
}
