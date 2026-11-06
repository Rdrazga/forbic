//! Fields with accessors (RFC-0085, I8): `var F<getter(G)><setter(S)>:T = external{}` in a class
//! or an interface. The field has no cell; a read of it is a call of `G` and a `set` of it a call
//! of `S`, each handed the one value of the standard type `accessor`, which no source expression
//! can build. No IR is new: the calls are the `method_value` and `invoke` an interface field's
//! accessors already compile to, so both machines, the replay and every trace mode run them as
//! they run any method call.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const nested = @import("nested_module_tests.zig");

/// The fixture `tests/conformance/accessors.forb`: the Book's examples 23 (12:849) and 100
/// (10:3279) in Forbic spelling, used through the class, the interface, `+=` and `-=`, and a
/// region that fails.
pub const contract =
    \\# RFC-0085, I8: fields with accessors. Such a field has no cell: a read calls its getter and a
    \\# `set` its setter, with an `accessor` that only the access can make. The Book's example 23
    \\# (12:849), then its example 100 (10:3279), in Forbic spelling.
    \\entity := class{
    \\    var Health<getter(GetHealth)><setter(SetHealth)>:i64 = external{}
    \\    var InternalHealth:i64 = 100
    \\    GetHealth(:accessor)<reads>:i64 = Self.InternalHealth
    \\    SetHealth(:accessor, NewValue:i64)<transacts>:void = If(NewValue >= 0 and NewValue <= 100, Block{ set Self.InternalHealth = NewValue; 0 }, 0)
    \\}
    \\subscribable_property := interface{
    \\    var Value<getter(GetValue)><setter(SetValue)>:i64 = external{}
    \\    var Storage:i64 = 100
    \\    GetValue(:accessor)<reads>:i64 = Self.Storage + 10
    \\    SetValue(:accessor, NewValue:i64)<transacts>:void = If(NewValue >= 0, Block{ set Self.Storage = NewValue; 0 }, 0)
    \\}
    \\tracked_value := class(subscribable_property){}
    \\Object := tracked_value{}
    \\Initial:i64 = Object.Value
    \\set Object.Value = 150
    \\Updated:i64 = Object.Value
    \\# Through the interface: the setter refuses -5; `+=` reads through the getter once.
    \\AsProperty:subscribable_property = Object
    \\set AsProperty.Value = -5
    \\set AsProperty.Value += 1
    \\Through:i64 = AsProperty.Value
    \\Hero := entity{}
    \\set Hero.Health = 150
    \\Refused:i64 = Hero.Health
    \\set Hero.Health = 40
    \\Accepted:i64 = Hero.Health
    \\set Hero.Health -= 15
    \\Lowered:i64 = Hero.Health
    \\# A setter's writes in a region that fails are undone with it.
    \\Hurt(E:entity, By:i64)<transacts><decides>:i64 = Block{ set E.Health -= By; Require[E.Health > 0]; E.Health }
    \\Survived:i64 = Attempt(Hurt[Hero, 5], -1)
    \\Fallen:i64 = Attempt(Hurt[Hero, 20], -1)
    \\Kept:i64 = Hero.Health
;

/// The members of class `c`, shared by the cases below: a field with accessors over the cell
/// `I`, whose setter keeps what it is given.
const plain =
    \\c := class{
    \\    var H<getter(G)><setter(S)>:i64 = external{}
    \\    var I:i64 = 1
    \\    G(:accessor)<reads>:i64 = Self.I
    \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
    \\}
    \\
;

test "accessors: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    // Initial: Storage + 10. The setter refuses -5, and `+= 1` reads 160 once and writes 161.
    // Hero's setter refuses 150; Hurt[Hero, 20] writes 0, fails its `Require` and is undone.
    try std.testing.expectEqualStrings(
        "{\"Object\":{\"$object\":0},\"Initial\":110,\"Updated\":160,\"AsProperty\":{\"$object\":0},\"Through\":171,\"Hero\":{\"$object\":2},\"Refused\":100,\"Accepted\":40,\"Lowered\":25,\"Survived\":20,\"Fallen\":-1,\"Kept\":20,\"$objects\":[{\"id\":0,\"class\":\"tracked_value\",\"fields\":{\"Storage\":161}},{\"id\":2,\"class\":\"entity\",\"fields\":{\"InternalHealth\":20}}]}\n",
        try live.report(x, &buffer),
    );
    try live.expectEveryMode(contract);
}

