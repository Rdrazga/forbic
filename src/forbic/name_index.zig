//! Open-addressing index for the duplicate checks of admission. Comparing every pair of names
//! costs the square of what a program declares, on every run; an index costs what it declares.
//!
//! The index holds item numbers and nothing else. Each machine hashes its own keys, visits the
//! candidates of one probe and decides with its own predicate whether two items collide, so the
//! two admissions stay independent. Memory comes from `scratch`, sized and cleared by the number
//! of items and never by a profile capacity.
const std = @import("std");
const scratch = @import("scratch.zig");

/// Marks a free slot and the end of a chain. No table of the IR holds this many items.
pub const none: u32 = std.math.maxInt(u32);

pub const Index = struct {
    slots: []u32,
    used: usize = 0,

    /// Room for `items` entries at a load of at most one half, so a probe always reaches a free
    /// slot. Null when the host has no memory left.
    pub fn create(items: usize) ?Index {
        const count = slotCount(items) orelse return null;
        const slots = scratch.alloc(u32, count) orelse return null;
        @memset(slots, none);
        return .{ .slots = slots };
    }

    pub fn destroy(self: Index) void {
        scratch.free(self.slots);
    }

    /// The slot where the probe of `hash` starts.
    pub fn home(self: *const Index, hash: u64) usize {
        std.debug.assert(std.math.isPowerOfTwo(self.slots.len));
        return @intCast(hash & (self.slots.len - 1));
    }

    pub fn probe(self: *Index, hash: u64) Probe {
        return .{ .index = self, .slot = self.home(hash) };
    }
};

/// Walks the occupied slots from an item's home slot to the first free one. Every item entered
/// with the same hash lies on that walk, because slots are never released while the index lives.
pub const Probe = struct {
    index: *Index,
    slot: usize,

    /// The next candidate, which may belong to a different key; null at the free slot.
    pub fn next(self: *Probe) ?u32 {
        const item = self.index.slots[self.slot];
        if (item == none) return null;
        self.slot = (self.slot + 1) & (self.index.slots.len - 1);
        return item;
    }

    /// Enters `item` at the free slot where `next` stopped.
    pub fn claim(self: *Probe, item: u32) void {
        std.debug.assert(item != none);
        std.debug.assert(self.index.slots[self.slot] == none);
        std.debug.assert((self.index.used + 1) * 2 <= self.index.slots.len);
        self.index.slots[self.slot] = item;
        self.index.used += 1;
    }
};

/// An index for a table that grows while it is used, as the compiler's tables do: its slots lie
/// in storage the owner reserved once (`slotCount` of the most items the table can hold), and
/// only a part of them that follows the number of entries is live. Starting a table costs
/// nothing and growing it clears the part it grows into, so a compile pays for the entries it
/// makes and never for the capacity. The owner keeps the items; when the live part is crowded
/// it calls `grow` and enters every item again, in order.
///
/// Items entered under one hash are met by `walk` in the order they were entered.
pub const Table = struct {
    /// Slots in use: a power of two, or zero before the first entry.
    live: u32 = 0,
    used: u32 = 0,

    /// The live part of a table that has just got its first entry.
    pub const smallest = 16;

    /// Forgets every entry. The storage is left as it is: `grow` clears what it takes.
    pub fn clear(self: *Table) void {
        self.* = .{};
    }

    /// Whether one more entry would fill more than half of the live part.
    pub fn crowded(self: Table) bool {
        return (@as(u64, self.used) + 1) * 2 > self.live;
    }

    /// Doubles the live part and empties it; the owner then enters its items again.
    pub fn grow(self: *Table, slots: []u32) void {
        const size: u32 = if (self.live == 0) smallest else self.live * 2;
        std.debug.assert(size <= slots.len and std.math.isPowerOfTwo(size));
        @memset(slots[0..size], none);
        self.live = size;
        self.used = 0;
    }

    /// Empties the live part without changing its size, for an owner that enters its items
    /// again because some of the entries have gone stale.
    pub fn empty(self: *Table, slots: []u32) void {
        @memset(slots[0..self.live], none);
        self.used = 0;
    }

    /// Enters `item` under `hash`, behind the items already entered under it.
    pub fn enter(self: *Table, slots: []u32, hash: u64, item: u32) void {
        std.debug.assert(item != none and !self.crowded());
        const mask: usize = self.live - 1;
        var at: usize = @intCast(hash & mask);
        while (slots[at] != none) at = (at + 1) & mask;
        slots[at] = item;
        self.used += 1;
    }

    /// The items that may have been entered under `hash`, the oldest first. Others share the
    /// walk: the owner tells them apart with its own predicate.
    pub fn walk(self: Table, slots: []const u32, hash: u64) Walk {
        if (self.live == 0) return .{ .slots = slots[0..0], .at = 0 };
        return .{ .slots = slots[0..self.live], .at = @intCast(hash & (self.live - 1)) };
    }

    pub const Walk = struct {
        slots: []const u32,
        at: usize,

        pub fn next(self: *Walk) ?u32 {
            if (self.slots.len == 0) return null;
            const item = self.slots[self.at];
            if (item == none) return null;
            self.at = (self.at + 1) & (self.slots.len - 1);
            return item;
        }
    };
};

