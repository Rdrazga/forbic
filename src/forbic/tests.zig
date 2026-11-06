const std = @import("std");
const scratch = @import("scratch.zig");
const support = @import("test_support.zig");
const evaluator = @import("evaluator.zig");
const types = @import("types.zig");

fn run(workspace: *support.Workspace, source: []const u8) !evaluator.Execution {
    const program = switch (workspace.compile(source)) {
        .ok => |program| program,
        .failed => |diagnostic| {
            std.debug.print("unexpected compile error: {s}\n", .{diagnostic.message()});
            return error.UnexpectedDiagnostic;
        },
    };
    return switch (evaluator.evaluate(program, &workspace.values, types.limits.nodes)) {
        .ok => |execution| execution,
        .failed => error.UnexpectedDiagnostic,
    };
}

test "typed config respects precedence, references, strings, and visibility" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const result = try run(
        workspace,
        "Base:i64=2\nGaps<public>:i64=(Base+1)*2\nRatio:i64=90/2+10\nTheme:string=\"ka\\nna雪\"\nEnabled:logic=false\nCopy:string=Theme\n",
    );
    try std.testing.expectEqual(@as(i64, 6), result.get("Gaps").?.integer);
    try std.testing.expectEqual(@as(i64, 55), result.get("Ratio").?.integer);
    try std.testing.expectEqualStrings("ka\nna雪", result.get("Copy").?.string);
    try std.testing.expect(!result.get("Enabled").?.boolean);
    try std.testing.expect(result.program.bindings[1].is_public);
}

test "unary signs, minimum i64, and division truncation are precise" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const result = try run(workspace, "A:i64=-9223372036854775808; B:i64=-7/3; C:i64=-(2+3)*--2; D:i64=10-3-2");
    try std.testing.expectEqual(std.math.minInt(i64), result.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -2), result.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -10), result.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 5), result.get("D").?.integer);
}

test "string copies retain empty, UTF-8, escaped and full-source-boundary values" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const small = try run(workspace, "Empty:string=\"\";Plain:string=\"雪🌲\";Escaped:string=\"雪\\n\\\"\\\\\";Alias:string=Plain");
    try std.testing.expectEqualStrings("", small.get("Empty").?.string);
    try std.testing.expectEqualStrings("雪🌲", small.get("Plain").?.string);
    try std.testing.expectEqualStrings("雪\n\"\\", small.get("Escaped").?.string);
    try std.testing.expectEqualStrings("雪🌲", small.get("Alias").?.string);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(source);
    const prefix = "Text:string=\"";
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len .. source.len - 2], 'a');
    @memcpy(source[source.len - 2 ..], "\";");
    const plain = try run(workspace, source);
    const text = plain.get("Text").?.string;
    try std.testing.expectEqualStrings(source[prefix.len .. source.len - 2], text);
    try std.testing.expect(text.ptr != source[prefix.len..].ptr);
    try std.testing.expectEqual(source.len - prefix.len - 2, plain.program.strings.len);
    // A late escape after a long ordinary prefix must still use decoded storage.
    @memcpy(source[source.len - 4 .. source.len - 2], "\\n");
    const escaped = (try run(workspace, source)).get("Text").?.string;
    try std.testing.expectEqual(source.len - prefix.len - 3, escaped.len);
    try std.testing.expectEqual(@as(u8, '\n'), escaped[escaped.len - 1]);
    for (escaped[0 .. escaped.len - 1]) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
    source[0] = 0xff;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_utf8, workspace.compile(source).failed.code);
    try std.testing.expectEqualStrings("", (try run(workspace, "Text:string=\"\"")).get("Text").?.string);
}

test "invalid programs are diagnosed before evaluation" {
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "A:i64=B", .code = .unknown_name },
        .{ .source = "A:i64=1; A:i64=2", .code = .duplicate_name },
        .{ .source = "A:i64=true", .code = .type_mismatch },
        .{ .source = "A:string=\"a\"-\"b\"", .code = .type_mismatch },
        .{ .source = "A:int=1", .code = .unsupported_type },
        .{ .source = "A<transacts>:i64=1", .code = .unsupported_specifier },
        .{ .source = "A:i64=(1+2", .code = .unmatched_parenthesis },
        .{ .source = "A:i64=1+", .code = .expected_expression },
        .{ .source = "A:i64=1 2", .code = .unexpected_token },
        .{ .source = "A:i64=9223372036854775808", .code = .integer_range },
    };
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    for (cases) |case| try std.testing.expectEqual(case.code, workspace.compile(case.source).failed.code);
}

test "overflow, zero division, and work exhaustion cannot crash the evaluator" {
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "A:i64=9223372036854775807+1", .code = .arithmetic_overflow },
        .{ .source = "A:i64=-9223372036854775808/-1", .code = .arithmetic_overflow },
        .{ .source = "A:i64=1/0", .code = .division_by_zero },
        .{ .source = "A:i64=--9223372036854775808", .code = .arithmetic_overflow },
    };
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    for (cases) |case| {
        const program = workspace.compile(case.source).ok;
        try std.testing.expectEqual(case.code, evaluator.evaluate(program, &workspace.values, types.limits.nodes).failed.code);
    }
    const program = workspace.compile("A:i64=1+2").ok;
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, evaluator.evaluate(program, &workspace.values, 1).failed.code);
}

