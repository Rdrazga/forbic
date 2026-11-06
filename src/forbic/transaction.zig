//! Allocation-free nested state journal. Published intents never execute here.
const std = @import("std");
const assert = std.debug.assert;

pub const Bounds = struct {
    cells: usize = 256,
    depth: usize = 32,
    undo: usize = 4096,
    pending: usize = 256,
    committed: usize = 256,
};
pub const Intent = struct { kind: u32, argument: i64 };
pub const Error = error{
    CellIndex,
    NoTransaction,
    ActiveTransaction,
    DepthLimit,
    UndoLimit,
    IntentLimit,
    OutboxLimit,
    InvalidAcknowledgement,
};
pub const default_bounds: Bounds = .{};
pub const Journal = Bounded(default_bounds);

pub fn Bounded(comptime bounds: Bounds) type {
    comptime {
        assert(bounds.cells > 0 and bounds.cells <= std.math.maxInt(u32));
        assert(bounds.depth > 0 and bounds.undo > 0);
        assert(bounds.pending > 0 and bounds.committed > 0);
    }
    return struct {
        const Self = @This();
        const Undo = struct { cell: u32, previous: i64 };
        const Frame = struct { undo: usize, pending: usize };

        cells: [bounds.cells]i64 = @splat(0),
        undo: [bounds.undo]Undo = undefined,
        frames: [bounds.depth]Frame = undefined,
        pending: [bounds.pending]Intent = undefined,
        outbox: [bounds.committed]Intent = undefined,
        depth: usize = 0,
        undo_count: usize = 0,
        pending_count: usize = 0,
        outbox_count: usize = 0,

        // Constant-time checks at ownership boundaries. These describe state
        // created by this journal, never a limit imposed on caller input.
        fn assertInvariants(self: *const Self) void {
            assert(self.depth <= self.frames.len);
            assert(self.undo_count <= self.undo.len);
            assert(self.pending_count <= self.pending.len);
            assert(self.outbox_count <= self.outbox.len);
            if (self.depth == 0) {
                assert(self.undo_count == 0 and self.pending_count == 0);
            } else {
                assert(self.frames[0].undo == 0 and self.frames[0].pending == 0);
                const frame = self.frames[self.depth - 1];
                assert(frame.undo <= self.undo_count);
                assert(frame.pending <= self.pending_count);
            }
        }

        pub fn begin(self: *Self) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (self.depth == self.frames.len) return error.DepthLimit;
            if (self.depth == 0) assert(self.undo_count == 0 and self.pending_count == 0);
            self.frames[self.depth] = .{ .undo = self.undo_count, .pending = self.pending_count };
            self.depth += 1;
            assert(self.depth > 0 and self.depth <= bounds.depth);
        }
        pub fn read(self: *const Self, cell: u32) Error!i64 {
            self.assertInvariants();
            if (cell >= self.cells.len) return error.CellIndex;
            return self.cells[cell];
        }
        pub fn write(self: *Self, cell: u32, value: i64) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (cell >= self.cells.len) return error.CellIndex;
            if (self.depth == 0) return error.NoTransaction;
            if (self.undo_count == self.undo.len) return error.UndoLimit;
            self.undo[self.undo_count] = .{ .cell = cell, .previous = self.cells[cell] };
            self.undo_count += 1;
            self.cells[cell] = value;
            assert(self.undo_count <= bounds.undo);
            assert(self.cells[cell] == value);
        }
        pub fn enqueue(self: *Self, intent: Intent) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (self.depth == 0) return error.NoTransaction;
            if (self.pending_count == self.pending.len) return error.IntentLimit;
            self.pending[self.pending_count] = intent;
            self.pending_count += 1;
            assert(self.pending_count <= bounds.pending);
            assert(std.meta.eql(self.pending[self.pending_count - 1], intent));
        }
        pub fn commit(self: *Self) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (self.depth == 0) return error.NoTransaction;
            if (self.depth > 1) {
                self.depth -= 1;
                return;
            }
            // Preflight before publishing or relinquishing rollback ownership.
            assert(self.outbox_count <= self.outbox.len);
            if (self.pending_count > self.outbox.len - self.outbox_count) return error.OutboxLimit;
            @memcpy(self.outbox[self.outbox_count..][0..self.pending_count], self.pending[0..self.pending_count]);
            self.outbox_count += self.pending_count;
            self.depth = 0;
            self.undo_count = 0;
            self.pending_count = 0;
            assert(self.outbox_count <= bounds.committed);
            assert(self.depth == 0 and self.undo_count == 0);
        }
        pub fn abort(self: *Self) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (self.depth == 0) return error.NoTransaction;
            const frame = self.frames[self.depth - 1];
            assert(frame.undo <= self.undo_count and frame.pending <= self.pending_count);
            while (self.undo_count > frame.undo) {
                self.undo_count -= 1;
                const record = self.undo[self.undo_count];
                assert(record.cell < self.cells.len);
                self.cells[record.cell] = record.previous;
            }
            self.pending_count = frame.pending;
            self.depth -= 1;
            assert(self.undo_count == frame.undo and self.pending_count == frame.pending);
        }
        pub fn abortAll(self: *Self) void {
            self.assertInvariants();
            defer self.assertInvariants();
            // Each iteration reduces depth; total replay is bounded by undo.len.
            while (self.depth > 0) self.abort() catch unreachable;
            assert(self.undo_count == 0 and self.pending_count == 0);
            assert(self.depth == 0);
        }
        /// Borrowed until a root commit or acknowledge; contains committed work only.
        pub fn committed(self: *const Self) []const Intent {
            self.assertInvariants();
            return self.outbox[0..self.outbox_count];
        }
        pub fn acknowledge(self: *Self, count: usize) Error!void {
            self.assertInvariants();
            defer self.assertInvariants();
            if (self.depth != 0) return error.ActiveTransaction;
            if (count > self.outbox_count) return error.InvalidAcknowledgement;
            const remaining = self.outbox_count - count;
            std.mem.copyForwards(Intent, self.outbox[0..remaining], self.outbox[count..self.outbox_count]);
            self.outbox_count = remaining;
            assert(self.undo_count == 0 and self.pending_count == 0);
            assert(self.outbox_count == remaining);
        }
    };
}

