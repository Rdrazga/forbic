//! Where parametric types (RFC-0073) meet modules declared inside files (RFC-0074), constructor
//! functions, class `Block{...}` clauses, `<final>` and split write access (RFC-0075), the
//! locals a `For` carries (RFC-0064) and the hashed lookups. Each was written against a
//! compiler without the others; these programs need them together.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const catalogue = @import("aggregate_types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const fuel = 1 << 20;

fn compile(h: *harness.Harness, inputs: []const modules.Input) !types.Program {
    return switch (h.front.compileBundle(.{ .root = "main.forb", .modules = inputs })) {
        .ok => |ir| ir,
        .failed => |problem| {
            const where = problem.diagnostic.location(problem.source);
            std.debug.print("interaction compile failed: {s}:{d}:{d}: {s}\n", .{ problem.path, where.line, where.column, problem.diagnostic.message() });
            return error.UnexpectedCompile;
        },
    };
}

fn execute(h: *harness.Harness, inputs: []const modules.Input) !evaluator.Execution {
    const result = try h.run(try compile(h, inputs), fuel);
    if (result == .failed) {
        std.debug.print("interaction run failed: {s}\n", .{result.failed.message()});
        return error.UnexpectedFailure;
    }
    return result.ok;
}

fn one(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    return execute(h, &.{.{ .path = "main.forb", .source = source }});
}

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.MissingBinding;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
}

/// A bundle that must be refused with `code` in file `path` at `line`:`column`.
fn expectRefused(h: *harness.Harness, inputs: []const modules.Input, code: types.Diagnostic.Code, path: []const u8, line: u32, column: u32) !void {
    const result = h.front.compileBundle(.{ .root = "main.forb", .modules = inputs });
    if (result == .ok) {
        std.debug.print("interaction admitted:\n{s}\n", .{inputs[inputs.len - 1].source});
        return error.UnexpectedAdmission;
    }
    const where = result.failed.diagnostic.location(result.failed.source);
    if (result.failed.diagnostic.code != code or where.line != line or where.column != column) std.debug.print("interaction diagnostic {s} at {s}:{d}:{d} for:\n{s}\n", .{ @tagName(result.failed.diagnostic.code), result.failed.path, where.line, where.column, inputs[inputs.len - 1].source });
    try std.testing.expectEqual(code, result.failed.diagnostic.code);
    try std.testing.expectEqualStrings(path, result.failed.path);
    try std.testing.expectEqual(line, where.line);
    try std.testing.expectEqual(column, where.column);
}

fn refusedOne(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, line: u32, column: u32) !void {
    return expectRefused(h, &.{.{ .path = "main.forb", .source = source }}, code, "main.forb", line, column);
}

/// The instantiations named `name` in `program`.
fn instancesOf(program: types.Program, name: []const u8) usize {
    var count: usize = 0;
    for (program.definitions) |item| {
        if (catalogue.typeArguments(item) == null) continue;
        if (std.mem.eql(u8, catalogue.declaredName(item).?.text(program.source), name)) count += 1;
    }
    return count;
}

const kit =
    \\Kit<public>:=module{
    \\  Box<public>[T:type]:=class{
    \\    var V<public>:T
    \\    Get<public>()<transacts>:T=Self.V
    \\  }
    \\  Hidden[T:type]:=class{V:T}
    \\  secret:=class{N:i64=1}
    \\  Inner<public>:=module{
    \\    Make<public>(N:i64)<transacts>:Box[i64]=Box[i64]{V:=N}
    \\  }
    \\  Own<public>()<transacts>:i64=Hidden[secret]{V:=secret{}}.V.N
    \\}
;

