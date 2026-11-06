//! `While(Conditions..., Body)`: loops over mutated locals and cells.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const Text = @import("condition_binding_tests.zig").Text;

test "While threads assigned locals through the loop and leaves cells in place" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{3,4,5}\nvar Cell:i64=0\nSum(N:i64)<transacts>:i64=Block{var I:i64=0;var Total:i64=0;While(I<N,Block{set Total=Total+I;set I=I+1});Total}\nCount(Limit:i64)<transacts>:i64=Block{var K:i64=0;While(K<Limit,Block{set Cell=Cell+10;set K=K+1});Cell*1000+K}\nBound(Max:i64)<transacts>:i64=Block{var I:i64=0;var Last:i64=-1;While(X:=Items[I],X<=Max,Block{set Last=X;set I=I+1});Last*10+I}\nNested()<transacts>:i64=Block{var A:i64=0;var Total:i64=0;While(A<3,Block{var B:i64=0;While(B<A,Block{set Total=Total+1;set B=B+1});set A=A+1});Total}\nNever()<transacts>:logic=Block{var I:i64=5;While(I<0,set I=I-1)}\nInLoop()<transacts>:[]i64=For(N:array{1,2,3},Block{var T:i64=0;var K:i64=0;While(K<N,Block{set T=T+K;set K=K+1});T})\nA<public>:i64=Sum(5)\nB<public>:i64=Count(3)\nC<public>:i64=Bound(4)\nD<public>:i64=Nested()\nE<public>:logic=Never()\nF<public>:i64=Sum(0)\nG<public>:[]i64=InLoop()");
    const expected = [_]struct { []const u8, i64 }{ .{ "A", 10 }, .{ "B", 30003 }, .{ "C", 42 }, .{ "D", 3 }, .{ "F", 0 } };
    for (expected) |entry| try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
    try std.testing.expect(x.get("E").?.boolean);
    const inner = x.elements(x.get("G").?).?;
    try std.testing.expectEqual(@as(usize, 3), inner.len);
    try std.testing.expectEqual(@as(i64, 0), inner[0].integer);
    try std.testing.expectEqual(@as(i64, 1), inner[1].integer);
    try std.testing.expectEqual(@as(i64, 3), inner[2].integer);
}

test "a failing condition ends the loop and undoes its own writes" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1}\nvar Probes:i64=0\nRun()<transacts>:i64=Block{var I:i64=0;While(Block{set Probes=Probes+1;true},Items[I]>0,set I=I+1);I*100+Probes}\nA<public>:i64=Run()\nB<public>:i64=Probes");
    // Two visits probe and pass (I=0 -> 1); the third probe's write is undone when Items[1] fails.
    try std.testing.expectEqual(@as(i64, 100 + 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
}

test "a few hundred iterations stay within the run limits" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Spin(N:i64)<transacts>:i64=Block{var I:i64=0;var Acc:i64=0;While(I<N,Block{set Acc=Acc+I*I;set I=I+1});Acc}\nA<public>:i64=Spin(200)");
    var expected: i64 = 0;
    for (0..200) |i| expected += @as(i64, @intCast(i * i));
    try std.testing.expectEqual(expected, x.get("A").?.integer);
}

test "While reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "F()<transacts>:logic=Block{I:i64=0;While(I<3,set I=I+1)}", .not_mutable },
        .{ "F(N:i64)<transacts>:logic=While(N<3,set N=N+1)", .not_mutable },
        .{ "F()<computes>:logic=Block{var I:i64=0;While(I<3,set I=I+1)}", .local_var_requires_writes },
        .{ "F()<transacts>:logic=While(true)", .macro_syntax },
        .{ "F()<transacts>:logic=While(,true)", .macro_syntax },
        .{ "F()<transacts>:logic=Block{var I:i64=0;While(I,set I=I+1)}", .type_mismatch },
        .{ "F()<transacts>:logic=Block{var I:i64=0;While(I<3,set I=true)}", .type_mismatch },
        .{ "While:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected While admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("While diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        try std.testing.expect(r.failed.span.end <= case[0].len);
        _ = try h.execute("A:i64=42");
    }
}

test "While carries as many locals as its function can capture" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each variable is a capture of the loop's function, next to its one parameter. That list
    // is what ends first: the numerals and the state tuple reach much further.
    const most = types.limits.parameters - 1;
    try std.testing.expect(most < types.limits.tuple_arity);
    var source: Text = .{};
    addLoop(&source, most);
    const x = try h.execute(source.text());
    try std.testing.expectEqual(loopResult(most), x.get("A").?.integer);
    source = .{};
    addLoop(&source, most + 1);
    const r = h.front.compile(source.text());
    try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, r.failed.code);
    // The loop is to blame, not one of its variables.
    try std.testing.expectEqualStrings("While", r.failed.span.text(source.text()));
}

test "While carries thirty locals where functions have the parameters for them" {
    // The bootstrap profile's sixteen parameters hold fifteen loop variables.
    if (types.limits.parameters <= 30) return error.SkipZigTest;
    const h = try harness.create();
    defer scratch.release(h);
    var source: Text = .{};
    addLoop(&source, 30);
    const x = try h.execute(source.text());
    try std.testing.expectEqual(loopResult(30), x.get("A").?.integer);
}

/// A function whose loop runs three times over `count` state variables: the counter, and sums that grow by 1, 2, ...
fn addLoop(source: *Text, count: usize) void {
    source.add("F()<transacts>:i64=Block{{var I:i64=0;", .{});
    for (1..count) |index| source.add("var V{d}:i64=0;", .{index});
    source.add("While(I<3,Block{{", .{});
    for (1..count) |index| source.add("set V{d}=V{d}+{d};", .{ index, index, index });
    source.add("set I=I+1}});", .{});
    for (1..count) |index| source.add("V{d}+", .{index});
    source.add("I*10000}}\nA<public>:i64=F()", .{});
}

fn loopResult(count: usize) i64 {
    return @intCast(3 * ((count - 1) * count / 2) + 30000);
}

test "While bounds its condition buffer at 64 conditions" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]usize{ 64, 65 }) |count| {
        var source: Text = .{};
        source.add("F()<transacts>:logic=While(false,", .{});
        for (1..count) |_| source.add("true,", .{});
        source.add("true)", .{});
        const result = h.front.compile(source.text());
        if (count == 64) {
            try std.testing.expect(result == .ok);
        } else {
            try std.testing.expect(result == .failed);
            try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, result.failed.code);
            try std.testing.expectEqualStrings("While", result.failed.span.text(source.text()));
        }
    }
}
