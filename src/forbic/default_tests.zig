//! Record default semantics tested through the compiler and both independent
//! execution engines. Fixtures exercise observable values, ordering and pressure.
const std = @import("std");
const scratch = @import("scratch.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const types = @import("types.zig");

const Storage = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [types.limits.source_bytes]u8 = undefined,

    fn execute(self: *Storage, source: []const u8) !evaluator.Execution {
        const program = switch (self.compiler.compile(source)) {
            .ok => |program| program,
            .failed => |diagnostic| {
                std.debug.print("default compile failed at {d}: {s}\n", .{ diagnostic.span.start, diagnostic.message() });
                return error.UnexpectedCompile;
            },
        };
        const reference = evaluator.evaluateWithStorage(program, &self.values, &self.members, types.limits.nodes * 2);
        const actual = self.runtime.evaluate(program, types.limits.nodes * 2);
        try self.equalResults(reference, actual);
        if (actual == .failed) {
            std.debug.print("default evaluation failed at {d}: {s}\n", .{ actual.failed.span.start, actual.failed.message() });
            return error.UnexpectedEvaluation;
        }
        return actual.ok;
    }

    fn equalResults(_: *Storage, reference: evaluator.Result, actual: evaluator.Result) !void {
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

    fn expectCompileError(self: *Storage, source: []const u8, code: types.Diagnostic.Code) !void {
        const result = self.compiler.compile(source);
        try std.testing.expectEqual(std.meta.Tag(compiler.Result).failed, std.meta.activeTag(result));
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expect(result.failed.span.start <= result.failed.span.end and result.failed.span.end <= source.len);
    }

    fn expectFailure(self: *Storage, source: []const u8, code: types.Diagnostic.Code, expected_start: usize) !void {
        const program = switch (self.compiler.compile(source)) {
            .ok => |program| program,
            .failed => return error.UnexpectedCompile,
        };
        const reference = evaluator.evaluateWithStorage(program, &self.values, &self.members, types.limits.nodes * 2);
        const actual = self.runtime.evaluate(program, types.limits.nodes * 2);
        try self.equalResults(reference, actual);
        try std.testing.expectEqual(std.meta.Tag(evaluator.Result).failed, std.meta.activeTag(actual));
        try std.testing.expectEqual(code, actual.failed.code);
        try std.testing.expectEqual(@as(u32, @intCast(expected_start)), actual.failed.span.start);
    }
};

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

fn storage() !*Storage {
    const result = try scratch.make(Storage);
    return result;
}

test "typed defaults compose scalar values nested records arrays and explicit overrides" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\palette<public> := struct {
        \\    Bg:string = "snow: 雪\n"
        \\    Opacity:float = 0.7
        \\    Enabled:logic = true
        \\}
        \\desktop := struct {
        \\    Theme:palette = palette{}
        \\    Workspaces:[]i64 = array{1,2,3}
        \\    Labels:[]string = array{}
        \\    Nested:[][]palette = array{array{},array{palette{Opacity := 0.9}}}
        \\    Gap:i64 = 2 * 3,
        \\}
        \\Default<public>:desktop = desktop{}
        \\Custom:desktop = desktop{Gap := 8,Theme := palette{Bg := "custom"}}
        \\Bg:string = Default.Theme.Bg
        \\Opacity:float = Custom.Theme.Opacity
        \\Enabled:logic = Default.Theme.Enabled
        \\Workspaces:i64 = Default.Workspaces.Length
        \\Labels:i64 = Default.Labels.Length
    );
    try std.testing.expectEqualStrings("snow: 雪\n", result.get("Bg").?.string);
    try std.testing.expectEqual(@as(f64, 0.7), result.get("Opacity").?.floating);
    try std.testing.expect(result.get("Enabled").?.boolean);
    try std.testing.expectEqual(@as(i64, 3), result.get("Workspaces").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.get("Labels").?.integer);
    const defaults = result.elements(result.get("Default").?).?;
    const custom = result.elements(result.get("Custom").?).?;
    try std.testing.expectEqual(@as(i64, 6), defaults[4].integer);
    try std.testing.expectEqual(@as(i64, 8), custom[4].integer);
    const nested = result.elements(defaults[3]).?;
    try std.testing.expectEqual(@as(usize, 0), result.elements(nested[0]).?.len);
    const row = result.elements(nested[1]).?;
    try std.testing.expectEqual(@as(f64, 0.9), result.elements(row[0]).?[1].floating);
}

