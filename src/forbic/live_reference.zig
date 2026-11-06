//! Live variables (RFC-0084, P4.1) in the reference evaluator: dependency entries and stamps,
//! the count of entries that must be kept, heights, the dirty set and tracking, written from
//! the RFC's rules L1 to L7. The evaluator runs guards and propagations with these. The VM and
//! the report replay keep the same rules in their own code; nothing here is shared with them.
//!
//! A record is an instance of `live(T)` (`catalogue.live_cells`). Its stamp and height are
//! cells, so a region that fails restores them with every other cell, and the link of a cell to
//! its record is part of the cell. What a rollback cannot restore by itself is kept with the
//! region marks of the reference's state (`source_state.Live`): the count of valid entries, the
//! stamp a region began at, above which its entries are dropped here before the next live
//! operation (`settle`), and the length of the log of entries it took off their lists.
//!
//! The entries are one array in stamp order: an evaluation takes the next stamp and appends its
//! entries together, a rollback drops the newest, and compaction keeps the order. So the
//! entries of one evaluation are found by their stamp alone (`count`). Each cell's valid
//! entries are also linked in the order they were made, which is the order propagation and
//! raising read (RFC-0084 C16): an entry leaves its list when it stops being valid, and one that
//! a rollback can revive is logged and put back by it. So a walk of a list visits valid entries
//! only, each charged.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");

pub const Store = call_frames.ReferenceLive;
const State = source_state.ReferenceState;
const Entry = call_frames.ReferenceLiveEntry;
const none = call_frames.no_entry;
const no_link = source_state.no_link;
const room = call_frames.live_entry_room;
const cap: u64 = types.limits.live_height;
const observer = call_frames.observer_entry;
pub const Error = source_state.Error || error{ LiveEdgeLimit, WorkLimit };

/// Prepares the store for a run; a program without `cell_live` leaves it off and pays nothing.
pub fn reset(store: *Store, on: bool, definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type) void {
    store.on = on;
    store.entry_count = 0;
    store.log_count = 0;
    store.listed = 0;
    store.heap_count = 0;
    store.raise_head = 0;
    store.raise_count = 0;
    store.tracking = false;
    store.read_count = 0;
    store.propagation = 0;
    store.record = .{};
    store.pending_head = 0;
    store.pending_tail = 0;
    store.pending_mark_count = 0;
    store.batch = 0;
    store.delivering = false;
    store.delivery_count = 0;
    store.drain_turn = false;
    store.comparable_count = @intCast(definitions.len);
    if (on) catalogue.comparableTypes(definitions, fields, tuple_elements, store.comparable[0..definitions.len]);
}

/// Gives the cells up to `cell` their empty bookkeeping, as a live program comes to name them.
fn list(store: *Store, cell: u32) void {
    while (store.listed <= cell) : (store.listed += 1) store.cells[store.listed] = .{ .first = none, .last = none, .heap = none, .queued = false, .seen = 0, .evaluated = 0 };
}

pub fn stampOf(state: *const State, record: u32) u64 {
    return @intCast(state.cells[record + catalogue.live_stamp].value.integer);
}
pub fn heightOf(state: *const State, record: u32) u64 {
    return @intCast(state.cells[record + catalogue.live_height].value.integer);
}
/// The cell a record follows: a module cell (its owner is itself), or a field of its owner.
pub fn targetOf(state: *const State, record: u32) u32 {
    const owner = state.cells[record + catalogue.live_owner].value.object.id;
    const place: u32 = @intCast(state.cells[record + catalogue.live_place].value.integer);
    return if (owner == record) place else owner + 1 + place;
}
/// L4: an entry is valid while its record is attached and has not been evaluated since, or,
/// for a reaction (P4.4), while it waits on its guard with the stamp of the evaluation that made
/// the entry. The listed entries are exactly the valid ones; this checks it.
fn valid(store: *const Store, state: *const State, entry: Entry) bool {
    if (entry.record & observer != 0) return store.observers[entry.record & ~observer].stamp == entry.stamp;
    return stampOf(state, entry.record) == entry.stamp and state.cells[targetOf(state, entry.record)].link == entry.record;
}

