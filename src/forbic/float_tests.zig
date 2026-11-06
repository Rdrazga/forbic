const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const bytecode = @import("bytecode.zig");
const evaluator = @import("evaluator.zig");
const vm = @import("vm.zig");
const inspection = @import("inspection.zig");
const origin: types.Span = .{ .start = 0, .end = 0 };

const Harness = struct {
    pub const parts = .{ "front", "runtime" };
    front: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    reference: [types.limits.nodes]types.Value = undefined,

    fn create() !*Harness {
        const self = try scratch.make(Harness);
        return self;
    }

    fn run(self: *Harness, source: []const u8) !evaluator.Execution {
        const ir = self.front.compile(source).ok;
        const expected = evaluator.evaluate(ir, &self.reference, types.limits.nodes).ok;
        const actual = self.runtime.evaluate(ir, types.limits.nodes).ok;
        try compare(expected.values, actual.values);
        return actual;
    }
};

fn compare(expected: []const types.Value, actual: []const types.Value) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| {
        try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
        switch (a) {
            .integer => |value| try std.testing.expectEqual(value, b.integer),
            .floating => |value| try bitsEqual(value, b.floating),
            .boolean => |value| try std.testing.expectEqual(value, b.boolean),
            .string => |value| try std.testing.expectEqualStrings(value, b.string),
            .aggregate => |value| try std.testing.expectEqualDeep(value, b.aggregate),
            .enumeration => |value| try std.testing.expectEqualDeep(value, b.enumeration),
            .callable => |value| try std.testing.expectEqualDeep(value, b.callable),
            .object => |value| try std.testing.expectEqualDeep(value, b.object),
            .rational => |value| try std.testing.expectEqualDeep(value, b.rational),
        }
    }
}

fn bitsEqual(expected: f64, actual: f64) !void {
    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
}

test "float functions preserve types captures and all arithmetic operators and reject shadowing" {
    const h = try Harness.create();
    defer scratch.release(h);
    const result = try h.run("Base:float=0.5;Scale(X:float)<computes>:float=X*Base;Mix(Bias:float,Y:float)<computes>:float=Scale(Bias)+Y/2.0-0.25;Ratio<public>:float=Mix(2.0,1e0);Neg:float=-(+Ratio);Alias:float=Ratio;Keep(X:float)<computes>:float=X;Copy:float=Keep(Neg)");
    try bitsEqual(1.25, result.get("Ratio").?.floating);
    try bitsEqual(-1.25, result.get("Neg").?.floating);
    try bitsEqual(1.25, result.get("Alias").?.floating);
    try bitsEqual(-1.25, result.get("Copy").?.floating);
    try std.testing.expect(result.program.bindings[1].is_public);
    // RFC-0076 rule 1: `Mix`'s first parameter was named `Base` and shadowed the binding.
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, h.front.compile("Base:float=0.5;Mix(Base:float,Y:float)<computes>:float=Base+Y").failed.code);
}

test "float rounding boundaries subnormals signed zero and no FMA contraction" {
    const h = try Harness.create();
    defer scratch.release(h);
    const result = try h.run("Tie:float=9007199254740993.0;Next:float=9007199254740995.0;Small:float=4.9406564584124654e-324;Half:float=Small/2.0;Double:float=Small*2.0;Tiny:float=1e-9999;NegativeZero:float=-0.0;Positive:float=-NegativeZero;Fused:float=1.0000000000000002*0.9999999999999998-1.0;Max:float=1.7976931348623157e308");
    try bitsEqual(9007199254740992.0, result.get("Tie").?.floating);
    try bitsEqual(9007199254740996.0, result.get("Next").?.floating);
    try bitsEqual(@bitCast(@as(u64, 1)), result.get("Small").?.floating);
    try bitsEqual(0.0, result.get("Half").?.floating);
    try bitsEqual(@bitCast(@as(u64, 2)), result.get("Double").?.floating);
    try bitsEqual(0.0, result.get("Tiny").?.floating);
    try bitsEqual(-0.0, result.get("NegativeZero").?.floating);
    try bitsEqual(0.0, result.get("Positive").?.floating);
    try bitsEqual(0.0, result.get("Fused").?.floating);
    try bitsEqual(std.math.floatMax(f64), result.get("Max").?.floating);
}

