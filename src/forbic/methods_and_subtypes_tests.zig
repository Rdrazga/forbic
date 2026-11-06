//! RFC-0081: generic methods, the `subtype` family as values and bounds, `SortBy`, function type
//! aliases with effects and casts out of `any` to a function type with more effects. Every
//! program runs on both machines (`harness.run` holds them to the same values, steps, cells and
//! reports, and replays both reports).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

const Code = types.Diagnostic.Code;

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value != .integer or value.integer != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectLogic(x: anytype, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse return error.Missing;
    try std.testing.expectEqual(expected, value.boolean);
}

fn expectText(x: anytype, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse return error.Missing;
    try std.testing.expectEqualStrings(expected, value.string);
}

/// The integers of the array binding `name`.
fn expectInts(x: anytype, name: []const u8, expected: []const i64) !void {
    const value = x.get(name) orelse return error.Missing;
    const elements = x.aggregate_values[value.aggregate.elements.start..value.aggregate.elements.end];
    try std.testing.expectEqual(expected.len, elements.len);
    for (elements, expected) |element, want| try std.testing.expectEqual(want, element.integer);
}

/// The source is refused with `code`, and the diagnostic covers exactly `text`.
fn expectRefused(h: *harness.Harness, source: []const u8, code: Code, text: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), text)) std.debug.print("{s} at `{s}`, expected {s} at `{s}`: {s}\n", .{ @tagName(result.failed.code), result.failed.span.text(source), @tagName(code), text, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(text, result.failed.span.text(source));
}

fn refused(h: *harness.Harness, source: []const u8, code: Code) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    if (result.failed.code != code) std.debug.print("{s} at `{s}`, expected {s}: {s}\n", .{ @tagName(result.failed.code), result.failed.span.text(source), @tagName(code), source });
    try std.testing.expectEqual(code, result.failed.code);
}

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

// ---- Generic methods

const shapes =
    \\Shape:=interface{
    \\    Area()<reads>:i64
    \\    Scaled[U:type](F:function(tuple(i64),U))<reads>:U{F(Self.Area())}
    \\}
    \\Sq:=class(Shape){
    \\    Side:i64
    \\    Area<override>()<reads>:i64=Self.Side*Self.Side
    \\}
    \\Box[T:type]:=class{
    \\    Value:T
    \\    Map[U:type](F:function(tuple(T),U))<reads><allocates>:Box[U]{Box[U]{Value:=F(Self.Value)}}
    \\    Both[U:type](Other:U)<reads>:tuple(T,U){tuple{Self.Value,Other}}
    \\}
    \\Counter:=class{
    \\    var N:i64=0
    \\    Add[U:type](Xs:[]U)<transacts>:i64{Block{set Self.N=Self.N+Xs.Length;Self.N}}
    \\    Down[U:type](K:i64,X:U)<computes>:i64{If(K<=0,0,1+Self.Down[U](K-1,X))}
    \\    Pick<private>[U:type](X:U)<computes>:U{X}
    \\    Use()<computes>:i64=Self.Pick[i64](6)
    \\}
    \\Child:=class(Counter){}
    \\
;

test "rfc0081 generic methods of classes, interfaces and parametric types are specialized per argument list" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(shapes ++
        \\S:Shape=Sq{Side:=3}
        \\A<public>:string=S.Scaled[string](Fn(N:i64)<computes>:string{"{N}"})
        \\B:=Box[i64]{Value:=5}
        \\C<public>:i64=B.Map[string](Fn(N:i64)<computes>:string{"v{N}"}).Both[i64](9)(1)
        \\D<public>:string=B.Map[string](Fn(N:i64)<computes>:string{"v{N}"}).Value
        \\G:=B.Both[string]
        \\H<public>:string=G("g")(1)
        \\K:=Child{}
        \\R<public>:i64=K.Down[string](5,"s")
        \\U<public>:i64=K.Use()
        \\F(X:Counter)<transacts>:i64=X.Add[string](array{"a","b"})+X.Add[i64](array{1})
        \\N<public>:i64=F(K)
    );
    try expectText(x, "A", "9");
    try expectInt(x, "C", 9);
    try expectText(x, "D", "v5");
    try expectText(x, "H", "g");
    try expectInt(x, "R", 5);
    try expectInt(x, "U", 6);
    try expectInt(x, "N", 2 + 3);
    // One function per method and argument list (and receiver): `Map[string]` and `Both[...]`
    // were named twice and compiled once each.
    var both: usize = 0;
    var map: usize = 0;
    for (x.program.functions) |f| {
        if (std.mem.eql(u8, f.name.text(x.program.source), "Both")) both += 1;
        if (std.mem.eql(u8, f.name.text(x.program.source), "Map")) map += 1;
        if (f.specialization) |key| if (!f.anonymous and f.parameter_count > 0) {
            // A specialization's key ends with its receiver's class, the function's first parameter.
            const shape = x.program.definitions[@backingInt(key) - @import("aggregate_types.zig").builtin_count].tuple;
            if (std.mem.eql(u8, f.name.text(x.program.source), "Both")) try std.testing.expectEqual(f.parameters[0], x.program.tuple_elements[shape.end - 1]);
        };
    }
    try std.testing.expectEqual(@as(usize, 2), both);
    try std.testing.expectEqual(@as(usize, 1), map);
}

test "rfc0081 classes may each declare a generic method of one name, and both admissions keep them apart" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A:=class{N:i64=1
        \\Get[U:type](X:U)<reads>:i64{Self.N}
        \\}
        \\B:=class{N:i64=2
        \\Get[U:type](X:U)<reads>:i64{Self.N*10}
        \\}
        \\V<public>:i64=A{}.Get[i64](0)+B{}.Get[i64](0)+A{}.Get[string]("s")
    );
    try expectInt(x, "V", 1 + 20 + 1);
}

test "rfc0081 a generic method rolls back with its region and charges its effects at the call" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(shapes ++
        \\K:=Counter{}
        \\Try(X:Counter)<transacts><decides>:i64=Block{X.Add[i64](array{1,2,3});Require[X.N>10];X.N}
        \\A<public>:i64=Attempt(Try[K],0-1)
        \\B<public>:i64=K.N
        \\C<public>:i64=K.Add[logic](array{true})
    );
    try expectInt(x, "A", -1);
    try expectInt(x, "B", 0);
    try expectInt(x, "C", 1);
    // The call needs what the method declares.
    try expectRefused(h, shapes ++ "F(X:Counter)<reads>:i64=X.Add[i64](array{1})", .call_requires_writes_allocates, "(");
}

