//! Reactions, P4.4 (RFC-0084): `Upon` and `When`, notifications, the pending list and its
//! region marks, delivery points and the delivery loop, firings, in both machines, the report
//! replay and every trace mode.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const trace_replay = @import("trace_replay.zig");
const reporting = @import("value_report.zig");
test {
    _ = @import("reaction_forgery_tests.zig");
}

/// Both machines stop with `code`, at the same place, in a run that keeps no steps.
pub fn expectFailureCode(source: []const u8, code: types.Diagnostic.Code) !void {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.off, types.ControlStorage.default_trace_window);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, live.fuel);
    const actual = f.h.runtime.evaluate(p, live.fuel);
    if (reference != .failed or actual != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, reference.failed.code);
    try std.testing.expectEqual(code, actual.failed.code);
    try std.testing.expectEqualDeep(reference.failed.span, actual.failed.span);
}

/// Both machines stop with `code` at the text `at` in a run that keeps no steps: a bound that
/// a `full` run could only reach after `call_trace_limit`.
pub fn expectFailureOff(source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.off, types.ControlStorage.default_trace_window);
    // A delivery loop at the program profile's bound takes more fuel than `live.fuel`.
    const budget: u64 = 1 << 40;
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const actual = f.h.runtime.evaluate(p, budget);
    if (reference != .failed or actual != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, reference.failed.code);
    try std.testing.expectEqual(code, actual.failed.code);
    try std.testing.expectEqualDeep(reference.failed.span, actual.failed.span);
    try std.testing.expectEqualStrings(at, p.source[reference.failed.span.start..reference.failed.span.end]);
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}
fn logic(execution: evaluator.Execution, name: []const u8) !bool {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.boolean;
}

test "Book 15:454: an Upon fires once, when its guard first holds" {
    const source =
        \\var Health:i64 = 100
        \\var IsDead:logic = false
        \\Dead:task(logic) = Upon(Health <= 0, Set(IsDead, true))
        \\set Health = 50
        \\A:logic = IsDead
        \\set Health = 0
        \\B:logic = IsDead
        \\set IsDead = false
        \\set Health = -10
        \\C:logic = IsDead
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expect(!try logic(x, "A"));
    try std.testing.expect(try logic(x, "B"));
    try std.testing.expect(!try logic(x, "C"));
    try std.testing.expectEqual(@as(u64, 1), x.live.firings);
    try live.expectEveryMode(source);
}

test "Book 15:484: a When runs at once, and after every write of what its guard reads" {
    const source =
        \\var Score:i64 = 0
        \\var Updates:i64 = 0
        \\Watch:task(void) = When(Score, Set(Updates, Updates + 1))
        \\A:i64 = Updates
        \\set Score = 100
        \\B:i64 = Updates
        \\set Score = 100
        \\C:i64 = Updates
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "C"));
    try live.expectEveryMode(source);
}

test "Book 15:506: two Whens that write each other's guards settle" {
    const source =
        \\var X:i64 = 2
        \\var Y:i64 = 2
        \\WY:task(void) = When(Y, Block{ Z := If(Y < 0, 0, Y - 1); If(Z != X, Set(X, Z), X) })
        \\WX:task(void) = When(X, Block{ Z := If(X < 0, 0, X - 1); If(Z != Y, Set(Y, Z), Y) })
        \\A:i64 = X
        \\B:i64 = Y
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, -1), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    try live.expectEveryMode(source);
}

test "Book 15:622: a region that fails takes back its notifications" {
    const source =
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\var Fired:i64 = 0
        \\U:task(i64) = Upon(X > 0, Set(Fired, Fired + 1))
        \\T:logic = Attempt(Block{ set live X = Y + 5; Require[X < 0]; true }, false)
        \\set Y = 10
        \\A:i64 = X
        \\B:i64 = Fired
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    try live.expectEveryMode(source);
}

