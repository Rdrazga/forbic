//! Structured concurrency, P3.7 (RFC-0082): `T.Cancel()` (`task_cancel`), the `Await` of a
//! cancelled task with its propagation (Q3), `NextTick()` as `Sleep(0.0)`, the interfaces
//! `awaitable(t)` and `signalable(t)` that handles and events implement, and
//! `GetSimulationElapsedTime()` (`elapsed_time`), in both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const catalogue = @import("aggregate_types.zig");
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

fn expectCounts(x: evaluator.Execution, created: u64, completed: u64, canceled: u64, waiting: usize) !void {
    try std.testing.expectEqual(created, x.scheduler.created);
    try std.testing.expectEqual(completed, x.scheduler.completed);
    try std.testing.expectEqual(canceled, x.scheduler.canceled);
    try std.testing.expectEqual(waiting, x.scheduler.waiting.len);
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

test "the Book's 14:888: Cancel asks a task to cancel, twice is safe, and its Defer runs as it unwinds" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var CleanedUp:i64 = 0
        \\Watcher()<transacts><suspends>:void = Block{
        \\    Defer{ set CleanedUp = 1 }
        \\    NextTick()
        \\}
        \\StopWatching()<transacts><suspends>:void = Block{
        \\    LongTask:task(void) = Spawn{ Watcher() }
        \\    LongTask.Cancel()
        \\    LongTask.Cancel()
        \\}
        \\RunStop()<transacts><suspends>:void = StopWatching()
        \\Started:task(void) = Spawn{ RunStop() }
    );
    // The watcher waited for the next tick; the request took its timer away, so the run ends at
    // tick 0 with the watcher cancelled and its `Defer` run.
    try expectReport(x, "{\"CleanedUp\":1,\"Started\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":1,\"canceled\":1,\"switches\":4,\"waiting\":[]}}\n");
}

test "the Book's 14:1054: code between sites runs on, so a loop without a site is not cut short" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Steps:i64 = 0
        \\LongComputation()<transacts><suspends>:void = Block{
        \\    For(I:0..9, Set(Steps, Steps + 1))
        \\    NextTick()
        \\}
        \\CancelEarly()<transacts><suspends>:void = Block{
        \\    Task := Spawn{ LongComputation() }
        \\    Task.Cancel()
        \\}
        \\RunCancel()<transacts><suspends>:void = CancelEarly()
        \\T:task(void) = Spawn{ RunCancel() }
    );
    try expectReport(x, "{\"Steps\":10,\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":1,\"canceled\":1,\"switches\":4,\"waiting\":[]}}\n");
}

test "the Book's 14:1086, with a While for its For (P3.8): a site in the loop lands the request after one step" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Steps:i64 = 0
        \\ResponsiveComputation()<transacts><suspends>:void = Block{
        \\    var I:i64 = 0
        \\    While(I < 10, Block{ set Steps = Steps + 1; set I = I + 1; NextTick() })
        \\}
        \\CancelEarly()<transacts><suspends>:void = Block{
        \\    Task := Spawn{ ResponsiveComputation() }
        \\    Task.Cancel()
        \\}
        \\RunCancel()<transacts><suspends>:void = CancelEarly()
        \\T:task(void) = Spawn{ RunCancel() }
    );
    try expectReport(x, "{\"Steps\":1,\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":1,\"canceled\":1,\"switches\":4,\"waiting\":[]}}\n");
    // The same with `Loop{}`: the visit that waits is cancelled, and the loop with it.
    const y = try expectRun(h,
        \\var Steps:i64 = 0
        \\Responsive()<transacts><suspends>:void = Block{ var I:i64 = 0; Loop{ set Steps = Steps + 1; set I = I + 1; If(I == 10, Break(), 0); NextTick() } }
        \\Main()<transacts><suspends>:void = Block{ Task := Spawn{ Responsive() }; Task.Cancel() }
        \\T:task(void) = Spawn{ Main() }
    );
    try std.testing.expectEqual(@as(i64, 1), y.get("Steps").?.integer);
}

test "the Book's 14:977: a deadline cancels a task from the other arm of a Race" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\ProcessData(S:float)<transacts><suspends>:void = Block{ Defer{ Print("process ends") }; Sleep(S) }
        \\StartTask(S:float)<transacts><suspends>:void = Block{
        \\    DataTask:task(void) = Spawn{ ProcessData(S) }
        \\    Race(
        \\        Block{ DataTask.Await(); Print("Task completed") },
        \\        Block{ Sleep(5.0); DataTask.Cancel(); Print("Task timed out and was canceled") })
        \\}
        \\Main()<transacts><suspends>:void = Block{ StartTask(1.0); StartTask(9.0) }
        \\T:task(void) = Spawn{ Main() }
    , "process ends\nTask completed\nTask timed out and was canceled\nprocess ends\n");
}

test "the Book's 14:923 (Q3): awaiting a cancelled task cancels the awaiter, at once or when it is woken" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each awaiter, in the order it began to wait, is asked when the task it awaits ends
    // cancelled; one that awaits it after that yields cancelled at once. Awaiting is not owning:
    // cancelling an awaiter leaves the awaited task alone (api:3269).
    const x = try expectPrinted(h,
        \\Work()<transacts><suspends>:i64 = Block{ Defer{ Print("work") }; Sleep(1.0); 5 }
        \\Wait(N:i64, T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("wait {N}") }; R := T.Await(); Print("got {R}"); R }
        \\Main()<transacts><suspends>:void = Block{
        \\    T := Spawn{ Work() }
        \\    A := Spawn{ Wait(1, T) }
        \\    B := Spawn{ Wait(2, T) }
        \\    T.Cancel()
        \\    Sleep(0.1)
        \\    C := Spawn{ Wait(3, T) }
        \\    Print("main")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "work\nwait 1\nwait 2\nwait 3\nmain\n");
    try expectCounts(x, 5, 1, 4, 0);
    _ = try expectPrinted(h,
        \\Work()<transacts><suspends>:i64 = Block{ Sleep(1.0); Print("work done"); 5 }
        \\Wait(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("waiter") }; T.Await() }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ Work() }; A := Spawn{ Wait(T) }; A.Cancel(); Print("t {T.Await()}") }
        \\M:task(void) = Spawn{ Main() }
    , "waiter\nwork done\nt 5\n");
}

