//! Overloads, defaults and named parameters of nested functions (RFC-0085, I4, S7, V8): the
//! rules of top-level functions (RFC-0058, RFC-0061, RFC-0076), with RFC-0061's tests rerun on
//! nested functions. Several nested functions of one block share a name when their parameter
//! types differ, and a call chooses by the argument types; a parameter may have a default,
//! read as a top-level function's is (literals, module declarations, the parameters before it),
//! and a direct call names parameters. No IR is new: a call is the `call` of the chosen entry
//! with its captures, the arguments in parameter order and the defaults expanded where it stands.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");

const allocator = std.testing.allocator;

/// The fixture `tests/conformance/nested-overloads.forb`.
pub const contract =
    \\# RFC-0085, I4: overloads, defaults and named parameters of nested functions, as top-level
    \\# functions have them (RFC-0058, RFC-0061).
    \\# Book example 53 (06:1128): overloaded, chosen by the argument's type.
    \\Process(X:i64)<computes>:string = Block{
    \\    Format(Value:i64)<computes>:string = "int: {Value}"
    \\    Format(Value:string)<computes>:string = "string: {Value}"
    \\    "{Format(X)}, {Format("x")}"
    \\}
    \\# Overloads by number and by type, each capturing what its body names, one of them a value
    \\# chosen by the expected function type.
    \\Measure(N:i64, Unit:string)<computes>:tuple(string, i64, float, i64) = Block{
    \\    Describe(X:i64)<computes>:string = "{X} {Unit}"
    \\    Describe(X:i64, Y:i64)<computes>:string = "{X + Y + N} {Unit}"
    \\    Twice(X:i64)<computes>:i64 = X * 2 + N
    \\    Twice(X:float)<computes>:float = X * 2.0
    \\    Apply:function(tuple(i64), i64) = Twice
    \\    tuple{Describe(Describe(1, 2).Length), Apply(4), Twice(1.5), Twice(3)}
    \\}
    \\# Defaults that read the parameters before them, and named arguments in any order.
    \\Box(Scale:i64)<computes>:tuple(i64, i64, i64, string) = Block{
    \\    Area(W:i64, H:i64 = W, Depth:i64 = W + H)<computes>:i64 = W * H * Depth * Scale
    \\    Show(A:i64, B:i64 = 10, C:string = "x")<computes>:string = "{A} {B} {C}"
    \\    tuple{Area(2), Area(2, 3), Area(Depth := 1, W := 2), "{Show(1)} / {Show(1, C := "z")} / {Show(C := "q", A := 9, B := 8)}"}
    \\}
    \\# A default is evaluated at each call, after the arguments, each argument once.
    \\var Calls:i64 = 0
    \\Next()<transacts>:i64 = Block{ set Calls += 1; Calls }
    \\Stamp()<transacts>:tuple(i64, i64) = Block{
    \\    Pair(A:i64, B:i64 = A * 10)<computes>:i64 = A + B
    \\    One := Pair(Next())
    \\    tuple{One, Pair(Next(), B := Calls)}
    \\}
    \\V1:string = Process(7)
    \\V2:tuple(string, i64, float, i64) = Measure(100, "cm")
    \\V3:tuple(i64, i64, i64, string) = Box(1)
    \\V4:tuple(i64, i64) = Stamp()
    \\V5:i64 = Calls
    \\
;

fn expectInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const x = try live.run(h, source);
    const value = x.get(name) orelse return error.MissingBinding;
    if (value.integer != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, value.integer, expected, source });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectString(h: *harness.Harness, source: []const u8, name: []const u8, expected: []const u8) !void {
    const x = try live.run(h, source);
    const value = x.get(name) orelse return error.MissingBinding;
    try std.testing.expectEqualStrings(expected, value.string);
}

const refused = live.expectRefused;

test "nested overloads: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    // Describe(1, 2) is "103 cm", six long; 4 * 2 + 100; 1.5 * 2.0; 3 * 2 + 100. Areas 2*2*4,
    // 2*3*5, 2*2*1. Pair(1) = 1 + 10, then Pair(2, B := 2) = 4: Calls is read after Next().
    try std.testing.expectEqualStrings(
        \\{"Calls":2,"V1":"int: 7, string: x","V2":["6 cm",108,3,106],"V3":[16,30,4,"1 10 x / 1 10 z / 9 8 q"],"V4":[11,4],"V5":2}
    ++ "\n", try live.report(x, &buffer));
    try live.expectEveryMode(contract);
}

