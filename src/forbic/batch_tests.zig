//! Batches, P4.5 (RFC-0084): `Batch{...}` holds notifications back until its outermost body has
//! returned, in both machines, the report replay and every trace mode: nested batches, a batch in
//! a region, a task handed off inside one, a reaction made inside one, and their refusals.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const reactions = @import("reaction_tests.zig");
const trace_replay = @import("trace_replay.zig");
const reporting = @import("value_report.zig");
test {
    _ = @import("batch_forgery_tests.zig");
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}
fn text(execution: evaluator.Execution, name: []const u8) ![]const u8 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.string;
}

test "Book 15:552: a batch delivers once, after its last write, and its observers see the final state" {
    const source =
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\var Notices:i64 = 0
        \\var NoticesInBatch:i64 = 0
        \\Never:task(void) = When(X > 1 and Y < 10, Set(Notices, Notices + 100))
        \\Watch:task(void) = When(X, Set(Notices, Notices + 1))
        \\Registered:i64 = Notices
        \\B:i64 = Batch{ set X = 2; set Y = 10; set X += 5; set NoticesInBatch = Notices; X }
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "Registered"));
    try std.testing.expectEqual(@as(i64, 7), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 7), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "NoticesInBatch"));
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "Notices"));
    // `Never` and `Watch` were notified by the first write of X, each once; the batch's end
    // delivered to both, and only `Watch` fired.
    try std.testing.expectEqual(@as(u64, 2), x.live.deliveries);
    try std.testing.expectEqual(@as(u64, 2), x.live.firings);
    try live.expectEveryMode(source);
}

test "nested batches deliver when the outermost ends, at the root and in a function" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\W:task(void) = When(X, Set(Log, Log + "w{X}"))
        \\Inner()<transacts>:string = Batch{ set X = 2; Log }
        \\A:string = Batch{ set X = 1; I := Inner(); set X = 3; Log + "|" + I }
        \\L1:string = Log
        \\B:string = Inner()
        \\L2:string = Log
        \\Outer()<transacts>:string = Batch{ C := Batch{ D := Batch{ set X = 4; Log }; set X = 5; D + Log }; C + Log }
        \\E:string = Outer()
        \\L3:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("w0|w0", try text(x, "A"));
    try std.testing.expectEqualStrings("w0w3", try text(x, "L1"));
    try std.testing.expectEqualStrings("w0w3", try text(x, "B"));
    try std.testing.expectEqualStrings("w0w3w2", try text(x, "L2"));
    try std.testing.expectEqualStrings("w0w3w2w0w3w2w0w3w2", try text(x, "E"));
    try std.testing.expectEqualStrings("w0w3w2w5", try text(x, "L3"));
    try std.testing.expectEqual(@as(u64, 3), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a batch in a region delivers when the region commits, and nothing when it fails" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\W:task(void) = When(X, Set(Log, Log + "w{X}"))
        \\R:logic = Attempt(Block{ B := Batch{ set X = 4; 0 }; Require[X < 0]; true }, false)
        \\L1:string = Log
        \\X1:i64 = X
        \\K:logic = Attempt(Block{ B := Batch{ set X = 5; 0 }; Inside := Log; true }, false)
        \\L2:string = Log
        \\F()<transacts>:string = Block{ R2:logic = Attempt(Block{ B := Batch{ set X = 6; 0 }; Require[X < 0]; true }, false); Log }
        \\L3:string = F()
        \\G()<transacts>:string = Block{ R3:logic = Attempt(Block{ B := Batch{ set X = 7; 0 }; true }, false); Log }
        \\L4:string = G()
        \\Nested:logic = Attempt(Block{ B := Batch{ Q := Attempt(Block{ set X = 8; Require[X < 0]; true }, false); set X = 9; 0 }; true }, false)
        \\L5:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("w0", try text(x, "L1"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "X1"));
    try std.testing.expectEqualStrings("w0w5", try text(x, "L2"));
    try std.testing.expectEqualStrings("w0w5", try text(x, "L3"));
    try std.testing.expectEqualStrings("w0w5w7", try text(x, "L4"));
    try std.testing.expectEqualStrings("w0w5w7w9", try text(x, "L5"));
    try std.testing.expectEqual(@as(u64, 3), x.live.deliveries);
    try live.expectEveryMode(source);
}

test "a task handed off inside a batch runs under it until it first waits, and later on its own" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\W:task(void) = When(X, Set(Log, Log + "w{X}"))
        \\Worker()<transacts><suspends>:void = Block{ set X = 1; set Log = Log + "t"; Sleep(0.0); set X = 2; Set(Log, Log + "u") }
        \\A:string = Batch{ T:task(void) = Spawn{ Worker() }; set Log = Log + "b"; Log }
        \\L1:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // The task's first write is held by the batch; its second, after it was restored on an
    // empty stack, is delivered at once, before its next statement.
    try std.testing.expectEqualStrings("w0tb", try text(x, "A"));
    try std.testing.expectEqualStrings("w0tbw1", try text(x, "L1"));
    // The root's register holds what it last wrote; the cell, in the report, what the task did.
    var buffer: [4096]u8 = undefined;
    const report = try live.report(x, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"Log\":\"w0tbw1w2u\"") != null);
    try live.expectEveryMode(source);
}