test "nonfinite arithmetic follows IEEE and produces one canonical NaN" {
    const h = try Harness.create();
    defer scratch.release(h);
    const result = try h.run("Positive:float=1.0/0.0;Negative:float=1.0/-0.0;Overflow:float=1e308*1e308;Bad:float=0.0/0.0;Subtract:float=Inf-Inf;Negate:float=-NaN;Product:float=0.0*Inf;Alias:float=NaN;Finite:float=1.0/Inf");
    try bitsEqual(std.math.inf(f64), result.get("Positive").?.floating);
    try bitsEqual(-std.math.inf(f64), result.get("Negative").?.floating);
    try bitsEqual(std.math.inf(f64), result.get("Overflow").?.floating);
    for ([_][]const u8{ "Bad", "Subtract", "Negate", "Product", "Alias" }) |name| {
        try std.testing.expectEqual(@as(u64, 0x7ff8000000000000), @as(u64, @bitCast(result.get(name).?.floating)));
    }
    try bitsEqual(0.0, result.get("Finite").?.floating);
}

test "numeric grammar and signatures reject malformed literals and implicit coercions" {
    const h = try Harness.create();
    defer scratch.release(h);
    const cases = .{
        .{ "A:float=1.", types.Diagnostic.Code.invalid_number },
        .{ "A:float=1e", types.Diagnostic.Code.invalid_number },
        .{ "A:float=1e+", types.Diagnostic.Code.invalid_number },
        .{ "A:float=1.0e-;", types.Diagnostic.Code.invalid_number },
        .{ "A:float=1efoo", types.Diagnostic.Code.invalid_number },
        .{ "A:float=.5", types.Diagnostic.Code.expected_expression },
        .{ "A:float=1e309", types.Diagnostic.Code.float_range },
        .{ "A:float=-1e309", types.Diagnostic.Code.float_range },
        .{ "A:float=1", types.Diagnostic.Code.type_mismatch },
        .{ "A:i64=1.0", types.Diagnostic.Code.type_mismatch },
        .{ "A:float=1+2.0", types.Diagnostic.Code.type_mismatch },
        .{ "A:float=1.0+2", types.Diagnostic.Code.type_mismatch },
        .{ "A:float=true*1.0", types.Diagnostic.Code.type_mismatch },
        .{ "A:float=+false", types.Diagnostic.Code.type_mismatch },
        .{ "F(X:float)<computes>:float=X;A:float=F(1)", types.Diagnostic.Code.type_mismatch },
        .{ "F()<computes>:i64=NaN", types.Diagnostic.Code.type_mismatch },
        .{ "Inf:float=2.0", types.Diagnostic.Code.expected_name },
        .{ "F(NaN:float)<computes>:float=NaN", types.Diagnostic.Code.expected_parameter },
    };
    inline for (cases) |case| {
        const diagnostic = h.front.compile(case[0]).failed;
        try std.testing.expectEqual(case[1], diagnostic.code);
        try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= case[0].len);
    }
    _ = try h.run("A:float=6.25E+1;B:i64=-9223372036854775808");
}

test "pure function arguments remain strict and unused float bodies are checked" {
    const h = try Harness.create();
    defer scratch.release(h);
    const ir = h.front.compile("Unused()<computes>:float=1.0/0.0;Keep(X:i64)<computes>:float=0.5;A:float=Keep(1/0)").ok;
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, evaluator.evaluate(ir, &h.reference, types.limits.nodes).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, h.runtime.evaluate(ir, types.limits.nodes).failed.code);
    _ = try h.run("Unused()<computes>:float=1.0/0.0;A:float=0.5");
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, h.front.compile("Unused()<computes>:float=1.0+1").failed.code);
}

