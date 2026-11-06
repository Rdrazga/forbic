//! Constructor functions, delegation, class `Block{...}` clauses and `<final>` members (RFC-0075),
//! with the two class-area repairs the same RFC records: an extension method no longer takes
//! the bare name of a builtin, and a loop body may write the fields of an instance it does not
//! carry.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

const Case = struct { tail: []const u8, code: types.Diagnostic.Code };

fn expectDiagnostics(h: *harness.Harness, base: []const u8, cases: []const Case) !void {
    var buffer: [4096]u8 = undefined;
    var wrong: usize = 0;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, case.tail });
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("constructor diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.tail, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            wrong += 1;
        }
    }
    if (wrong != 0) return error.WrongDiagnostic;
}

fn expectIntegers(x: anytype, name: []const u8, want: []const i64) !void {
    const value = x.get(name) orelse return error.MissingBinding;
    const elements = value.aggregate.elements;
    const got = x.aggregate_values[elements.start..elements.end];
    if (got.len != want.len) {
        std.debug.print("{s}: expected {d} elements, got {d}\n", .{ name, want.len, got.len });
        return error.WrongLength;
    }
    for (got, want, 0..) |a, b, index| if (a.integer != b) {
        std.debug.print("{s}[{d}]: expected {d}, got {d}\n", .{ name, index, b, a.integer });
        return error.WrongElement;
    };
}

const entities =
    \\var Log:[]i64=array{}
    \\Note(Tag:i64,Value:i64)<transacts>:i64=Block{set Log=Log+array{Tag};Value}
    \\Entity:=class{
    \\  Name:string
    \\  var Health:i64=100
    \\  var Label:string=""
    \\  Block{
    \\    set Log=Log+array{1000+Self.Health}
    \\    set Self.Label="e-"+Self.Name
    \\  }
    \\}
    \\MakeEntity<constructor>(Name:string,Health:i64=7)<transacts>:=Entity{Name:=Name,Health:=Note(1,Health)}
    \\Character:=class(Entity){
    \\  Kind:string
    \\  Level:i64=1
    \\  Block{set Log=Log+array{2000+Self.Level}}
    \\}
    \\MakeCharacter<constructor>(Name:string,Kind:string,Level:i64)<transacts>:=Character{
    \\  Kind:=Kind
    \\  Level:=Note(2,Level)
    \\  MakeEntity<constructor>(Name,Note(3,Level)*100)
    \\}
    \\
;

test "a constructor function builds an instance and is called like any function" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(entities ++
        \\E:=MakeEntity("bob")
        \\G:=MakeEntity(Health:=40,Name:="guard")
        \\A:i64=E.Health
        \\B:i64=G.Health
        \\C:string=E.Label+"/"+G.Label
        \\F:function<transacts>(tuple(string,i64),Entity)=MakeEntity
        \\H:=F("fn",5)
        \\D:i64=H.Health
        \\Twice(N:string)<transacts>:i64=MakeEntity(N).Health+MakeEntity(N,1).Health
        \\T:i64=Twice("t")
        \\L:[]i64=Log
    );
    try std.testing.expectEqual(@as(i64, 7), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 40), x.get("B").?.integer);
    try std.testing.expectEqualStrings("e-bob/e-guard", x.get("C").?.string);
    try std.testing.expectEqual(@as(i64, 5), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("T").?.integer);
    // Each construction: the field value, then the block clause on the complete instance.
    try expectIntegers(x, "L", &.{ 1, 1007, 1, 1040, 1, 1005, 1, 1007, 1, 1001 });
    // Five instances of a header and three fields.
    try std.testing.expectEqual(@as(usize, 5 * 4), x.object_cells.len);
}

test "an archetype takes its superclass part from a constructor function" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(entities ++
        \\Hero:=MakeCharacter("Aldric","Warrior",5)
        \\A:i64=Hero.Health
        \\B:string=Hero.Name+"/"+Hero.Kind+"/"+Hero.Label
        \\C:i64=Hero.Level
        \\Mark:i64=Note(9,0)
        \\Plain:=Character{MakeEntity<constructor>("p"),Kind:="plain"}
        \\D:i64=Plain.Health+Plain.Level
        \\MakeNamed<constructor>(Name:string)<transacts>:=Entity{Name:=Name}
        \\Knight:=class(Character){
        \\  var Health<override>:i64=250
        \\  Kind<override>:string="knight"
        \\}
        \\K1:=Knight{MakeNamed<constructor>("k1")}
        \\K2:=Knight{Health:=9,MakeNamed<constructor>("k2"),Level:=4}
        \\K3:=Knight{MakeEntity<constructor>("k3")}
        \\K4:=Entity{Health:=3,MakeNamed<constructor>("k4")}
        \\G:i64=K1.Health*1000000+K2.Health*10000+K3.Health*100+K4.Health
        \\H:string=K1.Kind+K1.Label+K2.Label
        \\Up:Entity=Hero
        \\E:i64=Up.Health
        \\L:[]i64=Log
    );
    try std.testing.expectEqual(@as(i64, 500), x.get("A").?.integer);
    try std.testing.expectEqualStrings("Aldric/Warrior/e-Aldric", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 500), x.get("E").?.integer);
    // The archetype's entries in the order written: `Level`, then the delegation, whose
    // argument is evaluated before the delegated constructor's own field values. Then one
    // instance, and the block clauses of the superclass before the subclass's.
    try expectIntegers(x, "L", &.{ 2, 3, 1, 1500, 2005, 9, 1, 1007, 2001, 1250, 2001, 1009, 2004, 1, 1007, 2001, 1003 });
    // A constructor function supplies what its archetype writes. A field it leaves alone takes
    // the default of the class that is built (`Knight` restates `Health`), or the value the
    // delegating archetype names; `MakeEntity` writes `Health` itself.
    try std.testing.expectEqual(@as(i64, 250 * 1000000 + 9 * 10000 + 7 * 100 + 3), x.get("G").?.integer);
    try std.testing.expectEqualStrings("knighte-k1e-k2", x.get("H").?.string);
    // One instance each, never a separate `Entity`: a header and five fields, or three.
    try std.testing.expectEqual(@as(usize, 5 * 6 + 4), x.object_cells.len);
}

test "constructor functions overload, forward to their own class and serve abstract classes" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Log:[]i64=array{}
        \\Shape:=class<abstract>{
        \\  Id:i64
        \\  var Area:i64=0
        \\  Sides<abstract>()<transacts>:i64
        \\  Block{set Log=Log+array{Self.Id*10+Self.Sides()}}
        \\}
        \\MakeShape<constructor>(Id:i64,Scale:i64=2)<transacts>:=Shape{Id:=Id,Area:=Id*Scale}
        \\Square:=class(Shape){
        \\  Edge:i64
        \\  Sides<override>()<transacts>:i64=4
        \\  Block{set Self.Area=Self.Area+Self.Edge*Self.Edge}
        \\}
        \\MakeSquare<constructor>(Id:i64,Edge:i64)<transacts>:=Square{Edge:=Edge,MakeShape<constructor>(Id)}
        \\MakeSquare<constructor>(Edge:i64)<transacts>:=Square{MakeSquare<constructor>(100,Edge)}
        \\MakeSquare<constructor>(Name:string)<transacts>:=Square{Edge:=Name.Length,MakeShape<constructor>(Scale:=0,Id:=1)}
        \\Tri:=class(Shape){
        \\  Edges:[]i64
        \\  Total:i64
        \\  Sides<override>()<transacts>:i64=Self.Edges.Length
        \\}
        \\MakeTri<constructor>(Id:i64,A:i64,B:i64,C:i64)<transacts>:Tri=Block{
        \\  Es:[]i64=array{A,B,C}
        \\  Tri{Edges:=Es,Total:=A+B+C,MakeShape<constructor>(Scale:=5,Id:=Id)}
        \\}
        \\S1:=MakeSquare(1,3)
        \\S2:=MakeSquare(4)
        \\S3:=MakeSquare("abcde")
        \\T1:=MakeTri(7,3,4,5)
        \\A1:i64=S1.Area
        \\A2:i64=S2.Id*1000+S2.Area
        \\A3:i64=S3.Area
        \\A4:i64=T1.Area*100+T1.Total
        \\F:function<transacts>(tuple(i64),Square)=MakeSquare
        \\A5:i64=F(9).Area
        \\L:[]i64=Log
    );
    try std.testing.expectEqual(@as(i64, 2 + 9), x.get("A1").?.integer);
    try std.testing.expectEqual(@as(i64, 100_000 + 200 + 16), x.get("A2").?.integer);
    try std.testing.expectEqual(@as(i64, 25), x.get("A3").?.integer);
    try std.testing.expectEqual(@as(i64, 3500 + 12), x.get("A4").?.integer);
    try std.testing.expectEqual(@as(i64, 200 + 81), x.get("A5").?.integer);
    // The superclass's clause calls `Sides` through the dispatch table of the instance built.
    try expectIntegers(x, "L", &.{ 14, 1004, 14, 73, 1004 });
}

