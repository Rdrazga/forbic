//! Nested functions (RFC-0085, I3, S7): `Name(P)<effects>:R = Body` as a statement of a
//! `Block{}`. Its body is a code entry of its own, anonymous and flagged `nested`, published
//! before the code around it; its name means it from the next statement to the end of the
//! block: a direct call is a `call` of the entry with its captures first, a use as a value its
//! `function_value` bound to them, and a call in its own body a `recur`. A local `var` it names
//! is shared (S1a), and every closure that names it carries its captures.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");

const allocator = std.testing.allocator;

/// The fixture `tests/conformance/nested-functions.forb`.
pub const contract =
    \\# RFC-0085, I3: nested functions, statements of a Block{} that capture what their bodies name
    \\# (immutable locals and parameters by value, a local var by its cell), call themselves, and are
    \\# values where they are not called.
    \\# Book example 51 (06:1088): called directly.
    \\Outer(X:i64)<computes>:i64 = Block{
    \\    Inner(Y:i64)<computes>:i64 = Y * 2
    \\    Inner(X)
    \\}
    \\# Example 52 (06:1105): a value that keeps the Name it closed over.
    \\MakeGreeter(Name:string)<computes>:function(tuple(), string) = Block{
    \\    Greeting()<computes>:string = "Hello, {Name}!"
    \\    Greeting
    \\}
    \\# Example 54 (06:1153): both name Count, so Count is one cell, a new one for each call.
    \\counter := tuple(function<reads>(tuple(), i64), function<transacts>(tuple(), void))
    \\MakeCounter(Initial:i64)<transacts>:counter = Block{
    \\    var Count:i64 = Initial
    \\    GetCount()<reads>:i64 = Count
    \\    Increment()<transacts>:void = Set(Count, Count + 1)
    \\    tuple{GetCount, Increment}
    \\}
    \\# Example 56 (06:1202): declared before it is used.
    \\Defined()<computes>:i64 = Block{
    \\    G()<computes>:i64 = 42
    \\    G()
    \\}
    \\# Example 57 (06:1225): the method calls its superclass's, and the nested function uses that.
    \\base_class := class{ F(X:i64)<computes>:i64 = X }
    \\derived_class := class(base_class){
    \\    F<override>(X:i64)<computes>:i64 = Block{
    \\        Base := Super.F(X)
    \\        Plus()<computes>:i64 = Base + 1
    \\        Plus()
    \\    }
    \\}
    \\# Example 50 (06:1061) over a generic function: compiled with each specialization.
    \\Partial[a:type, b:type, c:type](F:function(tuple(a, b), c), X:a)<computes>:function(tuple(b), c){Block{
    \\    PartialFunc(Y:b)<computes>:c = F(X, Y)
    \\    PartialFunc
    \\}}
    \\Add(X:i64, Y:i64)<computes>:i64 = X + Y
    \\# Recursion, and a nested function that calls an earlier one.
    \\Fact(N:i64)<computes>:i64 = Block{
    \\    Go(K:i64, Acc:i64)<computes>:i64 = If(K <= 1, Acc, Go(K - 1, Acc * K))
    \\    Twice(K:i64)<computes>:i64 = Go(K, 1) * 2
    \\    Twice(N)
    \\}
    \\# Closures that name a nested function carry its captures: an Fn and a loop's body.
    \\Total(Xs:[]i64)<transacts>:i64 = Block{
    \\    var Sum:i64 = 0
    \\    Put(X:i64)<transacts>:void = Set(Sum, Sum + X)
    \\    Both := Fn(X:i64)<transacts>:void{ Block{ Put(X); Put(X) } }
    \\    For(X:Xs, Both(X))
    \\    Sum
    \\}
    \\# A nested function inside another, a transparent one, and an exit from one.
    \\Layers(N:i64)<computes>:i64 = Block{
    \\    Mid(K:i64)<computes>:i64 = Block{
    \\        In(J:i64)<computes>:i64 = J + K + N
    \\        In(1) * 10
    \\    }
    \\    Half(K:i64)<computes> := K / 2
    \\    Find(K:i64)<computes>:i64 = Block{ If(K > 3, Return(K * 100), 0); K }
    \\    Mid(2) + Half(9) + Find(5)
    \\}
    \\# In a method it captures Self, and a write in a region that fails is undone.
    \\account := class{
    \\    var Balance:i64 = 10
    \\    Spend(Amounts:[]i64)<transacts>:i64 = Block{
    \\        Take(K:i64)<transacts><decides>:i64 = Block{ set Self.Balance -= K; Require[Self.Balance >= 0]; K }
    \\        For(K:Amounts, Attempt(Block{ Take[K]; 1 }, 0))
    \\        Self.Balance
    \\    }
    \\}
    \\V1:i64 = Outer(5)
    \\Hello:function(tuple(), string) = MakeGreeter("Alice")
    \\V2:string = Hello()
    \\Counter:counter = MakeCounter(0)
    \\V3:i64 = Block{ Counter(1)(); Counter(1)(); Counter(0)() }
    \\Other:counter = MakeCounter(10)
    \\V4:i64 = Other(0)()
    \\V5:i64 = Defined()
    \\V6:i64 = derived_class{}.F(3)
    \\Add5:function(tuple(i64), i64) = Partial[i64, i64, i64](Add, 5)
    \\V7:i64 = Add5(3)
    \\V8:i64 = Fact(5)
    \\V9:i64 = Total(array{1, 2, 3})
    \\V10:i64 = Layers(1)
    \\V11:i64 = account{}.Spend(array{4, 8, 3})
    \\
