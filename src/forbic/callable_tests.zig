//! Typed callable values, dynamic cycles, effect, lifetime and admission oracles.
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
                std.debug.print("callable compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("callable run {s}\n", .{r.failed.message()});
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

test "callable literals pass return select and invoke exact immutable signatures" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Double(X:i64)<computes>:i64=X*2;Apply(F:function(tuple(i64),i64),X:i64)<computes>:i64=F(X);Choose(B:logic)<computes>:function(tuple(i64),i64)=If(B,Inc,Double);F:function(tuple(i64),i64)=Inc;A:i64=F(41);B:i64=Apply(Double,21);C:i64=Choose(false)(21);D:i64=If(false,Inc,Double)(21)");
    for ([_][]const u8{ "A", "B", "C", "D" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expect(x.get("F").? == .callable);
    try std.testing.expect(x.call_steps.len != 0);
}

test "callable alias bodies publish once and direct template calls retain their behavior" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Keep(X:i64)<computes>:i64=X;A:i64=Keep(42);F:function(tuple(i64),i64)=Keep;G:function<computes>(tuple(i64),i64)=Keep;B:i64=F(7);C:i64=Iterate(Keep,4,G(8));Zero()<computes>:tuple()=tuple{};Z:function(tuple(),tuple())=Zero;Unit:tuple()=Z()");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("C").?.integer);
    try std.testing.expectEqual(@as(usize, 2), x.program.functions.len);
    try equal(x.get("F").?, x.get("G").?);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("Unit").?).?.len);
}

test "callable aggregate storage and definition-site defaults survive completed guest frames" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Box:=struct{F:function(tuple(i64),i64)=Inc};Make()<computes>:Box=Box{};B:Box=Make();A:i64=B.F(41);Pair:tuple(function(tuple(i64),i64),string)=tuple{Inc,\"雪\"};C:i64=Pair(0)(41);Items:[]function(tuple(i64),i64)=array{Inc};O:option(function(tuple(i64),i64))=option{Inc};M:map(string,function(tuple(i64),i64))=map{\"inc\"=>Inc};D:i64=Or(Lookup(M,\"inc\"),Inc)(41);E:i64=Or(O,Inc)(41)");
    for ([_][]const u8{ "A", "C", "D", "E" }) |name| try std.testing.expectEqual(@as(i64, 42), x.get(name).?.integer);
    try std.testing.expectEqualStrings("雪", x.elements(x.get("Pair").?).?[1].string);
    const returned = x.elements(x.get("B").?).?[0];
    try std.testing.expect(returned == .callable);
    try std.testing.expectEqual(@as(u32, 0), returned.callable.function);
}

test "callable self references allow bounded dynamic cycles through earlier helpers" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Apply(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);Later(N:i64)<computes>:i64=If(N==0,42,Apply(Later,N-1));A:i64=Later(9);F:function(tuple(i64),i64)=Later;B:i64=F(9)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    const overflow = try h.compile("Apply(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);Later(N:i64)<computes>:i64=Apply(Later,N);A:i64=Later(0)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(overflow, 1000)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "callable selection precedes strict arguments and captures immutable snapshots" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("First(X:i64,Y:i64)<computes>:i64=X;Second(X:i64,Y:i64)<computes>:i64=Y;var F:function(tuple(i64,i64),i64)=First;var C:i64=0;Change()<transacts>:i64=Block{set F=Second;set C=C+1;41};A:i64=F(Change(),Set(C,42));B:i64=F(7,42);After:i64=C");
    try std.testing.expectEqual(@as(i64, 41), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("After").?.integer);
    const y = try h.execute("Inc(X:i64)<computes>:i64=X+1;Twice(X:i64)<computes>:i64=X*2;F(Arg:function(tuple(i64),i64))<computes>:i64=Block{Local:function(tuple(i64),i64)=Arg;Local(21)};A:i64=F(Twice)");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
}

