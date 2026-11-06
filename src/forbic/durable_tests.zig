//! The durable journal on both machines (RFC-0086, P2.4). Each machine is given a journal of its
//! own on a disk in memory, and a world of its own that answers alike; both must write the same
//! journal, byte for byte, in every trace mode, and stop at the same node with the same
//! diagnostic when a disk operation fails, whichever it is. What a disk keeps is always a whole
//! number of commit points (J4), and the inputs are in it before the guest saw them (J2).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const durable = @import("durable.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;

const grants = [_]effects.Grant{
    .{ .kind = .reader, .name = "config" },
    .{ .kind = .writer, .name = "log" },
};
const config_lines = [_][]const u8{ "alpha", "beta", "gamma" };

/// One machine's end of the world: its script, its disk and its journal.
const Side = struct {
    script: effects.Script = .{ .clocks = &.{ 100.0, 90.0 }, .streams = &.{&config_lines} },
    storage: [64 * 1024]u8 = undefined,
    buffer: [8 * 1024]u8 = undefined,
    memory: durable.Memory = undefined,
    journal: durable.Journal = undefined,

    fn fresh(self: *Side, control: *types.ControlStorage) !void {
        self.script.rewind();
        self.memory = .{ .bytes = &self.storage };
        self.journal = .init(self.memory.disk(), &self.buffer);
        var header: [256]u8 = undefined;
        try self.journal.start(try durable.encodeHeader(.{ .toolchain = "test", .profile = "bootstrap", .program = @splat(0), .seed = effects.default_seed, .tick_rate = 60, .grants = &.{} }, &header));
        control.effects.sink = self.journal.sink();
        control.effects.inputs.source = self.script.source();
        control.effects.inputs.journal = self.journal.inputJournal();
        control.effects.inputs.grants = &grants;
    }
    fn detach(control: *types.ControlStorage) void {
        control.effects.sink = null;
        control.effects.inputs.source = null;
        control.effects.inputs.journal = null;
        control.effects.inputs.grants = &.{};
        control.trace = .full;
    }
};

const Bench = struct {
    h: *harness.Harness,
    sides: *[2]Side,

    fn create() !Bench {
        const h = try harness.create();
        errdefer scratch.release(h);
        const sides = try std.testing.allocator.create([2]Side);
        sides.* = .{ .{}, .{} };
        return .{ .h = h, .sides = sides };
    }
    fn destroy(self: Bench) void {
        Side.detach(&self.h.control);
        Side.detach(&self.h.runtime.machine.control);
        std.testing.allocator.destroy(self.sides);
        scratch.release(self.h);
    }
    fn controls(self: Bench) [2]*types.ControlStorage {
        return .{ &self.h.control, &self.h.runtime.machine.control };
    }
    /// Both machines, each on a fresh journal and world, in `mode`.
    fn run(self: Bench, p: types.Program, mode: types.TraceMode) ![2]evaluator.Result {
        for (self.controls(), self.sides) |control, *side| {
            try side.fresh(control);
            control.trace = mode;
        }
        if (mode == .full) {
            const actual = try self.h.run(p, fuel);
            // The harness ran the reference first and compared the two.
            return .{ actual, actual };
        }
        const h = self.h;
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const actual = h.runtime.evaluate(p, fuel);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .failed) try std.testing.expectEqualDeep(reference.failed, actual.failed);
        return .{ reference, actual };
    }
    /// Ends both journals as the tool does, and requires them equal.
    fn finish(self: Bench, result: evaluator.Result) !void {
        const end: durable.End = if (result == .ok) .{ .outcome = .completed } else .{ .outcome = .fatal, .code = @tagName(result.failed.code), .start = result.failed.span.start, .end = result.failed.span.end };
        for (self.sides) |*side| side.journal.finish(end) catch {};
        try self.same();
    }
    fn same(self: Bench) !void {
        try std.testing.expectEqualSlices(u8, self.sides[0].memory.contents(), self.sides[1].memory.contents());
        try std.testing.expectEqual(self.sides[0].memory.synced, self.sides[1].memory.synced);
    }
};

/// The kinds of a journal's durable prefix, as letters: h, i, a, s, e.
fn kinds(bytes: []const u8, out: []u8) ![]const u8 {
    var image: durable.Image = .{ .bytes = bytes };
    var buffer: [8 * 1024]u8 = undefined;
    var prefix = try durable.Prefix.init(image.disk(), &buffer);
    var at: usize = 0;
    while (try prefix.next()) |record| {
        out[at] = "hiase"[@backingInt(record.item.kind) - 1];
        at += 1;
    }
    return out[0..at];
}

