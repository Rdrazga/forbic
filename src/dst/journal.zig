//! Actual bounded journal against an independent complete-snapshot model.
const std = @import("std");
const kernel = @import("kernel.zig");
const transaction = @import("forbic").transaction;
const bounds: transaction.Bounds = .{ .cells = 8, .depth = 4, .undo = 32, .pending = 8, .committed = 8 };
const Journal = transaction.Bounded(bounds);
const Operation = union(enum) {
    begin,
    write: struct { cell: u32, value: i64 },
    enqueue: transaction.Intent,
    commit,
    abort,
    acknowledge: usize,
};
// Stable semantic outcomes also avoid relying on backend-specific equality of
// optional error-set values. Both rejection identities and success are checked.
const Outcome = enum {
    ok,
    CellIndex,
    NoTransaction,
    ActiveTransaction,
    DepthLimit,
    UndoLimit,
    IntentLimit,
    OutboxLimit,
    InvalidAcknowledgement,
};
fn outcome(result: transaction.Error!void) Outcome {
    return if (result) |_| .ok else |err| switch (err) {
        error.CellIndex => .CellIndex,
        error.NoTransaction => .NoTransaction,
        error.ActiveTransaction => .ActiveTransaction,
        error.DepthLimit => .DepthLimit,
        error.UndoLimit => .UndoLimit,
        error.IntentLimit => .IntentLimit,
        error.OutboxLimit => .OutboxLimit,
        error.InvalidAcknowledgement => .InvalidAcknowledgement,
    };
}

// Rollback copies complete cell snapshots, rather than replaying production's
// undo records. The write count models only its documented capacity semantics.
const Model = struct {
    const Frame = struct { cells: [bounds.cells]i64, pending: usize, writes: usize };
    cells: [bounds.cells]i64 = @splat(0),
    frames: [bounds.depth]Frame = undefined,
    pending: [bounds.pending]transaction.Intent = undefined,
    outbox: [bounds.committed]transaction.Intent = undefined,
    depth: usize = 0,
    writes: usize = 0,
    pending_count: usize = 0,
    outbox_count: usize = 0,

    fn apply(self: *Model, operation: Operation) transaction.Error!void {
        switch (operation) {
            .begin => {
                if (self.depth == self.frames.len) return error.DepthLimit;
                self.frames[self.depth] = .{ .cells = self.cells, .pending = self.pending_count, .writes = self.writes };
                self.depth += 1;
            },
            .write => |write| {
                if (write.cell >= self.cells.len) return error.CellIndex;
                if (self.depth == 0) return error.NoTransaction;
                if (self.writes == bounds.undo) return error.UndoLimit;
                self.cells[write.cell] = write.value;
                self.writes += 1;
            },
            .enqueue => |intent| {
                if (self.depth == 0) return error.NoTransaction;
                if (self.pending_count == self.pending.len) return error.IntentLimit;
                self.pending[self.pending_count] = intent;
                self.pending_count += 1;
            },
            .commit => {
                if (self.depth == 0) return error.NoTransaction;
                if (self.depth == 1) {
                    if (self.pending_count > self.outbox.len - self.outbox_count) return error.OutboxLimit;
                    for (self.pending[0..self.pending_count]) |intent| {
                        self.outbox[self.outbox_count] = intent;
                        self.outbox_count += 1;
                    }
                    self.pending_count = 0;
                    self.writes = 0;
                }
                self.depth -= 1;
            },
            .abort => {
                if (self.depth == 0) return error.NoTransaction;
                self.depth -= 1;
                const frame = self.frames[self.depth];
                self.cells = frame.cells;
                self.pending_count = frame.pending;
                self.writes = frame.writes;
            },
            .acknowledge => |count| {
                if (self.depth != 0) return error.ActiveTransaction;
                if (count > self.outbox_count) return error.InvalidAcknowledgement;
                self.outbox_count -= count;
                for (0..self.outbox_count) |index| self.outbox[index] = self.outbox[index + count];
            },
        }
    }
};

pub const State = struct {
    journal: Journal = .{},
    model: Model = .{},

    pub fn step(self: *State, c: *kernel.Context) !void {
        if (c.fault(.crash)) try self.cancel(c);
        if (c.fault(.exhaustion) or c.step % 31 == 0) {
            try self.pressure(c, c.rng.below(4));
            return;
        }
        const operation: Operation = switch (c.rng.below(8)) {
            0, 1 => .begin,
            2, 3 => .{ .write = .{ .cell = @intCast(c.rng.below(bounds.cells + 2)), .value = @bitCast(c.rng.next()) } },
            4 => .{ .enqueue = .{ .kind = @truncate(c.rng.next()), .argument = @bitCast(c.rng.next()) } },
            5 => .commit,
            6 => .abort,
            7 => .{ .acknowledge = @intCast(c.rng.below(bounds.committed + 3)) },
            else => unreachable,
        };
        try self.apply(c, operation);
        if (c.fault(.duplicate)) try self.apply(c, operation);
    }

    pub fn finish(self: *State, c: *kernel.Context) !void {
        try self.cancel(c);
        try self.apply(c, .{ .acknowledge = self.model.outbox_count });
        try self.apply(c, .begin);
        try self.apply(c, .{ .write = .{ .cell = bounds.cells - 1, .value = std.math.maxInt(i64) } });
        try self.apply(c, .{ .enqueue = .{ .kind = std.math.maxInt(u32), .argument = std.math.minInt(i64) } });
        try self.apply(c, .commit);
        try c.check(self.journal.depth == 0 and self.journal.committed().len == 1, "journal_recovers_and_publishes");
        try self.apply(c, .{ .acknowledge = 1 });
        try c.check(self.journal.committed().len == 0, "journal_recovery_drains_outbox");
    }

    fn cancel(self: *State, c: *kernel.Context) !void {
        c.record("journal_cancel", self.model.depth, self.model.outbox_count);
        self.journal.abortAll();
        while (self.model.depth > 0) {
            try self.model.apply(.abort);
            c.counters.aborted += 1;
        }
        try self.compare(c);
    }

    fn pressure(self: *State, c: *kernel.Context, kind: u64) !void {
        try self.cancel(c);
        try self.apply(c, .{ .acknowledge = self.model.outbox_count });
        c.record("journal_pressure", kind, 0);
        try self.apply(c, .begin);
        switch (kind) {
            0 => for (0..bounds.depth) |_| try self.apply(c, .begin),
            1 => for (0..bounds.undo + 1) |index| try self.apply(c, .{ .write = .{ .cell = @intCast(index % bounds.cells), .value = @bitCast(c.rng.next()) } }),
            2 => for (0..bounds.pending + 1) |index| try self.apply(c, .{ .enqueue = .{ .kind = @intCast(index), .argument = @bitCast(c.rng.next()) } }),
            3 => {
                for (0..bounds.committed) |index| try self.apply(c, .{ .enqueue = .{ .kind = @intCast(index), .argument = @intCast(index) } });
                try self.apply(c, .commit);
                try self.apply(c, .begin);
                try self.apply(c, .{ .write = .{ .cell = 0, .value = std.math.minInt(i64) } });
                try self.apply(c, .{ .enqueue = .{ .kind = 0, .argument = std.math.maxInt(i64) } });
                try self.apply(c, .commit);
            },
            else => unreachable,
        }
    }

    fn apply(self: *State, c: *kernel.Context, operation: Operation) !void {
        const a: u64 = switch (operation) {
            .write => |write| write.cell,
            .enqueue => |intent| intent.kind,
            .acknowledge => |count| count,
            else => self.model.depth,
        };
        const b: u64 = switch (operation) {
            .write => |write| @bitCast(write.value),
            .enqueue => |intent| @bitCast(intent.argument),
            else => self.model.outbox_count,
        };
        c.record(@tagName(operation), a, b);
        const expected = outcome(self.model.apply(operation));
        const actual = outcome(self.dispatch(operation));
        if (expected != actual) {
            c.record(@tagName(expected), 0, self.model.depth);
            c.record(@tagName(actual), 1, self.journal.depth);
        }
        try c.check(expected == actual, "journal_error_matches_snapshot_model");
        if (actual != .ok) {
            c.reject(@tagName(actual));
        } else switch (operation) {
            .commit => c.counters.committed += 1,
            .abort => c.counters.aborted += 1,
            .acknowledge => |count| c.counters.delivered += count,
            else => {},
        }
        try self.compare(c);
    }

    fn dispatch(self: *State, operation: Operation) transaction.Error!void {
        switch (operation) {
            .begin => try self.journal.begin(),
            .write => |write| try self.journal.write(write.cell, write.value),
            .enqueue => |intent| try self.journal.enqueue(intent),
            .commit => try self.journal.commit(),
            .abort => try self.journal.abort(),
            .acknowledge => |count| try self.journal.acknowledge(count),
        }
    }

    fn compare(self: *const State, c: *kernel.Context) !void {
        try c.check(std.mem.eql(i64, &self.model.cells, &self.journal.cells), "journal_cells_match_snapshot_model");
        try c.check(self.model.depth == self.journal.depth, "journal_depth_matches_snapshot_model");
        try c.check(self.model.writes == self.journal.undo_count, "journal_undo_count_matches_snapshot_model");
        try c.check(self.model.pending_count == self.journal.pending_count, "journal_pending_count_matches_snapshot_model");
        try c.check(self.model.outbox_count == self.journal.committed().len, "journal_outbox_count_matches_snapshot_model");
        for (self.model.pending[0..self.model.pending_count], self.journal.pending[0..self.journal.pending_count]) |expected, actual| {
            try c.check(std.meta.eql(expected, actual), "journal_pending_fifo_matches_snapshot_model");
        }
        for (self.model.outbox[0..self.model.outbox_count], self.journal.committed()) |expected, actual| {
            try c.check(std.meta.eql(expected, actual), "journal_committed_fifo_matches_snapshot_model");
        }
    }
};

test "journal workload exercises seeded pressure and repeats exactly" {
    var first = kernel.Context.init(0x7472616e73616374, .swarm);
    var second = kernel.Context.init(0x7472616e73616374, .swarm);
    var a: State = .{};
    var b: State = .{};
    for (0..1000) |step| {
        first.step = @intCast(step);
        second.step = @intCast(step);
        try a.step(&first);
        try b.step(&second);
    }
    first.heal();
    second.heal();
    try a.finish(&first);
    try b.finish(&second);
    try std.testing.expectEqualDeep(first.counters, second.counters);
    try std.testing.expectEqualSlices(u8, &first.hash(), &second.hash());
    try std.testing.expect(first.counters.rejected > 0 and first.counters.committed > 0 and first.counters.aborted > 0);
}

test "journal oracle detects a corrupted production cell" {
    var context = kernel.Context.init(1, .swarm);
    var state: State = .{};
    state.journal.cells[0] = 1;
    try std.testing.expectError(error.Invariant, state.compare(&context));
    try std.testing.expectEqualStrings("journal_cells_match_snapshot_model", context.failure.?);
}

test "journal outcomes preserve success and every distinct error identity" {
    try std.testing.expectEqual(Outcome.ok, outcome(@as(transaction.Error!void, {})));
    const errors = [_]transaction.Error{
        error.CellIndex,
        error.NoTransaction,
        error.ActiveTransaction,
        error.DepthLimit,
        error.UndoLimit,
        error.IntentLimit,
        error.OutboxLimit,
        error.InvalidAcknowledgement,
    };
    for (errors) |err| {
        const result = outcome(@as(transaction.Error!void, err));
        try std.testing.expect(result != .ok);
        try std.testing.expectEqualStrings(@errorName(err), @tagName(result));
    }
}

// ---- The durable journal (RFC-0086, P2.4) ---------------------------------------------------
//
// A port of the design prototype's journal (RFC-0086, Appendix A) to the real machines: Forbic
// programs with inputs, regions, output and writers, generated with a model of their commit
// points written here from the rules (J2, J3), run on both machines, each journaled on a
// simulated disk of its own whose unsynced tail survives a crash only as a prefix, its last
// record possibly torn. Every disk operation is crashed in turn, and failed in turn. Recovery is
// P2.5's: here what a crash leaves is checked, not resumed (JM2, JM4, and write-ahead).

const forbic = @import("forbic");
const durable = forbic.durable;
const effects = forbic.effects;
const vtypes = forbic.types;

