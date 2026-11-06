//! Callable iteration signature, snapshot, quota, rollback and independent replay oracles.
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
                std.debug.print("callable iteration compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("callable iteration run {s}\n", .{r.failed.message()});
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

test "callable iteration accepts parameters selected returned aggregate and alias steps" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Double(X:i64)<computes>:i64=X*2;Keep(X:i64)<computes>:i64=X;Run(F:function(tuple(i64),i64),N:i64,X:i64)<computes>:i64=Iterate(F,N,X);Choose(B:logic)<computes>:function(tuple(i64),i64)=If(B,Inc,Double);Box:=struct{F:function(tuple(i64),i64)=Inc};Make()<computes>:Box=Box{};B:Box=Make();V:function(tuple(i64),i64)=Keep;A:i64=Run(Inc,5,37);C:i64=Iterate(Choose(false),1,21);D:i64=Iterate(B.F,7,35);E:i64=Iterate(If(true,Inc,Double),2,40);F:i64=Iterate(V,5,42);G:i64=Iterate(Keep,5,42);H:i64=Block{Alt:function(tuple(i64),i64)=Double;Iterate(Alt,1,21)};I:i64=Iterate((Double),1,21)");
    for ([_][]const u8{ "A", "C", "D", "E", "F", "G", "H", "I" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expectEqual(@as(usize, 6), x.program.functions.len);
    var dynamic: usize = 0;
    for (x.program.nodes) |node| if (node.kind == .iterate_value) {
        dynamic += 1;
    };
    try std.testing.expectEqual(@as(usize, 6), dynamic);
    try std.testing.expect(h.front.functions.definitions[2].runtime == null and h.front.functions.definitions[2].alias_runtime != null);
}

test "callable iteration snapshots step before count seed and target-changing visits" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Double(X:i64)<computes>:i64=X*2;var Target:function(tuple(i64),i64)=Inc;var Order:i64=0;Pick()<transacts>:function(tuple(i64),i64)=Block{set Order=Order*10+1;Target};Count()<transacts>:i64=Block{set Order=Order*10+2;set Target=Double;2};Seed()<transacts>:i64=Block{set Order=Order*10+3;40};A:i64=Iterate(Pick(),Count(),Seed());B:i64=Order;C:i64=Iterate(Target,1,21)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 123), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("C").?.integer);
    const y = try h.execute("Double(X:i64)<transacts>:i64=X*2;var Target:function<transacts>(tuple(i64),i64)=Double;Change(X:i64)<transacts>:i64=Block{set Target=Double;X+1};set Target=Change;A:i64=Iterate(Target,3,39);B:i64=Iterate(Target,1,21)");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), y.get("B").?.integer);
}

test "callable iteration zero negative huge counts retain strict operand effects and cleanup" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=0;Step(X:i64)<transacts>:i64=Block{set C=C+100;X+1};Pick()<transacts>:function<transacts>(tuple(i64),i64)=Block{set C=C+1;Step};A:i64=Iterate(Pick(),Set(C,C+1)-2,Set(C,C+40));B:i64=C");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    try std.testing.expect(x.call_steps.len != 0); // Pick executes; Step does not.
    for ([_]struct { count: []const u8, seed: []const u8, code: types.Diagnostic.Code }{
        .{ .count = "-1", .seed = "7", .code = .negative_iteration_count },
        .{ .count = "-1", .seed = "1/0", .code = .division_by_zero },
        .{ .count = "0", .seed = "1/0", .code = .division_by_zero },
        .{ .count = "1/0", .seed = "1", .code = .division_by_zero },
        .{ .count = "9223372036854775807", .seed = "7", .code = .work_limit },
    }) |c| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("Step(X:i64)<computes>:i64=X;F:function(tuple(i64),i64)=Step;A:i64=Iterate(F,{s},{s})", .{ c.count, c.seed });
        try std.testing.expectEqual(c.code, (try h.run(try h.compile(out.buffered()), 100)).failed.code);
        _ = try h.execute("A:i64=42");
    }
    const before_count = try h.compile("Bad()<computes>:function(tuple(i64),i64)=Block{X:i64=1/0;Bad()};A:i64=Iterate(Bad(),1/0,0)");
    const r = try h.run(before_count, 1000);
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, r.failed.code);
    try std.testing.expectEqual(@as(u32, 54), r.failed.span.start);
}

