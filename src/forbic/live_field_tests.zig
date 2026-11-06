//! Live fields, P4.2 (RFC-0084): `set live E.F = G`, `var live` and `live` fields in class
//! bodies attached by the class's block clauses, live-only fields, the construction's effects,
//! rollback and reclamation, in both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const trace_replay = @import("trace_replay.zig");
const reporting = @import("value_report.zig");
test {
    _ = @import("live_field_forgery_tests.zig");
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try live.report(execution, &buffer));
}
fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}

/// The fixture `tests/conformance/live-fields.forb`.
const contract =
    \\var Bonus:i64 = 5
    \\meter := class{
    \\    var Raw:i64 = 1
    \\    var live Total:i64 = Self.Doubled + Bonus
    \\    var live Doubled:i64 = Self.Raw * 2
    \\    live Label:string = "raw {Self.Raw}"
    \\}
    \\M:meter = meter{ Raw := 3 }
    \\First:tuple(i64, i64, string) = tuple{M.Total, M.Doubled, M.Label}
    \\big_meter := class(meter){ live Scaled:i64 = Self.Total * 10 }
    \\B:big_meter = big_meter{}
    \\Bump(Amount:i64)<transacts>:i64 = Block{ set M.Raw = M.Raw + Amount; M.Total }
    \\Bumped:i64 = Bump(2)
    \\set Bonus = 100
    \\Scaled:i64 = B.Scaled
    \\score_board := class{
    \\    var Raw:i64 = 0
    \\    var<private> live Shown<public>:i64 = Self.Raw + 1
    \\    Follow(Other:score_board)<transacts>:i64 = Block{ set live Self.Shown = Other.Raw * 2; Self.Shown }
    \\}
    \\Left:score_board = score_board{}
    \\Right:score_board = score_board{ Raw := 4 }
    \\Followed:i64 = Left.Follow(Right)
    \\Raise()<transacts>:i64 = Block{ set Right.Raw = 7; Left.Shown }
    \\Raised:i64 = Raise()
    \\gauge := class{ var Level:i64 = 0 }
    \\G:gauge = gauge{}
    \\set live G.Level = Bonus + 1
    \\set Bonus = 10
    \\Seen:i64 = G.Level
    \\set G.Level = 0
    \\set Bonus = 20
    \\Tried:logic = Attempt(Block{ T:meter = meter{ Raw := 50 }; set M.Raw = 0; Require[T.Total < 0]; true }, false)
;

test "live fields: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    // M: Total and Label read Self, so they start at 0 and ""; Doubled's guard does too. Total is
    // attached first (0 + 5), then Doubled (6), whose write gives Total 11; Label "raw 3". B's
    // superclass fields are attached first (Total 5, Doubled 2, Total 7), then Scaled (70).
    // Bump: Raw 5, Doubled 10, Total 15. Bonus 100: M.Total 110, B.Total 102, B.Scaled 1020.
    // Left.Follow(Right) replaces Left.Shown's guard by Right.Raw * 2 = 8; Right.Raw = 7 gives
    // 14 and Right.Shown 8. G.Level follows Bonus + 1 (11) until the plain set. The failed region
    // forgets T and its three records, and puts M.Raw back. 14 records, three of them forgotten.
    try expectReport(x, "{\"Bonus\":20,\"M\":{\"$object\":0},\"First\":[11,6,\"raw 3\"],\"B\":{\"$object\":5},\"Bumped\":15,\"Scaled\":1020,\"Left\":{\"$object\":11},\"Right\":{\"$object\":14},\"Followed\":8,\"Raised\":14,\"G\":{\"$object\":17},\"Seen\":11,\"Tried\":false,\"$objects\":[{\"id\":0,\"class\":\"meter\",\"fields\":{\"Raw\":5,\"Total\":30,\"Doubled\":10,\"Label\":\"raw 5\"}},{\"id\":5,\"class\":\"big_meter\",\"fields\":{\"Raw\":1,\"Total\":22,\"Doubled\":2,\"Label\":\"raw 1\",\"Scaled\":220}},{\"id\":11,\"class\":\"score_board\",\"fields\":{\"Raw\":0,\"Shown\":14}},{\"id\":14,\"class\":\"score_board\",\"fields\":{\"Raw\":7,\"Shown\":8}},{\"id\":17,\"class\":\"gauge\",\"fields\":{\"Level\":0}}],\"$live\":{\"records\":14,\"propagations\":21,\"evaluations\":35,\"entries\":49,\"deliveries\":0,\"firings\":0}}\n");
    try live.expectEveryMode(contract);
}

