//! Structured concurrency, P3.2 (RFC-0082): `T.Await()`, `event(t)`, `E.Signal(V)` and
//! `E.Await()`, signals held by rollback regions, awaiter and waiter lists, and resume values
//! as reclamation roots, in both machines and the report replay.
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

test "the source contract's events: a waiter parks, a signal wakes it, and the result is awaited" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Log:[]string = array{}
        \\Note(S:string)<transacts>:void = Set(Log, Log + array{S})
        \\Gate:event(i64) = event(i64){}
        \\Waiter()<transacts><suspends>:i64 = Block{
        \\    Note("waiting")
        \\    Gate.Await()
        \\}
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Spawn{ Waiter() }
        \\    Gate.Signal(7)
        \\    Note("result {W.Await()}")
        \\}
        \\Started:task(void) = Spawn{ Main() }
    );
    try expectReport(x, "{\"Log\":[\"waiting\",\"result 7\"],\"Gate\":{\"$event\":{\"waiting\":0}},\"Started\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"$scheduler\":{\"tick_rate\":60,\"tick\":0,\"created\":2,\"completed\":2,\"canceled\":0,\"switches\":6,\"waiting\":[]}}\n");
}

fn expectFailure(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const p = try h.compile(source);
    const outcome = try h.run(p, concurrency.fuel);
    if (outcome != .failed) {
        std.debug.print("expected {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(code, outcome.failed.code);
    try std.testing.expectEqualStrings(at, p.source[outcome.failed.span.start..outcome.failed.span.end]);
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code or !std.mem.eql(u8, at, source[result.failed.span.start..result.failed.span.end])) std.debug.print("got {t} at '{s}' for {s}\n", .{ result.failed.code, source[result.failed.span.start..result.failed.span.end], source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

test "a Signal wakes every task waiting then, in the order they began to wait; one with no waiter is lost" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(string) = event(string){}
        \\Wait(N:i64)<transacts><suspends>:void = Block{ Print("w{N}"); V := E.Await(); Print("got{N} {V}") }
        \\Late()<transacts><suspends>:void = Block{ Sleep(1.0); Print("late"); V := E.Await(); Print("late {V}") }
        \\Main()<transacts><suspends>:void = Block{
        \\    A := Spawn{ Wait(1) }
        \\    B := Spawn{ Wait(2) }
        \\    C := Spawn{ Late() }
        \\    E.Signal("x")
        \\    Print("signalled")
        \\    E.Signal("lost")
        \\    Sleep(2.0)
        \\    E.Signal("y")
        \\}
        \\T:task(void) = Spawn{ Main() }
    );
    var buffer: [512]u8 = undefined;
    // Q1: both waiters, in FIFO order, after the signaller suspends (S4); the second signal
    // finds nobody; a task that waits only later gets the next one (api:8157).
    try std.testing.expectEqualStrings("w1\nw2\nsignalled\ngot1 x\ngot2 x\nlate\nlate y\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(u64, 120), x.scheduler.tick);
    try std.testing.expectEqual(@as(u64, 4), x.scheduler.completed);
}

test "Await is sticky, awaiters of one task resume in order with its result, and awaiting is not owning" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Work()<transacts><suspends>:i64 = Block{ Sleep(0.5); Print("work"); 42 }
        \\Watch(T:task(i64), N:i64)<transacts><suspends>:i64 = Block{ V := T.Await(); Print("watch{N} {V}"); V + N }
        \\Main()<transacts><suspends>:tuple(i64, i64, i64) = Block{
        \\    T := Spawn{ Work() }
        \\    A := Spawn{ Watch(T, 1) }
        \\    B := Spawn{ Watch(T, 2) }
        \\    X := T.Await()
        \\    Y := T.Await()
        \\    Print("main {X} {Y}")
        \\    tuple{X, Y, A.Await() + B.Await()}
        \\}
        \\M:task(tuple(i64, i64, i64)) = Spawn{ Main() }
    );
    var buffer: [512]u8 = undefined;
    // The three awaiters wake in the order they began to wait: A, B, then Main; the second
    // await of a completed task does not wait (14:926).
    try std.testing.expectEqualStrings("work\nwatch1 42\nwatch2 42\nmain 42 42\n", printed(x, &buffer));
    try expectReportContains(x, "\"M\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[42,42,87]}}");
}

fn expectReportContains(execution: evaluator.Execution, part: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), part) == null) {
        std.debug.print("report {s}\nlacks {s}\n", .{ out.buffered(), part });
        return error.TestUnexpectedResult;
    }
}

