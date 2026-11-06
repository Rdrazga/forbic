//! RFC-0087, P5.7 (S6, R8, R9): publishing the store from a journal, and the `published` records
//! that mark each publication.
//!
//! A journal's publications form a chain. It starts at the generation the header names as the
//! run's base (S7; none for a first run) and goes on through each `published {generation, through}`
//! record of the durable prefix: each names the generation that publication made from the one
//! before it with the store actions sealed between the previous record's `through` and its own,
//! the last write of each entry (S6). The next publication builds on the chain's last generation
//! with the store actions sealed after it, and its record is appended and sealed once the store
//! holds it. Publication is therefore a function of the base and the durable prefix: a crash
//! between the store's files and the record is repaired by publishing again, which writes the same
//! files and makes the same generation (content addressing), and a crash after the record leaves
//! nothing to publish again.
//!
//! `plan` reads the journal and the store and writes nothing. It works every record's generation
//! out in memory, from the base's manifest and the journal's texts, and refuses a record that
//! names any other (`StoreFailed`): a forged or damaged journal never makes a store take a
//! generation its prefix does not make. Every generation of the chain names the schema the header
//! records, so before the plan lets one be made (published or repaired) that object is read and
//! must be a schema (`persist_schema.parse`): a header that names anything else would make
//! generations no later run reads. `apply` writes what the plan found.
//!
//! What a crash on a file system that does not order its metadata can leave (RFC-0086 G22; P5.5's
//! P12) is a record that is durable while the replacement of `active` it followed is not, so that
//! `active` names an earlier generation of the chain, or while the generation `active` names is
//! not, or an object one of the chain's publications wrote is not (missing, cut short, or other
//! bytes than its name is the hash of). `plan` finds `active` behind on the chain, and `apply`
//! writes the chain's generations again, their objects with them, and makes `active` name the
//! last, before it publishes anything more; `confirm` does the same for the journal a run
//! rotated, before the next run starts. Only the objects the chain's own store actions name are
//! read for it, so what this costs is bounded by the journal and not by the store.
//! An `active` that names a generation outside the chain was moved by another publication, which
//! nothing here undoes (`ActiveMoved`).
//!
//! This file knows no file system, as `durable.zig` and `store.zig` do not: the host and the DST
//! publish with the same steps.
const std = @import("std");
const durable = @import("durable.zig");
const effects = @import("effects.zig");
const persist_schema = @import("persist_schema.zig");
const store = @import("store.zig");

pub const Error = store.Error || durable.ReadError;

const forged = "a published record of the journal names a generation its publication does not make";
const malformed = "a store action of the journal is not one";
pub const unschema = "the schema the journal's header names is not a schema the store holds";

/// What the publication of a journal's durable prefix has to do, found without writing.
pub const Plan = struct {
    gpa: std.mem.Allocator,
    journal: durable.Disk,
    buffer: []u8,
    reference: durable.StoreRef,
    /// The chain, oldest first: the header's base (null: none), then each record's generation.
    chain: std.ArrayList(?store.Hash) = .empty,
    /// The chain's last generation, as the store would read it (null: no base and no record).
    last: ?store.Generation = null,
    /// Holds `last`, and the scratch of the walk.
    arenas: [2]std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    /// The store actions sealed after the last record, the last of each entry.
    updates: store.Updates,
    /// `updates`, sorted by entry; owned by `gpa`.
    pending: []store.Updates.Update = &.{},
    /// The actions the durable prefix seals: the `through` of the next publication's record.
    through: u64 = 0,
    /// The generation the next publication makes, and its name; null: nothing to publish.
    next: ?store.Generation = null,
    next_name: ?store.Hash = null,
    /// What `active` named when the plan was made.
    active: ?store.Hash = null,
    /// When `active` is behind on the chain (an earlier generation, or the last one unreadable):
    /// its place on it.
    behind: ?usize = null,
    /// s5-1: the objects the chain's records' publications wrote (the last write of each entry in
    /// each record's range), each once.
    introduced: std.AutoArrayHashMapUnmanaged(store.Hash, void) = .empty,
    /// Which arena holds `last`.
    side: u1 = 0,

    pub fn deinit(self: *Plan) void {
        self.gpa.free(self.pending);
        self.updates.deinit();
        self.chain.deinit(self.gpa);
        self.introduced.deinit(self.gpa);
        for (&self.arenas) |*arena| arena.deinit();
        self.scratch.deinit();
    }

    /// The generation the next publication builds on.
    pub fn tail(self: *const Plan) ?store.Hash {
        return self.chain.items[self.chain.items.len - 1];
    }
    /// The number of `published` records of the prefix.
    pub fn records(self: *const Plan) usize {
        return self.chain.items.len - 1;
    }

    /// s5-1: `behind` at the chain's last generation when it or an object the chain introduced
    /// cannot be read whole, so that `repair` writes them again from the journal.
    fn checkWhole(self: *Plan, held: *store.Store) Error!void {
        if (self.records() == 0) return;
        if (!try readable(held, self.scratch.allocator(), self.tail().?, self.introduced.keys())) self.behind = self.chain.items.len - 1;
    }
};

