//! `Case` arms that bind: type tests, option and tuple shapes, record fields, `where` guards
//! and scrutinees that are expressions (RFC-0066).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const Expected = struct { []const u8, i64 };

fn expectIntegers(x: anytype, expected: []const Expected) !void {
    for (expected) |entry| {
        const value = x.get(entry[0]) orelse {
            std.debug.print("no binding {s}\n", .{entry[0]});
            return error.TestExpectedEqual;
        };
        if (value.integer != entry[1]) std.debug.print("binding {s}\n", .{entry[0]});
        try std.testing.expectEqual(entry[1], value.integer);
    }
}

fn count(program: types.Program, comptime tag: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    var total: usize = 0;
    for (program.nodes) |node| total += @intFromBool(node.kind == tag);
    for (program.function_nodes) |entry| total += @intFromBool(entry.node.kind == tag);
    return total;
}

const animals =
    \\Animal := class{ Name:string }
    \\Dog := class(Animal){ Tricks:i64 }
    \\Puppy := class<final>(Dog){ Weeks:i64 }
    \\Cat := class<final>(Animal){ Lives:i64 }
    \\Named := interface{ Label()<transacts>:string }
    \\Robot := class(Named){ Label<override>()<transacts>:string = "robot" }
    \\Parrot := class(Animal, Named){ Label<override>()<transacts>:string = "polly" }
    \\Rex := Dog{Name := "rex", Tricks := 3}
    \\Pup := Puppy{Name := "pup", Tricks := 1, Weeks := 8}
    \\Tom := Cat{Name := "tom", Lives := 9}
    \\Any := Animal{Name := "any"}
    \\Polly := Parrot{Name := "polly"}
    \\
;

test "type-test arms bind the narrowed instance and are tried in order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(animals ++
        \\Score(A:Animal)<transacts>:i64 = Case(A, D:Dog => D.Tricks, C:Cat => C.Lives, _ => 0)
        \\First(A:Animal)<transacts>:i64 = Case(A, P:Puppy => P.Weeks, D:Dog => D.Tricks * 10, _ => -1)
        \\Wide(A:Animal)<transacts>:i64 = Case(A, D:Dog where D.Tricks > 0 => D.Tricks * 10, P:Puppy => P.Weeks, _ => -1)
        \\Count(A:Animal)<transacts>:i64 = Case(A, _:Cat => 1, _:Dog => 2, Other:Animal => 3)
        \\Up(D:Dog)<transacts>:string = Case(D, A:Animal => A.Name)
        \\A:i64 = Score(Rex)
        \\B:i64 = Score(Tom)
        \\C:i64 = Score(Any)
        \\D:i64 = Score(Pup)
        \\E:i64 = First(Pup)
        \\F:i64 = First(Rex)
        \\G:i64 = Wide(Pup)
        \\H:i64 = Count(Tom) * 100 + Count(Pup) * 10 + Count(Any)
        \\I:string = Up(Pup)
    );
    // A puppy is a dog: the first arm that holds wins, whatever comes after it. (Without its
    // guard, `D:Dog` before `P:Puppy` leaves that arm unreachable: `subsumed_arm`, RFC-0090.)
    try expectIntegers(x, &.{ .{ "A", 3 }, .{ "B", 9 }, .{ "C", 0 }, .{ "D", 1 }, .{ "E", 8 }, .{ "F", 30 }, .{ "G", 10 }, .{ "H", 123 } });
    try std.testing.expectEqualStrings("pup", x.get("I").?.string);
}

test "type-test arms cast across interfaces" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(animals ++
        \\Say(N:Named)<transacts>:string = Case(N, R:Robot => R.Label() + "!", A:Animal => A.Name + "?", _ => "-")
        \\Tag(A:Animal)<transacts>:string = Case(A, N:Named => N.Label(), D:Dog => "dog", _ => "none")
        \\A:string = Say(Robot{})
        \\B:string = Say(Polly)
        \\C:string = Tag(Polly)
        \\D:string = Tag(Rex)
        \\E:string = Tag(Any)
    );
    try std.testing.expectEqualStrings("robot!", x.get("A").?.string);
    try std.testing.expectEqualStrings("polly?", x.get("B").?.string);
    try std.testing.expectEqualStrings("polly", x.get("C").?.string);
    try std.testing.expectEqualStrings("dog", x.get("D").?.string);
    try std.testing.expectEqualStrings("none", x.get("E").?.string);
}

test "a type-test arm lowers to instance_of, a branch and a downcast" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try h.compile(animals ++
        \\A:i64 = Case(Any, D:Dog => D.Tricks, C:Cat => C.Lives, _ => 0)
        \\M:option(i64) = option{4}
        \\B:i64 = Case(M, option{X} => X, option{} => 0)
    );
    // No attempt region, no demand and no aggregate carries a binding out of a test.
    try std.testing.expectEqual(@as(usize, 2), count(program, .instance_of));
    try std.testing.expectEqual(@as(usize, 2), count(program, .downcast));
    try std.testing.expectEqual(@as(usize, 3), count(program, .if_begin));
    try std.testing.expectEqual(@as(usize, 1), count(program, .option_present));
    try std.testing.expectEqual(@as(usize, 1), count(program, .option_value));
    try std.testing.expectEqual(@as(usize, 0), count(program, .attempt_begin));
    try std.testing.expectEqual(@as(usize, 0), count(program, .demand));
    const x = try h.run(program, 10_000);
    try expectIntegers(x.ok, &.{ .{ "A", 0 }, .{ "B", 4 } });
}

test "a forged arm whose test is skipped traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // The narrowing and the payload read carry no `demand`: the arm's test guards them. With the
    // test forged to `true` the machines' own checks are what stops the read.
    for ([_][]const u8{
        animals ++ "A:i64 = Case(Any, D:Dog => D.Tricks, _ => 0)",
        "M:option(i64) = option{}\nA:i64 = Case(M, option{X} => X, option{} => 0)",
    }) |source| {
        const p = try h.compile(source);
        const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
        defer std.testing.allocator.free(nodes);
        var tests: usize = 0;
        for (nodes) |*node| if (node.kind == .instance_of or node.kind == .option_present) {
            node.kind = .{ .boolean = true };
            tests += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), tests);
        var forged = p;
        forged.nodes = nodes;
        const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
        const actual = h.runtime.evaluate(forged, 4096);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, reference.failed.code);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, actual.failed.code);
        // Unforged, the same program runs.
        try expectIntegers((try h.run(p, 4096)).ok, &.{.{ "A", 0 }});
    }
}