/// A disk whose operations (appends and syncs) can crash or fail at a number chosen by the test.
/// A crash keeps the synced bytes and a prefix of the rest, cut anywhere, its last kept byte
/// flipped one time in three: a torn record. After a crash nothing reaches the disk.
const SimulatedDisk = struct {
    bytes: [32 * 1024]u8 = undefined,
    len: usize = 0,
    synced: usize = 0,
    operations: u64 = 0,
    crash_at: ?u64 = null,
    fail_at: ?u64 = null,
    crashed: bool = false,
    image: [32 * 1024]u8 = undefined,
    image_len: usize = 0,
    /// The synced length at the crash: what a consumer may have been shown came from it.
    synced_at_crash: usize = 0,
    tear: u64 = 0,
    /// P2.5: the synced length before a truncation that is not synced yet.
    untruncated: ?usize = null,

    fn disk(self: *SimulatedDisk) durable.Disk {
        return .{ .context = self, .append = append, .sync = sync, .read = read, .truncate = truncate };
    }
    fn operation(self: *SimulatedDisk) durable.DiskError!void {
        if (self.crashed) return error.DiskFailed;
        const number = self.operations;
        self.operations += 1;
        if (self.crash_at == number) {
            // The tear is a function of the crash point, so both machines' disks tear alike.
            var rng: kernel.Rng = .{ .state = self.tear ^ number *% 0x9e3779b97f4a7c15 };
            // A truncation that was not synced may not have happened (P2.5).
            if (self.untruncated) |old| if (rng.below(2) == 0) {
                self.len = old;
                self.synced = old;
            };
            const kept = self.synced + @as(usize, @intCast(rng.below(self.len - self.synced + 1)));
            @memcpy(self.image[0..kept], self.bytes[0..kept]);
            if (kept > self.synced and rng.below(3) == 0) self.image[kept - 1] ^= 0x5a;
            self.image_len = kept;
            self.synced_at_crash = self.synced;
            self.crashed = true;
            return error.DiskFailed;
        }
        if (self.fail_at == number) return error.DiskFailed;
    }
    fn append(context: *anyopaque, parts: []const []const u8) durable.DiskError!void {
        const self: *SimulatedDisk = @ptrCast(@alignCast(context));
        try self.operation();
        var total: usize = 0;
        for (parts) |part| total += part.len;
        if (total > self.bytes.len - self.len) return error.DiskFailed;
        // What an append writes over is gone for a truncation that is not synced.
        self.untruncated = null;
        for (parts) |part| {
            @memcpy(self.bytes[self.len..][0..part.len], part);
            self.len += part.len;
        }
    }
    fn sync(context: *anyopaque) durable.DiskError!void {
        const self: *SimulatedDisk = @ptrCast(@alignCast(context));
        try self.operation();
        self.synced = self.len;
        self.untruncated = null;
    }
    /// R1's cut. Until the next sync a crash may keep the bytes it dropped, as long as nothing
    /// was appended over them since.
    fn truncate(context: *anyopaque, length: u64) durable.DiskError!void {
        const self: *SimulatedDisk = @ptrCast(@alignCast(context));
        try self.operation();
        if (length >= self.len) return;
        if (self.untruncated == null) self.untruncated = self.synced;
        self.len = @intCast(length);
        self.synced = @min(self.synced, self.len);
    }
    fn read(context: *anyopaque, offset: u64, buffer: []u8) durable.DiskError!usize {
        const self: *SimulatedDisk = @ptrCast(@alignCast(context));
        if (self.crashed) return error.DiskFailed;
        if (offset >= self.len) return 0;
        const count = @min(buffer.len, self.len - offset);
        @memcpy(buffer[0..count], self.bytes[offset..][0..count]);
        return count;
    }
};

/// The actions a consumer was shown, in order.
const Shown = struct {
    count: u32 = 0,
    channels: [256]u32 = undefined,
    fn show(context: *anyopaque, action: effects.Action) bool {
        const self: *Shown = @ptrCast(@alignCast(context));
        if (action.sequence != self.count) return false;
        self.channels[self.count] = action.channel;
        self.count += 1;
        return true;
    }
};

/// What the model says a program does: its committed actions, its commit points (the actions
/// committed after each), its inputs, and the order in which the journal must hold them.
const Plan = struct {
    const Act = struct { channel: u32, text: [24]u8 = undefined, len: u8 = 0 };
    const Input = struct { kind: effects.InputKind, line: ?[]const u8 };
    const Event = enum(u8) { input = 'i', action = 'a', seal = 's' };
    actions: [128]Act = undefined,
    action_count: u32 = 0,
    pending: [128]Act = undefined,
    pending_count: u32 = 0,
    boundaries: [64]u32 = undefined,
    boundary_count: u32 = 0,
    /// The inputs recorded before each commit point closed.
    inputs_at: [64]u32 = undefined,
    inputs: [64]Input = undefined,
    input_count: u32 = 0,
    events: [512]Event = undefined,
    event_count: u32 = 0,
    cursor: usize = 0,
    clocked: bool = false,
    fatal: bool = false,
    names: u32 = 0,

    fn event(self: *Plan, kind: Event) void {
        self.events[self.event_count] = kind;
        self.event_count += 1;
    }
    fn read(self: *Plan) []const u8 {
        const line: ?[]const u8 = if (self.cursor < world_lines.len) world_lines[self.cursor] else null;
        self.cursor += 1;
        self.inputs[self.input_count] = .{ .kind = .line, .line = line };
        self.input_count += 1;
        self.event(.input);
        return line orelse "<e>";
    }
    fn act(self: *Plan, channel: u32, comptime format: []const u8, arguments: anytype) []const u8 {
        var item: Act = .{ .channel = channel };
        item.len = @intCast((std.fmt.bufPrint(&item.text, format, arguments) catch unreachable).len);
        self.pending[self.pending_count] = item;
        self.pending_count += 1;
        return item.text[0..item.len];
    }
    /// The pending actions from `start` on are one commit point.
    fn commit(self: *Plan, start: u32) void {
        if (self.pending_count == start) return;
        for (self.pending[start..self.pending_count]) |item| {
            self.actions[self.action_count] = item;
            self.action_count += 1;
            self.event(.action);
        }
        self.pending_count = start;
        self.boundaries[self.boundary_count] = self.action_count;
        self.inputs_at[self.boundary_count] = self.input_count;
        self.boundary_count += 1;
        self.event(.seal);
    }
};

const world_lines = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5" };
const journal_grants = [_]effects.Grant{ .{ .kind = .reader, .name = "config" }, .{ .kind = .writer, .name = "log" }, .{ .kind = .writer, .name = "audit" }, .{ .kind = .key, .name = "alice" }, .{ .kind = .key, .name = "bob" } };

fn word(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// The body of a region: one to four items, each an action, a line read and an action that
/// shows it, or a region of its own that commits or fails as drawn.
fn regionBody(rng: *kernel.Rng, out: *std.Io.Writer, plan: *Plan, depth: u32) !void {
    const items = 1 + rng.below(4);
    for (0..items) |_| {
        const n = plan.names;
        plan.names += 1;
        switch (rng.below(if (depth < 3) 5 else 4)) {
            0 => try out.print("Print(\"{s}\");", .{plan.act(0, "p{d}", .{n})}),
            1 => try out.print("L.WriteLine(\"{s}\");", .{plan.act(2, "l{d}", .{n})}),
            2 => try out.print("A.WriteLine(\"{s}\");", .{plan.act(3, "a{d}", .{n})}),
            3 => {
                const line = plan.read();
                try out.print("X{d}:=Attempt(R.ReadLine[],\"<e>\");L.WriteLine(\"r{d} {{X{d}}}\");", .{ n, n, n });
                _ = plan.act(2, "r{d} {s}", .{ n, line });
            },
            else => {
                const fails = rng.below(3) == 0;
                const start = plan.pending_count;
                try out.writeAll("Attempt(Block{");
                try regionBody(rng, out, plan, depth + 1);
                try out.print("Require[{s}];0}},0);", .{word(!fails)});
                if (fails) plan.pending_count = start;
            },
        }
    }
}

/// A program of root bindings and its plan.
fn generate(rng: *kernel.Rng, out: *std.Io.Writer, plan: *Plan) !void {
    try out.writeAll("Lo:option(writer)=option{OpenWriter[\"log\"]}\nAo:option(writer)=option{OpenWriter[\"audit\"]}\nRo:option(reader)=option{OpenReader[\"config\"]}\n");
    const statements = 2 + rng.below(8);
    for (0..statements) |k| switch (rng.below(5)) {
        0 => {
            try out.print("S{d}:tuple()=Print(\"{s}\")\n", .{ k, plan.act(0, "s{d}", .{k}) });
            plan.commit(0);
        },
        1, 2 => {
            const fails = rng.below(4) == 0;
            try out.print("S{d}:i64=Attempt(Block{{L:=Lo?;A:=Ao?;R:=Ro?;", .{k});
            try regionBody(rng, out, plan, 1);
            try out.print("Require[{s}];1}},0)\n", .{word(!fails)});
            if (fails) plan.pending_count = 0 else plan.commit(0);
        },
        3 => {
            try out.print("S{d}:string=Attempt(Block{{R:=Ro?;R.ReadLine[]}},\"<e>\")\n", .{k});
            _ = plan.read();
        },
        else => {
            try out.print("S{d}:float=GetSecondsSinceEpoch()\n", .{k});
            // The root runs at tick 0: one reading, recorded once.
            if (!plan.clocked) {
                plan.inputs[plan.input_count] = .{ .kind = .clock, .line = null };
                plan.input_count += 1;
                plan.event(.input);
                plan.clocked = true;
            }
        },
    };
    // P2.5 (JM6): a task that reads the clock at two later ticks, twice at the first, and prints
    // what it finds: one reading per tick, never going back, whatever world answers it.
    const ticking = rng.below(2) == 0;
    if (ticking) try out.writeAll("Tick()<transacts><suspends>:void=Block{Sleep(1.0);A:=GetSecondsSinceEpoch();B:=GetSecondsSinceEpoch();If(A==B,Print(\"same\"),Print(\"moved\"));Sleep(1.0);C:=GetSecondsSinceEpoch();If(C>=A,Print(\"later\"),Print(\"back\"))}\nT:task(void)=Spawn{Tick()}\n");
    if (rng.below(4) == 0) {
        try out.writeAll("Zero:i64=0\nBad:i64=1/Zero\n");
        plan.fatal = true;
    }
    try out.writeAll("Value:i64=1\n");
    // A fatal error at the root ends every task (RFC-0082 Q4): the task's events happen only in
    // a run that completes, after the root's.
    if (ticking and !plan.fatal) for ([_][]const u8{ "same", "later" }) |text| {
        plan.inputs[plan.input_count] = .{ .kind = .clock, .line = null };
        plan.input_count += 1;
        plan.event(.input);
        _ = plan.act(0, "{s}", .{text});
        plan.commit(0);
    };
}

/// P2.5: each machine's sealed inputs, as its recovery serves them.
const Sealed = struct { sides: [2]durable.SealedInputs = undefined };

/// Both machines, each with its world, its disk and its journal.
const Bench = struct {
    pub const parts = .{ "front", "mutant", "runtime", "sealed" };
    front: *forbic.compiler.Workspace,
    /// P2.5 (JM7): the compiler of a program changed from the one `front` compiled.
    mutant: *forbic.compiler.Workspace,
    runtime: *forbic.bytecode.Workspace,
    /// P2.5: the sealed inputs each machine's recovery serves it (R4).
    sealed: *Sealed,
    values: [vtypes.limits.nodes]vtypes.Value = undefined,
    members: [vtypes.limits.aggregate_elements]vtypes.Value = undefined,
    control: vtypes.ControlStorage = .{},
    state: forbic.source_state.ReferenceState = .{},
    frames: forbic.call_frames.ReferenceStorage = .{},
    worlds: [2]effects.Script = undefined,
    /// RFC-0087, P5.5: the entries the persistent cells of a program load.
    store: []const effects.Stored = &.{},
    /// RFC-0087, P5.7: the store a fresh journal's header names, if any.
    header_store: ?durable.StoreRef = null,
    disks: [2]SimulatedDisk = undefined,
    journals: [2]durable.Journal = undefined,
    shown: [2]Shown = undefined,
    buffers: [2][4096]u8 = undefined,
    results: [2]vtypes.Diagnostic = undefined,
    outcomes: [2]bool = undefined,

    fn controls(self: *Bench) [2]*vtypes.ControlStorage {
        return .{ &self.control, &self.runtime.machine.control };
    }
    /// One run of `program` on both machines, each journaled from a fresh disk.
    fn run(self: *Bench, program: vtypes.Program, group: u32, mode: vtypes.TraceMode, crash_at: ?u64, fail_at: ?u64, tear: u64) !void {
        for (self.controls(), 0..) |control, side| {
            self.worlds[side] = .{ .streams = &.{&world_lines}, .store = self.store };
            self.disks[side] = .{ .crash_at = crash_at, .fail_at = fail_at, .tear = tear };
            self.shown[side] = .{};
            self.journals[side] = .init(self.disks[side].disk(), &self.buffers[side]);
            self.journals[side].group = group;
            self.journals[side].consumer = .{ .context = &self.shown[side], .show = Shown.show };
            control.effects.sink = self.journals[side].sink();
            control.effects.inputs.source = self.worlds[side].source();
            control.effects.inputs.journal = self.journals[side].inputJournal();
            control.effects.inputs.grants = &journal_grants;
            control.trace = mode;
        }
        var header: [256]u8 = undefined;
        const payload = try durable.encodeHeader(.{ .toolchain = "dst", .profile = "bootstrap", .program = @splat(0), .seed = effects.default_seed, .tick_rate = 60, .grants = &.{}, .store = self.header_store }, &header);
        var started: [2]bool = undefined;
        for (&self.journals, &started) |*journal, *ok| ok.* = if (journal.start(payload)) |_| true else |_| false;
        const results = [2]forbic.evaluator.Result{
            if (started[0]) forbic.evaluator.evaluateWithRuntimeStorage(program, &self.values, &self.members, &self.control, &self.state, &self.frames, 1 << 20) else .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_ir } },
            if (started[1]) self.runtime.evaluate(program, 1 << 20) else .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_ir } },
        };
        for (results, &self.journals, &self.outcomes, &self.results) |result, *journal, *ok, *diagnostic| {
            ok.* = result == .ok;
            if (result == .failed) diagnostic.* = result.failed;
            if (!journal.started or journal.failed) continue;
            const end: durable.End = if (result == .ok) .{ .outcome = .completed } else .{ .outcome = .fatal, .code = @tagName(result.failed.code), .start = result.failed.span.start, .end = result.failed.span.end };
            journal.finish(end) catch {};
        }
        self.detach();
    }

    fn detach(self: *Bench) void {
        for (self.controls()) |control| {
            control.effects.sink = null;
            control.effects.inputs.source = null;
            control.effects.inputs.journal = null;
            control.effects.inputs.grants = &.{};
            control.effects.inputs.prefix = .{};
            control.trace = .full;
        }
    }

    /// P2.5: how a recovery on the bench began.
    const Begun = enum {
        /// No journal (none, or one without a valid header, R1): the run started afresh.
        fresh,
        /// A finished journal (R2): nothing ran.
        finished,
        /// The journal was cut, and the run resumed it in verify mode (R4).
        resumed,
        /// The cut itself crashed or failed: nothing ran.
        stopped,
    };

    /// A recovery of `image`, the journal a crash left, on both machines, each from a disk of its
    /// own that holds it, against world `world` (0: the first run's, 1 and 2: others that answer
    /// otherwise past what was sealed); with `reference` instead of an image, a fresh run that is
    /// served `reference` first and the world after it (JM1's uninterrupted run).
    fn recover(self: *Bench, program: vtypes.Program, group: u32, image: ?[]const u8, reference: ?effects.InputRecord, world: usize, crash_at: ?u64, tear: u64) !Begun {
        var begun: Begun = .fresh;
        var started: [2]bool = .{ false, false };
        for (self.controls(), 0..) |control, side| {
            self.worlds[side] = .{ .streams = &.{world_streams[world]}, .base = world_bases[world], .store = self.store };
            self.disks[side] = .{ .crash_at = crash_at, .tear = tear };
            self.shown[side] = .{};
            self.journals[side] = .init(self.disks[side].disk(), &self.buffers[side]);
            self.journals[side].group = group;
            self.journals[side].consumer = .{ .context = &self.shown[side], .show = Shown.show };
            control.effects.sink = self.journals[side].sink();
            control.effects.inputs.source = self.worlds[side].source();
            control.effects.inputs.journal = self.journals[side].inputJournal();
            control.effects.inputs.grants = &journal_grants;
            control.trace = .full;
            const disk = &self.disks[side];
            if (image) |bytes| {
                @memcpy(disk.bytes[0..bytes.len], bytes);
                disk.len = bytes.len;
                disk.synced = bytes.len;
                const found = try durable.scan(disk.disk(), &self.buffers[side]);
                if (found.has_header and found.finished()) {
                    begun = .finished;
                    continue;
                }
                if (found.has_header) {
                    durable.cutAt(disk.disk(), found) catch {
                        begun = .stopped;
                        continue;
                    };
                    control.effects.inputs.prefix = try self.sealed.sides[side].load(disk.disk(), &self.buffers[side]);
                    self.journals[side].resumeAt(found);
                    // Nothing sealed is shown again (J9): the consumer is next shown the first
                    // action past the cut.
                    self.shown[side].count = @intCast(found.actions);
                    begun = .resumed;
                    started[side] = true;
                    continue;
                }
                // R1: no journal; the run starts afresh on an empty file.
                disk.len = 0;
                disk.synced = 0;
            }
            var header: [256]u8 = undefined;
            const payload = try durable.encodeHeader(.{ .toolchain = "dst", .profile = "bootstrap", .program = @splat(0), .seed = effects.default_seed, .tick_rate = 60, .grants = &.{}, .store = self.header_store }, &header);
            self.journals[side].start(payload) catch {
                begun = .stopped;
                continue;
            };
            if (reference) |record| {
                // The served inputs head the journal, so that it is one a reader accepts; the
                // run is then served them, and asks the world past them.
                control.effects.inputs.prefix = record;
                const journal = self.journals[side].inputJournal();
                for (record.entries, 0..) |entry, sequence| {
                    if (!journal.append(journal.context, @intCast(sequence), entry, record.bytes[entry.start..entry.end])) return error.Invariant;
                }
                self.journals[side].taken = 0;
            }
            started[side] = true;
        }
        if (begun == .finished or begun == .stopped) {
            self.detach();
            return begun;
        }
        const results = [2]forbic.evaluator.Result{
            if (started[0]) forbic.evaluator.evaluateWithRuntimeStorage(program, &self.values, &self.members, &self.control, &self.state, &self.frames, 1 << 20) else .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_ir } },
            if (started[1]) self.runtime.evaluate(program, 1 << 20) else .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_ir } },
        };
        for (results, &self.journals, &self.outcomes, &self.results) |result, *journal, *ok, *diagnostic| {
            ok.* = result == .ok;
            if (result == .failed) diagnostic.* = result.failed;
            if (!journal.started or journal.failed) continue;
            const end: durable.End = if (result == .ok) .{ .outcome = .completed } else .{ .outcome = .fatal, .code = @tagName(result.failed.code), .start = result.failed.span.start, .end = result.failed.span.end };
            journal.finish(end) catch {};
        }
        self.detach();
        return begun;
    }
};