test "Book 15:650: a When keeps derived state in step" {
    const source =
        \\var PlayerScore:i64 = 0
        \\var DisplayedScore:i64 = 0
        \\var ScoreText:string = ""
        \\W:task(void) = When(PlayerScore, Block{ set DisplayedScore = PlayerScore; Set(ScoreText, "Score: {PlayerScore}") })
        \\set PlayerScore = 42
        \\A:i64 = DisplayedScore
        \\B:string = ScoreText
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 42), try integer(x, "A"));
    try std.testing.expectEqualStrings("Score: 42", x.get("B").?.string);
    try live.expectEveryMode(source);
}

fn reportOf(execution: evaluator.Execution, buffer: []u8) ![]const u8 {
    return live.report(execution, buffer);
}
fn expectInReport(execution: evaluator.Execution, needle: []const u8) !void {
    var buffer: [16384]u8 = undefined;
    const text = try reportOf(execution, &buffer);
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("report {s} lacks {s}\n", .{ text, needle });
        return error.TestUnexpectedResult;
    }
}

test "observers are delivered in the order of their first trigger, each once, and a failed region notifies none" {
    const source =
        \\var A:i64 = 0
        \\var B:i64 = 0
        \\var Log:string = ""
        \\W1:task(void) = When(A, Set(Log, Log + "1"))
        \\W2:task(void) = When(B, Set(Log, Log + "2"))
        \\W3:task(void) = When(A + B, Set(Log, Log + "3"))
        \\set B = 1
        \\R:logic = Attempt(Block{ set A = 1; set B = 2; set A = 3; true }, false)
        \\F:logic = Attempt(Block{ set A = 9; Require[A < 0]; true }, false)
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("12323132", x.get("L").?.string);
    try std.testing.expectEqual(@as(u64, 8), x.live.firings);
    try live.expectEveryMode(source);
}

test "a reaction made in a region starts when it commits, and never when it fails" {
    const source =
        \\var X:i64 = 1
        \\var N:i64 = 0
        \\A:logic = Attempt(Block{ U:task(i64) = Upon(X > 0, Set(N, N + 1)); Require[X > 5]; true }, false)
        \\B:logic = Attempt(Block{ V:task(i64) = Upon(X > 0, Set(N, N + 10)); true }, false)
        \\C:i64 = N
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "C"));
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.created);
    try std.testing.expectEqual(@as(u64, 1), x.scheduler.completed);
    try live.expectEveryMode(source);
}

test "a When made in a function hands its node the handle, and waits on its guard at the end" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Make(K:string)<transacts>:task(void) = When(X > 2, Set(Log, Log + K))
        \\W:task(void) = Make("a")
        \\set X = 3
        \\set X = 1
        \\set X = 4
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("aa", x.get("L").?.string);
    try expectInReport(x, "\"kind\":\"when\",\"wait\":\"guard\"");
    try live.expectEveryMode(source);
}

test "a When that writes what its guard reads runs once for each write by other code" {
    const source =
        \\var X:i64 = 3
        \\C:task(void) = When(X, If(X > 10, Set(X, 10), X))
        \\set X = 20
        \\A:i64 = X
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "A"));
    try std.testing.expectEqual(@as(u64, 2), x.live.firings);
    try live.expectEveryMode(source);
}

test "two Whens that feed each other end with reaction_limit" {
    try expectFailureOff(
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\A:task(void) = When(X, Set(Y, Y + 1))
        \\B:task(void) = When(Y, Set(X, X + 1))
    , .reaction_limit, "When");
}

test "an Upon's handle completes with its body's result, and wakes its awaiters" {
    const source =
        \\var X:i64 = 0
        \\var Got:i64 = 0
        \\U:task(i64) = Upon(X > 0, X * 2)
        \\T:task(i64) = Spawn{ Set(Got, U.Await()) }
        \\set X = 5
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try expectInReport(x, "\"Got\":10");
    try live.expectEveryMode(source);
}

test "a reaction made by a body fires inside it, and the outer body goes on" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\Outer:task(void) = When(X > 0, Block{ Inner:task(string) = Upon(X > 1, Set(Log, Log + "i")); Set(Log, Log + "o") })
        \\set X = 1
        \\set X = 2
        \\L:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("oiio", x.get("L").?.string);
    try live.expectEveryMode(source);
}

