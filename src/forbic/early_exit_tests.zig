//! Early exit (RFC-0068): `Return`, `Loop{}` with `Break`, `Defer` and `Err`.
//!
//! `h.execute` runs a program in both machines, compares their results, fuel-visible steps and
//! member pools, and replays each run in the report validator, so every test below is also a
//! test that the three implementations agree.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");

const Expected = struct { []const u8, i64 };

fn expectIntegers(x: evaluator.Execution, expected: []const Expected) !void {
    for (expected) |entry| {
        const value = x.get(entry[0]) orelse {
            std.debug.print("no binding {s}\n", .{entry[0]});
            return error.Missing;
        };
        if (value.integer != entry[1]) std.debug.print("{s}: expected {d}, found {d}\n", .{ entry[0], entry[1], value.integer });
        try std.testing.expectEqual(entry[1], value.integer);
    }
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    // A diagnostic never points into the generated library block.
    try std.testing.expect(r.failed.span.end <= source.len);
}

/// `Note(D)` appends a digit to `Trace`, so a trace reads as the order things ran in.
const noted =
    \\var Trace:i64=0
    \\Note(D:i64)<transacts>:i64=Set(Trace,Trace*10+D)
    \\
;

test "Return leaves a function from any depth and keeps what was written" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Log:i64=0
        \\Sign(N:i64)<computes>:i64=Block{
        \\  If(N<0,Return(-1),false)
        \\  If(N==0,Return(0),false)
        \\  1
        \\}
        \\Both(N:i64)<computes>:i64=If(N>0,Return(1),Return(2))
        \\Whole(N:i64)<computes>:i64=Return(N+1)
        \\Deep(N:i64)<transacts>:i64=Block{
        \\  set Log=Log+1
        \\  If(N>0,If(N>1,If(N>2,Block{set Log=Log+10;Return(3)},false),false),false)
        \\  set Log=Log+100
        \\  0
        \\}
        \\A<public>:i64=Sign(-5)
        \\B<public>:i64=Sign(0)
        \\C<public>:i64=Sign(7)
        \\D<public>:i64=Both(1)+Both(0)*10
        \\E<public>:i64=Whole(41)
        \\F<public>:i64=Deep(3)
        \\G<public>:i64=Log
        \\H<public>:i64=Deep(1)
        \\I<public>:i64=Log
    );
    try expectIntegers(x, &.{ .{ "A", -1 }, .{ "B", 0 }, .{ "C", 1 }, .{ "D", 21 }, .{ "E", 42 }, .{ "F", 3 }, .{ "G", 11 }, .{ "H", 0 }, .{ "I", 112 } });
}

test "a Return inside a region commits it, and a later failure still rolls back" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=0
        \\Items:[]i64=array{5,6}
        \\Inside(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;If(N>0,Return(Cell*10),false);Fail["no"];0},-1)
        \\Bound(I:i64)<transacts>:i64=Block{
        \\  If(X:=Items[I],X>5,Block{set Cell=Cell+100;Return(X)},false)
        \\  0
        \\}
        \\Pick(I:i64)<computes><decides>:i64=Block{If(I<0,Return(-1),false);Items[I]}
        \\Caught(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1000;Inside(N);Fail["outer"];0},Cell)
        \\A<public>:i64=Inside(1)
        \\B<public>:i64=Cell
        \\C<public>:i64=Inside(0)
        \\D<public>:i64=Cell
        \\E<public>:i64=Bound(1)
        \\F<public>:i64=Bound(0)+Bound(9)
        \\G<public>:i64=Cell
        \\H<public>:i64=Attempt(Pick[-1],99)
        \\I<public>:i64=Attempt(Pick[1],99)
        \\J<public>:i64=Attempt(Pick[7],99)
        \\K<public>:i64=Caught(1)
        \\L<public>:i64=Cell
    );
    // Inside(1) writes 1 and returns through its own region; Inside(0) fails and restores the 1.
    // Bound(1) binds 6 and keeps its write. Pick returns before the read that would have failed.
    // Caught: the region inside the call was committed by its Return, and the caller's failure
    // then undoes it together with the caller's own write.
    try expectIntegers(x, &.{ .{ "A", 10 }, .{ "B", 1 }, .{ "C", -1 }, .{ "D", 1 }, .{ "E", 6 }, .{ "F", 0 }, .{ "G", 101 }, .{ "H", -1 }, .{ "I", 6 }, .{ "J", 99 }, .{ "K", 101 }, .{ "L", 101 } });
}

test "Loop{} repeats until Break and carries the locals it assigns" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Bits(X:i64)<transacts>:i64=Block{
        \\  var B:i64=1
        \\  var C:i64=0
        \\  Loop{
        \\    If(B>X,Break(),false)
        \\    set B=2*B
        \\    set C=C+1
        \\  }
        \\  C
        \\}
        \\Grid(N:i64)<transacts>:i64=Block{
        \\  var Outer:i64=0
        \\  var Total:i64=0
        \\  Loop{
        \\    If(Outer>=N,Break(),false)
        \\    var Inner:i64=0
        \\    Loop{
        \\      If(Inner>Outer,Break(),false)
        \\      set Total=Total+1
        \\      set Inner=Inner+1
        \\    }
        \\    set Outer=Outer+1
        \\  }
        \\  Total
        \\}
        \\Kept(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{set I=I+N;If(I>10,Break(),false);set I=I+1}
        \\  I
        \\}
        \\var Ticks:i64=0
        \\Root<public>:logic=Loop{set Ticks=Ticks+1;If(Ticks>=3,Break(),false)}
        \\A<public>:i64=Bits(8)
        \\B<public>:i64=Bits(0)
        \\C<public>:i64=Grid(4)
        \\D<public>:i64=Kept(4)
        \\E<public>:i64=Ticks
    );
    // Grid: the inner Break leaves only the inner loop, 1+2+3+4 visits. Kept: the write before
    // the Break is kept (4, 5, 9, 10, 14). A loop has the value true, also at the top level.
    try expectIntegers(x, &.{ .{ "A", 4 }, .{ "B", 0 }, .{ "C", 10 }, .{ "D", 14 }, .{ "E", 3 } });
    try std.testing.expect(x.get("Root").?.boolean);
}

test "Return and Break leave For, While and Loop{} nested in one another" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64=array{5,6}
        \\var Seen:i64=0
        \\Find(T:i64)<transacts>:i64=Block{
        \\  For(I->X:Items,Block{set Seen=Seen+1;If(X==T,Return(I),false)})
        \\  -1
        \\}
        \\FirstOver(L:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  While(I<10,Block{If(I*I>L,Return(I),false);set I=I+1})
        \\  -1
        \\}
        \\Twice(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{If(I>=N,Return(I*2),false);set I=I+1}
        \\}
        \\Scan(Limit:i64)<transacts>:i64=Block{
        \\  var Rounds:i64=0
        \\  Loop{
        \\    set Rounds=Rounds+1
        \\    For(X:Items,If(X*Rounds>Limit,Break(),false))
        \\  }
        \\  Rounds
        \\}
        \\Triple(T:i64)<transacts>:i64=Block{
        \\  var A:i64=0
        \\  Loop{
        \\    set A=A+1
        \\    var B:i64=0
        \\    While(B<3,Block{
        \\      set B=B+1
        \\      For(X:Items,If(A*B*X==T,Return(A*100+B*10+X),false))
        \\    })
        \\    If(A>5,Break(),false)
        \\  }
        \\  0
        \\}
        \\Pairs(T:i64)<transacts>:i64=Block{
        \\  For(X:Items,Y:1..3,X*Y>10,If(X*Y==T,Return(X*10+Y),false))
        \\  0
        \\}
        \\A<public>:i64=Find(6)
        \\B<public>:i64=Seen
        \\C<public>:i64=Find(9)
        \\D<public>:i64=Seen
        \\E<public>:i64=FirstOver(10)
        \\F<public>:i64=FirstOver(1000)
        \\G<public>:i64=Twice(5)
        \\H<public>:i64=Scan(20)
        \\I<public>:i64=Triple(60)
        \\J<public>:i64=Triple(7)
        \\K<public>:i64=Pairs(18)
        \\L<public>:i64=Pairs(5)
    );
    // Find stops at the match (two visits) or runs out (two more). Scan: 6*4 is the first product
    // above 20. Triple(60) is 4*3*5. Pairs skips the products that are not above 10.
    try expectIntegers(x, &.{ .{ "A", 1 }, .{ "B", 2 }, .{ "C", -1 }, .{ "D", 4 }, .{ "E", 4 }, .{ "F", -1 }, .{ "G", 10 }, .{ "H", 4 }, .{ "I", 435 }, .{ "J", 0 }, .{ "K", 63 }, .{ "L", 0 } });
}