test "live fields: set live E.F evaluates E once, at the root and in a function, and a plain set ends it" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try live.run(h,
        \\var Calls:i64 = 0
        \\box := class{ var V:i64 = 0; Fixed:i64 = 1 }
        \\B:box = box{}
        \\Pick()<transacts>:box = Block{ set Calls += 1; B }
        \\var S:i64 = 2
        \\set live Pick().V = S * 3
        \\set S = 4
        \\A:i64 = B.V
    );
    try std.testing.expectEqual(@as(i64, 1), try integer(x, "Calls"));
    try std.testing.expectEqual(@as(i64, 12), try integer(x, "A"));
    x = try live.run(h,
        \\box := class{ var V:i64 = 0 }
        \\var S:i64 = 1
        \\Make()<transacts>:box = Block{ O:box = box{}; set live O.V = S + 1; O }
        \\O:box = Make()
        \\set S = 5
        \\A:i64 = O.V
        \\Stop()<transacts>:i64 = Block{ set O.V = 0; set S = 9; O.V }
        \\B:i64 = Stop()
    );
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    // The value of `set live E.F = G` is the value it established.
    x = try live.run(h,
        \\box := class{ var V:i64 = 0 }
        \\O:box = box{}
        \\var S:i64 = 3
        \\F()<transacts>:i64 = Block{ set live O.V = S * S }
        \\A:i64 = F()
    );
    try std.testing.expectEqual(@as(i64, 9), try integer(x, "A"));
}

test "live fields: fields that read each other settle in either declaration order" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        \\chain := class{
        \\    var A:i64 = 1
        \\    var live B:i64 = Self.A + 1
        \\    var live C:i64 = Self.B * 10
        \\}
        \\X:chain = chain{}
        \\F()<transacts>:i64 = Block{ set X.A = 5; X.C }
        \\Y:i64 = F()
        ,
        \\chain := class{
        \\    var live C:i64 = Self.B * 10
        \\    var live B:i64 = Self.A + 1
        \\    var A:i64 = 1
        \\}
        \\X:chain = chain{}
        \\F()<transacts>:i64 = Block{ set X.A = 5; X.C }
        \\Y:i64 = F()
    }, [_]u64{ 4, 5 }) |source, evaluations| {
        const x = try live.run(h, source);
        try std.testing.expectEqual(@as(i64, 60), try integer(x, "Y"));
        // In order: B 2, C 20, then B 6, C 60. Against it, C is attached first (0), then B (2),
        // whose write evaluates C again (20): one evaluation more.
        try std.testing.expectEqual(evaluations, x.live.evaluations);
        try live.expectEveryMode(source);
    }
}

test "live fields: a subclass attaches its fields after its superclass's, and a superclass's guards run on it" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var Base:i64 = 2
        \\top := class{ var live P:i64 = Base * 10 }
        \\middle := class(top){ var live Q:i64 = Self.P + 1 }
        \\bottom := class(middle){ live R:i64 = Self.Q + Self.P; Block{ set Base = Base + 0 } }
        \\X:bottom = bottom{}
        \\A:tuple(i64, i64, i64) = tuple{X.P, X.Q, X.R}
        \\set Base = 3
        \\B:tuple(i64, i64, i64) = tuple{X.P, X.Q, X.R}
    ;
    const x = try live.run(h, source);
    var buffer: [4096]u8 = undefined;
    const text = try live.report(x, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"A\":[20,21,41]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"B\":[30,31,61]") != null);
    try live.expectEveryMode(source);
}

