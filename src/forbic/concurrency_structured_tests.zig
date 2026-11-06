//! Structured concurrency, P3.3 (RFC-0082): `Sync` and `Race`, their records and start phase,
//! resolution, cancellation requests and unwinding through the landings of `Defer`s, in both
//! machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");
const concurrency = @import("concurrency_tests.zig");
const catalogue = @import("aggregate_types.zig");

const expectRun = concurrency.expectRun;
const printed = concurrency.printed;

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
}

fn expectPrinted(h: *harness.Harness, source: []const u8, expected: []const u8) !evaluator.Execution {
    const x = try expectRun(h, source);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(expected, printed(x, &buffer));
    return x;
}

test "Sync runs every arm and yields their results in order; Race yields the first and cancels the rest" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Fetch(N:i64, S:float)<transacts><suspends>:i64 = Block{ Print("fetch {N}"); Sleep(S); Print("fetched {N}"); N * 10 }
        \\Both()<transacts><suspends>:tuple(i64, i64) = Sync(Fetch(1, 0.5), Fetch(2, 0.1))
        \\First()<transacts><suspends>:i64 = Race(Fetch(3, 0.5), Fetch(4, 0.1))
        \\Main()<transacts><suspends>:void = Block{
        \\    P := Both()
        \\    Print("both {P(0)} {P(1)}")
        \\    Print("first {First()}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "fetch 1\nfetch 2\nfetched 2\nfetched 1\nboth 10 20\nfetch 3\nfetch 4\nfetched 4\nfirst 40\n");
    // Main and four arms; the loser of the Race was cancelled.
    try std.testing.expectEqual(@as(u64, 5), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 4), x.scheduler.completed);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.canceled);
}

test "cancellation order: arms settle before the expression yields, children before parents, Defers innermost first" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Leaf(N:i64)<transacts><suspends>:void = Block{ Defer{ Print("leaf {N} defer") }; Sleep(Inf) }
        \\Mid(N:i64)<transacts><suspends>:void = Block{ Defer{ Print("mid {N} defer") }; S := Sync(Leaf(N * 10 + 1), Leaf(N * 10 + 2)); Print("mid {N} after") }
        \\Top()<transacts><suspends>:void = Block{ Defer{ Print("top defer") }; S := Sync(Mid(1), Mid(2)); Print("top after") }
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Block{ Top(); 0 }, Block{ Sleep(1.0); 1 })
        \\    Print("winner {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "leaf 11 defer\nleaf 12 defer\nleaf 21 defer\nleaf 22 defer\nmid 1 defer\nmid 2 defer\ntop defer\nwinner 1\n");
    // Main, the two arms of the Race, the two of Top's Sync and the four leaves: seven cancelled.
    try std.testing.expectEqual(@as(u64, 9), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.completed);
    try std.testing.expectEqual(@as(u64, 7), x.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

test "a Race yields only once its losers have settled, after their Defers" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Slow()<transacts><suspends>:i64 = Block{ Defer{ Print("slow cleanup") }; Sleep(5.0); 1 }
        \\Quick()<transacts><suspends>:i64 = Block{ Sleep(0.1); 2 }
        \\Main()<transacts><suspends>:void = Block{ W := Race(Slow(), Quick()); Print("won {W}") }
        \\T:task(void) = Spawn{ Main() }
    , "slow cleanup\nwon 2\n");
}

