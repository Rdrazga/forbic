//! Classes completion (RFC-0092, B4): override results that narrow, override access that
//! narrows, `<final_super>` hierarchies and `GetCastableFinalSuperClass`, `Super{...}`
//! construction, and effects on structs. Every program runs on both machines (`harness.run`
//! holds them to the same values, steps, cells and reports, and replays both reports).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

const Code = types.Diagnostic.Code;

fn run(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const result = try h.run(try h.compile(source), 400_000);
    if (result == .failed) {
        std.debug.print("run failed: {s}\n", .{result.failed.message()});
        return error.Execute;
    }
    return result.ok;
}

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value != .integer or value.integer != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectLogic(x: evaluator.Execution, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse return error.Missing;
    try std.testing.expectEqual(expected, value.boolean);
}

fn expectText(x: evaluator.Execution, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse return error.Missing;
    try std.testing.expectEqualStrings(expected, value.string);
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

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

// ---- Override results that narrow (Book 10:478)

const producers =
    \\base_type:=class{Name:string}
    \\derived_type:=class(base_type){Value:i64=0}
    \\producer:=class{Create()<reads><allocates>:base_type=base_type{Name:="base"}}
    \\sub_producer:=class(producer){
    \\  Create<override>()<reads><allocates>:derived_type=derived_type{Name:="{Super.Create().Name} refined",Value:=42}
    \\}
    \\deeper:=class(sub_producer){Create<override>()<reads><allocates>:derived_type=derived_type{Name:="deep",Value:=7}}
;

test "an override narrows its result: the subclass sees the narrower type, the base reaches the override" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, producers ++
        \\
        \\V:i64=sub_producer{}.Create().Value
        \\P:producer=sub_producer{}
        \\N:string=P.Create().Name
        \\D:producer=deeper{}
        \\DN:string=D.Create().Name
        \\DS:sub_producer=deeper{}
        \\DV:i64=DS.Create().Value
        \\M:=DS.Create
        \\MV:i64=M().Value
        \\Wide:=P.Create
        \\WN:string=Wide().Name
    );
    // The Book's example: the caller that knows the subclass sees `Value`; through the base,
    // dispatch reaches the override, whose `Super.Create()` is the parent's.
    try expectInt(x, "V", 42);
    try expectText(x, "N", "base refined");
    try expectText(x, "DN", "deep");
    try expectInt(x, "DV", 7);
    try expectInt(x, "MV", 7);
    try expectText(x, "WN", "base refined");
    // One slot for `producer`, one for the narrower result of `sub_producer`; `deeper` fills both.
    try std.testing.expectEqual(@as(usize, 2), x.program.slots.len);
}

test "a narrowed result fills an interface slot, an inherited method narrows one, and any holds anything" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\animal:=class{Name:string="a"}
        \\dog:=class(animal){Tricks:i64=3}
        \\maker:=interface{Make()<allocates>:animal}
        \\kennel:=class(maker){Make<override>()<allocates>:dog=dog{}}
        \\holder:=class{Make()<allocates>:dog=dog{Tricks:=5}}
        \\both:=class(holder,maker){}
        \\base:=class{Get()<computes>:any=any(1)}
        \\sub:=class(base){Get<override>()<computes>:i64=5}
        \\M:maker=kennel{}
        \\A:animal=M.Make()
        \\T:i64=kennel{}.Make().Tricks
        \\H:maker=both{}
        \\HT:i64=Attempt(dog[H.Make()].Tricks,-1)
        \\BT:i64=both{}.Make().Tricks
        \\B:base=sub{}
        \\G:any=B.Get()
        \\S:i64=sub{}.Get()+1
    );
    try expectInt(x, "T", 3);
    try expectInt(x, "HT", 5);
    try expectInt(x, "BT", 5);
    try expectInt(x, "S", 6);
}

test "a class that narrows several results among other methods keeps every body with its declaration" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\animal:=class{N:i64=1}
        \\dog:=class(animal){}
        \\base:=class{
        \\  One()<allocates>:animal=animal{N:=1}
        \\  Plain()<computes>:i64=10
        \\  Two()<allocates>:animal=animal{N:=2}
        \\}
        \\sub:=class(base){
        \\  One<override>()<allocates>:dog=dog{N:=3}
        \\  Plain<override>()<computes>:i64=20
        \\  Two<override>()<allocates>:dog=dog{N:=4}
        \\  Own()<computes>:i64=30
        \\}
        \\B:base=sub{}
        \\V:i64=Block{A:=B.One();C:=B.Two();1}+B.Plain()+sub{}.Own()
        \\D:i64=Attempt(dog[B.One()].N*10+dog[B.Two()].N,-1)
    );
    try expectInt(x, "V", 1 + 20 + 30);
    try expectInt(x, "D", 34);
    try std.testing.expectEqual(@as(usize, 6), x.program.slots.len);
}