/// Slots of an index for `items` entries: a power of two, at least twice the entries.
pub fn slotCount(items: usize) ?usize {
    const doubled = std.math.mul(usize, @max(items, 1), 2) catch return null;
    return std.math.ceilPowerOfTwo(usize, doubled) catch null;
}

/// Hash of a declared name within its module. `owner` is the module number, or zero for a
/// program without modules.
pub fn hashName(owner: u32, text: []const u8) u64 {
    return std.hash.Wyhash.hash(owner, text);
}

/// Hash of a source span taken as a position, for items that are told apart by where they are
/// written rather than by their text. The seed keeps positions apart from names.
pub fn hashSpan(start: u32, end: u32) u64 {
    const words = [2]u32{ start, end };
    return std.hash.Wyhash.hash(std.math.maxInt(u64), std.mem.asBytes(&words));
}

test "an index is sized by its items and finds every entry of one hash" {
    try std.testing.expectEqual(@as(usize, 2), slotCount(0).?);
    try std.testing.expectEqual(@as(usize, 2), slotCount(1).?);
    try std.testing.expectEqual(@as(usize, 8), slotCount(3).?);
    try std.testing.expectEqual(@as(usize, 65536), slotCount(32768).?);
    try std.testing.expect(slotCount(std.math.maxInt(usize)) == null);

    var index = Index.create(5).?;
    defer index.destroy();
    try std.testing.expectEqual(@as(usize, 16), index.slots.len);
    // Hashes 15, 31 and 47 share the last slot, so their probes wrap around; 0 lands among them.
    for ([_]u64{ 15, 0, 31, 47, 3 }, 0..) |hash, item| {
        var probe = index.probe(hash);
        while (probe.next()) |_| {}
        probe.claim(@intCast(item));
    }
    try std.testing.expectEqual(@as(usize, 5), index.used);
    var seen: [5]u32 = undefined;
    var count: usize = 0;
    var probe = index.probe(15 + 16 * 7);
    while (probe.next()) |item| : (count += 1) seen[count] = item;
    // Items 1 and 4 are neighbours with other hashes: the caller's predicate tells them apart.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, seen[0..count]);
    var later = index.probe(3);
    try std.testing.expectEqual(@as(?u32, 4), later.next());
    try std.testing.expect(later.next() == null);
    var absent = index.probe(5);
    try std.testing.expect(absent.next() == null);
}

test "names hash by module and text, spans by position" {
    try std.testing.expectEqual(hashName(0, "Total"), hashName(0, "Total"));
    try std.testing.expect(hashName(0, "Total") != hashName(1, "Total"));
    try std.testing.expect(hashName(0, "Total") != hashName(0, "Totals"));
    try std.testing.expect(hashSpan(4, 6) != hashSpan(4, 7));
    try std.testing.expect(hashSpan(4, 6) != hashSpan(6, 4));
}

test "a table grows with its entries, keeps the order of one hash and starts again for nothing" {
    var slots: [slotCount(100).?]u32 = undefined;
    var hashes: [100]u64 = undefined;
    var table: Table = .{};
    var empty_walk = table.walk(&slots, 7);
    try std.testing.expect(empty_walk.next() == null);
    // Every third item shares hash 5; the others have hashes of their own.
    for (0..100) |item| {
        hashes[item] = if (item % 3 == 0) 5 else 1000 + item * 17;
        if (table.crowded()) {
            table.grow(&slots);
            for (hashes[0..item], 0..) |hash, earlier| table.enter(&slots, hash, @intCast(earlier));
        }
        table.enter(&slots, hashes[item], @intCast(item));
        try std.testing.expect(table.used == item + 1 and table.used * 2 <= table.live);
    }
    try std.testing.expectEqual(@as(u32, 256), table.live);
    var walk = table.walk(&slots, 5);
    var expected: u32 = 0;
    while (walk.next()) |item| {
        if (hashes[item] != 5) continue;
        try std.testing.expectEqual(expected, item);
        expected += 3;
    }
    try std.testing.expectEqual(@as(u32, 102), expected);
    // Emptying keeps the size; clearing gives the storage back untouched.
    table.empty(&slots);
    try std.testing.expect(table.used == 0 and table.live == 256);
    var gone = table.walk(&slots, 5);
    try std.testing.expect(gone.next() == null);
    table.clear();
    try std.testing.expect(table.live == 0 and table.crowded());
    table.grow(&slots);
    try std.testing.expectEqual(@as(u32, Table.smallest), table.live);
    for (slots[0..Table.smallest]) |slot| try std.testing.expectEqual(none, slot);
}
