//! Lexical completion (RFC-0089, B1): hexadecimal integers, the `f64` suffix, the rest of the
//! Book's string escapes, block and indented comments, and `Name:type := v`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const profile = @import("profile.zig");
const harness = @import("generic_function_tests.zig");
const compiler = @import("compiler.zig");
const qualify = @import("qualify.zig");

const Token = lexer.Token;

/// The kinds of the tokens `source` lexes to, without the end marker.
fn kinds(source: []const u8, storage: []Token) ![]const Token {
    const result = lexer.tokenize(source, storage);
    if (result == .failed) {
        std.debug.print("lexical test: {s} for {s}\n", .{ result.failed.message(), source });
        return error.Lex;
    }
    return result.ok[0 .. result.ok.len - 1];
}

fn expectTokens(source: []const u8, expected: []const struct { []const u8, Token.Kind }) !void {
    var storage: [128]Token = undefined;
    const tokens = try kinds(source, &storage);
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, token| {
        try std.testing.expectEqualStrings(want[0], token.span.text(source));
        try std.testing.expectEqual(want[1], token.kind);
    }
}

fn expectLexFailure(source: []const u8, code: types.Diagnostic.Code, start: u32, end: u32) !void {
    var storage: [128]Token = undefined;
    const result = lexer.tokenize(source, &storage);
    if (result == .ok) std.debug.print("lexical test: unexpected admission of {s}\n", .{source});
    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqual(start, result.failed.span.start);
    try std.testing.expectEqual(end, result.failed.span.end);
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const result = h.front.compile(source);
    if (result == .ok) std.debug.print("lexical test: unexpected admission of {s}\n", .{source});
    try std.testing.expect(result == .failed);
    if (result.failed.code != code) std.debug.print("lexical test: {s} for {s}\n", .{ result.failed.message(), source });
    try std.testing.expectEqual(code, result.failed.code);
}

// Hexadecimal integers

test "hexadecimal literals: either case, leading zeros, the 64-bit bounds and member access" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\(V:i64).Dbl()<computes>:i64=V*2
        \\A<public>:i64=0xFF
        \\B<public>:i64=0xabcdef
        \\C<public>:i64=0xABCDEF
        \\Max<public>:i64=0x7FFFFFFFFFFFFFFF
        \\Min<public>:i64=-0x8000000000000000
        \\Zero<public>:i64=0x0
        \\Padded<public>:i64=0x0000000000000000000000ff
        \\Sum<public>:i64=0x10+0x01*2
        \\Digits<public>:i64=0x1e3
        \\Suffixish<public>:i64=0x1f64
        \\Negative<public>:i64=-0x10
        \\Member<public>:i64=0x10.Dbl()
        \\Items<public>:[]i64=array{0x1,0x2}
        \\Decimal<public>:i64=-9223372036854775808
    );
    try std.testing.expectEqual(@as(i64, 255), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0xabcdef), x.get("B").?.integer);
    try std.testing.expectEqual(x.get("B").?.integer, x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), x.get("Max").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), x.get("Min").?.integer);
    try std.testing.expectEqual(x.get("Min").?.integer, x.get("Decimal").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("Zero").?.integer);
    try std.testing.expectEqual(@as(i64, 255), x.get("Padded").?.integer);
    try std.testing.expectEqual(@as(i64, 18), x.get("Sum").?.integer);
    // `e` is a digit here, not an exponent, and `f64` is three digits, not a suffix.
    try std.testing.expectEqual(@as(i64, 483), x.get("Digits").?.integer);
    try std.testing.expectEqual(@as(i64, 8036), x.get("Suffixish").?.integer);
    try std.testing.expectEqual(@as(i64, -16), x.get("Negative").?.integer);
    try std.testing.expectEqual(@as(i64, 32), x.get("Member").?.integer);
}

