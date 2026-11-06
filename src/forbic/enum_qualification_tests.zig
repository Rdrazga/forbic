//! Enumerator qualification (RFC-0085, I10): `(e:)Name` declares the enumerator `Name` in the
//! body of the enum `e`, where `Name` may be any word, and names it in expressions as `e.Name`.
//! It lowers to the enumerator nodes an unqualified enumerator compiles to.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const nested = @import("nested_module_tests.zig");

/// The fixture `tests/conformance/enumerator-qualification.forb`: the Book's examples 18
/// (09:507) and 19 (09:547) in Forbic spelling.
pub const contract =
    \\# RFC-0085, I10: the Book's examples 18 (09:507) and 19 (09:547).
    \\Start:i64 = 0
    \\game_state := enum{ (game_state:)Start, Playing, Paused }
    \\StateStart:game_state = game_state.Start
    \\Differs:logic = If(StateStart != game_state.Playing, true, false)
    \\Same:logic = If(StateStart == (game_state:)Start, true, false)
    \\Number:i64 = Start
    \\keyword_enum := enum{
    \\    (keyword_enum:)public
    \\    (keyword_enum:)for
    \\    (keyword_enum:)For
    \\    (keyword_enum:)set
    \\    (keyword_enum:)true
    \\    (keyword_enum:)i64
    \\    (keyword_enum:)keyword_enum
    \\    Regular
    \\}
    \\Words:[]keyword_enum = array{keyword_enum.public, keyword_enum.for, (keyword_enum:)For, keyword_enum.set, (keyword_enum:)true, (keyword_enum:)i64, (keyword_enum:)keyword_enum, keyword_enum.Regular}
    \\Name(K:keyword_enum)<computes>:string = Case(K, (keyword_enum:)set => "set", keyword_enum.keyword_enum => "own name", _ => "other")
    \\Names:[]string = array{Name((keyword_enum:)set), Name(keyword_enum.keyword_enum), Name(keyword_enum.Regular)}
;

test "enumerator qualification: the Book's examples, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"Start\":0,\"StateStart\":\"game_state.Start\",\"Differs\":true,\"Same\":true,\"Number\":0,\"Words\":[\"keyword_enum.public\",\"keyword_enum.for\",\"keyword_enum.For\",\"keyword_enum.set\",\"keyword_enum.true\",\"keyword_enum.i64\",\"keyword_enum.keyword_enum\",\"keyword_enum.Regular\"],\"Names\":[\"set\",\"own name\",\"other\"]}\n",
        try live.report(x, &buffer),
    );
    try live.expectEveryMode(contract);
}

test "enumerator qualification: the qualified forms compile to what the unqualified ones do" {
    const h = try harness.create();
    defer scratch.release(h);
    const qualified = try h.compile("e := enum{ (e:)A, (e:)B, C }\nX:e = (e:)B\nY:[]e = array{(e:)A, (e:)C}");
    // The cases are the names after the qualifiers.
    try std.testing.expectEqual(@as(usize, 3), qualified.cases.len);
    for (qualified.cases, [_][]const u8{ "A", "B", "C" }) |case, text| try std.testing.expectEqualStrings(text, case.text(qualified.source));
    // The compiler's storage is reused by the next compile: keep the nodes.
    const nodes = try std.testing.allocator.dupe(types.Node, qualified.nodes);
    defer std.testing.allocator.free(nodes);
    const plain = try h.compile("e := enum{ A, B, C }\nX:e = e.B\nY:[]e = array{e.A, e.C}");
    try std.testing.expectEqual(plain.nodes.len, nodes.len);
    for (plain.nodes, nodes) |a, b| {
        try std.testing.expectEqual(a.value_type, b.value_type);
        try std.testing.expectEqualDeep(a.kind, b.kind);
    }
}

test "enumerator qualification: every refusal, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // In the body, the qualifier names the enum being declared.
    try live.expectRefused(h, "other := enum{ A }\ne := enum{ (other:)B }", .invalid_qualifier, "other");
    try live.expectRefused(h, "e := enum{ (local:)A }", .invalid_qualifier, "A");
    // A reserved word after a qualifier that names no enum is refused as before.
    try live.expectRefused(h, "X:i64 = (M:)set", .invalid_qualifier, "M");
    try live.expectRefused(h, "e := enum{ A }\nX:i64 = (f:)set", .invalid_qualifier, "f");
    // In an expression, the qualifier is an enum in reach and the name one of its enumerators.
    try live.expectRefused(h, "e := enum{ A }\nX:e = (f:)A", .invalid_qualifier, "f");
    try live.expectRefused(h, "e := enum{ A }\nX:e = (e:)B", .unknown_case, "B");
    try live.expectRefused(h, "c := class{ V:i64 = 1 }\nX:i64 = (c:)V", .invalid_qualifier, "c");
    try live.expectRefused(h, "Y:i64 = 1\nX:i64 = (Y:)A", .invalid_qualifier, "Y");
    // After a dot a qualifier is no qualifier; a duplicate case is one however written.
    try live.expectRefused(h, "e := enum{ A }\nX:e = e.(e:)A", .invalid_qualifier, "(");
    try live.expectRefused(h, "e := enum{ (e:)A, A }", .duplicate_case, "A");
    // Without a qualifier, the words of example 19 stay what they are today (V19).
    const x = try live.run(h, "k := enum{ set, For, k, Regular }\nA:k = k.set\nB:k = k.k");
    try std.testing.expectEqual(@as(u32, 0), x.get("A").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 2), x.get("B").?.enumeration.index);
}

test "enumerator qualification: many qualified reserved words compile in time linear in the program" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // The names declared as enums are read from the tokens once, not once for each qualifier
    // (review of f85a). Enough enums to grow the table of their names, each qualifier naming one of them in turn.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..40) |index| try text.print(std.testing.allocator, "e{d} := enum{{ (e{d}:)set, (e{d}:)For, Other }}\n", .{ index, index, index });
    try text.appendSlice(std.testing.allocator, "Value:i64 = Block{ ");
    for (0..96) |index| try text.print(std.testing.allocator, "V{d}:e{d} = (e{d}:)set; ", .{ index, index % 40, index % 40 });
    try text.appendSlice(std.testing.allocator, "1 }");
    const x = try live.run(h, text.items);
    try std.testing.expectEqual(@as(i64, 1), x.get("Value").?.integer);
}

test "enumerator qualification: across modules, through using and in nested modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try nested.execute(h, &.{
        .{ .path = "main.forb", .source = "Kit:=import{\"kit.forb\"}\nusing{Kit}\nA<public>:Kit.mode=Kit.Dark\nB<public>:Kit.mode=(mode:)light\nIn<public>:=module{\n  shade<public>:=enum{(shade:)set, low}\n  S<public>:shade=(shade:)set\n}\nC<public>:In.shade=In.S\nD<public>:Kit.mode=(Kit:)Dark\n" },
        .{ .path = "kit.forb", .source = "mode<public>:=enum{(mode:)dark, light}\nDark<public>:mode=(mode:)dark\n" },
    });
    try std.testing.expectEqual(@as(u32, 0), x.get("A").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 1), x.get("B").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 0), x.get("C").?.enumeration.index);
    try std.testing.expectEqual(@as(u32, 0), x.get("D").?.enumeration.index);
}