test "unused and fully overridden failing defaults never execute or consume runtime fuel" {
    const s = try storage();
    defer scratch.release(s);
    const unused = try s.execute(
        \\Broken()<computes>:i64 = 1 / 0
        \\unused := struct { A:i64 = Broken(), B:i64 = 9223372036854775807 + 1 }
        \\Answer:i64 = 42
    );
    try std.testing.expectEqual(@as(i64, 42), unused.get("Answer").?.integer);
    try std.testing.expectEqual(@as(usize, 1), unused.program.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), unused.aggregate_values.len);

    const source = "r:=struct{A:i64=1/0,B:i64=9223372036854775807+1};Value:r=r{B:=8,A:=7}";
    const result = try s.execute(source);
    const values = result.elements(result.get("Value").?).?;
    try std.testing.expectEqual(@as(i64, 7), values[0].integer);
    try std.testing.expectEqual(@as(i64, 8), values[1].integer);
    try std.testing.expectEqual(@as(usize, 3), result.program.nodes.len);
    // Two explicit literals plus a two-member constructor cost exactly five.
    const reference = evaluator.evaluateWithStorage(result.program, &s.values, &s.members, 5);
    const actual = s.runtime.evaluate(result.program, 5);
    try s.equalResults(reference, actual);
    try std.testing.expectEqual(std.meta.Tag(evaluator.Result).ok, std.meta.activeTag(actual));
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, s.runtime.evaluate(result.program, 4).failed.code);
}

test "contextual empty array helper defaults and precise float bit patterns survive expansion" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\Keep(Values:[]i64)<computes>:[]i64 = Values
        \\record := struct {
        \\    Empty:[]i64 = Keep(array{})
        \\    Nested:[][]i64 = array{array{},Keep(array{})}
        \\    Zero:float = -0.0
        \\    Positive:float = Inf
        \\    Negative:float = -Inf
        \\    NotANumber:float = NaN
        \\}
        \\Make()<computes>:record = record{}
        \\Value:record = Make()
    );
    const fields = result.elements(result.get("Value").?).?;
    try std.testing.expectEqual(@as(usize, 0), result.elements(fields[0]).?.len);
    const nested = result.elements(fields[1]).?;
    for (nested) |value| try std.testing.expectEqual(@as(usize, 0), result.elements(value).?.len);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(fields[2].floating)));
    try std.testing.expectEqual(@as(u64, 0x7ff0000000000000), @as(u64, @bitCast(fields[3].floating)));
    try std.testing.expectEqual(@as(u64, 0xfff0000000000000), @as(u64, @bitCast(fields[4].floating)));
    try std.testing.expectEqual(@as(u64, 0x7ff8000000000000), @as(u64, @bitCast(fields[5].floating)));
}

test "explicit fields precede defaults and omitted defaults follow declaration order" {
    const s = try storage();
    defer scratch.release(s);
    const division_first = "r:=struct{A:i64=1/0,B:i64=9223372036854775807+1};Value:r=r{}";
    try s.expectFailure(division_first, .division_by_zero, std.mem.indexOf(u8, division_first, "/").?);
    const overflow_first = "r:=struct{B:i64=9223372036854775807+1,A:i64=1/0};Value:r=r{}";
    try s.expectFailure(overflow_first, .arithmetic_overflow, std.mem.indexOf(u8, overflow_first, "+").?);
    const explicit_first = "r:=struct{A:i64=1/0,B:i64=0};Value:r=r{B:=9223372036854775807+1}";
    try s.expectFailure(explicit_first, .arithmetic_overflow, std.mem.indexOf(u8, explicit_first, "+").?);
    const supplied_order = "r:=struct{A:i64=0,B:i64=0};Value:r=r{B:=1/0,A:=9223372036854775807+1}";
    try s.expectFailure(supplied_order, .division_by_zero, std.mem.indexOf(u8, supplied_order, "/").?);
}

test "default failures retain their original source spans through function expansion" {
    const s = try storage();
    defer scratch.release(s);
    const source =
        \\record := struct {
        \\    Value:i64 = 10 / 0
        \\}
        \\Make()<computes>:record = record{}
        \\Wrapper()<computes>:record = Make()
        \\Value:record = Wrapper()
    ;
    try s.expectFailure(source, .division_by_zero, std.mem.indexOf(u8, source, "/").?);
    const diagnostic = s.runtime.evaluate(s.compiler.compile(source).ok, types.limits.nodes * 2).failed;
    try std.testing.expectEqual(@as(u32, 2), diagnostic.location(source).line);
    try std.testing.expectEqualStrings("/", diagnostic.span.text(source));
}