test "hexadecimal tokens: an integer, the prefix is lower case, and what follows decides" {
    try expectTokens("0xFF 0x0 0xaB.Up 0x1e3 0X1F", &.{
        .{ "0xFF", .integer },  .{ "0x0", .integer },
        .{ "0xaB", .integer },  .{ ".", .dot },
        .{ "Up", .identifier }, .{ "0x1e3", .integer },
        // The prefix is `0x` alone: `0X1F` is the integer and the name it has always been.
        .{ "0", .integer },     .{ "X1F", .identifier },
    });
    // `0o` and `0u` keep their meaning as character literals.
    try expectTokens("0x61 0o61 0u61", &.{ .{ "0x61", .integer }, .{ "0o61", .character }, .{ "0u61", .character } });
    try std.testing.expectEqual(@as(?u64, 255), lexer.integerMagnitude("0xFF"));
    try std.testing.expectEqual(@as(?u64, 255), lexer.integerMagnitude("255"));
    try std.testing.expectEqual(@as(?u64, 0xFFFFFFFFFFFFFFFF), lexer.integerMagnitude("0xffffffffffffffff"));
    try std.testing.expectEqual(@as(?u64, null), lexer.integerMagnitude("0x10000000000000000"));
    try std.testing.expectEqual(@as(?u64, null), lexer.integerMagnitude("18446744073709551616"));
    try std.testing.expectEqual(@as(?u64, 0), lexer.integerMagnitude("0"));
}

test "hexadecimal diagnostics: range, a missing digit, a name character and a fraction" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        .{ "A:i64=0x8000000000000000", .integer_range },
        .{ "A:i64=0xFFFFFFFFFFFFFFFF", .integer_range },
        .{ "A:i64=0x10000000000000000", .integer_range },
        .{ "A:i64=-0x8000000000000001", .integer_range },
        .{ "A:i64=0x", .invalid_hex_literal },
        .{ "A:i64=0xg", .invalid_hex_literal },
        .{ "A:i64=0x1g", .invalid_hex_literal },
        .{ "A:i64=0xFFz", .invalid_hex_literal },
        .{ "A:i64=0x_1", .invalid_hex_literal },
        .{ "A:i64=0x1.5", .invalid_hex_literal },
        .{ "A:float=0x1p3", .invalid_hex_literal },
    }) |case| try expectRefused(h, case[0], case[1]);
    // The span covers the literal and the name characters that stick to it.
    try expectLexFailure("A:i64=0x1g+2", .invalid_hex_literal, 6, 10);
    try expectLexFailure("A:i64=0x 5", .invalid_hex_literal, 6, 8);
    try expectLexFailure("0x1.5", .invalid_hex_literal, 0, 3);
}

// The f64 suffix

test "float literals take the optional f64 suffix and 1. stays an error" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A<public>:float=12.34f64
        \\B<public>:float=2.5e+3f64
        \\C<public>:float=1e3f64
        \\D<public>:float=-1.0f64
        \\E<public>:float=1.5f64+0.5
        \\F<public>:float=12.34
        \\Max<public>:float=1.7976931348623158e+308f64
    );
    try std.testing.expectEqual(@as(f64, 12.34), x.get("A").?.floating);
    try std.testing.expectEqual(x.get("F").?.floating, x.get("A").?.floating);
    try std.testing.expectEqual(@as(f64, 2500.0), x.get("B").?.floating);
    try std.testing.expectEqual(@as(f64, 1000.0), x.get("C").?.floating);
    try std.testing.expectEqual(@as(f64, -1.0), x.get("D").?.floating);
    try std.testing.expectEqual(@as(f64, 2.0), x.get("E").?.floating);
    try std.testing.expectEqual(@as(f64, std.math.floatMax(f64)), x.get("Max").?.floating);
    try expectRefused(h, "A:float=1.7976931348623159e+308f64", .float_range);
    try expectRefused(h, "A:float=1.f64", .type_mismatch);
    try expectRefused(h, "A:float=1.", .invalid_number);
    try expectRefused(h, "A:float=1.f", .type_mismatch);
    try expectRefused(h, "A:float=1.5e", .invalid_number);
    // The suffix is for floats: an integer has none, and only `f64` is one.
    try expectRefused(h, "A:i64=1f64", .unexpected_token);
    try expectRefused(h, "A:float=1.5f32", .unexpected_token);
}

