//! Cancelling reactions, P4.7 (RFC-0084, N6): `T.Cancel()` of an `Upon` or a `When`. A reaction
//! waiting on its guard settles cancelled at once and its dependencies go; one firing (asked by a
//! task its body handed off to) finishes its body, after which an `Upon` completes and a `When`
//! settles cancelled; one whose start is still queued in a drain never starts. Each test runs both
//! machines, the report replay, and every trace mode.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const trace_replay = @import("trace_replay.zig");
const reporting = @import("value_report.zig");
test {
    _ = @import("reaction_cancel_forgery_tests.zig");
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}
fn expectInReport(execution: evaluator.Execution, needle: []const u8) !void {
    var buffer: [16384]u8 = undefined;
    const report = try live.report(execution, &buffer);
    if (std.mem.indexOf(u8, report, needle) == null) {
        std.debug.print("report {s} lacks {s}\n", .{ report, needle });
        return error.TestUnexpectedResult;
    }
}
fn expectCounts(x: evaluator.Execution, created: u64, completed: u64, canceled: u64) !void {
    try std.testing.expectEqual(created, x.scheduler.created);
    try std.testing.expectEqual(completed, x.scheduler.completed);
    try std.testing.expectEqual(canceled, x.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

/// The Book's 15:532 over module cells (its locals are refused, Q1), the cancel made by a
/// spawned task, which runs by hand-off at once.
const book =
    \\var X:i64 = 0
    \\var Y:i64 = 0
    \\Watch:task(i64) = Upon(X > 5, Set(Y, X))
    \\StopObserving()<transacts><suspends>:void = Watch.Cancel()
    \\S:task(void) = Spawn{ StopObserving() }
    \\set X = 10
    \\Seen:i64 = Y
;

test "Book 15:532: Watch.Cancel() from a spawned task, then a write, leaves Y at 0" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, book);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "Seen"));
    try expectInReport(x, "\"X\":10,\"Y\":0,\"Watch\":{\"$task\":{\"sequence\":1,\"state\":\"canceled\"}}");
    // "Canceling a task immediately removes all dependency tracking" (15:544): the write of 10
    // notified nothing, and the reaction's one entry went with it.
    try std.testing.expectEqual(@as(u64, 1), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 0), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 0), x.live.firings);
    try expectCounts(x, 2, 1, 1);
    try live.expectEveryMode(book);
    // Without the cancel the reaction fires at the write (the Book's `Y = X` once `X > 5`).
    const kept = try live.run(h,
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\Watch:task(i64) = Upon(X > 5, Set(Y, X))
        \\set X = 10
        \\Seen:i64 = Y
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(kept, "Seen"));
}

test "a When cancelled while it waits fires no more, and the tasks awaiting it are cancelled" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\W:task(void) = When(X > 0, Set(Log, Log + "w{X}"))
        \\Waiter()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "d") }; W.Await(); Set(Log, Log + "never") }
        \\A:task(void) = Spawn{ Waiter() }
        \\set X = 1
        \\Stop()<transacts><suspends>:void = Block{ W.Cancel(); Set(Log, Log + "c"); W.Cancel() }
        \\S:task(void) = Spawn{ Stop() }
        \\set X = 2
        \\Late()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "l") }; W.Await(); Set(Log, Log + "never") }
        \\B:task(void) = Spawn{ Late() }
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The awaiter is asked at the cancel and unwinds when it runs, after the root; a task that
    // awaits the cancelled handle later is cancelled at its `Await` (RFC-0082 Q3), at once.
    try std.testing.expectEqualStrings("w1cl", x.get("L").?.string);
    try expectInReport(x, "\"Log\":\"w1cld\"");
    // Created, fired by the write of 1, registered again; never evaluated after the cancel.
    try std.testing.expectEqual(@as(u64, 3), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 1), x.live.firings);
    try expectCounts(x, 4, 1, 3);
    try live.expectEveryMode(source);
}