test "a reaction made inside a batch starts at once, and what it then writes is held" {
    const source =
        \\var X:i64 = 0
        \\var Log:string = ""
        \\A:string = Batch{ U:task(i64) = Upon(true, Block{ set X = 1; 7 }); W:task(void) = When(X, Set(Log, Log + "w{X}")); set X = 2; Log }
        \\L:string = Log
        \\In()<transacts>:string = Batch{ V:task(void) = When(X > 2, Set(Log, Log + "v")); set X = 3; Log }
        \\B:string = In()
        \\L2:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("w1", try text(x, "A"));
    try std.testing.expectEqualStrings("w1w2", try text(x, "L"));
    try std.testing.expectEqualStrings("w1w2", try text(x, "B"));
    try std.testing.expectEqualStrings("w1w2w3v", try text(x, "L2"));
    try live.expectEveryMode(source);
}

test "a batch in a reaction's body, in a guard and in a copied Defer" {
    const source =
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\var N:i64 = 0
        \\var Log:string = ""
        \\P:task(void) = When(Y > 0, Batch{ set X = Y; Set(Log, Log + "p") })
        \\Q:task(void) = When(Batch{ X }, Set(Log, Log + "q{X}"))
        \\set Y = 5
        \\L1:string = Log
        \\F(K:i64)<transacts>:i64 = Block{ Defer{ B := Batch{ set X = X + 10; 0 } }; If(K > 0, Return(1), 0); 2 }
        \\A:i64 = F(1)
        \\C:i64 = F(0)
        \\L2:string = Log
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqualStrings("q0pq5", try text(x, "L1"));
    try std.testing.expectEqualStrings("q0pq5q15q25", try text(x, "L2"));
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "A") + try integer(x, "C"));
    try live.expectEveryMode(source);
}

test "a batch yields its body's value, and a program with nothing live reports as before" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, "V:i64 = Batch{ 1 + 2 }\nF(N:i64)<computes>:i64 = Batch{ N * 2 }\nG:i64 = F(V)\nvar Y:i64 = 0\nH()<transacts>:i64 = Batch{ set Y = 4; Y }\nI:i64 = H()");
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "V"));
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "G"));
    try std.testing.expectEqual(@as(i64, 4), try integer(x, "I"));
    // No record, observer or delivery: the program is not live (C57), and its report has no
    // `$live` member.
    try std.testing.expectEqualDeep(types.Live{}, x.live);
    var buffer: [4096]u8 = undefined;
    const report = try live.report(x, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, report, "$live") == null);
    try live.expectEveryMode("V:i64 = Batch{ 1 + 2 }\nF(N:i64)<computes>:i64 = Batch{ N * 2 }\nG:i64 = F(V)\nvar Y:i64 = 0\nH()<transacts>:i64 = Batch{ set Y = 4; Y }\nI:i64 = H()");
}

test "a batch's writes in a region that fails are undone, also where its function writes nothing itself" {
    // The function holds no source operation of its own: its regions journal because it calls
    // a body that writes, as an `invoke` makes them.
    const source =
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\W:task(void) = When(X, Set(N, N + 1))
        \\F(K:i64)<transacts>:logic = Attempt(Block{ B := Batch{ set X = K; 0 }; Require[K > 5]; true }, false)
        \\A:logic = F(3)
        \\X1:i64 = X
        \\N1:i64 = N
        \\C:logic = F(7)
        \\X2:i64 = X
        \\N2:i64 = N
    ;
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "X1"));
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "N1"));
    try std.testing.expectEqual(@as(i64, 7), try integer(x, "X2"));
    try std.testing.expectEqual(@as(i64, 2), try integer(x, "N2"));
    try live.expectEveryMode(source);
}

test "the bounds of a delivery at a batch's end fall at its keyword" {
    try reactions.expectFailureOff(
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\A:task(void) = When(X > 0, Set(Y, Y + 1))
        \\B:task(void) = When(Y > 0, Set(X, X + 1))
        \\F()<transacts>:i64 = Batch{ set X = 1; set Y = 1; 0 }
        \\C:i64 = F()
    , .reaction_limit, "Batch");
    try reactions.expectFailureOff(
        \\var X:i64 = 0
        \\var Y:i64 = 0
        \\A:task(void) = When(X > 0, Set(Y, Y + 1))
        \\B:task(void) = When(Y > 0, Set(X, X + 1))
        \\C:i64 = Batch{ set X = 1; 0 }
    , .reaction_limit, "Batch");
    const h = try harness.create();
    defer scratch.release(h);
    try live.expectFailure(h, "var X:i64 = 0\nW:task(void) = When(X > 0, Err(\"boom\"))\nC:i64 = Batch{ set X = 1; set X = 2; 0 }", .runtime_error, "Err");
}

