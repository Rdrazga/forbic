//! Tuple semantic, resource and malformed-input acceptance.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const catalogue = @import("aggregate_types.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");

const Storage = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    inspection: inspection.Workspace = .{},
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [types.limits.source_bytes]u8 = undefined,

    fn compile(self: *Storage, source: []const u8) !types.Program {
        return switch (self.compiler.compile(source)) {
            .ok => |program| program,
            .failed => |diagnostic| {
                std.debug.print("tuple compile failed at {d}: {s}\n", .{ diagnostic.span.start, diagnostic.message() });
                return error.UnexpectedCompile;
            },
        };
    }
    fn execute(self: *Storage, source: []const u8) !evaluator.Execution {
        const program = try self.compile(source);
        const actual = self.runtime.evaluate(program, types.limits.evaluation_work);
        try equalResults(evaluator.evaluateWithStorage(program, &self.values, &self.members, types.limits.evaluation_work), actual);
        if (actual == .failed) return error.UnexpectedEvaluation;
        return actual.ok;
    }
    fn reject(self: *Storage, source: []const u8, code: types.Diagnostic.Code) !void {
        const result = self.compiler.compile(source);
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expect(result.failed.span.start <= result.failed.span.end and result.failed.span.end <= source.len);
    }
};
fn storage() !*Storage {
    const result = try scratch.make(Storage);
    return result;
}
fn equalValue(left: types.Value, right: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
    switch (left) {
        .integer => |value| try std.testing.expectEqual(value, right.integer),
        .boolean => |value| try std.testing.expectEqual(value, right.boolean),
        .string => |value| try std.testing.expectEqualStrings(value, right.string),
        .floating => |value| try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(right.floating))),
        .aggregate => |value| try std.testing.expectEqualDeep(value, right.aggregate),
        .enumeration => |value| try std.testing.expectEqualDeep(value, right.enumeration),
        .callable => |value| try std.testing.expectEqualDeep(value, right.callable),
        .object => |value| try std.testing.expectEqualDeep(value, right.object),
        .rational => |value| try std.testing.expectEqualDeep(value, right.rational),
    }
}
fn equalResults(reference: evaluator.Result, actual: evaluator.Result) !void {
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    switch (reference) {
        .failed => |diagnostic| try std.testing.expectEqualDeep(diagnostic, actual.failed),
        .ok => |execution| {
            try std.testing.expectEqual(execution.values.len, actual.ok.values.len);
            for (execution.values, actual.ok.values) |left, right| try equalValue(left, right);
            try std.testing.expectEqual(execution.aggregate_values.len, actual.ok.aggregate_values.len);
            for (execution.aggregate_values, actual.ok.aggregate_values) |left, right| try equalValue(left, right);
        },
    }
}

test "structural tuples compose heterogeneous nested members with functions defaults and contextual empties" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\mode:=enum{Light,Dark}
        \\Base:i64=7
        \\Keep(P:tuple(i64,string))<computes>:tuple(i64,string)=P
        \\Captured()<computes>:tuple(i64,string)=tuple{Base,"λ\n"}
        \\box:=struct{Payload:tuple([]i64,tuple(mode,float))=tuple{array{},tuple{mode.Dark,-0.0}}}
        \\Pair:tuple(i64,string)=Keep(Captured())
        \\Settings:box=box{}
        \\First:i64=(Pair)(0)
        \\Text:string=Keep(Pair)(1)
        \\Count:i64=Settings.Payload(0).Length
        \\Mode:mode=Settings.Payload(1)(0)
        \\Zero:float=Settings.Payload(1)(1)
        \\Rows:[]tuple(i64,string)=array{Pair,tuple{9,"nine"}}
    );
    try std.testing.expectEqual(@as(i64, 7), result.get("First").?.integer);
    try std.testing.expectEqualStrings("λ\n", result.get("Text").?.string);
    try std.testing.expectEqual(@as(i64, 0), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(u32, 1), result.get("Mode").?.enumeration.index);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(result.get("Zero").?.floating)));
    try std.testing.expectEqual(@as(usize, 2), result.elements(result.get("Rows").?).?.len);
    try std.testing.expect(catalogue.validateAll(result.program.definitions, result.program.fields, result.program.cases, result.program.tuple_elements, result.program.source));
}

