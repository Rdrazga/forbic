//! Shared locals in tasks, RFC-0085 I5: a task body (`Spawn{}`, `Branch{}`), an arm of `Sync`,
//! `Race` or `Rush`, a reaction body (`Upon`, `When`), a `Batch{}` body and a landing that
//! assigns a local `var` of the code around it share the local (S1d), as an `Fn` does; and S5:
//! since no region crosses a site, a task sees every write made before a switch.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");

fn expectInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const x = try h.execute(source);
    const value = x.get(name) orelse return error.MissingBinding;
    if (value.integer != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, value.integer, expected, source });
    try std.testing.expectEqual(expected, value.integer);
}

/// The result of task `name` once the run is quiescent, read from the report.
fn taskResult(h: *harness.Harness, source: []const u8, name: []const u8) !i64 {
    const x = try h.execute(source);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const text = out.buffered();
    var key: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&key, "\"{s}\":{{\"$task\":{{", .{name});
    const at = std.mem.indexOf(u8, text, head) orelse {
        std.debug.print("no task {s}: {s}\n", .{ name, text });
        return error.MissingBinding;
    };
    const result = "\"result\":";
    const from = (std.mem.indexOfPos(u8, text, at, result) orelse return error.MissingBinding) + result.len;
    var end = from;
    while (end < text.len and (text[end] == '-' or std.ascii.isDigit(text[end]))) end += 1;
    return std.fmt.parseInt(i64, text[from..end], 10) catch {
        std.debug.print("task {s} has no integer result: {s}\n", .{ name, text });
        return error.MissingBinding;
    };
}

fn expectTask(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const actual = try taskResult(h, source, name);
    if (actual != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, actual, expected, source });
    try std.testing.expectEqual(expected, actual);
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

/// How many cell operations of each kind, and whether there is a cell type.
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

