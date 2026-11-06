//! Bound function captures, snapshot, quota, rollback and independent replay oracles.
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
                std.debug.print("bound function compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("bound function run {s}\n", .{r.failed.message()});
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

test "bound function captures bind ordered prefixes including nested and closed functions" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Add(A:i64,B:i64)<computes>:i64=A+B;Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;Plus:function(tuple(i64),i64)=Bind(Add,2);Closed:function(tuple(),i64)=Bind(Plus,40);Nested:function(tuple(i64),i64)=Bind(Bind(Sum,1),2);A:i64=Plus(40);B:i64=Closed();C:i64=Nested(39);D:i64=Bind(Add,20)(22)");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    const c = x.get("Closed").?.callable.captures;
    try std.testing.expectEqual(@as(u32, 2), c.end - c.start);
    try std.testing.expectEqual(@as(i64, 2), x.aggregate_values[c.start].integer);
    try std.testing.expectEqual(@as(i64, 40), x.aggregate_values[c.start + 1].integer);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&writer, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"captures\":[2,40]") != null);
}

test "bound function captures escape creating frames and snapshot mutable source and local values" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Add(A:i64,B:i64)<computes>:i64=A+B;Make(N:i64)<computes>:function(tuple(i64),i64)=Bind(Add,N);Box:=struct{F:function(tuple(i64),i64)};Build(N:i64)<computes>:Box=Box{F:=Make(N)};var Cell:i64=2;F:function(tuple(i64),i64)=Bind(Add,Cell);set Cell=100;B:Box=Build(2);Local()<transacts>:function(tuple(i64),i64)=Block{var N:i64=2;G:function(tuple(i64),i64)=Bind(Add,N);set N=100;G};A:i64=F(40);C:i64=B.F(40);D:i64=Local()(40)");
    for ([_][]const u8{ "A", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
}

test "bound function captures feed copied prefixes to counted and option state loops" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Add(Amount:i64,N:i64)<computes>:i64=N+Amount;Advance(Limit:i64,Amount:i64,N:i64)<computes>:option(i64)=If(N<Limit,option{N+Amount},option{});Step:function(tuple(i64),i64)=Bind(Add,2);Stop:function(tuple(i64),option(i64))=Bind(Bind(Advance,42),2);Run(F:function(tuple(i64),option(i64)),X:i64)<computes>:i64=Loop(F,X);A:i64=Iterate(Step,3,36);B:i64=Loop(Stop,38);C:i64=Run(Stop,38)");
    for ([_][]const u8{ "A", "B", "C" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
}

test "bound function captures strict callable then prefix order persists across nested binding" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;var Order:i64=0;Pick()<transacts>:function(tuple(i64,i64,i64),i64)=Block{set Order=Order*10+1;Sum};First()<transacts>:i64=Block{set Order=Order*10+2;1};Second()<transacts>:i64=Block{set Order=Order*10+3;2};F:function(tuple(i64),i64)=Bind(Bind(Pick(),First()),Second());A:i64=F(39);B:i64=Order");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 123), x.get("B").?.integer);
    const y = try h.execute("F(A:i64,B:i64)<transacts><decides>:i64=Block{Require[B<3];A+B};Maker(N:i64)<computes>:function<transacts><decides>(tuple(i64),i64)=Bind(F,N);V:function<transacts><decides>(tuple(i64),i64)=Maker(40);A:i64=Attempt(V[2],0)");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
    try std.testing.expectEqual(@as(u32, 0), y.failure_count);
}

test "bound function captures preserve every immutable value type and aggregate lifetimes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Mode:=enum{One,Two};R:=struct{N:i64,T:string};Read(A:[]i64,O:option(i64),M:map(string,i64),T:tuple(i64,string),V:R,E:Mode,S:string,F:float,L:logic,N:i64)<computes>:i64=A.Length+Or(O,0)+M.Length+T(0)+V.N+N;Inc(X:i64)<computes>:i64=X+1;Apply(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);Make()<computes>:function(tuple(i64),i64)=Bind(Read,array{1},option{1},map{\"雪\"=>1},tuple{30,\"雪\"},R{N:=8,T:=\"雪\"},Mode.Two,\"雪\",-0.0,true);F:function(tuple(i64),i64)=Make();G:function(tuple(i64),i64)=Bind(Apply,Inc);A:i64=F(1);B:i64=G(41);Zero(P:float,K:i64)<computes>:float=P;Z:function(tuple(i64),float)=Bind(Zero,-0.0);V:float=Z(0);Q:function(tuple(i64),float)=Bind(Zero,NaN);Nan:float=Q(0)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("V").?.floating)));
    try std.testing.expect(std.math.isNan(x.get("Nan").?.floating));
    const y = try h.execute("Keep(A:[]i64,O:option(i64),M:map(string,i64),N:i64)<computes>:i64=A.Length+Or(O,0)+M.Length+N;F:function(tuple(i64),i64)=Bind(Keep,array{},option{},map{});A:i64=F(42)");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
}

