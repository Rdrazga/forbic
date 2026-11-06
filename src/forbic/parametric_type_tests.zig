//! Parametric classes, structs and interfaces (RFC-0073): one definition for each list of type
//! arguments, made where it is first named and found again without a search.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const catalogue = @import("aggregate_types.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");

const Case = struct { tail: []const u8, code: types.Diagnostic.Code };

fn expectDiagnostics(h: *harness.Harness, base: []const u8, cases: []const Case) !void {
    var buffer: [8192]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, case.tail });
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("parametric type diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.tail, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

/// The definitions of a program that are instantiations of the template named `name`.
fn instancesOf(program: types.Program, name: []const u8) usize {
    var count: usize = 0;
    for (program.definitions) |item| {
        if (catalogue.typeArguments(item) == null) continue;
        if (std.mem.eql(u8, catalogue.declaredName(item).?.text(program.source), name)) count += 1;
    }
    return count;
}

/// The instantiation of `name` whose arguments are exactly `arguments`.
fn instance(program: types.Program, name: []const u8, arguments: []const types.Type) ?types.Type {
    for (program.definitions, 0..) |item, index| {
        const key = catalogue.typeArguments(item) orelse continue;
        if (!std.mem.eql(u8, catalogue.declaredName(item).?.text(program.source), name)) continue;
        const list = catalogue.definition(key, program.definitions).?.tuple;
        if (std.mem.eql(types.Type, arguments, program.tuple_elements[list.start..list.end])) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    }
    return null;
}

test "a parametric class is one type for each argument list, with fields and methods of the argument" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Box[T:type]:=class<unique>{
        \\  var Value:T
        \\  Get()<transacts>:T=Self.Value
        \\  Put(New:T)<transacts>:T=Block{Old:T=Self.Value;set Self.Value=New;Old}
        \\}
        \\Pair[A:type,B:type]:=class{
        \\  First:A
        \\  Second:B
        \\  Swap()<transacts>:Pair[B,A]=Pair[B,A]{First:=Self.Second,Second:=Self.First}
        \\}
        \\I:=Box[i64]{Value:=1}
        \\S:Box[string]=Box[string]{Value:="a"}
        \\A:i64=I.Get()
        \\B:i64=I.Put(5)
        \\C:i64=I.Get()
        \\D:string=S.Get()+S.Put("b")+S.Get()
        \\J:Box[i64]=I
        \\E:logic=J==I
        \\P:=Pair[i64,string]{First:=7,Second:="x"}
        \\Q:Pair[string,i64]=P.Swap()
        \\F:string=Q.First
        \\G:i64=Q.Second
        \\Ints:=Box[i64]
        \\K:Ints=Box[i64]{Value:=9}
        \\H:i64=K.Get()+J.Get()
        \\Nested:=Box[Box[[]i64]]{Value:=Box[[]i64]{Value:=array{1,2}}}
        \\L:i64=Nested.Get().Get().Length
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expectEqualStrings("aab", x.get("D").?.string);
    try std.testing.expect(x.get("E").?.boolean);
    try std.testing.expectEqualStrings("x", x.get("F").?.string);
    try std.testing.expectEqual(@as(i64, 7), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 14), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("L").?.integer);
    // `Box[i64]` is named six times and is one definition; so is each `Pair`.
    try std.testing.expectEqual(@as(usize, 4), instancesOf(x.program, "Box"));
    try std.testing.expectEqual(@as(usize, 2), instancesOf(x.program, "Pair"));
    const ints = instance(x.program, "Box", &.{.i64}).?;
    try std.testing.expectEqual(ints, x.get("I").?.object.value_type);
    try std.testing.expectEqual(ints, x.get("K").?.object.value_type);
    // An instantiation is a class like any other: two cells, one slot per method, its own entries.
    try std.testing.expectEqual(@as(u32, 2), catalogue.classCells(ints, x.program.definitions).?);
    var slots: usize = 0;
    for (x.program.slots) |slot| slots += @intFromBool(slot.owner == ints);
    try std.testing.expectEqual(@as(usize, 2), slots);
    var entries: usize = 0;
    for (x.program.dispatch) |entry| entries += @intFromBool(entry.class == ints);
    try std.testing.expectEqual(@as(usize, 2), entries);
    try std.testing.expect(h.front.instantiation_depth == 0 and h.front.local_count == 0 and h.front.anonymous_count == 0);
}

test "parametric structs are values: equal by their fields, usable as map keys and nested" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Pt[T:type]:=struct{X:T,Y:T,Tags:[]string=array{"a","b"},Pair:tuple(i64,string)=tuple{1,"p"}}
        \\Line[T:type]:=struct{From:Pt[T],To:Pt[T],Name:string="l"}
        \\A:=Pt[i64]{X:=1,Y:=2}
        \\B:Pt[i64]=Pt[i64]{X:=1,Y:=2}
        \\E:logic=A==B
        \\N:logic=A==Pt[i64]{X:=1,Y:=3}
        \\M:map(Pt[i64],string)=map{A=>"a"}
        \\F:string=Or(Lookup(M,B),"none")
        \\S:i64=A.X+B.Y+A.Tags.Length+A.Pair(0)
        \\L:=Line[i64]{From:=Pt[i64]{X:=0,Y:=0},To:=Pt[i64]{X:=3,Y:=4}}
        \\D:i64=L.To.X+L.To.Y
        \\Deep:=Line[Line[i64]]{From:=Pt[Line[i64]]{X:=L,Y:=L},To:=Pt[Line[i64]]{X:=L,Y:=L}}
        \\G:string=Deep.From.X.Name
        \\W:Pt[string]=WithField(Pt[string]{X:="x",Y:="y"},X,"z")
        \\V:string=W.X+W.Y
    );
    try std.testing.expect(x.get("E").?.boolean);
    try std.testing.expect(!x.get("N").?.boolean);
    try std.testing.expectEqualStrings("a", x.get("F").?.string);
    try std.testing.expectEqual(@as(i64, 6), x.get("S").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("D").?.integer);
    try std.testing.expectEqualStrings("l", x.get("G").?.string);
    try std.testing.expectEqualStrings("zy", x.get("V").?.string);
    try std.testing.expectEqual(@as(usize, 3), instancesOf(x.program, "Pt"));
    try std.testing.expectEqual(@as(usize, 2), instancesOf(x.program, "Line"));
    // A struct of comparable parts is comparable; one that holds a function is not.
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_map_key, h.front.compile("Pt[T:type]:=struct{X:T}\nM:map(Pt[function(tuple(i64),i64)],i64)=map{}").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.not_comparable, h.front.compile("Pt[T:type]:=struct{X:T}\nF(N:i64)<computes>:i64=N\nA:=Pt[function(tuple(i64),i64)]{X:=F}\nE:logic=A==A").failed.code);
}

test "instantiations are superclasses and interfaces, dispatch through them and cast both ways" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Container[T:type]:=interface{
        \\  Get()<transacts>:T
        \\  Twice()<transacts>:[]T=array{Self.Get(),Self.Get()}
        \\}
        \\Box[T:type]:=class(Container[T]){
        \\  var Value:T
        \\  Get<override>()<transacts>:T=Self.Value
        \\}
        \\IntBox:=class(Box[i64]){
        \\  Extra:i64=10
        \\  Get<override>()<transacts>:i64=Self.Value+Self.Extra
        \\}
        \\Lazy[T:type]:=class(Container[T]){
        \\  Make:function<transacts>(tuple(),T)
        \\  Get<override>()<transacts>:T=Self.Make()
        \\}
        \\Shape[T:type]:=class{Tag:T}
        \\Disc[T:type]:=class(Shape[T]){R:i64}
        \\Flat[T:type]:=class(Shape[T]){W:i64}
        \\Size(S:Shape[i64])<transacts>:i64=Case(S,R:Disc[i64]=>R.R,F:Flat[i64]=>F.W,_=>0)
        \\I:=IntBox{Value:=1}
        \\B:Box[i64]=I
        \\C:Container[i64]=I
        \\A:i64=B.Get()+C.Get()
        \\D:i64=Attempt(IntBox[B].Extra,0)
        \\U:Box[i64]=Box[i64][I]
        \\P:=Box[i64]{Value:=5}
        \\N:i64=Attempt(IntBox[P].Extra,-1)
        \\Back:i64=Attempt(Box[i64][C].Value,-1)
        \\Z:Container[i64]=Lazy[i64]{Make:=Fn()<transacts>:i64{7}}
        \\Q:i64=Z.Get()+Z.Twice().Length
        \\Miss:i64=Attempt(Box[i64][Z].Value,-1)
        \\T:i64=Size(Disc[i64]{Tag:=1,R:=5})+Size(Flat[i64]{Tag:=2,W:=7})+Size(Shape[i64]{Tag:=3})
    );
    try std.testing.expectEqual(@as(i64, 22), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Back").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("Q").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Miss").?.integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("T").?.integer);
    const box = instance(x.program, "Box", &.{.i64}).?;
    const container = instance(x.program, "Container", &.{.i64}).?;
    // A supertype is an earlier definition, as for every class.
    try std.testing.expect(@backingInt(container) < @backingInt(box));
    try std.testing.expect(catalogue.subtype(x.get("I").?.object.value_type, box, x.program.definitions));
    try std.testing.expect(catalogue.subtype(box, container, x.program.definitions));
    // A class above which an instantiation stands gets its place in the catalogue after that
    // instantiation, and so does every class below it, through an alias or an interface as
    // well: supertypes come first.
    const y = try h.execute(
        \\Box[T:type]:=class{var Value:T,Get()<transacts>:T=Self.Value}
        \\Has[T:type]:=interface{Tag()<transacts>:T}
        \\Early:=class{Next:option(Early)=option{},Later:option(Plain)=option{}}
        \\Plain:=class{N:i64=1}
        \\Counted:=class(Box[i64]){Step:i64=10}
        \\Special:=class<final>(Counted){Get<override>()<transacts>:i64=Self.Value+Self.Step}
        \\Ints:=Box[i64]
        \\ViaAlias:=class(Ints){}
        \\Tagged:=interface(Has[string]){}
        \\Marked:=class(Plain,Tagged){Tag<override>()<transacts>:string="m"}
        \\Deep:=class(Marked){}
        \\S:Box[i64]=Special{Value:=1}
        \\A:i64=S.Get()+ViaAlias{Value:=5}.Get()
        \\T:Has[string]=Deep{}
        \\B:string=T.Tag()
        \\C:i64=Attempt(Special[S].Step,0)+Attempt(Counted[S].Step,0)
    );
    try std.testing.expectEqual(@as(i64, 16), y.get("A").?.integer);
    try std.testing.expectEqualStrings("m", y.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 20), y.get("C").?.integer);
    for (y.program.definitions, 0..) |item, index| {
        if (item != .class) continue;
        if (item.class.parent) |parent| try std.testing.expect(@backingInt(parent) - catalogue.builtin_count < index);
        for (item.class.implemented()) |interface| try std.testing.expect(@backingInt(interface) - catalogue.builtin_count < index);
    }
    // Like other classes it is known before its declaration; its header may not name itself.
    try expectDiagnostics(h, "Box[T:type]:=class{Value:T}\n", &.{
        .{ .tail = "Counted:=class(Box[i64]){}\nCounted:=class(Box[i64]){}", .code = .duplicate_name },
        .{ .tail = "Counted:=class(Box[i64]){}\nCounted:=class{}", .code = .duplicate_name },
        .{ .tail = "Self2:=class(Box[Self2]){}", .code = .unsupported_type },
    });
    // Instantiations with different arguments are unrelated types, and no cast joins them.
    try expectDiagnostics(h, "Box[T:type]:=class{Value:T}\nA:=Box[i64]{Value:=1}\n", &.{
        .{ .tail = "B:Box[string]=A", .code = .type_mismatch },
        .{ .tail = "B:i64=Attempt(Box[string][A].Value.Length,0)", .code = .type_mismatch },
        .{ .tail = "F(X:Box[string])<transacts>:i64=1\nB:i64=F(A)", .code = .type_mismatch },
    });
}

