//! A program's own `ToString` (RFC-0053, B5): interpolation and `ToString(Value)` of a value
//! with no text of its own call the overload declared for its type, and `ToDiagnostic` prints
//! as it says. Nothing here is a new operation: the call lowers to an ordinary `call`, so the
//! harness's two machines and the replayed report check it as they check any function.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const modules = @import("modules.zig");
const nested = @import("nested_module_tests.zig");

test "interpolation and ToString reach the overload declared for a type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\point:=struct{X:i64,Y:i64}
        \\shade:=enum{Light,Dark}
        \\Thing:=class{Name:string}
        \\ToString(P:point)<computes>:string="({P.X},{P.Y})"
        \\ToString(S:shade)<computes>:string=If(S==shade.Light,"light","dark")
        \\ToString(T:Thing)<transacts>:string="Thing:"+T.Name
        \\ToString(Xs:[]i64)<computes>:string="n="+ToString(Xs.Length)
        \\Pt:point=point{X:=1,Y:=2}
        \\A<public>:string="{Pt}"
        \\B<public>:string="{shade.Dark} {Thing{Name:="a"}} {array{1,2,3}}"
        \\C<public>:string=ToString(Pt)+ToString(7)+ToString(1.5)+ToString(true)+ToString("s")+ToString('c')
        \\D<public>:string="[{Pt}] {ToString(Pt)} {7} {"x{Pt}"}"
    );
    try std.testing.expectEqualStrings("(1,2)", x.get("A").?.string);
    try std.testing.expectEqualStrings("dark Thing:a n=3", x.get("B").?.string);
    try std.testing.expectEqualStrings("(1,2)71.5truesc", x.get("C").?.string);
    try std.testing.expectEqualStrings("[(1,2)] (1,2) 7 x(1,2)", x.get("D").?.string);
}

test "a value with text of its own keeps it beside an overload for another type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\point:=struct{X:i64}
        \\ToString(V:point)<computes>:string="point"
        \\Pt:point=point{X:=1}
        \\A<public>:string="{7}{1.5}{true}{"s"}{'c'}"
        \\B<public>:string="{Pt}"
        \\C<public>:string=ToString(Pt)+ToString(8)
    );
    try std.testing.expectEqualStrings("71.5truesc", x.get("A").?.string);
    try std.testing.expectEqualStrings("point", x.get("B").?.string);
    try std.testing.expectEqualStrings("point8", x.get("C").?.string);
}

test "overloads are chosen by the type, and a subclass instance reaches its superclass's" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Shape:=class{Name:string}
        \\Circle:=class(Shape){}
        \\a:=struct{N:i64}
        \\b:=struct{N:i64,M:i64}
        \\ToString(S:Shape)<transacts>:string="shape "+S.Name
        \\ToString(V:a)<computes>:string="a{V.N}"
        \\ToString(V:b)<computes>:string="b{V.N}{V.M}"
        \\A<public>:string="{Shape{Name:="s"}}|{Circle{Name:="r"}}|{a{N:=1}}|{b{N:=2,M:=3}}"
    );
    try std.testing.expectEqualStrings("shape s|shape r|a1|b23", x.get("A").?.string);
}

test "a ToString of the program's own prints as ToDiagnostic" {
    const w = try @import("native_effect_tests.zig").World.create();
    defer w.destroy();
    _ = try w.expect(
        \\point:=struct{X:i64}
        \\other:=struct{X:i64}
        \\ToString(P:point)<computes>:string="point {P.X}"
        \\Pt:point=point{X:=4}
        \\A:=Print(ToDiagnostic(Pt))
        \\B:=Print(ToDiagnostic(other{X:=1}))
        \\C:=Print(ToDiagnostic(7))
    , "point 4\n<struct>\n7\n");
}