/// The first entry whose stamp is at least `stamp`.
fn lowerBound(store: *const Store, stamp: u64) u32 {
    var low: u32 = 0;
    var high: u32 = store.entry_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (store.entries[middle].stamp < stamp) low = middle + 1 else high = middle;
    }
    return low;
}
/// The entries of the latest evaluation of an attached record: all of them are valid.
pub fn count(store: *const Store, state: *const State, record: u32) u64 {
    const stamp = stampOf(state, record);
    if (stamp == 0) return 0;
    return lowerBound(store, stamp + 1) - lowerBound(store, stamp);
}

fn linkLast(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    list(store, entry.cell);
    const cell = &store.cells[entry.cell];
    entry.before = cell.last;
    entry.after = none;
    entry.listed = true;
    if (cell.last == none) cell.first = index else store.entries[cell.last].after = index;
    cell.last = index;
}
/// Takes an entry off its cell's list. It keeps `before`, the entry it followed.
fn unlist(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    std.debug.assert(entry.listed);
    const cell = &store.cells[entry.cell];
    if (entry.before == none) cell.first = entry.after else store.entries[entry.before].after = entry.after;
    if (entry.after == none) cell.last = entry.before else store.entries[entry.after].before = entry.before;
    entry.listed = false;
}
/// Puts a logged entry back after the entry it followed. Entries come back in the reverse of
/// the order they left, after the entries recorded since have been dropped, so that entry is
/// listed again and the list is as it was.
fn relist(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    std.debug.assert(!entry.listed);
    const cell = &store.cells[entry.cell];
    const after = if (entry.before == none) cell.first else store.entries[entry.before].after;
    std.debug.assert(entry.before == none or store.entries[entry.before].listed);
    entry.after = after;
    if (entry.before == none) cell.first = index else store.entries[entry.before].after = index;
    if (after == none) cell.last = index else store.entries[after].before = index;
    entry.listed = true;
}
/// The entries of the evaluation that took `stamp` stop being valid: they leave their lists.
/// In a region, those recorded before its innermost region began can be revived by its
/// rollback, so they are logged; the others never come back.
fn unlistRun(store: *Store, state: *State, stamp: u64) void {
    const keep = state.depth > 1 and stamp <= state.live_marks[state.depth - 1].stamp;
    var index = lowerBound(store, stamp);
    while (index < store.entry_count and store.entries[index].stamp == stamp) : (index += 1) {
        unlist(store, index);
        if (!keep) continue;
        store.log[store.log_count] = index;
        store.log_count += 1;
    }
    state.live.log = store.log_count;
}
/// What failed regions left for the store to do: their entries go, and the entries they took
/// off the lists come back, newest first. Done before every live operation and reclamation.
fn undoFailed(store: *Store, state: *State) void {
    if (state.live.dropped != source_state.Live.none) {
        const stamp = state.live.dropped;
        while (store.entry_count != 0 and store.entries[store.entry_count - 1].stamp > stamp) {
            store.entry_count -= 1;
            if (store.entries[store.entry_count].listed) {
                std.debug.assert(store.cells[store.entries[store.entry_count].cell].last == store.entry_count);
                unlist(store, store.entry_count);
            }
        }
        state.live.dropped = source_state.Live.none;
    }
    if (state.live.unlog != source_state.Live.none) {
        while (store.log_count > state.live.unlog) {
            store.log_count -= 1;
            const index = store.log[store.log_count];
            // An entry the failed region recorded and then took off has been dropped.
            if (index < store.entry_count) relist(store, index);
        }
        state.live.unlog = source_state.Live.none;
        state.live.log = store.log_count;
        // Regions begun since the failure took the log's length before it was cut back.
        var depth = state.depth;
        while (depth > 1 and state.live_marks[depth - 1].log > store.log_count) : (depth -= 1) state.live_marks[depth - 1].log = store.log_count;
    }
}
/// Keeps the logged entries a rollback of an open region can still revive: those recorded before
/// the innermost region began. One recorded since was logged in a region that has committed; a
/// rollback of the innermost region drops it, so no region needs it, and a reclamation may drop it
/// (C19). They lie after the innermost region's part of the log, so no region's length moves.
fn pruneLog(store: *Store, state: *State) void {
    const top = state.live_marks[state.depth - 1].stamp;
    var kept: u32 = 0;
    for (store.log[0..store.log_count]) |index| {
        if (store.entries[index].stamp > top) continue;
        store.log[kept] = index;
        kept += 1;
    }
    store.log_count = kept;
    state.live.log = kept;
}
/// Keeps only the listed entries, in order. Called where no entry taken off can come back:
/// outside every region, or before a live operation of an outermost region has made any.
fn compact(store: *Store, state: *const State) void {
    std.debug.assert(store.log_count == 0);
    var kept: u32 = 0;
    for (0..store.entry_count) |index| {
        const entry = store.entries[index];
        if (!entry.listed) continue;
        std.debug.assert(valid(store, state, entry));
        store.entries[kept] = entry;
        kept += 1;
    }
    for (store.entries[0..kept]) |entry| {
        store.cells[entry.cell].first = none;
        store.cells[entry.cell].last = none;
    }
    for (0..kept) |index| linkLast(store, @intCast(index));
    store.entry_count = kept;
    std.debug.assert(kept == state.live.valid);
}
/// Outside every region, and before an outermost region has taken an entry off, the logged
/// entries were taken off in regions that committed: none can come back.
fn forgetLog(store: *Store, state: *State) void {
    if (store.log_count == 0) return;
    store.log_count = 0;
    state.live.log = 0;
    for (state.live_marks[0..state.depth]) |*mark| mark.log = 0;
}
/// Before every live operation: what failed regions left is undone; outside every region, or at
/// the first live operation of an outermost one (`source_state.Live.opened`), no entry taken
/// off a list can come back, so the log is forgotten, and the store is compacted when its
/// unlisted entries outnumber half the valid ones plus 32.
pub fn settle(store: *Store, state: *State) void {
    undoFailed(store, state);
    const opened = state.live.opened;
    state.live.opened = false;
    if (state.depth > 1 and !opened) return;
    forgetLog(store, state);
    const kept = state.live.valid;
    if (2 * (store.entry_count - kept) > kept + 64) compact(store, state);
}