test "recursion through the same arguments, generic functions and types first named inside a body" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Node[T:type]:=class{
        \\  Value:T
        \\  Next:option(Node[T])=option{}
        \\  Length()<transacts>:i64=1+Attempt(Block{After:=Self.Next?;After.Length()},0)
        \\}
        \\Box[T:type]:=class{
        \\  var Value:T
        \\  Count:i64=7
        \\  Get()<transacts>:T=Self.Value
        \\  Add(N:i64=3)<transacts>:i64=Self.Count+N
        \\}
        \\Sum(N:option(Node[i64]))<transacts>:i64=Attempt(Block{X:=N?;X.Value+Sum(X.Next)},0)
        \\Cons[T:type](Head:T,Tail:option(Node[T]))<transacts>:Node[T]{Node[T]{Value:=Head,Next:=Tail}}
        \\Wrap[T:type](X:T)<transacts>:Box[T]{Box[T]{Value:=X}}
        \\Unwrap[T:type](B:Box[T])<transacts>:T{B.Value}
        \\L:=Cons[i64](1,option{Cons[i64](2,option{Cons[i64](3,option{})})})
        \\A:i64=Sum(option{L})
        \\Len:i64=L.Length()
        \\W:i64=Wrap[i64](4).Get()
        \\S:string=Unwrap[string](Wrap[string]("s"))
        \\F(X:float)<transacts>:float=Block{B:Box[float]=Box[float]{Value:=X};Y:float=B.Get();Y+1.0}
        \\Fl:float=F(1.5)
        \\G()<transacts>:i64=1+Box[char]{Value:='q'}.Add()+Box[logic]{Value:=true,Count:=1}.Add(N:=2)
        \\Gi:i64=G()
        \\Opt()<transacts>:option(i64)=option{Unwrap[i64](Box[i64]{Value:=3})}
        \\O:i64=Attempt(Opt()?,0)
        \\Lo()<transacts>:logic=logic{Box[[]i64]{Value:=array{1}}.Value[3]}
        \\Lg:logic=Lo()
        \\Lam:=Fn()<transacts>:i64{Box[tuple(i64,i64)]{Value:=tuple{1,2}}.Value(1)}
        \\La:i64=Lam()
        \\Mk()<transacts>:[]i64=For(X:array{1,2,3},Box[rational]{Value:=MakeRationalFromInt(X)}.Count+X)
        \\Xs:[]i64=Mk()
    );
    try std.testing.expectEqual(@as(i64, 6), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Len").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("W").?.integer);
    try std.testing.expectEqualStrings("s", x.get("S").?.string);
    try std.testing.expectEqual(@as(f64, 2.5), x.get("Fl").?.floating);
    try std.testing.expectEqual(@as(i64, 14), x.get("Gi").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("O").?.integer);
    try std.testing.expect(!x.get("Lg").?.boolean);
    try std.testing.expectEqual(@as(i64, 2), x.get("La").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.elements(x.get("Xs").?).?[2].integer);
    // Eight argument lists of `Box`, wherever each was first named, and one `Node`.
    try std.testing.expectEqual(@as(usize, 8), instancesOf(x.program, "Box"));
    try std.testing.expectEqual(@as(usize, 1), instancesOf(x.program, "Node"));
    try std.testing.expect(h.front.instantiation_depth == 0 and h.front.staged_fields == 0 and h.front.staged_inherited == 0);
}

test "a type argument must satisfy the constraint of its parameter, and the body may rely on it" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\Animal:=class{Name:string="x",Speak()<transacts>:string="..."}
        \\Dog:=class(Animal){Speak<override>()<transacts>:string="woof"}
        \\Walker:=interface{Legs()<transacts>:i64}
        \\Cat:=class(Animal,Walker){Legs<override>()<transacts>:i64=4}
        \\Pen[T:subtype(Animal)]:=class<unique>{
        \\  In:T
        \\  Hear()<transacts>:string=Self.In.Speak()+Self.In.Name
        \\}
        \\Walk[T:subtype(Walker)]:=struct{Who:T}
        \\Bag[K:comparable]:=class{
        \\  var Items:map(K,i64)=map{}
        \\  Add(X:K)<transacts>:i64=Block{N:i64=Or(Lookup(Self.Items,X),0)+1;set Self.Items=WithIndex[Self.Items,X,N];N}
        \\  Same(X:K,Y:K)<transacts>:logic=X==Y
        \\}
        \\Show[T:subtype(Animal)](X:T)<transacts>:string{X.Name+X.Speak()}
        \\
    ;
    var buffer: [4096]u8 = undefined;
    const x = try h.execute(try std.fmt.bufPrint(&buffer, "{s}{s}", .{
        base,
        \\A:string=Pen[Dog]{In:=Dog{}}.Hear()
        \\B:string=Pen[Animal]{In:=Dog{}}.Hear()
        \\S:=Bag[string]{}
        \\C:tuple(i64,i64,i64)=tuple{S.Add("a"),S.Add("b"),S.Add("a")}
        \\D:logic=Bag[tuple(i64,[]string)]{}.Same(tuple{1,array{"a"}},tuple{1,array{"a"}})
        \\E:string=Show[Dog](Dog{})
        \\L:i64=Walk[Cat]{Who:=Cat{}}.Who.Legs()
        \\K:=Bag[Pen[Dog]]{}
        \\M:i64=K.Add(Pen[Dog]{In:=Dog{}})
    }));
    try std.testing.expectEqualStrings("woofx", x.get("A").?.string);
    try std.testing.expectEqualStrings("woofx", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 2), x.elements(x.get("C").?).?[2].integer);
    try std.testing.expect(x.get("D").?.boolean);
    try std.testing.expectEqualStrings("xwoof", x.get("E").?.string);
    try std.testing.expectEqual(@as(i64, 4), x.get("L").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("M").?.integer);
    // The diagnostic is at the type that names the argument, not inside the template.
    try expectDiagnostics(h, base, &.{
        .{ .tail = "A:=Pen[i64]{In:=1}", .code = .type_argument_bound },
        .{ .tail = "A:option(Pen[Walker])=option{}", .code = .type_argument_bound },
        .{ .tail = "A:option(Walk[Dog])=option{}", .code = .type_argument_bound },
        .{ .tail = "A:=Bag[function(tuple(i64),i64)]{}", .code = .not_comparable },
        .{ .tail = "A:option(Bag[[]function(tuple(),i64)])=option{}", .code = .not_comparable },
        .{ .tail = "A:string=Show[i64](1)", .code = .type_argument_bound },
        .{ .tail = "A:string=Show[Walker](Cat{})", .code = .type_argument_bound },
        .{ .tail = "Bad[T:subtype(i64)]:=class{}", .code = .unsupported_type },
        .{ .tail = "Bad[T:subtype(Missing)]:=class{}", .code = .unsupported_type },
        .{ .tail = "Bad[T:subtype(Animal]:=class{}", .code = .expected_type },
        .{ .tail = "Bad[T:effect]:=class{}", .code = .unsupported_type },
        .{ .tail = "Bad[T:number]:=class{}", .code = .unsupported_type },
    });
    const located = h.front.compile(base ++ "First:i64=1\nA:=Pen[i64]{In:=1}").failed;
    try std.testing.expectEqualStrings("Pen", (base ++ "First:i64=1\nA:=Pen[i64]{In:=1}")[located.span.start..located.span.end]);
    try std.testing.expect(located.span.start > base.len);
}

test "members of parametric types: access, specifiers, interface fields, defaults and the macro forms" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Stack[T:type]:=class<final>{
        \\  var Items<private>:[]T=array{}
        \\  Push(X:T)<transacts>:i64=Block{set Self.Items=Self.Items+array{X};Self.Items.Length}
        \\  Top()<transacts><decides>:T=Self.Items[Self.Items.Length-1]
        \\  Count<public>()<transacts>:i64=Self.Items.Length
        \\  Each(F:function<transacts>(tuple(T),i64))<transacts>:i64=For(X:Self.Items,F(X)).Length
        \\  Find(Limit:i64)<transacts>:i64=Block{For(I->X:Self.Items,If(I>Limit,Return(0-2),false));Attempt(First[I->X:Self.Items,I>0,I],0-1)}
        \\  Kind()<transacts>:string=Case(Self.Items.Length,0=>"none",1=>"one",_=>"many")
        \\  Spin()<transacts>:i64=Block{var N:i64=0;Loop{set N=N+1;If(N>3,Break(),false)};While(N<9,set N=N+1);N}
        \\  Guard()<transacts>:i64=Block{var N:i64=1;Defer{set N=N+1};N}
        \\}
        \\Shape[T:type]:=class<abstract>{
        \\  Id:T
        \\  Area<abstract>()<transacts>:i64
        \\  Describe<final>()<transacts>:i64=Self.Area()+1
        \\  Hidden<protected>()<transacts>:i64=2
        \\}
        \\Sq[T:type]:=class<final><unique>(Shape[T]){
        \\  W:i64
        \\  Area<override>()<transacts>:i64=Self.W*Self.W+Self.Hidden()
        \\}
        \\Named[T:type]:=interface{
        \\  var Label:string="none"
        \\  Key:T
        \\  Show()<transacts>:string=Self.Label
        \\}
        \\Thing[T:type]:=class(Named[T]){
        \\  Key<override>:T
        \\}
        \\Ready[T:type]:=class<concrete>{
        \\  Items:[]T=array{}
        \\  Note:option(T)=option{}
        \\}
        \\(S:Stack[i64]).Sum()<transacts>:i64=S.Each(Fn(X:i64)<transacts>:i64{X})+100
        \\(S:Stack[string]).Sum()<transacts>:i64=S.Count()+200
        \\Run()<transacts>:i64=Block{S:=Stack[i64]{};S.Push(3);S.Push(4);T:=Attempt(S.Top[],0);K:i64=10;T+S.Count()+S.Each(Fn(X:i64)<transacts>:i64{X*K})}
        \\A:i64=Run()
        \\Texts:=Stack[string]{}
        \\B:tuple(i64,i64,string,i64,i64,i64,i64)=tuple{Texts.Push("ab"),Texts.Push("c"),Texts.Kind(),Texts.Find(5),Texts.Find(0),Texts.Spin(),Texts.Guard()}
        \\C:tuple(i64,i64)=tuple{Stack[i64]{}.Sum(),Texts.Sum()}
        \\S:Shape[string]=Sq[string]{Id:="a",W:=3}
        \\D:i64=S.Describe()
        \\N:Named[i64]=Thing[i64]{Key:=4}
        \\Go()<transacts>:string=Block{set N.Label="set";N.Show()}
        \\E:string=Go()
        \\F:i64=N.Key
        \\G:i64=Ready[i64]{}.Items.Length
    );
    try std.testing.expectEqual(@as(i64, 8), x.get("A").?.integer);
    const b = x.elements(x.get("B").?).?;
    try std.testing.expectEqual(@as(i64, 2), b[1].integer);
    try std.testing.expectEqualStrings("many", b[2].string);
    try std.testing.expectEqual(@as(i64, 1), b[3].integer);
    try std.testing.expectEqual(@as(i64, -2), b[4].integer);
    try std.testing.expectEqual(@as(i64, 9), b[5].integer);
    try std.testing.expectEqual(@as(i64, 1), b[6].integer);
    try std.testing.expectEqual(@as(i64, 100), x.elements(x.get("C").?).?[0].integer);
    try std.testing.expectEqual(@as(i64, 202), x.elements(x.get("C").?).?[1].integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("D").?.integer);
    try std.testing.expectEqualStrings("set", x.get("E").?.string);
    try std.testing.expectEqual(@as(i64, 4), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("G").?.integer);
    try expectDiagnostics(h,
        \\Stack[T:type]:=class<final>{
        \\  var Items<private>:[]T=array{}
        \\  Hidden<protected>()<transacts>:i64=1
        \\  Peek(Other:Stack[T])<transacts>:i64=Other.Items.Length
        \\}
        \\Shape[T:type]:=class<abstract>{Id:T,Area<abstract>()<transacts>:i64,Fixed<final>()<transacts>:i64=1}
        \\Open[T:type]:=class{Id:T}
        \\
    , &.{
        .{ .tail = "A:i64=Stack[i64]{}.Items.Length", .code = .inaccessible_member },
        .{ .tail = "A:i64=Stack[i64]{}.Hidden()", .code = .inaccessible_member },
        // Another instantiation is another class: its private members are its own.
        .{ .tail = "Other[T:type]:=class{Look(S:Stack[T])<transacts>:i64=S.Items.Length}\nA:=Other[i64]{}", .code = .inaccessible_member },
        .{ .tail = "A:=Shape[i64]{Id:=1}", .code = .abstract_instance },
        .{ .tail = "Sub:=class(Stack[i64]){}", .code = .invalid_parent },
        .{ .tail = "Sub[T:type]:=class(Stack[T]){}\nA:=Sub[i64]{}", .code = .invalid_parent },
        .{ .tail = "Sub:=class(Shape[i64]){}", .code = .unimplemented_method },
        .{ .tail = "Sub:=class(Shape[i64]){Area<override>()<transacts>:i64=1,Fixed<override>()<transacts>:i64=2}", .code = .final_method },
        .{ .tail = "Sub:=class(Shape[i64]){Area()<transacts>:i64=1}", .code = .missing_override },
        .{ .tail = "Sub:=class(Shape[i64]){Area<override>()<transacts>:string=\"a\"}", .code = .override_mismatch },
        .{ .tail = "Need[T:type]:=class<concrete>{Id:T}\nA:=Need[i64]{}", .code = .missing_field },
        .{ .tail = "A:=Open[i64]{}", .code = .missing_field },
        .{ .tail = "A:=Open[i64]{Id:=\"s\"}", .code = .type_mismatch },
        .{ .tail = "A:=Open[i64]{Id:=1,Other:=2}", .code = .unknown_field },
    });
}

