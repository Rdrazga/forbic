//! Forged IR around `json_encode` and `json_decode` (RFC-0087, P5.3, admission rule 6 and the
//! "Operations" row of "Forged IR"): every case is refused by both machines' admissions, each in
//! its own code, and by the report replay, which admits the program again before it replays.
//! Each is made from a program that runs by changing one thing. Forged reports, whose encoded
//! text or decoded value is not what the codec makes of its operand, are refused by the replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// JSON nodes at the root and in functions of each effect, beside values of types that are not
/// persistable and an option of one, and a branch whose arm holds an `i64`.
const base =
    \\point := struct<persistable>{X:i64 = 0}
    \\c := class<final><persistable>{N:i64 = 3}
    \\plain := struct{V:i64 = 0}
    \\Plain:plain = plain{}
    \\NoOption:option(plain) = option{}
    \\Count:i64 = 7
    \\Pick:i64 = If(Count > 3, Count + 1, Count + 2)
    \\Text:string = ToJson(point{X := Count})
    \\Back:i64 = Attempt(FromJson[point][Text].X, -1)
    \\Small:string = ToJson(Pick)
    \\Read(D:c)<reads>:string = ToJson(D)
    \\Build(T:string)<allocates><decides>:c = FromJson[c][T]
    \\Plainly(T:string)<computes><decides>:point = FromJson[point][T]
    \\Made:string = Read(c{})
    \\Again:i64 = Attempt(Build[Made].N, -1)
    \\Plained:i64 = Attempt(Plainly[Text].X, -1)
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    definitions: []types.Definition,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .definitions = try allocator.dupe(types.Definition, p.definitions),
            .program = p,
            .original = p,
        };
        copy.point();
        return copy;
    }
    fn point(self: *Copy) void {
        self.program.nodes = self.nodes;
        self.program.function_nodes = self.function_nodes;
        self.program.functions = self.functions;
        self.program.definitions = self.definitions;
    }
    fn free(self: *Copy) void {
        allocator.free(self.definitions);
        allocator.free(self.functions);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        @memcpy(self.definitions, self.original.definitions);
        self.program = self.original;
        self.point();
    }
    fn bound(self: *const Copy, name: []const u8) u32 {
        for (self.original.bindings) |binding| if (std.mem.eql(u8, binding.name.text(self.original.source), name)) return binding.node;
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
    fn body(self: *const Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
        const f = self.original.functions[self.function(name)];
        for (self.original.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) return index;
        unreachable;
    }
    fn named(self: *const Copy, name: []const u8) usize {
        for (self.original.definitions, 0..) |item, index| if (catalogue.declaredName(item)) |span| if (std.mem.eql(u8, span.text(self.original.source), name)) return index;
        unreachable;
    }
};

fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

fn admitted(p: types.Program) !void {
    const h = try harness.create();
    defer scratch.release(h);
    try std.testing.expect(try h.run(p, fuel) == .ok);
}