/// P2.5: the worlds a recovery may meet. Past what was sealed they answer otherwise: other lines,
/// and a clock that is behind the first world's (so I5 must hold the last value) or ahead of it.
const alternative_lines = [_][]const u8{ "d0", "d1", "d2", "d3", "d4", "d5" };
const third_lines = [_][]const u8{ "e0", "e1", "e2", "e3", "e4", "e5" };
const world_streams = [3][]const []const u8{ &world_lines, &alternative_lines, &third_lines };
const world_bases = [3]f64{ 1_700_000_000.0, 1_600_000_000.0, 1_800_000_000.0 };

fn scanBytes(bytes: []const u8, buffer: []u8) !durable.Scan {
    var image: durable.Image = .{ .bytes = bytes };
    return durable.scan(image.disk(), buffer);
}

/// The letters of a journal's kinds, past its header, as the plan's events name them; an end is
/// left out.
fn eventsOf(bytes: []const u8, buffer: []u8, out: []u8) ![]const u8 {
    var image: durable.Image = .{ .bytes = bytes };
    var prefix = try durable.Prefix.init(image.disk(), buffer);
    var at: usize = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .input => {
            out[at] = 'i';
            at += 1;
        },
        .action => {
            out[at] = 'a';
            at += 1;
        },
        .seal => {
            out[at] = 's';
            at += 1;
        },
        else => {},
    };
    return out[0..at];
}