test "accessors: the field has no cell, the accessor is an empty struct, and reads and writes are calls" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(contract);
    var accessors: usize = 0;
    for (p.definitions, 0..) |item, index| switch (item) {
        // The field is no catalogue field: the class's cells are its other fields'.
        .class => |class| if (std.mem.eql(u8, class.name.text(p.source), "entity")) {
            try std.testing.expectEqual(@as(u32, 1), class.fields.end - class.fields.start);
            try std.testing.expectEqualStrings("InternalHealth", p.fields[class.fields.start].name.text(p.source));
        } else if (std.mem.eql(u8, class.name.text(p.source), "tracked_value")) {
            try std.testing.expectEqual(@as(u32, 1), class.fields.end - class.fields.start);
            try std.testing.expectEqualStrings("Storage", p.fields[class.fields.start].name.text(p.source));
        },
        .record => |record| {
            try std.testing.expectEqualStrings("accessor", record.name.text(p.source));
            try std.testing.expectEqual(record.fields.start, record.fields.end);
            try std.testing.expect(record.is_public);
            const accessor: types.Type = @fromBackingInt(@intCast(index + catalogue.builtin_count));
            // Every getter and setter takes it after `Self`.
            var takers: usize = 0;
            for (p.functions) |f| if (f.parameter_count >= 2 and f.parameters[1] == accessor) {
                takers += 1;
            };
            try std.testing.expectEqual(@as(usize, 4), takers);
            accessors += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), accessors);
    // No runtime function is named after a field with accessors, as one is after an interface field.
    for (p.functions) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name.text(p.source), "Health"));
        try std.testing.expect(!std.mem.eql(u8, f.name.text(p.source), "Value"));
    }
    // A program without the form makes no `accessor`.
    const without = try h.compile("c := class{ var I:i64 = 1 }\nX := c{}\nA:i64 = X.I");
    for (without.definitions) |item| try std.testing.expect(item != .record);
}

