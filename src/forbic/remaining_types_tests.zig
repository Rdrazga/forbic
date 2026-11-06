//! RFC-0080, the remaining type features: `void` results, the top type `any` with its explicit
//! conversion and checked casts, and what follows from them. Every program runs on both
//! machines (`harness.run` holds them to the same values, steps, cells and reports).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
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

fn expectLogic(x: anytype, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value != .boolean or value.boolean != expected) std.debug.print("{s}: {any}, expected {}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.boolean);
}

fn expectText(x: anytype, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    try std.testing.expectEqualStrings(expected, value.string);
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

/// The source is refused with `code`, wherever.
fn refused(h: *harness.Harness, source: []const u8, code: Code) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    if (result.failed.code != code) std.debug.print("{s} at `{s}`, expected {s}: {s}\n", .{ @tagName(result.failed.code), result.failed.span.text(source), @tagName(code), source });
    try std.testing.expectEqual(code, result.failed.code);
}

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

fn bundleRuns(h: *harness.Harness, main: []const u8, lib: []const u8) !evaluator.Execution {
    const result = bundle(h, main, lib);
    if (result != .ok) {
        std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ result.failed.diagnostic.message(), result.failed.path, result.failed.diagnostic.span.start });
        return error.Compile;
    }
    return (try h.run(result.ok, 1 << 20)).ok;
}

fn count(nodes: anytype, comptime kind: []const u8) usize {
    var total: usize = 0;
    for (nodes) |entry| {
        const node = if (@hasField(@TypeOf(entry), "node")) entry.node else entry;
        if (std.mem.eql(u8, @tagName(node.kind), kind)) total += 1;
    }
    return total;
}

// ---- `void`

test "rfc0080 a void result accepts any body value and yields the unit value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Count:i64=0
        \\Bump(N:i64)<transacts>:void=Set(Count,Count+N)
        \\Log(S:string)<computes>:void=S.Length+1
        \\Unit<public>:tuple()=Log("abc")
        \\U2<public>:void=Bump(5)
        \\After<public>:i64=Count
        \\Gen[T:type](X:T)<computes>:void{array{X,X}}
        \\U3<public>:void=Gen[i64](4)
        \\K:=class{
        \\    var N:i64=0
        \\    Add(V:i64)<transacts>:void=Block{set Self.N=Self.N+V;Self.N}
        \\    Get()<transacts>:i64=Self.N
        \\}
        \\Obj:=K{}
        \\U4<public>:void=Obj.Add(7)
        \\Got<public>:i64=Obj.Get()
        \\(S:string).Shout()<computes>:void=S+"!"
        \\U5<public>:void="a".Shout()
        \\H:function(tuple(i64),void)=Fn(X:i64)<computes>:void{X*2}
        \\U6<public>:tuple()=H(3)
        \\Early(X:i64)<computes>:void=Block{If(X>3,Return(tuple{}),tuple{});X}
        \\U7<public>:void=Early(9)
        \\Checked(X:i64)<computes><decides>:void=Block{Require[X>0];X}
        \\Ok<public>:logic=Attempt(Block{Checked[1];true},false)
        \\No<public>:logic=Attempt(Block{Checked[0];true},false)
        \\U8<public>:void=void(Count+1)
        \\Same<public>:logic=Unit==U2 and U8==tuple{}
    );
    try expectInt(x, "After", 5);
    try expectInt(x, "Got", 7);
    try expectLogic(x, "Ok", true);
    try expectLogic(x, "No", false);
    try expectLogic(x, "Same", true);
    for ([_][]const u8{ "Unit", "U2", "U3", "U4", "U5", "U6", "U7", "U8" }) |name| {
        const value = x.get(name).?;
        try std.testing.expect(value == .aggregate and value.aggregate.elements.start == value.aggregate.elements.end);
    }
    // `void` is the type `tuple()`: no node, type or operation of its own.
    const p = try h.compile("F(X:i64)<computes>:void=X+1\nG(X:i64)<computes>:tuple()=Block{X+1;tuple{}}\nA:void=F(1)\nB:tuple()=G(1)");
    try std.testing.expectEqual(p.functions[0].value_type, p.functions[1].value_type);
    try std.testing.expectEqual(p.nodes[p.bindings[0].node].value_type, p.nodes[p.bindings[1].node].value_type);
}

test "rfc0080 void converts nothing implicitly and a dropped comparison stays an error" {
    const h = try harness.create();
    defer scratch.release(h);
    // The value of a void body is dropped, so a body that is a comparison is a dropped comparison.
    try expectRefused(h, "F(X:i64)<computes>:void=X<3", .discarded_comparison, "<");
    try expectRefused(h, "F(X:i64)<computes>:void=(X<3)", .discarded_comparison, "<");
    try expectRefused(h, "F(X:i64)<computes>:void=not (X==3)", .discarded_comparison, "not");
    try expectRefused(h, "F[T:type](X:T,Y:i64)<computes>:void{Y<3}\nA:void=F[i64](1,2)", .discarded_comparison, "<");
    try expectRefused(h, "K:=class{F(X:i64)<computes>:void=X<3}", .discarded_comparison, "<");
    try expectRefused(h, "H:function(tuple(i64),void)=Fn(X:i64)<computes>:void{X<3}", .discarded_comparison, "<");
    // A block that ends in one is a value of the block, as in RFC-0076; so is a call.
    _ = try h.execute("F(X:i64)<computes>:void=Block{X<3}\nLess(X:i64)<computes>:logic=X<3\nG(X:i64)<computes>:void=Less(X)\nA:void=F(1)\nB:void=G(1)");
    // Only a function result written `void` discards. Elsewhere `void` is `tuple()`, exactly.
    try expectRefused(h, "A:void=5", .type_mismatch, "5");
    try expectRefused(h, "F(X:void)<computes>:i64=1\nA:i64=F(5)", .type_mismatch, "5");
    try expectRefused(h, "F(X:i64)<computes>:void=Block{Return(X)}", .type_mismatch, "X");
    try expectRefused(h, "F(X:i64)<computes>:tuple()=X", .type_mismatch, "X");
    try expectRefused(h, "F(X:i64)<computes>:[]void=X", .type_mismatch, "X");
    try expectRefused(h, "F(X:i64)<computes>:void=array{}", .array_type_required, "array");
    try expectRefused(h, "A:void=void()", .expected_expression, ")");
    // An override keeps the result type, and `void` is `tuple()`.
    _ = try h.execute("B:=class{F()<transacts>:void=1}\nD:=class(B){F<override>()<transacts>:tuple()=tuple{}}\nE:=class(B){F<override>()<transacts>:void=\"x\"}");
}

test "rfc0080 void and any yield to every declaration of the name" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type, an alias, a type parameter.
    var x = try h.execute("void:=struct{N:i64}\nF(X:i64)<computes>:void=void{N:=X}\nA<public>:i64=F(4).N");
    try expectInt(x, "A", 4);
    x = try h.execute("void:=i64\nany:=string\nF(X:i64)<computes>:void=X+1\nG(S:any)<computes>:any=S+\"!\"\nA<public>:i64=F(4)\nB<public>:string=G(\"a\")");
    try expectInt(x, "A", 5);
    try expectText(x, "B", "a!");
    x = try h.execute("F[void:type](X:void)<computes>:void{X}\nG[any:type](X:any)<computes>:any{X}\nA<public>:i64=F[i64](4)\nB<public>:string=G[string](\"b\")");
    try expectInt(x, "A", 4);
    try expectText(x, "B", "b");
    x = try h.execute("any:=class{N:i64=3}\nMake()<transacts>:any=any{}\nA<public>:i64=Make().N");
    try expectInt(x, "A", 3);
    // A function, a local, a parameter, a binding.
    x = try h.execute("any(X:i64)<computes>:i64=X+1\nvoid(X:i64)<computes>:i64=X*2\nA<public>:i64=any(4)+void(4)");
    try expectInt(x, "A", 13);
    x = try h.execute("F(X:i64)<computes>:i64=Block{any:=X+1;void:=X*2;any+void}\nA<public>:i64=F(4)");
    try expectInt(x, "A", 13);
    x = try h.execute("F(any:i64,void:i64)<computes>:i64=any+void\nA<public>:i64=F(4,5)");
    try expectInt(x, "A", 9);
    x = try h.execute("any:i64=4\nvoid:i64=5\nA<public>:i64=any+void");
    try expectInt(x, "A", 9);
    // A member of the class a method is in: the bare name stays unknown, as for `Sqrt`.
    try expectRefused(h, "K:=class{any(X:i64)<computes>:i64=X\nF()<computes>:i64=any(1)}", .unknown_name, "any");
    // One name, one meaning in a scope: a declaration further down is not pre-empted.
    try expectRefused(h, "A:i64=Attempt(i64[any(1)],0)\nany(X:i64)<computes>:i64=X", .unknown_name, "any");
    // From a body it is in reach (RFC-0091), and a value between the two is refused as such.
    try expectRefused(h, "F()<computes>:i64=Block{any(1);2}\nY:i64=1\nany(X:i64)<computes>:i64=X", .forward_value_between, "any");
    x = try h.execute("F()<computes>:i64=Block{any(1)+2}\nany(X:i64)<computes>:i64=X*10\nA<public>:i64=F()");
    try expectInt(x, "A", 12);
    // Through `using`, a module's own `any` is the one that is meant.
    const used = try bundleRuns(h, "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=any(4)\nB<public>:void=void{N:=2}\nC<public>:i64=B.N", "any<public>(X:i64)<computes>:i64=X+10\nvoid<public>:=struct{N:i64}");
    try expectInt(used, "A", 14);
    try expectInt(used, "C", 2);
}

