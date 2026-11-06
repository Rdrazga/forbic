//! Per-run typed cells. VM undo records and reference full images are independent.
//! Values are shallow immutable borrows; caller-owned pools outlive this state.
//!
//! The program's own cells come first. Class instances live after them: an instance is a run of
//! consecutive cells appended when it is created, named by its first cell. A rolled-back region
//! forgets the instances it created by restoring the cell count, and undoes writes to older ones
//! exactly as it undoes writes to program cells.
//!
//! Rollback costs what can be restored, not what was written. Regions nest: the root region is
//! depth 1 and covers the run, each open `Attempt` is one deeper. A region other than the root
//! holds at most one record per cell: the value the cell had when the region began, taken at its
//! first write there. The root holds none, because a failed run is discarded, not restored: the
//! root begins from the state `reset` gives and aborting it returns to exactly that state.
//! `source_undos` therefore bounds the records the open regions hold together, which is at most
//! cells x (depth - 1), and a loop that rewrites one cell never reaches it.
//!
//! When a region commits, its parent inherits each record unless the parent already holds one for
//! that cell (the parent's is older, so it is the one to keep) or the parent is the root. Both
//! machines count records by this rule, so both report `undo_limit` at the same write.
const std = @import("std");
const types = @import("types.zig");
pub const Error = error{ SourceCellIndex, SourceUninitialized, SourceUndoLimit, SourceDepthLimit, NoSourceTransaction, ObjectLimit };
/// Program cells plus the cells all instances of a run may use.
pub const total_cells = types.limits.source_cells + types.limits.object_cells;
/// `link` (RFC-0084) is the live record attached to the cell, by the id of its first cell, or
/// `no_link`. It is part of the cell for the journal: a region's record holds the whole cell, so
/// a rollback restores the link with the value. A write keeps it; only `setLink` changes it.
pub const Cell = struct { value: types.Value = .{ .integer = 0 }, initialized: bool = false, link: u32 = no_link };
pub const no_link: u32 = std.math.maxInt(u32);
comptime {
    // The link lies in the padding of the value and its flag: a cell is no larger for it.
    std.debug.assert(@sizeOf(Cell) == @sizeOf(struct { value: types.Value, initialized: bool }));
}
/// The live bookkeeping that regions keep with the cells (RFC-0084, L4). `valid` is the count of
/// valid dependency entries (V): a region that fails restores it. `stamp` is the run-wide stamp
/// counter, which no rollback restores, so that no stamp is issued twice. `dropped` is the
/// lowest stamp a failed region began at since the machine last looked: the entries recorded
/// above it were recorded in a region that failed, and the machine drops them before its next
/// live operation (`none` when there are none).
pub const Live = struct {
    valid: u64 = 0,
    stamp: u64 = 0,
    dropped: u64 = none,
    /// An outermost region (depth 2) has begun since the machine last looked. Until the
    /// machine's next live operation, which entries are valid is what it was when it began.
    opened: bool = false,
    /// The length of the machine's log of entries taken off their cells' lists in a region
    /// while a rollback could bring them back, which the machine keeps up to date; `unlog` is
    /// the lowest length a failed region began at since the machine last looked: the entries
    /// logged above it go back on their lists before its next live operation (`none` if none).
    log: u64 = 0,
    unlog: u64 = none,
    pub const none = std.math.maxInt(u64);
};
/// What a region keeps of `Live` when it begins.
pub const LiveMark = struct { valid: u64, stamp: u64, log: u64 };
/// How many regions are open; also the name of the innermost one. The root region is 1.
pub const Depth = std.math.IntFittingRange(0, types.limits.source_frames);
/// `outer` is the nearest enclosing region that also holds a record for the cell, or 0.
pub const Undo = struct { cell: u32, previous: Cell, outer: Depth };

