const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");

const Harness = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},

    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const ir = switch (self.compiler.compile(source)) {
            .ok => |ir| ir,
            .failed => |diagnostic| {
                std.debug.print("predicate compile: {s} at {d}\n", .{ diagnostic.message(), diagnostic.span.start });
                return error.UnexpectedCompile;
            },
        };
        return self.executeIr(ir);
    }
    fn executeIr(self: *Harness, ir: types.Program) !evaluator.Execution {
        // `and`/`or` with an operand that is not plain are conditionals (RFC-0076).
        const reference = evaluator.evaluateWithControlStorage(ir, &self.values, &self.members, &self.control, 131072);
        const actual = self.runtime.evaluate(ir, 131072);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqualSlices(bool, reference.ok.activity, actual.ok.activity);
        for (reference.ok.values, actual.ok.values, 0..) |left, right, index| if (reference.ok.active(index)) try equal(left, right);
        for (reference.ok.aggregate_values, actual.ok.aggregate_values) |left, right| try equal(left, right);
        return actual.ok;
    }
};
fn create() !*Harness {
    const h = try scratch.make(Harness);
    return h;
}
fn equal(left: types.Value, right: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
    switch (left) {
        .floating => |value| try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(right.floating))),
        .string => |value| try std.testing.expectEqualStrings(value, right.string),
        .integer => |value| try std.testing.expectEqual(value, right.integer),
        .boolean => |value| try std.testing.expectEqual(value, right.boolean),
        .aggregate => |value| try std.testing.expectEqualDeep(value, right.aggregate),
        .enumeration => |value| try std.testing.expectEqualDeep(value, right.enumeration),
        .callable => |value| try std.testing.expectEqualDeep(value, right.callable),
        .object => |value| try std.testing.expectEqualDeep(value, right.object),
        .rational => |value| try std.testing.expectEqualDeep(value, right.rational),
    }
}

test "predicate precedence strict logic templates defaults and imported public helpers compose" {
    const h = try create();
    defer scratch.release(h);
    const source =
        \\Both(a:i64,b:i64)<computes>:logic=not (a == b) and a + 2 * 3 <= b or a > b
        \\settings:=struct{enabled:logic=Both(1,9),name:string="snow"}
        \\Value:settings=settings{}
        \\Answer<public>:logic=Value.enabled and Both(4,4) == false
        \\Text<public>:logic=Value.name == "snow"
        \\mode:=enum{light,dark}
        \\Tone<public>:logic=mode.light != mode.dark
    ;
    const execution = try h.execute(source);
    try std.testing.expect(execution.get("Answer").?.boolean and execution.get("Text").?.boolean and execution.get("Tone").?.boolean);
    try std.testing.expectEqual(@as(u32, 1), execution.program.string_comparisons);
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, execution, true, .{});
    try std.testing.expectEqualStrings("{\"Answer\":true,\"Text\":true,\"Tone\":true}\n", out.buffered());
    const inventory = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "P:=import{\"policy.forb\"};Enabled<public>:logic=P.Valid(6) and not P.Valid(101)" },
        .{ .path = "policy.forb", .source = "Minimum:i64=4;Valid<public>(x:i64)<computes>:logic=x >= Minimum and x <= 100" },
    };
    const bundled = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory }).ok;
    try std.testing.expect((try h.executeIr(bundled)).get("Enabled").?.boolean);
}

