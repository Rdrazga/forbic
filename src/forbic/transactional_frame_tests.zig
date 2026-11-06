//! Independent shared-cell frame, rollback, quota and report oracles.
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
                std.debug.print("transactional frame compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
        _ = try reporting.validate(reference.ok, false, .{});
        _ = try reporting.validate(actual.ok, false, .{});
        return actual;
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const r = try self.run(try self.compile(source), 131072);
        if (r == .failed) {
            std.debug.print("transactional frame run {s}\n", .{r.failed.message()});
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

test "transactional frames share caller cells commit own regions and restore the nearest source catcher" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=1;First(A:i64,B:i64)<computes>:i64=A
        \\Add(N:i64)<transacts>:i64=Set(C,C+N)
        \\Leaf(N:i64)<transacts><decides>:i64=First(Add(N),If(Require[N>=0],C,C))
        \\Own(N:i64)<transacts>:i64=Attempt(Leaf[N],Set(C,C+7))
        \\Chain(N:i64)<transacts><decides>:i64=Leaf[N]+5
        \\A:i64=Add(3);Frozen:i64=A;B:i64=Own(-2);D:i64=Attempt(Chain[-5],C)
        \\E:i64=Attempt(Chain[2],0);F:i64=Own(1);Value:i64=C
    );
    try std.testing.expectEqual(@as(i64, 4), x.get("Frozen").?.integer);
    try std.testing.expectEqual(@as(i64, 11), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 11), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 18), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 14), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 14), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 2), x.failure_count);
    try std.testing.expect(x.program.functions[0].has_source and !x.program.functions[0].has_control);
    try std.testing.expectEqual(@as(u32, 2), x.program.functions[0].source_ops);
    try std.testing.expectEqual(@as(u32, 0), x.program.functions[3].source_ops);
    for (x.program.functions) |f| try std.testing.expect(f.transacts and f.has_source);
    for (x.failures) |trace| try std.testing.expectEqual(@as(?u32, 1), trace.function);
}

test "transactional frames agree with 1000 independent strict argument and own rollback oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const base: i64 = @as(i64, @intCast(i % 19)) - 7;
        const n: i64 = @as(i64, @intCast(i % 23)) - 8;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64={d};First(A:i64,B:i64)<computes>:i64=A;Leaf(N:i64)<transacts><decides>:i64=First(Set(C,C+N),If(Require[N>0],N,N));Own(N:i64)<transacts>:i64=Attempt(Leaf[N],Set(C,C+7));A:i64=First(Set(C,C+2),Own({d}));B:i64=Attempt(First(Set(C,C+3),Fail[\"root\"]),C);Value:i64=C", .{ base, n });
        const x = try h.execute(out.buffered());
        const expected = base + 2 + if (n > 0) n else @as(i64, 7);
        try std.testing.expectEqual(expected, x.get("Value").?.integer);
        try std.testing.expectEqual(expected, x.get("B").?.integer);
        try std.testing.expectEqual(base + 2, x.get("A").?.integer);
        try std.testing.expectEqual(@as(u32, if (n > 0) 1 else 2), x.failure_count);
    }
}

test "transactional frame source checkpoints share exact 33 region capacity and fatal cleanup" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_][2]usize{ .{ 0, 32 }, .{ 1, 31 }, .{ 31, 1 }, .{ 32, 1 }, .{ 1, 32 } }) |depths| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("var C:i64=1;F()<transacts>:i64=");
        for (0..depths[1]) |_| try out.writeAll("Attempt(");
        try out.writeAll("Set(C,7)");
        for (0..depths[1]) |_| try out.writeAll(",8)");
        try out.writeAll(";A:i64=");
        for (0..depths[0]) |_| try out.writeAll("Attempt(");
        try out.writeAll("F()");
        for (0..depths[0]) |_| try out.writeAll(",9)");
        const r = try h.run(try h.compile(out.buffered()), 1000);
        if (depths[0] + depths[1] <= 32) {
            try std.testing.expectEqual(@as(i64, 7), r.ok.get("C").?.integer);
        } else {
            try std.testing.expectEqual(types.Diagnostic.Code.transaction_limit, r.failed.code);
            try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
        }
    }
    _ = try h.execute("var C:i64=1;F()<transacts>:i64=Set(C,42);A:i64=F()");
}

