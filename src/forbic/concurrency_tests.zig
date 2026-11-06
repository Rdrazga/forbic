//! Structured concurrency, P3.1 (RFC-0082): `Spawn`, `Sleep`, task handles, the check after
//! every site, and the scheduler, in both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

pub const fuel: u64 = 1 << 20;

/// What a run printed, a line each, from a `full` run's kept output.
pub fn printed(execution: evaluator.Execution, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (0..execution.effects.entries.len) |index| writer.print("{s}\n", .{execution.effects.text(index)}) catch unreachable;
    return writer.buffered();
}

/// Runs `source` on both machines through the harness, which compares them and admits the
/// report of each by the replay; returns the VM's run.
pub fn expectRun(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const p = try h.compile(source);
    const outcome = try h.run(p, fuel);
    if (outcome == .failed) {
        std.debug.print("run failed: {t} at {d}: {s}\n", .{ outcome.failed.code, outcome.failed.span.start, source });
        return error.RunFailed;
    }
    return outcome.ok;
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
}

fn expectFailure(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const p = try h.compile(source);
    const outcome = try h.run(p, fuel);
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
    if (result.failed.code != code) std.debug.print("got {t} for {s}\n", .{ result.failed.code, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

test "a spawn hands off at once, the root goes first, and the clock wakes timers in registration order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Child(N:i64)<transacts><suspends>:i64 = Block{ Print("child {N} start"); Sleep(0.0); Print("child {N} end"); N }
        \\Parent()<transacts><suspends>:void = Block{
        \\    Print("parent")
        \\    A := Spawn{ Child(1) }
        \\    Print("after 1")
        \\    B := Spawn{ Child(2) }
        \\    Print("after 2")
        \\    Sleep(1.0)
        \\    Print("parent end")
        \\}
        \\P:task(void) = Spawn{ Parent() }
        \\R:i64 = Block{ Print("root"); 7 }
    );
    var buffer: [512]u8 = undefined;
    // S1 the root first, S2 hand-off: each child runs until it first waits, before its
    // creator goes on; S3 the clock jumps to the next deadline; S6 equal deadlines in order.
    try std.testing.expectEqualStrings("parent\nchild 1 start\nafter 1\nchild 2 start\nafter 2\nroot\nchild 1 end\nchild 2 end\nparent end\n", printed(x, &buffer));
    // Three starts, three saves and three restores.
    try std.testing.expectEqualDeep(types.Scheduler{ .tick = 60, .created = 3, .completed = 3, .switches = 9 }, x.scheduler);
    try expectReport(x, "{\"P\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":[]}},\"R\":7,\"$scheduler\":{\"tick_rate\":60,\"tick\":60,\"created\":3,\"completed\":3,\"canceled\":0,\"switches\":9,\"waiting\":[]}}\n");
}

test "the cells a task wrote after the root are reported as they ended, and handles with their results" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\var Log:[]string = array{}
        \\Note(S:string)<transacts>:void = Set(Log, Log + array{S})
        \\Work(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.5); Note("work {N}"); N * 2 }
        \\Start(N:i64)<transacts>:task(i64) = Spawn{ Work(N) }
        \\A:task(i64) = Start(3)
        \\B:task(i64) = Start(4)
        \\Seen:[]string = Log
    );
    try std.testing.expectEqualDeep(types.Scheduler{ .tick = 30, .created = 2, .completed = 2, .switches = 6 }, x.scheduler);
    try expectReport(x, "{\"Log\":[\"work 3\",\"work 4\"],\"A\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":6}},\"B\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":8}},\"Seen\":[],\"$scheduler\":{\"tick_rate\":60,\"tick\":30,\"created\":2,\"completed\":2,\"canceled\":0,\"switches\":6,\"waiting\":[]}}\n");
}

test "Sleep by its duration: NaN, negative, zeros, a tick and a half, infinity and more ticks than the clock has" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { seconds: []const u8, tick: u64, switches: u64, waits: bool };
    for ([_]Case{
        .{ .seconds = "-1.0", .tick = 0, .switches = 1, .waits = false },
        .{ .seconds = "-Inf", .tick = 0, .switches = 1, .waits = false },
        .{ .seconds = "-0.0", .tick = 1, .switches = 3, .waits = false },
        .{ .seconds = "0.0", .tick = 1, .switches = 3, .waits = false },
        .{ .seconds = "1.0 / 60.0", .tick = 1, .switches = 3, .waits = false },
        .{ .seconds = "1.5 / 60.0", .tick = 2, .switches = 3, .waits = false },
        .{ .seconds = "0.000001", .tick = 1, .switches = 3, .waits = false },
        .{ .seconds = "2.5", .tick = 150, .switches = 3, .waits = false },
        .{ .seconds = "Inf", .tick = 0, .switches = 2, .waits = true },
        .{ .seconds = "1.0e300", .tick = 0, .switches = 2, .waits = true },
        // ceil(S * 60) is 2^62 exactly: never, by the one rule of "Time".
        .{ .seconds = "76861433640456465.0666", .tick = 0, .switches = 2, .waits = true },
    }) |case| {
        var source: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "Nap()<transacts><suspends>:void = Sleep({s})\nT:task(void) = Spawn{{ Nap() }}", .{case.seconds});
        const x = try expectRun(h, text);
        try std.testing.expectEqual(case.tick, x.scheduler.tick);
        try std.testing.expectEqual(case.switches, x.scheduler.switches);
        try std.testing.expectEqual(@as(usize, @intFromBool(case.waits)), x.scheduler.waiting.len);
        try std.testing.expectEqual(@as(u64, @intFromBool(!case.waits)), x.scheduler.completed);
        if (case.waits) {
            const waiting = x.scheduler.waiting[0];
            try std.testing.expectEqual(@as(u64, 1), waiting.task);
            try std.testing.expectEqual(types.Scheduler.WaitKind.sleep, waiting.wait);
            try std.testing.expectEqualStrings("Sleep", text[waiting.span.start..waiting.span.end]);
        }
    }
    try expectFailure(h, "Nap()<transacts><suspends>:void = Sleep(NaN)\nT:task(void) = Spawn{ Nap() }", .invalid_sleep_duration, "Sleep");
    // The tick rate is the run's: at 1000 ticks a second, 2.5 seconds are 2500 ticks.
    h.control.tick_rate = 1000;
    h.runtime.machine.control.tick_rate = 1000;
    defer {
        h.control.tick_rate = types.Scheduler.default_tick_rate;
        h.runtime.machine.control.tick_rate = types.Scheduler.default_tick_rate;
    }
    const fast = try expectRun(h, "Nap()<transacts><suspends>:void = Sleep(2.5)\nT:task(void) = Spawn{ Nap() }");
    try std.testing.expectEqualDeep(types.Scheduler{ .tick_rate = 1000, .tick = 2500, .created = 1, .completed = 1, .switches = 3 }, fast.scheduler);
}

