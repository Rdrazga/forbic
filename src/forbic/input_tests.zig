//! Inputs (RFC-0086, P2.2): the wall clock `GetSecondsSinceEpoch()`, the input record and its
//! readers. Every program runs on both machines through the harness: the reference evaluator
//! asks a scripted world (`effects.Script`), the VM is given the reference's record as its
//! prefix and no world, and the report of each is replayed against the record. Both machines
//! must agree on values, fuel, diagnostics and the record, whether the run completes or not.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const stdlib_natives = @import("stdlib_natives.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const start: f64 = 1_700_000_000.0;

/// Both machines and a scripted world, which only the first machine is given.
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
    /// A run of both machines from a fresh world.
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
    fn fails(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
        const result = try self.outcome(source, fuel);
        if (result != .failed) {
            std.debug.print("expected {t}: {s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
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

fn float(x: evaluator.Execution, name: []const u8) f64 {
    return x.get(name).?.floating;
}

/// The lines a `full` run committed.
fn printed(x: evaluator.Execution, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (0..x.effects.entries.len) |index| writer.print("{s}\n", .{x.effects.text(index)}) catch unreachable;
    return writer.buffered();
}

fn expectEntries(x: evaluator.Execution, ticks: []const u64, raws: []const f64) !void {
    try std.testing.expectEqual(ticks.len, x.effects.inputs.len);
    for (x.effects.inputs, ticks, raws) |entry, tick, raw| {
        try std.testing.expectEqual(effects.InputKind.clock, entry.kind);
        try std.testing.expectEqual(tick, entry.tick);
        try std.testing.expectEqual(@as(u64, @bitCast(raw)), entry.bits);
        try std.testing.expectEqual(@as(u32, 0), entry.request);
        try std.testing.expectEqual(effects.InputStatus.value, entry.status);
    }
    try std.testing.expectEqual(@as(usize, 0), x.effects.input_bytes.len);
}

fn reportOf(x: evaluator.Execution, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try reporting.write(&out, x, false, .{});
    return out.buffered();
}

test "the clock is read once at the root, in functions and in a region that fails, and the report counts the entry" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Stamp()<transacts>:float = GetSecondsSinceEpoch()
        \\Start:float = GetSecondsSinceEpoch()
        \\Again:logic = Stamp() == Start
        \\Lost:float = Attempt(Block{X := GetSecondsSinceEpoch(); Require[X < 0.0]; X}, -1.0)
        \\Same:float = Stamp()
    );
    try std.testing.expectEqual(start, float(x, "Start"));
    try std.testing.expect(x.get("Again").?.boolean);
    try std.testing.expectEqual(@as(f64, -1.0), float(x, "Lost"));
    try std.testing.expectEqual(start, float(x, "Same"));
    // The root runs at tick 0: one reading, asked of the world once.
    try expectEntries(x, &.{0}, &.{start});
    try std.testing.expectEqual(@as(u64, 1), b.script.reads);
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("{\"Start\":1700000000,\"Again\":true,\"Lost\":-1,\"Same\":1700000000,\"$inputs\":{\"count\":1,\"bytes\":0}}\n", try reportOf(x, &buffer));
    // A program that reads nothing reports as it did before.
    const quiet = try b.run("A:i64=1\nF()<transacts>:float=GetSecondsSinceEpoch()");
    try std.testing.expectEqual(@as(usize, 0), quiet.effects.inputs.len);
    try std.testing.expectEqualStrings("{\"A\":1}\n", try reportOf(quiet, &buffer));
}

test "each tick has one reading: tasks at one tick share it, a later tick asks again, and the clock never goes back" {
    const b = try Bench.create();
    defer b.destroy();
    const program =
        \\Seen(Name:string)<transacts>:void = Print("{Name} {GetSecondsSinceEpoch()}")
        \\Later(Name:string, Wait:float)<transacts><suspends>:void = Block{ Sleep(Wait); Seen(Name); Seen("{Name} again") }
        \\A:task(void) = Spawn{ Later("a", 1.0) }
        \\B:task(void) = Spawn{ Later("b", 1.0) }
        \\C:task(void) = Spawn{ Later("c", 2.0) }
        \\D:task(void) = Spawn{ Later("d", 0.5) }
        \\Root:tuple() = Seen("root")
    ;
    // The world: 100 at tick 0, then at tick 30 a clock that went back, then the pace.
    b.script.clocks = &.{ 100.0, 90.0, 160.0, 220.0 };
    defer b.script.clocks = &.{};
    var buffer: [1024]u8 = undefined;
    const x = try b.run(program);
    try std.testing.expectEqualStrings(
        \\root 100
        \\d 100
        \\d again 100
        \\a 160
        \\a again 160
        \\b 160
        \\b again 160
        \\c 220
        \\c again 220
        \\
    , printed(x, &buffer));
    try expectEntries(x, &.{ 0, 30, 60, 120 }, &.{ 100.0, 90.0, 160.0, 220.0 });
    try std.testing.expectEqual(@as(u64, 4), b.script.reads);
    // A tick rate of its own: the same reads at other ticks.
    b.h.control.tick_rate = 10;
    b.h.runtime.machine.control.tick_rate = 10;
    defer {
        b.h.control.tick_rate = types.Scheduler.default_tick_rate;
        b.h.runtime.machine.control.tick_rate = types.Scheduler.default_tick_rate;
    }
    try expectEntries(try b.run(program), &.{ 0, 5, 10, 20 }, &.{ 100.0, 90.0, 160.0, 220.0 });
}

test "a drain, a firing and a landing read the clock at the tick they run at" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 5.0, 7.0, 9.0 };
    defer b.script.clocks = &.{};
    var buffer: [1024]u8 = undefined;
    // A task started by a region that commits runs in the drain, at the root's tick; a `When`
    // fires at the write of a task woken at tick 60; a cancelled task's `Defer` lands there too.
    const x = try b.run(
        \\var X:i64 = 0
        \\Note(Name:string)<transacts>:void = Print("{Name} {GetSecondsSinceEpoch()}")
        \\Held()<transacts><suspends>:void = Note("held")
        \\Sleeper()<transacts><suspends>:void = Block{ Defer{ Note("landing") }; Sleep(Inf) }
        \\W:task(void) = When(X > 0, Note("fired"))
        \\S:task(void) = Spawn{ Sleeper() }
        \\Writer()<transacts><suspends>:void = Block{ Sleep(1.0); set X = 1; S.Cancel(); Sleep(1.0); Note("end") }
        \\R:logic = Attempt(Block{ T := Spawn{ Held() }; true }, false)
        \\T:task(void) = Spawn{ Writer() }
    );
    try std.testing.expectEqualStrings("held 5\nfired 7\nlanding 7\nend 9\n", printed(x, &buffer));
    try expectEntries(x, &.{ 0, 60, 120 }, &.{ 5.0, 7.0, 9.0 });
}