test "bound function captures retain creation snapshots while failure restores source and local callable versions" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=7;Step(Amount:i64,N:i64)<transacts><decides>:i64=Block{set C=C+Amount;Require[N<3];N+1};F:function<transacts><decides>(tuple(i64),i64)=Bind(Step,2);A:i64=Attempt(Iterate(F,5,0),C);B:i64=C;Stop(Limit:i64,N:i64)<transacts><decides>:option(i64)=Block{set C=C+1;Require[N<Limit];option{N+1}};G:function<transacts><decides>(tuple(i64),option(i64))=Bind(Stop,3);D:i64=Attempt(Loop(G,0),C);E:i64=C");
    for ([_][]const u8{ "A", "B", "D", "E" }) |name| try std.testing.expectEqual(@as(i64, 7), x.get(name).?.integer);
    try std.testing.expectEqual(@as(u32, 2), x.failure_count);
    const y = try h.execute("Add(A:i64,B:i64)<computes>:i64=A+B;Run()<transacts>:i64=Block{var F:function(tuple(i64),i64)=Bind(Add,2);A:i64=Attempt(Block{set F=Bind(Add,7);F(0);Fail[\"restore\"]},F(40));A};V:i64=Run()");
    try std.testing.expectEqual(@as(i64, 42), y.get("V").?.integer);
}

test "bound function captures reject prefix types counts residual effects and unused contexts" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(A:i64,B:i64)<computes>:i64=A+B;V:function(tuple(i64),i64)=Bind(F)", .code = .argument_count },
        .{ .source = "F()<computes>:i64=42;V:function(tuple(),i64)=Bind(F,0)", .code = .argument_count },
        .{ .source = "F(A:i64,B:i64)<computes>:i64=A+B;V:function(tuple(i64),i64)=Bind(F,\"bad\")", .code = .type_mismatch },
        .{ .source = "F(A:i64)<computes>:i64=A;V:function(tuple(),i64)=Bind(F,0,1)", .code = .argument_count },
        .{ .source = "F(A:i64,B:i64)<transacts>:i64=A+B;V:function(tuple(i64),i64)=Bind(F,0)", .code = .type_mismatch },
        .{ .source = "A:i64=Bind(7,0)", .code = .not_callable },
        .{ .source = "F(A:i64,B:i64)<transacts>:i64=A+B;G()<computes>:i64=Bind(F,2)(40);A:i64=1", .code = .call_requires_transacts },
        .{ .source = "F(A:i64,B:i64)<computes><decides>:i64=A+B;G()<computes>:i64=Bind(F,2)[40];A:i64=1", .code = .failure_context_required },
        .{ .source = "F(A:i64,B:i64)<computes>:i64=A+B;V:function(tuple(i64),i64)=Bind(F,)", .code = .expected_expression },
    }) |c| {
        const r = h.front.compile(c.source);
        if (r == .ok) return error.UnexpectedAdmission;
        if (r.failed.code != c.code) std.debug.print("bind diagnostic {s}: {s}\n", .{ c.source, r.failed.message() });
        try std.testing.expectEqual(c.code, r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "bound function captures self dispatch admits exactly 32 frames and 8192 live registers" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 31, 32 }) |n| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(N:i64)<computes>:i64=If(N==0,42,Bind(F,N-1)());A:i64=F({d})", .{n});
        const r = try h.run(try h.compile(out.buffered()), 10000);
        if (n == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    const prefix = "F(N:i64)<computes>:i64=If(true,If(N==0,42,Bind(F,N-1)()),Block{";
    const tail = "0});";
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

test "bound function captures exactly fill 8192 members and charge all copied prefixes" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const small = try h.compile("Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;F:function(tuple(i64,i64),i64)=Bind(Sum,2);G:function(tuple(i64),i64)=Bind(F,3);A:i64=G(37)");
    const x = (try h.run(small, 1000)).ok;
    const exact: u32 = @intCast(small.nodes.len + x.aggregate_values.len + x.call_steps.len);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(small, exact)).ok.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(small, exact - 1)).failed.code);
    for ([_]usize{ 546, 547 }) |visits| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Seed(A:i64,B:i64,N:i64)<computes>:i64=N;Wide(");
        for (0..15) |i| try out.print("P{d}:i64,", .{i});
        try out.writeAll("N:i64)<computes>:i64=N;Extend(F:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=Block{Z:i64=0;Bind(Wide");
        for (0..15) |_| try out.writeAll(",Z");
        try out.print(")}};F:function(tuple(i64),i64)=Iterate(Extend,{d},Bind(Seed,1,2));A:i64=F(42)", .{visits});
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (visits == 546) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer);
            try std.testing.expectEqual(@as(u32, 15), r.ok.get("F").?.callable.captures.end - r.ok.get("F").?.callable.captures.start);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "bound function captures agree with 1000 independent snapshot loop and rollback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const seed: i64 = @as(i64, @intCast(i % 19)) - 5;
        const limit: i64 = @intCast(i % 13);
        const amount: i64 = if (i % 2 == 0) 1 else 2;
        var expected = seed;
        var cell: i64 = 7;
        var failures: u32 = 0;
        while (true) {
            cell += amount;
            if (expected == 5) {
                expected = seed;
                cell = 7;
                failures = 1;
                break;
            }
            if (expected >= limit) break;
            expected += amount;
        }
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=7;var Dose:i64={d};Step(A:i64,L:i64,N:i64)<transacts><decides>:option(i64)=Block{{set C=C+A;Require[N!=5];If(N<L,option{{N+A}},option{{}})}};F:function<transacts><decides>(tuple(i64),option(i64))=Bind(Bind(Step,Dose),{d});set Dose=100;A:i64=Attempt(Loop(F,{d}),{d});B:i64=C", .{ amount, limit, seed, seed });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