test "a Return inside an anonymous function or a method returns from that one" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Outer(N:i64)<computes>:i64=Block{
        \\  F:=Fn(X:i64)<computes>:i64{Block{If(X>0,Return(X*2),false);0}}
        \\  F(N)+1
        \\}
        \\Looped(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  var Sum:i64=0
        \\  Loop{
        \\    If(I>=N,Break(),false)
        \\    G:=Fn(X:i64)<computes>:i64{If(X>1,Return(X*10),Return(X))}
        \\    set Sum=Sum+G(I)
        \\    set I=I+1
        \\  }
        \\  Sum
        \\}
        \\Counter:=class{
        \\  var N:i64=0
        \\  Bump(By:i64)<transacts>:i64=Block{If(By<=0,Return(-1),false);set Self.N=Self.N+By;Self.N}
        \\  Until(Limit:i64)<transacts>:i64=Block{
        \\    Loop{If(Self.N>=Limit,Return(Self.N),false);Self.Bump(3)}
        \\  }
        \\}
        \\K:=Counter{}
        \\A<public>:i64=Outer(5)
        \\B<public>:i64=Outer(-1)
        \\C<public>:i64=Looped(4)
        \\D<public>:i64=K.Bump(0)
        \\E<public>:i64=K.Bump(4)
        \\F<public>:i64=K.Until(10)
    );
    try expectIntegers(x, &.{ .{ "A", 11 }, .{ "B", 1 }, .{ "C", 0 + 1 + 20 + 30 }, .{ "D", -1 }, .{ "E", 4 }, .{ "F", 10 } });
}

test "Defer runs last in first out when its block ends, returns or breaks" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(noted ++
        \\Reset()<transacts>:i64=Set(Trace,0)
        \\Order()<transacts>:i64=Block{Note(1);Defer{Note(2)};Defer{Note(3)};Note(4);7}
        \\Nested()<transacts>:i64=Block{
        \\  Defer{Note(1)}
        \\  Block{Defer{Note(2)};Note(3);0}
        \\  Note(4)
        \\  5
        \\}
        \\Early(N:i64)<transacts>:i64=Block{
        \\  Defer{Note(1)}
        \\  Block{Defer{Note(2)};If(N>0,Return(Note(3)),false);Note(4);0}
        \\  Note(5)
        \\  9
        \\}
        \\Looped()<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{
        \\    Defer{Note(I)}
        \\    set I=I+1
        \\    If(I>=3,Break(),false)
        \\  }
        \\  I
        \\}
        \\Inside()<transacts>:i64=Block{
        \\  Note(1)
        \\  Defer{Note(2);Defer{Note(9)};Note(3)}
        \\  Note(4)
        \\}
        \\Shadow()<transacts>:i64=Block{
        \\  X:i64=1
        \\  Defer{Note(X)}
        \\  Block{Y:i64=2;If(Y==2,Return(Y),false);0}
        \\}
        \\Sets()<transacts>:i64=Block{
        \\  var Count:i64=0
        \\  Block{Defer{set Count=Count+5};set Count=Count+1;0}
        \\  Count
        \\}
        \\A<public>:i64=Order()
        \\TA<public>:i64=Trace
        \\B<public>:i64=Reset()+Nested()
        \\TB<public>:i64=Trace
        \\C<public>:i64=Reset()+Early(1)
        \\TC<public>:i64=Trace
        \\D<public>:i64=Reset()+Early(0)
        \\TD<public>:i64=Trace
        \\E<public>:i64=Reset()+Looped()
        \\TE<public>:i64=Trace
        \\F<public>:i64=Reset()+Inside()
        \\TF<public>:i64=Trace
        \\G<public>:i64=Reset()+Shadow()
        \\TG<public>:i64=Trace
        \\H<public>:i64=Sets()
    );
    // Early(1): the value 3 is ready before the two Defers run. Looped: each visit runs its Defer,
    // the last one on the Break. Inside: a Defer in a Defer runs when the outer one is done.
    // Shadow: the deferred code names the X of where it was written; the inner block's local has
    // another name, since it may not shadow X (RFC-0076 rule 1, asserted below).
    try expectIntegers(x, &.{
        .{ "A", 7 },  .{ "TA", 1432 },
        .{ "B", 5 },  .{ "TB", 3241 },
        .{ "C", 3 },  .{ "TC", 321 },
        .{ "D", 9 },  .{ "TD", 4251 },
        .{ "E", 3 },  .{ "TE", 123 },
        .{ "F", 14 }, .{ "TF", 14239 },
        .{ "G", 2 },  .{ "TG", 1 },
        .{ "H", 6 },
    });
    const shadowing = noted ++ "Shadow()<transacts>:i64=Block{X:i64=1;Defer{Note(X)};Block{X:i64=2;If(X==2,Return(X),false);0}}";
    try expectCode(h, shadowing, .shadowed_name);
    try std.testing.expectEqual(std.mem.indexOf(u8, shadowing, "Block{X:i64=2").? + 6, h.front.compile(shadowing).failed.span.start);
}

test "Defer does not run when its block fails, and what it wrote is undone with the region around it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(noted ++
        \\Reset()<transacts>:i64=Set(Trace,0)
        \\Risky(N:i64)<transacts><decides>:i64=Block{
        \\  Note(1)
        \\  Defer{Note(2)}
        \\  Require[N>0]
        \\  Note(3)
        \\}
        \\Inner()<transacts>:i64=Block{Defer{Note(7)};1}
        \\Later()<transacts>:i64=Attempt(Block{Inner();Fail["later"];0},Trace)
        \\Arm(N:i64)<transacts>:i64=Block{
        \\  Defer{Note(1)}
        \\  Attempt(Block{Defer{Note(2)};Require[N>0];Note(3);0},Note(4))
        \\  Note(5)
        \\}
        \\A<public>:i64=Attempt(Risky[0],-1)
        \\TA<public>:i64=Trace
        \\B<public>:i64=Attempt(Risky[1],-1)
        \\TB<public>:i64=Trace
        \\C<public>:i64=Reset()+Later()
        \\TC<public>:i64=Trace
        \\D<public>:i64=Reset()+Arm(0)
        \\TD<public>:i64=Trace
        \\E<public>:i64=Reset()+Arm(1)
        \\TE<public>:i64=Trace
    );
    // Risky[0]: neither the Defer nor the first Note leaves a trace. Later: Inner's Defer ran and
    // wrote 7, and the caller's failure undid it. Arm(0): the failed block's Defer is skipped,
    // the enclosing one still runs.
    try expectIntegers(x, &.{
        .{ "A", -1 },  .{ "TA", 0 },
        .{ "B", 13 },  .{ "TB", 132 },
        .{ "C", 0 },   .{ "TC", 0 },
        .{ "D", 45 },  .{ "TD", 451 },
        .{ "E", 325 }, .{ "TE", 3251 },
    });
}

test "Err ends the run in both machines and no region catches it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Checked(N:i64)<computes>:i64=Block{If(N<0,Err("negative"),false);N}
        \\Typed(N:i64)<computes>:i64=If(N<0,Err(),N*2)
        \\A<public>:i64=Checked(5)
        \\B<public>:i64=Typed(4)
        \\C<public>:i64=If(false,Err("never"),3)
    );
    try expectIntegers(x, &.{ .{ "A", 5 }, .{ "B", 8 }, .{ "C", 3 } });
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "Checked(N:i64)<computes>:i64=Block{If(N<0,Err(\"negative\"),false);N}\nA:i64=Attempt(Checked(-1),7)", "Err(\"negative\")" },
        .{ "var Cell:i64=0\nF()<transacts>:i64=Block{set Cell=1;Loop{Defer{set Cell=2};Err(\"stop\")};3}\nA:i64=F()", "Err(\"stop\")" },
        .{ "A:i64=Attempt(If(true,Err(\"root\"),1),2)", "Err(\"root\")" },
    }) |case| {
        const r = try h.run(try h.compile(case[0]), 131072);
        try std.testing.expectEqual(types.Diagnostic.Code.runtime_error, r.failed.code);
        // The diagnostic points at the `Err`, and so at its message.
        const start = std.mem.indexOf(u8, case[0], case[1]).?;
        try std.testing.expectEqual(@as(u32, @intCast(start)), r.failed.span.start);
    }
    _ = try h.execute("A:i64=42");
}