test "empty singleton inferred tuples and grouping preserve distinct exact structural identity" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\U:tuple()=tuple{}
        \\S:tuple(i64,)=tuple{(4),}
        \\P:tuple(tuple(),tuple(i64),tuple(string,i64))=tuple{U,S,tuple{"a",2}}
        \\X:i64=tuple{3,true}(0)
        \\Y:i64=P(1)(0)
        \\Z:i64=P(2)(1)
        \\Same:tuple(i64)=S
    );
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.get("U").?).?.len);
    try std.testing.expectEqual(@as(i64, 3), result.get("X").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.get("Y").?.integer);
    try std.testing.expectEqual(@as(i64, 2), result.get("Z").?.integer);
    try std.testing.expectEqual(result.get("S").?.aggregate.value_type, result.get("Same").?.aggregate.value_type);
    try std.testing.expect(result.get("S").?.aggregate.value_type != result.get("U").?.aggregate.value_type);
}

test "tuple annotations parse nested array prefixes multiline members and trailing commas iteratively" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\Keep(P:tuple(
        \\ []tuple([]i64,logic),
        \\ tuple(),
        \\))<computes>:tuple([]tuple([]i64,logic),tuple())=P
        \\Value:tuple([]tuple([]i64,logic),tuple())=Keep(tuple{
        \\ array{tuple{array{},true},tuple{array{2},false}},
        \\ tuple{}
        \\})
        \\Count:i64=Value(0).Length
    );
    try std.testing.expectEqual(@as(i64, 2), result.get("Count").?.integer);
}

test "tuple template remapping retains lexical captures and shallow aliases and rejects shadowing" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\Pair:tuple(i64,string)=tuple{8,"global"}
        \\Capture()<computes>:tuple(i64,string)=Pair
        \\Pick(Item:tuple(i64,string))<computes>:i64=Item(0)+Capture()(0)
        \\Wrap(X:tuple(i64,string))<computes>:tuple(tuple(i64,string),tuple(i64,string))=tuple{X,X}
        \\A:tuple(tuple(i64,string),tuple(i64,string))=Wrap(Pair)
        \\Value:i64=Pick(tuple{2,"local"})
        \\Helper()<computes>:tuple([]i64)=tuple{array{}}
        \\Empty:tuple([]i64)=Helper()
    );
    try std.testing.expectEqual(@as(i64, 10), result.get("Value").?.integer);
    const members = result.elements(result.get("A").?).?;
    try std.testing.expectEqualDeep(members[0].aggregate, members[1].aggregate);
    try std.testing.expectEqualDeep(result.get("Pair").?.aggregate, members[0].aggregate);
    // RFC-0076 rule 1: `Pick`'s parameter was named `Pair` and shadowed the binding.
    try s.reject("Pair:tuple(i64,string)=tuple{8,\"global\"}\nPick(Pair:tuple(i64,string))<computes>:i64=Pair(0)", .shadowed_name);
}

