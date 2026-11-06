//! RFC-0087, P5.6 (G1 to G8): the schema of a program's persistent data, and the check of the
//! schema a store keeps against the schema of a program that is about to run on it.
//!
//! **G1, the schema.** For each persistent cell, its store name (S2), the kind of its key and its
//! value type; and each type the cells reach, once: the primitives by name, the structural types
//! (`[]T`, `option(T)`, `map(K, V)`, `tuple(...)`) by their parts, and each persistable struct, class
//! or enum by its package and name (T8), with its fields (name, type, and the canonical JSON of its
//! default constant, E2, when it has one) or its cases and whether it is open. The text is one
//! canonical JSON object, a pure function of the program:
//!
//!   {"schema":1,"cells":[{"cell":NAME,"key":"persistent_key","value":I},...],"types":[T,...]}
//!
//! where each `T` is `{"primitive":"i64"}`, `{"array":I}`, `{"option":I}`, `{"map":[K,V]}`,
//! `{"tuple":[I,...]}`, `{"struct":{"package":P,"name":N,"fields":[{"name":F,"type":I},
//! {"name":F,"type":I,"default":JSON},...]}}`, the same with `"class"`, or
//! `{"enum":{"package":P,"name":N,"open":B,"cases":[C,...]}}`, and every `I` is an index in
//! `types`. A type is listed once (structural types by their shape, named ones by their identity),
//! in the order a walk from the cells in declaration order first meets it. The table is flat, so a
//! schema nests five containers deep whatever its types are: a class that names itself is one
//! entry whose field names its own index, and a reader needs no stack for the types.
//!
//! **G3, the check**, a pure function of two texts (G6): every persistent cell of the old schema is
//! in the new one with the same key kind, and its value type is compatible, by the table of G3.
//! Each refusal names the declaration of the new program that the rule is about (a removed cell
//! names the start of the root file), so the host can locate it, and gives its reason.
//!
//! **Version 0** is the placeholder P5.5 wrote (`{"schema":0,"cells":[...]}`): cells and the kind
//! of their keys, no types. Against it only the rule of the cells is checked; the value types were
//! never recorded, and a store written so is protected by the load's decode alone (G7).
//!
//! A reader trusts no schema it reads from a store: a text larger than `max_bytes`, one that is not
//! the canonical text of what it says, one whose indices leave its table, or whose names repeat
//! where they must not, is no schema. The walk of the check is iterative and memoised on pairs of
//! types, and it gives up (refusing) after more pairs than two schemas that agree can have.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const persist_json = @import("persist_json.zig");
const persistable = @import("persistable.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;

/// The version of the schema this toolchain writes; 0 is P5.5's placeholder.
pub const version: u32 = 1;
/// The largest schema text a store may hold: the description of the largest program a `program`
/// profile compiles, its defaults included, is below it; the writer refuses to describe a program
/// whose schema would not be read back (`error.TooLarge`), so every schema written is readable.
pub const max_bytes: usize = 256 * 1024 * 1024;

// ---- The schema as data ------------------------------------------------------------------------

/// A schema of version 1, as `render` writes it and `parse` reads it.
pub const Schema = struct {
    schema: u32,
    cells: []const Cell,
    types: []const Entry,
};
pub const Cell = struct { cell: []const u8, key: []const u8, value: u32 };
pub const Entry = union(enum) {
    primitive: []const u8,
    array: u32,
    option: u32,
    map: [2]u32,
    tuple: []const u32,
    @"struct": Object,
    class: Object,
    @"enum": Enumeration,
};
pub const Object = struct { package: []const u8, name: []const u8, fields: []const Field };
pub const Field = struct { name: []const u8, type: u32, default: ?[]const u8 = null };
pub const Enumeration = struct { package: []const u8, name: []const u8, open: bool, cases: []const []const u8 };

const primitive_names = [_][]const u8{ "logic", "i64", "float", "string", "char", "char32" };
/// The kind of key of a persistent cell: the one kind there is (K2).
pub const persistent_key = "persistent_key";

/// The canonical text of `schema`.
pub fn render(gpa: Allocator, schema: Schema) Allocator.Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    renderTo(&text.writer, schema) catch return error.OutOfMemory;
    return text.toOwnedSlice();
}

fn renderTo(out: *std.Io.Writer, schema: Schema) std.Io.Writer.Error!void {
    try out.print("{{\"schema\":{d},\"cells\":[", .{schema.schema});
    for (schema.cells, 0..) |cell, index| {
        if (index != 0) try out.writeByte(',');
        try out.writeAll("{\"cell\":");
        try jsonString(out, cell.cell);
        try out.writeAll(",\"key\":");
        try jsonString(out, cell.key);
        try out.print(",\"value\":{d}}}", .{cell.value});
    }
    try out.writeAll("],\"types\":[");
    for (schema.types, 0..) |entry, index| {
        if (index != 0) try out.writeByte(',');
        switch (entry) {
            .primitive => |name| {
                try out.writeAll("{\"primitive\":");
                try jsonString(out, name);
                try out.writeByte('}');
            },
            .array => |element| try out.print("{{\"array\":{d}}}", .{element}),
            .option => |element| try out.print("{{\"option\":{d}}}", .{element}),
            .map => |pair| try out.print("{{\"map\":[{d},{d}]}}", .{ pair[0], pair[1] }),
            .tuple => |elements| {
                try out.writeAll("{\"tuple\":[");
                for (elements, 0..) |element, at| {
                    if (at != 0) try out.writeByte(',');
                    try out.print("{d}", .{element});
                }
                try out.writeAll("]}");
            },
            .@"struct", .class => |object| {
                try out.writeAll(if (entry == .@"struct") "{\"struct\":{\"package\":" else "{\"class\":{\"package\":");
                try jsonString(out, object.package);
                try out.writeAll(",\"name\":");
                try jsonString(out, object.name);
                try out.writeAll(",\"fields\":[");
                for (object.fields, 0..) |field, at| {
                    if (at != 0) try out.writeByte(',');
                    try out.writeAll("{\"name\":");
                    try jsonString(out, field.name);
                    try out.print(",\"type\":{d}", .{field.type});
                    if (field.default) |default| {
                        try out.writeAll(",\"default\":");
                        try jsonString(out, default);
                    }
                    try out.writeByte('}');
                }
                try out.writeAll("]}}");
            },
            .@"enum" => |enumeration| {
                try out.writeAll("{\"enum\":{\"package\":");
                try jsonString(out, enumeration.package);
                try out.writeAll(",\"name\":");
                try jsonString(out, enumeration.name);
                try out.print(",\"open\":{},\"cases\":[", .{enumeration.open});
                for (enumeration.cases, 0..) |case, at| {
                    if (at != 0) try out.writeByte(',');
                    try jsonString(out, case);
                }
                try out.writeAll("]}}");
            },
        }
    }
    try out.writeAll("]}\n");
}

fn jsonString(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(text, .{}, out);
}

// ---- Reading a schema --------------------------------------------------------------------------

/// What a schema text read from a store is.
pub const Parsed = union(enum) {
    /// Version 1.
    full: Schema,
    /// Version 0, P5.5's placeholder: the store names of the cells, whose keys are persistent keys.
    placeholder: []const []const u8,
    /// A version this toolchain does not know.
    later: u64,
    /// Not a schema; the reason.
    invalid: []const u8,
};

const PlaceholderWire = struct {
    schema: u32,
    cells: []const struct { cell: []const u8, key: []const u8 },
};

