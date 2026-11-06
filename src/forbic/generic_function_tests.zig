//! Explicit generic specialization, scope, continuation and admission oracles.
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
pub const Harness = struct {
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
    pub fn compile(self: *Harness, source: []const u8) !types.Program {
        return switch (self.front.compile(source)) {
            .ok => |p| p,
            .failed => |d| {
                std.debug.print("generic function compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
                return error.Compile;
            },
        };
    }
    pub fn run(self: *Harness, p: types.Program, fuel: u64) !evaluator.Result {
        const reference = evaluator.evaluateWithRuntimeStorage(p, &self.values, &self.members, &self.control, &self.state, &self.frames, fuel);
        // The second machine is given the first one's input record (RFC-0086, I3): it must ask
        // for exactly what the first one read, and never asks the world. A test that gives it a
        // world of its own (one that fails as the first one's did, say) gives it no prefix.
        const second = &self.runtime.machine.control.effects.inputs;
        second.prefix = if (second.source == null) self.control.effects.inputs.record() else .{};
        // And the same grants, a run parameter (RFC-0086, H1).
        second.grants = self.control.effects.inputs.grants;
        const actual = self.runtime.evaluate(p, fuel);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        // Both recorded the same inputs, whether the run completed or not (I8).
        try std.testing.expectEqualDeep(self.control.effects.inputs.record().entries, self.runtime.machine.control.effects.inputs.record().entries);
        try std.testing.expectEqualSlices(u8, self.control.effects.inputs.record().bytes, self.runtime.machine.control.effects.inputs.record().bytes);
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
        try std.testing.expectEqual(reference.ok.object_cells.len, actual.ok.object_cells.len);
        for (reference.ok.object_cells, actual.ok.object_cells) |a, b| {
            try std.testing.expectEqual(a.initialized, b.initialized);
            try equal(a.value, b.value);
        }
        try std.testing.expectEqual(reference.ok.call_steps.len, actual.ok.call_steps.len);
        for (reference.ok.call_steps, actual.ok.call_steps) |a, b| {
            try std.testing.expectEqual(a.kind, b.kind);
            try std.testing.expectEqual(a.function, b.function);
            try std.testing.expectEqual(a.pc, b.pc);
            try equal(a.value, b.value);
        }
        // Both machines did the same to the world and drew the same from it (RFC-0079).
        try std.testing.expectEqualDeep(reference.ok.effects.output, actual.ok.effects.output);
        try std.testing.expectEqual(reference.ok.effects.seed, actual.ok.effects.seed);
        try std.testing.expectEqual(reference.ok.effects.draws, actual.ok.effects.draws);
        try std.testing.expectEqual(reference.ok.effects.discarded, actual.ok.effects.discarded);
        try std.testing.expectEqualSlices(u8, reference.ok.effects.bytes, actual.ok.effects.bytes);
        try std.testing.expectEqualDeep(reference.ok.effects.entries, actual.ok.effects.entries);
        // And their schedulers did the same (RFC-0082).
        try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
        // And their live variables (RFC-0084).
        try std.testing.expectEqualDeep(reference.ok.live, actual.ok.live);
        try std.testing.expectEqual(reference.ok.cells.len, actual.ok.cells.len);
        for (reference.ok.cells, actual.ok.cells) |a, b| {
            try std.testing.expectEqual(a.initialized, b.initialized);
            if (a.initialized) try equal(a.value, b.value);
        }
        // Physical-member tests intentionally retain many repeated aggregate
        // snapshots; fund their separate report traversal explicitly.
        _ = try reporting.validate(reference.ok, false, .{ .work = @max(1024 * 1024, types.limits.report_work) });
        _ = try reporting.validate(actual.ok, false, .{ .work = @max(1024 * 1024, types.limits.report_work) });
        return actual;
    }
    pub fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const r = try self.run(try self.compile(source), 131072);
        if (r == .failed) {
            std.debug.print("generic function run {s}\n", .{r.failed.message()});
            return error.Execute;
        }
        return r.ok;
    }
};
pub fn create() !*Harness {
    const h = try scratch.make(Harness);
    return h;
}
fn equal(a: types.Value, b: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .floating) try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating))) else try std.testing.expectEqualDeep(a, b);
}

pub fn invalid(h: *Harness, p: types.Program) !void {
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 0).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 0).failed.code);
}