test "a Case of constants over a name still compiles without the library block" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "N:i64=2\nA:i64=Case(N,1=>10,2=>20,_=>0)";
    const program = try h.compile(source);
    try std.testing.expectEqual(source.len, program.source.len);
    // A pattern arm makes the module carry it.
    const pattern = "N:i64=2\nA:i64=Case(N,X:i64 where X>1=>X,_=>0)";
    try std.testing.expect((try h.compile(pattern)).source.len > pattern.len);
}

test "option arms bind the payload match absence and are exhaustive together" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Inc(M:option(i64))<computes>:i64 = Case(M, option{X} => X + 1, option{} => 0)
        \\Dec(M:option(i64))<computes>:i64 = Case(M, option{} => 0, option{X} => X - 1)
        \\Zero(M:option(i64))<computes>:i64 = Case(M, option{0} => 100, option{X} where X < 0 => -X, option{_} => 1, option{} => 2)
        \\Deep(M:option(option(i64)))<computes>:i64 = Case(M, option{option{X}} => X, option{option{}} => -1, _ => -2)
        \\Name(M:option(string))<computes>:string = Case(M, option{"a"} => "first", option{S} => S + "!", option{} => "none")
        \\A:i64 = Inc(option{41})
        \\B:i64 = Inc(option{})
        \\C:i64 = Dec(option{41})
        \\D:i64 = Dec(option{})
        \\E:i64 = Zero(option{0}) + Zero(option{-7}) * 10 + Zero(option{5}) * 1000 + Zero(option{}) * 10000
        \\F:i64 = Deep(option{option{6}}) * 100 + Deep(option{option{}}) * 10 + Deep(option{})
        \\G:string = Name(option{"a"}) + Name(option{"b"}) + Name(option{})
    );
    try expectIntegers(x, &.{ .{ "A", 42 }, .{ "B", 0 }, .{ "C", 40 }, .{ "D", 0 }, .{ "E", 100 + 70 + 1000 + 20000 }, .{ "F", 600 - 10 - 2 } });
    try std.testing.expectEqualStrings("firstb!none", x.get("G").?.string);
}

test "tuple and record arms destructure constants wildcards and binders" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(animals ++
        \\Color := enum{Red, Green}
        \\Point := struct{ X:i64, Y:i64 }
        \\Line := struct{ From:Point, To:Point }
        \\Pick(P:tuple(i64,i64))<computes>:i64 = Case(P, tuple{0,Y} => Y, tuple{X,_} where X > 10 => X, tuple{X,Y} => X + Y)
        \\Mix(P:tuple(Color,logic,string))<computes>:string = Case(P, tuple{Color.Green,_,S} => "g" + S, tuple{_,true,"x"} => "tx", tuple{C,false,S} where C == Color.Red => "r" + S, _ => "?")
        \\Nest(P:tuple(option(i64),tuple(i64,i64)))<computes>:i64 = Case(P, tuple{option{N},tuple{0,B}} => N + B, tuple{option{},tuple{A,_}} => A, tuple{_,Rest} => Rest(1))
        \\Axis(P:Point)<computes>:i64 = Case(P, Point{X := 0, Y := 0} => 0, Point{X := 0, Y := V} => V, Point{Y := 0, X := V} => V * 10, Point{} => -1)
        \\Span(L:Line)<computes>:i64 = Case(L, Line{From := Point{X := A, Y := _}, To := Point{X := B, Y := _}} where B > A => B - A, _ => 0)
        \\Trick(A:Animal)<transacts>:i64 = Case(A, Puppy{Weeks := W, Tricks := T} => W * 100 + T, Dog{Tricks := 3} => 33, Dog{Tricks := T} => T, Animal{Name := "any"} => -1, _ => -2)
        \\A:i64 = Pick(tuple{0,7})
        \\B:i64 = Pick(tuple{20,7})
        \\C:i64 = Pick(tuple{2,7})
        \\D:string = Mix(tuple{Color.Green,true,"a"}) + Mix(tuple{Color.Red,true,"x"}) + Mix(tuple{Color.Red,false,"b"}) + Mix(tuple{Color.Red,true,"c"})
        \\E:i64 = Nest(tuple{option{5},tuple{0,2}}) * 100 + Nest(tuple{option{},tuple{3,4}}) * 10 + Nest(tuple{option{5},tuple{1,9}})
        \\F:i64 = Axis(Point{X := 0, Y := 0}) + Axis(Point{X := 0, Y := 4}) + Axis(Point{X := 5, Y := 0}) * 10 + Axis(Point{X := 1, Y := 1}) * 10000
        \\G:i64 = Span(Line{From := Point{X := 2, Y := 0}, To := Point{X := 9, Y := 0}}) + Span(Line{From := Point{X := 9, Y := 0}, To := Point{X := 2, Y := 0}})
        \\H:i64 = Trick(Pup) + Trick(Rex) * 10000 + Trick(Tom) * 1000000
        \\I:i64 = Trick(Dog{Name := "d", Tricks := 5}) * 10 + Trick(Any)
        \\J:i64 = Case(tuple{1,2,3}, tuple{_,_,_} => 1)
    );
    try expectIntegers(x, &.{ .{ "A", 7 }, .{ "B", 20 }, .{ "C", 9 }, .{ "E", 700 + 30 + 9 }, .{ "F", 4 + 500 - 10000 }, .{ "G", 7 }, .{ "H", 801 + 330000 - 2000000 }, .{ "I", 49 }, .{ "J", 1 } });
    try std.testing.expectEqualStrings("gatxrb?", x.get("D").?.string);
}

test "a guard sees the arm's bindings and a guard that does not hold keeps no effects" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64 = array{5, 6}
        \\var Cell:i64 = 0
        \\var Log:i64 = 0
        \\Bump(N:i64)<transacts>:i64 = Block{ set Cell = Cell + 1; N }
        \\Go(N:i64)<transacts>:i64 = Case(N, X:i64 where Bump(X) > 100 => 1, X:i64 where Bump(X) == 5 => 2, X:i64 where Bump(X) > 0 => 3, _ => 4)
        \\Index(N:i64)<computes>:i64 = Case(N, X:i64 where Items[X] > 5 => 1, X:i64 where Items[X - 7] > 4 => 2, _ => 3)
        \\Wild(N:i64)<computes>:i64 = Case(N, _ where N > 2 => 1, _ where N > 1 => 2, _ => 3)
        \\Then(N:i64)<transacts>:i64 = Case(N, X:i64 where X > 0 => Block{ set Log = Log + X; Log }, _ => Log)
        \\A:i64 = Go(5)
        \\B:i64 = Cell
        \\C:i64 = Go(-1)
        \\D:i64 = Cell
        \\E:i64 = Index(1) * 100 + Index(7) * 10 + Index(0)
        \\F:i64 = Wild(3) * 100 + Wild(2) * 10 + Wild(1)
        \\G:i64 = Then(4) + Then(0) * 10 + Then(6) * 100
    );
    // Go(5): the first guard ran and was undone, the second held and its write stays.
    // Go(-1): three guards ran and were undone.
    try expectIntegers(x, &.{ .{ "A", 2 }, .{ "B", 1 }, .{ "C", 4 }, .{ "D", 1 }, .{ "E", 123 }, .{ "F", 123 }, .{ "G", 4 + 40 + 1000 } });
}