test "callable transacts decides local catches and root rollback share source state" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=1;Visit(N:i64)<transacts><decides>:i64=Block{set C=C+N;Require[N>0];C};F:function<transacts><decides>(tuple(i64),i64)=Visit;Caller(H:function<transacts><decides>(tuple(i64),i64),N:i64)<transacts>:i64=Attempt(Block{set C=C+10;H[N]},C);A:i64=Attempt(F[2],42);B:i64=Attempt(F[-2],42);D:i64=Caller(F,0);After:i64=C");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("After").?.integer);
    try std.testing.expectEqual(@as(u32, 2), x.failure_count);
    const y = try h.execute("Inc(X:i64)<computes>:i64=X+1;Twice(X:i64)<computes>:i64=X*2;Choose()<transacts>:i64=Block{var F:function(tuple(i64),i64)=Inc;Ignored:i64=Attempt(Block{set F=Twice;Fail[\"雪\"];0},0);F(41)};A:i64=Choose()");
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
}

test "callable transacts metadata requires source regions even without declared cells" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:i64)<transacts>:i64=X;Apply(H:function<transacts>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(H(X),42);A:i64=Apply(F,7)");
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithControlStorage(p, &h.values, &h.members, &h.control, 1000).failed.code);
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(usize, 0), x.program.source_cells.len);
}

test "callable effects exact arity comparability and malformed annotations are checked even unused" {
    const h = try create();
    defer scratch.release(h);
    for ([_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "F(X:i64)<computes>:i64=X;A:function(tuple(logic),i64)=F", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;A:function(tuple(i64),logic)=F", .code = .type_mismatch },
        .{ .source = "F(X:i64)<transacts>:i64=X;A:function<reads>(tuple(i64),i64)=F", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes><decides>:i64=X;A:function(tuple(i64),i64)=F", .code = .type_mismatch },
        .{ .source = "G(F:function<transacts>(tuple(i64),i64))<computes>:i64=F(1)", .code = .call_requires_transacts },
        .{ .source = "G(F:function<computes><decides>(tuple(i64),i64))<computes>:i64=F[1]", .code = .failure_context_required },
        .{ .source = "F(X:i64)<computes>:i64=X;V:function(tuple(i64),i64)=F;A:i64=V()", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;V:function(tuple(i64),i64)=F;A:i64=V(1,2)", .code = .argument_count },
        .{ .source = "F(X:i64)<computes>:i64=X;V:function(tuple(i64),i64)=F;A:i64=V(true)", .code = .type_mismatch },
        .{ .source = "F(X:i64)<computes>:i64=X;V:function(tuple(i64),i64)=F;A:i64=V[1]", .code = .expected_call },
        .{ .source = "F(X:i64)<computes><decides>:i64=X;V:function<computes><decides>(tuple(i64),i64)=F;A:i64=Attempt(V(1),2)", .code = .expected_call },
        .{ .source = "F(X:i64)<computes>:i64=X;A:logic=F==F", .code = .not_comparable },
        .{ .source = "A:map(function(tuple(i64),i64),i64)=map{}", .code = .invalid_map_key },
        .{ .source = "A:function(i64,i64)=0", .code = .unsupported_type },
        .{ .source = "A:function(tuple(i64))=0", .code = .expected_type },
        .{ .source = "A:function(tuple(),i64,logic)=0", .code = .expected_type },
        .{ .source = "A:function<decides>(tuple(),i64)=0", .code = .unsupported_specifier },
        .{ .source = "A:function<computes><transacts>(tuple(),i64)=0", .code = .effect_specifier_conflict },
        .{ .source = "A:function(tuple(),i64)=Later;Later()<computes>:i64=1", .code = .unknown_name },
    }) |c| {
        const r = h.front.compile(c.source);
        if (r != .failed or r.failed.code != c.code) std.debug.print("callable negative expected {s}: {s}\n", .{ @tagName(c.code), c.source });
        try std.testing.expectEqual(c.code, r.failed.code);
    }
}

test "callable signatures retain all Value kinds and exact sixteen parameter calls" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Mode:=enum{A,B};Box:=struct{F:function(tuple(float),float)};Float(X:float)<computes>:float=X;Text(X:string)<computes>:string=X;Enum(X:Mode)<computes>:Mode=X;Empty(X:[]i64)<computes>:[]i64=X;Keep(X:Box)<computes>:Box=X;F:function(tuple(float),float)=Float;N:float=F(NaN);Z:float=F(-0.0);T:function(tuple(string),string)=Text;S:string=T(\"雪\");E:function(tuple(Mode),Mode)=Enum;M:Mode=E(Mode.B);A:function(tuple([]i64),[]i64)=Empty;V:[]i64=A(array{});B:function(tuple(Box),Box)=Keep;R:Box=B(Box{F:=Float});Q:float=R.F(42.0)");
    try std.testing.expect(std.math.isNan(x.get("N").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Z").?.floating)));
    try std.testing.expectEqualStrings("雪", x.get("S").?.string);
    try std.testing.expectEqual(@as(u32, 1), x.get("M").?.enumeration.index);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("V").?).?.len);
    try std.testing.expectEqual(@as(f64, 42), x.get("Q").?.floating);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F(");
    for (0..16) |i| try out.print("{s}P{d}:i64", .{ if (i == 0) "" else ",", i });
    try out.writeAll(")<computes>:i64=P15;V:function(tuple(");
    for (0..16) |i| try out.writeAll(if (i == 0) "i64" else ",i64");
    try out.writeAll("),i64)=F;A:i64=V(");
    for (0..16) |i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", i + 27 });
    try out.writeAll(")");
    const y = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 42), y.get("A").?.integer);
}