test "tuple typing arity positional access and reserved syntax reject with bounded precise diagnostics" {
    const s = try storage();
    defer scratch.release(s);
    const cases = .{
        .{ "X:tuple(i64,string)=tuple{1}", .tuple_arity },
        .{ "X:tuple(i64)=tuple{1,2}", .tuple_arity },
        .{ "X:tuple(i64,string)=tuple{\"a\",1}", .type_mismatch },
        .{ "X:i64=tuple{1}", .type_mismatch },
        .{ "X:[]i64=tuple{1}", .type_mismatch },
        .{ "X:tuple(i64)=array{1}", .type_mismatch },
        .{ "X:tuple()=tuple{1}", .tuple_arity },
        .{ "X:i64=tuple{}(0)", .tuple_index },
        .{ "X:i64=tuple{1}(1)", .tuple_index },
        .{ "X:i64=tuple{1}(999999999999999999999999)", .tuple_index },
        .{ "X:i64=tuple{1}(-1)", .expected_tuple_index },
        .{ "X:i64=tuple{1}(0+0)", .expected_tuple_index },
        .{ "I:i64=0;X:i64=tuple{1}(I)", .expected_tuple_index },
        .{ "X:i64=tuple{1}()", .expected_tuple_index },
        .{ "X:i64=tuple{1}.Length", .type_mismatch },
        .{ "X:i64=3;Y:i64=X(0)", .not_callable },
        .{ "X:[]i64=array{1};Y:i64=X(0)", .not_callable },
        .{ "X:tuple(i64)=tuple{1}+tuple{2}", .type_mismatch },
        .{ "tuple:i64=1", .expected_name },
        .{ "F(tuple:i64)<computes>:i64=tuple", .expected_parameter },
        .{ "X:i64=tuple", .expected_expression },
        .{ "X:tuple(i64 string)=tuple{1,\"s\"}", .expected_type },
        .{ "X:tuple(int)=tuple{1}", .unsupported_type },
        .{ "X:i64=tuple{array{}}(0).Length", .array_type_required },
        .{ "a:=struct{};b:=struct{};X:tuple(a)=tuple{b{}}", .type_mismatch },
    };
    inline for (cases) |case| try s.reject(case[0], case[1]);
    const source = "Pair:tuple(i64)=tuple{3}\nBad:i64=Pair(2)";
    try s.reject(source, .tuple_index);
    const diagnostic = s.compiler.diagnostic;
    try std.testing.expectEqualStrings("2", diagnostic.span.text(source));
    try std.testing.expectEqual(@as(u32, 2), diagnostic.location(source).line);
    try std.testing.expectEqual(@as(u32, 14), diagnostic.location(source).column);
    _ = try s.execute("Recovered:tuple(i64)=tuple{9}");
}

test "tuple members and unused call arguments evaluate strictly in source order" {
    const s = try storage();
    defer scratch.release(s);
    for ([_][]const u8{
        "X:i64=tuple{1/0,9223372036854775807+1}(1)",
        "F(P:tuple(i64,i64))<computes>:i64=1;X:i64=F(tuple{1/0,2})",
        "X:i64=tuple{3,1/0}(0)",
    }) |source| {
        const program = try s.compile(source);
        const reference = evaluator.evaluateWithStorage(program, &s.values, &s.members, types.limits.evaluation_work);
        const actual = s.runtime.evaluate(program, types.limits.evaluation_work);
        try equalResults(reference, actual);
        try std.testing.expect(actual == .failed);
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, actual.failed.code);
        try std.testing.expectEqualStrings("/", actual.failed.span.text(source));
    }
    _ = try s.execute("F()<computes>:tuple(i64)=tuple{1/0};box:=struct{P:tuple(i64)=tuple{1/0}};X:box=box{P:=tuple{9}}");
}

