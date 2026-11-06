//! TASK-0109, B8: two rules tightened to the Book (RFC-0067 amendment). `<castable>` is not
//! declared on a parametric class (10:2450, 10:2484), and `_` is the wildcard of a `Case`
//! pattern and a declared name nowhere. `castable_concrete_subtype` is tested with the other
//! metatypes in `methods_and_subtypes_tests.zig`. Every program runs on both machines.
const std = @import("std");
const scratch = @import("scratch.zig");
const modules = @import("modules.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const Code = types.Diagnostic.Code;

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value != .integer or value.integer != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.integer);
}

/// The source is refused with `code`, and the diagnostic covers exactly `text`.
fn expectRefused(h: *harness.Harness, source: []const u8, code: Code, text: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), text)) std.debug.print("{s} at `{s}`, expected {s} at `{s}`: {s}\n", .{ @tagName(result.failed.code), result.failed.span.text(source), @tagName(code), text, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(text, result.failed.span.text(source));
}

/// The diagnostic covers the `_` at `at`.
fn expectUnderscoreAt(h: *harness.Harness, source: []const u8, at: usize) !void {
    try expectRefused(h, source, .underscore_name, "_");
    const result = h.front.compile(source);
    try std.testing.expectEqual(at, result.failed.span.start);
}

/// The diagnostic covers the first `_` of `source`.
fn expectUnderscore(h: *harness.Harness, source: []const u8) !void {
    try expectUnderscoreAt(h, source, std.mem.indexOfScalar(u8, source, '_').?);
}

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

// ---- <castable> on a parametric class

test "b8 a parametric class is not castable, wherever it is declared and whether or not it is used" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "Box[T:type]:=class<castable>{}", .castable_parametric, "castable");
    try expectRefused(h, "Box[T:type]:=class<final><castable>{Value:T}", .castable_parametric, "castable");
    try expectRefused(h, "Box[T:type]:=class<castable><final>{Value:T}\nB<public>:i64=1", .castable_parametric, "castable");
    try expectRefused(h, "Pair[A:type,B:type]:=class<abstract><castable>{}", .castable_parametric, "castable");
    try expectRefused(h, "Root:=class<castable>{}\nBox[T:type]:=class<castable>(Root){}", .castable_parametric, "castable");
    // Used, it is refused where it is declared and not where it is named.
    try expectRefused(h, "Box[T:type]:=class<castable>{Value:T}\nV:=Box[i64]{Value:=1}", .castable_parametric, "castable");
    try expectRefused(h, "Box<public>[T:type]:=class<castable>{}", .castable_parametric, "castable");
    // In a bundle, in the file that declares it.
    const lib = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=1", "Box<public>[T:type]:=class<castable>{}\n");
    try std.testing.expect(lib == .failed and lib.failed.diagnostic.code == .castable_parametric);
}

test "b8 what stays: castable classes that are not parametric, and parametric classes below one" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Root:=class<castable>{N:i64=1}
        \\Leaf:=class<castable>(Root){N<override>:i64=2}
        \\Box[T:type]:=class(Root){Value:T}
        \\Cell[T:type]:=class{Value:T}
        \\Shape[T:type]:=struct{Value:T}
        \\Kinds:=castable_subtype(Root)
        \\K:Kinds=Leaf
        \\A<public>:i64=Attempt(Block{K[Leaf{}];K[Root{}];1},0)
        \\B<public>:i64=Attempt(Block{K[Leaf{}];1},0)
        \\C<public>:i64=Box[i64]{Value:=3}.Value+Cell[i64]{Value:=4}.Value+Shape[i64]{Value:=5}.Value
        \\Cast[T:castable_subtype(Root)](X:Root)<computes><decides>:T{T[X]}
        \\D<public>:i64=Attempt(Cast[Leaf][Leaf{}].N,0-1)
    );
    try expectInt(x, "A", 0);
    try expectInt(x, "B", 1);
    try expectInt(x, "C", 12);
    try expectInt(x, "D", 2);
    // An instantiation is no type value of a class bound, and the query of B4 refuses one the same way.
    try expectRefused(h, "Root:=class<castable>{}\nBox[T:type]:=class(Root){}\nBi:=Box[i64]\nK:castable_subtype(Bi)=Bi", .unsupported_type, "Bi");
    try expectRefused(h, "Root:=class<castable>{}\nBox[T:type]:=class(Root){}\nV:i64=Attempt(Block{GetCastableFinalSuperClass[Box[i64],Box[i64]{}];1},0)", .unsupported_type, "GetCastableFinalSuperClass");
    // An interface still has no `<castable>`.
    try expectRefused(h, "I:=interface<castable>{}", .unsupported_specifier, "castable");
}

