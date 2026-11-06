//! Independent bounded self recursion, quota, lifetime and replay oracles.
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
                std.debug.print("recursion compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("recursion run {s}\n", .{r.failed.message()});
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

test "self recursion computes strict arguments and preserves caller snapshots" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Fact(N:i64)<computes>:i64=If(N==0,1,N*Fact(N-1));A:i64=Fact(10);var C:i64=0;Swap(N:i64,X:i64,Y:i64)<transacts>:tuple(i64,i64,i64)=Block{set C=C+1;If(N==0,tuple{X,Y,C},Swap(N-1,Y,X))};B:tuple(i64,i64,i64)=Swap(2,Set(C,1),Set(C,2));After:i64=C");
    try std.testing.expectEqual(@as(i64, 3628800), x.get("A").?.integer);
    const b = x.elements(x.get("B").?).?;
    try std.testing.expectEqual(@as(i64, 1), b[0].integer);
    try std.testing.expectEqual(@as(i64, 2), b[1].integer);
    try std.testing.expectEqual(@as(i64, 5), b[2].integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("After").?.integer);
    try std.testing.expect(x.program.functions[0].has_control);
}

test "self recursion composes ordinary helpers aliases defaults and counted restarts" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(N:i64)<computes>:i64=N+1;Sum(N:i64)<computes>:i64=If(N==0,0,Inc(N)+Sum(N-1));D:i64=Sum(3);F(N:i64)<computes>:i64=If(N>3,N,F(N+1));A:i64=Iterate(F,5,0);G(X:i64)<computes>:i64=F(X);B:i64=G(1);Keep(X:i64)<computes>:i64=X;Defaults:=struct{Value:i64=Sum(3)};Record:Defaults=Defaults{};C:i64=Record.Value");
    try std.testing.expectEqual(@as(i64, 9), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("C").?.integer);
}

test "self recursion preserves every retained Value kind contextual empties and signed floats" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Kind<public>:=enum<closed>{Ready,Done};State<public>:=struct{Text:string,N:i64};Echo(N:i64,X:tuple(i64,logic,string,float,Kind,State,[]i64,option(i64),map(string,i64)))<computes>:tuple(i64,logic,string,float,Kind,State,[]i64,option(i64),map(string,i64))=If(N==0,X,Echo(N-1,X));Seed:tuple(i64,logic,string,float,Kind,State,[]i64,option(i64),map(string,i64))=tuple{7,true,\"雪\",NaN,Kind.Ready,State{Text:=\"旧\",N:=3},array{},option{},map{}};A:tuple(i64,logic,string,float,Kind,State,[]i64,option(i64),map(string,i64))=Echo(15,Seed);FloatEcho(N:i64,X:float)<computes>:float=If(N==0,X,FloatEcho(N-1,X));Zero:float=FloatEcho(4,-0.0)");
    try equal(x.get("Seed").?, x.get("A").?);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    const a = x.elements(x.get("A").?).?;
    try std.testing.expectEqualStrings("雪", a[2].string);
    try std.testing.expect(std.math.isNan(a[3].floating));
}

test "self failures preserve one defining origin and restore recursive source writes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=7;F(N:i64)<transacts><decides>:i64=Block{set C=C+1;If(N==0,Block{Require[false];N},F[N-1])};A:i64=Attempt(F[7],C);B:i64=C;G(N:i64)<transacts><decides>:i64=Block{set C=C+1;If(N==2,Attempt(G[N-1],C),If(N==0,Block{Require[false];N},G[N-1]))};D:i64=Attempt(G[3],0);E:i64=C;H(N:i64)<transacts>:i64=Block{var V:i64=N;Attempt(If(N==0,Block{Set(V,100);Require[false];V},H(N-1)),V+10)};Local:i64=H(3)");
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("Local").?.integer);
    try std.testing.expectEqual(@as(u32, 3), x.failure_count);
    try std.testing.expectEqual(@as(usize, 3), x.failures.len);
    try std.testing.expectEqual(@as(u32, 0), x.failures[0].function.?);
    var propagation: usize = 0;
    for (x.call_steps) |event| if (event.kind == .propagate) {
        propagation += 1;
    };
    try std.testing.expect(propagation >= 8);
}

