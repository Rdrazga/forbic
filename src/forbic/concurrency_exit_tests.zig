//! Structured concurrency, P3.6 (RFC-0082): `Return`, and `Break` to a `Loop{}` around the
//! expression, inside an arm of `Sync`, `Race` or `Rush`. The arm ends with a pending exit
//! (`arm_exit`), which abandons its expression: the other started arms are cancelled and waited
//! for, unstarted arms never start, and the site's check carries the exit on where the
//! expression stands (`arm_exited`, `arm_exit_value`). Both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");
const concurrency = @import("concurrency_tests.zig");

const expectRun = concurrency.expectRun;

fn expectPrinted(h: *harness.Harness, source: []const u8, expected: []const u8) !evaluator.Execution {
    const x = try expectRun(h, source);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(expected, concurrency.printed(x, &buffer));
    return x;
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "the Book's 14:524: a Return in an arm returns from the function and abandons the Sync" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var ArmTwoRan:i64 = 0
        \\var PastSync:i64 = 0
        \\var Result:i64 = 0
        \\Abandon()<transacts><suspends>:i64 = Block{
        \\    Sync(
        \\        Block{ Sleep(0.0); Return(5) },
        \\        Block{ Sleep(0.0); Set(ArmTwoRan, 1) })
        \\    set PastSync = 1
        \\    0
        \\}
        \\RunAbandon()<transacts><suspends>:void = Set(Result, Abandon())
        \\Started:task(void) = Spawn{ RunAbandon() }
    );
    // Arm two never got to run, the code after the Sync never ran, and 5 came out.
    try expectReport(x, "{\"ArmTwoRan\":0,\"PastSync\":0,\"Result\":5,\"Started\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":1,\"created\":3,\"completed\":2,\"canceled\":1,\"switches\":9,\"waiting\":[]}}\n");
}

test "the Book's 14:562: a Return in a function an arm calls returns from that function only" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var ArmTwoRan:i64 = 0
        \\var PastSync:i64 = 0
        \\var Result:i64 = 0
        \\Finish()<transacts><suspends>:i64 = Block{
        \\    Sleep(0.0)
        \\    Return(5)
        \\}
        \\KeepWaiting()<transacts><suspends>:i64 = Block{
        \\    R := Sync(
        \\        Finish(),
        \\        Block{ Sleep(0.0); Set(ArmTwoRan, 1); 2 })
        \\    set PastSync = 1
        \\    R(0)
        \\}
        \\RunKeep()<transacts><suspends>:void = Set(Result, KeepWaiting())
        \\Started:task(void) = Spawn{ RunKeep() }
    );
    // This time both arms finished and execution continued past the Sync.
    try expectReport(x, "{\"ArmTwoRan\":1,\"PastSync\":1,\"Result\":5,\"Started\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":1,\"created\":3,\"completed\":3,\"canceled\":0,\"switches\":9,\"waiting\":[]}}\n");
    // No arm exits here, so nothing of P3.6 is in the program.
    for (x.program.functions) |f| try std.testing.expect(f.exits == null);
    for (x.program.function_nodes) |entry| try std.testing.expect(entry.node.kind != .arm_exited and entry.node.kind != .arm_exit);
}

test "Defers run innermost first: the arm's own, then the cancelled arms', then the function's" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Slow(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("slow {N}") }; Sleep(Inf); N }
        \\F()<transacts><suspends>:i64 = Block{
        \\    Defer{ Print("function") }
        \\    R := Race(Slow(1), Block{ Defer{ Print("arm") }; Sleep(0.5); Return(7) }, Slow(2))
        \\    Print("after")
        \\    R
        \\}
        \\Main()<transacts><suspends>:void = Print("got {F()}")
        \\T:task(void) = Spawn{ Main() }
    , "arm\nslow 1\nslow 2\nfunction\ngot 7\n");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.canceled);
}

test "an exit abandons a Sync and a Rush too: their other started arms are cancelled, not kept" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Wait(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("wait {N}") }; Sleep(Inf); N }
        \\S()<transacts><suspends>:i64 = Block{ P := Sync(Wait(1), Block{ Sleep(0.1); Return(10) }); P(0) }
        \\U()<transacts><suspends>:i64 = Block{ Q:i64 = Rush(Wait(2), Block{ Sleep(0.1); Return(20) }); Q }
        \\Main()<transacts><suspends>:void = Block{ Print("s {S()}"); Print("u {U()}") }
        \\T:task(void) = Spawn{ Main() }
    , "wait 1\ns 10\nwait 2\nu 20\n");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

