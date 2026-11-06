//! Independent lexical scope, sequence, quota and rollback oracles.
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
                std.debug.print("local block compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("local block run {s}\n", .{r.failed.message()});
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

/// RFC-0076: `source` is rejected because a declaration shadows a visible name; `at` is the
/// byte where the name of that inner declaration starts.
fn expectShadowed(h: *Harness, source: []const u8, at: usize) !void {
    const r = h.front.compile(source);
    try std.testing.expect(r == .failed);
    if (r.failed.code != .shadowed_name or r.failed.span.start != at) std.debug.print("expected shadowed_name at {d}, found {s} at {d}: {s}\n", .{ at, r.failed.message(), r.failed.span.start, source });
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, r.failed.code);
    try std.testing.expectEqual(at, @as(usize, r.failed.span.start));
}

test "blocks reject shadowing and keep nested scopes earlier aliases and root names without published local bindings" {
    const h = try create();
    defer scratch.release(h);
    // RFC-0076: a block local may not have the name of a parameter, of a local of a block
    // around it, or of an earlier root name. (This test pinned that each of these shadowed.)
    const parameter = "F(N:i64)<computes>:i64=Block{N:i64=N+1;N};Value:i64=F(4)";
    try expectShadowed(h, parameter, std.mem.indexOf(u8, parameter, "{N").? + 1);
    const nested = "F(N:i64)<computes>:i64=Block{M:i64=N+1;Inner:i64=Block{M:i64=M+2;M*3};M+Inner};Value:i64=F(4)";
    try expectShadowed(h, nested, std.mem.lastIndexOf(u8, nested, "{M").? + 1);
    const nested_root = "Value:i64=Block{X:i64=1;Block{X:i64=2;X}}";
    try expectShadowed(h, nested_root, std.mem.lastIndexOf(u8, nested_root, "{X").? + 1);
    const root = "Base:i64=3;B:i64=Block{Base:i64=Base+1;Base}";
    try expectShadowed(h, root, std.mem.indexOf(u8, root, "{Base").? + 1);
    // The same program with each inner name renamed: the values are the ones it had.
    const x = try h.execute(
        \\Base:i64=3
        \\F(N:i64)<computes>:i64=Block{M:i64=N+1;Held:i64=M;Inner:i64=Block{K:i64=M+2;K*3};M+Held+Inner}
        \\A:i64=F(4);B:i64=Block{Local:i64=Base+1;Local};Value:i64=Base+A+B
    );
    try std.testing.expectEqual(@as(i64, 31), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 38), x.get("Value").?.integer);
    try std.testing.expect(x.get("Held") == null and x.get("N") == null and x.get("M") == null and x.get("K") == null and x.get("Local") == null and h.front.local_count == 0);
    const aliases = try h.execute("F(N:i64)<computes>:i64=Block{X:i64=N;X};Value:i64=F(7)");
    try std.testing.expectEqual(@as(i64, 7), aliases.get("Value").?.integer);
    try std.testing.expectEqual(@as(usize, 0), aliases.program.functions.len);
}

test "blocks execute discarded expressions strictly and may return an earlier register after later work" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<computes>:i64=Block{Held:i64=N+1;N+2;Held};Value:i64=F(4)");
    try std.testing.expect(p.functions[0].root + 1 < p.functions[0].body.end - p.functions[0].body.start);
    try std.testing.expectEqual(@as(i64, 5), (try h.run(p, 100)).ok.get("Value").?.integer);
    for ([_][]const u8{
        "Value:i64=Block{Unused:i64=1/0;7}",
        "F(N:i64)<computes>:i64=Block{N+1;1/0;N};Value:i64=F(4)",
        "Keep(N:i64)<computes>:i64=7;Value:i64=Keep(Block{1/0;4})",
    }) |source| try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(try h.compile(source), 100)).failed.code);
    _ = try h.execute("Value:i64=Block{7;}");
}

