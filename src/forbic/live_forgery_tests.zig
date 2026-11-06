//! Forged IR around live variables (RFC-0084, "Admission"): every case is refused by both
//! machines' admissions, each in its own code; the program each case is made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    cells: []types.SourceCell,
    functions: []types.RuntimeFunction,
    definitions: []types.Definition,
    program: types.Program,
    original: types.Program = undefined,

    fn of(p: types.Program) !Copy {
        const allocator = std.testing.allocator;
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .cells = try allocator.dupe(types.SourceCell, p.source_cells),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .definitions = try allocator.dupe(types.Definition, p.definitions),
            .program = p,
        };
        copy.program.nodes = copy.nodes;
        copy.program.function_nodes = copy.function_nodes;
        copy.program.source_cells = copy.cells;
        copy.program.functions = copy.functions;
        copy.program.definitions = copy.definitions;
        return copy;
    }
    fn free(self: Copy) void {
        const allocator = std.testing.allocator;
        allocator.free(self.nodes);
        allocator.free(self.function_nodes);
        allocator.free(self.cells);
        allocator.free(self.functions);
        allocator.free(self.definitions);
    }
    /// Back to the program it was made from.
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.program_nodes());
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.cells, self.original.source_cells);
        @memcpy(self.functions, self.original.functions);
        @memcpy(self.definitions, self.original.definitions);
        self.program.source_ops = self.original.source_ops;
        self.program.control_ops = self.original.control_ops;
    }
    fn program_nodes(self: *const Copy) []const types.Node {
        return self.original.nodes;
    }
};

fn copyOf(p: types.Program) !Copy {
    var copy = try Copy.of(p);
    copy.original = p;
    return copy;
}

fn rootNode(p: types.Program, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) usize {
    var seen: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == kind) {
        if (seen == nth) return index;
        seen += 1;
    };
    unreachable;
}
fn bodyNode(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    const f = p.functions[function];
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) return index;
    unreachable;
}
fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return index;
    unreachable;
}
fn bindingNode(p: types.Program, name: []const u8) u32 {
    for (p.bindings) |b| if (std.mem.eql(u8, b.name.text(p.source), name)) return b.node;
    unreachable;
}

test "forged guards: parameters, effects beyond reads, a narrowed function and the wrong result are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\var X:i64 = 0
        \\var W:i64 = 0
        \\Param(N:i64)<reads>:i64 = N
        \\Writes()<transacts>:i64 = Block{ set W = 1; 1 }
        \\Decides()<reads><decides>:i64 = Block{ Require[X > 0]; X }
        \\Suspends()<reads><suspends>:i64 = X
        \\Optional()<reads>:option(i64) = option{X}
        \\G1:function<reads>(tuple(i64), i64) = Param
        \\G2:function<transacts>(tuple(), i64) = Writes
        \\G3:function<reads><decides>(tuple(), i64) = Decides
        \\G4:function<reads><suspends>(tuple(), i64) = Suspends
        \\G5:function<reads>(tuple(), option(i64)) = Optional
        \\set live X = W + 1
    );
    _ = try h.run(p, 1 << 20);
    var copy = try copyOf(p);
    defer copy.free();
    const live = rootNode(p, .cell_live, 0);
    for ([_][]const u8{ "G1", "G2", "G3", "G4", "G5" }) |name| {
        copy.nodes[live].kind.cell_live.guard = bindingNode(p, name);
        try harness.invalid(h, copy.program);
        copy.restore();
    }
    // A function value typed as reading only, naming a function that writes.
    const writes = bindingNode(p, "G2");
    const reads_type = p.nodes[p.nodes[live].kind.cell_live.guard].value_type;
    copy.nodes[writes].value_type = reads_type;
    copy.nodes[live].kind.cell_live.guard = writes;
    try harness.invalid(h, copy.program);
    copy.restore();
    _ = try h.run(copy.program, 1 << 20);
}

test "forged targets and live-only cells are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\var X:i64 = 0
        \\var S:string = "s"
        \\live Y:i64 = X + 1
        \\var Z:i64 = 0
        \\set live Z = X
        \\Attach()<transacts>:i64 = Block{ set live Z = X * 2; 0 }
        \\A:i64 = Attach()
        \\set X = 2
    );
    _ = try h.run(p, 1 << 20);
    var copy = try copyOf(p);
    defer copy.free();
    const declared = rootNode(p, .cell_live, 0);
    const attached = rootNode(p, .cell_live, 1);
    const y = p.nodes[declared].kind.cell_live.cell;
    const z = p.nodes[attached].kind.cell_live.cell;
    // A cell out of range, and one of another type.
    copy.nodes[attached].kind.cell_live.cell = @intCast(p.source_cells.len);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[attached].kind.cell_live.cell = 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    // An attachment that says it initialises, and a declaration that says it does not.
    copy.nodes[attached].kind.cell_live.initialize = true;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[declared].kind.cell_live.initialize = false;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A plain cell made live-only: its `cell_init`, and the attachment to it.
    copy.cells[z].live_only = true;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A live-only cell written by the program.
    const write = rootNode(p, .cell_write, 0);
    copy.nodes[write].kind.cell_write.cell = y;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A live-only cell attached to again, at the root and in a function.
    copy.nodes[attached].kind.cell_live.cell = y;
    try harness.invalid(h, copy.program);
    copy.restore();
    const in_function = bodyNode(p, functionNamed(p, "Attach"), .cell_live);
    copy.function_nodes[in_function].node.kind.cell_live.cell = y;
    try harness.invalid(h, copy.program);
    copy.restore();
    // An initialisation in a function.
    copy.function_nodes[in_function].node.kind.cell_live.initialize = true;
    try harness.invalid(h, copy.program);
    copy.restore();
    _ = try h.run(copy.program, 1 << 20);
}