/// Forged code that passes admission but breaks a rule only a run can see stops both machines.
pub fn traps(h: *Harness, p: types.Program, budget: u64) !void {
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, budget).failed.code);
}

test "generic function explicit references reuse code and preserve exact scalar and aggregate types" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Id[T:type](X:T)<computes>:T{X};Pair[A:type,B:type](X:A,Y:B)<computes>:tuple(A,B){tuple{X,Y}};A:i64=Id[i64](42);B:string=Id[string](\"雪\");F:function(tuple(i64),i64)=Id[i64];C:i64=F(42);P:tuple(i64,string)=Pair[i64,string](42,\"雪\");Empty:[]i64=Id[[]i64](array{})");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("C").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("B").?.string);
    try std.testing.expectEqual(@as(usize, 4), x.program.functions.len);
    try std.testing.expectEqual(@as(u32, 0), x.get("F").?.callable.function);
    for (x.program.functions) |f| try std.testing.expect(f.specialization != null and !f.anonymous and !f.is_public);
    try std.testing.expect(h.front.generic_count == 2 and h.front.anonymous_count == 0);
}

test "generic function bodies specialize dependent operations before unused callable publication" {
    const h = try create();
    defer scratch.release(h);
    var x = try h.execute("Add[T:type](A:T,B:T)<computes>:T{A+B};A:i64=Add[i64](2,40);B:float=Add[float](2.0,40.0)");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(f64, 42), x.get("B").?.floating);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, h.front.compile("Add[T:type](A:T,B:T)<computes>:T{A+B};Unused:function(tuple(logic,logic),logic)=Add[logic]").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, h.front.compile("Broken[T:type](X:T)<computes>:T{Missing};Unused:function(tuple(i64),i64)=Broken[i64]").failed.code);
    const dormant = try h.compile("Broken[T:type](X:T)<computes>:T{Missing}");
    try std.testing.expectEqual(@as(usize, 0), dormant.functions.len);
    x = try h.execute("A:i64=42");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
}

test "generic function nested materialization restores creator parameters locals and explicit anonymous captures" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Id[T:type](X:T)<computes>:T{X};Make[T:type](X:T)<computes>:function(tuple(),T){Fn[Saved:T=Id[T](X)]()<computes>:T{Saved}};Outer(N:i64)<transacts>:i64=Block{var V:i64=N;F:function(tuple(),i64)=Make[i64](V);set V=V+1;F()+V};A:i64=Outer(20);Text:function(tuple(),string)=Make[string](\"雪\");B:string=Text()");
    try std.testing.expectEqual(@as(i64, 41), x.get("A").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("B").?.string);
    try std.testing.expect(h.front.anonymous_count == 0 and h.front.local_count == 0 and h.front.local_checkpoint_count == 0);
    var anonymous: usize = 0;
    for (x.program.functions) |f| if (f.anonymous) {
        anonymous += 1;
        try std.testing.expect(f.specialization != null);
    };
    try std.testing.expectEqual(@as(usize, 2), anonymous);
}

test "generic function definition namespaces reject later caller names and admit earlier globals" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Base:i64=2;Add[T:type](X:T)<computes>:i64{Base};A:i64=Add[string](\"雪\")");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    for ([_][]const u8{
        "F[T:type](X:T)<computes>:i64{Later};Later:i64=42;A:i64=F[i64](1)",
        "F[T:type](X:T)<computes>:i64{Later(1)};Later(N:i64)<computes>:i64=N;A:i64=F[i64](1)",
        "F[T:type](X:T)<computes>:i64{G[i64](1)};G[T:type](X:T)<computes>:i64{1};A:i64=F[i64](1)",
        "F[T:type](X:T)<computes>:i64{Caller};Outer(N:i64)<computes>:i64=Block{Caller:i64=N;F[i64](1)};A:i64=Outer(42)",
    }) |source| {
        const result = h.front.compile(source);
        if (result == .ok) std.debug.print("unexpected generic name admission: {s}\n", .{source});
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, result.failed.code);
    }
    try std.testing.expectEqual(types.Diagnostic.Code.unsupported_type, h.front.compile("F[T:type](X:T)<computes>:i64{Block{V:Later=Later{};1}};Later:=struct{};A:i64=F[i64](1)").failed.code);
    _ = try h.execute("A:i64=42");
}

