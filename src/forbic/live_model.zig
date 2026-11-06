//! A test-only model of live variables (RFC-0084, P4.1, and P4.2's fields), ported from the design prototype
//! (`live_model.py`, not in the tree): cells with links, regions that keep the first value of
//! each cell they touch, records with stamps and heights, dependency entries made invalid by
//! stamps, propagation by (height, id) with its two bounds, and the count of entries that must
//! be kept. It is written as plainly as the prototype, with none of the machines' stores: an
//! entry is found by scanning, a dirty record by taking the least of a list.
//!
//! A generator writes random programs over five cells as Forbic text: `set`, `set live` with a
//! guard from a small grammar, and `Attempt` regions that commit or fail, nested twice. Both
//! machines run each one and must end where the model ends: the same cells and the same record,
//! or the same bound. Half the programs are acyclic by construction (a guard of a cell reads only
//! the cells before it) and must never reach a bound. The model checks the prototype's
//! invariants after every statement: I1 every comparable record is at its fixed point, I2 its
//! dependencies are exactly what its guard reads, I3 a region that fails leaves no trace, I6 a
//! program runs the same twice, I7 every record below the cap stands above what it reads, and I8
//! the entry count stays within `live_edges`.
//!
//! P4.3: a fifth of the programs declare the last two cells as one variable whose type is a
//! function, `var D->E:Shift = d` with `Shift(X:i64)<reads>:i64 = Max(-4, Min(4, X - A))`, at
//! the root or as fields of `O`. For the model that is a live-only `E` whose guard is the
//! grammar's third shape over `D` and `A`, attached where it is declared; the generator writes
//! `set E = v` and `set E = X`, which assign `D`, and attaches guards to `D` instead of `E`.
//!
//! P4.4: three programs in seven make reactions: `When(A + (k), Body)` and `Upon(B > k, Body)`
//! over the first three cells, at the start, as statements at the root, in regions and in the
//! visits of the frames. A body appends its letter to `Log` and, where cycles are allowed, writes
//! `C` first. The model keeps notifications on a pending list with a mark per region, delivers
//! at the points the RFC names (a program write, an establishing write, a commit to depth 0, the
//! end of a firing), fires in order, registers a `When` again after its body, holds what a region
//! makes until the outermost one commits and drops it when it fails (N1 to N5, R2, R3). It checks
//! I4 (nothing pending outside regions), I5 (no waiting `Upon`'s guard holds) and I2 for
//! reactions after every statement.
//!
//! P4.5: in those programs a statement may be a `Batch{...}` of statements, nested twice with
//! the regions: what they notify is delivered when the outermost batch ends, outside every
//! region, and a delivery point inside one delivers nothing.
//!
//! P4.6: a third of those reactions are awaiters instead, `Spawn{ Await(A > (k)); Body }`: a task
//! that evaluates its guard where it is started, goes on at once if it holds, and otherwise waits
//! on it. A notification wakes it to the ready queue (S4); it runs when the root has ended, in the
//! order it was woken, evaluates its guard again on the state as it is then (N7), and appends its
//! letter if it holds. The model checks I2 and I5 for waiting awaiters too, and the final log
//! with what the woken awaiters appended.
//!
//! P4.7: outside every region and batch, and where the program is not wrapped in one region,
//! a statement may be `Kn:task(void) = Spawn{ StopS(Q1) }` (or `StopV` for a `When`): a task
//! that runs by hand-off at once and cancels one of the two reactions made first (N6). One that
//! waits on its guard, or an awaiter waiting or woken, never goes on; its entries go at once, and
//! a spent `Upon` or an awaiter that went on is not changed.
//!
//! P4.8 (RFC-0085, I14): a quarter of the programs keep their cells in locals: the statements
//! stand in a block at the root, `Locals:tuple(...) = Block{ ...; tuple{A, B, C, D, E} }`, or in
//! a function that the root calls, `Run()`, each cell declared `var live A:i64 = v`, a constant
//! guard that a write detaches. So every local is shared (S1c) and every write of one is a
//! program write, as a module cell's is; guards, reactions, awaiters and batches name the locals
//! (S1b, S1d), and the cells outlive the function's frame through the reactions' closures. The
//! model's rules are the same for every cell; the machines must give its cells (read from the
//! tuple), logs and live record, and every such program that settles runs in every trace mode.
//!
//! I13 (RFC-0085, Q1): beside the cells, each of these programs has a plain `var Zed` that a
//! closure `Peek`, built before a later write, only names. Q1 shares it by that name, so `Peek`
//! reads the variable: the tuple's sixth element is `Peek() * 100 + Seen`, 1207 (a snapshot
//! gave 707), in every program, whatever the live machinery does around it.
const std = @import("std");
const types = @import("types.zig");
const scratch = @import("scratch.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");
const evaluator = @import("evaluator.zig");
const trace_replay = @import("trace_replay.zig");

const cell_count = 5;
const names = [cell_count][]const u8{ "A", "B", "C", "D", "E" };
const none = std.math.maxInt(u32);
/// P4.2: in a program of fields, the last two cells are the `var` fields of an instance `O`,
/// which the program writes, reads and attaches guards to as `O.D` and `O.E`. The model's rules
/// are the same for every cell (RFC-0084, L1 to L7).
const field_names = [cell_count][]const u8{ "A", "B", "C", "O.D", "O.E" };
const first_field = 3;
fn nameOf(cell: u8, fields: bool) []const u8 {
    return if (fields) field_names[cell] else names[cell];
}

/// A guard of the grammar: `a + k`, `If(b > 0, a, -a)`, `Max(-4, Min(4, a - b))` or `k`.
const Guard = struct {
    shape: u8,
    a: u8,
    b: u8,
    k: i64,

    fn text(self: Guard, out: *std.Io.Writer, fields: bool) !void {
        switch (self.shape) {
            0 => try out.print("{s} + ({d})", .{ nameOf(self.a, fields), self.k }),
            1 => try out.print("If({s} > 0, {s}, -{s})", .{ nameOf(self.b, fields), nameOf(self.a, fields), nameOf(self.a, fields) }),
            2 => try out.print("Max(-4, Min(4, {s} - {s}))", .{ nameOf(self.a, fields), nameOf(self.b, fields) }),
            else => try out.print("{d}", .{self.k}),
        }
    }
};

const Record = struct { target: u8, guard: Guard, alive: bool };
/// `reaction` says that `record` is the index of a reaction (P4.4), not of a record.
const Entry = struct { cell: u8, record: u32, stamp: u64, reaction: bool = false };
const Undo = struct { kind: enum { value, link, stamp, height }, index: u32, old: u64 };
const Region = struct {
    undo: std.ArrayList(Undo) = .empty,
    created: std.ArrayList(u32) = .empty,
    stamp_mark: u64,
    v0: u64,
    /// P4.4: the pending list's length when the region began, and the reactions it made.
    pending_mark: usize = 0,
    held: std.ArrayList(u32) = .empty,
};