/// The checks of one generated program: the plan against the uninterrupted journal of both
/// machines in every trace mode, then a crash and a failure at every disk operation.
fn checkProgram(c: *kernel.Context, b: *Bench, source: []const u8, plan: *const Plan, recovered: *Recovered) !struct { crashes: u64, cut_points: u64 } {
    const program = switch (b.front.compile(source)) {
        .ok => |p| p,
        .failed => |d| {
            std.debug.print("journal dst compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
            return error.Invariant;
        },
    };
    // P2.5 (JM7): the program with the text of its first literal action changed.
    var mutant_bytes: [8 * 1024]u8 = undefined;
    const mutant = try mutate(b, source, plan, &mutant_bytes);
    var buffer: [4096]u8 = undefined;
    const group: u32 = @intCast(1 + c.rng.below(4));
    var whole: [32 * 1024]u8 = undefined;
    var whole_len: usize = 0;
    var operations: u64 = 0;
    for ([_]vtypes.TraceMode{ .full, .digest, .off }) |mode| {
        try b.run(program, group, mode, null, null, 0);
        try c.check(b.outcomes[0] == !plan.fatal and b.outcomes[1] == !plan.fatal, "journal_dst_runs_end_as_planned");
        if (plan.fatal) try c.check(b.results[0].code == .division_by_zero and std.meta.eql(b.results[0], b.results[1]), "journal_dst_fatal_errors_agree");
        // Both machines, in every trace mode, write one journal.
        try c.check(std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "journal_dst_machines_write_one_journal");
        if (mode == .full) {
            whole_len = b.disks[0].len;
            @memcpy(whole[0..whole_len], b.disks[0].bytes[0..whole_len]);
            operations = b.disks[0].operations;
        } else try c.check(std.mem.eql(u8, whole[0..whole_len], b.disks[0].bytes[0..b.disks[0].len]), "journal_dst_trace_modes_write_one_journal");
    }
    // The journal holds the plan: its inputs before what follows them, each commit point's
    // actions sealed once (J2, J3), and every action shown once, after the end's sync.
    var letters: [512]u8 = undefined;
    const events = try eventsOf(whole[0..whole_len], &buffer, &letters);
    try c.check(std.mem.eql(u8, events, std.mem.sliceAsBytes(plan.events[0..plan.event_count])), "journal_dst_records_follow_the_plan");
    try c.check(b.shown[0].count == plan.action_count and b.shown[1].count == plan.action_count, "journal_dst_every_action_is_shown_once");
    {
        var image: durable.Image = .{ .bytes = whole[0..whole_len] };
        var prefix = try durable.Prefix.init(image.disk(), &buffer);
        var action: u32 = 0;
        var input: u32 = 0;
        while (try prefix.next()) |record| switch (record.decoded) {
            .action => |item| {
                const expected = plan.actions[action];
                try c.check(item.channel == expected.channel and std.mem.eql(u8, item.text, expected.text[0..expected.len]), "journal_dst_actions_match_the_plan");
                action += 1;
            },
            .input => |item| {
                const expected = plan.inputs[input];
                try c.check(item.kind == expected.kind, "journal_dst_input_kinds_match_the_plan");
                if (expected.kind == .line) {
                    if (expected.line) |line| {
                        try c.check(item.status == .value and std.mem.eql(u8, item.bytes, line), "journal_dst_lines_match_the_world");
                    } else try c.check(item.status == .end, "journal_dst_ends_match_the_world");
                }
                input += 1;
            },
            .end => |end| try c.check((end.outcome == .fatal) == plan.fatal, "journal_dst_end_matches_the_plan"),
            else => {},
        };
        try c.check(action == plan.action_count and input == plan.input_count, "journal_dst_journal_is_whole");
    }
    var crashes: u64 = 0;
    var cut_points: u64 = 0;
    for (0..operations) |point| {
        // A crash at the operation: what the disk keeps is cut at a commit point of the whole
        // run, holds what was shown, and is the whole run's journal up to its cut (JM2, JM4).
        const tear = c.rng.next();
        try b.run(program, group, .full, point, null, tear);
        crashes += 1;
        try c.check(b.disks[0].crashed and b.disks[1].crashed, "journal_dst_crash_point_reached");
        try c.check(b.disks[0].image_len == b.disks[1].image_len and std.mem.eql(u8, b.disks[0].image[0..b.disks[0].image_len], b.disks[1].image[0..b.disks[1].image_len]), "journal_dst_machines_crash_alike");
        const image = b.disks[0].image[0..b.disks[0].image_len];
        const found = try scanBytes(image, &buffer);
        try c.check(std.mem.eql(u8, image[0..found.cut], whole[0..found.cut]), "journal_dst_cut_is_a_prefix_of_the_whole_run");
        try c.check(found.end == null or found.cut == whole_len, "journal_dst_an_end_survives_only_whole");
        if (found.actions != 0) {
            const at = std.mem.indexOfScalar(u32, plan.boundaries[0..plan.boundary_count], @intCast(found.actions));
            try c.check(at != null, "journal_dst_cut_ends_at_a_commit_point");
            // Write-ahead: every input read before the sealed commit point is in the cut.
            try c.check(found.inputs >= plan.inputs_at[at.?], "journal_dst_sealed_inputs_were_written_ahead");
            cut_points += 1;
        }
        // What was shown was durable: the synced prefix's actions, which the cut keeps.
        const durable_scan = try scanBytes(b.disks[0].bytes[0..b.disks[0].synced_at_crash], &buffer);
        try c.check(b.shown[0].count == durable_scan.actions and b.shown[0].count <= found.actions and b.shown[1].count == b.shown[0].count, "journal_dst_shown_actions_were_durable_and_kept");
        for (b.shown[0].channels[0..b.shown[0].count], plan.actions[0..b.shown[0].count]) |channel, expected| try c.check(channel == expected.channel, "journal_dst_shown_actions_follow_the_plan");
        // P2.5: what the crash left is recovered (R1 to R7, JM1 to JM7).
        var crashed: [32 * 1024]u8 = undefined;
        const crashed_len = b.disks[0].image_len;
        @memcpy(crashed[0..crashed_len], b.disks[0].image[0..crashed_len]);
        try checkRecovery(c, b, program, mutant, group, plan, whole[0..whole_len], crashed[0..crashed_len], point, recovered);

        // A failure at the operation: the run ends where it failed, alike on both machines, and
        // the journal refuses the rest; its disk is cut at a commit point all the same (J6).
        try b.run(program, group, .full, null, point, 0);
        try c.check(b.outcomes[0] == b.outcomes[1], "journal_dst_failures_end_both_machines_alike");
        if (!b.outcomes[0]) {
            try c.check(std.meta.eql(b.results[0], b.results[1]), "journal_dst_failure_diagnostics_agree");
            const code = b.results[0].code;
            try c.check(code == .effect_commit_failed or code == .input_failed or code == .invalid_ir or (plan.fatal and code == .division_by_zero), "journal_dst_failure_codes");
        }
        try c.check(b.journals[0].failed and b.journals[1].failed, "journal_dst_failed_journal_refuses_the_rest");
        try c.check(std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "journal_dst_failed_journals_agree");
        const failed = try scanBytes(b.disks[0].bytes[0..b.disks[0].len], &buffer);
        try c.check(failed.actions == 0 or std.mem.indexOfScalar(u32, plan.boundaries[0..plan.boundary_count], @intCast(failed.actions)) != null, "journal_dst_failed_journal_ends_at_a_commit_point");
    }
    // R2: the journal of the run that ended, recovered: nothing runs, nothing is written.
    try checkRecovery(c, b, program, mutant, group, plan, whole[0..whole_len], whole[0..whole_len], 1, recovered);
    return .{ .crashes = crashes, .cut_points = cut_points };
}

test "journaled programs crashed and failed at every disk operation keep whole commit points on both machines, and are recovered" {
    const b = try forbic.scratch.make(Bench);
    defer forbic.scratch.destroy(b);
    var c = kernel.Context.init(0x6a6f75726e616c, .swarm);
    var source_bytes: [8 * 1024]u8 = undefined;
    var crashes: u64 = 0;
    var cut_points: u64 = 0;
    var fatal: u64 = 0;
    var recovered: Recovered = .{};
    for (0..60) |_| {
        var out: std.Io.Writer = .fixed(&source_bytes);
        var plan: Plan = .{};
        try generate(&c.rng, &out, &plan);
        if (plan.fatal) fatal += 1;
        const counted = checkProgram(&c, b, out.buffered(), &plan, &recovered) catch |problem| {
            std.debug.print("journal dst failed ({s}) on: {s}\n", .{ c.failure orelse "", out.buffered() });
            return problem;
        };
        crashes += counted.crashes;
        cut_points += counted.cut_points;
    }
    // The campaign met crashes that kept commit points, and runs that ended in a fatal error.
    try std.testing.expect(crashes > 1000 and cut_points > 200 and fatal > 5);
    // P2.5: it resumed runs from their cuts, crashed some of those resumes and recovered again,
    // abandoned, met finished journals and ones with no header, and caught changed programs.
    std.debug.print("journal dst recovery: {d} resumed, {d} crashed while resuming and recovered again, {d} abandoned, {d} finished, {d} started afresh, {d} changed programs diverged\n", .{ recovered.resumed, recovered.again, recovered.abandoned, recovered.finished, recovered.fresh, recovered.diverged });
    try std.testing.expect(recovered.resumed > 500 and recovered.again > 100 and recovered.abandoned > 500 and recovered.finished > 20 and recovered.fresh > 20 and recovered.diverged > 50);
    try std.testing.expect(c.failure == null);
}

/// P2.5: what the recoveries of a campaign met.
const Recovered = struct {
    resumed: u64 = 0,
    again: u64 = 0,
    abandoned: u64 = 0,
    finished: u64 = 0,
    fresh: u64 = 0,
    diverged: u64 = 0,
};

/// A program changed from `source` (JM7): the first action whose text is a literal of the source
/// prints another text. Null when the plan has none.
const Mutant = struct { program: vtypes.Program, action: u32 };

fn mutate(b: *Bench, source: []const u8, plan: *const Plan, out: []u8) !?Mutant {
    for (plan.actions[0..plan.action_count], 0..) |action, index| {
        var quoted: [32]u8 = undefined;
        const literal = try std.fmt.bufPrint(&quoted, "\"{s}\"", .{action.text[0..action.len]});
        const at = std.mem.indexOf(u8, source, literal) orelse continue;
        // The text must be this action's alone: a literal printed twice would change two.
        if (std.mem.indexOfPos(u8, source, at + 1, literal) != null) continue;
        var writer: std.Io.Writer = .fixed(out);
        try writer.print("{s}\"{s}x\"{s}", .{ source[0..at], action.text[0..action.len], source[at + literal.len ..] });
        const program = switch (b.mutant.compile(writer.buffered())) {
            .ok => |p| p,
            .failed => return error.Invariant,
        };
        return .{ .program = program, .action = @intCast(index) };
    }
    return null;
}

/// A journal's actions, seals and end, as text, for comparing two journals that may hold their
/// inputs differently (JM1).
fn commitsOf(bytes: []const u8, buffer: []u8, out: []u8) ![]const u8 {
    var image: durable.Image = .{ .bytes = bytes };
    var prefix = try durable.Prefix.init(image.disk(), buffer);
    var writer: std.Io.Writer = .fixed(out);
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => |action| try writer.print("a{d}.{d}:{s}|", .{ action.sequence, action.channel, action.text }),
        // A seal's inputs are the journal's records, which the Checker holds it to; the reference
        // journal holds its served inputs at its head, so only the actions are compared.
        .seal => |seal| try writer.print("s{d}|", .{seal.actions}),
        .end => |end| try writer.print("e{t}:{s}|", .{ end.outcome, end.code }),
        .abandoned => try writer.writeAll("abandoned|"),
        .header, .input, .published => {},
    };
    return writer.buffered();
}

/// A journal's inputs as text, in order.
fn inputsOf(bytes: []const u8, buffer: []u8, out: []u8) ![]const u8 {
    var image: durable.Image = .{ .bytes = bytes };
    var prefix = try durable.Prefix.init(image.disk(), buffer);
    var writer: std.Io.Writer = .fixed(out);
    while (try prefix.next()) |record| switch (record.decoded) {
        .input => |input| try writer.print("{t}{d}@{d}:{t}:{x}:{s}|", .{ input.kind, input.request, input.tick, input.status, input.bits, input.bytes }),
        else => {},
    };
    return writer.buffered();
}

/// A run's input record as `inputsOf` writes a journal's.
fn recordOf(record: effects.InputRecord, out: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    for (record.entries) |entry| try writer.print("{t}{d}@{d}:{t}:{x}:{s}|", .{ entry.kind, entry.request, entry.tick, entry.status, entry.bits, record.bytes[entry.start..entry.end] });
    return writer.buffered();
}

/// JM1, JM3 and JM6 of a resumed journal: both machines wrote it alike, neither diverged, it is
/// what an uninterrupted run writes whose inputs are the sealed ones and then `world`'s, the cut
/// before it is untouched (JM2), and its clock readings are one per tick and never go back.
fn checkResumed(c: *kernel.Context, b: *Bench, program: vtypes.Program, group: u32, cut: []const u8, world: usize) !void {
    var buffer: [4096]u8 = undefined;
    try c.check(std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "journal_dst_machines_resume_alike");
    try c.check(!b.journals[0].diverged and !b.journals[1].diverged, "journal_dst_the_program_again_does_not_diverge");
    try c.check(b.outcomes[0] == b.outcomes[1] and (b.outcomes[0] or std.meta.eql(b.results[0], b.results[1])), "journal_dst_resumed_machines_end_alike");
    try c.check(std.mem.eql(u8, b.disks[0].bytes[0..cut.len], cut), "journal_dst_resume_keeps_the_cut");
    var resumed: [32 * 1024]u8 = undefined;
    const resumed_len = b.disks[0].len;
    @memcpy(resumed[0..resumed_len], b.disks[0].bytes[0..resumed_len]);
    const ended_ok = b.outcomes[0];
    const ended = b.results[0];
    // JM6: in the resumed journal, one clock entry per tick, ticks growing, values never back.
    {
        var image: durable.Image = .{ .bytes = resumed[0..resumed_len] };
        var prefix = try durable.Prefix.init(image.disk(), &buffer);
        var previous: ?u64 = null;
        var tick: ?u64 = null;
        while (try prefix.next()) |record| switch (record.decoded) {
            .input => |input| if (input.kind == .clock) {
                try c.check(tick == null or input.tick > tick.?, "journal_dst_one_clock_reading_per_tick");
                const value = effects.clockValue(previous, input.bits);
                if (previous) |earlier| try c.check(@as(f64, @bitCast(value)) >= @as(f64, @bitCast(earlier)), "journal_dst_clock_never_goes_back");
                previous = value;
                tick = input.tick;
            },
            else => {},
        };
    }
    // JM1: the uninterrupted run on the sealed inputs, then the world.
    const sealed = b.sealed.sides[0].record();
    try c.check(try b.recover(program, group, null, sealed, world, null, 0) == .fresh, "journal_dst_reference_runs");
    if (!(b.outcomes[0] == ended_ok and (ended_ok or std.meta.eql(b.results[0], ended)))) std.debug.print("resumed ok={} {t}@{d}, reference ok={} {t}@{d}, sealed {d}\n", .{ ended_ok, ended.code, ended.span.start, b.outcomes[0], b.results[0].code, b.results[0].span.start, sealed.entries.len });
    try c.check(b.outcomes[0] == ended_ok and (ended_ok or std.meta.eql(b.results[0], ended)), "journal_dst_resume_ends_as_the_uninterrupted_run");
    var mine: [16 * 1024]u8 = undefined;
    var theirs: [16 * 1024]u8 = undefined;
    const mine_text = try commitsOf(resumed[0..resumed_len], &buffer, &mine);
    const theirs_text = try commitsOf(b.disks[0].bytes[0..b.disks[0].len], &buffer, &theirs);
    if (!std.mem.eql(u8, mine_text, theirs_text)) std.debug.print("resumed:   {s}\nreference: {s}\n", .{ mine_text, theirs_text });
    try c.check(std.mem.eql(u8, mine_text, theirs_text), "journal_dst_resume_commits_what_the_uninterrupted_run_commits");
    try c.check(std.mem.eql(u8, try inputsOf(resumed[0..resumed_len], &buffer, &mine), try recordOf(b.control.effects.inputs.record(), &theirs)), "journal_dst_resume_records_the_uninterrupted_run_s_inputs");
}

