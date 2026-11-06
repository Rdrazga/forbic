//! Shared locals, RFC-0085 I2: an `Fn` that assigns a local `var` of the code around it shares
//! the local (S1d), which is then a variable cell `ref(T)` (S2) that every closure naming it
//! refers to. Programs that share nothing compile and run exactly as before.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const allocator = std.testing.allocator;

fn expectInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const x = try h.execute(source);
    const value = x.get(name) orelse return error.MissingBinding;
    if (value.integer != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, value.integer, expected, source });
    try std.testing.expectEqual(expected, value.integer);
}

fn refuses(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    switch (h.front.compile(source)) {
        .ok => {
            std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
            return error.Compiled;
        },
        .failed => |d| {
            if (d.code != code or !std.mem.eql(u8, source[d.span.start..d.span.end], at)) {
                std.debug.print("got {s} at '{s}', expected {s} at '{s}': {s}\n", .{ @tagName(d.code), source[d.span.start..d.span.end], @tagName(code), at, source });
                return error.WrongDiagnostic;
            }
        },
    }
}

/// Whether the program has a variable cell type, and how many of each cell operation.
const Census = struct { ref_type: bool = false, new: usize = 0, get: usize = 0, set: usize = 0 };
fn census(p: types.Program) Census {
    var c: Census = .{};
    for (p.definitions) |d| c.ref_type = c.ref_type or d == .ref;
    const count = struct {
        fn node(into: *Census, n: types.Node) void {
            switch (n.kind) {
                .ref_new => into.new += 1,
                .ref_get => into.get += 1,
                .ref_set => into.set += 1,
                else => {},
            }
        }
    }.node;
    for (p.nodes) |n| count(&c, n);
    for (p.function_nodes) |entry| if (entry.input == .operation) count(&c, entry.node);
    return c;
}

test "an Fn that assigns an outer local shares it with the code around it" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0085's `Total`: the `Fn` adds to `Sum`, and the function reads it after the loop.
    try expectInt(h, "Total(Xs:[]i64)<transacts>:i64=Block{\nvar Sum:i64=0\nAdd:function<transacts>(tuple(i64),void)=Fn(X:i64)<transacts>:void{Block{set Sum+=X;0}}\nFor(Y:Xs,Add(Y))\nSum}\nV:i64=Total(array{1,2,3,4})", "V", 10);
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:i64{Block{set X=X*10;X}};G();G();X}\nV:i64=F()", "V", 100);
    // `Set` yields the value it wrote.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:i64{Set(X,X+5)};A:=G();A+X}\nV:i64=F()", "V", 12);
    // Closures that only read it refer to the cell too, once something shares it.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};W:=Fn()<transacts>:void{Set(X,7)};A:=R();W();A*100+R()}\nV:i64=F()", "V", 107);
    // The code around writes it, and the closure sees the write.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};W:=Fn()<transacts>:void{Set(X,7)};set X=3;A:=R();W();A*100+R()+X}\nV:i64=F()", "V", 314);
    // Path assignments assign the variable too.
    try expectInt(h, "F()<transacts>:i64=Block{var Xs:[]i64=array{1,2,3};G:=Fn()<transacts>:i64{Attempt(Block{set Xs[1]=20;0},0)};G();Attempt(Xs[1],0)+Xs.Length}\nV:i64=F()", "V", 23);
    try expectInt(h, "P:=struct{A:i64=0,B:i64=0}\nF()<transacts>:i64=Block{var Q:P=P{};G:=Fn()<transacts>:i64{Block{set Q.B=9;0}};G();Q.A*10+Q.B}\nV:i64=F()", "V", 9);
    // An `Fn` in an `Fn` assigns through both captures.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;O:=Fn()<transacts>:i64{Block{I:=Fn()<transacts>:i64{Set(X,X+2)};I();I()}};O();X}\nV:i64=F()", "V", 5);
    // The root shares as functions do.
    try expectInt(h, "V:i64=Block{var X:i64=2;G:=Fn()<transacts>:void{Block{set X+=3;0}};G();G();X}", "V", 8);
    // A closure that outlives the frame keeps the cell: two counters, each its own.
    try expectInt(h,
        \\Counter:=tuple(function<reads>(tuple(),i64),function<transacts>(tuple(),void))
        \\Make(I:i64)<transacts>:Counter=Block{var C:i64=I;tuple{Fn()<reads>:i64{C},Fn()<transacts>:void{Set(C,C+1)}}}
        \\A:Counter=Make(0)
        \\B:Counter=Make(10)
        \\V:i64=Block{A(1)();A(1)();B(1)();A(0)()*100+B(0)()}
    , "V", 211);
}

test "every visit of a loop that declares a shared local makes a cell, and one declared outside is one cell" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Inside()<transacts>:[]i64=For(I:1..3,Block{var C:i64=I;G:=Fn()<transacts>:i64{Set(C,C+10)};G();C})\nOutside()<transacts>:tuple([]i64,i64)=Block{var C:i64=0;Rs:=For(I:1..3,Block{G:=Fn()<transacts>:i64{Set(C,C+I)};G()});tuple{Rs,C}}\nA:[]i64=Inside()\nB:tuple([]i64,i64)=Outside()");
    const a = x.elements(x.get("A").?).?;
    try std.testing.expectEqual(@as(usize, 3), a.len);
    for (a, 0..) |value, index| try std.testing.expectEqual(@as(i64, @intCast(index + 11)), value.integer);
    const b = x.elements(x.get("B").?).?;
    const rs = x.elements(b[0]).?;
    try std.testing.expectEqual(@as(i64, 1), rs[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rs[1].integer);
    try std.testing.expectEqual(@as(i64, 6), rs[2].integer);
    try std.testing.expectEqual(@as(i64, 6), b[1].integer);
}

test "no loop carries a shared local: writes from closures during the loop stay" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each loop assigns the local itself and calls a closure that assigns it. A carried copy
    // would be written back over the closure's writes after the loop.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;G:=Fn()<transacts>:i64{Set(X,X+100)};For(I:1..3,Block{set X=X+I;G()});X}\nV:i64=F()", "V", 306);
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;var N:i64=0;G:=Fn()<transacts>:i64{Set(X,X+100)};While(N<3,Block{set N=N+1;set X=X+N;G()});X*10+N}\nV:i64=F()", "V", 3063);
    try expectInt(h,
        \\F()<transacts>:i64=Block{
        \\  var X:i64=0
        \\  var N:i64=0
        \\  G:=Fn()<transacts>:i64{Set(X,X+100)}
        \\  Loop{
        \\    If(N>=3,Break(),false)
        \\    set N=N+1
        \\    set X=X+N
        \\    G()
        \\  }
        \\  X*10+N
        \\}
        \\V:i64=F()
    , "V", 3063);
    // A loop at the root does the same.
    try expectInt(h, "V:i64=Block{var X:i64=0;G:=Fn()<transacts>:i64{Set(X,X+100)};For(I:1..3,Block{set X=X+I;G()});X}", "V", 306);
    // A loop inside the `Fn`, over the variable it shares.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;G:=Fn()<transacts>:i64{Block{For(I:1..4,Block{set X=X+I;0});X}};G();set X=X*2;G()}\nV:i64=F()", "V", 30);
    // Locals the loops assign that nothing shares are carried as before.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;var Y:i64=0;G:=Fn()<transacts>:i64{Set(X,X+100)};For(I:1..3,Block{set Y=Y+I;G()});X+Y}\nV:i64=F()", "V", 306);
}