test "an exit in the start phase: unstarted arms never start, and the expression yields the exit at once" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Arm(N:i64)<transacts><suspends>:i64 = Block{ Print("arm {N}"); Sleep(1.0); N }
        \\F(C:logic)<transacts><suspends>:i64 = Block{
        \\    R := Race(Arm(1), Block{ Print("exit"); If(C, Return(-1), 0) }, Arm(3))
        \\    R
        \\}
        \\Main()<transacts><suspends>:void = Block{ Print("f {F(true)}"); Print("g {F(false)}") }
        \\T:task(void) = Spawn{ Main() }
    , "arm 1\nexit\nf -1\narm 1\nexit\ng 0\n");
    // Main; arm 1 and arm 2 of each F; arm 3 of neither: arm 2 ends the expression at once.
    try std.testing.expectEqual(@as(u64, 5), x.scheduler.created);
    var at_once = false;
    for (x.call_steps, 0..) |step, index| {
        if (step.kind != .resume_exited) continue;
        // No `suspend` of the parent before it: it yielded in its start phase.
        try std.testing.expect(index > 0 and x.call_steps[index - 1].kind != .@"suspend");
        try std.testing.expectEqual(@as(i64, -1), step.value.integer);
        at_once = true;
    }
    try std.testing.expect(at_once);
}

test "Break to a Loop{} around the expression, and a Return through the loop, with the visit's Defers" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Count()<transacts><suspends>:i64 = Block{
        \\    var N:i64 = 0
        \\    Loop{
        \\        set N = N + 1
        \\        Defer{ Print("visit {N}") }
        \\        R := Race(
        \\            Block{ Defer{ Print("slow {N}") }; Sleep(2.0); 2 },
        \\            Block{ Sleep(1.0); If(N == 3, Break(), 1) })
        \\        Print("raced {N}")
        \\    }
        \\    N
        \\}
        \\Find(K:i64)<transacts><suspends>:i64 = Block{
        \\    Defer{ Print("find {K}") }
        \\    var N:i64 = 0
        \\    Loop{
        \\        set N = N + 1
        \\        P := Sync(
        \\            Block{ Sleep(1.0); If(N == K, Return(100 + N), false) },
        \\            Block{ Sleep(1.0); If(N == 2, Break(), false) })
        \\    }
        \\    N
        \\}
        \\Main()<transacts><suspends>:void = Block{
        \\    Print("count {Count()}")
        \\    Print("find1 {Find(1)}")
        \\    Print("find5 {Find(5)}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "slow 1\nraced 1\nvisit 1\nslow 2\nraced 2\nvisit 2\nslow 3\nvisit 3\ncount 3\nfind 1\nfind1 101\nfind 5\nfind5 2\n");
}

test "an exit through nested arms returns from the function where it is written, cancelling every level" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Wait(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("wait {N}") }; Sleep(Inf); N }
        \\F()<transacts><suspends>:i64 = Block{
        \\    Defer{ Print("f") }
        \\    R := Race(
        \\        Wait(1),
        \\        Block{ Defer{ Print("outer arm") }; P := Sync(Wait(2), Block{ Sleep(0.2); Return(42) }); P(0) })
        \\    R + 1
        \\}
        \\Main()<transacts><suspends>:void = Print("got {F()}")
        \\T:task(void) = Spawn{ Main() }
    , "wait 2\nouter arm\nwait 1\nf\ngot 42\n");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.canceled);
}

test "an exit commits the arm's regions, and a Return in a function the arm calls is that function's" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\var Log:[]string = array{}
        \\Note(S:string)<transacts>:void = Set(Log, Log + array{S})
        \\Inner()<transacts>:i64 = Block{ Note("inner"); Return(3) }
        \\F()<transacts><suspends>:i64 = Block{
        \\    R := Race(Block{ Sleep(1.0); 0 }, Block{ Sleep(0.1); Attempt(Block{ Note("kept"); Return(Inner()) }, 9) })
        \\    R
        \\}
        \\Main()<transacts><suspends>:void = Block{ V := F(); Print("{V} {Log.Length}") }
        \\T:task(void) = Spawn{ Main() }
    , "3 2\n");
}