/// A reaction (P4.4): `When(A + (k), Body)` or `Upon(A > k, Body)` over the cell `a`; its body
/// appends `letter` to the log and, with `writes`, first sets `C` to `Max(-4, Min(4, A - B + k))`.
const Reaction = struct {
    upon: bool,
    a: u8,
    k: i64,
    writes: bool,
    letter: u8,
    waiting: bool = false,
    stamp: u64 = 0,
    pending: bool = false,
    /// P4.6: an awaiter, `Spawn{ Await(A > (k)); Body }`; woken, it is on the ready list.
    awaits: bool = false,
    ready: bool = false,
    /// P4.7: cancelled while it waited on its guard, or while it was woken.
    canceled: bool = false,

    fn text(self: Reaction, out: *std.Io.Writer, local: u32) !void {
        if (self.awaits) return out.print("Q{d}:task(string) = Spawn{{ Await({s} > ({d})); Set(Log, Log + \"{c}\") }}\n", .{ local, names[self.a], self.k, self.letter });
        if (self.upon) try out.print("Q{d}:task(string) = Upon({s} > ({d}), ", .{ local, names[self.a], self.k }) else try out.print("Q{d}:task(void) = When({s} + ({d}), ", .{ local, names[self.a], self.k });
        if (self.writes) try out.print("Block{{ set C = Max(-4, Min(4, A - B + ({d}))); Set(Log, Log + \"{c}\") }})\n", .{ self.k, self.letter }) else try out.print("Set(Log, Log + \"{c}\"))\n", .{self.letter});
    }
};

pub const Outcome = union(enum) { ok, fatal: types.Diagnostic.Code };

