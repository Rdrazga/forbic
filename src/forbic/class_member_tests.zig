//! Class and interface members beyond plain methods (RFC-0071): named and default arguments on
//! methods, default implementations and fields of interfaces, superclass methods that stand in
//! for interface methods, extension methods, `<concrete>`, `<castable>` and field overrides.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

const Case = struct { tail: []const u8, code: types.Diagnostic.Code };

fn expectDiagnostics(h: *harness.Harness, base: []const u8, cases: []const Case) !void {
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, case.tail });
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("class member diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.tail, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

test "methods take named and default arguments from the declaration the receiver's type sees" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Shape:=class{
        \\  var Size:i64=1
        \\  Grow(By:i64=1,Times:i64=1)<transacts>:i64=Block{set Self.Size=Self.Size+By*Times;Self.Size}
        \\  Tag(Prefix:string,Suffix:string="!")<transacts>:string=Prefix+Suffix
        \\  Count(Items:[]i64,Extra:option(i64)=option{})<transacts>:i64=Items.Length+If(Extra.IsSet,1,0)
        \\}
        \\Big:=class(Shape){
        \\  Grow<override>(By:i64=10,Times:i64=2)<transacts>:i64=Super.Grow(Times:=Times,By:=By)
        \\}
        \\Sizer:=interface{
        \\  Resize(To:i64,Scale:i64=3)<transacts>:i64
        \\}
        \\Box:=class(Sizer){
        \\  var W:i64=0
        \\  Resize<override>(To:i64,Scale:i64=5)<transacts>:i64=Block{set Self.W=To*Scale;Self.W}
        \\}
        \\S:=Shape{}
        \\A:i64=S.Grow()
        \\B:i64=S.Grow(5)
        \\C:i64=S.Grow(Times:=3)
        \\D:i64=S.Grow(Times:=2,By:=4)
        \\G:=Big{}
        \\E:i64=G.Grow()
        \\U:Shape=G
        \\F:i64=U.Grow()
        \\T:string=S.Tag("a")
        \\V:string=S.Tag(Suffix:="?",Prefix:="b")
        \\K:i64=S.Count(Extra:=option{4},Items:=array{})
        \\L:i64=S.Count(array{1,2})
        \\X:=Box{}
        \\H:i64=X.Resize(2)
        \\Y:Sizer=X
        \\I:i64=Y.Resize(2)
        \\J:i64=Y.Resize(Scale:=4,To:=2)
        \\Later(Z:Shape)<transacts>:i64=Z.Grow(Times:=0)+Z.Grow(By:=100)
        \\M:i64=Later(S)
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 18), x.get("D").?.integer);
    // `Big` restates the defaults, and a `Big` receiver uses them: 1 + 10 * 2.
    try std.testing.expectEqual(@as(i64, 21), x.get("E").?.integer);
    // Seen as a `Shape` the same instance is called with `Shape`'s defaults: 21 + 1 * 1.
    try std.testing.expectEqual(@as(i64, 22), x.get("F").?.integer);
    try std.testing.expectEqualStrings("a!", x.get("T").?.string);
    try std.testing.expectEqualStrings("b?", x.get("V").?.string);
    try std.testing.expectEqual(@as(i64, 1), x.get("K").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("L").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("H").?.integer);
    // The interface's default applies through the interface, the class's through the class.
    try std.testing.expectEqual(@as(i64, 6), x.get("I").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("J").?.integer);
    try std.testing.expectEqual(@as(i64, 18 + 118), x.get("M").?.integer);
}

test "named and default arguments of methods are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Shape:=class{
        \\  var Size:i64=1
        \\  Grow(By:i64=1,Times:i64=1)<transacts>:i64=Block{set Self.Size=Self.Size+By*Times;Self.Size}
        \\  Tag(Prefix:string,Suffix:string="!")<transacts>:string=Prefix+Suffix
        \\}
        \\S:=Shape{}
        \\
    ;
    try expectDiagnostics(h, base, &.{
        .{ .tail = "A:i64=S.Grow(Nope:=1)", .code = .unknown_parameter },
        .{ .tail = "A:i64=S.Grow(Self:=S)", .code = .unknown_parameter },
        .{ .tail = "A:i64=S.Grow(1,By:=2)", .code = .duplicate_argument },
        .{ .tail = "A:i64=S.Grow(By:=1,By:=2)", .code = .duplicate_argument },
        .{ .tail = "A:i64=S.Grow(By:=1,2)", .code = .named_argument_order },
        .{ .tail = "A:string=S.Tag()", .code = .argument_count },
        .{ .tail = "A:string=S.Tag(Suffix:=\"x\")", .code = .argument_count },
        .{ .tail = "A:i64=S.Grow(1,2,3)", .code = .argument_count },
        .{ .tail = "A:i64=S.Grow(By:=\"x\")", .code = .type_mismatch },
        .{ .tail = "Bad:=class{\n  M(X:i64=\"s\")<transacts>:i64=X\n}", .code = .type_mismatch },
        // A function value has no parameter names and no defaults.
        .{ .tail = "F:=S.Grow\nA:i64=F()", .code = .argument_count },
        .{ .tail = "F:=S.Grow\nA:i64=F(By:=1,Times:=2)", .code = .unknown_name },
    });
}

test "interfaces give default implementations that classes inherit, refine or replace" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Greeter:=interface{
        \\  Name()<transacts>:string
        \\  Greet()<transacts>:string="hello "+Self.Name()
        \\  Twice(N:i64)<transacts>:i64=N*2
        \\  Check(N:i64)<computes><decides>:i64=Block{Require[N>0];N}
        \\}
        \\Loud:=interface(Greeter){
        \\  Greet<override>()<transacts>:string="HEY "+Self.Name()
        \\}
        \\Plain:=class(Greeter){
        \\  Name<override>()<transacts>:string="plain"
        \\}
        \\Shouty:=class(Loud){
        \\  Name<override>()<transacts>:string="shouty"
        \\}
        \\Own:=class(Greeter){
        \\  Name<override>()<transacts>:string="own"
        \\  Greet<override>()<transacts>:string="yo "+Self.Name()
        \\}
        \\Child:=class(Plain){
        \\  Name<override>()<transacts>:string="child"
        \\  Greet<override>()<transacts>:string=Super.Greet()+"!"
        \\}
        \\Both:=class(Plain,Loud){}
        \\P:=Plain{}
        \\All:[]Greeter=array{P,Shouty{},Own{},Child{},Both{}}
        \\Say(Items:[]Greeter)<transacts>:[]string=For(Item:Items,Item.Greet())
        \\Said:[]string=Say(All)
        \\S0:string=Attempt(Said[0],"")
        \\S1:string=Attempt(Said[1],"")
        \\S2:string=Attempt(Said[2],"")
        \\S3:string=Attempt(Said[3],"")
        \\S4:string=Attempt(Said[4],"")
        \\Direct:string=P.Greet()
        \\Doubled:i64=P.Twice(4)
        \\Value:=P.Greet
        \\Called:string=Value()
        \\Passed:i64=Attempt(P.Check[3],-1)
        \\Failed:i64=Attempt(P.Check[0],-1)
        \\I:=interface{
        \\  F()<transacts>:i64=1
        \\}
        \\J:=interface(I){
        \\  F<override>()<transacts>:i64=2
        \\}
        \\K:=interface(I){
        \\  F<override>()<transacts>:i64=3
        \\}
        \\D:=class(J,K){
        \\  F<override>()<transacts>:i64=4
        \\}
        \\M:=interface(J,K){
        \\  F<override>()<transacts>:i64=5
        \\}
        \\E:=class(M){}
        \\OnlyJ:=class(J){}
        \\Chosen:i64=D{}.F()
        \\Merged:i64=E{}.F()
        \\Refined:i64=OnlyJ{}.F()
    );
    try std.testing.expectEqualStrings("hello plain", x.get("S0").?.string);
    try std.testing.expectEqualStrings("HEY shouty", x.get("S1").?.string);
    try std.testing.expectEqualStrings("yo own", x.get("S2").?.string);
    // `Super.Greet()` runs the interface's body, which asks the instance for its name.
    try std.testing.expectEqualStrings("hello child!", x.get("S3").?.string);
    // No class above `Both` declares `Greet`, so the most specific interface gives the body.
    try std.testing.expectEqualStrings("HEY plain", x.get("S4").?.string);
    try std.testing.expectEqualStrings("hello plain", x.get("Direct").?.string);
    try std.testing.expectEqual(@as(i64, 8), x.get("Doubled").?.integer);
    try std.testing.expectEqualStrings("hello plain", x.get("Called").?.string);
    try std.testing.expectEqual(@as(i64, 3), x.get("Passed").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Failed").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("Chosen").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("Merged").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Refined").?.integer);
}

test "default implementations are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\I:=interface{
        \\  F()<transacts>:i64=1
        \\  G()<transacts>:i64
        \\}
        \\J:=interface(I){
        \\  F<override>()<transacts>:i64=2
        \\}
        \\K:=interface(I){
        \\  F<override>()<transacts>:i64=3
        \\}
        \\N:=interface(I){
        \\  F<override>()<transacts>:i64
        \\}
        \\
    ;
    try expectDiagnostics(h, base, &.{
        // Two interfaces each refine the body and neither extends the other.
        .{ .tail = "C:=class(J,K){\n  G<override>()<transacts>:i64=0\n}", .code = .ambiguous_call },
        // A redeclaration without a body takes the default away again.
        .{ .tail = "C:=class(N){\n  G<override>()<transacts>:i64=0\n}", .code = .unimplemented_method },
        .{ .tail = "C:=class(I){}", .code = .unimplemented_method },
        // Two redeclarations without a body offer nothing to choose between.
        .{ .tail = "P:=interface(I){\n  F<override>()<transacts>:i64\n}\nC:=class(N,P){\n  G<override>()<transacts>:i64=0\n}", .code = .unimplemented_method },
        .{ .tail = "C:=class(I){\n  F()<transacts>:i64=9\n  G<override>()<transacts>:i64=0\n}", .code = .missing_override },
        .{ .tail = "L:=interface{\n  H()<transacts>:i64=\"x\"\n}", .code = .type_mismatch },
        // A final member of an interface has a body (RFC-0075), which nothing below replaces.
        .{ .tail = "L:=interface{\n  H<final>()<transacts>:i64\n}", .code = .invalid_interface },
        .{ .tail = "L:=interface{\n  H<final>()<transacts>:i64=1\n}\nC:=class(L){\n  H<override>()<transacts>:i64=2\n}", .code = .final_method },
        .{ .tail = "L:=interface(I){\n  F()<transacts>:i64=1\n}", .code = .missing_override },
        // A body in an interface sees only what the interface promises.
        .{ .tail = "L:=interface{\n  H()<transacts>:i64=Self.Missing\n}", .code = .unknown_field },
        .{ .tail = "L:=interface{\n  H()<computes>:i64=Self.H2()\n  H2()<transacts>:i64\n}", .code = .call_requires_transacts },
    });
}