test "defaults capture earlier globals and helpers whatever the constructor's parameters are" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\X:i64 = 40
        \\point := struct { X:i64, Y:i64 }
        \\Origin:point = point{X := X,Y := 2}
        \\Twice(N:i64)<computes>:i64 = N * 2
        \\record := struct {
        \\    X:i64 = 2
        \\    Y:i64 = X + 1
        \\    Z:i64 = Twice(X)
        \\    Item:point = Origin
        \\}
        \\Make(P:i64,Q:point)<computes>:record = record{}
        \\A:record = Make(999,point{X := 777,Y := 888})
        \\B:record = Make(7,point{X := 1,Y := 1})
        \\OwnX:i64 = A.X
        \\CapturedY:i64 = A.Y
        \\CapturedZ:i64 = B.Z
    );
    try std.testing.expectEqual(@as(i64, 2), result.get("OwnX").?.integer);
    try std.testing.expectEqual(@as(i64, 41), result.get("CapturedY").?.integer);
    try std.testing.expectEqual(@as(i64, 80), result.get("CapturedZ").?.integer);
    const fields = result.elements(result.get("A").?).?;
    try std.testing.expectEqualDeep(result.get("Origin").?.aggregate, fields[3].aggregate);
    try std.testing.expectEqualDeep(result.get("Origin").?.aggregate, result.elements(result.get("B").?).?[3].aggregate);
}

test "default constructors inside functions remap local overrides without losing outer parameters" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\Increment(N:i64)<computes>:i64 = N + 1
        \\pair := struct { A:i64 = Increment(2), B:i64 = 4 }
        \\Make(N:i64)<computes>:pair = pair{B := N * 2}
        \\Combine(N:i64)<computes>:i64 = Make(N).A + N + Make(N + 1).B
        \\One:i64 = Combine(10)
        \\Two:i64 = Combine(20)
        \\Values:[]pair = array{Make(3),pair{},Make(4)}
    );
    try std.testing.expectEqual(@as(i64, 35), result.get("One").?.integer);
    try std.testing.expectEqual(@as(i64, 65), result.get("Two").?.integer);
    const values = result.elements(result.get("Values").?).?;
    try std.testing.expectEqual(@as(i64, 6), result.elements(values[0]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 4), result.elements(values[1]).?[1].integer);
    try std.testing.expectEqual(@as(i64, 8), result.elements(values[2]).?[1].integer);
}

test "every default is typed even when unused and sibling self or forward references are rejected" {
    const s = try storage();
    defer scratch.release(s);
    const cases = .{
        .{ "r:=struct{A:i64=\"bad\"};Answer:i64=42", types.Diagnostic.Code.type_mismatch },
        .{ "r:=struct{A:i64=\"bad\"};Value:r=r{A:=1}", types.Diagnostic.Code.type_mismatch },
        .{ "r:=struct{A:[]i64=array{true}}", types.Diagnostic.Code.type_mismatch },
        .{ "r:=struct{A:i64=array{}}", types.Diagnostic.Code.array_type_required },
        .{ "r:=struct{A:float=1}", types.Diagnostic.Code.type_mismatch },
        .{ "p:=struct{};q:=struct{};r:=struct{A:p=q{}}", types.Diagnostic.Code.type_mismatch },
        .{ "r:=struct{A:i64=Missing}", types.Diagnostic.Code.unknown_name },
        .{ "r:=struct{A:i64=Later};Later:i64=1", types.Diagnostic.Code.unknown_name },
        .{ "r:=struct{A:i64=1,B:i64=A}", types.Diagnostic.Code.unknown_name },
        .{ "r:=struct{A:r}", types.Diagnostic.Code.unsupported_type },
        .{ "r:=struct{A:later};later:=struct{}", types.Diagnostic.Code.unsupported_type },
        .{ "r:=struct{A:i64=r{}.A}", types.Diagnostic.Code.unknown_name },
        .{ "r:=struct{A:i64=9223372036854775808}", types.Diagnostic.Code.integer_range },
        .{ "r:=struct{A:i64=}", types.Diagnostic.Code.expected_expression },
    };
    inline for (cases) |case| try s.expectCompileError(case[0], case[1]);
    try std.testing.expectEqual(@as(i64, 42), (try s.execute("r:=struct{A:i64=42};Value:r=r{};Answer:i64=Value.A")).get("Answer").?.integer);
}

