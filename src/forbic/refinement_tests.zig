//! RFC-0083: refinement types with their casts and conversions back, the Book's qualifiers
//! `(local:)` and `(Module:)`, parametric aliases, open enums, `Case[...]` arms that the types
//! show no value can select, and the infallible conversions `i64(X)` and `float(X)`. Every
//! program runs on both machines (`harness.run` holds them to the same values, steps, cells and
//! reports, and replays both runs).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const catalogue = @import("aggregate_types.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");
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

fn expectFloat(x: anytype, name: []const u8, expected: f64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value != .floating or value.floating != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.floating);
}

fn expectLogic(x: anytype, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    try std.testing.expectEqual(expected, value.boolean);
}

fn expectText(x: anytype, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectInts(x: anytype, name: []const u8, expected: []const i64) !void {
    const range = x.get(name).?.aggregate.elements;
    try std.testing.expectEqual(expected.len, range.end - range.start);
    for (expected, x.aggregate_values[range.start..range.end]) |want, got| try std.testing.expectEqual(want, got.integer);
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

fn bundleRuns(h: *harness.Harness, main: []const u8, lib: []const u8) !evaluator.Execution {
    const result = bundle(h, main, lib);
    if (result != .ok) {
        std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ result.failed.diagnostic.message(), result.failed.path, result.failed.diagnostic.span.start });
        return error.Compile;
    }
    return (try h.run(result.ok, 1 << 20)).ok;
}

/// The bundle is refused with `code` in file `path`, the diagnostic covering exactly `text`.
fn bundleRefused(h: *harness.Harness, main: []const u8, lib: []const u8, code: Code, path: []const u8, text: []const u8) !void {
    const result = bundle(h, main, lib);
    if (result != .failed) {
        std.debug.print("bundle compiled, expected {s}\n", .{@tagName(code)});
        return error.Compiled;
    }
    const source = if (std.mem.eql(u8, result.failed.path, "main.forb")) main else lib;
    if (result.failed.diagnostic.code != code or !std.mem.eql(u8, result.failed.path, path) or !std.mem.eql(u8, result.failed.diagnostic.span.text(source), text)) std.debug.print("{s} in {s} at `{s}`, expected {s} in {s} at `{s}`\n", .{ @tagName(result.failed.diagnostic.code), result.failed.path, result.failed.diagnostic.span.text(source), @tagName(code), path, text });
    try std.testing.expectEqual(code, result.failed.diagnostic.code);
    try std.testing.expectEqualStrings(path, result.failed.path);
    try std.testing.expectEqualStrings(text, result.failed.diagnostic.span.text(source));
}

fn count(nodes: anytype, comptime kind: []const u8) usize {
    var total: usize = 0;
    for (nodes) |entry| {
        const node = if (@hasField(@TypeOf(entry), "node")) entry.node else entry;
        if (std.mem.eql(u8, @tagName(node.kind), kind)) total += 1;
    }
    return total;
}

// ---- Refinement types

const ages =
    \\Age<public>:=type{_X:i64 where 0<=_X,_X<=120}
    \\Percent:=type{_X:float where 0.0<=_X,_X<=1.0}
    \\Celsius:=type{_X:float where _X>=-273.15}
    \\Finite:=type{_X:float where -Inf<_X,_X<Inf}
    \\Small:=type{_X:float where _X<0.1}
    \\Positive:=type{_X:i64 where _X>0}
    \\Low:=type{_X:i64 where 3>_X}
    \\
;

test "rfc0083 refinements take literals within their bounds, cast values and convert back" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(ages ++
        \\Valid<public>:Age=25
        \\Edge:Age=120
        \\Zero:Age=0
        \\Opacity:Percent=0.5
        \\Freezing:Celsius=-273.15
        \\Huge:Finite=1.7976931348623157e+308
        \\Below:Finite=-1.7976931348623157e+308
        \\Tiny:Small=0.09999999999999999
        \\Two:Low=-9223372036854775808
        \\ToAge(N:i64)<computes><decides>:Age=Age[N]
        \\A<public>:i64=Attempt(i64(ToAge[30]),-1)
        \\B<public>:i64=Attempt(i64(ToAge[121]),-1)
        \\C<public>:i64=Attempt(i64(ToAge[-1]),-1)
        \\D<public>:i64=Attempt(i64(ToAge[0]),-1)
        \\E<public>:float=Attempt(float(Celsius[-300.0]),1.0)
        \\F<public>:float=Attempt(float(Finite[Inf]),2.0)
        \\G<public>:float=Attempt(float(Finite[NaN]),3.0)
        \\H<public>:float=Attempt(float(Small[0.1]),4.0)
        \\I<public>:float=Attempt(float(Percent[1.0]),5.0)
        \\J<public>:i64=Attempt(i64(Positive[0]),-1)
        \\K<public>:i64=Attempt(i64(Positive[1]),-1)
        \\L<public>:i64=Attempt(i64(Low[2]),-1)+Attempt(i64(Low[3]),-1)*10
        \\Text<public>:string="{Valid} {Opacity} {ToString(Edge)}"
        \\Same<public>:logic=Valid==25 and 25==Valid and Valid!=Edge and Valid==Valid
        \\Plain<public>:i64=i64(Valid)+1
        \\Wide<public>:float=float(Opacity)*2.0
        \\Self<public>:i64=i64(5)
    );
    try expectInt(x, "Valid", 25);
    try expectInt(x, "A", 30);
    try expectInt(x, "B", -1);
    try expectInt(x, "C", -1);
    try expectInt(x, "D", 0);
    try expectFloat(x, "E", 1.0);
    try expectFloat(x, "F", 2.0);
    try expectFloat(x, "G", 3.0);
    try expectFloat(x, "H", 4.0);
    try expectFloat(x, "I", 1.0);
    try expectInt(x, "J", -1);
    try expectInt(x, "K", 1);
    try expectInt(x, "L", 2 - 10);
    try expectText(x, "Text", "25 0.5 120");
    try expectLogic(x, "Same", true);
    try expectInt(x, "Plain", 26);
    try expectFloat(x, "Wide", 1.0);
    try expectInt(x, "Self", 5);
    try expectInt(x, "Two", std.math.minInt(i64));
    // The value is the base's, typed as the refinement: no node but `refine` makes one.
    const age = for (x.program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name.text(x.program.source), "Valid")) break binding.value_type;
    } else unreachable;
    try std.testing.expect(catalogue.refinementOf(age, x.program.definitions) != null);
    try std.testing.expect(count(x.program.nodes, "refine") >= 10);
}