test "interface fields live in the implementing class and are reached through accessors" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Entity:=interface{
        \\  Id:i64=7
        \\  var Health:i64=100
        \\  Name:string
        \\  Describe()<transacts>:string="{Self.Name}/{Self.Id}/{Self.Health}"
        \\  Hurt(By:i64)<transacts>:i64=Block{set Self.Health=Self.Health-By;Self.Health}
        \\}
        \\Tagged:=interface(Entity){
        \\  Tag:string="t"
        \\}
        \\Scored:=interface(Entity){
        \\  var Score:i64=0
        \\}
        \\Player:=class(Tagged,Scored){
        \\  Name<override>:string="player"
        \\  Id<override>:i64=9
        \\  Extra:i64=1
        \\}
        \\Base:=class{
        \\  Name:string="base"
        \\  var Health:i64=5
        \\}
        \\Monster:=class(Base,Entity){}
        \\Zero(X:Entity)<transacts><decides>:i64=Block{set X.Health=0;Require[X.Health>0];1}
        \\P:=Player{}
        \\M:=Monster{Health:=50}
        \\E:Entity=P
        \\A:string=E.Describe()
        \\B:i64=E.Hurt(30)
        \\C:i64=P.Health
        \\set E.Health=E.Health+5
        \\D:i64=P.Health
        \\S:Scored=P
        \\set S.Score=3
        \\set S.Health=S.Health-1
        \\T:Tagged=P
        \\F:i64=T.Health
        \\G:i64=P.Score
        \\Tg:string=T.Tag
        \\N:Entity=M
        \\H:string=N.Describe()
        \\I:i64=N.Hurt(8)
        \\J:i64=M.Health
        \\R:i64=Attempt(Zero[E],-1)
        \\W:i64=P.Health
        \\Q:=class(Entity){}
        \\Given:Entity=Q{Name:="q",Health:=1}
        \\Told:string=Given.Describe()
        \\Living:=interface{
        \\  var Health:i64=1
        \\}
        \\Ghost:=class(Monster,Living){}
        \\Gh:=Ghost{}
        \\AsLiving:Living=Gh
        \\AsEntity:Entity=Gh
        \\set AsLiving.Health=31
        \\Shared:i64=AsEntity.Health+Gh.Health
    );
    // A field the superclass already holds for one interface is the same field for another.
    try std.testing.expectEqual(@as(i64, 62), x.get("Shared").?.integer);
    try std.testing.expectEqualStrings("player/9/100", x.get("A").?.string);
    try std.testing.expectEqual(@as(i64, 70), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 70), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 75), x.get("D").?.integer);
    // `Health` arrives through two interfaces and is one field.
    try std.testing.expectEqual(@as(i64, 74), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("G").?.integer);
    try std.testing.expectEqualStrings("t", x.get("Tg").?.string);
    // `Monster` gets `Name` and `Health` from its superclass and only `Id` from the interface.
    try std.testing.expectEqualStrings("base/7/50", x.get("H").?.string);
    try std.testing.expectEqual(@as(i64, 42), x.get("I").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("J").?.integer);
    // A write through the setter is undone with the region that failed.
    try std.testing.expectEqual(@as(i64, -1), x.get("R").?.integer);
    try std.testing.expectEqual(@as(i64, 74), x.get("W").?.integer);
    try std.testing.expectEqualStrings("q/7/1", x.get("Told").?.string);
    // Player: Id, Health, Name, Tag, Score, Extra. Monster: Name, Health, Id. Q: Id, Health, Name.
    try std.testing.expectEqual(@as(usize, 7 + 4 + 4 + 4), x.object_cells.len);
}

test "interface fields are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Entity:=interface{
        \\  Id:i64=7
        \\  var Health:i64=100
        \\  Name:string
        \\}
        \\Other:=interface{
        \\  Id:i64=1
        \\}
        \\Wrong:=class{
        \\  Name:i64=1
        \\}
        \\Hidden:=class{
        \\  Name<private>:string="h"
        \\}
        \\Fixed:=class{
        \\  Health:i64=1
        \\}
        \\Ok:=class(Entity){
        \\  Name<override>:string="ok"
        \\}
        \\O:=Ok{}
        \\E:Entity=O
        \\
    ;
    try expectDiagnostics(h, base, &.{
        .{ .tail = "set E.Id=1", .code = .not_mutable },
        .{ .tail = "set O.Id=1", .code = .not_mutable },
        .{ .tail = "set E.Health=\"x\"", .code = .type_mismatch },
        .{ .tail = "X:i64=E.Missing", .code = .unknown_field },
        .{ .tail = "Q:=class(Entity){}\nV:=Q{}", .code = .missing_field },
        .{ .tail = "Q:=class(Entity){\n  Name:string=\"x\"\n}", .code = .duplicate_field },
        .{ .tail = "Q:=class(Entity){\n  Nope<override>:i64=1\n}", .code = .unexpected_override },
        .{ .tail = "Q:=class(Entity){\n  Id<override>:string=\"x\"\n}", .code = .override_mismatch },
        .{ .tail = "Q:=class(Entity){\n  var Id<override>:i64=1\n}", .code = .override_mismatch },
        .{ .tail = "Q:=class(Entity){\n  Id<override>:i64=1\n  Id<override>:i64=2\n}", .code = .duplicate_field },
        .{ .tail = "Q:=class(Entity){\n  Id<override><private>:i64=1\n}", .code = .override_mismatch },
        // Unrelated interfaces with one field name would need a qualifier.
        .{ .tail = "Q:=class(Entity,Other){}", .code = .duplicate_name },
        // A superclass field stands in only when it is the same public field.
        .{ .tail = "Q:=class(Wrong,Entity){}", .code = .duplicate_name },
        .{ .tail = "Q:=class(Hidden,Entity){}", .code = .duplicate_name },
        .{ .tail = "Q:=class(Fixed,Entity){}", .code = .duplicate_name },
        .{ .tail = "L:=interface{\n  V:i64=1\n  V()<transacts>:i64\n}", .code = .duplicate_name },
        .{ .tail = "L:=interface{\n  V:i64=1\n  V:i64=2\n}", .code = .duplicate_name },
        .{ .tail = "L:=interface(Entity){\n  Id:i64=2\n}", .code = .duplicate_name },
        .{ .tail = "L:=interface{\n  V<private>:i64=1\n}", .code = .invalid_interface },
        .{ .tail = "L:=interface{\n  V:i64=\"x\"\n}", .code = .type_mismatch },
        .{ .tail = "Q:=class(Entity){\n  Health()<transacts>:i64=1\n}", .code = .duplicate_name },
        // An accessor is a function of the field's name, so a binding may not share it.
        .{ .tail = "Health:i64=3", .code = .duplicate_name },
        .{ .tail = "Read(X:Entity)<computes>:i64=X.Id", .code = .field_read_requires_reads },
        .{ .tail = "V:=Entity{}", .code = .abstract_instance },
    });
}

test "a superclass method stands in for an interface method of the same signature" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Named:=interface{
        \\  Label()<transacts>:string
        \\  Rank(N:i64,Bonus:i64=10)<transacts>:i64
        \\}
        \\Fallback:=interface{
        \\  Label()<transacts>:string="fallback"
        \\}
        \\Unit:=class{
        \\  Label()<transacts>:string="unit"
        \\  Rank(N:i64,Bonus:i64=1)<transacts>:i64=N+Bonus
        \\}
        \\Knight:=class(Unit,Named){}
        \\Squire:=class(Knight){
        \\  Label<override>()<transacts>:string="squire"
        \\}
        \\Page:=class(Squire,Fallback){}
        \\K:Named=Knight{}
        \\S:=Squire{}
        \\Q:Named=S
        \\A:string=K.Label()
        \\B:string=Q.Label()
        \\C:i64=Q.Rank(4)
        \\D:string=S.Label()
        \\E:i64=S.Rank(4)
        \\G:=Page{}
        \\F:Fallback=G
        \\H:string=F.Label()
        \\N:Named=G
        \\I:string=N.Label()
        \\J:string=G.Label()
        \\Back:string=Attempt(Block{U:=Unit[Q];U.Label()},"none")
    );
    try std.testing.expectEqualStrings("unit", x.get("A").?.string);
    // The interface slot forwards through the dispatch table, so the override runs.
    try std.testing.expectEqualStrings("squire", x.get("B").?.string);
    // Through the interface the interface's default applies, through the class the class's.
    try std.testing.expectEqual(@as(i64, 14), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("E").?.integer);
    try std.testing.expectEqualStrings("squire", x.get("D").?.string);
    // The method the class already has wins over an interface's default body.
    try std.testing.expectEqualStrings("squire", x.get("H").?.string);
    try std.testing.expectEqualStrings("squire", x.get("I").?.string);
    try std.testing.expectEqualStrings("squire", x.get("J").?.string);
    try std.testing.expectEqualStrings("squire", x.get("Back").?.string);
}

