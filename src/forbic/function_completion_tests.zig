//! Functions completion (RFC-0091, B3), besides mutual recursion (`mutual_recursion_tests.zig`):
//! destructured parameters, `false` as the bottom type, and type arguments read off the
//! arguments of a generic call. None adds an IR operation: a pattern is tuple element reads at
//! the start of the body, a value of `false` is followed by an `Err` no run reaches, and an
//! inferred call is the call its explicit type arguments would have written.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

fn expectInteger(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.integer != expected) std.debug.print("{s}: expected {d}, found {d}\n", .{ name, expected, value.integer });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    try std.testing.expect(r.failed.span.end <= source.len);
}

test "parameters destructure tuples to any depth, typed on their names or on the whole pattern" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Func(A:i64,(B:i64,C:i64),D:i64)<computes>:i64=A+B+C+D
        \\H(A:i64,(B:i64,(C:i64,D:i64)),E:i64)<computes>:i64=A+B+C+D+E
        \\Ann((X,Y):tuple(i64,string))<computes>:string=Y+ToString(X)
        \\Nest((P,(Q,R)):tuple(i64,tuple(i64,i64)))<computes>:i64=P*100+Q*10+R
        \\Mixed((P:i64,(Q,R):tuple(i64,i64)))<computes>:i64=P*100+Q*10+R
        \\Clos((A:i64,B:i64))<computes>:i64=Block{K:=Fn(Z:i64)<computes>:i64{A*Z+B};K(10)}
        \\Early((A:i64,B:i64))<computes>:i64=Block{If(A>B,Return(A),false);B}
        \\point:=class{K:i64=2;Scale((X:i64,Y:i64))<reads>:i64=(X+Y)*Self.K}
        \\(V:i64).Plus((A:i64,B:i64))<computes>:i64=V+A+B
        \\Second[T:type]((A:T,B:T))<computes>:T{B}
        \\Outer(N:i64)<computes>:i64=Block{
        \\  Inner((A:i64,B:i64))<computes>:i64=A-B
        \\  Inner(tuple{N,1})
        \\}
        \\Times:function(tuple(tuple(i64,i64)),i64)=Fn((A:i64,B:i64))<computes>:i64{A*B}
        \\Ahead((A:i64,B:i64))<computes>:i64=Behind(tuple{B,A})
        \\Behind((X:i64,Y:i64))<computes>:i64=X*10+Y
        \\Va:i64=Func(1,tuple{2,3},4)
        \\Vb:i64=H(1,tuple{2,tuple{3,4}},5)
        \\Vc:string=Ann(tuple{7,"n"})
        \\Vd:i64=Nest(tuple{1,tuple{2,3}})
        \\Ve:i64=Mixed(tuple{1,tuple{2,3}})
        \\Vf:i64=Clos(tuple{3,4})
        \\Vg:i64=Early(tuple{9,5})+Early(tuple{1,5})
        \\Vh:i64=point{}.Scale(tuple{3,4})
        \\Vi:i64=(1).Plus(tuple{2,3})
        \\Vj:i64=Second[i64](tuple{5,6})
        \\Vk:i64=Outer(10)
        \\Vl:i64=Times(tuple{6,7})
        \\Vm:i64=Ahead(tuple{1,2})
    );
    try expectInteger(x, "Va", 10);
    try expectInteger(x, "Vb", 15);
    try std.testing.expectEqualStrings("n7", x.get("Vc").?.string);
    try expectInteger(x, "Vd", 123);
    try expectInteger(x, "Ve", 123);
    try expectInteger(x, "Vf", 34);
    try expectInteger(x, "Vg", 14);
    try expectInteger(x, "Vh", 14);
    try expectInteger(x, "Vi", 6);
    try expectInteger(x, "Vj", 6);
    try expectInteger(x, "Vk", 9);
    try expectInteger(x, "Vl", 42);
    try expectInteger(x, "Vm", 21);
}

