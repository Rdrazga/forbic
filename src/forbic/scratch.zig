//! Cold-path scratch for admission, replay and reports. These buffers are sized by
//! actual need rather than by a structural capacity, so raising a profile limit does
//! not grow the native stack. Hot execution paths never use this.
const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");

/// Pages straight from the host. The allocator interface fills new memory with a marker in safe
/// builds, which would write, and so commit, every byte of a capacity that is mostly never used.
/// Debug builds keep the marker only at `bootstrap`: there capacities are small and the poison
/// catches stale reads. At `program` a marker would cost every run its whole capacity (each
/// evaluation takes hundreds of MiB of control and frame storage), which made a Linux Debug
/// oracle test take 118 s instead of 3 s (P0.8); those pages stay untouched, as in a release build.
const poison = builtin.mode == .debug and std.mem.eql(u8, profile.active.name, profile.bootstrap.name);

fn pages(bytes: usize, comptime alignment: std.mem.Alignment) ?[*]u8 {
    if (bytes == 0) return @ptrFromInt(alignment.toByteUnits());
    const memory = std.heap.page_allocator.rawAlloc(bytes, alignment, @returnAddress()) orelse return null;
    if (poison) @memset(memory[0..bytes], undefined);
    return memory;
}

fn unpages(memory: []u8, comptime alignment: std.mem.Alignment) void {
    if (memory.len != 0) std.heap.page_allocator.rawFree(memory, alignment, @returnAddress());
}

/// Returns `count` uninitialised elements, or null when the host is out of memory.
pub fn alloc(comptime T: type, count: usize) ?[]T {
    comptime bound(T);
    const memory = pages(@sizeOf(T) * count, .of(T)) orelse return null;
    return @as([*]T, @ptrCast(@alignCast(memory)))[0..count];
}

/// Storage is smaller than this. Zig's self-hosted x86_64 backend, the Linux Debug default, encodes
/// a field's offset as a signed 32-bit displacement, so a field 2 GiB or more into a struct is
/// addressed below it (TASK-0108, P0.8). Storage that would be larger keeps its biggest members
/// behind pointers and names them in `pub const parts`; see `make`. Checked on every target, so
/// a Windows build refuses what a Linux Debug build would miscompile.
pub const max_storage_bytes: usize = 1 << 31;

fn bound(comptime T: type) void {
    // Smaller, not at most: an end address (base + size) may be formed as a displacement too.
    if (@sizeOf(T) >= max_storage_bytes) @compileError(std.fmt.comptimePrint("{s} is {d} bytes; storage is below {d}: keep its large parts behind pointers", .{ @typeName(T), @sizeOf(T), max_storage_bytes }));
}

/// Uninitialised room for one `T`; pair with `initialise` and `release`.
pub fn storage(comptime T: type) error{OutOfMemory}!*T {
    // `release` returns parts, so storage whose parts were never made could not be released.
    if (comptime parts(T).len != 0) @compileError(@typeName(T) ++ " has parts: create it with `make`");
    return room(T);
}

fn room(comptime T: type) error{OutOfMemory}!*T {
    comptime bound(T);
    const memory = pages(@sizeOf(T), .of(T)) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(memory));
}

/// Allocates one default-initialised `T` in place, without a stack temporary.
pub fn create(comptime T: type) ?*T {
    return make(T) catch null;
}

/// Allocates one default-initialised `T` and, when `T` declares `pub const parts = .{ "a", ... }`,
/// one default-initialised part for each named field of type `*P`. `destroy` returns them all.
pub fn make(comptime T: type) error{OutOfMemory}!*T {
    const item = try room(T);
    initialiseFields(T, item);
    const names = comptime parts(T);
    inline for (0..names.len) |made| {
        const name = names[made];
        const Part = @typeInfo(@FieldType(T, name)).pointer.child;
        @field(item, name) = make(Part) catch |err| {
            inline for (0..made) |earlier| destroy(@field(item, names[earlier]));
            unpages(@as([*]u8, @ptrCast(item))[0..@sizeOf(T)], .of(T));
            return err;
        };
    }
    return item;
}