test "a failed constructor builds nothing and leaves nothing written" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Made:i64=0
        \\var Seen:[]i64=array{}
        \\Item:=class{
        \\  Id:i64
        \\  var Weight:i64=1
        \\  Block{set Made=Made+1}
        \\}
        \\Touch(V:i64)<transacts>:i64=Block{set Seen=Seen+array{V};V}
        \\MakeItem<constructor>(Id:i64,Weight:i64=2)<transacts><decides>:=Item{
        \\  Weight:=Touch(Weight)
        \\  Id:=Block{Require[Id>0];Id}
        \\}
        \\Heavy:=class(Item){
        \\  Extra:i64
        \\  Block{set Self.Weight=Self.Weight+Self.Extra}
        \\}
        \\MakeHeavy<constructor>(Id:i64,Extra:i64)<transacts><decides>:=Heavy{Extra:=Touch(Extra),MakeItem<constructor>[Id,Weight:=10]}
        \\Ok:i64=Attempt(MakeItem[3].Weight,0-1)
        \\Bad:i64=Attempt(MakeItem[0,9].Weight,0-1)
        \\Deep:i64=Attempt(MakeHeavy[0,5].Weight,0-2)
        \\Fine:i64=Attempt(MakeHeavy[1,5].Weight,0-2)
        \\Late:i64=Attempt(Block{X:=MakeHeavy[2,6];Require[X.Weight<0];X.Weight},0-3)
        \\Kept:option(Item)=Attempt(option{MakeItem[0]},option{})
        \\Holds:logic=Kept.IsSet
        \\M:i64=Made
        \\S:[]i64=Seen
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("Ok").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Bad").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.get("Deep").?.integer);
    try std.testing.expectEqual(@as(i64, 15), x.get("Fine").?.integer);
    try std.testing.expectEqual(@as(i64, -3), x.get("Late").?.integer);
    try std.testing.expectEqual(false, x.get("Holds").?.boolean);
    // Only the two that succeeded ran a block clause; `Late` ran both and was undone.
    try std.testing.expectEqual(@as(i64, 2), x.get("M").?.integer);
    // The writes of the field values of the failed constructions were undone with them.
    try expectIntegers(x, "S", &.{ 2, 5, 10 });
    // An `Item` (header and two fields) and a `Heavy` (three): no other instance exists.
    try std.testing.expectEqual(@as(usize, 3 + 4), x.object_cells.len);
}

test "constructor functions inside For, Case arms, First and beside Defer" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Made:i64=0
        \\Item:=class{
        \\  Id:i64
        \\  var Weight:i64=1
        \\  Block{set Made=Made+1}
        \\}
        \\MakeItem<constructor>(Id:i64,Weight:i64=2)<transacts><decides>:=Item{Id:=Block{Require[Id>0];Id},Weight:=Weight}
        \\Heavy:=class(Item){
        \\  Extra:i64
        \\  Block{set Self.Weight=Self.Weight+Self.Extra}
        \\}
        \\MakeHeavy<constructor>(Id:i64,Extra:i64)<transacts><decides>:=Heavy{Extra:=Extra,MakeItem<constructor>[Id,Weight:=10]}
        \\Kind:=enum{Light,Big}
        \\Ids:[]i64=array{3,0,5,0-1,8}
        \\Build(Xs:[]i64)<transacts>:[]Item=For(I:Xs,MakeItem[I])
        \\Items:[]Item=Build(Ids)
        \\Count:i64=Items.Length
        \\Weigh(Xs:[]Item)<transacts>:[]i64=For(X:Xs,X.Id*10+X.Weight)
        \\Weights:[]i64=Weigh(Items)
        \\Pick(K:Kind,Id:i64)<transacts>:i64=Case(K,Kind.Light=>Attempt(MakeItem[Id].Weight,0-1),Kind.Big=>Attempt(MakeHeavy[Id,4].Weight,0-2))
        \\P1:i64=Pick(Kind.Light,1)
        \\P2:i64=Pick(Kind.Big,1)
        \\P3:i64=Pick(Kind.Big,0)
        \\Find(Xs:[]i64)<transacts>:i64=Attempt(First[I:Xs,H:=MakeHeavy[I-4,I],H.Weight],0-3)
        \\F1:i64=Find(Ids)
        \\WithDefer(Id:i64)<transacts>:i64=Block{
        \\  Defer{set Made=Made+1000}
        \\  X:=Attempt(option{MakeItem[Id]},option{})
        \\  If(X.IsSet,1,0)
        \\}
        \\D1:i64=WithDefer(1)
        \\D2:i64=WithDefer(0)
        \\InDefer()<transacts>:i64=Block{
        \\  Defer{set Made=Made+Attempt(MakeItem[7].Weight,0)}
        \\  Made
        \\}
        \\D3:i64=InDefer()
        \\Total:i64=Made
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("Count").?.integer);
    try expectIntegers(x, "Weights", &.{ 32, 52, 82 });
    try std.testing.expectEqual(@as(i64, 2), x.get("P1").?.integer);
    try std.testing.expectEqual(@as(i64, 14), x.get("P2").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.get("P3").?.integer);
    // The first `I` for which `MakeHeavy[I-4, I]` succeeds is 5.
    try std.testing.expectEqual(@as(i64, 15), x.get("F1").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("D1").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("D2").?.integer);
    try std.testing.expectEqual(@as(i64, 2007), x.get("D3").?.integer);
    // 3 in the `For`, 2 in `Pick`, 1 in `First`, 1 in `WithDefer` and 1000 for each `WithDefer`;
    // then the `Defer` body, which read `Made` before the construction whose block clause
    // counted, and so stores 2007 + 2.
    try std.testing.expectEqual(@as(i64, 2009), x.get("Total").?.integer);
}

test "block clauses run after the fields, superclass first, in the order written" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Trail:[]i64=array{}
        \\Step(V:i64)<transacts>:i64=Block{set Trail=Trail+array{V};V}
        \\Multi:=class{
        \\  var Step1:i64=0
        \\  var Step2:i64=0
        \\  Block{set Self.Step1=10}
        \\  var Step3:i64=0
        \\  Block{
        \\    set Self.Step2=Self.Step1+5
        \\    set Self.Step3=Self.Step2*2
        \\  }
        \\  Bump()<transacts>:i64=Block{set Self.Step1=Self.Step1+1;Self.Step1}
        \\  Clone()<transacts>:Multi=Multi{Step1:=Self.Step1}
        \\}
        \\Loud:=class(Multi){
        \\  var Seen:i64=0
        \\  Bump<override>()<transacts>:i64=Block{set Self.Step1=Self.Step1+100;Self.Step1}
        \\  Block{
        \\    var I:i64=0
        \\    While(I<3,Block{set Self.Seen=Self.Seen+Self.Bump();set I=I+1})
        \\    Defer{set Self.Seen=Self.Seen*2}
        \\    set Self.Seen=Self.Seen+Step(7)
        \\  }
        \\  Block{Step(Self.Seen)}
        \\}
        \\M:=Multi{Step1:=3,Step3:=99}
        \\A:i64=M.Step1*10000+M.Step2*100+M.Step3
        \\C:=M.Clone()
        \\B:i64=C.Step1*10000+C.Step2*100+C.Step3
        \\Q:=Loud{}
        \\D:i64=Q.Step1
        \\E:i64=Q.Seen
        \\T:[]i64=Trail
    );
    // The archetype's `Step1` and `Step3` are overwritten by the clauses, which run after it.
    try std.testing.expectEqual(@as(i64, 10 * 10000 + 15 * 100 + 30), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10 * 10000 + 15 * 100 + 30), x.get("B").?.integer);
    // `Multi`'s clauses ran first (Step1 = 10); `Loud`'s loop calls its own override.
    try std.testing.expectEqual(@as(i64, 310), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, (110 + 210 + 310 + 7) * 2), x.get("E").?.integer);
    try expectIntegers(x, "T", &.{ 7, (110 + 210 + 310 + 7) * 2 });
}