test "abstract and final overrides narrow too, and a final narrowed method seals its new slot" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\shape:=class{Size:i64=1}
        \\square:=class(shape){Side:i64=2}
        \\maker:=class<abstract>{Make<abstract>()<allocates>:shape}
        \\squares:=class<abstract>(maker){Make<override><abstract>()<allocates>:square}
        \\tiles:=class(squares){Make<override><final>()<allocates>:square=square{Side:=4}}
        \\M:maker=tiles{}
        \\S:i64=Attempt(square[M.Make()].Side,-1)
        \\Q:squares=tiles{}
        \\Q2:i64=Q.Make().Side
    );
    try expectInt(x, "S", 4);
    try expectInt(x, "Q2", 4);
    try expectRefused(h,
        \\shape:=class{Size:i64=1}
        \\square:=class(shape){Side:i64=2}
        \\maker:=class{Make()<allocates>:shape=shape{}}
        \\tiles:=class(maker){Make<override><final>()<allocates>:square=square{}}
        \\more:=class(tiles){Make<override>()<allocates>:square=square{}}
    , .final_method, "Make");
}

test "an override that widens or changes its result, or one of an interface, is override_mismatch" {
    const h = try harness.create();
    defer scratch.release(h);
    const classes =
        \\animal:=class{Name:string="a"}
        \\dog:=class(animal){}
        \\cat:=class(animal){}
        \\
    ;
    // Wider: the Book's error 3532.
    try expectRefused(h, classes ++ "p:=class{Make()<allocates>:dog=dog{}}\ns:=class(p){Make<override>()<allocates>:animal=animal{}}", .override_mismatch, "Make");
    // Unrelated.
    try expectRefused(h, classes ++ "p:=class{Make()<allocates>:dog=dog{}}\ns:=class(p){Make<override>()<allocates>:cat=cat{}}", .override_mismatch, "Make");
    // Containers stay invariant (RFC-0067 D8).
    try expectRefused(h, classes ++ "p:=class{Make()<allocates>:[]animal=array{}}\ns:=class(p){Make<override>()<allocates>:[]dog=array{}}", .override_mismatch, "Make");
    // Parameters stay exact.
    try expectRefused(h, classes ++ "p:=class{Take(A:animal)<computes>:i64=1}\ns:=class(p){Take<override>(A:dog)<computes>:i64=2}", .override_mismatch, "Take");
    // An interface that extends another keeps its methods' results.
    try expectRefused(h, classes ++ "i:=interface{Make()<allocates>:animal}\nj:=interface(i){Make<override>()<allocates>:dog}", .override_mismatch, "Make");
    // A class declared later is not known to lie below the result yet.
    try expectRefused(h, "animal:=class{}\np:=class{Make()<allocates>:animal=animal{}}\ns:=class(p){Make<override>()<allocates>:dog=dog{}}\ndog:=class(animal){}", .override_mismatch, "Make");
    // `any` takes no refinement or task.
    try expectRefused(h, "small:=type{_X:i64 where 0<=_X,_X<=9}\np:=class{Get()<computes>:any=any(1)}\ns:=class(p){Get<override>()<computes>:small=small[3]}", .override_mismatch, "Get");
    // Effects may still only narrow, whatever the result does.
    try expectRefused(h, classes ++ "p:=class{Make()<allocates>:animal=animal{}}\ns:=class(p){Make<override>()<reads><allocates>:dog=dog{}}", .override_widens_reads, "Make");
    // An inherited method that stands in for an interface's must narrow, not widen.
    try expectRefused(h, classes ++ "i:=interface{Make()<allocates>:dog}\nh:=class{Make()<allocates>:animal=animal{}}\nb:=class(h,i){}", .duplicate_name, "b");
}

test "a narrowed override keeps the effects of its slot, so a caller through the subclass needs them" {
    const h = try harness.create();
    defer scratch.release(h);
    // The new slot has the parent's effects: `<reads><allocates>`, not the override's narrower set.
    try expectRefused(h,
        \\animal:=class{}
        \\dog:=class(animal){}
        \\p:=class{Make()<reads><allocates>:animal=animal{}}
        \\s:=class(p){Make<override>()<allocates>:dog=dog{}}
        \\F(S:s)<allocates>:dog=S.Make()
    , .call_requires_reads, "(");
}

// ---- Override access that narrows (Book 12:385)

test "an override may narrow its access: through its class the narrower access holds, through the base the slot's" {
    const h = try harness.create();
    defer scratch.release(h);
    const chain =
        \\base:=class{Value<public>()<computes>:i64=1}
        \\mid:=class(base){Value<override><protected>()<computes>:i64=2}
        \\low:=class(mid){
        \\  Value<override>()<computes>:i64=Super.Value()+10
        \\  Twice()<computes>:i64=Self.Value()*2
        \\}
        \\
    ;
    const x = try run(h, chain ++ "B:base=low{}\nX:i64=B.Value()\nY:i64=low{}.Twice()");
    try expectInt(x, "X", 12);
    try expectInt(x, "Y", 24);
    // Through `mid` and through `low`, which inherits the narrowing without restating it.
    try expectRefused(h, chain ++ "Y:i64=mid{}.Value()", .inaccessible_member, "Value");
    try expectRefused(h, chain ++ "Y:i64=low{}.Value()", .inaccessible_member, "Value");
    // Widening back, and `internal` and `protected`, which are not ordered, stay mismatches.
    try expectRefused(h, chain ++ "top:=class(low){Value<override><public>()<computes>:i64=3}", .override_mismatch, "Value");
    try expectRefused(h, "base:=class{Value()<computes>:i64=1}\nmid:=class(base){Value<override><protected>()<computes>:i64=2}", .override_mismatch, "Value");
    // Narrowed to private, nothing below may replace it.
    try expectRefused(h, "base:=class{Value<public>()<computes>:i64=1}\nmid:=class(base){Value<override><private>()<computes>:i64=2}\nlow:=class(mid){Value<override>()<computes>:i64=3}", .inaccessible_member, "Value");
    // Narrowing and a narrower result together: the new slot has the narrowed access.
    try expectRefused(h, "animal:=class{}\ndog:=class(animal){}\np:=class{Make<public>()<allocates>:animal=animal{}}\ns:=class(p){Make<override><internal>()<allocates>:dog=dog{}}\nq:=class(s){Make<override><public>()<allocates>:dog=dog{}}", .override_mismatch, "Make");
}

