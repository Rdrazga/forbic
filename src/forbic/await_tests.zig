//! `Await(G)`, P4.6 (RFC-0084, N7): a site that evaluates its guard with tracking, continues when
//! it holds, and otherwise makes its task wait on what the guard read, until a write notifies
//! it, the task is woken to the ready queue (S4) and evaluates its guard again at the same site.
//! Each test runs both machines, the report replay, and every trace mode.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const trace_replay = @import("trace_replay.zig");
const reporting = @import("value_report.zig");
test {
    _ = @import("await_forgery_tests.zig");
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}
fn text(execution: evaluator.Execution, name: []const u8) ![]const u8 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.string;
}
fn expectInReport(execution: evaluator.Execution, needle: []const u8) !void {
    var buffer: [16384]u8 = undefined;
    const report = try live.report(execution, &buffer);
    if (std.mem.indexOf(u8, report, needle) == null) {
        std.debug.print("report {s} lacks {s}\n", .{ report, needle });
        return error.TestUnexpectedResult;
    }
}

test "Book 15:419: an Await suspends until its guard holds, and the task goes on once it runs" {
    // The task is woken by the write of 11 and runs when the scheduler reaches it, after the
    // root (Q2): `B` still reads 0, and the final state has 22.
    const source =
        \\gauge := class{ var Level:i64 = 0 }
        \\DoubleWhenFull(Source:gauge, Target:gauge)<transacts><suspends>:void = Block{
        \\    Await(Source.Level > 10)
        \\    set Target.Level = Source.Level * 2
        \\    Target.Level
        \\}
        \\S:gauge = gauge{}
        \\T:gauge = gauge{}
        \\W:task(void) = Spawn{ DoubleWhenFull(S, T) }
        \\set S.Level = 5
        \\A:i64 = T.Level
        \\set S.Level = 11
        \\B:i64 = T.Level
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    try expectInReport(x, "{\"id\":2,\"class\":\"gauge\",\"fields\":{\"Level\":22}}");
    // Arriving, and when it runs after the write of 5 woke it: by then the level is 11. The
    // write of 11 notified nothing, as the woken task no longer waited on its guard (Q2).
    try std.testing.expectEqual(@as(u64, 2), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.completed);
    try live.expectEveryMode(source);
}

test "an Await whose guard holds goes on at once and yields the guard's value" {
    const source =
        \\var Items:[]i64 = array{4, 5}
        \\var Log:string = ""
        \\First()<transacts><suspends>:i64 = Await(Items[1] * 10)
        \\Main()<transacts><suspends>:void = Block{
        \\    V := First()
        \\    Set(Log, "{V}")
        \\}
        \\T:task(void) = Spawn{ Main() }
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("50", try text(x, "L"));
    // The task never suspended: a start, and its settle.
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 1), x.live.entries);
    try std.testing.expectEqual(@as(u64, 0), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "an Await woken while its guard has stopped holding waits again" {
    // The write of 20 wakes the task; the write of 0 comes before it runs, so its guard fails
    // where it stands and it waits again, now notified by the write of 30.
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Waiter()<transacts><suspends>:void = Block{
        \\    V := Await(Block{ Require[X > 10]; X * 2 })
        \\    Set(Log, Log + "got {V};")
        \\}
        \\Writer()<transacts><suspends>:void = Block{ Sleep(1.0); set X = 30; X }
        \\W:task(void) = Spawn{ Waiter() }
        \\set X = 20
        \\set X = 0
        \\K:task(void) = Spawn{ Writer() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"got 60;\"");
    // Arriving, woken by 20 and failing on 0, woken by 30 and holding.
    try std.testing.expectEqual(@as(u64, 3), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, 2), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.completed);
    try live.expectEveryMode(source);
    // Without the later write the task is left waiting on its guard at the `Await`.
    const left = try live.run(h,
        \\var X:i64 = 0
        \\Waiter()<transacts><suspends>:void = Block{ Await(X > 10); X }
        \\W:task(void) = Spawn{ Waiter() }
        \\set X = 20
        \\set X = 0
    );
    const at = std.mem.indexOf(u8, left.program.source, "Await").?;
    var needle: [128]u8 = undefined;
    try expectInReport(left, try std.fmt.bufPrint(&needle, "\"waiting\":[{{\"task\":1,\"kind\":\"spawn\",\"wait\":\"guard\",\"span\":[{d},{d}]}}]", .{ at, at + 5 }));
}