/// The recoveries of what a crash at disk operation `point` left (`image`): abandoning it (R7a,
/// JM5); resuming it against a world that answers otherwise (R1, R4, JM1 to JM3, JM6), one time in
/// three crashing that resume at one of its own disk operations and recovering again on a third
/// world; and resuming it with a changed program, which must diverge if the change lies in what
/// was sealed (JM7).
fn checkRecovery(c: *kernel.Context, b: *Bench, program: vtypes.Program, mutant: ?Mutant, group: u32, plan: *const Plan, whole: []const u8, image: []const u8, point: usize, recovered: *Recovered) !void {
    var buffer: [4096]u8 = undefined;
    const found = try scanBytes(image, &buffer);
    // R7a, JM5: abandoning cuts, ends in `abandoned`, and holds what the uninterrupted run had
    // committed at that commit point, for each writer and standard output.
    if (found.has_header and !found.finished()) {
        var disk: SimulatedDisk = .{};
        @memcpy(disk.bytes[0..image.len], image);
        disk.len = image.len;
        disk.synced = image.len;
        try durable.cutAt(disk.disk(), found);
        var journal: durable.Journal = .init(disk.disk(), &buffer);
        journal.resumeAt(found);
        try journal.abandon();
        const ended = try scanBytes(disk.bytes[0..disk.len], &buffer);
        try c.check(ended.finished() and ended.abandoned and ended.actions == found.actions and ended.cut == disk.len, "journal_dst_abandoned_journal_is_finished");
        var abandoned: durable.Image = .{ .bytes = disk.bytes[0..disk.len] };
        var prefix = try durable.Prefix.init(abandoned.disk(), &buffer);
        var index: usize = 0;
        while (try prefix.next()) |record| if (record.decoded == .action) {
            const expected = plan.actions[index];
            try c.check(record.decoded.action.channel == expected.channel and std.mem.eql(u8, record.decoded.action.text, expected.text[0..expected.len]), "journal_dst_abandoning_keeps_the_commit_point");
            index += 1;
        };
        try c.check(index == found.actions, "journal_dst_abandoning_keeps_every_sealed_action");
        // R7a: what abandoning publishes is each writer's lines up to the commit point.
        try checkPublication(c, plan, disk.bytes[0..disk.len], found.actions, &buffer);
        recovered.abandoned += 1;
    }
    // A header the run's would not be is refused before anything runs (R3).
    if (found.has_header) {
        var image_disk: durable.Image = .{ .bytes = image };
        var reader: durable.Reader = .{ .disk = image_disk.disk(), .buffer = &buffer };
        const first = (try reader.next()).?;
        var grants: [4]durable.GrantRecord = undefined;
        const header = try durable.decodeHeader(first.payload, &grants);
        var other = header;
        other.program[0] ^= 1;
        try c.check(durable.mismatch(header, header) == null and durable.mismatch(header, other) == .program, "journal_dst_header_of_another_program_mismatches");
        // c1-3: the header with a tick rate no run takes is malformed, so that a resume refuses it
        // before a machine is given the rate; one the scheduler takes is read back.
        const max_rate = vtypes.Scheduler.max_tick_rate;
        const rates = [_]u64{ 0, max_rate + 1, 1 << 31, std.math.maxInt(u64), 1 + c.rng.below(max_rate) };
        for (rates, 0..) |rate, index| {
            var forged = header;
            forged.tick_rate = rate;
            var forged_bytes: [256]u8 = undefined;
            const payload = try durable.encodeHeader(forged, &forged_bytes);
            var forged_grants: [4]durable.GrantRecord = undefined;
            const decoded = durable.decodeHeader(payload, &forged_grants);
            if (index == rates.len - 1) {
                try c.check(if (decoded) |back| back.tick_rate == rate else |_| false, "journal_dst_header_of_a_valid_tick_rate_decodes");
            } else try c.check(if (decoded) |_| false else |_| true, "journal_dst_header_of_an_invalid_tick_rate_is_malformed");
        }
    }
    const begun = try b.recover(program, group, image, null, 1, null, 0);
    switch (begun) {
        .stopped => try c.check(false, "journal_dst_recovery_without_a_crash_runs"),
        .finished => {
            // R2: a finished journal survives only whole; nothing of the program runs. The host
            // publishes it (J8) by the tool's own function, alike when a crash makes it repeat the
            // processing, and then rotates it: the next run on the directory starts afresh.
            try c.check(found.finished() and std.mem.eql(u8, image[0..found.cut], whole), "journal_dst_finished_journal_is_the_whole_run");
            try checkPublication(c, plan, image, plan.action_count, &buffer);
            const rotated = try b.recover(program, group, null, null, 0, null, 0);
            try c.check(rotated == .fresh and b.outcomes[0] == b.outcomes[1] and std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "journal_dst_rotated_directory_runs_afresh");
            const after = try scanBytes(b.disks[0].bytes[0..b.disks[0].len], &buffer);
            try c.check(after.finished() and after.actions == plan.action_count, "journal_dst_rotated_directory_runs_the_whole_program");
            recovered.finished += 1;
            return;
        },
        .fresh => {
            // R1: no header survived; the run started afresh on the other world.
            try c.check(!found.has_header, "journal_dst_fresh_only_without_a_header");
            try c.check(b.outcomes[0] == b.outcomes[1] and std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "journal_dst_fresh_machines_agree");
            recovered.fresh += 1;
            return;
        },
        .resumed => {},
    }
    const operations = b.disks[0].operations;
    try checkResumed(c, b, program, group, image[0..found.cut], 1);
    recovered.resumed += 1;
    // A crash during recovery itself, then a second recovery on a third world.
    if (point % 3 == 0 and operations != 0) {
        const at = c.rng.below(operations);
        const tear = c.rng.next();
        _ = try b.recover(program, group, image, null, 1, at, tear);
        try c.check(b.disks[0].crashed and b.disks[1].crashed and b.disks[0].image_len == b.disks[1].image_len and std.mem.eql(u8, b.disks[0].image[0..b.disks[0].image_len], b.disks[1].image[0..b.disks[1].image_len]), "journal_dst_recoveries_crash_alike");
        var second: [32 * 1024]u8 = undefined;
        const second_len = b.disks[0].image_len;
        @memcpy(second[0..second_len], b.disks[0].image[0..second_len]);
        const again = try scanBytes(second[0..second_len], &buffer);
        // What the crash kept of the recovery holds the first cut whole: a recovery loses nothing
        // that was sealed.
        try c.check(again.has_header and again.cut >= found.cut and std.mem.eql(u8, second[0..found.cut], image[0..found.cut]), "journal_dst_crashed_recovery_keeps_the_cut");
        switch (try b.recover(program, group, second[0..second_len], null, 2, null, 0)) {
            .resumed => try checkResumed(c, b, program, group, second[0..again.cut], 2),
            .finished => {},
            .fresh, .stopped => try c.check(false, "journal_dst_second_recovery_resumes"),
        }
        recovered.again += 1;
    }
    // JM7: a program whose action differs in what was sealed is caught; the journal is left as cut.
    if (mutant) |changed| if (found.has_header and !found.finished() and found.actions > changed.action) {
        try c.check(try b.recover(changed.program, group, image, null, 1, null, 0) == .resumed, "journal_dst_changed_program_resumes");
        try c.check(b.journals[0].diverged and b.journals[1].diverged, "journal_dst_changed_program_diverges");
        try c.check(!b.outcomes[0] and std.meta.eql(b.results[0], b.results[1]) and b.results[0].code == .effect_commit_failed, "journal_dst_divergence_ends_both_machines_alike");
        try c.check(b.disks[0].len == found.cut and std.mem.eql(u8, b.disks[0].bytes[0..found.cut], image[0..found.cut]), "journal_dst_divergence_leaves_the_cut");
        recovered.diverged += 1;
    };
}

/// J8: what the host publishes from a journal (`image`): by `durable.writePublished`, the tool's
/// own function, each writer receives its channel's lines of the first `actions` committed
/// actions of the plan, in order, and publishing again, as a crash during the processing makes the
/// next command do, writes the same.
fn checkPublication(c: *kernel.Context, plan: *const Plan, image: []const u8, actions: u64, buffer: []u8) !void {
    // By grant index, as the tool groups `journal_grants`: the reader owns nothing, each writer
    // its own file. Channel `n` is grant `n - 1`.
    const owners = [_]?u32{ null, 1, 2 };
    for ([_]u32{ 1, 2 }) |owner| {
        var expected_bytes: [4096]u8 = undefined;
        var expected: std.Io.Writer = .fixed(&expected_bytes);
        for (plan.actions[0..@intCast(actions)]) |act| if (act.channel == owner + 1) {
            try expected.writeAll(act.text[0..act.len]);
            try expected.writeByte('\n');
        };
        var published: [2][4096]u8 = undefined;
        var lengths: [2]usize = undefined;
        for (&published, &lengths) |*bytes, *length| {
            var image_disk: durable.Image = .{ .bytes = image };
            var out: std.Io.Writer = .fixed(bytes);
            const written = try durable.writePublished(image_disk.disk(), buffer, &owners, owner, &out);
            try c.check(written == out.buffered().len, "journal_dst_publication_counts_its_bytes");
            length.* = out.buffered().len;
        }
        try c.check(std.mem.eql(u8, published[0][0..lengths[0]], expected.buffered()), "journal_dst_publication_is_the_committed_lines");
        try c.check(std.mem.eql(u8, published[0][0..lengths[0]], published[1][0..lengths[1]]), "journal_dst_publication_repeats_exactly");
    }
}

test "the simulated disk keeps a synced prefix and tears what follows it, alike for a crash point" {
    var first: SimulatedDisk = .{ .crash_at = 3, .tear = 9 };
    var second: SimulatedDisk = .{ .crash_at = 3, .tear = 9 };
    for ([_]*SimulatedDisk{ &first, &second }) |disk| {
        const d = disk.disk();
        try d.append(d.context, &.{"header"});
        try d.sync(d.context);
        try d.append(d.context, &.{ "un", "synced" });
        try std.testing.expectError(error.DiskFailed, d.sync(d.context));
        try std.testing.expectError(error.DiskFailed, d.append(d.context, &.{"later"}));
        try std.testing.expect(disk.crashed and disk.image_len >= 6 and disk.image_len <= 14);
        try std.testing.expectEqualStrings("header", disk.image[0..6]);
    }
    try std.testing.expectEqualSlices(u8, first.image[0..first.image_len], second.image[0..second.image_len]);
}

// ---- The store of persistent cells (RFC-0087, P5.5) -------------------------------------------
//
// Programs of one persistent cell `X` of `i64`, with the keys `alice` and `bob`, whose entries the
// store holds or lacks, written with a model of their store actions written here from S5: a root
// write is saved, a compound update of an absent entry fails and saves nothing, a write in a region
// that fails is dropped. Each runs journaled on both machines, then is crashed at every disk
// operation of the journal. What a crash leaves is published, as `--abandon` publishes it, from the
// durable prefix to a store on a simulated disk, and must be the store of the uninterrupted run at
// that commit point (JM5); a publication that crashes at any of its own disk operations, with the
// file it was writing there or not, is published again to the same generation (S6); and a second
// session that loads what was published does what the model says the program does on those entries.

const store_lib = forbic.store;
const key_names = [2][]const u8{ "alice", "bob" };

const StoreOp = struct { kind: u8, key: u8, constant: i64 };
const Entries = [2]?i64;
const Saved = struct { key: u8, value: i64 };

/// What the model says a run does with its entries: the actions it commits, in order, and the
/// entries at the end.
const StoreRun = struct {
    saved: [64]Saved = undefined,
    count: usize = 0,
    entries: Entries,

    fn save(self: *StoreRun, key: u8, value: i64) void {
        self.entries[key] = value;
        self.saved[self.count] = .{ .key = key, .value = value };
        self.count += 1;
    }
};

fn simulateStore(ops: []const StoreOp, initial: Entries) StoreRun {
    var run: StoreRun = .{ .entries = initial };
    for (ops) |op| switch (op.kind) {
        0 => run.save(op.key, op.constant),
        1 => if (run.entries[op.key]) |value| run.save(op.key, value + op.constant),
        // A write in a region that fails, and a line printed: no action is saved.
        else => {},
    };
    return run;
}

fn storeSource(ops: []const StoreOp, out: *std.Io.Writer) !void {
    try out.writeAll("var X:weak_map(persistent_key,i64)=map{}\n");
    for (ops, 0..) |op, index| {
        const who = key_names[op.key];
        switch (op.kind) {
            0 => try out.print("S{d}:i64=Attempt(Block{{K:=GetPersistentKey[\"{s}\"];set X[K]={d};{d}}},-1)\n", .{ index, who, op.constant, op.constant }),
            1 => try out.print("S{d}:i64=Attempt(Block{{K:=GetPersistentKey[\"{s}\"];set X[K]+={d};X[K]}},-1)\n", .{ index, who, op.constant }),
            2 => try out.print("S{d}:i64=Attempt(Block{{K:=GetPersistentKey[\"{s}\"];set X[K]={d};Require[false];0}},0)\n", .{ index, who, op.constant }),
            else => try out.print("S{d}:tuple()=Print(\"p{d}\")\n", .{ index, index }),
        }
    }
    try out.writeAll("Value:i64=1\n");
}

/// The entries of the store at generation `hash`, read the way a run loads them.
fn storeEntries(files: *store_lib.Store, hash: ?store_lib.Hash) !Entries {
    var entries: Entries = .{ null, null };
    const named = hash orelse return entries;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const generation = try files.generation(arena_state.allocator(), named);
    for (&entries, key_names) |*slot, who| if (generation.find(":X", who)) |entry| {
        const text = try files.text(entry);
        defer std.testing.allocator.free(text);
        slot.* = try std.fmt.parseInt(i64, text, 10);
    };
    return entries;
}