test "an override narrowed to internal is refused to another module and allowed in its own" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\base<public>:=class{Value<public>()<computes>:i64=1}
        \\mid<public>:=class(base){Value<override><internal>()<computes>:i64=2}
        \\Own<public>:i64=mid{}.Value()
        \\Make<public>()<allocates>:mid=mid{}
    ;
    const ok = bundle(h, "L:=import{\"lib.forb\"}\nB:L.base=L.Make()\nV<public>:i64=B.Value()+L.Own", lib);
    if (ok != .ok) {
        std.debug.print("{s}\n", .{ok.failed.diagnostic.message()});
        return error.Compile;
    }
    const x = (try h.run(ok.ok, 100_000)).ok;
    try expectInt(x, "V", 4);
    const refused = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=L.Make().Value()", lib);
    try std.testing.expect(refused == .failed and refused.failed.diagnostic.code == .internal_member);
}

// ---- `Super{...}` (Book 10:376)

test "Super{...} builds a new instance of the superclass, which a parent method call does not" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\tagged:=class{
        \\  var Tag:string="original"
        \\  Describe()<transacts>:string="[{Self.Tag}]"
        \\}
        \\call_parent:=class(tagged){Describe<override>()<transacts>:string="call {Super.Describe()}"}
        \\build_parent:=class(tagged){
        \\  Describe<override>()<transacts>:string="build {Super{}.Describe()}"
        \\  Fresh()<allocates>:tagged=Super{Tag:="given"}
        \\}
        \\A:tagged=call_parent{}
        \\set A.Tag="updated"
        \\B:build_parent=build_parent{}
        \\set B.Tag="updated"
        \\RA:string=A.Describe()
        \\RB:string=B.Describe()
        \\F:tagged=B.Fresh()
        \\RF:string=F.Tag
        \\Kept:logic=Attempt(Block{tagged[F];build_parent[F];true},false)
        \\Undone:i64=Attempt(Block{G:=B.Fresh();Require[G.Tag=="other"];1},2)
    );
    try expectText(x, "RA", "call [updated]");
    try expectText(x, "RB", "build [original]");
    try expectText(x, "RF", "given");
    // The new instance is of the superclass, not of the class that built it.
    try expectLogic(x, "Kept", false);
    try expectInt(x, "Undone", 2);
}

test "Super{...} keeps the rules of building the superclass and yields to a program's own Super" {
    const h = try harness.create();
    defer scratch.release(h);
    // Abstract, without a superclass, without `<allocates>`, a field the superclass lacks.
    try expectRefused(h, "a:=class<abstract>{}\nb:=class(a){Make()<allocates>:a=Super{}}", .abstract_instance, "Super");
    try expectRefused(h, "b:=class{Make()<allocates>:b=Super{}}", .invalid_parent, "Super");
    try expectRefused(h, "a:=class{}\nb:=class(a){Make()<computes>:a=Super{}}", .construction_requires_allocates, "Super");
    try expectRefused(h, "a:=class{X:i64=0}\nb:=class(a){Y:i64=0\n  Make()<allocates>:a=Super{Y:=1}}", .unknown_field, "Y");
    // Outside a method `Super` names nothing, as before.
    try expectRefused(h, "a:=class{}\nb:=class(a){}\nX:=Super{}", .unknown_name, "Super");
    // A class the program names `Super` keeps its meaning in a method too.
    const x = try run(h,
        \\Super:=class{N:i64=7}
        \\a:=class{N:i64=1}
        \\b:=class(a){Make()<allocates>:Super=Super{}}
        \\V:i64=b{}.Make().N
    );
    try expectInt(x, "V", 7);
}

// ---- Effects on structs (Book 13:724)

test "struct<E> states what building one needs" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\vector:=struct<computes>{X:i64=1,Y:i64=2}
        \\logged:=struct<reads>{N:i64=3}
        \\heavy:=struct<transacts>{N:i64=4}
        \\Pure(A:i64)<computes>:vector=vector{X:=A}
        \\Look()<reads>:logged=logged{}
        \\All()<transacts>:heavy=heavy{}
        \\Box[T:type]:=struct<reads>{V:T}
        \\Boxed()<reads>:Box[i64]=Box[i64]{V:=5}
        \\Root:logged=logged{N:=9}
        \\V:i64=Pure(5).X+Look().N+All().N+Boxed().V+Root.N
    );
    try expectInt(x, "V", 5 + 3 + 4 + 5 + 9);
    try expectRefused(h, "logged:=struct<reads>{N:i64=3}\nF()<computes>:logged=logged{}", .struct_effect_required_reads, "logged");
    try expectRefused(h, "heavy:=struct<transacts>{N:i64=4}\nF()<reads>:heavy=heavy{}", .struct_effect_required_writes, "heavy");
    try expectRefused(h, "heavy:=struct<writes><allocates>{N:i64=4}\nF()<writes>:heavy=heavy{}", .struct_effect_required_allocates, "heavy");
    try expectRefused(h, "Box[T:type]:=struct<reads>{V:T}\nF()<computes>:Box[i64]=Box[i64]{V:=5}", .struct_effect_required_reads, "Box");
    // A field default is pure, so it cannot build one either.
    try expectRefused(h, "logged:=struct<reads>{N:i64=3}\nouter:=struct{L:logged=logged{}}", .struct_effect_required_reads, "logged");
    // A type is not declared in a failure context or one that waits (13:746).
    try expectRefused(h, "s:=struct<decides>{}", .class_effect_specifier, "decides");
    try expectRefused(h, "s:=struct<suspends>{}", .class_effect_specifier, "suspends");
    try expectRefused(h, "s:=struct<converges>{}", .class_effect_specifier, "converges");
    try expectRefused(h, "s:=struct<predicts>{}", .unsupported_specifier, "predicts");
    try expectRefused(h, "s:=struct<computes><reads>{}", .effect_specifier_conflict, "reads");
    try expectRefused(h, "s:=struct<reads><reads>{}", .effect_specifier_repeated, "reads");
}