test "the start phase: arms start in order, each until it first waits, and none after a resolution" {
    const h = try harness.create();
    defer scratch.release(h);
    // Arm 2 completes without waiting: it wins at once, arm 3 never starts, arm 1 is cancelled.
    var x = try expectPrinted(h,
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Block{ Print("one"); Sleep(0.0); 1 }, Block{ Print("two"); Sleep(-1.0); 2 }, Block{ Print("three"); Sleep(0.0); 3 })
        \\    Print("won {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "one\ntwo\nwon 2\n");
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.canceled);
    // The Book's 14:385 under Q2: all three wait for the next tick, and arm 1 registered first.
    x = try expectPrinted(h,
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Block{ Print("one"); Sleep(0.0); 1 }, Block{ Print("two"); Sleep(0.0); 2 }, Block{ Print("three"); Sleep(0.0); 3 })
        \\    Print("won {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "one\ntwo\nthree\nwon 1\n");
    try std.testing.expectEqual(@as(u64, 4), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.canceled);
    // A Sync whose arms all complete in the start phase yields at once: its task never waits.
    x = try expectPrinted(h,
        \\Main()<transacts><suspends>:void = Block{
        \\    P := Sync(Block{ Sleep(-1.0); 1 }, Block{ Sleep(-1.0); 2 })
        \\    Print("{P(0)} {P(1)}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "1 2\n");
    try std.testing.expectEqualDeep(types.Scheduler{ .created = 3, .completed = 3, .switches = 3 }, x.scheduler);
}

test "a cancelled waiter leaves the event's waiters and a cancelled awaiter the task's" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try expectPrinted(h,
        \\E:event(i64) = event(i64){}
        \\Waiter(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("waiter {N} gone") }; E.Await() + N }
        \\Late()<transacts><suspends>:void = Block{ V := E.Await(); Print("late {V}") }
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Waiter(1), Waiter(2), Block{ Sleep(0.5); 0 })
        \\    Print("won {W}")
        \\    T := Spawn{ Late() }
        \\    E.Signal(5)
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "waiter 1 gone\nwaiter 2 gone\nwon 0\nlate 5\n");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.canceled);
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.completed);
    x = try expectPrinted(h,
        \\Job()<transacts><suspends>:i64 = Block{ Sleep(2.0); 7 }
        \\Main()<transacts><suspends>:void = Block{
        \\    J := Spawn{ Job() }
        \\    W := Race(Block{ Defer{ Print("awaiter gone") }; J.Await() }, Block{ Sleep(1.0); 3 })
        \\    Print("won {W}")
        \\    Print("job {J.Await()}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "awaiter gone\nwon 3\njob 7\n");
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.canceled);
}

test "tasks waiting on an expression, and its arms, are listed at quiescence; a settled arm is not" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\Main()<transacts><suspends>:void = Block{ X := Sync(E.Await(), Block{ Sleep(0.1); 1 }); Print("never") }
        \\T:task(void) = Spawn{ Main() }
    );
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.completed);
    try std.testing.expectEqual(@as(usize, 2), x.scheduler.waiting.len);
    try std.testing.expectEqual(types.Scheduler.Waiting{ .task = 1, .kind = .spawn, .wait = .record, .span = x.scheduler.waiting[0].span }, x.scheduler.waiting[0]);
    try std.testing.expectEqual(types.Scheduler.Waiting{ .task = 2, .kind = .arm, .wait = .event, .span = x.scheduler.waiting[1].span }, x.scheduler.waiting[1]);
    try std.testing.expectEqualStrings("Sync", x.program.source[x.scheduler.waiting[0].span.start..x.scheduler.waiting[0].span.end]);
    try std.testing.expectEqualStrings("Await", x.program.source[x.scheduler.waiting[1].span.start..x.scheduler.waiting[1].span.end]);
}