pub const Model = struct {
    allocator: std.mem.Allocator,
    values: [cell_count]i64 = @splat(0),
    links: [cell_count]u32 = @splat(none),
    records: std.ArrayList(Record) = .empty,
    stamps: std.ArrayList(u64) = .empty,
    heights: std.ArrayList(u64) = .empty,
    stamp: u64 = 0,
    entries: std.ArrayList(Entry) = .empty,
    regions: std.ArrayList(Region) = .empty,
    live: types.Live = .{},
    tracking: ?*std.ArrayList(u8) = null,
    /// P4.4: the reactions made, the pending list, the log the bodies write, the firings under
    /// way and whether a delivery loop is.
    reactions: std.ArrayList(Reaction) = .empty,
    pending: std.ArrayList(u32) = .empty,
    /// P4.6: the awaiters woken, in order, which run when the root has ended; and how many
    /// awaiters went on after a wake, during the root's delivery or after it.
    ready: std.ArrayList(u32) = .empty,
    woke: u64 = 0,
    log: std.ArrayList(u8) = .empty,
    batch: u32 = 0,
    delivering: bool = false,
    created: u64 = 0,
    /// P4.7: the reactions a cancel stopped.
    stopped: u64 = 0,

    fn deinit(self: *Model) void {
        self.records.deinit(self.allocator);
        self.stamps.deinit(self.allocator);
        self.heights.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.regions.items) |*region| {
            region.undo.deinit(self.allocator);
            region.created.deinit(self.allocator);
            region.held.deinit(self.allocator);
        }
        self.regions.deinit(self.allocator);
        self.reactions.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.log.deinit(self.allocator);
    }

    fn journal(self: *Model, kind: @FieldType(Undo, "kind"), index: u32, old: u64) !void {
        if (self.regions.items.len == 0) return;
        const region = &self.regions.items[self.regions.items.len - 1];
        for (region.undo.items) |undo| if (undo.kind == kind and undo.index == index) return;
        try region.undo.append(self.allocator, .{ .kind = kind, .index = index, .old = old });
    }
    fn store(self: *Model, cell: u8, value: i64) !void {
        try self.journal(.value, cell, @bitCast(self.values[cell]));
        self.values[cell] = value;
    }
    fn link(self: *Model, cell: u8, record: u32) !void {
        try self.journal(.link, cell, self.links[cell]);
        self.links[cell] = record;
    }
    fn setStamp(self: *Model, record: u32, stamp: u64) !void {
        try self.journal(.stamp, record, self.stamps.items[record]);
        self.stamps.items[record] = stamp;
    }
    fn setHeight(self: *Model, record: u32, height: u64) !void {
        try self.journal(.height, record, self.heights.items[record]);
        self.heights.items[record] = height;
    }

    fn read(self: *Model, cell: u8) !i64 {
        if (self.tracking) |reads| {
            if (std.mem.indexOfScalar(u8, reads.items, cell) == null) try reads.append(self.allocator, cell);
        }
        return self.values[cell];
    }
    fn evaluate(self: *Model, guard: Guard, reads: *std.ArrayList(u8)) !i64 {
        reads.clearRetainingCapacity();
        self.tracking = reads;
        defer self.tracking = null;
        self.live.evaluations += 1;
        return switch (guard.shape) {
            0 => try self.read(guard.a) + guard.k,
            1 => if (try self.read(guard.b) > 0) try self.read(guard.a) else -(try self.read(guard.a)),
            2 => blk: {
                const difference = try self.read(guard.a) - try self.read(guard.b);
                break :blk @max(-4, @min(4, difference));
            },
            else => guard.k,
        };
    }

    fn valid(self: *const Model, entry: Entry) bool {
        if (entry.reaction) {
            const reaction = self.reactions.items[entry.record];
            return reaction.waiting and reaction.stamp == entry.stamp;
        }
        const record = self.records.items[entry.record];
        return record.alive and self.stamps.items[entry.record] == entry.stamp and self.links[record.target] == entry.record;
    }
    fn validCount(self: *const Model) u64 {
        var count: u64 = 0;
        for (self.entries.items) |entry| count += @intFromBool(self.valid(entry));
        return count;
    }
    fn countOf(self: *const Model, record: u32) u64 {
        var count: u64 = 0;
        for (self.entries.items) |entry| count += @intFromBool(!entry.reaction and entry.record == record and self.valid(entry));
        return count;
    }
    fn required(self: *const Model, old: u64, n: u64) u64 {
        if (self.regions.items.len == 0) return self.validCount() - old + n;
        const outermost = self.regions.items[0];
        var recorded: u64 = 0;
        for (self.entries.items) |entry| recorded += @intFromBool(entry.stamp > outermost.stamp_mark);
        return outermost.v0 + recorded + n;
    }
    /// L4: the stamp was taken when the guard began; the bound, then the entries.
    fn recordReads(self: *Model, record: u32, old: u64, stamp: u64, reads: []const u8) !void {
        if (self.required(old, reads.len) > types.limits.live_edges) return error.LiveEdgeLimit;
        try self.setStamp(record, stamp);
        for (reads) |cell| try self.entries.append(self.allocator, .{ .cell = cell, .record = record, .stamp = stamp });
        self.live.entries += reads.len;
    }
    /// Records with a valid entry for `cell`, in the order of the entries.
    fn readers(self: *const Model, cell: u8, out: *std.ArrayList(u32)) !void {
        out.clearRetainingCapacity();
        for (self.entries.items) |entry| if (!entry.reaction and entry.cell == cell and self.valid(entry)) try out.append(self.allocator, entry.record);
    }
    fn heightFor(self: *const Model, record: u32, own: u8, reads: []const u8) u64 {
        var top: u64 = 0;
        for (reads) |cell| {
            if (cell == own) continue;
            const attached = self.links[cell];
            if (attached != none and attached != record) top = @max(top, self.heights.items[attached]);
        }
        return @min(types.limits.live_height, top + 1);
    }
    /// L5: a worklist in the order the entries are found; a record waiting is not added again.
    fn raise(self: *Model, record: u32) !void {
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(self.allocator);
        var found: std.ArrayList(u32) = .empty;
        defer found.deinit(self.allocator);
        try work.append(self.allocator, record);
        var head: usize = 0;
        while (head < work.items.len) {
            const source = work.items[head];
            head += 1;
            const height = self.heights.items[source];
            try self.readers(self.records.items[source].target, &found);
            for (found.items) |reader| {
                const current = self.heights.items[reader];
                if (current > height or current >= types.limits.live_height) continue;
                try self.setHeight(reader, @min(types.limits.live_height, height + 1));
                if (std.mem.indexOfScalar(u32, work.items[head..], reader) == null) try work.append(self.allocator, reader);
            }
        }
    }

    fn detach(self: *Model, cell: u8) !void {
        if (self.links[cell] != none) try self.link(cell, none);
    }
    /// `set X = V` (L2).
    pub fn set(self: *Model, cell: u8, value: i64) !void {
        try self.detach(cell);
        try self.store(cell, value);
        try self.notify(cell);
        try self.propagate(cell);
        try self.deliver();
    }
    /// `set live X = G` (L2, establishing).
    pub fn setLive(self: *Model, cell: u8, guard: Guard) !void {
        var reads: std.ArrayList(u8) = .empty;
        defer reads.deinit(self.allocator);
        const record: u32 = @intCast(self.records.items.len);
        self.stamp += 1;
        const stamp = self.stamp;
        const value = try self.evaluate(guard, &reads);
        try self.records.append(self.allocator, .{ .target = cell, .guard = guard, .alive = true });
        try self.stamps.append(self.allocator, 0);
        try self.heights.append(self.allocator, 0);
        if (self.regions.items.len != 0) try self.regions.items[self.regions.items.len - 1].created.append(self.allocator, record);
        self.live.records += 1;
        try self.link(cell, record);
        try self.recordReads(record, 0, stamp, reads.items);
        try self.setHeight(record, self.heightFor(record, cell, reads.items));
        try self.raise(record);
        try self.store(cell, value);
        try self.notify(cell);
        try self.propagate(cell);
        try self.deliver();
    }
    /// L5 to L7.
    fn propagate(self: *Model, cell: u8) !void {
        self.live.propagations += 1;
        var dirty: std.ArrayList(u32) = .empty;
        defer dirty.deinit(self.allocator);
        var found: std.ArrayList(u32) = .empty;
        defer found.deinit(self.allocator);
        var counts: std.AutoHashMapUnmanaged(u32, u64) = .empty;
        defer counts.deinit(self.allocator);
        var reads: std.ArrayList(u8) = .empty;
        defer reads.deinit(self.allocator);
        try self.readers(cell, &found);
        for (found.items) |record| if (std.mem.indexOfScalar(u32, dirty.items, record) == null) try dirty.append(self.allocator, record);
        var total: u64 = 0;
        while (dirty.items.len != 0) {
            var best: usize = 0;
            for (dirty.items, 0..) |record, index| {
                const chosen = dirty.items[best];
                if (self.heights.items[record] < self.heights.items[chosen] or (self.heights.items[record] == self.heights.items[chosen] and record < chosen)) best = index;
            }
            const record = dirty.orderedRemove(best);
            const entry = try counts.getOrPut(self.allocator, record);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
            if (entry.value_ptr.* > types.limits.live_record_evaluations) return error.LiveUnstable;
            total += 1;
            if (total > types.limits.live_evaluations) return error.LivePropagationLimit;
            const target = self.records.items[record].target;
            self.stamp += 1;
            const stamp = self.stamp;
            const value = try self.evaluate(self.records.items[record].guard, &reads);
            try self.recordReads(record, self.countOf(record), stamp, reads.items);
            try self.setHeight(record, self.heightFor(record, target, reads.items));
            try self.raise(record);
            if (value == self.values[target]) continue;
            try self.store(target, value);
            try self.notify(target);
            try self.readers(target, &found);
            for (found.items) |reader| if (std.mem.indexOfScalar(u32, dirty.items, reader) == null) try dirty.append(self.allocator, reader);
        }
    }

    pub fn begin(self: *Model) !void {
        try self.regions.append(self.allocator, .{ .stamp_mark = self.stamp, .v0 = if (self.regions.items.len == 0) self.validCount() else 0, .pending_mark = self.pending.items.len });
    }
    pub fn commit(self: *Model) !void {
        var region = self.regions.pop().?;
        defer region.undo.deinit(self.allocator);
        defer region.created.deinit(self.allocator);
        defer region.held.deinit(self.allocator);
        if (self.regions.items.len == 0) {
            // N5: what the region made starts now, in order, each firing delivering; then the
            // commit delivers what is pending (N3).
            for (region.held.items) |reaction| {
                if (try self.start(reaction)) try self.deliver();
            }
            return self.deliver();
        }
        const parent = &self.regions.items[self.regions.items.len - 1];
        outer: for (region.undo.items) |undo| {
            for (parent.undo.items) |held| if (held.kind == undo.kind and held.index == undo.index) continue :outer;
            try parent.undo.append(self.allocator, undo);
        }
        try parent.created.appendSlice(self.allocator, region.created.items);
        try parent.held.appendSlice(self.allocator, region.held.items);
    }
    pub fn abort(self: *Model) void {
        var region = self.regions.pop().?;
        defer region.undo.deinit(self.allocator);
        defer region.created.deinit(self.allocator);
        defer region.held.deinit(self.allocator);
        // R2: what it notified is not notified; R3: what it made never starts.
        for (self.pending.items[region.pending_mark..]) |reaction| self.reactions.items[reaction].pending = false;
        self.pending.items.len = region.pending_mark;
        for (region.undo.items) |undo| switch (undo.kind) {
            .value => self.values[undo.index] = @bitCast(undo.old),
            .link => self.links[undo.index] = @intCast(undo.old),
            .stamp => self.stamps.items[undo.index] = undo.old,
            .height => self.heights.items[undo.index] = undo.old,
        };
        for (region.created.items) |record| self.records.items[record].alive = false;
        // R1: every entry the region recorded carries a stamp issued in it.
        var kept: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.stamp > region.stamp_mark) continue;
            self.entries.items[kept] = entry;
            kept += 1;
        }
        self.entries.items.len = kept;
    }

    // Reactions (P4.4).

    fn guardOf(self: *Model, reaction: Reaction, reads: *std.ArrayList(u8)) !bool {
        reads.clearRetainingCapacity();
        self.tracking = reads;
        defer self.tracking = null;
        const value = try self.read(reaction.a);
        return !(reaction.upon or reaction.awaits) or value > reaction.k;
    }
    /// The guard of reaction `index`, with tracking: the reaction waits on it with what it read.
    fn observe(self: *Model, index: u32) !bool {
        var reads: std.ArrayList(u8) = .empty;
        defer reads.deinit(self.allocator);
        self.stamp += 1;
        const stamp = self.stamp;
        self.live.evaluations += 1;
        const succeeded = try self.guardOf(self.reactions.items[index], &reads);
        var old: u64 = 0;
        for (self.entries.items) |entry| old += @intFromBool(entry.reaction and entry.record == index and self.valid(entry));
        if (self.required(old, reads.items.len) > types.limits.live_edges) return error.LiveEdgeLimit;
        self.reactions.items[index].stamp = stamp;
        for (reads.items) |cell| try self.entries.append(self.allocator, .{ .cell = cell, .record = index, .stamp = stamp, .reaction = true });
        self.live.entries += reads.items.len;
        return succeeded;
    }
    /// N1: the reactions waiting on `cell`, in the order of their entries, join the pending list.
    fn notify(self: *Model, cell: u8) !void {
        for (self.entries.items) |entry| {
            if (!entry.reaction or entry.cell != cell or !self.valid(entry)) continue;
            const reaction = &self.reactions.items[entry.record];
            if (reaction.pending) continue;
            reaction.pending = true;
            try self.pending.append(self.allocator, entry.record);
        }
    }
    /// N4: the body runs inside a batch; an `Upon` is spent, a `When` waits on its guard again.
    fn fire(self: *Model, index: u32) !void {
        self.reactions.items[index].waiting = false;
        self.live.firings += 1;
        self.batch += 1;
        const reaction = self.reactions.items[index];
        if (reaction.writes) try self.set(2, @max(-4, @min(4, self.values[0] - self.values[1] + reaction.k)));
        // The write of `Log` is a program write too, a propagation from a cell nothing reads.
        try self.log.append(self.allocator, reaction.letter);
        self.live.propagations += 1;
        self.batch -= 1;
        if (reaction.upon) return;
        self.reactions.items[index].waiting = true;
        _ = try self.observe(index);
    }
    /// P4.6: an awaiter whose guard holds stops waiting, and its body appends its letter: a
    /// program write of `Log`, a propagation from a cell nothing reads.
    fn proceed(self: *Model, index: u32) !void {
        self.reactions.items[index].waiting = false;
        try self.log.append(self.allocator, self.reactions.items[index].letter);
        self.live.propagations += 1;
    }
    /// N5: a reaction starts outside every region: it waits on its guard and fires if it holds.
    /// Whether it fired, or from P4.6, for an awaiter, whether it went on and wrote.
    fn start(self: *Model, index: u32) !bool {
        self.created += 1;
        self.reactions.items[index].waiting = true;
        if (!try self.observe(index)) return false;
        if (self.reactions.items[index].awaits) {
            try self.proceed(index);
            return true;
        }
        try self.fire(index);
        return true;
    }
    /// N3, N4: a delivery point, outside every region, batch and loop.
    fn deliver(self: *Model) anyerror!void {
        if (self.regions.items.len != 0 or self.batch != 0 or self.delivering) return;
        self.delivering = true;
        defer self.delivering = false;
        var count: u64 = 0;
        while (self.pending.items.len != 0) {
            const index = self.pending.orderedRemove(0);
            self.reactions.items[index].pending = false;
            count += 1;
            if (count > types.limits.deliveries) return error.ReactionLimit;
            self.live.deliveries += 1;
            if (!self.reactions.items[index].waiting) continue;
            if (self.reactions.items[index].awaits) {
                // P4.6: woken, it stops waiting and joins the ready queue.
                self.reactions.items[index].waiting = false;
                self.reactions.items[index].ready = true;
                try self.ready.append(self.allocator, index);
                continue;
            }
            if (try self.observe(index)) try self.fire(index);
        }
    }
    /// P4.5: a batch opens; what is notified while one is open is delivered when the outermost
    /// one ends, which is a delivery point.
    pub fn openBatch(self: *Model) void {
        self.batch += 1;
    }
    pub fn closeBatch(self: *Model) !void {
        std.debug.assert(self.batch != 0);
        self.batch -= 1;
        try self.deliver();
    }
    /// A reaction made by the program: started now, or held by the innermost region.
    pub fn react(self: *Model, reaction: Reaction) !void {
        const index: u32 = @intCast(self.reactions.items.len);
        try self.reactions.append(self.allocator, reaction);
        if (self.regions.items.len != 0) return self.regions.items[self.regions.items.len - 1].held.append(self.allocator, index);
        if (try self.start(index)) try self.deliver();
    }

    /// P4.7 (N6): a task made outside every region and batch asks reaction `index` to cancel,
    /// and completes. A reaction waiting on its guard, or an awaiter waiting or woken, stops:
    /// its entries are invalid from now on, and a notification still pending for it delivers
    /// nothing. A spent `Upon` and an awaiter that went on are not changed.
    pub fn cancel(self: *Model, index: u32) void {
        std.debug.assert(self.regions.items.len == 0 and self.batch == 0);
        self.created += 1;
        const reaction = &self.reactions.items[index];
        if (!reaction.waiting and !reaction.ready) return;
        reaction.waiting = false;
        reaction.ready = false;
        reaction.canceled = true;
        self.stopped += 1;
    }

    /// P4.6: when the root has ended, the woken awaiters run in the order they were woken, each
    /// evaluating its guard again on the state as it is then.
    pub fn runReady(self: *Model) !void {
        std.debug.assert(self.regions.items.len == 0);
        var at: usize = 0;
        while (at < self.ready.items.len) : (at += 1) {
            const index = self.ready.items[at];
            // P4.7: one cancelled after it was woken yields cancelled where it waited.
            if (self.reactions.items[index].canceled) continue;
            self.reactions.items[index].ready = false;
            self.reactions.items[index].waiting = true;
            if (!try self.observe(index)) continue;
            self.woke += 1;
            try self.proceed(index);
            try self.deliver();
        }
        self.ready.clearRetainingCapacity();
    }

    /// I1, I2, I7 and I8, outside every region; from P4.4 I4, I5 and I2 for reactions.
    pub fn check(self: *Model) !void {
        std.debug.assert(self.regions.items.len == 0);
        var reads: std.ArrayList(u8) = .empty;
        defer reads.deinit(self.allocator);
        const saved = self.live;
        defer self.live = saved;
        try std.testing.expectEqual(@as(usize, 0), self.pending.items.len);
        for (self.reactions.items, 0..) |reaction, index| {
            if (!reaction.waiting) continue;
            const holds = try self.guardOf(reaction, &reads);
            if (reaction.upon or reaction.awaits) try std.testing.expect(!holds);
            var deps: [cell_count]bool = @splat(false);
            for (self.entries.items) |entry| if (entry.reaction and entry.record == index and self.valid(entry)) {
                deps[entry.cell] = true;
            };
            var expected: [cell_count]bool = @splat(false);
            for (reads.items) |cell| expected[cell] = true;
            try std.testing.expectEqualSlices(bool, &expected, &deps);
        }
        for (self.records.items, 0..) |record, index| {
            const id: u32 = @intCast(index);
            if (!record.alive or self.links[record.target] != id) continue;
            const value = try self.evaluate(record.guard, &reads);
            try std.testing.expectEqual(self.values[record.target], value);
            var deps: [cell_count]bool = @splat(false);
            for (self.entries.items) |entry| if (!entry.reaction and entry.record == id and self.valid(entry)) {
                deps[entry.cell] = true;
            };
            var expected: [cell_count]bool = @splat(false);
            for (reads.items) |cell| expected[cell] = true;
            try std.testing.expectEqualSlices(bool, &expected, &deps);
            for (reads.items) |cell| {
                const other = self.links[cell];
                if (other != none and other != id and self.heights.items[id] < types.limits.live_height) try std.testing.expect(self.heights.items[id] > self.heights.items[other]);
            }
        }
        try std.testing.expect(self.required(0, 0) <= types.limits.live_edges);
    }
    /// What a region that fails must leave as it found: values, links and dependencies.
    fn snapshot(self: *const Model) [3 * cell_count + 1]u64 {
        var out: [3 * cell_count + 1]u64 = undefined;
        for (0..cell_count) |cell| {
            out[cell] = @bitCast(self.values[cell]);
            out[cell_count + cell] = self.links[cell];
            var mask: u64 = 0;
            if (self.links[cell] != none) {
                for (self.entries.items) |entry| if (!entry.reaction and entry.record == self.links[cell] and self.valid(entry)) {
                    mask |= @as(u64, 1) << @intCast(entry.cell);
                };
            }
            out[2 * cell_count + cell] = mask;
        }
        out[3 * cell_count] = self.validCount();
        return out;
    }
};