test "what the world gives that is no time ends the run where it is read, and the record keeps it" {
    const b = try Bench.create();
    defer b.destroy();
    const program = "F()<transacts><suspends>:float = Block{ Sleep(1.0); GetSecondsSinceEpoch() }\nT:task(float) = Spawn{ F() }\nA:float = GetSecondsSinceEpoch()";
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |raw| {
        const answers = [_]f64{ 3.0, raw };
        b.script.clocks = &answers;
        try b.fails(program, .input_invalid, "GetSecondsSinceEpoch");
        // Both machines kept both entries (I8): the harness compared them.
        try std.testing.expectEqual(@as(u32, 2), b.h.control.effects.inputs.count);
        try std.testing.expectEqual(@as(u64, @bitCast(raw)), b.h.runtime.machine.control.effects.inputs.entries[1].bits);
    }
    b.script.clocks = &.{};
    // A device that fails: the second machine has a world of its own that fails alike, since a
    // record cannot say that the world failed.
    b.script.fail_read = 1;
    var failing: effects.Script = .{ .fail_read = 1 };
    b.h.runtime.machine.control.effects.inputs.source = failing.source();
    try b.fails(program, .input_failed, "GetSecondsSinceEpoch");
    b.h.runtime.machine.control.effects.inputs.source = null;
    try std.testing.expectEqual(@as(u32, 1), b.h.control.effects.inputs.count);
    try std.testing.expectEqual(@as(u64, 2), failing.reads);
    b.script.fail_read = null;
    // A host that gives no world.
    b.h.control.effects.inputs.source = null;
    defer b.h.control.effects.inputs.source = b.script.source();
    try b.fails("A:i64 = 1\nB:float = GetSecondsSinceEpoch()", .input_unavailable, "GetSecondsSinceEpoch");
    try std.testing.expectEqual(@as(u32, 0), b.h.control.effects.inputs.count);
}

