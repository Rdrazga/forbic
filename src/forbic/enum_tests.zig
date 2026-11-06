//! Independent closed-enum source, admission and execution acceptance tests.
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
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [types.limits.source_bytes]u8 = undefined,

    fn execute(self: *Storage, source: []const u8) !evaluator.Execution {
        const program = switch (self.compiler.compile(source)) {
            .ok => |program| program,
            .failed => |diagnostic| {
                std.debug.print("enum compile failed at {d}: {s}\n", .{ diagnostic.span.start, diagnostic.message() });
                return error.UnexpectedCompile;
            },
        };
        const reference = evaluator.evaluateWithStorage(program, &self.values, &self.members, types.limits.evaluation_work);
        const actual = self.runtime.evaluate(program, types.limits.evaluation_work);
        try equalResults(reference, actual);
        if (actual == .failed) return error.UnexpectedEvaluation;
        return actual.ok;
    }

    fn rejectSource(self: *Storage, source: []const u8, code: ?types.Diagnostic.Code) !void {
        const result = self.compiler.compile(source);
        try std.testing.expectEqual(std.meta.Tag(compiler.Result).failed, std.meta.activeTag(result));
        if (code) |expected| try std.testing.expectEqual(expected, result.failed.code);
        try std.testing.expect(result.failed.span.start <= result.failed.span.end and result.failed.span.end <= source.len);
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

fn storage() !*Storage {
    const result = try scratch.make(Storage);
    return result;
}

fn expectCase(execution: evaluator.Execution, value: types.Value, type_name: []const u8, case_name: []const u8, index: u32) !void {
    try std.testing.expectEqual(std.meta.Tag(types.Value).enumeration, std.meta.activeTag(value));
    try std.testing.expectEqual(index, value.enumeration.index);
    const definition = catalogue.definition(value.enumeration.value_type, execution.program.definitions).?;
    try std.testing.expectEqualStrings(type_name, definition.enumeration.name.text(execution.program.source));
    try std.testing.expectEqualStrings(case_name, catalogue.caseAt(value.enumeration.value_type, index, execution.program.definitions, execution.program.cases).?.text(execution.program.source));
}

test "nominal enum constants compose with templates defaults nested records and contextual arrays" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\mode<public> := enum<closed> { Light, Dark, }
        \\alignment := enum { Left, Right }
        \\Initial:mode = mode.Dark
        \\Identity(M:mode)<computes>:mode = M
        \\Captured()<computes>:mode = Initial
        \\settings := struct {
        \\    Mode:mode = Captured()
        \\    Allowed:[]mode = array{mode.Light,Identity(mode.Dark)}
        \\    Empty:[]mode = array{}
        \\}
        \\container := struct { Settings:settings = settings{}, Alignment:alignment = alignment.Right }
        \\Default:container = container{}
        \\Custom:container = container{Settings := settings{Mode := Identity(mode.Light)}}
        \\Selected<public>:mode = Default.Settings.Mode
        \\Other:mode = Custom.Settings.Mode
        \\Count:i64 = Default.Settings.Allowed.Length
        \\Modes:[][]mode = array{array{},array{Captured(),Identity(mode.Light)}}
        \\Keep(Values:[]mode)<computes>:[]mode = Values
        \\Zero:i64 = Keep(array{}).Length
    );
    try expectCase(result, result.get("Selected").?, "mode", "Dark", 1);
    try expectCase(result, result.get("Other").?, "mode", "Light", 0);
    try std.testing.expectEqual(@as(i64, 2), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.get("Zero").?.integer);
    const rows = result.elements(result.get("Modes").?).?;
    try std.testing.expectEqual(@as(usize, 0), result.elements(rows[0]).?.len);
    try expectCase(result, result.elements(rows[1]).?[0], "mode", "Dark", 1);
    try std.testing.expect(result.program.definitions[0].enumeration.is_public);
}

test "enum case indexes are declaration-local even when spellings recur across types" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute("first:=enum{A,B,C};second:=enum{B,A};X:first=first.B;Y:second=second.B;Alias:first=X");
    try expectCase(result, result.get("X").?, "first", "B", 1);
    try expectCase(result, result.get("Y").?, "second", "B", 0);
    try std.testing.expect(result.get("X").?.enumeration.value_type != result.get("Y").?.enumeration.value_type);
    try std.testing.expectEqualDeep(result.get("X").?, result.get("Alias").?);
}