/// One generated program: its text, and the model's run of it.
/// `log` is the log as the root reads it at its end; `final_log`, from P4.6, what the woken
/// awaiters appended to it after the root.
const Generated = struct { outcome: Outcome, values: [cell_count]i64, live: types.Live, log: [256]u8 = @splat(0), log_length: usize = 0, created: u64 = 0, final_log: [256]u8 = @splat(0), final_length: usize = 0, woke: u64 = 0, stopped: u64 = 0 };
fn generated(model: *const Model, outcome: Outcome) Generated {
    var out: Generated = .{ .outcome = outcome, .values = model.values, .live = model.live, .created = model.created, .stopped = model.stopped };
    out.log_length = @min(out.log.len, model.log.items.len);
    @memcpy(out.log[0..out.log_length], model.log.items[0..out.log_length]);
    out.final_length = out.log_length;
    @memcpy(out.final_log[0..out.final_length], model.log.items[0..out.final_length]);
    return out;
}

fn randomGuard(random: std.Random, below: ?u8) Guard {
    const pool: u8 = below orelse cell_count;
    const a: u8 = if (pool == 0) 0 else random.uintLessThan(u8, pool);
    const b: u8 = if (pool == 0) 0 else random.uintLessThan(u8, pool);
    var shape = random.uintLessThan(u8, 4);
    if (pool == 0) shape = 3;
    return .{ .shape = shape, .a = a, .b = b, .k = random.intRangeAtMost(i64, -2, 2) };
}

