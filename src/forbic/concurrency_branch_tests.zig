//! Structured concurrency, P3.4 (RFC-0082): `Rush` and `Branch`, the tasks a frame owns, the
//! wait at a frame's end, and the check at a site's entry of a task asked to cancel while it
//! waited there, in both machines and the report replay.
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

fn expectCounts(x: evaluator.Execution, created: u64, completed: u64, canceled: u64, waiting: usize) !void {
    try std.testing.expectEqual(created, x.scheduler.created);
    try std.testing.expectEqual(completed, x.scheduler.completed);
    try std.testing.expectEqual(canceled, x.scheduler.canceled);
    try std.testing.expectEqual(waiting, x.scheduler.waiting.len);
}

test "the Book's 14:664: a branch is cancelled when its function returns, and its Defer runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Fire()<transacts><suspends>:void = Block{
        \\    Branch{ Defer{ Print("clean") }; Sleep(0.0); Print("body") }
        \\    Print("main")
        \\}
        \\Run()<transacts><suspends>:void = Block{ Fire(); Print("returned") }
        \\T:task(void) = Spawn{ Run() }
    , "main\nclean\nreturned\n");
    try expectCounts(x, 2, 1, 1, 0);
}

test "the Book's 14:443: Rush keeps its loser running, owned by the frame; Race cancels it" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { form: []const u8, expected: []const u8 }{
        .{ .form = "Rush", .expected = "trace 102\n" },
        .{ .form = "Race", .expected = "trace 2\n" },
    }) |case| {
        var source: [2048]u8 = undefined;
        var out: std.Io.Writer = .fixed(&source);
        try out.print(
            \\Gate:event(i64) = event(i64){{}}
            \\var Trace:i64 = 0
            \\A1()<transacts><suspends>:i64 = Block{{ Gate.Await(); set Trace = Trace + 100; 1 }}
            \\A2()<transacts><suspends>:i64 = Block{{ Sleep(0.0); 2 }}
            \\First()<transacts><suspends>:i64 = Block{{ W := {s}(A1(), A2()); Gate.Signal(0); Sleep(0.0); W }}
            \\Run()<transacts><suspends>:void = Block{{ R := First(); set Trace = Trace + R; Print("trace {{Trace}}") }}
            \\T:task(void) = Spawn{{ Run() }}
        , .{case.form});
        _ = try expectPrinted(h, out.buffered(), case.expected);
    }
}

test "a frame's end asks its tasks to cancel in creation order, depth first, and waits for them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Leaf(N:i64)<transacts><suspends>:void = Block{ Defer{ Print("leaf {N}") }; Sleep(Inf) }
        \\Owner()<transacts><suspends>:void = Block{
        \\    Defer{ Print("owner defer") }
        \\    Branch{ Leaf(1) }
        \\    Branch{ Leaf(2) }
        \\    Branch{ Sync(Leaf(3), Leaf(4)) }
        \\    Print("owner end")
        \\}
        \\Main()<transacts><suspends>:void = Block{ Owner(); Print("main after") }
        \\T:task(void) = Spawn{ Main() }
    , "owner end\nowner defer\nleaf 1\nleaf 2\nleaf 3\nleaf 4\nmain after\n");
    // Main, three branches and the two arms of the third: all but Main cancelled.
    try expectCounts(x, 6, 1, 5, 0);
}

test "a branch that settles before its frame ends leaves nothing to wait for" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\F()<transacts><suspends>:i64 = Block{ Branch{ Sleep(0.1); Print("b") }; Branch{ Print("at once") }; Sleep(0.5); Print("a"); 4 }
        \\Main()<transacts><suspends>:void = Block{ X := F(); Print("f {X}") }
        \\T:task(void) = Spawn{ Main() }
    , "at once\nb\na\nf 4\n");
    try expectCounts(x, 3, 3, 0, 0);
}

test "a Rush resolved in its start phase goes on at once; its loser is cancelled at the frame's end" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Slow(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("slow {N} gone") }; Sleep(5.0); Print("slow {N} done"); N }
        \\Quick()<transacts><suspends>:i64 = Block{ Sleep(-1.0); 7 }
        \\F()<transacts><suspends>:i64 = Block{ W := Rush(Slow(1), Quick(), Slow(2)); Print("rush {W}"); Sleep(1.0); Print("f end"); W }
        \\Main()<transacts><suspends>:void = Block{ X := F(); Print("main {X}") }
        \\T:task(void) = Spawn{ Main() }
    , "rush 7\nf end\nslow 1 gone\nmain 7\n");
    // The third arm never starts.
    try expectCounts(x, 3, 2, 1, 0);
}

