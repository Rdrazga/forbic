//! `For` carries the `var` locals of the code around it that its clauses and body assign
//! (RFC-0064, "Assigned locals"), as `While` and `Loop{}` do: through every lowering, with an
//! iteration that fails putting back what it assigned.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    if (expected.len != elements.len) std.debug.print("{s}: {d} elements, expected {d}\n", .{ name, elements.len, expected.len });
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    try std.testing.expect(r.failed.span.end <= source.len);
}

const prelude = "Xs:[]i64=array{1,2,3,4}\nM:map(string,i64)=map{\"a\"=>5,\"b\"=>7}\n";

test "a For body assigns the locals around it in every form of RFC-0056" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        // The value of the loop is still the array of its bodies.
        "Sum()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T});T}\n" ++
        "Run()<transacts>:[]i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T})}\n" ++
        "Kept()<transacts>:[]i64=Block{var T:i64=0;For(X:Xs,X>1,X<4,Block{set T=T+X;T})}\n" ++
        "Places()<transacts>:i64=Block{var T:i64=0;For(I->X:Xs,Block{set T=T*10+I;X});T}\n" ++
        "Odd()<transacts>:i64=Block{var T:i64=0;For(I->X:Xs,I!=1,Block{set T=T*10+X;X});T}\n" ++
        "Keys()<transacts>:i64=Block{var T:i64=0;var N:i64=0;For(K->V:M,Block{set T=T+V;set N=N+K.Length;V});T*10+N}\n" ++
        "A<public>:i64=Sum()\nB<public>:[]i64=Run()\nC<public>:[]i64=Kept()\nD<public>:i64=Places()\nE<public>:i64=Odd()\nF<public>:i64=Keys()\n");
    try expectInt(x, "A", 10);
    try expectIntegers(x, "B", &.{ 1, 3, 6, 10 });
    try expectIntegers(x, "C", &.{ 2, 5 });
    try expectInt(x, "D", 123);
    try expectInt(x, "E", 134);
    try expectInt(x, "F", 122);
}

test "a general For carries locals through its generators, ranges, bindings and filters" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        // Two generators: the inner level starts from what the outer one has and hands it back.
        "Pairs()<transacts>:i64=Block{var T:i64=0;var N:i64=0;Ys:=For(X:Xs,Y:1..X,Block{set T=T+Y;set N=N+1;X*Y});T*1000+N*10+Ys.Length}\n" ++
        "Range()<transacts>:i64=Block{var T:i64=1;For(I:1..5,Block{set T=T*I;I});T}\n" ++
        "Bound()<transacts>:i64=Block{var T:i64=0;For(X:Xs,D:=X*2,D>2,Block{set T=T+D;D});T}\n" ++
        // A clause may assign too. A filter that fails undoes what its iteration assigned, its
        // own count included, so this counts the elements it kept.
        "Seen()<transacts>:i64=Block{var N:i64=0;Ys:=For(X:Xs,Block{set N=N+1;X>2},X);N*10+Ys.Length}\n" ++
        "Three()<transacts>:i64=Block{var T:i64=0;For(A:1..2,B:1..2,C:1..2,Block{set T=T+A*B*C;T});T}\n" ++
        "A<public>:i64=Pairs()\nB<public>:i64=Range()\nC<public>:i64=Bound()\nD<public>:i64=Seen()\nE<public>:i64=Three()\n");
    // Y runs to X: 1 + 3 + 6 + 10 = 20 over ten pairs.
    try expectInt(x, "A", 20110);
    try expectInt(x, "B", 120);
    try expectInt(x, "C", 18);
    try expectInt(x, "D", 22);
    try expectInt(x, "E", 27);
}

test "an iteration that fails puts back the locals it assigned" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++ "var Seen:i64=0\n" ++
        // `Xs[X]` fails for X = 4: that iteration contributes nothing and its `set` is undone.
        "Skip()<transacts>:i64=Block{var T:i64=0;Ys:=For(X:Xs,Block{set T=T+X;Xs[X];X});T*10+Ys.Length}\n" ++
        // The filter runs after the assignment of its own iteration.
        "Late()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;true},X!=2,X);T}\n" ++
        // An inner level that fails as a whole undoes what its iterations assigned.
        "Inner()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Y:1..2,Block{set T=T+1;Require[not (X==3 and Y==2)];Y});T}\n" ++
        "Cells()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;set Seen=Seen+1;Require[X!=2];X});T*10+Seen}\n" ++
        "A<public>:i64=Skip()\nB<public>:i64=Late()\nC<public>:i64=Inner()\nD<public>:i64=Cells()\n");
    try expectInt(x, "A", 63);
    try expectInt(x, "B", 8);
    // Eight pairs, one of which fails.
    try expectInt(x, "C", 7);
    // The cell is rolled back with the local: three iterations count.
    try expectInt(x, "D", 83);
}