test "callable unused bodies independently reject signature pool effect and metadata forgeries" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Inc(X:i64)<computes>:i64=X+1;Apply(F:function<transacts><decides>(tuple(i64),i64),X:i64)<transacts><decides>:i64=If(X==0,42,F[X]);Spin(X:i64)<computes>:i64=Block{F:function(tuple(i64),i64)=Spin;F(X)};A:i64=9");
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    const args = try std.testing.allocator.dupe(u32, p.function_arguments);
    defer std.testing.allocator.free(args);
    forged.function_arguments = args;
    var invoke: usize = 0;
    var self_ref: usize = 0;
    var other_arm: u32 = 0;
    for (p.function_nodes, 0..) |entry, i| {
        if (entry.node.kind == .invoke and i < p.functions[1].body.end) invoke = i;
        if (entry.node.kind == .self_value) self_ref = i;
        if (entry.node.kind == .integer and entry.node.kind.integer == 42) other_arm = @intCast(i - p.functions[1].body.start);
    }
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        @memcpy(args, p.function_arguments);
        switch (i % 14) {
            0 => h.metadata[1].transacts = false,
            1 => h.metadata[1].decides = false,
            2 => h.metadata[1].has_control = false,
            3 => h.metadata[1].has_failure = false,
            4 => h.metadata[1].has_source = false,
            5 => h.metadata[1].has_local = false,
            6 => h.metadata[1].member_work = 0,
            7 => h.body[invoke].node.kind.invoke.arguments.end += 1,
            8 => h.body[invoke].node.kind.invoke.arguments.start += 1,
            9 => h.body[invoke].node.kind.invoke.callable = @intCast(invoke - p.functions[1].body.start),
            10 => args[0] = other_arm,
            11 => h.body[self_ref].node.value_type = .i64,
            12 => h.body[self_ref].node.kind = .{ .function_value = 2 },
            13 => h.metadata[2].parameters[0] = .logic,
            else => unreachable,
        }
        try invalid(h, forged);
    }
}

