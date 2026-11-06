const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const state = @import("source_state.zig");
const report = @import("value_report.zig");
const inspection = @import("inspection.zig");
const Harness = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},
    reference: state.ReferenceState = .{},
    fn compile(self: *Harness, source: []const u8) !types.Program {
        return switch (self.compiler.compile(source)) {
            .ok => |program| program,
            .failed => |d| {
                std.debug.print("mutation compile {s} at {d}: {s}\n", .{ d.message(), d.span.start, source });
                return error.Compile;
            },
        };
    }
    fn run(self: *Harness, program: types.Program, budget: u64) !evaluator.Result {
        const expected = evaluator.evaluateWithStateStorage(program, &self.values, &self.members, &self.control, &self.reference, budget);
        const actual = self.runtime.evaluate(program, budget);
        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
        if (expected == .failed) {
            try std.testing.expectEqualDeep(expected.failed, actual.failed);
            return actual;
        }
        try std.testing.expectEqualSlices(bool, expected.ok.activity, actual.ok.activity);
        try std.testing.expectEqualDeep(expected.ok.failures, actual.ok.failures);
        try std.testing.expectEqual(expected.ok.failure_count, actual.ok.failure_count);
        for (expected.ok.values, actual.ok.values, 0..) |a, b, index| if (expected.ok.active(index)) {
            try equal(a, b);
        };
        try std.testing.expectEqual(expected.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        for (expected.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try equal(a, b);
        _ = try report.validate(expected.ok, false, .{});
        _ = try report.validate(actual.ok, false, .{});
        return actual;
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const result = try self.run(try self.compile(source), 131072);
        if (result == .failed) {
            std.debug.print("mutation execution {s}: {s}\n", .{ result.failed.message(), source });
            return error.Execution;
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

test "mutation strict arguments rollback writes before failure and export final cells" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute(
        \\var Count<public>:i64=1
        \\Frozen:i64=Count
        \\Increment(X:i64)<transacts>:i64=Set(Count,Count+X)
        \\First(X:i64,Y:i64)<computes>:i64=X
        \\Discard:i64=Attempt(First(Increment(5),Fail["discard increment"]),Count)
        \\set Count=Count+1
        \\Observed:i64=First(Count,3)
    );
    try std.testing.expectEqual(@as(i64, 2), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), result.get("Frozen").?.integer);
    try std.testing.expectEqual(@as(i64, 1), result.get("Discard").?.integer);
    try std.testing.expectEqual(@as(i64, 2), result.get("Observed").?.integer);
    try std.testing.expectEqualStrings("discard increment", result.failures[0].reason.?);
    try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.source.depth);
    try std.testing.expectEqual(@as(usize, 0), h.reference.depth);
    _ = try h.execute("Pure:i64=7");
    try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.source.cell_count);
    try std.testing.expectEqual(@as(usize, 0), h.reference.cell_count);
    try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
}

test "mutation child commit parent abort fallback writes and failable transacts helpers" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute(
        \\var C:i64=1
        \\First(X:i64,Y:i64)<computes>:i64=X
        \\Change(X:i64)<transacts><decides>:i64=First(Set(C,X),If(Require[X>=0],0,0))
        \\A:i64=Attempt(First(Attempt(Change[5],0),Fail["parent"]),Set(C,C+2))
        \\B:i64=Attempt(Change[-7],C)
        \\D:i64=Attempt(Attempt(Fail["inner"],First(Set(C,99),Fail["fallback"])),C)
        \\E:i64=If(false,Set(C,100),Set(C,C+1))
    );
    try std.testing.expectEqual(@as(i64, 3), result.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.get("C").?.integer);
    try std.testing.expectEqual(@as(u32, 4), result.failure_count);
}

