//! Fields with accessors and no default (RFC-0085, I9): `var F<getter(G)><setter(S)>:T` in a
//! class or an interface. The field has no cell, as one with `= external{}` has none (I8); every
//! archetype of a class that has it gives it a value, which `S` receives once the instance is
//! built and its block clauses have run, in the order the fields are declared. No IR is new:
//! each setter call is the `method_value` and `invoke` that `set E.F = V` compiles to.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const evaluator = @import("evaluator.zig");
const nested = @import("nested_module_tests.zig");

/// The fixture `tests/conformance/accessor-initialisation.forb`.
pub const contract =
    \\# RFC-0085, I9: fields with accessors and no default. Every archetype gives each one a value,
    \\# which its setter receives once the instance is built and its block clauses have run, in the
    \\# order the fields are declared. The archetype's values are computed in the order written.
    \\var Log:[]string = array{}
    \\Say(Text:string, Value:i64)<transacts>:i64 = Block{ set Log = Log + array{Text}; Value }
    \\entity := class{
    \\    var Health<getter(GetHealth)><setter(SetHealth)>:i64
    \\    var Armour<getter(GetArmour)><setter(SetArmour)>:i64
    \\    var InternalHealth:i64 = 100
    \\    var InternalArmour:i64 = 0
    \\    Name:string = "anon"
    \\    Block{ Say("block {Self.Name} {Self.Health}", 0) }
    \\    GetHealth(:accessor)<reads>:i64 = Self.InternalHealth
    \\    SetHealth(:accessor, NewValue:i64)<transacts>:void = Block{
    \\        Say("health {NewValue}", 0)
    \\        If(NewValue >= 0 and NewValue <= 100, Block{ set Self.InternalHealth = NewValue; 0 }, 0)
    \\    }
    \\    GetArmour(:accessor)<reads>:i64 = Self.InternalArmour
    \\    SetArmour(:accessor, NewValue:i64)<transacts>:void = Block{ Say("armour {NewValue}", 0); set Self.InternalArmour = NewValue * 2; 0 }
    \\}
    \\# Written Armour first; the setters run in declaration order, after the block clause.
    \\Hero := entity{Armour := Say("armour value", 3), Name := "hero", Health := Say("health value", 40)}
    \\knight := class(entity){
    \\    var Oath<getter(GetOath)><setter(SetOath)>:string
    \\    var RawOath:string = ""
    \\    Block{ Say("knight block", 0) }
    \\    GetOath(:accessor)<reads>:string = Self.RawOath
    \\    SetOath(:accessor, Text:string)<transacts>:void = Block{ Say("oath {Text}", 0); set Self.RawOath = Text; 0 }
    \\}
    \\# A constructor function's archetype does the same; this setter refuses 150.
    \\MakeKnight<constructor>(Name:string, Oath:string)<transacts> := knight{Name := Name, Health := 150, Armour := 1, Oath := Oath}
    \\Sir := MakeKnight("sir", "honour")
    \\# Delegation lends the values a constructor gives these fields, as it lends its cells'.
    \\MakeEntity<constructor>(Health:i64)<transacts> := entity{Health := Say("lent", Health), Armour := 5}
    \\Squire := knight{Oath := "serve", MakeEntity<constructor>(60), Name := "squire"}
    \\# Through an interface: the class that implements it is built with the value.
    \\titled := interface{
    \\    var Title<getter(GetTitle)><setter(SetTitle)>:string
    \\    var Stored:string = ""
    \\    GetTitle(:accessor)<reads>:string = Self.Stored
    \\    SetTitle(:accessor, Text:string)<writes>:void = Block{ set Self.Stored = "<{Text}>"; 0 }
    \\}
    \\badge := class(titled){}
    \\AsTitled:titled = badge{Title := "gold"}
    \\# An archetype in a region that fails: its setters' writes are undone with it.
    \\Undone:i64 = Attempt(Block{ X := entity{Health := 10, Armour := 1}; Require[X.Health > 50]; X.Health }, -1)
    \\HeroHealth:i64 = Hero.Health
    \\HeroArmour:i64 = Hero.Armour
    \\SirHealth:i64 = Sir.Health
    \\SirOath:string = Sir.Oath
    \\SquireHealth:i64 = Squire.Health
    \\SquireArmour:i64 = Squire.Armour
    \\SquireName:string = Squire.Name
    \\Title:string = AsTitled.Title
    \\Trail:[]string = Log
    \\