/// The `actions` of each seal of a journal, in order: its commit points.
fn seals(bytes: []const u8, out: []u64) ![]const u64 {
    var image: durable.Image = .{ .bytes = bytes };
    var buffer: [8 * 1024]u8 = undefined;
    var prefix = try durable.Prefix.init(image.disk(), &buffer);
    var at: usize = 0;
    while (try prefix.next()) |record| if (record.decoded == .seal) {
        out[at] = record.decoded.seal.actions;
        at += 1;
    };
    return out[0..at];
}

const program_source =
    \\Line(R:reader)<transacts>:string = Attempt(R.ReadLine[], "<end>")
    \\Body(W:writer, R:reader)<transacts>:i64 = Block{ W.WriteLine("first {Line(R)}"); Print("shown"); X := Attempt(Block{ W.WriteLine("inner"); Require[false]; 1 }, 2); W.WriteLine("second {X}"); X }
    \\Early(W:writer)<transacts>:i64 = Attempt(Block{ W.WriteLine("early"); Return(5) }, 6)
    \\Stamp:float = GetSecondsSinceEpoch()
    \\Value:i64 = Attempt(Block{ W := OpenWriter["log"]; R := OpenReader["config"]; Body(W, R) }, 0)
    \\Spent:string = Attempt(Block{ R := OpenReader["config"]; L := R.ReadLine[]; Require[false]; L }, "-")
    \\Out:tuple() = Print("root")
    \\Exit:i64 = Attempt(Block{ W := OpenWriter["log"]; Early(W) }, 0)
    \\Later(W:float)<transacts><suspends>:float = Block{ Sleep(W); Print("late {GetSecondsSinceEpoch()}"); GetSecondsSinceEpoch() }
    \\Task:task(float) = Spawn{ Later(1.0) }
;

test "both machines write one journal, byte for byte, in every trace mode, its inputs ahead of what they decide" {
    const b = try Bench.create();
    defer b.destroy();
    const p = try b.h.compile(program_source);
    var first: [64 * 1024]u8 = undefined;
    var first_len: usize = 0;
    for ([_]types.TraceMode{ .full, .digest, .off }) |mode| {
        const results = try b.run(p, mode);
        try std.testing.expect(results[0] == .ok);
        try b.finish(results[0]);
        const bytes = b.sides[0].memory.contents();
        // Every mode writes the same journal: the trace mode is the report's, not the world's.
        if (mode == .full) {
            @memcpy(first[0..bytes.len], bytes);
            first_len = bytes.len;
        } else try std.testing.expectEqualSlices(u8, first[0..first_len], bytes);
    }
    var letters: [64]u8 = undefined;
    // The clock, a region of a line and three actions sealed once, a line spent in a region that
    // failed, `Print` at the root, a region left by `Return`, and the task at tick 60: the clock
    // again and its line.
    try std.testing.expectEqualStrings("hiiaaasiasasiase", try kinds(first[0..first_len], &letters));
    var points: [16]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{ 3, 4, 5, 6 }, try seals(first[0..first_len], &points));
}

test "a disk operation that fails, at every operation in turn, stops both machines at one node, and the disk keeps whole commit points" {
    const b = try Bench.create();
    defer b.destroy();
    const p = try b.h.compile(program_source);
    const whole = try b.run(p, .full);
    try std.testing.expect(whole[0] == .ok);
    try b.finish(whole[0]);
    const appends = b.sides[0].memory.appends;
    const syncs = b.sides[0].memory.syncs;
    var points_storage: [16]u64 = undefined;
    var whole_bytes: [64 * 1024]u8 = undefined;
    const whole_len = b.sides[0].memory.len;
    @memcpy(whole_bytes[0..whole_len], b.sides[0].memory.contents());
    const points = try seals(whole_bytes[0..whole_len], &points_storage);
    var stopped: [2]u32 = @splat(0);
    for ([_]bool{ true, false }) |appending| {
        const operations = if (appending) appends else syncs;
        // The header's operations and the end's are the host's: they fail before or after the run.
        for (1..operations - 1) |failing| {
            for (b.controls(), b.sides) |control, *side| {
                try side.fresh(control);
                if (appending) side.memory.fail_append = failing else side.memory.fail_sync = failing;
                control.trace = .full;
            }
            const result = try b.h.run(p, fuel);
            errdefer std.debug.print("failing {s} {d}\n", .{ if (appending) "append" else "sync", failing });
            try std.testing.expect(result == .failed);
            const code = result.failed.code;
            const at = p.source[result.failed.span.start..result.failed.span.end];
            if (code == .input_failed) {
                try std.testing.expect(std.mem.eql(u8, at, "GetSecondsSinceEpoch") or std.mem.eql(u8, at, "ReadLine"));
                stopped[0] += 1;
            } else {
                try std.testing.expectEqual(types.Diagnostic.Code.effect_commit_failed, code);
                stopped[1] += 1;
            }
            for (b.sides) |*side| {
                try std.testing.expect(side.journal.failed);
                try std.testing.expectError(error.DiskFailed, side.journal.finish(.{ .outcome = .fatal, .code = @tagName(code) }));
            }
            try b.same();
            // What each disk holds, synced or not, ends at a commit point of the whole run, and
            // the whole run's journal begins with it.
            for ([_][]const u8{ b.sides[0].memory.bytes[0..b.sides[0].memory.synced], b.sides[0].memory.contents() }) |bytes| {
                var image: durable.Image = .{ .bytes = bytes };
                var buffer: [8 * 1024]u8 = undefined;
                const found = try durable.scan(image.disk(), &buffer);
                try std.testing.expect(found.has_header and found.end == null);
                try std.testing.expect(found.actions == 0 or std.mem.indexOfScalar(u64, points, found.actions) != null);
                try std.testing.expectEqualSlices(u8, whole_bytes[0..found.cut], bytes[0..found.cut]);
            }
        }
    }
    // Both kinds of failure were met.
    try std.testing.expect(stopped[0] != 0 and stopped[1] != 0);
}