test "rfc0081 generic methods have no slot: what a slot would allow is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "A:=class{\nG<override>[U:type](X:U)<computes>:U{X}\n}", .generic_method_slot, "override");
    try expectRefused(h, "A:=class<abstract>{\nG<abstract>[U:type](X:U)<computes>:U{X}\n}", .generic_method_slot, "abstract");
    try expectRefused(h, "I:=interface{\nG[U:type](X:U)<computes>:U\n}", .generic_method_slot, "G");
    // Below a class that has it, the name is taken: by a method, a field or another generic method.
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nB:=class(A){\nG<override>()<computes>:i64=1\n}", .generic_method_slot, "G");
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nB:=class(A){\nG()<computes>:i64=1\n}", .generic_method_slot, "G");
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nB:=class(A){\nG:i64=1\n}", .generic_method_slot, "G");
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nB:=class(A){\nG[V:type](X:V)<computes>:V{X}\n}", .generic_method_slot, "G");
    // Above it, a method of the name is not replaced by one.
    try expectRefused(h, "A:=class{\nG()<computes>:i64=1\n}\nB:=class(A){\nG[U:type](X:U)<computes>:U{X}\n}", .generic_method_slot, "G");
    // In one class, a name is one member.
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\nG()<computes>:i64=1\n}", .duplicate_name, "G");
    try expectRefused(h, "A:=class{\nG[U:type](X:U)<computes>:U{X}\nG[V:type](X:V)<computes>:V{X}\n}", .duplicate_name, "G");
    try expectRefused(h, "A:=class{\nG:i64=1\nG[U:type](X:U)<computes>:U{X}\n}", .duplicate_name, "G");
    // Reached by two supertypes, the name is ambiguous where it is used.
    try expectRefused(h, "I:=interface{\nG[U:type](X:U)<computes>:U{X}\n}\nJ:=interface{\nG[U:type](X:U)<computes>:U{X}\n}\nC:=class(I,J){}\nV:i64=C{}.G[i64](1)", .ambiguous_call, "G");
    try expectRefused(h, "I:=interface{\nG()<computes>:i64\n}\nA:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nC:=class(A,I){\nG<override>()<computes>:i64=1\n}", .generic_method_slot, "G");
    // A call names its type arguments, as many as there are, within their bounds.
    const g = "Animal:=class{}\nDog:=class(Animal){}\nA:=class{\nG[U:subtype(Animal)](X:U)<computes>:U{X}\nP<private>[U:type](X:U)<computes>:U{X}\n}\n";
    try expectRefused(h, g ++ "V:=A{}.G(Dog{})", .type_arguments_required, "G");
    try expectRefused(h, g ++ "V:=A{}.G[Dog,Dog](Dog{})", .argument_count, "G");
    try expectRefused(h, g ++ "V:=A{}.G[i64](1)", .type_argument_bound, "G");
    try expectRefused(h, g ++ "V:=A{}.P[i64](1)", .inaccessible_member, "P");
    // A type parameter of the method may not take the name of one of its type's.
    try expectRefused(h, "B[T:type]:=class{\nG[T:type](X:T)<computes>:T{X}\n}\nV:=B[i64]{}", .shadowed_name, "T");
    // Nor may a bound name one: a bound is a class known where the method is written.
    try refused(h, "B[T:type]:=class{\nG[U:subtype(T)](X:U)<computes>:U{X}\n}\nV:=B[i64]{}", .unsupported_type);
    // The body is checked for each argument list it is named with.
    try refused(h, "A:=class{\nG[U:type](X:U)<computes>:i64{X+1}\n}\nV:i64=A{}.G[string](\"a\")", .type_mismatch);
}

test "rfc0081 a generic method's specialization is what both admissions accept, and nothing forged" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(shapes ++
        \\B:=Box[i64]{Value:=5}
        \\V<public>:i64=B.Both[i64](4)(1)+Child{}.Down[string](2,"s")
    );
    _ = try h.run(p, 100_000);
    const functions = try std.testing.allocator.dupe(types.RuntimeFunction, p.functions);
    defer std.testing.allocator.free(functions);
    var forged = p;
    forged.functions = functions;
    var checked: usize = 0;
    for (p.functions, 0..) |f, index| {
        const key = f.specialization orelse continue;
        if (f.anonymous or f.parameter_count == 0) continue;
        const name = f.name.text(p.source);
        if (!std.mem.eql(u8, name, "Both") and !std.mem.eql(u8, name, "Down")) continue;
        const shape = p.definitions[@backingInt(key) - @import("aggregate_types.zig").builtin_count].tuple;
        const receiver = p.tuple_elements[shape.end - 1];
        // Every other tuple of the catalogue as the key: one without the receiver last, one with
        // another class last, one with a scalar there, one too short.
        for (p.definitions, 0..) |item, at| {
            if (item != .tuple) continue;
            const candidate: types.Type = @fromBackingInt(@as(u16, @intCast(at + @import("aggregate_types.zig").builtin_count)));
            if (candidate == key) continue;
            const elements = p.tuple_elements[item.tuple.start..item.tuple.end];
            // A tuple that names the same receiver last and has a type argument that fits is a
            // key the header admits: another specialization of the same method.
            if (elements.len == shape.end - shape.start and elements[elements.len - 1] == receiver) continue;
            // One element fewer is the key of a generic function: metadata a header admits for
            // any function, which names the specialization and nothing that runs (RFC-0038).
            if (elements.len + 1 == shape.end - shape.start) continue;
            functions[index].specialization = candidate;
            try harness.invalid(h, forged);
            checked += 1;
        }
        functions[index].specialization = key;
        // The receiver's class is the first parameter's type, for a named specialization.
        functions[index].parameters[0] = .i64;
        try harness.invalid(h, forged);
        functions[index] = f;
        // A specifier no method may have.
        checked += 1;
    }
    try std.testing.expect(checked > 10);
}

test "rfc0081 generic methods in bundles keep the access of their class's module" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Kit<public>:=class{
        \\    N<public>:i64=3
        \\    Twice<public>[U:type](X:U)<reads>:tuple(i64,U){tuple{Self.N*2,X}}
        \\    Hidden[U:type](X:U)<computes>:U{X}
        \\}
        \\Make<public>()<allocates>:Kit=Kit{}
    ;
    const ok = bundle(h, "L:=import{\"lib.forb\"}\nusing{L}\nV<public>:i64=L.Make().Twice[string](\"x\")(0)", lib);
    if (ok != .ok) {
        std.debug.print("{s}\n", .{ok.failed.diagnostic.message()});
        return error.Compile;
    }
    const x = (try h.run(ok.ok, 100_000)).ok;
    try expectInt(x, "V", 6);
    const hidden = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=L.Make().Hidden[i64](1)", lib);
    try std.testing.expect(hidden == .failed and hidden.failed.diagnostic.code == .internal_member);
}

