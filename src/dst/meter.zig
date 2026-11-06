//! Serialized requested-byte accounting. This does not measure allocator metadata,
//! resident pages, embedded static assets, or allocations made by C libraries.
const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

pub const Meter = struct {
    backing: std.mem.Allocator,
    limit_bytes: usize,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocation_calls: u64 = 0,
    resize_calls: u64 = 0,
    free_calls: u64 = 0,
    failures: u64 = 0,
    /// Independent of saturating telemetry: swallowed allocation failures still
    /// reject an operation after the lifetime counter reaches its ceiling.
    failure_observed: bool = false,
    deny_allocations: bool = false,

    /// The meter must remain at this address until every allocation is released.
    pub fn allocator(meter: *Meter) std.mem.Allocator {
        assert(meter.limit_bytes > 0);
        return .{ .ptr = meter, .vtable = &vtable };
    }

    fn permits(meter: *Meter, previous: usize, requested: usize) bool {
        assert(previous <= meter.live_bytes);
        const retained = meter.live_bytes - previous;
        if (requested <= previous) return true;
        if (meter.deny_allocations or requested > meter.limit_bytes -| retained) {
            meter.failures +|= 1;
            meter.failure_observed = true;
            return false;
        }
        return true;
    }

    fn note(meter: *Meter, previous: usize, requested: usize) void {
        assert(previous <= meter.live_bytes);
        meter.live_bytes = meter.live_bytes - previous + requested;
        meter.peak_bytes = @max(meter.peak_bytes, meter.live_bytes);
        assert(meter.live_bytes <= meter.limit_bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const meter: *Meter = @ptrCast(@alignCast(context));
        meter.allocation_calls +|= 1;
        if (!meter.permits(0, len)) return null;
        const pointer = meter.backing.rawAlloc(len, alignment, ret) orelse {
            meter.failures +|= 1;
            meter.failure_observed = true;
            return null;
        };
        meter.note(0, len);
        return pointer;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) bool {
        const meter: *Meter = @ptrCast(@alignCast(context));
        meter.resize_calls +|= 1;
        if (!meter.permits(memory.len, len)) return false;
        if (!meter.backing.rawResize(memory, alignment, len, ret)) return false;
        meter.note(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) ?[*]u8 {
        const meter: *Meter = @ptrCast(@alignCast(context));
        meter.resize_calls +|= 1;
        if (!meter.permits(memory.len, len)) return null;
        const pointer = meter.backing.rawRemap(memory, alignment, len, ret) orelse return null;
        meter.note(memory.len, len);
        return pointer;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const meter: *Meter = @ptrCast(@alignCast(context));
        assert(memory.len <= meter.live_bytes);
        meter.free_calls +|= 1;
        meter.backing.rawFree(memory, alignment, ret);
        meter.note(memory.len, 0);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "meter enforces requested-byte cap and accounts realloc and teardown" {
    var meter: Meter = .{ .backing = std.testing.allocator, .limit_bytes = 512 };
    const allocator = meter.allocator();
    {
        var first = try allocator.alloc(u8, 200);
        defer allocator.free(first);
        try std.testing.expectEqual(@as(usize, 200), meter.live_bytes);
        try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 400));
        first = try allocator.realloc(first, 300);
        try std.testing.expectEqual(@as(usize, 300), meter.live_bytes);
        meter.deny_allocations = true;
        try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
        if (allocator.resize(first, 100)) first = first[0..100];
        try std.testing.expectEqual(first.len, meter.live_bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), meter.live_bytes);
    try std.testing.expect(meter.peak_bytes <= meter.limit_bytes);
    try std.testing.expect(meter.failures >= 2);
}

test "meter failure detection remains sticky after telemetry saturation" {
    var meter: Meter = .{
        .backing = std.testing.allocator,
        .limit_bytes = 16,
        .failures = std.math.maxInt(u64),
    };
    const allocator = meter.allocator();
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 32));
    try std.testing.expect(meter.failure_observed);
    try std.testing.expectEqual(std.math.maxInt(u64), meter.failures);
    meter.failure_observed = false;
    const memory = try allocator.alloc(u8, 8);
    defer allocator.free(memory);
    try std.testing.expect(!meter.failure_observed);
}