test "cancelling a firing When from a task its body spawned: the body ends, and it settles cancelled" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\var H:[]task(void) = array{}
        \\Stopper()<transacts><suspends>:void = Block{ If(T := H[0], T.Cancel(), void(0)); Set(Log, Log + "c") }
        \\Stop()<transacts>:i64 = Block{ T:task(void) = Spawn{ Stopper() }; Set(Log, Log + "s"); 0 }
        \\Watch:task(void) = When(X > 0, Block{ Set(Log, Log + "w{X}"); If(X > 1, Stop(), 0) })
        \\Waiter()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "d") }; Watch.Await(); Set(Log, Log + "never") }
        \\A:task(void) = Spawn{ Waiter() }
        \\set H = array{Watch}
        \\set X = 1
        \\set X = 2
        \\set X = 3
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The request only flags it; the body goes on to its end, then the When does not register
    // again (N4 step 3), so the write of 3 fires nothing.
    try std.testing.expectEqualStrings("w1w2cs", x.get("L").?.string);
    try expectInReport(x, "\"Log\":\"w1w2csd\"");
    try expectInReport(x, "\"Watch\":{\"$task\":{\"sequence\":1,\"state\":\"canceled\"}}");
    // Created, at each of the two deliveries, and after the first firing but not the second.
    try std.testing.expectEqual(@as(u64, 4), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 2), x.live.firings);
    try std.testing.expectEqual(@as(u64, 2), x.live.deliveries);
    try expectCounts(x, 3, 1, 2);
    try live.expectEveryMode(source);
    // The firing When's settle step has no result, as a cancelled task's.
    var settled = false;
    for (x.call_steps) |step| if (step.kind == .settle and step.value == .boolean and !step.value.boolean) {
        settled = true;
    };
    try std.testing.expect(settled);
}

test "an Upon asked while it fires completes with its body's result, and its awaiter gets it" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\var H:[]task(i64) = array{}
        \\Stopper()<transacts><suspends>:void = Block{ If(T := H[0], T.Cancel(), void(0)); Set(Log, Log + "c") }
        \\Stop()<transacts>:i64 = Block{ T:task(void) = Spawn{ Stopper() }; 7 }
        \\U:task(i64) = Upon(X > 0, Block{ Set(Log, Log + "u"); Stop() * X })
        \\Waiter()<transacts><suspends>:void = Block{ V := U.Await(); Set(Log, Log + "got {V}") }
        \\A:task(void) = Spawn{ Waiter() }
        \\set H = array{U}
        \\set X = 3
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"ucgot 21\"");
    try expectInReport(x, "\"U\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":21}}");
    try expectCounts(x, 3, 3, 0);
    try live.expectEveryMode(source);
}

test "an Upon cancelled while its start is queued never starts, and awaiting it cancels the awaiter" {
    // `First` starts earlier in the drain of the commit and reaches the `Upon` through a cell.
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\var H:[]task(string) = array{}
        \\Late()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "d") }; If(T := H[0], T.Await(), ""); Set(Log, Log + "never") }
        \\First()<transacts><suspends>:void = Block{ Set(Log, Log + "f"); If(T := H[0], T.Cancel(), void(0)); Set(Log, Log + "c") }
        \\Main()<transacts><suspends>:void = Block{
        \\    Attempt(Block{ A := Spawn{ First() }; U := Upon(X >= 0, Set(Log, Log + "u")); set H = array{U}; 0 }, 1)
        \\    Set(Log, Log + "m")
        \\    V := Spawn{ Late() }
        \\    Set(Log, Log + "e")
        \\}
        \\M:task(void) = Spawn{ Main() }
        \\set X = 1
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // Its guard, which holds, is never evaluated: it never fired, and nothing depends on X.
    try expectInReport(x, "\"Log\":\"fcmde\"");
    try std.testing.expectEqual(@as(u64, 0), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 0), x.live.entries);
    // Made and cancelled, it counts as created (C73): Main, First, the Upon and Late.
    try expectCounts(x, 4, 2, 2);
    try live.expectEveryMode(source);
}