test "blocks keep source snapshots lazy arms failure contexts and sibling fallback scopes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=1
        \\F(N:i64)<transacts>:i64=Block{
        \\ Old:i64=C
        \\ Ignored:i64=Attempt(Block{Tmp:i64=Set(C,N);Fail["stop"];Tmp},Block{Tmp:i64=Set(C,Old+7);Tmp})
        \\ Old+Ignored
        \\}
        \\set C=2;A:i64=F(4)
        \\B:i64=If(true,Block{X:i64=5;X},Block{X:i64=1/0;X})
        \\D:i64=Attempt(Block{X:i64=8;Set(C,X);Fail["root"];X},Block{X:i64=C;X})
        \\Value:i64=C+A+B+D
    );
    try std.testing.expectEqual(@as(i64, 11), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 34), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 2), x.failure_count);
    try std.testing.expect(x.failures[0].function != null and x.failures[1].function == null);
}

test "blocks reject duplicate self escape immutable targets reserved declarations and mismatched types" {
    const h = try create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "Value:i64=Block{X:i64=1;X:i64=2;X}", .code = .duplicate_name },
        .{ .source = "Value:i64=Block{X:i64=X;X}", .code = .unknown_name },
        .{ .source = "Value:i64=Block{Block{X:i64=1;X};X}", .code = .unknown_name },
        .{ .source = "A:i64=If(true,Block{X:i64=1;X},X)", .code = .unknown_name },
        .{ .source = "A:i64=Attempt(Block{X:i64=1;Fail[\"x\"];X},X)", .code = .unknown_name },
        .{ .source = "Value:i64=Block{X:logic=1;7}", .code = .type_mismatch },
        // RFC-0076: the local may not take the name of the root `var` (it shadowed it, and the
        // `Set` then found an immutable target); under a name of its own it is still immutable.
        .{ .source = "var C:i64=1;Value:i64=Block{C:i64=2;Set(C,3)}", .code = .shadowed_name },
        .{ .source = "var C:i64=1;Value:i64=Block{D:i64=2;Set(D,3)}", .code = .not_mutable },
        .{ .source = "Value:i64=Block{X<public>:i64=1;X}", .code = .unknown_name },
        .{ .source = "Block:i64=1", .code = .expected_name },
        .{ .source = "F(Block:i64)<computes>:i64=1", .code = .expected_parameter },
        .{ .source = "Value:i64=Block{}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{X:i64=1}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{X:i64=1;}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{X:i64=;7;X}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{1+;7}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{Require[true];7}", .code = .failure_context_required },
        .{ .source = "var C:i64=1;F()<computes>:i64=Block{X:i64=C;X}", .code = .variable_read_requires_reads },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.code, h.front.compile(case.source).failed.code);
        try std.testing.expectEqual(@as(i64, 42), (try h.execute("Value:i64=Block{X:i64=42;X}")).get("Value").?.integer);
    }
}

test "blocks admit exact 256 live names reuse closed scopes and reject the 257th name" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 256, 257 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Value:i64=Block{");
        for (0..count) |i| try out.print("X{d}:i64={d};", .{ i, i });
        try out.writeAll("X255}");
        const result = h.front.compile(out.buffered());
        if (count == 256) try std.testing.expectEqual(@as(i64, 255), (try h.run(result.ok, 1000)).ok.get("Value").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.local_binding_limit, result.failed.code);
    }
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("Value:i64=Block{Keep:i64=7;");
    for (0..4) |_| {
        try out.writeAll("Block{");
        for (0..255) |i| try out.print("X{d}:i64={d};", .{ i, i });
        try out.writeAll("X254};");
    }
    try out.writeAll("Keep}");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("Value").?.integer);
    for ([_]usize{ 128, 129 }) |depth| {
        out = .fixed(&h.text);
        try out.writeAll("Value:i64=");
        for (0..depth) |_| try out.writeAll("Block{");
        try out.writeAll("7");
        for (0..depth) |_| try out.writeAll("}");
        const result = h.front.compile(out.buffered());
        if (depth == 128) try std.testing.expectEqual(@as(i64, 7), (try h.run(result.ok, 100)).ok.get("Value").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, result.failed.code);
    }
}