/// The schema `text` is, read strictly into `arena`: a version-1 text must be the text `render`
/// writes for what it says, with every index inside its table, the names of the cells, of each
/// type's fields and of each enum's cases without repeats, and primitives that exist; a version-0
/// text the text `store.schemaText` writes.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Parsed {
    if (text.len > max_bytes) return .{ .invalid = "the schema is larger than a store's schema can be" };
    const prefix = "{\"schema\":";
    if (!std.mem.startsWith(u8, text, prefix)) return .{ .invalid = "the schema is not one" };
    var end = prefix.len;
    while (end < text.len and end - prefix.len <= 20 and std.ascii.isDigit(text[end])) end += 1;
    const number = std.fmt.parseInt(u64, text[prefix.len..end], 10) catch return .{ .invalid = "the schema is not one" };
    // A canonical number has no leading zero.
    if (end - prefix.len > 1 and text[prefix.len] == '0') return .{ .invalid = "the schema is not one" };
    if (number > version) return .{ .later = number };
    if (number == 0) {
        const wire = std.json.parseFromSliceLeaky(PlaceholderWire, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .invalid = "the schema is not one" },
        };
        const names = try arena.alloc([]const u8, wire.cells.len);
        for (wire.cells, names) |cell, *name| {
            if (!std.mem.eql(u8, cell.key, persistent_key)) return .{ .invalid = "the schema is not one" };
            name.* = cell.cell;
        }
        if (try repeated(arena, names)) return .{ .invalid = "the schema names a cell twice" };
        const again = try store.schemaText(arena, names);
        return if (std.mem.eql(u8, again, text)) .{ .placeholder = names } else .{ .invalid = "the schema is not one" };
    }
    const schema = std.json.parseFromSliceLeaky(Schema, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = "the schema is not one" },
    };
    const again = try render(arena, schema);
    if (!std.mem.eql(u8, again, text)) return .{ .invalid = "the schema is not one" };
    if (try invalidReason(arena, schema)) |reason| return .{ .invalid = reason };
    return .{ .full = schema };
}

/// Why a schema that parses is no schema, or null.
fn invalidReason(arena: Allocator, schema: Schema) Allocator.Error!?[]const u8 {
    const count = schema.types.len;
    const names = try arena.alloc([]const u8, schema.cells.len);
    for (schema.cells, names) |cell, *name| {
        if (cell.value >= count) return "a cell of the schema names no type";
        name.* = cell.cell;
    }
    if (try repeated(arena, names)) return "the schema names a cell twice";
    // Each struct, class or enum once (T8), as `describe` writes it: a named type of one schema then
    // meets one of the other at most, and the check costs what the two texts hold.
    var identities: std.ArrayList([]const u8) = .empty;
    for (schema.types) |entry| switch (entry) {
        .@"struct", .class, .@"enum" => {
            const identity = identityOf(entry);
            try identities.append(arena, try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ identity[0], identity[1] }));
        },
        else => {},
    };
    if (try repeated(arena, identities.items)) return "the schema names a type twice";
    for (schema.types) |entry| switch (entry) {
        .primitive => |name| for (primitive_names) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else return "the schema names a primitive type that does not exist",
        .array, .option => |element| if (element >= count) return "a type of the schema names no type",
        .map => |pair| if (pair[0] >= count or pair[1] >= count) return "a type of the schema names no type",
        .tuple => |elements| for (elements) |element| {
            if (element >= count) return "a type of the schema names no type";
        },
        .@"struct", .class => |object| {
            const fields = try arena.alloc([]const u8, object.fields.len);
            for (object.fields, fields) |field, *name| {
                if (field.type >= count) return "a type of the schema names no type";
                name.* = field.name;
            }
            if (try repeated(arena, fields)) return "a type of the schema names a field twice";
        },
        .@"enum" => |enumeration| if (try repeated(arena, enumeration.cases)) return "an enum of the schema names a case twice",
    };
    return null;
}

/// Whether two of `names` are equal.
fn repeated(arena: Allocator, names: []const []const u8) Allocator.Error!bool {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    try seen.ensureTotalCapacity(arena, @intCast(names.len));
    for (names) |name| {
        if (seen.contains(name)) return true;
        seen.putAssumeCapacity(name, {});
    }
    return false;
}

// ---- G1: describing a program ------------------------------------------------------------------

/// A persistent cell to describe: the span of its name and its value type `V`.
pub const CellInput = struct { name: types.Span, value: types.Type };

/// The schema of a program, and what lets a refusal be located in it: for each cell of the schema,
/// the index of the program's cell (or of the `CellInput`), and for each entry of `types`, the type
/// of the program it describes (for a struct, class or enum, its definition).
pub const Description = struct {
    text: []u8,
    schema: Schema,
    cells: []const u32,
    types: []const types.Type,
};

pub const DescribeError = Allocator.Error || error{
    /// The schema would be larger than `max_bytes`.
    TooLarge,
    /// Two persistable types of the program have one package and name (T8): they could not be told
    /// apart in a store. No program the compiler admits has two.
    Ambiguous,
    /// The program is not one the compiler or an admission would give.
    InvalidProgram,
};

/// G1: the schema of `program` (a `types.Program`), in `arena`.
pub fn describe(arena: Allocator, program: anytype) DescribeError!Description {
    var inputs: std.ArrayList(CellInput) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    for (program.source_cells, 0..) |cell, index| {
        if (cell.keyed != .persistent) continue;
        const value = persistable.persistentValue(cell.value_type, program.definitions) orelse return error.InvalidProgram;
        try inputs.append(arena, .{ .name = cell.name, .value = value });
        try indices.append(arena, @intCast(index));
    }
    var description = try describeCells(max_bytes, arena, persist_json.Catalogue.of(program), inputs.items);
    description.cells = indices.items;
    return description;
}

/// G1 for the cells `cells` of the catalogue `cat`, refusing a text longer than `limit`.
pub fn describeCells(limit: usize, arena: Allocator, cat: persist_json.Catalogue, cells: []const CellInput) DescribeError!Description {
    var writer: Describer = .{ .arena = arena, .cat = cat };
    const schema_cells = try arena.alloc(Cell, cells.len);
    const cell_indices = try arena.alloc(u32, cells.len);
    for (cells, schema_cells, cell_indices, 0..) |cell, *out, *index, at| {
        const name = persist_json.storeName(cat, cell.name);
        const joined = try arena.alloc(u8, name.length());
        var offset: usize = 0;
        for (name.slice()) |part| {
            @memcpy(joined[offset..][0..part.len], part);
            offset += part.len;
        }
        out.* = .{ .cell = joined, .key = persistent_key, .value = try writer.place(try writer.canonical(cell.value)) };
        index.* = @intCast(at);
    }
    const names = try arena.alloc([]const u8, schema_cells.len);
    for (schema_cells, names) |cell, *name| name.* = cell.cell;
    if (try repeated(arena, names)) return error.InvalidProgram;
    // Breadth first: each entry's parts are placed after the entries before it.
    var at: usize = 0;
    while (at < writer.order.items.len) : (at += 1) try writer.entry(at);
    const schema: Schema = .{ .schema = version, .cells = schema_cells, .types = writer.entries.items };
    const text = try render(arena, schema);
    if (text.len > limit) return error.TooLarge;
    const described = try arena.alloc(types.Type, writer.order.items.len);
    for (writer.order.items, described) |node, *out| out.* = writer.nodes.items[node].source;
    return .{ .text = text, .schema = schema, .cells = cell_indices, .types = described };
}

/// A type of the catalogue as the schema has it, once per shape or identity.
const Node = struct {
    shape: union(enum) {
        primitive: u8,
        array: u32,
        option: u32,
        map: [2]u32,
        tuple: []const u32,
        named: void,
    },
    /// The first type of the catalogue met with this shape: for a named type, its definition.
    source: types.Type,
};

