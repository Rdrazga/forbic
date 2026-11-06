//! Options/maps: independent semantics, resource funding and hostile admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const catalogue = @import("aggregate_types.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");
const keys = @import("map_keys.zig");
const Harness = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    inspection: inspection.Workspace = .{},
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [types.limits.source_bytes]u8 = undefined,

    fn compile(self: *Harness, source: []const u8) !types.Program {
        const result = self.compiler.compile(source);
        if (result == .failed) {
            std.debug.print("collection compile at {d}: {s}\n", .{ result.failed.span.start, result.failed.message() });
            return error.UnexpectedCompile;
        }
        return result.ok;
    }
    fn evaluate(self: *Harness, program: types.Program, budget: u64) !evaluator.Result {
        const reference = evaluator.evaluateWithStorage(program, &self.values, &self.members, budget);
        const actual = self.runtime.evaluate(program, budget);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .failed) {
            try std.testing.expectEqual(reference.failed.code, actual.failed.code);
            // Malformed metadata can identify a specific IR node or the VM's
            // whole-program origin. Source/runtime failures retain exact spans.
            if (reference.failed.code != .invalid_ir) try std.testing.expectEqualDeep(reference.failed, actual.failed);
            try std.testing.expect(reference.failed.span.end <= program.source.len and actual.failed.span.end <= program.source.len);
        } else {
            try std.testing.expectEqual(reference.ok.values.len, actual.ok.values.len);
            for (reference.ok.values, actual.ok.values) |a, b| try equalValue(a, b);
            try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
            for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try equalValue(a, b);
        }
        return actual;
    }
    fn execute(self: *Harness, source: []const u8) !evaluator.Execution {
        const result = try self.evaluate(try self.compile(source), types.limits.evaluation_work);
        try std.testing.expect(result == .ok);
        return result.ok;
    }
};
fn harness() !*Harness {
    const h = try scratch.make(Harness);
    return h;
}

fn equalValue(a: types.Value, b: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    switch (a) {
        .floating => |value| try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(b.floating))),
        .string => |value| try std.testing.expectEqualStrings(value, b.string),
        .integer => |value| try std.testing.expectEqual(value, b.integer),
        .boolean => |value| try std.testing.expectEqual(value, b.boolean),
        .aggregate => |value| try std.testing.expectEqualDeep(value, b.aggregate),
        .enumeration => |value| try std.testing.expectEqualDeep(value, b.enumeration),
        .callable => |value| try std.testing.expectEqualDeep(value, b.callable),
        .object => |value| try std.testing.expectEqualDeep(value, b.object),
        .rational => |value| try std.testing.expectEqualDeep(value, b.rational),
    }
}

test "options maps nested contexts defaults and templates retain exact types and shallow values" {
    const h = try harness();
    defer scratch.release(h);
    const execution = try h.execute(
        \\mode:=enum{Dark,Light}
        \\Seed:i64=6
        \\box:=struct{M:map(string,option(tuple(i64,[]mode)))=map{"gap"=>option{tuple{Seed,array{}}},"empty"=>option{}}}
        \\Keep(M:map(string,option(tuple(i64,[]mode))))<computes>:map(string,option(tuple(i64,[]mode)))=M
        \\Settings:box=box{}
        \\M:map(string,option(tuple(i64,[]mode)))=Keep(Settings.M)
        \\Found:option(tuple(i64,[]mode))=Or(Lookup(M,"gap"),option{})
        \\Pair:tuple(i64,[]mode)=Or(Found,tuple{9,array{mode.Light}})
        \\Gap:i64=Pair(0)
        \\Count:i64=Pair(1).Length+M.Length
        \\Missing:option(option(tuple(i64,[]mode)))=Lookup(M,"no")
        \\Has:logic=Found.IsSet
        \\Absent:logic=Missing.IsSet
    );
    try std.testing.expectEqual(@as(i64, 6), execution.get("Gap").?.integer);
    try std.testing.expectEqual(@as(i64, 2), execution.get("Count").?.integer);
    try std.testing.expect(execution.get("Has").?.boolean and !execution.get("Absent").?.boolean);
    try std.testing.expectEqualDeep(execution.get("M").?.aggregate, execution.elements(execution.get("Settings").?).?[0].aggregate);
}