test "a landing sees the locals as they are at its site, may spawn, and a loop's visit cancelled ends the loop" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Count()<transacts><suspends>:i64 = Block{
        \\    var N:i64 = 1
        \\    Defer{ Print("n {N}") }
        \\    set N = 2
        \\    Sleep(5.0)
        \\    set N = 3
        \\    N
        \\}
        \\Leaf()<transacts><suspends>:i64 = Block{ Defer{ T := Spawn{ Block{ Print("spawned in landing"); Sleep(0.1); Print("it ran") } } }; Sleep(Inf); 0 }
        \\var Ticks:i64 = 0
        \\Ticker()<transacts><suspends>:i64 = Block{ Defer{ Print("ticker stops at {Ticks}") }; Loop{ Sleep(1.0); set Ticks = Ticks + 1; Print("tick {Ticks}") }; Ticks }
        \\Main()<transacts><suspends>:void = Block{
        \\    A := Race(Count(), Block{ Sleep(1.0); 0 })
        \\    B := Race(Leaf(), Block{ Sleep(1.0); 0 })
        \\    C := Race(Ticker(), Block{ Sleep(2.5); 0 })
        \\    Print("done {A} {B} {C}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "n 2\nspawned in landing\nit ran\ntick 1\ntick 2\nticker stops at 2\ndone 0 0 0\n");
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code) std.debug.print("got {t} at {d} for {s}\n", .{ result.failed.code, result.failed.span.start, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

test "every compile-time refusal of P3.3 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        // A site: only a function that suspends waits for arms, and not in a failure context.
        .{ .source = "F()<transacts>:tuple(i64, i64) = Sync(1, 2)", .code = .call_requires_suspends, .at = "Sync" },
        .{ .source = "X:i64 = Race(1, 2)", .code = .call_requires_suspends, .at = "Race" },
        .{ .source = "F()<transacts><suspends>:i64 = Attempt(Race(Block{ Sleep(1.0); 1 }, 2), 0)", .code = .suspends_in_failure_context, .at = "Race" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Defer{ X := Race(Block{ Sleep(1.0); 1 }, 2) }; 1 }", .code = .suspends_in_failure_context, .at = "Race" },
        // Arms: at least two, and a Sync two that can suspend.
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); 1 })", .code = .concurrency_arms, .at = "Race" },
        .{ .source = "F()<transacts><suspends>:i64 = Race()", .code = .concurrency_arms, .at = "Race" },
        .{ .source = "F()<transacts><suspends>:tuple(i64, i64) = Sync(Block{ Sleep(1.0); 1 }, 2)", .code = .sync_arms, .at = "Sync" },
        .{ .source = "F()<transacts><suspends>:tuple(i64, i64) = Sync(1, 2)", .code = .sync_arms, .at = "Sync" },
        // Exits cannot leave an arm, whether the parser or the macro pass sees them.
        // From P3.6 an exit leaves an arm (`concurrency_exit_tests.zig`); a `Break` still needs a loop.
        .{ .source = "F()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); Break(); 1 }, 2)", .code = .break_outside_loop, .at = "Break" },
        // Arms capture by value; a local `var` an arm assigns is shared (RFC-0085, I5).
        .{ .source = "F()<transacts><suspends>:i64 = Block{ N:i64 = 0; Race(Block{ Sleep(1.0); set N = 1; N }, 2) }", .code = .arm_assigns_local, .at = "N" },
        // A failable expression has no failure context directly in an arm.
        .{ .source = "Xs:[]i64 = array{1}\nF()<transacts><suspends>:i64 = Race(Block{ Sleep(1.0); Xs[0] }, 2)", .code = .failure_context_required, .at = "[" },
        // A Race's arms share one type: the place's, or else the first arm's.
        .{ .source = "F()<transacts><suspends>:void = Block{ X := Race(Block{ Sleep(1.0); 1 }, \"two\"); 0 }", .code = .type_mismatch, .at = "\"two\"" },
        // A Defer open at a site runs as a function there, which shares a local `var` it
        // assigns (RFC-0085, I5); a parameter is refused in the copies at its exits.
        .{ .source = "F(N:i64)<transacts><suspends>:i64 = Block{ Defer{ set N = 1 }; Sleep(1.0); N }\nG()<transacts><suspends>:i64 = Race(F(1), 2)", .code = .not_mutable, .at = "N" },
    }) |case| try expectRefused(h, case.source, case.code, case.at);
    // `Spawn{ Break() }` leaves the body, as a `Return` does.
    try expectRefused(h, "T:task(i64) = Spawn{ Break(); 1 }", .return_in_task_body, "Break");
}

