//! Independent mutable-local state, version selection and rollback oracles.
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
                std.debug.print("mutable local compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
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
            std.debug.print("mutable local run {s}\n", .{r.failed.message()});
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

test "mutable locals reject shadowing and retain strict assignments nested scopes and immutable earlier snapshots" {
    const h = try create();
    defer scratch.release(h);
    // RFC-0076: a parameter may not have the name of an earlier root `var`, and a `var` local
    // may not have the name of a parameter, of a root `var`, or of a local of a block around
    // it. (This test pinned that each of these shadowed.)
    const parameter = "var N:i64=100;F(N:i64)<transacts>:i64=N+1";
    try expectShadowed(h, parameter, std.mem.indexOf(u8, parameter, "(N").? + 1);
    const local = "F(N:i64)<transacts>:i64=Block{var N:i64=N+1;set N=N+2;N}";
    try expectShadowed(h, local, std.mem.indexOf(u8, local, "var N").? + 4);
    const root = "var N:i64=100;Value:i64=Block{var N:i64=N+1;set N=N+3;N}";
    try expectShadowed(h, root, std.mem.lastIndexOf(u8, root, "var N").? + 4);
    const nested = "Value:i64=Block{var M:i64=1;Inner:i64=Block{var M:i64=M+10;set M=M+2;M};M+Inner}";
    try expectShadowed(h, nested, std.mem.lastIndexOf(u8, nested, "var M").? + 4);
    // The same program with each inner name renamed: the values are the ones it had.
    const x = try h.execute(
        \\var N:i64=100
        \\F(P:i64)<transacts>:i64=Block{var M:i64=P+1;Old:i64=M;set M=M+2;Set(M,M+3);Old+M}
        \\A:i64=F(4)
        \\Value:i64=Block{var M:i64=N+1;Old:i64=M;Inner:i64=Block{var K:i64=M+10;set K=K+2;K};set M=M+3;Set(M,M+4);Old+M+Inner+A}
    );
    try std.testing.expectEqual(@as(i64, 100), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 15), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 337), x.get("Value").?.integer);
    try std.testing.expect(x.program.functions[0].transacts and x.program.functions[0].has_local and !x.program.functions[0].has_source);
    try std.testing.expect(x.call_steps.len > 0 and x.get("Old") == null);
    try std.testing.expect(h.front.local_count == 0 and h.front.local_checkpoint_count == 0);
    try std.testing.expectEqual(@as(i64, 8), (try h.execute("var C:i64=1;Value:i64=Block{set C=8;C}")).get("C").?.integer);
}

test "mutable locals select only the chosen arm and save versions after condition mutations" {
    const h = try create();
    defer scratch.release(h);
    for ([_]bool{ true, false }) |choice| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("Value:i64=Block{{var X:i64=1;Old:i64=X;R:i64=If(Block{{set X=X+1;{s}}},Block{{set X=X+10;X}},Block{{set X=X+100;X}});Old+R+X}}", .{if (choice) "true" else "false"});
        try std.testing.expectEqual(@as(i64, if (choice) 25 else 205), (try h.execute(out.buffered())).get("Value").?.integer);
    }
    const x = try h.execute("F(L:logic)<transacts>:i64=Block{var X:i64=3;R:i64=If(L,Block{Set(X,9);X},Block{1/0;X});X+R};Value:i64=F(true)");
    try std.testing.expectEqual(@as(i64, 18), x.get("Value").?.integer);
}

test "mutable locals restore nested successful region versions before outer fallback and mix global rollback" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=1
        \\Bad()<transacts><decides>:i64=Block{var X:i64=90;Set(C,30);Fail["child"];X}
        \\F()<transacts>:i64=Block{var X:i64=3;Old:i64=X;R:i64=Attempt(Block{set X=9;Set(C,10);Attempt(Block{Set(X,11);Set(C,20);X},X);Bad[];X},Block{set X=X+2;Set(C,C+X);X});Old+R+X}
        \\A:i64=F()
        \\Value:i64=Block{var X:i64=7;Attempt(Block{Set(X,21);Set(C,50);Fail["root"];X},Block{Set(X,X+2);X});A+X+C}
    );
    try std.testing.expectEqual(@as(i64, 13), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 28), x.get("Value").?.integer);
    try std.testing.expectEqual(@as(u32, 2), x.failure_count);
}