;

fn report(execution: evaluator.Execution, buffer: []u8) ![]const u8 {
    return live.report(execution, buffer);
}

fn expectInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const x = try live.run(h, source);
    const value = x.get(name) orelse return error.MissingBinding;
    if (value.integer != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, value.integer, expected, source });
    try std.testing.expectEqual(expected, value.integer);
}

const refused = live.expectRefused;

fn entryNamed(p: types.Program, name: []const u8) ?types.RuntimeFunction {
    for (p.functions) |f| if (std.mem.eql(u8, f.name.text(p.source), name)) return f;
    return null;
}

fn refCells(p: types.Program) bool {
    for (p.definitions) |d| if (d == .ref) return true;
    return false;
}

test "nested functions: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    // Outer(5) = 10; the greeter keeps "Alice"; the first counter is incremented twice, the
    // second keeps 10 in its own cell; Super.F(3) + 1 = 4; 5 + 3 = 8; 2 * 5! = 240; each of
    // 1, 2, 3 is put twice; 40 + 4 + 500; the 8 overdraws, fails and is undone.
    try std.testing.expectEqualStrings(
        \\{"V1":10,"Hello":{"function":{"name":"Greeting","module":null,"anonymous":504,"captures":["Alice"]}},"V2":"Hello, Alice!","Counter":[{"function":{"name":"GetCount","module":null,"anonymous":823,"captures":[{"$ref":0}]}},{"function":{"name":"Increment","module":null,"anonymous":857,"captures":[{"$ref":0}]}}],"V3":2,"Other":[{"function":{"name":"GetCount","module":null,"anonymous":823,"captures":[{"$ref":1}]}},{"function":{"name":"Increment","module":null,"anonymous":857,"captures":[{"$ref":1}]}}],"V4":10,"V5":42,"V6":4,"Add5":{"function":{"name":"PartialFunc","module":null,"anonymous":1571,"specialization":[0,0,0],"captures":[{"function":{"name":"Add","module":null}},5]}},"V7":8,"V8":240,"V9":12,"V10":544,"V11":3,"$refs":[{"id":0,"value":2},{"id":1,"value":10}]}
    ++ "\n",
        try report(x, &buffer),
    );
    try live.expectEveryMode(contract);
}

test "nested functions: the Book's examples 51 to 57 in Forbic spelling" {
    const h = try harness.create();
    defer scratch.release(h);
    // 51: a direct call.
    try expectInt(h, "Outer(X:i64)<computes>:i64 = Block{\n    Inner(Y:i64)<computes>:i64 = Y * 2\n    Inner(X)\n}\nV:i64 = Outer(5)", "V", 10);
    // 52: each call makes a closure of its own.
    const greeters = try live.run(h, "MakeGreeter(Name:string)<computes>:function(tuple(), string) = Block{\n    Greeting()<computes>:string = \"Hello, {Name}!\"\n    Greeting\n}\nSayHello:function(tuple(), string) = MakeGreeter(\"Alice\")\nA:string = SayHello()\nSayHi:function(tuple(), string) = MakeGreeter(\"Bob\")\nB:string = SayHi()");
    try std.testing.expectEqualStrings("Hello, Alice!", greeters.get("A").?.string);
    try std.testing.expectEqualStrings("Hello, Bob!", greeters.get("B").?.string);
    // 53: overloaded, chosen by the argument's type (RFC-0085, I4).
    const formats = try live.run(h, "Process(X:i64)<computes>:string = Block{\n    Format(Value:i64)<computes>:string = \"int: {Value}\"\n    Format(Value:string)<computes>:string = \"string: {Value}\"\n    \"{Format(42)}, {Format(\"x\")}\"\n}\nV:string = Process(1)");
    try std.testing.expectEqualStrings("int: 42, string: x", formats.get("V").?.string);
    // 54: the counter, its value before and after an increment.
    try expectInt(h,
        \\counter := tuple(function<reads>(tuple(), i64), function<transacts>(tuple(), void))
        \\MakeCounter(Initial:i64)<transacts>:counter = Block{
        \\    var Count:i64 = Initial
        \\    GetCount()<reads>:i64 = Count
        \\    Increment()<transacts>:void = Set(Count, Count + 1)
        \\    tuple{GetCount, Increment}
        \\}
        \\Counter:counter = MakeCounter(0)
        \\V:i64 = Block{ Before := Counter(0)(); Counter(1)(); Before * 10 + Counter(0)() }
    , "V", 1);
    // 55: no class in a function, as before; one at module level is used from a function.
    try refused(h, "F()<computes>:i64 = Block{ my_class := class{}; 0 }\nV:i64 = F()", .unknown_name, "class");
    try std.testing.expect(try h.run(try h.compile("my_class := class{}\nF()<transacts>:my_class = my_class{}\nV:my_class = F()"), live.fuel) == .ok);
    // 56: used before it is declared, which also refuses mutual recursion; the correct form.
    try refused(h, "F()<computes>:i64 = Block{\n    X := G()\n    G()<computes>:i64 = 42\n    X\n}\nV:i64 = F()", .unknown_name, "G");
    try refused(h, "F()<computes>:i64 = Block{ A(K:i64)<computes>:i64 = If(K > 0, B(K - 1), 0); B(K:i64)<computes>:i64 = A(K); A(3) }\nV:i64 = F()", .unknown_name, "B");
    try expectInt(h, "F()<computes>:i64 = Block{\n    G()<computes>:i64 = 42\n    G()\n}\nV:i64 = F()", "V", 42);
    // 57: no superclass call in a nested function, in either spelling; the correct form.
    const base = "base_class := class{ F(X:i64)<computes>:i64 = X }\n";
    try refused(h, base ++ "derived_class := class(base_class){ F<override>(X:i64)<computes>:i64 = Block{ G()<computes>:i64 = Super.F(X); G() } }\nV:i64 = derived_class{}.F(3)", .nested_super, "Super");
    try refused(h, base ++ "derived_class := class(base_class){ F<override>(X:i64)<computes>:i64 = Block{ G()<computes>:i64 = (super:)F(X); G() } }\nV:i64 = derived_class{}.F(3)", .nested_super, "super");
    try refused(h, base ++ "derived_class := class(base_class){ F<override>(X:i64)<computes>:i64 = Block{ G()<computes>:i64 = Block{ H := Fn()<computes>:i64{ Super.F(X) }; H() }; G() } }\nV:i64 = derived_class{}.F(3)", .nested_super, "Super");
    try expectInt(h, base ++ "derived_class := class(base_class){ F<override>(X:i64)<computes>:i64 = Block{ S := Super.F(X); G()<computes>:i64 = S + 1; G() } }\nV:i64 = derived_class{}.F(3)", "V", 4);
}