test "all binary64 predicate truth tables use independent ordinal expectations" {
    const h = try create();
    defer scratch.release(h);
    const inputs = [_]struct { text: []const u8, rank: i8, nan: bool = false }{
        .{ .text = "-Inf", .rank = -4 }, .{ .text = "-2.0", .rank = -3 }, .{ .text = "-5e-324", .rank = -1 },
        .{ .text = "-0.0", .rank = 0 },  .{ .text = "0.0", .rank = 0 },   .{ .text = "5e-324", .rank = 1 },
        .{ .text = "2.0", .rank = 3 },   .{ .text = "Inf", .rank = 4 },   .{ .text = "NaN", .rank = 0, .nan = true },
    };
    var buffer: [1024]u8 = undefined;
    for (inputs) |left| for (inputs) |right| {
        const source = try std.fmt.bufPrint(&buffer, "L:float={s};R:float={s};E:logic=L==R;N:logic=L!=R;LT:logic=L<R;LE:logic=L<=R;GT:logic=L>R;GE:logic=L>=R", .{ left.text, right.text });
        const execution = try h.execute(source);
        const same = if (left.nan or right.nan) left.nan and right.nan else left.rank == right.rank;
        const ordered = !left.nan and !right.nan;
        try std.testing.expectEqual(same, execution.get("E").?.boolean);
        try std.testing.expectEqual(!same, execution.get("N").?.boolean);
        try std.testing.expectEqual(ordered and left.rank < right.rank, execution.get("LT").?.boolean);
        try std.testing.expectEqual(ordered and left.rank <= right.rank, execution.get("LE").?.boolean);
        try std.testing.expectEqual(ordered and left.rank > right.rank, execution.get("GT").?.boolean);
        try std.testing.expectEqual(ordered and left.rank >= right.rank, execution.get("GE").?.boolean);
    };
}

test "2000 generated integer comparisons match widened arithmetic at both i64 extrema" {
    const h = try create();
    defer scratch.release(h);
    var generator = std.Random.DefaultPrng.init(0x616161);
    const random = generator.random();
    var buffer: [1024]u8 = undefined;
    for (0..2000) |index| {
        const left = if (index % 4 == 0) std.math.minInt(i64) else random.int(i64);
        const right = if (index % 4 == 0) std.math.maxInt(i64) else random.int(i64);
        const difference = @as(i128, left) - @as(i128, right);
        const source = try std.fmt.bufPrint(&buffer, "L:i64={d};R:i64={d};E:logic=L==R;N:logic=L!=R;LT:logic=L<R;LE:logic=L<=R;GT:logic=L>R;GE:logic=L>=R;Logic:logic=not (L<R) or L!=R and false", .{ left, right });
        const execution = try h.execute(source);
        try std.testing.expectEqual(difference == 0, execution.get("E").?.boolean);
        try std.testing.expectEqual(difference != 0, execution.get("N").?.boolean);
        try std.testing.expectEqual(difference < 0, execution.get("LT").?.boolean);
        try std.testing.expectEqual(difference <= 0, execution.get("LE").?.boolean);
        try std.testing.expectEqual(difference > 0, execution.get("GT").?.boolean);
        try std.testing.expectEqual(difference >= 0, execution.get("GE").?.boolean);
        try std.testing.expectEqual(difference >= 0, execution.get("Logic").?.boolean);
    }
}

test "predicate type rejection keeps diagnostics and a skipped second operand does not run" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        "A:logic=1==1.0",             "A:logic=true<false",        "A:logic=\"a\"<=\"b\"",         "A:logic=not 1", "A:logic=1 and true",
        "A:logic=1<2<3.0",            "A:logic=array{1}<array{1}", "A:logic=tuple{1}==tuple{2.0}", "A:i64=1==1",    "a:=enum{x};b:=enum{x};A:logic=a.x==b.x",
        "a:=enum{x};A:logic=a.x<a.x",
    }) |source| {
        const failed = h.compiler.compile(source).failed;
        try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, failed.code);
        try std.testing.expect(failed.span.end <= source.len);
        _ = try h.execute("Answer:logic=not false and true or false");
    }
    // RFC-0076 (D2): the left operand decides, so the division is never reached.
    try std.testing.expect(!(try h.execute("A:logic=false and (1/0==0)")).get("A").?.boolean);
    try std.testing.expect((try h.execute("A:logic=true or (1/0==0)")).get("A").?.boolean);
    // When it does not decide, the right operand runs and its error is the run's.
    for ([_][]const u8{ "A:logic=true and (1/0==0)", "A:logic=false or (1/0==0)" }) |source| {
        const ir = h.compiler.compile(source).ok;
        const reference = evaluator.evaluateWithControlStorage(ir, &h.values, &h.members, &h.control, 128).failed;
        const actual = h.runtime.evaluate(ir, 128).failed;
        try std.testing.expectEqualDeep(reference, actual);
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, actual.code);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
    }
}

