const std = @import("std");
const scratch = @import("scratch.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const types = @import("types.zig");

const empty: types.Span = .{ .start = 0, .end = 0 };

test "reference and VM reject malformed UTF-8 pools and split string spans" {
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const integer: types.Node = .{ .span = empty, .value_type = .i64, .kind = .{ .integer = 7 } };
    const string: types.Node = .{ .span = empty, .value_type = .string, .kind = .{ .string = empty } };
    var values: [1]types.Value = undefined;
    const pools = [_]types.Program{
        .{ .source = "\xff", .nodes = &.{integer}, .bindings = &.{}, .strings = "" },
        .{ .source = "", .nodes = &.{integer}, .bindings = &.{}, .strings = "\xff" },
    };
    for (pools) |program| try rejected(program, &values, runtime);
    const pool = "A\xc3\xa9\xe9\x9b\xaa\xf0\x9f\x8c\xb2Z";
    for (0..pool.len + 1) |start| {
        for (start..pool.len + 1) |end| {
            var node = string;
            node.kind.string = .{ .start = @intCast(start), .end = @intCast(end) };
            const program: types.Program = .{ .source = "", .nodes = &.{node}, .bindings = &.{}, .strings = pool };
            if (!std.unicode.utf8ValidateSlice(pool[start..end])) {
                try rejected(program, &values, runtime);
            } else {
                // A zero-width slice inside a code point is also invalid metadata.
                const boundary = start == pool.len or (std.unicode.utf8ByteSequenceLength(pool[start]) catch 0) != 0;
                if (!boundary) {
                    try rejected(program, &values, runtime);
                } else {
                    try std.testing.expectEqualStrings(pool[start..end], evaluator.evaluate(program, &values, 1).ok.values[0].string);
                    try std.testing.expectEqualDeep(values[0], runtime.evaluate(program, 1).ok.values[0]);
                }
            }
        }
    }
}

fn rejected(program: types.Program, values: []types.Value, runtime: *bytecode.Workspace) !void {
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluate(program, values, types.limits.nodes).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, runtime.evaluate(program, types.limits.nodes).failed.code);
}

test "reference validates complete IR before writing results or consuming fuel" {
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const integer: types.Node = .{ .span = empty, .value_type = .i64, .kind = .{ .integer = 1 } };
    const divide: types.Node = .{ .span = empty, .value_type = .i64, .kind = .{ .binary = .{ .op = .divide, .lhs = 0, .rhs = 0 } } };
    const invalid = [_]types.Node{
        .{ .span = empty, .value_type = .logic, .kind = .{ .integer = 9 } },
        .{ .span = empty, .value_type = .i64, .kind = .{ .negate = 2 } },
        .{ .span = .{ .start = 0, .end = 1 }, .value_type = .i64, .kind = .{ .integer = 0 } },
    };
    for (invalid) |tail| {
        const nodes = [_]types.Node{ integer, divide, tail };
        const program: types.Program = .{ .source = "", .nodes = &nodes, .bindings = &.{}, .strings = "" };
        for ([_]u64{ 0, 3 }) |budget| {
            var values: [3]types.Value = @splat(.{ .integer = 42 });
            try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluate(program, &values, budget).failed.code);
            for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
            try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, runtime.evaluate(program, budget).failed.code);
        }
    }
    const bindings = [_]types.Binding{
        .{ .name = empty, .node = 1, .value_type = .i64, .is_public = false },
        .{ .name = empty, .node = 0, .value_type = .logic, .is_public = false },
        .{ .name = .{ .start = 1, .end = 0 }, .node = 0, .value_type = .i64, .is_public = false },
    };
    for (bindings) |binding| {
        const program: types.Program = .{ .source = "", .nodes = &.{integer}, .bindings = &.{binding}, .strings = "" };
        var values: [1]types.Value = .{.{ .integer = 42 }};
        try rejected(program, &values, runtime);
        try std.testing.expectEqual(@as(i64, 42), values[0].integer);
    }
}

test "10,000 seeded pure IR mutations agree across independent validation and execution" {
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const seed = [_]types.Node{
        .{ .span = empty, .value_type = .i64, .kind = .{ .integer = 7 } },
        .{ .span = empty, .value_type = .i64, .kind = .{ .integer = 3 } },
        .{ .span = empty, .value_type = .i64, .kind = .{ .binary = .{ .op = .add, .lhs = 0, .rhs = 1 } } },
        .{ .span = empty, .value_type = .logic, .kind = .{ .boolean = true } },
        .{ .span = empty, .value_type = .string, .kind = .{ .string = .{ .start = 0, .end = 3 } } },
        .{ .span = empty, .value_type = .float, .kind = .{ .floating = 0.5 } },
        .{ .span = empty, .value_type = .float, .kind = .{ .float_binary = .{ .op = .multiply, .lhs = 5, .rhs = 5 } } },
    };
    var random = std.Random.DefaultPrng.init(0x69722d7265766965);
    const rng = random.random();
    for (0..10000) |_| {
        var nodes = seed;
        var binding: types.Binding = .{ .name = .{ .start = 0, .end = 1 }, .node = 0, .value_type = .i64, .is_public = true };
        const position = rng.intRangeLessThan(usize, 0, nodes.len);
        const index = rng.intRangeLessThan(u32, 0, seed.len + 3);
        const value_type: types.Type = @fromBackingInt(@intCast(rng.intRangeLessThan(u8, 0, std.meta.tags(types.Type).len)));
        switch (rng.intRangeLessThan(u8, 0, 10)) {
            0 => nodes[position].span = .{ .start = index / 2, .end = index },
            1 => nodes[position].value_type = value_type,
            2 => nodes[position].kind = .{ .negate = index },
            3 => nodes[position].kind = .{ .binary = .{ .op = @fromBackingInt(@intCast(rng.intRangeLessThan(u8, 0, 4))), .lhs = index, .rhs = index / 2 } },
            4 => nodes[position].kind = .{ .integer = rng.int(i64) },
            5 => nodes[position].kind = .{ .string = .{ .start = index / 2, .end = index } },
            6 => binding = .{ .name = .{ .start = index / 2, .end = index }, .node = index, .value_type = value_type, .is_public = rng.boolean() },
            7 => nodes[position].kind = .{ .float_negate = index },
            8 => nodes[position].kind = .{ .float_binary = .{ .op = @fromBackingInt(@intCast(rng.intRangeLessThan(u8, 0, 4))), .lhs = index, .rhs = index / 2 } },
            9 => nodes[position].kind = .{ .floating = @bitCast(rng.int(u64)) },
            else => unreachable,
        }
        const program: types.Program = .{ .source = "ABC", .nodes = &nodes, .bindings = &.{binding}, .strings = "\xe9\x9b\xaaXY" };
        var values: [seed.len]types.Value = undefined;
        const budget = rng.intRangeLessThan(u32, 0, seed.len + 1);
        const expected = evaluator.evaluate(program, &values, budget);
        const actual = runtime.evaluate(program, budget);
        switch (expected) {
            .failed => |diagnostic| {
                try std.testing.expectEqual(diagnostic.code, actual.failed.code);
                try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= program.source.len);
                if (diagnostic.code != .invalid_ir) try std.testing.expectEqualDeep(diagnostic, actual.failed);
            },
            .ok => |execution| {
                try std.testing.expectEqual(execution.values.len, actual.ok.values.len);
                for (execution.values, actual.ok.values) |a, b| {
                    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
                    if (a == .floating) {
                        try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating)));
                    } else try std.testing.expectEqualDeep(a, b);
                }
            },
        }
    }
}