test "mutation copies every Value kind and nested aggregate aliases across rollback" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute(
        \\mode:=enum{dark,light};p:=struct{X:i64};wrap:=struct{A:[]p}
        \\var L:logic=true;var S:string="雪";var F:float=-0.0;var E:mode=mode.dark
        \\var A:[]i64=array{1};var O:option(i64)=option{2};var M:map(string,i64)=map{"a"=>3}
        \\var T:tuple(i64,string)=tuple{4,"old"};var W:wrap=wrap{A:=array{p{X:=5}}}
        \\Saved:wrap=W;First(X:i64,Y:i64)<computes>:i64=X
        \\Gate(X:logic,Y:i64)<computes>:i64=Y
        \\SFirst(X:string,Y:string)<computes>:string=X
        \\FFirst(X:float,Y:float)<computes>:float=X
        \\EFirst(X:mode,Y:mode)<computes>:mode=X
        \\MFirst(X:map(string,i64),Y:map(string,i64))<computes>:map(string,i64)=X
        \\TFirst(X:tuple(i64,string),Y:tuple(i64,string))<computes>:tuple(i64,string)=X
        \\WFirst(X:wrap,Y:wrap)<computes>:wrap=X
        \\Bad:i64=Attempt(First(Set(A,array{9}).Length,Gate(Set(O,option{}).IsSet and Set(L,false),Fail["abort"])),0)
        \\Text:string=Attempt(SFirst(Set(S,"bad"),Fail["text"]),S)
        \\Float:float=Attempt(FFirst(Set(F,NaN),Fail["float"]),F)
        \\Enum:mode=Attempt(EFirst(Set(E,mode.light),Fail["enum"]),E)
        \\Map:map(string,i64)=Attempt(MFirst(Set(M,map{"b"=>8}),Fail["map"]),M)
        \\Tuple:tuple(i64,string)=Attempt(TFirst(Set(T,tuple{9,"bad"}),Fail["tuple"]),T)
        \\Restored:wrap=Attempt(WFirst(Set(W,wrap{A:=array{p{X:=99}}}),Fail["record"]),W)
        \\RestoredArray:[]i64=A;RestoredOption:option(i64)=O
        \\View:option(i64)=Lookup(M,"a");var Held:option(i64)=View
        \\Changed:wrap=Set(W,wrap{A:=array{p{X:=6}}})
        \\set A=array{};set O=option{};set M=map{}
    );
    try std.testing.expect(result.get("L").?.boolean);
    try std.testing.expectEqualStrings("雪", result.get("S").?.string);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(result.get("F").?.floating)));
    try std.testing.expectEqual(@as(u32, 0), result.get("E").?.enumeration.index);
    try std.testing.expectEqual(@as(i64, 1), result.elements(result.get("RestoredArray").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 2), result.elements(result.get("RestoredOption").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 3), result.elements(result.get("Held").?).?[0].integer);
    const restored_map = result.elements(result.get("Map").?).?;
    try std.testing.expectEqualStrings("a", restored_map[0].string);
    try std.testing.expectEqual(@as(i64, 3), restored_map[1].integer);
    const restored_tuple = result.elements(result.get("Tuple").?).?;
    try std.testing.expectEqual(@as(i64, 4), restored_tuple[0].integer);
    try std.testing.expectEqualStrings("old", restored_tuple[1].string);
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.get("A").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.get("O").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), result.elements(result.get("M").?).?.len);
    const saved = result.elements(result.elements(result.elements(result.get("Saved").?).?[0]).?[0]).?[0].integer;
    const changed = result.elements(result.elements(result.elements(result.get("W").?).?[0]).?[0]).?[0].integer;
    try std.testing.expectEqual(@as(i64, 5), saved);
    try std.testing.expectEqual(@as(i64, 6), changed);
}