test "qualified case spellings include literal builtin and syntax identifiers" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\mode := enum {
        \\    true
        \\    false
        \\    i64, float, logic, string, struct, array, enum, closed, Inf, NaN,
        \\}
        \\A:mode = mode.true
        \\B:mode = mode.i64
        \\C:mode = mode.enum
        \\D:mode = mode.Inf
        \\E:mode = mode.NaN
    );
    try expectCase(result, result.get("A").?, "mode", "true", 0);
    try expectCase(result, result.get("B").?, "mode", "i64", 2);
    try expectCase(result, result.get("C").?, "mode", "enum", 8);
    try expectCase(result, result.get("D").?, "mode", "Inf", 10);
    try expectCase(result, result.get("E").?, "mode", "NaN", 11);
}

test "parameters may not shadow enum qualifiers and default field names do not create local bindings" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\mode := enum { Light, Dark }
        \\holder := struct { Dark:i64 = 42 }
        \\Read(item:holder)<computes>:i64 = item.Dark
        \\Keep(item:mode)<computes>:mode = item
        \\defaults := struct { mode:mode = mode.Dark }
        \\Answer:i64 = Read(holder{})
        \\Selected:mode = Keep(mode.Light)
        \\Default:defaults = defaults{}
    );
    try std.testing.expectEqual(@as(i64, 42), result.get("Answer").?.integer);
    try expectCase(result, result.get("Selected").?, "mode", "Light", 0);
    try expectCase(result, result.elements(result.get("Default").?).?[0], "mode", "Dark", 1);
    // RFC-0076 rule 1: a parameter named like the enum shadowed its qualifier (so `mode.Dark`
    // was a field access, and the last two were `type_mismatch`); the parameter is refused now.
    try s.rejectSource("mode:=enum{Light,Dark};holder:=struct{Dark:i64=42};Read(mode:holder)<computes>:i64=mode.Dark", .shadowed_name);
    try s.rejectSource("mode:=enum{Light,Dark};Read(mode:i64)<computes>:mode=mode.Dark", .shadowed_name);
    try s.rejectSource("mode:=enum{Light,Dark};Read(mode:mode)<computes>:mode=mode.Dark", .shadowed_name);
    // A parameter of another name is still no qualifier: a field access on an i64 or an enum value.
    try s.rejectSource("mode:=enum{Light,Dark};Read(item:i64)<computes>:mode=item.Dark", .type_mismatch);
    try s.rejectSource("mode:=enum{Light,Dark};Read(item:mode)<computes>:mode=item.Dark", .type_mismatch);
}

test "empty enums remain uninhabited while empty arrays and unused signatures are valid" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute("empty:=enum<closed>{};Identity(X:empty)<computes>:empty=X;Values:[]empty=array{};Count:i64=Values.Length");
    try std.testing.expectEqual(@as(i64, 0), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), result.program.cases.len);
    try std.testing.expect(catalogue.caseAt(@fromBackingInt(@as(u16, 4)), 0, result.program.definitions, result.program.cases) == null);
    try s.rejectSource("empty:=enum{};Value:empty=empty.Any", .unknown_case);
    try s.rejectSource("empty:=enum{};Value:empty=empty{}", null);
}