test "accessors: an access costs exactly the method call it lowers to" {
    const h = try harness.create();
    defer scratch.release(h);
    // The same calls written out, with a struct of no fields standing in for `accessor`.
    const by_field = try h.compile(plain ++
        \\Run()<transacts>:i64 = Block{ E := c{}; set E.H = 40; set E.H += 2; E.H }
        \\A:i64 = Run()
        \\All:[]i64 = For(X:array{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, Run() + X)
    );
    try std.testing.expectEqual(@as(i64, 42), (try h.run(by_field, live.fuel)).ok.get("A").?.integer);
    const by_call = try h.compile(
        \\key := struct{}
        \\c := class{
        \\    var I:i64 = 1
        \\    G(K:key)<reads>:i64 = Self.I
        \\    S(K:key, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\}
        \\Run()<transacts>:i64 = Block{ E := c{}; E.S(key{}, 40); E.S(key{}, E.G(key{}) + (2)); E.G(key{}) }
        \\A:i64 = Run()
        \\All:[]i64 = For(X:array{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, Run() + X)
    );
    try std.testing.expectEqual(@as(i64, 42), (try h.run(by_call, live.fuel)).ok.get("A").?.integer);
    try std.testing.expectEqual(try leastFuel(h, by_call), try leastFuel(h, by_field));
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
    // One unit less runs out of work, in both machines alike.
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, high - 1);
    const actual = h.runtime.evaluate(p, high - 1);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.failed.code);
    try std.testing.expectEqualDeep(reference.failed, actual.failed);
    return high;
}

test "accessors: every diagnostic, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    const getter = "\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}";
    // Both specifiers (12:876), on a `var` (12:879), with `= external{}` or no default (12:877).
    try live.expectRefused(h, "c := class{\n var H<getter(G)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n}", .accessor_pair, "H");
    try live.expectRefused(h, "c := class{\n var H<setter(S)>:i64 = external{}\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_pair, "H");
    try live.expectRefused(h, "c := class{\n H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .accessor_mutable, "H");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = 3" ++ getter, .accessor_default, "=");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{1}" ++ getter, .accessor_default, "=");
    // No default is archetype initialisation (I9, `accessor_init_tests.zig`): every archetype gives it.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64" ++ getter ++ "\nX := c{}", .missing_field, "c");
    // The getter and the setter: methods of this class with a body and the exact signatures.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n}", .accessor_signature, "S");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:string = \"h\"\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_signature, "G");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:i64 = 0\n}", .accessor_signature, "S");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:string)<writes>:void = 0\n}", .accessor_signature, "S");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor, X:i64)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_signature, "G");
    // A named `accessor` parameter could be handed on (V13's guarantee).
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(A:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_signature, "G");
    // A method of a superclass is not the field's own.
    try live.expectRefused(h, "b := class{\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nc := class(b){\n var H<getter(G)><setter(S)>:i64 = external{}\n}", .accessor_signature, "G");
    // An abstract getter of an interface has no body to call.
    try live.expectRefused(h, "i := interface{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_signature, "G");
    // Neither fails nor suspends.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads><decides>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .accessor_effect, "G");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes><suspends>:void = 0\n}", .accessor_effect, "S");
    // `(:T)` is for `accessor` in a method only.
    try live.expectRefused(h, "F(:i64)<computes>:i64 = 1", .expected_parameter, ":");
    try live.expectRefused(h, "F(:accessor)<computes>:i64 = 1", .expected_parameter, ":");
    try live.expectRefused(h, "c := class{\n M(:i64)<computes>:i64 = 1\n}", .expected_parameter, ":");
    // Live (no cell), restated, overridden, or named by another member.
    try live.expectRefused(h, "c := class{\n var live H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .accessor_live, "H");
    try live.expectRefused(h, "c := class{\n live H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .accessor_live, "H");
    try live.expectRefused(h, "c := class{\n var H<override><getter(G)><setter(S)>:i64 = external{}" ++ getter, .accessor_override, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n H<override>:i64 = 3\n}", .accessor_override, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n var H:i64 = 3\n}", .accessor_override, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n H()<computes>:i64 = 3\n}", .accessor_override, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n G<override>(:accessor)<reads>:i64 = 2\n}", .accessor_override, "G");
    try live.expectRefused(h, plain ++ "d := class(c){\n S<override>(:accessor, V:i64)<writes>:void = 1\n}", .accessor_override, "S");
    try live.expectRefused(h, plain ++ "d := class(c){\n var H<getter(G2)><setter(S2)>:i64 = external{}\n G2(:accessor)<reads>:i64 = 1\n S2(:accessor, V:i64)<writes>:void = 0\n}", .accessor_override, "H");
    // Through an interface (10:3309): an implementing class restates neither the field nor its accessors.
    const interface = "i := interface{\n var H<getter(G)><setter(S)>:i64 = external{}\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}\n";
    try live.expectRefused(h, interface ++ "d := class(i){\n G<override>(:accessor)<reads>:i64 = 2\n}", .accessor_override, "G");
    try live.expectRefused(h, interface ++ "d := class(i){\n var H:i64 = 2\n}", .accessor_override, "H");
    try live.expectRefused(h, interface ++ "j := interface(i){\n G<override>(:accessor)<reads>:i64 = 2\n}", .accessor_override, "G");
    // A superclass method does not stand in for an interface's getter.
    try live.expectRefused(h, interface ++ "b := class{\n G<public>(:accessor)<reads>:i64 = 3\n}\nd := class(b, i){}", .accessor_override, "d");
    // One member per name.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n H()<computes>:i64 = 1" ++ getter, .duplicate_name, "H");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n H:i64 = 1" ++ getter, .duplicate_field, "H");
    try live.expectRefused(h, "c := class{\n H:i64 = 1\n var H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .duplicate_field, "H");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n var H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .duplicate_field, "H");
    try live.expectRefused(h, "i := interface{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nj := interface{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nd := class(i, j){}", .duplicate_name, "d");
    // A getter that overrides a method above has that method's slot (review of a8: the read
    // coerced the receiver to the wrong class).
    try live.expectRefused(h, "b := class{\n G(A:accessor)<reads>:i64 = 5\n}\nc := class(b){\n var H<getter(G)><setter(S)>:i64 = external{}\n var I:i64 = 1\n G<override>(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}\nY:i64 = c{}.H", .accessor_signature, "G");
    // A generic method of the name, in the class or below it.
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n H[T:type](X:T)<computes>:T{ X }" ++ getter, .duplicate_name, "H");
    try live.expectRefused(h, plain ++ "d := class(c){\n H[T:type](X:T)<computes>:T{ X }\n}", .accessor_override, "H");
    // `<final>` keeps a default the field does not have; specifiers are not repeated.
    try live.expectRefused(h, "c := class{\n var H<final><getter(G)><setter(S)>:i64 = external{}" ++ getter, .unsupported_specifier, "final");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><getter(G)><setter(S)>:i64 = external{}" ++ getter, .unsupported_specifier, "getter");
    try live.expectRefused(h, "c := class{\n var<public> H<getter(G)><setter(S)>:i64 = external{}" ++ getter, .unsupported_specifier, "H");
    // Uses: an accessor is made only by an access; the field has no cell to initialise or to
    // attach a guard to; the getter and setter take an accessor nobody else has.
    try live.expectRefused(h, plain ++ "A:accessor = accessor{}", .accessor_construction, "accessor");
    try live.expectRefused(h, "A:i64 = Block{ X := accessor{}; 1 }", .accessor_construction, "accessor");
    try live.expectRefused(h, plain ++ "X := c{H := 3}", .accessor_archetype, "H");
    try live.expectRefused(h, plain ++ "X := c{}\nset live X.H = 3", .live_target, "H");
    try live.expectRefused(h, plain ++ "X := c{}\nA:i64 = X.G()", .argument_count, "(");
    try live.expectRefused(h, plain ++ "k := class{\n var live Z:accessor = 3\n}", .live_field_default, "Z");
    // Effects: a read needs `<reads>`, a write `<writes>`, each with the accessor's own effects.
    try live.expectRefused(h, plain ++ "F(X:c)<computes>:i64 = X.H", .field_read_requires_reads, "H");
    try live.expectRefused(h, plain ++ "F(X:c)<reads>:i64 = Block{ set X.H = 1; 0 }", .set_requires_writes, ".");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<transacts>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nF(X:c)<reads>:i64 = X.H", .call_requires_writes_allocates, "H");
    try live.expectRefused(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<transacts>:void = 0\n}\nF(X:c)<writes>:i64 = Block{ set X.H = 1; 0 }", .call_requires_reads_allocates, ".");
    // Access is the field's: who may read it and who may assign it.
    try live.expectRefused(h, "c := class{\n var H<private><getter(G)><setter(S)>:i64 = external{}" ++ getter ++ "\nX := c{}\nA:i64 = X.H", .inaccessible_member, "H");
    try live.expectRefused(h, "c := class{\n var<private> H<public><getter(G)><setter(S)>:i64 = external{}" ++ getter ++ "\nX := c{}\nset X.H = 2", .inaccessible_member, "H");
}

test "accessors: access is the field's, and the program's own `accessor` hides the standard one" {
    const h = try harness.create();
    defer scratch.release(h);
    // A private getter and setter serve a public field: they run on the field's authority.
    const x = try live.run(h,
        \\c := class{
        \\    var H<public><getter(G)><setter(S)>:i64 = external{}
        \\    var I:i64 = 1
        \\    G<private>(:accessor)<reads>:i64 = Self.I * 2
        \\    S<private>(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\    Inside()<transacts>:i64 = Block{ set Self.H += 1; Self.H }
        \\}
        \\X := c{}
        \\set X.H = 9
        \\A:i64 = X.H
        \\B:i64 = X.Inside()
    );
    try std.testing.expectEqual(@as(i64, 18), x.get("A").?.integer);
    // `+= 1` writes 18 + 1, which reads back doubled.
    try std.testing.expectEqual(@as(i64, 38), x.get("B").?.integer);
    // A struct the program calls `accessor` is its own, built and used as any struct; it is
    // then no getter's parameter type.
    const own = try live.run(h, "accessor := struct{ X:i64 = 1 }\nA:accessor = accessor{}\nB:i64 = A.X");
    try std.testing.expectEqual(@as(i64, 1), own.get("B").?.integer);
    try live.expectRefused(h, "accessor := struct{}\nc := class{\n M(:accessor)<computes>:i64 = 1\n}", .expected_parameter, ":");
    try live.expectRefused(h, "c := class{\n M(:accessor)<computes>:i64 = 1\n}\naccessor := struct{}", .unsupported_type, "accessor");
    // A trial reading (a generic signature, an alias template) discards the `accessor` it
    // made; the type that takes its number later is not the standard one (review of a8: a
    // tuple became one, so a getter took it and the next struct could not be built).
    const trial =
        \\Id[t:type](A:accessor, X:t)<computes>:t{X}
        \\Pair[t:type] := tuple(t, accessor)
        \\T:tuple(i64, logic) = tuple{1, true}
        \\p := struct{ V:i64 = 1 }
        \\Y:p = p{}
        \\B:i64 = Y.V
        \\c := class{
        \\    var H<getter(G)><setter(S)>:i64 = external{}
        \\    var I:i64 = 1
        \\    G(:accessor)<reads>:i64 = Self.I + 100
        \\    S<public>(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\}
        \\E := c{}
        \\set E.H = 5
        \\A:i64 = E.H
        \\
    ;
    const tried = try live.run(h, trial);
    try std.testing.expectEqual(@as(i64, 105), tried.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), tried.get("B").?.integer);
    try live.expectRefused(h, trial ++ "Direct:void = E.S(T, 55)", .type_mismatch, "tuple{1, true}");
    try live.expectRefused(h, trial ++ "Got:i64 = E.G(tuple{2, false})", .type_mismatch, "tuple{2, false}");
}

test "accessors: across modules, by the field's access, and the accessor of another module" {
    const h = try harness.create();
    defer scratch.release(h);
    const library =
        \\c<public> := class{
        \\    var H<public><getter(G)><setter(S)>:i64 = external{}
        \\    var K<getter(G)><setter(S)>:i64 = external{}
        \\    var I:i64 = 1
        \\    G(:accessor)<reads>:i64 = Self.I
        \\    S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }
        \\}
        \\Inner<public> := module{
        \\    d<public> := class{
        \\        var J<public><getter(G2)><setter(S2)>:i64 = external{}
        \\        var Raw:i64 = 5
        \\        G2(:accessor)<reads>:i64 = Self.Raw + 1
        \\        S2(:accessor, V:i64)<writes>:void = Block{ set Self.Raw = V; 0 }
        \\    }
        \\}
        \\
    ;
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nX:Kit.c=Kit.c{}\nset X.H = 4\nA<public>:i64=X.H\nY:Kit.Inner.d=Kit.Inner.d{}\nset Y.J += 3\nB<public>:i64=Y.J\n" },
        .{ .path = "kit.forb", .source = library },
    });
    try std.testing.expectEqual(@as(i64, 4), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("B").?.integer);
    // `K` is internal to its module.
    const problem = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nX:Kit.c=Kit.c{}\nA<public>:i64=X.K\n" },
        .{ .path = "kit.forb", .source = library },
    } })) {
        .ok => return error.TestUnexpectedResult,
        .failed => |problem| problem,
    };
    try std.testing.expectEqual(types.Diagnostic.Code.internal_member, problem.diagnostic.code);
    try std.testing.expectEqualStrings("K", problem.diagnostic.span.text(problem.source));
}