test "propagation through a chain of awaiters, and through a structured expression's arms" {
    const h = try harness.create();
    defer scratch.release(h);
    // One request ends a chain: each task awaits the one before it.
    const chain = try expectPrinted(h,
        \\Root()<transacts><suspends>:i64 = Block{ Defer{ Print("root") }; Sleep(Inf); 0 }
        \\Link(N:i64, T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("link {N}") }; T.Await() + 1 }
        \\Main()<transacts><suspends>:void = Block{
        \\    T0 := Spawn{ Root() }
        \\    T1 := Spawn{ Link(1, T0) }
        \\    T2 := Spawn{ Link(2, T1) }
        \\    T3 := Spawn{ Link(3, T2) }
        \\    T0.Cancel()
        \\    Print("main {T3.Await()}")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "root\nlink 1\nlink 2\nlink 3\n");
    try expectCounts(chain, 5, 0, 5, 0);
    // An arm cancelled from outside its expression (it awaited a cancelled task) cancels the
    // task running the expression: its other arms first, then its own `Defer`s.
    _ = try expectPrinted(h,
        \\W()<transacts><suspends>:i64 = Block{ Sleep(1.0); 3 }
        \\Arm(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("arm") }; T.Await() }
        \\P(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("p") }; R := Sync(Arm(T), Block{ Defer{ Print("other") }; Sleep(5.0); 1 }); R(0) }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ W() }; U := Spawn{ P(T) }; T.Cancel(); Sleep(2.0); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "arm\nother\np\nmain\n");
    // An arm that is cancelled in its first run: no arm starts after it.
    const first = try expectPrinted(h,
        \\W()<transacts><suspends>:i64 = Block{ Sleep(1.0); 3 }
        \\Arm(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("arm") }; T.Await() }
        \\P(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("p") }; R := Sync(Arm(T), Block{ Print("never"); Sleep(5.0); 1 }); R(0) }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ W() }; T.Cancel(); Sleep(0.0); U := Spawn{ P(T) }; Print("main {U.Await()}") }
        \\M:task(void) = Spawn{ Main() }
    , "arm\np\n");
    // `W`, the arm, `P` and `Main` itself, which awaited `P`: all cancelled.
    try expectCounts(first, 4, 0, 4, 0);
    var at_once = false;
    for (first.call_steps, 0..) |step, index| {
        if (step.kind != .resume_canceled or first.program.function_nodes[first.program.functions[step.function].body.start + step.pc].node.kind != .structured) continue;
        // The site yields cancelled without a `suspend` before it.
        try std.testing.expect(first.call_steps[index - 1].kind != .@"suspend");
        at_once = true;
    }
    try std.testing.expect(at_once);
    // A `Race` already won takes such an arm for a loser: nothing propagates.
    _ = try expectPrinted(h,
        \\W()<transacts><suspends>:i64 = Block{ Sleep(1.0); 3 }
        \\Arm(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("arm") }; T.Await() }
        \\P(T:task(i64))<transacts><suspends>:i64 = Race(Arm(T), Block{ Sleep(0.5); 9 })
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ W() }; U := Spawn{ P(T) }; Sleep(0.6); T.Cancel(); Print("u {U.Await()}") }
        \\M:task(void) = Spawn{ Main() }
    , "arm\nu 9\n");
}

test "a request reaches what the task is doing: a Sync's arms first, a frame's branches, a Rush's losers" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("leaf {N}") }; Sleep(Inf); N }
        \\P()<transacts><suspends>:i64 = Block{ Defer{ Print("p") }; R := Sync(Leaf(1), Leaf(2)); R(0) }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ P() }; Sleep(1.0); T.Cancel(); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "main\nleaf 1\nleaf 2\np\n");
    _ = try expectPrinted(h,
        \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("leaf {N}") }; Sleep(Inf); N }
        \\Owner()<transacts><suspends>:i64 = Block{ Defer{ Print("owner") }; Branch{ Leaf(1) }; W := Rush(Leaf(2), Block{ Sleep(0.1); 3 }); Sleep(Inf); W }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ Owner() }; Sleep(1.0); T.Cancel(); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "main\nowner\nleaf 1\nleaf 2\n");
}

test "a task can be asked while it runs: its own handle, its creator's, a start the drain has not reached" {
    const h = try harness.create();
    defer scratch.release(h);
    // A task that asks itself goes on to its next site, which yields cancelled; `Cancel` is a
    // site too, and checks first.
    _ = try expectPrinted(h,
        \\var H:[]task(void) = array{}
        \\Me()<transacts><suspends>:void = Block{ Defer{ Print("d") }; Sleep(0.1); If(T := H[0], Block{ T.Cancel(); Print("asked"); T.Cancel(); Print("never") }, void(0)); Print("never") }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ Me() }; set H = array{T}; Sleep(1.0); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "asked\nd\nmain\n");
    // A task that its hand-off asks, while it is below on the stack, finds the flag at its next site.
    _ = try expectPrinted(h,
        \\var H:[]task(void) = array{}
        \\Child()<transacts><suspends>:void = Block{ If(T := H[0], T.Cancel(), void(0)); Print("child") }
        \\Parent()<transacts><suspends>:void = Block{ Defer{ Print("parent ends") }; Sleep(0.1); C := Spawn{ Child() }; Print("parent goes on"); Sleep(0.1); Print("never") }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ Parent() }; set H = array{T}; Sleep(1.0); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "child\nparent goes on\nparent ends\nmain\n");
    // A committed start asked before its turn runs to its first site.
    _ = try expectPrinted(h,
        \\var H:[]task(void) = array{}
        \\First()<transacts><suspends>:void = Block{ Print("first"); If(T := H[1], T.Cancel(), void(0)); Print("first done") }
        \\Second()<transacts><suspends>:void = Block{ Defer{ Print("second defer") }; Print("second"); Sleep(1.0); Print("never") }
        \\Main()<transacts><suspends>:void = Block{ Attempt(Block{ A := Spawn{ First() }; B := Spawn{ Second() }; set H = array{A, B}; 0 }, 1); Print("main") }
        \\M:task(void) = Spawn{ Main() }
    , "first\nfirst done\nsecond\nsecond defer\nmain\n");
}