;

test "accessor initialisation: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [8192]u8 = undefined;
    // Hero: its values in the order written, the block clause (which reads Health through the
    // getter before any setter has run), then Health's setter and Armour's, as declared. Sir:
    // entity's clause, knight's, and the three setters; SetHealth keeps 100 against 150.
    // Squire: `lent` is computed where the delegation is written. The failed region's
    // entries of Log are undone with its instance.
    const trail = "[\"armour value\",\"health value\",\"block hero 100\",\"health 40\",\"armour 3\",\"block sir 100\",\"knight block\",\"health 150\",\"armour 1\",\"oath honour\",\"lent\",\"block squire 100\",\"knight block\",\"health 60\",\"armour 5\",\"oath serve\"]";
    try std.testing.expectEqualStrings(
        "{\"Log\":" ++ trail ++ ",\"Hero\":{\"$object\":0},\"Sir\":{\"$object\":4},\"Squire\":{\"$object\":9},\"AsTitled\":{\"$object\":14},\"Undone\":-1,\"HeroHealth\":40,\"HeroArmour\":6,\"SirHealth\":100,\"SirOath\":\"honour\",\"SquireHealth\":60,\"SquireArmour\":10,\"SquireName\":\"squire\",\"Title\":\"<gold>\",\"Trail\":" ++ trail ++ ",\"$objects\":[{\"id\":0,\"class\":\"entity\",\"fields\":{\"InternalHealth\":40,\"InternalArmour\":6,\"Name\":\"hero\"}},{\"id\":4,\"class\":\"knight\",\"fields\":{\"InternalHealth\":100,\"InternalArmour\":2,\"Name\":\"sir\",\"RawOath\":\"honour\"}},{\"id\":9,\"class\":\"knight\",\"fields\":{\"InternalHealth\":60,\"InternalArmour\":10,\"Name\":\"squire\",\"RawOath\":\"serve\"}},{\"id\":14,\"class\":\"badge\",\"fields\":{\"Stored\":\"<gold>\"}}]}\n",
        try live.report(x, &buffer),
    );
    try live.expectEveryMode(contract);
}

/// Class `c`: one field with accessors and no default over the cell `I`.
const plain =
    \\c := class{
    \\    var H<getter(G)><setter(S)>:i64
    \\    var I:i64 = 1
    \\    G(:accessor)<reads>:i64 = Self.I
    \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
    \\}
    \\
;

test "accessor initialisation: the field has no cell, and a program without the form keeps its nodes" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(plain ++ "X := c{H := 4}\nA:i64 = X.H");
    for (p.definitions) |item| if (item == .class) {
        // `I` alone: `H` is no catalogue field.
        try std.testing.expectEqual(@as(u32, 1), item.class.fields.end - item.class.fields.start);
    };
    // The archetype is an `object_new` of `I`'s default, then the setter's `method_value` and
    // `invoke`; the read is the getter's.
    var news: usize = 0;
    var invokes: usize = 0;
    for (p.nodes) |node| switch (node.kind) {
        .object_new => |new| {
            news += 1;
            try std.testing.expectEqual(@as(u32, 1), new.arguments.end - new.arguments.start);
        },
        .invoke => invokes += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), news);
    try std.testing.expectEqual(@as(usize, 2), invokes);
    // A program with `= external{}` fields only compiles to the same nodes whether or not a
    // class with a field without a default is declared after it.
    const external = "e := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}\nY := e{}\nset Y.H = 2\nB:i64 = Y.H\n";
    const alone = (try h.compile(external)).nodes.len;
    try std.testing.expectEqual(alone, (try h.compile(external ++ plain)).nodes.len);
}