test "a spawn inside a rollback region starts when the outermost region commits, and never when it fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Body(N:i64)<transacts><suspends>:void = Print("task {N}")
        \\F(N:i64)<transacts><decides>:i64 = Block{ Spawn{ Body(N) }; Print("in {N}"); Require[N > 0]; N }
        \\A:i64 = Attempt(F[1], -1)
        \\B:i64 = Attempt(F[0], -1)
        \\C:i64 = Attempt(Block{ X := Attempt(F[2], -1); Print("outer"); Y := Attempt(F[0], -1); X + Y }, -1)
        \\D:i64 = Attempt(Block{ X := F[3]; Require[false]; X }, -9)
        \\E:i64 = Attempt(F[4], -1)
    );
    var buffer: [512]u8 = undefined;
    // A failed region drops its starts with its output; their handles and sequence numbers are
    // given back, so the task of `C` is the second one.
    try std.testing.expectEqualStrings("in 1\ntask 1\nin 2\nouter\ntask 2\nin 4\ntask 4\n", printed(x, &buffer));
    try std.testing.expectEqualDeep(types.Scheduler{ .created = 3, .completed = 3, .switches = 3 }, x.scheduler);
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -9), x.get("D").?.integer);
    // Starts committed together take their turns in order, each until it first waits.
    const y = try expectRun(h,
        \\Body(N:i64)<transacts><suspends>:void = Block{ Print("start {N}"); Sleep(1.0); Print("end {N}") }
        \\Two()<transacts><decides>:i64 = Block{ Spawn{ Body(1) }; Spawn{ Body(2) }; Print("held"); 0 }
        \\Run()<transacts><suspends>:void = Block{ X := Attempt(Two[], -1); Print("after commit") }
        \\T:task(void) = Spawn{ Run() }
    );
    try std.testing.expectEqualStrings("held\nstart 1\nstart 2\nafter commit\nend 1\nend 2\n", printed(y, &buffer));
}

test "tasks still waiting at quiescence are listed by sequence and abandoned" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Forever(N:i64)<transacts><suspends>:i64 = Block{ Sleep(Inf); N }
        \\Brief()<transacts><suspends>:i64 = Block{ Sleep(0.25); 1 }
        \\A:task(i64) = Spawn{ Forever(1) }
        \\B:task(i64) = Spawn{ Brief() }
        \\C:task(i64) = Spawn{ Forever(3) }
    );
    try std.testing.expectEqual(@as(usize, 2), x.scheduler.waiting.len);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.waiting[0].task);
    try std.testing.expectEqual(@as(u64, 3), x.scheduler.waiting[1].task);
    try std.testing.expectEqualDeep(types.Scheduler{ .tick = 15, .created = 3, .completed = 1, .switches = 7, .waiting = x.scheduler.waiting }, x.scheduler);
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"A\":{\"$task\":{\"sequence\":1,\"state\":\"active\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"waiting\":[{\"task\":1,\"kind\":\"spawn\",\"wait\":\"sleep\",\"span\":[") != null);
}

test "every compile-time refusal of P3.1 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    // Sites stand only in a function that suspends, and not where code must finish at once.
    try expectRefused(h, "Nap()<transacts>:void = Sleep(1.0)", .call_requires_suspends, "Sleep");
    try expectRefused(h, "A:void = Sleep(1.0)", .call_requires_suspends, "Sleep");
    try expectRefused(h, "F()<transacts><suspends>:i64 = Attempt(Block{ Sleep(1.0); 1 }, 2)", .suspends_in_failure_context, "Sleep");
    try expectRefused(h, "F()<transacts><suspends>:i64 = If(Block{ Sleep(1.0); true }, 1, 2)", .suspends_in_failure_context, "Sleep");
    try expectRefused(h, "F()<transacts><suspends>:i64 = Block{ Defer{ Sleep(1.0) }; 1 }", .suspends_in_failure_context, "Sleep");
    try expectRefused(h, "F()<transacts><suspends>:i64 = Block{ Sleep(1); 1 }", .type_mismatch, "1");
    // A spawn builds its handle; its body is a task's, which has no caller to return to, no
    // failure context, and copies of the locals around it.
    try expectRefused(h, "F()<reads>:i64 = Block{ T := Spawn{ 1 }; 0 }", .construction_requires_allocates, "Spawn");
    try expectRefused(h, "F()<transacts>:i64 = Block{ T := Spawn{ Return(1) }; 0 }", .return_in_task_body, "Return");
    // RFC-0085, I5: a local `var` the body assigns is shared (`shared_local_task_tests.zig`).
    try expectRefused(h, "F()<transacts>:i64 = Block{ X:i64 = 1; T := Spawn{ set X = 2; X }; X }", .arm_assigns_local, "X");
    try expectRefused(h, "F(X:i64)<transacts>:i64 = Block{ T := Spawn{ Set(X, 2) }; X }", .arm_assigns_local, "X");
    try expectRefused(h, "G()<computes><decides>:i64 = 1\nF()<transacts>:i64 = Block{ T := Spawn{ G[] }; 0 }", .failure_context_required, "G");
    // `Spawn` takes braces and `task` is a type.
    try expectRefused(h, "A:i64 = Block{ X := Spawn(1); 0 }", .unknown_name, "Spawn");
    try expectRefused(h, "A:i64 = Block{ X := task(1); 0 }", .unknown_name, "task");
    // A handle is of its task type, takes no cast and has no equality.
    try expectRefused(h, "W()<transacts><suspends>:i64 = 1\nA:task(i64) = Spawn{ W() }\nB:task(string) = A", .type_mismatch, "Spawn");
    try expectRefused(h, "W()<transacts><suspends>:i64 = 1\nA:task(i64) = Spawn{ W() }\nB:any = any(A)", .type_mismatch, "Spawn");
    try expectRefused(h, "W()<transacts><suspends>:i64 = 1\nA:task(i64) = Spawn{ W() }\nB:logic = logic{A == A}", .not_comparable, "==");
    try expectRefused(h, "W()<transacts><suspends>:i64 = 1\nA:task(i64) = Spawn{ W() }\nB:i64 = A.Sequence", .unknown_field, "Sequence");
}

test "Sleep, Spawn and task yield to whatever the program declares by those names" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try expectRun(h, "Sleep(X:float)<computes>:float = X * 2.0\nA:float = Sleep(1.5)");
    try std.testing.expectEqual(@as(f64, 3.0), x.get("A").?.floating);
    x = try expectRun(h, "F()<transacts>:i64 = Block{ Sleep:i64 = 4; Sleep + 1 }\nA:i64 = F()");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    x = try expectRun(h, "Spawn := class{ var N:i64 = 3 }\nA:Spawn = Spawn{}\nB:i64 = Block{ var C:i64 = 0; 1 }");
    try std.testing.expectEqualDeep(types.Scheduler{}, x.scheduler);
    x = try expectRun(h, "task := struct{ N:i64 }\nA:task = task{ N := 2 }\nB:i64 = A.N");
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
    // A declaration further down gives the name its meaning above it too.
    try expectRefused(h, "A:void = Sleep(1.0)\nSleep(X:float)<computes>:void = X", .unknown_name, "Sleep");
    // From a body it is in reach (RFC-0091): the call is the program's `Sleep`.
    x = try expectRun(h, "F()<transacts>:i64 = Block{ Sleep(1.0); 7 }\nSleep(X:float)<computes>:void = X\nA:i64 = F()");
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
}