const Describer = struct {
    arena: Allocator,
    cat: persist_json.Catalogue,
    /// Canonical nodes, and each catalogue type's node.
    nodes: std.ArrayList(Node) = .empty,
    of_type: std.AutoHashMapUnmanaged(types.Type, u32) = .empty,
    /// Structural nodes by shape, named ones by identity (`package` NUL `name`).
    shapes: std.StringHashMapUnmanaged(u32) = .empty,
    /// The schema's entries in order, and each node's entry.
    order: std.ArrayList(u32) = .empty,
    entry_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    /// The node of `value_type`, made with every structural node below it, by an explicit
    /// depth-first walk: a structural type's parts are made first (they never contain it; a cycle
    /// passes through a named type, whose node needs nothing below it). A type is expanded once,
    /// when it is first on top: its parts not yet made go above it, and when it is on top again
    /// they are all made. A part met again before it is made is made by then too, unless it is
    /// being expanded below: a structural type that contains itself, which admission refuses, and
    /// which is refused here rather than walked forever. Each part is pushed once per edge.
    fn canonical(self: *Describer, value_type: types.Type) DescribeError!u32 {
        if (self.of_type.get(value_type)) |known| return known;
        var stack: std.ArrayList(types.Type) = .empty;
        defer stack.deinit(self.arena);
        var expanded: std.AutoHashMapUnmanaged(types.Type, void) = .empty;
        defer expanded.deinit(self.arena);
        try stack.append(self.arena, value_type);
        while (stack.items.len != 0) {
            const top = stack.items[stack.items.len - 1];
            if (self.of_type.contains(top)) {
                _ = stack.pop();
                continue;
            }
            const parts = try self.partsOf(top);
            if (!expanded.contains(top)) {
                try expanded.put(self.arena, top, {});
                var waiting = false;
                for (parts) |part| if (!self.of_type.contains(part)) {
                    if (expanded.contains(part)) return error.InvalidProgram;
                    try stack.append(self.arena, part);
                    waiting = true;
                };
                if (waiting) continue;
            }
            _ = stack.pop();
            for (parts) |part| if (!self.of_type.contains(part)) return error.InvalidProgram;
            try self.make(top, parts);
        }
        return self.of_type.get(value_type).?;
    }

    /// The parts a structural type's node is made of; none for a primitive or a named type.
    fn partsOf(self: *Describer, value_type: types.Type) DescribeError![]const types.Type {
        if (primitiveIndex(value_type) != null) return &.{};
        const item = catalogue.definition(value_type, self.cat.definitions) orelse return error.InvalidProgram;
        return switch (item) {
            .array, .option => |element| (try self.arena.dupe(types.Type, &.{element})),
            .map => |shape| (try self.arena.dupe(types.Type, &.{ shape.key, shape.value })),
            .tuple => |span| if (span.start <= span.end and span.end <= self.cat.tuple_elements.len) self.cat.tuple_elements[span.start..span.end] else error.InvalidProgram,
            .record => |record| if (record.persistable and record.arguments == null and !record.metatype) &.{} else error.InvalidProgram,
            .class => |class| if (class.persistable and class.arguments == null and !class.is_interface) &.{} else error.InvalidProgram,
            .enumeration => |enumeration| if (enumeration.persistable) &.{} else error.InvalidProgram,
            else => error.InvalidProgram,
        };
    }

    fn make(self: *Describer, value_type: types.Type, parts: []const types.Type) DescribeError!void {
        var key: std.ArrayList(u8) = .empty;
        const node: Node = if (primitiveIndex(value_type)) |index| blk: {
            try key.print(self.arena, "p{d}", .{index});
            break :blk .{ .shape = .{ .primitive = index }, .source = value_type };
        } else switch (catalogue.definition(value_type, self.cat.definitions).?) {
            .array => blk: {
                const element = self.of_type.get(parts[0]).?;
                try key.print(self.arena, "a{d}", .{element});
                break :blk .{ .shape = .{ .array = element }, .source = value_type };
            },
            .option => blk: {
                const element = self.of_type.get(parts[0]).?;
                try key.print(self.arena, "o{d}", .{element});
                break :blk .{ .shape = .{ .option = element }, .source = value_type };
            },
            .map => blk: {
                const pair: [2]u32 = .{ self.of_type.get(parts[0]).?, self.of_type.get(parts[1]).? };
                try key.print(self.arena, "m{d},{d}", .{ pair[0], pair[1] });
                break :blk .{ .shape = .{ .map = pair }, .source = value_type };
            },
            .tuple => blk: {
                const elements = try self.arena.alloc(u32, parts.len);
                try key.append(self.arena, 't');
                for (parts, elements) |part, *element| {
                    element.* = self.of_type.get(part).?;
                    try key.print(self.arena, "{d},", .{element.*});
                }
                break :blk .{ .shape = .{ .tuple = elements }, .source = value_type };
            },
            .record, .class, .enumeration => blk: {
                const package = persist_json.Package.of(self.cat, value_type);
                try key.append(self.arena, 'n');
                for (package.slice()) |part| try key.appendSlice(self.arena, part);
                try key.append(self.arena, 0);
                try key.appendSlice(self.arena, nameOf(self.cat, value_type));
                break :blk .{ .shape = .named, .source = value_type };
            },
            else => unreachable,
        };
        const found = try self.shapes.getOrPut(self.arena, key.items);
        if (found.found_existing) {
            // Two definitions of one identity are one type to a store: it cannot tell them apart.
            if (node.shape == .named and self.nodes.items[found.value_ptr.*].source != value_type) return error.Ambiguous;
        } else {
            found.value_ptr.* = @intCast(self.nodes.items.len);
            try self.nodes.append(self.arena, node);
        }
        try self.of_type.put(self.arena, value_type, found.value_ptr.*);
    }

    /// The entry of `node`, placed at the end of the order when it is met for the first time.
    fn place(self: *Describer, node: u32) DescribeError!u32 {
        const found = try self.entry_of.getOrPut(self.arena, node);
        if (!found.found_existing) {
            found.value_ptr.* = @intCast(self.order.items.len);
            try self.order.append(self.arena, node);
        }
        return found.value_ptr.*;
    }

    /// Writes the entry at `at` of the order, placing its parts.
    fn entry(self: *Describer, at: usize) DescribeError!void {
        const node = self.nodes.items[self.order.items[at]];
        std.debug.assert(self.entries.items.len == at);
        const made: Entry = switch (node.shape) {
            .primitive => |index| .{ .primitive = primitive_names[index] },
            .array => |element| .{ .array = try self.place(element) },
            .option => |element| .{ .option = try self.place(element) },
            .map => |pair| .{ .map = .{ try self.place(pair[0]), try self.place(pair[1]) } },
            .tuple => |elements| blk: {
                const placed = try self.arena.alloc(u32, elements.len);
                for (elements, placed) |element, *out| out.* = try self.place(element);
                break :blk .{ .tuple = placed };
            },
            .named => try self.named(node.source),
        };
        try self.entries.append(self.arena, made);
    }

    fn named(self: *Describer, value_type: types.Type) DescribeError!Entry {
        const package = persist_json.Package.of(self.cat, value_type);
        var joined: std.ArrayList(u8) = .empty;
        for (package.slice()) |part| try joined.appendSlice(self.arena, part);
        const name = nameOf(self.cat, value_type);
        switch (catalogue.definition(value_type, self.cat.definitions).?) {
            .enumeration => |enumeration| {
                if (enumeration.cases.start > enumeration.cases.end or enumeration.cases.end > self.cat.cases.len) return error.InvalidProgram;
                const cases = try self.arena.alloc([]const u8, enumeration.cases.end - enumeration.cases.start);
                for (cases, self.cat.cases[enumeration.cases.start..enumeration.cases.end]) |*out, span| out.* = try self.text(span);
                return .{ .@"enum" = .{ .package = joined.items, .name = name, .open = enumeration.is_open, .cases = cases } };
            },
            inline .record, .class => |object, tag| {
                if (object.fields.start > object.fields.end or object.fields.end > self.cat.fields.len) return error.InvalidProgram;
                const fields = try self.arena.alloc(Field, object.fields.end - object.fields.start);
                for (fields, self.cat.fields[object.fields.start..object.fields.end]) |*out, field| {
                    const default: ?[]const u8 = if (field.constant) |constant| try constantText(self.arena, self.cat, constant, field.value_type) else null;
                    out.* = .{ .name = try self.text(field.name), .type = try self.place(try self.canonical(field.value_type)), .default = default };
                }
                const described: Object = .{ .package = joined.items, .name = name, .fields = fields };
                return if (tag == .record) .{ .@"struct" = described } else .{ .class = described };
            },
            else => unreachable,
        }
    }

    fn text(self: *Describer, span: types.Span) DescribeError![]const u8 {
        if (span.start > span.end or span.end > self.cat.source.len) return error.InvalidProgram;
        return self.cat.source[span.start..span.end];
    }
};

fn primitiveIndex(value_type: types.Type) ?u8 {
    if (value_type == types.Type.char) return 4;
    if (value_type == types.Type.char32) return 5;
    return switch (value_type) {
        .logic => 0,
        .i64 => 1,
        .float => 2,
        .string => 3,
        else => null,
    };
}

fn nameOf(cat: persist_json.Catalogue, value_type: types.Type) []const u8 {
    const span = switch (catalogue.definition(value_type, cat.definitions).?) {
        .record => |record| record.name,
        .class => |class| class.name,
        .enumeration => |enumeration| enumeration.name,
        else => unreachable,
    };
    return cat.source[span.start..span.end];
}

