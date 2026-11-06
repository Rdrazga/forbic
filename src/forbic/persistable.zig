//! `<persistable>` types (RFC-0087, P5.2): which types of a catalogue are persistable (T2), and
//! which field-default constants are equal (T5). Both are pure functions of IR that the
//! compiler and both machines' admissions ask, as they ask `comparableTypes`; each admission
//! applies the rules of admission rule 2 in its own code (`validPersistable` in the evaluator,
//! `verifyPersistable` in the VM).
//!
//! Persistability is nominal for structs, classes and enums: one of them is persistable when it
//! carries the flag, which an admission accepts only on a type that keeps the rules. A
//! structural type (an array, an option, a tuple, a map) is persistable when its parts are,
//! and its parts are earlier definitions, so one pass in definition order decides every type
//! with no recursion. A class may name itself or a later class: those are nominal, decided by
//! their flag alone.
const std = @import("std");
const types = @import("types.zig");
const scratch = @import("scratch.zig");

const builtin_count: u16 = 4;

/// Whether `value_type` is persistable, given `persistable` for the definitions before
/// `upto` (a structural definition at or after it is not yet decided, and is not).
fn persistableBefore(value_type: types.Type, definitions: []const types.Definition, persistable: []const bool, upto: usize) bool {
    if (value_type.isCharacter()) return true;
    if (value_type == types.Type.any) return false;
    const id = @backingInt(value_type);
    if (id < builtin_count) return true;
    const index = id - builtin_count;
    if (index >= definitions.len) return false;
    return switch (definitions[index]) {
        .record => |record| record.persistable and record.arguments == null and !record.metatype,
        .class => |class| class.persistable and class.arguments == null and !class.is_interface,
        .enumeration => |enumeration| enumeration.persistable,
        .array, .option, .tuple, .map => index < upto and persistable[index],
        else => false,
    };
}

/// For each definition, whether it is a persistable type (T2). `output` has one entry per
/// definition. Assumes a catalogue in which every structural definition names earlier ones,
/// which `validateAllIn` admits; on any other it answers false for what it cannot decide.
pub fn persistableTypes(definitions: []const types.Definition, tuple_elements: []const types.Type, output: []bool) void {
    std.debug.assert(output.len == definitions.len);
    for (definitions, 0..) |item, index| {
        output[index] = switch (item) {
            .record, .class, .enumeration => persistableBefore(@fromBackingInt(@intCast(index + builtin_count)), definitions, output, index),
            .array => |element| persistableBefore(element, definitions, output, index),
            .option => |element| persistableBefore(element, definitions, output, index),
            .map => |shape| persistableBefore(shape.key, definitions, output, index) and persistableBefore(shape.value, definitions, output, index),
            .tuple => |span| tuple: {
                if (span.start > span.end or span.end > tuple_elements.len) break :tuple false;
                for (tuple_elements[span.start..span.end]) |element| if (!persistableBefore(element, definitions, output, index)) break :tuple false;
                break :tuple true;
            },
            else => false,
        };
    }
}

/// Whether `value_type` is persistable, with `persistable` what `persistableTypes` says of the
/// catalogue.
pub fn isPersistable(value_type: types.Type, definitions: []const types.Definition, persistable: []const bool) bool {
    std.debug.assert(persistable.len == definitions.len);
    return persistableBefore(value_type, definitions, persistable, definitions.len);
}

/// RFC-0087, P5.5 (W7, admission rule 4): whether the value type of every persistent cell is
/// persistable. A program without a persistent cell allocates nothing.
pub fn persistentCellsValid(definitions: []const types.Definition, tuple_elements: []const types.Type, cells: []const types.SourceCell) error{OutOfMemory}!bool {
    const any = for (cells) |cell| {
        if (cell.keyed == .persistent) break true;
    } else false;
    if (!any) return true;
    const kinds = scratch.alloc(bool, definitions.len) orelse return error.OutOfMemory;
    defer scratch.free(kinds);
    persistableTypes(definitions, tuple_elements, kinds);
    for (cells) |cell| {
        if (cell.keyed != .persistent) continue;
        const shape = persistentValue(cell.value_type, definitions) orelse return false;
        if (!isPersistable(shape, definitions, kinds)) return false;
    }
    return true;
}