test "callable raw report descriptors copied inputs and exact budgets precede output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Inc(X:i64)<computes>:i64=X+1;Double(X:i64)<computes>:i64=X*2;Apply(F:function(tuple(i64),i64),X:i64)<computes>:i64=F(X);F:function(tuple(i64),i64)=Inc;A:i64=Apply(F,41)");
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try reporting.write(&out, x, false, .{});
    try std.testing.expectEqualStrings("{\"F\":{\"function\":{\"name\":\"Inc\",\"module\":null}},\"A\":42}\n", out.buffered());
    out = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const values = try std.testing.allocator.dupe(types.Value, x.values);
    defer std.testing.allocator.free(values);
    var forged = x;
    forged.values = values;
    forged.call_steps = h.steps[0..x.call_steps.len];
    const root = x.program.bindings[0].node;
    var parameter: usize = 0;
    for (x.call_steps, 0..) |event, i| if (event.value == .callable) {
        parameter = i;
        break;
    };
    for (0..1000) |i| {
        @memcpy(values, x.values);
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        switch (i % 5) {
            0 => values[root].callable.function = 999,
            1 => values[root].callable.value_type = .i64,
            2 => values[root].callable.function = 1,
            3 => h.steps[parameter].value.callable.function = 1,
            4 => h.steps[x.call_steps.len - 1].pc += 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
}

test "callable fuel prefixes fatal rollback and healthy reuse agree across engines" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=1;F(X:i64)<transacts>:i64=Block{set C=C+X;C};V:function<transacts>(tuple(i64),i64)=F;A:i64=V(41)");
    var first: ?u32 = null;
    for (0..100) |fuel| {
        const r = try h.run(p, @intCast(fuel));
        if (r == .ok) {
            first = @intCast(fuel);
            try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer);
            break;
        }
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, r.failed.code);
        try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    }
    try std.testing.expect(first != null);
    const funded = (try h.run(p, first.?)).ok;
    var roots: usize = 0;
    for (funded.activity) |active| if (active) {
        roots += 1;
    };
    try std.testing.expectEqual(@as(usize, first.?), roots + funded.call_steps.len);
    const fatal = try h.compile("var C:i64=1;F(X:i64)<transacts>:i64=Block{set C=C+1;X/0};V:function<transacts>(tuple(i64),i64)=F;A:i64=Attempt(V(1),42)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(fatal, 1000)).failed.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    _ = try h.execute("A:i64=42");
}

test "callable module privacy nominal signature export and inspection eighteen admit unused types" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=S.Inc;A:i64=F(41)" },
        .{ .path = "雪.forb", .source = "Inc<public>(N:i64)<computes>:i64=N+1;Hidden(N:i64)<computes>:i64=N" },
    };
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok, 1000)).ok;
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expectEqualStrings("{\"F\":{\"function\":{\"name\":\"Inc\",\"module\":\"雪.forb\"}},\"A\":42}\n", out.buffered());
    var private = files;
    private[0].source = "S:=import{\"雪.forb\"};F:function(tuple(i64),i64)=S.Hidden";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    private[0].source = "S:=import{\"雪.forb\"};A:i64=9";
    private[1].source = "Hidden:=struct{N:i64};F<public>(X:function(tuple(Hidden),i64))<computes>:i64=1";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &private }).failed.diagnostic.code);
    const unused = try h.compile("F(X:function(tuple(i64),i64))<computes>:i64=1;A:i64=9");
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    scratch.initialise(inspector);
    out = .fixed(&buffer);
    try std.testing.expect(try inspector.write(&out, unused) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":18,"));
}