test "a failed region undoes the writes to an instance of a parametric class" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Counter[T:type]:=class{
        \\  var Value:T
        \\  var Hits:i64=0
        \\  Set(New:T)<transacts>:T=Block{set Self.Value=New;set Self.Hits=Self.Hits+1;New}
        \\}
        \\Slot[T:type]:=interface{var Held:option(T)=option{}}
        \\Shelf[T:type]:=class(Slot[T]){}
        \\C:=Counter[string]{Value:="a"}
        \\S:Slot[i64]=Shelf[i64]{}
        \\Try()<transacts>:i64=Attempt(Block{C.Set("b");set S.Held=option{5};Made:=Counter[i64]{Value:=9};Made.Set(10);Require[C.Hits>5];1},0)
        \\A:i64=Try()
        \\B:string=C.Value
        \\H:i64=C.Hits
        \\E:logic=S.Held.IsSet
        \\Keep()<transacts>:i64=Attempt(Block{C.Set("c");set S.Held=option{6};Require[C.Hits==1];1},0)
        \\K:i64=Keep()
        \\V:string=C.Value
        \\W:i64=Attempt(S.Held?,0)
    );
    try std.testing.expectEqual(@as(i64, 0), x.get("A").?.integer);
    try std.testing.expectEqualStrings("a", x.get("B").?.string);
    try std.testing.expectEqual(@as(i64, 0), x.get("H").?.integer);
    try std.testing.expect(!x.get("E").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), x.get("K").?.integer);
    try std.testing.expectEqualStrings("c", x.get("V").?.string);
    try std.testing.expectEqual(@as(i64, 6), x.get("W").?.integer);
}

test "parametric type declarations and uses are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectDiagnostics(h, "Box[T:type]:=class{Value:T}\nPt[T:type]:=struct{X:T}\n", &.{
        .{ .tail = "A:Box=1", .code = .type_arguments_required },
        .{ .tail = "A:=Box{Value:=1}", .code = .type_arguments_required },
        .{ .tail = "A:Box[i64,i64]=1", .code = .argument_count },
        .{ .tail = "A:option(Box[])=option{}", .code = .expected_type },
        .{ .tail = "A:Box[i64]=Box[string]{Value:=\"a\"}", .code = .type_mismatch },
        .{ .tail = "A:=Box[i64](1)", .code = .unexpected_token },
        .{ .tail = "A:i64=Pt[i64][1]", .code = .unknown_name },
        .{ .tail = "A:=Box[Missing]{Value:=1}", .code = .unsupported_type },
        .{ .tail = "Box:=class{}", .code = .duplicate_name },
        .{ .tail = "Box:i64=1", .code = .duplicate_name },
        .{ .tail = "Box(X:i64)<computes>:i64=X", .code = .duplicate_name },
        .{ .tail = "Box[U:type]:=class{}", .code = .duplicate_name },
        .{ .tail = "Box[U:type](X:U)<computes>:U{X}", .code = .duplicate_name },
        .{ .tail = "Two[T:type,T:type]:=class{}", .code = .duplicate_name },
        .{ .tail = "Odd[T:type]:=enum{A}", .code = .unsupported_type },
        // RFC-0083 made `Odd[T:type]:=i64` a parametric alias; one of no type is still refused.
        .{ .tail = "Odd[T:type]:=Missing", .code = .unsupported_type },
        .{ .tail = "Odd[T:type]:=class{", .code = .unexpected_token },
        .{ .tail = "Odd[T:type]:=class{X:T)}", .code = .unmatched_parenthesis },
        .{ .tail = "Odd[T:type]:=class{X:T} extra", .code = .unexpected_token },
        .{ .tail = "char[T:type]:=class{X:T}", .code = .expected_name },
        // A supertype is complete before its subtype, also when both are instantiations.
        .{ .tail = "Bad[T:type]:=class(Bad[T]){}\nA:option(Bad[i64])=option{}", .code = .invalid_parent },
        // Nor does a parametric type inherit from one of its parameters (the Book, 10:1660).
        .{ .tail = "Open:=class{}\nMix[T:type]:=class(T){}\nA:option(Mix[Open])=option{}", .code = .invalid_parent },
        // An exchange of arguments is finite: two types, each naming the other.
        .{ .tail = "Bi[A:type,B:type]:=class{V:A,Next:option(Bi[B,A])=option{}}\nX:=Bi[i64,string]{V:=1,Next:=option{Bi[string,i64]{V:=\"s\"}}}\nY:i64=Missing", .code = .unknown_name },
        .{ .tail = "Rec[T:type]:=struct{Inner:option(Rec[T])}\nA:option(Rec[i64])=option{}", .code = .unsupported_type },
        // Recursion keeps its arguments (the Book allows no other): a growing one never ends.
        .{ .tail = "Grow[T:type]:=class{Inner:option(Grow[Grow[T]])=option{}}\nA:option(Grow[i64])=option{}", .code = .instantiation_limit },
        .{ .tail = "Grow[T:type]:=class{Next()<transacts>:i64=Grow[[]T]{}.Next()}\nA:=Grow[i64]{}", .code = .instantiation_limit },
        // The body is checked for each argument list, where the template is written.
        .{ .tail = "Num[T:type]:=class{V:T,Inc()<transacts>:T=Self.V+1}\nA:=Num[i64]{V:=1}\nB:=Num[logic]{V:=true}", .code = .type_mismatch },
        .{ .tail = "Use[T:type]:=class{V:T,M()<transacts>:i64=Missing}\nA:=Use[i64]{V:=1}", .code = .unknown_name },
        // A generic method (RFC-0081) has its body in braces, as a generic function has.
        .{ .tail = "Gen[T:type]:=class{Map[U:type](X:U)<transacts>:U=X}\nA:=Gen[i64]{}", .code = .generic_method_slot },
    });
    // A template nobody names is only checked for balance, like a generic function body.
    const dormant = try h.compile("Dormant[T:type]:=class{V:T,M()<transacts>:i64=Missing}\nA:i64=1");
    try std.testing.expectEqual(@as(usize, 0), dormant.definitions.len);
    try std.testing.expectEqual(@as(usize, 0), dormant.functions.len);
    // A parameter named like a template that is declared after it is untouched by the name.
    // RFC-0076: after the template it is a shadow (the first case below), so `F` leads here.
    try expectDiagnostics(h, "Box[T:type]:=class{Value:T}\n", &.{
        .{ .tail = "F(Box:i64)<computes>:i64=Box+1", .code = .shadowed_name },
        .{ .tail = "G()<transacts>:i64=Block{Box:i64=1;Box}", .code = .shadowed_name },
    });
    const x = try h.execute("F(Box:i64)<computes>:i64=Box+1\nA:i64=F(1)\nBox[T:type]:=class{Value:T}\nG()<transacts>:i64=Block{B:=Box[i64]{Value:=2};B.Value}\nC:i64=G()");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("C").?.integer);
}

test "nesting to the capacity is compiled and one level more is a diagnostic" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [8192]u8 = undefined;
    for ([_]usize{ types.limits.instantiation_depth, types.limits.instantiation_depth + 1 }) |levels| {
        var out = std.Io.Writer.fixed(&buffer);
        // `L0[T]` is first named at the top; each `Lk[T]` is first named in a method body of the one before.
        for (0..levels) |level| {
            if (level + 1 == levels) try out.print("L{d}[T:type]:=class{{V:T,Depth()<transacts>:i64=1}}\n", .{level}) else try out.print("L{d}[T:type]:=class{{V:T,Depth()<transacts>:i64=1+L{d}[T]{{V:=Self.V}}.Depth()}}\n", .{ level, level + 1 });
        }
        try out.writeAll("A:i64=L0[i64]{V:=1}.Depth()");
        const result = h.front.compile(out.buffered());
        if (levels == types.limits.instantiation_depth) {
            const x = try h.run(result.ok, 100_000);
            try std.testing.expectEqual(@as(i64, @intCast(levels)), x.ok.get("A").?.integer);
        } else try std.testing.expectEqual(types.Diagnostic.Code.instantiation_limit, result.failed.code);
    }
}

test "instantiations fill the catalogue to its last definition and the next one is a diagnostic" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [32768]u8 = undefined;
    // `Tag[i64]`, `Tag[[]i64]`, `Tag[[][]i64]`, ...: each use adds an array, a key and a type.
    for ([_]usize{ 85, 86 }) |uses| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Z:[]string=array{}\nTag[T:type]:=struct{V:option(i64)=option{}}\n");
        for (0..uses) |use| {
            try out.print("A{d}:Tag[", .{use});
            for (0..use) |_| try out.writeAll("[]");
            try out.print("i64]=Tag[", .{});
            for (0..use) |_| try out.writeAll("[]");
            try out.writeAll("i64]{}\n");
        }
        const result = h.front.compile(out.buffered());
        if (uses == 85) {
            // `[]string` and `option(i64)`, then 85 keys, 85 structs and 84 arrays: every definition there is.
            try std.testing.expectEqual(@as(usize, types.limits.user_types), result.ok.definitions.len);
            try std.testing.expectEqual(@as(usize, 85), instancesOf(result.ok, "Tag"));
            _ = try h.run(result.ok, 100_000);
        } else try std.testing.expectEqual(types.Diagnostic.Code.type_limit, result.failed.code);
    }
}

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8, other: []const u8) @import("compiler.zig").BundleResult {
    var inputs: [3]modules.Input = undefined;
    inputs[0] = .{ .path = "main.forb", .source = main };
    inputs[1] = .{ .path = "lib.forb", .source = lib };
    inputs[2] = .{ .path = "other.forb", .source = other };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = inputs[0..if (other.len == 0) 2 else 3] });
}