test "a Rush whose task waits on it: the first to complete yields, the others finish under the frame" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Arm(N:i64, S:float)<transacts><suspends>:i64 = Block{ Defer{ Print("arm {N} ends") }; Sleep(S); N }
        \\F()<transacts><suspends>:i64 = Block{ W := Rush(Arm(1, 0.3), Arm(2, 0.1), Arm(3, 0.2)); Print("rush {W}"); Sleep(1.0); W }
        \\Main()<transacts><suspends>:void = Block{ X := F(); Print("main {X}") }
        \\T:task(void) = Spawn{ Main() }
    , "arm 2 ends\nrush 2\narm 3 ends\narm 1 ends\nmain 2\n");
    try expectCounts(x, 4, 4, 0, 0);
}

test "a task asked to cancel while it waited at a frame's end goes on ending, then its next site yields cancelled" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\G()<transacts><suspends>:void = Block{ Branch{ Defer{ Print("g branch") }; Sleep(5.0) }; Print("g end") }
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Block{ Defer{ Print("a defer") }; G(); Print("g returned"); Sleep(1.0); Print("never"); 1 }, Block{ Sleep(-1.0); 2 })
        \\    Print("won {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "g end\ng branch\ng returned\na defer\nwon 2\n");
    try expectCounts(x, 4, 2, 2, 0);
}

test "a branch in an arm belongs to the arm (Q9): the arm's end waits for it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Race(Block{ Branch{ Defer{ Print("branch gone") }; Sleep(0.5); Print("branch done") }; 1 }, Block{ Sleep(1.0); 2 })
        \\    Print("won {W}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "branch gone\nwon 1\n");
    try expectCounts(x, 4, 2, 2, 0);
}

test "branches still waiting at quiescence are listed as branches; a frame's end never waits for ever" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\E:event(i64) = event(i64){}
        \\F()<transacts><suspends>:i64 = Block{ Branch{ E.Await() }; Sleep(Inf); 1 }
        \\T:task(i64) = Spawn{ F() }
    );
    try expectCounts(x, 2, 0, 0, 2);
    try std.testing.expectEqual(types.Scheduler.Waiting{ .task = 1, .kind = .spawn, .wait = .sleep, .span = x.scheduler.waiting[0].span }, x.scheduler.waiting[0]);
    try std.testing.expectEqual(types.Scheduler.Waiting{ .task = 2, .kind = .branch, .wait = .event, .span = x.scheduler.waiting[1].span }, x.scheduler.waiting[1]);
    try std.testing.expectEqualStrings("Await", x.program.source[x.scheduler.waiting[1].span.start..x.scheduler.waiting[1].span.end]);
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