test "a task captures the cell an Fn shares and the creator sees its write after the wait" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Waits()<transacts><suspends>:i64=Block{
        \\  var Seen:i64=0
        \\  Note:=Fn()<transacts>:void{Set(Seen,Seen+7)}
        \\  T:=Spawn{Sleep(1.0);Note()}
        \\  var N:i64=0
        \\  Loop{
        \\    If(N>=2,Break(),false)
        \\    Sleep(1.0)
        \\    Note()
        \\    set N=N+1
        \\  }
        \\  T.Await()
        \\  Seen*10+N
        \\}
        \\T:task(i64)=Spawn{Waits()}
    );
    // The task's write after its `Sleep` and the creator's two are all in the one cell.
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), "\"result\":212") == null) std.debug.print("{s}\n", .{out.buffered()});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":212") != null);
}

test "a local an Fn only reads is shared too (Q1); a program no closure names a local in keeps its program" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0085, I13: the `Fn` names `L`, so `L` is the variable, and the Book's rule gives 51.
    const snap = "Snap()<transacts>:i64=Block{var L:i64=1;F:=Fn(X:i64){L+X};set L=50;F(1)}\nV:i64=Snap()";
    try expectInt(h, snap, "V", 51);
    const p = try h.compile(snap);
    try std.testing.expect(census(p).ref_type);
    // The share note takes one compile more.
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    // Before Q1 (the switch off) the same program snapshotted: 2, no cell, one compile.
    h.front.share_names = false;
    try expectInt(h, snap, "V", 2);
    const before = try h.compile(snap);
    try std.testing.expect(!census(before).ref_type);
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    h.front.share_names = true;
    // No closure names the local: no cell, no compile more, whatever else the program does.
    const plain = "Plain()<transacts>:i64=Block{var L:i64=1;F:=Fn(X:i64){X+1};set L=50;F(L)}\nV:i64=Plain()";
    try expectInt(h, plain, "V", 51);
    const unshared = try h.compile(plain);
    try std.testing.expect(!census(unshared).ref_type);
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
}

test "a program that shares its locals outside landings takes one more compile" {
    const h = try harness.create();
    defer scratch.release(h);
    // Each pair differs only in what the `Fn` assigns: a local, which it shares, or a module
    // `var` (and so names no local: since Q1 a closure that names a local `var` shares it).
    // Other retries (the library block, a loop's general lowering) come on top of both.
    const Twin = struct { []const u8, []const u8 };
    for ([_]Twin{
        .{ "var M:i64=0\nF()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:void{Set(X,2)};G();X}\nV:i64=F()", "var M:i64=0\nF()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:void{Set(M,2)};G();X}\nV:i64=F()" },
        .{ "var M:i64=0\nF(Xs:[]i64)<transacts>:i64=Block{var X:i64=1;var Y:i64=0;G:=Fn(K:i64)<transacts>:void{Set(X,X+K)};For(K:Xs,G(K));H:=Fn()<transacts>:void{Set(Y,X)};H();X+Y}\nV:i64=F(array{1,2})", "var M:i64=0\nF(Xs:[]i64)<transacts>:i64=Block{var X:i64=1;var Y:i64=0;G:=Fn(K:i64)<transacts>:void{Set(M,K)};For(K:Xs,G(K));H:=Fn()<transacts>:void{Set(M,1)};H();X+Y}\nV:i64=F(array{1,2})" },
        .{ "var M:i64=0\nF(Xs:[]i64)<transacts>:i64=Block{var X:i64=0;G:=Fn()<transacts>:i64{Set(X,X+1)};For(K:Xs,Block{set X=X+K;Require[K>0];G()});X}\nV:i64=F(array{1,2})", "var M:i64=0\nF(Xs:[]i64)<transacts>:i64=Block{var X:i64=0;G:=Fn()<transacts>:i64{Set(M,1)};For(K:Xs,Block{set X=X+K;Require[K>0];G()});X}\nV:i64=F(array{1,2})" },
    }) |pair| {
        const shared = try h.compile(pair[0]);
        const with = h.front.passes;
        try std.testing.expect(census(shared).ref_type);
        const plain = try h.compile(pair[1]);
        try std.testing.expect(!census(plain).ref_type);
        const without = h.front.passes;
        if (with != without + 1) std.debug.print("{d} passes against {d}: {s}\n", .{ with, without, pair[0] });
        try std.testing.expectEqual(without + 1, with);
    }
}

test "a shared local lowers to one ref_new and cell reads and writes" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("F()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:void{Set(X,X+1)};set X=5;G();X}\nV:i64=F()");
    const c = census(p);
    try std.testing.expect(c.ref_type);
    try std.testing.expectEqual(@as(usize, 1), c.new);
    // `X` in the `Fn` and the last `X`; the writes are the `Fn`'s and the `set`.
    try std.testing.expectEqual(@as(usize, 2), c.get);
    try std.testing.expectEqual(@as(usize, 2), c.set);
    const x = (try h.run(p, 4096)).ok;
    try std.testing.expectEqual(@as(i64, 6), x.get("V").?.integer);
}

test "rollback of shared locals: writes in failed regions are undone, from the frame and from closures" {
    const h = try harness.create();
    defer scratch.release(h);
    // R3: pure-core's example keeps its value with or without a closure that shares `X`.
    try expectInt(h, "F(N:i64)<transacts>:i64=Block{var X:i64=N;Held:i64=X;Attempt(Block{set X=X+1;Fail[\"undo\"];X},Set(X,X+7));Held+X}\nV:i64=F(3)", "V", 13);
    try expectInt(h, "F(N:i64)<transacts>:i64=Block{var X:i64=N;G:=Fn()<transacts>:void{Set(X,X)};Held:i64=X;Attempt(Block{set X=X+1;Fail[\"undo\"];X},Set(X,X+7));G();Held+X}\nV:i64=F(3)", "V", 13);
    // R1: a closure's write inside a region that fails.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts>:i64{Set(X,X+10)};A:=Attempt(Block{G();Require[X<5];X},-1);B:=Attempt(Block{G();Require[X>5];X},-1);A*100+B*10+X}\nV:i64=F()", "V", -100 + 110 + 11);
    // A failing visit of a `For` undoes its writes; the others stay.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;G:=Fn(K:i64)<transacts>:i64{Set(X,X+K)};Rs:=For(K:1..4,Block{G(K);Require[K!=3];K});X*10+Rs.Length}\nV:i64=F()", "V", 73);
    // `option{}` catches a failure and undoes what failed.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn()<transacts><decides>:i64{Block{set X=50;Require[false];X}};O:=option{G[]};If(O.IsSet,1,0)*1000+X}\nV:i64=F()", "V", 1);
    // R2: a cell made in a region that fails is forgotten with the closure stored then.
    try expectInt(h, "var Keep:option(function<transacts>(tuple(),i64))=option{}\nF()<transacts>:i64=Block{A:=Attempt(Block{var C:i64=5;G:=Fn()<transacts>:i64{Set(C,C+1)};set Keep=option{G};G();Require[false];0},-1);A+Attempt(Keep?(),0)}\nV:i64=F()", "V", -1);
    // Nested regions: the inner commits to the outer, which fails.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;G:=Fn(K:i64)<transacts>:i64{Set(X,X+K)};Attempt(Block{Attempt(Block{G(5);0},0);G(1);Require[X>100];0},0);Attempt(Block{Attempt(Block{G(7);0},0);G(2);0},0);X}\nV:i64=F()", "V", 9);
}