test "enum admission rejects nominal coercions operations unsupported specifiers and ambiguous names" {
    const s = try storage();
    defer scratch.release(s);
    const cases = .{
        .{ "mode:=enum{A,A}", types.Diagnostic.Code.duplicate_case },
        .{ "mode:=enum{A};Value:mode=mode.B", types.Diagnostic.Code.unknown_case },
        .{ "mode:=enum{A};other:=enum{A};Value:mode=other.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:i64=mode.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:string=mode.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:mode=mode.A+mode.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:mode=-mode.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:i64=mode.A.Length", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};Value:mode=mode.A.A", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};other:=enum{A};Values:[]mode=array{mode.A,other.A}", types.Diagnostic.Code.type_mismatch },
        .{ "mode:=enum{A};r:=struct{Mode:mode=1}", types.Diagnostic.Code.type_mismatch },
        // RFC-0083 made `enum<open>` a form; any other specifier is still refused.
        .{ "mode:=enum<shut>{A}", types.Diagnostic.Code.unsupported_specifier },
        // RFC-0087, P5.2 made `enum<persistable>` a form too; each specifier is said once.
        .{ "mode:=enum<persistable><persistable>{A}", types.Diagnostic.Code.unsupported_specifier },
        .{ "mode:=enum{1}", types.Diagnostic.Code.expected_case },
        .{ "mode:=enum{A};mode:=struct{}", types.Diagnostic.Code.duplicate_name },
        .{ "mode:=struct{};mode:=enum{A}", types.Diagnostic.Code.duplicate_name },
        .{ "mode:=enum{A};mode:i64=1", types.Diagnostic.Code.duplicate_name },
        .{ "enum:=enum{A}", types.Diagnostic.Code.expected_name },
        .{ "Value:mode=mode.A;mode:=enum{A}", types.Diagnostic.Code.unsupported_type },
    };
    inline for (cases) |case| try s.rejectSource(case[0], case[1]);
    inline for (.{ "mode:=enum{A};Value:mode=mode", "mode:=enum{A};Value:mode=mode{}", "mode:=enum{A};Value:mode=mode()", "mode:=enum{A};Value:mode=mode." }) |source| try s.rejectSource(source, null);
    try std.testing.expectEqual(@as(i64, 42), (try s.execute("Answer:i64=42")).get("Answer").?.integer);
}

test "exact per-enum and total case quotas remain ordinary checked source outcomes" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    for (0..4) |enumeration| {
        try out.print("e{d}:=enum{{", .{enumeration});
        for (0..types.limits.enum_cases) |index| try out.print("{s}C{d}", .{ if (index == 0) "" else ",", index });
        try out.writeAll("};");
    }
    try out.writeAll("First:e0=e0.C255;Last:e3=e3.C255");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(types.limits.cases, result.program.cases.len);
    try expectCase(result, result.get("First").?, "e0", "C255", 255);
    try expectCase(result, result.get("Last").?, "e3", "C255", 255);
    const full_source_end = out.end;
    try out.writeAll(";Empty:=enum{}");
    try std.testing.expectEqual(types.limits.cases, (try s.execute(out.buffered())).program.cases.len);
    out.end = full_source_end;
    try out.writeAll(";Overflow:=enum{Extra}");
    try s.rejectSource(out.buffered(), .case_limit);
    out.end = 0;
    try out.writeAll("mode:=enum{");
    for (0..types.limits.enum_cases + 1) |index| try out.print("{s}C{d}", .{ if (index == 0) "" else ",", index });
    try out.writeAll("}");
    try s.rejectSource(out.buffered(), .case_limit);
    const recovered = try s.execute("mode:=enum{A};Value:mode=mode.A");
    try expectCase(recovered, recovered.get("Value").?, "mode", "A", 0);
}

test "all 256 intentionally colliding case names are admitted with probe wraparound" {
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("mode:=enum{");
    var found: usize = 0;
    var name_bytes: [8]u8 = undefined;
    var last: [8]u8 = undefined;
    for (0..256 * 512 * 4) |candidate| {
        if (found == 256) break;
        const name = try std.fmt.bufPrint(&name_bytes, "N{d:0>7}", .{candidate});
        if (std.hash.Wyhash.hash(0, name) % 512 != 511) continue;
        if (found != 0) try out.writeByte(',');
        try out.writeAll(name);
        @memcpy(&last, name);
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 256), found);
    try out.print("}};Value:mode=mode.{s}", .{last});
    const result = try s.execute(out.buffered());
    try expectCase(result, result.get("Value").?, "mode", &last, 255);
}