test "the diagnostics of reactions, each where it is written" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .source = "F()<transacts><suspends>:void = Block{ W:task(void) = When(1, Sleep(1.0)); }", .code = .reaction_body_suspends, .at = "Sleep" },
        .{ .source = "F()<transacts>:i64 = Block{ W:task(void) = When(1, Return(1)); 1 }", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts>:i64 = Block{ W:task(void) = When(Return(1), 1); 1 }", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "var X:i64 = 0\nW:task(void) = When(Set(X, 1), 1)", .code = .guard_effect, .at = "X" },
        .{ .source = "c:=class{}\nW:task(void) = When(c{}, 1)", .code = .guard_effect, .at = "c" },
        .{ .source = "U:task(i64) = Upon(Print(\"x\"), 1)", .code = .guard_effect, .at = "Print" },
        .{ .source = "F()<transacts><suspends>:void = Block{ W:task(void) = When(Sleep(1.0), 1); }", .code = .guard_effect, .at = "Sleep" },
        // RFC-0085, I14: a guard that names a local `var` shares it (S1b), and may not write it.
        .{ .source = "F()<transacts>:i64 = Block{ var L:i64 = 0; W:task(void) = When(Set(L, 1), 1); 1 }", .code = .guard_effect, .at = "L" },
        .{ .source = "F()<transacts>:i64 = Block{ L:i64 = 0; W:task(void) = When(Set(L, 2), 1); 1 }", .code = .guard_effect, .at = "L" },
        // RFC-0085, I5: a local `var` the body assigns is shared (`shared_local_task_tests.zig`).
        .{ .source = "F()<transacts>:i64 = Block{ L:i64 = 0; W:task(void) = When(1, Set(L, 2)); 1 }", .code = .arm_assigns_local, .at = "L" },
        .{ .source = "F()<reads>:task(void) = When(1, 1)", .code = .call_requires_allocates, .at = "When" },
        .{ .source = "F()<allocates>:task(void) = When(1, 1)", .code = .call_requires_reads, .at = "When" },
        .{ .source = "var A:[]i64 = array{1}\nW:task(void) = When(1, A[0])", .code = .failure_context_required, .at = "[" },
        .{ .source = "W:task(void) = When(1)", .code = .argument_count, .at = "When" },
        .{ .source = "W:task(void) = When(1, 2, 3)", .code = .argument_count, .at = "," },
    };
    for (cases) |case| try live.expectRefused(h, case.source, case.code, case.at);
}

test "a guard that fails holds back its reaction; a loop of its own in a body is no exit" {
    const source =
        \\var A:[]i64 = array{}
        \\var N:i64 = 0
        \\U:task(i64) = Upon(A[0] > 1, Block{ Loop{ Break() }; Set(N, 7) })
        \\set A = array{1}
        \\B:i64 = N
        \\set A = array{2}
        \\C:i64 = N
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 7), try integer(x, "C"));
    try live.expectEveryMode(source);
}

test "Upon and When yield to what the program declares by their names" {
    const h = try harness.create();
    defer scratch.release(h);
    const function = try live.run(h, "When(X:i64, Y:i64)<computes>:i64 = X + Y\nV:i64 = When(3, 4)");
    try std.testing.expectEqual(@as(i64, 7), try integer(function, "V"));
    const parameter = try live.run(h, "F(Upon:i64)<computes>:i64 = Upon + 1\nV:i64 = F(2)");
    try std.testing.expectEqual(@as(i64, 3), try integer(parameter, "V"));
    const binding = try live.run(h, "var When:i64 = 5\nset When = 6\nV:i64 = When");
    try std.testing.expectEqual(@as(i64, 6), try integer(binding, "V"));
    const method = try live.run(h, "c:=class{ Upon(X:i64)<computes>:i64 = X * 2 }\nO:c = c{}\nV:i64 = O.Upon(4)");
    try std.testing.expectEqual(@as(i64, 8), try integer(method, "V"));
}