test "tasks waiting on an event or a task at quiescence are listed with what they wait for" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\Ear()<transacts><suspends>:i64 = E.Await()
        \\Watch(T:task(i64))<transacts><suspends>:i64 = Block{ Sleep(0.1); T.Await() }
        \\A:task(i64) = Spawn{ Ear() }
        \\B:task(i64) = Spawn{ Ear() }
        \\C:task(i64) = Spawn{ Watch(A) }
    );
    try std.testing.expectEqual(@as(usize, 3), x.scheduler.waiting.len);
    try std.testing.expectEqual(types.Scheduler.WaitKind.event, x.scheduler.waiting[0].wait);
    try std.testing.expectEqual(types.Scheduler.WaitKind.event, x.scheduler.waiting[1].wait);
    try std.testing.expectEqual(types.Scheduler.WaitKind.task, x.scheduler.waiting[2].wait);
    try std.testing.expectEqualStrings("Await", x.program.source[x.scheduler.waiting[2].span.start..x.scheduler.waiting[2].span.end]);
    // The event counts its waiters, which are abandoned with it.
    try expectReportContains(x, "\"E\":{\"$event\":{\"waiting\":2}}");
    try expectReportContains(x, "\"waiting\":[{\"task\":1,\"kind\":\"spawn\",\"wait\":\"event\",\"span\":[");
}

test "a Signal inside a rollback region happens when the outermost region commits, in order with spawns, and never when it fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\Ear(N:i64)<transacts><suspends>:void = Loop{ V := E.Await(); Print("ear{N} {V}") }
        \\Tell(V:i64)<transacts>:void = E.Signal(V)
        \\F(V:i64)<transacts><decides>:i64 = Block{ Tell(V); Print("told {V}"); Require[V > 0]; V }
        \\Body(N:i64)<transacts><suspends>:void = Print("task {N}")
        \\Main()<transacts><suspends>:void = Block{
        \\    A := Spawn{ Ear(1) }
        \\    X := Attempt(F[1], 0)
        \\    Print("after 1")
        \\    Sleep(0.0)
        \\    Y := Attempt(F[-2], 0)
        \\    Print("after -2")
        \\    Sleep(0.0)
        \\    Z := Attempt(Block{ Q := Attempt(F[3], 0); Spawn{ Body(4) }; Tell(5); Require[Q > 0]; Q }, 0)
        \\    Print("after 3")
        \\    Sleep(0.0)
        \\    Print("end")
        \\}
        \\T:task(void) = Spawn{ Main() }
        \\R:i64 = Attempt(F[7], 0)
    );
    var buffer: [1024]u8 = undefined;
    // F[1] signals at its commit, before "after 1": the ear wakes, and runs when Main next
    // waits. The root's signal of 7 comes while the ear is ready, not waiting, so it is lost.
    // F[-2] fails, and its output and signal never happen. In the nested case the inner
    // signal waits for the outer region; then that signal, the start and the second signal
    // follow in program order: the start runs at once, and the signal of 5 finds the ear
    // woken by 3 and not yet waiting again, so it is lost too.
    try std.testing.expectEqualStrings("told 1\nafter 1\ntold 7\near1 1\nafter -2\ntold 3\ntask 4\nafter 3\near1 3\nend\n", printed(x, &buffer));
}