test "blocks retain all immutable Value kinds contextual empties aliases and definition site defaults" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\mode:=enum{One,Two};row:=struct{Name:string,Size:i64};Seed:i64=4
        \\defaults:=struct{Value:i64=Block{Next:i64=Seed+1;Next},Names:[]string=Block{A:[]string=array{"雪"};A}}
        \\Make(N:i64)<computes>:defaults=Block{Local:i64=N;defaults{}}
        \\I:i64=Block{X:i64=7;X};S:string=Block{X:string="雪";X};L:logic=Block{X:logic=true;X}
        \\F:float=Block{X:float=NaN;X};Zero:float=Block{X:float=-0.0;X}
        \\R:row=Block{X:row=row{Name:="雪",Size:=7};X};E:mode=Block{X:mode=mode.Two;X}
        \\A:[]i64=Block{X:[]i64=array{7};Alias:[]i64=X;Alias}
        \\T:tuple(i64,string)=Block{X:tuple(i64,string)=tuple{7,"雪"};X}
        \\O:option(i64)=Block{X:option(i64)=option{};X};M:map(string,i64)=Block{X:map(string,i64)=map{"雪"=>7};X}
        \\D:defaults=Make(99);Value:i64=D.Value+D.Names.Length
    );
    try std.testing.expectEqual(@as(i64, 6), x.get("Value").?.integer);
    try std.testing.expectEqualStrings("雪", x.get("S").?.string);
    try std.testing.expect(std.math.isNan(x.get("F").?.floating));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("O").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("M").?).?.len);
}

test "blocks agree with 1000 independent scoped strict write rollback and snapshot oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const base: i64 = @as(i64, @intCast(i % 19)) - 7;
        const n: i64 = @as(i64, @intCast(i % 23)) - 8;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64={d};F(N:i64)<transacts>:i64=Block{{Old:i64=C;R:i64=Attempt(Block{{M:i64=Set(C,C+N);If(Require[M>=0],M,M)}},Block{{M:i64=Set(C,Old+7);M}});Old+R}};A:i64=F({d});Value:i64=C", .{ base, n });
        const x = try h.execute(out.buffered());
        const expected = if (base + n >= 0) base + n else base + 7;
        try std.testing.expectEqual(expected, x.get("Value").?.integer);
        try std.testing.expectEqual(base + expected, x.get("A").?.integer);
        try std.testing.expectEqual(@as(u32, if (base + n >= 0) 0 else 1), x.failure_count);
    }
}

test "blocks preserve defining nominal UTF8 modules and separate annotation and value namespaces" {
    const h = try create();
    defer scratch.release(h);
    // RFC-0076: a local may not have the name of the import alias (it did, and `S.Row` after it
    // was still the module's type), nor of an earlier binding of its module.
    const shadowing = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Block{S:i64=7;R:S.Row=Held;S+R.Size}" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<computes>:Row=Block{Sum:i64=Hidden+N;Row{Name:=\"雪\",Size:=Sum}}" },
    };
    const alias = h.front.compileBundle(.{ .root = "main.forb", .modules = &shadowing }).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, alias.diagnostic.code);
    try std.testing.expectEqualStrings("main.forb", alias.path);
    var hidden = shadowing;
    hidden[0].source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Held.Size";
    hidden[1].source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<computes>:Row=Block{Hidden:i64=Hidden+N;Row{Name:=\"雪\",Size:=Hidden}}";
    const binding = h.front.compileBundle(.{ .root = "main.forb", .modules = &hidden }).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, binding.diagnostic.code);
    try std.testing.expectEqualStrings("雪.forb", binding.path);
    // Renamed, the local value sits beside the module's types and the values are the same.
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Block{Seven:i64=7;R:S.Row=Held;Seven+R.Size}" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<computes>:Row=Block{Sum:i64=Hidden+N;Row{Name:=\"雪\",Size:=Sum}}" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok;
    try std.testing.expectEqual(@as(i64, 14), (try h.run(p, 1000)).ok.get("Value").?.integer);
    var changed = inputs;
    changed[0].source = "S:=import{\"雪.forb\"};Value:i64=Block{X:i64=S.Hidden;X}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &changed }).failed.diagnostic.code);
    changed[0].source = "S:=import{\"雪.forb\"};Value:i64=Block{X:i64=Attempt(S.Bad[],7);X}";
    changed[1].source = "Bad<public>()<computes><decides>:i64=Block{X:i64=7;Fail[\"雪\"];X}";
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &changed }).ok, 100)).ok;
    try std.testing.expectEqual(@as(i64, 7), x.get("Value").?.integer);
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try trace_report.write(&out, x, "wrong.forb", .{});
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    const trace = json.value.object.get("failures").?.array.items[0].object;
    try std.testing.expectEqualStrings("雪.forb", trace.get("path").?.string);
    try std.testing.expectEqualStrings("雪", trace.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(std.mem.indexOf(u8, changed[1].source, "Fail").? + 1)), trace.get("column").?.integer);
}

