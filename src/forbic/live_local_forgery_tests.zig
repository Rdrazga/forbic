//! Forged IR around live locals (RFC-0085, I14; admission rule 6): `object_live` may attach a
//! guard to a variable cell `ref(T)` only at field 0, with a guard and a node of type `T`, in a
//! function with every heap effect. Each case changes one thing in a compiled program that
//! runs, and is refused by both machines' admissions, each in its own code, and by the report
//! replay, which admits the program again before it replays (pattern of `map_iteration_tests`).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");

const allocator = std.testing.allocator;

/// A function `Two` with an `i64` cell and a `string` cell, each with a guard, and the same at
/// the root, in a block.
const source =
    \\var M:i64 = 1
    \\Two()<transacts>:i64 = Block{ var live X:i64 = M + 1; var live S:string = "m{M}"; set M = 2; X + S.Length }
    \\A:i64 = Two()
    \\B:i64 = Block{ var live Y:i64 = M * 3; var live T:string = "r{M}"; set M = 4; Y + T.Length }
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .program = p,
            .original = p,
        };
        copy.program.nodes = copy.nodes;
        copy.program.function_nodes = copy.function_nodes;
        copy.program.functions = copy.functions;
        return copy;
    }
    fn free(self: *Copy) void {
        allocator.free(self.functions);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
    }
    fn function(self: *const Copy, name: []const u8) usize {
        for (self.original.functions, 0..) |f, index| if (std.mem.eql(u8, f.name.text(self.original.source), name)) return index;
        unreachable;
    }
    /// The body entries (absolute) of the `object_live` nodes of `Two`, in order.
    fn attachments(self: *const Copy, out: *[2]usize) void {
        const f = self.original.functions[self.function("Two")];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == .object_live) {
            out[seen] = index;
            seen += 1;
        };
        std.debug.assert(seen == 2);
    }
    /// The root's `object_live` nodes, in order.
    fn rootAttachments(self: *const Copy, out: *[2]usize) void {
        var seen: usize = 0;
        for (self.original.nodes, 0..) |node, index| if (node.kind == .object_live) {
            out[seen] = index;
            seen += 1;
        };
        std.debug.assert(seen == 2);
    }
};

fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

test "rule 6: object_live on a variable cell, forged, is refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(source);
    // The program they are made from runs, and its report is admitted.
    const run = (try h.run(p, live.fuel)).ok;
    try std.testing.expectEqual(@as(i64, 3 + 2), run.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 12 + 2), run.get("B").?.integer);
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    var c = try Copy.of(p);
    defer c.free();
    var in_function: [2]usize = undefined;
    c.attachments(&in_function);
    var at_root: [2]usize = undefined;
    c.rootAttachments(&at_root);
    const integer_cell = c.function_nodes[in_function[0]].node.kind.object_live;
    const string_cell = c.function_nodes[in_function[1]].node.kind.object_live;
    try std.testing.expect(catalogue.isRef(c.function_nodes[c.original.functions[c.function("Two")].body.start + integer_cell.object].node.value_type, p.definitions));

    // A field other than 0, in a function and at the root.
    for ([_]u32{ 1, 2 }) |field| {
        c.function_nodes[in_function[0]].node.kind.object_live.field = field;
        try refused(h, run, c.program);
        c.restore();
        c.nodes[at_root[0]].kind.object_live.field = field;
        try refused(h, run, c.program);
        c.restore();
    }
    // A node whose type is not the cell's value type.
    c.function_nodes[in_function[0]].node.value_type = .string;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[at_root[1]].value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
    // A guard of another type than the cell's: the string cell's guard on the integer cell,
    // with the node typed as either.
    c.function_nodes[in_function[0]].node.kind.object_live.guard = string_cell.guard;
    try refused(h, run, c.program);
    c.function_nodes[in_function[0]].node.value_type = .string;
    try refused(h, run, c.program);
    c.restore();
    // The integer guard on the string cell.
    c.function_nodes[in_function[1]].node.kind.object_live.object = integer_cell.object;
    c.function_nodes[in_function[1]].node.kind.object_live.guard = string_cell.guard;
    c.function_nodes[in_function[1]].node.value_type = .string;
    try refused(h, run, c.program);
    c.restore();
    // An object that is not a cell: the guard's closure itself, and the value a cell holds.
    c.function_nodes[in_function[0]].node.kind.object_live.object = integer_cell.guard;
    try refused(h, run, c.program);
    c.restore();
    const f = c.original.functions[c.function("Two")];
    for (c.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .operation and entry.node.kind == .ref_get) {
        if (f.body.start + index > in_function[0]) break;
        c.function_nodes[in_function[0]].node.kind.object_live.object = @intCast(index);
        try refused(h, run, c.program);
        c.restore();
        break;
    };
    // An object later than the node.
    c.function_nodes[in_function[0]].node.kind.object_live.object = @intCast(in_function[0] - f.body.start);
    try refused(h, run, c.program);
    c.restore();
    // In a function without every heap effect (admission rule 6).
    inline for (.{ "no_reads", "no_writes", "no_allocates" }) |missing| {
        @field(c.functions[c.function("Two")].detail, missing) = true;
        try refused(h, run, c.program);
        c.restore();
    }
    // The copy, put back, runs.
    const again = try harness.create();
    defer scratch.release(again);
    try std.testing.expect(try again.run(c.program, live.fuel) == .ok);
}