test "the f64 suffix ends a float token and is not part of a longer name" {
    try expectTokens("1.5f64 2.0e3f64 1e3f64 1.5f64x 1.5f6 1.5f640 1.5 f64", &.{
        .{ "1.5f64", .floating }, .{ "2.0e3f64", .floating }, .{ "1e3f64", .floating },
        .{ "1.5", .floating },    .{ "f64x", .identifier },   .{ "1.5", .floating },
        .{ "f6", .identifier },   .{ "1.5", .floating },      .{ "f640", .identifier },
        .{ "1.5", .floating },    .{ "f64", .identifier },
    });
    // Numeric member access keeps working next to the suffix.
    try expectTokens("12.e5 7.f64 1.5.Floor", &.{
        .{ "12", .integer },   .{ ".", .dot }, .{ "e5", .identifier },
        .{ "7", .integer },    .{ ".", .dot }, .{ "f64", .identifier },
        .{ "1.5", .floating }, .{ ".", .dot }, .{ "Floor", .identifier },
    });
    try std.testing.expectEqualStrings("1.5", lexer.floatDigits("1.5f64"));
    try std.testing.expectEqualStrings("1e3", lexer.floatDigits("1e3f64"));
    try std.testing.expectEqualStrings("1.5", lexer.floatDigits("1.5"));
}

// Escapes

test "every escape of the Book stands for its character in plain and interpolated strings" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\N:i64=7
        \\Control<public>:string="a\tb\nc\rd"
        \\Quotes<public>:string="\"\'"
        \\Slash<public>:string="\\"
        \\Braces<public>:string="\{\}"
        \\Marks<public>:string="\<\>\&\#\~"
        \\Inside<public>:string="\<{N}\> \& {N+1}\#\~ \'q\' \{{N}\}"
        \\Tail<public>:string="{N}\<"
        \\Comment<public>:string="x \# not a comment <# nor this #> # nor that"
    );
    try std.testing.expectEqualStrings("a\tb\nc\rd", x.get("Control").?.string);
    try std.testing.expectEqualStrings("\"'", x.get("Quotes").?.string);
    try std.testing.expectEqualStrings("\\", x.get("Slash").?.string);
    try std.testing.expectEqualStrings("{}", x.get("Braces").?.string);
    try std.testing.expectEqualStrings("<>&#~", x.get("Marks").?.string);
    try std.testing.expectEqualStrings("<7> & 8#~ 'q' {7}", x.get("Inside").?.string);
    try std.testing.expectEqualStrings("7<", x.get("Tail").?.string);
    try std.testing.expectEqualStrings("x # not a comment <# nor this #> # nor that", x.get("Comment").?.string);
}

test "an escape the Book does not list is still refused" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "A:string=\"\\x\"",
        "A:string=\"\\a\"",
        "A:string=\"\\u0041\"",
        "A:string=\"\\0\"",
        "A:string=\"\\ \"",
        "N:i64=1\nA:string=\"{N}\\q\"",
        "N:i64=1\nA:string=\"\\q{N}\"",
    }) |source| try expectRefused(h, source, .invalid_escape);
    try expectRefused(h, "A:string=\"abc\\", .unterminated_string);
    try expectLexFailure("\"\\q\"", .invalid_escape, 1, 3);
}

// Comments

test "block comments: inline, across lines, nested, and not inside strings" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\N:i64=7
        \\A<public>:i64=1 <# inline #> + <# another #> 2
        \\<# multi
        \\   line <# nested <# twice #> #> still comment ( [ { "
        \\#>
        \\B<public>:i64=3
        \\C<public>:i64=4 #> a line comment, whatever it says
        \\D<public>:string="x <# not a comment #> y # nor this"
        \\S<public>:i64=1 +<# spans
        \\lines #> 2
        \\I<public>:string="a{N <# in an interpolation #> + 1}b"
        \\E<public>:i64=<##>5
        \\F<public>:i64=6<# no space before #>
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("C").?.integer);
    try std.testing.expectEqualStrings("x <# not a comment #> y # nor this", x.get("D").?.string);
    try std.testing.expectEqual(@as(i64, 3), x.get("S").?.integer);
    try std.testing.expectEqualStrings("a8b", x.get("I").?.string);
    try std.testing.expectEqual(@as(i64, 5), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("F").?.integer);
}

