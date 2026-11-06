//! Independent caught-failure, scope, quota, rollback and report oracles.
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
                std.debug.print("frame failure compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
        _ = try reporting.validate(reference.ok, false, .{});
        _ = try reporting.validate(actual.ok, false, .{});
        return actual;
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const r = try self.run(try self.compile(source), 131072);
        if (r == .failed) {
            std.debug.print("frame failure run {s}\n", .{r.failed.message()});
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

test "frame failures catch within defining frames and preserve root cell versions and allocation prefixes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Inner(N:i64)<computes>:i64=Attempt(If(Require[N>0],N+1,N),0)
        \\Outer(N:i64)<computes>:i64=Attempt(If(Require[Inner(N)>0],N+2,N),Attempt(Fail["雪"],9))
        \\Spread(N:i64)<computes>:i64=Attempt(Attempt(If(Require[N>0],N,N),Fail["inner"]),7)
        \\Build(L:logic)<computes>:[]i64=Attempt(If(array{Require[L]}.Length>0,array{1},array{2}),array{3,4})
        \\var Cell:i64=1;set Cell=2;A:i64=Outer(-1);B:i64=Outer(1);C:i64=Spread(-1)
        \\D:[]i64=Build(false);E:[]i64=Build(true);Value:i64=Cell
    );
    try std.testing.expectEqual(@as(i64, 9), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 6), x.failure_count);
    try std.testing.expectEqualStrings("雪", x.failures[2].reason.?);
    try std.testing.expectEqualStrings("inner", x.failures[4].reason.?);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("D").?).?.len);
    try std.testing.expectEqual(@as(usize, 1), x.elements(x.get("E").?).?.len);
    // The successful body's logic array remains physical storage after its
    // later selected array; failed Require created no incomplete constructor.
    try std.testing.expectEqual(@as(usize, 4), x.aggregate_values.len);
    for (x.failures) |trace| {
        try std.testing.expect(trace.function != null);
        const node = x.program.function_nodes[x.program.functions[trace.function.?].body.start + trace.pc].node;
        try std.testing.expectEqualDeep(node.span, trace.span);
        try std.testing.expect(x.program.nodes[trace.instruction].kind == .call);
    }
    const retained = try h.execute("F()<computes>:i64=Attempt(If(array{1,2}.Length>0,Fail[\"stop\"],0),7);A:i64=F()");
    try std.testing.expect(retained.activity.len == 0 and retained.failure_count == 1);
    try std.testing.expectEqual(@as(usize, 2), retained.aggregate_values.len);
}

test "frame failure traces order root and nested call failures across the bounded prefix" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F()<computes>:i64=Attempt(Fail[\"callee\"],1);G()<computes>:i64=F()+F();");
    for (0..14) |i| try out.print("A{d}:i64=Attempt(If(G()>0,Fail[\"root\"],0),2);", .{i});
    const x = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, 42), x.failure_count);
    try std.testing.expectEqual(@as(usize, 32), x.failures.len);
    for (x.failures, 0..) |trace, i| {
        try std.testing.expectEqual(i % 3 != 2, trace.function != null);
        try std.testing.expectEqualStrings(if (i % 3 == 2) "root" else "callee", trace.reason.?);
        if (i % 3 == 2) try std.testing.expectEqual(@as(u32, 0), trace.pc);
    }
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&writer, x, "root.forb", .{});
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "{\"format\":2,"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"local_instruction\":") != null);
    @memcpy(h.traces[0..x.failures.len], x.failures);
    var forged = x;
    forged.failures = h.traces[0..x.failures.len];
    for (0..32) |i| {
        const saved = h.traces[i];
        h.traces[i].instruction +%= 1;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        h.traces[i] = saved;
        h.traces[i].pc +%= 1;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        h.traces[i] = saved;
        h.traces[i].function = if (saved.function == null) 0 else null;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        h.traces[i] = saved;
        h.traces[i].reason = "foreign";
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        h.traces[i] = saved;
    }
    forged = x;
    forged.failure_count -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    const root = try h.execute("F()<computes>:logic=Attempt(Require[true],false);A:i64=Attempt(Fail[\"root\"],3)");
    writer = .fixed(&buffer);
    try trace_report.write(&writer, root, "root.forb", .{});
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "{\"format\":1,"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"local_instruction\":") == null);
    out = .fixed(&h.text);
    try out.writeAll("F()<computes>:i64=Attempt(Fail[\"late\"],1);");
    for (0..32) |i| try out.print("R{d}:i64=Attempt(Fail[\"root\"],0);", .{i});
    try out.writeAll("A:i64=F()");
    const late = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, 33), late.failure_count);
    for (late.failures) |trace| try std.testing.expect(trace.function == null);
    writer = .fixed(&buffer);
    try trace_report.write(&writer, late, "root.forb", .{});
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "{\"format\":2,"));
}

