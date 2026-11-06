//! Anonymous functions without `[...]` capture what they name, may omit the effect and
//! result type, and keep the explicit forms working.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

// `G` is `Snap()`: the `Fn` names the local `L`, so `L` is shared and the `Fn` sees `set L=50`
// (RFC-0085, I13, Q1); it was 2, the snapshot of RFC-0054.
test "bodies capture enclosing parameters locals and outer captures by value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Offset:i64=100\nRec:=struct{V:i64=3}\nvar Cell:i64=1\nMake(N:i64)<computes>:function(tuple(i64),i64)=Fn(X:i64){N+X}\nTwice(K:i64)<computes>:i64=Iterate(Fn(S:i64){S+K},3,1)\nBoth(A:i64,B:string)<computes>:string=Block{G:=Fn(Z:i64){B+ToString(Z+A)};G(5)}\nField(R:Rec)<computes>:i64=Block{F:=Fn(V:i64){R.V+V};F(10)}\nNested(A:i64)<computes>:i64=Block{O:=Fn(B:i64){Block{I:=Fn(C:i64){A+B+C};I(1)}};O(20)}\nBump(D:i64)<transacts>:i64=Block{F:function<transacts>(tuple(i64),i64)=Fn(X:i64){Block{set Cell=Cell+X+D;Cell}};F(2)}\nSnap()<transacts>:i64=Block{var L:i64=1;F:=Fn(X:i64){L+X};set L=50;F(1)}\nShadow(X:i64)<computes>:i64=Block{F:=Fn(Y:i64){Y*2};F(7)+X}\nA<public>:i64=Make(5)(10)\nB<public>:i64=Twice(4)\nC<public>:string=Both(1,\"v\")\nD<public>:i64=Field(Rec{})\nE<public>:i64=Nested(100)\nF<public>:i64=Bump(10)\nG<public>:i64=Snap()\nH<public>:i64=Offset\nI<public>:i64=Shadow(1)");
    const expected = [_]struct { []const u8, i64 }{ .{ "A", 15 }, .{ "B", 13 }, .{ "D", 13 }, .{ "E", 121 }, .{ "F", 13 }, .{ "G", 51 }, .{ "H", 100 }, .{ "I", 15 } };
    for (expected) |entry| try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
    try std.testing.expectEqualStrings("v6", x.get("C").?.string);
    try std.testing.expect(h.front.anonymous_count == 0 and h.front.local_count == 0);
}

test "omitted result types are inferred from the body for every value shape" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Rec:=struct{V:i64=0}\nHalf:function(tuple(i64),float)=Fn(X:i64){ToFloat(X)*0.5}\nWord:function(tuple(i64),string)=Fn(X:i64){\"n\"+ToString(X)}\nBox:function(tuple(i64),Rec)=Fn(X:i64){Rec{V:=X}}\nPair:function(tuple(i64),[]i64)=Fn(X:i64){array{X,X+1}}\nAdder(K:i64)<computes>:function(tuple(i64),function(tuple(i64),i64))=Fn(X:i64){Fn(Y:i64){K+X+Y}}\nFlag:function(tuple(),logic)=Fn(){true}\nUnit:function(tuple(),i64)=Fn(){7}\nA<public>:float=Half(5)\nB<public>:string=Word(3)\nC<public>:Rec=Box(4)\nD<public>:[]i64=Pair(8)\nE<public>:i64=Adder(100)(20)(3)\nF<public>:logic=Flag()\nG<public>:i64=Unit()\nInferred<public>:i64=Block{L:=Fn(X:i64){X+1};L(1)}");
    try std.testing.expectEqual(@as(f64, 2.5), x.get("A").?.floating);
    try std.testing.expectEqualStrings("n3", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 4), x.elements(x.get("C").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 9), x.elements(x.get("D").?).?[1].integer);
    try std.testing.expectEqual(@as(i64, 123), x.get("E").?.integer);
    try std.testing.expectEqual(true, x.get("F").?.boolean);
    try std.testing.expectEqual(@as(i64, 7), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Inferred").?.integer);
}

test "effects come from the expected type then the enclosing function and decides must be written" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0\nItems:[]i64=array{5,6}\nPure(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N)\nRun()<transacts>:i64=Block{F:=Fn(X:i64){Block{set Cell=Cell+X;Cell}};F(3)+F(4)}\nPick(I:i64)<computes>:i64=Attempt(Fn(J:i64)<computes><decides>{Items[J]}[I],-1)\nA<public>:i64=Pure(Fn(X:i64){X*10},4)\nB<public>:i64=Run()\nC<public>:i64=Pick(1)\nD<public>:i64=Pick(5)");
    try std.testing.expectEqual(@as(i64, 40), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
}

test "explicit captures and effect annotations keep their meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[M:i64=N+1](X:i64)<computes>:i64{M+X}\nA<public>:i64=Make(4)(10)");
    try std.testing.expectEqual(@as(i64, 15), x.get("A").?.integer);
}

test "anonymous function bodies report exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "F:function(tuple(i64),i64)=Fn(X:i64){Q+X}", .unknown_name },
        .{ "Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[M:i64=1](X:i64)<computes>:i64{N+X}", .unknown_name },
        .{ "F:function(tuple(i64),string)=Fn(X:i64){X}", .type_mismatch },
        .{ "Items:[]i64=array{1}\nF:function(tuple(i64),i64)=Fn(X:i64){Items[X]}", .failure_context_required },
        .{ "var Cell:i64=0\nF:function(tuple(i64),i64)=Fn(X:i64){Block{set Cell=X;X}}", .set_requires_writes },
        .{ "F:function(tuple(i64),i64)=Fn(X:i64){}", .expected_expression },
        .{ "F:function(tuple(i64),i64)=Fn(X:i64){X+1", .unexpected_token },
        .{ "Make(N:i64)<computes>:i64=Block{F:=Fn(X:i64){N+X};F(true)}", .type_mismatch },
        .{ "F:function(tuple(i64),i64)=Fn(X:i64,X:i64){X}", .duplicate_name },
        .{ "F:=Fn(X:i64){array{}}", .array_type_required },
        // RFC-0076 rule 1: an Fn parameter may not take the name of an enclosing parameter.
        .{ "Shadow(X:i64)<computes>:i64=Block{F:=Fn(X:i64){X*2};F(7)+X}", .shadowed_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected closure admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("closure diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
        try std.testing.expect(h.front.anonymous_count == 0 and h.front.local_count == 0 and h.front.local_checkpoint_count == 0);
    }
}