test "generic function exact concrete effects preserve source writes and failure rollback" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=7;Store[T:type](X:T,N:i64)<transacts><decides>:T{Block{set Cell=Cell+1;Require[N!=0];X}};A:i64=Attempt(Store[i64][42,1],0);B:i64=Attempt(Store[i64][99,0],Cell);S:string=Attempt(Store[string][\"雪\",1],\"\");C:i64=Cell");
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("C").?.integer);
    try std.testing.expectEqual(@as(u32, 1), x.failure_count);
    try std.testing.expectEqual(types.Diagnostic.Code.set_requires_writes, h.front.compile("var C:i64=1;F[T:type](X:T)<computes>:T{Block{set C=2;X}};Unused:function(tuple(i64),i64)=F[i64]").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.failure_context_required, h.front.compile("F[T:type](X:T)<computes><decides>:T{Block{Require[true];X}};A:i64=F[i64][1]").failed.code);
}

test "generic function concrete self recursion uses guest frames and checked specialization growth" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 31, 32 }) |n| {
        const source = try std.fmt.bufPrint(&h.text, "Keep[T:type](X:T,N:i64)<computes>:T{{If(N==0,X,Keep[T](X,N-1))}};A:i64=Keep[i64](42,{d})", .{n});
        const p = try h.compile(source);
        const r = try h.run(p, 131072);
        if (n == 31) try std.testing.expectEqual(@as(i64, 42), r.ok.get("A").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
        try std.testing.expectEqual(@as(usize, 1), p.functions.len);
    }
    const growing = h.front.compile("Grow[T:type](X:T)<computes>:i64{Grow[option(T)](option{X})};A:i64=Grow[i64](1)");
    try std.testing.expect(growing == .failed);
    try std.testing.expect(growing.failed.code == .function_limit or growing.failed.code == .expression_limit or growing.failed.code == .type_limit or growing.failed.code == .template_limit);
    _ = try h.execute("A:i64=42");
}

test "generic function imported templates retain defining privacy original UTF8 spans and caller nominal types" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    var files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};R:=struct{N:i64};V:R=S.Id[R](R{N:=42});A:i64=V.N;Again:R=S.Id[R](V);C:i64=Again.N;F:function(tuple(),string)=S.Make[string](\"雪\");B:string=F();Same:function(tuple(),string)=S.Make[string](\"雪\");D:string=Same()" },
        .{ .path = "雪.forb", .source = "Label:string=\"雪\";Id<public>[T:type](X:T)<computes>:T{X};Make<public>[T:type](X:T)<computes>:function(tuple(),T){Fn[Saved:T=Id[T](X)]()<computes>:T{Saved}};Hidden[T:type](X:T)<computes>:T{X}" },
    };
    const compiled = h.front.compileBundle(.{ .root = "main.forb", .modules = &files });
    if (compiled == .failed) std.debug.print("generic module: {s}:{d} {s}\n", .{ compiled.failed.path, compiled.failed.diagnostic.span.start, compiled.failed.diagnostic.message() });
    try std.testing.expect(compiled == .ok);
    const x = (try h.run(compiled.ok, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 42), x.get("C").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("D").?.string);
    var buffer: [32768]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const offset = std.mem.indexOf(u8, files[1].source, "Fn[").?;
    var expected: [512]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expected, "\"module\":\"雪.forb\",\"anonymous\":{d},\"specialization\":[2],\"captures\":[\"雪\"]", .{offset});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), needle) != null);
    files[0].source = "S:=import{\"雪.forb\"};A:i64=S.Hidden[i64](42)";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).failed.diagnostic.code);
    files[0].source = "S:=import{\"雪.forb\"};A:i64=1";
    files[1].source = "Secret:=struct{N:i64};Bad<public>[T:type](X:T)<computes>:Secret{Secret{N:=1}}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).failed.diagnostic.code);
    files[1].source = "Secret:=struct{N:i64};Bad<public>[T:type](X:Secret,Y:T)<computes>:T{Y}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).failed.diagnostic.code);
}

