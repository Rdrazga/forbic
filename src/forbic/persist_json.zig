//! RFC-0087, P5.3 (E1 to E10): the JSON of persistable values, written by one encoder and read
//! by one strict decoder, which both machines and the report replay run over pools of their own
//! (E8). It is a leaf library, as the map-key index and the float format are: each caller lends
//! it what it holds a run in (the member pool, the string pool, the instances), and the codec
//! decides every byte written, every member laid out and every instance built, in one order, so
//! two machines that agree on a value agree on its text and on what decoding it builds.
//!
//! Values are walked with an explicit stack of frames, never on the native stack (E6). The
//! encoder counts the JSON containers open around the value it writes, the decoder those open
//! in the text it reads, and both stop at `json_depth`: a value nested deeper is the fatal
//! `json_depth_limit` for the encoder and a text nested deeper is a decode that fails. As the
//! encoder writes an option and every map entry with the containers the decoder reads, a text
//! the encoder wrote is never too deep to read back.
//!
//! Decoding lays a value out as the machines lay out a literal: the members of each part before
//! the part, so the value's own members come last. While a container is read, the values of its
//! parts wait at the top of the member pool, which the decoder fills downwards from the end of
//! the room it is lent: the parts that wait are members the result will hold, so the decoder
//! needs no room beyond the result's but for the fields of the class instances it is reading,
//! which an instance holds in its cells and not in the pool. An instance's fields are first laid
//! out as members, as a struct's are, and then copied into its cells: the replay, which builds
//! no instance of the run, reads what the run's instance holds from those members. A decode
//! that fails builds nothing: the members, strings and instances it had made are dropped.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const run_strings = @import("run_strings.zig");
const keys = @import("map_keys.zig");
const modules = @import("modules.zig");

/// The most JSON containers (arrays and objects) open at once in a text the codec writes or
/// reads. One number in every capacity profile (E6), so a text written under one is read under
/// another.
pub const json_depth: u32 = 65536;
/// The stack holds the containers of a text and, above them, the default constants a decode is
/// filling in, whose depth admission does not bound by `json_depth`.
const frame_capacity: usize = 2 * json_depth;

/// `Host` is the error of a host operation (reading a field, building an instance), whose cause
/// the host keeps. `InvalidValue` is a value that does not have its type's form, which an
/// admitted program never hands the codec.
pub const Error = error{ WorkLimit, StringLimit, AggregateLimit, DepthLimit, ScratchUnavailable, InvalidValue, Host };

/// What the codec reads of a program: its catalogue, the field defaults of its persistable types
/// (`constants`) and the names of its files and nested modules (T8).
pub const Catalogue = struct {
    source: []const u8,
    strings: []const u8,
    definitions: []const types.Definition,
    fields: []const types.Field,
    cases: []const types.Span,
    tuple_elements: []const types.Type,
    paths: []const u8,
    modules: []const types.Module,
    nested: []const types.NestedModule,
    constants: []const types.Constant,
    constant_members: []const u32,

    pub fn of(program: anytype) Catalogue {
        return .{
            .source = program.source,
            .strings = program.strings,
            .definitions = program.definitions,
            .fields = program.fields,
            .cases = program.cases,
            .tuple_elements = program.tuple_elements,
            .paths = program.paths,
            .modules = program.modules,
            .nested = program.nested,
            .constants = program.constants,
            .constant_members = program.constant_members,
        };
    }
    fn text(self: Catalogue, span: types.Span) []const u8 {
        return self.source[span.start..span.end];
    }
};

/// The member pool lent to a decode: `slots` is indexed by member number, `count` members are in
/// use, and the decode may use every slot from `count.*` to `slots.len`.
pub const Members = struct { slots: []types.Value, count: *usize };

const Kind = enum(u8) { array, tuple, map, entry, option, wrap, record, class, constant };
const Phase = enum(u8) { open, awaiting, after, closing };

/// One open container. The encoder uses `value`, `value_type`, `next` and `open`; the decoder
/// every field but `value`.
const Frame = struct {
    kind: Kind,
    phase: Phase = .open,
    value_type: types.Type,
    /// Encoder: the part to write next. Decoder: the field the next out-of-order member is
    /// looked for from, the next missing field, or the next member of a constant.
    next: u32 = 0,
    /// JSON containers open around this one, itself included.
    open: u32 = 0,
    /// Decoder: where the frame's parts wait. For an array, a tuple, a map and a constant, the
    /// slot above the first part (parts are pushed below it); for the others, the first slot of
    /// the block reserved for the parts, in order.
    base: u32 = 0,
    /// Decoder: the parts pushed so far, or for a record, a class and an entry the slot the
    /// value being read goes to.
    count: u32 = 0,
    target: u32 = 0,
    /// Decoder: an entry's keys seen (`k` 1, `v` 2), an object's metadata seen.
    seen: u8 = 0,
    /// Decoder: for a record or a class, the first of its fields' bits in `Stack.marks`, set
    /// for the fields the text has given.
    marks: u32 = 0,
    value: types.Value = undefined,
};

/// The codec's stack, made with `scratch.storage` at a run's first encode or decode and given
/// back at its end, so a run that uses no JSON reserves nothing for it (E6).
pub const Stack = struct {
    frames: [frame_capacity]Frame,
    /// One bit per field of each object open in a text, which `json_depth` and `record_fields`
    /// bound.
    marks: [mark_words]u64,
};
const mark_words: usize = (@as(usize, json_depth) * types.limits.record_fields + 63) / 64;

comptime {
    // A default constant is made of earlier constants of earlier types, so it nests no deeper
    // than the catalogue has definitions: with a text as deep as it may be, its frames fit.
    std.debug.assert(@as(usize, json_depth) + types.limits.user_types <= frame_capacity);
}

const Shape = union(enum) {
    logic,
    integer,
    floating,
    string,
    character: types.Type,
    array: types.Type,
    option: types.Type,
    tuple: types.Span,
    map: types.Map,
    record: types.Span,
    class: types.Span,
    enumeration: types.Enumeration,
};

fn shapeOf(cat: Catalogue, value_type: types.Type) Error!Shape {
    if (value_type.isCharacter()) return .{ .character = value_type };
    switch (value_type) {
        .logic => return .logic,
        .i64 => return .integer,
        .float => return .floating,
        .string => return .string,
        else => {},
    }
    const item = catalogue.definition(value_type, cat.definitions) orelse return error.InvalidValue;
    return switch (item) {
        .array => |element| .{ .array = element },
        .option => |element| .{ .option = element },
        .tuple => |span| if (span.start <= span.end and span.end <= cat.tuple_elements.len) .{ .tuple = span } else error.InvalidValue,
        .map => |shape| .{ .map = shape },
        .record => |record| if (record.persistable and record.fields.start <= record.fields.end and record.fields.end <= cat.fields.len) .{ .record = record.fields } else error.InvalidValue,
        .class => |class| if (class.persistable and class.fields.start <= class.fields.end and class.fields.end <= cat.fields.len) .{ .class = class.fields } else error.InvalidValue,
        .enumeration => |enumeration| if (enumeration.cases.start <= enumeration.cases.end and enumeration.cases.end <= cat.cases.len) .{ .enumeration = enumeration } else error.InvalidValue,
        else => error.InvalidValue,
    };
}

fn typeName(cat: Catalogue, value_type: types.Type) []const u8 {
    return switch (catalogue.definition(value_type, cat.definitions).?) {
        .record => |record| cat.text(record.name),
        .class => |class| cat.text(class.name),
        .enumeration => |enumeration| cat.text(enumeration.name),
        else => unreachable,
    };
}
fn typeNameSpan(cat: Catalogue, value_type: types.Type) types.Span {
    return switch (catalogue.definition(value_type, cat.definitions).?) {
        .record => |record| record.name,
        .class => |class| class.name,
        .enumeration => |enumeration| enumeration.name,
        else => unreachable,
    };
}

/// The package name of a type (T8) as the pieces it is written in: `/`, the bundle path of the
/// file that declares it, and `/` and each nested module from the file to the type, outermost
/// first. A single file has no path, so its root's package is `/` and a module `M` in it is
/// `/M`. A module of a folder tree is named by a module path, which begins with `/` itself, so
/// its package is that path (`/d/A`, `/d/A/M` for a module `M` of it), never `//d/A` (c1-4).
pub const Package = struct {
    parts: [2 + 2 * (types.limits.module_depth + 1)][]const u8 = undefined,
    count: usize = 0,

    fn add(self: *Package, part: []const u8) void {
        self.parts[self.count] = part;
        self.count += 1;
    }
    pub fn of(cat: Catalogue, value_type: types.Type) Package {
        const name = typeNameSpan(cat, value_type);
        var package: Package = .{};
        var file_path: ?[]const u8 = null;
        if (cat.modules.len != 0) if (modules.owner(name, cat.modules)) |file| {
            const path = cat.modules[file].path;
            if (path.start <= path.end and path.end <= cat.paths.len and path.end > path.start) file_path = cat.paths[path.start..path.end];
        };
        if (file_path == null or file_path.?[0] != '/') package.add("/");
        if (file_path) |path| package.add(path);
        var named = file_path != null;
        // The nested modules from the type outwards, then written outermost first.
        var chain: [types.limits.module_depth + 1]u32 = undefined;
        var length: usize = 0;
        var at = modules.innermost(name, cat.nested);
        while (at) |module| {
            // Both admissions refuse nesting deeper than `module_depth` (`validateNested`
            // rebuilds the table from the source, which nests no deeper), so the chain fits.
            std.debug.assert(length < chain.len);
            chain[length] = module;
            length += 1;
            const parent = cat.nested[module].parent;
            at = if (parent == types.no_parent or parent >= cat.nested.len) null else parent;
        }
        while (length != 0) {
            length -= 1;
            if (named) package.add("/");
            package.add(cat.text(cat.nested[chain[length]].name));
            named = true;
        }
        return package;
    }
    pub fn slice(self: *const Package) []const []const u8 {
        return self.parts[0..self.count];
    }
};

fn spend(remaining: *u64, amount: u64) error{WorkLimit}!void {
    if (amount > remaining.*) return error.WorkLimit;
    remaining.* -= amount;
}

// --- encoding ---------------------------------------------------------------------------------

