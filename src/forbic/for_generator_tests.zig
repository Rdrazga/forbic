//! The general `For` (RFC-0064): several generators, ranges, bindings and failing bodies.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    if (expected.len != elements.len) std.debug.print("{s}: {d} elements, expected {d}\n", .{ name, elements.len, expected.len });
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "For generators nest in order and later ones see earlier bindings" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2,3}\nYs:[]i64=array{10,20}\nRows:[][]i64=array{array{1,2},array{},array{3}}\n" ++
        "Pairs<public>:[]i64=For(X:Xs,Y:Ys,X+Y)\n" ++
        "Flat<public>:[]i64=For(R:Rows,C:R,C*10)\n" ++
        "Tri<public>:[]i64=For(X:Xs,Y:Xs,Y<X,X*10+Y)\n" ++
        "Three<public>:[]i64=For(X:Ys,Y:Xs,Z:Xs,Y<Z,X+Y*Z)\n" ++
        "Words<public>:[]string=For(X:Xs,X>1,S:array{\"a\",\"b\"},\"{S}{X}\")\n" ++
        "None<public>:[]i64=For(X:Xs,Y:For(Z:Xs,Z>9,Z),X+Y)\n");
    try expectIntegers(x, "Pairs", &.{ 11, 21, 12, 22, 13, 23 });
    try expectIntegers(x, "Flat", &.{ 10, 20, 30 });
    try expectIntegers(x, "Tri", &.{ 21, 31, 32 });
    try expectIntegers(x, "Three", &.{ 12, 13, 16, 22, 23, 26 });
    const words = x.elements(x.get("Words").?).?;
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("a2", words[0].string);
    try std.testing.expectEqualStrings("b3", words[3].string);
    try expectIntegers(x, "None", &.{});
}

test "For inner generators are maps and arrays chosen by outer bindings, each with its own key" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Groups:map(string,[]i64)=map{\"b\"=>array{4,5},\"a\"=>array{},\"c\"=>array{6}}\n" ++
        "Tables:[]map(string,i64)=array{map{\"x\"=>1},map{\"y\"=>2,\"z\"=>3}}\nXs:[]i64=array{7,8}\n" ++
        "Members<public>:[]string=For(K->Vs:Groups,V:Vs,\"{K}{V}\")\n" ++
        "Entries<public>:[]string=For(I->T:Tables,K->V:T,\"{I}{K}{V}\")\n" ++
        "Cross<public>:[]i64=For(I->X:Xs,J->Y:Xs,I!=J,X*10+Y+I*100+J*1000)\n" ++
        "Values<public>:[]i64=For(X:Xs,V:Tables[X-7],V*X)\n" ++
        "Scores<public>:[]i64=For(T:Tables,V:T,I:V..2,I)\n");
    const members = x.elements(x.get("Members").?).?;
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("b4", members[0].string);
    try std.testing.expectEqualStrings("c6", members[2].string);
    const entries = x.elements(x.get("Entries").?).?;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("0x1", entries[0].string);
    try std.testing.expectEqualStrings("1z3", entries[2].string);
    try expectIntegers(x, "Cross", &.{ 1078, 187 });
    // The inner source may fail (`Tables[X-7]`): both lookups succeed here.
    try expectIntegers(x, "Values", &.{ 7, 16, 24 });
    try expectIntegers(x, "Scores", &.{ 1, 2, 2 });
}

test "For ranges are inclusive, empty when reversed and exact at the i64 edges" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("N:i64=4\nvar Calls:i64=0\nBound(V:i64)<transacts>:i64=Block{set Calls=Calls+1;V}\n" ++
        "A<public>:[]i64=For(I:1..N,I*I)\n" ++
        "B<public>:[]i64=For(I:3..3,I)\n" ++
        "C<public>:[]i64=For(I:3..2,I)\n" ++
        "D<public>:[]i64=For(I:0-2..N-3,I)\n" ++
        "E<public>:[]i64=For(I:1..3,J:I..3,I*10+J)\n" ++
        "F<public>:[]i64=For(I:9223372036854775806..9223372036854775807,I)\n" ++
        "G<public>:[]i64=For(I:9223372036854775807..0-9223372036854775807-1,I)\n" ++
        "H<public>:[]i64=For(I:0-9223372036854775807-1..0-9223372036854775807,I)\n" ++
        "J<public>:[]i64=For(I:Bound(1)..Bound(3),I)\n" ++
        "K<public>:i64=Calls\n" ++
        "L<public>:[]i64=For(I:0..N,I>2,I)\n" ++
        "M<public>:[]float=For(I:1..2,ToFloat(I)*0.5)\n" ++
        "O<public>:[]i64=For(I : 1 .. 2,I)\n");
    try expectIntegers(x, "A", &.{ 1, 4, 9, 16 });
    try expectIntegers(x, "B", &.{3});
    try expectIntegers(x, "C", &.{});
    try expectIntegers(x, "D", &.{ -2, -1, 0, 1 });
    try expectIntegers(x, "E", &.{ 11, 12, 13, 22, 23, 33 });
    try expectIntegers(x, "F", &.{ std.math.maxInt(i64) - 1, std.math.maxInt(i64) });
    try expectIntegers(x, "G", &.{});
    try expectIntegers(x, "H", &.{ std.math.minInt(i64), std.math.minInt(i64) + 1 });
    try expectIntegers(x, "J", &.{ 1, 2, 3 });
    // Each bound is evaluated once, whatever the length of the range.
    try std.testing.expectEqual(@as(i64, 2), x.get("K").?.integer);
    try expectIntegers(x, "L", &.{ 3, 4 });
    try std.testing.expectEqual(@as(f64, 1.0), x.elements(x.get("M").?).?[1].floating);
    // `..` is two adjacent dots; blanks around it are fine, a float literal next to it is not involved.
    try expectIntegers(x, "O", &.{ 1, 2 });
}

test "a range longer than an i64 can count is an overflow, in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "A<public>:[]i64=For(I:0-9223372036854775807..9223372036854775807,I)",
        "A<public>:[]i64=For(I:0..9223372036854775807,I)",
        "A<public>:[]i64=For(I:0-9223372036854775807-1..0,I)",
    }) |source| {
        const result = try h.run(try h.compile(source), 131072);
        try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
    }
    // One element short of that is a valid range, which only fuel ends.
    const long = try h.run(try h.compile("A<public>:[]i64=For(I:1..9223372036854775807,I>0,I)"), 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, long.failed.code);
}

