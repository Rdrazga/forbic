//! Runtime-frame semantics, independent admission, quotas and borrowed lifetime.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const calls = @import("call_frames.zig");
const state = @import("source_state.zig");
const report = @import("value_report.zig");
const Harness = struct {
    pub const parts = .{ "front", "runtime" };
    front: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},
    state: state.ReferenceState = .{},
    frames: calls.ReferenceStorage = .{},
    text: [types.limits.source_bytes]u8 = undefined,
    body: [types.limits.template_nodes]types.FunctionNode = undefined,
    arguments: [types.limits.call_arguments + 1]u32 = undefined,
    fn_arguments: [types.limits.call_arguments + 1]u32 = undefined,
    nodes: [types.limits.nodes]types.Node = undefined,
    fn_metadata: [types.limits.functions]types.RuntimeFunction = undefined,
    fn_members: [types.limits.aggregate_elements]u32 = undefined,
    globals: [types.limits.bindings]types.Binding = undefined,
    fn compile(self: *Harness, text: []const u8) !types.Program {
        return switch (self.front.compile(text)) {
            .ok => |p| p,
            .failed => |d| {
                std.debug.print("calls compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, text });
                return error.Compile;
            },
        };
    }
    fn run(self: *Harness, p: types.Program, fuel: u64) !evaluator.Result {
        const a = evaluator.evaluateWithRuntimeStorage(p, &self.values, &self.members, &self.control, &self.state, &self.frames, fuel);
        const b = self.runtime.evaluate(p, fuel);
        try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
        try std.testing.expectEqual(@as(u32, 0), self.frames.depth);
        try std.testing.expectEqual(@as(u32, 0), self.frames.count);
        try std.testing.expectEqual(@as(u32, 0), self.runtime.machine.calls.depth);
        try std.testing.expectEqual(@as(u32, 0), self.runtime.machine.calls.count);
        try std.testing.expectEqual(@as(u32, 0), self.state.depth);
        try std.testing.expectEqual(@as(u32, 0), self.runtime.machine.source.depth);
        if (a == .failed) {
            try std.testing.expectEqualDeep(a.failed, b.failed);
            return b;
        }
        try std.testing.expectEqualSlices(bool, a.ok.activity, b.ok.activity);
        try std.testing.expectEqualDeep(a.ok.failures, b.ok.failures);
        try std.testing.expectEqual(a.ok.failure_count, b.ok.failure_count);
        for (a.ok.values, b.ok.values, 0..) |x, y, index| if (a.ok.active(index)) {
            try equal(x, y);
        };
        try std.testing.expectEqual(a.ok.aggregate_values.len, b.ok.aggregate_values.len);
        for (a.ok.aggregate_values, b.ok.aggregate_values) |x, y| try equal(x, y);
        _ = try report.validate(a.ok, false, .{});
        _ = try report.validate(b.ok, false, .{});
        return b;
    }
    fn execute(self: *Harness, text: []const u8) !evaluator.Execution {
        const result = try self.run(try self.compile(text), 131072);
        if (result == .failed) {
            std.debug.print("calls execute {s}\n", .{result.failed.message()});
            return error.Execute;
        }
        return result.ok;
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

test "calls preserve all Value kinds captures nested constructor prefixes and aliases across frame reuse" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=3
        \\Frozen:i64=Cell
        \\mode:=enum{Dark,Light}
        \\row:=struct{N:i64,Text:string}
        \\Make(N:i64)<computes>:row=row{N:=N+Frozen,Text:="雪"}
        \\Rows(N:i64)<computes>:[]row=array{Make(N),Make(N+1)}
        \\All(N:i64)<computes>:tuple([]row,option(float),map(mode,logic))=tuple{Rows(N),option{-0.0},map{mode.Dark=>true,mode.Light=>false}}
        \\First:tuple([]row,option(float),map(mode,logic))=All(4)
        \\Held:tuple([]row,option(float),map(mode,logic))=First
        \\set Cell=99
        \\Second:tuple([]row,option(float),map(mode,logic))=All(10)
        \\Result:i64=First(0).Length+Second(0).Length
    );
    try std.testing.expectEqual(@as(i64, 4), x.get("Result").?.integer);
    try std.testing.expectEqual(@as(usize, 3), x.program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), x.program.globals.len);
    try std.testing.expectEqualDeep(x.get("First"), x.get("Held"));
    const first = x.elements(x.elements(x.get("Held").?).?[0]).?;
    try std.testing.expectEqual(@as(i64, 7), x.elements(first[0]).?[0].integer);
    const optional = x.elements(x.elements(x.get("Held").?).?[1]).?;
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(optional[0].floating)));
    try std.testing.expect(x.aggregate_values.len > x.program.members.len);
    // Reference compatibility scratch must not escape in successful borrows.
    const p = try h.compile("Make(N:i64)<computes>:[]i64=array{N,N+1};A:[]i64=Make(4);B:[]i64=Make(9)");
    const compat = evaluator.evaluateWithStorage(p, &h.values, &h.members, 32).ok;
    @memset(&h.frames.values, .{ .integer = -99 });
    try std.testing.expectEqual(@as(i64, 5), compat.elements(compat.get("A").?).?[1].integer);
    try std.testing.expectEqual(@as(usize, 0), compat.activity.len);
    _ = try report.validate(compat, false, .{});
}