test "the input record is bounded by its capacity, not by fuel: ticks that each read the clock fill it exactly" {
    try @import("profile.zig").requireBootstrap();
    const b = try Bench.create();
    defer b.destroy();
    var source: [512]u8 = undefined;
    // Reads at one tick hold one entry however many there are.
    const same = try b.run("Read(N:i64)<transacts>:float = Block{ var T:float = 0.0; var I:i64 = 0; While(I < N, Block{ set T = GetSecondsSinceEpoch(); set I = I + 1 }); T }\nA:float = Read(300)");
    try std.testing.expectEqual(@as(usize, 1), same.effects.inputs.len);
    // A run of a thousand ticks outgrows the stored witness: both machines run in `digest` mode,
    // the second given the first one's record, as the harness gives it.
    const h = b.h;
    for ([_]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |control| control.trace = .digest;
    defer for ([_]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |control| {
        control.trace = .full;
    };
    const format = "Tick(N:i64)<transacts><suspends>:float = Block{{ var T:float = 0.0; var I:i64 = 0; While(I < N, Block{{ NextTick(); set T = GetSecondsSinceEpoch(); set I = I + 1 }}); T }}\nX:task(float) = Spawn{{ Tick({d}) }}\nA:float = GetSecondsSinceEpoch()";
    // The root reads at tick 0 and the task at each of its ticks: one entry more than ticks.
    for ([_]u64{ effects.input_entry_capacity - 2, effects.input_entry_capacity - 1, effects.input_entry_capacity }) |ticks| {
        b.script.rewind();
        const p = try h.compile(try std.fmt.bufPrint(&source, format, .{ticks}));
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        h.runtime.machine.control.effects.inputs.prefix = h.control.effects.inputs.record();
        const actual = h.runtime.evaluate(p, fuel);
        for ([_]evaluator.Result{ reference, actual }) |result| {
            if (ticks < effects.input_entry_capacity) {
                try std.testing.expectEqual(@as(usize, ticks + 1), result.ok.effects.inputs.len);
            } else {
                // One tick more: `input_limit` at the call, with the full record kept (I8).
                try std.testing.expectEqual(types.Diagnostic.Code.input_limit, result.failed.code);
                try std.testing.expectEqualStrings("GetSecondsSinceEpoch", p.source[result.failed.span.start..result.failed.span.end]);
            }
        }
        try std.testing.expectEqualDeep(h.control.effects.inputs.record().entries, h.runtime.machine.control.effects.inputs.record().entries);
        try std.testing.expectEqual(@as(u32, @intCast(@min(ticks + 1, effects.input_entry_capacity))), h.runtime.machine.control.effects.inputs.count);
    }
}

test "at every budget both machines stop at the same node with the same record, which keeps what was read" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 8.0, 12.0 };
    defer b.script.clocks = &.{};
    const sources = [_][]const u8{
        "Stamp()<transacts>:float = GetSecondsSinceEpoch()\nA:float = Stamp()\nB:float = Attempt(Block{X := Stamp(); Require[X < 0.0]; X}, Stamp())\nC:float = GetSecondsSinceEpoch() + A",
        "Later(W:float)<transacts><suspends>:float = Block{ Sleep(W); GetSecondsSinceEpoch() }\nA:task(float) = Spawn{ Later(1.0) }\nB:task(float) = Spawn{ Later(2.0) }\nC:float = GetSecondsSinceEpoch()",
        "Step(S:float)<transacts>:float = S + GetSecondsSinceEpoch()\nA:float = Iterate(Step, 9, 0.0)",
    };
    for (sources) |source| {
        const whole = (try b.outcome(source, fuel)).ok;
        const entries = whole.effects.inputs.len;
        var budget: u64 = 1;
        var stopped: usize = 0;
        while (budget < 4096) : (budget += 1) {
            const result = try b.outcome(source, budget);
            if (result == .ok) break;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            // Whatever was recorded before the limit is a prefix of the whole run's record.
            const kept = b.h.control.effects.inputs.record();
            try std.testing.expect(kept.entries.len <= entries);
            try std.testing.expectEqualDeep(whole.effects.inputs[0..kept.entries.len], kept.entries);
            stopped += 1;
        }
        try std.testing.expect(stopped > 5 and budget < 4096);
    }
}