test "Cancel of a settled task does nothing, and a task asked that never reaches a site completes" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Quick()<transacts><suspends>:i64 = 4
        \\Ends()<transacts><suspends>:i64 = Block{ Sleep(0.1); 6 }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    A := Spawn{ Quick() }
        \\    A.Cancel()
        \\    B := Spawn{ Ends() }
        \\    B.Cancel()
        \\    B.Cancel()
        \\    C := Spawn{ Ends() }
        \\    Sleep(0.5)
        \\    C.Cancel()
        \\    A.Await() + C.Await()
        \\}
        \\M:task(i64) = Spawn{ Main() }
    );
    try expectReport(x, "{\"M\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":10}},\"$scheduler\":{\"tick_rate\":60,\"tick\":30,\"created\":4,\"completed\":3,\"canceled\":1,\"switches\":10,\"waiting\":[]}}\n");
}

test "NextTick is Sleep(0.0): the next tick, a site, and a name that yields to a declaration" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Loop3()<transacts><suspends>:void = Block{ var I:i64 = 0; While(I < 3, Block{ NextTick(); set I = I + 1 }); Print("at {GetSimulationElapsedTime()}") }
        \\T:task(void) = Spawn{ Loop3() }
    , "at 0.05\n");
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.tick);
    var y = try h.execute("NextTick()<computes>:i64 = 7\nX:i64 = NextTick()");
    try std.testing.expectEqual(@as(i64, 7), y.get("X").?.integer);
    y = try h.execute("X:i64 = Block{ NextTick := 3; NextTick + 1 }");
    try std.testing.expectEqual(@as(i64, 4), y.get("X").?.integer);
    y = try h.execute("GetSimulationElapsedTime(A:i64)<computes>:i64 = A + 1\nX:i64 = GetSimulationElapsedTime(2)");
    try std.testing.expectEqual(@as(i64, 3), y.get("X").?.integer);
}

test "GetSimulationElapsedTime reads the virtual clock in seconds, at the run's tick rate" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var Seen:[]float = array{}
        \\Note()<transacts>:void = Set(Seen, Seen + array{GetSimulationElapsedTime()})
        \\Watch()<transacts><suspends>:void = Block{ Note(); Sleep(1.5); Note(); Sleep(0.01); Note() }
        \\Zero:float = GetSimulationElapsedTime()
        \\T:task(void) = Spawn{ Watch() }
    ;
    const x = try expectRun(h, source);
    // Root code runs at tick 0; 1.5 s are 90 ticks, and 0.01 s rounds up to one more.
    try expectReport(x, "{\"Seen\":[0,1.5,1.5166666666666666],\"Zero\":0,\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":91,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":5,\"waiting\":[]}}\n");
    // At another tick rate the same sleeps are other ticks, and the seconds follow them.
    const p = try h.compile(source);
    h.control.tick_rate = 7;
    h.runtime.machine.control.tick_rate = 7;
    defer {
        h.control.tick_rate = types.Scheduler.default_tick_rate;
        h.runtime.machine.control.tick_rate = types.Scheduler.default_tick_rate;
    }
    const slow = (try h.run(p, concurrency.fuel)).ok;
    // ceil(1.5 * 7) = 11 ticks, then one more.
    try std.testing.expectEqual(@as(u64, 12), slow.scheduler.tick);
    try expectReport(slow, "{\"Seen\":[0,1.5714285714285714,1.7142857142857142],\"Zero\":0,\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":7,\"tick\":12,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":5,\"waiting\":[]}}\n");
}

test "the Book's 14:1664: awaitable and signalable, which an event implements both of and a handle the first" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Got:i64 = 0
        \\ConsumerFunction(Source:awaitable(i64))<transacts><suspends>:void = Block{ Value := Source.Await(); Set(Got, Value) }
        \\ProducerFunction(Target:signalable(i64))<transacts>:void = Target.Signal(42)
        \\Channel:event(i64) = event(i64){}
        \\Reader:awaitable(i64) = Channel
        \\Writer:signalable(i64) = Channel
        \\C:task(void) = Spawn{ ConsumerFunction(Reader) }
        \\P:void = ProducerFunction(Writer)
    );
    try expectReport(x, "{\"Got\":42,\"Channel\":{\"$event\":{\"waiting\":0}},\"Reader\":{\"$event\":{\"waiting\":0}},\"Writer\":{\"$event\":{\"waiting\":0}},\"C\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"P\":[],\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":3,\"waiting\":[]}}\n");
    // A handle is awaitable: its result, at once when it has completed, and its cancellation.
    _ = try expectPrinted(h,
        \\Work(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.5); N }
        \\Twice(A:awaitable(i64))<transacts><suspends>:i64 = A.Await() + A.Await()
        \\Main()<transacts><suspends>:void = Block{
        \\    T := Spawn{ Work(4) }
        \\    E := event(i64){}
        \\    Items:[]awaitable(i64) = array{T, E}
        \\    Print("t {Twice(T)}")
        \\    U := Spawn{ Block{ Defer{ Print("u") }; Twice(Spawn{ Block{ Sleep(Inf); 0 } }) } }
        \\    Print("items {Items.Length}")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "t 8\nitems 2\n");
}

