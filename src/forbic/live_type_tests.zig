//! Functions as types, P4.3 (RFC-0084, L8): a variable whose type is a function or a method
//! path, `In->Out` declarations, hidden raw cells and fields, at the root and in class bodies,
//! in both machines, the report replay and every trace mode.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const nested = @import("nested_module_tests.zig");
const live_fields = @import("live_field_tests.zig");
const trace_replay = @import("trace_replay.zig");
test {
    _ = @import("live_type_forgery_tests.zig");
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try live.report(execution, &buffer));
}
const nl = [1]u8{10};
fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}
fn pair(execution: evaluator.Execution, name: []const u8) ![2]i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    const members = execution.elements(value) orelse return error.TestUnexpectedResult;
    return .{ members[0].integer, members[1].integer };
}

/// The fixture `tests/conformance/live-function-types.forb`.
pub const contract =
    \\var Mult:i64 = 2
    \\Multiply(Arg:i64)<reads>:i64 = Arg * Mult
    \\var Scaled:Multiply = 10
    \\set Scaled = 4
    \\set Mult = 3
    \\clamp := class{
    \\    var Low:i64 = 0
    \\    var High:i64 = 100
    \\    Apply(V:i64)<reads>:i64 = If(V < Self.Low, Self.Low, If(V > Self.High, Self.High, V))
    \\}
    \\Bounds:clamp = clamp{}
    \\var Base->Health:Bounds.Apply = 50
    \\set Health = 120
    \\Clamped:tuple(i64, i64) = tuple{Base, Health}
    \\set Bounds.High = 60
    \\Fixed:Multiply = 5
    \\var live Follows:Multiply = Mult + 1
    \\set Mult = 4
    \\Heal(N:i64)<transacts>:i64 = Block{ set Health += N; Base }
    \\Healed:i64 = Heal(1)
    \\Assigned:i64 = Set(Scaled, 6)
    \\unit := class{
    \\    var Power:Multiply = 1
    \\    var Raw<public>->Shield<public>:Bounds.Apply = 70
    \\}
    \\U:unit = unit{ Raw := 90 }
    \\set U.Power = 2
    \\set U.Shield = 30
    \\Tried:logic = Attempt(Block{ set Scaled = 100; set U.Power = 50; Require[Scaled < 0]; true }, false)
    \\set Mult = 5
;

test "functions as types: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    // Scaled: raw 10, then 4 (8), Mult 3 (12), 4 (16), Set gives raw 6 (24), Mult 5: 30. Base 50,
    // then 120 (Health 100); High 60 gives Health 60. Fixed: 5 * Mult. Follows: raw Mult + 1,
    // times Mult: 5 * 4 = 20 then 6 * 5 = 30. Heal reads Health (60) and assigns 61 to Base:
    // Health stays 60. U: Power raw 1, then 2 (2 * 5 = 10); Raw 90 (Shield 60), then 30 (30).
    // The failed region puts Scaled's and Power's raw values back.
    try expectReport(x, "{\"Mult\":5,\"Scaled\":30,\"Bounds\":{\"$object\":0},\"Base\":61,\"Health\":60,\"Clamped\":[120,100],\"Fixed\":25,\"Follows\":30,\"Healed\":61,\"Assigned\":6,\"U\":{\"$object\":3},\"Tried\":false,\"$objects\":[{\"id\":0,\"class\":\"clamp\",\"fields\":{\"Low\":0,\"High\":60}},{\"id\":3,\"class\":\"unit\",\"fields\":{\"__raw3\":2,\"Power\":10,\"Raw\":30,\"Shield\":30}}],\"$live\":{\"records\":7,\"propagations\":19,\"evaluations\":26,\"entries\":55,\"deliveries\":0,\"firings\":0}}\n");
    try live.expectEveryMode(contract);
}