test "Sync and Race yield to whatever the program declares by those names" {
    const h = try harness.create();
    defer scratch.release(h);
    // A function, a local, a parameter and a class member named so keep their meaning.
    var x = try h.execute("Sync(A:i64, B:i64)<computes>:i64 = A + B\nX:i64 = Sync(1, 2)");
    try std.testing.expectEqual(@as(i64, 3), x.values[x.program.bindings[x.program.bindings.len - 1].node].integer);
    x = try h.execute("F(Race:i64)<computes>:i64 = Race + 1\nX:i64 = F(4)");
    try std.testing.expectEqual(@as(i64, 5), x.values[x.program.bindings[x.program.bindings.len - 1].node].integer);
    x = try h.execute("X:i64 = Block{ Race := 7; Race + 1 }");
    try std.testing.expectEqual(@as(i64, 8), x.values[x.program.bindings[x.program.bindings.len - 1].node].integer);
    // Where something else is `Sync`, a `Sync(` of one argument is that, not the form.
    x = try h.execute("Sync(A:i64)<computes>:i64 = A * 2\nX:i64 = Sync(21)");
    try std.testing.expectEqual(@as(i64, 42), x.values[x.program.bindings[x.program.bindings.len - 1].node].integer);
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

/// The `index`-th node of `kind` in the bodies of `p`, in order.
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
    \\Use(S:string)<transacts><suspends>:i64 = Block{ P := Sync(Leaf(1), Leaf(2)); R := Race(Leaf(3), Leaf(4)); P(0) + R }
    \\T:task(i64) = Spawn{ Use("s") }
;

test "forged structured expressions are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    _ = try expectRun(h, forged_source);
    var forged = forgeable(h, p);
    const sync = nth(p, .structured, 0);
    const race = nth(p, .structured, 1);
    const base = p.functions[sync.function].body.start;
    const sync_node = p.function_nodes[base + sync.at].node;
    const race_node = p.function_nodes[base + race.at].node;
    try std.testing.expect(sync_node.kind.structured.kind == .sync and race_node.kind.structured.kind == .race);
    const Forgery = struct { at: usize, node: types.Node };
    var cases: [8]Forgery = undefined;
    var count: usize = 0;
    // One arm.
    var node = sync_node;
    node.kind.structured.arms.end = node.kind.structured.arms.start + 1;
    cases[count] = .{ .at = sync.at, .node = node };
    count += 1;
    // A sync typed as one of its arms, a race typed as a tuple, and each kind swapped.
    node = sync_node;
    node.value_type = .i64;
    cases[count] = .{ .at = sync.at, .node = node };
    count += 1;
    node = race_node;
    node.value_type = sync_node.value_type;
    cases[count] = .{ .at = race.at, .node = node };
    count += 1;
    node = sync_node;
    node.kind.structured.kind = .race;
    cases[count] = .{ .at = sync.at, .node = node };
    count += 1;
    node = race_node;
    node.kind.structured.kind = .sync;
    cases[count] = .{ .at = race.at, .node = node };
    count += 1;
    node = race_node;
    node.value_type = .string;
    cases[count] = .{ .at = race.at, .node = node };
    count += 1;
    for (cases[0..count]) |case| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        h.body[base + case.at].node = case.node;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("forged {any} admitted\n", .{case.node});
            return err;
        };
    }
    // A structured expression without its check after it.
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    h.body[base + sync.at + 1].node.kind = .{ .boolean = false };
    try harness.invalid(h, forged);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    // In a function that does not suspend.
    h.metadata[sync.function].detail = .{};
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // The arms' effects lie within the function's: here they would not.
    h.metadata[sync.function].detail = .{ .no_writes = true, .suspends = true };
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    _ = &forged;
}

test "the landing forgeries: a landing holds no site, exit or check, and does not read its site" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    var forged = forgeable(h, p);
    const site = nth(p, .sleep, 0);
    const f = p.functions[site.function];
    const base = f.body.start;
    // The landing of the `Sleep` calls the `Defer`'s function: `function_value`, `bind`, `invoke`.
    var call: usize = site.at + 3;
    while (p.function_nodes[base + call].node.kind != .invoke) call += 1;
    try std.testing.expect(p.function_nodes[base + call + 1].node.kind == .cancel_exit);
    const invoke = p.function_nodes[base + call].node;
    const sleep = p.function_nodes[base + site.at].node;
    var cases: [5]types.Node = undefined;
    // A site in the landing: the `Sleep` again, and a `canceling`.
    cases[0] = sleep;
    cases[1] = .{ .span = invoke.span, .value_type = .logic, .kind = .canceling };
    // An exit in the landing, of the parameter's value.
    cases[2] = .{ .span = invoke.span, .value_type = invoke.value_type, .kind = .{ .exit = 0 } };
    // The landing reading the site's register.
    cases[3] = invoke;
    cases[3].kind.invoke.callable = @intCast(site.at);
    // A `cancel_exit` where the call was, so that the landing ends twice.
    cases[4] = .{ .span = invoke.span, .value_type = invoke.value_type, .kind = .cancel_exit };
    for (cases) |node| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        h.body[base + call].node = node;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("forged landing {any} admitted\n", .{node.kind});
            return err;
        };
    }
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    _ = &forged;
}