test "every compile-time refusal of P3.7 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        // `Cancel` and `NextTick` are sites: only in a function that suspends, never where code
        // must finish at once, and `Cancel` writes.
        .{ .source = "W()<transacts><suspends>:void = Sleep(1.0)\nF(T:task(void))<transacts>:void = T.Cancel()", .code = .call_requires_suspends, .at = "Cancel" },
        .{ .source = "W()<transacts><suspends>:void = Sleep(1.0)\nT:task(void) = Spawn{ W() }\nX:void = T.Cancel()", .code = .call_requires_suspends, .at = "Cancel" },
        .{ .source = "F(T:task(void))<reads><suspends>:void = T.Cancel()", .code = .call_requires_writes, .at = "Cancel" },
        .{ .source = "F(T:task(void))<transacts><suspends>:i64 = Attempt(Block{ T.Cancel(); 1 }, 0)", .code = .suspends_in_failure_context, .at = "Cancel" },
        .{ .source = "F(T:task(void))<transacts><suspends>:i64 = Block{ Defer{ T.Cancel() }; 1 }", .code = .suspends_in_failure_context, .at = "Cancel" },
        .{ .source = "F()<transacts>:void = NextTick()", .code = .call_requires_suspends, .at = "NextTick" },
        .{ .source = "X:void = NextTick()", .code = .call_requires_suspends, .at = "NextTick" },
        .{ .source = "F()<transacts><suspends>:logic = logic{ NextTick(); true }", .code = .suspends_in_failure_context, .at = "NextTick" },
        .{ .source = "F()<transacts><suspends>:void = NextTick(1)", .code = .argument_count, .at = "1" },
        // The clock is read.
        .{ .source = "F()<computes>:float = GetSimulationElapsedTime()", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "F()<reads>:float = GetSimulationElapsedTime(1.0)", .code = .argument_count, .at = "1.0" },
        // An event has no `Cancel`; an awaitable no `Signal` and a signalable no `Await`
        // (Book 14:1655); a handle is no signalable, and the types must agree.
        .{ .source = "E:event(i64) = event(i64){}\nF()<transacts><suspends>:void = E.Cancel()", .code = .unknown_field, .at = "Cancel" },
        .{ .source = "F(Source:awaitable(i64))<transacts><suspends>:void = Source.Signal(123)", .code = .unknown_field, .at = "Signal" },
        .{ .source = "F(Target:signalable(i64))<transacts><suspends>:i64 = Target.Await()", .code = .unknown_field, .at = "Await" },
        .{ .source = "W()<transacts><suspends>:i64 = 1\nT:task(i64) = Spawn{ W() }\nS:signalable(i64) = T", .code = .type_mismatch, .at = "Spawn" },
        .{ .source = "E:event(i64) = event(i64){}\nS:awaitable(string) = E", .code = .type_mismatch, .at = "event" },
        .{ .source = "E:event(i64) = event(i64){}\nS:awaitable(i64) = E\nA:any = any(S)", .code = .type_mismatch, .at = "event" },
        .{ .source = "E:event(i64) = event(i64){}\nS:awaitable(i64) = E\nB:logic = If(S == S, true, false)", .code = .not_comparable, .at = "==" },
        .{ .source = "X:i64 = awaitable(1)", .code = .unknown_name, .at = "awaitable" },
        .{ .source = "F(S:signalable(i64, i64))<transacts>:void = {}", .code = .expected_type, .at = "signalable" },
        // A `Defer` open where any task can be cancelled runs as a function there (C37, C87).
        // RFC-0085, I5: the landing shares a local `var` it assigns; a parameter is refused in
        // the copies at its exits.
        .{ .source = "F(N:i64)<transacts><suspends>:i64 = Block{ Defer{ set N = 1 }; Sleep(1.0); N }\nG(T:task(i64))<transacts><suspends>:void = T.Cancel()", .code = .not_mutable, .at = "N" },
    }) |case| try expectRefused(h, case.source, case.code, case.at);
}

test "the names of P3.7 yield to whatever the program declares by them" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type of the program named `awaitable` is that type.
    var x = try h.execute("awaitable := struct{ N:i64 }\nA:awaitable = awaitable{ N := 3 }\nX:i64 = A.N");
    try std.testing.expectEqual(@as(i64, 3), x.get("X").?.integer);
    x = try h.execute("signalable(A:i64)<computes>:i64 = A * 5\nX:i64 = signalable(1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("X").?.integer);
    // An extension method `Cancel` of a handle is what the name means for a handle.
    _ = try expectPrinted(h,
        \\(T:task(i64)).Cancel()<transacts>:void = Print("mine")
        \\W()<transacts><suspends>:i64 = Block{ Sleep(1.0); 2 }
        \\Main()<transacts><suspends>:void = Block{ T := Spawn{ W() }; T.Cancel(); Print("t {T.Await()}") }
        \\M:task(void) = Spawn{ Main() }
    , "mine\nt 2\n");
}

test "a program that cancels gets the landings of its Defers; one that does not keeps its IR" {
    const h = try harness.create();
    defer scratch.release(h);
    const with = try h.compile("Worker()<transacts><suspends>:void = Block{ Defer{ Print(\"w\") }; Sleep(Inf) }\nMain()<transacts><suspends>:void = Block{ T := Spawn{ Worker() }; T.Cancel() }\nM:task(void) = Spawn{ Main() }");
    var invokes: usize = 0;
    for (with.function_nodes) |entry| invokes += @intFromBool(entry.input == .operation and entry.node.kind == .invoke);
    try std.testing.expect(invokes != 0);
    // Await, NextTick, the interfaces and the clock cancel nothing: no landing.
    const without = try h.compile("Worker(E:awaitable(i64))<transacts><suspends>:void = Block{ Defer{ Print(\"w\") }; NextTick(); X := E.Await(); Y := GetSimulationElapsedTime(); Print(\"{X} {Y}\") }\nE:event(i64) = event(i64){}\nM:task(void) = Spawn{ Worker(E) }");
    for (without.function_nodes) |entry| try std.testing.expect(entry.input != .operation or (entry.node.kind != .invoke and entry.node.kind != .task_cancel));
    // A program without any of the forms of P3.7 has none of their operations or types.
    const plain = try h.compile("Worker()<transacts><suspends>:i64 = Block{ Sleep(1.0); 3 }\nMain()<transacts><suspends>:i64 = Block{ T := Spawn{ Worker() }; T.Await() }\nM:task(i64) = Spawn{ Main() }");
    for (plain.function_nodes) |entry| try std.testing.expect(entry.input != .operation or (entry.node.kind != .task_cancel and entry.node.kind != .elapsed_time));
    for (plain.definitions) |item| try std.testing.expect(item != .scheduled_interface);
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

/// The function of `p` named `name`.
fn named(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, id| if (std.mem.eql(u8, f.name.text(p.source), name)) return id;
    unreachable;
}

/// Refused by both machines, and by the replay, which admits a run of it again.
fn refusedEverywhere(h: *harness.Harness, forged: types.Program, run: evaluator.Execution) !void {
    try harness.invalid(h, forged);
    var replayed = run;
    replayed.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(replayed, false, .{}));
}