test "awaiters are woken in the order their entries were made, behind what is ready already" {
    // Three tasks wait on X; a Sleep(0.0) makes a fourth ready first. One write wakes the
    // three in the order they began to wait, and each appends its letter when it runs.
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Wait(K:string)<transacts><suspends>:void = Block{ Await(X > 0); Set(Log, Log + K) }
        \\Tick()<transacts><suspends>:void = Block{ Sleep(0.0); Set(Log, Log + "t") }
        \\A:task(void) = Spawn{ Wait("a") }
        \\B:task(void) = Spawn{ Wait("b") }
        \\C:task(void) = Spawn{ Wait("c") }
        \\Main()<transacts><suspends>:void = Block{ Sleep(0.0); set X = 1; Set(Log, Log + "m") }
        \\M:task(void) = Spawn{ Main() }
        \\D:task(void) = Spawn{ Tick() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"mtabc\"");
    try std.testing.expectEqual(@as(u64, 3), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a write in a region wakes an awaiter when the region commits, and one that fails wakes none" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Wait()<transacts><suspends>:void = Block{ Await(X > 0); Set(Log, Log + "woke {X};") }
        \\W:task(void) = Spawn{ Wait() }
        \\F:logic = Attempt(Block{ set X = 5; Require[X < 0]; true }, false)
        \\G:logic = Attempt(Block{ set X = 7; set X = 8; true }, false)
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"woke 8;\"");
    // The failed region notified nothing; the committed one notified once, delivered once.
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a commit in a task's frame that begins a drain wakes an awaiter when the drain ends (C68)" {
    // Main's region writes X and holds a start; its commit drains the start, which sleeps and
    // writes nothing; the drain's end is the delivery point that wakes the awaiter. Nothing is
    // written after it, so without that delivery the awaiter would be left waiting.
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Wait()<transacts><suspends>:void = Block{ Await(X > 0); Set(Log, Log + "w") }
        \\Main()<transacts><suspends>:logic = Block{ R := Attempt(Block{ set X = 1; S:task(void) = Spawn{ Sleep(1.0) }; true }, false); R }
        \\W:task(void) = Spawn{ Wait() }
        \\M:task(logic) = Spawn{ Main() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"w\"");
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "an Await inside a loop waits at each visit, and a When and an awaiter share a write" {
    const source =
        \\var X:i64 = 0
        \\var Seen:i64 = 0
        \\var Log:string = ""
        \\Count()<transacts><suspends>:void = Block{
        \\    var N:i64 = 0
        \\    While(N < 3, Block{ M := N; Await(X > M); set N = N + 1; Set(Log, Log + "c{N}") })
        \\}
        \\Watch:task(void) = When(X, Set(Seen, Seen + 1))
        \\T:task(void) = Spawn{ Count() }
        \\Bump()<transacts><suspends>:void = Block{ Sleep(1.0); set X = 1; Sleep(1.0); set X = 3; Log }
        \\B:task(void) = Spawn{ Bump() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // X = 1 lets the first visit go on; X = 3 the second and, at once, the third.
    try expectInReport(x, "\"Log\":\"c1c2c3\"");
    try expectInReport(x, "\"Seen\":3");
    try live.expectEveryMode(source);
}

test "a task waiting at an Await can be cancelled: its entries go, its Defer runs, it settles cancelled" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Waiter()<transacts><suspends>:void = Block{
        \\    Defer{ Set(Log, Log + "defer;") }
        \\    Await(X > 10)
        \\    Set(Log, Log + "after;")
        \\}
        \\Killer(T:task(void))<transacts><suspends>:void = Block{ Sleep(1.0); T.Cancel(); set X = 50; X }
        \\W:task(void) = Spawn{ Waiter() }
        \\K:task(void) = Spawn{ Killer(W) }
        \\set X = 1
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"defer;\"");
    try expectInReport(x, "\"W\":{\"$task\":{\"sequence\":1,\"state\":\"canceled\"}}");
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.canceled);
    // The write of 1 is delivered; the write of 50, after the request, notifies nothing.
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a task woken at an Await and asked to cancel before it runs yields cancelled" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Waiter()<transacts><suspends>:void = Block{
        \\    Defer{ Set(Log, Log + "defer;") }
        \\    Await(X > 10)
        \\    Set(Log, Log + "after;")
        \\}
        \\Killer(T:task(void))<transacts><suspends>:void = Block{ Sleep(1.0); set X = 50; T.Cancel(); X }
        \\W:task(void) = Spawn{ Waiter() }
        \\K:task(void) = Spawn{ Killer(W) }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"defer;\"");
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 1), x.live.evaluations);
    try live.expectEveryMode(source);
}

