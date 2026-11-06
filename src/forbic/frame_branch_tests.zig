//! Per-frame branch schedules, persistent evidence and independent admission.
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
    fn compile(self: *Harness, source: []const u8) !types.Program {
        return switch (self.front.compile(source)) {
            .ok => |p| p,
            .failed => |d| {
                std.debug.print("frame branch compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("frame branch run {s}\n", .{r.failed.message()});
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

test "frame branches preserve all Value kinds chosen allocations captures and aliases" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Mode:=enum{One,Two}; Row:=struct{Name:string,Size:i64}
        \\Name:string="雪"; Frozen:[]i64=array{9}
        \\Next(N:i64)<computes>:i64=N+1
        \\Rows(L:logic,N:i64)<computes>:[]Row=If(L,array{Row{Name:=Name,Size:=Next(N)}},array{})
        \\Pick(L:logic,N:i64)<computes>:[]i64=If(L,Frozen,array{Next(N),Next(N+1)})
        \\Label(L:logic)<computes>:string=If(L,Name,"empty")
        \\Ratio(L:logic)<computes>:float=If(L,0.0/0.0,-0.0)
        \\State(L:logic)<computes>:Mode=If(L,Mode.One,Mode.Two)
        \\Pair(L:logic)<computes>:tuple(i64,string)=If(L,tuple{1,Name},tuple{2,"other"})
        \\Maybe(L:logic)<computes>:option(i64)=If(L,option{7},option{})
        \\Map(L:logic)<computes>:map(i64,string)=If(L,map{1=>Name},map{})
        \\Bool(L:logic)<computes>:logic=If(L,true,false)
        \\A:[]i64=Pick(true,1); B:[]i64=Pick(false,4); C:[][]i64=array{A,B,A}
        \\R:[]Row=Rows(true,3); Empty:[]Row=Rows(false,0)
        \\S:string=Label(true); F:float=Ratio(true); Z:float=Ratio(false)
        \\E:Mode=State(false); T:tuple(i64,string)=Pair(true); O:option(i64)=Maybe(false)
        \\M:map(i64,string)=Map(true); L:logic=Bool(false)
    );
    try std.testing.expect(x.activity.len == 0 and x.call_steps.len > 0);
    try std.testing.expectEqualStrings("雪", x.get("S").?.string);
    try std.testing.expect(std.math.isNan(x.get("F").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Z").?.floating)));
    try std.testing.expectEqual(@as(i64, 9), x.elements(x.get("A").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 5), x.elements(x.get("B").?).?[0].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("Empty").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("O").?).?.len);
    try std.testing.expect(!x.get("L").?.boolean);
    const pure = try h.execute("Next(N:i64)<computes>:i64=N+1;A:i64=Next(3)");
    try std.testing.expect(pure.call_steps.len == 0 and h.control.call_count == 0 and h.runtime.machine.control.call_count == 0);
}

test "frame branches are lazy strict in arguments exact in fuel and fatal to outer transactions" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic,N:i64)<computes>:i64=If(L,If(N>0,7,8),1/0);A:i64=F(true,3)");
    const success = (try h.run(p, 100)).ok;
    try std.testing.expectEqual(@as(i64, 7), success.get("A").?.integer);
    const exact: u32 = @intCast(p.nodes.len + success.call_steps.len);
    for (0..exact) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try h.run(p, exact)).ok.get("A").?.integer);
    const strict = try h.compile("F(L:logic,N:i64)<computes>:i64=If(L,7,8);A:i64=F(true,1/0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(strict, 100)).failed.code);
    const fatal = try h.compile("var Cell:i64=1;F(L:logic)<computes>:i64=If(L,7,1/0);set Cell=2;A:i64=Attempt(F(false),9)");
    const fail = (try h.run(fatal, 100)).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, fail.code);
    try std.testing.expectEqualStrings("/", fail.span.text(fatal.source));
    try std.testing.expect(!h.runtime.machine.source.cells[0].initialized and !h.state.cells[0].initialized);
    _ = try h.execute("F(L:logic)<computes>:i64=If(L,7,1/0);A:i64=F(true)");
}