test "a superclass method that does not match an interface method is still a clash" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Unit:=class{
        \\  Label()<transacts>:string="unit"
        \\  Secret<private>()<transacts>:i64=1
        \\  Count:i64=0
        \\}
        \\
    ;
    try expectDiagnostics(h, base, &.{
        .{ .tail = "I:=interface{\n  Label()<transacts>:i64\n}\nC:=class(Unit,I){}", .code = .duplicate_name },
        .{ .tail = "I:=interface{\n  Label(N:i64)<transacts>:string\n}\nC:=class(Unit,I){}", .code = .duplicate_name },
        // The inherited method may narrow the slot's effects (RFC-0078), never widen them.
        .{ .tail = "I:=interface{\n  Label()<computes><decides>:string\n}\nC:=class(Unit,I){}", .code = .override_widens_reads },
        .{ .tail = "I:=interface{\n  Secret()<transacts>:i64\n}\nC:=class(Unit,I){}", .code = .duplicate_name },
        // A method does not stand in for a field, nor a field for a method.
        .{ .tail = "I:=interface{\n  Label:string=\"x\"\n}\nC:=class(Unit,I){}", .code = .duplicate_name },
        .{ .tail = "I:=interface{\n  Count()<transacts>:i64=1\n}\nC:=class(Unit,I){}", .code = .duplicate_name },
        .{ .tail = "I:=interface{\n  F()<transacts>:i64\n}\nJ:=interface{\n  F()<transacts>:i64\n}\nC:=class(Unit,I,J){\n  F<override>()<transacts>:i64=1\n}", .code = .duplicate_name },
    });
}

test "extension methods are called on values of any type and resolved statically" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\(V:i64).Double()<computes>:i64=V*2
        \\(V:i64).Plus(N:i64=1,Scale:i64=1)<computes>:i64=(V+N)*Scale
        \\(N:i64).Fact()<computes>:i64=If(N<=1,1,N*(N-1).Fact())
        \\(S:string).Shout()<computes>:string=S+"!"
        \\(B:logic).Flip()<computes>:logic=not B
        \\(F:float).Half()<computes>:float=F/2.0
        \\(Items:[]i64).First()<computes><decides>:i64=Items[0]
        \\(Items:[]i64).Count()<computes>:i64=Items.Length
        \\(M:map(string,i64)).Has(Key:string)<computes>:logic=Lookup(M,Key).IsSet
        \\(P:tuple(i64,i64)).Total()<computes>:i64=P(0)+P(1)
        \\(O:option(i64)).OrZero()<computes>:i64=Or(O,0)
        \\Point:=struct{X:i64,Y:i64}
        \\(P:Point).Norm()<computes>:i64=P.X*P.X+P.Y*P.Y
        \\Color:=enum{Red,Green}
        \\(C:Color).IsRed()<computes>:logic=C==Color.Red
        \\Counter:=class{
        \\  var N:i64=0
        \\  Bump()<transacts>:i64=Block{set Self.N=Self.N+1;Self.N}
        \\}
        \\Deep:=class(Counter){
        \\  Show()<transacts>:string="member"
        \\}
        \\(C:Counter).BumpBy(By:i64)<transacts>:i64=Block{set C.N=C.N+By;C.N}
        \\Shape:=interface{
        \\  Area()<transacts>:i64
        \\}
        \\Sq:=class(Shape){
        \\  Side:i64=3
        \\  Area<override>()<transacts>:i64=Self.Side*Self.Side
        \\}
        \\(S:Shape).DoubleArea()<transacts>:i64=S.Area()*2
        \\(V:i64).Show()<computes>:string="int"
        \\(V:string).Show()<computes>:string="text"
        \\Other:=class{}
        \\(V:Other).Show()<computes>:string="other"
        \\Five:i64=5
        \\A:i64=7.Double()
        \\B:i64=Five.Double().Double()
        \\C:i64=3.Plus()
        \\D:i64=3.Plus(Scale:=2)
        \\E:i64=3.Plus(2,3)
        \\F:i64=5.Fact()
        \\G:string="a".Shout()
        \\H:logic=true.Flip()
        \\I:float=1.5.Half()
        \\Empty:[]i64=array{}
        \\J:i64=Attempt(array{4,5}.First[],-1)
        \\K:i64=Attempt(Empty.First[],-1)
        \\L:i64=array{4,5}.Count()
        \\Ages:map(string,i64)=map{"a"=>1}
        \\M:logic=Ages.Has("a")
        \\N:i64=tuple{3,4}.Total()
        \\Some:option(i64)=option{5}
        \\O:i64=Some.OrZero()
        \\P:i64=Point{X:=3,Y:=4}.Norm()
        \\Q:logic=Color.Red.IsRed()
        \\Cn:=Counter{}
        \\R:i64=Cn.BumpBy(5)
        \\S:i64=Cn.Bump()
        \\Sv:=Sq{}
        \\T:i64=Sv.DoubleArea()
        \\U:string=1.Show()
        \\V:string="s".Show()
        \\W:string=Other{}.Show()
        \\Dp:=Deep{}
        \\X:string=Dp.Show()
        \\Y:i64=Dp.BumpBy(2)
        \\Z:[]i64=For(Each:array{1,2,3},Each.Double())
        \\Z1:i64=Attempt(Z[2],-1)
        \\Sum:i64=1+2.Double()*3
    );
    try std.testing.expectEqual(@as(i64, 14), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 20), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 15), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 120), x.get("F").?.integer);
    try std.testing.expectEqualStrings("a!", x.get("G").?.string);
    try std.testing.expectEqual(false, x.get("H").?.boolean);
    try std.testing.expectEqual(@as(f64, 0.75), x.get("I").?.floating);
    try std.testing.expectEqual(@as(i64, 4), x.get("J").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("K").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("L").?.integer);
    try std.testing.expectEqual(true, x.get("M").?.boolean);
    try std.testing.expectEqual(@as(i64, 7), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("O").?.integer);
    try std.testing.expectEqual(@as(i64, 25), x.get("P").?.integer);
    try std.testing.expectEqual(true, x.get("Q").?.boolean);
    try std.testing.expectEqual(@as(i64, 5), x.get("R").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("S").?.integer);
    try std.testing.expectEqual(@as(i64, 18), x.get("T").?.integer);
    try std.testing.expectEqualStrings("int", x.get("U").?.string);
    try std.testing.expectEqualStrings("text", x.get("V").?.string);
    // Extension methods of one name on unrelated types (also two unrelated classes) are told
    // apart by the receiver's type.
    try std.testing.expectEqualStrings("other", x.get("W").?.string);
    // A member of the receiver's class is found beside extension methods of its name on other types.
    try std.testing.expectEqualStrings("member", x.get("X").?.string);
    try std.testing.expectEqual(@as(i64, 2), x.get("Y").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("Z1").?.integer);
    try std.testing.expectEqual(@as(i64, 13), x.get("Sum").?.integer);

    // RFC-0076: definitions of one name must be distinct. An extension method on a class beside
    // a method of that name in a subclass, or beside an extension on a subclass or on an
    // interface the class could implement, was resolved by the receiver's static type; now the
    // second definition is refused where it is named.
    const related = [_]struct { source: []const u8, at: []const u8 }{
        .{ .source = "Counter:=class{var N:i64=0}\nDeep:=class(Counter){\n  Show()<transacts>:string=\"member\"\n}\n(V:Counter).Show()<computes>:string=\"counter\"", .at = "Show()<computes>" },
        .{ .source = "Counter:=class{var N:i64=0}\nDeep:=class(Counter){}\n(V:Counter).Tag()<computes>:string=\"counter\"\n(V:Deep).Tag()<computes>:string=\"deep\"", .at = "Tag()<computes>:string=\"deep\"" },
        .{ .source = "Counter:=class{var N:i64=0}\nDeep:=class(Counter){}\n(V:Deep).Tag()<computes>:string=\"deep\"\n(V:Counter).Tag()<computes>:string=\"counter\"", .at = "Tag()<computes>:string=\"counter\"" },
        .{ .source = "Shape:=interface{\n  Area()<transacts>:i64\n}\nCounter:=class{var N:i64=0}\n(V:Shape).Tag()<transacts>:string=\"shape\"\n(V:Counter).Tag()<transacts>:string=\"counter\"", .at = "Tag()<transacts>:string=\"counter\"" },
    };
    for (related) |case| {
        const refused = h.front.compile(case.source);
        if (refused == .ok or refused.failed.code != .related_overloads) {
            std.debug.print("related extension methods for:\n{s}\ngot {s}\n", .{ case.source, if (refused == .ok) "success" else @tagName(refused.failed.code) });
            return error.WrongDiagnostic;
        }
        const name = case.at[0..std.mem.indexOfScalar(u8, case.at, '(').?];
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.at).?, @as(usize, refused.failed.span.start));
        try std.testing.expectEqualStrings(name, case.source[refused.failed.span.start..refused.failed.span.end]);
    }
    // A final class cannot come to implement the interface, so the two stay distinct.
    const final = try h.execute("Shape:=interface{\n  Area()<transacts>:i64\n}\nCounter:=class<final>{var N:i64=0}\n(V:Shape).Tag()<transacts>:string=\"shape\"\n(V:Counter).Tag()<transacts>:string=\"counter\"\nA:string=Counter{}.Tag()");
    try std.testing.expectEqualStrings("counter", final.get("A").?.string);
}

