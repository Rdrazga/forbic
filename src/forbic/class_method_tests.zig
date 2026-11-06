//! Methods: declared in the class body with the receiver as `Self`, called as `Object.Method(...)`,
//! overridden by subclasses and dispatched on the class an instance was built as.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "a method reads and writes its receiver and calls other methods" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Counter:=class{
        \\  var N:i64=0
        \\  Bump(By:i64)<transacts>:i64=Block{set Self.N=Self.N+By;Self.N}
        \\  Twice(By:i64)<transacts>:i64=Block{First:=Self.Bump(By);Self.Bump(By)}
        \\  Get()<transacts>:i64=Self.N
        \\}
        \\K:=Counter{}
        \\A:i64=K.Bump(5)
        \\B:i64=K.Twice(2)
        \\C:i64=K.Get()
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("C").?.integer);
}

test "a method named without a call is a function value bound to its receiver" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Counter:=class{
        \\  var N:i64=0
        \\  Add(By:i64)<transacts>:i64=Block{set Self.N=Self.N+By;Self.N}
        \\  Kind()<transacts>:string="plain"
        \\}
        \\Loud:=class<unique><final>(Counter){
        \\  Add<override>(By:i64)<transacts>:i64=Block{set Self.N=Self.N+By*10;Self.N}
        \\  Kind<override>()<transacts>:string="loud"
        \\}
        \\Twice(F:function<transacts>(tuple(i64),i64),V:i64)<transacts>:i64=Block{First:=F(V);F(V)}
        \\A:=Counter{}
        \\B:Counter=Loud{}
        \\Step:=A.Add
        \\One:i64=Step(2)
        \\Two:i64=Twice(A.Add,5)
        \\Three:i64=Twice(B.Add,1)
        \\Label:=B.Kind
        \\Said:string=Label()
        \\Kept:i64=A.N
        \\Steps:[]function<transacts>(tuple(i64),i64)=array{A.Add,B.Add}
        \\Mixed:i64=Attempt(Steps[1](1),-1)
    );
    try std.testing.expectEqual(@as(i64, 2), x.get("One").?.integer);
    try std.testing.expectEqual(@as(i64, 12), x.get("Two").?.integer);
    try std.testing.expectEqual(@as(i64, 20), x.get("Three").?.integer);
    try std.testing.expectEqualStrings("loud", x.get("Said").?.string);
    try std.testing.expectEqual(@as(i64, 12), x.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 30), x.get("Mixed").?.integer);
}

test "an override runs for instances of the subclass even through the superclass type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Animal:=class{
        \\  Name:string
        \\  Sound()<transacts>:string="..."
        \\  Describe()<transacts>:string=Self.Name+Self.Sound()
        \\}
        \\Dog:=class(Animal){
        \\  Sound<override>()<transacts>:string="woof"
        \\}
        \\Cat:=class(Animal){}
        \\D:=Dog{Name:="rex "}
        \\C:=Cat{Name:="tom "}
        \\Pets:[]Animal=array{D,C}
        \\Viewed:Animal=D
        \\Direct:string=D.Describe()
        \\ViaBase:string=Viewed.Describe()
        \\Plain:string=C.Describe()
        \\First:string=Attempt(Pets[0].Sound(),"none")
        \\Second:string=Attempt(Pets[1].Sound(),"none")
    );
    try std.testing.expectEqualStrings("rex woof", x.get("Direct").?.string);
    try std.testing.expectEqualStrings("rex woof", x.get("ViaBase").?.string);
    try std.testing.expectEqualStrings("tom ...", x.get("Plain").?.string);
    try std.testing.expectEqualStrings("woof", x.get("First").?.string);
    try std.testing.expectEqualStrings("...", x.get("Second").?.string);
}
