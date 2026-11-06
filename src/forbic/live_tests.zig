//! Live variables, P4.1 (RFC-0084): `var live`, `set live` and `live` on module cells, their
//! tracking, heights, propagation and bounds, rollback, in both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");
test {
    _ = @import("live_forgery_tests.zig");
    _ = @import("live_model.zig");
}

pub const fuel: u64 = 1 << 22;

/// Runs `source` on both machines through the harness, which compares everything they record
/// (the live record included) and admits the report of each by the replay.
pub fn run(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const p = try h.compile(source);
    const outcome = try h.run(p, fuel);
    if (outcome == .failed) {
        std.debug.print("run failed: {t} at '{s}'\n", .{ outcome.failed.code, p.source[outcome.failed.span.start..outcome.failed.span.end] });
        return error.RunFailed;
    }
    return outcome.ok;
}

pub fn report(execution: evaluator.Execution, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try reporting.write(&out, execution, false, .{ .work = @max(1 << 24, types.limits.report_work) });
    return out.buffered();
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try report(execution, &buffer));
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}

/// Both machines stop with `code` at the text `at`.
pub fn expectFailure(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const p = try h.compile(source);
    const outcome = try h.run(p, fuel);
    if (outcome != .failed) {
        std.debug.print("expected {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (outcome.failed.code != code) std.debug.print("got {t} at '{s}'\n", .{ outcome.failed.code, p.source[outcome.failed.span.start..outcome.failed.span.end] });
    try std.testing.expectEqual(code, outcome.failed.code);
    try std.testing.expectEqualStrings(at, p.source[outcome.failed.span.start..outcome.failed.span.end]);
}

/// The compiler refuses `source` with `code` at the text `at`.
pub fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code or !std.mem.eql(u8, at, source[result.failed.span.start..result.failed.span.end])) std.debug.print("got {t} at '{s}' for {s}\n", .{ result.failed.code, source[result.failed.span.start..result.failed.span.end], source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

/// The run's report in `full`, `digest` (several windows, reclaiming often) and the record of an
/// `off` run are the same, and both machines agree in each mode.
pub fn expectEveryMode(source: []const u8) !void {
    _ = try everyMode(source);
}

/// `expectEveryMode`, returning the reclamations of the digest runs.
pub fn everyMode(source: []const u8) !u64 {
    var reclaims: u64 = 0;
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const full = try f.h.run(p, fuel);
    if (full != .ok) {
        std.debug.print("full run failed: {t} at '{s}'\n", .{ full.failed.code, p.source[full.failed.span.start..full.failed.span.end] });
        return error.TestUnexpectedResult;
    }
    const stored = full.ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{ .work = @max(1 << 24, types.limits.report_work) });
    const expected = out.buffered();
    const record = stored.live;
    for ([_]u32{ 1, 3, 64, types.ControlStorage.default_trace_window }) |window| {
        f.mode(.digest, window);
        f.h.control.reclaim_floor = 16;
        f.h.runtime.machine.control.reclaim_floor = 16;
        f.again.control.reclaim_floor = 16;
        f.again.control.trace_window = window;
        defer {
            f.h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
            f.h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
            f.again.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        }
        const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, fuel);
        const actual = f.h.runtime.evaluate(p, fuel);
        if (reference != .ok or actual != .ok) return error.TestUnexpectedResult;
        try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
        reclaims += actual.ok.reclaims;
        try std.testing.expectEqualDeep(record, reference.ok.live);
        try std.testing.expectEqualDeep(record, actual.ok.live);
        out = .fixed(f.replayed);
        _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, fuel), false, .{ .work = @max(1 << 24, types.limits.report_work) });
        try std.testing.expectEqualStrings(expected, out.buffered());
        _ = try reporting.validateReplayed(reference.ok, f.again.producer(p, fuel), false, .{ .work = @max(1 << 24, types.limits.report_work) });
    }
    f.mode(.off, types.ControlStorage.default_trace_window);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, fuel);
    const actual = f.h.runtime.evaluate(p, fuel);
    if (reference != .ok or actual != .ok) return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(record, reference.ok.live);
    try std.testing.expectEqualDeep(record, actual.ok.live);
    return reclaims;
}

const contract =
    \\var Source:i64 = 1
    \\var live Doubled:i64 = Source * 2
    \\live Label:string = "source {Source}"
    \\var Manual:i64 = 0
    \\set live Manual = Source + 3
    \\set Source = 10
    \\Seen:tuple(i64, string, i64) = tuple{Doubled, Label, Manual}
    \\set Manual = 0
    \\set Source = 11
;

test "the source contract: a live variable follows its guard, a live-only one too, and a plain set ends it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, contract);
    // Doubled = 20, Label = "source 10", Manual = 13 after `set Source = 10`; `set Manual = 0`
    // detaches Manual, so the last write leaves it at 0. Three records; six propagations
    // (three establishing, three program writes); 3 + 3 + 0 + 2 evaluations and entries.
    try expectReport(x, "{\"Source\":11,\"Doubled\":22,\"Label\":\"source 11\",\"Manual\":0,\"Seen\":[20,\"source 10\",13],\"$live\":{\"records\":3,\"propagations\":6,\"evaluations\":8,\"entries\":8,\"deliveries\":0,\"firings\":0}}\n");
    try expectEveryMode(contract);
}