test "json forged rows: types that are not persistable, nodes typed otherwise, effects the function lacks, operands out of reach" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const encode = c.root(.json_encode, 0);
    const decode = c.root(.json_decode, 0);
    const small = c.root(.json_encode, 1);
    // `json_encode` of a value whose type is not persistable.
    c.nodes[encode].kind.json_encode = c.bound("Plain");
    try refused(h, run, c.program);
    c.restore();
    // Typed otherwise than a `string`.
    c.nodes[encode].value_type = .i64;
    try refused(h, run, c.program);
    c.restore();
    // An operand that is not earlier.
    c.nodes[encode].kind.json_encode = encode;
    try refused(h, run, c.program);
    c.restore();
    // `json_decode` typed `T` without the option, of an option of a type that is not
    // persistable, and of an operand that is no `string`.
    c.nodes[decode].value_type = c.nodes[c.nodes[encode].kind.json_encode].value_type;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[decode].value_type = c.nodes[c.bound("NoOption")].value_type;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[decode].kind.json_decode = c.bound("Count");
    try refused(h, run, c.program);
    c.restore();
    // A persistable struct's flag taken away: what is encoded and decoded is not persistable.
    c.definitions[c.named("point")].record.persistable = false;
    try refused(h, run, c.program);
    c.restore();
    // An operand computed in an arm of a branch, out of reach after it.
    const arm = for (p.nodes[0..small], 0..) |node, index| {
        if (node.kind == .if_begin) break @as(u32, @intCast(index + 1));
    } else unreachable;
    try std.testing.expectEqual(types.Type.i64, p.nodes[arm].value_type);
    c.nodes[small].kind.json_encode = arm;
    try refused(h, run, c.program);
    c.restore();
    // A function that encodes what reaches a class without `<reads>`, and one that decodes it
    // without `<allocates>`: both declared `<computes>`.
    const read = c.function("Read");
    c.functions[read].transacts = false;
    c.functions[read].detail = .{};
    try refused(h, run, c.program);
    c.restore();
    const build = c.function("Build");
    c.functions[build].transacts = false;
    c.functions[build].detail = .{};
    try refused(h, run, c.program);
    c.restore();
    // In a function, a decode typed without the option, and of an i64.
    const plain_decode = c.body("Plainly", .json_decode);
    c.function_nodes[plain_decode].node.value_type = c.nodes[c.bound("Count")].value_type;
    try refused(h, run, c.program);
    c.restore();
    c.function_nodes[plain_decode].node.value_type = c.nodes[c.bound("NoOption")].value_type;
    try refused(h, run, c.program);
    c.restore();
    // The counts of control and source operations say each node is both.
    c.program.source_ops -= 1;
    try refused(h, run, c.program);
    c.restore();
    c.program.control_ops -= 1;
    try refused(h, run, c.program);
    c.restore();
    // A decode's member work is one that builds.
    c.functions[build].member_work = 0;
    try refused(h, run, c.program);
    c.restore();
    try admitted(p);
}

test "a forged report whose text or decoded value is not what the codec makes of its operand is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    const values = try allocator.dupe(types.Value, run.values);
    defer allocator.free(values);
    const steps = try allocator.dupe(types.CallStep, run.call_steps);
    defer allocator.free(steps);
    const members = try allocator.dupe(types.Value, run.aggregate_values);
    defer allocator.free(members);
    var x = run;
    x.values = values;
    x.call_steps = steps;
    x.aggregate_values = members;
    // The text of `Text` changed to another string of the run's, in its value and its step.
    const text = for (p.bindings) |binding| {
        if (std.mem.eql(u8, binding.name.text(p.source), "Text")) break binding.node;
    } else unreachable;
    const small = for (p.bindings) |binding| {
        if (std.mem.eql(u8, binding.name.text(p.source), "Small")) break binding.node;
    } else unreachable;
    const forged_text = run.values[small];
    values[text] = forged_text;
    for (steps) |*step| if (step.kind == .root and step.pc == text) {
        step.value = forged_text;
    };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    @memcpy(values, run.values);
    @memcpy(steps, run.call_steps);
    // The decoded point holds another X: its member is changed.
    const decoded = for (p.nodes, 0..) |node, index| {
        if (node.kind == .json_decode) break index;
    } else unreachable;
    const option = run.values[decoded].aggregate.elements;
    try std.testing.expectEqual(@as(u32, 1), option.end - option.start);
    const value = run.aggregate_values[option.start].aggregate.elements;
    members[value.start] = .{ .integer = 8 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    @memcpy(members, run.aggregate_values);
    // Or the decode is said to have found nothing.
    values[decoded].aggregate.elements.end = values[decoded].aggregate.elements.start;
    for (steps) |*step| if (step.kind == .root and step.pc == decoded) {
        step.value = values[decoded];
    };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    @memcpy(values, run.values);
    @memcpy(steps, run.call_steps);
    // And in a traced function: the step of the encode in `Read` holds another text.
    var changed = false;
    for (steps) |*step| if (step.kind == .value and step.value == .string and std.mem.indexOf(u8, step.value.string, "\"$class_name\":\"c\"") != null) {
        step.value = forged_text;
        changed = true;
    };
    try std.testing.expect(changed);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
    @memcpy(steps, run.call_steps);
    _ = try reporting.validate(x, false, .{ .work = 1 << 24 });
}
