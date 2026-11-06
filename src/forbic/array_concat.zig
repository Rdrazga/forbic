//! Where `left + right` lives. Arrays are immutable spans of the append-only run pool, so a
//! join often needs no copy: an empty side gives the other side back, two adjacent spans
//! already hold the joined elements, and a left array that ends at the pool tail can grow
//! in place. Building an array by repeated appends therefore costs its final length instead
//! of its square. Both machines and the report replay take the plan from this one function,
//! so every machine agrees on every position and charge.
//!
//! A copy leaves room behind it (RFC-0055, "Rooms"): placeholder members that no value names,
//! the last of which is never filled. A later join of an array that ends where a room begins
//! writes its right operand into the room instead of copying both. A loop whose state wraps
//! its accumulator (`tuple{N, Acc}`, as the general `For` does) leaves the wrapper right
//! behind the accumulator, which is then never at the pool tail; the room keeps its appends
//! linear. A first copy leaves only the last placeholder, so a join that is not part of a
//! growing array takes one member more than it did; a copy of an array that ends at a
//! placeholder is a growing one and leaves as much room as it copies, up to a third of the
//! pool, where the pool has twice that room left after the copy. A join writes into a
//! room only above the marks of the frame it runs in, which is what that frame's reclamation
//! reaches, and, once the run has switched tasks since that frame was pushed, only while no
//! other task holds suspended frames or when what it writes names nothing (`contextOf`).
const std = @import("std");
const types = @import("types.zig");

pub const Kind = enum { left, right, adjacent, extend, fresh, room };

pub const Plan = struct {
    kind: Kind,
    /// The joined array.
    span: types.Span,
    /// Members the join copies; also its work charge.
    copy: u32,
    /// Placeholders a fresh copy leaves behind it: its room and the last placeholder.
    reserve: u32 = 0,

    /// Members the join adds to the pool in use. A join into a room adds none: the room was
    /// counted when it was left.
    pub fn appended(self: Plan) u32 {
        return switch (self.kind) {
            .left, .right, .adjacent, .room => 0,
            .extend => self.copy,
            .fresh => self.copy + self.reserve,
        };
    }
};

/// What lies at `left.end`, as the caller knows it.
pub const Room = struct {
    /// The last placeholder of the room that begins at `left.end`, if one does.
    limit: ?u32 = null,
    /// Whether every member of `right` names only members below `left.start` (see `flat`).
    flat: bool = false,
    /// Whether the room lies at or above the floor (see `Context`), where the frame that joins
    /// may write.
    writable: bool = false,
    /// Members the pool can still take.
    free: usize,
};

/// What a join needs to know of the run around it (`contextOf`).
pub const Context = struct {
    /// The member below which it may not write (`floorOf`).
    floor: u32 = 0,
    /// The same for a right operand whose members name nothing (`inert`): no reclamation can
    /// free what such a member names, so only the frame's own floor holds, whatever other
    /// tasks hold. At most `floor`.
    inert_floor: u32 = 0,
};

/// The type of a placeholder: above every type a program can name (see `types.Type`).
const placeholder_type: types.Type = @fromBackingInt(@intCast(std.math.maxInt(u16)));
comptime {
    std.debug.assert(types.limits.user_types + 4 < std.math.maxInt(u16));
}

/// A placeholder of the room whose last placeholder is at `limit`.
pub fn placeholder(limit: u32) types.Value {
    return .{ .aggregate = .{ .value_type = placeholder_type, .elements = .{ .start = limit, .end = limit } } };
}

/// The last placeholder of the room `value` belongs to, if it is a placeholder.
pub fn placeholderLimit(value: types.Value) ?u32 {
    if (value != .aggregate or value.aggregate.value_type != placeholder_type) return null;
    return value.aggregate.elements.end;
}

/// Whether every member of `members` names only members below `bound`. The members of an
/// aggregate name only members below its start, and reclamation and the report rely on it. A
/// member written into a room lies below the operand it is copied from, so it may go there
/// only if what it names lies below the array that grows (an array of arrays is copied).
pub fn flat(members: []const types.Value, bound: u32) bool {
    for (members) |member| switch (member) {
        .aggregate => |a| if (a.elements.end > bound) return false,
        .callable => |c| if (c.captures.end > bound) return false,
        else => {},
    };
    return true;
}