/// The canonical JSON (E2) of the constant `index`, the default of a field of type `field_type`:
/// the text `ToJson` writes for its value, so that two defaults are the same constant exactly when
/// their texts are equal. Written with an explicit stack: a constant nests no deeper than the
/// catalogue has definitions, but that is deeper than a native stack should go.
pub fn constantText(arena: Allocator, cat: persist_json.Catalogue, index: u32, field_type: types.Type) DescribeError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    constantTo(arena, &out.writer, cat, index, field_type) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return out.written();
}

const ConstantFrame = struct { members: types.Span, value_type: types.Type, next: u32 = 0 };

fn constantTo(arena: Allocator, out: *std.Io.Writer, cat: persist_json.Catalogue, index: u32, field_type: types.Type) (DescribeError || std.Io.Writer.Error)!void {
    var stack: std.ArrayList(ConstantFrame) = .empty;
    defer stack.deinit(arena);
    try constantPart(arena, out, cat, &stack, index, field_type);
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const count = frame.members.end - frame.members.start;
        const at = frame.next;
        const item = catalogue.definition(frame.value_type, cat.definitions).?;
        switch (item) {
            .option => |element| {
                if (at == 1) {
                    try out.writeByte('}');
                    _ = stack.pop();
                    continue;
                }
                frame.next = 1;
                try constantPart(arena, out, cat, &stack, cat.constant_members[frame.members.start], element);
            },
            .array => |element| {
                if (at == count) {
                    try out.writeByte(']');
                    _ = stack.pop();
                    continue;
                }
                if (at != 0) try out.writeByte(',');
                frame.next += 1;
                try constantPart(arena, out, cat, &stack, cat.constant_members[frame.members.start + at], element);
            },
            .tuple => |span| {
                if (at == count) {
                    try out.writeByte(']');
                    _ = stack.pop();
                    continue;
                }
                if (at != 0) try out.writeByte(',');
                frame.next += 1;
                try constantPart(arena, out, cat, &stack, cat.constant_members[frame.members.start + at], cat.tuple_elements[span.start + at]);
            },
            .map => |shape| {
                if (at != 0 and at % 2 == 0) try out.writeAll("}}");
                if (at == count) {
                    try out.writeByte(']');
                    _ = stack.pop();
                    continue;
                }
                if (at % 2 == 0) try out.writeAll(if (at == 0) "{\"k\":{\"\":" else ",{\"k\":{\"\":") else try out.writeAll("},\"v\":{\"\":");
                frame.next += 1;
                try constantPart(arena, out, cat, &stack, cat.constant_members[frame.members.start + at], if (at % 2 == 0) shape.key else shape.value);
            },
            .record => |record| {
                if (at == count) {
                    try out.writeByte('}');
                    _ = stack.pop();
                    continue;
                }
                const field = cat.fields[record.fields.start + at];
                try out.writeAll(",\"x_");
                try out.writeAll(cat.source[field.name.start..field.name.end]);
                try out.writeAll("\":");
                frame.next += 1;
                try constantPart(arena, out, cat, &stack, cat.constant_members[frame.members.start + at], field.value_type);
            },
            else => return error.InvalidProgram,
        }
    }
}

/// Writes the constant `index` of `value_type`: a scalar whole, a container's opening (pushed).
fn constantPart(arena: Allocator, out: *std.Io.Writer, cat: persist_json.Catalogue, stack: *std.ArrayList(ConstantFrame), index: u32, value_type: types.Type) (DescribeError || std.Io.Writer.Error)!void {
    if (index >= cat.constants.len) return error.InvalidProgram;
    const constant = cat.constants[index];
    if (constant.value_type != value_type) return error.InvalidProgram;
    if (stack.items.len > cat.definitions.len + 8) return error.InvalidProgram;
    switch (constant.kind) {
        .integer => |value| try out.print("{d}", .{value}),
        .boolean => |value| try out.writeAll(if (value) "true" else "false"),
        // As the encoder writes a float (E2, `types.FloatReport`).
        .floating => |x| if (types.isNan(x)) try out.writeAll("\"NaN\"") else if (std.math.isInf(x)) try out.writeAll(if (x < 0) "\"-Inf\"" else "\"Inf\"") else {
            var buffer: [400]u8 = undefined;
            try out.writeAll(std.fmt.bufPrint(&buffer, "{d}", .{x}) catch unreachable);
        },
        .string => |span| {
            if (span.start > span.end or span.end > cat.strings.len) return error.InvalidProgram;
            try e2String(out, &.{cat.strings[span.start..span.end]});
        },
        .character => |code| try out.print("{d}", .{code}),
        .enumeration => |case| {
            const item = catalogue.definition(value_type, cat.definitions) orelse return error.InvalidProgram;
            if (item != .enumeration) return error.InvalidProgram;
            const cases = item.enumeration.cases;
            if (case >= cases.end - cases.start) return error.InvalidProgram;
            const span = cat.cases[cases.start + case];
            try e2String(out, &.{ nameOf(cat, value_type), "::", cat.source[span.start..span.end] });
        },
        .aggregate => |members| {
            if (members.start > members.end or members.end > cat.constant_members.len) return error.InvalidProgram;
            const count = members.end - members.start;
            const item = catalogue.definition(value_type, cat.definitions) orelse return error.InvalidProgram;
            switch (item) {
                .option => {
                    if (count == 0) return out.writeAll("false");
                    if (count != 1) return error.InvalidProgram;
                    try out.writeAll("{\"\":");
                },
                .array => try out.writeByte('['),
                .tuple => |span| {
                    if (count != span.end - span.start) return error.InvalidProgram;
                    try out.writeByte('[');
                },
                .map => {
                    if (count % 2 != 0) return error.InvalidProgram;
                    try out.writeByte('[');
                },
                .record => |record| {
                    if (count != record.fields.end - record.fields.start) return error.InvalidProgram;
                    const package = persist_json.Package.of(cat, value_type);
                    try out.writeAll("{\"$package_name\":");
                    try e2String(out, package.slice());
                    try out.writeAll(",\"$class_name\":");
                    try e2String(out, &.{nameOf(cat, value_type)});
                },
                else => return error.InvalidProgram,
            }
            try stack.append(arena, .{ .members = members, .value_type = value_type });
        },
    }
}

/// A JSON string of the pieces, joined, escaped as E2 has it: the codec's escapes.
fn e2String(out: *std.Io.Writer, parts: []const []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (parts) |piece| for (piece) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        0x08 => try out.writeAll("\\b"),
        0x09 => try out.writeAll("\\t"),
        0x0A => try out.writeAll("\\n"),
        0x0C => try out.writeAll("\\f"),
        0x0D => try out.writeAll("\\r"),
        else => if (c < 0x20) {
            const hex = "0123456789abcdef";
            try out.writeAll(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
        } else try out.writeByte(c),
    };
    try out.writeByte('"');
}

// ---- G3: the check -----------------------------------------------------------------------------

/// The declaration of the new program a refusal names: the start of the root file (a removed
/// cell), a cell, a type (a removed field or case, a change of the whole type), one of its fields
/// or one of its cases, by their indices in the new schema.
pub const Place = union(enum) {
    root,
    cell: u32,
    entry: u32,
    field: struct { entry: u32, field: u32 },
    case: struct { entry: u32, case: u32 },
};
pub const Refusal = struct { place: Place, reason: []const u8 };

pub const Outcome = struct {
    /// Every refusal; none when the new schema may run on data written under the old one.
    refusals: []const Refusal = &.{},
    /// The old text is no schema this toolchain reads: the reason.
    unreadable: ?[]const u8 = null,
    /// Whether the old schema described types (version 1), or was the placeholder of version 0,
    /// against which only the cells were checked.
    typed: bool = false,
};