test "a ToString that cannot be called by interpolation is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        // Values that have a text of their own.
        .{ "ToString(X:i64)<computes>:string=\"x\"", .to_string_signature },
        .{ "ToString(X:float)<computes>:string=\"x\"", .to_string_signature },
        .{ "ToString(X:logic)<computes>:string=\"x\"", .to_string_signature },
        .{ "ToString(X:string)<computes>:string=\"x\"", .to_string_signature },
        .{ "ToString(X:char)<computes>:string=\"x\"", .to_string_signature },
        .{ "r:=type{_X:i64 where 0<=_X,_X<=9}\nToString(X:r)<computes>:string=\"x\"", .to_string_signature },
        // Not one value in, a string out, and no failure.
        .{ "p:=struct{X:i64}\nToString(P:p)<computes>:i64=1", .to_string_signature },
        .{ "p:=struct{X:i64}\nToString(P:p,Q:p)<computes>:string=\"x\"", .to_string_signature },
        .{ "p:=struct{X:i64}\nToString()<computes>:string=\"x\"", .to_string_signature },
        .{ "p:=struct{X:i64}\nToString(P:p)<computes><decides>:string=If(Require[P.X>0],\"x\",\"y\")", .to_string_signature },
        // Reserved for everything but a function of one value.
        .{ "var ToString:i64=1", .expected_name },
        .{ "ToString:=3", .expected_name },
        .{ "ToString:i64=3", .expected_name },
        .{ "F(ToString:i64)<computes>:i64=1", .expected_parameter },
        .{ "C:=class{V:i64}\nToString<constructor>(X:i64)<computes>:C=C{V:=X}", .expected_name },
        .{ "ToString[T:type](X:T)<computes>:string=\"x\"", .expected_name },
        .{ "p:=struct{X:i64}\n(P:p).ToString()<computes>:string=\"x\"", .expected_name },
        .{ "ToString:=class{V:i64}", .expected_name },
        // No overload for the type, or none at all.
        .{ "p:=struct{X:i64}\nq:=struct{X:i64}\nToString(P:p)<computes>:string=\"p\"\nA:string=\"{q{X:=1}}\"", .type_mismatch },
        .{ "p:=struct{X:i64}\nA:string=\"{p{X:=1}}\"", .type_mismatch },
        .{ "p:=struct{X:i64}\nA:string=ToString(p{X:=1})", .type_mismatch },
        // A twin definition, and a body that needs the text it is defining.
        .{ "p:=struct{X:i64}\nToString(P:p)<computes>:string=\"p\"\nToString(P:p)<computes>:string=\"q\"", .duplicate_name },
        .{ "p:=struct{X:i64}\nToString(P:p)<computes>:string=\"{P}\"", .type_mismatch },
        // The overload is a call, with the effects of one.
        .{ "p:=struct{X:i64}\nToString(P:p)<transacts>:string=\"p\"\nF(Q:p)<computes>:string=\"{Q}\"", .call_requires_transacts },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected ToString admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("ToString diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "generated records agree with a formatting oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x7b5);
    const random = prng.random();
    var source: [512]u8 = undefined;
    var expected: [128]u8 = undefined;
    for (0..200) |_| {
        const a = random.intRangeAtMost(i64, -100000, 100000);
        const b = random.intRangeAtMost(i64, -100, 100);
        const text = try std.fmt.bufPrint(&source, "p:=struct{{X:i64,Y:i64}}\nToString(P:p)<computes>:string=\"<{{P.X}}|{{P.Y}}>\"\nV:p=p{{X:={d},Y:={d}}}\nOut<public>:string=\"{{V}} {{p{{X:=V.Y,Y:=V.X}}}} {{V.X}}\"", .{ a, b });
        const want = try std.fmt.bufPrint(&expected, "<{d}|{d}> <{d}|{d}> {d}", .{ a, b, b, a, a });
        try std.testing.expectEqualStrings(want, (try h.execute(text)).get("Out").?.string);
    }
}

test "the overload of a module is reached by the code in it, below it, and through using" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source =
        \\Kit:=import{"kit/shapes.forb"}
        \\using{Kit.Geometry}
        \\P:Kit.Geometry.point=Kit.Geometry.point{x:=3,y:=4}
        \\Out<public>:string="p={P} n={5} {ToString(P)} {ToString(6)} {Kit.Geometry.ToString(P)}"
        },
        .{ .path = "kit/shapes.forb", .source =
        \\Geometry<public>:=module{
        \\  point<public>:=struct{x:i64=0,y:i64=0}
        \\  ToString<public>(P:point)<computes>:string="<{P.x}:{P.y}>"
        \\}
        },
    });
    try std.testing.expectEqualStrings("p=<3:4> n=5 <3:4> 6 <3:4>", x.get("Out").?.string);
    const y = try nested.one(h,
        \\Local:=module{
        \\  other<public>:=struct{z:i64}
        \\  ToString<public>(V:other)<computes>:string="z{V.z}"
        \\  Mine<public>()<computes>:string="{other{z:=1}}"
        \\  Deep<public>:=module{
        \\    Inner<public>()<computes>:string="{Local.other{z:=2}}!"
        \\  }
        \\}
        \\A<public>:string=Local.Mine()
        \\B<public>:string=Local.Deep.Inner()
        \\C<public>:string=Local.ToString(Local.other{z:=3})
    );
    try std.testing.expectEqualStrings("z1", y.get("A").?.string);
    try std.testing.expectEqualStrings("z2!", y.get("B").?.string);
    try std.testing.expectEqualStrings("z3", y.get("C").?.string);
}