test "For bindings may fail, are visible to later clauses and skip the iteration" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{0,2,5,1}\nM:map(i64,i64)=map{1=>100,2=>200}\nN:i64=50\n" ++
        "Half(V:i64)<computes><decides>:i64=Block{Require[V>1];V/2}\n" ++
        "A<public>:[]i64=For(X:Xs,Y:=M[X],Y+X)\n" ++
        "C<public>:[]i64=For(I:0..5,Y:=Xs[I],Y>0,Z:=M[Y],Z+I)\n" ++
        "D<public>:[]i64=For(X:Xs,Y:=X*2,Z:Xs,Z>Y,Z)\n" ++
        "E<public>:[]i64=For(X:Xs,H:=Half[X],I:1..H,I*10+X)\n" ++
        "F<public>:[]i64=For(X:Xs,P:=X+1,Q:=P*2,Q)\n" ++
        "G<public>:[]i64=For(X:Xs,Y:=X+1,Z:Xs,T:=Z+Y,T>6,T)\n" ++
        "Use(K:i64)<computes>:[]i64=Block{L:=K*2;For(X:Xs,Y:=M[X],I:1..2,Y+I+K+L)}\n" ++
        "U<public>:[]i64=Use(1)\n" ++
        "W<public>:i64=N\n");
    try expectIntegers(x, "A", &.{ 202, 101 });
    try expectIntegers(x, "C", &.{ 201, 103 });
    try expectIntegers(x, "D", &.{ 2, 5, 1, 5, 5 });
    try expectIntegers(x, "E", &.{ 12, 15, 25 });
    // A binding is visible to the clauses that follow it and leaves an outer name alone.
    try expectIntegers(x, "F", &.{ 2, 6, 12, 4 });
    try std.testing.expectEqual(@as(i64, 50), x.get("W").?.integer);
    // After a generator a binding may use an earlier binding.
    try expectIntegers(x, "G", &.{ 8, 8, 11, 7, 7 });
    try expectIntegers(x, "U", &.{ 204, 205, 104, 105 });
    // RFC-0076 rule 1: a binding may not take the name of the generator's variable, of an
    // earlier declaration of the file or of an earlier binding of the same loop (these three
    // were the shadowing forms of `F` and `G` above); the diagnostic is at the binding's name.
    const prelude = "Xs:[]i64=array{0,2,5,1}\nN:i64=50\n";
    for ([_]struct { []const u8, []const u8 }{
        .{ "F<public>:[]i64=For(X:Xs,X:=X+1,X)", ",X:=" },
        .{ "F<public>:[]i64=For(X:Xs,P:=X+1,N:=P*2,N)", ",N:=" },
        .{ "G<public>:[]i64=For(X:Xs,Y:=X+1,Z:Xs,Y:=Z+Y,Y>6,Y)", ",Y:=Z" },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prelude, case[0] });
        defer std.testing.allocator.free(source);
        const r = h.front.compile(source);
        try std.testing.expect(r == .failed);
        if (r.failed.code != .shadowed_name) std.debug.print("shadowing in {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, r.failed.code);
        try std.testing.expectEqual(std.mem.indexOf(u8, source, case[1]).? + 1, r.failed.span.start);
    }
}

test "a For body that fails skips the iteration and undoes its writes and instances" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Box:=class{var N:i64}
        \\var Total:i64=0
        \\var Seen:i64=0
        \\Xs:[]i64=array{1,2,3,4}
        \\Odd(V:i64)<computes><decides>:i64=Block{Require[V!=2];Require[V!=4];V}
        \\Sum()<transacts>:[]i64=For(X:Xs,Block{set Total=Total+X;Require[X!=2];Total})
        \\Made()<transacts>:[]Box=For(X:Xs,Block{B:=Box{N:=X};set B.N=B.N*10;Require[X>2];B})
        \\Count()<transacts>:[]i64=For(X:Xs,Block{set Seen=Seen+1;true},Y:=Odd[X],Block{set Seen=Seen+100;Odd[Y+2]})
        \\Whole()<transacts><decides>:i64=Block{R:=For(X:Xs,Xs[X]);R.Length}
        \\A<public>:[]i64=Sum()
        \\AfterSum<public>:i64=Total
        \\Boxes:[]Box=Made()
        \\Ns(Items:[]Box)<transacts>:[]i64=For(K:Items,K.N)
        \\B<public>:[]i64=Ns(Boxes)
        \\C<public>:[]i64=Count()
        \\AfterCount<public>:i64=Seen
        \\D<public>:[]i64=For(X:Xs,Xs[X])
        \\E<public>:[]i64=For(X:Xs,Odd[X])
        \\F<public>:i64=Attempt(Whole[],-1)
        \\G<public>:[]i64=For(X:Xs,If(Xs[X]>3,1,0))
        \\H<public>:[]i64=For(X:Xs,Attempt(Xs[X],-1))
        \\Opts:[]option(i64)=array{option{7},option{},option{9}}
        \\I<public>:[]i64=For(O:Opts,O?+1)
        \\J<public>:[]i64=For(O:Opts,V:=O?,W:1..2,V*W)
    );
    // The write of the second iteration is undone with it.
    try expectIntegers(x, "A", &.{ 1, 4, 8 });
    try std.testing.expectEqual(@as(i64, 8), x.get("AfterSum").?.integer);
    try expectIntegers(x, "B", &.{ 30, 40 });
    // A header and a field for each box of the two iterations that succeeded; the other two are gone.
    try std.testing.expectEqual(@as(usize, 2 * 2), x.object_cells.len);
    // X=2 and X=4 fail at the binding, after the filter wrote: a filter's write stays only when
    // the whole iteration succeeds, so two iterations leave 101 each.
    try expectIntegers(x, "C", &.{ 3, 5 });
    try std.testing.expectEqual(@as(i64, 202), x.get("AfterCount").?.integer);
    try expectIntegers(x, "D", &.{ 2, 3, 4 });
    try expectIntegers(x, "E", &.{ 1, 3 });
    // A body's failure never leaves the loop, whatever the enclosing function may do.
    try std.testing.expectEqual(@as(i64, 3), x.get("F").?.integer);
    // A failure the body handles itself is its own business.
    try expectIntegers(x, "G", &.{ 0, 0, 1, 0 });
    try expectIntegers(x, "H", &.{ 2, 3, 4, -1 });
    // An empty option fails where it is unwrapped, in a body or a binding.
    try expectIntegers(x, "I", &.{ 8, 10 });
    try expectIntegers(x, "J", &.{ 7, 14, 9, 18 });
}

test "For filters of the general form undo their writes with a skipped iteration" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Hits:i64=0\nXs:[]i64=array{1,2,3}\n" ++
        "Mark(V:i64)<transacts>:logic=Block{set Hits=Hits+V;true}\n" ++
        "Run()<transacts>:[]i64=For(X:Xs,Mark(X),Y:1..X,Mark(10),Y!=2,X*10+Y)\n" ++
        "A<public>:[]i64=Run()\nB<public>:i64=Hits\n");
    try expectIntegers(x, "A", &.{ 11, 21, 31, 33 });
    // Outer marks 1+2+3 stay; of the six inner marks the two with Y=2 are undone.
    try std.testing.expectEqual(@as(i64, 6 + 40), x.get("B").?.integer);
}