// ---- `any`

const zoo =
    \\Animal:=class{Name:string="animal"}
    \\Dog:=class(Animal){Bark:i64=3}
    \\Cat:=class<final>(Animal){}
    \\Walker:=interface{Legs()<transacts>:i64}
    \\Robot:=class(Walker){Legs<override>()<transacts>:i64=2}
    \\Point:=struct{X:i64,Y:i64}
    \\Color:=enum{Red,Green}
    \\Ints:=[]i64
    \\Opt:=option(i64)
    \\Pair:=tuple(i64,string)
    \\Table:=map(i64,string)
    \\Step:=function(tuple(i64),i64)
    \\Twice(N:i64)<computes>:i64=N*2
    \\MkDog()<transacts>:Dog=Dog{Name:="rex"}
    \\MkCat()<transacts>:Animal=Cat{}
    \\MkBot()<transacts>:Walker=Robot{}
    \\
;

test "rfc0080 any holds every value and a checked cast gives it back as the type it has" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(zoo ++
        \\Half:rational=Attempt(Rational[1,2],MakeRationalFromInt(0))
        \\A:any=any(5)
        \\B:any=any("text")
        \\C:any=any(MkDog())
        \\D:any=any(Point{X:=1,Y:=2})
        \\E:any=any(Color.Green)
        \\F:any=any(array{1,2,3})
        \\G:[]any=array{A,B,C,D,E,F,any(2.5),any(true),any('c'),any(option{4}),any(Twice),any(MkCat()),any(MkBot()),any(tuple{1,"a"}),any(map{1=>"x"}),any(Half)}
        \\AsInt<public>:i64=Attempt(i64[A],-1)
        \\NotInt<public>:i64=Attempt(i64[B],-1)
        \\AsText<public>:string=Attempt(string[B],"none")
        \\NotText<public>:string=Attempt(string[A],"none")
        \\AsDog<public>:i64=Attempt(Dog[C].Bark,-1)
        \\AsAnimal<public>:string=Attempt(Animal[C].Name,"none")
        \\CatIsDog<public>:i64=Attempt(Dog[G[11]].Bark,-1)
        \\CatIsAnimal<public>:string=Attempt(Animal[G[11]].Name,"none")
        \\BotLegs<public>:i64=Attempt(Walker[G[12]].Legs(),-1)
        \\BotIsRobot<public>:i64=Attempt(Robot[G[12]].Legs(),-1)
        \\DogWalks<public>:i64=Attempt(Walker[C].Legs(),-1)
        \\AsPoint<public>:i64=Attempt(Point[D].Y,-1)
        \\AsColor<public>:Color=Attempt(Color[E],Color.Red)
        \\AsInts<public>:i64=Attempt(Ints[F].Length,-1)
        \\NotInts<public>:i64=Attempt(Ints[A].Length,-1)
        \\AsFloat<public>:float=Attempt(float[G[6]],0.0)
        \\AsLogic<public>:logic=Attempt(logic[G[7]],false)
        \\AsChar<public>:char=Attempt(char[G[8]],'x')
        \\AsOpt<public>:i64=Attempt(Opt[G[9]]?,-1)
        \\AsStep<public>:i64=Attempt(Step[G[10]](21),-1)
        \\AsPair<public>:string=Attempt(Pair[G[13]](1),"none")
        \\AsTable<public>:string=Attempt(Table[G[14]][1],"none")
        \\AsRational<public>:i64=Attempt(Floor(rational[G[15]]+rational[G[15]]),-1)
        \\Kind(V:any)<computes>:string=Case(V,N:i64=>"int",S:string=>"string",P:Point=>"point",L:Ints=>"ints",K:Dog=>"dog",W:Walker=>"walker",M:Animal=>"animal",_=>"other")
        \\Kinds<public>:[]string=For(V:G,Kind(V))
        \\Again<public>:i64=Attempt(i64[any(A)],-1)
        \\Count<public>:i64=G.Length
    );
    try expectInt(x, "AsInt", 5);
    try expectInt(x, "NotInt", -1);
    try expectText(x, "AsText", "text");
    try expectText(x, "NotText", "none");
    try expectInt(x, "AsDog", 3);
    try expectText(x, "AsAnimal", "rex");
    try expectInt(x, "CatIsDog", -1);
    try expectText(x, "CatIsAnimal", "animal");
    try expectInt(x, "BotLegs", 2);
    try expectInt(x, "BotIsRobot", 2);
    try expectInt(x, "DogWalks", -1);
    try expectInt(x, "AsPoint", 2);
    try std.testing.expectEqual(@as(u32, 1), x.get("AsColor").?.enumeration.index);
    try expectInt(x, "AsInts", 3);
    try expectInt(x, "NotInts", -1);
    try std.testing.expectEqual(@as(f64, 2.5), x.get("AsFloat").?.floating);
    try expectLogic(x, "AsLogic", true);
    try std.testing.expectEqual(@as(u32, 'c'), x.get("AsChar").?.enumeration.index);
    try expectInt(x, "AsOpt", 4);
    try expectInt(x, "AsStep", 42);
    try expectText(x, "AsPair", "a");
    try expectText(x, "AsTable", "x");
    try expectInt(x, "AsRational", 1);
    try expectInt(x, "Again", 5);
    try expectInt(x, "Count", 16);
    const expected = [_][]const u8{ "int", "string", "dog", "point", "other", "ints", "other", "other", "other", "other", "other", "animal", "walker", "other", "other", "other" };
    const kinds = x.elements(x.get("Kinds").?).?;
    try std.testing.expectEqual(expected.len, kinds.len);
    for (expected, kinds) |want, got| try std.testing.expectEqualStrings(want, got.string);
    // A value held as `any` is the value: no box, no node but the cast itself.
    const p = try h.compile("A:any=any(5)\nB:i64=Attempt(i64[A],0)");
    try std.testing.expectEqual(@as(usize, 1), count(p.nodes, "upcast"));
    try std.testing.expectEqual(@as(usize, 1), count(p.nodes, "instance_of"));
    try std.testing.expectEqual(@as(usize, 1), count(p.nodes, "downcast"));
    try std.testing.expectEqual(types.Type.any, p.nodes[p.bindings[0].node].value_type);
}