/// Whether no member of `members` names anything: strings, instances, members and captures
/// are named; numbers, logic values, enumerators and rationals are not. A reclamation frees
/// only what is named, so such a member may be written into a room below any frame's marks.
pub fn inert(members: []const types.Value) bool {
    for (members) |member| switch (member) {
        .integer, .boolean, .floating, .enumeration, .rational => {},
        .string, .aggregate, .callable, .object => return false,
    };
    return true;
}

/// Whether a join whose room begins at `fill` may write `members` into it.
fn writable(fill: u32, members: []const types.Value, context: Context) bool {
    std.debug.assert(context.inert_floor <= context.floor);
    if (fill >= context.floor) return true;
    return fill >= context.inert_floor and inert(members);
}

/// What a machine reads at `left.end` in `pool`, the members in use: `capacity` is the
/// members the pool can hold.
pub fn roomIn(pool: []const types.Value, left: types.Span, right: types.Span, capacity: usize, context: Context) Room {
    std.debug.assert(pool.len <= capacity);
    var room: Room = .{ .free = capacity - pool.len };
    const floor = context.floor;
    if (left.end <= left.start or right.end <= right.start or left.end >= pool.len) return room;
    const limit = placeholderLimit(pool[left.end]) orelse return room;
    std.debug.assert(limit >= left.end and limit < pool.len);
    room.limit = limit;
    // Whether the members are inert is read only where the room is long enough, as `flat`.
    room.writable = left.end >= floor;
    if (limit - left.end >= right.end - right.start) {
        room.flat = flat(pool[right.start..right.end], left.start);
        room.writable = writable(left.end, pool[right.start..right.end], context);
    }
    return room;
}

/// The members below which a join in a frame with member mark `mark` may not write (0 at the
/// root, which is never reclaimed). A frame's reclamation walks only what lies above its marks,
/// and a member written below them would name strings, instances and members the walk does not
/// see. A frame that reclaims after another task ran does so above the stores' sizes when the
/// root ended, if that is more (RFC-0082, P3.5). When `exposed` (see `contextOf`), the
/// suspended frames of other tasks, pushed with marks of their own, may reclaim over strings
/// and instances the joining frame made, above their marks, which a member written below their
/// member marks would name: such a frame writes into no room.
pub fn floorOf(mark: u64, root_ended: bool, root_members: u64, exposed: bool) u32 {
    if (exposed) return std.math.maxInt(u32);
    return @intCast(if (root_ended) @max(mark, root_members) else mark);
}

/// What a join needs to know of its frame: its member mark `mark` (0 at the root), whether the
/// run has switched tasks since the frame was pushed (`switched`; the root was pushed before
/// every switch), and whether any task holds suspended frames now (`suspended`).
///
/// The suspended frames of other tasks are the ones that can reclaim, above marks of their
/// own, over what a member written into a room below those marks names. A frame pushed after
/// the run's last switch is above every one of them: each was pushed before it, so its marks
/// are at most the joining frame's (reclamation only lowers marks), and the frames below it on
/// its own stack are older still. That is the rule by which a frame end reclaims above its own
/// marks (`ControlStorage.acrossMarks`). A frame that has seen a switch since its push (a `For`
/// whose visits wait) is in the same position when no task holds suspended frames: the frames
/// below it on its stack are older, a task that ran and ended has reclaimed already, and a
/// frame pushed later is pushed after what the join writes and so reclaims above it. A running
/// task holds no saved frames, and the joining frame's task is running. Otherwise such a frame
/// may write only members that name nothing (`inert`).
pub fn contextOf(mark: u64, root_ended: bool, root_members: u64, switched: bool, suspended: bool) Context {
    return .{ .floor = floorOf(mark, root_ended, root_members, switched and suspended), .inert_floor = floorOf(mark, root_ended, root_members, false) };
}