test "mutable locals preserve all Value snapshots contextual collections and nominal types" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\mode:=enum{One,Two};row:=struct{Name:string,Size:i64}
        \\F()<transacts>:row=Block{var R:row=row{Name:="雪",Size:=1};Held:row=R;var A:[]i64=array{1};Old:[]i64=A;var M:map(string,i64)=map{"雪"=>1};var O:option(i64)=option{};var T:tuple(i64,string)=tuple{1,"雪"};var E:mode=mode.One;var B:logic=false;var S:string="雪";var Z:float=-0.0;var N:float=NaN;Attempt(Block{Set(R,row{Name:="new",Size:=2});Set(A,array{2});Set(M,map{"雪"=>2});Set(O,option{2});Set(T,tuple{2,"new"});Set(E,mode.Two);Set(B,true);Set(S,"new");Set(Z,1.0);Set(N,2.0);Fail["undo"];R},R);Set(R,row{Name:=S,Size:=Held.Size+Or(Lookup(M,"雪"),0)+Old.Length+T(0)});R}
        \\Value:row=F()
        \\Zero:float=Block{var X:float=-0.0;Held:float=X;Set(X,1.0);Held}
        \\Nan:float=Block{var X:float=NaN;Attempt(Block{Set(X,1.0);Fail["undo"];X},X);X}
    );
    const row = x.elements(x.get("Value").?).?;
    try std.testing.expectEqualStrings("雪", row[0].string);
    try std.testing.expectEqual(@as(i64, 4), row[1].integer);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(x.get("Zero").?.floating)));
    try std.testing.expect(std.math.isNan(x.get("Nan").?.floating));
}

test "mutable locals reject immutable targets computes defaults missing values type errors and scope escape" {
    const h = try create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, code: types.Diagnostic.Code };
    for ([_]Case{
        .{ .source = "Value:i64=Block{X:i64=1;Set(X,2)}", .code = .not_mutable },
        // RFC-0076: the local may not take the name of the root `var` (it shadowed it, and the
        // `set` then found an immutable target); under a name of its own it is still immutable.
        .{ .source = "var X:i64=1;Value:i64=Block{X:i64=2;set X=3;X}", .code = .shadowed_name },
        .{ .source = "var X:i64=1;Value:i64=Block{Y:i64=2;set Y=3;Y}", .code = .not_mutable },
        .{ .source = "F(X:i64)<transacts>:i64=Block{set X=3;X}", .code = .not_mutable },
        .{ .source = "F()<computes>:i64=Block{var X:i64=1;X}", .code = .local_var_requires_writes },
        .{ .source = "defaults:=struct{X:i64=Block{var Y:i64=1;Y}}", .code = .local_var_requires_writes },
        .{ .source = "Value:i64=Block{var X:i64=X;X}", .code = .unknown_name },
        .{ .source = "Value:i64=Block{var X:i64=1;X:i64=2;X}", .code = .duplicate_name },
        .{ .source = "Value:i64=Block{var X:logic=1;7}", .code = .type_mismatch },
        .{ .source = "Value:i64=Block{var X:i64=1;Set(X,true)}", .code = .type_mismatch },
        .{ .source = "Value:i64=Block{var X:i64=1;set X=true;X}", .code = .type_mismatch },
        .{ .source = "Value:i64=Block{set X=1;7}", .code = .unknown_name },
        .{ .source = "Value:i64=Block{var X:i64=;7}", .code = .expected_expression },
        .{ .source = "var C:i64=1;Value:i64=Block{var X:i64=set C=2;X}", .code = .expected_expression },
        .{ .source = "var C:i64=1;Value:i64=Block{set C=set C=2;C}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{var X:i64=1,2;X}", .code = .unexpected_token },
        .{ .source = "Value:i64=Block{var X:i64=1;set X=;X}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{var X:i64=1}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{var X:i64=1;set X=2}", .code = .expected_expression },
        .{ .source = "Value:i64=Block{Block{var X:i64=1;X};Set(X,2)}", .code = .unknown_name },
        .{ .source = "Value:i64=Attempt(Block{var X:i64=1;Fail[\"x\"];X},X)", .code = .unknown_name },
    }) |c| {
        const r = h.front.compile(c.source);
        try std.testing.expect(r == .failed);
        if (r == .failed and r.failed.code != c.code) std.debug.print("wrong diagnostic {s}: {s}\n", .{ c.source, r.failed.message() });
        try std.testing.expectEqual(c.code, r.failed.code);
        try std.testing.expectEqual(@as(i64, 42), (try h.execute("Value:i64=Block{var X:i64=42;X}")).get("Value").?.integer);
    }
}

