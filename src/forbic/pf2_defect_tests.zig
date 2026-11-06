//! Defects closed by the `pf2` pass (`docs/development/capacity-review.md`, "Defect pass pf2"):
//! each reproducer is kept as the regression test of its fix.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");
const nested = @import("nested_module_tests.zig");
const evaluator = @import("evaluator.zig");

// A specialised generic function and a class method of the same name: the compiler accepted
// the program and both admissions refused it as two declarations of one name (`invalid_ir`).
// A specialization is reached by its template and type arguments, a method through its class,
// and a generic method's specialization through a value of its class, so none of them is a
// second declaration of another's name.
test "a specialised generic function and a method of the same name both compile and run" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, a: i64, b: i64 };
    const cases = [_]Case{
        // The program the defect was found with, then one that calls the method too.
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nA:i64 = Put[i64](3)\nbox := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nB:i64 = 0", .a = 3, .b = 0 },
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nbox := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nA:i64 = Put[i64](3)\nB:i64 = box{V := 4}.Put()", .a = 3, .b = 4 },
        // Two specialisations, one called from inside the class, next to the method.
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nbox := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V\n  Twice()<reads>:i64 = Self.Put() + Put[i64](Self.V) }\nA:i64 = Put[i64](3) + Put[string](\"ab\").Length - 2\nB:i64 = box{V := 4}.Twice()", .a = 3, .b = 8 },
        // A specialisation whose argument is the class whose method shares its name.
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nbox := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nX:box = Put[box](box{V := 2})\nA:i64 = X.Put()\nB:i64 = Put[i64](5)", .a = 2, .b = 5 },
        // An interface method, implemented by a class.
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nA:i64 = Put[i64](3)\nholder := interface{ Put()<reads>:i64 }\nbox := class(holder){ V:i64 = 0\n  Put<override>()<reads>:i64 = Self.V }\nH:holder = box{V := 4}\nB:i64 = H.Put()", .a = 3, .b = 4 },
        // A generic method of one class and a method of another, in both orders.
        .{ .source = "box := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\nother := class{ Put()<computes>:i64 = 7 }\nA:i64 = box{}.Put[i64](3)\nB:i64 = other{}.Put()", .a = 3, .b = 7 },
        .{ .source = "other := class{ Put()<computes>:i64 = 7 }\nbox := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\nA:i64 = box{}.Put[i64](3)\nB:i64 = other{}.Put()", .a = 3, .b = 7 },
        // An extension method and a generic method, in both orders.
        .{ .source = "(N:i64).Put()<computes>:i64 = N + 1\nbox := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\nA:i64 = box{}.Put[i64](3)\nB:i64 = (4).Put()", .a = 3, .b = 5 },
        .{ .source = "box := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\n(N:i64).Put()<computes>:i64 = N + 1\nA:i64 = box{}.Put[i64](3)\nB:i64 = (4).Put()", .a = 3, .b = 5 },
        // A generic function and a generic method, in both orders.
        .{ .source = "Put[T:type](V:T)<computes>:T{ V }\nbox := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\nA:i64 = Put[i64](3)\nB:i64 = box{}.Put[i64](4)", .a = 3, .b = 4 },
        .{ .source = "box := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X } }\nPut[T:type](V:T)<computes>:T{ V }\nA:i64 = Put[i64](3)\nB:i64 = box{}.Put[i64](4)", .a = 3, .b = 4 },
        // A generic method with two parameters and a bound written across a comment, next to a
        // function of its name: its arguments list the receiver after its own two.
        .{ .source = "base := class{}\nPut(N:i64)<computes>:i64 = N\nbox := class(base){ V:i64 = 0\n  Put[T:type, U:subtype(base) # the receiver's kind, ]\n  ](X:T, Y:U)<computes>:T{ X } }\nA:i64 = box{}.Put[i64, box](3, box{})\nB:i64 = Put(4)", .a = 3, .b = 4 },
    };
    for (cases) |case| {
        const x = try h.execute(case.source);
        try std.testing.expectEqual(case.a, x.get("A").?.integer);
        try std.testing.expectEqual(case.b, x.get("B").?.integer);
    }
}