test "rfc0083 a refinement is a value of every place: fields, elements, keys, options, parameters, generics and Case" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(ages ++
        \\P:=struct{Years:Age=1,Name:string}
        \\Q:P=P{Name:="a"}
        \\R:P=WithField(Q,Years,7)
        \\Years<public>:i64=i64(R.Years)+i64(Q.Years)*10
        \\M:map(Age,string)=map{1=>"one",2=>"two"}
        \\Hit<public>:string=Attempt(M[2],"none")
        \\Miss<public>:string=Attempt(M[3],"none")
        \\Keys<public>:[]i64=For(K->V:M,i64(K))
        \\O:option(Age)=option{3}
        \\Got<public>:i64=Attempt(i64(O?),-1)
        \\var Cell:Age=4
        \\Bump()<transacts>:Age=Block{set Cell=9;Cell}
        \\Bumped<public>:i64=i64(Bump())
        \\(A:Age).Next()<computes><decides>:Age=Age[i64(A)+1]
        \\Stepped<public>:i64=Attempt(i64(Age[119].Next[]),-1)+Attempt(i64(Age[120].Next[]),-1)*1000
        \\Id[T:type](Z:T)<computes>:T{Z}
        \\Kept<public>:i64=i64(Id[Age](5))
        \\Ages:[]Age=array{1,2,3}
        \\Fold(Xs:[]Age)<computes>:i64=For(X:Xs,i64(X)).Length*100+Attempt(i64(Xs[2]),0)
        \\Sum<public>:i64=Fold(Ages)
        \\Named(A:Age)<computes>:string=Case(A,0=>"none",1=>"one",_=>"many")
        \\Word<public>:string=Named(1)+Named(0)+Named(50)
        \\Pick(A:Age)<computes>:i64=Case(A,N:Age=>i64(N)*2)
        \\Twice<public>:i64=Pick(21)
        \\Default(A:Age=7)<computes>:i64=i64(A)
        \\Defaults<public>:i64=Default()*10+Default(A:=8)
        \\Box:=class{var Held:Age=2}
        \\Make()<transacts>:i64=Block{B:=Box{};set B.Held=11;i64(B.Held)}
        \\Boxed<public>:i64=Make()
    );
    try expectInt(x, "Years", 17);
    try expectText(x, "Hit", "two");
    try expectText(x, "Miss", "none");
    try expectInts(x, "Keys", &.{ 1, 2 });
    try expectInt(x, "Got", 3);
    try expectInt(x, "Bumped", 9);
    try expectInt(x, "Stepped", 120 - 1000);
    try expectInt(x, "Kept", 5);
    try expectInt(x, "Sum", 303);
    try expectText(x, "Word", "onenonemany");
    try expectInt(x, "Twice", 42);
    try expectInt(x, "Defaults", 78);
    try expectInt(x, "Boxed", 11);
}

test "rfc0083 a failed refinement cast fails its region, which undoes what it wrote" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(ages ++
        \\var Log:i64=0
        \\Admit(N:i64)<transacts><decides>:Age=Block{set Log=Log*10+1;A:=Age[N];set Log=Log*10+2;A}
        \\One<public>:i64=Attempt(i64(Admit[200]),-1)
        \\After<public>:i64=Log
        \\Two<public>:i64=Attempt(i64(Admit[20]),-1)
        \\Later<public>:i64=Log
        \\Cond<public>:i64=If(V:=Age[7],i64(V),-1)+If(W:=Age[700],i64(W),-1)*100
        \\Opt<public>:i64=Attempt(i64(option{Age[1000]}?),-5)
        \\Listed<public>:[]i64=For(N:-1..2,V:=Age[N],i64(V))
    );
    try expectInt(x, "One", -1);
    try expectInt(x, "After", 0);
    try expectInt(x, "Two", 20);
    try expectInt(x, "Later", 12);
    try expectInt(x, "Cond", 7 - 100);
    try expectInt(x, "Opt", -5);
}

test "rfc0083 the bound forms of the Book, and every other is refinement_bound at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each bound form the Book allows (11:742): either side, every comparison, negative
    // literals, `Inf` and `-Inf`, one bound or two.
    const x = try h.execute(
        \\A:=type{_X:i64 where _X>=-5}
        \\B:=type{_X:i64 where -5<=_X}
        \\C:=type{_X:i64 where _X<5,_X>-5}
        \\D:=type{_X:float where Inf>_X}
        \\E:=type{_X:float where _X<=0.0,_X>=-1.0}
        \\F:=type{_X:float where -0.0<=_X}
        \\R<public>:i64=1
    );
    _ = x;
    for ([_]struct { []const u8, []const u8 }{
        // A bound is a literal: not a name, a call or an expression (11:742).
        .{ "L:i64=3\nA:=type{_X:i64 where _X<L}", "L" },
        .{ "M()<computes>:i64=3\nA:=type{_X:i64 where _X<M()}", "M" },
        .{ "A:=type{_X:i64 where _X<1+2}", "+" },
        // A float bound is a float literal (11:771), never a NaN (11:792).
        .{ "A:=type{_X:float where _X<=142}", "142" },
        .{ "A:=type{_X:float where _X<=NaN}", "NaN" },
        .{ "A:=type{_X:float where NaN<=_X}", "NaN" },
        .{ "A:=type{_X:i64 where _X<=1.5}", "1.5" },
        .{ "A:=type{_X:i64 where _X<=Inf}", "Inf" },
        // The base is `i64` or `float`.
        .{ "A:=type{_X:string where _X<1}", "string" },
        .{ "A:=type{_X:logic where _X<1}", "logic" },
        .{ "B:=type{_X:i64 where _X>0}\nA:=type{_X:B where _X<1}", "B" },
        // A comparison of the placeholder and a literal, by `<`, `<=`, `>` or `>=`.
        .{ "A:=type{_X:i64 where _X==1}", "==" },
        .{ "A:=type{_X:i64 where _X!=1}", "!=" },
        .{ "A:=type{_X:i64 where _Y<1}", "_Y" },
        .{ "A:=type{_X:i64 where 1<2}", "1" },
        .{ "A:=type{_X:i64 where _X<_X}", "_X" },
        .{ "A:=type{_X:i64 where _X}", "}" },
        .{ "A:=type{_X:i64}", "}" },
        .{ "A:=type{_X:i64 when _X>1}", "when" },
        .{ "A:=type{i64 where _X>1}", "where" },
        // At most one bound on each side, and some value between them.
        .{ "A:=type{_X:i64 where _X<3,_X<5}", "_X" },
        .{ "A:=type{_X:i64 where _X>=1,1<=_X}", "1" },
        .{ "A:=type{_X:i64 where _X>5,_X<3}", "{" },
        .{ "A:=type{_X:i64 where _X>3,_X<4}", "{" },
        .{ "A:=type{_X:i64 where _X<-9223372036854775808}", "{" },
        .{ "A:=type{_X:i64 where _X>9223372036854775807}", "{" },
        .{ "A:=type{_X:float where _X<1.0,_X>1.0}", "{" },
        .{ "A:=type{_X:float where _X<=1.0,_X>1.0}", "{" },
        .{ "A:=type{_X:float where _X<-Inf}", "{" },
    }) |case| try expectRefused(h, case[0], .refinement_bound, case[1]);
    try expectRefused(h, "A:=type{_X:i64 where _X<9223372036854775808}", .integer_range, "9223372036854775808");
    try expectRefused(h, "A:=type{_X:float where _X<1e400}", .float_range, "1e400");
    // A refinement is declared once, by a module, after its name is free.
    try expectRefused(h, "A:=type{_X:i64 where _X<1}\nA:=type{_X:i64 where _X<2}", .duplicate_name, "A");
    try expectRefused(h, "A:i64=1\nA:=type{_X:i64 where _X<2}", .duplicate_name, "A");
    try expectRefused(h, "A:=type{_X:i64 where _X<1} extra", .unexpected_token, "extra");
}