test "an instantiation is one type across the modules of a bundle" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Box<public>[T:type]:=class<unique>{\n  var Value<public>:T\n  Get<public>()<transacts>:T=Self.Value\n}\nPt<public>[T:type]:=struct{X:T}\nTwice<public>(B:Box[i64])<transacts>:i64=B.Value*2\nIntBox<public>:=class<unique>(Box[i64]){}";
    // A class of another module below one that is declared late there is declared late too.
    const below = "L:=import{\"lib.forb\"}\nusing{L}\nSmall:=class<unique>(L.IntBox){}\nTiny:=class<unique>(IntBox){}\nV<public>:i64=Small{Value:=3}.Get()+Tiny{Value:=4}.Get()";
    const chained = bundle(h, below, lib, "");
    if (chained == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ chained.failed.diagnostic.message(), chained.failed.path });
    try std.testing.expectEqual(@as(i64, 7), (try h.run(chained.ok, 100_000)).ok.get("V").?.integer);
    const other = "L:=import{\"lib.forb\"}\nusing{L}\nMake<public>(N:i64)<transacts>:Box[i64]=Box[i64]{Value:=N}\nSame<public>(X:Box[i64],Y:L.Box[i64])<transacts>:logic=X==Y\nAt<public>:Pt[i64]=Pt[i64]{X:=3}";
    const main = "L:=import{\"lib.forb\"}\nO:=import{\"other.forb\"}\nA<public>:L.Box[i64]=L.Box[i64]{Value:=1}\nB<public>:L.Box[i64]=O.Make(2)\nSame<public>:logic=O.Same(A,A)\nC<public>:i64=A.Get()+B.Get()+L.Twice(A)\nD<public>:logic=O.At==L.Pt[i64]{X:=3}\nMine:=class{N:i64=4}\nP:L.Box[Mine]=L.Box[Mine]{Value:=Mine{}}\nGo()<transacts>:i64=P.Value.N+P.Get().N-4\nE<public>:i64=Go()\nF<public>:L.Box[i64]=L.IntBox{Value:=6}";
    const bundled = bundle(h, main, lib, other);
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const x = (try h.run(bundled.ok, 100_000)).ok;
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expect(x.get("D").?.boolean);
    try std.testing.expectEqual(@as(i64, 4), x.get("E").?.integer);
    // Three modules name `Box[i64]`; it is the template's module's type, defined once.
    try std.testing.expectEqual(@as(usize, 2), instancesOf(x.program, "Box"));
    try std.testing.expectEqual(@as(usize, 1), instancesOf(x.program, "Pt"));
    try std.testing.expectEqual(x.get("A").?.object.value_type, x.get("B").?.object.value_type);
    const box = catalogue.definition(x.get("A").?.object.value_type, x.program.definitions).?.class;
    try std.testing.expectEqualStrings("lib.forb", x.program.modules[modules.owner(box.name, x.program.modules).?].path.text(x.program.paths));
    const refused = [_]struct { main: []const u8, lib: []const u8, code: types.Diagnostic.Code, path: []const u8 }{
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1\nB:L.Hidden[i64]=L.Hidden[i64]{V:=1}", .lib = "Hidden[T:type]:=class{V:T}", .code = .private_name, .path = "main.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=1\nB:option(Hidden[i64])=option{}", .lib = "Hidden[T:type]:=class{V:T}", .code = .unsupported_type, .path = "main.forb" },
        // What a public template names is public, whatever it is instantiated for.
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1", .lib = "Secret:=class{}\nBox<public>[T:type]:=class{\n  V:T\n  S:option(Secret)=option{}\n}", .code = .private_type_escape, .path = "lib.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1", .lib = "Inner[T:type]:=class{V:T}\nBox<public>[T:type]:=class{\n  V:T\n  Make()<transacts>:Inner[T]=Inner[T]{V:=Self.V}\n}", .code = .private_type_escape, .path = "lib.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1", .lib = "Secret:=class{}\nBox<public>[T:type]:=class(Base[Secret]){\n  V:T\n}\nBase<public>[T:type]:=class{}", .code = .private_type_escape, .path = "lib.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1", .lib = "Secret:=class{}\nPt<public>[T:type]:=struct{V:T,S:[]Secret=array{}}", .code = .private_type_escape, .path = "lib.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nA<public>:i64=1", .lib = "Secret:=class{}\nBox<public>[T:type]:=class{V:T}\nWrap<public>[T:type](X:T)<transacts>:Box[Secret]{Box[Secret]{V:=Secret{}}}", .code = .private_type_escape, .path = "lib.forb" },
        // An instantiation for a private type is private to the module that can name that type.
        .{ .main = "L:=import{\"lib.forb\"}\nMine:=class{}\nA<public>:L.Box[Mine]=L.Box[Mine]{V:=Mine{}}", .lib = "Box<public>[T:type]:=class{\n  V<public>:T\n}", .code = .private_type_escape, .path = "main.forb" },
        .{ .main = "L:=import{\"lib.forb\"}\nMine:=class{}\nF<public>(X:L.Pt[Mine])<computes>:i64=1", .lib = "Pt<public>[T:type]:=struct{V:T}", .code = .private_type_escape, .path = "main.forb" },
    };
    for (refused) |entry| {
        const result = bundle(h, entry.main, entry.lib, "");
        if (result == .ok or result.failed.diagnostic.code != entry.code or !std.mem.eql(u8, result.failed.path, entry.path)) {
            std.debug.print("bundle {s} / {s}: expected {s}, got {s}\n", .{ entry.main, entry.lib, @tagName(entry.code), if (result == .ok) "success" else @tagName(result.failed.diagnostic.code) });
            return error.WrongDiagnostic;
        }
    }
}