test "a struct effect beside persistable, and an unstated struct is built anywhere as before" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\saved:=struct<persistable><computes>{N:i64=2}
        \\plain:=struct{N:i64=3}
        \\F()<computes>:i64=saved{}.N+plain{}.N
        \\V:i64=F()
    );
    try expectInt(x, "V", 5);
}

// ---- `<final_super>` and `GetCastableFinalSuperClass` (Book 10:2904, 11:1673)

const components =
    \\component:=class<castable>{ID:i64=0}
    \\physics_component:=class<final_super>(component){Velocity:i64=0}
    \\render_component:=class<final_super>(component){Material:string=""}
    \\rigid_body:=class(physics_component){Mass:i64=10}
    \\character_body:=class(rigid_body){Health:i64=100}
    \\loose:=class(component){}
    \\Family(C:component)<computes><decides>:castable_subtype(component)=GetCastableFinalSuperClass[component,C]
    \\Is(K:castable_subtype(component),C:component)<computes>:logic=Attempt(Block{K[C];true},false)
    \\
;

test "the query finds the final_super class directly below the base, and fails where there is none" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, components ++
        \\A:logic=Attempt(Block{K:=Family[character_body{}];Is(K,physics_component{})},false)
        \\B:logic=Attempt(Block{K:=Family[character_body{}];Is(K,render_component{})},false)
        \\C:logic=Attempt(Block{K:=Family[render_component{}];Is(K,render_component{})},false)
        \\L:i64=Attempt(Block{Family[loose{}];1},0)
        \\Base:i64=Attempt(Block{Family[component{}];1},0)
        \\Anchor:i64=Attempt(Block{Family[physics_component{}];1},0)
        \\Root:logic=Attempt(Block{K:=GetCastableFinalSuperClass[component,rigid_body{}];K[rigid_body{}];true},false)
        \\Cast:i64=Attempt(Block{K:=Family[character_body{}];Seen:=K[character_body{}];physics_component[Seen].Velocity+1},-1)
    );
    try expectLogic(x, "A", true);
    try expectLogic(x, "B", false);
    try expectLogic(x, "C", true);
    try expectInt(x, "L", 0);
    // The queried type itself: no level to walk up from.
    try expectInt(x, "Base", 0);
    try expectInt(x, "Anchor", 1);
    try expectLogic(x, "Root", true);
    try expectInt(x, "Cast", 1);
}

test "several final supers answer the base they lie directly below" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\base:=class<castable>{ID:i64=0}
        \\first_anchor:=class<final_super>(base){}
        \\second_anchor:=class<final_super>(first_anchor){}
        \\leaf:=class(second_anchor){}
        \\Is(K:castable_subtype(base),C:base)<computes>:logic=Attempt(Block{K[C];true},false)
        \\FromBase:logic=Attempt(Block{K:=GetCastableFinalSuperClass[base,leaf{}];Is(K,first_anchor{})},false)
        \\Narrow:logic=Attempt(Block{K:=GetCastableFinalSuperClass[base,leaf{}];Is(K,base{})},false)
        \\FromFirst:logic=Attempt(Block{K:=GetCastableFinalSuperClass[first_anchor,leaf{}];K[second_anchor{}];true},false)
        \\Above:logic=Attempt(Block{K:=GetCastableFinalSuperClass[first_anchor,leaf{}];K[first_anchor{}];true},false)
    );
    try expectLogic(x, "FromBase", true);
    try expectLogic(x, "Narrow", false);
    try expectLogic(x, "FromFirst", true);
    try expectLogic(x, "Above", false);
}