test "decoded strings charge exact minimum length before comparison at every fuel boundary" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const source = "A:string=\"\\nabc\";B:string=\"xabc\";E:logic=A==B;N:logic=A!=B";
    const ir = h.compiler.compile(source).ok;
    const required = ir.nodes.len + 8;
    for (0..required + 1) |budget| {
        const reference = evaluator.evaluateWithStorage(ir, &h.values, &h.members, @intCast(budget));
        const actual = h.runtime.evaluate(ir, @intCast(budget));
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .failed) {
            try std.testing.expectEqualDeep(reference.failed, actual.failed);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.failed.code);
        } else {
            try std.testing.expect(!actual.ok.get("E").?.boolean and actual.ok.get("N").?.boolean);
        }
    }
    // One maximum-size immutable pool can be borrowed twice without source
    // literal overhead or an invented per-string cap. Raw IR is fully admitted.
    const pool = try std.testing.allocator.alloc(u8, types.limits.string_bytes);
    defer std.testing.allocator.free(pool);
    @memset(pool, 'x');
    const origin: types.Span = .{ .start = 0, .end = 0 };
    const nodes = [_]types.Node{
        .{ .span = origin, .value_type = .string, .kind = .{ .string = .{ .start = 0, .end = @intCast(pool.len) } } },
        .{ .span = origin, .value_type = .logic, .kind = .{ .compare = .{ .lhs = 0, .rhs = 0, .op = .equal } } },
    };
    const large: types.Program = .{ .source = "A", .strings = pool, .nodes = &nodes, .bindings = &.{.{ .name = .{ .start = 0, .end = 1 }, .node = 1, .value_type = .logic, .is_public = true }}, .string_comparisons = 1 };
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, h.runtime.evaluate(large, types.limits.string_bytes + 1).failed.code);
    try std.testing.expect((try h.executeIr(large)).get("A").?.boolean);
    _ = try h.execute("Answer:logic=true==not false");
}

test "predicate metadata and raw malformed tails cannot bypass admission or dynamic fuel" {
    const h = try create();
    defer scratch.release(h);
    const original = (try h.execute("A:string=\"abc\";E:logic=A==A;L:logic=true and not false")).program;
    var nodes: [6]types.Node = undefined;
    try std.testing.expectEqual(@as(usize, nodes.len), original.nodes.len);
    var generator = std.Random.DefaultPrng.init(0x61006100);
    const random = generator.random();
    for (0..3000) |_| {
        @memcpy(&nodes, original.nodes);
        var ir = original;
        ir.nodes = &nodes;
        switch (random.uintLessThan(u8, 6)) {
            0 => ir.string_comparisons = random.int(u32),
            1 => nodes[1].kind.compare.lhs = random.int(u32),
            2 => nodes[1].kind.compare.rhs = random.int(u32),
            3 => nodes[1].value_type = .string,
            4 => nodes[1].kind.compare.op = .less,
            5 => nodes[nodes.len - 1].kind.logic_binary.rhs = random.int(u32),
            else => unreachable,
        }
        h.values[0] = .{ .integer = 123 };
        h.runtime.machine.values[0] = .{ .integer = 123 };
        h.runtime.machine.journal.cells[0] = 17;
        const reference = evaluator.evaluateWithStorage(ir, &h.values, &h.members, 0);
        const actual = h.runtime.evaluate(ir, 0);
        try std.testing.expect(reference == .failed and actual == .failed);
        try std.testing.expectEqual(reference.failed.code, actual.failed.code);
        try std.testing.expectEqual(@as(i64, 123), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 123), h.runtime.machine.values[0].integer);
        try std.testing.expectEqual(@as(i64, 17), h.runtime.machine.journal.cells[0]);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
    }
    _ = try h.execute("Answer:logic=7>=6");
}

