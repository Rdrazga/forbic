//! Independent counted state iteration, quota, lifetime and replay oracles.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const frames = @import("call_frames.zig");
const state = @import("source_state.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");
const trace_report = @import("failure_report.zig");
const Harness = struct {
    pub const parts = .{ "front", "runtime" };
    front: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},
    state: state.ReferenceState = .{},
    frames: frames.ReferenceStorage = .{},
    text: [types.limits.source_bytes]u8 = undefined,
    metadata: [types.limits.functions]types.RuntimeFunction = undefined,
    body: [types.limits.template_nodes]types.FunctionNode = undefined,
    steps: [types.limits.call_steps + 1]types.CallStep = undefined,
    traces: [types.limits.failure_traces]types.FailureTrace = undefined,
    fn compile(self: *Harness, source: []const u8) !types.Program {
        return switch (self.front.compile(source)) {
            .ok => |p| p,
            .failed => |d| {
                std.debug.print("iteration compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
                return error.Compile;
            },
        };
    }
    fn run(self: *Harness, p: types.Program, fuel: u64) !evaluator.Result {
        const reference = evaluator.evaluateWithRuntimeStorage(p, &self.values, &self.members, &self.control, &self.state, &self.frames, fuel);
        const actual = self.runtime.evaluate(p, fuel);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        try std.testing.expect(self.frames.depth == 0 and self.frames.count == 0 and self.state.depth == 0);
        try std.testing.expect(self.runtime.machine.calls.depth == 0 and self.runtime.machine.calls.count == 0 and self.runtime.machine.source.depth == 0 and self.runtime.machine.journal.depth == 0);
        if (actual == .failed) {
            try std.testing.expectEqualDeep(reference.failed, actual.failed);
            try std.testing.expect(self.control.call_count == 0 and self.runtime.machine.control.call_count == 0);
            try std.testing.expect(self.control.trace_count == 0 and self.control.failure_count == 0 and self.runtime.machine.control.trace_count == 0 and self.runtime.machine.control.failure_count == 0);
            return actual;
        }
        try std.testing.expectEqual(self.state.cell_count, self.runtime.machine.source.cell_count);
        for (self.state.cells[0..self.state.cell_count], self.runtime.machine.source.cells[0..self.runtime.machine.source.cell_count]) |a, b| {
            try std.testing.expectEqual(a.initialized, b.initialized);
            if (a.initialized) try equal(a.value, b.value);
        }
        try std.testing.expectEqualSlices(bool, reference.ok.activity, actual.ok.activity);
        try std.testing.expectEqualDeep(reference.ok.failures, actual.ok.failures);
        try std.testing.expectEqual(reference.ok.failure_count, actual.ok.failure_count);
        for (reference.ok.values, actual.ok.values, 0..) |a, b, index| if (actual.ok.active(index)) try equal(a, b);
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try equal(a, b);
        try std.testing.expectEqual(reference.ok.call_steps.len, actual.ok.call_steps.len);
        for (reference.ok.call_steps, actual.ok.call_steps) |a, b| {
            try std.testing.expectEqual(a.kind, b.kind);
            try std.testing.expectEqual(a.function, b.function);
            try std.testing.expectEqual(a.pc, b.pc);
            try equal(a.value, b.value);
        }
        // Physical-member tests intentionally retain many repeated aggregate
        // snapshots; fund their separate report traversal explicitly.
        _ = try reporting.validate(reference.ok, false, .{ .work = 1024 * 1024 });
        _ = try reporting.validate(actual.ok, false, .{ .work = 1024 * 1024 });
        return actual;
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const r = try self.run(try self.compile(source), 131072);
        if (r == .failed) {
            std.debug.print("iteration run {s}\n", .{r.failed.message()});
            return error.Execute;
        }
        return r.ok;
    }
};
fn create() !*Harness {
    const h = try scratch.make(Harness);
    return h;
}
fn equal(a: types.Value, b: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .floating) try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating))) else try std.testing.expectEqualDeep(a, b);
}