test "final_super_base restricts the classes directly below it, and the marks keep their rules" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\entity:=class{}
        \\component:=class<abstract><unique><castable><final_super_base>{Parent:entity}
        \\physics_component:=class<unique><final_super>(component){Mass:i64=1}
        \\gravity_component:=class<unique>(physics_component){Scale:i64=2}
        \\G:component=gravity_component{Parent:=entity{}}
        \\V:i64=Attempt(Block{K:=GetCastableFinalSuperClass[component,G];physics_component[K[G]].Mass},0)
    );
    try expectInt(x, "V", 1);
    try expectRefused(h, "root:=class<final_super_base>{}\nchild:=class(root){}", .final_super_required, "child");
    try expectRefused(h, "lone:=class<final_super>{}", .final_super_parent, "lone");
    try expectRefused(h, "i:=interface<computes>{}\nc:=class<final_super>(i){}", .final_super_parent, "c");
    try expectRefused(h, "i:=interface{}\nj:=interface<final_super>(i){}", .unsupported_specifier, "final_super");
    try expectRefused(h, "i:=interface<final_super_base>{}", .unsupported_specifier, "final_super_base");
    try expectRefused(h, "a:=class{}\nb:=class<final_super><final_super>(a){}", .unsupported_specifier, "final_super");
    try expectRefused(h, "a:=class{}\nBox[T:type]:=class<final_super>(a){V:T}\nX:=Box[i64]{V:=1}", .unsupported_specifier, "Box");
}

test "a query closes the family of its base, and is refused where it cannot be answered" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, components ++ "late:=class<final_super>(component){}", .final_super_after_query, "late");
    // Below another class the family is still open.
    const x = try run(h, components ++ "late:=class<final_super>(physics_component){}\nV:i64=Attempt(Block{K:=GetCastableFinalSuperClass[physics_component,late{}];K[late{}];1},0)");
    try expectInt(x, "V", 1);
    try expectRefused(h, "a:=class{}\nb:=class<final_super>(a){}\nV:i64=Attempt(Block{GetCastableFinalSuperClass[a,b{}];1},0)", .not_castable, "GetCastableFinalSuperClass");
    try expectRefused(h, "a:=class<castable>{}\nb:=class<final_super>(a){}\nc:=class{}\nV:i64=Attempt(Block{GetCastableFinalSuperClass[a,c{}];1},0)", .type_mismatch, "c{}");
    try expectRefused(h, "a:=class<castable>{}\nb:=class<final_super>(a){}\nF(X:a)<computes>:castable_subtype(a)=GetCastableFinalSuperClass[a,X]", .failure_context_required, "GetCastableFinalSuperClass");
    try expectRefused(h, "a:=class<castable>{}\nV:i64=Attempt(Block{GetCastableFinalSuperClass[a];1},0)", .argument_count, "]");
}

test "GetCastableFinalSuperClass yields to every name a program declares so" {
    const h = try harness.create();
    defer scratch.release(h);
    const own = try run(h, "GetCastableFinalSuperClass(N:i64)<computes><decides>:i64=N\nV:i64=Attempt(GetCastableFinalSuperClass[3],0)");
    try expectInt(own, "V", 3);
    const local = try run(h, "F()<computes>:i64=Block{GetCastableFinalSuperClass:=array{4,5};Attempt(GetCastableFinalSuperClass[1],0)}\nV:i64=F()");
    try expectInt(local, "V", 5);
    const lib = "GetCastableFinalSuperClass<public>(N:i64)<computes><decides>:i64=N+1";
    const used = bundle(h, "L:=import{\"lib.forb\"}\nusing{L}\nV<public>:i64=Attempt(GetCastableFinalSuperClass[6],0)", lib);
    if (used != .ok) {
        std.debug.print("{s}\n", .{used.failed.diagnostic.message()});
        return error.Compile;
    }
    try expectInt((try h.run(used.ok, 100_000)).ok, "V", 7);
}

test "a family of another module is asked through public classes, and its type value needs its own line" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\component<public>:=class<castable>{ID:i64=0}
        \\physics<public>:=class<final_super>(component){}
        \\Make<public>()<allocates>:component=physics{}
    ;
    // The main module never writes `castable_subtype`: its library block names the metatype.
    const ok = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=Attempt(Block{C:=L.Make();K:=GetCastableFinalSuperClass[L.component,C];K[C];1},0)", lib);
    if (ok != .ok) {
        std.debug.print("{s}\n", .{ok.failed.diagnostic.message()});
        return error.Compile;
    }
    try expectInt((try h.run(ok.ok, 100_000)).ok, "V", 1);
    const hidden = "component<public>:=class<castable>{ID:i64=0}\nphysics:=class<final_super>(component){}";
    const refused = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=Attempt(Block{GetCastableFinalSuperClass[L.component,L.component{}];1},0)", hidden);
    try std.testing.expect(refused == .failed and refused.failed.diagnostic.code == .private_name);
}