test "a guard that writes what the pattern read does not change what the arm bound" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each part is read once, before the guard runs; the guard's writes stay when it holds.
    const x = try h.execute(animals ++
        \\Box := class{ var Maybe:option(i64), var V:i64 = 1 }
        \\Holder := class{ var A:Animal }
        \\Pair := class{ var L:i64, var R:i64 }
        \\Clear(B:Box)<transacts>:logic = Block{ set B.Maybe = option{}; true }
        \\Bump(B:Box)<transacts>:logic = Block{ set B.V = B.V + 100; true }
        \\Swap(H:Holder)<transacts>:logic = Block{ set H.A = Tom; true }
        \\Turn(P:Pair)<transacts>:logic = Block{ T := P.L; set P.L = P.R; set P.R = T; T > 0 }
        \\B := Box{Maybe := option{4}}
        \\H := Holder{A := Rex}
        \\P := Pair{L := 1, R := 2}
        \\A:i64 = Case(B, Box{Maybe := option{X}} where Clear(B) => X, _ => -1)
        \\C:i64 = Case(B, Box{Maybe := option{X}} where Clear(B) => X, Box{Maybe := option{}} => -2, _ => -1)
        \\D:i64 = Case(H, Holder{A := Dg:Dog} where Swap(H) => Dg.Tricks, _ => -1)
        \\E:i64 = Case(H, Holder{A := Dg:Dog} where Swap(H) => Dg.Tricks, Holder{A := Ct:Cat} => Ct.Lives, _ => -1)
        \\F:i64 = Case(B, Box{V := 1} where Bump(B) => 10, _ => -1)
        \\G:i64 = Case(B, Box{V := X} where Bump(B) and X < 150 => X, _ => -1)
        \\I:i64 = B.V
        \\J:i64 = Case(P, Pair{L := L, R := R} where Turn(P) => L * 10 + R, _ => -1)
        \\K:i64 = P.L * 10 + P.R
        \\L:i64 = Case(P, Pair{L := Lf, R := R} where Turn(P) and Lf > 5 => Lf, Pair{L := Lf, R := R} => Lf * 10 + R)
        \\M:i64 = Case(tuple{P, B}, tuple{Pair{L := Lf}, Box{V := V}} where Turn(P) and Bump(B) and V > 1000 => 0, tuple{Pair{L := Lf}, Box{V := V}} => Lf * 1000 + V)
    );
    // L and M: the guard wrote and then did not hold, so the next arm reads the state before it.
    try expectIntegers(x, &.{ .{ "A", 4 }, .{ "C", -2 }, .{ "D", 3 }, .{ "E", 9 }, .{ "F", 10 }, .{ "G", 101 }, .{ "I", 201 }, .{ "J", 12 }, .{ "K", 21 }, .{ "L", 21 }, .{ "M", 2201 } });
}

test "a guard that can fail leaves the conditions around its Case as they were" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64 = array{5, 6}
        \\Big(N:i64)<computes>:logic = N > 3
        \\F(N:i64)<computes>:i64 = If(Items[N] > Case(N + 1, X:i64 where Items[X] > 5 => 1, _ => 2), 10, 20)
        \\G(N:i64)<computes>:i64 = If(Items[N] > 0 and Case(N + 1, X:i64 where Big(X) => true, _ => false), 10, 20)
        \\H(N:i64)<computes>:i64 = If(Case(N + 1, X:i64 where Items[X] > 5 => Items[X + 5] > 100, _ => false), 1, 2)
        \\A:i64 = F(7) + F(0) * 10 + F(1) * 100
        \\B:i64 = G(7) + G(0) * 10
        \\C:i64 = H(0) + H(7) * 10
    );
    // F(7), G(7): the user's own index fails and selects the else value. H(0): the guard holds
    // and the selected arm's index fails, which is the failure of the condition, not of the guard.
    try expectIntegers(x, &.{ .{ "A", 20 + 100 + 1000 }, .{ "B", 20 + 200 }, .{ "C", 2 + 20 } });
}

test "a value named where is still a constant pattern" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\where:i64 = 3
        \\A:i64 = Case(3, where => 1, _ => 2)
        \\N:i64 = 3
        \\B:i64 = Case(N, where => 1, _ => 2)
        \\C:i64 = Case(N, where + 1 => 1, X:i64 where X == where => 5, _ => 2)
    );
    try expectIntegers(x, &.{ .{ "A", 1 }, .{ "B", 1 }, .{ "C", 5 } });
    // The classic form with such a constant still carries no library block.
    const source = "where:i64=3\nN:i64=3\nA:i64=Case(N,where=>1,_=>2)";
    try std.testing.expectEqual(source.len, (try h.compile(source)).source.len);
}

