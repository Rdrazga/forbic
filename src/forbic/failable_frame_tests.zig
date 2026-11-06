//! Independent cross-frame propagation, outcome, rollback and report oracles.
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
                std.debug.print("failable frame compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("failable frame run {s}\n", .{r.failed.message()});
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

test "failable report retains unreturned constructors and checks every borrow and copied member before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make()<computes>:map(i64,string)=map{1+0=>\"a\",3+0=>\"b\"};F()<computes><decides>:i64=If(Make().Length>0,Fail[\"stop\"],0);G()<computes><decides>:i64=F[];A:i64=Attempt(G[],7)");
    try std.testing.expectEqual(@as(usize, 4), x.aggregate_values.len);
    try std.testing.expectEqual(@as(u32, 1), x.failure_count);
    @memcpy(h.members[0..4], x.aggregate_values);
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    var forged = x;
    forged.aggregate_values = h.members[0..4];
    forged.call_steps = h.steps[0..x.call_steps.len];
    h.members[2] = .{ .integer = 1 };
    for (h.steps[0..x.call_steps.len]) |*event| if (event.kind == .value) {
        const entry = x.program.function_nodes[x.program.functions[event.function].body.start + event.pc];
        if (entry.input == .operation and entry.node.kind == .binary and event.value.integer == 3) event.value.integer = 1;
    };
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    h.members[1] = .{ .string = "foreign" };
    out = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const admitted = try reporting.validate(x, false, .{});
    out = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const root = try h.execute("A:[]i64=array{1,2}");
    @memcpy(h.members[0..2], root.aggregate_values);
    forged = root;
    forged.aggregate_values = h.members[0..2];
    h.members[1] = .{ .integer = 1 };
    out = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "failable frames propagate one defining origin through callers and restore only the selected root region" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Leaf(N:i64)<computes><decides>:i64=If(Require[N>=0],N+1,Fail["negative"])
        \\Chain(N:i64)<computes><decides>:i64=Leaf[N]+10
        \\Catch(N:i64)<computes>:i64=Attempt(Chain[N],7)
        \\Escape(N:i64)<computes><decides>:i64=Attempt(Leaf[N],Fail["fallback"])
        \\First(X:i64,Y:i64)<computes>:i64=X
        \\var Cell:i64=1;set Cell=2;A:i64=Catch(-1);B:i64=Attempt(Chain[-1],8)
        \\C:i64=Attempt(Escape[-1],9);D:i64=Catch(2)
        \\E:i64=Attempt(First(Set(Cell,3),Chain[-1]),Cell);Value:i64=Cell
    );
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 13), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 5), x.failure_count);
    var origins: usize = 0;
    var propagated: usize = 0;
    var roots: usize = 0;
    for (x.call_steps) |event| switch (event.kind) {
        .failure => origins += 1,
        .propagate => propagated += 1,
        .root_failure => {
            roots += 1;
            try std.testing.expect(!x.active(event.pc));
            try std.testing.expect(x.program.nodes[event.pc].kind == .call);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), origins);
    try std.testing.expectEqual(@as(usize, 5), propagated);
    try std.testing.expectEqual(@as(usize, 3), roots);
    try std.testing.expectEqualStrings("fallback", x.failures[3].reason.?);
    try std.testing.expectEqual(@as(?u32, 3), x.failures[3].function);
    for (x.failures) |trace| try std.testing.expect(trace.function != null);
}

test "failable frame continuations bound depth count the origin once and leave fatal errors uncaught" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 1, 2, 31, 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F0()<computes><decides>:i64=Fail[\"雪\"];");
        for (1..depth) |i| try out.print("F{d}()<computes><decides>:i64=F{d}[]+1;", .{ i, i - 1 });
        try out.print("A:i64=Attempt(F{d}[],7)", .{depth - 1});
        const r = try h.run(try h.compile(out.buffered()), 1000);
        if (depth == 33) {
            try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
        } else {
            try std.testing.expectEqual(@as(i64, 7), r.ok.get("A").?.integer);
            try std.testing.expectEqual(@as(u32, 1), r.ok.failure_count);
            try std.testing.expectEqual(@as(?u32, 0), r.ok.failures[0].function);
            var propagation: usize = 0;
            for (r.ok.call_steps) |event| if (event.kind == .propagate) {
                propagation += 1;
            };
            try std.testing.expectEqual(depth - 1, propagation);
        }
    }
    const fatal = try h.compile("var Cell:i64=1;F()<computes><decides>:i64=1/0;set Cell=2;A:i64=Attempt(F[],7)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(fatal, 100)).failed.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    const strict = try h.compile("F(N:i64)<computes><decides>:i64=7;A:i64=Attempt(F[1/0],9)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(strict, 100)).failed.code);
    _ = try h.execute("A:i64=42");
}

