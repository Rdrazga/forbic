//! `Profile(Tag, Body)` (RFC-0094, B6): the Book's `profile("Tag"): body`. It lowers to existing
//! IR (a clock read, the body, a clock read, a `Print`), so these tests check what that gives:
//! the value, the line, the recorded clock, rollback, early exit, suspension, cancellation and
//! the names it yields to. Every program runs on both machines through the harness, the second
//! machine given the first one's record of the world, as in `input_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const start: f64 = 1_700_000_000.0;

const Bench = struct {
    h: *harness.Harness,
    script: *effects.Script,

    fn create() !Bench {
        const h = try harness.create();
        errdefer scratch.release(h);
        const script = try std.testing.allocator.create(effects.Script);
        script.* = .{};
        h.control.effects.inputs.source = script.source();
        return .{ .h = h, .script = script };
    }
    fn destroy(self: Bench) void {
        std.testing.allocator.destroy(self.script);
        scratch.release(self.h);
    }
    fn outcome(self: Bench, source: []const u8, budget: u64) !evaluator.Result {
        self.script.rewind();
        const p = try self.h.compile(source);
        return self.h.run(p, budget);
    }
    fn run(self: Bench, source: []const u8) !evaluator.Execution {
        const result = try self.outcome(source, fuel);
        if (result == .failed) {
            std.debug.print("run failed: {t} at {d}: {s}\n", .{ result.failed.code, result.failed.span.start, source });
            return error.RunFailed;
        }
        return result.ok;
    }
    fn refused(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
        const result = self.h.front.compile(source);
        if (result != .failed) {
            std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        }
        if (result.failed.code != code) std.debug.print("got {t} for {s}\n", .{ result.failed.code, source });
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
    }
};

/// The lines a `full` run committed.
fn printed(x: evaluator.Execution, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (0..x.effects.entries.len) |index| writer.print("{s}\n", .{x.effects.text(index)}) catch unreachable;
    return writer.buffered();
}

fn reportOf(x: evaluator.Execution, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try reporting.write(&out, x, false, .{});
    return out.buffered();
}

test "the value of the body is the value of the form, the line is Print's, and the clock is read once at one tick" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [1024]u8 = undefined;
    const x = try b.run(
        \\Quick:i64 = Profile("quick", 6 * 7)
        \\Half:float = Profile("half", 3.5)
        \\Words:[]i64 = Profile("array", array{})
        \\Shown:tuple() = Profile("unit", Print("hi"))
        \\Nest:i64 = Profile("outer", Profile("inner", 1) + 1)
        \\Joined:i64 = Profile("a" + "b", 5)
    );
    try std.testing.expectEqual(@as(i64, 42), x.get("Quick").?.integer);
    try std.testing.expectEqual(@as(f64, 3.5), x.get("Half").?.floating);
    try std.testing.expectEqual(@as(i64, 2), x.get("Nest").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("Joined").?.integer);
    try std.testing.expectEqualStrings(
        \\profile quick: 0 s
        \\profile half: 0 s
        \\profile array: 0 s
        \\hi
        \\profile unit: 0 s
        \\profile inner: 0 s
        \\profile outer: 0 s
        \\profile ab: 0 s
        \\
    , printed(x, &buffer));
    // Every read is at the root's tick: one entry, asked of the world once.
    try std.testing.expectEqual(@as(usize, 1), x.effects.inputs.len);
    try std.testing.expectEqual(@as(u64, 1), b.script.reads);
    // A program with no `Profile` reads nothing.
    try std.testing.expectEqual(@as(usize, 0), (try b.run("A:i64 = 1")).effects.inputs.len);
}

test "the tag is evaluated first, the body once, and the clock is read between them" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [256]u8 = undefined;
    const x = try b.run(
        \\var Runs:i64 = 0
        \\Tag()<transacts>:string = Block{ Print("tag"); "t" }
        \\Body()<transacts>:i64 = Block{ Print("body"); set Runs = Runs + 1; 1 }
        \\A:i64 = Profile(Tag(), Body())
        \\B:i64 = Block{ Runs }
    );
    try std.testing.expectEqualStrings("tag\nbody\nprofile t: 0 s\n", printed(x, &buffer));
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
}