test "early exit reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const items = "Items:[]i64=array{1,2}\nvar Cell:i64=0\n";
    for ([_]Case{
        // Break needs a Loop{} around it, in the same function.
        .{ "F()<computes>:i64=Block{Break();1}", .break_outside_loop },
        .{ items ++ "F()<transacts>:logic=For(X:Items,Break())", .break_outside_loop },
        .{ items ++ "F()<transacts>:logic=Block{var I:i64=0;While(I<3,Block{set I=I+1;Break()})}", .break_outside_loop },
        .{ "F()<transacts>:logic=Loop{G:=Fn(X:i64)<computes>:i64{Break()};Break()}", .break_outside_loop },
        .{ "F()<transacts>:logic=Loop{Break(1)}", .argument_count },
        // Return needs a function whose result type is written.
        .{ "A:i64=If(true,Return(1),2)", .return_outside_function },
        .{ "A:logic=Loop{Return(1)}", .return_outside_function },
        .{ items ++ "A:logic=For(X:Items,If(X>5,Return(true),false))", .return_outside_function },
        .{ "F()<computes>:i64=Block{G:=Fn(X:i64){Return(X)};G(1)}", .return_type_required },
        .{ "F()<computes>:i64=Return(true)", .type_mismatch },
        .{ "F()<computes>:i64=Return()", .expected_expression },
        .{ "F()<computes>:i64=Return(1,2)", .argument_count },
        // Return is the last thing its scope does.
        .{ "F()<computes>:i64=1+Return(2)", .return_not_tail },
        .{ "F()<computes>:i64=Return(2)+1", .return_not_tail },
        .{ "F()<computes>:i64=Block{Return(1);2}", .return_not_tail },
        .{ "F()<computes>:i64=Block{X:i64=Return(1);X}", .return_not_tail },
        .{ "G(X:i64)<computes>:i64=X\nF()<computes>:i64=G(Return(1))", .return_not_tail },
        .{ "F()<computes>:i64=If(Return(true),1,2)", .return_not_tail },
        .{ "F()<computes>:[]i64=array{Return(array{})}", .return_not_tail },
        .{ items ++ "F()<transacts>:logic=For(X:Return(Items),X)", .return_not_tail },
        // Defer is a statement with code after it, and its body stays inside it and cannot fail.
        .{ "F()<transacts>:i64=Block{1;Defer{Set(Cell,1)}}", .defer_position },
        .{ items ++ "F()<transacts>:i64=If(true,Defer{Set(Cell,1)},2)", .defer_position },
        .{ items ++ "F()<transacts>:i64=Block{X:i64=Defer{Set(Cell,1)};X}", .defer_position },
        .{ items ++ "F()<transacts>:i64=Block{Defer{};1}", .defer_empty },
        .{ items ++ "F()<transacts>:i64=Block{Defer{Return(1)};2}", .defer_exit },
        .{ items ++ "F()<transacts>:logic=Loop{Defer{Break()};Set(Cell,1)}", .defer_exit },
        .{ items ++ "F()<transacts>:i64=Block{Defer{Loop{Return(1)}};2}", .defer_exit },
        .{ items ++ "F()<transacts><decides>:i64=Block{Defer{Items[9]};1}", .defer_failure },
        .{ items ++ "F()<transacts><decides>:i64=Block{Defer{Require[Cell>0]};1}", .defer_failure },
        .{ items ++ "F()<transacts>:i64=Attempt(Block{Defer{Fail[\"no\"]};1},2)", .defer_failure },
        // The names are reserved.
        .{ "Return:i64=1", .expected_name },
        .{ "Break(X:i64)<computes>:i64=X", .expected_name },
        .{ "F()<computes>:i64=Block{Defer:i64=1;Defer}", .expected_name },
        .{ "Err:i64=1", .expected_name },
        .{ "F()<computes>:i64=Err(1)", .type_mismatch },
        .{ "F()<computes>:i64=Err(\"a\",\"b\")", .argument_count },
        .{ "F()<transacts>:logic=Loop{}", .macro_syntax },
    }) |case| {
        try expectCode(h, case[0], case[1]);
        _ = try h.execute("A:i64=42");
    }
    // Deferred code may handle a failure of its own, and a Break may leave a loop inside it.
    const x = try h.execute(items ++
        \\F()<transacts>:i64=Block{Defer{set Cell=Attempt(Items[9],7)};Defer{Loop{set Cell=Cell+1;Break()}};1}
        \\A<public>:i64=F()
        \\B<public>:i64=Cell
    );
    try expectIntegers(x, &.{ .{ "A", 1 }, .{ "B", 7 } });
}

test "the state loop Loop(Step, Initial) and While keep their lowering beside Loop{}" {
    const h = try harness.create();
    defer scratch.release(h);
    const before = "Advance(N:i64)<computes>:option(i64)=If(N<42,option{N+1},option{})\nA<public>:i64=Loop(Advance,39)\nSum(N:i64)<transacts>:i64=Block{var I:i64=0;var T:i64=0;While(I<N,Block{set T=T+I;set I=I+1});T}\nB<public>:i64=Sum(5)";
    const plain = try h.compile(before);
    const functions = plain.functions.len;
    const nodes = plain.function_nodes.len;
    // Adding a Loop{} elsewhere in the program changes nothing in the code of the other two.
    const mixed = try h.compile(before ++ "\nC<public>:logic=Loop{Break()}");
    try std.testing.expectEqual(functions + 1, mixed.functions.len);
    for (plain.functions, mixed.functions[0..functions]) |a, b| {
        try std.testing.expectEqual(a.body.end - a.body.start, b.body.end - b.body.start);
        try std.testing.expectEqual(a.control_ops, b.control_ops);
    }
    try std.testing.expect(mixed.function_nodes.len > nodes);
    const x = try h.execute(before ++ "\nC<public>:logic=Loop{Break()}");
    try expectIntegers(x, &.{ .{ "A", 42 }, .{ "B", 10 } });
    try std.testing.expect(x.get("C").?.boolean);
    // No exit operation appears unless something exits.
    for (plain.function_nodes) |entry| try std.testing.expect(entry.node.kind != .exit and entry.node.kind != .err);
}

fn functionNode(p: types.Program, comptime tag: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    for (p.function_nodes, 0..) |entry, index| if (entry.input == .operation and entry.node.kind == tag) return index;
    unreachable;
}

test "forged exits are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    // The exit sits in the second arm, so the first arm's sum is an earlier register it cannot reach.
    const p = try h.compile("F(N:i64)<computes>:i64=If(N>0,N+2,Return(N+1))\nA<public>:i64=F(0)\nB<public>:i64=F(3)");
    const body = try std.testing.allocator.dupe(types.FunctionNode, p.function_nodes);
    defer std.testing.allocator.free(body);
    const functions = try std.testing.allocator.dupe(types.RuntimeFunction, p.functions);
    defer std.testing.allocator.free(functions);
    const roots = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(roots);
    var forged = p;
    forged.function_nodes = body;
    forged.functions = functions;
    forged.nodes = roots;
    const exit = functionNode(p, .exit);
    const operand = p.function_nodes[exit].node.kind.exit;
    const merge = functionNode(p, .merge);
    const first = p.function_nodes[merge].node.kind.merge.left;
    const condition = p.function_nodes[functionNode(p, .if_begin)].node.kind.if_begin.condition;
    try std.testing.expect(first < exit and condition < exit and operand < exit);
    const x = (try h.run(forged, 10_000)).ok;
    try expectIntegers(x, &.{ .{ "A", 1 }, .{ "B", 5 } });
    // An operand of another type: the condition is `logic`, the function returns `i64`.
    body[exit].node.kind.exit = condition;
    try harness.invalid(h, forged);
    // An operand that is not computed yet, itself, and one beyond the body.
    body[exit].node.kind.exit = @intCast(exit);
    try harness.invalid(h, forged);
    body[exit].node.kind.exit = @intCast(merge);
    try harness.invalid(h, forged);
    body[exit].node.kind.exit = @intCast(body.len);
    try harness.invalid(h, forged);
    // An operand of the right type that lies in the other arm: it does not dominate the exit.
    body[exit].node.kind.exit = first;
    try harness.invalid(h, forged);
    body[exit] = p.function_nodes[exit];
    // A type that does not exist for the exit itself.
    body[exit].node.value_type = @fromBackingInt(@as(u16, @intCast(4 + p.definitions.len)));
    try harness.invalid(h, forged);
    body[exit] = p.function_nodes[exit];
    // The arm's result typed differently from the merge that would have read it.
    body[exit].node.value_type = .logic;
    try harness.invalid(h, forged);
    body[exit] = p.function_nodes[exit];
    // Metadata that hides the exit: fewer control operations, or none.
    functions[0].control_ops -= 1;
    try harness.invalid(h, forged);
    functions[0] = p.functions[0];
    // An exit outside every function.
    var literal: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .integer) {
        literal = index;
    };
    try std.testing.expect(literal + 1 < p.nodes.len);
    roots[literal + 1] = .{ .span = p.nodes[literal + 1].span, .value_type = p.nodes[literal + 1].value_type, .kind = .{ .exit = @intCast(literal) } };
    try harness.invalid(h, forged);
    roots[literal + 1] = p.nodes[literal + 1];
    _ = try h.run(forged, 10_000);
}

test "forged runtime errors are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("F(N:i64)<computes>:i64=If(N>0,N+2,Err(\"stop\"))\nA<public>:i64=F(3)\nB<public>:i64=If(true,4,Err(\"root\"))");
    const body = try std.testing.allocator.dupe(types.FunctionNode, p.function_nodes);
    defer std.testing.allocator.free(body);
    const roots = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(roots);
    var forged = p;
    forged.function_nodes = body;
    forged.nodes = roots;
    const err = functionNode(p, .err);
    const condition = p.function_nodes[functionNode(p, .if_begin)].node.kind.if_begin.condition;
    _ = try h.run(forged, 10_000);
    // A message that is not a string, one that is not computed yet, and a type that does not exist.
    body[err].node.kind.err = condition;
    try harness.invalid(h, forged);
    body[err].node.kind.err = @intCast(err);
    try harness.invalid(h, forged);
    body[err] = p.function_nodes[err];
    body[err].node.value_type = @fromBackingInt(@as(u16, @intCast(4 + p.definitions.len)));
    try harness.invalid(h, forged);
    body[err] = p.function_nodes[err];
    var root: usize = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .err) {
        root = index;
    };
    try std.testing.expect(p.nodes[root].kind == .err);
    roots[root].kind.err = @intCast(root);
    try harness.invalid(h, forged);
    roots[root].kind.err = 0;
    try std.testing.expect(p.nodes[0].value_type != .string);
    try harness.invalid(h, forged);
    roots[root] = p.nodes[root];
    _ = try h.run(forged, 10_000);
}

