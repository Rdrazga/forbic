const std = @import("std");
const scratch = @import("scratch.zig");
const support = @import("test_support.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");
const Instruction = vm.Instruction;

fn integer(value: i64) Instruction {
    return .{ .value_type = .i64, .op = .{ .integer = value } };
}
fn boolean(value: bool) Instruction {
    return .{ .value_type = .logic, .op = .{ .boolean = value } };
}
fn newMachine() !*vm.Machine {
    const machine = try scratch.storage(vm.Machine);
    scratch.initialise(machine);
    return machine;
}
fn run(machine: *vm.Machine, code: []const Instruction) vm.Result {
    return machine.run(.{ .code = code }, vm.max_instructions);
}

test "pure VM agrees with independent evaluator on typed programs and diagnostics" {
    const frontend = try scratch.storage(support.Workspace);
    defer scratch.release(frontend);
    scratch.initialise(frontend);
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const cases = [_][]const u8{
        "A:i64=-9223372036854775808; B:i64=-7/3; C:i64=-(2+3)*--2; D:i64=10-3-2",
        "A:logic=true; B:logic=A; C:string=\"snow: 雪\\n\"; D:string=C",
        "A:i64=9223372036854775807+1",
        "A:i64=-9223372036854775808/-1",
        "A:i64=1/0",
        "A:i64=--9223372036854775808",
        "",
    };
    for (cases) |source| try compare(frontend.compile(source).ok, frontend, runtime);
    var source: [256]u8 = undefined;
    for (0..2000) |index| {
        const a: i64 = @as(i64, @intCast(index)) - 1000;
        const b: i64 = @intCast(index % 17 + 1);
        var writer: std.Io.Writer = .fixed(&source);
        try writer.print("A:i64=({d}+3)*{d}; B:i64=A/{d}; C:i64=-({d}-{d})", .{ a, b, b, a, b });
        try compare(frontend.compile(writer.buffered()).ok, frontend, runtime);
    }
}

fn compare(program: types.Program, frontend: *support.Workspace, runtime: *bytecode.Workspace) !void {
    const expected = evaluator.evaluate(program, &frontend.values, types.limits.nodes);
    const actual = runtime.evaluate(program, types.limits.nodes);
    switch (expected) {
        .failed => |diagnostic| try std.testing.expectEqualDeep(diagnostic, actual.failed),
        .ok => |execution| {
            try std.testing.expectEqual(execution.values.len, actual.ok.values.len);
            for (execution.values, actual.ok.values) |left, right| try std.testing.expectEqualDeep(left, right);
        },
    }
}

test "full compiler node capacity retains independent reference and VM result storage" {
    try @import("profile.zig").requireBootstrap();
    const frontend = try scratch.storage(support.Workspace);
    defer scratch.release(frontend);
    scratch.initialise(frontend);
    const runtime = try scratch.storage(bytecode.Workspace);
    defer scratch.release(runtime);
    scratch.initialise(runtime);
    const other = try std.testing.allocator.alloc(types.Value, types.limits.nodes + 1);
    defer std.testing.allocator.free(other);
    @memset(other, .{ .integer = 42 });
    var source: [types.limits.nodes + 32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);
    try writer.writeAll("A:i64=1");
    for (0..types.limits.nodes / 2 - 1) |_| try writer.writeAll("+1");
    try writer.writeAll(";B:i64=7");
    const program = frontend.compile(writer.buffered()).ok;
    try std.testing.expectEqual(@as(usize, types.limits.nodes), program.nodes.len);
    // Capacity rejection leaves every independent destination untouched.
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluate(program, other[0 .. types.limits.nodes - 1], types.limits.nodes).failed.code);
    for (other) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
    const first = evaluator.evaluate(program, &frontend.values, types.limits.nodes).ok;
    const second = evaluator.evaluate(program, other[0..types.limits.nodes], types.limits.nodes).ok;
    try std.testing.expectEqual(@as(i64, types.limits.nodes / 2), first.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), first.get("B").?.integer);
    try std.testing.expectEqualDeep(first.values, second.values);
    try std.testing.expectEqualDeep(first.values, runtime.evaluate(program, types.limits.nodes).ok.values);
    other[0] = .{ .integer = 99 };
    runtime.machine.values[0] = .{ .integer = 88 };
    try std.testing.expectEqual(@as(i64, 1), first.values[0].integer);
    try std.testing.expectEqual(@as(i64, 42), other[types.limits.nodes].integer);
}

