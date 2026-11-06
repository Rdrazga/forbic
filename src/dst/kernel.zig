//! Deterministic test infrastructure. No clocks, native I/O, or ambient entropy.
const std = @import("std");
const assert = std.debug.assert;

pub const version = 1;
pub const max_steps = 1_000_000;
pub const trace_capacity = 128;
pub const Error = error{ Invariant, InvalidOptions, ClockExhausted, QueueFull, CounterExhausted };
pub const Phase = enum { safety, recovery };
pub const Mode = enum { swarm, performance };
pub const Fault = enum { drop, delay, duplicate, corrupt, crash, exhaustion, partition };

/// SplitMix64; unsigned wrapping operations specify the stream across hosts.
pub const Rng = struct {
    state: u64,
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }
    /// Internal callers supply a nonzero range. Rejection avoids modulo bias.
    pub fn below(self: *Rng, exclusive: u64) u64 {
        assert(exclusive > 0);
        const threshold = (0 -% exclusive) % exclusive;
        while (true) {
            const value = self.next();
            if (value >= threshold) {
                const result = value % exclusive;
                assert(result < exclusive);
                return result;
            }
        }
    }
};

pub const Profile = struct {
    rates: [std.meta.tags(Fault).len]u16,
    pub fn init(seed: u64, mode: Mode) Profile {
        if (mode == .performance) return .{ .rates = .{ 1, 10, 0, 0, 0, 0, 0 } };
        // The distribution itself varies per seed, including disabled faults.
        var rng: Rng = .{ .state = seed ^ 0x6d04f951230da13b };
        var result: Profile = undefined;
        for (&result.rates) |*rate| rate.* = @intCast(rng.below(31));
        return result;
    }
};

pub const Counters = struct {
    checks: u64 = 0,
    operations: u64 = 0,
    rejected: u64 = 0,
    committed: u64 = 0,
    aborted: u64 = 0,
    delivered: u64 = 0,
    faults: [std.meta.tags(Fault).len]u64 = @splat(0),
    queue_peak: usize = 0,
};
pub const Entry = struct { step: u32, tick: u64, phase: Phase, op: []const u8, a: u64, b: u64 };
pub const Context = struct {
    seed: u64,
    rng: Rng,
    profile: Profile,
    phase: Phase = .safety,
    step: u32 = 0,
    tick: u64 = 0,
    counters: Counters = .{},
    failure: ?[]const u8 = null,
    trace: [trace_capacity]Entry = undefined,
    trace_count: usize = 0,
    trace_next: usize = 0,
    digest: std.crypto.hash.sha2.Sha256 = .init(.{}),

    pub fn init(seed: u64, mode: Mode) Context {
        var result: Context = .{ .seed = seed, .rng = .{ .state = seed }, .profile = Profile.init(seed, mode) };
        result.record("seed", seed, version);
        for (result.profile.rates, 0..) |rate, index| result.record("fault_rate", index, rate);
        return result;
    }
    pub fn check(self: *Context, condition: bool, property: []const u8) Error!void {
        self.counters.checks += 1;
        if (!condition) {
            self.failure = property;
            self.record(property, 0, 0);
            return error.Invariant;
        }
    }
    pub fn record(self: *Context, op: []const u8, a: u64, b: u64) void {
        assert(self.trace_next < trace_capacity);
        assert(self.trace_count <= trace_capacity);
        self.trace[self.trace_next] = .{ .step = self.step, .tick = self.tick, .phase = self.phase, .op = op, .a = a, .b = b };
        self.trace_next = (self.trace_next + 1) % trace_capacity;
        self.trace_count = @min(trace_capacity, self.trace_count + 1);
        // Hash canonical fields, never pointers, padding, or undefined storage.
        var bytes: [37]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.step, .little);
        std.mem.writeInt(u64, bytes[4..12], self.tick, .little);
        bytes[12] = @backingInt(self.phase);
        std.mem.writeInt(u64, bytes[13..21], a, .little);
        std.mem.writeInt(u64, bytes[21..29], b, .little);
        std.mem.writeInt(u64, bytes[29..37], op.len, .little);
        self.digest.update(&bytes);
        self.digest.update(op);
    }
    pub fn reject(self: *Context, reason: []const u8) void {
        self.counters.rejected += 1;
        self.record(reason, self.counters.rejected, 0);
    }
    pub fn fault(self: *Context, kind: Fault) bool {
        if (self.phase == .recovery) return false;
        const index = @backingInt(kind);
        if (self.rng.below(100) >= self.profile.rates[index]) return false;
        self.counters.faults[index] += 1;
        self.record(@tagName(kind), self.counters.faults[index], 0);
        return true;
    }
    pub fn advance(self: *Context, delta: u64) Error!void {
        const result = @addWithOverflow(self.tick, delta);
        if (result[1] != 0) return error.ClockExhausted;
        self.tick = result[0];
    }
    pub fn heal(self: *Context) void {
        assert(self.phase == .safety);
        self.phase = .recovery;
        self.record("heal", 0, 0);
    }
    pub fn hash(self: *const Context) [64]u8 {
        var copy = self.digest;
        var bytes: [32]u8 = undefined;
        copy.final(&bytes);
        return std.fmt.bytesToHex(bytes, .lower);
    }
    pub fn writeTrace(self: *const Context, writer: *std.Io.Writer) !void {
        assert(self.trace_count <= trace_capacity);
        const first = (self.trace_next + trace_capacity - self.trace_count) % trace_capacity;
        try writer.writeByte('[');
        for (0..self.trace_count) |offset| {
            if (offset != 0) try writer.writeByte(',');
            try std.json.Stringify.value(self.trace[(first + offset) % trace_capacity], .{}, writer);
        }
        try writer.writeByte(']');
    }
};