test "accessors: rollback, a guard that follows the getter's reads, a path through the field, and a getter that calls itself" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\point := struct{ X:i64 = 0, Y:i64 = 0 }
        \\shape := class{
        \\    var Pos<getter(GetPos)><setter(SetPos)>:point = external{}
        \\    var Raw:point = point{}
        \\    var Writes:i64 = 0
        \\    GetPos(:accessor)<reads>:point = Self.Raw
        \\    SetPos(:accessor, P:point)<transacts>:void = Block{ set Self.Raw = P; set Self.Writes += 1; 0 }
        \\    Move(D:i64)<transacts>:i64 = Block{ set Self.Pos.X += D; Self.Pos.X }
        \\}
        \\square := class(shape){
        \\    Twice()<transacts>:i64 = Block{ set Self.Pos = point{X := Self.Pos.X * 2, Y := Self.Pos.Y}; Self.Pos.X }
        \\}
        \\S := square{}
        \\set S.Pos.Y = 4
        \\A:i64 = S.Move(3)
        \\B:i64 = S.Twice()
        \\Fails(Z:shape)<transacts><decides>:i64 = Block{ set Z.Pos = point{X := 99}; Require[Z.Pos.X < 50]; 1 }
        \\C:i64 = Attempt(Fails[S], -1)
        \\var Seen:i64 = 0
        \\set live Seen = S.Pos.X * 10 + S.Pos.Y
        \\set S.Pos.Y = 7
        \\D:i64 = Seen
        \\W:i64 = S.Writes
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("C").?.integer);
    // The guard read `Raw` through the getter, so the setter's write of it is followed.
    try std.testing.expectEqual(@as(i64, 67), x.get("D").?.integer);
    // Four writes: Y, the `+=`, `Twice`, and the second Y; the failed region's is undone.
    try std.testing.expectEqual(@as(i64, 4), x.get("W").?.integer);
    try live.expectEveryMode(source);
    // A getter that reads its own field calls itself: the call depth ends it, in both machines.
    try live.expectFailure(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = Self.H + 1\n S(:accessor, V:i64)<computes>:void = 0\n}\nA:i64 = c{}.H", .call_depth_limit, "H");
}