test "callable iteration self steps compose nested frames and exact 32 frame bound" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const zero = try h.execute("F(X:i64)<computes>:i64=Iterate(F,0,X);A:i64=F(42)");
    try std.testing.expectEqual(@as(i64, 42), zero.get("A").?.integer);
    for ([_]usize{ 31, 32 }) |n| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(X:i64)<computes>:i64=If(X==0,42,Iterate(F,1,X-1));A:i64=F({d})", .{n});
        const r = try h.run(try h.compile(out.buffered()), 10000);
        if (n == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Nest(F:function(tuple(i64),i64),X:i64)<computes>:i64=Iterate(F,2,X);Step(X:i64)<computes>:i64=Nest(Inc,X);A:i64=Iterate((Step),3,36)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
}

test "callable iteration preserves every immutable state kind contextual empties and lifetimes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Mode:=enum{One,Two};KF(X:float)<computes>:float=X;KS(X:string)<computes>:string=X;KL(X:logic)<computes>:logic=X;KE(X:Mode)<computes>:Mode=X;KA(X:[]i64)<computes>:[]i64=X;KO(X:option(i64))<computes>:option(i64)=X;KM(X:map(string,i64))<computes>:map(string,i64)=X;KT(X:tuple(i64,string))<computes>:tuple(i64,string)=X;Inc(X:i64)<computes>:i64=X+1;KC(X:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=X;R:=struct{N:i64,T:string};KR(X:R)<computes>:R=R{N:=X.N+1,T:=X.T};Seed:R=R{N:=2,T:=\"雪\"};V:R=Iterate((KR),20,Seed);Old:i64=Seed.N;N:i64=V.N;Text:string=V.T;Nan:float=Iterate((KF),2,NaN);Zero:float=Iterate((KF),2,-0.0);S:string=Iterate((KS),2,\"雪\");L:logic=Iterate((KL),2,true);E:Mode=Iterate((KE),2,Mode.Two);A:[]i64=Iterate((KA),2,array{});O:option(i64)=Iterate((KO),2,option{});M:map(string,i64)=Iterate((KM),2,map{});T:tuple(i64,string)=Iterate((KT),2,tuple{42,\"雪\"});C:function(tuple(i64),i64)=Iterate((KC),2,Inc);Answer:i64=C(41)");
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

test "callable iteration failure rolls back earlier visits and local callable versions" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=7;Step(X:i64)<transacts><decides>:i64=Block{set C=C+1;Require[X<3];X+1};F:function<transacts><decides>(tuple(i64),i64)=Step;A:i64=Attempt(Iterate(F,5,0),C);B:i64=C;Outer(G:function<transacts><decides>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(Iterate(G,5,X),C);D:i64=Outer(F,0);E:i64=C;Safe(X:i64)<transacts>:i64=Attempt(Step[X],X+10);G:function<transacts>(tuple(i64),i64)=Safe;H:i64=Iterate(G,5,0);I:i64=C");
    for ([_][]const u8{ "A", "B", "D", "E" }) |name| try std.testing.expectEqual(@as(i64, 7), x.get(name).?.integer);
    try std.testing.expectEqual(@as(i64, 23), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("I").?.integer);
    try std.testing.expectEqual(@as(u32, 4), x.failure_count);
    const y = try h.execute("Inc(X:i64)<computes>:i64=X+1;Double(X:i64)<computes>:i64=X*2;Run(X:i64)<transacts>:i64=Block{var F:function(tuple(i64),i64)=Inc;A:i64=Attempt(Block{set F=Double;Iterate(F,2,21);Fail[\"restore\"]},Iterate(F,1,41));A};V:i64=Run(0)");
    try std.testing.expectEqual(@as(i64, 42), y.get("V").?.integer);
}

