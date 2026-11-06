//! Forged IR around live fields (RFC-0084, P4.2, "Admission"): every case is refused by both
//! machines' admissions, each in its own code; the program each case is made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    fields: []types.Field,
    call_arguments: []u32,
    function_arguments: []u32,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        const allocator = std.testing.allocator;
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .fields = try allocator.dupe(types.Field, p.fields),
            .call_arguments = try allocator.dupe(u32, p.call_arguments),
            .function_arguments = try allocator.dupe(u32, p.function_arguments),
            .program = p,
            .original = p,
        };
        copy.program.nodes = copy.nodes;
        copy.program.function_nodes = copy.function_nodes;
        copy.program.functions = copy.functions;
        copy.program.fields = copy.fields;
        copy.program.call_arguments = copy.call_arguments;
        copy.program.function_arguments = copy.function_arguments;
        return copy;
    }
    fn free(self: Copy) void {
        const allocator = std.testing.allocator;
        allocator.free(self.nodes);
        allocator.free(self.function_nodes);
        allocator.free(self.functions);
        allocator.free(self.fields);
        allocator.free(self.call_arguments);
        allocator.free(self.function_arguments);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        @memcpy(self.fields, self.original.fields);
        @memcpy(self.call_arguments, self.original.call_arguments);
        @memcpy(self.function_arguments, self.original.function_arguments);
        self.program.source_ops = self.original.source_ops;
    }
};

fn rootNode(p: types.Program, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) usize {
    var seen: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == kind) {
        if (seen == nth) return index;
        seen += 1;
    };
    unreachable;
}
/// The `nth` node of `kind` in the body of `function`, by its place in `function_nodes`.
fn bodyNode(p: types.Program, function: usize, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) usize {
    const f = p.functions[function];
    var seen: usize = 0;
    for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
        if (seen == nth) return index;
        seen += 1;
    };
    unreachable;
}
/// The first node of `function` that reads its first parameter, by its place in the body.
fn parameterNode(p: types.Program, function: usize) u32 {
    const f = p.functions[function];
    for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .parameter) return @intCast(index);
    unreachable;
}
fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return index;
    unreachable;
}
/// The block-clause function of the class whose type is `class`.
fn clausesOf(p: types.Program, class: types.Type) usize {
    for (p.functions, 0..) |f, index| if (f.clauses_of == class) return index;
    unreachable;
}
fn fieldNamed(p: types.Program, name: []const u8) usize {
    for (p.fields, 0..) |field, index| if (std.mem.eql(u8, field.name.text(p.source), name)) return index;
    unreachable;
}

const program =
    \\var S:i64 = 0
    \\tag := class{
    \\    live Twice:i64 = S * 2
    \\    var Plain:i64 = 0
    \\    Fixed:i64 = 0
    \\    Me()<computes>:tag = Self
    \\    Block{ Self.Me() }
    \\}
    \\sub := class(tag){ live Extra:i64 = S + 1 }
    \\pair := struct{ X:i64 = 0 }
    \\T:tag = tag{}
    \\U:sub = sub{}
    \\P:pair = pair{}
    \\Ordinary(X:tag)<transacts>:i64 = Block{ set live X.Plain = S; 0 }
    \\Write(X:tag)<transacts>:i64 = Block{ set X.Plain = 1; 0 }
    \\Make(X:tag)<transacts>:tag = Block{ N:tag = tag{}; X }
    \\set live T.Plain = S + 1
    \\A:i64 = Ordinary(T) + Write(U)
    \\B:tag = Make(T)
;