test "nested overloads: Book example 53, which I3 refused, now chooses by the argument's type" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectString(h, "Process(X:i64)<computes>:string = Block{\n    Format(Value:i64)<computes>:string = \"int: {Value}\"\n    Format(Value:string)<computes>:string = \"string: {Value}\"\n    \"{Format(42)}, {Format(\"x\")}\"\n}\nV:string = Process(1)", "V", "int: 42, string: x");
}

// ---- RFC-0061's overload tests (`overload_tests.zig`), rerun on nested functions.

test "nested overloads are chosen by the types and number of the arguments" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\Run()<computes>:tuple(string, string, string, string, i64, i64, i64, logic, string) = Block{
        \\    Describe(X:i64)<computes>:string = "int " + ToString(X)
        \\    Describe(X:string)<computes>:string = "str " + X
        \\    Describe(X:i64, Y:i64)<computes>:string = "pair " + ToString(X + Y)
        \\    Describe(B:logic)<computes>:string = If(B, "yes", "no")
        \\    Pick(Xs:[]i64)<computes>:i64 = Xs.Length
        \\    Pick(Xs:[]string)<computes>:i64 = Xs.Length * 10
        \\    Twice(X:i64)<computes>:i64 = X * 2
        \\    Twice(X:float)<computes>:float = X * 2.0
        \\    Names:[]string = array{"a", "b"}
        \\    tuple{Describe(5), Describe("x"), Describe(1, 2), Describe(true), Pick(array{1, 2}), Pick(Names), Twice(3), Twice(1.5) == 3.0, Describe(Twice(4))}
        \\}
        \\V:tuple(string, string, string, string, i64, i64, i64, logic, string) = Run()
    );
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("{\"V\":[\"int 5\",\"str x\",\"pair 3\",\"yes\",2,20,6,true,\"int 8\"]}\n", try live.report(x, &buffer));
}

test "nested overloads keep their own effects and may recurse" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var Count:i64 = 0
        \\Run()<transacts>:tuple(i64, i64, i64, i64, i64, string, i64) = Block{
        \\    Bump(N:i64)<transacts>:i64 = Block{ set Count = Count + N; Count }
        \\    Bump(S:string)<transacts>:i64 = Block{ set Count = Count + S.Length; Count }
        \\    Fact(N:i64)<computes>:i64 = If(N <= 1, 1, N * Fact(N - 1))
        \\    Fact(S:string)<computes>:i64 = S.Length
        \\    First(Xs:[]i64)<computes><decides>:i64 = Xs[0]
        \\    First(Xs:[]string)<computes><decides>:string = Xs[0]
        \\    Empty:[]i64 = array{}
        \\    A := Bump(5)
        \\    B := Bump("abc")
        \\    tuple{A, B, Fact(5), Fact("four"), Attempt(First[array{7, 8}], -1), Attempt(First[array{"x"}], "-"), Attempt(First[Empty], -1)}
        \\}
        \\V:tuple(i64, i64, i64, i64, i64, string, i64) = Run()
    );
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("{\"Count\":8,\"V\":[5,8,120,4,7,\"x\",-1]}\n", try live.report(x, &buffer));
    // The effect checked is the chosen overload's: a `<computes>` caller may call the
    // `<computes>` one and not the `<transacts>` one.
    try expectInt(h, "Run()<computes>:i64 = Block{ G(X:i64)<computes>:i64 = X; G(S:string)<transacts>:i64 = S.Length; G(4) }\nV:i64 = Run()", "V", 4);
    try refused(h, "Run()<computes>:i64 = Block{ G(X:i64)<computes>:i64 = X; G(S:string)<transacts>:i64 = S.Length; G(\"ab\") }\nV:i64 = Run()", .call_requires_transacts, "G");
}

test "a nested overloaded name used as a value is chosen by the expected function type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\Use(F:function(tuple(float), float), V:float)<computes>:float = F(V)
        \\Run(N:i64)<computes>:tuple(i64, float, float) = Block{
        \\    Twice(X:i64)<computes>:i64 = X * 2 + N
        \\    Twice(X:float)<computes>:float = X * 2.0
        \\    ApplyInt:function(tuple(i64), i64) = Twice
        \\    ApplyFloat:function(tuple(float), float) = Twice
        \\    tuple{ApplyInt(21), ApplyFloat(1.25), Use(Twice, 2.0)}
        \\}
        \\V:tuple(i64, float, float) = Run(0)
    );
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("{\"V\":[42,2.5,4]}\n", try live.report(x, &buffer));
}

