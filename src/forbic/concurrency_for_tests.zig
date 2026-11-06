//! Structured concurrency, P3.8 (RFC-0082): a `For` whose generators, filters and bindings
//! cannot fail may have a body with a site. Such a `For` is lowered without a region per
//! iteration, so no rollback region is open at the site; one whose clause or body can fail is
//! refused at that clause (`suspending_for_fails`). A `For` with no site keeps its IR.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");
const concurrency = @import("concurrency_tests.zig");

const expectRun = concurrency.expectRun;
const printed = concurrency.printed;

fn expectPrinted(h: *harness.Harness, source: []const u8, expected: []const u8) !evaluator.Execution {
    const x = try expectRun(h, source);
    var buffer: [4096]u8 = undefined;
    const got = printed(x, &buffer);
    if (!std.mem.eql(u8, expected, got)) std.debug.print("program:\n{s}\n", .{source});
    try std.testing.expectEqualStrings(expected, got);
    return x;
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code) std.debug.print("got {t} at {d} for {s}\n", .{ result.failed.code, result.failed.span.start, source });
    try std.testing.expectEqual(code, result.failed.code);
    if (!std.mem.eql(u8, at, source[result.failed.span.start..result.failed.span.end])) std.debug.print("placed at {s} in {s}\n", .{ source[result.failed.span.start..result.failed.span.end], source });
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

/// The number of `attempt_begin` nodes in the functions of `p`.
fn regions(p: types.Program) usize {
    var count: usize = 0;
    for (p.function_nodes) |entry| count += @intFromBool(entry.input == .operation and entry.node.kind == .attempt_begin);
    return count;
}

test "the Book's 14:1086 with its For: a site in the loop lands the request after one step" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Steps:i64 = 0
        \\ResponsiveComputation()<transacts><suspends>:void = Block{
        \\    For(I:0..9, Block{ set Steps = Steps + 1; NextTick() })
        \\}
        \\CancelEarly()<transacts><suspends>:void = Block{
        \\    Task := Spawn{ ResponsiveComputation() }
        \\    Task.Cancel()
        \\}
        \\RunCancel()<transacts><suspends>:void = CancelEarly()
        \\T:task(void) = Spawn{ RunCancel() }
    );
    // The value of the Book (`Counted.Steps = 1`), and the report of the `While` it was
    // written with in P3.7, byte for byte.
    try expectReport(x, "{\"Steps\":1,\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":1,\"canceled\":1,\"switches\":4,\"waiting\":[]}}\n");
    // Not cancelled, it runs its ten steps, one a tick.
    const y = try expectRun(h,
        \\var Steps:i64 = 0
        \\Responsive()<transacts><suspends>:void = Block{ For(I:0..9, Block{ set Steps = Steps + 1; NextTick() }) }
        \\T:task(void) = Spawn{ Responsive() }
    );
    try std.testing.expectEqual(@as(i64, 10), y.cells[0].value.integer);
    try std.testing.expectEqual(@as(u64, 10), y.scheduler.tick);
}

test "every form of For may suspend in its body, and yields the array of its body's values" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Xs:[]i64 = array{5, 6, 7}
        \\Step(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.1); N * 2 }
        \\Ranged()<transacts><suspends>:[]i64 = For(I:0..2, Step(I))
        \\Filtered()<transacts><suspends>:[]i64 = For(I:0..4, I != 2, Step(I))
        \\Nested()<transacts><suspends>:[]i64 = For(I:1..2, J:I..2, Step(I * 10 + J))
        \\Bound()<transacts><suspends>:[]i64 = For(I:0..2, J := I * I, J > 0, Step(J))
        \\Keyed()<transacts><suspends>:[]i64 = For(K->X:Xs, Step(K * 100 + X))
        \\Plain()<transacts><suspends>:[]i64 = For(X:Xs, Step(X))
        \\Kept()<transacts><suspends>:[]i64 = For(X:Xs, X > 5, Step(X))
        \\Inner()<transacts><suspends>:[][]i64 = For(I:0..1, For(J:0..1, Step(I + J)))
        \\Empty()<transacts><suspends>:[]i64 = For(I:3..1, Step(I))
        \\Main()<transacts><suspends>:[][]i64 = Block{ N := Inner(); array{Ranged(), Filtered(), Nested(), Bound(), Keyed(), Plain(), Kept(), Empty()} + N }
        \\T:task([][]i64) = Spawn{ Main() }
    );
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const report = out.buffered();
    const expected = "\"result\":[[0,2,4],[0,2,6,8],[22,24,44],[2,8],[10,212,414],[10,12,14],[12,14],[],[0,2],[2,4]]";
    if (std.mem.indexOf(u8, report, expected) == null) std.debug.print("{s}\n", .{report});
    try std.testing.expect(std.mem.indexOf(u8, report, expected) != null);
    // One sleep of six ticks per element, in turn: 4+3+4+3+2+3+3+2 elements.
    try std.testing.expectEqual(@as(u64, 6 * (4 + 3 + 4 + 3 + 2 + 3 + 3 + 2)), x.scheduler.tick);
}