test "accessor initialisation: an archetype costs exactly the object and the setter call written out" {
    const h = try harness.create();
    defer scratch.release(h);
    const by_archetype = try h.compile(plain ++
        \\Run(V:i64)<transacts>:i64 = Block{ E := c{H := V}; E.H }
        \\A:i64 = Run(40)
        \\All:[]i64 = For(X:array{1, 2, 3, 4, 5, 6, 7, 8}, Run(X))
    );
    try std.testing.expectEqual(@as(i64, 40), (try h.run(by_archetype, live.fuel)).ok.get("A").?.integer);
    const by_set = try h.compile(
        \\c := class{
        \\    var H<getter(G)><setter(S)>:i64 = external{}
        \\    var I:i64 = 1
        \\    G(:accessor)<reads>:i64 = Self.I
        \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\}
        \\Run(V:i64)<transacts>:i64 = Block{ E := c{}; set E.H = V; E.H }
        \\A:i64 = Run(40)
        \\All:[]i64 = For(X:array{1, 2, 3, 4, 5, 6, 7, 8}, Run(X))
    );
    try std.testing.expectEqual(@as(i64, 40), (try h.run(by_set, live.fuel)).ok.get("A").?.integer);
    try std.testing.expectEqual(try leastFuel(h, by_set), try leastFuel(h, by_archetype));
}

/// The least budget `p` completes with in both machines, found by halving.
fn leastFuel(h: *harness.Harness, p: types.Program) !u64 {
    var low: u64 = 0;
    var high: u64 = live.fuel;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, middle);
        const actual = h.runtime.evaluate(p, middle);
        try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
        if (actual == .ok) high = middle else low = middle;
    }
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, high - 1);
    const actual = h.runtime.evaluate(p, high - 1);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.failed.code);
    try std.testing.expectEqualDeep(reference.failed, actual.failed);
    return high;
}

test "accessor initialisation: every diagnostic, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // Every archetype gives the field, a subclass's and an implementing class's included.
    try live.expectRefused(h, plain ++ "X := c{}", .missing_field, "c");
    try live.expectRefused(h, plain ++ "X := c{I := 2}", .missing_field, "c");
    try live.expectRefused(h, plain ++ "d := class(c){}\nX := d{}", .missing_field, "d");
    try live.expectRefused(h, plain ++ "d := class(c){\n var K<getter(G2)><setter(S2)>:i64\n G2(:accessor)<reads>:i64 = 0\n S2(:accessor, V:i64)<computes>:void = 0\n}\nX := d{K := 1}", .missing_field, "d");
    const interface = "i := interface{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}\nk := class(i){}\n";
    try live.expectRefused(h, interface ++ "X := k{}", .missing_field, "k");
    try live.expectRefused(h, plain ++ "M()<transacts>:c = c{}", .missing_field, "c");
    try live.expectRefused(h, plain ++ "M<constructor>()<transacts> := c{}", .missing_field, "c");
    // A class whose archetype may be empty (`<concrete>`, RFC-0081) cannot have one.
    try live.expectRefused(h, "c := class<concrete>{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}", .missing_field, "c");
    try live.expectRefused(h, plain ++ "d := class<concrete>(c){}", .missing_field, "d");
    try live.expectRefused(h, interface ++ "j := class<concrete>(i){}", .missing_field, "j");
    // Once only: by name twice, or by name and through a constructor function.
    try live.expectRefused(h, plain ++ "X := c{H := 1, H := 2}", .duplicate_field, "H");
    try live.expectRefused(h, plain ++ "M<constructor>()<transacts> := c{H := 1}\nX := c{H := 2, M<constructor>()}", .duplicate_field, "M");
    try live.expectRefused(h, plain ++ "M<constructor>()<transacts> := c{H := 1}\nX := c{M<constructor>(), H := 2}", .duplicate_field, "H");
    // A value of the field's type, by the field's access.
    try live.expectRefused(h, plain ++ "X := c{H := \"s\"}", .type_mismatch, "\"s\"");
    try live.expectRefused(h, "c := class{\n var H<private><getter(G)><setter(S)>:i64\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nX := c{H := 1}", .inaccessible_member, "H");
    // The construction needs the setter's effects, at the archetype's class.
    try live.expectRefused(h, plain ++ "M()<allocates>:c = c{H := 1}", .call_requires_writes, "c");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<transacts>:void = Block{ set Self.I = V + Self.I; 0 }\n}\nM()<allocates><writes>:c = c{H := 1}", .call_requires_reads, "c");
    try live.expectRefused(h, plain ++ "M()<allocates><writes><predicts>:c = c{H := 1}", .call_requires_dictates, "c");
    // What I8 refuses stays refused: a default other than `external{}`, an `external{}`
    // field in an archetype, a missing setter, a live field, a restatement.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = 3\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_default, "=");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nX := c{H := 3}", .accessor_archetype, "H");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64\n G(:accessor)<reads>:i64 = 1\n}", .accessor_signature, "S");
    try live.expectRefused(h, "c := class{\n var live H<getter(G)><setter(S)>:i64\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_live, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n var H:i64 = 2\n}", .accessor_override, "H");
}