// ---- `_` is the wildcard and no name

test "b8 a declared name is never _" {
    const h = try harness.create();
    defer scratch.release(h);
    const refusals = [_][]const u8{
        "_:i64=1",
        "_<public>:i64=1",
        "_:=1",
        "var _:i64=1",
        "V<public>:i64=1\n_:i64=2",
        "F(_:i64)<computes>:i64=1",
        "F(X:i64,_:i64)<computes>:i64=X",
        "F(X:i64,_:i64=3)<computes>:i64=X",
        "_()<computes>:i64=1",
        "_(X:i64)<computes>:i64=X",
        "C:=class{_:i64=0}",
        "C:=class{var _:i64=0}",
        "C:=class{M(_:i64)<computes>:i64=1}",
        "C:=class{_()<computes>:i64=1}",
        "S:=struct{_:i64}",
        "_:=class{}",
        "_:=struct{X:i64}",
        "E:=enum{_,b}",
        "E:=enum{a,_}",
        "_:=enum{a,b}",
        "I:=interface{_()<computes>:i64}",
        "M:=module{_<public>:i64=1}",
        "V<public>:i64=Block{_:=1;2}",
        "V<public>:i64=Block{var _:i64=1;2}",
        "V<public>:i64=Block{F(_:i64)<computes>:i64=1;F(2)}",
        "V<public>:i64=For(_:array{1,2},1).Length",
        "V<public>:i64=For(_:1..3,1).Length",
        "Box[_:type]:=class{}",
        "F[_:type](X:i64)<computes>:i64=1",
        "_[T:type]:=class{}",
        "T:=type{_:i64 where _>0}",
        "V<public>:i64=Block{Fn:=(_:i64)=>1;1}",
        "P:tuple(i64,i64)=tuple{1,2}\n(A,_):=P",
    };
    for (refusals) |source| try expectUnderscore(h, source);
    // A Case that has the wildcard in its place does not let one through elsewhere in it.
    try expectUnderscore(h, "V<public>:i64=Case(1,1=>Block{_:=2;3},_=>0)");
    try expectUnderscoreAt(h, "V<public>:i64=Case(1,1=>2,_=>Block{_:=2;3})", 35);
    try expectUnderscore(h, "V<public>:i64=Block{_:=1;Case(1,1=>2,_=>0)}");
    try expectUnderscore(h, "V<public>:i64=Case(Block{_:=1;1},1=>2,_=>0)");
    try expectUnderscoreAt(h, "V<public>:i64=Case(1,1=>Case(2,2=>Block{var _:i64=1;1},_=>0),_=>0)", 44);
    // A guard is an expression like the value: it declares nothing named `_` either.
    try expectUnderscore(h, "V<public>:i64=Case(1,Y:i64 where Block{_:=1;true}=>1,_=>0)");
    try expectUnderscore(h, "V<public>:i64=Case(1,Y:i64 where Block{F(_:i64)<computes>:i64=1;F(1)>0}=>1,_=>0)");
    try expectUnderscore(h, "V<public>:i64=Case(1,Y:i64 where Block{var _:i64=1;true}=>1,_=>0)");
    try expectUnderscore(h, "V<public>:i64=Case(1,Y:i64 where For(_:array{1},1).Length>0=>1,_=>0)");
    try expectUnderscoreAt(h, "V<public>:i64=Case(1,tuple{X,_} where Block{_:=X;true}=>X,_=>0)", 44);
    // A guard with the wildcard in the pattern before it, and a `where` that is a value.
    const guarded = try h.execute("V<public>:i64=Case(3,X:i64 where X>2=>X,_=>0)\nF(P:tuple(i64,i64))<computes>:i64=Case(P,tuple{A,_} where A>1=>A,_=>0)\nW<public>:i64=F(tuple{5,6})");
    try expectInt(guarded, "V", 3);
    try expectInt(guarded, "W", 5);
    // A Case that is not well formed is refused by the rewrite that takes Cases apart, whatever is
    // written in it: the `_` of its arms is not looked at first.
    const malformed = [_][]const u8{ "V:i64=Case(1,_:=2)", "V:i64=Case(1,2)", "V:i64=Case(1)", "V:i64=Case(1,_", "V:i64=Case(1,1,_=>2)", "V:i64=Case(_)", "V:i64=Case(1,1=>2,3)\nW:i64=Block{_:=1;2}" };
    for (malformed) |source| {
        const result = h.front.compile(source);
        if (result != .failed or result.failed.code != .case_arms) std.debug.print("expected case_arms: {s}\n", .{source});
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(Code.case_arms, result.failed.code);
    }
    // And one inside another costs one pass over its tokens at each level, not a doubling.
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(std.testing.allocator);
    try nested.appendSlice(std.testing.allocator, "V<public>:i64=");
    for (0..60) |_| try nested.appendSlice(std.testing.allocator, "Case(1,1=>");
    try nested.appendSlice(std.testing.allocator, "0");
    for (0..60) |_| try nested.appendSlice(std.testing.allocator, ",2)");
    const deep = h.front.compile(nested.items);
    try std.testing.expect(deep == .failed);
    // Neither the text of a string nor a comment declares a name.
    const x = try h.execute("V<public>:i64=\"a_b\".Length\n# _:i64=1\nW<public>:i64=1");
    try expectInt(x, "V", 3);
    // A name that holds an underscore is a name.
    const y = try h.execute("a_:i64=1\nb_c:i64=2\nd__:i64=3\nV<public>:i64=a_+b_c+d__");
    try expectInt(y, "V", 6);
}

