//! Forged IR around session cells (RFC-0087, P5.4, admission rules 3 to 5 and the "Keyed
//! cells", "Operations" and "Grants" rows of "Forged IR"): every case is refused by both
//! machines' admissions, each in its own code, and by the report replay, which admits the
//! program again before it replays. Each is made from a program that runs by changing one
//! thing; where the same change of an ordinary cell is valid, that program is shown to run too,
//! so that the keyed cell is what is refused. Forged reports follow: a session other than the
//! run's, a lookup, a declaration or a final value of the cell that the replay did not build.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const source_state = @import("source_state.zig");
const modules = @import("modules.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// A keyed cell `X` and an ordinary cell `O` of a `weak_map`, with a node of each one's type
/// before and after the declarations, a session before them, an update and a lookup of `X` at
/// the root, in a function that only reads and in one that only writes.
const base =
    \\Z0:i64=0
    \\Txt:string="s"
    \\S0:session=GetSession()
    \\Pre:option(i64)=option{}
    \\Pre2:weak_map(session,i64)=map{}
    \\var X:weak_map(session,i64)=map{}
    \\var O:weak_map(i64,i64)=map{}
    \\Post:weak_map(session,i64)=map{}
    \\PostO:weak_map(i64,i64)=map{}
    \\set O=PostO
    \\S:session=GetSession()
    \\set X[S]=1
    \\A:i64=Attempt(X[S],0)
    \\Get(K:session)<reads>:i64=Attempt(X[K],-1)
    \\Put(K:session,V:i64)<writes>:i64=Block{set X[K]=V;V}
    \\B:i64=Get(S)+Put(S,2)
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    source_cells: []types.SourceCell,
    bindings: []types.Binding,
    definitions: std.ArrayList(types.Definition),
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .source_cells = try allocator.dupe(types.SourceCell, p.source_cells),
            .bindings = try allocator.dupe(types.Binding, p.bindings),
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
        self.program.functions = self.functions;
        self.program.source_cells = self.source_cells;
        self.program.bindings = self.bindings;
        self.program.definitions = self.definitions.items;
    }
    fn free(self: *Copy) void {
        self.definitions.deinit(allocator);
        allocator.free(self.bindings);
        allocator.free(self.source_cells);
        allocator.free(self.functions);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        @memcpy(self.source_cells, self.original.source_cells);
        @memcpy(self.bindings, self.original.bindings);
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
    fn cell(self: *const Copy, name: []const u8) u32 {
        for (self.original.source_cells, 0..) |c, index| if (std.mem.eql(u8, c.name.text(self.original.source), name)) return @intCast(index);
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
    fn function(self: *const Copy, name: []const u8) usize {
        for (self.original.functions, 0..) |f, index| if (std.mem.eql(u8, f.name.text(self.original.source), name)) return index;
        unreachable;
    }
    /// The `nth` node of `kind` in the body of the function `name`.
    fn at(self: *Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) *types.FunctionNode {
        const f = self.original.functions[self.function(name)];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
            if (seen == nth) return &self.function_nodes[index];
            seen += 1;
        };
        unreachable;
    }
    /// The body place of the `nth` node of `kind` in `name`, relative to the body.
    fn place(self: *const Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) u32 {
        const f = self.original.functions[self.function(name)];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
            if (seen == nth) return @intCast(index);
            seen += 1;
        };
        unreachable;
    }
    fn parameter(self: *const Copy, name: []const u8, n: u32) u32 {
        const f = self.original.functions[self.function(name)];
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .parameter and entry.input.parameter == n) return @intCast(index);
        unreachable;
    }
    fn typeOf(self: *const Copy, node: u32) types.Type {
        return self.original.nodes[node].value_type;
    }
};

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
/// `p` with the root's counts of control and source operations taken again, so that a forged
/// node is refused for what it does and not for a count it changed.
fn recounted(p: types.Program) types.Program {
    var counted = p;
    counted.control_ops = 0;
    counted.source_ops = 0;
    for (p.nodes) |node| {
        if (types.controlOp(node)) counted.control_ops += 1;
        if (types.sourceOp(node)) counted.source_ops += 1;
    }
    return counted;
}

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
fn refused(h: *harness.Harness, run: evaluator.Execution, program: types.Program) !void {
    const forged = recounted(program);
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
    try std.testing.expect(try h.run(recounted(p), fuel) == .ok);
}

