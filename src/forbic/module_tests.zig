const std = @import("std");
const scratch = @import("scratch.zig");
const compiler = @import("compiler.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const vm = @import("vm.zig");
const types = @import("types.zig");

const Harness = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,

    fn execute(self: *Harness, inputs: []const modules.Input) !evaluator.Execution {
        const ir = switch (self.compiler.compileBundle(.{ .root = "main.forb", .modules = inputs })) {
            .ok => |ir| ir,
            .failed => |problem| {
                std.debug.print("module compile failed: {s}:{d}: {s}\n", .{ problem.path, problem.diagnostic.span.start, problem.diagnostic.message() });
                return error.UnexpectedCompile;
            },
        };
        const reference = switch (evaluator.evaluateWithStorage(ir, &self.values, &self.members, 32768)) {
            .ok => |execution| execution,
            .failed => |diagnostic| {
                std.debug.print("module reference failed: {s}\n", .{diagnostic.message()});
                return error.UnexpectedReference;
            },
        };
        const actual = switch (self.runtime.evaluate(ir, 32768)) {
            .ok => |execution| execution,
            .failed => |diagnostic| {
                std.debug.print("module VM failed: {s}\n", .{diagnostic.message()});
                return error.UnexpectedVm;
            },
        };
        try std.testing.expectEqual(reference.values.len, actual.values.len);
        for (reference.values, actual.values) |left, right| try equalValue(left, right);
        try std.testing.expectEqual(reference.aggregate_values.len, actual.aggregate_values.len);
        for (reference.aggregate_values, actual.aggregate_values) |left, right| try equalValue(left, right);
        return actual;
    }
};
fn harness() !*Harness {
    const result = try scratch.make(Harness);
    return result;
}
fn equalValue(left: types.Value, right: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
    switch (left) {
        .floating => |value| try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(right.floating))),
        .string => |value| try std.testing.expectEqualStrings(value, right.string),
        .integer => |value| try std.testing.expectEqual(value, right.integer),
        .boolean => |value| try std.testing.expectEqual(value, right.boolean),
        .aggregate => |value| try std.testing.expectEqualDeep(value, right.aggregate),
        .enumeration => |value| try std.testing.expectEqualDeep(value, right.enumeration),
        .callable => |value| try std.testing.expectEqualDeep(value, right.callable),
        .object => |value| try std.testing.expectEqualDeep(value, right.object),
        .rational => |value| try std.testing.expectEqualDeep(value, right.rational),
    }
}

const shared =
    \\Bias:i64=3
    \\point<public>:=struct{x:i64=Bias,tint:string="#7e9cd8"}
    \\mode<public>:=enum<closed>{dark,light}
    \\Make<public>(x:i64)<computes>:point=point{x:=x}
    \\Scale<public>(x:float)<computes>:float=x/2.0
;
const left_source =
    \\S:=import{"shared.forb"}
    \\Value<public>:i64=5
    \\Get<public>()<computes>:i64=S.Make(Value).x+S.Make(1).x
;
const right_source =
    \\S:=import{"shared.forb"}
    \\point<public>:=struct{x:i64=17}
    \\Value<public>:i64=17
    \\Get<public>()<computes>:i64=Value
;
const main_source =
    \\L:=import{"left.forb"}
    \\R:=import{"right.forb"}
    \\S:=import{"shared.forb"}
    \\Total<public>:i64=L.Get()+R.Get()
    \\Items:[]S.point=array{S.Make(7),S.point{}}
    \\Tone:S.mode=S.mode.dark
    \\Different:R.point=R.point{}
    \\Pair:option(tuple(S.point,R.point))=option{tuple{S.Make(8),R.point{}}}
;
const fixture_inputs = [_]modules.Input{
    .{ .path = "main.forb", .source = main_source },
    .{ .path = "right.forb", .source = right_source },
    .{ .path = "shared.forb", .source = shared },
    .{ .path = "left.forb", .source = left_source },
};