test "mutation effects unused bodies arms defaults static targets and exact types reject" {
    const h = try create();
    defer scratch.release(h);
    const cases = [_]struct { text: []const u8, code: types.Diagnostic.Code }{
        .{ .text = "var C:i64=1;Bad()<computes>:i64=C", .code = .variable_read_requires_reads },
        .{ .text = "var C:i64=1;Bad()<computes>:i64=Attempt(Set(C,2),0)", .code = .set_requires_writes },
        .{ .text = "var C:i64=1;Bad()<computes>:i64=If(true,1,C)", .code = .variable_read_requires_reads },
        .{ .text = "var C:i64=1;F()<transacts>:i64=C;Bad()<computes>:i64=F()", .code = .call_requires_transacts },
        .{ .text = "var C:i64=1;p:=struct{X:i64=C}", .code = .variable_read_requires_reads },
        .{ .text = "var C:i64=1;F()<transacts>:i64=C;p:=struct{X:i64=F()}", .code = .call_requires_transacts },
        .{ .text = "C:i64=1;set C=2", .code = .not_mutable },
        .{ .text = "C:i64=1;A:i64=Set(C,2)", .code = .not_mutable },
        .{ .text = "var C:i64=1;F(D:i64)<transacts>:i64=Set(D,2)", .code = .not_mutable },
        // RFC-0076 rule 1: a parameter may not take the name of an earlier cell.
        .{ .text = "var C:i64=1;F(C:i64)<transacts>:i64=Set(C,2)", .code = .shadowed_name },
        .{ .text = "var C:i64=C", .code = .unknown_name },
        .{ .text = "set C=1", .code = .unknown_name },
        .{ .text = "var C:i64=1;set C=2.0", .code = .type_mismatch },
        .{ .text = "var C:i64=1;A:i64=Set(C,true)", .code = .type_mismatch },
        .{ .text = "var C:i64=1;A:i64=Set(C,1,2)", .code = .argument_count },
        .{ .text = "var C:i64=1;A:i64=Set[C,2]", .code = .expected_call },
        .{ .text = "F()<transacts><computes>:i64=1", .code = .effect_specifier_conflict },
        .{ .text = "F()<decides>:i64=1", .code = .expected_computes },
        .{ .text = "var p:=struct{X:i64}", .code = .expected_type },
        .{ .text = "var C:i64=1;var C:i64=2", .code = .duplicate_name },
    };
    for (cases) |case| {
        const rejected = h.compiler.compile(case.text);
        if (rejected == .ok) std.debug.print("accepted mutation source: {s}\n", .{case.text});
        try std.testing.expect(rejected == .failed);
        try std.testing.expectEqual(case.code, rejected.failed.code);
        _ = try h.execute("var C:i64=1;F(D:i64)<computes>:i64=D;set C=F(3)");
    }
}

test "mutation exact fuel fatal arithmetic duplicate maps and reuse abort outer cells" {
    const h = try create();
    defer scratch.release(h);
    const program = try h.compile("var C:i64=1;set C=C+2");
    try std.testing.expectEqual(@as(usize, 7), program.nodes.len);
    for (0..7) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, @intCast(budget))).failed.code);
        try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
        try std.testing.expect(!h.reference.cells[0].initialized);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.source.undo_count);
        try std.testing.expectEqual(@as(usize, 0), h.reference.depth);
    }
    try std.testing.expectEqual(@as(i64, 3), (try h.run(program, 7)).ok.get("C").?.integer);
    for ([_][]const u8{
        "var C:i64=1;set C=2;Bad:i64=Attempt(1/0,C)",
        "var C:i64=1;Bad:i64=Attempt(Set(C,9223372036854775807)+1,C)",
        "var C:i64=1;set C=2;Bad:map(i64,i64)=Attempt(map{1=>0,1=>1},map{})",
    }, [_]types.Diagnostic.Code{ .division_by_zero, .arithmetic_overflow, .duplicate_map_key }) |source, code| {
        try std.testing.expectEqual(code, (try h.run(try h.compile(source), 1000)).failed.code);
        try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
        try std.testing.expect(!h.reference.cells[0].initialized);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.source.depth);
        _ = try h.execute("var C:i64=7");
    }
}

test "mutation 1000 independent whole-program scalar rollback oracles" {
    const h = try create();
    defer scratch.release(h);
    var rng = std.Random.DefaultPrng.init(0x630063);
    var buffer: [2048]u8 = undefined;
    for (0..1000) |_| {
        const a = rng.random().intRangeAtMost(i64, -1000, 1000);
        const b = rng.random().intRangeAtMost(i64, -1000, 1000);
        const c = rng.random().intRangeAtMost(i64, -1000, 1000);
        const succeeds = a < b;
        const source = try std.fmt.bufPrint(&buffer, "var C:i64={d};Frozen:i64=C;First(X:i64,Y:i64)<computes>:i64=X;R:i64=Attempt(First(Set(C,C+{d}),If(Require[{s}],0,0)),Set(C,C+{d}));Observed:i64=C;set C=C+1", .{ a, b, if (succeeds) "true" else "false", c });
        const actual = try h.execute(source);
        const observed = a + if (succeeds) b else c;
        try std.testing.expectEqual(a, actual.get("Frozen").?.integer);
        try std.testing.expectEqual(observed, actual.get("R").?.integer);
        try std.testing.expectEqual(observed, actual.get("Observed").?.integer);
        try std.testing.expectEqual(observed + 1, actual.get("C").?.integer);
        try std.testing.expectEqual(@as(u32, if (succeeds) 0 else 1), actual.failure_count);
    }
}