pub const Journal = struct {
    /// Cells below `cell_count` are live; `reset` and `allocate` initialise them as they are taken.
    cells: [total_cells]Cell = undefined,
    /// Per live cell, the innermost open region holding a record for it, or 0 for none. This is
    /// what makes "already recorded in this region" one comparison. It never exceeds `depth`, and
    /// it is never 1: the root holds no records.
    holder: [total_cells]Depth = undefined,
    undo: [types.limits.source_undos]Undo = undefined,
    frames: [types.limits.source_frames]usize = undefined,
    marks: [types.limits.source_frames]usize = undefined,
    cell_count: usize = 0,
    /// How many of the cells are the program's own: instances may take `object_cells` beyond
    /// them, however many or few the program has.
    program_cells: usize = 0,
    undo_count: usize = 0,
    depth: usize = 0,
    /// Every program cell is uninitialised and no instance exists. Only such a state may begin a
    /// root region, which is why aborting the root needs no records.
    pristine: bool = false,
    /// RFC-0084: see `Live`. A region keeps a mark of it when it begins.
    live: Live = .{},
    live_marks: [types.limits.source_frames]LiveMark = undefined,

    pub fn reset(self: *Journal, count: usize) void {
        std.debug.assert(self.depth == 0 and count <= types.limits.source_cells);
        @memset(self.cells[0..@max(self.cell_count, count)], .{});
        @memset(self.holder[0..count], 0);
        self.cell_count = count;
        self.program_cells = count;
        self.undo_count = 0;
        self.pristine = true;
        self.live = .{};
    }
    pub fn begin(self: *Journal) Error!void {
        if (self.depth == self.frames.len) return error.SourceDepthLimit;
        if (self.depth == 0) {
            std.debug.assert(self.pristine and self.undo_count == 0);
            self.pristine = false;
        }
        self.frames[self.depth] = self.undo_count;
        self.marks[self.depth] = self.cell_count;
        self.live_marks[self.depth] = .{ .valid = self.live.valid, .stamp = self.live.stamp, .log = self.live.log };
        if (self.depth == 1) self.live.opened = true;
        self.depth += 1;
    }
    /// Appends an instance's cells (its header first) and returns the first one.
    pub fn allocate(self: *Journal, values: []const types.Value) Error!u32 {
        if (self.depth == 0) return error.NoSourceTransaction;
        std.debug.assert(values.len != 0 and self.cell_count >= self.program_cells);
        if (values.len > types.limits.object_cells - (self.cell_count - self.program_cells)) return error.ObjectLimit;
        const base = self.cell_count;
        for (values, self.cells[base..][0..values.len]) |value, *cell| cell.* = .{ .value = value, .initialized = true };
        // A new cell has no record anywhere, whatever an earlier, rolled back cell here had.
        @memset(self.holder[base..][0..values.len], 0);
        self.cell_count += values.len;
        return @intCast(base);
    }
    /// RFC-0087, P5.3: takes back the instances allocated since `mark`, which nothing names: a
    /// decode that failed built them. A new cell has no record, so none is dropped.
    pub fn truncate(self: *Journal, mark: usize) void {
        std.debug.assert(mark >= self.program_cells and mark <= self.cell_count);
        self.cell_count = mark;
    }
    pub fn read(self: *const Journal, cell: u32) Error!types.Value {
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (!self.cells[cell].initialized) return error.SourceUninitialized;
        return self.cells[cell].value;
    }
    pub fn write(self: *Journal, cell: u32, value: types.Value, initialize: bool) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (self.cells[cell].initialized == initialize) return error.SourceUninitialized;
        std.debug.assert(self.holder[cell] <= self.depth and self.holder[cell] != 1);
        // Only the first write in a region other than the root can change what a rollback restores.
        if (self.depth > 1 and self.holder[cell] != self.depth) {
            if (self.undo_count == self.undo.len) return error.SourceUndoLimit;
            self.undo[self.undo_count] = .{ .cell = cell, .previous = self.cells[cell], .outer = self.holder[cell] };
            self.undo_count += 1;
            self.holder[cell] = @intCast(self.depth);
        }
        // The link stays: only `setLink` changes it (RFC-0084).
        self.cells[cell].value = value;
        self.cells[cell].initialized = true;
    }
    /// Attaches the live record `record` to an initialised cell, or detaches it (`no_link`),
    /// journalled as a write is: the cell's record in the region holds the link too (RFC-0084).
    pub fn setLink(self: *Journal, cell: u32, record: u32) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (!self.cells[cell].initialized) return error.SourceUninitialized;
        std.debug.assert(self.holder[cell] <= self.depth and self.holder[cell] != 1);
        if (self.depth > 1 and self.holder[cell] != self.depth) {
            if (self.undo_count == self.undo.len) return error.SourceUndoLimit;
            self.undo[self.undo_count] = .{ .cell = cell, .previous = self.cells[cell], .outer = self.holder[cell] };
            self.undo_count += 1;
            self.holder[cell] = @intCast(self.depth);
        }
        self.cells[cell].link = record;
    }
    /// Costs one step per record the closing region holds.
    pub fn commit(self: *Journal) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        self.depth -= 1;
        const parent = self.depth;
        var kept = if (parent == 0) 0 else self.frames[parent];
        std.debug.assert(kept <= self.undo_count and (parent > 1 or kept == 0));
        // The parent inherits a record unless it has its own, older one, or it is the root. A
        // record that is dropped leaves the cell with the holder it had before.
        for (self.undo[kept..self.undo_count]) |record| {
            std.debug.assert(self.holder[record.cell] == parent + 1 and record.outer <= parent and record.outer != 1);
            if (parent > 1 and record.outer != parent) {
                self.holder[record.cell] = @intCast(parent);
                self.undo[kept] = record;
                kept += 1;
            } else self.holder[record.cell] = record.outer;
        }
        self.undo_count = kept;
        std.debug.assert(parent > 1 or self.undo_count == 0);
    }
    pub fn abort(self: *Journal) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        self.depth -= 1;
        // RFC-0084: V as the region found it, and the entries it recorded are to be dropped.
        self.live.valid = self.live_marks[self.depth].valid;
        self.live.dropped = @min(self.live.dropped, self.live_marks[self.depth].stamp);
        self.live.unlog = @min(self.live.unlog, self.live_marks[self.depth].log);
        if (self.depth == 0) {
            // The root began pristine and wrote without records: discarding the run restores it.
            std.debug.assert(self.undo_count == 0);
            self.cell_count = self.marks[0];
            @memset(self.cells[0..self.cell_count], .{});
            self.pristine = true;
            return;
        }
        const start = self.frames[self.depth];
        while (self.undo_count > start) {
            self.undo_count -= 1;
            const record = self.undo[self.undo_count];
            std.debug.assert(self.holder[record.cell] == self.depth + 1 and record.outer <= self.depth);
            self.cells[record.cell] = record.previous;
            // Later writes in an enclosing region must record again unless that region has.
            self.holder[record.cell] = record.outer;
        }
        self.cell_count = self.marks[self.depth];
    }
    pub fn abortAll(self: *Journal) void {
        while (self.depth != 0) self.abort() catch unreachable;
    }
    /// Whether an open region holds a record for the cell. A reclamation keeps the instance
    /// such a cell belongs to, so that no record is left without its cell.
    pub fn holds(self: *const Journal, cell: usize) bool {
        return self.holder[cell] != 0;
    }
    /// Closes the gaps a reclamation leaves among the cells from `mark` on. `forward[k]` is 0
    /// for a cell that goes, and otherwise one more than the place, counted from `mark`, that
    /// cell `mark + k` moves to; the cells that stay keep their order. Every open region began
    /// before the frame whose mark this is, so no region's own mark lies above it, and the
    /// records the regions hold for cells that move are renumbered with them.
    pub fn relocate(self: *Journal, mark: u32, forward: []const u32) void {
        std.debug.assert(mark + forward.len == self.cell_count);
        for (self.marks[0..self.depth]) |began| std.debug.assert(began <= mark);
        var kept: usize = mark;
        for (forward, mark..) |to, cell| {
            if (to == 0) {
                std.debug.assert(self.holder[cell] == 0);
                continue;
            }
            std.debug.assert(mark + to - 1 == kept and kept <= cell);
            self.cells[kept] = self.cells[cell];
            self.holder[kept] = self.holder[cell];
            kept += 1;
        }
        for (self.undo[0..self.undo_count]) |*record| {
            if (record.cell >= mark) record.cell = mark + forward[record.cell - mark] - 1;
        }
        self.cell_count = kept;
    }
};