test "iteration preserves strict state snapshots zero count and reusable alias helpers" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Step(X:i64)<computes>:i64=X+2;Identity(X:i64)<computes>:i64=X;A:i64=Iterate(Step,5,3);B:i64=Iterate(Step,0,A);C:i64=Iterate(Identity,17,B);D:i64=Identity(C);E:i64=Iterate(Identity,2,D)");
    try std.testing.expectEqual(@as(i64, 13), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 13), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 13), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 13), x.get("D").?.integer);
    try std.testing.expectEqual(@as(usize, 2), x.program.functions.len);
    try std.testing.expectEqual(@as(u32, 0), x.program.call_ops);
    try std.testing.expectEqual(@as(usize, 0), x.program.call_arguments.len);
    try std.testing.expectEqual(@as(usize, 34), x.call_steps.len); // Step:15; Identity:17+2.
    try std.testing.expect(h.front.functions.definitions[1].runtime == null);
    try std.testing.expect(h.front.functions.definitions[1].alias_runtime != null);
}

test "iteration evaluates count and initial strictly before negative count admission" {
    const h = try create();
    defer scratch.release(h);
    const source = "var C:i64=0;Step(X:i64)<transacts>:i64=Block{set C=C+100;X+1};A:i64=Iterate(Step,Set(C,C+1)-1,Set(C,C+4));B:i64=C";
    const x = try h.execute(source);
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("B").?.integer);
    try std.testing.expectEqual(@as(usize, 0), x.call_steps.len);
    const negative = try h.compile("Step(X:i64)<computes>:i64=X;A:i64=Iterate(Step,-1,3)");
    try std.testing.expectEqual(types.Diagnostic.Code.negative_iteration_count, (try h.run(negative, 1000)).failed.code);
    const strict = try h.compile("Step(X:i64)<computes>:i64=X;A:i64=Iterate(Step,-1,1/0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(strict, 1000)).failed.code);
    const zero = try h.compile("Step(X:i64)<computes>:i64=X;A:i64=Iterate(Step,0,1/0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(zero, 1000)).failed.code);
    const huge = try h.compile("Step(X:i64)<computes>:i64=X;A:i64=Iterate(Step,9223372036854775807,1)");
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(huge, 100)).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try h.execute("A:i64=42")).get("A").?.integer);
}

test "iteration returns aggregate snapshots without borrowing reused frames" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("State<public>:=struct{N:i64,Text:string};Step(X:State)<computes>:State=State{N:=X.N+1,Text:=X.Text};Seed:State=State{N:=2,Text:=\"雪\"};Final:State=Iterate(Step,20,Seed);After:i64=Final.N;Old:i64=Seed.N;Keep(X:[]i64)<computes>:[]i64=X;Empty:[]i64=Iterate(Keep,4,array{});Echo(X:option(i64))<computes>:option(i64)=X;None:option(i64)=Iterate(Echo,3,option{})");
    try std.testing.expectEqual(@as(i64, 22), x.get("After").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Old").?.integer);
    try std.testing.expectEqualStrings("雪", x.elements(x.get("Final").?).?[1].string);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("Empty").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("None").?).?.len);
}

test "iteration failures restore writes from earlier visits across root and own catchers" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=7;Step(X:i64)<transacts><decides>:i64=Block{set C=C+1;Require[X<3];X+1};A:i64=Attempt(Iterate(Step,5,0),C);B:i64=C;Outer(X:i64)<transacts>:i64=Attempt(Block{R:i64=Iterate(Step,5,X);R},C);D:i64=Outer(0);E:i64=C;Safe(X:i64)<transacts>:i64=Attempt(Step[X],X+10);F:i64=Iterate(Safe,5,0);G:i64=C");
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 23), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("G").?.integer);
    try std.testing.expectEqual(@as(u32, 4), x.failure_count);
}

test "iteration composes nested helpers mutable locals and lazy zero dispatch" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Step(X:i64)<transacts>:i64=Block{var Y:i64=X;Set(Y,Iterate(Inc,2,Y));If(Y>5,Set(Y,Y+3),Set(Y,Y+1));Y};A:i64=Iterate(Step,3,0);Keep(X:i64)<computes>:i64=If(X==0,Iterate(Inc,0,X),Iterate(Inc,1,X));B:i64=Iterate(Keep,10,0)");
    try std.testing.expectEqual(@as(i64, 11), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("B").?.integer);
}