test "mutation imported public cells transacts frames and private nominal boundaries" {
    const h = try create();
    defer scratch.release(h);
    const inputs = [_]@import("modules.zig").Input{
        .{ .path = "main.forb", .source = "M:=import{\"state.forb\"};Frozen:i64=M.Count;set M.Count=4;A:i64=Attempt(M.Change[-1],M.Count);var Root:i64=M.Change(6)" },
        .{ .path = "state.forb", .source = "var Count<public>:i64=1;var Hidden:i64=2;Change<public>(X:i64)<transacts>:i64=Set(Count,X)" },
    };
    // Use a failable helper, then an ordinary helper, to check both call syntaxes.
    var changed = inputs;
    changed[1].source = "var Count<public>:i64=1;var Hidden:i64=2;Change<public>(X:i64)<transacts><decides>:i64=If(Require[X>=0],Set(Count,X),0);Plain<public>(X:i64)<transacts>:i64=Set(Count,X)";
    changed[0].source = "M:=import{\"state.forb\"};Frozen:i64=M.Count;set M.Count=4;A:i64=Attempt(M.Change[-1],M.Count);var Root:i64=M.Plain(6)";
    const bundled = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &changed });
    try std.testing.expect(bundled == .ok);
    const actual = (try h.run(bundled.ok, 1000)).ok;
    try std.testing.expectEqual(@as(i64, 1), actual.get("Frozen").?.integer);
    try std.testing.expectEqual(@as(i64, 4), actual.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 6), actual.get("Root").?.integer);
    try std.testing.expect(actual.get("Count") == null);
    for ([_][]const u8{ "set M.Hidden=3", "A:i64=M.Hidden", "A:i64=Set(M.Hidden,3)", "Bad()<computes>:i64=M.Plain(2)", "Bad()<computes>:i64=M.Count" }, [_]types.Diagnostic.Code{ .private_name, .private_name, .private_name, .call_requires_transacts, .variable_read_requires_reads }) |tail, code| {
        var source: [512]u8 = undefined;
        changed[0].source = try std.fmt.bufPrint(&source, "M:=import{{\"state.forb\"}};{s}", .{tail});
        const rejected = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &changed });
        try std.testing.expectEqual(code, rejected.failed.diagnostic.code);
    }
    changed[1].source = "hidden:=struct{X:i64};var C<public>:hidden=hidden{X:=1}";
    changed[0].source = "M:=import{\"state.forb\"}";
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, h.compiler.compileBundle(.{ .root = "main.forb", .modules = &changed }).failed.diagnostic.code);
}

test "mutation admission precedes storage access and rejects 2000 metadata IR bytecode tails" {
    // Written against the bootstrap capacities; the larger profile has its own scale tests.
    try @import("profile.zig").requireBootstrap();
    // The body's locals are sized by the bootstrap capacities. Under a larger profile a Debug
    // frame holding them would overflow the stack before the skip (P0.8), so they live in a
    // function that only a bootstrap run calls.
    try mutationAdmissionPrecedesStorageAtBootstrap();
}