test "a generic function and a method of its name in a nested module and across files" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try nested.one(h,
        \\M<public>:=module{
        \\  Put<public>[T:type](V:T)<computes>:T{ V }
        \\  box<public>:=class{ V<public>:i64 = 0
        \\    Put<public>()<reads>:i64 = Self.V }
        \\  In:i64 = Put[i64](2) + box{V := 5}.Put()
        \\}
        \\A:i64 = M.Put[i64](3)
        \\B:i64 = M.box{V := 4}.Put()
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("B").?.integer);
    const files = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nbox := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nA:i64 = L.Put[i64](3)\nB:i64 = box{V := 4}.Put()" },
        .{ .path = "lib.forb", .source = "Put<public>[T:type](V:T)<computes>:T{ V }" },
    };
    const y = try nested.execute(h, &files);
    try std.testing.expectEqual(@as(i64, 3), y.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), y.get("B").?.integer);
}

test "what the compiler refused before keeps its diagnostic, and a forged namesake of a generic function is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    // The compiler's own rules are unchanged: a module name declared after a method of that
    // name, and an extension of a generic function's name, are refused as they were.
    for ([_][]const u8{
        "box := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nPut[T:type](V:T)<computes>:T{ V }\nA:i64 = Put[i64](3)",
        "Put[T:type](V:T)<computes>:T{ V }\nA:i64 = Put[i64](3)\n(N:i64).Put()<computes>:i64 = N + 1",
        "box := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X }\n  Put()<computes>:i64 = 7 }\nA:i64 = box{}.Put[i64](3)",
    }) |source| try std.testing.expectEqual(types.Diagnostic.Code.duplicate_name, h.front.compile(source).failed.code);
    // A plain function and a generic function's specialization of one name are still two
    // declarations of it: `Get` renamed `Put`, by a span that no check of a name's place reads (a
    // comment, written last), is refused by both admissions, and the program as the compiler made
    // it runs.
    const source = "Put[T:type](V:T)<computes>:T{ V }\nGet(N:i64)<computes>:i64 = N + 1\nA:i64 = Put[i64](3) + Iterate(Get, 1, 0)\n# Put\n";
    const p = try h.compile(source);
    const functions = try std.testing.allocator.dupe(types.RuntimeFunction, p.functions);
    defer std.testing.allocator.free(functions);
    const put: u32 = @intCast(std.mem.lastIndexOf(u8, source, "Put").?);
    const get: u32 = @intCast(std.mem.indexOf(u8, source, "Get").?);
    var renamed = false;
    var specialized = false;
    for (functions) |*f| {
        if (f.specialization != null) specialized = true;
        if (f.name.start == get) {
            f.name = .{ .start = put, .end = put + 3 };
            renamed = true;
        }
    }
    try std.testing.expect(renamed and specialized);
    var forged = p;
    forged.functions = functions;
    try harness.invalid(h, forged);
    _ = try h.run(p, 131072);
}