test "accessor initialisation: in functions, arms, loops, parametric classes, a class's own methods, and abstract classes" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = plain ++
        \\Make(V:i64)<transacts>:c = c{H := V * 2}
        \\Pick(B:logic)<transacts>:i64 = If(B, c{H := 1}, c{H := 2}).H
        \\Sum:i64 = Block{ var T:i64 = 0; For(X:array{1, 2, 3}, Block{ set T += c{H := X}.H; 0 }); T }
        \\A:i64 = Make(5).H
        \\B:i64 = Pick(true) * 10 + Pick(false)
        \\cell[T:type] := class{
        \\    var Item<getter(Get)><setter(Put)>:T
        \\    var Raw:[]T = array{}
        \\    Get(:accessor)<reads>:T = ElementAt(Self.Raw, 0)
        \\    Put(:accessor, V:T)<writes>:void = Block{ set Self.Raw = array{V}; 0 }
        \\}
        \\D:string = cell[string]{Item := "s"}.Item
        \\self_made := class{
        \\    var H<getter(G)><setter(S)>:i64
        \\    var I:i64 = 0
        \\    G(:accessor)<reads>:i64 = Self.I
        \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\    Next()<transacts>:self_made = self_made{H := Self.H + 1}
        \\}
        \\E:i64 = self_made{H := 7}.Next().Next().H
        \\shape := class<abstract>{
        \\    var Id<getter(GetId)><setter(SetId)>:i64
        \\    var Raw:i64 = 0
        \\    GetId(:accessor)<reads>:i64 = Self.Raw
        \\    SetId(:accessor, V:i64)<writes>:void = Block{ set Self.Raw = V + 1000; 0 }
        \\}
        \\MakeShape<constructor>(Id:i64)<transacts> := shape{Id := Id * 3}
        \\square := class(shape){ Edge:i64 = 2 }
        \\MakeSquare<constructor>(Id:i64)<transacts> := square{MakeShape<constructor>(Id), Edge := 5}
        \\F:i64 = square{MakeShape<constructor>(4)}.Id
        \\L:i64 = MakeSquare(2).Id + MakeSquare(1).Edge
        \\Maker:function<transacts>(tuple(i64), square) = MakeSquare
        \\K:i64 = Maker(10).Id
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 10), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("Sum").?.integer);
    try std.testing.expectEqualStrings("s", x.get("D").?.string);
    try std.testing.expectEqual(@as(i64, 9), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 1012), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 1006 + 5), x.get("L").?.integer);
    try std.testing.expectEqual(@as(i64, 1030), x.get("K").?.integer);
    try live.expectEveryMode(source);
}