test "rfc0083 nothing converts to or from a refinement by itself, and it is no value of any" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "Age:=type{_X:i64 where 0<=_X,_X<=120}\nP:=type{_X:float where 0.0<=_X}\nV:Age=25\nN:i64=3\n";
    for ([_]struct { []const u8, Code, []const u8 }{
        // A constant outside the bounds, in every place a constant converts.
        .{ "X:Age=121", .outside_refinement, "121" },
        .{ "X:Age=-1", .outside_refinement, "-" },
        .{ "X:P=-0.5", .outside_refinement, "-" },
        .{ "X:P=NaN", .outside_refinement, "NaN" },
        .{ "F(A:Age)<computes>:i64=1\nX:i64=F(500)", .outside_refinement, "500" },
        .{ "X:[]Age=array{1,200}", .outside_refinement, "200" },
        .{ "X:logic=V==200", .outside_refinement, "200" },
        // Only a literal written there converts: not a name, not an expression.
        .{ "X:Age=N", .type_mismatch, "3" },
        .{ "X:Age=1+1", .type_mismatch, "+" },
        .{ "F(M:i64)<computes>:Age=M", .type_mismatch, "M" },
        .{ "F()<computes>:Age=Block{M:i64=3;M}", .type_mismatch, "3" },
        .{ "X:Age=2.0", .type_mismatch, "2.0" },
        .{ "X:P=1", .type_mismatch, "1" },
        // And a refinement is not its base where the base is expected, nor the other way.
        .{ "X:i64=V", .type_mismatch, "25" },
        .{ "X:i64=V+1", .type_mismatch, "+" },
        .{ "X:Age=-V", .type_mismatch, "-" },
        .{ "X:logic=V<30", .type_mismatch, "<" },
        .{ "X:i64=Abs(V)", .type_mismatch, "25" },
        .{ "X:Age=Age[V]", .type_mismatch, "25" },
        .{ "X:Age=Attempt(Age[2.0],V)", .type_mismatch, "2.0" },
        .{ "X:float=float(V)", .type_mismatch, "25" },
        .{ "X:i64=i64(\"a\")", .type_mismatch, "\"a\"" },
        .{ "X:i64=V.Length", .type_mismatch, "Length" },
        // `any` holds no refinement: its value would answer type tests as its base.
        .{ "X:any=any(V)", .type_mismatch, "25" },
        .{ "Y:any=any(3)\nX:Age=Attempt(Age[Y],V)", .type_mismatch, "any" },
        .{ "Y:any=any(3)\nX:i64=Case(Y,A:Age=>1,_=>0)", .type_mismatch, "any" },
        // A cast needs a failure context, as every cast does.
        .{ "X:Age=Age[N]", .failure_context_required, "Age" },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, case[0] });
        try expectRefused(h, source, case[1], case[2]);
    }
}

test "rfc0083 a refinement yields its name to every declaration of the word type, and is declared only by a module" {
    const h = try harness.create();
    defer scratch.release(h);
    // A struct named `type` is built as before.
    const x = try h.execute("type:=struct{N:i64}\nA:=type{N:=3}\nB<public>:i64=A.N");
    try expectInt(x, "B", 3);
    const y = try h.execute("type(N:i64)<computes>:i64=N\nB<public>:i64=type(4)");
    try expectInt(y, "B", 4);
    // Inside a function a refinement is no expression.
    try expectRefused(h, "F()<computes>:i64=Block{A:=type{_X:i64 where _X<1};1}", .unknown_name, "type");
}

test "rfc0083 refinements across modules: public ones are named and cast through the path, private ones stay home" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Age<public>:=type{_X:i64 where 0<=_X,_X<=120}
        \\Hidden:=type{_X:i64 where _X>0}
        \\Make<public>(N:i64)<computes><decides>:Age=Age[N]
        \\Old<public>:Age=99
    ;
    const x = try bundleRuns(h,
        \\L:=import{"lib.forb"}
        \\A:L.Age=30
        \\B<public>:i64=i64(A)+Attempt(i64(L.Age[200]),-1000)
        \\C<public>:i64=Attempt(i64(L.Make[40]),-1)
        \\D<public>:logic=L.Old==99
    , lib);
    try expectInt(x, "B", 30 - 1000);
    try expectInt(x, "C", 40);
    try expectLogic(x, "D", true);
    const y = try bundleRuns(h,
        \\L:=import{"lib.forb"}
        \\using{L}
        \\A:Age=31
        \\B<public>:i64=i64(A)
    , lib);
    try expectInt(y, "B", 31);
    // A refinement declared by a module nested in a file is named through its path.
    const n = try bundleRuns(h,
        \\L:=import{"lib.forb"}
        \\A:L.Kit.Small=3
        \\B<public>:i64=i64(A)+Attempt(i64(L.Kit.Small[9]),-10)
    , "Kit<public>:=module{\nSmall<public>:=type{_X:i64 where _X>=0,_X<5}\n}");
    try expectInt(n, "B", 3 - 10);
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:L.Hidden=3", lib, .private_name, "main.forb", "L.Hidden");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=1", "Secret:=type{_X:i64 where _X>0}\nShown<public>:Secret=1", .private_type_escape, "lib.forb", "Shown");
    // Through a generic function the refinement is a parameter of the cast.
    const z = try h.execute(ages ++
        \\Open[T:type](V:i64)<computes><decides>:T{T[V]}
        \\In<public>:i64=Attempt(i64(Open[Age][7]),-1)
        \\Out<public>:i64=Attempt(i64(Open[Age][700]),-1)
    );
    try expectInt(z, "In", 7);
    try expectInt(z, "Out", -1);
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=1", "Secret:=type{_X:i64 where _X>0}\nShow<public>(S:Secret)<computes>:i64=1", .private_type_escape, "lib.forb", "S");
}

/// One forged program: both machines refuse it, or both run it to the same end.
fn attempt(h: *harness.Harness, p: types.Program, what: []const u8, index: usize, a: usize, counts: *[3]usize) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    if (reference == .failed and reference.failed.code == .invalid_ir) {
        const lowered = bytecode.lower(p, &h.runtime.instructions);
        if (lowered == .ok) {
            const actual = h.runtime.machine.run(lowered.ok, 100_000);
            if (actual != .failed or actual.failed.code != .invalid_bytecode) {
                std.debug.print("DIVERGE {s} node {d} with {d}: reference invalid_ir, vm {s}\n", .{ what, index, a, if (actual == .failed) @tagName(actual.failed.code) else "ok" });
                return error.TestUnexpectedResult;
            }
        }
        counts[0] += 1;
        return;
    }
    const result = h.run(p, 100_000) catch |err| {
        std.debug.print("FINDING {s} node {d} with {d}: {s}\n", .{ what, index, a, @errorName(err) });
        return err;
    };
    counts[if (result == .ok) 1 else 2] += 1;
}