test "a destructured parameter writes each type once, has two or more elements and no default" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectCode(h, "F((A:i64))<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F((A,B:i64):tuple(i64,i64))<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F((A,B))<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F((A,B):tuple(i64,i64,i64))<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F((A,B):i64)<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F(((A,B):tuple(i64,i64),C):tuple(tuple(i64,i64),i64))<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "F((A:i64,B:i64)=tuple{1,2})<computes>:i64=A", .parameter_pattern);
    try expectCode(h, "c:=class{V:i64}\nM<constructor>((A:i64,B:i64))<computes>:=c{V:=A}", .parameter_pattern);
    try expectCode(h, "F((A:i64,A:i64))<computes>:i64=A", .duplicate_name);
    try expectCode(h, "F(A:i64,(A:i64,B:i64))<computes>:i64=A", .duplicate_name);
    try expectCode(h, "F((A:i64,B:i64),A:i64)<computes>:i64=A", .duplicate_name);
    try expectCode(h, "F((F:i64,B:i64))<computes>:i64=B", .shadowed_name);
    try expectCode(h, "F((A:i64,B:i64))<computes>:i64=Block{A:=1;A}", .shadowed_name);
    try expectCode(h, "F((A:i64,B:i64))<computes>:i64=A\nX:i64=F(tuple{1,\"a\"})", .type_mismatch);
    // The pattern's own parameter has no name a body or a caller can write.
    try expectCode(h, "F((A:i64,B:i64))<computes>:i64=A\nX:i64=F(A:=tuple{1,2})", .unknown_parameter);
}

test "patterns agree with a direct model on 300 random nested shapes" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xB30);
    const random = prng.random();
    for (0..300) |_| {
        // A pattern of two or three elements, each a name or a pattern of two names, typed on
        // its names or on the whole; each name is weighed by its place, so a name bound to the
        // wrong element changes the sum.
        var pattern_buffer: [256]u8 = undefined;
        var pattern = std.Io.Writer.fixed(&pattern_buffer);
        var argument_buffer: [256]u8 = undefined;
        var argument = std.Io.Writer.fixed(&argument_buffer);
        var shape_buffer: [256]u8 = undefined;
        var shape = std.Io.Writer.fixed(&shape_buffer);
        var weights: [8]i64 = undefined;
        var names: usize = 0;
        var weight: i64 = 1;
        var expected: i64 = 0;
        const count = 2 + random.uintLessThan(usize, 2);
        const annotated = random.boolean();
        for (0..count) |element| {
            const separator = if (element == 0) "" else ",";
            try pattern.writeAll(separator);
            try argument.writeAll(separator);
            try shape.writeAll(separator);
            const a = random.intRangeAtMost(i64, -50, 50);
            if (random.boolean()) {
                const b = random.intRangeAtMost(i64, -50, 50);
                if (annotated) try pattern.print("(N{d},N{d})", .{ names, names + 1 }) else try pattern.print("(N{d}:i64,N{d}:i64)", .{ names, names + 1 });
                try argument.print("tuple{{{d},{d}}}", .{ a, b });
                try shape.writeAll("tuple(i64,i64)");
                weights[names] = weight;
                weights[names + 1] = weight * 3;
                expected += a * weight + b * weight * 3;
                names += 2;
            } else {
                if (annotated) try pattern.print("N{d}", .{names}) else try pattern.print("N{d}:i64", .{names});
                try argument.print("{d}", .{a});
                try shape.writeAll("i64");
                weights[names] = weight;
                expected += a * weight;
                names += 1;
            }
            weight *= 7;
        }
        var out = std.Io.Writer.fixed(&h.text);
        if (annotated) try out.print("F(({s}):tuple({s}))<computes>:i64=", .{ pattern.buffered(), shape.buffered() }) else try out.print("F(({s}))<computes>:i64=", .{pattern.buffered()});
        for (weights[0..names], 0..) |w, name| try out.print("{s}N{d}*{d}", .{ if (name == 0) "" else "+", name, w });
        try out.print("\nV:i64=F(tuple{{{s}}})", .{argument.buffered()});
        const x = try h.execute(out.buffered());
        try expectInteger(x, "V", expected);
    }
}