test "the report replay checks every exit step against its own run" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Cell:i64=0\nF(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+N;If(N>0,Return(Cell),false);Fail[\"no\"];0},-1)\nA<public>:i64=F(4)\nB<public>:i64=Cell");
    try expectIntegers(x, &.{ .{ "A", 4 }, .{ "B", 4 } });
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    var forged = x;
    forged.call_steps = steps;
    var exit: usize = 0;
    var exits: usize = 0;
    for (steps, 0..) |step, index| if (step.kind == .exit) {
        exit = index;
        exits += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), exits);
    const budget: reporting.Limits = .{ .work = @max(1024 * 1024, types.limits.report_work) };
    _ = try reporting.validate(forged, false, budget);
    // Another value, another kind of step, and an exit where the body has none.
    steps[exit].value = .{ .integer = 5 };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, budget));
    steps[exit].value = .{ .boolean = true };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, budget));
    steps[exit] = x.call_steps[exit];
    steps[exit].kind = .value;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, budget));
    steps[exit].kind = .failure;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, budget));
    steps[exit] = x.call_steps[exit];
    steps[exit - 1].kind = .exit;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, budget));
    steps[exit - 1] = x.call_steps[exit - 1];
    _ = try reporting.validate(forged, false, budget);
}

/// What `Run(A, B, C)` of the oracle program does, written directly: two nested loops with a
/// `Defer` per scope, a `Break` each, a `Return` from the inner one and a region that fails every
/// third time. `trace` is the cell the program's `Note` folds numbers into.
fn modelNote(trace: *i64, value: i64) void {
    trace.* = @mod(trace.* * 7 + value, 1000003);
}
fn modelRun(a: i64, b: i64, c: i64, trace: *i64) i64 {
    var i: i64 = 0;
    var acc: i64 = 0;
    while (true) {
        if (i >= a) {
            modelNote(trace, i);
            break;
        }
        i += 1;
        var j: i64 = 0;
        while (true) {
            if (j >= b) {
                modelNote(trace, 100 + j);
                break;
            }
            j += 1;
            acc += i * j;
            if (acc > c) {
                // Innermost first: the inner visit, the outer visit, the function.
                modelNote(trace, 100 + j);
                modelNote(trace, i);
                modelNote(trace, acc);
                return acc;
            }
            const saved = trace.*;
            modelNote(trace, 200);
            acc += 1;
            if (@mod(i + j, 3) == 0) {
                // The region fails: its note and its write to the local are undone.
                trace.* = saved;
                acc -= 1;
                modelNote(trace, 300);
            }
            modelNote(trace, 100 + j);
        }
        modelNote(trace, i);
    }
    modelNote(trace, acc);
    return -acc;
}

test "random loops with Defer, Break, Return and a failing region match a direct model" {
    const h = try harness.create();
    defer scratch.release(h);
    const program =
        \\var Trace:i64=0
        \\Note(D:i64)<transacts>:i64=Set(Trace,(Trace*7+D)-((Trace*7+D)/1000003)*1000003)
        \\Run(A:i64,B:i64,C:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  var Acc:i64=0
        \\  Defer{Note(Acc)}
        \\  Loop{
        \\    Defer{Note(I)}
        \\    If(I>=A,Break(),false)
        \\    set I=I+1
        \\    var J:i64=0
        \\    Loop{
        \\      Defer{Note(100+J)}
        \\      If(J>=B,Break(),false)
        \\      set J=J+1
        \\      set Acc=Acc+I*J
        \\      If(Acc>C,Return(Acc),false)
        \\      Attempt(Block{Note(200);set Acc=Acc+1;Require[(I+J)-((I+J)/3)*3!=0];0},Note(300))
        \\    }
        \\  }
        \\  0-Acc
        \\}
        \\
    ;
    var random = std.Random.DefaultPrng.init(0x6813_0068);
    var returned: usize = 0;
    var completed: usize = 0;
    var text: [2048]u8 = undefined;
    for (0..40) |_| {
        const a = random.random().intRangeAtMost(i64, 0, 3);
        const b = random.random().intRangeAtMost(i64, 0, 3);
        const c = random.random().intRangeAtMost(i64, 0, 30);
        const source = try std.fmt.bufPrint(&text, "{s}R<public>:i64=Run({d},{d},{d})\nT<public>:i64=Trace", .{ program, a, b, c });
        const x = try h.execute(source);
        var trace: i64 = 0;
        const expected = modelRun(a, b, c, &trace);
        if (x.get("R").?.integer != expected or x.get("T").?.integer != trace) std.debug.print("Run({d},{d},{d}): expected {d} trace {d}, found {d} trace {d}\n", .{ a, b, c, expected, trace, x.get("R").?.integer, x.get("T").?.integer });
        try std.testing.expectEqual(expected, x.get("R").?.integer);
        try std.testing.expectEqual(trace, x.get("T").?.integer);
        if (expected > 0) returned += 1 else completed += 1;
    }
    // Both ways out of the function were taken.
    try std.testing.expect(returned >= 5 and completed >= 5);
}

test "a function that returns from the innermost of thirty conditionals" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // One level below the bootstrap control depth, which the body's own conditionals fill.
    const depth = types.limits.control_depth - 1;
    var text: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&text);
    try out.writeAll("var Cell:i64=0\nF(N:i64)<transacts>:i64=Block{");
    for (0..depth) |level| try out.print("If(N>{d},Block{{set Cell=Cell+1;", .{level});
    try out.writeAll("Return(Cell*1000+N)");
    for (0..depth) |_| try out.writeAll("},false)");
    try out.writeAll(";0-N}\nA<public>:i64=F(31)\nB<public>:i64=F(5)\nC<public>:i64=Cell");
    const x = try h.execute(out.buffered());
    // F(31) passes every test and returns from the innermost block; F(5) stops at the sixth test.
    try expectIntegers(x, &.{ .{ "A", 31 * 1000 + 31 }, .{ "B", -5 }, .{ "C", 31 + 5 } });
}

test "exits fit every typed position the contract names" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64=array{5,6}
        \\var Cell:i64=0
        \\NumberOfBits(X:i64)<transacts>:i64=Block{
        \\  var B:i64=1
        \\  var C:i64=0
        \\  Loop{
        \\    set B=If(B>X,Break(),2*B)
        \\    set C=C+1
        \\  }
        \\  C
        \\}
        \\Same[T:type](X:T)<computes>:T{Return(X)}
        \\Arm(N:i64)<computes>:i64=Case(N,0=>Return(10),1=>Return(11),_=>N)
        \\Fallback(I:i64)<computes>:i64=Block{
        \\  Attempt(Items[I],Return(-1))+1
        \\}
        \\Typed(N:i64)<computes>:i64=Block{
        \\  Y:i64=If(N<0,Return(0),N*2)
        \\  Z:=If(N>100,Err("large"),Y+1)
        \\  Z
        \\}
        \\Empty(N:i64)<computes>:[]i64=Block{If(N>0,Return(array{}),false);array{N}}
        \\Through()<transacts>:i64=Block{
        \\  var N:i64=0
        \\  Loop{
        \\    var I:i64=0
        \\    While(I<5,Block{set I=I+1;set N=N+1;If(N>=7,Break(),false)})
        \\  }
        \\  N
        \\}
        \\Strict(N:i64)<transacts><decides>:i64=Block{
        \\  var I:i64=0
        \\  Loop{set Cell=Cell+1;Require[I<N];set I=I+1;If(I>=3,Break(),false)}
        \\  I
        \\}
        \\A<public>:i64=NumberOfBits(8)*10+NumberOfBits(0)
        \\B<public>:i64=Same[i64](7)
        \\C<public>:i64=Arm(0)+Arm(1)+Arm(5)
        \\D<public>:i64=Fallback(1)*100+Fallback(9)
        \\E<public>:i64=Typed(-3)+Typed(4)
        \\F<public>:i64=Empty(1).Length*10+Empty(0).Length
        \\G<public>:i64=Through()
        \\H<public>:i64=Attempt(Strict[5],-1)
        \\I<public>:i64=Cell
        \\J<public>:i64=Attempt(Strict[1],-1)
        \\K<public>:i64=Cell
    );
    // NumberOfBits is the Book's example of `break` in a typed position. Through: the Break inside
    // the While leaves the Loop{} around it with both counters as they are. Strict[1] fails in
    // its second visit, and the failure of the function undoes the writes of both visits.
    try expectIntegers(x, &.{ .{ "A", 40 }, .{ "B", 7 }, .{ "C", 26 }, .{ "D", 699 }, .{ "E", 9 }, .{ "F", 1 }, .{ "G", 7 }, .{ "H", 3 }, .{ "I", 3 }, .{ "J", -1 }, .{ "K", 3 } });
    try expectCode(h, "F()<transacts>:i64=Block{Loop{Require[true];Break()};1}", .failure_context_required);
}