/// G3: whether data written under the schema `old_text` may be read by a program whose schema is
/// `new_text`, which must be a version-1 schema (`error.InvalidNew` otherwise). Every allocation is
/// in `arena`.
pub fn check(arena: Allocator, old_text: []const u8, new_text: []const u8) error{ OutOfMemory, InvalidNew }!Outcome {
    const new = switch (try parse(arena, new_text)) {
        .full => |schema| schema,
        else => return error.InvalidNew,
    };
    var old: ?Schema = null;
    var old_cells: []const []const u8 = &.{};
    switch (try parse(arena, old_text)) {
        .full => |schema| {
            const names = try arena.alloc([]const u8, schema.cells.len);
            for (schema.cells, names) |cell, *name| name.* = cell.cell;
            old = schema;
            old_cells = names;
        },
        .placeholder => |names| old_cells = names,
        .later => |number| return .{ .unreadable = try std.fmt.allocPrint(arena, "the schema is of version {d}, written by a later toolchain than this one (version {d})", .{ number, version }) },
        .invalid => |reason| return .{ .unreadable = reason },
    }
    var checker: Checker = .{ .arena = arena, .new = new, .old = old orelse undefined, .budget = (if (old) |held| held.types.len else 0) + new.types.len + 64 };
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    for (new.cells, 0..) |cell, index| try by_name.put(arena, cell.cell, @intCast(index));
    for (old_cells, 0..) |name, index| {
        const found = by_name.get(name) orelse {
            try checker.refuse(.root, "persistent cell {s} removed: the store holds its entries", .{name});
            continue;
        };
        const old_key = if (old) |held| held.cells[index].key else persistent_key;
        if (!std.mem.eql(u8, old_key, new.cells[found].key)) {
            try checker.refuse(.{ .cell = found }, "persistent cell {s} changed its key from {s} to {s}", .{ name, old_key, new.cells[found].key });
            continue;
        }
        if (old) |held| try checker.region(held.cells[index].value, new.cells[found].value, .{ .cell = found });
        if (checker.exhausted) break;
    }
    // The named types the regions met, each pair once: their own rules, and the regions of their
    // fields, which may meet more.
    var next: usize = 0;
    while (next < checker.named.items.len and !checker.exhausted) : (next += 1) try checker.namedPair(checker.named.items[next]);
    return .{ .refusals = checker.refusals.items, .typed = old != null };
}

/// Where in the new program a region of types lies: a cell's value type, or a field's type.
const At = union(enum) { cell: u32, field: struct { entry: u32, field: u32 } };

const Pair = struct { old: u32, new: u32 };
fn pairKey(pair: Pair) u64 {
    return @as(u64, pair.old) << 32 | pair.new;
}

/// The first difference below a pair of structural types.
const Mismatch = struct { old: u32, new: u32 };

const Checker = struct {
    arena: Allocator,
    old: Schema,
    new: Schema,
    refusals: std.ArrayList(Refusal) = .empty,
    /// Structural pairs decided: null when compatible (the named types below them being checked
    /// on their own), else the first difference.
    decided: std.AutoHashMapUnmanaged(u64, ?Mismatch) = .empty,
    /// Named pairs of one identity met, in the order met, each once.
    named: std.ArrayList(Pair) = .empty,
    named_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Pairs two schemas that agree can have: each type of the old one is met with one type of the
    /// new one at most, as the new one lists each shape once. More pairs than that are a refusal.
    budget: usize,
    exhausted: bool = false,

    fn refuse(self: *Checker, place: Place, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try self.refusals.append(self.arena, .{ .place = place, .reason = try std.fmt.allocPrint(self.arena, format, arguments) });
    }

    fn spend(self: *Checker, at: At) Allocator.Error!bool {
        if (self.decided.count() + self.named_seen.count() < self.budget) return true;
        if (!self.exhausted) {
            self.exhausted = true;
            try self.refuse(placeOf(at), "the store's schema differs from the program's in more places than are checked", .{});
        }
        return false;
    }

    /// The region of the old type `old_type` and the new type `new_type` at `at`: their structural
    /// parts compared down to primitives and named types, a refusal at `at` for the first
    /// difference, and the named pairs of one identity queued. The walk keeps the path from the
    /// region's pair to the pair it is at, and each pair is decided once (`decided`). A path is no
    /// longer than the old schema has structural types, unless the old schema's types contain
    /// themselves, which no schema this toolchain writes does: a forged one is refused there.
    fn region(self: *Checker, old_type: u32, new_type: u32, at: At) Allocator.Error!void {
        const root: Pair = .{ .old = old_type, .new = new_type };
        var path: std.ArrayList(Frame) = .empty;
        defer path.deinit(self.arena);
        var result = try self.visit(root, at, &path);
        while (path.items.len != 0) {
            const frame = &path.items[path.items.len - 1];
            if (frame.first == null and frame.next < frame.count) {
                const next = self.part(frame.pair, frame.next);
                frame.next += 1;
                const decided = try self.visit(next, at, &path);
                if (decided == .exhausted) return;
                if (decided == .decided) frame.first = decided.decided;
                continue;
            }
            if (!(try self.spend(at))) return;
            try self.decided.put(self.arena, pairKey(frame.pair), frame.first);
            const first = frame.first;
            _ = path.pop();
            if (path.items.len != 0) {
                const parent = &path.items[path.items.len - 1];
                if (parent.first == null) parent.first = first;
            } else result = .{ .decided = first };
        }
        const difference = switch (result) {
            .decided => |decided| decided orelse return,
            .exhausted => return,
            .pending => unreachable,
        };
        _ = difference;
        var old_text: std.Io.Writer.Allocating = .init(self.arena);
        var new_text: std.Io.Writer.Allocating = .init(self.arena);
        describeType(&old_text.writer, self.old, old_type, 4) catch return error.OutOfMemory;
        describeType(&new_text.writer, self.new, new_type, 4) catch return error.OutOfMemory;
        try self.refuse(placeOf(at), "{s}: the store's {s} is now {s}", .{ try self.where(at), old_text.written(), new_text.written() });
    }

    const Frame = struct { pair: Pair, count: u32, next: u32 = 0, first: ?Mismatch = null };
    const Visit = union(enum) { decided: ?Mismatch, pending, exhausted };

    /// A pair met: decided at once when it was before, when its shapes differ, or when it has no
    /// parts (a primitive, or a named type, which is queued); else put on the path.
    fn visit(self: *Checker, pair: Pair, at: At, path: *std.ArrayList(Frame)) Allocator.Error!Visit {
        if (self.decided.get(pairKey(pair))) |known| return .{ .decided = known };
        const count = self.shallow(pair) orelse {
            if (!(try self.spend(at))) return .exhausted;
            const mismatch: Mismatch = .{ .old = pair.old, .new = pair.new };
            try self.decided.put(self.arena, pairKey(pair), mismatch);
            return .{ .decided = mismatch };
        };
        const old_entry = self.old.types[pair.old];
        if (old_entry == .@"struct" or old_entry == .class or old_entry == .@"enum") {
            if (!(try self.spend(at))) return .exhausted;
            const seen = try self.named_seen.getOrPut(self.arena, pairKey(pair));
            if (!seen.found_existing) try self.named.append(self.arena, pair);
        }
        if (count == 0) {
            if (!(try self.spend(at))) return .exhausted;
            try self.decided.put(self.arena, pairKey(pair), null);
            return .{ .decided = null };
        }
        if (path.items.len >= self.old.types.len) {
            // Only an old schema whose structural types contain themselves gets here.
            const mismatch: Mismatch = .{ .old = pair.old, .new = pair.new };
            return .{ .decided = mismatch };
        }
        try path.append(self.arena, .{ .pair = pair, .count = count });
        return .pending;
    }

    /// How many parts a pair has when its shapes agree (0 for primitives and for named types of one
    /// identity), or null when they differ.
    fn shallow(self: *Checker, pair: Pair) ?u32 {
        const old_entry = self.old.types[pair.old];
        const new_entry = self.new.types[pair.new];
        if (std.meta.activeTag(old_entry) != std.meta.activeTag(new_entry)) return null;
        return switch (old_entry) {
            .primitive => |name| if (std.mem.eql(u8, name, new_entry.primitive)) 0 else null,
            .array, .option => 1,
            .map => 2,
            .tuple => |elements| if (elements.len == new_entry.tuple.len) @intCast(elements.len) else null,
            .@"struct", .class, .@"enum" => if (sameIdentity(old_entry, new_entry)) 0 else null,
        };
    }

    /// The part `index` of a pair whose shapes agree.
    fn part(self: *Checker, pair: Pair, index: u32) Pair {
        const old_entry = self.old.types[pair.old];
        const new_entry = self.new.types[pair.new];
        return switch (old_entry) {
            .array => |element| .{ .old = element, .new = new_entry.array },
            .option => |element| .{ .old = element, .new = new_entry.option },
            .map => |types_of| .{ .old = types_of[index], .new = new_entry.map[index] },
            .tuple => |elements| .{ .old = elements[index], .new = new_entry.tuple[index] },
            else => unreachable,
        };
    }

    fn where(self: *Checker, at: At) Allocator.Error![]const u8 {
        return switch (at) {
            .cell => |cell| std.fmt.allocPrint(self.arena, "persistent cell {s}", .{self.new.cells[cell].cell}),
            .field => |field| std.fmt.allocPrint(self.arena, "field {s} of {f}", .{ objectOf(self.new.types[field.entry]).fields[field.field].name, Named{ .entry = self.new.types[field.entry] } }),
        };
    }

    /// The rules of a pair of named types of one identity and kind (G3's last four rows), and the
    /// regions of the fields both have.
    fn namedPair(self: *Checker, pair: Pair) Allocator.Error!void {
        const old_entry = self.old.types[pair.old];
        const new_entry = self.new.types[pair.new];
        const named: Named = .{ .entry = new_entry };
        switch (old_entry) {
            .@"enum" => |old_enum| {
                const new_enum = new_entry.@"enum";
                if (old_enum.open != new_enum.open) try self.refuse(.{ .entry = pair.new }, "{s} enum {s} is now {s}", .{ if (old_enum.open) "open" else "closed", old_enum.name, if (new_enum.open) "open" else "closed" });
                // An open enum may add cases after the old ones (18:230); a closed one never changes
                // (18:226). Either rule is the stricter one when openness changed too.
                const growable = old_enum.open and new_enum.open;
                const positions = try self.indexOf(old_enum.cases);
                const kept = try self.indexOf(new_enum.cases);
                for (old_enum.cases) |case| if (!kept.contains(case)) try self.refuse(.{ .entry = pair.new }, "enumerator {s} of {f} removed", .{ case, named });
                // The old cases keep their relative order, and a new case of an open enum comes after
                // the last of them; one refusal per case that breaks either, so that an insertion
                // is not also reported as the cases after it moving.
                var last_old: ?usize = null;
                for (new_enum.cases, 0..) |case, index| if (positions.contains(case)) {
                    last_old = index;
                };
                var latest: ?u32 = null;
                for (new_enum.cases, 0..) |case, index| {
                    const place: Place = .{ .case = .{ .entry = pair.new, .case = @intCast(index) } };
                    if (positions.get(case)) |was| {
                        if (latest) |before| if (was < before) try self.refuse(place, "enumerator {s} of {f} moved: the store's enumerators keep their order", .{ case, named });
                        latest = if (latest) |before| @max(before, was) else was;
                    } else if (!growable) {
                        try self.refuse(place, "enumerator {s} added to closed {f}", .{ case, named });
                    } else if (last_old != null and index < last_old.?) {
                        try self.refuse(place, "enumerator {s} inserted before the store's enumerators of {f}: new ones come after the old", .{ case, named });
                    }
                }
            },
            .@"struct", .class => |old_object| {
                const new_object = objectOf(new_entry);
                const is_class = old_entry == .class;
                const positions = try self.indexOf(try fieldNames(self.arena, old_object.fields));
                const kept = try self.indexOf(try fieldNames(self.arena, new_object.fields));
                for (old_object.fields) |field| if (!kept.contains(field.name)) try self.refuse(.{ .entry = pair.new }, "field {s} of {f} removed: the store's entries hold it", .{ field.name, named });
                var last: ?u32 = null;
                for (new_object.fields, 0..) |field, index| {
                    const at: At = .{ .field = .{ .entry = pair.new, .field = @intCast(index) } };
                    const place = placeOf(at);
                    const was = positions.get(field.name) orelse {
                        if (!is_class) {
                            try self.refuse(place, "field {s} added to {f}: a struct's fields never change", .{ field.name, named });
                        } else if (field.default == null) {
                            try self.refuse(place, "field {s} added to {f} without a default: the store's entries lack it", .{ field.name, named });
                        }
                        continue;
                    };
                    if (last) |before| if (was < before) try self.refuse(place, "field {s} of {f} moved: the fields of saved entries keep their order", .{ field.name, named });
                    last = if (last) |before| @max(before, was) else was;
                    const old_field = old_object.fields[was];
                    // A default, once a field has one, never changes (18:131, G4): an entry that
                    // lacks the field reads as it read when the field was added.
                    if (is_class) if (old_field.default) |old_default| {
                        if (field.default) |new_default| {
                            if (!std.mem.eql(u8, old_default, new_default)) try self.refuse(place, "the default of field {s} of {f} changed from {s} to {s}", .{ field.name, named, clip(old_default), clip(new_default) });
                        } else try self.refuse(place, "the default of field {s} of {f} removed", .{ field.name, named });
                    };
                    try self.region(old_field.type, field.type, at);
                    if (self.exhausted) return;
                }
            },
            else => unreachable,
        }
    }

    /// Each name's index.
    fn indexOf(self: *Checker, names: []const []const u8) Allocator.Error!std.StringHashMapUnmanaged(u32) {
        var map: std.StringHashMapUnmanaged(u32) = .empty;
        try map.ensureTotalCapacity(self.arena, @intCast(names.len));
        for (names, 0..) |name, index| map.putAssumeCapacity(name, @intCast(index));
        return map;
    }
};