test "accessor initialisation: across modules, by the field's access" {
    const h = try harness.create();
    defer scratch.release(h);
    const library =
        \\c<public> := class{
        \\    var H<public><getter(G)><setter(S)>:i64
        \\    var I:i64 = 1
        \\    G(:accessor)<reads>:i64 = Self.I
        \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V + 1; 0 }
        \\}
        \\d<public> := class{
        \\    var K<getter(G)><setter(S)>:i64
        \\    var I:i64 = 1
        \\    G(:accessor)<reads>:i64 = Self.I
        \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\}
        \\
    ;
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nX:Kit.c=Kit.c{H := 4}\nA<public>:i64=X.H\n" },
        .{ .path = "kit.forb", .source = library },
    });
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    // `K` is internal to its module: no other module builds a `d`.
    const problem = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nY:Kit.d=Kit.d{K := 1}\n" },
        .{ .path = "kit.forb", .source = library },
    } })) {
        .ok => return error.TestUnexpectedResult,
        .failed => |problem| problem,
    };
    try std.testing.expectEqual(types.Diagnostic.Code.internal_member, problem.diagnostic.code);
    try std.testing.expectEqualStrings("K", problem.diagnostic.span.text(problem.source));
}

test "accessor initialisation: a setter that fails at run time fails the archetype, in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // A setter that assigns its own field calls itself: the call depth ends it.
    try live.expectFailure(h, "c := class{\n var H<getter(G)><setter(S)>:i64\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = Block{ set Self.H = V; 0 }\n}\nX := c{H := 1}", .call_depth_limit, ".");
    // An overflow in the setter is the setter's.
    try live.expectFailure(h, "c := class{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V * V; 0 }\n}\nX := c{H := 9223372036854775807}", .arithmetic_overflow, "*");
}

/// Class `c` with two fields with accessors and no default, over the cells `I` and `J`.
const pair =
    \\c := class{
    \\    var H<getter(G)><setter(S)>:i64
    \\    var K<getter(G2)><setter(S2)>:i64
    \\    var I:i64 = 0
    \\    var J:i64 = 0
    \\    G(:accessor)<reads>:i64 = Self.I
    \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
    \\    G2(:accessor)<reads>:i64 = Self.J
    \\    S2(:accessor, V:i64)<writes>:void = Block{ set Self.J = V; 0 }
    \\}
    \\
;

test "accessor initialisation: an archetype compiled inside another's values leaves the other's values alone (review of a9)" {
    const h = try harness.create();
    defer scratch.release(h);
    // An archetype of the same class in a value, written after a field the outer one gives:
    // directly, in a constructor function, inside an `Fn`, and in a method compiled where a
    // parametric class is first named. Each archetype keeps its own values.
    const source = pair ++
        \\X := c{H := 1, K := c{H := 2, K := 3}.K}
        \\MakeC<constructor>(V:i64)<transacts> := c{H := V, K := c{H := V + 1, K := 3}.K}
        \\Y := MakeC(4)
        \\F(V:i64)<transacts>:i64 = c{H := V, K := Block{ L:function<transacts>(tuple(i64),i64) = Fn(W:i64){c{H := W + 1, K := W}.H}; L(V) }}.H
        \\w[T:type] := class{
        \\    M()<transacts>:c = c{H := 1, K := 2}
        \\}
        \\Z := c{H := 5, K := w[i64]{}.M().K}
        \\A:i64 = X.H * 10 + X.K
        \\B:i64 = Y.H * 10 + Y.K
        \\C:i64 = F(5)
        \\D:i64 = Z.H * 10 + Z.K
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 13), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 43), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 52), x.get("D").?.integer);
    // A field given twice around such an archetype is still given twice: the inner one has
    // overwritten the outer one's mark, so the archetype finds it where it closes.
    try live.expectRefused(h, pair ++ "X := c{H := 1, K := c{H := 2, K := 3}.K, H := 9}", .duplicate_field, "c");
    try live.expectRefused(h, pair ++ "X := c{H := 1, K := 3, H := 9}", .duplicate_field, "H");
}