test "shapes nest exactly eight deep whatever they are" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [2048]u8 = undefined;
    const Nesting = struct { open: []const u8, close: []const u8, type_open: []const u8, type_close: []const u8 };
    for ([_]Nesting{
        .{ .open = "option{", .close = "}", .type_open = "option(", .type_close = ")" },
        .{ .open = "tuple{", .close = ",_}", .type_open = "tuple(", .type_close = ",i64)" },
    }) |shape| {
        for ([_]usize{ 8, 9 }) |levels| {
            // Once as a tested arm with a default, once as a last arm that must be total.
            for ([_]bool{ true, false }) |defaulted| {
                var writer: std.Io.Writer = .fixed(&buffer);
                try writer.writeAll("F(P:");
                for (0..levels) |_| try writer.writeAll(shape.type_open);
                try writer.writeAll("i64");
                for (0..levels) |_| try writer.writeAll(shape.type_close);
                try writer.writeAll(")<computes>:i64=Case(P,");
                if (!defaulted and shape.open[0] == 'o') try writer.writeAll("option{}=>0,");
                for (0..levels) |_| try writer.writeAll(shape.open);
                try writer.writeAll("X");
                for (0..levels) |_| try writer.writeAll(shape.close);
                try writer.writeAll(if (defaulted) " where X>0=>X,_=>0)" else "=>X)");
                const r = h.front.compile(writer.buffered());
                // An option nested in an option is not derived total, at any depth.
                if (!defaulted and shape.open[0] == 'o') {
                    try std.testing.expectEqual(types.Diagnostic.Code.case_not_exhaustive, r.failed.code);
                    continue;
                }
                if (levels == 9) {
                    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{writer.buffered()});
                    try std.testing.expectEqual(types.Diagnostic.Code.expression_limit, r.failed.code);
                    continue;
                }
                if (r != .ok) std.debug.print("rejected {s}: {s}\n", .{ writer.buffered(), r.failed.message() });
                try std.testing.expect(r == .ok);
            }
        }
    }
}

test "the scrutinee is any expression and is evaluated exactly once" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Color := enum{Red, Green, Blue}
        \\Box := class{ var Maybe:option(i64) }
        \\var Calls:i64 = 0
        \\Next(N:i64)<transacts>:i64 = Block{ set Calls = Calls + 1; N }
        \\Tint(N:i64)<computes>:Color = If(N > 1, Color.Blue, If(N > 0, Color.Green, Color.Red))
        \\Clear(B:Box)<transacts>:logic = Block{ set B.Maybe = option{}; true }
        \\Plain(N:i64)<transacts>:i64 = Case(Next(N) + 1, 1 => 10, 2 => 20, 3 => 30, _ => 0)
        \\Bound(N:i64)<transacts>:i64 = Case(Next(N) * 2, X:i64 where X > 100 => 1, X:i64 where X > 10 => X, X:i64 => -X)
        \\Name(N:i64)<computes>:string = Case(Tint(N), Color.Red => "r", Color.Green => "g", Color.Blue => "b")
        \\Mixed(N:i64)<computes>:i64 = Case(Tint(N), Color.Blue => 3, C:Color where N < 0 => 9, Color.Red => 1, Color.Green => 2)
        \\B := Box{Maybe := option{4}}
        \\A:i64 = Plain(2)
        \\C:i64 = Bound(7) * 100 + Bound(2)
        \\D:i64 = Calls
        \\E:string = Name(0) + Name(1) + Name(2)
        \\F:i64 = Mixed(2) * 100 + Mixed(-5) * 10 + Mixed(1)
        \\G:i64 = Case(B.Maybe, option{X} where Clear(B) => X, _ => -1)
        \\H:i64 = Case(B.Maybe, option{X} => X, option{} => -2)
        \\I:i64 = Case(Case(3, X:i64 where X > 2 => option{X}, _ => option{}), option{Y} where Case(Y, 3 => true, _ => false) => Case(tuple{Y, Y}, tuple{3, Z} => Z * 7, _ => 0), _ => -1)
    );
    // G: the guard empties the box after the payload was matched; the arm still sees 4.
    try expectIntegers(x, &.{ .{ "A", 30 }, .{ "C", 1396 }, .{ "D", 3 }, .{ "F", 392 }, .{ "G", 4 }, .{ "H", -2 }, .{ "I", 21 } });
    try std.testing.expectEqualStrings("rgb", x.get("E").?.string);
}

test "only the selected arm runs and its failure is not caught" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64 = array{5}
        \\var Cell:i64 = 0
        \\Tick(N:i64)<transacts>:i64 = Block{ set Cell = Cell + 1; N }
        \\Go(M:option(i64))<transacts>:i64 = Case(M, option{0} => 1 / 0, option{X} where X > 5 => Tick(X), option{X} => Tick(-X), option{} => 0 / 0)
        \\At(M:option(i64))<computes>:i64 = Attempt(Case(M, option{X} => Items[X], option{} => 0), -1)
        \\A:i64 = Go(option{9})
        \\B:i64 = Go(option{2})
        \\C:i64 = Cell
        \\D:i64 = At(option{0}) * 100 + At(option{4}) * 10 + At(option{})
    );
    try expectIntegers(x, &.{ .{ "A", 9 }, .{ "B", -2 }, .{ "C", 2 }, .{ "D", 500 - 10 + 0 } });
    // Outside a failure context the arm's failable value is the usual error.
    const r = h.front.compile("Items:[]i64=array{5}\nA:i64=Case(option{4},option{X}=>Items[X],option{}=>0)");
    try std.testing.expectEqual(types.Diagnostic.Code.failure_context_required, r.failed.code);
    // An arm that is selected fails like any expression.
    const p = try h.compile("M:option(i64)=option{0}\nA:i64=Case(M,option{X} where X==0=>1/X,_=>0)");
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(p, 1000)).failed.code);
}

