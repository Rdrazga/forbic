//! `If` with several conditions and bindings, and tuple destructuring.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

test "If binds names across conditions and falls through to the else value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{3,4,5}\nScores:map(string,i64)=map{\"a\"=>10,\"b\"=>20}\nPick(I:i64)<computes>:i64=If(X:=Items[I],X>3,X*100,-1)\nTwo(K:string,I:i64)<computes>:i64=If(S:=Scores[K],X:=Items[I],S+X,0)\nPlain(I:i64)<computes>:i64=If(Items[I]>3,I>0,1,2)\nChain(I:i64)<computes>:i64=If(A:=Items[I],B:=A+1,C:=B*2,C>9,A+B+C,0)\nNames(K:string)<computes>:string=If(V:=Scores[K],V>15,\"big\",\"small\")\nA<public>:i64=Pick(1)\nB<public>:i64=Pick(0)\nC<public>:i64=Pick(7)\nD<public>:i64=Two(\"a\",2)\nE<public>:i64=Two(\"z\",2)\nF<public>:i64=Plain(1)\nG<public>:i64=Plain(0)\nH<public>:i64=Chain(2)\nI<public>:i64=Chain(0)\nJ<public>:string=Names(\"b\")\nK<public>:string=Names(\"a\")");
    const expected = [_]struct { []const u8, i64 }{ .{ "A", 400 }, .{ "B", -1 }, .{ "C", -1 }, .{ "D", 15 }, .{ "E", 0 }, .{ "F", 1 }, .{ "G", 2 }, .{ "H", 5 + 6 + 12 }, .{ "I", 0 } };
    for (expected) |entry| try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
    try std.testing.expectEqualStrings("big", x.get("J").?.string);
    try std.testing.expectEqualStrings("small", x.get("K").?.string);
}

test "a failing condition undoes earlier writes and else sees the original state" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1}\nvar Log:i64=0\nBump()<transacts>:i64=Block{set Log=Log+1;Log}\nRoll()<transacts>:i64=If(N:=Bump(),Items[9]>0,10,Log)\nCommit()<transacts>:i64=If(N:=Bump(),Items[0]>0,N*100+Log,-1)\nA<public>:i64=Roll()\nB<public>:i64=Log\nC<public>:i64=Commit()\nD<public>:i64=Log");
    try std.testing.expectEqual(@as(i64, 0), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 101), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("D").?.integer);
}

test "multi-condition If nests with For and itself" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{3,4,5}\nNested(I:i64)<computes>:i64=If(X:=Items[I],If(Y:=Items[I+1],X<Y,1,0)>0,X*10,For(Z:Items,Z).Length)\nRows<public>:[]i64=For(I->X:Items,If(P:=Items[I],P>3,P,0))\nA<public>:i64=Nested(0)\nB<public>:i64=Nested(2)");
    try std.testing.expectEqual(@as(i64, 30), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("B").?.integer);
    const loop = x.elements(x.get("Rows").?).?;
    try std.testing.expectEqual(@as(i64, 0), loop[0].integer);
    try std.testing.expectEqual(@as(i64, 4), loop[1].integer);
    try std.testing.expectEqual(@as(i64, 5), loop[2].integer);
}

test "tuple destructuring binds each element once" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Count:i64=0\nNext()<transacts>:tuple(i64,string)=Block{set Count=Count+1;tuple{Count,\"n\"}}\nSplit(P:tuple(i64,string))<computes>:string=Block{(N,S):=P;S+ToString(N)}\nTriple()<computes>:i64=Block{(A,B,C):=tuple{1,2,3};A*100+B*10+C}\nOnce()<transacts>:string=Block{(N,S):=Next();S+ToString(N)+ToString(N)}\nNested()<computes>:i64=Block{(A,B):=tuple{tuple{1,2},3};(P,Q):=A;P+Q+B}\nA<public>:string=Split(tuple{5,\"n\"})\nB<public>:i64=Triple()\nC<public>:string=Once()\nD<public>:i64=Count\nE<public>:i64=Nested()");
    try std.testing.expectEqualStrings("n5", x.get("A").?.string);
    try std.testing.expectEqual(@as(i64, 123), x.get("B").?.integer);
    try std.testing.expectEqualStrings("n11", x.get("C").?.string);
    try std.testing.expectEqual(@as(i64, 1), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("E").?.integer);
}