test "blocks admit exact visited fuel and physical member capacity without recycling snapshots" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=1;F(N:i64)<transacts>:i64=Block{X:i64=N+1;Set(C,C+X);X};Value:i64=F(3)");
    const x = (try h.run(p, 100)).ok;
    const exact: u32 = @intCast(std.mem.count(bool, x.activity, &.{true}) + x.call_steps.len);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, exact - 1)).failed.code);
    try std.testing.expectEqual(@as(i64, 4), (try h.run(p, exact)).ok.get("Value").?.integer);
    for ([_]usize{ 32, 33 }) |calls| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("var A:[]i64=array{};F()<transacts>:[]i64=Block{Held:[]i64=A;Element:i64=1;Set(A,array{");
        for (0..255) |i| try out.print("{s}Element", .{if (i == 0) "" else ","});
        try out.writeAll("});Held};Items:[][]i64=array{");
        for (0..calls) |i| try out.print("{s}F()", .{if (i == 0) "" else ","});
        try out.writeAll("}");
        const result = try h.run(try h.compile(out.buffered()), 65536);
        if (calls == 32) {
            try std.testing.expectEqual(@as(usize, 8192), result.ok.aggregate_values.len);
            const items = result.ok.elements(result.ok.get("Items").?).?;
            try std.testing.expectEqual(@as(usize, 0), result.ok.elements(items[0]).?.len);
            try std.testing.expectEqual(@as(usize, 255), result.ok.elements(items[1]).?.len);
        } else {
            try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, result.failed.code);
            try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
        }
    }
    _ = try h.execute("Value:i64=Block{7}");
}

test "blocks retain independent arm admission earlier root copies and exact report work before output" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<computes>:i64=If(L,Block{X:i64=7;X+1},Block{X:i64=9;X+2});Value:i64=F(true)");
    var forged = p;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    var left: u32 = undefined;
    for (p.function_nodes, 0..) |entry, index| if (entry.node.kind == .binary) {
        left = @intCast(index);
        break;
    };
    for (0..1000) |_| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        for (h.body[left + 1 .. p.function_nodes.len]) |*entry| if (entry.node.kind == .binary) {
            entry.node.kind.binary.lhs = left;
        };
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 100).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, 100).failed.code);
    }
    const x = try h.execute("var C:i64=1;F()<transacts>:i64=Block{Held:i64=C;Set(C,3);Held};Value:i64=F()");
    @memcpy(h.values[0..x.values.len], x.values);
    var invalid = x;
    invalid.values = h.values[0..x.values.len];
    for (x.program.nodes, 0..) |node, index| if (node.kind == .call) {
        h.values[index] = .{ .integer = 3 };
    };
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, invalid, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const admitted = try reporting.validate(x, false, .{});
    out = .fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