// ---- The subtype family

const components =
    \\Component:=class<castable>{Id:i64=0}
    \\Physics:=class(Component){Mass:i64=5}
    \\Render:=class<castable>(Component){Mat:string="m"}
    \\Plain:=class(Component){}
    \\Entity:=class<abstract>{Name:string,Describe<abstract>()<computes>:string}
    \\Player:=class<concrete>(Entity){Name<override>:string="player",Describe<override>()<computes>:string="a player"}
    \\Enemy:=class<concrete>(Entity){Name<override>:string="enemy",Describe<override>()<computes>:string="an enemy"}
    \\Ghost:=class(Entity){Name<override>:string="ghost",Describe<override>()<computes>:string="boo"}
    \\Kinds:=castable_subtype(Component)
    \\Root:=class{}
    \\Leaf:=class(Root){}
    \\
;

test "rfc0081 a castable_subtype value casts, a concrete_subtype value builds, a subtype value is held" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(components ++
        \\Kind:castable_subtype(Component)=Physics
        \\Is(C:Component,K:Kinds)<computes>:logic=Attempt(Block{K[C];true},false)
        \\P:Component=Physics{Id:=1}
        \\R:Component=Render{}
        \\A<public>:logic=Is(P,Kind)
        \\B<public>:logic=Is(R,Kind)
        \\C<public>:logic=Is(R,Component)
        \\Got<public>:i64=Attempt(Kind[P].Id,0-1)
        \\Spawner:=class{
        \\    Kind:concrete_subtype(Entity)
        \\    Spawn()<reads><allocates>:Entity=Self.Kind{}
        \\}
        \\E1<public>:string=Spawner{Kind:=Player}.Spawn().Name
        \\E2<public>:string=Spawner{Kind:=Enemy}.Spawn().Describe()
        \\Make(K:concrete_subtype(Entity))<allocates>:Entity=K{}
        \\E3<public>:string=Make(Player).Name
        \\Held:subtype(Entity)=Ghost
        \\Ints:subtype(i64)=i64
        \\Same<public>:logic=Ints==Ints
        \\Pick(S:string)<computes>:castable_subtype(Component)=If(S=="physics",Physics,Render)
        \\Picked<public>:[]i64=For(X:array{P,R},Attempt(Block{Pick("render")[X];1},0))
        \\var Saved:castable_subtype(Component)=Component
        \\Swap()<transacts><decides>:void=Block{set Saved=Render;Require[1>2]}
        \\Undone<public>:logic=Attempt(Block{Swap[];true},false)
        \\Still<public>:logic=Is(P,Saved)
        \\Many:[]castable_subtype(Component)=array{Physics,Render,Component}
        \\Counted<public>:i64=For(K:Many,Attempt(Block{K[R];1},0)).Length
    );
    try expectLogic(x, "A", true);
    try expectLogic(x, "B", false);
    try expectLogic(x, "C", true);
    try expectInt(x, "Got", 1);
    try expectText(x, "E1", "player");
    try expectText(x, "E2", "an enemy");
    try expectText(x, "E3", "player");
    try expectLogic(x, "Same", true);
    try expectInts(x, "Picked", &.{ 0, 1 });
    try expectLogic(x, "Undone", false);
    try expectLogic(x, "Still", true);
    try expectInt(x, "Counted", 3);
}

test "rfc0081 the subtype family as bounds of type parameters" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(components ++
        \\Cast[T:castable_subtype(Component)](C:Component)<computes><decides>:T{T[C]}
        \\Build[T:concrete_subtype(Entity)]()<allocates>:T{T{}}
        \\Handler[T:castable_subtype(Component)]:=class{
        \\    Handle(C:Component)<reads>:i64=Attempt(Block{T[C].Id},0-1)
        \\}
        \\P:Component=Physics{Id:=7}
        \\A<public>:i64=Attempt(Cast[Physics][P].Mass,0-1)
        \\B<public>:i64=Attempt(Cast[Render][P].Id,0-1)
        \\N<public>:string=Build[Player]().Name
        \\H<public>:i64=Handler[Physics]{}.Handle(P)+Handler[Render]{}.Handle(P)*100
    );
    try expectInt(x, "A", 5);
    try expectInt(x, "B", -1);
    try expectText(x, "N", "player");
    try expectInt(x, "H", 7 - 100);
    try expectRefused(h, components ++ "Cast[T:castable_subtype(Component)](C:Component)<computes><decides>:T{T[C]}\nV:=Cast[i64]", .type_argument_bound, "Cast");
    try expectRefused(h, components ++ "Cast[T:castable_subtype(Root)](C:Root)<computes><decides>:T{T[C]}\nV:=Cast[Leaf]", .not_castable, "Cast");
    try expectRefused(h, components ++ "Build[T:concrete_subtype(Entity)]()<allocates>:T{T{}}\nV:=Build[Ghost]()", .not_concrete, "Build");
    try expectRefused(h, components ++ "H[T:castable_subtype(Root)]:=class{}\nV:=H[Leaf]{}", .not_castable, "H");
    try expectRefused(h, components ++ "Build[T:concrete_subtype(Entity)]()<allocates>:T{T{}}\nV:=Build[Entity]()", .not_concrete, "Build");
}

test "rfc0081 a type parameter is a type value, and a generic method may say final or protected" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(components ++
        \\Kind[T:castable_subtype(Component)]()<computes>:Kinds{T}
        \\Is(C:Component,K:Kinds)<computes>:logic=Attempt(Block{K[C];true},false)
        \\P:Component=Physics{}
        \\A<public>:logic=Is(P,Kind[Physics]())
        \\B<public>:logic=Is(P,Kind[Render]())
        \\Base:=class{
        \\    Echo<final>[U:type](X:U)<computes>:U{X}
        \\    Hold<protected>[U:type](X:U)<computes>:U{X}
        \\}
        \\Below:=class(Base){
        \\    Use()<computes>:i64=Self.Hold[i64](3)+Self.Echo[i64](4)
        \\}
        \\U<public>:i64=Below{}.Use()
    );
    try expectLogic(x, "A", true);
    try expectLogic(x, "B", false);
    try expectInt(x, "U", 7);
    try expectRefused(h, "Base:=class{\nHold<protected>[U:type](X:U)<computes>:U{X}\n}\nV:i64=Base{}.Hold[i64](1)", .inaccessible_member, "Hold");
    try expectRefused(h, "I:=interface{\nG<private>[U:type](X:U)<computes>:U{X}\n}", .invalid_interface, "G");
}