/// The body of the first function that holds a `sleep`, and the index of the sleep in it.
fn sleeper(p: types.Program) struct { function: usize, site: usize } {
    for (p.functions, 0..) |f, id| for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
        if (entry.input == .operation and entry.node.kind == .sleep) return .{ .function = id, .site = index };
    };
    unreachable;
}

test "forged sites, checks and spawns are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Nap(S:float)<transacts><suspends>:i64 = Block{ Sleep(S); X := 41; X + 1 }
        \\Z:i64 = 3
        \\T:task(i64) = Spawn{ Nap(0.5) }
    ;
    const p = try h.compile(source);
    _ = try expectRun(h, source);
    const found = sleeper(p);
    const f = p.functions[found.function];
    const at = f.body.start + found.site;
    var forged = p;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    const reset = struct {
        fn run(target: *harness.Harness, original: types.Program) void {
            @memcpy(target.body[0..original.function_nodes.len], original.function_nodes);
        }
    }.run;
    const check = p.function_nodes[at + 2].node.kind.if_begin;
    // The shape the site must be followed by: each node of it replaced or moved.
    reset(h, p);
    h.body[at + 1].node.kind = .{ .boolean = false };
    try harness.invalid(h, forged);
    reset(h, p);
    h.body[at + 2].node.kind.if_begin.condition = @intCast(found.site);
    try harness.invalid(h, forged);
    reset(h, p);
    h.body[f.body.start + check.alternative - 1].node.kind = .{ .boolean = false };
    h.body[f.body.start + check.alternative - 1].node.value_type = p.function_nodes[at].node.value_type;
    try harness.invalid(h, forged);
    reset(h, p);
    h.body[f.body.start + check.end].node.kind.merge.right = check.alternative - 1;
    try harness.invalid(h, forged);
    reset(h, p);
    h.body[f.body.start + check.end].node.kind.merge.left = @intCast(found.site);
    try harness.invalid(h, forged);
    // A second reader of the site's register, and a site whose register is read past its check.
    for (p.function_nodes[at + 1 .. f.body.end], at + 1..) |entry, index| {
        if (entry.input != .operation or entry.node.kind != .merge or entry.node.kind.merge.right != found.site) continue;
        for (p.function_nodes[index + 1 .. f.body.end], index + 1..) |later, position| {
            if (later.input == .operation and later.node.kind == .local_set) {
                reset(h, p);
                h.body[position].node.kind.local_set = @intCast(found.site);
                if (p.function_nodes[at].node.value_type == later.node.value_type) try harness.invalid(h, forged);
            }
        }
    }
    // `canceling` and `cancel_exit` stand nowhere but in a check.
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| {
        if (entry.input != .operation or index == at + 1) continue;
        if (entry.node.value_type == .logic and entry.node.kind == .boolean) {
            reset(h, p);
            h.body[index].node.kind = .canceling;
            try harness.invalid(h, forged);
        }
        if (entry.node.kind == .integer and entry.node.value_type == .i64) {
            reset(h, p);
            h.body[index].node.kind = .cancel_exit;
            try harness.invalid(h, forged);
        }
    }
    // `sleep` of an integer.
    for (p.function_nodes[f.body.start..at], f.body.start..) |entry, index| if (entry.node.value_type == .i64) {
        reset(h, p);
        h.body[at].node.kind.sleep = @intCast(index - f.body.start);
        try harness.invalid(h, forged);
        break;
    };
    // A site in a function that does not suspend.
    reset(h, p);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[found.function].detail.suspends = false;
    var forged_set = p;
    forged_set.functions = h.metadata[0..p.functions.len];
    try harness.invalid(h, forged_set);
    // A spawn typed as the handle of another result, or of a closure that does not suspend.
    var nodes: [256]types.Node = undefined;
    @memcpy(nodes[0..p.nodes.len], p.nodes);
    var forged_root = p;
    forged_root.nodes = nodes[0..p.nodes.len];
    for (p.nodes, 0..) |node, index| if (node.kind == .spawn) {
        for (p.definitions, 0..) |definition, id| if (definition == .option) {
            nodes[index].value_type = @fromBackingInt(@intCast(id + 4));
            try harness.invalid(h, forged_root);
        };
        nodes[index] = node;
        nodes[index].kind.spawn = 0;
        try harness.invalid(h, forged_root);
        nodes[index] = node;
    };
}

test "forged spawns of callables that take parameters, fail, or do more than the spawner may are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    // A function value of each forbidden shape stands where the closure was.
    const Case = struct { source: []const u8 };
    for ([_]Case{
        .{ .source = "G(N:i64)<transacts><suspends>:i64 = N\nW()<transacts><suspends>:i64 = 1\nF:function<transacts><suspends>(tuple(i64),i64) = G\nT:task(i64) = Spawn{ W() }" },
        .{ .source = "G()<transacts>:i64 = 1\nW()<transacts><suspends>:i64 = 1\nF:function<transacts>(tuple(),i64) = G\nT:task(i64) = Spawn{ W() }" },
        .{ .source = "G()<transacts><decides>:i64 = 1\nW()<transacts><suspends>:i64 = 1\nF:function<transacts><decides>(tuple(),i64) = G\nT:task(i64) = Spawn{ W() }" },
    }) |case| {
        const p = try h.compile(case.source);
        var nodes: [256]types.Node = undefined;
        @memcpy(nodes[0..p.nodes.len], p.nodes);
        var forged = p;
        forged.nodes = nodes[0..p.nodes.len];
        var function_value: u32 = 0;
        for (p.nodes, 0..) |node, index| if (node.kind == .function_value and node.span.start < std.mem.indexOf(u8, case.source, "T:").?) {
            function_value = @intCast(index);
        };
        for (p.nodes, 0..) |node, index| if (node.kind == .spawn) {
            nodes[index].kind.spawn = function_value;
        };
        try harness.invalid(h, forged);
    }
    // A body that does what the function spawning it may not: written in a function without
    // writes, its closure claims them.
    const p = try h.compile("var C:i64 = 0\nW()<reads><suspends>:i64 = C\nF()<reads><allocates>:task(i64) = Spawn{ W() }\nT:task(i64) = F()");
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    for (p.functions, 0..) |f, id| if (f.anonymous) {
        h.metadata[id].detail = .{ .suspends = true };
    };
    try harness.invalid(h, forged);
}

