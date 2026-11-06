//! Forged IR and forged reports around persistent cells (RFC-0087, P5.5, admission rules 3 to 6
//! and the "Keyed cells" and "Grants" rows of "Forged IR"): every program is refused by both
//! machines' admissions, each in its own code, and by the report replay, which admits the program
//! again before it replays. Each is made from a program that runs by changing one thing; where
//! the same change of a session cell or an ordinary cell is valid, that program is shown to run
//! too, so that the persistent cell is what is refused. Forged reports follow: a load changed,
//! missing, extra or asked for another `(cell, grant)`, a store action whose text, channel or
//! number differs from its write, and a key that names no key grant.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const source_state = @import("source_state.zig");
const cells = @import("persistent_cell_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// A persistent cell `X` and an ordinary cell `O` of a `weak_map`, with a node of each one's type
/// before and after the declarations, a key before them, an update and a lookup of `X` at the
/// root, in a function that only reads and in one that only writes.
const base =
    \\Z0:i64=0
    \\Txt:string="s"
    \\K0:option(persistent_key)=option{GetPersistentKey["alice"]}
    \\Pre:option(i64)=option{}
    \\Pre2:weak_map(persistent_key,i64)=map{}
    \\var X:weak_map(persistent_key,i64)=map{}
    \\var O:weak_map(i64,i64)=map{}
    \\Post:weak_map(persistent_key,i64)=map{}
    \\PostO:weak_map(i64,i64)=map{}
    \\set O=PostO
    \\Key(N:string)<reads><decides>:persistent_key=GetPersistentKey[N]
    \\Get(K:persistent_key)<reads>:i64=Attempt(X[K],-1)
    \\Put(K:persistent_key,V:i64)<writes>:i64=Block{set X[K]=V;V}
    \\B:i64=Attempt(Block{K:=Key["alice"];Put(K,1)+Get(K)},-1)
;

const grants = [_]effects.Grant{ .{ .kind = .key, .name = "alice" }, .{ .kind = .key, .name = "bob" } };

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
    fn bound(self: *const Copy, name: []const u8) u32 {
        for (self.original.bindings) |binding| if (std.mem.eql(u8, binding.name.text(self.original.source), name)) return binding.node;
        unreachable;
    }
    fn cell(self: *const Copy, name: []const u8) u32 {
        for (self.original.source_cells, 0..) |c, index| if (std.mem.eql(u8, c.name.text(self.original.source), name)) return @intCast(index);
        unreachable;
    }
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
    fn at(self: *Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) *types.FunctionNode {
        const f = self.original.functions[self.function(name)];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
            if (seen == nth) return &self.function_nodes[index];
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

fn setup(h: *harness.Harness, script: *effects.Script) void {
    script.* = .{};
    h.control.effects.inputs.source = script.source();
    h.control.effects.inputs.grants = &grants;
    h.runtime.machine.control.effects.inputs.grants = &grants;
}

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of the
/// valid program.
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
    var script: effects.Script = .{};
    setup(h, &script);
    try std.testing.expect(try h.run(recounted(p), fuel) == .ok);
}

fn keyType(p: types.Program) types.Type {
    for (p.definitions, 0..) |item, index| if (item == .grant and item.grant == .key) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    unreachable;
}

test "persistent-cell forged rows: cell operations of a persistent cell, weak operations of an ordinary one, declarations out of place and forged flags" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const x = c.cell("X");
    const o = c.cell("O");
    try std.testing.expect(p.source_cells[x].keyed == .persistent and p.source_cells[o].keyed == .none);
    const declaration = p.source_cells[x].initial;
    try std.testing.expect(c.nodes[declaration].kind == .weak_init and c.nodes[declaration].kind.weak_init == x);
    const keyed_type = c.typeOf(declaration);
    const post = c.bound("Post");
    const post_o = c.bound("PostO");
    const pre2 = c.bound("Pre2");

    // A whole read: of the ordinary cell it is admitted, of the persistent one refused.
    c.nodes[post_o].kind = .{ .cell_read = o };
    try admitted(c.program);
    c.restore();
    c.nodes[post].kind = .{ .cell_read = x };
    try refused(h, run, c.program);
    c.restore();
    // A whole write of the persistent cell, a declaration by `cell_init`, a guard attached to it.
    const write = c.root(.cell_write, 0);
    c.nodes[write].kind.cell_write = .{ .cell = x, .value = post };
    c.nodes[write].value_type = keyed_type;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[declaration].kind = .{ .cell_init = .{ .cell = x, .value = pre2 } };
    try refused(h, run, c.program);
    c.restore();
    c.nodes[write].kind = .{ .cell_live = .{ .cell = x, .guard = post, .initialize = false } };
    c.nodes[write].value_type = keyed_type;
    try refused(h, run, c.program);
    c.restore();
    // A second `weak_init` of it, and one in a function in place of a lookup.
    c.nodes[post] = .{ .span = c.nodes[declaration].span, .value_type = keyed_type, .kind = .{ .weak_init = x } };
    try refused(h, run, c.program);
    c.restore();
    const lookup = c.at("Get", .weak_get, 0);
    lookup.node = .{ .span = lookup.node.span, .value_type = keyed_type, .kind = .{ .weak_init = x } };
    try refused(h, run, c.program);
    c.restore();
    // A `weak_get` or `weak_set` of the ordinary cell, in a function.
    c.at("Get", .weak_get, 0).node.kind.weak_get.cell = o;
    try refused(h, run, c.program);
    c.restore();
    c.at("Put", .weak_set, 0).node.kind.weak_set.cell = o;
    try refused(h, run, c.program);
    c.restore();
    // A cell that is not what its type says: the persistent cell flagged ordinary, as a session
    // cell, as a kind that does not exist; the ordinary one flagged persistent.
    for ([_]types.Keyed{ .none, .session, @fromBackingInt(@intCast(3)), @fromBackingInt(@intCast(200)) }) |kind| {
        c.source_cells[x].keyed = kind;
        try refused(h, run, c.program);
        c.restore();
    }
    c.source_cells[o].keyed = .persistent;
    try refused(h, run, c.program);
    c.restore();
    // A persistent cell bound to a read of itself instead of its declaration.
    for (c.bindings) |*binding| if (binding.node == declaration) {
        binding.node = post;
    };
    try refused(h, run, c.program);
    c.restore();
}