/// `used` is the number of pool members in use before the join.
pub fn plan(left: types.Span, right: types.Span, used: usize, room: Room) Plan {
    const left_length = left.end - left.start;
    const right_length = right.end - right.start;
    if (right_length == 0) return .{ .kind = .left, .span = left, .copy = 0 };
    if (left_length == 0) return .{ .kind = .right, .span = right, .copy = 0 };
    if (left.end == right.start) return .{ .kind = .adjacent, .span = .{ .start = left.start, .end = right.end }, .copy = 0 };
    if (left.end == used) return .{ .kind = .extend, .span = .{ .start = left.start, .end = left.end + right_length }, .copy = right_length };
    if (room.limit) |limit| if (room.flat and room.writable and limit - left.end >= right_length)
        return .{ .kind = .room, .span = .{ .start = left.start, .end = left.end + right_length }, .copy = right_length };
    const start: u32 = @intCast(used);
    const length = left_length + right_length;
    // A copy that fits is never refused for its room: it leaves only the last placeholder, or
    // nothing, where the pool has less than twice the room left after the copy, so that a room,
    // which reclamation keeps as long as its array, takes at most half of what is left. How much is free depends on when the run last
    // reclaimed, so near the limit of the pool the room, and the fuel of the joins after it,
    // can depend on the reclamation floor; away from it they do not.
    const growing = room.limit != null and length <= (types.limits.aggregate_elements - 1) / 3;
    const reserve: u32 = if (room.free <= length) 0 else if (growing and (room.free - length - 1) / 2 >= length) 1 + length else 1;
    return .{ .kind = .fresh, .span = .{ .start = start, .end = start + length }, .copy = length, .reserve = reserve };
}

/// Copies the members a plan appends and advances `used` (the caller has checked capacity).
pub fn apply(pool: []types.Value, used: anytype, left: types.Span, right: types.Span, p: Plan) void {
    switch (p.kind) {
        .left, .right, .adjacent => {},
        .extend => {
            std.debug.assert(p.span.start == left.start and used.* == left.end);
            @memcpy(pool[left.end..p.span.end], pool[right.start..right.end]);
            used.* += p.copy;
        },
        .room => {
            std.debug.assert(p.span.start == left.start and p.span.end < used.*);
            @memcpy(pool[left.end..p.span.end], pool[right.start..right.end]);
        },
        .fresh => {
            const split = p.span.start + (left.end - left.start);
            @memcpy(pool[p.span.start..split], pool[left.start..left.end]);
            @memcpy(pool[split..p.span.end], pool[right.start..right.end]);
            if (p.reserve != 0) {
                const limit = p.span.end + p.reserve - 1;
                @memset(pool[p.span.end .. limit + 1], placeholder(limit));
            }
            used.* += p.copy + p.reserve;
        },
    }
}

/// The rooms a report replay knows to be open, in pool order. A replay cannot read them in
/// its pool, which later joins may already have filled. Each room is the position of its
/// first unfilled placeholder (`fill`) and of its last (`limit`); both rise from room to room.
pub const Rooms = struct {
    fills: []u32 = &.{},
    limits: []u32 = &.{},
    count: usize = 0,

    /// The rooms a run can have open at once: each follows a copy of at least two members.
    pub const capacity = types.limits.aggregate_elements / 3 + 1;

    /// What lies at `left.end` for this join, as a machine reads it in its own pool. `pool`
    /// holds the right operand and `used` is the members in use.
    pub fn at(self: *const Rooms, pool: []const types.Value, left: types.Span, right: types.Span, used: usize, context: Context) Room {
        var room: Room = .{ .free = types.limits.aggregate_elements -| used };
        if (left.end <= left.start or right.end <= right.start) return room;
        const index = self.find(left.end) orelse return room;
        room.limit = self.limits[index];
        room.writable = left.end >= context.floor;
        if (self.limits[index] - left.end >= right.end - right.start) {
            room.flat = flat(pool[right.start..right.end], left.start);
            room.writable = writable(left.end, pool[right.start..right.end], context);
        }
        return room;
    }

    fn find(self: *const Rooms, fill: u32) ?usize {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.fills[middle] < fill) low = middle + 1 else high = middle;
        }
        return if (low < self.count and self.fills[low] == fill) low else null;
    }

    /// Follows a join the replay has admitted. False when it has no place to remember a room.
    pub fn record(self: *Rooms, left: types.Span, p: Plan) bool {
        switch (p.kind) {
            .room => self.fills[self.find(left.end).?] = p.span.end,
            .fresh => if (p.reserve != 0) {
                if (self.count == self.fills.len or self.count == self.limits.len) return false;
                std.debug.assert(self.count == 0 or self.limits[self.count - 1] < p.span.end);
                self.fills[self.count] = p.span.end;
                self.limits[self.count] = p.span.end + p.reserve - 1;
                self.count += 1;
            },
            else => {},
        }
        return true;
    }

    /// The last placeholder of the open room that begins at `fill`, if one does.
    pub fn after(self: *const Rooms, fill: u32) ?u32 {
        return if (self.find(fill)) |index| self.limits[index] else null;
    }

    /// Follows a reclamation above `mark`: `slots[i]` is the number of members kept below
    /// `mark + i`. A room above the mark is kept whole, behind the array it belongs to, or not.
    pub fn moved(self: *Rooms, mark: u32, slots: []const u32) void {
        var first = self.count;
        while (first != 0 and self.limits[first - 1] >= mark) first -= 1;
        var kept = first;
        for (first..self.count) |index| {
            const fill = self.fills[index] - mark;
            const limit = self.limits[index] - mark;
            std.debug.assert(fill <= limit and limit + 1 < slots.len);
            // A kept room is kept whole, so its last placeholder tells.
            if (slots[limit + 1] == slots[limit]) continue;
            self.fills[kept] = mark + slots[fill];
            self.limits[kept] = mark + slots[limit];
            kept += 1;
        }
        self.count = kept;
    }
};

