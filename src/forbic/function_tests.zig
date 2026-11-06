const std = @import("std");
const scratch = @import("scratch.zig");
const support = @import("test_support.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const types = @import("types.zig");

fn workspace() !*support.Workspace {
    const result = try scratch.storage(support.Workspace);
    scratch.initialise(result);
    return result;
}

test "function name index survives colliding probes, full identifiers, and reuse" {
    try @import("profile.zig").requireBootstrap();
    const frontend = try workspace();
    defer scratch.release(frontend);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(source);
    var names: [types.limits.functions + 1][15]u8 = undefined;
    var found: usize = 0;
    for (0..65536) |candidate| {
        var bytes: [15]u8 = undefined;
        const name = try std.fmt.bufPrint(&bytes, "Collision{d:0>6}", .{candidate});
        if (std.hash.Wyhash.hash(0, name) % (types.limits.functions * 2) != 0) continue;
        names[found] = bytes;
        found += 1;
        if (found == names.len) break;
    }
    try std.testing.expectEqual(names.len, found);
    var writer: std.Io.Writer = .fixed(source);
    for (names[0..types.limits.functions], 0..) |name, index| try writer.print("{s}()<computes>:i64={d};", .{ name, index });
    try writer.writeAll("Result:i64=0");
    for (names[0..types.limits.functions]) |name| try writer.print("+{s}()", .{name});
    const result = try execute(frontend, writer.buffered());
    try std.testing.expectEqual(@as(i64, 2016), result.get("Result").?.integer);
    try writer.print(";Missing:i64={s}()", .{names[types.limits.functions]});
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, frontend.compile(writer.buffered()).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_name, frontend.compile("F()<computes>:i64=1;F()<computes>:i64=2").failed.code);
    // Reset after a partial failed compile clears every index entry.
    try std.testing.expectEqual(@as(i64, 9), (try execute(frontend, "F()<computes>:i64=9;Result:i64=F()")).get("Result").?.integer);
    writer = .fixed(source);
    var long_name: [types.limits.identifier_bytes]u8 = @splat('A');
    for (0..types.limits.functions) |index| {
        _ = try std.fmt.bufPrint(long_name[long_name.len - 2 ..], "{d:0>2}", .{index});
        try writer.print("{s}()<computes>:i64={d};", .{ long_name, index });
    }
    try writer.writeAll("Result:i64=0");
    for (0..types.limits.functions) |index| {
        _ = try std.fmt.bufPrint(long_name[long_name.len - 2 ..], "{d:0>2}", .{index});
        try writer.print("+{s}()", .{long_name});
    }
    try std.testing.expectEqual(@as(i64, 2016), (try execute(frontend, writer.buffered())).get("Result").?.integer);
    try std.testing.expectEqual(types.limits.functions, frontend.compiler.functions.count);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, frontend.compile("Result:i64=Collision000000()").failed.code);
    try std.testing.expectEqual(@as(u32, 0), frontend.compiler.functions.count);
    // The table of names is empty again, and it was emptied without touching its slots.
    try std.testing.expectEqual(@as(u32, 0), frontend.compiler.functions.table.live);
    try std.testing.expect(frontend.compiler.functions.find("F", "F") == null);
}

fn execute(frontend: *support.Workspace, source: []const u8) !evaluator.Execution {
    const program = switch (frontend.compile(source)) {
        .ok => |program| program,
        .failed => |diagnostic| {
            std.debug.print("unexpected function compile diagnostic: {s}\n", .{diagnostic.message()});
            return error.UnexpectedDiagnostic;
        },
    };
    return switch (evaluator.evaluate(program, &frontend.values, types.limits.nodes)) {
        .ok => |execution| execution,
        .failed => error.UnexpectedDiagnostic,
    };
}