test "nested functions: anonymous entries flagged nested, direct calls, recursion and values" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<computes>:function(tuple(i64), i64) = Block{ Go(K:i64)<computes>:i64 = If(K <= 0, N, Go(K - 1) + 1); A := Go(2); Go }\nG:function(tuple(i64), i64) = F(10)\nV:i64 = G(3)");
    const go = entryNamed(p, "Go").?;
    try std.testing.expect(go.nested and go.anonymous and !go.is_public);
    // Its capture `N` precedes its parameter.
    try std.testing.expectEqual(@as(u32, 2), go.parameter_count);
    var calls: usize = 0;
    var recurs: usize = 0;
    var values: usize = 0;
    var binds: usize = 0;
    for (p.function_nodes) |entry| if (entry.input == .operation) switch (entry.node.kind) {
        .call => |c| if (p.functions[c.function].nested) {
            calls += 1;
        },
        .recur => recurs += 1,
        .function_value => |target| if (p.functions[target].nested) {
            values += 1;
        },
        .bind => binds += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), recurs);
    try std.testing.expectEqual(@as(usize, 1), values);
    try std.testing.expectEqual(@as(usize, 1), binds);
    try std.testing.expectEqual(@as(i64, 13), (try h.run(p, live.fuel)).ok.get("V").?.integer);
    // A value in its own body is its `self_value`, bound to its capture.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = If(K <= 0, N, Block{ S := G; S(K - 1) + 1 }); G(3) }\nV:i64 = F(4)", "V", 7);
    // One that captures nothing is a plain value, called through it as through any.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = K * 3; H:function(tuple(i64), i64) = G; H(N) + G(1) }\nV:i64 = F(4)", "V", 15);
    // A program without the form has no entry flagged.
    const plain = try h.compile("F(N:i64)<computes>:i64 = Block{ G := Fn(K:i64)<computes>:i64{ K + N }; G(1) }\nV:i64 = F(4)");
    for (plain.functions) |f| try std.testing.expect(!f.nested);
}