test "loops that suspend interleave: each waits at its site and the other runs" {
    const h = try harness.create();
    defer scratch.release(h);
    // Two tasks, each a general `For` with a filter, sleep a tick an iteration; the first
    // starts first, so on every tick its print comes first.
    _ = try expectPrinted(h,
        \\Count(Name:string, N:i64)<transacts><suspends>:void = For(I:1..N, I != 2, Block{ Print("{Name} {I}"); NextTick() })
        \\A:task(void) = Spawn{ Count("a", 3) }
        \\B:task(void) = Spawn{ Count("b", 4) }
    , "a 1\nb 1\na 3\nb 3\nb 4\n");
}

test "a For that suspends may assign the locals around it, which it carries; a shared local it does not" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Xs:[]i64 = array{5, 6}
        \\Carried()<transacts><suspends>:i64 = Block{ var T:i64 = 0; For(I->X:Xs, Block{ set T = T + I * X + 1; NextTick() }); T }
        \\Ranged()<transacts><suspends>:i64 = Block{ var T:i64 = 0; For(I:1..3, J := I * 2, Block{ NextTick(); set T = T + J; T }); T }
        \\Shared()<transacts><suspends>:i64 = Block{ var X:i64 = 0; G := Fn()<transacts>:i64{ Set(X, X + 100) }; For(I:1..3, Block{ set X = X + I; NextTick(); G() }); X }
        \\Main()<transacts><suspends>:tuple(i64, i64, i64) = tuple{Carried(), Ranged(), Shared()}
        \\T:task(tuple(i64, i64, i64)) = Spawn{ Main() }
    );
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    // The carried locals come out of the loop; the shared one is the same cell every visit
    // writes and the `Fn` adds to (RFC-0085, S2: no loop carries it), as for a `For` that
    // does not suspend.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":[8,12,306]") != null);
}

test "a For that suspends may be left by Return, and a Break in it leaves the Loop{} around it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var C:i64 = 0
        \\Find()<transacts><suspends>:i64 = Block{ For(I:0..9, J:0..1, I > 0, Block{ If(I == 2, Return(100 + J), 0); set C = C + 1; NextTick() }); -1 }
        \\Stop()<transacts><suspends>:i64 = Block{ var K:i64 = 0; Loop{ For(I:0..9, Block{ If(I == 2, Break(), 0); set K = K + 1; NextTick() }); set K = K + 100; Break() }; K }
        \\Main()<transacts><suspends>:tuple(i64, i64) = tuple{Find(), Stop()}
        \\T:task(tuple(i64, i64)) = Spawn{ Main() }
    );
    try std.testing.expectEqual(@as(i64, 2), x.cells[0].value.integer);
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":[100,2]") != null);
}

