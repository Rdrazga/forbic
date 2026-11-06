const std = @import("std");
const types = @import("types.zig");
const Span = types.Span;
const Diagnostic = types.Diagnostic;

pub const Token = struct {
    kind: Kind,
    span: Span,
    /// For a token a macro generated: where the call it was generated for is written, plus
    /// one. Zero for a token of the program's own text. A generated token's span lies in its
    /// module's library block, which says what it spells and not whose it is; this says whose,
    /// so that a diagnostic about generated code can name the call (`Workspace.siteBlame`).
    site: u32 = 0,
    pub const Kind = enum {
        identifier,
        integer,
        string,
        colon,
        equal,
        less,
        greater,
        plus,
        minus,
        star,
        slash,
        left_paren,
        right_paren,
        comma,
        separator,
        newline,
        eof,
        /// Compiler-inserted `Attempt` and `false` (see Workspace.desugarFailableConditions).
        synthetic_attempt,
        synthetic_false,
        synthetic_if,
        /// Last arm of a `Case` without a default: checks that the patterns cover the enum.
        synthetic_exhaustive,
        /// Compiler-inserted `Require` around the guard of a `Case` arm; its span is the guard's.
        synthetic_require,
        synthetic_with_field,
        synthetic_with_index,
        /// `{` of a string interpolation: converts a number, logic or string to text.
        synthetic_interpolate,
        /// Early exit (RFC-0068), placed by the macro pass. `synthetic_exit` is a `Return` of the
        /// function being compiled; `synthetic_defer_mark` stands where a `Defer` was written and
        /// `synthetic_defer` opens a copy of its body where the scope is left; `synthetic_inherit`
        /// gives a generated loop function the effects of the code around it.
        synthetic_exit,
        synthetic_defer_mark,
        synthetic_defer,
        synthetic_inherit,
        /// Stands before the `(` that holds the expansion of a `First[...]`; its span is the word
        /// `First`. It tells an `If` that its condition can fail, which no bracket of the
        /// expansion shows, and that the `Require` of a filter inside belongs to the expansion.
        synthetic_first,
        /// The `Fail` that ends a `Case[...]` no arm of which took the scrutinee (RFC-0080); its
        /// span is the word `Case`.
        synthetic_fail,
        // Escape validation classifies literals without an extra field/store on
        // every token. Ordinary strings can copy their already validated bytes.
        escaped_string,
        floating,
        left_brace,
        right_brace,
        left_bracket,
        right_bracket,
        dot,
        question,
        arrow,
        equal_equal,
        not_equal,
        less_equal,
        greater_equal,
        /// A `char` or `char32` constant: `'a'`, `'\n'`, `'é'`, `0o61` or `0u1f600` (RFC-0069).
        /// The lexer checks its shape; the compiler reads the value with `characterLiteral`.
        character,
        /// RFC-0082, P3.3: placed by the macro pass after the mark of a `Defer` whose scope holds
        /// a suspension site, before a copy of its body in braces that the parser compiles as
        /// the function a cancellation runs. Its span is a library `Fn` word, which names it.
        synthetic_landing,
        /// Stands before the braces the compiler puts around the guard of a live variable
        /// (RFC-0084); its span is the word `live`, which names the guard's function.
        synthetic_guard,
        /// Stands before `(E, F, <guard>{ G })`, which the compiler writes for `set live E.F = G`
        /// (RFC-0084, P4.2); its span is the word `live`.
        synthetic_live_field,
        /// RFC-0084, P4.3: stands after the colon of a declaration whose type may be a function,
        /// before `{ F(<raw>) } <end>` and the type as written: the guard of the variable when the
        /// type names a function or a method path, and skipped when it names a type.
        synthetic_live_type,
        /// The raw value inside that guard: the raw cell, or the raw field of `Self`.
        synthetic_live_raw,
        /// Ends that guard, so that the type as written follows it.
        synthetic_live_end,
        /// RFC-0082, P3.6, placed by the macro pass. `synthetic_arm_exit` and a numeral stand
        /// before the `(...)` of the pending exit an arm of `Sync`, `Race` or `Rush` ends with;
        /// `synthetic_arm_reissue` stands after the last arm of such an expression, before the
        /// code that carries a pending exit on where the expression stands, in which
        /// `synthetic_arm_value` is the value of that exit.
        synthetic_arm_exit,
        synthetic_arm_reissue,
        synthetic_arm_value,
        /// RFC-0090: the `==` of a constant arm of a `Case`, placed by the rewrite with the span
        /// the `==` had; it compares as `==` does, once its left operand, the scrutinee, is seen
        /// to have one of the types the Book's `case` takes.
        synthetic_case_equal,
        /// RFC-0093, B7: a module path, `/Verse.org/Verse` or `/user@example.com/App/Kit`: a `/`
        /// directly after a `{` or a `(` (newlines may stand between), where a division has no
        /// left operand, followed by a segment. The first segment is a domain; the others are
        /// names (`pathEnd`). Whether the path names a module is the bundle's to say.
        path,
    };
};
pub const Result = union(enum) { ok: []const Token, failed: Diagnostic };