test "persistent-cell forged rows: the value type of a persistent cell is persistable, in both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const source =
        \\p := struct<persistable>{N:i64}
        \\var X:weak_map(persistent_key,[]p)=map{}
        \\Key(N:string)<reads><decides>:persistent_key=GetPersistentKey[N]
        \\Put(K:persistent_key)<writes>:i64=Block{set X[K]=array{p{N:=1}};1}
        \\B:i64=Attempt(Block{K:=Key["alice"];Put(K)},-1)
    ;
    const p = try h.compile(source);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    try admitted(c.program);
    // The struct loses its flag: `[]p` is persistable no more, and nothing else about the program
    // says so (the struct has no default, so no constant waits for the flag).
    for (c.definitions.items) |*item| switch (item.*) {
        .record => |*record| record.persistable = false,
        else => {},
    };
    c.program.definitions = c.definitions.items;
    try refused(h, run, c.program);
    c.restore();
    // The cell's map type given another value type altogether.
    var weak: ?usize = null;
    for (c.definitions.items, 0..) |item, index| if (item == .weak_map) {
        weak = index;
    };
    c.definitions.items[weak.?].weak_map.value = .any;
    try refused(h, run, c.program);
    c.restore();
}

test "forged key grants: a name, a type, another kind, an enumerator and a second definition are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const key = keyType(p);
    const open = c.at("Key", .grant, 0);
    try std.testing.expect(open.node.kind == .grant and open.node.kind.grant.kind == .key);
    // A name of type `i64` (at the root), a name after the node, the node itself.
    open.node.kind.grant.name = c.parameter("Key", 0);
    try admitted(c.program);
    c.restore();
    c.nodes[c.root(.grant, 0)].kind.grant.name = c.bound("Z0");
    try refused(h, run, c.program);
    c.restore();
    const place = for (c.original.function_nodes, 0..) |entry, index| {
        if (entry.input == .operation and entry.node.kind == .grant) break @as(u32, @intCast(index - c.original.functions[c.function("Key")].body.start));
    } else unreachable;
    for ([_]u32{ place, place + 1 }) |name| {
        c.at("Key", .grant, 0).node.kind.grant.name = name;
        try refused(h, run, c.program);
        c.restore();
    }
    // Typed as the key without the option, as an option of another kind, as a string.
    const reader = try c.define(.{ .grant = .reader });
    const option_reader = try c.define(.{ .option = reader });
    for ([_]types.Type{ key, option_reader, .string }) |wrong| {
        c.at("Key", .grant, 0).node.value_type = wrong;
        try refused(h, run, c.program);
        c.restore();
    }
    // Another kind at the key's type, and one that does not exist; the session's, which has no name.
    for ([_]types.GrantKind{ .reader, .writer, .session, @fromBackingInt(@intCast(4)), @fromBackingInt(@intCast(250)) }) |kind| {
        c.at("Key", .grant, 0).node.kind.grant.kind = kind;
        try refused(h, run, c.program);
        c.restore();
    }
    // At the root too: the key's kind and a type the kind does not make.
    const top = c.root(.grant, 0);
    c.nodes[top].kind.grant.kind = .reader;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[top].value_type = key;
    try refused(h, run, c.program);
    c.restore();
    // An enumerator of the key type: no grant has a case a program can name.
    c.at("Key", .option_value, 0).node.kind = .{ .enumeration = 0 };
    try refused(h, run, c.program);
    c.restore();
    // A second definition of `grant(key)`.
    _ = try c.define(.{ .grant = .key });
    try refused(h, run, c.program);
    c.restore();
    // In a function that only computes, a key is refused: it reads the run's grants.
    const f = c.function("Key");
    c.functions[f].transacts = false;
    c.functions[f].detail = .{};
    try harness.invalid(h, c.program);
    c.restore();
    // A definition of the key alone, which nothing uses, is admitted.
    var lone = try Copy.of(try h.compile("A:i64 = 1"));
    defer lone.free();
    _ = try lone.define(.{ .grant = .key });
    try admitted(lone.program);
}