test "For clauses nest other macros and keep generated names out of reach" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2,3}\nM:map(i64,i64)=map{1=>5}\n" ++
        "A<public>:[]i64=For(X:For(I:1..3,I*2),Y:For(J:Xs,J>X,J),X+Y)\n" ++
        "B<public>:[]i64=For(X:Xs,S:=For(I:1..X,I).Length,T:For(Y:Xs,Y<=S,Y),T)\n" ++
        "C<public>:[]i64=For(X:Xs,Y:Xs,If(V:=M[X],Y>1,V+Y,0-Y))\n" ++
        "D<public>:[][]i64=For(X:Xs,Y:X..2,For(Z:Y..2,W:=M[Z],W+X))\n" ++
        "E<public>:[]i64=For(for_s:Xs,for_f:1..for_s,for_items:=for_f+for_s,for_items)\n" ++
        "Twice[T:type](Items:[]T)<computes>:[]T{For(X:Items,Y:Items,I:1..1,Y)}\n" ++
        "F<public>:[]i64=Twice[i64](array{1,2})\nG<public>:[]string=Twice[string](array{\"a\"})\n" ++
        "Sum(N:i64)<transacts>:i64=Block{var T:i64=0;var I:i64=0;While(I<N,Block{set T=T+For(P:0..I,Q:P..I,Q).Length;set I=I+1});T}\n" ++
        "H<public>:i64=Sum(3)\n");
    // Only 2 has a larger element after it.
    try expectIntegers(x, "A", &.{5});
    try expectIntegers(x, "B", &.{ 1, 1, 2, 1, 2, 3 });
    try expectIntegers(x, "C", &.{ -1, 7, 8, -1, -2, -3, -1, -2, -3 });
    const rows = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try expectIntegers(x, "E", &.{ 2, 3, 4, 4, 5, 6 });
    try expectIntegers(x, "F", &.{ 1, 2, 1, 2 });
    try std.testing.expectEqualStrings("a", x.elements(x.get("G").?).?[0].string);
    // Triangles of 1, 3 and 6 pairs.
    try std.testing.expectEqual(@as(i64, 10), x.get("H").?.integer);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "A:[]i64=For(__for_s:array{1},Y:1..2,__for_s)", .expected_parameter },
        .{ "A:[]i64=For(X:array{1},__for_f:=X,__for_f)", .expected_name },
        .{ "A:[]i64=For(X:1..2,__for_lo:=X,__for_lo)", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("generated name in {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
    }
}

test "a For with many generators gets the Fn words its pool lacks, in every module" {
    const h = try harness.create();
    defer scratch.release(h);
    // One generator fits the pool, so the block has the general templates and no line of words.
    const one = "A<public>:[]i64=For(X:1..2,X)";
    try std.testing.expectEqual(one.len + macros.libraryLength(1, .{ .loops = true }), (try h.compile(one)).source.len);
    const five = "A<public>:[]i64=For(V:1..2,B:1..2,C:V..B,D:C..2,E:D..2,V+B+C+D+E)";
    const program = try h.compile(five);
    try std.testing.expect(program.source.len > five.len + macros.libraryLength(1, .{ .loops = true }));
    const x = (try h.run(program, 131072)).ok;
    // (A,B) = (1,1): C=1, D in 1..2, E in D..2: 3. (1,2): C in 1..2: 3 + 1. (2,2): C=2: 1. (2,1): none.
    try std.testing.expectEqual(@as(usize, 8), x.elements(x.get("A").?).?.len);
    // Words and temporaries are separate lines of one block: 40 patterns need the second.
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("P:tuple(i64,i64)=tuple{1,2}\nR<public>:[]i64=For(A:1..2,B:1..2,C:1..2,A+B+C)\nF()<computes>:i64=Block{\n");
    for (0..40) |index| try out.print("(L{d},H{d}):=P\n", .{ index, index });
    try out.writeAll("L39+H0}\nS<public>:i64=F()\n");
    const both = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(usize, 8), both.elements(both.get("R").?).?.len);
    try std.testing.expectEqual(@as(i64, 3), both.get("S").?.integer);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:[]i64=For(X:L.Items,Y:1..2,Z:L.Pairs(X),X+Y+Z)" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{10,20}\nPairs<public>(V:i64)<computes>:[]i64=For(X:1..2,Y:X..2,Q:=V+X,Q>0,Q*Y)" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path, bundled.failed.diagnostic.span.start });
    try std.testing.expect(bundled == .ok);
    const result = (try h.run(bundled.ok, 131072)).ok;
    // Pairs(10) = 11, 22, 24; Pairs(20) = 21, 42, 44; each with Y = 1 and 2.
    try expectIntegers(result, "A", &.{ 22, 33, 35, 23, 34, 36, 42, 63, 65, 43, 64, 66 });
}

test "For reports malformed clauses and type errors at the call" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "Xs:[]i64=array{1,2}\nN:i64=3\nvar Cell:i64=0\n";
    for ([_]Case{
        // The last argument is the body.
        .{ "A:[]i64=For(X:Xs,Y:Xs)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,Y:=3)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,Y:1..2)", .for_syntax },
        // Clauses that lack a part.
        .{ "A:[]i64=For(X:Xs,Y:,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,Y:=,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,,X)", .for_syntax },
        .{ "A:[]i64=For(X:1..,X)", .for_syntax },
        .{ "A:[]i64=For(X:..3,X)", .for_syntax },
        .{ "A:[]i64=For(X:..,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,Y:N..,X)", .for_syntax },
        // A key needs something keyed. (A head that binds or filters is RFC-0090's, and compiles.)
        .{ "A:[]i64=For(I->X:1..3,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,I->Y:1..3,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,I->Y,X)", .for_syntax },
        .{ "A:[]i64=For(X:Xs,I->Y:=3,X)", .for_syntax },
        // Types.
        .{ "A:[]i64=For(X:1.5..3,X)", .type_mismatch },
        .{ "A:[]i64=For(X:1..\"a\",X)", .type_mismatch },
        .{ "A:[]i64=For(X:1..3.0,X)", .type_mismatch },
        .{ "A:[]i64=For(X:Xs,Y:N,X)", .type_mismatch },
        .{ "A:[]string=For(X:Xs,Y:Xs,X)", .type_mismatch },
        .{ "A:[]i64=For(X:Xs,Y:Xs,N,X)", .type_mismatch },
        .{ "A:[]i64=For(X:Xs,Y:=X>1,Y+1)", .type_mismatch },
        // Names and effects.
        .{ "A:[]i64=For(X:Xs,Y:=Q[X],Y)", .unknown_name },
        .{ "A:[]i64=For(X:Xs,Y:Xs,Z)", .unknown_name },
        .{ "A:[]i64=For(X:Xs,Y:=1,Y:=2,Y)", .duplicate_name },
        .{ "F()<computes>:[]i64=For(X:Xs,Y:Xs,Block{set Cell=X;X})", .set_requires_writes },
        // A range is a generator source, not a value, and the head's source is not a failure context.
        .{ "A:=1..3", .expected_field },
        .{ "A:[]i64=For(X:Xs[0]..3,X)", .failure_context_required },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] });
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected For admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("For diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        // Every diagnostic points into the user's own text, never into the appended library.
        try std.testing.expect(r.failed.span.end <= source.len);
        try std.testing.expect(r.failed.span.start >= prelude.len);
        _ = try h.execute("A:i64=42");
    }
    // Errors in generated code are blamed on the For call itself.
    const wrong = prelude ++ "A:[]i64=For(X:Xs,Y:N,X)";
    try std.testing.expectEqual(std.mem.indexOf(u8, wrong, "For(").?, h.front.compile(wrong).failed.span.start);
}