test "functions as types: the Book's 15:155 and 15:213, and 15:824 refused" {
    const h = try harness.create();
    defer scratch.release(h);
    // 15:155, with the initialiser Forbic requires (15:160 has none).
    var x = try live.run(h,
        \\var Mult:i64 = 2
        \\Multiply(Arg:i64)<reads>:i64 = Arg * Mult
        \\var X:Multiply = 0
        \\set X = 10
        \\A:i64 = X
        \\set Mult = 1
        \\B:i64 = X
    );
    try std.testing.expectEqual(@as(i64, 20), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 10), try integer(x, "B"));
    // 15:213.
    x = try live.run(h,
        \\health_clamp := class{
        \\    var Lower:i64 = 0
        \\    var Upper:i64 = 100
        \\    Evaluate(Value:i64)<reads>:i64 = If(Value < Self.Lower, Self.Lower, If(Value > Self.Upper, Self.Upper, Value))
        \\}
        \\Bounds:health_clamp = health_clamp{}
        \\var BaseHealth->Health:Bounds.Evaluate = 50
        \\set Health = 75
        \\A:tuple(i64, i64) = tuple{BaseHealth, Health}
        \\set Health = 120
        \\B:tuple(i64, i64) = tuple{BaseHealth, Health}
        \\set Bounds.Upper = 60
        \\C:tuple(i64, i64) = tuple{BaseHealth, Health}
    );
    try std.testing.expectEqual([2]i64{ 75, 75 }, try pair(x, "A"));
    try std.testing.expectEqual([2]i64{ 120, 100 }, try pair(x, "B"));
    try std.testing.expectEqual([2]i64{ 120, 60 }, try pair(x, "C"));
    // 15:824: a call that returns a function is no type, whatever its effect.
    try live.expectRefused(h,
        \\var Mult:i64 = 10
        \\Multiply(Value:i64)<computes>:function(tuple(i64), i64) = Fn(Arg:i64)<computes>:i64{ Value * Arg }
        \\var X:Multiply(Mult) = 10
    , .live_type_form, "Multiply");
    // The function itself is a type: one parameter, a function for its result, and no
    // dependency but the raw value.
    x = try live.run(h,
        \\Multiply(Value:i64)<computes>:function(tuple(i64), i64) = Fn(Arg:i64)<computes>:i64{ Value * Arg }
        \\var X:Multiply = 10
        \\A:i64 = X(3)
        \\set X = 2
        \\B:i64 = X(3)
    );
    try std.testing.expectEqual(@as(i64, 30), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 6), try integer(x, "B"));
}

test "functions as types: every form at the root, its raw value, set, Set, compound sets and rollback" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var M:i64 = 2
        \\F(A:i64)<reads>:i64 = A * M + 1
        \\Plain(A:i64)<computes>:i64 = A + 100
        \\var Hidden:F = 1
        \\var In->Out:F = 2
        \\Fixed:F = 3
        \\FixedIn->FixedOut:F = 4
        \\var live Follow:F = M
        \\var live FollowIn->FollowOut:F = M + 1
        \\live Kept:F = M * 10
        \\live KeptIn->KeptOut:F = M * 20
        \\var Pure:Plain = 1
        \\set M = 3
        \\First:tuple(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) = tuple{Hidden, In, Out, Fixed, FixedOut, Follow, FollowIn, FollowOut, Kept, KeptOut}
        \\set Out = 5
        \\set Follow = 7
        \\set M = 4
        \\set FollowIn = 1
        \\Second:tuple(i64, i64, i64, i64, i64, i64, i64) = tuple{In, Out, Follow, FollowIn, FollowOut, Kept, KeptIn}
        \\Assigned:i64 = Set(Hidden, 9)
        \\Bump()<transacts>:i64 = Block{ set Hidden += 1; Hidden }
        \\Bumped:i64 = Bump()
        \\Tried:logic = Attempt(Block{ set Out = 50; set Pure = 2; Require[Out < 0]; true }, false)
        \\set Pure = 3
        \\Last:tuple(i64, i64, i64) = tuple{Out, Pure, Hidden}
    );
    // M = 3: Hidden 1*3+1 = 4, In 2 (Out 7), Fixed 10, FixedOut 13, Follow raw 3 (10), FollowIn 4
    // (13), Kept raw 30 (91), KeptOut 181. Out = 5 gives 16; Follow = 7 detaches its raw from
    // M: 22, and M = 4 gives 29; FollowIn = 1 detaches it, 5. Kept follows M: 161; KeptIn 80.
    try expectReportTuple(x, "First", &.{ 4, 2, 7, 10, 13, 10, 4, 13, 91, 181 });
    try expectReportTuple(x, "Second", &.{ 5, 21, 29, 1, 5, 161, 80 });
    // Set yields the value assigned; `set Hidden += 1` reads Hidden (9 * 4 + 1 = 37) and assigns
    // 38: 153. The failed region puts both raw values back. Pure has no dependency but its raw.
    try std.testing.expectEqual(@as(i64, 9), try integer(x, "Assigned"));
    try std.testing.expectEqual(@as(i64, 153), try integer(x, "Bumped"));
    try std.testing.expect(!x.get("Tried").?.boolean);
    try expectReportTuple(x, "Last", &.{ 21, 103, 153 });
}