test "a forged schedule is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\One(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.25); Sleep(0.5); N }
        \\Two(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.25); Sleep(0.5); N + 1 }
        \\A:task(i64) = Spawn{ One(1) }
        \\B:task(i64) = Spawn{ Two(2) }
    );
    _ = try reporting.validate(x, false, .{});
    const steps = x.call_steps;
    const Forgery = enum { start_sequence, wake, resume_other, resume_value, missing_tick, tick_value, settle_value, switches, created, swapped };
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var done = false;
        for (h.steps[0..steps.len], 0..) |*step, index| {
            if (done) break;
            switch (forgery) {
                .start_sequence => if (step.kind == .start) {
                    step.value.integer += 1;
                    done = true;
                },
                .wake => if (step.kind == .@"suspend") {
                    step.value.integer += 1;
                    done = true;
                },
                .resume_other => if (step.kind == .@"resume") {
                    step.pc += 1;
                    done = true;
                },
                .resume_value => if (step.kind == .@"resume") {
                    step.value = .{ .boolean = true };
                    done = true;
                },
                .missing_tick => if (step.kind == .tick) {
                    std.mem.copyForwards(types.CallStep, h.steps[index .. steps.len - 1], h.steps[index + 1 .. steps.len]);
                    forged.call_steps = h.steps[0 .. steps.len - 1];
                    done = true;
                },
                .tick_value => if (step.kind == .tick) {
                    step.value.integer -= 1;
                    done = true;
                },
                .settle_value => if (step.kind == .settle) {
                    step.value.integer += 10;
                    done = true;
                },
                .swapped => if (step.kind == .@"resume" and index + 1 < steps.len) {
                    // The two tasks woken by one tick, resumed in the other order.
                    var other = index + 1;
                    while (other < steps.len and h.steps[other].kind != .@"resume") other += 1;
                    if (other < steps.len) {
                        std.mem.swap(types.CallStep, step, &h.steps[other]);
                        done = true;
                    }
                },
                .switches => {
                    forged.scheduler.switches += 1;
                    done = true;
                },
                .created => {
                    forged.scheduler.created -= 1;
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

test "the same program needs the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Child(N:i64)<transacts><suspends>:i64 = Block{ Print(\"c{N}\"); Sleep(0.0); N }\nParent()<transacts><suspends>:void = Block{ A := Spawn{ Child(1) }; B := Spawn{ Child(2) }; Sleep(1.0); Print(\"p\") }\nP:task(void) = Spawn{ Parent() }",
        "Body(N:i64)<transacts><suspends>:void = Block{ Sleep(0.5); Print(\"t{N}\") }\nF(N:i64)<transacts><decides>:i64 = Block{ Spawn{ Body(N) }; Require[N > 0]; N }\nA:i64 = Attempt(F[1], -1)\nB:i64 = Attempt(F[0], -1)",
        "Deep(N:i64)<transacts><suspends>:i64 = If(N == 0, Block{ Sleep(0.1); 0 }, Deep(N - 1) + 1)\nT:task(i64) = Spawn{ Deep(5) }",
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

test "reclamation with tasks: a frame that saw another task run reclaims too, with what suspended frames hold as roots (P3.5), and a digest run reports as a stored one" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Task(N:i64)<transacts><suspends>:i64 = Block{ A := Many(12); Sleep(0.1); B := Many(12); A + B + N }
        \\Starter(N:i64)<transacts>:i64 = Block{ T := Spawn{ Task(N) }; Many(10) }
        \\A:i64 = Starter(1)
        \\B:task(i64) = Spawn{ Task(2) }
        \\C:i64 = Many(14)
    ;
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const stored = (try f.h.run(p, fuel)).ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = out.buffered();
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
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
        try std.testing.expect(actual.ok.reclaims != 0);
        try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
        out = .fixed(f.replayed);
        _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        _ = try reporting.validateReplayed(reference.ok, f.again.producer(p, fuel), false, .{});
    }
}

/// The program of `source` with the body of its function `target` replaced by `body`, the bodies
/// after it moved along. `control_ops` is the new body's count of control operations.
fn rebodied(h: *harness.Harness, p: types.Program, target: usize, body: []const types.FunctionNode, root: u32, control_ops: u32) types.Program {
    const old = p.functions[target].body;
    var at: usize = 0;
    @memcpy(h.body[0..old.start], p.function_nodes[0..old.start]);
    at = old.start;
    @memcpy(h.body[at..][0..body.len], body);
    at += body.len;
    @memcpy(h.body[at..][0 .. p.function_nodes.len - old.end], p.function_nodes[old.end..]);
    at += p.function_nodes.len - old.end;
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    const shift = @as(i64, @intCast(body.len)) - @as(i64, @intCast(old.end - old.start));
    for (h.metadata[0..p.functions.len], 0..) |*f, id| {
        if (id == target) {
            f.body = .{ .start = old.start, .end = old.start + @as(u32, @intCast(body.len)) };
            f.root = root;
            f.control_ops = control_ops;
        } else if (f.body.start >= old.end) {
            f.body.start = @intCast(@as(i64, f.body.start) + shift);
            f.body.end = @intCast(@as(i64, f.body.end) + shift);
        }
    }
    var forged = p;
    forged.function_nodes = h.body[0..at];
    forged.functions = h.metadata[0..p.functions.len];
    return forged;
}

test "a site inside a rollback region is refused by both machines, and its twin outside one runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Nap()<transacts><suspends>:void = Block{ Sleep(0.5); void(0) }\nT:task(void) = Spawn{ Nap() }");
    const nap = p.functions[0];
    try std.testing.expect(!nap.anonymous);
    const original = p.function_nodes[nap.body.start..nap.body.end];
    var unit: types.Node = undefined;
    var half: types.Node = undefined;
    for (original) |entry| {
        if (entry.node.kind == .aggregate) unit = entry.node;
        if (entry.node.kind == .floating) half = entry.node;
    }
    const span = half.span;
    const logic: types.Type = .logic;
    const n = struct {
        fn of(value_type: types.Type, at: types.Span, kind: @FieldType(types.Node, "kind")) types.FunctionNode {
            return .{ .node = .{ .span = at, .value_type = value_type, .kind = kind } };
        }
    }.of;
    const t = unit.value_type;
    const outside = [_]types.FunctionNode{
        .{ .node = half },
        n(t, span, .{ .sleep = 0 }),
        n(logic, span, .canceling),
        n(logic, span, .{ .if_begin = .{ .condition = 2, .alternative = 5, .end = 6 } }),
        n(t, span, .cancel_exit),
        n(logic, span, .{ .otherwise = 3 }),
        n(t, span, .{ .merge = .{ .begin = 3, .left = 4, .right = 1 } }),
        n(logic, span, .{ .attempt_begin = .{ .condition = std.math.maxInt(u32), .alternative = 9, .end = 11 } }),
        .{ .node = unit },
        n(logic, span, .{ .otherwise = 7 }),
        .{ .node = unit },
        n(t, span, .{ .merge = .{ .begin = 7, .left = 8, .right = 10 } }),
    };
    const inside = [_]types.FunctionNode{
        .{ .node = half },
        n(logic, span, .{ .attempt_begin = .{ .condition = std.math.maxInt(u32), .alternative = 8, .end = 10 } }),
        n(t, span, .{ .sleep = 0 }),
        n(logic, span, .canceling),
        n(logic, span, .{ .if_begin = .{ .condition = 3, .alternative = 6, .end = 7 } }),
        n(t, span, .cancel_exit),
        n(logic, span, .{ .otherwise = 4 }),
        n(t, span, .{ .merge = .{ .begin = 4, .left = 5, .right = 2 } }),
        n(logic, span, .{ .otherwise = 1 }),
        .{ .node = unit },
        n(t, span, .{ .merge = .{ .begin = 1, .left = 7, .right = 9 } }),
        .{ .node = unit },
    };
    const twin = rebodied(h, p, 0, &outside, 11, 9);
    const ran = try h.run(twin, fuel);
    try std.testing.expect(ran == .ok);
    try std.testing.expectEqual(@as(u64, 30), ran.ok.scheduler.tick);
    try harness.invalid(h, rebodied(h, p, 0, &inside, 11, 9));
}

