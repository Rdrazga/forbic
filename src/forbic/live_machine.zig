//! Live variables (RFC-0084, P4.1) in the VM: the machine's own dependency store, tracking,
//! heights and dirty set, written from the RFC's rules L1 to L7 apart from the reference's
//! (`live_reference.zig`). The VM runs guards and propagations with these.
//!
//! All entries lie in one array in the order they were made, which is stamp order: a rollback
//! takes the newest off the end, and the entries of one evaluation are the run of its stamp.
//! Each cell's valid entries are chained both ways, from `oldest` through `newer` and from
//! `newest` through `older`, and the rules visit them oldest first (RFC-0084 C16). An entry
//! that stops being valid leaves its chain; one that a rollback of an open region can revive
//! is kept in `taken`, and the rollback puts it back beside the entry it followed.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");

pub const Store = call_frames.VmLive;
const Journal = source_state.Journal;
const none = call_frames.no_entry;
const unlinked = source_state.no_link;
const height_cap: u64 = types.limits.live_height;
const watcher = call_frames.observer_entry;
pub const Error = source_state.Error || error{ LiveEdgeLimit, WorkLimit };

pub fn start(store: *Store, on: bool, definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type) void {
    store.on = on;
    store.count = 0;
    store.taken_len = 0;
    store.known = 0;
    store.heap_len = 0;
    store.pending_first = 0;
    store.pending_len = 0;
    store.tracking = false;
    store.read_len = 0;
    store.propagation = 0;
    store.record = .{};
    store.notified_first = 0;
    store.notified_end = 0;
    store.notified_mark_len = 0;
    store.firing_depth = 0;
    store.batches = 0;
    store.delivering = false;
    store.delivered = 0;
    store.drain_due = false;
    store.comparable_len = @intCast(definitions.len);
    if (on) catalogue.comparableTypes(definitions, fields, tuple_elements, store.comparable[0..definitions.len]);
}

/// Cells first named by a live program get empty bookkeeping.
fn know(store: *Store, cell: u32) void {
    while (store.known <= cell) {
        store.newest[store.known] = none;
        store.oldest[store.known] = none;
        store.seen[store.known] = 0;
        store.slot[store.known] = 0;
        store.tally[store.known] = 0;
        store.waiting[store.known] = false;
        store.known += 1;
    }
}
fn oldestOf(store: *const Store, cell: u32) u32 {
    return if (cell < store.known) store.oldest[cell] else none;
}

fn cellInteger(journal: *const Journal, cell: u32) i64 {
    return journal.cells[cell].value.integer;
}
pub fn stampOf(journal: *const Journal, record: u32) u64 {
    return @intCast(cellInteger(journal, record + catalogue.live_stamp));
}
pub fn heightOf(journal: *const Journal, record: u32) u64 {
    return @intCast(cellInteger(journal, record + catalogue.live_height));
}
/// The cell the record follows: its place among the program's cells when it owns itself,
/// otherwise a field of its owner.
pub fn targetOf(journal: *const Journal, record: u32) u32 {
    const owner = journal.cells[record + catalogue.live_owner].value.object.id;
    const place: u32 = @intCast(cellInteger(journal, record + catalogue.live_place));
    if (owner == record) return place;
    return owner + 1 + place;
}
/// An entry counts while its record holds its stamp and its target still names the record, or,
/// for a reaction (P4.4), while it waits on its guard with that stamp. The chained entries are
/// exactly those; this checks it.
fn holds(store: *const Store, journal: *const Journal, entry: call_frames.VmLiveEntry) bool {
    if (entry.record & watcher != 0) return store.watch_stamp[entry.record & ~watcher] == entry.stamp;
    if (stampOf(journal, entry.record) != entry.stamp) return false;
    return journal.cells[targetOf(journal, entry.record)].link == entry.record;
}

/// Where the run of entries with stamps of at least `stamp` begins.
fn firstFrom(store: *const Store, stamp: u64) u32 {
    var below: u32 = 0;
    var above: u32 = store.count;
    while (above > below) {
        const probe = (below + above) / 2;
        if (store.entries[probe].stamp >= stamp) above = probe else below = probe + 1;
    }
    return below;
}
/// The entries of a record's latest evaluation.
pub fn entriesOf(store: *const Store, journal: *const Journal, record: u32) u64 {
    const stamp = stampOf(journal, record);
    if (stamp == 0) return 0;
    return firstFrom(store, stamp + 1) - firstFrom(store, stamp);
}