test "what sharing does not lift is refused as before" {
    const h = try harness.create();
    defer scratch.release(h);
    // An explicit capture is a value of the body.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn[Y:i64=X]()<transacts>:i64{Set(Y,2)};G()}\nV:i64=F()", .not_mutable, "Y");
    // A parameter the `Fn` declares, an immutable local, a parameter of the function around it.
    try refuses(h, "F()<transacts>:i64=Block{G:=Fn(Z:i64)<transacts>:i64{Set(Z,2)};G(1)}\nV:i64=F()", .not_mutable, "Z");
    try refuses(h, "F()<transacts>:i64=Block{X:=1;G:=Fn()<transacts>:i64{Set(X,2)};G()}\nV:i64=F()", .not_mutable, "X");
    try refuses(h, "F(P:i64)<transacts>:i64=Block{G:=Fn()<transacts>:i64{Set(P,2)};G()}\nV:i64=F(1)", .not_mutable, "P");
    try refuses(h, "F(P:i64)<transacts>:i64=Block{G:=Fn()<transacts>:i64{Block{set P=2;P}};G()}\nV:i64=F(1)", .not_mutable, "P");
    // Task bodies and arms share a local `var` from I5 (`shared_local_task_tests.zig`); what
    // they captured for a parameter or an immutable local stays a copy.
    try refuses(h, "F(X:i64)<transacts><suspends>:i64=Block{T:=Spawn{Set(X,2)};T.Await()}\nT:task(i64)=Spawn{F(1)}", .arm_assigns_local, "X");
    try refuses(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;G:=Fn()<transacts>:void{Set(X,3)};Y:i64=2;T:=Spawn{Block{G();Set(Y,X)}};T.Await()}\nT:task(i64)=Spawn{F()}", .arm_assigns_local, "Y");
}

test "a task body updates the instance a shared local holds, as without the share" {
    const h = try harness.create();
    defer scratch.release(h);
    // Second review: the field update reads the cell, so the task updates the instance the cell
    // holds when it runs (from I5 the statement also writes that instance back to the cell,
    // I5-D5). Here the creator has replaced the instance before the task runs again.
    const x = try h.execute(
        \\c := class{var V:i64=0}
        \\F()<transacts><suspends>:i64=Block{
        \\  var E:c=c{}
        \\  G:=Fn()<transacts>:void{Set(E,c{V:=1})}
        \\  T:=Spawn{Block{Sleep(1.0);set E.V=E.V+5;0}}
        \\  G()
        \\  T.Await()
        \\  E.V
        \\}
        \\T:task(i64)=Spawn{F()}
    );
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), "\"result\":6") == null) std.debug.print("{s}\n", .{out.buffered()});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":6") != null);
    // From I5 an assignment of the local there writes the cell: the creator reads the instance
    // the task put there.
    const y = try h.execute("c := class{var V:i64=0}\nF()<transacts><suspends>:i64=Block{var E:c=c{};G:=Fn()<transacts>:void{Set(E,c{V:=1})};T:=Spawn{Block{Sleep(1.0);set E=c{V:=40};0}};G();T.Await();E.V}\nT:task(i64)=Spawn{F()}");
    out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, y, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), "\"result\":40") == null) std.debug.print("{s}\n", .{out.buffered()});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":40") != null);
}

test "S6: a shared local is read with <reads> and written with <writes>" {
    const h = try harness.create();
    defer scratch.release(h);
    // Reading it in the function that declares it.
    try refuses(h, "F()<writes>:i64=Block{var X:i64=0;G:=Fn()<writes>:void{Set(X,1)};G();X}\nV:i64=F()", .local_read_requires_reads, "X");
    // Reading it in a closure.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<transacts>:void{Set(X,1)};R:=Fn()<writes>:i64{X+1};W();R()}\nV:i64=F()", .local_read_requires_reads, "X");
    // A compound assignment reads it.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<writes>:void{Block{set X+=1;0}};W();X}\nV:i64=F()", .local_read_requires_reads, "X");
    // Writing it.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<reads>:void{Set(X,1)};W();X}\nV:i64=F()", .set_requires_writes, "X");
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<transacts>:void{Set(X,1)};R:=Fn()<reads>:i64{Set(X,2)};W();R()}\nV:i64=F()", .set_requires_writes, "X");
    // Declaring it, as any local `var`.
    try refuses(h, "F()<reads>:i64=Block{var X:i64=0;0}\nV:i64=F()", .local_var_requires_writes, "X");
    // An `Fn` without an effect takes the function's, which reads.
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;W:=Fn(){Set(X,4)};R:=Fn(){X+1};W();R()}\nV:i64=F()", "V", 5);
    // A local no closure names stays free to read; one a closure names is shared since Q1
    // (I13), so that the closure and the function need `<reads>`, though nothing assigns it.
    try expectInt(h, "F()<writes>:i64=Block{var X:i64=2;R:=Fn()<computes>:i64{3};set X=5;R()+X}\nV:i64=F()", "V", 8);
    try refuses(h, "F()<writes>:i64=Block{var X:i64=2;R:=Fn()<computes>:i64{X+1};set X=5;R()+X}\nV:i64=F()", .local_read_requires_reads, "X");
    try expectInt(h, "F()<reads><writes>:i64=Block{var X:i64=2;R:=Fn()<reads>:i64{X+1};set X=5;R()+X}\nV:i64=F()", "V", 11);
}

test "a guard that calls a closure depends on the cell the closure reads" {
    const h = try harness.create();
    defer scratch.release(h);
    // The guard names no local; `R` reads the cell `W` shares, so `Y` follows it.
    const x = try h.execute("var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;R:=Fn()<reads>:i64{L};W:=Fn()<transacts>:void{Set(L,5)};set live Y=R()+1;A:=Y;W();A*100+Y}\nV:i64=F()");
    try std.testing.expectEqual(@as(i64, 206), x.get("V").?.integer);
    try std.testing.expect(x.live.propagations >= 1);
    // A write in a region that fails is undone, and the guard follows it back.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;R:=Fn()<reads>:i64{L};W:=Fn()<transacts>:void{Set(L,5)};set live Y=R()+1;Attempt(Block{W();Require[false];0},0);Y}\nV:i64=F()", "V", 2);
}

test "a guard names a local var through what a closure captured (Q10, replaced by S1b in I14)" {
    const h = try harness.create();
    defer scratch.release(h);
    // The snapshot case of RFC-0084 Q1 that `guard_local_var` missed, inside an `Fn`: I2 refused
    // it (`guard_capture_var`); since I14 the guard shares the local and follows its cell.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:i64{Block{set live Y=L+1;0}};set L=5;A:=G();set L=7;Y}\nV:i64=F()", "V", 8);
    // Shared or not, at any depth, and through a loop.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;W:=Fn()<transacts>:void{Set(L,2)};G:=Fn()<transacts>:i64{Block{set live Y=L+1;0}};A:=G();W();Y}\nV:i64=F()", "V", 3);
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:i64{Block{H:=Fn()<transacts>:i64{Block{set live Y=L;0}};H()}};A:=G();set L=4;Y}\nV:i64=F()", "V", 4);
    try expectInt(h, "var Y:i64=0\nF(Xs:[]i64)<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:i64{Block{For(X:Xs,Block{set live Y=L+X;0});0}};A:=G();set L=5;Y}\nV:i64=F(array{1})", "V", 6);
    // An `Fn` written in the capture list of another (review).
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;O:=Fn()<transacts>:i64{Block{P:=Fn[A:i64=(Fn()<transacts>:i64{Block{set live Y=L;0}})()]()<computes>:i64{A};P()}};B:=O();set L=3;Y}\nV:i64=F()", "V", 3);
    // A task body.
    try expectInt(h, "var Y:i64=0\nvar Seen:i64=0\nF()<transacts><suspends>:i64=Block{var L:i64=1;T:=Spawn{Block{set live Y=L;0}};A:=T.Await();set L=6;Set(Seen,Y)}\nT:task(i64)=Spawn{F()}\nV:i64=Seen", "V", 6);
    // A guard in a loop, a `Batch{}` or a `First` written in the function itself names no closure
    // of the program's: what it compiled to before Q10, it compiles to still.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;For(I:1..2,Block{set live Y=L+I;0});Y}\nV:i64=F()", "V", 3);
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;Batch{set live Y=L;0};Y}\nV:i64=F()", "V", 1);
    // An `Fn` in the capture list of another shares through both (review).
    try expectInt(h, "F()<transacts>:i64=Block{var X:i64=0;O:=Fn()<transacts>:i64{Block{P:=Fn[A:i64=(Fn()<transacts>:i64{Set(X,X+1)})()]()<computes>:i64{A};P()}};O();X}\nV:i64=F()", "V", 1);
    // A guard in a loop, a `First`, a `Loop{}` or a `Batch{}` of the declaring function names a
    // shared local as the function does: it was `guard_local_var` (second review), and since I14
    // the guard follows the cell.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:void{Set(L,10)};For(I:1..1,Block{set live Y=L+I;0});G();Y}\nV:i64=F()", "V", 11);
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:void{Set(L,10)};Batch{set live Y=L+1;0};G();Y}\nV:i64=F()", "V", 11);
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;G:=Fn()<transacts>:void{Set(L,10)};Loop{set live Y=L+1;Break()};G();Y}\nV:i64=F()", "V", 11);
    // And so does a guard on a shared local itself.
    try expectInt(h, "var Y:i64=0\nF()<transacts>:i64=Block{var L:i64=1;W:=Fn()<transacts>:void{Set(L,2)};set live Y=L+1;W();Y}\nV:i64=F()", "V", 3);
    // What a closure captured of an immutable local or a parameter is a value a guard may name.
    try expectInt(h, "var Y:i64=0\nF(P:i64)<transacts>:i64=Block{L:=1;G:=Fn()<transacts>:i64{Block{set live Y=L+P;Y}};G()}\nV:i64=F(4)", "V", 5);
}

