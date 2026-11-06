//! State loop termination, snapshot, quota, rollback and independent replay oracles.
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
                std.debug.print("state loop compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("state loop run {s}\n", .{r.failed.message()});
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

fn invalid(h: *Harness, p: types.Program) !void {
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 0).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 0).failed.code);
}

test "state loop terminates on None and preserves the last immutable seed" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Advance(N:i64)<computes>:option(i64)=If(N<42,option{N+1},option{});Run(H:function(tuple(i64),option(i64)),N:i64)<computes>:i64=Loop(H,N);Box:=struct{F:function(tuple(i64),option(i64))=Advance};Make()<computes>:Box=Box{};A:i64=Loop(Advance,39);B:i64=Loop(Advance,42);C:i64=Run(Make().F,39);D:i64=Block{Stepper:function(tuple(i64),option(i64))=Make().F;Loop(Stepper,41)}");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    var visits: usize = 0;
    for (x.call_steps) |event| if (event.function == 0 and event.pc == 0) {
        visits += 1;
    };
    try std.testing.expectEqual(@as(usize, 11), visits);
}

test "state loop snapshots strict target before seed and commits terminating writes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Double(X:i64)<transacts>:option(i64)=If(X<42,option{X*2},option{});var Target:function<transacts>(tuple(i64),option(i64))=Double;var Order:i64=0;Step(X:i64)<transacts>:option(i64)=Block{set Target=Double;set Order=Order+1;If(X<42,option{X+1},option{})};set Target=Step;Pick()<transacts>:function<transacts>(tuple(i64),option(i64))=Block{set Order=Order*10+1;Target};Seed()<transacts>:i64=Block{set Order=Order*10+2;set Target=Double;40};A:i64=Loop(Pick(),Seed());B:i64=Order;C:i64=Loop(Target,21);D:i64=Order");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 15), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 15), x.get("D").?.integer);
    const y = try h.execute("var C:i64=0;Stop(X:i64)<transacts>:option(i64)=Block{set C=C+1;option{}};A:i64=Loop(Stop,42);B:i64=C");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), y.get("B").?.integer);
    for ([_][]const u8{
        "Stop(X:i64)<computes>:option(i64)=option{};A:i64=Loop(Stop,1/0)",
        "Bad()<computes>:function(tuple(i64),option(i64))=Block{N:i64=1/0;Bad()};A:i64=Loop(Bad(),1/0)",
    }) |source| {
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(try h.compile(source), 1000)).failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "state loop self recursion counted iteration and exact frame bounds compose" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 31, 32 }) |n| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(N:i64)<computes>:option(i64)=If(N==0,option{{}},option{{Loop(F,N-1)}});A:i64=Loop(F,{d})", .{n});
        const r = try h.run(try h.compile(out.buffered()), 10000);
        if (n == 31) try std.testing.expectEqual(@as(i64, 0), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    const x = try h.execute("Inc(N:i64)<computes>:i64=N+1;Step(N:i64)<computes>:option(i64)=If(N<42,option{Iterate(Inc,2,N)},option{});Run(F:function(tuple(i64),option(i64)),N:i64)<computes>:i64=Loop(F,N);A:i64=Run(Step,38)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
}

test "state loop preserves contextual empty scalar callable and aggregate states" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Mode:=enum{One,Two};KF(X:float)<computes>:option(float)=option{};KS(X:string)<computes>:option(string)=option{};KL(X:logic)<computes>:option(logic)=option{};KE(X:Mode)<computes>:option(Mode)=option{};KA(X:[]i64)<computes>:option([]i64)=option{};KO(X:option(i64))<computes>:option(option(i64))=option{};KM(X:map(string,i64))<computes>:option(map(string,i64))=option{};KT(X:tuple(i64,string))<computes>:option(tuple(i64,string))=option{};Inc(X:i64)<computes>:i64=X+1;KC(X:function(tuple(i64),i64))<computes>:option(function(tuple(i64),i64))=option{};R:=struct{N:i64,T:string};KR(X:R)<computes>:option(R)=If(X.N<22,option{R{N:=X.N+1,T:=X.T}},option{});Seed:R=R{N:=2,T:=\"雪\"};V:R=Loop(KR,Seed);Old:i64=Seed.N;N:i64=V.N;Text:string=V.T;Nan:float=Loop(KF,NaN);Zero:float=Loop(KF,-0.0);S:string=Loop(KS,\"雪\");L:logic=Loop(KL,true);E:Mode=Loop(KE,Mode.Two);A:[]i64=Loop(KA,array{});O:option(i64)=Loop(KO,option{});M:map(string,i64)=Loop(KM,map{});T:tuple(i64,string)=Loop(KT,tuple{42,\"雪\"});C:function(tuple(i64),i64)=Loop(KC,Inc);Answer:i64=C(41)");
    try std.testing.expectEqual(@as(i64, 22), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Old").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("Text").?.string);
    try std.testing.expectEqualStrings("雪", x.get("S").?.string);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expect(std.math.isNan(x.get("Nan").?.floating));
    try std.testing.expect(x.get("L").?.boolean);
    try std.testing.expectEqual(@as(u32, 1), x.get("E").?.enumeration.index);
    for ([_][]const u8{ "A", "O", "M" }) |name| try std.testing.expectEqual(@as(usize, 0), x.elements(x.get(name).?).?.len);
    try std.testing.expectEqual(@as(i64, 42), x.elements(x.get("T").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("Answer").?.integer);
}

test "state loop propagated failure restores all visits and mutable local versions" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=7;Step(X:i64)<transacts><decides>:option(i64)=Block{set C=C+1;Require[X<3];option{X+1}};F:function<transacts><decides>(tuple(i64),option(i64))=Step;A:i64=Attempt(Loop(F,0),C);B:i64=C;Outer(G:function<transacts><decides>(tuple(i64),option(i64)),X:i64)<transacts>:i64=Attempt(Loop(G,X),C);D:i64=Outer(F,0);E:i64=C;Safe(X:i64)<transacts>:option(i64)=Attempt(Step[X],option{});H:i64=Loop(Safe,0);I:i64=C");
    for ([_][]const u8{ "A", "B", "D", "E" }) |name| try std.testing.expectEqual(@as(i64, 7), x.get(name).?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("I").?.integer);
    try std.testing.expectEqual(@as(u32, 3), x.failure_count);
    const y = try h.execute("Stop(X:i64)<computes>:option(i64)=option{};Run(X:i64)<transacts>:i64=Block{var N:i64=42;A:i64=Attempt(Block{set N=7;Loop(Stop,N);Fail[\"restore\"]},Loop(Stop,N));A};V:i64=Run(0)");
    try std.testing.expectEqual(@as(i64, 42), y.get("V").?.integer);
}

test "state loop rejects wrong signatures arity and unused effect contexts" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Loop(F,0)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:option(string)=option{};A:i64=Loop(F,0)", .code = .type_mismatch },
        .{ .source = "F()<computes>:option(i64)=option{};A:i64=Loop(F,0)", .code = .argument_count },
        .{ .source = "F(X:i64,Y:i64)<computes>:option(i64)=option{};A:i64=Loop(F,0)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:option(i64)=option{};A:i64=Loop(F,\"bad\")", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:option(i64)=option{};A:i64=Loop(F)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:option(i64)=option{};A:i64=Loop(F,0,1)", .code = .argument_count },
        .{ .source = "A:i64=Loop(7,0)", .code = .not_callable },
        .{ .source = "F(X:i64)<transacts>:option(i64)=option{};G(X:i64)<computes>:i64=Loop(F,X);A:i64=1", .code = .call_requires_transacts },
        .{ .source = "F(X:i64)<computes><decides>:option(i64)=option{};G(X:i64)<computes>:i64=Loop(F,X);A:i64=1", .code = .failure_context_required },
        .{ .source = "F(X:i64)<transacts>:option(i64)=option{};R:=struct{N:i64=Loop(F,0)}", .code = .call_requires_transacts },
        .{ .source = "F(X:i64)<computes>:option(i64)=option{};A:i64=Loop(F,)", .code = .expected_expression },
    }) |c| {
        const r = h.front.compile(c.source);
        if (r == .ok) return error.UnexpectedAdmission;
        if (r.failed.code != c.code) std.debug.print("loop diagnostic {s}: {s}\n", .{ c.source, r.failed.message() });
        try std.testing.expectEqual(c.code, r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "state loop agrees with 1000 independent progress selection and rollback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const seed = @as(i64, @intCast(i % 31)) - 15;
        const limit = @as(i64, @intCast(i % 19));
        const selected = i % 2 == 0;
        const whole_catch = i % 3 == 0;
        var expected = seed;
        var cell: i64 = 5;
        var failures: u32 = 0;
        while (expected < limit) {
            if (expected >= 3) {
                failures = 1;
                if (whole_catch) {
                    expected = seed;
                    cell = 5;
                }
                break;
            }
            cell += expected;
            expected += if (selected) 2 else 1;
        }
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=5;F(X:i64)<transacts><decides>:option(i64)=If(X>={d},option{{}},Block{{Set(C,C+X);Require[X<3];option{{X+2}}}});G(X:i64)<transacts><decides>:option(i64)=If(X>={d},option{{}},Block{{Set(C,C+X);Require[X<3];option{{X+1}}}});SafeF(X:i64)<transacts>:option(i64)=Attempt(F[X],option{{}});SafeG(X:i64)<transacts>:option(i64)=Attempt(G[X],option{{}});A:i64=", .{ limit, limit });
        if (whole_catch) try out.print("Attempt(Loop(If({s},F,G),{d}),{d})", .{ if (selected) "true" else "false", seed, seed }) else try out.print("Loop(If({s},SafeF,SafeG),{d})", .{ if (selected) "true" else "false", seed });
        try out.writeAll(";B:i64=C");
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

test "state loop exact dispatch fuel member bounds and nontermination permit fatal reuse" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<computes>:option(i64)=If(N<42,option{N+1},option{});A:i64=Loop(F,39)");
    const x = (try h.run(p, 1000)).ok;
    const fuel: u64 = @intCast(p.nodes.len + x.call_steps.len + x.aggregate_values.len + 4);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(p, fuel)).ok.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, fuel - 1)).failed.code);
    const infinite = try h.compile("var C:i64=0;F(X:i64)<transacts>:option(i64)=Block{set C=C+1;option{X}};A:i64=Loop(F,0)");
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(infinite, 100)).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(infinite, 131072)).failed.code);
    for ([_]usize{ 32, 33 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=0;F(X:[]i64)<transacts>:option([]i64)=If(C=={d},option{{}},Block{{set C=C+1;N:i64=C;option{{array{{", .{count});
        for (0..255) |i| try out.print("{s}N", .{if (i == 0) "" else ","});
        try out.writeAll("}}});A:[]i64=Loop(F,array{});Size:i64=A.Length;Writes:i64=C");
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (count == 32) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            try std.testing.expectEqual(@as(i64, 255), r.ok.get("Size").?.integer);
            try std.testing.expectEqual(@as(i64, 32), r.ok.get("Writes").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "state loop independently rejects 2000 unused signature metadata and operand forgeries" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:i64)<transacts><decides>:option(i64)=option{};G(H:function<transacts><decides>(tuple(i64),option(i64)),X:i64)<transacts>:i64=Attempt(Loop(H,X),X);A:i64=1");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    const owner = p.functions.len - 1;
    var loop: usize = 0;
    for (p.function_nodes, 0..) |entry, i| if (entry.node.kind == .loop) {
        loop = i;
    };
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (i % 10) {
            0 => h.metadata[owner].transacts = false,
            1 => h.metadata[owner].has_control = false,
            2 => h.metadata[owner].has_failure = false,
            3 => h.metadata[owner].control_ops -= 1,
            4 => h.metadata[owner].has_source = false,
            5 => h.metadata[owner].has_local = false,
            6 => h.metadata[owner].member_work = 0,
            7 => h.body[loop].node.kind.loop.callable = 8192,
            8 => h.body[loop].node.kind.loop.initial = 8192,
            9 => h.body[loop].node.value_type = .string,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    const root = try h.compile("F(X:i64)<computes>:option(i64)=option{};A:i64=If(false,Loop(F,7),2)");
    const nodes = try std.testing.allocator.dupe(types.Node, root.nodes);
    defer std.testing.allocator.free(nodes);
    var transition: types.StateLoop = undefined;
    for (nodes) |node| if (node.kind == .loop) {
        transition = node.kind.loop;
    };
    nodes[nodes.len - 2].kind = .{ .loop = transition };
    forged = root;
    forged.nodes = nodes;
    forged.control_ops += 1;
    try invalid(h, forged);
}

test "state loop replay rejects 1000 altered Some None seeds targets and schedules before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(X:i64)<computes>:option(i64)=If(X<42,option{X+1},option{});Other(X:i64)<computes>:option(i64)=option{};A:i64=Loop(F,39)");
    var forged = x;
    var output: [512]u8 = undefined;
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        @memcpy(h.values[0..x.values.len], x.values);
        @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
        forged.call_steps = h.steps[0..x.call_steps.len];
        forged.values = h.values[0..x.values.len];
        forged.aggregate_values = h.members[0..x.aggregate_values.len];
        switch (i % 6) {
            0 => h.steps[0].value = .{ .integer = 999 },
            1 => h.steps[1].pc = 0,
            2 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            3 => h.steps[0].function = 1,
            4 => h.members[0].integer += 1,
            5 => for (x.program.nodes) |node| {
                if (node.kind == .loop) h.values[node.kind.loop.callable].callable.function = 1;
            },
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    forged = x;
    forged.call_steps = h.steps[0..x.call_steps.len];
    for (h.steps[0..x.call_steps.len]) |*event| if (event.value == .aggregate) {
        event.value.aggregate.elements.end = 8193;
        break;
    };
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "state loop reserves exactly 8192 repeated body live registers" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "F(N:i64)<computes>:option(i64)=If(true,If(N==0,option{},option{Loop(F,N-1)}),Block{";
    const tail = "option{}});";
    const base = try h.compile(prefix ++ tail ++ "A:i64=Loop(F,15)");
    const length = base.functions[0].body.end - base.functions[0].body.start;
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    for (0..512 - length) |_| try out.writeAll("0;");
    try out.writeAll(tail);
    const end = out.end;
    try out.writeAll("A:i64=Loop(F,15)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(@as(u32, 512), p.functions[0].body.end - p.functions[0].body.start);
    try std.testing.expectEqual(@as(i64, 0), (try h.run(p, 32768)).ok.get("A").?.integer);
    out.end = end;
    try out.writeAll("A:i64=Loop(F,16)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_register_limit, (try h.run(try h.compile(out.buffered()), 32768)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "state loop exactly fills 8192 evidence events then rejects an extra terminating visit" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "Step(N:i64)<computes>:option(i64)=If(N<700,option{N+1},option{});Stop(N:i64)<computes>:option(i64)=option{};V:function(tuple(i64),option(i64))=Stop;Z:i64=0;A:i64=Loop(Step,Z);";
    const first = try h.execute(prefix);
    const padding = types.limits.call_steps - first.call_steps.len;
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    try out.writeAll("P:i64=Block{");
    for (0..padding) |_| try out.writeAll("Loop(V,Z);");
    const end = out.end;
    try out.writeAll("Z}");
    const full = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(usize, 8192), full.call_steps.len);
    try std.testing.expectEqual(@as(i64, 700), full.get("A").?.integer);
    out.end = end;
    try out.writeAll("Loop(V,Z);Z}");
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(try h.compile(out.buffered()), 131072)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "state loop unused inspection20 and zero cell source regions have exact admission" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:function(tuple(i64),option(i64)),N:i64)<computes>:i64=Loop(X,N);A:i64=1");
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect(try report.write(&out, p) == .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"loop\"") != null);
    const size = out.end;
    out.end = 0;
    try std.testing.expect(try report.writeBounded(&out, p, .{ .output_bytes = size }) == .ok);
    out.end = 0;
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try report.writeBounded(&out, p, .{ .output_bytes = size - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const source = try h.compile("F(X:i64)<transacts>:option(i64)=option{};A:i64=Loop(F,42)");
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithRuntimeStorage(source, &h.values, &h.members, &h.control, null, &h.frames, 100).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(source, 100)).ok.get("A").?.integer);
    const prefix = "F(X:i64)<transacts>:option(i64)=option{};G(H:function<transacts>(tuple(i64),option(i64)),X:i64)<transacts>:i64=Attempt(Loop(H,X),0);A:i64=";
    for ([_]usize{ 31, 32 }) |depth| {
        out = .fixed(&h.text);
        try out.writeAll(prefix);
        for (0..depth) |_| try out.writeAll("Attempt(");
        try out.writeAll("G(F,42)");
        for (0..depth) |_| try out.writeAll(",0)");
        const r = try h.run(try h.compile(out.buffered()), 1000);
        if (depth == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, r.failed.code);
    }
}

test "state loop imported steps defaults and nominal privacy retain definition owners" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};F:function(tuple(i64),option(i64))=S.Step;A:i64=Loop(F,40);B:i64=Loop(S.Step,41);R:=struct{N:i64=Loop(S.Step,39)};V:R=R{};N:i64=V.N" },
        .{ .path = "雪.forb", .source = "Step<public>(N:i64)<computes>:option(i64)=If(N<42,option{N+1},option{});Hidden(N:i64)<computes>:option(i64)=option{}" },
    };
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok, 1000)).ok;
    for ([_][]const u8{ "A", "B", "N" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"module\":\"雪.forb\"") != null);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};A:i64=Loop(S.Hidden,0)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    private[0].source = "S:=import{\"雪.forb\"};A:i64=9";
    private[1].source = "Hidden:=struct{N:i64};F<public>(X:function(tuple(Hidden),option(Hidden)),Y:Hidden)<computes>:Hidden=Loop(X,Y)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
}

test "state loop exact report budgets and empty source nesting reject forged successful evidence" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(X:i64)<computes>:option(i64)=If(X<42,option{X+1},option{});A:i64=Loop(F,40)");
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const admitted = try reporting.write(&writer, x, false, .{});
    writer.end = 0;
    _ = try reporting.write(&writer, x, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    writer.end = 0;
    try std.testing.expectError(error.ReportLimit, reporting.write(&writer, x, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&writer, x, false, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
    const prefix = "F(X:i64)<transacts>:option(i64)=option{};G(H:function<transacts>(tuple(i64),option(i64)),X:i64)<transacts>:i64=Attempt(Loop(H,X),0);A:i64=";
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    for (0..31) |_| try out.writeAll("Attempt(");
    try out.writeAll("G(F,42)");
    for (0..31) |_| try out.writeAll(",0)");
    const good = try h.execute(out.buffered());
    const steps = good.call_steps.len;
    @memcpy(h.steps[0..steps], good.call_steps);
    out = .fixed(&h.text);
    try out.writeAll(prefix);
    for (0..32) |_| try out.writeAll("Attempt(");
    try out.writeAll("G(F,42)");
    for (0..32) |_| try out.writeAll(",0)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, (try h.run(p, 1000)).failed.code);
    for (p.nodes, 0..) |node, i| {
        h.values[i] = switch (node.value_type) {
            .i64 => .{ .integer = if (node.kind == .integer) node.kind.integer else 42 },
            .logic => .{ .boolean = true },
            else => .{ .callable = .{ .value_type = node.value_type, .function = node.kind.function_value } },
        };
        h.control.activity[i] = node.kind != .otherwise and !(node.kind == .integer and node.kind.integer == 0);
    }
    const forged: evaluator.Execution = .{ .program = p, .values = h.values[0..p.nodes.len], .activity = h.control.activity[0..p.nodes.len], .call_steps = h.steps[0..steps] };
    writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&writer, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}