test "qualified modules retain nominal identity defaults captures and root-only reporting" {
    const h = try harness();
    defer scratch.release(h);
    const execution = try h.execute(&fixture_inputs);
    try std.testing.expectEqual(@as(i64, 23), execution.get("Total").?.integer);
    try std.testing.expectEqual(@as(usize, 5), execution.program.bindings.len);
    try std.testing.expect(execution.get("Bias") == null and execution.get("Value") == null);
    const items = execution.elements(execution.get("Items").?).?;
    try std.testing.expectEqual(@as(i64, 7), execution.elements(items[0]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 3), execution.elements(items[1]).?[0].integer);
    try std.testing.expect(items[0].aggregate.value_type != execution.get("Different").?.aggregate.value_type);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try reporting.write(&out.writer, execution, true, .{});
    try std.testing.expectEqualStrings("{\"Total\":23}\n", out.written());
    const reversed = [_]modules.Input{ fixture_inputs[3], fixture_inputs[2], fixture_inputs[1], fixture_inputs[0] };
    const again = try h.execute(&reversed);
    try std.testing.expectEqual(@as(i64, 23), again.get("Total").?.integer);
    try std.testing.expectEqualStrings("shared.forb", again.program.modules[0].path.text(again.program.paths));
}

test "private names ambient scope late imports and unused public private-type escape are rejected" {
    const h = try harness();
    defer scratch.release(h);
    try std.testing.expectEqual(types.Diagnostic.Code.module_bundle_required, h.compiler.compile("T:=import{\"b.forb\"}").failed.code);
    const cases = [_]struct { root: []const u8, dependency: []const u8, code: types.Diagnostic.Code, path: []const u8 = "main.forb" }{
        .{ .root = "T:=import{\"b.forb\"}\nA:i64=T.Hidden", .dependency = "Hidden:i64=9", .code = .private_name },
        .{ .root = "T:=import{\"b.forb\"}\nA:i64=T.Hide()", .dependency = "Hide()<computes>:i64=9", .code = .private_name },
        .{ .root = "T:=import{\"b.forb\"}\nA:T.secret=T.secret{}", .dependency = "secret:=struct{x:i64=9}", .code = .private_name },
        .{ .root = "T:=import{\"b.forb\"}\nA:i64=Value", .dependency = "Value<public>:i64=9", .code = .unknown_name },
        .{ .root = "T:=import{\"b.forb\"}\nA:i64=T.Ghost", .dependency = "Value<public>:i64=9", .code = .unknown_name },
        .{ .root = "T:=import{\"b.forb\"}\nT:i64=9", .dependency = "Value<public>:i64=9", .code = .duplicate_name },
        .{ .root = "A:i64=1\nT:=import{\"b.forb\"}", .dependency = "Value<public>:i64=9", .code = .late_import },
        .{ .root = "T<public>:=import{\"b.forb\"}", .dependency = "Value<public>:i64=9", .code = .unsupported_specifier },
        .{ .root = "T:=import{\"b.forb\"}", .dependency = "secret:=struct{x:i64=9}\nHide<public>()<computes>:secret=secret{}", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "T:=import{\"b.forb\"}", .dependency = "secret:=enum{a}\nA<public>:option(secret)=option{}", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "T:=import{\"b.forb\"}", .dependency = "secret:=struct{x:i64}\nPublic<public>:=struct{hidden:[]secret}", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "T:=import{\"b.forb\"}", .dependency = "Unused()<computes>:i64=Unknown", .code = .unknown_name, .path = "b.forb" },
        .{ .root = "T:=import{\"b.forb\"}", .dependency = "Back:=import{\"main.forb\"}", .code = .module_cycle, .path = "b.forb" },
        .{ .root = "T:=import{\"missing.forb\"}", .dependency = "", .code = .missing_module },
        .{ .root = "T:=import{\"../outside.forb\"}", .dependency = "", .code = .invalid_module_path },
    };
    for (cases) |case| {
        const program_inputs = [_]modules.Input{ .{ .path = "main.forb", .source = case.root }, .{ .path = "b.forb", .source = case.dependency } };
        const failed = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &program_inputs }).failed;
        try std.testing.expectEqual(case.code, failed.diagnostic.code);
        try std.testing.expectEqualStrings(case.path, failed.path);
        try std.testing.expect(failed.diagnostic.span.start <= failed.diagnostic.span.end and failed.diagnostic.span.end <= failed.source.len);
        _ = try h.execute(&fixture_inputs);
    }
}