test "For is bounded by its clauses and by the frames and parameters of its generators" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [2048]u8 = undefined;
    // A head and sixty-four more clauses fit, in the established form as before and in the general one.
    for ([_][]const u8{ "X:array{1,2}", "X:1..2" }) |head| {
        for ([_]usize{ 64, 65 }) |filters| {
            var out = std.Io.Writer.fixed(&buffer);
            try out.print("A<public>:[]i64=For({s},", .{head});
            for (0..filters) |_| try out.writeAll("X>0,");
            try out.writeAll("X)");
            const r = h.front.compile(out.buffered());
            if (filters == 64) try expectIntegers((try h.run(r.ok, 131072)).ok, "A", &.{ 1, 2 }) else try std.testing.expectEqual(types.Diagnostic.Code.for_syntax, r.failed.code);
        }
    }
    // Conditions that bind nest the rewrite two levels each; the bound is a diagnostic, not a crash.
    var nested = std.Io.Writer.fixed(&buffer);
    try nested.writeAll("A<public>:[]i64=For(X:array{1},");
    for (0..70) |_| try nested.writeAll("If(B:=");
    try nested.writeAll("X");
    for (0..70) |_| try nested.writeAll(",B>0,B,0)");
    try nested.writeAll(")");
    try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, h.front.compile(nested.buffered()).failed.code);
    // A generator holds two frames while it runs, and the bootstrap profile has thirty-two.
    for ([_]usize{ 16, 17 }) |generators| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("A<public>:[]i64=For(");
        for (0..generators) |index| try out.print("V{d}:1..1,", .{index});
        try out.writeAll("V0)");
        const result = try h.run(try h.compile(out.buffered()), 131072);
        if (generators == 16) try expectIntegers(result.ok, "A", &.{1}) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, result.failed.code);
    }
    // The innermost level captures every outer name its body uses, through its parameter list.
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("A<public>:[]i64=For(");
    for (0..16) |index| try out.print("V{d}:1..1,", .{index});
    for (0..16) |index| try out.print("{s}V{d}", .{ if (index == 0) "" else "+", index });
    try out.writeAll(")");
    try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, h.front.compile(out.buffered()).failed.code);
}

test "established For forms that handle their own failures keep their lowering exactly" {
    const h = try harness.create();
    defer scratch.release(h);
    // Nodes, call steps and run members measured with the compiler as it was before RFC-0064.
    // The members of the second, third and fourth are 25, 76 and 22 since the rooms of RFC-0055:
    // their loop states wrap an accumulator, and its copies leave their placeholders behind.
    const Case = struct { []const u8, usize, usize, usize, usize };
    for ([_]Case{
        .{ "Xs:[]i64=array{1,2,3}\nA<public>:[]i64=For(X:Xs,If(Xs[0]>0,X,0))", 10, 81, 8, 3 },
        .{ "Xs:[]i64=array{1,2,3}\nO:option(i64)=option{4}\nA<public>:[]i64=For(X:Xs,If(V:=O?,V>0,X+V,0))", 12, 96, 25, 3 },
        .{ "Xs:[]i64=array{1,2,3}\nA<public>:[]i64=For(X:Xs,For(Y:Xs,Xs[Y]>1,Y).Length)", 11, 510, 76, 3 },
        .{ "Xs:[]i64=array{1,2,3}\nA<public>:[]i64=For(I->X:Xs,Xs[I]>1,Attempt(Xs[X],0-1))", 13, 186, 22, 2 },
        // Linear: the general lowering would copy the accumulator 192 times and exhaust the pool.
        .{ "Base:[]i64=Iterate(Fn(S:[]i64){S+array{S.Length}},192,array{})\nA<public>:[]i64=For(X:Base,If(Base[0]>=0,X,0))", 10, 6144, 386, 192 },
    }) |case| {
        const program = try h.compile(case[0]);
        try std.testing.expectEqual(case[1], program.nodes.len);
        const x = (try h.run(program, 131072)).ok;
        try std.testing.expectEqual(case[2], x.call_steps.len);
        try std.testing.expectEqual(case[3], x.aggregate_values.len);
        try std.testing.expectEqual(case[4], x.elements(x.get("A").?).?.len);
    }
}