/// Chains entry `index` in as its cell's newest.
fn chainNewest(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    know(store, entry.cell);
    const previous = store.newest[entry.cell];
    entry.older = previous;
    entry.newer = none;
    entry.chained = true;
    if (previous == none) store.oldest[entry.cell] = index else store.entries[previous].newer = index;
    store.newest[entry.cell] = index;
}
/// Takes an entry out of its chain; it keeps `older`.
fn unchain(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    assert(entry.chained);
    if (entry.older == none) store.oldest[entry.cell] = entry.newer else store.entries[entry.older].newer = entry.newer;
    if (entry.newer == none) store.newest[entry.cell] = entry.older else store.entries[entry.newer].older = entry.older;
    entry.chained = false;
}
/// Puts a taken entry back after its `older`, which is chained again by then: entries come
/// back newest taken first, once what was recorded after them has gone.
fn rechain(store: *Store, index: u32) void {
    const entry = &store.entries[index];
    assert(!entry.chained);
    const cell = entry.cell;
    const newer = if (entry.older == none) store.oldest[cell] else store.entries[entry.older].newer;
    assert(entry.older == none or store.entries[entry.older].chained);
    entry.newer = newer;
    if (entry.older == none) store.oldest[cell] = index else store.entries[entry.older].newer = index;
    if (newer == none) store.newest[cell] = index else store.entries[newer].older = index;
    entry.chained = true;
}
/// The run of `stamp` stops counting: out of the chains, kept in `taken` when a rollback of
/// the innermost open region would revive it (its stamp is older than that region).
fn unchainRun(store: *Store, journal: *Journal, stamp: u64) void {
    const revivable = journal.depth > 1 and stamp <= journal.live_marks[journal.depth - 1].stamp;
    var index = firstFrom(store, stamp);
    while (index < store.count and store.entries[index].stamp == stamp) : (index += 1) {
        unchain(store, index);
        if (revivable) {
            store.taken[store.taken_len] = index;
            store.taken_len += 1;
        }
    }
    journal.live.log = store.taken_len;
}
/// What failed regions left: the entries they recorded go, those they took out come back.
fn rollBack(store: *Store, journal: *Journal) void {
    if (journal.live.dropped != source_state.Live.none) {
        const above = journal.live.dropped;
        while (store.count != 0 and store.entries[store.count - 1].stamp > above) {
            store.count -= 1;
            if (!store.entries[store.count].chained) continue;
            assert(store.newest[store.entries[store.count].cell] == store.count);
            unchain(store, store.count);
        }
        journal.live.dropped = source_state.Live.none;
    }
    if (journal.live.unlog != source_state.Live.none) {
        while (store.taken_len > journal.live.unlog) {
            store.taken_len -= 1;
            const index = store.taken[store.taken_len];
            if (index < store.count) rechain(store, index);
        }
        journal.live.unlog = source_state.Live.none;
        journal.live.log = store.taken_len;
        // A region begun after the failure kept the length the log had before this.
        var level = journal.depth;
        while (level > 1 and journal.live_marks[level - 1].log > store.taken_len) : (level -= 1) journal.live_marks[level - 1].log = store.taken_len;
    }
}
/// Nothing taken can come back once every region has closed, or before an outermost region
/// takes anything out.
fn forgetTaken(store: *Store, journal: *Journal) void {
    if (store.taken_len == 0) return;
    store.taken_len = 0;
    journal.live.log = 0;
    for (journal.live_marks[0..journal.depth]) |*mark| mark.log = 0;
}
/// Keeps in `taken` only what a rollback of an open region can revive: entries recorded before
/// the innermost one began. The others were taken in regions that committed since, and the
/// innermost region's rollback drops them anyway; they lie after its part of `taken`.
fn pruneTaken(store: *Store, journal: *Journal) void {
    const top = journal.live_marks[journal.depth - 1].stamp;
    var kept: u32 = 0;
    for (store.taken[0..store.taken_len]) |index| {
        if (store.entries[index].stamp > top) continue;
        store.taken[kept] = index;
        kept += 1;
    }
    store.taken_len = kept;
    journal.live.log = kept;
}
fn sweep(store: *Store, journal: *const Journal) void {
    assert(store.taken_len == 0);
    const old_count = store.count;
    for (store.entries[0..old_count]) |entry| if (entry.chained) {
        store.newest[entry.cell] = none;
        store.oldest[entry.cell] = none;
    };
    var kept: u32 = 0;
    for (0..old_count) |index| {
        const entry = store.entries[index];
        if (!entry.chained) continue;
        assert(holds(store, journal, entry));
        store.entries[kept] = entry;
        chainNewest(store, kept);
        kept += 1;
    }
    store.count = kept;
    assert(store.count == journal.live.valid);
}
/// What every live operation does first: undo what failed regions left, and where nothing
/// taken can come back, forget it and sweep the unchained entries out when they exceed half
/// the valid ones (plus 32).
pub fn prepare(store: *Store, journal: *Journal) void {
    rollBack(store, journal);
    const fresh = journal.live.opened;
    journal.live.opened = false;
    if (journal.depth > 1 and !fresh) return;
    forgetTaken(store, journal);
    const valid = journal.live.valid;
    const slack = store.count - valid;
    if (slack * 2 > valid + 64) sweep(store, journal);
}

