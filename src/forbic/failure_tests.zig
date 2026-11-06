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
    fn compile(self: *Harness, source: []const u8) !types.Program {
        return switch (self.compiler.compile(source)) {
            .ok => |ir| ir,
            .failed => |d| {
                std.debug.print("failure compile: {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
                return error.Compile;
            },
        };
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        return self.executeIr(try self.compile(source), 131072);
    }
    fn executeIr(self: *Harness, ir: types.Program, budget: u64) !evaluator.Execution {
        const reference = evaluator.evaluateWithControlStorage(ir, &self.values, &self.members, &self.control, budget);
        const actual = self.runtime.evaluate(ir, budget);
        if (reference != .ok or actual != .ok) {
            if (reference == .failed) std.debug.print("reference: {s}\n", .{reference.failed.message()});
            if (actual == .failed) std.debug.print("VM: {s}\n", .{actual.failed.message()});
            return error.Execution;
        }
        try compare(reference, actual);
        _ = try reporting.validate(reference.ok, false, .{});
        _ = try reporting.validate(actual.ok, false, .{});
        return actual.ok;
    }
};
fn create() !*Harness {
    const h = try scratch.make(Harness);
    return h;
}
fn compare(a: evaluator.Result, b: evaluator.Result) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .failed) {
        try std.testing.expectEqualDeep(a.failed, b.failed);
        return;
    }
    try std.testing.expectEqualSlices(bool, a.ok.activity, b.ok.activity);
    try std.testing.expectEqualDeep(a.ok.failures, b.ok.failures);
    try std.testing.expectEqual(a.ok.failure_count, b.ok.failure_count);
    for (0..a.ok.values.len) |i| if (a.ok.active(i)) {
        try equal(a.ok.values[i], b.ok.values[i]);
    };
    try std.testing.expectEqual(a.ok.aggregate_values.len, b.ok.aggregate_values.len);
    for (a.ok.aggregate_values, b.ok.aggregate_values) |left, right| try equal(left, right);
}
fn equal(a: types.Value, b: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .floating) try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating))) else try std.testing.expectEqualDeep(a, b);
}

test "failure lazy arms contextual types templates defaults and strict predicates" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute(
        \\Choose(C:logic,X:i64)<computes>:i64=If(C,X,1/0)
        \\Good(X:i64)<computes><decides>:i64=If(Require[X>=0],X,Fail["negative"])
        \\p:=struct{N:i64=If(true,Choose(true,7),1/0),Empty:[]i64=If(false,array{1},array{})}
        \\All:p=p{};A<public>:i64=All.N+Attempt(Good[-1],2)
        \\B<public>:logic=Attempt(Require[true] and true,false)
        \\C<public>:float=If(false,1.0/0.0,-0.0)
        \\D<public>:string=Attempt(Fail["雪"],"fallback")
        \\mode:=enum{dark,light};E<public>:mode=If(true,mode.dark,mode.light)
    );
    try std.testing.expectEqual(@as(i64, 9), result.get("A").?.integer);
    try std.testing.expect(result.get("B").?.boolean);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(result.get("C").?.floating)));
    try std.testing.expectEqualStrings("fallback", result.get("D").?.string);
    try std.testing.expectEqual(@as(u32, 0), result.get("E").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 2), result.failure_count);
    try std.testing.expectEqualStrings("雪", result.failures[1].reason.?);
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.elements(result.get("All").?).?[1]).?.len);
}

test "nested fallback failure propagates outward and strict arguments fail in source order" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute("First(X:i64,Y:i64)<computes>:i64=X;A:i64=Attempt(Attempt(Fail[\"first\"],Fail[\"second\"]),3);B:i64=Attempt(First(Fail[\"left\"],Fail[\"right\"]),4)");
    try std.testing.expectEqual(@as(i64, 3), result.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.get("B").?.integer);
    try std.testing.expectEqual(@as(u32, 3), result.failure_count);
    for ([_][]const u8{ "first", "second", "left" }, result.failures) |reason, trace| try std.testing.expectEqualStrings(reason, trace.reason.?);
    const fatal = try h.compile("A:i64=Attempt(1/0,7)");
    try compare(evaluator.evaluateWithControlStorage(fatal, &h.values, &h.members, &h.control, 100), h.runtime.evaluate(fatal, 100));
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, h.runtime.evaluate(fatal, 100).failed.code);
}

