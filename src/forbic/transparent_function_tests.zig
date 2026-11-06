//! Transparent functions (RFC-0085, I7): `Name(P)<effects> := Body` takes its result type from
//! its body. The code entry is marked `transparent` for P5 and inspection; nothing else differs
//! from a function whose result type is written, in both machines, the replay and every trace
//! mode. `<constructor>` keeps `:=` for constructor functions.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const nested = @import("nested_module_tests.zig");

/// The fixture `tests/conformance/transparent-functions.forb`.
pub const contract =
    \\# RFC-0085, I7: a transparent function takes its result type from its body.
    \\Next<public>(X:i64)<computes> := X + 1
    \\Label(N:i64)<computes> := "n = {N}"
    \\Positive(X:i64)<computes><decides> := Block{ Require[X > 0]; X }
    \\Pair(X:i64)<computes> := tuple{Next(X), Label(X)}
    \\Scaled(Xs:[]i64, K:i64)<computes> := For(X:Xs, X * K)
    \\var Total:i64 = 0
    \\Add(N:i64)<transacts> := Block{ set Total += N; Total }
    \\Describe(X:i64)<computes> := X * 10
    \\Describe(X:string)<computes> := "<{X}>"
    \\(X:i64).Squared()<computes> := X * X
    \\Adder(K:i64)<computes> := Fn(X:i64){ X + K }
    \\point := struct{ X:i64 = 0, Y:i64 = 0 }
    \\Origin(D:i64)<computes> := point{ X := D, Y := -D }
    \\# `<constructor>` keeps its meaning: a constructor function, not a transparent one.
    \\counter := class{ Start:i64 = 0 }
    \\MakeCounter<constructor>(S:i64)<allocates> := counter{ Start := S }
    \\A<public>:i64 = Next(41)
    \\B:string = Label(3)
    \\C:tuple(i64, i64) = tuple{Attempt(Positive[5], 0), Attempt(Positive[-5], 0)}
    \\D:tuple(i64, string) = Pair(1)
    \\E:[]i64 = Scaled(array{1, 2, 3}, 4)
    \\F:tuple(i64, i64) = tuple{Add(2), Add(5)}
    \\G:tuple(i64, string) = tuple{Describe(4), Describe("x")}
    \\H:i64 = (7).Squared()
    \\Inc:function<computes>(tuple(i64), i64) = Adder(3)
    \\I:i64 = Inc(4)
    \\Through:function<computes>(tuple(i64), i64) = Next
    \\J:i64 = Through(9)
    \\K:point = Origin(2)
    \\L:i64 = MakeCounter(6).Start
;

fn report(execution: evaluator.Execution, buffer: []u8) ![]const u8 {
    return live.report(execution, buffer);
}

fn functionNamed(p: types.Program, name: []const u8) ?types.RuntimeFunction {
    for (p.functions) |f| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return f;
    return null;
}

test "transparent functions: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    // Next(41) = 42; Positive fails for -5, so its Attempt yields 0; Pair(1) = (Next(1), Label(1));
    // Add writes Total twice: 2, then 7; Describe takes the overload of its argument's type.
    try std.testing.expectEqualStrings(
        "{\"Total\":7,\"A\":42,\"B\":\"n = 3\",\"C\":[5,0],\"D\":[2,\"n = 1\"],\"E\":[4,8,12],\"F\":[2,7],\"G\":[40,\"<x>\"],\"H\":49,\"Inc\":{\"function\":{\"name\":\"Fn\",\"module\":null,\"anonymous\":" ++ "533" ++ ",\"captures\":[3]}},\"I\":7,\"Through\":{\"function\":{\"name\":\"Next\",\"module\":null}},\"J\":10,\"K\":{\"X\":2,\"Y\":-2},\"L\":6}\n",
        try report(x, &buffer),
    );
    try live.expectEveryMode(contract);
}