test "callable repeated dispatch admits exactly 8192 events and rejects the next visit" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Keep(X:i64)<computes>:i64=X;Step(X:i64)<computes>:i64=Block{F:function(tuple(i64),i64)=Keep;F(X)};A:i64=Iterate(Step,2048,42)");
    try std.testing.expectEqual(@as(usize, types.limits.call_steps), x.call_steps.len);
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    const too_many = try h.compile("Keep(X:i64)<computes>:i64=X;Step(X:i64)<computes>:i64=Block{F:function(tuple(i64),i64)=Keep;F(X)};A:i64=Iterate(Step,2049,42)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(too_many, 20000)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "callable dynamic aggregate constructors retain exactly bounded physical storage" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("Make(X:i64)<computes>:[]i64=Block{Value:i64=X;array{");
    for (0..256) |i| try out.writeAll(if (i == 0) "Value" else ",Value");
    try out.writeAll("}};F:function(tuple(i64),[]i64)=Make;Step(X:i64)<computes>:i64=Block{A:[]i64=F(X);A.Length};A:i64=Iterate(Step,32,0)");
    const x = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(usize, types.limits.aggregate_elements), x.aggregate_values.len);
    try std.testing.expectEqual(@as(i64, 256), x.get("A").?.integer);
    out = .fixed(&h.text);
    try out.writeAll("Make(X:i64)<computes>:[]i64=Block{Value:i64=X;array{");
    for (0..256) |i| try out.writeAll(if (i == 0) "Value" else ",Value");
    try out.writeAll("}};F:function(tuple(i64),[]i64)=Make;Step(X:i64)<computes>:i64=Block{A:[]i64=F(X);A.Length};A:i64=Iterate(Step,33,0)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, (try h.run(p, 20000)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "callable effects free references and 1000 independent source selection oracles" {
    const h = try create();
    defer scratch.release(h);
    _ = try h.execute("F(X:i64)<transacts><decides>:i64=Block{Require[X>0];X};Take()<computes>:function<transacts><decides>(tuple(i64),i64)=F;V:function<transacts><decides>(tuple(i64),i64)=Take();A:i64=42");
    for (0..1000) |i| {
        const n = i % 7 + 1;
        const selected = i % 2 == 0;
        const negative = i % 3 == 0;
        const increment: i64 = if (selected) 1 else 2;
        const delta: i64 = if (negative) -@as(i64, @intCast(n)) else @intCast(n);
        const expected: i64 = if (negative) 10 else 10 + increment * delta;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64=10;One(N:i64)<transacts><decides>:i64=Block{{set C=C+N;Require[N>0];C}};Two(N:i64)<transacts><decides>:i64=Block{{set C=C+2*N;Require[N>0];C}};F:function<transacts><decides>(tuple(i64),i64)=If({s},One,Two);A:i64=Attempt(F[{d}],C);After:i64=C", .{ if (selected) "true" else "false", delta });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(expected, x.get("After").?.integer);
        try std.testing.expectEqual(@as(u32, if (negative) 1 else 0), x.failure_count);
    }
}

test "callable root references signatures availability and bytecode dispatch admit whole tails" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(X:i64)<computes>:i64=X+1;V:function(tuple(i64),i64)=F;A:i64=V(41)");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    const args = try std.testing.allocator.dupe(u32, p.call_arguments);
    defer std.testing.allocator.free(args);
    var forged = p;
    forged.nodes = nodes;
    forged.definitions = definitions;
    forged.functions = h.metadata[0..p.functions.len];
    forged.call_arguments = args;
    const literal = p.bindings[0].node;
    const invocation = p.bindings[1].node;
    const signature = @backingInt(p.nodes[literal].value_type) - 4;
    for (0..1000) |i| {
        @memcpy(nodes, p.nodes);
        @memcpy(definitions, p.definitions);
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(args, p.call_arguments);
        switch (i % 10) {
            0 => nodes[literal].kind.function_value = 999,
            1 => nodes[literal].kind = .self_value,
            2 => nodes[invocation].kind.invoke.callable = invocation,
            3 => nodes[invocation].kind.invoke.arguments.end += 1,
            4 => args[0] = invocation,
            5 => definitions[signature].callable.result = .logic,
            6 => definitions[signature].callable.transacts = true,
            7 => definitions[signature].callable.parameters = .i64,
            8 => h.metadata[0].available_at = literal + 1,
            9 => definitions[signature].callable.result = p.nodes[literal].value_type,
            else => unreachable,
        }
        try invalid(h, forged);
    }
    var bc = bytecode.lower(p, &h.runtime.instructions).ok;
    h.runtime.instructions[invocation].op.invoke.callable = invocation;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bc, 0).failed.code);
    bc = bytecode.lower(p, &h.runtime.instructions).ok;
    h.runtime.instructions[literal].op.function_value = 999;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bc, 0).failed.code);
}