fn fieldNames(arena: Allocator, fields: []const Field) Allocator.Error![]const []const u8 {
    const names = try arena.alloc([]const u8, fields.len);
    for (fields, names) |field, *name| name.* = field.name;
    return names;
}

fn placeOf(at: At) Place {
    return switch (at) {
        .cell => |cell| .{ .cell = cell },
        .field => |field| .{ .field = .{ .entry = field.entry, .field = field.field } },
    };
}

fn objectOf(entry: Entry) Object {
    return switch (entry) {
        .@"struct", .class => |object| object,
        else => unreachable,
    };
}

fn sameIdentity(a: Entry, b: Entry) bool {
    const left = identityOf(a);
    const right = identityOf(b);
    return std.mem.eql(u8, left[0], right[0]) and std.mem.eql(u8, left[1], right[1]);
}
fn identityOf(entry: Entry) [2][]const u8 {
    return switch (entry) {
        .@"struct", .class => |object| .{ object.package, object.name },
        .@"enum" => |enumeration| .{ enumeration.package, enumeration.name },
        else => unreachable,
    };
}

/// A named type as a reason names it: its kind and name, and its package unless it is `/`.
const Named = struct {
    entry: Entry,
    pub fn format(self: Named, out: *std.Io.Writer) std.Io.Writer.Error!void {
        const identity = identityOf(self.entry);
        try out.print("{s} {s}", .{ switch (self.entry) {
            .@"struct" => "struct",
            .class => "class",
            else => "enum",
        }, identity[1] });
        if (!std.mem.eql(u8, identity[0], "/")) try out.print(" ({s})", .{identity[0]});
    }
};

/// A default as a reason quotes it: its first 40 bytes.
fn clip(text: []const u8) []const u8 {
    return text[0..@min(text.len, 40)];
}

/// A type of `schema` as a reason shows it, in Forbic's spelling, `depth` levels deep at most and
/// eight elements of a tuple.
fn describeType(out: *std.Io.Writer, schema: Schema, index: u32, depth: u32) std.Io.Writer.Error!void {
    const entry = schema.types[index];
    switch (entry) {
        .primitive => |name| return out.writeAll(name),
        .@"struct", .class, .@"enum" => return out.print("{f}", .{Named{ .entry = entry }}),
        else => {},
    }
    if (depth == 0) return out.writeAll("...");
    switch (entry) {
        .array => |element| {
            try out.writeAll("[]");
            try describeType(out, schema, element, depth - 1);
        },
        .option => |element| {
            try out.writeAll("option(");
            try describeType(out, schema, element, depth - 1);
            try out.writeByte(')');
        },
        .map => |pair| {
            try out.writeAll("map(");
            try describeType(out, schema, pair[0], depth - 1);
            try out.writeAll(", ");
            try describeType(out, schema, pair[1], depth - 1);
            try out.writeByte(')');
        },
        .tuple => |elements| {
            try out.writeAll("tuple(");
            for (elements[0..@min(elements.len, 8)], 0..) |element, at| {
                if (at != 0) try out.writeAll(", ");
                try describeType(out, schema, element, depth - 1);
            }
            if (elements.len > 8) try out.print(", ... {d} elements", .{elements.len});
            try out.writeByte(')');
        },
        else => unreachable,
    }
}