const used_kit =
    \\T<public>:=module{
    \\  shape<public>:=struct{x:i64=0}
    \\}
    \\A<public>:=module{
    \\  point<public>:=struct{x:i64=0}
    \\  ToString<public>(P:point)<computes>:string="a"
    \\}
    \\B<public>:=module{
    \\  other<public>:=struct{z:i64=0}
    \\  ToString<public>(P:other)<computes>:string="b"
    \\}
    \\C<public>:=module{
    \\  ToString<public>(P:T.shape)<computes>:string="c"
    \\}
    \\D<public>:=module{
    \\  ToString<public>(P:T.shape)<computes>:string="d"
    \\}
    \\Hidden<public>:=module{
    \\  hid<public>:=struct{x:i64=0}
    \\  ToString(P:hid)<computes>:string="private"
    \\}
;

test "used modules are told apart by the type, and the built-in texts never depend on them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source =
        \\Kit:=import{"kit.forb"}
        \\using{Kit.A}
        \\using{Kit.B}
        \\P:Kit.A.point=Kit.A.point{}
        \\Q:Kit.B.other=Kit.B.other{}
        \\Out<public>:string="{P}{Q}{7}{ToString(7)}{ToString(P)}{ToString(Q)}"
        },
        .{ .path = "kit.forb", .source = used_kit },
    });
    try std.testing.expectEqualStrings("ab77ab", x.get("Out").?.string);
}

test "used modules that both take a type are ambiguous only for that type, and a private overload is not reached" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, ?types.Diagnostic.Code };
    for ([_]Case{
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.C}\nusing{Kit.D}\nS:Kit.T.shape=Kit.T.shape{}\nOut<public>:string=\"{S}\"", .ambiguous_call },
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.C}\nusing{Kit.D}\nS:Kit.T.shape=Kit.T.shape{}\nOut<public>:string=ToString(S)", .ambiguous_call },
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.C}\nusing{Kit.D}\nOut<public>:string=\"{7}\"+ToString(7)", null },
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.C}\nusing{Kit.A}\nS:Kit.T.shape=Kit.T.shape{}\nOut<public>:string=\"{S}\"", null },
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.Hidden}\nS:Kit.Hidden.hid=Kit.Hidden.hid{}\nOut<public>:string=\"{S}\"", .type_mismatch },
        .{ "Kit:=import{\"kit.forb\"}\nOut<public>:string=\"{Kit.A.point{}}\"", .type_mismatch },
        .{ "Kit:=import{\"kit.forb\"}\nusing{Kit.A}\nQ:Kit.A.point=Kit.A.point{}\nOut<public>:string=\"{Q}\"\nAgain<public>:string=Kit.B.ToString(Q)", .type_mismatch },
    }) |case| {
        const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{
            .{ .path = "main.forb", .source = case[0] },
            .{ .path = "kit.forb", .source = used_kit },
        } });
        if (case[1] == null) {
            if (result != .ok) std.debug.print("unexpected refusal of {s}: {s}\n", .{ case[0], result.failed.diagnostic.message() });
            try std.testing.expect(result == .ok);
            continue;
        }
        if (result == .ok) std.debug.print("unexpected admission: {s}\n", .{case[0]});
        try std.testing.expect(result == .failed);
        if (result.failed.diagnostic.code != case[1].?) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], result.failed.diagnostic.message() });
        try std.testing.expectEqual(case[1].?, result.failed.diagnostic.code);
    }
}

test "a ToString whose result is its body's type is a ToString too" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\point:=struct{X:i64}
        \\ToString(P:point)<computes> := "P{P.X}"
        \\bad:=struct{X:i64}
        \\A<public>:string="{point{X:=1}}"
    );
    try std.testing.expectEqualStrings("P1", x.get("A").?.string);
    try std.testing.expectEqual(types.Diagnostic.Code.to_string_signature, h.front.compile("point:=struct{X:i64}\nToString(P:point)<computes> := 3").failed.code);
}
