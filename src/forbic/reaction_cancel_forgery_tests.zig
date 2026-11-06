//! Forged IR around cancelling reactions (RFC-0084, P4.7): a `Cancel` of a reaction's handle is
//! the `task_cancel` site of RFC-0082 P3.7, and P4.7 adds no operation. Every forged way to reach
//! a reaction with a request from where a program cannot is refused by both machines' admissions,
//! each in its own code, and by the report replay, which admits the program again; the program
//! each case is made from runs, and cancels its reaction.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        const allocator = std.testing.allocator;
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
    fn free(self: Copy) void {
        const allocator = std.testing.allocator;
        allocator.free(self.nodes);
        allocator.free(self.function_nodes);
        allocator.free(self.functions);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        self.program.source_ops = self.original.source_ops;
        self.program.control_ops = self.original.control_ops;
    }
};

fn bindingNode(p: types.Program, name: []const u8) u32 {
    for (p.bindings) |b| if (std.mem.eql(u8, b.name.text(p.source), name)) return b.node;
    unreachable;
}
fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return index;
    unreachable;
}
/// The first body node of `function` of `kind`.
fn bodyNode(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    const f = p.functions[function];
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) return index;
    unreachable;
}

const program_text =
    \\var X:i64 = 0
    \\var Y:i64 = 0
    \\Stop(T:task(i64))<transacts><suspends>:void = Block{ N:i64 = 3; T.Cancel() }
    \\Body()<transacts><suspends>:i64 = 1
    \\Fire:function<transacts><suspends>(tuple(), i64) = Body
    \\U:task(i64) = Upon(X > 5, Set(Y, X))
    \\Main()<transacts><suspends>:void = Stop(U)
    \\M:task(void) = Spawn{ Main() }
    \\set X = 10
;

test "forged cancels of a reaction: places, effects, checks, operands and bodies are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    const ran = try h.run(p, 1 << 20);
    try std.testing.expect(ran == .ok);
    const execution = ran.ok;
    // The program cancels its `Upon` before the write: it never fires.
    try std.testing.expectEqual(@as(i64, 0), execution.get("Y").?.integer);
    try std.testing.expectEqual(@as(u64, 1), execution.scheduler.canceled);
    var copy = try Copy.of(p);
    defer copy.free();
    const Check = struct {
        fn refused(hh: *harness.Harness, c: *Copy, x: evaluator.Execution) !void {
            try harness.invalid(hh, c.program);
            var forged = x;
            forged.program = c.program;
            if (reporting.validate(forged, false, .{})) |_| return error.TestUnexpectedResult else |_| {}
            c.restore();
        }
    };
    const stop = functionNamed(p, "Stop");
    const start = p.functions[stop].body.start;
    const site = bodyNode(p, stop, .task_cancel);
    // A `Cancel` in a function that does not suspend, or does not write.
    var narrowed = p.functions[stop].detail;
    narrowed.suspends = false;
    copy.functions[stop].detail = narrowed;
    try Check.refused(h, &copy, execution);
    narrowed = p.functions[stop].detail;
    narrowed.no_writes = true;
    copy.functions[stop].detail = narrowed;
    try Check.refused(h, &copy, execution);
    // A `Cancel` whose check is gone: a second request where the check stood.
    copy.function_nodes[site + 1].node.kind = copy.function_nodes[site].node.kind;
    try Check.refused(h, &copy, execution);
    // A `Cancel` of something that is no handle: the local `N`.
    copy.function_nodes[site].node.kind.task_cancel = @intCast(bodyNode(p, stop, .integer) - start);
    try Check.refused(h, &copy, execution);
    // An operand that is not before the site.
    copy.function_nodes[site].node.kind.task_cancel = @intCast(site - start);
    try Check.refused(h, &copy, execution);
    // A reaction whose body suspends, so that it could reach a `Cancel` of its own handle.
    const upon = bindingNode(p, "U");
    std.debug.assert(p.nodes[upon].kind == .reaction);
    copy.nodes[upon].kind.reaction.body = bindingNode(p, "Fire");
    try Check.refused(h, &copy, execution);
    // A reaction's handle at the root asked by a `Cancel` there: the write of 10 becomes one.
    var write: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .cell_write) {
        write = index;
    };
    std.debug.assert(write > bindingNode(p, "M"));
    copy.nodes[write] = .{ .span = p.nodes[write].span, .value_type = p.nodes[write].value_type, .kind = .{ .task_cancel = upon } };
    try Check.refused(h, &copy, execution);
    _ = try reporting.validate(execution, false, .{});
}