test "the tool's rerun after a limit is served the first attempt's record and asks the world only past it" {
    const b = try Bench.create();
    defer b.destroy();
    const source = "Later(W:float)<transacts><suspends>:float = Block{ Sleep(W); GetSecondsSinceEpoch() }\nA:task(float) = Spawn{ Later(1.0) }\nB:task(float) = Spawn{ Later(2.0) }\nC:float = GetSecondsSinceEpoch()";
    const p = try b.h.compile(source);
    const vm = &b.h.runtime.machine.control.effects.inputs;
    var first: effects.Script = .{ .clocks = &.{ 1.0, 2.0, 3.0 } };
    vm.source = first.source();
    vm.prefix = .{};
    defer vm.source = null;
    // The first attempt stops after its second reading.
    var budget: u64 = 1;
    while (true) : (budget += 1) {
        const attempt = b.h.runtime.evaluate(p, budget);
        if (attempt == .failed and vm.count == 2) break;
        first.rewind();
        try std.testing.expect(budget < 4096);
    }
    // The second attempt, in digest mode, asks a world that would now answer otherwise.
    var second: effects.Script = .{ .clocks = &.{ 70.0, 80.0, 90.0 } };
    vm.again();
    vm.source = second.source();
    b.h.runtime.machine.control.trace = .digest;
    defer b.h.runtime.machine.control.trace = .full;
    const x = b.h.runtime.evaluate(p, fuel).ok;
    try std.testing.expectEqual(@as(u64, 1), second.reads);
    try expectEntries(x, &.{ 0, 60, 120 }, &.{ 1.0, 2.0, 70.0 });
    // Its report replays a second run that is given the record and no world.
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.writeReplayed(&out, x, again.producer(p, fuel), false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"$inputs\":{\"count\":3,\"bytes\":0}") != null);
    try std.testing.expectEqual(@as(?effects.InputSource, null), again.control.effects.inputs.source);
}