test "macros work in bundles and add a library only where used" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nPlain<public>:i64=L.Plain(2)\nPicked<public>:i64=L.Pick(1)" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{3,4}\nPlain<public>(N:i64)<computes>:i64=N+1\nPick<public>(I:i64)<computes>:i64=If(X:=Items[I],X>3,(A,B):=tuple{X,1};A+B,0)" },
    };
    const good_inputs = inputs;
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &good_inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 20_000);
    try std.testing.expectEqual(@as(i64, 3), result.ok.get("Plain").?.integer);
    try std.testing.expectEqual(@as(i64, 5), result.ok.get("Picked").?.integer);
    // Only the module that used a macro grew a library block (the dependency comes first).
    try std.testing.expect(bundled.ok.modules[0].source.end - bundled.ok.modules[0].source.start > good_inputs[1].source.len);
    try std.testing.expectEqual(good_inputs[0].source.len, bundled.ok.modules[1].source.end - bundled.ok.modules[1].source.start);
}

test "programs that use no macro keep their source byte for byte" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "Pick(I:i64)<computes>:i64=If(I>0,1,2)\nA<public>:i64=Pick(1)";
    const program = try h.compile(source);
    try std.testing.expectEqual(source.len, program.source.len);
}

test "macro misuse reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "Items:[]i64=array{3,4}\nN:i64=1\n";
    for ([_]Case{
        // One binding condition is the form too: here `X>3` is the then-branch and `1` the else.
        .{ prelude ++ "A:i64=If(X:=Items[0],X>3,1)", .type_mismatch },
        .{ prelude ++ "A:i64=If(,X>3,1,2)", .macro_syntax },
        .{ prelude ++ "A:i64=If(X:=Items[0],N,1,2)", .type_mismatch },
        .{ prelude ++ "A:i64=If(X:=Items[0],X>3,1,\"two\")", .type_mismatch },
        .{ prelude ++ "A:i64=If(X:=Items[0],Y,X,2)", .unknown_name },
        .{ prelude ++ "A:i64=If(X:=Items[0],X>3,X,Y)", .unknown_name },
        .{ prelude ++ "A:i64=Block{(P,Q):=N;P}", .not_callable },
        .{ prelude ++ "A:i64=Block{(P,Q):=tuple{1};P}", .tuple_index },
        .{ prelude ++ "A:i64=Block{(P,Q):=;P}", .macro_syntax },
        .{ prelude ++ "A:i64=Block{(P,P):=tuple{1,2};P}", .duplicate_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected macro admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("macro diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        try std.testing.expect(r.failed.span.end <= case[0].len);
        _ = try h.execute("A:i64=42");
    }
}

/// Source text built piece by piece: programs with a hundred statements are not written by hand.
pub const Text = struct {
    bytes: [16 * 1024]u8 = undefined,
    len: usize = 0,

    pub fn add(self: *Text, comptime format: []const u8, arguments: anytype) void {
        self.len += (std.fmt.bufPrint(self.bytes[self.len..], format, arguments) catch unreachable).len;
    }

    pub fn text(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// `Name()<computes>:i64` whose one scope holds `count` tuple patterns; it yields `first + ... + (first + count - 1)`.
fn addPatterns(source: *Text, name: []const u8, first: usize, count: usize) void {
    source.add("{s}()<computes>:i64=Block{{", .{name});
    for (first..first + count) |index| source.add("(A{d},B{d}):=tuple{{{d},1}};", .{ index, index, index });
    for (first..first + count) |index| source.add("A{d}*B{d}+", .{ index, index });
    source.add("0}}\n", .{});
}

test "a module holds any number of tuple patterns" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: Text = .{};
    addPatterns(&source, "F", 0, 50);
    addPatterns(&source, "G", 50, 50);
    source.add("R<public>:i64=F()+G()", .{});
    const program = try h.compile(source.text());
    // The block names a temporary for each pattern after the fixed ones, and no more.
    const library = program.source[source.len..];
    try std.testing.expect(std.mem.indexOf(u8, library, "__t99 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, library, "__t100") == null);
    const x = (try h.run(program, 131072)).ok;
    try std.testing.expectEqual(@as(i64, 99 * 100 / 2), x.get("R").?.integer);
}

test "modules within the fixed temporaries and numerals keep the plain library block" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: Text = .{};
    addPatterns(&source, "F", 0, macros.fixed_temporaries);
    source.add("G()<computes>:i64=Block{{(", .{});
    for (0..macros.fixed_numerals) |index| source.add("{s}N{d}", .{ if (index == 0) "" else ",", index });
    source.add("):=tuple{{", .{});
    for (0..macros.fixed_numerals) |index| source.add("{s}{d}", .{ if (index == 0) "" else ",", index });
    source.add("}};N{d}}}\nR<public>:i64=F()+G()", .{macros.fixed_numerals - 1});
    // One pattern more than the fixed temporaries: the block names exactly one more.
    const extended = try h.compile(source.text());
    try std.testing.expectEqual(source.len + macros.libraryLength(0, .{ .temporaries = 1 }), extended.source.len);
    var plain: Text = .{};
    addPatterns(&plain, "F", 0, macros.fixed_temporaries - 1);
    plain.add("{s}", .{source.text()[std.mem.indexOf(u8, source.text(), "G()").?..]});
    const program = try h.compile(plain.text());
    try std.testing.expectEqual(plain.len + macros.libraryLength(0, .{}), program.source.len);
    const x = (try h.run(program, 131072)).ok;
    try std.testing.expectEqual(@as(i64, 30 * 31 / 2 + 15), x.get("R").?.integer);
}

test "a pattern that only a later rewrite round reaches is counted with the earlier ones" {
    const h = try harness.create();
    defer scratch.release(h);
    // The pattern in the `If` follows a comma, so it becomes a statement (and a pattern) only once
    // the `If` is expanded. By then the first round has used every fixed temporary.
    var source: Text = .{};
    addPatterns(&source, "F", 0, macros.fixed_temporaries);
    source.add("Items:[]i64=array{{3,4}}\nG(I:i64)<computes>:i64=If(X:=Items[I],X>3,(P,Q):=tuple{{X,1}};P+Q,0)\nR<public>:i64=F()*10+G(1)", .{});
    const program = try h.compile(source.text());
    try std.testing.expectEqual(source.len + macros.libraryLength(0, .{ .temporaries = 1 }), program.source.len);
    const x = (try h.run(program, 131072)).ok;
    try std.testing.expectEqual(@as(i64, 31 * 32 / 2 * 10 + 5), x.get("R").?.integer);
}

/// `(N0,...):=tuple{0,...};` with `count` names.
fn addWidePattern(source: *Text, count: usize) void {
    source.add("(", .{});
    for (0..count) |index| source.add("{s}N{d}", .{ if (index == 0) "" else ",", index });
    source.add("):=tuple{{", .{});
    for (0..count) |index| source.add("{s}{d}", .{ if (index == 0) "" else ",", index });
    source.add("}};", .{});
}

test "a tuple pattern holds as many names as a tuple has elements" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: Text = .{};
    source.add("F()<computes>:i64=Block{{", .{});
    addWidePattern(&source, 40);
    source.add("N0+N15*100+N16*10000+N39*1000000}}\nR<public>:i64=F()", .{});
    const x = try h.execute(source.text());
    try std.testing.expectEqual(@as(i64, 39161500), x.get("R").?.integer);
    // Each name and the temporary is a local, so the locals of a function end a pattern first:
    // one short of the widest tuple fits, the widest does not, and one more is not a tuple.
    try std.testing.expect(types.limits.local_bindings == types.limits.tuple_arity);
    const Case = struct { usize, ?types.Diagnostic.Code };
    for ([_]Case{ .{ types.limits.tuple_arity - 1, null }, .{ types.limits.tuple_arity, .local_binding_limit }, .{ types.limits.tuple_arity + 1, .tuple_limit } }) |case| {
        source = .{};
        source.add("F()<computes>:i64=Block{{", .{});
        addWidePattern(&source, case[0]);
        source.add("N0+N{d}}}\nR<public>:i64=F()", .{case[0] - 1});
        const r = h.front.compile(source.text());
        if (case[1]) |code| {
            try std.testing.expectEqual(code, r.failed.code);
            try std.testing.expect(r.failed.span.end <= source.len);
        } else {
            try std.testing.expect(r == .ok);
            try std.testing.expectEqual(@as(i64, @intCast(case[0] - 1)), (try h.run(r.ok, 131072)).ok.get("R").?.integer);
        }
    }
}

test "If binds more names than the fixed numerals" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: Text = .{};
    source.add("Items:[]i64=array{{3,4,5}}\nPick(I:i64)<computes>:i64=If(", .{});
    for (0..20) |index| source.add("X{d}:=Items[I]+{d},", .{ index, index });
    source.add("X0+X16*100+X19*10000,-1)\nA<public>:i64=Pick(1)\nB<public>:i64=Pick(9)", .{});
    const x = try h.execute(source.text());
    try std.testing.expectEqual(@as(i64, 4 + 20 * 100 + 23 * 10000), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
}

test "generated temporaries and numerals stay out of the user's reach" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        // `__t40` exists in this module's block, yet the user's text cannot declare it, in any scope or pattern.
        .{ "__t40:=7;A40", .expected_name },
        .{ "Block{__t40:=tuple{7,8};__t40(0)}", .expected_name },
        .{ "(__t40,Z):=tuple{1,2};Z", .expected_name },
        // A user name that only looks like a temporary's neighbour is an ordinary reserved name.
        .{ "__t500:=7;A40", .expected_name },
    }) |case| {
        var source: Text = .{};
        source.add("F()<computes>:i64=Block{{", .{});
        for (0..41) |index| source.add("(A{d},B{d}):=tuple{{{d},1}};", .{ index, index, index });
        addWidePattern(&source, 20);
        source.add("{s}", .{case[0]});
        source.add("}}\nR<public>:i64=F()", .{});
        const r = h.front.compile(source.text());
        if (r == .ok) std.debug.print("unexpected generated-name admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("hygiene diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        // The diagnostic points into the user's text, not into the generated lines.
        try std.testing.expect(r.failed.span.end <= source.len);
    }
}

test "each module of a bundle gets the generated lines it needs" {
    const h = try harness.create();
    defer scratch.release(h);
    var wide: Text = .{};
    wide.add("Wide<public>()<computes>:i64=Block{{", .{});
    addWidePattern(&wide, 20);
    wide.add("N19}}", .{});
    var many: Text = .{};
    many.add("W:=import{{\"wide.forb\"}}\nP:=import{{\"plain.forb\"}}\n", .{});
    addPatterns(&many, "F", 0, 40);
    many.add("R<public>:i64=F()+W.Wide()*1000+P.Sum()*100000", .{});
    const plain = "Sum<public>()<computes>:i64=Block{(A,B):=tuple{1,2};A+B}";
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = many.text() },
        .{ .path = "wide.forb", .source = wide.text() },
        .{ .path = "plain.forb", .source = plain },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const program = bundled.ok;
    const expected = [_]struct { []const u8, usize }{
        .{ "main.forb", many.len + macros.libraryLength(0, .{ .temporaries = 8 }) },
        .{ "wide.forb", wide.len + macros.libraryLength(0, .{ .numerals = true }) },
        .{ "plain.forb", plain.len + macros.libraryLength(0, .{}) },
    };
    for (program.modules) |module| {
        const length = for (expected) |entry| {
            if (std.mem.eql(u8, entry[0], module.path.text(program.paths))) break entry[1];
        } else unreachable;
        try std.testing.expectEqual(length, module.source.end - module.source.start);
    }
    const x = (try h.run(program, 131072)).ok;
    try std.testing.expectEqual(@as(i64, 39 * 40 / 2 + 19 * 1000 + 3 * 100000), x.get("R").?.integer);
}