test "empty nested options are distinct from present empty values and maps infer ordered schemas" {
    const h = try harness();
    defer scratch.release(h);
    const e = try h.execute(
        \\None:option([]i64)=option{}
        \\Some:option([]i64)=option{array{}}
        \\M:map(i64,option([]i64))=map{1=>None,2=>Some}
        \\A:logic=Or(Lookup(M,1),option{}).IsSet
        \\B:logic=Or(Lookup(M,2),option{}).IsSet
        \\C:logic=Lookup(M,3).IsSet
        \\Empty:map(i64,option([]i64))=map{}
        \\Size:i64=Empty.Length
        \\Inferred:option(i64)=Lookup(map{1=>2},1)
    );
    try std.testing.expect(!e.get("A").?.boolean and e.get("B").?.boolean and !e.get("C").?.boolean);
    try std.testing.expectEqual(@as(i64, 0), e.get("Size").?.integer);
    try std.testing.expectEqual(@as(usize, 0), e.elements(e.get("None").?).?.len);
    try std.testing.expectEqual(@as(usize, 1), e.elements(e.get("Some").?).?.len);
    try std.testing.expectEqual(@as(i64, 2), e.elements(e.get("Inferred").?).?[0].integer);
}

test "scalar enum and float map keys have exact nominal NaN signed-zero and UTF8 semantics" {
    const h = try harness();
    defer scratch.release(h);
    const e = try h.execute(
        \\mode:=enum{Dark,Light}
        \\Enums:map(mode,i64)=map{mode.Light=>9,mode.Dark=>6}
        \\Bools:map(logic,i64)=map{false=>3,true=>4}
        \\Floats:map(float,i64)=map{NaN=>7,-0.0=>8,Inf=>9,-Inf=>10,1.0=>11}
        \\Text:map(string,i64)=map{"雪"=>12,"snow"=>13,""=>14}
        \\Value:i64=Or(Lookup(Enums,mode.Dark),0)+Or(Lookup(Bools,true),0)+Or(Lookup(Floats,0.0/0.0),0)+Or(Lookup(Floats,0.0),0)+Or(Lookup(Text,"雪"),0)+Or(Lookup(Text,""),0)
    );
    try std.testing.expectEqual(@as(i64, 51), e.get("Value").?.integer);
    const duplicate_sources = [_][]const u8{
        "M:map(float,i64)=map{NaN=>1,0.0/0.0=>2}",
        "M:map(float,i64)=map{-0.0=>1,0.0=>2}",
        "M:map(i64,i64)=map{1=>2,0+1=>3}",
        "M:map(string,i64)=map{\"a\"=>1,\"a\"=>2}",
        "M:map(logic,i64)=map{true=>1,true=>2}",
        "mode:=enum{Dark};M:map(mode,i64)=map{mode.Dark=>1,mode.Dark=>2}",
    };
    for (duplicate_sources) |source| try std.testing.expectEqual(types.Diagnostic.Code.duplicate_map_key, (try h.evaluate(try h.compile(source), types.limits.evaluation_work)).failed.code);
}

test "map keys values and fallback arguments evaluate strictly before result selection or duplicates" {
    const h = try harness();
    defer scratch.release(h);
    const cases = [_][]const u8{
        "O:option(i64)=option{6};V:i64=Or(O,1/0)",
        "M:map(i64,i64)=map{1=>1,1=>1/0}",
        "M:map(i64,i64)=map{1=>1/0,2=>9223372036854775807+1}",
        "M:map(i64,i64)=map{1=>7};O:option(i64)=Lookup(M,1/0)",
        "p:=struct{M:map(i64,i64)=map{1=>1/0}};P:p=p{}",
    };
    for (cases) |source| try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.evaluate(try h.compile(source), 200)).failed.code);
    const e = try h.execute("p:=struct{M:map(i64,i64)=map{1=>1/0}};P:p=p{M:=map{}};Size:i64=P.M.Length");
    try std.testing.expectEqual(@as(i64, 0), e.get("Size").?.integer);
}