test "extension methods are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\(V:i64).Double()<computes>:i64=V*2
        \\(V:i64).Try()<computes><decides>:i64=Block{Require[V>0];V}
        \\Counter:=class{
        \\  var N:i64=0
        \\  Bump()<transacts>:i64=Block{set Self.N=Self.N+1;Self.N}
        \\}
        \\Plain(X:i64)<computes>:i64=X
        \\Bound:i64=1
        \\
    ;
    try expectDiagnostics(h, base, &.{
        // Only `Value.Name(...)` names an extension method.
        .{ .tail = "A:i64=Double(3)", .code = .unknown_name },
        .{ .tail = "A:=Double", .code = .unknown_name },
        .{ .tail = "A:=7.Double", .code = .expected_call },
        .{ .tail = "A:i64=7.Nope()", .code = .type_mismatch },
        .{ .tail = "A:i64=\"s\".Double()", .code = .type_mismatch },
        .{ .tail = "A:i64=7.Double(1)", .code = .argument_count },
        .{ .tail = "A:i64=7.Double(Q:=1)", .code = .unknown_parameter },
        .{ .tail = "A:i64=7.Double(V:=1)", .code = .duplicate_argument },
        .{ .tail = "A:i64=7.Try[]", .code = .failure_context_required },
        .{ .tail = "A:i64=Attempt(7.Try(),0)", .code = .expected_call },
        .{ .tail = "A:i64=Iterate(Double,3,1)", .code = .unknown_name },
        // A member of the receiver's class would always win, so the extension is refused.
        .{ .tail = "(C:Counter).Bump()<transacts>:i64=1", .code = .duplicate_name },
        .{ .tail = "(C:Counter).N()<transacts>:i64=1", .code = .duplicate_name },
        .{ .tail = "(S:string).Length()<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(S:[]i64).Length()<computes>:i64=1", .code = .duplicate_name },
        // One name is called one way: as a function or as an extension method.
        .{ .tail = "(V:i64).Plain()<computes>:i64=V", .code = .duplicate_name },
        .{ .tail = "Double(X:string)<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(V:i64).Double()<computes>:i64=V", .code = .duplicate_name },
        .{ .tail = "(V:i64).Bound()<computes>:i64=V", .code = .duplicate_name },
        .{ .tail = "(V:string).Double()<computes><decides>:i64=1", .code = .overload_conflict },
        .{ .tail = "(V:i64,W:i64).Pair()<computes>:i64=V", .code = .expected_parameter },
        .{ .tail = "(V:i64)Pair()<computes>:i64=V", .code = .expected_name },
        .{ .tail = "(V:Nope).Pair()<computes>:i64=1", .code = .unsupported_type },
        // Declared before the class, an extension with a method's signature is found there.
        .{ .tail = "(X:Later).M()<transacts>:i64=1\nLater:=class{\n  M()<transacts>:i64=2\n}", .code = .duplicate_name },
        .{ .tail = "M(X:Later)<transacts>:i64=1\nLater:=class{\n  M()<transacts>:i64=2\n}", .code = .duplicate_name },
    });
}

test "extension methods are scoped like functions across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "(S:string).Shout<public>()<computes>:string=S+\"!\"\n(S:string).Wrap<public>(Open:string,Close:string=\">\")<computes>:string=Open+S+Close\n(S:string).Quiet()<computes>:string=S\n(V:i64).Shout<public>()<computes>:string=\"n\"\n(V:logic).Shout()<computes>:string=\"hidden\"\nEntity<public>:=interface{\n  var Health<public>:i64=10\n  Hurt<public>(By:i64=1)<transacts>:i64=Block{set Self.Health=Self.Health-By;Self.Health}\n}\n(E:Entity).Left<public>()<transacts>:i64=E.Health";
    const good = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:string=\"a\".Shout()\nB<public>:string=\"a\".Wrap(\"<\")+\"a\".Wrap(\"[\",Close:=\"]\")\nC<public>:string=3.Shout()\nP:=class(Entity){}\nX:=P{}\nE:Entity=X\nD<public>:i64=E.Hurt()\nF<public>:i64=E.Left()\nG<public>:i64=X.Left()\nset E.Health=4\nH<public>:i64=X.Health" },
        .{ .path = "lib.forb", .source = lib },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &good });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 20_000);
    try std.testing.expectEqualStrings("a!", result.ok.get("A").?.string);
    try std.testing.expectEqualStrings("<a>[a]", result.ok.get("B").?.string);
    try std.testing.expectEqualStrings("n", result.ok.get("C").?.string);
    try std.testing.expectEqual(@as(i64, 9), result.ok.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 9), result.ok.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 9), result.ok.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.ok.get("H").?.integer);

    const refused = [_]struct { main: []const u8, code: types.Diagnostic.Code }{
        // Not exported, not imported with `using`, and a private overload of an exported name.
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:string=\"a\".Quiet()", .code = .unknown_field },
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:string=\"a\".Shout()", .code = .unknown_field },
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:string=true.Shout()", .code = .private_name },
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:string=Shout(\"a\")", .code = .unknown_name },
        // `Super` names a body directly, and a body in another module is not exported.
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nBase:=class(Entity){}\nQ:=class(Base){\n  Hurt<override>(By:i64=1)<transacts>:i64=Super.Hurt(By)\n}", .code = .private_name },
    };
    for (refused) |case| {
        const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = case.main }, .{ .path = "lib.forb", .source = lib } };
        const failed = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if (failed == .ok or failed.failed.diagnostic.code != case.code) {
            std.debug.print("module diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.main, @tagName(case.code), if (failed == .ok) "success" else @tagName(failed.failed.diagnostic.code) });
            return error.WrongDiagnostic;
        }
    }
    const two = [_]modules.Input{
        .{ .path = "main.forb", .source = "A:=import{\"a.forb\"}\nB:=import{\"b.forb\"}\nusing{A}\nusing{B}\nV<public>:i64=1.Dup()" },
        .{ .path = "a.forb", .source = "(V:i64).Dup<public>()<computes>:i64=V" },
        .{ .path = "b.forb", .source = "(V:i64).Dup<public>()<computes>:i64=V+1" },
    };
    const ambiguous = h.front.compileBundle(.{ .root = "main.forb", .modules = &two });
    try std.testing.expect(ambiguous == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.ambiguous_call, ambiguous.failed.diagnostic.code);
    // The module's own extension method wins over a used module's.
    const own = [_]modules.Input{
        .{ .path = "main.forb", .source = "A:=import{\"a.forb\"}\nusing{A}\n(V:i64).Dup()<computes>:i64=V*10\nV<public>:i64=2.Dup()" },
        .{ .path = "a.forb", .source = "(V:i64).Dup<public>()<computes>:i64=V" },
    };
    const mine = h.front.compileBundle(.{ .root = "main.forb", .modules = &own });
    try std.testing.expect(mine == .ok);
    try std.testing.expectEqual(@as(i64, 20), (try h.run(mine.ok, 20_000)).ok.get("V").?.integer);
}

test "concrete classes, castable classes and restated field defaults" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Config:=class<concrete>{
        \\  Players:i64=8
        \\  Name:string="x"
        \\}
        \\Has:=interface{
        \\  Field:i64
        \\}
        \\Thing:=class<concrete>(Has){
        \\  Field<override>:i64=4
        \\}
        \\Open:=class(Config){
        \\  Needed:i64
        \\}
        \\Part:=class<castable><abstract>{
        \\  Speed:i64=1
        \\  Get()<transacts>:i64=Self.Speed
        \\}
        \\Slow:=class<castable>(Part){}
        \\Fast:=class(Part){
        \\  Speed<override>:i64=2
        \\}
        \\A:i64=Config{}.Players
        \\B:i64=Thing{}.Field
        \\C:i64=Open{Needed:=3}.Players
        \\D:i64=Slow{}.Get()
        \\E:i64=Fast{}.Get()
        \\F:i64=Fast{Speed:=9}.Get()
        \\Up:Part=Fast{}
        \\G:i64=Attempt(Block{Down:=Fast[Up];Down.Speed},-1)
        \\H:i64=Attempt(Block{Down:=Slow[Up];Down.Speed},-1)
    );
    try std.testing.expectEqual(@as(i64, 8), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("D").?.integer);
    // The method is inherited unchanged and reads the default its own class restated.
    try std.testing.expectEqual(@as(i64, 2), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("H").?.integer);
    try expectDiagnostics(h, "Has:=interface{\n  Field:i64\n}\nVarHas:=interface{\n  var Field:i64\n}\nBase:=class{\n  Speed:i64=1\n  Hidden<private>:i64=1\n}\n", &.{
        .{ .tail = "C:=class<concrete>{\n  A:i64\n}", .code = .missing_field },
        .{ .tail = "C:=class<concrete>(Has){}", .code = .missing_field },
        // Restating the member without a value does not give it one.
        .{ .tail = "C:=class<concrete>(Has){\n  Field<override>:i64\n}", .code = .missing_field },
        .{ .tail = "C:=class<concrete>(VarHas){}", .code = .missing_field },
        .{ .tail = "Open:=class{\n  A:i64\n}\nC:=class<concrete>(Open){}", .code = .missing_field },
        .{ .tail = "C:=class<concrete><concrete>{}", .code = .unsupported_specifier },
        .{ .tail = "C:=class<castable><castable>{}", .code = .unsupported_specifier },
        .{ .tail = "C:=interface<concrete>{}", .code = .unsupported_specifier },
        .{ .tail = "C:=class(Base){\n  Speed<override>:string=\"x\"\n}", .code = .override_mismatch },
        .{ .tail = "C:=class(Base){\n  Hidden<override>:i64=2\n}", .code = .inaccessible_member },
        .{ .tail = "C:=class(Base){\n  Speed<override>:i64=\"x\"\n}", .code = .type_mismatch },
        .{ .tail = "C:=class{\n  Speed<override>:i64=2\n}", .code = .unexpected_override },
    });
}

const Forged = struct {
    arguments: []u32,
    dispatch: []types.Dispatch,
    program: types.Program,

    fn init(p: types.Program) !Forged {
        return .{ .arguments = try std.testing.allocator.dupe(u32, p.call_arguments), .dispatch = try std.testing.allocator.dupe(types.Dispatch, p.dispatch), .program = p };
    }
    fn deinit(self: *Forged) void {
        std.testing.allocator.free(self.arguments);
        std.testing.allocator.free(self.dispatch);
    }
    fn view(self: *const Forged) types.Program {
        var forged = self.program;
        forged.call_arguments = self.arguments;
        forged.dispatch = self.dispatch;
        return forged;
    }
    fn reset(self: *Forged) void {
        @memcpy(self.arguments, self.program.call_arguments);
        @memcpy(self.dispatch, self.program.dispatch);
    }
};