test "a For is a failure context for failures no token shows, and only the call that needs it changes" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Xs:[]i64=array{1,2,3}\n" ++
        "Dec(S:i64)<computes><decides>:i64=Block{Require[S>0];S-1}\n" ++
        "Stop(S:i64)<computes><decides>:option(i64)=Block{Require[S!=2];option{}}\n" ++
        "Row(S:[]i64)<computes><decides>:[]i64=Block{Require[S.Length<2];S+array{7}}\n";
    const x = try h.execute(prelude ++
        "A<public>:[]i64=For(X:0..3,Iterate(Dec,1,X))\n" ++
        "B<public>:[]i64=For(X:Xs,Block{Loop(Stop,X);X})\n" ++
        "C<public>:[]i64=For(X:Xs,Y:Iterate(Row,X,array{}),X*10+Y)\n" ++
        "D<public>:[]i64=For(X:Xs,Iterate(Dec,2,X))\n" ++
        "E<public>:[]i64=For(X:Xs,For(Y:Xs,Iterate(Dec,Y,X)).Length)\n" ++
        "F<public>:[]i64=For(X:Xs,Require[X!=2],X)\n");
    try expectIntegers(x, "A", &.{ 0, 1, 2 });
    try expectIntegers(x, "B", &.{ 1, 3 });
    // Two rows fit; the third application fails and skips that iteration of X.
    try expectIntegers(x, "C", &.{ 17, 27, 27 });
    try expectIntegers(x, "D", &.{ 0, 1 });
    // Only the inner call is a failure context here: the outer body cannot fail.
    try expectIntegers(x, "E", &.{ 1, 2, 3 });
    try expectIntegers(x, "F", &.{ 1, 3 });
    // A call the retry leaves alone compiles to what it does on its own.
    const established = "Xs:[]i64=array{1,2,3}\nK<public>:[]i64=For(X:Xs,X*2)";
    const failing = "L<public>:[]i64=For(X:Xs,Xs[X])";
    const alone = (try h.execute(established)).call_steps.len;
    const general = (try h.execute("Xs:[]i64=array{1,2,3}\n" ++ failing)).call_steps.len;
    const beside = (try h.execute(established ++ "\n" ++ failing)).call_steps.len;
    try std.testing.expect(general > alone);
    try std.testing.expectEqual(alone + general, beside);
    // In a bundle the calls of every module are found, also after a library block has grown.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:[]i64=For(X:L.Items,L.Items[X])\nB<public>:[]i64=L.Pick(2)\nC<public>:[]i64=For(X:1..2,Y:1..2,Z:1..2,X)" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{1,2}\nPick<public>(N:i64)<computes>:[]i64=For(X:Items,Items[X+N-2]+X)" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const result = (try h.run(bundled.ok, 131072)).ok;
    try expectIntegers(result, "A", &.{2});
    try expectIntegers(result, "B", &.{3});
    try std.testing.expectEqual(@as(usize, 8), result.elements(result.get("C").?).?.len);
    // What cannot be helped stays the diagnostic it was: the head's source is outside the loop.
    try std.testing.expectEqual(types.Diagnostic.Code.failure_context_required, h.front.compile("Xs:[]i64=array{1}\nA:[]i64=For(X:array{Xs[0]},X)").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.failure_context_required, h.front.compile("Xs:[]i64=array{1}\nA:[]i64=For(X:Xs,For(Y:array{Xs[0]},Y).Length)\nB:i64=Xs[0]").failed.code);
}

test "integers before a range lex as integers and floats stay floats" {
    const lexer = @import("lexer.zig");
    var buffer: [16]lexer.Token = undefined;
    const tokens = lexer.tokenize("1..23 1.5 4.", &buffer);
    try std.testing.expect(tokens == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_number, tokens.failed.code);
    const range = lexer.tokenize("1..23 1.5..7", &buffer).ok;
    const kinds = [_]lexer.Token.Kind{ .integer, .dot, .dot, .integer, .floating, .dot, .dot, .integer, .eof };
    try std.testing.expectEqual(kinds.len, range.len);
    for (kinds, range) |kind, token| try std.testing.expectEqual(kind, token.kind);
}

test "a skipped iteration costs its state and nothing else, and fuel is exact in both machines" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const short = (try h.run(try h.compile("A<public>:[]i64=For(I:1..10,I>10,I)"), 131072)).ok;
    const long = (try h.run(try h.compile("A<public>:[]i64=For(I:1..110,I>110,I)"), 131072)).ok;
    // The position and the accumulator travel as one two-element tuple per iteration.
    try std.testing.expectEqual(@as(usize, 200), long.aggregate_values.len - short.aggregate_values.len);
    const steps = (long.call_steps.len - short.call_steps.len) / 100;
    try std.testing.expectEqual(short.call_steps.len + 100 * steps, long.call_steps.len);
    // The harness runs both machines on the same fuel and requires the same outcome: the least
    // fuel that completes the loop is the same number for both, and one unit less ends both.
    const program = try h.compile("Xs:[]i64=array{3,1,2}\nA<public>:[]i64=For(X:Xs,Y:1..X,Z:=Xs[Y],Z>1,X*10+Z)");
    var low: u64 = 0;
    var high: u64 = 131072;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        const result = try h.run(program, middle);
        if (result == .ok) high = middle else {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            low = middle;
        }
    }
    try std.testing.expect(high > 100 and high < 4096);
    try expectIntegers((try h.run(program, high)).ok, "A", &.{ 32, 22 });
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, high - 1)).failed.code);
}