test "live fields: forged object_live targets, live-only fields, clauses and catalogue are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program);
    try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
    var copy = try Copy.of(p);
    defer copy.free();
    const live = rootNode(p, .object_live, 0);
    const tag_type = p.nodes[p.nodes[live].kind.object_live.object].value_type;
    // An immutable field, a field beyond the class's, a live-only field, at the root.
    for ([_]u32{ 2, 99, 0 }) |field| {
        copy.nodes[live].kind.object_live.field = field;
        try harness.invalid(h, copy.program);
        copy.restore();
    }
    // An operand that is no instance.
    copy.nodes[live].kind.object_live.object = @intCast(rootNode(p, .cell_read, 0));
    try harness.invalid(h, copy.program);
    copy.restore();
    // A live-only field attached by an ordinary function.
    const ordinary = bodyNode(p, functionNamed(p, "Ordinary"), .object_live, 0);
    copy.function_nodes[ordinary].node.kind.object_live.field = 0;
    try harness.invalid(h, copy.program);
    copy.restore();
    // By the clauses of a subclass, which attach only the subclass's own.
    const sub_type = p.nodes[rootNode(p, .object_new, 1)].value_type;
    const sub_live = bodyNode(p, clausesOf(p, sub_type), .object_live, 0);
    copy.function_nodes[sub_live].node.kind.object_live.field = 0;
    try harness.invalid(h, copy.program);
    copy.restore();
    // By the clauses of its own class, on an instance other than their own `Self`: a call's result.
    const clauses = clausesOf(p, tag_type);
    const own = bodyNode(p, clauses, .object_live, 0);
    copy.function_nodes[own].node.kind.object_live.object = @intCast(bodyNode(p, clauses, .invoke, 0) - p.functions[clauses].body.start);
    try harness.invalid(h, copy.program);
    copy.restore();
    // A program write of a live-only field.
    const write = bodyNode(p, functionNamed(p, "Write"), .object_set, 0);
    copy.function_nodes[write].node.kind.object_set.index = 0;
    try harness.invalid(h, copy.program);
    copy.restore();
    // A class's clauses called on an instance not built just before.
    const make = functionNamed(p, "Make");
    const call = bodyNode(p, make, .call, 0);
    const arguments = copy.function_nodes[call].node.kind.call.arguments;
    copy.function_arguments[arguments.start] = parameterNode(p, make);
    try harness.invalid(h, copy.program);
    copy.restore();
    // A function that says it holds a class's clauses and is not shaped as they are.
    copy.functions[functionNamed(p, "Ordinary")].clauses_of = tag_type;
    try harness.invalid(h, copy.program);
    copy.restore();
    // Attaching in a function that may not allocate.
    copy.functions[functionNamed(p, "Ordinary")].detail = types.heapDetail(true, true, false);
    try harness.invalid(h, copy.program);
    copy.restore();
    // A count of source operations that leaves the attachment out.
    copy.program.source_ops -= 1;
    try harness.invalid(h, copy.program);
    copy.restore();
    // The catalogue: a struct field and a `var` field are never live-only.
    copy.fields[fieldNamed(p, "X")].live_only = true;
    try harness.invalid(h, copy.program);
    copy.restore();
    copy.fields[fieldNamed(p, "Plain")].live_only = true;
    try harness.invalid(h, copy.program);
    copy.restore();
    // Restored, the program runs.
    try std.testing.expect((try h.run(copy.program, 1 << 20)) == .ok);
}

test "live fields: forged calls of clauses on an older construction, a double upcast or by recur are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    // Review 6: the second construction's clauses are handed the first construction's instance,
    // which the program has since detached.
    var p = try h.compile(
        \\var S:i64 = 1
        \\meter := class{ var live V:i64 = S * 2 }
        \\X:meter = meter{}
        \\set X.V = 50
        \\Z:meter = meter{}
        \\set S = 7
        \\W:i64 = X.V
    );
    try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
    var copy = try Copy.of(p);
    copy.call_arguments[p.nodes[rootNode(p, .call, 1)].kind.call.arguments.start] = @intCast(rootNode(p, .object_new, 0));
    try harness.invalid(h, copy.program);
    copy.free();
    // Review 4: a call handed an upcast of an upcast of an older instance, at the root.
    p = try h.compile(
        \\var S:i64 = 1
        \\c1 := class{ live L:i64 = S * 2 }
        \\c2 := class(c1){ var A:i64 = 0 }
        \\c3 := class(c2){ var B:i64 = 0 }
        \\X:c2 = c3{}
        \\Y:c1 = X
        \\Z:c3 = c3{}
        \\V:i64 = Y.L + Z.L
    );
    try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
    copy = try Copy.of(p);
    var double: u32 = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .upcast and p.nodes[node.kind.upcast].kind == .upcast) {
        double = @intCast(index);
    };
    var last_call: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .call and p.functions[node.kind.call.function].clauses_of != null) {
        last_call = index;
    };
    copy.call_arguments[p.nodes[last_call].kind.call.arguments.start] = double;
    try harness.invalid(h, copy.program);
    copy.free();
    // Review 5: a function marked as a class's clauses that calls itself on an old instance.
    p = try h.compile(
        \\var S:i64 = 1
        \\var Count:i64 = 0
        \\tag := class{ live Twice:i64 = S * 2; var N:i64 = 0 }
        \\Keep:tag = tag{}
        \\R(X:tag)<transacts>:logic = Block{ set live X.N = S + 100; set Count = Count + 1; If(Count > 1, true, R(Keep)) }
        \\Z:logic = R(tag{})
        \\set S = 3
        \\V:i64 = Keep.Twice
    );
    try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
    copy = try Copy.of(p);
    defer copy.free();
    const r = functionNamed(p, "R");
    copy.functions[r].clauses_of = p.nodes[rootNode(p, .object_new, 0)].value_type;
    const attach = bodyNode(p, r, .object_live, 0);
    copy.function_nodes[attach].node.kind.object_live.field = 0;
    try harness.invalid(h, copy.program);
    // Marking it alone is refused for the same reason: the clauses never recur.
    copy.function_nodes[attach].node.kind.object_live.field = 1;
    try harness.invalid(h, copy.program);
}