const forged_source = ages ++
    \\P:=struct{X:i64}
    \\N:i64=5
    \\Fl:float=0.25
    \\T:string="t"
    \\Lg:logic=true
    \\A:Age=30
    \\Op:Percent=0.5
    \\Ps:Positive=8
    \\Pt:P=P{X:=1}
    \\B:i64=i64(A)
    \\C:float=float(Op)
    \\D:Age=Attempt(Age[N],A)
    \\E:Percent=Attempt(Percent[Fl],Op)
    \\H:any=any(N)
    \\Eq:logic=A==D
    \\Xs:[]Age=array{A,D}
;

test "rfc0083 forged refine nodes are refused by both machines or run alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 100_000);
    var seen: [64]types.Type = undefined;
    var seen_count: usize = 0;
    for ([_]types.Type{ types.Type.any, .i64, .logic, .string, .float, types.Type.char, @fromBackingInt(4 + types.limits.user_types), @fromBackingInt(0xFFFF) }) |t| {
        seen[seen_count] = t;
        seen_count += 1;
    }
    for (p.nodes) |node| {
        var known = false;
        for (seen[0..seen_count]) |t| known = known or t == node.value_type;
        if (!known and seen_count < seen.len) {
            seen[seen_count] = node.value_type;
            seen_count += 1;
        }
    }
    var counts = [3]usize{ 0, 0, 0 };
    var refines: usize = 0;
    for (p.nodes, 0..) |node, index| {
        if (node.kind != .refine) continue;
        refines += 1;
        // Every earlier node as the operand, at its own type and at every type seen.
        for (0..index) |other| {
            var changed = node;
            changed.kind = .{ .refine = @intCast(other) };
            nodes[index] = changed;
            try attempt(h, forged, "operand", index, other, &counts);
            changed.value_type = p.nodes[other].value_type;
            nodes[index] = changed;
            try attempt(h, forged, "operand as itself", index, other, &counts);
        }
        for (seen[0..seen_count], 0..) |t, ti| {
            var changed = node;
            changed.value_type = t;
            nodes[index] = changed;
            try attempt(h, forged, "result type", index, ti, &counts);
        }
        for ([_]u32{ @intCast(index), @intCast(index + 1), std.math.maxInt(u32) }) |other| {
            var changed = node;
            changed.kind = .{ .refine = other };
            nodes[index] = changed;
            try attempt(h, forged, "forward", index, other, &counts);
        }
        nodes[index] = node;
    }
    try std.testing.expect(refines >= 6);
    try std.testing.expect(counts[0] > 100 and counts[1] > 20);
}

test "rfc0083 a refine whose value lies outside the bounds traps both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(ages ++
        \\N:i64=500
        \\Nan:float=NaN
        \\Huge:float=Inf
        \\M:i64=50
        \\A:Age=40
        \\F:Finite=0.5
        \\G:Finite=0.25
        \\C:Age=Attempt(Age[M],A)
    );
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 100_000);
    var n: u32 = 0;
    var nan: u32 = 0;
    var huge: u32 = 0;
    for (p.bindings) |binding| {
        const name = binding.name.text(p.source);
        if (std.mem.eql(u8, name, "N")) n = binding.node;
        if (std.mem.eql(u8, name, "Nan")) nan = binding.node;
        if (std.mem.eql(u8, name, "Huge")) huge = binding.node;
    }
    var trapped: usize = 0;
    for (p.nodes, 0..) |node, index| {
        if (node.kind != .refine) continue;
        const target = catalogue.refinementOf(node.value_type, p.definitions) orelse continue;
        const name = target.name.text(p.source);
        // The guard holds for the value it tested; the refine reads another one.
        const outside: []const u32 = if (std.mem.eql(u8, name, "Age")) &.{n} else if (std.mem.eql(u8, name, "Finite")) &.{ nan, huge } else continue;
        for (outside) |operand| {
            if (operand >= index) continue;
            var changed = node;
            changed.kind = .{ .refine = operand };
            nodes[index] = changed;
            try harness.traps(h, forged, 100_000);
            trapped += 1;
        }
        nodes[index] = node;
    }
    try std.testing.expect(trapped >= 3);
    _ = try h.run(forged, 100_000);

    // In a function body: the refine reads another parameter than the one its guard tested,
    // and the call passes a value outside the bounds there.
    const q = try h.compile(ages ++
        \\G(N:i64,M:i64)<computes>:Age=Block{K:=N;Attempt(Age[M],0)}
        \\A:Age=G(500,5)
    );
    _ = try h.run(q, 100_000);
    const body = try std.testing.allocator.dupe(types.FunctionNode, q.function_nodes);
    defer std.testing.allocator.free(body);
    var in_function = q;
    in_function.function_nodes = body;
    const f = q.functions[0];
    var first: ?u32 = null;
    var forged_refines: usize = 0;
    for (body[f.body.start..f.body.end], 0..) |entry, local| {
        if (entry.input == .parameter and entry.input.parameter == 0) first = @intCast(local);
        if (entry.node.kind != .refine or catalogue.refinementOf(entry.node.value_type, q.definitions) == null) continue;
        // The cast's refine, which runs after its guard; the fallback's refine reads a literal.
        if (body[f.body.start + entry.node.kind.refine].input != .parameter) continue;
        body[f.body.start + local].node.kind = .{ .refine = first orelse return error.TestUnexpectedResult };
        try harness.traps(h, in_function, 100_000);
        body[f.body.start + local] = entry;
        forged_refines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), forged_refines);
    _ = try h.run(in_function, 100_000);
}