test "VM rejects malformed operands and regions before any root commit executes" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const cases = [_][]const Instruction{
        &.{.{ .value_type = .i64, .op = .{ .negate = 0 } }},
        &.{ boolean(true), .{ .value_type = .i64, .op = .{ .negate = 0 } } },
        &.{ integer(1), .{ .op = .{ .require = 0 } } },
        &.{.{ .op = .begin }},
        &.{.{ .op = .commit }},
        &.{.{ .op = .abort }},
        &.{ integer(1), .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } } },
        &.{.{ .value_type = .i64, .op = .{ .load_cell = 256 } }},
        &.{.{ .value_type = .logic, .op = .{ .integer = 1 } }},
        &.{.{ .op = .{ .integer = 1 } }},
        &.{ integer(1), .{ .op = .begin }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .commit }, .{ .value_type = .i64, .op = .{ .negate = 999 } } },
    };
    for (cases) |code| {
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, code).failed.code);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.committed().len);
    }
    const code = [_]Instruction{ integer(9), .{ .op = .begin }, .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .commit }, .{ .op = .begin } };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, &code).failed.code);
    try std.testing.expectEqual(@as(i64, 0), try machine.journal.read(0));
}

test "full register capacity permits trailing statements and rolls back each exhausted instruction" {
    try @import("profile.zig").requireBootstrap();
    const machine = try newMachine();
    defer scratch.release(machine);
    const count = types.limits.nodes;
    const code = try std.testing.allocator.alloc(Instruction, count + 5);
    defer std.testing.allocator.free(code);
    for (code[0..count], 0..) |*instruction, index| instruction.* = integer(@intCast(index));
    code[count] = .{ .op = .begin };
    code[count + 1] = .{ .op = .{ .store_cell = .{ .cell = 0, .value = count - 1 } } };
    code[count + 2] = .{ .op = .{ .enqueue = .{ .kind = 7, .argument = count - 1 } } };
    code[count + 3] = .{ .op = .commit };
    const program: vm.Program = .{ .code = code[0 .. count + 4] };
    for (count..count + 4) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, machine.run(program, @intCast(budget)).failed.code);
        try std.testing.expectEqual(@as(i64, 0), try machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.committed().len);
    }
    const values = machine.run(program, count + 4).ok;
    try std.testing.expectEqual(@as(usize, count), values.len);
    try std.testing.expectEqual(@as(i64, count - 1), values[count - 1].integer);
    try std.testing.expectEqual(@as(i64, count - 1), try machine.journal.read(0));
    try std.testing.expectEqualSlices(transaction.Intent, &.{.{ .kind = 7, .argument = count - 1 }}, machine.journal.committed());
    code[count + 4] = integer(9); // An extra register rejects the whole program.
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .code = code }, 0).failed.code);
    try std.testing.expectEqual(@as(usize, 1), machine.journal.committed().len);
    try std.testing.expectEqual(@as(i64, count - 1), try machine.journal.read(0));
}

test "reused bytecode and text buffers are completely reverified before execution" {
    const machine = try newMachine();
    defer scratch.release(machine);
    var strings = [_]u8{ 'o', 'k' };
    var code = [_]Instruction{
        integer(42),
        .{ .value_type = .string, .op = .{ .string = .{ .start = 0, .end = 2 } } },
    };
    const program: vm.Program = .{ .strings = &strings, .code = &code };
    try std.testing.expectEqualStrings("ok", machine.run(program, 2).ok[1].string);
    strings[1] = 0xff;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(program, 0).failed.code);
    try std.testing.expectEqual(@as(i64, 42), machine.values[0].integer);
    strings[1] = 'k';
    code[0] = boolean(true);
    try std.testing.expect(machine.run(program, 2).ok[0].boolean);
    code[1].op = .{ .negate = 0 }; // Valid indexes still require the current operand type.
    code[1].value_type = .i64;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(program, 0).failed.code);
    try std.testing.expect(machine.values[0].boolean);
    try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
}