test "forged operations: a lookup and an update of the wrong key or value, out of order, and in functions without their effect" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    // An update by an `i64` where a key stands, with a key where the `i64` value stands, and a
    // lookup by the lookup itself, which is no earlier node.
    c.at("Put", .weak_set, 0).node.kind.weak_set.key = c.parameter("Put", 1);
    try refused(h, run, c.program);
    c.restore();
    c.at("Put", .weak_set, 0).node.kind.weak_set.value = c.parameter("Put", 0);
    try refused(h, run, c.program);
    c.restore();
    const f = c.original.functions[c.function("Get")];
    const here: u32 = for (c.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
        if (entry.input == .operation and entry.node.kind == .weak_get) break @intCast(index);
    } else unreachable;
    c.at("Get", .weak_get, 0).node.kind.weak_get.key = here;
    try refused(h, run, c.program);
    c.restore();
    // The update in a function that only reads, the lookup in one that only writes.
    const put = c.function("Put");
    c.functions[put].detail = .{ .no_reads = true, .no_writes = false, .no_allocates = true };
    try admitted(c.program);
    c.restore();
    c.functions[put].detail = .{ .no_reads = false, .no_writes = true, .no_allocates = true };
    try refused(h, run, c.program);
    c.restore();
    const lookup = c.function("Get");
    c.functions[lookup].detail = .{ .no_reads = true, .no_writes = false, .no_allocates = true };
    try refused(h, run, c.program);
    c.restore();
}