test "an awaiter of a cancelled waiter is cancelled, and a Race arm waiting at an Await is a loser" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Waiter()<transacts><suspends>:i64 = Block{ Await(X > 10); X }
        \\Race2()<transacts><suspends>:void = Block{
        \\    R := Race(Block{ Defer{ Set(Log, Log + "lost;") }; Await(X > 100); 1 }, Block{ Sleep(1.0); 2 })
        \\    Set(Log, Log + "won {R};")
        \\}
        \\Awaiter(T:task(i64))<transacts><suspends>:void = Block{ V := T.Await(); Set(Log, Log + "never;") }
        \\Killer(T:task(i64))<transacts><suspends>:void = Block{ Sleep(2.0); T.Cancel(); Log }
        \\W:task(i64) = Spawn{ Waiter() }
        \\A:task(void) = Spawn{ Awaiter(W) }
        \\C:task(void) = Spawn{ Killer(W) }
        \\R:task(void) = Spawn{ Race2() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Log\":\"lost;won 2;\"");
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.canceled);
    try live.expectEveryMode(source);
}

test "the diagnostics of Await, each where it is written" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .source = "var X:i64 = 0\nV:logic = Await(X > 0)", .code = .call_requires_suspends, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts>:logic = Await(X > 0)", .code = .call_requires_suspends, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<writes><suspends>:logic = Await(X > 0)", .code = .call_requires_reads, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:logic = Attempt(Await(X > 0), false)", .code = .suspends_in_failure_context, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:i64 = Block{ Defer{ Await(X > 0) }; 1 }", .code = .suspends_in_failure_context, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:void = Block{ W:task(void) = When(X, Await(X > 0)); }", .code = .reaction_body_suspends, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:logic = Await(Set(X, 1) > 0)", .code = .guard_effect, .at = "X" },
        .{ .source = "c:=class{}\nF()<transacts><suspends>:c = Await(c{})", .code = .guard_effect, .at = "c" },
        .{ .source = "F()<transacts><suspends>:i64 = Await(Print(\"x\"))", .code = .guard_effect, .at = "Print" },
        .{ .source = "F()<transacts><suspends>:void = Await(Sleep(1.0))", .code = .guard_effect, .at = "Sleep" },
        // RFC-0085, I14: a guard that names a local `var` shares it (S1b), and may not write it.
        .{ .source = "F()<transacts><suspends>:i64 = Block{ var L:i64 = 0; Await(Set(L, 1) > 0); 1 }", .code = .guard_effect, .at = "L" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Await(Return(1)); 1 }", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Loop{ Await(Break()) }; 1 }", .code = .return_in_task_body, .at = "Break" },
        .{ .source = "F()<transacts><suspends>:logic = Await()", .code = .argument_count, .at = "Await" },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:logic = Await(X > 0, X > 1)", .code = .argument_count, .at = "," },
        .{ .source = "var X:i64 = 0\nF()<transacts><suspends>:i64 = Await(X > 0)", .code = .type_mismatch, .at = "Await" },
    };
    for (cases) |case| try live.expectRefused(h, case.source, case.code, case.at);
}