pub const Event = struct { at: u64, order: u64 = 0, kind: u8, value: u64, epoch: u64 = 0 };
/// Bounded min-heap. Equal deadlines use a stable submission order.
pub fn Queue(comptime capacity: usize) type {
    comptime assert(capacity > 0);
    return struct {
        const Self = @This();
        events: [capacity]Event = undefined,
        count: usize = 0,
        next_order: u64 = 0,
        peak: usize = 0,
        pub fn push(self: *Self, event: Event) Error!void {
            assert(self.count <= capacity);
            if (self.count == capacity) return error.QueueFull;
            if (self.next_order == std.math.maxInt(u64)) return error.CounterExhausted;
            var value = event;
            value.order = self.next_order;
            self.next_order += 1;
            var index = self.count;
            self.count += 1;
            self.peak = @max(self.peak, self.count);
            while (index > 0) {
                const parent = (index - 1) / 2;
                if (!before(value, self.events[parent])) break;
                self.events[index] = self.events[parent];
                index = parent;
            }
            self.events[index] = value;
            assert(self.count <= capacity);
        }
        pub fn pop(self: *Self) ?Event {
            assert(self.count <= capacity);
            if (self.count == 0) return null;
            const result = self.events[0];
            self.count -= 1;
            if (self.count == 0) return result;
            const last = self.events[self.count];
            var index: usize = 0;
            while (index * 2 + 1 < self.count) {
                var child = index * 2 + 1;
                if (child + 1 < self.count and before(self.events[child + 1], self.events[child])) child += 1;
                if (!before(self.events[child], last)) break;
                self.events[index] = self.events[child];
                index = child;
            }
            self.events[index] = last;
            assert(self.count < capacity);
            return result;
        }
        pub fn peek(self: *const Self) ?Event {
            assert(self.count <= capacity);
            return if (self.count == 0) null else self.events[0];
        }
        fn before(a: Event, b: Event) bool {
            return a.at < b.at or (a.at == b.at and a.order < b.order);
        }
    };
}

test "PRNG stream is specified and ranges exclude their bound" {
    var rng: Rng = .{ .state = 0 };
    try std.testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), rng.next());
    try std.testing.expectEqual(@as(u64, 0x6e789e6aa1b965f4), rng.next());
    for ([_]u64{ 1, 3, 256, 0x8000000000000001, std.math.maxInt(u64) }) |bound| {
        for (0..1000) |_| try std.testing.expect(rng.below(bound) < bound);
    }
}
test "scheduler preserves deadline ordering and bounded rejection state" {
    var queue: Queue(3) = .{};
    try queue.push(.{ .at = 9, .kind = 1, .value = 1 });
    try queue.push(.{ .at = 2, .kind = 1, .value = 2 });
    try queue.push(.{ .at = 2, .kind = 1, .value = 3 });
    try std.testing.expectError(error.QueueFull, queue.push(.{ .at = 0, .kind = 0, .value = 0 }));
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?.value);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?.value);
    try std.testing.expectEqual(@as(u64, 1), queue.pop().?.value);
    try std.testing.expect(queue.pop() == null);
    queue.next_order = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterExhausted, queue.push(.{ .at = 0, .kind = 0, .value = 0 }));
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}
test "checks detect broken models; healing disables faults; clock overflow preserves state" {
    var context = Context.init(7, .swarm);
    try std.testing.expectError(error.Invariant, context.check(false, "deliberate_oracle_failure"));
    try std.testing.expectEqualStrings("deliberate_oracle_failure", context.failure.?);
    context.tick = std.math.maxInt(u64);
    try std.testing.expectError(error.ClockExhausted, context.advance(1));
    try std.testing.expectEqual(std.math.maxInt(u64), context.tick);
    context.heal();
    for (std.meta.tags(Fault)) |fault| try std.testing.expect(!context.fault(fault));
    const hash = context.hash();
    try std.testing.expectEqualSlices(u8, &hash, &context.hash());
}

test "heap agrees with an independent unordered minimum model under churn" {
    var rng: Rng = .{ .state = 91 };
    var queue: Queue(64) = .{};
    var reference: [64]Event = undefined;
    var count: usize = 0;
    var order: u64 = 0;
    for (0..10_000) |_| {
        if (count == 0 or (count < reference.len and rng.below(2) == 0)) {
            const event: Event = .{ .at = rng.below(32), .kind = 1, .value = rng.next() };
            try queue.push(event);
            reference[count] = event;
            reference[count].order = order;
            order += 1;
            count += 1;
        } else {
            var minimum: usize = 0;
            for (reference[0..count], 0..) |event, index| {
                const best = reference[minimum];
                if (event.at < best.at or (event.at == best.at and event.order < best.order)) minimum = index;
            }
            try std.testing.expectEqualDeep(reference[minimum], queue.pop().?);
            count -= 1;
            reference[minimum] = reference[count];
        }
        try std.testing.expectEqual(count, queue.count);
    }
}