test "frame branches require persistent control evidence and admit exact 8192 step pressure" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<computes>:i64=If(L,1,2);A:i64=F(false)");
    try std.testing.expectEqual(types.Diagnostic.Code.control_storage_required, evaluator.evaluateWithStorage(p, &h.values, &h.members, 100).failed.code);
    const reference = evaluator.evaluateWithControlStorage(p, &h.values, &h.members, &h.control, 100).ok;
    try std.testing.expectEqual(@intFromPtr(h.control.calls[0..].ptr), @intFromPtr(reference.call_steps.ptr));
    _ = try reporting.validate(reference, false, .{});
    const unused = try h.compile("F(L:logic)<computes>:i64=If(L,1,2);A:i64=3");
    try std.testing.expect(evaluator.evaluateWithStorage(unused, &h.values, &h.members, 10).ok.call_steps.len == 0);
    for ([_]usize{ 2048, 2049 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F(L:logic)<computes>:i64=If(L,1,2);A:i64=");
        for (0..count) |index| try out.writeAll(if (index == 0) "F(false)" else "+F(false)");
        const full = try h.compile(out.buffered());
        const r = try h.run(full, 100000);
        if (count == 2048) {
            try std.testing.expectEqual(@as(usize, types.limits.call_steps), r.ok.call_steps.len);
            try std.testing.expectEqual(@as(i64, 4096), r.ok.get("A").?.integer);
            const fuel: u64 = @intCast(full.nodes.len + r.ok.call_steps.len);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(full, fuel - 1)).failed.code);
            try std.testing.expectEqual(@as(usize, types.limits.call_steps), (try h.run(full, fuel)).ok.call_steps.len);
        } else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
    }
    _ = try h.execute("F(L:logic)<computes>:i64=If(L,1,2);A:i64=F(true)");
}

test "frame branches reject unused malformed metadata targets roots and arm leakage before storage writes" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<computes>:i64=If(L,1+2,3+4);G(L:logic)<computes>:i64=F(L)+1;A:i64=9");
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    var malformed = p;
    malformed.functions = h.metadata[0..p.functions.len];
    malformed.function_nodes = h.body[0..p.function_nodes.len];
    for (0..2000) |iteration| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (iteration % 5) {
            0 => h.metadata[0].has_control = false,
            1 => h.metadata[0].control_ops += 1,
            2 => h.metadata[1].has_control = false,
            3 => h.metadata[0].root = 2,
            else => for (h.body[0..p.functions[0].body.end]) |*entry| if (entry.node.kind == .if_begin) {
                entry.node.kind.if_begin.end = entry.node.kind.if_begin.alternative;
                break;
            },
        }
        h.values[0] = .{ .integer = 91 };
        h.runtime.machine.values[0] = .{ .integer = 92 };
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithControlStorage(malformed, &h.values, &h.members, &h.control, 0).failed.code);
        const lowered = bytecode.lower(malformed, &h.runtime.instructions).ok;
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(lowered, 0).failed.code);
        try std.testing.expectEqual(@as(i64, 91), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 92), h.runtime.machine.values[0].integer);
    }
    _ = try h.run(p, 100);
}

test "frame branch reports reject missing extra reordered copied and borrowed steps before writing" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F(L:logic,N:i64)<computes>:[]i64=If(L,array{N,N+1},array{N+2});G(L:logic)<computes>:[]i64=F(L,7);A:[]i64=G(true);B:[]i64=G(false)");
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    var forged = x;
    forged.call_steps = h.steps[0..x.call_steps.len];
    var output: [1024]u8 = undefined;
    for (0..1000) |iteration| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        forged.call_steps = h.steps[0..x.call_steps.len];
        switch (iteration % 6) {
            0 => h.steps[0].function = 64,
            1 => h.steps[0].pc = std.math.maxInt(u32),
            2 => forged.call_steps = h.steps[1..x.call_steps.len],
            3 => {
                h.steps[x.call_steps.len] = h.steps[0];
                forged.call_steps = h.steps[0 .. x.call_steps.len + 1];
            },
            4 => h.steps[0].value = .{ .integer = 99 },
            else => std.mem.swap(types.CallStep, &h.steps[0], &h.steps[1]),
        }
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const stats = try reporting.validate(x, false, .{});
    var out = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = stats.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const strings = try h.execute("F(L:logic)<computes>:string=If(L,\"雪\",\"ok\");A:string=F(true)");
    @memcpy(h.steps[0..strings.call_steps.len], strings.call_steps);
    forged = strings;
    forged.call_steps = h.steps[0..strings.call_steps.len];
    for (h.steps[0..strings.call_steps.len]) |*step| if (step.value == .string) {
        step.value.string = "foreign";
        break;
    };
    out = .fixed(&output);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "frame branches agree with 1000 independent scalar oracles and inspection records control metadata" {
    const h = try create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xf00c65017);
    const random = prng.random();
    for (0..1000) |_| {
        const a = random.intRangeAtMost(i64, -100, 100);
        const b = random.intRangeAtMost(i64, -100, 100);
        const choice = random.boolean();
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("F(L:logic,A:i64,B:i64)<computes>:i64=If(L,If(A>B,A*2,B-3),A+B);G(L:logic,A:i64,B:i64)<computes>:i64=F(L,A,B)+1;R:i64=G({s},{d},{d})", .{ if (choice) "true" else "false", a, b });
        const expected = 1 + if (choice) (if (a > b) a * 2 else b - 3) else a + b;
        try std.testing.expectEqual(expected, (try h.execute(out.buffered())).get("R").?.integer);
    }
    const ir = try h.compile("F(L:logic)<computes>:i64=If(L,7,8);A:i64=F(true)");
    const inspect = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspect);
    var buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expect((try inspect.write(&out, ir)) == .ok);
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 11), json.value.object.get("format").?.integer);
    const function = json.value.object.get("functions").?.array.items[0].object;
    try std.testing.expect(function.get("has_control").?.bool);
    try std.testing.expectEqual(@as(i64, 3), function.get("control_ops").?.integer);
}