fn expectReportTuple(execution: evaluator.Execution, name: []const u8, expected: []const i64) !void {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    const members = execution.elements(value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected.len, members.len);
    for (expected, members) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "functions as types: fields in each form, a subclass, a method path through fields, and rollback" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var M:i64 = 2
        \\F(A:i64)<reads>:i64 = A * M
        \\clamp := class{ var High:i64 = 10; Apply(V:i64)<reads>:i64 = If(V > Self.High, Self.High, V) }
        \\holder := class{ var Inner:clamp }
        \\H:holder = holder{ Inner := clamp{} }
        \\unit := class{
        \\    var Hidden:F = 1
        \\    var In->Out:F = 2
        \\    Fixed:F = 3
        \\    var live Follow:F = M + Self.Hidden
        \\    live KeptIn->KeptOut:F = M * 10
        \\    var Capped:H.Inner.Apply = 50
        \\}
        \\big := class(unit){ var Extra:F = 7 }
        \\U:unit = unit{ In := 5 }
        \\B:big = big{}
        \\set M = 3
        \\First:tuple(i64, i64, i64, i64, i64, i64) = tuple{U.Hidden, U.In, U.Out, U.Fixed, U.Follow, U.KeptOut}
        \\set U.Out = 4
        \\set B.Extra = 2
        \\set H.Inner.High = 20
        \\Tried:logic = Attempt(Block{ set U.Out = 40; set B.Hidden = 9; Require[U.Out < 0]; true }, false)
        \\Second:tuple(i64, i64, i64, i64, i64, i64) = tuple{U.In, U.Out, B.Extra, B.Hidden, U.Capped, B.Capped}
    ;
    const x = try live.run(h, source);
    // M = 3: Hidden 3; In 5 from the archetype (15); Fixed 9; Follow's raw follows M + Hidden,
    // which reads the field that follows F of the hidden raw (3 + 3 = 6): 18; KeptIn 30: 90.
    try expectReportTuple(x, "First", &.{ 3, 5, 15, 9, 18, 90 });
    // Out = 4 assigns In; Extra = 2: 6; Capped follows the receiver's High: 20.
    try expectReportTuple(x, "Second", &.{ 4, 12, 6, 3, 20, 20 });
    try std.testing.expect(!x.get("Tried").?.boolean);
    try live.expectEveryMode(source);
}