test "rfc0081 what a type value is not, and what it cannot do, is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, components ++ "K:castable_subtype(Root)=Leaf", .not_castable, "Leaf");
    try expectRefused(h, components ++ "K:concrete_subtype(Entity)=Ghost", .not_concrete, "Ghost");
    try expectRefused(h, components ++ "K:concrete_subtype(Entity)=Entity", .not_concrete, "Entity");
    try expectRefused(h, components ++ "K:castable_subtype(Component)=Player", .type_mismatch, "Player");
    try expectRefused(h, components ++ "K:subtype(i64)=float", .type_mismatch, "float");
    try expectRefused(h, components ++ "K:castable_subtype(i64)=i64", .unsupported_type, "castable_subtype");
    try expectRefused(h, components ++ "K:subtype(subtype(Entity))=Ghost", .unsupported_type, "subtype");
    // A subtype value holds a class; casting and building need the stronger metatypes.
    try expectRefused(h, components ++ "K:subtype(Component)=Physics\nV:=Attempt(K[Physics{}],Component{})", .not_castable, "[");
    try expectRefused(h, components ++ "K:castable_subtype(Component)=Physics\nF()<allocates>:Component=K{}", .not_concrete, "{");
    try expectRefused(h, components ++ "F(K:concrete_subtype(Entity))<allocates>:Entity=K{Name:=\"x\"}", .not_concrete, "Name");
    // A cast needs a failure context, a construction the effects of its bound.
    try expectRefused(h, components ++ "K:castable_subtype(Component)=Physics\nV:Component=K[Physics{}]", .failure_context_required, "[");
    try expectRefused(h, components ++ "F(K:concrete_subtype(Entity))<computes>:Entity=K{}", .call_requires_allocates, "{");
    // Type values are not compared: two may hold different classes.
    try refused(h, components ++ "K:castable_subtype(Component)=Physics\nV:logic=K==K", .not_comparable);
    // An instantiation is named by its template; it is a type value of no class bound.
    try expectRefused(h, "Root:=class<castable>{}\nBox[T:type]:=class(Root){}\nBi:=Box[i64]\nK:castable_subtype(Bi)=Bi", .unsupported_type, "Bi");
    // A program's own declaration of the name is what the name means.
    const x = try h.execute("subtype:=class{N:i64=4}\nV<public>:i64=subtype{}.N");
    try expectInt(x, "V", 4);
    try refused(h, "subtype:=class{}\nK:subtype(i64)=i64", .expected_equal);
    // A parametric type of the name declared further down names another type.
    const y = try h.execute("K:subtype(i64)=i64\nsubtype[T:type]:=struct{X:T}\nA<public>:i64=subtype[i64]{X:=1}.X");
    try expectInt(y, "A", 1);
}

test "rfc0081 type values cross modules, also when a metatype is first written in a nested module" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Component<public>:=class<castable>{Id<public>:i64=0}
        \\Physics<public>:=class(Component){}
        \\Inner:=module{
        \\    Pick<public>()<computes>:castable_subtype(Component)=Physics
        \\}
        \\Picked<public>()<computes>:castable_subtype(Component)=Inner.Pick()
        \\K<public>:castable_subtype(Component)=Physics
    ;
    const result = bundle(h, "L:=import{\"lib.forb\"}\nusing{L}\nM:castable_subtype(Component)=Physics\nV<public>:logic=Attempt(Block{L.Picked()[Physics{}];L.K[Physics{}];M[Physics{}];true},false)", lib);
    if (result != .ok) {
        std.debug.print("{s}\n", .{result.failed.diagnostic.message()});
        return error.Compile;
    }
    const x = (try h.run(result.ok, 100_000)).ok;
    try expectLogic(x, "V", true);
    // A bound in a nested module that is not public: the witness stays private to its module.
    const nested = bundle(h, "Inner:=module{\nComponent<public>:=class<castable>{Id<public>:i64=0}\n}\nPhysics<public>:=class(Inner.Component){}\nK:castable_subtype(Inner.Component)=Physics\nN<public>:i64=Attempt(Block{K[Physics{}];1},0)", "V<public>:i64=1");
    if (nested != .ok) {
        std.debug.print("{s}\n", .{nested.failed.diagnostic.message()});
        return error.Compile;
    }
    try expectInt((try h.run(nested.ok, 100_000)).ok, "N", 1);
    // A class that is not public has its type values in its own module only.
    const hidden = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=1", "Base<public>:=class<castable>{}\nSecret:=class(Base){}\nK:castable_subtype(Base)=Secret\nUse<public>()<allocates>:logic=Attempt(Block{K[Base{}];true},false)");
    try std.testing.expect(hidden == .ok);
}

test "rfc0081 metatype structs are admitted as the compiler makes them and refused when forged" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(components ++
        \\K:castable_subtype(Component)=Physics
        \\M:concrete_subtype(Entity)=Player
        \\S:subtype(i64)=i64
        \\Pt:=struct{X:i64}
        \\Pv:Pt=Pt{X:=1}
        \\V<public>:logic=Attempt(Block{K[Physics{}];true},false)
    );
    _ = try h.run(p, 100_000);
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    var forged = p;
    forged.definitions = definitions;
    var metatypes: usize = 0;
    for (p.definitions, 0..) |item, index| {
        if (item != .record or item.record.arguments == null) continue;
        const name = item.record.name.text(p.source);
        if (!std.mem.endsWith(u8, name, "subtype")) continue;
        metatypes += 1;
        // Not public, or not marked: no template declares it, so both refuse. (Without its
        // argument and its mark it is a struct a program may declare under that name.)
        definitions[index].record.is_public = false;
        try harness.invalid(h, forged);
        definitions[index] = item;
        definitions[index].record.metatype = false;
        try harness.invalid(h, forged);
        definitions[index] = item;
        definitions[index].record.arguments = null;
        try harness.invalid(h, forged);
        definitions[index] = item;
        // A field of another type: only the test or the construction of the bound travels in one.
        if (item.record.fields.end - item.record.fields.start == 1) {
            const fields = try std.testing.allocator.dupe(types.Field, p.fields);
            defer std.testing.allocator.free(fields);
            var with_fields = forged;
            with_fields.fields = fields;
            for (p.definitions, 0..) |other, at| {
                if (other != .callable and other != .record) continue;
                const candidate: types.Type = @fromBackingInt(@as(u16, @intCast(at + @import("aggregate_types.zig").builtin_count)));
                if (candidate == p.fields[item.record.fields.start].value_type or at >= index) continue;
                fields[item.record.fields.start].value_type = candidate;
                const reference = evaluator.evaluateWithRuntimeStorage(with_fields, &h.values, &h.members, &h.control, &h.state, &h.frames, 0);
                if (reference == .failed and reference.failed.code == .invalid_ir) continue;
                // Only a callable over the bound passes: then both machines run it alike or refuse it.
                try std.testing.expect(other == .callable);
            }
        }
        // Two arguments: a metatype has one.
        for (p.definitions, 0..) |other, at| {
            if (other != .tuple or other.tuple.end - other.tuple.start != 2 or at >= index) continue;
            definitions[index].record.arguments = @fromBackingInt(@as(u16, @intCast(at + @import("aggregate_types.zig").builtin_count)));
            try harness.invalid(h, forged);
            break;
        }
        definitions[index] = item;
    }
    try std.testing.expectEqual(@as(usize, 3), metatypes);
    // A struct of the program marked as a metatype is refused by both.
    for (p.definitions, 0..) |item, index| {
        if (item != .record or item.record.metatype) continue;
        definitions[index].record.metatype = true;
        try harness.invalid(h, forged);
        definitions[index] = item;
    }
}