test "cancellation inside a For that suspends runs the Defers of the iteration, then of the loop around it, then of the function" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Work()<transacts><suspends>:void = Block{
        \\    Defer{ Print("function") }
        \\    For(I:0..9, Block{
        \\        Defer{ Print("outer {I}") }
        \\        For(J:0..9, J != 1, Block{ Defer{ Print("inner {I} {J}") }; Print("step {I} {J}"); Sleep(1.0) })
        \\    })
        \\}
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ Work() }; Sleep(2.5); T.Cancel() }
        \\M:task(void) = Spawn{ Main() }
    , "step 0 0\ninner 0 0\nstep 0 2\ninner 0 2\nstep 0 3\ninner 0 3\nouter 0\nfunction\n");
    // In an arm that loses a `Race`, as a loser does.
    _ = try expectPrinted(h,
        \\Arm()<transacts><suspends>:i64 = Block{ Defer{ Print("arm") }; For(I:0..9, Block{ Defer{ Print("visit {I}") }; Sleep(1.0) }); 0 }
        \\Main()<transacts><suspends>:i64 = Race(Arm(), Block{ Sleep(1.5); 7 })
        \\M:task(i64) = Spawn{ Main() }
    , "visit 0\nvisit 1\narm\n");
}

test "a For whose body suspends and whose clause or body can fail is refused at that clause" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    const head = "Xs:[]i64 = array{1, 2}\nYs:[][]i64 = array{array{1}, array{2, 3}}\nW(N:i64)<transacts><suspends>:i64 = Block{ Sleep(1.0); N }\n";
    inline for ([_]Case{
        // A generator after the first, a filter, a binding, the body: each runs in an iteration,
        // which has no region to undo it.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, J:Ys[I], W(J))", .code = .suspending_for_fails, .at = "J:Ys[I]" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, J:0..Xs[I], W(J))", .code = .suspending_for_fails, .at = "J:0..Xs[I]" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Xs[I] > 1, W(I))", .code = .suspending_for_fails, .at = "Xs[I] > 1" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Y := Xs[I], W(Y))", .code = .suspending_for_fails, .at = "Y := Xs[I]" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Block{ NextTick(); Xs[I] })", .code = .suspending_for_fails, .at = "Block{ NextTick(); Xs[I] }" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, I > 0, Y := I + 1, Z := Xs[Y], W(Z))", .code = .suspending_for_fails, .at = "Z := Xs[Y]" },
        // A filtered form of RFC-0056 whose body suspends takes the general lowering without
        // regions, where its filter may not fail either (C128).
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(X:Xs, Xs[X] > 1, Block{ NextTick(); X })", .code = .suspending_for_fails, .at = "Xs[X] > 1" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(K->X:Xs, Xs[K] > 1, Block{ NextTick(); X })", .code = .suspending_for_fails, .at = "Xs[K] > 1" },
        // A single generator with a body that fails takes the general lowering, then this.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(X:Xs, W(Xs[X]))", .code = .suspending_for_fails, .at = "W(Xs[X])" },
        // So does a loop that can be left.
        .{ .source = head ++ "F()<transacts><suspends>:i64 = Block{ For(I:0..1, Y := Xs[I], Block{ If(Y > 1, Return(Y), 0); NextTick() }); 0 }", .code = .suspending_for_fails, .at = "Y := Xs[I]" },
        // What fails in a function of its own in the loop, an `Fn` or an arm, is that function's.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Block{ NextTick(); G := Fn():i64{ Xs[0] }; I })", .code = .failure_context_required, .at = "[" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Block{ NextTick(); R := Sync(Block{ Sleep(1.0); Xs[0] }, 2); I })", .code = .failure_context_required, .at = "[" },
        // The first source runs before the loop, in the code around it, as before.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..Xs[0], W(I))", .code = .failure_context_required, .at = "[" },
        // Only the body may suspend: a clause stays what an `If`'s condition is.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, W(I) > 0, I)", .code = .suspends_in_failure_context, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Y := W(I), Y)", .code = .suspends_in_failure_context, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, J:0..W(I), J)", .code = .suspends_in_failure_context, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(X:Xs, W(X) > 0, X)", .code = .suspends_in_failure_context, .at = "W" },
        // Where the code around does not suspend, such a filter is refused as before P3.8.
        .{ .source = head ++ "F()<transacts>:[]i64 = For(X:Xs, W(X) > 0, X)", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "A:[]i64 = For(X:Xs, W(X) > 0, X)", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "F()<transacts>:[]i64 = For(I:0..2, W(I) > 0, I)", .code = .call_requires_suspends, .at = "W" },
        // A region around the loop is a region around the site; so is a `First`, and the root
        // does not suspend.
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = Attempt(For(I:0..1, W(I)), array{})", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = Attempt(For(X:Xs, W(X)), array{})", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:i64 = Attempt(First[I:0..1, W(I)], 0)", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "A:[]i64 = For(I:0..1, W(I))", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "F()<transacts>:[]i64 = For(I:0..1, W(I))", .code = .call_requires_suspends, .at = "W" },
        .{ .source = head ++ "F()<transacts><suspends>:[]i64 = For(I:0..1, Block{ Defer{ X := W(I) }; I })", .code = .suspends_in_failure_context, .at = "W" },
    }) |case| try expectRefused(h, case.source, case.code, case.at);
}