test "tuple catalogue reuse admission boundaries and rejected publication preserve prefixes" {
    try @import("profile.zig").requireBootstrap();
    var c: catalogue.Storage = .{};
    const pair = try c.internTuple(&.{ .i64, .string });
    try std.testing.expectEqual(pair, try c.internTuple(&.{ .i64, .string }));
    try std.testing.expect(pair != try c.internTuple(&.{ .string, .i64 }));
    const singleton = try c.internTuple(&.{.i64});
    try std.testing.expect(singleton != try c.internTuple(&.{}));
    try std.testing.expectError(error.InvalidType, c.internTuple(&.{@fromBackingInt(@as(u16, 65535))}));
    const counts = .{ c.count, c.tuple_count };
    var wide: [types.limits.tuple_arity + 1]types.Type = @splat(.i64);
    try std.testing.expectError(error.TupleLimit, c.internTuple(&wide));
    try std.testing.expectEqual(counts[0], c.count);
    try std.testing.expectEqual(counts[1], c.tuple_count);
    c.reset();
    for (0..4) |index| {
        wide[index] = .string;
        _ = try c.internTuple(wide[0..types.limits.tuple_arity]);
    }
    try std.testing.expectEqual(@as(u32, types.limits.tuple_elements), c.tuple_count);
    try std.testing.expectError(error.TupleLimit, c.internTuple(&.{.logic}));
    try std.testing.expectEqual(@as(u32, 4), c.count);
    const last = try c.internTuple(wide[0..types.limits.tuple_arity]);
    try std.testing.expectEqual(@as(u16, 7), @backingInt(last));
    try std.testing.expect(catalogue.validateAll(c.definitions[0..c.count], &.{}, &.{}, c.tuple_elements[0..c.tuple_count], ""));
    c.reset();
    var nested: types.Type = .i64;
    for (0..types.limits.user_types) |_| nested = try c.internTuple(&.{nested});
    try std.testing.expectEqual(@as(u32, 256), c.count);
    try std.testing.expectEqual(@as(u16, 259), @backingInt(nested));
    try std.testing.expectError(error.TypeLimit, c.internTuple(&.{nested}));
    try std.testing.expectEqual(nested, try c.internTuple(&.{@fromBackingInt(@as(u16, 258))}));
    try std.testing.expect(catalogue.validateAll(c.definitions[0..c.count], &.{}, &.{}, c.tuple_elements[0..c.tuple_count], ""));
}

test "tuple catalogue publication copies overlapping type input in either direction" {
    var c: catalogue.Storage = .{};
    c.tuple_elements[1] = .i64;
    c.tuple_elements[2] = .string;
    _ = try c.internTuple(c.tuple_elements[1..3]);
    try std.testing.expectEqualSlices(types.Type, &.{ .i64, .string }, c.tuple_elements[0..2]);
    c.reset();
    c.tuple_elements[0] = .i64;
    c.tuple_elements[1] = .string;
    c.tuple_elements[2] = .logic;
    _ = try c.internTuple(c.tuple_elements[0..2]);
    _ = try c.internTuple(c.tuple_elements[1..3]);
    try std.testing.expectEqualSlices(types.Type, &.{ .string, .logic }, c.tuple_elements[2..4]);
    try std.testing.expect(catalogue.validateAll(c.definitions[0..c.count], &.{}, &.{}, c.tuple_elements[0..c.tuple_count], ""));
}

test "wide tuple source uses member storage and admits exact per tuple and total type quotas" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var writer = std.Io.Writer.fixed(&s.source);
    try writer.writeAll("X:tuple(");
    for (0..256) |index| try writer.writeAll(if (index == 0) "i64" else ",i64");
    try writer.writeAll(")=tuple{");
    for (0..256) |index| try writer.print("{s}{d}", .{ if (index == 0) "" else ",", index });
    try writer.writeAll("};Last:i64=X(255)");
    const result = try s.execute(writer.buffered());
    try std.testing.expectEqual(@as(i64, 255), result.get("Last").?.integer);
    try std.testing.expectEqual(@as(usize, 256), result.program.tuple_elements.len);
    writer = std.Io.Writer.fixed(&s.source);
    try writer.writeAll("X:i64=tuple{");
    for (0..257) |index| try writer.writeAll(if (index == 0) "1" else ",1");
    try writer.writeAll("}(0)");
    try s.reject(writer.buffered(), .tuple_limit);
    writer = std.Io.Writer.fixed(&s.source);
    for (0..5) |group| {
        try writer.print("T{d}:tuple(", .{group});
        for (0..256) |index| try writer.print("{s}{s}", .{ if (index == 0) "" else ",", if (index == group) "logic" else "i64" });
        try writer.writeAll(")=tuple{");
        for (0..256) |index| try writer.print("{s}{s}", .{ if (index == 0) "" else ",", if (index == group) "true" else "0" });
        try writer.writeAll("};");
        if (group == 3) _ = try s.execute(writer.buffered());
    }
    try s.reject(writer.buffered(), .tuple_limit);
    _ = try s.execute("X:tuple()=tuple{}");
}