test "live fields: a live-only field reads like a var, follows its guard and is never assigned" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var Source:i64 = 1
        \\tag := class{ live Name:string = "n{Source}"; live Twice:i64 = Source * 2 }
        \\T:tag = tag{}
        \\Read()<reads>:string = T.Name
        \\set Source = 4
        \\A:string = Read()
        \\B:i64 = T.Twice
    );
    try std.testing.expectEqualStrings("n4", x.get("A").?.string);
    try std.testing.expectEqual(@as(i64, 8), try integer(x, "B"));
    // A guard that reads a live-only field depends on it.
    const y = try live.run(h,
        \\var Source:i64 = 1
        \\tag := class{ live Twice:i64 = Source * 2 }
        \\T:tag = tag{}
        \\var live Watch:i64 = T.Twice + 1
        \\set Source = 10
    );
    try std.testing.expectEqual(@as(i64, 21), try integer(y, "Watch"));
}

test "live fields: the diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const tag = "var S:i64 = 0\ntag := class{ live Twice:i64 = S * 2; var Plain:i64 = 0; Fixed:i64 = 0 }\nT:tag = tag{}\n";
    // A live-only field is never assigned, made live again, given by an archetype or restated.
    try live.expectRefused(h, tag ++ "set T.Twice = 1", .live_assigned, "Twice");
    try live.expectRefused(h, tag ++ "set live T.Twice = S", .live_assigned, "Twice");
    try live.expectRefused(h, tag ++ "U:tag = tag{ Twice := 3 }", .live_assigned, "Twice");
    try live.expectRefused(h, "var S:i64 = 0\ngauge := class{ var live V:i64 = S }\nU:gauge = gauge{ V := 3 }", .live_assigned, "V");
    try live.expectRefused(h, "var S:i64 = 0\ngauge := class{ var live V:i64 = S }\nsub := class(gauge){ var V<override>:i64 = 2 }", .live_assigned, "V");
    try live.expectRefused(h, "var S:i64 = 0\ngauge := class{ var V:i64 = 0 }\nsub := class(gauge){ var live V<override>:i64 = S }", .live_target, "V");
    // An immutable field, a struct's field and an interface's are no live targets.
    try live.expectRefused(h, tag ++ "set live T.Fixed = S", .live_target, "Fixed");
    try live.expectRefused(h, "pair := struct{ X:i64 = 0 }\nP:pair = pair{}\nset live P.X = 1", .live_target, "X");
    try live.expectRefused(h, "shape := interface{ var live V:i64 = 0 }", .live_target, "V");
    try live.expectRefused(h, "shape := interface{ var V:i64 = 0 }\nsquare := class(shape){}\nQ:shape = square{}\nset live Q.V = 1", .live_target, "V");
    // `set live E.F` writes the field, so it needs its write access, and all three heap effects.
    try live.expectRefused(h, "board := class{ var<private> Shown<public>:i64 = 0 }\nB:board = board{}\nset live B.Shown = 1", .inaccessible_member, "Shown");
    try live.expectRefused(h, "box := class{ var V:i64 = 0 }\nB:box = box{}\nF()<reads><writes>:i64 = Block{ set live B.V = 1 }", .call_requires_allocates, "V");
    // A guard that reads Self of a type without a default value.
    try live.expectRefused(h, "box := class{}\nShared:box = box{}\nholder := class{ var Pick:logic = false; var live Kept:box = If(Self.Pick, Shared, Shared) }", .live_field_default, "Kept");
    try live.expectRefused(h, "holder := class{ var N:i64 = 0; var live Pick:function<reads>(tuple(), i64) = If(Self.N > 0, Fn()<reads>:i64{ 1 }, Fn()<reads>:i64{ 2 }) }", .live_field_default, "Pick");
    // A guard only reads, also as a field's default.
    try live.expectRefused(h, "var S:i64 = 0\nbox := class{ var live V:i64 = Set(S, 1) }", .guard_effect, "S");
    try live.expectRefused(h, "var S:i64 = 0\nbox := class{ var N:i64 = 0; var live V:i64 = Block{ set S = Self.N; 1 } }", .guard_effect, "S");
    // Building an instance of a class with live fields runs and writes its guards.
    const meter = "var S:i64 = 0\nmeter := class{ var live V:i64 = S }\n";
    try live.expectRefused(h, meter ++ "F()<allocates>:meter = meter{}", .construction_requires_reads, "meter");
    try live.expectRefused(h, meter ++ "F()<reads><allocates>:meter = meter{}", .construction_requires_writes, "meter");
    try live.expectRefused(h, meter ++ "F()<reads><writes>:meter = meter{}", .construction_requires_allocates, "meter");
    // A class that states fewer effects than attaching needs.
    try live.expectRefused(h, "var S:i64 = 0\nmeter := class<allocates>{ var live V:i64 = S }", .call_requires_reads_writes, "V");
}

