//! Bounded compile-time templates for explicitly typed pure functions.
//! All function bodies are typed before publication; calls expand iteratively.
const std = @import("std");
const types = @import("types.zig");
const modules = @import("modules.zig");
const name_index = @import("name_index.zig");

pub const Parameter = struct { name: types.Span, value_type: types.Type };
/// A typed expression template. An empty range denotes a field without a
/// default; published bodies always contain their root. No function-name slot
/// or runtime frame is needed to instantiate one.
pub const Body = struct { start: u32 = 0, end: u32 = 0, root: u32 = 0, work: u32 = 0 };
comptime {
    // Body ranges are u32 like every other IR index; only the work counter needs the sum.
    std.debug.assert(types.limits.template_nodes + types.limits.aggregate_elements <= std.math.maxInt(u32));
    std.debug.assert(@sizeOf(Body) == 16);
}
pub const Definition = struct {
    name: types.Span,
    parameters: [types.limits.parameters]Parameter = undefined,
    parameter_count: u32 = 0,
    /// Template of each parameter's default value; an empty body means the argument is required.
    defaults: [types.limits.parameters]Body = @splat(.{}),
    value_type: types.Type,
    is_public: bool,
    anonymous: bool = false,
    specialization: ?types.Type = null,
    generic_source: types.Span = .{ .start = 0, .end = 0 },
    template_public: bool = false,
    decides: bool = false,
    transacts: bool = false,
    /// The rest of the declared effect (RFC-0078): heap effects given up, `suspends`.
    detail: types.EffectDetail = .{},
    /// Another function of the same module has this name and different parameter types.
    overloaded: bool = false,
    /// A method of a class: its receiver is the first parameter, and it is reached through the class, not by name.
    is_method: bool = false,
    /// Declared `(Receiver:type).Name(...)`: an ordinary function whose first parameter is the
    /// receiver, called only as `Value.Name(...)`. Every definition of its name is one.
    is_extension: bool = false,
    /// Declared `Name<constructor>(...)`: its body is one archetype of its class, whose field
    /// values an archetype of that class or of a subclass can take over (RFC-0075).
    is_constructor: bool = false,
    /// For a constructor function: the template node where the defaults of the fields its
    /// archetype was not given begin. Delegation takes over the values computed before it.
    given: u32 = 0,
    /// Declared `Name(...)<effects> := Body` (RFC-0085, I7): the result type is the body's,
    /// known once the body is compiled; the body cannot name the function or `Return`.
    is_transparent: bool = false,
    runtime: ?u32 = null,
    alias_runtime: ?u32 = null,
    start: u32,
    end: u32,
    root: u32,
    work: u32 = 0,
    /// RFC-0091 (B3): the entries of `Workspace.patterns` that destructure its tuple parameters,
    /// whose elements its body names as locals.
    patterns: types.Span = .{ .start = 0, .end = 0 },
};
pub const Template = types.FunctionNode;
pub const Storage = struct {
    definitions: [types.limits.functions]Definition = undefined,
    /// The functions by name and scope, in a table that grows with them (`name_index.Table`):
    /// `symbols` is its storage, of which `table` says how much is live, and `homes` is the
    /// hash each definition was published under, for when a table grows.
    symbols: [name_index.slotCount(types.limits.functions).?]u32 = undefined,
    table: name_index.Table = .{},
    homes: [types.limits.functions]u64 = undefined,
    /// The methods are listed apart, so that the many methods a program names alike (`Update`,
    /// `ToString`) lengthen no walk of the functions. Their table has one entry for each name
    /// and scope, the first method published under it; `method_next` links the methods of one
    /// name in the order they were published, and `method_last`, at that first method, is the
    /// newest of them. It is `none` at every other definition.
    method_symbols: [name_index.slotCount(types.limits.functions).?]u32 = undefined,
    method_table: name_index.Table = .{},
    method_next: [types.limits.functions]u32 = undefined,
    method_last: [types.limits.functions]u32 = undefined,
    nodes: [types.limits.template_nodes]Template = undefined,
    mapping: [types.limits.template_nodes]u32 = undefined,
    members: [types.limits.aggregate_elements]u32 = undefined,
    arguments: [types.limits.call_arguments]u32 = undefined,
    argument_count: u32 = 0,
    member_count: u32 = 0,
    count: u32 = 0,
    /// Published methods. `find` passes them over: a method is reached through its class.
    method_count: u32 = 0,
    node_count: u32 = 0,
    /// Where the default values of instantiated types begin (RFC-0073). A parametric type can be
    /// instantiated while a function body is being compiled, and its defaults must outlive that
    /// body without lying inside it, so they are kept at the far end of each pool, growing down.
    /// Everything else is appended below these marks.
    node_top: u32 = types.limits.template_nodes,
    member_top: u32 = types.limits.aggregate_elements,
    argument_top: u32 = types.limits.call_arguments,
    /// The modules declared inside files (RFC-0074): a scope's text contains theirs, so whether
    /// a function belongs to a scope is asked with this table.
    nested: []const types.NestedModule = &.{},

    pub fn reset(self: *Storage) void {
        self.nested = &.{};
        self.count = 0;
        self.method_count = 0;
        self.node_count = 0;
        self.member_count = 0;
        self.argument_count = 0;
        self.node_top = types.limits.template_nodes;
        self.member_top = types.limits.aggregate_elements;
        self.argument_top = types.limits.call_arguments;
        // A table clears what it grows into, so starting again costs nothing.
        self.table.clear();
        self.method_table.clear();
    }

    const none = name_index.none;

    /// The first method published under `name` in `scope`.
    fn firstMethod(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) ?u32 {
        var same = self.method_table.walk(&self.method_symbols, hash(name, scope));
        while (same.next()) |index| {
            const other = &self.definitions[index];
            if (modules.contains(scope, other.name) and std.mem.eql(u8, other.name.text(source), name) and modules.owned(scope, other.name, self.nested)) return index;
        }
        return null;
    }

    fn hash(name: []const u8, scope: types.Span) u64 {
        return std.hash.Wyhash.hash(scope.start, name);
    }

    pub fn find(self: *const Storage, name: []const u8, source: []const u8) ?u32 {
        return self.findIn(name, source, .{ .start = 0, .end = @intCast(source.len) });
    }
    pub fn findIn(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) ?u32 {
        std.debug.assert(self.count <= self.definitions.len);
        // Tiny namespaces avoid hashing; larger namespaces use bounded probes.
        if (self.count <= 4) {
            for (self.definitions[0..self.count], 0..) |*function, index| {
                if (!function.is_method and modules.contains(scope, function.name) and std.mem.eql(u8, function.name.text(source), name) and modules.owned(scope, function.name, self.nested)) return @intCast(index);
            }
            return null;
        }
        // Preserve the fast path for the first/common helper in large modules.
        if (!self.definitions[0].is_method and modules.contains(scope, self.definitions[0].name) and std.mem.eql(u8, self.definitions[0].name.text(source), name) and modules.owned(scope, self.definitions[0].name, self.nested)) return 0;
        var same = self.table.walk(&self.symbols, hash(name, scope));
        while (same.next()) |index| {
            std.debug.assert(index < self.count);
            if (!self.definitions[index].is_method and modules.contains(scope, self.definitions[index].name) and std.mem.eql(u8, self.definitions[index].name.text(source), name) and modules.owned(scope, self.definitions[index].name, self.nested)) return index;
        }
        return null;
    }

    /// Debug builds check a walk of namesakes against reading every definition in order.
    fn namesakesAgree(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) bool {
        var listed: Namesakes = .{ .storage = self, .name = name, .source = source, .scope = scope, .same = self.table.walk(&self.symbols, hash(name, scope)), .method = self.firstMethod(name, source, scope) orelse none };
        for (self.definitions[0..self.count], 0..) |*other, index| {
            if (!modules.contains(scope, other.name) or !std.mem.eql(u8, other.name.text(source), name) or !modules.owned(scope, other.name, self.nested)) continue;
            if (listed.next() != @as(?u32, @intCast(index))) return false;
        }
        return listed.next() == null;
    }

    /// The definitions named `name` in `scope`, methods among them, in the order they were
    /// published. A declaration and a call of an overloaded name ask for these; reading every
    /// definition each time cost the square of the number of functions.
    pub fn namesakes(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) Namesakes {
        if (@import("builtin").mode == .debug) std.debug.assert(self.namesakesAgree(name, source, scope));
        return .{ .storage = self, .name = name, .source = source, .scope = scope, .same = self.table.walk(&self.symbols, hash(name, scope)), .method = self.firstMethod(name, source, scope) orelse none };
    }
    /// The functions named `name` in `scope`, without its methods: the candidates of a call
    /// with no receiver. A method is reached only through one.
    pub fn functionNamesakes(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) Namesakes {
        var walk = self.namesakes(name, source, scope);
        walk.method = none;
        return walk;
    }
    pub const Namesakes = struct {
        storage: *const Storage,
        name: []const u8,
        source: []const u8,
        scope: types.Span,
        same: name_index.Table.Walk,
        /// The next function and the next method of the name still to be given; `none` when
        /// there is no more of that kind. The function is read when it is first needed.
        function: u32 = unread,
        method: u32,

        const unread = none - 1;

        pub fn next(self: *Namesakes) ?u32 {
            // The functions of one name in one scope lie in their table in the order they were
            // published, and so do its methods along their links: the two lists are merged.
            // Reading every definition once a method existed cost the square of their number.
            if (self.function == unread) self.function = self.nextFunction();
            if (self.function == none and self.method == none) return null;
            if (self.method == none or (self.function != none and self.function < self.method)) {
                const index = self.function;
                self.function = self.nextFunction();
                return index;
            }
            const index = self.method;
            self.method = self.storage.method_next[index];
            return index;
        }
        fn nextFunction(self: *Namesakes) u32 {
            while (self.same.next()) |index| if (self.matches(index)) return index;
            return none;
        }
        fn matches(self: *const Namesakes, index: usize) bool {
            const other = &self.storage.definitions[index];
            return modules.contains(self.scope, other.name) and std.mem.eql(u8, other.name.text(self.source), self.name) and modules.owned(self.scope, other.name, self.storage.nested);
        }
    };

    pub fn publish(self: *Storage, function: Definition, source: []const u8) void {
        return self.publishIn(function, source, .{ .start = 0, .end = @intCast(source.len) });
    }
    pub fn publishIn(self: *Storage, function: Definition, source: []const u8, scope: types.Span) void {
        std.debug.assert(self.count < self.definitions.len);
        std.debug.assert(modules.within(scope, function.name, self.nested));
        var published = function;
        const text = function.name.text(source);
        const home = hash(text, scope);
        const index = self.count;
        self.homes[index] = home;
        self.method_next[index] = none;
        self.method_last[index] = none;
        if (function.is_method) {
            if (self.firstMethod(text, source, scope)) |first| {
                // Behind the newest method of its name.
                self.method_next[self.method_last[first]] = index;
                self.method_last[first] = index;
            } else {
                if (self.method_table.crowded()) {
                    self.method_table.grow(&self.method_symbols);
                    for (self.method_last[0..index], self.homes[0..index], 0..) |last, earlier, at| {
                        if (last != none) self.method_table.enter(&self.method_symbols, earlier, @intCast(at));
                    }
                }
                self.method_last[index] = index;
                self.method_table.enter(&self.method_symbols, home, index);
            }
            self.definitions[index] = published;
            self.count += 1;
            self.method_count += 1;
            std.debug.assert(self.count <= types.limits.functions);
            return;
        }
        std.debug.assert(function.parameter_count <= function.parameters.len);
        std.debug.assert(function.start <= function.root and function.root < function.end);
        std.debug.assert(function.end <= self.node_count);
        std.debug.assert(self.nodes[function.root].node.value_type == function.value_type);
        // A second definition of a name is an overload (the compiler has checked the
        // signatures differ). Every function is published under the scope that holds its
        // name, so the earlier definitions of this name were entered under this hash:
        // walking them finds them all, where a scan of every definition cost the square of
        // their number.
        var same = self.table.walk(&self.symbols, home);
        while (same.next()) |earlier| {
            const other = &self.definitions[earlier];
            std.debug.assert(!other.is_method);
            if (modules.contains(scope, other.name) and std.mem.eql(u8, other.name.text(source), text) and modules.owned(scope, other.name, self.nested)) {
                other.overloaded = true;
                published.overloaded = true;
            }
        }
        if (self.table.crowded()) {
            self.table.grow(&self.symbols);
            for (self.definitions[0..index], self.homes[0..index], 0..) |*earlier, earlier_home, at| {
                if (!earlier.is_method) self.table.enter(&self.symbols, earlier_home, @intCast(at));
            }
        }
        self.definitions[index] = published;
        self.table.enter(&self.symbols, home, index);
        self.count += 1;
        std.debug.assert(self.count <= types.limits.functions);
    }
};

