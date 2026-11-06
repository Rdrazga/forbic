//! `using{M}`: unqualified access to the public names of an imported module.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

test "using exposes public functions bindings and types without qualification" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=Twice(4)+Limit\nB<public>:Rec=Rec{V:=3}\nC<public>:i64=L.Twice(2)\nD<public>:Color=Color.Green\nE<public>:i64=Twice(Twice(1))" },
        .{ .path = "lib.forb", .source = "Limit<public>:i64=10\nHidden:i64=99\nTwice<public>(X:i64)<computes>:i64=X*2\nRec<public>:=struct{V:i64=0}\nColor<public>:=enum{Red,Green}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 20_000);
    try std.testing.expectEqual(@as(i64, 18), result.ok.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.ok.elements(result.ok.get("B").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 4), result.ok.get("C").?.integer);
    try std.testing.expectEqual(@as(u32, 1), result.ok.get("D").?.enumeration.index);
    try std.testing.expectEqual(@as(i64, 4), result.ok.get("E").?.integer);
}

test "the importing module may not redeclare a name a using exports and private names stay hidden" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076: a module-level declaration may not reuse a name that a `using` in effect
    // exports; "the module's own name wins" is gone.
    const main = "L:=import{\"lib.forb\"}\nusing{L}\nLimit:i64=1\nA<public>:i64=Limit+Twice(1)";
    const shadowed = [_]modules.Input{
        .{ .path = "main.forb", .source = main },
        .{ .path = "lib.forb", .source = "Limit<public>:i64=10\nTwice<public>(X:i64)<computes>:i64=X*2" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &shadowed });
    try std.testing.expect(bundled == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, bundled.failed.diagnostic.code);
    try std.testing.expectEqualStrings("main.forb", bundled.failed.path);
    try std.testing.expectEqual(std.mem.indexOf(u8, main, "Limit:i64=1").?, @as(usize, bundled.failed.diagnostic.span.start));
    try std.testing.expectEqualStrings("Limit", main[bundled.failed.diagnostic.span.start..bundled.failed.diagnostic.span.end]);
    // A private name of the used module is not exported, so the importing module may declare
    // that name itself, and then it means its own.
    const own = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nLimit:i64=1\nA<public>:i64=Limit+Twice(1)" },
        .{ .path = "lib.forb", .source = "Limit:i64=10\nTwice<public>(X:i64)<computes>:i64=X*2+Limit-10" },
    };
    const kept = h.front.compileBundle(.{ .root = "main.forb", .modules = &own });
    if (kept == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ kept.failed.diagnostic.message(), kept.failed.path });
    try std.testing.expect(kept == .ok);
    try std.testing.expectEqual(@as(i64, 3), (try h.run(kept.ok, 20_000)).ok.get("A").?.integer);
    const hidden = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=Hidden" },
        .{ .path = "lib.forb", .source = "Hidden:i64=99" },
    };
    const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &hidden });
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, refused.failed.diagnostic.code);
}

test "a name exported by two used modules is ambiguous and bad usings are rejected" {
    const h = try harness.create();
    defer scratch.release(h);
    const two = [_]modules.Input{
        .{ .path = "main.forb", .source = "A:=import{\"a.forb\"}\nB:=import{\"b.forb\"}\nusing{A}\nusing{B}\nV<public>:i64=Dup+Only" },
        .{ .path = "a.forb", .source = "Dup<public>:i64=1" },
        .{ .path = "b.forb", .source = "Dup<public>:i64=2\nOnly<public>:i64=5" },
    };
    const ambiguous = h.front.compileBundle(.{ .root = "main.forb", .modules = &two });
    try std.testing.expect(ambiguous == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.ambiguous_call, ambiguous.failed.diagnostic.code);
    const unknown = [_]modules.Input{.{ .path = "main.forb", .source = "using{Z}\nA<public>:i64=1" }};
    const missing = h.front.compileBundle(.{ .root = "main.forb", .modules = &unknown });
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, missing.failed.diagnostic.code);
    try std.testing.expectEqual(types.Diagnostic.Code.module_bundle_required, h.front.compile("using{L}\nA:i64=1").failed.code);
}