test "Await yields to what the program declares by its name, and a handle's Await keeps its meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    const function = try live.run(h, "Await(X:i64)<computes>:i64 = X + 1\nV:i64 = Await(3)");
    try std.testing.expectEqual(@as(i64, 4), try integer(function, "V"));
    const parameter = try live.run(h, "F(Await:i64)<computes>:i64 = Await + 1\nV:i64 = F(2)");
    try std.testing.expectEqual(@as(i64, 3), try integer(parameter, "V"));
    const binding = try live.run(h, "var Await:i64 = 5\nset Await = 6\nV:i64 = Await");
    try std.testing.expectEqual(@as(i64, 6), try integer(binding, "V"));
    const method = try live.run(h, "c:=class{ Await(X:i64)<computes>:i64 = X * 2 }\nO:c = c{}\nV:i64 = O.Await(4)");
    try std.testing.expectEqual(@as(i64, 8), try integer(method, "V"));
    // A handle's `Await()` and the form in one program.
    const both = try live.run(h,
        \\var X:i64 = 0
        \\Get()<transacts><suspends>:i64 = Block{ Await(X > 1); X }
        \\T:task(i64) = Spawn{ Get() }
        \\U:task(i64) = Spawn{ Block{ V := T.Await(); V + 1 } }
        \\set X = 2
    );
    try expectInReport(both, "\"U\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":3}}");
    // A program whose only `Await` is a handle's is not live: no `$live`, and the IR it had.
    const handle = try live.run(h, "T:task(i64) = Spawn{ 1 }\nU:task(i64) = Spawn{ T.Await() }");
    try std.testing.expect(!evaluator.live(handle.program));
}

test "review D1 and D2: an Await a program declares keeps its exits' rules, nested in a module of a bundle too" {
    const h = try harness.create();
    defer scratch.release(h);
    // A call of the program's own `Await` is no guard: a `Return` cannot be its argument.
    try live.expectRefused(h, "Await(X:i64)<computes>:i64 = X + 1\nF()<computes>:i64 = Await(Return(5))\nV:i64 = F()", .return_not_tail, "Return");
    // An `Await` declared in a module of another file, reached by `using`, is a call; a `Break`
    // in its argument leaves the loop around it, as before P4.6.
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L.Kit}\nF()<computes>:i64=Block{ Loop{ Q:=Await(Break()) }; 1 }\nV:i64=F()\n" },
        .{ .path = "lib.forb", .source = "Kit<public>:=module{Await<public>(X:i64)<computes>:i64=X+1\nOther<public>:i64=1}\n" },
    };
    const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (result != .ok) return error.TestUnexpectedResult;
    const x = (try h.run(result.ok, 1 << 20)).ok;
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "V"));
}

test "Await: every fuel budget stops both machines at the same node" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Waiter()<transacts><suspends>:void = Block{ Defer{ Set(Log, Log + "d") }; V := Await(Block{ Require[X > 1]; X }); Set(Log, Log + "{V}") }
        \\Writer()<transacts><suspends>:void = Block{ Sleep(0.0); set X = 2; set X = 0; Sleep(0.0); set X = 3; X }
        \\W:task(void) = Spawn{ Waiter() }
        \\K:task(void) = Spawn{ Writer() }
        \\set X = 1
    ;
    const p = try h.compile(source);
    _ = (try h.run(p, live.fuel)).ok;
    var budget: u64 = 1;
    var stopped: u64 = 0;
    while (budget < 2000) : (budget += 1) {
        const outcome = try h.run(p, budget);
        if (outcome == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
        stopped += 1;
    }
    try std.testing.expect(stopped > 60 and budget < 2000);
}