/// A store holding `entries`, as a first run left it: its active generation, or none.
fn storeWith(memory: *store_lib.Memory, entries: Entries) !?store_lib.Hash {
    var files: store_lib.Store = .{ .disk = memory.disk(), .gpa = std.testing.allocator };
    var texts: [2][24]u8 = undefined;
    var updates: [2]store_lib.Updates.Update = undefined;
    var count: usize = 0;
    for (entries, key_names, &texts) |entry, who, *text| if (entry) |value| {
        updates[count] = .{ .cell = ":X", .key = who, .text = @constCast(try std.fmt.bufPrint(text, "{d}", .{value})) };
        count += 1;
    };
    return files.publish(null, store_lib.hashOf("schema"), updates[0..count]);
}

/// The store actions of the durable prefix of `journal`, as publication reads them.
fn storeUpdates(updates: *store_lib.Updates, journal: []const u8, buffer: []u8) !u64 {
    var image: durable.Image = .{ .bytes = journal };
    var prefix = try durable.Prefix.init(image.disk(), buffer);
    var count: u64 = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => |action| if (action.channel == effects.store_channel) {
            try updates.add(action.text);
            count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u64, 0), updates.malformed);
    return count;
}

/// Publishes the store actions of `journal` onto a store that holds `initial`, and gives the
/// entries it then holds; with `crash_at`, a publication that crashes at that disk operation (the
/// file it was writing there, or not, by `applied`) and is published again.
fn publishJournal(c: *kernel.Context, journal: []const u8, initial: Entries, crash_at: ?u64, applied: bool, buffer: []u8) !struct { entries: Entries, hash: ?store_lib.Hash } {
    var memory: store_lib.Memory = .init(std.testing.allocator);
    defer memory.deinit();
    const base = try storeWith(&memory, initial);
    var files: store_lib.Store = .{ .disk = memory.disk(), .gpa = std.testing.allocator };
    var updates = store_lib.Updates.init(std.testing.allocator);
    defer updates.deinit();
    _ = try storeUpdates(&updates, journal, buffer);
    const list = try updates.sorted();
    defer std.testing.allocator.free(list);
    const before = memory.operations;
    if (crash_at) |at| {
        memory.fail_at = before + at;
        memory.apply_failed = applied;
        if (files.publish(base, store_lib.hashOf("schema"), list)) |_| {
            // The publication had fewer operations than the crash point: nothing crashed.
        } else |problem| try c.check(problem == error.DiskFailed, "store_dst_a_crashed_publication_is_a_disk_failure");
        memory.fail_at = null;
        // Whatever the crash left, active names the base or the generation to be.
        if (try files.activeName()) |hash| {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            _ = try files.generation(arena_state.allocator(), hash);
        }
    }
    const published = try files.publish(base, store_lib.hashOf("schema"), list);
    const hash = published orelse base;
    return .{ .entries = try storeEntries(&files, hash), .hash = hash };
}