test "false is the bottom type: a value of it stands where any type is expected, and none exists" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Fatal(Message:string)<computes>:false=Err(Message)
        \\Check(N:i64)<computes>:i64=If(N>=0,N*2,Fatal("negative"))
        \\Flip(N:i64)<computes>:i64=If(N<0,Fatal("negative"),N+1)
        \\Safe(N:i64)<computes><decides>:i64=If(N>100,Fatal("big"),Block{Require[N>0];N})
        \\Choose(N:i64)<computes>:string=If(N==0,"zero",If(N>0,"pos",Fatal("neg")))
        \\Spin(N:i64)<transacts>:i64=Block{var X:i64=N;set X=If(X>5,Fatal("x"),X+1);X}
        \\Pass(N:i64)<computes>:i64=N
        \\Arg(N:i64)<computes>:i64=If(N>0,Pass(N),Pass(Fatal("no")))
        \\A:i64=Check(4)
        \\B:i64=Flip(4)
        \\C:i64=Attempt(Safe[0],-1)
        \\D:string=Choose(3)
        \\E:i64=Spin(2)
        \\F:i64=Arg(3)
        \\Empty:[]false=array{}
        \\None:option(false)=option{}
    );
    try expectInteger(x, "A", 8);
    try expectInteger(x, "B", 5);
    try expectInteger(x, "C", -1);
    try std.testing.expectEqualStrings("pos", x.get("D").?.string);
    try expectInteger(x, "E", 3);
    try expectInteger(x, "F", 3);
    // A call of it ends the run with what ends it.
    const fatal = try h.run(try h.compile("Fatal(Message:string)<computes>:false=Err(Message)\nA:i64=Fatal(\"boom\")"), 10_000);
    try std.testing.expectEqual(types.Diagnostic.Code.runtime_error, fatal.failed.code);
    const never = try h.run(try h.compile("Never()<computes>:false=Never()\nA:i64=Never()"), 1 << 20);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, never.failed.code);
    // It has no values to compare, to key a map with, to print, or to build from a literal.
    try expectCode(h, "Fatal()<computes>:false=Err(\"x\")\nA:logic=Fatal()==Fatal()", .not_comparable);
    try expectCode(h, "M:map(false,i64)=map{}", .invalid_map_key);
    try expectCode(h, "Fatal()<computes>:false=Err(\"x\")\nA:string=\"{Fatal()}\"", .type_mismatch);
    try expectCode(h, "Fatal()<computes>:false=1", .type_mismatch);
    // Exact aggregates (RFC-0067, D8): `[]false` is no `[]i64`, though `false` is an `i64`.
    try expectCode(h, "E:[]false=array{}\nA:[]i64=E", .type_mismatch);
    try expectCode(h, "F()<computes>:function(tuple(),false)=F\nG:function(tuple(),i64)=F", .type_mismatch);
}

test "both machines refuse a forged value of false" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("A:i64=1\nB:logic=true\nC:string=\"c\"");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 10_000);
    for (0..nodes.len) |index| {
        @memcpy(nodes, p.nodes);
        nodes[index].value_type = types.Type.bottom;
        try harness.invalid(h, forged);
    }
}