const Writer = struct {
    out: *std.Io.Writer,
    locals: u32 = 0,
    /// The last cells are fields of `O` (P4.2).
    fields: bool = false,
    /// The last two cells are one variable whose type is a function (P4.3): `E` follows
    /// `Shift(D)`, and assigning `E` assigns `D`.
    typed: bool = false,
    /// P4.4: the program makes reactions, and how many it has made; whether their bodies may
    /// write `C`.
    reactive: bool = false,
    reactions: u8 = 0,
    writes: bool = false,
    /// P4.7: statements outside every region may cancel the first two reactions.
    cancels: bool = false,
    /// P4.8: the first cells are locals of a block (or of a function) around the statements.
    holder: Locals = .none,

    /// The cell a program write of `cell` assigns.
    fn assigned(self: Writer, cell: u8) u8 {
        return if (self.typed and cell == 4) 3 else cell;
    }
};
/// The guard `E` follows in a program whose type is a function (P4.3).
const shift_guard: Guard = .{ .shape = 2, .a = 3, .b = 0, .k = 0 };

/// One statement, written and run by the model. `depth` counts the regions around it.
fn statement(model: *Model, random: std.Random, acyclic: bool, depth: u32, w: *Writer, indent: u32) anyerror!void {
    const choice = random.uintLessThan(u8, 8);
    for (0..indent) |_| try w.out.writeAll("    ");
    if (choice <= 2) {
        const cell = random.uintLessThan(u8, cell_count);
        const value = random.intRangeAtMost(i64, -3, 3);
        try w.out.print("set {s} = {d}\n", .{ nameOf(cell, w.fields), value });
        return model.set(w.assigned(cell), value);
    }
    if (choice == 3 or choice == 4) {
        // `E` follows its type's function; a guard is attached to its raw value `D` instead.
        const cell: u8 = w.assigned(if (acyclic) random.intRangeAtMost(u8, 1, cell_count - 1) else random.uintLessThan(u8, cell_count));
        const guard = randomGuard(random, if (acyclic) cell else null);
        try w.out.print("set live {s} = ", .{nameOf(cell, w.fields)});
        try guard.text(w.out, w.fields);
        try w.out.writeByte('\n');
        return model.setLive(cell, guard);
    }
    if (choice <= 6 and depth < 2) {
        const fail = random.boolean();
        const count = random.intRangeAtMost(u8, 1, 3);
        w.locals += 1;
        try w.out.print("R{d}:logic = Attempt(Block{{\n", .{w.locals});
        const before = model.snapshot();
        try model.begin();
        for (0..count) |_| statement(model, random, acyclic, depth + 1, w, indent + 1) catch |err| {
            // A bound ends the run inside the region; the text still has to close.
            try closeRegion(w, indent, fail);
            return err;
        };
        try closeRegion(w, indent, fail);
        if (fail) {
            model.abort();
            // I3: a region that fails leaves no trace.
            const after = model.snapshot();
            try std.testing.expectEqualSlices(u64, &before, &after);
        } else try model.commit();
        return;
    }
    // P4.7: a task that cancels one of the two reactions made first, outside every region.
    if (w.cancels and depth == 0 and random.uintLessThan(u8, 3) == 0) {
        const target = random.uintLessThan(u32, 2);
        const reaction = model.reactions.items[target];
        w.locals += 1;
        try w.out.print("K{d}:task(void) = Spawn{{ Stop{s}(Q{d}) }}\n", .{ w.locals, if (reaction.upon or reaction.awaits) "S" else "V", target + 1 });
        model.cancel(target);
        return;
    }
    // P4.4: a reaction, where the program makes them.
    if (w.reactive and w.reactions < 4 and random.uintLessThan(u8, 3) == 0) {
        const reaction = randomReaction(random, w);
        w.locals += 1;
        try reaction.text(w.out, w.locals);
        return model.react(reaction);
    }
    // P4.5: a batch of statements, where the program makes reactions.
    if (w.reactive and depth < 2 and random.boolean()) {
        const count = random.intRangeAtMost(u8, 1, 3);
        w.locals += 1;
        try w.out.print("B{d}:logic = Batch{{\n", .{w.locals});
        model.openBatch();
        for (0..count) |_| statement(model, random, acyclic, depth + 1, w, indent + 1) catch |err| {
            // A bound ends the run inside the batch; the text still has to close.
            try closeBatch(w, indent);
            return err;
        };
        try closeBatch(w, indent);
        return model.closeBatch();
    }
    // A set of one cell to another's value.
    const cell = random.uintLessThan(u8, cell_count);
    const from = random.uintLessThan(u8, cell_count);
    try w.out.print("set {s} = {s}\n", .{ nameOf(cell, w.fields), nameOf(from, w.fields) });
    return model.set(w.assigned(cell), model.values[from]);
}
fn closeRegion(w: *Writer, indent: u32, fail: bool) !void {
    for (0..indent + 1) |_| try w.out.writeAll("    ");
    if (fail) try w.out.writeAll("Require[false]\n");
    for (0..indent + 1) |_| try w.out.writeAll("    ");
    try w.out.writeAll("true\n");
    for (0..indent) |_| try w.out.writeAll("    ");
    try w.out.writeAll("}, false)\n");
}