test "iteration rejects malformed signatures names contexts and unused effects" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F()<computes>:i64=1;A:i64=Iterate(F,2,0)", .code = .argument_count },
        .{ .source = "F(X:i64,Y:i64)<computes>:i64=X;A:i64=Iterate(F,2,0)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:logic=true;A:logic=Iterate(F,2,true)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,true,0)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,2,true)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,2)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,2,0,1)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F(),2,0)", .code = .argument_count },
        .{ .source = "A:i64=Iterate(Missing,0,0)", .code = .unknown_name },
        .{ .source = "F:i64=1;A:i64=Iterate(F,0,0)", .code = .not_callable },
        // RFC-0076 rule 1: a local or a parameter may not take the name of an earlier function.
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Block{F:i64=7;Iterate(F,0,0)}", .code = .shadowed_name },
        .{ .source = "F(X:i64)<computes>:i64=X;G(F:i64)<computes>:i64=Iterate(F,0,0)", .code = .shadowed_name },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Block{H:i64=7;Iterate(H,0,0)}", .code = .not_callable },
        .{ .source = "F(X:i64)<computes>:i64=X;G(H:i64)<computes>:i64=Iterate(H,0,0)", .code = .not_callable },
        .{ .source = "F(X:i64)<transacts>:i64=X;G(X:i64)<computes>:i64=Iterate(F,0,X);A:i64=1", .code = .call_requires_transacts },
        .{ .source = "F(X:i64)<computes><decides>:i64=X;A:i64=Iterate(F,0,0)", .code = .failure_context_required },
        .{ .source = "F(X:i64)<transacts>:i64=X;R:=struct{N:i64=Iterate(F,0,0)}", .code = .call_requires_transacts },
        .{ .source = "Iterate:i64=1", .code = .expected_name },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,,0)", .code = .expected_expression },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate(F,2,)", .code = .expected_expression },
    }) |c| {
        const r = h.front.compile(c.source);
        try std.testing.expect(r == .failed);
        if (r.failed.code != c.code) std.debug.print("iteration diagnostic {s}: {s}\n", .{ c.source, r.failed.message() });
        try std.testing.expectEqual(c.code, r.failed.code);
        _ = try h.execute("A:i64=42");
    }
    const x = try h.execute("F(X:i64)<computes>:i64=X+1;R:=struct{N:i64=Iterate(F,2,7)};Value:R=R{}");
    try std.testing.expectEqual(@as(i64, 9), x.elements(x.get("Value").?).?[0].integer);
}

test "iteration dispatch fuel is exact at every prefix and zero requires no frame" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Identity(X:i64)<computes>:i64=X;A:i64=Iterate(Identity,3,7)");
    for (0..9) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try h.run(p, 9)).ok.get("A").?.integer);
    const zero = try h.compile("Identity(X:i64)<computes>:i64=X;A:i64=Iterate(Identity,0,7)");
    for (0..3) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(zero, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(usize, 0), (try h.run(zero, 3)).ok.call_steps.len);
    const writes = try h.compile("var C:i64=1;F(X:i64)<transacts>:i64=Block{set C=C+1;X+1};A:i64=Iterate(F,4,0)");
    const full = (try h.run(writes, 1000)).ok;
    const exact: u32 = @intCast(full.values.len + full.call_steps.len + 4);
    for (0..exact) |fuel| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(writes, @intCast(fuel))).failed.code);
        try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    }
    try std.testing.expectEqual(@as(i64, 5), (try h.run(writes, exact)).ok.get("C").?.integer);
}