test "frame branches bound per-frame nesting and dynamic member copies independently" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 31, 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F()<computes>:i64=");
        for (0..depth) |_| try out.writeAll("If(true,");
        try out.writeAll("7");
        for (0..depth) |_| try out.writeAll(",8)");
        try out.writeAll(";A:i64=F()");
        if (depth <= 32) {
            try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.control_limit, h.front.compile(out.buffered()).failed.code);
    }
    for ([_]usize{ 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("F0(L:logic)<computes>:i64=If(L,1,2);");
        for (1..depth) |index| try out.print("F{d}(L:logic)<computes>:i64=If(L,F{d}(L),3);", .{ index, index - 1 });
        try out.print("A:i64=F{d}(true)", .{depth - 1});
        const p = try h.compile(out.buffered());
        const r = try h.run(p, 1000);
        if (depth == 32) try std.testing.expectEqual(@as(i64, 1), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    }
    const p = try h.compile("F(L:logic)<computes>:[]i64=If(L,array{1,2,3},array{});A:[]i64=F(true)");
    for (0..4) |capacity| {
        @memset(h.members[0..4], .{ .integer = 99 });
        const r = evaluator.evaluateWithRuntimeStorage(p, &h.values, h.members[0..capacity], &h.control, &h.state, &h.frames, 100);
        if (capacity < 3) {
            try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
            try std.testing.expectEqual(@as(i64, 99), h.members[0].integer);
            try std.testing.expectEqual(@as(usize, 0), h.control.call_count);
        } else _ = try reporting.validate(r.ok, false, .{});
    }
    const empty = try h.compile("F(L:logic)<computes>:[]i64=If(L,array{1,2,3},array{});A:[]i64=F(false)");
    const r = evaluator.evaluateWithControlStorage(empty, &h.values, &.{}, &h.control, 100).ok;
    try std.testing.expect(r.aggregate_values.len == 0);
    _ = try reporting.validate(r, false, .{});
}

test "frame branch report admits hidden maps only after every borrowed trace value and checks copied members" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make()<computes>:map(i64,string)=map{1+0=>\"a\",3+0=>\"b\"};Discard(M:map(i64,string))<computes>:i64=If(true,7,8);F()<computes>:i64=Discard(Make());A:i64=F()");
    try std.testing.expectEqual(@as(usize, 4), x.aggregate_values.len);
    @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    var forged = x;
    forged.aggregate_values = h.members[0..x.aggregate_values.len];
    forged.call_steps = h.steps[0..x.call_steps.len];
    h.members[2] = .{ .integer = 1 };
    // Preserve constructor copies while forging an opaque computed key.
    for (h.steps[0..x.call_steps.len]) |*event| {
        const entry = x.program.function_nodes[x.program.functions[event.function].body.start + event.pc];
        if (entry.input == .operation and entry.node.kind == .binary and event.value.integer == 3) event.value.integer = 1;
    }
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    // A foreign string must be rejected before the map comparator sees it.
    h.members[1] = .{ .string = "foreign" };
    out = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
    @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
    h.members[1] = h.members[3];
    out = .fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