test "generic function invalid headers explicit arguments and concrete constraints reject with healthy reuse" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        "F[](X:i64)<computes>:i64{X}",
        "F[T:i64](X:T)<computes>:T{X}",
        "F[T:type,T:type](X:T)<computes>:T{X}",
        "F[T:type](T:T)<computes>:T{T}",
        "F[T:type](X:Unknown)<computes>:T{X}",
        "F[T:type](X:T)<computes>:T{}",
        "F[T:type](X:T)<computes>:T{(X]}",
        "F[T:type](X:T)<computes>:T{X",
        // RFC-0091: `F(42)` reads its type argument off 42; one it cannot read is still refused.
        "F[T:type](X:i64)<computes>:T{X};A:i64=F(42)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[](42)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[i64,string](42)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[42](42)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[string](42)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[i64][42]",
        "F[T:type](X:T)<computes>:T{X};F:i64=1",
        "F(N:i64)<computes>:i64=N;F[T:type](X:T)<computes>:T{X}",
        "F[T:type](X:T)<computes>:T{X};R:=struct{F:i64=F[i64]}",
        "F[T:type](X:T)<computes>:T{X} A:i64=1",
    }) |source| {
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected generic syntax admission: {s}\n", .{source});
        try std.testing.expect(r == .failed);
        _ = try h.execute("A:i64=42");
    }
    const bad_key = h.front.compile("Table[T:type](X:T)<computes>:map(T,i64){map{X=>1}};F:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N};A:map(function(tuple(i64),i64),i64)=Table[function(tuple(i64),i64)](F)");
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_map_key, bad_key.failed.code);
}

test "generic function concrete constructors preserve every immutable kind contextual empty values and float bits" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Id[T:type](X:T)<computes>:T{X};Empty[T:type]()<computes>:T{T{}};R:=struct{N:i64=42};E:=enum{One,Two};A:R=Empty[R]();B:E=Id[E](E.Two);C:[]i64=Empty[[]i64]();D:tuple()=Empty[tuple()]();O:option(string)=Empty[option(string)]();M:map(i64,string)=Empty[map(i64,string)]();F:function(tuple(i64),i64)=Id[function(tuple(i64),i64)](Id[i64]);N:float=Id[float](-0.0);Q:float=Id[float](NaN);Text:string=Id[string](\"雪\");Logic:logic=Id[logic](true);Answer:i64=F(A.N)");
    try std.testing.expectEqual(@as(i64, 42), x.get("Answer").?.integer);
    try std.testing.expectEqual(@as(u32, 1), x.get("B").?.enumeration.index);
    for ([_][]const u8{ "C", "D", "O", "M" }) |name| try std.testing.expectEqual(@as(u32, 0), x.get(name).?.aggregate.elements.end - x.get(name).?.aggregate.elements.start);
    try std.testing.expectEqual(@as(u64, 1) << 63, @as(u64, @bitCast(x.get("N").?.floating)));
    try std.testing.expectEqual(@as(u64, @bitCast(types.canonicalFloat(std.math.nan(f64)))), @as(u64, @bitCast(x.get("Q").?.floating)));
    try std.testing.expectEqualStrings("雪", x.get("Text").?.string);
    try std.testing.expect(x.get("Logic").?.boolean);
}

test "generic function independent metadata admission rejects 2000 specialization identities even unused" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Id[T:type](X:T)<computes>:T{X};A:function(tuple(i64),i64)=Id[i64];B:function(tuple(string),string)=Id[string];C:i64=42");
    try std.testing.expectEqual(@as(usize, 2), p.functions.len);
    for (0..2000) |index| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        switch (index % 12) {
            0 => h.metadata[0].specialization = .i64,
            1 => h.metadata[0].specialization = @fromBackingInt(@intCast(65535)),
            2 => h.metadata[0].specialization = null,
            3 => h.metadata[0].generic_source = .{ .start = 0, .end = 0 },
            4 => h.metadata[0].generic_source.end -= 1,
            5 => h.metadata[0].is_public = true,
            6 => h.metadata[1].specialization = p.functions[0].specialization,
            7 => h.metadata[0].anonymous = true,
            8 => h.metadata[0].generic_source.start += 1,
            9 => h.metadata[1].generic_source.start += 1,
            10 => h.metadata[0].template_public = true,
            11 => {
                h.metadata[0].specialization = null;
                h.metadata[0].generic_source = .{ .start = 0, .end = 0 };
            },
            else => unreachable,
        }
        var forged = p;
        forged.functions = h.metadata[0..p.functions.len];
        try invalid(h, forged);
    }
}