test "VM validates spans, UTF-8 boundaries, bindings, and borrowed IR" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = [_]Instruction{integer(1)};
    const binding: types.Binding = .{ .name = .{ .start = 0, .end = 1 }, .node = 0, .value_type = .i64, .is_public = false };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .code = &code, .bindings = &.{binding} }, 1).failed.code);
    var changed = binding;
    changed.node = 1;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .source = "A", .code = &code, .bindings = &.{changed} }, 1).failed.code);
    changed = binding;
    changed.value_type = .logic;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .source = "A", .code = &code, .bindings = &.{changed} }, 1).failed.code);
    const strings = [_]Instruction{.{ .value_type = .string, .op = .{ .string = .{ .start = 1, .end = 2 } } }};
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .strings = "雪", .code = &strings }, 1).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .strings = "\xff", .code = &code }, 1).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .source = "\xff", .code = &code }, 1).failed.code);
    const span = [_]Instruction{.{ .span = .{ .start = 2, .end = 1 }, .value_type = .i64, .op = .{ .integer = 1 } }};
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, &span).failed.code);
    var storage: [1]Instruction = undefined;
    const invalid_ir: types.Program = .{ .source = "", .strings = "", .bindings = &.{}, .nodes = &.{.{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .negate = std.math.maxInt(u32) } }} };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, bytecode.evaluate(invalid_ir, &storage, machine, 1).failed.code);
    try std.testing.expectEqual(@as(i64, 1), run(machine, &code).ok[0].integer);
}

test "nested VM regions restore state and publish only committed intents" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = [_]Instruction{
        integer(10),                                              integer(20),                                              .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } }, .{ .op = .{ .enqueue = .{ .kind = 2, .argument = 1 } } }, .{ .op = .abort },
        .{ .value_type = .i64, .op = .{ .load_cell = 0 } },       .{ .op = .begin },                                        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } },
        .{ .op = .{ .enqueue = .{ .kind = 3, .argument = 1 } } }, .{ .op = .commit },                                       .{ .op = .commit },
        .{ .value_type = .i64, .op = .{ .load_cell = 0 } },
    };
    const values = run(machine, &code).ok;
    try std.testing.expectEqual(@as(i64, 10), values[2].integer);
    try std.testing.expectEqual(@as(i64, 20), values[3].integer);
    try std.testing.expectEqualSlices(transaction.Intent, &.{ .{ .kind = 1, .argument = 10 }, .{ .kind = 3, .argument = 20 } }, machine.journal.committed());
    try std.testing.expectEqual(@as(usize, 0), machine.journal.undo_count);
    try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
}

test "fuel exhaustion at each instruction and failed requirements unwind every active region" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = [_]Instruction{
        integer(42),                                              boolean(false),                                           .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 1, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 2, .argument = 0 } } }, .{ .op = .commit },
        .{ .op = .{ .require = 1 } },                             .{ .op = .commit },
    };
    for (0..code.len + 1) |budget| {
        machine.journal = .{};
        const diagnostic = machine.run(.{ .code = &code }, @intCast(budget)).failed;
        try std.testing.expectEqual(if (budget <= 9) types.Diagnostic.Code.work_limit else .requirement_failed, diagnostic.code);
        for (machine.journal.cells) |cell| try std.testing.expectEqual(@as(i64, 0), cell);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.committed().len);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.undo_count);
    }
    try std.testing.expectEqual(@as(i64, 7), run(machine, &.{integer(7)}).ok[0].integer);
}

test "later failures preserve earlier root commits and rollback arithmetic faults" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = [_]Instruction{
        integer(7),                                               boolean(false),                                           .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .commit },
        integer(9),                                               .{ .op = .begin },                                        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 2 } } },
        .{ .op = .{ .enqueue = .{ .kind = 2, .argument = 2 } } }, .{ .op = .{ .require = 1 } },                             .{ .op = .commit },
    };
    try std.testing.expectEqual(types.Diagnostic.Code.requirement_failed, run(machine, &code).failed.code);
    try std.testing.expectEqual(@as(i64, 7), try machine.journal.read(0));
    try std.testing.expectEqualSlices(transaction.Intent, &.{.{ .kind = 1, .argument = 7 }}, machine.journal.committed());
    const overflow = [_]Instruction{
        integer(std.math.maxInt(i64)),                            integer(1),                                                                        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } }, .{ .value_type = .i64, .op = .{ .binary = .{ .op = .add, .lhs = 0, .rhs = 1 } } }, .{ .op = .commit },
    };
    try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, run(machine, &overflow).failed.code);
    try std.testing.expectEqual(@as(i64, 7), try machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 1), machine.journal.committed().len);
}