const origin: types.Span = .{ .start = 0, .end = 0 };
const raw_source = "Mode Light Dark Other Pair Value Items Tail";
const mode: types.Type = @fromBackingInt(@as(u16, 4));
const other: types.Type = @fromBackingInt(@as(u16, 5));
const modes: types.Type = @fromBackingInt(@as(u16, 6));
const pair: types.Type = @fromBackingInt(@as(u16, 7));
const raw_cases = [_]types.Span{ .{ .start = 5, .end = 10 }, .{ .start = 11, .end = 15 }, .{ .start = 5, .end = 10 } };
const raw_definitions = [_]types.Definition{
    .{ .enumeration = .{ .name = .{ .start = 0, .end = 4 }, .cases = .{ .start = 0, .end = 2 }, .is_public = true } },
    .{ .enumeration = .{ .name = .{ .start = 16, .end = 21 }, .cases = .{ .start = 2, .end = 3 }, .is_public = false } },
    .{ .array = mode },
    .{ .record = .{ .name = .{ .start = 22, .end = 26 }, .fields = .{ .start = 0, .end = 2 }, .is_public = false } },
};
const raw_fields = [_]types.Field{
    .{ .name = .{ .start = 27, .end = 32 }, .value_type = mode },
    .{ .name = .{ .start = 33, .end = 38 }, .value_type = modes },
};
const raw_nodes = [_]types.Node{
    .{ .span = origin, .value_type = mode, .kind = .{ .enumeration = 1 } },
    .{ .span = origin, .value_type = other, .kind = .{ .enumeration = 0 } },
    .{ .span = origin, .value_type = mode, .kind = .{ .enumeration = 0 } },
    .{ .span = origin, .value_type = modes, .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
    .{ .span = origin, .value_type = pair, .kind = .{ .aggregate = .{ .start = 2, .end = 4 } } },
    .{ .span = origin, .value_type = mode, .kind = .{ .field = .{ .value = 4, .index = 0 } } },
    .{ .span = origin, .value_type = modes, .kind = .{ .field = .{ .value = 4, .index = 1 } } },
    .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 6 } },
};
const raw_members = [_]u32{ 0, 2, 0, 3 };
const raw_program: types.Program = .{
    .source = raw_source,
    .strings = "",
    .nodes = &raw_nodes,
    .bindings = &.{.{ .name = .{ .start = 27, .end = 32 }, .node = 5, .value_type = mode, .is_public = true }},
    .definitions = &raw_definitions,
    .fields = &raw_fields,
    .members = &raw_members,
    .cases = &raw_cases,
};

test "manually authored enum IR uses exact nominal types and local indexes in both engines" {
    const s = try storage();
    defer scratch.release(s);
    const reference = evaluator.evaluateWithStorage(raw_program, &s.values, &s.members, raw_nodes.len + raw_members.len);
    const actual = s.runtime.evaluate(raw_program, raw_nodes.len + raw_members.len);
    try equalResults(reference, actual);
    try expectCase(actual.ok, actual.ok.values[0], "Mode", "Dark", 1);
    try expectCase(actual.ok, actual.ok.values[1], "Other", "Light", 0);
    try std.testing.expectEqual(@as(i64, 2), actual.ok.values[7].integer);
    try std.testing.expectEqualDeep(actual.ok.values[0], actual.ok.values[5]);
    try std.testing.expectEqualDeep(actual.ok.values[0], actual.ok.aggregate_values[2]);
    try std.testing.expect(actual.ok.elements(actual.ok.values[0]) == null);
    try std.testing.expect(actual.ok.elements(.{ .aggregate = .{ .value_type = mode, .elements = origin } }) == null);
    try std.testing.expect(catalogue.caseAt(.i64, 0, &raw_definitions, &raw_cases) == null);
    try std.testing.expect(catalogue.caseAt(modes, 0, &raw_definitions, &raw_cases) == null);
    try std.testing.expect(catalogue.caseAt(mode, std.math.maxInt(u32), &raw_definitions, &raw_cases) == null);
    try std.testing.expect(catalogue.caseAt(@fromBackingInt(@as(u16, 65535)), 0, &raw_definitions, &raw_cases) == null);
}

fn rejectRaw(s: *Storage, changed: types.Program) !void {
    const prior_values = s.runtime.machine.values[0..raw_nodes.len].*;
    const prior_members = s.runtime.machine.aggregate_values[0..raw_members.len].*;
    const prior_count = s.runtime.machine.aggregate_count;
    var values: [16]types.Value = @splat(.{ .integer = 42 });
    var members: [16]types.Value = @splat(.{ .integer = 42 });
    for ([_]u64{ 0, types.limits.evaluation_work }) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithStorage(changed, &values, &members, budget).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, s.runtime.evaluate(changed, budget).failed.code);
        for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
        for (members) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
        try std.testing.expectEqualDeep(prior_values, s.runtime.machine.values[0..raw_nodes.len].*);
        try std.testing.expectEqualDeep(prior_members, s.runtime.machine.aggregate_values[0..raw_members.len].*);
        try std.testing.expectEqual(prior_count, s.runtime.machine.aggregate_count);
    }
}