pub fn tokenize(source: []const u8, buffer: []Token) Result {
    return tokenizeFiles(source, buffer, &.{});
}

/// `tokenize` for the joined text of a bundle, whose files are `files` in order (their `source`
/// spans, a newline between each): a comment ends where its file ends, as it does when the file is
/// lexed alone. Joined by a newline, an indented comment on the last line of a file would otherwise
/// take the next file's first lines, if they are indented four columns, for its body (RFC-0089).
pub fn tokenizeFiles(source: []const u8, buffer: []Token, files: []const types.Module) Result {
    return tokenizeWithin(types.Module, source, buffer, files);
}

/// `tokenizeFiles` for the text of modules given as folders (RFC-0093): a comment ends where its
/// file ends, and `parts` are the files, each a part of its module's text.
pub fn tokenizeParts(source: []const u8, buffer: []Token, parts: []const types.ModulePart) Result {
    return tokenizeWithin(types.ModulePart, source, buffer, parts);
}

fn tokenizeWithin(comptime File: type, source: []const u8, buffer: []Token, files: []const File) Result {
    if (source.len > types.limits.source_bytes) return failure(0, 0, .source_limit);
    if (!std.unicode.utf8ValidateSlice(source)) return failure(0, 0, .invalid_utf8);
    var cursor: u32 = 0;
    var count: u32 = 0;
    // Open interpolations: the brace depth of the expression being lexed in each.
    var braces: [max_interpolation_depth]u32 = undefined;
    var open: usize = 0;
    // The file the cursor is in; the cursor only moves forward.
    var file: usize = 0;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (byte == ' ' or byte == '\t' or byte == '\r') {
            cursor += 1;
            continue;
        }
        if (byte == '#' or (byte == '<' and cursor + 1 < source.len and source[cursor + 1] == '#')) {
            while (file < files.len and files[file].source.end <= cursor) file += 1;
            const limit = if (file < files.len) files[file].source.end else source.len;
            cursor = switch (comment(source[0..limit], cursor)) {
                .end => |end| @intCast(end),
                .unterminated => return failure(cursor, cursor + 2, .unterminated_comment),
                .misplaced => return failure(cursor, cursor + 3, .misplaced_indented_comment),
            };
            continue;
        }
        const start = cursor;
        var has_escapes = false;
        const kind: Token.Kind = if (isNameStart(byte)) name: {
            cursor += 1;
            while (cursor < source.len and isNameContinue(source[cursor])) : (cursor += 1) {}
            if (cursor - start > types.limits.identifier_bytes) return failure(start, cursor, .identifier_limit);
            break :name .identifier;
        } else if (byte == '\'') character: {
            cursor = scanQuotedCharacter(source, start) orelse return failure(start, quotedCharacterEnd(source, start), .invalid_char_literal);
            break :character .character;
        } else if (byte == '0' and numericCharacterEnd(source, start) != null) character: {
            cursor = numericCharacterEnd(source, start).?;
            break :character .character;
        } else if (std.ascii.isDigit(byte)) number: {
            if (byte == '0' and cursor + 1 < source.len and source[cursor + 1] == 'x') {
                cursor = hexadecimalEnd(source, start) orelse return failure(start, hexadecimalTextEnd(source, start), .invalid_hex_literal);
                break :number .integer;
            }
            cursor += 1;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) : (cursor += 1) {}
            if (cursor < source.len) {
                const suffix = source[cursor];
                // `1..9` is a range between two integers, not a float with an empty fraction.
                const range = suffix == '.' and cursor + 1 < source.len and source[cursor + 1] == '.';
                // `7.Double()` calls an extension method on an integer: a dot before a name
                // starts a member access (a float needs a digit there, so nothing else read so).
                const member = suffix == '.' and cursor + 1 < source.len and isNameStart(source[cursor + 1]);
                if (!range and !member and (suffix == '.' or suffix | 0x20 == 'e')) {
                    if (scanFloatTail(source, start, &cursor)) |diagnostic| return .{ .failed = diagnostic };
                    break :number .floating;
                }
            }
            break :number .integer;
        } else if (byte == '/' and pathMayStart(buffer[0..count]) and cursor + 1 < source.len and isDomainStart(source[cursor + 1])) path: {
            cursor = @intCast(pathEnd(source, start));
            break :path .path;
        } else if (byte == '"') string: {
            const outcome = scanFragment(source, &cursor, &has_escapes);
            if (outcome == .failed) return .{ .failed = outcome.failed };
            if (outcome == .interpolate) {
                // `"a{X}b"` becomes `("a" + ToString(X) + "b")`: the fragments keep the quote or
                // brace on each side, which the decoder already strips.
                if (open == max_interpolation_depth) return failure(start, cursor, .interpolation_depth);
                if (!push(buffer, &count, .left_paren, start, start + 1)) return failure(start, cursor, .token_limit);
                if (cursor - start > 2) {
                    if (!push(buffer, &count, if (has_escapes) .escaped_string else .string, start, cursor)) return failure(start, cursor, .token_limit);
                    if (!push(buffer, &count, .plus, cursor - 1, cursor)) return failure(start, cursor, .token_limit);
                }
                if (!push(buffer, &count, .synthetic_interpolate, cursor - 1, cursor) or !push(buffer, &count, .left_paren, cursor - 1, cursor)) return failure(start, cursor, .token_limit);
                braces[open] = 0;
                open += 1;
                continue;
            }
            break :string if (has_escapes) .escaped_string else .string;
        } else punctuation: {
            cursor += 1;
            break :punctuation switch (byte) {
                ':' => .colon,
                '=' => arrow: {
                    if (cursor < source.len and source[cursor] == '>') {
                        cursor += 1;
                        break :arrow .arrow;
                    }
                    if (cursor < source.len and source[cursor] == '=') {
                        cursor += 1;
                        break :arrow .equal_equal;
                    }
                    break :arrow .equal;
                },
                '<', '>', '!' => compare: {
                    if (cursor < source.len and source[cursor] == '=') {
                        cursor += 1;
                        break :compare if (byte == '<') .less_equal else if (byte == '>') .greater_equal else .not_equal;
                    }
                    if (byte == '!') return failure(start, cursor, .invalid_character);
                    break :compare if (byte == '<') .less else .greater;
                },
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '{' => brace: {
                    if (open > 0) braces[open - 1] += 1;
                    break :brace .left_brace;
                },
                '}' => brace: {
                    if (open == 0) break :brace .right_brace;
                    if (braces[open - 1] > 0) {
                        braces[open - 1] -= 1;
                        break :brace .right_brace;
                    }
                    // The brace closes an interpolation: end `ToString(` and resume the string.
                    cursor = start;
                    const outcome = scanFragment(source, &cursor, &has_escapes);
                    if (outcome == .failed) return .{ .failed = outcome.failed };
                    const kind: Token.Kind = if (has_escapes) .escaped_string else .string;
                    const text_present = cursor - start > 2;
                    if (!push(buffer, &count, .right_paren, start, start + 1)) return failure(start, cursor, .token_limit);
                    if (text_present) {
                        if (!push(buffer, &count, .plus, start, start + 1) or !push(buffer, &count, kind, start, cursor)) return failure(start, cursor, .token_limit);
                    }
                    if (outcome == .interpolate) {
                        if (!push(buffer, &count, .plus, cursor - 1, cursor) or !push(buffer, &count, .synthetic_interpolate, cursor - 1, cursor) or !push(buffer, &count, .left_paren, cursor - 1, cursor)) return failure(start, cursor, .token_limit);
                    } else {
                        if (!push(buffer, &count, .right_paren, cursor - 1, cursor)) return failure(start, cursor, .token_limit);
                        open -= 1;
                    }
                    continue;
                },
                '[' => .left_bracket,
                ']' => .right_bracket,
                '.' => .dot,
                '?' => .question,
                '(' => .left_paren,
                ')' => .right_paren,
                ',' => .comma,
                ';' => .separator,
                '\n' => .newline,
                else => return failure(start, cursor, .invalid_character),
            };
        };
        // Reserve one slot for EOF, so every successful token stream has a sentinel.
        if (count + 1 >= buffer.len) return failure(start, cursor, .token_limit);
        buffer[count] = .{ .kind = kind, .span = .{ .start = start, .end = cursor } };
        std.debug.assert(start < cursor and cursor <= source.len);
        count += 1;
    }
    if (open != 0) return failure(cursor, cursor, .unterminated_string);
    count = @intCast(dropTypedInitializerColons(source, buffer[0..count]));
    if (count >= buffer.len) return failure(cursor, cursor, .token_limit);
    buffer[count] = .{ .kind = .eof, .span = .{ .start = cursor, .end = cursor } };
    std.debug.assert(cursor == source.len);
    std.debug.assert(count < buffer.len);
    return .{ .ok = buffer[0 .. count + 1] };
}