test "the standard name yields to every declaration of it, and the diagnostics name the place" {
    const b = try Bench.create();
    defer b.destroy();
    // A function, a local, a parameter, a member reached through `Self`; a module reached
    // through `using` is below, in a bundle.
    const programs = [_][]const u8{
        "GetSecondsSinceEpoch()<computes>:float = 4.0\nA:float = GetSecondsSinceEpoch()",
        "A:float = Block{ GetSecondsSinceEpoch := Fn()<computes>:float{4.0}; GetSecondsSinceEpoch() }",
        "F(GetSecondsSinceEpoch:function(tuple(), float))<computes>:float = GetSecondsSinceEpoch()\nG()<computes>:float = 4.0\nA:float = F(G)",
        "C := class{\n  GetSecondsSinceEpoch()<computes>:float = 4.0\n  Twice()<computes>:float = Self.GetSecondsSinceEpoch() * 1.0\n}\nA:float = C{}.Twice()",
    };
    for (programs) |source| {
        const x = try b.run(source);
        try std.testing.expectEqual(@as(f64, 4.0), float(x, "A"));
        try std.testing.expectEqual(@as(usize, 0), x.effects.inputs.len);
    }
    // A declaration further down is the module's throughout: a use above it is the unknown name.
    try b.refused("A:float = GetSecondsSinceEpoch()\nGetSecondsSinceEpoch()<computes>:float = 4.0", .unknown_name, "GetSecondsSinceEpoch");
    // Bare in the class it stays the unknown name it was, rather than the standard one.
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, b.h.front.compile("C := class{\n  GetSecondsSinceEpoch()<computes>:float = 4.0\n  F()<transacts>:float = GetSecondsSinceEpoch()\n}").failed.code);
    // A module of a bundle: the name it exports wins where it is used, the standard one elsewhere.
    const modules = @import("modules.zig");
    const lib = "GetSecondsSinceEpoch<public>()<computes>:float = 4.0\nStamp<public>()<transacts>:float = 0.0 + GetSecondsSinceEpoch()";
    const used = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:float = GetSecondsSinceEpoch()\nB<public>:float = L.Stamp()" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const bundled = b.h.front.compileBundle(.{ .root = "main.forb", .modules = &used });
    const x = (try b.h.run(bundled.ok, fuel)).ok;
    try std.testing.expectEqual(@as(f64, 4.0), x.get("A").?.floating);
    try std.testing.expectEqual(@as(f64, 4.0), x.get("B").?.floating);
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:float = GetSecondsSinceEpoch()\nB<public>:float = L.GetSecondsSinceEpoch()" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const standard = (try b.h.run(b.h.front.compileBundle(.{ .root = "main.forb", .modules = &plain }).ok, fuel)).ok;
    try std.testing.expectEqual(start, standard.get("A").?.floating);
    try std.testing.expectEqual(@as(f64, 4.0), standard.get("B").?.floating);
    // The native by its id, as RFC-0079's are.
    const bound = try b.run("Now := native{\"std.clock_seconds\"}\nF()<transacts>:float = Now()\nA:float = F()");
    try std.testing.expectEqual(start, float(bound, "A"));
    // An input needs all three heap effects, named as for a call of a `<transacts>` function.
    try b.refused("F()<reads>:float = GetSecondsSinceEpoch()", .call_requires_writes_allocates, "GetSecondsSinceEpoch");
    try b.refused("F()<computes>:float = GetSecondsSinceEpoch()", .call_requires_transacts, "GetSecondsSinceEpoch");
    try b.refused("F()<reads><writes>:float = GetSecondsSinceEpoch()", .call_requires_allocates, "GetSecondsSinceEpoch");
    try b.refused("Now := native{\"std.clock_seconds\"}\nF()<reads>:float = Now()", .call_requires_writes_allocates, "Now");
    // A guard reads cells and nothing else, so it reads no input.
    try b.refused("var X:float = 0.0\nW:task(void) = When(X < GetSecondsSinceEpoch(), Print(\"late\"))", .guard_effect, "GetSecondsSinceEpoch");
    try b.refused("var X:float = 0.0\nU:task(void) = Upon(GetSecondsSinceEpoch() > X, Print(\"late\"))", .guard_effect, "GetSecondsSinceEpoch");
    try b.refused("var X:float = 0.0\nF()<transacts><suspends>:void = Await(X < GetSecondsSinceEpoch())", .guard_effect, "GetSecondsSinceEpoch");
    // An input is the world's answer to whoever runs the code: it dictates (RFC-0085, V22).
    try b.refused("F()<transacts><predicts>:float = GetSecondsSinceEpoch()", .call_requires_dictates, "GetSecondsSinceEpoch");
    // It takes no argument and is called.
    try b.refused("A:float = GetSecondsSinceEpoch(1.0)", .argument_count, "1.0");
    try b.refused("A:float = GetSecondsSinceEpoch", .unknown_name, "GetSecondsSinceEpoch");
    try b.refused("A:i64 = GetSecondsSinceEpoch()", .type_mismatch, "GetSecondsSinceEpoch");
}

fn kernel(id: []const u8) u16 {
    return stdlib_natives.find(&native_std.table, id).?;
}

/// The program `p` with the heap effects of every function made these.
fn retyped(h: *harness.Harness, p: types.Program, set: types.EffectSet) types.Program {
    var forged = p;
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    for (h.metadata[0..p.functions.len]) |*function| {
        function.transacts = set.reads or set.writes or set.allocates;
        function.detail.no_reads = function.transacts and !set.reads;
        function.detail.no_writes = function.transacts and !set.writes;
        function.detail.no_allocates = function.transacts and !set.allocates;
    }
    forged.functions = h.metadata[0..p.functions.len];
    return forged;
}