test "nested functions: S1a shares the local vars they name, and only those" {
    const h = try harness.create();
    defer scratch.release(h);
    // A nested function that only reads a local shares it: a later write is seen.
    const shared = "F()<transacts>:i64 = Block{ var X:i64 = 1; G()<reads>:i64 = X; set X = 5; G() }\nV:i64 = F()";
    try expectInt(h, shared, "V", 5);
    const p = try h.compile(shared);
    try std.testing.expect(refCells(p));
    const with = h.front.passes;
    // Its twin with a module var takes one compile fewer and has no cell.
    _ = try h.compile("var M:i64 = 1\nF()<transacts>:i64 = Block{ var X:i64 = 1; G()<reads>:i64 = M; set X = 5; G() }\nV:i64 = F()");
    try std.testing.expectEqual(h.front.passes + 1, with);
    // Once shared, an `Fn` built before the write refers to the cell too (S2).
    try expectInt(h, "F()<transacts>:i64 = Block{ var A:i64 = 1; K := Fn()<reads>:i64{ A }; set A = 9; G()<reads>:i64 = A; K() * 10 + G() }\nV:i64 = F()", "V", 99);
    // A local that only an `Fn` reads is shared since Q1 (I13), nested function or not.
    try expectInt(h, "F()<transacts>:i64 = Block{ var A:i64 = 1; K := Fn()<reads>:i64{ A }; set A = 9; G()<computes>:i64 = 3; K() * 10 + G() }\nV:i64 = F()", "V", 93);
    // Immutable locals and parameters are captured by value: no cell.
    const values = try h.compile("F(P:i64)<computes>:i64 = Block{ L := P + 1; G()<computes>:i64 = L + P; G() }\nV:i64 = F(2)");
    try std.testing.expect(!refCells(values));
    try std.testing.expectEqual(@as(i64, 5), (try h.run(values, live.fuel)).ok.get("V").?.integer);
    // Through the capture of an `Fn` around it, and through a loop's carry.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; O := Fn()<transacts>:i64{ Block{ G()<transacts>:i64 = Set(X, X + 2); G(); G() } }; O(); X }\nV:i64 = F()", "V", 5);
    try expectInt(h, "F(Xs:[]i64)<transacts>:i64 = Block{ var T:i64 = 0; For(K:Xs, Block{ set T += K; Note()<reads>:i64 = T; Note() }); T }\nV:i64 = F(array{1, 2, 3})", "V", 6);
    // No loop carries what a nested function shares: its writes during the loop stay.
    try expectInt(h, "F(Xs:[]i64)<transacts>:i64 = Block{ var T:i64 = 0; Bump()<transacts>:i64 = Set(T, T + 100); For(K:Xs, Block{ set T += K; Bump() }); T }\nV:i64 = F(array{1, 2, 3})", "V", 306);
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; var Y:i64 = 0; While(X < 3, Block{ G()<transacts>:void = Set(X, X + 1); G(); set Y += X; 0 }); X * 10 + Y }\nV:i64 = F()", "V", 36);
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; G()<transacts>:void = Set(X, X + 1); Loop{ If(X >= 3, Break(), false); G() }; X }\nV:i64 = F()", "V", 3);
    // At the root.
    try expectInt(h, "V:i64 = Block{ var C:i64 = 1; Bump()<transacts>:i64 = Set(C, C * 3); Bump(); Bump(); C }", "V", 9);
    // In a `Loop{}`'s body, a statement of a block as written.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; Loop{ G()<transacts>:void = Set(X, X + 1); G(); If(X >= 3, Break(), false) }; X }\nV:i64 = F()", "V", 3);
    // A label denotes nothing (review): a field of an archetype, a named argument and the
    // field `WithField` takes share nothing, in a nested function or in an `Fn` (I13), so the
    // local `X` stays a plain local and no cell is made.
    const labels = [_]struct { []const u8, i64 }{
        .{ "pt := struct{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var X:i64 = 1; G()<computes>:pt = pt{X := 5}; set X = 2; X * 10 + G().X }\nV:i64 = F()", 25 },
        .{ "Pair(A:i64, X:i64)<computes>:i64 = A * 100 + X\nF()<transacts>:i64 = Block{ var X:i64 = 1; G()<computes>:i64 = Pair(A := 1, X := 5); set X = 2; X * 1000 + G() }\nV:i64 = F()", 2105 },
        .{ "pt := struct{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var X:i64 = 1; G()<computes>:pt = WithField(pt{}, X, 5); set X = 2; X * 10 + G().X }\nV:i64 = F()", 25 },
        .{ "pt := struct{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var X:i64 = 1; H := Fn()<computes>:pt{ pt{X := 5} }; set X = 2; X + H().X }\nV:i64 = F()", 7 },
        .{ "Pair(A:i64, X:i64)<computes>:i64 = A * 100 + X\nF()<transacts>:i64 = Block{ var X:i64 = 1; H := Fn()<computes>:i64{ Pair(A := 1, X := 5) }; set X = 2; X * 1000 + H() }\nV:i64 = F()", 2105 },
    };
    for (labels) |entry| {
        try expectInt(h, entry[0], "V", entry[1]);
        try std.testing.expect(!refCells(try h.compile(entry[0])));
    }
}

test "nested functions: closures that name one carry its captures" {
    const h = try harness.create();
    defer scratch.release(h);
    // An `Fn`, a nested function and a loop's body call one declared before them.
    try expectInt(h, "F(X:i64)<computes>:i64 = Block{ G(Y:i64)<computes>:i64 = X + Y; K := Fn(Z:i64)<computes>:i64{ G(Z) + 1 }; K(3) }\nV:i64 = F(5)", "V", 9);
    try expectInt(h, "F(X:i64)<computes>:i64 = Block{ G(Y:i64)<computes>:i64 = X + Y; H(Z:i64)<computes>:i64 = G(Z) * 2; H(1) + G(10) }\nV:i64 = F(5)", "V", 27);
    const squares = try live.run(h, "F(N:i64)<computes>:[]i64 = Block{ Sq(K:i64)<computes>:i64 = K * K + N; For(I:1..3, Sq(I)) }\nV:[]i64 = F(1)");
    const listed = squares.elements(squares.get("V").?).?;
    for (listed, [_]i64{ 2, 5, 10 }) |value, wanted| try std.testing.expectEqual(wanted, value.integer);
    // An `Fn` that names a nested function, inside a nested function that names another.
    try expectInt(h, "F(N:i64)<transacts>:i64 = Block{ var A:i64 = 1; var B:i64 = 2; G()<reads>:i64 = A + B; H()<reads>:i64 = G() * 10; set A = 5; K := Fn()<reads>:i64{ H() + 1 }; K() }\nV:i64 = F(0)", "V", 71);
    // A nested function in an `Fn`, over the `Fn`'s parameter and capture.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ O := Fn(M:i64)<computes>:i64{ Block{ G(K:i64)<computes>:i64 = K + M + N; G(1) } }; O(10) }\nV:i64 = F(4)", "V", 15);
    // A task body; the task writes the cell after its `Sleep`.
    const waits = try live.run(h,
        \\Waits()<transacts><suspends>:i64 = Block{
        \\    var Seen:i64 = 0
        \\    Note(K:i64)<transacts>:void = Set(Seen, Seen + K)
        \\    T := Spawn{ Sleep(1.0); Note(7) }
        \\    Note(100)
        \\    T.Await()
        \\    Seen
        \\}
        \\T:task(i64) = Spawn{ Waits() }
    );
    var buffer: [2048]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try report(waits, &buffer), "\"result\":107") != null);
    // A guard that calls one reads what it reads (I2-D9), and follows the cell.
    const guarded = try live.run(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; R()<reads>:i64 = L; W()<transacts>:void = Set(L, 5); set live Y = R() + 1; A := Y; W(); A * 100 + Y }\nV:i64 = F()");
    try std.testing.expectEqual(@as(i64, 206), guarded.get("V").?.integer);
    // The landing a cancellation runs calls one through the copy of its `Defer` body.
    const landed = try live.run(h, "F()<transacts><suspends>:i64 = Block{ var X:i64 = 0; Note(K:i64)<transacts>:void = Set(X, X + K); W := Race(Block{ Defer{ Note(10) }; Sleep(5.0); 1 }, Block{ Sleep(1.0); 2 }); W * 100 + X }\nT:task(i64) = Spawn{ F() }");
    try std.testing.expect(std.mem.indexOf(u8, try report(landed, &buffer), "\"result\":210") != null);
    // A value of one in a tuple, and passed to a function.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = K + N; P := tuple{G, G}; P(0)(1) * 100 + P(1)(2) }\nV:i64 = F(10)", "V", 1112);
    try expectInt(h, "Apply(F:function(tuple(i64), i64), X:i64)<computes>:i64 = F(X)\nF(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = K * N; Apply(G, 3) }\nV:i64 = F(10)", "V", 30);
    // An explicit capture list says what is captured: it cannot reach one.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = N; K := Fn[A:i64 = N]()<computes>:i64{ G() + A }; K() }\nV:i64 = F(4)", .unknown_name, "G");
    // Nor can a closure in its own body, as a loop in a named function cannot name it.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = Block{ For(I:1..2, G(1)); K }; G(N) }\nV:i64 = F(4)", .unknown_name, "G");
}