test "keyed-cell forged rows: cell operations of a keyed cell, weak operations of an ordinary one, declarations out of place and forged flags" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const x = c.cell("X");
    const o = c.cell("O");
    try std.testing.expect(p.source_cells[x].keyed == .session and p.source_cells[o].keyed == .none);
    const declaration = p.source_cells[x].initial;
    try std.testing.expect(c.nodes[declaration].kind == .weak_init and c.nodes[declaration].kind.weak_init == x);
    const keyed_type = c.typeOf(declaration);
    const ordinary_type = p.source_cells[o].value_type;
    const post = c.bound("Post");
    const post_o = c.bound("PostO");
    const pre2 = c.bound("Pre2");

    // A whole read: of the ordinary cell it is admitted, of the keyed one refused.
    c.nodes[post_o].kind = .{ .cell_read = o };
    try admitted(c.program);
    c.restore();
    c.nodes[post].kind = .{ .cell_read = x };
    try refused(h, run, c.program);
    c.restore();
    // A whole write, of a value of the cell's type.
    const write = c.root(.cell_write, 0);
    try std.testing.expectEqual(o, c.nodes[write].kind.cell_write.cell);
    c.nodes[write].kind.cell_write = .{ .cell = x, .value = post };
    c.nodes[write].value_type = keyed_type;
    try refused(h, run, c.program);
    c.restore();
    // A declaration by `cell_init`, from an earlier map of the type.
    c.nodes[declaration].kind = .{ .cell_init = .{ .cell = x, .value = pre2 } };
    try refused(h, run, c.program);
    c.restore();
    // A guard attached to it, as `set live` would.
    c.nodes[write].kind = .{ .cell_live = .{ .cell = x, .guard = post, .initialize = false } };
    c.nodes[write].value_type = keyed_type;
    try refused(h, run, c.program);
    c.restore();
    // A second `weak_init` of it.
    c.nodes[post] = .{ .span = c.nodes[declaration].span, .value_type = keyed_type, .kind = .{ .weak_init = x } };
    try refused(h, run, c.program);
    c.restore();
    // A `weak_init`, `weak_get` or `weak_set` of the ordinary cell.
    c.nodes[post_o] = .{ .span = c.original.source_cells[o].name, .value_type = ordinary_type, .kind = .{ .weak_init = o } };
    try refused(h, run, c.program);
    c.restore();
    const lookup = c.root(.weak_get, 0);
    const update = c.root(.weak_set, 0);
    const option_i64 = c.typeOf(lookup);
    c.nodes[lookup].kind.weak_get = .{ .cell = o, .key = c.bound("Z0") };
    try refused(h, run, c.program);
    c.restore();
    c.nodes[update].kind.weak_set.cell = o;
    c.nodes[update].kind.weak_set.key = c.bound("Z0");
    try refused(h, run, c.program);
    c.restore();
    // A lookup before the declaration, of an earlier session.
    const pre = c.bound("Pre");
    c.nodes[pre].kind = .{ .weak_get = .{ .cell = x, .key = c.bound("S0") } };
    try std.testing.expectEqual(option_i64, c.nodes[pre].value_type);
    try refused(h, run, c.program);
    c.restore();
    // A cell that is not what its type says: the keyed cell flagged ordinary, the ordinary one
    // flagged keyed, and a kind that does not exist.
    for ([_]types.Keyed{ .none, @fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(200)) }) |kind| {
        c.source_cells[x].keyed = kind;
        try refused(h, run, c.program);
        c.restore();
    }
    c.source_cells[o].keyed = .session;
    try refused(h, run, c.program);
    c.restore();
    // A keyed cell bound to a read of itself instead of its declaration.
    for (c.bindings) |*binding| if (binding.node == declaration) {
        binding.node = post;
    };
    try refused(h, run, c.program);
    c.restore();
    // A `weak_init` in a function, in place of a lookup.
    const get_lookup = c.at("Get", .weak_get, 0);
    get_lookup.node = .{ .span = get_lookup.node.span, .value_type = keyed_type, .kind = .{ .weak_init = x } };
    try refused(h, run, c.program);
    c.restore();
}