test "invalid collection types arity entries helpers and reserved names have bounded diagnostics" {
    const h = try harness();
    defer scratch.release(h);
    const cases = .{
        .{ "X:option()=option{}", .expected_type },
        .{ "X:option(i64,string)=option{}", .expected_type },
        .{ "X:map(i64)=map{}", .expected_type },
        .{ "X:map([]function(tuple(i64),i64),i64)=map{}", .invalid_map_key },
        .{ "X:option(i64)=option{1,2}", .option_arity },
        .{ "X:i64=Or(option{},1)", .contextual_type_required },
        .{ "X:map(i64,i64)=map{1}", .expected_map_value },
        .{ "X:map(i64,i64)=map{1=>}", .expected_map_value },
        .{ "X:map(i64,i64)=map{1=>1,2}", .expected_map_value },
        .{ "X:[]i64=array{1=>2}", .unexpected_token },
        .{ "X:tuple(i64,i64)=tuple{1=>2}", .unexpected_token },
        .{ "X:option(i64)=option{1=>2}", .unexpected_token },
        .{ "p:=struct{X:i64};P:p=p{X:=1=>2}", .unexpected_token },
        .{ "X:map(i64,i64)=map{1=>\"a\"}", .type_mismatch },
        .{ "X:map(i64,i64)=map{1=>2,\"a\"=>3}", .type_mismatch },
        .{ "X:i64=Or(1,2)", .type_mismatch },
        .{ "X:option(i64)=Lookup(map{1=>2},\"a\")", .type_mismatch },
        .{ "X:option(i64)=Lookup(map{1=>2})", .argument_count },
        .{ "X:i64=Or(option{1},2,3)", .argument_count },
        .{ "X:option(i64)=option{true}", .type_mismatch },
        .{ "X:option(i64)=option{};Y:i64=X.Length", .unknown_field },
        .{ "X:map(i64,i64)=map{};Y:logic=X.IsSet", .unknown_field },
        .{ "Lookup:i64=1", .expected_name },
        .{ "Or:i64=1", .expected_name },
        .{ "map:i64=1", .expected_name },
        .{ "F(option:i64)<computes>:i64=1", .expected_parameter },
    };
    inline for (cases) |case| {
        const source: []const u8 = case[0];
        const result = h.compiler.compile(source);
        if (result == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(@as(types.Diagnostic.Code, case[1]), result.failed.code);
        try std.testing.expect(result.failed.span.start <= result.failed.span.end and result.failed.span.end <= source.len);
    }
}

test "every dynamic map fuel boundary agrees preserves failed registers and permits workspace reuse" {
    const h = try harness();
    defer scratch.release(h);
    const p = try h.compile("M:map(string,i64)=map{\"same-prefix-a\"=>1,\"same-prefix-b\"=>2};V:i64=Or(Lookup(M,\"same-prefix-b\"),3)");
    var first_success: ?u32 = null;
    for (0..200) |budget| {
        const result = try h.evaluate(p, @intCast(budget));
        if (result == .failed) {
            try std.testing.expect(first_success == null);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
        } else {
            if (first_success == null) first_success = @intCast(budget);
            try std.testing.expectEqual(@as(i64, 2), result.ok.get("V").?.integer);
        }
    }
    try std.testing.expect(first_success.? > p.nodes.len + p.members.len);
    h.values[0] = .{ .integer = 999 };
    h.runtime.machine.values[0] = .{ .integer = 999 };
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.evaluate(p, 0)).failed.code);
    try std.testing.expectEqual(@as(i64, 999), h.values[0].integer);
    try std.testing.expectEqual(@as(i64, 999), h.runtime.machine.values[0].integer);
    try std.testing.expectEqual(@as(i64, 2), (try h.evaluate(p, first_success.?)).ok.get("V").?.integer);
}