test "Defer runs on every way out of a For and of the loops around it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(noted ++
        \\Items:[]i64=array{5,6}
        \\Reset()<transacts>:i64=Set(Trace,0)
        \\Walk(T:i64)<transacts>:i64=Block{
        \\  Defer{Note(9)}
        \\  For(X:Items,Block{Defer{Note(X)};If(X==T,Return(X*10),false);0})
        \\  0
        \\}
        \\Rounds()<transacts>:i64=Block{
        \\  var R:i64=0
        \\  Loop{
        \\    Defer{Note(1)}
        \\    set R=R+1
        \\    For(X:Items,Block{Defer{Note(2)};If(X*R>10,Break(),false);0})
        \\  }
        \\  R
        \\}
        \\A<public>:i64=Walk(6)
        \\TA<public>:i64=Trace
        \\B<public>:i64=Reset()+Walk(1)
        \\TB<public>:i64=Trace
        \\C<public>:i64=Reset()+Rounds()
        \\TC<public>:i64=Trace
    );
    // Walk(6): the first element's Defer, the second's on the Return, then the function's.
    // Rounds: round one runs 5 and 6 (two 2s) and ends (1); in round two 5*2 is not above 10
    // (2), 6*2 is, so the Break runs the iteration's Defer (2) and the visit's (1).
    try expectIntegers(x, &.{ .{ "A", 60 }, .{ "TA", 569 }, .{ "B", 0 }, .{ "TB", 569 }, .{ "C", 2 }, .{ "TC", 221221 } });
}

test "an exit in a loop's condition, filter or generator leaves from where that code runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Items:[]i64=array{1,2,3}
        \\Plain()<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{
        \\    While(If(I>3,Break(),true),Block{set I=I+1})
        \\    set I=I+100
        \\  }
        \\  I
        \\}
        \\Rounds()<transacts>:i64=Block{
        \\  var I:i64=0
        \\  var R:i64=0
        \\  Loop{
        \\    set R=R+1
        \\    While(If(I>3,Break(),true),Block{set I=I+1})
        \\    If(R>=3,Break(),false)
        \\  }
        \\  R*10+I
        \\}
        \\Bound(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  While(X:=Items[I],If(X>N,Return(X*100+I),true),set I=I+1)
        \\  0-I
        \\}
        \\Filtered(N:i64)<transacts>:i64=Block{
        \\  var Seen:i64=0
        \\  Loop{
        \\    set Seen=Seen+1
        \\    For(X:Items,If(X*Seen>N,Break(),true),Y:=X+1,Y)
        \\  }
        \\  Seen
        \\}
        \\Sourced(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  var Sum:i64=0
        \\  Loop{
        \\    set I=I+1
        \\    Xs:=For(X:If(I>N,Break(),Items),X*I)
        \\    set Sum=Sum+Xs.Length
        \\  }
        \\  Sum
        \\}
        \\Inner(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{
        \\    set I=I+1
        \\    For(X:Items,Y:If(X*I>N,Break(),Items),X+Y)
        \\  }
        \\  I
        \\}
        \\A<public>:i64=Plain()
        \\B<public>:i64=Rounds()
        \\C<public>:i64=Bound(1)
        \\D<public>:i64=Bound(9)
        \\E<public>:i64=Filtered(7)
        \\F<public>:i64=Sourced(2)
        \\G<public>:i64=Inner(5)
    );
    // Plain and Rounds: the Break in the While's condition leaves the Loop{} with I as it is.
    // Bound: the Return in a condition after a binding. Filtered: 3*3 is the first product
    // above 7 (a For that something leaves builds no array, so its body is a statement and may
    // not be a bare comparison: RFC-0076 rule 5). Sourced: the source of a For's first generator runs before the For, so the For
    // keeps its array (two rounds of three). Inner: a later generator's source runs in the loop.
    try expectIntegers(x, &.{ .{ "A", 4 }, .{ "B", 14 }, .{ "C", 201 }, .{ "D", -3 }, .{ "E", 3 }, .{ "F", 6 }, .{ "G", 2 } });
}

test "a Defer body that is copied may hold functions, loops and a Case of its own" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(noted ++
        \\Items:[]i64=array{1,2}
        \\Reset()<transacts>:i64=Set(Trace,0)
        \\Closure(N:i64)<transacts>:i64=Block{
        \\  X:i64=3
        \\  Defer{K:=Fn(Y:i64)<transacts>:i64{Note(X+Y)};K(5)}
        \\  If(N>0,Return(N),false)
        \\  7
        \\}
        \\Iterated(N:i64)<transacts>:i64=Block{
        \\  Defer{Note(Iterate(Fn(S:i64)<computes>:i64{S+N},2,0))}
        \\  If(N>0,Return(N),false)
        \\  7
        \\}
        \\Visits(N:i64)<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Loop{
        \\    Defer{K:=Fn(Y:i64)<transacts>:i64{Note(Y+N)};K(5)}
        \\    set I=I+1
        \\    If(I>N,Break(),false)
        \\  }
        \\  7
        \\}
        \\Loops(N:i64)<transacts>:i64=Block{
        \\  Defer{
        \\    var J:i64=0
        \\    For(X:Items,Note(X))
        \\    While(J<2,Block{set J=J+1;Note(3)})
        \\    Loop{set J=J+1;If(J>3,Break(),false)}
        \\    Note(Case(J,4=>4,_=>0))
        \\  }
        \\  If(N==1,Return(1),false)
        \\  If(N==2,Return(2),false)
        \\  If(N==3,Return(3),false)
        \\  If(N==4,Return(4),false)
        \\  If(N==5,Return(5),false)
        \\  0
        \\}
        \\A<public>:i64=Closure(1)*10+Closure(0)
        \\TA<public>:i64=Trace
        \\B<public>:i64=Reset()+Iterated(1)*10+Iterated(0)
        \\TB<public>:i64=Trace
        \\C<public>:i64=Reset()+Visits(1)*10+Visits(0)
        \\TC<public>:i64=Trace
        \\D<public>:i64=Reset()+Loops(5)
        \\TD<public>:i64=Trace
        \\E<public>:i64=Reset()+Loops(0)
        \\TE<public>:i64=Trace
    );
    // Each copy of the body has functions of its own. Loops: 1 and 2 from the For, 3 twice from
    // the While, the Loop{} counts J to 4, and the Case notes it; six copies of all of that.
    try expectIntegers(x, &.{ .{ "A", 17 }, .{ "TA", 88 }, .{ "B", 17 }, .{ "TB", 20 }, .{ "C", 77 }, .{ "TC", 665 }, .{ "D", 5 }, .{ "TD", 12334 }, .{ "E", 0 }, .{ "TE", 12334 } });
}

test "a Defer inside the body of a For or While that nothing leaves counts from that body" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(noted ++
        \\Items:[]i64=array{5,6}
        \\Reset()<transacts>:i64=Set(Trace,0)
        \\Whiled()<transacts>:i64=Block{
        \\  var I:i64=0
        \\  Defer{Note(9)}
        \\  While(I<3,Block{Defer{Note(I)};set I=I+1})
        \\  0
        \\}
        \\Plain()<transacts>:i64=Block{Defer{Note(9)};For(X:Items,Block{Defer{Note(X)};0});7}
        \\Pairs()<transacts>:i64=Block{Defer{Note(9)};For(X:Items,Y:Items,Block{Defer{Note(X)};Note(Y)});7}
        \\Ranged()<transacts>:i64=Block{Defer{Note(9)};Defer{Note(8)};For(X:1..2,Block{Defer{Note(X)};0});7}
        \\Kept()<transacts>:i64=Block{Defer{Note(9)};For(X:Items,X>5,Block{Defer{Note(X)};0});7}
        \\A<public>:i64=Whiled()
        \\TA<public>:i64=Trace
        \\B<public>:i64=Reset()+Plain()
        \\TB<public>:i64=Trace
        \\C<public>:i64=Reset()+Pairs()
        \\TC<public>:i64=Trace
        \\D<public>:i64=Reset()+Ranged()
        \\TD<public>:i64=Trace
        \\E<public>:i64=Reset()+Kept()
        \\TE<public>:i64=Trace
    );
    try expectIntegers(x, &.{ .{ "A", 0 }, .{ "TA", 1239 }, .{ "B", 7 }, .{ "TB", 569 }, .{ "C", 7 }, .{ "TC", 556556669 }, .{ "D", 7 }, .{ "TD", 1289 }, .{ "E", 7 }, .{ "TE", 69 } });
}

test "only an exit written in an arm takes the other arm's type, never a name bound to one" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        // A name has the type it was given, also when what it was bound to never yields.
        "F(N:i64)<computes>:i64=Block{Y:logic=Err(\"x\");Z:=Y and true;If(N>0,Y,5)}\nA<public>:i64=F(0)",
        "F(N:i64)<computes>:i64=Block{Y:logic=true;If(N>0,Y,5)}\nA<public>:i64=F(0)",
        "F(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{set I=I+1;Y:=Break();Z:=Y and true;set I=If(N>0,Y,5)};I}\nA<public>:i64=F(0)",
    }) |source| try expectCode(h, source, .type_mismatch);
    // The exit itself, and blocks that end in it, still fit.
    const x = try h.execute(
        \\F(N:i64)<computes>:i64=If(N>0,Block{Block{Err("x")}},5)
        \\G(N:i64)<computes>:i64=Block{Y:logic=If(N>100,Err("y"),true);If(Y,N,0)}
        \\A<public>:i64=F(0)+G(4)
    );
    try expectIntegers(x, &.{.{ "A", 9 }});
}