test "S1d: a task body, a Branch, arms, reaction bodies and Batch bodies share a local var they assign" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0085's `Waits`: the body writes after its `Sleep`, and the creator reads after `Await`.
    try expectTask(h, "Waits()<transacts><suspends>:i64=Block{var Seen:i64=0;T:=Spawn{Sleep(1.0);Set(Seen,7)};T.Await();Seen}\nP:task(i64)=Spawn{Waits()}", "P", 7);
    // `set` and a compound `set` as statements of the body.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var S:i64=1;T:=Spawn{Sleep(1.0);set S+=4;set S=S*10;S};A:=T.Await();A*1000+S}\nP:task(i64)=Spawn{F()}", "P", 50050);
    // A `Branch` the frame waits for at its end; the creator reads after its own sleep.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;Branch{Sleep(1.0);Set(N,N+5)};Sleep(2.0);N}\nP:task(i64)=Spawn{F()}", "P", 5);
    // `Sync` arms write one cell, in the order the scheduler runs them.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;X:=Sync(Block{Sleep(1.0);set N=N*10+1;N},Block{Sleep(2.0);set N=N*10+2;N});X(0)*10000+X(1)*100+N}\nP:task(i64)=Spawn{F()}", "P", 11212);
    // A `Race` loser is cancelled at its sleep, before its write.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;W:=Race(Block{Sleep(1.0);Set(N,N+1)},Block{Sleep(3.0);Set(N,N+100)});W*10+N}\nP:task(i64)=Spawn{F()}", "P", 11);
    // A `Rush` loser keeps running and writes the cell after the expression resolved.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;W:=Rush(Block{Sleep(1.0);Set(N,N+1)},Block{Sleep(2.0);Set(N,N+100)});A:=N;Sleep(3.0);W*10000+A*100+N}\nP:task(i64)=Spawn{F()}", "P", 10201);
    // A `When` body runs at each change of its guard and writes the creator's local.
    try expectTask(h, "var G:i64=0\nF()<transacts><suspends>:i64=Block{var L:i64=0;W:task(void)=When(G,Set(L,L*10+G));set G=5;Sleep(1.0);set G=7;Sleep(1.0);L}\nT:task(i64)=Spawn{F()}", "T", 57);
    // An `Upon` body, once its guard holds.
    try expectTask(h, "var G:i64=0\nF()<transacts><suspends>:i64=Block{var L:i64=1;U:task(i64)=Upon(G>0,Set(L,L+G));Sleep(1.0);set G=5;Sleep(1.0);L}\nT:task(i64)=Spawn{F()}", "T", 6);
    // A `Batch{}` body, which runs where it stands.
    try expectInt(h, "F()<transacts>:i64=Block{var L:i64=0;B:i64=Batch{set L=L+3;L*2};L*100+B}\nV:i64=F()", "V", 306);
    // A path assignment shares the local too: a field of a struct, an element of an array.
    try expectTask(h, "P:=struct{A:i64=0,B:i64=0}\nF()<transacts><suspends>:i64=Block{var Q:P=P{A:=1};T:=Spawn{Sleep(1.0);Block{set Q.B=9;0}};T.Await();Q.A*10+Q.B}\nR:task(i64)=Spawn{F()}", "R", 19);
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var Xs:[]i64=array{1,2};T:=Spawn{Sleep(1.0);Attempt(Block{set Xs[1]=20;0},0)};T.Await();Attempt(Xs[0]+Xs[1],-1)}\nR:task(i64)=Spawn{F()}", "R", 21);
    // A task in a task assigns a local of the outer body.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{T:=Spawn{var Y:i64=0;U:=Spawn{Sleep(1.0);Set(Y,3)};U.Await();Y};T.Await()}\nR:task(i64)=Spawn{F()}", "R", 3);
    // A task inside an `Fn` assigns the local the `Fn` captured.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;G:=Fn()<transacts><suspends>:i64{Block{T:=Spawn{Sleep(1.0);Set(X,X+10)};T.Await()}};G();X}\nR:task(i64)=Spawn{F()}", "R", 11);
    // A nested function reads the cell a task writes (S1a and S1d agree on the one cell).
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var C:i64=0;Get()<reads>:i64=C;T:=Spawn{Sleep(1.0);Set(C,5)};T.Await();Get()}\nR:task(i64)=Spawn{F()}", "R", 5);
    // The root shares as functions do: a `Batch{}` body, and a body whose write a closure the
    // root stored reads after the task is awaited.
    try expectInt(h, "V:i64=Block{var X:i64=0;B:i64=Batch{set X=X+4;0};X}", "V", 4);
    try expectTask(h, "var Keep:option(function<reads>(tuple(),i64))=option{}\nT:task(i64)=Block{var N:i64=1;set Keep=option{Fn()<reads>:i64{N}};Spawn{Sleep(1.0);Set(N,5)}}\nR()<transacts><suspends>:i64=Block{T.Await();Attempt(Keep?(),-1)}\nU:task(i64)=Spawn{R()}", "U", 5);
    // A loop in an arm, and a `Loop{}` that sleeps in an arm, over the local of the function.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;W:=Race(Block{For(I:1..3,Block{set X=X+I;0});Sleep(1.0);X},Block{Sleep(2.0);0});W}\nP:task(i64)=Spawn{F()}", "P", 6);
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;W:=Race(Block{Loop{If(X>=3,Break(),false);Sleep(1.0);set X=X+1};X},Block{Sleep(9.0);0});W*10+X}\nP:task(i64)=Spawn{F()}", "P", 33);
}