// Shared locals in digest and off runs: the cells are reclaimed as instances are, both
// machines agree member for member, and the replayed report is the stored one.
test "shared locals report alike in every trace mode" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    const sources = [_][]const u8{
        "Step(S:i64)<transacts>:i64=Block{var C:i64=S;G:=Fn()<transacts>:i64{Set(C,C+1)};G();C}\nTotal<public>:i64=Iterate(Step,60,0)",
        "Counter:=tuple(function<reads>(tuple(),i64),function<transacts>(tuple(),void))\nMake(I:i64)<transacts>:Counter=Block{var C:i64=I;tuple{Fn()<reads>:i64{C},Fn()<transacts>:void{Set(C,C+1)}}}\nStep(S:Counter)<transacts>:Counter=Block{S(1)();Make(S(0)())}\nEnd<public>:Counter=Iterate(Step,40,Make(0))\nV<public>:i64=End(0)()",
        "var Keep:option(function<transacts>(tuple(),i64))=option{}\nStep(S:i64)<transacts>:i64=Block{var C:i64=S;G:=Fn()<transacts>:i64{Set(C,C+1)};A:=Attempt(Block{set Keep=option{G};G();Require[S<20];0},-1);S+1+A-A}\nTotal<public>:i64=Iterate(Step,30,0)\nBack<public>:i64=Attempt(Keep?(),0)",
        // A guard that depends on a cell through a closure, visit after visit.
        "var Y:i64=0\nStep(S:i64)<transacts>:i64=Block{var L:i64=S;R:=Fn()<reads>:i64{L};W:=Fn()<transacts>:void{Set(L,L+2)};set live Y=R()+1;W();Y}\nTotal<public>:i64=Iterate(Step,40,0)",
    };
    for (sources) |source| {
        const p = try f.h.compile(source);
        try std.testing.expect(census(p).ref_type);
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.h.run(p, replay.fuel)).ok;
        var out = std.Io.Writer.fixed(stored_text);
        _ = try reporting.write(&out, stored, false, .{ .work = 1 << 24 });
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = out.buffered();
        var reclaiming = false;
        for ([_]u32{ 0, 1, 5 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
            configure(f, .digest, window, floor);
            const runs = try both(f, p);
            if (runs.actual.reclaims != 0) reclaiming = true;
            try std.testing.expectEqualStrings(expected, try replayed(f, runs.actual, p, other));
            try std.testing.expectEqualStrings(expected, try replayed(f, runs.reference, p, other));
        };
        try std.testing.expect(reclaiming);
        configure(f, .off, 5, 0);
        _ = try both(f, p);
    }
}

fn configure(f: replay.Fixture, trace: types.TraceMode, window: u32, floor: u32) void {
    f.mode(trace, window);
    f.h.control.reclaim_floor = floor;
    f.h.runtime.machine.control.reclaim_floor = floor;
    f.again.control.trace_window = window;
    f.again.control.reclaim_floor = floor;
}
const Pair = struct { reference: evaluator.Execution, actual: evaluator.Execution };
fn both(f: replay.Fixture, p: types.Program) !Pair {
    const h = f.h;
    const expected = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, replay.fuel);
    const actual = h.runtime.evaluate(p, replay.fuel);
    try std.testing.expect(expected == .ok and actual == .ok);
    const a = expected.ok;
    const b = actual.ok;
    try std.testing.expectEqualSlices(bool, a.activity, b.activity);
    for (a.values, b.values, 0..) |x, y, index| if (b.active(index)) try replay.same(x, y);
    try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
    for (a.aggregate_values, b.aggregate_values) |x, y| try replay.same(x, y);
    try std.testing.expectEqual(a.object_cells.len, b.object_cells.len);
    for (a.object_cells, b.object_cells) |x, y| try replay.same(x.value, y.value);
    try std.testing.expectEqual(a.trace, b.trace);
    try std.testing.expectEqualDeep(a.witness, b.witness);
    try std.testing.expectEqual(a.reclaims, b.reclaims);
    try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
    return .{ .reference = a, .actual = b };
}
fn replayed(f: replay.Fixture, x: evaluator.Execution, p: types.Program, into: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(into);
    _ = try reporting.writeReplayed(&out, x, f.again.producer(p, replay.fuel), false, .{ .work = 1 << 24 });
    try trace_report.writeReplayed(&out, x, f.again.producer(p, replay.fuel), "test.forb", .{});
    return out.buffered();
}

// ---- The randomised oracle (RFC-0085, "Randomised oracle", over `Fn` only for I2).
//
// A program is one function `Run`: `var` locals, then statements among which `Fn`s are built,
// each assigning some locals and reading one. A local some `Fn` assigns is shared (S1d) and
// every closure refers to it; one no `Fn` assigns is read by a closure as it was when the
// closure was built (RFC-0054). Statements assign locals directly, call closures, call one in
// an `Attempt` that fails past a bound, and loop over a local and a closure with visits that
// fail. The model below is a plain interpreter of exactly that.
//
// RFC-0085, I13 (Q1): every local an `Fn` or nested function names is shared, so a closure
// always reads the variable. With `names_share` false the model is the one of I2 to I14, before
// Q1, and the compiler runs with `Workspace.share_names` off: a local is shared only when a
// closure assigns it (or a nested function names it), and a closure reads any other as it was
// when the closure was built. Both are tested.

