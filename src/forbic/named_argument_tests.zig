//! Parameter defaults and named arguments.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

test "defaults fill omitted arguments and named arguments pick parameters in any order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Base:i64=100\nPt:=struct{V:i64=7}\nShow(A:i64,B:i64=10,C:string=\"x\")<computes>:string=ToString(A)+\"|\"+ToString(B)+\"|\"+C\nTotal(A:i64,Extra:i64=Base+1)<computes>:i64=A+Extra\nCount(Xs:[]i64=array{1,2,3},Fallback:option(i64)=option{})<computes>:i64=Xs.Length+Or(Fallback,40)\nRec(P:Pt=Pt{V:=3})<computes>:i64=P.V\nA<public>:string=Show(1)\nB<public>:string=Show(1,2)\nC<public>:string=Show(1,2,\"y\")\nD<public>:string=Show(1,C:=\"z\")\nE<public>:string=Show(C:=\"q\",A:=9,B:=8)\nF<public>:string=Show(5,C:=\"m\",B:=6)\nG<public>:i64=Total(1)\nH<public>:i64=Total(1,Extra:=2)\nI<public>:i64=Count()\nJ<public>:i64=Count(Fallback:=option{5})\nK<public>:i64=Count(Xs:=array{9})\nL<public>:i64=Rec()+Rec(Pt{})");
    const expected = [_]struct { []const u8, []const u8 }{
        .{ "A", "1|10|x" }, .{ "B", "1|2|x" }, .{ "C", "1|2|y" }, .{ "D", "1|10|z" }, .{ "E", "9|8|q" }, .{ "F", "5|6|m" },
    };
    for (expected) |entry| try std.testing.expectEqualStrings(entry[1], x.get(entry[0]).?.string);
    try std.testing.expectEqual(@as(i64, 102), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 43), x.get("I").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("J").?.integer);
    try std.testing.expectEqual(@as(i64, 41), x.get("K").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("L").?.integer);
}

test "a required parameter may follow a defaulted one when it is named" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Mix(A:i64=1,B:i64)<computes>:i64=A*10+B\nV<public>:i64=Mix(B:=2)\nW<public>:i64=Mix(5,B:=3)");
    try std.testing.expectEqual(@as(i64, 12), x.get("V").?.integer);
    try std.testing.expectEqual(@as(i64, 53), x.get("W").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.argument_count, h.front.compile("Mix(A:i64=1,B:i64)<computes>:i64=A*10+B\nV:i64=Mix(7)").failed.code);
}

test "arguments evaluate in the order written and recursive functions keep their defaults" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var N:i64=0\nNext()<transacts>:i64=Block{set N=N+1;N}\nPair(A:i64,B:i64)<computes>:i64=A*10+B\nRun()<transacts>:i64=Pair(A:=Next(),B:=Next())\nBack()<transacts>:i64=Pair(B:=Next(),A:=Next())\nFact(K:i64,Acc:i64=1)<computes>:i64=If(K<=1,Acc,Fact(K-1,Acc*K))\nFirst<public>:i64=Run()\nSecond<public>:i64=Back()\nF<public>:i64=Fact(5)\nG<public>:i64=Fact(4,Acc:=2)");
    // Run reads 1 then 2: A=1, B=2. Back reads 3 for B first, then 4 for A: A=4, B=3.
    try std.testing.expectEqual(@as(i64, 12), x.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, 43), x.get("Second").?.integer);
    try std.testing.expectEqual(@as(i64, 120), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 48), x.get("G").?.integer);
}

test "defaults work across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64=L.Scale(3)\nB<public>:i64=L.Scale(3,Factor:=5)" },
        .{ .path = "lib.forb", .source = "Default:i64=7\nScale<public>(N:i64,Factor:i64=Default)<computes>:i64=N*Factor" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s}\n", .{bundled.failed.diagnostic.message()});
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 10_000);
    try std.testing.expectEqual(@as(i64, 21), result.ok.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 15), result.ok.get("B").?.integer);
}

test "default and named argument misuse has exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "F(A:i64,B:i64=2,C:string=\"c\")<computes>:i64=A+B\nG:function(tuple(i64),i64)=Fn(X:i64){X}\n";
    for ([_]Case{
        .{ prelude ++ "V:i64=F()", .argument_count },
        .{ prelude ++ "V:i64=F(B:=3)", .argument_count },
        .{ prelude ++ "V:i64=F(1,2,\"x\",4)", .argument_count },
        .{ prelude ++ "V:i64=F(1,Z:=3)", .unknown_parameter },
        .{ prelude ++ "V:i64=F(1,A:=3)", .duplicate_argument },
        .{ prelude ++ "V:i64=F(A:=1,A:=2)", .duplicate_argument },
        .{ prelude ++ "V:i64=F(1,B:=2,3)", .named_argument_order },
        .{ prelude ++ "V:i64=F(1,B:=\"x\")", .type_mismatch },
        .{ prelude ++ "V:i64=F(A:=true)", .type_mismatch },
        .{ prelude ++ "V:i64=G(X:=1)", .unknown_name },
        .{ "H(A:i64=\"x\")<computes>:i64=A", .type_mismatch },
        .{ "H(A:i64=Q)<computes>:i64=A", .unknown_name },
        .{ "F:function(tuple(i64),i64)=Fn(X:i64=1){X}", .unexpected_token },
        .{ prelude ++ "V:i64=F(1,B:=)", .expected_expression },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected argument admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("argument diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}