const max_interpolation_depth = 8;

const DeclarationState = enum { start, qualifier, after_var, named, specifier, typed, other };

/// The Book writes a constant or a variable with an explicit type as `Name:type = v` or as
/// `Name:type := v` (04:368). The second spelling has the meaning of the first, so this pass
/// removes the colon of its `:=` and the parser reads the first. A declaration is an optional
/// qualifier `(...)`, `[var] Name`, optional `<specifier>`s, a colon that does not belong to `:=`, then a type, at the start of a
/// statement: after a newline, a `;`, a `{` or the start of the source. The colon goes only when
/// it is directly followed, with no space, by the `=` and nothing but the type lies between: an
/// `=` or a `,` at the bracket depth of the type ends the search. Everything else is left as it
/// was, including `Name := v` and the named arguments `?Name := v`, whose colon follows the
/// name at once. One forward pass, no lookahead beyond the next token, and no storage:
/// the brackets of a type are counted, not stacked. Returns the number of tokens kept.
fn dropTypedInitializerColons(source: []const u8, tokens: []Token) usize {
    var write: usize = 0;
    var state: DeclarationState = .start;
    var nest: usize = 0;
    for (tokens, 0..) |token, read| {
        var keep = true;
        if (state == .typed and nest != 0) {
            switch (token.kind) {
                .left_paren, .left_bracket, .left_brace => nest += 1,
                .right_paren, .right_bracket, .right_brace => nest -= 1,
                else => {},
            }
        } else switch (token.kind) {
            .newline, .separator => state = .start,
            .left_brace => if (state == .typed) {
                nest += 1;
            } else {
                state = .start;
            },
            // `(/:)Name` and `(local:)Name`, the qualified forms `forbic qualify` prints, may
            // stand before the name of a declaration.
            .left_paren => if (state == .typed) {
                nest += 1;
            } else {
                state = if (state == .start) .qualifier else .other;
            },
            .left_bracket => if (state == .typed) {
                nest += 1;
            } else {
                state = .other;
            },
            .right_paren => state = if (state == .qualifier) .start else .other,
            .right_bracket, .right_brace, .comma => state = .other,
            else => switch (state) {
                .start => state = if (token.kind != .identifier) .other else if (std.mem.eql(u8, token.span.text(source), "var")) .after_var else .named,
                .qualifier => {},
                .after_var => state = if (token.kind == .identifier) .named else .other,
                .named => switch (token.kind) {
                    .less => state = .specifier,
                    .colon => {
                        const next = if (read + 1 < tokens.len) tokens[read + 1].kind else Token.Kind.eof;
                        state = if (next == .equal) .other else .typed;
                        nest = 0;
                    },
                    else => state = .other,
                },
                .specifier => if (token.kind == .greater) {
                    state = .named;
                },
                .typed => switch (token.kind) {
                    .equal => state = .other,
                    .colon => if (read + 1 < tokens.len and tokens[read + 1].kind == .equal and token.span.end == tokens[read + 1].span.start) {
                        keep = false;
                        state = .other;
                    },
                    else => {},
                },
                .other => {},
            },
        }
        if (keep) {
            tokens[write] = token;
            write += 1;
        }
    }
    std.debug.assert(write <= tokens.len);
    return write;
}