/// A program of `operations` random assignments of the field `V` of a class whose setter keeps
/// only values in `[low, high]` and whose getter adds `bias` to what it keeps, some of them in
/// regions that fail; returns what the Zig model says `Value` is.
fn randomProgram(random: std.Random, out: *std.Io.Writer) !i64 {
    const low = random.intRangeAtMost(i64, -20, 0);
    const high = random.intRangeAtMost(i64, 10, 60);
    const bias = random.intRangeAtMost(i64, -5, 5);
    const limit = random.intRangeAtMost(i64, 0, 40);
    try out.print("acc := class{{\n var V<getter(G)><setter(S)>:i64 = external{{}}\n var Raw:i64 = 0\n var Writes:i64 = 0\n G(:accessor)<reads>:i64 = Self.Raw + {d}\n S(:accessor, X:i64)<transacts>:void = If(X >= {d} and X <= {d}, Block{{ set Self.Raw = X - {d}; set Self.Writes += 1; 0 }}, 0)\n}}\nsub := class(acc){{}}\nO:acc = sub{{}}\nStep(Y:acc, N:i64)<transacts><decides>:i64 = Block{{ set Y.V += N; Require[Y.V < {d}]; Y.V }}\n", .{ bias, low, high, bias, limit });
    var raw: i64 = 0;
    var writes: i64 = 0;
    var results: i64 = 0;
    const operations = random.intRangeAtMost(usize, 1, 12);
    for (0..operations) |index| {
        const n = random.intRangeAtMost(i64, -15, 15);
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                try out.print("set O.V = {d}\n", .{n});
                if (n >= low and n <= high) {
                    raw = n - bias;
                    writes += 1;
                }
            },
            1 => {
                try out.print("set O.V += {d}\n", .{n});
                const wanted = raw + bias + n;
                if (wanted >= low and wanted <= high) {
                    raw = wanted - bias;
                    writes += 1;
                }
            },
            else => {
                try out.print("R{d}:i64 = Attempt(Step[O, {d}], -1)\n", .{ index, n });
                const wanted = raw + bias + n;
                var after = raw;
                var written = writes;
                if (wanted >= low and wanted <= high) {
                    after = wanted - bias;
                    written += 1;
                }
                if (after + bias < limit) {
                    raw = after;
                    writes = written;
                    results += after + bias;
                } else results -= 1;
            },
        }
    }
    try out.writeAll("Value:i64 = O.V * 1000000 + O.Writes * 1000 + Sum\n");
    // `Sum` adds the results of the regions, written before `Value` reads it.
    return (raw + bias) * 1000000 + writes * 1000 + results;
}