test "both machines stop at the same node for every budget of programs that exit" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "var Cell:i64=0\nItems:[]i64=array{5,6}\nF(T:i64)<transacts>:i64=Block{var I:i64=0;Defer{set Cell=Cell+1};Loop{Defer{set Cell=Cell+10};set I=I+1;For(X:Items,If(X*I>T,Return(X*I),false));If(I>3,Break(),false)};0-I}\nA<public>:i64=F(11)\nB<public>:i64=F(100)\nC<public>:i64=Cell",
        "var Cell:i64=0\nIn(N:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Attempt(Block{set Cell=Cell+10;If(N>0,Return(Cell),false);Fail[\"no\"];0},-1)},-2)\nOut(N:i64)<transacts>:i64=Attempt(Block{X:=In(N);Require[N>1];X},Cell)\nA<public>:i64=Out(0)\nB<public>:i64=Out(1)\nC<public>:i64=Out(2)\nD<public>:i64=Cell",
        "F(N:i64)<transacts>:i64=Block{var I:i64=0;var J:i64=0;Loop{set I=I+1;While(J<I*2,Block{set J=J+1;If(J>N,Break(),false)})};I*100+J}\nA<public>:i64=F(5)",
        "S(X:i64)<computes>:i64=Block{If(X>3,Return(X),false);X+2}\nA<public>:i64=Iterate(S,5,0)\nT(X:i64)<computes>:option(i64)=Block{If(X>3,Return(option{}),false);option{X+2}}\nB<public>:i64=Loop(T,0)",
    }) |source| {
        const p = try h.compile(source);
        var fuel: u64 = 0;
        // `run` compares the two machines' diagnostics; every budget below the need is `work_limit`.
        const done = while (fuel < 4000) : (fuel += 1) {
            const r = try h.run(p, fuel);
            if (r == .ok) break true;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, r.failed.code);
        } else false;
        try std.testing.expect(done);
    }
}

test "a program without the new forms has the library block and the positions it had" {
    const h = try harness.create();
    defer scratch.release(h);
    const macros = @import("macros.zig");
    // Two generators per `For` take more `Fn` words than the pool holds, so the last two come
    // from the block's generated line of words, behind every template. Where the eight functions
    // are named was measured with the compiler as it was before RFC-0068; an inspection prints
    // these positions, so they must not move. (The two on the generated line stand a line of
    // `Case` words earlier than then: every block had that line, and now only a module with a
    // pattern `Case` has it.)
    const plain = "Items:[]i64=array{1,2}\nA<public>:[]i64=For(X:Items,Y:Items,X*Y)\nB<public>:[]i64=For(X:Items,Y:Items,X+Y)\n";
    const before = try h.compile(plain);
    const case_line: u32 = macros.case_text.len + 2;
    const expected = [_]u32{ 110, 113, 107, 116, 122, 3289 - case_line, 119, 3292 - case_line };
    try std.testing.expectEqual(expected.len, before.functions.len);
    for (before.functions, expected) |f, start| try std.testing.expectEqual(start, f.name.start);
    try std.testing.expect(std.mem.indexOf(u8, before.source, "__exit") == null);
    try std.testing.expect(std.mem.endsWith(u8, before.source, "Fn \n#}"));
    // A module that uses the early-exit forms carries their words as its last line; what stood
    // before that line stands where it stood.
    const more = "C<public>:logic=Loop{Break()}\n";
    const with = try h.compile(plain ++ more);
    try std.testing.expect(std.mem.endsWith(u8, with.source, macros.exit_words ++ "\n#}"));
    try std.testing.expectEqual(expected.len + 1, with.functions.len);
}

// What follows was written when RFC-0068 was merged onto RFC-0066 (`Case` patterns), RFC-0070
// (`Quotient`, `Mod`, `rational`) and RFC-0072 (`First`, `logic{...}`, a catching `option{...}`):
// the forms of those increments used together with the exits, which neither side could test.

fn expectRational(x: evaluator.Execution, name: []const u8, numerator: i64, denominator: i64) !void {
    const value = x.get(name) orelse return error.Missing;
    try std.testing.expectEqualDeep(types.Rational{ .numerator = numerator, .denominator = denominator }, value.rational);
}

test "an exit that would leave a First[...] is refused by name; exits beside or wholly inside one work" {
    const h = try harness.create();
    defer scratch.release(h);
    // The clauses and the body of a `First` run in the functions of its levels, which carry no
    // exit state: a `Return` or `Break` there is not taken for an exit of such a function.
    const items = "Xs:[]i64=array{1,5,9}\n";
    try expectCode(h, items ++ "F(N:i64)<computes><decides>:i64=Block{Y:=First[X:Xs,X>N,If(X>6,Return(-1),X)];Y+100}\n", .first_exit);
    try expectCode(h, items ++ "F(N:i64)<computes><decides>:i64=Block{Y:=First[X:Xs,If(X>N,Return(X),true),X];Y+100}\n", .first_exit);
    try expectCode(h, items ++ "F(N:i64)<computes><decides>:i64=First[X:Xs,Y:If(X>N,Return(X),Xs),X+Y]\n", .first_exit);
    try expectCode(h, items ++ "F(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{set I=I+1;Y:=Attempt(First[X:Xs,X>I,If(X>6,Break(),X)],0)};I}\n", .first_exit);
    try expectCode(h, items ++ "F(N:i64)<transacts>:i64=Block{For(I:1..3,Attempt(First[X:Xs,X>I,Block{If(X>6,Return(I),false);X}],0));0}\n", .first_exit);
    // The diagnostic names the exit, not the form.
    const source = items ++ "F(N:i64)<computes><decides>:i64=First[X:Xs,X>N,If(X>6,Return(-1),X)]\n";
    const refused = h.front.compile(source).failed;
    try std.testing.expectEqualStrings("Return", refused.span.text(source));
    try std.testing.expectEqualStrings("Return and Break cannot leave a First[...]", refused.message());
    // Directly as the body it is no tail position at all, as in any bracket.
    try expectCode(h, items ++ "F(N:i64)<computes><decides>:i64=Block{Y:=First[X:Xs,X>N,Return(X)];Y+100}\n", .return_not_tail);

    const x = try h.execute(items ++
        // A `First` in a loop that is left: the exits stand beside it.
        \\Digits(N:i64)<transacts>:i64=Block{var I:i64=0;var S:i64=0;Loop{set I=I+1;Y:=Attempt(First[X:Xs,X>I,X],0);If(Y==0,Break(),false);set S=S*10+Y};S}
        \\Reach(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{set I=I+1;Y:=Attempt(First[X:Xs,X>I,X],0);If(Y>N,Return(Y*1000+I),false)};0}
        \\Each(N:i64)<transacts>:i64=Block{For(I:1..9,Block{Y:=Attempt(First[X:Xs,X>I,X],0);If(Y>N,Return(Y*10+I),false)});0}
        // The first source runs in the code around the form, so an exit there leaves that code.
        \\Source(N:i64)<computes><decides>:i64=First[X:If(N<0,Return(-7),Xs),X>N,X]
        // A `Loop{}` and a function of the user's inside the body keep their exits to themselves.
        \\Inner(N:i64)<transacts><decides>:i64=First[X:Xs,X>N,Block{var I:i64=0;Loop{set I=I+X;If(I>20,Break(),false)};G:=Fn(Z:i64):i64{If(Z>5,Return(Z*2),Z)};G(X)*100+I}]
        \\A<public>:i64=Digits(0)
        \\B<public>:i64=Reach(5)
        \\C<public>:i64=Each(5)
        \\D<public>:i64=Attempt(Source[-3],0)
        \\E<public>:i64=Attempt(Source[4],0)
        \\F<public>:i64=Attempt(Source[9],0)
        \\G<public>:i64=Attempt(Inner[0],0)
        \\H<public>:i64=Attempt(Inner[5],0)
    );
    // Digits: the first element above 1..4 is 5, above 5..8 is 9, above 9 there is none.
    // Inner(0): X=1, the loop runs to 21 and G(1) is 1. Inner(5): X=9, 27 and G(9) returns 18.
    try expectIntegers(x, &.{ .{ "A", 55559999 }, .{ "B", 9005 }, .{ "C", 95 }, .{ "D", -7 }, .{ "E", 5 }, .{ "F", 0 }, .{ "G", 121 }, .{ "H", 1827 } });
}