test "reports and inspection name an instantiation by its template and arguments" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Box[T:type]:=class{var Value:T}\nPt[A:type,B:type]:=struct{X:A,Y:B}\nI:=Box[i64]{Value:=1}\nS:=Box[Pt[i64,string]]{Value:=Pt[i64,string]{X:=2,Y:=\"y\"}}\nP:=class{}\nQ:=P{}");
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const point = instance(x.program, "Pt", &.{ .i64, .string }).?;
    var expected: [512]u8 = undefined;
    // A plain class keeps its report; an instantiation adds the type IDs of its arguments.
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"I\":{{\"$object\":0}},\"S\":{{\"$object\":2}},\"Q\":{{\"$object\":4}},\"$objects\":[{{\"id\":0,\"class\":\"Box\",\"arguments\":[0],\"fields\":{{\"Value\":1}}}},{{\"id\":2,\"class\":\"Box\",\"arguments\":[{d}],\"fields\":{{\"Value\":{{\"X\":2,\"Y\":\"y\"}}}}}},{{\"id\":4,\"class\":\"P\",\"fields\":{{}}}}]}}\n", .{@backingInt(point)}), out.buffered());
    const document = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(document);
    var writer = std.Io.Writer.fixed(document);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    try std.testing.expect(try workspace.write(&writer, x.program) == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    var seen: usize = 0;
    for (parsed.value.object.get("type_definitions").?.array.items) |item| {
        const name = item.object.get("name") orelse continue;
        const arguments = item.object.get("arguments");
        if (std.mem.eql(u8, name.string, "P")) try std.testing.expect(arguments == null);
        if (std.mem.eql(u8, name.string, "Pt")) {
            try std.testing.expectEqualStrings("record", item.object.get("kind").?.string);
            try std.testing.expectEqualStrings("i64", arguments.?.array.items[0].string);
            try std.testing.expectEqualStrings("string", arguments.?.array.items[1].string);
            seen += 1;
        }
        if (std.mem.eql(u8, name.string, "Box")) {
            try std.testing.expectEqual(@as(usize, 1), arguments.?.array.items.len);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

const Forge = struct {
    definitions: []types.Definition,
    tuple_elements: []types.Type,
    fields: []types.Field,
    program: types.Program,

    fn init(p: types.Program) !Forge {
        return .{
            .definitions = try std.testing.allocator.dupe(types.Definition, p.definitions),
            .tuple_elements = try std.testing.allocator.dupe(types.Type, p.tuple_elements),
            .fields = try std.testing.allocator.dupe(types.Field, p.fields),
            .program = p,
        };
    }
    fn deinit(self: *Forge) void {
        std.testing.allocator.free(self.definitions);
        std.testing.allocator.free(self.tuple_elements);
        std.testing.allocator.free(self.fields);
    }
    fn view(self: *const Forge) types.Program {
        var forged = self.program;
        forged.definitions = self.definitions;
        forged.tuple_elements = self.tuple_elements;
        forged.fields = self.fields;
        return forged;
    }
    fn reset(self: *Forge) void {
        @memcpy(self.definitions, self.program.definitions);
        @memcpy(self.tuple_elements, self.program.tuple_elements);
        @memcpy(self.fields, self.program.fields);
    }
    fn at(self: *Forge, value: types.Type) *types.Definition {
        return &self.definitions[@backingInt(value) - catalogue.builtin_count];
    }
};

/// Every argument list is interned before the first class, so a forged origin can name any of them.
const forge_source =
    \\Id(N:i64)<computes>:i64=N+0
    \\Keys:tuple(tuple(i64),tuple(string),tuple(i64,string),tuple(function(tuple(i64),i64)))=tuple{tuple{1},tuple{"s"},tuple{1,"s"},tuple{Id}}
    \\Box<public>[T:type]:=class{
    \\  var Value:T
    \\  Get()<transacts>:T=Self.Value
    \\}
    \\Face[T:type]:=interface{Show()<transacts>:i64}
    \\Pair[A:type,B:type]:=class{First:A,Second:B}
    \\Bag[K:comparable]:=class{Items:map(K,i64)=map{}}
    \\Pt[T:type]:=struct{X:T}
    \\Plain:=class{N:i64=0}
    \\A:=Box[i64]{Value:=1}
    \\B:=Box[string]{Value:="s"}
    \\C:=Pair[i64,string]{First:=1,Second:="s"}
    \\D:=Bag[i64]{}
    \\P:=Pt[i64]{X:=1}
    \\Q:=Plain{}
    \\F:option(Face[i64])=option{}
    \\X:i64=A.Get()
;

test "the unmodified parametric program is admitted" {
    const h = try harness.create();
    defer scratch.release(h);
    var forge = try Forge.init(try h.compile(forge_source));
    defer forge.deinit();
    const x = try h.run(forge.view(), 10_000);
    try std.testing.expectEqual(@as(i64, 1), x.ok.get("X").?.integer);
}

test "forged origins of instantiations are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forge_source);
    var forge = try Forge.init(p);
    defer forge.deinit();
    const ints = instance(p, "Box", &.{.i64}).?;
    const texts = instance(p, "Box", &.{.string}).?;
    const pair = instance(p, "Pair", &.{ .i64, .string }).?;
    const bag = instance(p, "Bag", &.{.i64}).?;
    const point = instance(p, "Pt", &.{.i64}).?;
    const face = instance(p, "Face", &.{.i64}).?;
    const plain = p.bindings[6].value_type;
    try std.testing.expectEqualStrings("Q", p.bindings[6].name.text(p.source));
    const one = forge.at(ints).class.arguments.?;
    const two = forge.at(pair).class.arguments.?;
    const keys = catalogue.definition(p.bindings[0].value_type, p.definitions).?.tuple;
    const callable = p.tuple_elements[keys.start + 3];
    // The keys precede the classes, which is what lets the origins below be exchanged.
    try std.testing.expect(@backingInt(two) < @backingInt(ints) and @backingInt(callable) < @backingInt(ints));

    // Two definitions claim `Box[i64]`.
    forge.at(texts).class.arguments = one;
    try harness.invalid(h, forge.view());
    forge.reset();
    // So do two structs, and a class and a struct of one name.
    forge.at(point).record.name = forge.at(ints).class.name;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A definition claims the template's name without arguments, beside its instantiations or alone.
    forge.at(ints).class.arguments = null;
    try harness.invalid(h, forge.view());
    forge.at(texts).class.arguments = null;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(point).record.arguments = null;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A class that is not declared as a template claims arguments.
    forge.at(plain).class.arguments = one;
    try harness.invalid(h, forge.view());
    forge.reset();
    // The arguments are not a tuple, are empty, or are more or fewer than the parameters.
    forge.at(ints).class.arguments = .i64;
    try harness.invalid(h, forge.view());
    forge.at(ints).class.arguments = texts;
    try harness.invalid(h, forge.view());
    forge.at(ints).class.arguments = @fromBackingInt(@intCast(p.definitions.len + catalogue.builtin_count));
    try harness.invalid(h, forge.view());
    forge.at(ints).class.arguments = two;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(pair).class.arguments = one;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A cyclic origin: the arguments are a later definition, or a list that holds the type itself.
    const later = for (p.definitions, 0..) |item, index| {
        if (item == .tuple and index > @backingInt(point) - catalogue.builtin_count) break index;
    } else null;
    if (later) |index| {
        forge.at(point).record.arguments = @fromBackingInt(@intCast(index + catalogue.builtin_count));
        try harness.invalid(h, forge.view());
        forge.reset();
    }
    forge.at(ints).class.arguments = ints;
    try harness.invalid(h, forge.view());
    forge.reset();
    const list = catalogue.definition(one, p.definitions).?.tuple;
    forge.tuple_elements[list.start] = ints;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A `comparable` parameter is given a type without an equality.
    forge.at(bag).class.arguments = callable;
    try harness.invalid(h, forge.view());
    forge.reset();
    // The kind of the template, its publicity and its place in the source.
    forge.at(face).class.is_interface = false;
    forge.at(face).class.is_abstract = false;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(point).record.name = forge.at(pair).class.name;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(ints).class.is_public = false;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(bag).class.is_public = true;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(ints).class.name = forge.at(plain).class.name;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.at(ints).class.name = forge.fields[forge.at(ints).class.fields.start].name;
    try harness.invalid(h, forge.view());
    forge.reset();
    _ = try h.run(forge.view(), 10_000);
}

test "an instantiation whose fields are not its template's is still a sound class" {
    const h = try harness.create();
    defer scratch.release(h);
    // Admission has the source text but not the compiler: it cannot tell what a template's body
    // gives for an argument list. It guarantees that a name with arguments is one definition
    // and that the definition is a well-formed class. Exchanging the origins of two
    // instantiations therefore passes, and changes nothing but the name each is reported under:
    // every operation is checked against the definition itself, in both machines alike.
    const p = try h.compile(forge_source);
    var forge = try Forge.init(p);
    defer forge.deinit();
    const ints = instance(p, "Box", &.{.i64}).?;
    const texts = instance(p, "Box", &.{.string}).?;
    const one = forge.at(ints).class.arguments.?;
    forge.at(ints).class.arguments = forge.at(texts).class.arguments;
    forge.at(texts).class.arguments = one;
    const x = (try h.run(forge.view(), 10_000)).ok;
    try std.testing.expectEqual(@as(i64, 1), x.get("X").?.integer);
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    // The instance that holds an integer is now reported as `Box[string]`.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"id\":0,\"class\":\"Box\",\"arguments\":[2],\"fields\":{\"Value\":1}}") != null);
    // What a forged definition cannot do is make an operation ill-typed: a field of another type is rejected.
    forge.reset();
    forge.fields[forge.at(ints).class.fields.start].value_type = .string;
    try harness.invalid(h, forge.view());
}

test "forged origins in a bundle: the template's module owns the name" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Box<public>[T:type]:=class{\n  Value<public>:T\n}\nOwn[T:type]:=class{\n  Value:T\n}\nA<public>:Box[i64]=Box[i64]{Value:=1}\nB:Own[i64]=Own[i64]{Value:=1}";
    const main = "L:=import{\"lib.forb\"}\nBox[T:type]:=class{\n  Value:T\n}\nC<public>:i64=L.A.Value\nD:Box[i64]=Box[i64]{Value:=2}";
    const p = bundle(h, main, lib, "").ok;
    var forge = try Forge.init(p);
    defer forge.deinit();
    // Each module has its own `Box[i64]`: the same name and arguments in two namespaces.
    try std.testing.expectEqual(@as(usize, 2), instancesOf(p, "Box"));
    _ = try h.run(forge.view(), 10_000);
    var boxes: [2]usize = undefined;
    var found: usize = 0;
    var own: usize = 0;
    for (p.definitions, 0..) |item, index| {
        if (item != .class or item.class.arguments == null) continue;
        if (std.mem.eql(u8, item.class.name.text(p.source), "Box")) {
            boxes[found] = index;
            found += 1;
        } else own = index;
    }
    // One module's instantiation moved into the other's namespace: two claims of one type there.
    forge.definitions[boxes[1]].class.name = forge.definitions[boxes[0]].class.name;
    forge.definitions[boxes[1]].class.is_public = forge.definitions[boxes[0]].class.is_public;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A private template's instantiation claims to be public.
    forge.definitions[own].class.is_public = true;
    try harness.invalid(h, forge.view());
    forge.reset();
    _ = try h.run(forge.view(), 10_000);
}

/// A model of parametric classes that knows nothing of the compiler: types are hash-consed
/// trees, a template is a list of fields over its parameters with an optional superclass, and
/// instantiating is substitution.
const Model = struct {
    const max_nodes = 512;
    const max_templates = 6;
    const max_fields = 3;
    const max_parameters = 2;
    const Node = union(enum) {
        scalar: u8,
        parameter: u8,
        array: u16,
        option: u16,
        instance: struct { template: u8, arguments: [max_parameters]u16, count: u8 },
    };
    const Template = struct {
        parameters: u8,
        parent: ?u16 = null,
        fields: [max_fields]u16 = undefined,
        field_count: u8 = 0,
        /// Whether the template declares `Tag` itself: always without a parent, an override with one.
        declares: bool = true,
        tag: i64 = 0,
    };
    // In the order of their type IDs.
    const scalars = [_][]const u8{ "i64", "logic", "string", "float" };
    const literals = [_][]const u8{ "1", "true", "\"s\"", "1.5" };

    nodes: [max_nodes]Node = undefined,
    node_count: u16 = 0,
    templates: [max_templates]Template = undefined,
    template_count: u8 = 0,
    /// Ground instances that exist once the uses are compiled.
    made: [max_nodes]bool = @splat(false),

    fn intern(self: *Model, node: Node) !u16 {
        for (self.nodes[0..self.node_count], 0..) |existing, index| if (std.meta.eql(existing, node)) return @intCast(index);
        if (self.node_count == max_nodes) return error.ModelFull;
        self.nodes[self.node_count] = node;
        self.node_count += 1;
        return self.node_count - 1;
    }

    fn substitute(self: *Model, node: u16, arguments: []const u16) !u16 {
        return switch (self.nodes[node]) {
            .scalar => node,
            .parameter => |index| arguments[index],
            .array => |element| self.intern(.{ .array = try self.substitute(element, arguments) }),
            .option => |element| self.intern(.{ .option = try self.substitute(element, arguments) }),
            .instance => |item| made: {
                var result = item;
                for (item.arguments[0..item.count], result.arguments[0..item.count]) |argument, *target| target.* = try self.substitute(argument, arguments);
                break :made self.intern(.{ .instance = result });
            },
        };
    }

    /// Naming a ground instance makes it, its superclass and every instance its fields name.
    fn make(self: *Model, node: u16) !void {
        switch (self.nodes[node]) {
            .scalar, .parameter => {},
            .array, .option => |element| try self.make(element),
            .instance => |item| {
                for (item.arguments[0..item.count]) |argument| try self.make(argument);
                if (self.made[node]) return;
                self.made[node] = true;
                const template = self.templates[item.template];
                if (template.parent) |parent| try self.make(try self.substitute(parent, item.arguments[0..item.count]));
                for (template.fields[0..template.field_count]) |field| try self.make(try self.substitute(field, item.arguments[0..item.count]));
            },
        }
    }

    const Field = struct { template: u8, ordinal: u8, value_type: u16 };

    /// The fields of a ground instance: its superclass's first, then its own.
    fn layout(self: *Model, node: u16, out: *[max_templates * max_fields]Field) !usize {
        const item = self.nodes[node].instance;
        const template = self.templates[item.template];
        var count: usize = 0;
        if (template.parent) |parent| count = try self.layout(try self.substitute(parent, item.arguments[0..item.count]), out);
        for (template.fields[0..template.field_count], 0..) |field, ordinal| {
            out[count] = .{ .template = item.template, .ordinal = @intCast(ordinal), .value_type = try self.substitute(field, item.arguments[0..item.count]) };
            count += 1;
        }
        return count;
    }

    /// What `Tag()` returns for an instance: the nearest declaration up its superclasses.
    fn tag(self: *Model, node: u16) !i64 {
        const item = self.nodes[node].instance;
        const template = self.templates[item.template];
        if (template.declares) return template.tag;
        return self.tag(try self.substitute(template.parent.?, item.arguments[0..item.count]));
    }

    fn root(self: *Model, node: u16) !u16 {
        const item = self.nodes[node].instance;
        const parent = self.templates[item.template].parent orelse return node;
        return self.root(try self.substitute(parent, item.arguments[0..item.count]));
    }

    fn writeType(self: *const Model, out: *std.Io.Writer, node: u16) !void {
        switch (self.nodes[node]) {
            .scalar => |index| try out.writeAll(scalars[index]),
            .parameter => |index| try out.print("P{d}", .{index}),
            .array => |element| {
                try out.writeAll("[]");
                try self.writeType(out, element);
            },
            .option => |element| {
                try out.writeAll("option(");
                try self.writeType(out, element);
                try out.writeByte(')');
            },
            .instance => |item| {
                try out.print("T{d}[", .{item.template});
                for (item.arguments[0..item.count], 0..) |argument, index| {
                    if (index != 0) try out.writeByte(',');
                    try self.writeType(out, argument);
                }
                try out.writeByte(']');
            },
        }
    }

    fn writeValue(self: *Model, out: *std.Io.Writer, node: u16) !void {
        switch (self.nodes[node]) {
            .scalar => |index| try out.writeAll(literals[index]),
            .parameter => unreachable,
            .array => try out.writeAll("array{}"),
            .option => try out.writeAll("option{}"),
            .instance => {
                var fields: [max_templates * max_fields]Field = undefined;
                const count = try self.layout(node, &fields);
                try self.writeType(out, node);
                try out.writeByte('{');
                for (fields[0..count], 0..) |field, index| {
                    if (index != 0) try out.writeByte(',');
                    try out.print("F{d}_{d}:=", .{ field.template, field.ordinal });
                    try self.writeValue(out, field.value_type);
                }
                try out.writeByte('}');
            },
        }
    }

    /// The catalogue type a ground model type must have been compiled to, if it exists.
    fn resolve(self: *const Model, p: types.Program, node: u16) ?types.Type {
        switch (self.nodes[node]) {
            .scalar => |index| return @fromBackingInt(index),
            .parameter => unreachable,
            .array, .option => |element| {
                const inner = self.resolve(p, element) orelse return null;
                for (p.definitions, 0..) |item, index| {
                    const found = switch (self.nodes[node]) {
                        .array => item == .array and item.array == inner,
                        else => item == .option and item.option == inner,
                    };
                    if (found) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
                }
                return null;
            },
            .instance => |item| {
                var arguments: [max_parameters]types.Type = undefined;
                for (item.arguments[0..item.count], arguments[0..item.count]) |argument, *target| target.* = self.resolve(p, argument) orelse return null;
                var name: [8]u8 = undefined;
                return instance(p, std.fmt.bufPrint(&name, "T{d}", .{item.template}) catch unreachable, arguments[0..item.count]);
            },
        }
    }
};

test "generated templates and argument lists give the layouts and dispatch a model predicts" {
    const h = try harness.create();
    defer scratch.release(h);
    const model = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(model);
    const text = try std.testing.allocator.alloc(u8, 48 * 1024);
    defer std.testing.allocator.free(text);
    var compiled: usize = 0;
    var checked_instances: usize = 0;
    var seed: u64 = 0;
    while (seed < 60) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(0x73_0073 + seed);
        const random = prng.random();
        model.* = .{};
        var out = std.Io.Writer.fixed(text);
        for (Model.scalars, 0..) |_, index| _ = try model.intern(.{ .scalar = @intCast(index) });
        model.template_count = random.intRangeAtMost(u8, 2, Model.max_templates);
        for (0..model.template_count) |t| {
            var template: Model.Template = .{ .parameters = random.intRangeAtMost(u8, 1, Model.max_parameters), .tag = random.intRangeAtMost(i64, 1, 999) };
            var own: [Model.max_parameters]u16 = undefined;
            for (own[0..template.parameters], 0..) |*parameter, index| parameter.* = try model.intern(.{ .parameter = @intCast(index) });
            // A type over this template's parameters: a parameter, a scalar, an earlier template
            // or this one for its own parameters, the last only behind an option.
            const pick = struct {
                fn leaf(m: *Model, r: std.Random, parameters: []const u16) u16 {
                    _ = m;
                    return if (r.boolean()) parameters[r.uintLessThan(usize, parameters.len)] else r.uintLessThan(u16, Model.scalars.len);
                }
                fn earlier(m: *Model, r: std.Random, parameters: []const u16, below: usize) !u16 {
                    const target: u8 = @intCast(r.uintLessThan(usize, below));
                    var item: @FieldType(Model.Node, "instance") = .{ .template = target, .arguments = undefined, .count = m.templates[target].parameters };
                    for (item.arguments[0..item.count]) |*argument| argument.* = leaf(m, r, parameters);
                    return m.intern(.{ .instance = item });
                }
            };
            if (t != 0 and random.uintLessThan(u8, 3) != 0) {
                template.parent = try pick.earlier(model, random, own[0..template.parameters], t);
                template.declares = random.boolean();
            }
            template.field_count = random.intRangeAtMost(u8, 0, Model.max_fields);
            for (template.fields[0..template.field_count]) |*field| {
                field.* = switch (random.uintLessThan(u8, 6)) {
                    0, 1 => pick.leaf(model, random, own[0..template.parameters]),
                    2 => try model.intern(.{ .array = pick.leaf(model, random, own[0..template.parameters]) }),
                    3 => if (t == 0) pick.leaf(model, random, own[0..template.parameters]) else try pick.earlier(model, random, own[0..template.parameters], t),
                    4 => if (t == 0) pick.leaf(model, random, own[0..template.parameters]) else try model.intern(.{ .array = try pick.earlier(model, random, own[0..template.parameters], t) }),
                    else => self: {
                        var item: @FieldType(Model.Node, "instance") = .{ .template = @intCast(t), .arguments = undefined, .count = template.parameters };
                        @memcpy(item.arguments[0..item.count], own[0..template.parameters]);
                        break :self try model.intern(.{ .option = try model.intern(.{ .instance = item }) });
                    },
                };
            }
            model.templates[t] = template;
            try out.print("T{d}[", .{t});
            for (0..template.parameters) |index| try out.print("{s}P{d}:type", .{ if (index == 0) "" else ",", index });
            try out.writeAll("]:=class");
            if (template.parent) |parent| {
                try out.writeByte('(');
                try model.writeType(&out, parent);
                try out.writeByte(')');
            }
            try out.writeAll("{\n");
            for (template.fields[0..template.field_count], 0..) |field, ordinal| {
                try out.print("  F{d}_{d}:", .{ t, ordinal });
                try model.writeType(&out, field);
                try out.writeByte('\n');
            }
            if (template.declares) try out.print("  Tag{s}()<transacts>:i64={d}\n", .{ if (template.parent == null) "" else "<override>", template.tag });
            try out.writeAll("}\n");
        }
        const uses = random.intRangeAtMost(usize, 1, 5);
        var used: [5]u16 = undefined;
        for (used[0..uses], 0..) |*use, index| {
            const target = random.uintLessThan(u8, model.template_count);
            var item: @FieldType(Model.Node, "instance") = .{ .template = target, .arguments = undefined, .count = model.templates[target].parameters };
            for (item.arguments[0..item.count]) |*argument| {
                const scalar = random.uintLessThan(u16, Model.scalars.len);
                argument.* = switch (random.uintLessThan(u8, 4)) {
                    0 => try model.intern(.{ .array = scalar }),
                    1 => try model.intern(.{ .option = scalar }),
                    else => scalar,
                };
            }
            use.* = try model.intern(.{ .instance = item });
            try model.make(use.*);
            try out.print("U{d}()<transacts>:i64=Block{{X:=", .{index});
            try model.writeValue(&out, use.*);
            try out.writeAll(";B:");
            try model.writeType(&out, try model.root(use.*));
            try out.print("=X;B.Tag()}}\nR{d}:i64=U{d}()\n", .{ index, index });
        }
        const result = h.front.compile(out.buffered());
        if (result == .failed) {
            // A generated program may outgrow a bootstrap capacity; nothing else may refuse it.
            const code = result.failed.code;
            if (code != .function_limit and code != .method_limit and code != .type_limit and code != .field_limit and code != .tuple_limit) {
                std.debug.print("seed {d}: {s} at {d}\n{s}\n", .{ seed, @tagName(code), result.failed.span.start, out.buffered() });
                return error.UnexpectedDiagnostic;
            }
            continue;
        }
        compiled += 1;
        const p = result.ok;
        const x = (try h.run(p, 1 << 20)).ok;
        for (used[0..uses], 0..) |use, index| {
            var name: [8]u8 = undefined;
            try std.testing.expectEqual(try model.tag(use), x.get(try std.fmt.bufPrint(&name, "R{d}", .{index})).?.integer);
        }
        // Exactly the instances the model made exist, each once, each with the model's fields.
        var expected: usize = 0;
        for (model.made[0..model.node_count], 0..) |made, node| {
            if (!made) continue;
            expected += 1;
            const class = model.resolve(p, @intCast(node)) orelse {
                std.debug.print("seed {d}: an instance the model made is missing\n{s}\n", .{ seed, out.buffered() });
                return error.MissingInstance;
            };
            var fields: [Model.max_templates * Model.max_fields]Model.Field = undefined;
            const count = try model.layout(@intCast(node), &fields);
            const shape = catalogue.definition(class, p.definitions).?.class;
            try std.testing.expectEqual(count, shape.fields.end - shape.fields.start);
            for (fields[0..count], p.fields[shape.fields.start..shape.fields.end]) |field, actual| {
                var name: [16]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&name, "F{d}_{d}", .{ field.template, field.ordinal }), actual.name.text(p.source));
                const wanted = model.resolve(p, field.value_type) orelse {
                    std.debug.print("seed {d}: the type of field F{d}_{d} is missing\n{s}\n", .{ seed, field.template, field.ordinal, out.buffered() });
                    return error.MissingFieldType;
                };
                try std.testing.expectEqual(wanted, actual.value_type);
            }
            const item = model.nodes[node].instance;
            if (model.templates[item.template].parent) |parent| {
                try std.testing.expectEqual(model.resolve(p, try model.substitute(parent, item.arguments[0..item.count])).?, shape.parent.?);
            } else try std.testing.expect(shape.parent == null);
            // The dispatch table sends `Tag` of this class to a function that returns the model's tag.
            const slot = for (p.slots, 0..) |entry, index| {
                if (catalogue.subtype(class, entry.owner, p.definitions)) break index;
            } else unreachable;
            const function = p.functions[catalogue.dispatchLookup(p.dispatch, class, @intCast(slot)).?];
            const body = p.function_nodes[function.body.start + function.root].node;
            try std.testing.expectEqual(try model.tag(@intCast(node)), body.kind.integer);
            checked_instances += 1;
        }
        var actual: usize = 0;
        for (p.definitions) |item| actual += @intFromBool(catalogue.typeArguments(item) != null);
        try std.testing.expectEqual(expected, actual);
    }
    try std.testing.expect(compiled >= 40 and checked_instances >= 200);
}

