//! The effect families of RFC-0078: `<reads>`, `<writes>`, `<allocates>` under `<transacts>`,
//! `<suspends>`, `<converges>`, effects on classes, and a function with fewer effects standing
//! where more are expected. Both machines admit the declared sets on their own.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const catalogue = @import("aggregate_types.zig");
const native = @import("native.zig");
const harness = @import("generic_function_tests.zig");

const Code = types.Diagnostic.Code;

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
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

/// `expectRefused` for each row of a table; the rows that fail are printed, then the test fails.
fn expectAllRefused(h: *harness.Harness, head: []const u8, rows: []const struct { []const u8, Code, []const u8 }) !void {
    var wrong: usize = 0;
    for (rows) |row| {
        var buffer: [2048]u8 = undefined;
        expectRefused(h, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, row[0] }), row[1], row[2]) catch {
            wrong += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

/// Both machines refuse `p` at admission and leave their storage as it was.
fn invalid(h: *harness.Harness, p: types.Program) !void {
    h.values[0] = .{ .integer = 91 };
    h.runtime.machine.values[0] = .{ .integer = 92 };
    try std.testing.expectEqual(Code.invalid_ir, evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096).failed.code);
    try std.testing.expectEqual(Code.invalid_bytecode, h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 4096).failed.code);
    try std.testing.expectEqual(@as(i64, 91), h.values[0].integer);
    try std.testing.expectEqual(@as(i64, 92), h.runtime.machine.values[0].integer);
}

fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (std.mem.eql(u8, f.name.text(p.source), name)) return index;
    unreachable;
}

const reads_only = types.heapDetail(true, false, false);
const writes_only = types.heapDetail(false, true, false);
const allocates_only = types.heapDetail(false, false, true);

// ---- the lattice

test "an effect set has one encoding, and fewer effects lie within more" {
    const computes = types.effectSet(false, false, .{});
    const transacts = types.effectSet(true, false, .{});
    const reads = types.effectSet(true, false, reads_only);
    const writes = types.effectSet(true, false, writes_only);
    const failing = types.effectSet(false, true, .{});
    const waiting = types.effectSet(false, false, .{ .suspends = true });
    const converging = types.effectSet(false, false, .{ .converges = true });
    try std.testing.expect(computes.within(reads) and reads.within(transacts) and computes.within(transacts));
    try std.testing.expect(!transacts.within(reads) and !reads.within(computes) and !reads.within(writes) and !writes.within(reads));
    try std.testing.expect(computes.within(failing) and !failing.within(computes) and !failing.within(transacts));
    try std.testing.expect(computes.within(waiting) and !waiting.within(transacts) and !waiting.within(failing));
    // Converging is a promise, so the converging function is the one with fewer effects.
    try std.testing.expect(converging.within(computes) and !computes.within(converging));
    // All three heap effects are `<transacts>` and nothing else.
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(types.heapDetail(true, true, true))));
    try std.testing.expect(types.effectsCanonical(true, true, reads_only) and types.effectsCanonical(false, true, .{}));
    try std.testing.expect(!types.effectsCanonical(false, false, reads_only));
    try std.testing.expect(!types.effectsCanonical(true, false, .{ .no_reads = true, .no_writes = true, .no_allocates = true }));
    try std.testing.expect(!types.effectsCanonical(true, true, .{ .suspends = true }));
    try std.testing.expect(!types.effectsCanonical(true, false, .{ .reserved = 1 }));
    // Every pair of the 32 heap, failure and suspension sets: `within` is the subset order.
    for (0..32) |a| for (0..32) |b| {
        const left: types.EffectSet = @bitCast(@as(u8, @intCast(a)));
        const right: types.EffectSet = @bitCast(@as(u8, @intCast(b)));
        try std.testing.expectEqual(a & ~b == 0, left.within(right));
    };
}

// ---- what requires which

test "reading needs reads, set needs writes and construction needs allocates, each alone" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=10
        \\box:=class{var N:i64=5}
        \\Q:box=box{}
        \\Peek()<reads>:i64=C+Q.N
        \\Put(V:i64)<writes>:i64=Block{set C=V;set Q.N=V+1;V}
        \\Make(V:i64)<allocates>:box=box{N:=V}
        \\Both(V:i64)<reads><writes>:i64=Block{set C=C+V;C}
        \\Size(B:box)<reads>:i64=B.N
        \\Local(V:i64)<writes>:i64=Block{var T:i64=V;set T=T+1;T}
        \\Any(V:i64)<allocates><reads><writes>:i64=Block{B:=box{N:=V};set B.N=B.N+C;B.N}
        \\Old(V:i64)<transacts>:i64=Block{B:=box{N:=V};set B.N=B.N+C;B.N}
        \\Loose(V:i64)<decides><reads>:i64=Block{Require[V<C];V}
        \\A<public>:i64=Peek()
        \\B<public>:i64=Put(20)
        \\D<public>:i64=Peek()
        \\E<public>:i64=Size(Make(7))
        \\F<public>:i64=Both(3)
        \\G<public>:i64=Local(8)
        \\H<public>:i64=Any(1)+Old(1)
        \\I<public>:i64=Attempt(Loose[5],-1)+Attempt(Loose[50],-1)
    );
    try expectInt(x, "A", 15);
    try expectInt(x, "B", 20);
    try expectInt(x, "D", 41);
    try expectInt(x, "E", 7);
    try expectInt(x, "F", 23);
    try expectInt(x, "G", 9);
    try expectInt(x, "H", 48);
    try expectInt(x, "I", 4);
    const p = x.program;
    // The declared sets reach the IR as written, and three additive effects are `<transacts>`.
    try std.testing.expectEqual(reads_only, p.functions[functionNamed(p, "Peek")].detail);
    try std.testing.expectEqual(writes_only, p.functions[functionNamed(p, "Put")].detail);
    try std.testing.expectEqual(allocates_only, p.functions[functionNamed(p, "Make")].detail);
    try std.testing.expectEqual(types.heapDetail(true, true, false), p.functions[functionNamed(p, "Both")].detail);
    try std.testing.expectEqual(types.EffectDetail{}, p.functions[functionNamed(p, "Any")].detail);
    try std.testing.expectEqual(p.functions[functionNamed(p, "Any")].effects(), p.functions[functionNamed(p, "Old")].effects());
    for (p.functions) |f| try std.testing.expect(f.transacts and types.effectsCanonical(f.transacts, f.decides, f.detail));
    try std.testing.expect(p.functions[functionNamed(p, "Loose")].decides);
}

test "every heap effect is rolled back when the failure context it ran in fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var W:i64=1
        \\cell:=class{var N:i64=0}
        \\Kept:cell=cell{}
        \\Put(V:i64)<writes><decides>:i64=Block{set W=V;set Kept.N=V;Require[V<5];V}
        \\Mint(V:i64)<allocates><decides>:cell=Block{X:=cell{N:=V};Require[V<5];X}
        \\Look(V:i64)<reads><decides>:i64=Block{Require[W<V];W}
        \\Try(V:i64)<writes>:i64=Attempt(Block{set W=V;Require[false];1},0)
        \\A<public>:i64=Attempt(Put[9],-1)
        \\A1<public>:i64=W*100+Kept.N
        \\B<public>:i64=Attempt(Put[3],-1)
        \\B1<public>:i64=W*100+Kept.N
        \\D<public>:i64=Attempt(Mint[9].N,-1)+Attempt(Mint[4].N,-1)
        \\E<public>:i64=Attempt(Look[9],-1)+Attempt(Look[2],-1)
        \\F<public>:i64=Try(77)
        \\F1<public>:i64=W
    );
    try expectInt(x, "A", -1);
    try expectInt(x, "A1", 100);
    try expectInt(x, "B", 3);
    try expectInt(x, "B1", 303);
    try expectInt(x, "D", 3);
    try expectInt(x, "E", 2);
    try expectInt(x, "F", 0);
    try expectInt(x, "F1", 3);
}

// ---- sub-effecting