test "constructor functions, delegation and block clauses are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Base:=class{
        \\  Id:i64
        \\  var N:i64=0
        \\}
        \\MakeBase<constructor>(Id:i64)<transacts>:=Base{Id:=Id}
        \\Checked<constructor>(Id:i64)<transacts><decides>:=Base{Id:=Block{Require[Id>0];Id}}
        \\Sub:=class(Base){
        \\  Extra:i64=0
        \\}
        \\Other:=class{
        \\  Z:i64=0
        \\}
        \\MakeOther<constructor>()<transacts>:=Other{}
        \\Plain(Id:i64)<transacts>:Base=Base{Id:=Id}
        \\Rec:=struct{X:i64}
        \\Face:=interface{
        \\  Get()<transacts>:i64
        \\}
        \\Hollow:=class<abstract>{
        \\  K:i64=1
        \\}
        \\MakeHollow<constructor>(K:i64)<transacts>:=Hollow{K:=K}
        \\
    ;
    try expectDiagnostics(h, base, &.{
        // The body is one archetype of exactly the class the function builds.
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:=If(Id>0,Base{Id:=Id},Base{Id:=0})", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:=Nowhere{Id:=Id}", .code = .unsupported_type },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=If(Id>0,Base{Id:=Id},Base{Id:=0})", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Sub{Id:=Id}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=MakeBase(Id)", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Block{B:=Base{Id:=Id};set B.N=1;B}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Block{B:=Base{Id:=Id};C:=Base{Id:=2};B}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Block{Defer{Plain(1)};Base{Id:=Id}}", .code = .constructor_body },
        // No `Return`: it would leave the archetype that delegates, with another instance.
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Block{If(Id<0,Return(Base{Id:=0}),false);Base{Id:=Id}}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:=Base{Id:=Block{If(Id<0,Return(Base{Id:=0}),false);Id}}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:Base=Block{var I:i64=0;Loop{If(I>Id,Return(Base{Id:=0}),false);set I=I+1;If(I>3,Break(),false)};Base{Id:=I}}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(X:i64)<transacts>:=Rec{X:=X}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>()<transacts>:=Face{}", .code = .constructor_body },
        .{ .tail = "Bad<constructor>(X:i64)<transacts>:i64=X", .code = .constructor_body },
        .{ .tail = "Bad<constructor>()<transacts>:=array{1}", .code = .constructor_body },
        // It builds an instance, which needs `<transacts>`, and is declared like a function.
        .{ .tail = "Bad<constructor>(Id:i64)<computes>:=Base{Id:=Id}", .code = .construction_requires_allocates },
        .{ .tail = "Bad<constructor>(Id:i64):=Base{Id:=Id}", .code = .expected_computes },
        .{ .tail = "Bad<constructor>:i64=1", .code = .unsupported_specifier },
        .{ .tail = "var Bad<constructor>(Id:i64)<transacts>:=Base{Id:=Id}", .code = .unsupported_specifier },
        .{ .tail = "Bad<constructor><constructor>(Id:i64)<transacts>:=Base{Id:=Id}", .code = .unsupported_specifier },
        .{ .tail = "MakeBase<constructor>(Id:i64)<transacts>:=Base{Id:=Id+1}", .code = .duplicate_name },
        .{ .tail = "MakeBase<constructor>(Id:string)<transacts><decides>:=Base{Id:=Id.Length}", .code = .overload_conflict },
        // A call is a call: brackets when it can fail, a failure context around it.
        .{ .tail = "A:i64=Attempt(Checked(1).N,0)", .code = .expected_call },
        .{ .tail = "A:=Checked[1]", .code = .failure_context_required },
        .{ .tail = "A:=MakeBase[1]", .code = .expected_call },
        .{ .tail = "A:=MakeBase()", .code = .argument_count },
        .{ .tail = "A:=MakeBase(Nope:=1)", .code = .unknown_parameter },
        .{ .tail = "A:=MakeBase(\"x\")", .code = .type_mismatch },
        .{ .tail = "F(I:i64)<computes>:Base=MakeBase(I)", .code = .call_requires_transacts },
        // Delegation: once, to a constructor function of the class or of a superclass.
        .{ .tail = "A:=Sub{MakeOther<constructor>()}", .code = .invalid_delegation },
        .{ .tail = "A:=Base{Sub2<constructor>(1)}", .code = .unknown_name },
        // A constructor function is not declared while its own body is compiled.
        .{ .tail = "Bad<constructor>(Id:i64)<transacts>:=Base{Bad<constructor>(Id)}", .code = .unknown_name },
        .{ .tail = "A:=Sub{Plain<constructor>(1)}", .code = .invalid_delegation },
        .{ .tail = "A:=Sub{MakeBase<constructor>(1),MakeBase<constructor>(2)}", .code = .invalid_delegation },
        .{ .tail = "MakeSub<constructor>(Id:i64)<transacts>:=Sub{MakeBase<constructor>(Id)}\nA:=Base{MakeSub<constructor>(1)}", .code = .invalid_delegation },
        .{ .tail = "A:=Rec{MakeBase<constructor>(1)}", .code = .unknown_field },
        // A field comes from the constructor or from the archetype, never from both.
        .{ .tail = "A:=Sub{Id:=2,MakeBase<constructor>(1)}", .code = .duplicate_field },
        .{ .tail = "A:=Sub{MakeBase<constructor>(1),Id:=2}", .code = .duplicate_field },
        .{ .tail = "A:=Base{Id:=2,MakeBase<constructor>(1)}", .code = .duplicate_field },
        .{ .tail = "Both<constructor>(Id:i64)<transacts>:=Base{N:=1,MakeBase<constructor>(Id)}\nA:=Sub{N:=2,Both<constructor>(1)}", .code = .duplicate_field },
        // The delegated call is checked like any call.
        .{ .tail = "A:=Sub{MakeBase<constructor>()}", .code = .argument_count },
        .{ .tail = "A:=Sub{MakeBase<constructor>(1,2)}", .code = .argument_count },
        .{ .tail = "A:=Sub{MakeBase<constructor>(\"x\")}", .code = .type_mismatch },
        .{ .tail = "A:=Sub{MakeBase<constructor>[1]}", .code = .expected_call },
        .{ .tail = "A:i64=Attempt(Sub{Checked<constructor>(1)}.N,0)", .code = .expected_call },
        .{ .tail = "A:=Sub{Checked<constructor>[1]}", .code = .failure_context_required },
        .{ .tail = "A:=Sub{MakeBase<constructor>(1)+1}", .code = .unexpected_token },
        .{ .tail = "A:=Sub{MakeBase<constructor>(1).N}", .code = .unexpected_token },
        .{ .tail = "A:=Sub{MakeBase<constructor>}", .code = .expected_call },
        .{ .tail = "A:=Sub{Extra:=MakeBase<constructor>(1)}", .code = .unknown_name },
        .{ .tail = "F()<computes>:i64=Sub{MakeBase<constructor>(1)}.Extra", .code = .call_requires_transacts },
        // An abstract class is never built: its constructor function only lends its field values.
        .{ .tail = "A:=MakeHollow(1)", .code = .abstract_instance },
        .{ .tail = "F:function<transacts>(tuple(i64),Hollow)=MakeHollow", .code = .abstract_instance },
        .{ .tail = "A:=Hollow{MakeHollow<constructor>(1)}", .code = .abstract_instance },
        .{ .tail = "Bad<constructor>(K:i64)<transacts>:Hollow=Block{H:=Hollow{};Hollow{K:=K}}", .code = .abstract_instance },
        .{ .tail = "Bad<constructor>(K:i64)<transacts>:=Hollow{K:=Bad(K).K}", .code = .abstract_instance },
        .{ .tail = "Bad(K:i64)<transacts>:Hollow=Hollow{K:=K}", .code = .abstract_instance },
        // Block clauses belong to classes, cannot fail, return nothing and cannot build their class.
        .{ .tail = "I2:=interface{\n  Block{1}\n}", .code = .invalid_interface },
        .{ .tail = "C2:=class{\n  var N:i64=0\n  Block{Require[Self.N>0]}\n}", .code = .failure_context_required },
        .{ .tail = "C2:=class{\n  var N:i64=0\n  Block{Return(1)}\n}", .code = .return_outside_function },
        .{ .tail = "C2:=class{\n  var N:i64=0\n  Block{D:=C2{};set Self.N=D.N}\n}", .code = .construction_cycle },
        .{ .tail = "C2:=class{\n  var N:i64=0\n  Block{set Self.M=1}\n}", .code = .unknown_field },
        .{ .tail = "C2:=class{\n  N:i64=0\n  Block{set Self.N=1}\n}", .code = .not_mutable },
        .{ .tail = "C2:=class{\n  var N:i64=0\n  Block{set Self.N=}\n}", .code = .expected_expression },
    });
}