test "failure contexts arities unused arms and call effects are checked before execution" {
    const h = try create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "A:logic=Require[true]", .code = .failure_context_required },
        .{ .source = "A:i64=Attempt(1,Fail[\"bad\"])", .code = .failure_context_required },
        .{ .source = "Bad()<computes>:logic=Require[true]", .code = .failure_context_required },
        .{ .source = "F()<computes><decides>:i64=Fail[\"x\"];A:i64=F[]", .code = .failure_context_required },
        .{ .source = "F()<computes><decides>:i64=1;A:i64=Attempt(F(),2)", .code = .expected_call },
        .{ .source = "F()<computes>:i64=1;A:i64=Attempt(F[],2)", .code = .expected_call },
        .{ .source = "A:i64=If(true,1,\"wrong\")", .code = .type_mismatch },
        .{ .source = "A:i64=If(1,2,3)", .code = .type_mismatch },
        .{ .source = "A:i64=Attempt(1,2.0)", .code = .type_mismatch },
        .{ .source = "A:logic=Attempt(Require[1],false)", .code = .type_mismatch },
        .{ .source = "A:i64=Attempt(Fail[1],2)", .code = .type_mismatch },
        // RFC-0090: an If without an else is a statement, with no value for `A`.
        .{ .source = "A:i64=If(true,1)", .code = .if_without_else },
        .{ .source = "A:i64=Attempt(1,2,3)", .code = .argument_count },
        .{ .source = "A:i64=If(true,1,Missing)", .code = .unknown_name },
        .{ .source = "Bad()<computes>:i64=If(false,\"x\",1)", .code = .type_mismatch },
        .{ .source = "A:logic=Attempt(Require[true),false)", .code = .unexpected_token },
    };
    for (cases) |c| {
        const r = h.compiler.compile(c.source);
        try std.testing.expect(r == .failed);
        try std.testing.expectEqual(c.code, r.failed.code);
        _ = try h.execute("A:i64=If(true,7,1/0)");
    }
}

test "1000 independent branch failure oracles preserve aggregate aliases and recovery" {
    const h = try create();
    defer scratch.release(h);
    var rng = std.Random.DefaultPrng.init(0x626262);
    const random = rng.random();
    var source_buffer: [2048]u8 = undefined;
    for (0..1000) |_| {
        const a = random.intRangeAtMost(i64, -1000, 1000);
        const b = random.intRangeAtMost(i64, -1000, 1000);
        const source = try std.fmt.bufPrint(&source_buffer, "Valid(X:i64)<computes><decides>:i64=If(Require[X>=0],X,0);Rows:[][]i64=If({s},array{{array{{{d},{d}}}}},array{{array{{{d}}}}});Value:i64=Attempt(Valid[{d}],{d});Count:i64=Rows.Length", .{ if (a < b) "true" else "false", a, b, b, a, b });
        const execution = try h.execute(source);
        try std.testing.expectEqual(if (a >= 0) a else b, execution.get("Value").?.integer);
        const row = execution.elements(execution.elements(execution.get("Rows").?).?[0]).?;
        try std.testing.expectEqual(@as(usize, if (a < b) 2 else 1), row.len);
        try std.testing.expectEqual(if (a < b) a else b, row[0].integer);
        try std.testing.expectEqual(@as(u32, if (a >= 0) 0 else 1), execution.failure_count);
    }
}

test "every fuel boundary skips untaken instructions and fatal exhaustion leaves journal idle" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        "A:i64=If(true,7,1/0)",                                            "A:i64=If(false,1/0,7)",                                      "A:logic=Attempt(Require[false],true)",
        "A:[]i64=Attempt(If(Require[false],array{1,2},array{}),array{7})", "A:i64=Attempt(Attempt(Fail[\"first\"],Fail[\"second\"]),7)", "A:logic=If(true,\"abcdef\"==\"abcdef\",false)",
    }) |source| {
        const ir = try h.compile(source);
        var first_success: ?u32 = null;
        for (0..ir.nodes.len + ir.members.len + 16) |fuel| {
            const ref = evaluator.evaluateWithControlStorage(ir, &h.values, &h.members, &h.control, @intCast(fuel));
            const result = h.runtime.evaluate(ir, @intCast(fuel));
            try compare(ref, result);
            try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
            if (result == .ok) {
                _ = try reporting.validate(result.ok, false, .{});
                if (first_success == null) first_success = @intCast(fuel);
            } else try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
        }
        try std.testing.expect(first_success != null);
        if (std.mem.eql(u8, source, "A:i64=If(true,7,1/0)")) try std.testing.expectEqual(@as(u32, 5), first_success.?);
        if (std.mem.eql(u8, source, "A:i64=If(false,1/0,7)")) try std.testing.expectEqual(@as(u32, 4), first_success.?);
        try std.testing.expectEqual(types.Diagnostic.Code.control_storage_required, evaluator.evaluateWithStorage(ir, &h.values, &h.members, 100).failed.code);
    }
}