test "a function with fewer effects is a value of every function type that allows more" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=10
        \\Pure(X:i64)<computes>:i64=X+1
        \\Peek(X:i64)<reads>:i64=X+C
        \\Bump(X:i64)<transacts>:i64=Block{set C=C+X;C}
        \\Sure(X:i64)<computes><decides>:i64=Block{Require[X>0];X}
        \\A:function<transacts>(tuple(i64),i64)=Pure
        \\B:function<reads>(tuple(i64),i64)=Pure
        \\D:function<transacts>(tuple(i64),i64)=Peek
        \\E:function<computes><decides>(tuple(i64),i64)=Pure
        \\G:function<transacts><decides>(tuple(i64),i64)=Sure
        \\H:function<reads><writes>(tuple(i64),i64)=Peek
        \\Use(F:function<transacts>(tuple(i64),i64),X:i64)<transacts>:i64=F(X)
        \\Ask(F:function<reads>(tuple(i64),i64),X:i64)<reads>:i64=F(X)
        \\Pick(N:i64)<computes>:function<reads>(tuple(i64),i64)=Block{Wide:function<reads>(tuple(i64),i64)=Pure;If(N==0,Wide,Peek)}
        \\P0:function<reads>(tuple(i64),i64)=Pick(0)
        \\P1:function<reads>(tuple(i64),i64)=Pick(1)
        \\pair:=struct{Run:function<transacts>(tuple(i64),i64)}
        \\Pr:pair=pair{Run:=Peek}
        \\Held:function<transacts>(tuple(i64),i64)=Pr.Run
        \\var V:function<reads>(tuple(i64),i64)=Pure
        \\Swap()<writes>:i64=Block{set V=Peek;0}
        \\R1<public>:i64=A(1)
        \\R2<public>:i64=B(2)
        \\R3<public>:i64=D(3)
        \\R4<public>:i64=Attempt(E[4],-1)
        \\R5<public>:i64=Attempt(G[5],-1)+Attempt(G[-5],-1)
        \\R6<public>:i64=Use(Pure,5)+Use(Peek,6)+Use(Bump,7)
        \\R7<public>:i64=Ask(Pure,1)+Ask(Peek,1)+H(1)
        \\R8<public>:i64=P0(1)+P1(1)
        \\R9<public>:i64=Held(1)
        \\R10<public>:i64=V(1)+Swap()+V(1)
        \\Fs:[]function<transacts>(tuple(i64),i64)=array{Pure,Peek,Bump}
        \\R11<public>:i64=Fs.Length
        \\L:function<transacts>(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N*2}
        \\R12<public>:i64=L(21)
    );
    try expectInt(x, "R1", 2);
    try expectInt(x, "R2", 3);
    try expectInt(x, "R3", 13);
    try expectInt(x, "R4", 5);
    try expectInt(x, "R5", 4);
    try expectInt(x, "R6", 6 + 16 + 17);
    try expectInt(x, "R7", 2 + 18 + 18);
    try expectInt(x, "R8", 2 + 18);
    try expectInt(x, "R9", 18);
    try expectInt(x, "R10", 2 + 0 + 18);
    try expectInt(x, "R11", 3);
    try expectInt(x, "R12", 42);
    // The value of a widened function carries the type it is used at, in both machines.
    const a = x.get("A").?.callable;
    try std.testing.expectEqual(catalogue.definition(a.value_type, x.program.definitions).?.callable.effects(), types.effectSet(true, false, .{}));
    try std.testing.expectEqual(functionNamed(x.program, "Pure"), a.function);
}

test "an effect is never taken away: wider functions, failing ones and other shapes are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "var C:i64=1\nPure(X:i64)<computes>:i64=X\nPeek(X:i64)<reads>:i64=X+C\nBump(X:i64)<transacts>:i64=Block{set C=C+X;C}\nSure(X:i64)<computes><decides>:i64=Block{Require[X>0];X}\nWait(X:i64)<computes><suspends>:i64=X\n";
    for ([_]struct { []const u8, []const u8 }{
        .{ "A:function(tuple(i64),i64)=Peek", "Peek" },
        .{ "A:function<reads>(tuple(i64),i64)=Bump", "Bump" },
        .{ "A:function<writes>(tuple(i64),i64)=Peek", "Peek" },
        .{ "A:function<reads><allocates>(tuple(i64),i64)=Bump", "Bump" },
        .{ "A:function<transacts>(tuple(i64),i64)=Sure", "Sure" },
        .{ "A:function<transacts><decides>(tuple(i64),i64)=Wait", "Wait" },
        .{ "A:function<transacts>(tuple(i64),i64)=Wait", "Wait" },
        .{ "A:function<computes><converges>(tuple(i64),i64)=Pure", "Pure" },
        .{ "A:function<transacts>(tuple(i64),logic)=Pure", "Pure" },
        .{ "A:function<transacts>(tuple(logic),i64)=Pure", "Pure" },
        .{ "Use(F:function<reads>(tuple(i64),i64))<reads>:i64=F(1)\nA:i64=Use(Bump)", "Bump" },
    }) |c| {
        var buffer: [512]u8 = undefined;
        try expectRefused(h, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, c[0] }), .type_mismatch, c[1]);
    }
}

test "an override and an interface implementation may narrow the effects of the slot, never widen them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Shape:=class<abstract>{
        \\var Scale:i64=2
        \\Area<abstract>()<transacts>:i64
        \\Check<abstract>(N:i64)<reads><decides>:i64
        \\}
        \\Square:=class(Shape){
        \\Side:i64=3
        \\Area<override>()<reads>:i64=Self.Side*Self.Scale
        \\Check<override>(N:i64)<reads>:i64=N+Self.Scale
        \\}
        \\Dot:=class(Shape){
        \\Area<override>()<computes>:i64=1
        \\Check<override>(N:i64)<computes><decides>:i64=Block{Require[N>0];N}
        \\}
        \\Grow:=class(Shape){
        \\Area<override>()<writes><reads>:i64=Block{set Self.Scale=Self.Scale+1;Self.Scale}
        \\Check<override>(N:i64)<computes>:i64=N
        \\}
        \\Sized:=interface{
        \\Size()<reads>:i64
        \\}
        \\Pebble:=class(Sized){
        \\Size<override>()<computes>:i64=4
        \\}
        \\Total(S:Shape)<transacts>:i64=S.Area()
        \\Probe(S:Shape,N:i64)<reads>:i64=Attempt(S.Check[N],-1)
        \\Weigh(S:Sized)<reads>:i64=S.Size()
        \\A<public>:i64=Total(Square{})*100+Total(Dot{})*10+Total(Grow{})
        \\B<public>:i64=Probe(Square{},5)*100+Probe(Dot{},-5)*10+Probe(Grow{},5)
        \\D<public>:i64=Weigh(Pebble{})
        \\M:function<transacts>(tuple(),i64)=Square{}.Area
        \\E<public>:i64=M()
    );
    try expectInt(x, "A", 613);
    try expectInt(x, "B", 695);
    try expectInt(x, "D", 4);
    try expectInt(x, "E", 6);
    const base = "Shape:=class<abstract>{\nvar Scale:i64=2\nArea<abstract>()<reads>:i64\nPlain<abstract>()<computes>:i64\n}\n";
    try expectAllRefused(h, base, &.{
        .{ "Bad:=class(Shape){\nArea<override>()<transacts>:i64=1\nPlain<override>()<computes>:i64=1\n}", .override_widens_writes, "Area" },
        .{ "Bad:=class(Shape){\nArea<override>()<reads><writes>:i64=1\nPlain<override>()<computes>:i64=1\n}", .override_widens_writes, "Area" },
        .{ "Bad:=class(Shape){\nArea<override>()<allocates>:i64=1\nPlain<override>()<computes>:i64=1\n}", .override_widens_allocates, "Area" },
        .{ "Bad:=class(Shape){\nArea<override>()<reads><decides>:i64=1\nPlain<override>()<computes>:i64=1\n}", .override_widens_decides, "Area" },
        .{ "Bad:=class(Shape){\nArea<override>()<reads>:i64=1\nPlain<override>()<reads>:i64=1\n}", .override_widens_reads, "Plain" },
        .{ "Bad:=class(Shape){\nArea<override>()<reads>:i64=1\nPlain<override>()<computes><suspends>:i64=1\n}", .override_widens_suspends, "Plain" },
        .{ "Bad:=class(Shape){\nArea<override>()<reads>:logic=true\nPlain<override>()<computes>:i64=1\n}", .override_mismatch, "Area" },
    });
    try expectRefused(h, "Sized:=interface{\nSize()<reads>:i64\n}\nRock:=class(Sized){\nSize<override>()<transacts>:i64=1\n}", .override_widens_writes, "Size");
    // A call through a type asks for the effects its slot declares, whatever the override has.
    try expectRefused(h, "Shape:=class<abstract>{\nArea<abstract>()<transacts>:i64\n}\nDot:=class(Shape){\nArea<override>()<computes>:i64=1\n}\nF(D:Dot)<computes>:i64=D.Area()", .call_requires_transacts, "(");
}