test "a Spawn in a root For, While or First body, with statements after it, compiles and runs on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // A root loop declares the effects it used (`fix2`); a spawn in it uses every heap effect
    // its body may, and what follows the spawn in the loop is recorded as well.
    const x = try expectRun(h,
        \\var C:i64 = 0
        \\Xs:[]i64 = array{1, 2, 3}
        \\Work(N:i64)<transacts><suspends>:void = Block{ Sleep(0.5); set C = C + N; N }
        \\F:[]i64 = For(X:Xs, Block{ T := Spawn{ Work(X) }; set C = C + 10; X })
        \\W:i64 = Block{ var I:i64 = 0; While(I < 2, Block{ T := Spawn{ Work(100) }; set C = C + 1000; set I = I + 1 }); I }
        \\G:i64 = Attempt(First[X:Xs, X > 1, Block{ T := Spawn{ Work(10000) }; set C = C + 100000; X }], -1)
        \\Q:[]i64 = For(I:0..2, Block{ T := Spawn{ 1 }; I })
        \\P:[]task(void) = For(X:Xs, Spawn{ Print("p{X}") })
    );
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("p1\np2\np3\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(u64, 3 + 2 + 1 + 3 + 3), x.scheduler.created);
    try std.testing.expectEqual(x.scheduler.created, x.scheduler.completed);
    var report: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"C\":112236,\"Xs\":[1,2,3],\"F\":[1,2,3],\"W\":2,\"G\":2,\"Q\":[0,1,2],\"P\":[{\"$task\":{\"sequence\":10,"));
    // The loop functions declare every heap effect: the spawns' bodies may do what they do.
    for (x.program.functions) |f| if (f.anonymous and !std.mem.eql(u8, f.name.text(x.program.source), "Spawn")) {
        try std.testing.expect(f.effects().reads and f.effects().writes and f.effects().allocates);
    };
}

test "Sleep(0.0) one tick before the clock's limit never wakes, on both machines and in the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    h.control.tick_rate = 64;
    h.runtime.machine.control.tick_rate = 64;
    defer {
        h.control.tick_rate = types.Scheduler.default_tick_rate;
        h.runtime.machine.control.tick_rate = types.Scheduler.default_tick_rate;
    }
    // (2^56 - 8) seconds at 64 ticks a second is 2^62 - 512 ticks, and 510/64 seconds 510 more.
    // A zero sleep then reaches 2^62 - 1, and the next would be at 2^62, which is never.
    const x = try expectRun(h,
        \\Edge()<transacts><suspends>:void = Block{
        \\    Sleep(72057594037927928.0)
        \\    Sleep(7.96875)
        \\    Sleep(0.0)
        \\    Print("last tick")
        \\    Sleep(-0.0)
        \\    Print("never")
        \\}
        \\T:task(void) = Spawn{ Edge() }
    );
    try std.testing.expectEqual(@as(u64, types.Scheduler.clock_limit - 1), x.scheduler.tick);
    try std.testing.expectEqual(@as(usize, 1), x.scheduler.waiting.len);
    try std.testing.expectEqual(@as(u64, 0), x.scheduler.completed);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("last tick\n", printed(x, &buffer));
}

test "the tick rate is recorded by both machines in every mode, for programs with and without tasks" {
    const h = try harness.create();
    defer scratch.release(h);
    h.control.tick_rate = 7;
    h.runtime.machine.control.tick_rate = 7;
    defer {
        h.control.tick_rate = types.Scheduler.default_tick_rate;
        h.runtime.machine.control.tick_rate = types.Scheduler.default_tick_rate;
    }
    for ([_][]const u8{
        "Value:i64 = 1",
        "F(N:i64)<computes>:i64 = N + 1\nValue:i64 = F(1)",
        "Nap()<transacts><suspends>:void = Sleep(1.0)\nT:task(void) = Spawn{ Nap() }",
    }) |source| {
        const x = try expectRun(h, source);
        try std.testing.expectEqual(@as(u64, 7), x.scheduler.tick_rate);
    }
    const x = try expectRun(h, "Nap()<transacts><suspends>:void = Sleep(1.0)\nT:task(void) = Spawn{ Nap() }");
    try std.testing.expectEqual(@as(u64, 7), x.scheduler.tick);
    var report: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"$scheduler\":{\"tick_rate\":7,\"tick\":7,") != null);
    // In every trace mode: `full`, `digest` and `off` runs record the rate alike.
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    f.h.control.tick_rate = 7;
    f.h.runtime.machine.control.tick_rate = 7;
    for ([_]types.TraceMode{ .full, .digest, .off }) |mode| {
        f.mode(mode, types.ControlStorage.default_trace_window);
        for ([_][]const u8{
            "Value:i64 = 1",
            "F(N:i64)<computes>:i64 = N + 1\nValue:i64 = F(1)",
            "Nap()<transacts><suspends>:void = Sleep(1.0)\nT:task(void) = Spawn{ Nap() }",
            "E:event(i64) = event(i64){}\nEar()<transacts><suspends>:i64 = E.Await()\nT:task(i64) = Spawn{ Ear() }\nU:void = E.Signal(1)",
        }) |source| {
            const p = try f.h.compile(source);
            const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, fuel);
            const actual = f.h.runtime.evaluate(p, fuel);
            try std.testing.expect(reference == .ok and actual == .ok);
            try std.testing.expectEqual(@as(u64, 7), reference.ok.scheduler.tick_rate);
            try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
        }
    }
}

test "a function's root is no site's register, on either machine" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Nap()<transacts><suspends>:void = Sleep(0.5)
        \\T:task(void) = Spawn{ Nap() }
    ;
    const p = try h.compile(source);
    _ = try expectRun(h, source);
    const found = sleeper(p);
    try std.testing.expect(p.functions[found.function].root != found.site);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[found.function].root = @intCast(found.site);
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    try harness.invalid(h, forged);
    // Every other kind of site too: a call of a function that suspends, an invocation of a
    // function value that does, and the awaits of a handle and an event (P3.2).
    const every =
        \\E:event(i64) = event(i64){}
        \\Nap()<transacts><suspends>:i64 = Block{ Sleep(0.5); 1 }
        \\Call()<transacts><suspends>:i64 = Nap()
        \\Through(G:function<transacts><suspends>(tuple(), i64))<transacts><suspends>:i64 = G()
        \\Handle(T:task(i64))<transacts><suspends>:i64 = T.Await()
        \\Event()<transacts><suspends>:i64 = E.Await()
        \\T:task(i64) = Spawn{ Call() + Through(Nap) + Event() }
        \\U:task(i64) = Spawn{ Handle(T) }
        \\V:void = E.Signal(2)
    ;
    const q = try h.compile(every);
    _ = try expectRun(h, every);
    var kinds: usize = 0;
    for (q.functions, 0..) |f, id| for (q.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
        if (entry.input != .operation or index + 1 >= f.body.end - f.body.start or q.function_nodes[f.body.start + index + 1].node.kind != .canceling) continue;
        if (f.root == index) continue;
        @memcpy(h.metadata[0..q.functions.len], q.functions);
        h.metadata[id].root = @intCast(index);
        var site_root = q;
        site_root.functions = h.metadata[0..q.functions.len];
        try harness.invalid(h, site_root);
        kinds += 1;
    };
    try std.testing.expect(kinds >= 6);
}