/// The reference keeps a full image of the program's own cells per open region, which is simple
/// and unlike the VM's journal. Instance cells are far more numerous, so they are restored from
/// previous values instead: a region then costs what it writes, not what the run has built.
///
/// It keeps the same count of records as the VM, by the rule in the file comment, but finds
/// "this region already holds the cell" from where the cell's newest record lies in the log, not
/// from a region number per cell: a region's records are the log from its start onwards.
pub const ReferenceState = struct {
    pub const Held = struct { cell: u32, previous: Cell, outer: u32 };
    /// No open region holds a record for the cell.
    const none = std.math.maxInt(u32);

    /// Cells below `cell_count` are live; `reset` and `allocate` initialise them as they are taken.
    cells: [total_cells]Cell = undefined,
    images: [types.limits.source_frames][types.limits.source_cells]Cell = undefined,
    marks: [types.limits.source_frames]usize = undefined,
    /// One entry per (region, cell written in it): `outer` is the position of the record an
    /// enclosing region holds for the same cell, or `none`.
    held: [types.limits.source_undos]Held = undefined,
    /// Where each region's records start; the innermost region's run to `undo_count`.
    starts: [types.limits.source_frames]usize = undefined,
    /// Per live cell, the position of its newest record, or `none`.
    newest: [total_cells]u32 = undefined,
    cell_count: usize = 0,
    /// The program's own cells; the instances' cells follow and number at most `object_cells`.
    own: usize = 0,
    undo_count: usize = 0,
    depth: usize = 0,
    /// As in the VM's journal: only the state `reset` gives may begin a root region.
    pristine: bool = false,
    /// RFC-0084: see `Live`, kept by the reference in its own words.
    live: Live = .{},
    live_marks: [types.limits.source_frames]LiveMark = undefined,

    /// How many of the live cells are the program's own.
    fn named(self: *const ReferenceState) usize {
        return @min(self.cell_count, types.limits.source_cells);
    }

    pub fn reset(self: *ReferenceState, count: usize) void {
        std.debug.assert(self.depth == 0 and count <= types.limits.source_cells);
        @memset(self.cells[0..@max(self.cell_count, count)], .{});
        @memset(self.newest[0..count], none);
        self.cell_count = count;
        self.own = count;
        self.undo_count = 0;
        self.pristine = true;
        self.live = .{};
    }
    pub fn begin(self: *ReferenceState) Error!void {
        if (self.depth == self.images.len) return error.SourceDepthLimit;
        if (self.depth == 0) {
            // The root restores from its image alone, so a run starts with no cell outside it.
            std.debug.assert(self.pristine and self.undo_count == 0 and self.cell_count <= types.limits.source_cells);
            self.pristine = false;
        }
        @memcpy(self.images[self.depth][0..self.named()], self.cells[0..self.named()]);
        self.starts[self.depth] = self.undo_count;
        self.marks[self.depth] = self.cell_count;
        self.live_marks[self.depth] = .{ .valid = self.live.valid, .stamp = self.live.stamp, .log = self.live.log };
        if (self.depth == 1) self.live.opened = true;
        self.depth += 1;
    }
    pub fn allocate(self: *ReferenceState, values: []const types.Value) Error!u32 {
        if (self.depth == 0) return error.NoSourceTransaction;
        std.debug.assert(values.len != 0);
        const instances = self.cell_count - self.own;
        if (instances + values.len > types.limits.object_cells) return error.ObjectLimit;
        const base = self.cell_count;
        for (values, self.cells[base..][0..values.len]) |value, *cell| cell.* = .{ .value = value, .initialized = true };
        @memset(self.newest[base..][0..values.len], none);
        self.cell_count += values.len;
        return @intCast(base);
    }
    /// RFC-0087, P5.3: as `Journal.truncate`.
    pub fn truncate(self: *ReferenceState, mark: usize) void {
        std.debug.assert(mark >= self.own and mark <= self.cell_count);
        self.cell_count = mark;
    }
    pub fn read(self: *const ReferenceState, cell: u32) Error!types.Value {
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (!self.cells[cell].initialized) return error.SourceUninitialized;
        return self.cells[cell].value;
    }
    pub fn write(self: *ReferenceState, cell: u32, value: types.Value, initialize: bool) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (initialize == self.cells[cell].initialized) return error.SourceUninitialized;
        const outer = self.newest[cell];
        std.debug.assert(outer == none or (outer < self.undo_count and self.held[outer].cell == cell));
        // The innermost region holds the cell when the cell's newest record lies within it.
        if (self.depth > 1 and (outer == none or outer < self.starts[self.depth - 1])) {
            if (self.undo_count == self.held.len) return error.SourceUndoLimit;
            self.held[self.undo_count] = .{ .cell = cell, .previous = self.cells[cell], .outer = outer };
            self.newest[cell] = @intCast(self.undo_count);
            self.undo_count += 1;
        }
        // A write leaves the cell's live link as it is (RFC-0084).
        self.cells[cell] = .{ .value = value, .initialized = true, .link = self.cells[cell].link };
    }
    /// The link of a live record to an initialised cell, recorded as a write is (RFC-0084).
    pub fn setLink(self: *ReferenceState, cell: u32, record: u32) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        if (cell >= self.cell_count) return error.SourceCellIndex;
        if (!self.cells[cell].initialized) return error.SourceUninitialized;
        const outer = self.newest[cell];
        if (self.depth > 1 and (outer == none or outer < self.starts[self.depth - 1])) {
            if (self.undo_count == self.held.len) return error.SourceUndoLimit;
            self.held[self.undo_count] = .{ .cell = cell, .previous = self.cells[cell], .outer = outer };
            self.newest[cell] = @intCast(self.undo_count);
            self.undo_count += 1;
        }
        self.cells[cell].link = record;
    }
    pub fn commit(self: *ReferenceState) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        self.depth -= 1;
        if (self.depth == 0) {
            std.debug.assert(self.undo_count == 0);
            return;
        }
        // The closing region's records join the parent's, which then run to the end of the log.
        // One the parent cannot use (it has its own, or it is the root) is squeezed out.
        const parent_start = self.starts[self.depth - 1];
        var kept = self.starts[self.depth];
        for (self.held[kept..self.undo_count]) |record| {
            std.debug.assert(record.outer == none or record.outer < self.starts[self.depth]);
            if (self.depth == 1 or (record.outer != none and record.outer >= parent_start)) {
                self.newest[record.cell] = record.outer;
            } else {
                self.held[kept] = record;
                self.newest[record.cell] = @intCast(kept);
                kept += 1;
            }
        }
        self.undo_count = kept;
        std.debug.assert(self.depth > 1 or self.undo_count == 0);
    }
    pub fn abort(self: *ReferenceState) Error!void {
        if (self.depth == 0) return error.NoSourceTransaction;
        self.depth -= 1;
        // RFC-0084: the count of valid entries comes back, and what the region recorded goes.
        self.live.valid = self.live_marks[self.depth].valid;
        if (self.live_marks[self.depth].stamp < self.live.dropped) self.live.dropped = self.live_marks[self.depth].stamp;
        if (self.live_marks[self.depth].log < self.live.unlog) self.live.unlog = self.live_marks[self.depth].log;
        // A region holds a cell once, so these are the values its instance cells began with.
        while (self.undo_count > self.starts[self.depth]) {
            self.undo_count -= 1;
            const record = self.held[self.undo_count];
            if (record.cell >= types.limits.source_cells) self.cells[record.cell] = record.previous;
            self.newest[record.cell] = record.outer;
        }
        self.cell_count = self.marks[self.depth];
        @memcpy(self.cells[0..self.named()], self.images[self.depth][0..self.named()]);
        if (self.depth == 0) {
            std.debug.assert(self.undo_count == 0);
            self.pristine = true;
        }
    }
    pub fn abortAll(self: *ReferenceState) void {
        while (self.depth != 0) self.abort() catch unreachable;
    }
    /// Whether an open region holds a record for the cell; see `Journal.holds`.
    pub fn holds(self: *const ReferenceState, cell: usize) bool {
        return self.newest[cell] != none;
    }
    /// What `Journal.relocate` does, on this state's own bookkeeping: the cells from `mark` on
    /// for which `forward` is not 0 move down to `mark + forward - 1`, with the position of
    /// their newest record, and the records name them where they are afterwards.
    pub fn relocate(self: *ReferenceState, mark: u32, forward: []const u32) void {
        std.debug.assert(mark + forward.len == self.cell_count);
        for (self.marks[0..self.depth]) |began| std.debug.assert(began <= mark);
        var from: usize = mark;
        var kept: usize = mark;
        while (from < self.cell_count) : (from += 1) {
            const to = forward[from - mark];
            if (to == 0) continue;
            std.debug.assert(mark + to - 1 == kept);
            if (kept != from) {
                self.cells[kept] = self.cells[from];
                self.newest[kept] = self.newest[from];
            }
            kept += 1;
        }
        var position = self.undo_count;
        while (position != 0) {
            position -= 1;
            const record = &self.held[position];
            if (record.cell < mark) continue;
            std.debug.assert(forward[record.cell - mark] != 0);
            record.cell = mark + forward[record.cell - mark] - 1;
        }
        self.cell_count = kept;
    }
    /// Checks what member reclamation relies on: no value a rollback can bring back names a
    /// member at or above `mark`, the pool mark of the frame that is ending. Every open region
    /// was opened before that frame was pushed, and a record or image holds what a cell held
    /// when its region began. A record for a cell created inside its region is exempt: the
    /// rollback that would use it forgets the cell.
    /// The same holds for instances and run strings: such a value names no instance at or
    /// above `cell_mark` and no string byte at or above `text_mark`, the frame's other marks.
    pub fn assertRestoresBelow(self: *const ReferenceState, mark: u32, cell_mark: u32, text_mark: [*]const u8) void {
        for (0..self.depth) |region| {
            const existed = self.marks[region];
            std.debug.assert(existed <= cell_mark);
            for (self.images[region][0..@min(existed, types.limits.source_cells)]) |cell| std.debug.assert(namedEnd(cell.value) <= mark and olderThan(cell.value, cell_mark, text_mark));
            const last = if (region + 1 == self.depth) self.undo_count else self.starts[region + 1];
            for (self.held[self.starts[region]..last]) |record| std.debug.assert(record.cell >= existed or (namedEnd(record.previous.value) <= mark and olderThan(record.previous.value, cell_mark, text_mark)));
        }
    }
    fn olderThan(value: types.Value, cell_mark: u32, text_mark: [*]const u8) bool {
        return switch (value) {
            .object => |object| object.id < cell_mark,
            .string => |text| text.len == 0 or @intFromPtr(text.ptr) + text.len <= @intFromPtr(text_mark),
            else => true,
        };
    }
    /// One past the last member a value names, or 0 when it names none.
    fn namedEnd(value: types.Value) u32 {
        const span = switch (value) {
            .aggregate => |aggregate| aggregate.elements,
            .callable => |callable| callable.captures,
            else => return 0,
        };
        return if (span.start == span.end) 0 else span.end;
    }
};