test "rfc0080 nothing converts to any implicitly and any has no operation but the cast" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "A:any=5", .type_mismatch, "5");
    try expectRefused(h, "F(X:any)<computes>:i64=1\nA:i64=F(5)", .type_mismatch, "5");
    try expectRefused(h, "F(X:i64)<computes>:any=X", .type_mismatch, "X");
    try expectRefused(h, "A:[]any=array{1,2}", .type_mismatch, "1");
    try expectRefused(h, "A:any=any(5)\nB:logic=A==A", .not_comparable, "==");
    try expectRefused(h, "A:any=any(5)\nB:logic=A!=A", .not_comparable, "!=");
    try expectRefused(h, "A:any=any(5)\nB:any=A+A", .type_mismatch, "+");
    try expectRefused(h, "A:any=any(5)\nB:logic=A<A", .type_mismatch, "<");
    try expectRefused(h, "A:any=any(5)\nB:string=\"{A}\"", .type_mismatch, "any");
    try expectRefused(h, "M:map(any,i64)=map{}", .invalid_map_key, "map");
    try expectRefused(h, "A:[]any=array{any(1)}\nB:i64=Attempt(A.Find[any(1)],0)", .not_comparable, "Find");
    try expectRefused(h, "Idx[K:comparable](X:K)<computes>:K{X}\nA:any=Idx[any](any(1))", .not_comparable, "Idx");
    // The cast can fail, so it needs a failure context; and it is a cast of a value of `any`.
    try expectRefused(h, "A:any=any(5)\nB:i64=i64[A]", .failure_context_required, "i64");
    try expectRefused(h, "P:=struct{X:i64}\nA:any=any(P{X:=1})\nB:P=P[A]", .failure_context_required, "P");
    try expectRefused(h, "A:i64=5\nB:i64=Attempt(i64[A],0)", .type_mismatch, "5");
    try expectRefused(h, "P:=struct{X:i64}\nQ:P=P{X:=1}\nB:P=Attempt(P[Q],Q)", .type_mismatch, "P{X:=1}");
    try expectRefused(h, "E:=enum{A,B}\nV:E=E.A\nW:E=Attempt(E[V],V)", .type_mismatch, "E.A");
    try expectRefused(h, "A:any=any(5)\nB:i64=Case(A,N:i64=>N)", .case_not_exhaustive, "N:i64");
    try expectRefused(h, "A:any=any()", .expected_expression, ")");
    try expectRefused(h, "A:any=any(1,2)", .argument_count, ",");
    // A class is not comparable through `any`, unique or not, and `any` is not a class.
    try expectRefused(h, "T:=class<unique>{}\nMk()<transacts>:T=T{}\nA:any=any(Mk())\nB:logic=A==A", .not_comparable, "==");
    try expectRefused(h, "A:any=any(5)\nC:=class(any){}", .invalid_parent, "any");
}

test "rfc0080 any is stored, passed, returned and rolled back like any value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(zoo ++
        \\var Held:any=any(1)
        \\var Log:[]any=array{}
        \\Box:=class{var Value:any=any("empty")}
        \\Keep(V:any)<transacts>:any=Block{Before:=Held;set Held=V;set Log=Log+array{V};Before}
        \\First<public>:i64=Attempt(i64[Keep(any("two"))],-1)
        \\Second<public>:string=Attempt(string[Keep(any(3.5))],"none")
        \\Undone<public>:i64=Attempt(Block{Keep(any(Color.Red));i64[Held]},-7)
        \\Now<public>:float=Attempt(float[Held],0.0)
        \\Length<public>:i64=Log.Length
        \\B:=Box{}
        \\Put(V:any)<transacts><decides>:i64=Block{set B.Value=V;i64[B.Value]}
        \\Wrote<public>:i64=Attempt(Put[any(9)],-1)
        \\Refused<public>:i64=Attempt(Put[any("no")],-1)
        \\Kept<public>:i64=Attempt(i64[B.Value],-1)
        \\Wrap[T:type](X:T)<computes>:any{any(X)}
        \\Open[T:type](X:any)<computes><decides>:T{T[X]}
        \\Trip<public>:i64=Attempt(Open[i64][Wrap[i64](11)],-1)
        \\Wrong<public>:string=Attempt(Open[string][Wrap[i64](11)],"wrong")
        \\Deep<public>:i64=Attempt(Open[Ints][Wrap[Ints](array{1,2})].Length,-1)
        \\Nested:map(string,[]any)=map{"k"=>array{any(1),any("s")}}
        \\Inner<public>:string=Attempt(string[Nested["k"][1]],"none")
        \\Shown:option(any)=option{any(Point{X:=4,Y:=5})}
        \\Seen<public>:i64=Attempt(Point[Shown?].X,-1)
        \\Pass:function(tuple(any),any)=Fn(V:any)<computes>:any{V}
        \\Through<public>:i64=Attempt(i64[Pass(any(8))],-1)
    );
    try expectInt(x, "First", 1);
    try expectText(x, "Second", "two");
    // The failed cast undid the write of `Held` and the append to `Log`.
    try expectInt(x, "Undone", -7);
    try std.testing.expectEqual(@as(f64, 3.5), x.get("Now").?.floating);
    try expectInt(x, "Length", 2);
    try expectInt(x, "Wrote", 9);
    try expectInt(x, "Refused", -1);
    try expectInt(x, "Kept", 9);
    try expectInt(x, "Trip", 11);
    try expectText(x, "Wrong", "wrong");
    try expectInt(x, "Deep", 2);
    try expectText(x, "Inner", "s");
    try expectInt(x, "Seen", 4);
    try expectInt(x, "Through", 8);
}

/// One forged program: both machines refuse it, or both run it to the same end.
fn attempt(h: *harness.Harness, p: types.Program, what: []const u8, index: usize, a: usize, counts: *[3]usize) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    if (reference == .failed and reference.failed.code == .invalid_ir) {
        const lowered = bytecode.lower(p, &h.runtime.instructions);
        if (lowered == .ok) {
            const actual = h.runtime.machine.run(lowered.ok, 100_000);
            if (actual != .failed or actual.failed.code != .invalid_bytecode) {
                std.debug.print("DIVERGE {s} node {d} with {d}: reference invalid_ir, vm {s}\n", .{ what, index, a, if (actual == .failed) @tagName(actual.failed.code) else "ok" });
                return error.TestUnexpectedResult;
            }
        }
        counts[0] += 1;
        return;
    }
    const result = h.run(p, 100_000) catch |err| {
        std.debug.print("FINDING {s} node {d} with {d}: {s}\n", .{ what, index, a, @errorName(err) });
        return err;
    };
    counts[if (result == .ok) 1 else 2] += 1;
}