/// L3: a guard begins with a fresh stamp, which no rollback takes back, and no reads.
pub fn begin(store: *Store, state: *State) u64 {
    std.debug.assert(!store.tracking);
    state.live.stamp += 1;
    store.tracking = true;
    store.read_count = 0;
    return state.live.stamp;
}
/// A read the running guard makes of a mutable cell, in the order of its first occurrence.
pub fn track(store: *Store, state: *const State, cell: u32) void {
    std.debug.assert(store.tracking);
    list(store, cell);
    const stamp = state.live.stamp;
    if (store.cells[cell].seen == stamp) return;
    store.cells[cell].seen = stamp;
    store.reads[store.read_count] = cell;
    store.read_count += 1;
}
pub fn end(store: *Store) void {
    store.tracking = false;
}

/// L4, limits: the count `live_edge_limit` bounds for an evaluation whose dependent has `old`
/// valid entries and that reads `n` cells. Outside every region it is the valid entries the
/// evaluation leaves; inside one, the valid entries when the outermost region began and every
/// entry recorded since and not dropped by an inner rollback, which a rollback could still
/// need. Entries a failed region left that are still to be dropped are not counted.
pub fn required(store: *const Store, state: *const State, old: u64, n: u64) u64 {
    if (state.depth <= 1) return state.live.valid - old + n;
    const mark = state.live_marks[1];
    const end_at = if (state.live.dropped == source_state.Live.none) store.entry_count else lowerBound(store, state.live.dropped + 1);
    const recorded = end_at - @min(end_at, lowerBound(store, mark.stamp + 1));
    return mark.valid + recorded + n;
}
/// The bound, then one unit of fuel per entry recorded and per entry the evaluation's own
/// earlier entries leave behind, in that order (C9).
pub fn check(store: *const Store, state: *const State, old: u64, remaining: *u64) Error!void {
    const n = store.read_count;
    if (required(store, state, old, n) > types.limits.live_edges) return error.LiveEdgeLimit;
    if (remaining.* < n + old) return error.WorkLimit;
    remaining.* -= n + old;
}
/// Appends the entries of the evaluation of `record` whose stamp its stamp cell already holds;
/// those of its evaluation that took `old_stamp` (0 for none) leave their lists.
pub fn append(store: *Store, state: *State, record: u32, stamp: u64, old_stamp: u64, old: u64) void {
    const n = store.read_count;
    if (old_stamp != 0) unlistRun(store, state, old_stamp);
    // The old entries are off their lists, so the valid ones are `V - old` until the new ones
    // are appended, also for a compaction here.
    state.live.valid -= old;
    if (store.entry_count + n > room) {
        // Only outside every region: inside one the store has room for what the count allows.
        std.debug.assert(state.depth <= 1);
        compact(store, state);
    }
    std.debug.assert(store.entry_count + n <= room);
    // The record's own bookkeeping (its place in the dirty heap, its counts) too; a reaction's
    // is its slot's (P4.4).
    if (record & observer == 0) list(store, record);
    for (store.reads[0..n]) |cell| {
        store.entries[store.entry_count] = .{ .cell = cell, .record = record, .stamp = stamp, .before = none, .after = none, .listed = false };
        linkLast(store, store.entry_count);
        store.entry_count += 1;
    }
    state.live.valid += n;
    store.record.entries += n;
}