test "every compile-time refusal of P3.2 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "W()<transacts><suspends>:i64 = 1\nE:event(i64) = event(i64){}\nT:task(i64) = Spawn{ W() }\n";
    var buffer: [512]u8 = undefined;
    const Case = struct { tail: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        // An await is a site: only a function that suspends waits, and not where its code must
        // finish at once; it reads, and a signal writes.
        .{ .tail = "F()<transacts>:i64 = T.Await()", .code = .call_requires_suspends, .at = "Await" },
        .{ .tail = "A:i64 = E.Await()", .code = .call_requires_suspends, .at = "Await" },
        .{ .tail = "F()<transacts><suspends>:i64 = Attempt(Block{ X := T.Await(); X }, 2)", .code = .suspends_in_failure_context, .at = "Await" },
        .{ .tail = "F()<transacts><suspends>:i64 = If(Block{ E.Await() > 0 }, 1, 2)", .code = .suspends_in_failure_context, .at = "Await" },
        .{ .tail = "F()<transacts><suspends>:i64 = Block{ Defer{ X := E.Await() }; 1 }", .code = .suspends_in_failure_context, .at = "Await" },
        .{ .tail = "F()<writes><suspends>:i64 = E.Await()", .code = .call_requires_reads, .at = "Await" },
        .{ .tail = "F()<reads>:void = E.Signal(1)", .code = .call_requires_writes, .at = "Signal" },
        .{ .tail = "F()<reads>:event(i64) = event(i64){}", .code = .construction_requires_allocates, .at = "event" },
        // Types: what a signal carries, what an await yields, and handles of their own type.
        .{ .tail = "A:void = E.Signal(\"x\")", .code = .type_mismatch, .at = "\"x\"" },
        .{ .tail = "F()<transacts><suspends>:string = E.Await()", .code = .type_mismatch, .at = "Await" },
        .{ .tail = "B:event(string) = E", .code = .type_mismatch, .at = "event" },
        .{ .tail = "B:logic = logic{E == E}", .code = .not_comparable, .at = "==" },
        .{ .tail = "B:any = any(E)", .code = .type_mismatch, .at = "event" },
        .{ .tail = "B:i64 = E.Waiting", .code = .unknown_field, .at = "Waiting" },
        .{ .tail = "B:void = E.Signal()", .code = .expected_expression, .at = ")" },
        .{ .tail = "B:void = T.Signal(1)", .code = .unknown_field, .at = "Signal" },
        // `event(T){}` builds one, with nothing in the braces; `event` is no function.
        .{ .tail = "B:event(i64) = event(i64){1}", .code = .unexpected_token, .at = "1" },
        .{ .tail = "B:i64 = Block{ X := event(1); 0 }", .code = .unknown_name, .at = "event" },
    }) |case| {
        const text = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, case.tail });
        try expectRefused(h, text, case.code, case.at);
    }
}

test "event, Await and Signal yield to whatever the program declares by those names" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try expectRun(h, "event := struct{ N:i64 }\nA:event = event{ N := 2 }\nB:i64 = A.N");
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
    x = try expectRun(h, "event(N:i64)<computes>:i64 = N + 1\nA:i64 = event(4)");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    x = try expectRun(h, "F()<transacts>:i64 = Block{ event:i64 = 4; event + 1 }\nA:i64 = F()");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    // An extension method of the receiver's type is what the name means (RFC-0077).
    x = try expectRun(h,
        \\(E:event(i64)).Signal(V:i64)<computes>:i64 = V * 10
        \\(T:task(i64)).Await()<computes>:i64 = 3
        \\W()<transacts><suspends>:i64 = 1
        \\E:event(i64) = event(i64){}
        \\T:task(i64) = Spawn{ W() }
        \\A:i64 = E.Signal(4) + T.Await()
    );
    try std.testing.expectEqual(@as(i64, 43), x.get("A").?.integer);
    // One declared for another receiver leaves the standard method in place.
    x = try expectRun(h,
        \\(S:string).Signal(V:i64)<computes>:i64 = V
        \\E:event(i64) = event(i64){}
        \\A:void = E.Signal(4)
        \\B:i64 = "x".Signal(2)
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
}