test "catalogue interning reuses full option and map capacities and malformed unused definitions reject" {
    var store: catalogue.Storage = .{};
    var previous: types.Type = .i64;
    for (0..types.limits.user_types) |index| previous = if (index % 2 == 0) try store.internOption(previous) else try store.internMap(.i64, previous);
    try std.testing.expectEqual(@as(u32, types.limits.user_types), store.count);
    try std.testing.expectEqual(@as(types.Type, @fromBackingInt(4)), try store.internOption(.i64));
    try std.testing.expectEqual(previous, try store.internMap(.i64, store.definitions[store.count - 1].map.value));
    try std.testing.expectError(error.TypeLimit, store.internOption(.string));
    // A map of comparables is itself a key type, so only the full catalogue stops this one.
    try std.testing.expectError(error.TypeLimit, store.internMap(previous, .i64));
    try std.testing.expect(catalogue.validateAll(store.definitions[0..store.count], &.{}, &.{}, &.{}, ""));
    store.definitions[store.count - 1].map.value = @fromBackingInt(600);
    try std.testing.expect(!catalogue.validateAll(store.definitions[0..store.count], &.{}, &.{}, &.{}, ""));
    store.reset();
    _ = try store.internOption(.i64);
    _ = try store.internMap(.i64, .string);
    store.definitions[1] = store.definitions[0];
    try std.testing.expect(!catalogue.validateAll(store.definitions[0..store.count], &.{}, &.{}, &.{}, ""));
}

test "malformed helper operands arity and map schemas are rejected before output or register writes" {
    const h = try harness();
    defer scratch.release(h);
    const p = try h.compile("M:map(i64,i64)=map{1=>2};O:option(i64)=Lookup(M,1);V:i64=Or(O,3);B:logic=O.IsSet");
    var nodes: [64]types.Node = undefined;
    @memcpy(nodes[0..p.nodes.len], p.nodes);
    var bad = p;
    bad.nodes = nodes[0..p.nodes.len];
    for (bad.nodes, 0..) |node, index| {
        nodes[index] = node;
        switch (node.kind) {
            .map_lookup => nodes[index].kind.map_lookup.key = @intCast(p.nodes.len),
            .option_or => nodes[index].kind.option_or.fallback = @intCast(p.nodes.len),
            .option_present => nodes[index].kind.option_present = @intCast(p.nodes.len),
            .aggregate => nodes[index].kind.aggregate.end += 1,
            else => continue,
        }
        h.values[0] = .{ .integer = 999 };
        h.runtime.machine.values[0] = .{ .integer = 999 };
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try h.evaluate(bad, 0)).failed.code);
        try std.testing.expectEqual(@as(i64, 999), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 999), h.runtime.machine.values[0].integer);
        nodes[index] = node;
    }
}