test "every float execution fuel boundary agrees and the workspace recovers" {
    const h = try Harness.create();
    defer scratch.release(h);
    const ir = h.front.compile("F(X:float)<computes>:float=-X*2.0;A:float=F(1.25)+0.5/0.0;B:float=A-A").ok;
    const total = ir.nodes.len + ir.function_nodes.len;
    try std.testing.expectEqual(@as(usize, 4), ir.function_nodes.len);
    for (0..total) |budget| {
        const reference = evaluator.evaluate(ir, &h.reference, @intCast(budget)).failed;
        const actual = h.runtime.evaluate(ir, @intCast(budget)).failed;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.code);
        try std.testing.expectEqualDeep(reference, actual);
        try std.testing.expectEqual(@as(u32, 0), h.runtime.machine.journal.depth);
    }
    const expected = evaluator.evaluate(ir, &h.reference, @intCast(total)).ok;
    try compare(expected.values, h.runtime.evaluate(ir, @intCast(total)).ok.values);
    _ = try h.run("A:float=-0.0");
}

test "independent IR and VM verification reject invalid float tails before execution" {
    const h = try Harness.create();
    defer scratch.release(h);
    var nodes = [_]types.Node{
        .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 1 } },
        .{ .span = origin, .value_type = .float, .kind = .{ .floating = 2.0 } },
        .{ .span = origin, .value_type = .float, .kind = .{ .float_negate = 0 } },
    };
    const bad = [_]types.Node{
        nodes[2],
        .{ .span = origin, .value_type = .i64, .kind = .{ .floating = 2.0 } },
        .{ .span = origin, .value_type = .float, .kind = .{ .negate = 1 } },
        .{ .span = origin, .value_type = .float, .kind = .{ .float_negate = 2 } },
        .{ .span = origin, .value_type = .float, .kind = .{ .float_binary = .{ .op = .divide, .lhs = 1, .rhs = 0 } } },
        .{ .span = origin, .value_type = .float, .kind = .{ .float_binary = .{ .op = .add, .lhs = 99, .rhs = 1 } } },
        .{ .span = origin, .value_type = .i64, .kind = .{ .binary = .{ .op = .add, .lhs = 0, .rhs = 1 } } },
    };
    for (bad) |tail| {
        nodes[2] = tail;
        const ir: types.Program = .{ .source = "", .strings = "", .nodes = &nodes, .bindings = &.{} };
        @memset(h.reference[0..nodes.len], .{ .integer = 42 });
        @memset(h.runtime.machine.values[0..nodes.len], .{ .integer = 43 });
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluate(ir, &h.reference, 0).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, h.runtime.evaluate(ir, 0).failed.code);
        for (h.reference[0..nodes.len]) |value| try std.testing.expectEqual(@as(i64, 42), value.integer);
        for (h.runtime.machine.values[0..nodes.len]) |value| try std.testing.expectEqual(@as(i64, 43), value.integer);
    }
}

test "float registers cannot enter i64 transaction cells intents or logic requirements" {
    const h = try Harness.create();
    defer scratch.release(h);
    var code = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 7 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } },
        .{ .op = .commit },
        .{ .value_type = .float, .op = .{ .floating = 1.0 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } },
        .{ .op = .abort },
    };
    const tails = [_]vm.Instruction{
        code[7],
        .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 1 } } },
        .{ .op = .{ .require = 1 } },
        .{ .value_type = .float, .op = .{ .load_cell = 0 } },
    };
    for (tails) |tail| {
        code[7] = tail;
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(.{ .code = &code }, 0).failed.code);
        try std.testing.expectEqual(@as(i64, 0), try h.runtime.machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.committed().len);
    }
}

test "raw binary64 IR literals normalize NaN payloads without rejecting valid values" {
    const h = try Harness.create();
    defer scratch.release(h);
    for ([_]u64{ 0x7ff0000000000001, 0xfff8000000000001, 0x8000000000000000, 1, 0x7ff0000000000000 }) |bits| {
        const node: types.Node = .{ .span = origin, .value_type = .float, .kind = .{ .floating = @bitCast(bits) } };
        const ir: types.Program = .{ .source = "", .strings = "", .nodes = &.{node}, .bindings = &.{} };
        const expected = evaluator.evaluate(ir, &h.reference, 1).ok;
        const actual = h.runtime.evaluate(ir, 1).ok;
        try compare(expected.values, actual.values);
        const result: u64 = @bitCast(actual.values[0].floating);
        try std.testing.expectEqual(if (std.math.isNan(node.kind.floating)) @as(u64, 0x7ff8000000000000) else bits, result);
    }
}