test "a body that suspends is measured in the recorded clock, and the readings are the world's" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [256]u8 = undefined;
    const program =
        \\Wait(S:float)<transacts><suspends>:float = Block{ Sleep(S); S }
        \\T:task(float) = Spawn{ Profile("slow", Wait(2.5)) }
    ;
    // Without a script the clock reads `S + now / R`: the body took 150 ticks of 60 a second.
    const paced = try b.run(program);
    try std.testing.expectEqualStrings("profile slow: 2.5 s\n", printed(paced, &buffer));
    // The tick rate is a parameter of the run; the world's pace follows it (the script's rate).
    b.script.clocks = &.{ 100.0, 103.5 };
    defer b.script.clocks = &.{};
    const scripted = try b.run(program);
    try std.testing.expectEqualStrings("profile slow: 3.5 s\n", printed(scripted, &buffer));
    try std.testing.expectEqual(@as(usize, 2), scripted.effects.inputs.len);
    // A clock that went back holds its last value (RFC-0086, I5): the body took no time.
    b.script.clocks = &.{ 100.0, 90.0 };
    try std.testing.expectEqualStrings("profile slow: 0 s\n", printed(try b.run(program), &buffer));
    // Two tasks at one tick share their readings; the later tick asks again.
    b.script.clocks = &.{ 10.0, 11.0, 14.0 };
    const two = try b.run(
        \\Wait(S:float)<transacts><suspends>:float = Block{ Sleep(S); S }
        \\A:task(float) = Spawn{ Profile("a", Wait(1.0)) }
        \\B:task(float) = Spawn{ Profile("b", Wait(1.0)) }
        \\C:task(float) = Spawn{ Profile("c", Wait(2.0)) }
    );
    try std.testing.expectEqualStrings("profile a: 1 s\nprofile b: 1 s\nprofile c: 4 s\n", printed(two, &buffer));
    try std.testing.expectEqual(@as(usize, 3), two.effects.inputs.len);
}

test "a body that fails, or a region that fails after the form, shows no line, and the reading stays" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [256]u8 = undefined;
    const x = try b.run(
        \\Fails()<transacts><decides>:i64 = Block{ Require[false]; 1 }
        \\Gone:i64 = Attempt(Profile("gone", Fails[]), 0)
        \\Rolled:i64 = Attempt(Block{ Profile("rolled", 5); Require[false]; 1 }, -1)
        \\Kept:i64 = Attempt(Block{ Profile("kept", 7) }, -1)
    );
    try std.testing.expectEqual(@as(i64, 0), x.get("Gone").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Rolled").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Kept").?.integer);
    try std.testing.expectEqualStrings("profile kept: 0 s\n", printed(x, &buffer));
    // The first reading was made in a region that failed, and inputs are never rolled back.
    const only = try b.run("Fails()<transacts><decides>:i64 = Block{ Require[false]; 1 }\nGone:i64 = Attempt(Profile(\"gone\", Fails[]), 0)");
    try std.testing.expectEqualStrings("", printed(only, &buffer));
    try std.testing.expectEqual(@as(usize, 1), only.effects.inputs.len);
    try std.testing.expectEqual(@as(u64, @bitCast(start)), only.effects.inputs[0].bits);
}

test "a body that leaves with Return or Break logs nothing, and one that finishes logs" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [512]u8 = undefined;
    const x = try b.run(
        \\Early(N:i64)<transacts>:i64 = Block{ Profile("early", Block{ If(N < 0, Return(-1), false); N * 2 }) }
        \\Turns()<transacts>:i64 = Block{ var N:i64 = 0; Loop{ Profile("turn", Block{ set N = N + 1; If(N > 2, Break(), false) }) }; N }
        \\Outer()<transacts>:i64 = Block{ Profile("outer", Block{ Profile("inner", Block{ Return(9) }); 1 }) }
        \\A:i64 = Early(-1)
        \\B:i64 = Early(3)
        \\C:i64 = Turns()
        \\D:i64 = Outer()
    );
    try std.testing.expectEqual(@as(i64, -1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("D").?.integer);
    // `B` finished; `Turns` finished its first two turns and left in the third; `Outer` left
    // from its inner body, so neither of its forms reached its line.
    try std.testing.expectEqualStrings("profile early: 0 s\nprofile turn: 0 s\nprofile turn: 0 s\n", printed(x, &buffer));
    // A body that is itself a Return is not in a tail position of anything (RFC-0068).
    try b.refused("F()<transacts>:i64 = Profile(\"x\", Return(1))", .return_not_tail, "Return");
}

