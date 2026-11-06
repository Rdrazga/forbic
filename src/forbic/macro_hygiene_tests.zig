//! Regressions from the review of the macro system: generics, joined views, hygiene, spans.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

test "For inside a generic function specializes once per type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Twice[T:type](Items:[]T)<computes>:[]T{For(X:Items,X)}\nA<public>:[]i64=Twice[i64](array{1,2})\nB<public>:[]string=Twice[string](array{\"a\"})\nC<public>:[]i64=Twice[i64](array{3})");
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("A").?).?.len);
    try std.testing.expectEqualStrings("a", x.elements(x.get("B").?).?[0].string);
    try std.testing.expectEqual(@as(i64, 3), x.elements(x.get("C").?).?[0].integer);
}

test "joined views may contain empty aggregates" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("L:[][]i64=array{array{1}}\nR:[][]i64=array{array{}}\nJ<public>:[][]i64=L+R\nNone(X:i64)<computes>:[]i64=array{}\nRows<public>:[][]i64=For(X:array{1,2},None(X))");
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("J").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("Rows").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.elements(x.get("Rows").?).?[1]).?.len);
}

test "the items of For are one parenthesized expression" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1,2}\nR<public>:[]i64=For(X:Items+\n  Items,X)");
    try std.testing.expectEqual(@as(usize, 4), x.elements(x.get("R").?).?.len);
    const r = h.front.compile("Items:[]i64=array{1}\nR:[]i64=For(X:Items;K:=5,X+K)");
    try std.testing.expect(r == .failed);
}

test "generated names are reserved for generated code" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "F(__for_items:[]i64)<computes>:[]i64=For(X:array{1,2},X+__for_items.Length)", .expected_parameter },
        .{ "A:i64=Block{__x:=1;__x}", .expected_name },
        .{ "__a:i64=1", .expected_name },
        .{ "__elem:=struct{V:i64=0}", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected generated-name admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        try std.testing.expectEqual(case[1], r.failed.code);
    }
    // Generated code itself still declares them.
    _ = try h.execute("A<public>:[]i64=For(X:array{1},X)");
}

test "diagnostics stay inside the user's text" {
    const h = try harness.create();
    defer scratch.release(h);
    // A literal that mentions For( and never ends: the library's first newline must not end it.
    const open = "A:string=\"For(";
    const lexical = h.front.compile(open);
    try std.testing.expectEqual(types.Diagnostic.Code.unterminated_string, lexical.failed.code);
    try std.testing.expect(lexical.failed.span.end <= open.len);
    // Running out of input blames the end of the user's own text, not a For call.
    const unfinished = "Items:[]i64=array{1}\nA:[]i64=For(X:Items,X)\nB:i64=(1";
    const parse = h.front.compile(unfinished);
    try std.testing.expect(parse == .failed);
    try std.testing.expect(parse.failed.span.end <= unfinished.len);
    // In a bundle the error belongs to the module whose text ended, even if For is only mentioned.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\n# For(\nA:i64=(1" },
        .{ .path = "lib.forb", .source = "Size<public>:i64=1" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    try std.testing.expect(bundled == .failed);
    try std.testing.expectEqualStrings("main.forb", bundled.failed.path);
}

test "failures inside generated functions point into the user's text" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "A<public>:[]i64=For(X:array{1,2,3},X)";
    const program = try h.compile(source);
    var saw_failure = false;
    for (1..80) |budget| {
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, @intCast(budget));
        if (reference == .ok) continue;
        saw_failure = true;
        try std.testing.expect(reference.failed.span.end <= source.len);
        const actual = h.runtime.evaluate(program, @intCast(budget));
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
    }
    try std.testing.expect(saw_failure);
}

test "calls are counted through carriage returns" {
    try std.testing.expectEqual(@as(usize, 1), macros.callCount("A=For\r(X:Items,X)"));
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1,2}\nA<public>:[]i64=For\r(X:Items,X)");
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("A").?).?.len);
}

test "a parameter may not shadow a global, and an Fn body captures the enclosing local and sees the global" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076 rule 1: the parameter that shadowed the global (RFC-0054 had the body capture
    // it in place of the global) is refused, at its name.
    const shadowing = "X:i64=1\nF(X:i64)<computes>:i64=Iterate(Fn(S:i64)<computes>:i64{S+X},1,0)\nA<public>:i64=F(100)";
    const r = h.front.compile(shadowing);
    try std.testing.expect(r == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, r.failed.code);
    try std.testing.expectEqual(std.mem.indexOf(u8, shadowing, "F(X").? + 2, r.failed.span.start);
    // RFC-0054: bodies capture the enclosing local, and still see the global beside it.
    const x = try h.execute("X:i64=1\nF(Y:i64)<computes>:i64=Iterate(Fn(S:i64)<computes>:i64{S+Y},1,0)\nG(Y:i64)<computes>:i64=Iterate(Fn(S:i64)<computes>:i64{S+X+Y},1,0)\nA<public>:i64=F(100)\nB<public>:i64=G(100)");
    try std.testing.expectEqual(@as(i64, 100), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 101), x.get("B").?.integer);
}