// ---- functions that are not named

test "an anonymous function states its effect or takes the heap effects around it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=10
        \\L:function<reads>(tuple(i64),i64)=Fn(N:i64){N+C}
        \\M:function<reads>(tuple(i64),i64)=Fn(N:i64)<reads>:i64{N+C}
        \\Make(K:i64)<reads>:function<reads>(tuple(i64),i64)=Fn(N:i64){N+K+C}
        \\Twice(F:function<reads>(tuple(i64),i64),X:i64)<reads>:i64=F(F(X))
        \\Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{F(F(X))}
        \\Peek(X:i64)<reads>:i64=X+C
        \\Count(N:i64)<reads><writes>:i64=Block{var I:i64=0;var T:i64=0;While(I<N,Block{set T=T+C;set I=I+1});T}
        \\H<public>:i64=Count(3)
        \\A<public>:i64=L(1)+M(2)
        \\B<public>:i64=Make(5)(1)
        \\D<public>:i64=Twice(Fn(N:i64)<reads>:i64{N*C},2)
        \\E<public>:i64=Apply[reads,i64](Peek,1)
        \\G<public>:i64=Apply[writes<reads>,i64](Peek,1)
    );
    try expectInt(x, "A", 23);
    try expectInt(x, "B", 16);
    try expectInt(x, "D", 200);
    try expectInt(x, "E", 21);
    try expectInt(x, "G", 21);
    try expectInt(x, "H", 30);
    try expectRefused(h, "var C:i64=1\nL:function<reads>(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N+C}", .variable_read_requires_reads, "C");
    try expectRefused(h, "var C:i64=1\nF()<reads>:function<reads>(tuple(i64),i64)=Fn(N:i64){Block{set C=N;N}}", .set_requires_writes, "C");
    try expectRefused(h, "var C:i64=1\nApply[E:effect](F:function<E>(tuple(i64),i64))<E>:i64{F(1)}\nPeek(X:i64)<reads>:i64=X+C\nA:i64=Apply[computes](Peek)", .type_mismatch, "Peek");
}

// ---- classes

test "a class states the effect of building it, which bounds its block clauses and binds every construction" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var C:i64=4
        \\Tag:=class<computes>{N:i64=1}
        \\Seen:=class<reads>{
        \\var N:i64=0
        \\Block{C+Self.N}
        \\}
        \\Log:=class<transacts>{
        \\var N:i64=0
        \\Block{set Self.N=C;set C=C+1}
        \\}
        \\Deep:=class<transacts>(Log){}
        \\Free:=class{
        \\var N:i64=0
        \\Block{set Self.N=7}
        \\}
        \\Marked:=interface<reads>{}
        \\Pin:=class<reads>(Marked){}
        \\MakeTag()<allocates>:Tag=Tag{}
        \\MakeLog()<transacts>:Log=Log{}
        \\MakeDeep()<reads><writes><allocates>:Deep=Deep{}
        \\MakeFree()<transacts>:Free=Free{}
        \\MakePin()<reads><allocates>:Pin=Pin{}
        \\Read(T:Tag)<reads>:i64=T.N
        \\A<public>:i64=Read(MakeTag())
        \\B<public>:i64=MakeLog().N*10+MakeDeep().N
        \\D<public>:i64=MakeFree().N+C
    );
    try expectInt(x, "A", 1);
    try expectInt(x, "B", 45);
    try expectInt(x, "D", 13);
    try expectAllRefused(h, "", &.{
        .{ "Log:=class<transacts>{}\nBad()<allocates>:Log=Log{}", .class_effect_required_reads, "Log" },
        .{ "Log:=class<reads>{}\nBad()<allocates><writes>:Log=Log{}", .class_effect_required_reads, "Log" },
        .{ "Free:=class{\nvar N:i64=0\nBlock{set Self.N=7}\n}\nBad()<allocates>:Free=Free{}", .call_requires_reads_writes, "Free" },
        .{ "Tag:=class{}\nBad()<reads><writes>:Tag=Tag{}", .construction_requires_allocates, "Tag" },
        .{ "Bad:=class<computes>{\nvar N:i64=0\nBlock{set Self.N=7}\n}", .set_requires_writes, "." },
        .{ "var C:i64=1\nBad:=class<writes>{\nvar N:i64=0\nBlock{set Self.N=C}\n}", .variable_read_requires_reads, "C" },
        .{ "Bad:=class<decides>{}", .class_effect_specifier, "decides" },
        .{ "Bad:=class<suspends>{}", .class_effect_specifier, "suspends" },
        .{ "Bad:=interface<converges>{}", .class_effect_specifier, "converges" },
        .{ "Bad:=interface<abstract>{}", .unsupported_specifier, "abstract" },
        .{ "Bad:=class<computes><reads>{}", .effect_specifier_conflict, "reads" },
        .{ "Log:=class<transacts>{}\nBad:=class<computes>(Log){}", .class_effect_narrower_reads, "Bad" },
        .{ "Marked:=interface<transacts>{}\nBad:=class<reads>(Marked){}", .class_effect_narrower_writes, "Bad" },
        // What a supertype states is what a class has when it states nothing.
        .{ "Log:=class<transacts>{}\nSub:=class(Log){}\nBad()<allocates>:Sub=Sub{}", .class_effect_required_reads, "Sub" },
    });
}

// ---- suspends and converges