/// RFC-0087, P5.7: the publication of the durable prefix of `journal` (the journal of a run whose
/// header records `reference`) to `held`: every record checked against the generation its
/// publication makes, the store actions after the last one, the generation they make, and where
/// `active` stands. `buffer` holds a record (`Reader`). Reads the base's manifest, `active`, when
/// `active` names the last record's generation (or the one the next publication makes) the last
/// record's manifest and the objects the chain introduced, and when there is something to publish
/// or repair the schema object the header names; writes nothing. `StoreFailed` names its reason in
/// `held.why`; an `active` outside the chain is `ActiveMoved`.
pub fn plan(gpa: std.mem.Allocator, held: *store.Store, journal: durable.Disk, buffer: []u8, reference: durable.StoreRef) Error!Plan {
    var result: Plan = .{
        .gpa = gpa,
        .journal = journal,
        .buffer = buffer,
        .reference = reference,
        .arenas = .{ .init(gpa), .init(gpa) },
        .scratch = .init(gpa),
        .updates = .init(gpa),
    };
    errdefer result.deinit();
    try walk(&result, held, null);
    result.pending = try result.updates.sorted();
    result.next = try successor(held, result.scratch.allocator(), result.last, result.tail(), reference.schema, result.pending);
    if (result.next) |next| result.next_name = try held.nameOf(result.scratch.allocator(), next);
    result.active = try held.activeName();
    try locate(&result, held);
    // c1-2: before a generation naming it is made.
    if (result.next != null or result.behind != null) try checkSchema(held, gpa, reference.schema);
    return result;
}

/// Where `active` stands on the chain of `result`: `behind`, or `ActiveMoved`.
fn locate(result: *Plan, held: *store.Store) Error!void {
    if (same(result.active, result.tail())) {
        // P12: a crash may also have kept the replacement of `active` and lost the generation it
        // names, or an object of it, which the journal can write again.
        return result.checkWhole(held);
    }
    // A crash after the next publication's `active` and before its record: `apply` writes that
    // one's files again, and the chain's first when one of them was lost. Where it lost one of
    // that generation's own files (and the record never followed, so that `confirm` meets it),
    // `behind` as well, so that `confirm` writes them again (`apply`).
    if (result.next_name) |name| if (same(result.active, name)) {
        try result.checkWhole(held);
        if (result.behind == null and result.records() != 0) {
            const scratch = result.scratch.allocator();
            const objects = try scratch.alloc(store.Hash, result.pending.len);
            for (objects, result.pending) |*object, update| object.* = store.hashOf(update.text);
            if (!try readable(held, scratch, name, objects)) result.behind = result.chain.items.len - 1;
        }
        return;
    };
    // P12: a crash kept a record and lost the replacement of `active` that came before it.
    for (result.chain.items[0 .. result.chain.items.len - 1], 0..) |earlier, place| {
        if (same(result.active, earlier)) {
            result.behind = place;
            return;
        }
    }
    return error.ActiveMoved;
}