test "an arm that owns a branch ends after it, and cancellation of the task beats a pending exit" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Tick()<transacts><suspends>:void = Block{ Defer{ Print("branch") }; Sleep(Inf) }
        \\F()<transacts><suspends>:i64 = Block{ R := Race(Block{ Sleep(1.0); 0 }, Block{ Branch{ Tick() }; Sleep(0.1); Return(5) }); R }
        \\G()<transacts><suspends>:i64 = Block{ Defer{ Print("g") }; P := Sync(Block{ Sleep(0.5); Return(1) }, Block{ Sleep(0.6); 2 }); P(1) }
        \\Main()<transacts><suspends>:void = Block{
        \\    Print("f {F()}")
        \\    W := Race(Block{ G(); 0 }, Block{ Sleep(0.1); 9 })
        \\    Print("w {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "branch\nf 5\ng\nw 9\n");
}

test "a Rush's loser that exits after the Rush resolved only ends: its function has gone on" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\F()<transacts><suspends>:i64 = Block{
        \\    Q:i64 = Rush(Block{ Sleep(0.1); 1 }, Block{ Defer{ Print("loser") }; Sleep(0.2); Return(2) })
        \\    Print("rushed {Q}")
        \\    Sleep(1.0)
        \\    Q
        \\}
        \\Main()<transacts><suspends>:void = Print("f {F()}")
        \\T:task(void) = Spawn{ Main() }
    , "rushed 1\nloser\nf 1\n");
    try std.testing.expectEqual(@as(u64, 0), x.scheduler.canceled);
}

test "the exits that the Book rejects stay refused, and an exit inside a Fn in an arm is the Fn's" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); T := Spawn{ Return(1) }; 1 }, 2)", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); Branch{ Return(1) }; 1 }, 2)", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Defer{ Return(1) }; Sleep(1.0); 1 }, 2)", .code = .defer_exit, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); Break() }, 2)", .code = .break_outside_loop, .at = "Break" },
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); 1 + Return(1) }, 2)", .code = .return_not_tail, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ X := Spawn{ R := Race(Block{ Sleep(1.0); Return(1) }, 2) }; 0 }", .code = .return_in_task_body, .at = "Return" },
    }) |case| {
        const result = h.front.compile(case.source);
        if (result != .failed) {
            std.debug.print("expected {t}: {s}\n", .{ case.code, case.source });
            return error.TestUnexpectedResult;
        }
        if (result.failed.code != case.code) std.debug.print("got {t} for {s}\n", .{ result.failed.code, case.source });
        try std.testing.expectEqual(case.code, result.failed.code);
        try std.testing.expectEqualStrings(case.at, case.source[result.failed.span.start..result.failed.span.end]);
    }
    // A `Return` in a `Fn` in an arm returns from the `Fn`, and the arm goes on.
    _ = try expectPrinted(h,
        \\F()<transacts><suspends>:i64 = Block{ R := Race(Block{ Sleep(0.1); G := Fn():i64{ Return(4) }; G() + 1 }, Block{ Sleep(1.0); 0 }); R }
        \\Main()<transacts><suspends>:void = Print("{F()}")
        \\T:task(void) = Spawn{ Main() }
    , "5\n");
    // A whole arm may be a `Return`, as an argument of `Attempt` may.
    _ = try expectPrinted(h,
        \\F(C:logic)<transacts><suspends>:i64 = Block{ R:i64 = Race(Block{ Sleep(1.0); 0 }, Return(8)); R }
        \\Main()<transacts><suspends>:void = Print("{F(true)}")
        \\T:task(void) = Spawn{ Main() }
    , "8\n");
}

/// A copy of `p` whose function bodies and metadata are the harness's, to forge.
fn forgeable(h: *harness.Harness, p: types.Program) types.Program {
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    var forged = p;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    forged.functions = h.metadata[0..p.functions.len];
    return forged;
}

const Place = struct { function: usize, at: usize };

fn nth(p: types.Program, kind: std.meta.Tag(@FieldType(types.Node, "kind")), index: usize) Place {
    var seen: usize = 0;
    for (p.functions, 0..) |f, id| for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, at| {
        if (entry.input != .operation or entry.node.kind != kind) continue;
        if (seen == index) return .{ .function = id, .at = at };
        seen += 1;
    };
    unreachable;
}

const forged_source =
    \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("d{N}") }; Sleep(1.0); N }
    \\Use()<transacts><suspends>:i64 = Block{ Defer{ Print("u") }; R := Race(Leaf(3), Block{ Sleep(0.5); Return(7) }); R + 1 }
    \\T:task(i64) = Spawn{ Use() }