/// Where a comment that opens at some position ends. `unterminated` is a block comment that
/// reaches the end of the source before its `#>`, and `misplaced` an indented comment `<#>` that
/// is not the first thing on its line (RFC-0089).
pub const Comment = union(enum) { end: usize, unterminated, misplaced };

/// A body line of an indented comment (`<#>`) is indented this many columns past the line of the
/// marker; the Book says "four spaces". A space is one column and a tab is four.
pub const indented_comment_columns = 4;

/// The comment that opens at `at`, where `source[at]` is `#` or `source[at..]` begins with `<#`.
/// The end is the position of the newline that closes a line comment (the newline is still a
/// token), the position after the `#>` of a block comment, and the position of the newline that
/// follows the last body line of an indented comment. Block comments nest and are not aware of
/// strings or of `#`; the nesting depth is a counter bounded by half the source length, so
/// there is no stack to size. Inside a block comment `<#` is read before `#>`: `<#>` opens a
/// nested comment. The scanners of generic headers (aggregate_types.zig, evaluator.zig) call
/// this too, so that a bracket in a comment is text for them as it is for the lexer.
pub fn comment(source: []const u8, at: usize) Comment {
    std.debug.assert(at < source.len);
    std.debug.assert(source[at] == '#' or (source[at] == '<' and at + 1 < source.len and source[at + 1] == '#'));
    if (source[at] == '#') return .{ .end = lineEnd(source, at) };
    if (at + 2 < source.len and source[at + 2] == '>') {
        // The Book writes the marker "on its own line", and a rule that reads only the line
        // keeps the scanners of generic headers, which see a slice of the source that starts at a
        // name, in step with the lexer: the marker of a slice is never on its first line.
        var before = at;
        while (before > 0 and (source[before - 1] == ' ' or source[before - 1] == '\t')) before -= 1;
        if (before != 0 and source[before - 1] != '\n') return .misplaced;
        return .{ .end = indentedCommentEnd(source, at) };
    }
    var depth: usize = 1;
    var cursor = at + 2;
    while (cursor + 1 < source.len) {
        if (source[cursor] == '<' and source[cursor + 1] == '#') {
            depth += 1;
            cursor += 2;
        } else if (source[cursor] == '#' and source[cursor + 1] == '>') {
            depth -= 1;
            cursor += 2;
            if (depth == 0) return .{ .end = cursor };
        } else cursor += 1;
    }
    return .unterminated;
}