/// A program like `p` in which every native call of a function that names `from` names `to`
/// with no operands.
fn renamed(h: *harness.Harness, p: types.Program, from: u16, to: u16) !types.Program {
    var forged = p;
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    var changed: usize = 0;
    for (h.body[0..p.function_nodes.len]) |*entry| {
        if (entry.input == .operation and entry.node.kind == .native_call and entry.node.kind.native_call.native == from) {
            entry.node.kind.native_call.native = to;
            entry.node.kind.native_call.count = 0;
            changed += 1;
        }
    }
    try std.testing.expect(changed != 0);
    forged.function_nodes = h.body[0..p.function_nodes.len];
    return forged;
}

fn sneaks(ctx: *native.Context) native.Error!f64 {
    return @bitCast((try ctx.input(.clock, 0)).bits);
}
fn asksAnotherClock(ctx: *native.Context) native.Error!f64 {
    return @bitCast((try ctx.input(.clock, 1)).bits);
}

test "forged code and tables: an input native stands only where all three heap effects are, and a native reads no input it does not declare" {
    const b = try Bench.create();
    defer b.destroy();
    const h = b.h;
    // The clock in a function that reads, computes, or has two of the three, in both machines.
    const p = try h.compile("F()<transacts>:float = GetSecondsSinceEpoch()\nA:float = F()");
    for ([_]types.EffectSet{ .{ .reads = true, .diverges = false }, .{ .diverges = false }, .{ .reads = true, .writes = true, .diverges = false }, .{ .writes = true, .allocates = true, .diverges = false } }) |set| {
        try harness.invalid(h, retyped(h, p, set));
    }
    // The clock's kernel index put into a computing function's call of a pure kernel.
    const computing = try h.compile("F()<computes>:float = PiFloat * Abs(-1.0)\nA:float = F()");
    try harness.invalid(h, try renamed(h, computing, kernel("std.abs"), kernel("std.clock_seconds")));
    // In a `<transacts>` function the forged call is an input like any other.
    const transacting = try h.compile("F()<transacts>:float = Abs(-1.0)\nA:float = F()");
    b.script.rewind();
    const read = (try h.run(try renamed(h, transacting, kernel("std.abs"), kernel("std.clock_seconds")), fuel)).ok;
    try std.testing.expectEqual(start, float(read, "A"));

    var table: [native_std.table.len]native.Entry = native_std.table;
    h.front.natives = &table;
    defer h.front.natives = &native_std.table;
    const sqrt = kernel("std.sqrt");
    const clock = kernel("std.clock_seconds");
    // A pure kernel declared an input: a function that only computes may not call it.
    table[sqrt].effect = .input;
    try harness.invalid(h, try h.compile("F()<computes>:float = Sqrt(4.0)\nA:float = F()"));
    // From the root it runs and reads nothing; the replay cannot check an input it does not
    // know, and refuses the report.
    const root = try h.compile("A:float = Sqrt(4.0)");
    const reference = evaluator.evaluateWithRuntimeStorage(root, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).ok;
    try std.testing.expectEqual(@as(f64, 2.0), reference.get("A").?.floating);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(reference, false, .{}));
    table[sqrt] = native_std.table[sqrt];
    // An input that answers nothing is no entry: the compiler has no form, and a program
    // compiled against the honest table is refused by both machines.
    const honest = try h.compile("F()<transacts>:float = GetSecondsSinceEpoch()\nA:float = F()");
    table[clock].result = .{ .element = .i64, .kind = .unit };
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, h.front.compile("A:float = GetSecondsSinceEpoch()").failed.code);
    try harness.invalid(h, honest);
    table[clock] = native_std.table[clock];
    // A native that reaches for an input it does not declare: a fault at the call, nothing read.
    for ([_]native.Effect{ .none, .draw, .output }) |declared| {
        if (declared == .output) continue; // An action yields nothing; a float result is refused by the table.
        table[clock] = native.entry("std.clock_seconds", sneaks, .{ .base = 2 });
        table[clock].effect = declared;
        const sneaky = try h.compile("F()<transacts>:float = GetSecondsSinceEpoch()\nA:float = F()");
        b.script.rewind();
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(sneaky, fuel)).failed.code);
        try std.testing.expectEqual(@as(u64, 0), b.script.reads);
        try std.testing.expectEqual(@as(u32, 0), h.control.effects.inputs.count);
    }
    table[clock] = native_std.table[clock];
    // An input native that asks for a clock other than the one there is: a fault at the call.
    table[clock] = native.effectEntry("std.clock_seconds", asksAnotherClock, .{ .base = 2 }, .input);
    const other = try h.compile("F()<transacts>:float = GetSecondsSinceEpoch()\nA:float = F()");
    b.script.rewind();
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(other, fuel)).failed.code);
    try std.testing.expectEqual(@as(u64, 0), b.script.reads);
    table[clock] = native_std.table[clock];
}