/// The fields `T` names in `pub const parts`: pointers to storage it owns, each named once.
fn parts(comptime T: type) []const []const u8 {
    switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "parts")) {
            var names: [T.parts.len][]const u8 = undefined;
            for (&names, 0..) |*name, index| {
                name.* = T.parts[index];
                if (!@hasField(T, name.*)) @compileError("part " ++ name.* ++ " is not a field of " ++ @typeName(T));
                if (!isPart(@FieldType(T, name.*))) @compileError("part " ++ name.* ++ " of " ++ @typeName(T) ++ " is not a `*T`");
                for (names[0..index]) |earlier| {
                    if (std.mem.eql(u8, earlier, name.*)) @compileError("part " ++ name.* ++ " of " ++ @typeName(T) ++ " is named twice");
                }
            }
            const result = names;
            return &result;
        },
        else => {},
    }
    return &.{};
}

fn isPart(comptime Field: type) bool {
    return switch (@typeInfo(Field)) {
        .pointer => |pointer| pointer.size == .one and !pointer.attrs.@"const",
        else => false,
    };
}

fn named(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |each| {
        if (std.mem.eql(u8, each, name)) return true;
    }
    return false;
}

/// Storage below this size is initialised as one value; above it, field by field.
const whole_value_bytes = 64 * 1024;

/// Gives `target` its default field values in place. `target.* = .{}` builds the whole value
/// first: for a storage struct that is an image of every capacity in the binary and a copy of
/// it at start-up, so capacity would cost space and time whether or not a program uses it.
/// Here a large array is left as it is: it is storage, and its owner sets the part it uses
/// before reading it (a counter beside it says how much is live).
pub fn initialise(target: anytype) void {
    const T = @typeInfo(@TypeOf(target)).pointer.child;
    if (comptime parts(T).len != 0) @compileError(@typeName(T) ++ " has parts: create it with `make`");
    initialiseFields(T, target);
}

fn initialiseFields(comptime T: type, target: *T) void {
    // The compile workspace has hundreds of fields, each checked here at comptime (RFC-0085, I4
    // added one past the default quota).
    @setEvalBranchQuota(64 * 1024);
    // A part has no default: `make` sets it after this.
    if (@sizeOf(T) <= whole_value_bytes and comptime parts(T).len == 0) {
        target.* = .{};
        return;
    }
    const info = @typeInfo(T).@"struct";
    // By index, with the attributes read only at comptime. A capture of `info.field_attrs` is a
    // runtime value in Debug builds, and its default pointer puts that field's default into the
    // static image: for a capacity-sized array, gigabytes of `undefined`. Data past 2 GiB is out
    // of reach of x86_64's 32-bit absolute addresses (a fault in the self-hosted backend, a
    // relocation error with LLVM), so this must never reference a large default.
    inline for (0..info.field_names.len) |index| {
        const Field = info.field_types[index];
        const place = &@field(target, info.field_names[index]);
        // Parts are made only through a pointer `make` knows about: a struct with parts held by
        // value, or a pointer without a default that is not a part (say, `parts` declared without
        // `pub`, which this file cannot see), would be left unset and freed as garbage.
        if (comptime parts(Field).len != 0) @compileError("field " ++ info.field_names[index] ++ " of " ++ @typeName(T) ++ " has parts: hold it behind a pointer named in `parts`");
        if (comptime isPart(Field) and info.field_attrs[index].default_value_ptr == null and !named(parts(T), info.field_names[index]))
            @compileError("pointer " ++ info.field_names[index] ++ " of " ++ @typeName(T) ++ " has no default and is not in `pub const parts`");
        if (@sizeOf(Field) <= whole_value_bytes) {
            if (comptime info.field_attrs[index].defaultValue(Field)) |value| place.* = value;
        } else switch (@typeInfo(Field)) {
            .@"struct" => initialiseFields(Field, place),
            .array => {},
            else => @compileError("large field " ++ info.field_names[index] ++ " of " ++ @typeName(T) ++ " is neither storage nor a struct"),
        }
    }
}

