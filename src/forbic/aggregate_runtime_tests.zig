const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");

const origin: types.Span = .{ .start = 0, .end = 0 };
const pair: types.Type = @fromBackingInt(@intCast(4));
const pairs: types.Type = @fromBackingInt(@intCast(5));
const box: types.Type = @fromBackingInt(@intCast(6));
const integers: types.Type = @fromBackingInt(@intCast(7));
const nested_integers: types.Type = @fromBackingInt(@intCast(8));
const source = "Pair left right Box item count";
const definitions = [_]types.Definition{
    .{ .record = .{ .name = .{ .start = 0, .end = 4 }, .fields = .{ .start = 0, .end = 2 }, .is_public = true } },
    .{ .array = pair },
    .{ .record = .{ .name = .{ .start = 16, .end = 19 }, .fields = .{ .start = 2, .end = 4 }, .is_public = false } },
    .{ .array = .i64 },
    .{ .array = integers },
};
const fields = [_]types.Field{
    .{ .name = .{ .start = 5, .end = 9 }, .value_type = .i64 },
    .{ .name = .{ .start = 10, .end = 15 }, .value_type = .float },
    .{ .name = .{ .start = 20, .end = 24 }, .value_type = pairs },
    .{ .name = .{ .start = 25, .end = 30 }, .value_type = .i64 },
};
const nodes = [_]types.Node{
    .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 7 } },
    .{ .span = origin, .value_type = .float, .kind = .{ .floating = 0.5 } },
    .{ .span = origin, .value_type = pair, .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
    .{ .span = origin, .value_type = pairs, .kind = .{ .aggregate = .{ .start = 2, .end = 4 } } },
    .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 3 } },
    .{ .span = origin, .value_type = box, .kind = .{ .aggregate = .{ .start = 4, .end = 6 } } },
    .{ .span = origin, .value_type = pairs, .kind = .{ .field = .{ .value = 5, .index = 0 } } },
    .{ .span = origin, .value_type = .i64, .kind = .{ .field = .{ .value = 2, .index = 0 } } },
    .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 6 } },
    .{ .span = origin, .value_type = integers, .kind = .{ .aggregate = .{ .start = 6, .end = 6 } } },
    .{ .span = origin, .value_type = nested_integers, .kind = .{ .aggregate = .{ .start = 6, .end = 8 } } },
};
const members = [_]u32{ 0, 1, 2, 2, 3, 4, 9, 9 };
const program: types.Program = .{
    .source = source,
    .strings = "",
    .nodes = &nodes,
    .bindings = &.{},
    .definitions = &definitions,
    .fields = &fields,
    .members = &members,
};

fn newRuntime() !*bytecode.Workspace {
    const runtime = try scratch.storage(bytecode.Workspace);
    scratch.initialise(runtime);
    return runtime;
}

test "immutable records and arrays shallow-share nested ranges independently in IR and VM" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    var values: [nodes.len]types.Value = undefined;
    var storage: [members.len]types.Value = undefined;
    const expected = evaluator.evaluateWithStorage(program, &values, &storage, nodes.len + members.len).ok;
    const actual = runtime.evaluate(program, nodes.len + members.len).ok;
    try std.testing.expectEqualDeep(expected.values, actual.values);
    try std.testing.expectEqualDeep(expected.aggregate_values, actual.aggregate_values);
    try std.testing.expectEqual(@as(usize, members.len), actual.aggregate_values.len);
    try std.testing.expectEqual(@as(i64, 2), actual.values[4].integer);
    try std.testing.expectEqual(@as(i64, 7), actual.values[7].integer);
    try std.testing.expectEqual(@as(i64, 2), actual.values[8].integer);
    try std.testing.expectEqualDeep(actual.values[3], actual.values[6]);
    const pair_values = actual.elements(actual.values[2]).?;
    try std.testing.expectEqual(@as(i64, 7), pair_values[0].integer);
    try std.testing.expectEqual(@as(f64, 0.5), pair_values[1].floating);
    const array_values = actual.elements(actual.values[3]).?;
    try std.testing.expectEqualDeep(actual.values[2], array_values[0]);
    try std.testing.expectEqualDeep(array_values[0], array_values[1]);
    try std.testing.expectEqual(@as(usize, 0), actual.elements(actual.values[9]).?.len);
    const nested = actual.elements(actual.values[10]).?;
    try std.testing.expectEqualDeep(actual.values[9], nested[0]);
    try std.testing.expectEqualDeep(nested[0], nested[1]);
    // Independent caller and VM storage have distinct ownership.
    runtime.machine.aggregate_values[0] = .{ .integer = 99 };
    try std.testing.expectEqual(@as(i64, 7), expected.elements(expected.values[2]).?[0].integer);
    try std.testing.expect(actual.elements(.{ .integer = 0 }) == null);
    try std.testing.expect(actual.elements(.{ .aggregate = .{ .value_type = pair, .elements = .{ .start = 0, .end = 1 } } }) == null);
    try std.testing.expect(actual.elements(.{ .aggregate = .{ .value_type = @fromBackingInt(@intCast(65535)), .elements = origin } }) == null);
    try std.testing.expect(actual.elements(.{ .aggregate = .{ .value_type = integers, .elements = .{ .start = 0, .end = 9 } } }) == null);
}