test "mutable locals admit 256 grouped state versions reject the next name and reuse closed prefixes" {
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 256, 257 }) |count| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Value:i64=Block{");
        for (0..count) |i| try out.print("var X{d}:i64={d};", .{ i, i });
        try out.writeAll("If(false,Set(X255,1),Set(X255,999));X255}");
        const r = h.front.compile(out.buffered());
        if (count == 256) {
            try std.testing.expectEqual(@as(i64, 999), (try h.run(r.ok, 10000)).ok.get("Value").?.integer);
            try std.testing.expect(h.front.local_count == 0 and h.front.local_checkpoint_count == 0);
        } else try std.testing.expectEqual(types.Diagnostic.Code.local_binding_limit, r.failed.code);
    }
    var out = std.Io.Writer.fixed(&h.text);
    try out.writeAll("Value:i64=Block{var Keep:i64=7;");
    for (0..4) |_| {
        try out.writeAll("Block{");
        for (0..255) |i| try out.print("var X{d}:i64={d};", .{ i, i });
        try out.writeAll("If(true,Set(X254,3),X254);X254};");
    }
    try out.writeAll("Keep}");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("Value").?.integer);
}

test "mutable locals admit exactly 32 live checkpoints and restore every failed region" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 32, 33 }) |depth| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("Value:i64=Block{var X:i64=1;");
        for (0..depth) |_| try out.writeAll("Attempt(Block{Set(X,X+1);");
        try out.writeAll("Fail[\"undo\"];X");
        for (0..depth) |_| try out.writeAll("},X)");
        try out.writeAll(";X}");
        const r = h.front.compile(out.buffered());
        if (depth == 32) try std.testing.expectEqual(@as(i64, 32), (try h.run(r.ok, 10000)).ok.get("Value").?.integer) else try std.testing.expectEqual(types.Diagnostic.Code.control_limit, r.failed.code);
    }
    _ = try h.execute("Value:i64=Block{var X:i64=1;X}");
}

test "mutable locals agree with 1000 independent branch condition commit rollback and global state oracles" {
    const h = try create();
    defer scratch.release(h);
    for (0..1000) |i| {
        const base: @TypeOf(@as(i64, 0)) = @as(i64, @intCast(i % 97)) - 48;
        const n = @as(i64, @intCast(i % 23)) - 11;
        var out = std.Io.Writer.fixed(&h.text);
        try out.print("var C:i64={d};F(N:i64)<transacts>:i64=Block{{var X:i64={d};Old:i64=X;R:i64=Attempt(Block{{If(Block{{set X=X+1;N>=0}},Set(X,X+N),Set(X,X-N));Set(C,C+X);If(Require[N>=0],X,X)}},Block{{set X=X+7;Set(C,C+X);X}});Old+R+X}};A:i64=F({d});Value:i64=A+C", .{ base, base, n });
        const final = if (n >= 0) base + 1 + n else base + 7;
        const expected = 2 * base + 3 * final;
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("Value").?.integer);
        try std.testing.expectEqual(base + final, x.get("C").?.integer);
    }
}