/// The canonical text of `value` (E1, E2), appended to `pool`: no whitespace, members in
/// declaration order, metadata first. `members` is the pool the value's aggregates name;
/// `host.field(object, index)` reads a field of an instance. Charges 2 and one per 8 bytes
/// written, as it writes them; the caller has charged the node.
pub fn encode(cat: Catalogue, host: anytype, members: []const types.Value, value_type: types.Type, value: types.Value, pool: *run_strings.Pool, stack: *Stack, remaining: *u64) Error![]const u8 {
    return encodeWithin(json_depth, cat, host, members, value_type, value, pool, stack, remaining);
}

/// `encode` with `limit` open containers at most instead of `json_depth`: for the tests of the
/// depth rule, which cannot build values 65,536 containers deep at every size.
pub fn encodeWithin(limit: u32, cat: Catalogue, host: anytype, members: []const types.Value, value_type: types.Type, value: types.Value, pool: *run_strings.Pool, stack: *Stack, remaining: *u64) Error![]const u8 {
    std.debug.assert(limit <= json_depth);
    try spend(remaining, 2);
    std.debug.assert(pool.used >= pool.base);
    var encoder: Encoder(@TypeOf(host)) = .{ .cat = cat, .host = host, .members = members, .pool = pool, .start = pool.used - pool.base, .remaining = remaining, .frames = &stack.frames, .limit = limit };
    if (encoder.start > pool.tail.len) return error.StringLimit;
    try encoder.part(value_type, value, 0);
    while (encoder.depth != 0) try encoder.proceed();
    pool.used += encoder.written;
    return pool.tail[encoder.start .. encoder.start + encoder.written];
}

/// RFC-0087, P5.5 (S2): the store name of the persistent cell declared at `name`, as the pieces
/// it is written in: the bundle path of the file (empty in a single file), `:`, then each nested
/// module from the file to the cell, outermost first, and the cell's name, joined by `.`:
/// `progress.forb:Stats`, `kit/save.forb:Slots.Data`, `:Stats`.
pub const StoreName = struct {
    parts: [3 + 2 * (types.limits.module_depth + 1)][]const u8 = undefined,
    count: usize = 0,

    fn add(self: *StoreName, part: []const u8) void {
        self.parts[self.count] = part;
        self.count += 1;
    }
    pub fn slice(self: *const StoreName) []const []const u8 {
        return self.parts[0..self.count];
    }
    pub fn length(self: *const StoreName) usize {
        var total: usize = 0;
        for (self.slice()) |part| total += part.len;
        return total;
    }
    /// Whether the name is exactly `text`.
    pub fn eql(self: *const StoreName, text: []const u8) bool {
        var at: usize = 0;
        for (self.slice()) |part| {
            if (part.len > text.len - at or !std.mem.eql(u8, part, text[at..][0..part.len])) return false;
            at += part.len;
        }
        return at == text.len;
    }
};

pub fn storeName(cat: Catalogue, name: types.Span) StoreName {
    var result: StoreName = .{};
    var path: []const u8 = "";
    if (cat.modules.len != 0) if (modules.owner(name, cat.modules)) |file| {
        const found = cat.modules[file].path;
        if (found.start <= found.end and found.end <= cat.paths.len) path = cat.paths[found.start..found.end];
    };
    result.add(path);
    result.add(":");
    var chain: [types.limits.module_depth + 1]u32 = undefined;
    var depth: usize = 0;
    var at = modules.innermost(name, cat.nested);
    while (at) |module| {
        // As `Package.of`: nesting is no deeper than `module_depth`.
        std.debug.assert(depth < chain.len);
        chain[depth] = module;
        depth += 1;
        const parent = cat.nested[module].parent;
        at = if (parent == types.no_parent or parent >= cat.nested.len) null else parent;
    }
    while (depth != 0) {
        depth -= 1;
        result.add(cat.text(cat.nested[chain[depth]].name));
        result.add(".");
    }
    result.add(cat.text(name));
    return result;
}

fn putTail(tail: []u8, at: usize, bytes: []const u8) Error!usize {
    if (at > tail.len or bytes.len > tail.len - at) return error.StringLimit;
    @memcpy(tail[at..][0..bytes.len], bytes);
    return at + bytes.len;
}

/// A JSON string of the pieces, joined and escaped as E2 has it, written at `at` of `tail`.
fn putString(tail: []u8, start: usize, parts: []const []const u8) Error!usize {
    var at = try putTail(tail, start, "\"");
    for (parts) |text| {
        var run: usize = 0;
        for (text, 0..) |c, index| {
            const escape: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x09 => "\\t",
                0x0A => "\\n",
                0x0C => "\\f",
                0x0D => "\\r",
                else => null,
            };
            if (escape == null and c >= 0x20) continue;
            at = try putTail(tail, at, text[run..index]);
            if (escape) |sequence| at = try putTail(tail, at, sequence) else {
                const hex = "0123456789abcdef";
                at = try putTail(tail, at, &.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
            }
            run = index + 1;
        }
        at = try putTail(tail, at, text[run..]);
    }
    return putTail(tail, at, "\"");
}

/// RFC-0087, P5.5 (S5): the text of the store action a `set` of an entry of a persistent cell
/// prepares: `{"cell":"S2-NAME","key":"KEY-NAME","value":TEXT}` where `TEXT` is `encode` of the
/// value, appended to `pool` as one string. Charges 1 for the names, then what `encode` charges.
/// `cell` is the span of the cell's name (`storeName`); `key` the granted name.
pub fn encodeStoreAction(cat: Catalogue, host: anytype, members: []const types.Value, value_type: types.Type, value: types.Value, cell: types.Span, key: []const u8, pool: *run_strings.Pool, stack: *Stack, remaining: *u64) Error![]const u8 {
    try spend(remaining, 1);
    std.debug.assert(pool.used >= pool.base);
    const start = pool.used - pool.base;
    const saved = pool.used;
    errdefer pool.used = saved;
    const name = storeName(cat, cell);
    var at = try putTail(pool.tail, start, "{\"cell\":");
    at = try putString(pool.tail, at, name.slice());
    at = try putTail(pool.tail, at, ",\"key\":");
    at = try putString(pool.tail, at, &.{key});
    at = try putTail(pool.tail, at, ",\"value\":");
    pool.used = pool.base + at;
    const json = try encode(cat, host, members, value_type, value, pool, stack, remaining);
    // `encode` appends at the pool's end, which is where the prefix ends.
    std.debug.assert(json.ptr == pool.tail.ptr + at);
    at += json.len;
    at = try putTail(pool.tail, at, "}");
    pool.used = pool.base + at;
    return pool.tail[start..at];
}