test "reports preflight forged duplicate keys invalid string references exact work and output limits" {
    const h = try harness();
    defer scratch.release(h);
    const e = try h.execute("M<public>:map(string,i64)=map{\"a\"=>1,\"b\"=>2};O<public>:option(i64)=Lookup(M,\"b\");N<public>:option(i64)=option{}");
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const stats = try reporting.write(&out, e, true, .{});
    try std.testing.expectEqualStrings("{\"M\":[\"a\",1,\"b\",2],\"O\":[2],\"N\":[]}\n", out.buffered());
    _ = try reporting.validate(e, true, .{ .work = stats.work, .output_bytes = stats.output_bytes });
    try std.testing.expectError(error.ReportLimit, reporting.validate(e, true, .{ .work = stats.work - 1 }));
    try std.testing.expectError(error.ReportLimit, reporting.validate(e, true, .{ .output_bytes = stats.output_bytes - 1 }));
    const range = e.get("M").?.aggregate.elements;
    const saved = h.runtime.machine.aggregate_values[range.start + 2];
    h.runtime.machine.aggregate_values[range.start + 2] = h.runtime.machine.aggregate_values[range.start];
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, e, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    h.runtime.machine.aggregate_values[range.start + 2] = saved;
    h.runtime.machine.aggregate_values[range.start].string = @as([*]const u8, @ptrFromInt(1))[0..1];
    try std.testing.expectError(error.InvalidExecution, reporting.write(&out, e, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "collection inspection format five preserves schemas and borrows option results without member growth" {
    const h = try harness();
    defer scratch.release(h);
    const e = try h.execute("M:map(i64,string)=map{1=>\"one\"};O:option(string)=Lookup(M,1);N:option(string)=Lookup(M,2);V:string=Or(O,\"fallback\")");
    try std.testing.expectEqual(@as(usize, 2), e.aggregate_values.len);
    try std.testing.expectEqualStrings("one", e.get("V").?.string);
    try std.testing.expectEqual(e.get("M").?.aggregate.elements.start + 1, e.get("O").?.aggregate.elements.start);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(inspection.Result.ok, try h.inspection.write(&out, e.program));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("format").?.integer);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("type_definitions").?.array.items.len);
}

test "two thousand generated lookups agree with an independent source integer oracle" {
    const h = try harness();
    defer scratch.release(h);
    for (0..2000) |seed| {
        const key: i64 = @as(i64, @intCast(seed)) - 1000;
        const value: i64 = @intCast(seed * 7);
        const position: i64 = @intCast(seed % 4);
        var out = std.Io.Writer.fixed(&h.source);
        try out.print("M:map(i64,i64)=map{{{d}=>{d},{d}=>{d},{d}=>{d}}};V:i64=Or(Lookup(M,{d}),-1);Size:i64=M.Length", .{ key, value, key + 1, value + 3, key + 2, value + 6, key + position });
        const e = try h.execute(out.buffered());
        try std.testing.expectEqual(if (position == 3) @as(i64, -1) else value + position * 3, e.get("V").?.integer);
        try std.testing.expectEqual(@as(i64, 3), e.get("Size").?.integer);
    }
}

test "five thousand collection source mutations remain checked and recover to a healthy program" {
    const h = try harness();
    defer scratch.release(h);
    const original = "M:map(string,option(i64))=map{\"a\"=>option{1},\"b\"=>option{}};V:i64=Or(Or(Lookup(M,\"a\"),option{}),3)";
    const punctuation = "{}()[],.:;=>+-*/\"\\\n";
    for (0..5000) |seed| {
        @memcpy(h.source[0..original.len], original);
        h.source[(seed * 37) % original.len] = punctuation[(seed * 13) % punctuation.len];
        const result = h.compiler.compile(h.source[0..original.len]);
        if (result == .ok) _ = try h.evaluate(result.ok, types.limits.evaluation_work) else try std.testing.expect(result.failed.span.end <= original.len);
    }
    const healthy = try h.execute(original);
    try std.testing.expectEqual(@as(i64, 1), healthy.get("V").?.integer);
}

test "map work measures long key bytes and exhausted operations remain reusable" {
    var bytes: [1024]u8 = @splat('x');
    const members = [_]types.Value{ .{ .string = &bytes }, .{ .integer = 3 } };
    var work: keys.Work = .{};
    defer work.release();
    var budget: u64 = 1025;
    try std.testing.expectError(error.WorkLimit, keys.unique(&work, &members, &members, &budget));
    budget = 1026;
    try keys.unique(&work, &members, &members, &budget);
    try std.testing.expectEqual(@as(u64, 0), budget);
    budget = 1025;
    try std.testing.expectError(error.WorkLimit, keys.lookup(&work, &members, &members, .{ .string = &bytes }, &budget));
    budget = 1026;
    try std.testing.expectEqual(@as(?usize, 1), try keys.lookup(&work, &members, &members, .{ .string = &bytes }, &budget));
    try std.testing.expectEqual(@as(u64, 0), budget);
}

test "maps admit the exact full member pool and lookup borrows without reserving another slot" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness();
    defer scratch.release(h);
    var out = std.Io.Writer.fixed(&h.source);
    try out.writeAll("Seed:i64=7;Make()<computes>:map(i64,i64)=map{");
    for (0..128) |index| try out.print("{s}{d}=>Seed", .{ if (index == 0) "" else ",", index });
    try out.writeAll("};V:i64=");
    for (0..32) |index| try out.print("{s}Or(Lookup(Make(),127),Seed)", .{if (index == 0) "" else "+"});
    const p = try h.compile(out.buffered());
    try std.testing.expectEqual(@as(usize, 0), p.members.len);
    try std.testing.expectEqual(@as(usize, 256), p.function_members.len);
    const result = try h.evaluate(p, 65536);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(i64, 224), result.ok.get("V").?.integer);
    try std.testing.expectEqual(@as(usize, types.limits.aggregate_elements), result.ok.aggregate_values.len);
    try out.writeAll(";Extra:option(i64)=option{Seed}");
    const overflow = try h.compile(out.buffered());
    const exhausted = try h.evaluate(overflow, 65536);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, exhausted.failed.code);
    _ = try h.execute("M:map(i64,i64)=map{1=>7};V:i64=Or(Lookup(M,1),0)");
}