test "the type arguments of a generic call are read off its arguments, and the call is the explicit one" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Identity[T:type](X:T)<computes>:T{X}
        \\Pair[A:type,B:type](X:A,Y:B)<computes>:tuple(A,B){tuple{X,Y}}
        \\First[T:type](Xs:[]T,Default:T)<computes>:T{If(Xs.Length>0,ElementAt(Xs,0),Default)}
        \\Same[T:comparable](X:T,Y:T)<computes>:logic{X==Y}
        \\Count[K:type,V:type](M:map(K,V))<computes>:i64{M.Length}
        \\Unwrap[T:type](O:option(T),D:T)<computes>:T{Or(O,D)}
        \\Swap[A:type,B:type](P:tuple(A,B))<computes>:tuple(B,A){tuple{P(1),P(0)}}
        \\Apply[T:type](F:function(tuple(T),T),X:T)<computes>:T{F(X)}
        \\Rec[T:type](N:i64,X:T)<computes>:T{If(N<=0,X,Rec(N-1,X))}
        \\Inc(N:i64)<computes>:i64=N+1
        \\Use(N:i64)<computes>:i64=Identity(N)+First(array{N,2},0)
        \\Va:i64=Identity(41)
        \\Vb:string=Identity("s")
        \\Vc:tuple(i64,string)=Pair(1,"a")
        \\Vd:i64=First(array{7,8},0)
        \\Ve:i64=Count(map{1=>"a",2=>"b"})
        \\Vf:i64=Unwrap(option{5},0)
        \\Vg:tuple(string,i64)=Swap(tuple{3,"x"})
        \\Vh:i64=Use(10)
        \\Vi:i64=Identity(Identity(2))+Identity[i64](3)
        \\Vj:logic=Same(1,1)
        \\Vk:i64=Apply(Inc,4)
        \\Vl:string=Rec(3,"r")
    );
    try expectInteger(x, "Va", 41);
    try std.testing.expectEqualStrings("s", x.get("Vb").?.string);
    try expectInteger(x, "Vd", 7);
    try expectInteger(x, "Ve", 2);
    try expectInteger(x, "Vf", 5);
    try expectInteger(x, "Vh", 20);
    try expectInteger(x, "Vi", 5);
    try std.testing.expect(x.get("Vj").?.boolean);
    try expectInteger(x, "Vk", 5);
    try std.testing.expectEqualStrings("r", x.get("Vl").?.string);
    // The same program with the type arguments written compiles to the same operations, up to
    // the order the catalogue numbers its types in and the place of the callee's reference,
    // which an inferred call takes after its arguments (a reference has no effect).
    const pairs = [_][2][]const u8{
        .{ "Id[T:type](X:T)<computes>:T{X}\nF(N:i64)<computes>:i64=Id(N)+Id(N)\nA:i64=Id(1)+F(2)", "Id[T:type](X:T)<computes>:T{X}\nF(N:i64)<computes>:i64=Id[i64](N)+Id[i64](N)\nA:i64=Id[i64](1)+F(2)" },
        .{ "P[A:type,B:type](X:A,Y:B)<computes>:tuple(B,A){tuple{Y,X}}\nA:tuple(string,i64)=P(1,\"a\")", "P[A:type,B:type](X:A,Y:B)<computes>:tuple(B,A){tuple{Y,X}}\nA:tuple(string,i64)=P[i64,string](1,\"a\")" },
        .{ "H[T:type](Xs:[]T)<computes>:i64{Xs.Length}\nF(Xs:[]string)<computes>:i64=H(Xs)\nA:i64=F(array{\"a\"})", "H[T:type](Xs:[]T)<computes>:i64{Xs.Length}\nF(Xs:[]string)<computes>:i64=H[string](Xs)\nA:i64=F(array{\"a\"})" },
    };
    for (pairs) |pair| {
        const inferred = try h.compile(pair[0]);
        const functions = try std.testing.allocator.dupe(types.RuntimeFunction, inferred.functions);
        defer std.testing.allocator.free(functions);
        const bodies = try std.testing.allocator.dupe(types.FunctionNode, inferred.function_nodes);
        defer std.testing.allocator.free(bodies);
        const roots = try std.testing.allocator.dupe(types.Node, inferred.nodes);
        defer std.testing.allocator.free(roots);
        const explicit = try h.compile(pair[1]);
        try std.testing.expectEqual(functions.len, explicit.functions.len);
        try std.testing.expectEqual(bodies.len, explicit.function_nodes.len);
        try std.testing.expectEqual(roots.len, explicit.nodes.len);
        for (functions, explicit.functions) |a, b| {
            try std.testing.expectEqual(a.parameter_count, b.parameter_count);
            try std.testing.expectEqual(a.specialization != null, b.specialization != null);
            try std.testing.expectEqual(a.body.end - a.body.start, b.body.end - b.body.start);
        }
        var kinds: [2][std.enums.values(std.meta.Tag(@FieldType(types.Node, "kind"))).len]u32 = @splat(@splat(0));
        for (bodies) |a| kinds[0][@backingInt(std.meta.activeTag(a.node.kind))] += 1;
        for (roots) |a| kinds[0][@backingInt(std.meta.activeTag(a.kind))] += 1;
        for (explicit.function_nodes) |b| kinds[1][@backingInt(std.meta.activeTag(b.node.kind))] += 1;
        for (explicit.nodes) |b| kinds[1][@backingInt(std.meta.activeTag(b.kind))] += 1;
        try std.testing.expectEqualSlices(u32, &kinds[0], &kinds[1]);
    }
}