fn Encoder(comptime Host: type) type {
    return struct {
        const Self = @This();
        cat: Catalogue,
        host: Host,
        members: []const types.Value,
        pool: *run_strings.Pool,
        start: usize,
        written: usize = 0,
        remaining: *u64,
        frames: []Frame,
        depth: usize = 0,
        limit: u32,

        fn write(self: *Self, bytes: []const u8) Error!void {
            const room = self.pool.tail.len - self.start;
            if (bytes.len > room - self.written) return error.StringLimit;
            const before = self.written;
            @memcpy(self.pool.tail[self.start + self.written ..][0..bytes.len], bytes);
            self.written += bytes.len;
            try spend(self.remaining, self.written / 8 - before / 8);
        }
        fn byte(self: *Self, value: u8) Error!void {
            return self.write(&.{value});
        }
        /// The JSON string of the pieces, joined, escaped as E2 has it.
        fn string(self: *Self, parts: []const []const u8) Error!void {
            try self.byte('"');
            for (parts) |text| {
                var run: usize = 0;
                for (text, 0..) |c, at| {
                    const escape: ?[]const u8 = switch (c) {
                        '"' => "\\\"",
                        '\\' => "\\\\",
                        0x08 => "\\b",
                        0x09 => "\\t",
                        0x0A => "\\n",
                        0x0C => "\\f",
                        0x0D => "\\r",
                        else => null,
                    };
                    if (escape == null and c >= 0x20) continue;
                    try self.write(text[run..at]);
                    if (escape) |sequence| try self.write(sequence) else {
                        const hex = "0123456789abcdef";
                        try self.write(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                    }
                    run = at + 1;
                }
                try self.write(text[run..]);
            }
            try self.byte('"');
        }
        fn aggregate(value: types.Value) Error!types.Span {
            if (value != .aggregate) return error.InvalidValue;
            return value.aggregate.elements;
        }
        fn member(self: *Self, span: types.Span, index: u32) Error!types.Value {
            if (span.start > span.end or span.end > self.members.len or index >= span.end - span.start) return error.InvalidValue;
            return self.members[span.start + index];
        }

        /// Writes `value` of `value_type`, a scalar at once and a container's opening, with
        /// `open` containers already around it.
        fn part(self: *Self, value_type: types.Type, value: types.Value, open: u32) Error!void {
            var buffer: [400]u8 = undefined;
            switch (try shapeOf(self.cat, value_type)) {
                .logic => {
                    if (value != .boolean) return error.InvalidValue;
                    try self.write(if (value.boolean) "true" else "false");
                },
                .integer => {
                    if (value != .integer) return error.InvalidValue;
                    try self.write(std.fmt.bufPrint(&buffer, "{d}", .{value.integer}) catch unreachable);
                },
                .floating => {
                    if (value != .floating) return error.InvalidValue;
                    const x = value.floating;
                    // As the value report writes a float (`types.FloatReport`), the one rule for
                    // every JSON the toolchain writes (Q5).
                    if (types.isNan(x)) try self.write("\"NaN\"") else if (std.math.isInf(x)) try self.write(if (x < 0) "\"-Inf\"" else "\"Inf\"") else try self.write(std.fmt.bufPrint(&buffer, "{d}", .{x}) catch unreachable);
                },
                .string => {
                    if (value != .string) return error.InvalidValue;
                    try self.string(&.{value.string});
                },
                .character => |character| {
                    if (value != .enumeration or value.enumeration.value_type != character) return error.InvalidValue;
                    try self.write(std.fmt.bufPrint(&buffer, "{d}", .{value.enumeration.index}) catch unreachable);
                },
                .enumeration => |enumeration| {
                    if (value != .enumeration or value.enumeration.value_type != value_type) return error.InvalidValue;
                    const index = value.enumeration.index;
                    if (index >= enumeration.cases.end - enumeration.cases.start) return error.InvalidValue;
                    try self.string(&.{ self.cat.text(enumeration.name), "::", self.cat.text(self.cat.cases[enumeration.cases.start + index]) });
                },
                .option => {
                    const span = try aggregate(value);
                    if (span.start == span.end) return self.write("false");
                    try self.push(value_type, value, open);
                    try self.write("{\"\":");
                },
                .array, .tuple, .map => {
                    _ = try aggregate(value);
                    try self.push(value_type, value, open);
                    try self.byte('[');
                },
                .record => {
                    _ = try aggregate(value);
                    try self.push(value_type, value, open);
                    try self.metadata(value_type);
                },
                .class => {
                    if (value != .object or value.object.value_type != value_type) return error.InvalidValue;
                    try self.push(value_type, value, open);
                    try self.metadata(value_type);
                },
            }
        }
        fn metadata(self: *Self, value_type: types.Type) Error!void {
            const package = Package.of(self.cat, value_type);
            try self.write("{\"$package_name\":");
            try self.string(package.slice());
            try self.write(",\"$class_name\":");
            try self.string(&.{typeName(self.cat, value_type)});
        }
        fn push(self: *Self, value_type: types.Type, value: types.Value, open: u32) Error!void {
            if (open >= self.limit or self.depth == self.frames.len) return error.DepthLimit;
            self.frames[self.depth] = .{ .kind = .array, .value_type = value_type, .value = value, .open = open + 1 };
            self.depth += 1;
        }

        /// Writes the next part of the innermost open container, or closes it.
        fn proceed(self: *Self) Error!void {
            const frame = &self.frames[self.depth - 1];
            const index = frame.next;
            switch (try shapeOf(self.cat, frame.value_type)) {
                .array => |element| {
                    const span = try aggregate(frame.value);
                    if (index == span.end - span.start) return self.close("]");
                    if (index != 0) try self.byte(',');
                    frame.next += 1;
                    try self.part(element, try self.member(span, index), frame.open);
                },
                .tuple => |elements| {
                    const span = try aggregate(frame.value);
                    if (span.end - span.start != elements.end - elements.start) return error.InvalidValue;
                    if (index == span.end - span.start) return self.close("]");
                    if (index != 0) try self.byte(',');
                    frame.next += 1;
                    try self.part(self.cat.tuple_elements[elements.start + index], try self.member(span, index), frame.open);
                },
                .option => |element| {
                    if (index == 1) return self.close("}");
                    frame.next = 1;
                    try self.part(element, try self.member(try aggregate(frame.value), 0), frame.open);
                },
                // An entry is `{"k":{"":K},"v":{"":V}}`: two containers more around each half.
                .map => |shape| {
                    const span = try aggregate(frame.value);
                    if ((span.end - span.start) % 2 != 0) return error.InvalidValue;
                    if (index != 0 and index % 2 == 0) try self.write("}}");
                    if (index == span.end - span.start) return self.close("]");
                    // The entry's object and the wrapper around its key or value are open while
                    // the part is written, whatever the part is: the decoder counts them.
                    if (frame.open + 2 > self.limit) return error.DepthLimit;
                    if (index % 2 == 0) try self.write(if (index == 0) "{\"k\":{\"\":" else ",{\"k\":{\"\":") else try self.write("},\"v\":{\"\":");
                    frame.next += 1;
                    try self.part(if (index % 2 == 0) shape.key else shape.value, try self.member(span, index), frame.open + 2);
                },
                .record, .class => |fields| {
                    if (index == fields.end - fields.start) return self.close("}");
                    const field = self.cat.fields[fields.start + index];
                    try self.write(",\"x_");
                    try self.write(self.cat.text(field.name));
                    try self.write("\":");
                    frame.next += 1;
                    const value = if (frame.value == .object) self.host.field(frame.value.object, index) catch return error.Host else try self.member(try aggregate(frame.value), index);
                    try self.part(field.value_type, value, frame.open);
                },
                else => return error.InvalidValue,
            }
        }
        fn close(self: *Self, closer: []const u8) Error!void {
            try self.write(closer);
            self.depth -= 1;
        }
    };
}

// --- decoding ---------------------------------------------------------------------------------

/// `option(T)` of the value `text` encodes as `T` (E3, E4), or the empty option when it encodes
/// none. Every member the decode builds is appended to `members`, the option's last; strings to
/// `pool`; instances through `host.instance(class, cells, block)`, where `cells` are the
/// header and the fields and `block` is the first of the members the fields were laid out as.
/// `host.instanceMark()` and `host.instanceDrop(mark)` let a decode that fails take back the
/// instances it made. Charges 2, one per 8 bytes read, one per member and instance built, one
/// per enumerator compared after the first and one per field passed over to find a member
/// written out of order. Fuel is fatal; anything about the text is a failure.
///
/// The text is read twice. The first pass checks every rule of E3 but two keys of a map being
/// equal, and builds nothing; a text it refuses has cost what was read of it. The second pass
/// builds the value, and fails only for equal keys, which needs the keys built, and then keeps
/// nothing of what it built. So a text that does not encode a value never meets a capacity:
/// only one that does, and needs more than the run has, ends it with `aggregate_limit`,
/// `string_limit` or `object_limit`. The first pass charges the bytes, the enumerators and
/// the fields; the second the members and the instances.
pub fn decode(cat: Catalogue, host: anytype, members: Members, option_type: types.Type, text: []const u8, pool: *run_strings.Pool, stack: *Stack, key_work: *keys.Work, remaining: *u64) Error!types.Value {
    return decodeWithin(json_depth, cat, host, members, option_type, text, pool, stack, key_work, remaining);
}

/// `decode` with `limit` open containers at most instead of `json_depth`: for the tests of the
/// depth rule.
pub fn decodeWithin(limit: u32, cat: Catalogue, host: anytype, members: Members, option_type: types.Type, text: []const u8, pool: *run_strings.Pool, stack: *Stack, key_work: *keys.Work, remaining: *u64) Error!types.Value {
    std.debug.assert(limit <= json_depth);
    // The one charge a decode makes before it reads anything.
    try spend(remaining, 2);
    const shape = catalogue.definition(option_type, cat.definitions) orelse return error.InvalidValue;
    if (shape != .option) return error.InvalidValue;
    const first = members.count.*;
    if (first > members.slots.len) return error.AggregateLimit;
    const nothing: types.Value = .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = @intCast(first), .end = @intCast(first) } } };
    _ = (try decodeCore(limit, cat, host, members, shape.option, text, pool, stack, key_work, remaining)) orelse return nothing;
    return .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = @intCast(members.count.* - 1), .end = @intCast(members.count.*) } } };
}

/// RFC-0087, P5.5 (S4): the value of type `value_type` that `text` encodes, or null when it
/// encodes none, for a load, which has no `option(T)` to name. The value is the newest member
/// the decode laid out (its option's member in `decode`), and is given as well. Charges what
/// `decode` charges.
pub fn decodeEntry(cat: Catalogue, host: anytype, members: Members, value_type: types.Type, text: []const u8, pool: *run_strings.Pool, stack: *Stack, key_work: *keys.Work, remaining: *u64) Error!?types.Value {
    try spend(remaining, 2);
    if (members.count.* > members.slots.len) return error.AggregateLimit;
    // A load is the first text this decoder reads that is no Forbic string: one that is not UTF-8
    // encodes no value, whose strings would not be text.
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    return decodeCore(json_depth, cat, host, members, value_type, text, pool, stack, key_work, remaining);
}

/// Reads `text` twice (J8): the first pass checks every rule but equal map keys and builds
/// nothing; the second builds the value, as the newest member from `members.count`. A text that
/// encodes no value builds nothing and gives null.
fn decodeCore(limit: u32, cat: Catalogue, host: anytype, members: Members, element: types.Type, text: []const u8, pool: *run_strings.Pool, stack: *Stack, key_work: *keys.Work, remaining: *u64) Error!?types.Value {
    const first = members.count.*;
    var checker: Decoder(@TypeOf(host)) = .{ .cat = cat, .host = host, .text = text, .slots = members.slots, .bottom = first, .top = members.slots.len, .pool = pool, .remaining = remaining, .frames = &stack.frames, .marks = &stack.marks, .key_work = key_work, .building = false, .limit = limit };
    _ = checker.run(element) catch |err| switch (err) {
        // What was read before the text failed is paid for.
        error.Invalid => {
            try checker.charge();
            return null;
        },
        else => |fatal| return fatal,
    };
    const used = pool.used;
    const made = host.instanceMark();
    var decoder: Decoder(@TypeOf(host)) = .{ .cat = cat, .host = host, .text = text, .slots = members.slots, .bottom = first, .top = members.slots.len, .pool = pool, .remaining = remaining, .frames = &stack.frames, .marks = &stack.marks, .key_work = key_work, .building = true, .limit = limit };
    const value = decoder.run(element) catch |err| switch (err) {
        error.Invalid => {
            // The text encodes no value: nothing the decode built is kept.
            pool.used = used;
            host.instanceDrop(made);
            return null;
        },
        else => |fatal| return fatal,
    };
    try decoder.append(value);
    members.count.* = decoder.bottom;
    return value;
}

const DecodeError = Error || error{Invalid};

/// A JSON string as it lies in the text, between its quotes, with what it decodes to.
const Token = struct {
    raw: []const u8,
    length: usize,
    escaped: bool,
};

/// The bytes a JSON string decodes to, one at a time. The string was checked when it was read.
const Unescaped = struct {
    raw: []const u8,
    at: usize = 0,
    held: [4]u8 = undefined,
    held_length: u8 = 0,
    held_at: u8 = 0,

    fn next(self: *Unescaped) ?u8 {
        if (self.held_at < self.held_length) {
            self.held_at += 1;
            return self.held[self.held_at - 1];
        }
        if (self.at >= self.raw.len) return null;
        const c = self.raw[self.at];
        if (c != '\\') {
            self.at += 1;
            return c;
        }
        const e = self.raw[self.at + 1];
        self.at += 2;
        switch (e) {
            '"', '\\', '/' => return e,
            'b' => return 0x08,
            'f' => return 0x0C,
            'n' => return 0x0A,
            'r' => return 0x0D,
            't' => return 0x09,
            else => {},
        }
        var code: u21 = hex4(self.raw[self.at..][0..4]);
        self.at += 4;
        if (code >= 0xD800 and code < 0xDC00) {
            const low = hex4(self.raw[self.at + 2 ..][0..4]);
            self.at += 6;
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        }
        self.held_length = std.unicode.utf8Encode(code, &self.held) catch unreachable;
        self.held_at = 1;
        return self.held[0];
    }
};