;

/// Both machines refuse `forged`, and so does the replay of a run of the program it forges.
fn refused(h: *harness.Harness, forged: types.Program, run: evaluator.Execution) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    if (reporting.validate(x, false, .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.InvalidExecution, err);
}

test "forged arm exits, checks and starts of arms that may exit are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const run = try expectPrinted(h, forged_source, "d3\nu\n");
    var stored: [4096]types.FunctionNode = undefined;
    @memcpy(stored[0..run.program.function_nodes.len], run.program.function_nodes);
    var x = run;
    x.program.function_nodes = stored[0..run.program.function_nodes.len];
    var forged = forgeable(h, p);
    const exit = nth(p, .arm_exit, 0);
    const exited = nth(p, .arm_exited, 0);
    const arm = exit.function;
    const user = exited.function;
    const base = p.functions[user].body.start;
    const site = nth(p, .structured, 0).at;
    try std.testing.expect(p.function_nodes[base + site].node.kind == .structured and p.functions[arm].exits.? == .i64);
    const reissue = p.function_nodes[base + exited.at + 1].node.kind.if_begin;
    const reset = struct {
        fn reset(hh: *harness.Harness, pp: types.Program) void {
            @memcpy(hh.body[0..pp.function_nodes.len], pp.function_nodes);
            @memcpy(hh.metadata[0..pp.functions.len], pp.functions);
        }
    }.reset;
    // An arm's exit in a function that is no arm that may exit, or of another type.
    reset(h, p);
    h.metadata[arm].exits = null;
    try refused(h, forged, x);
    reset(h, p);
    h.metadata[arm].exits = .string;
    try refused(h, forged, x);
    // The exit's value read as another type.
    reset(h, p);
    h.body[base + exited.at + 2].node.value_type = .string;
    try refused(h, forged, x);
    // No second test: the arm that may exit is started by a site that cannot carry its exit.
    reset(h, p);
    h.body[base + exited.at].node.kind = .{ .boolean = false };
    try refused(h, forged, x);
    // The second test's merge reading the exit's value instead of the site, of the same type.
    reset(h, p);
    h.body[base + reissue.end].node.kind.merge.right = @intCast(exited.at + 2);
    try refused(h, forged, x);
    // The check's merge reading the site past the second test.
    reset(h, p);
    h.body[base + reissue.end + 1].node.kind.merge.right = @intCast(site);
    try refused(h, forged, x);
    // A node of a check, and a second arm_exited, in the code that carries the exit on.
    for ([_]std.meta.Tag(@FieldType(types.Node, "kind")){ .canceling, .arm_exited }) |kind| {
        reset(h, p);
        const at = base + reissue.alternative - 1;
        h.body[at].node.kind = if (kind == .canceling) .canceling else .arm_exited;
        h.body[at].node.value_type = .logic;
        refused(h, forged, x) catch |err| {
            std.debug.print("{t} in the code admitted\n", .{kind});
            return err;
        };
    }
    // `arm_exited` and `arm_exit_value` outside a check.
    reset(h, p);
    h.body[base + site - 1].node = .{ .span = h.body[base + site - 1].node.span, .value_type = .logic, .kind = .arm_exited };
    try refused(h, forged, x);
    // A call of the arm's function, which only its expression may start: the spawned body calls it.
    reset(h, p);
    var spawned: Place = undefined;
    for (p.functions, 0..) |f, id| if (std.mem.eql(u8, f.name.text(p.source), "Spawn")) {
        spawned = .{ .function = id, .at = 0 };
        for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, at| if (entry.input == .operation and entry.node.kind == .call) {
            spawned.at = at;
        };
    };
    h.body[p.functions[spawned.function].body.start + spawned.at].node.kind.call.function = @intCast(arm);
    h.metadata[spawned.function].value_type = p.functions[arm].value_type;
    try harness.invalid(h, forged);
    // The arm's function calling itself, or naming itself, which would start it as no arm.
    reset(h, p);
    h.body[p.functions[arm].body.start + exit.at - 1].node = .{ .span = p.function_nodes[p.functions[arm].body.start].node.span, .value_type = h.body[p.functions[arm].body.start + exit.at - 1].node.value_type, .kind = .self_value };
    try harness.invalid(h, forged);
    // An arm's exit in the landing of a site.
    reset(h, p);
    const leaf_sleep = nth(p, .sleep, 0);
    const leaf = p.functions[leaf_sleep.function];
    var landed: usize = leaf_sleep.at + 3;
    while (p.function_nodes[leaf.body.start + landed].node.kind != .invoke) landed += 1;
    h.metadata[leaf_sleep.function].exits = .i64;
    h.body[leaf.body.start + landed].node.kind = .{ .arm_exit = 0 };
    try harness.invalid(h, forged);
    reset(h, p);
    _ = &forged;
}

