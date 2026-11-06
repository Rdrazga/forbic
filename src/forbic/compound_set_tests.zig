//! Compound assignment (`set X op= e`) is a token rewrite to `set X = X op (e)`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "compound assignment covers every operator for cells locals floats and strings" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Count:i64=1\nvar Scale:float=2.0\nvar Label:string=\"a\"\nBump(N:i64)<transacts>:i64=Block{set Count+=N;set Count*=2;Count}\nRun<public>:i64=Bump(3)\nLoc<public>:i64=Block{var X:i64=10;set X-=4;set X/=2;X}\nText<public>:string=Block{var S:string=\"x\";set S+=\"y\"+\"z\";S}\nset Scale*=1.5\nset Label+=\"b\"\nset Count-=1\nset Scale-=0.5");
    try std.testing.expectEqual(@as(i64, 7), x.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("Run").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Loc").?.integer);
    try std.testing.expectEqualStrings("xyz", x.get("Text").?.string);
    try std.testing.expectEqual(@as(f64, 2.5), x.get("Scale").?.floating);
    try std.testing.expectEqualStrings("ab", x.get("Label").?.string);
}

test "compound assignment reads the target before the right-hand side runs" {
    const h = try harness.create();
    defer scratch.release(h);
    // Tick increments Count and returns it; `Count += Tick()` is Count = Count_old + Tick().
    const x = try h.execute("var Count:i64=10\nTick()<transacts>:i64=Block{set Count=Count+1;Count}\nGo<public>:i64=Block{set Count+=Tick();Count}\nWhole<public>:i64=Count");
    // Old value 10 is read first; Tick makes Count 11 and returns 11; the sum 21 is written.
    try std.testing.expectEqual(@as(i64, 21), x.get("Go").?.integer);
    try std.testing.expectEqual(@as(i64, 21), x.get("Whole").?.integer);
}

test "compound assignment rolls back with its attempt and accepts nested right-hand sides" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Count:i64=0\nItems:[]i64=array{5,6}\nTry(I:i64)<transacts>:i64=Attempt(Block{set Count+=Items[I]*(2+1);Count},-1)\nA<public>:i64=Try(1)\nB<public>:i64=Try(9)\nC<public>:i64=Count\nD<public>:i64=Block{set Count+=If(Count>10,1,2);Count}");
    try std.testing.expectEqual(@as(i64, 18), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 18), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 19), x.get("D").?.integer);
}

test "compound assignment keeps exact diagnostics and leaves other tokens alone" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "var N:i64=1\nset N+=\"a\"", .type_mismatch },
        .{ "var N:i64=1\nset N+=1.5", .type_mismatch },
        .{ "var S:string=\"a\"\nset S-=\"b\"", .type_mismatch },
        .{ "N:i64=1\nset N+=1", .not_mutable },
        .{ "var N:i64=1\nset N+=", .expected_expression },
        .{ "var N:i64=1\nset N + = 1", .expected_equal },
        .{ "var N:i64=1\nset Q+=1", .unknown_name },
        .{ "var N:i64=1\nF()<computes>:i64=Block{set N+=1;N}", .set_requires_writes },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected compound admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("compound diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
    // `+=` outside a set statement is not rewritten.
    try std.testing.expect(h.front.compile("A:i64=1\nB:i64=A+=2") == .failed);
}