pub fn startGuard(store: *Store, journal: *Journal) void {
    assert(!store.tracking);
    journal.live.stamp += 1;
    store.tracking = true;
    store.read_len = 0;
}
pub fn noteRead(store: *Store, journal: *const Journal, cell: u32) void {
    know(store, cell);
    if (store.seen[cell] == journal.live.stamp) return;
    store.seen[cell] = journal.live.stamp;
    store.reads[store.read_len] = cell;
    store.read_len += 1;
}
pub fn endGuard(store: *Store) void {
    store.tracking = false;
}
const assert = std.debug.assert;

/// The count the limit is checked on (RFC-0084, "The entry count"). Entries of failed regions
/// still waiting to be dropped do not count.
pub fn required(store: *const Store, journal: *const Journal, old: u64, more: u64) u64 {
    if (journal.depth > 1) {
        const outermost = journal.live_marks[1];
        const top = if (journal.live.dropped == source_state.Live.none) store.count else firstFrom(store, journal.live.dropped + 1);
        const since = firstFrom(store, outermost.stamp + 1);
        return outermost.valid + (top - @min(top, since)) + more;
    }
    return journal.live.valid + more - old;
}
/// The limit, then a unit for each entry recorded and each the record's last evaluation leaves.
pub fn admit(store: *const Store, journal: *const Journal, old: u64, remaining: *u64) Error!void {
    const more = store.read_len;
    if (required(store, journal, old, more) > types.limits.live_edges) return error.LiveEdgeLimit;
    if (remaining.* < more + old) return error.WorkLimit;
    remaining.* -= more + old;
}
/// Records the reads of the evaluation of `record` that took `stamp`; its evaluation that took
/// `previous` (0 for none) stops counting.
pub fn store_reads(store: *Store, journal: *Journal, record: u32, stamp: u64, previous: u64, old: u64) void {
    const more = store.read_len;
    if (previous != 0) unchainRun(store, journal, previous);
    // Unchained, the old entries no longer count, also for a sweep here.
    journal.live.valid -= old;
    if (store.count + more > call_frames.live_entry_room) {
        assert(journal.depth <= 1);
        sweep(store, journal);
    }
    // A reaction's bookkeeping is its slot's (P4.4).
    if (record & watcher == 0) know(store, record);
    for (store.reads[0..more]) |cell| {
        store.entries[store.count] = .{ .cell = cell, .record = record, .stamp = stamp, .older = none, .newer = none, .chained = false };
        chainNewest(store, store.count);
        store.count += 1;
    }
    journal.live.valid += more;
    store.record.entries += more;
}

/// A record stops being attached: its entries leave the chains, a unit each.
fn let_go(store: *Store, journal: *Journal, record: u32, remaining: *u64) Error!void {
    const entries = entriesOf(store, journal, record);
    if (remaining.* < entries) return error.WorkLimit;
    remaining.* -= entries;
    unchainRun(store, journal, stampOf(journal, record));
    journal.live.valid -= entries;
}
pub fn unlink(store: *Store, journal: *Journal, cell: u32, remaining: *u64) Error!void {
    const record = journal.cells[cell].link;
    if (record == unlinked) return;
    prepare(store, journal);
    try let_go(store, journal, record, remaining);
    try journal.setLink(cell, unlinked);
}
pub fn link(store: *Store, journal: *Journal, cell: u32, record: u32, remaining: *u64) Error!void {
    const previous = journal.cells[cell].link;
    if (previous != unlinked) try let_go(store, journal, previous, remaining);
    try journal.setLink(cell, record);
}