test "every compile-time refusal of P3.4 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        // Both forms are sites: only in a function that suspends, never where code must finish.
        .{ .source = "F()<transacts>:void = Branch{ Print(\"x\") }", .code = .call_requires_suspends, .at = "Branch" },
        .{ .source = "X:void = Branch{ Print(\"x\") }", .code = .call_requires_suspends, .at = "Branch" },
        .{ .source = "F()<transacts>:i64 = Rush(Block{ Sleep(1.0); 1 }, 2)", .code = .call_requires_suspends, .at = "Rush" },
        .{ .source = "X:i64 = Rush(1, 2)", .code = .call_requires_suspends, .at = "Rush" },
        .{ .source = "F()<transacts><suspends>:i64 = Attempt(Block{ Branch{ Sleep(1.0) }; 1 }, 0)", .code = .suspends_in_failure_context, .at = "Branch" },
        .{ .source = "F()<transacts><suspends>:i64 = Attempt(Rush(Block{ Sleep(1.0); 1 }, 2), 0)", .code = .suspends_in_failure_context, .at = "Rush" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Defer{ Branch{ Sleep(1.0) } }; 1 }", .code = .suspends_in_failure_context, .at = "Branch" },
        // Not in the body of a `Loop{}` or a `While` (Book 14:503, 14:705), whatever the depth of
        // blocks, unless a function of its own lies between.
        .{ .source = "F()<transacts><suspends>:void = Loop{ Branch{ Sleep(1.0) }; Break() }", .code = .concurrency_in_loop, .at = "Branch" },
        .{ .source = "F()<transacts><suspends>:void = Loop{ X := If(true, Block{ Branch{ Sleep(1.0) }; 0 }, 1); Sleep(1.0) }", .code = .concurrency_in_loop, .at = "Branch" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ var N:i64 = 0; While(N < 3, Block{ X := Rush(Block{ Sleep(1.0); 1 }, 2); set N = N + X }); N }", .code = .concurrency_in_loop, .at = "Rush" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Loop{ X := Rush(Block{ Sleep(1.0); 1 }, 2); Return(X) } }", .code = .concurrency_in_loop, .at = "Rush" },
        // A body is a task's: nothing leaves it, and it captures by value.
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Branch{ Sleep(1.0); Return(1) }; 2 }", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Branch{ Break() }; 2 }", .code = .return_in_task_body, .at = "Break" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Loop{ X := Branch{ Break() }; Break() }; 2 }", .code = .return_in_task_body, .at = "Break" },
        .{ .source = "F()<transacts><suspends>:i64 = Block{ Branch{ Loop{ Sleep(1.0); Return(3) } }; 2 }", .code = .return_in_task_body, .at = "Loop" },
        // RFC-0085, I5: a local `var` the body assigns is shared (`shared_local_task_tests.zig`).
        .{ .source = "F()<transacts><suspends>:i64 = Block{ N:i64 = 0; Branch{ Sleep(1.0); set N = 1 }; N }", .code = .arm_assigns_local, .at = "N" },
        .{ .source = "Xs:[]i64 = array{1}\nF()<transacts><suspends>:i64 = Block{ Branch{ Sleep(1.0); Xs[0] }; 1 }", .code = .failure_context_required, .at = "[" },
        // A `Rush` is read as a `Race` is.
        .{ .source = "F()<transacts><suspends>:i64 = Rush(Block{ Sleep(1.0); 1 })", .code = .concurrency_arms, .at = "Rush" },
        .{ .source = "F()<transacts><suspends>:i64 = Rush()", .code = .concurrency_arms, .at = "Rush" },
        .{ .source = "F(N:i64)<transacts><suspends>:i64 = Block{ Rush(Block{ Sleep(1.0); set N = 1; N }, 2) }", .code = .arm_assigns_local, .at = "N" },
        .{ .source = "F()<transacts><suspends>:void = Block{ X := Rush(Block{ Sleep(1.0); 1 }, \"two\"); 0 }", .code = .type_mismatch, .at = "\"two\"" },
        // A `Defer` open where a branch can be cancelled runs as a function there.
        // RFC-0085, I5: its landing shares a local `var` it assigns; a parameter is refused in
        // the copies at its exits, which are compiled first.
        .{ .source = "F(N:i64)<transacts><suspends>:i64 = Block{ Defer{ set N = 1 }; Sleep(1.0); N }\nG()<transacts><suspends>:void = Branch{ F(1) }", .code = .not_mutable, .at = "N" },
        // `Branch(...)` and `Rush` without its parenthesis are no forms.
        .{ .source = "F()<transacts><suspends>:void = Branch(1)", .code = .unknown_name, .at = "Branch" },
    }) |case| try expectRefused(h, case.source, case.code, case.at);
}

