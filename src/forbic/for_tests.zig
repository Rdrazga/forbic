//! `For` over arrays: map, index, filter forms, nesting, captures, effects, scale and diagnostics.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "For maps indexes and filters arrays" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{3,4,5}\nOffset:i64=100\nNames:[]string=array{\"a\",\"b\"}\nRun(K:i64)<computes>:[]i64=For(X:Items,X*K+Offset)\nA<public>:[]i64=Run(2)\nIdx<public>:[]i64=For(I->X:Items,I*10+X)\nBig<public>:[]i64=For(X:For(Y:Items,Y+1),X*2)\nKept<public>:[]i64=For(X:Items,X>3,X*2)\nKeptIdx<public>:[]i64=For(I->X:Items,I>0,X>3,I+X)\nEmpty<public>:[]i64=For(X:Items,X>9,X)\nNone<public>:[]i64=For(X:Items+Empty+Empty,X)\nLens<public>:[]i64=For(N:Names,N.Length)\nBoth<public>:[]i64=For(X:Items,X>3,X<5,X)");
    try expectIntegers(x, "A", &.{ 106, 108, 110 });
    try expectIntegers(x, "Idx", &.{ 3, 14, 25 });
    try expectIntegers(x, "Big", &.{ 8, 10, 12 });
    try expectIntegers(x, "Kept", &.{ 8, 10 });
    try expectIntegers(x, "KeptIdx", &.{ 5, 7 });
    try expectIntegers(x, "Empty", &.{});
    try expectIntegers(x, "None", &.{ 3, 4, 5 });
    try expectIntegers(x, "Lens", &.{ 1, 1 });
    try expectIntegers(x, "Both", &.{4});
}

test "For bodies capture enclosing names and produce every element type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Pt:=struct{V:i64=0}\nRows:[][]i64=array{array{1,2},array{3}}\nNames:[]string=array{\"a\",\"b\"}\nShift(K:i64,Items:[]i64)<computes>:[]i64=Block{L:=K*2;For(X:Items,X+K+L)}\nGrid<public>:[][]i64=For(R:Rows,For(C:R,C*10))\nWords<public>:[]string=For(N:Names,N+\"!\")\nPoints<public>:[]Pt=For(X:array{5,6},Pt{V:=X})\nShifted<public>:[]i64=Shift(1,array{10,20})\nSums<public>:[]i64=For(R:Rows,For(C:R,C).Length)\nHalves<public>:[]float=For(X:array{1,2},ToFloat(X)*0.5)\nFlags<public>:[]logic=For(X:array{1,2},X>1)");
    const grid = x.elements(x.get("Grid").?).?;
    try std.testing.expectEqual(@as(usize, 2), grid.len);
    try std.testing.expectEqual(@as(i64, 20), x.elements(grid[0]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 30), x.elements(grid[1]).?[0].integer);
    const words = x.elements(x.get("Words").?).?;
    try std.testing.expectEqualStrings("b!", words[1].string);
    const points = x.elements(x.get("Points").?).?;
    try std.testing.expectEqual(@as(i64, 6), x.elements(points[1]).?[0].integer);
    try expectIntegers(x, "Shifted", &.{ 13, 23 });
    try expectIntegers(x, "Sums", &.{ 2, 1 });
    const halves = x.elements(x.get("Halves").?).?;
    try std.testing.expectEqual(@as(f64, 1.0), halves[1].floating);
    const flags = x.elements(x.get("Flags").?).?;
    try std.testing.expect(!flags[0].boolean and flags[1].boolean);
}

test "For runs under transacts effects and its writes roll back with the enclosing attempt" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Total:i64=0\nItems:[]i64=array{3,4,5}\nRun()<transacts>:[]i64=For(X:Items,Block{set Total=Total+X;Total})\nTry()<transacts><decides>:i64=Block{For(X:Items,Block{set Total=Total+100;X});Require[false];1}\nA<public>:[]i64=Run()\nB<public>:i64=Attempt(Try[],-1)\nC<public>:i64=Total");
    try expectIntegers(x, "A", &.{ 3, 7, 12 });
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    // The failed attempt's three writes are undone.
    try std.testing.expectEqual(@as(i64, 12), x.get("C").?.integer);
}