test "calls integrate template control defaults transacts strict arguments and fatal source cleanup" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var C:i64=1;Pure(N:i64)<computes>:i64=N+1;Lazy(N:i64)<computes>:i64=If(N>0,Pure(N),Pure(N+2));Write(N:i64)<transacts>:i64=Set(C,Lazy(N));r:=struct{N:i64=Pure(8)};A:i64=Attempt(Write(3)+Fail[\"rollback\"],Write(-1));Value:r=r{};Result:i64=C+Value.N+A");
    try std.testing.expectEqual(@as(i64, 13), x.get("Result").?.integer);
    for ([_][]const u8{
        "var C:i64=1;Bad(N:i64)<computes>:i64=1/N;A:i64=Attempt(Set(C,9)+Bad(0),0)",
        "var C:i64=1;First(A:i64,B:i64)<computes>:i64=A+0;X:i64=First(Set(C,9),1/0)",
    }) |text| {
        const failure = try h.run(try h.compile(text), 131072);
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, failure.failed.code);
        try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
        try std.testing.expect(!h.state.cells[0].initialized);
    }
    const p = try h.compile("var C:i64=1;Double(N:i64)<computes>:i64=N*2;A:i64=Set(C,Double(4))");
    for (0..11) |fuel| _ = try h.run(p, @intCast(fuel));
    try std.testing.expectEqual(@as(i64, 8), (try h.run(p, 32)).ok.get("C").?.integer);
}

test "calls admit exactly 32 iterative frames and retain defining spans at all fuel boundaries" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var writer = std.Io.Writer.fixed(&h.text);
    try writer.writeAll("F0(X:i64)<computes>:i64=-X;");
    for (1..64) |id| try writer.print("F{d}(X:i64)<computes>:i64=F{d}(X);", .{ id, id - 1 });
    const end = writer.end;
    try writer.writeAll("A:i64=F31(7)");
    const p = try h.compile(writer.buffered());
    try std.testing.expectEqual(@as(usize, 128), p.function_nodes.len);
    for (0..66) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(i64, -7), (try h.run(p, 66)).ok.get("A").?.integer);
    writer.end = end;
    try writer.writeAll("A:i64=F32(7)");
    const failure = try h.run(try h.compile(writer.buffered()), 131072);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, failure.failed.code);
    try std.testing.expectEqualStrings("F0", failure.failed.span.text(writer.buffered()));
    _ = try h.execute("F(N:i64)<computes>:i64=N+3;A:i64=F(4)");
}