test "comment tokens: a comment is white space, a line comment keeps its newline" {
    try expectTokens("A <# c #> B", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    try expectTokens("A <# c\n d #> B", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    try expectTokens("A # c <# \nB", &.{ .{ "A", .identifier }, .{ "\n", .newline }, .{ "B", .identifier } });
    try expectTokens("A <# a <# b #> c #> B", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    try expectTokens("A <# # #> B #> C", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    try expectTokens("A <##> B <###> C", &.{ .{ "A", .identifier }, .{ "B", .identifier }, .{ "C", .identifier } });
    // A comment's `#` is no line comment, and a block comment's quote opens no string.
    try expectTokens("A <# \" # #> B", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    // `<#>` inside a block comment opens a nested one, so this is closed by its second `#>`.
    try expectTokens("A <# x <#> y #> z #> B", &.{ .{ "A", .identifier }, .{ "B", .identifier } });
    // A comment is no string's business either way: `<` and `#` apart are the old tokens.
    try expectTokens("A < B", &.{ .{ "A", .identifier }, .{ "<", .less }, .{ "B", .identifier } });
    try expectTokens("A <= # c\nB", &.{ .{ "A", .identifier }, .{ "<=", .less_equal }, .{ "\n", .newline }, .{ "B", .identifier } });
}

test "an unterminated block comment names the comment that is not closed" {
    try expectLexFailure("A <# never", .unterminated_comment, 2, 4);
    try expectLexFailure("<#", .unterminated_comment, 0, 2);
    try expectLexFailure("A <# outer <# inner #> still open", .unterminated_comment, 2, 4);
    try expectLexFailure("A <# x <#> y #> z", .unterminated_comment, 2, 4);
    try expectLexFailure("A <#\n\nB # #", .unterminated_comment, 2, 4);
    try expectLexFailure("A <# #", .unterminated_comment, 2, 4);
    // The first `#` of `#>` is not enough, and `<#>` at the end is an indented comment.
    try expectLexFailure("<# #", .unterminated_comment, 0, 2);
    var storage: [8]Token = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try kinds("<#>", &storage)).len + 1);
    // A string that holds `<#` is a string, so nothing is unterminated.
    try expectTokens("\"<#\" A", &.{ .{ "\"<#\"", .string }, .{ "A", .identifier } });
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "A:i64=1 <# never closed", .unterminated_comment);
    try expectRefused(h, "A:i64=1\n<# one <# two #>\nB:i64=2", .unterminated_comment);
}

test "indented comments: the marker's line and the lines indented four columns past it" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\<#>
        \\    E<public>:i64=99
        \\    deeper ( [ {
        \\        and deeper
        \\
        \\F<public>:i64=6
        \\G<public>:i64=7
        \\<#> text on the marker line ( [
        \\    ignored ( [ {
        \\H<public>:i64=8
        \\M<public>:i64=Block{
        \\    <#>
        \\        inner ) ] }
        \\    9
        \\}
        \\I<public>:i64=10
    );
    try std.testing.expect(x.get("E") == null);
    try std.testing.expectEqual(@as(i64, 6), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.get("G").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("H").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("M").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.get("I").?.integer);
}

test "indented comments: where they end, blank lines, carriage returns and the end of the source" {
    try expectTokens("A\n<#>\n    x\n    y\nB", &.{ .{ "A", .identifier }, .{ "\n", .newline }, .{ "\n", .newline }, .{ "B", .identifier } });
    // Three columns are not a body line.
    try expectTokens("<#>\n   x\nB", &.{ .{ "\n", .newline }, .{ "x", .identifier }, .{ "\n", .newline }, .{ "B", .identifier } });
    // The body is indented past the marker's own line, wherever the marker stands on it.
    try expectTokens("  <#>\n    x\n  B", &.{ .{ "\n", .newline }, .{ "x", .identifier }, .{ "\n", .newline }, .{ "B", .identifier } });
    try expectTokens("  <#>\n      x\n  B", &.{ .{ "\n", .newline }, .{ "B", .identifier } });
    // Blank lines inside belong to it; the lines after the last body line do not.
    try expectTokens("A\n<#> note\n    x\n\n    y\n\nB", &.{ .{ "A", .identifier }, .{ "\n", .newline }, .{ "\n", .newline }, .{ "\n", .newline }, .{ "B", .identifier } });
    try expectTokens("<#>\r\n    x\r\n\r\n    y\r\nB", &.{ .{ "\n", .newline }, .{ "B", .identifier } });
    // A tab is four columns: one tab is a body line, a space and a tab are five, two spaces are not.
    try expectTokens("<#>\n\tx\nB", &.{ .{ "\n", .newline }, .{ "B", .identifier } });
    try expectTokens("<#>\n \tx\nB", &.{ .{ "\n", .newline }, .{ "B", .identifier } });
    try expectTokens("<#>\n  x\nB", &.{ .{ "\n", .newline }, .{ "x", .identifier }, .{ "\n", .newline }, .{ "B", .identifier } });
    // A comment that runs to the end of the source ends there.
    try expectTokens("A\n<#>\n    x", &.{ .{ "A", .identifier }, .{ "\n", .newline } });
    // White space before the marker is fine; anything else is the marker out of place, which
    // keeps the lines the scanners of generic headers see in step with the lexer's.
    try expectTokens("  \t<#>", &.{});
    try expectLexFailure("A <#> x", .misplaced_indented_comment, 2, 5);
    try expectLexFailure("<# c #> <#>", .misplaced_indented_comment, 8, 11);
    try expectLexFailure("A\n  B <#>\n    x", .misplaced_indented_comment, 6, 9);
    // Inside a block comment the same text is a nested comment, wherever it stands.
    try expectTokens("<# a <#> b #> c #>", &.{});
}

test "an indented comment in the header of an indented generic declaration is text for all three readers" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\    Pick[T:type,
        \\        <#>
        \\            why ) ] [ (
        \\        U:type](A:T,B:U)<computes>:T{A}
        \\R<public>:i64=Pick[i64,string](1,"a")
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("R").?.integer);
    try expectRefused(h, "Pick[T:type, <#> why\n        U:type](A:T,B:U)<computes>:T{A}", .misplaced_indented_comment);
}

test "qualification reads a typed definition and a comment between a name and its type" {
    const Both = struct { first: compiler.Workspace, written: [types.limits.modules]types.Span };
    const both = try scratch.storage(Both);
    scratch.initialise(both);
    defer scratch.release(both);
    const source =
        \\A<public>:i64:=3
        \\F(N:i64)<transacts>:i64=Block{T <# a note ( #> :i64:=N*2;var U:i64 := 1 <# note ) #> ;set U=U+T;U}
        \\B<public>:i64=F(A) <# a comment before the end #>
        \\
    ;
    both.first.qualify = true;
    const program = both.first.compile(source).ok;
    const text = both.first.qualification(program, &both.written);
    try std.testing.expect(both.first.verifyQualification(program, text) == null);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try qualify.write(text, &out.writer);
    // The qualifier stands before the name of each declaration, the colon of `:=` follows the type.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(/:)A<public>:(/Verse.org/Verse:)i64:=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(local:)U:(/Verse.org/Verse:)i64 := 1") != null);
}

test "a qualifier before the name of a typed definition is read like the name alone" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\B<public>:i64=Block{(local:)X:i64:=3;(local:)X*2}
    );
    try std.testing.expectEqual(@as(i64, 6), x.get("B").?.integer);
}