/// Writes what `plan` found: the chain's generations after the one `active` names, when it is
/// behind (`repair`), then the next generation, made active; its name, which the caller records
/// (`durable.Journal.recordPublished` with `plan.through`), or null when there was nothing to
/// publish. Under the same lock as the plan: `active` must still be where the plan found it.
pub fn apply(result: *Plan, held: *store.Store) Error!?store.Hash {
    try repair(result, held);
    const next = result.next orelse return null;
    const name = try held.write(result.scratch.allocator(), next, result.pending);
    std.debug.assert(std.mem.eql(u8, &name, &result.next_name.?));
    try held.activate(result.tail(), name);
    return name;
}

/// P12: when `active` names an earlier generation of the chain than its last, or the last one
/// whose manifest or an object of whose chain is gone, the generations of every record are written
/// again, each from the journal's texts as its publication wrote them (files that are whole are left
/// and synced again), and `active` is made the chain's last, unless it names the generation the
/// next publication makes, which it keeps (`apply` writes that one again). Nothing else is
/// published.
pub fn repair(result: *Plan, held: *store.Store) Error!void {
    if (result.behind == null) return;
    var again: Plan = .{
        .gpa = result.gpa,
        .journal = result.journal,
        .buffer = result.buffer,
        .reference = result.reference,
        .arenas = .{ .init(result.gpa), .init(result.gpa) },
        .scratch = .init(result.gpa),
        .updates = .init(result.gpa),
    };
    defer again.deinit();
    try walk(&again, held, 0);
    // The journal is the one the plan read: the same records make the same chain.
    if (again.chain.items.len != result.chain.items.len or !same(again.tail(), result.tail())) return held.failed(forged);
    result.behind = null;
    // A publication that is not recorded is still the journal's: `active` never goes back from it.
    if (result.next_name) |name| if (same(result.active, name)) return;
    const last = result.tail().?;
    try held.activate(result.active, last);
    result.active = last;
}

/// RFC-0087, P5.7 (P12): what the next run on a state directory does with the journal rotated last
/// (`journal`, of a run whose header records `reference`): when `active` is behind on its chain
/// (an earlier generation, none, the last one's manifest gone, or an object the chain introduced
/// lost or damaged), the chain is written again and `active` made its last (`repair`); when
/// `active` names the generation the store actions after its last record make (published, its
/// record lost or never appended), that one is written again too and `active` keeps it (`apply`).
/// A journal without a record tells nothing. Whether it repaired; `StoreFailed` (a chain that is not
/// the journal's publications) and `ActiveMoved` (an `active` another publication moved) are the
/// caller's to weigh. The journal is walked whole: which objects must be whole is known only from
/// the store actions of its records.
pub fn confirm(gpa: std.mem.Allocator, held: *store.Store, journal: durable.Disk, buffer: []u8, reference: durable.StoreRef) Error!bool {
    const found = try durable.scan(journal, buffer);
    if (found.published == null) return false;
    var made = try plan(gpa, held, journal, buffer, reference);
    defer made.deinit();
    if (made.behind == null) return false;
    if (made.next_name) |name| if (same(made.active, name)) {
        _ = try apply(&made, held);
        return true;
    };
    try repair(&made, held);
    return true;
}

/// Whether the store holds the generation `hash` whole: its manifest there and the bytes its name
/// is the hash of, and each of `objects` (s5-1: those its chain introduced) the same.
fn readable(held: *store.Store, arena: std.mem.Allocator, hash: store.Hash, objects: []const store.Hash) Error!bool {
    _ = held.generation(arena, hash) catch |problem| return if (problem == error.StoreFailed) false else problem;
    for (objects) |object| {
        const text = held.text(.{ .cell = "", .key = "", .object = object }) catch |problem| return if (problem == error.StoreFailed) false else problem;
        held.gpa.free(text);
    }
    return true;
}