test "a forged schedule of arm exits is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("d{N}") }; Sleep(1.0); N }
        \\Use(C:logic)<transacts><suspends>:i64 = Block{ R := Race(Leaf(3), Block{ Sleep(0.5); If(C, Return(7), 1) }); Q:i64 = Race(Block{ Return(8) }, Leaf(4)); R + Q }
        \\T:task(i64) = Spawn{ Block{ A := Use(true); Use(false) } }
    );
    _ = try reporting.validate(x, false, .{});
    const steps = x.call_steps;
    const Forgery = enum { exit_value, resume_exited_value, exited_as_resume, at_once_value, exited_test, settle_value, completed_count };
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var done = false;
        var seen: usize = 0;
        for (h.steps[0..steps.len], 0..) |*step, index| {
            if (done) break;
            switch (forgery) {
                .exit_value => if (step.kind == .arm_exit) {
                    step.value.integer += 1;
                    done = true;
                },
                .resume_exited_value => if (step.kind == .resume_exited) {
                    step.value.integer += 1;
                    done = true;
                },
                .exited_as_resume => if (step.kind == .resume_exited and index > 0 and h.steps[index - 1].kind != .@"suspend") {
                    seen += 1;
                    step.kind = .@"resume";
                    done = true;
                } else if (step.kind == .resume_exited) {
                    step.kind = .@"resume";
                    done = true;
                },
                .at_once_value => if (step.kind == .resume_exited and index > 0 and h.steps[index - 1].kind != .@"suspend") {
                    step.kind = .value;
                    done = true;
                },
                .exited_test => if (step.kind == .value and step.value == .boolean and step.value.boolean) {
                    const node = x.program.function_nodes[x.program.functions[step.function].body.start + step.pc].node;
                    if (node.kind == .arm_exited) {
                        step.value = .{ .boolean = false };
                        done = true;
                    }
                },
                .settle_value => if (step.kind == .settle and index > 0 and h.steps[index - 1].kind == .arm_exit) {
                    step.value.integer += 1;
                    done = true;
                },
                .completed_count => {
                    forged.scheduler.completed -= 1;
                    done = true;
                },
            }
        }
        try std.testing.expect(done);
        _ = reporting.validate(forged, false, .{}) catch |err| {
            try std.testing.expectEqual(error.InvalidExecution, err);
            continue;
        };
        std.debug.print("forged schedule admitted: {t}\n", .{forgery});
        return error.TestUnexpectedResult;
    }
}

test "programs whose arms exit need the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"d{N}\") }; Sleep(Inf); N }\nMain()<transacts><suspends>:i64 = Block{ Defer{ Print(\"m\") }; S := Sync(Leaf(1), Block{ Sleep(0.1); Return(3) }); S(0) }\nM:task(i64) = Spawn{ Main() }",
        "Count()<transacts><suspends>:i64 = Block{ var N:i64 = 0; Loop{ set N = N + 1; R := Race(Block{ Sleep(2.0); 2 }, Block{ Sleep(1.0); If(N == 3, Break(), 1) }) }; N }\nMain()<transacts><suspends>:i64 = Block{ Q:i64 = Rush(Block{ Sleep(0.1); Count() }, Block{ Return(5) }); Q }\nM:task(i64) = Spawn{ Main() }",
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

test "a pending exit is a root: a digest run that reclaims reports as a stored one, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Slow()<transacts><suspends>:tuple(i64, i64, i64) = Block{ Defer{ X := Many(5) }; Sleep(Inf); tuple{0, 0, 0} }
        \\Built(N:i64)<transacts><suspends>:tuple(i64, i64, i64) = Block{
        \\    R := Race(Slow(), Block{ J := Many(6); Sleep(0.1); K := Many(6); Return(tuple{N, J, K}) })
        \\    R
        \\}
        \\Main()<transacts><suspends>:i64 = Block{
        \\    var Total:i64 = 0
        \\    var I:i64 = 0
        \\    Loop{
        \\        set I = I + 1
        \\        A := Built(I)
        \\        set Total = Total + A(0) + A(1) + A(2)
        \\        If(I == 4, Break(), false)
        \\    }
        \\    Total + Many(8)
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

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms));
}