pub fn destroy(item: anytype) void {
    const T = @typeInfo(@TypeOf(item)).pointer.child;
    inline for (comptime parts(T)) |name| destroy(@field(item, name));
    unpages(@as([*]u8, @ptrCast(item))[0..@sizeOf(T)], .of(T));
}

/// Returns what `storage` gave.
pub const release = destroy;

pub fn free(items: anytype) void {
    const T = @typeInfo(@TypeOf(items)).pointer.child;
    unpages(@as([*]u8, @ptrCast(items.ptr))[0 .. @sizeOf(T) * items.len], .of(T));
}

test "initialise sets small defaults in large storage and leaves its arrays alone" {
    const Inner = struct {
        live: u32 = 3,
        cells: [40 * 1024]u32 = undefined,
        marks: [4]u8 = .{ 1, 2, 3, 4 },
    };
    const Outer = struct {
        count: u64 = 7,
        items: [20 * 1024]u64 = undefined,
        inner: Inner = .{},
        flag: ?bool = null,
        tail: [8]u16 = @splat(9),
    };
    const outer = try storage(Outer);
    defer release(outer);
    @memset(std.mem.asBytes(outer), 0x5a);
    initialise(outer);
    try std.testing.expectEqual(@as(u64, 7), outer.count);
    try std.testing.expectEqual(@as(u32, 3), outer.inner.live);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &outer.inner.marks);
    try std.testing.expectEqual(@as(?bool, null), outer.flag);
    try std.testing.expectEqualSlices(u16, &@as([8]u16, @splat(9)), &outer.tail);
    // Large arrays are storage: their owners set what they use, so initialise never writes them.
    try std.testing.expectEqual(@as(u64, 0x5a5a5a5a5a5a5a5a), outer.items[20 * 1024 - 1]);
    try std.testing.expectEqual(@as(u32, 0x5a5a5a5a), outer.inner.cells[0]);
}

test "make gives each named part its own initialised storage and destroy returns them" {
    const Big = struct {
        live: u32 = 5,
        cells: [40 * 1024]u32 = undefined,
    };
    const Inner = struct {
        pub const parts = .{"big"};
        big: *Big,
        count: u8 = 2,
    };
    const Outer = struct {
        pub const parts = .{ "first", "inner" };
        first: *Big,
        inner: *Inner,
        cells: [20 * 1024]u64 = undefined,
        count: u64 = 7,
    };
    try std.testing.expect(@sizeOf(Outer) < 2 * @sizeOf(Big));
    const outer = try make(Outer);
    defer destroy(outer);
    try std.testing.expectEqual(@as(u64, 7), outer.count);
    try std.testing.expectEqual(@as(u32, 5), outer.first.live);
    try std.testing.expectEqual(@as(u8, 2), outer.inner.count);
    try std.testing.expectEqual(@as(u32, 5), outer.inner.big.live);
    try std.testing.expect(@intFromPtr(outer.first) != @intFromPtr(outer.inner.big));
    outer.first.cells[40 * 1024 - 1] = 1;
    outer.inner.big.cells[0] = 2;
    const plain = create(Big).?;
    defer release(plain);
    try std.testing.expectEqual(@as(u32, 5), plain.live);
}

test "scratch allocates and frees exactly sized buffers" {
    const items = alloc(u32, 1000).?;
    defer free(items);
    try std.testing.expectEqual(@as(usize, 1000), items.len);
    @memset(items, 7);
    try std.testing.expectEqual(@as(u32, 7), items[999]);
}