// Name:type := v

test "a typed definition with := is the definition with =" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Age<public>:=type{_X:i64 where 0<=_X,_X<=120}
        \\F(N:i64)<computes>:i64=Block{Twice:i64:=N*2;Twice+1}
        \\A<public>:i64:=3
        \\B<public>:string := "s"
        \\var C:i64:=10
        \\D<public>:[]i64:=array{1,2}
        \\Old<public>:Age:=30
        \\Local<public>:i64=Block{X:i64:=3;var Y:i64:=4;set Y=Y+X;Y*X}
        \\Call<public>:i64=F(4)
        \\Pair:tuple(i64,i64):=tuple{1,2}
        \\Spaced<public>:i64 := 8
        \\Both<public>:i64=Block{P:i64=1;Q:i64:=2;P+Q}
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqualStrings("s", x.get("B").?.string);
    try std.testing.expectEqual(@as(u32, 2), x.get("D").?.aggregate.elements.end - x.get("D").?.aggregate.elements.start);
    try std.testing.expectEqual(@as(i64, 30), x.get("Old").?.integer);
    try std.testing.expectEqual(@as(i64, 21), x.get("Local").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("Call").?.integer);
    try std.testing.expectEqual(@as(i64, 8), x.get("Spaced").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("Both").?.integer);
}