test "the diagnostics of batches, each where it is written" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .source = "F()<transacts><suspends>:void = Block{ B:i64 = Batch{ Sleep(1.0); 1 }; }", .code = .batch_suspends, .at = "Sleep" },
        .{ .source = "G()<transacts><suspends>:void = Sleep(0.0)\nF()<transacts><suspends>:void = Block{ B:i64 = Batch{ G(); 1 }; }", .code = .batch_suspends, .at = "G" },
        .{ .source = "F()<transacts><suspends>:void = Block{ B:i64 = Batch{ Branch{ 1 }; 1 }; }", .code = .batch_suspends, .at = "Branch" },
        .{ .source = "F()<transacts><suspends>:i64 = Batch{ T:task(i64) = Spawn{ 1 }; T.Await() }", .code = .batch_suspends, .at = "Await" },
        .{ .source = "F()<transacts><suspends>:i64 = Batch{ X := For(K:1..2, Block{ Sleep(0.0); K }); 1 }", .code = .batch_suspends, .at = "Sleep" },
        .{ .source = "F()<transacts>:i64 = Batch{ Return(1) }", .code = .return_in_task_body, .at = "Return" },
        .{ .source = "F()<transacts>:i64 = Block{ Loop{ B:i64 = Batch{ Break() }; 1 }; 1 }", .code = .return_in_task_body, .at = "Break" },
        // RFC-0085, I5: a local `var` the body assigns is shared (`shared_local_task_tests.zig`).
        .{ .source = "F()<transacts>:i64 = Block{ L:i64 = 0; B:i64 = Batch{ set L = 1; 1 }; L }", .code = .arm_assigns_local, .at = "L" },
        .{ .source = "var A:[]i64 = array{1}\nB:i64 = Batch{ A[0] }", .code = .failure_context_required, .at = "[" },
        .{ .source = "var X:i64 = 0\nF()<computes>:i64 = Batch{ set X = 1; 1 }", .code = .set_requires_writes, .at = "X" },
        .{ .source = "var X:i64 = 0\nW:task(void) = When(Batch{ set X = 1; X }, 1)", .code = .guard_effect, .at = "X" },
        .{ .source = "F()<transacts>:i64 = Block{ W:task(void) = When(1, Batch{ Sleep(1.0); 1 }); 1 }", .code = .batch_suspends, .at = "Sleep" },
        .{ .source = "B:i64 = Batch(1)", .code = .unknown_name, .at = "Batch" },
        // Review F1: a local declared by the name after the form was used.
        .{ .source = "F()<transacts>:i64 = Block{ X:i64 = Batch{ 1 }; Batch:i64 = 4; X + Batch }", .code = .used_before_declaration, .at = "Batch" },
    };
    for (cases) |case| try live.expectRefused(h, case.source, case.code, case.at);
}

test "Batch yields to what the program declares by its name" {
    const h = try harness.create();
    defer scratch.release(h);
    const function = try live.run(h, "Batch(X:i64)<computes>:i64 = X + 1\nV:i64 = Batch(3)");
    try std.testing.expectEqual(@as(i64, 4), try integer(function, "V"));
    const parameter = try live.run(h, "F(Batch:i64)<computes>:i64 = Batch + 1\nV:i64 = F(2)");
    try std.testing.expectEqual(@as(i64, 3), try integer(parameter, "V"));
    const binding = try live.run(h, "var Batch:i64 = 5\nset Batch = 6\nV:i64 = Batch");
    try std.testing.expectEqual(@as(i64, 6), try integer(binding, "V"));
    const local = try live.run(h, "F()<computes>:i64 = Block{ Batch:i64 = 4; Batch + 1 }\nV:i64 = F()");
    try std.testing.expectEqual(@as(i64, 5), try integer(local, "V"));
    const method = try live.run(h, "c:=class{ Batch(X:i64)<computes>:i64 = X * 2 }\nO:c = c{}\nV:i64 = O.Batch(4)");
    try std.testing.expectEqual(@as(i64, 8), try integer(method, "V"));
    // A class of that name keeps its construction, braces and all.
    const class = try live.run(h, "Batch := class{ X:i64 = 1 }\nO:Batch = Batch{}\nP:Batch = Batch{ X := 3 }\nV:i64 = O.X + P.X");
    try std.testing.expectEqual(@as(i64, 4), try integer(class, "V"));
    const structure = try live.run(h, "Batch := struct{ X:i64 = 1 }\nO:Batch = Batch{ X := 2 }\nV:i64 = O.X");
    try std.testing.expectEqual(@as(i64, 2), try integer(structure, "V"));
}