test "accessors: random assignments, compound assignments and failing regions meet a plain model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x8a11_0085);
    const random = prng.random();
    var text: [4096]u8 = undefined;
    for (0..200) |_| {
        var out = std.Io.Writer.fixed(&text);
        // `Sum` needs the names of the regions' results, which the generator writes as it goes:
        // the program is written first into a scratch buffer, then `Sum` is put before `Value`.
        var body: [4096]u8 = undefined;
        var body_out = std.Io.Writer.fixed(&body);
        const expected = try randomProgram(random, &body_out);
        const written = body_out.buffered();
        const value_line = std.mem.lastIndexOf(u8, written, "Value:i64").?;
        try out.writeAll(written[0..value_line]);
        try out.writeAll("Sum:i64 = 0");
        var lines = std.mem.splitScalar(u8, written[0..value_line], '\n');
        while (lines.next()) |line| if (line.len > 1 and line[0] == 'R' and std.ascii.isDigit(line[1])) {
            try out.print(" + {s}", .{line[0..std.mem.indexOfScalar(u8, line, ':').?]});
        };
        try out.writeAll("\n");
        try out.writeAll(written[value_line..]);
        const x = try live.run(h, out.buffered());
        const value = x.get("Value").?.integer;
        if (value != expected) std.debug.print("{s}\n", .{out.buffered()});
        try std.testing.expectEqual(expected, value);
    }
}