test "aggregate copy fuel is charged before touching a constructor destination" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    for (0..nodes.len + members.len) |budget| {
        var values: [nodes.len]types.Value = @splat(.{ .integer = 42 });
        var storage: [members.len]types.Value = @splat(.{ .integer = 42 });
        @memset(&runtime.machine.values, .{ .integer = 42 });
        @memset(&runtime.machine.aggregate_values, .{ .integer = 42 });
        const expected = evaluator.evaluateWithStorage(program, &values, &storage, @intCast(budget)).failed;
        const actual = runtime.evaluate(program, @intCast(budget)).failed;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, expected.code);
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqualDeep(values, runtime.machine.values[0..nodes.len].*);
        try std.testing.expectEqualDeep(storage, runtime.machine.aggregate_values[0..members.len].*);
        // Two scalars cost two units; the first record needs three more. A
        // partially funded constructor must leave both member slots untouched.
        if (budget < 5) {
            try std.testing.expectEqual(@as(i64, 42), storage[0].integer);
            try std.testing.expectEqual(@as(i64, 42), storage[1].integer);
        }
    }
    try std.testing.expectEqual(@as(usize, nodes.len), runtime.evaluate(program, nodes.len + members.len).ok.values.len);
}

test "caller aggregate capacity pressure validates first and preserves all destinations" {
    var values: [nodes.len]types.Value = @splat(.{ .integer = 42 });
    var storage: [members.len]types.Value = @splat(.{ .integer = 42 });
    for (0..members.len) |capacity| {
        try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithStorage(program, &values, storage[0..capacity], 0).failed.code);
        for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
        for (storage) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
    }
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluate(program, &values, 100).failed.code);
    var changed_nodes = nodes;
    changed_nodes[nodes.len - 1].kind.aggregate.end = 9;
    var changed = program;
    changed.nodes = &changed_nodes;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithStorage(changed, &values, &.{}, 0).failed.code);
    for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
    const expected = evaluator.evaluateWithStorage(program, &values, &storage, nodes.len + members.len).ok;
    try std.testing.expectEqual(@as(usize, members.len), expected.aggregate_values.len);
}

fn reject(changed: types.Program, runtime: *bytecode.Workspace) !void {
    var values: [nodes.len + 1]types.Value = @splat(.{ .integer = 42 });
    var storage: [members.len + 1]types.Value = @splat(.{ .integer = 42 });
    for ([_]u64{ 0, 100 }) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithStorage(changed, &values, &storage, budget).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, runtime.evaluate(changed, budget).failed.code);
        for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
        for (storage) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
    }
}

test "complete aggregate member ranges and nominal types reject malformed tails before execution" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    const invalid = [_]types.Node{
        .{ .span = origin, .value_type = integers, .kind = .{ .aggregate = .{ .start = 6, .end = 8 } } }, // Nested array elements have the wrong nominal type.
        .{ .span = origin, .value_type = nested_integers, .kind = .{ .aggregate = .{ .start = 5, .end = 8 } } },
        .{ .span = origin, .value_type = nested_integers, .kind = .{ .aggregate = .{ .start = 7, .end = 8 } } },
        .{ .span = origin, .value_type = nested_integers, .kind = .{ .aggregate = .{ .start = 8, .end = 6 } } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .field = .{ .value = 0, .index = 0 } } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .field = .{ .value = 2, .index = 2 } } },
        .{ .span = origin, .value_type = .float, .kind = .{ .field = .{ .value = 2, .index = 0 } } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 2 } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 10 } },
        .{ .span = origin, .value_type = @fromBackingInt(@intCast(65535)), .kind = .{ .aggregate = .{ .start = 6, .end = 8 } } },
    };
    for (invalid) |tail| {
        var changed_nodes = nodes;
        changed_nodes[nodes.len - 1] = tail;
        var changed = program;
        changed.nodes = &changed_nodes;
        try reject(changed, runtime);
    }
    var changed_members = members;
    var changed = program;
    changed.members = &changed_members;
    for ([_]u32{ 10, 11, 65535 }) |operand| {
        changed_members[members.len - 1] = operand;
        try reject(changed, runtime);
    }
    const extra_members = members ++ [_]u32{0};
    changed = program;
    changed.members = &extra_members;
    try reject(changed, runtime);
    changed = program;
    changed.members = members[0 .. members.len - 1];
    try reject(changed, runtime);
}