test "a reaction made in a function's region starts in the drain of its commit" {
    const source =
        \\var X:i64 = 1
        \\var N:i64 = 0
        \\F()<transacts>:i64 = Block{ R:logic = Attempt(Block{ W:task(void) = When(X, Set(N, N + X)); true }, false); N }
        \\A:i64 = F()
        \\set X = 5
        \\B:i64 = N
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "B"));
    try live.expectEveryMode(source);
}

test "a Return from an arm that commits to depth 0 delivers what its region notified" {
    // Review F1: `arm_exit` commits the arm's regions as `exit` does, so it is a delivery point.
    const source =
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\W:task(void) = When(X, Set(N, N + 1))
        \\F()<transacts><suspends>:i64 = Block{
        \\    R := Race(Block{ Sleep(1.0); 0 }, Block{ Sleep(0.1); Attempt(Block{ set X = 1; Return(5) }, 9) })
        \\    R
        \\}
        \\T:task(i64) = Spawn{ F() }
        \\Seen:i64 = N
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The When ran at its creation, and once more when the arm's exit committed `set X = 1`.
    try std.testing.expectEqual(@as(u64, 2), x.live.firings);
    try std.testing.expectEqual(@as(u64, 1), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a program without reactions drains a function's commit as before P4.4, with the same failures" {
    // Review F2: only a program that holds a `reaction` takes a drain's turns in the frame
    // loop. Main's commit hands its three starts their turns, with the held signal between
    // them, while the root's `T` hands off; the program with a live cell after that stops at
    // every budget that runs out before the cell with the code and at the node of the program
    // without it, which P4.4 leaves alone.
    const plain =
        \\E:event(i64) = event(i64){}
        \\Ear(N:i64)<transacts><suspends>:void = Loop{ V := E.Await(); Print("ear{N} {V}") }
        \\Body(N:i64)<transacts><suspends>:void = Print("task {N}")
        \\Main()<transacts><suspends>:void = Block{
        \\    Z := Attempt(Block{ A := Spawn{ Ear(1) }; E.Signal(3); B := Spawn{ Body(2) }; C := Spawn{ Body(3) }; true }, false)
        \\    Sleep(0.0)
        \\    Print("end")
        \\}
        \\T:task(void) = Spawn{ Main() }
        \\
    ;
    const with_live = plain ++ "var live L:i64 = 1\n";
    const h = try harness.create();
    defer scratch.release(h);
    const p_plain = try h.compile(plain);
    const p_live = try h.compile(with_live);
    var compared: u64 = 0;
    var at: u64 = 1;
    while (at < 400) : (at += 1) {
        const live_outcome = try h.run(p_live, at);
        try std.testing.expect(live_outcome == .failed);
        if (live_outcome.failed.span.start >= plain.len) break;
        const outcome = try h.run(p_plain, at);
        try std.testing.expect(outcome == .failed);
        try std.testing.expectEqual(outcome.failed.code, live_outcome.failed.code);
        try std.testing.expectEqualDeep(outcome.failed.span, live_outcome.failed.span);
        compared += 1;
    }
    // Every budget up to Main's first wait, the drain's turns included.
    try std.testing.expect(compared > 30 and at < 400);
}

test "a drain begun inside another frame's drain leaves that frame's own place to it" {
    // Review F3: each draining frame keeps the node of the commit that began its drain. G's
    // drain starts W, whose body calls Inner: Inner's commit begins a drain of its own, in its
    // frame. The body's write is delivered when the firing ends, on G's drain, and the
    // `reaction_limit` of P and Q must fall at G's `Attempt`, not at Inner's.
    const source =
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\P:task(void) = When(X, If(X > 0, Set(Y, X - 1), 0))
        \\Q:task(void) = When(Y, If(Y > 0, Set(X, Y - 1), 0))
        \\Inner()<transacts>:logic = Attempt(Block{ T:task(i64) = Spawn{ 1 }; true }, false)
        \\G()<transacts>:logic = Attempt(Block{ W:task(void) = When(1, Block{ I := Inner(); Set(X, 10000000) }); true }, false)
        \\A:logic = G()
    ;
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.off, types.ControlStorage.default_trace_window);
    const budget: u64 = 1 << 40;
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const actual = f.h.runtime.evaluate(p, budget);
    if (reference != .failed or actual != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.Diagnostic.Code.reaction_limit, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.reaction_limit, actual.failed.code);
    // G's region commits at its `otherwise`, the `, false)` of its Attempt (Inner's is earlier).
    const g = ", false)\nA:logic";
    const at: u32 = @intCast(std.mem.indexOf(u8, source, g).?);
    try std.testing.expectEqual(at, reference.failed.span.start);
    try std.testing.expectEqualDeep(reference.failed.span, actual.failed.span);
}