test "pure functions compose earlier declarations and typed lexical parameters" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const execution = try execute(frontend,
        \\Base:i64=3
        \\Double<public>(X:i64)<computes>:i64 = X * 2
        \\Offset(Seed:i64, Y:i64)<computes>:i64 = Double(Seed) + Y
        \\Captured()<computes>:i64 = Base
        \\Identity(S:string)<computes>:string = S
        \\Enabled(B:logic)<computes>:logic = B
        \\Result<public>:i64 = Offset(Double(4), Captured()) / 2
        \\Theme:string = Identity("snow: \"雪\"\n")
        \\Animations:logic = Enabled(false)
    );
    try std.testing.expectEqual(@as(i64, 9), execution.get("Result").?.integer);
    try std.testing.expectEqualStrings("snow: \"雪\"\n", execution.get("Theme").?.string);
    try std.testing.expect(!execution.get("Animations").?.boolean);
    try std.testing.expectEqual(@as(usize, 4), execution.program.bindings.len);
    try std.testing.expect(execution.get("Double") == null);
    try std.testing.expect(frontend.compiler.functions.definitions[0].is_public);
    // RFC-0076 rule 1: `Offset`'s first parameter was named `Base` and shadowed the binding.
    const shadowing = "Base:i64=3\nOffset(Base:i64, Y:i64)<computes>:i64 = Base + Y";
    const rejected = frontend.compile(shadowing);
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, rejected.failed.code);
    try std.testing.expectEqual(std.mem.indexOf(u8, shadowing, "(Base").? + 1, rejected.failed.span.start);
}

test "call delimiters, unary signs, multiline signatures, and empty argument lists are precise" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const execution = try execute(frontend,
        \\Sum(
        \\    A:i64,
        \\    B:i64
        \\)<computes>:i64=A+B
        \\Constant()<computes>:i64=-9223372036854775808
        \\Identity(X:i64)<computes>:i64=X
        \\A:i64=1+Sum((2+3)*4, -Sum(1,2))*2
        \\B:i64=Identity(Constant())
        \\C:i64=Sum(
        \\    Sum(1, 2),
        \\    Sum(3, 4)
        \\)
    );
    try std.testing.expectEqual(@as(i64, 35), execution.get("A").?.integer);
    try std.testing.expectEqual(std.math.minInt(i64), execution.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 10), execution.get("C").?.integer);
}

test "unused function templates do not execute and call arguments are strict" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const unused = try execute(frontend, "Bad()<computes>:i64=1/0; A:i64=5");
    try std.testing.expectEqual(@as(usize, 1), unused.program.nodes.len);
    const source = "First(A:i64,B:i64)<computes>:i64=A; Result:i64=First(1,2/0)";
    const program = frontend.compile(source).ok;
    const failure = evaluator.evaluate(program, &frontend.values, types.limits.nodes).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, failure.code);
    try std.testing.expectEqualStrings("/", failure.span.text(source));
}

test "function signatures, calls, namespaces, and forward references reject invalid source" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(X:i64):i64=X", .code = .expected_computes },
        .{ .source = "F(X:i64)<suspends>:i64=X", .code = .expected_computes },
        .{ .source = "F(X:int)<computes>:i64=1", .code = .unsupported_type },
        .{ .source = "F(X:i64)<computes>:logic=X", .code = .type_mismatch },
        .{ .source = "F(X:i64,X:i64)<computes>:i64=X", .code = .duplicate_name },
        .{ .source = "F(true:i64)<computes>:i64=1", .code = .expected_parameter },
        .{ .source = "F(X:i64,)<computes>:i64=X", .code = .expected_parameter },
        .{ .source = "F(X:i64)<computes>:i64=Y", .code = .unknown_name },
        .{ .source = "F(X:i64)<computes>:i64=F(true)", .code = .type_mismatch },
        // RFC-0091: a body may call a function declared further down; the root may not.
        .{ .source = "A:i64=G(1);G(X:i64)<computes>:i64=X", .code = .unknown_name },
        .{ .source = "F()<computes>:i64=1;F:i64=2", .code = .duplicate_name },
        .{ .source = "F:i64=1;F()<computes>:i64=2", .code = .duplicate_name },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=F", .code = .type_mismatch },
        .{ .source = "F:i64=1;A:i64=F(2)", .code = .not_callable },
        .{ .source = "F(X:i64)<computes>:i64=X(2)", .code = .not_callable },
        .{ .source = "A:i64=true()", .code = .not_callable },
        .{ .source = "A:i64=F(2)", .code = .unknown_name },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=F()", .code = .argument_count },
        .{ .source = "F()<computes>:i64=1;A:i64=F(2)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=F(1,2)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=F(true)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=F(-)", .code = .expected_expression },
        .{ .source = "F(X:i64,Y:i64)<computes>:i64=X;A:i64=F(1,)", .code = .expected_expression },
        .{ .source = "A:i64=(1,2)", .code = .unexpected_token },
    };
    for (cases) |case| {
        const result = frontend.compile(case.source);
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(case.code, result.failed.code);
        try std.testing.expect(result.failed.span.end <= case.source.len);
    }
    try std.testing.expectEqual(@as(i64, 7), (try execute(frontend, "A:i64=7")).get("A").?.integer);
}