/// The value type of the `weak_map(K, V)` a cell has, or null for any other type.
pub fn persistentValue(cell_type: types.Type, definitions: []const types.Definition) ?types.Type {
    const id = @backingInt(cell_type);
    if (id < builtin_count or id - builtin_count >= definitions.len) return null;
    const item = definitions[id - builtin_count];
    return if (item == .weak_map) item.weak_map.value else null;
}

/// RFC-0087, P5.3: for each definition, whether a value of it can hold an instance: a class,
/// and an array, option, tuple, map or struct of a type that can. One pass in definition order
/// decides every type, as for `persistableTypes`: a struct's fields and a structural type's parts
/// are earlier definitions (`validateAllIn` admits that), and a class is decided by its kind.
pub fn instanceTypes(definitions: []const types.Definition, tuple_elements: []const types.Type, fields: []const types.Field, output: []bool) void {
    std.debug.assert(output.len == definitions.len);
    for (definitions, 0..) |item, index| {
        output[index] = switch (item) {
            .class => true,
            .array => |element| instanceBefore(element, definitions, output, index),
            .option => |element| instanceBefore(element, definitions, output, index),
            .map => |shape| instanceBefore(shape.key, definitions, output, index) or instanceBefore(shape.value, definitions, output, index),
            .weak_map => |shape| instanceBefore(shape.key, definitions, output, index) or instanceBefore(shape.value, definitions, output, index),
            .tuple => |span| tuple: {
                if (span.start > span.end or span.end > tuple_elements.len) break :tuple true;
                for (tuple_elements[span.start..span.end]) |element| if (instanceBefore(element, definitions, output, index)) break :tuple true;
                break :tuple false;
            },
            .record => |record| record: {
                if (record.fields.start > record.fields.end or record.fields.end > fields.len) break :record true;
                for (fields[record.fields.start..record.fields.end]) |field| if (instanceBefore(field.value_type, definitions, output, index)) break :record true;
                break :record false;
            },
            else => false,
        };
    }
}

/// Whether a value of `value_type` can hold an instance, given `instances` for the definitions
/// before `upto`. What is not yet decided is taken to hold one: only a catalogue that names a
/// later part could ask, and admission refuses it.
fn instanceBefore(value_type: types.Type, definitions: []const types.Definition, instances: []const bool, upto: usize) bool {
    if (value_type.isCharacter() or value_type == types.Type.any) return false;
    const id = @backingInt(value_type);
    if (id < builtin_count) return false;
    const index = id - builtin_count;
    if (index >= definitions.len) return true;
    if (definitions[index] == .class) return true;
    return index >= upto or instances[index];
}

/// What admission asks of the type of a JSON node (RFC-0087, P5.3, admission rule 6): whether it
/// is persistable, and whether it reaches a class, which makes an encode read and a decode
/// allocate. Worked out once per program that holds a JSON node; the empty facts admit none.
pub const JsonFacts = struct {
    ready: bool = false,
    persistable: []bool = &.{},
    instances: []bool = &.{},

    pub fn of(definitions: []const types.Definition, tuple_elements: []const types.Type, fields: []const types.Field) error{OutOfMemory}!JsonFacts {
        const kinds = scratch.alloc(bool, definitions.len) orelse return error.OutOfMemory;
        const instances = scratch.alloc(bool, definitions.len) orelse {
            scratch.free(kinds);
            return error.OutOfMemory;
        };
        persistableTypes(definitions, tuple_elements, kinds);
        instanceTypes(definitions, tuple_elements, fields, instances);
        return .{ .ready = true, .persistable = kinds, .instances = instances };
    }
    pub fn release(self: JsonFacts) void {
        if (!self.ready) return;
        scratch.free(self.persistable);
        scratch.free(self.instances);
    }
    /// Whether `value_type` is persistable; never for facts made for another catalogue.
    pub fn persistableType(self: JsonFacts, value_type: types.Type, definitions: []const types.Definition) bool {
        if (!self.ready or self.persistable.len != definitions.len) return false;
        return isPersistable(value_type, definitions, self.persistable);
    }
    /// Whether a value of `value_type` can hold an instance.
    pub fn reachesClass(self: JsonFacts, value_type: types.Type, definitions: []const types.Definition) bool {
        if (!self.ready or self.instances.len != definitions.len) return true;
        return instanceBefore(value_type, definitions, self.instances, definitions.len);
    }
};