test "rfc0083 forged refinement definitions and casts of them through any are refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(ages ++
        \\A:Age=30
        \\Op:Percent=0.5
        \\H:any=any(5)
        \\B:i64=Attempt(i64[H],0)
    );
    _ = try h.run(p, 100_000);
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    var forged = p;
    forged.definitions = definitions;
    var age: usize = 0;
    var percent: usize = 0;
    for (p.definitions, 0..) |item, index| if (item == .refinement) {
        if (std.mem.eql(u8, item.refinement.name.text(p.source), "Age")) age = index;
        if (std.mem.eql(u8, item.refinement.name.text(p.source), "Percent")) percent = index;
    };
    const original_age = p.definitions[age].refinement;
    const original_percent = p.definitions[percent].refinement;
    var bad = original_age;
    // Bounds that cross, an open integer bound, a base that is no number.
    bad.low = @bitCast(@as(i64, 121));
    definitions[age] = .{ .refinement = bad };
    try harness.invalid(h, forged);
    bad = original_age;
    bad.low_open = true;
    definitions[age] = .{ .refinement = bad };
    try harness.invalid(h, forged);
    bad = original_age;
    bad.base = .string;
    definitions[age] = .{ .refinement = bad };
    try harness.invalid(h, forged);
    bad = original_age;
    bad.base = .float;
    definitions[age] = .{ .refinement = bad };
    try harness.invalid(h, forged);
    // A name that is not one: the name of a builtin type.
    bad = original_age;
    bad.name = .{ .start = 0, .end = 0 };
    definitions[age] = .{ .refinement = bad };
    try harness.invalid(h, forged);
    definitions[age] = .{ .refinement = original_age };
    var float_bad = original_percent;
    float_bad.low = @bitCast(std.math.nan(f64));
    definitions[percent] = .{ .refinement = float_bad };
    try harness.invalid(h, forged);
    float_bad = original_percent;
    float_bad.high = @bitCast(@as(f64, 0.0));
    float_bad.high_open = true;
    definitions[percent] = .{ .refinement = float_bad };
    try harness.invalid(h, forged);
    float_bad = original_percent;
    float_bad.high = float_bad.low;
    definitions[percent] = .{ .refinement = float_bad };
    // A single value is a range, with closed bounds.
    _ = try h.run(forged, 100_000);
    definitions[percent] = .{ .refinement = original_percent };
    _ = try h.run(forged, 100_000);

    // `any` holds no refinement and gives none back.
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    forged = p;
    forged.nodes = nodes;
    const age_type: types.Type = @fromBackingInt(@as(u16, @intCast(age + 4)));
    var a_node: u32 = 0;
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), "A")) {
        a_node = binding.node;
    };
    for (p.nodes, 0..) |node, index| {
        switch (node.kind) {
            .upcast => {
                if (a_node >= index) continue;
                nodes[index].kind = .{ .upcast = a_node };
                try harness.invalid(h, forged);
            },
            .downcast => {
                nodes[index].value_type = age_type;
                try harness.invalid(h, forged);
            },
            .instance_of => |c| {
                nodes[index].kind = .{ .instance_of = .{ .value = c.value, .class = age_type } };
                try harness.invalid(h, forged);
            },
            else => continue,
        }
        nodes[index] = node;
    }
    _ = try h.run(forged, 100_000);
}

test "rfc0083 a report whose value of a refinement lies outside its bounds is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const limits: reporting.Limits = .{ .work = 1024 * 1024 };
    const r = try h.run(try h.compile(ages ++
        \\N:i64=30
        \\A<public>:Age=Attempt(Age[N],0)
        \\Xs<public>:[]Age=array{1,2}
        \\F<public>:Finite=1.5
    ), 10_000);
    _ = try reporting.validate(r.ok, false, limits);
    const p = r.ok.program;
    var a: u32 = 0;
    var xs: u32 = 0;
    var f: u32 = 0;
    for (p.bindings) |binding| {
        const name = binding.name.text(p.source);
        if (std.mem.eql(u8, name, "A")) a = binding.node;
        if (std.mem.eql(u8, name, "Xs")) xs = binding.node;
        if (std.mem.eql(u8, name, "F")) f = binding.node;
    }
    const values = &h.runtime.machine.values;
    const kept = values[a];
    values[a] = .{ .integer = 121 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
    values[a] = .{ .floating = 30.0 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
    values[a] = kept;
    _ = try reporting.validate(r.ok, false, limits);
    const span = values[xs].aggregate.elements;
    const members = &h.runtime.machine.aggregate_values;
    members[span.start + 1] = .{ .integer = -2 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
    members[span.start + 1] = .{ .integer = 2 };
    _ = try reporting.validate(r.ok, false, limits);
    values[f] = .{ .floating = std.math.inf(f64) };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(r.ok, false, limits));
    values[f] = .{ .floating = 1.5 };
    _ = try reporting.validate(r.ok, false, limits);
}

test "rfc0083 random refinement casts agree with a model of their bounds" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x83);
    const random = prng.random();
    var cases: usize = 0;
    for (0..24) |_| {
        var source: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&source);
        // A refinement over each base, with bounds drawn from a small range so that values
        // land on both sides and on the bounds themselves.
        const low = random.intRangeAtMost(i64, -6, 6);
        var high = low + random.intRangeAtMost(i64, 0, 6);
        const low_kind = random.intRangeAtMost(u8, 0, 2);
        const high_kind = random.intRangeAtMost(u8, 0, 2);
        // Bounds with no integer between them are refused (another test); keep one there.
        if (low_kind != 0 and high_kind != 0 and (if (low_kind == 2) low + 1 else low) > (if (high_kind == 2) high - 1 else high)) high = low + 2;
        const flow: f64 = @as(f64, @floatFromInt(random.intRangeAtMost(i64, -8, 8))) / 4.0;
        const fhigh = flow + @as(f64, @floatFromInt(random.intRangeAtMost(i64, 1, 8))) / 4.0;
        const flow_open = random.boolean();
        const fhigh_open = random.boolean();
        try writer.print("I:=type{{_X:i64 where ", .{});
        // 0: no bound on that side, 1: closed, 2: open.
        var wrote = false;
        if (low_kind != 0) {
            try writer.print("_X{s}{d}", .{ if (low_kind == 1) ">=" else ">", low });
            wrote = true;
        }
        if (high_kind != 0 or !wrote) {
            try writer.print("{s}{d}{s}_X", .{ if (wrote) "," else "", high, if (high_kind == 2) ">" else ">=" });
        }
        try writer.print("}}\nF:=type{{_X:float where {d:.2}{s}_X,_X{s}{d:.2}}}\n", .{ flow, if (flow_open) "<" else "<=", if (fhigh_open) "<" else "<=", fhigh });
        var ints: [12]i64 = undefined;
        var floats: [12]f64 = undefined;
        for (&ints, &floats, 0..) |*value, *floating, index| {
            value.* = random.intRangeAtMost(i64, -9, 14);
            floating.* = @as(f64, @floatFromInt(random.intRangeAtMost(i64, -12, 16))) / 4.0;
            try writer.print("V{d}:i64={d}\nW{d}:float={d:.2}\n", .{ index, value.*, index, floating.* });
        }
        for (0..ints.len) |index| try writer.print("A{d}<public>:i64=Attempt(i64(I[V{d}]),-100)\nB{d}<public>:float=Attempt(float(F[W{d}]),-100.0)\n", .{ index, index, index, index });
        const x = try h.execute(writer.buffered());
        for (ints, floats, 0..) |value, floating, index| {
            var name: [8]u8 = undefined;
            const in_low = switch (low_kind) {
                0 => true,
                1 => value >= low,
                else => value > low,
            };
            const in_high = if (high_kind == 0 and low_kind != 0) true else if (high_kind == 2) value < high else value <= high;
            try expectInt(x, try std.fmt.bufPrint(&name, "A{d}", .{index}), if (in_low and in_high) value else -100);
            const above = if (flow_open) floating > flow else floating >= flow;
            const below = if (fhigh_open) floating < fhigh else floating <= fhigh;
            try expectFloat(x, try std.fmt.bufPrint(&name, "B{d}", .{index}), if (above and below) floating else -100.0);
            cases += 2;
        }
    }
    try std.testing.expectEqual(@as(usize, 24 * 24), cases);
}