test "rfc0080 forged casts to and from any are refused by both machines or run alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(zoo ++
        \\N:i64=5
        \\T:string="t"
        \\Fl:float=1.5
        \\Lg:logic=true
        \\Ch:char='a'
        \\Xs:Ints=array{1,2}
        \\Pt:Point=Point{X:=1,Y:=2}
        \\Co:Color=Color.Green
        \\Op:Opt=option{4}
        \\Pr:Pair=tuple{1,"a"}
        \\Tb:Table=map{1=>"x"}
        \\St:Step=Twice
        \\D:Dog=MkDog()
        \\An:Animal=MkCat()
        \\W:Walker=MkBot()
        \\A:any=any(N)
        \\B:any=any(D)
        \\C:any=any(Xs)
        \\Many:[]any=array{A,B,C}
        \\R1:i64=Attempt(i64[A],0)
        \\R2:string=Attempt(Animal[B].Name,"")
        \\R3:i64=Attempt(Ints[C].Length,0)
        \\R4:string=Case(A,V:string=>V,K:Dog=>"dog",_=>"other")
        \\R5:string=Attempt(Dog[An].Name,"")
    );
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 100_000);
    var seen: [128]types.Type = undefined;
    var seen_count: usize = 0;
    for ([_]types.Type{ types.Type.any, .i64, .logic, .string, .float, types.Type.char, types.Type.char32, @fromBackingInt(0xFF03), @fromBackingInt(4 + types.limits.user_types), @fromBackingInt(0xFFFF) }) |t| {
        seen[seen_count] = t;
        seen_count += 1;
    }
    for (p.nodes) |node| {
        var known = false;
        for (seen[0..seen_count]) |t| known = known or t == node.value_type;
        if (!known and seen_count < seen.len) {
            seen[seen_count] = node.value_type;
            seen_count += 1;
        }
    }
    var counts = [3]usize{ 0, 0, 0 };
    var casts: usize = 0;
    for (p.nodes, 0..) |node, index| {
        switch (node.kind) {
            .upcast, .downcast => {
                casts += 1;
                // Every earlier node as the operand, with every result type.
                for (0..index) |other| {
                    var changed = node;
                    if (node.kind == .upcast) changed.kind = .{ .upcast = @intCast(other) } else changed.kind = .{ .downcast = @intCast(other) };
                    nodes[index] = changed;
                    try attempt(h, forged, "operand", index, other, &counts);
                    changed.value_type = types.Type.any;
                    nodes[index] = changed;
                    try attempt(h, forged, "operand to any", index, other, &counts);
                    // The other cast of the same operand.
                    if (node.kind == .upcast) changed.kind = .{ .downcast = @intCast(other) } else changed.kind = .{ .upcast = @intCast(other) };
                    for ([_]types.Type{ node.value_type, types.Type.any, p.nodes[other].value_type }) |t| {
                        changed.value_type = t;
                        nodes[index] = changed;
                        try attempt(h, forged, "flipped", index, other, &counts);
                    }
                }
                for (seen[0..seen_count], 0..) |t, ti| {
                    var changed = node;
                    changed.value_type = t;
                    nodes[index] = changed;
                    try attempt(h, forged, "result type", index, ti, &counts);
                }
                // Its own node and a later one as the operand.
                for ([_]u32{ @intCast(index), @intCast(index + 1), std.math.maxInt(u32) }) |other| {
                    var changed = node;
                    if (node.kind == .upcast) changed.kind = .{ .upcast = other } else changed.kind = .{ .downcast = other };
                    nodes[index] = changed;
                    try attempt(h, forged, "forward", index, other, &counts);
                }
            },
            .instance_of => |test_of| {
                casts += 1;
                for (0..index) |other| {
                    var changed = node;
                    changed.kind = .{ .instance_of = .{ .value = @intCast(other), .class = test_of.class } };
                    nodes[index] = changed;
                    try attempt(h, forged, "tested value", index, other, &counts);
                    changed.kind.instance_of.class = p.nodes[other].value_type;
                    nodes[index] = changed;
                    try attempt(h, forged, "tested value as itself", index, other, &counts);
                }
                for (seen[0..seen_count], 0..) |t, ti| {
                    var changed = node;
                    changed.kind = .{ .instance_of = .{ .value = test_of.value, .class = t } };
                    nodes[index] = changed;
                    try attempt(h, forged, "tested type", index, ti, &counts);
                    changed.kind = .{ .instance_of = test_of };
                    changed.value_type = t;
                    nodes[index] = changed;
                    try attempt(h, forged, "test result type", index, ti, &counts);
                }
            },
            // Operations that an `any` operand must never reach.
            .compare, .binary, .to_string, .array_length, .field, .option_present, .map_lookup, .string_concat, .array_get => {
                for (p.bindings) |binding| {
                    if (p.nodes[binding.node].value_type != types.Type.any or binding.node >= index) continue;
                    var changed = node;
                    switch (changed.kind) {
                        .compare => |*c| c.lhs = binding.node,
                        .binary => |*c| c.lhs = binding.node,
                        .to_string => |*c| c.* = binding.node,
                        .array_length => |*c| c.* = binding.node,
                        .field => |*c| c.value = binding.node,
                        .option_present => |*c| c.* = binding.node,
                        .map_lookup => |*c| c.map = binding.node,
                        .string_concat => |*c| c.lhs = binding.node,
                        .array_get => |*c| c.array = binding.node,
                        else => unreachable,
                    }
                    nodes[index] = changed;
                    try harness.invalid(h, forged);
                    counts[0] += 1;
                    switch (changed.kind) {
                        .compare => |*c| c.rhs = binding.node,
                        .binary => |*c| c.rhs = binding.node,
                        .string_concat => |*c| c.rhs = binding.node,
                        .array_get => |*c| c.index = binding.node,
                        .map_lookup => |*c| c.key = binding.node,
                        else => {},
                    }
                    nodes[index] = changed;
                    try harness.invalid(h, forged);
                }
            },
            else => continue,
        }
        nodes[index] = node;
    }
    try std.testing.expect(casts >= 12);
    try std.testing.expect(counts[0] > 500 and counts[1] > 20);
    // A `downcast` without its guard: admitted, and trapped by both machines when it runs on a
    // value that is not of the type.
    for (p.nodes, 0..) |node, index| {
        if (node.kind != .downcast or p.nodes[node.kind.downcast].value_type != types.Type.any) continue;
        for (p.bindings) |binding| {
            if (p.nodes[binding.node].value_type != types.Type.any or binding.node >= index) continue;
            for ([_]types.Type{ .i64, .string, .float, .logic }) |t| {
                var changed = node;
                changed.kind = .{ .downcast = binding.node };
                changed.value_type = t;
                nodes[index] = changed;
                const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
                if (reference == .failed and reference.failed.code == .invalid_ir) {
                    const actual = h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, 100_000);
                    try std.testing.expectEqual(Code.invalid_bytecode, actual.failed.code);
                } else _ = try h.run(forged, 100_000);
            }
        }
        nodes[index] = node;
    }
}

/// What the model knows of a value: the one type it was made as, or the classes it is.
const Kind = enum { int, text, float, logic, char, ints, texts, point, color, opt, pair, table, step, rational, dog, cat, animal_plain, robot };
const targets = [_][]const u8{ "i64", "string", "float", "logic", "char", "Ints", "Texts", "Point", "Color", "Opt", "Pair", "Table", "Step", "rational", "Dog", "Cat", "Animal", "Robot", "Walker", "char32", "Wide" };

fn literal(kind: Kind) []const u8 {
    return switch (kind) {
        .int => "7",
        .text => "\"s\"",
        .float => "0.5",
        .logic => "true",
        .char => "'q'",
        .ints => "Xs",
        .texts => "Ws",
        .point => "Point{X:=1,Y:=2}",
        .color => "Color.Green",
        .opt => "Some",
        .pair => "tuple{1,\"a\"}",
        .table => "map{1=>\"x\"}",
        .step => "Twice",
        .rational => "Half",
        .dog => "MkDog()",
        .cat => "MkCat()",
        .animal_plain => "MkAnimal()",
        .robot => "MkBot()",
    };
}

/// The model: a value is of the type it was made as and of nothing else, except that an
/// instance is also of every class above its own and of every interface it implements.
fn modelIs(kind: Kind, target: usize) bool {
    const name = targets[target];
    const exact: ?[]const u8 = switch (kind) {
        .int => "i64",
        .text => "string",
        .float => "float",
        .logic => "logic",
        .char => "char",
        .ints => "Ints",
        .texts => "Texts",
        .point => "Point",
        .color => "Color",
        .opt => "Opt",
        .pair => "Pair",
        .table => "Table",
        .step => "Step",
        .rational => "rational",
        else => null,
    };
    if (exact) |own| return std.mem.eql(u8, own, name);
    const is_animal = std.mem.eql(u8, name, "Animal");
    return switch (kind) {
        .dog => is_animal or std.mem.eql(u8, name, "Dog"),
        .cat => is_animal or std.mem.eql(u8, name, "Cat"),
        .animal_plain => is_animal,
        .robot => std.mem.eql(u8, name, "Robot") or std.mem.eql(u8, name, "Walker"),
        else => unreachable,
    };
}