// A nested function (`Fn`, a guard) written inside the body of a `For` of a generic function: the
// `For` body is a function of the module's library block, whose template span is widened to
// reach it (`genericSourceFor`), while the function written by the author keeps the template's
// own span. Both identify the same template, and a specialization's function value names a
// function of its own template: the span of the nested function lies within its parent's, and
// starts with it. The compiler's own IR was refused by both admissions.
test "an Fn, a guard and a nested For inside the body of a For of a generic function compile and run" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, a: i64 };
    const cases = [_]Case{
        // The program the defect was found with.
        .{ .source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ W := Fn()<computes>:i64{ 3 }; W() }); 0 } }\nA:i64 = G[i64](1)", .a = 0 },
        // The values are used; an Fn takes an argument and the loop's variable.
        .{ .source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..3, Block{ W := Fn(J:i64)<computes>:i64{ J * 10 + I }; W(I) }); Xs.Length + Attempt(Xs[0], 0) + Attempt(Xs[2], 0) } }\nA:i64 = G[i64](1)", .a = 47 },
        // Two specializations, an Fn in each, one of them of a type that is not an integer.
        .{ .source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ W := Fn()<computes>:i64{ 3 }; W() }); Xs.Length } }\nA:i64 = G[i64](1) + G[string](\"a\") * 10", .a = 22 },
        // A For inside a For, the inner body holding the Fn.
        .{ .source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ Ys := For(J:1..3, Block{ W := Fn()<computes>:i64{ 3 }; W() + I + J }); Ys.Length }); Xs.Length * 10 + Attempt(Xs[1], 0) } }\nA:i64 = G[i64](1)", .a = 23 },
        // An Fn whose body is itself a For.
        .{ .source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ W := Fn()<computes>:i64{ Block{ Ys := For(J:1..4, J); Ys.Length } }; W() + I }); Attempt(Xs[0], 0) + Attempt(Xs[1], 0) } }\nA:i64 = G[i64](1)", .a = 11 },
        // A method of a class declared outside, a generic method, and a method of a parametric class.
        .{ .source = "box := class{ V:i64 = 2\n  M[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..3, Block{ W := Fn()<computes>:i64{ 3 }; W() + Self.V }); Xs.Length + Attempt(Xs[0], 0) } } }\nA:i64 = box{}.M[i64](1)", .a = 8 },
        .{ .source = "Box[T:type] := class{ V:T\n  M()<transacts>:i64 = Block{ Xs := For(I:1..3, Block{ W := Fn()<computes>:i64{ 3 }; W() + I }); Xs.Length + Attempt(Xs[2], 0) } }\nA:i64 = Box[i64]{V := 1}.M()", .a = 9 },
        // A guard: a live variable set inside the loop of a generic function.
        .{ .source = "var Cell:i64 = 0\nvar Other:i64 = 5\nG[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..3, Block{ set live Cell = Other + I; Cell }); Xs.Length } }\nA:i64 = G[i64](1)", .a = 3 },
    };
    for (cases) |case| {
        const x = h.execute(case.source) catch |err| {
            std.debug.print("source: {s}\n", .{case.source});
            return err;
        };
        try std.testing.expectEqual(case.a, x.get("A").?.integer);
    }
}

test "a function value of a specialization names a function of its own template, however the spans widen" {
    const h = try harness.create();
    defer scratch.release(h);
    // `H` is called first, so its `Fn` is made before the body of `G`'s `For`; `G` is declared
    // first, so the widened span of that body reaches `H`'s text.
    const source = "G[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ W := Fn()<computes>:i64{ 3 }; W() }); 0 } }\nH[T:type](X:T)<transacts>:i64{ Block{ Xs := For(I:1..2, Block{ W := Fn()<computes>:i64{ 4 }; W() }); 0 } }\nB:i64 = H[i64](1)\nA:i64 = G[i64](1)";
    const p = try h.compile(source);
    const g_start: u32 = 0;
    const h_start: u32 = @intCast(std.mem.indexOf(u8, source, "H[T").?);
    // The compiler's own IR has both: the body of a `For` in the library block, widened to reach
    // it, and the `Fn` the author wrote in it, which keeps its template's span.
    var widened: ?usize = null;
    var narrow: ?usize = null;
    for (p.functions, 0..) |f, id| {
        if (f.specialization == null or !f.anonymous) continue;
        if (f.generic_source.start == g_start and f.generic_source.end > source.len and widened == null) widened = id;
        if (f.generic_source.start == h_start and f.generic_source.end <= source.len) narrow = id;
    }
    try std.testing.expect(widened != null and narrow != null and narrow.? < widened.?);
    _ = try h.run(p, 131072);
    // Forged IR: a function value in `G`'s body names the `Fn` of `H`, a function of another
    // template (the specialization key is the same: the type argument is).
    const nodes = try std.testing.allocator.dupe(types.FunctionNode, p.function_nodes);
    defer std.testing.allocator.free(nodes);
    const body = p.functions[widened.?].body;
    var redirected = false;
    for (nodes[body.start..body.end]) |*node| {
        if (node.node.kind == .function_value) {
            node.node.kind = .{ .function_value = @intCast(narrow.?) };
            redirected = true;
        }
    }
    try std.testing.expect(redirected);
    var forged = p;
    forged.function_nodes = nodes;
    try harness.invalid(h, forged);
}