/// Whether a comment opens at `at`.
pub fn commentOpens(source: []const u8, at: usize) bool {
    return source[at] == '#' or (source[at] == '<' and at + 1 < source.len and source[at + 1] == '#');
}

/// The end of the comment that opens at `at` for a scanner of source the lexer has accepted:
/// an unterminated block comment cannot occur there, and would end at the end of the text.
pub fn commentEnd(source: []const u8, at: usize) usize {
    return switch (comment(source, at)) {
        .end => |end| end,
        .unterminated, .misplaced => source.len,
    };
}

fn lineEnd(source: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, from, '\n') orelse source.len;
}

/// The columns of the spaces and tabs a line begins with.
fn indentation(source: []const u8, line_start: usize) usize {
    var columns: usize = 0;
    var cursor = line_start;
    while (cursor < source.len) : (cursor += 1) {
        switch (source[cursor]) {
            ' ' => columns += 1,
            '\t' => columns += 4,
            else => break,
        }
    }
    return columns;
}

/// The end of the indented comment whose `<#>` is at `at`: the rest of that line, and then
/// every following line that is blank or indented `indented_comment_columns` past the marker's
/// line. Blank lines count only when a body line follows them, so the end is the end of the last
/// body line and the newline after it stays a token.
fn indentedCommentEnd(source: []const u8, at: usize) usize {
    var line_start = at;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    const required = indentation(source, line_start) + indented_comment_columns;
    var end = lineEnd(source, at);
    var cursor = end;
    while (cursor < source.len) {
        std.debug.assert(source[cursor] == '\n');
        const line = cursor + 1;
        const stop = lineEnd(source, line);
        const blank = std.mem.indexOfNone(u8, source[line..stop], " \t\r") == null;
        if (!blank) {
            if (indentation(source, line) < required) break;
            end = stop;
        }
        cursor = stop;
    }
    std.debug.assert(end >= at + 3 and end <= source.len);
    return end;
}

/// The end of the hexadecimal literal `0x...` at `start`, or null when it has no digit, is
/// followed by a name character, or by a `.` and a digit (which would read as a fraction).
fn hexadecimalEnd(source: []const u8, start: u32) ?u32 {
    std.debug.assert(source[start] == '0' and source[start + 1] == 'x');
    var end = start + 2;
    while (end < source.len and std.ascii.isHex(source[end])) : (end += 1) {}
    if (end == start + 2) return null;
    if (end < source.len and isNameContinue(source[end])) return null;
    if (end + 1 < source.len and source[end] == '.' and std.ascii.isDigit(source[end + 1])) return null;
    return end;
}

/// Where the diagnostic for a bad hexadecimal literal ends: after the name characters and
/// digits that stick to the `0x`.
fn hexadecimalTextEnd(source: []const u8, start: u32) u32 {
    var end = start + 2;
    while (end < source.len and isNameContinue(source[end])) : (end += 1) {}
    return end;
}

/// The magnitude an `integer` token spells, decimal or `0x`; null when it does not fit in 64
/// bits (the caller checks the signed range, which depends on a minus before the literal).
/// `text` is a token the lexer produced.
pub fn integerMagnitude(text: []const u8) ?u64 {
    std.debug.assert(text.len >= 1);
    if (text.len > 2 and text[0] == '0' and text[1] == 'x') return std.fmt.parseInt(u64, text[2..], 16) catch null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// The digits of a `floating` token without its optional `f64` suffix.
pub fn floatDigits(text: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, text, "f64")) text[0 .. text.len - 3] else text;
}

/// The value a `character` token spells and which type it has: `char` for an ASCII character in
/// quotes and for `0oXX`, `char32` for any other character in quotes and for `0uXXXXXX`. Null
/// when `0u...` names no Unicode scalar value. `text` is a token the lexer produced.
pub const Character = struct { code: u32, wide: bool };
pub fn characterLiteral(text: []const u8) ?Character {
    std.debug.assert(text.len >= 3);
    if (text[0] == '0') {
        const code = std.fmt.parseInt(u32, text[2..], 16) catch unreachable;
        if (text[1] == 'o') return .{ .code = code, .wide = false };
        return if (types.validCharacter(types.Type.char32, code)) .{ .code = code, .wide = true } else null;
    }
    std.debug.assert(text[0] == '\'' and text[text.len - 1] == '\'');
    const body = text[1 .. text.len - 1];
    if (body[0] == '\\') return .{ .code = switch (body[1]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => |escaped| escaped,
    }, .wide = false };
    const code = std.unicode.utf8Decode(body) catch unreachable;
    return .{ .code = code, .wide = code >= 0x80 };
}