test "rfc0080 random casts out of any agree with a model of what each value is" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x80_0080);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const kinds = std.enums.values(Kind);
    var total: usize = 0;
    var held: usize = 0;
    for (0..40) |_| {
        source.clearRetainingCapacity();
        try source.appendSlice(std.testing.allocator, zoo ++
            \\Texts:=[]string
            \\Wide:=[][]i64
            \\MkAnimal()<transacts>:Animal=Animal{}
            \\Xs:Ints=array{1,2}
            \\Ws:Texts=array{"a"}
            \\Some:Opt=option{3}
            \\Half:rational=Attempt(Rational[1,2],MakeRationalFromInt(0))
            \\Is[T:type](V:any)<computes>:logic{Case(V,X:T=>true,_=>false)}
            \\
        );
        var chosen: [12]Kind = undefined;
        try source.appendSlice(std.testing.allocator, "Vs:[]any=array{");
        for (&chosen, 0..) |*kind, index| {
            kind.* = kinds[random.uintLessThan(usize, kinds.len)];
            try source.print(std.testing.allocator, "{s}any({s})", .{ if (index == 0) "" else ",", literal(kind.*) });
        }
        try source.appendSlice(std.testing.allocator, "}\n");
        var expected: [24]bool = undefined;
        var picked: [24]struct { value: usize, target: usize, form: u8 } = undefined;
        for (&picked, &expected, 0..) |*pick, *want, index| {
            pick.* = .{ .value = random.uintLessThan(usize, chosen.len), .target = random.uintLessThan(usize, targets.len), .form = random.uintLessThan(u8, 3) };
            // Half of the casts are aimed at a type the value has, so that both outcomes are common.
            if (random.boolean()) while (!modelIs(chosen[pick.value], pick.target)) {
                pick.target = random.uintLessThan(usize, targets.len);
            };
            want.* = modelIs(chosen[pick.value], pick.target);
            const target = targets[pick.target];
            switch (pick.form) {
                // The cast in a failure context, the type test of a `Case`, and both through a
                // generic function for which the type is a parameter.
                0 => try source.print(std.testing.allocator, "R{d}<public>:logic=Attempt(Block{{V:=Vs[{d}];{s}[V];true}},false)\n", .{ index, pick.value, target }),
                1 => try source.print(std.testing.allocator, "R{d}<public>:logic=Attempt(Case(Vs[{d}],X:{s}=>true,_=>false),false)\n", .{ index, pick.value, target }),
                else => try source.print(std.testing.allocator, "R{d}<public>:logic=Attempt(Is[{s}](Vs[{d}]),false)\n", .{ index, target, pick.value }),
            }
        }
        const x = h.execute(source.items) catch |err| {
            std.debug.print("{s}\n", .{source.items});
            return err;
        };
        var name: [8]u8 = undefined;
        for (expected, 0..) |want, index| {
            const got = x.get(try std.fmt.bufPrint(&name, "R{d}", .{index})).?.boolean;
            if (got != want) std.debug.print("R{d}: {} expected {}\n{s}\n", .{ index, got, want, source.items });
            try std.testing.expectEqual(want, got);
            total += 1;
            held += @intFromBool(want);
        }
    }
    // Both outcomes were exercised.
    try std.testing.expect(total == 960 and held > 300 and held < 800);
}

// ---- aliases of instantiations reached through a path

const kit =
    \\Kit<public>:=module{
    \\    Box<public>[T:type]:=class{Value<public>:T}
    \\    Pt<public>[T:type]:=struct{X:T}
    \\    Hidden[T:type]:=struct{X:T}
    \\    Make<public>[T:type](V:T)<transacts>:Box[T]{Box[T]{Value:=V}}
    \\}
;

test "rfc0080 an alias names an instantiation reached through a module path" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try bundleRuns(h,
        \\L:=import{"lib.forb"}
        \\Ints:=L.Kit.Box[i64]
        \\Pts<public>:=L.Kit.Pt[string]
        \\Nested:=L.Kit.Box[L.Kit.Pt[i64]]
        \\Mk(V:i64)<transacts>:Ints=L.Kit.Box[i64]{Value:=V}
        \\Mk2(V:i64)<transacts>:L.Kit.Box[i64]=L.Kit.Box[i64]{Value:=V}
        \\A<public>:i64=Mk(4).Value+Mk2(5).Value
        \\P:Pts=L.Kit.Pt[string]{X:="s"}
        \\B<public>:string=P.X
        \\Q:=L.Kit.Pt[i64]{X:=3}
        \\R:L.Kit.Pt[i64]=Q
        \\C<public>:i64=R.X
        \\S:Ints=Mk(1)
        \\T:=L.Kit.Box[i64][S]
        \\D<public>:i64=T.Value
        \\N:Nested=L.Kit.Make[L.Kit.Pt[i64]](Q)
        \\E<public>:i64=N.Value.X
        \\Same<public>:L.Kit.Box[i64]=S
    , kit);
    try expectInt(x, "A", 9);
    try expectText(x, "B", "s");
    try expectInt(x, "C", 3);
    try expectInt(x, "D", 1);
    try expectInt(x, "E", 3);
    // The alias is the instantiation itself, also at the end of a file without a newline.
    const y = try bundleRuns(h, "L:=import{\"lib.forb\"}\nA<public>:i64=L.V", "Kit<public>:=module{Pt<public>[T:type]:=struct{X:T}}\nP:Kit.Pt[i64]=Kit.Pt[i64]{X:=6}\nV<public>:i64=P.X\nLast:=Kit.Pt[i64]");
    try expectInt(y, "A", 6);
    // A template that is not exported, a value where a type is needed, and arguments that
    // the template refuses stay the errors they were.
    for ([_][]const u8{
        "L:=import{\"lib.forb\"}\nBad:=L.Kit.Hidden[i64]\nA:i64=1",
        "L:=import{\"lib.forb\"}\nBad:=L.Kit.Box[i64,i64]\nA:i64=1",
        "L:=import{\"lib.forb\"}\nBad:=L.Kit.Missing[i64]\nA:i64=1",
    }) |main| {
        const result = bundle(h, main, kit);
        if (result != .failed) {
            std.debug.print("compiled: {s}\n", .{main});
            return error.Compiled;
        }
    }
}

// ---- `ToArray`, `Concatenate()` and an empty first argument

test "rfc0080 ToArray converts a tuple explicitly and the place of a call types what it builds" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class{Name:string="animal"}
        \\Dog:=class(Animal){}
        \\Cat:=class(Animal){}
        \\MkD()<transacts>:Dog=Dog{Name:="d"}
        \\MkC()<transacts>:Cat=Cat{Name:="c"}
        \\var Calls:i64=0
        \\Tick(V:i64)<transacts>:i64=Block{set Calls=Calls*10+V;V}
        \\T:tuple(i64,i64,i64)=tuple{1,2,3}
        \\A<public>:[]i64=ToArray(T)
        \\B<public>:=ToArray(tuple{"a","b"})
        \\C<public>:[]i64=ToArray(tuple{})
        \\D:[]Animal=ToArray(tuple{MkD(),MkC()})
        \\Names<public>:string=Attempt(D[0].Name+D[1].Name,"none")
        \\E<public>:[]i64=Concatenate()
        \\F<public>:string=Join(array{},",")
        \\G<public>:[]i64=Concatenate(array{},A)
        \\H<public>:[]i64=Concatenate(array{A,A})
        \\I<public>:[]i64=Concatenate(ToArray(tuple{A,C,A}))
        \\J<public>:string=Concatenate()
        \\Sum(Xs:[]i64)<computes>:i64=Xs.Length
        \\K<public>:i64=Sum(Concatenate())*100+Sum(ToArray(tuple{}))*10+Sum(ToArray(tuple{5}))
        \\L<public>:[][]i64=ToArray(tuple{A,ToArray(tuple{9})})
        \\Order<public>:[]i64=ToArray(tuple{Tick(1),Tick(2),Tick(3)})
        \\Once<public>:i64=Calls
        \\M<public>:[]i64=A+ToArray(tuple{4})
        \\Words<public>:string=Join(ToArray(tuple{"x","y"}),"-")
    );
    const expectArray = struct {
        fn of(run: evaluator.Execution, name: []const u8, want: []const i64) !void {
            const got = run.elements(run.get(name).?).?;
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |a, b| try std.testing.expectEqual(a, b.integer);
        }
    }.of;
    try expectArray(x, "A", &.{ 1, 2, 3 });
    try expectArray(x, "C", &.{});
    try expectArray(x, "E", &.{});
    try expectArray(x, "G", &.{ 1, 2, 3 });
    try expectArray(x, "H", &.{ 1, 2, 3, 1, 2, 3 });
    try expectArray(x, "I", &.{ 1, 2, 3, 1, 2, 3 });
    try expectArray(x, "Order", &.{ 1, 2, 3 });
    try expectArray(x, "M", &.{ 1, 2, 3, 4 });
    try expectInt(x, "Once", 123);
    try expectInt(x, "K", 1);
    try expectText(x, "Names", "dc");
    try expectText(x, "F", "");
    try expectText(x, "J", "");
    try expectText(x, "Words", "x-y");
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("B").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("L").?).?.len);
    // The conversion adds no operation: element reads and one array.
    const p = try h.compile("T:tuple(i64,i64)=tuple{1,2}\nA:[]i64=ToArray(T)");
    try std.testing.expectEqual(@as(usize, 2), count(p.nodes, "tuple_element"));
    try std.testing.expectEqual(@as(usize, 2), count(p.nodes, "aggregate"));
    // Nothing converts a tuple implicitly, and the elements have one type.
    try expectRefused(h, "A:[]i64=tuple{1,2}", .type_mismatch, "tuple{1,2}");
    try expectRefused(h, "F(Xs:[]i64)<computes>:i64=Xs.Length\nA:i64=F(tuple{1,2})", .type_mismatch, "tuple{1,2}");
    try expectRefused(h, "A:=ToArray(tuple{1,\"a\"})", .type_mismatch, "ToArray");
    try expectRefused(h, "A:[]string=ToArray(tuple{1,2})", .type_mismatch, "ToArray");
    try expectRefused(h, "A:=ToArray(tuple{})", .array_type_required, "ToArray");
    try expectRefused(h, "A:=ToArray(array{1})", .type_mismatch, "array{1}");
    try expectRefused(h, "A:=ToArray(5)", .type_mismatch, "5");
    try expectRefused(h, "A:=Concatenate()", .array_type_required, "Concatenate");
    try expectRefused(h, "A:i64=Concatenate()", .array_type_required, "Concatenate");
    try refused(h, "A:[]i64=Concatenate(array{})", .array_type_required);
    // A program's own `ToArray` is the one that is meant.
    const own = try h.execute("ToArray(X:i64)<computes>:i64=X+1\nA<public>:i64=ToArray(4)");
    try expectInt(own, "A", 5);
}