test "VM outbox pressure preserves old commits and supports explicit acknowledgement" {
    const machine = try newMachine();
    defer scratch.release(machine);
    try machine.journal.begin();
    for (0..transaction.default_bounds.committed) |index| try machine.journal.enqueue(.{ .kind = @intCast(index), .argument = @intCast(index) });
    try machine.journal.commit();
    const code = [_]Instruction{
        integer(9),                                               .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 999, .argument = 0 } } },
        .{ .op = .commit },
    };
    try std.testing.expectEqual(types.Diagnostic.Code.outbox_limit, run(machine, &code).failed.code);
    try std.testing.expectEqual(@as(i64, 0), try machine.journal.read(0));
    try std.testing.expectEqual(@as(usize, 256), machine.journal.committed().len);
    try std.testing.expectEqual(@as(u32, 0), machine.journal.committed()[0].kind);
    try machine.journal.acknowledge(1);
    _ = run(machine, &code).ok;
    try std.testing.expectEqual(@as(i64, 9), try machine.journal.read(0));
    try std.testing.expectEqual(@as(u32, 1), machine.journal.committed()[0].kind);
    try std.testing.expectEqual(@as(u32, 999), machine.journal.committed()[255].kind);
}

test "VM resource ceilings reject safely and remain reusable" {
    try @import("profile.zig").requireBootstrap();
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = try std.testing.allocator.alloc(Instruction, vm.max_instructions + 1);
    defer std.testing.allocator.free(code);
    @memset(code, integer(0));
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, code).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, code[0 .. types.limits.nodes + 1]).failed.code);
    try std.testing.expectEqual(@as(usize, types.limits.nodes), run(machine, code[0..types.limits.nodes]).ok.len);
    const cases = [_]struct { count: usize, operation: Instruction, diagnostic: types.Diagnostic.Code }{
        .{ .count = transaction.default_bounds.undo + 1, .operation = .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .diagnostic = .undo_limit },
        .{ .count = transaction.default_bounds.pending + 1, .operation = .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .diagnostic = .intent_limit },
    };
    for (cases) |case| {
        code[0] = integer(5);
        code[1] = .{ .op = .begin };
        @memset(code[2..][0..case.count], case.operation);
        code[2 + case.count] = .{ .op = .commit };
        try std.testing.expectEqual(case.diagnostic, run(machine, code[0 .. case.count + 3]).failed.code);
        try std.testing.expectEqual(@as(i64, 0), try machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.committed().len);
    }
    @memset(code[0..33], .{ .op = .begin });
    @memset(code[33..66], .{ .op = .commit });
    try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, run(machine, code[0..66]).failed.code);
    code[0] = boolean(true);
    @memset(code[1..vm.max_instructions], .{ .op = .{ .require = 0 } });
    try std.testing.expectEqual(@as(usize, 1), run(machine, code[0..vm.max_instructions]).ok.len);
    const oversized = try std.testing.allocator.alloc(u8, types.limits.source_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .source = oversized, .code = &.{integer(0)} }, 1).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(.{ .strings = oversized, .code = &.{integer(0)} }, 1).failed.code);
    try std.testing.expectEqual(@as(i64, 11), run(machine, &.{integer(11)}).ok[0].integer);
}

test "root commits survive later fuel exhaustion and a machine requires idle ownership" {
    const machine = try newMachine();
    defer scratch.release(machine);
    const code = [_]Instruction{
        integer(7),                                               integer(9),                                               .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .commit },
        .{ .op = .begin },                                        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } }, .{ .op = .{ .enqueue = .{ .kind = 2, .argument = 1 } } },
        .{ .op = .commit },
    };
    for (0..code.len) |budget| {
        machine.journal = .{};
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, machine.run(.{ .code = &code }, @intCast(budget)).failed.code);
        try std.testing.expectEqual(@as(i64, if (budget >= 6) 7 else 0), try machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, if (budget >= 6) 1 else 0), machine.journal.committed().len);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
    }
    try machine.journal.begin();
    try machine.journal.write(0, 42);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, run(machine, &.{integer(0)}).failed.code);
    try std.testing.expectEqual(@as(usize, 1), machine.journal.depth);
    try std.testing.expectEqual(@as(i64, 42), try machine.journal.read(0));
    machine.journal.abortAll();
    try std.testing.expectEqual(@as(i64, 7), try machine.journal.read(0));
}