/// `0oXX` (two hexadecimal digits) or `0uX` ... `0uXXXXXX` (one to six), not followed by a
/// name character: the end of that token when `source[start..]` begins with one. Anything
/// else stays what it was, an integer followed by a name, so `0or` is still `0 or`.
fn numericCharacterEnd(source: []const u8, start: u32) ?u32 {
    std.debug.assert(source[start] == '0');
    if (start + 1 >= source.len) return null;
    const wide = source[start + 1] == 'u';
    if (!wide and source[start + 1] != 'o') return null;
    var end = start + 2;
    while (end < source.len and std.ascii.isHex(source[end])) : (end += 1) {}
    const digits = end - start - 2;
    if (if (wide) digits == 0 or digits > 6 else digits != 2) return null;
    if (end < source.len and isNameContinue(source[end])) return null;
    return end;
}

/// The end of the quoted character that opens at `start`, or null when what follows the quote
/// is not exactly one character or one of the Book's escapes and a closing quote.
fn scanQuotedCharacter(source: []const u8, start: u32) ?u32 {
    std.debug.assert(source[start] == '\'');
    var cursor = start + 1;
    if (cursor >= source.len) return null;
    const first = source[cursor];
    if (first == '\\') {
        if (cursor + 1 >= source.len) return null;
        switch (source[cursor + 1]) {
            'n', 'r', 't', '\\', '"', '\'', '{', '}', '<', '>', '&', '#', '~' => {},
            else => return null,
        }
        cursor += 2;
    } else {
        // The source is valid UTF-8, so a lead byte has its continuation bytes.
        if (first < 0x20 or first == '\'' or first == 0x7f) return null;
        cursor += std.unicode.utf8ByteSequenceLength(first) catch unreachable;
    }
    if (cursor >= source.len or source[cursor] != '\'') return null;
    return cursor + 1;
}

/// Where a diagnostic for a malformed quoted character ends: the closing quote on its line,
/// when there is one, and otherwise the opening quote alone.
fn quotedCharacterEnd(source: []const u8, start: u32) u32 {
    var cursor = start + 1;
    while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {
        if (source[cursor] == '\'') return cursor + 1;
    }
    return start + 1;
}

fn push(buffer: []Token, count: *u32, kind: Token.Kind, start: u32, end: u32) bool {
    // Reserve one slot for EOF, so every successful token stream has a sentinel.
    if (count.* + 1 >= buffer.len) return false;
    buffer[count.*] = .{ .kind = kind, .span = .{ .start = start, .end = end } };
    count.* += 1;
    return true;
}

const Fragment = union(enum) { done, interpolate, failed: Diagnostic };

/// Scans a string literal or the rest of one after an interpolation. `cursor` is on the opening
/// `"` or on the `}` that closes an interpolation; scanning stops after the closing `"` or after
/// the `{` that opens the next interpolation. A `{` or `}` is escaped as `\{` and `\}`.
fn scanFragment(source: []const u8, cursor: *u32, has_escapes: *bool) Fragment {
    const start = cursor.*;
    std.debug.assert(start < source.len);
    std.debug.assert(source[start] == '"' or source[start] == '}');
    var contains_escape = false;
    cursor.* += 1;
    while (cursor.* < source.len) {
        const byte = source[cursor.*];
        cursor.* += 1;
        if (byte == '"' or byte == '{') {
            has_escapes.* = contains_escape;
            std.debug.assert(cursor.* >= start + 2 and cursor.* <= source.len);
            return if (byte == '"') .done else .interpolate;
        }
        if (byte == '\n' or byte == '\r') break;
        if (byte < 0x20) return .{ .failed = .{ .span = .{ .start = cursor.* - 1, .end = cursor.* }, .code = .invalid_escape } };
        if (byte != '\\') continue;
        contains_escape = true;
        if (cursor.* == source.len) break;
        const escaped = source[cursor.*];
        cursor.* += 1;
        switch (escaped) {
            'n', 'r', 't', '\\', '"', '\'', '{', '}', '<', '>', '&', '#', '~' => {},
            else => return .{ .failed = .{ .span = .{ .start = cursor.* - 2, .end = cursor.* }, .code = .invalid_escape } },
        }
    }
    return .{ .failed = .{ .span = .{ .start = start, .end = cursor.* }, .code = .unterminated_string } };
}