test "a For that something leaves early carries its locals to the exit and past the loop" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        "Find(K:i64)<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;If(X==K,Return(T*100),false)});T}\n" ++
        "Stop(K:i64)<transacts>:i64=Block{var T:i64=0;Loop{For(X:Xs,Block{set T=T+X;If(T>K,Break(),false)});Break()};T}\n" ++
        "Deep(K:i64)<transacts>:i64=Block{var T:i64=0;var N:i64=0;For(X:Xs,Y:1..X,Block{set N=N+1;set T=T+Y;If(N==K,Return(T*100+N),false)});T}\n" ++
        "Miss(K:i64)<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;Xs[X];If(X==K,Return(-1),false)});T}\n" ++
        "A<public>:i64=Find(3)\nB<public>:i64=Find(9)\nC<public>:i64=Stop(4)\nD<public>:i64=Stop(99)\nE<public>:i64=Deep(4)\nF<public>:i64=Deep(99)\nG<public>:i64=Miss(9)\n");
    try expectInt(x, "A", 600);
    try expectInt(x, "B", 10);
    // 1 + 2 + 3 exceeds 4: the `Break` leaves the `Loop{}` with what the loop had then.
    try expectInt(x, "C", 6);
    try expectInt(x, "D", 10);
    // The fourth pair is X = 3, Y = 1: T is 1 + 1 + 2 + 1.
    try expectInt(x, "E", 504);
    try expectInt(x, "F", 20);
    // The iteration of X = 4 fails at the index and its assignment is undone.
    try expectInt(x, "G", 6);
}

test "a path assignment in a For updates a local array, map or record of the code around it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        "P:=struct{X:i64=0\nY:i64=0}\n" ++
        "Fill()<transacts>:[]i64=Block{var Ys:[]i64=array{0,0,0,0};For(I->X:Xs,Block{set Ys[I]=X*2;I});Ys}\n" ++
        "Count()<transacts>:i64=Block{var Seen:map(i64,i64)=map{};For(X:Xs,Y:Xs,Block{set Seen[X+Y]=X;X});Seen.Length}\n" ++
        "Move()<transacts>:i64=Block{var At:P=P{};For(X:Xs,Block{set At.X=At.X+X;set At.Y=X;X});At.X*10+At.Y}\n" ++
        "A<public>:[]i64=Fill()\nB<public>:i64=Count()\nC<public>:i64=Move()\n");
    try expectIntegers(x, "A", &.{ 2, 4, 6, 8 });
    try expectInt(x, "B", 7);
    try expectInt(x, "C", 104);
    // The compile that finds that the four assignments update nothing notes all of them at
    // once; the others fetch the templates and the words of the loops, as for any general `For`.
    try std.testing.expectEqual(@as(u32, 4), h.front.carry_site_count);
    if (h.front.passes > 5) std.debug.print("passes: {d}\n", .{h.front.passes});
    try std.testing.expect(h.front.passes <= 5);
}

test "a For that assigns nothing of the code around it compiles as it did" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // A cell, a local of the body and an instance are assigned as before: none is carried, so
    // the block has no carrying templates and the loop its established lowering.
    const source = prelude ++ "var Cell:i64=0\nBox:=class{var N:i64=0}\nB:Box=Box{}\n" ++
        "Add()<transacts>:[]i64=For(X:Xs,Block{set Cell=Cell+X;var L:i64=X;set L=L+1;set B.N=B.N+X;L})\n" ++
        "A<public>:[]i64=Add()\nC<public>:i64=Cell\nD<public>:i64=B.N\n";
    const program = try h.compile(source);
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    try std.testing.expectEqualDeep(macros.Extension{}, h.front.library_extension[0]);
    try std.testing.expectEqual(source.len + macros.libraryLength(1, .{}), program.source.len);
    const x = (try h.run(program, 131072)).ok;
    try expectIntegers(x, "A", &.{ 2, 3, 4, 5 });
    try expectInt(x, "C", 10);
    try expectInt(x, "D", 10);
    // A loop that carries a local gets the general templates and the carrying ones, in one
    // request, and nothing else.
    const carrying = prelude ++ "Sum()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T});T}\nA<public>:i64=Sum()\n";
    const carried = try h.compile(carrying);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    try std.testing.expectEqualDeep(macros.Extension{ .loops = true, .carries = true }, h.front.library_extension[0]);
    try std.testing.expect(std.mem.endsWith(u8, carried.source, macros.carry_text[macros.carry_text.len - 1] ++ "\n#}"));
}

