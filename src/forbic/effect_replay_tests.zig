//! Native effects (RFC-0079) and the report replay: a record of effects is the one the run's
//! steps lead to or the report is refused, whether the steps were stored or arrive from a
//! second run; reclamation never touches what the log holds; and random programs agree with a
//! model of regions written in plain Zig.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const replay = @import("trace_replay.zig");
const World = @import("native_effect_tests.zig").World;

const fuel = 131072;

const Runs = struct { reference: evaluator.Execution, actual: evaluator.Execution };

/// Both machines with recording sinks, and the storage of the second run a replay needs.
const Bench = struct {
    w: World,
    again: *replay.Storage,

    fn create() !Bench {
        const w = try World.create();
        errdefer w.destroy();
        const again = try scratch.storage(replay.Storage);
        scratch.initialise(again);
        return .{ .w = w, .again = again };
    }
    fn destroy(self: Bench) void {
        self.configure(.full, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        scratch.release(self.again);
        self.w.destroy();
    }
    fn configure(self: Bench, trace: types.TraceMode, window: u32, floor: u32) void {
        const h = self.w.h;
        for ([_]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |control| {
            control.trace = trace;
            control.trace_window = window;
            control.reclaim_floor = floor;
        }
        self.again.control.trace_window = window;
        self.again.control.reclaim_floor = floor;
    }
    fn seed(self: Bench, value: u64) void {
        self.w.h.control.effects.seed = value;
        self.w.h.runtime.machine.control.effects.seed = value;
        self.again.control.effects.seed = value;
    }
    /// Runs both machines as configured. They agree on every binding, on the witness, on the
    /// record of effects and on what their sinks heard.
    fn both(self: Bench, p: types.Program) !Runs {
        const h = self.w.h;
        self.w.reference.clear();
        self.w.actual.clear();
        const expected = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const actual = h.runtime.evaluate(p, fuel);
        try std.testing.expect(expected == .ok and actual == .ok);
        const a = expected.ok;
        const b = actual.ok;
        for (a.values, b.values, 0..) |x, y, at| if (b.active(at)) try replay.same(x, y);
        try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
        for (a.aggregate_values, b.aggregate_values) |x, y| try replay.same(x, y);
        try std.testing.expectEqualDeep(a.callWitness(), b.callWitness());
        try std.testing.expectEqual(a.reclaims, b.reclaims);
        try std.testing.expectEqualDeep(a.effects.output, b.effects.output);
        try std.testing.expectEqual(a.effects.draws, b.effects.draws);
        try std.testing.expectEqual(a.effects.discarded, b.effects.discarded);
        try std.testing.expectEqual(a.effects.seed, b.effects.seed);
        try std.testing.expectEqualSlices(u8, a.effects.bytes, b.effects.bytes);
        try std.testing.expectEqualDeep(a.effects.entries, b.effects.entries);
        _ = try self.w.agreed();
        return .{ .reference = a, .actual = b };
    }
    fn producer(self: Bench, p: types.Program) types.TraceProducer {
        return self.again.producer(p, fuel);
    }
};

const sources = [_][]const u8{
    // Actions and draws at the root and in frames, kept and discarded.
    \\Risky(N:i64)<transacts><decides>:i64=Block{Print("risky {N}");Require[N>0];N}
    \\Roll()<transacts>:i64=Block{R:=GetRandomInt(1,6);Print("rolled {R}");R}
    \\A:=Print("first")
    \\B:i64=Attempt(Block{Print("pending");X:=Risky[1];Print("inner {X}");Risky[0]},-1)
    \\C:i64=Roll()+Roll()
    \\D:i64=Attempt(Block{Print("kept one");Y:=Risky[2];Print("kept two");Y+GetRandomInt(0,9)},-1)
    \\E:[]i64=Shuffle(array{1,2,3})
    \\F:float=GetRandomFloat(0.0,1.0)
    \\G:=Print("last")
    ,
    // A loop that prints text it builds, draws, and fails every third visit.
    \\Step(S:i64)<transacts>:i64=Block{T:="visit {S} of the loop";Print(T);D:=GetRandomInt(0,99);Attempt(Block{Print("draw {D}");Require[Mod[S,3]!=0];S},0);S+1}
    \\A:i64=Iterate(Step,20,0)
    \\B:=Print("done {A}")
    ,
    // Everything inside one region that commits, and then one that fails.
    \\Step(S:i64)<transacts>:i64=Block{Print("line {S}: {GetRandomInt(100,999)}");S+1}
    \\A:i64=Attempt(Block{X:=Iterate(Step,12,0);Require[X>0];X},-1)
    \\B:i64=Attempt(Block{X:=Iterate(Step,12,0);Require[X<0];X},-1)
    \\C:[]string=Shuffle(array{"a","b","c","d"})
    ,
    // No effects at all: the record is empty and says so.
    "Step(S:i64)<computes>:i64=S+1\nA:i64=Iterate(Step,9,0)",
    // Only root effects.
    "A:=Print(\"a\")\nB:i64=GetRandomInt(1,6)\nC:=Print(\"c {B}\")",
};

fn expectRefused(outcome: reporting.Error!reporting.Stats) !void {
    try std.testing.expectError(error.InvalidExecution, outcome);
}

test "a stored report replays its effects and refuses every forged record and every forged draw" {
    const bench = try Bench.create();
    defer bench.destroy();
    const allocator = std.testing.allocator;
    for (sources) |source| {
        const x = try bench.w.run(source);
        _ = try reporting.validate(x, false, .{});
        const record = x.effects;
        var forged = x;
        // Counts, sizes, the digest and the seed.
        forged.effects.draws += 1;
        try expectRefused(reporting.validate(forged, false, .{}));
        if (record.draws != 0) {
            forged = x;
            forged.effects.draws -= 1;
            try expectRefused(reporting.validate(forged, false, .{}));
            // Another seed names another stream: the draws the steps hold are not its draws.
            forged = x;
            forged.effects.seed ^= 1;
            try expectRefused(reporting.validate(forged, false, .{}));
        }
        forged = x;
        forged.effects.discarded += 1;
        try expectRefused(reporting.validate(forged, false, .{}));
        forged = x;
        forged.effects.output.count += 1;
        try expectRefused(reporting.validate(forged, false, .{}));
        forged = x;
        forged.effects.output.bytes += 1;
        try expectRefused(reporting.validate(forged, false, .{}));
        forged = x;
        forged.effects.output.digest ^= 1;
        try expectRefused(reporting.validate(forged, false, .{}));
        // A stored witness of a run that kept its output: saying it kept none is refused.
        if (record.entries.len != 0) {
            forged = x;
            forged.effects.entries = &.{};
            forged.effects.bytes = "";
            try expectRefused(reporting.validate(forged, false, .{}));
        }
        // The listed actions themselves: every one, its place and every byte.
        const entries = try allocator.alloc(effects.Entry, record.entries.len + 1);
        defer allocator.free(entries);
        const bytes = try allocator.alloc(u8, record.bytes.len + 8);
        defer allocator.free(bytes);
        @memcpy(bytes[0..record.bytes.len], record.bytes);
        @memset(bytes[record.bytes.len..], 'z');
        for (0..record.bytes.len) |at| {
            bytes[at] ^= 1;
            forged = x;
            forged.effects.bytes = bytes[0..record.bytes.len];
            try expectRefused(reporting.validate(forged, false, .{}));
            bytes[at] ^= 1;
        }
        if (record.entries.len >= 2) {
            // Two actions in the other order.
            @memcpy(entries[0..record.entries.len], record.entries);
            const first = record.entries[0];
            const second = record.entries[1];
            if (!std.mem.eql(u8, record.text(0), record.text(1))) {
                const moved = try allocator.alloc(u8, record.bytes.len);
                defer allocator.free(moved);
                @memcpy(moved, record.bytes);
                @memcpy(moved[0 .. second.end - second.start], record.text(1));
                @memcpy(moved[second.end - second.start ..][0 .. first.end - first.start], record.text(0));
                entries[0] = .{ .start = 0, .end = second.end - second.start };
                entries[1] = .{ .start = entries[0].end, .end = second.end };
                forged = x;
                forged.effects.entries = entries[0..record.entries.len];
                forged.effects.bytes = moved;
                try expectRefused(reporting.validate(forged, false, .{}));
            }
            // The same bytes cut at another place.
            @memcpy(entries[0..record.entries.len], record.entries);
            if (first.end != first.start) {
                entries[0].end -= 1;
                entries[1].start -= 1;
                forged = x;
                forged.effects.entries = entries[0..record.entries.len];
                try expectRefused(reporting.validate(forged, false, .{}));
            }
            // Entries that overlap, leave a gap, or run past the bytes.
            @memcpy(entries[0..record.entries.len], record.entries);
            entries[1].start = first.start;
            forged = x;
            forged.effects.entries = entries[0..record.entries.len];
            try expectRefused(reporting.validate(forged, false, .{}));
            @memcpy(entries[0..record.entries.len], record.entries);
            entries[record.entries.len - 1].end += 4;
            forged = x;
            forged.effects.entries = entries[0..record.entries.len];
            try expectRefused(reporting.validate(forged, false, .{}));
            forged.effects.bytes = bytes[0 .. record.bytes.len + 4];
            try expectRefused(reporting.validate(forged, false, .{}));
            // One action fewer, and one more.
            forged = x;
            forged.effects.entries = record.entries[0 .. record.entries.len - 1];
            try expectRefused(reporting.validate(forged, false, .{}));
            forged.effects.bytes = record.bytes[0..record.entries[record.entries.len - 2].end];
            try expectRefused(reporting.validate(forged, false, .{}));
            @memcpy(entries[0..record.entries.len], record.entries);
            entries[record.entries.len] = .{ .start = @intCast(record.bytes.len), .end = @intCast(record.bytes.len + 2) };
            forged = x;
            forged.effects.entries = entries;
            forged.effects.bytes = bytes[0 .. record.bytes.len + 2];
            try expectRefused(reporting.validate(forged, false, .{}));
        }
        // The value of every draw is the one the stream gives at its position: any other
        // integer or float in a step or a root register is refused, in range or out of it.
        const p = x.program;
        const steps = try allocator.dupe(types.CallStep, x.call_steps);
        defer allocator.free(steps);
        var draws: usize = 0;
        for (steps, x.call_steps) |*step, original| {
            if (step.kind != .value or step.function >= p.functions.len) continue;
            const f = p.functions[step.function];
            if (step.pc >= f.body.end - f.body.start) continue;
            const entry = p.function_nodes[f.body.start + step.pc];
            if (entry.input != .operation or entry.node.kind != .native_call or p.natives[entry.node.kind.native_call.native].effect != .draw) continue;
            draws += 1;
            for ([_]i64{ 1, -1, 1000 }) |change| {
                switch (step.value) {
                    .integer => |*value| value.* +%= change,
                    .floating => |*value| value.* = if (change == 1000) 7.5 else value.* / 2 + 0.001,
                    else => unreachable,
                }
                forged = x;
                forged.call_steps = steps;
                try expectRefused(reporting.validate(forged, false, .{}));
                step.* = original;
            }
        }
        const values = try allocator.dupe(types.Value, x.values);
        defer allocator.free(values);
        for (p.nodes, 0..) |node, at| {
            if (!x.active(at) or node.kind != .native_call or p.natives[node.kind.native_call.native].effect != .draw) continue;
            draws += 1;
            switch (values[at]) {
                .integer => |*value| value.* +%= 1,
                .floating => |*value| value.* = value.* / 2 + 0.001,
                else => unreachable,
            }
            forged = x;
            forged.values = values;
            try expectRefused(reporting.validate(forged, false, .{}));
            values[at] = x.values[at];
        }
        try std.testing.expect((draws == 0) == (record.draws == 0));
        // The text of an action is the operand of its call: another string there is refused.
        // (The text of an action that was discarded is seen by no one, and is not compared.)
        if (record.discarded == 0) for (p.nodes, 0..) |node, at| {
            if (!x.active(at) or node.kind != .native_call or p.natives[node.kind.native_call.native].effect != .output) continue;
            const operand = node.kind.native_call.args[0];
            const text = x.values[operand].string;
            if (text.len < 2) continue;
            values[operand] = .{ .string = text[0 .. text.len - 1] };
            forged = x;
            forged.values = values;
            try expectRefused(reporting.validate(forged, false, .{}));
            values[operand] = x.values[operand];
        };
        // Honest again.
        _ = try reporting.validate(x, false, .{});
    }
}

test "a run that stores no steps commits the same effects, and its replayed report checks them" {
    const bench = try Bench.create();
    defer bench.destroy();
    const allocator = std.testing.allocator;
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const replayed_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(replayed_text);
    const shown = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(shown);
    for (sources) |source| for ([_]u64{ effects.default_seed, 0xfeed }) |seed| {
        bench.seed(seed);
        defer bench.seed(effects.default_seed);
        const p = try bench.w.h.compile(source);
        bench.configure(.full, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const stored = (try bench.both(p)).actual;
        var out: std.Io.Writer = .fixed(stored_text);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const stored_end = out.end;
        const visible = bench.w.actual.visible(bench.w.shown);
        @memcpy(shown[0..visible.len], visible);
        const whole = stored.effects;
        for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
            bench.configure(.digest, window, types.ControlStorage.default_reclaim_floor);
            const runs = try bench.both(p);
            const x = runs.actual;
            // Nothing is kept, and the world saw the same lines in the same order.
            try std.testing.expectEqual(@as(usize, 0), x.effects.entries.len + x.effects.bytes.len);
            try std.testing.expect(x.effects.output.eql(whole.output));
            try std.testing.expectEqual(whole.draws, x.effects.draws);
            try std.testing.expectEqual(whole.discarded, x.effects.discarded);
            try std.testing.expectEqual(seed, x.effects.seed);
            try std.testing.expectEqualStrings(shown[0..visible.len], bench.w.actual.visible(bench.w.shown));
            // The report of the second run's steps is the report of the stored ones.
            out = .fixed(replayed_text);
            _ = try reporting.writeReplayed(&out, x, bench.producer(p), false, .{});
            try trace_report.writeReplayed(&out, x, bench.producer(p), "test.forb", .{});
            try std.testing.expectEqualStrings(stored_text[0..stored_end], out.buffered());
            _ = try reporting.validateReplayed(runs.reference, bench.producer(p), false, .{});
            if (!types.cold(p)) continue;
            // Every part of the record is checked against the second run.
            var forged = x;
            forged.effects.draws += 1;
            try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            forged = x;
            forged.effects.discarded += 1;
            try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            forged = x;
            forged.effects.output.count += 1;
            try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            forged = x;
            forged.effects.output.bytes += 1;
            try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            forged = x;
            forged.effects.output.digest ^= 1;
            try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            // A run that kept nothing cannot be given a list of what it showed.
            forged = x;
            forged.effects.entries = whole.entries;
            forged.effects.bytes = whole.bytes;
            if (whole.entries.len != 0) try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            if (whole.draws != 0) {
                // A second run that draws from another stream is not this run.
                bench.again.control.effects.seed = seed + 1;
                try expectRefused(reporting.validateReplayed(x, bench.producer(p), false, .{}));
                // Nor is the record's seed free: the replay reads the stream it names.
                forged = x;
                forged.effects.seed = seed + 1;
                try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
                bench.again.control.effects.seed = seed;
                try expectRefused(reporting.validateReplayed(forged, bench.producer(p), false, .{}));
            }
            _ = try reporting.validateReplayed(x, bench.producer(p), false, .{});
        }
        // A run that records nothing still acts on the world alike.
        bench.configure(.off, 5, types.ControlStorage.default_reclaim_floor);
        const silent = try bench.both(p);
        try std.testing.expect(silent.actual.effects.output.eql(whole.output));
        try std.testing.expectEqualStrings(shown[0..visible.len], bench.w.actual.visible(bench.w.shown));
    };
}

test "reclamation moves strings and members under pending output without touching it" {
    try @import("profile.zig").requireBootstrap();
    const bench = try Bench.create();
    defer bench.destroy();
    // Each visit builds two strings and an array, prints one string and drops everything.
    // In the second half the whole loop runs inside a region, so every line waits in the log
    // while the frames that built its text are reclaimed again and again.
    const source =
        \\Step(S:i64)<transacts>:i64=Block{Pad:="{S}{S}{S}{S}{S}{S}{S}{S}";T:="visit {S} "+Pad;Xs:=array{S,S+1,S+2};Print(T);S+Xs.Length-2}
        \\A:i64=Iterate(Step,150,0)
        \\B:i64=Attempt(Block{X:=Iterate(Step,150,1000);Require[X>0];X},-1)
        \\C:i64=Attempt(Block{X:=Iterate(Step,150,5000);Require[X<0];X},-1)
        \\D:=Print("end")
    ;
    const p = try bench.w.h.compile(source);
    const allocator = std.testing.allocator;
    const expected = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(expected);
    var lines: std.Io.Writer = .fixed(expected);
    for ([_]i64{ 0, 1000 }) |base| for (0..150) |visit| {
        const s = base + @as(i64, @intCast(visit));
        try lines.print("visit {d} {d}{d}{d}{d}{d}{d}{d}{d}\n", .{ s, s, s, s, s, s, s, s, s });
    };
    try lines.writeAll("end\n");
    for ([_]u32{ 4, 64, types.ControlStorage.default_reclaim_floor }) |floor| for ([_]types.TraceMode{ .digest, .off }) |trace| {
        bench.configure(trace, 16, floor);
        const runs = try bench.both(p);
        try std.testing.expectEqualStrings(lines.buffered(), bench.w.actual.visible(bench.w.shown));
        try std.testing.expectEqual(@as(u64, 301), runs.actual.effects.output.count);
        try std.testing.expectEqual(@as(u64, 150), runs.actual.effects.discarded);
        // The run did reclaim, strings included, and far more text went by than a pool holds.
        if (floor != types.ControlStorage.default_reclaim_floor) {
            try std.testing.expect(runs.actual.reclaims > 20);
            try std.testing.expect(bench.w.h.runtime.machine.control.reclaimed_bytes > 2 * 1024);
        }
        try std.testing.expectEqual(@as(usize, 0), runs.actual.effects.entries.len);
        if (trace == .digest) {
            _ = try reporting.validateReplayed(runs.actual, bench.producer(p), false, .{ .work = 16 * 1024 * 1024 });
            _ = try reporting.validateReplayed(runs.reference, bench.producer(p), false, .{ .work = 16 * 1024 * 1024 });
        }
    };
}

/// A random program and what it must print: statements nest in `Attempt` bodies that commit
/// or fail, at the root and in function frames. The model is the plain rule: a failed body's
/// lines are taken out again, and every draw advances the stream whatever became of it.
const Generator = struct {
    r: std.Random,
    source: *std.Io.Writer,
    lines: *std.Io.Writer,
    stream: effects.Stream = .{},
    line_count: u64 = 0,
    discarded: u64 = 0,
    names: u32 = 0,
    budget: u32 = 0,
    fails: u32 = 0,
    nested: u32 = 0,

    const prelude =
        \\Say(N:i64)<transacts>:i64=Block{Print("say {N}");N}
        \\Risky(N:i64)<transacts><decides>:i64=Block{Print("risky {N}");Require[N>0];N}
        \\Try(N:i64)<transacts>:i64=Attempt(Block{Print("try {N}");Risky[N]},Block{Print("caught {N}");0-1})
        \\
    ;

    fn line(self: *Generator, comptime format: []const u8, arguments: anytype) !void {
        try self.lines.print(format ++ "\n", arguments);
        self.line_count += 1;
    }
    fn name(self: *Generator) u32 {
        self.names += 1;
        return self.names;
    }
    const Mark = struct { end: usize, count: u64 };
    fn mark(self: *const Generator) Mark {
        return .{ .end = self.lines.end, .count = self.line_count };
    }
    fn rollback(self: *Generator, to: Mark) void {
        self.discarded += self.line_count - to.count;
        self.line_count = to.count;
        self.lines.end = to.end;
    }

    /// Statements of a block, each ending in a semicolon.
    fn statements(self: *Generator, depth: u32) anyerror!void {
        const count = self.r.uintLessThan(u32, 5);
        for (0..count) |_| {
            if (self.budget == 0) return;
            self.budget -= 1;
            try self.statement(depth);
            try self.source.writeByte(';');
        }
    }

    fn statement(self: *Generator, depth: u32) anyerror!void {
        const n = self.name();
        switch (self.r.uintLessThan(u8, if (depth < 4) 12 else 8)) {
            0, 1 => {
                try self.source.print("Print(\"p{d}\")", .{n});
                try self.line("p{d}", .{n});
            },
            2 => {
                try self.source.print("Print(\"d{d}={{GetRandomInt(0,9)}}\")", .{n});
                try self.line("d{d}={d}", .{ n, self.stream.integer(0, 9).? });
            },
            3 => {
                try self.source.writeAll("GetRandomInt(5,500)");
                _ = self.stream.integer(5, 500).?;
            },
            4 => {
                try self.source.writeAll("Shuffle(array{1,2,3})");
                _ = self.stream.next();
            },
            5 => {
                try self.source.print("Say({d})", .{n});
                try self.line("say {d}", .{n});
            },
            6, 7 => {
                // A function with a region of its own, which fails for a number below one.
                const value: i64 = if (self.r.boolean()) @intCast(n) else 0;
                try self.source.print("Try({d})", .{value});
                const before = self.mark();
                try self.line("try {d}", .{value});
                try self.line("risky {d}", .{value});
                if (value <= 0) {
                    self.rollback(before);
                    self.fails += 1;
                    try self.line("caught {d}", .{value});
                }
            },
            else => {
                // `Attempt(body, alternative)`: the alternative runs when the body failed.
                self.nested += 1;
                try self.source.print("T{d}:i64=Attempt(Block{{", .{n});
                const before = self.mark();
                try self.statements(depth + 1);
                const ending = self.r.uintLessThan(u8, 5);
                const fails = ending < 2;
                if (ending == 0) {
                    try self.source.writeAll("Fail[\"f\"];");
                } else if (ending == 1) {
                    // The failure of a function called last, after its own line.
                    try self.source.writeAll("Risky[0];");
                    try self.line("risky 0", .{});
                } else if (ending == 2) {
                    try self.source.print("Risky[{d}];", .{n});
                    try self.line("risky {d}", .{n});
                }
                try self.source.writeAll("0},Block{");
                if (fails) {
                    self.rollback(before);
                    self.fails += 1;
                    try self.statements(depth + 1);
                }
                try self.source.writeAll("0})");
            },
        }
    }

    /// A whole program: root bindings that are blocks, or calls of functions holding one.
    fn program(self: *Generator) !void {
        try self.source.writeAll(prelude);
        const roots = 1 + self.r.uintLessThan(u32, 4);
        for (0..roots) |_| {
            const n = self.name();
            self.budget = 10;
            if (self.r.boolean()) {
                try self.source.print("R{d}:i64=Block{{", .{n});
                try self.statements(1);
                try self.source.writeAll("0}\n");
            } else {
                try self.source.print("M{d}()<transacts>:i64=Block{{", .{n});
                try self.statements(1);
                try self.source.print("0}}\nR{d}:i64=M{d}()\n", .{ n, n });
            }
        }
    }
};

test "an action at the root after a call that reclaimed is read when the second run has rebuilt its text" {
    // Found by the random programs below: the replay of a run without stored steps used to
    // reach a root `Print` before the second run had rebuilt its text over the bytes the call
    // before it had freed, and folded the stale bytes. An effect at the root now leaves a step
    // the replay waits for.
    const bench = try Bench.create();
    defer bench.destroy();
    const source =
        \\Risky(N:i64)<transacts><decides>:i64=Block{Print("risky {N}");Require[N>0];N}
        \\Try(N:i64)<transacts>:i64=Attempt(Block{Print("try {N}");Risky[N]},Block{Print("caught {N}");0-1})
        \\A:i64=Block{Try(0);Print("after={GetRandomInt(0,9)}");Try(0);Print("again={GetRandomInt(10,99)}");0}
        \\B:=Print("end")
    ;
    const p = try bench.w.h.compile(source);
    bench.configure(.full, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
    const stored = (try bench.both(p)).actual;
    // One root step per effect at the root, in order, and none for anything else there.
    var roots: usize = 0;
    for (stored.call_steps) |step| if (step.kind == .root) {
        try std.testing.expect(p.nodes[step.pc].kind == .native_call and step.function == 0);
        roots += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), roots);
    const visible = try std.testing.allocator.dupe(u8, bench.w.actual.visible(bench.w.shown));
    defer std.testing.allocator.free(visible);
    for ([_]u32{ 0, 1, 8 }) |floor| for ([_]u32{ 1, 2, 3, 5 }) |window| {
        bench.configure(.digest, window, floor);
        const runs = try bench.both(p);
        try std.testing.expectEqualStrings(visible, bench.w.actual.visible(bench.w.shown));
        _ = try reporting.validateReplayed(runs.actual, bench.producer(p), false, .{});
        _ = try reporting.validateReplayed(runs.reference, bench.producer(p), false, .{});
    };
}

test "three hundred random programs print what a model of regions prints, in every trace mode" {
    const bench = try Bench.create();
    defer bench.destroy();
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(source);
    const lines = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(lines);
    var random = std.Random.DefaultPrng.init(0x0079e11);
    var fails: u32 = 0;
    var nested: u32 = 0;
    var discarded: u64 = 0;
    var drawn: u64 = 0;
    for (0..300) |round| {
        var text: std.Io.Writer = .fixed(source);
        var expected: std.Io.Writer = .fixed(lines);
        var generator: Generator = .{ .r = random.random(), .source = &text, .lines = &expected };
        try generator.program();
        bench.configure(.full, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const x = bench.w.expect(text.buffered(), expected.buffered()) catch |err| {
            std.debug.print("round {d}:\n{s}\n", .{ round, text.buffered() });
            return err;
        };
        try std.testing.expectEqual(generator.stream.position, x.effects.draws);
        try std.testing.expectEqual(generator.discarded, x.effects.discarded);
        try std.testing.expectEqual(generator.line_count, x.effects.output.count);
        fails += generator.fails;
        nested += generator.nested;
        discarded += generator.discarded;
        drawn += generator.stream.position;
        if (round % 3 != 0) continue;
        // The same program without stored steps, replayed from a second run.
        const p = try bench.w.h.compile(text.buffered());
        bench.configure(.digest, 1 + @as(u32, @intCast(round % 7)), 8);
        const runs = try bench.both(p);
        try std.testing.expectEqualStrings(expected.buffered(), bench.w.actual.visible(bench.w.shown));
        try std.testing.expectEqual(generator.stream.position, runs.actual.effects.draws);
        try std.testing.expectEqual(generator.discarded, runs.actual.effects.discarded);
        _ = reporting.validateReplayed(runs.actual, bench.producer(p), false, .{}) catch |err| {
            std.debug.print("round {d}, without stored steps:\n{s}\n", .{ round, text.buffered() });
            return err;
        };
    }
    // The programs nested regions, failed many of them and drew through the failures.
    try std.testing.expect(nested >= 300 and fails >= 200 and discarded >= 300 and drawn >= 300);
}
