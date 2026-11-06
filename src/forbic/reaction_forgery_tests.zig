//! Forged IR around reactions (RFC-0084, P4.4, "Admission"): every case is refused by both
//! machines' admissions, each in its own code; the program each case is made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

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
    \\Param(N:i64)<reads>:option(i64) = option{N}
    \\Writes()<transacts>:option(i64) = Block{ set W = 1; option{1} }
    \\Plain()<reads>:i64 = X
    \\Decides()<reads><decides>:option(i64) = Block{ Require[X > 0]; option{X} }
    \\Suspends()<reads><suspends>:option(i64) = option{X}
    \\BodyParam(N:i64)<transacts>:i64 = N
    \\BodySuspends()<transacts><suspends>:i64 = 1
    \\BodyDecides()<transacts><decides>:i64 = Block{ Require[X > 0]; 1 }
    \\G1:function<reads>(tuple(i64), option(i64)) = Param
    \\G2:function<transacts>(tuple(), option(i64)) = Writes
    \\G3:function<reads>(tuple(), i64) = Plain
    \\G4:function<reads><decides>(tuple(), option(i64)) = Decides
    \\G5:function<reads><suspends>(tuple(), option(i64)) = Suspends
    \\B1:function<transacts>(tuple(i64), i64) = BodyParam
    \\B2:function<transacts><suspends>(tuple(), i64) = BodySuspends
    \\B3:function<transacts><decides>(tuple(), i64) = BodyDecides
    \\U:task(i64) = Upon(X > 0, 5)
    \\V:task(void) = When(X, 1)
    \\Make()<transacts>:task(void) = Block{ S:function<transacts><suspends>(tuple(), i64) = BodySuspends; When(X, Set(W, 2)) }
    \\M:task(void) = Make()
    \\set X = 1
;

test "forged reactions: guards, bodies, handles, effects and metadata are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    _ = try h.run(p, 1 << 20);
    var copy = try Copy.of(p);
    defer copy.free();
    const upon = bindingNode(p, "U");
    const when = bindingNode(p, "V");
    std.debug.assert(p.nodes[upon].kind == .reaction and p.nodes[when].kind == .reaction);
    // A guard with a parameter; that writes; that yields no option; that fails; that suspends.
    for ([_][]const u8{ "G1", "G2", "G3", "G4", "G5" }) |name| {
        copy.nodes[upon].kind.reaction.guard = bindingNode(p, name);
        try harness.invalid(h, copy.program);
        copy.restore();
    }
    // A function value typed as reading only, naming a function that writes.
    const writes = bindingNode(p, "G2");
    copy.nodes[writes].value_type = p.nodes[p.nodes[upon].kind.reaction.guard].value_type;
    copy.nodes[upon].kind.reaction.guard = writes;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A body with a parameter; that suspends; that fails.
    for ([_][]const u8{ "B1", "B2", "B3" }) |name| {
        copy.nodes[upon].kind.reaction.body = bindingNode(p, name);
        try harness.invalid(h, copy.program);
        copy.restore();
    }
    // An `upon` whose handle is of another result, a `when` whose handle is not `task(void)`, and
    // the kinds exchanged.
    copy.nodes[upon].value_type = p.nodes[when].value_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[when].value_type = p.nodes[upon].value_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[upon].kind.reaction.kind = .when;
    try harness.invalid(h, copy.program);
    copy.restore();
    // Operands that are not before the node: the guard, the body.
    copy.nodes[upon].kind.reaction.guard = @intCast(upon);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[upon].kind.reaction.body = @intCast(upon);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.nodes[upon].kind.reaction.body = @intCast(upon + 1);
    try harness.invalid(h, copy.program);
    copy.restore();
    // A reaction in a function that may not allocate, or not read; a body that does more to
    // state than its function may.
    const make = functionNamed(p, "Make");
    copy.functions[make].detail = types.heapDetail(true, true, false);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[make].detail = types.heapDetail(false, true, true);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.functions[make].detail = types.heapDetail(true, false, true);
    try harness.invalid(h, copy.program);
    copy.restore();
    // In a function: the reaction's body replaced by a suspending one, which the function
    // holds as a value of its own; a body operand not before the node; the kinds exchanged.
    const in_make = bodyNode(p, make, .reaction);
    const start = p.functions[make].body.start;
    const suspending = bodyNode(p, make, .function_value);
    std.debug.assert(suspending < in_make);
    copy.function_nodes[in_make].node.kind.reaction.body = @intCast(suspending - start);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.function_nodes[in_make].node.kind.reaction.body = @intCast(in_make - start);
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.function_nodes[in_make].node.kind.reaction.kind = .upon;
    try harness.invalid(h, copy.program);
    copy.restore();
    // Counts that omit the reactions.
    copy.program.source_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.program.control_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    _ = try h.run(copy.program, 1 << 20);
}
