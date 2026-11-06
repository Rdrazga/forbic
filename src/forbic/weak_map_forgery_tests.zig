//! Forged IR around `weak_map(K, V)` (RFC-0087, P5.1, admission rule 1 and the `weak_map` row
//! of "Forged IR"): every case is refused by both machines' admissions, each in its own code,
//! and by the report replay, which admits the program again before it replays. Each is made
//! from a program that runs by changing one thing, and where the same change on a `map` is
//! valid, that program is shown to run too, so that the `weak_map` is what is refused.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// Every operation a `weak_map` is given or refused, at the root, where a node's operands are
/// earlier root nodes: a map `M` and its upcast `W`, a literal built at the `weak_map` type, a
/// lookup of each, an update of a top-level `var` cell, and the map operations a `weak_map`
/// does not have, applied to `M`.
const base =
    \\Z0:i64=0
    \\M:map(i64,i64)=map{1=>2}
    \\W:weak_map(i64,i64)=M
    \\L:weak_map(i64,i64)=map{3=>4}
    \\Lm:option(i64)=Lookup(M,1)
    \\Lw:option(i64)=Lookup(W,1)
    \\var V:weak_map(i64,i64)=map{}
    \\set V[5]=6
    \\E:logic=M==M
    \\N:i64=M.Length
    \\C:map(i64,i64)=ConcatenateMaps(M,M)
    \\S:string="s"
    \\Y:any=any(W)
    \\Yd:weak_map(i64,i64)=map{}
    \\Put(X:weak_map(i64,i64),K:i64)<transacts>:i64=Block{var Z:weak_map(i64,i64)=X;set Z[K]=K;Attempt(Z[K],-1)}
    \\P:i64=Put(W,7)
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    definitions: std.ArrayList(types.Definition),
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .definitions = .empty,
            .program = p,
            .original = p,
        };
        try copy.definitions.appendSlice(allocator, p.definitions);
        copy.point();
        return copy;
    }
    fn point(self: *Copy) void {
        self.program.nodes = self.nodes;
        self.program.function_nodes = self.function_nodes;
        self.program.definitions = self.definitions.items;
    }
    fn free(self: *Copy) void {
        self.definitions.deinit(allocator);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        self.definitions.items.len = self.original.definitions.len;
        @memcpy(self.definitions.items, self.original.definitions);
        self.program = self.original;
        self.point();
    }
    /// Appends a definition, which takes the next type id.
    fn define(self: *Copy, item: types.Definition) !types.Type {
        try self.definitions.append(allocator, item);
        self.program.definitions = self.definitions.items;
        return @fromBackingInt(@intCast(self.definitions.items.len - 1 + catalogue.builtin_count));
    }
    /// The root node that binding `name` is bound to.
    fn bound(self: *const Copy, name: []const u8) u32 {
        for (self.original.bindings) |binding| if (std.mem.eql(u8, binding.name.text(self.original.source), name)) return binding.node;
        unreachable;
    }
    /// The `nth` root node of `kind`.
    fn root(self: *const Copy, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) u32 {
        var seen: usize = 0;
        for (self.original.nodes, 0..) |node, index| if (node.kind == kind) {
            if (seen == nth) return @intCast(index);
            seen += 1;
        };
        unreachable;
    }
    /// The `nth` node of `kind` in the body of the function `name`, as an index into the
    /// program's function nodes.
    fn body(self: *const Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) usize {
        for (self.original.functions) |f| if (std.mem.eql(u8, f.name.text(self.original.source), name)) {
            var seen: usize = 0;
            for (self.original.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
                if (seen == nth) return index;
                seen += 1;
            };
        };
        unreachable;
    }
    fn typeOf(self: *const Copy, node: u32) types.Type {
        return self.original.nodes[node].value_type;
    }
};

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

/// Admitted and run by both machines, on a harness of its own so that the run whose report the
/// replay reads stays as it was.
fn admitted(p: types.Program) !void {
    const h = try harness.create();
    defer scratch.release(h);
    try std.testing.expect(try h.run(p, fuel) == .ok);
}