test "generic function oracles independently derive 1000 strict snapshots counted transitions and rollback results" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |seed| {
        const initial: i64 = @intCast(seed % 41);
        const amount: i64 = @intCast(seed % 7 + 1);
        const visits: i64 = @intCast(seed % 9);
        const fail_at: i64 = @intCast(seed % 6);
        const source = try std.fmt.bufPrint(&h.text, "var C:i64={d};Id[T:type](X:T)<computes>:T{{X}};Make[T:type](X:T,A:i64)<computes>:function<transacts><decides>(tuple(i64),i64){{Fn[Saved:T=X,Amount:i64=A](N:i64)<transacts><decides>:i64{{Block{{set C=C+Amount;Require[N!={d}];N+1}}}}}};F:function<transacts><decides>(tuple(i64),i64)=Make[string](\"value\",{d});G:function(tuple(i64),i64)=Id[i64];A:i64=Attempt(Iterate(F,{d},0),-1);B:i64=G(C)", .{ initial, fail_at, amount, visits });
        // The initializer is ordinary typed data; no runtime path uses Saved.
        const x = try h.execute(source);
        const failed = visits > fail_at;
        try std.testing.expectEqual(if (failed) @as(i64, -1) else visits, x.get("A").?.integer);
        try std.testing.expectEqual(if (failed) initial else initial + amount * visits, x.get("B").?.integer);
        try std.testing.expectEqual(@as(u32, @intFromBool(failed)), x.failure_count);
    }
}

test "generic function source and concrete code quotas admit exactly 64 and share 16 source parameters" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 64, 65 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        for (0..count) |i| try out.print("G{d}[T:type](X:T)<computes>:T{{X}};", .{i});
        const r = h.front.compile(out.buffered());
        if (count == 64) {
            try std.testing.expect(r == .ok and h.front.generic_count == 64 and r.ok.functions.len == 0);
        } else try std.testing.expectEqual(types.Diagnostic.Code.function_limit, r.failed.code);
    }
    var out = std.Io.Writer.fixed(&h.text);
    for (0..63) |i| try out.print("G{d}[T:type](X:T)<computes>:T{{X}};", .{i});
    try out.writeAll("K(X:i64)<computes>:i64=X;A:i64=G0[i64](42)");
    const mixed = try h.compile(out.buffered());
    try std.testing.expect(h.front.generic_count + h.front.functions.count == 64);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(mixed, 1000)).ok.get("A").?.integer);
    for ([_]usize{ 64, 65 }) |count| {
        out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Id[T:type](X:T)<computes>:T{X};");
        for (0..count) |i| try out.print("R{d}:=struct{{N:i64=42}};V{d}:R{d}=Id[R{d}](R{d}{{}});", .{ i, i, i, i, i });
        const r = h.front.compile(out.buffered());
        if (count == 64) {
            try std.testing.expectEqual(@as(usize, 64), r.ok.functions.len);
            const x = (try h.run(r.ok, 10000)).ok;
            for (x.program.bindings) |b| try std.testing.expectEqual(@as(i64, 42), x.aggregate_values[x.values[b.node].aggregate.elements.start].integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.function_limit, r.failed.code);
    }
    for ([_]usize{ 16, 17 }) |count| {
        out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("G[");
        for (0..count) |i| try out.print("{s}T{d}:type", .{ if (i == 0) "" else ",", i });
        try out.writeAll("]()<computes>:i64{42};A:i64=G[");
        for (0..count) |i| try out.print("{s}i64", .{if (i == 0) "" else ","});
        try out.writeAll("]()");
        const r = h.front.compile(out.buffered());
        if (count == 16) {
            try std.testing.expectEqual(@as(u32, 0), r.ok.functions[0].parameter_count);
            try std.testing.expectEqual(@as(i64, 42), (try h.run(r.ok, 1000)).ok.get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "generic function fresh materialization exactly exhausts shared compiler work while cached references reuse it" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 1014, 1015 }) |newlines| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("G[T:type]()<computes>:i64{");
        for (0..newlines) |_| try out.writeByte('\n');
        try out.writeAll("42};");
        for (0..64) |i| try out.print("R{d}:=struct{{}};V{d}:i64=G[R{d}]();", .{ i, i, i });
        try out.writeAll("Cached:i64=G[R0]()");
        const r = h.front.compile(out.buffered());
        if (newlines == 1014) {
            try std.testing.expect(r == .ok);
            try std.testing.expectEqual(@as(u32, 65536), h.front.expansion_work);
            try std.testing.expectEqual(@as(usize, 64), r.ok.functions.len);
            const x = (try h.run(r.ok, 10000)).ok;
            for (x.program.bindings) |b| try std.testing.expectEqual(@as(i64, 42), x.values[b.node].integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.compiler_work_limit, r.failed.code);
    }
    _ = try h.execute("A:i64=42");
}

test "generic function inspection23 exact report budgets and temporary specialization wire depth precede output" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Id[T:type](X:T)<computes>:T{X};F<public>:function(tuple(i64),i64)=Id[i64];A:i64=F(42)");
    var buffer: [65536]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    scratch.initialise(report);
    try std.testing.expect(try report.write(&out, x.program) == .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"format\":23") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"generic_source\":") != null);
    out = std.Io.Writer.fixed(&buffer);
    const admitted = try reporting.write(&out, x, true, .{});
    try std.testing.expectEqualStrings("{\"F\":{\"function\":{\"name\":\"Id\",\"module\":null,\"specialization\":[0]}}}\n", out.buffered());
    out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, true, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    for ([_]usize{ 253, 254 }) |depth| {
        var source = std.Io.Writer.fixed(&h.text);
        try source.writeAll("Id[T:type](X:T)<computes>:T{X};F:function(tuple(i64),i64)=Id[i64];");
        for (0..depth) |i| {
            if (i == 0) {
                // Public: a public report prints no value of a type the API cannot name (`fix2`).
                try source.writeAll("R0<public>:=struct{V:function(tuple(i64),i64)};V0:R0=R0{V:=F};");
            } else {
                try source.print("R{d}<public>:=struct{{V:R{d}}};V{d}{s}:R{d}=R{d}{{V:=V{d}}};", .{ i, i - 1, i, if (i + 1 == depth) "<public>" else "", i, i, i - 1 });
            }
        }
        const p = try h.compile(source.buffered());
        const actual = h.runtime.evaluate(p, 10000);
        try std.testing.expect(actual == .ok);
        out = std.Io.Writer.fixed(&buffer);
        if (depth == 253) {
            _ = try reporting.write(&out, actual.ok, true, .{});
        } else {
            try std.testing.expectError(error.ReportLimit, reporting.write(&out, actual.ok, true, .{}));
            try std.testing.expectEqual(@as(usize, 0), out.end);
        }
    }
}