test "malformed enum catalogues including unused definitions and case tails fail before execution" {
    const s = try storage();
    defer scratch.release(s);
    _ = s.runtime.evaluate(raw_program, types.limits.evaluation_work).ok;
    var changed = raw_program;
    var definitions = raw_definitions;
    changed.definitions = &definitions;
    const invalid_ranges = [_]types.Span{ .{ .start = 1, .end = 2 }, .{ .start = 2, .end = 1 }, .{ .start = 0, .end = 4 }, .{ .start = 0, .end = 257 }, .{ .start = std.math.maxInt(u32), .end = 0 } };
    for (invalid_ranges) |range| {
        definitions[0].enumeration.cases = range;
        try rejectRaw(s, changed);
    }
    definitions = raw_definitions;
    definitions[1].enumeration.name = definitions[0].enumeration.name;
    try rejectRaw(s, changed);
    definitions = raw_definitions;
    definitions[3].record.name = definitions[0].enumeration.name;
    try rejectRaw(s, changed);
    definitions = raw_definitions;
    definitions[1].enumeration.name = .{ .start = 40, .end = 44 };
    try rejectRaw(s, changed);
    changed = raw_program;
    var cases = raw_cases;
    changed.cases = &cases;
    for ([_]types.Span{ origin, .{ .start = 11, .end = 10 }, .{ .start = 5, .end = 65535 }, raw_cases[0] }) |span| {
        cases[1] = span;
        try rejectRaw(s, changed);
    }
    changed = raw_program;
    changed.cases = raw_cases[0..2];
    try rejectRaw(s, changed);
    const extra_cases = raw_cases ++ [_]types.Span{.{ .start = 39, .end = 43 }};
    changed.cases = &extra_cases;
    try rejectRaw(s, changed);
    var tail_cases = extra_cases;
    tail_cases[3] = origin;
    const extra_definitions = raw_definitions ++ [_]types.Definition{.{ .enumeration = .{ .name = .{ .start = 39, .end = 43 }, .cases = .{ .start = 3, .end = 4 }, .is_public = false } }};
    changed.definitions = &extra_definitions;
    changed.cases = &tail_cases;
    try rejectRaw(s, changed);
    try std.testing.expect(!catalogue.validateWithCases(&.{}, &.{}, &.{raw_cases[0]}, raw_source));
    const oversized_cases: [types.limits.cases + 1]types.Span = @splat(raw_cases[0]);
    try std.testing.expect(!catalogue.validateWithCases(&raw_definitions, &raw_fields, &oversized_cases, raw_source));
    _ = s.runtime.evaluate(raw_program, types.limits.evaluation_work).ok;
}

test "invalid enum IR literal types and indexes win over earlier arithmetic or fuel failures" {
    const s = try storage();
    defer scratch.release(s);
    _ = s.runtime.evaluate(raw_program, types.limits.evaluation_work).ok;
    const invalid_nodes = [_]types.Node{
        .{ .span = origin, .value_type = mode, .kind = .{ .enumeration = 2 } },
        .{ .span = origin, .value_type = other, .kind = .{ .enumeration = 1 } },
        .{ .span = origin, .value_type = mode, .kind = .{ .enumeration = std.math.maxInt(u32) } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .enumeration = 0 } },
        .{ .span = origin, .value_type = modes, .kind = .{ .enumeration = 0 } },
        .{ .span = origin, .value_type = pair, .kind = .{ .enumeration = 0 } },
        .{ .span = origin, .value_type = @fromBackingInt(@as(u16, 65535)), .kind = .{ .enumeration = 0 } },
        .{ .span = origin, .value_type = mode, .kind = .{ .integer = 0 } },
        .{ .span = origin, .value_type = mode, .kind = .{ .aggregate = origin } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .field = .{ .value = 0, .index = 0 } } },
    };
    for (invalid_nodes) |tail| {
        const nodes = raw_nodes ++ [_]types.Node{tail};
        var changed = raw_program;
        changed.nodes = &nodes;
        try rejectRaw(s, changed);
    }
    const early_failure = [_]types.Node{
        .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 1 } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 0 } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .binary = .{ .op = .divide, .lhs = 0, .rhs = 1 } } },
        invalid_nodes[0],
    };
    var changed = raw_program;
    changed.nodes = &early_failure;
    changed.bindings = &.{};
    changed.members = &.{};
    try rejectRaw(s, changed);
    var empty_definitions = raw_definitions;
    empty_definitions[0].enumeration.cases = origin;
    empty_definitions[1].enumeration.cases = .{ .start = 0, .end = 1 };
    changed = raw_program;
    changed.definitions = &empty_definitions;
    changed.cases = raw_cases[0..1];
    try rejectRaw(s, changed);
}

