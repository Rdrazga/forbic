//! Function overloading: one name, several parameter lists, chosen by the argument types.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

test "overloads are chosen by the types and number of the arguments" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Describe(X:i64)<computes>:string=\"int \"+ToString(X)\nDescribe(X:string)<computes>:string=\"str \"+X\nDescribe(X:i64,Y:i64)<computes>:string=\"pair \"+ToString(X+Y)\nDescribe(B:logic)<computes>:string=If(B,\"yes\",\"no\")\nPick(Xs:[]i64)<computes>:i64=Xs.Length\nPick(Xs:[]string)<computes>:i64=Xs.Length*10\nTwice(X:i64)<computes>:i64=X*2\nTwice(X:float)<computes>:float=X*2.0\nNames:[]string=array{\"a\",\"b\"}\nA<public>:string=Describe(5)\nB<public>:string=Describe(\"x\")\nC<public>:string=Describe(1,2)\nD<public>:string=Describe(true)\nE<public>:i64=Pick(array{1,2})\nF<public>:i64=Pick(Names)\nG<public>:i64=Twice(3)\nH<public>:float=Twice(1.5)\nI<public>:string=Describe(Twice(4))");
    const strings = [_]struct { []const u8, []const u8 }{ .{ "A", "int 5" }, .{ "B", "str x" }, .{ "C", "pair 3" }, .{ "D", "yes" }, .{ "I", "int 8" } };
    for (strings) |entry| try std.testing.expectEqualStrings(entry[1], x.get(entry[0]).?.string);
    try std.testing.expectEqual(@as(i64, 2), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 20), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("G").?.integer);
    try std.testing.expectEqual(@as(f64, 3.0), x.get("H").?.floating);
}

test "overloads keep their own effects and may recurse" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Count:i64=0\nBump(N:i64)<transacts>:i64=Block{set Count=Count+N;Count}\nBump(S:string)<transacts>:i64=Block{set Count=Count+S.Length;Count}\nFact(N:i64)<computes>:i64=If(N<=1,1,N*Fact(N-1))\nFact(S:string)<computes>:i64=S.Length\nFirst(Xs:[]i64)<computes><decides>:i64=Xs[0]\nFirst(Xs:[]string)<computes><decides>:string=Xs[0]\nEmpty:[]i64=array{}\nA<public>:i64=Bump(5)\nB<public>:i64=Bump(\"abc\")\nC<public>:i64=Fact(5)\nD<public>:i64=Fact(\"four\")\nE<public>:i64=Attempt(First[array{7,8}],-1)\nF<public>:string=Attempt(First[array{\"x\"}],\"-\")\nG<public>:i64=Attempt(First[Empty],-1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 120), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("E").?.integer);
    try std.testing.expectEqualStrings("x", x.get("F").?.string);
    try std.testing.expectEqual(@as(i64, -1), x.get("G").?.integer);
}

test "an overloaded name used as a value is chosen by the expected function type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Twice(X:i64)<computes>:i64=X*2\nTwice(X:float)<computes>:float=X*2.0\nApplyInt:function(tuple(i64),i64)=Twice\nApplyFloat:function(tuple(float),float)=Twice\nUse(F:function(tuple(float),float),V:float)<computes>:float=F(V)\nA<public>:i64=ApplyInt(21)\nB<public>:float=ApplyFloat(1.25)\nC<public>:float=Use(Twice,2.0)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(f64, 2.5), x.get("B").?.floating);
    try std.testing.expectEqual(@as(f64, 4.0), x.get("C").?.floating);
}

test "overloads work across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nTwice(X:string)<computes>:string=X+X\nA<public>:i64=L.Twice(4)\nB<public>:string=Twice(\"ab\")\nC<public>:float=L.Twice(1.5)" },
        .{ .path = "lib.forb", .source = "Twice<public>(X:i64)<computes>:i64=X*2\nTwice<public>(X:float)<computes>:float=X*2.0" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 10_000);
    try std.testing.expectEqual(@as(i64, 8), result.ok.get("A").?.integer);
    try std.testing.expectEqualStrings("abab", result.ok.get("B").?.string);
    try std.testing.expectEqual(@as(f64, 3.0), result.ok.get("C").?.floating);
}

test "overload misuse reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "F(X:i64)<computes>:i64=X\nF(X:string)<computes>:i64=X.Length\nF(X:i64,Y:i64)<computes>:i64=X+Y\n";
    for ([_]Case{
        .{ "F(X:i64)<computes>:i64=X\nF(Y:i64)<computes>:i64=Y", .duplicate_name },
        .{ "F(X:i64)<computes>:i64=X\nF(X:string)<computes><decides>:i64=X.Length", .overload_conflict },
        .{ prelude ++ "V:i64=F(true)", .type_mismatch },
        .{ prelude ++ "V:i64=F(1,2,3)", .argument_count },
        .{ prelude ++ "V:i64=F()", .argument_count },
        .{ prelude ++ "V:i64=F(X:=1)", .named_argument_order },
        .{ prelude ++ "V:function(tuple(i64),i64)=F\nW:=F", .ambiguous_call },
        .{ prelude ++ "V:function(tuple(float),float)=F", .ambiguous_call },
        .{ "F(X:i64)<computes>:i64=X\nF:i64=1", .duplicate_name },
        .{ "F:i64=1\nF(X:i64)<computes>:i64=X", .duplicate_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected overload admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("overload diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "forged identical signatures under one name are rejected by independent admission" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Twice(X:i64)<computes>:i64=X*2\nTwice(X:float)<computes>:float=X*2.0\nA:function(tuple(i64),i64)=Twice\nB:function(tuple(float),float)=Twice");
    try std.testing.expect(p.functions.len >= 2);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // The two published aliases differ only in their parameter types; make them equal.
    h.metadata[1].parameters[0] = h.metadata[0].parameters[0];
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    try harness.invalid(h, forged);
}
