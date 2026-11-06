//! Deterministic equality and hashing of comparable values, and explicitly funded map work
//! (RFC-0065). Callers admit types, ranges, canonical floats and string ownership first.
//!
//! Equality is structural: scalars by value (floats with one NaN and one zero, as `==` has
//! them), enum cases by case, instances by identity, and records, tuples, options, arrays and
//! maps part by part in order. Every value visited costs one unit and every string byte compared
//! one more, so the cost of a comparison follows what it had to look at and both machines, which
//! share this file for keys, charge the same. Structural values are walked with an explicit
//! stack: nesting is as deep as the type catalogue allows, which a guest chooses.
//!
//! Nothing here asks the host for memory per comparison. What a walk or a duplicate check needs
//! beyond the native stack belongs to a `Work` that its machine keeps for a whole run, and a
//! host that cannot provide it is `ScratchUnavailable`, never an exhausted budget: fuel is the
//! guest's and must not depend on the host's memory.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
pub const Error = error{ WorkLimit, DuplicateKey, ScratchUnavailable };

pub fn dynamic(definitions: []const types.Definition) bool {
    // RFC-0087: a `weak_map`'s lookups and updates are a map's.
    for (definitions) |definition| if (definition == .map or definition == .weak_map) return true;
    return false;
}

pub fn spend(remaining: *u64, amount: u64) error{WorkLimit}!void {
    if (amount > remaining.*) return error.WorkLimit;
    remaining.* -= amount;
}

fn floatBits(value: f64) u64 {
    if (value == 0) return 0;
    return @bitCast(types.canonicalFloat(value));
}

/// A place in two aggregates of equal length that are being compared member by member. A hash
/// walks one aggregate and leaves `right` alone.
pub const Pair = struct { left: u32, right: u32, end: u32 };

/// Levels of a walk that stay on the native stack: nearly every value is this shallow.
const near_depth = 16;
/// A level names an earlier definition than the one around it, so a value of the last type a
/// catalogue can hold opens `user_types` levels and no admitted value opens more.
pub const far_depth = types.limits.user_types - near_depth;
/// The levels below the near ones. A machine that has storage of its own keeps one of these
/// and lends it to its `Work`.
pub const FarLevels = [far_depth]Pair;

/// What walks and duplicate checks use beyond the native stack, kept by one machine for one run
/// and reused by every operation of it. Walks do not nest, so one set of far levels serves all.
pub const Work = struct {
    /// Empty until a value nests deeper than the near levels, unless they were lent.
    far: []Pair = &.{},
    far_lent: bool = false,
    /// The table of the largest map literal checked so far; smaller checks use its front.
    slots: []u32 = &.{},
    /// How often the host was asked for memory: at most once for the far levels and once per
    /// doubling of the largest literal, however many operations ran.
    host_requests: u32 = 0,
    /// Failure injection: the host has nothing to give.
    host_exhausted: bool = false,

    /// A `Work` over far levels the caller owns for at least as long.
    pub fn lend(levels: *FarLevels) Work {
        return .{ .far = levels, .far_lent = true };
    }

    /// Returns what was taken from the host. The `Work` can be used again afterwards.
    pub fn release(self: *Work) void {
        if (!self.far_lent and self.far.len != 0) {
            scratch.free(self.far);
            self.far = &.{};
        }
        if (self.slots.len != 0) scratch.free(self.slots);
        self.slots = &.{};
    }

    fn request(self: *Work, comptime T: type, count: usize) error{ScratchUnavailable}![]T {
        if (self.host_exhausted) return error.ScratchUnavailable;
        const memory = scratch.alloc(T, count) orelse return error.ScratchUnavailable;
        self.host_requests += 1;
        return memory;
    }

    fn farLevels(self: *Work) error{ScratchUnavailable}![]Pair {
        if (self.far.len == 0) {
            std.debug.assert(!self.far_lent);
            self.far = try self.request(Pair, far_depth);
        }
        return self.far;
    }

    /// `count` slots, not cleared. `count` is a power of two, so the table at most doubles.
    fn table(self: *Work, count: usize) error{ScratchUnavailable}![]u32 {
        std.debug.assert(std.math.isPowerOfTwo(count));
        if (self.slots.len < count) {
            const larger = try self.request(u32, count);
            if (self.slots.len != 0) scratch.free(self.slots);
            self.slots = larger;
        }
        return self.slots[0..count];
    }
};

/// The aggregates a walk is inside of: the first few on the native stack, the rest in the far
/// levels of the machine's `Work`.
const Levels = struct {
    work: *Work,
    near: [near_depth]Pair = undefined,
    depth: usize = 0,

    fn push(self: *Levels, frame: Pair) error{ WorkLimit, ScratchUnavailable }!void {
        if (self.depth < near_depth) {
            self.near[self.depth] = frame;
        } else {
            const far = try self.work.farLevels();
            // Deeper than any type nests. No admitted value is; one that claims to be is cut
            // off like any other work without end.
            if (self.depth - near_depth == far.len) return error.WorkLimit;
            far[self.depth - near_depth] = frame;
        }
        self.depth += 1;
    }
    fn top(self: *Levels) ?*Pair {
        if (self.depth == 0) return null;
        return if (self.depth <= near_depth) &self.near[self.depth - 1] else &self.work.far[self.depth - 1 - near_depth];
    }
};