test "a quota that a prepare would pass ends both machines at the call, and the journal still takes its end" {
    const b = try Bench.create();
    defer b.destroy();
    const p = try b.h.compile("Value:i64 = Attempt(Block{ W := OpenWriter[\"log\"]; W.WriteLine(\"one\"); W.WriteLine(\"two\"); 1 }, 0)\nAfter:tuple() = Print(\"three\")");
    for (b.controls(), b.sides) |control, *side| {
        try side.fresh(control);
        side.journal.quota = side.journal.offset + durable.actionRecordBytes(3) + durable.seal_record_bytes + durable.end_record_bytes;
    }
    const result = try b.h.run(p, fuel);
    try std.testing.expectEqual(types.Diagnostic.Code.effect_prepare_failed, result.failed.code);
    try std.testing.expectEqualStrings("WriteLine", p.source[result.failed.span.start..result.failed.span.end]);
    try b.finish(result);
    var letters: [16]u8 = undefined;
    // The region's first line was aborted with it: nothing was committed.
    try std.testing.expectEqualStrings("he", try kinds(b.sides[0].memory.contents(), &letters));
}

// ---- Recovery (RFC-0086, P2.5) ---------------------------------------------------------------

/// Each machine's side resumed from `image`, a journal a crash left (R1, R4): its disk holds the
/// image, cut at its durable prefix; its sealed inputs are its log's prefix; its world reads on
/// past what was sealed (R6); its journal is in verify mode.
fn resumeSides(b: Bench, image: []const u8, sealed: *[2]durable.SealedInputs, mode: types.TraceMode) !void {
    for (b.controls(), b.sides, sealed) |control, *side, *inputs| {
        side.script.rewind();
        side.memory = .{ .bytes = &side.storage };
        @memcpy(side.storage[0..image.len], image);
        side.memory.len = image.len;
        side.memory.synced = image.len;
        side.journal = .init(side.memory.disk(), &side.buffer);
        const found = try durable.scan(side.memory.disk(), &side.buffer);
        try std.testing.expect(found.has_header and !found.finished());
        try durable.cutAt(side.memory.disk(), found);
        const record = try inputs.load(side.memory.disk(), &side.buffer);
        for (record.entries) |entry| switch (entry.kind) {
            .clock => side.script.clock_reads += 1,
            .line => if (entry.status == .value) {
                side.script.cursors[entry.request] += 1;
            },
            .load => {},
        };
        side.journal.resumeAt(found);
        control.effects.sink = side.journal.sink();
        control.effects.inputs.source = side.script.source();
        control.effects.inputs.journal = side.journal.inputJournal();
        control.effects.inputs.grants = &grants;
        control.effects.inputs.prefix = record;
        control.trace = mode;
    }
}

fn runBoth(b: Bench, p: types.Program) ![2]evaluator.Result {
    const h = b.h;
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(p, fuel);
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    if (reference == .failed) try std.testing.expectEqualDeep(reference.failed, actual.failed);
    for (b.controls()) |control| control.effects.inputs.prefix = .{};
    return .{ reference, actual };
}