test "nested functions: scope, exits, effects and kinds" {
    const h = try harness.create();
    defer scratch.release(h);
    // To the end of its block, and its sibling blocks may reuse its name.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ Block{ H()<computes>:i64 = 1; H() } + H() }\nV:i64 = F(4)", .unknown_name, "H");
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ Block{ H()<computes>:i64 = 1; H() } + Block{ H()<computes>:i64 = 2; H() } }\nV:i64 = F(4)", "V", 3);
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = N; Block{ H()<computes>:i64 = G() + 1; H() } + G() }\nV:i64 = F(4)", "V", 9);
    // Bodies over several lines, and a statement on the next line.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{\n    G(A:i64,\n      B:i64)<computes>:i64 = A + B + N\n    H()<computes>:i64 = Block{\n        X := N * 2\n        X + 1\n    }\n    G(1, 2) + H()\n}\nV:i64 = F(4)", "V", 16);
    // `Return` leaves it, also from a loop inside it, and the `Defer` around it is not its own.
    try expectInt(h, "F(N:i64)<computes>:i64 = Block{ G(Y:i64)<computes>:i64 = Block{ If(Y > 3, Return(100), 0); Y }; G(N) + G(1) }\nV:i64 = F(5)", "V", 101);
    try expectInt(h, "Find(Xs:[]i64, K:i64)<transacts>:i64 = Block{ Index()<transacts>:i64 = Block{ var I:i64 = 0; For(X:Xs, Block{ If(X == K, Return(I), 0); set I += 1; 0 }); -1 }; Index() * 10 }\nV:i64 = Find(array{4, 5, 6}, 6)", "V", 20);
    try expectInt(h, "var Log:i64 = 0\nF(N:i64)<transacts>:i64 = Block{ Defer{ set Log += 1 }; G(K:i64)<computes>:i64 = Block{ If(K > 1, Return(K * 3), 0); K }; G(N) + G(1) }\nV:i64 = F(4)\nW:i64 = Log", "W", 1);
    try expectInt(h, "var Log:i64 = 0\nF(N:i64)<transacts>:i64 = Block{ G(K:i64)<transacts>:i64 = Block{ Defer{ set Log += 1 }; If(K > 1, Return(K * 3), 0); K }; G(N) + G(1) }\nV:i64 = F(4)\nW:i64 = Log * 100 + V", "W", 213);
    // A `Defer` body calls one declared before it.
    try expectInt(h, "var Log:i64 = 0\nF(N:i64)<transacts>:i64 = Block{ G()<transacts>:void = Block{ set Log += N; 0 }; Defer{ G() }; 1 }\nV:i64 = F(4)\nW:i64 = Log", "W", 4);
    try refused(h, "F(N:i64)<computes>:i64 = Block{ Loop{ G()<computes>:i64 = Break(); G(); Break() }; 1 }\nV:i64 = F(4)", .break_outside_loop, "Break");
    // Its effects are its own; a call is checked against the caller.
    try expectInt(h, "F(N:i64)<computes>:function<transacts>(tuple(), i64) = Block{ Later()<transacts>:i64 = N; Later }\nV:i64 = F(4)()", "V", 4);
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<transacts>:i64 = N; G() }\nV:i64 = F(4)", .call_requires_transacts, "G");
    // `<decides>` needs a failure context and brackets, `<suspends>` a suspending caller.
    try expectInt(h, "F(N:i64)<computes><decides>:i64 = Block{ G(K:i64)<computes><decides>:i64 = Block{ Require[K > 0]; K }; G[N] }\nV:i64 = Attempt(F[3], -1) * 10 + Attempt(F[0], -1)", "V", 29);
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes><decides>:i64 = Block{ Require[K > 0]; K }; G[N] }\nV:i64 = F(3)", .failure_context_required, "G");
    try refused(h, "F(N:i64)<transacts>:i64 = Block{ G()<transacts><suspends>:i64 = Block{ Sleep(1.0); N }; G() }\nV:i64 = F(3)", .call_requires_suspends, "G");
    const slow = try live.run(h, "Run()<transacts><suspends>:i64 = Block{ var X:i64 = 0; Slow(K:i64)<transacts><suspends>:i64 = Block{ Sleep(1.0); Set(X, X + K) }; A := Slow(2); B := Slow(3); A * 10 + B + X }\nT:task(i64) = Spawn{ Run() }");
    var buffer: [2048]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try report(slow, &buffer), "\"result\":30") != null);
    // A transparent one takes its body's type, and cannot name itself or `Return`.
    try expectInt(h, "Twice(N:i64)<computes>:i64 = Block{ T(Y:i64)<computes> := Y * 2; T(N) }\nV:i64 = Twice(21)", "V", 42);
    try refused(h, "Twice(N:i64)<computes>:i64 = Block{ T(Y:i64)<computes> := If(Y > 0, T(Y - 1), 0); T(N) }\nV:i64 = Twice(21)", .transparent_recursion, "T");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ T(Y:i64)<computes> := Block{ If(Y > 0, Return(1), 0); Y }; T(N) }\nV:i64 = F(4)", .return_type_required, "Return");
    const transparent = try h.compile("F(N:i64)<computes>:i64 = Block{ T(Y:i64)<computes> := Y * 2; T(N) }\nV:i64 = F(4)");
    try std.testing.expect(entryNamed(transparent, "T").?.transparent);
    // A generic function around one compiles it with each specialization.
    const partial = try live.run(h, "Partial[a:type, b:type, c:type](F:function(tuple(a, b), c), X:a)<computes>:function(tuple(b), c){Block{ PartialFunc(Y:b)<computes>:c = F(X, Y); PartialFunc }}\nAdd(X:i64, Y:i64)<computes>:i64 = X + Y\nJoin(X:string, Y:string)<computes>:string = X + Y\nAdd5:function(tuple(i64), i64) = Partial[i64, i64, i64](Add, 5)\nHi:function(tuple(string), string) = Partial[string, string, string](Join, \"hi \")\nV:i64 = Add5(3)\nW:string = Hi(\"there\")");
    try std.testing.expectEqual(@as(i64, 8), partial.get("V").?.integer);
    try std.testing.expectEqualStrings("hi there", partial.get("W").?.string);
    var specializations: usize = 0;
    for (partial.program.functions) |f| if (f.nested and f.specialization != null) {
        specializations += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), specializations);
    // One outside a generic function's body is not in its scope there.
    try expectInt(h, "Use[t:type](X:t)<computes>:i64{Block{ G()<computes>:i64 = 1; G() }}\nF(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = N; Use[i64](G()) + G() }\nV:i64 = F(4)", "V", 5);
    // In a method it captures `Self`.
    try expectInt(h, "c := class{ var V:i64 = 7; M(X:i64)<transacts>:i64 = Block{ G()<transacts>:i64 = Block{ set Self.V += X; Self.V }; G() + G() } }\nV:i64 = c{}.M(3)", "V", 23);
}