/// c1-2: whether the object `schema` is whole and a schema (of this version, P5.5's placeholder, or
/// a later one): the header's program binds the program, not this field, and a run does not check
/// it against its own until the store it names is read.
fn checkSchema(held: *store.Store, gpa: std.mem.Allocator, schema: store.Hash) Error!void {
    const text = held.text(.{ .cell = "", .key = "", .object = schema }) catch |problem| return if (problem == error.StoreFailed) held.failed(unschema) else problem;
    defer held.gpa.free(text);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    if (try persist_schema.parse(arena_state.allocator(), text) == .invalid) return held.failed(unschema);
}

fn same(a: ?store.Hash, b: ?store.Hash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

/// What a publication from `before` (named `base`) of `updates` makes: the store actions applied,
/// or with none the schema alone where `before`'s is another (P5.6, C15); null: nothing.
fn successor(held: *store.Store, arena: std.mem.Allocator, before: ?store.Generation, base: ?store.Hash, schema: store.Hash, updates: []const store.Updates.Update) Error!?store.Generation {
    if (updates.len != 0) return try held.following(arena, before, base, schema, updates);
    const held_before = before orelse return null;
    if (std.mem.eql(u8, &held_before.schema, &schema)) return null;
    return try held.following(arena, before, base, schema, &.{});
}

/// A generation copied into `arena`, so that the arena it was made in can be dropped.
fn settle(arena: std.mem.Allocator, generation: store.Generation) std.mem.Allocator.Error!store.Generation {
    const entries = try arena.alloc(store.Entry, generation.entries.len);
    for (entries, generation.entries) |*out, entry| out.* = .{ .cell = try arena.dupe(u8, entry.cell), .key = try arena.dupe(u8, entry.key), .object = entry.object };
    return .{ .number = generation.number, .parent = generation.parent, .schema = generation.schema, .entries = entries };
}

/// Reads the durable prefix: the chain, its last generation, the store actions after its last
/// record and the actions sealed. With `writing`, the generations of the records whose place on the
/// chain is after it are written (objects, then manifest), as their publications wrote them.
fn walk(result: *Plan, held: *store.Store, writing: ?usize) Error!void {
    const base: ?store.Hash = if (std.mem.allEqual(u8, &result.reference.base, 0)) null else result.reference.base;
    try result.chain.append(result.gpa, base);
    if (base) |named| result.last = try settle(result.arenas[0].allocator(), try held.generation(result.scratch.allocator(), named));
    _ = result.scratch.reset(.retain_capacity);
    var prefix = try durable.Prefix.init(result.journal, result.buffer);
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => |action| if (action.channel == effects.store_channel) try result.updates.add(action.text),
        .published => |published| {
            if (result.updates.malformed != 0) return held.failed(malformed);
            const list = try result.updates.sorted();
            defer result.gpa.free(list);
            const scratch = result.scratch.allocator();
            const made = (try successor(held, scratch, result.last, result.tail(), result.reference.schema, list)) orelse return held.failed(forged);
            const name = try held.nameOf(scratch, made);
            if (!std.mem.eql(u8, &name, &published.generation)) return held.failed(forged);
            if (writing) |place| if (result.chain.items.len > place) {
                _ = try held.write(scratch, made, list);
            };
            for (list) |update| try result.introduced.put(result.gpa, store.hashOf(update.text), {});
            const other = &result.arenas[1 - result.side];
            _ = other.reset(.retain_capacity);
            result.last = try settle(other.allocator(), made);
            result.side = 1 - result.side;
            _ = result.scratch.reset(.retain_capacity);
            try result.chain.append(result.gpa, name);
            result.updates.deinit();
            result.updates = .init(result.gpa);
        },
        else => {},
    };
    if (result.updates.malformed != 0) return held.failed(malformed);
    result.through = prefix.checker.sealed_actions;
}