test "required duplicate and unknown fields remain checked before omitted expansion" {
    const s = try storage();
    defer scratch.release(s);
    try s.expectCompileError("r:=struct{Required:i64,Bad:i64=1/0};Value:r=r{}", .missing_field);
    try std.testing.expectEqual(@as(u32, 0), s.compiler.expansion_work);
    try std.testing.expectEqual(@as(u32, 0), s.compiler.node_count);
    try s.expectCompileError("r:=struct{A:i64=1};Value:r=r{A:=2,A:=3}", .duplicate_field);
    try s.expectCompileError("r:=struct{A:i64=1};Value:r=r{Other:=2}", .unknown_field);
    try s.expectCompileError("r:=struct{A:i64=1,A:i64=2}", .duplicate_field);
    const result = try s.execute("r:=struct{Required:i64,Default:i64=5};Value:r=r{Required:=7}");
    const values = result.elements(result.get("Value").?).?;
    try std.testing.expectEqual(@as(i64, 7), values[0].integer);
    try std.testing.expectEqual(@as(i64, 5), values[1].integer);
}

test "builtin type and syntax names cannot silently become false default values" {
    const s = try storage();
    defer scratch.release(s);
    inline for (.{ "i64", "float", "logic", "string", "struct", "array" }) |name| {
        try s.expectCompileError("r:=struct{Flag:logic=" ++ name ++ "}", .expected_expression);
        try s.expectCompileError("Flag:logic=" ++ name, .expected_expression);
    }
    try std.testing.expect((try s.execute("r:=struct{Flag:logic=false};Value:r=r{};Flag:logic=Value.Flag")).get("Flag").?.boolean == false);
}

test "default descriptors do not consume the full public function namespace" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    for (0..types.limits.functions) |index| try out.print("F{d}(N:i64)<computes>:i64=N;", .{index});
    try out.writeAll("r:=struct{");
    for (0..128) |index| try out.print("{s}V{d}:i64=F63({d})", .{ if (index == 0) "" else ",", index, index });
    try out.writeAll("};Value:r=r{}");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, types.limits.functions), s.compiler.functions.count);
    const fields = result.elements(result.get("Value").?).?;
    try std.testing.expectEqual(@as(usize, 128), fields.len);
    try std.testing.expectEqual(@as(i64, 0), fields[0].integer);
    try std.testing.expectEqual(@as(i64, 127), fields[127].integer);
    try out.writeAll(";Extra()<computes>:i64=0");
    try s.expectCompileError(out.buffered(), .function_limit);
}

test "all 1024 field defaults and 256 record definitions fit their exact profiles" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    for (0..types.limits.user_types) |index| try out.print("r{d}:=struct{{A:i64=1,B:i64=2,C:i64=3,D:i64=4}};", .{index});
    try out.writeAll("Value:r255=r255{}");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(types.limits.fields, result.program.fields.len);
    try std.testing.expectEqual(types.limits.user_types, result.program.definitions.len);
    try std.testing.expectEqual(@as(u32, 0), s.compiler.functions.count);
    const fields = result.elements(result.get("Value").?).?;
    for (fields, 0..) |field, index| try std.testing.expectEqual(@as(i64, @intCast(index + 1)), field.integer);
    try out.writeAll(";Extra:=struct{}");
    try s.expectCompileError(out.buffered(), .type_limit);
    try std.testing.expectEqual(@as(i64, 7), (try s.execute("Answer:i64=7")).get("Answer").?.integer);
}

test "default templates and expanded nodes have independent exact capacity checks" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("r:=struct{A:i64=1");
    for (0..4095) |_| try out.writeAll("+1");
    const expression_end = out.end;
    try out.writeAll("};Value:r=r{}");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(types.limits.nodes, result.program.nodes.len);
    try std.testing.expectEqual(@as(i64, 4096), result.elements(result.get("Value").?).?[0].integer);
    try out.writeAll(";Answer:i64=Value.A");
    try s.expectCompileError(out.buffered(), .node_limit);
    out.end = expression_end;
    try out.writeAll(",B:i64=0};Answer:i64=42");
    try std.testing.expectEqual(@as(i64, 42), (try s.execute(out.buffered())).get("Answer").?.integer);
    try std.testing.expectEqual(@as(u32, types.limits.template_nodes), s.compiler.functions.node_count);
    out.end = expression_end;
    try out.writeAll(",B:i64=0,C:i64=0};Answer:i64=42");
    try s.expectCompileError(out.buffered(), .template_limit);
    try std.testing.expectEqual(@as(i64, 3), (try s.execute("r:=struct{A:i64=3};Value:r=r{};Answer:i64=Value.A")).get("Answer").?.integer);
}