/// A generated loop: up to three generators with clauses between them and a body, over two
/// arrays and a map. `Atom` names a bound value or a small constant.
const Model = struct {
    const Atom = union(enum) { slot: u8, constant: i8 };
    const Clause = struct {
        kind: enum { array_x, array_y, indexed_x, map_m, range, bind_sum, bind_lookup, less, differs, indexed_greater },
        a: Atom = .{ .constant = 0 },
        b: Atom = .{ .constant = 0 },
    };
    const Body = struct { kind: enum { sum, element, lookup }, a: Atom, b: Atom };

    xs: [4]i64 = undefined,
    xs_len: usize = 0,
    ys: [4]i64 = undefined,
    ys_len: usize = 0,
    keys: [4]i64 = undefined,
    values: [4]i64 = undefined,
    map_len: usize = 0,
    clauses: [9]Clause = undefined,
    clause_count: usize = 0,
    body: Body = undefined,
    slots: [24]i64 = undefined,
    results: [512]i64 = undefined,
    result_count: usize = 0,
    /// The loop yields more than `results` holds: far more than a bootstrap run can.
    overflow: bool = false,

    fn atom(random: std.Random, bound: usize) Atom {
        if (bound != 0 and random.boolean()) return .{ .slot = random.uintLessThan(u8, @intCast(bound)) };
        return .{ .constant = random.intRangeAtMost(i8, -1, 4) };
    }

    fn generate(self: *Model, random: std.Random) void {
        self.xs_len = random.intRangeAtMost(usize, 1, 4);
        for (self.xs[0..self.xs_len]) |*x| x.* = random.intRangeAtMost(i64, 0, 5);
        self.ys_len = random.uintAtMost(usize, 3);
        for (self.ys[0..self.ys_len]) |*y| y.* = random.intRangeAtMost(i64, -2, 3);
        self.map_len = random.intRangeAtMost(usize, 1, 4);
        // Distinct keys in a shuffled order: a map iterates in insertion order.
        var pool = [_]i64{ 0, 1, 2, 3, 4, 5 };
        random.shuffle(i64, &pool);
        for (0..self.map_len) |index| {
            self.keys[index] = pool[index];
            self.values[index] = random.intRangeAtMost(i64, 0, 4);
        }
        self.clause_count = 0;
        var bound: usize = 0;
        const generators = random.intRangeAtMost(usize, 1, 3);
        for (0..generators) |_| {
            const kind = random.enumValue(enum { array_x, array_y, indexed_x, map_m, range });
            switch (kind) {
                .array_x => self.push(.{ .kind = .array_x }),
                .array_y => self.push(.{ .kind = .array_y }),
                .indexed_x => self.push(.{ .kind = .indexed_x }),
                .map_m => self.push(.{ .kind = .map_m }),
                // Half the ranges start low, so that many of them are not empty.
                .range => self.push(.{ .kind = .range, .a = if (random.boolean()) .{ .constant = random.intRangeAtMost(i8, -1, 1) } else atom(random, bound), .b = atom(random, bound) }),
            }
            bound += slotsOf(self.clauses[self.clause_count - 1]);
            for (0..random.uintAtMost(usize, 1)) |_| {
                const check = random.enumValue(enum { bind_sum, bind_lookup, less, differs, indexed_greater });
                const a = atom(random, bound);
                const b = atom(random, bound);
                self.push(switch (check) {
                    .bind_sum => .{ .kind = .bind_sum, .a = a, .b = b },
                    .bind_lookup => .{ .kind = .bind_lookup, .a = a },
                    .less => .{ .kind = .less, .a = a, .b = b },
                    .differs => .{ .kind = .differs, .a = a, .b = b },
                    .indexed_greater => .{ .kind = .indexed_greater, .a = a, .b = b },
                });
                bound += slotsOf(self.clauses[self.clause_count - 1]);
            }
        }
        self.body = .{ .kind = random.enumValue(@FieldType(Body, "kind")), .a = atom(random, bound), .b = atom(random, bound) };
    }

    fn push(self: *Model, clause: Clause) void {
        self.clauses[self.clause_count] = clause;
        self.clause_count += 1;
    }

    /// How many names a clause binds; they take the next slots in order.
    fn slotsOf(clause: Clause) usize {
        return switch (clause.kind) {
            .indexed_x, .map_m => 2,
            .array_x, .array_y, .range, .bind_sum, .bind_lookup => 1,
            .less, .differs, .indexed_greater => 0,
        };
    }

    fn writeAtom(out: *std.Io.Writer, value: Atom) !void {
        switch (value) {
            .slot => |slot| try out.print("S{d}", .{slot}),
            .constant => |constant| if (constant < 0) try out.print("(0-{d})", .{-@as(i64, constant)}) else try out.print("{d}", .{constant}),
        }
    }

    fn writeSource(self: *const Model, out: *std.Io.Writer) !void {
        try out.writeAll("Xs:[]i64=array{");
        for (self.xs[0..self.xs_len], 0..) |x, index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", x });
        try out.writeAll("}\nYs:[]i64=array{");
        for (self.ys[0..self.ys_len], 0..) |y, index| try out.print("{s}{s}{d}", .{ if (index == 0) "" else ",", if (y < 0) "0-" else "", @abs(y) });
        try out.writeAll("}\nM:map(i64,i64)=map{");
        for (self.keys[0..self.map_len], self.values[0..self.map_len], 0..) |key, value, index| try out.print("{s}{d}=>{d}", .{ if (index == 0) "" else ",", key, value });
        try out.writeAll("}\nR<public>:[]i64=For(");
        var bound: usize = 0;
        for (self.clauses[0..self.clause_count]) |clause| {
            switch (clause.kind) {
                .array_x => try out.print("S{d}:Xs", .{bound}),
                .array_y => try out.print("S{d}:Ys", .{bound}),
                .indexed_x => try out.print("S{d}->S{d}:Xs", .{ bound, bound + 1 }),
                .map_m => try out.print("S{d}->S{d}:M", .{ bound, bound + 1 }),
                .range => {
                    try out.print("S{d}:", .{bound});
                    try writeAtom(out, clause.a);
                    try out.writeAll("..");
                    try writeAtom(out, clause.b);
                },
                .bind_sum => {
                    try out.print("S{d}:=", .{bound});
                    try writeAtom(out, clause.a);
                    try out.writeAll("+");
                    try writeAtom(out, clause.b);
                },
                .bind_lookup => {
                    try out.print("S{d}:=M[", .{bound});
                    try writeAtom(out, clause.a);
                    try out.writeAll("]");
                },
                .less, .differs => {
                    try writeAtom(out, clause.a);
                    try out.writeAll(if (clause.kind == .less) "<" else "!=");
                    try writeAtom(out, clause.b);
                },
                .indexed_greater => {
                    try out.writeAll("Xs[");
                    try writeAtom(out, clause.a);
                    try out.writeAll("]>");
                    try writeAtom(out, clause.b);
                },
            }
            bound += slotsOf(clause);
            try out.writeAll(",");
        }
        switch (self.body.kind) {
            .sum => {
                try writeAtom(out, self.body.a);
                try out.writeAll("*7+");
                try writeAtom(out, self.body.b);
            },
            .element => {
                try out.writeAll("Xs[");
                try writeAtom(out, self.body.a);
                try out.writeAll("]+");
                try writeAtom(out, self.body.b);
            },
            .lookup => {
                try out.writeAll("M[");
                try writeAtom(out, self.body.a);
                try out.writeAll("]");
            },
        }
        try out.writeAll(")\n");
    }

    fn valueOf(self: *const Model, of: Atom) i64 {
        return switch (of) {
            .slot => |slot| self.slots[slot],
            .constant => |constant| constant,
        };
    }

    fn element(self: *const Model, index: i64) ?i64 {
        return if (index >= 0 and index < self.xs_len) self.xs[@intCast(index)] else null;
    }

    fn lookup(self: *const Model, key: i64) ?i64 {
        for (self.keys[0..self.map_len], self.values[0..self.map_len]) |candidate, found| if (candidate == key) return found;
        return null;
    }

    /// The loop as nested iteration: what the lowering must agree with.
    fn evaluate(self: *Model, clause_index: usize, bound: usize) void {
        if (clause_index == self.clause_count) {
            const result = switch (self.body.kind) {
                .sum => self.valueOf(self.body.a) * 7 + self.valueOf(self.body.b),
                .element => (self.element(self.valueOf(self.body.a)) orelse return) + self.valueOf(self.body.b),
                .lookup => self.lookup(self.valueOf(self.body.a)) orelse return,
            };
            if (self.result_count == self.results.len) {
                self.overflow = true;
                return;
            }
            self.results[self.result_count] = result;
            self.result_count += 1;
            return;
        }
        const clause = self.clauses[clause_index];
        const next = bound + slotsOf(clause);
        switch (clause.kind) {
            .array_x, .array_y => {
                const items = if (clause.kind == .array_x) self.xs[0..self.xs_len] else self.ys[0..self.ys_len];
                for (items) |item| {
                    self.slots[bound] = item;
                    self.evaluate(clause_index + 1, next);
                }
            },
            .indexed_x => for (self.xs[0..self.xs_len], 0..) |item, index| {
                self.slots[bound] = @intCast(index);
                self.slots[bound + 1] = item;
                self.evaluate(clause_index + 1, next);
            },
            .map_m => for (self.keys[0..self.map_len], self.values[0..self.map_len]) |key, found| {
                self.slots[bound] = key;
                self.slots[bound + 1] = found;
                self.evaluate(clause_index + 1, next);
            },
            .range => {
                // The bounds are read once, before the generator's own name can shadow anything.
                const low = self.valueOf(clause.a);
                const high = self.valueOf(clause.b);
                var current = low;
                while (current <= high) : (current += 1) {
                    self.slots[bound] = current;
                    self.evaluate(clause_index + 1, next);
                }
            },
            .bind_sum => {
                self.slots[bound] = self.valueOf(clause.a) + self.valueOf(clause.b);
                self.evaluate(clause_index + 1, next);
            },
            .bind_lookup => {
                self.slots[bound] = self.lookup(self.valueOf(clause.a)) orelse return;
                self.evaluate(clause_index + 1, next);
            },
            .less => if (self.valueOf(clause.a) < self.valueOf(clause.b)) self.evaluate(clause_index + 1, next),
            .differs => if (self.valueOf(clause.a) != self.valueOf(clause.b)) self.evaluate(clause_index + 1, next),
            .indexed_greater => if ((self.element(self.valueOf(clause.a)) orelse return) > self.valueOf(clause.b)) self.evaluate(clause_index + 1, next),
        }
    }
};