test "nested overload misuse reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code, []const u8 };
    const prelude = "Run()<computes>:i64 = Block{\n    F(X:i64)<computes>:i64 = X\n    F(X:string)<computes>:i64 = X.Length\n    F(X:i64, Y:i64)<computes>:i64 = X + Y\n";
    for ([_]Case{
        .{ "Run()<computes>:i64 = Block{\n    F(X:i64)<computes>:i64 = X\n    F(Y:i64)<computes>:i64 = Y\n    0\n}", .duplicate_name, "F" },
        .{ "Run()<computes>:i64 = Block{\n    F(X:i64)<computes>:i64 = X\n    F(X:string)<computes><decides>:i64 = X.Length\n    0\n}", .overload_conflict, "F" },
        .{ "base := class{}\nderived := class(base){}\nRun()<computes>:i64 = Block{\n    F(X:base)<computes>:i64 = 1\n    F(X:derived)<computes>:i64 = 2\n    0\n}", .related_overloads, "F" },
        .{ prelude ++ "    F(true)\n}", .type_mismatch, "F" },
        // Too many arguments for any overload: refused at the comma, as a top-level call is.
        .{ prelude ++ "    F(1, 2, 3)\n}", .argument_count, "," },
        .{ prelude ++ "    F()\n}", .argument_count, "F" },
        .{ prelude ++ "    F(X := 1)\n}", .named_argument_order, "F" },
        .{ prelude ++ "    W := F\n    0\n}", .ambiguous_call, "F" },
        .{ prelude ++ "    W:function(tuple(float), float) = F\n    0\n}", .ambiguous_call, "F" },
        // A local of the name, and a nested function of it in an inner block, still shadow.
        .{ prelude ++ "    F := 1\n    0\n}", .shadowed_name, "F" },
        .{ prelude ++ "    Block{ F(X:float)<computes>:i64 = 1; 0 }\n}", .shadowed_name, "F" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator, "{s}\nV:i64 = Run()", .{case[0]});
        defer allocator.free(source);
        try refused(h, source, case[1], case[2]);
        _ = try h.execute("A:i64=42");
    }
}

test "forged nested overloads with one name span are refused by independent admission" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Run()<computes>:tuple(i64, float) = Block{ Twice(X:i64)<computes>:i64 = X * 2; Twice(X:float)<computes>:float = X * 2.0; tuple{Twice(1), Twice(1.0)} }\nV:tuple(i64, float) = Run()");
    _ = (try h.run(p, live.fuel)).ok;
    var first: ?usize = null;
    var second: ?usize = null;
    for (p.functions, 0..) |f, index| if (f.nested) {
        if (first == null) first = index else second = index;
    };
    const functions = try allocator.dupe(types.RuntimeFunction, p.functions);
    defer allocator.free(functions);
    var forged = p;
    forged.functions = functions;
    // Two overloads are two declarations; one declaration copied would be two entries of one name.
    functions[second.?].name = functions[first.?].name;
    try harness.invalid(h, forged);
}

// ---- Defaults and named arguments (RFC-0058, RFC-0076) on nested functions.

