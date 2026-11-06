//! Interfaces as method contracts. A class lists the interfaces it implements after its
//! superclass, and its instances can be used as any of them. Fields and default bodies are in
//! `class_member_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "classes implement several interfaces and are called through them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Named:=interface{
        \\  Label()<transacts>:string
        \\}
        \\Scored:=interface{
        \\  Score()<transacts>:i64
        \\  Bonus(By:i64)<transacts>:i64
        \\}
        \\Ranked:=interface(Named,Scored){
        \\  Rank()<transacts>:i64
        \\}
        \\Unit:=class{
        \\  var Hits:i64=3
        \\}
        \\Knight:=class(Unit,Named,Scored){
        \\  Label<override>()<transacts>:string="knight"
        \\  Score<override>()<transacts>:i64=Self.Hits*10
        \\  Bonus<override>(By:i64)<transacts>:i64=Self.Score()+By
        \\}
        \\Squire:=class<unique>(Knight){
        \\  Label<override>()<transacts>:string="squire"
        \\}
        \\Tower:=class(Ranked){
        \\  Label<override>()<transacts>:string="tower"
        \\  Score<override>()<transacts>:i64=7
        \\  Bonus<override>(By:i64)<transacts>:i64=By
        \\  Rank<override>()<transacts>:i64=Self.Score()+1
        \\}
        \\K:=Knight{}
        \\Q:=Squire{Hits:=5}
        \\T:=Tower{}
        \\Names:[]Named=array{K,Q,T}
        \\Scores:[]Scored=array{K,Q,T}
        \\Labels(Items:[]Named)<transacts>:[]string=For(Item:Items,Item.Label())
        \\Total(Items:[]Scored)<transacts>:[]i64=For(Item:Items,Item.Bonus(1))
        \\All:[]string=Labels(Names)
        \\Second:string=Attempt(All[1],"none")
        \\Third:string=Attempt(All[2],"none")
        \\Sums:[]i64=Total(Scores)
        \\Sum:i64=Attempt(Sums[0]+Sums[1]+Sums[2],-1)
        \\Top:Ranked=T
        \\AsNamed:Named=Top
        \\Told:string=AsNamed.Label()
        \\Ranking:i64=Top.Rank()
        \\Back:i64=Attempt(Block{Down:=Squire[Names[1]];Down.Hits},-1)
        \\Wrong:i64=Attempt(Block{Down:=Squire[Names[0]];Down.Hits},-1)
        \\Same:i64=Attempt(Block{L:=Squire[Names[1]];R:=Squire[Scores[1]];Require[L==R];1},0)
        \\Lone:=class(Named){
        \\  Label<override>()<transacts>:string="lone"
        \\}
        \\Alone:Named=Lone{}
        \\Across:i64=Attempt(Block{S:=Scored[Names[1]];S.Score()},-1)
        \\NotAcross:i64=Attempt(Block{S:=Scored[Alone];S.Score()},-1)
        \\FromClass:string=Attempt(Block{U:Unit=Q;N:=Named[U];N.Label()},"none")
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("Same").?.integer);
    try std.testing.expectEqual(@as(i64, 50), x.get("Across").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("NotAcross").?.integer);
    try std.testing.expectEqualStrings("squire", x.get("FromClass").?.string);
    try std.testing.expectEqualStrings("squire", x.get("Second").?.string);
    try std.testing.expectEqualStrings("tower", x.get("Third").?.string);
    try std.testing.expectEqual(@as(i64, 31 + 51 + 1), x.get("Sum").?.integer);
    try std.testing.expectEqualStrings("tower", x.get("Told").?.string);
    try std.testing.expectEqual(@as(i64, 8), x.get("Ranking").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("Back").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Wrong").?.integer);
}