test "forged effects, catalogue and metadata of live programs are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\var X:i64 = 0
        \\var Z:i64 = 0
        \\Attach()<transacts>:i64 = Block{ set live Z = X * 2; 0 }
        \\A:i64 = Attach()
    );
    _ = try h.run(p, 1 << 20);
    var copy = try copyOf(p);
    defer copy.free();
    // `set live` in a function that may read and write but not allocate, or only read.
    const attach = functionNamed(p, "Attach");
    copy.functions[attach].detail = types.heapDetail(true, true, false);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[attach].detail = types.heapDetail(true, false, false);
    try harness.invalid(h, copy.program);
    copy.restore();
    // The counts that say a program holds source and control operations leave one out.
    copy.program.source_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.program.control_ops += 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[attach].source_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    // The record type (admission rule 7). Missing: `live(i64)` is replaced by another valid
    // definition (`rational`, which this program has not), so the catalogue is admitted and only
    // the `cell_live` finds no record type for its cell.
    var live_index: usize = 0;
    var guard_index: usize = 0;
    for (p.definitions, 0..) |item, index| {
        if (item == .live) live_index = index;
        if (item == .callable and item.callable.result == .i64 and item.callable.detail.no_writes) guard_index = index;
    }
    copy.definitions[live_index] = .rational;
    try std.testing.expect(catalogueAdmitted(copy.program));
    try harness.invalid(h, copy.program);
    copy.restore();
    // Two definitions appended to the program's: a record type of another target after its
    // guard type is admitted and the program still runs; one before its guard type, or a
    // second record type of i64, is refused by the catalogue itself.
    const empty = p.definitions[guard_index].callable.parameters;
    const string_guard: types.Definition = .{ .callable = catalogue.liveGuard(empty, .string) };
    const extended = try std.testing.allocator.alloc(types.Definition, p.definitions.len + 2);
    defer std.testing.allocator.free(extended);
    for ([_]struct { tail: [2]types.Definition, admitted: bool }{
        .{ .tail = .{ string_guard, .{ .live = .string } }, .admitted = true },
        .{ .tail = .{ .{ .live = .string }, string_guard }, .admitted = false },
        .{ .tail = .{ string_guard, .{ .live = .i64 } }, .admitted = false },
    }) |case| {
        @memcpy(extended[0..p.definitions.len], p.definitions);
        extended[p.definitions.len..][0..2].* = case.tail;
        copy.program.definitions = extended;
        try std.testing.expectEqual(case.admitted, catalogueAdmitted(copy.program));
        if (case.admitted) try std.testing.expect(try h.run(copy.program, 1 << 20) == .ok) else try harness.invalid(h, copy.program);
    }
    copy.program.definitions = copy.definitions;
    // A cell or a function of the record type. The catalogue's `validType`, which both
    // admissions ask of every cell, function and parameter type, refuses it; the type no
    // longer matches its `cell_init` or root node either.
    const record_type: types.Type = @fromBackingInt(@intCast(live_index + catalogue.builtin_count));
    try std.testing.expect(!catalogue.validType(record_type, p.definitions) and catalogue.validType(.i64, p.definitions));
    copy.cells[0].value_type = record_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[attach].value_type = record_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    _ = try h.run(copy.program, 1 << 20);
}

fn catalogueAdmitted(p: types.Program) bool {
    return catalogue.validateAll(p.definitions, p.fields, p.cases, p.tuple_elements, p.source);
}

test "forged instance operations on a live record are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\cell := class{ var V:i64 = 1 }
        \\var X:i64 = 0
        \\set live X = 1
        \\C:cell = cell{}
        \\set C.V = 2
        \\A:i64 = C.V
    );
    try std.testing.expect(try h.run(p, 1 << 20) == .ok);
    var copy = try copyOf(p);
    defer copy.free();
    var live_index: usize = 0;
    for (p.definitions, 0..) |item, index| if (item == .live) {
        live_index = index;
    };
    const record_type: types.Type = @fromBackingInt(@intCast(live_index + catalogue.builtin_count));
    // A construction of the record type: it is no class.
    const made = rootNode(p, .object_new, 0);
    copy.nodes[made].value_type = record_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A read and a write of a field of an instance said to be a record: the record's cells
    // (its guard, stamp, height, owner, place and origin) are no fields.
    const read = rootNode(p, .object_get, 0);
    copy.nodes[p.nodes[read].kind.object_get.value].value_type = record_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    const write = rootNode(p, .object_set, 0);
    copy.nodes[p.nodes[write].kind.object_set.object].value_type = record_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    try std.testing.expect(try h.run(copy.program, 1 << 20) == .ok);
}