test "self recursion admits exactly 32 frames and rejects fatal depth without catching it" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(N:i64)<computes>:i64=If(N==0,42,F(N-1));A:i64=F(31)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    const p = try h.compile("var C:i64=3;F(N:i64)<transacts>:i64=Block{set C=C+1;If(N==0,C,F(N-1))};A:i64=Attempt(F(32),0)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(p, 10000)).failed.code);
    try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
    try std.testing.expectEqual(@as(i64, 42), (try h.execute("A:i64=42")).get("A").?.integer);
    const endless = try h.compile("F()<computes>:i64=F();A:i64=F()");
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(endless, 1000)).failed.code);
}

test "self recursion admits exactly 8192 live registers with repeated bodies" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const base = try h.compile("F(N:i64)<computes>:i64=Block{If(N==0,42,F(N-1))};A:i64=F(15)");
    const base_length = base.functions[0].body.end - base.functions[0].body.start;
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F(N:i64)<computes>:i64=Block{");
    for (0..512 - base_length) |_| try out.writeAll("0;");
    try out.writeAll("If(N==0,42,F(N-1))};");
    const end = out.end;
    try out.writeAll("A:i64=F(15)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(@as(u32, 512), p.functions[0].body.end - p.functions[0].body.start);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(p, 32768)).ok.get("A").?.integer);
    out.end = end;
    try out.writeAll("A:i64=F(16)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_register_limit, (try h.run(try h.compile(out.buffered()), 32768)).failed.code);
}

test "self constructors admit exactly 8192 physical members and retain old aggregate snapshots" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]bool{ false, true }) |extra| {
        var out = std.Io.Writer.fixed(&h.text);
        if (extra) try out.writeAll("Old:[]i64=array{1};");
        try out.writeAll("F(N:i64)<computes>:[]i64=Block{V:i64=N;R:[]i64=array{");
        for (0..256) |i| try out.writeAll(if (i == 0) "V" else ",V");
        try out.writeAll("};If(N==0,R,F(N-1))};A:[]i64=F(31)");
        const p = try h.compile(out.buffered());
        try std.testing.expectEqual(@as(u32, 8193), p.functions[0].member_work);
        const r = try h.run(p, 65536);
        if (extra) try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code) else {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            for (r.ok.elements(r.ok.get("A").?).?) |v| try std.testing.expectEqual(@as(i64, 0), v.integer);
            for (r.ok.aggregate_values[0..256]) |v| try std.testing.expectEqual(@as(i64, 31), v.integer);
        }
    }
}

test "self execution charges exact fuel at every prefix and cleans every failed run" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=0;F(N:i64)<transacts>:i64=Block{set C=C+1;If(N==0,C,F(N-1))};A:i64=F(6);B:i64=C");
    var needed: u32 = 0;
    while (true) : (needed += 1) {
        const r = try h.run(p, needed);
        if (r == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, r.failed.code);
        try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
        try std.testing.expect(needed < 1000);
    }
    const x = (try h.run(p, needed)).ok;
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    // Every visited root and body operation costs one; self returns have their
    // operation event and no extra dispatch or host recursion cost.
    var root_visits: usize = 0;
    for (x.activity) |active| if (active) {
        root_visits += 1;
    };
    try std.testing.expectEqual(@as(usize, needed), root_visits + x.call_steps.len);
    _ = try h.execute("A:i64=42");
}

test "self recursion agrees with 1000 independent recursive state and rollback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const n = i % 24;
        const seed = @as(i64, @intCast(i % 31)) - 15;
        var sum = seed;
        var cell: i64 = 5;
        var failures: u32 = 0;
        // Independent scalar loop models the recursive unwind, including
        // own region rollback around each local write before returning.
        for (0..n + 1) |depth| {
            const current = @as(i64, @intCast(n - depth));
            if (@rem(current, 3) == 0) {
                sum += 10;
                failures += 1;
            } else {
                sum += current;
                cell += current;
            }
        }
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=5;F(N:i64,X:i64)<transacts>:i64=Block{{V:i64=Attempt(Block{{Set(C,C+N);Require[N/3*3!=N];X+N}},X+10);If(N==0,V,F(N-1,V))}};A:i64=F({d},{d});B:i64=C", .{ n, seed });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(sum, x.get("A").?.integer);
        try std.testing.expectEqual(cell, x.get("B").?.integer);
        try std.testing.expectEqual(failures, x.failure_count);
    }
}