fn closeBatch(w: *Writer, indent: u32) !void {
    for (0..indent + 1) |_| try w.out.writeAll("    ");
    try w.out.writeAll("true\n");
    for (0..indent) |_| try w.out.writeAll("    ");
    try w.out.writeAll("}\n");
}

fn randomReaction(random: std.Random, w: *Writer) Reaction {
    const letter = "abcdefgh"[w.reactions];
    w.reactions += 1;
    var reaction: Reaction = .{ .upon = random.boolean(), .a = random.uintLessThan(u8, 3), .k = random.intRangeAtMost(i64, -2, 2), .writes = w.writes and random.boolean(), .letter = letter };
    // P4.6: a third of them are awaiters.
    if (random.uintLessThan(u8, 3) == 0) reaction = .{ .upon = false, .a = reaction.a, .k = reaction.k, .writes = false, .letter = letter, .awaits = true };
    return reaction;
}

fn codeOf(err: anyerror) types.Diagnostic.Code {
    return switch (err) {
        error.LiveUnstable => .live_unstable,
        error.LivePropagationLimit => .live_propagation_limit,
        error.LiveEdgeLimit => .live_edge_limit,
        error.ReactionLimit => .reaction_limit,
        else => unreachable,
    };
}

/// How the statements of a generated program stand: at the root; each in the visit of a root
/// loop that also builds an array, so that frames end over the records, entries and regions it
/// makes and digest runs reclaim them; or so, all inside one region that commits, where the
/// loop's reclamations run with regions open and the entries their inner regions took off.
pub const Frame = enum { root, framed, in_region };
/// P4.8: where the cells that are not fields are declared: module cells, locals of a block at the
/// root, or locals of a function the root calls.
pub const Locals = enum { none, block, function };

/// Ends the block or the function that holds the locals, with the tuple of the five cells and
/// the sixth element of I13: what a closure that only reads a plain local saw of it.
fn closeLocals(out: *std.Io.Writer, locals: Locals, fields: bool) !void {
    if (locals == .none) return;
    try out.writeAll("tuple{");
    for (0..cell_count) |cell| try out.print("{s}{s}", .{ if (cell == 0) "" else ", ", nameOf(@intCast(cell), fields) });
    try out.writeAll(", Peek() * 100 + Seen}\n}\n");
    if (locals == .function) try out.writeAll("Locals:tuple(i64, i64, i64, i64, i64, i64) = Run()\n");
}

/// RFC-0085, I13 (Q1): beside the live cells, a plain local `Zed` that a closure built before
/// its later write only names: `Peek` is shared by that name and reads the variable (12), where
/// the snapshot of RFC-0054 gave the value it had when `Peek` was built (7). `Seen` is that value.
const plain_local = "var Zed:i64 = 7\nPeek := Fn()<reads>:i64{ Zed }\nSeen:i64 = Peek()\nset Zed = Zed + 5\n";
/// What the tuple's sixth element is: `Peek() * 100 + Seen`.
const plain_local_result: i64 = 12 * 100 + 7;