// ---- Qualifiers

test "rfc0083 a local or parameter declared (local:) may share its name with what is outside, and means the local" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Volume:i64=5
        \\Factor:i64=3
        \\Limit:i64=4
        \\I:i64=9
        \\Mix()<computes>:i64=Block{(local:)Volume:i64=1;(local:)Volume*10+Volume}
        \\M<public>:i64=Mix()
        \\Scale((local:)Factor:i64)<computes>:i64=Block{(local:)Base:i64=10;(local:)Base*(local:)Factor}
        \\S<public>:i64=Scale(4)
        \\Doubles((local:)Limit:i64)<computes>:[]i64=For((local:)I:0..Limit,(local:)I*2)
        \\D<public>:[]i64=Doubles(3)
        \\Clamp((local:)Factor:i64)<computes>:i64=Block{(local:)Volume:i64=5;If(Factor>Volume,Volume,Factor)}
        \\C<public>:i64=Clamp(9)+Clamp(2)*10
        \\Count()<transacts>:i64=Block{var (local:)Volume:i64=1;set (local:)Volume=3;Set(Volume,Volume+1);While(Volume<20,set Volume=Volume*2);(local:)Volume}
        \\V<public>:i64=Count()
        \\Pick(O:option(i64))<computes>:i64=If((local:)Limit:=O?,Limit,0)
        \\P<public>:i64=Pick(option{7})
        \\Closure()<computes>:i64=Block{(local:)Factor:i64=6;G:=Fn()<computes>:i64{Factor};G()}
        \\Cl<public>:i64=Closure()
        \\Outer<public>:i64=Volume+Factor
    );
    // The plain name means the local too.
    try expectInt(x, "M", 11);
    try expectInt(x, "S", 40);
    try expectInts(x, "D", &.{ 0, 2, 4, 6 });
    try expectInt(x, "C", 5 + 20);
    try expectInt(x, "V", 32);
    try expectInt(x, "P", 7);
    try expectInt(x, "Cl", 6);
    try expectInt(x, "Outer", 8);
}

test "rfc0083 (Module:)Name names what the module declares, beside a local of the name" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try bundleRuns(h,
        \\L:=import{"lib.forb"}
        \\Audio:=module{
        \\Volume<public>:i64=5
        \\Point<public>:=struct{X:i64}
        \\}
        \\Mixer:=module{
        \\using{Audio}
        \\Mix<public>()<computes>:i64=Block{(local:)Volume:i64=1;(local:)Volume+(Audio:)Volume}
        \\}
        \\M<public>:i64=Mixer.Mix()
        \\T<public>:i64=(L:)Twice(4)+(L:)Base
        \\P:(Audio:)Point=(Audio:)Point{X:=7}
        \\Px<public>:i64=P.X
    , "Twice<public>(N:i64)<computes>:i64=N*2\nBase<public>:i64=100");
    try expectInt(x, "M", 6);
    try expectInt(x, "T", 108);
    try expectInt(x, "Px", 7);
    // The qualifier names a module: not a value, a class or anything else of the name.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nP:=struct{X:i64}\nQ:P=P{X:=1}\nA:i64=(Q:)X", "B<public>:i64=1", .invalid_qualifier, "main.forb", "Q");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=(Nowhere:)X", "B<public>:i64=1", .invalid_qualifier, "main.forb", "Nowhere");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=(L:)Hidden", "Hidden:i64=1", .private_name, "main.forb", "L:)Hidden");
}

test "rfc0083 a qualifier means something only before a local, a parameter or a module's name" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { []const u8, Code, []const u8 }{
        // `(local:)` is no qualifier of a declaration of a module, a field, an argument, a type.
        .{ "(local:)X:i64=3", .invalid_qualifier, "X" },
        .{ "(local:)F()<computes>:i64=3", .invalid_qualifier, "F" },
        .{ "P:=struct{X:i64}\nQ:P=P{(local:)X:=1}", .invalid_qualifier, "X" },
        .{ "P:=struct{X:i64}\nF(Q:P)<computes>:i64=Q.(local:)X", .invalid_qualifier, "(" },
        .{ "F(A:i64)<computes>:i64=A\nY:i64=F((local:)A:=1)", .invalid_qualifier, "A" },
        .{ "G[(local:)T:type](V:T)<computes>:T{V}", .invalid_qualifier, "T" },
        .{ "X:(local:)i64=3", .invalid_qualifier, "i64" },
        .{ "P:=struct{(local:)X:i64}", .invalid_qualifier, "X" },
        .{ "P:=class{(local:)X:i64=1}", .invalid_qualifier, "X" },
        .{ "E:=enum{(local:)A}", .invalid_qualifier, "A" },
        // Nor of a word the language gives a meaning, which a macro would take away with it.
        .{ "X:(local:)option(i64)=option{}", .invalid_qualifier, "option" },
        .{ "X:i64=(local:)Block{1}", .invalid_qualifier, "Block" },
        .{ "X:[]i64=(local:)For(I:0..2,I)", .invalid_qualifier, "For" },
        .{ "X:i64=(local:)Case(1,_=>2)", .invalid_qualifier, "Case" },
        .{ "P:=struct{Y:i64}\nQ:P=P{Y:=1}\nR:P=WithField(Q,(local:)Y,7)", .invalid_qualifier, "Y" },
        // A use so written is a local or a parameter.
        .{ "X:i64=3\nF()<computes>:i64=(local:)X", .unknown_name, "X" },
        .{ "F()<computes>:i64=Block{A:=1;(local:)B}", .unknown_name, "B" },
        // Inside the function, a local declared so is one name like any other: it cannot be
        // declared again (16:765), nor can a parameter.
        .{ "F((local:)X:i64)<computes>:i64=Block{(local:)X:i64=2;X}", .shadowed_name, "X" },
        .{ "X:i64=4\nF()<computes>:i64=Block{(local:)X:i64=1;Block{X:i64=2;X}}", .shadowed_name, "X" },
        .{ "F(X:i64)<computes>:i64=Block{(local:)X:i64=2;X}", .shadowed_name, "X" },
        .{ "F()<computes>:i64=Block{(local:)F:i64=2;F}", .shadowed_name, "F" },
        // Without the qualifier the rule of RFC-0076 holds as before.
        .{ "X:i64=4\nF()<computes>:i64=Block{X:i64=1;X}", .shadowed_name, "X" },
        // A module qualifier needs modules.
        .{ "X:i64=3\nY:i64=(X:)Y", .invalid_qualifier, "X" },
    }) |case| try expectRefused(h, case[0], case[1], case[2]);
    // An uncalled generic body is checked from its tokens, with the same exemption.
    const x = try h.execute("X:i64=4\nG[T:type](V:T)<computes>:i64{Block{(local:)X:i64=1;X}}\nA<public>:i64=G[i64](0)");
    try expectInt(x, "A", 1);
    try expectRefused(h, "X:i64=4\nG[T:type](V:T)<computes>:i64{Block{X:i64=1;X}}", .shadowed_name, "X");
    _ = try h.compile("X:i64=4\nG[T:type](V:T)<computes>:i64{Block{(local:)X:i64=1;X}}");
}