test "frame failure fuel is exact strict arguments remain fatal and storage recovers" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<computes>:i64=Attempt(If(Require[L],4,5),7);A:i64=F(false)");
    const x = (try h.run(p, 100)).ok;
    const exact: u32 = @intCast(p.nodes.len + x.call_steps.len);
    for (0..exact) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try h.run(p, exact)).ok.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.control_storage_required, evaluator.evaluateWithStorage(p, &h.values, &h.members, 100).failed.code);
    const strict = try h.compile("F(N:i64)<computes>:i64=Attempt(Fail[\"unused\"],7);A:i64=F(1/0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(strict, 100)).failed.code);
    const fatal = try h.compile("var Cell:i64=1;F()<computes>:i64=Attempt(If(Require[false],7,8),1/0);set Cell=2;A:i64=Attempt(F(),9)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(fatal, 100)).failed.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    try std.testing.expect(h.state.undo_count == 0 and h.runtime.machine.source.undo_count == 0);
    const clean = try h.execute("A:i64=3");
    try std.testing.expect(clean.call_steps.len == 0 and clean.failures.len == 0);
}

test "frame failures agree with 1000 independent nested scalar fallback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const n: i64 = @as(i64, @intCast(i % 17)) - 6;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(N:i64)<computes>:i64=Attempt(Attempt(If(Require[N>0],N+3,N),Fail[\"fallback\"]),9);G(N:i64)<computes>:i64=Attempt(If(Require[F(N)<10],N*2,N),7);A:i64=G({d});B:i64=F({d})", .{ n, n });
        const x = try h.execute(out.buffered());
        const inner = if (n > 0) n + 3 else 9;
        try std.testing.expectEqual(if (inner < 10) n * 2 else @as(i64, 7), x.get("A").?.integer);
        try std.testing.expectEqual(inner, x.get("B").?.integer);
        const failures: u32 = if (n <= 0) 4 else if (inner >= 10) 1 else 0;
        try std.testing.expectEqual(failures, x.failure_count);
        try std.testing.expect(x.activity.len == 0);
    }
}

test "frame failure results retain all Value kinds nominal module identities and defining UTF8 locations" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Mode:=enum{One,Two};Row:=struct{Name:string,Size:i64};Frozen:[]i64=array{9}
        \\A()<computes>:[]i64=Attempt(Fail["a"],Frozen)
        \\R()<computes>:Row=Attempt(Fail["r"],Row{Name:="雪",Size:=3})
        \\S()<computes>:string=Attempt(Fail["s"],"雪")
        \\F()<computes>:float=Attempt(Fail["f"],0.0/0.0)
        \\Z()<computes>:float=Attempt(Fail["z"],-0.0)
        \\E()<computes>:Mode=Attempt(Fail["e"],Mode.Two)
        \\T()<computes>:tuple(i64,string)=Attempt(Fail["t"],tuple{1,"雪"})
        \\O()<computes>:option(i64)=Attempt(Fail["o"],option{})
        \\M()<computes>:map(i64,string)=Attempt(Fail["m"],map{1=>"雪"})
        \\L()<computes>:logic=Attempt(Require[false],true)
        \\Items:[][]i64=array{A(),A()};Record:Row=R();Text:string=S();Float:float=F();Zero:float=Z()
        \\Enum:Mode=E();Tuple:tuple(i64,string)=T();Option:option(i64)=O();Map:map(i64,string)=M();Logic:logic=L()
    );
    try std.testing.expectEqual(@as(u32, 11), x.failure_count);
    const aliases = x.elements(x.get("Items").?).?;
    try std.testing.expectEqualDeep(aliases[0], aliases[1]);
    try std.testing.expect(std.math.isNan(x.get("Float").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expectEqualStrings("雪", x.get("Text").?.string);
    try std.testing.expect(x.get("Logic").?.boolean);
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Result:S.Row=S.Make(false)" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string}\nMake<public>(L:logic)<computes>:Row=Attempt(If(Require[L],Row{Name:=\"ok\"},Row{Name:=\"ok\"}),Row{Name:=\"雪\"})" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok;
    const result = (try h.run(p, 100)).ok;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, result, "wrong.forb", .{});
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    const trace = json.value.object.get("failures").?.array.items[0].object;
    try std.testing.expectEqualStrings("雪.forb", trace.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 2), trace.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 48), trace.get("column").?.integer);
    const inspect = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspect);
    out = .fixed(&buffer);
    try std.testing.expect((try inspect.write(&out, p)) == .ok);
    const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(i64, 12), report.value.object.get("format").?.integer);
    try std.testing.expect(report.value.object.get("functions").?.array.items[0].object.get("has_failure").?.bool);
}