test "mutable local unused effects and operand types are admitted independently before execution" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<transacts>:i64=Block{var X:i64=N;Set(X,7);X};G()<transacts>:i64=F(1);Value:i64=9");
    var malformed = p;
    malformed.functions = h.metadata[0..p.functions.len];
    malformed.function_nodes = h.body[0..p.function_nodes.len];
    for (0..2000) |i| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        switch (i % 5) {
            0 => h.metadata[0].transacts = false,
            1 => h.metadata[0].has_local = false,
            2 => h.metadata[1].has_local = false,
            3 => for (h.body[0..p.function_nodes.len]) |*entry| {
                if (entry.node.kind == .local_set) entry.node.kind.local_set = types.limits.template_nodes;
            },
            else => for (h.body[0..p.function_nodes.len]) |*entry| {
                if (entry.node.kind == .local_set) entry.node.value_type = .string;
            },
        }
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(malformed, &h.values, &h.members, &h.control, &h.state, &h.frames, 100).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(malformed, &h.runtime.instructions).ok, 100).failed.code);
    }
    _ = try h.execute("Value:i64=42");
}

test "mutable local copy and selected hidden state reports reject 1000 forged events before output" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute("F()<transacts>:i64=Block{var X:i64=1;If(false,Set(X,9),Set(X,3));X};Value:i64=F()");
    var forged = x;
    forged.call_steps = h.steps[0..x.call_steps.len];
    var output: [1024]u8 = undefined;
    for (0..1000) |i| {
        @memcpy(h.steps[0..x.call_steps.len], x.call_steps);
        var changed = false;
        for (h.steps[0..x.call_steps.len]) |*step| {
            const node = x.program.function_nodes[x.program.functions[step.function].body.start + step.pc].node;
            if ((i % 2 == 0 and node.kind == .local_set) or (i % 2 == 1 and node.kind == .tuple_element and step.value == .integer)) {
                step.value = .{ .integer = 999 };
                changed = true;
                break;
            }
        }
        try std.testing.expect(changed);
        var out = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    const admitted = try reporting.validate(x, false, .{});
    var out = std.Io.Writer.fixed(&output);
    _ = try reporting.write(&out, x, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    out = .fixed(&output);
    try std.testing.expectError(error.ReportLimit, reporting.write(&out, x, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "mutable local copies cost exact fuel and retain exactly 8192 step events with reusable fatal cleanup" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<transacts>:i64=Block{var X:i64=N;Set(X,2);X};Value:i64=F(1)");
    const x = (try h.run(p, 100)).ok;
    const exact: u32 = @intCast(x.values.len + x.call_steps.len);
    for (0..exact) |fuel| try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(p, @intCast(fuel))).failed.code);
    try std.testing.expectEqual(@as(i64, 2), (try h.run(p, exact)).ok.get("Value").?.integer);
    for ([_]usize{ 2048, 2049 }) |calls| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("One:i64=1;F(N:i64)<transacts>:i64=Block{var X:i64=N;Set(X,2);X};Items:[]i64=array{");
        for (0..calls) |i| try out.print("{s}F(One)", .{if (i == 0) "" else ","});
        try out.writeAll("}");
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (calls == 2048) try std.testing.expectEqual(@as(usize, 8192), r.ok.call_steps.len) else try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, r.failed.code);
    }
    const fatal = (try h.run(try h.compile("var C:i64=1;Value:i64=Block{var X:i64=1;Set(C,9);Set(X,7);Attempt(Block{1/0;X},X)}"), 1000)).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, fatal.code);
    try std.testing.expect(!h.state.cells[0].initialized and !h.runtime.machine.source.cells[0].initialized);
    _ = try h.execute("Value:i64=Block{var X:i64=42;X}");
}