test "a Rush or a Branch in a loop's body is allowed where a function of its own lies between" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Step(N:i64)<transacts><suspends>:i64 = Block{ Branch{ Print("tick {N}") }; Rush(Block{ Sleep(0.1); N }, Block{ Sleep(0.2); 0 }) }
        \\Main()<transacts><suspends>:void = Block{
        \\    var N:i64 = 0
        \\    Loop{ set N = N + Step(N + 1); If(N > 5, Break(), 0) }
        \\    F := Fn()<transacts><suspends>:void{ Branch{ Print("in fn") } }
        \\    S := Sync(Block{ Loop{ X := Sync(Block{ Branch{ Print("in arm") }; Sleep(0.1); 1 }, Block{ Sleep(0.1); 2 }); Break() }; 1 }, Block{ F(); Sleep(0.1); 2 })
        \\    Print("n {N}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "tick 1\ntick 2\ntick 4\nin arm\nin fn\nn 7\n");
}

test "Rush and Branch yield to whatever the program declares by those names" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute("Rush(A:i64, B:i64)<computes>:i64 = A + B\nX:i64 = Rush(1, 2)");
    try std.testing.expectEqual(@as(i64, 3), x.get("X").?.integer);
    x = try h.execute("Rush(A:i64)<computes>:i64 = A * 2\nX:i64 = Rush(21)");
    try std.testing.expectEqual(@as(i64, 42), x.get("X").?.integer);
    x = try h.execute("F(Rush:function<transacts>(tuple(i64),i64), N:i64)<transacts>:i64 = Block{ X := Rush(If(N > 2, Return(N * 100), N)); X + 1 }\nG(N:i64)<transacts>:i64 = N * 2\nA:i64 = F(G, 1)\nB:i64 = F(G, 5)");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 500), x.get("B").?.integer);
    x = try h.execute("X:i64 = Block{ Branch := 7; Branch + 1 }");
    try std.testing.expectEqual(@as(i64, 8), x.get("X").?.integer);
    x = try h.execute("Branch(A:i64)<computes>:i64 = A + 1\nX:i64 = Branch(4)");
    try std.testing.expectEqual(@as(i64, 5), x.get("X").?.integer);
    // A class named `Branch` is built with braces, as the form is written.
    x = try h.execute("Branch := struct{ N:i64 }\nB:Branch = Branch{ N := 3 }\nX:i64 = B.N");
    try std.testing.expectEqual(@as(i64, 3), x.get("X").?.integer);
    // And it keeps its `Break` in its constructor in a loop, as a program's own `Spawn` does.
    x = try h.execute("Branch := struct{ N:i64 }\nF()<transacts>:i64 = Block{ var I:i64 = 0; Loop{ S := Branch{ N := If(I > 1, Break(), I) }; set I = I + 1 }; I }\nA:i64 = F()");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
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
    \\Plain(N:i64)<transacts><suspends>:i64 = N + 1
    \\Use(S:string)<transacts><suspends>:i64 = Block{
    \\    H := Plain
    \\    K := Fn()<transacts><suspends>:i64{ Block{ Sleep(0.5); 3 } }
    \\    Branch{ Leaf(9) }
    \\    P := Sync(Leaf(1), Leaf(2))
    \\    R := Rush(Leaf(3), Leaf(4))
    \\    P(0) + R + H(1) + K()
    \\}
    \\T:task(i64) = Spawn{ Use("s") }
;

test "forged branches and Rushes are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    _ = try expectRun(h, forged_source);
    var forged = forgeable(h, p);
    const branch = nth(p, .branch, 0);
    const sync = nth(p, .structured, 0);
    const rush = nth(p, .structured, 1);
    const base = p.functions[branch.function].body.start;
    const branch_node = p.function_nodes[base + branch.at].node;
    const sync_node = p.function_nodes[base + sync.at].node;
    const rush_node = p.function_nodes[base + rush.at].node;
    try std.testing.expect(rush_node.kind.structured.kind == .rush and sync_node.kind.structured.kind == .sync);
    // `H`, a function of a parameter; and the closure `K`, a function of none that suspends and
    // yields an `i64`.
    var plain: Place = .{ .function = branch.function, .at = 0 };
    var closure: usize = 0;
    var found_plain = false;
    for (p.function_nodes[base .. base + branch.at], 0..) |entry, at| {
        if (entry.input != .operation or entry.node.kind != .function_value) continue;
        const shape = @import("aggregate_types.zig").definition(entry.node.value_type, p.definitions).?.callable;
        const parameters = @import("aggregate_types.zig").definition(shape.parameters, p.definitions).?.tuple;
        if (parameters.end != parameters.start) {
            plain.at = at;
            found_plain = true;
        } else if (shape.result == .i64 and shape.detail.suspends) closure = at;
    }
    try std.testing.expect(closure != 0 and found_plain);
    const Forgery = struct { at: usize, node: types.Node };
    var cases: [10]Forgery = undefined;
    var count: usize = 0;
    // A branch typed as anything but the unit value; of a callable with a parameter, of one that
    // yields an `i64`, of a value that is no callable, and of a node after it.
    var node = branch_node;
    node.value_type = .i64;
    cases[count] = .{ .at = branch.at, .node = node };
    count += 1;
    node = branch_node;
    node.kind.branch = @intCast(plain.at);
    cases[count] = .{ .at = branch.at, .node = node };
    count += 1;
    node = branch_node;
    node.kind.branch = @intCast(closure);
    cases[count] = .{ .at = branch.at, .node = node };
    count += 1;
    node = branch_node;
    node.kind.branch = 0;
    cases[count] = .{ .at = branch.at, .node = node };
    count += 1;
    node = branch_node;
    node.kind.branch = @intCast(branch.at + 1);
    cases[count] = .{ .at = branch.at, .node = node };
    count += 1;
    // A rush typed as the tuple of its arms, a sync turned into a rush, a rush of one arm.
    node = rush_node;
    node.value_type = sync_node.value_type;
    cases[count] = .{ .at = rush.at, .node = node };
    count += 1;
    node = sync_node;
    node.kind.structured.kind = .rush;
    cases[count] = .{ .at = sync.at, .node = node };
    count += 1;
    node = rush_node;
    node.kind.structured.arms.end = node.kind.structured.arms.start + 1;
    cases[count] = .{ .at = rush.at, .node = node };
    count += 1;
    node = rush_node;
    node.value_type = .string;
    cases[count] = .{ .at = rush.at, .node = node };
    count += 1;
    for (cases[0..count]) |case| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        h.body[base + case.at].node = case.node;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("forged {any} admitted\n", .{case.node});
            return err;
        };
    }
    // A branch without its check after it.
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    h.body[base + branch.at + 1].node.kind = .{ .boolean = false };
    try harness.invalid(h, forged);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    // In a function that does not suspend.
    h.metadata[branch.function].detail = .{};
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // A body whose effects lie beyond the function's.
    h.metadata[branch.function].detail = .{ .no_writes = true, .suspends = true };
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // A branch's body made public, or renamed: an anonymous function is named `Fn` or by its form.
    var body_function: usize = 0;
    for (p.functions, 0..) |f, id| if (f.anonymous and std.mem.eql(u8, f.name.text(p.source), "Branch")) {
        body_function = id;
    };
    try std.testing.expect(body_function != 0);
    h.metadata[body_function].is_public = true;
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[body_function].name.end -= 1;
    try harness.invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    _ = &forged;
}