test "transparent functions: the inferred result types, the flag on each entry, and constructors unchanged" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(contract);
    const expected = [_]struct { []const u8, ?types.Type }{
        .{ "Next", .i64 },   .{ "Label", .string }, .{ "Positive", .i64 }, .{ "Pair", null },
        .{ "Scaled", null }, .{ "Add", .i64 },      .{ "Squared", .i64 },  .{ "Adder", null },
        .{ "Origin", null },
    };
    for (expected) |entry| {
        const f = functionNamed(p, entry[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expect(f.transparent);
        if (entry[1]) |t| try std.testing.expectEqual(t, f.value_type);
    }
    // The result of `Pair` is the tuple its body builds, of `Scaled` the array of the loop.
    const pair = functionNamed(p, "Pair").?;
    const tuple = @import("aggregate_types.zig").definition(pair.value_type, p.definitions).?;
    try std.testing.expect(tuple == .tuple);
    try std.testing.expectEqualSlices(types.Type, &.{ .i64, .string }, p.tuple_elements[tuple.tuple.start..tuple.tuple.end]);
    try std.testing.expect(@import("aggregate_types.zig").definition(functionNamed(p, "Scaled").?.value_type, p.definitions).? == .array);
    // Both overloads of `Describe` are transparent, each of its own type.
    var describes: usize = 0;
    for (p.functions) |f| if (std.mem.eql(u8, f.name.text(p.source), "Describe")) {
        try std.testing.expect(f.transparent);
        describes += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), describes);
    // The constructor function and the anonymous functions are not transparent.
    try std.testing.expect(!functionNamed(p, "MakeCounter").?.transparent);
    for (p.functions) |f| if (f.anonymous) try std.testing.expect(!f.transparent);
    // The same functions with written result types compile to the same code, but for the flag.
    const written = try h.compile(
        \\Next<public>(X:i64)<computes>:i64 = X + 1
        \\Label(N:i64)<computes>:string = "n = {N}"
        \\A<public>:i64 = Next(41)
        \\B:string = Label(3)
    );
    const inferred = try h.compile(
        \\Next<public>(X:i64)<computes> := X + 1
        \\Label(N:i64)<computes> := "n = {N}"
        \\A<public>:i64 = Next(41)
        \\B:string = Label(3)
    );
    try std.testing.expectEqual(written.functions.len, inferred.functions.len);
    for (written.functions, inferred.functions) |a, b| {
        var flagged = a;
        flagged.transparent = true;
        try std.testing.expectEqualDeep(flagged, b);
    }
    try std.testing.expectEqual(written.function_nodes.len, inferred.function_nodes.len);
    for (written.function_nodes, inferred.function_nodes) |a, b| {
        try std.testing.expectEqual(a.input, b.input);
        try std.testing.expectEqual(a.node.value_type, b.node.value_type);
        try std.testing.expectEqual(std.meta.activeTag(a.node.kind), std.meta.activeTag(b.node.kind));
    }
    // A program without the form has no flag set.
    const plain = try h.compile("F(X:i64)<computes>:i64 = X + 1\nA:i64 = F(1)");
    for (plain.functions) |f| try std.testing.expect(!f.transparent);
}

test "transparent functions: every diagnostic, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // The body cannot name the function, called or as a value, nor `Return`: its type is the
    // body's, not known yet.
    try live.expectRefused(h, "Count(N:i64)<computes> := If(N > 0, Count(N - 1) + 1, 0)", .transparent_recursion, "Count");
    try live.expectRefused(h, "Me(N:i64)<computes> := Block{ G := Me; N }", .transparent_recursion, "Me");
    // An extension method calls itself on its receiver (review of f85a: the call was typed
    // with the placeholder, and admission refused the program).
    try live.expectRefused(h, "(X:i64).Label()<computes> := Block{ Y:i64 = If(X > 0, (X - 1).Label(), 0); \"s\" }\nA:string = (2).Label()", .transparent_recursion, "Label");
    try live.expectRefused(h, "(X:i64).Down()<computes> := If(X > 0, (X - 1).Down(), 7)", .transparent_recursion, "Down");
    try live.expectRefused(h, "F(X:i64)<computes> := If(X > 0, Return(1), 2)", .return_type_required, "Return");
    // From a loop, at the loop that carries the `Return` out (RFC-0068).
    try live.expectRefused(h, "F(Xs:[]i64)<computes> := For(X:Xs, If(X > 1, Return(array{}), X))", .return_type_required, "For");
    // An `Fn` inside with its own result type may `Return` from itself.
    const x = try live.run(h, "F(X:i64)<computes> := Block{ G := Fn(Y:i64):i64{ If(Y > 0, Return(Y), 0) }; G(X) }\nA:i64 = F(3)");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    // Methods of classes and interfaces, generic functions and generic methods (V11).
    try live.expectRefused(h, "c := class{ M()<computes> := 1 }", .transparent_method, "M");
    try live.expectRefused(h, "i := interface{ M()<computes> := 1 }", .transparent_method, "M");
    try live.expectRefused(h, "Id[T:type](X:T)<computes> := X", .transparent_generic, "Id");
    try live.expectRefused(h, "c := class{ Get[T:type](X:T)<computes> := X }", .transparent_method, "Get");
    // The effect is mandatory (V10): nothing is inferred, `<decides>` alone is no heap effect.
    try live.expectRefused(h, "F(X:i64) := X + 1", .expected_computes, ":");
    try live.expectRefused(h, "F(X:i64)<decides> := X", .expected_computes, "decides");
    // The body's effects are checked against the written ones, and a contextless literal keeps
    // its diagnostic.
    try live.expectRefused(h, "var V:i64 = 0\nF()<computes> := V", .variable_read_requires_reads, "V");
    try live.expectRefused(h, "F()<computes> := array{}", .array_type_required, "array");
    // Two definitions of one parameter type stay a duplicate.
    try live.expectRefused(h, "F(X:i64)<computes> := X\nF(Y:i64)<computes> := Y + 1", .duplicate_name, "F");
}

