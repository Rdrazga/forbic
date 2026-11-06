//! Forged IR around `<persistable>` (RFC-0087, P5.2, admission rule 2 and the "Persistable"
//! row of "Forged IR"): every case is refused by both machines' admissions, each in its own
//! code, and by the report replay, which admits the program again before it replays. Each is
//! made from a program that runs by changing one thing: a flag where the rules do not hold, or
//! a constant that is no value of its field's type.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// Persistable types of every kind, with a default of every constant kind, and beside them
/// the types a flag must not reach: a struct of a type that is not persistable, a struct with
/// a function field, an instantiation, a class that is not final, one with a superclass, one
/// with an interface, one with a `var` field, an interface.
const base =
    \\e := enum<persistable>{A, B}
    \\s := struct<persistable>{I:i64 = 1, F:float = 0.5, S:string = "雪a", C:char32 = 0u1F600, U:char = 'u', E:e = e.B, O:option(i64) = option{2}, A:[]i64 = array{1, 2}, T:tuple(i64, logic) = tuple{1, true}, M:map(i64, string) = map{1 => "x", 2 => "y"}, L:logic = true}
    \\c := class<final><persistable>{N:i64 = 3}
    \\plain := struct{V:i64 = 0}
    \\fr := struct{G:function(tuple(i64), i64)}
    \\box[t:type] := struct{V:t}
    \\B:box[i64] = box[i64]{V := 1}
    \\open_class := class{X:i64 = 0}
    \\sub := class<final>(open_class){}
    \\iface := interface{}
    \\impl := class<final>(iface){N:i64 = 0}
    \\vc := class<final>{var N:i64 = 0}
    \\pc := class<final>{P:plain = plain{}}
    \\D:s = s{}
    \\K:c = c{}
    \\V:i64 = D.I + K.N
;

const Copy = struct {
    definitions: []types.Definition,
    fields: []types.Field,
    constants: std.ArrayList(types.Constant),
    members: std.ArrayList(u32),
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .definitions = try allocator.dupe(types.Definition, p.definitions),
            .fields = try allocator.dupe(types.Field, p.fields),
            .constants = .empty,
            .members = .empty,
            .program = p,
            .original = p,
        };
        try copy.constants.appendSlice(allocator, p.constants);
        try copy.members.appendSlice(allocator, p.constant_members);
        copy.point();
        return copy;
    }
    fn point(self: *Copy) void {
        self.program.definitions = self.definitions;
        self.program.fields = self.fields;
        self.program.constants = self.constants.items;
        self.program.constant_members = self.members.items;
    }
    fn free(self: *Copy) void {
        self.members.deinit(allocator);
        self.constants.deinit(allocator);
        allocator.free(self.fields);
        allocator.free(self.definitions);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.definitions, self.original.definitions);
        @memcpy(self.fields, self.original.fields);
        self.constants.items.len = self.original.constants.len;
        @memcpy(self.constants.items, self.original.constants);
        self.members.items.len = self.original.constant_members.len;
        @memcpy(self.members.items, self.original.constant_members);
        self.program = self.original;
        self.point();
    }
    /// The index of the definition named `name`; with `instance`, the instantiation of it.
    fn named(self: *const Copy, name: []const u8, instance: bool) usize {
        for (self.original.definitions, 0..) |item, index| if (catalogue.declaredName(item)) |span| if (std.mem.eql(u8, span.text(self.original.source), name) and (catalogue.typeArguments(item) != null) == instance) return index;
        unreachable;
    }
    /// The index in the fields of field `field` of the struct or class `name`.
    fn field(self: *const Copy, name: []const u8, field_name: []const u8) usize {
        const span = switch (self.original.definitions[self.named(name, false)]) {
            .record => |record| record.fields,
            .class => |class| class.fields,
            else => unreachable,
        };
        for (self.original.fields[span.start..span.end], span.start..) |f, index| if (std.mem.eql(u8, f.name.text(self.original.source), field_name)) return index;
        unreachable;
    }
    /// The constant of field `field_name` of `name`.
    fn constant(self: *const Copy, name: []const u8, field_name: []const u8) u32 {
        return self.original.fields[self.field(name, field_name)].constant.?;
    }
    fn flag(self: *Copy, name: []const u8, instance: bool) void {
        switch (self.definitions[self.named(name, instance)]) {
            .record => |*record| record.persistable = true,
            .class => |*class| class.persistable = true,
            .enumeration => |*enumeration| enumeration.persistable = true,
            else => unreachable,
        }
    }
};

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    harness.invalid(h, forged) catch |err| {
        std.debug.print("admitted: {any} {any}\n", .{ forged.constants, forged.constant_members });
        return err;
    };
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

/// Admitted and run by both machines, on a harness of its own so that the run whose report the
/// replay reads stays as it was.
fn admitted(p: types.Program) !void {
    const h = try harness.create();
    defer scratch.release(h);
    const result = try h.run(p, fuel);
    if (result == .failed) std.debug.print("refused: {t}\n", .{result.failed.code});
    try std.testing.expect(result == .ok);
}