test "rfc0081 random casts through castable type values agree with a model of the class tree" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x81);
    const random = prng.random();
    // Classes C0..C5: C0 is castable, Ci's parent is a random earlier class.
    for (0..12) |_| {
        var parents: [6]usize = undefined;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "C0:=class<castable>{}\n");
        for (1..6) |i| {
            parents[i] = random.uintLessThan(usize, i);
            try source.print(std.testing.allocator, "C{d}:=class(C{d}){{}}\n", .{ i, parents[i] });
        }
        try source.appendSlice(std.testing.allocator, "Kinds:[]castable_subtype(C0)=array{C0,C1,C2,C3,C4,C5}\n");
        for (0..6) |i| try source.print(std.testing.allocator, "M{d}:C0=C{d}{{}}\n", .{ i, i });
        var expected: [6][6]bool = undefined;
        for (0..6) |value| for (0..6) |kind| {
            var at = value;
            var below = at == kind;
            while (at != 0 and !below) {
                at = parents[at];
                below = at == kind;
            }
            expected[value][kind] = below;
        };
        for (0..6) |value| try source.print(std.testing.allocator, "V{d}<public>:[]logic=For(K:Kinds,Attempt(Block{{K[M{d}];true}},false))\n", .{ value, value });
        const x = try h.execute(source.items);
        for (0..6) |value| {
            var name: [4]u8 = undefined;
            const binding = x.get(try std.fmt.bufPrint(&name, "V{d}", .{value})).?;
            const answers = x.aggregate_values[binding.aggregate.elements.start..binding.aggregate.elements.end];
            for (answers, 0..) |answer, kind| try std.testing.expectEqual(expected[value][kind], answer.boolean);
        }
    }
}

// ---- castable_concrete_subtype (TASK-0109, B8)

const pair_classes =
    \\Base:=class<castable>{N:i64=1}
    \\Kid:=class<castable><concrete>(Base){N<override>:i64=2}
    \\Kid2:=class<castable><concrete>(Base){N<override>:i64=3}
    \\Odd:=class<castable>(Base){}
    \\Free:=class{}
    \\FreeKid:=class<concrete>(Free){}
    \\Pair:=castable_concrete_subtype(Base)
    \\
;

test "b8 a castable_concrete_subtype value casts and builds, wherever a metatype may stand" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(pair_classes ++
        \\K:Pair=Kid
        \\Make(M:castable_concrete_subtype(Base))<allocates>:Base=M{}
        \\Is(X:Base,M:castable_concrete_subtype(Base))<computes>:logic=Attempt(Block{M[X];true},false)
        \\A<public>:i64=Make(K).N
        \\B<public>:logic=Is(Kid{},K)
        \\Rc<public>:logic=Is(Kid2{},K)
        \\D<public>:logic=Is(Make(K),K)
        \\E<public>:logic=Is(Odd{},K)
        \\Holder:=class{
        \\    Kind:castable_concrete_subtype(Base)
        \\    Spawn()<reads><allocates>:Base=Self.Kind{}
        \\}
        \\F<public>:i64=Holder{Kind:=Kid2}.Spawn().N
        \\Pick(S:string)<computes>:castable_concrete_subtype(Base)=If(S=="a",Kid,Kid2)
        \\G<public>:i64=Make(Pick("b")).N
        \\Many:[]castable_concrete_subtype(Base)=array{Kid,Kid2,Kid}
        \\H<public>:[]i64=For(M:Many,Make(M).N)
        \\Ri<public>:[]logic=For(M:Many,Is(Kid2{},M))
        \\var Saved:castable_concrete_subtype(Base)=Kid
        \\Swap()<transacts><decides>:void=Block{set Saved=Kid2;Require[1>2]}
        \\Undone<public>:logic=Attempt(Block{Swap[];true},false)
        \\J<public>:i64=Make(Saved).N
        \\Cast[T:castable_concrete_subtype(Base)](C:Base)<computes><decides>:T{T[C]}
        \\Build[T:castable_concrete_subtype(Base)]()<allocates>:T{T{}}
        \\Handler[T:castable_concrete_subtype(Base)]:=class{
        \\    Handle(C:Base)<reads><allocates>:i64=Attempt(Block{T[C].N},Build[T]().N*10)
        \\}
        \\Rl<public>:i64=Attempt(Cast[Kid][Kid{}].N,0-1)
        \\Rm<public>:i64=Attempt(Cast[Kid2][Kid{}].N,0-1)
        \\Rn<public>:i64=Build[Kid2]().N
        \\Ro<public>:i64=Handler[Kid]{}.Handle(Kid{})*100+Handler[Kid]{}.Handle(Kid2{})
    );
    try expectInt(x, "A", 2);
    try expectLogic(x, "B", true);
    try expectLogic(x, "Rc", false);
    try expectLogic(x, "D", true);
    try expectLogic(x, "E", false);
    try expectInt(x, "F", 3);
    try expectInt(x, "G", 3);
    try expectInts(x, "H", &.{ 2, 3, 2 });
    const cast = x.get("Ri").?;
    const answers = x.aggregate_values[cast.aggregate.elements.start..cast.aggregate.elements.end];
    try std.testing.expectEqual(@as(usize, 3), answers.len);
    try std.testing.expect(!answers[0].boolean and answers[1].boolean and !answers[2].boolean);
    try expectLogic(x, "Undone", false);
    try expectInt(x, "J", 2);
    try expectInt(x, "Rl", 2);
    try expectInt(x, "Rm", -1);
    try expectInt(x, "Rn", 3);
    try expectInt(x, "Ro", 2 * 100 + 20);
}