test "control nesting admits 32 levels per frame including pure declared transacts bodies" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var source: [4096]u8 = undefined;
    for ([_]usize{ 31, 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&source);
        try out.writeAll("A:i64=");
        for (0..depth) |_| try out.writeAll("Attempt(");
        try out.writeAll("7");
        for (0..depth) |_| try out.writeAll(",8)");
        if (depth <= 32) {
            try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.control_limit, h.compiler.compile(out.buffered()).failed.code);
    }
    var out = std.Io.Writer.fixed(&source);
    try out.writeAll("F()<computes>:i64=If(true,7,8);A:i64=");
    for (0..32) |_| try out.writeAll("Attempt(");
    try out.writeAll("F()");
    for (0..32) |_| try out.writeAll(",8)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
    out = .fixed(&source);
    try out.writeAll("F()<computes>:i64=Attempt(7,8);A:i64=");
    for (0..32) |_| try out.writeAll("Attempt(");
    try out.writeAll("F()");
    for (0..32) |_| try out.writeAll(",8)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
    out = .fixed(&source);
    try out.writeAll("F()<transacts>:i64=Attempt(7,8);A:i64=");
    for (0..32) |_| try out.writeAll("Attempt(");
    try out.writeAll("F()");
    for (0..32) |_| try out.writeAll(",8)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
    _ = try h.execute("A:i64=Attempt(Fail[\"recover\"],7)");
}

test "trace prefix pressure preserves all failures and exact report admission" {
    const h = try create();
    defer scratch.release(h);
    var source: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&source);
    for (0..40) |i| try out.print("A{d}:i64=Attempt(Fail[\"reason\"],{d});", .{ i, i });
    const result = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, 40), result.failure_count);
    try std.testing.expectEqual(@as(usize, 32), result.failures.len);
    try std.testing.expectEqual(@as(i64, 39), result.get("A39").?.integer);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const admitted = try reporting.write(&writer, result, false, .{});
    writer = .fixed(&buffer);
    _ = try reporting.write(&writer, result, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    writer = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&writer, result, false, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "reports reject each forged activity bit trace merge value and arm escape before writing" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute("Rows:[][]i64=If(false,array{array{1,2}},array{array{7}});A:i64=Attempt(Fail[\"why\"],7)");
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var mask: [types.limits.nodes]bool = undefined;
    @memcpy(mask[0..result.activity.len], result.activity);
    var forged = result;
    forged.activity = mask[0..result.activity.len];
    for (0..result.activity.len) |i| {
        mask[i] = !mask[i];
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
        mask[i] = !mask[i];
    }
    var trace = result.failures[0];
    trace.instruction += 1;
    forged = result;
    forged.failures = &.{trace};
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    forged = result;
    forged.failure_count += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    forged = result;
    forged.failures = &.{};
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    const root = result.program.bindings[1].node;
    h.runtime.machine.values[root] = .{ .integer = 999 };
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, result, false, .{}));
}

test "independent IR and VM reject malformed targets scope escape and control count including unused tails" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    // The body's locals are sized by the bootstrap capacities. Under a larger profile a Debug
    // frame holding them would overflow the stack before the skip (P0.8), so they live in a
    // function that only a bootstrap run calls.
    try independentIrAndVmRejectMalformedAtBootstrap();
}