pub fn diagnostic(err: Error) types.Diagnostic.Code {
    return switch (err) {
        error.SourceUndoLimit => .undo_limit,
        error.SourceDepthLimit => .transaction_limit,
        error.ObjectLimit => .object_limit,
        else => .invalid_ir,
    };
}

/// Both states behind one set of calls, checked against each other after every step.
const Pair = struct {
    journal: Journal = .{},
    reference: ReferenceState = .{},

    fn reset(self: *Pair, count: usize) void {
        self.journal.reset(count);
        self.reference.reset(count);
    }
    fn begin(self: *Pair) !void {
        try self.journal.begin();
        try self.reference.begin();
    }
    fn commit(self: *Pair) !void {
        try self.journal.commit();
        try self.reference.commit();
        try self.agree();
    }
    fn abort(self: *Pair) !void {
        try self.journal.abort();
        try self.reference.abort();
        try self.agree();
    }
    fn set(self: *Pair, cell: u32, value: i64) !void {
        const initialize = !self.journal.cells[cell].initialized;
        try self.journal.write(cell, .{ .integer = value }, initialize);
        try self.reference.write(cell, .{ .integer = value }, initialize);
        try self.agree();
    }
    fn allocate(self: *Pair, values: []const types.Value) !u32 {
        const first = try self.journal.allocate(values);
        try std.testing.expectEqual(first, try self.reference.allocate(values));
        return first;
    }
    fn get(self: *const Pair, cell: u32) !i64 {
        const value = (try self.journal.read(cell)).integer;
        try std.testing.expectEqual(value, (try self.reference.read(cell)).integer);
        return value;
    }
    fn agree(self: *const Pair) !void {
        try std.testing.expectEqual(self.journal.depth, self.reference.depth);
        try std.testing.expectEqual(self.journal.undo_count, self.reference.undo_count);
        try std.testing.expectEqual(self.journal.cell_count, self.reference.cell_count);
    }
    fn records(self: *const Pair) usize {
        return self.journal.undo_count;
    }
};