/// The record attached to a cell stops being so: its entries leave their lists, one unit each.
fn release(store: *Store, state: *State, record: u32, remaining: *u64) Error!void {
    const entries = count(store, state, record);
    if (remaining.* < entries) return error.WorkLimit;
    remaining.* -= entries;
    unlistRun(store, state, stampOf(state, record));
    state.live.valid -= entries;
}
/// L2: a program write of `cell` detaches the record attached to it.
pub fn detach(store: *Store, state: *State, cell: u32, remaining: *u64) Error!void {
    const link = state.cells[cell].link;
    if (link == no_link) return;
    settle(store, state);
    try release(store, state, link, remaining);
    try state.setLink(cell, no_link);
}
/// L2, establishing: `record` replaces whatever record the cell had.
pub fn attach(store: *Store, state: *State, cell: u32, record: u32, remaining: *u64) Error!void {
    const link = state.cells[cell].link;
    if (link != no_link) try release(store, state, link, remaining);
    try state.setLink(cell, record);
}

/// L5: one above the highest record attached to a cell the evaluation read, other than the
/// record itself (a plain cell is 0), up to the cap. `own` is the record's target, which is
/// attached to the record by the time the height is taken, so its reads count for nothing.
pub fn heightFor(store: *const Store, state: *const State, record: u32, own: u32) u64 {
    var top: u64 = 0;
    for (store.reads[0..store.read_count]) |cell| {
        if (cell == own) continue;
        const link = state.cells[cell].link;
        if (link != no_link and link != record) top = @max(top, heightOf(state, link));
    }
    return @min(cap, top + 1);
}
/// L5: every record reading the target of `record` that does not stand above it is raised to
/// one above, up to the cap, and so on from each record raised: a worklist in the order the
/// entries are found, in which a record already waiting is not added again. One unit for each
/// entry looked at (C9).
pub fn raise(store: *Store, state: *State, record: u32, remaining: *u64) Error!void {
    std.debug.assert(store.raise_count == 0);
    store.raise_head = 0;
    store.raise[0] = record;
    store.raise_count = 1;
    store.cells[record].queued = true;
    while (store.raise_count != 0) {
        const source = store.raise[store.raise_head];
        store.raise_head = (store.raise_head + 1) % @as(u32, @intCast(store.raise.len));
        store.raise_count -= 1;
        store.cells[source].queued = false;
        const height = heightOf(state, source);
        const target = targetOf(state, source);
        if (target >= store.listed) continue;
        var at = store.cells[target].first;
        while (at != none) {
            const entry = store.entries[at];
            at = entry.after;
            std.debug.assert(valid(store, state, entry));
            if (remaining.* == 0) return error.WorkLimit;
            remaining.* -= 1;
            // A reaction that reads the target has no height (P4.4).
            if (entry.record & observer != 0) continue;
            const reader = entry.record;
            const old = heightOf(state, reader);
            if (old > height or old >= cap) continue;
            try state.write(reader + catalogue.live_height, .{ .integer = @intCast(@min(cap, height + 1)) }, false);
            if (store.cells[reader].heap != none) heapDown(store, state, store.cells[reader].heap);
            if (!store.cells[reader].queued) {
                store.raise[(store.raise_head + store.raise_count) % @as(u32, @intCast(store.raise.len))] = reader;
                store.raise_count += 1;
                store.cells[reader].queued = true;
            }
        }
    }
}