test "For appends in linear space and filters stay correct at moderate size" {
    const h = try harness.create();
    defer scratch.release(h);
    // 200 elements: with copying joins the accumulator alone would need about 20,000 members.
    const x = try h.execute("Count:i64=200\nBase:[]i64=Iterate(Fn(S:[]i64){S+array{S.Length}},Count,array{})\nDoubled<public>:[]i64=For(X:Base,X*2)\nSize<public>:i64=Doubled.Length\nEvens<public>:[]i64=For(X:array{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30},X>20,X)\nLast<public>:i64=Attempt(Doubled[199],-1)");
    try std.testing.expectEqual(@as(i64, 200), x.get("Size").?.integer);
    try std.testing.expectEqual(@as(i64, 398), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(usize, 10), x.elements(x.get("Evens").?).?.len);
}

test "For works inside bundles for every module and keeps provenance valid" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nTotal<public>:[]i64=For(X:L.Items,X+1)\nLocal<public>:[]i64=L.Twice(array{1,2})" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{10,20}\nTwice<public>(V:[]i64)<computes>:[]i64=For(X:V,X*2)" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path, bundled.failed.diagnostic.span.start });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 131072);
    if (result == .failed) std.debug.print("bundle run failed: {s} at {d}\n", .{ result.failed.message(), result.failed.span.start });
    const actual = result.ok;
    try expectIntegers(actual, "Total", &.{ 11, 21 });
    try expectIntegers(actual, "Local", &.{ 2, 4 });
    try std.testing.expect(bundled.ok.source.len > inputs[0].source.len + inputs[1].source.len);
}

test "programs without For carry no library" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "Format(X:i64)<computes>:i64=X\nA<public>:i64=Format(1)";
    const program = try h.compile(source);
    try std.testing.expectEqual(source.len, program.source.len);
    const user = "Items:[]i64=array{1}\nA<public>:[]i64=For(X:Items,X)";
    const with = try h.compile(user);
    try std.testing.expectEqual(user.len + macros.libraryLength(1, .{}), with.source.len);
}

test "For reports exact diagnostics and blames the For call for generated code" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "Items:[]i64=array{1,2}\nN:i64=3\nvar Cell:i64=0\n";
    for ([_]Case{
        // RFC-0090: a first clause that is not a generator is a filter, which is logic.
        .{ prelude ++ "A:[]i64=For(Items,X)", .type_mismatch },
        .{ prelude ++ "A:[]i64=For(X:Items)", .for_syntax },
        .{ prelude ++ "A:[]i64=For(X:,X)", .for_syntax },
        // RFC-0090: a first clause that is not a generator is read as a filter.
        .{ prelude ++ "A:[]i64=For(:Items,X)", .expected_expression },
        .{ prelude ++ "A:[]i64=For(X:Items,)", .for_syntax },
        .{ prelude ++ "A:[]i64=For(X:Items,X", .for_syntax },
        .{ prelude ++ "A:[]i64=For(X:N,X)", .type_mismatch },
        .{ prelude ++ "A:[]i64=For(X:Items,Q)", .unknown_name },
        .{ prelude ++ "A:[]i64=For(X:Items,X+true)", .type_mismatch },
        .{ prelude ++ "A:[]string=For(X:Items,X)", .type_mismatch },
        .{ prelude ++ "F()<computes>:[]i64=For(X:Items,Block{set Cell=X;X})", .set_requires_writes },
        .{ prelude ++ "A:[]i64=For(X:Items,X>true,X)", .type_mismatch },
        .{ prelude ++ "A:[]i64=For(X:Items,N,X)", .type_mismatch },
        .{ prelude ++ "For:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected For admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("For diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        // Every diagnostic points into the user's own text, never into the appended library.
        try std.testing.expect(r.failed.span.end <= case[0].len);
        _ = try h.execute("A:i64=42");
    }
    // Errors in generated code are blamed on the For call itself.
    const generated = h.front.compile(prelude ++ "A:[]i64=For(X:N,X)");
    try std.testing.expectEqual(std.mem.indexOf(u8, prelude ++ "A:[]i64=For(X:N,X)", "For(").?, generated.failed.span.start);
}