// ---- Tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// A journal in memory, written as a run's sink writes it, for the tests of publication.
const Bench = struct {
    bytes: [16 * 1024]u8 = undefined,
    memory: durable.Memory = undefined,
    journal: durable.Journal = undefined,
    buffer: [4096]u8 = undefined,
    header: [512]u8 = undefined,

    fn start(self: *Bench, recorded: durable.StoreRef) !void {
        self.memory = .{ .bytes = &self.bytes };
        self.journal = .init(self.memory.disk(), &self.buffer);
        try self.journal.start(try durable.encodeHeader(.{ .toolchain = "t", .profile = "bootstrap", .program = @splat(1), .seed = 1, .tick_rate = 60, .grants = &.{}, .store = recorded }, &self.header));
    }
    /// One commit point: each text an action on its channel, then a seal.
    fn commit(self: *Bench, actions: []const struct { u32, []const u8 }) !void {
        const sink = self.journal.sink();
        for (actions) |action| {
            try testing.expect(sink.prepare(sink.context, action[1]));
            try testing.expect(sink.commit(sink.context, .{ .sequence = self.journal.actions, .channel = action[0], .text = action[1] }));
        }
        try testing.expect(sink.seal.?(sink.context, self.journal.actions));
    }
    fn found(self: *Bench) !durable.Scan {
        return durable.scan(self.memory.disk(), &self.buffer);
    }
    /// Publishes the durable prefix to `held` and records it.
    fn publish(self: *Bench, held: *store.Store) !?store.Hash {
        var made = try plan(testing.allocator, held, self.memory.disk(), &self.buffer, self.reference());
        defer made.deinit();
        const name = (try apply(&made, held)) orelse return null;
        try self.journal.recordPublished(.{ .generation = name, .through = made.through });
        return name;
    }
    fn reference(self: *Bench) durable.StoreRef {
        var grants: [0]durable.GrantRecord = .{};
        var reader: durable.Reader = .{ .disk = self.memory.disk(), .buffer = &self.buffer };
        const item = (reader.next() catch unreachable).?;
        return (durable.decodeHeader(item.payload, &grants) catch unreachable).store.?;
    }
};

fn storeAction(comptime key: []const u8, comptime value: []const u8) struct { u32, []const u8 } {
    return .{ effects.store_channel, "{\"cell\":\":X\",\"key\":\"" ++ key ++ "\",\"value\":" ++ value ++ "}" };
}

/// The schema of the tests' one cell, as P5.5 writes it.
fn putSchema(held: *store.Store) !store.Hash {
    const text = try store.schemaText(testing.allocator, &.{":X"});
    defer testing.allocator.free(text);
    return held.putObject(text);
}

/// A file of the store lost, as a crash that kept none of it leaves it.
fn forget(memory: *store.Memory, area: store.Area, name: []const u8) void {
    var path: [128]u8 = undefined;
    const removed = memory.files.fetchSwapRemove(std.fmt.bufPrint(&path, "{t}/{s}", .{ area, name }) catch unreachable).?;
    testing.allocator.free(removed.key);
    testing.allocator.free(removed.value);
}

/// The texts of the entries of `active`, as `KEY=TEXT;` in order.
fn entriesOf(held: *store.Store, out: []u8) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var writer: std.Io.Writer = .fixed(out);
    const current = (try held.active(arena_state.allocator())) orelse return "";
    for (current.generation.entries) |entry| {
        const text = try held.text(entry);
        defer testing.allocator.free(text);
        try writer.print("{s}={s};", .{ entry.key, text });
    }
    return writer.buffered();
}