fn hexDigit(c: u8) ?u21 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
fn hex4(digits: *const [4]u8) u21 {
    var code: u21 = 0;
    for (digits) |c| code = code * 16 + hexDigit(c).?;
    return code;
}

/// Whether the string decodes to the pieces joined.
fn matches(token: Token, parts: []const []const u8) bool {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    if (total != token.length) return false;
    if (!token.escaped) {
        var at: usize = 0;
        for (parts) |part| {
            if (!std.mem.eql(u8, token.raw[at..][0..part.len], part)) return false;
            at += part.len;
        }
        return true;
    }
    var bytes: Unescaped = .{ .raw = token.raw };
    for (parts) |part| for (part) |c| if (bytes.next() != c) return false;
    return bytes.next() == null;
}

fn Decoder(comptime Host: type) type {
    return struct {
        const Self = @This();
        cat: Catalogue,
        host: Host,
        text: []const u8,
        at: usize = 0,
        charged: usize = 0,
        slots: []types.Value,
        /// Members in use: the result's so far, from the first the decode was lent.
        bottom: usize,
        /// The parts that wait for their containers lie from here to the end of `slots`.
        top: usize,
        pool: *run_strings.Pool,
        remaining: *u64,
        frames: []Frame,
        depth: usize = 0,
        /// JSON containers open in the text, and the most there may be.
        open: u32 = 0,
        limit: u32,
        marks: []u64,
        /// The next free bit of `marks`.
        mark_top: usize = 0,
        key_work: *keys.Work,
        result: ?types.Value = null,
        /// The second pass, which builds; the first only checks (`decode`).
        building: bool,

        fn run(self: *Self, value_type: types.Type) DecodeError!types.Value {
            var pending: ?types.Type = value_type;
            while (true) {
                if (pending) |wanted| {
                    pending = null;
                    try self.readValue(wanted);
                } else if (self.depth == 0) break else pending = try self.proceed();
            }
            self.space();
            if (self.at != self.text.len) return error.Invalid;
            try self.charge();
            return self.result.?;
        }

        // The text.
        fn charge(self: *Self) Error!void {
            // The first pass paid for the bytes.
            if (self.building) return;
            try spend(self.remaining, self.at / 8 - self.charged / 8);
            self.charged = self.at;
        }
        fn space(self: *Self) void {
            while (self.at < self.text.len) : (self.at += 1) switch (self.text[self.at]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            };
        }
        /// Skips whitespace and takes `c`, or fails.
        fn expect(self: *Self, c: u8) DecodeError!void {
            self.space();
            if (self.at >= self.text.len or self.text[self.at] != c) return error.Invalid;
            self.at += 1;
            try self.charge();
        }
        /// Skips whitespace and takes `c` if it is next.
        fn take(self: *Self, c: u8) DecodeError!bool {
            self.space();
            if (self.at >= self.text.len or self.text[self.at] != c) return false;
            self.at += 1;
            try self.charge();
            return true;
        }
        fn literal(self: *Self, word: []const u8) DecodeError!bool {
            self.space();
            if (!std.mem.startsWith(u8, self.text[self.at..], word)) return false;
            self.at += word.len;
            try self.charge();
            return true;
        }
        fn peek(self: *Self) ?u8 {
            self.space();
            return if (self.at < self.text.len) self.text[self.at] else null;
        }
        /// A JSON number (RFC 8259): its text, and whether it has a fraction or an exponent.
        fn number(self: *Self) DecodeError!struct { text: []const u8, integral: bool } {
            self.space();
            const start = self.at;
            const text = self.text;
            var integral = true;
            if (self.at < text.len and text[self.at] == '-') self.at += 1;
            if (self.at >= text.len) return error.Invalid;
            if (text[self.at] == '0') self.at += 1 else if (text[self.at] >= '1' and text[self.at] <= '9') {
                while (self.at < text.len and std.ascii.isDigit(text[self.at])) self.at += 1;
            } else return error.Invalid;
            if (self.at < text.len and text[self.at] == '.') {
                self.at += 1;
                integral = false;
                if (self.at >= text.len or !std.ascii.isDigit(text[self.at])) return error.Invalid;
                while (self.at < text.len and std.ascii.isDigit(text[self.at])) self.at += 1;
            }
            if (self.at < text.len and (text[self.at] == 'e' or text[self.at] == 'E')) {
                self.at += 1;
                integral = false;
                if (self.at < text.len and (text[self.at] == '+' or text[self.at] == '-')) self.at += 1;
                if (self.at >= text.len or !std.ascii.isDigit(text[self.at])) return error.Invalid;
                while (self.at < text.len and std.ascii.isDigit(text[self.at])) self.at += 1;
            }
            try self.charge();
            return .{ .text = text[start..self.at], .integral = integral };
        }
        fn integer(self: *Self, low: i64, high: i64) DecodeError!i64 {
            const read = try self.number();
            if (!read.integral) return error.Invalid;
            const value = std.fmt.parseInt(i64, read.text, 10) catch return error.Invalid;
            if (value < low or value > high) return error.Invalid;
            return value;
        }
        /// A JSON string: well formed escapes, no control character, no lone surrogate (E3).
        fn stringToken(self: *Self) DecodeError!Token {
            self.space();
            const text = self.text;
            if (self.at >= text.len or text[self.at] != '"') return error.Invalid;
            self.at += 1;
            const start = self.at;
            var length: usize = 0;
            var escaped = false;
            while (true) {
                if (self.at >= text.len) return error.Invalid;
                const c = text[self.at];
                if (c == '"') break;
                if (c < 0x20) return error.Invalid;
                if (c != '\\') {
                    self.at += 1;
                    length += 1;
                    continue;
                }
                escaped = true;
                if (self.at + 1 >= text.len) return error.Invalid;
                const e = text[self.at + 1];
                self.at += 2;
                switch (e) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        length += 1;
                        continue;
                    },
                    'u' => {},
                    else => return error.Invalid,
                }
                const code = try self.hex();
                if (code >= 0xDC00 and code < 0xE000) return error.Invalid;
                if (code >= 0xD800 and code < 0xDC00) {
                    if (self.at + 1 >= text.len or text[self.at] != '\\' or text[self.at + 1] != 'u') return error.Invalid;
                    self.at += 2;
                    const low = try self.hex();
                    if (low < 0xDC00 or low >= 0xE000) return error.Invalid;
                    length += 4;
                } else length += std.unicode.utf8CodepointSequenceLength(code) catch unreachable;
            }
            const raw = text[start..self.at];
            self.at += 1;
            try self.charge();
            return .{ .raw = raw, .length = length, .escaped = escaped };
        }
        fn hex(self: *Self) DecodeError!u21 {
            if (self.text.len - self.at < 4) return error.Invalid;
            for (self.text[self.at..][0..4]) |c| if (hexDigit(c) == null) return error.Invalid;
            const code = hex4(self.text[self.at..][0..4]);
            self.at += 4;
            return code;
        }

        // The member pool.
        /// What the first pass delivers: it builds no value.
        const unbuilt: types.Value = .{ .boolean = false };
        /// The first pass's charge for a comparison, which the second makes again for nothing.
        fn compared(self: *Self) Error!void {
            if (!self.building) try spend(self.remaining, 1);
        }
        fn push(self: *Self, value: types.Value) Error!void {
            if (!self.building) return;
            if (self.top == self.bottom) return error.AggregateLimit;
            self.top -= 1;
            self.slots[self.top] = value;
        }
        fn reserve(self: *Self, count: usize) Error!u32 {
            if (!self.building) return @intCast(self.top);
            if (count > self.top - self.bottom) return error.AggregateLimit;
            self.top -= count;
            return @intCast(self.top);
        }
        fn append(self: *Self, value: types.Value) Error!void {
            if (self.top == self.bottom) return error.AggregateLimit;
            try spend(self.remaining, 1);
            self.slots[self.bottom] = value;
            self.bottom += 1;
        }
        /// Moves `count` parts that wait from `from` on, in order, to the end of the members,
        /// and gives their span. The members only ever move down, so the move needs no room.
        fn layOut(self: *Self, from: usize, count: usize) Error!types.Span {
            if (!self.building) return .{ .start = @intCast(self.bottom), .end = @intCast(self.bottom) };
            try spend(self.remaining, count);
            const start = self.bottom;
            std.mem.copyForwards(types.Value, self.slots[start..][0..count], self.slots[from..][0..count]);
            self.bottom += count;
            return .{ .start = @intCast(start), .end = @intCast(self.bottom) };
        }
        /// The parts of a container that pushed them, which lie below `base` in reverse order:
        /// put back in order and laid out.
        fn layOutPushed(self: *Self, frame: *const Frame) Error!types.Span {
            if (!self.building) return .{ .start = @intCast(self.bottom), .end = @intCast(self.bottom) };
            const count = frame.base - self.top;
            std.mem.reverse(types.Value, self.slots[self.top..frame.base]);
            const span = try self.layOut(self.top, count);
            self.top = frame.base;
            return span;
        }
        fn buildString(self: *Self, token: Token) Error![]const u8 {
            if (!self.building) return "";
            const pool = self.pool;
            const offset = pool.used - pool.base;
            if (offset > pool.tail.len or token.length > pool.tail.len - offset) return error.StringLimit;
            const out = pool.tail[offset..][0..token.length];
            if (!token.escaped) @memcpy(out, token.raw) else {
                var bytes: Unescaped = .{ .raw = token.raw };
                for (out) |*c| c.* = bytes.next().?;
            }
            pool.used += token.length;
            return out;
        }

        // The frames.
        fn openFrame(self: *Self, kind: Kind, value_type: types.Type) DecodeError!*Frame {
            if (kind != .constant) {
                if (self.open == self.limit) return error.Invalid;
                self.open += 1;
            }
            // A text opens at most `json_depth` frames, and a default constant the frames the
            // comptime check above counts.
            std.debug.assert(self.depth < self.frames.len);
            self.frames[self.depth] = .{ .kind = kind, .value_type = value_type, .base = @intCast(self.top) };
            self.depth += 1;
            return &self.frames[self.depth - 1];
        }
        fn pop(self: *Self) void {
            if (self.frames[self.depth - 1].kind != .constant) self.open -= 1;
            self.depth -= 1;
        }
        /// Hands a value to the innermost open container, or makes it the result.
        fn deliver(self: *Self, value: types.Value) Error!void {
            if (self.depth == 0) {
                self.result = value;
                return;
            }
            const frame = &self.frames[self.depth - 1];
            switch (frame.kind) {
                .array, .tuple, .map, .constant => {
                    try self.push(value);
                    frame.count += 1;
                },
                .option => if (self.building) {
                    self.slots[frame.base] = value;
                },
                .entry, .wrap, .record, .class => if (self.building) {
                    self.slots[frame.target] = value;
                },
            }
            if (frame.phase == .awaiting) frame.phase = .after;
        }
        /// Closes the innermost container with the value it built, or with none for a part of
        /// its container's (an entry, a wrapper).
        fn closeWith(self: *Self, value: ?types.Value) Error!void {
            self.pop();
            if (value) |made| return self.deliver(made);
            const frame = &self.frames[self.depth - 1];
            if (frame.phase == .awaiting) frame.phase = .after;
        }

        /// Reads a value of `value_type`: a scalar is delivered, a container opened.
        fn readValue(self: *Self, value_type: types.Type) DecodeError!void {
            switch (try shapeOf(self.cat, value_type)) {
                .logic => {
                    if (try self.literal("true")) return self.deliver(.{ .boolean = true });
                    if (try self.literal("false")) return self.deliver(.{ .boolean = false });
                    return error.Invalid;
                },
                .integer => return self.deliver(.{ .integer = try self.integer(std.math.minInt(i64), std.math.maxInt(i64)) }),
                .character => |character| {
                    const code = try self.integer(0, if (character == types.Type.char) 0xFF else 0x10FFFF);
                    if (!types.validCharacter(character, @intCast(code))) return error.Invalid;
                    return self.deliver(types.characterValue(character, @intCast(code)));
                },
                .floating => {
                    if (self.peek() == '"') {
                        const token = try self.stringToken();
                        const special: f64 = if (matches(token, &.{"NaN"})) std.math.nan(f64) else if (matches(token, &.{"Inf"})) std.math.inf(f64) else if (matches(token, &.{"-Inf"})) -std.math.inf(f64) else return error.Invalid;
                        return self.deliver(.{ .floating = types.canonicalFloat(special) });
                    }
                    const read = try self.number();
                    const parsed = std.fmt.parseFloat(f64, read.text) catch return error.Invalid;
                    // A number too large for a float is no float (E3).
                    if (std.math.isInf(parsed)) return error.Invalid;
                    return self.deliver(.{ .floating = types.canonicalFloat(parsed) });
                },
                .string => return self.deliver(.{ .string = try self.buildString(try self.stringToken()) }),
                .enumeration => |enumeration| {
                    const token = try self.stringToken();
                    const name = self.cat.text(enumeration.name);
                    const cases = self.cat.cases[enumeration.cases.start..enumeration.cases.end];
                    for (cases, 0..) |case, index| {
                        if (index != 0) try self.compared();
                        if (matches(token, &.{ name, "::", self.cat.text(case) })) return self.deliver(.{ .enumeration = .{ .value_type = value_type, .index = @intCast(index) } });
                    }
                    return error.Invalid;
                },
                .option => {
                    if (try self.literal("false")) return self.deliver(.{ .aggregate = .{ .value_type = value_type, .elements = .{ .start = @intCast(self.bottom), .end = @intCast(self.bottom) } } });
                    try self.expect('{');
                    const frame = try self.openFrame(.option, value_type);
                    frame.base = try self.reserve(1);
                },
                .array => {
                    try self.expect('[');
                    _ = try self.openFrame(.array, value_type);
                },
                .tuple => {
                    try self.expect('[');
                    _ = try self.openFrame(.tuple, value_type);
                },
                .map => {
                    try self.expect('[');
                    _ = try self.openFrame(.map, value_type);
                },
                .record => |fields| {
                    try self.expect('{');
                    const frame = try self.openFrame(.record, value_type);
                    frame.base = try self.reserve(fields.end - fields.start);
                    frame.marks = try self.claimMarks(fields.end - fields.start);
                },
                .class => |fields| {
                    try self.expect('{');
                    const frame = try self.openFrame(.class, value_type);
                    frame.base = try self.reserve(fields.end - fields.start + 1);
                    frame.marks = try self.claimMarks(fields.end - fields.start);
                    if (self.building) self.slots[frame.base] = .{ .integer = @backingInt(value_type) };
                },
            }
        }

        /// Goes on with the innermost container: the type of the next value to read, or null
        /// when the container moved on by itself.
        fn proceed(self: *Self) DecodeError!?types.Type {
            const frame = &self.frames[self.depth - 1];
            switch (frame.kind) {
                .array => {
                    const element = catalogue.definition(frame.value_type, self.cat.definitions).?.array;
                    if (frame.phase == .open) {
                        if (try self.take(']')) return self.closeArray(frame);
                    } else if (!try self.take(',')) {
                        try self.expect(']');
                        return self.closeArray(frame);
                    }
                    frame.phase = .awaiting;
                    return element;
                },
                .tuple => {
                    const elements = catalogue.definition(frame.value_type, self.cat.definitions).?.tuple;
                    const arity = elements.end - elements.start;
                    if (frame.count == arity) {
                        try self.expect(']');
                        return self.closeArray(frame);
                    }
                    if (frame.phase != .open) try self.expect(',');
                    frame.phase = .awaiting;
                    return self.cat.tuple_elements[elements.start + frame.count];
                },
                .option, .wrap => {
                    if (frame.phase == .open) {
                        const name = try self.stringToken();
                        if (!matches(name, &.{""})) return error.Invalid;
                        try self.expect(':');
                        frame.phase = .awaiting;
                        const shape = catalogue.definition(frame.value_type, self.cat.definitions).?;
                        if (frame.kind == .option) return shape.option;
                        // A wrapper reads the key or the value of a map entry.
                        return if (frame.count == 0) shape.map.key else shape.map.value;
                    }
                    try self.expect('}');
                    if (frame.kind == .wrap) {
                        try self.closeWith(null);
                        return null;
                    }
                    if (!self.building) {
                        try self.closeWith(unbuilt);
                        return null;
                    }
                    const span = try self.layOut(frame.base, 1);
                    self.top = frame.base + 1;
                    try self.closeWith(.{ .aggregate = .{ .value_type = frame.value_type, .elements = span } });
                    return null;
                },
                .map => {
                    if (frame.phase == .open) {
                        if (try self.take(']')) return self.closeMap(frame);
                    } else if (!try self.take(',')) {
                        try self.expect(']');
                        return self.closeMap(frame);
                    }
                    frame.phase = .awaiting;
                    try self.expect('{');
                    const entry = try self.openFrame(.entry, frame.value_type);
                    // The key, then the value, as the map's parts: pushed below what it holds.
                    entry.base = try self.reserve(2);
                    return null;
                },
                .entry => {
                    if (frame.phase != .open) {
                        if (!try self.take(',')) {
                            try self.expect('}');
                            if (frame.seen != 3) return error.Invalid;
                            // Its key and its value stay where they are, the map's two parts.
                            self.pop();
                            const map = &self.frames[self.depth - 1];
                            map.count += 2;
                            map.phase = .after;
                            return null;
                        }
                    }
                    const name = try self.stringToken();
                    const bit: u8 = if (matches(name, &.{"k"})) 1 else if (matches(name, &.{"v"})) 2 else return error.Invalid;
                    if (frame.seen & bit != 0) return error.Invalid;
                    frame.seen |= bit;
                    try self.expect(':');
                    try self.expect('{');
                    frame.phase = .awaiting;
                    frame.target = if (bit == 1) frame.base + 1 else frame.base;
                    const target = frame.target;
                    const wrap = try self.openFrame(.wrap, frame.value_type);
                    wrap.target = target;
                    wrap.count = bit - 1;
                    return null;
                },
                .record, .class => return self.resumeObject(frame),
                .constant => {
                    const constant = self.cat.constants[frame.next];
                    const span = constant.kind.aggregate;
                    if (frame.count == span.end - span.start) {
                        const laid = try self.layOutPushed(frame);
                        try self.closeWith(.{ .aggregate = .{ .value_type = constant.value_type, .elements = laid } });
                        return null;
                    }
                    try self.materialize(self.cat.constant_members[span.start + frame.count]);
                    return null;
                },
            }
        }
        fn closeArray(self: *Self, frame: *Frame) Error!?types.Type {
            if (!self.building) {
                try self.closeWith(unbuilt);
                return null;
            }
            const span = try self.layOutPushed(frame);
            try self.closeWith(.{ .aggregate = .{ .value_type = frame.value_type, .elements = span } });
            return null;
        }
        fn closeMap(self: *Self, frame: *Frame) DecodeError!?types.Type {
            // Equal keys are found once the keys are built, in the second pass.
            if (!self.building) {
                try self.closeWith(unbuilt);
                return null;
            }
            const span = try self.layOutPushed(frame);
            // Two entries with equal keys encode no map: a literal with them is fatal (E3).
            keys.unique(self.key_work, self.slots[0..self.bottom], self.slots[span.start..span.end], self.remaining) catch |err| return switch (err) {
                error.DuplicateKey => error.Invalid,
                error.WorkLimit => error.WorkLimit,
                error.ScratchUnavailable => error.ScratchUnavailable,
            };
            try self.closeWith(.{ .aggregate = .{ .value_type = frame.value_type, .elements = span } });
            return null;
        }

        /// Bits for the fields of an object just opened, all clear; they are given back when it
        /// closes.
        fn claimMarks(self: *Self, count: usize) Error!u32 {
            const first = self.mark_top;
            if (count > self.marks.len * 64 - first) return error.InvalidValue;
            var at = first;
            while (at < first + count) {
                if (at % 64 == 0 and first + count - at >= 64) {
                    self.marks[at / 64] = 0;
                    at += 64;
                } else {
                    self.marks[at / 64] &= ~(@as(u64, 1) << @intCast(at % 64));
                    at += 1;
                }
            }
            self.mark_top = first + count;
            return @intCast(first);
        }
        fn isGiven(self: *const Self, frame: *const Frame, index: usize) bool {
            const bit = frame.marks + index;
            return self.marks[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0;
        }

        /// A struct or a class: its members in any order, then the defaults of the fields the
        /// text lacks, then the value.
        fn resumeObject(self: *Self, frame: *Frame) DecodeError!?types.Type {
            const class = frame.kind == .class;
            const fields = switch (catalogue.definition(frame.value_type, self.cat.definitions).?) {
                .record => |record| record.fields,
                .class => |item| item.fields,
                else => unreachable,
            };
            const count = fields.end - fields.start;
            const first: u32 = frame.base + @intFromBool(class);
            switch (frame.phase) {
                .open, .after => {
                    if (frame.phase == .open) {
                        if (try self.take('}')) {
                            frame.phase = .closing;
                            frame.next = 0;
                            return null;
                        }
                    } else if (!try self.take(',')) {
                        try self.expect('}');
                        frame.phase = .closing;
                        frame.next = 0;
                        return null;
                    }
                    const name = try self.stringToken();
                    try self.expect(':');
                    // Metadata may be absent; present, it names this type (E3).
                    if (matches(name, &.{"$package_name"}) or matches(name, &.{"$class_name"})) {
                        const bit: u8 = if (matches(name, &.{"$class_name"})) 2 else 1;
                        if (frame.seen & bit != 0) return error.Invalid;
                        frame.seen |= bit;
                        const given = try self.stringToken();
                        const ok = if (bit == 2) matches(given, &.{typeName(self.cat, frame.value_type)}) else matches(given, Package.of(self.cat, frame.value_type).slice());
                        if (!ok) return error.Invalid;
                        frame.phase = .after;
                        return null;
                    }
                    // The field the member names: the one after the last found, as in a text
                    // written canonically, or else any, each passed over at a unit.
                    var found: ?u32 = null;
                    if (frame.next < count and matches(name, &.{ "x_", self.cat.text(self.cat.fields[fields.start + frame.next].name) })) found = frame.next else {
                        for (0..count) |index| {
                            if (index == frame.next) continue;
                            try self.compared();
                            if (matches(name, &.{ "x_", self.cat.text(self.cat.fields[fields.start + index].name) })) {
                                found = @intCast(index);
                                break;
                            }
                        }
                    }
                    const index = found orelse return error.Invalid;
                    if (self.isGiven(frame, index)) return error.Invalid;
                    const bit = frame.marks + index;
                    self.marks[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
                    frame.next = index + 1;
                    frame.target = first + index;
                    frame.phase = .awaiting;
                    return self.cat.fields[fields.start + index].value_type;
                },
                .closing => {
                    // A field the text lacks takes its default (E3, 17:352); one without fails.
                    while (frame.next < count) {
                        const index = frame.next;
                        frame.next += 1;
                        if (self.isGiven(frame, index)) continue;
                        const constant = self.cat.fields[fields.start + index].constant orelse return error.Invalid;
                        if (!self.building) continue;
                        frame.target = first + index;
                        try self.materialize(constant);
                        if (self.frames[self.depth - 1].kind == .constant) return null;
                    }
                    self.mark_top = frame.marks;
                    if (!self.building) {
                        try self.closeWith(unbuilt);
                        return null;
                    }
                    if (!class) {
                        const span = try self.layOut(first, count);
                        self.top = frame.base + count;
                        try self.closeWith(.{ .aggregate = .{ .value_type = frame.value_type, .elements = span } });
                        return null;
                    }
                    // The instance's cells are its header and its fields (E5: nothing runs),
                    // which are then laid out as the members from `block` on. It is built
                    // first: laying out may write over the block that holds its cells.
                    try spend(self.remaining, 1);
                    const block: u32 = @intCast(self.bottom);
                    const id = self.host.instance(frame.value_type, self.slots[frame.base..][0 .. count + 1], block) catch return error.Host;
                    _ = try self.layOut(first, count);
                    self.top = frame.base + count + 1;
                    try self.closeWith(.{ .object = .{ .value_type = frame.value_type, .id = id } });
                    return null;
                },
                .awaiting => unreachable,
            }
        }

        /// Builds the default constant `index`: a scalar at once, an aggregate in a frame.
        fn materialize(self: *Self, index: u32) DecodeError!void {
            if (index >= self.cat.constants.len) return error.InvalidValue;
            const constant = self.cat.constants[index];
            const made: types.Value = switch (constant.kind) {
                .integer => |value| .{ .integer = value },
                .boolean => |value| .{ .boolean = value },
                .floating => |value| .{ .floating = types.canonicalFloat(value) },
                .string => |span| .{ .string = self.cat.strings[span.start..span.end] },
                .enumeration => |case| .{ .enumeration = .{ .value_type = constant.value_type, .index = case } },
                .character => |code| types.characterValue(constant.value_type, code),
                .aggregate => {
                    const frame = try self.openFrame(.constant, constant.value_type);
                    frame.next = index;
                    return;
                },
            };
            return self.deliver(made);
        }
    };
}