test "the Book's examples 15:32, 15:106, 15:388, 15:674 and 15:808" {
    const h = try harness.create();
    defer scratch.release(h);
    // 15:32: X = Y + 1 follows Y.
    var x = try run(h,
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\set live X = Y + 1
        \\set Y = 5
    );
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "X"));
    // 15:106: the three forms.
    x = try run(h,
        \\var Source:i64 = 1
        \\var live Mutable:i64 = Source + 1
        \\live Immutable:i64 = Source + 2
        \\var Attached:i64 = 0
        \\set live Attached = Source + 3
        \\set Source = 10
    );
    try std.testing.expectEqual(@as(i64, 11), try integer(x, "Mutable"));
    try std.testing.expectEqual(@as(i64, 12), try integer(x, "Immutable"));
    try std.testing.expectEqual(@as(i64, 13), try integer(x, "Attached"));
    // 15:388: a plain set turns liveness off.
    x = try run(h,
        \\var X:i64 = 0
        \\var Y:i64 = 5
        \\set live X = Y
        \\set Y = 10
        \\A:i64 = X
        \\set X = 20
        \\set Y = 15
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 20), try integer(x, "X"));
    // 15:674: what a guard depends on is what it read the last time it ran.
    x = try run(h,
        \\var UseAlternate:logic = false
        \\var PrimaryValue:i64 = 10
        \\var AlternateValue:i64 = 20
        \\var CurrentValue:i64 = 0
        \\set live CurrentValue = If(UseAlternate, AlternateValue, PrimaryValue)
        \\A:i64 = CurrentValue
        \\set UseAlternate = true
        \\B:i64 = CurrentValue
        \\set AlternateValue = 30
        \\C:i64 = CurrentValue
        \\set PrimaryValue = 15
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 20), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 30), try integer(x, "C"));
    try std.testing.expectEqual(@as(i64, 30), try integer(x, "CurrentValue"));
    // 15:808: a guard without dependencies sets its cell once.
    x = try run(h,
        \\var live X:i64 = 10
        \\var Other:i64 = 0
        \\set Other = 1
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "X"));
    try std.testing.expectEqual(types.Live{ .records = 1, .propagations = 2, .evaluations = 1, .entries = 0 }, x.live);
}

test "the Book's 15:354: dependencies are replaced at every evaluation" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\var X:i64 = 1
        \\var Y:i64 = 2
        \\var Z:i64 = 3
        \\var W:i64 = 0
        \\set live W = If(Z > 0, X, Y)
        \\A:i64 = W
        \\set Z = 0
        \\B:i64 = W
        \\set X = 99
    );
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "B"));
    // X is no longer a dependency: its write evaluates nothing.
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "W"));
    try std.testing.expectEqual(types.Live{ .records = 1, .propagations = 3, .evaluations = 2, .entries = 4 }, x.live);
}

test "the Book's 15:297 converges and 15:333 diverges, stopped by the per-record bound at its record" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\var X:i64 = 2
        \\var Y:i64 = 2
        \\set live X = If(Y < 0, 0, Y - 1)
        \\set live Y = If(X < 0, 0, X - 1)
    );
    try std.testing.expectEqual(@as(i64, -1), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "Y"));
    try expectFailure(h,
        \\var X:i64 = 1
        \\var Y:i64 = 0
        \\set live Y = If(X > 0, X + 1, 0)
        \\set live X = Y
    , .live_unstable, "Y");
}

test "heights: a diamond and a layered graph declared against their order evaluate each record once" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        \\var A:i64 = 1
        \\var live B:i64 = A + 1
        \\var live C:i64 = A * 2
        \\var live D:i64 = B + C
        \\set A = 5
        ,
        \\var A:i64 = 1
        \\var B:i64 = 0
        \\var C:i64 = 0
        \\var live D:i64 = B + C
        \\set live B = A + 1
        \\set live C = A * 2
        \\set A = 5
    }) |source| {
        const x = try run(h, source);
        try std.testing.expectEqual(@as(i64, 16), try integer(x, "D"));
        // Three evaluations for the last write, whatever the order of declaration.
        const before = x.live.evaluations;
        const y = try run(h, source[0..std.mem.lastIndexOf(u8, source, "\nset A = 5").?]);
        try std.testing.expectEqual(@as(u64, 3), before - y.live.evaluations);
    }
    // The review's layered graph: two records per layer, each reading both records of the layer
    // below, declared top layer first; one write at the bottom costs two evaluations a layer.
    var text: [8192]u8 = undefined;
    // Depth 40 is in `program_profile_tests.zig`: its eighty guards outgrow the bootstrap
    // profile's compiler budget.
    for ([_]usize{ 8, 12 }) |depth| {
        var out: std.Io.Writer = .fixed(&text);
        try out.writeAll("var S:i64 = 0\n");
        for (1..depth + 1) |k| try out.print("var A{d}:i64 = 0\nvar B{d}:i64 = 0\n", .{ k, k });
        for (1..depth + 1) |k| {
            if (k < depth) {
                try out.print("set live A{d} = A{d} + B{d}\nset live B{d} = A{d} + B{d} + 1\n", .{ k, k + 1, k + 1, k, k + 1, k + 1 });
            } else try out.print("set live A{d} = S + S\nset live B{d} = S + S + 1\n", .{ k, k });
        }
        const prefix_len = out.buffered().len;
        try out.writeAll("set S = 1\n");
        const after = try run(h, out.buffered());
        const before = try run(h, text[0..prefix_len]);
        try std.testing.expectEqual(@as(u64, 2 * depth), after.live.evaluations - before.live.evaluations);
    }
}

fn ringSource(buffer: []u8, records: usize, start: i64) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    for (0..records) |index| try out.print("var R{d}:i64 = {d}\n", .{ index, start });
    for (0..records) |index| try out.print("set live R{d} = Max(R{d} - 1, 0)\n", .{ index, (index + records - 1) % records });
    return out.buffered();
}

test "rings at the bootstrap bounds: the per-record bound first, then the evaluations of one propagation" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var text: [4096]u8 = undefined;
    // 16 records from 1024: 1024 evaluations in the last propagation, 64 each, exactly.
    var x = try run(h, try ringSource(&text, 16, 1024));
    try std.testing.expectEqual(@as(u64, 16 + 1024), x.live.evaluations);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "R0"));
    try expectFailure(h, try ringSource(&text, 16, 1025), .live_unstable, "R0");
    // 32 records from 1024: 32 each, and one more is one evaluation too many for the update.
    x = try run(h, try ringSource(&text, 32, 1024));
    try std.testing.expectEqual(@as(u64, 32 + 1024), x.live.evaluations);
    try expectFailure(h, try ringSource(&text, 32, 1025), .live_propagation_limit, "R31");
}