test "tuple type parser exact iterative depth and recovery do not use native recursion" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    for ([_]usize{ 128, 129 }) |depth| {
        var writer = std.Io.Writer.fixed(&s.source);
        try writer.writeAll("F(X:");
        for (0..depth) |_| try writer.writeAll("tuple(");
        try writer.writeAll("i64");
        for (0..depth) |_| try writer.writeAll(")");
        try writer.writeAll(")<computes>:i64=3");
        if (depth == 128) _ = try s.execute(writer.buffered()) else try s.reject(writer.buffered(), .expression_limit);
    }
    _ = try s.execute("X:i64=4");
}

test "every tuple fuel boundary and caller member pressure agree and recover" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    const program = try s.compile("P:tuple(i64,tuple(i64))=tuple{1,tuple{2}};X:i64=P(1)(0)");
    const cost: u64 = @intCast(program.nodes.len + program.members.len);
    for (0..cost + 1) |fuel| {
        const actual = s.runtime.evaluate(program, @intCast(fuel));
        try equalResults(evaluator.evaluateWithStorage(program, &s.values, &s.members, @intCast(fuel)), actual);
        if (fuel < cost) try std.testing.expect(actual == .failed and actual.failed.code == .work_limit) else try std.testing.expect(actual == .ok);
    }
    @memset(&s.values, .{ .integer = 999 });
    @memset(&s.members, .{ .integer = 888 });
    const failed = evaluator.evaluateWithStorage(program, &s.values, s.members[0 .. program.members.len - 1], cost);
    try std.testing.expect(failed == .failed and failed.failed.code == .aggregate_limit);
    // Through slices: a Debug build copies an array iterated by value onto the stack (P0.8).
    for (s.values[0..]) |value| try std.testing.expectEqual(@as(i64, 999), value.integer);
    for (s.members[0..]) |value| try std.testing.expectEqual(@as(i64, 888), value.integer);
    _ = try s.execute("X:tuple()=tuple{}");
    const scalar = try s.execute("X:i64=4");
    try std.testing.expectEqual(@as(usize, 0), scalar.aggregate_values.len);
}

fn rejectProgram(s: *Storage, program: types.Program) !void {
    @memset(&s.values, .{ .integer = 77 });
    const result = evaluator.evaluateWithStorage(program, &s.values, &s.members, 0);
    try std.testing.expect(result == .failed and result.failed.code == .invalid_ir);
    for (s.values[0..]) |value| try std.testing.expectEqual(@as(i64, 77), value.integer);
    var out = std.Io.Writer.fixed(s.source[0..1024]);
    const report = try s.inspection.write(&out, program);
    try std.testing.expect(report == .failed);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const lowered = switch (bytecode.lower(program, &s.runtime.instructions)) {
        .failed => return,
        .ok => |value| value,
    };
    const failed = s.runtime.machine.run(lowered, 0);
    try std.testing.expect(failed == .failed and failed.failed.code == .invalid_bytecode);
}