test "a forged schedule of branches, Rushes and frame ends is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("d{N}") }; Sleep(Inf); N }
        \\G()<transacts><suspends>:void = Block{ Branch{ Leaf(5) }; Print("g") }
        \\Owner()<transacts><suspends>:i64 = Block{ Branch{ Leaf(1) }; Branch{ Leaf(2) }; W := Rush(Leaf(3), Block{ Sleep(0.1); 4 }); W }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    A := Owner()
        \\    B := Race(Block{ Defer{ Print("arm") }; G(); Sleep(1.0); 0 }, Block{ Sleep(-1.0); 6 })
        \\    A + B
        \\}
        \\M:task(i64) = Spawn{ Main() }
    );
    _ = try reporting.validate(x, false, .{});
    try std.testing.expectEqual(@as(u64, 5), x.scheduler.canceled);
    const steps = x.call_steps;
    const Forgery = enum { frame_end_count, frame_end_resume, entry_check_dropped, branch_settle_value, branch_unit, swapped_owned, canceled_count, branch_start, frame_end_pc };
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var done = false;
        var index: usize = 0;
        while (index < steps.len and !done) : (index += 1) {
            const step = &h.steps[index];
            const f = x.program.functions[step.function];
            const at_end = step.pc == f.body.end - f.body.start;
            switch (forgery) {
                .frame_end_count => if (step.kind == .@"suspend" and at_end and step.value == .integer) {
                    step.value.integer += 1;
                    done = true;
                },
                .frame_end_resume => if (step.kind == .@"resume" and at_end) {
                    step.value = .{ .boolean = false };
                    done = true;
                },
                .frame_end_pc => if (step.kind == .@"suspend" and at_end and step.value == .integer) {
                    step.pc -= 1;
                    done = true;
                },
                .entry_check_dropped => if (step.kind == .resume_canceled and index > 0 and h.steps[index - 1].kind == .value and h.steps[index - 1].function == step.function) {
                    // A site that yields cancelled at its entry, said to have waited.
                    step.kind = .@"suspend";
                    step.value = .{ .boolean = false };
                    done = true;
                },
                .branch_settle_value => if (step.kind == .settle and std.mem.eql(u8, f.name.text(x.program.source), "Branch") and step.value == .boolean) {
                    step.value = .{ .boolean = true };
                    done = true;
                },
                .branch_unit => if (step.kind == .value and x.program.function_nodes[f.body.start + step.pc].node.kind == .branch) {
                    step.value = .{ .integer = 0 };
                    done = true;
                },
                .swapped_owned => if (step.kind == .resume_canceled) {
                    var other = index + 1;
                    while (other < steps.len and h.steps[other].kind != .resume_canceled) other += 1;
                    if (other < steps.len) {
                        std.mem.swap(types.CallStep, step, &h.steps[other]);
                        done = true;
                    }
                },
                .canceled_count => {
                    forged.scheduler.canceled += 1;
                    done = true;
                },
                .branch_start => if (step.kind == .start and std.mem.eql(u8, f.name.text(x.program.source), "Branch")) {
                    step.value.integer += 1;
                    done = true;
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

test "the same program of branches and Rushes needs the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Leaf(N:i64)<transacts><suspends>:i64 = Block{ Defer{ Print(\"d{N}\") }; Sleep(Inf); N }\nOwner()<transacts><suspends>:i64 = Block{ Branch{ Leaf(1) }; Branch{ Sync(Leaf(2), Leaf(3)) }; W := Rush(Leaf(4), Block{ Sleep(0.1); 5 }); W }\nM:task(i64) = Spawn{ Owner() }",
        "G()<transacts><suspends>:void = Block{ Branch{ Defer{ Print(\"b\") }; Sleep(5.0) }; Print(\"g\") }\nMain()<transacts><suspends>:i64 = Race(Block{ Defer{ Print(\"a\") }; G(); Sleep(1.0); 1 }, Block{ Sleep(-1.0); 2 })\nM:task(i64) = Spawn{ Main() }",
        "Arm(N:i64, S:float)<transacts><suspends>:i64 = Block{ Defer{ Print(\"a{N}\") }; Sleep(S); N }\nF()<transacts><suspends>:i64 = Block{ W := Rush(Arm(1, 0.3), Arm(2, 0.1), Arm(3, 0.2)); Branch{ Print(\"b\") }; Sleep(1.0); W }\nM:task(i64) = Spawn{ F() }",
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

test "branches and Rush losers in a digest run that reclaims report as a stored run, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Arm(N:i64, S:float)<transacts><suspends>:i64 = Block{ J := Many(6); Sleep(S); K := Many(6); N + J + K }
        \\Slow()<transacts><suspends>:i64 = Block{ Defer{ X := Many(5) }; Sleep(Inf); 0 }
        \\Owner()<transacts><suspends>:i64 = Block{
        \\    Branch{ Arm(9, 0.05) }
        \\    Branch{ Slow() }
        \\    W := Rush(Slow(), Arm(4, 0.1), Arm(5, 0.2))
        \\    A := Many(8)
        \\    Sleep(0.3)
        \\    W + A
        \\}
        \\M:task(i64) = Spawn{ Owner() }
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

/// The scale test of P3.4: a binary tree of branches `depth` levels deep, each frame owning
/// two, the leaves waiting for ever, cancelled from its root when a `Race` beside it resolves.
/// Each frame's end asks its two branches and waits for them, so the cancellation goes down
/// the tree one level per turn of the scheduler, on its queue, and the native stack does not
/// grow with it; every leaf's `Defer` runs before the root's frame ends. Prints how long each
/// machine and the replay took.
pub fn branchTree(h: *harness.Harness, depth: u32) !void {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try out.writeAll("var Cleaned:i64 = 0\nN0()<transacts><suspends>:void = Block{ Defer{ set Cleaned = Cleaned + 1 }; Sleep(Inf) }\n");
    for (1..depth + 1) |level| try out.print("N{d}()<transacts><suspends>:void = Block{{ Branch{{ N{d}() }}; Branch{{ N{d}() }}; Sleep(Inf) }}\n", .{ level, level - 1, level - 1 });
    try out.print("Main()<transacts><suspends>:i64 = Block{{ W := Race(Block{{ N{d}(); 0 }}, Block{{ Sleep(1.0); 1 }}); W + Cleaned }}\nT:task(i64) = Spawn{{ Main() }}\n", .{depth});
    const p = try h.compile(out.buffered());
    const budget: u64 = 1 << 40;
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("branch tree failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    const tree = (@as(u64, 1) << @intCast(depth + 1)) - 2;
    try std.testing.expectEqual(tree + 3, actual.ok.scheduler.created);
    try std.testing.expectEqual(@as(u64, 2), actual.ok.scheduler.completed);
    try std.testing.expectEqual(tree + 1, actual.ok.scheduler.canceled);
    try std.testing.expectEqual(@as(usize, 0), actual.ok.scheduler.waiting.len);
    _ = try reporting.validate(actual.ok, false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("a tree of {d} branches cancelled by their frames' ends: reference={d}ms vm={d}ms replay={d}ms\n", .{ tree, referenced, ran - referenced, elapsed(start) - ran });
    var report: [1024]u8 = undefined;
    var written: std.Io.Writer = .fixed(&report);
    _ = try reporting.write(&written, actual.ok, false, .{ .work = std.math.maxInt(u64) });
    var expected: [64]u8 = undefined;
    // The winner, 1, and one `Defer` per leaf.
    try std.testing.expect(std.mem.indexOf(u8, written.buffered(), try std.fmt.bufPrint(&expected, "\"result\":{d}", .{1 + (@as(u64, 1) << @intCast(depth))})) != null);
}

test "a tree of branches cancelled by their frames' ends, at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    try branchTree(h, 4);
}

test "review: a program with no Rush, Branch, Sync or Race keeps its IR; one with a Branch gets landings" {
    const h = try harness.create();
    defer scratch.release(h);
    // A `Defer` open at a site gets a landing once a task can be cancelled: here by the end of
    // the frame that owns a branch (P3.4 widens C37). The landing runs where the branch is
    // cancelled, with the locals as they are at its site.
    const x = try expectPrinted(h,
        \\Worker(N:i64)<transacts><suspends>:void = Block{ var K:i64 = N; Defer{ Print("worker {K}") }; set K = K + 1; Sleep(Inf) }
        \\Owner()<transacts><suspends>:void = Block{ Branch{ Worker(7) }; Sleep(0.1); Print("owner") }
        \\T:task(void) = Spawn{ Owner() }
    , "owner\nworker 8\n");
    try expectCounts(x, 2, 1, 1, 0);
    const p = try h.compile("Worker(N:i64)<transacts><suspends>:void = Block{ Defer{ Print(\"w\") }; Sleep(Inf) }\nOwner()<transacts><suspends>:void = Branch{ Worker(1) }\nT:task(void) = Spawn{ Owner() }");
    var invokes: usize = 0;
    for (p.function_nodes) |entry| invokes += @intFromBool(entry.input == .operation and entry.node.kind == .invoke);
    try std.testing.expect(invokes != 0);
    // Without any of the four forms no task can be cancelled, and no landing is made.
    const plain = try h.compile("Worker(N:i64)<transacts><suspends>:void = Block{ Defer{ Print(\"w\") }; Sleep(Inf) }\nT:task(void) = Spawn{ Worker(1) }");
    for (plain.function_nodes) |entry| try std.testing.expect(entry.input != .operation or entry.node.kind != .invoke);
}

test "a Rush in a bundle: each module's arms take words of its own block, and its losers stay with the frame" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nMain()<transacts><suspends>:i64 = Block{ W := Rush(L.Work(1, 0.5), L.Work(2, 0.25)); Branch{ L.Work(3, 2.0) }; W }\nT:task(i64) = Spawn{ Main() }" },
        .{ .path = "lib.forb", .source = "Work<public>(N:i64, S:float)<transacts><suspends>:i64 = Block{ Defer{ Print(\"w{N}\") }; X := Rush(Block{ Sleep(S); N }, Block{ Sleep(Inf); 0 }); X * 10 }" },
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
    // Work(2) wins after its Rush's loser is cancelled at its frame's end; Work(1) goes on, as
    // the branch does, until Main's end cancels both.
    try std.testing.expectEqualStrings("w2\nw1\nw3\n", printed(x, &buffer));
}

test "Rush and Branch in a generic function: each specialization's bodies and arms are its own" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Pick[T:type](A:T, B:T)<transacts><suspends>:T{ Block{
        \\    Branch{ Defer{ Print("branch of pick") }; Sleep(Inf) }
        \\    Rush(Block{ Sleep(0.1); A }, Block{ Sleep(0.2); B })
        \\} }
        \\Main()<transacts><suspends>:void = Block{
        \\    I := Pick[i64](1, 2)
        \\    S := Pick[string]("a", "b")
        \\    Print("{I} {S}")
        \\}
        \\T:task(void) = Spawn{ Main() }
    , "branch of pick\nbranch of pick\n1 a\n");
}

test "a branch of a branch of a Spawn body: a task asked while it waits at its end still completes" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\T:task(void) = Spawn{ Block{ Branch{ Branch{ Defer{ Print("inner gone") }; Sleep(Inf) }; Print("x") }; Print("y") } }
    , "x\ny\ninner gone\n");
    // The Spawn body and the outer branch complete; the inner branch is cancelled.
    try expectCounts(x, 3, 2, 1, 0);
}