test "nested functions: every diagnostic, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // `nested_access`, after the name as a top-level function writes it, or among the effects.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G<public>(K:i64)<computes>:i64 = K; G(1) }\nV:i64 = F(4)", .nested_access, "public");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<private><computes>:i64 = K; G(1) }\nV:i64 = F(4)", .nested_access, "private");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes><scoped>:i64 = K; G(1) }\nV:i64 = F(4)", .nested_access, "scoped");
    // `nested_generic`: type parameters, or a `where` clause.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G[t:type](K:t)<computes>:t = K; G(1) }\nV:i64 = F(4)", .nested_generic, "G");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:t where t:type)<computes>:t = K; G(1) }\nV:i64 = F(4)", .nested_generic, "where");
    // `nested_position`: as a function's body, an operand, an `Fn`'s body, or in a `Defer` body
    // at any depth.
    try refused(h, "F(N:i64)<computes>:i64 = G(K:i64)<computes>:i64 = K\nV:i64 = F(4)", .nested_position, "G");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ Q := (G(K:i64)<computes>:i64 = K); 0 }\nV:i64 = F(4)", .nested_position, "G");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ Q := Fn()<computes>:i64{ G()<computes>:i64 = 1 }; 0 }\nV:i64 = F(4)", .nested_position, "G");
    try refused(h, "V:i64 = G()<computes>:i64 = 1", .nested_position, "G");
    try refused(h, "F(N:i64)<transacts>:i64 = Block{ Defer{ G()<computes>:i64 = 1; G() }; 0 }\nV:i64 = F(4)", .nested_position, "G");
    try refused(h, "F(N:i64)<transacts>:i64 = Block{ Defer{ Q := Fn()<computes>:i64{ Block{ G()<computes>:i64 = 1; G() } }; Q() }; 0 }\nV:i64 = F(4)", .nested_position, "G");
    // An argument that a macro moves into a block of its own is no statement of a block as
    // written (review): the branch of an `If` with a binding, the body of a `While`, and so in a
    // `Defer` body, whose copies would be entries of one name.
    try refused(h, "F(O:option(i64))<computes>:i64 = If(V := O?, G()<computes>:i64 = 5 + V; G(), 0)\nV:i64 = F(option{2})", .nested_position, "G");
    try refused(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; While(X < 3, G(K:i64)<transacts>:void = Set(X, X + 1); G(1)); X }\nV:i64 = F()", .nested_position, "G");
    try refused(h, "F(X:i64, O:option(i64))<transacts>:i64 = Block{ var N:i64 = 0; Defer{ If(V := O?, G(K:i64)<computes>:i64 = K + V; G(5), 0) }; If(X > 0, Return(1), 0); N }\nV:i64 = F(1, option{1})", .nested_position, "G");
    try refused(h, "F(O:option(i64))<transacts>:i64 = Block{ R := For(I:1..3, Block{ X := If(V := O?, G(K:i64)<computes>:i64 = Block{ If(K > 1, Return(100), 0); K }; G(I), 0); X }); R.Length }\nV:i64 = F(option{1})", .nested_position, "G");
    // `shadowed_name`: a parameter, the function, a global, another nested function, its own
    // name taken by its parameter or a later local.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ N()<computes>:i64 = 1; 0 }\nV:i64 = F(4)", .shadowed_name, "N");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ F()<computes>:i64 = 1; 0 }\nV:i64 = F(4)", .shadowed_name, "F");
    try refused(h, "V:i64 = 3\nF(N:i64)<computes>:i64 = Block{ V()<computes>:i64 = 1; 0 }\nW:i64 = F(4)", .shadowed_name, "V");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = 1; G := 2; 0 }\nV:i64 = F(4)", .shadowed_name, "G");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(G:i64)<computes>:i64 = 1; 0 }\nV:i64 = F(4)", .shadowed_name, "G");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = 1; Block{ G()<computes>:i64 = 2; G() } }\nV:i64 = F(4)", .shadowed_name, "G");
    // `expected_computes`: an effect is mandatory (V2).
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64):i64 = K; G(1) }\nV:i64 = F(4)", .expected_computes, ":");
    // A block ends with a value, not a declaration.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = 1 }\nV:i64 = F(4)", .expected_expression, "}");
    // S6, at the name.
    try refused(h, "F(N:i64)<transacts>:i64 = Block{ var X:i64 = 1; G()<computes>:i64 = X; set X = 5; G() }\nV:i64 = F(4)", .local_read_requires_reads, "X");
    try refused(h, "F(N:i64)<transacts>:i64 = Block{ var X:i64 = 1; G()<reads>:void = Set(X, 2); G(); X }\nV:i64 = F(4)", .set_requires_writes, "X");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G()<computes>:i64 = Block{ var X:i64 = 1; X }; G() }\nV:i64 = F(4)", .local_var_requires_writes, "X");
    // An argument count, as for any call.
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = K; G(1, 2) }\nV:i64 = F(4)", .argument_count, ",");
    try refused(h, "F(N:i64)<computes>:i64 = Block{ G(K:i64)<computes>:i64 = If(K > 0, G(), 0); G(1) }\nV:i64 = F(4)", .argument_count, "G");
}