test "set live in a function captures immutable locals and parameters by value, and reads in callees count" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\var Base:i64 = 1
        \\var Scale:i64 = 2
        \\var Out:i64 = 0
        \\Scaled()<reads>:i64 = Base * Scale
        \\Attach(Offset:i64)<transacts>:i64 = Block{
        \\    Extra := Offset * 10
        \\    set live Out = Scaled() + Offset + Extra
        \\    Extra
        \\}
        \\Bump()<transacts>:i64 = Block{ set Base = Base + 1; set Scale = Scale + 1; Scale }
        \\A:i64 = Attach(3)
        \\B:i64 = Out
        \\C:i64 = Bump()
    );
    // 1 * 2 + 3 + 30, then Base = 2 and Scale = 3: 6 + 33. Each write in `Bump` propagates.
    try std.testing.expectEqual(@as(i64, 35), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 39), try integer(x, "Out"));
    try std.testing.expectEqual(types.Live{ .records = 1, .propagations = 3, .evaluations = 3, .entries = 6 }, x.live);
    // Records made in frames that reclaim on return are kept, their entries moved with them.
    try std.testing.expect(try everyMode(
        \\var Base:i64 = 1
        \\var Out:i64 = 0
        \\Junk(N:i64)<computes>:i64 = Block{ X:[]i64 = array{N, N, N, N}; X.Length }
        \\Attach(N:i64)<transacts>:i64 = Block{ Y := Junk(N); set live Out = Base + Junk(Base) + N; Y }
        \\Repeat(N:i64)<transacts>:i64 = If(N == 0, 0, Block{ set Base = Base + 1; Junk(N) + Repeat(N - 1) })
        \\A:i64 = Attach(4)
        \\B:i64 = Repeat(20)
        \\C:i64 = Attach(5)
        \\D:i64 = Repeat(20)
    ) > 0);
}

test "set live in a task and in a Defer: one copy of the body is a guard, a landing's second copy is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const task =
        \\var S:i64 = 1
        \\var Out:i64 = 0
        \\F(N:i64)<transacts><suspends>:i64 = Block{ Defer{ set live Out = S + N; 0 }; Sleep(0.5); N }
        \\Main()<transacts><suspends>:i64 = Block{ P := F(3); set S = 10; S }
        \\T:task(i64) = Spawn{ Main() }
    ;
    try expectReport(try run(h, task),
        \\{"S":10,"Out":13,"T":{"$task":{"sequence":1,"state":"completed","result":10}},"$scheduler":{"tick_rate":60,"tick":30,"created":1,"completed":1,"canceled":0,"switches":3,"waiting":[]},"$live":{"records":1,"propagations":2,"evaluations":2,"entries":2,"deliveries":0,"firings":0}}
        \\
    );
    try expectEveryMode(task);
    // Under Sync or Race a Defer's body is also copied as the landing a cancellation runs
    // (RFC-0082, P3.3); a guard is named by its word `live`, which that copy cannot have again.
    try expectRefused(h,
        \\var S:i64 = 1
        \\var Out:i64 = 0
        \\F(N:i64)<transacts><suspends>:i64 = Block{ Defer{ set live Out = S + N; 0 }; Sleep(Inf); N }
        \\G()<transacts><suspends>:i64 = Race(F(1), Block{ Sleep(0.1); 7 })
    , .live_deferred, "live");
}

test "R1: a region that fails restores values, links, dependencies and the records it made" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var Y:i64 = 1
        \\var Z:i64 = 100
        \\var X:i64 = 0
        \\set live X = Y + 1
        \\F()<transacts><decides>:logic = Block{
        \\    set live X = Z + 1
        \\    set Z = 200
        \\    G:i64 = Attempt(Block{ set X = 7; Require[false]; 1 }, 0)
        \\    Require[false]
        \\    true
        \\}
        \\R:logic = Attempt(Block{ F[]; true }, false)
        \\A:i64 = X
        \\set Y = 5
        \\set Z = 300
    ;
    const x = try run(h, source);
    // F's record and its dependency on Z went with the region; X follows Y again.
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 300), try integer(x, "Z"));
    try expectEveryMode(source);
    // A region that commits keeps them, at three levels.
    const kept = try run(h,
        \\var Y:i64 = 1
        \\var X:i64 = 0
        \\Inner()<transacts><decides>:logic = Block{ set live X = Y * 3; Require[true]; true }
        \\Middle()<transacts><decides>:logic = Block{ G:logic = Attempt(Block{ Inner[]; true }, false); Require[G]; true }
        \\R:logic = Attempt(Block{ Attempt(Block{ Middle[]; true }, false) }, false)
        \\set Y = 4
    );
    try std.testing.expectEqual(@as(i64, 12), try integer(kept, "X"));
}

test "a guard depends on the var fields it reads and not on the immutable ones" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\gauge := class{ var Level:i64 = 0; Limit:i64 = 10 }
        \\G:gauge = gauge{}
        \\var live Over:logic = G.Level > G.Limit
        \\A:logic = Over
        \\Raise(N:i64)<transacts>:i64 = Block{ set G.Level = N; N }
        \\B:i64 = Raise(11)
    );
    try std.testing.expect(!x.get("A").?.boolean);
    try std.testing.expect(x.get("Over").?.boolean);
    try std.testing.expectEqual(types.Live{ .records = 1, .propagations = 2, .evaluations = 2, .entries = 2 }, x.live);
}

test "L6: an equal value of a comparable type is not written, NaN is stable, a non-comparable value always is" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try run(h,
        \\var A:i64 = 1
        \\var live Parity:i64 = A - A / 2 * 2
        \\var live Twice:i64 = Parity * 2
        \\set A = 3
    );
    // Parity stays 1, so Twice is not evaluated again: two establishing, one re-evaluation.
    try std.testing.expectEqual(@as(u64, 3), x.live.evaluations);
    x = try run(h,
        \\var A:float = 1.0
        \\var live N:float = A * 0.0 + NaN
        \\var live Count:float = N + 1.0
        \\var live Z:float = A * 0.0
        \\set A = -2.0
    );
    // N stays NaN and is stable; Z keeps the 0.0 it had for -0.0.
    try std.testing.expectEqual(@as(u64, 5), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(x.get("Z").?.floating)));
    x = try run(h,
        \\box := class{ Value:i64 = 0 }
        \\One:box = box{ Value := 1 }
        \\var Flag:logic = false
        \\Read()<reads>:logic = Flag
        \\var live Again:box = If(Read(), One, One)
        \\var live After:i64 = Again.Value
        \\set Flag = true
    );
    // `Again` is written at each evaluation, though it is the same instance: `After` follows.
    try std.testing.expectEqual(@as(u64, 4), x.live.evaluations);
    // A cycle through a type that is not comparable never settles.
    try expectFailure(h,
        \\box := class{}
        \\One:box = box{}
        \\var P:box = One
        \\var Q:box = One
        \\set live P = Q
        \\set live Q = P
    , .live_unstable, "P");
}