test "nested defaults and named arguments: positional, named in any order, defaults reading the parameters before them" {
    const h = try harness.create();
    defer scratch.release(h);
    const show = "Run()<computes>:string = Block{\n    Show(A:i64, B:i64 = 10, C:string = \"x\")<computes>:string = \"{A} {B} {C}\"\n    ";
    try expectString(h, show ++ "Show(1)\n}\nV:string = Run()", "V", "1 10 x");
    try expectString(h, show ++ "Show(1, 2, \"y\")\n}\nV:string = Run()", "V", "1 2 y");
    try expectString(h, show ++ "Show(1, C := \"z\")\n}\nV:string = Run()", "V", "1 10 z");
    try expectString(h, show ++ "Show(C := \"q\", A := 9, B := 8)\n}\nV:string = Run()", "V", "9 8 q");
    const area = "Run()<computes>:i64 = Block{\n    Area(W:i64, H:i64 = W, Depth:i64 = W + H)<computes>:i64 = W * 100 + H * 10 + Depth\n    ";
    try expectInt(h, area ++ "Area(2)\n}\nV:i64 = Run()", "V", 224);
    try expectInt(h, area ++ "Area(2, 3)\n}\nV:i64 = Run()", "V", 235);
    try expectInt(h, area ++ "Area(H := 1, W := 3)\n}\nV:i64 = Run()", "V", 314);
    // A required parameter after a defaulted one is named.
    try expectInt(h, "Run()<computes>:i64 = Block{\n    G(A:i64 = 1, B:i64)<computes>:i64 = A * 10 + B\n    G(B := 2)\n}\nV:i64 = Run()", "V", 12);
    // A default reads literals, module declarations and functions, as a top-level one does.
    try expectInt(h, "Base:i64 = 7\nPlus(X:i64)<computes>:i64 = X + 1\nRun()<computes>:i64 = Block{\n    G(A:i64 = Plus(Base) * 2)<computes>:i64 = A\n    G()\n}\nV:i64 = Run()", "V", 16);
    // An array literal, and a block, as defaults.
    try expectInt(h, "Run()<computes>:i64 = Block{\n    G(Xs:[]i64 = array{1, 2, 3}, K:i64 = Block{ A := 2; A * 3 })<computes>:i64 = Xs.Length * K\n    G()\n}\nV:i64 = Run()", "V", 18);
}

test "nested defaults and named arguments with captures, cells, closures, values and recursion" {
    const h = try harness.create();
    defer scratch.release(h);
    // The captures come first; the arguments and defaults follow, by the declared parameters.
    try expectInt(h, "Run(N:i64)<computes>:i64 = Block{\n    G(X:i64, Y:i64 = 5)<computes>:i64 = X * 100 + Y * 10 + N\n    G(1) * 1000 + G(Y := 1, X := 2)\n}\nV:i64 = Run(3)", "V", 153213);
    // Through a cell that the nested function shares.
    try expectInt(h, "Run()<transacts>:i64 = Block{\n    var Total:i64 = 0\n    Add(X:i64 = 1)<transacts>:void = Set(Total, Total + X)\n    Add()\n    Add(X := 10)\n    Add(100)\n    Total\n}\nV:i64 = Run()", "V", 111);
    // An `Fn` and a loop's body that call one with a default carry its captures.
    try expectInt(h, "Run(N:i64)<computes>:i64 = Block{\n    G(X:i64, Y:i64 = 1)<computes>:i64 = X + Y + N\n    H := Fn(K:i64)<computes>:i64{ G(K) }\n    S := For(I:1..3, G(I, 0))\n    H(1) + S.Length\n}\nV:i64 = Run(10)", "V", 15);
    // Its value has every declared parameter: a function type records no default.
    try expectInt(h, "Run()<computes>:i64 = Block{\n    G(X:i64, Y:i64 = 5)<computes>:i64 = X + Y\n    F:function(tuple(i64, i64), i64) = G\n    F(1, 2)\n}\nV:i64 = Run()", "V", 3);
    // A call of itself passes every argument, as a top-level function's does.
    try expectInt(h, "Run()<computes>:i64 = Block{\n    Fact(K:i64, Acc:i64 = 1)<computes>:i64 = If(K <= 1, Acc, Fact(K - 1, Acc * K))\n    Fact(5)\n}\nV:i64 = Run()", "V", 120);
    try refused(h, "Run()<computes>:i64 = Block{\n    Fact(K:i64, Acc:i64 = 1)<computes>:i64 = If(K <= 1, Acc, Fact(K - 1))\n    Fact(5)\n}\nV:i64 = Run()", .argument_count, "Fact");
    // A nested function in a method, with a default.
    try expectInt(h, "point := class{ X:i64 = 4; Scaled(K:i64)<reads>:i64 = Block{ Mul(A:i64, B:i64 = 2)<reads>:i64 = A * B * Self.X; Mul(K) + Mul(K, B := 1) } }\nV:i64 = point{}.Scaled(3)", "V", 36);
    // In a generic function, compiled for each specialization.
    const generic = "Pick[t:type](X:t, Y:t)<computes>:t{Block{ Choose(A:t, Front:logic = true)<computes>:t = If(Front, A, Y); Choose(X) + Choose(Y, Front := false) }}\nA:i64 = Pick[i64](1, 2)\nB:string = Pick[string](\"a\", \"b\")\nV:i64 = A";
    try expectInt(h, generic, "V", 3);
    try expectString(h, generic, "B", "ab");
    // Overloads, each with defaults of its own arity: a call names every argument, as for
    // top-level overloads, and an overloaded call takes no named argument.
    try expectInt(h, "Run()<computes>:i64 = Block{\n    F(X:i64, Y:i64 = 1)<computes>:i64 = X + Y\n    F(S:string)<computes>:i64 = S.Length\n    F(2, 3) + F(\"ab\")\n}\nV:i64 = Run()", "V", 7);
    try refused(h, "Run()<computes>:i64 = Block{\n    F(X:i64, Y:i64 = 1)<computes>:i64 = X + Y\n    F(S:string)<computes>:i64 = S.Length\n    F(2)\n}\nV:i64 = Run()", .type_mismatch, "F");
}