pub fn heightAfter(store: *const Store, journal: *const Journal, record: u32, own: u32) u64 {
    var highest: u64 = 0;
    for (store.reads[0..store.read_len]) |cell| {
        if (cell == own) continue;
        const attached = journal.cells[cell].link;
        if (attached == unlinked or attached == record) continue;
        highest = @max(highest, heightOf(journal, attached));
    }
    return @min(height_cap, highest + 1);
}

fn ahead(journal: *const Journal, a: u32, b: u32) bool {
    const left = heightOf(journal, a);
    const right = heightOf(journal, b);
    if (left != right) return left < right;
    return a < b;
}
fn put(store: *Store, position: u32, record: u32) void {
    store.heap[position] = record;
    store.slot[record] = position + 1;
}
fn rise(store: *Store, journal: *const Journal, from: u32) void {
    const record = store.heap[from];
    var position = from;
    while (position > 0) {
        const up = (position - 1) / 2;
        if (!ahead(journal, record, store.heap[up])) break;
        put(store, position, store.heap[up]);
        position = up;
    }
    put(store, position, record);
}
fn sink(store: *Store, journal: *const Journal, from: u32) void {
    const record = store.heap[from];
    var position = from;
    while (2 * position + 1 < store.heap_len) {
        var child = 2 * position + 1;
        if (child + 1 < store.heap_len and ahead(journal, store.heap[child + 1], store.heap[child])) child += 1;
        if (!ahead(journal, store.heap[child], record)) break;
        put(store, position, store.heap[child]);
        position = child;
    }
    put(store, position, record);
}
/// Raises the readers of `record`'s target, and theirs, a unit for each entry looked at.
pub fn raiseReaders(store: *Store, journal: *Journal, record: u32, remaining: *u64) Error!void {
    assert(store.pending_len == 0);
    const ring: u32 = @intCast(store.pending.len);
    store.pending_first = 0;
    store.pending[0] = record;
    store.pending_len = 1;
    store.waiting[record] = true;
    while (store.pending_len > 0) {
        const from = store.pending[store.pending_first];
        store.pending_first = (store.pending_first + 1) % ring;
        store.pending_len -= 1;
        store.waiting[from] = false;
        const level = heightOf(journal, from);
        var index = oldestOf(store, targetOf(journal, from));
        while (index != none) {
            const entry = store.entries[index];
            index = entry.newer;
            assert(holds(store, journal, entry));
            if (remaining.* == 0) return error.WorkLimit;
            remaining.* -= 1;
            // A reaction has no height (P4.4).
            if (entry.record & watcher != 0) continue;
            const reader = entry.record;
            const current = heightOf(journal, reader);
            if (current > level or current >= height_cap) continue;
            try journal.write(reader + catalogue.live_height, .{ .integer = @intCast(@min(height_cap, level + 1)) }, false);
            if (store.slot[reader] != 0) sink(store, journal, store.slot[reader] - 1);
            if (store.waiting[reader]) continue;
            store.pending[(store.pending_first + store.pending_len) % ring] = reader;
            store.pending_len += 1;
            store.waiting[reader] = true;
        }
    }
}
/// Makes the readers of `cell` dirty, a unit for each entry looked at; a reaction among them is
/// notified, a unit more unless it already was (N1, P4.4). `depth` is the region depth now.
pub fn markDirty(store: *Store, journal: *const Journal, cell: u32, depth: u32, remaining: *u64) Error!void {
    var index = oldestOf(store, cell);
    while (index != none) {
        const entry = store.entries[index];
        index = entry.newer;
        assert(holds(store, journal, entry));
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        if (entry.record & watcher != 0) {
            try notified(store, entry.record & ~watcher, depth, remaining);
            continue;
        }
        if (store.slot[entry.record] != 0) continue;
        put(store, store.heap_len, entry.record);
        store.heap_len += 1;
        rise(store, journal, store.heap_len - 1);
    }
}
pub fn next(store: *Store, journal: *const Journal) ?u32 {
    if (store.heap_len == 0) return null;
    const record = store.heap[0];
    store.slot[record] = 0;
    store.heap_len -= 1;
    if (store.heap_len > 0) {
        put(store, 0, store.heap[store.heap_len]);
        sink(store, journal, 0);
    }
    return record;
}
pub fn tallied(store: *Store, record: u32) u64 {
    const shift = 20;
    const mask: u64 = (1 << shift) - 1;
    if (store.tally[record] >> shift != store.propagation) store.tally[record] = store.propagation << shift;
    store.tally[record] += 1;
    return store.tally[record] & mask;
}
pub fn beginPropagation(store: *Store) void {
    assert(store.heap_len == 0);
    store.propagation += 1;
    store.record.propagations += 1;
}
pub fn comparable(store: *const Store, value_type: types.Type) bool {
    return catalogue.comparableIn(value_type, store.comparable[0..store.comparable_len]);
}