test "set live needs all three heap effects; a guard may only read" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "var X:i64 = 0\nF()<reads><writes>:i64 = Block{ set live X = 1; 0 }", .call_requires_allocates, "X");
    try expectRefused(h, "var X:i64 = 0\nF()<reads>:i64 = Block{ set live X = 1; 0 }", .call_requires_writes_allocates, "X");
    try expectRefused(h, "var X:i64 = 0\nvar Y:i64 = 0\nset live X = Block{ set Y = 1; 2 }", .guard_effect, "Y");
    try expectRefused(h, "var X:i64 = 0\nset live X = Block{ Print(\"no\"); 2 }", .guard_effect, "Print");
    try expectRefused(h, "box := class{}\nvar X:box = box{}\nset live X = box{}", .guard_effect, "box");
    try expectRefused(h, "var X:i64 = 0\nvar Y:i64 = 0\nW()<transacts>:i64 = Y\nset live X = W()", .guard_effect, "W");
    try expectRefused(h, "var X:i64 = 0\nset live X = Block{ var L:i64 = 1; L }", .guard_effect, "L");
    // A function the program writes in a guard has its own effect, and its own diagnostic.
    try expectRefused(h, "var X:i64 = 0\nvar Y:i64 = 0\nset live X = Fn()<reads>:i64{ Set(Y, 1) }()", .set_requires_writes, "Y");
}

test "a parameter, a binding, an immutable or live-only local, a struct field or an element is no live target" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0085, I14: a guard names a local `var` (S1b) and a local `var` is a live target (S1c):
    // `live_local_tests.zig`. An immutable local is no target.
    try expectRefused(h, "F()<transacts>:i64 = Block{ L:i64 = 1; set live L = 2; 0 }", .live_target, "L");
    try expectRefused(h, "F(P:i64)<transacts>:i64 = Block{ set live P = 2; 0 }", .live_target, "P");
    try expectRefused(h, "B:i64 = 1\nset live B = 2", .live_target, "B");
    try expectRefused(h, "pair := struct{ X:i64 = 0 }\nvar P:pair = pair{}\nset live P.X = 2", .live_target, "X");
    try expectRefused(h, "F()<transacts>:i64 = Block{ live L:i64 = 1; L }", .live_target, "L");
    try expectRefused(h, "shape := interface{ var live V:i64 = 0 }", .live_target, "V");
    try expectRefused(h, "var X:i64 = 0\nvar live Y:i64 = \"text\"", .type_mismatch, "\"text\"");
}

test "a live-only variable is never assigned; live is a word only before a name" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "var S:i64 = 0\nlive Y:i64 = S\nset Y = 2", .live_assigned, "Y");
    try expectRefused(h, "var S:i64 = 0\nlive Y:i64 = S\nset live Y = S", .live_assigned, "Y");
    try expectRefused(h, "var S:i64 = 0\nlive Y:i64 = S\nset Y += 1", .live_assigned, "Y");
    try expectRefused(h, "var S:i64 = 0\nlive Y:i64 = S\nF()<transacts>:i64 = Block{ set Y = 1; 0 }", .live_assigned, "Y");
    // `live` names a variable, a binding or a parameter wherever no name follows it.
    const x = try run(h,
        \\var live:i64 = 0
        \\set live = 1
        \\live2:i64 = live + 1
        \\Twice(N:i64)<computes>:i64 = N * 2
        \\T:i64 = Twice(live)
    );
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "live"));
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "T"));
    try std.testing.expectEqual(types.Live{}, x.live);
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("{\"live\":1,\"live2\":2,\"T\":2}\n", try report(x, &buffer));
}

test "the replay refuses forged steps: records out of order, a stability claimed falsely, another record" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\var A:i64 = 1
        \\var live B:i64 = A + 1
        \\var live C:i64 = A * 0
        \\var live D:i64 = B + C
        \\set A = 5
    );
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    // The last propagation evaluates B, then C (stable: 0), then D.
    var evals: [8]usize = undefined;
    var eval_count: usize = 0;
    var settles: [8]usize = undefined;
    var settle_count: usize = 0;
    for (steps, 0..) |step, index| {
        if (step.kind == .live_eval) {
            evals[eval_count] = index;
            eval_count += 1;
        }
        if (step.kind == .live_settle) {
            settles[settle_count] = index;
            settle_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), eval_count);
    var forged = x;
    forged.call_steps = steps;
    _ = try reporting.validate(forged, false, .{});
    // B's and C's evaluations swapped: the guard frames follow their records.
    const b = evals[3];
    const c = evals[4];
    std.mem.swap(types.CallStep, &steps[b], &steps[c]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    std.mem.swap(types.CallStep, &steps[b], &steps[c]);
    // C's settle claims a write of the value its cell already holds, and B's claims stability.
    steps[settles[4]].value = .{ .boolean = true };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[settles[4]].value = .{ .boolean = false };
    steps[settles[3]].value = .{ .boolean = false };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[settles[3]].value = .{ .boolean = true };
    // A step left out, or one record named for another.
    var shorter = forged;
    shorter.call_steps = steps[0 .. steps.len - 1];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(shorter, false, .{}));
    const named = steps[evals[5]].value;
    steps[evals[5]].value = steps[evals[4]].value;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[evals[5]].value = named;
    // The run's record says something else.
    for ([_]usize{ 0, 1, 2, 3, 4, 5 }) |field| {
        var record = forged;
        switch (field) {
            0 => record.live.records += 1,
            1 => record.live.propagations -= 1,
            2 => record.live.evaluations += 1,
            3 => record.live.entries -= 1,
            4 => record.live.deliveries = 1,
            else => record.live.firings = 1,
        }
        try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    }
    _ = try reporting.validate(forged, false, .{});
}