test "both machines resume a journal cut at each of its seals, torn after it, in every trace mode, to the journal the uninterrupted run wrote" {
    const b = try Bench.create();
    defer b.destroy();
    const sealed = try scratch.storage([2]durable.SealedInputs);
    defer scratch.release(sealed);
    const p = try b.h.compile(program_source);
    const whole = try b.run(p, .full);
    try std.testing.expect(whole[0] == .ok);
    try b.finish(whole[0]);
    var whole_bytes: [64 * 1024]u8 = undefined;
    const whole_len = b.sides[0].memory.len;
    @memcpy(whole_bytes[0..whole_len], b.sides[0].memory.contents());
    // Where the header and each seal end.
    var ends: [16]u64 = undefined;
    var count: usize = 0;
    {
        var image: durable.Image = .{ .bytes = whole_bytes[0..whole_len] };
        var buffer: [8 * 1024]u8 = undefined;
        var prefix = try durable.Prefix.init(image.disk(), &buffer);
        while (try prefix.next()) |record| if (record.decoded == .header or record.decoded == .seal) {
            ends[count] = record.item.end;
            count += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    var image_bytes: [64 * 1024]u8 = undefined;
    for (ends[0..count]) |at| for ([_]types.TraceMode{ .full, .digest, .off }) |mode| {
        // The crash kept the cut and a torn piece of the next record.
        const kept = @min(at + 11, whole_len);
        @memcpy(image_bytes[0..kept], whole_bytes[0..kept]);
        try resumeSides(b, image_bytes[0..kept], sealed, mode);
        const results = try runBoth(b, p);
        try std.testing.expect(results[0] == .ok);
        for (b.sides) |side| try std.testing.expect(!side.journal.diverged and !side.journal.verifying());
        try b.finish(results[0]);
        try std.testing.expectEqualSlices(u8, whole_bytes[0..whole_len], b.sides[0].memory.contents());
    };
}

test "a resumed program that commits another action diverges on both machines at one node, and one that asks for another input too" {
    const b = try Bench.create();
    defer b.destroy();
    const sealed = try scratch.storage([2]durable.SealedInputs);
    defer scratch.release(sealed);
    var p = try b.h.compile(program_source);
    const whole = try b.run(p, .full);
    try b.finish(whole[0]);
    var whole_bytes: [64 * 1024]u8 = undefined;
    const whole_len = b.sides[0].memory.len;
    @memcpy(whole_bytes[0..whole_len], b.sides[0].memory.contents());
    var image: durable.Image = .{ .bytes = whole_bytes[0..whole_len] };
    var buffer: [8 * 1024]u8 = undefined;
    var prefix = try durable.Prefix.init(image.disk(), &buffer);
    // The cut after the second seal, which holds `shown` and `root`.
    var second: u64 = 0;
    var seen: usize = 0;
    while (try prefix.next()) |record| if (record.decoded == .seal) {
        seen += 1;
        if (seen == 2) second = record.item.end;
    };
    const Case = struct { from: []const u8, to: []const u8, code: types.Diagnostic.Code, at: []const u8 };
    for ([_]Case{
        // Another text: the commit that compares it is refused (recovery_diverged, at the host).
        .{ .from = "Print(\"shown\")", .to = "Print(\"shewn\")", .code = .effect_commit_failed, .at = "" },
        // Another commit point: the line printed at the root comes before the region's.
        .{ .from = "Stamp:float = GetSecondsSinceEpoch()", .to = "Stamp:float = GetSecondsSinceEpoch()\nFirst:tuple() = Print(\"first\")", .code = .effect_commit_failed, .at = "" },
        // The line asked for before the clock: the prefix holds the clock there (input_diverged).
        .{ .from = "Stamp:float = GetSecondsSinceEpoch()", .to = "Early0:string = Attempt(Block{ R := OpenReader[\"config\"]; R.ReadLine[] }, \"\")\nStamp:float = GetSecondsSinceEpoch()", .code = .input_diverged, .at = "ReadLine" },
    }) |case| {
        var changed: [4096]u8 = undefined;
        const at = std.mem.indexOf(u8, program_source, case.from).?;
        const source = try std.fmt.bufPrint(&changed, "{s}{s}{s}", .{ program_source[0..at], case.to, program_source[at + case.from.len ..] });
        p = try b.h.compile(source);
        try resumeSides(b, whole_bytes[0..second], sealed, .full);
        const results = try runBoth(b, p);
        errdefer std.debug.print("{s}: {any}\n", .{ case.to, results[0] });
        try std.testing.expect(results[0] == .failed);
        try std.testing.expectEqual(case.code, results[0].failed.code);
        // A commit is refused at the node that commits: the region, or the call outside every region.
        if (case.at.len != 0) try std.testing.expectEqualStrings(case.at, source[results[0].failed.span.start..][0..case.at.len]);
        for (b.sides) |*side| {
            // The journal found it (or, for an input, the log did) and was left as it was cut.
            try std.testing.expectEqual(case.code == .effect_commit_failed, side.journal.diverged);
            try std.testing.expectEqualSlices(u8, whole_bytes[0..second], side.memory.contents());
            if (side.journal.diverged) try std.testing.expectError(error.Diverged, side.journal.finish(.{ .outcome = .completed }));
        }
        for (b.controls()) |control| control.effects.inputs.prefix = .{};
    }
}