test "a Return or Break that would leave a Spawn body is refused there, in loops and macros too" {
    const h = try harness.create();
    defer scratch.release(h);
    // An exit a loop's macro lowers is placed at the loop, as every diagnostic of that lowering.
    const Case = struct { text: []const u8, at: []const u8 };
    for ([_]Case{
        .{ .text = "F()<transacts><suspends>:i64 = Block{ T := Spawn{ For(I:0..2, Return(1)) }; 0 }\nValue:i64 = 1", .at = "For" },
        .{ .text = "F()<transacts><suspends>:i64 = Block{ T := Spawn{ For(I:0..2, If(I > 0, Return(I), I)) }; 0 }\nValue:i64 = 1", .at = "For" },
        .{ .text = "F()<transacts><suspends>:i64 = Block{ T := Spawn{ Block{ var I:i64 = 0; While(I < 2, Block{ set I = I + 1; Return(I) }); I } }; 0 }\nValue:i64 = 1", .at = "While" },
        .{ .text = "F()<transacts><suspends>:i64 = Block{ var I:i64 = 0; Loop{ T := Spawn{ Return(2) }; Break() }; I }\nValue:i64 = 1", .at = "Return" },
        .{ .text = "F()<transacts><suspends>:i64 = For(I:0..2, Block{ T := Spawn{ Return(I) }; I }).Length\nValue:i64 = 1", .at = "Return" },
        .{ .text = "F()<transacts><suspends>:i64 = For(I:0..2, Block{ T := Spawn{ Break() }; I }).Length\nValue:i64 = 1", .at = "Break" },
    }) |case| {
        const at = std.mem.indexOf(u8, case.text, "Spawn").? + std.mem.indexOf(u8, case.text[std.mem.indexOf(u8, case.text, "Spawn").?..], case.at).?;
        try expectRefused(h, case.text, .return_in_task_body, case.text[at .. at + case.at.len]);
    }
    // A loop of the body's own may still be left, and a function inside it returned from.
    const x = try expectRun(h,
        \\F()<transacts><suspends>:i64 = Block{ var I:i64 = 0; Loop{ If(I >= 3, Break(), false); set I = I + 1 }; For(K:0..2, If(K > 0, Return(K), K)); I }
        \\T:task(i64) = Spawn{ Block{ var J:i64 = 0; Loop{ Break() }; G := Fn()<computes>:i64{ Return(5) }; G() + F() } }
    );
    var report: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":6") != null);
}

test "public and bundled reports print task handles in place, a result held as any hidden" {
    var f = try trace_replay.Fixture.create();
    defer f.destroy();
    const h = f.h;
    const p = try h.compile(
        \\rec:=struct{Code:i64}
        \\Make()<transacts><suspends>:any = Block{ Sleep(0.5); any(rec{Code:=7}) }
        \\Plain()<transacts><suspends>:i64 = 3
        \\A<public>:task(any) = Spawn{ Make() }
        \\B<public>:task(i64) = Spawn{ Plain() }
        \\C:task(i64) = Spawn{ Block{ Sleep(Inf); 0 } }
    );
    f.mode(.full, types.ControlStorage.default_trace_window);
    const full = (try h.run(p, fuel)).ok;
    var stored: [2][2048]u8 = undefined;
    var stored_len: [2]usize = undefined;
    for ([_]bool{ true, false }, 0..) |public_only, index| {
        var out = std.Io.Writer.fixed(&stored[index]);
        _ = try reporting.write(&out, full, public_only, .{});
        stored_len[index] = out.buffered().len;
    }
    try std.testing.expect(std.mem.startsWith(u8, stored[0][0..stored_len[0]], "{\"A\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":{\"$hidden\":true}}},\"B\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":3}},\"$scheduler\":{"));
    try std.testing.expect(std.mem.indexOf(u8, stored[1][0..stored_len[1]], "\"result\":{\"Code\":7}") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored[1][0..stored_len[1]], "\"C\":{\"$task\":{\"sequence\":3,\"state\":\"active\"}}") != null);
    // A digest run's replayed reports are the stored ones, public or not.
    f.mode(.digest, 7);
    f.again.control.trace_window = 7;
    const digest = h.runtime.evaluate(p, fuel);
    try std.testing.expect(digest == .ok);
    for ([_]bool{ true, false }, 0..) |public_only, index| {
        var buffer: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        _ = try reporting.writeReplayed(&out, digest.ok, f.again.producer(p, fuel), public_only, .{ .work = 1 << 26 });
        try std.testing.expectEqualStrings(stored[index][0..stored_len[index]], out.buffered());
    }
    f.mode(.full, types.ControlStorage.default_trace_window);
    // A handle in a bundle: the library spawns, the main file holds the handle.
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nH<public>:task(i64)=L.Start(4)" },
        .{ .path = "lib.forb", .source = "Twice(N:i64)<transacts><suspends>:i64=Block{Sleep(0.25);N*2}\nStart<public>(N:i64)<transacts>:task(i64)=Spawn{Twice(N)}" },
    };
    const bundle = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |value| value,
        .failed => |failure| {
            std.debug.print("bundle failed: {s} in {s}\n", .{ failure.diagnostic.message(), failure.path });
            return error.Compile;
        },
    };
    const run = (try h.run(bundle, fuel)).ok;
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, run, true, .{});
    try std.testing.expectEqualStrings("{\"H\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":8}},\"$scheduler\":{\"tick_rate\":60,\"tick\":15,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":3,\"waiting\":[]}}\n", out.buffered());
}

test "sites in the loop functions of a task agree across the machines and in a digest replay" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    // A `For` body that may fail has a region per iteration, so a site in it is refused; from
    // P3.8 one that cannot fail has none and may hold one (`concurrency_for_tests.zig`).
    try expectRefused(f.h, "Step(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.1); N * 2 }\nRun(K:i64, Xs:[]i64)<transacts><suspends>:[]i64 = For(I:0..K, Step(Xs[I]))", .suspending_for_fails, "Step(Xs[I])");
    const source =
        \\Step(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.1); N * 2 }
        \\Run(K:i64)<transacts><suspends>:i64 = Block{
        \\    var T:i64 = 0
        \\    var J:i64 = 0
        \\    While(J < K, Block{ set T = T + Step(J); set J = J + 1 })
        \\    Loop{ If(J <= 0, Break(), false); Sleep(0.05); set T = T + J; set J = J - 1 }
        \\    T * 100 + J
        \\}
        \\A:task(i64) = Spawn{ Run(3) }
        \\B:task(i64) = Spawn{ Run(4) }
    ;
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const stored = (try f.h.run(p, fuel)).ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, expected, "\"A\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":") != null);
    try std.testing.expect(stored.scheduler.switches > 20);
    for ([_]u32{ 1, 4, types.ControlStorage.default_trace_window }) |window| {
        f.mode(.digest, window);
        f.again.control.trace_window = window;
        const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, fuel);
        const actual = f.h.runtime.evaluate(p, fuel);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
        try std.testing.expectEqualDeep(stored.scheduler, actual.ok.scheduler);
        out = .fixed(f.replayed);
        _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
    f.mode(.full, types.ControlStorage.default_trace_window);
}

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms));
}