test "transactional frame writes admit exact register and event capacity and hold no undo record in the root region" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=0;F()<transacts>:i64=Set(C,1);A:i64=F()");
    @memcpy(h.metadata[0..1], p.functions);
    h.body[0] = p.function_nodes[0];
    for (h.body[1..]) |*entry| entry.* = p.function_nodes[1];
    h.metadata[0].body.end = types.limits.template_nodes;
    h.metadata[0].root = types.limits.template_nodes - 1;
    h.metadata[0].source_ops = types.limits.template_nodes - 1;
    var program = p;
    program.functions = h.metadata[0..1];
    program.function_nodes = &h.body;
    const x = (try h.run(program, 16384)).ok;
    try std.testing.expectEqual(@as(usize, 8192), x.call_steps.len);
    try std.testing.expectEqual(@as(i64, 1), x.get("C").?.integer);
    const fuel: u64 = @intCast(program.nodes.len + x.call_steps.len);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, fuel - 1)).failed.code);
    _ = try h.run(program, fuel);
    var nodes: [5]types.Node = undefined;
    nodes[0] = p.nodes[0];
    nodes[1] = p.nodes[1];
    nodes[2] = .{ .span = p.source_cells[0].name, .value_type = .i64, .kind = .{ .cell_write = .{ .cell = 0, .value = 0 } } };
    nodes[3] = p.nodes[2];
    nodes[4] = p.nodes[3];
    var bindings: [2]types.Binding = undefined;
    @memcpy(&bindings, p.bindings);
    for (&bindings) |*binding| binding.node += 1;
    program.nodes = &nodes;
    program.bindings = &bindings;
    program.source_ops += 1;
    // One write more than `source_undos` used to end the run with `undo_limit`. None of these
    // writes is inside an Attempt, so no rollback could use a record of them and none is kept.
    try std.testing.expect(types.limits.template_nodes + 1 > types.limits.source_undos);
    const extra = (try h.run(program, 16384)).ok;
    try std.testing.expectEqual(@as(usize, 8192), extra.call_steps.len);
    try std.testing.expectEqual(@as(i64, 1), extra.get("C").?.integer);
    try std.testing.expect(h.state.undo_count == 0 and h.runtime.machine.source.undo_count == 0);
}

test "transactional report checks cell read write and restoration copies before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=1;F()<transacts>:i64=Set(C,C+1);A:i64=F();Value:i64=C");
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    var forged = x;
    forged.call_steps = h.steps[0..x.call_steps.len];
    var buffer: [1024]u8 = undefined;
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        const wanted: std.meta.Tag(@FieldType(types.Node, "kind")) = if (i % 2 == 0) .cell_read else .cell_write;
        for (h.steps[0..x.call_steps.len]) |*event| {
            const node = x.program.function_nodes[x.program.functions[event.function].body.start + event.pc].node;
            if (std.meta.activeTag(node.kind) == wanted) event.value = .{ .integer = 99 };
        }
        var out = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const recovered = try h.execute("var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Leaf()<transacts><decides>:i64=First(Set(C,3),Fail[\"stop\"]);F()<transacts>:i64=Attempt(Leaf[],Set(C,7));A:i64=F();Value:i64=C");
    @memcpy(h.values[0..recovered.values.len], recovered.values);
    forged = recovered;
    forged.values = h.values[0..recovered.values.len];
    for (recovered.program.nodes, 0..) |node, index| if (node.kind == .cell_read) {
        h.values[index] = .{ .integer = 1 };
    };
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const admitted = try reporting.validate(recovered, false, .{});
    out = .fixed(&buffer);
    _ = try reporting.write(&out, recovered, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, recovered, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "transactional frames independently admit unused effects cells availability types and metadata" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=1;F(N:i64)<transacts>:i64=Set(C,C+N);A:i64=9");
    var malformed = p;
    malformed.functions = h.metadata[0..p.functions.len];
    malformed.function_nodes = h.body[0..p.function_nodes.len];
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (i % 8) {
            0 => h.metadata[0].transacts = false,
            1 => h.metadata[0].has_source = false,
            2 => h.metadata[0].source_ops += 1,
            3 => h.metadata[0].available_at = 0,
            4 => {
                for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .cell_read) {
                    entry.node.kind.cell_read = types.limits.source_cells;
                };
            },
            5 => {
                for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .cell_write) {
                    entry.node.kind.cell_write.value = types.limits.template_nodes;
                };
            },
            6 => {
                for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .cell_write) {
                    const write = entry.node.kind.cell_write;
                    entry.node.kind = .{ .cell_init = write };
                };
            },
            else => {
                for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .cell_read) {
                    entry.node.value_type = .string;
                };
            },
        }
        try invalid(h, malformed);
    }
    const pure = try h.compile("Nop()<transacts>:i64=7;F()<transacts>:i64=Nop();A:i64=1");
    @memcpy(h.metadata[0..pure.functions.len], pure.functions);
    malformed = pure;
    malformed.functions = h.metadata[0..pure.functions.len];
    h.metadata[1].transacts = false;
    try std.testing.expect(!pure.functions[1].has_source);
    try invalid(h, malformed);
    _ = try h.run(pure, 100);
}