test "review of B4: instantiation bases, nested modules, cached families, blame and members" {
    const h = try harness.create();
    defer scratch.release(h);
    // An instantiation of a parametric type is no type value, so its family is not asked (F1).
    try expectRefused(h, "b:=class<castable>{}\nbox[T:type]:=class(b){}\nR:=Attempt(Block{K:=GetCastableFinalSuperClass[box[i64],box[i64]{}];1},0)", .unsupported_type, "GetCastableFinalSuperClass");
    // A nested module that never writes `castable_subtype` asks through its file's block (F2).
    const inputs = [_]modules.Input{.{ .path = "main.forb", .source = "inner:=module{\n  component<public>:=class<castable>{ID:i64=0}\n  physics<public>:=class<final_super>(component){}\n  Ask<public>()<allocates>:i64=Attempt(Block{K:=GetCastableFinalSuperClass[component,physics{}];1},0)\n}\nW<public>:i64=inner.Ask()" }};
    const nested = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (nested != .ok) {
        std.debug.print("{s}\n", .{nested.failed.diagnostic.message()});
        return error.Compile;
    }
    try expectInt((try h.run(nested.ok, 100_000)).ok, "W", 1);
    // A query of another module's family is judged alike whether or not that module asked first (F3).
    const lib = "component<public>:=class<castable>{ID:i64=0}\nphysics:=class<final_super>(component){}\nW<public>:i64=Attempt(Block{GetCastableFinalSuperClass[component,physics{}];1},0)";
    const cached = bundle(h, "L:=import{\"lib.forb\"}\nV<public>:i64=Attempt(Block{GetCastableFinalSuperClass[L.component,L.component{}];1},0)", lib);
    try std.testing.expect(cached == .failed and cached.failed.diagnostic.code == .private_name);
    // A query that finds nothing fails where it is written, not where the first query was (F4).
    const source = "base:=class<castable>{}\nanchor:=class<final_super>(base){}\nA:i64=Attempt(Block{GetCastableFinalSuperClass[base,anchor{}];1},0)\nB:i64=Attempt(Block{GetCastableFinalSuperClass[base,base{}];1},0)";
    const blamed = try run(h, source);
    try expectInt(blamed, "A", 1);
    try expectInt(blamed, "B", 0);
    try std.testing.expectEqual(@as(usize, 1), blamed.failures.len);
    const at = std.mem.lastIndexOf(u8, source, "GetCastableFinalSuperClass").?;
    try std.testing.expectEqual(@as(u32, @intCast(at)), blamed.failures[0].span.start);
    // A member of the class named like the builtin keeps the diagnostic it had (members are `Self.Name`).
    try expectRefused(h, "a:=class<castable>{}\nc:=class{\n  GetCastableFinalSuperClass()<computes>:i64=1\n  F()<computes>:i64=GetCastableFinalSuperClass[a,a{}]\n}", .unknown_name, "GetCastableFinalSuperClass");
    // A narrowed result alone records no narrowed access (F5): calls stay on the plain path.
    const plain = try h.compile("animal:=class{}\ndog:=class(animal){}\np:=class{Make()<allocates>:animal=animal{}}\ns:=class(p){Make<override>()<allocates>:dog=dog{}}\nV:i64=1");
    try std.testing.expectEqual(@as(u32, 0), h.front.narrowed_count);
    _ = plain;
}

test "inspection lists the marks under format 52" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("root:=class<castable><final_super_base>{}\nanchor:=class<final_super>(root){}\nV:i64=1");
    const inspection = @import("inspection.zig");
    const workspace = try scratch.make(inspection.Workspace);
    defer scratch.release(workspace);
    const buffer = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(buffer);
    var out: std.Io.Writer = .fixed(buffer);
    try std.testing.expect(try workspace.write(&out, p) == .ok);
    const text = out.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"format\":52,"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"final_super_base\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"final_super\":true") != null);
}

// ---- Forged IR: the marks and the dispatch rows of a narrowed result

const forged_source =
    \\animal:=class<castable>{N:i64=1}
    \\dog:=class(animal){}
    \\maker:=class<final_super_base>{Make()<allocates>:animal=animal{}}
    \\kennel:=class<final_super>(maker){Make<override>()<allocates>:dog=dog{}}
    \\anchor:=class<final_super>(animal){}
    \\M:maker=kennel{}
    \\A:i64=Attempt(Block{X:=M.Make();dog[X];1},0)
    \\B:i64=Attempt(Block{GetCastableFinalSuperClass[animal,anchor{}];2},0)
;

fn classAt(p: types.Program, name: []const u8) usize {
    for (p.definitions, 0..) |item, index| {
        if (item == .class and std.mem.eql(u8, item.class.name.text(p.source), name)) return index;
    }
    unreachable;
}

test "both machines refuse forged final_super marks and a dispatch row whose result is narrower than its slot" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const original = (try h.run(p, 100_000)).ok;
    try expectInt(original, "A", 1);
    try expectInt(original, "B", 2);
    const a = std.testing.allocator;
    const definitions = try a.dupe(types.Definition, p.definitions);
    defer a.free(definitions);
    const dispatch = try a.dupe(types.Dispatch, p.dispatch);
    defer a.free(dispatch);
    var forged = p;
    forged.definitions = definitions;
    forged.dispatch = dispatch;
    const maker = classAt(p, "maker");
    const kennel = classAt(p, "kennel");
    const anchor = classAt(p, "anchor");
    const animal = classAt(p, "animal");
    // The class below a final_super_base class loses its mark.
    definitions[kennel].class.final_super = false;
    try harness.invalid(h, forged);
    definitions[kennel] = p.definitions[kennel];
    // A class without a superclass is marked.
    definitions[animal].class.final_super = true;
    try harness.invalid(h, forged);
    definitions[animal] = p.definitions[animal];
    // A marked class loses its superclass.
    definitions[anchor].class.parent = null;
    definitions[anchor].class.inherited = 0;
    definitions[anchor].class.fields = .{ .start = definitions[anchor].class.fields.end, .end = definitions[anchor].class.fields.end };
    try harness.invalid(h, forged);
    definitions[anchor] = p.definitions[anchor];
    // A final_super_base class gets a subclass without the mark: `animal` above `dog`.
    definitions[animal].class.final_super_base = true;
    try harness.invalid(h, forged);
    definitions[animal] = p.definitions[animal];
    // An interface or an instantiation marked.
    definitions[maker].class.is_interface = true;
    definitions[maker].class.is_abstract = true;
    try harness.invalid(h, forged);
    definitions[maker] = p.definitions[maker];
    definitions[anchor].class.arguments = p.definitions[anchor].class.parent;
    try harness.invalid(h, forged);
    definitions[anchor] = p.definitions[anchor];
    // The old slot's row for `kennel` names the narrowed implementation instead of the forwarder.
    try std.testing.expectEqual(@as(usize, 2), p.slots.len);
    var old_row: ?usize = null;
    var new_row: ?usize = null;
    for (p.dispatch, 0..) |entry, index| {
        if (@backingInt(entry.class) != kennel + 4) continue;
        if (entry.slot == 0) old_row = index else new_row = index;
    }
    dispatch[old_row.?].function = p.dispatch[new_row.?].function;
    try harness.invalid(h, forged);
    // And the new slot's row names the forwarder of the old one.
    dispatch[old_row.?] = p.dispatch[old_row.?];
    dispatch[new_row.?].function = p.dispatch[old_row.?].function;
    try harness.invalid(h, forged);
    dispatch[new_row.?] = p.dispatch[new_row.?];
    try expectInt((try h.run(forged, 100_000)).ok, "A", 1);
}