test "task bodies and arms in nested functions share as anywhere else" {
    const h = try harness.create();
    defer scratch.release(h);
    // A nested function whose body spawns a task that writes the local of the function around it.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;Kick()<transacts><suspends>:i64=Block{T:=Spawn{Sleep(1.0);Set(X,X+10)};T.Await()};A:=Kick();A*100+X}\nP:task(i64)=Spawn{F()}", "P", 1111);
    // Its body is a task body: the task outlives the call and writes the cell later.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;Go()<transacts><suspends>:task(i64)=Spawn{Sleep(1.0);Set(X,X+5)};T:=Go();T.Await();X}\nP:task(i64)=Spawn{F()}", "P", 6);
    // `Sync` arms in a nested function.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;Both()<transacts><suspends>:i64=Block{R:=Sync(Block{Sleep(1.0);set X=X*10+2;X},Block{Sleep(2.0);Set(X,X*10+3)});R(0)};A:=Both();A*1000+X}\nP:task(i64)=Spawn{F()}", "P", 12123);
    // A local of the nested function itself, and a call of a nested function with a default and
    // a named argument from a task body.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{Inner(N:i64)<transacts><suspends>:i64=Block{var Y:i64=N;T:=Spawn{Sleep(1.0);Set(Y,Y*3)};T.Await();Y};Inner(4)}\nP:task(i64)=Spawn{F()}", "P", 12);
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;Add(K:i64=5)<transacts>:void=Set(X,X+K);T:=Spawn{Sleep(1.0);Add();Add(K:=2);Set(X,X*10)};T.Await();X}\nP:task(i64)=Spawn{F()}", "P", 70);
    // A parameter of the nested function stays a copy.
    try refuses(h, "F()<transacts><suspends>:i64=Block{Inner(N:i64)<transacts><suspends>:i64=Block{T:=Spawn{Sleep(1.0);Set(N,3)};T.Await()};Inner(4)}", .arm_assigns_local, "N");
}

test "S1d in a landing: the second share wave" {
    const h = try harness.create();
    defer scratch.release(h);
    // The losing arm's `Defer` runs as its landing on the cancellation, and writes the local of
    // the function the arms stand in.
    const race = "Run()<transacts><suspends>:i64=Block{var X:i64=0;W:=Race(Block{Defer{set X=X+10};Sleep(5.0);1},Block{Sleep(1.0);2});W*100+X}\nT:task(i64)=Spawn{Run()}";
    try expectTask(h, race, "T", 210);
    // A local of the cancelled function itself: a closure stored before the sleep reads its cell
    // after the landing wrote it.
    const own =
        \\var Keep:option(function<reads>(tuple(),i64))=option{}
        \\F()<transacts><suspends>:i64=Block{var N:i64=0;set Keep=option{Fn()<reads>:i64{N}};Defer{set N=N+1};Sleep(5.0);N}
        \\G()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(1.0);2});W*100+Attempt(Keep?(),-1)}
        \\T:task(i64)=Spawn{G()}
    ;
    try expectTask(h, own, "T", 201);
    // The copy at the normal exit writes the same cell.
    try expectTask(h, "var Keep:option(function<reads>(tuple(),i64))=option{}\nF()<transacts><suspends>:i64=Block{var N:i64=0;set Keep=option{Fn()<reads>:i64{N}};Defer{set N=N+1};Sleep(1.0);N}\nG()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(5.0);2});W*100+Attempt(Keep?(),-1)}\nT:task(i64)=Spawn{G()}", "T", 1);
    // A `Defer` in a task body that is cancelled writes, from its landing, the local the body
    // captured.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Defer{set X=X+1};Sleep(5.0);0};Sleep(1.0);T.Cancel();Sleep(1.0);X}\nP:task(i64)=Spawn{F()}", "P", 1);
    // A `Cancel` gives a landing too (RFC-0082 C87).
    try expectTask(h, "var Keep:option(function<reads>(tuple(),i64))=option{}\nF()<transacts><suspends>:i64=Block{var N:i64=4;set Keep=option{Fn()<reads>:i64{N}};Defer{set N=N*10};Sleep(5.0);N}\nG()<transacts><suspends>:i64=Block{T:=Spawn{F()};Sleep(1.0);T.Cancel();Sleep(1.0);Attempt(Keep?(),-1)}\nT:task(i64)=Spawn{G()}", "T", 40);
    // Only one compile more than the same program with a module `var` in place of the local:
    // the share is noted by the compile that has the landings. The landing is the only closure
    // that names the local here, and it assigns it (S1d, I5): a landing that only reads a local
    // takes no cell (I13-D5), and an `Fn` that names it shares it in the first wave (I13).
    const landing = "var M:i64=0\nF()<transacts><suspends>:i64=Block{var N:i64=4;Defer{set N=N*10;Set(M,N)};Sleep(5.0);N}\nG()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(1.0);2});W*100+M}\nT:task(i64)=Spawn{G()}";
    try expectTask(h, landing, "T", 240);
    const p = try h.compile(landing);
    const with = h.front.passes;
    try std.testing.expect(census(p).ref_type);
    _ = try h.compile("var M:i64=0\nF()<transacts><suspends>:i64=Block{var N:i64=4;Defer{set M=40};Sleep(5.0);N}\nG()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(1.0);2});W*100+M}\nT:task(i64)=Spawn{G()}");
    const without = h.front.passes;
    if (with != without + 1) std.debug.print("{d} passes against {d}\n", .{ with, without });
    try std.testing.expectEqual(without + 1, with);
    // The Fn that stores the cell names the local too, and shares it in the first wave: the same
    // compile finds the landing, so the two waves cost one compile more than the twin, not two.
    _ = try h.compile(own);
    const both_waves = h.front.passes;
    _ = try h.compile("var Keep:option(function<reads>(tuple(),i64))=option{}\nvar M:i64=0\nF()<transacts><suspends>:i64=Block{var N:i64=0;set Keep=option{Fn()<reads>:i64{7}};Defer{set M=M+1};Sleep(5.0);N}\nG()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(1.0);2});W*100+Attempt(Keep?(),-1)}\nT:task(i64)=Spawn{G()}");
    try std.testing.expectEqual(h.front.passes + 1, both_waves);
}