test "iteration admits exactly 8192 retained visits and reuses all frame registers" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 8192, 8193 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("Id(X:i64)<computes>:i64=X;Value:i64=Iterate(Id,{d},7)", .{count});
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (count == 8192) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.call_steps.len);
            try std.testing.expectEqual(@as(i64, 7), r.ok.get("Value").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
    }
    const span: types.Span = .{ .start = 0, .end = 1 };
    for (&h.body) |*entry| entry.* = .{ .node = .{ .span = span, .value_type = .i64, .kind = .{ .integer = 0 } }, .input = .{ .parameter = 0 } };
    h.metadata[0] = .{ .name = span, .parameter_count = 1, .value_type = .i64, .body = .{ .start = 0, .end = 8192 }, .root = 8191, .available_at = 0, .member_work = 0, .is_public = false };
    h.metadata[0].parameters[0] = .i64;
    h.front.nodes[0] = .{ .span = span, .value_type = .i64, .kind = .{ .integer = 1 } };
    h.front.nodes[1] = .{ .span = span, .value_type = .i64, .kind = .{ .integer = 7 } };
    h.front.nodes[2] = .{ .span = span, .value_type = .i64, .kind = .{ .iterate = .{ .function = 0, .count = 0, .initial = 1 } } };
    const p: types.Program = .{ .source = "F", .strings = "", .bindings = &.{}, .nodes = h.front.nodes[0..3], .functions = h.metadata[0..1], .function_nodes = &h.body, .control_ops = 1 };
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, 8195)).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try h.run(p, 8196)).ok.values[2].integer);
    // Earlier-ID bodies bound live registers by the 8192-node catalogue. A
    // repeated visit reuses the same prefix; its evidence budget is independent.
    h.front.nodes[0].kind.integer = 2;
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(p, 20000)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "iteration nesting consumes exactly 32 guest frames without native recursion" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F0(X:i64)<computes>:i64=X;");
    for (1..34) |id| try out.print("F{d}(X:i64)<computes>:i64=Iterate(F{d},1,X);", .{ id, id - 1 });
    const end = out.end;
    try out.writeAll("A:i64=Iterate(F31,2,7)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
    out.end = end;
    try out.writeAll("A:i64=Iterate(F32,1,7)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(try h.compile(out.buffered()), 10000)).failed.code);
    out.end = end;
    try out.writeAll("A:i64=Iterate(F32,0,7)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
}

test "iteration admits exactly 8192 physical members with immutable previous state" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 32, 33 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F(X:[]i64)<computes>:[]i64=Block{N:i64=X.Length;array{");
        for (0..256) |i| try out.print("{s}N", .{if (i == 0) "" else ","});
        try out.print("}}}};Seed:[]i64=array{{}};Value:[]i64=Iterate(F,{d},Seed);Size:i64=Value.Length;Old:i64=Seed.Length", .{count});
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (count == 32) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            try std.testing.expectEqual(@as(i64, 0), r.ok.get("Old").?.integer);
            try std.testing.expectEqual(@as(i64, 256), r.ok.get("Size").?.integer);
            for (r.ok.elements(r.ok.get("Value").?).?) |v| try std.testing.expectEqual(@as(i64, 256), v.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "iteration agrees with 1000 independent repeated branch and rollback state oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const seed = @as(i64, @intCast(i % 31)) - 15;
        const count = i % 19;
        var expected = seed;
        var cell: i64 = 5;
        var failures: u32 = 0;
        for (0..count) |_| {
            if (expected < 3) {
                cell += expected;
                expected += 2;
            } else {
                expected -= 7;
                failures += 1;
            }
        }
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=5;F(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);If(Require[X<3],X+2,X)}},X-7);A:i64=Iterate(F,{d},{d});B:i64=C", .{ count, seed });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

fn invalid(h: *Harness, p: types.Program) !void {
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 0).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 0).failed.code);
}

test "iteration independently admits unused effects metadata signatures earlier typed operands" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=1;F(X:i64)<transacts><decides>:i64=If(Require[X>0],Set(C,X),C);G(X:i64)<transacts>:i64=Attempt(Iterate(F,0,X),X);Value:i64=9");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    var loop: usize = 0;
    for (p.function_nodes, 0..) |entry, i| if (entry.node.kind == .iterate) {
        loop = i;
    };
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (i % 8) {
            0 => h.metadata[1].transacts = false,
            1 => h.metadata[1].has_control = false,
            2 => h.metadata[1].has_failure = false,
            3 => h.metadata[1].control_ops -= 1,
            4 => h.body[loop].node.kind.iterate.function = 1,
            5 => h.body[loop].node.kind.iterate.initial = 8192,
            6 => h.body[loop].node.kind.iterate.count = 8192,
            7 => h.metadata[0].parameter_count = 0,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    const aggregate = try h.compile("F(X:[]i64)<computes>:[]i64=array{X.Length};G(X:[]i64)<computes>:[]i64=Iterate(F,0,X);A:i64=1");
    try std.testing.expectEqual(@as(u32, 8193), aggregate.functions[1].member_work);
    @memcpy(h.metadata[0..aggregate.functions.len], aggregate.functions);
    forged = aggregate;
    forged.functions = h.metadata[0..aggregate.functions.len];
    h.metadata[1].member_work = 0;
    try invalid(h, forged);
    const root = try h.compile("F(X:i64)<computes>:i64=X;A:i64=If(false,Iterate(F,1,7),2)");
    // A statically well-typed second-arm read of a first-arm initial is unavailable.
    var nodes = try std.testing.allocator.dupe(types.Node, root.nodes);
    defer std.testing.allocator.free(nodes);
    var count_index: u32 = 0;
    for (nodes) |node| if (node.kind == .iterate) {
        count_index = node.kind.iterate.count;
    };
    nodes[nodes.len - 2].kind = .{ .local_set = count_index };
    forged = root;
    forged.nodes = nodes;
    try invalid(h, forged);
}