/// The first function whose body holds a node of `kind`, and the node's index in its body.
fn holding(p: types.Program, kind: std.meta.Tag(@FieldType(types.Node, "kind"))) struct { function: usize, at: usize } {
    for (p.functions, 0..) |f, id| for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
        if (entry.input == .operation and entry.node.kind == kind) return .{ .function = id, .at = index };
    };
    unreachable;
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

/// The index in the body of `function` of the last node before `before` whose type is `value_type`.
fn registerOf(p: types.Program, function: usize, before: usize, value_type: types.Type) ?u32 {
    const f = p.functions[function];
    var at = before;
    while (at != 0) {
        at -= 1;
        const entry = p.function_nodes[f.body.start + at];
        if (entry.node.value_type == value_type) return @intCast(at);
    }
    return null;
}

test "forged awaits, signals and events are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\E:event(i64) = event(i64){}
        \\Use(T:task(i64), N:i64, S:string)<transacts><suspends>:i64 = Block{ Print("{N}{S}"); X := T.Await(); Y := E.Await(); E.Signal(N); F := event(string){}; X + Y + N }
        \\W()<transacts><suspends>:i64 = 1
        \\T:task(i64) = Spawn{ W() }
        \\U:task(i64) = Spawn{ Use(T, 2, "s") }
    ;
    const p = try h.compile(source);
    _ = try expectRun(h, source);
    var forged = forgeable(h, p);
    const awaited = holding(p, .task_await);
    const waited = holding(p, .event_await);
    const signal = holding(p, .event_signal);
    const built = holding(p, .event_new);
    const base = p.functions[awaited.function].body.start;
    const task_await = p.function_nodes[base + awaited.at].node;
    const event_await = p.function_nodes[base + waited.at].node;
    const event_signal = p.function_nodes[base + signal.at].node;
    const event_new = p.function_nodes[base + built.at].node;
    const string_register = registerOf(p, awaited.function, awaited.at, .string).?;
    const integer_register = registerOf(p, awaited.function, awaited.at, .i64).?;
    const Forgery = struct { at: usize, node: types.Node };
    var cases: [16]Forgery = undefined;
    var count: usize = 0;
    // `task_await` of a value that is no handle, of an event, and yielding another type.
    var node = task_await;
    node.kind.task_await = string_register;
    cases[count] = .{ .at = awaited.at, .node = node };
    count += 1;
    node = task_await;
    node.kind.task_await = event_await.kind.event_await;
    cases[count] = .{ .at = awaited.at, .node = node };
    count += 1;
    node = task_await;
    node.value_type = .string;
    cases[count] = .{ .at = awaited.at, .node = node };
    count += 1;
    // `event_await` of a handle, of an integer, and yielding another type.
    node = event_await;
    node.kind.event_await = task_await.kind.task_await;
    cases[count] = .{ .at = waited.at, .node = node };
    count += 1;
    node = event_await;
    node.kind.event_await = integer_register;
    cases[count] = .{ .at = waited.at, .node = node };
    count += 1;
    node = event_await;
    node.value_type = .float;
    cases[count] = .{ .at = waited.at, .node = node };
    count += 1;
    // `event_signal` with a value of another type, on a handle, and not of the unit type.
    node = event_signal;
    node.kind.event_signal.value = string_register;
    cases[count] = .{ .at = signal.at, .node = node };
    count += 1;
    node = event_signal;
    node.kind.event_signal.event = task_await.kind.task_await;
    cases[count] = .{ .at = signal.at, .node = node };
    count += 1;
    node = event_signal;
    node.value_type = .i64;
    cases[count] = .{ .at = signal.at, .node = node };
    count += 1;
    // `event_new` of a type that is no event: a handle type and a scalar.
    node = event_new;
    node.value_type = p.nodes[0].value_type;
    for (p.nodes) |root| if (root.kind == .spawn) {
        node.value_type = root.value_type;
    };
    cases[count] = .{ .at = built.at, .node = node };
    count += 1;
    node = event_new;
    node.value_type = .i64;
    cases[count] = .{ .at = built.at, .node = node };
    count += 1;
    for (cases[0..count]) |case| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        h.body[base + case.at].node = case.node;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("forged {any} admitted\n", .{case.node.kind});
            return err;
        };
    }
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    // An await without its check after it.
    h.body[base + awaited.at + 1].node.kind = .{ .boolean = false };
    try harness.invalid(h, forged);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    // The effects of admission rule 5: each operation in a function that lacks its effect.
    for ([_]types.EffectDetail{
        .{ .no_reads = true, .suspends = true },
        .{ .no_writes = true, .suspends = true },
        .{ .no_allocates = true, .suspends = true },
        .{},
    }) |detail| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        h.metadata[awaited.function].transacts = true;
        h.metadata[awaited.function].detail = detail;
        try harness.invalid(h, forged);
    }
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    _ = &forged;
}

