const std = @import("std");
const scratch = @import("scratch.zig");
const compiler = @import("compiler.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const types = @import("types.zig");

const Storage = struct {
    pub const parts = .{ "compiler", "runtime" };
    compiler: *compiler.Workspace,
    runtime: *bytecode.Workspace,
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [types.limits.source_bytes]u8 = undefined,

    fn execute(self: *Storage, source: []const u8) !evaluator.Execution {
        const ir = switch (self.compiler.compile(source)) {
            .ok => |ir| ir,
            .failed => |diagnostic| {
                std.debug.print("aggregate compile failed at {d}: {s}\n", .{ diagnostic.span.start, diagnostic.message() });
                return error.UnexpectedCompile;
            },
        };
        const reference = switch (evaluator.evaluateWithStorage(ir, &self.values, &self.members, 32768)) {
            .ok => |value| value,
            .failed => |diagnostic| {
                std.debug.print("aggregate reference failed: {s}\n", .{diagnostic.message()});
                return error.UnexpectedReference;
            },
        };
        const actual = switch (self.runtime.evaluate(ir, 32768)) {
            .ok => |value| value,
            .failed => |diagnostic| {
                std.debug.print("aggregate VM failed: {s}\n", .{diagnostic.message()});
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

fn storage() !*Storage {
    const result = try scratch.make(Storage);
    return result;
}

test "records arrays contextual empties and aliases compose through pure functions" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\palette<public> := struct { Bg:string, Opacity:float }
        \\desktop := struct {
        \\    Theme:palette
        \\    Workspaces:[]i64
        \\}
        \\Base:palette=palette{Opacity := 0.7, Bg := "snow: 雪"}
        \\Make(X:palette)<computes>:desktop=desktop{Workspaces := array{1,2,3},Theme := X}
        \\Keep(X:desktop)<computes>:desktop=X
        \\Config<public>:desktop=Keep(Make(Base))
        \\Alias:desktop=Config
        \\Background:string=Config.Theme.Bg
        \\Count:i64=Config.Workspaces.Length
        \\Empty:[]palette=array{}
        \\Nested:[][]palette=array{array{},array{Base}}
        \\Length(X:[]palette)<computes>:i64=X.Length
        \\EmptyCount:i64=Length(array{})
        \\Factory()<computes>:[]palette=array{}
        \\FactoryCount:i64=Factory().Length
    );
    try std.testing.expectEqualStrings("snow: 雪", result.get("Background").?.string);
    try std.testing.expectEqual(@as(i64, 3), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.get("EmptyCount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.get("FactoryCount").?.integer);
    try std.testing.expectEqualDeep(result.get("Config").?.aggregate, result.get("Alias").?.aggregate);
    const nested = result.elements(result.get("Nested").?).?;
    try std.testing.expectEqual(@as(usize, 0), result.elements(nested[0]).?.len);
    try std.testing.expectEqual(@as(usize, 1), result.elements(nested[1]).?.len);
}

test "aggregate templates capture immutable globals and remap nested constructors" {
    const s = try storage();
    defer scratch.release(s);
    const result = try s.execute(
        \\point := struct { X:i64,Y:i64 }
        \\Origin:point=point{X:=4,Y:=5}
        \\Captured()<computes>:point=Origin
        \\Pair(X:point)<computes>:[]point=array{X,Captured()}
        \\Wrap(X:i64)<computes>:[][]point=array{Pair(point{Y:=X+1,X:=X}),array{}}
        \\All:[][]point=Wrap(10)
        \\Repeated:[][]point=Wrap(20)
        \\X:i64=Captured().X
    );
    try std.testing.expectEqual(@as(i64, 4), result.get("X").?.integer);
    const row = result.elements(result.elements(result.get("All").?).?[0]).?;
    try std.testing.expectEqual(@as(i64, 10), result.elements(row[0]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 11), result.elements(row[0]).?[1].integer);
    try std.testing.expectEqualDeep(result.get("Origin").?.aggregate, row[1].aggregate);
}

test "records preserve source evaluation order while storing fields in schema order" {
    const s = try storage();
    defer scratch.release(s);
    const source = "pair:=struct{A:i64,B:i64};Value:pair=pair{B:=1/0,A:=9223372036854775807+1}";
    const ir = s.compiler.compile(source).ok;
    const ref_failure = evaluator.evaluateWithStorage(ir, &s.values, &s.members, 32768).failed;
    const vm_failure = s.runtime.evaluate(ir, 32768).failed;
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, ref_failure.code);
    try std.testing.expectEqualDeep(ref_failure, vm_failure);
    try std.testing.expectEqualStrings("/", ref_failure.span.text(source));
    const unused = "pair:=struct{A:i64};Keep(X:pair)<computes>:i64=7;Value:i64=Keep(pair{A:=1/0})";
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, s.runtime.evaluate(s.compiler.compile(unused).ok, 32768).failed.code);
}

test "aggregate admission rejects ambiguity missing fields and exact type violations" {
    const s = try storage();
    defer scratch.release(s);
    const cases = .{
        .{ "p:=struct{X:i64,X:i64}", types.Diagnostic.Code.duplicate_field },
        .{ "p:=struct{X:i64};A:p=p{}", types.Diagnostic.Code.missing_field },
        .{ "p:=struct{X:i64};A:p=p{X:=1,X:=2}", types.Diagnostic.Code.duplicate_field },
        .{ "p:=struct{X:i64};A:p=p{Y:=1}", types.Diagnostic.Code.unknown_field },
        .{ "p:=struct{X:i64};A:p=p{X:=true}", types.Diagnostic.Code.type_mismatch },
        .{ "p:=struct{X:i64};q:=struct{X:i64};A:q=p{X:=1}", types.Diagnostic.Code.type_mismatch },
        .{ "A:[]i64=array{1,true}", types.Diagnostic.Code.type_mismatch },
        .{ "A:i64=array{}", types.Diagnostic.Code.array_type_required },
        .{ "A:[]i64=array{array{}}", types.Diagnostic.Code.array_type_required },
        .{ "p:=struct{X:p}", types.Diagnostic.Code.unsupported_type },
        .{ "A:[]i64=array{1};B:i64=A.Unknown", types.Diagnostic.Code.unknown_field },
        .{ "p:=struct{};p:i64=1", types.Diagnostic.Code.duplicate_name },
        .{ "p:=struct{X:i64};A:p=p{X:=}", types.Diagnostic.Code.expected_expression },
        .{ "A:[]i64=array{(}", types.Diagnostic.Code.expected_expression },
        .{ "A:[]i64=array{1)", types.Diagnostic.Code.unexpected_token },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[1], s.compiler.compile(case[0]).failed.code);
    // A failed partial compilation must not retain catalogue/member state.
    const result = try s.execute("p:=struct{};A:p=p{};Items:[]p=array{A};Count:i64=Items.Length");
    try std.testing.expectEqual(@as(i64, 1), result.get("Count").?.integer);
}

test "wide arrays use member storage rather than the expression operand stack" {
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("Items:[]i64=array{");
    for (0..2048) |index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", index });
    try out.writeAll("};Count:i64=Items.Length");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 2048), result.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 2047), result.elements(result.get("Items").?).?[2047].integer);
}