test "an arm's names are visible only in its own guard and value, and may not shadow a visible name" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076: a pattern binder may not have the name of a module binding, a parameter, a local
    // or a binder of an arm around it; two arms side by side may still use one name.
    const x = try h.execute(
        \\X:i64 = 1000
        \\Shadow(Z:i64, M:option(i64))<computes>:i64 = Case(M, option{W} where W > 0 => W, option{W} => W - 1, option{} => Z)
        \\Outer(M:option(i64))<computes>:i64 = Case(M, option{Y} => Y, option{} => X)
        \\Again(P:tuple(i64,i64))<computes>:i64 = Case(P, tuple{A,B} where A > B => Case(tuple{B,A}, tuple{Lo,Hi} => Lo * 10 + Hi), tuple{A,_} => A)
        \\Local(N:i64)<computes>:i64 = Block{ T := 7; Case(N + T, U:i64 where U > 10 => U, _ => T) }
        \\A:i64 = Shadow(1, option{2}) * 100 + Shadow(1, option{-2}) * 10 + Shadow(1, option{})
        \\B:i64 = Outer(option{}) + Outer(option{3})
        \\C:i64 = Again(tuple{5,2}) * 10 + Again(tuple{2,5})
        \\D:i64 = Local(5) * 10 + Local(1)
    );
    try expectIntegers(x, &.{ .{ "A", 200 - 30 + 1 }, .{ "B", 1003 }, .{ "C", 252 }, .{ "D", 127 } });
    const Bad = struct { []const u8, types.Diagnostic.Code };
    for ([_]Bad{
        // A name bound by one arm is unknown in the next, in the default and after the Case.
        .{ "N:i64=3\nA:i64=Case(N,X:i64 where X>5=>X,_=>X)", .unknown_name },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X}=>X,option{}=>X)", .unknown_name },
        .{ "N:i64=3\nA:i64=Case(N,X:i64=>X)+X", .unknown_name },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X} where Y>0=>X,option{Y}=>Y,option{}=>0)", .unknown_name },
        // The temporary and the pattern forms are the library's alone.
        .{ "N:i64=3\nA:i64=Case(N,X:i64=>__case_s)", .unknown_name },
        .{ "M:option(i64)=option{1}\nA:logic=Case(M,option{X}=>__case_some(M),option{}=>false)", .unknown_name },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{__x}=>1,option{}=>0)", .expected_name },
        // A reserved word is a constant, never a binder.
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{true}=>1,_=>0)", .type_mismatch },
        // One pattern binds a name once.
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{X,X}=>X)", .duplicate_name },
        // A binder may not shadow (RFC-0076): an earlier module binding, a parameter, the
        // binder of an arm around it, a local.
        .{ "X:i64=1000\nF(M:option(i64))<computes>:i64=Case(M,option{X}=>X,option{}=>0)", .shadowed_name },
        .{ "F(X:i64,M:option(i64))<computes>:i64=Case(M,option{X}=>X,option{}=>X)", .shadowed_name },
        .{ "F(P:tuple(i64,i64))<computes>:i64=Case(P,tuple{A,B} where A>B=>Case(tuple{B,A},tuple{A,B}=>A*10+B),tuple{A,_}=>A)", .shadowed_name },
        .{ "F(N:i64)<computes>:i64=Block{T:=7;Case(N+T,T:i64 where T>10=>T,_=>T)}", .shadowed_name },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
    }
}

test "a Case without a default must be shown to cover every value" {
    const h = try harness.create();
    defer scratch.release(h);
    const Bad = struct { []const u8, types.Diagnostic.Code };
    const classes = "Animal:=class{Name:string}\nDog:=class(Animal){Tricks:i64}\nCat:=class(Animal){Lives:i64}\nRock:=class{W:i64}\nPoint:=struct{X:i64,Y:i64}\nOther:=struct{X:i64}\nColor:=enum{Red,Green,Blue}\n";
    for ([_]Bad{
        // Classes are open: listing the subclasses that exist proves nothing.
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,D:Dog=>1,C:Cat=>2)", .case_not_exhaustive },
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,D:Dog=>1,X:Animal where X.Name==\"a\"=>2)", .case_not_exhaustive },
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,Dog{Tricks:=T}=>T)", .case_not_exhaustive },
        .{ classes ++ "F(P:tuple(Animal,i64))<transacts>:i64=Case(P,tuple{D:Dog,_}=>1)", .case_not_exhaustive },
        .{ classes ++ "F(P:tuple(Animal,i64))<transacts>:i64=Case(P,tuple{_:Dog,_}=>1)", .case_not_exhaustive },
        .{ classes ++ "F(M:option(Animal))<transacts>:i64=Case(M,option{}=>0,option{D:Dog}=>1)", .case_not_exhaustive },
        // An option needs both arms, unguarded, and a present arm that takes any payload.
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X}=>X)", .case_not_exhaustive },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{}=>0)", .case_not_exhaustive },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X} where X>0=>X,option{}=>0)", .case_not_exhaustive },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{0}=>5,option{}=>0)", .case_not_exhaustive },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{} where true=>0,option{X}=>X)", .case_not_exhaustive },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X}=>X,option{} where true=>0)", .case_not_exhaustive },
        .{ "M:option(option(i64))=option{}\nA:i64=Case(M,option{option{X}}=>X,option{option{}}=>1,option{}=>2)", .case_not_exhaustive },
        // Tuples and constants.
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{0,Y}=>Y)", .case_not_exhaustive },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{X,Y} where X>Y=>X)", .case_not_exhaustive },
        .{ "N:i64=3\nA:i64=Case(N+1,4=>10,5=>20)", .case_not_exhaustive },
        .{ "N:i64=3\nA:i64=Case(N,X:i64 where X>1=>10)", .case_not_exhaustive },
        .{ "N:i64=3\nA:i64=Case(N,_ where N>1=>10)", .case_not_exhaustive },
        // The enum rule counts unguarded constants only.
        .{ classes ++ "C:=Color.Red\nA:i64=Case(C,Color.Red=>1,Color.Green where 1>0=>2,Color.Blue=>3)", .case_not_exhaustive },
        .{ classes ++ "C:=Color.Red\nA:i64=Case(C,Color.Red=>1,X:Color where 1>0=>2,Color.Blue=>3)", .case_not_exhaustive },
        // An arm that takes every value ends the Case.
        .{ "N:i64=3\nA:i64=Case(N,_=>1,X:i64=>2)", .case_arms },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{X,Y}=>X,tuple{0,_}=>3)", .case_arms },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{_,_}=>1,_=>3)", .case_arms },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
    }
    // What is accepted: a last arm that the static type alone satisfies.
    const x = try h.execute(classes ++
        \\Rex := Dog{Name := "rex", Tricks := 3}
        \\F(A:Animal)<transacts>:i64 = Case(A, D:Dog => 1, X:Animal => 2)
        \\G(D:Dog)<transacts>:i64 = Case(D, Dog{Tricks := 0} => 0, Animal{Name := N} where N == "rex" => 5, Dog{Tricks := T} => T)
        \\H(P:tuple(Dog,Point))<transacts>:i64 = Case(P, tuple{_,Point{X := 0, Y := _}} => 0, tuple{A:Animal,Point{X := V}} => V)
        \\I(M:option(Dog))<transacts>:i64 = Case(M, option{} => 0, option{A:Animal} => 1)
        \\A:i64 = F(Rex) * 10 + F(Cat{Name := "c", Lives := 1})
        \\B:i64 = G(Rex) * 10 + G(Dog{Name := "d", Tricks := 7})
        \\C:i64 = H(tuple{Rex, Point{X := 4, Y := 0}})
        \\D:i64 = I(option{Rex}) + I(option{})
    );
    try expectIntegers(x, &.{ .{ "A", 12 }, .{ "B", 57 }, .{ "C", 4 }, .{ "D", 1 } });
}