test "a reaction cancelled while a notification for it is pending is delivered nothing, and keeps its slot until then" {
    // One write notifies A and B. A fires first; its body hands off to a task that cancels B,
    // still pending, and makes a new When, which must not take B's slot: the delivery to B that
    // follows would reach it (C74).
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\var H:[]task(void) = array{}
        \\Stopper()<transacts><suspends>:void = Block{ If(T := H[0], T.Cancel(), void(0)); N:task(void) = When(X > 0, Set(Log, Log + "n")); Set(Log, Log + "c") }
        \\Stop()<transacts>:i64 = Block{ T:task(void) = Spawn{ Stopper() }; 0 }
        \\A:task(void) = When(X > 0, Block{ Set(Log, Log + "a{X}"); If(X > 1, Stop(), 0) })
        \\B:task(void) = When(X > 0, Set(Log, Log + "b{X}"))
        \\set H = array{B}
        \\set X = 1
        \\set X = 2
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The new When fires at once when it is made, inside the firing of A; B gets nothing.
    try std.testing.expectEqualStrings("a1b1a2nc", x.get("L").?.string);
    // A and B made, delivered and registered again at the write of 1; at the write of 2 A is
    // delivered, the new When is made, fires and registers again inside A's firing, A registers
    // again, and B is not evaluated.
    try std.testing.expectEqual(@as(u64, 10), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 4), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a reaction's own guard and body may not cancel it, and Cancel of a settled reaction does nothing" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Cancel` is a site: a body or a guard cannot hold one.
    try live.expectRefused(h,
        \\var X:i64 = 0
        \\Stop(T:task(void))<transacts><suspends>:void = T.Cancel()
        \\F()<transacts>:task(void) = When(X > 0, Stop(F()))
    , .reaction_body_suspends, "Stop");
    // An Upon that fired has settled: asking it costs a unit and does nothing.
    const x = try live.run(h,
        \\var X:i64 = 1
        \\var N:i64 = 0
        \\U:task(i64) = Upon(X > 0, Set(N, N + 1))
        \\Stop()<transacts><suspends>:void = Block{ U.Cancel(); U.Cancel(); Set(N, N + 10) }
        \\T:task(void) = Spawn{ Stop() }
    );
    try expectInReport(x, "\"N\":11");
    try expectCounts(x, 2, 2, 0);
}

const swept =
    \\var X:i64 = 0
    \\var Log:string = ""
    \\var H:[]task(void) = array{}
    \\Stopper()<transacts><suspends>:void = Block{ If(T := H[0], T.Cancel(), void(0)); If(T := H[1], T.Cancel(), void(0)); Set(Log, Log + "c") }
    \\Stop()<transacts>:i64 = Block{ T:task(void) = Spawn{ Stopper() }; 0 }
    \\A:task(void) = When(X > 0, Block{ Set(Log, Log + "a"); If(X > 1, Stop(), 0) })
    \\B:task(void) = When(X > 0, Set(Log, Log + "b"))
    \\U:task(string) = Upon(X > 5, Set(Log, Log + "u"))
    \\set H = array{A, B}
    \\Waiter()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "d") }; If(T := H[1], T.Await(), void(0)) }
    \\W:task(void) = Spawn{ Waiter() }
    \\set X = 1
    \\set X = 2
    \\Kill()<transacts><suspends>:void = Block{ U.Cancel(); Sleep(0.0); set X = 9; X }
    \\K:task(void) = Spawn{ Kill() }
;

test "cancelling reactions: every fuel budget stops both machines at the same node" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(swept);
    const full = (try h.run(p, live.fuel)).ok;
    try expectInReport(full, "\"Log\":\"abacd\"");
    var budget: u64 = 1;
    var stopped: u64 = 0;
    while (budget < 4000) : (budget += 1) {
        const outcome = try h.run(p, budget);
        if (outcome == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
        stopped += 1;
    }
    try std.testing.expect(stopped > 100 and budget < 4000);
    try live.expectEveryMode(swept);
}