fn mutationAdmissionPrecedesStorageAtBootstrap() !void {
    const h = try create();
    defer scratch.release(h);
    const original = try h.compile("var C:i64=1;A:i64=Attempt(Set(C,2),3);set C=C+1");
    _ = try h.run(original, 1000);
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithStorage(original, &h.values, &h.members, 0).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.state_storage_required, evaluator.evaluateWithControlStorage(original, &h.values, &h.members, &h.control, 0).failed.code);
    const prior = h.runtime.machine.source.cells[0];
    const prior_reference = h.reference.cells[0];
    var nodes: [types.limits.nodes]types.Node = undefined;
    var cells: [1]types.SourceCell = undefined;
    var bindings: [2]types.Binding = undefined;
    var ir = original;
    var rng = std.Random.DefaultPrng.init(0x636364);
    for (0..2000) |iteration| {
        @memcpy(nodes[0..original.nodes.len], original.nodes);
        @memcpy(&cells, original.source_cells);
        @memcpy(&bindings, original.bindings);
        ir = original;
        ir.nodes = nodes[0..original.nodes.len];
        ir.source_cells = &cells;
        ir.bindings = &bindings;
        const index = rng.random().uintLessThan(u32, @intCast(original.nodes.len));
        switch (iteration % 12) {
            0 => ir.source_ops = 0,
            1 => cells[0].initial = index + @as(u32, @intCast(original.nodes.len)),
            2 => cells[0].value_type = .string,
            3 => nodes[index].kind = .{ .cell_read = 1 },
            4 => nodes[index].kind = .{ .cell_write = .{ .cell = 0, .value = index } },
            5 => nodes[index].kind = .{ .cell_init = .{ .cell = 0, .value = index } },
            6 => cells[0].name.end = std.math.maxInt(u32),
            7 => ir.source_cells = &.{},
            8 => nodes[original.nodes.len - 1].value_type = .logic,
            9 => bindings[0].node = cells[0].initial,
            10 => cells[0].is_public = true,
            11 => nodes[original.nodes.len - 1].kind = .{ .cell_read = std.math.maxInt(u32) },
            else => unreachable,
        }
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, evaluator.evaluateWithStateStorage(ir, &h.values, &h.members, &h.control, &h.reference, 0).failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, h.runtime.evaluate(ir, 0).failed.code);
        try std.testing.expectEqualDeep(prior, h.runtime.machine.source.cells[0]);
        try std.testing.expectEqualDeep(prior_reference, h.reference.cells[0]);
    }
    const lowered = bytecode.lower(original, &h.runtime.instructions).ok;
    var raw = lowered;
    raw.source_ops = 0;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(raw, 1000).failed.code);
    raw = lowered;
    h.runtime.instructions[raw.code.len - 1].op = .begin;
    h.runtime.instructions[raw.code.len - 1].value_type = null;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, h.runtime.machine.run(raw, 1000).failed.code);
    try std.testing.expectEqualDeep(prior, h.runtime.machine.source.cells[0]);
}