test "malformed and ill-typed patterns are exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Bad = struct { []const u8, types.Diagnostic.Code };
    const classes = "Animal:=class{Name:string}\nDog:=class(Animal){Tricks:i64}\nCat:=class<final>(Animal){Lives:i64}\nRock:=class{W:i64}\nNamed:=interface{Label()<transacts>:string}\nPoint:=struct{X:i64,Y:i64}\nOther:=struct{X:i64}\n";
    for ([_]Bad{
        // A class the scrutinee can never be is the cast's diagnostic.
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,D:Dog=>1,R:Rock=>2,_=>0)", .type_mismatch },
        .{ classes ++ "F(C:Cat)<transacts>:i64=Case(C,N:Named=>1,_=>0)", .type_mismatch },
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,Rock{W:=V}=>V,_=>0)", .type_mismatch },
        .{ classes ++ "F(A:Animal)<transacts>:i64=Case(A,D:Missing=>1,_=>0)", .unsupported_type },
        .{ "N:i64=3\nA:i64=Case(N,X:string=>1,_=>0)", .type_mismatch },
        .{ "N:i64=3\nA:i64=Case(N,option{X}=>X,_=>0)", .type_mismatch },
        .{ "N:i64=3\nA:i64=Case(N,option{}=>1,_=>0)", .type_mismatch },
        .{ "N:i64=3\nA:i64=Case(N,tuple{X,_} where X>0=>X,_=>0)", .type_mismatch },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{\"a\"}=>1,_=>0)", .type_mismatch },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X}=>X,option{}=>\"x\")", .type_mismatch },
        // A tuple pattern names every element.
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{0}=>1,_=>0)", .type_mismatch },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{_,_,0}=>1,_=>0)", .type_mismatch },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{_,_,_} where true=>1,_=>0)", .type_mismatch },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{_,_,_}=>1)", .type_mismatch },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{}=>1,_=>0)", .case_pattern },
        .{ "P:tuple(i64,i64)=tuple{1,2}\nA:i64=Case(P,tuple{1,,2}=>1,_=>0)", .case_pattern },
        // Records.
        .{ classes ++ "P:=Point{X:=1,Y:=2}\nA:i64=Case(P,Other{X:=V}=>V,_=>0)", .type_mismatch },
        .{ classes ++ "P:=Point{X:=1,Y:=2}\nA:i64=Case(P,Point{X:=V,Z:=W}=>V)", .unknown_field },
        .{ classes ++ "P:=Point{X:=1,Y:=2}\nA:i64=Case(P,Point{X}=>1,_=>0)", .case_pattern },
        .{ classes ++ "P:=Point{X:=1,Y:=2}\nA:i64=Case(P,Point{X:=}=>1,_=>0)", .case_pattern },
        // Guards.
        .{ "N:i64=3\nA:i64=Case(N,X:i64 where X=>1,_=>0)", .type_mismatch },
        .{ "Id(N:i64)<computes>:i64=N\nN:i64=3\nA:i64=Case(N,X:i64 where Id(X)=>1,_=>0)", .type_mismatch },
        .{ "N:i64=3\nA:i64=Case(N,X:i64 where=>1,_=>0)", .case_arms },
        // First in an arm `where` is a value of that name, so this is not a constant pattern.
        .{ "N:i64=3\nA:i64=Case(N,where N>1=>1,_=>0)", .case_pattern },
        // What follows the colon of a typed pattern is a type.
        .{ "N:i64=3\nA:i64=Case(N,X:5=>1,_=>0)", .case_pattern },
        .{ "N:i64=3\nA:i64=Case(N,X:i64+1=>1,_=>0)", .case_pattern },
        .{ "N:i64=3\nA:i64=Case(N,X:\"i64\"=>1,_=>0)", .case_pattern },
        // Shapes that are not patterns.
        .{ "N:i64=3\nA:i64=Case(N,array{X}=>1,_=>0)", .case_pattern },
        .{ "N:i64=3\nA:i64=Case(N,map{}=>1,_=>0)", .case_pattern },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{1,2}=>1,_=>0)", .case_pattern },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{Abs(1)}=>1,_=>0)", .case_pattern },
        .{ "M:option(i64)=option{1}\nA:i64=Case(M,option{X}+1=>1,_=>0)", .case_pattern },
        .{ "N:i64=3\nA:i64=Case(N,X:i64=>1=>2,_=>0)", .case_arms },
        .{ "N:i64=3\nA:i64=Case(,X:i64=>1,_=>0)", .case_scrutinee },
        // Shapes nest eight deep.
        .{ "N:i64=3\nA:i64=Case(N,tuple{tuple{tuple{tuple{tuple{tuple{tuple{tuple{tuple{X,_},_},_},_},_},_},_},_},_} where X>0=>X,_=>0)", .expression_limit },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "pattern Cases nest in functions methods loops and conditions" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]option(i64) = array{option{1}, option{}, option{3}}
        \\Counter := class{
        \\    var N:i64 = 0
        \\    Kind(M:option(i64))<transacts>:i64 = Case(M, option{X} where X > Self.N => Block{ set Self.N = X; 1 }, option{_} => 2, option{} => 3)
        \\}
        \\Default[T:type](M:option(T), D:T)<computes>:T{Case(M, option{X} => X, option{} => D)}
        \\Check(B:logic)<computes>:logic = B
        \\Keep[T:type](M:option(T), D:T, Ok:logic)<computes>:T{Case(M, option{X} where Check(Ok) => X, _ => D)}
        \\Swap[A:type, B:type](P:tuple(A,B), Ok:logic)<computes>:option(tuple(B,A)){Case(P, tuple{X,Y} where Check(Ok) => option{tuple{Y,X}}, _ => option{})}
        \\K:i64 = Keep[i64](option{4}, 0, true) * 10 + Keep[i64](option{4}, 1, false)
        \\L:string = Keep[string](option{"k"}, "d", true) + Attempt(Swap[i64,string](tuple{1,"s"}, true)?(0), "none") + Attempt(Swap[i64,string](tuple{1,"s"}, false)?(0), "none")
        \\Depth(M:option(option(i64)))<computes>:i64 = Case(M,
        \\    option{Inner} => Case(Inner,
        \\        option{X} where X > 0 => Case(X, 1 => 10, 2 => 20, _ => X),
        \\        option{_} => 0,
        \\        option{} => -1),
        \\    option{} => -2)
        \\C := Counter{}
        \\A:i64 = C.Kind(option{5}) * 100 + C.Kind(option{5}) * 10 + C.Kind(option{})
        \\B:i64 = C.N
        \\D:[]i64 = For(M:Items, Case(M, option{X} where X > 2 => X * 10, option{X} => X, option{} => -1))
        \\E:i64 = If(X := Items[0], Y := X?, Case(Y, V:i64 where V > 0 => V, _ => 0), -5)
        \\F:i64 = Case(For(M:Items, 1).Length, 3 => 30, _ => 0)
        \\G:i64 = Default[i64](option{4}, 0) + Default[i64](option{}, 10)
        \\H:string = Default[string](option{}, "d")
        \\I:i64 = Depth(option{option{2}}) + Depth(option{option{7}}) * 100 + Depth(option{option{-1}}) + Depth(option{option{}}) * 1000 + Depth(option{}) * 10000
        \\J:string = Case(E, V:i64 where V > 0 => "big {V}", _ => "small")
    );
    try expectIntegers(x, &.{ .{ "A", 123 }, .{ "B", 5 }, .{ "E", 1 }, .{ "F", 30 }, .{ "G", 14 }, .{ "I", 20 + 700 + 0 - 1000 - 20000 } });
    const loop = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(i64, 1), loop[0].integer);
    try std.testing.expectEqual(@as(i64, -1), loop[1].integer);
    try std.testing.expectEqual(@as(i64, 30), loop[2].integer);
    try std.testing.expectEqualStrings("d", x.get("H").?.string);
    try std.testing.expectEqualStrings("big 1", x.get("J").?.string);
    // A guard with a call carries its names out of its attempt, in a specialization too.
    try expectIntegers(x, &.{.{ "K", 41 }});
    try std.testing.expectEqualStrings("ksnone", x.get("L").?.string);
}