test "S5: a task writes a shared local across a suspension, and its creator may return first" {
    const h = try harness.create();
    defer scratch.release(h);
    // The creator has returned when the task writes; the cell stays reachable from the task's
    // saved frame and from the closure the creator handed on.
    try expectTask(h, "Make()<transacts><suspends>:function<reads>(tuple(),i64)=Block{var S:i64=1;T:=Spawn{Sleep(2.0);Set(S,S+10)};Fn()<reads>:i64{S}}\nRun()<transacts><suspends>:i64=Block{R:=Make();A:=R();Sleep(3.0);A*100+R()}\nT:task(i64)=Spawn{Run()}", "T", 111);
    // The creator returns and nobody reads the write: harmless.
    try expectTask(h, "Make()<transacts><suspends>:i64=Block{var S:i64=1;T:=Spawn{Sleep(2.0);Set(S,S+10)};S}\nRun()<transacts><suspends>:i64=Block{A:=Make();Sleep(3.0);A}\nT:task(i64)=Spawn{Run()}", "T", 1);
    // Two tasks write one cell in the interleaving the scheduler fixes: deadlines 1, 2, 3, 4.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Sleep(1.0);set X=X*10+1;Sleep(2.0);Set(X,X*10+3)};U:=Spawn{Sleep(2.0);set X=X*10+2;Sleep(2.0);Set(X,X*10+4)};T.Await();U.Await();X}\nP:task(i64)=Spawn{F()}", "P", 1234);
    // At equal deadlines the task that registered first wakes first.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Sleep(1.0);Set(X,X*10+1)};U:=Spawn{Sleep(1.0);Set(X,X*10+2)};Sleep(1.0);set X=X*10+3;T.Await();U.Await();X}\nP:task(i64)=Spawn{F()}", "P", 123);
    // A body runs at once to its first site: its write before the `Sleep` is seen by the creator
    // at the next statement.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{set X=X+1;Sleep(1.0);Set(X,X*100)};A:=X;T.Await();A*1000+X}\nP:task(i64)=Spawn{F()}", "P", 2200);
}