test "a parametric program with one character changed compiles or is refused, and what compiles runs alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const original =
        \\Has[T:type]:=interface{Get()<transacts>:T}
        \\Pt[A:type,B:comparable]:=struct{X:A,Y:B,Tag:string="p"}
        \\Box[T:subtype(Has[i64])]:=class<final>(Has[i64]){
        \\  In:option(T)=option{}
        \\  At:Pt[i64,string]=Pt[i64,string]{X:=1,Y:="y"}
        \\  Get<override>()<transacts>:i64=40+Self.At.X
        \\}
        \\Leaf:=class(Has[i64]){Get<override>()<transacts>:i64=2}
        \\Node[T:type]:=class{V:T,Next:option(Node[T])=option{}}
        \\Wrap[T:type](X:T)<transacts>:Node[T]{Node[T]{V:=X}}
        \\B:Has[i64]=Box[Leaf]{}
        \\N:=Wrap[Pt[i64,i64]](Pt[i64,i64]{X:=1,Y:=2})
        \\Value:i64=B.Get()+Leaf{}.Get()+N.V.Y+Attempt(Box[Leaf][B].At.X,0)
    ;
    try std.testing.expectEqual(@as(i64, 46), (try h.execute(original)).get("Value").?.integer);
    const punctuation = "{}[]().,:;=+-*/<>\n\" TB";
    var prng = std.Random.DefaultPrng.init(0x0073);
    const random = prng.random();
    var source: [original.len]u8 = undefined;
    var accepted: usize = 0;
    for (0..1500) |_| {
        @memcpy(&source, original);
        // One or two changes: a second one can repair the bracket the first one broke.
        for (0..random.intRangeAtMost(usize, 1, 2)) |_| source[random.uintLessThan(usize, source.len)] = punctuation[random.uintLessThan(usize, punctuation.len)];
        const result = h.front.compile(&source);
        try std.testing.expect(h.front.instantiation_depth == 0 or result == .failed);
        if (result == .failed) continue;
        accepted += 1;
        _ = try h.run(result.ok, 100_000);
    }
    // Some changes land in a name or a number and leave a program.
    try std.testing.expect(accepted != 0);
}