/// Writes the program of `seed` into `out` and runs it on the model.
pub fn generate(seed: u64, out: *std.Io.Writer, statements: usize, frame: Frame) !Generated {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var model: Model = .{ .allocator = std.testing.allocator };
    defer model.deinit();
    const acyclic = seed % 2 == 0;
    const fields = hasFields(seed);
    const locals = localsOf(seed);
    const typed = hasType(seed) and locals == .none;
    for (0..cell_count) |cell| {
        model.values[cell] = random.intRangeAtMost(i64, -3, 3);
        if (locals == .none and (!fields or cell < first_field) and (!typed or cell < 3)) try out.print("var {s}:i64 = {d}\n", .{ names[cell], model.values[cell] });
    }
    const reactive = hasReactions(seed);
    if (reactive) try out.writeAll("var Log:string = \"\"\nStopS(T:task(string))<transacts><suspends>:void = T.Cancel()\nStopV(T:task(void))<transacts><suspends>:void = T.Cancel()\n");
    if (typed) try out.writeAll("Shift(X:i64)<reads>:i64 = Max(-4, Min(4, X - A))\n");
    if (typed and !fields) try out.print("var D->E:Shift = {d}\n", .{model.values[3]});
    if (fields and typed) try out.print("box := class{{ var D->E:Shift = {d} }}\nO:box = box{{}}\n", .{model.values[3]});
    if (fields and !typed) try out.print("box := class{{ var D:i64 = {d}; var E:i64 = {d} }}\nO:box = box{{}}\n", .{ model.values[3], model.values[4] });
    // The declaration of `E` attaches its guard (P4.3): at its cell, or in the construction.
    if (typed) model.setLive(4, shift_guard) catch |err| return generated(&model, .{ .fatal = codeOf(err) });
    // P4.8: the locals, each a `var live` of a constant, which its cell takes when it is made.
    switch (locals) {
        .none => {},
        .block => try out.writeAll("Locals:tuple(i64, i64, i64, i64, i64, i64) = Block{\n"),
        .function => try out.writeAll("Run()<transacts>:tuple(i64, i64, i64, i64, i64, i64) = Block{\n"),
    }
    if (locals != .none) for (0..cell_count) |cell| {
        if (fields and cell >= first_field) continue;
        const constant: Guard = .{ .shape = 3, .a = 0, .b = 0, .k = model.values[cell] };
        try out.print("var live {s}:i64 = {d}\n", .{ names[cell], constant.k });
        model.values[cell] = 0;
        model.setLive(@intCast(cell), constant) catch |err| return generated(&model, .{ .fatal = codeOf(err) });
    };
    if (locals != .none) try out.writeAll(plain_local);
    var w: Writer = .{ .out = out, .fields = fields, .typed = typed, .reactive = reactive, .writes = !acyclic, .cancels = reactive and frame != .in_region, .holder = locals };
    // P4.4: two reactions made before the statements.
    if (reactive) for (0..2) |_| {
        const reaction = randomReaction(random, &w);
        w.locals += 1;
        try reaction.text(out, w.locals);
        model.react(reaction) catch |err| return generated(&model, .{ .fatal = codeOf(err) });
    };
    const framed = frame != .root;
    const outer: u32 = @intFromBool(frame == .in_region);
    if (outer != 0) {
        try out.writeAll("Outer:logic = Attempt(Block{\n");
        try model.begin();
    }
    for (0..statements) |index| {
        if (framed) try out.print("F{d}:[]i64 = For(K:1..1, Block{{\n", .{index});
        statement(&model, random, acyclic, 0, &w, @intFromBool(framed) + outer) catch |err| switch (err) {
            error.LiveUnstable, error.LivePropagationLimit, error.LiveEdgeLimit, error.ReactionLimit => {
                if (framed) try out.writeAll("    K\n})\n");
                if (outer != 0) try out.writeAll("true\n}, false)\n");
                try closeLocals(out, locals, fields);
                return generated(&model, .{ .fatal = codeOf(err) });
            },
            else => return err,
        };
        if (framed) try out.writeAll("    G:[]i64 = array{K, K, K, K, K, K, K, K}\n    G.Length\n})\n");
        if (outer == 0) try model.check();
    }
    if (outer != 0) {
        try out.writeAll("true\n}, false)\n");
        model.commit() catch |err| switch (err) {
            error.LiveUnstable, error.LivePropagationLimit, error.LiveEdgeLimit, error.ReactionLimit => {
                try closeLocals(out, locals, fields);
                return generated(&model, .{ .fatal = codeOf(err) });
            },
            else => return err,
        };
        try model.check();
    }
    try closeLocals(out, locals, fields);
    if (reactive) try out.writeAll("FinalLog:string = Log\n");
    var result = generated(&model, .ok);
    // P4.6: the awaiters woken during the root run once it has ended.
    model.runReady() catch |err| return generated(&model, .{ .fatal = codeOf(err) });
    result.live = model.live;
    // I13: `set Zed` is a program write of a cell, which the machines count as a propagation
    // (nothing follows it); the model has no cell for it.
    if (locals != .none) result.live.propagations += 1;
    result.woke = model.woke;
    result.final_length = @min(result.final_log.len, model.log.items.len);
    @memcpy(result.final_log[0..result.final_length], model.log.items[0..result.final_length]);
    return result;
}

/// Both machines stop with `code` at one place in a run that keeps no steps.
fn expectOff(source: []const u8, code: types.Diagnostic.Code) !void {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    f.mode(.off, types.ControlStorage.default_trace_window);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, live_tests.fuel);
    const actual = f.h.runtime.evaluate(p, live_tests.fuel);
    if (reference != .failed or actual != .failed) return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, reference.failed.code);
    try std.testing.expectEqual(code, actual.failed.code);
    try std.testing.expectEqualDeep(reference.failed.span, actual.failed.span);
}

/// Three in seven make reactions (P4.4).
fn hasReactions(seed: u64) bool {
    return seed % 7 < 3;
}