test "an accessor reached for an instance of another class traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // `V` is cell 0 of a `Thin` and cell 1 of a `Wide`: an accessor run on the wrong one would
    // read or write its neighbour.
    const p = try h.compile(
        \\Holder:=interface{
        \\  var V:i64=1
        \\}
        \\Thin:=class(Holder){}
        \\Pad:=class{
        \\  var X:i64=5
        \\}
        \\Wide:=class(Pad,Holder){}
        \\A:=Thin{}
        \\B:=Wide{}
        \\U:Holder=A
        \\W:Holder=B
        \\R:i64=U.V
        \\set U.V=9
        \\S:i64=A.V
    );
    var forge = try Forged.init(p);
    defer forge.deinit();
    const run = try h.run(forge.view(), 10_000);
    try std.testing.expectEqual(@as(i64, 1), run.ok.get("R").?.integer);
    try std.testing.expectEqual(@as(i64, 9), run.ok.get("S").?.integer);
    var upcasts: [2]u32 = undefined;
    var seen: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .upcast and seen < 2) {
        upcasts[seen] = @intCast(index);
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expect(p.nodes[upcasts[0]].value_type == p.nodes[upcasts[1]].value_type);
    // The getter and the setter looked up on the `Thin` are applied to the `Wide`. Every type
    // matches the slot's signature; only the accessor's own narrowing of `Self` can notice.
    var calls: usize = 0;
    for (p.nodes) |node| if (node.kind == .invoke) {
        const first = node.kind.invoke.arguments.start;
        try std.testing.expectEqual(upcasts[0], p.call_arguments[first]);
        forge.arguments[first] = upcasts[1];
        try harness.traps(h, forge.view(), 10_000);
        forge.reset();
        calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), calls);
    // A dispatch table that hands one class the accessor of the other is admitted, since both
    // have the slot's signature, and traps the same way when it runs.
    var swapped: usize = 0;
    for (forge.dispatch, 0..) |entry, index| {
        for (forge.dispatch[index + 1 ..]) |*other| {
            if (other.slot != entry.slot or other.class == entry.class or other.function == entry.function) continue;
            if (p.definitions[@backingInt(entry.class) - 4].class.is_abstract or p.definitions[@backingInt(other.class) - 4].class.is_abstract) continue;
            std.mem.swap(u32, &forge.dispatch[index].function, &other.function);
            try harness.traps(h, forge.view(), 10_000);
            forge.reset();
            swapped += 1;
        }
    }
    // The getter and the setter, each between `Thin` and `Wide`.
    try std.testing.expectEqual(@as(usize, 2), swapped);
    _ = try h.run(forge.view(), 10_000);
}

test "a forwarder and a default body applied to a foreign instance trap in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Named:=interface{
        \\  Label()<transacts>:string
        \\}
        \\Unit:=class{
        \\  var Hits:i64=3
        \\  Label()<transacts>:string="unit"
        \\}
        \\Knight:=class(Unit,Named){}
        \\Lone:=class(Named){
        \\  Label<override>()<transacts>:string="lone"
        \\}
        \\K:=Knight{}
        \\L:=Lone{}
        \\A:Named=K
        \\B:Named=L
        \\R:string=A.Label()
    );
    var forge = try Forged.init(p);
    defer forge.deinit();
    const run = try h.run(forge.view(), 10_000);
    try std.testing.expectEqualStrings("unit", run.ok.get("R").?.string);
    var upcasts: [2]u32 = undefined;
    var seen: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .upcast and seen < 2) {
        upcasts[seen] = @intCast(index);
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), seen);
    // `Knight`'s forwarder, looked up on the knight, is handed the `Lone`, which has no
    // `Unit` part: the forwarder's narrowing to `Unit` stops it.
    for (p.nodes) |node| if (node.kind == .invoke) {
        const first = node.kind.invoke.arguments.start;
        try std.testing.expectEqual(upcasts[0], p.call_arguments[first]);
        forge.arguments[first] = upcasts[1];
    };
    try harness.traps(h, forge.view(), 10_000);
}

test "a class may name its fields in the module of an interface it implements and nowhere else" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nO:=import{\"other.forb\"}\nP:=class(L.Entity){\n  Own:i64=1\n}\nPlain:=class{\n  Mine:i64=2\n}\nA<public>:i64=P{}.Health+Plain{}.Mine+O.Stray" },
        .{ .path = "lib.forb", .source = "Entity<public>:=interface{\n  var Health<public>:i64=10\n}\nUnused<public>:i64=0" },
        .{ .path = "other.forb", .source = "Stray<public>:i64=5\nLonely<public>:i64=1" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const p = bundled.ok;
    try std.testing.expectEqual(@as(i64, 17), (try h.run(p, 20_000)).ok.get("A").?.integer);
    const fields = try std.testing.allocator.dupe(types.Field, p.fields);
    defer std.testing.allocator.free(fields);
    var forged = p;
    forged.fields = fields;
    const named = struct {
        fn at(program: types.Program, text: []const u8) types.Span {
            const start: u32 = @intCast(std.mem.indexOf(u8, program.source, text).?);
            return .{ .start = start, .end = start + @as(u32, @intCast(text.len)) };
        }
        fn field(program: types.Program, list: []const types.Field, text: []const u8) usize {
            for (list, 0..) |entry, index| if (std.mem.eql(u8, entry.name.text(program.source), text)) return index;
            unreachable;
        }
    };
    // The interface's field is named where the interface declared it: another module.
    const health = named.field(p, fields, "Health");
    try std.testing.expect(modules.owner(fields[health].name, p.modules).? != modules.owner(fields[named.field(p, fields, "Own")].name, p.modules).?);
    // Named in a module that declares no interface of the class: refused.
    fields[health].name = named.at(p, "Lonely");
    try harness.invalid(h, forged);
    @memcpy(fields, p.fields);
    // A class without interfaces still names every field of its own in its own module.
    fields[named.field(p, fields, "Mine")].name = named.at(p, "Unused");
    try harness.invalid(h, forged);
    @memcpy(fields, p.fields);
    _ = try h.run(forged, 20_000);
}

const Model = struct {
    const max_classes = 6;
    const max_objects = 5;
    const Class = struct { parent: ?usize, v: ?i64, k: ?i64, get_scale: ?i64, add_default: ?i64 };
    classes: [max_classes]Class = undefined,
    class_count: usize = 0,
    v_default: i64 = 0,
    k_default: i64 = 0,
    add_default: i64 = 0,
    bias_default: i64 = 0,
    object_class: [max_objects]usize = undefined,
    object_v: [max_objects]i64 = undefined,
    object_count: usize = 0,

    fn nearest(self: *const Model, class: usize, comptime field: []const u8) ?i64 {
        var at: ?usize = class;
        while (at) |index| : (at = self.classes[index].parent) if (@field(self.classes[index], field)) |value| return value;
        return null;
    }
    fn get(self: *const Model, object: usize) i64 {
        const class = self.object_class[object];
        const k = self.nearest(class, "k") orelse self.k_default;
        return if (self.nearest(class, "get_scale")) |scale| self.object_v[object] * scale else self.object_v[object] + k;
    }
    /// An override of `Add` adds twice what it is given; the default body adds it once.
    fn add(self: *Model, object: usize, by: i64) i64 {
        const doubled = self.nearest(self.object_class[object], "add_default") != null;
        self.object_v[object] += if (doubled) by * 2 else by;
        return self.object_v[object];
    }
};