test "what a For cannot assign is refused as it was" {
    const h = try harness.create();
    defer scratch.release(h);
    // An immutable binding, a parameter and a name that is not declared at all.
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{T:=0;For(X:Xs,Block{set T=T+X;T});T}\nA<public>:i64=F()", .not_mutable);
    try expectCode(h, prelude ++ "F(T:i64)<transacts>:i64=Block{For(X:Xs,Block{set T=T+X;T});T}\nA<public>:i64=F(1)", .not_mutable);
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{For(X:Xs,Block{set Nope=X;X});1}\nA<public>:i64=F()", .unknown_name);
    // A path assignment to an immutable array, in a loop and outside one: noted once, compiled
    // again, refused for good.
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{Ys:=array{0,0};For(I->X:Xs,Block{set Ys[0]=X;X});1}\nA<public>:i64=F()", .not_mutable);
    try std.testing.expect(h.front.passes <= 4);
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{Ys:=array{0,0};Attempt(Block{set Ys[0]=1;1},0)}\nA<public>:i64=F()", .not_mutable);
    try std.testing.expect(h.front.passes <= 2);
    // Mutable locals need `writes`, in a loop as anywhere.
    try expectCode(h, prelude ++ "F()<computes>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T});T}\nA<public>:i64=F()", .local_var_requires_writes);
    // The generated names stay out of reach.
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;__for_q(0)});T}\nA<public>:i64=F()", .unknown_name);
    try expectCode(h, prelude ++ "F()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+__s(0);T});T}\nA<public>:i64=F()", .unknown_name);
}

test "loops nest: For in While, While in For and For in For share the locals they assign" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        "A1()<transacts>:i64=Block{var T:i64=0;var I:i64=0;While(I<3,Block{For(X:Xs,Block{set T=T+X;X});set I=I+1});T}\n" ++
        "A2()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{var I:i64=0;While(I<X,Block{set T=T+1;set I=I+1});I});T}\n" ++
        "A3()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{For(Y:Xs,Y<X,Block{set T=T+Y;Y});set T=T+100;X});T}\n" ++
        "A4()<transacts>:i64=Block{var T:i64=0;For(X:Xs,For(Y:Xs,Block{set T=T+1;Y}).Length);T}\n" ++
        "A<public>:i64=A1()\nB<public>:i64=A2()\nC<public>:i64=A3()\nD<public>:i64=A4()\n");
    try expectInt(x, "A", 30);
    try expectInt(x, "B", 10);
    // 0 + 1 + (1+2) + (1+2+3) and a hundred for each of four elements.
    try expectInt(x, "C", 410);
    try expectInt(x, "D", 16);
}

test "a bundle's modules each carry what their own loops need" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"sum.forb\"}\nP:=import{\"plain.forb\"}\nA<public>:i64=L.Sum(P.Twice())" },
        .{ .path = "sum.forb", .source = "Sum<public>(Xs:[]i64)<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T});T}" },
        .{ .path = "plain.forb", .source = "Xs:[]i64=array{4,5}\nTwice<public>()<computes>:[]i64=For(X:Xs,X*2)" },
    };
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |program| program,
        .failed => |problem| {
            std.debug.print("bundle: {s}:{d}: {s}\n", .{ problem.path, problem.diagnostic.span.start, problem.diagnostic.message() });
            return error.Compile;
        },
    };
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, program.source, "#" ++ macros.carry_text[0] ++ "\n"));
    var total: usize = 0;
    for (inputs) |input| total += input.source.len;
    // The modules are joined by a newline each.
    try std.testing.expectEqual(total + inputs.len - 1 + macros.libraryLength(1, .{ .loops = true, .carries = true }) + macros.libraryLength(1, .{}), program.source.len);
    const x = (try h.run(program, 1 << 20)).ok;
    try expectInt(x, "A", 18);
}