test "module boundaries cannot repair malformed expressions and failures retain defining locations" {
    const h = try harness();
    defer scratch.release(h);
    const broken = [_]modules.Input{
        .{ .path = "main.forb", .source = "T:=import{\"b.forb\"}\n)\nRoot:i64=1" },
        .{ .path = "b.forb", .source = "Value<public>:i64=(1" },
    };
    const rejected = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &broken }).failed;
    try std.testing.expectEqualStrings("b.forb", rejected.path);
    try std.testing.expect(rejected.diagnostic.span.end <= broken[1].source.len);
    const failing = [_]modules.Input{
        .{ .path = "main.forb", .source = "T:=import{\"b.forb\"}\nAnswer:i64=T.Fault()" },
        .{ .path = "b.forb", .source = "# helper\nFault<public>()<computes>:i64=1/0" },
    };
    const ir = h.compiler.compileBundle(.{ .root = "main.forb", .modules = &failing }).ok;
    const vm_failed = h.runtime.evaluate(ir, 32768).failed;
    const ref_failed = evaluator.evaluateWithStorage(ir, &h.values, &h.members, 32768).failed;
    try std.testing.expectEqualDeep(vm_failed, ref_failed);
    const located = modules.locate(ir.source, ir.paths, ir.modules, vm_failed, "main.forb");
    try std.testing.expectEqualStrings("b.forb", located.path);
    try std.testing.expectEqual(@as(u32, 2), located.diagnostic.location(located.source).line);
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, located.diagnostic.code);
    _ = try h.execute(&fixture_inputs);
}

test "module inspection admits all metadata before output and exposes source provenance" {
    const h = try harness();
    defer scratch.release(h);
    const execution = try h.execute(&fixture_inputs);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out.writer, execution.program));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"local_span\"") != null);
    out.clearRetainingCapacity();
    var bad = execution.program;
    bad.imports = bad.imports[0 .. bad.imports.len - 1];
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try workspace.write(&out.writer, bad)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "all 64 dependency frames and 256 imports admit their exact capacities and recover" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness();
    defer scratch.release(h);
    var paths: [65][32]u8 = undefined;
    var sources: [65][128]u8 = undefined;
    var inventory: [65]modules.Input = undefined;
    for (0..65) |index| {
        const path = if (index == 0) "main.forb" else try std.fmt.bufPrint(&paths[index], "m/{d}.forb", .{index});
        const source = if (index >= 63) "Value<public>:i64=1" else if (index == 0)
            try std.fmt.bufPrint(&sources[index], "Next:=import{{\"m/1.forb\"}};Value<public>:i64=Next.Value+1", .{})
        else
            try std.fmt.bufPrint(&sources[index], "Next:=import{{\"{d}.forb\"}};Value<public>:i64=Next.Value+1", .{index + 1});
        inventory[index] = .{ .path = path, .source = source };
    }
    const chain = try h.execute(inventory[0..64]);
    try std.testing.expectEqual(@as(usize, 64), chain.program.modules.len);
    try std.testing.expectEqual(@as(i64, 64), chain.get("Value").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.module_limit, h.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory }).failed.diagnostic.code);
    const source = try std.testing.allocator.alloc(u8, 16384);
    defer std.testing.allocator.free(source);
    var out = std.Io.Writer.fixed(source);
    for (0..256) |index| try out.print("M{d}:=import{{\"dep.forb\"}};", .{index});
    const prefix = out.end;
    try out.writeAll("Value:i64=M255.Value");
    var fanout = [_]modules.Input{ .{ .path = "main.forb", .source = out.buffered() }, .{ .path = "dep.forb", .source = "Value<public>:i64=7" } };
    const exact = try h.execute(&fanout);
    try std.testing.expectEqual(@as(usize, 256), exact.program.imports.len);
    try std.testing.expectEqual(@as(usize, 2), exact.program.modules.len);
    try std.testing.expectEqual(@as(i64, 7), exact.get("Value").?.integer);
    out.end = prefix;
    try out.writeAll("M256:=import{\"dep.forb\"};Value:i64=M256.Value");
    fanout[0].source = out.buffered();
    try std.testing.expectEqual(types.Diagnostic.Code.import_limit, h.compiler.compileBundle(.{ .root = "main.forb", .modules = &fanout }).failed.diagnostic.code);
    _ = try h.execute(&fixture_inputs);
}