test "accessor initialisation: a stated class effect bounds the setters its constructions run (review of a9)" {
    const h = try harness.create();
    defer scratch.release(h);
    const setter = "p := class{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<transacts>:void = Block{ set Self.I = V; 0 }\n}\n";
    // As block clauses are (RFC-0078): the class's own fields and those it inherits.
    try live.expectRefused(h, "c := class<allocates>{\n var H<getter(G)><setter(S)>:i64\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}", .class_effect_narrower_writes, "c");
    try live.expectRefused(h, setter ++ "d := class<computes>(p){}", .class_effect_narrower_reads, "d");
    try live.expectRefused(h, setter ++ "d := class<allocates><reads>(p){}", .class_effect_narrower_writes, "d");
    // A predicting class has setters that predict.
    try live.expectRefused(h, setter ++ "d := class<transacts><predicts>(p){}", .construction_requires_dictates, "d");
    const x = try live.run(h, setter ++ "d := class<transacts>(p){}\nM()<transacts>:i64 = d{H := 3}.H\nA:i64 = M()");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
}

/// A class `b` with one to three fields with accessors and no default, a subclass `d` with up
/// to two more, each with a block clause or not, and one archetype of `d` that gives every
/// field in a random order: the fields of `b` by name, or through a constructor function of `b`
/// whose own order is random. Every value, block clause and setter appends a digit to `Trace`.
/// Returns the model's `Trace * 1000 + Sum`, `Sum` adding what each setter keeps.
fn randomOrder(random: std.Random, out: *std.Io.Writer) !i64 {
    const above = random.intRangeAtMost(usize, 1, 3);
    const below = random.intRangeAtMost(usize, 0, 2);
    const fields = above + below;
    const blocks = [2]bool{ random.boolean(), random.boolean() };
    const lends = random.boolean();
    const in_function = random.boolean();
    var values: [5]i64 = undefined;
    for (values[0..fields]) |*value| value.* = random.intRangeAtMost(i64, 0, 9);
    try out.writeAll("var Trace:i64 = 0\nNote(D:i64, V:i64)<transacts>:i64 = Block{ set Trace = Trace * 16 + D; V }\n");
    for (0..2) |class| {
        const first: usize = if (class == 0) 0 else above;
        const last: usize = if (class == 0) above else fields;
        try out.writeAll(if (class == 0) "b := class{\n" else "d := class(b){\n");
        for (first..last) |i| try out.print(" var F{d}<getter(G{d})><setter(S{d})>:i64\n var R{d}:i64 = 0\n G{d}(:accessor)<reads>:i64 = Self.R{d}\n S{d}(:accessor, V:i64)<transacts>:void = Block{{ Note({d}, 0); set Self.R{d} = V + {d}; 0 }}\n", .{ i, i, i, i, i, i, i, 6 + i, i, i });
        if (blocks[class]) try out.print(" Block{{ Note({d}, 0) }}\n", .{11 + class});
        try out.writeAll("}\n");
    }
    // The constructor's order of `b`'s fields, and the archetype's order of its entries, in
    // which `fields` stands for the delegation.
    var lent: [3]usize = .{ 0, 1, 2 };
    random.shuffle(usize, lent[0..above]);
    var entries: [6]usize = .{ 0, 1, 2, 3, 4, 5 };
    var entry_count: usize = 0;
    if (lends) {
        try out.writeAll("Mk<constructor>()<transacts> := b{");
        for (lent[0..above], 0..) |i, at| try out.print("{s}F{d} := Note({d}, {d})", .{ if (at == 0) "" else ", ", i, 1 + i, values[i] });
        try out.writeAll("}\n");
        entries[0] = fields;
        entry_count = 1;
        for (above..fields) |i| {
            entries[entry_count] = i;
            entry_count += 1;
        }
    } else {
        for (0..fields) |i| entries[i] = i;
        entry_count = fields;
    }
    random.shuffle(usize, entries[0..entry_count]);
    try out.writeAll(if (in_function) "Run()<transacts>:d = d{" else "X := d{");
    for (entries[0..entry_count], 0..) |entry, at| {
        if (at != 0) try out.writeAll(", ");
        if (entry == fields) try out.writeAll("Mk<constructor>()") else try out.print("F{d} := Note({d}, {d})", .{ entry, 1 + entry, values[entry] });
    }
    try out.writeAll(if (in_function) "}\nX := Run()\n" else "}\n");
    try out.writeAll("Result:i64 = Trace * 1000");
    for (0..fields) |i| try out.print(" + X.F{d}", .{i});
    try out.writeAll("\n");
    // The model: the values as written, then the clauses, `b`'s first, then the setters in
    // declaration order.
    var trace: i64 = 0;
    for (entries[0..entry_count]) |entry| {
        if (entry == fields) {
            for (lent[0..above]) |i| trace = trace * 16 + @as(i64, @intCast(1 + i));
        } else trace = trace * 16 + @as(i64, @intCast(1 + entry));
    }
    for (blocks, 0..) |has, class| if (has) {
        trace = trace * 16 + @as(i64, @intCast(11 + class));
    };
    var sum: i64 = 0;
    for (0..fields) |i| {
        trace = trace * 16 + @as(i64, @intCast(6 + i));
        sum += values[i] + @as(i64, @intCast(i));
    }
    return trace * 1000 + sum;
}