/// The dirty set (L5): records by (height, id), the heights as they are when one is taken.
fn sooner(state: *const State, a: u32, b: u32) bool {
    const ha = heightOf(state, a);
    const hb = heightOf(state, b);
    return ha < hb or (ha == hb and a < b);
}
fn heapPlace(store: *Store, at: u32, record: u32) void {
    store.heap[at] = record;
    store.cells[record].heap = at;
}
fn heapUp(store: *Store, state: *const State, start: u32) void {
    var at = start;
    const record = store.heap[at];
    while (at != 0) {
        const parent = (at - 1) / 2;
        if (!sooner(state, record, store.heap[parent])) break;
        heapPlace(store, at, store.heap[parent]);
        at = parent;
    }
    heapPlace(store, at, record);
}
fn heapDown(store: *Store, state: *const State, start: u32) void {
    var at = start;
    const record = store.heap[at];
    while (true) {
        const left = 2 * at + 1;
        if (left >= store.heap_count) break;
        const right = left + 1;
        const child = if (right < store.heap_count and sooner(state, store.heap[right], store.heap[left])) right else left;
        if (!sooner(state, store.heap[child], record)) break;
        heapPlace(store, at, store.heap[child]);
        at = child;
    }
    heapPlace(store, at, record);
}
/// Adds to the dirty set every record with a valid entry for `cell` that is not in it, one
/// unit for each entry looked at (C9). A reaction with a valid entry is notified instead (N1,
/// P4.4): it joins the pending list unless it is there, one unit more, in the order of the
/// entries. `depth` is the run's region depth, whose regions mark the list.
pub fn dirty(store: *Store, state: *const State, cell: u32, depth: u32, remaining: *u64) Error!void {
    if (cell >= store.listed) return;
    var at = store.cells[cell].first;
    while (at != none) {
        const entry = store.entries[at];
        at = entry.after;
        std.debug.assert(valid(store, state, entry));
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        if (entry.record & observer != 0) {
            try notify(store, entry.record & ~observer, depth, remaining);
            continue;
        }
        if (store.cells[entry.record].heap != none) continue;
        std.debug.assert(store.heap_count < store.heap.len);
        heapPlace(store, store.heap_count, entry.record);
        store.heap_count += 1;
        heapUp(store, state, store.heap_count - 1);
    }
}
/// Takes the dirty record that comes first.
pub fn take(store: *Store, state: *const State) ?u32 {
    if (store.heap_count == 0) return null;
    const first = store.heap[0];
    store.heap_count -= 1;
    store.cells[first].heap = none;
    if (store.heap_count != 0) {
        heapPlace(store, 0, store.heap[store.heap_count]);
        heapDown(store, state, 0);
    }
    return first;
}
/// Counts an evaluation of `record` in the current propagation; returns how many it has had.
pub fn counted(store: *Store, record: u32) u64 {
    const cell = &store.cells[record];
    const bits = 20;
    if (cell.evaluated >> bits != store.propagation) cell.evaluated = store.propagation << bits;
    cell.evaluated += 1;
    return cell.evaluated & ((1 << bits) - 1);
}
/// A new propagation (L5): it numbers the evaluation counts of its records.
pub fn startPropagation(store: *Store) void {
    std.debug.assert(store.heap_count == 0);
    store.propagation += 1;
    store.record.propagations += 1;
}
/// When a propagation stops at a fatal error the run ends; nothing needs undoing here.
pub fn comparableTarget(store: *const Store, value_type: types.Type) bool {
    return catalogue.comparableIn(value_type, store.comparable[0..store.comparable_count]);
}