const forged_source =
    \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("d{N}") }; Sleep(1.0); N }
    \\Use(E:event(i64))<transacts><suspends>:float = Block{
    \\    T := Spawn{ Leaf(1) }
    \\    A:awaitable(i64) = T
    \\    S:signalable(i64) = E
    \\    T.Cancel()
    \\    S.Signal(3)
    \\    X := A.Await()
    \\    GetSimulationElapsedTime() + 1.0
    \\}
    \\Asks(T:task(i64))<writes><suspends>:void = T.Cancel()
    \\Reads()<reads>:float = GetSimulationElapsedTime()
    \\E:event(i64) = event(i64){}
    \\M:task(float) = Spawn{ Use(E) }
    \\Z:float = GetSimulationElapsedTime()
;

test "forged cancellations, clocks, awaits and signals of interfaces, and casts to them are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const run = try expectRun(h, forged_source);
    const forged = forgeable(h, p);
    const use = named(p, "Use");
    const base = p.functions[use].body.start;
    const body = p.function_nodes[base..p.functions[use].body.end];
    const none = std.math.maxInt(u32);
    var spawn: u32 = none;
    var cancel: u32 = none;
    var clock: u32 = none;
    var signal: u32 = none;
    var await_at: u32 = none;
    var awaitable: u32 = none;
    var signalable: u32 = none;
    var event: u32 = none;
    for (body, 0..) |entry, index| {
        const at: u32 = @intCast(index);
        switch (entry.input) {
            .parameter => event = at,
            .global => {},
            .operation => switch (entry.node.kind) {
                .spawn => spawn = at,
                .task_cancel => cancel = at,
                .elapsed_time => clock = at,
                .event_signal => signal = at,
                .task_await => await_at = at,
                .upcast => if (catalogue.scheduledInterface(entry.node.value_type, p.definitions)) |interface| {
                    if (interface.kind == .awaitable) awaitable = at else signalable = at;
                },
                else => {},
            },
        }
    }
    if (spawn == none or cancel == none or clock == none or signal == none or await_at == none or awaitable == none or signalable == none or event == none) {
        for (body, 0..) |entry, index| std.debug.print("{d}: {any} {any}\n", .{ index, entry.input, entry.node.kind });
        return error.TestUnexpectedResult;
    }
    const Forgery = struct { at: u32, node: types.Node };
    const cancel_node = body[cancel].node;
    const clock_node = body[clock].node;
    const signal_node = body[signal].node;
    const await_node = body[await_at].node;
    const signalable_node = body[signalable].node;
    const awaitable_node = body[awaitable].node;
    var cases: [16]Forgery = undefined;
    var count: usize = 0;
    var node = cancel_node;
    // A request typed as anything but the unit value; of an awaitable, of an event, of a value
    // that is no handle, and of a node after it.
    node.value_type = .i64;
    cases[count] = .{ .at = cancel, .node = node };
    count += 1;
    for ([_]u32{ awaitable, event, 0, cancel + 1 }) |operand| {
        node = cancel_node;
        node.kind.task_cancel = operand;
        cases[count] = .{ .at = cancel, .node = node };
        count += 1;
    }
    // The clock as an integer.
    node = clock_node;
    node.value_type = .i64;
    cases[count] = .{ .at = clock, .node = node };
    count += 1;
    // An await of an awaitable that yields another type; a signal of an awaitable.
    node = await_node;
    node.value_type = .string;
    cases[count] = .{ .at = await_at, .node = node };
    count += 1;
    node = signal_node;
    node.kind.event_signal.event = awaitable;
    cases[count] = .{ .at = signal, .node = node };
    count += 1;
    // A handle cast to a signalable, an event's interface to the other, and an interface to `any`.
    node = signalable_node;
    node.kind.upcast = spawn;
    cases[count] = .{ .at = signalable, .node = node };
    count += 1;
    node = awaitable_node;
    node.value_type = signalable_node.value_type;
    cases[count] = .{ .at = awaitable, .node = node };
    count += 1;
    node = signalable_node;
    node.kind.upcast = awaitable;
    cases[count] = .{ .at = signalable, .node = node };
    count += 1;
    node = awaitable_node;
    node.value_type = types.Type.any;
    cases[count] = .{ .at = awaitable, .node = node };
    count += 1;
    // The awaitable's `Await` turned into an event's, which needs an event.
    node = await_node;
    node.kind = .{ .event_await = awaitable };
    cases[count] = .{ .at = await_at, .node = node };
    count += 1;
    for (cases[0..count]) |case| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        h.body[base + case.at].node = case.node;
        refusedEverywhere(h, forged, run) catch |err| {
            std.debug.print("forged {any} admitted\n", .{case.node});
            return err;
        };
    }
    // A request without its check after it, or with a check one node late.
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    h.body[base + cancel + 1].node.kind = .{ .boolean = false };
    try refusedEverywhere(h, forged, run);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    // In a function that does not suspend; one that may not write asks no task; one that may
    // not read reads no clock.
    h.metadata[named(p, "Asks")].detail = .{ .no_writes = true, .suspends = true };
    try refusedEverywhere(h, forged, run);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[named(p, "Asks")].detail = .{ .no_reads = true, .no_allocates = true };
    try refusedEverywhere(h, forged, run);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[named(p, "Reads")].transacts = false;
    h.metadata[named(p, "Reads")].detail = .{};
    try refusedEverywhere(h, forged, run);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // At the root a request is a site, which root code holds none of; the clock is read there.
    var nodes: [256]types.Node = undefined;
    @memcpy(nodes[0..p.nodes.len], p.nodes);
    var rooted = forged;
    rooted.nodes = nodes[0..p.nodes.len];
    var handle: u32 = none;
    var root_clock: u32 = none;
    for (p.nodes, 0..) |item, index| switch (item.kind) {
        .spawn => handle = @intCast(index),
        .elapsed_time => root_clock = @intCast(index),
        else => {},
    };
    try std.testing.expect(handle != none and root_clock != none);
    try std.testing.expect(handle < root_clock);
    nodes[root_clock] = .{ .span = p.nodes[root_clock].span, .value_type = cancel_node.value_type, .kind = .{ .task_cancel = handle } };
    try harness.invalid(h, rooted);
    nodes[root_clock] = p.nodes[root_clock];
    nodes[root_clock].value_type = .i64;
    try harness.invalid(h, rooted);
    // The catalogue: an interface twice, or of a type that is not there.
    var definitions: [types.limits.user_types]types.Definition = undefined;
    @memcpy(definitions[0..p.definitions.len], p.definitions);
    var interface_at: usize = none;
    for (p.definitions, 0..) |item, index| if (item == .scheduled_interface) {
        interface_at = index;
    };
    try std.testing.expect(interface_at != none);
    var cataloged = p;
    cataloged.definitions = definitions[0 .. p.definitions.len + 1];
    definitions[p.definitions.len] = p.definitions[interface_at];
    try harness.invalid(h, cataloged);
    cataloged.definitions = definitions[0..p.definitions.len];
    definitions[p.definitions.len] = undefined;
    definitions[interface_at].scheduled_interface.value = @fromBackingInt(@as(u16, 4000));
    try harness.invalid(h, cataloged);
}