test "live fields: a construction in a region that fails forgets its records; set live on a field is undone" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var S:i64 = 1
        \\meter := class{ var live V:i64 = S * 2 }
        \\box := class{ var W:i64 = 0 }
        \\O:box = box{}
        \\Try()<transacts>:logic = Attempt(Block{ M:meter = meter{}; set live O.W = S + 100; set S = 7; Require[M.V < 0]; true }, false)
        \\A:logic = Try()
        \\set S = 3
        \\B:i64 = O.W
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 0), try integer(x, "B"));
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "S"));
    try live.expectEveryMode(source);
}

test "live fields: a field's record goes with an instance nothing reaches; one that reads a kept cell stays (C24)" {
    // Each visit builds an instance whose live field reads only its own fields: once the visit
    // ends, nothing can write what the guard reads, and a digest run reclaims the record with
    // the instance. Each also builds one whose guard reads a module var, which a later write
    // evaluates in every mode: the record stays. Every mode charges and records the same.
    const source =
        \\var S:i64 = 1
        \\own := class{ var A:i64 = 1; var live B:i64 = Self.A * 2 }
        \\shared := class{ var live C:i64 = S + 1 }
        \\Visit(N:i64)<transacts>:i64 = Block{ O:own = own{ A := N }; P:shared = shared{}; O.B + P.C }
        \\Total:i64 = For(I:1..20, Visit(I)).Length
        \\set S = 5
    ;
    const reclaims = try live.everyMode(source);
    try std.testing.expect(reclaims > 0);
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, source);
    // 40 records; the final write evaluates the 20 that read S.
    try std.testing.expectEqual(@as(u64, 40), x.live.records);
    try std.testing.expectEqual(@as(u64, 40 + 20), x.live.evaluations);
    // A full run keeps every instance and record; a digest run keeps those of `shared` only
    // (2 + 7 cells each), and of `own` at most the last visit's.
    const full_cells = x.object_cells.len;
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.digest, 64);
    f.h.control.reclaim_floor = 16;
    f.h.runtime.machine.control.reclaim_floor = 16;
    defer {
        f.h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        f.h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    }
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, live.fuel);
    const actual = f.h.runtime.evaluate(p, live.fuel);
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqual(reference.ok.object_cells.len, actual.ok.object_cells.len);
    try std.testing.expectEqual(@as(usize, 20 * (2 + 3 + 7 + 7)), full_cells);
    try std.testing.expect(actual.ok.object_cells.len <= 20 * (2 + 7) + 3 + 7);
    try std.testing.expect(actual.ok.object_cells.len >= 20 * (2 + 7));
}

test "live fields: every fuel budget stops both machines at the same node" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var S:i64 = 1
        \\chain := class{ var live C:i64 = Self.B * 10; var live B:i64 = Self.A + S; var A:i64 = 1 }
        \\X:chain = chain{}
        \\F()<transacts>:i64 = Block{ set X.A = 5; set live X.A = S * 3; X.C }
        \\Y:i64 = F()
        \\set S = 2
    ;
    const p = try h.compile(source);
    const total = (try h.run(p, live.fuel)).ok;
    _ = total;
    var budget: u64 = 1;
    var stopped: u64 = 0;
    while (budget < 400) : (budget += 1) {
        const outcome = try h.run(p, budget);
        if (outcome == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
        stopped += 1;
    }
    try std.testing.expect(stopped > 20 and budget < 400);
}