test "functions as types: what is refused, each at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    const head =
        \\var Mult:i64 = 2
        \\Multiply(Arg:i64)<reads>:i64 = Arg * Mult
        \\Two(A:i64, B:i64)<reads>:i64 = A + B
        \\None()<reads>:i64 = Mult
        \\Writes(A:i64)<transacts>:i64 = Block{ set Mult = A; A }
        \\Builds(A:i64)<allocates>:[]i64 = array{A}
        \\Fails(A:i64)<reads><decides>:i64 = Block{ Require[A > 0]; A }
        \\Waits(A:i64)<reads><suspends>:i64 = A
        \\Over(A:i64)<computes>:i64 = A
        \\Over(A:string)<computes>:i64 = 1
        \\Id[T:type](X:T)<computes>:T{X}
        \\clamp := class{ var Low:i64 = 0; Apply(V:i64)<reads>:i64 = V + Self.Low; Set(V:i64)<transacts>:i64 = Block{ set Self.Low = V; V } }
        \\Bounds:clamp = clamp{}
        \\
    ;
    const cases = [_]struct { tail: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .tail = "var X:Multiply(Mult) = 10", .code = .live_type_form, .at = "Multiply" },
        .{ .tail = "var X:Multiply", .code = .live_initializer, .at = "Multiply" },
        .{ .tail = "var A->B:Multiply", .code = .live_initializer, .at = "Multiply" },
        .{ .tail = "var X:Two = 1", .code = .live_type_form, .at = "Two" },
        .{ .tail = "var X:None = 1", .code = .live_type_form, .at = "None" },
        .{ .tail = "var X:Writes = 1", .code = .live_type_form, .at = "Writes" },
        .{ .tail = "var X:Builds = 1", .code = .live_type_form, .at = "Builds" },
        .{ .tail = "var X:Fails = 1", .code = .live_type_form, .at = "Fails" },
        .{ .tail = "var X:Waits = 1", .code = .live_type_form, .at = "Waits" },
        .{ .tail = "var X:Over = 1", .code = .live_type_form, .at = "Over" },
        .{ .tail = "var X:Bounds.Set = 1", .code = .live_type_form, .at = "Bounds.Set" },
        .{ .tail = "var X:Bounds.Low = 1", .code = .live_type_form, .at = "Bounds.Low" },
        .{ .tail = "var X:Bounds.Apply.Q = 1", .code = .live_type_form, .at = "Bounds.Apply.Q" },
        .{ .tail = "var A->B:i64 = 1", .code = .live_type_form, .at = "i64" },
        .{ .tail = "var X:Multiply = \"a\"", .code = .type_mismatch, .at = "\"a\"" },
        .{ .tail = "Fixed:Multiply = 5\nset Fixed = 1", .code = .live_assigned, .at = "Fixed" },
        .{ .tail = "P->O:Multiply = 5\nset P = 1", .code = .live_assigned, .at = "P" },
        .{ .tail = "P->O:Multiply = 5\nset O = 1", .code = .live_assigned, .at = "O" },
        .{ .tail = "P->O:Multiply = 5\nset live P = 1", .code = .live_assigned, .at = "P" },
        .{ .tail = "live P->O:Multiply = Mult\nset P = 1", .code = .live_assigned, .at = "P" },
        .{ .tail = "var X:Multiply = 1\nset live X = 2", .code = .live_assigned, .at = "X" },
        .{ .tail = "var X->X:Multiply = 1", .code = .duplicate_name, .at = "X" },
        .{ .tail = "var Mult->Y:Multiply = 1", .code = .duplicate_name, .at = "Mult" },
        .{ .tail = "var Y->Mult:Multiply = 1", .code = .duplicate_name, .at = "Mult" },
        .{ .tail = "F()<transacts>:i64 = Block{ X:Multiply = 1; X }", .code = .live_target, .at = "X" },
        .{ .tail = "F()<transacts>:i64 = Block{ var A->B:Multiply = 1; B }", .code = .live_target, .at = "A" },
        .{ .tail = "var X:Multiply = 1\nG()<computes>:i64 = X", .code = .variable_read_requires_reads, .at = "X" },
        .{ .tail = "var X:Multiply = 1\nG()<reads>:i64 = Block{ set X = 2; X }", .code = .set_requires_writes, .at = "X" },
        .{ .tail = "pair := struct{ X:Multiply = 1 }", .code = .live_type_form, .at = "Multiply" },
        .{ .tail = "box := class{ var Hidden:Multiply = 1 }\nO:box = box{ __raw0 := 1 }", .code = .unknown_field, .at = "__raw0" },
        .{ .tail = "box := class{ var Hidden:Multiply = 1 }\nO:box = box{}\nN:i64 = O.__raw0", .code = .unknown_field, .at = "__raw0" },
        .{ .tail = "box := class{ var Hidden:Multiply = 1 }\nO:box = box{}\nset O.__raw0 = 1", .code = .unknown_field, .at = "__raw0" },
        .{ .tail = "box := class{ var Hidden:Multiply = 1 }\nsub := class(box){ __raw0<override>:i64 = 2 }", .code = .expected_field, .at = "__raw0" },
        .{ .tail = "box := class{ var Hidden:Multiply = 1 }\nO:box = box{ Hidden := 1 }", .code = .live_assigned, .at = "Hidden" },
        .{ .tail = "box := class{ P->O:Multiply = 1 }\nB:box = box{}\nset B.O = 2", .code = .live_assigned, .at = "O" },
        .{ .tail = "box := class{ var P->O:Multiply = 1 }\nB:box = box{}\nset live B.O = 2", .code = .live_assigned, .at = "O" },
        .{ .tail = "box := class{ P->O:Multiply = 1 }\nB:box = box{}\nset live B.P = 2", .code = .live_assigned, .at = "P" },
        .{ .tail = "box := class{ var X:Multiply }", .code = .live_initializer, .at = "Multiply" },
        .{ .tail = "box := class{ var X<override>:Multiply = 1 }", .code = .live_target, .at = "override" },
        .{ .tail = "box := class{ var P->P:Multiply = 1 }", .code = .duplicate_field, .at = "P" },
        .{ .tail = "shape := interface{ var X:Multiply = 1 }", .code = .live_target, .at = "var" },
        .{ .tail = "box := class{ var X:Multiply = 1 }\nF()<allocates>:box = box{}", .code = .construction_requires_reads, .at = "box" },
        .{ .tail = "var X:Id = 1", .code = .unsupported_type, .at = "Id" },
    };
    for (cases) |case| {
        var buffer: [2048]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, case.tail });
        try live.expectRefused(h, source, case.code, case.at);
    }
}