test "a suspending function is declared, checked and called only from a suspending function" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "var C:i64=1\nWait(N:i64)<computes><suspends>:i64=N+1\nPoll(N:i64)<suspends><reads>:i64=Wait(N)+C\nTask:=class<abstract>{\nRun<abstract>()<computes><suspends>:i64\n}\n";
    const x = try h.execute(head ++
        \\Cycle(N:i64)<reads><writes><suspends>:i64=Block{var T:i64=0;While(T<N,Block{set T=T+Poll(1)});If(T>0,Wait(T),Wait(0))}
        \\Step(T:Task)<computes><suspends>:i64=T.Run()
        \\Later(F:function<computes><suspends>(tuple(i64),i64))<computes><suspends>:i64=F(1)
        \\Both()<computes><suspends>:i64=Later(Wait)+Later(Fn(N:i64){N})
        \\Hold:function<reads><suspends>(tuple(i64),i64)=Poll
        \\Calm:function<computes><suspends>(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N}
        \\Sure(N:i64)<computes><decides>:i64=Block{Require[N>0];N}
        \\Guard(N:i64)<computes><suspends>:i64=If(Sure[N]>0,Wait(N),Attempt(Sure[N],0))
        \\Spin(N:i64)<writes><suspends>:i64=Block{var T:i64=0;Loop{If(T>N,Break(),false);set T=T+Wait(1)};T}
        \\Value<public>:i64=7
    );
    try expectInt(x, "Value", 7);
    const p = x.program;
    try std.testing.expect(p.functions[functionNamed(p, "Wait")].detail.suspends and !p.functions[functionNamed(p, "Wait")].transacts);
    try std.testing.expectEqual(types.EffectDetail{ .no_writes = true, .no_allocates = true, .suspends = true }, p.functions[functionNamed(p, "Poll")].detail);
    try expectAllRefused(h, head, &.{
        .{ "F()<computes>:i64=Wait(1)", .call_requires_suspends, "Wait" },
        .{ "F()<transacts>:i64=Wait(1)", .call_requires_suspends, "Wait" },
        .{ "A:i64=Wait(1)", .call_requires_suspends, "Wait" },
        .{ "F()<computes><decides>:i64=Wait(1)", .call_requires_suspends, "Wait" },
        .{ "F()<computes><suspends>:i64=Poll(1)", .call_requires_reads, "Poll" },
        .{ "F()<computes><suspends>:i64=Attempt(Wait(1),0)", .suspends_in_failure_context, "Wait" },
        .{ "F()<computes><suspends>:i64=If(Wait(1)>0,1,2)", .suspends_in_failure_context, "Wait" },
        .{ "F()<computes><suspends>:i64=Block{Defer{Wait(1)};2}", .suspends_in_failure_context, "Wait" },
        .{ "F()<computes><suspends>:option(i64)=option{Wait(1)}", .suspends_in_failure_context, "Wait" },
        .{ "F()<computes><suspends>:[]i64=For(X:1..3,Wait(X)>0,X)", .suspends_in_failure_context, "Wait" },
        .{ "F()<computes><suspends>:logic=While(Wait(1)>0,false)", .suspends_in_failure_context, "Wait" },
        .{ "F(T:Task)<computes>:i64=T.Run()", .call_requires_suspends, "(" },
        .{ "F(G:function<computes><suspends>(tuple(i64),i64))<computes>:i64=G(1)", .call_requires_suspends, "(" },
        .{ "H:function<computes><suspends>(tuple(i64),i64)=Wait\nA:i64=H(1)", .call_requires_suspends, "(" },
        .{ "F()<computes>:i64=Iterate(Wait,2,0)", .call_requires_suspends, "Wait" },
        .{ "F()<computes><decides><suspends>:i64=1", .decides_with_suspends, "suspends" },
        .{ "F()<suspends><computes><decides>:i64=1", .decides_with_suspends, "decides" },
        .{ "A:function<computes><suspends><decides>(tuple(),i64)=0", .decides_with_suspends, "decides" },
    });
}

test "converges is written on a native's entry, an abstract method and a function type, and nowhere else" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Sum:=native{"std.sum"}
        \\Shape:=class<abstract>{
        \\Area<abstract>()<computes><converges>:i64
        \\}
        \\Sized:=interface{
        \\Size()<converges><reads>:i64
        \\}
        \\Dot:=class(Shape,Sized){
        \\Area<override>()<computes>:i64=3
        \\Size<override>()<computes>:i64=4
        \\}
        \\Run(F:function<computes><converges>(tuple(i64),i64),X:i64)<computes>:i64=F(X)
        \\Total(Xs:[]i64)<computes>:i64=Sum(Xs)
        \\A<public>:i64=Dot{}.Area()+Dot{}.Size()+Total(array{1,2,3})
    );
    try expectInt(x, "A", 13);
    // Every standard native is pure and bounded by its input: the narrowest set there is.
    for (h.front.natives) |entry| {
        try std.testing.expect(native.wellFormed(entry));
        try std.testing.expectEqual(types.EffectSet{ .diverges = false }, entry.effects);
    }
    try expectRefused(h, "F()<computes><converges>:i64=1", .converges_position, "converges");
    try expectRefused(h, "F()<converges>:i64=1", .converges_position, "converges");
    try expectRefused(h, "A:function<computes>(tuple(),i64)=Fn()<computes><converges>:i64{1}", .converges_position, "converges");
    try expectRefused(h, "c:=class{\nF()<computes><converges>:i64=1\n}", .converges_position, "F");
    try expectRefused(h, "I:=interface{\nF()<computes><converges>:i64=1\n}", .converges_position, "F");
    try expectRefused(h, "F[T:type](X:T)<computes><converges>:T{X}\nA:i64=F[i64](1)", .converges_position, "converges");
    try expectRefused(h, "c:=class{}\nMake<constructor>()<allocates><converges>:=c{}", .converges_position, "converges");
    try expectRefused(h, "A:function<converges>(tuple(),i64)=0", .unsupported_specifier, "converges");
}

// ---- diagnostics

test "each missing effect is named with the construct that needs it" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "var C:i64=1\nbox:=class{var N:i64=5}\nQ:box=box{}\nHas:=interface{var V:i64=1}\nIt:=class(Has){}\nPeek()<reads>:i64=C\nPut()<writes>:i64=Block{set C=2;2}\nMake()<allocates>:box=box{}\nRW()<reads><writes>:i64=Block{set C=C+1;C}\nRA()<reads><allocates>:box=box{N:=C}\nWA()<writes><allocates>:box=Block{set C=2;box{}}\nAll()<transacts>:i64=Block{set C=C+1;box{}.N}\n";
    try expectAllRefused(h, head, &.{
        .{ "F()<computes>:i64=C", .variable_read_requires_reads, "C" },
        .{ "F()<writes><allocates>:i64=C", .variable_read_requires_reads, "C" },
        .{ "F()<computes>:i64=Q.N", .field_read_requires_reads, "N" },
        .{ "F(B:box)<writes><allocates>:i64=B.N", .field_read_requires_reads, "N" },
        .{ "F(H:Has)<writes><allocates>:i64=H.V", .field_read_requires_reads, "V" },
        .{ "F()<computes>:i64=Block{set C=2;2}", .set_requires_writes, "C" },
        .{ "F()<reads><allocates>:i64=Block{set C=2;2}", .set_requires_writes, "C" },
        .{ "F()<reads><allocates>:i64=Block{set Q.N=2;2}", .set_requires_writes, "." },
        .{ "F(H:Has)<reads><allocates>:i64=Block{set H.V=2;2}", .set_requires_writes, "." },
        .{ "F()<reads><allocates>:i64=Block{var T:i64=1;set T=2;T}", .local_var_requires_writes, "T" },
        .{ "F()<reads>:i64=Block{set C+=1;C}", .set_requires_writes, "C" },
        .{ "F()<writes>:i64=Block{set C+=1;2}", .variable_read_requires_reads, "C" },
        .{ "F()<computes>:box=box{}", .construction_requires_allocates, "box" },
        .{ "F()<reads><writes>:box=box{}", .construction_requires_allocates, "box" },
        .{ "F()<computes>:i64=Peek()", .call_requires_reads, "Peek" },
        .{ "F()<writes><allocates>:i64=Peek()", .call_requires_reads, "Peek" },
        .{ "F()<reads><allocates>:i64=Put()", .call_requires_writes, "Put" },
        .{ "F()<reads><writes>:box=Make()", .call_requires_allocates, "Make" },
        .{ "F()<allocates>:i64=RW()", .call_requires_reads_writes, "RW" },
        .{ "F()<writes>:box=RA()", .call_requires_reads_allocates, "RA" },
        .{ "F()<reads>:box=WA()", .call_requires_writes_allocates, "WA" },
        .{ "F()<computes>:i64=All()", .call_requires_transacts, "All" },
        .{ "F()<reads>:i64=All()", .call_requires_writes_allocates, "All" },
        .{ "F(G:function<reads>(tuple(),i64))<computes>:i64=G()", .call_requires_reads, "(" },
        .{ "F(G:function<transacts>(tuple(),i64))<allocates>:i64=G()", .call_requires_reads_writes, "(" },
        .{ "(V:i64).Seen()<reads>:i64=V+C\nF(X:i64)<computes>:i64=X.Seen()", .call_requires_reads, "Seen" },
        .{ "F()<computes>:i64=Iterate(Fn(N:i64)<reads>:i64{N+C},2,0)", .call_requires_reads, "Fn" },
        // A signature says its heap effect once and in one way.
        .{ "F()<decides>:i64=1", .expected_computes, "decides" },
        .{ "F()<suspends>:i64=1", .expected_computes, "suspends" },
        .{ "F():i64=1", .expected_computes, ":" },
        .{ "F()<varies>:i64=1", .expected_computes, "varies" },
        .{ "F()<computes><varies>:i64=1", .unsupported_specifier, "varies" },
        // `<predicts>` is accepted beside a heap effect (RFC-0085, I12), and is none itself.
        .{ "F()<predicts>:i64=1", .expected_computes, "predicts" },
        .{ "F()<computes><predicts><predicts>:i64=1", .effect_specifier_repeated, "predicts" },
        .{ "F()<computes><computes>:i64=1", .effect_specifier_repeated, "computes" },
        .{ "F()<computes><transacts>:i64=1", .effect_specifier_conflict, "transacts" },
        .{ "F()<transacts><reads>:i64=1", .effect_specifier_conflict, "reads" },
        .{ "F()<reads><computes>:i64=1", .effect_specifier_conflict, "computes" },
        .{ "F()<reads><reads>:i64=1", .effect_specifier_repeated, "reads" },
        .{ "F()<reads><decides><decides>:i64=1", .effect_specifier_repeated, "decides" },
        .{ "A:function<reads><transacts>(tuple(),i64)=0", .effect_specifier_conflict, "transacts" },
        .{ "A:function<decides>(tuple(),i64)=0", .unsupported_specifier, "decides" },
        .{ "Apply[E:effect](F:function<E>(tuple(),i64))<E>:i64{F()}\nA:i64=Apply[decides](Peek)", .expected_computes, "decides" },
        .{ "Apply[E:effect](F:function<E>(tuple(),i64))<E>:i64{F()}\nA:i64=Apply[reads<reads>](Peek)", .effect_specifier_repeated, "reads" },
    });
    // A module's own initialisers read, write and build freely, as they always did.
    const x = try h.execute(head ++ "set C=C+Q.N\nA<public>:i64=C+box{N:=3}.N+Peek()+All()");
    try expectInt(x, "A", 6 + 3 + 6 + 5);
}