test "module paths source joins and empty roots have precise independent boundaries" {
    const h = try harness();
    defer scratch.release(h);
    const path: [types.limits.module_path_bytes]u8 = @splat('a');
    const single = [_]modules.Input{.{ .path = &path, .source = "Value:i64=7" }};
    const exact = h.compiler.compileBundle(.{ .root = &path, .modules = &single }).ok;
    try std.testing.expectEqualStrings(&path, exact.modules[0].path.text(exact.paths));
    try std.testing.expectEqual(@as(i64, 7), h.runtime.evaluate(exact, 1).ok.get("Value").?.integer);
    const too_long: [types.limits.module_path_bytes + 1]u8 = @splat('a');
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_module_path, h.compiler.compileBundle(.{ .root = &too_long, .modules = &single }).failed.diagnostic.code);
    const source = try std.testing.allocator.alloc(u8, types.limits.source_bytes);
    defer std.testing.allocator.free(source);
    @memset(source, '#');
    var inventory = [_]modules.Input{ .{ .path = "main.forb", .source = source }, .{ .path = "d.forb", .source = "" } };
    const full = h.compiler.compileBundle(.{ .root = "main.forb", .modules = inventory[0..1] }).ok;
    try std.testing.expectEqual(@as(usize, types.limits.source_bytes), full.source.len);
    try std.testing.expectEqual(@as(usize, 0), h.runtime.evaluate(full, 0).ok.values.len);
    const prefix = "D:=import{\"d.forb\"}\n#";
    @memcpy(source[0..prefix.len], prefix);
    try std.testing.expectEqual(types.Diagnostic.Code.source_limit, h.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory }).failed.diagnostic.code);
    inventory[0].source = "D:=import{\"d.forb\"}";
    inventory[1].source = "Imported<public>:i64=1";
    const empty_root = try h.execute(&inventory);
    try std.testing.expectEqual(@as(usize, 0), empty_root.program.bindings.len);
    try std.testing.expectEqual(@as(usize, 1), empty_root.values.len);
    inventory[1].path = "main.forb";
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_module, h.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory }).failed.diagnostic.code);
    _ = try h.execute(&fixture_inputs);
}

test "every module fuel boundary agrees and retains the defining module for exhaustion" {
    const h = try harness();
    defer scratch.release(h);
    const execution = try h.execute(&fixture_inputs);
    const ir = execution.program;
    const total: u32 = @intCast(ir.nodes.len + ir.members.len);
    for (0..total + 1) |budget| {
        const reference = evaluator.evaluateWithStorage(ir, &h.values, &h.members, @intCast(budget));
        const actual = h.runtime.evaluate(ir, @intCast(budget));
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (reference == .failed) {
            try std.testing.expectEqualDeep(reference.failed, actual.failed);
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, reference.failed.code);
            const located = modules.locate(ir.source, ir.paths, ir.modules, reference.failed, "main.forb");
            try std.testing.expect(located.diagnostic.span.end <= located.source.len);
        } else {
            for (reference.ok.values, actual.ok.values) |lhs, rhs| try equalValue(lhs, rhs);
            try std.testing.expectEqual(@as(i64, 23), actual.ok.get("Total").?.integer);
        }
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
    }
    _ = try h.execute(&fixture_inputs);
}