fn checkStore(c: *kernel.Context, b: *Bench, rng: *kernel.Rng) !struct { crashes: u64, republished: u64, sessions: u64 } {
    var ops: [12]StoreOp = undefined;
    const count: usize = @intCast(2 + rng.below(9));
    for (ops[0..count]) |*op| op.* = .{ .kind = @intCast(rng.below(4)), .key = @intCast(rng.below(2)), .constant = @as(i64, @intCast(rng.below(40))) - 10 };
    var initial: Entries = .{ null, null };
    for (&initial) |*entry| if (rng.below(3) != 0) {
        entry.* = @as(i64, @intCast(rng.below(30))) - 5;
    };
    var source_bytes: [4096]u8 = undefined;
    var source: std.Io.Writer = .fixed(&source_bytes);
    try storeSource(ops[0..count], &source);
    const program = switch (b.front.compile(source.buffered())) {
        .ok => |p| p,
        .failed => |d| {
            std.debug.print("store dst compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source.buffered() });
            return error.Invariant;
        },
    };
    var texts: [2][24]u8 = undefined;
    var stored: [2]effects.Stored = undefined;
    var held: usize = 0;
    for (initial, &texts, 0..) |entry, *text, key| if (entry) |value| {
        stored[held] = .{ .request = effects.loadRequest(0, @intCast(3 + key)), .text = try std.fmt.bufPrint(text, "{d}", .{value}) };
        held += 1;
    };
    b.store = stored[0..held];
    defer b.store = &.{};
    var buffer: [4096]u8 = undefined;
    const group: u32 = @intCast(1 + rng.below(4));
    try b.run(program, group, .full, null, null, 0);
    try c.check(b.outcomes[0] and b.outcomes[1], "store_dst_runs_complete");
    try c.check(std.mem.eql(u8, b.disks[0].bytes[0..b.disks[0].len], b.disks[1].bytes[0..b.disks[1].len]), "store_dst_machines_write_one_journal");
    var whole: [32 * 1024]u8 = undefined;
    const whole_len = b.disks[0].len;
    @memcpy(whole[0..whole_len], b.disks[0].bytes[0..whole_len]);
    const operations = b.disks[0].operations;
    // The journal holds the loads, one per key, and the actions the model says.
    const model = simulateStore(ops[0..count], initial);
    {
        var loads: u32 = 0;
        var saved: usize = 0;
        var image: durable.Image = .{ .bytes = whole[0..whole_len] };
        var prefix = try durable.Prefix.init(image.disk(), &buffer);
        while (try prefix.next()) |record| switch (record.decoded) {
            .input => |input| if (input.kind == .load) {
                try c.check(input.request == effects.loadRequest(0, 3 + loads) and (input.status == .value) == (initial[loads] != null), "store_dst_loads_follow_the_keys");
                loads += 1;
            },
            .action => |action| if (action.channel == effects.store_channel) {
                var expected_bytes: [96]u8 = undefined;
                const expected = try std.fmt.bufPrint(&expected_bytes, "{{\"cell\":\":X\",\"key\":\"{s}\",\"value\":{d}}}", .{ key_names[model.saved[saved].key], model.saved[saved].value });
                try c.check(std.mem.eql(u8, action.text, expected), "store_dst_actions_match_the_model");
                saved += 1;
            },
            else => {},
        };
        try c.check(loads == 2 and saved == model.count, "store_dst_journal_holds_the_model");
    }
    // Published whole, the store is the model's.
    const finished = try publishJournal(c, whole[0..whole_len], initial, null, false, &buffer);
    for (finished.entries, model.entries) |got, want| try c.check(std.meta.eql(got, want), "store_dst_published_store_is_the_models");
    var crashes: u64 = 0;
    var republished: u64 = 0;
    var sessions: u64 = 0;
    var last_saved: ?u64 = null;
    for (0..operations) |point| {
        b.store = stored[0..held];
        try b.run(program, group, .full, point, null, rng.next());
        crashes += 1;
        try c.check(b.disks[0].crashed and b.disks[1].crashed, "store_dst_crash_point_reached");
        var crashed: [32 * 1024]u8 = undefined;
        const crashed_len = b.disks[0].image_len;
        @memcpy(crashed[0..crashed_len], b.disks[0].image[0..crashed_len]);
        const found = try scanBytes(crashed[0..crashed_len], &buffer);
        if (!found.has_header) {
            // No journal: nothing to publish, and the store is as it was.
            continue;
        }
        // JM5: the durable prefix publishes the store of the uninterrupted run at its commit point.
        var updates = store_lib.Updates.init(std.testing.allocator);
        defer updates.deinit();
        const actions = try storeUpdates(&updates, crashed[0..found.cut], &buffer);
        const prefix_model = simulateStorePrefix(ops[0..count], initial, @intCast(actions));
        const result = try publishJournal(c, crashed[0..found.cut], initial, null, false, &buffer);
        for (result.entries, prefix_model.entries) |got, want| try c.check(std.meta.eql(got, want), "store_dst_abandoned_store_is_the_commit_points");
        // A publication that crashes at each of its disk operations, whole or not, is published
        // again to the same generation (S6).
        if (actions != 0) for (0..6) |at| for ([_]bool{ false, true }) |applied| {
            const again = try publishJournal(c, crashed[0..found.cut], initial, at, applied, &buffer);
            try c.check(again.hash != null and result.hash != null and std.mem.eql(u8, &again.hash.?, &result.hash.?), "store_dst_a_crashed_publication_is_published_again");
            republished += 1;
        };
        // A second session loads what was published and does what the model says on those entries.
        if (last_saved == null or last_saved.? != actions) {
            last_saved = actions;
            var again_texts: [2][24]u8 = undefined;
            var again_stored: [2]effects.Stored = undefined;
            var again_held: usize = 0;
            for (result.entries, &again_texts, 0..) |entry, *text, key| if (entry) |value| {
                again_stored[again_held] = .{ .request = effects.loadRequest(0, @intCast(3 + key)), .text = try std.fmt.bufPrint(text, "{d}", .{value}) };
                again_held += 1;
            };
            b.store = again_stored[0..again_held];
            try b.run(program, group, .full, null, null, 0);
            try c.check(b.outcomes[0] and b.outcomes[1], "store_dst_second_session_completes");
            const second = simulateStore(ops[0..count], result.entries);
            var saved: usize = 0;
            var image: durable.Image = .{ .bytes = b.disks[0].bytes[0..b.disks[0].len] };
            var prefix = try durable.Prefix.init(image.disk(), &buffer);
            while (try prefix.next()) |record| switch (record.decoded) {
                .action => |action| if (action.channel == effects.store_channel) {
                    var expected_bytes: [96]u8 = undefined;
                    const expected = try std.fmt.bufPrint(&expected_bytes, "{{\"cell\":\":X\",\"key\":\"{s}\",\"value\":{d}}}", .{ key_names[second.saved[saved].key], second.saved[saved].value });
                    try c.check(std.mem.eql(u8, action.text, expected), "store_dst_second_session_follows_the_store");
                    saved += 1;
                },
                else => {},
            };
            try c.check(saved == second.count, "store_dst_second_session_saves_what_the_model_says");
            sessions += 1;
        }
    }
    return .{ .crashes = crashes, .republished = republished, .sessions = sessions };
}

/// The model's run after only its first `actions` actions were committed: the entries then.
fn simulateStorePrefix(ops: []const StoreOp, initial: Entries, actions: usize) StoreRun {
    const whole = simulateStore(ops, initial);
    var prefix: StoreRun = .{ .entries = initial };
    for (whole.saved[0..@min(actions, whole.count)]) |saved| prefix.save(saved.key, saved.value);
    return prefix;
}

test "persistent stores: a program's store actions crashed at every disk operation publish the store of the uninterrupted run at that commit point, a crashed publication is published again, and a second session loads it" {
    const b = try forbic.scratch.make(Bench);
    defer forbic.scratch.destroy(b);
    var c = kernel.Context.init(0x73746f7265, .swarm);
    var crashes: u64 = 0;
    var republished: u64 = 0;
    var sessions: u64 = 0;
    for (0..30) |_| {
        const counted = checkStore(&c, b, &c.rng) catch |problem| {
            std.debug.print("store dst failed ({s})\n", .{c.failure orelse ""});
            return problem;
        };
        crashes += counted.crashes;
        republished += counted.republished;
        sessions += counted.sessions;
    }
    std.debug.print("store dst: {d} crashes, {d} publications crashed and published again, {d} second sessions\n", .{ crashes, republished, sessions });
    try std.testing.expect(crashes > 200 and republished > 500 and sessions > 60);
    try std.testing.expect(c.failure == null);
}

// ---- Recovery of a store (RFC-0087, P5.7) ---------------------------------------------------
//
// The programs of the store test above, run journaled with a store their header names, then
// crashed at every disk operation of the run. Each crash is recovered by a command that resumes
// or abandons the journal (or, for a run that ended, processes its end): the publication of what
// the journal sealed (`forbic.publication`, the host's own steps), its `published` record, the
// resumed run on both machines, and the publication at its end. That command is itself crashed at
// each of its disk operations, of the journal and of the store alike, with the file a crashed put
// was writing there or not; and after one crash in three the store loses the last replacement of
// `active` the command made while the journal keeps what it synced (RFC-0086 G22, RFC-0087 P5.5
// P12). A second command recovers what that left, and the journal it ends with is then checked as
// the next run checks its rotated journal. The store must then hold exactly what the uninterrupted
// run's store holds at the commit point the journal reached (JM1 when it ended, JM5 when it was
// abandoned), its records must each name the generation its publication makes, and a second
// session that loads it does what the model says on those entries.

const publication = forbic.publication;

/// A store whose puts are disk operations of the journal's simulated disk: they share its crash
/// point, and nothing reaches either after it. A put that the crash stopped leaves its file whole
/// or absent.
const CrashStore = struct {
    files: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    sim: *SimulatedDisk,
    rng: kernel.Rng,
    /// The command replaced `active`, which held `previous` before (null: no file).
    replaced: bool = false,
    previous: ?[store_lib.active_bytes]u8 = null,
    /// The last generation the command created, a file no earlier command wrote.
    created: ?store_lib.Hex = null,
    /// s5-1: the last object the command created, a file no earlier command wrote.
    created_object: ?store_lib.Hex = null,

    fn deinit(self: *CrashStore) void {
        var held = self.files.iterator();
        while (held.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(std.testing.allocator);
    }
    fn handle(self: *CrashStore) store_lib.Store {
        return .{ .disk = .{ .context = self, .read = read, .put = put }, .gpa = std.testing.allocator };
    }
    fn path(area: store_lib.Area, name: []const u8, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{t}/{s}", .{ area, name }) catch unreachable;
    }
    fn read(context: *anyopaque, gpa: std.mem.Allocator, area: store_lib.Area, name: []const u8, limit: usize) store_lib.DiskError!?[]u8 {
        const self: *CrashStore = @ptrCast(@alignCast(context));
        if (self.sim.crashed) return error.DiskFailed;
        var buffer: [128]u8 = undefined;
        const bytes = self.files.get(path(area, name, &buffer)) orelse return null;
        if (bytes.len > limit) return error.TooLarge;
        return gpa.dupe(u8, bytes) catch return error.DiskFailed;
    }
    fn put(context: *anyopaque, area: store_lib.Area, name: []const u8, bytes: []const u8) store_lib.DiskError!void {
        const self: *CrashStore = @ptrCast(@alignCast(context));
        const before = self.sim.crashed;
        self.sim.operation() catch {
            if (!before and self.sim.crashed and self.rng.below(2) == 0) self.write(area, name, bytes);
            return error.DiskFailed;
        };
        self.write(area, name, bytes);
    }
    fn write(self: *CrashStore, area: store_lib.Area, name: []const u8, bytes: []const u8) void {
        var buffer: [128]u8 = undefined;
        const key = path(area, name, &buffer);
        if (area == .root and !self.replaced) {
            self.replaced = true;
            self.previous = if (self.files.get(key)) |held| held[0..store_lib.active_bytes].* else null;
        }
        if (area == .generations and self.files.get(key) == null) self.created = name[0..64].*;
        if (area == .objects and self.files.get(key) == null) self.created_object = name[0..64].*;
        const copy = std.testing.allocator.dupe(u8, bytes) catch @panic("out of memory");
        if (self.files.getPtr(key)) |existing| {
            std.testing.allocator.free(existing.*);
            existing.* = copy;
            return;
        }
        self.files.put(std.testing.allocator, std.testing.allocator.dupe(u8, key) catch @panic("out of memory"), copy) catch @panic("out of memory");
    }
    /// G22: the replacement of `active` this command made is lost, as a file system that does not
    /// order its metadata may lose it while the journal keeps what its own sync made durable.
    fn loseActive(self: *CrashStore) void {
        if (!self.replaced) return;
        var buffer: [128]u8 = undefined;
        const key = path(.root, store_lib.active_name, &buffer);
        if (self.previous) |held| {
            self.write(.root, store_lib.active_name, &held);
        } else if (self.files.fetchSwapRemove(key)) |removed| {
            std.testing.allocator.free(removed.key);
            std.testing.allocator.free(removed.value);
        }
    }
    /// G22 as well: the generation the command created is lost, whether or not `active` names it.
    fn loseGeneration(self: *CrashStore) bool {
        const name = self.created orelse return false;
        var buffer: [128]u8 = undefined;
        const removed = self.files.fetchSwapRemove(path(.generations, &name, &buffer)) orelse return false;
        std.testing.allocator.free(removed.key);
        std.testing.allocator.free(removed.value);
        self.created = null;
        return true;
    }
    /// s5-1, G22 as well: the object the command created last is lost, cut short or changed,
    /// whatever names it. How, or null when the command created none.
    fn loseObject(self: *CrashStore) ?ObjectLoss {
        const name = self.created_object orelse return null;
        self.created_object = null;
        var buffer: [128]u8 = undefined;
        const key = path(.objects, &name, &buffer);
        const how: ObjectLoss = @fromBackingInt(@intCast(self.rng.below(3)));
        switch (how) {
            .lost => {
                const removed = self.files.fetchSwapRemove(key) orelse return null;
                std.testing.allocator.free(removed.key);
                std.testing.allocator.free(removed.value);
            },
            .cut => {
                const bytes = self.files.getPtr(key) orelse return null;
                if (bytes.len == 0) return null;
                const kept = std.testing.allocator.dupe(u8, bytes.*[0..@intCast(self.rng.below(bytes.len))]) catch @panic("out of memory");
                std.testing.allocator.free(bytes.*);
                bytes.* = kept;
            },
            .changed => {
                const bytes = self.files.getPtr(key) orelse return null;
                if (bytes.len == 0) return null;
                bytes.*[@intCast(self.rng.below(bytes.len))] ^= @intCast(1 + self.rng.below(255));
            },
        }
        return how;
    }
    /// A copy of `other`'s files, on `sim`.
    fn copyOf(other: *const CrashStore, sim: *SimulatedDisk, seed: u64) CrashStore {
        var copy: CrashStore = .{ .sim = sim, .rng = .{ .state = seed } };
        var held = other.files.iterator();
        while (held.next()) |entry| {
            copy.files.put(std.testing.allocator, std.testing.allocator.dupe(u8, entry.key_ptr.*) catch @panic("out of memory"), std.testing.allocator.dupe(u8, entry.value_ptr.*) catch @panic("out of memory")) catch @panic("out of memory");
        }
        return copy;
    }
};

const ObjectLoss = enum(u2) { lost, cut, changed };

const RecoveryStats = struct {
    commands: u64 = 0,
    crashes: u64 = 0,
    lost_active: u64 = 0,
    lost_generations: u64 = 0,
    /// s5-1: objects lost, cut short and changed, by `ObjectLoss`.
    lost_objects: [3]u64 = @splat(0),
    repaired: u64 = 0,
    again: u64 = 0,
    resumed: u64 = 0,
    abandoned: u64 = 0,
    records: u64 = 0,
    sessions: u64 = 0,
    /// c1-2: journals whose header names another schema, refused.
    forged_schemas: u64 = 0,
};

/// What the host does to a journal before or instead of running (P5.7): its store published from
/// the durable prefix and the publication recorded. False: a crash stopped it.
fn publishRecorded(c: *kernel.Context, journal: *durable.Journal, held: *store_lib.Store, reference: durable.StoreRef, buffer: []u8, stats: *RecoveryStats) !bool {
    var made = publication.plan(std.testing.allocator, held, journal.disk, buffer, reference) catch |problem| {
        if (problem == error.DiskFailed) return false;
        std.debug.print("store recovery dst: plan {s} ({s})\n", .{ @errorName(problem), held.why });
        try c.check(false, "store_recovery_dst_publication_is_planned");
        unreachable;
    };
    defer made.deinit();
    if (made.behind != null) stats.repaired += 1;
    if (made.next_name) |next| if (made.active) |active| if (std.mem.eql(u8, &next, &active)) {
        stats.again += 1;
    };
    const name = (publication.apply(&made, held) catch |problem| {
        if (problem == error.DiskFailed) return false;
        try c.check(false, "store_recovery_dst_publication_is_applied");
        unreachable;
    }) orelse return true;
    journal.recordPublished(.{ .generation = name, .through = made.through }) catch return false;
    return true;
}

const Intent = enum { resume_run, abandon };

const Commanded = struct { operations: u64, crashed: bool, len: usize };

/// The end of a command a crash stopped: its journal is the crash's image, and one time in three
/// the replacement of `active` it made is lost.
fn stoppedBy(disk: *const SimulatedDisk, files: *CrashStore, stats: *RecoveryStats, operations: u64, out: []u8) Commanded {
    @memcpy(out[0..disk.image_len], disk.image[0..disk.image_len]);
    stats.crashes += 1;
    if (files.rng.below(3) == 0 and files.replaced) {
        files.loseActive();
        stats.lost_active += 1;
    }
    if (files.rng.below(4) == 0 and files.loseGeneration()) stats.lost_generations += 1;
    if (files.rng.below(4) == 0) if (files.loseObject()) |how| {
        stats.lost_objects[@backingInt(how)] += 1;
    };
    return .{ .operations = operations, .crashed = true, .len = disk.image_len };
}

/// One command on `image` and `files`: a finished journal processed, or an unfinished one resumed
/// on both machines (publication first, the run, publication at its end) or abandoned
/// (publication, `abandoned`). With `crash_at`, the disk operation it crashes at, counted across
/// the journal's and the store's. The journal it leaves is in `out`; the result is how many disk
/// operations it made and whether it crashed.
fn storeCommand(c: *kernel.Context, b: *Bench, program: vtypes.Program, group: u32, intent: Intent, image: []const u8, files: *CrashStore, reference: durable.StoreRef, crash_at: ?u64, tear: u64, stats: *RecoveryStats, out: []u8) !Commanded {
    var buffer: [4096]u8 = undefined;
    const disk = try std.testing.allocator.create(SimulatedDisk);
    defer std.testing.allocator.destroy(disk);
    disk.* = .{ .crash_at = crash_at, .tear = tear };
    @memcpy(disk.bytes[0..image.len], image);
    disk.len = image.len;
    disk.synced = image.len;
    files.sim = disk;
    files.replaced = false;
    files.created = null;
    files.created_object = null;
    var held = files.handle();
    const found = try durable.scan(disk.disk(), &buffer);
    try c.check(found.has_header, "store_recovery_dst_journal_has_a_header");
    var journal: durable.Journal = .init(disk.disk(), &buffer);
    stopped: {
        durable.cutAt(disk.disk(), found) catch break :stopped;
        journal.reopen(found);
        if (!try publishRecorded(c, &journal, &held, reference, &buffer, stats)) break :stopped;
        if (found.finished()) break :stopped;
        if (intent == .abandon) {
            journal.abandon() catch break :stopped;
            stats.abandoned += 1;
            break :stopped;
        }
        // The resumed run, on both machines, each from the journal the publication left.
        const before = disk.operations;
        const run_crash: ?u64 = if (crash_at) |at| at - before else null;
        const begun = try b.recover(program, group, disk.bytes[0..disk.len], null, 0, run_crash, tear);
        try c.check(b.disks[0].crashed == b.disks[1].crashed, "store_recovery_dst_machines_crash_alike");
        if (b.disks[0].crashed) {
            try c.check(std.mem.eql(u8, b.disks[0].image[0..b.disks[0].image_len], b.disks[1].image[0..b.disks[1].image_len]), "store_recovery_dst_machines_leave_one_journal");
            return stoppedBy(&b.disks[0], files, stats, before + b.disks[0].operations, out);
        }
        try c.check(begun == .resumed, "store_recovery_dst_the_run_resumes");
        try c.check(b.outcomes[0] and b.outcomes[1], "store_recovery_dst_resumed_runs_complete");
        const ran = b.disks[0].bytes[0..b.disks[0].len];
        try c.check(std.mem.eql(u8, ran, b.disks[1].bytes[0..b.disks[1].len]), "store_recovery_dst_resumed_machines_write_one_journal");
        stats.resumed += 1;
        // The publication at its end, on a disk that goes on counting where the run stopped.
        const used = before + b.disks[0].operations;
        const ended = try std.testing.allocator.create(SimulatedDisk);
        defer std.testing.allocator.destroy(ended);
        ended.* = .{ .crash_at = if (crash_at) |at| at - used else null, .tear = tear };
        @memcpy(ended.bytes[0..ran.len], ran);
        ended.len = ran.len;
        ended.synced = ran.len;
        files.sim = ended;
        var end_journal: durable.Journal = .init(ended.disk(), &buffer);
        const end_found = try durable.scan(ended.disk(), &buffer);
        try c.check(end_found.end != null, "store_recovery_dst_resumed_run_ends");
        var published = false;
        if (durable.cutAt(ended.disk(), end_found)) |_| {
            end_journal.reopen(end_found);
            published = try publishRecorded(c, &end_journal, &held, reference, &buffer, stats);
        } else |_| {}
        if (ended.crashed) return stoppedBy(ended, files, stats, used + ended.operations, out);
        try c.check(published, "store_recovery_dst_end_is_published");
        @memcpy(out[0..ended.len], ended.bytes[0..ended.len]);
        return .{ .operations = used + ended.operations, .crashed = false, .len = ended.len };
    }
    if (disk.crashed) return stoppedBy(disk, files, stats, disk.operations, out);
    @memcpy(out[0..disk.len], disk.bytes[0..disk.len]);
    return .{ .operations = disk.operations, .crashed = false, .len = disk.len };
}

/// The store actions of `journal`'s durable prefix: their number, each checked against the model's.
fn checkedActions(c: *kernel.Context, journal: []const u8, model: *const StoreRun, buffer: []u8) !u64 {
    var image: durable.Image = .{ .bytes = journal };
    var prefix = try durable.Prefix.init(image.disk(), buffer);
    var saved: u64 = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => |action| if (action.channel == effects.store_channel) {
            try c.check(saved < model.count, "store_recovery_dst_no_action_past_the_model");
            var expected_bytes: [96]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_bytes, "{{\"cell\":\":X\",\"key\":\"{s}\",\"value\":{d}}}", .{ key_names[model.saved[saved].key], model.saved[saved].value });
            try c.check(std.mem.eql(u8, action.text, expected), "store_recovery_dst_actions_are_the_models");
            saved += 1;
        },
        else => {},
    };
    return saved;
}