/// Runs `source` on both machines and returns the reference's run, whose record lives in the
/// harness until the next run.
fn stored(b: Bench, source: []const u8) !evaluator.Execution {
    _ = try b.run(source);
    // The harness ran the reference first; its run is the one in `h.control`.
    const p = try b.h.compile(source);
    b.script.rewind();
    const x = evaluator.evaluateWithRuntimeStorage(p, &b.h.values, &b.h.members, &b.h.control, &b.h.state, &b.h.frames, fuel).ok;
    _ = try reporting.validate(x, false, .{});
    return x;
}

test "the replay refuses a record that the steps do not lead to: values, entries, requests, kinds, ticks and the clock's rule" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 8.0, 12.0 };
    defer b.script.clocks = &.{};
    const x = try stored(b,
        \\Later(W:float)<transacts><suspends>:float = Block{ Sleep(W); GetSecondsSinceEpoch() + GetSecondsSinceEpoch() }
        \\A:task(float) = Spawn{ Later(1.0) }
        \\B:task(float) = Spawn{ Later(2.0) }
        \\C:float = GetSecondsSinceEpoch()
        \\D:float = Attempt(Block{ Y := GetSecondsSinceEpoch(); Require[Y < 0.0]; Y }, 0.0)
    );
    // The world went back at tick 60: the steps hold 10, the clamped value.
    try expectEntries(x, &.{ 0, 60, 120 }, &.{ 10.0, 8.0, 12.0 });
    const entries = x.effects.inputs;
    var forged_entries: [8]effects.InputEntry = undefined;
    var forged = x;
    const Forge = struct {
        fn with(execution: evaluator.Execution, storage: []effects.InputEntry, list: []const effects.InputEntry) evaluator.Execution {
            var changed = execution;
            @memcpy(storage[0..list.len], list);
            changed.effects.inputs = storage[0..list.len];
            return changed;
        }
    };
    // Each field of each entry.
    for (0..entries.len) |at| {
        for (0..5) |field| {
            forged = Forge.with(x, &forged_entries, entries);
            const entry = &forged_entries[at];
            switch (field) {
                // A raw reading that went back can change while it stays below the one before
                // it: nothing the run did depends on it. One raised above every other does.
                0 => entry.bits = @bitCast(@as(f64, @bitCast(entry.bits)) + 100.0),
                1 => entry.tick += 1,
                2 => entry.kind = .line,
                3 => entry.request = 1,
                else => entry.status = .end,
            }
            errdefer std.debug.print("entry {d} field {d}\n", .{ at, field });
            try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        }
    }
    // An entry missing, or one more: at the end, at the start, and a second one at one tick,
    // which would claim a cached read as an entry.
    try std.testing.expectError(error.InvalidExecution, reporting.validate(Forge.with(x, &forged_entries, entries[0..2]), false, .{}));
    try std.testing.expectError(error.InvalidExecution, reporting.validate(Forge.with(x, &forged_entries, entries[1..]), false, .{}));
    var longer: [4]effects.InputEntry = .{ entries[0], entries[1], entries[2], entries[2] };
    longer[3].tick = 180;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(Forge.with(x, &forged_entries, &longer), false, .{}));
    const doubled = [_]effects.InputEntry{ entries[0], entries[1], entries[1], entries[2] };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(Forge.with(x, &forged_entries, &doubled), false, .{}));
    // Bytes for an entry that has none, and a record of bytes no entry owns.
    forged = Forge.with(x, &forged_entries, entries);
    forged_entries[0].end = 1;
    forged.effects.input_bytes = "x";
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    forged = x;
    forged.effects.input_bytes = "x";
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    // A reading that is no number.
    forged = Forge.with(x, &forged_entries, entries);
    forged_entries[2].bits = @bitCast(std.math.inf(f64));
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    // The record of a run that read nothing, given an entry.
    _ = try b.run("A:i64 = 1");
    const none = evaluator.evaluateWithRuntimeStorage(try b.h.compile("A:i64 = 1"), &b.h.values, &b.h.members, &b.h.control, &b.h.state, &b.h.frames, fuel).ok;
    var lone = none;
    lone.effects.inputs = entries[0..1];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(lone, false, .{}));
}