test "a parametric class of a nested module is one type for every module that names it" {
    const h = try harness.create();
    defer scratch.release(h);
    // `A` names it through `using`, `B` by its path, the library's own inner module by the
    // scope around it, and the root passes each one's instances to a function of the type.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA:=module{\nusing{L.Kit}\nMk<public>()<transacts>:Box[i64]=Box[i64]{V:=5}\n}\nB:=module{\nMk<public>()<transacts>:L.Kit.Box[i64]=L.Kit.Box[i64]{V:=7}\n}\nSame(X:L.Kit.Box[i64],Y:L.Kit.Box[i64])<transacts>:i64=X.Get()*10+Y.Get()\nR<public>:i64=Same(A.Mk(),B.Mk())*100+Same(L.Kit.Inner.Make(3),A.Mk())+L.Kit.Own()*10000" },
        .{ .path = "lib.forb", .source = kit },
    };
    const program = try compile(h, &inputs);
    // One definition of `Box[i64]`, whoever named it first, and one of the private template.
    try std.testing.expectEqual(@as(usize, 1), instancesOf(program, "Box"));
    try std.testing.expectEqual(@as(usize, 1), instancesOf(program, "Hidden"));
    const result = try h.run(program, fuel);
    try expectInt(result.ok, "R", 5700 + 35 + 10000);
    // Templates of one name in sibling modules and in the file are three templates.
    const siblings = try compile(h, &.{.{ .path = "main.forb", .source = "A:=module{\nBox<public>[T:type]:=class{V<public>:T,K<public>:i64=1}\n}\nB:=module{\nBox<public>[T:type]:=class{V<public>:T,K<public>:i64=2}\n}\nBox[T:type]:=class{V:T,K:i64=3}\nRun()<transacts>:i64=A.Box[i64]{V:=0}.K*100+B.Box[i64]{V:=0}.K*10+Box[i64]{V:=0}.K\nR<public>:i64=Run()" }});
    try std.testing.expectEqual(@as(usize, 3), instancesOf(siblings, "Box"));
    try expectInt((try h.run(siblings, fuel)).ok, "R", 123);
    // A template of a module that is not public, named by the module around it; a struct.
    const x = try one(h, "Kit:=module{\nPriv:=module{\nBox<public>[T:type]:=class{V<public>:T}\n}\nPair<public>[A:type,B:type]:=struct{X:A,Y:B}\nUse<public>()<transacts>:i64=Priv.Box[i64]{V:=9}.V\n}\nUser:=module{\nusing{Kit}\nSum<public>(P:Pair[i64,i64])<computes>:i64=P.X+P.Y\n}\nR<public>:i64=Kit.Use()*100+User.Sum(Kit.Pair[i64,i64]{X:=3,Y:=4})");
    try expectInt(x, "R", 907);
    // A class below an instantiation is declared late, also inside a module: named through
    // `using`, by its path, and by a class above it in its own module.
    const y = try one(h, "Kit:=module{\nBox<public>[T:type]:=class{var V<public>:T}\nHolder<public>:=class{Kid:option(Counted)=option{}}\nCounted<public>:=class(Box[i64]){Step<public>:i64=10}\n}\nUser:=module{\nusing{Kit}\nMk<public>()<transacts>:i64=Counted{V:=1}.Step\n}\nHold:option(Kit.Counted)=option{}\nR<public>:i64=User.Mk()+Kit.Counted{V:=2}.V");
    try expectInt(y, "R", 12);
}