test "b8 the wildcard of a Case pattern stays" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class{}
        \\Cat:=class(Animal){}
        \\Dog:=class(Animal){}
        \\Color:=enum{red,green,blue}
        \\Count(A:Animal)<transacts>:i64=Case(A,_:Cat=>1,_:Dog=>2,Other:Animal=>3)
        \\Tint(C:Color)<computes>:i64=Case(C,Color.red=>1,_=>2)
        \\Both(P:tuple(Animal,i64))<transacts>:i64=Case(P,tuple{_:Cat,N}=>N,tuple{_,N}=>N+100)
        \\Maybe(O:option(i64))<computes>:i64=Case(O,option{_}=>1,_=>0)
        \\Nest(X:i64)<computes>:i64=Case(X,1=>Case(X+1,2=>10,_=>20),_=>Case(X,5=>30,_=>40))
        \\Guarded(X:i64)<computes>:i64=Case(X,1=>Block{Y:=7;Y},_=>0)
        \\Fails(X:i64)<computes><decides>:i64=Case[X,1=>5,2=>6]
        \\A<public>:i64=Count(Cat{})+Count(Dog{})*10+Count(Animal{})*100
        \\B<public>:i64=Tint(Color.red)*10+Tint(Color.blue)
        \\C<public>:i64=Both(tuple{Cat{},5})*1000+Both(tuple{Dog{},6})
        \\D<public>:i64=Maybe(option{4})*10+Maybe(option{})
        \\E<public>:i64=Nest(1)+Nest(5)+Nest(2)
        \\F<public>:i64=Guarded(1)+Guarded(2)
        \\G<public>:i64=Attempt(Fails[1],0)*10+Attempt(Fails[2],0)
    );
    try expectInt(x, "A", 1 + 2 * 10 + 3 * 100);
    try expectInt(x, "B", 12);
    try expectInt(x, "C", 5000 + 106);
    try expectInt(x, "D", 10);
    try expectInt(x, "E", 10 + 30 + 40);
    try expectInt(x, "F", 7);
    try expectInt(x, "G", 56);
}