// ---- Locating a refusal ------------------------------------------------------------------------

/// The span in `program` of the declaration `place` names in the schema `description` of it.
pub fn located(program: anytype, description: Description, place: Place) types.Span {
    const cat = persist_json.Catalogue.of(program);
    return switch (place) {
        // The start of the root file: in a bundle the last module, which is laid out last.
        .root => if (program.modules.len == 0) .{ .start = 0, .end = 0 } else blk: {
            const start = program.modules[program.modules.len - 1].source.start;
            break :blk .{ .start = start, .end = start };
        },
        .cell => |cell| program.source_cells[description.cells[cell]].name,
        .entry => |entry| typeSpan(cat, description.types[entry]),
        .field => |field| switch (catalogue.definition(description.types[field.entry], cat.definitions).?) {
            .record => |record| cat.fields[record.fields.start + field.field].name,
            .class => |class| cat.fields[class.fields.start + field.field].name,
            else => unreachable,
        },
        .case => |case| blk: {
            const enumeration = catalogue.definition(description.types[case.entry], cat.definitions).?.enumeration;
            break :blk cat.cases[enumeration.cases.start + case.case];
        },
    };
}

fn typeSpan(cat: persist_json.Catalogue, value_type: types.Type) types.Span {
    return switch (catalogue.definition(value_type, cat.definitions).?) {
        .record => |record| record.name,
        .class => |class| class.name,
        .enumeration => |enumeration| enumeration.name,
        else => unreachable,
    };
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn expectRefusals(old: []const u8, new: []const u8, expected: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try check(arena_state.allocator(), old, new);
    const refusals = outcome.refusals;
    if (refusals.len != expected.len) {
        for (refusals) |refusal| std.debug.print("refusal: {s}\n", .{refusal.reason});
        return error.TestUnexpectedResult;
    }
    for (refusals, expected) |refusal, reason| try testing.expectEqualStrings(reason, refusal.reason);
}

const stats_v1 = "{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"stats\",\"fields\":[{\"name\":\"Level\",\"type\":1,\"default\":\"1\"},{\"name\":\"Mode\",\"type\":2}]}},{\"primitive\":\"i64\"},{\"enum\":{\"package\":\"/\",\"name\":\"mode\",\"open\":true,\"cases\":[\"Easy\",\"Hard\"]}}]}\n";

test "a schema text reads back as what it says, and every text that is not one is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = (try parse(arena, stats_v1)).full;
    try testing.expectEqual(@as(usize, 3), parsed.types.len);
    try testing.expectEqualStrings(stats_v1, try render(arena, parsed));
    // The placeholder of P5.5 is version 0: its cells, nothing else.
    const placeholder = try store.schemaText(arena, &.{ ":Stats", "a.forb:M.Data" });
    const names = (try parse(arena, placeholder)).placeholder;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a.forb:M.Data", names[1]);
    try testing.expectEqual(@as(u64, 2), (try parse(arena, "{\"schema\":2,\"cells\":[]}")).later);
    try testing.expectEqual(@as(u64, 99999999999999999), (try parse(arena, "{\"schema\":99999999999999999}")).later);
    // Not schemas: other JSON, other whitespace, member order, numbers or escapes, indices out of
    // the table, repeated names, unknown primitives and members, trailing text, a placeholder with
    // another key, and a text past `max_bytes`.
    const refused = [_][]const u8{
        "",
        "{}",
        "[1]",
        "{\"schema\":01,\"cells\":[],\"types\":[]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[]}",
        "{\"schema\":1, \"cells\":[],\"types\":[]}\n",
        "{\"schema\":1,\"types\":[],\"cells\":[]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[]}\n\n",
        "{\"schema\":1,\"cells\":[],\"types\":[],\"extra\":0}\n",
        "{\"schema\":1,\"cells\":[{\"cell\":\":A\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[]}\n",
        "{\"schema\":1,\"cells\":[{\"cell\":\":A\",\"key\":\"persistent_key\",\"value\":0},{\"cell\":\":A\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"primitive\":\"i64\"}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"primitive\":\"int\"}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"array\":1}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"map\":[0,7]}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"map\":[0]}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"tuple\":[0,3]}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"array\":1e0}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"array\":-1}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"array\":0,\"option\":0}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"set\":0}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"s\",\"fields\":[{\"name\":\"A\",\"type\":0},{\"name\":\"A\",\"type\":0}]}}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"s\",\"fields\":[{\"name\":\"A\",\"type\":0,\"default\":null}]}}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":false,\"cases\":[\"A\",\"A\"]}}]}\n",
        // One identity twice, as a struct and as an enum.
        "{\"schema\":1,\"cells\":[],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"e\",\"fields\":[]}},{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":false,\"cases\":[]}}]}\n",
        "{\"schema\":1,\"cells\":[],\"types\":[{\"enum\":{\"package\":\"\\u002f\",\"name\":\"e\",\"open\":false,\"cases\":[]}}]}\n",
        "{\"schema\":0,\"cells\":[{\"cell\":\":A\",\"key\":\"session\"}]}\n",
        "{\"schema\":0,\"cells\":[{\"cell\":\":A\",\"key\":\"persistent_key\"},{\"cell\":\":A\",\"key\":\"persistent_key\"}]}\n",
        "{\"schema\":0,\"cells\":[]}",
        "{\"schema\":-1,\"cells\":[]}\n",
    };
    for (refused) |text| switch (try parse(arena, text)) {
        .invalid => {},
        else => {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        },
    };
    // Deep: a text nested far deeper than a schema is refused at its first container that is not
    // in a schema's shape, with no stack of its own.
    const deep = try arena.alloc(u8, 1 << 20);
    const head = "{\"schema\":1,\"cells\":[],\"types\":[{\"tuple\":";
    @memcpy(deep[0..head.len], head);
    @memset(deep[head.len..], '[');
    try testing.expect(try parse(arena, deep) == .invalid);
    var tuple_deep: std.ArrayList(u8) = .empty;
    try tuple_deep.appendSlice(arena, "{\"schema\":1,\"cells\":[],\"types\":[{\"tuple\":");
    try tuple_deep.appendNTimes(arena, '[', 100_000);
    try testing.expect(try parse(arena, tuple_deep.items) == .invalid);
    // Oversized: refused by its length before it is read.
    const big = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(big);
    @memcpy(big[0..stats_v1.len], stats_v1);
    try testing.expectEqualStrings("the schema is larger than a store's schema can be", (try parse(arena, big)).invalid);
}