test "a private template and a private argument stay inside the module that declares them" {
    const h = try harness.create();
    defer scratch.release(h);
    const library: modules.Input = .{ .path = "lib.forb", .source = kit };
    // The template is not public: neither a path nor `using` reaches it from outside.
    try expectRefused(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nR<public>:i64=L.Kit.Hidden[i64]{V:=1}.V" }, library }, .private_name, "main.forb", 2, 15);
    try expectRefused(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L.Kit}\nR<public>:i64=Hidden[i64]{V:=1}.V" }, library }, .unknown_name, "main.forb", 3, 15);
    const main: modules.Input = .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nR<public>:i64=1" };
    // An instantiation is as public as its template and its arguments: with a private
    // argument it does not leave through a public binding, a public function or a struct.
    try expectRefused(h, &.{ main, .{ .path = "lib.forb", .source = "Kit<public>:=module{\nBox<public>[T:type]:=class{V:T}\nsecret:=class{N:i64=1}\nLeak<public>:option(Box[secret])=option{}\n}" } }, .private_type_escape, "lib.forb", 4, 1);
    try expectRefused(h, &.{ main, .{ .path = "lib.forb", .source = "Kit<public>:=module{\nBox<public>[T:type]:=class{V:T}\nsecret:=class{N:i64=1}\nLeak<public>()<transacts>:Box[secret]=Box[secret]{V:=secret{}}\n}" } }, .private_type_escape, "lib.forb", 4, 1);
    try expectRefused(h, &.{ main, .{ .path = "lib.forb", .source = "Kit<public>:=module{\nPair<public>[A:type,B:type]:=struct{X:A,Y:B}\nsecret:=struct{n:i64=1}\nLeak<public>:option(Pair[i64,secret])=option{}\n}" } }, .private_type_escape, "lib.forb", 4, 1);
    // What a public template names in its members must be nameable wherever it is.
    try expectRefused(h, &.{ main, .{ .path = "lib.forb", .source = "Kit<public>:=module{\nsecret:=class{N:i64=1}\nBox<public>[T:type]:=class{V:T,S:option(secret)=option{}}\n}" } }, .private_type_escape, "lib.forb", 3, 32);
    // Inside the module that has the private argument the instantiation is used freely.
    const x = try execute(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nR<public>:i64=L.Kit.Use()" }, .{ .path = "lib.forb", .source = "Kit<public>:=module{\nBox<public>[T:type]:=class{V:T}\nsecret:=class{N:i64=4}\nKeep:option(Box[secret])=option{}\nUse<public>()<transacts>:i64=Box[secret]{V:=secret{}}.V.N\n}" } });
    try expectInt(x, "R", 4);
}

test "forged origins in nested modules are told apart by the scope that declares the template" {
    const h = try harness.create();
    defer scratch.release(h);
    // `A.Box[i64]`, `B.Box[i64]` and `A.Box[string]`: the same name and arguments in two
    // modules of one file are two types, and both machines admit them.
    const program = try compile(h, &.{.{ .path = "main.forb", .source = "A:=module{\nBox<public>[T:type]:=class{V<public>:T}\n}\nB:=module{\nBox<public>[T:type]:=class{V<public>:T}\n}\nP:=A.Box[i64]{V:=1}\nQ:=B.Box[i64]{V:=2}\nS:=A.Box[string]{V:=\"s\"}\nR<public>:i64=3" }});
    try expectInt((try h.run(program, fuel)).ok, "R", 3);
    const definitions = try std.testing.allocator.dupe(types.Definition, program.definitions);
    defer std.testing.allocator.free(definitions);
    var forged = program;
    forged.definitions = definitions;
    var first_a: ?usize = null;
    var text_a: ?usize = null;
    var first_b: ?usize = null;
    const scope_a = program.nested[0].source;
    for (definitions, 0..) |item, index| {
        if (item != .class or item.class.arguments == null) continue;
        const list = catalogue.definition(item.class.arguments.?, program.definitions).?.tuple;
        const is_int = program.tuple_elements[list.start] == .i64;
        if (modules.contains(scope_a, item.class.name)) {
            if (is_int) first_a = index else text_a = index;
        } else first_b = index;
    }
    // Two definitions of `A` claim `Box[i64]`: one name with one argument list in one scope.
    definitions[text_a.?].class.arguments = definitions[first_a.?].class.arguments;
    try harness.invalid(h, forged);
    @memcpy(definitions, program.definitions);
    // `B`'s instantiation claims to be `A`'s: again two of one scope.
    definitions[first_b.?].class.name = definitions[first_a.?].class.name;
    try harness.invalid(h, forged);
    @memcpy(definitions, program.definitions);
    // A plain definition under the name of a template declared inside a module.
    definitions[first_b.?].class.arguments = null;
    try harness.invalid(h, forged);
}

const xs = "Xs:[]i64=array{1,2,3}\n";

test "a parametric class has a constructor function, delegates to its superclass's and runs its clauses per instantiation" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try one(h, xs ++
        \\var Log:[]i64=array{}
        \\Base[T:type]:=class<abstract>{
        \\  var V:T
        \\  var Seen:i64=0
        \\  Block{set Log=Log+array{10};set Self.Seen=Self.Seen+1}
        \\}
        \\MakeBase<constructor>(N:i64)<transacts>:=Base[i64]{V:=N+1}
        \\Mid[T:type]:=class(Base[T]){
        \\  W:T
        \\  Block{set Log=Log+array{20}}
        \\}
        \\MakeMid<constructor>(N:i64)<transacts>:=Mid[i64]{MakeBase<constructor>(N),W:=N*3}
        \\Leaf:=class(Mid[i64]){X:i64=0}
        \\MakeLeaf<constructor>(N:i64)<transacts>:=Leaf{MakeMid<constructor>(N),X:=N}
        \\Text:=Mid[string]{V:="a",W:="b"}
        \\Run()<transacts>:i64=Block{L:=MakeLeaf(2);M:=MakeMid(5);L.V*1000+L.W*100+L.X*10+M.V+M.W*10000+L.Seen*1000000+Text.Seen*10000000}
        \\R<public>:i64=Run()
        \\N<public>:i64=Log.Length
    );
    // The leaf takes V = 3 from the base's constructor through the middle one, and W = 6.
    try expectInt(x, "R", 3000 + 600 + 20 + 6 + 150000 + 1000000 + 10000000);
    // Each of the three instances ran the clause of its base and of its middle class, once.
    try expectInt(x, "N", 6);
    // A clause builds another parametric type that the class first names; a constructor
    // function of a template in a module is delegated to through its path.
    const y = try one(h,
        \\Kit:=module{
        \\  Leaf<public>[T:type]:=class{V<public>:T}
        \\  Tree<public>[T:type]:=class{
        \\    V:T
        \\    var Kid<public>:option(Leaf[T])=option{}
        \\    Block{set Self.Kid=option{Leaf[T]{V:=Self.V}}}
        \\  }
        \\  Make<public><constructor>(N:i64)<transacts>:=Tree[i64]{V:=N}
        \\}
        \\Sub:=class(Kit.Tree[i64]){W:i64=0}
        \\MakeSub<constructor>(N:i64)<transacts>:=Sub{Kit.Make<constructor>(N),W:=1}
        \\Run()<transacts>:i64=Block{S:=MakeSub(6);Attempt(Block{K:=S.Kid?;K.V*10+S.W},-1)}
        \\R<public>:i64=Run()
    );
    try expectInt(y, "R", 61);
    // The rules of constructor functions hold for instantiations: an abstract one is built
    // only by delegation, and a class is not built while its clauses are unknown, by its own
    // clause or by a type that its declaration completes before them.
    try refusedOne(h, "Base[T:type]:=class<abstract>{V:T}\nMakeBase<constructor>(N:i64)<transacts>:=Base[i64]{V:=N}\nRun()<transacts>:i64=MakeBase(1).V\nR<public>:i64=Run()", .abstract_instance, 3, 22);
    try refusedOne(h, "Base[T:type]:=class<abstract>{V:T}\nRun()<transacts>:i64=Base[i64]{V:=1}.V\nR<public>:i64=Run()", .abstract_instance, 2, 22);
    try refusedOne(h, "Box[T:type]:=class{\nV:T\nBlock{Box[T]{V:=Self.V}}\n}\nRun()<transacts>:i64=Box[i64]{V:=1}.V\nR<public>:i64=Run()", .construction_cycle, 3, 7);
    try refusedOne(h, "Ping[T:type]:=class{\nPeer()<transacts>:Pong[T]=Pong[T]{W:=Self.V}\nV:T\nBlock{Self.V}\n}\nPong[T:type]:=class{\nBack()<transacts>:Ping[T]=Ping[T]{V:=Self.W}\nW:T\n}\nRun()<transacts>:i64=Ping[i64]{V:=3}.Peer().Back().V\nR<public>:i64=Run()", .construction_cycle, 7, 27);
    // Through a type parameter too: what `T{}` builds is built under the rules of the class.
    try refusedOne(h, "Make[T:type]()<transacts>:T{T{}}\nBox:=class{\nV:i64=1\nBlock{Make[Box]()}\n}\nR<public>:i64=1", .construction_cycle, 1, 29);
}

test "a For carries a local inside a method of a template instantiated twice" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try one(h, xs ++
        \\Acc[T:type]:=class{
        \\  var V:T
        \\  Sum()<transacts>:i64=Block{var Total:i64=0;For(X:Xs,Block{set Total=Total+X;Total});Total}
        \\  Count()<transacts>:i64=Block{var N:i64=0;For(X:Xs,X!=2,Block{set N=N+1;N});N}
        \\  Pick(O:option(i64))<computes>:i64=If(O?>3,1,2)
        \\}
        \\Run()<transacts>:i64=Acc[i64]{V:=1}.Sum()*1000+Acc[string]{V:="a"}.Sum()*100+Acc[string]{V:="b"}.Count()*10+Acc[i64]{V:=2}.Pick(option{})
        \\R<public>:i64=Run()
    );
    // 6 from each instantiation's own loop, two elements counted, and the lone unwrap that
    // makes its condition failable in a method compiled once for each argument.
    try expectInt(x, "R", 6000 + 600 + 20 + 2);
    // The filter is traced to itself, in the template's text.
    const failures = x.failures[0..@min(x.failures.len, x.failure_count)];
    var filters: usize = 0;
    for (failures) |failure| filters += @intFromBool(std.mem.eql(u8, failure.span.text(x.program.source), "X!=2"));
    try std.testing.expectEqual(@as(usize, 1), filters);
}