/// Whether two values of one comparable type are equal. `pool` holds the members of every
/// aggregate either value names.
pub fn equal(work: *Work, pool: []const types.Value, lhs: types.Value, rhs: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!bool {
    if (lhs != .aggregate) return equalScalar(lhs, rhs, remaining);
    return equalParts(work, pool, lhs, rhs, remaining);
}

noinline fn equalParts(work: *Work, pool: []const types.Value, lhs: types.Value, rhs: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!bool {
    var levels: Levels = .{ .work = work };
    var left = lhs;
    var right = rhs;
    while (true) {
        if (left == .aggregate) {
            try spend(remaining, 1);
            if (right != .aggregate) return false;
            const a = left.aggregate.elements;
            const b = right.aggregate.elements;
            std.debug.assert(a.start <= a.end and a.end <= pool.len and b.start <= b.end and b.end <= pool.len);
            // Arrays and maps of different lengths, and a present against an absent option.
            if (a.end - a.start != b.end - b.start) return false;
            if (a.start != a.end) try levels.push(.{ .left = a.start, .right = b.start, .end = a.end });
        } else if (!try equalScalar(left, right, remaining)) return false;
        while (true) {
            const level = levels.top() orelse return true;
            if (level.left == level.end) {
                levels.depth -= 1;
                continue;
            }
            left = pool[level.left];
            right = pool[level.right];
            level.left += 1;
            level.right += 1;
            break;
        }
    }
}

fn equalScalar(lhs: types.Value, rhs: types.Value, remaining: *u64) error{WorkLimit}!bool {
    try spend(remaining, 1);
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .integer => |value| value == rhs.integer,
        .boolean => |value| value == rhs.boolean,
        .floating => |value| floatBits(value) == floatBits(rhs.floating),
        .enumeration => |value| std.meta.eql(value, rhs.enumeration),
        .string => |value| string: {
            if (value.len != rhs.string.len) break :string false;
            for (value, rhs.string) |a, b| {
                try spend(remaining, 1);
                if (a != b) break :string false;
            }
            break :string true;
        },
        // The same instance, whichever of its classes each side is seen as.
        .object => |value| value.id == rhs.object.id,
        // Rationals are held in lowest terms, so equal fractions are equal term by term.
        .rational => |value| value.numerator == rhs.rational.numerator and value.denominator == rhs.rational.denominator,
        .aggregate => false, // A structural value against a scalar: never of one type.
        .callable => unreachable, // The catalogue admits no function inside a comparable type.
    };
}

/// Equal values hash equally; scalar keys hash as they always have, so the probes a map of
/// them costs are unchanged.
fn hash(work: *Work, pool: []const types.Value, key: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!u64 {
    if (key != .aggregate) return hashScalar(key, remaining);
    return hashParts(work, pool, key, remaining);
}

noinline fn hashParts(work: *Work, pool: []const types.Value, key: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!u64 {
    var levels: Levels = .{ .work = work };
    var result: u64 = @backingInt(std.meta.activeTag(key));
    var current = key;
    while (true) {
        if (current == .aggregate) {
            try spend(remaining, 1);
            const range = current.aggregate.elements;
            std.debug.assert(range.start <= range.end and range.end <= pool.len);
            // The length separates `option{}` from `option{X}` and tells nested arrays apart.
            result = hashBits(result, range.end - range.start);
            if (range.start != range.end) try levels.push(.{ .left = range.start, .right = range.start, .end = range.end });
        } else result = hashBits(result, try hashScalar(current, remaining));
        while (true) {
            const level = levels.top() orelse return result;
            if (level.left == level.end) {
                levels.depth -= 1;
                continue;
            }
            current = pool[level.left];
            level.left += 1;
            break;
        }
    }
}

fn hashScalar(key: types.Value, remaining: *u64) error{WorkLimit}!u64 {
    try spend(remaining, 1);
    const seed: u64 = @backingInt(std.meta.activeTag(key));
    return switch (key) {
        .integer => |value| hashBits(seed, @bitCast(value)),
        .boolean => |value| if (value) 1 else 0,
        .floating => |value| number: {
            const bits = floatBits(value);
            break :number hashBits(seed, bits);
        },
        .enumeration => |value| nominal: {
            const bits: u64 = @as(u64, @backingInt(value.value_type)) << 32 | value.index;
            break :nominal hashBits(seed, bits);
        },
        .string => |value| string: {
            try spend(remaining, value.len);
            break :string std.hash.Wyhash.hash(seed, value);
        },
        .object => |value| hashBits(seed, value.id),
        .rational => |value| hashBits(hashBits(seed, @bitCast(value.numerator)), @bitCast(value.denominator)),
        .aggregate, .callable => unreachable,
    };
}

fn hashBits(seed: u64, bits: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, bits, .little);
    return std.hash.Wyhash.hash(seed, &bytes);
}

/// Fails when two keys of the map `elements` are equal. `pool` holds the parts of its keys.
pub noinline fn unique(work: *Work, pool: []const types.Value, elements: []const types.Value, remaining: *u64) Error!void {
    std.debug.assert(elements.len % 2 == 0 and elements.len <= types.limits.aggregate_elements);
    // At most 4,096 keys occupy 8,192 slots. Collisions consume ordinary fuel,
    // not a separate arbitrary admission quota. Entries are pair-index + 1.
    if (elements.len == 0) return;
    // The table is sized by the map, not by the profile: small maps use the stack, large ones
    // the table the run keeps, which grows only when a literal is larger than any before it.
    var small: [512]u32 = undefined;
    const slot_count = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 2), elements.len)) catch unreachable;
    const slots = if (slot_count > small.len) try work.table(slot_count) else small[0..slot_count];
    @memset(slots, 0);
    var pair: usize = 0;
    while (pair < elements.len / 2) : (pair += 1) {
        const key = elements[2 * pair];
        const start = try hash(work, pool, key, remaining) % slots.len;
        var inserted = false;
        for (0..slots.len) |probe| {
            try spend(remaining, 1);
            const slot = (start + probe) % slots.len;
            const entry = slots[slot];
            if (entry == 0) {
                slots[slot] = @intCast(pair + 1);
                inserted = true;
                break;
            }
            std.debug.assert(entry - 1 < pair);
            if (try equal(work, pool, key, elements[2 * (@as(usize, entry) - 1)], remaining)) return error.DuplicateKey;
        }
        std.debug.assert(inserted);
    }
}