test "default helper expansion shares and checks the exact template member pool" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("Seed:i64=9;Repeat(N:i64)<computes>:[]i64=array{");
    for (0..1024) |index| try out.print("{s}N", .{if (index == 0) "" else ","});
    try out.writeAll("};r:=struct{");
    for (0..7) |index| try out.print("{s}A{d}:[]i64=Repeat(Seed)", .{ if (index == 0) "" else ",", index });
    const fields_end = out.end;
    try out.writeAll("};Value:r=r{}");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, 1024), s.compiler.functions.member_count);
    try std.testing.expectEqual(@as(usize, 1024), result.program.function_members.len);
    const fields = result.elements(result.get("Value").?).?;
    try std.testing.expectEqual(@as(usize, 7), fields.len);
    for (fields) |field| {
        const values = result.elements(field).?;
        try std.testing.expectEqual(@as(usize, 1024), values.len);
        try std.testing.expectEqual(@as(i64, 9), values[0].integer);
        try std.testing.expectEqual(@as(i64, 9), values[1023].integer);
    }
    out.end = fields_end;
    try out.writeAll(",A7:[]i64=Repeat(Seed)};Value:r=r{}");
    const overflow = s.compiler.compile(out.buffered()).ok;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, s.runtime.evaluate(overflow, 32768).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithStorage(overflow, &s.values, &s.members, 32768).failed.code);
}

test "alias-heavy omitted defaults consume checked compiler work without reaching node or member quotas" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("Seed:i64=9;Keep(");
    for (0..types.limits.parameters) |index| try out.print("{s}P{d}:i64", .{ if (index == 0) "" else ",", index });
    try out.writeAll(")<computes>:i64=P0;r:=struct{");
    for (0..types.limits.record_fields) |index| {
        try out.print("{s}A{d}:i64=Keep(", .{ if (index == 0) "" else ",", index });
        for (0..types.limits.parameters) |parameter| try out.print("{s}Seed", .{if (parameter == 0) "" else ","});
        try out.writeAll(")");
    }
    try out.writeAll("};");
    for (0..15) |index| try out.print("V{d}:r=r{{}};", .{index});
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(usize, 15 * types.limits.record_fields), result.aggregate_values.len);
    try std.testing.expectEqual(@as(i64, 9), result.elements(result.get("V14").?).?[255].integer);
    try out.writeAll("Overflow:r=r{}");
    try s.expectCompileError(out.buffered(), .compiler_work_limit);
    try std.testing.expect(s.compiler.node_count < types.limits.nodes);
    try std.testing.expect(s.compiler.member_count < types.limits.aggregate_elements);
    try std.testing.expectEqual(@as(i64, 42), (try s.execute("Answer:i64=42")).get("Answer").?.integer);
}

test "deep defaults expand earlier acyclic schemas without native or expression recursion" {
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("r0:=struct{Value:i64=42};");
    for (1..120) |index| try out.print("r{d}:=struct{{Item:r{d}=r{d}{{}}}};", .{ index, index - 1, index - 1 });
    try out.writeAll("Deep:r119=r119{};Answer:i64=Deep");
    for (0..119) |_| try out.writeAll(".Item");
    try out.writeAll(".Value");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 42), result.get("Answer").?.integer);
    try std.testing.expectEqual(@as(usize, 120), result.program.definitions.len);
    try std.testing.expectEqual(@as(usize, 120), result.aggregate_values.len);
}

test "malformed default source is recoverable and successful mutations agree across engines" {
    const s = try storage();
    defer scratch.release(s);
    const original = "Seed:i64=9;p:=struct{X:i64=Seed+1,A:[]i64=array{}};Make(N:i64)<computes>:p=p{X:=N};Value:p=Make(2);Other:p=p{};Count:i64=Other.A.Length";
    const mutations = "{}[]().,:;=+-*/<>\n\"\\";
    for (0..3000) |iteration| {
        @memcpy(s.source[0..original.len], original);
        const position = (iteration * 37) % original.len;
        s.source[position] = mutations[(iteration / original.len) % mutations.len];
        switch (s.compiler.compile(s.source[0..original.len])) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= original.len),
            .ok => |program| try s.equalResults(
                evaluator.evaluateWithStorage(program, &s.values, &s.members, types.limits.nodes * 2),
                s.runtime.evaluate(program, types.limits.nodes * 2),
            ),
        }
        if (iteration % 128 == 0) try std.testing.expectEqual(@as(i64, 42), (try s.execute("Answer:i64=42")).get("Answer").?.integer);
    }
    const result = try s.execute(original);
    try std.testing.expectEqual(@as(i64, 0), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 10), result.elements(result.get("Other").?).?[0].integer);
}