test "random loops that assign, filter and fail agree with a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xf07a55);
    const random = prng.random();
    var buffer: [2048]u8 = undefined;
    for (0..40) |_| {
        // Items in 0..9, a filter threshold, an index limit that makes some iterations fail
        // after they have assigned, and optionally an element that ends the loop by `Return`.
        var items: [8]i64 = undefined;
        const count = random.intRangeAtMost(usize, 0, items.len);
        for (items[0..count]) |*item| item.* = random.intRangeAtMost(i64, 0, 9);
        const threshold = random.intRangeAtMost(i64, 0, 9);
        const limit = random.intRangeAtMost(i64, 1, 10);
        const stop: i64 = if (random.boolean()) random.intRangeAtMost(i64, 0, 9) else -1;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Xs:[]i64=array{");
        for (items[0..count], 0..) |item, index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", item });
        try out.writeAll("}\nTen:[]i64=array{0,0,0,0,0,0,0,0,0,0}\n");
        try out.print("Go()<transacts>:i64=Block{{var T:i64=0;var N:i64=0;For(I->X:Xs,X>={d},Block{{set T=T+X;set N=N+1;Ten[X+{d}];If(X=={d},Return(T*1000+N+500000),false);I}});T*1000+N}}\nA<public>:i64=Go()\n", .{ threshold, 10 - limit, stop });
        // The model: an element below the threshold is filtered before it assigns; one whose
        // index into `Ten` is out of range fails after assigning and is undone; `stop` returns.
        var total: i64 = 0;
        var kept: i64 = 0;
        var expected: ?i64 = null;
        for (items[0..count]) |item| {
            if (item < threshold) continue;
            if (item + 10 - limit > 9) continue;
            total += item;
            kept += 1;
            if (item == stop) {
                expected = total * 1000 + kept + 500000;
                break;
            }
        }
        const x = try h.execute(out.buffered());
        expectInt(x, "A", expected orelse total * 1000 + kept) catch |err| {
            std.debug.print("program: {s}\n", .{out.buffered()});
            return err;
        };
    }
}

/// Where the diagnostic of `source` points, as text.
fn expectAt(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, column_text: []const u8, occurrence: usize) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    // The `occurrence`-th place the text is written.
    var at: usize = 0;
    for (0..occurrence + 1) |_| at = (std.mem.indexOfPos(u8, source, at, column_text) orelse return error.TestUnexpectedResult) + 1;
    if (r.failed.span.start != at - 1 + column_text.len - 1) std.debug.print("diagnostic at {d} in {s}\n", .{ r.failed.span.start, source });
    try std.testing.expectEqual(at - 1 + column_text.len - 1, r.failed.span.start);
}