test "self calls reject malformed signatures defaults shadowing and forward references" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(N:i64)<computes>:i64=F()", .code = .argument_count },
        .{ .source = "F()<computes>:i64=F(1)", .code = .argument_count },
        .{ .source = "F(N:i64)<computes>:i64=F(true)", .code = .type_mismatch },
        .{ .source = "F(N:i64)<computes><decides>:i64=F(N)", .code = .expected_call },
        .{ .source = "F(N:i64)<computes>:i64=F[N]", .code = .expected_call },
        .{ .source = "F(N:i64=F(0))<computes>:i64=N", .code = .unknown_name },
        // RFC-0076 rule 1: a local or a parameter may not take the function's own name.
        .{ .source = "F(N:i64)<computes>:i64=Block{F:i64=1;F(N)}", .code = .shadowed_name },
        .{ .source = "F(F:i64)<computes>:i64=F(0)", .code = .shadowed_name },
        .{ .source = "F(F:tuple(i64))<computes>:i64=F(0);A:i64=F(tuple{42})", .code = .shadowed_name },
        .{ .source = "G(N:i64)<computes>:i64=Block{G:tuple(i64)=tuple{N};G(0)};B:i64=G(7)", .code = .shadowed_name },
        .{ .source = "F(N:i64)<computes>:i64=Block{H:i64=1;H(N)}", .code = .not_callable },
        .{ .source = "F(H:i64)<computes>:i64=H(0)", .code = .not_callable },
        // RFC-0091: a body may call a function declared further down; the root may not.
        .{ .source = "A:i64=G(0);G(N:i64)<computes>:i64=N", .code = .unknown_name },
        .{ .source = "F(N:i64)<computes><decides>:i64=F[N];A:i64=F[0]", .code = .failure_context_required },
        .{ .source = "F(N:i64)<transacts>:i64=F(N);G(N:i64)<computes>:i64=F(N)", .code = .call_requires_transacts },
        .{ .source = "F(N:i64)<computes>:i64=F(", .code = .unmatched_parenthesis },
        .{ .source = "F(N:i64)<computes>:i64=F(1+)", .code = .expected_expression },
        .{ .source = "F(N:i64)<computes>:i64=F(,)", .code = .expected_expression },
    }) |c| try std.testing.expectEqual(c.code, h.front.compile(c.source).failed.code);
    // A tuple parameter or local of another name is indexed by a call form beside the function.
    const x = try h.execute("F(T:tuple(i64))<computes>:i64=T(0);A:i64=F(tuple{42});G(N:i64)<computes>:i64=Block{U:tuple(i64)=tuple{N};U(0)};B:i64=G(7)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
}

test "self bodies independently reject 2000 unused signature chronology effect and metadata forgeries" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=3;F(N:i64)<transacts><decides>:i64=Block{set C=C+1;Require[N>0];If(N==1,42,F[N-1])};A:i64=9");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    const args = try std.testing.allocator.dupe(u32, p.function_arguments);
    defer std.testing.allocator.free(args);
    forged.function_arguments = args;
    var self_pc: usize = 0;
    var other_arm: u32 = 0;
    for (p.function_nodes, 0..) |entry, i| {
        if (entry.node.kind == .recur) self_pc = i;
        if (entry.node.kind == .integer and entry.node.kind.integer == 42) other_arm = @intCast(i);
    }
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        @memcpy(args, p.function_arguments);
        switch (i % 12) {
            0 => h.metadata[0].transacts = false,
            1 => h.metadata[0].decides = false,
            2 => h.metadata[0].has_control = false,
            3 => h.metadata[0].has_failure = false,
            4 => h.metadata[0].has_source = false,
            5 => h.metadata[0].control_ops -= 1,
            6 => h.body[self_pc].node.kind.recur.end += 1,
            7 => h.body[self_pc].node.kind.recur.start += 1,
            8 => h.body[self_pc].node.value_type = .logic,
            9 => args[0] = @intCast(self_pc),
            10 => args[0] = other_arm,
            11 => h.metadata[0].parameter_count = 0,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    const aggregate = try h.compile("F(N:i64)<computes>:[]i64=If(N==0,array{N},F(N-1));A:i64=9");
    @memcpy(h.metadata[0..aggregate.functions.len], aggregate.functions);
    forged = aggregate;
    forged.functions = h.metadata[0..aggregate.functions.len];
    h.metadata[0].member_work = 1;
    try invalid(h, forged);
    const root = try h.compile("F(N:i64)<computes>:i64=If(N==0,0,F(N-1));A:i64=F(1)");
    const nodes = try std.testing.allocator.dupe(types.Node, root.nodes);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*node| if (node.kind == .call) {
        const range = node.kind.call.arguments;
        node.kind = .{ .recur = range };
    };
    forged = root;
    forged.nodes = nodes;
    try invalid(h, forged);
}