test "frame failures independently reject malformed unused contexts metadata and tails before storage writes" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<computes>:i64=Attempt(If(Require[L],1+2,3+4),7);G(L:logic)<computes>:i64=F(L)+1;A:i64=9");
    var malformed = p;
    malformed.functions = h.metadata[0..p.functions.len];
    malformed.function_nodes = h.body[0..p.function_nodes.len];
    var attempt: usize = 0;
    var demand: usize = 0;
    for (p.function_nodes, 0..) |entry, i| {
        if (entry.node.kind == .attempt_begin) attempt = i;
        if (entry.node.kind == .demand) demand = i;
    }
    for (0..2000) |iteration| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (iteration % 8) {
            0 => h.metadata[0].has_failure = false,
            1 => h.metadata[1].has_failure = false,
            2 => h.metadata[0].has_control = false,
            3 => h.metadata[0].control_ops += 1,
            4 => {
                const branch = h.body[attempt].node.kind.attempt_begin;
                h.body[attempt].node.kind = .{ .if_begin = .{ .condition = 0, .alternative = branch.alternative, .end = branch.end } };
            },
            5 => h.body[demand].node.kind.demand = @intCast(demand),
            6 => h.body[attempt].node.kind.attempt_begin.condition = 0,
            else => h.metadata[0].root = @intCast(demand),
        }
        h.values[0] = .{ .integer = 91 };
        h.runtime.machine.values[0] = .{ .integer = 92 };
        h.control.call_count = 1;
        h.runtime.machine.control.call_count = 1;
        h.control.calls[0] = .{ .function = 0, .pc = 0, .value = .{ .integer = 93 } };
        h.runtime.machine.control.calls[0] = h.control.calls[0];
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(malformed, &h.values, &h.members, &h.control, &h.state, &h.frames, 0).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(malformed, &h.runtime.instructions).ok, 0).failed.code);
        try std.testing.expectEqual(@as(i64, 91), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 92), h.runtime.machine.values[0].integer);
        try std.testing.expectEqual(@as(usize, 1), h.control.call_count);
        try std.testing.expectEqual(@as(usize, 1), h.runtime.machine.control.call_count);
        try std.testing.expectEqual(@as(i64, 93), h.control.calls[0].value.integer);
    }
    malformed = p;
    malformed.function_nodes = p.function_nodes[0 .. p.function_nodes.len - 1];
    try std.testing.expect(evaluator.validate(malformed, p.nodes.len) != null);
    _ = try h.run(p, 100);
}

test "frame failure reports reject forged event kinds operands scopes schedules and borrowed strings before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(L:logic)<computes>:string=Attempt(If(Require[L],\"ok\",\"other\"),Attempt(Fail[\"雪\"],\"fallback\"));A:string=F(false)");
    var failure: usize = 0;
    var reason: usize = 0;
    for (x.call_steps, 0..) |event, i| if (event.kind == .failure) {
        if (event.value == .boolean) failure = i else reason = i;
    };
    var forged = x;
    var output: [4096]u8 = undefined;
    for (0..1000) |iteration| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (iteration % 8) {
            0 => h.steps[failure].kind = .value,
            1 => h.steps[0].kind = .failure,
            2 => h.steps[failure].value = .{ .boolean = true },
            3 => h.steps[reason].value = .{ .string = "foreign" },
            4 => h.steps[reason].function = 64,
            5 => h.steps[reason].pc = std.math.maxInt(u32),
            6 => forged.call_steps = h.steps[1..x.call_steps.len],
            else => std.mem.swap(types.CallStep, &h.steps[failure], &h.steps[reason]),
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    var out = std.Io.Writer.fixed(&output);
    const stats = try reporting.validate(x, false, .{});
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = stats.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    _ = try reporting.write(&out, x, false, .{ .work = stats.work });
}