test "map runtime exhaustion rolls back active cells and leaves prior committed intents intact" {
    const vm = @import("vm.zig");
    const h = try harness();
    defer scratch.release(h);
    const ir = try h.compile("M:map(string,i64)=map{\"long-key\"=>3};O:option(i64)=Lookup(M,\"long-key\")");
    const p = bytecode.lower(ir, &h.runtime.instructions).ok;
    var code: [64]vm.Instruction = undefined;
    code[0] = .{ .op = .begin };
    @memcpy(code[1 .. p.code.len + 1], p.code);
    code[p.code.len + 1] = .{ .op = .{ .store_cell = .{ .cell = 0, .value = 1 } } };
    code[p.code.len + 2] = .{ .op = .commit };
    var transaction = p;
    transaction.code = code[0 .. p.code.len + 3];
    const machine = &h.runtime.machine;
    try machine.journal.begin();
    try machine.journal.write(0, 11);
    try machine.journal.enqueue(.{ .kind = 1, .argument = 11 });
    try machine.journal.commit();
    var succeeded = false;
    for (0..100) |budget| {
        const result = machine.run(transaction, @intCast(budget));
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.undo_count);
        try std.testing.expectEqual(@as(usize, 1), machine.journal.committed().len);
        if (result == .failed) {
            try std.testing.expect(!succeeded);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            try std.testing.expectEqual(@as(i64, 11), try machine.journal.read(0));
        } else {
            succeeded = true;
            try std.testing.expectEqual(@as(i64, 3), try machine.journal.read(0));
        }
    }
    try std.testing.expect(succeeded);
}