test "self replay rejects 1000 missing reordered parameter return and propagated cause forgeries before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(N:i64)<computes>:i64=If(N==0,42,F(N-1));A:i64=F(7)");
    var forged = x;
    var output: [512]u8 = undefined;
    var parameter: usize = 0;
    var returned: usize = 0;
    for (x.call_steps, 0..) |event, i| {
        if (event.pc == 0 and i != 0) parameter = i;
        if (x.program.function_nodes[event.pc].node.kind == .recur) returned = i;
    }
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (i % 5) {
            0 => h.steps[parameter].value = .{ .integer = 99 },
            1 => h.steps[returned].value = .{ .integer = 99 },
            2 => h.steps[parameter].pc = 1,
            3 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            4 => h.steps[parameter].function = 1,
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const exact = try reporting.validate(x, false, .{});
    var out = std.Io.Writer.fixed(&output);
    _ = try reporting.write(&out, x, false, .{ .work = exact.work, .output_bytes = exact.output_bytes });
    out = .fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = exact.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    out = .fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .output_bytes = exact.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const failure = try h.execute("F(N:i64)<computes><decides>:i64=If(N==0,Block{Require[false];N},F[N-1]);A:i64=Attempt(F[7],42)");
    @memcpy(h.steps[0..failure.call_steps.len], failure.call_steps);
    forged = failure;
    forged.call_steps = h.steps[0..failure.call_steps.len];
    for (h.steps[0..failure.call_steps.len]) |*event| if (event.kind == .propagate) {
        event.value = .{ .boolean = true };
        break;
    };
    out = .fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "self evidence admits exactly 8192 events and rejects the next event with healthy reuse" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "F(N:i64)<computes>:i64=If(N==0,42,F(N-1));G(X:i64)<computes>:i64=Block{F(1);X};Keep(X:i64)<computes>:i64=X;";
    var out = std.Io.Writer.fixed(&h.text);
    try out.print("{s}A:i64=Iterate(G,1,7)", .{prefix});
    const one = try h.execute(out.buffered());
    const events = one.call_steps.len;
    const visits = 8192 / events;
    const tail = 8192 % events;
    for ([_]usize{ 0, 1 }) |extra| {
        out = .fixed(&h.text);
        try out.print("{s}A:i64=Iterate(G,{d},7);B:i64=Iterate(Keep,{d},A)", .{ prefix, visits, tail + extra });
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (extra == 0) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.call_steps.len);
            try std.testing.expectEqual(@as(i64, 7), r.ok.get("B").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "self origins truncate after 32 while repeated catches preserve 100 failures and fatal cleanup" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(N:i64)<computes><decides>:i64=If(N==0,Block{Fail[\"雪\"];N},F[N-1]);G(X:i64)<computes>:i64=Attempt(F[2],X);A:i64=Iterate(G,100,7)");
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(u32, 100), x.failure_count);
    try std.testing.expectEqual(@as(usize, 32), x.failures.len);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, x, "recursive.forb", .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"truncated\":true") != null);
    const fatal = try h.compile("var C:i64=1;F(N:i64)<transacts>:i64=Block{set C=C+1;If(N==0,1/0,F(N-1))};A:i64=Attempt(F(5),42)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(fatal, 1000)).failed.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    _ = try h.execute("A:i64=42");
}

test "self imported public bodies preserve defining UTF8 owners privacy and inspection seventeen unused bodies" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};A:S.Row=S.Echo(7,S.Row{Name:=\"雪\",N:=3})" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,N:i64};Echo<public>(N:i64,X:Row)<computes>:Row=If(N==0,X,Echo(N-1,X));Hidden(N:i64)<computes>:i64=If(N==0,1,Hidden(N-1))" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok;
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqualStrings("雪", x.elements(x.get("A").?).?[0].string);
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};A:i64=S.Hidden(0)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    const unused = try h.compile("F(N:i64)<computes>:i64=F(N);A:i64=9");
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    scratch.initialise(inspector);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.write(&out, unused)));
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 17), json.value.object.get("format").?.integer);
    const exact = out.end;
    out = .fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.writeBounded(&out, unused, .{ .output_bytes = exact })));
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try inspector.writeBounded(&out, unused, .{ .output_bytes = exact - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