test "nested functions: rollback of the cells they write (S4)" {
    const h = try harness.create();
    defer scratch.release(h);
    // R3 with a nested function that writes `X`.
    try expectInt(h, "F(N:i64)<transacts>:i64 = Block{ var X:i64 = N; G()<transacts>:i64 = Set(X, X + 1); Held:i64 = X; Attempt(Block{ G(); Fail[\"undo\"]; X }, Set(X, X + 7)); Held + X }\nV:i64 = F(3)", "V", 13);
    // A failing visit of a `For` undoes what the call in it wrote.
    try expectInt(h, "F(Xs:[]i64)<transacts>:i64 = Block{ var T:i64 = 0; Put(K:i64)<transacts>:i64 = Set(T, T + K); Rs := For(K:Xs, Block{ Put(K); Require[K != 2]; K }); T * 10 + Rs.Length }\nV:i64 = F(array{1, 2, 3})", "V", 42);
    // A failure inside the call that its caller catches restores what the call wrote.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; G()<transacts><decides>:i64 = Block{ set X = 50; Require[false]; X }; A := Attempt(G[], -1); A * 100 + X }\nV:i64 = F()", "V", -99);
    // A closure stored in a region that fails is forgotten with the cell made there.
    try expectInt(h, "var Keep:option(function<transacts>(tuple(),i64))=option{}\nF()<transacts>:i64=Block{A:=Attempt(Block{var C:i64=5;G()<transacts>:i64=Set(C,C+1);set Keep=option{G};G();Require[false];0},-1);A+Attempt(Keep?(),0)}\nV:i64=F()", "V", -1);
}