test "the defaults of a method's parameters see the heap effects the method declares" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\c:=class{
        \\var V:i64=4
        \\Get(N:i64=Self.V)<reads>:i64=N
        \\Put(N:i64=Self.V+1)<writes><reads>:i64=Block{set Self.V=N;N}
        \\Try(N:i64=Self.V)<decides><reads>:i64=Block{Require[N>0];N}
        \\}
        \\X:=c{}
        \\A<public>:i64=X.Get()*100+X.Put()*10+Attempt(X.Try[],-1)
    );
    try expectInt(x, "A", 455);
    try expectRefused(h, "c:=class{\nvar V:i64=4\nGet(N:i64=Self.V)<computes>:i64=N\n}", .field_read_requires_reads, "V");
    try expectRefused(h, "c:=class{\nvar V:i64=4\nGet(N:i64=Self.V)<writes>:i64=N\n}", .field_read_requires_reads, "V");
}

// ---- forged IR

/// `p` with its function table and bodies in the harness, to be forged and restored.
fn forgeable(h: *harness.Harness, p: types.Program) types.Program {
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    var forged = p;
    forged.functions = h.metadata[0..p.functions.len];
    forged.function_nodes = h.body[0..p.function_nodes.len];
    return forged;
}

test "a function that claims fewer effects than its body has is refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\var C:i64=1
        \\box:=class{var N:i64=5}
        \\Q:box=box{}
        \\Peek()<reads>:i64=C
        \\Field()<reads>:i64=Q.N
        \\Put()<writes>:i64=Block{set C=2;2}
        \\Poke()<writes>:i64=Block{set Q.N=2;2}
        \\Local()<writes>:i64=Block{var T:i64=1;set T=2;T}
        \\Make()<allocates>:box=box{}
        \\Calls()<reads>:i64=Peek()
        \\Uses(F:function<reads>(tuple(),i64))<reads>:i64=F()
        \\Steps()<writes>:i64=Iterate(Fn(N:i64)<writes>:i64{Block{set C=N;N}},2,0)
        \\Value<public>:i64=Peek()+Field()+Put()+Poke()+Local()+Make().N+Calls()+Uses(Peek)+Steps()
    );
    const baseline = (try h.run(p, 1 << 16)).ok.get("Value").?.integer;
    const forged = forgeable(h, p);
    const names = [_][]const u8{ "Peek", "Field", "Put", "Poke", "Local", "Make", "Calls", "Uses", "Steps" };
    const needed = [_]types.EffectSet{
        .{ .reads = true },     .{ .reads = true }, .{ .writes = true }, .{ .writes = true }, .{ .writes = true },
        .{ .allocates = true }, .{ .reads = true }, .{ .reads = true },  .{ .writes = true },
    };
    for (names, needed) |name, need| {
        const id = functionNamed(p, name);
        // Every heap set: the function is admitted exactly when the set has what its body needs.
        for (0..8) |bits| {
            @memcpy(h.metadata[0..p.functions.len], p.functions);
            const reads = bits & 1 != 0;
            const writes = bits & 2 != 0;
            const allocates = bits & 4 != 0;
            h.metadata[id].transacts = bits != 0;
            h.metadata[id].detail = if (bits != 0) types.heapDetail(reads, writes, allocates) else .{};
            const claimed = h.metadata[id].effects();
            // `Peek` is also a function value, whose type states its exact set, and the callee
            // of a `<reads>` function; the others are called from the root alone.
            const elsewhere = !std.mem.eql(u8, name, "Peek") or std.meta.eql(claimed, p.functions[id].effects());
            if (need.heap().within(claimed) and elsewhere) {
                try std.testing.expectEqual(baseline, (try h.run(forged, 1 << 16)).ok.get("Value").?.integer);
            } else try invalid(h, forged);
        }
    }
    // The canonical form: nothing given up without a heap effect, never all three, no stray bit.
    const peek = functionNamed(p, "Peek");
    for ([_]struct { bool, types.EffectDetail }{
        .{ false, reads_only },
        .{ false, .{ .no_allocates = true } },
        .{ true, .{ .no_reads = true, .no_writes = true, .no_allocates = true } },
        .{ true, .{ .no_writes = true, .no_allocates = true, .reserved = 1 } },
        .{ true, .{ .no_writes = true, .no_allocates = true, .reserved = 2 } },
        // No body is vouched to converge.
        .{ true, .{ .no_writes = true, .no_allocates = true, .converges = true } },
    }) |c| {
        @memcpy(h.metadata[0..p.functions.len], p.functions);
        h.metadata[peek].transacts = c[0];
        h.metadata[peek].detail = c[1];
        try invalid(h, forged);
    }
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    try std.testing.expectEqual(baseline, (try h.run(forged, 1 << 16)).ok.get("Value").?.integer);
}

test "a forged suspension, a widened callee and a narrowed function type are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\var C:i64=1
        \\Pure(X:i64)<computes>:i64=X
        \\Peek(X:i64)<reads>:i64=X+C
        \\Sure(X:i64)<computes><decides>:i64=Block{Require[X>0];X}
        \\Outer(X:i64)<reads>:i64=Peek(X)
        \\Wait(X:i64)<computes><suspends>:i64=X+2
        \\Poll(X:i64)<computes><suspends>:i64=Wait(X)+1
        \\A:function<transacts>(tuple(i64),i64)=Peek
        \\B:function<computes>(tuple(i64),i64)=Pure
        \\Value<public>:i64=A(1)+B(1)+Outer(1)+Attempt(Sure[1],0)
    );
    const baseline = (try h.run(p, 1 << 16)).ok.get("Value").?.integer;
    try std.testing.expectEqual(@as(i64, 6), baseline);
    var forged = forgeable(h, p);
    // A function called from the root, or from one that does not suspend, starts to suspend.
    h.metadata[functionNamed(p, "Outer")].detail.suspends = true;
    try invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[functionNamed(p, "Poll")].detail.suspends = false;
    try invalid(h, forged);
    // A function that may fail does not suspend.
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[functionNamed(p, "Sure")].detail.suspends = true;
    try invalid(h, forged);
    // The callee of a `<reads>` function claims to write as well.
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    h.metadata[functionNamed(p, "Peek")].detail = types.heapDetail(true, true, false);
    try invalid(h, forged);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    // The upcast of `Peek` is turned to a type that allows less, and to one of another shape.
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    const bindings = try std.testing.allocator.dupe(types.Binding, p.bindings);
    defer std.testing.allocator.free(bindings);
    forged.nodes = nodes;
    forged.bindings = bindings;
    var upcast: ?usize = null;
    for (p.nodes, 0..) |node, index| if (node.kind == .upcast) {
        try std.testing.expect(upcast == null);
        upcast = index;
    };
    const pure_type = p.nodes[p.bindings[findBinding(p, "B")].node].value_type;
    for ([_]types.Type{ pure_type, .i64, p.nodes[p.nodes[upcast.?].kind.upcast].value_type }) |narrower| {
        nodes[upcast.?].value_type = narrower;
        bindings[findBinding(p, "A")].value_type = narrower;
        try invalid(h, forged);
    }
    // A function type in a non-canonical encoding, and one that fails and suspends.
    forged.nodes = p.nodes;
    forged.bindings = p.bindings;
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    forged.definitions = definitions;
    for (p.definitions, 0..) |item, index| {
        if (item != .callable) continue;
        for ([_]types.EffectDetail{ .{ .reserved = 2 }, .{ .no_reads = true, .no_writes = true, .no_allocates = true } }) |detail| {
            @memcpy(definitions, p.definitions);
            definitions[index].callable.detail = detail;
            try invalid(h, forged);
        }
        if (item.callable.decides) {
            @memcpy(definitions, p.definitions);
            definitions[index].callable.detail.suspends = true;
            try invalid(h, forged);
        }
    }
    try std.testing.expectEqual(baseline, (try h.run(p, 1 << 16)).ok.get("Value").?.integer);
}