// --- tests ------------------------------------------------------------------------------------

/// A host over a plain array of instance cells, for the tests of this file and of the model.
pub const TestHost = struct {
    cells: []types.Value,
    count: usize = 0,
    instances: u32 = 0,
    blocks: [64]u32 = undefined,

    pub fn field(self: *TestHost, object: types.ObjectRef, index: u32) error{Host}!types.Value {
        if (object.id + 1 + index >= self.count) return error.Host;
        return self.cells[object.id + 1 + index];
    }
    pub fn instance(self: *TestHost, class: types.Type, cells: []const types.Value, block: u32) error{Host}!u32 {
        if (cells.len > self.cells.len - self.count or cells[0] != .integer or cells[0].integer != @backingInt(class)) return error.Host;
        const id: u32 = @intCast(self.count);
        @memcpy(self.cells[self.count..][0..cells.len], cells);
        self.count += cells.len;
        if (self.instances < self.blocks.len) self.blocks[self.instances] = block;
        self.instances += 1;
        return id;
    }
    pub fn instanceMark(self: *TestHost) usize {
        return self.count;
    }
    pub fn instanceDrop(self: *TestHost, mark: usize) void {
        self.count = mark;
    }
};

const testing = std.testing;
const scratch = @import("scratch.zig");

fn testCatalogue(definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type, cases: []const types.Span, source: []const u8, constants: []const types.Constant, constant_members: []const u32) Catalogue {
    return .{ .source = source, .strings = source, .definitions = definitions, .fields = fields, .cases = cases, .tuple_elements = tuple_elements, .paths = "", .modules = &.{}, .nested = &.{}, .constants = constants, .constant_members = constant_members };
}