test "10,000 seeded bytecode mutations preserve diagnostic and cleanup bounds" {
    try @import("profile.zig").requireBootstrap();
    const machine = try newMachine();
    defer scratch.release(machine);
    const seed = [_]Instruction{
        integer(7),                                               boolean(true),                                            .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } }, .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } }, .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 1, .value = 0 } } }, .{ .op = .{ .require = 1 } },                             .{ .op = .commit },
        .{ .op = .commit },
    };
    var random = std.Random.DefaultPrng.init(0x62797465636f6465);
    const rng = random.random();
    for (0..10000) |_| {
        var code = seed;
        const position = rng.intRangeLessThan(usize, 0, code.len);
        code[position] = mutation(rng);
        machine.journal = .{};
        switch (machine.run(.{ .source = "test", .strings = "雪x", .code = &code }, rng.intRangeLessThan(u32, 0, 12))) {
            .failed => |diagnostic| {
                try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
                try std.testing.expect(diagnostic.span.end <= 4);
            },
            .ok => |values| for (values) |value| {
                if (value == .string) try std.testing.expect(std.unicode.utf8ValidateSlice(value.string));
            },
        }
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.pending_count);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.undo_count);
        try std.testing.expect(machine.journal.committed().len <= transaction.default_bounds.committed);
    }
}

fn mutation(rng: std.Random) Instruction {
    const operand = rng.intRangeLessThan(u32, 0, 12);
    const cell = rng.intRangeLessThan(u32, 0, 258);
    var instruction: Instruction = switch (rng.intRangeLessThan(u8, 0, 11)) {
        0 => .{ .value_type = .i64, .op = .{ .binary = .{ .op = .divide, .lhs = operand, .rhs = operand / 2 } } },
        1 => integer(rng.int(i64)),
        2 => .{ .op = .{ .store_cell = .{ .cell = cell, .value = operand } } },
        3 => .{ .op = .{ .require = operand } },
        4 => .{ .value_type = .i64, .op = .{ .load_cell = cell } },
        5 => .{ .op = .begin },
        6 => .{ .op = .commit },
        7 => .{ .op = .abort },
        8 => .{ .op = .{ .enqueue = .{ .kind = cell, .argument = operand } } },
        9 => .{ .value_type = .string, .op = .{ .string = .{ .start = operand / 2, .end = operand } } },
        10 => boolean(rng.boolean()),
        else => unreachable,
    };
    if (rng.boolean()) instruction.span = .{ .start = operand / 2, .end = operand };
    if (rng.boolean()) instruction.value_type = switch (rng.intRangeLessThan(u8, 0, 4)) {
        0 => null,
        1 => .i64,
        2 => .logic,
        3 => .string,
        else => unreachable,
    };
    return instruction;
}