test "generated For loops agree with nested iteration in a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x64_0f_0a);
    const random = prng.random();
    var nonempty: usize = 0;
    var skipped: usize = 0;
    for (0..400) |round| {
        var model: Model = .{};
        model.generate(random);
        model.result_count = 0;
        model.evaluate(0, 0);
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try model.writeSource(&out);
        const program = h.compile(out.buffered()) catch |err| {
            std.debug.print("round {d}\n", .{round});
            return err;
        };
        const result = try h.run(program, 1 << 20);
        if (result == .failed) {
            // The largest loops do not fit the bootstrap witness or pool; neither machine may differ on that.
            const code = result.failed.code;
            if (code != .call_trace_limit and code != .aggregate_limit) std.debug.print("round {d}: {s}\n{s}", .{ round, result.failed.message(), out.buffered() });
            try std.testing.expect(code == .call_trace_limit or code == .aggregate_limit);
            skipped += 1;
            continue;
        }
        try std.testing.expect(!model.overflow);
        const elements = result.ok.elements(result.ok.get("R").?).?;
        if (elements.len != model.result_count) std.debug.print("round {d}: {d} elements, model {d}\n{s}", .{ round, elements.len, model.result_count, out.buffered() });
        try std.testing.expectEqual(model.result_count, elements.len);
        for (model.results[0..model.result_count], elements) |want, got| {
            if (want != got.integer) std.debug.print("round {d}\n{s}", .{ round, out.buffered() });
            try std.testing.expectEqual(want, got.integer);
        }
        nonempty += @intFromBool(model.result_count != 0);
    }
    // The generator is worth its name: most loops run, and many produce something.
    try std.testing.expect(skipped < 40);
    try std.testing.expect(nonempty > 100);
}

/// Random expressions of type `i64` built from established `For` calls in every position:
/// bodies, generator sources, filters, lambdas and failure contexts, with things that can
/// fail scattered through them.
const ForceGenerator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    fn add(self: *ForceGenerator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn expression(self: *ForceGenerator, depth: u32, bound: ?u32) error{OutOfMemory}!void {
        const choice = if (depth == 0) self.rng.uintLessThan(u32, 5) else self.rng.uintLessThan(u32, 13);
        switch (choice) {
            0 => try self.add("Xs[{d}]", .{self.rng.uintLessThan(u32, 4)}),
            1 => try self.add("Pick[Xs]", .{}),
            2 => if (bound) |name| try self.add("X{d}", .{name}) else try self.add("7", .{}),
            3 => try self.add("Attempt(Xs[{d}],0)", .{self.rng.uintLessThan(u32, 4)}),
            4 => try self.add("{d}", .{self.rng.uintLessThan(u32, 9)}),
            5, 6 => {
                self.names += 1;
                const name = self.names;
                try self.add("For(X{d}:", .{name});
                try self.source(depth - 1, bound);
                try self.add(",", .{});
                try self.expression(depth - 1, name);
                try self.add(").Length", .{});
            },
            7 => {
                self.names += 1;
                const name = self.names;
                try self.add("For(I{d}->X{d}:", .{ name, name });
                try self.source(depth - 1, bound);
                try self.add(",", .{});
                try self.expression(depth - 1, name);
                try self.add("+I{d}).Length", .{name});
            },
            8 => {
                self.names += 1;
                const name = self.names;
                try self.add("For(X{d}:", .{name});
                try self.source(depth - 1, bound);
                try self.add(",X{d}>", .{name});
                try self.expression(depth - 1, name);
                try self.add(",", .{});
                try self.expression(depth - 1, name);
                try self.add(").Length", .{});
            },
            9 => {
                self.names += 1;
                const name = self.names;
                try self.add("Apply(Fn(X{d}:i64){{", .{name});
                try self.expression(depth - 1, name);
                try self.add("}})", .{});
            },
            10 => {
                try self.add("Attempt(", .{});
                try self.expression(depth - 1, bound);
                try self.add(",1)", .{});
            },
            11 => {
                try self.add("(", .{});
                try self.expression(depth - 1, bound);
                try self.add("+", .{});
                try self.expression(depth - 1, bound);
                try self.add(")", .{});
            },
            else => {
                try self.add("Or(option{{", .{});
                try self.expression(depth - 1, bound);
                try self.add("}},2)", .{});
            },
        }
    }
    fn source(self: *ForceGenerator, depth: u32, bound: ?u32) error{OutOfMemory}!void {
        switch (self.rng.uintLessThan(u32, if (depth == 0) 2 else 5)) {
            0, 1 => try self.add("Xs", .{}),
            2 => {
                try self.add("array{{", .{});
                try self.expression(depth, bound);
                try self.add("}}", .{});
            },
            3 => {
                self.names += 1;
                const name = self.names;
                try self.add("For(X{d}:Xs,", .{name});
                try self.expression(depth, name);
                try self.add(")", .{});
            },
            else => try self.add("Rows[{d}]", .{self.rng.uintLessThan(u32, 3)}),
        }
    }
    fn program(self: *ForceGenerator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.add("Xs:[]i64=array{{1,2,3}}\nRows:[][]i64=array{{array{{1}},array{{2,3}}}}\nPick(A:[]i64)<computes><decides>:i64=A[0]\nApply(F:function(tuple(i64),i64))<computes>:i64=F(1)\n", .{});
        const lines = 1 + self.rng.uintLessThan(u32, 3);
        for (0..lines) |line| {
            if (self.rng.boolean()) try self.add("V{d}<public>:i64=", .{line}) else try self.add("G{d}()<computes>:i64=", .{line});
            try self.expression(1 + self.rng.uintLessThan(u32, 4), null);
            try self.add("\n", .{});
        }
        return self.text.items;
    }
};