test "namesakes are every definition of a name in its scope, in order, with and without methods" {
    const scratch = @import("scratch.zig");
    const storage = try scratch.storage(Storage);
    defer scratch.release(storage);
    scratch.initialise(storage);
    storage.reset();
    // Two scopes, as two modules joined by a newline: "Aa Bb Aa Cc Aa" and "Aa Bb".
    const source = "Aa Bb Aa Cc Aa\nAa Bb";
    const first: types.Span = .{ .start = 0, .end = 14 };
    const second: types.Span = .{ .start = 15, .end = 20 };
    storage.nodes[0] = .{ .node = .{ .span = .{ .start = 0, .end = 2 }, .value_type = .i64, .kind = .{ .integer = 0 } } };
    storage.node_count = 1;
    const starts = [_]u32{ 0, 3, 6, 9, 15, 18, 12 };
    for (starts) |start| {
        const scope = if (start < 15) first else second;
        storage.publishIn(.{ .name = .{ .start = start, .end = start + 2 }, .value_type = .i64, .is_public = false, .start = 0, .end = 1, .root = 0 }, source, scope);
    }
    const Case = struct { name: []const u8, scope: types.Span, expected: []const u32 };
    const cases = [_]Case{
        .{ .name = "Aa", .scope = first, .expected = &.{ 0, 2, 6 } },
        .{ .name = "Bb", .scope = first, .expected = &.{1} },
        .{ .name = "Cc", .scope = first, .expected = &.{3} },
        .{ .name = "Aa", .scope = second, .expected = &.{4} },
        .{ .name = "Bb", .scope = second, .expected = &.{5} },
        .{ .name = "Cc", .scope = second, .expected = &.{} },
        .{ .name = "Dd", .scope = first, .expected = &.{} },
    };
    for (cases) |case| {
        var found = storage.namesakes(case.name, source, case.scope);
        for (case.expected) |index| try std.testing.expectEqual(@as(?u32, index), found.next());
        try std.testing.expect(found.next() == null);
    }
    // The three definitions of one name were marked as overloads of each other; no other was.
    for (storage.definitions[0..storage.count], 0..) |definition, index| try std.testing.expectEqual(index == 0 or index == 2 or index == 6, definition.overloaded);

    // A method is listed apart from the functions: it is among the namesakes of its name, where
    // the order of publication puts it, and `find` never answers with it.
    storage.publishIn(.{ .name = .{ .start = 3, .end = 5 }, .value_type = .i64, .is_public = false, .is_method = true, .start = 0, .end = 1, .root = 0 }, source, first);
    try std.testing.expectEqual(@as(u32, 1), storage.method_count);
    for (cases) |case| {
        var found = storage.namesakes(case.name, source, case.scope);
        for (case.expected) |index| try std.testing.expectEqual(@as(?u32, index), found.next());
        if (case.scope.start == 0 and std.mem.eql(u8, case.name, "Bb")) try std.testing.expectEqual(@as(?u32, 7), found.next());
        try std.testing.expect(found.next() == null);
    }
    try std.testing.expect(!storage.definitions[1].overloaded and !storage.definitions[7].overloaded);
    try std.testing.expectEqual(@as(?u32, 1), storage.findIn("Bb", source, first));
    // A function published after the method is no overload of it, and both are namesakes.
    storage.publishIn(.{ .name = .{ .start = 9, .end = 11 }, .value_type = .i64, .is_public = false, .is_method = true, .start = 0, .end = 1, .root = 0 }, source, first);
    var both = storage.namesakes("Cc", source, first);
    try std.testing.expectEqual(@as(?u32, 3), both.next());
    try std.testing.expectEqual(@as(?u32, 8), both.next());
    try std.testing.expect(both.next() == null);
    try std.testing.expect(!storage.definitions[3].overloaded);
    // Enough definitions to grow the table several times: every one is still found, in order.
    const live_before = storage.table.live;
    var published: u32 = storage.count;
    while (published < @min(types.limits.functions, 60)) : (published += 1) {
        storage.publishIn(.{ .name = .{ .start = 18, .end = 20 }, .value_type = .i64, .is_public = false, .start = 0, .end = 1, .root = 0 }, source, second);
    }
    try std.testing.expect(storage.table.live > live_before and storage.table.used == storage.count - storage.method_count);
    try std.testing.expectEqual(@as(u32, 2), storage.method_table.used);
    var many = storage.namesakes("Bb", source, second);
    try std.testing.expectEqual(@as(?u32, 5), many.next());
    var expected: u32 = 9;
    while (many.next()) |index| : (expected += 1) try std.testing.expectEqual(expected, index);
    try std.testing.expectEqual(storage.count, expected);
    try std.testing.expectEqual(@as(?u32, 0), storage.findIn("Aa", source, first));
    try std.testing.expectEqual(@as(?u32, 4), storage.findIn("Aa", source, second));
    // Starting again touches no slot: the table is empty until something is published.
    storage.reset();
    try std.testing.expectEqual(@as(u32, 0), storage.method_count);
    try std.testing.expectEqual(@as(u32, 0), storage.table.live);
    try std.testing.expectEqual(@as(u32, 0), storage.method_table.live);
    var none_left = storage.namesakes("Aa", source, first);
    try std.testing.expect(none_left.next() == null);
}

