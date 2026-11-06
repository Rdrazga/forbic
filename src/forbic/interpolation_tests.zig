//! String interpolation: `"a {X} b"` lowers to concatenation with an implicit conversion.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const harness = @import("generic_function_tests.zig");

test "interpolation converts numbers logic and strings and keeps literal text" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("N:i64=42\nF:float=1.5\nB:logic=true\nName:string=\"雪\"\nA<public>:string=\"n={N} f={F} b={B} s={Name}!\"\nC<public>:string=\"{N+1}{Name}{N}\"\nD<public>:string=\"\\{x\\} {Name}\"\nI<public>:string=\"{N}\"\nL<public>:string=\"x{ -1 }y\"\nE<public>:string=\"\"\nJ<public>:string=\"{Name}\"");
    try std.testing.expectEqualStrings("n=42 f=1.5 b=true s=雪!", x.get("A").?.string);
    try std.testing.expectEqualStrings("43雪42", x.get("C").?.string);
    try std.testing.expectEqualStrings("{x} 雪", x.get("D").?.string);
    try std.testing.expectEqualStrings("42", x.get("I").?.string);
    try std.testing.expectEqualStrings("x-1y", x.get("L").?.string);
    try std.testing.expectEqualStrings("", x.get("E").?.string);
    try std.testing.expectEqualStrings("雪", x.get("J").?.string);
}

test "interpolation nests calls fields records and failable reads" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("P:=struct{Name:string=\"ab\",Size:i64=3}\nPt:P=P{}\nItems:[]i64=array{7}\nTwice(S:string)<computes>:string=S+S\nA<public>:string=\"{Twice(\"x{Pt.Size}\")}|{Pt.Name}\"\nB<public>:string=\"a{\"b{\"c{Pt.Size}\"}\"}\"\nG<public>:string=Attempt(\"v={Items[0]}\",\"none\")\nH<public>:string=Attempt(\"v={Items[3]}\",\"none\")\nK<public>:string=\"{Pt.Size*2}\\}\"\nL<public>:string=\"}{Pt.Size}\"");
    try std.testing.expectEqualStrings("x3x3|ab", x.get("A").?.string);
    try std.testing.expectEqualStrings("abc3", x.get("B").?.string);
    try std.testing.expectEqualStrings("v=7", x.get("G").?.string);
    try std.testing.expectEqualStrings("none", x.get("H").?.string);
    try std.testing.expectEqualStrings("6}", x.get("K").?.string);
    try std.testing.expectEqualStrings("}3", x.get("L").?.string);
}

test "interpolation reports exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "N:i64=1\nA:string=\"a{N\"", .unterminated_string },
        .{ "N:i64=1\nA:string=\"a{N}", .unterminated_string },
        .{ "A:string=\"a{}\"", .expected_expression },
        .{ "Items:[]i64=array{1}\nA:string=\"{Items}\"", .type_mismatch },
        .{ "N:i64=1\nA:string=\"{Q}\"", .unknown_name },
        .{ "Items:[]i64=array{1}\nA:string=\"{Items[0]}\"", .failure_context_required },
        .{ "N:i64=1\nA:i64=\"{N}\"", .type_mismatch },
        .{ "A:string=\"\\x{1}\"", .invalid_escape },
        .{ "N:i64=1\nA:string=\"{N}\\q\"", .invalid_escape },
        .{ "A:string=\"{\"{\"{\"{\"{\"{\"{\"{\"{\"{1}\"}\"}\"}\"}\"}\"}\"}\"}\"}\"", .interpolation_depth },
        .{ "N:i64=1\nA:string=\"{N+}\"", .expected_expression },
    }) |case| {
        const r = h.front.compile(case[0]);
        if (r == .ok) std.debug.print("unexpected interpolation admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("interpolation diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        _ = try h.execute("A:i64=42");
    }
}

test "lexer splits an interpolated literal into a parenthesized concatenation" {
    var tokens: [32]lexer.Token = undefined;
    const source = "\"a{X}b\"";
    const result = lexer.tokenize(source, &tokens).ok;
    const expected = [_]lexer.Token.Kind{ .left_paren, .string, .plus, .synthetic_interpolate, .left_paren, .identifier, .right_paren, .plus, .string, .right_paren, .eof };
    try std.testing.expectEqual(expected.len, result.len);
    for (expected, result) |kind, token| try std.testing.expectEqual(kind, token.kind);
    // Fragments keep their delimiters so the decoder can strip them uniformly.
    try std.testing.expectEqualStrings("\"a{", result[1].span.text(source));
    try std.testing.expectEqualStrings("}b\"", result[8].span.text(source));
    // Nothing changes for ordinary strings, braces outside strings or empty interpolation edges.
    const plain = lexer.tokenize("M:=map{\"k\"=>\"v\"}", &tokens).ok;
    for (plain) |token| try std.testing.expect(token.kind != .synthetic_interpolate);
    const edges = lexer.tokenize("\"{X}\"", &tokens).ok;
    try std.testing.expectEqual(@as(usize, 7), edges.len);
    try std.testing.expectEqual(lexer.Token.Kind.synthetic_interpolate, edges[1].kind);
}

test "five hundred generated interpolations agree with a formatting oracle" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x11b7);
    const random = prng.random();
    var source: [512]u8 = undefined;
    var expected: [256]u8 = undefined;
    for (0..500) |_| {
        const a = random.intRangeAtMost(i64, -100000, 100000);
        const b = random.intRangeAtMost(i64, -100, 100);
        const flag = random.boolean();
        const text = try std.fmt.bufPrint(&source, "A:i64={d}\nB:i64={d}\nF:logic={s}\nOut<public>:string=\"<{{A}}|{{A+B}}|{{F}}|\\{{{{B}}\\}}|{{A*B}}>\"", .{ a, b, if (flag) "true" else "false" });
        const want = try std.fmt.bufPrint(&expected, "<{d}|{d}|{s}|{{{d}}}|{d}>", .{ a, a + b, if (flag) "true" else "false", b, a * b });
        try std.testing.expectEqualStrings(want, (try h.execute(text)).get("Out").?.string);
    }
}