test "forged sites of P3.2 at the root, and forged uses of handles and events as classes, are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Box := class{ var N:i64 = 0 }
        \\E:event(i64) = event(i64){}
        \\W()<transacts><suspends>:i64 = 1
        \\T:task(i64) = Spawn{ W() }
        \\B:Box = Box{}
        \\A:i64 = 3
        \\G:i64 = B.N
        \\Q:any = any(5)
        \\L:logic = true
    ;
    const p = try h.compile(source);
    _ = try expectRun(h, source);
    var nodes: [256]types.Node = undefined;
    var forged = p;
    forged.nodes = nodes[0..p.nodes.len];
    const none = std.math.maxInt(u32);
    var event: u32 = none;
    var handle: u32 = none;
    var three: u32 = none;
    var read: u32 = none;
    var widened: u32 = none;
    var truth: u32 = none;
    for (p.nodes, 0..) |node, index| switch (node.kind) {
        .event_new => event = @intCast(index),
        .spawn => handle = @intCast(index),
        .integer => |value| if (value == 3) {
            three = @intCast(index);
        },
        .object_get => read = @intCast(index),
        .upcast => widened = @intCast(index),
        .boolean => truth = @intCast(index),
        else => {},
    };
    if (!(event != none and handle != none and three != none and read != none and widened != none and truth != none)) {
        for (p.nodes, 0..) |node, index| std.debug.print("{d}: {any}\n", .{ index, node.kind });
        return error.TestUnexpectedResult;
    }
    const Change = struct { at: u32, node: types.Node };
    const at_three = p.nodes[three];
    const at_read = p.nodes[read];
    for ([_]Change{
        // Root code holds no site.
        .{ .at = three, .node = .{ .span = at_three.span, .value_type = .i64, .kind = .{ .event_await = event } } },
        .{ .at = three, .node = .{ .span = at_three.span, .value_type = .i64, .kind = .{ .task_await = handle } } },
        // A handle and an event are no instances of a class: no field is read from either.
        .{ .at = read, .node = .{ .span = at_read.span, .value_type = .i64, .kind = .{ .object_get = .{ .value = event, .index = 0 } } } },
        .{ .at = read, .node = .{ .span = at_read.span, .value_type = .i64, .kind = .{ .object_get = .{ .value = handle, .index = 0 } } } },
        // No cast reaches or leaves one.
        .{ .at = widened, .node = .{ .span = at_read.span, .value_type = types.Type.any, .kind = .{ .upcast = event } } },
        .{ .at = widened, .node = .{ .span = at_read.span, .value_type = types.Type.any, .kind = .{ .upcast = handle } } },
        .{ .at = truth, .node = .{ .span = at_read.span, .value_type = .logic, .kind = .{ .instance_of = .{ .value = widened, .class = p.nodes[event].value_type } } } },
    }) |change| {
        @memcpy(nodes[0..p.nodes.len], p.nodes);
        nodes[change.at] = change.node;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("forged root {any} admitted\n", .{change.node.kind});
            return err;
        };
    }
    // A second definition of the same event type, and one of a type that is not earlier.
    var definitions: [64]types.Definition = undefined;
    @memcpy(definitions[0..p.definitions.len], p.definitions);
    const event_type = p.nodes[event].value_type;
    const shape = catalogue.definition(event_type, p.definitions).?;
    var twice = p;
    definitions[p.definitions.len] = shape;
    twice.definitions = definitions[0 .. p.definitions.len + 1];
    try harness.invalid(h, twice);
    definitions[p.definitions.len] = .{ .event = .{ .value = @fromBackingInt(@intCast(p.definitions.len + 4 + 5)) } };
    try harness.invalid(h, twice);
}