/// A run with entries loaded and entries saved, from which forged reports are made.
const report_source =
    \\var X:weak_map(persistent_key,i64)=map{}
    \\Alice()<reads><decides>:persistent_key=GetPersistentKey["alice"]
    \\Bob()<reads><decides>:persistent_key=GetPersistentKey["bob"]
    \\Start:i64=Attempt(X[Alice[]],-1)
    \\Run()<reads><writes><decides>:i64=Block{set X[Alice[]]=Start+1;set X[Bob[]]=9;0}
    \\R:i64=Attempt(Run[],-1)
;

fn storedRun(h: *harness.Harness, script: *effects.Script, store: []const effects.Stored) !evaluator.Execution {
    script.* = .{ .store = store };
    h.control.effects.inputs.source = script.source();
    h.control.effects.inputs.grants = &grants;
    h.runtime.machine.control.effects.inputs.grants = &grants;
    const p = try h.compile(report_source);
    return (try h.run(p, fuel)).ok;
}

test "forged reports: a load changed, missing, extra or asked for another cell and grant is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 0), .text = "41" }};
    const run = try storedRun(h, &script, &stored);
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    try std.testing.expectEqual(@as(usize, 2), run.effects.inputs.len);
    var entries: [4]effects.InputEntry = undefined;
    var bytes: [16]u8 = undefined;
    const original = run.effects.inputs;
    @memcpy(entries[0..original.len], original);
    @memcpy(bytes[0..run.effects.input_bytes.len], run.effects.input_bytes);
    var forged = run;
    // The text of the first load changed: to another number, to a text that does not decode.
    for ([_][]const u8{ "42", "4x" }) |text| {
        @memcpy(bytes[0..2], text);
        forged.effects.input_bytes = bytes[0..2];
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    }
    @memcpy(bytes[0..2], "41");
    forged.effects.input_bytes = bytes[0..2];
    // A load missing, one extra, one asked for by another cell or another grant.
    forged.effects.inputs = entries[0..1];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    entries[2] = original[1];
    forged.effects.inputs = entries[0..3];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    forged.effects.inputs = entries[0..2];
    for ([_]u32{ effects.loadRequest(1, 0), effects.loadRequest(0, 1), effects.loadRequest(0, 5), 0xffff_ffff }) |request| {
        entries[0].request = request;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    }
    entries[0] = original[0];
    // A load at another tick, of another kind, as an end that holds bytes, as a reading.
    entries[0].tick = 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    entries[0] = original[0];
    entries[0].kind = .line;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    entries[0] = original[0];
    entries[0].status = .end;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    entries[0] = original[0];
    entries[0].bits = 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    entries[0] = original[0];
    entries[1].status = .value;
    entries[1].end = entries[1].start + 2;
    entries[1].bits = 0;
    forged.effects.input_bytes = bytes[0..4];
    @memcpy(bytes[2..4], "40");
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    // Untouched, it validates again.
    entries[1] = original[1];
    forged.effects.input_bytes = bytes[0..2];
    _ = try reporting.validate(forged, false, .{ .work = 1 << 24 });
    // Grants that lose a key, or rename one, are not the run's.
    const renamed = [_]effects.Grant{ .{ .kind = .key, .name = "alice" }, .{ .kind = .key, .name = "carol" } };
    for ([_][]const effects.Grant{ grants[0..1], &renamed, &.{} }) |others| {
        forged.effects.grants = others;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    }
}