test "patterns span lines take contextual types and tuples wider than the fixed numerals" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Point := struct{ X:i64, Y:i64 }
        \\M:option(i64) = option{1}
        \\Wide := tuple{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20}
        \\Empty:[]i64 = Case(M, option{X} where X > 5 => array{}, option{X} => array{X}, option{} => array{})
        \\Gone:option(i64) = Case(M, option{_} => option{}, option{} => option{})
        \\Sure(N:option(i64))<computes><decides>:i64 = Case(N, option{X} where X > 0 => X, option{_} => Fail["negative"], option{} => 0)
        \\A:i64 = Case(Wide, tuple{_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,X,21} => -X, tuple{_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,X,Y} => X * 100 + Y)
        \\B:i64 = Case(tuple{1, 2}, tuple{
        \\    1,
        \\    Y
        \\  } where
        \\    Y > 1
        \\    => Y,
        \\  tuple{X, _}
        \\    => X)
        \\C:i64 = Case(Point{X := 1, Y := 2}, Point{
        \\    X := 1,
        \\    Y := V
        \\  } => V, _ => 0)
        \\D:i64 = Attempt(Sure[option{-1}], -9) * 10 + Attempt(Sure[option{4}], -9)
        \\E:i64 = Case(M, X:option(i64) where true => 1, _ => 0) + Case(1, X:i64 where X > 1 => X, _ => 0) * 10 + (Case(M, option{1} => 7, _ => 0)) * 100
        \\F:i64 = Empty.Length + Case(Gone, option{_} => 10, option{} => 20)
    );
    try expectIntegers(x, &.{ .{ "A", 1920 }, .{ "B", 2 }, .{ "C", 2 }, .{ "D", -86 }, .{ "E", 701 }, .{ "F", 21 } });
}

test "an expression evaluator walks a class hierarchy with type-test arms" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Expr := class<abstract>{}
        \\Num := class<final>(Expr){ Value:i64 }
        \\Add := class<final>(Expr){ Left:Expr, Right:Expr }
        \\Mul := class<final>(Expr){ Left:Expr, Right:Expr }
        \\Neg := class<final>(Expr){ Inner:Expr }
        \\Lit(V:i64)<transacts>:Expr = Num{Value := V}
        \\Sum(L:Expr, R:Expr)<transacts>:Expr = Add{Left := L, Right := R}
        \\Product(L:Expr, R:Expr)<transacts>:Expr = Mul{Left := L, Right := R}
        \\Eval(E:Expr)<transacts>:i64 = Case(E,
        \\    N:Num => N.Value,
        \\    A:Add => Eval(A.Left) + Eval(A.Right),
        \\    M:Mul => Eval(M.Left) * Eval(M.Right),
        \\    Neg{Inner := I} => -Eval(I),
        \\    _ => 0)
        \\Simplify(E:Expr)<transacts>:Expr = Case(E,
        \\    Add{Left := Num{Value := 0}, Right := R} => Simplify(R),
        \\    Add{Left := L, Right := Num{Value := 0}} => Simplify(L),
        \\    Mul{Left := Num{Value := 1}, Right := R} => Simplify(R),
        \\    Mul{Left := Num{Value := 0}, Right := _} => Lit(0),
        \\    Neg{Inner := Neg{Inner := I}} => Simplify(I),
        \\    Add{Left := L, Right := R} => Sum(Simplify(L), Simplify(R)),
        \\    Mul{Left := L, Right := R} => Product(Simplify(L), Simplify(R)),
        \\    _ => E)
        \\Size(E:Expr)<transacts>:i64 = Case(E, Add{Left := L, Right := R} => 1 + Size(L) + Size(R), Mul{Left := L, Right := R} => 1 + Size(L) + Size(R), Neg{Inner := I} => 1 + Size(I), _ => 1)
        \\Two := Num{Value := 2}
        \\Tree:Expr = Add{Left := Mul{Left := Num{Value := 1}, Right := Add{Left := Num{Value := 0}, Right := Two}}, Right := Neg{Inner := Neg{Inner := Mul{Left := Num{Value := 3}, Right := Num{Value := 4}}}}}
        \\Small:Expr = Simplify(Tree)
        \\A:i64 = Eval(Tree)
        \\B:i64 = Eval(Small)
        \\C:i64 = Size(Tree)
        \\D:i64 = Size(Small)
        \\E:i64 = Eval(Simplify(Mul{Left := Num{Value := 0}, Right := Tree}))
    );
    // 1*(0+2) + --(3*4) = 14; simplified to 2 + 3*4.
    try expectIntegers(x, &.{ .{ "A", 14 }, .{ "B", 14 }, .{ "C", 11 }, .{ "D", 5 }, .{ "E", 0 } });
}