test "an Fn that names an overloaded nested function carries the captures of every overload" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(h,
        \\Run(A:i64, B:i64)<computes>:i64 = Block{
        \\    F(X:i64)<computes>:i64 = X + A
        \\    F(S:string)<computes>:i64 = S.Length * B
        \\    H := Fn(K:i64)<computes>:i64{ F(K) + F("abc") }
        \\    H(1)
        \\}
        \\V:i64 = Run(10, 100)
    , "V", 311);
}

test "nested defaults and named arguments report exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code, []const u8 };
    const show = "Run(N:i64)<computes>:string = Block{\n    Show(A:i64, B:i64 = 10, C:string = \"x\")<computes>:string = \"{A} {B} {C}\"\n    ";
    for ([_]Case{
        .{ show ++ "Show(1, D := 2)\n}", .unknown_parameter, "D" },
        .{ show ++ "Show(1, A := 2)\n}", .duplicate_argument, "A" },
        .{ show ++ "Show(1, B := 2, B := 3)\n}", .duplicate_argument, "B" },
        .{ show ++ "Show(B := 2, 1)\n}", .named_argument_order, "1" },
        .{ show ++ "Show(1, 2, \"y\", 4)\n}", .argument_count, "," },
        .{ show ++ "Show()\n}", .argument_count, "Show" },
        .{ show ++ "Show(\"one\")\n}", .type_mismatch, "\"one\"" },
        .{ "Run(N:i64)<computes>:string = Block{\n    Show(A:i64 = \"one\")<computes>:string = \"{A}\"\n    Show()\n}", .type_mismatch, "\"one\"" },
        // A default reads nothing of the code around its block.
        .{ "Run(N:i64)<computes>:string = Block{\n    Show(A:i64 = N)<computes>:string = \"{A}\"\n    Show()\n}", .nested_default, "N" },
        .{ "Run(N:i64)<computes>:string = Block{\n    L := 4\n    Show(A:i64 = L + 1)<computes>:string = \"{A}\"\n    Show()\n}", .nested_default, "L" },
        .{ "Run(N:i64)<computes>:string = Block{\n    G()<computes>:i64 = 1\n    Show(A:i64 = G())<computes>:string = \"{A}\"\n    Show()\n}", .nested_default, "G" },
        .{ "Run(N:i64)<computes>:string = Block{\n    Show(A:i64 = Show(1).Length)<computes>:string = \"{A}\"\n    Show()\n}", .nested_default, "Show" },
        .{ "item := class{ X:i64 = 1; Run()<reads>:string = Block{ Show(A:i64 = Self.X)<computes>:string = \"{A}\"; Show() } }\nW:string = item{}.Run()\nRun(N:i64)<computes>:string = \"\"", .nested_default, "Self" },
        // Nor a parameter after it.
        .{ "Run(N:i64)<computes>:string = Block{\n    Show(A:i64 = B, B:i64 = 1)<computes>:string = \"{A}\"\n    Show()\n}", .unknown_name, "B" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator, "{s}\nV:string = Run(1)", .{case[0]});
        defer allocator.free(source);
        try refused(h, source, case[1], case[2]);
        _ = try h.execute("A:i64=42");
    }
}