/// Reclamation: what failed regions left is undone, then entries of cells or records that go
/// are dropped, and outside every region the unchained ones too; the rest are renumbered by
/// `places` (0 for a cell that goes, else one more than its place above `mark`). Called before
/// the cells move. A chained entry goes only with its record and its cell, a field's record that
/// nothing reaches, through its target or a cell it reads (P4.2, C23, C24; see the reference's
/// `relocate` for why), and then stops being counted; the taken ones kept (`pruneTaken`) stay
/// where they are: older than the innermost open region, so than the frame.
pub fn moveEntries(store: *Store, journal: *Journal, mark: u32, places: []const u32) void {
    rollBack(store, journal);
    // The chains are rebuilt where the cells stand afterwards: the heads of the cells that have
    // chained entries are cleared now, the others are empty already (work in proportion to the
    // entries, not to every cell ever known).
    for (store.entries[0..store.count]) |entry| if (entry.chained) {
        store.newest[entry.cell] = none;
        store.oldest[entry.cell] = none;
    };
    const outside = journal.depth <= 1;
    if (outside or journal.live.opened) forgetTaken(store, journal) else pruneTaken(store, journal);
    const old_count = store.count;
    var kept_count: u32 = 0;
    for (0..old_count) |index| {
        var entry = store.entries[index];
        const watching = entry.record & watcher != 0;
        const record_gone = !watching and entry.record >= mark and places[entry.record - mark] == 0;
        const cell_gone = entry.cell >= mark and places[entry.cell - mark] == 0;
        if (cell_gone or record_gone or (outside and !entry.chained)) {
            if (entry.chained) {
                // A reaction keeps no cell it read: the entry of one that goes goes too (C49).
                assert((watching and cell_gone) or (record_gone and cell_gone and (outside or entry.stamp > journal.live_marks[journal.depth - 1].stamp)));
                journal.live.valid -= 1;
            }
            continue;
        }
        if (entry.cell >= mark) entry.cell = mark + places[entry.cell - mark] - 1;
        if (!watching and entry.record >= mark) entry.record = mark + places[entry.record - mark] - 1;
        store.entries[kept_count] = entry;
        kept_count += 1;
    }
    for (store.taken[0..store.taken_len]) |index| assert(index < kept_count and store.entries[index].stamp <= journal.live_marks[journal.depth - 1].stamp);
    store.count = kept_count;
    for (0..kept_count) |index| if (store.entries[index].chained) chainNewest(store, @intCast(index));
    journal.live.log = store.taken_len;
}
/// Before a reclamation's walk, which follows the chains of the cells it keeps to the records
/// that read them (C24): what failed regions left is undone.
pub fn beforeReclaim(store: *Store, journal: *Journal) void {
    rollBack(store, journal);
}
pub fn measure(store: *const Store, journal: *const Journal) u64 {
    if (!store.on) return 0;
    return required(store, journal, 0, 0);
}
/// The records with a chained entry for `cell`, oldest first, for the reclamation's walk (C24):
/// a reaction among the readers is the scheduler's, which keeps it.
pub fn readerAfter(store: *const Store, at: *u32) ?u32 {
    while (at.* != none) {
        const entry = store.entries[at.*];
        at.* = entry.newer;
        if (entry.record & watcher == 0) return entry.record;
    }
    return null;
}

// Reactions (RFC-0084, P4.4), in the VM's own form. A reaction depends on cells as a record does,
// named in its entries by its slot with the `watcher` bit. Outside every region only it is
// evaluated, fired or delivered to, so its stamp and its count of entries are plain numbers here.