fn compare(frontend: *support.Workspace, runtime: *bytecode.Workspace, source: []const u8) !evaluator.Result {
    const program = frontend.compile(source).ok;
    const expected = evaluator.evaluate(program, &frontend.values, types.limits.nodes);
    const actual = runtime.evaluate(program, types.limits.nodes);
    switch (expected) {
        .failed => |diagnostic| try std.testing.expectEqualDeep(diagnostic, actual.failed),
        .ok => |execution| try std.testing.expectEqualDeep(execution.values, actual.ok.values),
    }
    return expected;
}

test "2,000 generated function compositions agree with arithmetic and register VM" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    var source: [512]u8 = undefined;
    for (0..2000) |index| {
        const a: i64 = @as(i64, @intCast(index)) - 1000;
        const b: i64 = @intCast(index % 17 + 1);
        var writer: std.Io.Writer = .fixed(&source);
        try writer.print("Base:i64={d};Scale(X:i64)<computes>:i64=(X+3)*{d};Compose(X:i64,Y:i64)<computes>:i64=Scale(X)/Y+Base;A:i64=Compose({d},{d});B:i64=Scale(Scale({d}))", .{ a, b, a, b, a });
        const execution = (try compare(frontend, runtime, writer.buffered())).ok;
        try std.testing.expectEqual(a * 2 + 3, execution.get("A").?.integer);
        try std.testing.expectEqual(((a + 3) * b + 3) * b, execution.get("B").?.integer);
    }
    for ([_][]const u8{
        "F(X:i64)<computes>:i64=X+1;A:i64=F(9223372036854775807)",
        "F(X:i64)<computes>:i64=1/X;A:i64=F(0)",
        "F(X:i64)<computes>:i64=-X;A:i64=F(-9223372036854775808)",
    }) |case| _ = try compare(frontend, runtime, case);
}

test "function, parameter, template, expansion, and nested-call budgets reject exhaustion" {
    try @import("profile.zig").requireBootstrap();
    const frontend = try workspace();
    defer scratch.release(frontend);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(source);
    var writer: std.Io.Writer = .fixed(source);
    for (0..types.limits.functions + 1) |index| try writer.print("F{d}()<computes>:i64=1\n", .{index});
    try std.testing.expectEqual(types.Diagnostic.Code.function_limit, frontend.compile(writer.buffered()).failed.code);
    writer = .fixed(source);
    try writer.writeAll("F(");
    for (0..types.limits.parameters + 1) |index| try writer.print("{s}P{d}:i64", .{ if (index == 0) "" else ",", index });
    try writer.writeAll(")<computes>:i64=1");
    try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, frontend.compile(writer.buffered()).failed.code);
    writer = .fixed(source);
    try writer.writeAll("F()<computes>:i64=1");
    for (0..types.limits.template_nodes / 2) |_| try writer.writeAll("+1");
    try std.testing.expectEqual(types.Diagnostic.Code.template_limit, frontend.compile(writer.buffered()).failed.code);
    writer = .fixed(source);
    try writer.writeAll("F()<computes>:i64=1");
    for (0..types.limits.nodes / 2 - 1) |_| try writer.writeAll("+1");
    try writer.writeAll(";A:i64=F();B:i64=F()");
    const compact = frontend.compile(writer.buffered()).ok;
    try std.testing.expectEqual(@as(usize, 2), compact.nodes.len);
    try std.testing.expectEqual(types.limits.nodes - 1, compact.function_nodes.len);
    const compact_result = evaluator.evaluate(compact, &frontend.values, types.limits.nodes * 2).ok;
    try std.testing.expectEqual(@as(i64, 4096), compact_result.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4096), compact_result.get("B").?.integer);
    writer = .fixed(source);
    try writer.writeAll("F(X:i64)<computes>:i64=X;A:i64=");
    for (0..types.limits.expression_depth + 1) |_| try writer.writeAll("F(");
    try writer.writeAll("1");
    try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, frontend.compile(writer.buffered()).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try execute(frontend, "F(X:i64)<computes>:i64=X;A:i64=F(7)")).get("A").?.integer);
}