test "a body that is cancelled while it waits shows no line" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [256]u8 = undefined;
    const x = try b.run(
        \\Held()<transacts><suspends>:float = Profile("held", Block{ Sleep(Inf); 1.0 })
        \\T:task(float) = Spawn{ Held() }
        \\Stop()<transacts><suspends>:void = Block{ Sleep(1.0); T.Cancel() }
        \\S:task(void) = Spawn{ Stop() }
    );
    try std.testing.expectEqualStrings("", printed(x, &buffer));
    // The tag's read at tick 0 is the only one: the second never happened.
    try std.testing.expectEqual(@as(usize, 1), x.effects.inputs.len);
}

test "the diagnostics: arguments, types, effects and positions" {
    const b = try Bench.create();
    defer b.destroy();
    try b.refused("A:i64 = Profile(\"x\")", .argument_count, "Profile");
    try b.refused("A:i64 = Profile()", .expected_expression, ")");
    try b.refused("A:i64 = Profile(\"x\", 1, 2)", .argument_count, ",");
    try b.refused("A:i64 = Profile(5, 1)", .type_mismatch, "5");
    try b.refused("A:i64 = Profile(\"x\", 1.5)", .type_mismatch, "1.5");
    try b.refused("A:i64 = Profile[\"x\", 1]", .unknown_name, "Profile");
    try b.refused("A:i64 = Profile", .unknown_name, "Profile");
    try b.refused("A:i64 = Profile(\"x\", Missing)", .unknown_name, "Missing");
    // It reads the clock and prints: all three heap effects, as `Print` and the clock need.
    try b.refused("F()<computes>:i64 = Profile(\"x\", 1)", .call_requires_transacts, "Profile");
    try b.refused("F()<reads>:i64 = Profile(\"x\", 1)", .call_requires_writes_allocates, "Profile");
    try b.refused("F()<reads><writes>:i64 = Profile(\"x\", 1)", .call_requires_allocates, "Profile");
    // The clock is the world's answer to whoever runs the code: it dictates (RFC-0086, D15).
    try b.refused("F()<transacts><predicts>:i64 = Profile(\"x\", 1)", .call_requires_dictates, "Profile");
    // A guard reads cells and nothing else.
    try b.refused("var X:i64 = 0\nW:task(void) = When(Profile(\"g\", X) > 0, Print(\"late\"))", .guard_effect, "Profile");
    // A body that suspends needs a function that does.
    try b.refused("F()<transacts>:float = Profile(\"x\", Block{ Sleep(1.0); 1.0 })", .call_requires_suspends, "Sleep");
    // A body that fails needs a failure context, as any call does.
    try b.refused("Fails()<transacts><decides>:i64 = Block{ Require[false]; 1 }\nF()<transacts>:i64 = Profile(\"x\", Fails[])", .failure_context_required, "Fails");
}