test "S5: a Spawn held in a region drops its writes when the region fails" {
    const h = try harness.create();
    defer scratch.release(h);
    // A cell made before the region: the held start is dropped and the creator's write undone.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;A:=Attempt(Block{T:=Spawn{Set(X,X+10)};set X=X+100;Require[false];0},-1);Sleep(1.0);X*10+A}\nP:task(i64)=Spawn{F()}", "P", 9);
    // The region commits: the start is carried out at the commit, after the creator's write.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;A:=Attempt(Block{T:=Spawn{Set(X,X+10)};set X=X+100;0},-1);B:=X;Sleep(1.0);B*100+X*10+A}\nP:task(i64)=Spawn{F()}", "P", 11100 + 1110);
    // A cell made inside the region is forgotten with the closure stored there.
    try expectTask(h, "var Keep:option(function<reads>(tuple(),i64))=option{}\nF()<transacts><suspends>:i64=Block{A:=Attempt(Block{var C:i64=5;T:=Spawn{Set(C,C+1)};set Keep=option{Fn()<reads>:i64{C}};Require[false];0},-1);Sleep(1.0);A*10+Attempt(Keep?(),-7)}\nP:task(i64)=Spawn{F()}", "P", -17);
    try expectTask(h, "var Keep:option(function<reads>(tuple(),i64))=option{}\nF()<transacts><suspends>:i64=Block{A:=Attempt(Block{var C:i64=5;T:=Spawn{Set(C,C+1)};set Keep=option{Fn()<reads>:i64{C}};0},-1);Sleep(1.0);A*10+Attempt(Keep?(),-7)}\nP:task(i64)=Spawn{F()}", "P", 6);
    // A body's write in a region of its own that fails is undone, as anywhere.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);Attempt(Block{set X=50;Require[false];0},0);Set(X,X+2)};T.Await();X}\nP:task(i64)=Spawn{F()}", "P", 3);
}

test "S5: cancellation stops later writes and leaves earlier ones" {
    const h = try harness.create();
    defer scratch.release(h);
    // Cancelled between its two writes.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Sleep(1.0);set X=X+1;Sleep(2.0);Set(X,X+10)};Sleep(2.0);T.Cancel();Sleep(5.0);X}\nP:task(i64)=Spawn{F()}", "P", 1);
    // Cancelled before its first.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Sleep(1.0);set X=X+1;Sleep(2.0);Set(X,X+10)};T.Cancel();Sleep(5.0);X}\nP:task(i64)=Spawn{F()}", "P", 0);
    // Not cancelled: both.
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{Sleep(1.0);set X=X+1;Sleep(2.0);Set(X,X+10)};Sleep(5.0);X}\nP:task(i64)=Spawn{F()}", "P", 11);
}

test "no loop in a task body carries the shared local it assigns" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;T:=Spawn{For(I:1..3,Block{set N=N+I;0});Sleep(1.0);N};A:=T.Await();A*100+N}\nP:task(i64)=Spawn{F()}", "P", 606);
    try expectTask(h, "F()<transacts><suspends>:i64=Block{var N:i64=0;var I:i64=0;T:=Spawn{While(I<3,Block{set I=I+1;set N=N+I});N};A:=T.Await();A*100+N*10+I}\nP:task(i64)=Spawn{F()}", "P", 663);
    // A `Loop{}` that sleeps, while the creator writes the same cell between its visits.
    try expectTask(h,
        \\F()<transacts><suspends>:i64=Block{
        \\  var N:i64=0
        \\  T:=Spawn{Loop{If(N>=3,Break(),false);Sleep(1.0);set N=N+1};N}
        \\  Sleep(1.5)
        \\  set N=N+10
        \\  A:=T.Await()
        \\  A*100+N
        \\}
        \\P:task(i64)=Spawn{F()}
    , "P", 1212);
}

