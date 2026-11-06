//! Anonymous function scope, continuation, capture and admission oracles.
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
                std.debug.print("anonymous function compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("anonymous function run {s}\n", .{r.failed.message()});
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

test "anonymous function bodies publish distinct code sites and exact zero capture signatures" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N+1};G:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N+2};H:function(tuple(),i64)=Fn()<computes>:i64{42};A:i64=F(41);B:i64=G(40);C:i64=H();D:i64=Fn(N:i64)<computes>:i64{N+1}(41)");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expectEqual(@as(usize, 4), x.program.functions.len);
    for (x.program.functions) |f| try std.testing.expect(f.anonymous and !f.is_public);
    try std.testing.expect(h.front.anonymous_count == 0);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"name\":\"Fn\",\"module\":null,\"anonymous\":27") != null);
}

test "anonymous function bodies nest with explicit compiler continuations and restore creator scopes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make()<computes>:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N+1};F:function(tuple(),function(tuple(i64),i64))=Fn()<computes>:function(tuple(i64),i64){Fn(N:i64)<computes>:i64{N+2}};Run(N:i64)<transacts>:i64=Block{var Outer:i64=N;H:function<transacts>(tuple(i64),i64)=Fn(X:i64)<transacts>:i64{Block{var Inner:i64=X;If(true,Set(Inner,Inner+1),Set(Inner,0));Inner}};set Outer=Outer+1;H(Outer)};A:i64=Make()(41);B:i64=F()(40);C:i64=Run(40);D:i64=Fn()<computes>:i64{\n42\n}()");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expect(h.front.anonymous_count == 0 and h.front.local_count == 0 and h.front.local_checkpoint_count == 0);
    for ([_][]const u8{
        "Make()<computes>:function(tuple(i64),i64)=Block{N:i64=2;Fn[M:i64=1](X:i64)<computes>:i64{N+X}};A:i64=1",
        "F:i64=Fn()<computes>:i64{42",
        "F:function(tuple(),i64)=Fn()<computes>:i64{}",
    }) |source| {
        try std.testing.expect(h.front.compile(source) == .failed);
        _ = try h.execute("A:i64=42");
    }
}

test "anonymous function captures escape nested creator frames and snapshot source and mutable local values" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=N](X:i64)<computes>:i64{A+X};var Cell:i64=2;F:function(tuple(i64),i64)=Make(Cell);set Cell=100;G:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<computes>:i64{A+N};Build(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=N]()<computes>:function(tuple(i64),i64){Fn[B:i64=A](X:i64)<computes>:i64{B+X}}();Local()<transacts>:function(tuple(i64),i64)=Block{var N:i64=2;H:function(tuple(i64),i64)=Fn[A:i64=N](X:i64)<computes>:i64{A+X};set N=100;H};A:i64=F(40);B:i64=G(40);C:i64=Build(2)(40);D:i64=Local()(40)");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expect(h.front.anonymous_count == 0);
}

test "anonymous function captures evaluate strictly and preserve exact invocation effects in state loops" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var Order:i64=0;First()<transacts>:i64=Block{set Order=Order*10+1;2};Second()<transacts>:i64=Block{set Order=Order*10+2;3};F:function(tuple(i64),i64)=Fn[A:i64=First(),B:i64=Second()](N:i64)<computes>:i64{A+B+N};A:i64=F(37);B:i64=Order;Step:function(tuple(i64),i64)=Fn[Amount:i64=2](N:i64)<computes>:i64{N+Amount};C:i64=Iterate(Step,3,36);Stop:function(tuple(i64),option(i64))=Fn[Limit:i64=42,Amount:i64=2](N:i64)<computes>:option(i64){If(N<Limit,option{N+Amount},option{})};D:i64=Loop(Stop,38)");
    for ([_][]const u8{ "A", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("B").?.integer);
    const y = try h.execute("var Cell:i64=7;Make(A:i64)<computes>:function<transacts><decides>(tuple(i64),option(i64))=Fn[Amount:i64=A](N:i64)<transacts><decides>:option(i64){Block{set Cell=Cell+Amount;Require[N<3];option{N+1}}};F:function<transacts><decides>(tuple(i64),option(i64))=Make(2);A:i64=Attempt(Loop(F,0),Cell);B:i64=Cell");
    try std.testing.expectEqual(@as(i64, 7), y.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), y.get("B").?.integer);
    try std.testing.expectEqual(@as(u32, 1), y.failure_count);
}