const max_vars = 4;
const max_fns = 4;
const max_statements = 12;
const Assign = struct { v: u8, c: i64 };
const Closure = struct {
    assigns: [3]Assign = undefined,
    count: u8 = 0,
    read: u8 = 0,
    plus: i64 = 0,
    /// RFC-0085, I3: a nested function rather than an `Fn`, and the earlier closure it calls
    /// before its read (`no_call` for none).
    nested: bool = false,
    calls: u8 = no_call,
};
const no_call = std.math.maxInt(u8);
const Statement = union(enum) {
    build: u8,
    set: Assign,
    call: u8,
    attempt: struct { f: u8, limit: i64 },
    loop: struct { v: u8, f: u8, visits: u8, limit: ?i64 },
};
const Model = struct {
    vars: u8,
    initial: [max_vars]i64,
    fns: u8,
    closures: [max_fns]Closure,
    statements: [max_statements + max_fns]Statement,
    statement_count: u8,
    /// Q1 (I13): a local any closure names is shared.
    names_share: bool,

    fn shared(self: *const Model, v: u8) bool {
        for (self.closures[0..self.fns]) |closure| for (closure.assigns[0..closure.count]) |a| if (a.v == v) return true;
        if (self.names_share) for (self.closures[0..self.fns]) |closure| if (closure.read == v) return true;
        // S1a: every local `var` a nested function names.
        for (self.closures[0..self.fns]) |closure| if (closure.nested and closure.read == v) return true;
        return false;
    }
    fn anyShared(self: *const Model) bool {
        for (0..self.vars) |v| if (self.shared(@intCast(v))) return true;
        return false;
    }

    fn generate(random: std.Random, names_share: bool) Model {
        return generateWith(random, false, names_share);
    }
    /// With `nested`, some closures are nested functions, and some call an earlier closure.
    fn generateWith(random: std.Random, nested: bool, names_share: bool) Model {
        var m: Model = undefined;
        m.names_share = names_share;
        m.vars = 1 + random.uintLessThan(u8, max_vars);
        for (m.initial[0..m.vars]) |*value| value.* = random.intRangeAtMost(i64, -5, 9);
        m.fns = 1 + random.uintLessThan(u8, max_fns);
        for (m.closures[0..m.fns]) |*closure| {
            closure.* = .{};
            // Some only read.
            closure.count = random.uintLessThan(u8, 3);
            for (closure.assigns[0..closure.count]) |*a| a.* = .{ .v = random.uintLessThan(u8, m.vars), .c = random.intRangeAtMost(i64, -3, 7) };
            closure.read = random.uintLessThan(u8, m.vars);
            closure.plus = random.intRangeAtMost(i64, 0, 5);
        }
        if (nested) for (m.closures[0..m.fns], 0..) |*closure, f| {
            closure.nested = random.boolean();
            if (f != 0 and random.uintLessThan(u8, 3) == 0) closure.calls = random.uintLessThan(u8, @intCast(f));
        };
        m.statement_count = 0;
        var built: u8 = 0;
        const total = 3 + random.uintLessThan(u8, max_statements - 2);
        for (0..total) |_| {
            // Closures are built in order, so a statement can call only those built before it.
            if (built < m.fns and (built == 0 or random.uintLessThan(u8, 3) == 0)) {
                m.statements[m.statement_count] = .{ .build = built };
                m.statement_count += 1;
                built += 1;
            }
            const f = random.uintLessThan(u8, built);
            const v = random.uintLessThan(u8, m.vars);
            m.statements[m.statement_count] = switch (random.uintLessThan(u8, 4)) {
                0 => .{ .set = .{ .v = v, .c = random.intRangeAtMost(i64, -4, 8) } },
                1 => .{ .call = f },
                2 => .{ .attempt = .{ .f = f, .limit = random.intRangeAtMost(i64, -2, 20) } },
                else => .{ .loop = .{ .v = v, .f = f, .visits = 1 + random.uintLessThan(u8, 3), .limit = if (random.boolean()) random.intRangeAtMost(i64, 0, 25) else null } },
            };
            m.statement_count += 1;
        }
        // Closures never built assign nothing anyone sees, and share nothing.
        m.fns = built;
        return m;
    }

    fn write(self: *const Model, out: *std.Io.Writer) !void {
        try out.writeAll("Run()<transacts>:[]i64=Block{\n");
        for (self.initial[0..self.vars], 0..) |value, v| try out.print("var V{d}:i64={d}\n", .{ v, value });
        try out.writeAll("var Acc:i64=0\n");
        for (self.statements[0..self.statement_count]) |s| switch (s) {
            .build => |f| {
                const closure = self.closures[f];
                if (closure.nested) try out.print("F{d}()<transacts>:i64=Block{{", .{f}) else try out.print("F{d}:=Fn()<transacts>:i64{{Block{{", .{f});
                for (closure.assigns[0..closure.count]) |a| try out.print("set V{d}=V{d}+{d};", .{ a.v, a.v, a.c });
                if (closure.calls != no_call) try out.print("K{d}:=F{d}();", .{ f, closure.calls });
                try out.print("V{d}+{d}", .{ closure.read, closure.plus });
                if (closure.calls != no_call) try out.print("+K{d}", .{f});
                if (closure.nested) try out.writeAll("}\n") else try out.writeAll("}}\n");
            },
            .set => |a| try out.print("set V{d}=V{d}+{d}\n", .{ a.v, a.v, a.c }),
            .call => |f| try out.print("set Acc=Acc+F{d}()\n", .{f}),
            .attempt => |a| try out.print("set Acc=Acc+Attempt(Block{{A:=F{d}();Require[A<{d}];A}},-1)\n", .{ a.f, a.limit }),
            .loop => |l| if (l.limit) |limit|
                try out.print("For(I:1..{d},Block{{set V{d}=V{d}+I;R:=F{d}();Require[R<{d}];R}})\n", .{ l.visits, l.v, l.v, l.f, limit })
            else
                try out.print("For(I:1..{d},Block{{set V{d}=V{d}+I;F{d}()}})\n", .{ l.visits, l.v, l.v, l.f }),
        };
        try out.writeAll("array{Acc");
        for (0..self.vars) |v| try out.print(",V{d}", .{v});
        try out.writeAll("}}\nOut:[]i64=Run()");
    }

    const State = struct { vars: [max_vars]i64, snapshots: [max_fns][max_vars]i64 };
    fn call(self: *const Model, state: *State, f: u8) i64 {
        const closure = self.closures[f];
        for (closure.assigns[0..closure.count]) |a| state.vars[a.v] += a.c;
        const called = if (closure.calls != no_call) self.call(state, closure.calls) else 0;
        const read = if (self.shared(closure.read)) state.vars[closure.read] else state.snapshots[f][closure.read];
        return read + closure.plus + called;
    }
    /// What `Run()` yields: `Acc` and the locals.
    fn run(self: *const Model, into: []i64) void {
        var state: State = .{ .vars = undefined, .snapshots = undefined };
        @memcpy(state.vars[0..self.vars], self.initial[0..self.vars]);
        var acc: i64 = 0;
        for (self.statements[0..self.statement_count]) |s| switch (s) {
            .build => |f| state.snapshots[f] = state.vars,
            .set => |a| state.vars[a.v] += a.c,
            .call => |f| acc += self.call(&state, f),
            .attempt => |a| {
                const saved = state.vars;
                const r = self.call(&state, a.f);
                if (r < a.limit) acc += r else {
                    state.vars = saved;
                    acc -= 1;
                }
            },
            .loop => |l| for (1..@as(usize, l.visits) + 1) |visit| {
                const saved = state.vars;
                state.vars[l.v] += @intCast(visit);
                const r = self.call(&state, l.f);
                if (l.limit) |limit| if (r >= limit) {
                    state.vars = saved;
                };
            },
        };
        into[0] = acc;
        @memcpy(into[1 .. 1 + self.vars], state.vars[0..self.vars]);
    }
};

test "randomised oracle: Fn closures over shared and unshared locals agree with the model in both machines" {
    // Q1 (I13), and the rules before it with the switch off.
    try fnOracle(true);
    try fnOracle(false);
}
fn fnOracle(names_share: bool) !void {
    const f = try replay.Fixture.create();
    defer f.destroy();
    f.h.front.share_names = names_share;
    var prng = std.Random.DefaultPrng.init(0x0085_0002);
    var text: [4096]u8 = undefined;
    var shares: usize = 0;
    var snapshots: usize = 0;
    for (0..400) |seed| {
        const m = Model.generate(prng.random(), names_share);
        var out = std.Io.Writer.fixed(&text);
        try m.write(&out);
        const source = out.buffered();
        var expected: [1 + max_vars]i64 = undefined;
        m.run(&expected);
        for (0..m.vars) |v| {
            if (m.shared(@intCast(v))) shares += 1 else snapshots += 1;
        }
        // The runs alternate between the three trace modes; digest and off runs reclaim.
        const mode: types.TraceMode = switch (seed % 3) {
            0 => .full,
            1 => .digest,
            else => .off,
        };
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const p = f.h.compile(source) catch |problem| {
            std.debug.print("seed {d}:\n{s}\n", .{ seed, source });
            return problem;
        };
        try std.testing.expectEqual(m.anyShared(), census(p).ref_type);
        const x = if (mode == .full) (try f.h.run(p, replay.fuel)).ok else blk: {
            configure(f, mode, 2, 0);
            break :blk (try both(f, p)).actual;
        };
        const values = x.elements(x.get("Out").?).?;
        try std.testing.expectEqual(@as(usize, 1 + m.vars), values.len);
        for (values, expected[0 .. 1 + m.vars]) |actual, wanted| if (actual.integer != wanted) {
            std.debug.print("seed {d}, mode {s}: got", .{ seed, @tagName(mode) });
            for (values) |value| std.debug.print(" {d}", .{value.integer});
            std.debug.print(", model", .{});
            for (expected[0 .. 1 + m.vars]) |value| std.debug.print(" {d}", .{value});
            std.debug.print("\n{s}\n", .{source});
            return error.ModelDisagrees;
        };
    }
    // The generator reaches both kinds of local: locals a closure shares, and locals no closure
    // names, which stay plain locals under Q1 (and snapshots before it).
    try std.testing.expect(shares > 100 and snapshots > 20);
}