test "catalogue and member mutation reverify before touching journal or prior results" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    const committed_code = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 31 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .op = .{ .enqueue = .{ .kind = 7, .argument = 0 } } },
        .{ .op = .commit },
    };
    _ = runtime.machine.run(.{ .code = &committed_code }, committed_code.len).ok;
    var changed_definitions = definitions;
    var changed_members = members;
    var changed = program;
    changed.definitions = &changed_definitions;
    changed.members = &changed_members;
    const valid = runtime.evaluate(changed, nodes.len + members.len).ok;
    try std.testing.expectEqual(@as(usize, members.len), valid.aggregate_values.len);
    const prior_values = runtime.machine.values[0..nodes.len].*;
    const prior_storage = runtime.machine.aggregate_values[0..members.len].*;
    changed_definitions[4].array = nested_integers; // Self-referential array schema.
    try reject(changed, runtime);
    try std.testing.expectEqualDeep(prior_values, runtime.machine.values[0..nodes.len].*);
    try std.testing.expectEqualDeep(prior_storage, runtime.machine.aggregate_values[0..members.len].*);
    try std.testing.expectEqual(@as(usize, members.len), runtime.machine.aggregate_count);
    changed_definitions = definitions;
    changed_members[7] = 10;
    try reject(changed, runtime);
    try std.testing.expectEqual(@as(i64, 31), try runtime.machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 1), runtime.machine.journal.committed().len);
    try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.depth);
    changed_members = members;
    try std.testing.expectEqualDeep(valid.values, runtime.evaluate(changed, nodes.len + members.len).ok.values);
    // A subsequent scalar program clears the initialized aggregate prefix.
    try std.testing.expectEqual(@as(i64, 7), runtime.evaluate(.{ .source = "", .strings = "", .bindings = &.{}, .nodes = nodes[0..1] }, 1).ok.values[0].integer);
    try std.testing.expectEqual(@as(usize, 0), runtime.machine.aggregate_count);
}

test "full aggregate element capacity is accepted and excess raw storage is rejected" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    const full_members = try std.testing.allocator.alloc(u32, types.limits.aggregate_elements + 1);
    defer std.testing.allocator.free(full_members);
    @memset(full_members, 0);
    const full_storage = try std.testing.allocator.alloc(types.Value, types.limits.aggregate_elements);
    defer std.testing.allocator.free(full_storage);
    var values: [3]types.Value = undefined;
    var full_nodes = [_]types.Node{
        nodes[0],
        .{ .span = origin, .value_type = pair, .kind = .{ .aggregate = .{ .start = 0, .end = types.limits.aggregate_elements } } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 1 } },
    };
    var full: types.Program = .{ .source = "", .strings = "", .bindings = &.{}, .nodes = &full_nodes, .definitions = &.{.{ .array = .i64 }}, .members = full_members[0..types.limits.aggregate_elements] };
    const fuel = full_nodes.len + types.limits.aggregate_elements;
    const expected = evaluator.evaluateWithStorage(full, &values, full_storage, fuel).ok;
    const actual = runtime.evaluate(full, fuel).ok;
    try std.testing.expectEqualDeep(expected.values, actual.values);
    try std.testing.expectEqual(@as(i64, types.limits.aggregate_elements), actual.values[2].integer);
    for (actual.aggregate_values) |value| try std.testing.expectEqual(@as(i64, 7), value.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithStorage(full, &values, full_storage[0 .. full_storage.len - 1], fuel).failed.code);
    full.members = full_members;
    full_nodes[1].kind.aggregate.end += 1;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithStorage(full, &values, full_storage, fuel).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, runtime.evaluate(full, fuel).failed.code);
}