test "what I5 does not lift is refused as before" {
    const h = try harness.create();
    defer scratch.release(h);
    // A parameter, an immutable local, a capture of an explicit list.
    try refuses(h, "F(X:i64)<transacts><suspends>:i64=Block{T:=Spawn{Set(X,2)};T.Await()}", .arm_assigns_local, "X");
    try refuses(h, "F()<transacts><suspends>:i64=Block{X:i64=1;T:=Spawn{Block{set X=2;X}};T.Await()}", .arm_assigns_local, "X");
    try refuses(h, "F()<transacts><suspends>:i64=Block{X:i64=1;R:=Sync(Block{Sleep(1.0);Set(X,2)},Block{Sleep(1.0);1});R(0)}", .arm_assigns_local, "X");
    try refuses(h, "F()<transacts>:i64=Block{X:i64=1;B:i64=Batch{Set(X,2)};X}", .arm_assigns_local, "X");
    try refuses(h, "F(L:i64)<transacts>:i64=Block{W:task(void)=When(1,Set(L,2));1}", .arm_assigns_local, "L");
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=1;G:=Fn[Y:i64=X]()<transacts>:i64{Block{T:=Spawn{Set(Y,2)};1}};G()}", .arm_assigns_local, "Y");
    // A guard is no closure that may assign (S1d). Since I14 it shares the local it names
    // (S1b), and the assignment is then the guard's effect it may not have.
    try refuses(h, "F()<transacts><suspends>:i64=Block{var X:i64=1;W:task(void)=When(Set(X,2),1);1}", .guard_effect, "X");
    // A loop in a body over a parameter.
    try refuses(h, "F(N:i64)<transacts><suspends>:i64=Block{T:=Spawn{For(I:1..3,Block{set N=N+I;0});N};T.Await()}", .arm_assigns_local, "N");
}

test "S6 in task bodies, arms and Batch bodies" {
    const h = try harness.create();
    defer scratch.release(h);
    // Reading a shared local needs <reads>, where it is declared and in the body.
    try refuses(h, "F()<writes>:i64=Block{var X:i64=0;B:i64=Batch{Set(X,1)};X}", .local_read_requires_reads, "X");
    try refuses(h, "F()<writes><allocates><suspends>:i64=Block{var X:i64=0;T:=Spawn{Set(X,X+1)};0}", .local_read_requires_reads, "X");
    // Writing it needs <writes>: a body has the heap effects of the code it stands in.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=0;G:=Fn()<reads><allocates>:i64{Block{T:=Spawn{Set(X,1)};0}};G()}", .set_requires_writes, "X");
}

test "a program that shares a local through a task body takes one more compile" {
    const h = try harness.create();
    defer scratch.release(h);
    const Twin = struct { []const u8, []const u8 };
    for ([_]Twin{
        .{ "var M:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);Set(X,2)};T.Await();X}\nP:task(i64)=Spawn{F()}", "var M:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);Set(M,2)};T.Await();X}\nP:task(i64)=Spawn{F()}" },
        .{ "var M:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;R:=Sync(Block{Sleep(1.0);Set(X,X+1)},Block{Sleep(2.0);Set(X,X+2)});X}\nP:task(i64)=Spawn{F()}", "var M:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;R:=Sync(Block{Sleep(1.0);Set(M,1)},Block{Sleep(2.0);Set(M,2)});X}\nP:task(i64)=Spawn{F()}" },
        .{ "var M:i64=0\nF()<transacts>:i64=Block{var X:i64=1;B:i64=Batch{For(K:1..3,Block{set X=X+K;0});X};B}\nV:i64=F()", "var M:i64=0\nF()<transacts>:i64=Block{var X:i64=1;B:i64=Batch{For(K:1..3,Block{set M=K;0});7};B}\nV:i64=F()" },
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

test "a shared local a task body assigns lowers to one ref_new and cell operations" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);Set(X,X+1)};T.Await();X}\nP:task(i64)=Spawn{F()}");
    const c = census(p);
    try std.testing.expect(c.ref_type);
    try std.testing.expectEqual(@as(usize, 1), c.new);
    // `X` in the body and the last `X`; the write is the body's.
    try std.testing.expectEqual(@as(usize, 2), c.get);
    try std.testing.expectEqual(@as(usize, 1), c.set);
    // A body that only reads a local shares it since Q1 (I13): it reads the write after its
    // creation, 6, where it read its copy, 2, before.
    const reads = "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);X+1};set X=5;T.Await()}\nP:task(i64)=Spawn{F()}";
    const q = try h.compile(reads);
    try std.testing.expect(census(q).ref_type);
    try expectTask(h, reads, "P", 6);
    h.front.share_names = false;
    const before = try h.compile(reads);
    try std.testing.expect(!census(before).ref_type);
    try expectTask(h, reads, "P", 2);
    h.front.share_names = true;
}