const Counts = struct { refused: usize = 0, ran: usize = 0 };

/// Both admissions agree on a forged program, and one both admit runs alike.
fn attempt(h: *harness.Harness, p: types.Program, what: []const u8, at: usize, counts: *Counts) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    const lowered = bytecode.lower(p, &h.runtime.instructions);
    const vm_refused = lowered != .ok or vm_refused: {
        const actual = h.runtime.machine.run(lowered.ok, 100_000);
        break :vm_refused actual == .failed and actual.failed.code == .invalid_bytecode;
    };
    const reference_refused = reference == .failed and reference.failed.code == .invalid_ir;
    if (reference_refused != vm_refused) {
        std.debug.print("DIVERGE {s} {d}: reference {}, vm {}\n", .{ what, at, reference_refused, vm_refused });
        return error.TestUnexpectedResult;
    }
    if (reference_refused) {
        counts.refused += 1;
        return;
    }
    _ = try h.run(p, 100_000);
    counts.ran += 1;
}

test "every mark of every class and every function of every row, forged: both machines agree" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const a = std.testing.allocator;
    const definitions = try a.dupe(types.Definition, p.definitions);
    defer a.free(definitions);
    const dispatch = try a.dupe(types.Dispatch, p.dispatch);
    defer a.free(dispatch);
    var forged = p;
    forged.definitions = definitions;
    forged.dispatch = dispatch;
    var counts: Counts = .{};
    for (p.definitions, 0..) |item, index| {
        if (item != .class) continue;
        definitions[index].class.final_super = !item.class.final_super;
        try attempt(h, forged, "final_super", index, &counts);
        definitions[index] = item;
        definitions[index].class.final_super_base = !item.class.final_super_base;
        try attempt(h, forged, "final_super_base", index, &counts);
        definitions[index] = item;
    }
    for (p.dispatch, 0..) |entry, index| {
        for (0..p.functions.len + 1) |function| {
            dispatch[index].function = @intCast(function);
            try attempt(h, forged, "dispatch function", index, &counts);
        }
        dispatch[index] = entry;
    }
    try std.testing.expect(counts.refused > 10 and counts.ran >= p.dispatch.len);
}

// ---- Randomized oracles

// Random chains of producers whose `Make` overrides narrow, keep or widen the result along a
// chain of result classes, each override building on `Super.Make()`, against a Zig model of
// the slots: the static type a call through each class sees, the value dispatch reaches, and
// the refusal of a widening override.
test "random chains of narrowing overrides meet a model of their slots on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0b4c_0001);
    const random = prng.random();
    const a = std.testing.allocator;
    var compiled: usize = 0;
    var refused: usize = 0;
    for (0..60) |_| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        const results = 5;
        try source.appendSlice(a, "T0:=class{Tag:i64=0}\n");
        for (1..results) |k| try source.print(a, "T{d}:=class(T{d}){{}}\n", .{ k, k - 1 });
        const producers_count = 1 + random.uintLessThan(usize, 6);
        // What the model knows of each producer: the result its calls see and the tag it returns.
        var static: [8]usize = undefined;
        var tag: [8]i64 = undefined;
        var valid = true;
        const first = random.uintLessThan(usize, 3);
        try source.print(a, "P0:=class{{Make()<reads><allocates>:T{d}=T{d}{{}}}}\n", .{ first, first });
        static[0] = first;
        tag[0] = 0;
        for (1..producers_count + 1) |i| {
            if (random.boolean()) {
                const result = random.uintLessThan(usize, results);
                if (result < static[i - 1]) valid = false;
                try source.print(a, "P{d}:=class(P{d}){{Make<override>()<reads><allocates>:T{d}=T{d}{{Tag:=Super.Make().Tag*10+{d}}}}}\n", .{ i, i - 1, result, result, i });
                static[i] = result;
                tag[i] = tag[i - 1] * 10 + @as(i64, @intCast(i));
            } else {
                try source.print(a, "P{d}:=class(P{d}){{}}\n", .{ i, i - 1 });
                static[i] = static[i - 1];
                tag[i] = tag[i - 1];
            }
        }
        for (0..producers_count + 1) |j| {
            // Through the base, through the class itself at its static result, and as a value.
            try source.print(a, "B{d}:i64=Block{{X:P0=P{d}{{}};X.Make().Tag}}\n", .{ j, j });
            try source.print(a, "S{d}:T{d}=P{d}{{}}.Make()\n", .{ j, static[j], j });
            try source.print(a, "F{d}:=P{d}{{}}.Make\nV{d}:i64=F{d}().Tag\n", .{ j, j, j, j });
        }
        const result = h.front.compile(source.items);
        if (!valid) {
            try std.testing.expect(result == .failed and result.failed.code == .override_mismatch);
            refused += 1;
            continue;
        }
        if (result != .ok) {
            std.debug.print("{s}\n{s}\n", .{ result.failed.message(), source.items });
            return error.Compile;
        }
        const x = (try h.run(result.ok, 400_000)).ok;
        compiled += 1;
        var name: [16]u8 = undefined;
        for (0..producers_count + 1) |j| {
            try expectInt(x, try std.fmt.bufPrint(&name, "B{d}", .{j}), tag[j]);
            try expectInt(x, try std.fmt.bufPrint(&name, "V{d}", .{j}), tag[j]);
        }
    }
    try std.testing.expect(compiled > 10 and refused > 5);
}