test "a forged schedule of cancellations is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Work()<transacts><suspends>:i64 = Block{ Defer{ Print("w") }; Sleep(1.0); 5 }
        \\Wait(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print("a") }; T.Await() }
        \\Arm(T:task(i64))<transacts><suspends>:i64 = T.Await()
        \\P(T:task(i64))<transacts><suspends>:i64 = Block{ R := Sync(Arm(T), Block{ Sleep(0.1); 1 }); R(0) }
        \\Main()<transacts><suspends>:float = Block{
        \\    T := Spawn{ Work() }
        \\    A := Spawn{ Wait(T) }
        \\    B := Spawn{ Wait(T) }
        \\    T.Cancel()
        \\    Sleep(0.1)
        \\    C := Spawn{ Wait(T) }
        \\    D := Spawn{ P(T) }
        \\    GetSimulationElapsedTime()
        \\}
        \\M:task(float) = Spawn{ Main() }
    );
    _ = try reporting.validate(x, false, .{});
    // The work, two awaiters woken to unwind, one that unwinds at once, and the arm and `P`.
    try std.testing.expectEqual(@as(u64, 6), x.scheduler.canceled);
    const steps = x.call_steps;
    const Forgery = enum { cancel_value, cancel_canceled, await_waits, awaiters_swapped, settle_value, canceled_count, clock_value, structured_value, handle_state };
    var cells: [512]@import("source_state.zig").Cell = undefined;
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var done = false;
        var index: usize = 0;
        while (index < steps.len and !done) : (index += 1) {
            const step = &h.steps[index];
            const f = x.program.functions[step.function];
            // The kind of the step's node; a step at a frame's end names none.
            const node: std.meta.Tag(@FieldType(types.Node, "kind")) = if (step.function < x.program.functions.len and step.pc < f.body.end - f.body.start) std.meta.activeTag(x.program.function_nodes[f.body.start + step.pc].node.kind) else .canceling;
            switch (forgery) {
                .cancel_value => if (step.kind == .value and node == .task_cancel) {
                    step.value = .{ .integer = 0 };
                    done = true;
                },
                .cancel_canceled => if (step.kind == .value and node == .task_cancel) {
                    step.kind = .resume_canceled;
                    step.value = .{ .integer = 1 };
                    done = true;
                },
                .await_waits => if (step.kind == .resume_canceled and node == .task_await and index > 0 and h.steps[index - 1].kind != .@"suspend") {
                    step.kind = .@"suspend";
                    done = true;
                },
                .awaiters_swapped => if (step.kind == .resume_canceled and node == .task_await) {
                    var other = index + 1;
                    while (other < steps.len and !(h.steps[other].kind == .resume_canceled and h.steps[other].function == step.function)) other += 1;
                    if (other < steps.len) {
                        std.mem.swap(types.CallStep, step, &h.steps[other]);
                        done = true;
                    }
                },
                .settle_value => if (step.kind == .settle and step.value == .boolean and !step.value.boolean and std.mem.eql(u8, f.name.text(x.program.source), "Spawn")) {
                    step.value = .{ .boolean = true };
                    done = true;
                },
                .canceled_count => {
                    forged.scheduler.canceled -= 1;
                    done = true;
                },
                .clock_value => if (step.kind == .value and node == .elapsed_time) {
                    step.value = .{ .floating = step.value.floating + 1.0 };
                    done = true;
                },
                .structured_value => if (step.kind == .resume_canceled and node == .structured) {
                    step.kind = .value;
                    step.value = .{ .integer = 1 };
                    done = true;
                },
                .handle_state => {
                    // A cancelled task's handle said to have completed.
                    @memcpy(cells[0..x.object_cells.len], x.object_cells);
                    forged.object_cells = cells[0..x.object_cells.len];
                    // Instance by instance, each a header naming its type and then its cells.
                    var at: usize = 0;
                    while (at < x.object_cells.len) {
                        const class: types.Type = @fromBackingInt(@as(u16, @intCast(cells[at].value.integer)));
                        if (catalogue.isTask(class, x.program.definitions) and cells[at + catalogue.task_state].value.integer == catalogue.task_canceled) {
                            cells[at + catalogue.task_state].value.integer = catalogue.task_active;
                            done = true;
                            break;
                        }
                        at += catalogue.classCells(class, x.program.definitions).?;
                    }
                },
            }
        }
        if (!done) {
            std.debug.print("no step to forge for {t}\n", .{forgery});
            return error.TestUnexpectedResult;
        }
        _ = reporting.validate(forged, false, .{}) catch |err| {
            try std.testing.expectEqual(error.InvalidExecution, err);
            continue;
        };
        std.debug.print("forged schedule admitted: {t}\n", .{forgery});
        return error.TestUnexpectedResult;
    }
}

test "programs that cancel need the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Work()<transacts><suspends>:i64 = Block{ Defer{ Print(\"w\") }; Sleep(1.0); 5 }\nWait(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print(\"a\") }; T.Await() }\nMain()<transacts><suspends>:float = Block{ T := Spawn{ Work() }; A := Spawn{ Wait(T) }; T.Cancel(); T.Cancel(); Sleep(0.1); C := Spawn{ Wait(T) }; GetSimulationElapsedTime() }\nM:task(float) = Spawn{ Main() }",
        "W()<transacts><suspends>:i64 = Block{ Sleep(1.0); 3 }\nArm(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print(\"arm\") }; T.Await() }\nP(T:task(i64))<transacts><suspends>:i64 = Block{ Defer{ Print(\"p\") }; R := Sync(Arm(T), Block{ Defer{ Print(\"other\") }; Sleep(5.0); 1 }); R(0) }\nMain()<transacts><suspends>:void = Block{ T := Spawn{ W() }; U := Spawn{ P(T) }; T.Cancel(); Sleep(2.0); Print(\"main\") }\nM:task(void) = Spawn{ Main() }",
        "Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"leaf {N}\") }; Sleep(Inf); N }\nOwner()<transacts><suspends>:i64 = Block{ Branch{ Leaf(1) }; W := Rush(Leaf(2), Block{ NextTick(); 3 }); X := Sync(Leaf(4), Leaf(5)); W }\nE:event(i64) = event(i64){}\nMain(A:awaitable(i64))<transacts><suspends>:void = Block{ T := Spawn{ Owner() }; Sleep(1.0); T.Cancel(); Print(\"main {A.Await()}\") }\nM:task(void) = Spawn{ Main(E) }",
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