// ---- Parametric aliases

test "rfc0083 parametric aliases name the type their text names with the arguments in place" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\StringMap[T:type]:=map(string,T)
        \\Scores:StringMap[i64]=map{"a"=>1,"b"=>2}
        \\OptionalArray[T:type]:=[]option(T)
        \\Items:OptionalArray[i64]=array{option{1},option{}}
        \\Pair[T:type,U:type]:=tuple(T,U)
        \\P:Pair[i64,string]=tuple{1,"a"}
        \\Pred[T:type]:=function(tuple(T),logic)
        \\IsBig(X:i64)<computes>:logic=X>5
        \\B:Pred[i64]=IsBig
        \\Twice[T:type]:=Pair[T,T]
        \\Deep[T:type]:=OptionalArray[Twice[T]]
        \\D:Deep[i64]=array{option{tuple{1,2}}}
        \\Same:Pair[i64,i64]=Attempt(D[0]?,tuple{0,0})
        \\Ints:=StringMap[i64]
        \\Back:Ints=Scores
        \\Keyed[K:comparable]:=map(K,i64)
        \\Kd:Keyed[string]=map{"k"=>3}
        \\Box[T:type]:=class{Value:T}
        \\Boxed[T:type]:=Box[T]
        \\Bx:Boxed[i64]=Box[i64]{Value:=4}
        \\Cast<public>:i64=Attempt(Boxed[i64][Bx].Value,0)
        \\Gen[T:type](V:T)<computes>:Twice[T]{tuple{V,V}}
        \\G:Twice[string]=Gen[string]("x")
        \\R<public>:i64=Attempt(Scores["b"],0)+Items.Length*10+P(0)*100+If(B(7),1000,0)+Same(1)*10000+Back.Length*100000+Kd.Length*1000000
        \\S<public>:string=G(0)+G(1)
    );
    try expectInt(x, "R", 2 + 20 + 100 + 1000 + 20000 + 200000 + 1000000);
    try expectInt(x, "Cast", 4);
    try expectText(x, "S", "xx");
    // An alias makes no type of its own: `Pair[i64,i64]` and `Twice[i64]` are one type.
    var tuples: usize = 0;
    for (x.program.definitions) |item| if (item == .tuple) {
        tuples += 1;
    };
    try std.testing.expect(tuples < 12);
}

test "rfc0083 a parametric alias is checked where it is written and where it is named" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { []const u8, Code, []const u8 }{
        .{ "A[T:type]:=[]Missing", .unsupported_type, "Missing" },
        .{ "A[T:type]:=[]A[T]", .unsupported_type, "A" },
        .{ "A[T:type]:=[]T extra", .unexpected_token, "extra" },
        .{ "A[T:type]:=[]T\nX:A=array{}", .type_arguments_required, "A" },
        .{ "A[T:type]:=[]T\nX:A[i64,i64]=array{}", .argument_count, "A" },
        .{ "A[T:type]:=[]T\nX:A[i64]=array{\"a\"}", .type_mismatch, "\"a\"" },
        .{ "K[T:comparable]:=map(T,i64)\nX:K[function(tuple(),i64)]=map{}", .not_comparable, "K" },
        .{ "Animal:=class{}\nPen[T:subtype(Animal)]:=[]T\nX:Pen[i64]=array{}", .type_argument_bound, "Pen" },
        .{ "A[T:type]:=[]T\nA:i64=1", .duplicate_name, "A" },
        .{ "X:i64=1\nA[X:type]:=[]X", .shadowed_name, "X" },
        .{ "A[E:effect]:=[]i64", .unsupported_type, "A" },
        // Nothing is built through an alias (RFC-0074).
        .{ "P[T:type]:=struct{X:T}\nQ[T:type]:=P[T]\nV:=Q[i64]{X:=1}", .unknown_name, "Q" },
    }) |case| try expectRefused(h, case[0], case[1], case[2]);
    // Across modules: a public alias is named through the path, and names only public types.
    const lib = "Strings<public>[T:type]:=map(string,T)\nHidden:=struct{X:i64}\nKept[T:type]:=[]Hidden";
    const x = try bundleRuns(h, "L:=import{\"lib.forb\"}\nS:L.Strings[i64]=map{\"a\"=>2}\nA<public>:i64=S.Length", lib);
    try expectInt(x, "A", 1);
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nS:L.Kept[i64]=array{}", lib, .private_name, "main.forb", "L.Kept");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=1", "Hidden:=struct{X:i64}\nShown<public>[T:type]:=[]Hidden", .private_type_escape, "lib.forb", "[");
}

test "rfc0083 parametric aliases nest only as deep as the expression limit" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&source);
    // Eight levels are read; the ninth is one too many.
    const depth = 10;
    try writer.writeAll("A0[T:type]:=[]T\n");
    for (1..depth) |level| try writer.print("A{d}[T:type]:=A{d}[T]\n", .{ level, level - 1 });
    try writer.print("X:A{d}[i64]=array{{}}\n", .{depth - 1});
    const result = h.front.compile(writer.buffered());
    if (result != .failed) return error.Compiled;
    if (result.failed.code != .expression_limit) std.debug.print("alias depth: {s}\n", .{@tagName(result.failed.code)});
    try std.testing.expectEqual(Code.expression_limit, result.failed.code);
    var shallow: [4096]u8 = undefined;
    var short = std.Io.Writer.fixed(&shallow);
    try short.writeAll("A0[T:type]:=[]T\n");
    for (1..8) |level| try short.print("A{d}[T:type]:=A{d}[T]\n", .{ level, level - 1 });
    try short.writeAll("X<public>:A7[i64]=array{1,2}\n");
    const x = try h.execute(short.buffered());
    try std.testing.expectEqual(@as(u32, 2), x.get("X").?.aggregate.elements.end - x.get("X").?.aggregate.elements.start);

    // Each alias names the one below it four times: read once per list of arguments, eight
    // levels cost eight reads, not four to the eighth (the review's reproducer, which took
    // seconds at ten levels when every use was read again).
    var wide: [4096]u8 = undefined;
    var fan = std.Io.Writer.fixed(&wide);
    try fan.writeAll("B0[T:type]:=[]T\n");
    for (1..8) |level| try fan.print("B{d}[T:type]:=tuple(B{d}[T],B{d}[T],B{d}[T],B{d}[T])\n", .{ level, level - 1, level - 1, level - 1, level - 1 });
    try fan.writeAll("Y:option(B7[i64])=option{}\nZ:option(B7[string])=option{}\nW<public>:logic=not Y.IsSet\n");
    const start = std.Io.Clock.awake.now(std.testing.io);
    const y = try h.execute(fan.buffered());
    try std.testing.expect(y.get("W").?.boolean);
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() < 2 * std.time.ns_per_s);
}