test "reactions: every fuel budget stops both machines at the same node" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\U:task(i64) = Upon(X > 1, X * 10)
        \\W:task(void) = When(X, Set(N, N + X))
        \\F()<transacts>:i64 = Block{ set X = 1; R:logic = Attempt(Block{ set X = 2; true }, false); N }
        \\A:i64 = F()
        \\set X = 3
    ;
    const p = try h.compile(source);
    _ = (try h.run(p, live.fuel)).ok;
    var budget: u64 = 1;
    var stopped: u64 = 0;
    while (budget < 600) : (budget += 1) {
        const outcome = try h.run(p, budget);
        if (outcome == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
        stopped += 1;
    }
    try std.testing.expect(stopped > 40 and budget < 600);
}

test "reactions: a reclamation keeps what a waiting reaction's guard and body capture" {
    // The function's frames reclaim the arrays each call leaves behind; the When made in the
    // first call holds the captured `Scale` and `Offsets` in its guard and body, which every
    // reclamation must keep and move.
    const source =
        \\var X:i64 = 0
        \\var Sum:i64 = 0
        \\Watch(Scale:i64)<transacts>:task(void) = Block{
        \\    Offsets:[]i64 = array{1, 2, 3}
        \\    When(X * Scale > Offsets[0], Set(Sum, Sum + X * Scale + Offsets.Length))
        \\}
        \\W:task(void) = Watch(5)
        \\Bump(K:i64)<transacts>:i64 = Block{ T:[]i64 = array{K, K, K, K, K, K, K, K}; set X = K; K + T.Length - 7 }
        \\A:i64 = Iterate(Bump, 40, 0)
        \\B:i64 = Sum
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // Every write but X = 0 makes the guard hold: 5K + 3 for K in 1..39.
    try std.testing.expectEqual(@as(i64, 5 * 39 * 40 / 2 + 3 * 39), try integer(x, "B"));
    try std.testing.expect(try live.everyMode(source) > 0);
}