test "pattern Cases compile inside an imported module" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "S:=import{\"shapes.forb\"}\nA:i64=S.Area(S.Square{Side:=3})+S.Area(S.Rect{W:=2,H:=5})*100\nD:i64=S.Area(S.Rect{W:=2,H:=2})+Case(S.Half(option{8}),option{X} where S.Same(X,4)=>1,_=>0)\nB:i64=Case(S.Half(option{8}),option{X} where X>3=>X,_=>0)\nC:i64=Case(S.Square{Side:=4},S.Square{Side:=V}=>V)" },
        .{ .path = "shapes.forb", .source = "Shape<public>:=class{}\nSquare<public>:=class(Shape){Side<public>:i64}\nRect<public>:=class(Shape){W<public>:i64,H<public>:i64}\nSame<public>(A:i64,B:i64)<computes>:logic=A==B\nArea<public>(X:Shape)<transacts>:i64=Case(X,Q:Square=>Q.Side*Q.Side,Rect{W:=W,H:=H} where Same(W,H)=>W*W*1000,Rect{W:=W,H:=H}=>W*H,_=>0)\nHalf<public>(M:option(i64))<computes>:option(i64)=Case(M,option{X}=>option{X/2},option{}=>option{})" },
    };
    const x = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok, 10_000)).ok;
    try expectIntegers(x, &.{ .{ "A", 1009 }, .{ "B", 4 }, .{ "C", 4 }, .{ "D", 4001 } });
}

test "arms nest one conditional each up to the bootstrap control depth" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [4096]u8 = undefined;
    for ([_]usize{ types.limits.control_depth, types.limits.control_depth + 1 }) |arms| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll("F(M:option(i64))<computes>:i64=Case(M");
        // The first arm tests presence and its guard, one conditional inside the other.
        for (0..arms - 1) |arm| try writer.print(",option{{X}} where X=={d}=>{d}", .{ arm, arm * 2 });
        try writer.print(",_=>-1)\nA:i64=F(option{{{d}}})\nB:i64=F(option{{}})", .{arms - 2});
        const r = h.front.compile(writer.buffered());
        if (arms > types.limits.control_depth) {
            try std.testing.expectEqual(types.Diagnostic.Code.control_limit, r.failed.code);
            continue;
        }
        const x = (try h.run(r.ok, 100_000)).ok;
        try expectIntegers(x, &.{ .{ "A", @intCast((arms - 2) * 2) }, .{ "B", -1 } });
    }
}

/// What an arm of the oracle test matches. `none` and `some_any` together cover an option.
const Shape = enum { none, some_any, some_constant, some_guarded, pair_constant_left, pair_constant_right, pair_guarded };

const Sample = struct { present: bool, left: i64, right: i64 };

fn matches(shape: Shape, constant: i64, sample: Sample) bool {
    return switch (shape) {
        .none => !sample.present,
        .some_any => sample.present,
        .some_constant => sample.present and sample.left == constant,
        .some_guarded => sample.present and sample.left + sample.right > constant,
        .pair_constant_left => sample.present and sample.left == constant,
        .pair_constant_right => sample.present and sample.right == constant,
        .pair_guarded => sample.present and sample.left < sample.right,
    };
}

test "randomized option and tuple patterns agree with a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xca5e_66);
    const random = prng.random();
    var buffer: [4096]u8 = undefined;
    for (0..60) |_| {
        var writer: std.Io.Writer = .fixed(&buffer);
        // The scrutinee is `option(tuple(i64,i64))`; every arm yields a distinct number plus
        // what it bound, so the result shows both the arm chosen and the values it saw.
        var shapes: [6]Shape = undefined;
        var constants: [6]i64 = undefined;
        const arms = random.intRangeAtMost(usize, 1, shapes.len);
        try writer.writeAll("F(M:option(tuple(i64,i64)))<computes>:i64=Case(M");
        for (0..arms) |arm| {
            shapes[arm] = random.enumValue(Shape);
            constants[arm] = random.intRangeAtMost(i64, -2, 2);
            const base = (arm + 1) * 1000;
            switch (shapes[arm]) {
                .none => try writer.print(",option{{}} where true=>{d}", .{base}),
                .some_any => try writer.print(",option{{P}} where true=>{d}+P(0)*10+P(1)", .{base}),
                .some_constant => try writer.print(",option{{tuple{{{d},Y}}}}=>{d}+Y", .{ constants[arm], base }),
                .some_guarded => try writer.print(",option{{tuple{{X,Y}}}} where X+Y>{d}=>{d}+X*10+Y", .{ constants[arm], base }),
                .pair_constant_left => try writer.print(",option{{tuple{{{d},_}}}}=>{d}", .{ constants[arm], base }),
                .pair_constant_right => try writer.print(",option{{tuple{{X,{d}}}}}=>{d}+X*10", .{ constants[arm], base }),
                .pair_guarded => try writer.print(",option{{tuple{{X,Y}}}} where X<Y=>{d}+X*10+Y", .{base}),
            }
        }
        // Half the programs end in a default, half in the two arms that cover an option.
        const defaulted = random.boolean();
        const present_first = random.boolean();
        if (defaulted) try writer.writeAll(",_=>-1)") else if (present_first) try writer.writeAll(",option{tuple{X,_}}=>-2-X,option{}=>-1)") else try writer.writeAll(",option{}=>-1,option{tuple{X,_}}=>-2-X)");
        var samples: [5]Sample = undefined;
        for (&samples, 0..) |*sample, index| {
            sample.* = .{ .present = random.uintLessThan(u8, 5) != 0, .left = random.intRangeAtMost(i64, -2, 2), .right = random.intRangeAtMost(i64, -2, 2) };
            if (sample.present) try writer.print("\nR{d}:i64=F(option{{tuple{{{d},{d}}}}})", .{ index, sample.left, sample.right }) else try writer.print("\nR{d}:i64=F(option{{}})", .{index});
        }
        const x = try h.execute(writer.buffered());
        for (samples, 0..) |sample, index| {
            var expected: i64 = if (!sample.present) -1 else if (defaulted) -1 else -2 - sample.left;
            for (shapes[0..arms], constants[0..arms], 0..) |shape, constant, arm| {
                if (!matches(shape, constant, sample)) continue;
                const base: i64 = @intCast((arm + 1) * 1000);
                expected = base + switch (shape) {
                    .none, .pair_constant_left => 0,
                    .some_any, .some_guarded, .pair_guarded => sample.left * 10 + sample.right,
                    .some_constant => sample.right,
                    .pair_constant_right => sample.left * 10,
                };
                break;
            }
            var name: [8]u8 = undefined;
            const actual = x.get(try std.fmt.bufPrint(&name, "R{d}", .{index})).?.integer;
            if (actual != expected) std.debug.print("oracle mismatch for sample {d} of:\n{s}\n", .{ index, writer.buffered() });
            try std.testing.expectEqual(expected, actual);
        }
    }
}