test "interface declarations and implementations are checked" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\I:=interface{
        \\  F()<transacts>:i64
        \\}
        \\J:=interface{
        \\  F()<transacts>:i64
        \\}
        \\A:=class{}
        \\B:=class{}
        \\
    ;
    const cases = [_]struct { tail: []const u8, code: types.Diagnostic.Code }{
        .{ .tail = "C:=class(I){}", .code = .unimplemented_method },
        .{ .tail = "C:=class(I){F()<transacts>:i64=1}", .code = .missing_override },
        .{ .tail = "C:=class(I){F<override>()<transacts>:string=\"x\"}", .code = .override_mismatch },
        .{ .tail = "C:=class(I,J){F<override>()<transacts>:i64=1}", .code = .duplicate_name },
        .{ .tail = "C:=class(A,B){}", .code = .invalid_interface },
        .{ .tail = "C:=class(I,I){F<override>()<transacts>:i64=1}", .code = .invalid_interface },
        .{ .tail = "K:=interface(A){}", .code = .invalid_interface },
        .{ .tail = "K:=interface{N<private>:i64}", .code = .invalid_interface },
        .{ .tail = "K:=interface{N<override>:i64}", .code = .invalid_interface },
        .{ .tail = "K:=interface{G<final>()<transacts>:i64}", .code = .invalid_interface },
        .{ .tail = "K:=interface<abstract>{}", .code = .unsupported_specifier },
        .{ .tail = "X:=I{}", .code = .abstract_instance },
        .{ .tail = "C:=class(I){F<override>()<transacts>:i64=1}\nV:J=C{}", .code = .type_mismatch },
        .{ .tail = "C:=class<abstract>(I){}\nD:=class(C){}", .code = .unimplemented_method },
        .{ .tail = "S:=class<final>{}\nV:=S{}\nX:i64=Attempt(Block{W:=I[V];W.F()},0)", .code = .type_mismatch },
        .{ .tail = "V:=A{}\nX:i64=Attempt(Block{W:=B[V];1},0)", .code = .type_mismatch },
    };
    var buffer: [1024]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, case.tail });
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("interface diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.tail, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

test "forged interface lists are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\I:=interface{
        \\  F()<transacts>:i64
        \\}
        \\Plain:=class{N:i64}
        \\C:=class(I){
        \\  F<override>()<transacts>:i64=4
        \\}
        \\V:I=C{}
        \\X:i64=V.F()
    );
    const definitions = try std.testing.allocator.dupe(types.Definition, p.definitions);
    defer std.testing.allocator.free(definitions);
    var forged = p;
    forged.definitions = definitions;
    const implementer = blk: {
        for (definitions, 0..) |item, index| if (item == .class and item.class.interface_count == 1) break :blk index;
        unreachable;
    };
    const plain = blk: {
        for (definitions, 0..) |item, index| if (item == .class and !item.class.is_interface and item.class.interface_count == 0) break :blk index;
        unreachable;
    };
    const original = definitions[implementer];
    _ = try h.run(forged, 10_000);
    // Dropping the interface makes the upcast and the dispatch entry unfounded.
    definitions[implementer].class.interface_count = 0;
    try harness.invalid(h, forged);
    definitions[implementer] = original;
    // An interface entry must be an interface: a class with fields would expose them.
    definitions[implementer].class.interfaces[0] = @fromBackingInt(@intCast(plain + 4));
    try harness.invalid(h, forged);
    definitions[implementer] = original;
    // The same interface twice, a count past the array, and a later definition.
    definitions[implementer].class.interfaces[1] = original.class.interfaces[0];
    definitions[implementer].class.interface_count = 2;
    try harness.invalid(h, forged);
    definitions[implementer] = original;
    definitions[implementer].class.interface_count = types.Class.max_interfaces + 1;
    try harness.invalid(h, forged);
    definitions[implementer] = original;
    definitions[implementer].class.interfaces[0] = @fromBackingInt(@intCast(implementer + 4));
    try harness.invalid(h, forged);
    definitions[implementer] = original;
    // An interface with a field, a parent, or without the abstract mark.
    const interface: usize = @backingInt(original.class.interfaces[0]) - 4;
    const kept = definitions[interface];
    definitions[interface].class.is_abstract = false;
    try harness.invalid(h, forged);
    definitions[interface] = kept;
    definitions[interface].class.is_interface = false;
    try harness.invalid(h, forged);
    definitions[interface] = kept;
    _ = try h.run(forged, 10_000);
}