test "keyed-cell forged rows: a declaration inside a region at the root is refused, the same one outside a region runs" {
    const h = try harness.create();
    defer scratch.release(h);
    // In an imported file, whose cells have no binding: `Out` is a map of the cell's type made
    // outside every region, `In` one made inside a region. Each is made the cell's declaration
    // in turn, and the declaration written `map{}` a map. (A cell of the root file is refused
    // there by its binding too, which no region may hold.)
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nA:i64 = L.N" },
        .{ .path = "lib.forb", .source = "Out:weak_map(session,i64)=map{}\nN<public>:i64=Attempt(Block{In:weak_map(session,i64)=map{};1},0)\nvar X:weak_map(session,i64)=map{}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    const p = bundled.ok;
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const x = c.cell("X");
    const declaration = p.source_cells[x].initial;
    const keyed_type = c.typeOf(declaration);
    var maps: [2]u32 = undefined;
    var found: usize = 0;
    for (c.original.nodes, 0..) |node, index| if (index != declaration and node.kind == .aggregate and node.value_type == keyed_type) {
        maps[found] = @intCast(index);
        found += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    for (maps, 0..) |moved, inside| {
        c.nodes[moved] = .{ .span = c.nodes[declaration].span, .value_type = keyed_type, .kind = .{ .weak_init = x } };
        c.nodes[declaration] = .{ .span = c.nodes[declaration].span, .value_type = keyed_type, .kind = .{ .aggregate = .{ .start = 0, .end = 0 } } };
        c.source_cells[x].initial = moved;
        if (inside == 0) try admitted(c.program) else try refused(h, run, c.program);
        c.restore();
    }
}

test "keyed-cell forged rows: lookups and updates of other types, out of order, and in functions without their effect" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const x = c.cell("X");
    const keyed_type = p.source_cells[x].value_type;
    const lookup = c.root(.weak_get, 0);
    const update = c.root(.weak_set, 0);
    const option_i64 = c.typeOf(lookup);
    const z0 = c.bound("Z0");
    const text = c.bound("Txt");
    // A lookup with a key of another type, typed as the value without its option, as the map,
    // with a key after it or the node itself.
    c.nodes[lookup].kind.weak_get.key = z0;
    try refused(h, run, c.program);
    c.restore();
    for ([_]types.Type{ .i64, keyed_type, .string }) |wrong| {
        c.nodes[lookup].value_type = wrong;
        try refused(h, run, c.program);
        c.restore();
    }
    for ([_]u32{ lookup, lookup + 1 }) |key| {
        c.nodes[lookup].kind.weak_get.key = key;
        try refused(h, run, c.program);
        c.restore();
    }
    // A lookup of a cell that does not exist.
    c.nodes[lookup].kind.weak_get.cell = @intCast(p.source_cells.len);
    try refused(h, run, c.program);
    c.restore();
    // An update with a key or a value of another type, typed as the option or the map, with a
    // value after it.
    c.nodes[update].kind.weak_set.key = z0;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[update].kind.weak_set.value = text;
    try refused(h, run, c.program);
    c.restore();
    for ([_]types.Type{ option_i64, keyed_type, .string }) |wrong| {
        c.nodes[update].value_type = wrong;
        try refused(h, run, c.program);
        c.restore();
    }
    c.nodes[update].kind.weak_set.value = update;
    try refused(h, run, c.program);
    c.restore();
    // The same in function bodies, where the key is a parameter.
    c.at("Get", .weak_get, 0).node.value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
    c.at("Get", .weak_get, 0).node.kind.weak_get.key = c.place("Get", .weak_get, 0);
    try refused(h, run, c.program);
    c.restore();
    c.at("Put", .weak_set, 0).node.kind.weak_set.value = c.parameter("Put", 0);
    try refused(h, run, c.program);
    c.restore();
    c.at("Put", .weak_set, 0).node.kind.weak_set.key = c.parameter("Put", 1);
    try refused(h, run, c.program);
    c.restore();
    // A function whose lookup is of an ordinary cell of the same key and value, a cell of
    // another module being impossible in one file.
    c.at("Get", .weak_get, 0).node.kind.weak_get.cell = c.cell("O");
    try refused(h, run, c.program);
    c.restore();
    // A lookup in a function that only writes, an update in one that only reads, and either in
    // one that only computes. With every heap effect, each runs.
    const get = c.function("Get");
    const put = c.function("Put");
    for ([_]usize{ get, put }) |f| {
        c.functions[f].transacts = true;
        c.functions[f].detail = types.heapDetail(true, true, true);
        try admitted(c.program);
        c.functions[f].detail = if (f == get) types.heapDetail(false, true, true) else types.heapDetail(true, false, true);
        try refused(h, run, c.program);
        c.functions[f].transacts = false;
        c.functions[f].detail = .{};
        try refused(h, run, c.program);
        c.restore();
    }
}

test "forged session grants: a name, an option, another kind, an enumerator and a second definition are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const session = c.bound("S");
    const session_type = c.typeOf(session);
    try std.testing.expect(c.nodes[session].kind == .grant and c.nodes[session].kind.grant.kind == .session);
    try std.testing.expectEqual(types.GrantKind.session, catalogue.grantKind(session_type, p.definitions).?);
    // A name: of type `string`, of another type, the node itself.
    for ([_]u32{ c.bound("Txt"), c.bound("Z0"), session }) |name| {
        c.nodes[session].kind.grant.name = name;
        try refused(h, run, c.program);
        c.restore();
    }
    // Typed as an option of the session, as `i64`, as a reader.
    const option_session = try c.define(.{ .option = session_type });
    try admitted(c.program);
    c.nodes[session].value_type = option_session;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[session].value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
    const reader = try c.define(.{ .grant = .reader });
    c.nodes[session].value_type = reader;
    try refused(h, run, c.program);
    c.restore();
    // The other kinds with no name, at the session's type, and a kind that does not exist.
    for ([_]types.GrantKind{ .reader, .writer, @fromBackingInt(@intCast(4)), @fromBackingInt(@intCast(250)) }) |kind| {
        c.nodes[session].kind.grant.kind = kind;
        try refused(h, run, c.program);
        c.restore();
    }
    // An enumerator of the session type: no grant has a case a program can name.
    c.nodes[session].kind = .{ .enumeration = 0 };
    try refused(h, run, c.program);
    c.restore();
    // A second definition of `grant(session)`.
    _ = try c.define(.{ .grant = .session });
    try refused(h, run, c.program);
    c.restore();
    // In a function that only computes, the session is refused: it reads the run.
    var lone = try Copy.of(try h.compile("F()<reads>:session = GetSession()\nS:session = F()"));
    defer lone.free();
    const f = lone.function("F");
    lone.functions[f].transacts = false;
    lone.functions[f].detail = .{};
    try harness.invalid(h, lone.program);
}