pub fn watchReset(store: *Store, slot: u32) void {
    store.watch_stamp[slot] = 0;
    store.watch_entries[slot] = 0;
    store.watch_pending[slot] = false;
}
/// The entries of a waiting reaction's latest evaluation that are still in the store.
fn watchHeld(store: *const Store, slot: u32) u64 {
    const stamp = store.watch_stamp[slot];
    if (stamp == 0) return 0;
    return firstFrom(store, stamp + 1) - firstFrom(store, stamp);
}
/// The limit, then a unit for each entry recorded and each entry the reaction recorded before.
pub fn watchAdmit(store: *const Store, journal: *const Journal, slot: u32, remaining: *u64) Error!void {
    const more = store.read_len;
    if (required(store, journal, watchHeld(store, slot), more) > types.limits.live_edges) return error.LiveEdgeLimit;
    const old = store.watch_entries[slot];
    if (remaining.* < more + old) return error.WorkLimit;
    remaining.* -= more + old;
}
/// The reaction in `slot` waits on its guard with the reads of the evaluation that took `stamp`.
pub fn watchStore(store: *Store, journal: *Journal, slot: u32, stamp: u64) void {
    const more = store.read_len;
    store_reads(store, journal, watcher | slot, stamp, store.watch_stamp[slot], watchHeld(store, slot));
    store.watch_stamp[slot] = stamp;
    store.watch_entries[slot] = more;
}
/// The reaction in `slot` stops waiting, to fire: a unit for each entry it recorded.
pub fn watchRelease(store: *Store, journal: *Journal, slot: u32, remaining: *u64) Error!void {
    const charged = store.watch_entries[slot];
    if (remaining.* < charged) return error.WorkLimit;
    remaining.* -= charged;
    const held = watchHeld(store, slot);
    if (store.watch_stamp[slot] != 0) unchainRun(store, journal, store.watch_stamp[slot]);
    journal.live.valid -= held;
    store.watch_stamp[slot] = 0;
    store.watch_entries[slot] = 0;
}
/// N1: the reaction in `slot` is notified, a unit, unless it is already; a region notifying for
/// the first time marks the list (R2).
fn notified(store: *Store, slot: u32, depth: u32, remaining: *u64) Error!void {
    if (store.watch_pending[slot]) return;
    if (remaining.* == 0) return error.WorkLimit;
    remaining.* -= 1;
    if (depth != 0 and (store.notified_mark_len == 0 or store.notified_marks[store.notified_mark_len - 1].depth != depth)) {
        store.notified_marks[store.notified_mark_len] = .{ .depth = depth, .count = store.notified_end };
        store.notified_mark_len += 1;
    }
    const ring = store.notified.len;
    assert(store.notified_end - store.notified_first < ring);
    store.notified[store.notified_end % ring] = slot;
    store.notified_end += 1;
    store.watch_pending[slot] = true;
}
pub fn notifiedCommit(store: *Store, closing: u32) void {
    if (store.notified_mark_len == 0 or store.notified_marks[store.notified_mark_len - 1].depth != closing) return;
    const outer = closing - 1;
    if (outer == 0 or (store.notified_mark_len > 1 and store.notified_marks[store.notified_mark_len - 2].depth == outer)) {
        store.notified_mark_len -= 1;
    } else store.notified_marks[store.notified_mark_len - 1].depth = outer;
}
pub fn notifiedAbort(store: *Store, closing: u32) void {
    if (store.notified_mark_len == 0 or store.notified_marks[store.notified_mark_len - 1].depth != closing) return;
    store.notified_mark_len -= 1;
    const keep = store.notified_marks[store.notified_mark_len].count;
    assert(keep >= store.notified_first and keep < store.notified_end);
    const ring = store.notified.len;
    while (store.notified_end > keep) {
        store.notified_end -= 1;
        store.watch_pending[store.notified[store.notified_end % ring]] = false;
    }
}
/// The oldest notified reaction, no longer notified.
pub fn nextNotified(store: *Store) ?u32 {
    if (store.notified_first == store.notified_end) return null;
    assert(store.notified_mark_len == 0);
    const slot = store.notified[store.notified_first % store.notified.len];
    store.notified_first += 1;
    store.watch_pending[slot] = false;
    return slot;
}
/// Whether a delivery point delivers now (N3).
pub fn mayDeliver(store: *const Store, depth: u32) bool {
    return store.on and depth == 0 and store.firing_depth == 0 and store.batches == 0 and !store.tracking and !store.delivering and store.notified_first != store.notified_end;
}