test "aggregate fuel failures unwind active journal writes while preserving earlier root commits" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    const code = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 17 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } },
        .{ .op = .commit },
        .{ .value_type = .i64, .op = .{ .integer = 29 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } },
        .{ .op = .{ .enqueue = .{ .kind = 2, .argument = 1 } } },
        .{ .value_type = pair, .op = .{ .aggregate = .{ .start = 0, .end = 2 } } },
        .{ .op = .commit },
    };
    const guest: vm.Program = .{ .code = &code, .definitions = &.{.{ .array = .i64 }}, .members = &.{ 0, 1 } };
    const fuel = code.len + 2;
    for (5..fuel) |budget| {
        runtime.machine.journal = .{};
        @memset(runtime.machine.aggregate_values[0..2], .{ .integer = 42 });
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, runtime.machine.run(guest, @intCast(budget)).failed.code);
        try std.testing.expectEqual(@as(i64, 17), try runtime.machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 1), runtime.machine.journal.committed().len);
        try std.testing.expectEqual(@as(i64, 17), runtime.machine.journal.committed()[0].argument);
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.undo_count);
        if (budget < 12) {
            try std.testing.expectEqual(@as(i64, 42), runtime.machine.aggregate_values[0].integer);
            try std.testing.expectEqual(@as(i64, 42), runtime.machine.aggregate_values[1].integer);
        }
    }
    runtime.machine.journal = .{};
    const result = runtime.machine.run(guest, fuel).ok;
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.machine.aggregate_count);
    try std.testing.expectEqual(@as(i64, 29), try runtime.machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 2), runtime.machine.journal.committed().len);
    // A malformed aggregate tail rejects even the earlier root commit.
    runtime.machine.journal = .{};
    var malformed = guest;
    malformed.members = &.{ 0, 2 };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, runtime.machine.run(malformed, fuel).failed.code);
    try std.testing.expectEqual(@as(i64, 0), try runtime.machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.committed().len);
}

test "10,000 seeded aggregate IR and catalogue mutations agree across independent execution" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    var random = std.Random.DefaultPrng.init(0x6167677265676174);
    const rng = random.random();
    for (0..10000) |_| {
        var changed_nodes = nodes;
        var changed_members = members;
        var changed_definitions = definitions;
        var changed_fields = fields;
        var changed = program;
        changed.nodes = &changed_nodes;
        changed.members = &changed_members;
        changed.definitions = &changed_definitions;
        changed.fields = &changed_fields;
        const position = rng.intRangeLessThan(usize, 0, nodes.len);
        const index = rng.intRangeLessThan(u32, 0, nodes.len + 3);
        const value_type: types.Type = @fromBackingInt(@intCast(rng.intRangeLessThan(u16, 0, definitions.len + 6)));
        switch (rng.intRangeLessThan(u8, 0, 12)) {
            0 => changed_nodes[position].value_type = value_type,
            1 => changed_nodes[position].kind = .{ .aggregate = .{ .start = index / 2, .end = index } },
            2 => changed_nodes[position].kind = .{ .field = .{ .value = index, .index = index / 2 } },
            3 => changed_nodes[position].kind = .{ .array_length = index },
            4 => changed_members[rng.intRangeLessThan(usize, 0, members.len)] = index,
            5 => changed_definitions[rng.intRangeLessThan(usize, 0, definitions.len)] = .{ .array = value_type },
            6 => changed_fields[rng.intRangeLessThan(usize, 0, fields.len)].value_type = value_type,
            7 => changed_fields[rng.intRangeLessThan(usize, 0, fields.len)].name = .{ .start = index / 2, .end = index },
            8 => changed_definitions[0].record.fields = .{ .start = index / 2, .end = index },
            9 => changed_nodes[position].span = .{ .start = index, .end = index / 2 },
            10 => changed_definitions[2].record.name = changed_definitions[0].record.name,
            11 => changed_nodes[0].kind.integer = rng.int(i64),
            else => unreachable,
        }
        var values: [nodes.len]types.Value = @splat(.{ .integer = 42 });
        var storage: [members.len]types.Value = @splat(.{ .integer = 42 });
        @memset(runtime.machine.values[0..nodes.len], .{ .integer = 42 });
        @memset(runtime.machine.aggregate_values[0..members.len], .{ .integer = 42 });
        const budget = rng.intRangeLessThan(u32, 0, 40);
        const expected = evaluator.evaluateWithStorage(changed, &values, &storage, budget);
        const actual = runtime.evaluate(changed, budget);
        switch (expected) {
            .failed => |diagnostic| {
                try std.testing.expectEqual(diagnostic.code, actual.failed.code);
                if (diagnostic.code != .invalid_ir) try std.testing.expectEqualDeep(diagnostic, actual.failed);
                if (diagnostic.code == .invalid_ir) {
                    for (values) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
                    for (storage) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
                }
            },
            .ok => |execution| {
                try std.testing.expectEqualDeep(execution.values, actual.ok.values);
                try std.testing.expectEqualDeep(execution.aggregate_values, actual.ok.aggregate_values);
            },
        }
        try std.testing.expectEqualDeep(values, runtime.machine.values[0..nodes.len].*);
        try std.testing.expectEqualDeep(storage, runtime.machine.aggregate_values[0..members.len].*);
    }
}