test "a forged schedule of arms and cancellations is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("d{N}") }; Sleep(Inf); N }
        \\Ear()<transacts><suspends>:i64 = Block{ Defer{ Print("e") }; E.Await() }
        \\Pair()<transacts><suspends>:tuple(i64, i64) = Sync(Leaf(1), Leaf(2))
        \\Main()<transacts><suspends>:i64 = Block{ W := Race(Block{ Q := Pair(); Q(0) }, Ear(), Block{ Sleep(0.5); 9 }); B := Sync(Block{ Sleep(0.1); 1 }, Block{ Sleep(0.2); 2 }); W + B(0) + B(1) }
        \\M:task(i64) = Spawn{ Main() }
    );
    _ = try reporting.validate(x, false, .{});
    try std.testing.expectEqual(@as(u64, 4), x.scheduler.canceled);
    const steps = x.call_steps;
    const Forgery = enum { resume_canceled_value, canceled_as_resume, settle_canceled_value, call_canceled_dropped, cancel_exit_value, swapped_cancellations, record_suspend_value, tuple_member, canceled_count, start_value, extra_canceling };
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var members: [512]types.Value = undefined;
        var done = false;
        var index: usize = 0;
        while (index < steps.len and !done) : (index += 1) {
            const step = &h.steps[index];
            switch (forgery) {
                .resume_canceled_value => if (step.kind == .resume_canceled) {
                    step.value.integer += 1;
                    done = true;
                },
                .canceled_as_resume => if (step.kind == .resume_canceled) {
                    step.kind = .@"resume";
                    step.value = .{ .aggregate = .{ .value_type = x.program.function_nodes[0].node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                    done = true;
                },
                .settle_canceled_value => if (step.kind == .settle and step.value == .boolean) {
                    step.value = .{ .integer = 1 };
                    done = true;
                },
                .call_canceled_dropped => if (step.kind == .call_canceled) {
                    step.kind = .value;
                    done = true;
                },
                .cancel_exit_value => if (step.kind == .cancel_exit) {
                    step.value = .{ .boolean = true };
                    done = true;
                },
                .swapped_cancellations => if (step.kind == .resume_canceled) {
                    // Two cancelled tasks restored in the other order: the requests were made in
                    // arm order, depth first.
                    var other = index + 1;
                    while (other < steps.len and h.steps[other].kind != .resume_canceled) other += 1;
                    if (other < steps.len) {
                        std.mem.swap(types.CallStep, step, &h.steps[other]);
                        done = true;
                    }
                },
                .record_suspend_value => if (step.kind == .@"suspend" and step.value == .integer and step.value.integer < 4) {
                    step.value.integer += 1;
                    done = true;
                },
                .tuple_member => if (step.kind == .@"resume" and step.value == .aggregate and step.value.aggregate.elements.end > step.value.aggregate.elements.start) {
                    @memcpy(members[0..x.aggregate_values.len], x.aggregate_values);
                    members[step.value.aggregate.elements.start] = .{ .integer = 77 };
                    forged.aggregate_values = members[0..x.aggregate_values.len];
                    done = true;
                },
                .canceled_count => {
                    forged.scheduler.canceled -= 1;
                    done = true;
                },
                .start_value => if (step.kind == .start and index > 0) {
                    step.value.integer += 1;
                    done = true;
                },
                .extra_canceling => if (step.kind == .value and step.value == .boolean and !step.value.boolean and index + 1 < steps.len and h.steps[index + 1].kind == .value) {
                    // A check that says its task is unwinding where no site yielded cancelled.
                    const node = x.program.function_nodes[x.program.functions[step.function].body.start + step.pc].node;
                    if (node.kind == .canceling) {
                        step.value = .{ .boolean = true };
                        done = true;
                    }
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

test "the same structured program needs the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"d{N}\") }; Sleep(Inf); N }\nMain()<transacts><suspends>:i64 = Block{ W := Race(Block{ S := Sync(Leaf(1), Leaf(2)); S(0) }, Block{ Sleep(0.1); 3 }); W }\nM:task(i64) = Spawn{ Main() }",
        "E:event(i64) = event(i64){}\nEar(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"e{N}\") }; E.Await() + N }\nMain()<transacts><suspends>:i64 = Block{ P := Sync(Ear(1), Ear(2), Block{ Sleep(0.1); E.Signal(5); 0 }); P(0) + P(1) + Race(Ear(3), Block{ Sleep(-1.0); 4 }) }\nM:task(i64) = Spawn{ Main() }",
        "J()<transacts><suspends>:i64 = Block{ Sleep(1.0); 7 }\nMain()<transacts><suspends>:i64 = Block{ T := Spawn{ J() }; Race(Block{ Defer{ X := Spawn{ Print(\"late\") } }; T.Await() }, Block{ Sleep(0.5); 1 }) + T.Await() }\nM:task(i64) = Spawn{ Main() }",
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

test "arm results are roots: a digest run that reclaims reports as a stored one, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Arm(N:i64, S:float)<transacts><suspends>:i64 = Block{ J := Many(6); Sleep(S); K := Many(6); N + J + K }
        \\Slow()<transacts><suspends>:i64 = Block{ Defer{ X := Many(5) }; Sleep(Inf); 0 }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    P := Sync(Arm(1, 0.1), Arm(2, 0.2), Arm(3, 0.3))
        \\    W := Race(Slow(), Arm(4, 0.1))
        \\    A := Many(8)
        \\    P(0) + P(1) + P(2) + W + A
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

/// Scale test 4 (RFC-0082): a binary tree of `Sync`s `depth` levels deep, its leaves waiting for
/// ever, cancelled from its root when a `Race` beside it resolves. The requests go down the tree
/// on an explicit stack, so the native stack does not grow with it; every leaf's `Defer` runs,
/// and every task of the tree settles cancelled before the `Race` yields. Prints how long each
/// machine and the replay took.
pub fn treeCancel(h: *harness.Harness, depth: u32) !void {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try out.writeAll("var Cleaned:i64 = 0\nN0()<transacts><suspends>:void = Block{ Defer{ set Cleaned = Cleaned + 1 }; Sleep(Inf) }\n");
    for (1..depth + 1) |level| try out.print("N{d}()<transacts><suspends>:void = Block{{ S := Sync(N{d}(), N{d}()); Sleep(Inf) }}\n", .{ level, level - 1, level - 1 });
    try out.print("Main()<transacts><suspends>:i64 = Block{{ W := Race(Block{{ N{d}(); 0 }}, Block{{ Sleep(1.0); 1 }}); W + Cleaned }}\nT:task(i64) = Spawn{{ Main() }}\n", .{depth});
    const p = try h.compile(out.buffered());
    const budget: u64 = 1 << 40;
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("tree cancel failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    const tree = (@as(u64, 1) << @intCast(depth + 1)) - 2;
    try std.testing.expectEqual(tree + 3, actual.ok.scheduler.created);
    try std.testing.expectEqual(@as(u64, 2), actual.ok.scheduler.completed);
    try std.testing.expectEqual(tree + 1, actual.ok.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), actual.ok.scheduler.waiting.len);
    _ = try reporting.validate(actual.ok, false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("a tree of {d} tasks cancelled from its root: reference={d}ms vm={d}ms replay={d}ms\n", .{ tree, referenced, ran - referenced, elapsed(start) - ran });
    var report: [1024]u8 = undefined;
    var written: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&written, actual.ok, false, .{ .work = std.math.maxInt(u64) });
    var expected: [64]u8 = undefined;
    // The winner, 1, and one `Defer` per leaf.
    try std.testing.expect(std.mem.indexOf(u8, written.buffered(), try std.fmt.bufPrint(&expected, "\"result\":{d}", .{1 + (@as(u64, 1) << @intCast(depth))})) != null);
}

test "a tree of tasks cancelled from its root, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    try treeCancel(h, 4);
}

test "Sync, Race and landings in a bundle: each module's arms take words of its own block" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nMain()<transacts><suspends>:i64 = Block{ P := Sync(L.Work(1, 0.5), L.Work(2, 0.25)); W := Race(L.Work(3, 2.0), L.Work(4, 0.1)); P(0) + P(1) + W }\nT:task(i64) = Spawn{ Main() }" },
        .{ .path = "lib.forb", .source = "Work<public>(N:i64, S:float)<transacts><suspends>:i64 = Block{ Defer{ Print(\"w{N}\") }; X := Race(Block{ Sleep(S); N }, Block{ Sleep(Inf); 0 }); X * 10 }" },
    };
    const p = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &files })) {
        .ok => |program| program,
        .failed => |failure| {
            std.debug.print("bundle refused: {t} in {s}\n", .{ failure.diagnostic.code, failure.path });
            return error.TestUnexpectedResult;
        },
    };
    const x = (try h.run(p, concurrency.fuel)).ok;
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("w2\nw1\nw4\nw3\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(u64, 6), x.scheduler.canceled);
}

