//! Type aliases are transparent names for structural types.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "aliases name arrays options maps functions and nest in fields and generics" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Grid:=[][]i64\nPick:=option(i64)\nTable:=map(string,Grid)\nTransform:=function(tuple(i64),i64)\nWide:=Grid\nCell:=struct{Rows:Wide=array{array{1,2},array{3}}}\nTotal(G:Grid)<computes>:i64=Attempt(G[1][0],-1)\nApply[T:type](F:Transform,X:i64)<computes>:i64{F(X)}\nDouble(N:i64)<computes>:i64=N*2\nData:Grid=array{array{7,8},array{9}}\nMaybe:Pick=option{4}\nBook:Table=map{\"a\"=>Data}\nA<public>:i64=Total(Data)\nB<public>:i64=Apply[i64](Double,21)\nC<public>:i64=Total(Cell{}.Rows)\nD<public>:i64=Or(Maybe,0)\nE<public>:i64=Total(Or(Lookup(Book,\"a\"),array{}))");
    try std.testing.expectEqual(@as(i64, 9), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("E").?.integer);
}

test "aliases are transparent: aliased and spelled types are the same type" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Grid:=[][]i64\nA:Grid=array{array{1}}\nB:[][]i64=A\nSpelled(G:[][]i64)<computes>:i64=G.Length\nC<public>:i64=Spelled(A)");
    // One array-of-array-of-i64 definition exists, however it is spelled.
    var arrays: usize = 0;
    for (p.definitions) |definition| if (definition == .array) {
        arrays += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), arrays);
}

test "alias declarations reject misuse with exact diagnostics and healthy reuse" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Grid<private>:=[]i64", .unsupported_specifier },
        .{ "Grid:=[]i64\nGrid:=[]string", .duplicate_name },
        .{ "Grid:=[]i64\nGrid:i64=1", .duplicate_name },
        .{ "Grid:=[]i64\nGrid(X:i64)<computes>:i64=X", .duplicate_name },
        .{ "Pair:=struct{X:i64=0}\nPair:=[]i64", .duplicate_name },
        .{ "A:Late=array{1}\nLate:=[]i64", .unsupported_type },
        .{ "Loop:=Loop", .expected_name },
        .{ "Nope:=Unknown", .unknown_name },
        .{ "i64:=[]i64", .expected_name },
        .{ "Grid:=[]i64 extra", .unexpected_token },
        .{ "Grid:=[]i64\nV:i64=Grid", .unknown_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected alias admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("alias diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
}