test "plans choose the cheapest valid layout" {
    const a: types.Span = .{ .start = 0, .end = 3 };
    const b: types.Span = .{ .start = 3, .end = 5 };
    const empty: types.Span = .{ .start = 9, .end = 9 };
    try std.testing.expectEqual(Kind.left, plan(a, empty, 5, .{ .free = 0 }).kind);
    try std.testing.expectEqual(Kind.right, plan(empty, b, 5, .{ .free = 0 }).kind);
    const joined = plan(a, b, 5, .{ .free = 0 });
    try std.testing.expectEqual(Kind.adjacent, joined.kind);
    try std.testing.expectEqual(types.Span{ .start = 0, .end = 5 }, joined.span);
    try std.testing.expectEqual(@as(u32, 0), joined.copy);
    const grown = plan(b, a, 5, .{ .free = 0 });
    try std.testing.expectEqual(Kind.extend, grown.kind);
    try std.testing.expectEqual(types.Span{ .start = 3, .end = 8 }, grown.span);
    try std.testing.expectEqual(@as(u32, 3), grown.copy);
    const copied = plan(a, b, 7, .{ .free = 0 });
    try std.testing.expectEqual(Kind.adjacent, copied.kind);
    const apart = plan(a, .{ .start = 4, .end = 5 }, 7, .{ .free = 100 });
    try std.testing.expectEqual(Kind.fresh, apart.kind);
    try std.testing.expectEqual(types.Span{ .start = 7, .end = 11 }, apart.span);
    try std.testing.expectEqual(@as(u32, 4), apart.copy);
}