test "memberless empty aggregates and transaction statements retain exact one-step fuel" {
    const runtime = try newRuntime();
    defer scratch.release(runtime);
    const empty_definitions = [_]types.Definition{
        .{ .record = .{ .name = .{ .start = 0, .end = 5 }, .fields = origin, .is_public = false } },
        .{ .array = pair },
    };
    const empty_nodes = [_]types.Node{
        .{ .span = origin, .value_type = pair, .kind = .{ .aggregate = origin } },
        .{ .span = origin, .value_type = pairs, .kind = .{ .aggregate = origin } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 1 } },
    };
    const empty_program: types.Program = .{ .source = "Empty", .strings = "", .bindings = &.{}, .nodes = &empty_nodes, .definitions = &empty_definitions };
    var values: [empty_nodes.len]types.Value = undefined;
    for (0..empty_nodes.len) |budget| {
        @memset(&values, .{ .integer = 42 });
        @memset(runtime.machine.values[0..empty_nodes.len], .{ .integer = 42 });
        const expected = evaluator.evaluate(empty_program, &values, @intCast(budget)).failed;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, expected.code);
        try std.testing.expectEqualDeep(expected, runtime.evaluate(empty_program, @intCast(budget)).failed);
        try std.testing.expectEqualDeep(values, runtime.machine.values[0..empty_nodes.len].*);
    }
    const expected = evaluator.evaluate(empty_program, &values, empty_nodes.len).ok;
    const actual = runtime.evaluate(empty_program, empty_nodes.len).ok;
    try std.testing.expectEqualDeep(expected.values, actual.values);
    try std.testing.expectEqual(@as(usize, 0), actual.aggregate_values.len);
    try std.testing.expectEqual(@as(usize, 0), actual.elements(actual.values[0]).?.len);
    try std.testing.expectEqual(@as(usize, 0), actual.elements(actual.values[1]).?.len);
    try std.testing.expectEqual(@as(i64, 0), actual.values[2].integer);
    const code = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 31 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .value_type = pair, .op = .{ .aggregate = origin } },
        .{ .value_type = pairs, .op = .{ .aggregate = origin } },
        .{ .value_type = .i64, .op = .{ .array_length = 2 } },
        .{ .op = .{ .enqueue = .{ .kind = 9, .argument = 3 } } },
        .{ .op = .commit },
    };
    const guest: vm.Program = .{ .source = "Empty", .code = &code, .definitions = &empty_definitions };
    for (0..code.len) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, runtime.machine.run(guest, @intCast(budget)).failed.code);
        try std.testing.expectEqual(@as(i64, 0), try runtime.machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.undo_count);
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.journal.committed().len);
        try std.testing.expectEqual(@as(usize, 0), runtime.machine.aggregate_count);
    }
    const complete = runtime.machine.run(guest, code.len).ok;
    try std.testing.expectEqual(@as(usize, 4), complete.len);
    try std.testing.expectEqual(@as(i64, 0), complete[3].integer);
    try std.testing.expectEqual(@as(i64, 31), try runtime.machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 1), runtime.machine.journal.committed().len);
    try std.testing.expectEqual(@as(i64, 0), runtime.machine.journal.committed()[0].argument);
    var malformed = guest;
    malformed.members = &.{0}; // A memberless constructor cannot hide pool tails.
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, runtime.machine.run(malformed, 0).failed.code);
    try std.testing.expectEqual(@as(i64, 31), try runtime.machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 1), runtime.machine.journal.committed().len);
}