test "malformed enum bytecode preserves prior values journal state and committed intents" {
    const s = try storage();
    defer scratch.release(s);
    const committed = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 31 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .op = .{ .enqueue = .{ .kind = 7, .argument = 0 } } },
        .{ .op = .commit },
    };
    _ = s.runtime.machine.run(.{ .code = &committed }, committed.len).ok;
    _ = s.runtime.evaluate(raw_program, types.limits.evaluation_work).ok;
    const prior_values = s.runtime.machine.values[0..raw_nodes.len].*;
    const prior_members = s.runtime.machine.aggregate_values[0..raw_members.len].*;
    const lowered = bytecode.lower(raw_program, &s.runtime.instructions).ok;
    const invalid_literals = [_]vm.Instruction{
        .{ .value_type = mode, .op = .{ .enumeration = 2 } },
        .{ .value_type = other, .op = .{ .enumeration = std.math.maxInt(u32) } },
        .{ .value_type = .i64, .op = .{ .enumeration = 0 } },
        .{ .value_type = modes, .op = .{ .enumeration = 0 } },
        .{ .op = .{ .enumeration = 0 } },
        .{ .value_type = mode, .op = .{ .aggregate = .{ .start = 4, .end = 4 } } },
    };
    var code: [raw_nodes.len + 1]vm.Instruction = undefined;
    @memcpy(code[0..raw_nodes.len], lowered.code);
    for (invalid_literals) |instruction| {
        code[raw_nodes.len] = instruction;
        var changed = lowered;
        changed.code = &code;
        for ([_]u64{ 0, types.limits.evaluation_work }) |budget| {
            try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, s.runtime.machine.run(changed, budget).failed.code);
            try std.testing.expectEqualDeep(prior_values, s.runtime.machine.values[0..raw_nodes.len].*);
            try std.testing.expectEqualDeep(prior_members, s.runtime.machine.aggregate_values[0..raw_members.len].*);
            try std.testing.expectEqual(@as(usize, raw_members.len), s.runtime.machine.aggregate_count);
            try std.testing.expectEqual(@as(i64, 31), try s.runtime.machine.journal.read(0));
            try std.testing.expectEqual(@as(usize, 1), s.runtime.machine.journal.committed().len);
            try std.testing.expectEqual(@as(usize, 0), s.runtime.machine.journal.depth);
        }
    }
}

test "enum literals cost one fuel unit and scalar reuse clears aggregate execution state" {
    const s = try storage();
    defer scratch.release(s);
    const program = s.compiler.compile("mode:=enum{Light,Dark};Value:mode=mode.Dark").ok;
    var values: [1]types.Value = .{.{ .integer = 42 }};
    const reference = evaluator.evaluate(program, &values, 0);
    const actual = s.runtime.evaluate(program, 0);
    try equalResults(reference, actual);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.failed.code);
    try std.testing.expectEqual(@as(i64, 42), values[0].integer);
    try equalResults(evaluator.evaluate(program, &values, 1), s.runtime.evaluate(program, 1));
    _ = s.runtime.evaluate(raw_program, types.limits.evaluation_work).ok;
    const result = try s.execute("mode:=enum{Only};Value:mode=mode.Only");
    try std.testing.expectEqual(@as(usize, 0), result.aggregate_values.len);
    try std.testing.expectEqual(@as(usize, 0), s.runtime.machine.aggregate_count);
}