test "inner commit remains undoable by parent; inner abort preserves parent" {
    var journal: Journal = .{};
    try journal.begin();
    try journal.write(0, 10);
    try journal.enqueue(.{ .kind = 1, .argument = 10 });
    try journal.begin();
    try journal.write(0, 20);
    try journal.write(0, 30);
    try journal.enqueue(.{ .kind = 2, .argument = 30 });
    try journal.abort();
    try std.testing.expectEqual(@as(i64, 10), try journal.read(0));
    try std.testing.expectEqual(@as(usize, 1), journal.pending_count);
    try journal.begin();
    try journal.write(0, 40);
    try journal.enqueue(.{ .kind = 3, .argument = 40 });
    try journal.commit();
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
    try journal.abort();
    try std.testing.expectEqual(@as(i64, 0), try journal.read(0));
    try std.testing.expectEqual(@as(usize, 0), journal.pending_count);
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
}

test "root publication is FIFO and acknowledgement consumes only a prefix" {
    var journal: Journal = .{};
    try journal.begin();
    try journal.enqueue(.{ .kind = 1, .argument = 11 });
    try journal.begin();
    try journal.enqueue(.{ .kind = 2, .argument = 22 });
    try journal.commit();
    try journal.enqueue(.{ .kind = 3, .argument = 33 });
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
    try std.testing.expectError(error.ActiveTransaction, journal.acknowledge(0));
    try journal.commit();
    try std.testing.expectEqualSlices(Intent, &.{ .{ .kind = 1, .argument = 11 }, .{ .kind = 2, .argument = 22 }, .{ .kind = 3, .argument = 33 } }, journal.committed());
    try std.testing.expectError(error.InvalidAcknowledgement, journal.acknowledge(4));
    try journal.acknowledge(2);
    try std.testing.expectEqualSlices(Intent, &.{.{ .kind = 3, .argument = 33 }}, journal.committed());
    try journal.acknowledge(1);
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
}