test "random hierarchies with interface fields, defaults and extension methods match a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x71_c1a55);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    for (0..60) |round| {
        source.clearRetainingCapacity();
        var model: Model = .{};
        model.v_default = random.intRangeAtMost(i64, 0, 9);
        model.k_default = random.intRangeAtMost(i64, 0, 9);
        model.add_default = random.intRangeAtMost(i64, 1, 5);
        model.bias_default = random.intRangeAtMost(i64, 0, 5);
        try source.print(a, "I:=interface{{\n  var V:i64={d}\n  K:i64={d}\n  Get()<transacts>:i64=Self.V+Self.K\n  Add(By:i64={d})<transacts>:i64=Block{{set Self.V=Self.V+By;Self.V}}\n}}\n", .{ model.v_default, model.k_default, model.add_default });
        try source.print(a, "(X:I).Peek(Bias:i64={d})<transacts>:i64=X.Get()+Bias\n", .{model.bias_default});
        model.class_count = random.intRangeAtMost(usize, 1, Model.max_classes);
        for (0..model.class_count) |index| {
            var class: Model.Class = .{ .parent = null, .v = null, .k = null, .get_scale = null, .add_default = null };
            if (index != 0 and random.boolean()) class.parent = random.uintLessThan(usize, index);
            if (class.parent) |parent| try source.print(a, "C{d}:=class(C{d}){{\n", .{ index, parent }) else try source.print(a, "C{d}:=class(I){{\n", .{index});
            // A field of the class in front of the interface's moves them to other cells.
            if (class.parent == null and random.boolean()) try source.print(a, "  Pad{d}:i64=0\n", .{index});
            if (random.boolean()) {
                class.v = random.intRangeAtMost(i64, 10, 19);
                try source.print(a, "  var V<override>:i64={d}\n", .{class.v.?});
            }
            if (random.boolean()) {
                class.k = random.intRangeAtMost(i64, 20, 29);
                try source.print(a, "  K<override>:i64={d}\n", .{class.k.?});
            }
            if (random.uintLessThan(u8, 3) == 0) {
                class.get_scale = random.intRangeAtMost(i64, 2, 4);
                try source.print(a, "  Get<override>()<transacts>:i64=Self.V*{d}\n", .{class.get_scale.?});
            }
            if (random.uintLessThan(u8, 3) == 0) {
                class.add_default = random.intRangeAtMost(i64, 6, 9);
                try source.print(a, "  Add<override>(By:i64={d})<transacts>:i64=Block{{set Self.V=Self.V+By*2;Self.V}}\n", .{class.add_default.?});
            }
            try source.appendSlice(a, "}\n");
            model.classes[index] = class;
        }
        model.object_count = random.intRangeAtMost(usize, 1, Model.max_objects);
        for (0..model.object_count) |index| {
            const class = random.uintLessThan(usize, model.class_count);
            model.object_class[index] = class;
            model.object_v[index] = model.nearest(class, "v") orelse model.v_default;
            try source.print(a, "O{d}:=C{d}{{}}\nN{d}:I=O{d}\n", .{ index, class, index, index });
        }
        var expected: [40]i64 = undefined;
        var results: usize = 0;
        for (0..40) |_| {
            const object = random.uintLessThan(usize, model.object_count);
            const class = model.object_class[object];
            const amount = random.intRangeAtMost(i64, 1, 9);
            const name = results;
            switch (random.uintLessThan(u8, 12)) {
                0 => {
                    try source.print(a, "R{d}:i64=N{d}.Get()\n", .{ name, object });
                    expected[results] = model.get(object);
                },
                1 => {
                    try source.print(a, "R{d}:i64=O{d}.Get()\n", .{ name, object });
                    expected[results] = model.get(object);
                },
                2 => {
                    // Through the interface the interface's default applies.
                    try source.print(a, "R{d}:i64=N{d}.Add()\n", .{ name, object });
                    expected[results] = model.add(object, model.add_default);
                },
                3 => {
                    // Through the class the nearest declaration above it gives the default.
                    try source.print(a, "R{d}:i64=O{d}.Add()\n", .{ name, object });
                    expected[results] = model.add(object, model.nearest(class, "add_default") orelse model.add_default);
                },
                4 => {
                    try source.print(a, "R{d}:i64=N{d}.Add({d})\n", .{ name, object, amount });
                    expected[results] = model.add(object, amount);
                },
                5 => {
                    try source.print(a, "R{d}:i64=O{d}.Add(By:={d})\n", .{ name, object, amount });
                    expected[results] = model.add(object, amount);
                },
                6 => {
                    try source.print(a, "set N{d}.V={d}\n", .{ object, amount });
                    model.object_v[object] = amount;
                    continue;
                },
                7 => {
                    try source.print(a, "set O{d}.V=O{d}.V+{d}\n", .{ object, object, amount });
                    model.object_v[object] += amount;
                    continue;
                },
                8 => {
                    try source.print(a, "R{d}:i64=N{d}.V\n", .{ name, object });
                    expected[results] = model.object_v[object];
                },
                9 => {
                    try source.print(a, "R{d}:i64=N{d}.K+O{d}.K\n", .{ name, object, object });
                    expected[results] = 2 * (model.nearest(class, "k") orelse model.k_default);
                },
                10 => {
                    try source.print(a, "R{d}:i64=N{d}.Peek()\n", .{ name, object });
                    expected[results] = model.get(object) + model.bias_default;
                },
                else => {
                    try source.print(a, "R{d}:i64=O{d}.Peek(Bias:={d})\n", .{ name, object, amount });
                    expected[results] = model.get(object) + amount;
                },
            }
            results += 1;
        }
        const x = h.execute(source.items) catch |err| {
            std.debug.print("round {d} failed:\n{s}\n", .{ round, source.items });
            return err;
        };
        var buffer: [16]u8 = undefined;
        for (expected[0..results], 0..) |want, index| {
            const got = x.get(try std.fmt.bufPrint(&buffer, "R{d}", .{index})).?.integer;
            if (got != want) {
                std.debug.print("round {d} R{d}: expected {d}, got {d}\n{s}\n", .{ round, index, want, got, source.items });
                return error.ModelMismatch;
            }
        }
    }
}

// Class members beside the increments merged around them: RFC-0064 ranges, RFC-0066 patterns,
// RFC-0068 early exit, RFC-0069 characters and their text methods, RFC-0070 `rational` and
// RFC-0072 `First`.

fn expectCharacterOf(x: @import("evaluator.zig").Execution, name: []const u8, value_type: types.Type, code: u32) !void {
    try std.testing.expectEqualDeep(types.Value{ .enumeration = .{ .value_type = value_type, .index = code } }, x.get(name).?);
}
fn expectRationalOf(x: @import("evaluator.zig").Execution, name: []const u8, numerator: i64, denominator: i64) !void {
    try std.testing.expectEqualDeep(types.Value{ .rational = .{ .numerator = numerator, .denominator = denominator } }, x.get(name).?);
}
fn expectIntegersOf(x: @import("evaluator.zig").Execution, name: []const u8, expected: []const i64) !void {
    const range = x.get(name).?.aggregate.elements;
    try std.testing.expectEqual(expected.len, range.end - range.start);
    for (expected, x.aggregate_values[range.start..range.end]) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "a dot after a number: member access, range, float and character literals side by side" {
    const lexer = @import("lexer.zig");
    var tokens: [64]lexer.Token = undefined;
    const source = "7.Double 1..3 1.5 1.5.Half 2e3 2.0e1 0o61.ToCodeUnit 0u1F600.ToCodePoint 'a'.Up 0.Sign 12.e5 3.Length";
    const Expected = struct { text: []const u8, kind: lexer.Token.Kind };
    const expected = [_]Expected{
        .{ .text = "7", .kind = .integer },              .{ .text = ".", .kind = .dot },             .{ .text = "Double", .kind = .identifier },
        .{ .text = "1", .kind = .integer },              .{ .text = ".", .kind = .dot },             .{ .text = ".", .kind = .dot },
        .{ .text = "3", .kind = .integer },              .{ .text = "1.5", .kind = .floating },      .{ .text = "1.5", .kind = .floating },
        .{ .text = ".", .kind = .dot },                  .{ .text = "Half", .kind = .identifier },   .{ .text = "2e3", .kind = .floating },
        .{ .text = "2.0e1", .kind = .floating },         .{ .text = "0o61", .kind = .character },    .{ .text = ".", .kind = .dot },
        .{ .text = "ToCodeUnit", .kind = .identifier },  .{ .text = "0u1F600", .kind = .character }, .{ .text = ".", .kind = .dot },
        .{ .text = "ToCodePoint", .kind = .identifier }, .{ .text = "'a'", .kind = .character },     .{ .text = ".", .kind = .dot },
        .{ .text = "Up", .kind = .identifier },          .{ .text = "0", .kind = .integer },         .{ .text = ".", .kind = .dot },
        .{ .text = "Sign", .kind = .identifier },        .{ .text = "12", .kind = .integer },        .{ .text = ".", .kind = .dot },
        .{ .text = "e5", .kind = .identifier },          .{ .text = "3", .kind = .integer },         .{ .text = ".", .kind = .dot },
        .{ .text = "Length", .kind = .identifier },
    };
    const result = lexer.tokenize(source, &tokens).ok;
    try std.testing.expectEqual(expected.len + 1, result.len);
    for (expected, result[0..expected.len]) |want, token| {
        try std.testing.expectEqualStrings(want.text, token.span.text(source));
        try std.testing.expectEqual(want.kind, token.kind);
    }
    // A float still needs a digit after its point; without a name there it is the old error.
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_number, lexer.tokenize("1.+2", &tokens).failed.code);
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\(V:i64).Dbl()<computes>:i64=V*2
        \\(F:float).Whole()<computes>:i64=Attempt(Floor[F],0)
        \\(V:i64).e5()<computes>:i64=V+5
        \\Range:[]i64=For(I:1..3,I.Dbl())
        \\Sum:float=1.5+2.0e1+1e2
        \\Mixed:[]i64=array{1.5.Whole(),2.Dbl(),12.e5()}
        \\Q:i64=3.Dbl()+0o61.ToCodeUnit()+0u1F600.ToCodePoint()
        \\Made:char=Attempt(104.ToChar[],0o3F)
    );
    try expectIntegersOf(x, "Range", &.{ 2, 4, 6 });
    try std.testing.expectEqual(@as(f64, 121.5), x.get("Sum").?.floating);
    try expectIntegersOf(x, "Mixed", &.{ 1, 4, 17 });
    try std.testing.expectEqual(@as(i64, 6 + 0x61 + 0x1F600), x.get("Q").?.integer);
    try expectCharacterOf(x, "Made", types.Type.char, 'h');
}