test "bound function captures independently reject 2000 unused metadata signature and operand forgeries" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("G(F:function(tuple(i64,i64,i64),i64))<computes>:function(tuple(i64),i64)=Bind(Bind(F,1),2);A:i64=1");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    var binding: usize = 0;
    for (p.function_nodes, 0..) |entry, i| if (entry.node.kind == .bind) {
        binding = i;
    };
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (i % 10) {
            0 => h.metadata[0].has_control = false,
            1 => h.metadata[0].control_ops -= 1,
            2 => h.metadata[0].member_work = 0,
            3 => h.metadata[0].has_failure = true,
            4 => h.metadata[0].has_source = true,
            5 => h.metadata[0].has_local = true,
            6 => h.body[binding].node.kind.bind.callable = 8192,
            7 => h.body[binding].node.kind.bind.arguments.end += 1,
            8 => h.body[binding].node.kind.bind.arguments.start += 1,
            9 => h.body[binding].node.value_type = .string,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    const root = try h.compile("F(A:i64,B:i64)<computes>:i64=A+B;A:i64=If(false,Bind(F,2)(40),42)");
    const nodes = try std.testing.allocator.dupe(types.Node, root.nodes);
    defer std.testing.allocator.free(nodes);
    forged = root;
    forged.nodes = nodes;
    for (nodes, 0..) |*node, i| if (node.kind == .bind) {
        node.kind.bind.callable = @intCast(i);
        break;
    };
    try invalid(h, forged);
}