test "apply writes only what the plan appends and leaves operands intact" {
    var pool: [16]types.Value = undefined;
    for (pool[0..5], 0..) |*slot, index| slot.* = .{ .integer = @intCast(index) };
    var used: usize = 5;
    const a: types.Span = .{ .start = 0, .end = 2 };
    const c: types.Span = .{ .start = 3, .end = 5 };
    const fresh = plan(a, c, used, .{ .free = pool.len - used });
    apply(&pool, &used, a, c, fresh);
    // The copy and the placeholder behind it.
    try std.testing.expectEqual(@as(usize, 10), used);
    for ([_]i64{ 0, 1, 3, 4 }, pool[fresh.span.start..fresh.span.end]) |want, got| try std.testing.expectEqual(want, got.integer);
    try std.testing.expectEqual(@as(?u32, 9), placeholderLimit(pool[9]));
    // The operands still read as before.
    try std.testing.expectEqual(@as(i64, 1), pool[1].integer);
    try std.testing.expectEqual(@as(i64, 4), pool[4].integer);
    pool[used] = .{ .integer = 7 };
    used += 1;
    const tail: types.Span = .{ .start = 10, .end = 11 };
    const extended = plan(tail, a, used, .{ .free = pool.len - used });
    try std.testing.expectEqual(Kind.extend, extended.kind);
    apply(&pool, &used, tail, a, extended);
    try std.testing.expectEqual(@as(usize, 13), used);
    for ([_]i64{ 7, 0, 1 }, pool[extended.span.start..extended.span.end]) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "a copy leaves a room only behind a growing array and a join of the room's array fills it" {
    var pool: [64]types.Value = undefined;
    for (pool[0..6], 0..) |*slot, index| slot.* = .{ .integer = @intCast(index) };
    var used: usize = 6;
    const a: types.Span = .{ .start = 0, .end = 2 };
    const one: types.Span = .{ .start = 4, .end = 5 };
    // A first copy: only the last placeholder, which no join can fill.
    const first = plan(a, one, used, roomIn(pool[0..used], a, one, pool.len, .{}));
    try std.testing.expectEqual(Kind.fresh, first.kind);
    try std.testing.expectEqual(@as(u32, 3), first.copy);
    try std.testing.expectEqual(@as(u32, 1), first.reserve);
    apply(&pool, &used, a, one, first);
    try std.testing.expectEqual(@as(usize, 10), used);
    try std.testing.expectEqual(@as(?u32, 9), placeholderLimit(pool[9]));
    // Something lands behind it, as a loop's state does; the array is not at the tail.
    pool[used] = .{ .integer = 99 };
    used += 1;
    // Its next join sees the placeholder: a growing array, copied with as much room as it copies.
    const second = plan(first.span, one, used, roomIn(pool[0..used], first.span, one, pool.len, .{}));
    try std.testing.expectEqual(Kind.fresh, second.kind);
    try std.testing.expectEqual(@as(u32, 4), second.copy);
    try std.testing.expectEqual(@as(u32, 5), second.reserve);
    apply(&pool, &used, first.span, one, second);
    try std.testing.expectEqual(@as(usize, 20), used);
    pool[used] = .{ .integer = 98 };
    used += 1;
    // Four joins fill the room, each charged one member and adding none to the pool.
    var grown = second.span;
    for (0..4) |_| {
        const into = plan(grown, one, used, roomIn(pool[0..used], grown, one, pool.len, .{}));
        try std.testing.expectEqual(Kind.room, into.kind);
        try std.testing.expectEqual(@as(u32, 1), into.copy);
        try std.testing.expectEqual(@as(u32, 0), into.appended());
        apply(&pool, &used, grown, one, into);
        try std.testing.expectEqual(@as(usize, 21), used);
        grown = into.span;
    }
    try std.testing.expectEqual(types.Span{ .start = 11, .end = 19 }, grown);
    for ([_]i64{ 0, 1, 4, 4, 4, 4, 4, 4 }, pool[grown.start..grown.end]) |want, got| try std.testing.expectEqual(want, got.integer);
    // The older arrays still read as they did: a room lies beyond every array that exists.
    for ([_]i64{ 0, 1, 4, 4 }, pool[second.span.start..second.span.end]) |want, got| try std.testing.expectEqual(want, got.integer);
    // The last placeholder stays: the next join is a growing copy again.
    const again = plan(grown, one, used, roomIn(pool[0..used], grown, one, pool.len, .{}));
    try std.testing.expectEqual(Kind.fresh, again.kind);
    try std.testing.expect(again.reserve > 1);
    // An older array that ends inside the filled room is no longer at a room: a plain copy.
    const older = plan(second.span, one, used, roomIn(pool[0..used], second.span, one, pool.len, .{}));
    try std.testing.expectEqual(Kind.fresh, older.kind);
    try std.testing.expectEqual(@as(u32, 1), older.reserve);
    apply(&pool, &used, grown, one, again);
    // A member that names something at or above the growing array's start is never written
    // below it: such an array of arrays is copied. One that names older members fills the room.
    pool[used] = .{ .aggregate = .{ .value_type = .i64, .elements = .{ .start = again.span.start, .end = again.span.start + 1 } } };
    pool[used + 1] = .{ .aggregate = .{ .value_type = .i64, .elements = .{ .start = 0, .end = 1 } } };
    const above: types.Span = .{ .start = @intCast(used), .end = @intCast(used + 1) };
    const below: types.Span = .{ .start = @intCast(used + 1), .end = @intCast(used + 2) };
    used += 2;
    try std.testing.expect(!roomIn(pool[0..used], again.span, above, pool.len, .{}).flat);
    try std.testing.expectEqual(Kind.fresh, plan(again.span, above, used, roomIn(pool[0..used], again.span, above, pool.len, .{})).kind);
    try std.testing.expectEqual(Kind.room, plan(again.span, below, used, roomIn(pool[0..used], again.span, below, pool.len, .{})).kind);
    // A frame whose mark lies above the room does not write into it: it copies.
    try std.testing.expect(!roomIn(pool[0..used], again.span, below, pool.len, .{ .floor = again.span.end + 1 }).writable);
    try std.testing.expectEqual(Kind.fresh, plan(again.span, below, used, roomIn(pool[0..used], again.span, below, pool.len, .{ .floor = again.span.end + 1 })).kind);
    // A growing copy leaves a room as long as itself, up to a third of the pool, where the pool
    // has twice that room left after the copy; otherwise only the last placeholder, and nothing
    // where the copy just fits.
    const fits = plan(grown, one, 21, .{ .limit = 19, .free = 9 + 1 + 18 });
    try std.testing.expectEqual(@as(u32, 9), fits.copy);
    try std.testing.expectEqual(@as(u32, 1 + 9), fits.reserve);
    try std.testing.expectEqual(@as(u32, 9 + 1 + 9), fits.appended());
    try std.testing.expectEqual(@as(u32, 1), plan(grown, one, 21, .{ .limit = 19, .free = 9 + 1 + 17 }).reserve);
    try std.testing.expectEqual(@as(u32, 1), plan(grown, one, 21, .{ .limit = 19, .free = 10 }).reserve);
    try std.testing.expectEqual(@as(u32, 0), plan(grown, one, 21, .{ .limit = 19, .free = 9 }).reserve);
    const third: u32 = (types.limits.aggregate_elements - 1) / 3;
    const ample = std.math.maxInt(u32);
    const large: types.Span = .{ .start = 0, .end = third - 1 };
    try std.testing.expectEqual(@as(u32, 1 + third), plan(large, one, third + 5, .{ .limit = third - 1, .free = ample }).reserve);
    const larger: types.Span = .{ .start = 0, .end = third };
    try std.testing.expectEqual(@as(u32, 1), plan(larger, one, third + 5, .{ .limit = third, .free = ample }).reserve);
}

test "a frame that saw a switch writes into a room unless another task holds suspended frames, or what it writes names nothing" {
    var pool: [64]types.Value = undefined;
    for (pool[0..6], 0..) |*slot, index| slot.* = .{ .integer = @intCast(index) };
    var used: usize = 6;
    const a: types.Span = .{ .start = 0, .end = 2 };
    const one: types.Span = .{ .start = 4, .end = 5 };
    // A growing array, at 11 to 15, with its room behind it, at 15 to 19.
    apply(&pool, &used, a, one, plan(a, one, used, roomIn(pool[0..used], a, one, pool.len, .{})));
    const first: types.Span = .{ .start = 6, .end = 9 };
    pool[used] = .{ .integer = 99 };
    used += 1;
    const second = plan(first, one, used, roomIn(pool[0..used], first, one, pool.len, .{}));
    apply(&pool, &used, first, one, second);
    try std.testing.expect(second.reserve > 1);
    // Right operands: an integer, a string, an instance, an array of older members, a rational.
    pool[used] = .{ .string = "s" };
    pool[used + 1] = .{ .object = .{ .value_type = .i64, .id = 0 } };
    pool[used + 2] = .{ .aggregate = .{ .value_type = .i64, .elements = .{ .start = 0, .end = 1 } } };
    pool[used + 3] = .{ .rational = .{ .numerator = 1, .denominator = 3 } };
    const named = [_]types.Span{ .{ .start = @intCast(used), .end = @intCast(used + 1) }, .{ .start = @intCast(used + 1), .end = @intCast(used + 2) }, .{ .start = @intCast(used + 2), .end = @intCast(used + 3) } };
    const rational: types.Span = .{ .start = @intCast(used + 3), .end = @intCast(used + 4) };
    used += 4;
    const mark = second.span.start;
    // Pushed after the last switch, or no task holds suspended frames: every flat member.
    for ([_][2]bool{ .{ false, false }, .{ false, true }, .{ true, false } }) |flags| {
        const context = contextOf(mark, false, 0, flags[0], flags[1]);
        try std.testing.expectEqual(@as(u32, mark), context.floor);
        for (named ++ [_]types.Span{ one, rational }) |right| try std.testing.expectEqual(Kind.room, plan(second.span, right, used, roomIn(pool[0..used], second.span, right, pool.len, context)).kind);
    }
    // Switched while another task holds suspended frames: numbers only, above the own floor.
    const exposed = contextOf(mark, false, 0, true, true);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), exposed.floor);
    try std.testing.expectEqual(@as(u32, mark), exposed.inert_floor);
    for (named) |right| try std.testing.expectEqual(Kind.fresh, plan(second.span, right, used, roomIn(pool[0..used], second.span, right, pool.len, exposed)).kind);
    for ([_]types.Span{ one, rational }) |right| try std.testing.expectEqual(Kind.room, plan(second.span, right, used, roomIn(pool[0..used], second.span, right, pool.len, exposed)).kind);
    const above = contextOf(second.span.end + 1, false, 0, true, true);
    try std.testing.expectEqual(Kind.fresh, plan(second.span, one, used, roomIn(pool[0..used], second.span, one, pool.len, above)).kind);
    // After the root ended, the own floor is at least what the root held.
    try std.testing.expectEqual(@as(u32, 40), contextOf(mark, true, 40, true, true).inert_floor);
    try std.testing.expectEqual(Kind.fresh, plan(second.span, one, used, roomIn(pool[0..used], second.span, one, pool.len, contextOf(mark, true, 40, true, true))).kind);
    // The replay's list reads the same.
    var fills: [4]u32 = undefined;
    var limits: [4]u32 = undefined;
    var rooms: Rooms = .{ .fills = &fills, .limits = &limits };
    try std.testing.expect(rooms.record(first, second));
    for (named ++ [_]types.Span{ one, rational }) |right| for ([_]Context{ exposed, above, contextOf(mark, false, 0, true, false) }) |context| {
        var replayed = rooms.at(&pool, second.span, right, used, context);
        replayed.free = pool.len - used;
        try std.testing.expectEqualDeep(roomIn(pool[0..used], second.span, right, pool.len, context), replayed);
    };
    try std.testing.expect(inert(&.{ .{ .integer = 1 }, .{ .boolean = true }, .{ .floating = 0.5 } }));
    try std.testing.expect(!inert(&.{ .{ .integer = 1 }, .{ .string = "x" } }));
}