test "extension methods on char, string, rational and arrays; the builtin text methods are members" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\(Q:rational).Half()<computes>:rational=Q*R(1,2)
        \\(Q:rational).Whole()<computes>:i64=Floor(Q)
        \\(Q:rational).Over(D:i64=2)<computes><decides>:rational=Q*Rational[1,D]
        \\(Cs:[]char).Text()<computes>:string=Attempt(string[Cs],"?")
        \\(Qs:[]rational).Total()<transacts>:rational=Block{var T:rational=R(0,1);var I:i64=0;While(I<Qs.Length,Block{set T=T+Attempt(Qs[I],R(0,1));set I=I+1});T}
        \\(C:char).Twice()<computes>:string="{C}{C}"
        \\(C:char).IsVowel()<computes>:logic=Case(C,'a'=>true,'e'=>true,'i'=>true,'o'=>true,'u'=>true,_=>false)
        \\(C:char32).Next()<computes>:char32=Attempt((C.ToCodePoint()+1).ToChar32[],0u3F)
        \\(S:string).Vowels()<computes>:i64=For(C:S,C.IsVowel(),1).Length
        \\(S:string).Find(T:char,From:i64=0)<computes><decides>:i64=First[I->C:S,I>=From,C==T,I]
        \\(S:string).Tail(From:i64=1)<computes>:string=Attempt(S.Slice[From],"")
        \\H:rational=R(7,2).Half()
        \\W:i64=R(7,2).Whole()
        \\O1:rational=Attempt(R(7,2).Over[],R(0,1))
        \\O2:rational=Attempt(R(7,2).Over[D:=0],R(0-1,1))
        \\T:string=For(C:"abc",C).Text()
        \\Tot:rational=array{R(1,2),R(1,3),R(1,6)}.Total()
        \\U:string=0o78.Twice()
        \\V:char32=0uE9.Next()
        \\N:i64="education".Vowels()
        \\F1:i64=Attempt("axbxc".Find[0o78],-1)
        \\F2:i64=Attempt("axbxc".Find[0o78,From:=2],-1)
        \\F3:i64=Attempt("axbxc".Find[From:=4,T:=0o78],-1)
        \\Tl:string="hello".Tail()+"hello".Tail(From:=3)
        \\(C:char32).ToCodeUnit()<computes>:i64=1
        \\(C:char).ToCodePoint()<computes>:i64=C.ToCodeUnit()+1000
        \\(S:string).ToChar()<computes><decides>:char=S[0]
        \\(K:i64).Slice(A:i64,B:i64=2)<computes>:i64=K*A+B
        \\X1:i64=0u41.ToCodeUnit()
        \\X2:i64=0o41.ToCodePoint()
        \\X3:char=Attempt("hey".ToChar[],0o3F)
        \\X4:i64=7.Slice(3)
        \\X5:string=Attempt("hello".Slice[1,3],"!")
    );
    try expectRationalOf(x, "H", 7, 4);
    try std.testing.expectEqual(@as(i64, 3), x.get("W").?.integer);
    try expectRationalOf(x, "O1", 7, 4);
    try expectRationalOf(x, "O2", -1, 1);
    try std.testing.expectEqualStrings("abc", x.get("T").?.string);
    try expectRationalOf(x, "Tot", 1, 1);
    try std.testing.expectEqualStrings("xx", x.get("U").?.string);
    try expectCharacterOf(x, "V", types.Type.char32, 0xEA);
    try std.testing.expectEqual(@as(i64, 5), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("F1").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("F2").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("F3").?.integer);
    try std.testing.expectEqualStrings("ellolo", x.get("Tl").?.string);
    // A text method's name is free on every other receiver type: the method belongs to its type.
    try std.testing.expectEqual(@as(i64, 1), x.get("X1").?.integer);
    try std.testing.expectEqual(@as(i64, 0x41 + 1000), x.get("X2").?.integer);
    try expectCharacterOf(x, "X3", types.Type.char, 'h');
    try std.testing.expectEqual(@as(i64, 23), x.get("X4").?.integer);
    try std.testing.expectEqualStrings("el", x.get("X5").?.string);
    try expectDiagnostics(h, "", &.{
        // The builtin text methods (RFC-0069) are members of their receiver type, and a member
        // always wins: an extension of that name on that type could never be called.
        .{ .tail = "(S:string).Slice(A:i64)<computes>:i64=A", .code = .duplicate_name },
        .{ .tail = "(S:string).ScalarAt(A:i64)<computes>:i64=A", .code = .duplicate_name },
        .{ .tail = "(C:char).ToCodeUnit()<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(C:char).ToAsciiChar32()<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(C:char32).ToCodePoint()<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(C:char32).ToAsciiString()<computes>:string=\"\"", .code = .duplicate_name },
        .{ .tail = "(N:i64).ToChar()<computes>:i64=N", .code = .duplicate_name },
        .{ .tail = "(N:i64).ToChar32()<computes>:i64=N", .code = .duplicate_name },
        .{ .tail = "(S:string).Length()<computes>:i64=1", .code = .duplicate_name },
        .{ .tail = "(Cs:[]char).Length()<computes>:i64=1", .code = .duplicate_name },
        // With no extension in reach the receivers answer as they did before extensions existed.
        .{ .tail = "A:i64='a'.Missing()", .code = .unknown_field },
        .{ .tail = "A:i64=\"a\".Missing()", .code = .unknown_field },
        .{ .tail = "A:i64=7.Missing()", .code = .type_mismatch },
        .{ .tail = "A:i64=MakeRationalFromInt(1).Missing()", .code = .type_mismatch },
        // An extension is not found on another receiver type, and a text method keeps its brackets.
        .{ .tail = "(C:char).Up()<computes>:char=C\nA:char=0u41.Up()", .code = .type_mismatch },
        .{ .tail = "(C:char).Up()<computes>:char=C\nA:i64='a'.Up().ToCodeUnit[]", .code = .expected_call },
        // The names of RFC-0068 stay reserved for a declaration, an extension method included.
        .{ .tail = "(V:i64).Return()<computes>:i64=V", .code = .expected_name },
        .{ .tail = "(V:i64).Break()<computes>:i64=V", .code = .expected_name },
        .{ .tail = "(V:i64).Defer()<computes>:i64=V", .code = .expected_name },
        .{ .tail = "(Return:i64).Twice()<computes>:i64=Return*2", .code = .expected_parameter },
        // An extension method is named only after a receiver, so the bare name stays the
        // intrinsic of RFC-0070 or RFC-0072 (RFC-0075; `class_constructor_tests.zig` has the
        // values) and is checked as one.
        .{ .tail = "(V:i64).BitAnd(B:i64)<computes>:i64=V+B\nA:i64=BitAnd(6)", .code = .argument_count },
        .{ .tail = "(V:i64).Quotient(B:i64)<computes>:i64=V+B\nA:i64=Quotient[7,2]", .code = .failure_context_required },
        // Inside an interface a bare name that is one of its members is not the intrinsic either.
        .{ .tail = "I:=interface{BitAnd(A:i64,B:i64)<transacts>:i64=A+B\nRun()<transacts>:i64=BitAnd(6,3)}", .code = .unknown_name },
        .{ .tail = "I:=interface{BitAnd:i64=9\nRun()<transacts>:i64=BitAnd(6,3)}", .code = .unknown_name },
    });
}

test "interface default bodies and methods with defaults use First, Return, Quotient, Case and For" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\Token:=interface{
        \\  Mark:char='a'
        \\  var Glyph:char='x'
        \\  var Share:rational=MakeRationalFromInt(1)
        \\  Weights:[]i64=array{3,8,12}
        \\  Pick(Min:i64,Step:i64=4)<transacts>:i64=Block{If(Min<0,Return(0-1),false);W:=Attempt(First[X:Self.Weights,X>Min,X],0);Attempt(Quotient[W,Step],0-2)}
        \\  Stamp(C:char,Keep:logic=false)<transacts>:char=Block{Old:=Self.Glyph;If(Keep,Return(Old),false);set Self.Glyph=C;Old}
        \\  Portion(Of:i64=6)<transacts>:rational=Self.Share*MakeRationalFromInt(Of)
        \\}
        \\Piece:=class<unique>(Token){}
        \\Coin:=class<unique>(Piece){
        \\  Mark<override>:char='c'
        \\}
        \\Note:=class<unique>(Piece){
        \\  Pick<override>(Min:i64,Step:i64=1)<transacts>:i64=Min*Step
        \\}
        \\AsPiece(K:Token)<transacts>:Piece=Attempt(Piece[K],Piece{})
        \\C:=Coin{}
        \\N:=Note{Share:=R(1,3)}
        \\T:Token=C
        \\U:Token=N
        \\P1:i64=T.Pick(5)
        \\P2:i64=T.Pick(5,Step:=3)
        \\P3:i64=T.Pick(0-1)
        \\P4:i64=T.Pick(20)
        \\P5:i64=T.Pick(5,Step:=0)
        \\P6:i64=U.Pick(5)
        \\P7:i64=N.Pick(5)
        \\M1:char=T.Mark
        \\M2:char=U.Mark
        \\G0:char=T.Glyph
        \\set T.Glyph='y'
        \\G1:char=C.Glyph
        \\Old:char=T.Stamp('z')
        \\G2:char=T.Glyph
        \\Kept:char=T.Stamp('w',Keep:=true)
        \\G3:char=C.Glyph
        \\S0:rational=U.Share
        \\set U.Share=U.Share+R(1,6)
        \\S1:rational=N.Share
        \\S2:rational=T.Share
        \\S3:rational=U.Portion()
        \\S4:rational=U.Portion(Of:=3)
        \\Rate(K:Token,D:char)<transacts>:i64=Case(D,'a'=>K.Pick(Step:=2,Min:=5),'b'=>K.Pick(5),E:char where E==K.Mark=>K.Pick(Min:=0),_=>0-9)
        \\AllRates(K:Token)<transacts>:[]i64=For(D:"abcq",Rate(K,D))
        \\Rates:[]i64=AllRates(T)
        \\Table(K:Token)<transacts>:[]i64=For(A:array{2,7},B:1..2,K.Pick(A,Step:=B))
        \\Grid:[]i64=Table(T)
        \\Each(Ks:[]Token)<transacts>:[]i64=For(K:Ks,Min:array{2,7},K.Pick(Min))
        \\Both:[]i64=Each(array{T,U})
        \\Owners:map(Piece,i64)=map{AsPiece(T)=>1,AsPiece(U)=>2}
        \\C2:=Coin{}
        \\T2:Token=C2
        \\O1:i64=Or(Lookup(Owners,AsPiece(T)),0)
        \\O2:i64=Or(Lookup(Owners,AsPiece(T2)),0)
        \\ByCoin:map(Coin,string)=map{C=>"first"}
        \\O3:string=Attempt(ByCoin[C],"?")
        \\O4:string=Attempt(ByCoin[C2],"?")
        \\set T.Glyph='q'
        \\O5:i64=Or(Lookup(Owners,AsPiece(T)),0)
        \\Eq1:logic=tuple{AsPiece(T),'a',R(1,2)}==tuple{AsPiece(T),0o61,R(2,4)}
        \\Eq2:logic=tuple{AsPiece(T),'a'}==tuple{AsPiece(T2),'a'}
        \\Eq3:logic=tuple{C,T.Glyph}==tuple{C,C.Glyph}
        \\Eq4:logic=tuple{AsPiece(U),U.Share}!=tuple{AsPiece(U),R(1,2)}
    );
    // The first weight above 5 is 8: 8/4 with the interface's default, 8/3 floored when named.
    try std.testing.expectEqual(@as(i64, 2), x.get("P1").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("P2").?.integer);
    // `Return` leaves the default body; a `First` that finds nothing and a `Quotient` by zero
    // fail into their `Attempt`s.
    try std.testing.expectEqual(@as(i64, -1), x.get("P3").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("P4").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.get("P5").?.integer);
    // Through the interface `Step` is 4 and `Note`'s body runs; through `Note` it is 1.
    try std.testing.expectEqual(@as(i64, 20), x.get("P6").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("P7").?.integer);
    const char = types.Type.char;
    try expectCharacterOf(x, "M1", char, 'c');
    try expectCharacterOf(x, "M2", char, 'a');
    try expectCharacterOf(x, "G0", char, 'x');
    try expectCharacterOf(x, "G1", char, 'y');
    try expectCharacterOf(x, "Old", char, 'y');
    try expectCharacterOf(x, "G2", char, 'z');
    try expectCharacterOf(x, "Kept", char, 'z');
    try expectCharacterOf(x, "G3", char, 'z');
    try expectRationalOf(x, "S0", 1, 3);
    try expectRationalOf(x, "S1", 1, 2);
    try expectRationalOf(x, "S2", 1, 1);
    try expectRationalOf(x, "S3", 3, 1);
    try expectRationalOf(x, "S4", 3, 2);
    // 'a': 8/2; 'b': 8/4; 'c' is the coin's `Mark`, so the binding arm: 3/4; no arm for 'q'.
    try expectIntegersOf(x, "Rates", &.{ 4, 2, 0, -9 });
    try expectIntegersOf(x, "Grid", &.{ 3, 1, 8, 4 });
    try expectIntegersOf(x, "Both", &.{ 0, 2, 8, 28 });
    // An instance is a key by identity: an equal-looking coin is another key, and writing a
    // field through the interface does not move the entry. A value of interface type is not
    // comparable (RFC-0076: only a `class<unique>` is), so the keys and the compared values are
    // the same instances cast from `Token` to the unique class `Piece` both classes are below.
    try std.testing.expectEqual(@as(i64, 1), x.get("O1").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("O2").?.integer);
    try std.testing.expectEqualStrings("first", x.get("O3").?.string);
    try std.testing.expectEqualStrings("?", x.get("O4").?.string);
    try std.testing.expectEqual(@as(i64, 1), x.get("O5").?.integer);
    try std.testing.expect(x.get("Eq1").?.boolean);
    try std.testing.expect(!x.get("Eq2").?.boolean);
    try std.testing.expect(x.get("Eq3").?.boolean);
    try std.testing.expect(!x.get("Eq4").?.boolean);
}