test "a site in a function written in a clause is that function's, and a task's body in a clause may wait" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\F()<transacts><suspends>:[]i64 = For(I:0..1, T := Spawn{ Sleep(1.0); Print("t") }, Block{ NextTick(); Print("i{I}"); I })
        \\U:task([]i64) = Spawn{ F() }
    );
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("i0\ni1\nt\nt\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.created);
}

test "a For with no site keeps its regions and its IR; one with a site has none in its iterations" {
    const h = try harness.create();
    defer scratch.release(h);
    // Without a site: a region per level, as before P3.8.
    const plain = try h.compile("F()<transacts><suspends>:[]i64 = For(I:0..2, J:0..1, I + J)\nT:task([]i64) = Spawn{ F() }");
    const plain_passes = h.front.passes;
    try std.testing.expectEqual(@as(usize, 2), regions(plain));
    // With one: no region at all, at the cost of one more compile.
    const suspending = try h.compile("F()<transacts><suspends>:[]i64 = For(I:0..2, J:0..1, Block{ NextTick(); I + J })\nT:task([]i64) = Spawn{ F() }");
    try std.testing.expectEqual(@as(usize, 0), regions(suspending));
    try std.testing.expectEqual(plain_passes + 1, h.front.passes);
    // A program of many such loops takes that one compile more for all of them, whatever the
    // site in their inner levels: a call, a `Race`, a `Branch` or an `Await(G)` (the review).
    const bodies = [_][]const u8{ "", "NextTick(); ", "R := Race(Block{ Sleep(0.1); 1 }, Block{ Sleep(0.2); 0 }); ", "Branch{ Sleep(1.0) }; ", "Z := Await(I >= 0); " };
    var buffer: [bodies.len][16 * 1024]u8 = undefined;
    var compiles: [bodies.len]usize = undefined;
    for (bodies, 0..) |site, kind| {
        var out: std.Io.Writer = .fixed(&buffer[kind]);
        for (0..4) |k| try out.print("F{d}()<transacts><suspends>:[]i64 = For(I:0..1, J:0..{d}, Block{{ {s}I + J }})\n", .{ k, k % 3, site });
        try out.writeAll("T:task([]i64) = Spawn{ F0() }\n");
        const many = try h.compile(out.buffered());
        try std.testing.expectEqual(@as(usize, if (kind == 0) 8 else if (kind == 4) 4 else 0), regions(many));
        compiles[kind] = h.front.passes;
    }
    // The landings a `Race` or a `Branch` needs take a compile of their own (C37).
    try std.testing.expectEqual(compiles[0] + 1, compiles[1]);
    try std.testing.expect(compiles[2] <= compiles[0] + 2 and compiles[3] <= compiles[0] + 2 and compiles[4] <= compiles[0] + 2);
    // A filter of RFC-0056's form is the condition of an `If` in a function of its own, which
    // never suspends, so such a `For` without a site compiles where it was refused before P3.8,
    // with the IR it has elsewhere, in a function that suspends or not, and in a task's body.
    // With a site in its body it is lowered as a general `For` without regions (C128).
    const loops = struct {
        fn count(p: types.Program) usize {
            var found: usize = 0;
            for (p.function_nodes) |entry| found += @intFromBool(entry.input == .operation and entry.node.kind == .loop);
            return found;
        }
    }.count;
    const filtered = try h.compile("Xs:[]i64 = array{1, 2}\nF()<transacts><suspends>:[]i64 = For(X:Xs, X > 1, Block{ NextTick(); X })\nT:task([]i64) = Spawn{ F() }");
    try std.testing.expectEqual(@as(usize, 0), loops(filtered) + regions(filtered));
    const unfiltered = try h.compile("Xs:[]i64 = array{1, 2}\nF()<transacts><suspends>:[]i64 = For(X:Xs, X > 1, X)\nT:task([]i64) = Spawn{ F() }");
    try std.testing.expectEqual(@as(usize, 1), loops(unfiltered));
    const kept = try h.compile("Xs:[]i64 = array{1, 2}\nF()<transacts><suspends>:[]i64 = For(X:Xs, X > 1, X)\nG()<transacts>:[]i64 = For(X:Xs, X > 1, X)\nT:task([]i64) = Spawn{ For(X:Xs, X > 1, X) }");
    try std.testing.expectEqual(@as(usize, 0), regions(kept));
    var filters: usize = 0;
    for (kept.functions) |f| filters += @intFromBool(f.anonymous and !f.detail.suspends and f.body.end - f.body.start > 1);
    try std.testing.expect(filters >= 3);
}