// Random trees of classes below a castable root, with random `<final_super>` marks, queried
// from the root and from a random class for every class, against a Zig model that walks each
// class up to the class directly below the queried base.
test "random final_super families meet a model of the query on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0b4c_0002);
    const random = prng.random();
    const a = std.testing.allocator;
    var answered: usize = 0;
    var failed: usize = 0;
    for (0..40) |_| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        const count = 4 + random.uintLessThan(usize, 9);
        var parent: [16]usize = undefined;
        var marked: [16]bool = undefined;
        try source.appendSlice(a, "C0:=class<castable>{}\n");
        marked[0] = false;
        for (1..count) |i| {
            parent[i] = random.uintLessThan(usize, i);
            marked[i] = random.uintLessThan(usize, 3) != 0;
            try source.print(a, "C{d}:=class{s}(C{d}){{}}\n", .{ i, if (marked[i]) "<final_super>" else "", parent[i] });
        }
        const other = random.uintLessThan(usize, count);
        try source.print(a, "Q0(X:C0)<computes><decides>:castable_subtype(C0)=GetCastableFinalSuperClass[C0,X]\n", .{});
        try source.print(a, "Q1(X:C{d})<computes><decides>:castable_subtype(C{d})=GetCastableFinalSuperClass[C{d},X]\n", .{ other, other, other });
        // For each class and each candidate, whether the answer is that candidate; -1 when none.
        var expected_root: [16]i64 = undefined;
        var expected_other: [16]i64 = undefined;
        for (0..count) |j| {
            expected_root[j] = familyOf(j, 0, parent[0..count], marked[0..count]);
            expected_other[j] = if (below(j, other, parent[0..count])) familyOf(j, other, parent[0..count], marked[0..count]) else -2;
            try source.print(a, "R{d}:i64=Attempt(Block{{K:=Q0[C{d}{{}}];", .{ j, j });
            try whichOf(&source, a, 0, parent[0..count], marked[0..count], "C0");
            try source.appendSlice(a, "},-1)\n");
            if (expected_other[j] != -2) {
                try source.print(a, "O{d}:i64=Attempt(Block{{K:=Q1[C{d}{{}}];", .{ j, j });
                var bound: [8]u8 = undefined;
                try whichOf(&source, a, other, parent[0..count], marked[0..count], try std.fmt.bufPrint(&bound, "C{d}", .{other}));
                try source.appendSlice(a, "},-1)\n");
            }
        }
        const x = try run(h, source.items);
        var name: [16]u8 = undefined;
        for (0..count) |j| {
            try expectInt(x, try std.fmt.bufPrint(&name, "R{d}", .{j}), expected_root[j]);
            if (expected_root[j] == -1) failed += 1 else answered += 1;
            if (expected_other[j] != -2) try expectInt(x, try std.fmt.bufPrint(&name, "O{d}", .{j}), expected_other[j]);
        }
    }
    try std.testing.expect(answered > 40 and failed > 40);
}

fn below(class: usize, base: usize, parent: []const usize) bool {
    var at = class;
    while (true) {
        if (at == base) return true;
        if (at == 0) return false;
        at = parent[at];
    }
}

/// The model: the class directly below `base` on the way up from `class`, when it is marked;
/// -1 when `class` is `base` or that class is not marked.
fn familyOf(class: usize, base: usize, parent: []const usize, marked: []const bool) i64 {
    if (class == base) return -1;
    var at = class;
    while (parent[at] != base) at = parent[at];
    return if (marked[at]) @intCast(at) else -1;
}

/// An expression that names the candidate whose instance the type value `K` casts: each
/// marked class directly below `base` in turn. Candidates are siblings, so at most one holds.
fn whichOf(source: *std.ArrayList(u8), a: std.mem.Allocator, base: usize, parent: []const usize, marked: []const bool, bound: []const u8) !void {
    var opened: usize = 0;
    for (1..parent.len) |candidate| {
        if (!marked[candidate] or parent[candidate] != base) continue;
        try source.print(a, "If(Attempt(Block{{K[C{d}{{}}];true}},false),{d},", .{ candidate, candidate });
        opened += 1;
    }
    _ = bound;
    try source.appendSlice(a, "-1");
    for (0..opened) |_| try source.appendSlice(a, ")");
}
