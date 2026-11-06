//! Functional record updates (`WithField`) and field-path assignment (`set P.A.B = e`).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const records = "Inner:=struct{X:i64=1\nY:string=\"a\"}\nOuter:=struct{Name:string=\"n\"\nIn:Inner=Inner{}\nCount:i64=0}\n";

test "WithField returns an updated copy and leaves the original untouched" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(records ++ "Base:Outer=Outer{}\nMoved<public>:Outer=WithField(Base,Count,5)\nDeep<public>:Outer=WithField(Base,In,WithField(Base.In,X,9))\nSame<public>:i64=Base.Count+Base.In.X\nNamed<public>:string=WithField(Base,Name,\"z\").Name\nChain<public>:i64=WithField(WithField(Base,Count,2),Count,3).Count");
    try std.testing.expectEqual(@as(i64, 1), x.get("Same").?.integer);
    try std.testing.expectEqualStrings("z", x.get("Named").?.string);
    try std.testing.expectEqual(@as(i64, 3), x.get("Chain").?.integer);
    const moved = x.elements(x.get("Moved").?).?;
    try std.testing.expectEqual(@as(i64, 5), moved[2].integer);
    try std.testing.expectEqualStrings("n", moved[0].string);
    const deep = x.elements(x.get("Deep").?).?;
    try std.testing.expectEqual(@as(i64, 9), x.elements(deep[1]).?[0].integer);
}

test "field path assignment updates cells and locals with compound forms and strict order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(records ++ "var Player:Outer=Outer{}\nTick()<transacts>:i64=Block{set Player.Count=Player.Count+1;Player.Count}\nset Player.Count=7\nset Player.In.X=40\nset Player.In.Y=\"b\"\nset Player.Count+=3\nBump()<transacts>:i64=Block{set Player.Count*=2;Player.Count}\nSeen<public>:i64=Bump()\nLoc<public>:i64=Block{var Q:Outer=Outer{};set Q.In.X+=9;set Q.Name=\"z\";Q.In.X}\nOrder<public>:i64=Block{set Player.Count=Player.Count+Tick();Player.Count}");
    try std.testing.expectEqual(@as(i64, 20), x.get("Seen").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("Loc").?.integer);
    // Old Count 20 is read first, Tick makes it 21 and returns 21: 41.
    try std.testing.expectEqual(@as(i64, 41), x.get("Order").?.integer);
    const player = x.elements(x.get("Player").?).?;
    try std.testing.expectEqual(@as(i64, 41), player[2].integer);
    const inner = x.elements(player[1]).?;
    try std.testing.expectEqual(@as(i64, 40), inner[0].integer);
    try std.testing.expectEqualStrings("b", inner[1].string);
}

test "field updates roll back with their attempt and compose with loops" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(records ++ "var P:Outer=Outer{}\nItems:[]i64=array{4,5}\nTry(I:i64)<transacts>:i64=Attempt(Block{set P.Count+=10;set P.In.X=Items[I];P.In.X},P.Count)\nStep(S:Outer)<computes>:Outer=WithField(S,Count,S.Count+1)\nA<public>:i64=Try(1)\nB<public>:i64=Try(7)\nC<public>:i64=P.Count\nD<public>:i64=Iterate(Step,5,Outer{}).Count");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    // The failed attempt's two writes are undone: Count is 10 (from A) and B falls back to it.
    try std.testing.expectEqual(@as(i64, 10), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("D").?.integer);
}

test "field updates reject non records unknown fields wrong types and malformed paths" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ records ++ "A:Outer=WithField(Outer{},Missing,1)", .unknown_field },
        .{ records ++ "A:Outer=WithField(Outer{},Count,\"x\")", .type_mismatch },
        .{ records ++ "A:Outer=WithField(1,Count,1)", .type_mismatch },
        .{ records ++ "A:Outer=WithField(Outer{},Count)", .argument_count },
        .{ records ++ "A:Outer=WithField(Outer{},Count,1,2)", .argument_count },
        .{ records ++ "A:Outer=WithField(Outer{},3,1)", .expected_field },
        .{ records ++ "var P:Outer=Outer{}\nset P.Missing=1", .unknown_field },
        .{ records ++ "var P:Outer=Outer{}\nset P.Count=\"x\"", .type_mismatch },
        .{ records ++ "var P:Outer=Outer{}\nset P.Name.Length=1", .type_mismatch },
        .{ records ++ "P:Outer=Outer{}\nset P.Count=1", .not_mutable },
        .{ records ++ "var N:i64=1\nset N.X=1", .type_mismatch },
        .{ records ++ "var P:Outer=Outer{}\nset P.Count-=", .expected_expression },
        .{ records ++ "WithField:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected field update admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("field update diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
}
