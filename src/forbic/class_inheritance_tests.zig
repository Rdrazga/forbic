//! Inheritance: subclasses share their parent's fields, instances convert to their superclasses
//! implicitly and back by an explicit failable cast, and overloads over related classes are refused.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "a subclass has its parent's fields and is usable as the parent" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class<unique>{Name:string,var Age:i64=0}
        \\Dog:=class<unique>(Animal){Tricks:i64}
        \\D:=Dog{Name:="rex",Tricks:=3}
        \\A:Animal=D
        \\Label:string=A.Name
        \\set A.Age=7
        \\Seen:i64=D.Age
        \\Tricks:i64=D.Tricks
        \\Same:logic=A==D
        \\Grow(Who:Animal)<transacts>:i64=Block{set Who.Age=Who.Age+1;Who.Age}
        \\After:i64=Grow(D)
        \\Zoo:[]Animal=array{D,Animal{Name:="cat"}}
        \\Count:i64=Zoo.Length
    );
    try std.testing.expectEqualStrings("rex", x.get("Label").?.string);
    try std.testing.expectEqual(@as(i64, 7), x.get("Seen").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Tricks").?.integer);
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expectEqual(@as(i64, 8), x.get("After").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Count").?.integer);
    // `A` is the dog: its value keeps the class it was built as.
    try std.testing.expectEqual(x.get("D").?.object.value_type, x.get("A").?.object.value_type);
    try std.testing.expect(x.get("A").?.object.value_type != x.program.nodes[x.program.bindings[3].node].value_type);
}

test "a class cast succeeds exactly for instances of the class" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class{Name:string}
        \\Dog:=class(Animal){Tricks:i64}
        \\Cat:=class(Animal){Lives:i64}
        \\D:=Dog{Name:="rex",Tricks:=3}
        \\C:=Cat{Name:="tom",Lives:=9}
        \\Pets:[]Animal=array{D,C}
        \\Tricks(P:Animal)<transacts><decides>:i64=Block{Doggy:=Dog[P];Doggy.Tricks}
        \\First:i64=Attempt(Tricks[Pets[0]],-1)
        \\Second:i64=Attempt(Tricks[Pets[1]],-1)
        \\Widened:Animal=Animal[D]
        \\Name:string=Widened.Name
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Second").?.integer);
    try std.testing.expectEqualStrings("rex", x.get("Name").?.string);
}

test "overloads over a class and its subclass are rejected, unrelated ones resolve by type and a method varies by class" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076: overloads must be distinct. A class and a class below it are related, so the
    // second definition is refused; "the most specific overload wins" is gone.
    const related =
        \\Animal:=class{Name:string}
        \\Dog:=class(Animal){Tricks:i64}
        \\Puppy:=class(Dog){Age:i64}
        \\Kind(A:Animal)<transacts>:i64=1
        \\Kind(D:Dog)<transacts>:i64=2
        \\P:=Puppy{Name:="p",Tricks:=1,Age:=0}
        \\ForPuppy:i64=Kind(P)
    ;
    const refused = h.front.compile(related);
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.related_overloads, refused.failed.code);
    const second = std.mem.indexOf(u8, related, "Kind(D:Dog)").?;
    try std.testing.expectEqual(@as(usize, second), @as(usize, refused.failed.span.start));
    try std.testing.expectEqualStrings("Kind", related[refused.failed.span.start..refused.failed.span.end]);
    // Overloads over unrelated classes still resolve by the static type of the argument, a
    // subclass instance reaching the overload of its superclass; behaviour that varies by the
    // dynamic class is a method.
    const x = try h.execute(
        \\Animal:=class{
        \\  Name:string
        \\  Rank()<transacts>:i64=1
        \\}
        \\Dog:=class(Animal){
        \\  Tricks:i64
        \\  Rank<override>()<transacts>:i64=2
        \\}
        \\Puppy:=class(Dog){Age:i64}
        \\Rock:=class{Weight:i64}
        \\Kind(A:Animal)<transacts>:i64=1
        \\Kind(R:Rock)<transacts>:i64=3
        \\P:=Puppy{Name:="p",Tricks:=1,Age:=0}
        \\A:=Animal{Name:="a"}
        \\ForPuppy:i64=Kind(P)
        \\ForAnimal:i64=Kind(A)
        \\ForRock:i64=Kind(Rock{Weight:=5})
        \\Viewed:Animal=P
        \\ForViewed:i64=Kind(Viewed)
        \\RankPuppy:i64=P.Rank()
        \\RankAnimal:i64=A.Rank()
        \\RankViewed:i64=Viewed.Rank()
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("ForPuppy").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("ForAnimal").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("ForRock").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("ForViewed").?.integer);
    // Dispatch on the dynamic class comes with methods: the puppy answers as a dog, also when
    // it is viewed as an animal.
    try std.testing.expectEqual(@as(i64, 2), x.get("RankPuppy").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("RankAnimal").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("RankViewed").?.integer);
}

test "class declarations with parents and specifiers are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "Base:=class<final>{X:i64}\nKid:=class(Base){Y:i64}", .code = .invalid_parent },
        .{ .source = "Kid:=class(Base){Y:i64}\nBase:=class{X:i64}", .code = .invalid_parent },
        .{ .source = "Kid:=class(Kid){Y:i64}", .code = .invalid_parent },
        .{ .source = "Base:=class{X:i64}\nKid:=class(Base){X:i64}", .code = .duplicate_field },
        .{ .source = "Base:=class<abstract>{X:i64}\nB:=Base{X:=1}", .code = .abstract_instance },
        .{ .source = "Base:=class<abstract><final>{X:i64}", .code = .unsupported_specifier },
        .{ .source = "R:=struct{X:i64}\nKid:=class(R){Y:i64}", .code = .invalid_parent },
        .{ .source = "Base:=class{X:i64}\nKid:=class(Base){Y:i64}\nK:=Kid{X:=1,Y:=2}\nB:Base=K\nC:Kid=B", .code = .type_mismatch },
        .{ .source = "Base:=class{X:i64}\nOther:=class{X:i64}\nK:=Other{X:=1}\nB:Base=K", .code = .type_mismatch },
    };
    for (cases) |case| {
        const result = h.front.compile(case.source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("inheritance diagnostic for:\n{s}\nexpected {s}, got {s}\n", .{ case.source, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
    // An abstract class is a valid parent.
    _ = try h.execute("Base:=class<abstract>{X:i64}\nKid:=class(Base){}\nK:=Kid{X:=4}\nB:Base=K\nV:i64=B.X");
}