test "a declaration that first names a struct instantiation in a default keeps the fields it has staged" {
    const h = try harness.create();
    defer scratch.release(h);
    // The field whose default is being read is staged like the ones before it: a struct made
    // in the middle of the default moves all of them out of its way and back.
    const x = try h.execute(
        \\Pt[T:type]:=struct{A:T,B:T,C:T,D:T,E:[]i64=array{1,2}}
        \\Inner[T:type]:=struct{Arr:[]i64=array{1,2,3}}
        \\Wide[T:type]:=struct{P:T,Q:T,R:T,S:i64=Pt[T]{A:=3,B:=4,C:=5,D:=6}.A,U:i64=30}
        \\Outer[T:type]:=class{
        \\  A:i64=1
        \\  B:i64=1
        \\  C:[]i64=array{9}
        \\  D:i64=Inner[T]{}.Arr.Length+Inner[[]T]{}.Arr.Length-1
        \\  E:[]i64=array{7,8}
        \\}
        \\Plain:=struct{Y:i64=Inner[string]{}.Arr.Length,Z:i64=Pt[logic]{A:=true,B:=true,C:=true,D:=true}.E.Length}
        \\K:=class{
        \\  P:i64=1
        \\  Q:i64=2
        \\  M(X:i64,Y:i64=Pt[i64]{A:=1,B:=2,C:=3,D:=4}.D+Pt[string]{A:="a",B:="b",C:="c",D:="d"}.E.Length)<transacts>:i64=X+Y+Self.P+Self.Q
        \\}
        \\F(X:i64,Y:i64=2,Z:i64=Pt[float]{A:=1.0,B:=2.0,C:=3.0,D:=4.0}.E.Length+4,W:string="w")<transacts>:i64=X+Y+Z
        \\Go()<transacts>:i64=Block{O:=Outer[i64]{};O.D+O.E.Length-O.C.Length-O.A}
        \\V:tuple(i64,i64,i64,i64,i64,i64)=tuple{Wide[i64]{P:=1,Q:=1,R:=1}.S,Wide[i64]{P:=1,Q:=1,R:=1}.U,Go(),K{}.M(7),F(1),Plain{}.Z}
    );
    const v = x.elements(x.get("V").?).?;
    for ([_]i64{ 3, 30, 5, 16, 9, 2 }, v) |expected, actual| try std.testing.expectEqual(expected, actual.integer);
    try std.testing.expect(h.front.staged_fields == 0 and h.front.staged_inherited == 0 and h.front.declaring == 0 and h.front.open_count == 0);
    try expectDiagnostics(h, "Bx[T:type]:=class{var Y:T}\nPt[T:type]:=struct{Zed:T}\n", &.{
        // The field of `Q` stays the immutable `Y` it was declared as, whatever its default names.
        .{ .tail = "Q:=class{Y:i64=Fn(B:option(Bx[i64]))<computes>:i64{7}(option{})}\nGo()<transacts>:i64=Block{X:=Q{};set X.Y=99;X.Y}\nR:i64=Go()", .code = .not_mutable },
        .{ .tail = "S:=struct{Y:string=Pt[string]{Zed:=\"d\"}.Zed}\nR:string=S{}.Zed", .code = .unknown_field },
        .{ .tail = "S:=struct{Y:i64=1,Y:string=Pt[string]{Zed:=\"d\"}.Zed}", .code = .duplicate_field },
        // No instance is built in a default, of a parametric class as of any other.
        .{ .tail = "Q:=class{Y:i64=Bx[i64]{Y:=5}.Y+1}", .code = .construction_requires_allocates },
    });
    const kept = try h.execute("Pt[T:type]:=struct{Zed:T}\nS:=struct{Y:string=Pt[string]{Zed:=\"d\"}.Zed,W:i64=2}\nR:string=S{}.Y\nN:i64=S{}.W");
    try std.testing.expectEqualStrings("d", kept.get("R").?.string);
    try std.testing.expectEqual(@as(i64, 2), kept.get("N").?.integer);
}

test "naming instantiations in the middle of declarations means what naming them up front means" {
    const h = try harness.create();
    defer scratch.release(h);
    const text = try std.testing.allocator.alloc(u8, 2 * 24 * 1024);
    defer std.testing.allocator.free(text);
    const arguments = [_][]const u8{ "i64", "string", "logic", "[]i64" };
    const literals = [_][]const u8{ "1", "\"s\"", "true", "array{1}" };
    var compared: usize = 0;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var results: [2][12]i64 = undefined;
        var counts: [2]usize = .{ 0, 0 };
        for (0..2) |variant| {
            // The same random choices for both variants: the second only names every type first.
            var prng = std.Random.DefaultPrng.init(0x1707 + seed);
            const random = prng.random();
            var out = std.Io.Writer.fixed(text[variant * 24 * 1024 ..][0 .. 24 * 1024]);
            const templates = random.intRangeAtMost(usize, 2, 4);
            for (0..templates) |t| {
                try out.print("S{d}[T:type]:=struct{{A:T,B:i64={d},C:[]i64=array{{{d},{d}}}}}\n", .{ t, t + 1, t, t });
                try out.print("C{d}[T:type]:=class{{\n  var V:T\n  N:i64={d}\n  Get(Add:i64=S{d}[[]T]{{A:=array{{}}}}.B)<transacts>:i64=Self.N+Add\n}}\n", .{ t, 10 * (t + 1), t });
            }
            if (variant == 1) for (0..templates) |t| for (arguments, 0..) |argument, a| {
                try out.print("PreS{d}_{d}:option(S{d}[{s}])=option{{}}\nPreC{d}_{d}:option(C{d}[{s}])=option{{}}\n", .{ t, a, t, argument, t, a, t, argument });
            };
            const Mention = struct {
                fn structValue(o: *std.Io.Writer, r: std.Random, count: usize) !void {
                    const a = r.uintLessThan(usize, arguments.len);
                    try o.print("S{d}[{s}]{{A:={s}}}.{s}", .{ r.uintLessThan(usize, count), arguments[a], literals[a], if (r.boolean()) "B" else "C.Length" });
                }
                fn classValue(o: *std.Io.Writer, r: std.Random, count: usize) !void {
                    const a = r.uintLessThan(usize, arguments.len);
                    try o.print("C{d}[{s}]{{V:={s}}}.Get()", .{ r.uintLessThan(usize, count), arguments[a], literals[a] });
                }
                fn named(o: *std.Io.Writer, r: std.Random, count: usize) !void {
                    try o.print("{s}{d}[{s}]", .{ if (r.boolean()) "S" else "C", r.uintLessThan(usize, count), arguments[r.uintLessThan(usize, arguments.len)] });
                }
                fn number(o: *std.Io.Writer, r: std.Random, count: usize) !void {
                    if (r.boolean()) try o.print("{d}", .{r.uintLessThan(u8, 9)}) else try structValue(o, r, count);
                }
            };
            const declarations = random.intRangeAtMost(usize, 2, 5);
            for (0..declarations) |d| {
                switch (random.uintLessThan(u8, 3)) {
                    0 => {
                        try out.print("P{d}:=struct{{F0:i64=", .{d});
                        try Mention.number(&out, random, templates);
                        try out.writeAll(",F1:option(");
                        try Mention.named(&out, random, templates);
                        try out.writeAll(")=option{},F2:i64=");
                        try Mention.number(&out, random, templates);
                        try out.print("}}\nR{d}:i64=P{d}{{}}.F0+P{d}{{}}.F2\n", .{ d, d, d });
                    },
                    1 => {
                        try out.print("Q{d}:=class{{\n  F0:i64=", .{d});
                        try Mention.number(&out, random, templates);
                        try out.writeAll("\n  F1:option(");
                        try Mention.named(&out, random, templates);
                        try out.writeAll(")=option{}\n  var F2:i64=");
                        try Mention.number(&out, random, templates);
                        try out.writeAll("\n  M(X:i64,Other:option(");
                        try Mention.named(&out, random, templates);
                        try out.writeAll(")=option{},Y:i64=");
                        try Mention.number(&out, random, templates);
                        try out.writeAll(")<transacts>:i64=X+Y+Self.F0+Self.F2+");
                        try Mention.classValue(&out, random, templates);
                        try out.print("\n}}\nR{d}:i64=Q{d}{{}}.M(1)\n", .{ d, d });
                    },
                    else => {
                        try out.print("F{d}(X:i64,Y:i64=", .{d});
                        try Mention.number(&out, random, templates);
                        try out.writeAll(")<transacts>:i64=Block{L:=X;L+Y+");
                        try Mention.classValue(&out, random, templates);
                        try out.writeAll("+");
                        try Mention.number(&out, random, templates);
                        try out.print("}}\nR{d}:i64=F{d}(1)\n", .{ d, d });
                    },
                }
            }
            const result = h.front.compile(out.buffered());
            if (result == .failed) {
                const code = result.failed.code;
                // Only a bootstrap capacity may refuse a generated program, and then in both variants or the larger one.
                if (code != .function_limit and code != .method_limit and code != .type_limit and code != .field_limit and code != .tuple_limit and code != .template_limit) {
                    std.debug.print("seed {d} variant {d}: {s} at {d}\n{s}\n", .{ seed, variant, @tagName(code), result.failed.span.start, out.buffered() });
                    return error.UnexpectedDiagnostic;
                }
                counts[variant] = std.math.maxInt(usize);
                continue;
            }
            try std.testing.expect(h.front.staged_fields == 0 and h.front.declaring == 0 and h.front.open_count == 0 and h.front.instantiation_depth == 0);
            const run = (try h.run(result.ok, 1 << 20)).ok;
            for (0..declarations) |d| {
                var name: [8]u8 = undefined;
                results[variant][d] = run.get(try std.fmt.bufPrint(&name, "R{d}", .{d})).?.integer;
            }
            counts[variant] = declarations;
        }
        if (counts[0] == std.math.maxInt(usize) or counts[1] == std.math.maxInt(usize)) continue;
        try std.testing.expectEqualSlices(i64, results[1][0..counts[1]], results[0][0..counts[0]]);
        compared += 1;
    }
    try std.testing.expect(compared >= 20);
}

/// Compiles and runs `declarations` followed by the lines of `uses` in the order given and in
/// the reverse order, and expects `Result` to be `expected` both times.
fn expectEitherOrder(h: *harness.Harness, declarations: []const u8, uses: []const []const u8, result: []const u8, expected: i64) !void {
    var buffer: [4096]u8 = undefined;
    for (0..2) |order| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll(declarations);
        for (0..uses.len) |index| try out.print("{s}\n", .{uses[if (order == 0) index else uses.len - 1 - index]});
        try out.print("Result:i64={s}", .{result});
        const x = h.execute(out.buffered()) catch |err| {
            std.debug.print("order {d} of:\n{s}\n", .{ order, out.buffered() });
            return err;
        };
        try std.testing.expectEqual(expected, x.get("Result").?.integer);
        try std.testing.expect(h.front.declaring == 0 and h.front.open_count == 0 and h.front.settled == h.front.instance_count);
    }
}

test "templates that name each other mean the same whichever instantiation is named first" {
    const h = try harness.create();
    defer scratch.release(h);
    // A base whose signature, field or body names its own subclass, as a plain class may.
    const base =
        \\Base[T:type]:=class{
        \\  V:T
        \\  Kid:option(Sub[T])=option{}
        \\  Mk(S:option(Sub[T]))<transacts>:i64=1
        \\  G()<transacts>:i64=7
        \\}
        \\Sub[T:type]:=class(Base[T]){
        \\  W:i64=2
        \\  G<override>()<transacts>:i64=Self.W+Self.Mk(option{})
        \\}
        \\
    ;
    try expectEitherOrder(h, base, &.{ "B:Base[i64]=Base[i64]{V:=1}", "X:Base[i64]=Sub[i64]{V:=1}" }, "X.G()*10+B.G()", 37);
    try expectEitherOrder(h, base, &.{ "B:option(Base[i64])=option{}", "X:=Sub[i64]{V:=1}" }, "X.G()", 3);
    // An interface that names its implementer.
    try expectEitherOrder(h,
        \\Fc[T:type]:=interface{
        \\  Same(Other:option(Impl[T]))<transacts>:logic=true
        \\  Get()<transacts>:T
        \\}
        \\Impl[T:type]:=class(Fc[T]){
        \\  V:T
        \\  Get<override>()<transacts>:T=Self.V
        \\}
        \\
    , &.{ "F:Fc[i64]=Impl[i64]{V:=5}", "N:option(Fc[i64])=option{}", "I:option(Impl[i64])=option{}" }, "F.Get()", 5);
    // Two templates whose bodies build and call each other.
    try expectEitherOrder(h,
        \\Ping[T:type]:=class{
        \\  V:T
        \\  Other:option(Pong[T])=option{}
        \\  Hit()<transacts>:i64=1+Attempt(Block{O:=Self.Other?;O.Back()},0)
        \\  Peer()<transacts>:Pong[T]=Pong[T]{W:=Self.V}
        \\  Both()<transacts>:i64=Ping[T]{V:=Self.V,Other:=option{Self.Peer()}}.Hit()
        \\}
        \\Pong[T:type]:=class{
        \\  W:T
        \\  Owner:option(Ping[T])=option{}
        \\  Back()<transacts>:i64=10
        \\  Make()<transacts>:i64=Ping[T]{V:=Self.W}.Hit()+Attempt(Block{P:=Self.Owner?;P.Hit()},100)
        \\}
        \\
    , &.{ "A:=Ping[i64]{V:=1}", "B:=Pong[i64]{W:=2}", "C:option(Pong[string])=option{}", "D:option(Ping[string])=option{}" }, "A.Peer().Make()+B.Make()+A.Both()", 101 + 101 + 11);
    // A plain class below an instantiation, named by the template above it: it is declared
    // late and still known to what precedes it, like any class.
    try expectEitherOrder(h,
        \\Base[T:type]:=class{
        \\  V:T
        \\  Kid:option(Leaf)=option{}
        \\  Mk(S:option(Leaf))<transacts>:i64=1
        \\  G()<transacts>:i64=7
        \\}
        \\Holder:=class{Later:option(Leaf)=option{},Deeper:option(Twig)=option{}}
        \\Leaf:=class(Base[i64]){
        \\  W:i64=2
        \\}
        \\Use(X:Leaf)<transacts>:i64=X.W
        \\Twig:=class<final>(Leaf){}
        \\
    , &.{ "X:=Leaf{V:=1}", "Y:=Base[i64]{V:=3}", "Z:=Twig{V:=4}", "H:=Holder{}" }, "X.G()+Use(X)+Y.Mk(option{X})+Use(Z)", 12);
    // What a plain class cannot do, these cannot either: a body that builds a type whose
    // declaration needs the one being declared.
    try expectDiagnostics(h, "Base[T:type]:=class{\n  V:T\n  F()<transacts>:i64=3\n  Mk()<transacts>:i64=Sub[T]{V:=Self.V}.F()\n}\nSub[T:type]:=class(Base[T]){W:i64=2}\n", &.{
        .{ .tail = "B:=Base[i64]{V:=1}", .code = .unknown_name },
        .{ .tail = "X:=Sub[i64]{V:=1}", .code = .unknown_name },
    });
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, h.front.compile("Base:=class{\n  V:i64\n  F()<transacts>:i64=3\n  Mk()<transacts>:i64=Sub{V:=Self.V}.F()\n}\nSub:=class(Base){W:i64=2}\nB:=Base{V:=1}").failed.code);
}