test "final fields keep their default and final interface members cannot be replaced" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Config:=class{
        \\  Version<final>:i64=3
        \\  var Uses<final>:i64=0
        \\  Name:string="c"
        \\}
        \\Sub:=class(Config){
        \\  Name<override><final>:string="sub"
        \\}
        \\Rule:=interface{
        \\  Limit<final>:i64=100
        \\  Id<final>()<transacts>:i64=42
        \\  Run()<transacts>:i64
        \\}
        \\Impl:=class(Rule){
        \\  Run<override>()<transacts>:i64=Self.Id()+Self.Limit
        \\}
        \\Wider:=interface(Rule){
        \\  More()<transacts>:i64=Self.Id()+1
        \\}
        \\Both:=class(Wider){
        \\  Run<override>()<transacts>:i64=Self.More()
        \\}
        \\MakeConfig<constructor>(Name:string)<transacts>:=Config{Name:=Name}
        \\Bare<constructor>()<transacts>:=Config{}
        \\
    ;
    const x = try h.execute(base ++
        \\C:=Config{Name:="x"}
        \\set C.Uses=C.Uses+1
        \\A:i64=C.Version*10+C.Uses
        \\S:=Sub{Bare<constructor>()}
        \\B:string=S.Name+MakeConfig("given").Name
        \\I:=Impl{}
        \\D:i64=I.Run()
        \\R:Rule=Both{}
        \\E:i64=R.Run()+R.Limit
    );
    try std.testing.expectEqual(@as(i64, 31), x.get("A").?.integer);
    // `Bare` writes nothing, so the instance holds the default `Sub` sealed.
    try std.testing.expectEqualStrings("subgiven", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 142), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 143), x.get("E").?.integer);
    try expectDiagnostics(h, base, &.{
        .{ .tail = "A:=Config{Version:=4}", .code = .final_field },
        .{ .tail = "A:=Config{Uses:=4}", .code = .final_field },
        .{ .tail = "A:=Sub{Name:=\"n\"}", .code = .final_field },
        .{ .tail = "Bad<constructor>()<transacts>:=Config{Version:=4}", .code = .final_field },
        // A constructor function of the superclass that writes a field the subclass sealed.
        .{ .tail = "A:=Sub{MakeConfig<constructor>(\"n\")}", .code = .final_field },
        .{ .tail = "MakeSub<constructor>()<transacts>:=Sub{MakeConfig<constructor>(\"n\")}", .code = .final_field },
        .{ .tail = "D2:=class(Config){\n  Version<override>:i64=4\n}", .code = .final_field },
        .{ .tail = "D2:=class(Sub){\n  Name<override>:string=\"n\"\n}", .code = .final_field },
        .{ .tail = "D2:=class{\n  V<final>:i64\n}", .code = .final_field },
        // Sealing without a value keeps the inherited default, which then has to exist.
        .{ .tail = "P2:=class{\n  Q:i64\n}\nD2:=class(P2){\n  Q<override><final>:i64\n}", .code = .final_field },
        .{ .tail = "D2:=class(Config){\n  Name<override><final>:string\n}\nA:=D2{Name:=\"n\"}", .code = .final_field },
        .{ .tail = "D2:=class{\n  V<final><final>:i64=1\n}", .code = .unsupported_specifier },
        .{ .tail = "A:=Impl{Limit:=1}", .code = .final_field },
        .{ .tail = "D2:=class(Rule){\n  Limit<override>:i64=1\n  Run<override>()<transacts>:i64=1\n}", .code = .final_field },
        .{ .tail = "D2:=class(Rule){\n  Run<override>()<transacts>:i64=1\n  Id<override>()<transacts>:i64=2\n}", .code = .final_method },
        .{ .tail = "D2:=class(Wider){\n  Run<override>()<transacts>:i64=1\n  Id<override>()<transacts>:i64=2\n}", .code = .final_method },
        .{ .tail = "I2:=interface(Rule){\n  Id<override>()<transacts>:i64=2\n}", .code = .final_method },
        .{ .tail = "I2:=interface{\n  Id<final>()<transacts>:i64\n}", .code = .invalid_interface },
        .{ .tail = "I2:=interface{\n  Limit<final>:i64\n}", .code = .final_field },
        // A superclass member cannot stand in for a final member of an interface.
        .{ .tail = "P2:=class{\n  Id()<transacts>:i64=7\n}\nD2:=class(P2,Rule){\n  Run<override>()<transacts>:i64=1\n}", .code = .final_method },
        .{ .tail = "P2:=class{\n  Limit:i64=7\n}\nD2:=class(P2,Rule){\n  Run<override>()<transacts>:i64=1\n}", .code = .final_field },
    });
}

test "an extension method leaves the bare name of a builtin what it was" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\(V:i64).BitAnd(W:i64)<computes>:i64=V+W
        \\(V:i64).BitOr(W:i64)<computes>:i64=V*W
        \\(V:i64).BitXor(W:i64)<computes>:i64=V-W
        \\(V:i64).BitNot()<computes>:i64=V+1
        \\(V:i64).Quotient(W:i64)<computes>:i64=V+W+1
        \\(V:i64).Mod(W:i64)<computes>:i64=Attempt(Mod[V,W],0-1)+100
        \\(V:i64).Rational(W:i64)<computes>:i64=V+W+3
        \\(V:i64).MakeRationalFromInt()<computes>:i64=V+4
        \\(V:i64).rational()<computes>:i64=V+5
        \\(V:i64).char()<computes>:i64=V+6
        \\R:=rational
        \\K:=char
        \\A:i64=6.BitAnd(3)*1000+BitAnd(6,3)
        \\B:i64=6.BitOr(3)*1000+BitOr(6,3)
        \\C:i64=6.BitXor(3)*1000+BitXor(6,3)
        \\D:i64=6.BitNot()*1000+BitNot(0-7)
        \\E:i64=7.Quotient(2)*1000+Attempt(Quotient[7,2],0-1)
        \\F:i64=7.Mod(2)*1000+Attempt(Mod[7,2],0-1)
        \\G:R=Attempt(Rational[1,2],MakeRationalFromInt(0))
        \\H:i64=1.Rational(2)*1000+Floor(G+MakeRationalFromInt(5))
        \\I:i64=1.MakeRationalFromInt()*100+1.rational()*10+1.char()
        \\J:K='a'
        \\Inside(V:i64)<computes>:i64=BitAnd(V,3)+V.BitAnd(3)
        \\L:i64=Inside(6)
        \\(V:i64).Twice()<computes>:i64=BitOr(V,1)+V.BitOr(1)
        \\M:i64=6.Twice()
    );
    try std.testing.expectEqual(@as(i64, 9002), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 18007), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3005), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 7006), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 10003), x.get("E").?.integer);
    // Inside its own body too, the bare name is the intrinsic: 7 mod 2, plus 100.
    try std.testing.expectEqual(@as(i64, 101001), x.get("F").?.integer);
    try std.testing.expectEqualDeep(types.Value{ .rational = .{ .numerator = 1, .denominator = 2 } }, x.get("G").?);
    try std.testing.expectEqual(@as(i64, 6005), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 567), x.get("I").?.integer);
    try std.testing.expectEqual(@as(i64, 2 + 9), x.get("L").?.integer);
    try std.testing.expectEqual(@as(i64, 7 + 6), x.get("M").?.integer);
    try expectDiagnostics(h, "", &.{
        // Still only called on a receiver, and a function of the name still takes the bare name.
        .{ .tail = "(V:i64).Dup()<computes>:i64=V\nA:i64=Dup(1)", .code = .unknown_name },
        .{ .tail = "(V:i64).Dup()<computes>:i64=V\nF:=Dup", .code = .unknown_name },
        .{ .tail = "BitAnd(A:string)<computes>:i64=1\nB:i64=BitAnd(6,3)", .code = .argument_count },
        .{ .tail = "(V:i64).BitAnd(W:i64)<computes>:i64=V\nBitAnd(A:i64,B:i64)<computes>:i64=1", .code = .duplicate_name },
        // Inside a class with a member of the name the bare name is still not the intrinsic.
        .{ .tail = "(V:i64).BitAnd(W:i64)<computes>:i64=V\nI:=interface{BitAnd:i64=9\nRun()<transacts>:i64=BitAnd(6,3)}", .code = .unknown_name },
    });
    // Across modules: a used module's extension method exports no bare name either.
    const lib = "(V:i64).BitAnd<public>(W:i64)<computes>:i64=V+W\n(V:i64).Quotient<public>(W:i64)<computes>:i64=V+W\n(V:i64).rational<public>()<computes>:i64=V\n(V:i64).Helper<public>()<computes>:i64=V";
    const good = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nR:=rational\nA<public>:i64=6.BitAnd(3)*1000+BitAnd(6,3)\nB<public>:i64=7.Quotient(2)*1000+Attempt(Quotient[7,2],0-1)\nC<public>:R=MakeRationalFromInt(3)\nD<public>:i64=4.rational()" },
        .{ .path = "lib.forb", .source = lib },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &good });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 20_000);
    try std.testing.expectEqual(@as(i64, 9002), result.ok.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 9003), result.ok.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.ok.get("D").?.integer);
    const refused = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=Helper(1)" },
        .{ .path = "lib.forb", .source = lib },
    };
    const failed = h.front.compileBundle(.{ .root = "main.forb", .modules = &refused });
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, failed.failed.diagnostic.code);
}