const Fixture = struct {
    stack: *Stack,
    members: []types.Value,
    count: usize = 0,
    bytes: []u8,
    pool: run_strings.Pool,
    cells: []types.Value,
    host: TestHost = undefined,
    work: keys.Work = .{},

    fn init(self: *Fixture) !void {
        self.stack = try scratch.storage(Stack);
        self.members = scratch.alloc(types.Value, 1 << 18) orelse return error.OutOfMemory;
        self.cells = scratch.alloc(types.Value, 1 << 17) orelse return error.OutOfMemory;
        self.bytes = scratch.alloc(u8, 1 << 23) orelse return error.OutOfMemory;
        self.pool = run_strings.Pool.init(self.bytes[0..0], self.bytes);
        self.host = .{ .cells = self.cells };
        self.count = 0;
        self.work = .{};
    }
    fn deinit(self: *Fixture) void {
        self.work.release();
        scratch.release(self.stack);
        scratch.free(self.members);
        scratch.free(self.cells);
        scratch.free(self.bytes);
    }
    fn decodeText(self: *Fixture, cat: Catalogue, option_type: types.Type, text: []const u8) !types.Value {
        var remaining: u64 = 1 << 40;
        return decode(cat, &self.host, .{ .slots = self.members, .count = &self.count }, option_type, text, &self.pool, self.stack, &self.work, &remaining);
    }
    fn encodeValue(self: *Fixture, cat: Catalogue, value_type: types.Type, value: types.Value) ![]const u8 {
        var remaining: u64 = 1 << 40;
        return encode(cat, &self.host, self.members[0..self.count], value_type, value, &self.pool, self.stack, &remaining);
    }
};