// RFC-0085, I3: the oracle with nested functions. A nested function shares every local it
// names (S1a), and an `Fn` or nested function that calls one carries its captures.
test "randomised oracle: nested functions and Fn closures agree with the model in both machines" {
    try nestedOracle(true);
    try nestedOracle(false);
}
fn nestedOracle(names_share: bool) !void {
    const f = try replay.Fixture.create();
    defer f.destroy();
    f.h.front.share_names = names_share;
    var prng = std.Random.DefaultPrng.init(0x0085_0003);
    var text: [4096]u8 = undefined;
    var nested_fns: usize = 0;
    var calls: usize = 0;
    var snapshots: usize = 0;
    for (0..400) |seed| {
        const m = Model.generateWith(prng.random(), true, names_share);
        var out = std.Io.Writer.fixed(&text);
        try m.write(&out);
        const source = out.buffered();
        var expected: [1 + max_vars]i64 = undefined;
        m.run(&expected);
        for (m.closures[0..m.fns]) |closure| {
            if (closure.nested) nested_fns += 1;
            if (closure.calls != no_call) calls += 1;
        }
        for (0..m.vars) |v| {
            if (!m.shared(@intCast(v))) snapshots += 1;
        }
        const mode: types.TraceMode = switch (seed % 3) {
            0 => .full,
            1 => .digest,
            else => .off,
        };
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const p = f.h.compile(source) catch |problem| {
            std.debug.print("seed {d}:\n{s}\n", .{ seed, source });
            return problem;
        };
        try std.testing.expectEqual(m.anyShared(), census(p).ref_type);
        const x = if (mode == .full) (try f.h.run(p, replay.fuel)).ok else blk: {
            configure(f, mode, 2, 0);
            break :blk (try both(f, p)).actual;
        };
        const values = x.elements(x.get("Out").?).?;
        try std.testing.expectEqual(@as(usize, 1 + m.vars), values.len);
        for (values, expected[0 .. 1 + m.vars]) |actual, wanted| if (actual.integer != wanted) {
            std.debug.print("seed {d}, mode {s}: got", .{ seed, @tagName(mode) });
            for (values) |value| std.debug.print(" {d}", .{value.integer});
            std.debug.print(", model", .{});
            for (expected[0 .. 1 + m.vars]) |value| std.debug.print(" {d}", .{value});
            std.debug.print("\n{s}\n", .{source});
            return error.ModelDisagrees;
        };
    }
    // The generator reaches nested functions, calls between closures, and snapshots still.
    try std.testing.expect(nested_fns > 200 and calls > 100 and snapshots > 20);
}

test "an Fn in a Defer body shares a local, also in the landing a cancellation runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Run()<transacts><suspends>:i64=Block{
        \\  var X:i64=0
        \\  W:=Race(Block{Defer{G:=Fn()<transacts>:void{Set(X,X+10)};G()};Sleep(5.0);1},Block{Sleep(1.0);2})
        \\  W*100+X
        \\}
        \\T:task(i64)=Spawn{Run()}
    ;
    // The same program with a module `var` in place of the local shares nothing.
    var twin_text: [512]u8 = undefined;
    var twin = std.Io.Writer.fixed(&twin_text);
    try twin.writeAll("var M:i64=0\n");
    const set_at = std.mem.indexOf(u8, source, "Set(X,X+10)").?;
    try twin.print("{s}Set(M,M+10){s}", .{ source[0..set_at], source[set_at + "Set(X,X+10)".len ..] });
    _ = try h.compile(twin.buffered());
    const twin_passes = h.front.passes;
    const x = try h.execute(source);
    try std.testing.expect(census(x.program).ref_type);
    // The share is noted in the compile that also finds the landing: the two come together.
    if (h.front.passes > twin_passes + 1) std.debug.print("{d} passes against {d}\n", .{ h.front.passes, twin_passes });
    try std.testing.expect(h.front.passes <= twin_passes + 1);
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), "\"result\":210") == null) std.debug.print("{d} passes: {s}\n", .{ h.front.passes, out.buffered() });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"result\":210") != null);
}

// ---- RFC-0085, I5: the oracle with tasks.
//
// A program is one suspending function `Run`: `var` locals, then statements of its own that
// assign them, `Spawn` a task, `Sleep`, `Await` a task, run a `Sync` of two arms or a `Batch{}`.
// Each body and arm assigns some locals before and after one `Sleep`, then yields a local plus a
// constant. A local that a body, an arm or a `Batch{}` assigns is shared (S1d) and every closure
// refers to its cell; one nothing assigns is read by a body as it was when the body was built.
// Since I13 (Q1) a local a body or an arm only reads is shared too (`names_share`); the model of
// the rules before it runs with `Workspace.share_names` off.
// The model is a plain interpreter of exactly that under RFC-0082's scheduler: hand-off at a
// `Spawn` and at each arm's start, a FIFO ready queue, timers in deadline and registration order.