test "inspection and value reporting emit valid JSON for all binary64 classes" {
    const h = try Harness.create();
    defer scratch.release(h);
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    const ir = h.front.compile("A:float=NaN;B:float=Inf;C:float=-Inf;D:float=-0.0;E:float=0.55").ok;
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try std.testing.expectEqual(inspection.Result.ok, try inspector.write(&out, ir));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.array.items;
    try std.testing.expectEqualStrings("NaN", instructions[0].object.get("op").?.object.get("floating").?.string);
    try std.testing.expectEqualStrings("Inf", instructions[1].object.get("op").?.object.get("floating").?.string);
    try std.testing.expectEqualStrings("float", instructions[0].object.get("type").?.string);
    out = .fixed(&bytes);
    try std.json.Stringify.value([_]types.FloatReport{ .{ .value = -std.math.inf(f64) }, .{ .value = -0.0 }, .{ .value = std.math.nan(f64) }, .{ .value = 0.55 } }, .{}, &out);
    const values = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer values.deinit();
    try std.testing.expectEqualStrings("-Inf", values.value.array.items[0].string);
    try std.testing.expectEqualStrings("NaN", values.value.array.items[2].string);
    try bitsEqual(0.55, values.value.array.items[3].float);
}

test "generated dyadic arithmetic agrees with an independent exact integer oracle" {
    const h = try Harness.create();
    defer scratch.release(h);
    var source: [512]u8 = undefined;
    for (0..2000) |index| {
        const a: i64 = @as(i64, @intCast(index)) - 1000;
        const b: i64 = @intCast(index % 31 + 1);
        const text = try std.fmt.bufPrint(&source, "F(X:float)<computes>:float=(X+3.0)*{d}.0/8.0;A:float=F({d}.0);B:float=-A;C:float=A-{d}.0", .{ b, a, b });
        const result = try h.run(text);
        const exact: f64 = @as(f64, @floatFromInt((a + 3) * b)) / 8.0;
        try bitsEqual(exact, result.get("A").?.floating);
        try bitsEqual(-exact, result.get("B").?.floating);
        try bitsEqual(exact - @as(f64, @floatFromInt(b)), result.get("C").?.floating);
    }
}

test "source-sized float literals remain bounded and reusable" {
    const h = try Harness.create();
    defer scratch.release(h);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(source);
    const prefix = "A:float=0.";
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len..], '0');
    source[source.len - 1] = '1';
    const result = try h.run(source);
    try bitsEqual(0.0, result.get("A").?.floating);
    _ = try h.run("A:float=0.55");
}

test "seeded numeric source mutations preserve admission diagnostics and recovery" {
    const h = try Harness.create();
    defer scratch.release(h);
    const seed = "Base:float=0.55;F(X:float)<computes>:float=(X+Base)/2e0;Value:float=F(-1.25)";
    const alphabet = "0123456789.eE+-*/(),;:<>=#\nNaNInftrue\"\\";
    var random = std.Random.DefaultPrng.init(0x666c6f61742d3534);
    const rng = random.random();
    var bytes: [seed.len]u8 = undefined;
    for (0..2000) |_| {
        @memcpy(&bytes, seed);
        bytes[rng.intRangeLessThan(usize, 0, bytes.len)] = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
        const source = bytes[0..rng.intRangeLessThan(usize, 0, bytes.len + 1)];
        switch (h.front.compile(source)) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= source.len),
            .ok => |ir| {
                const budget = rng.intRangeLessThan(u32, 0, @intCast(ir.nodes.len + 1));
                const expected = evaluator.evaluate(ir, &h.reference, budget);
                const actual = h.runtime.evaluate(ir, budget);
                try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
                switch (expected) {
                    .failed => |diagnostic| {
                        try std.testing.expect(diagnostic.code != .invalid_ir);
                        try std.testing.expectEqualDeep(diagnostic, actual.failed);
                    },
                    .ok => |result| try compare(result.values, actual.ok.values),
                }
            },
        }
    }
    _ = try h.run(seed);
}