test "a forged schedule of events and awaits is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\Ear(N:i64)<transacts><suspends>:i64 = E.Await() + N
        \\Other(N:i64)<transacts><suspends>:i64 = E.Await() * N
        \\Main()<transacts><suspends>:i64 = Block{ A := Spawn{ Ear(1) }; B := Spawn{ Other(2) }; E.Signal(10); A.Await() + B.Await() }
        \\M:task(i64) = Spawn{ Main() }
    );
    _ = try reporting.validate(x, false, .{});
    const steps = x.call_steps;
    const Forgery = enum { resume_value, swapped, suspend_value, waiting_count, settle_value, cells };
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var cells: [64]@import("source_state.zig").Cell = undefined;
        var done = false;
        for (h.steps[0..steps.len], 0..) |*step, index| {
            if (done) break;
            switch (forgery) {
                .resume_value => if (step.kind == .@"resume" and step.value == .integer) {
                    step.value.integer += 1;
                    done = true;
                },
                .swapped => if (step.kind == .@"resume" and index + 1 < steps.len) {
                    // The two ears woken by one signal, resumed in the other order.
                    var other = index + 1;
                    while (other < steps.len and h.steps[other].kind != .@"resume") other += 1;
                    if (other < steps.len) {
                        std.mem.swap(types.CallStep, step, &h.steps[other]);
                        done = true;
                    }
                },
                .suspend_value => if (step.kind == .@"suspend" and step.value == .object) {
                    step.value = .{ .boolean = false };
                    done = true;
                },
                .settle_value => if (step.kind == .settle and step.value == .integer) {
                    step.value.integer += 1;
                    done = true;
                },
                .waiting_count => {
                    forged.scheduler.switches += 2;
                    done = true;
                },
                .cells => {
                    // The event's count of waiters, which the replay works out too.
                    @memcpy(cells[0..x.object_cells.len], x.object_cells);
                    for (x.object_cells, 0..) |cell, at| if (cell.value == .integer and cell.value.integer == @backingInt(x.program.nodes[0].value_type)) {
                        cells[at + 1].value.integer = 1;
                        cells[at + 2].value.integer = 1;
                        cells[at + 3].value.integer = 1;
                        break;
                    };
                    forged.object_cells = cells[0..x.object_cells.len];
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

test "the same event program needs the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "E:event(i64) = event(i64){}\nEar(N:i64)<transacts><suspends>:i64 = E.Await() + N\nMain()<transacts><suspends>:i64 = Block{ A := Spawn{ Ear(1) }; B := Spawn{ Ear(2) }; C := Spawn{ Ear(3) }; E.Signal(10); A.Await() + B.Await() + C.Await() }\nM:task(i64) = Spawn{ Main() }",
        "E:event(i64) = event(i64){}\nTell(V:i64)<transacts>:void = E.Signal(V)\nF(V:i64)<transacts><decides>:i64 = Block{ Tell(V); Spawn{ Print(\"t{V}\") }; Tell(V + 1); Require[V > 0]; V }\nEar()<transacts><suspends>:void = Loop{ V := E.Await(); Print(\"e{V}\") }\nA:task(void) = Spawn{ Ear() }\nB:i64 = Attempt(F[1], 0)\nC:i64 = Attempt(F[-1], 0)",
        "E:event(string) = event(string){}\nPing(N:i64)<transacts><suspends>:void = Block{ var I:i64 = 0; Loop{ If(I >= N, Break(), false); E.Signal(\"p{I}\"); Sleep(0.0); set I = I + 1 } }\nPong()<transacts><suspends>:void = Loop{ V := E.Await(); Print(V) }\nA:task(void) = Spawn{ Pong() }\nB:task(void) = Spawn{ Ping(4) }",
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

test "values a signal or an awaited task hands on are roots: a digest run that reclaims reports as a stored one" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\E:event([]i64) = event([]i64){}
        \\S:event(string) = event(string){}
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Send(N:i64)<transacts>:i64 = Block{ J := Many(6); E.Signal(array{N, N + 1, N + 2}); S.Signal("s{N}"); J }
        \\Held(N:i64)<transacts><decides>:i64 = Block{ J := Send(N); Require[N > 0]; J }
        \\Ear()<transacts><suspends>:void = Loop{ Xs := E.Await(); Print("{Attempt(Xs[0], -1)} {Xs.Length}") }
        \\Word()<transacts><suspends>:void = Loop{ W := S.Await(); Print(W) }
        \\Make(N:i64)<transacts><suspends>:[]i64 = Block{ Sleep(0.1); J := Many(4); array{N, J} }
        \\Main()<transacts><suspends>:void = Block{
        \\    A := Spawn{ Ear() }
        \\    B := Spawn{ Word() }
        \\    var I:i64 = 0
        \\    Loop{ If(I >= 3, Break(), false); Sleep(0.1); J1 := Attempt(Held[I], 0); J2 := Send(I); set I = I + 1 }
        \\    T := Spawn{ Make(7) }
        \\    R := T.Await()
        \\    Print("made {Attempt(R[0], -1)}")
        \\}
        \\M:task(void) = Spawn{ Main() }
    ;
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const stored = (try f.h.run(p, concurrency.fuel)).ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = out.buffered();
    var lines: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("0 3\ns0\n1 3\ns1\n2 3\ns2\nmade 7\n", printed(stored, &lines));
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

/// Scale test 3 (RFC-0082): two tasks hand a value back and forth through two events, four
/// switches a round (a save and a restore of each); `rounds` of 250,000 make a million.
/// Prints how long each machine and the replay took.
/// The runs are `digest` runs, whose steps the replay reads from a second run, as a long run
/// would be: a stored trace of a million switches would not fit.
pub fn pingPong(f: trace_replay.Fixture, rounds: u64) !void {
    const h = f.h;
    var buffer: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&buffer,
        \\A:event(i64) = event(i64){{}}
        \\B:event(i64) = event(i64){{}}
        \\var Sent:i64 = 0
        \\var Sum:i64 = 0
        \\var Seen:i64 = 0
        \\Ping(N:i64)<transacts><suspends>:i64 = Block{{ Loop{{ If(Sent >= N, Break(), false); A.Signal(Sent); set Sum = Sum + B.Await(); set Sent = Sent + 1 }}; Sum }}
        \\Pong(N:i64)<transacts><suspends>:i64 = Block{{ Loop{{ If(Seen >= N, Break(), false); B.Signal(A.Await() + 1); set Seen = Seen + 1 }}; Seen }}
        \\Q:task(i64) = Spawn{{ Pong({d}) }}
        \\P:task(i64) = Spawn{{ Ping({d}) }}
    , .{ rounds, rounds });
    const p = try h.compile(source);
    const budget: u64 = 1 << 40;
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("ping-pong failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    try std.testing.expectEqual(4 * rounds + 2, actual.ok.scheduler.switches);
    try std.testing.expectEqual(@as(u64, 2), actual.ok.scheduler.completed);
    _ = try reporting.validateReplayed(actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("{d} switches through two events, {d} members: reference={d}ms vm={d}ms replay={d}ms\n", .{ actual.ok.scheduler.switches, actual.ok.aggregate_values.len, referenced, ran - referenced, elapsed(start) - ran });
    var report: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    var expected: [128]u8 = undefined;
    const sum = try std.fmt.bufPrint(&expected, "\"P\":{{\"$task\":{{\"sequence\":2,\"state\":\"completed\",\"result\":{d}}}}}", .{rounds * (rounds + 1) / 2});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), sum) != null);
}

test "two tasks hand a value back and forth through two events, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try pingPong(f, 1000);
}