test "a cancelled waiter in the middle, at the head and at the tail of an event's waiters leaves it whole" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { position: usize, expected: []const u8 }{
        .{ .position = 0, .expected = "gone\nwon 0\nb 5\nc 5\n" },
        .{ .position = 1, .expected = "gone\nwon 0\na 5\nc 5\n" },
        .{ .position = 2, .expected = "gone\nwon 0\na 5\nb 5\n" },
    }) |case| {
        var source: [2048]u8 = undefined;
        const names = [_][]const u8{ "a", "b", "c" };
        var out: std.Io.Writer = .fixed(&source);
        try out.writeAll("E:event(i64) = event(i64){}\nPlain(S:string)<transacts><suspends>:void = Block{ V := E.Await(); Print(\"{S} {V}\") }\nArm()<transacts><suspends>:i64 = Block{ Defer{ Print(\"gone\") }; E.Await() }\n");
        try out.writeAll("Main()<transacts><suspends>:void = Block{\n");
        for (names, 0..) |name, index| {
            if (index == case.position) {
                try out.writeAll("    R := Spawn{ Block{ W := Race(Arm(), Block{ Sleep(0.5); 0 }); Print(\"won {W}\") } }\n");
            } else try out.print("    T{d} := Spawn{{ Plain(\"{s}\") }}\n", .{ index, name });
        }
        try out.writeAll("    Sleep(1.0)\n    E.Signal(5)\n}\nM:task(void) = Spawn{ Main() }\n");
        _ = try expectPrinted(h, out.buffered(), case.expected);
    }
}