test "a default after a Defer is no exit of the code around it, and a body after one is its own (review)" {
    const h = try harness.create();
    defer scratch.release(h);
    // The `Return` of a default is no exit of `F` that would run the `Defer`'s copy: a default
    // reads as a top-level one does, where no function encloses it.
    try refused(h, "var Log:i64 = 0\nF()<transacts>:i64 = Block{\n    Defer{ set Log += 1 }\n    G(X:i64 = Block{ Return(9) })<computes>:i64 = X\n    G()\n}\nV:i64 = F()", .return_outside_function, "Return");
    try expectInt(h, "var Log:i64 = 0\nF()<transacts>:i64 = Block{\n    Defer{ set Log += 1 }\n    G(X:i64 = 4)<computes>:i64 = Block{ If(X > 3, Return(X * 10), 0); X }\n    G() + G(1)\n}\nV:i64 = F()\nW:i64 = Log", "V", 41);
    try expectInt(h, "var Log:i64 = 0\nF()<transacts>:i64 = Block{\n    Defer{ set Log += 1 }\n    G(X:i64 = 4)<computes>:i64 = X\n    G()\n}\nV:i64 = F()\nW:i64 = Log", "W", 1);
}

test "nested functions: a call of one calling itself reads its arguments by the declared parameters" {
    const h = try harness.create();
    defer scratch.release(h);
    // The capture `Tag` is a string; the argument `array{}` takes the parameter's type.
    try expectInt(h, "Run(Tag:string)<computes>:i64 = Block{\n    Count(Xs:[]i64, K:i64)<computes>:i64 = If(K <= 0, Xs.Length + Tag.Length, Count(array{}, K - 1))\n    Count(array{1}, 2)\n}\nV:i64 = Run(\"ab\")", "V", 2);
}

const Shape = struct { kinds: [64]std.meta.Tag(@FieldType(types.Node, "kind")) = undefined, count: usize = 0, functions: usize = 0, roots: usize = 0 };

fn shape(p: types.Program) !Shape {
    var result: Shape = .{ .functions = p.functions.len, .roots = p.nodes.len };
    if (p.function_nodes.len > result.kinds.len) return error.TestUnexpectedResult;
    for (p.function_nodes, result.kinds[0..p.function_nodes.len]) |entry, *kind| kind.* = std.meta.activeTag(entry.node.kind);
    result.count = p.function_nodes.len;
    return result;
}

test "a nested call that leaves out a default, or names its arguments, is the call that passes them" {
    const h = try harness.create();
    defer scratch.release(h);
    // One `call` of the entry with the arguments in parameter order, the default's value where
    // the argument would be, and no other node.
    const plain = try shape(try h.compile("Run()<computes>:i64 = Block{ G(X:i64, Y:i64)<computes>:i64 = X - Y; G(1, 5) + G(2, 6) }\nV:i64 = Run()"));
    const defaulted = try shape(try h.compile("Run()<computes>:i64 = Block{ G(X:i64, Y:i64 = 5)<computes>:i64 = X - Y; G(1) + G(Y := 6, X := 2) }\nV:i64 = Run()"));
    try std.testing.expectEqual(plain.functions, defaulted.functions);
    try std.testing.expectEqual(plain.roots, defaulted.roots);
    try std.testing.expectEqualSlices(std.meta.Tag(@FieldType(types.Node, "kind")), plain.kinds[0..plain.count], defaulted.kinds[0..defaulted.count]);
    try expectInt(h, "Run()<computes>:i64 = Block{ G(X:i64, Y:i64 = 5)<computes>:i64 = X - Y; G(1) * 10 + G(Y := 6, X := 2) }\nV:i64 = Run()", "V", -44);
}

// ---- Randomised oracles: a model of the call rules of RFC-0058 and RFC-0061, worked out in
// Zig, against both machines (`live.run` compares them and replays the report).

const weights = [_]i64{ 1, 7, 49, 343 };