// At the limit of the active profile (16 in the bootstrap profile, 32 in the program profile).
test "nested functions: captures and parameters together are bounded by the parameter limit" {
    const h = try harness.create();
    defer scratch.release(h);
    const limit = types.limits.parameters;
    var text: [2048]u8 = undefined;
    // The function around has `limit - 1` parameters, all named by `G`, which has one of its own.
    for ([_]usize{ limit - 1, limit }) |names| {
        var out = std.Io.Writer.fixed(&text);
        try out.writeAll("F(");
        for (0..names) |index| try out.print("{s}P{d}:i64", .{ if (index == 0) "" else ", ", index });
        try out.writeAll(")<computes>:i64 = Block{ G(Y:i64)<computes>:i64 = Y");
        for (0..names) |index| try out.print(" + P{d}", .{index});
        try out.writeAll("; G(1) }\nV:i64 = F(");
        for (0..names) |index| try out.print("{s}1", .{if (index == 0) "" else ", "});
        try out.writeAll(")");
        if (names == limit - 1) {
            try expectInt(h, out.buffered(), "V", @intCast(names + 1));
        } else switch (h.front.compile(out.buffered())) {
            .ok => return error.Compiled,
            .failed => |d| try std.testing.expectEqual(types.Diagnostic.Code.parameter_limit, d.code),
        }
    }
    // So with captures a closure takes from a nested function it names.
    var out = std.Io.Writer.fixed(&text);
    try out.writeAll("F(");
    for (0..limit) |index| try out.print("{s}P{d}:i64", .{ if (index == 0) "" else ", ", index });
    try out.writeAll(")<computes>:i64 = Block{ G()<computes>:i64 = 0");
    for (0..limit - 1) |index| try out.print(" + P{d}", .{index});
    try out.print("; K := Fn()<computes>:i64{{ G() + P{d} }}; K() }}\nV:i64 = F(", .{limit - 1});
    for (0..limit) |index| try out.print("{s}1", .{if (index == 0) "" else ", "});
    try out.writeAll(")");
    try expectInt(h, out.buffered(), "V", @intCast(limit));
}

// ---- F18 (RFC-0085 admission rule 8): a forged `nested` flag, or its absence.

fn forgedRefused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

test "F18: forged nested entries are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\counter := class{ var N:i64 = 0 }
        \\Make(Start:i64)<transacts>:function<transacts>(tuple(), i64) = Block{
        \\    var Count:i64 = Start
        \\    Next()<transacts>:i64 = Set(Count, Count + 1)
        \\    Twice(K:i64)<computes>:i64 = K * 2
        \\    Next() + Twice(1)
        \\    Next
        \\}
        \\Plain(X:i64)<computes>:i64 = X + 1
        \\Lambda(X:i64)<computes>:i64 = (Fn(Y:i64)<computes>:i64{ Y + X })(1)
        \\Step:function<transacts>(tuple(), i64) = Make(5)
        \\V:i64 = Step() + Plain(1) + Lambda(2)
    ;
    const p = try h.compile(source);
    const run = (try h.run(p, live.fuel)).ok;
    try std.testing.expectEqual(@as(i64, 7 + 2 + 3), run.get("V").?.integer);
    const functions = try allocator.dupe(types.RuntimeFunction, p.functions);
    defer allocator.free(functions);
    var forged = p;
    forged.functions = functions;
    var next: usize = undefined;
    var plain: usize = undefined;
    var lambda: usize = undefined;
    for (p.functions, 0..) |f, index| {
        const name = f.name.text(p.source);
        if (std.mem.eql(u8, name, "Next")) next = index;
        if (std.mem.eql(u8, name, "Plain")) plain = index;
        if (std.mem.eql(u8, name, "Fn")) lambda = index;
    }
    try std.testing.expect(p.functions[next].nested);
    // `nested` on an entry that is not anonymous.
    functions[plain].nested = true;
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    // On a public one.
    functions[next].is_public = true;
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    // On one that exits an arm, or holds a class's clauses.
    functions[next].exits = .i64;
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    functions[next].clauses_of = run.program.functions[next].value_type;
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    // Whose name is not an identifier the source follows with `(`: `Count`, followed by `:`.
    const count_at: u32 = @intCast(std.mem.indexOf(u8, p.source, "Count:i64").?);
    functions[next].name = .{ .start = count_at, .end = count_at + 5 };
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    // An anonymous entry with an arbitrary name and no `nested`.
    functions[next].nested = false;
    try forgedRefused(h, run, forged);
    @memcpy(functions, p.functions);
    // The flag on an `Fn`, whose name `(` follows too, is harmless: admitted, and the same run.
    functions[lambda].nested = true;
    const again = (try h.run(forged, live.fuel)).ok;
    try std.testing.expectEqual(run.get("V").?.integer, again.get("V").?.integer);
    _ = try reporting.validate(again, false, .{ .work = 1 << 24 });
}

test "nested functions: inspection format 37 lists them; a program without one keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const report_space = try scratch.storage(inspection.Workspace);
    defer scratch.release(report_space);
    const out_buffer = try allocator.alloc(u8, 1 << 18);
    defer allocator.free(out_buffer);
    var out = std.Io.Writer.fixed(out_buffer);
    const p = try h.compile("F(X:i64)<computes>:i64 = Block{ Inner(Y:i64)<computes>:i64 = Y * 2; G := Fn(Z:i64)<computes>:i64{ Z }; Inner(G(X)) }\nA:i64 = F(1)");
    try std.testing.expect(try report_space.write(&out, p) == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 37), parsed.value.object.get("format").?.integer);
    const listed = parsed.value.object.get("function_nested").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("Inner", p.functions[@intCast(listed[0].integer)].name.text(p.source));
    out.end = 0;
    const plain = try h.compile("F(X:i64)<computes>:i64 = Block{ G := Fn(Z:i64)<computes>:i64{ Z }; G(X) * 2 }\nA:i64 = F(1)");
    try std.testing.expect(try report_space.write(&out, plain) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":22,"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "function_nested") == null);
}