test "failable frame reports admit exact terminal pressure and fatal continuation quota clears all evidence" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]bool{ false, true }) |extra| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Step(N:i64)<computes>:i64=N+1;Throw()<computes><decides>:[]i64=array{");
        for (0..1637) |i| try out.print("{s}Step(0)", .{if (i == 0) "" else ","});
        try out.writeAll(",0,0,0,0");
        if (extra) try out.writeAll(",0");
        try out.writeAll(",Fail[\"stop\"]};var Cell:i64=1;set Cell=2;A:[]i64=Attempt(Throw[],array{})");
        const p = try h.compile(out.buffered());
        const r = try h.run(p, 131072);
        if (extra) {
            try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
            try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
        } else {
            const x = r.ok;
            try std.testing.expectEqual(@as(usize, 8192), x.call_steps.len);
            try std.testing.expectEqual(@as(u32, 1), x.failure_count);
            try std.testing.expectEqual(@as(usize, 0), x.aggregate_values.len);
            try std.testing.expectEqual(.root_failure, x.call_steps[8191].kind);
            try std.testing.expectEqual(.failure, x.call_steps[8190].kind);
            var fuel: u64 = @intCast(x.call_steps.len);
            for (0..x.values.len) |i| if (x.active(i)) {
                fuel += 1;
            };
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, fuel - 1)).failed.code);
            try std.testing.expectEqual(@as(usize, 8192), (try h.run(p, fuel)).ok.call_steps.len);
        }
    }
}

test "failable frame reports reject forged propagated causes root termination and missing visited calls before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F()<computes><decides>:i64=Fail[\"雪\"];G()<computes><decides>:i64=F[]+1;A:i64=Attempt(G[],7)");
    var propagated: usize = 0;
    for (x.call_steps, 0..) |event, i| if (event.kind == .propagate) {
        propagated = i;
    };
    var forged = x;
    var buffer: [1024]u8 = undefined;
    for (0..1000) |iteration| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (iteration % 8) {
            0 => h.steps[propagated].kind = .failure,
            1 => h.steps[propagated].value = .{ .boolean = false },
            2 => h.steps[propagated].value = .{ .string = "foreign" },
            3 => h.steps[propagated].pc +%= 1,
            4 => h.steps[x.call_steps.len - 1].function = 0,
            5 => h.steps[x.call_steps.len - 1].pc +%= 1,
            6 => forged.call_steps = h.steps[0 .. x.call_steps.len - 1],
            else => {
                h.steps[x.call_steps.len] = h.steps[0];
                forged.call_steps = h.steps[0 .. x.call_steps.len + 1];
            },
        }
        var out = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
}

test "failable frames independently enforce declared contexts even for pure callees and unused unmarked callers" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Nop()<computes><decides>:i64=7;F()<computes><decides>:i64=Nop[];A:i64=Attempt(F[],0)");
    try std.testing.expect(p.functions.len == 2 and !p.functions[1].has_control);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    var malformed = p;
    malformed.functions = h.metadata[0..p.functions.len];
    h.metadata[1].decides = false;
    try invalid(h, malformed);
    // A raw root call to a declared decides helper needs a context even if
    // no visited opcode in that helper can actually fail.
    var root_node: types.Node = undefined;
    for (p.nodes) |node| if (node.kind == .call) {
        root_node = node;
    };
    var binding = p.bindings[0];
    binding.node = 0;
    malformed = p;
    malformed.nodes = @as(*const [1]types.Node, &root_node);
    malformed.bindings = @as(*const [1]types.Binding, &binding);
    malformed.control_ops = 0;
    try invalid(h, malformed);
    const unused = try h.compile("F(L:logic)<computes><decides>:i64=If(Require[L],7,Fail[\"x\"]);A:i64=9");
    malformed = unused;
    malformed.functions = h.metadata[0..unused.functions.len];
    for (0..2000) |i| {
        @memcpy(h.metadata[0..unused.functions.len], unused.functions);
        switch (i % 4) {
            0 => h.metadata[0].decides = false,
            1 => h.metadata[0].has_failure = false,
            2 => h.metadata[0].has_control = false,
            else => h.metadata[0].control_ops += 1,
        }
        try invalid(h, malformed);
    }
    _ = try h.run(unused, 100);
}
fn invalid(h: *Harness, p: types.Program) !void {
    h.values[0] = .{ .integer = 91 };
    h.runtime.machine.values[0] = .{ .integer = 92 };
    h.control.call_count = 1;
    h.runtime.machine.control.call_count = 1;
    h.control.calls[0] = .{ .function = 0, .pc = 0, .value = .{ .integer = 93 } };
    h.runtime.machine.control.calls[0] = h.control.calls[0];
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 0).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 0).failed.code);
    try std.testing.expectEqual(@as(i64, 91), h.values[0].integer);
    try std.testing.expectEqual(@as(i64, 92), h.runtime.machine.values[0].integer);
    try std.testing.expect(h.control.call_count == 1 and h.runtime.machine.control.call_count == 1);
    try std.testing.expectEqual(@as(i64, 93), h.control.calls[0].value.integer);
}