fn findBinding(p: types.Program, name: []const u8) usize {
    for (p.bindings, 0..) |binding, index| if (std.mem.eql(u8, binding.name.text(p.source), name)) return index;
    unreachable;
}

test "a forged override that does more than its slot allows is refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Shape:=class<abstract>{
        \\var Scale:i64=2
        \\Area<abstract>()<reads>:i64
        \\}
        \\Square:=class(Shape){
        \\Area<override>()<computes>:i64=3
        \\}
        \\Total(S:Shape)<reads>:i64=S.Area()
        \\Value<public>:i64=Total(Square{})
    );
    try std.testing.expectEqual(@as(i64, 3), (try h.run(p, 4096)).ok.get("Value").?.integer);
    const forged = forgeable(h, p);
    const area = functionNamed(p, "Area");
    // Up to the slot's own effects the implementation is admitted; beyond them it is not.
    h.metadata[area].transacts = true;
    h.metadata[area].detail = reads_only;
    try std.testing.expectEqual(@as(i64, 3), (try h.run(forged, 4096)).ok.get("Value").?.integer);
    for ([_]types.EffectDetail{ .{}, types.heapDetail(true, true, false), writes_only, .{ .no_writes = true, .no_allocates = true, .suspends = true } }) |detail| {
        h.metadata[area].detail = detail;
        try invalid(h, forged);
    }
    h.metadata[area].detail = reads_only;
    h.metadata[area].decides = true;
    try invalid(h, forged);
}

// ---- a randomized oracle

const Statement = union(enum) {
    constant: i64,
    read_variable,
    write_variable: i64,
    read_field,
    write_field: i64,
    construct: i64,
    call: usize,
    attempt: usize,
};
const Flow = enum { plain, decides, suspends };
const Generated = struct {
    statements: [4]Statement = undefined,
    count: usize = 0,
    heap: u3 = 0,
    flow: Flow = .plain,
    passes: bool = true,

    fn declared(self: Generated) types.EffectSet {
        return .{ .reads = self.heap & 1 != 0, .writes = self.heap & 2 != 0, .allocates = self.heap & 4 != 0, .decides = self.flow == .decides, .suspends = self.flow == .suspends };
    }
};
const Model = struct {
    variable: i64 = 3,
    field: i64 = 5,

    /// Runs function `id` of `functions`; null when it fails, with its writes undone.
    fn run(self: *Model, functions: []const Generated, id: usize) ?i64 {
        const before = self.*;
        const f = functions[id];
        var total: i64 = 0;
        for (f.statements[0..f.count]) |statement| total += switch (statement) {
            .constant => |k| k,
            .read_variable => self.variable,
            .write_variable => |k| value: {
                self.variable = k;
                break :value k;
            },
            .read_field => self.field,
            .write_field => |k| value: {
                self.field = k;
                break :value k;
            },
            .construct => |k| k,
            .call => |callee| self.run(functions, callee).?,
            .attempt => |callee| self.run(functions, callee) orelse -1,
        };
        if (f.flow == .decides and !f.passes) {
            self.* = before;
            return null;
        }
        return total;
    }
};

/// What the lattice says of one function: its body's heap effects are declared, and it
/// suspends if anything it calls does.
fn modelAccepts(functions: []const Generated, id: usize, claimed: types.EffectSet) bool {
    const f = functions[id];
    for (f.statements[0..f.count]) |statement| {
        const need: types.EffectSet = switch (statement) {
            .constant => .{},
            .read_variable, .read_field => .{ .reads = true },
            .write_variable, .write_field => .{ .writes = true },
            .construct => .{ .allocates = true },
            .call, .attempt => |callee| functions[callee].declared(),
        };
        if (!need.heap().within(claimed)) return false;
        if (need.suspends and !claimed.suspends) return false;
    }
    return true;
}

fn writeEffect(out: *std.ArrayList(u8), random: std.Random, f: Generated) !void {
    var words: [4][]const u8 = undefined;
    var count: usize = 0;
    if (f.heap == 0) {
        words[count] = "computes";
        count += 1;
    } else if (f.heap == 7 and random.boolean()) {
        words[count] = "transacts";
        count += 1;
    } else for ([_][]const u8{ "reads", "writes", "allocates" }, 0..) |word, bit| if (f.heap >> @intCast(bit) & 1 != 0) {
        words[count] = word;
        count += 1;
    };
    if (f.flow != .plain) {
        words[count] = if (f.flow == .decides) "decides" else "suspends";
        count += 1;
    }
    // The specifiers of a signature are read in any order.
    random.shuffle([]const u8, words[0..count]);
    for (words[0..count]) |word| try out.print(std.testing.allocator, "<{s}>", .{word});
}