test "Await: a reclamation keeps what a waiting guard captures, in every mode" {
    // RFC-0082 C73: the guard of a task waiting at an `Await` is in the site's operand register,
    // which a reclamation across stacks roots with the other registers of saved frames. The
    // guard captures `Limit` and an array; other tasks' frames reclaim while it waits.
    const source =
        \\var X:i64 = 0
        \\var Sum:i64 = 0
        \\Waiter(Limit:i64)<transacts><suspends>:void = Block{
        \\    Steps:[]i64 = array{Limit, Limit + 1, Limit + 2}
        \\    Await(X > Steps[2])
        \\    Set(Sum, Sum + X + Steps.Length)
        \\}
        \\Bump(K:i64)<transacts>:i64 = Block{ T:[]i64 = array{K, K, K, K, K, K, K, K}; set X = K; K + T.Length - 7 }
        \\Driver()<transacts><suspends>:void = Block{ Sleep(1.0); A := Iterate(Bump, 40, 0); Sleep(1.0); A }
        \\W:task(void) = Spawn{ Waiter(30) }
        \\D:task(void) = Spawn{ Driver() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The first write wakes the task; it runs when the Driver next waits, when X is 39, which
    // passes 32, the captured array's last element, and adds its length.
    try expectInReport(x, "\"Sum\":42");
    try std.testing.expect(try live.everyMode(source) > 0);
}

test "Await: a frame that saw its task's waiter suspend reclaims, and the waiter's guard keeps its captures" {
    // RFC-0082 C73 and P3.5: `Make` hands off to a waiter, which builds an array, captures it in
    // its guard and waits at its `Await`; `Make`'s frame then ends having seen a switch, and
    // reclaims its own `Junk` below the waiter's array, so the waiter's saved registers, the
    // guard's capture among them, move. When the write wakes them, each guard reads its array.
    const source =
        \\var X:i64 = 0
        \\var Sum:i64 = 0
        \\Waiter(Limit:i64)<transacts><suspends>:void = Block{
        \\    Steps:[]i64 = array{Limit, Limit + 1, Limit + 2}
        \\    Await(X > Steps[2])
        \\    Set(Sum, Sum + X + Limit)
        \\}
        \\Make(K:i64)<transacts>:i64 = Block{
        \\    Junk:[]i64 = array{K, K, K, K, K, K, K, K, K, K, K, K, K, K, K, K, K, K, K, K}
        \\    T:task(void) = Spawn{ Waiter(K) }
        \\    K + Junk.Length - 20
        \\}
        \\Main()<transacts><suspends>:void = Block{ Sleep(0.0); A := Make(30); B := Make(40); Sleep(1.0); set X = 100; A + B }
        \\M:task(void) = Spawn{ Main() }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Sum\":270");
    try std.testing.expect(try live.everyMode(source) > 0);
}