test "Return and Break leave from the arms and guards of Case patterns" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Log:i64=0
        \\Ps:[]tuple(i64,i64)=array{tuple{1,2},tuple{0,7},tuple{30,4}}
        \\Arms(M:option(i64))<transacts>:i64=Block{set Log=Log+1;Case(M,option{X} where X>10 => Return(X),option{X} => Block{set Log=Log+10;X+1},option{} => Return(-1));set Log=Log+100;7}
        \\Walk(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{P:=Attempt(Ps[I],tuple{0,0});set I=I+1;Case(P,tuple{0,Y} where Y>N => Return(Y*100+I),tuple{X,_} where X>10 => Break(),_ => false)};I}
        \\Scan(N:i64)<transacts>:i64=Block{For(P:Ps,Case(P,tuple{0,Y} => Return(Y+N),_ => false));-1}
        \\Guard(M:option(i64))<transacts>:i64=Block{R:=Case(M,option{X} where Block{set Log=Log+1000;If(X>10,Return(X),X>0)} => 1,_ => 0);set Log=Log+10000;R}
        \\A<public>:i64=Arms(option{50})
        \\B<public>:i64=Arms(option{3})
        \\C<public>:i64=Arms(option{})
        \\D<public>:i64=Log
        \\E<public>:i64=Walk(5)
        \\F<public>:i64=Walk(9)
        \\G<public>:i64=Scan(1)
        \\H<public>:i64=Guard(option{50})
        \\I<public>:i64=Log
        \\J<public>:i64=Guard(option{3})
        \\K<public>:i64=Guard(option{-3})
        \\L<public>:i64=Log
    );
    // Arms: 1, then 1+10+100, then 1. Walk(5) returns at the second pair; Walk(9) passes it and
    // breaks at the third. A guard runs in a region of its own: the `Return` in it commits that
    // region (the 1000 stays), a guard that holds keeps its write, and one that fails loses it.
    try expectIntegers(x, &.{ .{ "A", 50 }, .{ "B", 7 }, .{ "C", -1 }, .{ "D", 113 }, .{ "E", 702 }, .{ "F", 3 }, .{ "G", 8 }, .{ "H", 50 }, .{ "I", 1113 }, .{ "J", 1 }, .{ "K", 0 }, .{ "L", 22113 } });
    // A guard is a condition, not an arm: an exit is not its last word.
    try expectCode(h, "F(M:option(i64))<computes>:i64=Case(M,option{X} where Return(X) => 1,_ => 0)\n", .return_not_tail);
}

test "an exit inside logic{} or a catching option{} leaves with its effects kept" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=0
        \\Xs:[]i64=array{1,5,9}
        \\Asked(N:i64)<transacts>:i64=Block{B:=logic{set Cell=Cell+1;Y:=Xs[N];If(Y>4,Return(Y*10),false)};set Cell=Cell+100;If(B,1,0)}
        \\Last(N:i64)<transacts>:i64=Block{B:=logic{set Cell=Cell+1;Y:=Xs[N];Return(Y*10)};set Cell=Cell+100;If(B,1,0)}
        \\Held(N:i64)<transacts>:i64=Block{O:=option{Block{set Cell=Cell+1;Y:=Xs[N];If(Y>4,Return(Y*10),Y)}};set Cell=Cell+100;Attempt(O?,-1)}
        \\Both(N:i64)<transacts>:i64=Block{var I:i64=0;var S:i64=0;Loop{O:=option{Block{set Cell=Cell+1;Y:=Xs[I];If(Y>N,Return(Y*10+I),Y)}};B:=logic{set Cell=Cell+10;Y:=Xs[I];If(Y==5,Break(),false)};set I=I+1;If(B,false,Break());set S=S+1};S*1000+I}
        \\Reset()<transacts>:i64=Set(Cell,0)
        \\A<public>:i64=Asked(1)
        \\B<public>:i64=Cell
        \\C<public>:i64=Asked(0)
        \\D<public>:i64=Cell
        \\E<public>:i64=Asked(7)
        \\F<public>:i64=Cell
        \\G<public>:i64=Last(1)+Last(7)
        \\H<public>:i64=Cell+Reset()
        \\I<public>:i64=Held(1)
        \\J<public>:i64=Cell
        \\K<public>:i64=Held(0)
        \\L<public>:i64=Held(7)
        \\M<public>:i64=Cell
        \\N<public>:i64=Both(7)
        \\Q<public>:i64=Cell+Reset()
        \\O<public>:i64=Both(0)
        \\P<public>:i64=Cell
    );
    // An exit is no failure: `Asked(1)` and `Held(1)` return 50 and keep the write made inside
    // the caught expression, where a failure (`Asked(7)`, `Held(7)`) undoes it and goes on.
    // `Last(1)` returns 50 and keeps its 1; `Last(7)` fails inside and yields 0: 203 + 100.
    // `Both(7)`: the first visit goes round, the second breaks out of the `logic{...}` with
    // both visits' writes in place (202 + 22). `Both(0)` returns from inside the
    // `option{...}` on its first visit.
    try expectIntegers(x, &.{ .{ "A", 50 }, .{ "B", 1 }, .{ "C", 1 }, .{ "D", 102 }, .{ "E", 0 }, .{ "F", 202 }, .{ "G", 50 }, .{ "H", 303 }, .{ "I", 50 }, .{ "J", 1 }, .{ "K", 1 }, .{ "L", -1 }, .{ "M", 202 }, .{ "N", 1001 }, .{ "Q", 224 }, .{ "O", 10 }, .{ "P", 1 } });
    // An exit alone cannot fail, so `logic{...}` has nothing to ask; and a constructor's member
    // is no tail position.
    try expectCode(h, "F(N:i64)<computes>:i64=Block{B:=logic{Return(N)};If(B,1,0)}\n", .failure_expected);
    try expectCode(h, "F(N:i64)<computes>:i64=Block{B:=option{Return(N)};1}\n", .return_not_tail);
    // A loop inside `logic{...}` fails into it. Inside an `option{...}` that stands outside
    // every failure context, the loop's function is a function like any other the constructor
    // holds: what fails in it is not caught (RFC-0072), and the program is told so.
    const y = try h.execute(
        \\var Cell:i64=0
        \\Xs:[]i64=array{1,5,9}
        \\Sum(N:i64)<transacts>:i64=Block{B:=logic{Block{var I:i64=N;var S:i64=0;Loop{set Cell=Cell+1;set S=S+Xs[I];set I=I+1;If(S>5,Break(),false)};S}};If(B,1,0)}
        \\Each(N:i64)<transacts>:i64=Block{O:=option{Block{For(I:0..5,If(Xs[I]>N,Return(I*10),false));7}};Attempt(O?,-1)}
        \\A<public>:i64=Sum(0)
        \\B<public>:i64=Cell
        \\C<public>:i64=Sum(2)
        \\D<public>:i64=Cell
        \\E<public>:i64=Sum(3)
        \\F<public>:i64=Cell
        \\G<public>:i64=Each(4)
        \\H<public>:i64=Each(100)
    );
    try expectIntegers(y, &.{ .{ "A", 1 }, .{ "B", 2 }, .{ "C", 1 }, .{ "D", 3 }, .{ "E", 0 }, .{ "F", 3 }, .{ "G", 10 }, .{ "H", 7 } });
    try expectCode(h, "Xs:[]i64=array{1,5,9}\nF(N:i64)<transacts>:i64=Block{O:=option{Block{var I:i64=N;var S:i64=0;Loop{set S=S+Xs[I];set I=I+1;If(S>5,Break(),false)};S}};Attempt(O?,-1)}\n", .failure_context_required);
}

test "rational values are returned early, carried by a Loop{} and handed out of a For" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Kept:rational=MakeRationalFromInt(0)
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\Half(N:i64)<computes>:rational=Block{If(N<0,Return(R(N,-2)),false);If(N==0,Return(MakeRationalFromInt(0)),false);R(N,2)}
        \\Sum(N:i64)<transacts>:rational=Block{var Acc:rational=MakeRationalFromInt(0);var I:i64=0;Loop{set I=I+1;If(I>N,Break(),false);set Acc=Acc+R(1,I)};Acc}
        \\Find(Qs:[]rational,T:rational)<transacts>:rational=Block{Defer{set Kept=Kept+T};For(Q:Qs,If(Q>T,Return(Q*R(2,1)),false));R(-1,1)}
        \\Exact(A:i64,B:i64)<computes><decides>:rational=Block{If(B==1,Return(MakeRationalFromInt(A)),false);Rational[A,B]}
        \\A<public>:rational=Half(-3)
        \\B<public>:rational=Half(0)
        \\C<public>:rational=Half(5)
        \\D<public>:rational=Sum(4)
        \\E<public>:rational=Find(array{R(1,3),R(2,3),R(5,6)},R(1,2))
        \\F<public>:rational=Find(array{R(1,3)},R(1,2))
        \\G<public>:rational=Kept
        \\H<public>:rational=Attempt(Exact[7,1],R(9,1))
        \\I<public>:rational=Attempt(Exact[7,0],R(9,1))
        \\J<public>:i64=Floor(Sum(3))
    );
    try expectRational(x, "A", 3, 2);
    try expectRational(x, "B", 0, 1);
    try expectRational(x, "C", 5, 2);
    // 1 + 1/2 + 1/3 + 1/4.
    try expectRational(x, "D", 25, 12);
    try expectRational(x, "E", 4, 3);
    try expectRational(x, "F", -1, 1);
    try expectRational(x, "G", 1, 1);
    try expectRational(x, "H", 7, 1);
    try expectRational(x, "I", 9, 1);
    try expectIntegers(x, &.{.{ "J", 1 }});
}