test "review D1: E1 and E4 hold where the program declares something else named Spawn" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [256]u8 = undefined;
    // A field, a parameter and a named argument called `Spawn` leave `Spawn{` the form: copies
    // of a `Defer` body still name their task bodies apart, and a body is still a scope.
    for ([_][]const u8{
        "R := struct{ Spawn:i64 }\n",
        "G(Spawn:i64)<computes>:i64 = Spawn + 1\nN:i64 = G(Spawn := 2)\n",
        "Box := class{ var Spawn:i64 = 0 }\n",
    }) |head| {
        var source: [512]u8 = undefined;
        var x = try expectRun(h, try std.fmt.bufPrint(&source, "{s}F(K:i64)<transacts>:i64 = Block{{ Defer{{ T := Spawn{{ Print(\"d{{K}}\") }} }}; If(K > 0, Return(K), 0); 7 }}\nA:i64 = F(1)\nB:i64 = F(0)", .{head}));
        try std.testing.expectEqualStrings("d1\nd0\n", printed(x, &buffer));
        x = try expectRun(h, try std.fmt.bufPrint(&source, "{s}A:task(i64) = Spawn{{ Defer{{ Print(\"d\") }}; Sleep(0.5); Print(\"b\"); 1 }}", .{head}));
        try std.testing.expectEqualStrings("b\nd\n", printed(x, &buffer));
        // The parser still refuses an exit that would leave a body.
        try expectRefused(h, try std.fmt.bufPrint(&source, "{s}F(K:i64)<transacts>:i64 = Block{{ T := Spawn{{ For(I:0..K, If(I > 1, Return(I), I)); 0 }}; 1 }}\nA:i64 = F(1)", .{head}), .return_in_task_body, "For");
    }
    // And a class named `Spawn`, built in a `Defer` copied to two exits, is built by each copy.
    const x = try expectRun(h, "Spawn := class{ var N:i64 = 0 }\nvar C:i64 = 0\nF(K:i64)<transacts>:i64 = Block{ Defer{ S := Spawn{ N := K }; set C = C + S.N }; If(K > 0, Return(K), 0); 7 }\nA:i64 = F(3)\nB:i64 = F(0)\nD:i64 = C");
    try std.testing.expectEqual(@as(i64, 3), x.get("D").?.integer);
}