test "methods of one name are linked in order and merged with the functions of that name" {
    const scratch = @import("scratch.zig");
    const storage = try scratch.storage(Storage);
    defer scratch.release(storage);
    scratch.initialise(storage);
    storage.reset();
    // One scope; `Aa` is declared five times and `Bb` once, methods and functions in turn.
    const source = "Aa Aa Aa Aa Aa Bb";
    const scope: types.Span = .{ .start = 0, .end = source.len };
    storage.nodes[0] = .{ .node = .{ .span = .{ .start = 0, .end = 2 }, .value_type = .i64, .kind = .{ .integer = 0 } } };
    storage.node_count = 1;
    const methods = [_]bool{ true, false, true, true, false, true };
    for (methods, 0..) |is_method, at| {
        const start: u32 = @intCast(3 * at);
        storage.publishIn(.{ .name = .{ .start = start, .end = start + 2 }, .value_type = .i64, .is_public = false, .is_method = is_method, .start = 0, .end = 1, .root = 0 }, source, scope);
    }
    var all = storage.namesakes("Aa", source, scope);
    for (0..5) |index| try std.testing.expectEqual(@as(?u32, @intCast(index)), all.next());
    try std.testing.expect(all.next() == null);
    var other = storage.namesakes("Bb", source, scope);
    try std.testing.expectEqual(@as(?u32, 5), other.next());
    try std.testing.expect(other.next() == null);
    // The functions are overloads of each other; a method is an overload of nothing, and
    // `find` gives the first function, never a method.
    try std.testing.expect(storage.definitions[1].overloaded and storage.definitions[4].overloaded);
    for ([_]usize{ 0, 2, 3, 5 }) |index| try std.testing.expect(!storage.definitions[index].overloaded);
    try std.testing.expectEqual(@as(?u32, 1), storage.findIn("Aa", source, scope));
    try std.testing.expect(storage.findIn("Bb", source, scope) == null);
    // One entry of the method table for each name, however many methods share it.
    try std.testing.expectEqual(@as(u32, 2), storage.method_table.used);
    try std.testing.expectEqual(@as(u32, 2), storage.table.used);
}