test "generic function full replay rejects 1000 altered code identities capture inputs and descriptors" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("Make[T:type](X:T)<computes>:function(tuple(),T){Fn[Saved:T=X]()<computes>:T{Saved}};F<public>:function(tuple(),i64)=Make[i64](42);G:function(tuple(),string)=Make[string](\"value\");A:i64=F()");
    try std.testing.expectEqual(@as(usize, 4), x.program.functions.len);
    var buffer: [32768]u8 = undefined;
    for (0..1000) |index| {
        @memcpy(h.metadata[0..x.program.functions.len], x.program.functions);
        @memcpy(h.values[0..x.values.len], x.values);
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        @memcpy(h.members[0..x.aggregate_values.len], x.aggregate_values);
        var forged = x;
        forged.program.functions = h.metadata[0..x.program.functions.len];
        forged.values = h.values[0..x.values.len];
        forged.call_steps = h.steps[0..x.call_steps.len];
        forged.aggregate_values = h.members[0..x.aggregate_values.len];
        const binding = x.program.bindings[0].node;
        switch (index % 10) {
            0 => h.metadata[0].specialization = .i64,
            1 => h.metadata[0].generic_source.end -= 1,
            2 => h.metadata[0].is_public = true,
            3 => h.values[binding].callable.function = 2,
            4 => h.values[binding].callable.captures.end += 1,
            5 => h.steps[0].value = .{ .integer = 43 },
            6 => h.steps[0].function = 3,
            7 => h.members[0] = .{ .integer = 43 },
            8 => {
                h.metadata[0].specialization = null;
                h.metadata[0].generic_source = .{ .start = 0, .end = 0 };
            },
            9 => {
                h.metadata[1].specialization = null;
                h.metadata[1].generic_source = .{ .start = 0, .end = 0 };
            },
            else => unreachable,
        }
        var out = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, true, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{});
}