/// Runs `source` on both machines in a `digest` run, which keeps no steps, and returns the VM's
/// outcome; the two must agree, and a report of a run that completed is admitted by the replay.
pub fn digestRun(f: trace_replay.Fixture, source: []const u8, budget: u64) !evaluator.Result {
    const p = try f.h.compile(source);
    f.mode(.digest, types.ControlStorage.default_trace_window);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const actual = f.h.runtime.evaluate(p, budget);
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    if (actual == .failed) {
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
        return actual;
    }
    try std.testing.expectEqualDeep(reference.ok.live, actual.ok.live);
    _ = try reporting.validateReplayed(actual.ok, f.again.producer(p, budget), false, .{ .work = @max(1 << 26, types.limits.report_work) });
    return actual;
}

fn expectDigestFailure(f: trace_replay.Fixture, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const outcome = try digestRun(f, source, fuel);
    if (outcome != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, outcome.failed.code);
    try std.testing.expectEqualStrings(at, source[outcome.failed.span.start..outcome.failed.span.end]);
}

/// The program of the entry bound's tests at the bootstrap profile: 128 cells, `Sum` reading all
/// of them and `Part` the first `part`; 31 records of `Sum` (3968 entries), and `G` reading `Flag`
/// alone until `Flag` is set, when it reads `Flag` and `Part`. `how` is where that happens: at
/// the root, inside a region, or inside a sub-region of the guard that fails.
fn entrySource(buffer: []u8, part: usize, how: enum { plain, region, failed_inside }) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    for (0..128) |index| try out.print("var C{d}:i64 = {d}\n", .{ index, index });
    try out.writeAll("Sum()<reads>:i64 = 0");
    for (0..128) |index| try out.print(" + C{d}", .{index});
    try out.writeAll("\nPart()<reads>:i64 = 0");
    for (0..part) |index| try out.print(" + C{d}", .{index});
    try out.writeAll("\nvar Flag:i64 = 0\nvar G:i64 = 0\n");
    for (0..31) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
    switch (how) {
        .plain => try out.writeAll("set live G = If(Flag > 0, Part(), 0)\nset Flag = 1\n"),
        .region => try out.writeAll("set live G = If(Flag > 0, Part(), 0)\nR:logic = Attempt(Block{ set Flag = 1; true }, false)\n"),
        .failed_inside => try out.writeAll("set live G = If(Flag > 0, Attempt(Block{ X := Part(); Require[false]; X }, 0), 0)\nset Flag = 1\n"),
    }
    return out.buffered();
}

test "the entry bound: exactly live_edges entries and one more, outside a region, inside one and in a guard's own" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(text);
    // Outside every region the re-evaluation of G counts what it leaves: 3969 - 1 + (1 + 127).
    var x = (try digestRun(f, try entrySource(text, 127, .plain), fuel)).ok;
    try std.testing.expectEqual(@as(u64, 31 * 128 + 1 + 128), x.live.entries);
    try expectDigestFailure(f, try entrySource(text, 128, .plain), .live_edge_limit, "Flag");
    // Inside a region the entries G had are kept too, since a rollback could need them.
    x = (try digestRun(f, try entrySource(text, 126, .region), fuel)).ok;
    try std.testing.expect(x.get("R").?.boolean);
    try expectDigestFailure(f, try entrySource(text, 127, .region), .live_edge_limit, "Flag");
    // Reads inside a sub-region of the guard that fails are dependencies all the same.
    x = (try digestRun(f, try entrySource(text, 127, .failed_inside), fuel)).ok;
    try expectDigestFailure(f, try entrySource(text, 128, .failed_inside), .live_edge_limit, "Flag");
    // One more record at the bound: the check comes before the fuel of its entries.
    var out: std.Io.Writer = .fixed(text);
    for (0..128) |index| try out.print("var C{d}:i64 = {d}\n", .{ index, index });
    try out.writeAll("Sum()<reads>:i64 = 0");
    for (0..128) |index| try out.print(" + C{d}", .{index});
    try out.writeAll("\n");
    for (0..32) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
    const full = out.buffered().len;
    try out.writeAll("var live Over:i64 = C0\n");
    x = (try digestRun(f, text[0..full], fuel)).ok;
    try std.testing.expectEqual(@as(u64, 4096), x.live.entries);
    try expectDigestFailure(f, out.buffered(), .live_edge_limit, "Over");
    // Every budget near the end stops both machines at one node, and the last entries are paid.
    const source = text[0..full];
    var low: u64 = 0;
    var high: u64 = 1 << 20;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try digestRun(f, source, middle) == .ok) high = middle else low = middle + 1;
    }
    const budget = low;
    try std.testing.expect(budget > 4096);
    // The last record's 128 entries and what follows them, budget by budget.
    for (budget - 140..budget) |short| {
        const outcome = try digestRun(f, source, short);
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
    }
    const at_check = try digestRun(f, out.buffered(), budget + 128);
    try std.testing.expectEqual(types.Diagnostic.Code.live_edge_limit, at_check.failed.code);
}