test "a loop body writes the fields of an instance it does not carry" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Point:=struct{X:i64,Y:i64}
        \\Counter:=class{
        \\  var N:i64=0
        \\  var At:Point=Point{X:=0,Y:=0}
        \\  ByWhile(Times:i64)<transacts>:i64=Block{
        \\    var I:i64=0
        \\    While(I<Times,Block{set Self.N=Self.N+1;set I=I+1})
        \\    Self.N
        \\  }
        \\  ByLoop(Times:i64)<transacts>:i64=Block{
        \\    var I:i64=0
        \\    Loop{
        \\      If(I>=Times,Break(),false)
        \\      set Self.N+=10
        \\      set Self.At.X=Self.At.X+I
        \\      set I=I+1
        \\    }
        \\    Self.N
        \\  }
        \\  ByFor(Xs:[]i64)<transacts>:i64=Block{
        \\    For(X:Xs,Block{set Self.N=Self.N+X;X})
        \\    Self.N
        \\  }
        \\  Until(Limit:i64)<transacts>:i64=Block{
        \\    var I:i64=0
        \\    While(I<100,Block{
        \\      If(Self.N>=Limit,Return(I),false)
        \\      set Self.N=Self.N+7
        \\      set I=I+1
        \\    })
        \\    0-1
        \\  }
        \\  Scan(Xs:[]i64)<transacts>:i64=Block{
        \\    For(X:Xs,Block{If(X<0,Return(X),false);set Self.N=Self.N+X;X})
        \\    Self.N
        \\  }
        \\}
        \\Feed(P:Counter,Xs:[]i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  While(I<Xs.Length,Block{set P.N=P.N+Attempt(Xs[I],0);set I=I+1})
        \\  Loop{
        \\    If(P.N>=50,Break(),false)
        \\    set P.N=P.N*2
        \\  }
        \\  P.N
        \\}
        \\Local(P:Counter)<transacts>:i64=Block{
        \\  Q:=P
        \\  var R:Counter=P
        \\  var Rec:Point=Point{X:=1,Y:=1}
        \\  var I:i64=0
        \\  While(I<3,Block{set Q.N=Q.N+1;set R.N=R.N+1;set Rec.X=Rec.X+I;set I=I+1})
        \\  Loop{
        \\    If(I>=6,Break(),false)
        \\    set Q.N=Q.N+1
        \\    set Rec.Y=Rec.Y+I
        \\    set I=I+1
        \\  }
        \\  P.N*10000+Rec.X*100+Rec.Y
        \\}
        \\Holder:=class{
        \\  var Q:i64=0
        \\  var P:Point=Point{X:=0,Y:=0}
        \\  Feed(Q:Counter,P:Counter)<transacts>:i64=Block{
        \\    var I:i64=0
        \\    While(I<2,Block{set Q.N=Q.N+1;set P.N=P.N+10;set I=I+1})
        \\    Loop{
        \\      If(Q.N>=5,Break(),false)
        \\      set Q.N+=1
        \\    }
        \\    Q.N*100+P.N
        \\  }
        \\}
        \\G:=Counter{}
        \\Global()<transacts>:i64=Block{
        \\  var I:i64=0
        \\  While(I<4,Block{set G.N=G.N+I;set I=I+1})
        \\  Loop{
        \\    If(G.N>20,Return(G.N),false)
        \\    set G.N+=5
        \\  }
        \\  0
        \\}
        \\C:=Counter{}
        \\A:i64=C.ByWhile(3)
        \\B:i64=C.ByLoop(2)
        \\B2:i64=C.At.X*100+C.At.Y
        \\D:i64=C.ByFor(array{1,2,3})
        \\E:i64=C.Until(60)
        \\E2:i64=C.N
        \\F:i64=C.Scan(array{1,0-5,100})
        \\F2:i64=C.N
        \\P:=Counter{}
        \\H:i64=Feed(P,array{3,4})
        \\Q:=Counter{}
        \\J:i64=Local(Q)
        \\K:i64=Global()
        \\K2:i64=G.N
        \\M:i64=Holder{}.Feed(Counter{},Counter{})
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 23), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 100), x.get("B2").?.integer);
    try std.testing.expectEqual(@as(i64, 29), x.get("D").?.integer);
    // 29, 36, ..., 64: five visits before the sixth returns.
    try std.testing.expectEqual(@as(i64, 5), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 64), x.get("E2").?.integer);
    // The write of the first visit stays when the second returns.
    try std.testing.expectEqual(@as(i64, -5), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 65), x.get("F2").?.integer);
    try std.testing.expectEqual(@as(i64, 56), x.get("H").?.integer);
    // Nine writes reach the one instance; the struct in a `var` is still carried and stored back.
    try std.testing.expectEqual(@as(i64, 9 * 10000 + 4 * 100 + 13), x.get("J").?.integer);
    try std.testing.expectEqual(@as(i64, 21), x.get("K").?.integer);
    try std.testing.expectEqual(@as(i64, 21), x.get("K2").?.integer);
    // A parameter named like a `var` field of the class around it is still not a `var` local.
    try std.testing.expectEqual(@as(i64, 520), x.get("M").?.integer);
    try expectDiagnostics(h, "Point:=struct{X:i64,Y:i64}\nCounter:=class{\n  var N:i64=0\n  K:i64=0\n}\n", &.{
        // What cannot be assigned outside a loop cannot be assigned inside one.
        .{ .tail = "F(P:Point)<transacts>:i64=Block{var I:i64=0;While(I<2,Block{set P.X=1;set I=I+1});P.X}", .code = .not_mutable },
        .{ .tail = "F(P:Counter)<transacts>:i64=Block{var I:i64=0;While(I<2,Block{set P.K=1;set I=I+1});P.K}", .code = .not_mutable },
        .{ .tail = "F(P:Counter)<transacts>:i64=Block{Loop{set P.K=1;Break()};P.K}", .code = .not_mutable },
        .{ .tail = "F(P:Counter)<computes>:i64=Block{Loop{set P.N=1;Break()};1}", .code = .set_requires_writes },
    });
}

test "constructor functions and block clauses across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\var Count<public>:i64=0
        \\Bump()<transacts>:i64=Block{set Count=Count+1;Count}
        \\Scale()<computes>:i64=3
        \\Base<public>:=class{
        \\  Id<public>:i64
        \\  var Seen<public>:i64=0
        \\  Steps<public>:[]i64=array{}
        \\  Block{set Self.Seen=Bump()}
        \\}
        \\MakeBase<public><constructor>(Id:i64,Twice:logic=false)<transacts>:=Base{Id:=If(Twice,Id*Scale()*2,Id*Scale()),Steps:=For(I:1..Id,I*Scale())}
        \\Counted<constructor><public>(Id:i64)<transacts>:=Base{Id:=Block{set Count=Count+100;Id}}
        \\Stepped<public><constructor>(Id:i64)<transacts>:=Base{Id:=Block{var T:i64=Id;set T=T+1;T}}
        \\Hidden<constructor>(Id:i64)<transacts>:=Base{Id:=Id}
        \\Mid<public>:=class(Base){
        \\  Half<public>:i64=0
        \\  Block{set Self.Seen=Self.Seen+1000}
        \\}
        \\MakeMid<public><constructor>(Id:i64)<transacts>:=Mid{Half:=Id,MakeBase<constructor>(Id)}
        \\CountedMid<public><constructor>(Id:i64)<transacts>:=Mid{Half:=Id,Counted<constructor>(Id)}
    ;
    const good = [_]modules.Input{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\using{L}
        \\Sub:=class(Mid){
        \\  Extra:i64=0
        \\  Block{set Self.Seen=Self.Seen+20000}
        \\}
        \\MakeSub<constructor>(Id:i64)<transacts>:=Sub{Extra:=1,MakeBase<constructor>(Id)}
        \\Build(Id:i64)<transacts>:i64=Sub{L.MakeBase<constructor>(Twice:=true,Id:=Id)}.Id
        \\A:=MakeBase(2)
        \\B:=MakeSub(5)
        \\C:=Sub{MakeMid<constructor>(7)}
        \\D:=Counted(4)
        \\E:=Stepped(8)
        \\R1<public>:i64=A.Id*100000+A.Seen
        \\R2<public>:i64=B.Id*100000+B.Seen
        \\R3<public>:i64=C.Id*100000+C.Seen+C.Half*1000000
        \\R4<public>:i64=Build(1)
        \\R5<public>:i64=D.Id+E.Id*10
        \\R6<public>:i64=Count
        \\R7<public>:i64=B.Steps.Length*100+Attempt(B.Steps[1],0)+C.Steps.Length*10000
        },
        .{ .path = "lib.forb", .source = lib },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &good });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path, bundled.failed.diagnostic.span.start });
    try std.testing.expect(bundled == .ok);
    const result = try h.run(bundled.ok, 40_000);
    // The library's clause runs first on every instance, then `Mid`'s, then `Sub`'s.
    try std.testing.expectEqual(@as(i64, 6 * 100000 + 1), result.ok.get("R1").?.integer);
    try std.testing.expectEqual(@as(i64, 15 * 100000 + 21002), result.ok.get("R2").?.integer);
    try std.testing.expectEqual(@as(i64, 21 * 100000 + 21003 + 7 * 1000000), result.ok.get("R3").?.integer);
    try std.testing.expectEqual(@as(i64, 6), result.ok.get("R4").?.integer);
    try std.testing.expectEqual(@as(i64, 4 + 90), result.ok.get("R5").?.integer);
    // Six instances counted by the library's clause, and the 100 `Counted` adds when called.
    try std.testing.expectEqual(@as(i64, 106), result.ok.get("R6").?.integer);
    // The loop of the library's constructor function, expanded into this module's archetypes,
    // still calls the library's private `Scale`.
    try std.testing.expectEqual(@as(i64, 70506), result.ok.get("R7").?.integer);

    const refused = [_]struct { main: []const u8, code: types.Diagnostic.Code }{
        // A constructor function that writes its module's variables or assigns a local keeps
        // those nodes in its own module; it is called from elsewhere, not delegated to.
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nSub:=class(Base){}\nA:=Sub{Counted<constructor>(1)}", .code = .invalid_delegation },
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nSub:=class(Base){}\nF()<transacts>:i64=Sub{Stepped<constructor>(1)}.Id", .code = .invalid_delegation },
        // The same holds for a constructor function that took such a body over by delegating.
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nSub:=class(Mid){}\nA:=Sub{CountedMid<constructor>(1)}", .code = .invalid_delegation },
        // Not exported.
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nSub:=class(Base){}\nA:=Sub{Hidden<constructor>(1)}", .code = .unknown_name },
        .{ .main = "L:=import{\"lib.forb\"}\nSub:=class(L.Base){}\nA:=Sub{L.Hidden<constructor>(1)}", .code = .private_name },
        .{ .main = "L:=import{\"lib.forb\"}\nA:=L.Hidden(1)", .code = .private_name },
    };
    for (refused) |case| {
        const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = case.main }, .{ .path = "lib.forb", .source = lib } };
        const failed = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if (failed == .ok or failed.failed.diagnostic.code != case.code) {
            std.debug.print("module diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.main, @tagName(case.code), if (failed == .ok) "success" else @tagName(failed.failed.diagnostic.code) });
            return error.WrongDiagnostic;
        }
    }
}