test "publications continue from the last record, each recorded, and one that crashed is made again" {
    var memory: store.Memory = .init(testing.allocator);
    defer memory.deinit();
    var held: store.Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const schema = try putSchema(&held);
    const base = (try held.publish(null, schema, &.{.{ .cell = ":X", .key = "alice", .text = @constCast("1") }})).?;
    const bench = try testing.allocator.create(Bench);
    defer testing.allocator.destroy(bench);
    try bench.start(.{ .base = base, .schema = schema });
    try bench.commit(&.{ storeAction("alice", "2"), .{ 0, "line" } });
    try bench.commit(&.{storeAction("bob", "3")});
    // The first publication builds on the base, and its record covers the two sealed commit points.
    const first = (try bench.publish(&held)).?;
    var scanned = try bench.found();
    try testing.expectEqualSlices(u8, &first, &scanned.published.?.generation);
    try testing.expectEqual(@as(u64, 3), scanned.published.?.through);
    var text: [256]u8 = undefined;
    try testing.expectEqualStrings("alice=2;bob=3;", try entriesOf(&held, &text));
    // Nothing more to publish: nothing is written and no record appended.
    const length = bench.memory.len;
    const operations = memory.operations;
    try testing.expect((try bench.publish(&held)) == null);
    try testing.expectEqual(length, bench.memory.len);
    // The plan reads the base's manifest, `active`, the manifest it names and the two objects the
    // record's publication wrote, and writes nothing; with nothing to publish, not the schema.
    try testing.expectEqual(operations + 5, memory.operations);
    // More sealed: the next publication builds on the record's generation, not the base.
    try bench.commit(&.{ storeAction("alice", "4"), storeAction("alice", "5") });
    const second = (try bench.publish(&held)).?;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const made = try held.generation(arena_state.allocator(), second);
    try testing.expectEqualSlices(u8, &first, &made.parent.?);
    try testing.expectEqual(@as(u64, 3), made.number);
    try testing.expectEqualStrings("alice=5;bob=3;", try entriesOf(&held, &text));
    // A crash after a publication's files and `active`, before its record: published again, it is
    // the same generation, and the record names it.
    try bench.commit(&.{storeAction("carol", "6")});
    var crashed = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    const lost = (try apply(&crashed, &held)).?;
    crashed.deinit();
    var again = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    defer again.deinit();
    try testing.expect(again.behind == null and std.mem.eql(u8, &again.active.?, &lost));
    try testing.expectEqualSlices(u8, &lost, &(try apply(&again, &held)).?);
    try bench.journal.recordPublished(.{ .generation = lost, .through = again.through });
    scanned = try bench.found();
    try testing.expectEqualSlices(u8, &lost, &scanned.published.?.generation);
}