test "a Case tests for two instantiations of one template" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try one(h,
        \\Has:=interface{Id()<transacts>:i64}
        \\Box[T:type]:=class(Has){
        \\  V:T
        \\  Id<override>()<transacts>:i64=7
        \\}
        \\Which(X:Has)<transacts>:i64=Case(X,B:Box[i64]=>B.V,S:Box[string]=>S.V.Length+100,_=>0)
        \\Other:=class(Has){Id<override>()<transacts>:i64=1}
        \\Run()<transacts>:i64=Which(Box[i64]{V:=5})*10000+Which(Box[string]{V:="abc"})*10+Which(Other{})
        \\R<public>:i64=Run()
    );
    try expectInt(x, "R", 50000 + 1030);
}

test "a template keeps final fields and split write access in every instantiation, and takes extension methods" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try one(h,
        \\Cell[T:type]:=class{
        \\  var<private> V<public>:T
        \\  Rate<final>:i64=3
        \\  Put(N:T)<transacts>:T=Block{set Self.V=N;N}
        \\}
        \\(C:Cell[i64]).Twice()<transacts>:i64=C.V*2
        \\(C:Cell[string]).Twice()<transacts>:i64=C.V.Length
        \\Run()<transacts>:i64=Block{C:=Cell[i64]{V:=1};C.Put(5);S:=Cell[string]{V:="abc"};C.V*1000+C.Rate*100+C.Twice()*1+S.Twice()*10000+S.Rate*100000}
        \\R<public>:i64=Run()
    );
    try expectInt(x, "R", 5000 + 300 + 10 + 30000 + 300000);
    // No archetype gives a final field and only the class assigns the field, for each argument.
    try refusedOne(h, "Cell[T:type]:=class{\nV:T\nRate<final>:i64=3\n}\nR<public>:i64=Cell[i64]{V:=1,Rate:=4}.Rate", .final_field, 5, 30);
    try refusedOne(h, "Cell[T:type]:=class{\nvar<private> V<public>:T\n}\nRun()<transacts>:i64=Block{C:=Cell[i64]{V:=1};set C.V=2;C.V}\nR<public>:i64=Run()", .inaccessible_member, 4, 53);
    try refusedOne(h, "Cell[T:type]:=class{\nvar<private> V<public>:T\n}\nRun()<transacts>:i64=Block{C:=Cell[string]{V:=\"a\"};set C.V=\"b\";C.V.Length}\nR<public>:i64=Run()", .inaccessible_member, 4, 58);
    // A public template of a module is read once for the types it names: its write
    // specifiers, final fields and clauses are passed over there as its bodies are.
    const y = try one(h,
        \\Kit<public>:=module{
        \\  Cell<public>[T:type]:=class{
        \\    var<private> V<public>:T
        \\    Rate<final>:i64=3
        \\    var Puts<public>:i64=0
        \\    Block{set Self.Puts=Self.Rate}
        \\    Put<public>(N:T)<transacts>:T=Block{set Self.V=N;set Self.Puts=Self.Puts+1;N}
        \\  }
        \\}
        \\Run()<transacts>:i64=Block{C:=Kit.Cell[i64]{V:=1};C.Put(8);C.V*10+C.Puts}
        \\R<public>:i64=Run()
    );
    try expectInt(y, "R", 84);
}