const Forge = struct {
    nodes: []types.Node,
    arguments: []u32,
    function_nodes: []types.FunctionNode,
    function_arguments: []u32,
    functions: []types.RuntimeFunction,
    program: types.Program,

    fn init(p: types.Program) !Forge {
        const a = std.testing.allocator;
        return .{
            .nodes = try a.dupe(types.Node, p.nodes),
            .arguments = try a.dupe(u32, p.call_arguments),
            .function_nodes = try a.dupe(types.FunctionNode, p.function_nodes),
            .function_arguments = try a.dupe(u32, p.function_arguments),
            .functions = try a.dupe(types.RuntimeFunction, p.functions),
            .program = p,
        };
    }
    fn deinit(self: *Forge) void {
        const a = std.testing.allocator;
        a.free(self.nodes);
        a.free(self.arguments);
        a.free(self.function_nodes);
        a.free(self.function_arguments);
        a.free(self.functions);
    }
    fn view(self: *const Forge) types.Program {
        var forged = self.program;
        forged.nodes = self.nodes;
        forged.call_arguments = self.arguments;
        forged.function_nodes = self.function_nodes;
        forged.function_arguments = self.function_arguments;
        forged.functions = self.functions;
        return forged;
    }
    fn reset(self: *Forge) void {
        @memcpy(self.nodes, self.program.nodes);
        @memcpy(self.arguments, self.program.call_arguments);
        @memcpy(self.function_nodes, self.program.function_nodes);
        @memcpy(self.function_arguments, self.program.function_arguments);
        @memcpy(self.functions, self.program.functions);
    }
    fn function(self: *const Forge, name: []const u8, parameter: ?types.Type) u32 {
        for (self.program.functions, 0..) |f, index| {
            if (std.mem.eql(u8, f.name.text(self.program.source), name) and (parameter == null or f.parameters[0] == parameter.?)) return @intCast(index);
        }
        unreachable;
    }
};