test "raw verified map admits all 4096 pairs within the existing member pool" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness();
    defer scratch.release(h);
    const map_type: types.Type = @fromBackingInt(4);
    const option_type: types.Type = @fromBackingInt(5);
    const definitions = [_]types.Definition{ .{ .map = .{ .key = .i64, .value = .i64 } }, .{ .option = .i64 } };
    const origin: types.Span = .{ .start = 0, .end = 0 };
    for (0..4096) |index| {
        h.compiler.nodes[index] = .{ .span = origin, .value_type = .i64, .kind = .{ .integer = @intCast(index) } };
        h.compiler.members[2 * index] = @intCast(index);
        h.compiler.members[2 * index + 1] = 4096;
    }
    h.compiler.nodes[4096] = .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 7 } };
    h.compiler.nodes[4097] = .{ .span = origin, .value_type = map_type, .kind = .{ .aggregate = .{ .start = 0, .end = 8192 } } };
    h.compiler.nodes[4098] = .{ .span = origin, .value_type = option_type, .kind = .{ .map_lookup = .{ .map = 4097, .key = 4095 } } };
    h.compiler.nodes[4099] = .{ .span = origin, .value_type = .i64, .kind = .{ .option_or = .{ .option = 4098, .fallback = 4096 } } };
    const bindings = [_]types.Binding{.{ .name = .{ .start = 0, .end = 1 }, .node = 4099, .value_type = .i64, .is_public = true }};
    const p: types.Program = .{ .source = "V", .strings = "", .nodes = h.compiler.nodes[0..4100], .bindings = &bindings, .definitions = &definitions, .members = &h.compiler.members };
    const result = try h.evaluate(p, 65536);
    try std.testing.expectEqual(@as(i64, 7), result.ok.get("V").?.integer);
    try std.testing.expectEqual(@as(usize, 8192), result.ok.aggregate_values.len);
    // Same IR with the last key aliasing the first must reject a duplicate,
    // without an arbitrary width restriction or assertion at full storage.
    h.compiler.nodes[4095].kind.integer = 0;
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_map_key, (try h.evaluate(p, 65536)).failed.code);
}

test "five thousand collection catalogue IR and member mutations agree and preserve admission safety" {
    const h = try harness();
    defer scratch.release(h);
    const original = try h.compile("M:map(i64,option(i64))=map{1=>option{7},2=>option{}};O:option(option(i64))=Lookup(M,1);V:i64=Or(Or(O,option{}),3);B:logic=O.IsSet");
    var nodes: [64]types.Node = undefined;
    var definitions: [16]types.Definition = undefined;
    var members: [64]u32 = undefined;
    var state: u64 = 0x5839ec014a8fd276;
    for (0..5000) |_| {
        @memcpy(nodes[0..original.nodes.len], original.nodes);
        @memcpy(definitions[0..original.definitions.len], original.definitions);
        @memcpy(members[0..original.members.len], original.members);
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const index: usize = @intCast(state % original.nodes.len);
        switch (state % 4) {
            0 => nodes[index].value_type = @fromBackingInt(@intCast((state >> 16) % 65536)),
            1 => nodes[index].span.end = @intCast((state >> 16) % 65536),
            2 => members[@intCast(state % original.members.len)] = @intCast((state >> 16) % 8193),
            3 => definitions[@intCast(state % original.definitions.len)] = .{ .option = @fromBackingInt(@intCast((state >> 16) % 65536)) },
            else => unreachable,
        }
        var changed = original;
        changed.nodes = nodes[0..original.nodes.len];
        changed.definitions = definitions[0..original.definitions.len];
        changed.members = members[0..original.members.len];
        @memset(h.values[0..original.nodes.len], .{ .integer = 99 });
        @memset(h.runtime.machine.values[0..original.nodes.len], .{ .integer = 99 });
        @memset(h.members[0..original.members.len], .{ .integer = 88 });
        @memset(h.runtime.machine.aggregate_values[0..original.members.len], .{ .integer = 88 });
        const result = try h.evaluate(changed, @intCast(state % 128));
        if (result == .failed) try std.testing.expect(result.failed.span.end <= original.source.len);
        try std.testing.expectEqualDeep(h.values[0..original.nodes.len], h.runtime.machine.values[0..original.nodes.len]);
        try std.testing.expectEqualDeep(h.members[0..original.members.len], h.runtime.machine.aggregate_values[0..original.members.len]);
    }
    try std.testing.expectEqual(@as(i64, 7), (try h.evaluate(original, 512)).ok.get("V").?.integer);
}