/// The bits a float key compares by: one zero and one NaN, as `==` has them (RFC-0065).
fn keyBits(value: f64) u64 {
    if (value == 0) return 0;
    return @bitCast(types.canonicalFloat(value));
}

/// The room `equalityClasses` needs for `count` constants: two words each.
pub fn workSize(count: usize) usize {
    return 2 * count;
}

/// What sorts one level of constants: a constant's type, kind and value, an aggregate's value
/// being its length and its members' classes in order, which the levels below have given.
const Order = struct {
    constants: []const types.Constant,
    members: []const u32,
    strings: []const u8,
    classes: []const u32,

    fn order(self: Order, left: u32, right: u32) std.math.Order {
        const a = self.constants[left];
        const b = self.constants[right];
        const by_type = std.math.order(@backingInt(a.value_type), @backingInt(b.value_type));
        if (by_type != .eq) return by_type;
        const by_kind = std.math.order(@backingInt(std.meta.activeTag(a.kind)), @backingInt(std.meta.activeTag(b.kind)));
        if (by_kind != .eq) return by_kind;
        return switch (a.kind) {
            .integer => |value| std.math.order(value, b.kind.integer),
            .boolean => |value| std.math.order(@intFromBool(value), @intFromBool(b.kind.boolean)),
            .floating => |value| std.math.order(keyBits(value), keyBits(b.kind.floating)),
            .string => |span| std.mem.order(u8, self.strings[span.start..span.end], self.strings[b.kind.string.start..b.kind.string.end]),
            .enumeration => |value| std.math.order(value, b.kind.enumeration),
            .character => |value| std.math.order(value, b.kind.character),
            .aggregate => |span| aggregate: {
                const other = b.kind.aggregate;
                const by_length = std.math.order(span.end - span.start, other.end - other.start);
                if (by_length != .eq) break :aggregate by_length;
                for (self.members[span.start..span.end], self.members[other.start..other.end]) |x, y| {
                    const by_member = std.math.order(self.classes[x], self.classes[y]);
                    if (by_member != .eq) break :aggregate by_member;
                }
                break :aggregate .eq;
            },
        };
    }
    fn less(self: Order, left: u32, right: u32) bool {
        return self.order(left, right) == .lt;
    }
};

/// For each constant, a class: two constants are equal by the language's `==` (RFC-0065:
/// structural, floats with one zero and one NaN, maps in order) exactly when their classes
/// are, and every class is the index of one of its constants. Equal constants have the same
/// depth (a scalar 0, an aggregate one more than its deepest member), so the constants are
/// sorted level by level, shallowest first: when a level is sorted every member's class is
/// known, two aggregates are equal when their lengths and their members' classes are, and the
/// runs of equal constants in the sorted level are the classes. The cost is a sort per level,
/// O(n log n) comparisons in all, each bounded by what it compares, whatever the values: no
/// hash a program could aim at. The caller has admitted spans, member order and string spans;
/// `work` has `workSize(constants.len)` words and `classes` one per constant.
pub fn equalityClasses(constants: []const types.Constant, members: []const u32, strings: []const u8, classes: []u32, work: []u32) void {
    std.debug.assert(classes.len == constants.len and work.len == workSize(constants.len));
    const depths = work[0..constants.len];
    const order = work[constants.len..];
    var deepest: u32 = 0;
    for (constants, depths) |constant, *depth| {
        depth.* = 0;
        if (constant.kind == .aggregate) {
            const span = constant.kind.aggregate;
            for (members[span.start..span.end]) |member| depth.* = @max(depth.*, depths[member]);
            depth.* += 1;
        }
        deepest = @max(deepest, depth.*);
    }
    // The constants by depth, so that each level is one run of `order`.
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    std.sort.pdq(u32, order, @as([]const u32, depths), struct {
        fn less(by: []const u32, left: u32, right: u32) bool {
            return by[left] < by[right];
        }
    }.less);
    var begin: usize = 0;
    while (begin < order.len) {
        var placed = begin + 1;
        while (placed < order.len and depths[order[placed]] == depths[order[begin]]) placed += 1;
        const run = order[begin..placed];
        const context: Order = .{ .constants = constants, .members = members, .strings = strings, .classes = classes };
        std.sort.pdq(u32, run, context, Order.less);
        var at: usize = 0;
        while (at < run.len) {
            var same = at + 1;
            while (same < run.len and context.order(run[at], run[same]) == .eq) same += 1;
            for (run[at..same]) |index| classes[index] = run[at];
            at = same;
        }
        begin = placed;
    }
    std.debug.assert(deepest == 0 or depths[order[order.len - 1]] == deepest);
}