test "bound function captures replay rejects 1000 altered snapshots copies inputs and targets before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;Other(A:i64,B:i64,C:i64)<computes>:i64=A+B+C+1;F:function(tuple(i64,i64),i64)=Bind(Sum,2);G:function(tuple(i64),i64)=Bind(F,3);A:i64=G(37)");
    var forged = x;
    var output: [2048]u8 = undefined;
    var bound: usize = 0;
    for (x.program.bindings) |binding| if (std.mem.eql(u8, binding.name.text(x.program.source), "G")) {
        bound = binding.node;
    };
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        @memcpy(h.values[0..x.values.len], x.values);
        @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
        forged.call_steps = h.steps[0..x.call_steps.len];
        forged.values = h.values[0..x.values.len];
        forged.aggregate_values = h.members[0..x.aggregate_values.len];
        switch (i % 10) {
            0 => h.steps[0].value.integer += 1,
            1 => h.steps[0].function = 1,
            2 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            3 => h.members[0].integer += 1,
            4 => h.members[1].integer += 1,
            5 => h.members[2].integer += 1,
            6 => h.values[bound].callable.function = 1,
            7 => h.values[bound].callable.captures = .{ .start = 0, .end = 2 },
            8 => h.values[bound].callable.captures.end = 8193,
            9 => h.members[0] = .{ .floating = 2 },
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const cycle = try h.execute("Id(N:i64)<computes>:i64=N;Wrap(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);F:function(tuple(i64),i64)=Bind(Wrap,Id);A:i64=F(42)");
    @memcpy(h.members[0..cycle.aggregate_values.len], cycle.aggregate_values);
    h.members[0] = cycle.get("F").?;
    forged = cycle;
    forged.aggregate_values = h.members[0..cycle.aggregate_values.len];
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "bound function captures exact report work output and wire depth admit before external output" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Add(A:i64,B:i64)<computes>:i64=A+B;F<public>:function(tuple(i64),i64)=Bind(Add,2);A<public>:i64=F(40)");
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try reporting.write(&out, x, true, .{});
    out.end = 0;
    _ = try reporting.write(&out, x, true, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out.end = 0;
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    for ([_]usize{ 84, 85 }) |count| {
        var source = std.Io.Writer.fixed(&h.text);
        try source.writeAll("Id(N:i64)<computes>:i64=N;Wrap(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);Grow(F:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=Bind(Wrap,F);");
        try source.print("F<public>:function(tuple(i64),i64)=Iterate(Grow,{d},Id)", .{count});
        const p = try h.compile(source.buffered());
        // Deliberately bypass Harness report validation for the depth rejection.
        const r = h.runtime.evaluate(p, 10000);
        try std.testing.expect(r == .ok);
        out.end = 0;
        // The captures nest one container a level in a whole-program report. A public report
        // shows no capture (`fix2`), so it has no such depth.
        if (count == 84) _ = try reporting.write(&out, r.ok, false, .{}) else {
            try std.testing.expectError(error.ReportLimit, reporting.write(&out, r.ok, false, .{}));
            try std.testing.expectEqual(@as(usize, 0), out.end);
        }
        out.end = 0;
        _ = try reporting.write(&out, r.ok, true, .{});
    }
    _ = try h.execute("A:i64=42");
}

test "bound function captures inspection21 and zero cell transactional regions retain exact nesting" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Add(A:i64,B:i64)<computes>:i64=A+B;F(N:i64)<computes>:function(tuple(i64),i64)=Bind(Add,N);A:i64=1");
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect(try report.write(&out, p) == .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":21") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"bind\"") != null);
    const source = try h.compile("F(A:i64,B:i64)<transacts>:i64=A+B;A:i64=Bind(F,2)(40)");
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithRuntimeStorage(source, &h.values, &h.members, &h.control, null, &h.frames, 100).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(source, 100)).ok.get("A").?.integer);
    for ([_]usize{ 31, 32 }) |depth| {
        out = .fixed(&h.text);
        try out.writeAll("F(A:i64,B:i64)<transacts>:i64=A+B;G(H:function<transacts>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(H(X),0);V:function<transacts>(tuple(i64),i64)=Bind(F,2);A:i64=");
        for (0..depth) |_| try out.writeAll("Attempt(");
        try out.writeAll("G(V,40)");
        for (0..depth) |_| try out.writeAll(",0)");
        const r = try h.run(try h.compile(out.buffered()), 1000);
        if (depth == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, r.failed.code);
    }
}

test "bound function captures imported defaults and nominal privacy retain definition owners" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=Bind(S.Add,2);A:i64=F(40);R:=struct{F:function(tuple(i64),i64)=Bind(S.Add,2)};V:R=R{};B:i64=V.F(40)" },
        .{ .path = "雪.forb", .source = "Add<public>(A:i64,B:i64)<computes>:i64=A+B;Hidden(A:i64,B:i64)<computes>:i64=A+B" },
    };
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"module\":\"雪.forb\",\"captures\":[2]") != null);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=Bind(S.Hidden,2)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    private[0].source = "S:=import{\"雪.forb\"};A:i64=9";
    private[1].source = "Hidden:=struct{N:i64};F<public>(X:Hidden,N:i64)<computes>:i64=N";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
}