test "explicit expression stack rejects excess nesting and permits reuse after error" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    var source: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);
    try writer.writeAll("A:i64=");
    for (0..types.limits.expression_depth + 1) |_| try writer.writeByte('(');
    try writer.writeAll("1");
    try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, workspace.compile(writer.buffered()).failed.code);
    try std.testing.expectEqual(@as(i64, 2), (try run(workspace, "A:i64=2")).get("A").?.integer);
}

test "malformed indexed IR is rejected without accessing uninitialized values" {
    const node: types.Node = .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .negate = 0 } };
    const program: types.Program = .{ .source = "", .nodes = &.{node}, .bindings = &.{}, .strings = "" };
    var values: [1]types.Value = undefined;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluate(program, &values, 1).failed.code);
}

test "source, binding, and IR limits reject exhaustion with reusable storage" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes + 1);
    defer std.testing.allocator.free(source);
    @memset(source, ' ');
    try std.testing.expectEqual(types.Diagnostic.Code.source_limit, workspace.compile(source).failed.code);
    var writer: std.Io.Writer = .fixed(source);
    for (0..types.limits.bindings + 1) |index| try writer.print("Value{d}:i64={d}\n", .{ index, index });
    try std.testing.expectEqual(types.Diagnostic.Code.binding_limit, workspace.compile(writer.buffered()).failed.code);
    writer = .fixed(source);
    try writer.writeAll("A:i64=1");
    for (0..types.limits.nodes / 2) |_| try writer.writeAll("+1");
    try std.testing.expectEqual(types.Diagnostic.Code.node_limit, workspace.compile(writer.buffered()).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try run(workspace, "A:i64=42")).get("A").?.integer);
}

test "generated arithmetic agrees with independent integer calculations" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    var source: [256]u8 = undefined;
    for (0..2000) |index| {
        const a: i64 = @as(i64, @intCast(index)) - 1000;
        const b: i64 = @intCast(index % 17 + 1);
        var writer: std.Io.Writer = .fixed(&source);
        try writer.print("A:i64=({d}+3)*{d}; B:i64=A/{d}; C:i64=-({d}-{d})", .{ a, b, b, a, b });
        const result = try run(workspace, writer.buffered());
        try std.testing.expectEqual((a + 3) * b, result.get("A").?.integer);
        try std.testing.expectEqual(a + 3, result.get("B").?.integer);
        try std.testing.expectEqual(b - a, result.get("C").?.integer);
    }
}

test "seeded malformed inputs preserve diagnostic bounds and workspace reuse" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    var source: [128]u8 = undefined;
    const alphabet = "A:i64=1+-*/()\n;#<>stringlogictruefalse\"\\\t ";
    var state: u64 = 0x123456789abcdef;
    for (0..4000) |iteration| {
        const length = iteration % source.len;
        for (source[0..length]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = alphabet[(state >> 32) % alphabet.len];
        }
        switch (workspace.compile(source[0..length])) {
            .failed => |diagnostic| {
                try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
                try std.testing.expect(diagnostic.span.end <= length);
            },
            .ok => |program| switch (evaluator.evaluate(program, &workspace.values, types.limits.nodes)) {
                .ok => {},
                .failed => |diagnostic| try std.testing.expect(diagnostic.code != .invalid_ir),
            },
        }
    }
    _ = try run(workspace, "A:i64=1");
}

test "single-byte mutations exercise parser recovery around valid grammar" {
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const seed = "A:i64=-(2+3)*4; B<public>:i64=A/2; C:string=\"snow: 雪\"; D:logic=true";
    const alphabet = "A1:+-*/()\n;<>\"\\=";
    var source: [256]u8 = undefined;
    for (0..seed.len) |position| {
        for (alphabet) |byte| {
            @memcpy(source[0..seed.len], seed);
            source[position] = byte;
            switch (workspace.compile(source[0..seed.len])) {
                .failed => |diagnostic| {
                    try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
                    try std.testing.expect(diagnostic.span.end <= seed.len);
                },
                .ok => |program| switch (evaluator.evaluate(program, &workspace.values, types.limits.nodes)) {
                    .ok => {},
                    .failed => |diagnostic| try std.testing.expect(diagnostic.code != .invalid_ir),
                },
            }
        }
    }
}

test "lexer failures reset initialized token prefix and exact nesting capacity is accepted" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const workspace = try scratch.storage(support.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    _ = try run(workspace, "A:i64=42");
    try std.testing.expect(workspace.compiler.token_count > 0);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_utf8, workspace.compile("\xff").failed.code);
    try std.testing.expectEqual(@as(u32, 0), workspace.compiler.token_count);
    try std.testing.expectEqual(@as(u32, 0), workspace.compiler.node_count);
    var source: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&source);
    try out.writeAll("A:i64=");
    for (0..types.limits.expression_depth) |_| try out.writeByte('(');
    try out.writeByte('1');
    for (0..types.limits.expression_depth) |_| try out.writeByte(')');
    try std.testing.expectEqual(@as(i64, 1), (try run(workspace, out.buffered())).get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), (try run(workspace, "A:i64=42")).get("A").?.integer);
}