test "forged reports: a store action whose text, channel or number differs from its write is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 0), .text = "41" }};
    const run = try storedRun(h, &script, &stored);
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    try std.testing.expectEqual(@as(usize, 2), run.effects.entries.len);
    var list: [4]effects.Entry = undefined;
    @memcpy(list[0..2], run.effects.entries);
    var text: [256]u8 = undefined;
    @memcpy(text[0..run.effects.bytes.len], run.effects.bytes);
    var forged = run;
    forged.effects.entries = list[0..2];
    forged.effects.bytes = text[0..run.effects.bytes.len];
    _ = try reporting.validate(forged, false, .{ .work = 1 << 24 });
    // A byte of the first action's value, of its key, of its cell.
    for ([_][]const u8{ "42", "\"bobby\"", ":Y" }) |_| {}
    const one = std.mem.indexOf(u8, text[0..run.effects.bytes.len], "42").?;
    text[one + 1] = '3';
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    text[one + 1] = '2';
    const key = std.mem.indexOf(u8, text[0..run.effects.bytes.len], "alice").?;
    text[key] = 'A';
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    text[key] = 'a';
    const cell = std.mem.indexOf(u8, text[0..run.effects.bytes.len], ":X").?;
    text[cell + 1] = 'Y';
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    text[cell + 1] = 'X';
    // The action on another channel, a writer's or `Print`'s.
    for ([_]u32{ 0, 1, effects.store_channel - 1 }) |channel| {
        list[0].channel = channel;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    }
    list[0].channel = effects.store_channel;
    // An action missing, and two swapped.
    forged.effects.entries = list[0..1];
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    forged.effects.entries = list[0..2];
    const swap = list[0];
    list[0] = list[1];
    list[1] = swap;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    list[1] = list[0];
    list[0] = swap;
    _ = try reporting.validate(forged, false, .{ .work = 1 << 24 });
    // The tally of the actions is the replay's too.
    forged.effects.output.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
}

test "forged reports: a key that names no key grant, and a cell's final value the replay did not build" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 0), .text = "41" }};
    const run = try storedRun(h, &script, &stored);
    const values = try allocator.dupe(types.Value, run.values);
    defer allocator.free(values);
    const final = try allocator.dupe(source_state.Cell, run.cells);
    defer allocator.free(final);
    const members = try allocator.dupe(types.Value, run.aggregate_values);
    defer allocator.free(members);
    var forged = run;
    forged.values = values;
    forged.cells = final;
    forged.aggregate_values = members;
    _ = try reporting.validate(forged, false, .{ .work = 1 << 24 });
    // A key of the cell's map with an index past the grants, and one that names a reader.
    const readers = [_]effects.Grant{ .{ .kind = .reader, .name = "alice" }, .{ .kind = .key, .name = "bob" } };
    forged.effects.grants = &readers;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    forged.effects.grants = run.effects.grants;
    var at: ?usize = null;
    for (members, 0..) |member, index| if (member == .enumeration and member.enumeration.index == 1) {
        at = index;
        break;
    };
    // Bob is the grant at index 1; 0 is alice, a key too, but not the one this member is.
    members[at.?].enumeration.index = 2;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    members[at.?].enumeration.index = 7;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    members[at.?].enumeration.index = 0;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
    members[at.?].enumeration.index = 1;
    _ = try reporting.validate(forged, false, .{ .work = 1 << 24 });
    // The final value of the cell: emptied.
    const span = final[0].value.aggregate.elements;
    try std.testing.expect(span.end - span.start >= 2);
    final[0].value.aggregate.elements.end = span.start;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{ .work = 1 << 24 }));
}

test "a persistent program run with no store action and no key keeps a plain report" {
    const b = try cells.Bench.create(&.{.{ .kind = .writer, .name = "log" }}, &.{});
    defer b.destroy();
    const x = try b.run("var X:weak_map(persistent_key,i64)=map{}\nV:i64=Attempt(Block{K:=GetPersistentKey[\"alice\"];X[K]},-1)");
    try std.testing.expectEqual(@as(i64, -1), x.get("V").?.integer);
    try std.testing.expectEqual(@as(usize, 0), x.effects.entries.len);
    try std.testing.expectEqual(@as(usize, 0), x.effects.inputs.len);
}