test "the IR of a site in the region of an iteration is refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const sources = [_][]const u8{
        "F()<transacts><suspends>:[]i64 = For(I:0..2, Block{ Sleep(1.0); I })\nT:task([]i64) = Spawn{ F() }",
        "F()<transacts><suspends>:[]i64 = For(I:0..2, J := I * 2, J > 0, Block{ Sleep(1.0); J })\nT:task([]i64) = Spawn{ F() }",
        "F()<transacts><suspends>:i64 = Block{ var T:i64 = 0; For(I:0..2, Block{ set T = T + I; Sleep(1.0) }); T }\nT:task(i64) = Spawn{ F() }",
        "F()<transacts><suspends>:i64 = Block{ For(I:0..2, Block{ If(I == 1, Return(5), 0); Sleep(1.0) }); 0 }\nT:task(i64) = Spawn{ F() }",
    };
    for (sources) |source| {
        const p = try h.compile(source);
        const run = (try h.run(p, concurrency.fuel)).ok;
        // The lowering before P3.8, written by the compiler on request: each iteration in its
        // region, and the site inside it.
        h.front.for_regions_kept = true;
        defer h.front.for_regions_kept = false;
        const forged = try h.compile(source);
        try std.testing.expect(regions(forged) != 0);
        try harness.invalid(h, forged);
        var replayed = run;
        replayed.program = forged;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(replayed, false, .{}));
    }
}

test "loops that suspend need the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "W(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"w{N}\") }; Sleep(0.5); N }\nF()<transacts><suspends>:[]i64 = For(I:0..3, I != 1, J := I + 1, W(J))\nMain()<transacts><suspends>:void = Block{ T := Spawn{ F() }; Sleep(1.2); T.Cancel() }\nM:task(void) = Spawn{ Main() }",
        "F()<transacts><suspends>:i64 = Block{ var T:i64 = 0; For(I:0..2, J:0..1, Block{ set T = T + I * J; NextTick() }); T }\nG()<transacts><suspends>:i64 = Block{ For(X:array{4, 5, 6}, X > 4, Block{ If(X == 6, Return(X), 0); NextTick() }); 0 }\nM:task(i64) = Spawn{ F() + G() }",
    }) |source| {
        const p = try h.compile(source);
        var budget: u64 = 0;
        while (true) : (budget += 1) {
            const outcome = try h.run(p, budget);
            if (outcome == .ok) break;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
            try std.testing.expect(budget < 100_000);
        }
        try std.testing.expect(budget > 30);
    }
}