test "persistable forged rows: flags where the rules do not hold are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    // Each type the flag must not reach, flagged.
    for ([_][]const u8{ "fr", "open_class", "sub", "impl", "vc", "pc", "iface" }) |name| {
        c.flag(name, false);
        try refused(h, run, c.program);
        c.restore();
    }
    // An instantiation of a parametric struct.
    c.flag("box", true);
    try refused(h, run, c.program);
    c.restore();
    // A unique, an abstract class; a `var` and a live-only field of a flagged class.
    c.definitions[c.named("c", false)].class.is_unique = true;
    try refused(h, run, c.program);
    c.restore();
    c.fields[c.field("c", "N")].is_var = true;
    try refused(h, run, c.program);
    c.restore();
    c.fields[c.field("c", "N")].live_only = true;
    try refused(h, run, c.program);
    c.restore();
    // A flagged struct that is a metatype.
    c.definitions[c.named("s", false)].record.metatype = true;
    try refused(h, run, c.program);
    c.restore();
    // A flagged struct's field of a type that is not persistable, by the definition that
    // holds it: the flag taken from the enum it names.
    c.definitions[c.named("e", false)].enumeration.persistable = false;
    try refused(h, run, c.program);
    c.restore();
    try admitted(p);
}

test "persistable forged rows: constants that are no value of their field's type are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const integer = c.constant("s", "I");
    const float = c.constant("s", "F");
    const string = c.constant("s", "S");
    const char32 = c.constant("s", "C");
    const char = c.constant("s", "U");
    const enumerated = c.constant("s", "E");
    const option = c.constant("s", "O");
    const array = c.constant("s", "A");
    const tuple = c.constant("s", "T");
    const map = c.constant("s", "M");
    // A field names a constant of another type, one past the table, or one of a field outside
    // every flagged type.
    c.fields[c.field("s", "I")].constant = string;
    try refused(h, run, c.program);
    c.restore();
    c.fields[c.field("s", "I")].constant = @intCast(c.constants.items.len);
    try refused(h, run, c.program);
    c.restore();
    c.fields[c.field("plain", "V")].constant = integer;
    try refused(h, run, c.program);
    c.restore();
    // A scalar of a kind its type does not have.
    c.constants.items[integer].kind = .{ .floating = 1.0 };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[float].kind = .{ .integer = 1 };
    try refused(h, run, c.program);
    c.restore();
    // A NaN other than the one canonical NaN.
    c.constants.items[float].kind = .{ .floating = @bitCast(@as(u64, 0x7ff8_0000_0000_0001)) };
    try refused(h, run, c.program);
    c.restore();
    // A string that is no span of the strings, or that splits a character.
    const text = c.constants.items[string].kind.string;
    c.constants.items[string].kind = .{ .string = .{ .start = text.start + 1, .end = text.end } };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[string].kind = .{ .string = .{ .start = text.start, .end = @intCast(p.strings.len + 1) } };
    try refused(h, run, c.program);
    c.restore();
    // A character outside its type, a surrogate, a case its enum lacks.
    c.constants.items[char].kind = .{ .character = 256 };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[char32].kind = .{ .character = 0xD800 };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[char32].kind = .{ .character = 0x110000 };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[enumerated].kind = .{ .enumeration = 2 };
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[enumerated].kind = .{ .character = 1 };
    try refused(h, run, c.program);
    c.restore();
    // Members outside the static part, a member that is not earlier, two members of an option,
    // an element of another type, a tuple and a struct of another arity, a map of an odd count.
    const elements = c.constants.items[array].kind.aggregate;
    c.constants.items[array].kind = .{ .aggregate = .{ .start = elements.start, .end = @intCast(c.members.items.len + 1) } };
    try refused(h, run, c.program);
    c.restore();
    c.members.items[elements.start] = array;
    try refused(h, run, c.program);
    c.restore();
    c.constants.items[option].kind = .{ .aggregate = elements };
    try refused(h, run, c.program);
    c.restore();
    c.members.items[elements.start] = string;
    try refused(h, run, c.program);
    c.restore();
    const pair = c.constants.items[tuple].kind.aggregate;
    c.constants.items[tuple].kind = .{ .aggregate = .{ .start = pair.start, .end = pair.end - 1 } };
    try refused(h, run, c.program);
    c.restore();
    const entries = c.constants.items[map].kind.aggregate;
    c.constants.items[map].kind = .{ .aggregate = .{ .start = entries.start, .end = entries.end - 1 } };
    try refused(h, run, c.program);
    c.restore();
    // A map with two equal keys.
    c.members.items[entries.start + 2] = c.members.items[entries.start];
    try refused(h, run, c.program);
    c.restore();
    // A constant of a class: an instance has no literal. And one of a type that is not
    // persistable, held nowhere.
    try c.constants.append(allocator, .{ .value_type = @fromBackingInt(@intCast(c.named("c", false) + catalogue.builtin_count)), .kind = .{ .aggregate = .{ .start = 0, .end = 1 } } });
    c.point();
    try refused(h, run, c.program);
    c.restore();
    try c.constants.append(allocator, .{ .value_type = @fromBackingInt(@intCast(c.named("plain", false) + catalogue.builtin_count)), .kind = .{ .aggregate = .{ .start = 0, .end = 1 } } });
    c.point();
    try refused(h, run, c.program);
    c.restore();
    // An unused constant of a persistable type, and a field without its constant, are what
    // a compiler could have written: admitted.
    try c.constants.append(allocator, .{ .value_type = .i64, .kind = .{ .integer = 9 } });
    c.point();
    try admitted(c.program);
    c.restore();
    c.fields[c.field("s", "I")].constant = null;
    try admitted(c.program);
    c.restore();
    // The table of a program whose types are all without the flag is empty. (Compiled last:
    // the copy above shares the compiler's storage.)
    var plain = try Copy.of(try h.compile("plain := struct{V:i64 = 0}\nV:i64 = plain{}.V"));
    defer plain.free();
    try plain.constants.append(allocator, .{ .value_type = .i64, .kind = .{ .integer = 0 } });
    plain.point();
    try harness.invalid(h, plain.program);
    plain.restore();
    plain.fields[0].constant = 0;
    try harness.invalid(h, plain.program);
    plain.restore();
    try admitted(plain.program);
}