test "aggregate source mutations never turn user input into an assertion" {
    const s = try storage();
    defer scratch.release(s);
    const original = "p:=struct{X:i64,A:[]i64};F(P:p)<computes>:[]p=array{P,p{A:=array{},X:=3}};Items:[]p=F(p{X:=2,A:=array{1,2}});Count:i64=Items.Length";
    const mutations = "{}[]().,:;=+-*/<>\n\"\\";
    for (0..5000) |iteration| {
        @memcpy(s.source[0..original.len], original);
        const position = (iteration * 37) % original.len;
        s.source[position] = mutations[(iteration / original.len) % mutations.len];
        switch (s.compiler.compile(s.source[0..original.len])) {
            .failed => |diagnostic| try std.testing.expect(diagnostic.span.start <= diagnostic.span.end and diagnostic.span.end <= original.len),
            .ok => |ir| {
                const reference = evaluator.evaluateWithStorage(ir, &s.values, &s.members, 32768);
                const actual = s.runtime.evaluate(ir, 32768);
                try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
                if (reference == .failed) try std.testing.expectEqualDeep(reference.failed, actual.failed);
            },
        }
    }
}

test "template expansion accounts for members and admits the exact aggregate pool" {
    try @import("profile.zig").requireBootstrap();
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("Seed:i64=9;Many()<computes>:[]i64=array{");
    for (0..1024) |index| try out.print("{s}Seed", .{if (index == 0) "" else ","});
    try out.writeAll("};");
    for (0..8) |index| try out.print("A{d}:[]i64=Many();", .{index});
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(types.limits.aggregate_elements, result.aggregate_values.len);
    try std.testing.expectEqual(@as(usize, 1024), result.elements(result.get("A7").?).?.len);
    try std.testing.expectEqual(@as(u32, 2049), s.compiler.functions.definitions[0].work);
    try std.testing.expectEqual(@as(u32, 0), s.compiler.expansion_work);
    try std.testing.expectEqual(@as(usize, 1024), result.program.function_members.len);
    try out.writeAll("Overflow:[]i64=Many()");
    const overflow = s.compiler.compile(out.buffered()).ok;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, s.runtime.evaluate(overflow, 32768).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithStorage(overflow, &s.values, &s.members, 32768).failed.code);
    try std.testing.expectEqual(@as(i64, 42), (try s.execute("Answer:i64=42")).get("Answer").?.integer);
}

test "deep immutable type graphs do not consume native or expression stacks" {
    const s = try storage();
    defer scratch.release(s);
    var out = std.Io.Writer.fixed(&s.source);
    try out.writeAll("r0:=struct{Value:i64};V0:r0=r0{Value:=42};");
    for (1..200) |index| try out.print("r{d}:=struct{{Value:r{d}}};V{d}:r{d}=r{d}{{Value:=V{d}}};", .{ index, index - 1, index, index, index, index - 1 });
    try out.writeAll("Answer:i64=V199");
    for (0..200) |_| try out.writeAll(".Value");
    const result = try s.execute(out.buffered());
    try std.testing.expectEqual(@as(i64, 42), result.get("Answer").?.integer);
    try std.testing.expectEqual(@as(usize, 200), result.program.definitions.len);
    try std.testing.expectEqual(@as(usize, 200), result.aggregate_values.len);
}