test "anonymous function captures reject malformed headers exact types and hidden free parameters with healthy reuse" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        "F:function(tuple(i64),i64)=Fn[](N:i64)<computes>:i64{N}",
        "F:function(tuple(i64),i64)=Fn[A:i64=\"bad\"](N:i64)<computes>:i64{A+N}",
        "F:function(tuple(i64),i64)=Fn[A:i64=2,A:i64=3](N:i64)<computes>:i64{A+N}",
        "F:function(tuple(i64),i64)=Fn[A:i64=2](A:i64)<computes>:i64{A}",
        "F:function(tuple(i64),i64)=Fn[A:i64=2,](N:i64)<computes>:i64{A+N}",
        "F:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<transacts>:i64{A+N}",
        "G(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=2](X:i64)<computes>:i64{N+X};A:i64=1",
        "F:i64=Fn[A:i64=2](N:i64)<computes>:i64{N",
    }) |source| {
        try std.testing.expect(h.front.compile(source) == .failed);
        _ = try h.execute("A:i64=42");
    }
}

test "anonymous function compiler continuations admit exactly 64 code bodies and shared 256 locals" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 64, 65 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("A:i64=");
        for (0..count) |_| try out.writeAll("Fn()<computes>:i64{Block{");
        try out.writeAll("42");
        for (0..count - 1) |_| try out.writeAll("}};42");
        try out.writeAll("}}()");
        const result = h.front.compile(out.buffered());
        if (count == 64) {
            try std.testing.expectEqual(@as(usize, 64), result.ok.functions.len);
            try std.testing.expectEqual(@as(i64, 42), (try h.run(result.ok, 1000)).ok.get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.function_limit, result.failed.code);
    }
    for ([_]usize{ 255, 256 }) |locals| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Make()<computes>:function(tuple(),i64)=Block{");
        for (0..locals) |i| try out.print("L{d}:i64=0;", .{i});
        try out.writeAll("Fn()<computes>:i64{Block{Inner:i64=42;Inner}}};A:i64=Make()()");
        const result = h.front.compile(out.buffered());
        if (locals == 255) try std.testing.expectEqual(@as(i64, 42), (try h.run(result.ok, 10000)).ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.local_binding_limit, result.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "anonymous function compiler publishes exactly 8192 runtime nodes before template reuse" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]bool{ false, true }) |extra| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("A:i64=Block{");
        for (0..64) |i| {
            try out.writeAll("Fn()<computes>:i64{");
            const last = extra and i == 63;
            for (0..@as(usize, if (last) 126 else 127)) |_| try out.writeByte('-');
            try out.writeAll(if (last) "42+0};" else "42};");
        }
        try out.writeAll("42}");
        const result = h.front.compile(out.buffered());
        if (!extra) {
            try std.testing.expectEqual(@as(usize, 8192), result.ok.function_nodes.len);
            try std.testing.expectEqual(@as(i64, 42), (try h.run(result.ok, 1000)).ok.get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.template_limit, result.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "anonymous function capture copies exactly fill run member storage and have precise fuel" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("A:i64=Fn[X:i64=2](N:i64)<computes>:i64{X+N}(40)");
    const x = (try h.run(p, 100)).ok;
    const fuel: u64 = @intCast(p.nodes.len + x.call_steps.len + x.aggregate_values.len);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(p, fuel)).ok.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, fuel - 1)).failed.code);
    for ([_]usize{ 16, 17 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F:function(tuple(),i64)=Fn[");
        for (0..count) |i| try out.print("{s}P{d}:i64={d}", .{ if (i == 0) "" else ",", i, if (i == 15) @as(i64, 42) else 0 });
        try out.writeAll("]()<computes>:i64{P15};A:i64=F()");
        const result = h.front.compile(out.buffered());
        if (count == 16) {
            const closed = (try h.run(result.ok, 1000)).ok;
            try std.testing.expectEqual(@as(i64, 42), closed.get("A").?.integer);
            try std.testing.expectEqual(@as(usize, 16), closed.aggregate_values.len);
        } else try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, result.failed.code);
    }
    for ([_]usize{ 546, 547 }) |visits| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Seed(A:i64,B:i64,N:i64)<computes>:i64=N;Extend(F:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=Block{Z:i64=0;Fn[");
        for (0..15) |i| try out.print("{s}P{d}:i64=Z", .{ if (i == 0) "" else ",", i });
        try out.print("](N:i64)<computes>:i64{{N}}}};F:function(tuple(i64),i64)=Iterate(Extend,{d},Bind(Seed,1,2));A:i64=F(42)", .{visits});
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (visits == 546) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "anonymous function independent admission rejects 2000 forged source identities and unused metadata" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Named(N:i64)<computes>:i64=N+1;Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=N](X:i64)<computes>:i64{A+X};Other:function(tuple(i64),i64)=Fn[X:i64=2](N:i64)<computes>:i64{X+N};A:i64=1");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    const anonymous: usize = 1;
    const owner: usize = 2;
    try std.testing.expect(p.functions[anonymous].anonymous and !p.functions[owner].anonymous);
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        switch (i % 8) {
            0 => h.metadata[anonymous].anonymous = false,
            1 => h.metadata[anonymous].is_public = true,
            2 => h.metadata[0].anonymous = true,
            3 => h.metadata[anonymous].name = p.functions[0].name,
            4 => h.metadata[p.functions.len - 1].name = p.functions[anonymous].name,
            5 => h.metadata[owner].has_control = false,
            6 => h.metadata[owner].member_work = 0,
            7 => h.metadata[owner].control_ops -= 1,
            else => unreachable,
        }
        try invalid(h, forged);
    }
}

test "anonymous function captures agree with 1000 independent immutable snapshot and rollback oracles" {
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
        try out.print("var C:i64=7;var Dose:i64={d};F:function<transacts><decides>(tuple(i64),option(i64))=Fn[A:i64=Dose,L:i64={d}](N:i64)<transacts><decides>:option(i64){{Block{{set C=C+A;Require[N!=5];If(N<L,option{{N+A}},option{{}})}}}};set Dose=100;A:i64=Attempt(Loop(F,{d}),{d});B:i64=C", .{ amount, limit, seed, seed });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

test "anonymous function captures preserve all immutable values contextual empties and signed float bits" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Mode:=enum{One,Two};R:=struct{N:i64,T:string};F:function(tuple(i64),i64)=Fn[A:[]i64=array{1},O:option(i64)=option{1},M:map(string,i64)=map{\"雪\"=>1},T:tuple(i64,string)=tuple{30,\"雪\"},V:R=R{N:=8,T:=\"雪\"},E:Mode=Mode.Two,S:string=\"雪\",Q:float=-0.0,B:logic=true](N:i64)<computes>:i64{A.Length+Or(O,0)+M.Length+T(0)+V.N+N};G:function(tuple(i64),i64)=Fn[H:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N+1}](N:i64)<computes>:i64{H(N)};Empty:function(tuple(i64),i64)=Fn[A:[]i64=array{},O:option(i64)=option{},M:map(string,i64)=map{}](N:i64)<computes>:i64{A.Length+Or(O,0)+M.Length+N};Z:function(tuple(i64),float)=Fn[Q:float=-0.0](N:i64)<computes>:float{Q};Nan:function(tuple(i64),float)=Fn[Q:float=NaN](N:i64)<computes>:float{Q};A:i64=F(1);B:i64=G(41);C:i64=Empty(42);Zero:float=Z(0);NotNumber:float=Nan(0)");
    for ([_][]const u8{ "A", "B", "C" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expect(std.math.isNan(x.get("NotNumber").?.floating));
}

test "anonymous function captured named self dispatch reaches exact 32 frames and permits fatal reuse" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 15, 16 }) |n| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(N:i64)<computes>:i64=If(N==0,42,Fn[Next:function(tuple(i64),i64)=F,Remaining:i64=N-1]()<computes>:i64{{Next(Remaining)}}());A:i64=Fn()<computes>:i64{{F({d})}}()", .{n});
        const p = try h.compile(out.buffered());
        const r = try h.run(p, 10000);
        // Root thunk plus16 F frames and15 callbacks exactly fill32 slots.
        if (n == 15) {
            try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer);
            try std.testing.expectEqual(@as(usize, 30), r.ok.aggregate_values.len);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "anonymous function imported factories defaults and private signatures retain original source sites" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=S.Make(2);A:i64=F(40);R:=struct{F:function(tuple(i64),i64)=S.Make(2)};V:R=R{};B:i64=V.F(40)" },
        .{ .path = "雪.forb", .source = "Label:string=\"雪\";Helper(A:i64,N:i64)<computes>:i64=A+N;Make<public>(A:i64)<computes>:function(tuple(i64),i64)=Fn[Amount:i64=A](N:i64)<computes>:i64{Helper(Amount,N)}" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok;
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    var buffer: [16384]u8 = undefined;
    var expected: [512]u8 = undefined;
    const offset = std.mem.indexOf(u8, files[1].source, "Fn[").?;
    const needle = try std.fmt.bufPrint(&expected, "\"module\":\"雪.forb\",\"anonymous\":{d},\"captures\":[2]", .{offset});
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), needle) != null);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};A:i64=S.Helper(2,40)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    private[0].source = "S:=import{\"雪.forb\"};A:i64=1";
    private[1].source = "Hidden:=struct{N:i64};Make<public>()<computes>:function(tuple(Hidden),i64)=Fn(H:Hidden)<computes>:i64{H.N}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
}