test "scalars round trip through their canonical texts, and the decoder is strict" {
    // 4: option(i64), 5: option(float), 6: option(string), 7: option(char32), 8: option(logic), 9: option(char)
    const definitions = [_]types.Definition{ .{ .option = .i64 }, .{ .option = .float }, .{ .option = .string }, .{ .option = types.Type.char32 }, .{ .option = .logic }, .{ .option = types.Type.char } };
    const cat = testCatalogue(&definitions, &.{}, &.{}, &.{}, "", &.{}, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const Case = struct { option: u16, text: []const u8, ok: bool };
    const cases = [_]Case{
        .{ .option = 4, .text = "-9223372036854775808", .ok = true },
        .{ .option = 4, .text = "9223372036854775808", .ok = false },
        .{ .option = 4, .text = "1.0", .ok = false },
        .{ .option = 4, .text = "1e3", .ok = false },
        .{ .option = 4, .text = "01", .ok = false },
        .{ .option = 4, .text = " 7 ", .ok = true },
        .{ .option = 4, .text = "1 2", .ok = false },
        .{ .option = 4, .text = "null", .ok = false },
        .{ .option = 5, .text = "-0", .ok = true },
        .{ .option = 5, .text = "1e400", .ok = false },
        .{ .option = 5, .text = "\"Infinity\"", .ok = false },
        .{ .option = 5, .text = "\"-Inf\"", .ok = true },
        .{ .option = 6, .text = "\"a\\u00e9\\ud83d\\ude00\\n\"", .ok = true },
        .{ .option = 6, .text = "\"\\ud800\"", .ok = false },
        .{ .option = 6, .text = "\"a\\udfff\"", .ok = false },
        .{ .option = 6, .text = "\"\\x41\"", .ok = false },
        .{ .option = 6, .text = "\"tab\there\"", .ok = false },
        .{ .option = 7, .text = "1114111", .ok = true },
        .{ .option = 7, .text = "1114112", .ok = false },
        .{ .option = 7, .text = "55296", .ok = false },
        .{ .option = 9, .text = "255", .ok = true },
        .{ .option = 9, .text = "256", .ok = false },
        .{ .option = 9, .text = "-1", .ok = false },
        .{ .option = 8, .text = "true", .ok = true },
        .{ .option = 8, .text = "\"true\"", .ok = false },
        .{ .option = 8, .text = "true false", .ok = false },
    };
    for (cases) |case| {
        const option_type: types.Type = @fromBackingInt(case.option);
        const got = try fixture.decodeText(cat, option_type, case.text);
        const span = got.aggregate.elements;
        try testing.expectEqual(case.ok, span.end - span.start == 1);
    }
    const value = (try fixture.decodeText(cat, @fromBackingInt(6), "\"a\\u00e9\\ud83d\\ude00\\n\""));
    const text = fixture.members[value.aggregate.elements.start].string;
    try testing.expectEqualStrings("a\u{e9}\u{1F600}\n", text);
    try testing.expectEqualStrings("\"a\u{e9}\u{1F600}\\n\"", try fixture.encodeValue(cat, .string, .{ .string = text }));
    try testing.expectEqualStrings("\"\\u0001\\b\\\"\\\\\"", try fixture.encodeValue(cat, .string, .{ .string = "\x01\x08\"\\" }));
    try testing.expectEqualStrings("-0", try fixture.encodeValue(cat, .float, .{ .floating = -0.0 }));
    try testing.expectEqualStrings("\"NaN\"", try fixture.encodeValue(cat, .float, .{ .floating = types.canonicalFloat(std.math.nan(f64)) }));
    try testing.expectEqualStrings("9223372036854776000", try fixture.encodeValue(cat, .float, .{ .floating = 9223372036854775808.0 }));
    try testing.expectEqualStrings("1114111", try fixture.encodeValue(cat, types.Type.char32, types.characterValue(types.Type.char32, 0x10FFFF)));
}

test "a failed decode builds nothing and a deep text fails rather than overflow" {
    // 4: []i64, 5: option([]i64), 6: [][]i64... built as an array of itself is not a type, so
    // depth is shown with an array of arrays of arrays.
    const definitions = [_]types.Definition{ .{ .array = .i64 }, .{ .array = @fromBackingInt(4) }, .{ .option = @fromBackingInt(5) }, .{ .option = .string } };
    const cat = testCatalogue(&definitions, &.{}, &.{}, &.{}, "", &.{}, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const used = fixture.pool.used;
    const failed = try fixture.decodeText(cat, @fromBackingInt(6), "[[1,2],[3,\"x\"]]");
    try testing.expectEqual(@as(u32, 0), failed.aggregate.elements.end - failed.aggregate.elements.start);
    try testing.expectEqual(@as(usize, 0), fixture.count);
    try testing.expectEqual(used, fixture.pool.used);
    const good = try fixture.decodeText(cat, @fromBackingInt(6), "[[1,2],[],[3]]");
    // Each inner array's members, then the outer array's, then the option's.
    try testing.expectEqual(@as(usize, 3 + 3 + 1), fixture.count);
    try testing.expectEqualStrings("[[1,2],[],[3]]", try fixture.encodeValue(cat, @fromBackingInt(5), fixture.members[good.aggregate.elements.start]));
    // A string decoded and then the failure of what follows drops its bytes too.
    const before = fixture.pool.used;
    _ = try fixture.decodeText(cat, @fromBackingInt(7), "\"abc\" x");
    try testing.expectEqual(before, fixture.pool.used);
}

test "objects read in any order with defaults, maps refuse equal keys, instances are built last" {
    // Source of the names: "point X Y node Next mode Easy Hard".
    const source = "point X Y node Next mode Easy Hard";
    const span = struct {
        fn of(start: u32, end: u32) types.Span {
            return .{ .start = start, .end = end };
        }
    }.of;
    const point: types.Type = @fromBackingInt(4);
    const node: types.Type = @fromBackingInt(5);
    const option_node: types.Type = @fromBackingInt(6);
    const mode: types.Type = @fromBackingInt(7);
    const map: types.Type = @fromBackingInt(8);
    const option_point: types.Type = @fromBackingInt(9);
    const option_map: types.Type = @fromBackingInt(10);
    const fields = [_]types.Field{
        .{ .name = span(6, 7), .value_type = .float, .constant = 0 },
        .{ .name = span(8, 9), .value_type = .float },
        .{ .name = span(15, 19), .value_type = option_node, .constant = 1 },
    };
    const definitions = [_]types.Definition{
        .{ .record = .{ .name = span(0, 5), .fields = span(0, 2), .is_public = false, .persistable = true } },
        .{ .class = .{ .name = span(10, 14), .fields = span(2, 3), .is_public = false, .is_final = true, .persistable = true } },
        .{ .option = node },
        .{ .enumeration = .{ .name = span(20, 24), .cases = span(0, 2), .is_public = false, .persistable = true } },
        .{ .map = .{ .key = .float, .value = mode } },
        .{ .option = point },
        .{ .option = map },
        .{ .option = option_node },
    };
    const cases = [_]types.Span{ span(25, 29), span(30, 34) };
    const constants = [_]types.Constant{ .{ .value_type = .float, .kind = .{ .floating = 0.5 } }, .{ .value_type = option_node, .kind = .{ .aggregate = span(0, 0) } } };
    const cat = testCatalogue(&definitions, &fields, &.{}, &cases, source, &constants, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Members in any order, whitespace, metadata absent or right: the default fills X.
    const got = try fixture.decodeText(cat, option_point, " { \"x_Y\" : 2 , \"$class_name\":\"point\" } ");
    const value = fixture.members[got.aggregate.elements.start];
    try testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"point\",\"x_X\":0.5,\"x_Y\":2}", try fixture.encodeValue(cat, point, value));
    for ([_][]const u8{
        "{\"x_Y\":2,\"x_Y\":3}",
        "{\"x_Y\":2,\"x_Z\":3}",
        "{\"x_X\":1}",
        "{\"x_Y\":2,\"$class_name\":\"other\"}",
        "{\"x_Y\":2,\"$package_name\":\"/elsewhere\"}",
        "{\"x_Y\":2,\"$class_name\":\"point\",\"$class_name\":\"point\"}",
    }) |text| {
        const refused = try fixture.decodeText(cat, option_point, text);
        try testing.expectEqual(refused.aggregate.elements.start, refused.aggregate.elements.end);
    }
    // A chain of instances: the innermost is built first, and the encoder reads each field.
    const chain = try fixture.decodeText(cat, option_node, "{\"x_Next\":{\"\":{}}}");
    const outer = fixture.members[chain.aggregate.elements.start];
    try testing.expectEqual(@as(u32, 2), fixture.host.instances);
    try testing.expectEqual(@as(u32, 2), fixture.host.cells[outer.object.id + 1].aggregate.elements.end - fixture.host.cells[outer.object.id + 1].aggregate.elements.start + 1);
    try testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Next\":{\"\":{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Next\":false}}}", try fixture.encodeValue(cat, node, outer));
    // Nested exactly as deep as `json_depth` allows, and one container more: an option around
    // a chain whose links are an object and an option each, the innermost an object.
    for ([_]u32{ json_depth / 2 - 1, json_depth / 2 }) |links| {
        const deep = scratch.alloc(u8, links * 20 + 8) orelse return error.OutOfMemory;
        defer scratch.free(deep);
        var length: usize = 0;
        @memcpy(deep[0..4], "{\"\":");
        length += 4;
        for (0..links) |_| {
            @memcpy(deep[length..][0..14], "{\"x_Next\":{\"\":");
            length += 14;
        }
        @memcpy(deep[length..][0..2], "{}");
        length += 2;
        for (0..links) |_| {
            @memcpy(deep[length..][0..2], "}}");
            length += 2;
        }
        deep[length] = '}';
        length += 1;
        fixture.count = 0;
        fixture.host.count = 0;
        const read = try fixture.decodeText(cat, @fromBackingInt(11), deep[0..length]);
        // 2 * links + 2 containers: exactly the limit for the first, beyond it for the second.
        try testing.expectEqual(links == json_depth / 2 - 1, read.aggregate.elements.end != read.aggregate.elements.start);
        if (links == json_depth / 2 - 1) {
            const deepest = fixture.members[read.aggregate.elements.start];
            const written = try fixture.encodeValue(cat, @fromBackingInt(6), deepest);
            // What the encoder writes of it is as deep, and reads back.
            const again = try fixture.decodeText(cat, @fromBackingInt(11), written);
            try testing.expect(again.aggregate.elements.end != again.aggregate.elements.start);
        }
    }
    // Maps: entries with their members in either order; equal keys (one zero, -0) refused.
    const entries = try fixture.decodeText(cat, option_map, "[{\"v\":{\"\":\"mode::Hard\"},\"k\":{\"\":1.5}},{\"k\":{\"\":\"NaN\"},\"v\":{\"\":\"mode::Easy\"}}]");
    try testing.expectEqualStrings("[{\"k\":{\"\":1.5},\"v\":{\"\":\"mode::Hard\"}},{\"k\":{\"\":\"NaN\"},\"v\":{\"\":\"mode::Easy\"}}]", try fixture.encodeValue(cat, map, fixture.members[entries.aggregate.elements.start]));
    for ([_][]const u8{
        "[{\"k\":{\"\":0},\"v\":{\"\":\"mode::Easy\"}},{\"k\":{\"\":-0},\"v\":{\"\":\"mode::Hard\"}}]",
        "[{\"k\":{\"\":0}}]",
        "[{\"k\":1,\"v\":{\"\":\"mode::Easy\"}}]",
        "[{\"k\":{\"\":0},\"v\":{\"\":\"mode::Expert\"}}]",
        "[{\"k\":{\"\":0},\"v\":{\"\":\"other::Easy\"}}]",
        "[{\"k\":{\"\":0},\"v\":{\"\":\"Easy\"}}]",
    }) |text| {
        const refused = try fixture.decodeText(cat, option_map, text);
        try testing.expectEqual(refused.aggregate.elements.start, refused.aggregate.elements.end);
    }
}

test "a map entry's object and wrappers count: a map at the limit is written and read, one deeper is refused (review D1)" {
    const source = "node Next M";
    const span = struct {
        fn of(start: u32, end: u32) types.Span {
            return .{ .start = start, .end = end };
        }
    }.of;
    const map: types.Type = @fromBackingInt(4);
    const node: types.Type = @fromBackingInt(5);
    const option_node: types.Type = @fromBackingInt(6);
    const fields = [_]types.Field{
        .{ .name = span(5, 9), .value_type = option_node },
        .{ .name = span(10, 11), .value_type = map },
    };
    const definitions = [_]types.Definition{
        .{ .map = .{ .key = .i64, .value = .i64 } },
        .{ .class = .{ .name = span(0, 4), .fields = span(0, 2), .is_public = false, .is_final = true, .persistable = true } },
        .{ .option = node },
    };
    const cat = testCatalogue(&definitions, &fields, &.{}, &.{}, source, &.{}, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Each link is an object and an option; the innermost holds a map of one entry of scalars,
    // whose entry object and wrapper are two containers more than its `[`.
    for ([_]u32{ json_depth / 2 - 1, json_depth / 2 }) |links| {
        fixture.host.count = 0;
        fixture.members[0] = .{ .integer = 1 };
        fixture.members[1] = .{ .integer = 2 };
        fixture.count = 2;
        const full_map: types.Value = .{ .aggregate = .{ .value_type = map, .elements = span(0, 2) } };
        const empty_map: types.Value = .{ .aggregate = .{ .value_type = map, .elements = span(2, 2) } };
        var inner: ?types.Value = null;
        for (0..links) |_| {
            var next: types.Value = .{ .aggregate = .{ .value_type = option_node, .elements = span(@intCast(fixture.count), @intCast(fixture.count)) } };
            if (inner) |object| {
                fixture.members[fixture.count] = object;
                next = .{ .aggregate = .{ .value_type = option_node, .elements = span(@intCast(fixture.count), @intCast(fixture.count + 1)) } };
                fixture.count += 1;
            }
            const cells = [_]types.Value{ .{ .integer = @backingInt(node) }, next, if (inner == null) full_map else empty_map };
            inner = .{ .object = .{ .value_type = node, .id = try fixture.host.instance(node, &cells, 0) } };
        }
        if (links == json_depth / 2) {
            try testing.expectError(error.DepthLimit, fixture.encodeValue(cat, node, inner.?));
            continue;
        }
        const written = try fixture.encodeValue(cat, node, inner.?);
        fixture.host.count = 0;
        fixture.count = 0;
        const read = try fixture.decodeText(cat, option_node, written);
        try testing.expect(read.aggregate.elements.end != read.aggregate.elements.start);
    }
}

test "fuel: a text that fails pays for what was read of it, and a valid one for its bytes once (review D2)" {
    const definitions = [_]types.Definition{ .{ .option = .i64 }, .{ .option = .string }, .{ .array = .i64 }, .{ .option = @fromBackingInt(6) } };
    const cat = testCatalogue(&definitions, &.{}, &.{}, &.{}, "", &.{}, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const spaces = 16 * 1024;
    const text = try testing.allocator.alloc(u8, spaces + 2);
    defer testing.allocator.free(text);
    @memset(text, ' ');
    const Case = struct { option: u16, last: []const u8, cost: u64 };
    // 2 for the decode, and one unit per 8 bytes read; a valid array of 2 members, 3 more
    // (its members and the option's).
    for ([_]Case{
        .{ .option = 4, .last = "x", .cost = 2 + (spaces + 1) / 8 },
        .{ .option = 4, .last = "1", .cost = 2 + (spaces + 1) / 8 + 1 },
        .{ .option = 5, .last = " ", .cost = 2 + (spaces + 1) / 8 },
        .{ .option = 7, .last = "[", .cost = 2 + (spaces + 1) / 8 },
    }) |case| {
        @memcpy(text[spaces..][0..case.last.len], case.last);
        // An unterminated string: the text is all read before it fails.
        if (case.option == 5) {
            text[0] = '"';
        } else text[0] = ' ';
        var remaining: u64 = 1 << 40;
        _ = try decode(cat, &fixture.host, .{ .slots = fixture.members, .count = &fixture.count }, @fromBackingInt(case.option), text[0 .. spaces + case.last.len], &fixture.pool, fixture.stack, &fixture.work, &remaining);
        try testing.expectEqual(case.cost, (1 << 40) - remaining);
    }
    // Four elements, each read once though the text is read twice: 2, the bytes, 4 members
    // and the array's and the option's member.
    var remaining: u64 = 1 << 40;
    fixture.count = 0;
    const array = "[1,2,3,4]";
    _ = try decode(cat, &fixture.host, .{ .slots = fixture.members, .count = &fixture.count }, @fromBackingInt(7), array, &fixture.pool, fixture.stack, &fixture.work, &remaining);
    try testing.expectEqual(@as(u64, 2 + array.len / 8 + 4 + 1), (1 << 40) - remaining);
}

test "a text that does not decode builds nothing and meets no capacity, however large (review)" {
    const definitions = [_]types.Definition{ .{ .array = .string }, .{ .option = @fromBackingInt(4) } };
    const cat = testCatalogue(&definitions, &.{}, &.{}, &.{}, "", &.{}, &.{});
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // More elements than the fixture's member pool holds, and more string bytes than its string
    // pool: a valid text would end with a capacity, this one fails at its last byte.
    const elements = fixture.members.len + 10;
    const text = try testing.allocator.alloc(u8, 1 + elements * 33 + 3);
    defer testing.allocator.free(text);
    var at: usize = 0;
    text[at] = '[';
    at += 1;
    for (0..elements) |_| {
        @memcpy(text[at..][0..33], "\"abcdefghijklmnopqrstuvwxyz0123\",");
        at += 33;
    }
    @memcpy(text[at..][0..3], "1]x");
    at += 3;
    const used = fixture.pool.used;
    var remaining: u64 = 1 << 40;
    const got = try decode(cat, &fixture.host, .{ .slots = fixture.members, .count = &fixture.count }, @fromBackingInt(5), text[0..at], &fixture.pool, fixture.stack, &fixture.work, &remaining);
    try testing.expectEqual(got.aggregate.elements.start, got.aggregate.elements.end);
    try testing.expectEqual(@as(usize, 0), fixture.count);
    try testing.expectEqual(used, fixture.pool.used);
    // The same elements in a valid text need more members than there are: that is fatal.
    text[at - 3] = '"';
    text[at - 2] = '"';
    text[at - 1] = ']';
    if (decode(cat, &fixture.host, .{ .slots = fixture.members, .count = &fixture.count }, @fromBackingInt(5), text[0..at], &fixture.pool, fixture.stack, &fixture.work, &remaining)) |_| return error.TestUnexpectedResult else |err| try testing.expect(err == error.StringLimit or err == error.AggregateLimit);
}

test "a default nested as deep as a catalogue allows, at the bottom of a text nested near the limit, fits the stack (review)" {
    const source = "node Next D";
    const span = struct {
        fn of(start: u32, end: u32) types.Span {
            return .{ .start = start, .end = end };
        }
    }.of;
    const nesting = 200;
    // node, option(node), then option(i64), option(option(i64)), ... `nesting` deep.
    var definitions: [2 + nesting]types.Definition = undefined;
    const node: types.Type = @fromBackingInt(4);
    const option_node: types.Type = @fromBackingInt(5);
    const deepest: types.Type = @fromBackingInt(4 + 2 + nesting - 1);
    var constants: [nesting + 2]types.Constant = undefined;
    var members: [nesting]u32 = undefined;
    constants[0] = .{ .value_type = .i64, .kind = .{ .integer = 7 } };
    for (0..nesting) |level| {
        definitions[2 + level] = .{ .option = if (level == 0) .i64 else @fromBackingInt(@as(u16, @intCast(4 + 2 + level - 1))) };
        members[level] = @intCast(level);
        constants[level + 1] = .{ .value_type = @fromBackingInt(@as(u16, @intCast(4 + 2 + level))), .kind = .{ .aggregate = span(@intCast(level), @intCast(level + 1)) } };
    }
    constants[nesting + 1] = .{ .value_type = option_node, .kind = .{ .aggregate = span(nesting, nesting) } };
    const fields = [_]types.Field{
        .{ .name = span(5, 9), .value_type = option_node, .constant = nesting + 1 },
        .{ .name = span(10, 11), .value_type = deepest, .constant = nesting },
    };
    definitions[0] = .{ .class = .{ .name = span(0, 4), .fields = span(0, 2), .is_public = false, .is_final = true, .persistable = true } };
    definitions[1] = .{ .option = node };
    const cat = testCatalogue(&definitions, &fields, &.{}, &.{}, source, &constants, &members);
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // 2 * links + 1 containers: one fewer than the limit; the innermost link's default then
    // takes `nesting` frames more.
    const links = json_depth / 2 - 1;
    // Every link but the innermost gives its default field an empty option.
    const text = try testing.allocator.alloc(u8, links * 32 + 64);
    defer testing.allocator.free(text);
    var at: usize = 0;
    const link = "{\"x_D\":false,\"x_Next\":{\"\":";
    for (0..links) |_| {
        @memcpy(text[at..][0..link.len], link);
        at += link.len;
    }
    @memcpy(text[at..][0..2], "{}");
    at += 2;
    for (0..links) |_| {
        @memcpy(text[at..][0..2], "}}");
        at += 2;
    }
    const got = try fixture.decodeText(cat, option_node, text[0..at]);
    try testing.expect(got.aggregate.elements.end != got.aggregate.elements.start);
    try testing.expectEqual(@as(u32, links + 1), fixture.host.instances);
}