test "predicate inspection format seven validates counts before output and reports exact operators" {
    const h = try create();
    defer scratch.release(h);
    const execution = try h.execute("Answer<public>:logic=1+2>=3 and not false");
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    var buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, execution.program));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"greater_equal\"") != null);
    var bad = execution.program;
    bad.string_comparisons = 1;
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, bad)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "predicate nodes and unary expression stacks admit exact profiles and recover" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const buffer = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(buffer);
    var out = std.Io.Writer.fixed(buffer);
    try out.writeAll("Value:logic=true");
    for (0..4094) |_| try out.writeAll(" and true");
    try out.writeAll(" and not true");
    const ir = h.compiler.compile(out.buffered()).ok;
    try std.testing.expectEqual(@as(usize, types.limits.nodes), ir.nodes.len);
    try std.testing.expect(!(try h.executeIr(ir)).get("Value").?.boolean);
    try out.writeAll(" and true");
    try std.testing.expectEqual(types.Diagnostic.Code.node_limit, h.compiler.compile(out.buffered()).failed.code);
    for ([_]usize{ types.limits.expression_depth, types.limits.expression_depth + 1 }) |count| {
        out = .fixed(buffer);
        try out.writeAll("Value:logic=");
        for (0..count) |_| try out.writeAll("not ");
        try out.writeAll("true");
        if (count == types.limits.expression_depth) try std.testing.expect((try h.execute(out.buffered())).get("Value").?.boolean) else try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, h.compiler.compile(out.buffered()).failed.code);
    }
    _ = try h.execute("Value:logic=1==1");
}

test "string predicate exhaustion unwinds active writes and retains earlier machine state" {
    const h = try create();
    defer scratch.release(h);
    const code = [_]vm.Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 7 } },                                       .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },                               .{ .value_type = .string, .op = .{ .string = .{ .start = 0, .end = 3 } } },
        .{ .value_type = .logic, .op = .{ .compare = .{ .lhs = 1, .rhs = 1, .op = .equal } } }, .{ .op = .{ .require = 2 } },
        .{ .op = .commit },
    };
    const program: vm.Program = .{ .code = &code, .strings = "abc", .string_comparisons = 1 };
    for (0..11) |budget| {
        h.runtime.machine.journal.cells[0] = 17;
        const result = h.runtime.machine.run(program, @intCast(budget));
        if (budget < 10) {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            try std.testing.expectEqual(@as(i64, 17), h.runtime.machine.journal.cells[0]);
        } else {
            try std.testing.expect(result == .ok and result.ok[2].boolean);
            try std.testing.expectEqual(@as(i64, 7), h.runtime.machine.journal.cells[0]);
        }
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
    }
    var forged = program;
    forged.string_comparisons = 0;
    h.runtime.machine.journal.cells[0] = 17;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(forged, 7).failed.code);
    try std.testing.expectEqual(@as(i64, 17), h.runtime.machine.journal.cells[0]);
}

test "1500 predicate source mutations retain checked locations semantic agreement and workspace reuse" {
    const h = try create();
    defer scratch.release(h);
    const original = "Eq(x:float,y:float)<computes>:logic=x==y;A:logic=Eq(NaN,NaN) and not (0.0<-0.0);B:logic=\"snow\"!=\"other\"";
    var changed: [original.len]u8 = undefined;
    var generator = std.Random.DefaultPrng.init(0x6161006161);
    const random = generator.random();
    const punctuation = "=<>!()+-*/.,:;{}[]\n\\\"";
    for (0..1500) |_| {
        @memcpy(&changed, original);
        changed[random.uintLessThan(usize, changed.len)] = punctuation[random.uintLessThan(usize, punctuation.len)];
        switch (h.compiler.compile(&changed)) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= changed.len),
            .ok => |ir| {
                try std.testing.expect(evaluator.validate(ir, h.values.len) == null);
                const reference = evaluator.evaluateWithStorage(ir, &h.values, &h.members, 16384);
                const actual = h.runtime.evaluate(ir, 16384);
                try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
                if (reference == .failed) try std.testing.expectEqualDeep(reference.failed, actual.failed) else for (reference.ok.values, actual.ok.values) |left, right| try equal(left, right);
            },
        }
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
        _ = try h.execute("Value:logic=NaN==NaN and not (NaN<=NaN)");
    }
}