fn invalid(h: *Harness, p: types.Program) !void {
    h.values[0] = .{ .integer = 91 };
    h.runtime.machine.values[0] = .{ .integer = 92 };
    h.control.call_count = 1;
    h.control.calls[0] = .{ .function = 0, .pc = 0, .value = .{ .integer = 93 } };
    h.runtime.machine.control.call_count = 1;
    h.runtime.machine.control.calls[0] = h.control.calls[0];
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 100).failed.code);
    try std.testing.expectEqual(@as(i64, 91), h.values[0].integer);
    try std.testing.expectEqual(@as(i64, 92), h.runtime.machine.values[0].integer);
    try std.testing.expectEqual(@as(usize, 1), h.control.call_count);
    try std.testing.expectEqual(@as(usize, 1), h.runtime.machine.control.call_count);
    try std.testing.expectEqual(@as(i64, 93), h.control.calls[0].value.integer);
    try std.testing.expectEqual(@as(i64, 93), h.runtime.machine.control.calls[0].value.integer);
}

test "transactional frames retain every Value kind snapshots and aggregate aliases across source rollback" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\row:=struct{Name:string,Size:i64};mode:=enum{One,Two}
        \\var I:i64=1;var L:logic=false;var F:float=-0.0;var S:string="old"
        \\var R:row=row{Name:="old",Size:=1};var E:mode=mode.One;var A:[]i64=array{1}
        \\var T:tuple(i64,string)=tuple{1,"old"};var O:option(i64)=option{1};var M:map(string,i64)=map{"old"=>1}
        \\Frozen:[]i64=A;Zero:float=F;First(P:i64,Q:i64)<computes>:i64=P
        \\Change()<transacts>:i64=tuple{Set(I,2),Set(L,true),Set(F,NaN),Set(S,"雪"),Set(R,row{Name:="雪",Size:=2}),Set(E,mode.Two),Set(A,array{2,3}),Set(T,tuple{2,"雪"}),Set(O,option{}),Set(M,map{"雪"=>2})}(0)
        \\Reset()<transacts><decides>:i64=First(Change(),Fail["abort"])
        \\Changed:i64=Change();Held:[]i64=A;set I=7;set S="kept";set M=map{"kept"=>7}
        \\Rolled:i64=Attempt(Reset[],I);Value:i64=Or(Lookup(M,"kept"),0)
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("Changed").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Rolled").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(usize, 1), x.elements(x.get("Frozen").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("Held").?).?.len);
    try std.testing.expectEqualDeep(x.get("Held").?, x.get("A").?);
    try std.testing.expect(std.math.isNan(x.get("F").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expectEqualStrings("kept", x.get("S").?.string);
    try std.testing.expect(x.get("L").?.boolean);
    try std.testing.expectEqual(@as(u32, 1), x.get("E").?.enumeration.index);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("O").?).?.len);
    try std.testing.expectEqual(@as(u32, 1), x.failure_count);
}