test "journal limits and invalid operations preserve the rejected operation" {
    const Small = Bounded(.{ .cells = 2, .depth = 2, .undo = 2, .pending = 2, .committed = 1 });
    var journal: Small = .{};
    try std.testing.expectError(error.NoTransaction, journal.write(0, 1));
    try std.testing.expectError(error.CellIndex, journal.read(2));
    try std.testing.expectError(error.NoTransaction, journal.enqueue(.{ .kind = 0, .argument = 0 }));
    try std.testing.expectError(error.NoTransaction, journal.commit());
    try std.testing.expectError(error.NoTransaction, journal.abort());
    try journal.begin();
    try journal.begin();
    try std.testing.expectError(error.DepthLimit, journal.begin());
    try journal.write(0, 1);
    try journal.write(0, 2);
    try std.testing.expectError(error.UndoLimit, journal.write(0, 3));
    try std.testing.expectEqual(@as(i64, 2), try journal.read(0));
    try std.testing.expectError(error.CellIndex, journal.write(2, 3));
    try journal.enqueue(.{ .kind = 1, .argument = 1 });
    try journal.enqueue(.{ .kind = 2, .argument = 2 });
    try std.testing.expectError(error.IntentLimit, journal.enqueue(.{ .kind = 3, .argument = 3 }));
    try journal.commit();
    try std.testing.expectError(error.OutboxLimit, journal.commit());
    try std.testing.expectEqual(@as(usize, 1), journal.depth);
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
    journal.abortAll();
    try std.testing.expectEqual(@as(i64, 0), try journal.read(0));
    try journal.begin();
    try journal.enqueue(.{ .kind = 4, .argument = 4 });
    try journal.commit();
    try journal.begin();
    try journal.write(1, 9);
    try journal.enqueue(.{ .kind = 5, .argument = 5 });
    try std.testing.expectError(error.OutboxLimit, journal.commit());
    journal.abortAll();
    try std.testing.expectEqual(@as(i64, 0), try journal.read(1));
    try std.testing.expectEqual(@as(u32, 4), journal.committed()[0].kind);
    try journal.acknowledge(1);
    try journal.begin();
    try journal.write(1, 9);
    try journal.commit();
    try std.testing.expectEqual(@as(i64, 9), try journal.read(1));
}

test "default capacities admit every slot and reject pressure without losing root state" {
    var journal: Journal = .{};
    for (0..default_bounds.depth) |_| try journal.begin();
    try std.testing.expectError(error.DepthLimit, journal.begin());
    for (0..default_bounds.undo) |index| {
        try journal.write(@intCast(index % default_bounds.cells), std.math.minInt(i64) + @as(i64, @intCast(index)));
    }
    try std.testing.expectError(error.UndoLimit, journal.write(0, std.math.maxInt(i64)));
    const cell_before = try journal.read(0);
    for (0..default_bounds.pending) |index| {
        try journal.enqueue(.{ .kind = std.math.maxInt(u32), .argument = std.math.maxInt(i64) - @as(i64, @intCast(index)) });
    }
    try std.testing.expectError(error.IntentLimit, journal.enqueue(.{ .kind = 0, .argument = 0 }));
    for (0..default_bounds.depth) |_| try journal.commit();
    try std.testing.expectEqual(default_bounds.committed, journal.committed().len);
    try std.testing.expectEqual(cell_before, try journal.read(0));
    try journal.begin();
    try journal.write(0, std.math.maxInt(i64));
    try journal.enqueue(.{ .kind = 0, .argument = std.math.minInt(i64) });
    try std.testing.expectError(error.OutboxLimit, journal.commit());
    try std.testing.expectEqual(@as(usize, 1), journal.depth);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try journal.read(0));
    try std.testing.expectEqual(default_bounds.committed, journal.committed().len);
    journal.abortAll();
    try std.testing.expectEqual(cell_before, try journal.read(0));
    for (journal.committed(), 0..) |intent, index| {
        try std.testing.expectEqual(std.math.maxInt(u32), intent.kind);
        try std.testing.expectEqual(std.math.maxInt(i64) - @as(i64, @intCast(index)), intent.argument);
    }
    try journal.acknowledge(default_bounds.committed);
    try std.testing.expectEqual(@as(usize, 0), journal.committed().len);
}