test "forged reports: a session other than the run's, a lookup, a declaration and a final value the replay did not build" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    const values = try allocator.dupe(types.Value, run.values);
    defer allocator.free(values);
    const cells = try allocator.dupe(source_state.Cell, run.cells);
    defer allocator.free(cells);
    var x = run;
    x.values = values;
    x.cells = cells;
    const restore = struct {
        fn of(v: []types.Value, cs: []source_state.Cell, r: evaluator.Execution) void {
            @memcpy(v, r.values);
            @memcpy(cs, r.cells);
        }
    }.of;
    const find = struct {
        fn of(program: types.Program, name: []const u8) u32 {
            for (program.bindings) |binding| if (std.mem.eql(u8, binding.name.text(program.source), name)) return binding.node;
            unreachable;
        }
    }.of;
    // The run's one session is index 0.
    const session = find(p, "S");
    try std.testing.expectEqual(@as(u32, 0), values[session].enumeration.index);
    values[session].enumeration.index = 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    // A lookup that found the entry reported as finding none.
    var lookup: ?u32 = null;
    for (p.nodes, 0..) |node, index| if (node.kind == .weak_get) {
        lookup = @intCast(index);
        break;
    };
    try std.testing.expectEqual(@as(u32, 1), values[lookup.?].aggregate.elements.end - values[lookup.?].aggregate.elements.start);
    values[lookup.?].aggregate.elements.end = values[lookup.?].aggregate.elements.start;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    // An update reported as yielding another value.
    for (p.nodes, 0..) |node, index| if (node.kind == .weak_set) {
        values[index] = .{ .integer = 77 };
        break;
    };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    // A declaration that was not empty.
    const declaration = p.source_cells[0].initial;
    try std.testing.expect(p.nodes[declaration].kind == .weak_init);
    values[declaration] = cells[0].value;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    // The cell's final value other than what the replay built: emptied, or with its entry's
    // value changed; and the record of final cells missing, which every program with a keyed
    // cell has.
    const final = cells[0].value.aggregate.elements;
    try std.testing.expectEqual(@as(u32, 2), final.end - final.start);
    cells[0].value.aggregate.elements.end = final.start;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    cells[0].value = values[declaration];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    restore(values, cells, run);
    x.cells = &.{};
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}