fn independentIrAndVmRejectMalformedAtBootstrap() !void {
    const h = try create();
    defer scratch.release(h);
    const original = try h.compile("A:i64=If(true,1,2);B:i64=Attempt(Fail[\"x\"],3);C:i64=7");
    var nodes: [types.limits.nodes]types.Node = undefined;
    var ir = original;
    ir.nodes = nodes[0..original.nodes.len];
    var random = std.Random.DefaultPrng.init(0x626263);
    const rng = random.random();
    for (0..2000) |iteration| {
        @memcpy(nodes[0..original.nodes.len], original.nodes);
        ir.control_ops = original.control_ops;
        const index = rng.uintLessThan(u32, @intCast(original.nodes.len));
        switch (iteration % 5) {
            0 => ir.control_ops +%= 1,
            1 => nodes[index].value_type = @fromBackingInt(@as(u16, 65535)),
            2 => nodes[index].kind = .{ .otherwise = index },
            3 => nodes[index].kind = .{ .merge = .{ .begin = index, .left = index, .right = index } },
            4 => nodes[index].kind = .{ .binary = .{ .op = .add, .lhs = std.math.maxInt(u32), .rhs = 0 } },
            else => unreachable,
        }
        try std.testing.expect(evaluator.validate(ir, h.values.len) != null);
        try std.testing.expect(h.runtime.evaluate(ir, 0) == .failed);
    }
    @memcpy(nodes[0..original.nodes.len], original.nodes);
    ir.control_ops = original.control_ops;
    nodes[nodes[original.bindings[0].node].kind.merge.right].kind = .{ .binary = .{ .op = .add, .lhs = nodes[original.bindings[0].node].kind.merge.left, .rhs = 0 } };
    try std.testing.expect(evaluator.validate(ir, h.values.len) != null);
    try std.testing.expect(h.runtime.evaluate(ir, 100) == .failed);
    var bindings: [3]types.Binding = undefined;
    @memcpy(&bindings, original.bindings);
    ir = original;
    ir.bindings = &bindings;
    bindings[2].node = original.nodes[original.bindings[0].node].kind.merge.left;
    try std.testing.expect(evaluator.validate(ir, h.values.len) != null);
    try std.testing.expect(h.runtime.evaluate(ir, 100) == .failed);
    _ = try h.execute("A:i64=If(false,1/0,7)");
}

test "source mutations and all truncations recover without native recursion or divergent engines" {
    const h = try create();
    defer scratch.release(h);
    const source = "F(X:i64)<computes><decides>:i64=If(Require[X>0],X,Fail[\"bad\"]);A:i64=Attempt(F[7],If(false,1/0,8))";
    var buffer: [source.len]u8 = undefined;
    var generator = std.Random.DefaultPrng.init(0x626264);
    const random = generator.random();
    for (0..1500) |_| {
        @memcpy(&buffer, source);
        const position = random.uintLessThan(usize, buffer.len);
        const punctuation = "()[]{},;:<>=+-*/\"\\\n";
        buffer[position] = punctuation[random.uintLessThan(usize, punctuation.len)];
        const result = h.compiler.compile(&buffer);
        if (result == .ok) {
            try std.testing.expect(evaluator.validate(result.ok, h.values.len) == null);
            try compare(evaluator.evaluateWithControlStorage(result.ok, &h.values, &h.members, &h.control, 131072), h.runtime.evaluate(result.ok, 131072));
        }
        _ = try h.execute("A:i64=Attempt(Fail[\"recover\"],7)");
    }
    for (0..source.len) |end| {
        const result = h.compiler.compile(source[0..end]);
        if (result == .ok) try compare(evaluator.evaluateWithControlStorage(result.ok, &h.values, &h.members, &h.control, 131072), h.runtime.evaluate(result.ok, 131072));
    }
}

test "imported failable runtime frames preserve defining module traces and inspection format 13" {
    const h = try create();
    defer scratch.release(h);
    const ir = switch (h.compiler.compileBundle(.{ .root = "main.forb", .modules = &.{
        .{ .path = "main.forb", .source = "P:=import{\"policy.forb\"};A:i64=Attempt(P.Check[-1],7)" },
        .{ .path = "policy.forb", .source = "Check<public>(X:i64)<computes><decides>:i64=If(Require[X>=0],X,Fail[\"bad\"])" },
    } })) {
        .ok => |ir| ir,
        .failed => return error.Compile,
    };
    const execution = try h.executeIr(ir, 100);
    const located = @import("modules.zig").locate(ir.source, ir.paths, ir.modules, .{ .span = execution.failures[0].span, .code = execution.failures[0].code }, "fallback");
    try std.testing.expectEqualStrings("policy.forb", located.path);
    try std.testing.expectEqual(@as(u32, 1), located.diagnostic.location(located.source).line);
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect((try inspector.write(&out, ir)) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":13,"));
}