fn timed(f: trace_replay.Fixture, label: []const u8, source: []const u8) !evaluator.Result {
    const p = try f.h.compile(source);
    const budget: u64 = 1 << 40;
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const referenced = elapsed(start);
    const actual = f.h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    if (actual == .failed) {
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
        std.debug.print("{s}: {t}: reference={d}ms vm={d}ms\n", .{ label, actual.failed.code, referenced, ran - referenced });
        return actual;
    }
    try std.testing.expectEqualDeep(reference.ok.live, actual.ok.live);
    const stats = try reporting.validateReplayed(actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("{s}: {d} evaluations, {d} entries: reference={d}ms vm={d}ms replay={d}ms, the live replay held {d} KiB at most\n", .{ label, actual.ok.live.evaluations, actual.ok.live.entries, referenced, ran - referenced, elapsed(start) - ran, stats.live_bytes / 1024 });
    return actual;
}
fn elapsed(start: std.Io.Timestamp) u64 {
    const nanoseconds = start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds();
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
}
fn expectAt(result: evaluator.Result, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    if (result != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

/// Scale test 2 (RFC-0084): rings of `Max(Previous - 1, 0)` closed by their last `set live`.
/// With `live_evaluations / live_record_evaluations` records from `live_evaluations`, the last
/// propagation takes exactly `live_evaluations` evaluations, each record exactly
/// `live_record_evaluations`; one more and the per-record bound ends it. With twice as many
/// records each takes half, and one more is one evaluation too many for the propagation.
pub fn ringScale(f: trace_replay.Fixture) !void {
    const allocator = std.testing.allocator;
    const records = types.limits.live_evaluations / types.limits.live_record_evaluations;
    const text = try allocator.alloc(u8, 128 * records);
    defer allocator.free(text);
    const start: i64 = types.limits.live_evaluations;
    var x = (try timed(f, "ring at both bounds", try ringSource(text, records, start))).ok;
    try std.testing.expectEqual(@as(u64, records + types.limits.live_evaluations), x.live.evaluations);
    var source = try ringSource(text, records, start + 1);
    try expectAt(try timed(f, "ring one more", source), source, .live_unstable, "R0");
    x = (try timed(f, "ring of twice the records", try ringSource(text, 2 * records, start))).ok;
    try std.testing.expectEqual(@as(u64, 2 * records + types.limits.live_evaluations), x.live.evaluations);
    source = try ringSource(text, 2 * records, start + 1);
    var name: [16]u8 = undefined;
    try expectAt(try timed(f, "ring of twice the records, one more", source), source, .live_propagation_limit, try std.fmt.bufPrint(&name, "R{d}", .{2 * records - 1}));
}

/// Scale test 5 (RFC-0084) at the program profile: `live_edges` entries exactly and one more,
/// 1024 guards each reading the fields of 4096 instances; then a guard that comes to read more, outside a region
/// (`V - old + n`) and inside one (`V0 + A + n`).
pub fn entryScale(f: trace_replay.Fixture) !void {
    const allocator = std.testing.allocator;
    const per = 4096;
    const records = types.limits.live_edges / per;
    const text = try allocator.alloc(u8, 32 * records + 64 * per + 4096);
    defer allocator.free(text);
    var out: std.Io.Writer = .fixed(text);
    try cells(&out, per, per);
    for (0..records) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
    const exact = out.buffered().len;
    try out.writeAll("var live Over:i64 = Flag\n");
    const x = (try timed(f, "live_edges entries", text[0..exact])).ok;
    try std.testing.expectEqual(@as(u64, types.limits.live_edges), x.live.entries);
    try expectAt(try timed(f, "one entry more", out.buffered()), out.buffered(), .live_edge_limit, "Over");
    // 1023 records and G, reading Flag alone, then Flag and `Part`: V = 4,190,209 before.
    for ([_]struct { region: bool, part: usize, fails: bool }{
        .{ .region = false, .part = per - 1, .fails = false },
        .{ .region = false, .part = per, .fails = true },
        .{ .region = true, .part = per - 2, .fails = false },
        .{ .region = true, .part = per - 1, .fails = true },
    }) |case| {
        out = .fixed(text);
        try cells(&out, per, case.part);
        try out.writeAll("var G:i64 = 0\n");
        for (0..records - 1) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
        try out.writeAll("set live G = If(Flag > 0, Part(), 0)\n");
        if (case.region) try out.writeAll("R:logic = Attempt(Block{ set Flag = 1; true }, false)\n") else try out.writeAll("set Flag = 1\n");
        const result = try timed(f, if (case.region) "a guard reading more, in a region" else "a guard reading more", out.buffered());
        if (case.fails) try expectAt(result, out.buffered(), .live_edge_limit, "Flag") else try std.testing.expect(result == .ok);
    }
}

/// `count` instances, `Sum` reading the field of each and `Part` of the first `part`, and `Flag`;
/// fields rather than `var` bindings, of which a program has `source_cells`.
fn cells(out: *std.Io.Writer, count: usize, part: usize) !void {
    try out.writeAll("cell := class{ var V:i64 = 1 }\n");
    for (0..count) |index| try out.print("C{d}:cell = cell{{}}\n", .{index});
    try out.writeAll("Sum()<reads>:i64 = 0");
    for (0..count) |index| try out.print(" + C{d}.V", .{index});
    try out.writeAll("\nPart()<reads>:i64 = 0");
    for (0..part) |index| try out.print(" + C{d}.V", .{index});
    try out.writeAll("\nvar Flag:i64 = 0\n");
}

/// The layered graph of the review at depth 40, which the bootstrap profile cannot compile.
pub fn layers(h: *harness.Harness, depth: usize) !void {
    var text: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&text);
    try out.writeAll("var S:i64 = 0\n");
    for (1..depth + 1) |k| try out.print("var A{d}:i64 = 0\nvar B{d}:i64 = 0\n", .{ k, k });
    for (1..depth + 1) |k| {
        if (k < depth) {
            try out.print("set live A{d} = A{d} + B{d}\nset live B{d} = A{d} + B{d} + 1\n", .{ k, k + 1, k + 1, k, k + 1, k + 1 });
        } else try out.print("set live A{d} = S + S\nset live B{d} = S + S + 1\n", .{ k, k });
    }
    const prefix_len = out.buffered().len;
    try out.writeAll("set S = 1\n");
    const after = try run(h, out.buffered());
    const before = try run(h, text[0..prefix_len]);
    try std.testing.expectEqual(@as(u64, 2 * depth), after.live.evaluations - before.live.evaluations);
}

// The review's cases (RFC-0084 C16 to C21): reclamation after failed regions, the measure inside
// nested regions, `Return` committing a region, propagations at `undo_limit`, and the work of
// lists that hold valid entries only.

test "a reclamation after a failed region drops its entries first, at the root and when a function returns" {
    const h = try harness.create();
    defer scratch.release(h);
    // The failed region's record lies at the position the frame's mark names; its entry goes
    // before the cells above the mark are renumbered (C18).
    const root =
        \\var S:i64 = 1
        \\var live Y:i64 = S + 10
        \\var X:i64 = 0
        \\R:i64 = Attempt(Block{ set live X = S + 1; Require[false]; 1 }, 0)
        \\A:[]i64 = For(K:1..64, K + R)
        \\set S = 4
    ;
    var x = try run(h, root);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 14), try integer(x, "Y"));
    try std.testing.expect(try everyMode(root) > 0);
    // The same in a function: its frame reclaims when it returns.
    const function =
        \\var S:i64 = 1
        \\var live Y:i64 = S + 10
        \\var X:i64 = 0
        \\set live X = S * 2
        \\G()<transacts>:[]i64 = Block{ R:i64 = Attempt(Block{ set live X = S + 1; Require[false]; 1 }, 0); For(K:1..64, K + R) }
        \\A:[]i64 = G()
        \\B:[]i64 = G()
        \\set S = 4
    ;
    x = try run(h, function);
    try std.testing.expectEqual(@as(i64, 8), try integer(x, "X"));
    try std.testing.expect(try everyMode(function) > 0);
    // A failed region inside a region of the function, then a reclamation in the same function.
    try std.testing.expect(try everyMode(
        \\var S:i64 = 1
        \\var X:i64 = 0
        \\var Z:i64 = 0
        \\G(N:i64)<transacts>:[]i64 = Block{
        \\    set live Z = S + N
        \\    R:logic = Attempt(Block{ set live X = S + N; Q:i64 = Attempt(Block{ set S = N; Require[false]; 1 }, 0); Require[N > 2]; true }, false)
        \\    For(K:1..40, K + N)
        \\}
        \\A:[]i64 = G(1)
        \\B:[]i64 = G(3)
        \\set S = 7
    ) > 0);
}