test "a type argument the arguments do not give, or give twice differently, is written" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectCode(h, "Make[T:type](N:i64)<computes>:[]T{array{}}\nA:[]i64=Make(1)", .type_inference);
    try expectCode(h, "Same[T:type](X:T,Y:T)<computes>:T{X}\nA:i64=Same(1,\"a\")", .type_inference);
    try expectCode(h, "Pick[T:type](X:T)<computes><decides>:T{X}\nA:i64=Pick(1)", .type_inference);
    try expectCode(h, "Pick[T:type](X:T)<computes>:T{X}\nA:i64=Pick(X:=1)", .type_inference);
    try expectCode(h, "Run[E:effect,T:type](X:T)<E>:T{X}\nA:i64=Run(1)", .type_inference);
    try expectCode(h, "Apply[T:type](F:function(tuple(T),T))<computes>:i64{1}\nInc(N:i64)<computes>:i64=N\nA:i64=Apply(Inc)", .type_inference);
    try expectCode(h, "Pick[T:type](X:T)<computes>:T{X}\nA:[]i64=Pick(array{})", .array_type_required);
    try expectCode(h, "Pick[T:type](X:T)<computes>:T{X}\nA:i64=Pick()", .argument_count);
    try expectCode(h, "Pick[T:type](X:T)<computes>:T{X}\nA:i64=Pick(1,2)", .argument_count);
    try expectCode(h, "Head[T:type](Xs:[]T)<computes>:T{ElementAt(Xs,0)}\nA:i64=Head(5)", .type_mismatch);
    try expectCode(h, "Same[T:comparable](X:T,Y:T)<computes>:logic{X==Y}\nF(N:i64)<computes>:i64=N\nA:logic=Same(F,F)", .not_comparable);
    // Inference reads the types a parameter can be written in: `option(T)` and `map(K,V)`,
    // never the `?T` and `[K]V` the type syntax does not have.
    try expectCode(h, "Get[T:type](V:?T)<computes>:i64{1}\nA:i64=Get(option{1})", .expected_type);
    try expectCode(h, "Keys[K:type,V:type](M:[K]V)<computes>:i64{1}\nA:i64=Keys(map{1=>2})", .expected_type);
}

test "review: a closure that captures reads its patterns past its captures, and JSON and inference know patterns and false" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A:i64=Block{P:=tuple{7,8};K:=Fn((X,Y):tuple(i64,i64))<computes>:i64{X*10+Y+P(0)};K(tuple{1,2})}
        \\B:i64=Block{P:=5;K:=Fn((X,Y):tuple(i64,i64))<computes>:i64{X*10+Y+P};K(tuple{1,2})}
        \\F(P:i64)<computes>:i64=Block{K:=Fn(Z:i64,(X,Y):tuple(i64,i64))<computes>:i64{X*10+Y+P+Z};K(100,tuple{1,2})}
        \\C:i64=F(5)
        \\G((P,Q):tuple(i64,i64))<computes>:i64=Block{
        \\  In((X:i64,Y:i64))<computes>:i64=X*10+Y+P
        \\  In(tuple{Q,P})
        \\}
        \\D:i64=G(tuple{1,2})
        \\E:i64=Block{P:=3;For(I:array{1,2},Block{K:=Fn((X,Y):tuple(i64,i64))<computes>:i64{X+Y+P};K(tuple{I,I})})}.Length
        \\Sw[U:type,V:type]((X,Y):tuple(U,V))<computes>:tuple(V,U){tuple{Y,X}}
        \\Nested[T:type]((X:T,(Y:T,Z:T)))<computes>:T{Z}
        \\S:string=Sw(tuple{1,"a"})(0)
        \\N:i64=Nested(tuple{1,tuple{2,3}})
    );
    try expectInteger(x, "A", 19);
    try expectInteger(x, "B", 17);
    try expectInteger(x, "C", 117);
    try expectInteger(x, "D", 22);
    try expectInteger(x, "E", 2);
    try std.testing.expectEqualStrings("a", x.get("S").?.string);
    try expectInteger(x, "N", 3);
    try expectCode(h, "X:[]false=array{}\nA:string=ToJson(X)", .json_type);
    try expectCode(h, "A:i64=Attempt(Block{FromJson[false][\"true\"];1},0)", .json_type);
    try expectCode(h, "Fatal(M:string)<computes>:false=Err(M)\nA:string=ToJson(Fatal(\"x\"))", .json_type);
}
