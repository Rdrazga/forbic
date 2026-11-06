//! `Case(S, P=>V, ..., _=>D)` selects the first arm whose pattern equals the scrutinee.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "case selects enum integer string and field path arms with a default" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Color:=enum{Red,Green,Blue}\nCfg:=struct{Mode:Color=Color.Green}\nName(C:Color)<computes>:string=Case(C,Color.Red=>\"red\",Color.Green=>\"green\",_=>\"other\")\nScore(N:i64)<computes>:i64=Case(N,1=>10,2=>20,-1=>-10,_=>0)\nWord(S:string)<computes>:i64=Case(S,\"a\"=>1,\"bc\"=>2,_=>3)\nPick(G:Cfg)<computes>:i64=Case(G.Mode,Color.Blue=>3,Color.Green=>2,_=>1)\nOnly(N:i64)<computes>:i64=Case(N,_=>7)\nA<public>:string=Name(Color.Green)\nB<public>:string=Name(Color.Blue)\nC<public>:i64=Score(2)\nD<public>:i64=Score(-1)\nE<public>:i64=Score(99)\nF<public>:i64=Pick(Cfg{})\nG<public>:i64=Word(\"bc\")+Word(\"zz\")\nH<public>:i64=Word(\"a\"+\"\")\nI<public>:i64=Only(5)");
    try std.testing.expectEqualStrings("green", x.get("A").?.string);
    try std.testing.expectEqualStrings("other", x.get("B").?.string);
    for ([_]struct { []const u8, i64 }{ .{ "C", 20 }, .{ "D", -10 }, .{ "E", 0 }, .{ "F", 2 }, .{ "G", 5 }, .{ "H", 1 }, .{ "I", 7 } }) |expected| {
        try std.testing.expectEqual(expected[1], x.get(expected[0]).?.integer);
    }
}

test "case arms are lazy first match wins and nested cases compose" {
    const h = try harness.create();
    defer scratch.release(h);
    // Two arms written alike are `unreachable_arm` (RFC-0090); equal values written differently
    // still select the first.
    const x = try h.execute("var Cell:i64=0\nTick(N:i64)<transacts>:i64=Block{set Cell=Cell+1;N}\nGo(N:i64)<transacts>:i64=Case(N,1=>Tick(10),0+1=>Tick(20),2=>1/0,_=>Tick(30))\nGrid(A:i64,B:i64)<computes>:i64=Case(A,0=>Case(B,0=>1,_=>2),_=>Case(B,0=>3,_=>4))\nX<public>:i64=Go(1)\nY<public>:i64=Go(7)\nZ<public>:i64=Cell\nP<public>:i64=Grid(0,0)+Grid(0,5)*10+Grid(1,0)*100+Grid(1,1)*1000");
    try std.testing.expectEqual(@as(i64, 10), x.get("X").?.integer);
    try std.testing.expectEqual(@as(i64, 30), x.get("Y").?.integer);
    // Only the selected arms ran, and the 1/0 arm was never evaluated.
    try std.testing.expectEqual(@as(i64, 2), x.get("Z").?.integer);
    try std.testing.expectEqual(@as(i64, 1 + 20 + 300 + 4000), x.get("P").?.integer);
}

test "case reports exact diagnostics for malformed arms scrutinees and mismatched types" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "N:i64=1\nA:i64=Case(N)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(N,1=>2)", .case_not_exhaustive },
        .{ "Color:=enum{Red,Green,Blue}\nC:=Color.Red\nA:i64=Case(C,Color.Red=>1,Color.Green=>2)", .case_not_exhaustive },
        .{ "Color:=enum{Red,Green,Blue}\nC:=Color.Red\nA:i64=Case(C,Color.Red=>1,Color.Green=>2,Color.Red=>3)", .unreachable_arm },
        .{ "Color:=enum{Red,Green}\nPick(C:Color,R:Color)<computes>:i64=Case(C,R=>1,Color.Green=>2)", .case_not_exhaustive },
        .{ "Color:=enum{Red,Green}\nC:=Color.Red\nA:i64=Case(C,Color.Red=>1,Color.Green=>\"x\")", .type_mismatch },
        .{ "N:i64=1\nA:i64=Case(N,_=>2,1=>3)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(N,1,_=>2)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(N,1=>2=>3,_=>4)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(N,=>2,_=>4)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(N,1=>,_=>4)", .case_arms },
        .{ "N:i64=1\nA:i64=Case(,1=>2,_=>4)", .case_scrutinee },
        .{ "N:i64=1\nA:i64=Case(N,\"a\"=>2,_=>4)", .type_mismatch },
        .{ "N:i64=1\nA:i64=Case(N,1=>2,_=>\"x\")", .type_mismatch },
        .{ "N:i64=1\nA:string=Case(N,1=>\"a\",2=>3,_=>\"c\")", .type_mismatch },
        .{ "N:i64=1\nA:i64=Case(Q,1=>2,_=>4)", .unknown_name },
        .{ "Case:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected case admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("case diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "a case that lists every enum case needs no default and stays lazy" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Color:=enum{Red,Green,Blue}
        \\Only:=enum{One}
        \\Name(C:Color)<computes>:string=Case(C,Color.Blue=>"blue",Color.Red=>"red",Color.Green=>"green")
        \\Heat(C:Color,N:i64)<computes>:i64=Case(C,
        \\  Color.Red=>10/N,
        \\  Color.Green=>Case(N,0=>-1,_=>N),
        \\  Color.Blue=>N*2)
        \\Pixel:=struct{Tint:Color}
        \\P:=Pixel{Tint:=Color.Green}
        \\A:string=Name(Color.Red)
        \\B:string=Name(Color.Green)
        \\C:string=Name(Color.Blue)
        \\D:i64=Heat(Color.Blue,0)
        \\E:i64=Heat(Color.Green,0)
        \\F:i64=Heat(Color.Red,5)
        \\G:i64=Case(P.Tint,Color.Red=>1,Color.Green=>2,Color.Blue=>3)
        \\O:=Only.One
        \\H:i64=Case(O,Only.One=>7)
    );
    try std.testing.expectEqualStrings("red", x.get("A").?.string);
    try std.testing.expectEqualStrings("green", x.get("B").?.string);
    try std.testing.expectEqualStrings("blue", x.get("C").?.string);
    try std.testing.expectEqual(@as(i64, 0), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("H").?.integer);
}