test "b8 castable_concrete_subtype asks for both a castable and a concrete class" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(Base)=Odd", .not_concrete, "Odd");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(Base)=Base", .not_concrete, "Base");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(Free)=FreeKid", .not_castable, "FreeKid");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(Free)=Free", .not_castable, "Free");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(Base)=Free", .type_mismatch, "Free");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(i64)=i64", .unsupported_type, "castable_concrete_subtype");
    try expectRefused(h, pair_classes ++ "K:castable_concrete_subtype(castable_concrete_subtype(Base))=Kid", .unsupported_type, "castable_concrete_subtype");
    // As a bound the same two rules hold, each with its own code.
    const generic = pair_classes ++ "Build[T:castable_concrete_subtype(Base)]()<allocates>:T{T{}}\n";
    try expectRefused(h, generic ++ "V:=Build[Odd]()", .not_concrete, "Build");
    try expectRefused(h, generic ++ "V:=Build[Base]()", .not_concrete, "Build");
    try expectRefused(h, generic ++ "V:=Build[i64]()", .type_argument_bound, "Build");
    try expectRefused(h, pair_classes ++ "Free2[T:castable_concrete_subtype(Free)]:=class{}\nV:=Free2[FreeKid]{}", .not_castable, "Free2");
    // What the value can do is what the Book allows: a cast needs a failure context, a
    // construction the effects of its bound and nothing in its braces.
    try expectRefused(h, pair_classes ++ "K:Pair=Kid\nV:Base=K[Kid{}]", .failure_context_required, "[");
    try expectRefused(h, pair_classes ++ "F(K:Pair)<computes>:Base=K{}", .call_requires_allocates, "{");
    try expectRefused(h, pair_classes ++ "F(K:Pair)<allocates>:Base=K{N:=4}", .not_concrete, "N");
    try refused(h, pair_classes ++ "K:Pair=Kid\nV:logic=K==K", .not_comparable);
    // A value of one metatype is not a value of another: types stay exact (RFC-0067 D8).
    try refused(h, pair_classes ++ "K:Pair=Kid\nC:castable_subtype(Base)=K", .type_mismatch);
    try refused(h, pair_classes ++ "K:Pair=Kid\nC:concrete_subtype(Base)=K", .type_mismatch);
    try refused(h, pair_classes ++ "K:castable_subtype(Base)=Kid\nC:Pair=K", .type_mismatch);
    // The name yields to a program's own declaration of it.
    const own = try h.execute("castable_concrete_subtype:=class{N:i64=4}\nV<public>:i64=castable_concrete_subtype{}.N");
    try expectInt(own, "V", 4);
}

test "b8 castable_concrete_subtype values cross modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Base<public>:=class<castable>{N<public>:i64=1}
        \\Kid<public>:=class<castable><concrete>(Base){N<override><public>:i64=2}
        \\Hidden:=class<castable><concrete>(Base){}
        \\Inner:=module{
        \\    Pick<public>()<computes>:castable_concrete_subtype(Base)=Kid
        \\}
        \\Picked<public>()<computes>:castable_concrete_subtype(Base)=Inner.Pick()
        \\K<public>:castable_concrete_subtype(Base)=Kid
        \\Own<public>()<reads><allocates>:i64=Block{M:castable_concrete_subtype(Base)=Hidden;X:Base=M{};X.N}
    ;
    const result = bundle(h, "L:=import{\"lib.forb\"}\nusing{L}\nM:castable_concrete_subtype(Base)=Kid\nMake(Q:castable_concrete_subtype(Base))<allocates>:Base=Q{}\nV<public>:i64=Make(Picked()).N*100+Make(K).N*10+Make(M).N+L.Own()*1000", lib);
    if (result != .ok) {
        std.debug.print("{s}\n", .{result.failed.diagnostic.message()});
        return error.Compile;
    }
    const x = (try h.run(result.ok, 100_000)).ok;
    try expectInt(x, "V", 1000 + 200 + 20 + 2);
}

test "b8 castable_concrete_subtype structs are admitted as the compiler makes them and refused when forged" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(pair_classes ++
        \\K:Pair=Kid
        \\C:concrete_subtype(Base)=Kid
        \\V<public>:logic=Attempt(Block{K[Kid{}];true},false)
    );
    _ = try h.run(p, 100_000);
    const aggregate = @import("aggregate_types.zig");
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    const fields = try std.testing.allocator.dupe(types.Field, p.fields);
    defer std.testing.allocator.free(fields);
    var forged = p;
    forged.definitions = definitions;
    forged.fields = fields;
    var pair: ?usize = null;
    var single: ?usize = null;
    for (p.definitions, 0..) |item, index| {
        if (item != .record or !item.record.metatype) continue;
        const name = item.record.name.text(p.source);
        if (std.mem.eql(u8, name, "castable_concrete_subtype")) pair = index;
        if (std.mem.eql(u8, name, "concrete_subtype")) single = index;
    }
    const at = pair.?;
    const item = p.definitions[at];
    const first = item.record.fields.start;
    try std.testing.expectEqual(@as(u32, 2), item.record.fields.end - first);
    // Not public, not marked, no argument: no template declares it.
    definitions[at].record.is_public = false;
    try harness.invalid(h, forged);
    definitions[at] = item;
    definitions[at].record.metatype = false;
    try harness.invalid(h, forged);
    definitions[at] = item;
    definitions[at].record.arguments = null;
    try harness.invalid(h, forged);
    definitions[at] = item;
    // One field, or none: the pair holds the test and the construction.
    definitions[at].record.fields.end = first + 1;
    try harness.invalid(h, forged);
    definitions[at].record.fields.end = first;
    try harness.invalid(h, forged);
    definitions[at] = item;
    // The test is first and the construction second; the other way round is refused.
    const test_type = p.fields[first].value_type;
    const make_type = p.fields[first + 1].value_type;
    fields[first].value_type = make_type;
    fields[first + 1].value_type = test_type;
    try harness.invalid(h, forged);
    // Two tests, or two constructions.
    fields[first + 1].value_type = test_type;
    fields[first].value_type = test_type;
    try harness.invalid(h, forged);
    fields[first + 1].value_type = make_type;
    fields[first].value_type = make_type;
    try harness.invalid(h, forged);
    fields[first] = p.fields[first];
    fields[first + 1] = p.fields[first + 1];
    // A field of another name, or a `var` one: only the value travels in a metatype.
    fields[first + 1].name = p.fields[first + 1].name;
    fields[first + 1].name.start += 1;
    try harness.invalid(h, forged);
    fields[first + 1] = p.fields[first + 1];
    fields[first].is_var = true;
    try harness.invalid(h, forged);
    fields[first] = p.fields[first];
    // A field of a type that is no callable of the bound.
    for (p.definitions, 0..) |other, candidate| {
        if (other == .callable or candidate >= at) continue;
        fields[first].value_type = @fromBackingInt(@as(u16, @intCast(candidate + aggregate.builtin_count)));
        try harness.invalid(h, forged);
    }
    fields[first] = p.fields[first];
    // The word is what tells a pair from a single: a pair named as `concrete_subtype` has one
    // field too many, and a single named as the pair has one too few.
    definitions[at].record.name = p.definitions[single.?].record.name;
    try harness.invalid(h, forged);
    definitions[at] = item;
    definitions[single.?].record.name = item.record.name;
    try harness.invalid(h, forged);
    definitions[single.?] = p.definitions[single.?];
    // Unforged again, both machines accept it.
    _ = try h.run(forged, 100_000);
}