test "anonymous function replay rejects 1000 altered sites capture copies targets and cyclic descriptors before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F<public>:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<computes>:i64{A+N};G:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<computes>:i64{A+N+1};A<public>:i64=F(40)");
    var forged = x;
    var output: [2048]u8 = undefined;
    var bound: usize = 0;
    for (x.program.bindings) |binding| if (std.mem.eql(u8, binding.name.text(x.program.source), "F")) {
        bound = binding.node;
    };
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        @memcpy(h.values[0..x.values.len], x.values);
        @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
        @memcpy(h.metadata[0..x.program.functions.len], x.program.functions);
        forged = x;
        forged.program.functions = h.metadata[0..x.program.functions.len];
        forged.call_steps = h.steps[0..x.call_steps.len];
        forged.values = h.values[0..x.values.len];
        forged.aggregate_values = h.members[0..x.aggregate_values.len];
        switch (i % 10) {
            0 => h.steps[0].value.integer += 1,
            1 => h.steps[0].function = 1,
            2 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            3 => h.members[0].integer += 1,
            4 => h.members[0] = .{ .floating = 2 },
            5 => h.values[bound].callable.function = 1,
            6 => h.values[bound].callable.captures = .{ .start = 1, .end = 2 },
            7 => h.values[bound].callable.captures.end = 8193,
            8 => h.metadata[0].anonymous = false,
            9 => h.metadata[0].name = h.metadata[1].name,
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, true, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const cycle = try h.execute("F:function(tuple(i64),i64)=Fn[H:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N}](N:i64)<computes>:i64{H(N)};A:i64=F(42)");
    @memcpy(h.members[0..cycle.aggregate_values.len], cycle.aggregate_values);
    h.members[0] = cycle.get("F").?;
    forged = cycle;
    forged.aggregate_values = h.members[0..cycle.aggregate_values.len];
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "anonymous function unused inspection22 exact report budgets and zero cell rollback regions have checked admission" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=N](X:i64)<computes>:i64{A+X};A:i64=1");
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect(try report.write(&out, p) == .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"anonymous\":true") != null);
    const size = out.end;
    out.end = 0;
    try std.testing.expect(try report.writeBounded(&out, p, .{ .output_bytes = size }) == .ok);
    out.end = 0;
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try report.writeBounded(&out, p, .{ .output_bytes = size - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const x = try h.execute("F<public>:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<computes>:i64{A+N};A<public>:i64=F(40)");
    out.end = 0;
    const admitted = try reporting.write(&out, x, true, .{});
    out.end = 0;
    _ = try reporting.write(&out, x, true, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out.end = 0;
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const source = try h.compile("Id(N:i64)<transacts>:i64=N;F:function<transacts>(tuple(i64),i64)=Fn[H:function<transacts>(tuple(i64),i64)=Id](N:i64)<transacts>:i64{Attempt(H(N),0)};A:i64=F(42)");
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithRuntimeStorage(source, &h.values, &h.members, &h.control, null, &h.frames, 100).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(source, 100)).ok.get("A").?.integer);
    for ([_]usize{ 31, 32 }) |depth| {
        var text = std.Io.Writer.fixed(&h.text);
        try text.writeAll("Id(N:i64)<transacts>:i64=N;F:function<transacts>(tuple(i64),i64)=Fn[H:function<transacts>(tuple(i64),i64)=Id](N:i64)<transacts>:i64{Attempt(H(N),0)};A:i64=");
        for (0..depth) |_| try text.writeAll("Attempt(");
        try text.writeAll("F(42)");
        for (0..depth) |_| try text.writeAll(",0)");
        const r = try h.run(try h.compile(text.buffered()), 1000);
        if (depth == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, r.failed.code);
    }
}