test "cancellations in a digest run that reclaims report as a stored run, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Work(N:i64)<transacts><suspends>:i64 = Block{ Defer{ X := Many(4) }; J := Many(6); Sleep(1.0); N + J }
        \\Wait(T:task(i64))<transacts><suspends>:i64 = Block{ J := Many(5); Defer{ X := Many(3) }; T.Await() + J }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    T := Spawn{ Work(1) }
        \\    A := Spawn{ Wait(T) }
        \\    U := Spawn{ Work(2) }
        \\    K := Many(8)
        \\    T.Cancel()
        \\    Sleep(0.5)
        \\    B := Spawn{ Wait(U) }
        \\    L := Many(7)
        \\    B.Await() + K + L
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

/// The scale test of P3.7: a chain of `length` tasks, each awaiting the one before it, the first
/// asleep for ever. One `Cancel` of the first ends them all: each that settles cancelled asks its
/// awaiter, which unwinds in its turn of the scheduler, on its queue, so the native stack does
/// not grow with the chain; each runs its `Defer`, and the task that built the chain, awaiting
/// the last, is cancelled too. Prints how long each machine and the replay took.
pub fn awaitChain(h: *harness.Harness, length: u32, budget: u64) !void {
    var buffer: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&buffer,
        \\var Unwound:i64 = 0
        \\Root()<transacts><suspends>:i64 = Block{{ Defer{{ set Unwound = Unwound + 1 }}; Sleep(Inf); 0 }}
        \\Link(T:task(i64))<transacts><suspends>:i64 = Block{{ Defer{{ set Unwound = Unwound + 1 }}; T.Await() + 1 }}
        \\Build(N:i64)<transacts><suspends>:i64 = Block{{
        \\    First := Spawn{{ Root() }}
        \\    var Last:task(i64) = First
        \\    var I:i64 = 0
        \\    While(I < N, Block{{ L := Last; set Last = Spawn{{ Link(L) }}; set I = I + 1 }})
        \\    First.Cancel()
        \\    Last.Await()
        \\}}
        \\M:task(i64) = Spawn{{ Build({d}) }}
    , .{length});
    const p = try h.compile(source);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("await chain failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    // The chain, its root and the builder: every one cancelled.
    try std.testing.expectEqual(@as(u64, length) + 2, actual.ok.scheduler.created);
    try std.testing.expectEqual(@as(u64, 0), actual.ok.scheduler.completed);
    try std.testing.expectEqual(@as(u64, length) + 2, actual.ok.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), actual.ok.scheduler.waiting.len);
    _ = try reporting.validate(actual.ok, false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("a chain of {d} awaiters cancelled from its root: reference={d}ms vm={d}ms replay={d}ms\n", .{ length, referenced, ran - referenced, elapsed(start) - ran });
    var report: [1024]u8 = undefined;
    var written: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&written, actual.ok, false, .{ .work = std.math.maxInt(u64) });
    var expected: [64]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, written.buffered(), try std.fmt.bufPrint(&expected, "{{\"Unwound\":{d},", .{@as(u64, length) + 1})));
}

test "a chain of awaiters cancelled from its root, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    try awaitChain(h, 60, 1 << 24);
}

test "one task more than the capacity, made by a chain of awaiters, is task_limit at its spawn" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // The builder, the root and 62 links fill the 64 slots; the next spawn needs one more.
    const p = try h.compile(
        \\Root()<transacts><suspends>:i64 = Block{ Sleep(Inf); 0 }
        \\Link(T:task(i64))<transacts><suspends>:i64 = T.Await() + 1
        \\Build(N:i64)<transacts><suspends>:i64 = Block{
        \\    First := Spawn{ Root() }
        \\    var Last:task(i64) = First
        \\    var I:i64 = 0
        \\    While(I < N, Block{ L := Last; set Last = Spawn{ Link(L) }; set I = I + 1 })
        \\    First.Cancel()
        \\    Last.Await()
        \\}
        \\M:task(i64) = Spawn{ Build(63) }
    );
    const outcome = try h.run(p, concurrency.fuel);
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.task_limit, outcome.failed.code);
    try std.testing.expectEqualStrings("Spawn", p.source[outcome.failed.span.start..outcome.failed.span.end]);
}

test "review: a standard function of no arguments may close its parenthesis on a later line" {
    const h = try harness.create();
    defer scratch.release(h);
    const y = try h.execute("Y:float = GetSimulationElapsedTime(\n)");
    try std.testing.expectEqual(@as(f64, 0.0), y.get("Y").?.floating);
    const x = try expectPrinted(h,
        \\F()<transacts><suspends>:void = Block{
        \\    NextTick(
        \\    )
        \\    Print("at {GetSimulationElapsedTime(
        \\    )}")
        \\}
        \\T:task(void) = Spawn{ F() }
    , "at 0.016666666666666666\n");
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.tick);
    // An argument is still refused, on whatever line it stands.
    try expectRefused(h, "F()<transacts><suspends>:void = NextTick(\n1)", .argument_count, "1");
}