fn pair() !*Pair {
    const scratch = @import("scratch.zig");
    const p = try scratch.storage(Pair);
    scratch.initialise(p);
    return p;
}

test "root writes hold no records and a region holds one per cell however often it writes" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    p.reset(2);
    try p.begin();
    // More writes than the log has room for: outside an Attempt nothing could restore them.
    for (0..2 * types.limits.source_undos + 100) |i| try p.set(0, @intCast(i));
    try std.testing.expectEqual(@as(usize, 0), p.records());
    try p.set(1, 5);
    try p.begin();
    for (0..2 * types.limits.source_undos + 100) |i| try p.set(0, -@as(i64, @intCast(i)));
    try std.testing.expectEqual(@as(usize, 1), p.records());
    try p.set(1, 6);
    try std.testing.expectEqual(@as(usize, 2), p.records());
    try p.abort();
    try std.testing.expectEqual(@as(usize, 0), p.records());
    try std.testing.expectEqual(@as(i64, 2 * types.limits.source_undos + 99), try p.get(0));
    try std.testing.expectEqual(@as(i64, 5), try p.get(1));
    try p.commit();
    try std.testing.expectEqual(@as(i64, 5), try p.get(1));
}

test "inner commit then outer abort restores, and an inner abort does not hide later writes" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    p.reset(3);
    try p.begin();
    for (0..3) |cell| try p.set(@intCast(cell), 10 + @as(i64, @intCast(cell)));

    // The outer region inherits the record of a cell only the inner one wrote, and keeps its own
    // for a cell both wrote.
    try p.begin();
    try p.set(0, 20);
    try p.begin();
    try p.set(0, 30);
    try p.set(1, 31);
    try std.testing.expectEqual(@as(usize, 3), p.records());
    try p.commit();
    try std.testing.expectEqual(@as(usize, 2), p.records());
    // Both cells are now held by the outer region: writing them again records nothing.
    try p.set(0, 40);
    try p.set(1, 41);
    try std.testing.expectEqual(@as(usize, 2), p.records());
    try p.abort();
    try std.testing.expectEqual(@as(i64, 10), try p.get(0));
    try std.testing.expectEqual(@as(i64, 11), try p.get(1));

    // After an inner abort the outer region has no record for the cell, so its next write there
    // must take one, or the outer abort would keep that write.
    try p.begin();
    try p.begin();
    try p.set(2, 50);
    try p.abort();
    try std.testing.expectEqual(@as(i64, 12), try p.get(2));
    try std.testing.expectEqual(@as(usize, 0), p.records());
    try p.set(2, 60);
    try p.set(2, 61);
    try std.testing.expectEqual(@as(usize, 1), p.records());
    // A new inner region at the depth of the aborted one starts without its records.
    try p.begin();
    try p.set(2, 70);
    try std.testing.expectEqual(@as(usize, 2), p.records());
    try p.abort();
    try std.testing.expectEqual(@as(i64, 61), try p.get(2));
    try p.abort();
    try std.testing.expectEqual(@as(i64, 12), try p.get(2));

    // A region committed into the root leaves nothing behind for a later one to trip over.
    try p.begin();
    try p.set(0, 80);
    try p.commit();
    try std.testing.expectEqual(@as(usize, 0), p.records());
    try p.begin();
    try p.set(0, 90);
    try std.testing.expectEqual(@as(usize, 1), p.records());
    try p.abort();
    try std.testing.expectEqual(@as(i64, 80), try p.get(0));

    // A loop of inner regions that each commit one write costs the outer region one record.
    try p.begin();
    for (0..1000) |i| {
        try p.begin();
        try p.set(1, @intCast(i));
        try p.commit();
        try std.testing.expectEqual(@as(usize, 1), p.records());
    }
    try p.abort();
    try std.testing.expectEqual(@as(i64, 11), try p.get(1));
    try p.commit();
}