// A nested function of up to four parameters whose defaults are literals or read an earlier
// parameter, called with arguments by position and then by name in a random order.
test "randomised oracle: defaults and named arguments of a nested function agree with the model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0085_0004);
    const random = prng.random();
    var text: [2048]u8 = undefined;
    var expected_text: [256]u8 = undefined;
    var named_calls: usize = 0;
    var defaults_taken: usize = 0;
    for (0..300) |_| {
        const count = 1 + random.uintLessThan(usize, 4);
        const capture = @as(i64, random.uintLessThan(u8, 10));
        // A default of parameter `i`: none, a literal, or an earlier parameter plus a literal.
        const Default = struct { kind: enum { none, literal, earlier }, value: i64, from: usize };
        var defaults: [4]Default = undefined;
        for (defaults[0..count], 0..) |*d, i| {
            const kind = random.uintLessThan(u8, 3);
            d.* = .{ .kind = if (kind == 0) .none else if (kind == 1 or i == 0) .literal else .earlier, .value = @as(i64, random.uintLessThan(u8, 20)), .from = if (i == 0) 0 else random.uintLessThan(usize, i) };
        }
        var out = std.Io.Writer.fixed(&text);
        try out.writeAll("Run(N:i64)<computes>:tuple(i64, i64, i64) = Block{\n    G(");
        for (defaults[0..count], 0..) |d, i| {
            if (i != 0) try out.writeAll(", ");
            try out.print("P{d}:i64", .{i});
            switch (d.kind) {
                .none => {},
                .literal => try out.print(" = {d}", .{d.value}),
                .earlier => try out.print(" = P{d} + {d}", .{ d.from, d.value }),
            }
        }
        try out.writeAll(")<computes>:i64 = N * 10000");
        for (0..count) |i| try out.print(" + P{d} * {d}", .{ i, weights[i] });
        try out.writeAll("\n    tuple{");
        var results: [3]i64 = undefined;
        for (&results, 0..) |*result, call| {
            if (call != 0) try out.writeAll(", ");
            const positional = random.uintLessThan(usize, count + 1);
            // Every required parameter past the positional ones is named; others now and then.
            var given: [4]?i64 = @splat(null);
            var order: [4]usize = undefined;
            var named: usize = 0;
            for (0..count) |i| {
                if (i < positional) {
                    given[i] = @as(i64, random.uintLessThan(u8, 30));
                } else if (defaults[i].kind == .none or random.boolean()) {
                    given[i] = @as(i64, random.uintLessThan(u8, 30));
                    order[named] = i;
                    named += 1;
                }
            }
            random.shuffle(usize, order[0..named]);
            try out.writeAll("G(");
            for (0..positional) |i| {
                if (i != 0) try out.writeAll(", ");
                try out.print("{d}", .{given[i].?});
            }
            for (order[0..named], 0..) |i, k| {
                if (positional + k != 0) try out.writeAll(", ");
                try out.print("P{d} := {d}", .{ i, given[i].? });
            }
            try out.writeAll(")");
            named_calls += @intFromBool(named != 0);
            // The model: parameters in order, each omitted one its default of those before it.
            var values: [4]i64 = undefined;
            var sum: i64 = capture * 10000;
            for (0..count) |i| {
                values[i] = given[i] orelse switch (defaults[i].kind) {
                    .none => unreachable,
                    .literal => defaults[i].value,
                    .earlier => values[defaults[i].from] + defaults[i].value,
                };
                if (given[i] == null) defaults_taken += 1;
                sum += values[i] * weights[i];
            }
            result.* = sum;
        }
        try out.print("}}\n}}\nV:tuple(i64, i64, i64) = Run({d})", .{capture});
        const source = out.buffered();
        const x = try live.run(h, source);
        var buffer: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_text, "{{\"V\":[{d},{d},{d}]}}\n", .{ results[0], results[1], results[2] });
        const actual = try live.report(x, &buffer);
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("model {s} machines {s}for\n{s}\n", .{ expected, actual, source });
            return error.ModelDisagrees;
        }
    }
    try std.testing.expect(named_calls > 200 and defaults_taken > 200);
}