test "a typed definition with := compiles to the same program as the one with =" {
    const typed = try harness.create();
    defer scratch.release(typed);
    const plain = try harness.create();
    defer scratch.release(plain);
    // Each `:=` of the first is ` =` in the second: the same length, the same positions.
    const with_colon =
        \\A<public>:i64:=3
        \\B:string:="s"
        \\var C:i64:=10
        \\F(N:i64)<transacts>:i64=Block{Twice:i64:=N*2;var T:i64:=1;set T=T+Twice;T}
        \\D<public>:[]i64:=array{1,2}
    ;
    const with_equal =
        \\A<public>:i64 =3
        \\B:string ="s"
        \\var C:i64 =10
        \\F(N:i64)<transacts>:i64=Block{Twice:i64 =N*2;var T:i64 =1;set T=T+Twice;T}
        \\D<public>:[]i64 =array{1,2}
    ;
    try std.testing.expectEqual(with_colon.len, with_equal.len);
    const a = try typed.compile(with_colon);
    const b = try plain.compile(with_equal);
    try std.testing.expectEqualDeep(a.nodes, b.nodes);
    try std.testing.expectEqualDeep(a.bindings, b.bindings);
    // TASK-0109, W4.6 review: a function's parameter array is set only up to its count; the rest is
    // undefined, so it is compared up to the count (a Debug build fills it with a marker).
    try std.testing.expectEqual(a.functions.len, b.functions.len);
    for (a.functions, b.functions) |left, right| {
        try std.testing.expectEqual(left.parameter_count, right.parameter_count);
        try std.testing.expectEqualDeep(left.parameters[0..left.parameter_count], right.parameters[0..right.parameter_count]);
        var same = left;
        @memcpy(same.parameters[same.parameter_count..], right.parameters[right.parameter_count..]);
        try std.testing.expectEqualDeep(same, right);
    }
    try std.testing.expectEqualDeep(a.function_nodes, b.function_nodes);
    try std.testing.expectEqualDeep(a.source_cells, b.source_cells);
    try std.testing.expectEqualDeep(a.fields, b.fields);
    try std.testing.expectEqualSlices(u8, a.strings, b.strings);
}

test "a typed := that is not a definition stays refused" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        // `var` still needs its type, and an inferred definition still needs none.
        .{ "var A:=3", .expected_type },
        // The colon and the equal sign are one token pair, with nothing between them.
        .{ "A:i64: =3", .expected_equal },
        .{ "A:i64:\n=3", .expected_equal },
        .{ "A:i64:=", .expected_expression },
        .{ "A:i64:=\"s\"", .type_mismatch },
        .{ "A:string:=3", .type_mismatch },
        .{ "var A:i64:=\"s\"", .type_mismatch },
        .{ "A:i64:=1\nA:i64:=2", .duplicate_name },
        // After a comma a field does not start a statement: the first field is read, the second not.
        .{ "P:=struct{X:i64 := 0, Y:i64 := 0}", .unexpected_token },
        // Only a statement can define: a parameter or an argument is no definition.
        .{ "F(X:i64:=1)<computes>:i64=X", .expected_parameter },
        .{ "F(X:i64)<computes>:i64=X\nA:i64=F(Y:i64:=1)", .unknown_name },
    }) |case| try expectRefused(h, case[0], case[1]);
}

test "dropTypedInitializerColons leaves every other colon and equal sign alone" {
    // A colon is dropped only by the pass, so counting them in the text and in the tokens shows it.
    const unchanged = [_][]const u8{
        "A:=3",
        "A : = 3",
        "A:i64=3",
        "A:=Foo{X:=1,Y:=2}",
        "F(?A:=1,B:=2)",
        "F(A:i64,B:i64:=2)",
        "A:i64\n:=3",
        "A:i64,B:i64:=3",
        "A:=3;B:=4",
        "Case(X,A:=1)",
        "A<public>:=type{_X:i64 where _X>0}",
        "A[T:type]:=3",
    };
    for (unchanged) |source| {
        var storage: [64]Token = undefined;
        var colons: usize = 0;
        for (source) |byte| colons += @intFromBool(byte == ':');
        var seen: usize = 0;
        for (try kinds(source, &storage)) |token| seen += @intFromBool(token.kind == .colon);
        try std.testing.expectEqual(colons, seen);
    }
    var storage: [32]Token = undefined;
    // The ones the pass applies to lose exactly the colon of the `:=`.
    const dropped = [_][]const u8{ "(/:)A<public>:i64:=3", "Block{(local:)X:i64:=3;X}", "A:i64:=3", "var A:i64:=3", "A<public>:i64:=3", "X;A:i64 := 3", "{A:i64:=3}", "A:[]i64:=array{}", "A:tuple(i64,i64):=(1,2)", "A:type{_X:i64 where _X>0}:=3" };
    for (dropped) |source| {
        var colons: usize = 0;
        for (source) |byte| colons += @intFromBool(byte == ':');
        var seen: usize = 0;
        for (try kinds(source, &storage)) |token| seen += @intFromBool(token.kind == .colon);
        if (seen + 1 != colons) std.debug.print("lexical test: {s} kept {d} of {d} colons\n", .{ source, seen, colons });
        try std.testing.expectEqual(colons, seen + 1);
    }
}

