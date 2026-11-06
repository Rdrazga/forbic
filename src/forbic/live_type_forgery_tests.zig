//! Forged IR around functions used as types (RFC-0084, P4.3): they are sugar over `cell_live`,
//! `object_live` and live-only cells and fields, so what a program could forge of them is what
//! P4.1 and P4.2 refuse. Each case is refused by both machines' admissions and by the one the
//! report replay runs; the program each case is made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    fields: []types.Field,
    cells: []types.SourceCell,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        const allocator = std.testing.allocator;
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .fields = try allocator.dupe(types.Field, p.fields),
            .cells = try allocator.dupe(types.SourceCell, p.source_cells),
            .program = p,
            .original = p,
        };
        copy.program.nodes = copy.nodes;
        copy.program.function_nodes = copy.function_nodes;
        copy.program.fields = copy.fields;
        copy.program.source_cells = copy.cells;
        return copy;
    }
    fn free(self: Copy) void {
        const allocator = std.testing.allocator;
        allocator.free(self.nodes);
        allocator.free(self.function_nodes);
        allocator.free(self.fields);
        allocator.free(self.cells);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.fields, self.original.fields);
        @memcpy(self.cells, self.original.source_cells);
    }
};

/// Refused by the reference, the VM and the replay's admission.
fn refused(h: *harness.Harness, p: types.Program) !void {
    try harness.invalid(h, p);
    try std.testing.expect(evaluator.validate(p, h.values.len) != null);
}

fn cellNamed(p: types.Program, name: []const u8) u32 {
    for (p.source_cells, 0..) |cell, index| if (std.mem.eql(u8, cell.name.text(p.source), name)) return @intCast(index);
    unreachable;
}
fn fieldNamed(p: types.Program, name: []const u8) usize {
    for (p.fields, 0..) |field, index| if (std.mem.eql(u8, field.name.text(p.source), name)) return index;
    unreachable;
}
fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return index;
    unreachable;
}
/// The root `cell_write` of `cell`.
fn writeOf(p: types.Program, cell: u32) usize {
    for (p.nodes, 0..) |node, index| if (node.kind == .cell_write and node.kind.cell_write.cell == cell) return index;
    unreachable;
}
fn bodyNode(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    const f = p.functions[function];
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) return index;
    unreachable;
}

const program =
    \\var M:i64 = 2
    \\F(A:i64)<reads>:i64 = A * M
    \\var Hidden:F = 1
    \\var In->Out:F = 2
    \\Fixed:F = 3
    \\set Hidden = 4
    \\set In = 5
    \\unit := class{ var Power:F = 1; Raw->Shield:F = 2 }
    \\U:unit = unit{}
    \\Raise(X:unit)<transacts>:i64 = Block{ set X.Power = 3; X.Power }
    \\A:i64 = Raise(U)
    \\set M = 3
;

test "functions as types: forged writes of what follows a function, and of a fixed raw field, are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program);
    try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
    var copy = try Copy.of(p);
    defer copy.free();
    const hidden_raw = cellNamed(p, "__raw0");
    const hidden = cellNamed(p, "Hidden");
    const out = cellNamed(p, "Out");
    try std.testing.expect(!p.source_cells[hidden_raw].live_only and p.source_cells[hidden].live_only and p.source_cells[out].live_only);
    // The program's write of a variable whose type is a function is one of its raw cell; a
    // write of the cell that follows the function is refused.
    const write = writeOf(p, hidden_raw);
    copy.nodes[write].kind.cell_write.cell = hidden;
    try refused(h, copy.program);
    copy.restore();
    copy.nodes[writeOf(p, cellNamed(p, "In"))].kind.cell_write.cell = out;
    try refused(h, copy.program);
    copy.restore();
    // The raw cell declared by the cell that follows it: a `cell_init` of a live-only cell.
    const declared = p.source_cells[hidden_raw].initial;
    copy.nodes[declared].kind.cell_init.cell = hidden;
    try refused(h, copy.program);
    copy.restore();
    // The hidden raw cell made live-only: no guard gives it its first value.
    copy.cells[hidden_raw].live_only = true;
    try refused(h, copy.program);
    copy.restore();
    // A guard attached again to it, as `set live Out = ...` would.
    copy.nodes[p.source_cells[out].initial].kind.cell_live.initialize = false;
    try refused(h, copy.program);
    copy.restore();
    // A field's write redirected to the field that follows the function.
    const raise = functionNamed(p, "Raise");
    const set = bodyNode(p, raise, .object_set);
    // The class's fields are the raw one (0), Power (1), Raw (2) and Shield (3).
    try std.testing.expectEqual(@as(u32, 0), p.function_nodes[set].node.kind.object_set.index);
    copy.function_nodes[set].node.kind.object_set.index = 1;
    try refused(h, copy.program);
    copy.restore();
    // The field that follows the function made an ordinary immutable one: its attachment is
    // then of an immutable field. And the immutable form's raw field made live-only, so that
    // no guard gives it a value but the default.
    copy.fields[fieldNamed(p, "Shield")].live_only = false;
    try refused(h, copy.program);
    copy.restore();
    copy.fields[fieldNamed(p, "__raw2")].live_only = true;
    try refused(h, copy.program);
    copy.restore();
    try std.testing.expect((try h.run(copy.program, 1 << 20)) == .ok);
}