test "the replay refuses forged steps of reactions: deliveries out of order or left out, another firing, another record" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var A:i64 = 0
        \\var Log:string = ""
        \\W1:task(void) = When(A > 1, Set(Log, Log + "1"))
        \\W2:task(void) = When(A, Set(Log, Log + "2"))
        \\set A = 1
        \\set A = 2
    );
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    var delivers: [8]usize = undefined;
    var deliver_count: usize = 0;
    var fires: [8]usize = undefined;
    var fire_count: usize = 0;
    for (steps, 0..) |step, index| {
        if (step.kind == .deliver) {
            delivers[deliver_count] = index;
            deliver_count += 1;
        }
        if (step.kind == .fire) {
            fires[fire_count] = index;
            fire_count += 1;
        }
    }
    // W2 fires at creation; then W1 and W2 are delivered at each write; W1 fires at the second.
    try std.testing.expectEqual(@as(usize, 4), deliver_count);
    try std.testing.expectEqual(@as(usize, 4), fire_count);
    var forged = x;
    forged.call_steps = steps;
    _ = try reporting.validate(forged, false, .{});
    // The two deliveries of the first write in the other order.
    const first = steps[delivers[0]].value;
    steps[delivers[0]].value = steps[delivers[1]].value;
    steps[delivers[1]].value = first;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[delivers[1]].value = steps[delivers[0]].value;
    steps[delivers[0]].value = first;
    // A delivery left out.
    var shorter = forged;
    const without = try std.testing.allocator.alloc(types.CallStep, steps.len - 1);
    defer std.testing.allocator.free(without);
    @memcpy(without[0..delivers[2]], steps[0..delivers[2]]);
    @memcpy(without[delivers[2]..], steps[delivers[2] + 1 ..]);
    shorter.call_steps = without;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(shorter, false, .{}));
    // A firing of the other reaction, and a firing step where the guard failed.
    const fired = steps[fires[1]].value;
    steps[fires[1]].value = steps[delivers[0]].value;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[fires[1]].value = fired;
    const delivered = steps[delivers[0]].kind;
    steps[delivers[0]].kind = .fire;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[delivers[0]].kind = delivered;
    // The run's record says something else.
    for ([_]usize{ 0, 1, 2 }) |field| {
        var record = forged;
        switch (field) {
            0 => record.live.deliveries += 1,
            1 => record.live.firings -= 1,
            else => record.scheduler.created += 1,
        }
        try std.testing.expectError(error.InvalidExecution, reporting.validate(record, false, .{}));
    }
    _ = try reporting.validate(forged, false, .{});
}

test "the replay refuses a firing whose guard failed, a delivery before its region commits and one too many" {
    // Review F5. W1's guard fails at the first write; the region's write is delivered when
    // the region commits.
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var A:i64 = 0
        \\var Log:string = ""
        \\W1:task(void) = When(A > 1, Set(Log, Log + "1"))
        \\W2:task(void) = When(A, Set(Log, Log + "2"))
        \\set A = 1
        \\set A = 2
        \\R:logic = Attempt(Block{ set A = 3; true }, false)
    );
    _ = try reporting.validate(x, false, .{});
    const steps = x.call_steps;
    var delivers: [8]usize = undefined;
    var deliver_count: usize = 0;
    var w1_fire: ?types.CallStep = null;
    for (steps, 0..) |step, index| {
        if (step.kind == .deliver) {
            delivers[deliver_count] = index;
            deliver_count += 1;
        }
    }
    for (steps) |step| {
        if (step.kind == .fire and w1_fire == null and std.meta.eql(step.value, steps[delivers[0]].value)) w1_fire = step;
    }
    // Two deliveries at each of the three points; W1 is delivered first at the first write.
    try std.testing.expectEqual(@as(usize, 6), deliver_count);
    try std.testing.expect(w1_fire != null);
    const longer = try std.testing.allocator.alloc(types.CallStep, steps.len + 1);
    defer std.testing.allocator.free(longer);
    var forged = x;
    forged.call_steps = longer;
    // A firing of W1 right after its guard failed, before the next delivery.
    @memcpy(longer[0..delivers[1]], steps[0..delivers[1]]);
    longer[delivers[1]] = w1_fire.?;
    @memcpy(longer[delivers[1] + 1 ..], steps[delivers[1]..]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    // One delivery more after the last, of a reaction that is waiting and not notified.
    @memcpy(longer[0..steps.len], steps);
    longer[steps.len] = steps[delivers[5]];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    longer[steps.len] = steps[delivers[4]];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    // The region's first delivery a step sooner, before the region has committed.
    var sooner = x;
    const moved = try std.testing.allocator.dupe(types.CallStep, steps);
    defer std.testing.allocator.free(moved);
    sooner.call_steps = moved;
    std.mem.swap(types.CallStep, &moved[delivers[4]], &moved[delivers[4] - 1]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(sooner, false, .{}));
    // And a delivery while the region is open: the region's write's own step followed by one.
    var inside = x;
    const extra = try std.testing.allocator.alloc(types.CallStep, steps.len + 1);
    defer std.testing.allocator.free(extra);
    inside.call_steps = extra;
    var refused: usize = 0;
    var at = delivers[3] + 1;
    while (at < delivers[4]) : (at += 1) {
        @memcpy(extra[0..at], steps[0..at]);
        extra[at] = steps[delivers[4]];
        @memcpy(extra[at + 1 ..], steps[at..]);
        try std.testing.expectError(error.InvalidExecution, reporting.validate(inside, false, .{}));
        refused += 1;
    }
    try std.testing.expect(refused > 0);
}