test "random bodies under random declared sets compile exactly when the lattice says so, and forged sets are admitted exactly then" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0078_eff3);
    const random = prng.random();
    var compiled: usize = 0;
    var refused: usize = 0;
    var forged_admitted: usize = 0;
    var forged_refused: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    for (0..600) |_| {
        var functions: [4]Generated = undefined;
        const count = 2 + random.uintLessThan(usize, 3);
        var accepted = true;
        for (functions[0..count], 0..) |*f, id| {
            f.* = .{};
            f.count = 1 + random.uintLessThan(usize, 4);
            f.flow = switch (random.uintLessThan(u8, 6)) {
                0 => .decides,
                1 => .suspends,
                else => .plain,
            };
            f.passes = random.boolean();
            var needs: u3 = 0;
            for (f.statements[0..f.count]) |*statement| {
                const k = random.intRangeAtMost(i64, 1, 9);
                statement.* = switch (random.uintLessThan(u8, 8)) {
                    0 => .{ .constant = k },
                    1 => .read_variable,
                    2 => .{ .write_variable = k },
                    3 => .read_field,
                    4 => .{ .write_field = k },
                    5 => .{ .construct = k },
                    else => if (id == 0) .{ .constant = k } else call: {
                        const callee = random.uintLessThan(usize, id);
                        break :call if (functions[callee].flow == .decides) .{ .attempt = callee } else .{ .call = callee };
                    },
                };
                needs |= switch (statement.*) {
                    .constant => 0,
                    .read_variable, .read_field => 1,
                    .write_variable, .write_field => 2,
                    .construct => 4,
                    .call, .attempt => |callee| functions[callee].heap,
                };
            }
            // Mostly a set that covers the body, sometimes with more, sometimes any set at all.
            f.heap = switch (random.uintLessThan(u8, 4)) {
                0 => random.int(u3),
                1 => needs | random.int(u3),
                else => needs,
            };
            accepted = accepted and modelAccepts(functions[0..count], id, f.declared());
        }
        out.clearRetainingCapacity();
        try out.appendSlice(std.testing.allocator, "var C:i64=3\nbox:=class{var N:i64=5}\nQ:box=box{}\n");
        for (functions[0..count], 0..) |f, id| {
            try out.print(std.testing.allocator, "F{d}()", .{id});
            try writeEffect(&out, random, f);
            try out.appendSlice(std.testing.allocator, ":i64=Block{");
            for (f.statements[0..f.count], 0..) |statement, at| {
                try out.print(std.testing.allocator, "L{d}x{d}:i64=", .{ id, at });
                switch (statement) {
                    .constant => |k| try out.print(std.testing.allocator, "{d}", .{k}),
                    .read_variable => try out.appendSlice(std.testing.allocator, "C"),
                    .write_variable => |k| try out.print(std.testing.allocator, "Block{{set C={d};{d}}}", .{ k, k }),
                    .read_field => try out.appendSlice(std.testing.allocator, "Q.N"),
                    .write_field => |k| try out.print(std.testing.allocator, "Block{{set Q.N={d};{d}}}", .{ k, k }),
                    .construct => |k| try out.print(std.testing.allocator, "Block{{B{d}x{d}:=box{{}};{d}}}", .{ id, at, k }),
                    .call => |callee| try out.print(std.testing.allocator, "F{d}()", .{callee}),
                    .attempt => |callee| try out.print(std.testing.allocator, "Attempt(F{d}[],-1)", .{callee}),
                }
                try out.appendSlice(std.testing.allocator, ";");
            }
            if (f.flow == .decides) try out.print(std.testing.allocator, "Require[{s}];", .{if (f.passes) "true" else "false"});
            for (0..f.count) |at| try out.print(std.testing.allocator, "{s}L{d}x{d}", .{ if (at == 0) "" else "+", id, at });
            try out.appendSlice(std.testing.allocator, "}\n");
        }
        // The root runs every function that it may call: none that suspends.
        try out.appendSlice(std.testing.allocator, "Value<public>:i64=0");
        for (functions[0..count], 0..) |f, id| switch (f.flow) {
            .plain => try out.print(std.testing.allocator, "+F{d}()", .{id}),
            .decides => try out.print(std.testing.allocator, "+Attempt(F{d}[],-1)", .{id}),
            .suspends => {},
        };
        const source = out.items;
        const result = h.front.compile(source);
        if ((result == .ok) != accepted) std.debug.print("model says {}: {s}\n", .{ accepted, source });
        try std.testing.expectEqual(accepted, result == .ok);
        if (!accepted) {
            refused += 1;
            const effect_code = switch (result.failed.code) {
                .variable_read_requires_reads, .field_read_requires_reads, .set_requires_writes, .construction_requires_allocates, .call_requires_reads, .call_requires_writes, .call_requires_allocates, .call_requires_reads_writes, .call_requires_reads_allocates, .call_requires_writes_allocates, .call_requires_transacts, .call_requires_suspends => true,
                else => false,
            };
            if (!effect_code) std.debug.print("{s}: {s}\n", .{ @tagName(result.failed.code), source });
            try std.testing.expect(effect_code);
            continue;
        }
        compiled += 1;
        const p = result.ok;
        var model: Model = .{};
        var expected: i64 = 0;
        for (functions[0..count], 0..) |f, id| switch (f.flow) {
            .plain => expected += model.run(functions[0..count], id).?,
            .decides => expected += model.run(functions[0..count], id) orelse -1,
            .suspends => {},
        };
        const ran = try h.run(p, 1 << 16);
        if (ran == .failed or ran.ok.get("Value").?.integer != expected) std.debug.print("expected {d}: {s}\n", .{ expected, source });
        try std.testing.expectEqual(expected, ran.ok.get("Value").?.integer);
        // The same program with one function's set forged: admitted exactly when the model
        // accepts the function under the forged set and every caller under what it now calls.
        const forged = forgeable(h, p);
        for (0..6) |_| {
            @memcpy(h.metadata[0..p.functions.len], p.functions);
            const victim = random.uintLessThan(usize, count);
            var name_buffer: [8]u8 = undefined;
            const slot = functionNamed(p, try std.fmt.bufPrint(&name_buffer, "F{d}", .{victim}));
            const transacts = random.boolean();
            var detail: types.EffectDetail = @bitCast(random.int(u8));
            if (random.uintLessThan(u8, 8) != 0) detail.reserved = 0;
            if (random.uintLessThan(u8, 4) != 0) detail.converges = false;
            h.metadata[slot].transacts = transacts;
            h.metadata[slot].detail = detail;
            var changed = functions;
            const claimed = types.effectSet(transacts, changed[victim].flow == .decides, detail);
            changed[victim].heap = @as(u3, @intFromBool(claimed.reads)) | @as(u3, @intFromBool(claimed.writes)) << 1 | @as(u3, @intFromBool(claimed.allocates)) << 2;
            const was_suspending = changed[victim].flow == .suspends;
            var admitted = types.effectsCanonical(transacts, changed[victim].flow == .decides, detail) and !detail.converges;
            if (changed[victim].flow != .decides) changed[victim].flow = if (detail.suspends) .suspends else .plain;
            // The root calls every function that did not suspend when the program was compiled.
            if (!was_suspending and detail.suspends) admitted = false;
            // RFC-0082: a call of a function that suspends is a site, followed by its check, and
            // only such a call is; a forged change of whether a called function suspends leaves
            // its callers with a check where there is no site, or a site without one.
            if (was_suspending != detail.suspends) for (changed[0..count]) |caller| for (caller.statements[0..caller.count]) |statement| switch (statement) {
                .call, .attempt => |callee| if (callee == victim) {
                    admitted = false;
                },
                else => {},
            };
            // RFC-0085, rule 9: a function forged to predict calls only what predicts, which no
            // function of the generated program does.
            if (detail.predicts) for (changed[victim].statements[0..changed[victim].count]) |statement| switch (statement) {
                .call, .attempt => admitted = false,
                else => {},
            };
            for (0..count) |id| admitted = admitted and modelAccepts(changed[0..count], id, changed[id].declared());
            if (admitted) {
                forged_admitted += 1;
                const again = try h.run(forged, 1 << 16);
                // A function that stopped suspending is still not called from the root.
                try std.testing.expectEqual(expected, again.ok.get("Value").?.integer);
            } else {
                forged_refused += 1;
                invalid(h, forged) catch |err| {
                    std.debug.print("forged F{d} to transacts={} detail={b} was admitted: {s}\n", .{ victim, transacts, @as(u8, @bitCast(detail)), source });
                    return err;
                };
            }
        }
    }
    // The generator reaches both answers of both questions often.
    try std.testing.expect(compiled > 100 and refused > 100 and forged_admitted > 100 and forged_refused > 100);
}

// ---- review findings

test "declaring a local var needs writes, as it needed transacts, and the refusal is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(try h.execute("F()<writes>:i64=Block{var X:i64=1;X}\nG(Y:i64)<writes>:i64=Block{var X:i64=Y;set X+=1;X}\nA<public>:i64=F()+G(4)"), "A", 6);
    try expectAllRefused(h, "", &.{
        .{ "F()<computes>:i64=Block{var X:i64=1;X}\nA:i64=F()", .local_var_requires_writes, "X" },
        .{ "F()<reads>:i64=Block{var X:i64=1;X}\nA:i64=F()", .local_var_requires_writes, "X" },
        .{ "F()<allocates>:i64=Block{var X:i64=1;X}\nA:i64=F()", .local_var_requires_writes, "X" },
        .{ "F(Y:i64)<reads><allocates>:i64=Block{var X:i64=Y;X+1}\nA:i64=F(1)", .local_var_requires_writes, "X" },
        .{ "F()<computes>:i64=Block{var X:i64=0;For(I:1..3,Block{set X=X+I;0});X}", .local_var_requires_writes, "X" },
        // Defaults are compiled without a heap effect wherever they are used.
        .{ "defaults:=struct{X:i64=Block{var Y:i64=1;Y}}\nF()<computes>:i64=defaults{}.X\nA:i64=F()", .local_var_requires_writes, "Y" },
        .{ "F(K:i64=Block{var Y:i64=1;Y})<computes>:i64=K\nG()<computes>:i64=F()\nA:i64=G()", .local_var_requires_writes, "Y" },
        .{ "c:=class{X:i64=Block{var Y:i64=1;Y}}\nF()<allocates><reads>:i64=c{}.X\nA:i64=F()", .local_var_requires_writes, "Y" },
    });
}