test "the rooms a replay remembers match what the machines read in their pools, over random joins" {
    // A model of one run: arrays as spans of a pool, joined at random, with literals and wrappers
    // appended between joins, and frames whose ends keep nothing above their marks. The machine reads
    // rooms in its pool and the replay remembers them; both must plan every join alike, and every
    // array must keep its elements, which the model holds as plain lists.
    var prng = std.Random.DefaultPrng.init(0x9e37_79b9_0055);
    const random = prng.random();
    const capacity = 4096;
    const arrays_max = 64;
    const pool = try std.testing.allocator.alloc(types.Value, capacity);
    defer std.testing.allocator.free(pool);
    const fills = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(fills);
    const limits = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(limits);
    const model = try std.testing.allocator.alloc([capacity]i64, arrays_max + 1);
    defer std.testing.allocator.free(model);
    var lengths: [arrays_max + 1]usize = undefined;
    var spans: [arrays_max + 1]types.Span = undefined;
    const nothing = try std.testing.allocator.alloc(u32, capacity + 1);
    defer std.testing.allocator.free(nothing);
    var rooms_seen: usize = 0;
    var kinds = std.EnumArray(Kind, usize).initFill(0);
    for (0..40) |_| {
        var rooms: Rooms = .{ .fills = fills, .limits = limits };
        var used: usize = 0;
        var arrays: usize = 0;
        var next: i64 = 0;
        // The pool sizes at which frames still open were pushed: a reclamation happens where a
        // frame ends, above its own mark, and every room lies wholly below or above that mark.
        var marks: [16]u32 = undefined;
        var depth: usize = 0;
        for (0..400) |_| {
            const action = random.uintLessThan(u32, 11);
            if (action < 3 or arrays < 2) {
                // A literal of fresh integers.
                const length = random.uintLessThan(usize, 4);
                if (used + length > capacity or arrays == arrays_max) break;
                spans[arrays] = .{ .start = @intCast(used), .end = @intCast(used + length) };
                for (0..length) |offset| {
                    pool[used + offset] = .{ .integer = next };
                    model[arrays][offset] = next;
                    next += 1;
                }
                lengths[arrays] = length;
                used += length;
                arrays += 1;
            } else if (action < 4) {
                // A wrapper, as a loop state leaves behind the array it holds.
                if (used == capacity) break;
                pool[used] = .{ .boolean = true };
                used += 1;
            } else if (action < 9) {
                const l = random.uintLessThan(usize, arrays);
                const r = random.uintLessThan(usize, arrays);
                const left = spans[l];
                const right = spans[r];
                // A frame that saw a switch while another task holds suspended frames writes
                // only members that name nothing, which every member of this model is.
                const context = contextOf(if (depth == 0) 0 else marks[depth - 1], false, 0, random.boolean(), random.boolean());
                const machine = roomIn(pool[0..used], left, right, capacity, context);
                var replayed = rooms.at(pool, left, right, used, context);
                // The model's pool is smaller than a run's.
                replayed.free = capacity - used;
                try std.testing.expectEqualDeep(machine, replayed);
                const p = plan(left, right, used, machine);
                if (p.appended() > capacity - used) break;
                kinds.getPtr(p.kind).* += 1;
                apply(pool, &used, left, right, p);
                try std.testing.expect(rooms.record(left, p));
                // The result is the joined list in a new slot, or over the left operand's slot
                // when the model is full; every other operand must read as before.
                const slot = if (arrays < arrays_max) arrays else l;
                const left_length = lengths[l];
                const right_length = lengths[r];
                var joined: [capacity]i64 = undefined;
                @memcpy(joined[0..left_length], model[l][0..left_length]);
                @memcpy(joined[left_length .. left_length + right_length], model[r][0..right_length]);
                lengths[slot] = left_length + right_length;
                @memcpy(model[slot][0..lengths[slot]], joined[0..lengths[slot]]);
                spans[slot] = p.span;
                if (slot == arrays) arrays += 1;
            } else if (action < 10 or depth == 0) {
                if (depth < marks.len) {
                    marks[depth] = @intCast(used);
                    depth += 1;
                }
            } else {
                // A frame ends and keeps nothing above its mark: the arrays above it are gone.
                depth -= 1;
                const mark = marks[depth];
                var kept: usize = 0;
                for (0..arrays) |index| if (spans[index].end <= mark or spans[index].start == spans[index].end) {
                    spans[kept] = if (spans[index].end <= mark) spans[index] else .{ .start = 0, .end = 0 };
                    lengths[kept] = lengths[index];
                    if (kept != index) @memcpy(model[kept][0..lengths[kept]], model[index][0..lengths[index]]);
                    kept += 1;
                };
                arrays = kept;
                // Nothing above the mark is kept, so no room above it either.
                @memset(nothing[0 .. used - mark + 1], 0);
                rooms.moved(mark, nothing[0 .. used - mark + 1]);
                used = mark;
            }
            for (spans[0..arrays], lengths[0..arrays], model[0..arrays]) |span, length, *items| {
                try std.testing.expectEqual(length, span.end - span.start);
                for (pool[span.start..span.end], items[0..length]) |value, want| try std.testing.expectEqual(want, value.integer);
            }
            rooms_seen = @max(rooms_seen, rooms.count);
        }
    }
    try std.testing.expect(rooms_seen > 1);
    for ([_]Kind{ .left, .right, .adjacent, .extend, .fresh, .room }) |kind| try std.testing.expect(kinds.get(kind) > 0);
}