/// Reclamation (RFC-0084, "Reclamation" points 2 and 4): the entries name cells and records
/// by position. What failed regions left is undone first (C18), and the log keeps only what an
/// open region can revive (`pruneLog`, C19). Entries whose cell or record goes
/// are dropped, the others are renumbered with `forward` (0 for a cell that goes, otherwise one
/// more than its place above `mark`), and the lists are rebuilt in order (`relink`). Outside
/// every region the unlisted entries go as well.
///
/// A valid entry goes only with its record and its cell (P4.2, C23, C24). A record is reached
/// through the link of its target, and through every cell it reads that is reached (the walk
/// follows `Readers`), so one that goes can never be evaluated again: a field's record whose
/// instance and dependencies nothing reaches. Such a record was built after the frame was
/// pushed, so after every open region began, and its entries are counted above every region's
/// mark: the count of valid entries loses them and no region's mark changes. The cell of a
/// valid entry whose record stays does not go: the guard reached it from a cell it read or
/// from what it captured, which the record reaches, and a change on that path would have
/// evaluated it again. Logged entries keep their places: those kept were recorded before the
/// innermost open region began, so before the frame was pushed, and every entry that goes was
/// recorded after it.
pub fn relocate(store: *Store, state: *State, mark: u32, forward: []const u32) void {
    undoFailed(store, state);
    for (store.entries[0..store.entry_count]) |entry| if (entry.listed) {
        store.cells[entry.cell].first = none;
        store.cells[entry.cell].last = none;
    };
    var kept: u32 = 0;
    const tidy = state.depth <= 1;
    if (tidy or state.live.opened) forgetLog(store, state) else pruneLog(store, state);
    for (0..store.entry_count) |index| {
        var entry = store.entries[index];
        const reaction = entry.record & observer != 0;
        const cell_goes = entry.cell >= mark and forward[entry.cell - mark] == 0;
        const record_goes = !reaction and entry.record >= mark and forward[entry.record - mark] == 0;
        if (cell_goes or record_goes or (tidy and !entry.listed)) {
            if (entry.listed) {
                // A reaction keeps no cell: one it read that nothing reaches any more goes, and
                // its entry with it (P4.4, C49). The reaction is charged for what it recorded.
                std.debug.assert((reaction and cell_goes) or (record_goes and cell_goes and (state.depth <= 1 or entry.stamp > state.live_marks[state.depth - 1].stamp)));
                state.live.valid -= 1;
            }
            continue;
        }
        if (entry.cell >= mark) entry.cell = mark + forward[entry.cell - mark] - 1;
        if (!reaction and entry.record >= mark) entry.record = mark + forward[entry.record - mark] - 1;
        store.entries[kept] = entry;
        kept += 1;
    }
    for (store.log[0..store.log_count]) |index| std.debug.assert(index < kept and store.entries[index].stamp <= state.live_marks[state.depth - 1].stamp);
    store.entry_count = kept;
    state.live.log = store.log_count;
}
/// Before a reclamation's walk: what failed regions left is undone, so that the lists hold the
/// valid entries the walk follows (C24).
pub fn beforeReclaim(store: *Store, state: *State) void {
    undoFailed(store, state);
}
/// The records with a valid entry for `cell`, oldest first: a reclamation keeps each record
/// that reads a cell it keeps (C24).
pub const Readers = struct {
    store: *const Store,
    at: u32,
    pub fn of(store: *const Store, cell: u32) Readers {
        return .{ .store = store, .at = if (cell < store.listed) store.cells[cell].first else none };
    }
    pub fn next(self: *Readers) ?u32 {
        while (self.at != none) {
            const entry = self.store.entries[self.at];
            self.at = entry.after;
            // A reaction is the scheduler's, which keeps it (P4.4).
            if (entry.record & observer == 0) return entry.record;
        }
        return null;
    }
};
/// After the cells moved: the lists again, over the listed entries as `relocate` left them.
/// An unlisted entry keeps the `before` it had, which names an entry that did not move.
pub fn relink(store: *Store) void {
    for (0..store.entry_count) |index| if (store.entries[index].listed) linkLast(store, @intCast(index));
}
/// The entries the reclamation measure counts (`ControlStorage.reclaimExamined`): the count
/// `live_edge_limit` bounds, which no implementation's compaction changes.
pub fn measure(store: *const Store, state: *const State) u64 {
    if (!store.on) return 0;
    return required(store, state, 0, 0);
}

// Reactions (RFC-0084, P4.4). A reaction is a dependent like a record, named in its entries by
// its task slot (`call_frames.observer_entry`). Its stamp and the number of entries it recorded
// are kept here, not in cells: a reaction is evaluated, fired and notified of only outside every
// region, so nothing about it is ever rolled back except its place on the pending list, which
// the list's marks restore (R2).