test "maximum typed parameter list and 64 earlier function definitions are usable" {
    try @import("profile.zig").requireBootstrap();
    const frontend = try workspace();
    defer scratch.release(frontend);
    var source: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);
    try writer.writeAll("F0(");
    for (0..types.limits.parameters) |index| try writer.print("{s}P{d}:i64", .{ if (index == 0) "" else ",", index });
    try writer.writeAll(")<computes>:i64=P0+P15;");
    for (1..types.limits.functions) |index| try writer.print("F{d}()<computes>:i64=F0(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);", .{index});
    try writer.writeAll("A:i64=F63()");
    try std.testing.expectEqual(@as(i64, 15), (try execute(frontend, writer.buffered())).get("A").?.integer);
    try std.testing.expectEqual(types.limits.functions, frontend.compiler.functions.count);
}

test "single-byte function mutations preserve bounded diagnostics and reusable execution" {
    const frontend = try workspace();
    defer scratch.release(frontend);
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const seed = "Base:i64=2;F(X:i64,Y:i64)<computes>:i64=(X+Y)*Base;G(X:i64)<computes>:i64=F(X,F(1,2));A:i64=G(-3)";
    const alphabet = "A1:+-*/(),\n;<>\"\\=";
    var source: [256]u8 = undefined;
    for (0..seed.len) |position| {
        for (alphabet) |byte| {
            @memcpy(source[0..seed.len], seed);
            source[position] = byte;
            switch (frontend.compile(source[0..seed.len])) {
                .failed => |diagnostic| {
                    try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
                    try std.testing.expect(diagnostic.span.end <= seed.len);
                },
                .ok => |program| {
                    const expected = evaluator.evaluate(program, &frontend.values, types.limits.nodes);
                    const actual = runtime.evaluate(program, types.limits.nodes);
                    switch (expected) {
                        .failed => |diagnostic| {
                            try std.testing.expect(diagnostic.code != .invalid_ir);
                            try std.testing.expectEqualDeep(diagnostic, actual.failed);
                        },
                        .ok => |execution| try std.testing.expectEqualDeep(execution.values, actual.ok.values),
                    }
                },
            }
        }
    }
    try std.testing.expectEqual(@as(i64, 7), (try execute(frontend, "A:i64=7")).get("A").?.integer);
}

fn selectorBody(writer: *std.Io.Writer) !void {
    // A balanced arity-four tree produces 1,024 aliases, without native recursion.
    const powers = [_]usize{ 1, 4, 16, 64, 256, 1024 };
    for (0..powers[5]) |index| {
        for (0..5) |depth| if (index % powers[5 - depth] == 0) try writer.writeAll("Pick(");
        try writer.writeByte('X');
        for (powers[1..]) |power| {
            if ((index + 1) % power != 0) break;
            try writer.writeByte(')');
        }
        if (index + 1 != powers[5]) try writer.writeByte(',');
    }
}

test "alias-only expansions consume explicit compiler work and remain reusable" {
    try @import("profile.zig").requireBootstrap();
    const frontend = try workspace();
    defer scratch.release(frontend);
    var source: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);
    try writer.writeAll("Pick(A:i64,B:i64,C:i64,D:i64)<computes>:i64=A;Big(X:i64)<computes>:i64=");
    try selectorBody(&writer);
    try writer.writeAll(";Base:i64=7;");
    const prefix_length = writer.end;
    const template_work = (1024 - 1) / (4 - 1);
    const accepted_calls = (types.limits.compiler_work - template_work) / 1024;
    for (0..accepted_calls) |index| try writer.print("Value{d}:i64=Big(Base);", .{index});
    const accepted = try execute(frontend, writer.buffered());
    try std.testing.expectEqual(@as(usize, 1), accepted.program.nodes.len);
    try std.testing.expectEqual(@as(i64, 7), accepted.get("Value62").?.integer);
    try std.testing.expectEqual(template_work + accepted_calls * 1024, frontend.compiler.expansion_work);
    try writer.print("Value{d}:i64=Big(Base);", .{accepted_calls});
    const failure = frontend.compile(writer.buffered()).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.compiler_work_limit, failure.code);
    try std.testing.expectEqualStrings("Big", failure.span.text(writer.buffered()));
    try std.testing.expect(frontend.compiler.expansion_work <= types.limits.compiler_work);
    try std.testing.expectEqual(@as(u32, 1), frontend.compiler.node_count);
    const reused = try execute(frontend, source[0..prefix_length]);
    try std.testing.expectEqual(@as(i64, 7), reused.get("Base").?.integer);
    try std.testing.expectEqual(template_work, frontend.compiler.expansion_work);
    _ = try execute(frontend, "A:i64=1");
    try std.testing.expectEqual(@as(u32, 0), frontend.compiler.expansion_work);
}