test "mutation reports replay cell versions and reject forged reads writes masks before output" {
    const h = try create();
    defer scratch.release(h);
    const result = try h.execute("var C<public>:i64=1;First(X:i64,Y:i64)<computes>:i64=X;A:i64=Attempt(First(Set(C,9),Fail[\"abort\"]),Set(C,C+1));B:i64=C");
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const exact = try report.write(&out, result, false, .{});
    out = .fixed(&buffer);
    _ = try report.write(&out, result, false, .{ .work = exact.work, .output_bytes = exact.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, report.write(&out, result, false, .{ .output_bytes = exact.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    for (result.program.nodes, 0..) |node, index| {
        if (!types.sourceOp(node) or !result.active(index)) continue;
        const old = h.runtime.machine.values[index];
        h.runtime.machine.values[index] = .{ .integer = 999 };
        try std.testing.expectError(error.InvalidExecution, report.write(&out, result, false, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
        h.runtime.machine.values[index] = old;
    }
    for (0..result.activity.len) |index| {
        h.runtime.machine.control.activity[index] = !h.runtime.machine.control.activity[index];
        try std.testing.expectError(error.InvalidExecution, report.write(&out, result, false, .{}));
        h.runtime.machine.control.activity[index] = !h.runtime.machine.control.activity[index];
    }
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    out = .fixed(&buffer);
    try std.testing.expect((try workspace.write(&out, result.program)) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":9,"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"source_cells\"") != null);
    const bytes = out.end;
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try workspace.writeBounded(&out, result.program, .{ .output_bytes = bytes - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "mutation exact cell register journal and frame capacities use checked cleanup" {
    try @import("profile.zig").requireBootstrap();
    // The body's locals are sized by the bootstrap capacities. Under a larger profile a Debug
    // frame holding them would overflow the stack before the skip (P0.8), so they live in a
    // function that only a bootstrap run calls.
    try mutationExactCapacitiesAtBootstrap();
}

fn mutationExactCapacitiesAtBootstrap() !void {
    const h = try create();
    defer scratch.release(h);
    var source: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&source);
    for (0..types.limits.source_cells) |i| try out.print("var C{d}:i64={d};", .{ i, i });
    try std.testing.expectEqual(@as(i64, 255), (try h.execute(out.buffered())).get("C255").?.integer);
    try out.writeAll("var Extra:i64=1");
    try std.testing.expectEqual(types.Diagnostic.Code.binding_limit, h.compiler.compile(out.buffered()).failed.code);
    out = .fixed(&source);
    try out.writeAll("var C:i64=1;A:i64=");
    for (0..types.limits.control_depth) |_| try out.writeAll("Attempt(");
    try out.writeAll("Set(C,7)");
    for (0..types.limits.control_depth) |_| try out.writeAll(",0)");
    try std.testing.expectEqual(@as(i64, 7), (try h.execute(out.buffered())).get("C").?.integer);
    var ir = try h.compile("var C:i64=0");
    var nodes: [types.limits.nodes]types.Node = undefined;
    nodes[0] = ir.nodes[0];
    nodes[1] = ir.nodes[1];
    for (nodes[2 .. nodes.len - 1]) |*node| node.* = .{ .span = ir.source_cells[0].name, .value_type = .i64, .kind = .{ .cell_write = .{ .cell = 0, .value = 0 } } };
    nodes[nodes.len - 1] = ir.nodes[2];
    var binding = ir.bindings[0];
    binding.node = @intCast(nodes.len - 1);
    ir.nodes = &nodes;
    ir.bindings = &.{binding};
    ir.source_ops = types.limits.nodes - 1;
    try std.testing.expectEqual(@as(i64, 0), (try h.run(ir, types.limits.nodes)).ok.get("C").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(ir, types.limits.nodes - 1)).failed.code);
    try std.testing.expect(!h.runtime.machine.source.cells[0].initialized);
    // The quota bounds the records that regions hold for rollback, and the root region holds
    // none: one root write more than `source_undos`, which used to be `SourceUndoLimit`, is
    // admitted. source_state.zig fills the quota exactly, with distinct cells in nested regions.
    const journal = &h.runtime.machine.source;
    journal.reset(types.limits.source_cells);
    h.reference.reset(types.limits.source_cells);
    try journal.begin();
    try h.reference.begin();
    for (0..types.limits.source_undos + 1) |i| {
        const cell: u32 = @intCast(i % types.limits.source_cells);
        const value: types.Value = .{ .integer = @intCast(i) };
        try journal.write(cell, value, i < types.limits.source_cells);
        try h.reference.write(cell, value, i < types.limits.source_cells);
    }
    try std.testing.expect(journal.undo_count == 0 and h.reference.undo_count == 0);
    try std.testing.expectEqual(@as(i64, types.limits.source_undos), (try journal.read(0)).integer);
    for (1..types.limits.source_frames) |_| {
        try journal.begin();
        try h.reference.begin();
    }
    try std.testing.expectError(error.SourceDepthLimit, journal.begin());
    try std.testing.expectError(error.SourceDepthLimit, h.reference.begin());
    journal.abortAll();
    h.reference.abortAll();
    for (journal.cells[0..journal.cell_count], h.reference.cells[0..journal.cell_count]) |a, b| {
        try std.testing.expect(!a.initialized);
        try std.testing.expectEqualDeep(a, b);
    }
    try std.testing.expectError(error.NoSourceTransaction, journal.write(0, .{ .integer = 1 }, false));
    try std.testing.expectError(error.SourceCellIndex, journal.read(256));
    try std.testing.expectError(error.SourceUninitialized, journal.read(0));
}

test "mutation source truncations and 3000 edits retain admission and recover reusable state" {
    const h = try create();
    defer scratch.release(h);
    const original = "var C:i64=1;F(X:i64)<transacts><decides>:i64=If(Require[X>=0],Set(C,C+X),0);A:i64=Attempt(F[2],Set(C,4));set C=C+1";
    var source: [original.len]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x636365);
    const punctuation = "()+-*/,:;<>={}[]\"\\\n";
    for (0..3000 + original.len) |iteration| {
        @memcpy(&source, original);
        var count = source.len;
        if (iteration < original.len) count = iteration else {
            const position = random.random().uintLessThan(usize, source.len);
            source[position] = punctuation[random.random().uintLessThan(usize, punctuation.len)];
        }
        switch (h.compiler.compile(source[0..count])) {
            .failed => |d| try std.testing.expect(d.span.start <= d.span.end and d.span.end <= count),
            .ok => |program| {
                _ = try h.run(program, 1000);
            },
        }
        if (iteration % 64 == 0) _ = try h.execute("var C:i64=1;set C=7");
    }
}

test "mutation 20000 randomized nested journal actions agree with full snapshot oracle" {
    const h = try create();
    defer scratch.release(h);
    const journal = &h.runtime.machine.source;
    const oracle = &h.reference;
    journal.reset(4);
    oracle.reset(4);
    var random = std.Random.DefaultPrng.init(0x636367);
    for (0..20000) |iteration| {
        const depth = journal.depth;
        const operation = random.random().uintLessThan(u8, 5);
        if (depth == 0 or (operation == 0 and depth < types.limits.source_frames)) {
            // A root region begins only from the state `reset` gives: it is discarded, not undone.
            if (depth == 0) {
                journal.reset(4);
                oracle.reset(4);
            }
            try journal.begin();
            try oracle.begin();
        } else if (operation == 1) {
            try journal.abort();
            try oracle.abort();
        } else if (operation == 2) {
            try journal.commit();
            try oracle.commit();
        } else {
            const cell = random.random().uintLessThan(u32, 4);
            const value: types.Value = switch (iteration % 6) {
                0 => .{ .integer = @intCast(iteration) },
                1 => .{ .boolean = iteration % 2 == 0 },
                2 => .{ .string = "雪" },
                3 => .{ .floating = -0.0 },
                4 => .{ .enumeration = .{ .value_type = @fromBackingInt(4), .index = 0 } },
                5 => .{ .aggregate = .{ .value_type = @fromBackingInt(5), .elements = .{ .start = 0, .end = 0 } } },
                else => unreachable,
            };
            const initialize = !journal.cells[cell].initialized;
            try journal.write(cell, value, initialize);
            try oracle.write(cell, value, initialize);
        }
        try std.testing.expectEqual(oracle.depth, journal.depth);
        try std.testing.expectEqual(oracle.undo_count, journal.undo_count);
        for (journal.cells[0..4], oracle.cells[0..4]) |cell, image| {
            try std.testing.expectEqual(image.initialized, cell.initialized);
            try equal(image.value, cell.value);
        }
    }
    journal.abortAll();
    oracle.abortAll();
    for (journal.cells[0..4], oracle.cells[0..4]) |cell, image| try std.testing.expectEqualDeep(image, cell);
}

test "mutation rewrites of one cell beyond the undo quota run and report outside and inside a failed Attempt" {
    try @import("profile.zig").requireBootstrap();
    const h = try create();
    defer scratch.release(h);
    // The call witness ends a bootstrap loop long before 2 * source_undos + 100 iterations, so the
    // writes come from both the root schedule and a loop; program_profile_tests.zig has the long
    // loop. Every write counted against `source_undos` before: these runs ended in `undo_limit`.
    // `Set` yields what it wrote: seven under a `set` are eight writes, a node or call step each.
    const chain = "Set(C,Set(C,Set(C,Set(C,Set(C,Set(C,Set(C,";
    const chain_end = ")))))))";
    const root_writes = 8 * 250;
    const body_writes = 8 * 16;
    const iterations = 50;
    try std.testing.expect(root_writes + body_writes * iterations > types.limits.source_undos);
    var source: [24000]u8 = undefined;
    var out = std.Io.Writer.fixed(&source);
    try out.writeAll("var C<public>:i64=5\nBump(S:i64)<transacts>:i64=Block{");
    for (0..body_writes / 8) |_| try out.writeAll("set C=" ++ chain ++ "S" ++ chain_end ++ ";");
    try out.writeAll("S+1}\n");
    const prefix = out.buffered().len;

    for (0..root_writes / 8) |_| try out.writeAll("set C=" ++ chain ++ "6" ++ chain_end ++ "\n");
    try out.print("Sum<public>:i64=Iterate(Bump,{d},0)\nAfter<public>:i64=C\n", .{iterations});
    const kept = try h.execute(out.buffered());
    try std.testing.expect(kept.call_steps.len >= body_writes * iterations);
    try std.testing.expectEqual(@as(i64, iterations), kept.get("Sum").?.integer);
    try std.testing.expectEqual(@as(i64, iterations - 1), kept.get("After").?.integer);
    try std.testing.expectEqual(@as(i64, iterations - 1), kept.get("C").?.integer);

    // The same writes inside one Attempt hold one record, and its failure restores the cell.
    out = .fixed(&source);
    out.end = prefix;
    try out.writeAll("Before<public>:i64=C\nTried<public>:i64=Attempt(Block{");
    for (0..root_writes / 8) |_| try out.writeAll("set C=" ++ chain ++ "6" ++ chain_end ++ ";");
    try out.print("set C=Iterate(Bump,{d},0)+1000;Fail[\"undo\"];C}},0-C)\nAfter<public>:i64=C\n", .{iterations});
    const undone = try h.execute(out.buffered());
    try std.testing.expect(undone.call_steps.len >= body_writes * iterations);
    try std.testing.expectEqual(@as(usize, 1), undone.failures.len);
    try std.testing.expectEqual(@as(i64, 5), undone.get("Before").?.integer);
    try std.testing.expectEqual(@as(i64, -5), undone.get("Tried").?.integer);
    try std.testing.expectEqual(@as(i64, 5), undone.get("After").?.integer);
    try std.testing.expect(h.reference.undo_count == 0 and h.runtime.machine.source.undo_count == 0);

    // Without the failure the Attempt commits what the loop and the last write left.
    out = .fixed(&source);
    out.end = prefix;
    try out.print("Tried<public>:i64=Attempt(Block{{set C=6;set C=Iterate(Bump,{d},0)+1000;C}},0-C)\nAfter<public>:i64=C\n", .{iterations});
    const committed = try h.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, iterations + 1000), committed.get("Tried").?.integer);
    try std.testing.expectEqual(@as(i64, iterations + 1000), committed.get("After").?.integer);
}

test "mutation nested regions restore after inner commit then outer abort and after inner abort then more writes" {
    const h = try create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C<public>:i64=1
        \\var D<public>:i64=10
        \\Twice(S:i64)<transacts>:i64=Block{set C=C+S;set C=C+S;set D=D+1;S}
        \\Keep:i64=Attempt(Block{set D=20;Inner:i64=Attempt(Block{set C=2;set C=3;Twice(4)},0);set C=C+100;Fail["outer"];Inner},C*1000+D)
        \\Mid:i64=C*1000+D
        \\Drop:i64=Attempt(Block{Inner:i64=Attempt(Block{set C=7;set D=8;set D=Twice(1);Fail["inner"];0},C*1000+D);set C=C+50;set C=C+50;set D=D+5;Fail["outer"];Inner},C*1000+D)
        \\Last:i64=C*1000+D
        \\Kept:i64=Attempt(Block{Inner:i64=Attempt(Block{set C=7;Fail["inner"];0},C);set C=C+50;Attempt(Twice(2),0)+Inner},0)
        \\End:i64=C*1000+D
    );
    try std.testing.expectEqual(@as(i64, 1010), x.get("Keep").?.integer);
    try std.testing.expectEqual(@as(i64, 1010), x.get("Mid").?.integer);
    try std.testing.expectEqual(@as(i64, 1010), x.get("Drop").?.integer);
    try std.testing.expectEqual(@as(i64, 1010), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 55011), x.get("End").?.integer);
    try std.testing.expectEqual(@as(usize, 4), x.failures.len);
}