test "a record that names another generation than its publication makes is refused, and the store is untouched" {
    var memory: store.Memory = .init(testing.allocator);
    defer memory.deinit();
    var held: store.Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const schema = try putSchema(&held);
    const bench = try testing.allocator.create(Bench);
    defer testing.allocator.destroy(bench);
    try bench.start(.{ .base = @splat(0), .schema = schema });
    try bench.commit(&.{storeAction("alice", "1")});
    // A generation the store holds, but not the one this prefix makes from no base.
    const other = (try held.publish(null, schema, &.{.{ .cell = ":X", .key = "alice", .text = @constCast("9") }})).?;
    try bench.journal.recordPublished(.{ .generation = other, .through = 1 });
    const operations = memory.puts;
    try testing.expectError(error.StoreFailed, plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
    try testing.expectEqualStrings(forged, held.why);
    try testing.expectEqual(operations, memory.puts);
    // A record of a range with nothing to publish is forged as well.
    try bench.start(.{ .base = @splat(0), .schema = schema });
    try bench.commit(&.{.{ 0, "line" }});
    try bench.journal.recordPublished(.{ .generation = other, .through = 1 });
    try testing.expectError(error.StoreFailed, plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
}

test "a header whose schema is missing or no schema is refused before anything is written, and the store keeps its active generation" {
    var memory: store.Memory = .init(testing.allocator);
    defer memory.deinit();
    var held: store.Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const schema = try putSchema(&held);
    const base = (try held.publish(null, schema, &.{.{ .cell = ":X", .key = "alice", .text = @constCast("1") }})).?;
    const bench = try testing.allocator.create(Bench);
    defer testing.allocator.destroy(bench);
    // c1-2: none in the store, an entry's object, and an object that is text but no schema.
    const garbage = try held.putObject("garbage");
    const forgeries = [_]store.Hash{ @splat(0x11), store.hashOf("1"), garbage };
    for (forgeries) |named| {
        try bench.start(.{ .base = base, .schema = named });
        try bench.commit(&.{storeAction("alice", "2")});
        const puts = memory.puts;
        try testing.expectError(error.StoreFailed, plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        try testing.expectEqualStrings(unschema, held.why);
        try testing.expectEqual(puts, memory.puts);
        try testing.expectEqualSlices(u8, &base, &(try held.activeName()).?);
        // So is the processing of the journal once it has finished, which has no program to
        // compare the field with.
        try bench.journal.abandon();
        try testing.expectError(error.StoreFailed, plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        try testing.expectEqual(puts, memory.puts);
    }
    // A schema of a later version than this toolchain's is still one: published, it names it.
    const later = try held.putObject("{\"schema\":2}");
    try bench.start(.{ .base = base, .schema = later });
    try bench.commit(&.{storeAction("alice", "2")});
    const made = (try bench.publish(&held)).?;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualSlices(u8, &later, &(try held.generation(arena_state.allocator(), made)).schema);
}

test "an active that a crash took back to an earlier generation of the chain is brought up to its last, one outside it is refused" {
    var memory: store.Memory = .init(testing.allocator);
    defer memory.deinit();
    var held: store.Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const schema = try putSchema(&held);
    const bench = try testing.allocator.create(Bench);
    defer testing.allocator.destroy(bench);
    try bench.start(.{ .base = @splat(0), .schema = schema });
    try bench.commit(&.{storeAction("alice", "1")});
    const first = (try bench.publish(&held)).?;
    try bench.commit(&.{storeAction("bob", "2")});
    const second = (try bench.publish(&held)).?;
    var text: [256]u8 = undefined;
    // The replacement of `active` by the second publication is lost, and so are its manifest and
    // its object; its record is durable.
    var line: [65]u8 = undefined;
    line[0..64].* = store.hexOf(first);
    line[64] = '\n';
    try memory.disk().put(memory.disk().context, .root, store.active_name, &line);
    forget(&memory, .generations, &store.hexOf(second));
    forget(&memory, .objects, &store.hexOf(store.hashOf("2")));
    try bench.commit(&.{storeAction("carol", "3")});
    var made = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    try testing.expectEqual(@as(?usize, 1), made.behind);
    const third = (try apply(&made, &held)).?;
    try bench.journal.recordPublished(.{ .generation = third, .through = made.through });
    made.deinit();
    try testing.expectEqualStrings("alice=1;bob=2;carol=3;", try entriesOf(&held, &text));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualSlices(u8, &second, &(try held.generation(arena_state.allocator(), third)).parent.?);
    // No file at all, where the chain starts at no base: the whole chain is written again.
    forget(&memory, .root, store.active_name);
    var none = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    try testing.expectEqual(@as(?usize, 0), none.behind);
    try testing.expect((try apply(&none, &held)) == null);
    none.deinit();
    try testing.expectEqualStrings("alice=1;bob=2;carol=3;", try entriesOf(&held, &text));
    // The manifest `active` names is gone, `active` kept: written again from the journal.
    forget(&memory, .generations, &store.hexOf(third));
    try testing.expect(try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
    try testing.expectEqualStrings("alice=1;bob=2;carol=3;", try entriesOf(&held, &text));
    try testing.expect(!try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
    // And `active` taken back to the base, as the next run on the rotated journal finds it.
    forget(&memory, .root, store.active_name);
    try testing.expect(try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
    try testing.expectEqualStrings("alice=1;bob=2;carol=3;", try entriesOf(&held, &text));
    // An active outside the chain was moved by another publication.
    _ = (try held.publish(third, schema, &.{.{ .cell = ":X", .key = "dave", .text = @constCast("4") }})).?;
    try testing.expectError(error.ActiveMoved, plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
}

/// What a crash on a file system that does not order its metadata may leave of an object.
const Damage = enum { lost, cut, changed };

fn damage(memory: *store.Memory, object: store.Hash, how: Damage) void {
    const name = store.hexOf(object);
    var path: [128]u8 = undefined;
    const bytes = memory.files.getPtr(std.fmt.bufPrint(&path, "objects/{s}", .{&name}) catch unreachable).?;
    switch (how) {
        .lost => forget(memory, .objects, &name),
        .cut => {
            const kept = testing.allocator.dupe(u8, bytes.*[0 .. bytes.len / 2]) catch unreachable;
            testing.allocator.free(bytes.*);
            bytes.* = kept;
        },
        .changed => bytes.*[bytes.len - 1] ^= 1,
    }
}

test "an object the chain's publications wrote that a crash lost, cut short or changed, its manifest, active and record kept, is written again from the journal" {
    var memory: store.Memory = .init(testing.allocator);
    defer memory.deinit();
    var held: store.Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const schema = try putSchema(&held);
    const base = (try held.publish(null, schema, &.{.{ .cell = ":X", .key = "dave", .text = @constCast("40") }})).?;
    const bench = try testing.allocator.create(Bench);
    defer testing.allocator.destroy(bench);
    try bench.start(.{ .base = base, .schema = schema });
    try bench.commit(&.{ storeAction("alice", "1001"), storeAction("bob", "2002") });
    _ = (try bench.publish(&held)).?;
    try bench.commit(&.{storeAction("alice", "3003")});
    _ = (try bench.publish(&held)).?;
    var text: [256]u8 = undefined;
    const whole = "alice=3003;bob=2002;dave=40;";
    try testing.expectEqualStrings(whole, try entriesOf(&held, &text));
    // s5-1: an object of the last record's publication and one of the first's, which `active` still
    // names; and one the chain no longer names, which its first generation does.
    const objects = [_]store.Hash{ store.hashOf("3003"), store.hashOf("2002"), store.hashOf("1001") };
    for (std.enums.values(Damage)) |how| for (objects) |object| {
        damage(&memory, object, how);
        // The next run on the rotated journal.
        try testing.expect(try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        try testing.expectEqualStrings(whole, try entriesOf(&held, &text));
        try testing.expect(!try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        // A publication of the same journal, before it publishes more.
        damage(&memory, object, how);
        var made = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
        defer made.deinit();
        try testing.expectEqual(@as(?usize, 2), made.behind);
        try testing.expect((try apply(&made, &held)) == null);
        try testing.expectEqualStrings(whole, try entriesOf(&held, &text));
    };
    // An object of the base is not the journal's to read or write: a plan reads only the chain's
    // (and the base's manifest, `active` and the manifest it names).
    const reads = memory.operations;
    var quiet = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    quiet.deinit();
    try testing.expectEqual(reads + 3 + objects.len, memory.operations);
    // A crash after the next publication's `active` and before its record, and an object of the
    // chain lost: published again, the chain is written whole first.
    try bench.commit(&.{storeAction("carol", "5005")});
    var crashed = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    const lost = (try apply(&crashed, &held)).?;
    crashed.deinit();
    const ahead = "alice=3003;bob=2002;carol=5005;dave=40;";
    // The next run on the journal rotated so (its record never appended): the chain is written
    // again, and `active` keeps the generation that is not recorded, written again too.
    for ([_]?store.Hash{ null, store.hashOf("5005") }) |also| {
        damage(&memory, store.hashOf("2002"), .lost);
        if (also) |object| damage(&memory, object, .changed);
        try testing.expect(try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        try testing.expectEqualSlices(u8, &lost, &(try held.activeName()).?);
        try testing.expectEqualStrings(ahead, try entriesOf(&held, &text));
    }
    // Only that generation's own files: its object, then its manifest.
    for ([_]bool{ false, true }) |manifest| {
        if (manifest) forget(&memory, .generations, &store.hexOf(lost)) else damage(&memory, store.hashOf("5005"), .cut);
        try testing.expect(try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
        try testing.expectEqualSlices(u8, &lost, &(try held.activeName()).?);
        try testing.expectEqualStrings(ahead, try entriesOf(&held, &text));
    }
    try testing.expect(!try confirm(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference()));
    damage(&memory, store.hashOf("2002"), .cut);
    var again = try plan(testing.allocator, &held, bench.memory.disk(), &bench.buffer, bench.reference());
    defer again.deinit();
    try testing.expect(again.behind != null and std.mem.eql(u8, &again.active.?, &lost));
    try testing.expectEqualSlices(u8, &lost, &(try apply(&again, &held)).?);
    try bench.journal.recordPublished(.{ .generation = lost, .through = again.through });
    try testing.expectEqualStrings(ahead, try entriesOf(&held, &text));
}
