//! A failure inside an `If` condition selects the else branch.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

fn count(p: types.Program, kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    var n: usize = 0;
    for (p.nodes) |node| if (node.kind == kind) {
        n += 1;
    };
    return n;
}

test "failable index decides and conversion conditions select the else branch" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{5,1}\nCheck(N:i64)<computes><decides>:i64=Block{Require[N>0];N}\nPick(I:i64)<computes>:i64=If(Items[I]>3,1,0)\nPos(N:i64)<computes>:i64=If(Check[N]>2,10,20)\nBucket(F:float)<computes>:i64=If(Floor[F]>=3,1,2)\nA<public>:i64=Pick(0)\nB<public>:i64=Pick(1)\nC<public>:i64=Pick(7)\nD<public>:i64=Pos(5)\nE<public>:i64=Pos(-1)\nF<public>:i64=Bucket(3.5)\nG<public>:i64=Bucket(1.0e30)\nH<public>:i64=If(Items[9]>0,If(Items[0]>4,1,2),3)");
    for ([_]struct { []const u8, i64 }{ .{ "A", 1 }, .{ "B", 0 }, .{ "C", 0 }, .{ "D", 10 }, .{ "E", 20 }, .{ "F", 1 }, .{ "G", 2 }, .{ "H", 3 } }) |expected| {
        try std.testing.expectEqual(expected[1], x.get(expected[0]).?.integer);
    }
}

test "a failed condition rolls back its writes before the else branch runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0\nItems:[]i64=array{5}\nTry(I:i64)<transacts>:i64=If(Block{set Cell=Cell+10;Items[I]}>3,Cell+100,Cell+200)\nA<public>:i64=Try(0)\nB<public>:i64=Try(4)\nC<public>:i64=Cell");
    // Try(0): the condition commits Cell=10, then adds 100. Try(4): the write is undone, then 10+200.
    try std.testing.expectEqual(@as(i64, 110), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 210), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("C").?.integer);
}

test "bracket-free conditions keep their IR and wrapped conditions are not wrapped twice" {
    const h = try harness.create();
    defer scratch.release(h);
    const plain = try h.compile("N:i64=5\nA<public>:i64=If(N>3,1,2)");
    try std.testing.expectEqual(@as(usize, 0), count(plain, .attempt_begin));
    const wrapped = try h.compile("Items:[]i64=array{5}\nA<public>:i64=If(Attempt(Items[0]>3,false),1,2)");
    try std.testing.expectEqual(@as(usize, 1), count(wrapped, .attempt_begin));
    const implicit = try h.compile("Items:[]i64=array{5}\nA<public>:i64=If(Items[0]>3,1,2)");
    try std.testing.expectEqual(@as(usize, 1), count(implicit, .attempt_begin));
}

test "failable conditions keep exact diagnostics and compose with lambdas and decides bodies" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Items:[]i64=array{5}\nA:i64=If(Items[0],1,2)", .type_mismatch },
        .{ "Items:[]i64=array{5}\nA:i64=If(Items[0]>3,1)", .argument_count },
        .{ "Items:[]i64=array{5}\nA:i64=If(Items[0]>3,1,\"x\")", .type_mismatch },
        .{ "Items:[]i64=array{5}\nA:i64=If(Items[0]>3 1,2)", .unexpected_token },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected condition admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("condition diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        _ = try h.execute("A:i64=42");
    }
    const x = try h.execute("Items:[]i64=array{5,1}\nPick:=Fn[Items:[]i64=Items](I:i64)<computes>:i64{If(Items[I]>3,1,0)}\nGuard(I:i64)<computes><decides>:i64=If(Items[I]>3,Items[I],Items[9])\nA<public>:i64=Pick(0)\nB<public>:i64=Pick(5)\nC<public>:i64=Attempt(Guard[0],-1)\nD<public>:i64=Attempt(Guard[1],-1)");
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
}

test "an else-if ladder of failable conditions works to the control depth" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&source);
    try out.writeAll("Items:[]i64=array{0,1,2,3,4,5,6,7,8,9}\nPick(I:i64)<computes>:i64=");
    const arms = 7;
    for (0..arms) |i| try out.print("If(Items[I]=={d},{d},", .{ i, i * 10 });
    try out.writeAll("-1");
    for (0..arms) |_| try out.writeByte(')');
    try out.writeAll("\nA<public>:i64=Pick(4)\nB<public>:i64=Pick(9)\nC<public>:i64=Pick(20)\n");
    const x = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 40), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("C").?.integer);
}

test "an explicit Require or Fail in a condition still fails the enclosing region" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Strict(N:i64)<computes><decides>:i64=If(Require[N>=0],N+1,Fail[\"negative\"])\nA<public>:i64=Attempt(Strict[4],-1)\nB<public>:i64=Attempt(Strict[-4],-1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
}