test "accessor initialisation: random construction orders meet a plain model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0085_0009);
    const random = prng.random();
    var text: [4096]u8 = undefined;
    for (0..200) |seed| {
        var out = std.Io.Writer.fixed(&text);
        const expected = try randomOrder(random, &out);
        const x = try live.run(h, out.buffered());
        const value = x.get("Result").?.integer;
        if (value != expected) std.debug.print("{s}\n", .{out.buffered()});
        try std.testing.expectEqual(expected, value);
        if (seed < 8) try live.expectEveryMode(out.buffered());
    }
}

test "accessor initialisation: an archetype gives as many fields with accessors as the profile has methods" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var text: [96 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&text);
    // One getter and one setter serve every field; the setter adds what it is given.
    try out.writeAll("c := class{\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<transacts>:void = Block{ set Self.I += V; 0 }\n");
    for (0..types.limits.methods) |index| try out.print(" var F{d}<getter(G)><setter(S)>:i64\n", .{index});
    try out.writeAll("}\nX := c{");
    // Written last first; F0 is written last.
    var index: usize = types.limits.methods;
    while (index > 0) {
        index -= 1;
        try out.print("F{d} := {d}{s}", .{ index, index, if (index == 0) "" else ", " });
    }
    try out.writeAll("}\nA:i64 = X.I\n");
    const x = try live.run(h, out.buffered());
    try std.testing.expectEqual(@as(i64, types.limits.methods * (types.limits.methods - 1) / 2), x.get("A").?.integer);
    // Without F0 it is `missing_field`.
    const at = std.mem.indexOf(u8, out.buffered(), ", F0 := 0").?;
    var shorter: [96 * 1024]u8 = undefined;
    const cut = try std.fmt.bufPrint(&shorter, "{s}{s}", .{ out.buffered()[0..at], out.buffered()[at + ", F0 := 0".len ..] });
    try live.expectRefused(h, cut, .missing_field, "c");
}