test "transactional frames retain nominal UTF8 modules privacy defining owners and inspection fourteen" {
    const h = try create();
    defer scratch.release(h);
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Held:S.Row=S.Read();Changed:S.Row=Attempt(S.Change[4],Held);Recovered:S.Row=Attempt(S.Change[-1],Changed);Value:i64=S.Read().Size" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};var Hidden:Row=Row{Name:=\"initial\",Size:=1}\nRead<public>()<transacts>:Row=Hidden\nChange<public>(N:i64)<transacts><decides>:Row=If(Require[N>=0],Set(Hidden,Row{Name:=\"雪\",Size:=N}),Hidden)" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok;
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqualStrings("initial", x.elements(x.get("Held").?).?[0].string);
    try std.testing.expectEqualStrings("雪", x.elements(x.get("Changed").?).?[0].string);
    try std.testing.expectEqualDeep(x.get("Changed").?, x.get("Recovered").?);
    try std.testing.expectEqual(@as(i64, 4), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 1), x.failure_count);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, x, "wrong.forb", .{});
    const trace_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer trace_json.deinit();
    const trace = trace_json.value.object.get("failures").?.array.items[0].object;
    try std.testing.expectEqualStrings("雪.forb", trace.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 3), trace.get("line").?.integer);
    const defining_line = inputs[1].source[std.mem.lastIndexOfScalar(u8, inputs[1].source, '\n').? + 1 ..];
    const column = std.mem.indexOf(u8, defining_line, "Require").? + 1;
    try std.testing.expectEqual(@as(i64, @intCast(column)), trace.get("column").?.integer);
    const inspect = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspect);
    out = .fixed(&buffer);
    try std.testing.expect((try inspect.write(&out, p)) == .ok);
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 14), json.value.object.get("format").?.integer);
    const functions = json.value.object.get("functions").?.array.items;
    for (functions) |f| try std.testing.expect(f.object.get("transacts").?.bool and f.object.get("has_source").?.bool);
    try std.testing.expect(functions[1].object.get("decides").?.bool);
    try std.testing.expectEqual(@as(i64, 1), functions[0].object.get("source_ops").?.integer);
    // Exporting the cell alone would make a root-owned span visible. A body
    // operation must also retain the function's defining module owner.
    var cells: [1]types.SourceCell = undefined;
    @memcpy(&cells, p.source_cells);
    cells[0].is_public = true;
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .cell_read) {
        entry.node.span = p.bindings[0].name;
    };
    var forged = p;
    forged.source_cells = &cells;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    try invalid(h, forged);
    var changed = inputs;
    changed[0].source = "S:=import{\"雪.forb\"};Bad:S.Row=S.Hidden";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &changed }).failed.diagnostic.code);
    // Even an unused declared effect with no reads/writes versions inspection.
    const pure = try h.compile("F()<transacts>:i64=7;A:i64=1");
    out = .fixed(&buffer);
    try std.testing.expect((try inspect.write(&out, pure)) == .ok);
    const pure_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer pure_json.deinit();
    try std.testing.expectEqual(@as(i64, 14), pure_json.value.object.get("format").?.integer);
    try std.testing.expect(!pure_json.value.object.get("functions").?.array.items[0].object.get("has_source").?.bool);
    _ = try h.run(pure, 100);
}

test "transactional frames abort all writes on every fuel prefix fatal fallback and strict discarded argument" {
    const h = try create();
    defer scratch.release(h);
    const source = "var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Leaf(N:i64)<transacts><decides>:i64=First(Set(C,C+N),Fail[\"stop\"]);Own()<transacts>:i64=Attempt(Leaf[3],Set(C,C+7));A:i64=First(Set(C,C+2),Own());Value:i64=C";
    const p = try h.compile(source);
    const complete = (try h.run(p, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 10), complete.get("Value").?.integer);
    // This program catches inside Own. All events correspond to visited
    // operations, with no root failure delimiter or aggregate copy costs.
    const exact: u32 = @intCast(std.mem.count(bool, complete.activity, &.{true}) + complete.call_steps.len);
    for (0..exact) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(budget))).failed.code);
        try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    }
    _ = try h.run(p, exact);
    for ([_][]const u8{
        "var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Leaf()<transacts><decides>:i64=First(Set(C,3),Fail[\"x\"]);Own()<transacts>:i64=Attempt(Leaf[],Set(C,1/0));A:i64=Own()",
        "var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Keep(N:i64)<transacts>:i64=Set(C,7);A:i64=Keep(First(Set(C,3),1/0))",
    }) |text| {
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(try h.compile(text), 1000)).failed.code);
        try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    }
    _ = try h.execute(source);
}