/// The program of the measure's sweep. Four records read `S` and 64 cells: 260 entries. `H`,
/// called from the root, builds an array of 500 that the root keeps; the reclamation at its
/// return examines that much, so the next one is not due by size for another 107 members. In
/// a region, an inner one evaluates the records again and fails, leaving 260 entries to be
/// dropped; then `G`, called from the root, builds an array of `n` and returns. Its frame's end
/// reclaims if 8 n is at least what a reclamation would examine, which takes in the entry
/// count before any live operation has dropped those entries: about 52 <= n with them left
/// out, as the replay leaves them out, and about 89 <= n with them counted.
fn measureSource(buffer: []u8, n: usize) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    try out.writeAll("var S:i64 = 0\n");
    for (0..64) |index| try out.print("var C{d}:i64 = {d}\n", .{ index, index });
    try out.writeAll("Wide()<reads>:i64 = S");
    for (0..64) |index| try out.print(" + C{d}", .{index});
    try out.writeAll("\n");
    for (0..4) |index| try out.print("var live X{d}:i64 = Wide() + {d}\n", .{ index, index });
    // Array literals, so that no loop's visits reclaim inside `H` or `G` before they return;
    // the `If` makes each frame one that is traced and so may reclaim.
    try out.writeAll("H(N:i64)<computes>:[]i64 = If(N > 0, array{0");
    for (1..500) |index| try out.print(", {d}", .{index});
    try out.writeAll("}, array{})\nP:[]i64 = H(1)\nG(N:i64)<computes>:[]i64 = If(N > 0, array{0");
    for (1..n) |index| try out.print(", {d}", .{index});
    try out.writeAll("}, array{})\nR:logic = Attempt(Block{ Q:i64 = Attempt(Block{ set S = 5; Require[false]; 1 }, 0); A:[]i64 = G(1); true }, false)\n");
    try out.writeAll("set S = 2\n");
    return out.buffered();
}

test "the reclamation measure leaves out the entries a failed inner region left, in both machines and the replay" {
    // C18: the entries the inner region recorded are not counted before they are dropped, so
    // every N reclaims where the replay predicts (`everyMode` admits each digest report). With
    // them counted, the machines would not reclaim at `G`'s return for N from about 52 to 88,
    // and the replay would refuse their reports.
    var buffer: [16 * 1024]u8 = undefined;
    var counts: [100]u64 = undefined;
    for (&counts, 1..) |*count, n| count.* = try everyMode(try measureSource(&buffer, n));
    // The sweep crosses the point where `G`'s return reclaims.
    var changes: usize = 0;
    for (counts[1..], counts[0 .. counts.len - 1]) |now, before| changes += @intFromBool(now != before);
    try std.testing.expect(changes >= 1);
}

test "Return commits the regions it leaves, with their records and entries" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var S:i64 = 1
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\F(N:i64)<transacts>:i64 = Block{
        \\    J:[]i64 = For(K:1..20, K * N)
        \\    Attempt(Block{ set live X = S * 2; Attempt(Block{ set live Y = S + N; If(N > 0, Return(N), false); Fail["no"]; 0 }, -1) }, -2)
        \\}
        \\A:i64 = F(3)
        \\B:i64 = F(0)
        \\set S = 5
    ;
    const x = try run(h, source);
    // F(3) returns from inside both regions: both commit, so X and Y follow S. F(0) attaches X
    // again and Y in a region that fails, which leaves Y with F(3)'s record.
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, -1), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 8), try integer(x, "Y"));
    // Four records were built; the one the failed region made is counted too.
    try std.testing.expectEqual(@as(u64, 4), x.live.records);
    try std.testing.expect(try everyMode(source) > 0);
}

/// 56 records read `S` (the bootstrap profile has 64 functions, guards included), and `levels`
/// regions, each inside the last, each set the 16 fields of 10 instances and then `S`: a region
/// journals the 160 fields, `S`, and the stamp, height and target of each record its propagation
/// evaluates, 329 cells in all.
fn undoSource(buffer: []u8, levels: usize) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    try out.writeAll("cell := class{");
    for (0..16) |field| try out.print(" var V{d}:i64 = 0;", .{field});
    try out.writeAll(" }\nPool:[]cell = For(I:1..10, cell{})\nFill(K:i64)<transacts>:i64 = For(C:Pool, Block{");
    for (0..16) |field| try out.print(" set C.V{d} = K;", .{field});
    try out.writeAll(" false }, 0).Length\nvar S:i64 = 0\n");
    for (0..56) |index| try out.print("var live L{d}:i64 = S + {d}\n", .{ index, index });
    try out.writeAll("Nest(D:i64, Top:i64)<transacts>:logic = Block{ F := Fill(D); set S = D; If(D < Top, Attempt(Block{ Require[Nest(D + 1, Top)]; true }, false), true) }\n");
    try out.print("R:logic = Attempt(Block{{ Require[Nest(1, {d})]; true }}, false)\n", .{levels});
    return out.buffered();
}