test "a type or effect parameter may be named like an effect word" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(try h.execute("Id[reads:type](X:reads)<computes>:reads{X}\nA<public>:i64=Id[i64](3)"), "A", 3);
    try expectInt(try h.execute("Ap[writes:effect](F:function<writes>(tuple(i64),i64),X:i64)<writes>:i64{F(X)}\nG(X:i64)<computes>:i64=X\nA<public>:i64=Ap[computes](G,3)"), "A", 3);
    try expectInt(try h.execute("Pick[allocates:type,suspends:type,converges:type](X:allocates,Y:suspends,Z:converges)<computes>:allocates{X}\nA<public>:i64=Pick[i64,logic,string](5,true,\"z\")"), "A", 5);
}

test "an inherited method that fills an interface slot may narrow its effects, never widen them" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(try h.execute("Lab:=interface{Label()<transacts>:i64}\nU:=class{Label()<computes>:i64=1}\nKn:=class(U,Lab){}\nX:Lab=Kn{}\nA<public>:i64=X.Label()"), "A", 1);
    try expectInt(try h.execute("Lab:=interface{Label()<transacts>:i64}\nU:=class{Label()<transacts>:i64=1}\nKn:=class(U,Lab){}\nX:Lab=Kn{}\nA<public>:i64=X.Label()"), "A", 1);
    try expectInt(try h.execute("Lab:=interface{Label()<reads><decides>:i64}\nU:=class{Label()<computes>:i64=2}\nKn:=class(U,Lab){}\nF(Y:Lab)<reads>:i64=Attempt(Y.Label[],-1)\nA<public>:i64=F(Kn{})"), "A", 2);
    try expectAllRefused(h, "", &.{
        .{ "Lab:=interface{Label()<computes>:i64}\nU:=class{Label()<transacts>:i64=1}\nKn:=class(U,Lab){}", .override_widens_reads, "Kn" },
        .{ "Lab:=interface{Label()<computes>:i64}\nU:=class{Label()<computes><decides>:i64=1}\nKn:=class(U,Lab){}", .override_widens_decides, "Kn" },
        .{ "var C:i64=0\nLab:=interface{Label()<reads>:i64}\nU:=class{Label()<writes>:i64=Block{set C=5;1}}\nKn:=class(U,Lab){}", .override_widens_writes, "Kn" },
        .{ "Lab:=interface{Label()<computes>:i64}\nU:=class{Label()<computes>:logic=true}\nKn:=class(U,Lab){}", .duplicate_name, "Kn" },
    });
}

test "a stated class effect bounds the block clauses it inherits from an unstated superclass" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(try h.execute("P:=class{\nvar N:i64=0\nBlock{set Self.N=7}\n}\nOk:=class<transacts>(P){}\nPlain:=class{}\nPure:=class<computes>(Plain){}\nF()<transacts>:i64=Ok{}.N\nA<public>:i64=F()"), "A", 7);
    try expectAllRefused(h, "", &.{
        .{ "P:=class{\nvar N:i64=0\nBlock{set Self.N=7}\n}\nBad:=class<computes>(P){}", .class_effect_narrower_reads, "Bad" },
        .{ "P:=class{\nvar N:i64=0\nBlock{set Self.N=7}\n}\nBad:=class<reads>(P){\nBlock{Self.N}\n}", .class_effect_narrower_writes, "Bad" },
    });
}

/// Whether both machines admit `p`; an error when they disagree.
fn admits(h: *harness.Harness, p: types.Program) !bool {
    const a = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 20);
    const b = h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 1 << 20);
    const refused_a = a == .failed and a.failed.code == .invalid_ir;
    const refused_b = b == .failed and b.failed.code == .invalid_bytecode;
    if (refused_a != refused_b) return error.AdmissionsDisagree;
    return !refused_a;
}

test "every forged effect encoding of every function and function type is judged alike by both admissions" {
    const h = try harness.create();
    defer scratch.release(h);
    const sources = [_][]const u8{
        \\var C:i64=1
        \\W(X:i64)<writes>:i64=Block{set C=X;X}
        \\F:function<writes><decides>(tuple(i64),i64)=W
        \\G(X:i64)<reads><writes>:i64=Attempt(Block{Dropped:=F[X];Require[X<0];0},C)
        \\A:i64=G(5)
        \\B:i64=C
        ,
        \\var C:i64=1
        \\c:=class{var N:i64=1}
        \\Q:c=c{}
        \\H(X:i64)<writes><decides>:i64=Block{set C=X;set Q.N=X;Require[X<3];X}
        \\G(X:i64)<writes>:option(i64)=option{H[X]}
        \\K(X:i64)<writes>:logic=logic{H[X]>0}
        \\A:i64=Block{U:=G(9);V:=K(9);C+Q.N*10}
        \\B:i64=Block{Dropped:=G(2);C+Q.N*10}
        ,
        \\c:=class{N:i64=1}
        \\Mk(V:i64)<allocates><decides>:c=Block{O:=c{N:=V};Require[V<5];O}
        \\G()<allocates><reads>:[]i64=For(X:1..8,Mk[X].N)
        \\A:i64=G().Length
        ,
        \\F()<reads><writes>:i64=Block{var X:i64=1;set X=X+1;G:=Fn(Y:i64):i64{Y+X};G(3)}
        \\A:i64=F()
        ,
        \\F()<writes>:i64=Block{var X:i64=1;Dropped:=Attempt(Block{set X=5;Require[X<0];0},0);X}
        \\A:i64=F()
        ,
        \\var C:i64=0
        \\g:=class<abstract>{M<abstract>(X:i64)<transacts><decides>:i64}
        \\a:=class(g){M<override>(X:i64)<writes>:i64=Block{set C=X;X}}
        \\T(X:g)<transacts>:i64=Attempt(Block{F:=X.M;Dropped:=F[7];Require[1>2];1},C)
        \\A:i64=T(a{})
        \\B:i64=C
        ,
        \\Wait(X:i64)<computes><suspends>:i64=X
        \\Poll(X:i64)<reads><suspends>:i64=Wait(X)
        \\Lab:=interface{Label()<transacts>:i64}
        \\U:=class{Label()<computes>:i64=1}
        \\Kn:=class(U,Lab){}
        \\A:i64=Kn{}.Label()
        ,
    };
    var admitted: usize = 0;
    var refused: usize = 0;
    for (sources) |source| {
        const p = try h.compile(source);
        try std.testing.expect((try h.run(p, 1 << 20)) == .ok);
        const forged = forgeable(h, p);
        for (0..p.functions.len) |id| for (0..256) |combo| {
            @memcpy(h.metadata[0..p.functions.len], p.functions);
            h.metadata[id].transacts = combo & 1 != 0;
            h.metadata[id].decides = combo & 2 != 0;
            h.metadata[id].detail = @bitCast(@as(u8, @intCast(combo >> 2)));
            if (try admits(h, forged)) {
                admitted += 1;
                // An admitted forgery runs alike on both machines.
                _ = try h.run(forged, 1 << 20);
            } else refused += 1;
        };
        const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
        defer std.testing.allocator.free(definitions);
        var retyped = p;
        retyped.definitions = definitions;
        for (p.definitions, 0..) |item, index| if (item == .callable) for (0..256) |combo| {
            @memcpy(definitions, p.definitions);
            definitions[index].callable.transacts = combo & 1 != 0;
            definitions[index].callable.decides = combo & 2 != 0;
            definitions[index].callable.detail = @bitCast(@as(u8, @intCast(combo >> 2)));
            if (try admits(h, retyped)) admitted += 1 else refused += 1;
        };
    }
    try std.testing.expect(admitted > 0 and refused > admitted);
}