test "generic effect parameters specialize pure and transacting callbacks with distinct reusable identities" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=1;Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{F(F(X))};Inc(N:i64)<computes>:i64=N+1;Bump(N:i64)<transacts>:i64=Block{set Cell=Cell+N;Cell};Pure<public>:i64=Apply[computes,i64](Inc,5);Moved<public>:i64=Apply[transacts,i64](Bump,2);Again<public>:i64=Apply[computes,i64](Inc,7);Total<public>:i64=Pure+Moved+Cell");
    try std.testing.expectEqual(@as(i64, 7), x.get("Pure").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("Moved").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("Again").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("Cell").?.integer);
    try std.testing.expectEqual(@as(i64, 19), x.get("Total").?.integer);
    var specialized: usize = 0;
    var first: ?types.Type = null;
    for (x.program.functions) |f| {
        if (f.specialization == null) continue;
        specialized += 1;
        try std.testing.expect(f.transacts == (specialized == 2));
        if (first) |earlier| try std.testing.expect(earlier != f.specialization.?) else first = f.specialization;
    }
    // Apply[computes,i64] is reused by the third reference; only two specializations exist.
    try std.testing.expectEqual(@as(usize, 2), specialized);
}

test "generic effect parameters carry decides and forward through nested specializations" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0;Pass[E:effect](F:function<E>(tuple(i64),i64),X:i64)<E>:i64{F[X]};Via[E:effect](F:function<E>(tuple(i64),i64),X:i64)<E>:i64{Pass[E][F,X]};Pos(N:i64)<computes><decides>:i64=Block{Require[N>0];N};Mark(N:i64)<transacts><decides>:i64=Block{set Cell=Cell+1;Require[N>0];N};A<public>:i64=Attempt(Via[computes<decides>][Pos,3],0);B<public>:i64=Attempt(Via[computes<decides>][Pos,-3],-1);C<public>:i64=Attempt(Via[transacts<decides>][Mark,4],0);D<public>:i64=Attempt(Via[transacts<decides>][Mark,-4],-1)");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
    // The failed transacting attempt rolls its write back; only the successful one commits.
    try std.testing.expectEqual(@as(i64, 1), x.get("Cell").?.integer);
}

test "generic effect parameters check each concrete body and reject misuse with healthy reuse" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        // A body that writes source state is invalid when the effect is computes.
        "var C:i64=0;W[E:effect](X:i64)<E>:i64{Block{set C=X;X}};A:i64=W[computes](1)",
        // A transacting callback cannot satisfy a computes function type.
        "Apply[E:effect](F:function<E>(tuple(i64),i64),X:i64)<E>:i64{F(X)};var C:i64=0;Bump(N:i64)<transacts>:i64=Block{set C=N;N};A:i64=Apply[computes](Bump,1)",
        // Effect parameters are not types and type parameters are not effects.
        "F[E:effect](X:E)<computes>:i64{1}",
        "F[T:type](X:i64)<T>:i64{X}",
        "F[E:effect](X:i64)<E>:i64{X};A:i64=F[i64](1)",
        "F[T:type](X:T)<computes>:T{X};A:i64=F[computes](1)",
        "F[E:effect](X:i64)<E>:i64{X};A:i64=F[pure](1)",
        "F[E:effect](X:i64)<E>:i64{X};A:i64=F[transacts<computes>](1)",
        // The parameter already carries its decides bit.
        "F[E:effect](X:i64)<E><decides>:i64{X};A:i64=F[computes](1)",
        "F[E:effect,E:type](X:i64)<E>:i64{X}",
        "F[E:effect](E:i64)<E>:i64{E}",
        "F(X:i64)<E>:i64=X",
    }) |source| {
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected effect parameter admission: {s}\n", .{source});
        try std.testing.expect(r == .failed);
        _ = try h.execute("A:i64=42");
    }
    const mismatch = h.front.compile("var C:i64=0;W[E:effect](X:i64)<E>:i64{Block{set C=X;X}};A:i64=W[computes](1)");
    try std.testing.expectEqual(types.Diagnostic.Code.set_requires_writes, mismatch.failed.code);
    // Valid with transacts.
    const ok = try h.execute("var C:i64=0;W[E:effect](X:i64)<E>:i64{Block{set C=X;X}};A:i64=W[transacts](1)");
    try std.testing.expectEqual(@as(i64, 1), ok.get("C").?.integer);
}

