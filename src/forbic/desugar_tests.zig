//! Regression tests for the token-level desugar passes (compound and path `set`, `Case`,
//! failable `If` conditions): precedence, nesting, layout, scoping and bounded scans.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const profile = @import("profile.zig");
const harness = @import("generic_function_tests.zig");

test "a Case keeps its precedence and nests in default arms" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("N:i64=2\nOnly(M:i64)<computes>:i64=Case(M,_=>1+2)*3\nDeep(M:i64)<computes>:i64=Case(M,_=>Case(M,2=>10,_=>20))\nSum(M:i64)<computes>:i64=Case(M,2=>1,_=>0)+Case(M,3=>1,_=>5)*2\nA<public>:i64=Only(N)\nB<public>:i64=Deep(2)\nC<public>:i64=Deep(3)\nD<public>:i64=Sum(2)");
    try std.testing.expectEqual(@as(i64, 9), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 20), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 11), x.get("D").?.integer);
}

test "a Case accepts newlines around its parts and rejects effectful patterns" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Score(N:i64)<computes>:i64=Case(\n  N,\n  1=>10,\n  2=>20,\n  _=>0\n)\nA<public>:i64=Score(2)\nB<public>:i64=Score(9)");
    try std.testing.expectEqual(@as(i64, 20), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("B").?.integer);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "var Cell:i64=0\nBump()<transacts>:i64=Block{set Cell=Cell+1;5}\nGo()<transacts>:i64=Case(Cell,Bump()=>1,1=>2,_=>3)", .case_pattern },
        .{ "Items:[]i64=array{1}\nA:i64=Case(0,Items[0]=>1,_=>2)", .case_pattern },
        .{ "N:i64=1\nItems:[]i64=array{1}\nA:i64=Case(N,Items[0]=>1,_=>2)", .case_pattern },
    }) |case| {
        const r = h.front.compile(case[0]);
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("case diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
    }
}

test "path sets nest inside the value of another path set" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Box:=struct{X:i64=0}\nvar Items:[]i64=array{4,5}\nvar Q:Box=Box{}\nRun()<transacts><decides>:i64=Block{set Items[0]=Block{set Q.X=5;7};Q.X*10+Items[0]}\nTotal<public>:i64=Attempt(Run[],-1)\nAgain<public>:i64=Attempt(Block{set Items[1]=Block{set Q.X+=1;2};Q.X*100+Items[1]},-1)");
    try std.testing.expectEqual(@as(i64, 57), x.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 602), x.get("Again").?.integer);
}

test "an import alias only disables path sets in the module that declares it" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "Geo:=import{\"geo.forb\"}\nResult<public>:i64=Geo.Run()" },
        .{ .path = "geo.forb", .source = "Pt:=struct{X:i64=0}\nvar Geo:Pt=Pt{}\nRun<public>()<transacts>:i64=Block{set Geo.X=7;Geo.X}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s}\n", .{bundled.failed.diagnostic.message()});
    try std.testing.expect(bundled == .ok);
    const actual = (try h.run(bundled.ok, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 7), actual.get("Result").?.integer);
}

test "an If condition that only starts with Attempt is still failable" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1}\nA<public>:i64=If(Attempt(Items[0]>0,false) and Items[5]>0,1,0)\nB<public>:i64=If(Attempt(Items[0]>0,false),1,0)\nC<public>:i64=If(Items[5]>0 and Attempt(Items[0]>0,false),1,2)");
    try std.testing.expectEqual(@as(i64, 0), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("C").?.integer);
}

test "unbalanced openers fail cleanly at the end of input" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "var X:i64=1\nset X += (1", .unmatched_parenthesis },
        .{ "Box:=struct{X:i64=0}\nvar P:Box=Box{}\nset P.X = (1", .unmatched_parenthesis },
        .{ "var Items:[]i64=array{1}\nset Items[0 = 1", .expected_equal },
        .{ "A:i64=If(1<2, 3", .unmatched_parenthesis },
        .{ "A:i64=Case(1, 1=>2", .case_arms },
    }) |case| {
        const r = h.front.compile(case[0]);
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "thousands of rewritten statements compile without quadratic token movement" {
    if (!std.mem.eql(u8, profile.active.name, "program")) return error.SkipZigTest;
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Box:=struct{X:i64=0}\nvar P:Box=Box{}\nvar Items:[]i64=array{0,0}\nRun()<transacts><decides>:i64=Block{");
    const count = 3000;
    for (0..count) |_| try source.appendSlice(std.testing.allocator, "set P.X+=1;set Items[1]+=2;");
    try source.appendSlice(std.testing.allocator, "P.X+Items[1]}\nTotal<public>:i64=Attempt(Run[],-1)\n");
    const start = std.Io.Clock.awake.now(std.testing.io);
    _ = try h.compile(source.items);
    const elapsed_ms = @divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms);
    // Linear passes finish in tens of milliseconds; the old in-place splices took seconds.
    try std.testing.expect(elapsed_ms < 2000);
}