const max_bodies = 6;
const max_task_statements = 10;
const Body = struct {
    pre: [2]Assign = undefined,
    pre_count: u8 = 0,
    sleep: u8 = 1,
    post: [2]Assign = undefined,
    post_count: u8 = 0,
    read: u8 = 0,
    plus: i64 = 0,
};
const TaskStatement = union(enum) {
    set: Assign,
    spawn: u8,
    sleep: u8,
    await_task: u8,
    sync: [2]u8,
    batch: Assign,
};
const TaskModel = struct {
    vars: u8,
    initial: [max_vars]i64,
    bodies: [max_bodies]Body,
    body_count: u8,
    statements: [max_task_statements]TaskStatement,
    statement_count: u8,
    /// Q1 (I13): a local any body or arm names is shared, not only one it assigns.
    names_share: bool,

    fn shared(self: *const TaskModel, v: u8) bool {
        for (self.bodies[0..self.body_count]) |body| {
            if (self.names_share and body.read == v) return true;
            for (body.pre[0..body.pre_count]) |a| if (a.v == v) return true;
            for (body.post[0..body.post_count]) |a| if (a.v == v) return true;
        }
        for (self.statements[0..self.statement_count]) |s| if (s == .batch and s.batch.v == v) return true;
        return false;
    }
    fn anyShared(self: *const TaskModel) bool {
        for (0..self.vars) |v| if (self.shared(@intCast(v))) return true;
        return false;
    }

    fn generate(random: std.Random, names_share: bool) TaskModel {
        var m: TaskModel = undefined;
        m.names_share = names_share;
        m.vars = 1 + random.uintLessThan(u8, max_vars);
        for (m.initial[0..m.vars]) |*value| value.* = random.intRangeAtMost(i64, -5, 9);
        m.body_count = 0;
        m.statement_count = 0;
        var spawned: [max_bodies]u8 = undefined;
        var spawn_count: u8 = 0;
        var synced = false;
        const total = 3 + random.uintLessThan(u8, max_task_statements - 3);
        for (0..total) |_| {
            const kind = random.uintLessThan(u8, 6);
            const v = random.uintLessThan(u8, m.vars);
            m.statements[m.statement_count] = switch (kind) {
                0 => .{ .set = .{ .v = v, .c = random.intRangeAtMost(i64, -4, 8) } },
                1 => if (m.body_count < max_bodies - 2) spawn: {
                    spawned[spawn_count] = m.body_count;
                    spawn_count += 1;
                    break :spawn .{ .spawn = m.newBody(random) };
                } else .{ .set = .{ .v = v, .c = 1 } },
                2 => .{ .sleep = 1 + random.uintLessThan(u8, 3) },
                3 => if (spawn_count != 0) .{ .await_task = spawned[random.uintLessThan(u8, spawn_count)] } else .{ .sleep = 1 },
                4 => if (!synced) sync: {
                    synced = true;
                    const a = m.newBody(random);
                    break :sync .{ .sync = .{ a, m.newBody(random) } };
                } else .{ .set = .{ .v = v, .c = 2 } },
                else => .{ .batch = .{ .v = v, .c = random.intRangeAtMost(i64, -3, 6) } },
            };
            m.statement_count += 1;
        }
        return m;
    }
    fn newBody(self: *TaskModel, random: std.Random) u8 {
        const body = &self.bodies[self.body_count];
        body.* = .{};
        // Some only read.
        body.pre_count = random.uintLessThan(u8, 2);
        for (body.pre[0..body.pre_count]) |*a| a.* = .{ .v = random.uintLessThan(u8, self.vars), .c = random.intRangeAtMost(i64, -3, 7) };
        body.sleep = 1 + random.uintLessThan(u8, 3);
        body.post_count = random.uintLessThan(u8, 3);
        for (body.post[0..body.post_count]) |*a| a.* = .{ .v = random.uintLessThan(u8, self.vars), .c = random.intRangeAtMost(i64, -3, 7) };
        body.read = random.uintLessThan(u8, self.vars);
        body.plus = random.intRangeAtMost(i64, 0, 5);
        self.body_count += 1;
        return self.body_count - 1;
    }

    fn writeBody(self: *const TaskModel, out: *std.Io.Writer, b: u8) !void {
        const body = self.bodies[b];
        for (body.pre[0..body.pre_count]) |a| try out.print("set V{d}=V{d}+{d};", .{ a.v, a.v, a.c });
        try out.print("Sleep({d}.0);", .{body.sleep});
        for (body.post[0..body.post_count]) |a| try out.print("set V{d}=V{d}+{d};", .{ a.v, a.v, a.c });
        try out.print("V{d}+{d}", .{ body.read, body.plus });
    }
    fn write(self: *const TaskModel, out: *std.Io.Writer) !void {
        try out.writeAll("var Out:[]i64=array{}\nRun()<transacts><suspends>:i64=Block{\n");
        for (self.initial[0..self.vars], 0..) |value, v| try out.print("var V{d}:i64={d}\n", .{ v, value });
        try out.writeAll("var Acc:i64=0\n");
        for (self.statements[0..self.statement_count], 0..) |s, index| switch (s) {
            .set => |a| try out.print("set V{d}=V{d}+{d}\n", .{ a.v, a.v, a.c }),
            .spawn => |b| {
                try out.print("T{d}:=Spawn{{", .{b});
                try self.writeBody(out, b);
                try out.writeAll("}\n");
            },
            .sleep => |d| try out.print("Sleep({d}.0)\n", .{d}),
            .await_task => |b| try out.print("set Acc=Acc*3+T{d}.Await()\n", .{b}),
            .sync => |arms| {
                try out.print("S{d}:=Sync(Block{{", .{index});
                try self.writeBody(out, arms[0]);
                try out.writeAll("},Block{");
                try self.writeBody(out, arms[1]);
                try out.print("}})\nset Acc=Acc*5+S{d}(0)*2+S{d}(1)\n", .{ index, index });
            },
            .batch => |a| try out.print("B{d}:i64=Batch{{set V{d}=V{d}+{d};V{d}}}\nset Acc=Acc+B{d}\n", .{ index, a.v, a.v, a.c, a.v, index }),
        };
        try out.writeAll("set Out=array{Acc");
        for (0..self.vars) |v| try out.print(",V{d}", .{v});
        try out.writeAll("}\n0}\nP:task(i64)=Spawn{Run()}");
    }

    /// The run under the scheduler: task 0 is `Run`, task `1 + b` runs body `b`.
    const Wait = enum { none, timer, task, record, done };
    const Task = struct { phase: u8 = 0, wait: Wait = .none, deadline: u64 = 0, registration: u64 = 0, target: u8 = 0, result: i64 = 0, snapshot: [max_vars]i64 = undefined };
    const Run = struct {
        model: *const TaskModel,
        vars: [max_vars]i64,
        acc: i64 = 0,
        pc: u8 = 0,
        tasks: [1 + max_bodies]Task = @splat(.{}),
        /// The arms of the `Sync` the creator waits on still running.
        open_arms: u8 = 0,
        sync_arms: [2]u8 = undefined,
        ready: [64]u8 = undefined,
        ready_head: usize = 0,
        ready_tail: usize = 0,
        now: u64 = 0,
        registrations: u64 = 0,
        out: ?[1 + max_vars]i64 = null,

        fn push(self: *Run, task: u8) void {
            self.ready[self.ready_tail] = task;
            self.ready_tail += 1;
        }
        fn sleep(self: *Run, task: u8, seconds: u8) void {
            self.registrations += 1;
            self.tasks[task].wait = .timer;
            self.tasks[task].deadline = self.now + seconds;
            self.tasks[task].registration = self.registrations;
        }
        fn read(self: *const Run, b: u8, v: u8) i64 {
            return if (self.model.shared(v)) self.vars[v] else self.tasks[1 + b].snapshot[v];
        }
        /// Runs body `b` from where it stands until its `Sleep` or its end.
        fn body(self: *Run, b: u8) void {
            const task = 1 + b;
            const shape = self.model.bodies[b];
            if (self.tasks[task].phase == 0) {
                for (shape.pre[0..shape.pre_count]) |a| self.vars[a.v] += a.c;
                self.tasks[task].phase = 1;
                self.sleep(task, shape.sleep);
                return;
            }
            for (shape.post[0..shape.post_count]) |a| self.vars[a.v] += a.c;
            self.tasks[task].result = self.read(b, shape.read) + shape.plus;
            self.tasks[task].wait = .done;
            // Its awaiter, or the record it is an arm of.
            if (self.tasks[0].wait == .task and self.tasks[0].target == b) self.push(0);
            if (self.tasks[0].wait == .record and (self.sync_arms[0] == b or self.sync_arms[1] == b)) {
                self.open_arms -= 1;
                if (self.open_arms == 0) self.push(0);
            }
        }
        fn start(self: *Run, b: u8) void {
            self.tasks[1 + b].snapshot = self.vars;
            self.body(b);
        }
        /// Runs `Run` from where it stands until it waits or ends.
        fn creator(self: *Run) void {
            const m = self.model;
            // Resumed from a wait: what it waited for.
            switch (self.tasks[0].wait) {
                .task => self.acc = self.acc * 3 + self.tasks[1 + self.tasks[0].target].result,
                .record => self.acc = self.acc * 5 + self.tasks[1 + self.sync_arms[0]].result * 2 + self.tasks[1 + self.sync_arms[1]].result,
                else => {},
            }
            self.tasks[0].wait = .none;
            while (self.pc < m.statement_count) {
                const s = m.statements[self.pc];
                self.pc += 1;
                switch (s) {
                    .set => |a| self.vars[a.v] += a.c,
                    .spawn => |b| self.start(b),
                    .sleep => |d| {
                        self.sleep(0, d);
                        return;
                    },
                    .await_task => |b| {
                        if (self.tasks[1 + b].wait == .done) {
                            self.acc = self.acc * 3 + self.tasks[1 + b].result;
                        } else {
                            self.tasks[0].wait = .task;
                            self.tasks[0].target = b;
                            return;
                        }
                    },
                    .sync => |arms| {
                        // Both are built where the `Sync` stands; each runs to its `Sleep`.
                        self.tasks[1 + arms[0]].snapshot = self.vars;
                        self.tasks[1 + arms[1]].snapshot = self.vars;
                        self.sync_arms = arms;
                        self.body(arms[0]);
                        self.body(arms[1]);
                        self.open_arms = 2;
                        self.tasks[0].wait = .record;
                        return;
                    },
                    .batch => |a| {
                        self.vars[a.v] += a.c;
                        self.acc += self.vars[a.v];
                    },
                }
            }
            var out: [1 + max_vars]i64 = undefined;
            out[0] = self.acc;
            @memcpy(out[1 .. 1 + m.vars], self.vars[0..m.vars]);
            self.out = out;
            self.tasks[0].wait = .done;
        }
        fn wake(self: *Run, task: u8) void {
            if (task == 0) self.creator() else {
                self.tasks[task].wait = .none;
                self.body(task - 1);
            }
        }
    };
    /// What `Out` holds at the end: `Acc` and the locals.
    fn run(self: *const TaskModel, into: []i64) void {
        var r: Run = .{ .model = self, .vars = undefined };
        @memcpy(r.vars[0..self.vars], self.initial[0..self.vars]);
        // The root spawns `Run`, which runs at once to its first wait.
        r.creator();
        while (true) {
            if (r.ready_head < r.ready_tail) {
                const task = r.ready[r.ready_head];
                r.ready_head += 1;
                r.wake(task);
                continue;
            }
            // The earliest deadline, then every timer due then, in registration order.
            var earliest: ?u64 = null;
            for (r.tasks[0 .. 1 + self.body_count]) |t| if (t.wait == .timer) {
                earliest = if (earliest) |e| @min(e, t.deadline) else t.deadline;
            };
            const due = earliest orelse break;
            r.now = due;
            while (true) {
                var next: ?u8 = null;
                for (r.tasks[0 .. 1 + self.body_count], 0..) |t, index| if (t.wait == .timer and t.deadline == due) {
                    if (next == null or t.registration < r.tasks[next.?].registration) next = @intCast(index);
                };
                const task = next orelse break;
                // Woken: it is ready, not waiting.
                r.tasks[task].wait = .none;
                r.push(task);
            }
        }
        @memcpy(into[0 .. 1 + self.vars], r.out.?[0 .. 1 + self.vars]);
    }
};