test "forged construction through constructor functions and block clauses is rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // No operation is new: a constructor function is a function whose body ends in the one
    // `object_new`, and a block clause is a function called on the instance. So what both
    // admissions already prove about those nodes is what keeps construction sound.
    const p = try h.compile(
        \\Base:=class{
        \\  Id:i64
        \\  var Seen:i64=0
        \\  Block{set Self.Seen=Self.Seen+1}
        \\}
        \\Other:=class{
        \\  Name:string="o"
        \\  var Hits:i64=0
        \\  Block{set Self.Hits=Self.Hits+1}
        \\}
        \\Sub:=class(Base){
        \\  Tag:string
        \\  Block{set Self.Seen=Self.Seen+10}
        \\}
        \\MakeBase<constructor>(Id:i64)<transacts>:=Base{Id:=Id+1}
        \\MakeSub<constructor>(Id:i64,Tag:string)<transacts>:=Sub{Tag:=Tag,MakeBase<constructor>(Id)}
        \\B:=Base{Id:=1}
        \\O:=Other{}
        \\S:=MakeSub(4,"t")
        \\R:i64=B.Seen*1000+S.Seen*10+O.Hits+S.Id
    );
    var forge = try Forge.init(p);
    defer forge.deinit();
    const run = try h.run(forge.view(), 20_000);
    try std.testing.expectEqual(@as(i64, 1000 + 110 + 1 + 5), run.ok.get("R").?.integer);
    const base_type = p.nodes[p.bindings[0].node].value_type;
    const other_type = p.nodes[p.bindings[1].node].value_type;
    const sub_type = p.nodes[p.bindings[2].node].value_type;
    const base_block = forge.function("Block", base_type);
    const other_block = forge.function("Block", other_type);
    const sub_block = forge.function("Block", sub_type);
    // The two top-level archetypes: an `object_new` followed by the call of its class's clause.
    var news: [2]u32 = undefined;
    var calls: [2]u32 = undefined;
    var seen: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .object_new) {
        news[seen] = @intCast(index);
        calls[seen] = @intCast(index + 1);
        try std.testing.expect(p.nodes[index + 1].kind == .call);
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(base_block, p.nodes[calls[0]].kind.call.function);
    try std.testing.expectEqual(other_block, p.nodes[calls[1]].kind.call.function);
    // A clause handed an instance of another class.
    forge.arguments[p.nodes[calls[1]].kind.call.arguments.start] = news[0];
    try harness.invalid(h, forge.view());
    forge.reset();
    // An instance handed to another class's clause.
    forge.nodes[calls[0]].kind.call.function = other_block;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A subclass's clause run on an instance of the superclass: no upcast leads downwards.
    forge.nodes[calls[0]].kind.call.function = sub_block;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A clause that claims to fail or to be pure while it writes.
    forge.functions[base_block].transacts = false;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Inside the constructor functions. `MakeSub` builds a `Sub` from three operands in the
    // order of its cells: `Id` as `MakeBase` computes it, the default of `Seen`, then `Tag`.
    const make_sub = p.functions[forge.function("MakeSub", null)];
    const body = p.function_nodes[make_sub.body.start..make_sub.body.end];
    const new_index = make_sub.body.start + make_sub.root;
    try std.testing.expect(body[make_sub.root].node.kind == .object_new and body[make_sub.root].node.value_type == sub_type);
    const range = body[make_sub.root].node.kind.object_new.arguments;
    try std.testing.expectEqual(@as(u32, 3), range.end - range.start);
    // The delegated values come first, whatever order the archetype wrote them in.
    try std.testing.expect(body[p.function_arguments[range.start]].node.value_type == .i64);
    try std.testing.expect(body[p.function_arguments[range.start + 2]].node.value_type == .string);
    // A field value of the wrong type: `Tag` where `Id` belongs.
    forge.function_arguments[range.start] = p.function_arguments[range.start + 2];
    try harness.invalid(h, forge.view());
    forge.reset();
    // The superclass built from the subclass's values, and the subclass from too few.
    forge.function_nodes[new_index].node.value_type = base_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.function_nodes[new_index].node.kind.object_new.arguments.end -= 1;
    try harness.invalid(h, forge.view());
    forge.reset();
    // The clauses that follow the `object_new` inside the function: `Base`'s on the instance
    // seen as a `Base`, then `Sub`'s. Handing `Base`'s the raw `Sub` skips the upcast.
    var inner: [2]u32 = undefined;
    seen = 0;
    for (body[make_sub.root + 1 ..], make_sub.root + 1..) |entry, index| if (entry.input == .operation and entry.node.kind == .call) {
        inner[seen] = @intCast(index);
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(base_block, body[inner[0]].node.kind.call.function);
    try std.testing.expectEqual(sub_block, body[inner[1]].node.kind.call.function);
    forge.function_arguments[body[inner[0]].node.kind.call.arguments.start] = make_sub.root;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.function_nodes[make_sub.body.start + inner[1]].node.kind.call.function = other_block;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A constructor function that claims another result.
    forge.functions[forge.function("MakeSub", null)].value_type = base_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    _ = try h.run(forge.view(), 20_000);
}

/// A generated hierarchy: every class adds fields, may restate an inherited default, may have a
/// block clause and has up to two constructor functions, which may delegate to a constructor
/// function of any class above or of the class itself.
const Model = struct {
    const max_classes = 6;
    const max_own = 2;
    const max_fields = max_classes * max_own;
    const max_entries = max_fields + 1;
    const failed: i64 = -777;

    const Field = struct { owner: usize, default: ?i64, is_var: bool };
    const Entry = union(enum) {
        /// `F := Note(tag, A * mul + B + add)`, behind `Require[A != reject]` when `guard`.
        field: struct { index: usize, mul: i64, add: i64, guard: bool },
        /// `K<constructor>(A + shift, B * scale)`, or without the second argument.
        delegate: struct { class: usize, which: usize, shift: i64, scale: ?i64 },
    };
    const Constructor = struct {
        entries: [max_entries]Entry = undefined,
        count: usize = 0,
        b_default: i64 = 0,
        decides: bool = false,
        reject: i64 = 0,
        /// The fields its archetype writes, the ones it delegates for included.
        gives: [max_fields]bool = @splat(false),
    };
    const Class = struct {
        parent: ?usize = null,
        /// Fields of the whole chain, the superclass's first.
        fields: [max_fields]Field = undefined,
        field_count: usize = 0,
        first_own: usize = 0,
        /// A default this class restates for an inherited field.
        restated: ?struct { index: usize, value: i64 } = null,
        /// The clause logs its tag and, when the class's first own field is `var`, rewrites it.
        block: ?i64 = null,
        constructors: [2]Constructor = .{ .{}, .{} },
        constructor_count: usize = 0,
    };

    classes: [max_classes]Class = undefined,
    class_count: usize = 0,
    log: [512]i64 = undefined,
    log_count: usize = 0,
    cells: usize = 0,

    fn note(self: *Model, tag: i64) void {
        self.log[self.log_count] = tag;
        self.log_count += 1;
    }
    /// What an instance of `class` holds in `field` when nothing gives it a value: the nearest
    /// restatement at or above `class`, else the default of the declaration.
    fn default(self: *const Model, class: usize, field: usize) ?i64 {
        var at: ?usize = class;
        while (at) |index| : (at = self.classes[index].parent) {
            if (self.classes[index].restated) |restated| if (restated.index == field) return restated.value;
            if (self.classes[class].fields[field].owner == index) return self.classes[class].fields[field].default;
        }
        unreachable;
    }
    /// Runs the archetype of constructor `which` of `class`: its entries in the order written.
    /// A field it does not write stays unset. Fails without a result.
    fn construct(self: *Model, class: usize, which: usize, a: i64, b: i64, values: *[max_fields]?i64) bool {
        const constructor = &self.classes[class].constructors[which];
        for (constructor.entries[0..constructor.count], 0..) |entry, position| switch (entry) {
            .field => |f| {
                if (f.guard and a == constructor.reject) return false;
                self.note(@intCast(class * 1000 + which * 100 + position + 1));
                values[f.index] = a * f.mul + b + f.add;
            },
            .delegate => |d| {
                const target = &self.classes[d.class].constructors[d.which];
                if (!self.construct(d.class, d.which, a + d.shift, if (d.scale) |scale| b * scale else target.b_default, values)) return false;
            },
        };
        return true;
    }
    /// The fields nobody gave take the defaults of the class that is built.
    fn defaults(self: *const Model, class: usize, values: *[max_fields]?i64) void {
        for (values[0..self.classes[class].field_count], 0..) |*value, field| {
            if (value.* == null) value.* = self.default(class, field).?;
        }
    }
    /// The block clauses of the chain on a finished instance, the outermost class first.
    fn clauses(self: *Model, class: usize, values: *[max_fields]?i64) void {
        if (self.classes[class].parent) |parent| self.clauses(parent, values);
        const tag = self.classes[class].block orelse return;
        self.note(tag);
        const own = self.classes[class].first_own;
        if (own < self.classes[class].field_count and self.classes[class].fields[own].is_var) values[own] = values[own].? * 2 + tag;
    }
    fn digest(self: *const Model, class: usize, values: *const [max_fields]?i64) i64 {
        var total: i64 = 0;
        for (values[0..self.classes[class].field_count], 0..) |value, field| total += value.? * @as(i64, @intCast(field + 1));
        return total;
    }
};

test "random hierarchies with constructor functions, delegation and block clauses match a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x75_c0de);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    var delegations: usize = 0;
    var failures: usize = 0;
    var undone: usize = 0;
    var restated_under_delegation: usize = 0;
    for (0..100) |round| {
        source.clearRetainingCapacity();
        var model: Model = .{};
        try source.appendSlice(a, "var Log:[]i64=array{}\nNote(Tag:i64,Value:i64)<transacts>:i64=Block{set Log=Log+array{Tag};Value}\n");
        model.class_count = random.intRangeAtMost(usize, 1, Model.max_classes);
        for (0..model.class_count) |index| {
            var class: Model.Class = .{};
            if (index != 0 and random.uintLessThan(u8, 4) != 0) class.parent = random.uintLessThan(usize, index);
            const inherited = if (class.parent) |parent| model.classes[parent].field_count else 0;
            class.first_own = inherited;
            if (class.parent) |parent| @memcpy(class.fields[0..inherited], model.classes[parent].fields[0..inherited]);
            const own = random.intRangeAtMost(usize, 0, Model.max_own);
            class.field_count = inherited + own;
            if (class.parent) |parent| try source.print(a, "C{d}:=class(C{d}){{\n", .{ index, parent }) else try source.print(a, "C{d}:=class{{\n", .{index});
            for (inherited..class.field_count) |field| {
                class.fields[field] = .{ .owner = index, .default = if (random.boolean()) random.intRangeAtMost(i64, 1, 9) else null, .is_var = random.boolean() };
                try source.print(a, "  {s}F{d}_{d}:i64", .{ if (class.fields[field].is_var) "var " else "", index, field });
                if (class.fields[field].default) |value| try source.print(a, "={d}", .{value});
                try source.appendSlice(a, "\n");
            }
            if (inherited != 0 and random.uintLessThan(u8, 2) == 0) {
                const field = random.uintLessThan(usize, inherited);
                class.restated = .{ .index = field, .value = random.intRangeAtMost(i64, 20, 29) };
                try source.print(a, "  {s}F{d}_{d}<override>:i64={d}\n", .{ if (class.fields[field].is_var) "var " else "", class.fields[field].owner, field, class.restated.?.value });
            }
            if (random.boolean()) {
                class.block = @intCast(9000 + index);
                try source.print(a, "  Block{{\n    Note({d},0)\n", .{class.block.?});
                if (own != 0 and class.fields[inherited].is_var) try source.print(a, "    set Self.F{d}_{d}=Self.F{d}_{d}*2+{d}\n", .{ index, inherited, index, inherited, class.block.? });
                try source.appendSlice(a, "  }\n");
            }
            try source.appendSlice(a, "}\n");
            model.classes[index] = class;
            // Up to two constructor functions; the second may forward to the first.
            const wanted = random.intRangeAtMost(usize, 0, 2);
            for (0..wanted) |which| {
                var constructor: Model.Constructor = .{ .b_default = random.intRangeAtMost(i64, 0, 5), .reject = random.intRangeAtMost(i64, 0, 4) };
                // The constructor functions this one could delegate to: any class of the chain.
                var target: ?struct { class: usize, which: usize } = null;
                var at: ?usize = index;
                while (at) |candidate| : (at = model.classes[candidate].parent) {
                    const available = if (candidate == index) which else model.classes[candidate].constructor_count;
                    if (available != 0 and random.uintLessThan(u8, 3) != 0) {
                        target = .{ .class = candidate, .which = random.uintLessThan(usize, available) };
                        break;
                    }
                }
                if (target) |t| constructor.gives = model.classes[t.class].constructors[t.which].gives;
                var guarded = false;
                for (0..class.field_count) |field| {
                    // What the delegated constructor writes cannot be written again. A field
                    // without a default for this class has to be given; another may be.
                    if (constructor.gives[field]) continue;
                    if (model.default(index, field) != null and random.boolean()) continue;
                    const guard = !guarded and random.uintLessThan(u8, 4) == 0;
                    guarded = guarded or guard;
                    constructor.entries[constructor.count] = .{ .field = .{ .index = field, .mul = random.intRangeAtMost(i64, 1, 3), .add = random.intRangeAtMost(i64, 0, 9), .guard = guard } };
                    constructor.count += 1;
                    constructor.gives[field] = true;
                }
                random.shuffle(Model.Entry, constructor.entries[0..constructor.count]);
                constructor.decides = guarded;
                if (target) |t| {
                    // The delegation stands anywhere among the entries.
                    const place = random.uintAtMost(usize, constructor.count);
                    std.mem.copyBackwards(Model.Entry, constructor.entries[place + 1 .. constructor.count + 1], constructor.entries[place..constructor.count]);
                    constructor.entries[place] = .{ .delegate = .{ .class = t.class, .which = t.which, .shift = random.intRangeAtMost(i64, 0, 2), .scale = if (random.boolean()) random.intRangeAtMost(i64, 1, 3) else null } };
                    constructor.count += 1;
                    constructor.decides = constructor.decides or model.classes[t.class].constructors[t.which].decides;
                    delegations += 1;
                }
                try source.print(a, "K{d}_{d}<constructor>(A:i64,B:i64={d})<transacts>{s}:=C{d}{{\n", .{ index, which, constructor.b_default, if (constructor.decides) "<decides>" else "", index });
                for (constructor.entries[0..constructor.count], 0..) |entry, position| switch (entry) {
                    .field => |f| {
                        const tag = index * 1000 + which * 100 + position + 1;
                        try source.print(a, "  F{d}_{d}:=", .{ class.fields[f.index].owner, f.index });
                        if (f.guard) try source.print(a, "Block{{Require[A!={d}];Note({d},A*{d}+B+{d})}}\n", .{ constructor.reject, tag, f.mul, f.add }) else try source.print(a, "Note({d},A*{d}+B+{d})\n", .{ tag, f.mul, f.add });
                    },
                    .delegate => |d| {
                        const brackets: [2][]const u8 = if (model.classes[d.class].constructors[d.which].decides) .{ "[", "]" } else .{ "(", ")" };
                        try source.print(a, "  K{d}_{d}<constructor>{s}A+{d}", .{ d.class, d.which, brackets[0], d.shift });
                        if (d.scale) |scale| try source.print(a, ",B:=B*{d}", .{scale});
                        try source.print(a, "{s}\n", .{brackets[1]});
                    },
                };
                try source.appendSlice(a, "}\n");
                model.classes[index].constructors[which] = constructor;
                model.classes[index].constructor_count = which + 1;
            }
        }
        // Constructions: through a constructor function, or by an archetype that delegates and
        // names other fields itself. Some are undone after the instance exists.
        var expected: [24]i64 = undefined;
        var results: usize = 0;
        for (0..24) |_| {
            const class = random.uintLessThan(usize, model.class_count);
            // A constructor function of the class or of one above it.
            var owner: ?usize = class;
            while (owner) |candidate| : (owner = model.classes[candidate].parent) if (model.classes[candidate].constructor_count != 0 and random.boolean()) break;
            const from = owner orelse continue;
            const which = random.uintLessThan(usize, model.classes[from].constructor_count);
            const constructor = &model.classes[from].constructors[which];
            const arg_a = random.intRangeAtMost(i64, 0, 5);
            const arg_b: ?i64 = if (random.boolean()) random.intRangeAtMost(i64, 0, 5) else null;
            const direct = from == class and random.boolean();
            const late = random.uintLessThan(u8, 5) == 0;
            var values: [Model.max_fields]?i64 = @splat(null);
            const log_before = model.log_count;
            var extra: [Model.max_fields]?i64 = @splat(null);
            if (!direct) {
                // `Class{F := v, ..., K<constructor>(...)}`: the named fields first, as written.
                for (0..model.classes[class].field_count) |field| {
                    if (constructor.gives[field]) continue;
                    if (model.default(class, field) != null and random.boolean()) continue;
                    extra[field] = random.intRangeAtMost(i64, 30, 39);
                    model.note(@intCast(50_000 + field));
                    values[field] = extra[field];
                }
            }
            const ok = model.construct(from, which, arg_a, arg_b orelse constructor.b_default, &values);
            if (ok) {
                // A restated default applies to a field the constructor above left alone.
                if (model.classes[class].restated) |restated| if (values[restated.index] == null and from != class) {
                    restated_under_delegation += 1;
                };
                model.defaults(class, &values);
                model.clauses(class, &values);
            }
            const sum = if (ok) model.digest(class, &values) else Model.failed;
            // `Require[Digest != sum]` after the instance exists undoes it and all it logged.
            const kept = ok and !late;
            if (!kept) model.log_count = log_before;
            if (!ok) failures += 1;
            if (ok and late) undone += 1;
            if (kept) model.cells += 1 + model.classes[class].field_count;
            expected[results] = if (kept) sum else Model.failed;
            try source.print(a, "R{d}:i64=Attempt(Block{{X:=", .{results});
            const brackets: [2][]const u8 = if (constructor.decides) .{ "[", "]" } else .{ "(", ")" };
            if (direct) {
                try source.print(a, "K{d}_{d}{s}{d}", .{ from, which, brackets[0], arg_a });
            } else {
                try source.print(a, "C{d}{{", .{class});
                for (extra[0..model.classes[class].field_count], 0..) |value, field| if (value) |given| {
                    try source.print(a, "F{d}_{d}:=Note({d},{d}),", .{ model.classes[class].fields[field].owner, field, 50_000 + field, given });
                };
                try source.print(a, "K{d}_{d}<constructor>{s}{d}", .{ from, which, brackets[0], arg_a });
            }
            if (arg_b) |b| try source.print(a, ",{d}", .{b});
            try source.print(a, "{s}{s};D:=0", .{ brackets[1], if (direct) "" else "}" });
            for (0..model.classes[class].field_count) |field| try source.print(a, "+X.F{d}_{d}*{d}", .{ model.classes[class].fields[field].owner, field, field + 1 });
            if (late) try source.print(a, ";Require[D!={d}]", .{sum});
            try source.print(a, ";D}},{d})\n", .{Model.failed});
            results += 1;
        }
        try source.appendSlice(a, "L:[]i64=Log\n");
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
        // Every field value and every block clause ran in the model's order, and nothing a
        // failed or undone construction logged is left.
        expectIntegers(x, "L", model.log[0..model.log_count]) catch |err| {
            std.debug.print("round {d} log differs:\n{s}\n", .{ round, source.items });
            return err;
        };
        // Exactly the instances that were kept exist.
        if (x.object_cells.len != model.cells) {
            std.debug.print("round {d}: expected {d} object cells, got {d}\n{s}\n", .{ round, model.cells, x.object_cells.len, source.items });
            return error.ModelMismatch;
        }
    }
    // The generator reaches what it is meant to test.
    try std.testing.expect(delegations > 40 and failures > 20 and undone > 20 and restated_under_delegation > 10);
}