// Keep decimal/exponent processing off the integer/string/name token hot path.
// The caller has consumed a nonempty integer prefix and admitted a float suffix.
noinline fn scanFloatTail(source: []const u8, start: u32, cursor: *u32) ?Diagnostic {
    std.debug.assert(start < cursor.* and cursor.* < source.len);
    std.debug.assert(source[cursor.*] == '.' or source[cursor.*] == 'e' or source[cursor.*] == 'E');
    if (source[cursor.*] == '.') {
        cursor.* += 1;
        const fraction = cursor.*;
        while (cursor.* < source.len and std.ascii.isDigit(source[cursor.*])) : (cursor.* += 1) {}
        if (cursor.* == fraction) return .{ .span = .{ .start = start, .end = cursor.* }, .code = .invalid_number };
    }
    if (cursor.* < source.len and (source[cursor.*] == 'e' or source[cursor.*] == 'E')) {
        cursor.* += 1;
        if (cursor.* < source.len and (source[cursor.*] == '+' or source[cursor.*] == '-')) cursor.* += 1;
        const exponent = cursor.*;
        while (cursor.* < source.len and std.ascii.isDigit(source[cursor.*])) : (cursor.* += 1) {}
        if (cursor.* == exponent) return .{ .span = .{ .start = start, .end = cursor.* }, .code = .invalid_number };
    }
    // The optional `f64` suffix is a suffix only when no name character follows it: `1.5f64x`
    // stays the float and the name it always was.
    const suffix = source[cursor.*..];
    if (std.mem.startsWith(u8, suffix, "f64") and (suffix.len == 3 or !isNameContinue(suffix[3]))) cursor.* += 3;
    std.debug.assert(cursor.* > start + 1 and cursor.* <= source.len);
    return null;
}

fn failure(start: u32, end: u32, code: Diagnostic.Code) Result {
    std.debug.assert(start <= end);
    return .{ .failed = .{ .span = .{ .start = start, .end = end }, .code = code } };
}
/// Whether a `/` after the tokens `before` starts a path: the token before it, newlines aside,
/// opens a brace or a parenthesis. A division needs a left operand there, so no program read a
/// `/` in that place before paths: `using{/A/B}`, `import{/A/B}`.
fn pathMayStart(before: []const Token) bool {
    var at = before.len;
    while (at > 0 and before[at - 1].kind == .newline) at -= 1;
    if (at == 0) return false;
    return before[at - 1].kind == .left_brace or before[at - 1].kind == .left_paren;
}
/// The bytes of a domain segment, the first of a path: `Verse.org`, `user@example.com`, `My-Org`.
pub fn isDomainStart(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
pub fn isDomainContinue(byte: u8) bool {
    return isDomainStart(byte) or byte == '.' or byte == '@' or byte == '-';
}
/// The end of the path that starts with the `/` at `start`: the domain, then every `/` that is
/// followed by a name and that name. A `/` followed by anything else ends the path before it.
pub fn pathEnd(source: []const u8, start: usize) usize {
    std.debug.assert(source[start] == '/' and start + 1 < source.len and isDomainStart(source[start + 1]));
    var cursor = start + 1;
    while (cursor < source.len and isDomainContinue(source[cursor])) cursor += 1;
    while (cursor + 1 < source.len and source[cursor] == '/' and isNameStart(source[cursor + 1])) {
        cursor += 2;
        while (cursor < source.len and isNameContinue(source[cursor])) cursor += 1;
    }
    return cursor;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}
fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte);
}

test "invalid UTF-8 and incomplete strings produce bounded diagnostics" {
    var tokens: [32]Token = undefined;
    try std.testing.expectEqual(Diagnostic.Code.invalid_utf8, tokenize("\xff", &tokens).failed.code);
    try std.testing.expectEqual(Diagnostic.Code.unterminated_string, tokenize("A:string = \"abc\n", &tokens).failed.code);
    try std.testing.expectEqual(Diagnostic.Code.invalid_escape, tokenize("\"\\x\"", &tokens).failed.code);
    try std.testing.expectEqual(Diagnostic.Code.token_limit, tokenize("A:i64=1", tokens[0..2]).failed.code);
}