const small_bounds: transaction.Bounds = .{ .cells = 8, .depth = 4, .undo = 32, .pending = 8, .committed = 8 };
const SmallJournal = transaction.Bounded(small_bounds);
const Operation = union(enum) {
    begin,
    write: struct { cell: u32, value: i64 },
    enqueue: transaction.Intent,
    commit,
    abort,
    acknowledge: usize,
};
// Independent rollback oracle: copy complete observable state at each begin.
// Only the undo-record count is modeled to reproduce the explicit work bound.
const Reference = struct {
    const Snapshot = struct { cells: [8]i64, pending: usize, undo: usize };
    cells: [8]i64 = @splat(0),
    frames: [4]Snapshot = undefined,
    pending: [8]transaction.Intent = undefined,
    outbox: [8]transaction.Intent = undefined,
    depth: usize = 0,
    undo_count: usize = 0,
    pending_count: usize = 0,
    outbox_count: usize = 0,

    fn apply(self: *Reference, operation: Operation) transaction.Error!void {
        switch (operation) {
            .begin => {
                if (self.depth == 4) return error.DepthLimit;
                self.frames[self.depth] = .{ .cells = self.cells, .pending = self.pending_count, .undo = self.undo_count };
                self.depth += 1;
            },
            .write => |write| {
                if (write.cell >= 8) return error.CellIndex;
                if (self.depth == 0) return error.NoTransaction;
                if (self.undo_count == 32) return error.UndoLimit;
                self.cells[write.cell] = write.value;
                self.undo_count += 1;
            },
            .enqueue => |intent| {
                if (self.depth == 0) return error.NoTransaction;
                if (self.pending_count == 8) return error.IntentLimit;
                self.pending[self.pending_count] = intent;
                self.pending_count += 1;
            },
            .commit => {
                if (self.depth == 0) return error.NoTransaction;
                if (self.depth == 1) {
                    if (self.pending_count + self.outbox_count > 8) return error.OutboxLimit;
                    for (self.pending[0..self.pending_count]) |intent| {
                        self.outbox[self.outbox_count] = intent;
                        self.outbox_count += 1;
                    }
                    self.pending_count = 0;
                    self.undo_count = 0;
                }
                self.depth -= 1;
            },
            .abort => {
                if (self.depth == 0) return error.NoTransaction;
                self.depth -= 1;
                const snapshot = self.frames[self.depth];
                self.cells = snapshot.cells;
                self.pending_count = snapshot.pending;
                self.undo_count = snapshot.undo;
            },
            .acknowledge => |count| {
                if (self.depth != 0) return error.ActiveTransaction;
                if (count > self.outbox_count) return error.InvalidAcknowledgement;
                self.outbox_count -= count;
                for (0..self.outbox_count) |index| self.outbox[index] = self.outbox[index + count];
            },
        }
    }
};

fn apply(journal: *SmallJournal, operation: Operation) transaction.Error!void {
    switch (operation) {
        .begin => try journal.begin(),
        .write => |write| try journal.write(write.cell, write.value),
        .enqueue => |intent| try journal.enqueue(intent),
        .commit => try journal.commit(),
        .abort => try journal.abort(),
        .acknowledge => |count| try journal.acknowledge(count),
    }
}
fn compareJournal(journal: *const SmallJournal, reference: *const Reference) !void {
    try std.testing.expectEqualSlices(i64, &reference.cells, &journal.cells);
    try std.testing.expectEqual(reference.depth, journal.depth);
    try std.testing.expectEqual(reference.undo_count, journal.undo_count);
    try std.testing.expectEqual(reference.pending_count, journal.pending_count);
    try std.testing.expectEqualSlices(transaction.Intent, reference.pending[0..reference.pending_count], journal.pending[0..journal.pending_count]);
    try std.testing.expectEqualSlices(transaction.Intent, reference.outbox[0..reference.outbox_count], journal.committed());
}

test "10,000 seeded journal operations agree with full-snapshot rollback oracle" {
    var journal: SmallJournal = .{};
    var reference: Reference = .{};
    var random = std.Random.DefaultPrng.init(0x7472616e73616374);
    const rng = random.random();
    for (0..10000) |index| {
        const operation: Operation = switch (rng.intRangeLessThan(u8, 0, 6)) {
            0 => .begin,
            1 => .{ .write = .{ .cell = rng.intRangeLessThan(u32, 0, 9), .value = @as(i64, @intCast(index)) - 5000 } },
            2 => .{ .enqueue = .{ .kind = @intCast(index), .argument = @intCast(index) } },
            3 => .commit,
            4 => .abort,
            5 => .{ .acknowledge = rng.intRangeLessThan(usize, 0, 10) },
            else => unreachable,
        };
        var expected: ?transaction.Error = null;
        reference.apply(operation) catch |err| {
            expected = err;
        };
        var actual: ?transaction.Error = null;
        apply(&journal, operation) catch |err| {
            actual = err;
        };
        try std.testing.expectEqual(expected, actual);
        try compareJournal(&journal, &reference);
    }
    journal.abortAll();
    while (reference.depth > 0) try reference.apply(.abort);
    try compareJournal(&journal, &reference);
}