test "qualified enum reports admit exact work and bytes and reject forged literal values before output" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute("mode:=enum{Light,Dark};Value<public>:mode=mode.Dark");
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const stats = try reporting.write(&out, result, false, .{});
    try std.testing.expectEqualStrings("{\"Value\":\"mode.Dark\"}\n", out.buffered());
    out.end = 0;
    _ = try reporting.write(&out, result, false, .{ .work = stats.work, .output_bytes = stats.output_bytes });
    out.end = 0;
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, result, false, .{ .work = stats.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, result, false, .{ .output_bytes = stats.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const valid = s.runtime.machine.values[0];
    for ([_]types.Value{
        .{ .enumeration = .{ .value_type = valid.enumeration.value_type, .index = std.math.maxInt(u32) } },
        .{ .enumeration = .{ .value_type = valid.enumeration.value_type, .index = 0 } },
        .{ .enumeration = .{ .value_type = .i64, .index = 0 } },
        .{ .enumeration = .{ .value_type = @fromBackingInt(@as(u16, 65535)), .index = 0 } },
        .{ .aggregate = .{ .value_type = valid.enumeration.value_type, .elements = origin } },
    }) |forged| {
        s.runtime.machine.values[0] = forged;
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, result, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    s.runtime.machine.values[0] = valid;
    const nested = try s.execute("mode:=enum{Light,Dark};r:=struct{Mode:mode=mode.Dark,Modes:[]mode=array{mode.Light,mode.Dark}};Value<public>:r=r{}");
    out.end = 0;
    _ = try reporting.write(&out, nested, false, .{});
    try std.testing.expectEqualStrings("{\"Value\":{\"Mode\":\"mode.Dark\",\"Modes\":[\"mode.Light\",\"mode.Dark\"]}}\n", out.buffered());
}

test "inspection version three reports enum catalogue case names once and local literal indexes" {
    const s = try storage();
    defer scratch.release(s);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    var buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const program = s.compiler.compile("mode<public>:=enum{Light,Dark};unused:=enum{};Value:mode=mode.Dark").ok;
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, program));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("format").?.integer);
    const definitions = object.get("type_definitions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), definitions.len);
    try std.testing.expectEqualStrings("enumeration", definitions[0].object.get("kind").?.string);
    try std.testing.expect(definitions[0].object.get("public").?.bool);
    try std.testing.expectEqualStrings("unused", definitions[1].object.get("name").?.string);
    const cases = object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    try std.testing.expectEqualStrings("Dark", cases[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 1), cases[1].object.get("index").?.integer);
    const literal = object.get("instructions").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 4), literal.get("type").?.integer);
    try std.testing.expectEqual(@as(i64, 1), literal.get("op").?.object.get("enumeration").?.integer);
    out.end = 0;
    const scalar = s.compiler.compile("Value:i64=1").ok;
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, scalar));
    const scalar_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer scalar_json.deinit();
    try std.testing.expectEqual(@as(i64, 1), scalar_json.value.object.get("format").?.integer);
    try std.testing.expect(scalar_json.value.object.get("cases") == null);
}

test "enum source mutations never expose assertions and independently replay successful results" {
    const s = try storage();
    defer scratch.release(s);
    const original = "mode:=enum<closed>{Light,Dark};r:=struct{Mode:mode=mode.Dark,Allowed:[]mode=array{mode.Light}};Keep(M:mode)<computes>:mode=M;Value:r=r{Mode:=Keep(mode.Light)};Selected:mode=Value.Mode";
    const mutations = "{}[]().,:;=+-*/<>\n\"\\";
    for (0..4000) |iteration| {
        @memcpy(s.source[0..original.len], original);
        const position = (iteration * 37) % original.len;
        s.source[position] = mutations[(iteration / original.len) % mutations.len];
        switch (s.compiler.compile(s.source[0..original.len])) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= original.len),
            .ok => |program| try equalResults(
                evaluator.evaluateWithStorage(program, &s.values, &s.members, types.limits.evaluation_work),
                s.runtime.evaluate(program, types.limits.evaluation_work),
            ),
        }
    }
    const result = try s.execute(original);
    try expectCase(result, result.get("Selected").?, "mode", "Light", 0);
}