test "review F1: a Branch in a Fn in a Defer body copied to several exits and into landings takes a word of its own per copy" {
    const h = try harness.create();
    defer scratch.release(h);
    // Copies at a `Return` and at the end of the block.
    var x = try expectPrinted(h,
        \\F(N:i64)<transacts>:i64 = Block{
        \\    Defer{ G := Fn()<transacts><suspends>:void{ Branch{ Print("x") } }; Print("d") }
        \\    If(N > 0, Return(1), 0)
        \\    2
        \\}
        \\A:i64 = F(1)
        \\B:i64 = F(0)
    , "d\nd\n");
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
    // A copy into the landing of a site too, with two branches in the function.
    x = try expectPrinted(h,
        \\F()<transacts><suspends>:i64 = Block{
        \\    Defer{ G := Fn()<transacts><suspends>:void{ Block{ Branch{ Print("x") }; Branch{ Print("y") } } }; Print("d") }
        \\    Sleep(Inf)
        \\    2
        \\}
        \\Main()<transacts><suspends>:i64 = Race(F(), Block{ Sleep(0.1); 3 })
        \\T:task(i64) = Spawn{ Main() }
    , "d\n");
    var bodies: usize = 0;
    for (x.program.functions) |f| bodies += @intFromBool(f.anonymous and std.mem.eql(u8, f.name.text(x.program.source), "Branch"));
    // Two in the landing's copy and two in the copy at the block's end.
    try std.testing.expectEqual(@as(usize, 4), bodies);
}