test "live fields: a constructor and an instantiation of a parametric class attach them too" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var S:i64 = 1
        \\meter := class{ var A:i64 = 0; var live B:i64 = Self.A + S }
        \\MakeMeter<constructor>(N:i64)<transacts>:meter = meter{ A := N }
        \\M:meter = MakeMeter(5)
        \\set S = 10
        \\X:i64 = M.B
        \\box[T:type] := class{ var V:T; var live W:T = Self.V }
        \\Bi:box[i64] = box[i64]{ V := 3 }
        \\F()<transacts>:i64 = Block{ set Bi.V = 8; Bi.W }
        \\Y:i64 = F()
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 15), try integer(x, "X"));
    try std.testing.expectEqual(@as(i64, 8), try integer(x, "Y"));
    try live.expectEveryMode(source);
}

test "live fields: the replay refuses forged steps and cells of field records" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var A:i64 = 1
        \\pair := class{ var live B:i64 = A + 1; var live C:i64 = A * 0; var live D:i64 = Self.B + Self.C }
        \\P:pair = pair{}
        \\set A = 5
    );
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    const cells = try std.testing.allocator.dupe(@TypeOf(x.object_cells[0]), x.object_cells);
    defer std.testing.allocator.free(cells);
    var evals: [16]usize = undefined;
    var eval_count: usize = 0;
    var settles: [16]usize = undefined;
    var settle_count: usize = 0;
    for (steps, 0..) |step, index| {
        if (step.kind == .live_eval) {
            evals[eval_count] = index;
            eval_count += 1;
        }
        if (step.kind == .live_settle) {
            settles[settle_count] = index;
            settle_count += 1;
        }
    }
    // Attaching B, C and D (D twice more as B and C are attached), then B, C and D again.
    try std.testing.expectEqual(eval_count, settle_count);
    var forged = x;
    forged.call_steps = steps;
    forged.object_cells = cells;
    _ = try reporting.validate(forged, false, .{});
    // The last propagation's first two evaluations swapped, and a stable result claimed written.
    const last = eval_count - 3;
    std.mem.swap(types.CallStep, &steps[evals[last]], &steps[evals[last + 1]]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    std.mem.swap(types.CallStep, &steps[evals[last]], &steps[evals[last + 1]]);
    steps[settles[last + 1]].value = .{ .boolean = !steps[settles[last + 1]].value.boolean };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    steps[settles[last + 1]].value = .{ .boolean = !steps[settles[last + 1]].value.boolean };
    // A field's final value, and a record's owner or place, that are not what the run made.
    const fields = 1 + 3;
    const field_b = 1;
    const kept = cells[field_b];
    cells[field_b].value = .{ .integer = 99 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    cells[field_b] = kept;
    const record = fields;
    const place = record + 5;
    const kept_place = cells[place];
    cells[place].value = .{ .integer = 7 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    cells[place] = kept_place;
    _ = try reporting.validate(forged, false, .{});
}

/// Runs `source` in a digest run on both machines and the replay, and prints the time of each.
pub fn timed(f: trace_replay.Fixture, label: []const u8, source: []const u8) !evaluator.Execution {
    const p = try f.h.compile(source);
    const budget: u64 = 1 << 40;
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const referenced = elapsed(start);
    const actual = f.h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (reference != .ok or actual != .ok) return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(reference.ok.live, actual.ok.live);
    const stats = try reporting.validateReplayed(actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("{s}: {d} evaluations, {d} entries: reference={d}ms vm={d}ms replay={d}ms, the live replay held {d} KiB at most\n", .{ label, actual.ok.live.evaluations, actual.ok.live.entries, referenced, ran - referenced, elapsed(start) - ran, stats.live_bytes / 1024 });
    return actual.ok;
}
fn elapsed(start: std.Io.Timestamp) u64 {
    const nanoseconds = start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds();
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
}

/// Scale test 1 (RFC-0084): a chain of `count` instances, each with a `var` field whose guard
/// reads the field of the instance before it, built in order, and one write at its head: each
/// record is evaluated once. An instance and its record take nine cells, so the program
/// profile's `object_cells` hold a chain of 460,000 (C27).
pub fn chainScale(f: trace_replay.Fixture, count: usize) !void {
    var text: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&text,
        \\node := class{{ var V:i64 = 0 }}
        \\Head:node = node{{}}
        \\Make(Prev:node)<transacts>:node = Block{{ N:node = node{{}}; set live N.V = Prev.V + 1; N }}
        \\Tail:node = Iterate(Make, {d}, Head)
        \\Start()<transacts>:i64 = Block{{ set Head.V = 1000; Tail.V }}
        \\A:i64 = Start()
    , .{count});
    const x = try timed(f, "a chain of live fields", source);
    try std.testing.expectEqual(@as(i64, 1000 + @as(i64, @intCast(count))), x.get("A").?.integer);
    try std.testing.expectEqual(@as(u64, count), x.live.records);
    // One establishing evaluation per record, then the write at the head evaluates each once.
    try std.testing.expectEqual(@as(u64, 2 * count), x.live.evaluations);
}

test "live fields: a chain of instances at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try chainScale(f, 100);
}

test "live fields: guards with functions and loops compile once; the clauses take no program's name" {
    const h = try harness.create();
    defer scratch.release(h);
    // Review 1: a guard holding a `Fn` or a `For` is compiled once, as the guard.
    var x = try live.run(h,
        \\var S:i64 = 1
        \\holder := class{ var live V:i64 = For(K:1..3, K + S).Length; var live W:i64 = (Fn()<reads>:i64{ S * 10 })() }
        \\H:holder = holder{}
        \\set S = 2
        \\A:i64 = H.V + H.W
    );
    try std.testing.expectEqual(@as(i64, 3 + 20), try integer(x, "A"));
    // A type without a default is refused whatever the guard reads (C26).
    try live.expectRefused(h, "var S:i64 = 1\nholder := class{ var live F:function<reads>(tuple(), i64) = Fn()<reads>:i64{ S } }", .live_field_default, "F");
    // Review 2: a field, a module var or a function of the field's name stays the program's.
    x = try live.run(h,
        \\var S:i64 = 1
        \\var Total:i64 = 3
        \\meter := class{ var live Total:i64 = S }
        \\M:meter = meter{}
        \\Count(N:meter)<reads>:i64 = N.Total
        \\A:i64 = Count(M) + Total
    );
    try std.testing.expectEqual(@as(i64, 4), try integer(x, "A"));
    x = try live.run(h,
        \\var S:i64 = 1
        \\meter := class{ var live Total:i64 = S }
        \\Total(M:meter)<reads>:i64 = M.Total + 1
        \\M:meter = meter{}
        \\set S = 5
        \\X:i64 = Total(M)
    );
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "X"));
}