test "persistable types are decided in one pass: nominal by flag, structural by parts" {
    const definitions = [_]types.Definition{
        .{ .record = .{ .name = .{ .start = 0, .end = 1 }, .fields = .{ .start = 0, .end = 0 }, .is_public = false, .persistable = true } },
        .{ .array = @fromBackingInt(4) },
        .{ .record = .{ .name = .{ .start = 0, .end = 1 }, .fields = .{ .start = 0, .end = 0 }, .is_public = false } },
        .{ .option = @fromBackingInt(6) },
        .{ .tuple = .{ .start = 0, .end = 2 } },
        .rational,
        .{ .map = .{ .key = .string, .value = @fromBackingInt(9) } },
    };
    const elements = [_]types.Type{ .i64, types.Type.char32 };
    var output: [definitions.len]bool = undefined;
    persistableTypes(&definitions, &elements, &output);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false, true, false, false }, &output);
    try std.testing.expect(isPersistable(.float, &definitions, &output));
    try std.testing.expect(!isPersistable(types.Type.any, &definitions, &output));
    try std.testing.expect(!isPersistable(@fromBackingInt(200), &definitions, &output));
}

test "constants equal by the language's equality share a class, whatever their sign of zero" {
    const strings = "abab";
    const constants = [_]types.Constant{
        .{ .value_type = .float, .kind = .{ .floating = 0.0 } },
        .{ .value_type = .float, .kind = .{ .floating = -0.0 } },
        .{ .value_type = .string, .kind = .{ .string = .{ .start = 0, .end = 2 } } },
        .{ .value_type = .string, .kind = .{ .string = .{ .start = 2, .end = 4 } } },
        .{ .value_type = @fromBackingInt(4), .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
        .{ .value_type = @fromBackingInt(4), .kind = .{ .aggregate = .{ .start = 2, .end = 4 } } },
        .{ .value_type = .i64, .kind = .{ .integer = 0 } },
        .{ .value_type = @fromBackingInt(4), .kind = .{ .aggregate = .{ .start = 4, .end = 6 } } },
    };
    const members = [_]u32{ 0, 2, 1, 3, 2, 0 };
    var classes: [constants.len]u32 = undefined;
    var work: [2 * constants.len]u32 = undefined;
    equalityClasses(&constants, &members, strings, &classes, &work);
    try std.testing.expectEqual(classes[0], classes[1]);
    try std.testing.expectEqual(classes[2], classes[3]);
    try std.testing.expectEqual(classes[4], classes[5]);
    const distinct = [_]usize{ 0, 2, 4, 6, 7 };
    for (distinct, 0..) |a, position| for (distinct[position + 1 ..]) |b| try std.testing.expect(classes[a] != classes[b]);
    // A class is one of its own constants.
    for (classes, 0..) |class, index| try std.testing.expectEqual(classes[index], classes[class]);
}

test "equality classes match a model over thousands of integers and options of them" {
    // Many integers and nested options of them: the classes match a plain model.
    const count = 4096;
    var constants: [2 * count]types.Constant = undefined;
    var members: [count]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(87);
    for (0..count) |index| {
        constants[index] = .{ .value_type = .i64, .kind = .{ .integer = prng.random().intRangeAtMost(i64, 0, 300) } };
        members[index] = @intCast(index);
        constants[count + index] = .{ .value_type = @fromBackingInt(4), .kind = .{ .aggregate = .{ .start = @intCast(index), .end = @intCast(index + 1) } } };
    }
    var classes: [2 * count]u32 = undefined;
    var work: [4 * count]u32 = undefined;
    equalityClasses(&constants, &members, "", &classes, &work);
    for (0..count) |a| for ([_]usize{ (a * 7919) % count, (a + 1) % count }) |b| {
        const equal = constants[a].kind.integer == constants[b].kind.integer;
        try std.testing.expectEqual(equal, classes[a] == classes[b]);
        try std.testing.expectEqual(equal, classes[count + a] == classes[count + b]);
    };
}