/// Runs `source` on each machine and replays its report, printing how long each took.
fn timed(h: *harness.Harness, label: []const u8, source: []const u8, budget: u64) !evaluator.Result {
    const p = try h.compile(source);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    if (actual == .ok) {
        try std.testing.expectEqualDeep(reference.ok.scheduler.waiting.len, actual.ok.scheduler.waiting.len);
        try std.testing.expectEqual(reference.ok.scheduler.switches, actual.ok.scheduler.switches);
        try std.testing.expectEqual(reference.ok.scheduler.tick, actual.ok.scheduler.tick);
        _ = try reporting.validate(actual.ok, false, .{ .work = std.math.maxInt(u64) });
    } else try std.testing.expectEqualDeep(reference.failed, actual.failed);
    std.debug.print("{s}: reference={d}ms vm={d}ms replay={d}ms\n", .{ label, referenced, ran - referenced, elapsed(start) - ran });
    return actual;
}

/// Scale tests 1 and 2 (RFC-0082): the task capacity, every slot live at once with each task
/// sleeping a time of its own, and one more task, which is `task_limit` at its spawn.
pub fn liveTasks(h: *harness.Harness) !void {
    var buffer: [512]u8 = undefined;
    const program =
        \\Nap(N:i64)<transacts><suspends>:void = Sleep(ToFloat(N + 1))
        \\Spawner(Count:i64)<transacts><suspends>:void = Block{{
        \\    var I:i64 = 0
        \\    Loop{{ If(I >= Count, Break(), false); Spawn{{ Nap(I) }}; set I = I + 1 }}
        \\}}
        \\T:task(void) = Spawn{{ Spawner({d}) }}
    ;
    // The spawner is a task itself, so it spawns one fewer.
    const all = types.limits.tasks - 1;
    const x = (try timed(h, "live tasks", try std.fmt.bufPrint(&buffer, program, .{all}), 1 << 40)).ok;
    try std.testing.expectEqual(@as(u64, types.limits.tasks), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, types.limits.tasks), x.scheduler.completed);
    try std.testing.expectEqual(@as(u64, 60 * all), x.scheduler.tick);
    const over = try timed(h, "one task more", try std.fmt.bufPrint(&buffer, program, .{all + 1}), 1 << 40);
    try std.testing.expectEqual(types.Diagnostic.Code.task_limit, over.failed.code);
}

/// Scale test 6: suspended frames at their capacity, eight per task, and one frame more, which
/// is `suspended_frame_limit` at the site that would save it.
pub fn savedFrames(h: *harness.Harness) !void {
    var buffer: [1024]u8 = undefined;
    const program =
        \\F0()<transacts><suspends>:void = Sleep(Inf)
        \\F1()<transacts><suspends>:void = F0()
        \\F2()<transacts><suspends>:void = F1()
        \\F3()<transacts><suspends>:void = F2()
        \\F4()<transacts><suspends>:void = F3()
        \\F5()<transacts><suspends>:void = F4()
        \\F6()<transacts><suspends>:void = F5()
        \\Spawner(Count:i64)<transacts><suspends>:void = Block{{
        \\    var I:i64 = 0
        \\    Loop{{ If(I >= Count, Break(), false); Spawn{{ F6() }}; set I = I + 1 }}
        \\    Spawn{{ F{d}() }}
        \\}}
        \\T:task(void) = Spawn{{ Spawner({d}) }}
    ;
    // Each task waits with its entry frame and seven more.
    const tasks = types.limits.saved_frames / 8;
    const x = (try timed(h, "saved frames at capacity", try std.fmt.bufPrint(&buffer, program, .{ 6, tasks - 1 }), 1 << 40)).ok;
    try std.testing.expectEqual(@as(usize, tasks), x.scheduler.waiting.len);
    try std.testing.expectEqual(@as(u32, types.limits.saved_frames), h.runtime.machine.scheduler.frames_used);
    try std.testing.expectEqual(@as(u32, types.limits.saved_frames), h.frames.scheduler.frames_live);
    // The last task one frame deeper.
    const program_more =
        \\F0()<transacts><suspends>:void = Sleep(Inf)
        \\F1()<transacts><suspends>:void = F0()
        \\F2()<transacts><suspends>:void = F1()
        \\F3()<transacts><suspends>:void = F2()
        \\F4()<transacts><suspends>:void = F3()
        \\F5()<transacts><suspends>:void = F4()
        \\F6()<transacts><suspends>:void = F5()
        \\F7()<transacts><suspends>:void = F6()
        \\Spawner(Count:i64)<transacts><suspends>:void = Block{{
        \\    var I:i64 = 0
        \\    Loop{{ If(I >= Count, Break(), false); Spawn{{ F6() }}; set I = I + 1 }}
        \\    Spawn{{ F7() }}
        \\}}
        \\T:task(void) = Spawn{{ Spawner({d}) }}
    ;
    const over = try timed(h, "one saved frame more", try std.fmt.bufPrint(&buffer, program_more, .{tasks - 1}), 1 << 40);
    try std.testing.expectEqual(types.Diagnostic.Code.suspended_frame_limit, over.failed.code);
}

/// Scale test 5: ten million ticks crossed by one sleeper in a few advances.
pub fn longSleep(h: *harness.Harness) !void {
    const x = (try timed(h, "ten million ticks", "Long()<transacts><suspends>:void = Block{ Sleep(100000.0); Sleep(66666.0); Sleep(0.0) }\nT:task(void) = Spawn{ Long() }", 1 << 20)).ok;
    try std.testing.expectEqual(@as(u64, 6_000_000 + 3_999_960 + 1), x.scheduler.tick);
    try std.testing.expectEqual(@as(u64, 7), x.scheduler.switches);
}

test "the task and saved-frame capacities of the bootstrap profile, and one more of each" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    try liveTasks(h);
    try savedFrames(h);
    try longSleep(h);
}

// The re-review of P3.1 (r31): its reproducers, each now a test of the fixed behaviour.