// ---- Open enums

test "rfc0083 an open enum is never exhaustive in Case(...), and Case[...] fails over it instead" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Mode:=enum<open>{On,Off}
        \\Shut:=enum<closed>{On,Off}
        \\M:Mode=Mode.Off
        \\A<public>:i64=Case(M,Mode.On=>1,_=>2)
        \\F(X:Mode)<computes><decides>:i64=Case[X,Mode.On=>1,Mode.Off=>2]
        \\B<public>:i64=Attempt(F[M],0)
        \\C<public>:i64=Case(Shut.On,Shut.On=>1,Shut.Off=>2)
        \\D<public>:logic=M==Mode.Off
    );
    try expectInt(x, "A", 2);
    try expectInt(x, "B", 2);
    try expectInt(x, "C", 1);
    try expectLogic(x, "D", true);
    try expectRefused(h, "Mode:=enum<open>{On,Off}\nM:Mode=Mode.On\nA:i64=Case(M,Mode.On=>1,Mode.Off=>2)", .open_enum_case, "Case");
    try expectRefused(h, "Mode:=enum<shut>{On,Off}", .unsupported_specifier, "shut");
    // Imported open enums are open in the importer too.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=Case(L.Mode.On,L.Mode.On=>1,L.Mode.Off=>2)", "Mode<public>:=enum<open>{On,Off}", .open_enum_case, "main.forb", "Case");
}

// ---- Arms the types show to be unreachable

test "rfc0083 a Case[...] arm whose type an earlier arm already takes is subsumed_arm" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "Animal:=class{}\nDog:=class(Animal){}\nWalker:=interface{}\nBot:=class(Walker){}\nInts:=[]i64\n";
    for ([_]struct { []const u8, []const u8 }{
        .{ "F(V:any)<computes><decides>:i64=Case[V,M:Animal=>1,K:Dog=>2]", "K:Dog" },
        .{ "F(V:any)<computes><decides>:i64=Case[V,W:Walker=>1,B:Bot=>2]", "B:Bot" },
        .{ "F(V:any)<computes><decides>:i64=Case[V,M:[]i64=>1,K:Ints=>2]", "K:Ints" },
        .{ "F[T:type](V:any)<computes><decides>:i64{Case[V,M:T=>1,K:Dog=>2]}\nX:i64=Attempt(F[Animal][any(Dog{})],0)", "K:Dog" },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, case[0] });
        try expectRefused(h, source, .subsumed_arm, case[1]);
    }
    // RFC-0090: and in `Case(...)`, also in each specialization of a generic function.
    for ([_]struct { []const u8, []const u8 }{
        .{ "T(V:any)<computes>:i64=Case(V,M:Animal=>1,K:Dog=>2,_=>0)", "K:Dog" },
        .{ "F[T:type](V:any)<computes>:i64{Case(V,M:T=>1,K:Dog=>2,_=>0)}\nX:i64=F[i64](any(1))\nY:i64=F[Animal](any(Dog{}))", "K:Dog" },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, case[0] });
        try expectRefused(h, source, .subsumed_arm, case[1]);
    }
    // The narrower arm first, a guard on the wider one and other specializations keep their
    // meaning.
    const x = try h.execute(head ++
        \\F(V:any)<computes><decides>:i64=Case[V,K:Dog=>2,M:Animal=>1]
        \\G(V:any)<computes><decides>:i64=Case[V,M:Animal where false=>1,K:Dog=>2]
        \\H[T:type](V:any)<computes><decides>:i64{Case[V,M:T=>1,K:Dog=>2]}
        \\T(V:any)<computes>:i64=Case(V,K:Dog=>2,M:Animal=>1,_=>0)
        \\A<public>:i64=Attempt(F[any(Dog{})],0)*1000+Attempt(G[any(Dog{})],0)*100+Attempt(H[i64][any(Dog{})],0)*10+T(any(Dog{}))
    );
    try expectInt(x, "A", 2222);
}

// ---- The conversions back and the message of `not_comparable`

test "rfc0083 i64(X) and float(X) convert a refinement to its base and nothing else" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("A:=type{_X:i64 where _X>0}\nB:=type{_X:float where _X>0.0}\nV<public>:i64=Attempt(i64(A[3]),0)\nW<public>:float=float(Attempt(B[2.5],1.0))\nN<public>:i64=i64(7)\nF<public>:float=float(1.5)");
    _ = x;
    try expectRefused(h, "V:i64=i64(1.5)", .type_mismatch, "1.5");
    try expectRefused(h, "V:float=float(1)", .type_mismatch, "1");
    try expectRefused(h, "V:i64=i64(1,2)", .argument_count, ",");
    // The bracket is the cast of a value of `any` to the type, as before (RFC-0080).
    try expectRefused(h, "V:i64=i64[1]", .type_mismatch, "1");
    try std.testing.expectEqualStrings("this type has no equality: a function, a task, a value held as any, or something that holds one", (types.Diagnostic{ .span = .{ .start = 0, .end = 0 }, .code = .not_comparable }).message());
}

test "rfc0083 inspection format 28 shows refinements with their bounds, and open enums" {
    const h = try harness.create();
    defer scratch.release(h);
    const view = try scratch.storage(inspection.Workspace);
    defer scratch.release(view);
    scratch.initialise(view);
    const p = try h.compile("Age:=type{_X:i64 where 0<=_X,_X<=120}\nF:=type{_X:float where -Inf<_X}\nM:=enum<open>{A}\nC:=enum{B}\nV:Age=3");
    var buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(inspection.Result.ok, try view.write(&out, p));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 28), parsed.value.object.get("format").?.integer);
    const items = parsed.value.object.get("type_definitions").?.array.items;
    try std.testing.expectEqualStrings("refinement", items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("i64", items[0].object.get("base").?.string);
    try std.testing.expectEqual(@as(i64, 0), items[0].object.get("low").?.integer);
    try std.testing.expectEqual(@as(i64, 120), items[0].object.get("high").?.integer);
    try std.testing.expect(items[0].object.get("low_open") == null);
    try std.testing.expectEqualStrings("-Inf", items[1].object.get("low").?.string);
    try std.testing.expectEqualStrings("Inf", items[1].object.get("high").?.string);
    try std.testing.expect(items[1].object.get("low_open").?.bool and items[1].object.get("high_open") == null);
    try std.testing.expect(items[2].object.get("open").?.bool);
    try std.testing.expect(items[3].object.get("open") == null);
    // A program with none of them keeps the format it had.
    var plain_buffer: [16 * 1024]u8 = undefined;
    var plain = std.Io.Writer.fixed(&plain_buffer);
    try std.testing.expectEqual(inspection.Result.ok, try view.write(&plain, try h.compile("C:=enum{B}\nV:i64=1")));
    try std.testing.expect(std.mem.startsWith(u8, plain.buffered(), "{\"format\":3,"));
}