test "calls admit all 8192 frame registers and check full root and body argument pools" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const span: types.Span = .{ .start = 0, .end = 1 };
    const constant: types.Node = .{ .span = span, .value_type = .i64, .kind = .{ .integer = 7 } };
    for (&h.body) |*entry| entry.* = .{ .node = constant };
    h.fn_metadata[0] = .{ .name = span, .parameter_count = 0, .value_type = .i64, .body = .{ .start = 0, .end = 8192 }, .root = 8191, .available_at = 0, .member_work = 0, .is_public = false };
    h.nodes[0] = .{ .span = span, .value_type = .i64, .kind = .{ .call = .{ .function = 0, .arguments = .{ .start = 0, .end = 0 } } } };
    var p: types.Program = .{ .source = "F", .strings = "", .nodes = h.nodes[0..1], .bindings = &.{}, .functions = h.fn_metadata[0..1], .function_nodes = &h.body, .call_ops = 1 };
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, 8192)).failed.code);
    try std.testing.expectEqual(@as(i64, 7), (try h.run(p, 8193)).ok.values[0].integer);
    // Acyclic static bodies bound actual register pressure by the body pool.
    // Full argument pools reuse sixteen prior input registers, without copying
    // function bodies into root code or growing native call depth.
    h.fn_metadata[0].body.end = 17;
    h.fn_metadata[0].root = 16;
    h.fn_metadata[0].parameter_count = 16;
    @memset(&h.fn_metadata[0].parameters, .i64);
    for (0..16) |id| {
        h.body[id] = .{ .node = .{ .span = span, .value_type = .i64, .kind = .{ .integer = 0 } }, .input = .{ .parameter = @intCast(id) } };
        h.nodes[id] = .{ .span = span, .value_type = .i64, .kind = .{ .integer = @intCast(id) } };
    }
    h.body[16] = .{ .node = .{ .span = span, .value_type = .i64, .kind = .{ .negate = 15 } } };
    for (0..8192) |id| h.arguments[id] = @intCast(id % 16);
    for (0..512) |id| h.nodes[id + 16] = .{ .span = span, .value_type = .i64, .kind = .{ .call = .{ .function = 0, .arguments = .{ .start = @intCast(id * 16), .end = @intCast((id + 1) * 16) } } } };
    p.nodes = h.nodes[0..528];
    p.call_arguments = h.arguments[0..8192];
    p.function_nodes = h.body[0..17];
    p.call_ops = 512;
    try std.testing.expectEqual(@as(i64, -15), (try h.run(p, 9232)).ok.values[527].integer);
    p.call_arguments = &h.arguments;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try h.run(p, 0)).failed.code);
    p.call_arguments = h.arguments[0..16];
    p.call_ops = 1;
    p.nodes = h.nodes[0..17];
    h.nodes[16].kind.call.function = 1;
    h.fn_metadata[1] = h.fn_metadata[0];
    h.fn_metadata[1].name = .{ .start = 2, .end = 3 };
    h.fn_metadata[1].body = .{ .start = 17, .end = 545 };
    h.fn_metadata[1].root = 527;
    @memcpy(h.body[17..33], h.body[0..16]);
    for (0..8192) |id| h.fn_arguments[id] = @intCast(id % 16);
    for (0..512) |id| h.body[id + 33] = .{ .node = .{ .span = span, .value_type = .i64, .kind = .{ .call = .{ .function = 0, .arguments = .{ .start = @intCast(id * 16), .end = @intCast((id + 1) * 16) } } } } };
    p.source = "F G";
    p.functions = h.fn_metadata[0..2];
    p.function_nodes = h.body[0..545];
    p.function_arguments = h.fn_arguments[0..8192];
    try std.testing.expectEqual(@as(i64, -15), (try h.run(p, 9249)).ok.values[16].integer);
    p.function_arguments = &h.fn_arguments;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try h.run(p, 0)).failed.code);
}

test "calls reject 4000 malformed unused catalogue and body edits before touching run storage" {
    const h = try create();
    defer scratch.release(h);
    const original = try h.compile("Base:i64=9;Make(N:i64)<computes>:[]i64=array{N,Base};Size(N:i64)<computes>:i64=Make(N).Length;A:i64=0");
    var generator = std.Random.DefaultPrng.init(0x6400640064);
    const rng = generator.random();
    for (0..4000) |_| {
        @memcpy(h.fn_metadata[0..original.functions.len], original.functions);
        @memcpy(h.body[0..original.function_nodes.len], original.function_nodes);
        @memcpy(h.fn_members[0..original.function_members.len], original.function_members);
        @memcpy(h.fn_arguments[0..original.function_arguments.len], original.function_arguments);
        @memcpy(h.globals[0..original.globals.len], original.globals);
        var p = original;
        p.functions = h.fn_metadata[0..original.functions.len];
        p.function_nodes = h.body[0..original.function_nodes.len];
        p.function_members = h.fn_members[0..original.function_members.len];
        p.function_arguments = h.fn_arguments[0..original.function_arguments.len];
        p.globals = h.globals[0..original.globals.len];
        const value = rng.int(u32);
        switch (rng.uintLessThan(u8, 14)) {
            0 => h.fn_metadata[0].root = value,
            1 => h.fn_metadata[0].body.end = value,
            2 => h.fn_metadata[0].parameter_count = value,
            3 => h.fn_metadata[0].member_work = value,
            4 => h.fn_metadata[0].available_at = value,
            5 => h.fn_metadata[0].name.end = value,
            6 => h.body[0].input = .{ .parameter = value },
            7 => h.body[1].input = .{ .global = value },
            8 => h.fn_members[0] = value,
            9 => h.fn_arguments[0] = value,
            10 => h.globals[0].node = value,
            11 => h.body[2].node.kind = .{ .cell_read = 0 },
            12 => p.call_ops = 1,
            13 => p.functions = p.functions[0..1],
            else => unreachable,
        }
        h.values[0] = .{ .integer = 987 };
        h.runtime.machine.values[0] = .{ .integer = 987 };
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try h.run(p, 0)).failed.code);
        try std.testing.expectEqual(@as(i64, 987), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 987), h.runtime.machine.values[0].integer);
    }
    // Unused, valid bodies still admit with zero root call count.
    try std.testing.expectEqual(@as(i64, 0), (try h.run(original, 2)).ok.get("A").?.integer);
}