test "r31 E1: a Spawn in a Defer body copied to several exits compiles, and each copy is a task body of its own" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [256]u8 = undefined;
    var x = try expectRun(h,
        \\F(K:i64)<transacts>:i64 = Block{ Defer{ T := Spawn{ Print("d{K}") } }; If(K > 0, Return(K), 0); 7 }
        \\A:i64 = F(1)
        \\B:i64 = F(0)
    );
    try std.testing.expectEqualStrings("d1\nd0\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
    x = try expectRun(h,
        \\F(K:i64)<transacts>:i64 = Block{ For(I:0..K, Block{ Defer{ T := Spawn{ Print("d{I}") } }; If(I > 0, Return(I), 0); I }); 7 }
        \\A:i64 = F(3)
    );
    try std.testing.expectEqualStrings("d0\nd1\n", printed(x, &buffer));
    // Three exits, so three copies, in a function that suspends.
    x = try expectRun(h,
        \\G(K:i64)<transacts><suspends>:i64 = Block{ Defer{ T := Spawn{ Sleep(0.1); Print("g{K}") } }; If(K > 1, Return(K), 0); If(K > 0, Return(-K), 0); 0 }
        \\H:task(i64) = Spawn{ G(2) + G(1) + G(0) }
    );
    try std.testing.expectEqualStrings("g2\ng1\ng0\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(u64, 4), x.scheduler.completed);
}

test "r31 E2: a Spawn written directly in a Spawn body is the form" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [256]u8 = undefined;
    var x = try expectRun(h, "A:task(void) = Spawn{ U := Spawn{ Print(\"in\") }; Sleep(0.1); Print(\"out\") }");
    try std.testing.expectEqualStrings("in\nout\n", printed(x, &buffer));
    x = try expectRun(h, "A:task(void) = Spawn{ Spawn{ Print(\"in\") }; Print(\"out\") }");
    try std.testing.expectEqualStrings("in\nout\n", printed(x, &buffer));
    x = try expectRun(h, "F()<transacts><suspends>:void = Block{ T := Spawn{ U := Spawn{ Print(\"in\") }; Print(\"out\") }; Sleep(0.1) }\nA:task(void) = Spawn{ F() }");
    try std.testing.expectEqualStrings("in\nout\n", printed(x, &buffer));
    x = try expectRun(h, "A:task(void) = Spawn{ Block{ U := Spawn{ Print(\"in\") }; Print(\"out\") } }");
    try std.testing.expectEqualStrings("in\nout\n", printed(x, &buffer));
    x = try expectRun(h, "A:task(task(i64)) = Spawn{ Spawn{ 1 } }");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.completed);
}

test "r31 E3: a program's own Spawn keeps its Return and Break in its constructor in a loop" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try expectRun(h, "Spawn := class{ var N:i64 = 0 }\nF(K:i64)<transacts>:i64 = Block{ For(I:0..K, Block{ S := Spawn{ N := If(I > 1, Return(I), I) }; S.N }); 0 }\nA:i64 = F(3)");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    x = try expectRun(h, "Spawn := struct{ N:i64 }\nF()<transacts>:i64 = Block{ var I:i64 = 0; Loop{ S := Spawn{ N := If(I > 1, Break(), I) }; set I = I + 1 }; I }\nA:i64 = F()");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    x = try expectRun(h, "Spawn := struct{ N:i64 }\nF(K:i64)<transacts>:i64 = Block{ S := Spawn{ N := If(K > 0, Return(5), K) }; S.N }\nA:i64 = F(1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
}

test "r31 E4: a Defer written directly in a Spawn body runs when the body ends" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [256]u8 = undefined;
    var x = try expectRun(h, "A:task(i64) = Spawn{ Defer{ Print(\"d\") }; Sleep(0.5); Print(\"b\"); 1 }");
    try std.testing.expectEqualStrings("b\nd\n", printed(x, &buffer));
    x = try expectRun(h, "A:task(i64) = Spawn{ Block{ Defer{ Print(\"d\") }; Sleep(0.5); Print(\"b\"); 1 } }");
    try std.testing.expectEqualStrings("b\nd\n", printed(x, &buffer));
    // The Book's example 14:813: the spawned task outlives its creator, and its `defer` runs.
    x = try expectRun(h,
        \\Creator()<transacts><suspends>:void = Block{ T := Spawn{ Defer{ Print("task defer") }; Sleep(1.0); Print("task end") }; Print("creator end") }
        \\C:task(void) = Spawn{ Creator() }
    );
    try std.testing.expectEqualStrings("creator end\ntask end\ntask defer\n", printed(x, &buffer));
}

test "r31 E5: an alias of a handle type, and of an event type, is a type" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try expectRun(h, "H:=task(i64)\nA:H = Spawn{ 4 }\nB:task(i64) = A");
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.completed);
    x = try expectRun(h, "Gate:=event(i64)\nE:Gate = event(i64){}\nF := event(string){}\nA:event(string) = F");
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

test "the saved_registers limit falls where the registers and parameters of saved frames exceed it, on both machines" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [4096]u8 = undefined;
    const program = "P3(A:i64, B:i64, C:i64, D:i64, E:i64, F:i64, G:i64, H:i64, I:i64, J:i64, K:i64, L:i64, M:i64, N:i64, O:i64, Q:i64)<transacts><suspends>:i64 = Block{{ Sleep(Inf); A + B + C + D + E + F + G + H + I + J + K + L + M + N + O + Q }}\n" ++
        "P2(A:i64, B:i64, C:i64, D:i64, E:i64, F:i64, G:i64, H:i64, I:i64, J:i64, K:i64, L:i64, M:i64, N:i64, O:i64, Q:i64)<transacts><suspends>:i64 = P3(A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, Q) + 1\n" ++
        "P1(A:i64, B:i64, C:i64, D:i64, E:i64, F:i64, G:i64, H:i64, I:i64, J:i64, K:i64, L:i64, M:i64, N:i64, O:i64, Q:i64)<transacts><suspends>:i64 = P2(A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, Q) + 1\n" ++
        "Spawner(Count:i64)<transacts><suspends>:void = Block{{ var I:i64 = 0; Loop{{ If(I >= Count, Break(), false); Spawn{{ P1(I, I, I, I, I, I, I, I, I, I, I, I, I, I, I, I) }}; set I = I + 1 }} }}\n" ++
        "T:task(void) = Spawn{{ Spawner({d}) }}";
    // Each task waits with four frames, three of them with sixteen parameters: the frames alone
    // stay far below `saved_frames`, so the parameters decide where the limit falls.
    var count: u64 = 1;
    var last_ok: u64 = 0;
    while (count < 63) : (count += 1) {
        const p = try h.compile(try std.fmt.bufPrint(&buffer, program, .{count}));
        const outcome = try h.run(p, 1 << 30);
        if (outcome == .failed) {
            try std.testing.expectEqual(types.Diagnostic.Code.suspended_frame_limit, outcome.failed.code);
            try std.testing.expect(h.runtime.machine.scheduler.frames_used < types.limits.saved_frames);
            try std.testing.expect(h.runtime.machine.scheduler.values_used + h.runtime.machine.scheduler.parameters_used <= types.limits.saved_registers);
            break;
        }
        last_ok = count;
    }
    try std.testing.expect(count < 63 and last_ok + 1 == count);
}

test "handles and events reach any only inside an aggregate, and come back from it unchanged" {
    const h = try harness.create();
    defer scratch.release(h);
    // Decision C30: `any(H)` and `any(E)` are refused; an aggregate that holds one is a value
    // like any other, and a cast back gives the same handle, which awaits as before.
    const x = try expectRun(h,
        \\W()<transacts><suspends>:i64 = Block{ Sleep(0.1); 4 }
        \\A:task(i64) = Spawn{ W() }
        \\B:any = any(tuple{A, 1})
        \\Z:task(i64) = Spawn{ 9 }
        \\Pair := tuple(task(i64), i64)
        \\D:Pair = Attempt(Pair[B], tuple{Z, 2})
        \\R()<transacts><suspends>:i64 = Block{ P := D; P(0).Await() }
        \\S:task(i64) = Spawn{ R() }
    );
    var report: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"S\":{\"$task\":{\"sequence\":3,\"state\":\"completed\",\"result\":4}}") != null);
}