test "weak_map forged rows: map operations it lacks, conversions back and across, keys and literals are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const m = c.bound("M");
    const w = c.bound("W");
    const map_type = c.typeOf(m);
    const weak = c.typeOf(w);
    try std.testing.expect(catalogue.isWeakMap(weak, p.definitions) and !catalogue.isWeakMap(map_type, p.definitions));
    // The program compiled what it was meant to: `W` is an upcast of `M`, `L` a literal at the
    // `weak_map` type.
    try std.testing.expectEqual(m, c.nodes[w].kind.upcast);
    try std.testing.expectEqual(weak, c.nodes[c.bound("L")].value_type);
    try std.testing.expect(c.nodes[c.bound("L")].kind == .aggregate);
    const length = c.bound("N");
    // The first position of an entry, which `M` has.
    const one = c.bound("Z0");
    try std.testing.expectEqual(@as(i64, 0), c.nodes[one].kind.integer);

    // The length of a `weak_map` (03:1112).
    c.nodes[length].kind = .{ .array_length = w };
    try refused(h, run, c.program);
    c.restore();
    // `map_key` and `map_value` (the walk of a `For`) of one, where a map's are admitted.
    for ([_]bool{ false, true }) |value| {
        c.nodes[length].kind = if (value) .{ .map_value = .{ .array = m, .index = one } } else .{ .map_key = .{ .array = m, .index = one } };
        try admitted(c.program);
        c.nodes[length].kind = if (value) .{ .map_value = .{ .array = w, .index = one } } else .{ .map_key = .{ .array = w, .index = one } };
        try refused(h, run, c.program);
        c.restore();
    }
    // Equality of a `weak_map`, with itself and with the map it was made from.
    const equal = c.bound("E");
    c.nodes[equal].kind.compare = .{ .op = .equal, .lhs = w, .rhs = w };
    try refused(h, run, c.program);
    c.restore();
    c.nodes[equal].kind.compare = .{ .op = .unequal, .lhs = c.bound("L"), .rhs = w };
    try refused(h, run, c.program);
    c.restore();
    // The removal of an entry, behind the lookup that found it (`Without`, Q11). On the map it
    // is admitted.
    const map_lookup = c.bound("Lm");
    const weak_lookup = c.bound("Lw");
    try std.testing.expect(c.nodes[map_lookup].kind == .map_lookup and c.nodes[weak_lookup].kind == .map_lookup);
    const concatenated = c.bound("C");
    c.nodes[concatenated] = .{ .span = c.nodes[concatenated].span, .value_type = map_type, .kind = .{ .map_remove = .{ .map = m, .key = map_lookup } } };
    try admitted(c.program);
    c.nodes[concatenated] = .{ .span = c.nodes[concatenated].span, .value_type = weak, .kind = .{ .map_remove = .{ .map = w, .key = weak_lookup } } };
    try refused(h, run, c.program);
    c.restore();
    // `ConcatenateMaps` of a `weak_map`: the native admits maps only.
    try std.testing.expect(c.nodes[concatenated].kind == .native_call);
    c.nodes[concatenated].kind.native_call.args[0] = w;
    try refused(h, run, c.program);
    c.restore();

    // An upcast back from a `weak_map` to its map, and a downcast, which only an instance or a
    // value held as `any` admits.
    c.nodes[length] = .{ .span = c.nodes[length].span, .value_type = map_type, .kind = .{ .upcast = w } };
    try refused(h, run, c.program);
    c.restore();
    c.nodes[length] = .{ .span = c.nodes[length].span, .value_type = map_type, .kind = .{ .downcast = w } };
    try refused(h, run, c.program);
    c.restore();
    // An upcast from `map(K, V)` to `weak_map(K, U)` and to `weak_map(U, V)`. The definitions
    // alone, which nothing uses, are admitted.
    const other_value = try c.define(.{ .weak_map = .{ .key = .i64, .value = .string } });
    const other_key = try c.define(.{ .weak_map = .{ .key = .string, .value = .i64 } });
    try admitted(c.program);
    for ([_]types.Type{ other_value, other_key }) |wrong| {
        c.nodes[w].value_type = wrong;
        try refused(h, run, c.program);
    }
    c.restore();
    // An upcast from a `weak_map` to another `weak_map`.
    c.nodes[length] = .{ .span = c.nodes[length].span, .value_type = try c.define(.{ .weak_map = .{ .key = .i64, .value = .string } }), .kind = .{ .upcast = w } };
    try refused(h, run, c.program);
    c.restore();

    // A `weak_map` whose key is not comparable: a `weak_map` itself, and a function type. A
    // map keyed by a `weak_map` is refused the same way, whether a node uses it or not.
    const unit = for (p.definitions, 0..) |item, index| {
        if (item == .tuple and item.tuple.start == item.tuple.end) break @as(?types.Type, @fromBackingInt(@as(u16, @intCast(index + catalogue.builtin_count))));
    } else null;
    try std.testing.expect(unit == null);
    _ = try c.define(.{ .weak_map = .{ .key = weak, .value = .i64 } });
    try refused(h, run, c.program);
    c.restore();
    _ = try c.define(.{ .map = .{ .key = weak, .value = .i64 } });
    try refused(h, run, c.program);
    c.restore();
    {
        const empty = try c.define(.{ .tuple = .{ .start = @intCast(p.tuple_elements.len), .end = @intCast(p.tuple_elements.len) } });
        const function = try c.define(.{ .callable = .{ .parameters = empty, .result = .i64 } });
        // A map of it is no type either; the function type alone is.
        try admitted(c.program);
        _ = try c.define(.{ .weak_map = .{ .key = function, .value = .i64 } });
        try refused(h, run, c.program);
        c.restore();
    }
    // A second definition of the same `weak_map`: one type, so one definition.
    _ = try c.define(.{ .weak_map = .{ .key = .i64, .value = .i64 } });
    try refused(h, run, c.program);
    c.restore();
    // A `weak_map` of a value type defined after it.
    _ = try c.define(.{ .weak_map = .{ .key = .i64, .value = @fromBackingInt(@as(u16, @intCast(p.definitions.len + 1 + catalogue.builtin_count))) } });
    _ = try c.define(.{ .array = .i64 });
    try refused(h, run, c.program);
    c.restore();

    // A literal at the `weak_map` type with a member of another type, and with a key and no
    // value.
    const literal = c.bound("L");
    const text = c.bound("S");
    const members = c.nodes[literal].kind.aggregate;
    const changed_members = try allocator.dupe(u32, p.members);
    defer allocator.free(changed_members);
    changed_members[members.start + 1] = text;
    c.program.members = changed_members;
    try refused(h, run, c.program);
    c.restore();

    // A downcast from `any` of a `weak_map` to its map passes admission, as every downcast from
    // `any` does, but the value is a `weak_map` (W3): both machines stop. Cast to its own type,
    // it runs.
    const held = c.bound("Y");
    const cast = c.bound("Yd");
    c.nodes[cast] = .{ .span = c.nodes[cast].span, .value_type = weak, .kind = .{ .downcast = held } };
    try admitted(c.program);
    const bindings = try allocator.dupe(types.Binding, p.bindings);
    defer allocator.free(bindings);
    for (bindings) |*binding| if (binding.node == cast) {
        binding.value_type = map_type;
    };
    c.nodes[cast].value_type = map_type;
    c.program.bindings = bindings;
    try harness.traps(h, c.program, fuel);
    c.restore();

    // A lookup of a `weak_map` with a key of another type, or typed as the value without its
    // option; an update of one with a key or a value of another type, or typed as the map.
    c.nodes[weak_lookup].kind.map_lookup.key = text;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[weak_lookup].value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
    const update = c.root(.map_set, 0);
    try std.testing.expect(catalogue.isWeakMap(c.nodes[update].value_type, p.definitions));
    c.nodes[update].kind.map_set.key = text;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[update].kind.map_set.value = text;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[update].value_type = map_type;
    try refused(h, run, c.program);
    c.restore();
    // The same in a function body, where the operand is a local.
    const set_in_body = c.body("Put", .map_set, 0);
    c.function_nodes[set_in_body].node.value_type = map_type;
    try refused(h, run, c.program);
    c.restore();
    const lookup_in_body = c.body("Put", .map_lookup, 0);
    c.function_nodes[lookup_in_body].node.value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
}

test "a forged report whose weak_map value is tagged as its map, or holds an odd member count, is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    const w = for (p.bindings) |binding| {
        if (std.mem.eql(u8, binding.name.text(p.source), "W")) break binding.node;
    } else unreachable;
    const m = p.nodes[p.nodes[w].kind.upcast].value_type;
    const values = try allocator.dupe(types.Value, run.values);
    defer allocator.free(values);
    var x = run;
    x.values = values;
    // The upcast retags the aggregate; one that kept the map's tag is no value of its place.
    try std.testing.expect(values[w] == .aggregate and values[w].aggregate.value_type == p.nodes[w].value_type);
    values[w].aggregate.value_type = m;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    values[w] = run.values[w];
    values[w].aggregate.elements.end -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}