test "callable iteration rejects invalid dynamic shape effect arity and unused context" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),true,0)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),2,true)", .code = .type_mismatch },
        .{ .source = "F()<computes>:i64=1;A:i64=Iterate((F),0,0)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:logic=true;A:logic=Iterate((F),0,true)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),2)", .code = .argument_count },
        .{ .source = "A:i64=Iterate(7,0,0)", .code = .not_callable },
        .{ .source = "F(X:i64)<transacts>:i64=X;G(X:i64)<computes>:i64=Iterate((F),0,X);A:i64=1", .code = .call_requires_transacts },
        .{ .source = "F(X:i64)<computes><decides>:i64=X;G(X:i64)<computes>:i64=Iterate((F),0,X);A:i64=1", .code = .failure_context_required },
        .{ .source = "F(X:i64)<transacts>:i64=X;R:=struct{N:i64=Iterate((F),0,0)}", .code = .call_requires_transacts },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),2,0,1)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),,0)", .code = .expected_expression },
        .{ .source = "F(X:i64)<computes>:i64=X;A:i64=Iterate((F),0,)", .code = .expected_expression },
    }) |c| {
        const r = h.front.compile(c.source);
        if (r == .ok) return error.UnexpectedAdmission;
        if (r.failed.code != c.code) std.debug.print("dynamic iteration diagnostic {s}: {s}\n", .{ c.source, r.failed.message() });
        try std.testing.expectEqual(c.code, r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "callable iteration agrees with 1000 independent target selection rollback state oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const seed = @as(i64, @intCast(i % 31)) - 15;
        const count = i % 19;
        const selected = i % 2 == 0;
        var expected = seed;
        var cell: i64 = 5;
        var failures: u32 = 0;
        for (0..count) |_| {
            if (expected < 3) {
                cell += expected;
                expected += if (selected) 2 else 1;
            } else {
                expected -= if (selected) 7 else 5;
                failures += 1;
            }
        }
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=5;F(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);Require[X<3];X+2}},X-7);G(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);Require[X<3];X+1}},X-5);A:i64=Iterate(If({s},F,G),{d},{d});B:i64=C", .{ if (selected) "true" else "false", count, seed });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

