//! Abstract methods, `Super`, recursive dispatch over object graphs, failable methods and the
//! diagnostics of method declarations.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "abstract methods are implemented by concrete subclasses" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Shape:=class<abstract>{
        \\  Name:string
        \\  Area<abstract>()<transacts>:i64
        \\  Report()<transacts>:i64=Self.Area()*10
        \\}
        \\Square:=class(Shape){
        \\  Side:i64
        \\  Area<override>()<transacts>:i64=Self.Side*Self.Side
        \\}
        \\Rect:=class(Shape){
        \\  W:i64
        \\  H:i64
        \\  Area<override>()<transacts>:i64=Self.W*Self.H
        \\}
        \\S:=Square{Name:="s",Side:=3}
        \\R:=Rect{Name:="r",W:=2,H:=5}
        \\Shapes:[]Shape=array{S,R}
        \\Reps(Items:[]Shape)<transacts>:[]i64=For(Item:Items,Item.Report())
        \\Reports:[]i64=Reps(Shapes)
        \\First:i64=Attempt(Reports[0],-1)
        \\Second:i64=Attempt(Reports[1],-1)
        \\One:i64=S.Area()
    );
    try std.testing.expectEqual(@as(i64, 90), x.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, 100), x.get("Second").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("One").?.integer);
}

test "Super runs the superclass implementation and a tree sums itself through dispatch" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Base:=class{
        \\  var Calls:i64=0
        \\  Note(By:i64)<transacts>:i64=Block{set Self.Calls=Self.Calls+1;By}
        \\}
        \\Loud:=class(Base){
        \\  Note<override>(By:i64)<transacts>:i64=Super.Note(By)*2
        \\}
        \\L:=Loud{}
        \\Doubled:i64=L.Note(21)
        \\Counted:i64=L.Calls
        \\Node:=class{
        \\  Value:i64
        \\  Left:option(Node)
        \\  Right:option(Node)
        \\  Sum()<transacts>:i64=Block{
        \\    LSum:=Attempt(Block{N:=Self.Left?;N.Sum()},0)
        \\    R:=Attempt(Block{N:=Self.Right?;N.Sum()},0)
        \\    Self.Value+LSum+R
        \\  }
        \\}
        \\Leaf1:=Node{Value:=2,Left:=option{},Right:=option{}}
        \\Leaf2:=Node{Value:=3,Left:=option{},Right:=option{}}
        \\Branch:=Node{Value:=10,Left:=option{Leaf1},Right:=option{Leaf2}}
        \\Root:=Node{Value:=100,Left:=option{Branch},Right:=option{Leaf1}}
        \\Everything:i64=Root.Sum()
    );
    try std.testing.expectEqual(@as(i64, 42), x.get("Doubled").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Counted").?.integer);
    try std.testing.expectEqual(@as(i64, 117), x.get("Everything").?.integer);
}

test "failable methods use brackets and fail their caller's region" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Bag:=class{
        \\  var Items:[]i64
        \\  Find(Wanted:i64)<transacts><decides>:i64=Block{
        \\    I:=For(Item:Self.Items,Item==Wanted,Item)
        \\    Require[I.Length>0]
        \\    I[0]
        \\  }
        \\}
        \\B:=Bag{Items:=array{4,5,6}}
        \\Hit:i64=Attempt(B.Find[5],-1)
        \\Miss:i64=Attempt(B.Find[9],-1)
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("Hit").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Miss").?.integer);
}

test "method declarations are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "A:=class{F()<transacts>:i64=1}\nB:=class(A){F()<transacts>:i64=2}", .code = .missing_override },
        .{ .source = "A:=class{}\nB:=class(A){F<override>()<transacts>:i64=2}", .code = .unexpected_override },
        .{ .source = "A:=class{F()<transacts>:i64=1}\nB:=class(A){F<override>()<transacts>:string=\"x\"}", .code = .override_mismatch },
        .{ .source = "A:=class{F(X:i64)<transacts>:i64=1}\nB:=class(A){F<override>(X:string)<transacts>:i64=2}", .code = .override_mismatch },
        .{ .source = "A:=class{F<final>()<transacts>:i64=1}\nB:=class(A){F<override>()<transacts>:i64=2}", .code = .final_method },
        .{ .source = "A:=class<abstract>{F<abstract>()<transacts>:i64}\nB:=class(A){}", .code = .unimplemented_method },
        .{ .source = "A:=class{F<abstract>()<transacts>:i64}", .code = .unsupported_specifier },
        .{ .source = "A:=class{F()<transacts>:i64=1\nF()<transacts>:i64=2}", .code = .duplicate_name },
        .{ .source = "A:=class{F()<transacts>:i64=1}\nK:=A{}\nX:i64=K.F[]", .code = .expected_call },
        .{ .source = "A:=class{F()<transacts>:i64=1}\nK:=A{}\nX:i64=K.G()", .code = .unknown_field },
        .{ .source = "A:=class{F()<computes>:i64=Self.G()\nG()<transacts>:i64=1}", .code = .call_requires_transacts },
        .{ .source = "A:=class{F()<transacts>:i64=Super.G()}", .code = .invalid_parent },
        .{ .source = "A:=class{F()<transacts>:i64=1}\nF:i64=2", .code = .duplicate_name },
        .{ .source = "A:=class{F()<transacts>:i64=1}\nB:=class(A){G(X:A)<transacts>:i64=1\nF<override>()<transacts>:i64=Self.G(Super)}", .code = .expected_field },
        .{ .source = "A:=class<abstract>{F()<transacts>:i64=1}\nB:=class<abstract>(A){F<override><abstract>()<transacts>:i64}\nC:=class(B){}", .code = .unimplemented_method },
    };
    for (cases) |case| {
        const result = h.front.compile(case.source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("method diagnostic for:\n{s}\nexpected {s}, got {s}\n", .{ case.source, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

test "a final override only seals its own subclasses and Super does not leak into later calls" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Base:=class{
        \\  Tag()<transacts>:i64=1
        \\}
        \\Sealed:=class(Base){
        \\  Tag<override><final>()<transacts>:i64=Super.Tag()+10
        \\}
        \\Open:=class(Base){
        \\  Tag<override>()<transacts>:i64=Super.Tag()+20
        \\}
        \\Deep:=class(Open){
        \\  Tag<override>()<transacts>:i64=Super.Tag()+300
        \\}
        \\S:Base=Sealed{}
        \\O:Base=Open{}
        \\D:Base=Deep{}
        \\A:i64=S.Tag()
        \\B:i64=O.Tag()
        \\C:i64=D.Tag()
    );
    try std.testing.expectEqual(@as(i64, 11), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 21), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 321), x.get("C").?.integer);
}