test "the check refuses each change of G3 with its reason, and accepts what G3 allows" {
    // The same schema, and the allowed changes: a class field added with a default, a default
    // added, an enumerator added after the old ones, a cell added.
    try expectRefusals(stats_v1, stats_v1, &.{});
    const grown = "{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"persistent_key\",\"value\":0},{\"cell\":\":New\",\"key\":\"persistent_key\",\"value\":1}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"stats\",\"fields\":[{\"name\":\"Level\",\"type\":1,\"default\":\"1\"},{\"name\":\"Mode\",\"type\":2,\"default\":\"\\\"mode::Easy\\\"\"},{\"name\":\"Seen\",\"type\":1,\"default\":\"0\"}]}},{\"primitive\":\"i64\"},{\"enum\":{\"package\":\"/\",\"name\":\"mode\",\"open\":true,\"cases\":[\"Easy\",\"Hard\",\"Mythic\"]}}]}\n";
    try expectRefusals(stats_v1, grown, &.{});
    // G5: the downgrade lacks what the store's schema has.
    try expectRefusals(grown, stats_v1, &.{
        "persistent cell :New removed: the store holds its entries",
        "field Seen of class stats removed: the store's entries hold it",
        "the default of field Mode of class stats removed",
        "enumerator Mythic of enum mode removed",
    });
    // Refusals of a class and an enum.
    const broken = "{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"stats\",\"fields\":[{\"name\":\"Mode\",\"type\":2},{\"name\":\"Level\",\"type\":1,\"default\":\"2\"},{\"name\":\"Rank\",\"type\":1}]}},{\"primitive\":\"i64\"},{\"enum\":{\"package\":\"/\",\"name\":\"mode\",\"open\":false,\"cases\":[\"Normal\",\"Easy\"]}}]}\n";
    try expectRefusals(stats_v1, broken, &.{
        "field Level of class stats moved: the fields of saved entries keep their order",
        "the default of field Level of class stats changed from 1 to 2",
        "field Rank added to class stats without a default: the store's entries lack it",
        "open enum mode is now closed",
        "enumerator Hard of enum mode removed",
        "enumerator Normal added to closed enum mode",
    });
    // Cases moved among themselves: one refusal per case out of order. An insertion before the old
    // cases of an open enum is one refusal, not one per case after it.
    const open_v1 = "{\"schema\":1,\"cells\":[{\"cell\":\":E\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":true,\"cases\":[\"A\",\"B\",\"C\"]}}]}\n";
    try expectRefusals(open_v1, "{\"schema\":1,\"cells\":[{\"cell\":\":E\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":true,\"cases\":[\"Z\",\"A\",\"B\",\"C\",\"D\"]}}]}\n", &.{
        "enumerator Z inserted before the store's enumerators of enum e: new ones come after the old",
    });
    try expectRefusals(open_v1, "{\"schema\":1,\"cells\":[{\"cell\":\":E\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":true,\"cases\":[\"C\",\"A\",\"B\",\"D\"]}}]}\n", &.{
        "enumerator A of enum e moved: the store's enumerators keep their order",
        "enumerator B of enum e moved: the store's enumerators keep their order",
    });
    try expectRefusals(open_v1, "{\"schema\":1,\"cells\":[{\"cell\":\":E\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"enum\":{\"package\":\"/\",\"name\":\"e\",\"open\":true,\"cases\":[\"A\",\"B\",\"C\",\"D\"]}}]}\n", &.{});
    // A type replaced: a primitive, a renamed type, a struct for a class; a key of another kind.
    const replaced = "{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"stats\",\"fields\":[{\"name\":\"Level\",\"type\":1,\"default\":\"1\"},{\"name\":\"Mode\",\"type\":2}]}},{\"primitive\":\"string\"},{\"enum\":{\"package\":\"/Kit\",\"name\":\"mode\",\"open\":true,\"cases\":[\"Easy\",\"Hard\"]}}]}\n";
    try expectRefusals(stats_v1, replaced, &.{
        "field Level of class stats: the store's i64 is now string",
        "field Mode of class stats: the store's enum mode is now enum mode (/Kit)",
    });
    const rekeyed = "{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"player\",\"value\":0}],\"types\":[{\"primitive\":\"i64\"}]}\n";
    try expectRefusals(stats_v1, rekeyed, &.{"persistent cell :Stats changed its key from persistent_key to player"});
    // Structural types: the same constructors and arity, with compatible parts.
    const pair_v1 = "{\"schema\":1,\"cells\":[{\"cell\":\":P\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"tuple\":[1,2]},{\"primitive\":\"i64\"},{\"map\":[3,4]},{\"primitive\":\"string\"},{\"array\":5},{\"option\":1}]}\n";
    const pair_v2 = "{\"schema\":1,\"cells\":[{\"cell\":\":P\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"tuple\":[1,2,1]},{\"primitive\":\"i64\"},{\"map\":[3,4]},{\"primitive\":\"string\"},{\"array\":5},{\"option\":3}]}\n";
    try expectRefusals(pair_v1, pair_v2, &.{"persistent cell :P: the store's tuple(i64, map(string, []option(i64))) is now tuple(i64, map(string, []option(string)), i64)"});
    try expectRefusals(pair_v1, pair_v1, &.{});
    // A struct never changes; its defaults are not compared, since its entries hold every field.
    const struct_v1 = "{\"schema\":1,\"cells\":[{\"cell\":\":S\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"s\",\"fields\":[{\"name\":\"A\",\"type\":1},{\"name\":\"B\",\"type\":1,\"default\":\"0\"}]}},{\"primitive\":\"i64\"}]}\n";
    const struct_v2 = "{\"schema\":1,\"cells\":[{\"cell\":\":S\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"s\",\"fields\":[{\"name\":\"B\",\"type\":1,\"default\":\"5\"},{\"name\":\"C\",\"type\":1,\"default\":\"0\"}]}},{\"primitive\":\"i64\"}]}\n";
    try expectRefusals(struct_v1, struct_v2, &.{
        "field A of struct s removed: the store's entries hold it",
        "field C added to struct s: a struct's fields never change",
    });
    // Against a placeholder only the cells are checked.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const placeholder = try store.schemaText(arena_state.allocator(), &.{ ":Stats", ":Gone" });
    try expectRefusals(placeholder, stats_v1, &.{"persistent cell :Gone removed: the store holds its entries"});
    // An old text that is no schema, or a later one, is unreadable; a new one that is none is a bug.
    try testing.expectEqualStrings("the schema is not one", (try check(arena_state.allocator(), "{}", stats_v1)).unreadable.?);
    try testing.expect(std.mem.indexOf(u8, (try check(arena_state.allocator(), "{\"schema\":7,\"cells\":[]}", stats_v1)).unreadable.?, "version 7") != null);
    try testing.expectError(error.InvalidNew, check(arena_state.allocator(), stats_v1, placeholder));
}

test "a class that names itself, and types shared by many fields, are checked once each" {
    // `node` holds an option of itself; the check meets the pair once and ends.
    const recursive = "{\"schema\":1,\"cells\":[{\"cell\":\":N\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"node\",\"fields\":[{\"name\":\"Next\",\"type\":1,\"default\":\"false\"}]}},{\"option\":0}]}\n";
    try expectRefusals(recursive, recursive, &.{});
    const recursive_grown = "{\"schema\":1,\"cells\":[{\"cell\":\":N\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"node\",\"fields\":[{\"name\":\"Next\",\"type\":1,\"default\":\"false\"},{\"name\":\"Rank\",\"type\":2}]}},{\"option\":0},{\"primitive\":\"i64\"}]}\n";
    try expectRefusals(recursive, recursive_grown, &.{"field Rank added to class node without a default: the store's entries lack it"});
    // A forged old schema whose structural types contain themselves is refused where it loops.
    const looping = "{\"schema\":1,\"cells\":[{\"cell\":\":N\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"option\":0}]}\n";
    const deep_new = "{\"schema\":1,\"cells\":[{\"cell\":\":N\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"option\":1},{\"option\":2},{\"primitive\":\"i64\"}]}\n";
    try expectRefusals(looping, deep_new, &.{"persistent cell :N: the store's option(option(option(option(...)))) is now option(option(i64))"});
}

test "pairs are bounded: an old schema with repeated types is checked in pairs of its size, and a walk past the budget refuses" {
    // The old schema: a tuple of 10,000 elements, element (i, j) a tuple of an `i64` in the i-th of
    // 100 entries that are alike; the new one the same with element (i, j) in the j-th of 100.
    // Against a new schema that lists each shape once, as `describe` writes one, the pairs are
    // as many as the old schema's types; against one that repeats its shapes, they would be
    // 10,000, and the walk stops at its budget with a refusal.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const side = 100;
    const cells: []const Cell = &.{.{ .cell = ":T", .key = persistent_key, .value = 0 }};
    const build = struct {
        fn of(a: Allocator, by_row: bool, repeated_shapes: bool) ![]u8 {
            var entries: std.ArrayList(Entry) = .empty;
            const elements = try a.alloc(u32, side * side);
            try entries.append(a, .{ .tuple = elements });
            try entries.append(a, .{ .primitive = "i64" });
            const first: u32 = 2;
            for (0..(if (repeated_shapes) side else 1)) |_| try entries.append(a, .{ .tuple = &.{1} });
            for (elements, 0..) |*element, index| {
                const which: u32 = @intCast(if (by_row) index / side else index % side);
                element.* = if (repeated_shapes) first + which else first;
            }
            return render(a, .{ .schema = 1, .cells = cells, .types = entries.items });
        }
    };
    const old = try build.of(arena, true, true);
    try expectRefusals(old, try build.of(arena, false, false), &.{});
    var checked_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer checked_state.deinit();
    const outcome = try check(checked_state.allocator(), old, try build.of(arena, false, true));
    try testing.expectEqual(@as(usize, 1), outcome.refusals.len);
    try testing.expectEqualStrings("the store's schema differs from the program's in more places than are checked", outcome.refusals[0].reason);
}