test "instances created and written in an aborted region vanish and their cells start clean" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    // With every program cell taken, instance cells are the ones the reference restores from
    // records; with one, they are among those it restores from images.
    for ([_]usize{ 1, types.limits.source_cells }) |count| {
        p.reset(count);
        try p.begin();
        try p.set(0, 1);
        const old = try p.allocate(&.{ .{ .integer = 7 }, .{ .integer = 8 } });
        try p.begin();
        try p.set(old + 1, 9);
        const new = try p.allocate(&.{ .{ .integer = 1 }, .{ .integer = 2 } });
        try p.set(new + 1, 3);
        try p.begin();
        try p.set(new + 1, 4);
        try p.set(old + 1, 10);
        try p.commit();
        try std.testing.expectEqual(@as(usize, 2), p.records());
        try p.abort();
        try std.testing.expectEqual(@as(usize, 0), p.records());
        try std.testing.expectEqual(@as(usize, count + 2), p.journal.cell_count);
        try std.testing.expectEqual(@as(i64, 8), try p.get(old + 1));
        try std.testing.expectError(error.SourceCellIndex, p.journal.read(new));
        try std.testing.expectError(error.SourceCellIndex, p.reference.read(new));
        // The same cells are taken again: nothing of the aborted region's records may remain.
        try p.begin();
        const again = try p.allocate(&.{ .{ .integer = 5 }, .{ .integer = 6 } });
        try std.testing.expectEqual(new, again);
        try p.set(again + 1, 11);
        try std.testing.expectEqual(@as(usize, 1), p.records());
        try p.commit();
        try std.testing.expectEqual(@as(i64, 11), try p.get(again + 1));
        p.journal.abortAll();
        p.reference.abortAll();
        try p.agree();
        try std.testing.expectEqual(count, p.journal.cell_count);
        try std.testing.expectError(error.SourceUninitialized, p.journal.read(0));
        try std.testing.expectError(error.SourceUninitialized, p.reference.read(0));
    }
}

test "the record quota is exact: distinct cells per region fill it and rewrites stay free" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    p.reset(types.limits.source_cells);
    try p.begin();
    for (0..types.limits.source_cells) |cell| try p.set(@intCast(cell), 0);
    // One instance cell more than the program's, so that the regions need not divide the quota.
    _ = try p.allocate(&.{.{ .integer = 0 }});
    const cells: u32 = types.limits.source_cells + 1;
    comptime std.debug.assert(cells * (types.limits.source_frames - 1) > types.limits.source_undos);
    var cell: u32 = cells;
    while (p.records() < types.limits.source_undos) {
        if (cell == cells) {
            try p.begin();
            cell = 0;
        }
        try p.set(cell, 1);
        try p.set(cell, 2);
        cell += 1;
    }
    try std.testing.expect(cell != cells);
    try std.testing.expectEqual(@as(usize, types.limits.source_undos), p.records());
    const before = try p.get(cell);
    try std.testing.expectError(error.SourceUndoLimit, p.journal.write(cell, .{ .integer = 3 }, false));
    try std.testing.expectError(error.SourceUndoLimit, p.reference.write(cell, .{ .integer = 3 }, false));
    try std.testing.expectEqual(before, try p.get(cell));
    // A cell the region already holds needs no room.
    try p.set(cell - 1, 3);
    // Neither does the room a committed region gives back: the parent held all but one of them.
    const depth = p.journal.depth;
    try p.commit();
    try std.testing.expectEqual(depth - 1, p.journal.depth);
    try std.testing.expectEqual(@as(usize, if (depth == 2) 0 else types.limits.source_undos - cell), p.records());
    p.journal.abortAll();
    p.reference.abortAll();
    try p.agree();
    try std.testing.expectEqual(@as(usize, 0), p.records());
    try std.testing.expectError(error.SourceUninitialized, p.journal.read(0));
    try std.testing.expectError(error.SourceUninitialized, p.reference.read(0));
}