test "programs without parametric types declare their classes as before, in a module and across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    // A binding made by a generic call is no declaration of a type: `Base` here is a value of
    // one module and a class of the other, and the class below it is declared early as ever.
    const classes = "Base<public>:=class{N:i64=1}\nHolder:=class{Later:option(D)=option{}}\nUse(X:D)<transacts>:D=X\nD:=class(Base){}\nCount<public>:i64=Use(D{}).N";
    const binding = "Gen[T:type](X:T)<computes>:T{X}\nBase<public>:=Gen[i64](1)";
    const cases = [_]struct { main: []const u8, lib: []const u8, other: []const u8 = "" }{
        .{ .main = "L:=import{\"lib.forb\"}\nBase:=class{N:i64=1}\nHolder:=class{Later:option(D)=option{}}\nUse(X:D)<transacts>:D=X\nD:=class(Base){}\nV<public>:i64=Use(D{}).N+L.Base", .lib = binding },
        .{ .main = "O:=import{\"other.forb\"}\nL:=import{\"lib.forb\"}\nV<public>:i64=O.Base+L.Count", .lib = classes, .other = binding },
        .{ .main = "L:=import{\"lib.forb\"}\nO:=import{\"other.forb\"}\nV<public>:i64=O.Base+L.Count", .lib = classes, .other = binding },
    };
    for (cases) |case| {
        const bundled = bundle(h, case.main, case.lib, case.other);
        if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
        try std.testing.expectEqual(@as(i64, 2), (try h.run(bundled.ok, 100_000)).ok.get("V").?.integer);
        try std.testing.expectEqual(@as(u32, 0), h.front.late_count);
    }
    const x = try h.execute("Gen[T:type](X:T)<computes>:T{X}\nY:=Gen[i64](1)\nItems:[]i64=array{1,2}\nBase:=class{N:i64=1}\nUse(X:D)<transacts>:D=X\nD:=class<final>(Base){}\nV:i64=Use(D{}).N+Y");
    try std.testing.expectEqual(@as(i64, 2), x.get("V").?.integer);
    try std.testing.expectEqual(@as(u32, 0), h.front.late_count);
    // With parametric types only the declarations that need it are late: a template, a class
    // below an instantiation, a class below that one and an alias; not the values around them.
    const y = try h.execute("Box[T:type]:=class{V:T}\nB:=Box[i64]{V:=1}\nInts:=Box[i64]\nUp:=class(Box[i64]){}\nDown:=class(Up){}\nVia:=class(Ints){}\nFree:=class{}\nUnder:=class(Free){}\nN:i64=Down{V:=1}.V+Via{V:=2}.V");
    try std.testing.expectEqual(@as(i64, 3), y.get("N").?.integer);
    try std.testing.expectEqual(@as(u32, 5), h.front.late_count);
    // A class below a plain class of its own module is still known before its declaration
    // when a module it imports has a template of that name.
    const scoped = bundle(h, "L:=import{\"lib.forb\"}\nUser:=class{Later:option(Mine)=option{}}\nBox:=class{N:i64=4}\nMine:=class(Box){}\nV<public>:i64=Mine{}.N+L.Made", "Box[T:type]:=class{V:T}\nInner:=class(Box[i64]){}\nMade<public>:i64=Inner{V:=1}.V", "");
    if (scoped == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ scoped.failed.diagnostic.message(), scoped.failed.path });
    try std.testing.expectEqual(@as(i64, 5), (try h.run(scoped.ok, 100_000)).ok.get("V").?.integer);
}

test "a type parameter that stands for an abstract class builds nothing" {
    const h = try harness.create();
    defer scratch.release(h);
    const base = "Sh:=class<abstract>{N:i64=1}\nSq:=class(Sh){}\nMake[T:type]()<transacts>:T{T{}}\nBound[T:subtype(Sh)]()<transacts>:T{T{}}\nFac[T:subtype(Sh)]:=class{Mk()<transacts>:T=T{}}\nAny[T:type]:=class{Mk()<transacts>:T=T{}}\n";
    try expectDiagnostics(h, base, &.{
        .{ .tail = "A:=Make[Sh]()", .code = .abstract_instance },
        .{ .tail = "A:=Bound[Sh]()", .code = .abstract_instance },
        .{ .tail = "A:=Fac[Sh]{}.Mk()", .code = .abstract_instance },
        .{ .tail = "A:=Any[Sh]{}.Mk()", .code = .abstract_instance },
    });
    var buffer: [1024]u8 = undefined;
    const x = try h.execute(try std.fmt.bufPrint(&buffer, "{s}A:i64=Make[Sq]().N+Bound[Sq]().N+Fac[Sq]{{}}.Mk().N+Any[Sq]{{}}.Mk().N", .{base}));
    try std.testing.expectEqual(@as(i64, 4), x.get("A").?.integer);
}

test "template headers with comments, newlines and nested bounds are read alike by the compiler and both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude =
        \\Has[T:type]:=interface{Get()<transacts>:T}
        \\Leaf:=class(Has[i64]){Get<override>()<transacts>:i64=4}
        \\Wide:=interface(Has[i64]){}
        \\Both:=class(Wide){Get<override>()<transacts>:i64=6}
        \\
    ;
    // The reviewer's cases: a comment inside a bound that holds brackets.
    var buffer: [4096]u8 = undefined;
    for ([_][]const u8{
        "Take[T:subtype(Has[ # one )\n  i64])](X:T)<transacts>:i64{X.Get()}\nW:i64=Take[Leaf](Leaf{})",
        "Take[T:subtype(Has[ # see [RFC\n  i64])](X:T)<transacts>:i64{X.Get()}\nW:i64=Take[Leaf](Leaf{})",
        "Pen[T:subtype(Has[ # one ) and [ two\n  i64])]:=class{K:T}\nW:i64=Pen[Leaf]{K:=Leaf{}}.K.Get()",
        "Pen[T:subtype( # ((( \"\n  Has[i64] # ]]]\n )]:=class{K:T}\nW:i64=Pen[Leaf]{K:=Leaf{}}.K.Get()",
    }) |tail| {
        const x = try h.execute(try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, tail }));
        try std.testing.expectEqual(@as(i64, 4), x.get("W").?.integer);
    }
    // Generated headers: every gap that may hold a line break holds, at random, spaces, a line
    // break or a comment full of brackets and quotes. What the compiler accepts, both
    // admissions accept (`h.run`); a header with one character changed is refused or still agrees.
    const kinds = [_][]const u8{ "type", "comparable", "subtype(Has[i64])", "subtype(Wide)", "subtype(Has[\n i64 ])" };
    const noise = [_][]const u8{ "", " ", "  ", "\n", " \n  ", " # ) ] [ ( \" ' } { :=\n", "#]\n", " # subtype(type]\n " };
    var prng = std.Random.DefaultPrng.init(0x5005);
    const random = prng.random();
    var accepted: usize = 0;
    for (0..400) |round| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll(prelude);
        const header = out.end;
        const function = random.boolean();
        const parameters = random.intRangeAtMost(usize, 1, 3);
        var chosen: [3]usize = undefined;
        try out.print("Gen{s}[", .{if (random.boolean()) "<public>" else ""});
        for (0..parameters) |index| {
            chosen[index] = random.uintLessThan(usize, kinds.len);
            try out.print("{s}P{d}{s}:{s}{s}{s}", .{ noise[random.uintLessThan(usize, noise.len)], index, if (random.boolean()) " " else "", if (random.boolean()) " " else "", kinds[chosen[index]], noise[random.uintLessThan(usize, noise.len)] });
            if (index + 1 != parameters) try out.writeByte(',');
        }
        try out.writeByte(']');
        const body = out.end;
        if (function) try out.writeAll("(X:P0)<transacts>:i64{1}\nW:i64=Gen[") else try out.writeAll(" := class{X:P0}\nW:option(Gen[");
        for (chosen[0..parameters], 0..) |kind, index| try out.print("{s}{s}", .{ if (index == 0) "" else ",", if (kind < 2) "i64" else "Both" });
        if (function) try out.print("]({s})", .{if (chosen[0] < 2) "1" else "Both{}"}) else try out.writeAll("])=option{}");
        if (round % 2 == 1) {
            // One character of the header changed.
            const mutations = "[]()#,:< \n";
            buffer[header + random.uintLessThan(usize, body - header)] = mutations[random.uintLessThan(usize, mutations.len)];
        }
        const result = h.front.compile(out.buffered());
        if (result == .failed) {
            if (round % 2 == 0) {
                std.debug.print("a generated header was refused: {s} at {d}\n{s}\n", .{ @tagName(result.failed.code), result.failed.span.start, out.buffered() });
                return error.UnexpectedDiagnostic;
            }
            continue;
        }
        const run = h.run(result.ok, 100_000) catch |err| {
            std.debug.print("the machines disagree with the compiler about:\n{s}\n", .{out.buffered()});
            return err;
        };
        if (run == .failed) {
            std.debug.print("admitted by the compiler and refused by a machine ({s}):\n{s}\n", .{ @tagName(run.failed.code), out.buffered() });
            return error.Refused;
        }
        accepted += 1;
    }
    try std.testing.expect(accepted >= 200);
}

test "a private type that a class of another module exposes is reported at that class" {
    const h = try harness.create();
    defer scratch.release(h);
    const main = "L:=import{\"lib.forb\"}\nMine:=class{K:i64=4}\nOut<public>:=class(L.Box[Mine]){}\nA<public>:i64=Out{V:=Mine{}}.V.K";
    const refused = bundle(h, main, "Box<public>[T:type]:=class{V<public>:T}", "").failed;
    try std.testing.expectEqual(types.Diagnostic.Code.private_type_escape, refused.diagnostic.code);
    try std.testing.expectEqualStrings("main.forb", refused.path);
    try std.testing.expectEqualStrings("Out", main[refused.diagnostic.span.start..refused.diagnostic.span.end]);
    // Within one module the field is where it was always reported.
    const own = "Secret:=class{}\nUp<public>:=class{S<public>:option(Secret)=option{}}";
    const local = bundle(h, "L:=import{\"lib.forb\"}\nA<public>:i64=1", own, "").failed;
    try std.testing.expectEqualStrings("lib.forb", local.path);
    try std.testing.expectEqualStrings("S", own[local.diagnostic.span.start..local.diagnostic.span.end]);
}