/// The steps of `kind` in `steps`, by index.
fn stepsOf(steps: []const types.CallStep, kind: @FieldType(types.CallStep, "kind"), out: []usize) usize {
    var count: usize = 0;
    for (steps, 0..) |step, index| if (step.kind == kind) {
        out[count] = index;
        count += 1;
    };
    return count;
}
/// The run with the step at `at` left out, or with `step` put before it.
fn edited(x: evaluator.Execution, at: usize, step: ?types.CallStep) !evaluator.Execution {
    const allocator = std.testing.allocator;
    const steps = try allocator.alloc(types.CallStep, if (step == null) x.call_steps.len - 1 else x.call_steps.len + 1);
    @memcpy(steps[0..at], x.call_steps[0..at]);
    if (step) |inserted| {
        steps[at] = inserted;
        @memcpy(steps[at + 1 ..], x.call_steps[at..]);
    } else @memcpy(steps[at..], x.call_steps[at + 1 ..]);
    var forged = x;
    forged.call_steps = steps;
    return forged;
}
fn expectForged(x: evaluator.Execution, at: usize, step: ?types.CallStep) !void {
    const forged = try edited(x, at, step);
    defer std.testing.allocator.free(forged.call_steps);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
}

test "the replay refuses forged schedules of cancelled reactions" {
    const h = try harness.create();
    defer scratch.release(h);
    // A waiting reaction cancelled: no write reaches it again.
    const book_run = try live.run(h, book);
    _ = try reporting.validate(book_run, false, .{});
    var found: [16]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), stepsOf(book_run.call_steps, .observe, &found));
    const observed = book_run.call_steps[found[0]];
    // A delivery to it, and a firing of it, after the write of 10: the run's last steps.
    const last = book_run.call_steps.len;
    try expectForged(book_run, last, .{ .function = 0, .pc = 0, .value = observed.value, .kind = .deliver });
    try expectForged(book_run, last, .{ .function = observed.function, .pc = 0, .value = observed.value, .kind = .observe });
    // The run's record says it was not cancelled, or never made.
    var record = book_run;
    record.scheduler.canceled -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    record = book_run;
    record.scheduler.created -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    record = book_run;
    record.live.entries += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));

    // A When cancelled while it fired, and one cancelled while a notification for it was
    // pending (the program of the fuel sweep).
    const x = try live.run(h, swept);
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    var forged = x;
    forged.call_steps = steps;
    _ = try reporting.validate(forged, false, .{});
    // The one `settle` with no result of a reaction's body: A's, at the end of its second
    // firing (the bodies are the functions of the `fire` steps).
    var settles: [16]usize = undefined;
    const settle_count = stepsOf(steps, .settle, &settles);
    var fires: [16]usize = undefined;
    const fire_count = stepsOf(steps, .fire, &fires);
    var canceled: ?usize = null;
    for (settles[0..settle_count]) |index| {
        const step = steps[index];
        if (step.value != .boolean or step.value.boolean) continue;
        for (fires[0..fire_count]) |fire| if (steps[fire].function == step.function) {
            canceled = index;
        };
    }
    const at = canceled orelse return error.TestUnexpectedResult;
    const settled = steps[at];
    // That it completed; that its body was another; that it registered again instead.
    steps[at].value = .{ .boolean = true };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[at] = settled;
    steps[at].kind = .observe;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[at] = settled;
    try expectForged(forged, at, null);
    // B was notified by the write of 2 and cancelled before its turn: its delivery is in the run,
    // and does nothing. Leaving it out, or making it evaluate B's guard, is refused.
    var delivers: [16]usize = undefined;
    const deliver_count = stepsOf(steps, .deliver, &delivers);
    // The deliveries of the write of 1 are A's, then B's.
    const b_sequence = steps[delivers[1]].value;
    var empty: ?usize = null;
    for (delivers[0..deliver_count]) |index| {
        if (!std.meta.eql(steps[index].value, b_sequence)) continue;
        if (index + 1 < steps.len and steps[index + 1].kind == .observe) continue;
        empty = index;
    }
    const nothing = empty orelse return error.TestUnexpectedResult;
    try expectForged(forged, nothing, null);
    var guard: ?types.CallStep = null;
    for (steps[0..nothing]) |step| if (step.kind == .observe and std.meta.eql(step.value, b_sequence)) {
        guard = step;
    };
    try expectForged(forged, nothing + 1, guard.?);
    // Nothing is pending at the end: a delivery to A there is refused.
    try expectForged(forged, steps.len, .{ .function = 0, .pc = 0, .value = steps[delivers[0]].value, .kind = .deliver });
    _ = try reporting.validate(forged, false, .{});
}