test "cells that close up after a reclamation keep their records, and a rollback still forgets them" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    // With one program cell the instances lie among the cells the reference restores from
    // images; with all of them taken, among those it restores from records.
    for ([_]usize{ 1, types.limits.source_cells }) |count| {
        p.reset(count);
        try p.begin();
        try p.set(0, 1);
        const old = try p.allocate(&.{ .{ .integer = 7 }, .{ .integer = 8 } });
        // The region that is open while cells are reclaimed began before all of them.
        try p.begin();
        try p.set(old + 1, 9);
        const mark: u32 = @intCast(p.journal.cell_count);
        const dead = try p.allocate(&.{ .{ .integer = 1 }, .{ .integer = 2 } });
        const held = try p.allocate(&.{ .{ .integer = 3 }, .{ .integer = 4 }, .{ .integer = 5 } });
        const gone = try p.allocate(&.{.{ .integer = 6 }});
        const kept = try p.allocate(&.{ .{ .integer = 10 }, .{ .integer = 11 } });
        try std.testing.expectEqual(mark, dead);
        // A nested region writes two of them and commits, so the outer one holds the records.
        try p.begin();
        try p.set(held + 2, 50);
        try p.set(kept + 1, 51);
        try p.commit();
        try std.testing.expectEqual(@as(usize, 3), p.records());
        for ([_]u32{ dead, dead + 1, gone, held, kept }) |cell| try std.testing.expect(!p.journal.holds(cell) and !p.reference.holds(cell));
        for ([_]u32{ old + 1, held + 2, kept + 1 }) |cell| try std.testing.expect(p.journal.holds(cell) and p.reference.holds(cell));
        // `dead` and `gone` go: the others move down by two and then by three cells.
        const forward = [_]u32{ 0, 0, 1, 2, 3, 0, 4, 5 };
        p.journal.relocate(mark, &forward);
        p.reference.relocate(mark, &forward);
        try p.agree();
        try std.testing.expectEqual(@as(usize, mark + 5), p.journal.cell_count);
        try std.testing.expectEqual(@as(usize, 3), p.records());
        try std.testing.expectEqual(@as(i64, 3), try p.get(mark));
        try std.testing.expectEqual(@as(i64, 50), try p.get(mark + 2));
        try std.testing.expectEqual(@as(i64, 10), try p.get(mark + 3));
        try std.testing.expectEqual(@as(i64, 51), try p.get(mark + 4));
        // The cells that moved are still held where they are now: writing them records nothing.
        try std.testing.expect(p.journal.holds(mark + 2) and p.reference.holds(mark + 2) and p.journal.holds(mark + 4) and p.reference.holds(mark + 4));
        try std.testing.expect(!p.journal.holds(mark) and !p.reference.holds(mark) and !p.journal.holds(mark + 3) and !p.reference.holds(mark + 3));
        try p.set(mark + 2, 60);
        try p.set(mark + 4, 61);
        try std.testing.expectEqual(@as(usize, 3), p.records());
        // A cell that was not held takes its record now, and a new instance starts clean.
        try p.set(mark + 1, 62);
        try std.testing.expectEqual(@as(usize, 4), p.records());
        const new = try p.allocate(&.{ .{ .integer = 20 }, .{ .integer = 21 } });
        try std.testing.expectEqual(mark + 5, new);
        try p.set(new + 1, 22);
        try std.testing.expectEqual(@as(usize, 5), p.records());
        // A nested region over the moved cells commits and aborts as over any others.
        try p.begin();
        try p.set(mark + 2, 70);
        try p.abort();
        try std.testing.expectEqual(@as(i64, 60), try p.get(mark + 2));
        try p.begin();
        try p.set(mark + 2, 71);
        try p.commit();
        try std.testing.expectEqual(@as(i64, 71), try p.get(mark + 2));
        try std.testing.expectEqual(@as(usize, 5), p.records());
        // Rolling the region back forgets every cell it created and restores the older one.
        try p.abort();
        try std.testing.expectEqual(@as(usize, 0), p.records());
        try std.testing.expectEqual(@as(usize, mark), p.journal.cell_count);
        try std.testing.expectEqual(@as(i64, 8), try p.get(old + 1));
        try std.testing.expectError(error.SourceCellIndex, p.journal.read(mark));
        try std.testing.expectError(error.SourceCellIndex, p.reference.read(mark));
        // The same after a commit into the root: nothing is left to trip over.
        try p.begin();
        const again = try p.allocate(&.{ .{ .integer = 30 }, .{ .integer = 31 }, .{ .integer = 32 } });
        try std.testing.expectEqual(mark, again);
        const more = try p.allocate(&.{ .{ .integer = 40 }, .{ .integer = 41 } });
        try p.set(more + 1, 42);
        p.journal.relocate(mark, &.{ 0, 0, 0, 1, 2 });
        p.reference.relocate(mark, &.{ 0, 0, 0, 1, 2 });
        try p.agree();
        try std.testing.expectEqual(@as(usize, 1), p.records());
        try std.testing.expectEqual(@as(i64, 42), try p.get(mark + 1));
        try p.commit();
        try std.testing.expectEqual(@as(usize, 0), p.records());
        try std.testing.expectEqual(@as(i64, 42), try p.get(mark + 1));
        try p.begin();
        try p.set(mark + 1, 43);
        try std.testing.expectEqual(@as(usize, 1), p.records());
        try p.abort();
        try std.testing.expectEqual(@as(i64, 42), try p.get(mark + 1));
        p.journal.abortAll();
        p.reference.abortAll();
        try p.agree();
    }
}