test "the replay refuses forged steps of an Await: a resume that yields, a value where the task waited, another observer" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var X:i64 = 0
        \\Waiter()<transacts><suspends>:i64 = Block{ V := Await(Block{ Require[X > 1]; X }); V }
        \\Writer()<transacts><suspends>:void = Block{ Sleep(0.0); set X = 1; Sleep(0.0); set X = 2; X }
        \\W:task(i64) = Spawn{ Waiter() }
        \\K:task(void) = Spawn{ Writer() }
    );
    _ = try reporting.validate(x, false, .{});
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    var forged = x;
    forged.call_steps = steps;
    var observes: [4]usize = undefined;
    var observe_count: usize = 0;
    var suspends: [4]usize = undefined;
    var suspend_count: usize = 0;
    var resumes: [4]usize = undefined;
    var resume_count: usize = 0;
    var delivers: [4]usize = undefined;
    var deliver_count: usize = 0;
    for (steps, 0..) |step, index| switch (step.kind) {
        .observe => {
            observes[observe_count] = index;
            observe_count += 1;
        },
        // The Writer's sleeps wait for ticks and resume with the unit value.
        .@"suspend" => if (step.value == .boolean) {
            suspends[suspend_count] = index;
            suspend_count += 1;
        },
        .@"resume" => if (step.value == .boolean) {
            resumes[resume_count] = index;
            resume_count += 1;
        },
        .deliver => {
            delivers[deliver_count] = index;
            deliver_count += 1;
        },
        else => {},
    };
    // Arriving, and woken twice (by 1, failing, and by 2, holding).
    try std.testing.expectEqual(@as(usize, 3), observe_count);
    try std.testing.expectEqual(@as(usize, 2), suspend_count);
    try std.testing.expectEqual(@as(usize, 2), resume_count);
    try std.testing.expectEqual(@as(usize, 2), deliver_count);
    // A resume that says it yields a value, or that the site completes.
    const resumed = steps[resumes[0]];
    steps[resumes[0]].value = .{ .boolean = false };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[resumes[0]].value = .{ .integer = 1 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[resumes[0]] = resumed;
    // A wait that says it waits for a tick.
    const waited = steps[suspends[0]];
    steps[suspends[0]].value = .{ .integer = 1 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    // The site's value where the task waited.
    steps[suspends[0]] = .{ .function = waited.function, .pc = waited.pc, .value = .{ .integer = 0 } };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[suspends[0]] = waited;
    // An observe of another task, and of another guard.
    const observed = steps[observes[1]];
    steps[observes[1]].value = .{ .integer = 2 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[observes[1]].function += 1;
    steps[observes[1]].value = observed.value;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[observes[1]] = observed;
    // A delivery left out.
    var shorter = forged;
    const without = try std.testing.allocator.alloc(types.CallStep, steps.len - 1);
    defer std.testing.allocator.free(without);
    @memcpy(without[0..delivers[1]], steps[0..delivers[1]]);
    @memcpy(without[delivers[1]..], steps[delivers[1] + 1 ..]);
    shorter.call_steps = without;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(shorter, false, .{}));
    // The run's record says something else.
    var record = forged;
    record.live.deliveries += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    record = forged;
    record.live.evaluations -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    _ = try reporting.validate(forged, false, .{});
}

/// The scale test of `Await` (RFC-0084, P4.6): `tasks` tasks wait on one cell, each until it
/// passes its own threshold; `writes` writes raise the cell one step at a time, each waking the
/// tasks still waiting, which evaluate their guards again and wait once more or go on. In a
/// digest run, whose stores stay bounded.
pub fn awaitScale(f: trace_replay.Fixture, tasks: usize, writes: usize) !evaluator.Execution {
    var source_text: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_text,
        \\var X:i64 = 0
        \\var Done:i64 = 0
        \\Wait(K:i64)<transacts><suspends>:void = Block{{ Await(X >= K); Set(Done, Done + 1) }}
        \\Start(K:i64)<transacts>:i64 = Block{{ T:task(void) = Spawn{{ Wait(K) }}; K + 1 }}
        \\S:i64 = Iterate(Start, {d}, 1)
        \\Raise()<transacts><suspends>:void = Block{{ var N:i64 = 0; While(N < {d}, Block{{ set N = N + 1; set X = N; Sleep(0.0) }}) }}
        \\R:task(void) = Spawn{{ Raise() }}
    , .{ tasks, writes });
    const x = try @import("live_field_tests.zig").timed(f, "awaiters on one cell", source);
    // The final value of the cell `Done`, the first of the program's cells but one.
    try std.testing.expectEqual(@as(i64, @intCast(@min(tasks, writes))), x.cells[1].value.integer);
    return x;
}

/// `tasks` tasks wait on one cell; one write wakes them all, in the order they began to wait,
/// and each goes on: a delivery loop of `tasks` deliveries, and as many slices.
pub fn awaitFanOut(f: trace_replay.Fixture, tasks: usize) !evaluator.Execution {
    var source_text: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_text,
        \\var X:i64 = 0
        \\var Done:i64 = 0
        \\Wait(K:i64)<transacts><suspends>:void = Block{{ Await(X > 0); Set(Done, Done + 1) }}
        \\Start(K:i64)<transacts>:i64 = Block{{ T:task(void) = Spawn{{ Wait(K) }}; K + 1 }}
        \\S:i64 = Iterate(Start, {d}, 1)
        \\set X = 1
    , .{tasks});
    const x = try @import("live_field_tests.zig").timed(f, "a fan-out of one write to awaiters", source);
    try std.testing.expectEqual(@as(i64, @intCast(tasks)), x.cells[1].value.integer);
    try std.testing.expectEqual(@as(u64, tasks), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 2 * tasks), x.live.evaluations);
    try std.testing.expectEqual(@as(u64, tasks), x.scheduler.completed);
    return x;
}

test "the scale tests of Await at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const x = try awaitScale(f, 20, 25);
    // Each task is evaluated at its arrival and at each write up to its threshold.
    try std.testing.expectEqual(@as(u64, 20 + 20 * 21 / 2), x.live.evaluations);
    // The bootstrap profile runs 64 tasks at once: 63 awaiters and the root's none.
    _ = try awaitFanOut(f, 63);
}