test "whole tuple catalogue and IR admission rejects invalid unused tails ranges cycles duplicates and accesses" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    const original = try s.compile("P:tuple(i64,string)=tuple{1,\"x\"};X:i64=P(0)");
    var definitions: [2]types.Definition = .{ original.definitions[0], .{ .tuple = .{ .start = 2, .end = 2 } } };
    var elements = [_]types.Type{ .i64, .string, .logic };
    for ([_]types.Span{ .{ .start = 1, .end = 2 }, .{ .start = 2, .end = 1 }, .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 257 }, .{ .start = 0, .end = std.math.maxInt(u32) } }) |span| {
        var broken = original;
        definitions[0] = .{ .tuple = span };
        broken.definitions = definitions[0..1];
        try rejectProgram(s, broken);
    }
    definitions[0] = original.definitions[0];
    for ([_]types.Type{ @fromBackingInt(@as(u16, 4)), @fromBackingInt(@as(u16, 65535)) }) |invalid_type| {
        var broken = original;
        elements[0] = invalid_type;
        broken.tuple_elements = elements[0..2];
        try rejectProgram(s, broken);
    }
    elements[0] = .i64;
    var broken = original;
    broken.tuple_elements = &elements;
    try rejectProgram(s, broken);
    var duplicate = [_]types.Type{ .i64, .string, .i64, .string };
    definitions[1] = .{ .tuple = .{ .start = 2, .end = 4 } };
    broken = original;
    broken.definitions = &definitions;
    broken.tuple_elements = &duplicate;
    try rejectProgram(s, broken);
    var nodes: [4]types.Node = undefined;
    @memcpy(nodes[0..original.nodes.len], original.nodes);
    for ([_]types.FieldAccess{ .{ .value = 0, .index = 0 }, .{ .value = 2, .index = 2 }, .{ .value = 3, .index = 0 }, .{ .value = 2, .index = std.math.maxInt(u32) } }) |access| {
        broken = original;
        nodes[3].kind = .{ .tuple_element = access };
        broken.nodes = &nodes;
        try rejectProgram(s, broken);
    }
    @memcpy(&nodes, original.nodes);
    nodes[3].value_type = .string;
    broken.nodes = &nodes;
    try rejectProgram(s, broken);
    @memcpy(&nodes, original.nodes);
    nodes[3].kind = .{ .field = .{ .value = 2, .index = 0 } };
    try rejectProgram(s, broken);
}

test "malformed tuple bytecode is rejected before journal writes and partial fuel rolls back" {
    const s = try storage();
    defer scratch.release(s);
    const tuple_type: types.Type = @fromBackingInt(@as(u16, 4));
    const definitions = [_]types.Definition{.{ .tuple = .{ .start = 0, .end = 1 } }};
    var code = [_]vm.Instruction{
        .{ .op = .begin },
        .{ .value_type = .i64, .op = .{ .integer = 9 } },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .value_type = tuple_type, .op = .{ .aggregate = .{ .start = 0, .end = 1 } } },
        .{ .value_type = .i64, .op = .{ .tuple_element = .{ .value = 1, .index = 0 } } },
        .{ .op = .commit },
    };
    const program: vm.Program = .{ .code = &code, .definitions = &definitions, .tuple_elements = &.{.i64}, .members = &.{0} };
    const machine = &s.runtime.machine;
    machine.journal.cells[0] = 5;
    code[4].op.tuple_element.index = 1;
    const invalid = machine.run(program, 100);
    try std.testing.expect(invalid == .failed and invalid.failed.code == .invalid_bytecode);
    try std.testing.expectEqual(@as(i64, 5), machine.journal.cells[0]);
    code[4].op.tuple_element.index = 0;
    for (0..7) |fuel| {
        const result = machine.run(program, @intCast(fuel));
        try std.testing.expect(result == .failed and result.failed.code == .work_limit);
        try std.testing.expectEqual(@as(i64, 5), machine.journal.cells[0]);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
    }
    try std.testing.expect(machine.run(program, 7) == .ok);
    try std.testing.expectEqual(@as(i64, 9), machine.journal.cells[0]);
}