test "callable iteration exact trace fuel and physical member boundaries permit fatal reuse" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 0, 8192, 8193 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("Keep(X:i64)<computes>:i64=X;F:function(tuple(i64),i64)=Keep;A:i64=Iterate(F,{d},42)", .{count});
        const p = try h.compile(out.buffered());
        const fuel: u64 = @intCast(p.nodes.len + count * 2);
        if (count <= 8192) {
            const x = (try h.run(p, fuel)).ok;
            try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
            try std.testing.expectEqual(count, x.call_steps.len);
            if (fuel != 0) try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, fuel - 1)).failed.code);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(p, 65536)).failed.code);
    }
    for ([_]usize{ 32, 33 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F(X:[]i64)<computes>:[]i64=Block{N:i64=X.Length;array{");
        for (0..256) |i| try out.print("{s}N", .{if (i == 0) "" else ","});
        try out.print("}}}};V:function(tuple([]i64),[]i64)=F;A:[]i64=Iterate(V,{d},array{{}});Size:i64=A.Length", .{count});
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (count == 32) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            try std.testing.expectEqual(@as(i64, 256), r.ok.get("Size").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "callable iteration independently rejects 2000 unused metadata operands and effect forgeries" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:i64)<transacts><decides>:i64=X;G(H:function<transacts><decides>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(Iterate(H,0,X),X);A:i64=1");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    const owner = p.functions.len - 1;
    var loop: usize = 0;
    for (p.function_nodes, 0..) |entry, i| if (entry.node.kind == .iterate_value) {
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
            7 => h.body[loop].node.kind.iterate_value.callable = 8192,
            8 => h.body[loop].node.kind.iterate_value.count = 8192,
            9 => h.body[loop].node.kind.iterate_value.initial = 8192,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    const root = try h.compile("F(X:i64)<computes>:i64=X;A:i64=If(false,Iterate((F),1,7),2)");
    const nodes = try std.testing.allocator.dupe(types.Node, root.nodes);
    defer std.testing.allocator.free(nodes);
    var iteration: types.CallableIteration = undefined;
    for (nodes) |node| if (node.kind == .iterate_value) {
        iteration = node.kind.iterate_value;
    };
    nodes[nodes.len - 2].kind = .{ .iterate_value = iteration };
    forged = root;
    forged.nodes = nodes;
    forged.control_ops += 1;
    try invalid(h, forged);
}

test "callable iteration replay rejects altered targets visit seeds order and returns before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(X:i64)<computes>:i64=X+2;Other(X:i64)<computes>:i64=X+3;V:function(tuple(i64),i64)=F;A:i64=Iterate(V,5,3)");
    var forged = x;
    var output: [512]u8 = undefined;
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (i % 4) {
            0 => h.steps[3].value = .{ .integer = 999 },
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
    for (x.program.nodes) |node| if (node.kind == .iterate_value) {
        h.values[node.kind.iterate_value.callable].callable.function = 1;
    };
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "callable iteration unused inspection19 exact output and zero-cell source admission" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:function(tuple(i64),i64),N:i64)<computes>:i64=Iterate(X,0,N);A:i64=1");
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect(try report.write(&out, p) == .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":19") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "iterate_value") != null);
    const size = out.end;
    out.end = 0;
    try std.testing.expect(try report.writeBounded(&out, p, .{ .output_bytes = size }) == .ok);
    out.end = 0;
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try report.writeBounded(&out, p, .{ .output_bytes = size - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const source = try h.compile("F(X:i64)<transacts>:i64=X;A:i64=Iterate((F),0,42)");
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithRuntimeStorage(source, &h.values, &h.members, &h.control, null, &h.frames, 100).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(source, 100)).ok.get("A").?.integer);
}

test "callable iteration reserves exactly 8192 repeated-body live registers" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "F(N:i64)<computes>:i64=Block{";
    const tail = "If(N==0,42,Iterate(F,1,N-1))};";
    const base = try h.compile(prefix ++ tail ++ "A:i64=F(15)");
    const length = base.functions[0].body.end - base.functions[0].body.start;
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    for (0..512 - length) |_| try out.writeAll("0;");
    try out.writeAll(tail);
    const end = out.end;
    try out.writeAll("A:i64=F(15)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(@as(u32, 512), p.functions[0].body.end - p.functions[0].body.start);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(p, 32768)).ok.get("A").?.integer);
    out.end = end;
    try out.writeAll("A:i64=F(16)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_register_limit, (try h.run(try h.compile(out.buffered()), 32768)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "callable iteration empty source regions count combined nesting and replay rejects forged success" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "F(X:i64)<transacts>:i64=X;G(H:function<transacts>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(Iterate(H,1,X),0);A:i64=";
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    for (0..31) |_| try out.writeAll("Attempt(");
    try out.writeAll("G(F,42)");
    for (0..31) |_| try out.writeAll(",0)");
    const good = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 42), good.get("A").?.integer);
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
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&writer, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "callable iteration imported steps record defaults and nominal privacy retain definition owners" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=S.Inc;A:i64=Iterate(F,2,40);B:i64=Iterate(S.Inc,1,41);R:=struct{N:i64=Iterate((S.Inc),2,40)};V:R=R{};N:i64=V.N" },
        .{ .path = "雪.forb", .source = "Inc<public>(N:i64)<computes>:i64=N+1;Hidden(N:i64)<computes>:i64=N" },
    };
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok, 1000)).ok;
    for ([_][]const u8{ "A", "B", "N" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"module\":\"雪.forb\"") != null);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};A:i64=Iterate((S.Hidden),0,0)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    private[0].source = "S:=import{\"雪.forb\"};A:i64=9";
    private[1].source = "Hidden:=struct{N:i64};F<public>(X:function(tuple(Hidden),Hidden),Y:Hidden)<computes>:Hidden=Iterate(X,0,Y)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
}