test "a public alias of an instantiation or of a late class is a supertype, here and from other modules" {
    const h = try harness.create();
    defer scratch.release(h);
    // The pre-pass has to know such an alias whatever its access: a class below it is declared
    // late, after the type the alias stands for. It left public aliases out, and the class got
    // its place before its superclass (`invalid_parent`).
    const x = try one(h, "Base<public>[T:type]:=class{V:T}\nAl<public>:=Base[i64]\nMine:=class(Al){S:i64=3}\nR<public>:i64=Mine{V:=4}.V*10+Mine{V:=1}.S");
    try expectInt(x, "R", 43);
    const below = try one(h, "Base<public>[T:type]:=class{V:T}\nSub<public>:=class(Base[i64]){}\nAl<public>:=Sub\nMine:=class(Al){S:i64=3}\nR<public>:i64=Mine{V:=4}.V*10+Mine{V:=1}.S");
    try expectInt(below, "R", 43);
    const library: modules.Input = .{ .path = "lib.forb", .source = "Base<public>[T:type]:=class{V<public>:T}\nAl<public>:=Base[i64]\nKit<public>:=module{\nBox<public>[T:type]:=class{W<public>:T}\nInts<public>:=Box[i64]\n}" };
    // Through an import, by a path into a nested module, and through `using`.
    const y = try execute(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nMine:=class(L.Al){S:i64=3}\nDeep:=class(L.Kit.Ints){S:i64=5}\nR<public>:i64=Mine{V:=4}.V*100+Deep{W:=2}.W*10+Deep{W:=0}.S" }, library });
    try expectInt(y, "R", 425);
    const z = try execute(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nusing{L.Kit}\nMine:=class(Al){S:i64=3}\nDeep:=class(Ints){S:i64=5}\nR<public>:i64=Mine{V:=4}.V*100+Deep{W:=2}.W*10+Deep{W:=0}.S" }, library });
    try expectInt(z, "R", 425);
    // A private alias is still refused from outside, as a private name.
    try expectRefused(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nMine:=class(L.Hid){}\nR<public>:i64=1" }, .{ .path = "lib.forb", .source = "Base<public>[T:type]:=class{V:T}\nHid:=Base[i64]" } }, .private_name, "main.forb", 2, 13);
}

test "a class that is declared late is an alias and a cast target above its declaration" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Sub` is declared late only because its superclass is spelled like a template that the
    // imported file keeps to itself. Above its declaration it must be what a class of the
    // pre-pass is: a type that `Name := Sub` aliases and `Sub[X]` casts to.
    const template: modules.Input = .{ .path = "lib.forb", .source = "Base[T:type]:=class{V:T}\nOk<public>:i64=1" };
    const plain: modules.Input = .{ .path = "lib.forb", .source = "Other[T:type]:=class{V:T}\nOk<public>:i64=1" };
    const alias = "L:=import{\"lib.forb\"}\nAl:=Sub\nBase:=class{N:i64=1}\nSub:=class(Base){M:i64=2}\nX:option(Al)=option{}\nR<public>:i64=Sub{}.M+L.Ok";
    const cast = "L:=import{\"lib.forb\"}\nAny:=interface{}\nBase:=class(Any){N:i64=1}\nF(X:Any)<transacts>:i64=Attempt(Block{S:=Sub[X];1},0)\nSub:=class(Base){M:i64=2}\nR<public>:i64=F(Sub{})*10+F(Base{})+L.Ok";
    for ([_]modules.Input{ plain, template }) |library| {
        try expectInt(try execute(h, &.{ .{ .path = "main.forb", .source = alias }, library }), "R", 3);
        try expectInt(try execute(h, &.{ .{ .path = "main.forb", .source = cast }, library }), "R", 11);
    }
    // The same for a class that really is below an instantiation, and with modules in the file.
    const x = try one(h, "Any:=interface{}\nBox[T:type]:=class(Any){V:T}\nAl:=Sub\nF(X:Any)<transacts>:i64=Attempt(Block{S:=Sub[X];1},0)\nSub:=class(Box[i64]){M:i64=2}\nHeld:option(Al)=option{}\nR<public>:i64=F(Sub{V:=1})*10+F(Box[i64]{V:=1})+Sub{V:=0}.M");
    try expectInt(x, "R", 12);
    const y = try one(h, "Q:=module{\nBase<public>[T:type]:=class{V:T}\n}\nAl:=Sub\nBase:=class{N:i64=1}\nSub:=class(Base){M:i64=2}\nHeld:option(Al)=option{}\nR<public>:i64=Sub{}.M");
    try expectInt(y, "R", 2);
    // A value of that name in the scope is still the value.
    const z = try one(h, "Q:=module{\nBox<public>[T:type]:=class{V:T}\nSub<public>:=class(Box[i64]){}\n}\nSub:i64=4\nAl:=Sub\nR<public>:i64=Al");
    try expectInt(z, "R", 4);
}

test "Fors that fill arrays of the code around them cost no compile each, as any For sent to the general lowering" {
    const h = try harness.create();
    defer scratch.release(h);
    // `set Out[I]=X` indexes, so its loop needs the general lowering (one retry), and it
    // updates a local of the code around it, which the loop has to carry (a retry that all
    // such loops share). The two were found in turn, two compiles for each loop, then one;
    // now every loop of a pass is noted in it, so nine loops take the compiles of one.
    var passes: [2]u32 = undefined;
    for ([_]usize{ 1, 9 }, &passes) |loops, *counted| {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll(xs);
        for (0..loops) |index| try out.print("F{d}()<transacts>:i64=Block{{var Ys:[]i64=array{{0,0,0}};For(I->X:Xs,Block{{set Ys[I]=X+{d};X}});Attempt(Ys[0]+Ys[2],0-1)}}\n", .{ index, index });
        try out.print("R<public>:i64=F0()*100+F{d}()", .{loops - 1});
        const x = try one(h, out.buffered());
        try expectInt(x, "R", 400 + 4 + 2 * @as(i64, @intCast(loops - 1)));
        counted.* = h.front.passes;
    }
    try std.testing.expectEqual(passes[0], passes[1]);
    try std.testing.expect(passes[0] <= 4);
}

test "a class made late by a template of the same spelling it cannot name means what it meant" {
    const h = try harness.create();
    defer scratch.release(h);
    // `lateSeen` once read spellings: `Sub:=class(Box)` was declared late because an imported
    // file has a template `Box`, private there and not in `using`, which this `Box` is not.
    // That only moved where `Sub` entered the catalogue; now (`fix2`) only a public template
    // that a qualified name or a `using` reaches counts, so `Sub` is not late at all. Either
    // way everything a program can observe is what it is with a template of another
    // spelling: values, the report, and a later declaration under the class's name refused
    // as before.
    const source = "L:=import{\"lib.forb\"}\nBox<public>:=class{N<public>:i64=1}\nSub<public>:=class(Box){M<public>:i64=2}\nMake(S:Sub)<transacts>:i64=S.M+S.N\nHeld<public>:Box=Sub{}\nEarly<public>:i64=Make(Sub{})\nLate<public>:i64=Held.N+L.Five()";
    var reports: [2][512]u8 = undefined;
    var lengths: [2]usize = undefined;
    var lates: [2]u32 = undefined;
    for ([_][]const u8{ "Crate", "Box" }, 0..) |spelling, index| {
        var lib: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&lib, "{s}[T:type]:=class{{V:T}}\nHidden:{s}[i64]={s}[i64]{{V:=5}}\nFive<public>()<computes>:i64=5", .{ spelling, spelling, spelling });
        const x = try execute(h, &.{ .{ .path = "main.forb", .source = source }, .{ .path = "lib.forb", .source = text } });
        lates[index] = h.front.late_count;
        try expectInt(x, "Early", 3);
        try expectInt(x, "Late", 6);
        var out = std.Io.Writer.fixed(&reports[index]);
        _ = try @import("value_report.zig").write(&out, x, true, .{});
        lengths[index] = out.buffered().len;
        const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nBox:=class{N:i64=1}\nSub:=class(Box){M:i64=2}\nF(Sub:i64)<computes>:i64=Sub" }, .{ .path = "lib.forb", .source = text } } });
        try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, refused.failed.diagnostic.code);
    }
    // The spelling no longer makes `Sub` late: only the template is, in both.
    try std.testing.expectEqual(lates[0], lates[1]);
    try std.testing.expectEqualStrings(reports[0][0..lengths[0]], reports[1][0..lengths[1]]);
}