/// The scale test of functions as types: a chain of `count` instances, each holding the one
/// before it and a field whose type is a function of a module var, so that one write of that
/// var reaches every instance, and one write of the last instance's field assigns its raw value.
pub fn fanScale(f: trace_replay.Fixture, count: usize) !void {
    var text: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&text,
        \\var Rate:i64 = 1
        \\Scale(X:i64)<reads>:i64 = X * Rate
        \\item := class{{ Before:option(item); var Cost:Scale = 1 }}
        \\Make(Prev:item)<transacts>:item = item{{ Before := option{{Prev}} }}
        \\Head:item = item{{ Before := option{{}} }}
        \\Tail:item = Iterate(Make, {d}, Head)
        \\Raise()<transacts>:i64 = Block{{ set Rate = 3; set Tail.Cost = 5; Tail.Cost }}
        \\A:i64 = Raise()
    , .{count});
    const x = try live_fields.timed(f, "a chain of fields whose type is a function", source);
    try std.testing.expectEqual(@as(i64, 15), x.get("A").?.integer);
    try std.testing.expectEqual(@as(u64, count + 1), x.live.records);
    // One establishing evaluation per record, one each for the write of Rate, and one for the
    // write of the last raw value.
    try std.testing.expectEqual(@as(u64, 2 * count + 3), x.live.evaluations);
}

test "functions as types: the chain of the scale test at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try fanScale(f, 80);
}

test "functions as types: review fixes: a generic class, writes from another module, refusals and token costs" {
    const h = try harness.create();
    defer scratch.release(h);
    // Review 1: a field whose type is a function in a generic class, hidden and named; its guard
    // is named by a library word that the class's generic source reaches.
    const generic =
        \\var M:i64 = 2
        \\F(A:i64)<reads>:i64 = A * M
        \\Box[T:type] := class{ var X:F = 1; var In->Out:F = 4; Kept:T }
        \\B:Box[i64] = Box[i64]{ Kept := 3 }
        \\set B.X = 5
        \\set M = 3
        \\N:i64 = B.X * 100 + B.Out
    ;
    var x = try live.run(h, generic);
    try std.testing.expectEqual(@as(i64, 15 * 100 + 12), try integer(x, "N"));
    try live.expectEveryMode(generic);
    // Review 2: `Out` is assigned from another module through its own access, whatever its raw
    // value's is (C44): from a nested module, and from an imported file.
    x = try nested.one(h,
        \\var M:i64 = 2
        \\Lib := module{
        \\    G<public>(A:i64)<reads>:i64 = A + M
        \\    var Raw->Out<public>:G = 1
        \\    var Hidden<public>:G = 2
        \\}
        \\set Lib.Out = 30
        \\set Lib.Hidden = 40
        \\N:i64 = Lib.Out + Lib.Hidden
    );
    try std.testing.expectEqual(@as(i64, 32 + 42), try integer(x, "N"));
    x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source = "K:=import{\"kit/k.forb\"}\nset K.KX = 5\nBump()<transacts>:i64 = Block{ set K.KO += 1; K.KO }\nB:i64 = Bump()\nN:i64 = K.KX * 100 + B" },
        .{ .path = "kit/k.forb", .source = "var KM<public>:i64 = 1\nH<public>(A:i64)<reads>:i64 = A * KM\nvar KX<public>:H = 6\nvar KR->KO<public>:H = 2\n" },
    });
    try std.testing.expectEqual(@as(i64, 500 + 3), try integer(x, "N"));
    // The raw value itself stays as private as it was declared.
    try std.testing.expect(h.front.compileBundle(.{ .root = "main.forb", .modules = &.{
        .{ .path = "main.forb", .source = "K:=import{\"kit/k.forb\"}\nset K.KR = 5" },
        .{ .path = "kit/k.forb", .source = "var KM<public>:i64 = 1\nH<public>(A:i64)<reads>:i64 = A * KM\nvar KR->KO<public>:H = 2\n" },
    } }) == .failed);
    // Review 3: a call at the start of a statement is no declaration of a function, so a program
    // without functions as types gets no guard written into its tokens.
    _ = try h.compile("F(A:i64)<computes>:i64 = A\nG()<transacts>:i64 = Block{\n    var Y:i64 = 1\n    F(Y)\n}\nX:i64 = G()\nZ:i64 = 3");
    for (h.front.tokens[0..h.front.token_count]) |token| try std.testing.expect(token.kind != .synthetic_live_type);
    // A field may not take a name of the hidden raw fields (C37), nor a local the form (C41),
    // and a restatement of the field that follows a function is live_assigned (C30).
    try live.expectRefused(h, "box := class{ var __raw0:i64 = 1 }", .expected_field, "__raw0");
    try live.expectRefused(h, "F(A:i64)<reads>:i64 = A\nbox := class{ var __rawest:i64 = 1; var X:F = 2 }", .expected_field, "__rawest");
    try live.expectRefused(h, "F(A:i64)<reads>:i64 = A\nbox := class{ var P->O:F = 1 }\nsub := class(box){ var O<override>:i64 = 9 }", .live_assigned, "O");
    try live.expectRefused(h, "F(A:i64)<reads>:i64 = A\nbox := class{ var P->O:F = 1 }\nsub := class(box){ O<override>:i64 = 9 }", .live_assigned, "O");
    try live.expectRefused(h, "F(A:i64)<reads>:i64 = A\nG()<transacts>:i64 = Block{ var X:F\n 1 }", .live_target, "X");
    try live.expectRefused(h, "F(A:i64)<reads>:i64 = A\nG()<transacts>:i64 = Block{ X:F(1) = 2; 1 }", .live_target, "X");
}