test "randomised oracle: task bodies, Sync arms and Batch bodies over shared and unshared locals agree with the model" {
    try taskOracle(true);
    try taskOracle(false);
}
fn taskOracle(names_share: bool) !void {
    const f = try replay.Fixture.create();
    defer f.destroy();
    f.h.front.share_names = names_share;
    var prng = std.Random.DefaultPrng.init(0x0085_0005);
    var text: [8192]u8 = undefined;
    var shares: usize = 0;
    var snapshots: usize = 0;
    var spawns: usize = 0;
    var syncs: usize = 0;
    for (0..400) |seed| {
        const m = TaskModel.generate(prng.random(), names_share);
        var out = std.Io.Writer.fixed(&text);
        try m.write(&out);
        const source = out.buffered();
        var expected: [1 + max_vars]i64 = undefined;
        m.run(&expected);
        for (0..m.vars) |v| {
            if (m.shared(@intCast(v))) shares += 1 else snapshots += 1;
        }
        for (m.statements[0..m.statement_count]) |s| switch (s) {
            .spawn => spawns += 1,
            .sync => syncs += 1,
            else => {},
        };
        const mode: types.TraceMode = switch (seed % 3) {
            0 => .full,
            1 => .digest,
            else => .off,
        };
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const p = f.h.compile(source) catch |problem| {
            std.debug.print("seed {d}:\n{s}\n", .{ seed, source });
            return problem;
        };
        try std.testing.expectEqual(m.anyShared(), census(p).ref_type);
        const x = if (mode == .full) (try f.h.run(p, replay.fuel)).ok else blk: {
            configure(f, mode, 2, 0);
            break :blk (try both(f, p)).actual;
        };
        // `Out` is the program's first cell.
        try std.testing.expect(x.cells.len >= 1 and x.cells[0].initialized);
        const values = x.elements(x.cells[0].value).?;
        try std.testing.expectEqual(@as(usize, 1 + m.vars), values.len);
        for (values, expected[0 .. 1 + m.vars]) |actual, wanted| if (actual.integer != wanted) {
            std.debug.print("seed {d}, mode {s}: got", .{ seed, @tagName(mode) });
            for (values) |value| std.debug.print(" {d}", .{value.integer});
            std.debug.print(", model", .{});
            for (expected[0 .. 1 + m.vars]) |value| std.debug.print(" {d}", .{value});
            std.debug.print("\n{s}\n", .{source});
            return error.ModelDisagrees;
        };
    }
    // The generator reaches both kinds of local, tasks and arms.
    try std.testing.expect(shares > 100 and snapshots > 20 and spawns > 200 and syncs > 100);
}

test "shared locals of tasks report alike in every trace mode" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    const sources = [_][]const u8{
        // Each visit makes a cell a task writes across its sleep.
        "Step(S:i64)<transacts><suspends>:i64=Block{var C:i64=S;T:=Spawn{Sleep(1.0);Set(C,C+1)};T.Await();C}\nRun()<transacts><suspends>:i64=Block{var I:i64=0;var A:i64=0;Loop{If(I>=30,Break(),false);set A=A+Step(I);set I=I+1};A}\nP<public>:task(i64)=Spawn{Run()}",
        // The creator returns first; the closure it hands on reads the task's write.
        "Make(S:i64)<transacts><suspends>:function<reads>(tuple(),i64)=Block{var C:i64=S;T:=Spawn{Sleep(2.0);Set(C,C+10)};Fn()<reads>:i64{C}}\nRun()<transacts><suspends>:i64=Block{var I:i64=0;var A:i64=0;Loop{If(I>=20,Break(),false);R:=Make(I);Sleep(3.0);set A=A+R();set I=I+1};A}\nP<public>:task(i64)=Spawn{Run()}",
        // Arms write one cell; a landing writes another.
        "Step(S:i64)<transacts><suspends>:i64=Block{var C:i64=S;var D:i64=0;R:=Sync(Block{Sleep(1.0);Set(C,C+1)},Block{Sleep(2.0);Set(C,C*2)});W:=Race(Block{Defer{set D=D+5};Sleep(5.0);1},Block{Sleep(1.0);2});C+D+W}\nRun()<transacts><suspends>:i64=Block{var I:i64=0;var A:i64=0;Loop{If(I>=15,Break(),false);set A=A+Step(I);set I=I+1};A}\nP<public>:task(i64)=Spawn{Run()}",
    };
    for (sources) |source| {
        const p = try f.h.compile(source);
        try std.testing.expect(census(p).ref_type);
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.h.run(p, replay.fuel)).ok;
        var out = std.Io.Writer.fixed(stored_text);
        _ = try reporting.write(&out, stored, false, .{ .work = 1 << 24 });
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = out.buffered();
        var reclaiming = false;
        for ([_]u32{ 0, 1, 5 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
            configure(f, .digest, window, floor);
            const runs = try both(f, p);
            if (runs.actual.reclaims != 0) reclaiming = true;
            try std.testing.expectEqualStrings(expected, try replayed(f, runs.actual, p, other));
            try std.testing.expectEqualStrings(expected, try replayed(f, runs.reference, p, other));
        };
        try std.testing.expect(reclaiming);
        configure(f, .off, 5, 0);
        _ = try both(f, p);
    }
}