/// A loop of `visits` visits, each a `Race` left by a `Break` in its arm at the last visit and
/// otherwise by a `Return` of a helper's arm, timed per machine and for the replay.
pub fn exitLoop(h: *harness.Harness, visits: u32, budget: u64) !void {
    var source: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&source,
        \\Step(N:i64)<transacts><suspends>:i64 = Block{{ R := Race(Block{{ Sleep(Inf); 0 }}, Block{{ Sleep(0.0); Return(N + 1) }}); R }}
        \\Main()<transacts><suspends>:i64 = Block{{
        \\    var N:i64 = 0
        \\    Loop{{
        \\        P := Sync(Block{{ Sleep(0.0); 0 }}, Block{{ S := Step(N); If(S == {d}, Break(), 0) }})
        \\        set N = N + 1
        \\    }}
        \\    N
        \\}}
        \\M:task(i64) = Spawn{{ Main() }}
    , .{visits});
    const p = try h.compile(text);
    const started = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const reference_ms = elapsed(started);
    const vm_started = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(p, budget);
    const vm_ms = elapsed(vm_started);
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    const replay_started = std.Io.Clock.awake.now(std.testing.io);
    _ = try reporting.validate(actual.ok, false, .{ .work = @max(1024 * 1024, types.limits.report_work) });
    const replay_ms = elapsed(replay_started);
    // Each visit creates four arms, one of which is cancelled.
    try std.testing.expectEqual(@as(u64, 1 + 4 * @as(u64, visits)), actual.ok.scheduler.created);
    try std.testing.expectEqual(@as(u64, visits), actual.ok.scheduler.canceled);
    std.debug.print("{d} visits left by arms' exits: reference={d}ms vm={d}ms replay={d}ms\n", .{ visits, reference_ms, vm_ms, replay_ms });
}

test "a loop left by arms' exits, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    try exitLoop(h, 40, concurrency.fuel);
}

const merged_source =
    \\Use(C:logic)<transacts><suspends>:i64 = Block{
    \\    G := If(C, Fn()<transacts><suspends>:i64{ Block{ Sleep(0.0); 1 } }, Fn()<transacts><suspends>:i64{ Block{ Sleep(0.0); 2 } })
    \\    A := G()
    \\    R:i64 = Race(Block{ Sleep(1.0); 0 }, Block{ Sleep(0.5); Return(7) })
    \\    Q:i64 = Race(Block{ Sleep(1.0); 0 }, Block{ Sleep(0.5); 3 })
    \\    A + R + Q
    \\}
    \\T:task(i64) = Spawn{ Use(true) }
;

var forged_arguments: [4096]u32 = undefined;

test "review: the closure of an arm that may exit handed on by a merge is refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(merged_source);
    _ = try expectRun(h, merged_source);
    var arm: usize = 0;
    var user: usize = 0;
    for (p.functions, 0..) |f, id| {
        if (f.exits != null) arm = id;
        if (std.mem.eql(u8, f.name.text(p.source), "Use")) user = id;
    }
    var forged = forgeable(h, p);
    const base = p.functions[user].body.start;
    const body = p.function_nodes[base..p.functions[user].body.end];
    var merge_at: u32 = 0;
    var left: u32 = 0;
    var plain: ?u32 = null;
    for (body, 0..) |entry, at| {
        if (entry.input != .operation) continue;
        if (merge_at == 0 and entry.node.kind == .merge and body[entry.node.kind.merge.left].node.kind == .function_value) {
            merge_at = @intCast(at);
            left = entry.node.kind.merge.left;
        }
        // The second `Race`, whose check reads no pending exit.
        if (entry.node.kind == .structured) plain = @intCast(at);
    }
    try std.testing.expect(merge_at != 0 and plain != null);
    // A merge hands the arm on to the call `G()`, which would run it as no arm.
    h.body[base + left].node.kind = .{ .function_value = @intCast(arm) };
    try harness.invalid(h, forged);
    // And as an arm of the `Race` whose check carries no exit.
    @memcpy(forged_arguments[0..p.function_arguments.len], p.function_arguments);
    forged.function_arguments = forged_arguments[0..p.function_arguments.len];
    forged_arguments[body[plain.?].node.kind.structured.arms.start + 1] = merge_at;
    try harness.invalid(h, forged);
}