test "3000 raw module metadata mutations preserve independent admission and idle state" {
    const h = try harness();
    defer scratch.release(h);
    const original = (try h.execute(&fixture_inputs)).program;
    var generator = std.Random.DefaultPrng.init(0x6000600060);
    const random = generator.random();
    var module_table: [4]types.Module = undefined;
    var import_table: [5]types.Import = undefined;
    var bindings: [5]types.Binding = undefined;
    for (0..3000) |_| {
        @memcpy(&module_table, original.modules);
        @memcpy(&import_table, original.imports);
        @memcpy(&bindings, original.bindings);
        var ir = original;
        ir.modules = &module_table;
        ir.imports = &import_table;
        ir.bindings = &bindings;
        const index = random.uintLessThan(usize, module_table.len);
        const edge = random.uintLessThan(usize, import_table.len);
        const value = random.uintLessThan(u32, @intCast(original.source.len + 8));
        switch (random.uintLessThan(u8, 12)) {
            0 => module_table[index].source.start = value,
            1 => module_table[index].source.end = value,
            2 => module_table[index].path.start = value,
            3 => module_table[index].path.end = value,
            4 => module_table[index].imports.start = value,
            5 => module_table[index].imports.end = value,
            6 => import_table[edge].target = value,
            7 => import_table[edge].alias.start = value,
            8 => import_table[edge].path.end = value,
            9 => ir.imports = import_table[0..random.uintLessThan(usize, import_table.len + 1)],
            10 => bindings[0].name = original.nodes[0].span,
            11 => ir.paths = original.paths[0..random.uintLessThan(usize, original.paths.len + 1)],
            else => unreachable,
        }
        h.values[0] = .{ .integer = 123456789 };
        h.runtime.machine.values[0] = .{ .integer = 123456789 };
        h.runtime.machine.journal.cells[0] = 17;
        const reference = evaluator.evaluateWithStorage(ir, &h.values, &h.members, 0);
        const actual = h.runtime.evaluate(ir, 0);
        try std.testing.expect(reference == .failed and actual == .failed);
        try std.testing.expectEqual(reference.failed.code, actual.failed.code);
        try std.testing.expect(reference.failed.code == .invalid_ir or reference.failed.code == .work_limit);
        try std.testing.expectEqual(@as(i64, 123456789), h.values[0].integer);
        try std.testing.expectEqual(@as(i64, 123456789), h.runtime.machine.values[0].integer);
        try std.testing.expectEqual(@as(i64, 17), h.runtime.machine.journal.cells[0]);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
        // Exercise the independent VM preflight even when lowering rejected it.
        const raw: vm.Program = .{ .source = ir.source, .strings = ir.strings, .code = h.runtime.instructions[0..ir.nodes.len], .bindings = ir.bindings, .definitions = ir.definitions, .fields = ir.fields, .members = ir.members, .cases = ir.cases, .tuple_elements = ir.tuple_elements, .paths = ir.paths, .modules = ir.modules, .imports = ir.imports, .call_ops = ir.call_ops, .call_arguments = ir.call_arguments, .functions = ir.functions, .function_nodes = ir.function_nodes, .function_members = ir.function_members, .function_arguments = ir.function_arguments, .globals = ir.globals };
        const checked = vm.verify(raw, &h.runtime.machine.register_types);
        try std.testing.expect((checked == .failed) == (evaluator.validate(ir, h.values.len) != null));
    }
    _ = try h.execute(&fixture_inputs);
}