test "b8 random castable_concrete_subtype values agree with a model of the class tree" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xb8);
    const random = prng.random();
    // Classes C0..C5, each castable and concrete: Ci's parent is a random earlier class.
    for (0..12) |_| {
        var parents: [6]usize = undefined;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "C0:=class<castable><concrete>{Id:i64=0}\n");
        for (1..6) |i| {
            parents[i] = random.uintLessThan(usize, i);
            try source.print(std.testing.allocator, "C{d}:=class<castable><concrete>(C{d}){{Id<override>:i64={d}}}\n", .{ i, parents[i], i });
        }
        try source.appendSlice(std.testing.allocator, "Kinds:[]castable_concrete_subtype(C0)=array{C0,C1,C2,C3,C4,C5}\n");
        try source.appendSlice(std.testing.allocator, "Build(K:castable_concrete_subtype(C0))<allocates>:C0=K{}\n");
        try source.appendSlice(std.testing.allocator, "Built<public>:[]i64=For(K:Kinds,Build(K).Id)\n");
        for (0..6) |i| try source.print(std.testing.allocator, "M{d}:C0=C{d}{{}}\n", .{ i, i });
        var expected: [6][6]bool = undefined;
        for (0..6) |value| for (0..6) |kind| {
            var at = value;
            var below = at == kind;
            while (at != 0 and !below) {
                at = parents[at];
                below = at == kind;
            }
            expected[value][kind] = below;
        };
        for (0..6) |value| try source.print(std.testing.allocator, "V{d}<public>:[]logic=For(K:Kinds,Attempt(Block{{K[M{d}];true}},false))\n", .{ value, value });
        // What a value built through a type value is, cast through the same value.
        try source.appendSlice(std.testing.allocator, "Again<public>:[]logic=For(K:Kinds,Attempt(Block{K[Build(K)];true},false))\n");
        const x = try h.execute(source.items);
        try expectInts(x, "Built", &.{ 0, 1, 2, 3, 4, 5 });
        for (0..6) |value| {
            var name: [4]u8 = undefined;
            const binding = x.get(try std.fmt.bufPrint(&name, "V{d}", .{value})).?;
            const answers = x.aggregate_values[binding.aggregate.elements.start..binding.aggregate.elements.end];
            for (answers, 0..) |answer, kind| try std.testing.expectEqual(expected[value][kind], answer.boolean);
        }
        const round = x.aggregate_values[x.get("Again").?.aggregate.elements.start..x.get("Again").?.aggregate.elements.end];
        for (round) |answer| try std.testing.expect(answer.boolean);
    }
}

// ---- SortBy

test "rfc0081 SortBy is a stable merge sort through a failable comparison" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Less(A:i64,B:i64)<computes><decides>:void=Require[A<B]
        \\Xs<public>:[]i64=SortBy(array{5,3,9,1,3,7,2,8,6,4,0},Less)
        \\P:=struct{K:i64,V:i64}
        \\ByK(A:P,B:P)<computes><decides>:void=Require[A.K<B.K]
        \\Ps:[]P=SortBy(array{P{K:=2,V:=0},P{K:=1,V:=1},P{K:=2,V:=2},P{K:=1,V:=3},P{K:=0,V:=4}},ByK)
        \\Vs<public>:[]i64=For(Q:Ps,Q.V)
        \\Empty:[]i64=array{}
        \\E<public>:[]i64=SortBy(Empty,Less)
        \\One<public>:[]i64=SortBy(array{4},Less)
        \\Desc<public>:[]i64=SortBy(array{1,2,3,4,5},Fn(A:i64,B:i64)<computes><decides>:void{Require[A>B]})
        \\Never<public>:[]i64=SortBy(array{3,1,2},Fn(A:i64,B:i64)<computes><decides>:void{Require[1>2]})
    );
    try expectInts(x, "Xs", &.{ 0, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9 });
    try expectInts(x, "Vs", &.{ 4, 1, 3, 0, 2 });
    try expectInts(x, "E", &.{});
    try expectInts(x, "One", &.{4});
    try expectInts(x, "Desc", &.{ 5, 4, 3, 2, 1 });
    // A comparison that never succeeds leaves every element where it was.
    try expectInts(x, "Never", &.{ 3, 1, 2 });
}

test "rfc0081 a comparison that fails undoes its writes, one that succeeds keeps them, an error ends the run" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Calls:i64=0
        \\var Kept:i64=0
        \\Less(A:i64,B:i64)<transacts><decides>:void=Block{set Calls=Calls+1;set Kept=Kept+1;Require[A<B]}
        \\Run()<transacts>:[]i64=SortBy(array{2,1,4,3},Less)
        \\Xs<public>:[]i64=Run()
        \\AllCalls<public>:i64=Calls
        \\Successes<public>:i64=Kept
    );
    try expectInts(x, "Xs", &.{ 1, 2, 3, 4 });
    // Every call was undone but the ones that succeeded, so the counters agree.
    try expectInt(x, "AllCalls", x.get("Successes").?.integer);
    try std.testing.expect(x.get("AllCalls").?.integer > 0);
    const p = try h.compile(
        \\Less(A:i64,B:i64)<computes><decides>:void=Block{Require[A/(A-A)<B]}
        \\Xs<public>:[]i64=SortBy(array{2,1},Less)
    );
    const result = try h.run(p, 100_000);
    try std.testing.expect(result == .failed and result.failed.code == .division_by_zero);
}