test "a delegated constructor function may call and name itself, assign locals and write module variables" {
    const h = try harness.create();
    defer scratch.release(h);
    // Its body is expanded into the archetype that delegates, where `MakeNode` no longer means
    // "this function": the recursive call and the function value have to name it there.
    const x = try h.execute(
        \\var Count:i64=0
        \\Node:=class{
        \\  Value:i64
        \\  Next:option(Node)
        \\  Depth:i64
        \\  Make:function<transacts>(tuple(i64),Node)
        \\  Twice:function<computes>(tuple(i64),i64)
        \\  Doubled:[]i64
        \\}
        \\MakeNode<constructor>(N:i64)<transacts>:=Node{
        \\  Value:=Block{var T:i64=N;set T=T*2;set Count=Count+1;T+Count}
        \\  Next:=If(N>0,option{MakeNode(N-1)},option{})
        \\  Depth:=N
        \\  Make:=MakeNode
        \\  Twice:=Fn(V:i64)<computes>:i64{V*2+N}
        \\  Doubled:=For(I:0..N,I*2)
        \\}
        \\Leaf:=class(Node){
        \\  Tag:string="leaf"
        \\}
        \\MakeLeaf<constructor>(N:i64)<transacts>:=Leaf{MakeNode<constructor>(N)}
        \\A:=Leaf{MakeNode<constructor>(2)}
        \\B:=MakeLeaf(1)
        \\Walk(X:Node)<transacts>:i64=1+Attempt(Walk(X.Next?),0)
        \\RA:i64=Walk(A)*1000+A.Value
        \\RB:i64=Walk(B)*1000+B.Value
        \\RC:i64=Walk(A.Make(3))
        \\RD:i64=Count
        \\RE:i64=A.Twice(10)*100+B.Twice(10)
        \\RF:[]i64=A.Doubled
    );
    try std.testing.expectEqual(@as(i64, 3005), x.get("RA").?.integer);
    try std.testing.expectEqual(@as(i64, 2006), x.get("RB").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("RC").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("RD").?.integer);
    try std.testing.expectEqual(@as(i64, 2221), x.get("RE").?.integer);
    try expectIntegers(x, "RF", &.{ 0, 2, 4 });
}