test "the name yields to every declaration of it" {
    const b = try Bench.create();
    defer b.destroy();
    var buffer: [256]u8 = undefined;
    const programs = [_][]const u8{
        "Profile(T:string, V:i64)<computes>:i64 = V + 1\nA:i64 = Profile(\"x\", 1)",
        "A:i64 = Block{ Profile := Fn(T:string, V:i64)<computes>:i64{V + 1}; Profile(\"x\", 1) }",
        "F(Profile:function(tuple(string, i64), i64))<computes>:i64 = Profile(\"x\", 1)\nG(T:string, V:i64)<computes>:i64 = V + 1\nA:i64 = F(G)",
        "C := class{\n  Profile(T:string, V:i64)<computes>:i64 = V + 1\n  Twice()<computes>:i64 = Self.Profile(\"x\", 1)\n}\nA:i64 = C{}.Twice()",
        "A:i64 = Block{ Profile := 1; Profile + 1 }",
    };
    for (programs) |source| {
        const x = try b.run(source);
        try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
        try std.testing.expectEqual(@as(usize, 0), x.effects.inputs.len);
        try std.testing.expectEqualStrings("", printed(x, &buffer));
    }
    // A declaration further down is the module's throughout: a use above it is the unknown name.
    try b.refused("A:i64 = Profile(\"x\", 1)\nProfile(T:string, V:i64)<computes>:i64 = V + 1", .unknown_name, "Profile");
    // A module of a bundle: the name it exports wins where it is used, the standard one elsewhere.
    const modules = @import("modules.zig");
    const lib = "Profile<public>(T:string, V:i64)<computes>:i64 = V + 1";
    const used = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64 = Profile(\"x\", 1)" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const bundled = b.h.front.compileBundle(.{ .root = "main.forb", .modules = &used });
    try std.testing.expectEqual(@as(i64, 2), (try b.h.run(bundled.ok, fuel)).ok.get("A").?.integer);
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64 = Profile(\"x\", 1)\nB<public>:i64 = L.Profile(\"x\", 1)" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const standard = (try b.h.run(b.h.front.compileBundle(.{ .root = "main.forb", .modules = &plain }).ok, fuel)).ok;
    try std.testing.expectEqual(@as(i64, 1), standard.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 2), standard.get("B").?.integer);
    try std.testing.expectEqualStrings("profile x: 0 s\n", printed(standard, &buffer));
}

test "at every budget both machines stop at the same node, and a line is shown only for a body that finished" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 12.0, 15.0 };
    defer b.script.clocks = &.{};
    const source =
        \\Wait(S:float)<transacts><suspends>:float = Block{ Sleep(S); S }
        \\A:task(float) = Spawn{ Profile("a", Wait(1.0)) }
        \\B:i64 = Attempt(Block{ Profile("b", 2); Require[false]; 1 }, 3)
        \\C:i64 = Profile("c", Profile("d", 4) + 1)
    ;
    const whole = (try b.outcome(source, fuel)).ok;
    var budget: u64 = 1;
    var stopped: usize = 0;
    while (budget < 4096) : (budget += 1) {
        const result = try b.outcome(source, budget);
        if (result == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
        const kept = b.h.control.effects.inputs.record();
        try std.testing.expect(kept.entries.len <= whole.effects.inputs.len);
        try std.testing.expectEqualDeep(whole.effects.inputs[0..kept.entries.len], kept.entries);
        stopped += 1;
    }
    try std.testing.expect(stopped > 10 and budget < 4096);
}

test "digest and off runs replay the line and the record from the stored run" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 12.5, 20.0 };
    defer b.script.clocks = &.{};
    const source =
        \\Wait(S:float)<transacts><suspends>:float = Block{ Sleep(S); S }
        \\Step(N:i64)<transacts>:i64 = Profile("step", N + 1)
        \\A:task(float) = Spawn{ Profile("a", Wait(1.0)) }
        \\B:i64 = Iterate(Step, 50, 0)
        \\C:i64 = Attempt(Block{ Profile("c", 2); Require[false]; 1 }, 3)
    ;
    const p = try b.h.compile(source);
    b.script.rewind();
    const whole = (try b.h.run(p, fuel)).ok;
    var buffer: [2048]u8 = undefined;
    const expected = try std.testing.allocator.dupe(u8, try reportOf(whole, &buffer));
    defer std.testing.allocator.free(expected);
    // 50 lines of `Step`, and the task's.
    try std.testing.expectEqual(@as(usize, 51), whole.effects.entries.len);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const vm = &b.h.runtime.machine.control;
    defer {
        vm.trace = .full;
        vm.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    }
    for ([_]types.TraceMode{ .digest, .off }) |trace| {
        vm.trace = trace;
        vm.reclaim_floor = 0;
        again.control.reclaim_floor = 0;
        vm.effects.inputs.prefix = whole.effects.inputRecord();
        const run = b.h.runtime.evaluate(p, fuel).ok;
        try std.testing.expectEqual(whole.effects.output.count, run.effects.output.count);
        try std.testing.expect(whole.effects.output.eql(run.effects.output));
        if (trace == .digest) {
            var out: std.Io.Writer = .fixed(&buffer);
            _ = try reporting.writeReplayed(&out, run, again.producer(p, fuel), false, .{});
            try std.testing.expectEqualStrings(expected, out.buffered());
            // A record changed in one reading is refused: the second run, given it, would print
            // another elapsed time than the digest the first run reported.
            try std.testing.expectEqual(@as(usize, 2), run.effects.inputs.len);
            var entries: [2]effects.InputEntry = run.effects.inputs[0..2].*;
            entries[1].bits = @bitCast(@as(f64, 99.0));
            var forged = run;
            forged.effects.inputs = &entries;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
    }
}