test "tuple JSON and inspection format four preflight exact budgets and forged private values" {
    const s = try storage();
    defer scratch.release(s);
    const execution = try s.execute("P<public>:tuple(i64,string,tuple())=tuple{2,\"λ\\n\",tuple{}};X:i64=P(0)");
    const expected = "{\"P\":[2,\"λ\\n\",[]]}\n";
    var writer = std.Io.Writer.fixed(&s.source);
    const stats = try reporting.write(&writer, execution, true, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
    writer.end = 0;
    _ = try reporting.write(&writer, execution, true, .{ .work = stats.work, .output_bytes = stats.output_bytes });
    writer.end = 0;
    try std.testing.expectError(error.ReportLimit, reporting.write(&writer, execution, true, .{ .work = stats.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&writer, execution, true, .{ .output_bytes = stats.output_bytes - 1 }));
    writer.end = 0;
    try std.testing.expect(try s.inspection.write(&writer, execution.program) == .ok);
    const count = writer.end;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 4), parsed.value.object.get("format").?.integer);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("tuple_elements").?.array.items.len);
    writer.end = 0;
    try std.testing.expect(try s.inspection.writeBounded(&writer, execution.program, .{ .output_bytes = count }) == .ok);
    writer.end = 0;
    try std.testing.expect(try s.inspection.writeBounded(&writer, execution.program, .{ .output_bytes = count - 1 }) == .failed);
    try std.testing.expectEqual(@as(usize, 0), writer.end);
    const constructor = execution.program.bindings[0].node;
    s.runtime.machine.values[constructor].aggregate.elements.end -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.write(&writer, execution, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "seeded heterogeneous tuple programs agree with independent selected integer and string oracles" {
    const s = try storage();
    defer scratch.release(s);
    var prng = std.Random.DefaultPrng.init(0x5858_0001);
    const random = prng.random();
    for (0..2000) |_| {
        const a = random.intRangeAtMost(i64, -1000, 1000);
        const b = random.intRangeAtMost(i64, -1000, 1000);
        const source = try std.fmt.bufPrint(&s.source, "Pick(P:tuple(i64,string,tuple(i64)))<computes>:i64=P(0)+P(2)(0);P:tuple(i64,string,tuple(i64))=tuple{{{d},\"label\",tuple{{{d}}}}};Value:i64=Pick(P);Text:string=P(1)", .{ a, b });
        const result = try s.execute(source);
        try std.testing.expectEqual(a + b, result.get("Value").?.integer);
        try std.testing.expectEqualStrings("label", result.get("Text").?.string);
    }
}

test "seeded tuple source mutations preserve diagnostics admitted IR and workspace recovery" {
    const s = try storage();
    defer scratch.release(s);
    const base = "mode:=enum{A,B};box:=struct{P:tuple([]i64,mode)=tuple{array{},mode.B}};Keep(P:tuple(i64,box))<computes>:tuple(i64,box)=P;Value:tuple(i64,box)=Keep(tuple{3,box{}});X:i64=Value(0)";
    var prng = std.Random.DefaultPrng.init(0x5858_0002);
    const random = prng.random();
    for (0..4000) |_| {
        @memcpy(s.source[0..base.len], base);
        s.source[random.uintLessThan(usize, base.len)] = random.int(u8);
        const source = s.source[0..base.len];
        switch (s.compiler.compile(source)) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= source.len),
            .ok => |program| {
                try std.testing.expect(evaluator.validate(program, s.values.len) == null);
                const fuel = random.uintLessThan(u32, 50);
                try equalResults(evaluator.evaluateWithStorage(program, &s.values, &s.members, fuel), s.runtime.evaluate(program, fuel));
            },
        }
    }
    _ = try s.execute(base);
}