/// A full copy of every cell per open region, and a flag per region and cell for "written here":
/// nothing shared with either implementation, and nothing to get wrong.
const Snapshots = struct {
    const depth_limit = 6;
    const Frame = struct { cells: []Cell, written: []bool, count: usize };
    cells: []Cell,
    count: usize,
    frames: [depth_limit]Frame,
    depth: usize = 0,

    fn create(allocator: std.mem.Allocator, capacity: usize, count: usize) !Snapshots {
        var self: Snapshots = .{ .cells = try allocator.alloc(Cell, capacity), .count = count, .frames = undefined };
        @memset(self.cells, .{});
        for (&self.frames) |*frame| frame.* = .{ .cells = try allocator.alloc(Cell, capacity), .written = try allocator.alloc(bool, capacity), .count = 0 };
        return self;
    }
    fn destroy(self: *Snapshots, allocator: std.mem.Allocator) void {
        for (self.frames) |frame| {
            allocator.free(frame.cells);
            allocator.free(frame.written);
        }
        allocator.free(self.cells);
    }
    fn begin(self: *Snapshots) void {
        const frame = &self.frames[self.depth];
        @memcpy(frame.cells, self.cells);
        @memset(frame.written, false);
        frame.count = self.count;
        self.depth += 1;
    }
    fn write(self: *Snapshots, cell: u32, value: types.Value) void {
        self.frames[self.depth - 1].written[cell] = true;
        self.cells[cell] = .{ .value = value, .initialized = true };
    }
    fn commit(self: *Snapshots) void {
        self.depth -= 1;
        if (self.depth == 0) return;
        for (self.frames[self.depth - 1].written, self.frames[self.depth].written) |*parent, child| parent.* = parent.* or child;
    }
    fn abort(self: *Snapshots) void {
        self.depth -= 1;
        self.count = self.frames[self.depth].count;
        // A discarded run: the program's cells as `reset` left them.
        if (self.depth == 0) @memset(self.cells, .{}) else @memcpy(self.cells, self.frames[self.depth].cells);
    }
    /// What the regions other than the root must be able to restore.
    fn records(self: *const Snapshots) usize {
        var total: usize = 0;
        for (self.frames[1..@max(self.depth, 1)]) |frame| total += std.mem.count(bool, frame.written, &.{true});
        return total;
    }
};

test "four thousand random region actions agree with a snapshot per region" {
    const p = try pair();
    defer @import("scratch.zig").release(p);
    const allocator = std.testing.allocator;
    const instance_cells = 24;
    // Few program cells: instances share the reference's images. All of them: instances are
    // restored from its records. The journal treats both alike.
    for ([_]usize{ 3, types.limits.source_cells }, [_]u64{ 0x77345f31, 0x77345f32 }) |count, seed| {
        var model = try Snapshots.create(allocator, count + instance_cells, count);
        defer model.destroy(allocator);
        var random = std.Random.DefaultPrng.init(seed);
        const r = random.random();
        p.reset(count);
        var most_records: usize = 0;
        var aborted_writes: usize = 0;
        for (0..4000) |iteration| {
            const action = r.uintLessThan(u8, 16);
            if (p.journal.depth == 0) {
                // A root region only ever begins from the state `reset` gives.
                p.reset(count);
                @memset(model.cells, .{});
                model.count = count;
                try p.begin();
                model.begin();
            } else if (action < 3 and model.depth < Snapshots.depth_limit) {
                try p.begin();
                model.begin();
            } else if (action < 5) {
                try p.commit();
                model.commit();
            } else if (action < 7) {
                aborted_writes += model.records();
                try p.abort();
                model.abort();
            } else if (action < 9 and model.count + 3 <= model.cells.len) {
                const values = [_]types.Value{ .{ .integer = @intCast(iteration) }, .{ .boolean = true }, .{ .integer = -1 } };
                const length = 1 + r.uintLessThan(usize, values.len);
                const first = try p.allocate(values[0..length]);
                try std.testing.expectEqual(model.count, first);
                for (values[0..length], model.cells[first..][0..length]) |value, *cell| cell.* = .{ .value = value, .initialized = true };
                model.count += length;
            } else {
                // Mostly the first few cells and the instances, so that regions collide on them.
                const cell: u32 = @intCast(if (model.count > count and r.boolean()) count + r.uintLessThan(usize, model.count - count) else r.uintLessThan(usize, @min(count, 3)));
                const value: types.Value = if (iteration % 3 == 0) .{ .boolean = iteration % 2 == 0 } else .{ .integer = @intCast(iteration) };
                const initialize = !model.cells[cell].initialized;
                try p.journal.write(cell, value, initialize);
                try p.reference.write(cell, value, initialize);
                model.write(cell, value);
            }
            try p.agree();
            try std.testing.expectEqual(model.depth, p.journal.depth);
            try std.testing.expectEqual(model.count, p.journal.cell_count);
            try std.testing.expectEqual(model.records(), p.journal.undo_count);
            most_records = @max(most_records, model.records());
            for ([_][2]usize{ .{ 0, @min(count, 3) }, .{ count, model.count } }) |range| {
                for (model.cells[range[0]..range[1]], p.journal.cells[range[0]..range[1]], p.reference.cells[range[0]..range[1]]) |expected, a, b| {
                    try std.testing.expectEqualDeep(expected, a);
                    try std.testing.expectEqualDeep(expected, b);
                }
            }
        }
        // The walk reached nested records and rolled some back; otherwise it proved little.
        try std.testing.expect(most_records >= 8 and aborted_writes >= 100);
        p.journal.abortAll();
        p.reference.abortAll();
        try p.agree();
    }
}