const live_fields = @import("live_field_tests.zig");

/// Scale test 3 (RFC-0084): one cell read by `records` live fields and by `watchers` Whens; one
/// write of it evaluates each record once and delivers to each When once, which fires. The
/// records are a list built by `Iterate`: a `For` that makes instances costs time quadratic in
/// their count in both machines, with or without live fields (an open item of P4.4).
pub fn fanOut(f: trace_replay.Fixture, records: usize, watchers: usize) !void {
    var text: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&text,
        \\var S:i64 = 0
        \\var Count:i64 = 0
        \\follower := class{{ var live V:i64 = S * 2; Next:option(follower) }}
        \\Push(P:option(follower))<transacts>:option(follower) = option{{follower{{Next := P}}}}
        \\Kept:option(follower) = Iterate(Push, {d}, option{{}})
        \\Watch(K:i64)<transacts>:task(void) = When(S, Set(Count, Count + 1))
        \\W:[]task(void) = For(K:1..{d}, Watch(K))
        \\set S = 21
        \\A:i64 = Attempt(Block{{ H := Kept?; H.V }}, 0)
        \\B:i64 = Count
    , .{ records, watchers });
    const x = try live_fields.timed(f, "a fan-out of one cell to records and Whens", source);
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(2 * watchers)), x.get("B").?.integer);
    try std.testing.expectEqual(@as(u64, watchers), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 2 * watchers), x.live.firings);
}

/// Scale test 4: `writes` writes of a watched cell outside every region, each delivered to a
/// When that counts, in a digest run whose stores stay bounded.
pub fn watchedWrites(f: trace_replay.Fixture, writes: usize) !void {
    var text: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&text,
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\C:task(void) = When(X, Set(N, N + 1))
        \\Bump(K:i64)<transacts>:i64 = Block{{ T:[]i64 = array{{K, K, K, K}}; set X = K + T.Length; K + 1 }}
        \\A:i64 = Iterate(Bump, {d}, 0)
        \\B:i64 = N
    , .{writes});
    const x = try live_fields.timed(f, "writes of a watched cell", source);
    try std.testing.expectEqual(@as(i64, @intCast(writes + 1)), x.get("B").?.integer);
    try std.testing.expectEqual(@as(u64, writes), x.live.deliveries);
    try std.testing.expect(x.reclaims > 0);
}

/// Scale test 6: two Whens that hand a count down to each other deliver `count + 1` times after
/// one write of `count`: `deliveries - 1` is the most a delivery loop reaches, and one more is
/// `reaction_limit` at the write. (`live_record_evaluations` exactly and one more is the ring
/// test of P4.1.)
pub fn deliveryBound(f: trace_replay.Fixture) !void {
    const limit: i64 = types.limits.deliveries;
    var text: [512]u8 = undefined;
    for ([_]i64{ limit - 1, limit }) |count| {
        const source = try std.fmt.bufPrint(&text,
            \\var X:i64 = 0
            \\var Y:i64 = 0
            \\P:task(void) = When(X, If(X > 0, Set(Y, X - 1), 0))
            \\Q:task(void) = When(Y, If(Y > 0, Set(X, Y - 1), 0))
            \\set X = {d}
        , .{count});
        if (count == limit) {
            try expectFailureOff(source, .reaction_limit, "X");
            continue;
        }
        const x = try live_fields.timed(f, "deliveries at their bound", source);
        try std.testing.expectEqual(@as(u64, types.limits.deliveries), x.live.deliveries);
    }
}

test "the scale tests of reactions at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try fanOut(f, 60, 20);
    try watchedWrites(f, 2000);
    try deliveryBound(f);
}