const ForcedOutcome = struct { ok: bool, code: types.Diagnostic.Code = .expected_expression, span: types.Span = .{ .start = 0, .end = 0 }, nodes: usize = 0, functions: usize = 0, passes: u32, forced: u32, hash: u64 = 0 };

fn forcedOutcome(h: *harness.Harness, source: []const u8, one_at_a_time: bool) ForcedOutcome {
    h.front.for_one_at_a_time = one_at_a_time;
    defer h.front.for_one_at_a_time = false;
    const result = h.front.compile(source);
    var hasher = std.hash.Wyhash.init(0);
    // The calls sent to the general lowering, whatever order they were found in.
    const keys = h.front.for_forced[0..h.front.for_forced_count];
    std.sort.pdq(@TypeOf(keys[0]), keys, {}, struct {
        fn before(_: void, a: @TypeOf(keys[0]), b: @TypeOf(keys[0])) bool {
            return if (a.module != b.module) a.module < b.module else a.offset < b.offset;
        }
    }.before);
    var last: ?u32 = null;
    var distinct: u32 = 0;
    for (keys) |key| {
        if (last != null and last.? == key.offset) continue;
        last = key.offset;
        distinct += 1;
        hasher.update(std.mem.asBytes(&key.offset));
    }
    if (result == .failed) return .{ .ok = false, .code = result.failed.code, .span = result.failed.span, .passes = h.front.passes, .forced = distinct, .hash = hasher.final() };
    for (result.ok.nodes) |node| {
        hasher.update(std.mem.asBytes(&node.span));
        hasher.update(std.mem.asBytes(&node.value_type));
        hasher.update(@tagName(node.kind));
    }
    return .{ .ok = true, .nodes = result.ok.nodes.len, .functions = result.ok.functions.len, .passes = h.front.passes, .forced = distinct, .hash = hasher.final() };
}

test "noting every loop of a pass forces the calls that one compile per loop forced, with the same program or diagnostic" {
    const h = try harness.create();
    defer scratch.release(h);
    const fixed = [_][]const u8{
        "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,Xs[X])",
        "Xs:[]i64=array{1,2}\nA<public>:[][]i64=For(X:Xs,For(Y:Xs,Xs[Y]))",
        "Xs:[]i64=array{1,2}\nA<public>:[][]i64=For(X:Xs,For(Y:array{Xs[X]},Y))",
        "Xs:[]i64=array{1,2}\nA<public>:[][]i64=For(X:Xs,For(Y:array{Xs[X]},Xs[Y]))",
        "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,Xs[X]+For(Y:array{Xs[X]},Y).Length)",
        "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:array{Xs[0]},X)",
        "Xs:[]i64=array{1,2}\nPick(A:[]i64)<computes><decides>:i64=A[0]\nA<public>:[]i64=For(X:Xs,Pick[For(Y:Xs,Y)])",
        "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,For(Y:Xs,Y)[0])",
        "Xs:[]i64=array{1,2}\nApply(F:function(tuple(i64),i64))<computes>:i64=F(1)\nA<public>:[]i64=For(X:Xs,Apply(Fn(Q:i64){Xs[Q]}))",
        "Xs:[]i64=array{1,2}\nA<public>:[]option(i64)=For(X:Xs,option{Xs[X]})\nB<public>:[]i64=For(Y:Xs,Xs[Y]+Or(option{Xs[Y]},0))",
        "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,Xs[X]>0,X)\nB<public>:[]i64=For(I->X:Xs,X>Xs[I],Xs[I])",
        "Xs:[]i64=array{1,2}\nF()<computes>:[]i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+Xs[X];T})}\nA<public>:[]i64=F()",
        "Xs:[]i64=array{1,2}\nG[t:type](A:[]t)<computes>:[]t=For(I->X:A,A[I])\nA<public>:[]i64=G(Xs)\nB<public>:[]string=G(array{\"a\"})",
    };
    var differing: u32 = 0;
    for (fixed) |source| {
        const before = forcedOutcome(h, source, true);
        const after = forcedOutcome(h, source, false);
        if (before.ok != after.ok or before.code != after.code or !std.meta.eql(before.span, after.span) or before.hash != after.hash or before.forced != after.forced or before.nodes != after.nodes) {
            std.debug.print("one at a time: {any}\ntogether: {any}\n{s}\n", .{ before, after, source });
            return error.Differs;
        }
        try std.testing.expect(after.passes <= before.passes);
        differing += @intFromBool(after.passes < before.passes);
    }
    var random = std.Random.DefaultPrng.init(0x666f72636564);
    var generator: ForceGenerator = .{ .rng = random.random() };
    defer generator.text.deinit(std.testing.allocator);
    var compiled: u32 = 0;
    var forced: u32 = 0;
    for (0..600) |_| {
        const source = try generator.program();
        const before = forcedOutcome(h, source, true);
        const after = forcedOutcome(h, source, false);
        if (before.ok != after.ok or before.code != after.code or !std.meta.eql(before.span, after.span) or before.hash != after.hash or before.forced != after.forced or before.nodes != after.nodes) {
            std.debug.print("one at a time: {any}\ntogether: {any}\n{s}\n", .{ before, after, source });
            return error.Differs;
        }
        try std.testing.expect(after.passes <= before.passes);
        differing += @intFromBool(after.passes < before.passes);
        compiled += @intFromBool(after.ok);
        forced += after.forced;
    }
    // The generator is only worth running if it compiles, forces and saves compiles often.
    try std.testing.expect(compiled > 200 and forced > 200 and differing > 40);
}

fn forcedLoops(buffer: []u8, count: usize, body: []const u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    try out.writeAll("Xs:[]i64=array{1,2,3}\n");
    for (0..count) |index| try out.print("A{d}:[]i64=For(I->X:Xs,{s})\n", .{ index, body });
    return out.buffered();
}

test "the number of compiles does not grow with the number of loops that need the general lowering" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [8192]u8 = undefined;
    for ([_][]const u8{ "Xs[I]", "Xs[I]+Or(option{Xs[X]},0)" }) |body| {
        _ = try h.compile(try forcedLoops(&buffer, 2, body));
        const few = h.front.passes;
        const x = try h.execute(try forcedLoops(&buffer, 12, body));
        try std.testing.expectEqual(few, h.front.passes);
        try std.testing.expect(few <= 4);
        try std.testing.expectEqual(@as(u32, 12), h.front.for_forced_count);
        try expectIntegers(x, "A11", if (body.len == 5) &.{ 1, 2, 3 } else &.{ 3, 5, 3 });
    }
}