test "accessors: as many fields with accessors as the profile has methods, and one more is field_limit" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var text: [64 * 1024]u8 = undefined;
    for ([_]usize{ types.limits.methods, types.limits.methods + 1 }) |count| {
        var out = std.Io.Writer.fixed(&text);
        // One getter and one setter serve every field.
        try out.writeAll("c := class{\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n");
        for (0..count) |index| try out.print(" var F{d}<getter(G)><setter(S)>:i64 = external{{}}\n", .{index});
        try out.print("}}\nX := c{{}}\nset X.F{d} = 7\nA:i64 = X.F0\n", .{count - 1});
        if (count == types.limits.methods) {
            const x = try live.run(h, out.buffered());
            try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
        } else try live.expectRefused(h, out.buffered(), .field_limit, "F256");
    }
}

test "accessors: in a parametric class, of a function type, and in predicting code" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\cell[T:type] := class{
        \\    var Item<getter(Get)><setter(Put)>:T = external{}
        \\    var Raw:[]T = array{}
        \\    Get(:accessor)<reads>:T = ElementAt(Self.Raw, 0)
        \\    Put(:accessor, V:T)<writes>:void = Block{ set Self.Raw = array{V}; 0 }
        \\}
        \\Ints := cell[i64]{}
        \\set Ints.Item = 5
        \\A:i64 = Ints.Item
        \\Y := cell[string]{}
        \\set Y.Item = "s"
        \\set Y.Item += "t"
        \\B:string = Y.Item
        \\f := class{
        \\    var F<getter(G)><setter(S)>:function<computes>(tuple(i64), i64) = external{}
        \\    var Raw:function<computes>(tuple(i64), i64) = Fn(X:i64)<computes>:i64{ X }
        \\    G(:accessor)<reads>:function<computes>(tuple(i64), i64) = Self.Raw
        \\    S(:accessor, V:function<computes>(tuple(i64), i64))<writes>:void = Block{ set Self.Raw = V; 0 }
        \\}
        \\O := f{}
        \\set O.F = Fn(X:i64)<computes>:i64{ X * 3 }
        \\C:i64 = O.F(4)
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("C").?.integer);
    // A function used as a type (RFC-0084, P4.3) is no type of a field without a cell.
    try live.expectRefused(h, "Double(X:i64)<computes>:i64 = X * 2\nc := class{\n var F<getter(G)><setter(S)>:Double = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}", .unsupported_type, "Double");
    // The getter and the setter take nothing but the accessor the access makes.
    try live.expectRefused(h, plain ++ "X := c{}\nA:i64 = X.G(5)", .type_mismatch, "5");
    // A getter that dictates is a call a predicting function cannot make (I12).
    try live.expectRefused(h, plain ++ "P(Y:c)<reads><predicts>:i64 = Y.H", .call_requires_dictates, "H");
    const predicting = try live.run(h, "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n var I:i64 = 4\n G(:accessor)<reads><predicts>:i64 = Self.I\n S(:accessor, V:i64)<writes><predicts>:void = Block{ set Self.I = V; 0 }\n}\nP(Y:c)<transacts><predicts>:i64 = Block{ set Y.H += 1; Y.H }\nA:i64 = P(c{})");
    try std.testing.expectEqual(@as(i64, 5), predicting.get("A").?.integer);
}