test "a propagation whose writes reach undo_limit stops at the writing node in both machines" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    var buffer: [16 * 1024]u8 = undefined;
    // Each level's propagation logs the entries it takes off in a region that then commits,
    // and `Nest` returns into a region that is still open: its reclamation keeps of the log only
    // what an open region can revive (C19).
    try std.testing.expect(try everyMode(try undoSource(&buffer, 6)) > 0);
    // 24 levels journal 24 * 329 = 7896 cells. A 25th journals its fields and `S` (8057), and
    // its propagation needs more than `source_undos` (8192) at the 46th record it evaluates.
    // Its steps are more than a `full` run keeps at this profile: the runs are `digest` ones.
    const x = (try digestRun(f, try undoSource(&buffer, 24), fuel)).ok;
    try std.testing.expect(x.get("R").?.boolean);
    try std.testing.expectEqual(@as(i64, 24 + 55), try integer(x, "L55"));
    const over = try undoSource(&buffer, 25);
    const outcome = try digestRun(f, over, fuel);
    try std.testing.expectEqual(types.Diagnostic.Code.undo_limit, outcome.failed.code);
    // The write of `S`, whose propagation it is.
    try std.testing.expect(std.mem.startsWith(u8, over[outcome.failed.span.start..], "S = D"));
}

test "a store full at a re-evaluation is compacted without the entries the record leaves" {
    try @import("profile.zig").requireBootstrap();
    // 32 records of 128 entries: `live_edges` (4096) exactly. A write of C0 evaluates them
    // again; each leaves 128 entries. Before the 17th, 2048 are left, under the compaction's
    // threshold (2 * 2048 <= 4096 + 64), and 4096 + 2048 + 128 is more than the room (6208):
    // the store is compacted while the record's old entries are off their lists (review E1).
    var buffer: [8 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    for (0..128) |index| try out.print("var C{d}:i64 = {d}\n", .{ index, index });
    try out.writeAll("Sum()<reads>:i64 = 0");
    for (0..128) |index| try out.print(" + C{d}", .{index});
    try out.writeAll("\n");
    for (0..32) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
    try out.writeAll("set C0 = 1\nset C1 = 2\n");
    // Its steps are more than a `full` run keeps at this profile: both machines and the
    // replay run it in `digest` mode.
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const x = (try digestRun(f, out.buffered(), fuel)).ok;
    try std.testing.expectEqual(@as(i64, 127 * 128 / 2 + 2), try integer(x, "T31"));
    try std.testing.expectEqual(@as(u64, 32 * 128 * 3), x.live.entries);
}

test "a report of a program without live variables holds no memory for them" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [512]u8 = undefined;
    const plain = try run(h, "var S:i64 = 1\nset S = 2\nA:i64 = S\n");
    var out: std.Io.Writer = .fixed(&buffer);
    const stats = try reporting.write(&out, plain, false, .{});
    try std.testing.expectEqual(@as(u64, 0), stats.live_bytes);
    out = .fixed(&buffer);
    const live = try reporting.write(&out, try run(h, contract), false, .{});
    // C17: the stores grow with what the run used, a few kilobytes here.
    try std.testing.expect(live.live_bytes > 0 and live.live_bytes < 64 * 1024);
    std.debug.print("the contract's live replay held at most {d} bytes\n", .{live.live_bytes});
}

/// Scale (C16, R1 of the review): `S` read by one record is written two million times inside one
/// region. Every write visits the one valid entry of `S`; the superseded ones are off its list.
pub fn regionWrites(f: trace_replay.Fixture) !void {
    const source =
        \\var S:i64 = 0
        \\var live X:i64 = S
        \\Spin(K:i64)<transacts>:i64 = Block{ set S = K; K + 1 }
        \\R:logic = Attempt(Block{ T:i64 = Iterate(Spin, 2000000, 0); Require[T > 0]; true }, false)
    ;
    const x = (try timed(f, "two million writes of a watched cell in one region", source)).ok;
    try std.testing.expectEqual(@as(i64, 1999999), x.get("X").?.integer);
    try std.testing.expectEqual(@as(u64, 2000001), x.live.evaluations);
}

/// Scale (C16): about two million valid entries of 512 records, then two million writes of a
/// cell one other record reads, outside every region. The entries its evaluations leave are
/// compacted away every million or so; no write walks them.
pub fn rootWrites(f: trace_replay.Fixture) !void {
    const allocator = std.testing.allocator;
    const per = 4096;
    const text = try allocator.alloc(u8, 64 * per + 32 * 512 + 4096);
    defer allocator.free(text);
    var out: std.Io.Writer = .fixed(text);
    try cells(&out, per, 0);
    for (0..512) |index| try out.print("var live T{d}:i64 = Sum()\n", .{index});
    try out.writeAll("var S:i64 = 0\nvar live X:i64 = S\nSpin(K:i64)<transacts>:i64 = Block{ set S = K; K + 1 }\nN:i64 = Iterate(Spin, 2000000, 0)\n");
    const x = (try timed(f, "two million writes of a watched cell beside two million entries", out.buffered())).ok;
    try std.testing.expectEqual(@as(i64, 1999999), x.get("X").?.integer);
    try std.testing.expectEqual(@as(u64, 512 * per + 1 + 2000000), x.live.entries);
}

/// Scale (R3 of the review): a guard attached again a million times in a loop at the root. Each
/// attachment detaches the last record, and the loop's visits reclaim them, so the run stays in
/// `object_cells` (a million records would need seven million).
pub fn reattached(f: trace_replay.Fixture) !void {
    const source =
        \\var S:i64 = 1
        \\var X:i64 = 0
        \\Attach(K:i64)<transacts>:i64 = Block{ set live X = S + K; K }
        \\A:[]i64 = For(K:1..1000000, Attach(K) > 999998, K)
        \\set S = 2
    ;
    const x = (try timed(f, "a guard attached a million times", source)).ok;
    try std.testing.expectEqual(@as(i64, 1000002), x.get("X").?.integer);
    try std.testing.expectEqual(@as(u64, 1000000), x.live.records);
    try std.testing.expect(x.reclaims > 0);
}