test "rfc0081 SortBy is the standard function only where the program does not use the name" {
    const h = try harness.create();
    defer scratch.release(h);
    // The program's own function of the name is what every use means.
    const x = try h.execute("SortBy(A:[]i64,B:i64)<computes>:i64=A.Length+B\nV<public>:i64=SortBy(array{1,2},40)");
    try expectInt(x, "V", 42);
    const y = try h.execute("F(SortBy:function(tuple(i64,i64),i64))<computes>:i64=SortBy(1,2)\nV<public>:i64=F(Fn(A:i64,B:i64)<computes>:i64{A+B})");
    try expectInt(y, "V", 3);
    try expectRefused(h, "Less(A:i64,B:i64)<computes><decides>:void=Require[A<B]\nV:[]i64=SortBy(array{1})", .argument_count, "SortBy");
    // The items are an array: a map or a string is not one.
    try refused(h, "Less(A:i64,B:i64)<computes><decides>:void=Require[A<B]\nM:map(string,i64)=map{\"z\"=>9}\nV:[]i64=SortBy(M,Less)", .type_mismatch);
    try refused(h, "Less(A:char,B:char)<computes><decides>:void=Require[A<B]\nV:[]char=SortBy(\"ba\",Less)", .type_mismatch);
    try expectRefused(h, "Less(A:i64,B:i64)<computes>:logic=A<B\nV:[]i64=SortBy(array{2,1},Less)", .expected_call, "SortBy");
    try expectRefused(h, "Less(A:i64,B:i64)<computes><decides>:void=Require[A<B]\nV:[]i64=SortBy(array{2,1},Less:=Less)", .unknown_parameter, "Less");
    // An effectful comparison needs the effects where the sort runs: a function that lacks them
    // is refused, and the root has them, as its loops do since `fix2` (RFC-0079).
    try expectRefused(h, "var C:i64=0\nLess(A:i64,B:i64)<transacts><decides>:void=Block{set C=1;Require[A<B]}\nF()<computes>:[]i64=SortBy(array{2,1},Less)", .call_requires_transacts, "SortBy");
    const z = try h.execute("var C:i64=0\nLess(A:i64,B:i64)<transacts><decides>:void=Block{set C=C+1;Require[A<B]}\nV<public>:[]i64=SortBy(array{2,1},Less)\nN<public>:i64=C");
    try std.testing.expect(z.get("N").?.integer > 0);
}

test "rfc0081 random arrays sort as a stable sort in Zig sorts them" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5017);
    const random = prng.random();
    for (0..40) |_| {
        // The bootstrap profile's call steps bound the arrays; `program_profile_tests` sorts large ones.
        const n = random.uintLessThan(usize, 14);
        var keys: [40]i64 = undefined;
        var order: [40]usize = undefined;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "P:=struct{K:i64,I:i64}\nLess(A:P,B:P)<computes><decides>:void=Require[A.K<B.K]\nXs:[]P=array{");
        for (0..n) |i| {
            keys[i] = random.intRangeAtMost(i64, 0, 6);
            order[i] = i;
            try source.print(std.testing.allocator, "{s}P{{K:={d},I:={d}}}", .{ if (i == 0) "" else ",", keys[i], i });
        }
        try source.appendSlice(std.testing.allocator, "}\nSorted<public>:[]i64=For(Q:SortBy(Xs,Less),Q.I)\n");
        const Context = struct {
            keys: []const i64,
            fn less(context: @This(), a: usize, b: usize) bool {
                return context.keys[a] < context.keys[b];
            }
        };
        std.sort.insertion(usize, order[0..n], Context{ .keys = keys[0..n] }, Context.less);
        const x = try h.execute(source.items);
        const expected = try std.testing.allocator.alloc(i64, n);
        defer std.testing.allocator.free(expected);
        for (order[0..n], expected) |index, *slot| slot.* = @intCast(index);
        try expectInts(x, "Sorted", expected);
    }
}

// ---- Function types

test "rfc0081 a function type alias may name effects, and a cast out of any takes a function with fewer" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Wide:=function<transacts>(tuple(i64),i64)
        \\Maybe:=function<computes><decides>(tuple(i64),i64)
        \\Exact:=function<computes>(tuple(i64),i64)
        \\Reads:=function<reads>(tuple(i64),i64)
        \\Twice(N:i64)<computes>:i64=N*2
        \\var C:i64=1
        \\Peek(N:i64)<reads>:i64=N+C
        \\Held:any=any(Twice)
        \\Seen:any=any(Peek)
        \\Run(V:any)<transacts>:i64=Attempt(Wide[V](20),0-1)
        \\A<public>:i64=Run(Held)+Run(Seen)*100
        \\B<public>:i64=Attempt(Exact[Held](21),0-1)
        \\M<public>:i64=Attempt(Maybe[Held][4],0-1)
        \\NotNarrower<public>:i64=Attempt(Exact[Seen](1),0-1)
        \\K(V:any)<computes>:i64=Case(V,F:Exact=>1,G:Reads=>2,_=>3)
        \\Kinds<public>:[]i64=array{K(Held),K(Seen),K(any(5))}
        \\Through(F:Wide)<transacts>:i64=F(1)
        \\T<public>:i64=Through(Twice)
    );
    try expectInt(x, "A", 40 + 21 * 100);
    try expectInt(x, "B", 42);
    try expectInt(x, "M", 8);
    try expectInt(x, "NotNarrower", -1);
    try expectInts(x, "Kinds", &.{ 1, 2, 3 });
    try expectInt(x, "T", 2);
    // A function value out of a cast has the type it was cast to, as an upcast gives it.
    const p = try h.compile("Wide:=function<transacts>(tuple(i64),i64)\nTwice(N:i64)<computes>:i64=N*2\nH:any=any(Twice)\nW<public>:Wide=Attempt(Wide[H],Fn(N:i64)<transacts>:i64{0})");
    const run = (try h.run(p, 100_000)).ok;
    try std.testing.expectEqual(p.nodes[p.bindings[p.bindings.len - 1].node].value_type, run.get("W").?.callable.value_type);
}