// ---- `Case[...]` and unreachable arms

test "rfc0080 Case in brackets fails when no arm takes the value and undoes what its region wrote" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Color:=enum{Red,Green,Blue}
        \\Name(N:i64)<computes><decides>:string=Case[N,1=>"one",2=>"two"]
        \\A<public>:string=Attempt(Name[1],"none")
        \\B<public>:string=Attempt(Name[3],"none")
        \\Warm(C:Color)<computes><decides>:logic=Case[C,Color.Red=>true]
        \\D<public>:logic=Attempt(Warm[Color.Red],false)
        \\E<public>:logic=Attempt(Warm[Color.Blue],false)
        \\F<public>:i64=Attempt(Case["b","a"=>1,"b"=>2],0)
        \\G<public>:i64=Attempt(Case['z','a'=>1,'b'=>2],0)
        \\G2<public>:i64=Attempt(Case['b','a'=>1,'b'=>2],0)
        \\H<public>:i64=Attempt(Case[option{4},option{X} where X>5=>X,option{}=>0],-1)
        \\H2<public>:i64=Attempt(Case[option{9},option{X} where X>5=>X,option{}=>0],-1)
        \\I<public>:i64=Attempt(Case[tuple{1,2},tuple{1,Y}=>Y],-1)
        \\I2<public>:i64=Attempt(Case[tuple{3,2},tuple{1,Y}=>Y],-1)
        \\Animal:=class{}
        \\Dog:=class(Animal){Bark:i64=3}
        \\Cat:=class(Animal){}
        \\Mk()<transacts>:Animal=Dog{}
        \\J<public>:i64=Attempt(Case[Mk(),K:Dog=>K.Bark],-1)
        \\J2<public>:i64=Attempt(Case[Mk(),K:Cat=>1],-1)
        \\var Seen:i64=0
        \\Note(V:i64)<transacts>:i64=Block{set Seen=Seen+V;V}
        \\K<public>:i64=Attempt(Block{Note(5);Case[Note(7),1=>2]},-1)
        \\L<public>:i64=Seen
        \\K2<public>:i64=Attempt(Block{Note(5);Case[Note(7),7=>2]},-1)
        \\L2<public>:i64=Seen
        \\M<public>:i64=If(Case[3,1=>true,2=>false],1,0)
        \\S:string="b"
        \\N<public>:i64=Attempt(Case[S,"a"=>1,"b"=>Case[S.Length,1=>10]],0)
        \\N2<public>:i64=Attempt(Case[S,"a"=>1,"b"=>Case[S.Length,2=>10]],0)
        \\Any<public>:string=Attempt(Case[any(4),T:string=>T,V:i64=>"int"],"none")
        \\O<public>:option(i64)=option{Case[2,1=>5]}
        \\P<public>:[]i64=For(V:1..4,Case[V,2=>20,4=>40])
        \\Q<public>:i64=Attempt(Case[Color.Green,Color.Red=>1,Color.Green=>2,Color.Blue=>3],0)
    );
    try expectText(x, "A", "one");
    try expectText(x, "B", "none");
    try expectLogic(x, "D", true);
    try expectLogic(x, "E", false);
    try expectInt(x, "F", 2);
    try expectInt(x, "G", 0);
    try expectInt(x, "G2", 2);
    try expectInt(x, "H", -1);
    try expectInt(x, "H2", 9);
    try expectInt(x, "I", 2);
    try expectInt(x, "I2", -1);
    try expectInt(x, "J", 3);
    try expectInt(x, "J2", -1);
    // The failed `Case` undid the writes of its region, the scrutinee's included.
    try expectInt(x, "K", -1);
    try expectInt(x, "L", 0);
    try expectInt(x, "K2", 2);
    try expectInt(x, "L2", 12);
    try expectInt(x, "M", 0);
    try expectInt(x, "N", 10);
    try expectInt(x, "N2", 0);
    try expectText(x, "Any", "int");
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("O").?).?.len);
    const kept = x.elements(x.get("P").?).?;
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqual(@as(i64, 40), kept[1].integer);
    try expectInt(x, "Q", 2);
    // It is a failable form: it needs a failure context, and an arm that takes everything
    // would make it one that cannot fail.
    try expectRefused(h, "A:i64=Case[1,1=>2]", .failure_context_required, "Case");
    try expectRefused(h, "F(N:i64)<computes>:i64=Case[N,1=>2]", .failure_context_required, "Case");
    try expectRefused(h, "A:i64=Attempt(Case[1,1=>2,_=>3],0)", .case_cannot_fail, "_");
    try expectRefused(h, "A:i64=Attempt(Case[option{1},option{X}=>X,_=>3],0)", .case_cannot_fail, "_");
    try expectRefused(h, "A:i64=Attempt(Case[tuple{1,2},tuple{X,Y}=>X],0)", .case_cannot_fail, "tuple");
    try refused(h, "A:i64=Attempt(Case[1,1=>2),0)", .case_arms);
    try refused(h, "A:i64=Attempt(Case(1,1=>2],0)", .case_arms);
    try refused(h, "A:i64=Attempt(Case[1],0)", .case_arms);
    // `Case(...)` is as total as it was.
    try expectRefused(h, "A:i64=Case(1,1=>2)", .case_not_exhaustive, "Case");
    try expectRefused(h, "E:=enum{A,B}\nV:E=E.A\nW:i64=Case(V,E.A=>1)", .case_not_exhaustive, "Case");
}

test "rfc0080 in Case[...] an arm written like an unguarded arm before it is unreachable" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "A:i64=Attempt(Case[1,1=>2,1=>3],0)", .unreachable_arm, "1");
    try expectRefused(h, "S:string=\"a\"\nA:i64=Attempt(Case[S,\"a\"=>2,\"b\"=>3,\"a\"=>5],0)", .unreachable_arm, "\"a\"");
    try expectRefused(h, "E:=enum{A,B}\nV:E=E.A\nW:i64=Attempt(Case[V,E.A=>1,E.A=>2],0)", .unreachable_arm, "E");
    try expectRefused(h, "A:i64=Attempt(Case[option{1},option{}=>2,option{X} where X>3=>X,option{}=>3],0)", .unreachable_arm, "option");
    try expectRefused(h, "C:=class{}\nD:=class(C){}\nMk()<transacts>:C=D{}\nA:i64=Attempt(Case[Mk(),X:D=>2,Y:D=>3],0)", .unreachable_arm, "Y");
    try expectRefused(h, "A:i64=Attempt(Case[option{1},option{X} where X>3=>X,option{}=>2,option{} where true=>3],0)", .unreachable_arm, "option");
    // A guard on the earlier arm leaves the later one reachable; so does different text.
    const x = try h.execute(
        \\A<public>:i64=Attempt(Case[option{1},option{X} where X>3=>X,option{X} where X>0=>X+10,option{}=>2],0)
        \\B<public>:i64=Attempt(Case[2,1+1=>2,2=>3],0)
        \\C:=class{}
        \\D:=class(C){}
        \\Mk()<transacts>:C=D{}
        \\E<public>:i64=Attempt(Case[Mk(),X:D where false=>2,Y:D=>3],0)
        \\F<public>:i64=Attempt(Case[3,1=>2,3=>Case[3,1=>5,3=>6]],0)
    );
    try expectInt(x, "A", 11);
    try expectInt(x, "B", 2);
    try expectInt(x, "E", 3);
    try expectInt(x, "F", 6);
    // RFC-0090: `Case(...)` refuses a repeated arm too, where RFC-0050 let the first one win;
    // the first match still wins among arms that are written differently.
    try expectRefused(h, "A<public>:i64=Case(1,1=>2,1=>3,_=>4)", .unreachable_arm, "1");
    const kept = try h.execute("A<public>:i64=Case(1,1=>2,0+1=>3,_=>4)\nB<public>:i64=Case(option{1},option{}=>2,option{X}=>X,_=>4)");
    try expectInt(kept, "A", 2);
    try expectInt(kept, "B", 1);
}