test "a For that suspends in a digest run that reclaims reports as a stored run, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Work(N:i64)<transacts><suspends>:[]i64 = Block{ Defer{ X := Many(3) }; For(I:0..4, I != 2, J := Many(I + 2), Block{ Defer{ Y := Many(2) }; Sleep(0.1); J + N }) }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    T := Spawn{ Work(1) }
        \\    U := Spawn{ Work(2) }
        \\    K := Many(8)
        \\    Sleep(0.25)
        \\    T.Cancel()
        \\    R := U.Await()
        \\    R.Length + K
        \\}
        \\M:task(i64) = Spawn{ Main() }
        \\C:i64 = Many(14)
    ;
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const stored = (try f.h.run(p, concurrency.fuel)).ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = out.buffered();
    for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
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
        const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, concurrency.fuel);
        const actual = f.h.runtime.evaluate(p, concurrency.fuel);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
        try std.testing.expect(actual.ok.reclaims != 0);
        try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
        out = .fixed(f.replayed);
        _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, concurrency.fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        _ = try reporting.validateReplayed(reference.ok, f.again.producer(p, concurrency.fuel), false, .{});
    }
}

test "a For that suspends in a module of a bundle, and its refusal there" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nH<public>:task([]i64)=L.Start(3)" },
        .{ .path = "lib.forb", .source = "Twice(N:i64)<transacts><suspends>:i64=Block{Sleep(0.25);N*2}\nStart<public>(N:i64)<transacts>:task([]i64)=Spawn{For(I:1..N,J:=I+1,Twice(J))}" },
    };
    const bundle = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |value| value,
        .failed => |failure| {
            std.debug.print("bundle failed: {s} in {s}\n", .{ failure.diagnostic.message(), failure.path });
            return error.Compile;
        },
    };
    const run = (try h.run(bundle, concurrency.fuel)).ok;
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, run, true, .{});
    try std.testing.expectEqualStrings("{\"H\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[4,6,8]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":45,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":7,\"waiting\":[]}}\n", out.buffered());
    const failing = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nH<public>:task([]i64)=L.Start(3)" },
        .{ .path = "lib.forb", .source = "Xs:[]i64=array{1}\nTwice(N:i64)<transacts><suspends>:i64=Block{Sleep(0.25);N*2}\nStart<public>(N:i64)<transacts>:task([]i64)=Spawn{For(I:1..N,J:=Xs[I],Twice(J))}" },
    };
    const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &failing });
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.suspending_for_fails, refused.failed.diagnostic.code);
    try std.testing.expectEqualStrings("lib.forb", refused.failed.path);
    try std.testing.expectEqualStrings("J:=Xs[I]", refused.failed.source[refused.failed.diagnostic.span.start..refused.failed.diagnostic.span.end]);
}

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms));
}

/// The scale test of P3.8: two tasks, each a `For` over `count` values with a filter and a
/// binding whose body waits for the next tick, in a digest run that reclaims, which the
/// replay checks. Every iteration is a wait and a restore; what stays is the two arrays the
/// loops build. Prints how long each machine and the replay took.
pub fn suspendingLoops(f: trace_replay.Fixture, count: u64) !void {
    const h = f.h;
    var buffer: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&buffer,
        \\var Visits:i64 = 0
        \\Service(N:i64)<transacts><suspends>:i64 = Block{{
        \\    Kept := For(I:1..{d}, I != 0, J := I + N, Block{{ set Visits = Visits + 1; S := "visit {{J}}"; Sleep(0.0); S.Length }})
        \\    Kept.Length
        \\}}
        \\A:task(i64) = Spawn{{ Service(1) }}
        \\B:task(i64) = Spawn{{ Service(2) }}
    , .{count});
    const p = try h.compile(source);
    const budget: u64 = 1 << 40;
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("suspending loops failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(4 * count + 2, actual.ok.scheduler.switches);
    try std.testing.expectEqual(count, actual.ok.scheduler.tick);
    try std.testing.expectEqual(@as(i64, @intCast(2 * count)), actual.ok.cells[0].value.integer);
    var report: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("{d} iterations of two For loops that each wait, {d} reclamations, {d} members left: reference={d}ms vm={d}ms replay={d}ms\n", .{ 2 * count, actual.ok.reclaims, actual.ok.aggregate_values.len, referenced, ran - referenced, elapsed(start) - ran });
    var expected: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&expected, "\"result\":{d}", .{count})) != null);
}

test "two For loops that wait every iteration, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try suspendingLoops(f, 500);
}