test "ten thousand tuple catalogue IR and member mutations agree across independent admission and execution" {
    // Each round poisons every register and member: a cost of the test, set by the capacities.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    const original = try s.compile("P:tuple(i64,tuple(string,logic))=tuple{7,tuple{\"x\",true}};X:i64=P(0)");
    var prng = std.Random.DefaultPrng.init(0x5858_0003);
    const random = prng.random();
    for (0..10000) |_| {
        var nodes: [8]types.Node = undefined;
        var definitions: [2]types.Definition = undefined;
        var elements: [4]types.Type = undefined;
        var members: [4]u32 = undefined;
        @memcpy(nodes[0..original.nodes.len], original.nodes);
        @memcpy(&definitions, original.definitions);
        @memcpy(&elements, original.tuple_elements);
        @memcpy(&members, original.members);
        var changed = original;
        changed.nodes = nodes[0..original.nodes.len];
        changed.definitions = &definitions;
        changed.tuple_elements = &elements;
        changed.members = &members;
        const position = random.uintLessThan(usize, original.nodes.len);
        const index = random.uintLessThan(u32, 12);
        const value_type: types.Type = @fromBackingInt(random.uintLessThan(u16, 9));
        switch (random.uintLessThan(u8, 8)) {
            0 => nodes[position].value_type = value_type,
            1 => nodes[position].kind = .{ .tuple_element = .{ .value = index, .index = index / 2 } },
            2 => nodes[position].kind = .{ .aggregate = .{ .start = index / 2, .end = index } },
            3 => definitions[random.uintLessThan(usize, 2)].tuple = .{ .start = index / 2, .end = index },
            4 => elements[random.uintLessThan(usize, 4)] = value_type,
            5 => members[random.uintLessThan(usize, 4)] = index,
            6 => nodes[position].kind = .{ .field = .{ .value = index, .index = index / 2 } },
            7 => nodes[0].kind.integer = random.int(i64),
            else => unreachable,
        }
        const fuel = random.uintLessThan(u32, 30);
        @memset(&s.values, .{ .integer = 99 });
        @memset(&s.members, .{ .integer = 88 });
        @memset(&s.runtime.machine.values, .{ .integer = 99 });
        @memset(&s.runtime.machine.aggregate_values, .{ .integer = 88 });
        const expected = evaluator.evaluateWithStorage(changed, &s.values, &s.members, fuel);
        const actual = s.runtime.evaluate(changed, fuel);
        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
        if (expected == .failed) {
            try std.testing.expectEqual(expected.failed.code, actual.failed.code);
            if (expected.failed.code != .invalid_ir) try std.testing.expectEqualDeep(expected.failed, actual.failed);
        } else try equalResults(expected, actual);
        try std.testing.expectEqualDeep(s.values[0..original.nodes.len], s.runtime.machine.values[0..original.nodes.len]);
        try std.testing.expectEqualDeep(s.members[0..4], s.runtime.machine.aggregate_values[0..4]);
    }
}

test "tuple template member quota accepts exactly 8192 values and rejects further expansion" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var writer = std.Io.Writer.fixed(&s.source);
    try writer.writeAll("Seed:i64=1;Make()<computes>:tuple(");
    for (0..256) |index| try writer.writeAll(if (index == 0) "i64" else ",i64");
    try writer.writeAll(")=tuple{");
    for (0..256) |index| try writer.writeAll(if (index == 0) "Seed" else ",Seed");
    try writer.writeAll("};Value:i64=");
    for (0..32) |index| try writer.writeAll(if (index == 0) "Make()(0)" else "+Make()(0)");
    const program = try s.compile(writer.buffered());
    const cost: u64 = @intCast(program.nodes.len + 32 * program.function_nodes.len + 8192);
    const result = s.runtime.evaluate(program, cost).ok;
    try equalResults(evaluator.evaluateWithStorage(program, &s.values, &s.members, cost), .{ .ok = result });
    try std.testing.expectEqual(@as(usize, 0), result.program.members.len);
    try std.testing.expectEqual(@as(usize, 256), result.program.function_members.len);
    try std.testing.expectEqual(@as(usize, 8192), result.aggregate_values.len);
    try std.testing.expectEqual(@as(i64, 32), result.get("Value").?.integer);
    // One more copy stays within source/node/type budgets but exceeds members.
    try writer.writeAll("+Make()(0)");
    const overflow = try s.compile(writer.buffered());
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, s.runtime.evaluate(overflow, 131072).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithStorage(overflow, &s.values, &s.members, 131072).failed.code);
}