/// A third of the programs keep two of their cells in an instance's fields (P4.2).
fn hasFields(seed: u64) bool {
    return seed % 3 == 2;
}
/// P4.8: a quarter keep their cells in locals, half of those in a function's frame. A local
/// cannot be a variable whose type is a function (RFC-0084 C41), so these programs have none.
fn localsOf(seed: u64) Locals {
    // Even seeds are acyclic, odd ones not: each kind of local program has both.
    return switch (seed % 16) {
        2, 3 => .block,
        10, 11 => .function,
        else => .none,
    };
}
/// A fifth declare two of them as one variable whose type is a function (P4.3).
fn hasType(seed: u64) bool {
    // Every tenth program, which also runs in every mode and in frames, is one of them.
    return seed % 5 == 1;
}
/// The log as the run ends, after the tasks that ran when the root had ended (P4.6).
fn finalLog(execution: evaluator.Execution) []const u8 {
    for (execution.program.source_cells, 0..) |cell, index| if (std.mem.eql(u8, cell.name.text(execution.program.source), "Log")) return execution.cells[index].value.string;
    unreachable;
}
/// The final value of the model's cell `cell` in a run of a generated program.
fn finalValue(execution: anytype, seed: u64, cell: usize) i64 {
    // P4.8: the locals, as the block or the function hands them on.
    if (localsOf(seed) != .none) return execution.elements(execution.get("Locals").?).?[cell].integer;
    if (!hasFields(seed) or cell < first_field) return execution.get(names[cell]).?.integer;
    return execution.fields(execution.get("O").?).?[cell - first_field].value.integer;
}
pub fn runOracle(count: u64, every_mode: u64) !void {
    const h = try harness.create();
    defer scratch.release(h);
    const buffer = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(buffer);
    var outcomes: [5]u64 = @splat(0);
    var reclaims: u64 = 0;
    // P4.5: the programs that hold a batch.
    var batched: u64 = 0;
    // P4.6: awaiters that went on after a wake, in the programs that settled.
    var woke: u64 = 0;
    // P4.7: reactions a cancel stopped, in the programs that settled.
    var stopped: u64 = 0;
    // P4.8: the programs over locals that settled, each also run in every trace mode.
    var local_programs: u64 = 0;
    for (0..count) |seed| {
        var out: std.Io.Writer = .fixed(buffer);
        const expected = try generate(seed, &out, 24, .root);
        // I6: the same program, the same run.
        var again_buffer: [64 * 1024]u8 = undefined;
        var again_out: std.Io.Writer = .fixed(&again_buffer);
        const again = try generate(seed, &again_out, 24, .root);
        try std.testing.expectEqualStrings(out.buffered(), again_out.buffered());
        try std.testing.expectEqualDeep(expected, again);
        const source = out.buffered();
        if (std.mem.indexOf(u8, source, "Batch{") != null) batched += 1;
        if (seed % 2 == 0) try std.testing.expect(expected.outcome == .ok);
        const p = h.compile(source) catch |err| {
            std.debug.print("{s}\n", .{source});
            return err;
        };
        const outcome = try h.run(p, live_tests.fuel);
        switch (expected.outcome) {
            .ok => {
                if (outcome != .ok) {
                    std.debug.print("seed {d}: the model ran, the machines stopped with {t}\n{s}\n", .{ seed, outcome.failed.code, source });
                    return error.TestUnexpectedResult;
                }
                for (expected.values, 0..) |value, cell| try std.testing.expectEqual(value, finalValue(outcome.ok, seed, cell));
                // I13: the closure that only names a plain local reads the variable.
                if (localsOf(seed) != .none) try std.testing.expectEqual(plain_local_result, outcome.ok.elements(outcome.ok.get("Locals").?).?[cell_count].integer);
                if (hasReactions(seed)) {
                    try std.testing.expectEqualStrings(expected.log[0..expected.log_length], outcome.ok.get("FinalLog").?.string);
                    try std.testing.expectEqualStrings(expected.final_log[0..expected.final_length], finalLog(outcome.ok));
                    try std.testing.expectEqual(expected.created, outcome.ok.scheduler.created);
                }
                std.testing.expectEqualDeep(expected.live, outcome.ok.live) catch |err| {
                    std.debug.print("seed {d}: model {any}\n{s}\n", .{ seed, expected.live, source });
                    return err;
                };
                outcomes[0] += 1;
                woke += expected.woke;
                stopped += expected.stopped;
                // P4.8: every program over locals that settles, in every trace mode, its report
                // admitted by the replay.
                if (localsOf(seed) != .none) {
                    local_programs += 1;
                    reclaims += live_tests.everyMode(source) catch |err| {
                        std.debug.print("seed {d} (locals) in every mode\n{s}\n", .{ seed, source });
                        return err;
                    };
                }
                if (seed % every_mode == 1) {
                    try live_tests.expectEveryMode(source);
                    // The same statements in frames that end, reclaiming in digest runs, at
                    // the root and inside a region.
                    for ([_]Frame{ .framed, .in_region }) |frame| {
                        var framed_out: std.Io.Writer = .fixed(&again_buffer);
                        // A reactive program in frames has fewer statements: its guards, bodies and visits are
                        // functions, which the bootstrap profile counts.
                        const framed_expected = try generate(seed, &framed_out, if (hasReactions(seed)) 12 else 24, frame);
                        // Inside one region, reactions are delivered only when it commits (P4.4):
                        // such a program is checked against its own run of the model.
                        if (!hasReactions(seed)) try std.testing.expectEqualDeep(expected, framed_expected);
                        if (framed_expected.outcome != .ok) continue;
                        const framed = framed_out.buffered();
                        const run = h.run(try h.compile(framed), live_tests.fuel) catch |err| {
                            std.debug.print("seed {d} {t}\n{s}\n", .{ seed, frame, framed });
                            return err;
                        };
                        if (run != .ok) {
                            std.debug.print("seed {d} {t}: {t}\n{s}\n", .{ seed, frame, run.failed.code, framed });
                            return error.TestUnexpectedResult;
                        }
                        try std.testing.expectEqualDeep(framed_expected.live, run.ok.live);
                        for (framed_expected.values, 0..) |value, cell| try std.testing.expectEqual(value, finalValue(run.ok, seed, cell));
                        if (hasReactions(seed)) try std.testing.expectEqualStrings(framed_expected.log[0..framed_expected.log_length], run.ok.get("FinalLog").?.string);
                        if (hasReactions(seed)) try std.testing.expectEqualStrings(framed_expected.final_log[0..framed_expected.final_length], finalLog(run.ok));
                        reclaims += try live_tests.everyMode(framed);
                    }
                }
            },
            .fatal => |code| {
                // A full run would keep the steps of every delivery and stop at the trace bound
                // first: a run that ends at `reaction_limit` is compared in a run that keeps none.
                if (code == .reaction_limit) {
                    try expectOff(source, code);
                    outcomes[4] += 1;
                    continue;
                }
                if (outcome != .failed or outcome.failed.code != code) {
                    std.debug.print("seed {d}: the model stopped with {t}, the machines with {s}\n{s}\n", .{ seed, code, if (outcome == .ok) "nothing" else @tagName(outcome.failed.code), source });
                    return error.TestUnexpectedResult;
                }
                outcomes[
                    @as(usize, switch (code) {
                        .live_unstable => 1,
                        .live_propagation_limit => 2,
                        else => 3,
                    })
                ] += 1;
            },
        }
    }
    std.debug.print("oracle: {d} settled, {d} unstable, {d} at the propagation bound, {d} at the entry bound, {d} at the reaction bound, {d} with batches; {d} awaiters went on after a wake; {d} reactions stopped by a cancel; {d} over locals settled\n", .{ outcomes[0], outcomes[1], outcomes[2], outcomes[3], outcomes[4], batched, woke, stopped, local_programs });
    // The walk reached the bounds as well as fixed points, and digest runs reclaimed.
    try std.testing.expect(outcomes[0] > count / 2 and outcomes[1] > 0);
    if (count >= 100) try std.testing.expect(batched > count / 10);
    if (count >= 100) try std.testing.expect(woke > 0);
    if (count >= 100) try std.testing.expect(stopped > count / 20);
    if (count > every_mode) try std.testing.expect(reclaims > 0);
    if (count >= 100) try std.testing.expect(local_programs > count / 8);
}

test "the model and both machines agree on random programs of set, set live and regions" {
    // The generator and its fuel are sized to the bootstrap bounds, which its walks reach.
    try @import("profile.zig").requireBootstrap();
    try runOracle(400, 10);
}