test "control aggregate dynamic ranges compose records tuples options maps and failed prefixes" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute(
        \\p:=struct{M:map(string,option(i64)),T:tuple([]i64,i64)}
        \\Make(X:tuple([]i64,i64),Ok:logic)<computes><decides>:p=If(Require[Ok],p{M:=map{"x"=>option{7}},T:=X},Fail["no"])
        \\A:p=Attempt(Make[tuple{array{1,2},3},false],If(true,p{T:=tuple{array{},7},M:=map{}},p{T:=tuple{array{1/0},0},M:=map{}}))
        \\B:map(string,option(i64))=If(false,map{"bad"=>option{1}},map{"good"=>option{42}})
        \\Value:i64=Or(Or(Lookup(B,"good"),option{}),0)+A.T(1)
    );
    try std.testing.expectEqual(@as(i64, 49), result.get("Value").?.integer);
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.elements(result.get("A").?).?[0]).?.len);
}

test "control admits full register member and reason pools with bounded trace output" {
    try @import("profile.zig").requireBootstrap();
    // The body's locals are sized by the bootstrap capacities. Under a larger profile a Debug
    // frame holding them would overflow the stack before the skip (P0.8), so they live in a
    // function that only a bootstrap run calls.
    try controlAdmitsFullPoolsAtBootstrap();
}

fn controlAdmitsFullPoolsAtBootstrap() !void {
    const h = try create();
    defer scratch.release(h);
    // The source token profile cannot spell 8,192 comma-separated operands;
    // exercise the exact independently admitted IR member pool directly.
    const template_ir = try h.compile("One:i64=1;A:[]i64=If(false,array{One},array{})");
    var full_members: [types.limits.aggregate_elements]u32 = @splat(0);
    var member_nodes: [16]types.Node = undefined;
    @memcpy(member_nodes[0..template_ir.nodes.len], template_ir.nodes);
    for (member_nodes[0..template_ir.nodes.len]) |*node| if (node.kind == .aggregate) {
        node.kind.aggregate = if (node.kind.aggregate.end != node.kind.aggregate.start) .{ .start = 0, .end = types.limits.aggregate_elements } else .{ .start = types.limits.aggregate_elements, .end = types.limits.aggregate_elements };
    };
    var full_ir = template_ir;
    full_ir.nodes = member_nodes[0..template_ir.nodes.len];
    full_ir.members = &full_members;
    const result = try h.executeIr(full_ir, types.limits.evaluation_work);
    try std.testing.expectEqual(@as(usize, 8192), result.program.members.len);
    try std.testing.expectEqual(@as(usize, 0), result.aggregate_values.len);
    var ir = try h.compile("A:i64=Attempt(Fail[\"x\"],7)");
    const strings = try std.testing.allocator.alloc(u8, types.limits.string_bytes);
    defer std.testing.allocator.free(strings);
    @memset(strings, 'x');
    var nodes: [types.limits.nodes]types.Node = undefined;
    @memcpy(nodes[0..ir.nodes.len], ir.nodes);
    const original_len = ir.nodes.len;
    for (nodes[0..original_len]) |*node| if (node.kind == .string) {
        node.kind.string = .{ .start = 0, .end = types.limits.string_bytes };
    };
    for (nodes[original_len..]) |*node| node.* = .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .integer = 1 } };
    ir.strings = strings;
    ir.nodes = &nodes;
    const full = try h.executeIr(ir, types.limits.evaluation_work);
    try std.testing.expectEqual(@as(usize, 8192), full.values.len);
    try std.testing.expectEqual(@as(usize, 65536), full.failures[0].reason.?.len);
    const report = @import("failure_report.zig");
    const buffer = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try report.write(&writer, full, "program.forb", .{});
    const exact = writer.end;
    writer = .fixed(buffer);
    try report.write(&writer, full, "program.forb", .{ .output_bytes = exact });
    writer = .fixed(buffer);
    try std.testing.expectError(error.ReportLimit, report.write(&writer, full, "program.forb", .{ .output_bytes = exact - 1 }));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}