test "calls report every hidden constructor and reject extra ranges duplicate maps and forged borrows" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make(N:i64)<computes>:map(i64,i64)=map{1=>N,2=>N+1};Size(N:i64)<computes>:i64=Make(N).Length;A:i64=Size(4)");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(usize, 4), x.aggregate_values.len);
    var forged = x;
    forged.aggregate_values = x.aggregate_values[0..3];
    try std.testing.expectError(error.InvalidExecution, report.validate(forged, false, .{}));
    h.runtime.machine.aggregate_values[2] = .{ .integer = 1 };
    try std.testing.expectError(error.InvalidExecution, report.validate(x, false, .{}));
    h.runtime.machine.aggregate_values[2] = .{ .string = "foreign" };
    try std.testing.expectError(error.InvalidExecution, report.validate(x, false, .{}));
    const p = try h.compile("F(N:i64)<computes>:[]i64=array{N,N+1};A:[]i64=F(4)");
    const result = (try h.run(p, 32)).ok;
    try std.testing.expectError(error.ReportLimit, report.validate(result, false, .{ .work = 1 }));
    // Scalar-only exponentially repeated call graphs are skipped by footprints;
    // bounded fuel prevents executing them, and reporting cannot amplify them.
    _ = vm;
}

test "calls scalar DAG report work is bounded independently of exponential execution" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("F0()<computes>:i64=1;");
    for (1..64) |index| try out.print("F{d}()<computes>:i64=F{d}()+F{d}();", .{ index, index - 1, index - 1 });
    try out.writeAll("A:i64=F63()");
    const p = try h.compile(out.buffered());
    for (p.functions) |f| try std.testing.expectEqual(@as(u32, 0), f.member_work);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, (try h.run(p, 10000)).failed.code);
    // A report that claims a value for the call is refused: the replay runs the untraced call
    // itself (RFC-0024, "Amendment: the replay works out every value"). Its work stays within the
    // budget it is given, and with room it finds the call deeper than any run's frames.
    const typed_result: evaluator.Execution = .{ .program = p, .values = &.{.{ .integer = 1 }} };
    try std.testing.expectError(error.ReportLimit, report.validate(typed_result, false, .{ .work = 8 }));
    try std.testing.expectError(error.InvalidExecution, report.validate(typed_result, false, .{ .work = 1024 }));
}

test "calls caller member pressure rejects before copying and restores source state" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=1;Make(N:i64)<computes>:[]i64=array{N,N+1};A:[]i64=Make(Set(C,9));B:[]i64=Make(3)");
    for (0..4) |capacity| {
        @memset(&h.members, .{ .integer = 123 });
        const result = evaluator.evaluateWithRuntimeStorage(p, &h.values, h.members[0..capacity], &h.control, &h.state, &h.frames, 131072);
        try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, result.failed.code);
        try std.testing.expectEqual(@as(u32, 0), h.frames.depth);
        try std.testing.expectEqual(@as(u32, 0), h.state.depth);
        try std.testing.expect(!h.state.cells[0].initialized);
        for (h.members[capacity..]) |value| try std.testing.expectEqual(@as(i64, 123), value.integer);
    }
    _ = try h.run(p, 131072);
}