test "mutable local hidden groups retain exact physical member capacity without borrowing frame scratch" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    for ([_]usize{ 163, 164 }) |padding| {
        var out = std.Io.Writer.fixed(&h.text);
        try out.writeAll("E:i64=1;F()<transacts>:[]i64=Block{Element:i64=E;var X:[]i64=array{};If(true,Set(X,array{");
        for (0..255) |i| try out.print("{s}Element", .{if (i == 0) "" else ","});
        try out.writeAll("}),X);X};Items:[][]i64=array{");
        for (0..31) |i| try out.print("{s}F()", .{if (i == 0) "" else ","});
        try out.writeAll("};Padding:[]i64=array{");
        for (0..padding) |i| try out.print("{s}E", .{if (i == 0) "" else ","});
        try out.writeAll("}");
        const r = try h.run(try h.compile(out.buffered()), 65536);
        if (padding == 163) {
            if (r == .failed) std.debug.print("physical local quota: {s}\n", .{r.failed.message()});
            try std.testing.expect(r == .ok);
            try std.testing.expectEqual(@as(usize, 8192), r.ok.aggregate_values.len);
            const items = r.ok.elements(r.ok.get("Items").?).?;
            for (items) |v| try std.testing.expectEqual(@as(usize, 255), r.ok.elements(v).?.len);
        } else try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, r.failed.code);
    }
}

test "mutable locals preserve every restored result kind through returned frame aggregates" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\mode:=enum{One,Two};row:=struct{Name:string,Size:i64}
        \\all:=struct{R:row,A:[]i64,M:map(string,i64),O:option(i64),T:tuple(i64,string),E:mode,B:logic,S:string,Z:float,N:float}
        \\F()<transacts>:all=Block{var R:row=row{Name:="雪",Size:=1};var A:[]i64=array{1};var M:map(string,i64)=map{"雪"=>1};var O:option(i64)=option{};var T:tuple(i64,string)=tuple{1,"雪"};var E:mode=mode.One;var B:logic=false;var S:string="雪";var Z:float=-0.0;var N:float=NaN;Attempt(Block{Set(R,row{Name:="new",Size:=2});Set(A,array{2});Set(M,map{"雪"=>2});Set(O,option{2});Set(T,tuple{2,"new"});Set(E,mode.Two);Set(B,true);Set(S,"new");Set(Z,1.0);Set(N,2.0);Fail["undo"];true},false);all{R:=R,A:=A,M:=M,O:=O,T:=T,E:=E,B:=B,S:=S,Z:=Z,N:=N}}
        \\Value:all=F()
    );
    const fields = x.elements(x.get("Value").?).?;
    const row = x.elements(fields[0]).?;
    try std.testing.expectEqualStrings("雪", row[0].string);
    try std.testing.expectEqual(@as(i64, 1), row[1].integer);
    try std.testing.expectEqual(@as(i64, 1), x.elements(fields[1]).?[0].integer);
    const map = x.elements(fields[2]).?;
    try std.testing.expectEqualStrings("雪", map[0].string);
    try std.testing.expectEqual(@as(i64, 1), map[1].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(fields[3]).?.len);
    const tuple = x.elements(fields[4]).?;
    try std.testing.expectEqual(@as(i64, 1), tuple[0].integer);
    try std.testing.expectEqualStrings("雪", tuple[1].string);
    try std.testing.expectEqual(@as(u32, 0), fields[5].enumeration.index);
    try std.testing.expect(!fields[6].boolean);
    try std.testing.expectEqualStrings("雪", fields[7].string);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(fields[8].floating)));
    try std.testing.expect(std.math.isNan(fields[9].floating));
    try std.testing.expectEqual(@as(u32, 1), x.failure_count);
}