test "a cancelled reaction's captures are released with it, and a reclamation keeps those of one still waiting" {
    const source =
        \\var X:i64 = 0
        \\var Sum:i64 = 0
        \\Make(K:i64)<transacts>:task(void) = Block{ Steps:[]i64 = array{K, K + 1, K + 2}; When(X > Steps[0], Set(Sum, Sum + Steps.Length + X)) }
        \\A:task(void) = Make(5)
        \\B:task(void) = Make(1)
        \\Bump(K:i64)<transacts>:i64 = Block{ T:[]i64 = array{K, K, K, K, K, K, K, K}; set X = K; K + T.Length - 7 }
        \\Driver()<transacts><suspends>:void = Block{ B.Cancel(); Sleep(1.0); I := Iterate(Bump, 8, 0); A.Cancel(); set X = 100; I }
        \\D:task(void) = Spawn{ Driver() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // A fires at each write above 5 (6 and 7) and adds 3 + X; B never fires.
    try expectInReport(x, "\"Sum\":19");
    try std.testing.expect(try live.everyMode(source) > 0);
}

/// The scale test of cancelling reactions: `count` Whens on one cell, linked in a list; one
/// write notifies them all, and the first to fire hands off to a task that walks the list and
/// cancels every one, itself (firing) and all the others (pending). Each later delivery does
/// nothing, and a second write notifies none.
pub fn cancelScale(f: trace_replay.Fixture, count: usize) !evaluator.Execution {
    var source_text: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_text,
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\link := class{{ W:task(void); Next:option(link) }}
        \\var Head:option(link) = option{{}}
        \\Kill()<transacts><suspends>:void = Block{{
        \\    var P:option(link) = Head
        \\    var Going:logic = true
        \\    While(Going, Block{{ If(L := P?, Block{{ L.W.Cancel(); set P = L.Next; 0 }}, Block{{ set Going = false; 0 }}) }})
        \\}}
        \\Watch()<transacts>:task(void) = When(X > 0, Block{{ Set(N, N + 1); If(N == 1, Block{{ S:task(void) = Spawn{{ Kill() }}; 0 }}, 0) }})
        \\Push(P:option(link))<transacts>:option(link) = option{{link{{W := Watch(), Next := P}}}}
        \\set Head = Iterate(Push, {d}, option{{}})
        \\set X = 1
        \\set X = 2
    , .{count});
    const x = try @import("live_field_tests.zig").timed(f, "Whens cancelled while notified", source);
    try std.testing.expectEqual(@as(i64, 1), x.cells[1].value.integer);
    try std.testing.expectEqual(@as(u64, count), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 1), x.live.firings);
    try std.testing.expectEqual(@as(u64, count + 1), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, count), x.scheduler.canceled);
    try std.testing.expectEqual(@as(u64, count + 1), x.scheduler.created);
    return x;
}

test "the scale test of cancelling reactions at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    // The bootstrap profile runs 64 tasks at once: 63 Whens and the task that cancels them.
    _ = try cancelScale(f, 63);
}