/// A random program of sequential and nested profiled sleeps in one task, and a model of what
/// the recorded clock (RFC-0086, I5) makes of them.
const Model = struct {
    clocks: []const f64,
    next: usize = 0,
    /// The latest reading: its tick and value (the clock never goes back).
    tick: ?u64 = null,
    value: f64 = 0.0,
    now: u64 = 0,
    out: std.Io.Writer,

    fn read(self: *Model) f64 {
        if (self.tick != null and self.tick.? == self.now) return self.value;
        const raw = self.clocks[self.next];
        self.next += 1;
        self.value = if (self.tick == null) raw else @max(self.value, raw);
        self.tick = self.now;
        return self.value;
    }
    /// `Sleep(Seconds)` at 60 ticks a second: a whole second is 60 ticks, and `0.0` waits one.
    fn sleep(self: *Model, seconds: u64) void {
        self.now += @max(1, seconds * 60);
    }
    fn profile(self: *Model, tag: u32, body: Step) void {
        const before = self.read();
        switch (body) {
            .sleep => |seconds| self.sleep(seconds),
            .pair => |pair| {
                self.profile(tag * 2 + 1, .{ .sleep = pair[0] });
                self.sleep(pair[1]);
            },
        }
        const after = self.read();
        self.out.print("profile p{d}: {d} s\n", .{ tag, after - before }) catch unreachable;
    }
};

const Step = union(enum) { sleep: u64, pair: [2]u64 };

test "a randomised oracle: profiled sleeps against a model of the recorded clock" {
    const b = try Bench.create();
    defer b.destroy();
    var prng = std.Random.DefaultPrng.init(0x0b6);
    const random = prng.random();
    var source: [4096]u8 = undefined;
    var expected: [4096]u8 = undefined;
    var actual: [4096]u8 = undefined;
    var clocks: [64]f64 = undefined;
    for (0..40) |round| {
        // Readings in quarter seconds, some of them below the one before (held at its value).
        for (&clocks) |*clock| clock.* = 100.0 + @as(f64, @floatFromInt(random.uintLessThan(u32, 40))) / 4.0;
        var model: Model = .{ .clocks = &clocks, .out = .fixed(&expected) };
        var text: std.Io.Writer = .fixed(&source);
        try text.writeAll("Run()<transacts><suspends>:void = Block{\n");
        const count = 1 + random.uintLessThan(u32, 6);
        for (0..count) |index| {
            const tag: u32 = @intCast(index);
            if (random.boolean()) {
                const seconds = random.uintLessThan(u64, 4);
                model.profile(tag, .{ .sleep = seconds });
                try text.print("  Profile(\"p{d}\", Sleep({d}.0))\n", .{ tag, seconds });
            } else {
                const pair: [2]u64 = .{ random.uintLessThan(u64, 3), random.uintLessThan(u64, 3) };
                model.profile(tag, .{ .pair = pair });
                try text.print("  Profile(\"p{d}\", Block{{ Profile(\"p{d}\", Sleep({d}.0)); Sleep({d}.0) }})\n", .{ tag, tag * 2 + 1, pair[0], pair[1] });
            }
        }
        try text.writeAll("}\nT:task(void) = Spawn{ Run() }\n");
        b.script.clocks = &clocks;
        const x = try b.run(text.buffered());
        try std.testing.expectEqualStrings(model.out.buffered(), printed(x, &actual));
        try std.testing.expectEqual(@as(usize, model.next), x.effects.inputs.len);
        _ = round;
    }
    b.script.clocks = &.{};
}