test "early exit in extension methods, default bodies and methods with defaults; members may be named Return" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Trace:i64=0
        \\Note(D:i64)<transacts>:i64=Set(Trace,Trace*10+D)
        \\(V:i64).Sign()<computes>:i64=Block{If(V<0,Return(-1),false);If(V==0,Return(0),false);1}
        \\(S:string).Find(T:char,From:i64=0)<transacts>:i64=Block{Defer{Note(1)};For(I->C:S,If(C==T and I>=From,Return(I),false));-1}
        \\(Xs:[]i64).Bits(X:i64=8)<transacts>:i64=Block{var B:i64=1;var C:i64=0;Loop{If(B>X,Break(),false);set B=2*B;set C=C+1};C}
        \\A:i64=5.Sign()+0.Sign()*10+(0-3).Sign()*100
        \\B:i64="axbxc".Find(0o78)
        \\C:i64="axbxc".Find(0o78,From:=2)
        \\D:i64=array{1}.Bits()+array{1}.Bits(X:=100)*10
        \\T1:i64=Trace
        \\Shape:=interface{
        \\  Sides:i64=4
        \\  Return:i64=6
        \\  Break()<transacts>:i64=7
        \\  Score(N:i64,Scale:i64=2)<transacts>:i64=Block{Defer{Note(Scale)};If(N<0,Return(0-1),false);var I:i64=0;Loop{Defer{Note(9)};set I=I+1;If(I*Scale>N,Break(),false)};I*Self.Sides}
        \\  Run()<transacts>:i64=Block{var K:i64=0;Loop{set K=K+Self.Break();If(K>20,Break(),false)};K+Self.Return}
        \\}
        \\Sq:=class(Shape){}
        \\Tri:=class(Shape){
        \\  Sides<override>:i64=3
        \\  Score<override>(N:i64,Scale:i64=5)<transacts>:i64=Block{Defer{Note(Scale)};If(N==0,Return(Self.Sides),false);N*Scale}
        \\}
        \\S:=Sq{}
        \\Y:=Tri{}
        \\AsShape:Shape=Y
        \\E:i64=S.Score(3)
        \\F:i64=S.Score(0-1)
        \\G:i64=S.Score(Scale:=7,N:=7)
        \\H:i64=AsShape.Score(0)
        \\I:i64=AsShape.Score(2)
        \\J:i64=Y.Score(2)
        \\K:i64=AsShape.Run()+S.Return+S.Break()
        \\T2:i64=Trace
    );
    try std.testing.expectEqual(@as(i64, -99), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 4 + 70), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 11), x.get("T1").?.integer);
    // Two visits of the loop (a deferred 9 each), then the body's own `Defer` notes the scale.
    try std.testing.expectEqual(@as(i64, 8), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("G").?.integer);
    // Through the interface the scale defaults to 2 and `Tri`'s body runs; through `Tri`, to 5.
    try std.testing.expectEqual(@as(i64, 3), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("I").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("J").?.integer);
    // A member named like an exit is a member after a dot, and `Break()` alone still leaves.
    try std.testing.expectEqual(@as(i64, 21 + 6 + 6 + 7), x.get("K").?.integer);
    // 1 1 | E: 9 9 2 | F: 2 | G: 9 9 7 | H: 2 | I: 2 | J: 5
    try std.testing.expectEqual(@as(i64, 119922997225), x.get("T2").?.integer);
    try expectDiagnostics(h, "", &.{
        // A default value is not a place an exit can leave from, in a method as in a function.
        .{ .tail = "C:=class{F(N:i64=Return(1))<transacts>:i64=N}", .code = .return_not_tail },
        .{ .tail = "I:=interface{F(N:i64=Return(1))<transacts>:i64=N}", .code = .return_not_tail },
        .{ .tail = "(V:i64).F(N:i64=Return(1))<computes>:i64=N", .code = .return_not_tail },
        .{ .tail = "I:=interface{F()<transacts>:i64=Block{Break();1}}", .code = .break_outside_loop },
        .{ .tail = "(V:i64).F()<computes>:i64=Block{Defer{Return(1)};V}", .code = .defer_exit },
        .{ .tail = "Xs:[]i64=array{1}\nI:=interface{F()<transacts><decides>:i64=First[X:Xs,X>0,If(X>6,Return(-1),X)]}", .code = .first_exit },
    });
}

test "a slot that many sibling classes declare resolves and seals as one that few do" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [8192]u8 = undefined;
    // More declarations than are read one by one: the index answers from here on, and a
    // Debug build holds every answer against reading them all.
    const siblings = 24;
    inline for (.{ "class", "interface" }) |root| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Base:=" ++ root ++ "{\n  M()<transacts>:i64=1\n  K()<transacts>:i64=2\n}\n");
        for (0..siblings) |index| {
            // Every third class seals its override, every fourth leaves the method alone.
            if (index % 4 == 3) try out.print("C{d}:=class(Base){{}}\n", .{index}) else try out.print("C{d}:=class(Base){{\n  M<override>{s}()<transacts>:i64={d}\n}}\n", .{ index, if (index % 3 == 0) "<final>" else "", 100 + index });
        }
        try out.writeAll("D:=class(C1){}\nE:=class(C1){\n  M<override>()<transacts>:i64=7\n}\nA:Base=C3{}\nB:Base=C4{}\nC:Base=D{}\nF:Base=E{}\nG:Base=C0{}\n");
        try out.writeAll("Plain<public>:i64=A.M()\nOver<public>:i64=B.M()\nBelow<public>:i64=C.M()\nAgain<public>:i64=F.M()\nSealed<public>:i64=G.M()\nOther<public>:i64=A.K()\n");
        const base = out.buffered().len;
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(@as(i64, 1), x.get("Plain").?.integer);
        try std.testing.expectEqual(@as(i64, 104), x.get("Over").?.integer);
        try std.testing.expectEqual(@as(i64, 101), x.get("Below").?.integer);
        try std.testing.expectEqual(@as(i64, 7), x.get("Again").?.integer);
        try std.testing.expectEqual(@as(i64, 100), x.get("Sealed").?.integer);
        try std.testing.expectEqual(@as(i64, 2), x.get("Other").?.integer);
        // Below a sealed override nothing overrides; below a sibling of it, anything does.
        const tails = [_]struct { tail: []const u8, code: ?types.Diagnostic.Code }{
            .{ .tail = "Z:=class(C0){\n  M<override>()<transacts>:i64=0\n}\n", .code = .final_method },
            .{ .tail = "Y:=class(C0){}\nZ:=class(Y){\n  M<override>()<transacts>:i64=0\n}\n", .code = .final_method },
            .{ .tail = "Z:=class(C2){\n  M<override>()<transacts>:i64=0\n}\n", .code = null },
            .{ .tail = "Z:=class(C3){\n  M<override><final>()<transacts>:i64=0\n}\nY:=class(Z){\n  M<override>()<transacts>:i64=0\n}\n", .code = .final_method },
            .{ .tail = "Z:=class(C0){\n  K<override>()<transacts>:i64=0\n}\n", .code = null },
        };
        for (tails) |case| {
            out = std.Io.Writer.fixed(buffer[base..]);
            try out.writeAll(case.tail);
            const result = h.front.compile(buffer[0 .. base + out.buffered().len]);
            const got: ?types.Diagnostic.Code = if (result == .ok) null else result.failed.code;
            if (got != case.code) {
                std.debug.print("below one {s}, {s}: expected {s}, got {s}\n", .{ root, case.tail, if (case.code) |c| @tagName(c) else "success", if (got) |c| @tagName(c) else "success" });
                return error.WrongDiagnostic;
            }
        }
    }
}