test "failable frames preserve every result kind aggregate aliases and defining nominal UTF8 module locations" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Mode:=enum{One,Two};Row:=struct{Name:string};Frozen:[]i64=array{9}
        \\A()<computes><decides>:[]i64=Fail["array"]
        \\R()<computes><decides>:Row=Fail["record"]
        \\S()<computes><decides>:string=Fail["雪"]
        \\F()<computes><decides>:float=Fail["float"]
        \\E()<computes><decides>:Mode=Fail["enum"]
        \\T()<computes><decides>:tuple(i64,string)=Fail["tuple"]
        \\O()<computes><decides>:option(i64)=Fail["option"]
        \\M()<computes><decides>:map(i64,string)=Fail["map"]
        \\L()<computes><decides>:logic=Fail["logic"]
        \\Items:[][]i64=array{Attempt(A[],Frozen),Attempt(A[],Frozen)}
        \\Record:Row=Attempt(R[],Row{Name:="雪"});Text:string=Attempt(S[],"雪")
        \\Float:float=Attempt(F[],0.0/0.0);Zero:float=Attempt(F[],-0.0)
        \\Enum:Mode=Attempt(E[],Mode.Two);Tuple:tuple(i64,string)=Attempt(T[],tuple{1,"雪"})
        \\Option:option(i64)=Attempt(O[],option{});Map:map(i64,string)=Attempt(M[],map{1=>"雪"})
        \\Logic:logic=Attempt(L[],true)
    );
    try std.testing.expectEqual(@as(u32, 11), x.failure_count);
    const aliases = x.elements(x.get("Items").?).?;
    try std.testing.expectEqualDeep(aliases[0], aliases[1]);
    try std.testing.expect(std.math.isNan(x.get("Float").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Result:S.Row=Attempt(S.Make[],S.Row{Name:=\"雪\"})" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string}\nMake<public>()<computes><decides>:Row=Fail[\"雪\"]" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok;
    const result = (try h.run(p, 100)).ok;
    var buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, result, "wrong.forb", .{});
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    const trace = json.value.object.get("failures").?.array.items[0].object;
    try std.testing.expectEqualStrings("雪.forb", trace.get("path").?.string);
    try std.testing.expectEqualStrings("雪", trace.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 2), trace.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 39), trace.get("column").?.integer);
    const inspect = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspect);
    out = .fixed(&buffer);
    try std.testing.expect((try inspect.write(&out, p)) == .ok);
    const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(i64, 13), report.value.object.get("format").?.integer);
    try std.testing.expect(report.value.object.get("functions").?.array.items[0].object.get("decides").?.bool);
}

test "failable frames preserve global failure chronology after continuation and prefix truncation" {
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F()<computes><decides>:i64=Fail[\"callee\"];G()<computes><decides>:i64=F[];");
    for (0..14) |i| try out.print("A{d}:i64=Attempt(If(Attempt(G[],1)>0,Fail[\"root\"],0),Attempt(G[],2));", .{i});
    const x = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(u32, 42), x.failure_count);
    try std.testing.expectEqual(@as(usize, 32), x.failures.len);
    for (x.failures, 0..) |trace, i| {
        try std.testing.expectEqual(i % 3 != 1, trace.function != null);
        try std.testing.expectEqualStrings(if (i % 3 == 1) "root" else "callee", trace.reason.?);
    }
    @memcpy(h.traces[0..32], x.failures);
    var forged = x;
    forged.failures = &h.traces;
    std.mem.swap(types.FailureTrace, &h.traces[0], &h.traces[1]);
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    forged = x;
    forged.failure_count += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
}

test "failable frames agree with 1000 independent caller catch source rollback and fallback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const n: i64 = @as(i64, @intCast(i % 23)) - 7;
        const use_catch = i % 3 == 0;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(N:i64)<computes><decides>:i64=If(Require[N>0],N+3,Fail[\"negative\"]);G(N:i64)<computes><decides>:i64=If(Require[F[N]<10],N*2,Fail[\"large\"]);H(N:i64)<computes>:i64=Attempt(G[N],5);First(X:i64,Y:i64)<computes>:i64=X;var C:i64=1;A:i64=Attempt(First(Set(C,2),{s}{d}{s}),C+7);Value:i64=C", .{ if (use_catch) "H(" else "G[", n, if (use_catch) ")" else "]" });
        const x = try h.execute(out.buffered());
        const failed = n <= 0 or n + 3 >= 10;
        const expected: i64 = if (failed and !use_catch) 8 else 2;
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        try std.testing.expectEqual(@as(i64, if (failed and !use_catch) 1 else 2), x.get("Value").?.integer);
        try std.testing.expectEqual(@as(u32, if (failed) 1 else 0), x.failure_count);
        if (failed) try std.testing.expectEqual(@as(?u32, if (n <= 0) 0 else 1), x.failures[0].function);
    }
}