// ---- Regressions found by the independent review

test "rfc0080 review: a path alias of an instantiation ends where its nested module ends" {
    const h = try harness.create();
    defer scratch.release(h);
    const box_kit = "Kit<public>:=module{Box<public>[T:type]:=class{V<public>:T}}";
    for ([_][]const u8{
        "L:=import{\"lib.forb\"}\nM:=module{Ints<public>:=L.Kit.Box[i64]\n}\nX:M.Ints=L.Kit.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "L:=import{\"lib.forb\"}\nM:=module{Ints<public>:=L.Kit.Box[i64]}\nX:M.Ints=L.Kit.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "L:=import{\"lib.forb\"}\nInts:=L.Kit.Box[i64];X:Ints=L.Kit.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "K:=module{Box<public>[T:type]:=class{V<public>:T}}\nM:=module{Ints<public>:=K.Box[i64]}\nX:M.Ints=K.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "K:=module{Box<public>[T:type]:=class{V<public>:T}}\nM:=module{Ints<public>:=K.Box[i64]\n}\nX:M.Ints=K.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "M:=module{Box<public>[T:type]:=class{V<public>:T}\nInts<public>:=Box[i64]}\nX:M.Ints=M.Box[i64]{V:=3}\nA<public>:i64=X.V",
        "L:=import{\"lib.forb\"}\nM:=module{B<public>:=L.Kit.Box[i64]}\nX:M.B=L.Kit.Box[i64]{V:=3}\nA<public>:i64=X.V",
    }) |main| {
        const x = try bundleRuns(h, main, box_kit);
        try expectInt(x, "A", 3);
    }
}

test "rfc0080 review: a Case[...] arm whose type tests the static types decide is case_cannot_fail" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "V:any=any(5)\nA:i64=Attempt(Case[V,N:i64=>N,X:any=>0],1)", .case_cannot_fail, "X:any");
    try expectRefused(h, "T:tuple(i64,string)=tuple{1,\"a\"}\nA:i64=Attempt(Case[T,tuple{N:i64,S:string}=>N],1)", .case_cannot_fail, "tuple{N:i64,S:string}");
    try expectRefused(h, "N:i64=3\nA:i64=Attempt(Case[N,M:i64=>M],1)", .case_cannot_fail, "M:i64");
    try expectRefused(h, "C:=class{}\nD:=class(C){}\nMk()<transacts>:D=D{}\nA:i64=Attempt(Case[Mk(),X:C=>1],0)", .case_cannot_fail, "X:C");
    try expectRefused(h, "P:=struct{X:i64}\nQ:P=P{X:=1}\nA:i64=Attempt(Case[Q,P{X:=N}=>N],0)", .case_cannot_fail, "P{X:=N}");
    // Per argument list of a generic function, as every check of its body.
    try expectRefused(h, "Same[T:type](W:T)<computes><decides>:i64{Case[W,X:i64=>1]}\nD:i64=Attempt(Same[i64][1],0)", .case_cannot_fail, "X:i64");
    // A test the types do not decide, or a guard, leaves the form able to fail.
    const x = try h.execute(
        \\V:any=any(5)
        \\A<public>:i64=Attempt(Case[V,N:i64=>N,S:string=>0],1)
        \\T:tuple(any,string)=tuple{any(1),"a"}
        \\B<public>:i64=Attempt(Case[T,tuple{N:i64,S:string}=>N],7)
        \\Is[T2:type](W:any)<computes><decides>:i64{Case[W,X:T2=>1]}
        \\C<public>:i64=Attempt(Is[i64][V],0)+Attempt(Is[string][V],0)*10
        \\Q:i64=3
        \\D<public>:i64=Attempt(Case[Q,M:i64 where M>5=>M],-1)
        \\E<public>:i64=Attempt(Case[any("s"),N:i64=>N],-2)
    );
    try expectInt(x, "A", 5);
    try expectInt(x, "B", 1);
    try expectInt(x, "C", 1);
    try expectInt(x, "D", -1);
    try expectInt(x, "E", -2);
}

test "rfc0080 review: a type name declared further down means that declaration in templates and functions alike" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "F(X:i64)<computes>:void=X\nvoid:=struct{N:i64}", .unsupported_type, "void");
    try expectRefused(h, "F[T:type](X:T)<computes>:void{X}\nA:void=F[i64](1)\nvoid:=struct{N:i64}", .unsupported_type, "void");
    try expectRefused(h, "F(X:any)<computes>:i64=1\nany:=struct{N:i64}", .unsupported_type, "any");
    try expectRefused(h, "F[T:type](X:any)<computes>:T{T[X]}\nA:i64=Attempt(F[i64][any(1)],0)\nany:=struct{N:i64}", .unsupported_type, "any");
    // Declared above, the program's own type is meant in both.
    const x = try h.execute("void:=struct{N:i64}\nF(X:i64)<computes>:void=void{N:=X}\nG[T:type](X:i64)<computes>:void{void{N:=X+1}}\nA<public>:i64=F(1).N+G[i64](1).N*10");
    try expectInt(x, "A", 21);
}

test "rfc0080 review: deep values of any survive many frames and reclamation" {
    const h = try harness.create();
    defer scratch.release(h);
    const deep = "Wrap(S:any)<computes>:any=Block{D:=tuple{1,2};any(array{S,any(D)})}\nDeep<public>:any=Iterate(Wrap,200,any(0))";
    const many = "Wrap(S:any)<computes>:any=Block{D:=tuple{1,2};any(array{S})}\nUse(N:i64)<computes>:i64=Block{X:=Iterate(Wrap,N,any(0));N}\nStep(S:i64)<computes>:i64=S+Use(500)\nT<public>:i64=Iterate(Step,3,0)";
    try std.testing.expect(try h.run(try h.compile(deep), 1 << 20) == .ok);
    // A full trace records every call; at the bootstrap profile 1500 calls pass its bound
    // whatever the values are, `any` or not, and the run stops loudly. Digest and off runs
    // below take them at every profile.
    const full = try h.run(try h.compile(many), 1 << 20);
    const plain = try h.run(try h.compile("Wrap(S:[]i64)<computes>:[]i64=Block{D:=tuple{1,2};array{S.Length}}\nUse(N:i64)<computes>:i64=Block{X:=Iterate(Wrap,N,array{0});N}\nStep(S:i64)<computes>:i64=S+Use(500)\nT<public>:i64=Iterate(Step,3,0)"), 1 << 20);
    if (full == .ok) {
        try std.testing.expect(plain == .ok);
    } else {
        try std.testing.expect(full.failed.code == .call_trace_limit);
        try std.testing.expect(plain == .failed and plain.failed.code == .call_trace_limit);
    }
    for ([_]types.TraceMode{ .digest, .off }) |mode| {
        h.control.trace = mode;
        h.runtime.machine.control.trace = mode;
        h.control.reclaim_floor = 0;
        h.runtime.machine.control.reclaim_floor = 0;
        defer {
            h.control.trace = .full;
            h.runtime.machine.control.trace = .full;
            h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
            h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        }
        for ([_][]const u8{ deep, many }) |source| {
            const q = try h.compile(source);
            const r = evaluator.evaluateWithRuntimeStorage(q, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 20);
            const a = h.runtime.evaluate(q, 1 << 20);
            try std.testing.expect(r == .ok and a == .ok);
            try std.testing.expectEqual(r.ok.reclaims, a.ok.reclaims);
            try std.testing.expectEqual(r.ok.aggregate_values.len, a.ok.aggregate_values.len);
            for (r.ok.aggregate_values, a.ok.aggregate_values) |x, y| try std.testing.expectEqualDeep(x, y);
        }
        const p = try h.compile("P:=struct{X:i64}\nvar Held:[]any=array{}\nStep(S:i64)<transacts>:i64=Block{set Held=array{any(P{X:=S}),any(array{S})};S+1}\nT<public>:i64=Iterate(Step,300,0)\nLast<public>:i64=Attempt(P[Held[0]].X,-1)");
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 20);
        const actual = h.runtime.evaluate(p, 1 << 20);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqual(@as(i64, 299), reference.ok.get("Last").?.integer);
        try std.testing.expectEqual(@as(i64, 299), actual.ok.get("Last").?.integer);
        try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
        try std.testing.expect(actual.ok.reclaims > 0);
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try std.testing.expectEqualDeep(a, b);
    }
}