test "character tokens: quotes, escapes, numeric forms, and what stays an integer" {
    var tokens: [32]Token = undefined;
    const source = "'a' '\\n' '\\'' '\xc3\xa9' '\xf0\x9f\x98\x80' 0o61 0oFF 0u1f600 0uE9 0or 0o6 0o611 0u 0u1234567 0o61x";
    const result = tokenize(source, &tokens).ok;
    const expected = [_]struct { text: []const u8, kind: Token.Kind }{
        .{ .text = "'a'", .kind = .character },
        .{ .text = "'\\n'", .kind = .character },
        .{ .text = "'\\''", .kind = .character },
        .{ .text = "'\xc3\xa9'", .kind = .character },
        .{ .text = "'\xf0\x9f\x98\x80'", .kind = .character },
        .{ .text = "0o61", .kind = .character },
        .{ .text = "0oFF", .kind = .character },
        .{ .text = "0u1f600", .kind = .character },
        .{ .text = "0uE9", .kind = .character },
        // Not a character: the integer and the name they always were.
        .{ .text = "0", .kind = .integer },
        .{ .text = "or", .kind = .identifier },
        .{ .text = "0", .kind = .integer },
        .{ .text = "o6", .kind = .identifier },
        .{ .text = "0", .kind = .integer },
        .{ .text = "o611", .kind = .identifier },
        .{ .text = "0", .kind = .integer },
        .{ .text = "u", .kind = .identifier },
        .{ .text = "0", .kind = .integer },
        .{ .text = "u1234567", .kind = .identifier },
        .{ .text = "0", .kind = .integer },
        .{ .text = "o61x", .kind = .identifier },
    };
    try std.testing.expectEqual(expected.len + 1, result.len);
    for (expected, result[0..expected.len]) |want, token| {
        try std.testing.expectEqualStrings(want.text, token.span.text(source));
        try std.testing.expectEqual(want.kind, token.kind);
    }
    const values = [_]Character{ .{ .code = 'a', .wide = false }, .{ .code = '\n', .wide = false }, .{ .code = '\'', .wide = false }, .{ .code = 0xe9, .wide = true }, .{ .code = 0x1f600, .wide = true }, .{ .code = 0x61, .wide = false }, .{ .code = 0xff, .wide = false }, .{ .code = 0x1f600, .wide = true }, .{ .code = 0xe9, .wide = true } };
    for (values, result[0..values.len]) |want, token| try std.testing.expectEqualDeep(want, characterLiteral(token.span.text(source)).?);
    // A surrogate and a value past the last scalar lex as characters and name none.
    try std.testing.expectEqual(@as(?Character, null), characterLiteral("0uD800"));
    try std.testing.expectEqual(@as(?Character, null), characterLiteral("0u110000"));
    try std.testing.expect(characterLiteral("0uD7FF") != null and characterLiteral("0u10FFFF") != null);
    for ([_][]const u8{ "''", "'ab'", "'a", "'", "'\\x'", "'\\", "'\t'", "'\n'", "'\xc3\xa9x'", "X:='a\nb'" }) |bad| {
        try std.testing.expectEqual(Diagnostic.Code.invalid_char_literal, tokenize(bad, &tokens).failed.code);
    }
    // The diagnostic covers the quoted text when the quote closes on its line.
    try std.testing.expectEqualDeep(Span{ .start = 0, .end = 4 }, tokenize("'ab'", &tokens).failed.span);
    try std.testing.expectEqualDeep(Span{ .start = 0, .end = 1 }, tokenize("'a", &tokens).failed.span);
}

test "string tags distinguish ordinary and escaped literals across token reuse" {
    var tokens: [16]Token = undefined;
    const result = tokenize("\"\" \"雪🌲\" \"\\n\" \"x\\\\y\" \"\\\"\" # ignore \\\nName", &tokens).ok;
    const expected = [_]bool{ false, false, true, true, true };
    for (result[0..expected.len], expected) |token, escaped| {
        try std.testing.expectEqual(if (escaped) Token.Kind.escaped_string else .string, token.kind);
    }
    for (result[expected.len..]) |token| try std.testing.expect(token.kind != .escaped_string);
    const reused = tokenize("\"plain\"", &tokens).ok;
    try std.testing.expectEqual(Token.Kind.string, reused[0].kind);
    try std.testing.expectEqual(Token.Kind.eof, reused[1].kind);
}

test "EOF reservation and exact identifier boundary remain ordinary input outcomes" {
    var tokens: [2]Token = undefined;
    try std.testing.expectEqual(Diagnostic.Code.token_limit, tokenize("", tokens[0..0]).failed.code);
    const empty = tokenize(" # comment", tokens[0..1]).ok;
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqual(Token.Kind.eof, empty[0].kind);
    try std.testing.expectEqual(@as(u32, 10), empty[0].span.start);
    try std.testing.expectEqual(Diagnostic.Code.token_limit, tokenize("A", tokens[0..1]).failed.code);
    var name: [types.limits.identifier_bytes + 1]u8 = @splat('A');
    const accepted = tokenize(name[0..types.limits.identifier_bytes], &tokens).ok;
    try std.testing.expectEqual(@as(usize, 2), accepted.len);
    try std.testing.expectEqual(types.limits.identifier_bytes, accepted[0].span.end);
    try std.testing.expectEqual(Diagnostic.Code.identifier_limit, tokenize(&name, &tokens).failed.code);
}
