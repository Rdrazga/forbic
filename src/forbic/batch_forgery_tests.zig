//! Forged IR around batches (RFC-0084, P4.5, "Admission"): every case is refused by both
//! machines' admissions, each in its own code, and by the report replay, which admits the
//! program again; the program each case is made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
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
fn bodyNode(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    const f = p.functions[function];
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) return index;
    unreachable;
}

const program_text =
    \\var X:i64 = 0
    \\var W:i64 = 0
    \\Watch:task(void) = When(X, Set(W, W + 1))
    \\BodyParam(N:i64)<transacts>:i64 = N
    \\BodySuspends()<transacts><suspends>:i64 = 1
    \\BodyDecides()<transacts><decides>:i64 = Block{ Require[X > 0]; 1 }
    \\BodyText()<transacts>:string = "s"
    \\B1:function<transacts>(tuple(i64), i64) = BodyParam
    \\B2:function<transacts><suspends>(tuple(), i64) = BodySuspends
    \\B3:function<transacts><decides>(tuple(), i64) = BodyDecides
    \\B4:function<transacts>(tuple(), string) = BodyText
    \\Seven:i64 = 7
    \\A:i64 = Batch{ set X = 1; 2 }
    \\Make()<transacts>:i64 = Block{ S:function<transacts><suspends>(tuple(), i64) = BodySuspends; Batch{ set W = 2; 3 } }
    \\M:i64 = Make()
    \\Plain()<transacts>:i64 = Batch{ set X = 4; 5 }
    \\P:i64 = Plain()
;

test "forged batches: bodies, types, effects and metadata are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    const ran = (try h.run(p, 1 << 20)).ok;
    _ = try reporting.validate(ran, false, .{});
    var copy = try Copy.of(p);
    defer copy.free();
    const batch = bindingNode(p, "A");
    std.debug.assert(p.nodes[batch].kind == .batch);
    // A body with a parameter; that suspends; that fails.
    for ([_][]const u8{ "B1", "B2", "B3" }) |name| {
        copy.nodes[batch].kind.batch = bindingNode(p, name);
        try harness.invalid(h, copy.program);
        copy.restore();
    }
    // A body of another result than the node's; an operand that is no function; one that is
    // not before the node.
    copy.nodes[batch].kind.batch = bindingNode(p, "B4");
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[batch].value_type = .string;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[batch].kind.batch = bindingNode(p, "Seven");
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[batch].kind.batch = @intCast(batch);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[batch].kind.batch = @intCast(batch + 1);
    try harness.invalid(h, copy.program);
    copy.restore();
    // The replay admits the program again: the run's report of a forged program is refused.
    var forged = ran;
    copy.nodes[batch].kind.batch = bindingNode(p, "B3");
    forged.program = copy.program;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    copy.restore();
    // In a function: a body that writes in a function that may not; the function's metadata
    // without what calling a body that writes makes it (a region that journals, a failure, the
    // members it builds); counts that omit the batch.
    const plain = functionNamed(p, "Plain");
    copy.functions[plain].detail = types.heapDetail(true, false, true);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[plain].has_source = false;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[plain].has_local = false;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[plain].has_failure = false;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[plain].member_work = 0;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[plain].control_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.program.control_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    // In a function: the body replaced by a suspending one the function holds as a value; an
    // operand not before the node; the node typed otherwise.
    const make = functionNamed(p, "Make");
    const in_make = bodyNode(p, make, .batch);
    const start = p.functions[make].body.start;
    const suspending = bodyNode(p, make, .function_value);
    std.debug.assert(suspending < in_make);
    copy.function_nodes[in_make].node.kind.batch = @intCast(suspending - start);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.function_nodes[in_make].node.kind.batch = @intCast(in_make - start);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.function_nodes[in_make].node.value_type = .string;
    try harness.invalid(h, copy.program);
    copy.restore();
    _ = try h.run(copy.program, 1 << 20);
}