test "mutable locals retain module type namespaces defining owners privacy and inspection fifteen" {
    const h = try create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    // RFC-0076: a `var` local may not have the name of the import alias (it did, and `S.Row`
    // after it was still the module's type), nor of a parameter of its function.
    const shadowing = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Block{var S:i64=7;set S=8;R:S.Row=Held;S+R.Size}" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<transacts>:Row=Block{var M:i64=N;Set(M,M+Hidden);Row{Name:=\"雪\",Size:=M}}" },
    };
    const alias = h.front.compileBundle(.{ .root = "main.forb", .modules = &shadowing }).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, alias.diagnostic.code);
    try std.testing.expectEqualStrings("main.forb", alias.path);
    var outer = shadowing;
    outer[0].source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Held.Size";
    outer[1].source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<transacts>:Row=Block{var N:i64=N;Set(N,N+Hidden);Row{Name:=\"雪\",Size:=N}}";
    const inner = h.front.compileBundle(.{ .root = "main.forb", .modules = &outer }).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, inner.diagnostic.code);
    try std.testing.expectEqualStrings("雪.forb", inner.path);
    // Renamed, the local sits beside the module's types and the values are the same.
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"雪.forb\"};Held:S.Row=S.Make(4);Value:i64=Block{var T:i64=7;set T=8;R:S.Row=Held;T+R.Size}" },
        .{ .path = "雪.forb", .source = "Row<public>:=struct{Name:string,Size:i64};Hidden:i64=3;Make<public>(N:i64)<transacts>:Row=Block{var M:i64=N;Set(M,M+Hidden);Row{Name:=\"雪\",Size:=M}}" },
    };
    const p = h.front.compileBundle(.{ .root = "main.forb", .modules = &files }).ok;
    const x = (try h.run(p, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 15), x.get("Value").?.integer);
    var forged = p;
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    forged.function_nodes = h.body[0..p.function_nodes.len];
    for (h.body[0..p.function_nodes.len]) |*entry| if (entry.node.kind == .local_set) {
        entry.node.span = p.bindings[0].name;
    };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 1000).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, 1000).failed.code);
    var changed = files;
    changed[0].source = "S:=import{\"雪.forb\"};Value:i64=Block{var X:i64=S.Hidden;X}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_name, h.front.compileBundle(.{ .root = "main.forb", .modules = &changed }).failed.diagnostic.code);
    const unused = try h.compile("F()<transacts>:i64=Block{var X:i64=1;X};Value:i64=9");
    const inspector = try scratch.storage(inspection.Workspace);
    defer scratch.release(inspector);
    scratch.initialise(inspector);
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.write(&out, unused)));
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 15), json.value.object.get("format").?.integer);
    const function = json.value.object.get("functions").?.array.items[0].object;
    try std.testing.expect(function.get("has_local").?.bool and function.get("transacts").?.bool and !function.get("has_source").?.bool);
    const exact = out.end;
    out = .fixed(&buffer);
    try std.testing.expectEqual(std.meta.Tag(inspection.Result).ok, std.meta.activeTag(try inspector.writeBounded(&out, unused, .{ .output_bytes = exact })));
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try inspector.writeBounded(&out, unused, .{ .output_bytes = exact - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "mutable local untaken arms reject unavailable versions and root copies before output" {
    const h = try create();
    defer scratch.release(h);
    const p = try h.compile("F(L:logic)<transacts>:i64=Block{var X:i64=1;If(L,Set(X,7),Set(X,9));X};Value:i64=F(true)");
    var malformed = p;
    malformed.function_nodes = h.body[0..p.function_nodes.len];
    var left: u32 = undefined;
    for (p.function_nodes, 0..) |entry, index| if (entry.node.kind == .local_set) {
        if (index > 1) {
            left = @intCast(index);
            break;
        }
    };
    for (0..1000) |_| {
        @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
        var changed = false;
        for (h.body[left + 1 .. p.function_nodes.len]) |*entry| if (entry.node.kind == .local_set) {
            entry.node.kind.local_set = left;
            changed = true;
        };
        try std.testing.expect(changed);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(malformed, &h.values, &h.members, &h.control, &h.state, &h.frames, 1000).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(malformed, &h.runtime.instructions).ok, 1000).failed.code);
    }
    const x = try h.execute("Value:i64=Block{var X:i64=1;Set(X,3);X}");
    @memcpy(h.values[0..x.values.len], x.values);
    var forged = x;
    forged.values = h.values[0..x.values.len];
    for (x.program.nodes, 0..) |node, index| if (node.kind == .local_set) {
        h.values[index] = .{ .integer = 999 };
    };
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, forged, false, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}