/// What the next run on the directory does with the rotated journal (P12), by the host's own
/// function: `active` brought up to its last record when a crash took it back along the chain.
fn confirmRotated(c: *kernel.Context, held: *store_lib.Store, journal: []const u8, reference: durable.StoreRef, buffer: []u8, stats: *RecoveryStats) !void {
    var image: durable.Image = .{ .bytes = journal };
    const repaired = publication.confirm(std.testing.allocator, held, image.disk(), buffer, reference) catch |problem| {
        std.debug.print("store recovery dst: confirm {s} ({s})\n", .{ @errorName(problem), held.why });
        try c.check(false, "store_recovery_dst_rotated_journal_is_confirmed");
        unreachable;
    };
    if (repaired) stats.repaired += 1;
}

/// A second session on `entries`: a fresh run that loads them does what the model says.
fn secondSession(c: *kernel.Context, b: *Bench, program: vtypes.Program, group: u32, ops: []const StoreOp, entries: Entries, buffer: []u8) !void {
    var texts: [2][24]u8 = undefined;
    var stored: [2]effects.Stored = undefined;
    var held: usize = 0;
    for (entries, &texts, 0..) |entry, *text, key| if (entry) |value| {
        stored[held] = .{ .request = effects.loadRequest(0, @intCast(3 + key)), .text = try std.fmt.bufPrint(text, "{d}", .{value}) };
        held += 1;
    };
    const kept = b.store;
    b.store = stored[0..held];
    defer b.store = kept;
    try b.run(program, group, .full, null, null, 0);
    try c.check(b.outcomes[0] and b.outcomes[1], "store_recovery_dst_second_session_completes");
    const second = simulateStore(ops, entries);
    try c.check(try checkedActions(c, b.disks[0].bytes[0..b.disks[0].len], &second, buffer) == second.count, "store_recovery_dst_second_session_saves_what_the_model_says");
}

const Journals = struct { first: [32 * 1024]u8, second: [32 * 1024]u8, third: [32 * 1024]u8, whole: [32 * 1024]u8 };

fn checkStoreRecovery(c: *kernel.Context, b: *Bench, rng: *kernel.Rng, stats: *RecoveryStats, journals: *Journals) !void {
    var ops: [12]StoreOp = undefined;
    const count: usize = @intCast(2 + rng.below(9));
    for (ops[0..count]) |*op| op.* = .{ .kind = @intCast(rng.below(4)), .key = @intCast(rng.below(2)), .constant = @as(i64, @intCast(rng.below(40))) - 10 };
    var initial: Entries = .{ null, null };
    for (&initial) |*entry| if (rng.below(3) != 0) {
        entry.* = @as(i64, @intCast(rng.below(30))) - 5;
    };
    var source_bytes: [4096]u8 = undefined;
    var source: std.Io.Writer = .fixed(&source_bytes);
    try storeSource(ops[0..count], &source);
    const program = switch (b.front.compile(source.buffered())) {
        .ok => |p| p,
        .failed => return error.Invariant,
    };
    var texts: [2][24]u8 = undefined;
    var stored: [2]effects.Stored = undefined;
    var held: usize = 0;
    for (initial, &texts, 0..) |entry, *text, key| if (entry) |value| {
        stored[held] = .{ .request = effects.loadRequest(0, @intCast(3 + key)), .text = try std.fmt.bufPrint(text, "{d}", .{value}) };
        held += 1;
    };
    // The store the run starts on: `initial` as a first session left it, the base of its header.
    var quiet: SimulatedDisk = .{};
    var base_files: CrashStore = .{ .sim = &quiet, .rng = .{ .state = rng.next() } };
    defer base_files.deinit();
    var seeded = base_files.handle();
    var initial_texts: [2][24]u8 = undefined;
    var updates: [2]store_lib.Updates.Update = undefined;
    var updated: usize = 0;
    for (initial, key_names, &initial_texts) |entry, who, *text| if (entry) |value| {
        updates[updated] = .{ .cell = ":X", .key = who, .text = @constCast(try std.fmt.bufPrint(text, "{d}", .{value})) };
        updated += 1;
    };
    // c1-2: the schema the header names is one the store holds, as `storage.prepare` writes it.
    const schema_text = try store_lib.schemaText(std.testing.allocator, &.{":X"});
    defer std.testing.allocator.free(schema_text);
    const schema = try seeded.putObject(schema_text);
    const base = try seeded.publish(null, schema, updates[0..updated]);
    const reference: durable.StoreRef = .{ .base = base orelse @splat(0), .schema = schema };
    const model = simulateStore(ops[0..count], initial);
    var buffer: [4096]u8 = undefined;
    const group: u32 = @intCast(1 + rng.below(4));
    // R8: every run is served the base's entries, whatever was published since it started.
    b.store = stored[0..held];
    defer b.store = &.{};
    b.header_store = reference;
    defer b.header_store = null;
    try b.run(program, group, .full, null, null, 0);
    try c.check(b.outcomes[0] and b.outcomes[1], "store_recovery_dst_runs_complete");
    const whole_len = b.disks[0].len;
    @memcpy(journals.whole[0..whole_len], b.disks[0].bytes[0..whole_len]);
    const operations = b.disks[0].operations;
    // c1-2: the run's journal with a header that names another schema: none the store holds, the
    // base's manifest, or an entry's object. Its publication is refused, and writes nothing; only a
    // plan that makes no generation (no base and no store action) reads no schema.
    var forgeries: [3]store_lib.Hash = undefined;
    var forged_count: usize = 0;
    for (&forgeries[0]) |*byte| byte.* = @truncate(rng.next());
    forged_count += 1;
    if (base) |named| {
        forgeries[forged_count] = named;
        forged_count += 1;
    }
    if (updated != 0) {
        forgeries[forged_count] = store_lib.hashOf(updates[@intCast(rng.below(updated))].text);
        forged_count += 1;
    }
    for (forgeries[0..forged_count]) |forged| {
        var files = CrashStore.copyOf(&base_files, &quiet, rng.next());
        defer files.deinit();
        const before = quiet.operations;
        var held_files = files.handle();
        var image: durable.Image = .{ .bytes = journals.whole[0..whole_len] };
        const refused = if (publication.plan(std.testing.allocator, &held_files, image.disk(), &buffer, .{ .base = reference.base, .schema = forged })) |made| refused: {
            var planned = made;
            defer planned.deinit();
            try c.check(planned.next == null and planned.behind == null, "store_recovery_dst_forged_schema_makes_nothing");
            break :refused false;
        } else |problem| refused: {
            try c.check(problem == error.StoreFailed and std.mem.eql(u8, held_files.why, publication.unschema), "store_recovery_dst_forged_schema_is_refused");
            break :refused true;
        };
        try c.check(quiet.operations == before and files.files.count() == base_files.files.count(), "store_recovery_dst_forged_schema_leaves_the_store");
        if (refused) stats.forged_schemas += 1;
    }
    var last_session: ?Entries = null;
    // Each crash point of the run, and the run that ended (its end not yet published).
    for (0..operations + 1) |point| {
        var first_len = whole_len;
        if (point < operations) {
            try b.run(program, group, .full, point, null, rng.next());
            first_len = b.disks[0].image_len;
            @memcpy(journals.first[0..first_len], b.disks[0].image[0..first_len]);
        } else @memcpy(journals.first[0..first_len], journals.whole[0..whole_len]);
        if (!(try scanBytes(journals.first[0..first_len], &buffer)).has_header) continue;
        const intent: Intent = if (rng.below(3) == 0) .abandon else .resume_run;
        // How many disk operations the command makes uncrashed, then a crash at each of them.
        var counting = CrashStore.copyOf(&base_files, &quiet, rng.next());
        defer counting.deinit();
        const total = (try storeCommand(c, b, program, group, intent, journals.first[0..first_len], &counting, reference, null, 0, stats, &journals.second)).operations;
        for (0..total) |at| {
            var files = CrashStore.copyOf(&base_files, &quiet, rng.next());
            defer files.deinit();
            stats.commands += 1;
            const crashed = try storeCommand(c, b, program, group, intent, journals.first[0..first_len], &files, reference, at, rng.next(), stats, &journals.second);
            try c.check(crashed.crashed, "store_recovery_dst_command_crashes_where_told");
            const found = try scanBytes(journals.second[0..crashed.len], &buffer);
            try c.check(found.has_header, "store_recovery_dst_crash_keeps_the_header");
            // A second command recovers it, uncrashed, then the next run checks the rotated journal.
            const again: Intent = if (found.finished() or rng.below(2) == 0) .resume_run else .abandon;
            const final = try storeCommand(c, b, program, group, again, journals.second[0..crashed.len], &files, reference, null, 0, stats, &journals.third);
            try c.check(!final.crashed, "store_recovery_dst_second_command_completes");
            const journal = journals.third[0..final.len];
            const ended = try scanBytes(journal, &buffer);
            try c.check(ended.finished(), "store_recovery_dst_journal_is_finished");
            if (rng.below(3) == 0 and files.replaced) {
                files.loseActive();
                stats.lost_active += 1;
            }
            if (rng.below(4) == 0 and files.loseGeneration()) stats.lost_generations += 1;
            if (rng.below(4) == 0) if (files.loseObject()) |how| {
                stats.lost_objects[@backingInt(how)] += 1;
            };
            files.sim = &quiet;
            var store = files.handle();
            try confirmRotated(c, &store, journal, reference, &buffer, stats);
            // JM1, JM5: the store is the uninterrupted run's at the commit point the journal reached.
            const saved = try checkedActions(c, journal, &model, &buffer);
            if (ended.end != null) try c.check(saved == model.count, "store_recovery_dst_ended_run_saved_everything");
            const expected = simulateStorePrefix(ops[0..count], initial, @intCast(saved));
            const got = try storeEntries(&store, try store.activeName());
            for (got, expected.entries) |entry, want| try c.check(std.meta.eql(entry, want), "store_recovery_dst_store_is_the_commit_points");
            // Every record names the generation its publication makes, and nothing is left.
            var image: durable.Image = .{ .bytes = journal };
            var checked = publication.plan(std.testing.allocator, &store, image.disk(), &buffer, reference) catch |problem| {
                std.debug.print("store recovery dst: check {s} ({s})\n", .{ @errorName(problem), store.why });
                try c.check(false, "store_recovery_dst_records_name_their_generations");
                unreachable;
            };
            defer checked.deinit();
            try c.check(checked.next == null and checked.behind == null, "store_recovery_dst_nothing_left_to_publish");
            stats.records += checked.records();
            if (last_session == null or !std.meta.eql(last_session.?, got)) {
                last_session = got;
                try secondSession(c, b, program, group, ops[0..count], got, &buffer);
                stats.sessions += 1;
            }
        }
    }
}

test "recovery of a store: publication, resume and abandon crashed at every disk operation, then recovered, hold the uninterrupted run's store at the commit point reached, and a second session loads it" {
    const b = try forbic.scratch.make(Bench);
    defer forbic.scratch.destroy(b);
    const journals = try std.testing.allocator.create(Journals);
    defer std.testing.allocator.destroy(journals);
    var c = kernel.Context.init(0x7075626c6973, .swarm);
    var stats: RecoveryStats = .{};
    for (0..12) |_| {
        checkStoreRecovery(&c, b, &c.rng, &stats, journals) catch |problem| {
            std.debug.print("store recovery dst failed ({s})\n", .{c.failure orelse ""});
            return problem;
        };
    }
    std.debug.print("store recovery dst: {d} commands crashed, {d} crashes, {d} active replacements and {d} generations lost, {d}/{d}/{d} objects lost/cut/changed, {d} repaired, {d} published again to the generation active named, {d} resumed, {d} abandoned, {d} records checked, {d} second sessions, {d} forged schemas refused\n", .{ stats.commands, stats.crashes, stats.lost_active, stats.lost_generations, stats.lost_objects[0], stats.lost_objects[1], stats.lost_objects[2], stats.repaired, stats.again, stats.resumed, stats.abandoned, stats.records, stats.sessions, stats.forged_schemas });
    try std.testing.expect(stats.commands > 1000 and stats.lost_active > 50 and stats.lost_generations > 50 and stats.repaired > 20 and stats.again > 20 and stats.abandoned > 100 and stats.sessions > 20);
    for (stats.lost_objects) |count| try std.testing.expect(count > 100);
    try std.testing.expect(stats.forged_schemas >= 24);
    try std.testing.expect(c.failure == null);
}