test "128 generated module graphs match an independent arithmetic oracle under shuffled inventories" {
    const h = try harness();
    defer scratch.release(h);
    var generator = std.Random.DefaultPrng.init(0x60006060);
    const random = generator.random();
    var paths: [13][32]u8 = undefined;
    var sources: [13][768]u8 = undefined;
    var inventory: [13]modules.Input = undefined;
    var expected: [12]i64 = undefined;
    for (0..128) |_| {
        const count = random.intRangeAtMost(usize, 3, 12);
        for (0..count) |index| {
            const path = try std.fmt.bufPrint(&paths[index], "m/{d}.forb", .{index});
            var out = std.Io.Writer.fixed(&sources[index]);
            const bias = random.intRangeAtMost(i64, -7, 19);
            if (index != 0) try out.print("Prev:=import{{\"./{d}.forb\"}};", .{index - 1});
            const earlier = if (index > 1) random.uintLessThan(usize, index - 1) else 0;
            if (index > 1) try out.print("Other:=import{{\"../m/{d}.forb\"}};", .{earlier});
            try out.print("Bias:i64={d};Get<public>()<computes>:i64=Bias", .{bias});
            if (index != 0) try out.writeAll("+Prev.Get()");
            if (index > 1) try out.writeAll("+Other.Get()");
            expected[index] = bias + (if (index != 0) expected[index - 1] else @as(i64, 0)) + (if (index > 1) expected[earlier] else @as(i64, 0));
            inventory[index] = .{ .path = path, .source = out.buffered() };
        }
        inventory[count] = .{ .path = "main.forb", .source = try std.fmt.bufPrint(&sources[count], "Last:=import{{\"m/{d}.forb\"}};First:=import{{\"m/0.forb\"}};Use(Tail:i64)<computes>:i64=Tail+First.Get();Answer<public>:i64=Use(Last.Get())", .{count - 1}) };
        var fingerprint: u64 = 0;
        for (0..3) |permutation| {
            random.shuffle(modules.Input, inventory[0 .. count + 1]);
            const execution = try h.execute(inventory[0 .. count + 1]);
            try std.testing.expectEqual(expected[count - 1] + expected[0], execution.get("Answer").?.integer);
            try std.testing.expectEqual(@as(usize, 1), execution.program.bindings.len);
            const current = std.hash.Wyhash.hash(0, execution.program.source);
            if (permutation == 0) fingerprint = current else try std.testing.expectEqual(fingerprint, current);
        }
    }
    _ = try h.execute(&fixture_inputs);
}

test "every source truncation stays inside its original module and admits reusable state" {
    const h = try harness();
    defer scratch.release(h);
    var inventory = fixture_inputs;
    for (fixture_inputs, 0..) |input, index| {
        for (0..input.source.len + 1) |end| {
            inventory[index].source = input.source[0..end];
            switch (h.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory })) {
                .failed => |problem| {
                    try std.testing.expect(problem.diagnostic.span.start <= problem.diagnostic.span.end and problem.diagnostic.span.end <= problem.source.len);
                    var found = false;
                    for (inventory) |item| if (std.mem.eql(u8, item.path, problem.path)) {
                        found = true;
                        try std.testing.expectEqualStrings(item.source, problem.source);
                    };
                    try std.testing.expect(found);
                },
                .ok => |program| {
                    try std.testing.expect(evaluator.validate(program, h.values.len) == null);
                    const reference = evaluator.evaluateWithStorage(program, &h.values, &h.members, 32768);
                    const actual = h.runtime.evaluate(program, 32768);
                    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
                    if (reference == .failed) try std.testing.expectEqualDeep(reference.failed, actual.failed);
                },
            }
            try std.testing.expectEqual(@as(usize, 0), h.runtime.machine.journal.depth);
        }
        inventory[index] = input;
        _ = try h.execute(&fixture_inputs);
    }
}