test "a name the loop binds may not be a name declared around the loop, and is never carried" {
    const h = try harness.create();
    defer scratch.release(h);
    const xs = "Xs:[]i64=array{1,2,3}\n";
    // RFC-0076 rule 1: the generator, an inner generator, the key and a binding clause may not
    // take the name of a `var` of the code around the loop (they shadowed it before, and the
    // assignment in the body was `not_mutable`). The diagnostic is at the loop's name.
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var X:i64=10;Ys:=For(X:Xs,Block{set X=X+1;X});X*100+Ys.Length}\nA<public>:i64=S()", .shadowed_name, "For(X", 0);
    try expectAt(h, xs ++ "S()<transacts>:[]i64=Block{var T:i64=10;Ys:=For(A:Xs,T:Xs,Block{set T=T+1;T});Ys+array{T}}\nA<public>:[]i64=S()", .shadowed_name, ",T", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var I:i64=10;Ys:=For(I->X:Xs,Block{set I=I+X;I});I*100+Ys.Length}\nA<public>:i64=S()", .shadowed_name, "For(I", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var D:i64=10;For(X:Xs,D:=X*2,Block{set D=D+1;D});D}\nA<public>:i64=S()", .shadowed_name, ",D", 0);
    try expectAt(h, xs ++ "S()<transacts>:string=Block{var X:string=\"a\";Ys:=For(X:Xs,Block{set X=X+\"b\";X});X}\nA<public>:string=S()", .shadowed_name, "For(X", 0);
    // In a loop that is left early too.
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var X:i64=10;For(X:Xs,Block{set X=X+1;If(X>11,Return(X),false);X});X}\nA<public>:i64=S()", .shadowed_name, "For(X", 0);
    // A name bound inside the body (a binding) may not be the name of such a `var` either.
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{T:=X;set T=T+1;T});T}\nA<public>:i64=S()", .shadowed_name, "Block{T", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var X:i64=10;var T:i64=0;For(X:Xs,Block{set T=T+X;X});T*100+X}\nA<public>:i64=S()", .shadowed_name, "For(X", 0);
    // With a `var` of another name around the loop, the loop's own name is what the body means:
    // it cannot be assigned, and the diagnostic is at the assignment, as it was before loops
    // carried anything.
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var W:i64=10;Ys:=For(X:Xs,Block{set X=X+1;X});W*100+Ys.Length}\nA<public>:i64=S()", .not_mutable, "set X", 0);
    try expectAt(h, xs ++ "S()<transacts>:[]i64=Block{var W:i64=10;Ys:=For(A:Xs,T:Xs,Block{set T=T+1;T});Ys+array{W}}\nA<public>:[]i64=S()", .not_mutable, "set T", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var W:i64=10;Ys:=For(I->X:Xs,Block{set I=I+X;I});W*100+Ys.Length}\nA<public>:i64=S()", .not_mutable, "set I", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var W:i64=10;For(X:Xs,D:=X*2,Block{set D=D+1;D});W}\nA<public>:i64=S()", .not_mutable, "set D", 0);
    try expectAt(h, xs ++ "S()<transacts>:string=Block{var W:string=\"a\";Ys:=For(X:Xs,Block{set X=X+1;X});W}\nA<public>:string=S()", .not_mutable, "set X", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var W:i64=10;For(X:Xs,Block{set X=X+1;If(X>11,Return(X),false);X});W}\nA<public>:i64=S()", .not_mutable, "set X", 0);
    // With no `var` of the name anywhere, the loop's own name is still what cannot be assigned.
    try expectAt(h, xs ++ "L()<transacts>:[]i64=For(X:Xs,Block{set X=X+1;X})\nA<public>:[]i64=L()", .not_mutable, "set X", 0);
    try expectAt(h, xs ++ "L()<transacts>:[][]i64=Block{Rows:[][]i64=array{array{1},array{2}};For(R:Rows,Block{set R[0]=9;R})}\nA<public>:[][]i64=L()", .not_mutable, "set R", 0);
    try expectAt(h, xs ++ "P:=struct{X:i64=0}\nS()<transacts>:i64=Block{var T:i64=0;For(Q:array{P{X:=1}},Block{set Q.X=5;set T=T+Q.X;T});T}\nA<public>:i64=S()", .not_mutable, "set Q", 0);
    // A name bound inside the body (a binding, a parameter) is the body's own as well.
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{var T:i64=0;For(X:Xs,Block{U:=X;set U=U+1;set T=T+U;T});T}\nA<public>:i64=S()", .not_mutable, "set U", 0);
    // The loop beside another `var` carries what its body assigns: `T` here, with `Y` the
    // element and `X` untouched.
    const x = try h.execute(xs ++ "S()<transacts>:i64=Block{var X:i64=10;var T:i64=0;For(Y:Xs,Block{set T=T+Y;Y});T*100+X}\nA<public>:i64=S()");
    try expectInt(x, "A", 610);
}

test "only a var declared in a scope around the loop is carried" {
    const h = try harness.create();
    defer scratch.release(h);
    const xs = "Xs:[]i64=array{1,2,3}\n";
    // A `var` of the name in another function, or in a block that has closed, is no local of
    // the code around this loop: the name is unknown here, as it was.
    try expectAt(h, xs ++ "G()<transacts>:i64=Block{var T:i64=0;T}\nS()<transacts>:i64=Block{For(X:Xs,Block{set T=X;X});1}\nA<public>:i64=S()", .unknown_name, "set T", 0);
    try expectAt(h, xs ++ "S()<transacts>:i64=Block{Block{var T:i64=0;T};For(X:Xs,Block{set T=X;X});1}\nA<public>:i64=S()", .unknown_name, "set T", 0);
    // Declared in an outer block, several brackets away, it is.
    const x = try h.execute(xs ++ "S(N:i64)<transacts>:i64=Block{var T:i64=0;If(N>0,Block{Ys:=For(X:Xs,Block{set T=T+X;X});Ys.Length},0);T}\nA<public>:i64=S(1)*10+S(0)");
    try expectInt(x, "A", 60);
}