test "generic effect witnesses are the only admitted effect arguments in specialization keys" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{F(X)};Inc(N:i64)<computes>:i64=N+1;Decoy:tuple(i64,i64)=tuple{1,2};Plain:tuple(i64,i64)=tuple{3,4};A:i64=Apply[computes,i64](Inc,5)");
    var decoy: ?types.Type = null;
    for (p.definitions, 0..) |d, index| {
        if (d == .tuple and d.tuple.end - d.tuple.start == 2 and p.tuple_elements[d.tuple.start] == .i64 and p.tuple_elements[d.tuple.start + 1] == .i64) decoy = @fromBackingInt(@intCast(index + 4));
    }
    try std.testing.expect(decoy != null);
    var target: usize = 0;
    for (p.functions, 0..) |f, index| if (f.specialization != null) {
        target = index;
    };
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[target].specialization = decoy;
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    try invalid(h, forged);
    // An unforged program still admits and runs.
    try std.testing.expectEqual(@as(i64, 6), (try h.run(p, 4096)).ok.get("A").?.integer);
}

test "generic bodies keep failure contexts and control depth scoped to their own body" {
    const h = try create();
    defer scratch.release(h);
    // A caller's Attempt must not make a computes body's Require legal, whichever reference comes first.
    for ([_][]const u8{
        "G[T:type](X:T)<computes>:T{Block{Require[true];X}};A:i64=Attempt(G[i64](1),0)",
        "A:i64=Attempt(Fn(N:i64)<computes>:i64{Block{Require[N>0];N}}(1),0)",
        "G[T:type](X:T)<computes>:T{Block{Require[true];X}};B:i64=G[i64](1);A:i64=Attempt(G[i64](1),0)",
    }) |source| {
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected failure context admission: {s}\n", .{source});
        try std.testing.expectEqual(types.Diagnostic.Code.failure_context_required, r.failed.code);
        _ = try h.execute("A:i64=42");
    }
    // A body inside its own Attempt remains legal even when called from an Attempt.
    const ok = try h.execute("G[T:type](X:T)<computes>:T{Attempt(Block{Require[true];X},X)};A:i64=Attempt(G[i64](5),0)");
    try std.testing.expectEqual(@as(i64, 5), ok.get("A").?.integer);
    // Callers may nest conditionals up to the limit; a generic body has its own full budget.
    var buffer: [16 * types.limits.control_depth + 512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("G[T:type](X:T)<computes>:T{If(true,X,X)};A:i64=");
    for (0..types.limits.control_depth - 1) |_| try out.writeAll("If(true,");
    try out.writeAll("G[i64](1)");
    for (0..types.limits.control_depth - 1) |_| try out.writeAll(",0)");
    try std.testing.expectEqual(@as(i64, 1), (try h.execute(out.buffered())).get("A").?.integer);
}

test "generic admission rejects shared parameter budget overflow in both machines" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("Id[T:type](X:T)<computes>:T{X};A:function(tuple(i64),i64)=Id[i64]");
    try std.testing.expectEqual(@as(usize, 1), p.functions.len);
    @memcpy(h.metadata[0..1], p.functions);
    h.metadata[0].parameter_count = types.limits.parameters;
    var forged = p;
    forged.functions = h.metadata[0..1];
    try invalid(h, forged);
}

test "effect parameters cannot take effect keywords or be used as same-named types" {
    const h = try create();
    defer scratch.release(h);
    for ([_][]const u8{
        "var C:i64=0;W[computes:effect](X:i64)<computes>:i64{Block{set C=X;X}};A:i64=W[transacts](1)",
        "W[decides:effect](X:i64)<decides>:i64{X}",
        "W[type:type](X:i64)<computes>:i64{X}",
        "E:=struct{N:i64=0};F[E:effect](X:E)<computes>:i64{1};A:i64=F[computes](E{})",
    }) |source| {
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected effect parameter admission: {s}\n", .{source});
        try std.testing.expect(r == .failed);
        _ = try h.execute("A:i64=42");
    }
}