/// A slot taken by a new reaction starts with no entries and not notified.
pub fn observerReset(store: *Store, slot: u32) void {
    store.observers[slot] = .{};
}
/// The entries of the latest evaluation of the reaction in `slot` that are still in the store:
/// all it recorded, but those of cells a reclamation forgot.
fn observerHeld(store: *const Store, slot: u32) u64 {
    const stamp = store.observers[slot].stamp;
    if (stamp == 0) return 0;
    return lowerBound(store, stamp + 1) - lowerBound(store, stamp);
}
/// The bound and the fuel of an evaluation of the reaction in `slot` that read `read_count`
/// cells (L4, C9): its earlier entries leave their lists, and it is charged for as many as it
/// recorded then.
pub fn observerCheck(store: *const Store, state: *const State, slot: u32, remaining: *u64) Error!void {
    const n = store.read_count;
    if (required(store, state, observerHeld(store, slot), n) > types.limits.live_edges) return error.LiveEdgeLimit;
    const old = store.observers[slot].entries;
    if (remaining.* < n + old) return error.WorkLimit;
    remaining.* -= n + old;
}
/// Records the reads of the evaluation of the reaction in `slot` that took `stamp`: it waits on
/// its guard with these dependencies from now on.
pub fn observerAppend(store: *Store, state: *State, slot: u32, stamp: u64) void {
    const n = store.read_count;
    const previous = store.observers[slot].stamp;
    append(store, state, observer | slot, stamp, previous, observerHeld(store, slot));
    store.observers[slot].stamp = stamp;
    store.observers[slot].entries = n;
}
/// The reaction in `slot` stops waiting on its guard, to fire: its entries leave their lists, a
/// unit for each it recorded.
pub fn observerRelease(store: *Store, state: *State, slot: u32, remaining: *u64) Error!void {
    const charged = store.observers[slot].entries;
    if (remaining.* < charged) return error.WorkLimit;
    remaining.* -= charged;
    const held = observerHeld(store, slot);
    if (store.observers[slot].stamp != 0) unlistRun(store, state, store.observers[slot].stamp);
    state.live.valid -= held;
    store.observers[slot].stamp = 0;
    store.observers[slot].entries = 0;
}
/// N1: the reaction in `slot` joins the pending list unless it is there, one unit. A region open
/// at `depth` that notifies for the first time marks the list, so that its rollback takes back
/// what it added (R2).
fn notify(store: *Store, slot: u32, depth: u32, remaining: *u64) Error!void {
    const entry = &store.observers[slot];
    if (entry.pending) return;
    if (remaining.* == 0) return error.WorkLimit;
    remaining.* -= 1;
    if (depth != 0 and (store.pending_mark_count == 0 or store.pending_marks[store.pending_mark_count - 1].depth != depth)) {
        // A mark owns at least one entry of the list, which holds a slot at most once.
        store.pending_marks[store.pending_mark_count] = .{ .depth = depth, .count = store.pending_tail };
        store.pending_mark_count += 1;
    }
    std.debug.assert(store.pending_tail - store.pending_head < store.pending.len);
    store.pending[store.pending_tail % store.pending.len] = slot;
    store.pending_tail += 1;
    entry.pending = true;
}
/// The region `closing` deep committed: what it notified now belongs to the region around it.
pub fn pendingCommit(store: *Store, closing: u32) void {
    if (store.pending_mark_count == 0 or store.pending_marks[store.pending_mark_count - 1].depth != closing) return;
    if (closing == 1 or (store.pending_mark_count > 1 and store.pending_marks[store.pending_mark_count - 2].depth == closing - 1)) {
        store.pending_mark_count -= 1;
    } else store.pending_marks[store.pending_mark_count - 1].depth = closing - 1;
}
/// The region `closing` deep failed: the reactions it notified are not notified (R2).
pub fn pendingAbort(store: *Store, closing: u32) void {
    if (store.pending_mark_count == 0 or store.pending_marks[store.pending_mark_count - 1].depth != closing) return;
    const mark = store.pending_marks[store.pending_mark_count - 1];
    store.pending_mark_count -= 1;
    std.debug.assert(mark.count >= store.pending_head and mark.count < store.pending_tail);
    while (store.pending_tail > mark.count) {
        store.pending_tail -= 1;
        store.observers[store.pending[store.pending_tail % store.pending.len]].pending = false;
    }
}
/// The front of the pending list, which is no longer pending (N4 step 1).
pub fn takePending(store: *Store) ?u32 {
    if (store.pending_head == store.pending_tail) return null;
    std.debug.assert(store.pending_mark_count == 0);
    const slot = store.pending[store.pending_head % store.pending.len];
    store.pending_head += 1;
    store.observers[slot].pending = false;
    return slot;
}
/// Whether a delivery point may deliver now (N3): no region is open, no batch or firing, no
/// guard runs, no loop is under way, and something is pending.
pub fn deliverable(store: *const Store, depth: u32) bool {
    return store.on and depth == 0 and store.batch == 0 and !store.tracking and !store.delivering and store.pending_head != store.pending_tail;
}
