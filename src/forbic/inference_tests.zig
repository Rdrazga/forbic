//! `Name := expression` infers the type of immutable bindings and block locals.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "inferred bindings take the type of their expression at the top level and in blocks" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Count:=42\nName:=\"雪\"\nRatio:=2.5\nFlag:=Count>40\nItems:=array{1,2,3}\nPair:=tuple{1,\"a\"}\nBox:=struct{N:i64=7}\nMade:=Box{}\nTotal:=Count+Items.Length\nTwice(N:i64)<computes>:i64=Block{Half:=N/2;Half*4}\nLoc<public>:i64=Block{X:=10;Y:=X*2;Y+X}\nText<public>:string=Name+ToString(Count)\nBig<public>:i64=Twice(10)\nField<public>:i64=Made.N\nPicked<public>:i64=Pair(0)\nOk<public>:logic=Flag\nHere<public>:i64=Block{Nested:=Block{Inner:=3;Inner+1};Nested*2}");
    try std.testing.expectEqual(@as(i64, 45), x.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 30), x.get("Loc").?.integer);
    try std.testing.expectEqualStrings("雪42", x.get("Text").?.string);
    try std.testing.expectEqual(@as(i64, 20), x.get("Big").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Field").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Picked").?.integer);
    try std.testing.expect(x.get("Ok").?.boolean);
    try std.testing.expectEqual(@as(i64, 8), x.get("Here").?.integer);
}

test "inference agrees with declared types and keeps definitions and aliases distinct" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Grid:=[][]i64\nColor:=enum{Red,Blue}\nPoint:=struct{X:i64=1}\nShade:=Color.Blue\nWide:=Grid\nData:Wide=array{array{1,2}}\nGuess:=Data\nSame:[][]i64=Guess\nTakes(G:Grid)<computes>:i64=G.Length\nN<public>:i64=Takes(Guess)\nIsBlue<public>:logic=(Shade==Color.Blue)");
    try std.testing.expectEqual(@as(i64, 1), x.get("N").?.integer);
    try std.testing.expect(x.get("IsBlue").?.boolean);
}

test "inference reports exact diagnostics and never infers mutables or contextual empties" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Empty:=array{}", .array_type_required },
        .{ "None:=option{}", .contextual_type_required },
        .{ "Bad:=Unknown", .unknown_name },
        .{ "Bad:=1+\"a\"", .type_mismatch },
        .{ "A:=1\nA:=2", .duplicate_name },
        .{ "A:=B\nB:=1", .unknown_name },
        .{ "F()<transacts>:i64=Block{var X:=1;X}", .expected_type },
        .{ "F()<computes>:i64=Block{X:=Y;X}", .unknown_name },
        .{ "F()<computes>:i64=Block{X:=1;X:=2;X}", .duplicate_name },
        .{ "F()<computes>:i64=Block{X:=array{};1}", .array_type_required },
        .{ "Total<public>:=Missing", .unknown_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected inference admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("inference diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
}