/// Slots enough for the table of a small map: what `unique` and `indexed` keep on the stack.
pub const small_slots = 512;

/// A table over the keys of one map, for looking up many keys in it (RFC-0077): one lookup
/// costs what a probe costs, not a walk of the map. It lives in the slots it was built in,
/// which are the caller's or the run's, until either is used for something else.
pub const Index = struct {
    slots: []u32,
    elements: []const types.Value,

    /// The offset in the map of the value stored under a key equal to `key`, if any.
    pub fn find(self: Index, work: *Work, pool: []const types.Value, key: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!?usize {
        if (self.slots.len == 0) return null;
        const start = try hash(work, pool, key, remaining) % self.slots.len;
        for (0..self.slots.len) |probe| {
            try spend(remaining, 1);
            const entry = self.slots[(start + probe) % self.slots.len];
            if (entry == 0) return null;
            const pair = @as(usize, entry) - 1;
            if (try equal(work, pool, key, self.elements[2 * pair], remaining)) return 2 * pair + 1;
        }
        // The table is at most half full, so a probe always meets an empty slot first.
        unreachable;
    }
};

/// Indexes the keys of the map `elements`, which are distinct as the keys of every map value
/// are. The table is `small` when the map fits it and the run's otherwise.
pub noinline fn indexed(work: *Work, small: *[small_slots]u32, pool: []const types.Value, elements: []const types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!Index {
    std.debug.assert(elements.len % 2 == 0 and elements.len <= types.limits.aggregate_elements);
    if (elements.len == 0) return .{ .slots = &.{}, .elements = elements };
    // Twice as many slots as keys, as `unique` has: at least half of them stay empty.
    const slot_count = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 2), elements.len)) catch unreachable;
    const slots = if (slot_count > small.len) try work.table(slot_count) else small[0..slot_count];
    @memset(slots, 0);
    var pair: usize = 0;
    while (pair < elements.len / 2) : (pair += 1) {
        const start = try hash(work, pool, elements[2 * pair], remaining) % slots.len;
        for (0..slots.len) |probe| {
            try spend(remaining, 1);
            const slot = (start + probe) % slots.len;
            if (slots[slot] != 0) continue;
            slots[slot] = @intCast(pair + 1);
            break;
        }
    }
    return .{ .slots = slots, .elements = elements };
}

/// The offset in the map `elements` of the value stored under `key`, if any.
pub noinline fn lookup(work: *Work, pool: []const types.Value, elements: []const types.Value, key: types.Value, remaining: *u64) error{ WorkLimit, ScratchUnavailable }!?usize {
    std.debug.assert(elements.len % 2 == 0 and elements.len <= types.limits.aggregate_elements);
    var index: usize = 0;
    while (index < elements.len) : (index += 2) {
        try spend(remaining, 1);
        if (try equal(work, pool, elements[index], key, remaining)) return index + 1;
    }
    return null;
}