test "iteration replay rejects 1000 altered seeds counts ordered visits and return copies before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(X:i64)<computes>:i64=X+2;A:i64=Iterate(F,5,3)");
    var forged = x;
    forged.call_steps = h.steps[0..x.call_steps.len];
    var output: [512]u8 = undefined;
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (i % 4) {
            0 => h.steps[3].value = .{ .integer = 999 }, // Second visit seed.
            1 => h.steps[3].pc = 1,
            2 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            3 => h.steps[6].function = 1,
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    @memcpy(h.values[0..x.values.len], x.values);
    forged = x;
    forged.values = h.values[0..x.values.len];
    for (x.program.nodes, 0..) |node, i| if (node.kind == .iterate) {
        h.values[i] = .{ .integer = 999 };
    };
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const exact = try reporting.validate(x, false, .{});
    out = .fixed(&output);
    _ = try reporting.write(&out, x, false, .{ .work = exact.work, .output_bytes = exact.output_bytes });
    out = .fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = exact.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    out = .fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .output_bytes = exact.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "iteration retains every value kind repeated failures truncated origins and fatal reuse" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\mode:=enum{One,Two};row:=struct{Name:string,Size:i64}
        \\all:=struct{R:row,A:[]i64,M:map(string,i64),O:option(i64),T:tuple(i64,string),E:mode,B:logic,S:string,Z:float,N:float}
        \\F(X:all)<computes>:all=Attempt(Block{Fail["keep"];X},X)
        \\Seed:all=all{R:=row{Name:="雪",Size:=1},A:=array{1},M:=map{"雪"=>1},O:=option{},T:=tuple{1,"雪"},E:=mode.Two,B:=true,S:="雪",Z:=-0.0,N:=NaN}
        \\Value:all=Iterate(F,100,Seed)
    );
    try equal(x.get("Seed").?, x.get("Value").?);
    const fields = x.elements(x.get("Value").?).?;
    try std.testing.expectEqualStrings("雪", fields[7].string);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(fields[8].floating)));
    try std.testing.expect(std.math.isNan(fields[9].floating));
    try std.testing.expectEqual(@as(u32, 100), x.failure_count);
    try std.testing.expectEqual(@as(usize, 32), x.failures.len);
    var buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, x, "repeat.forb", .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"truncated\":true") != null);
    const fatal = try h.compile("var C:i64=1;F(X:i64)<transacts>:i64=Block{Set(C,C+1);If(X==2,1/0,X+1)};A:i64=Iterate(F,4,0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(fatal, 1000)).failed.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    _ = try h.execute("A:i64=42");
}

test "iteration admits imported public alias helpers namespaces and inspection sixteen unused bodies" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Value:S.Row=Iterate(S.Keep,3,S.Row{Name:=\"雪\",Size:=9})" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};Keep<public>(X:Row)<computes>:Row=X;Hidden(X:i64)<computes>:i64=X" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok;
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 9), x.elements(x.get("Value").?).?[1].integer);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};Value:i64=Iterate(S.Hidden,0,1)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    const unused = try h.compile("F(X:i64)<computes>:i64=X;G(X:i64)<computes>:i64=Iterate(F,0,X);A:i64=9");
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    scratch.initialise(inspector);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.write(&out, unused)));
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 16), json.value.object.get("format").?.integer);
    const exact = out.end;
    out = .fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.writeBounded(&out, unused, .{ .output_bytes = exact })));
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try inspector.writeBounded(&out, unused, .{ .output_bytes = exact - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