// Overloads of one name by number of parameters and by the type of the first, chosen by the
// arguments of each call, and refused where two would have one signature.
test "randomised oracle: overloads of a nested function are chosen as the model chooses" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0085_0005);
    const random = prng.random();
    var text: [2048]u8 = undefined;
    var expected_text: [256]u8 = undefined;
    var refusals: usize = 0;
    for (0..300) |_| {
        // Overload `k` takes `arity` parameters, the first an i64 or a string, the rest i64.
        const Overload = struct { arity: usize, string: bool };
        var overloads: [6]Overload = undefined;
        const count = 1 + random.uintLessThan(usize, 6);
        var duplicate = false;
        for (overloads[0..count], 0..) |*o, k| {
            o.* = .{ .arity = 1 + random.uintLessThan(usize, 3), .string = random.boolean() };
            for (overloads[0..k]) |earlier| if (earlier.arity == o.arity and earlier.string == o.string) {
                duplicate = true;
            };
        }
        var out = std.Io.Writer.fixed(&text);
        try out.writeAll("Run(N:i64)<computes>:tuple(i64, i64) = Block{\n");
        for (overloads[0..count], 0..) |o, k| {
            try out.print("    F(X:{s}", .{if (o.string) "string" else "i64"});
            for (1..o.arity) |i| try out.print(", Y{d}:i64", .{i});
            try out.print(")<computes>:i64 = {d} * 1000 + N + {s}", .{ k + 1, if (o.string) "X.Length" else "X" });
            for (1..o.arity) |i| try out.print(" + Y{d} * 10", .{i});
            try out.writeAll("\n");
        }
        try out.writeAll("    tuple{");
        var results: [2]i64 = undefined;
        const n = @as(i64, random.uintLessThan(u8, 10));
        for (&results, 0..) |*result, call| {
            if (call != 0) try out.writeAll(", ");
            const o = overloads[random.uintLessThan(usize, count)];
            const first = @as(i64, random.uintLessThan(u8, 6));
            try out.writeAll("F(");
            if (o.string) {
                try out.writeAll("\"");
                for (0..@intCast(first)) |_| try out.writeAll("s");
                try out.writeAll("\"");
            } else try out.print("{d}", .{first});
            var rest: i64 = 0;
            for (1..o.arity) |_| {
                const y = @as(i64, random.uintLessThan(u8, 9));
                try out.print(", {d}", .{y});
                rest += y * 10;
            }
            try out.writeAll(")");
            // The model: the overload declared with that number and that first type.
            const winner = for (overloads[0..count], 0..) |other, k| {
                if (other.arity == o.arity and other.string == o.string) break k;
            } else unreachable;
            result.* = @as(i64, @intCast(winner + 1)) * 1000 + n + first + rest;
        }
        try out.print("}}\n}}\nV:tuple(i64, i64) = Run({d})", .{n});
        const source = out.buffered();
        if (duplicate) {
            // Two overloads with one signature: the later one is refused.
            const result = h.front.compile(source);
            try std.testing.expect(result == .failed);
            try std.testing.expectEqual(types.Diagnostic.Code.duplicate_name, result.failed.code);
            refusals += 1;
            continue;
        }
        const x = try live.run(h, source);
        var buffer: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_text, "{{\"V\":[{d},{d}]}}\n", .{ results[0], results[1] });
        const actual = try live.report(x, &buffer);
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("model {s} machines {s}for\n{s}\n", .{ expected, actual, source });
            return error.ModelDisagrees;
        }
    }
    try std.testing.expect(refusals > 30 and refusals < 270);
}

const compiler = @import("compiler.zig");

test "automatic qualification notes the overload each use of a nested function chooses (RFC-0085, I11)" {
    const QualifyHarness = struct { compiler: compiler.Workspace, written: [types.limits.modules]types.Span };
    const q = try scratch.storage(QualifyHarness);
    defer scratch.release(q);
    scratch.initialise(q);
    q.compiler.qualify = true;
    const program = switch (q.compiler.compile(contract)) {
        .ok => |p| p,
        .failed => |d| {
            std.debug.print("{t}\n", .{d.code});
            return error.TestUnexpectedResult;
        },
    };
    const text = q.compiler.qualification(program, &q.written);
    try std.testing.expectEqual(@as(u32, 0), q.compiler.resolution_conflicts);
    if (q.compiler.verifyQualification(program, text)) |problem| {
        std.debug.print("`{s}` at {d}: {s}\n", .{ text.name(problem.at), problem.at, problem.reason });
        return error.TestUnexpectedResult;
    }
    // Each use means the declaration its arguments, or its expected type, choose.
    const Use = struct { use: []const u8, declaration: []const u8 };
    for ([_]Use{
        .{ .use = "Twice(1.5)", .declaration = "Twice(X:float)" },
        .{ .use = "Twice(3)", .declaration = "Twice(X:i64)" },
        .{ .use = "Twice\n", .declaration = "Twice(X:i64)" },
        .{ .use = "Format(\"x\")", .declaration = "Format(Value:string)" },
        .{ .use = "Describe(1, 2)", .declaration = "Describe(X:i64, Y:i64)" },
    }) |entry| {
        const at: u32 = @intCast(std.mem.indexOf(u8, contract, entry.use).?);
        const declared: u32 = @intCast(std.mem.indexOf(u8, contract, entry.declaration).?);
        const found = text.find(at) orelse {
            std.debug.print("no entry at `{s}`\n", .{entry.use});
            return error.TestUnexpectedResult;
        };
        if (found.declared != declared) std.debug.print("`{s}` means {d}, not {d}\n", .{ entry.use, found.declared, declared });
        try std.testing.expectEqual(declared, found.declared);
    }
}