test "transparent functions: a public one exports its inferred type, which may not be private" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nA<public>:i64=Kit.Next(1)\nB<public>:i64=Kit.Inner.Twice(4)\n" },
        .{ .path = "kit.forb", .source = "Next<public>(X:i64)<computes> := X + 1\nInner<public>:=module{\n  Twice<public>(X:i64)<computes> := X * 2\n}\n" },
    });
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("B").?.integer);
    for ([_][]const u8{
        "p:=struct{X:i64=1}\nMake<public>()<computes> := p{}\n",
        "M<public>:=module{\n p:=struct{X:i64=1}\n Make<public>()<computes> := p{}\n}\n",
    }) |kit| {
        const problem = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{
            .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nA<public>:i64=1\n" },
            .{ .path = "kit.forb", .source = kit },
        } })) {
            .ok => return error.TestUnexpectedResult,
            .failed => |problem| problem,
        };
        try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, problem.diagnostic.code);
        try std.testing.expectEqualStrings("Make", problem.diagnostic.span.text(problem.source));
    }
}

test "transparent functions: the flag is metadata, admitted either way by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(contract);
    const ran = (try h.run(p, live.fuel)).ok;
    var buffer: [4096]u8 = undefined;
    const expected = try std.testing.allocator.dupe(u8, try report(ran, &buffer));
    defer std.testing.allocator.free(expected);
    const functions = try std.testing.allocator.dupe(types.RuntimeFunction, p.functions);
    defer std.testing.allocator.free(functions);
    var forged = p;
    forged.functions = functions;
    // Every entry flipped: the transparent ones cleared, every other one set. The harness runs
    // both machines and replays the report of each, which admits the program again.
    for (functions) |*f| f.transparent = !f.transparent;
    const again = (try h.run(forged, live.fuel)).ok;
    try std.testing.expectEqualStrings(expected, try report(again, &buffer));
    _ = try reporting.validate(again, false, .{});
}

test "transparent functions: inspection format 30 lists them; a program without one keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const report_space = try scratch.storage(inspection.Workspace);
    defer scratch.release(report_space);
    const out_buffer = try std.testing.allocator.alloc(u8, 1 << 18);
    defer std.testing.allocator.free(out_buffer);
    var out = std.Io.Writer.fixed(out_buffer);
    const p = try h.compile("Next(X:i64)<computes> := X + 1\nTwice(X:i64)<computes>:i64 = X * 2\nA:i64 = Next(Twice(1))");
    try std.testing.expect(try report_space.write(&out, p) == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 30), parsed.value.object.get("format").?.integer);
    const listed = parsed.value.object.get("function_transparent").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("Next", p.functions[@intCast(listed[0].integer)].name.text(p.source));
    out.end = 0;
    const plain = try h.compile("Next(X:i64)<computes>:i64 = X + 1\nTwice(X:i64)<computes>:i64 = X * 2\nA:i64 = Next(Twice(1))");
    try std.testing.expect(try report_space.write(&out, plain) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":10,"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "function_transparent") == null);
}