test "functions as types: a name yields to every type of that name, and nothing else changes" {
    const h = try harness.create();
    defer scratch.release(h);
    // A builtin type that is no reserved word keeps its meaning beside a function of its name.
    var x = try live.run(h,
        \\char(A:i64)<computes>:i64 = A
        \\var C:char = 'a'
        \\N:i64 = char(4)
    );
    try std.testing.expectEqual(@as(i64, 4), try integer(x, "N"));
    // In a bundle: a class of one module beside a function of that name in another, the
    // function through `using`, and the function of a module named by its path.
    x = try nested.one(h,
        \\Lib := module{
        \\    var M<public>:i64 = 2
        \\    Scale<public>(X:i64)<reads>:i64 = X * M
        \\    Bump<public>()<transacts>:i64 = Block{ set M = 5; M }
        \\    var Inside<public>:Scale = 6
        \\}
        \\Other := module{
        \\    Scale<public> := class{ var V<public>:i64 = 7 }
        \\    var Kept<public>:Scale = Scale{}
        \\}
        \\using{Lib}
        \\var Y:Scale = 3
        \\var Q:Lib.Scale = 4
        \\B:i64 = Bump()
        \\Value:i64 = Y * 100 + Q * 10 + Other.Kept.V + Lib.Inside * 1000
    );
    // A hidden raw cell inside a module: 6 * 5.
    try std.testing.expectEqual(@as(i64, 30 * 1000 + 15 * 100 + 20 * 10 + 7), try integer(x, "Value"));
    // A function named like a standard type (`void`, `any`, `comparable`, `type`) leaves that
    // name no type at all, and no function used as a type either (C36): refused as before.
    for ([_][]const u8{ "void", "any", "comparable", "type" }) |standard| {
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "var M:i64 = 2\n{s}(A:i64)<reads>:i64 = A * M\nvar X:{s} = 3", .{ standard, standard });
        const result = h.front.compile(source);
        try std.testing.expect(result == .failed);
        try std.testing.expect(result.failed.code != .live_type_form);
    }
    // A parameter, a result and a field of a struct are no places for a function.
    try live.expectRefused(h, "F(A:i64)<computes>:i64 = A\nG(X:F)<computes>:i64 = 1", .unsupported_type, "F");
    // A program whose declarations name types where a function might have stood compiles to
    // what the same program does with every such name changed: the guard the macro pass wrote
    // is stepped over, and no word of the library is taken for it.
    const marked = try h.compile("char(A:i64)<computes>:i64 = A" ++ nl ++ "var C:char = 'a'" ++ nl ++ "N:i64 = char(1)");
    const marked_nodes = marked.nodes.len;
    const marked_functions = marked.functions.len;
    const marked_source = marked.source.len;
    const plain = try h.compile("cbar(A:i64)<computes>:i64 = A" ++ nl ++ "var C:char = 'a'" ++ nl ++ "N:i64 = cbar(1)");
    try std.testing.expectEqual(plain.nodes.len, marked_nodes);
    try std.testing.expectEqual(plain.functions.len, marked_functions);
    try std.testing.expectEqual(plain.source.len, marked_source);
}
