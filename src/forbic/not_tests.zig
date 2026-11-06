//! `Not[E]`: succeeds exactly when `E` fails, and undoes what `E` did.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "Not succeeds when its operand fails and fails when it succeeds" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Items:[]i64=array{1,2}\nvar Hits:i64=0\nAbsent(I:i64)<computes><decides>:i64=Block{Not[Items[I]];7}\nProbe()<transacts><decides>:i64=Block{Not[Block{set Hits=Hits+1;Items[9]}];Hits}\nTwice()<transacts><decides>:i64=Block{Not[Block{set Hits=Hits+10;Items[0]}];Hits}\nStrict(I:i64)<computes><decides>:i64=Block{Not[Require[Items[I]>1]];I}\nDouble(I:i64)<computes><decides>:i64=Block{Not[Not[Items[I]]];I}\nA<public>:i64=Attempt(Absent[5],-1)\nB<public>:i64=Attempt(Absent[0],-1)\nC<public>:i64=Attempt(Probe[],-1)\nD<public>:i64=Hits\nE<public>:i64=Attempt(Twice[],-1)\nF<public>:i64=Hits\nG<public>:i64=Attempt(Strict[0],-1)\nH<public>:i64=Attempt(Strict[1],-1)\nI<public>:i64=Attempt(Double[1],-1)\nJ<public>:i64=Attempt(Double[8],-1)");
    const expected = [_]struct { []const u8, i64 }{ .{ "A", 7 }, .{ "B", -1 }, .{ "C", 0 }, .{ "D", 0 }, .{ "E", -1 }, .{ "F", 0 }, .{ "G", 0 }, .{ "H", -1 }, .{ "I", 1 }, .{ "J", -1 } };
    for (expected) |entry| try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
}

test "Not reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const prelude = "Items:[]i64=array{1}\n";
    for ([_]Case{
        .{ prelude ++ "A:i64=Block{Not[Items[0]];1}", .failure_context_required },
        .{ prelude ++ "A:i64=Attempt(Block{Not[];1},0)", .macro_syntax },
        .{ prelude ++ "A:i64=Attempt(Block{Not[Q];1},0)", .unknown_name },
        .{ "Not:i64=1", .expected_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected Not admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("Not diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}
