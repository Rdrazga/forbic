//! Classes: instances with identity, constructed by `Class{Field := value}`, read with `.`, and
//! updated in place through `var` fields.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");

fn cell(x: anytype, value: types.Value, index: usize) i64 {
    return x.fields(value).?[index].value.integer;
}

test "a class instance is built once, read by field and updated in place" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Point:=class{X:i64,var Y:i64=5}
        \\P:=Point{X:=1}
        \\A:i64=P.X
        \\B:i64=P.Y
        \\set P.Y=9
        \\C:i64=P.Y
        \\set P.Y+=1
        \\D:i64=P.Y
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("D").?.integer);
    // Exactly one instance exists, with a header naming its class and the final field values.
    try std.testing.expectEqual(@as(usize, 3), x.object_cells.len);
    try std.testing.expectEqual(@as(i64, 1), cell(x, x.get("P").?, 0));
    try std.testing.expectEqual(@as(i64, 10), cell(x, x.get("P").?, 1));
    try std.testing.expectEqual(x.get("P").?.object.value_type, x.program.nodes[x.program.bindings[0].node].value_type);
}

test "instances are equal only to themselves" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Box:=class<unique>{var N:i64}
        \\A:=Box{N:=1}
        \\B:=Box{N:=1}
        \\Same:logic=A==A
        \\Different:logic=A==B
        \\Apart:logic=A!=B
    );
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expect(!x.get("Different").?.boolean);
    try std.testing.expect(x.get("Apart").?.boolean);
}

test "functions take instances, mutate them and the caller sees the change" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Counter:=class{var N:i64=0}
        \\Bump(C:Counter,By:i64)<transacts>:i64=Block{set C.N=C.N+By;C.N}
        \\Make(Start:i64)<transacts>:Counter=Counter{N:=Start}
        \\K:=Counter{}
        \\First:i64=Bump(K,5)
        \\Second:i64=Bump(K,2)
        \\Total:i64=K.N
        \\M:=Make(40)
        \\Third:i64=Bump(M,2)
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Second").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("Third").?.integer);
    try std.testing.expectEqual(@as(usize, 4), x.object_cells.len);
}

test "a failed attempt undoes field writes and forgets the instances it built" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Box:=class{var N:i64}
        \\Poke(B:Box)<transacts><decides>:i64=Block{set B.N=B.N+10;Require[B.N>100];B.N}
        \\Build(B:Box)<transacts><decides>:i64=Block{Spare:=Box{N:=7};set B.N=Spare.N;Require[false];B.N}
        \\K:=Box{N:=1}
        \\A:i64=Attempt(Poke[K],K.N)
        \\B:i64=Attempt(Build[K],K.N)
        \\Keep:i64=Attempt(Block{set K.N=3;K.N},0)
        \\After:i64=K.N
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Keep").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("After").?.integer);
    // Only the first instance survives: the one built in the failed attempt is gone.
    try std.testing.expectEqual(@as(usize, 2), x.object_cells.len);
}

test "classes may refer to themselves and to classes declared later" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Node:=class{Value:i64,var Next:option(Node)}
        \\Owner:=class{var Items:[]Item}
        \\Item:=class{Name:string,var Holder:option(Owner)}
        \\Tail:=Node{Value:=2,Next:=option{}}
        \\Head:=Node{Value:=1,Next:=option{Tail}}
        \\Second:i64=Attempt(Block{N:=Head.Next?;N.Value},0)
        \\Walk(N:Node)<transacts><decides>:i64=Block{After:=N.Next?;N.Value+After.Value}
        \\Sum:i64=Attempt(Walk[Head],0)
        \\Leaf:i64=Attempt(Walk[Tail],-1)
        \\I:=Item{Name:="a",Holder:=option{}}
        \\O:=Owner{Items:=array{I}}
        \\set I.Holder=option{O}
        \\Back:i64=Attempt(Block{H:=I.Holder?;H.Items.Length},-1)
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("Second").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Sum").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Leaf").?.integer);
}