test "callable dynamic self dispatch admits exact frame and live register boundaries" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "Spin(N:i64)<computes>:i64=Block{F:function(tuple(i64),i64)=Spin;";
    const tail = "If(N==0,42,F(N-1))};V:function(tuple(i64),i64)=Spin;";
    const x = try h.execute(prefix ++ tail ++ "A:i64=V(31)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(try h.compile(prefix ++ tail ++ "A:i64=Attempt(V(32),0)"), 1000)).failed.code);
    const base = try h.compile(prefix ++ tail ++ "A:i64=V(15)");
    const length = base.functions[0].body.end - base.functions[0].body.start;
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll(prefix);
    for (0..512 - length) |_| try out.writeAll("0;");
    try out.writeAll(tail);
    const end = out.end;
    try out.writeAll("A:i64=V(15)");
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(@as(u32, 512), p.functions[0].body.end - p.functions[0].body.start);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(p, 32768)).ok.get("A").?.integer);
    out.end = end;
    try out.writeAll("A:i64=V(16)");
    try std.testing.expectEqual(types.Diagnostic.Code.call_register_limit, (try h.run(try h.compile(out.buffered()), 32768)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "callable empty source regions retain exact combined nesting and reject forged success" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const prefix = "F(X:i64)<transacts>:i64=X;G(H:function<transacts>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(H(X),0);A:i64=";
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
    // Forge the successful masks/typed values at the otherwise valid 32-root
    // schedule. Replay must count the empty shared source region in G too.
    for (p.nodes, 0..) |node, i| {
        h.values[i] = switch (node.value_type) {
            .i64 => .{ .integer = 42 },
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

test "callable structural signatures reuse the exact full type catalogue before quota rejection" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    for (0..254) |i| try out.print("R{d}:=struct{{}};", .{i});
    try out.writeAll("F()<computes>:i64=42;V:function(tuple(),i64)=F;W:function<computes>(tuple(),i64)=F;A:i64=V()+W()");
    const full = out.end;
    const x = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(usize, types.limits.user_types), x.program.definitions.len);
    try std.testing.expectEqual(@as(i64, 84), x.get("A").?.integer);
    out.end = full;
    try out.writeAll(";G(X:function<transacts>(tuple(),i64))<computes>:i64=1");
    try std.testing.expectEqual(types.Diagnostic.Code.type_limit, h.front.compile(out.buffered()).failed.code);
}

test "callable indirect IR argument ranges admit exact 8192 operands and reject an oversized pool" {
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("First(");
    for (0..16) |i| try out.print("{s}P{d}:i64", .{ if (i == 0) "" else ",", i });
    try out.writeAll(")<computes>:i64=P0;Step(F:function(tuple(");
    for (0..16) |i| try out.writeAll(if (i == 0) "i64" else ",i64");
    try out.writeAll("),i64),X:i64)<computes>:i64=Block{L:function(tuple(");
    for (0..16) |i| try out.writeAll(if (i == 0) "i64" else ",i64");
    try out.writeAll("),i64)=F;V:i64=X;");
    for (0..256) |_| {
        try out.writeAll("L(");
        for (0..16) |i| try out.writeAll(if (i == 0) "V" else ",V");
        try out.writeAll(");");
    }
    try out.writeAll("V};A:i64=Step(First,42)");
    const base = try h.compile(out.buffered());
    // Source token admission precedes a 512-call spelling. Exercise the larger
    // valid typed IR graph directly, with independent IR/bytecode admission.
    try std.testing.expectEqual(@as(usize, 4096), base.function_arguments.len);
    var p = base;
    const args = try std.testing.allocator.alloc(u32, types.limits.call_arguments + 1);
    defer std.testing.allocator.free(args);
    @memcpy(args[0..4096], base.function_arguments);
    @memcpy(args[4096..8192], base.function_arguments);
    @memcpy(h.metadata[0..base.functions.len], base.functions);
    const step = base.functions[0];
    const length = step.body.end - step.body.start;
    @memcpy(h.body[0..length], base.function_nodes[0..length]);
    var prototype: types.FunctionNode = undefined;
    for (base.function_nodes[0..length]) |entry| if (entry.node.kind == .invoke) {
        prototype = entry;
        break;
    };
    for (0..256) |i| {
        h.body[length + i] = prototype;
        h.body[length + i].node.kind.invoke.arguments = .{ .start = @intCast(4096 + i * 16), .end = @intCast(4096 + (i + 1) * 16) };
    }
    @memcpy(h.body[length + 256 .. base.function_nodes.len + 256], base.function_nodes[length..]);
    h.metadata[0].body.end += 256;
    h.metadata[0].control_ops += 256;
    for (h.metadata[1..base.functions.len]) |*f| {
        f.body.start += 256;
        f.body.end += 256;
    }
    p.functions = h.metadata[0..base.functions.len];
    p.function_nodes = h.body[0 .. base.function_nodes.len + 256];
    p.function_arguments = args[0..8192];
    const x = (try h.run(p, 8192)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    args[8192] = 0;
    p.function_arguments = args;
    try invalid(h, p);
    _ = try h.execute("A:i64=42");
}