test "a Defer body may use Quotient, Mod, First, logic{} and an option{} of its own, and nothing around it catches what it lets out" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Trace:i64=0
        \\Xs:[]i64=array{1,5,9}
        \\Halves(N:i64)<transacts>:i64=Block{Defer{set Trace=Trace*100+Attempt(Quotient[N,2],0)*10+Attempt(First[X:Xs,X>N,X],0)};If(N>6,Return(1),false);If(N>2,Return(2),false);3}
        \\Kinds(N:i64)<transacts>:i64=Block{Defer{O:=option{First[X:Xs,X>N,X]};set Trace=Trace*10+Attempt(O?,0)};Defer{If(Q:=Mod[N,4],Q>=0,Block{set Trace=Trace*10+Q;true},false)};If(N>6,Return(1),false);3}
        \\Asks(N:i64)<transacts>:i64=Block{Defer{set Trace=Trace*10+If(logic{Xs[N]},1,2)};If(N>1,Return(4),false);3}
        \\Strict(N:i64)<transacts><decides>:i64=Block{Defer{O:=option{Xs[N]};set Trace=Trace*10+Attempt(O?,7)};Xs[N]}
        \\Take()<transacts>:i64=Block{T:=Trace;set Trace=0;T}
        \\A<public>:i64=Halves(8)+Halves(4)*10+Halves(-1)*100
        \\B<public>:i64=Take()
        \\C<public>:i64=Kinds(7)+Kinds(4)*10
        \\D<public>:i64=Take()
        \\E<public>:i64=Asks(1)+Asks(5)*10
        \\F<public>:i64=Take()
        \\G<public>:i64=Attempt(Strict[1],-1)
        \\H<public>:i64=Attempt(Strict[5],-1)
        \\I<public>:i64=Take()
    );
    // Halves: 4 and 9, then 2 and 5, then -1 and 1 (Euclidean: -1 = 2 * -1 + 1): 49, 4925,
    // 492500 - 10 + 1. Kinds(7): the later Defer first, 7 mod 4, then the first element above
    // 7; Kinds(4): 0, then 5. Strict[5] fails, so its Defer does not run.
    try expectIntegers(x, &.{ .{ "A", 321 }, .{ "B", 492491 }, .{ "C", 31 }, .{ "D", 3905 }, .{ "E", 43 }, .{ "F", 12 }, .{ "G", 5 }, .{ "H", -1 }, .{ "I", 5 } });
    const prefix = "var Trace:i64=0\nXs:[]i64=array{1,5,9}\n";
    // Deferred code cannot fail, whatever the failing form is ...
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{Defer{set Trace=Quotient[N,2]};3}\n", .defer_failure);
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{Defer{set Trace=Mod[N,2]};3}\n", .defer_failure);
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{Defer{set Trace=First[X:Xs,X>N,X]};3}\n", .defer_failure);
    // ... and the regions RFC-0072 opens around the `Defer` are no more its business than an
    // `Attempt` there: an `option{...}` outside is not made to catch for it.
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{O:=option{Block{Defer{set Trace=Xs[N]};3}};Attempt(O?,0)}\n", .defer_failure);
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{O:=logic{Block{Defer{set Trace=Xs[N]};Xs[N]}};If(O,1,0)}\n", .defer_failure);
    try expectCode(h, prefix ++ "F(N:i64)<transacts><decides>:i64=Block{Defer{set Trace=Xs[N]};Xs[N]}\n", .defer_failure);
    // Nothing leaves a `Defer`, through a `First` or otherwise.
    try expectCode(h, prefix ++ "F(N:i64)<transacts>:i64=Block{Defer{set Trace=Attempt(First[X:Xs,X>N,If(X>5,Return(1),X)],0)};3}\n", .first_exit);
}

test "a First in a Defer body that is copied to many exits gets its words, and the block has both increments' lines in order" {
    const h = try harness.create();
    defer scratch.release(h);
    const macros = @import("macros.zig");
    const last_first = macros.first_text[macros.first_text.len - 1];
    // Five copies of a body whose `First` has two levels: more `Fn` words than a count of the
    // text foresees, so the block asks again (RFC-0068) after it asked for the templates of
    // `First` together with their words (RFC-0072).
    const source =
        \\var Trace:i64=0
        \\Xs:[]i64=array{1,5,9}
        \\F(N:i64)<transacts>:i64=Block{
        \\  Defer{set Trace=Trace*10+Attempt(First[X:Xs,Y:Xs,X+Y>N,X],0)}
        \\  If(N>17,Return(1),false)
        \\  If(N>9,Return(2),false)
        \\  If(N>5,Return(3),false)
        \\  If(N>1,Return(4),false)
        \\  5
        \\}
        \\A<public>:i64=F(18)+F(10)*10+F(6)*100+F(2)*1000+F(0)*10000
        \\B<public>:i64=Trace
    ;
    const x = try h.execute(source);
    // No pair exceeds 18; 5+9 exceeds 10; 1+9 exceeds 6; 1+5 exceeds 2; 1+1 exceeds 0.
    try expectIntegers(x, &.{ .{ "A", 54321 }, .{ "B", 5111 } });
    // Each kind of line is asked for once and the words double: far fewer compiles than calls.
    try std.testing.expect(h.front.passes <= 10);
    try std.testing.expect(std.mem.endsWith(u8, x.program.source, last_first ++ "\n#" ++ macros.exit_words ++ "\n#}"));
    // A module that uses one of the two has that one's lines and not the other's.
    const only_first = try h.compile("Xs:[]i64=array{1,5,9}\nA<public>:i64=Attempt(First[X:Xs,X>2,X],0)\n");
    try std.testing.expect(std.mem.endsWith(u8, only_first.source, last_first ++ "\n#}"));
    try std.testing.expect(std.mem.indexOf(u8, only_first.source, "__exit") == null);
    const only_exits = try h.compile("F(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{set I=I+1;If(I>N,Break(),false)};I}\nA<public>:i64=F(3)\n");
    try std.testing.expect(std.mem.endsWith(u8, only_exits.source, "\n#" ++ macros.exit_words ++ "\n#}"));
    try std.testing.expect(std.mem.indexOf(u8, only_exits.source, macros.first_text[0]) == null);
}

test "a bundle whose modules use the early-exit forms and First each get the lines they need" {
    const h = try harness.create();
    defer scratch.release(h);
    const macros = @import("macros.zig");
    const modules = @import("modules.zig");
    // `search` uses `First` and no exit, `loops` exits and no `First`, `main` both, and `plain`
    // neither, so each gets a different library block.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source =
        \\S:=import{"search.forb"}
        \\L:=import{"loops.forb"}
        \\P:=import{"plain.forb"}
        \\Pick(N:i64)<transacts>:i64=Block{var I:i64=N;Loop{Y:=Attempt(S.Above[I],0);If(Y==0,Return(-I),false);If(Y>5,Break(),false);set I=I+L.Count(2)};Defer{L.Mark(7)};I*100+Attempt(S.Halve[I],0)+Attempt(First[X:P.Base,X>I,X],0)*10000}
        \\A<public>:i64=Pick(0)
        \\B<public>:i64=Pick(9)
        \\C<public>:i64=L.Find(P.Base,6)
        \\D<public>:i64=L.Seen()
        },
        .{ .path = "search.forb", .source =
        \\Xs:[]i64=array{1,5,9}
        \\Above<public>(N:i64)<computes><decides>:i64=First[X:Xs,X>N,X]
        \\Halve<public>(N:i64)<computes><decides>:i64=Quotient[N,2]
        },
        .{ .path = "loops.forb", .source =
        \\var Trace:i64=0
        \\Mark<public>(D:i64)<transacts>:i64=Set(Trace,Trace*10+D)
        \\Count<public>(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{Defer{Mark(1)};If(I>=N,Break(),false);set I=I+1};I}
        \\Find<public>(Items:[]i64,T:i64)<transacts>:i64=Block{For(I->X:Items,If(X==T,Return(I),false));-1}
        \\Seen<public>()<transacts>:i64=Trace
        },
        .{ .path = "plain.forb", .source =
        \\Base<public>:[]i64=array{4,5,6,8}
        },
    };
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |program| program,
        .failed => |problem| {
            std.debug.print("bundle: {s}:{d}: {s}\n", .{ problem.path, problem.diagnostic.span.start, problem.diagnostic.message() });
            return error.Compile;
        },
    };
    // Two modules carry the exit words and two the `First` templates; `plain` has no block.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, program.source, "#" ++ macros.exit_words ++ "\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, program.source, "#" ++ macros.first_text[0] ++ "\n"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, program.source, "\n#}"));
    const r = try h.run(program, 131072);
    try std.testing.expect(r == .ok);
    // Pick(0): the element above 0, 2 and 4 is 1, 5 and 5, and each `Count(2)` adds 2 and
    // marks three visits; above 6 it is 9, which breaks: 600 + 3 + 8 * 10000, and the `Defer`
    // marks 7. Pick(9) finds nothing and returns before its `Defer` is reached.
    try expectIntegers(r.ok, &.{ .{ "A", 80603 }, .{ "B", -9 }, .{ "C", 2 }, .{ "D", 1111111117 } });
    // A diagnostic of the new kind is reported in the module it is in.
    var broken = inputs;
    broken[1].source = "Xs:[]i64=array{1,5,9}\nAbove<public>(N:i64)<computes><decides>:i64=First[X:Xs,X>N,If(X>6,Return(0),X)]\nHalve<public>(N:i64)<computes><decides>:i64=Quotient[N,2]\n";
    const problem = h.front.compileBundle(.{ .root = "main.forb", .modules = &broken }).failed;
    try std.testing.expectEqualStrings("search.forb", problem.path);
    try std.testing.expectEqual(types.Diagnostic.Code.first_exit, problem.diagnostic.code);
    try std.testing.expectEqualStrings("Return", problem.diagnostic.span.text(problem.source));
}