// Boundaries

test "block comments nest to the length of the source and no further" {
    const allocator = std.testing.allocator;
    const limit = types.limits.source_bytes;
    const source = try allocator.alloc(u8, limit);
    defer allocator.free(source);
    const tokens = try allocator.alloc(Token, 4);
    defer allocator.free(tokens);
    // A full source of `<#` and `#>` in equal numbers, with the padding in the middle.
    const pairs = limit / 4;
    @memset(source, ' ');
    for (0..pairs) |index| {
        source[2 * index] = '<';
        source[2 * index + 1] = '#';
        source[limit - 2 * index - 2] = '#';
        source[limit - 2 * index - 1] = '>';
    }
    const result = lexer.tokenize(source, tokens);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(usize, 1), result.ok.len);
    // One closing mark fewer leaves the outermost comment open, at its own position.
    source[limit - 1] = ' ';
    source[limit - 2] = ' ';
    const open = lexer.tokenize(source, tokens);
    try std.testing.expectEqual(types.Diagnostic.Code.unterminated_comment, open.failed.code);
    try std.testing.expectEqual(@as(u32, 0), open.failed.span.start);
    // And a source one byte over the limit is the source limit, comments or not.
    const over = try allocator.alloc(u8, limit + 1);
    defer allocator.free(over);
    @memset(over, ' ');
    try std.testing.expectEqual(types.Diagnostic.Code.source_limit, lexer.tokenize(over, tokens).failed.code);
}

test "hexadecimal literals at the 64-bit bound across the whole range of digits" {
    var prng = std.Random.DefaultPrng.init(0x0b1);
    const random = prng.random();
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [128]u8 = undefined;
    for (0..64) |round| {
        const value: i64 = switch (round) {
            0 => 0,
            1 => std.math.maxInt(i64),
            2 => std.math.minInt(i64),
            3 => -1,
            else => random.int(i64) >> @intCast(random.uintLessThan(u6, 63)),
        };
        // The magnitude in hexadecimal; the most negative value is its own magnitude.
        const magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
        const upper = random.boolean();
        const text = if (upper) try std.fmt.bufPrint(&buffer, "A<public>:i64={s}0x{X}", .{ if (value < 0) "-" else "", magnitude }) else try std.fmt.bufPrint(&buffer, "A<public>:i64={s}0x{x}", .{ if (value < 0) "-" else "", magnitude });
        const x = try h.execute(text);
        if (x.get("A").?.integer != value) std.debug.print("hexadecimal round trip: {s}\n", .{text});
        try std.testing.expectEqual(value, x.get("A").?.integer);
        // The decimal text of the same value reads the same.
        const decimal = try std.fmt.bufPrint(&buffer, "A<public>:i64={d}", .{value});
        try std.testing.expectEqual(value, (try h.execute(decimal)).get("A").?.integer);
    }
}

test "an indented comment ends with its file: the next file of a bundle is lexed as code" {
    const h = try harness.create();
    defer scratch.release(h);
    // lib.forb ends in a `<#>` line; main.forb, joined after it, begins with a line indented
    // four columns, which alone is code and which the joined text must not read as comment.
    const lib = "Value<public>:i64=40\n<#> a note on the last line";
    const main = "    L:=import{\"lib.forb\"}\n    Answer<public>:i64=L.Value+2";
    const inputs = [_]@import("modules.zig").Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (result == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ result.failed.diagnostic.message(), result.failed.path });
    try std.testing.expect(result == .ok);
    const x = (try h.run(result.ok, 1 << 20)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("Answer").?.integer);
    // The comment still takes the lines of its own file: an indented line after the marker is
    // comment, and a file that ends there leaves the next one alone.
    const longer = "Value<public>:i64=40\n<#> a note\n    on two lines\n    and three";
    const inputs_longer = [_]@import("modules.zig").Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = longer } };
    const again = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs_longer });
    try std.testing.expect(again == .ok);
    try std.testing.expectEqual(@as(i64, 42), (try h.run(again.ok, 1 << 20)).ok.get("Answer").?.integer);
}