/// The review's sweep: one forged program per typed slot of a compiled program set to `any`.
fn sweepAttempt(h: *harness.Harness, p: types.Program, what: []const u8, index: usize, counts: *[3]usize) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    if (reference == .failed and reference.failed.code == .invalid_ir) {
        const lowered = bytecode.lower(p, &h.runtime.instructions);
        if (lowered == .ok) {
            const actual = h.runtime.machine.run(lowered.ok, 100_000);
            if (actual != .failed or actual.failed.code != .invalid_bytecode) {
                std.debug.print("DIVERGE {s} {d}: reference invalid_ir, vm {s}\n", .{ what, index, if (actual == .failed) @tagName(actual.failed.code) else "ok" });
                return error.TestUnexpectedResult;
            }
        }
        counts[0] += 1;
        return;
    }
    const result = h.run(p, 100_000) catch |err| {
        std.debug.print("FINDING {s} {d}: {s}\n", .{ what, index, @errorName(err) });
        return err;
    };
    counts[if (result == .ok) 1 else 2] += 1;
}

test "rfc0080 review: any forged into every typed slot is refused by both machines or run alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Animal:=class{Name:string="animal"}
        \\Dog:=class(Animal){Bark:i64=3}
        \\Point:=struct{X:i64,Y:i64}
        \\Ints:=[]i64
        \\Mk()<transacts>:Dog=Dog{}
        \\var Held:any=any(1)
        \\var Count:i64=0
        \\Keep(V:any)<transacts>:any=Block{B:=Held;set Held=V;set Count=Count+1;B}
        \\Kind(V:any)<computes>:string=Case(V,N:i64=>"i",S:string=>S+"!",P:Point=>"p",_=>"o")
        \\Len(V:any)<computes><decides>:i64=Ints[V].Length
        \\Twice(N:i64)<computes>:i64=N*2
        \\A<public>:i64=Attempt(i64[Keep(any(5))],-1)
        \\B<public>:string=Kind(any("s"))+Kind(any(Point{X:=1,Y:=2}))+Kind(Held)
        \\C<public>:i64=Attempt(Len[any(array{1,2,3})],-1)+Attempt(Len[any(1)],-10)
        \\Xs:[]any=array{any(1),any("t"),any(Mk()),any(Twice),any(option{2}),any(tuple{1,"a"}),any(2.5),any('c')}
        \\D<public>:[]string=For(V:Xs,Kind(V))
        \\E<public>:i64=Attempt(Dog[Xs[2]].Bark,-1)
        \\M:map(string,any)=map{"a"=>any(1)}
        \\F<public>:i64=Attempt(i64[M["a"]],-1)
        \\G<public>:i64=Count
        \\H<public>:string=ToString(Twice(2))+"x"
        \\I<public>:logic=Point{X:=1,Y:=2}==Point{X:=1,Y:=3}
        \\J<public>:[]i64=array{1,2}+array{3}
        \\K<public>:i64=Or(Lookup(map{1=>2},1),0)
    );
    _ = try h.run(p, 100_000);
    const allocator = std.testing.allocator;
    const nodes = try allocator.dupe(types.Node, p.nodes);
    defer allocator.free(nodes);
    const body = try allocator.dupe(types.FunctionNode, p.function_nodes);
    defer allocator.free(body);
    const functions = try allocator.dupe(types.RuntimeFunction, p.functions);
    defer allocator.free(functions);
    const cells = try allocator.dupe(types.SourceCell, p.source_cells);
    defer allocator.free(cells);
    const definitions = try allocator.dupe(types.Definition, p.definitions);
    defer allocator.free(definitions);
    const elements = try allocator.dupe(types.Type, p.tuple_elements);
    defer allocator.free(elements);
    const fields = try allocator.dupe(types.Field, p.fields);
    defer allocator.free(fields);
    var forged = p;
    forged.nodes = nodes;
    forged.function_nodes = body;
    forged.functions = functions;
    forged.source_cells = cells;
    forged.definitions = definitions;
    forged.tuple_elements = elements;
    forged.fields = fields;
    var counts = [3]usize{ 0, 0, 0 };
    const any = types.Type.any;
    for (nodes, 0..) |node, i| {
        if (node.value_type == any) continue;
        nodes[i].value_type = any;
        try sweepAttempt(h, forged, "root node", i, &counts);
        nodes[i] = node;
    }
    for (body, 0..) |entry, i| {
        if (entry.node.value_type == any) continue;
        body[i].node.value_type = any;
        try sweepAttempt(h, forged, "function node", i, &counts);
        body[i] = entry;
    }
    for (functions, 0..) |f, i| {
        for (0..f.parameter_count) |k| {
            functions[i].parameters[k] = any;
            try sweepAttempt(h, forged, "parameter", i * 100 + k, &counts);
            functions[i] = f;
        }
        functions[i].value_type = any;
        try sweepAttempt(h, forged, "result", i, &counts);
        functions[i] = f;
    }
    for (cells, 0..) |c, i| {
        cells[i].value_type = any;
        try sweepAttempt(h, forged, "cell", i, &counts);
        cells[i] = c;
    }
    for (definitions, 0..) |d, i| {
        switch (d) {
            .array => definitions[i] = .{ .array = any },
            .option => definitions[i] = .{ .option = any },
            .map => |m| definitions[i] = .{ .map = .{ .key = m.key, .value = any } },
            else => continue,
        }
        try sweepAttempt(h, forged, "definition", i, &counts);
        if (d == .map) {
            definitions[i] = .{ .map = .{ .key = any, .value = d.map.value } };
            try sweepAttempt(h, forged, "map key", i, &counts);
        }
        definitions[i] = d;
    }
    for (elements, 0..) |e, i| {
        elements[i] = any;
        try sweepAttempt(h, forged, "tuple element", i, &counts);
        elements[i] = e;
    }
    for (fields, 0..) |f, i| {
        fields[i].value_type = any;
        try sweepAttempt(h, forged, "field", i, &counts);
        fields[i] = f;
    }
    // Most forgeries are refused at admission; the rest run alike (or fail alike) in both.
    try std.testing.expect(counts[0] > 150);
}

test "rfc0080 merge: a function held as any keeps the function type it was used at (RFC-0078)" {
    const h = try harness.create();
    defer scratch.release(h);
    // An upcast to a function type that allows more effects retypes the function value; an
    // upcast to `any` must not, or the cast back could never find the type it was held at.
    const x = try h.execute(
        \\var C:i64=4
        \\Peek()<reads>:i64=C
        \\W:function<transacts>(tuple(),i64)=Peek
        \\A:any=any(W)
        \\B:any=any(Peek)
        \\Wide(V:any)<transacts>:i64=Case(V,F:function<transacts>(tuple(),i64)=>F(),_=>-1)
        \\Narrow(V:any)<transacts>:i64=Case(V,F:function<reads>(tuple(),i64)=>F(),_=>-1)
        \\WideBack<public>:i64=Wide(A)
        \\WideNotNarrow<public>:i64=Narrow(A)
        \\NarrowBack<public>:i64=Narrow(B)
        \\NarrowIsWide<public>:i64=Wide(B)
    );
    try expectInt(x, "WideBack", 4);
    try expectInt(x, "WideNotNarrow", -1);
    try expectInt(x, "NarrowBack", 4);
    // RFC-0081: a function is also of every function type that allows more effects, so the
    // narrower function held as `any` comes out at the wider type too.
    try expectInt(x, "NarrowIsWide", 4);
}