fn bundled(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const ir = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = source }} })) {
        .ok => |ir| ir,
        .failed => return error.TestUnexpectedResult,
    };
    const outcome = try h.run(ir, live.fuel);
    if (outcome != .ok) return error.TestUnexpectedResult;
    return outcome.ok;
}

test "live fields: set live through modules names a module's cell or a field, as its path says" {
    const h = try harness.create();
    defer scratch.release(h);
    // Review 3: a path of modules names a cell, however deep.
    var x = try bundled(h, "Outer<public>:=module{\n  Inner<public>:=module{\n    var X<public>:i64=0\n  }\n}\nvar S:i64=1\nset live Outer.Inner.X=S+1\nset S=4\nY:i64=Outer.Inner.X\n");
    try std.testing.expectEqual(@as(i64, 5), try integer(x, "Y"));
    x = try bundled(h, "Kit<public>:=module{\n  var X<public>:i64=0\n}\nvar S:i64=1\nset live Kit.X=S+1\nset S=4\nY:i64=Kit.X\n");
    try std.testing.expectEqual(@as(i64, 5), try integer(x, "Y"));
    // A path through a module's instance names its field.
    x = try bundled(h, "Kit<public>:=module{\n  box<public>:=class{ var V<public>:i64 = 0 }\n  B<public>:box=box{}\n}\nvar S:i64=1\nset live Kit.B.V=S+1\nset S=4\nY:i64=Kit.B.V\n");
    try std.testing.expectEqual(@as(i64, 5), try integer(x, "Y"));
}