test "a Race won while a loser is ready with a value: the loser yields cancelled, not the value" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\E:event(i64) = event(i64){}
        \\Ear()<transacts><suspends>:i64 = Block{ Defer{ Print("ear gone") }; V := E.Await(); Print("ear {V}"); V }
        \\Both()<transacts><suspends>:i64 = Block{ E.Signal(7); Sleep(0.0); 9 }
        \\Main()<transacts><suspends>:void = Block{ W := Race(Ear(), Block{ Sleep(-1.0); E.Signal(3); 4 }); Print("won {W}") }
        \\M:task(void) = Spawn{ Main() }
    , "ear gone\nwon 4\n");
}

test "review: programs with no Sync or Race keep their meaning, their IR and their capacities" {
    const h = try harness.create();
    defer scratch.release(h);
    // A parameter called `Race` or `Sync` is called, with an exit in its argument and a `Defer` open.
    var x = try h.execute("var Log:[]string = array{}\nF(Race:function<transacts>(tuple(i64),i64), N:i64)<transacts>:i64 = Block{ Defer{ set Log = Log + array{\"outer\"} }; X := Race(If(N > 2, Return(N * 100), N)); X + 1 }\nG(N:i64)<transacts>:i64 = N * 2\nA:i64 = F(G, 1)\nB:i64 = F(G, 5)");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 500), x.get("B").?.integer);
    x = try h.execute("var Log:[]string = array{}\nF(Sync:function<transacts>(tuple(i64),i64), Xs:[]i64)<transacts>:i64 = Block{ var S:i64 = 0; Loop{ Defer{ set Log = Log + array{\"it\"} }; set S = S + Sync(If(S > 5, Break(), 3)) }; S }\nG(N:i64)<transacts>:i64 = N * 2\nA:i64 = F(G, array{1})");
    try std.testing.expectEqual(@as(i64, 6), x.get("A").?.integer);
    // Without a `Sync` or `Race` no task can be cancelled: a `Defer` open at a site gets no
    // landing, so it may assign a local and read more names than a function takes parameters,
    // and the program compiles once, to the IR it had.
    const plain = "F()<transacts><suspends>:i64 = Block{ var N:i64 = 0; Defer{ set N = 1 }; Sleep(1.0); N }\nT:task(i64) = Spawn{ F() }";
    _ = try expectRun(h, plain);
    const p = try h.compile(plain);
    try std.testing.expectEqual(@as(usize, 2), p.functions.len);
    for (p.function_nodes) |entry| try std.testing.expect(entry.input != .operation or entry.node.kind != .invoke);
    var source: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&source);
    try out.writeAll("F()<transacts><suspends>:i64 = Block{ ");
    for (0..20) |index| try out.print("L{d} := {d}; ", .{ index, index });
    try out.writeAll("Defer{ Print(\"sum {L0");
    for (1..20) |index| try out.print(" + L{d}", .{index});
    try out.writeAll("}\") }; Sleep(0.1); 1 }\nT:task(i64) = Spawn{ F() }");
    _ = try expectPrinted(h, out.buffered(), "sum 190\n");
}