test "batches: every fuel budget stops both machines at the same node" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\W:task(void) = When(X, Set(N, N + X))
        \\F()<transacts>:i64 = Batch{ set X = 1; R:logic = Attempt(Block{ B := Batch{ set X = 2; 0 }; true }, false); N }
        \\A:i64 = F()
        \\C:i64 = Batch{ set X = 3; F() }
    ;
    const p = try h.compile(source);
    _ = (try h.run(p, live.fuel)).ok;
    var budget: u64 = 1;
    var stopped: u64 = 0;
    while (budget < 800) : (budget += 1) {
        const outcome = try h.run(p, budget);
        if (outcome == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
        stopped += 1;
    }
    try std.testing.expect(stopped > 40 and budget < 800);
    try live.expectEveryMode(source);
}

test "the replay refuses a delivery inside a batch, a batch's delivery left out, and another value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var X:i64 = 0
        \\var Log:string = ""
        \\W:task(void) = When(X, Set(Log, Log + "w"))
        \\F()<transacts>:i64 = Batch{ set X = 1; set X = 2; 5 }
        \\A:i64 = F()
    );
    _ = try reporting.validate(x, false, .{});
    const steps = x.call_steps;
    // The batch node's step, in F, and the delivery right after it.
    var node_step: ?usize = null;
    for (steps, 0..) |step, index| {
        if (step.kind == .deliver) {
            node_step = index - 1;
            break;
        }
    }
    const at = node_step.?;
    try std.testing.expect(steps[at].kind == .value and steps[at].value == .integer and steps[at].value.integer == 5);
    const moved = try std.testing.allocator.dupe(types.CallStep, steps);
    defer std.testing.allocator.free(moved);
    var forged = x;
    forged.call_steps = moved;
    // The delivery before the batch's node has its value: inside the batch.
    std.mem.swap(types.CallStep, &moved[at], &moved[at + 1]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    std.mem.swap(types.CallStep, &moved[at], &moved[at + 1]);
    // The batch yields another value.
    moved[at].value = .{ .integer = 6 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    moved[at].value = steps[at].value;
    // The batch's delivery left out.
    const without = try std.testing.allocator.alloc(types.CallStep, steps.len - 1);
    defer std.testing.allocator.free(without);
    @memcpy(without[0 .. at + 1], steps[0 .. at + 1]);
    @memcpy(without[at + 1 ..], steps[at + 2 ..]);
    var shorter = x;
    shorter.call_steps = without;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(shorter, false, .{}));
    _ = try reporting.validate(forged, false, .{});
}

/// The scale test of batches: `writes` writes of a watched cell inside one batch, by a function
/// iterated in its body, notify the `When` once and deliver once; `depth` batches nested by
/// recursion deliver once, when the outermost ends.
pub fn batchScale(f: trace_replay.Fixture, writes: usize, depth: usize) !void {
    const buffer = try std.testing.allocator.alloc(u8, 1024 + 32 * depth);
    defer std.testing.allocator.free(buffer);
    // `depth` batches, each in the body of the one before.
    var nesting: std.Io.Writer = .fixed(buffer[512..]);
    for (0..depth) |level| try nesting.print("Batch{{ set X = {d}; ", .{level + 1});
    try nesting.writeAll("N");
    for (0..depth) |_| try nesting.writeAll(" }");
    const nested = nesting.buffered();
    const source = try std.fmt.bufPrint(buffer[0..512],
        \\var X:i64 = 0
        \\var N:i64 = 0
        \\W:task(void) = When(X, Set(N, N + 1))
        \\Bump(K:i64)<transacts>:i64 = Block{{ T:[]i64 = array{{K, K, K, K}}; set X = K + T.Length; K + 1 }}
        \\A:i64 = Batch{{ Iterate(Bump, {d}, 0) }}
        \\B:i64 = N
        \\Deep()<transacts>:i64 =
    , .{writes});
    // The nested batches follow, then the rest of the program.
    std.mem.copyForwards(u8, buffer[source.len..], nested);
    const tail = "\nC:i64 = Deep()\nD:i64 = N";
    @memcpy(buffer[source.len + nested.len ..][0..tail.len], tail);
    const program = buffer[0 .. source.len + nested.len + tail.len];
    const x = try @import("live_field_tests.zig").timed(f, "writes of a watched cell in one batch, and nested batches", program);
    try std.testing.expectEqual(@as(i64, @intCast(writes)), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("D").?.integer);
    try std.testing.expectEqual(@as(u64, 2), x.live.deliveries);
    try std.testing.expect(x.reclaims > 0);
}

test "the scale test of batches at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try batchScale(f, 2000, 24);
}