test "a forged step value is refused: a raw reading that went back, another tick's value, a cached read's" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 8.0 };
    defer b.script.clocks = &.{};
    const source = "Later()<transacts><suspends>:float = Block{ Sleep(1.0); GetSecondsSinceEpoch() }\nA:task(float) = Spawn{ Later() }\nC:float = GetSecondsSinceEpoch()\nD:float = GetSecondsSinceEpoch()";
    const x = try stored(b, source);
    // The steps: the root's two reads at tick 0 and the task's at tick 60, whose value is the
    // clamped 10, not the world's 8.
    var clock_steps: usize = 0;
    for (b.h.control.calls[0..b.h.control.call_count], 0..) |step, at| {
        if (step.value != .floating or step.value.floating != 10.0) continue;
        clock_steps += 1;
        for ([_]f64{ 8.0, 11.0, -10.0 }) |claimed| {
            const original = b.h.control.calls[at];
            b.h.control.calls[at].value = .{ .floating = claimed };
            defer b.h.control.calls[at] = original;
            const pc = original.pc;
            const register = if (original.function == 0) &b.h.values[pc] else null;
            const kept = if (register) |slot| slot.* else types.Value{ .integer = 0 };
            if (register) |slot| slot.* = .{ .floating = claimed };
            defer if (register) |slot| {
                slot.* = kept;
            };
            try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{}));
        }
    }
    try std.testing.expect(clock_steps >= 3);
    _ = try reporting.validate(x, false, .{});
}

test "digest runs at six windows give the stored report, and refuse a forged record" {
    const b = try Bench.create();
    defer b.destroy();
    b.script.clocks = &.{ 10.0, 8.0, 12.0 };
    defer b.script.clocks = &.{};
    const source =
        \\Later(W:float)<transacts><suspends>:float = Block{ Sleep(W); Print("t {GetSecondsSinceEpoch()}"); GetSecondsSinceEpoch() }
        \\Step(S:float)<transacts>:float = S + GetSecondsSinceEpoch()
        \\A:task(float) = Spawn{ Later(1.0) }
        \\B:task(float) = Spawn{ Later(2.0) }
        \\C:float = Iterate(Step, 12, 0.0)
    ;
    const p = try b.h.compile(source);
    const whole = try b.run(source);
    var stored_report: [2048]u8 = undefined;
    const expected = try reportOf(whole, &stored_report);
    try std.testing.expect(std.mem.indexOf(u8, expected, "\"$inputs\":{\"count\":3,\"bytes\":0}") != null);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    defer {
        b.h.runtime.machine.control.trace = .full;
        b.h.runtime.machine.control.trace_window = types.ControlStorage.default_trace_window;
        b.h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    }
    var buffer: [2048]u8 = undefined;
    for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
        const vm = &b.h.runtime.machine.control;
        vm.trace = .digest;
        vm.trace_window = window;
        vm.reclaim_floor = 0;
        again.control.trace_window = window;
        again.control.reclaim_floor = 0;
        // The VM alone, given the stored run's record as its prefix.
        vm.effects.inputs.prefix = whole.effects.inputRecord();
        const digest = b.h.runtime.evaluate(p, fuel).ok;
        var out: std.Io.Writer = .fixed(&buffer);
        _ = try reporting.writeReplayed(&out, digest, again.producer(p, fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        // A record changed in one value is refused, though the second run is given it: its
        // steps no longer lead to the values the first run reported.
        var entries: [3]effects.InputEntry = digest.effects.inputs[0..3].*;
        entries[2].bits = @bitCast(@as(f64, 13.0));
        var forged = digest;
        forged.effects.inputs = &entries;
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        // And a record shorter than the run read: its second run has no world to ask.
        forged.effects.inputs = digest.effects.inputs[0..2];
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
    }
}
