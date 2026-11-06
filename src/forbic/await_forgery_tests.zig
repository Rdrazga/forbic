//! Forged IR around `Await(G)` (RFC-0084, P4.6, "Admission"): every case is refused by both
//! machines' admissions, each in its own code, and by the report replay, which admits the
//! program again; the program each case is made from runs.
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
/// The body nodes of `function` of `kind`, in order.
fn bodyNodes(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), out: []usize) usize {
    const f = p.functions[function];
    var count: usize = 0;
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
        out[count] = index;
        count += 1;
    };
    return count;
}

const program_text =
    \\var X:i64 = 0
    \\var W:i64 = 0
    \\Param(N:i64)<reads>:option(logic) = option{true}
    \\Writes()<transacts>:option(logic) = Block{ set W = 1; option{true} }
    \\Plain()<reads>:logic = X > 0
    \\Decides()<reads><decides>:option(logic) = Block{ Require[X > 0]; option{true} }
    \\Suspends()<reads><suspends>:option(logic) = option{true}
    \\Other()<reads>:option(i64) = option{X}
    \\Reads()<reads>:option(logic) = option{true}
    \\RootGuard:function<reads>(tuple(), option(logic)) = Reads
    \\Wait()<transacts><suspends>:logic = Block{
    \\    G1:function<reads>(tuple(i64), option(logic)) = Param
    \\    G2:function<transacts>(tuple(), option(logic)) = Writes
    \\    G3:function<reads>(tuple(), logic) = Plain
    \\    G4:function<reads><decides>(tuple(), option(logic)) = Decides
    \\    G5:function<reads><suspends>(tuple(), option(logic)) = Suspends
    \\    G6:function<reads>(tuple(), option(i64)) = Other
    \\    R:logic = Attempt(Block{ set W = 2; true }, false)
    \\    Await(X > 0)
    \\}
    \\T:task(logic) = Spawn{ Wait() }
    \\Done:i64 = 7
    \\set X = 1
;

test "forged Await sites: guards, types, effects, places, checks and metadata are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    const ran = try h.run(p, 1 << 20);
    try std.testing.expect(ran == .ok);
    const execution = ran.ok;
    var copy = try Copy.of(p);
    defer copy.free();
    const wait = functionNamed(p, "Wait");
    const start = p.functions[wait].body.start;
    var found: [16]usize = undefined;
    std.debug.assert(bodyNodes(p, wait, .await_guard, &found) == 1);
    const site = found[0];
    const values = bodyNodes(p, wait, .function_value, &found);
    // The six function values of the locals, then the guard's.
    std.debug.assert(values == 7);
    var guards: [6]usize = undefined;
    @memcpy(&guards, found[0..6]);
    const Check = struct {
        fn refused(hh: *harness.Harness, c: *Copy, x: evaluator.Execution) !void {
            try harness.invalid(hh, c.program);
            var forged = x;
            forged.program = c.program;
            if (reporting.validate(forged, false, .{})) |_| return error.TestUnexpectedResult else |_| {}
            c.restore();
        }
    };
    // A guard with a parameter; that writes; that yields no option; that fails; that suspends;
    // that yields an option of another type than the site's.
    for (guards) |guard| {
        copy.function_nodes[site].node.kind.await_guard = @intCast(guard - start);
        try Check.refused(h, &copy, execution);
    }
    // A function value typed as reading only, naming a function that writes (a narrowing cast).
    copy.function_nodes[guards[1]].node.value_type = p.function_nodes[start + p.function_nodes[site].node.kind.await_guard].node.value_type;
    copy.function_nodes[site].node.kind.await_guard = @intCast(guards[1] - start);
    try Check.refused(h, &copy, execution);
    // An operand that is not before the site.
    copy.function_nodes[site].node.kind.await_guard = @intCast(site - start);
    try Check.refused(h, &copy, execution);
    copy.function_nodes[site].node.kind.await_guard = @intCast(site - start + 1);
    try Check.refused(h, &copy, execution);
    // A site of another type than its guard's option.
    copy.function_nodes[site].node.value_type = .i64;
    try Check.refused(h, &copy, execution);
    // In a function that does not suspend, or does not read.
    copy.functions[wait].detail = .{};
    try Check.refused(h, &copy, execution);
    copy.functions[wait].detail = .{ .no_reads = true, .suspends = true };
    try Check.refused(h, &copy, execution);
    // Without its check: the `canceling` after it is something else.
    std.debug.assert(p.function_nodes[site + 1].node.kind == .canceling);
    copy.function_nodes[site + 1].node.kind = .{ .boolean = false };
    try Check.refused(h, &copy, execution);
    // Inside a region: the `true` of the `Attempt` before it becomes the site, with its check.
    var region: [4]usize = undefined;
    std.debug.assert(bodyNodes(p, wait, .attempt_begin, &region) == 1);
    var inside = region[0] + 1;
    while (p.function_nodes[inside].node.kind != .boolean) inside += 1;
    copy.function_nodes[inside].node = p.function_nodes[site].node;
    copy.function_nodes[inside].node.kind.await_guard = @intCast(guards[0] - start);
    try Check.refused(h, &copy, execution);
    // At the root: a root node becomes the site of a guard the root holds.
    const done = bindingNode(p, "Done");
    copy.nodes[done] = .{ .span = p.nodes[done].span, .value_type = .logic, .kind = .{ .await_guard = bindingNode(p, "RootGuard") } };
    try Check.refused(h, &copy, execution);
    // Counts and flags that omit the site.
    copy.program.source_ops -= 1;
    try Check.refused(h, &copy, execution);
    copy.program.control_ops -= 1;
    try Check.refused(h, &copy, execution);
    copy.functions[wait].source_ops -= 1;
    try Check.refused(h, &copy, execution);
    copy.functions[wait].control_ops -= 1;
    try Check.refused(h, &copy, execution);
    _ = try h.run(copy.program, 1 << 20);
}