test "review F2: a Rush whose parent was asked to cancel resolves nothing; an arm that then completes is waited for" {
    const h = try harness.create();
    defer scratch.release(h);
    // A1 is waiting at Deep's end when the Race asks P, and so the Rush's record, to cancel: it
    // only takes the flag, and completes once Deep's branch has settled. The cancelled Rush does
    // not resolve: P waits for A2 too, whose branches unwind first, and then yields cancelled.
    _ = try expectPrinted(h,
        \\Deep()<transacts><suspends>:void = Block{ Branch{ Defer{ Print("deep") }; Sleep(Inf) }; Print("deep end") }
        \\A1()<transacts><suspends>:i64 = Block{ Deep(); Print("a1 completes"); 1 }
        \\L3()<transacts><suspends>:void = Block{ Defer{ Print("l3") }; Sleep(Inf) }
        \\L2()<transacts><suspends>:void = Block{ Branch{ L3() }; Sleep(Inf) }
        \\A2()<transacts><suspends>:i64 = Block{ Defer{ Print("a2 defer") }; Branch{ L2() }; Sleep(Inf); 2 }
        \\P()<transacts><suspends>:i64 = Block{ Defer{ Print("p defer") }; W := Rush(A1(), A2()); Print("never {W}"); W }
        \\Main()<transacts><suspends>:i64 = Block{ X := Race(P(), Block{ Sleep(-1.0); 9 }); Print("race {X}"); X }
        \\T:task(i64) = Spawn{ Main() }
    , "deep end\ndeep\na2 defer\na1 completes\nl3\np defer\nrace 9\n");
}

test "review F3: each visit of Iterate, a call of its function, waits at its end for the tasks it owns" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Step(S:i64)<transacts><suspends>:i64 = Block{ Defer{ Print("step defer {S}") }; Branch{ Defer{ Print("b {S}") }; Sleep(Inf) }; Sleep(0.1); S + 1 }
        \\Main()<transacts><suspends>:void = Block{ X := Iterate(Step, 3, 0); Print("x {X}") }
        \\T:task(void) = Spawn{ Main() }
    , "step defer 0\nb 0\nstep defer 1\nb 1\nstep defer 2\nb 2\nx 3\n");
    // A program's own state loop the same: each visit of its function is a call of it.
    _ = try expectPrinted(h,
        \\Visit(S:i64)<transacts><suspends>:option(i64) = Block{
        \\    W := Rush(Block{ Defer{ Print("w {S}") }; Sleep(Inf); 0 }, Block{ Sleep(0.1); S })
        \\    If(S < 2, option{S + 1}, option{})
        \\}
        \\Main()<transacts><suspends>:void = Block{ X := Loop(Visit, 0); Print("x {X}") }
        \\T:task(void) = Spawn{ Main() }
    , "w 0\nw 1\nw 2\nx 2\n");
}