test "frame failure catchers and calls have separate exact depth and event capacities" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 31, 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F()<computes>:i64=");
        for (0..depth) |_| try out.writeAll("Attempt(");
        try out.writeAll("Fail[\"deep\"]");
        for (0..depth) |_| try out.writeAll(",7)");
        try out.writeAll(";A:i64=F()");
        if (depth <= 32) {
            const x = try h.execute(out.buffered());
            try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
            try std.testing.expectEqual(@as(u32, 1), x.failure_count);
        } else try std.testing.expectEqual(types.Diagnostic.Code.control_limit, h.front.compile(out.buffered()).failed.code);
    }
    for ([_]usize{ 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F0()<computes>:i64=Attempt(Fail[\"bottom\"],7);");
        for (1..depth) |i| try out.print("F{d}()<computes>:i64=Attempt(F{d}(),8);", .{ i, i - 1 });
        try out.print("A:i64=F{d}()", .{depth - 1});
        const r = try h.run(try h.compile(out.buffered()), 1000);
        if (depth == 32) {
            try std.testing.expectEqual(@as(i64, 7), r.ok.get("A").?.integer);
            try std.testing.expectEqual(@as(u32, 1), r.ok.failure_count);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    var nested = std.Io.Writer.fixed(&h.text);
    try nested.writeAll("var Cell:i64=1;F()<computes>:i64=");
    for (0..32) |_| try nested.writeAll("Attempt(");
    try nested.writeAll("Fail[\"deep\"]");
    for (0..32) |_| try nested.writeAll(",7)");
    try nested.writeAll(";set Cell=2;A:i64=");
    for (0..32) |_| try nested.writeAll("Attempt(");
    try nested.writeAll("F()");
    for (0..32) |_| try nested.writeAll(",8)");
    try nested.writeAll(";Value:i64=Cell");
    const independent = try h.execute(nested.buffered());
    try std.testing.expectEqual(@as(i64, 2), independent.get("Value").?.integer);
    for ([_]bool{ false, true }) |extra| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F()<computes>:i64=Attempt(Fail[\"x\"],7);G()<computes>:i64=If(false,1,2);Items:[]i64=array{");
        for (0..1636) |i| try out.print("{s}F()", .{if (i == 0) "" else ","});
        try out.writeAll(",G(),G(),G()");
        if (extra) try out.writeAll(",F()");
        try out.writeAll("};A:i64=Items.Length");
        const p = try h.compile(out.buffered());
        const r = try h.run(p, 131072);
        if (!extra) {
            try std.testing.expectEqual(@as(usize, 8192), r.ok.call_steps.len);
            try std.testing.expectEqual(@as(u32, 1636), r.ok.failure_count);
            const exact: u32 = @intCast(p.nodes.len + r.ok.call_steps.len + p.members.len);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, exact - 1)).failed.code);
            try std.testing.expectEqual(@as(usize, 8192), (try h.run(p, exact)).ok.call_steps.len);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
    }
}

test "frame failure admission retains failed-body constructors and checks hidden maps before hashing borrowed strings" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F()<computes>:i64=Attempt(If(array{1,2,3}.Length>0,Fail[\"stop\"],0),7);A:i64=F()");
    for (0..4) |capacity| {
        @memset(h.members[0..4], .{ .integer = 99 });
        const r = evaluator.evaluateWithRuntimeStorage(p, &h.values, h.members[0..capacity], &h.control, &h.state, &h.frames, 100);
        if (capacity < 3) {
            try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
            try std.testing.expectEqual(@as(i64, 99), h.members[0].integer);
            try std.testing.expect(h.control.call_count == 0 and h.control.failure_count == 0);
        } else {
            try std.testing.expectEqual(@as(u32, 1), r.ok.failure_count);
            try std.testing.expectEqual(@as(usize, 3), r.ok.aggregate_values.len);
            _ = try reporting.validate(r.ok, false, .{});
        }
    }
    const x = try h.execute("Make()<computes>:map(i64,string)=map{1+0=>\"a\",3+0=>\"b\"};Discard(M:map(i64,string))<computes>:i64=Attempt(Fail[\"stop\"],7);F()<computes>:i64=Discard(Make());A:i64=F()");
    @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    var forged = x;
    forged.aggregate_values = h.members[0..x.aggregate_values.len];
    forged.call_steps = h.steps[0..x.call_steps.len];
    h.members[2] = .{ .integer = 1 };
    for (h.steps[0..x.call_steps.len]) |*event| {
        const entry = x.program.function_nodes[x.program.functions[event.function].body.start + event.pc];
        if (entry.input == .operation and entry.node.kind == .binary and event.value.integer == 3) event.value.integer = 1;
    }
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    h.members[1] = .{ .string = "foreign" };
    out = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