/// A program whose function `F` holds `signals` signals in one rollback region, after a held
/// start when `with_start`, called at the root or (`in_task`) from a task.
fn heldActions(buffer: []u8, signals: usize, with_start: bool, in_task: bool) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    try out.writeAll("E:event(i64) = event(i64){}\nF()<transacts><decides>:i64 = Block{ ");
    if (with_start) try out.writeAll("Spawn{ Print(\"s\") }; ");
    for (0..signals) |_| try out.writeAll("E.Signal(1); ");
    try out.writeAll("1 }\n");
    if (in_task) {
        try out.writeAll("G()<transacts><suspends>:i64 = Attempt(F[], 0)\nT:task(i64) = Spawn{ G() }");
    } else try out.writeAll("U:task(i64) = Spawn{ 0 }\nA:i64 = Attempt(F[], 0)");
    return out.buffered();
}

test "scheduler_action_limit falls at the action one past the capacity, at the root and in a task" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [8192]u8 = undefined;
    const limit: usize = types.limits.scheduler_actions;
    // Signals alone, and signals after a held start, all held by one region: at the capacity
    // both machines run; one more is the fatal error at the `Signal` that would exceed it.
    for ([_]bool{ false, true }) |in_task| for ([_]bool{ false, true }) |with_start| {
        const actions = if (with_start) limit - 1 else limit;
        _ = try expectRun(h, try heldActions(&buffer, actions, with_start, in_task));
        try expectFailure(h, try heldActions(&buffer, actions + 1, with_start, in_task), .scheduler_action_limit, "Signal");
    };
}