test "review: the interfaces and Cancel of a type parameter, in generic functions and a parametric class" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Get[T:type](A:awaitable(T))<transacts><suspends>:T{ A.Await() }
        \\Put[T:type](A:signalable(T), V:T)<transacts>:void{ A.Signal(V) }
        \\Stop[T:type](A:task(T))<transacts><suspends>:void{ A.Cancel() }
        \\Box[T:type] := class{ A:awaitable(T); S:signalable(T) }
        \\Slow()<transacts><suspends>:i64 = Block{ Defer{ Print("slow") }; Sleep(Inf); 0 }
        \\Four()<transacts><suspends>:i64 = Block{ Sleep(0.1); 4 }
        \\E:event(string) = event(string){}
        \\B:Box[string] = Box[string]{ A := E, S := E }
        \\Main()<transacts><suspends>:void = Block{
        \\    U := Spawn{ Slow() }
        \\    Stop[i64](U)
        \\    W := Spawn{ Get[string](B.A) }
        \\    Put[string](B.S, "s")
        \\    Print("{Get[i64](Spawn{ Four() })} {W.Await()}")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "slow\n4 s\n");
}

test "a Cancel of a reaction that has not settled cancels it (C100, replaced by RFC-0084 P4.7)" {
    const h = try harness.create();
    defer scratch.release(h);
    const canceled = try expectRun(h,
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\U:task(i64) = Upon(X > 0, Set(N, N + 1))
        \\Stop()<transacts><suspends>:void = U.Cancel()
        \\T:task(void) = Spawn{ Stop() }
        \\set X = 1
    );
    try expectReport(canceled, "{\"X\":1,\"N\":0,\"U\":{\"$task\":{\"sequence\":1,\"state\":\"canceled\"}},\"T\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":1,\"canceled\":1,\"switches\":1,\"waiting\":[]},\"$live\":{\"records\":0,\"propagations\":1,\"evaluations\":1,\"entries\":1,\"deliveries\":0,\"firings\":0}}\n");
    // An `Upon` that has fired has settled: asking it does nothing.
    const x = try expectRun(h,
        \\var X:i64 = 1
        \\var N:i64 = 0
        \\U:task(i64) = Upon(X > 0, Set(N, N + 1))
        \\Stop()<transacts><suspends>:void = Block{ U.Cancel(); Print("n {N}") }
        \\T:task(void) = Spawn{ Stop() }
    );
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("n 1\n", printed(x, &buffer));
}

test "the clock is read only where reading is declared: every function without <reads> is refused it" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        .{ .source = "F()<writes>:float = GetSimulationElapsedTime()", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "F()<allocates>:float = GetSimulationElapsedTime()", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "F()<writes><allocates>:float = GetSimulationElapsedTime()", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "F()<computes><suspends>:float = GetSimulationElapsedTime()", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "F()<computes><decides>:float = Block{ X := GetSimulationElapsedTime(); X > 0.0; X }", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        // A closure that only computes, in a function that reads, does not read.
        .{ .source = "F()<reads>:float = Block{ G := Fn()<computes>:float{ GetSimulationElapsedTime() }; G() }", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
        .{ .source = "C := class{ F()<computes>:float = GetSimulationElapsedTime() }", .code = .call_requires_reads, .at = "GetSimulationElapsedTime" },
    }) |case| try expectRefused(h, case.source, case.code, case.at);
    // Each declared set that reads may.
    for ([_][]const u8{
        "F()<reads>:float = GetSimulationElapsedTime()\nX:float = F()",
        "F()<reads><writes>:float = GetSimulationElapsedTime()\nX:float = F()",
        "F()<transacts>:float = GetSimulationElapsedTime()\nX:float = F()",
        "F()<reads><suspends>:float = GetSimulationElapsedTime()\nT:task(float) = Spawn{ F() }",
    }) |source| _ = try expectRun(h, source);
}

const clock_forgery_source =
    \\Clocked()<reads>:float = GetSimulationElapsedTime()
    \\Pure()<computes>:float = 1.0
    \\Other()<reads>:float = 1.0
    \\Z:float = Clocked() + Pure() + Other()
;

test "a forged clock read in a function that does not read is refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(clock_forgery_source);
    const run = try expectRun(h, clock_forgery_source);
    const forged = forgeable(h, p);
    // The declared set of the function that reads the clock, narrowed to each set without `reads`.
    const clocked = named(p, "Clocked");
    try std.testing.expect(p.functions[clocked].has_control and p.functions[clocked].transacts);
    for ([_]struct { transacts: bool, detail: types.EffectDetail }{
        .{ .transacts = false, .detail = .{} },
        .{ .transacts = true, .detail = .{ .no_reads = true } },
        .{ .transacts = true, .detail = .{ .no_reads = true, .no_writes = true } },
        .{ .transacts = true, .detail = .{ .no_reads = true, .no_allocates = true } },
        .{ .transacts = false, .detail = .{ .predicts = true } },
    }) |set| {
        try std.testing.expect(types.effectsCanonical(set.transacts, false, set.detail));
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        h.metadata[clocked].transacts = set.transacts;
        h.metadata[clocked].detail = set.detail;
        refusedEverywhere(h, forged, run) catch |err| {
            std.debug.print("a clock read admitted in a function declaring {any} {any}\n", .{ set.transacts, set.detail });
            return err;
        };
    }
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // A clock read placed in the body of a function that only computes, with its metadata
    // made to agree, is refused; the same placement in a function that reads is admitted, and
    // both machines read the root's clock, 0.0.
    for ([_]struct { name: []const u8, admitted: bool }{ .{ .name = "Pure", .admitted = false }, .{ .name = "Other", .admitted = true } }) |target| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        const id = named(p, target.name);
        const f = p.functions[id];
        try std.testing.expect(!f.has_control and f.body.end - f.body.start == 1);
        try std.testing.expect(p.function_nodes[f.body.start].node.kind == .floating);
        h.body[f.body.start].node.kind = .elapsed_time;
        h.metadata[id].has_control = true;
        h.metadata[id].control_ops = 1;
        if (target.admitted) {
            const e = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 1_000_000);
            const v = h.runtime.evaluate(forged, 1_000_000);
            if (e == .failed or v == .failed) {
                std.debug.print("the control placement was refused: {any} {any}\n", .{ e == .failed, v == .failed });
                return error.TestUnexpectedResult;
            }
            // `Clocked() + Pure() + Other()`: 0.0 + 1.0 + 0.0, where it was 2.0.
            try std.testing.expectEqual(@as(f64, 1.0), e.ok.get("Z").?.floating);
            try std.testing.expectEqual(@as(f64, 1.0), v.ok.get("Z").?.floating);
        } else {
            refusedEverywhere(h, forged, run) catch |err| {
                std.debug.print("a clock read admitted in {s}\n", .{target.name});
                return err;
            };
        }
    }
}
