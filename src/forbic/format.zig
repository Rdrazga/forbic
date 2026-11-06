//! `forbic fmt` (TASK-0109, W4.5): the canonical layout of Forbic source. The conventions are in
//! docs/formatting.md.
//!
//! The formatter reads the tokens the compiler's own lexer makes, so it accepts exactly what the
//! compiler can lex and never sees a different program. The lexer ignores spaces, tabs, carriage
//! returns and comments; a newline is a token. The formatter changes only those ignored bytes and
//! the number of newlines in a run (at most one blank line is kept, and none at either end of the
//! file); comments are kept, and string literals with their interpolations are copied byte for
//! byte. Before it returns, it lexes what it wrote and compares the tokens with the source's
//! (`sameTokens`) and the comments with the source's (`sameComments`), so a defect of the
//! formatter is refused instead of changing a program or losing a comment.
const std = @import("std");
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const Token = lexer.Token;
const Diagnostic = types.Diagnostic;

/// Spaces per level of bracket nesting.
pub const indent_width = 4;

/// Everything one formatting needs, sized from the profile: the formatted text is a source too,
/// so it gets the room a source may have. Create with `scratch.storage` and `scratch.initialise`.
pub const Storage = struct {
    /// The source's tokens.
    tokens: [types.limits.tokens]Token = undefined,
    /// The formatted text's tokens, which must be the source's.
    check: [types.limits.tokens]Token = undefined,
    /// For each open bracket, the indentation of the lines inside it.
    open: [types.limits.tokens]u32 = undefined,
    output: [types.limits.source_bytes]u8 = undefined,

    pub fn format(self: *Storage, source: []const u8) Result {
        return formatInto(source, .{ .tokens = &self.tokens, .check = &self.check, .open = &self.open, .output = &self.output });
    }
};

pub const Failure = union(enum) {
    /// The compiler's lexer refuses the source (an oversize source is `source_limit`).
    lexical: Diagnostic,
    /// The formatted text would be larger than a source may be.
    output_limit,
    /// The formatted text does not lex to the source's tokens, or changes whether two tokens the
    /// compiler reads together touch (`touchMatters`): a defect of the formatter, found before
    /// anything was written. The offset is in the source: the first token that differs.
    tokens_changed: u32,
    /// A carriage return between two tokens that does not end a line, at this offset. The lexer
    /// takes it for a blank, but a module header (`modules.moduleHeader`) does not, so dropping
    /// it could change a program: such a file is left for its author. One in a comment, or at
    /// the end of the file, is not refused.
    stray_carriage_return: u32,
    /// A comment of the formatted text differs from the source's, other than in the blanks that
    /// the layout rules change (`sameComments`): a comment lost, joined, split or altered, or a
    /// block comment turned into an indented comment (RFC-0089: `<#>` is measured by its own
    /// indentation, so a layout that misplaced one would change what it covers). A defect of
    /// the formatter, found before anything was written. The offset is in the source: the first
    /// comment that differs.
    comment_changed: u32,
};
pub const Result = union(enum) { ok: []const u8, failed: Failure };

pub const Buffers = struct {
    tokens: []Token,
    check: []Token,
    open: []u32,
    output: []u8,
};

/// Formats `source` into `buffers.output`. Buffers smaller than the profile's are for tests.
pub fn formatInto(source: []const u8, buffers: Buffers) Result {
    const tokens = switch (lexer.tokenize(source, buffers.tokens)) {
        .ok => |tokens| tokens,
        .failed => |diagnostic| return .{ .failed = .{ .lexical = diagnostic } },
    };
    if (strayCarriageReturn(source, tokens)) |offset| return .{ .failed = .{ .stray_carriage_return = offset } };
    std.debug.assert(tokens.len > 0 and tokens[tokens.len - 1].kind == .eof);
    var out: Output = .{ .bytes = buffers.output };
    var layout: Layout = .{ .source = source, .tokens = tokens, .open = buffers.open };
    layout.run(&out);
    if (out.overflow) return .{ .failed = .output_limit };
    const text = out.bytes[0..out.len];
    // Room was checked against the profile's source limit only through `buffers.output`.
    if (text.len > types.limits.source_bytes) return .{ .failed = .output_limit };
    const written = switch (lexer.tokenize(text, buffers.check)) {
        .ok => |written| written,
        // Its offset is in the formatted text, which no caller shows: name the start instead.
        .failed => return .{ .failed = .{ .tokens_changed = 0 } },
    };
    return verified(source, tokens, text, written);
}

/// `text` as the result when it keeps the source's tokens and comments, else the refusal.
fn verified(source: []const u8, tokens: []const Token, text: []const u8, written: []const Token) Result {
    if (sameTokens(source, tokens, text, written)) |offset| return .{ .failed = .{ .tokens_changed = offset } };
    if (sameComments(source, tokens, text, written)) |offset| return .{ .failed = .{ .comment_changed = offset } };
    return .{ .ok = text };
}

/// A comment found between tokens. A line comment `#` runs to the newline; a block comment
/// `<# ... #>` nests and may span lines; an indented comment `<#>` stands first on its line, and
/// the lines below it that are indented four columns past it belong to it (RFC-0089).
const Item = struct {
    start: u32,
    end: u32,
    kind: Kind,

    const Kind = enum { line, block, indented };

    fn text(self: Item, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// The comments in the gap `source[at..to]` between two tokens, in order. The lexer ignores the
/// rest of a gap (spaces, tabs and carriage returns), and drops one colon.
const Gap = struct {
    source: []const u8,
    at: u32,
    to: u32,

    fn next(self: *Gap) ?Item {
        while (self.at < self.to) {
            const byte = self.source[self.at];
            // The colon of `Name:type := v` is not a token (`lexer.dropTypedInitializerColons`),
            // so it lies in the gap before the `=`.
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == ':') {
                self.at += 1;
                continue;
            }
            // The lexer accepted the source, so what else is here opens a comment that ends
            // within the gap.
            std.debug.assert(lexer.commentOpens(self.source, self.at));
            const start = self.at;
            const end: u32 = @intCast(lexer.commentEnd(self.source, start));
            std.debug.assert(end <= self.to and end > start);
            self.at = end;
            const kind: Item.Kind = if (self.source[start] == '#') .line else if (start + 2 < self.source.len and self.source[start + 2] == '>') .indented else .block;
            return .{ .start = start, .end = end, .kind = kind };
        }
        return null;
    }
};

/// The first carriage return between tokens, outside comments, that a newline does not follow.
/// Tokens of an interpolation share bytes, so a gap starts after the furthest end yet seen.
fn strayCarriageReturn(source: []const u8, tokens: []const Token) ?u32 {
    var end: u32 = 0;
    for (tokens) |token| {
        if (token.span.start > end) {
            var at = end;
            while (at < token.span.start) {
                if (lexer.commentOpens(source, at)) {
                    // A comment's text may hold carriage returns.
                    at = @intCast(lexer.commentEnd(source, at));
                    continue;
                }
                if (source[at] == '\r' and at + 1 < source.len and source[at + 1] != '\n') return at;
                at += 1;
            }
        }
        end = @max(end, token.span.end);
    }
    return null;
}

/// How a comment that spans lines moves: its first line goes from indentation `from` to `to`, in
/// columns, a space being one and a tab four, as the lexer counts them for an indented comment
/// (`lexer.indented_comment_columns`).
const Shift = struct {
    from: usize,
    to: usize,

    /// The columns of a later line that had `columns_before`: it stays as far from the first line.
    fn move(self: Shift, columns_before: usize) usize {
        return (columns_before + self.to) -| self.from;
    }
};

/// The columns of a run of spaces and tabs.
fn columns(blanks: []const u8) usize {
    var count: usize = 0;
    for (blanks) |byte| count += switch (byte) {
        ' ' => 1,
        '\t' => lexer.indented_comment_columns,
        else => 0,
    };
    return count;
}

/// `text` without the blanks and carriage returns that end it.
fn trimBlanks(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;
    return text[0..end];
}

const Output = struct {
    bytes: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn write(self: *Output, text: []const u8) void {
        if (self.overflow) return;
        if (text.len > self.bytes.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..text.len], text);
        self.len += text.len;
    }

    /// Writes `text` without the carriage returns that end a line (those directly before a line
    /// feed, `strayCarriageReturn`). One that ends no line is in a comment, whose text stays.
    fn lines(self: *Output, text: []const u8) void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |found| {
            self.write(std.mem.trimEnd(u8, rest[0..found], "\r"));
            self.write("\n");
            rest = rest[found + 1 ..];
        }
        self.write(rest);
    }

    /// Writes a block comment's text. Each carriage return that ends a line is dropped (as in
    /// `lines`), and the rest is kept byte for byte. With a `shift` that moves the comment's first
    /// line, its other lines move with it: their leading blanks become as many spaces as their
    /// columns plus the shift (not fewer than none), and a line of blanks becomes empty.
    fn block(self: *Output, text: []const u8, shift: ?Shift) void {
        const moved = if (shift) |found| found.from != found.to else false;
        var rest = text;
        var first = true;
        while (true) {
            const end = std.mem.indexOfScalar(u8, rest, '\n');
            var piece = rest[0 .. end orelse rest.len];
            if (end != null) while (piece.len > 0 and piece[piece.len - 1] == '\r') {
                piece = piece[0 .. piece.len - 1];
            };
            if (first or !moved) {
                self.write(piece);
            } else {
                const blanks = std.mem.indexOfNone(u8, piece, " \t") orelse piece.len;
                if (blanks < piece.len) {
                    self.spaces(shift.?.move(columns(piece[0..blanks])));
                    self.write(piece[blanks..]);
                }
            }
            first = false;
            if (end == null) return;
            self.write("\n");
            rest = rest[end.? + 1 ..];
        }
    }

    /// Writes an indented comment `<#>`: its lines without the blanks that end them, each body
    /// line at the same number of columns past the marker as before (the marker moves as
    /// `shift` says), and a line of blanks empty.
    fn indented(self: *Output, text: []const u8, shift: Shift) void {
        var rest = text;
        var first = true;
        while (true) {
            const end = std.mem.indexOfScalar(u8, rest, '\n');
            const piece = trimBlanks(rest[0 .. end orelse rest.len]);
            if (first) {
                self.write(piece);
            } else if (piece.len > 0) {
                const blanks = std.mem.indexOfNone(u8, piece, " \t") orelse piece.len;
                self.spaces(shift.move(columns(piece[0..blanks])));
                self.write(piece[blanks..]);
            }
            first = false;
            if (end == null) return;
            self.write("\n");
            rest = rest[end.? + 1 ..];
        }
    }

    fn spaces(self: *Output, count: usize) void {
        if (self.overflow) return;
        if (count > self.bytes.len - self.len) {
            self.overflow = true;
            return;
        }
        @memset(self.bytes[self.len..][0..count], ' ');
        self.len += count;
    }
};

/// How a unit is spaced from its neighbours.
const Class = enum {
    word,
    /// `(` and `[`, and their closers: nothing inside.
    open,
    close,
    /// `{` and `}`: spaced inside as written (`Block{ X }` and `array{1}` are both common).
    open_brace,
    close_brace,
    comma,
    separator,
    dot,
    colon,
    /// One space on each side: `:=`, `=`, `=>`, comparisons that are not `<` or `>`, compound
    /// assignments, `*` and `/`.
    spaced,
    /// `+` and `-`: spaced when binary, attached to their operand when unary.
    sign,
    /// Everything else (`<`, `>`, `?`) is spaced as written: `<` and `>` both compare and
    /// bracket specifiers (`<transacts>`), which tokens alone do not tell apart.
    other,
};

/// What the formatter places: one token, `:=` or a compound assignment (two tokens written
/// together), or a whole string literal with its interpolations.
const Unit = struct {
    start: u32,
    end: u32,
    class: Class,
    /// For a sign: whether it is binary.
    binary: bool = false,
    /// The token after the unit.
    next: usize,
    /// Whether the unit is a string literal, which is copied as written.
    string: bool = false,
    /// The kinds of its first and last tokens, and of the token after its first, which decide
    /// whether its edges may move.
    first: Token.Kind,
    last: Token.Kind,
    second: Token.Kind,

    fn text(self: Unit, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

const Layout = struct {
    source: []const u8,
    tokens: []const Token,
    open: []u32,
    depth: usize = 0,

    fn run(self: *Layout, out: *Output) void {
        var at: usize = 0;
        // Where the last token consumed ends: comments lie between it and the next newline.
        var last_end: u32 = 0;
        var started = false;
        var blank = false;
        while (true) {
            // The units of one line, from `at` to its newline or the end of the file.
            var end = at;
            var count: usize = 0;
            while (!terminates(self.tokens[end].kind)) : (count += 1) end = self.unit(end, null).next;
            const terminator = self.tokens[end];
            var gap: Gap = .{ .source = self.source, .at = last_end, .to = terminator.span.start };
            if (count == 0 and gap.next() == null) {
                // An empty line: kept as one blank line between lines that are not empty.
                blank = started;
            } else {
                if (blank) out.write("\n");
                blank = false;
                started = true;
                self.line(out, at, end, count, last_end, terminator.span.start);
                out.write("\n");
            }
            if (terminator.kind == .eof) break;
            last_end = terminator.span.end;
            at = end + 1;
        }
        std.debug.assert(at < self.tokens.len);
    }

    /// One line: the units `from` to `to` (`count` of them), with the comments around and between
    /// them. `line_start` is where the bytes of the line begin (after the previous newline) and
    /// `limit` where its newline is. A line of comments only is `commentLine`.
    fn line(self: *Layout, out: *Output, from: usize, to: usize, count: usize, line_start: u32, limit: u32) void {
        // Closers that begin the line put it at the indentation of the line their brackets
        // opened on.
        var indent: u32 = if (self.depth == 0) 0 else self.open[self.depth - 1];
        var leading: usize = 0;
        var at = from;
        while (at < to) {
            const first = self.unit(at, null);
            if (first.class != .close and first.class != .close_brace) break;
            if (self.depth > 0) {
                self.depth -= 1;
                indent = self.open[self.depth] - 1;
            } else indent = 0;
            leading += 1;
            at = first.next;
        }
        out.spaces(@as(usize, indent) * indent_width);
        if (count == 0) return self.commentLine(out, line_start, limit, indent);
        // Block comments before the first unit, each followed by one space.
        var lead: Gap = .{ .source = self.source, .at = line_start, .to = self.unit(from, null).start };
        while (lead.next()) |item| {
            std.debug.assert(item.kind == .block);
            out.block(item.text(self.source), null);
            out.write(" ");
        }
        var previous: ?Unit = null;
        var index: usize = 0;
        at = from;
        while (at < to) : (index += 1) {
            const current = self.unit(at, previous);
            if (previous) |before| {
                // A block comment between two units has one space on each side.
                var between: Gap = .{ .source = self.source, .at = before.end, .to = current.start };
                var any = false;
                while (between.next()) |item| {
                    std.debug.assert(item.kind == .block);
                    out.write(" ");
                    out.block(item.text(self.source), null);
                    any = true;
                }
                if (any or self.spaced(before, current)) out.write(" ");
            }
            // A string's interpolation can hold line ends, which are written as the others are.
            if (current.string) out.lines(current.text(self.source)) else out.write(current.text(self.source));
            switch (current.class) {
                .open, .open_brace => {
                    // A bracket is a token, and there are fewer of them than tokens.
                    std.debug.assert(self.depth < self.open.len);
                    self.open[self.depth] = indent + 1;
                    self.depth += 1;
                },
                .close, .close_brace => if (index >= leading and self.depth > 0) {
                    self.depth -= 1;
                },
                else => {},
            }
            previous = current;
            at = current.next;
        }
        std.debug.assert(index == count);
        // Comments at the end of the line: the first keeps the blanks written before it (so
        // aligned comments stay aligned when the code before them does not change width), with
        // at least one space; the others have one space between them.
        const line_end = self.tokens[to - 1].span.end;
        var trailing: Gap = .{ .source = self.source, .at = line_end, .to = limit };
        var first_comment = true;
        while (trailing.next()) |item| {
            std.debug.assert(item.kind != .indented);
            if (first_comment) {
                var written: usize = 0;
                for (self.source[line_end..item.start]) |byte| if (byte != '\r') {
                    out.write(&.{byte});
                    written += 1;
                };
                if (written == 0) out.write(" ");
                first_comment = false;
            } else out.write(" ");
            self.place(out, item, null);
        }
    }

    /// A line that holds comments and no unit, whose first comment begins at indentation
    /// `indent`. It is moved as a unit: a comment that spans lines (a block comment, or the body
    /// of an indented comment) keeps the layout of its lines relative to its first one.
    fn commentLine(self: *Layout, out: *Output, line_start: u32, limit: u32, indent: u32) void {
        var gap: Gap = .{ .source = self.source, .at = line_start, .to = limit };
        const first = gap.next().?;
        const shift: Shift = .{ .from = columns(self.source[line_start..first.start]), .to = @as(usize, indent) * indent_width };
        self.place(out, first, shift);
        while (gap.next()) |item| {
            // An indented comment stands first on its line, so nothing follows it or precedes it.
            std.debug.assert(first.kind != .indented and item.kind != .indented);
            out.write(" ");
            self.place(out, item, shift);
        }
    }

    fn place(self: *Layout, out: *Output, item: Item, shift: ?Shift) void {
        const text = item.text(self.source);
        switch (item.kind) {
            .line => out.write(trimBlanks(text)),
            .block => out.block(text, shift),
            .indented => out.indented(text, shift.?),
        }
    }

    /// Whether a space goes between two units on one line.
    fn spaced(self: *const Layout, before: Unit, after: Unit) bool {
        const written = before.end != after.start;
        // Whether these two touch is part of what they mean.
        if (touchMatters(before.last, after.first, after.second)) return written;
        const wanted = rule(before, after, written);
        // Never join two units that would lex as something else (`1 .5`, `0 o61`).
        if (!wanted and written and !self.joinable(before, after)) return true;
        return wanted;
    }

    fn joinable(self: *const Layout, before: Unit, after: Unit) bool {
        // A string literal begins and ends with a quote, which ends any token next to it.
        if (before.string or after.string) return true;
        const left = before.text(self.source);
        const right = after.text(self.source);
        var bytes: [2 * types.limits.identifier_bytes + 2]u8 = undefined;
        if (left.len + right.len > bytes.len) return false;
        @memcpy(bytes[0..left.len], left);
        @memcpy(bytes[left.len..][0..right.len], right);
        var apart: [4]Token = undefined;
        var together: [6]Token = undefined;
        const first = switch (lexer.tokenize(left, &apart)) {
            .ok => |tokens| tokens.len - 1,
            .failed => return false,
        };
        const kinds = [_]Token.Kind{ apart[0].kind, if (first > 1) apart[1].kind else .eof };
        const second = switch (lexer.tokenize(right, &apart)) {
            .ok => |tokens| tokens,
            .failed => return false,
        };
        const joined = switch (lexer.tokenize(bytes[0 .. left.len + right.len], &together)) {
            .ok => |tokens| tokens,
            .failed => return false,
        };
        if (joined.len != first + second.len) return false;
        for (joined[0..first], kinds[0..first]) |token, kind| if (token.kind != kind) return false;
        for (joined[first..], second) |token, kind| if (token.kind != kind.kind) return false;
        return joined[first].span.start == left.len;
    }

    /// The unit that begins at token `at`. `previous` decides whether a sign is binary.
    fn unit(self: *const Layout, at: usize, previous: ?Unit) Unit {
        const token = self.tokens[at];
        const start = token.span.start;
        if (token.kind == .left_paren and self.source[start] == '"') {
            // A string with interpolations: the lexer wrote it as a parenthesised sum whose
            // outer parentheses stand on its quotes. It ends at the paren on its closing quote.
            var depth: usize = 0;
            var index = at;
            while (true) : (index += 1) {
                const inner = self.tokens[index];
                std.debug.assert(inner.kind != .eof);
                const quote = self.source[inner.span.start] == '"';
                if (inner.kind == .left_paren and quote) depth += 1;
                if (inner.kind == .right_paren and quote) {
                    depth -= 1;
                    if (depth == 0) return .{ .start = start, .end = inner.span.end, .class = .word, .next = index + 1, .string = true, .first = .left_paren, .last = .right_paren, .second = .string };
                }
            }
        }
        const following = if (at + 1 < self.tokens.len) self.tokens[at + 1] else token;
        const touching = following.span.start == token.span.end;
        // Pairs the compiler reads as one operator only when they touch, written together.
        if (touching and following.kind == .equal) switch (token.kind) {
            .colon, .plus, .minus, .star, .slash => return .{ .start = start, .end = following.span.end, .class = .spaced, .next = at + 2, .first = token.kind, .last = .equal, .second = .equal },
            else => {},
        };
        if (touching and token.kind == .minus and following.kind == .greater) {
            // `K->V` of a map generator, spaced as written.
            return .{ .start = start, .end = following.span.end, .class = .other, .next = at + 2, .first = .minus, .last = .greater, .second = .greater };
        }
        const class: Class = switch (token.kind) {
            .identifier, .integer, .floating, .character, .string, .escaped_string => .word,
            .left_paren, .left_bracket => .open,
            .right_paren, .right_bracket => .close,
            .left_brace => .open_brace,
            .right_brace => .close_brace,
            .comma => .comma,
            .separator => .separator,
            .dot => .dot,
            .colon => .colon,
            .equal, .arrow, .equal_equal, .not_equal, .less_equal, .greater_equal, .star, .slash => .spaced,
            .plus, .minus => .sign,
            else => .other,
        };
        const binary = class == .sign and if (previous) |before| operand(self.source, before) else false;
        return .{ .start = start, .end = token.span.end, .class = class, .binary = binary, .next = at + 1, .string = token.kind == .string or token.kind == .escaped_string, .first = token.kind, .last = token.kind, .second = following.kind };
    }
};

/// Whether a unit ends an operand, so that a sign after it is binary.
fn operand(source: []const u8, before: Unit) bool {
    if (before.class == .close or before.class == .close_brace) return true;
    if (before.class != .word) return false;
    if (before.string) return true;
    const text = before.text(source);
    // A sign after these words is the sign of their operand.
    for ([_][]const u8{ "and", "or", "not", "Return" }) |word| if (std.mem.eql(u8, text, word)) return false;
    return true;
}

fn rule(before: Unit, after: Unit, written: bool) bool {
    if (after.class == .comma or after.class == .separator) return false;
    if (before.class == .comma or before.class == .separator) return if (after.class == .close or after.class == .close_brace) written else true;
    if (before.class == .dot or after.class == .dot) return false;
    if (before.class == .open or after.class == .close) return false;
    if (before.class == .spaced or after.class == .spaced) return true;
    if (after.class == .sign and after.binary) return true;
    if (before.class == .sign) return before.binary;
    if (before.class == .colon or after.class == .colon) return false;
    return written;
}

/// Whether the compiler reads two neighbouring tokens, `before` and `after` (which `next`
/// follows), differently when they touch: `:=` (`Workspace.bindingAhead` and others), `+=` and the
/// other compound assignments (`compoundAt`), `->` of a map generator, `..` of a range, the
/// name and colon of a qualifier `(Word:)` (`qualifierAt`), and a name directly before the `(`,
/// `[` or `<` of a nested function's header (`nestedHeaderAt`). The formatter keeps these as
/// written, and `sameTokens` checks it.
pub fn touchMatters(before: Token.Kind, after: Token.Kind, next: Token.Kind) bool {
    return switch (before) {
        .colon => after == .equal or after == .right_paren,
        .plus, .star, .slash => after == .equal,
        .minus => after == .equal or after == .greater,
        .dot => after == .dot,
        .identifier => (after == .colon and next == .right_paren) or after == .left_paren or after == .left_bracket or after == .less,
        else => false,
    };
}

fn terminates(kind: Token.Kind) bool {
    return kind == .newline or kind == .eof;
}

/// Null when the two token streams are the same program text: the same tokens with the same
/// spelling, where a run of newlines counts as one and newlines at either end do not count.
/// Otherwise the source offset of the first difference.
pub fn sameTokens(source: []const u8, tokens: []const Token, text: []const u8, written: []const Token) ?u32 {
    var left: Stream = .{ .tokens = tokens };
    var right: Stream = .{ .tokens = written };
    var previous: ?[2]Token = null;
    while (true) {
        const a = left.next();
        const b = right.next();
        if (a.kind != b.kind) return a.span.start;
        if (a.kind == .eof) return null;
        if (a.kind != .newline and !std.mem.eql(u8, a.span.text(source), b.span.text(text))) return a.span.start;
        if (previous) |pair| if (touchMatters(pair[0].kind, a.kind, left.peek().kind)) {
            if ((pair[0].span.end == a.span.start) != (pair[1].span.end == b.span.start)) return a.span.start;
        };
        previous = .{ a, b };
    }
}

/// Null when the comments of `text` (whose tokens are `written`) are those of `source` (whose tokens
/// are `tokens`): as many, of the same kinds, in the same order, with the same lines, where the
/// blanks (spaces, tabs and carriage returns) that begin or end a line do not count, which are
/// all the layout may change. Otherwise the source offset of the first comment that differs. A comment of a different kind would
/// change what it covers, and one lost or joined to another would change the text.
pub fn sameComments(source: []const u8, tokens: []const Token, text: []const u8, written: []const Token) ?u32 {
    var left: Comments = .{ .source = source, .tokens = tokens };
    var right: Comments = .{ .source = text, .tokens = written };
    while (true) {
        const a = left.next();
        const b = right.next();
        if (a == null and b == null) return null;
        const first = a orelse return @intCast(source.len);
        const second = b orelse return first.start;
        if (first.kind != second.kind) return first.start;
        if (!sameLines(first.text(source), second.text(text))) return first.start;
    }
}

fn sameLines(a: []const u8, b: []const u8) bool {
    var left = std.mem.splitScalar(u8, a, '\n');
    var right = std.mem.splitScalar(u8, b, '\n');
    while (true) {
        const x = left.next();
        const y = right.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, std.mem.trim(u8, x.?, " \t\r"), std.mem.trim(u8, y.?, " \t\r"))) return false;
    }
}

/// Every comment of a lexed source, in order: those in the gaps before its tokens. Tokens of an
/// interpolation share bytes, so a gap starts after the furthest end yet seen.
const Comments = struct {
    source: []const u8,
    tokens: []const Token,
    at: usize = 0,
    end: u32 = 0,
    gap: Gap = .{ .source = &.{}, .at = 0, .to = 0 },

    fn next(self: *Comments) ?Item {
        while (true) {
            if (self.gap.next()) |item| return item;
            if (self.at == self.tokens.len) return null;
            const token = self.tokens[self.at];
            self.at += 1;
            if (token.span.start > self.end) self.gap = .{ .source = self.source, .at = self.end, .to = token.span.start };
            self.end = @max(self.end, token.span.end);
        }
    }
};

const Stream = struct {
    tokens: []const Token,
    at: usize = 0,
    started: bool = false,

    fn peek(self: *const Stream) Token {
        var copy = self.*;
        return copy.next();
    }

    fn next(self: *Stream) Token {
        while (true) {
            const token = self.tokens[self.at];
            if (token.kind == .eof) return token;
            if (token.kind == .newline) {
                while (self.tokens[self.at].kind == .newline) self.at += 1;
                if (!self.started or self.tokens[self.at].kind == .eof) continue;
                return token;
            }
            self.at += 1;
            self.started = true;
            return token;
        }
    }
};

// Tests use buffers of their own size, so that they mean the same in every profile.
const Fixture = struct {
    tokens: [512]Token = undefined,
    check: [512]Token = undefined,
    open: [512]u32 = undefined,
    output: [4096]u8 = undefined,

    fn run(self: *Fixture, source: []const u8) Result {
        return formatInto(source, .{ .tokens = &self.tokens, .check = &self.check, .open = &self.open, .output = &self.output });
    }

    /// Formats `source`, expects `want`, and expects `want` to be its own format.
    fn expect(self: *Fixture, source: []const u8, want: []const u8) !void {
        const got = switch (self.run(source)) {
            .ok => |text| text,
            .failed => |failure| {
                std.debug.print("format failed: {any}\n", .{failure});
                return error.TestUnexpectedResult;
            },
        };
        try std.testing.expectEqualStrings(want, got);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..got.len], got);
        try std.testing.expectEqualStrings(want, self.run(copy[0..got.len]).ok);
    }
};

test "format: spacing around declarations, operators, commas and brackets" {
    var f: Fixture = .{};
    try f.expect("ApiVersion:i64=1\n", "ApiVersion:i64 = 1\n");
    try f.expect("X:=c{I:=2}\n", "X := c{I := 2}\n");
    try f.expect("X:i64 = F( 1 ,2 )\n", "X:i64 = F(1, 2)\n");
    try f.expect("V:i64=Block{set L[2]=L[0]+L[1];L[2]}\n", "V:i64 = Block{set L[2] = L[0] + L[1]; L[2]}\n");
    try f.expect("Y:=Block{ set X+=1; X*2-1 }\n", "Y := Block{ set X += 1; X * 2 - 1 }\n");
    // Signs: unary after an operator, an opener, a comma or `not`; binary after an operand.
    try f.expect("Z:=F(-1,- 2)-(-X)+not -Y\n", "Z := F(-1, -2) - (-X) + not -Y\n");
    try f.expect("M:=map{1=>2,3 =>4}\n", "M := map{1 => 2, 3 => 4}\n");
    try f.expect("If(A==B,C!=D,E<=F)\n", "If(A == B, C != D, E <= F)\n");
    // `<` and `>` keep the spacing they were written with: comparisons and specifiers.
    try f.expect("F<public>(X:i64)<transacts>:i64=If(X<3,X  >  2,1)\n", "F<public>(X:i64)<transacts>:i64 = If(X<3, X > 2, 1)\n");
    try f.expect("Items:[]string=array{}\nO:?i64=false\n", "Items:[]string = array{}\nO:?i64 = false\n");
    try f.expect("A:=X . Y.Z ( 1 )\n", "A := X.Y.Z (1)\n");
}

test "format: nothing is joined into a different token" {
    var f: Fixture = .{};
    // `1.5` would be a float and `0o61` a character: the space stays.
    try f.expect("A:=1 .5\n", "A := 1 .5\n");
    try f.expect("A:=0 o61\n", "A := 0 o61\n");
    // `: =` is two tokens however it is written; `= =` stays apart.
    try f.expect("A: =1\n", "A: = 1\n");
    try f.expect("A:= = 1\n", "A := = 1\n");
}

test "format: tokens the compiler reads together keep touching, or not, as written" {
    var f: Fixture = .{};
    // `->` of a map generator, and `- >` that is not one.
    try f.expect("M:=For(K->V:Items,K)\n", "M := For(K->V:Items, K)\n");
    try f.expect("M:=F(- >1)\n", "M := F(- >1)\n");
    // `..` of a range, and two dots apart.
    try f.expect("R:=For(I:1..9,I)\nS:=X. .Y\n", "R := For(I:1..9, I)\nS := X. .Y\n");
    // `+=` touching is a compound assignment; `+ =` is not.
    try f.expect("Block{set X+=1;set Y+ =2}\n", "Block{set X += 1; set Y + = 2}\n");
    // A qualifier `(Word:)Name`, and the same tokens apart.
    try f.expect("X:=(local:)Y+(local :)Z+(local: )W\n", "X := (local:)Y + (local :)Z + (local: )W\n");
    try f.expect("X : i64 = 1\n", "X:i64 = 1\n");
    // A name touching the `(`, `[` or `<` after it may start a nested function's header.
    try f.expect("F(X:i64):i64=G (X)+H[1]+K <public>\n", "F(X:i64):i64 = G (X) + H[1] + K <public>\n");
}

test "format: a carriage return that ends no line is refused" {
    var f: Fixture = .{};
    try std.testing.expectEqual(@as(u32, 4), f.run("A:=1\rB:=2\n").failed.stray_carriage_return);
    try std.testing.expectEqual(@as(u32, 7), f.run("S:=\"a{X\r+1}\"\n").failed.stray_carriage_return);
    // In a comment, or at the end of the file, it is harmless.
    try f.expect("A:=1 # a\rb\r\n", "A := 1 # a\rb\n");
    try f.expect("A:=1\r", "A := 1\n");
}

test "format: a block comment between tokens has one space on each side" {
    var f: Fixture = .{};
    try f.expect("A:=1 <# a #> + 2\n", "A := 1 <# a #> + 2\n");
    try f.expect("A:=1<#a#>+2\n", "A := 1 <#a#> + 2\n");
    try f.expect("F(<# a #>1,<# b #>2)\n", "F( <# a #> 1, <# b #> 2)\n");
    // Several in a row, nested ones, and one that stands between the tokens of a pair the
    // compiler reads together when they touch (the comment keeps them apart).
    try f.expect("A:=1 <# a #>   <# b #> + 2\n", "A := 1 <# a #> <# b #> + 2\n");
    try f.expect("A:=<# x <# y #> z #>1\n", "A := <# x <# y #> z #> 1\n");
    try f.expect("X:<#c#>=1\nY+<#c#>=1\n", "X: <#c#> = 1\nY + <#c#> = 1\n");
    // A sign after a comment is binary after an operand, and unary after an operator.
    try f.expect("A:=B<#c#>-1\nC:=-<#c#>1\n", "A := B <#c#> - 1\nC := - <#c#> 1\n");
    // The colon of `Name:type := v` is dropped by the lexer, so it is not a token to keep apart.
    try f.expect("X:i64<#c#>:=3\n", "X:i64 <#c#> = 3\n");
    // A comment inside an interpolation is part of the string and is copied with it.
    try f.expect("S:=\"a{ X <# c #>+1 }b\"\n", "S := \"a{ X <# c #>+1 }b\"\n");
    // A comment that spans lines inside a line keeps its lines as they are.
    try f.expect("A:=1 +<# spans\n   two lines #>  2\n", "A := 1 + <# spans\n   two lines #> 2\n");
    try f.expect("B:=Block{\nX <# a\n\n\tb #> + 1\n}\n", "B := Block{\n    X <# a\n\n\tb #> + 1\n}\n");
}

test "format: a block comment before or after the units of a line" {
    var f: Fixture = .{};
    try f.expect("  <# a #>A:=1\n", "<# a #> A := 1\n");
    try f.expect("B:=Block{\n<# a\n b #>X\n}\n", "B := Block{\n    <# a\n b #> X\n}\n");
    // The first comment after code keeps the blanks written before it; the others have one.
    try f.expect("A:=1   <# a #>\n", "A := 1   <# a #>\n");
    try f.expect("A:=1<# a #>\n", "A := 1 <# a #>\n");
    try f.expect("A:=1 \t<# a #>   <# b #>   # c   \n", "A := 1 \t<# a #> <# b #> # c\n");
    try f.expect("A:=1 <# a\n  b #>\nB:=2\n", "A := 1 <# a\n  b #>\nB := 2\n");
    // A line that begins with a closer goes back to the indentation of its opener.
    try f.expect("B:=Block{\nX\n<# c #>}\n", "B := Block{\n    X\n<# c #> }\n");
    try f.expect("B:=Block{X<# a #>}\n", "B := Block{X <# a #> }\n");
}

test "format: a block comment alone on its lines moves as a unit" {
    var f: Fixture = .{};
    try f.expect("A:=1\n  <# note #>\nB:=2\n", "A := 1\n<# note #>\nB := 2\n");
    // Down one level: its other lines move as far as the first.
    try f.expect("B:=Block{\n<# one\n  two #>\nX\n}\n", "B := Block{\n    <# one\n      two #>\n    X\n}\n");
    // Up: a line indented less than the shift gets no indentation, never a negative one.
    try f.expect(
        "B:=Block{\n        <# one\n          two\n  three #>\n    X\n}\n",
        "B := Block{\n    <# one\n      two\nthree #>\n    X\n}\n",
    );
    // Lines of blanks inside it become empty when it moves; the text between stays.
    try f.expect("B:=Block{\n<# one\n   \n\n  two #>\n}\n", "B := Block{\n    <# one\n\n\n      two #>\n}\n");
    // Where it already stands, it is left as written, tabs included.
    try f.expect("B:=Block{\n\t<# one\n\t\ttwo   #>\n}\n", "B := Block{\n    <# one\n\t\ttwo   #>\n}\n");
    // Several on a line, then a line comment: they move together.
    try f.expect("  <# a #>   <# b\n   c #>  # d  \nX\n", "<# a #> <# b\n c #> # d\nX\n");
    // At the start and the end of the file, with or without a newline there.
    try f.expect("<# head #>\nA:=1\n<# tail\n   more #>", "<# head #>\nA := 1\n<# tail\n   more #>\n");
    try f.expect("  <# only\n   more #>", "<# only\n more #>\n");
    // Inside nested blocks.
    try f.expect(
        "B:=Block{\nC:=Block{\n<# deep\n    deeper #>\nD\n}\n<# back #>\n}\n",
        "B := Block{\n    C := Block{\n        <# deep\n            deeper #>\n        D\n    }\n    <# back #>\n}\n",
    );
    // Nested block comments are one comment.
    try f.expect("  <# a <# b\n  c #> d\n  e #>\nX\n", "<# a <# b\nc #> d\ne #>\nX\n");
    // Blank lines around it follow the rules of blank lines.
    try f.expect("A:=1\n\n\n<# c #>\n\n\nB:=2\n", "A := 1\n\n<# c #>\n\nB := 2\n");
}

test "format: an indented comment keeps its lines relative to its marker" {
    var f: Fixture = .{};
    try f.expect("<#>\n    note\n      deeper\nA:=1\n", "<#>\n    note\n      deeper\nA := 1\n");
    // One level in: the marker and every line of its body move together.
    try f.expect(
        "B:=Block{\n<#>\n    note\n      deeper\n\n    more\nX\n}\n",
        "B := Block{\n    <#>\n        note\n          deeper\n\n        more\n    X\n}\n",
    );
    // Two levels in, with blanks that end its lines dropped.
    try f.expect(
        "B:=Block{\nC:=Block{\n<#>  text  \n    note   \nX\n}\n}\n",
        "B := Block{\n    C := Block{\n        <#>  text\n            note\n        X\n    }\n}\n",
    );
    // Out: from two levels to one.
    try f.expect("B:=Block{\n        <#>\n            note\n    X\n}\n", "B := Block{\n    <#>\n        note\n    X\n}\n");
    // A tab is four columns, for the marker's line and its body.
    try f.expect("B:=Block{\n\t<#>\n\t\tnote\n\t \tmore\n\tX\n}\n", "B := Block{\n    <#>\n        note\n         more\n    X\n}\n");
    // Blank lines inside it are part of it (and become empty); blank lines after it collapse.
    try f.expect("<#>\n    a\n   \n\n    b\nX\n", "<#>\n    a\n\n\n    b\nX\n");
    try f.expect("<#>\n    a\n\n\n\nX\n", "<#>\n    a\n\nX\n");
    // Alone, at the start and at the end of the file, after code, and before a line comment.
    try f.expect("<#>\n    x", "<#>\n    x\n");
    try f.expect("A:=1\n<#>\n    last", "A := 1\n<#>\n    last\n");
    try f.expect("<#>\nA:=1\n", "<#>\nA := 1\n");
    try f.expect("<#>\n    a\n# b\n", "<#>\n    a\n# b\n");
    // Code that looks like part of the body is part of it, and is not code.
    try f.expect("<#>\n    A:=1\nB:=2\n", "<#>\n    A:=1\nB := 2\n");
    // Beside a block comment on the line before and the line after.
    try f.expect("<# a #>\n  <#>\n      b\n  <# c #>\n", "<# a #>\n<#>\n    b\n<# c #>\n");
    // In a string's interpolation it is part of the string.
    try f.expect("S:=\"a{Block{\n<#>\n    x\n1}}\"\n", "S := \"a{Block{\n<#>\n    x\n1}}\"\n");
}

test "format: comments next to line comments and a <# in text" {
    var f: Fixture = .{};
    try f.expect("# a\n<# b #>\n# c\nX:=1 # d\n", "# a\n<# b #>\n# c\nX := 1 # d\n");
    try f.expect("<# a #> # b\n", "<# a #> # b\n");
    try f.expect("A:=1 # <#>\nB:=2 # <# open\n", "A := 1 # <#>\nB := 2 # <# open\n");
    try f.expect("S:=\"<#x#>\" <# y #>\n", "S := \"<#x#>\" <# y #>\n");
    try f.expect("A:=1 <# a # b #>\nB:=2\n", "A := 1 <# a # b #>\nB := 2\n");
}

test "format: carriage returns around comments" {
    var f: Fixture = .{};
    // Each carriage return that ends a line goes, in a block comment and an indented comment too.
    try f.expect(
        "A:=1 <# a\r\n  b #>\r\n<#>\r\n    note \r\n\r\n    more\r\nB:=2\r\n",
        "A := 1 <# a\n  b #>\n<#>\n    note\n\n    more\nB := 2\n",
    );
    // One in a comment that ends no line stays, in an interpolation too; one between tokens that
    // ends no line is refused. Those directly before a line end all go.
    try f.expect("A:=1 <# a\rb #> \n", "A := 1 <# a\rb #>\n");
    try f.expect("S:=\"a{ X <# c\rd #> }\"\n", "S := \"a{ X <# c\rd #> }\"\n");
    try f.expect("S:=\"a{ X # c\rd\n }\"\n", "S := \"a{ X # c\rd\n }\"\n");
    try f.expect("S:=\"a{Block{\n<#>\n    c\rd\n1}}\"\n", "S := \"a{Block{\n<#>\n    c\rd\n1}}\"\n");
    try f.expect("A:=1 <# a\r\r\n b #>\n# x\r\r\nB:=2\n", "A := 1 <# a\n b #>\n# x\nB := 2\n");
    try std.testing.expectEqual(@as(u32, 12), f.run("A:=1 <# a #>\rB:=2\n").failed.stray_carriage_return);
    try std.testing.expectEqual(@as(u32, 4), f.run("A:=1\r<# a #>\n").failed.stray_carriage_return);
}

test "format: comments are never lost, and formatting them again changes nothing" {
    var f: Fixture = .{};
    var copy: [4096]u8 = undefined;
    var a: [512]Token = undefined;
    var b: [512]Token = undefined;
    const sources = [_][]const u8{
        "<# a #>\n  <# b\n c #> X:=1 <#d#>\n\t<#>\n\t\t  e\n\tf\n",
        "B:=Block{\nC:=Block{\n   <# one\n     two\n\t three #>\n  <#>\n          deep\n\n      deeper\n   X <# in #> + <# two #> 1 <#\n#>  # end\n   }\n}\n",
        "A:=1\n\n\n  <#>\n         a\n\n\n         b\n\n\nB:=2 <# x\n\n\n y #>\n<#>\n    z",
        "F(\n<#>\n    a\nX,\n  <# b\n    c #>\nY <# d #>)\n",
        "S:=\"x{ <# a #> Y # b\n }\" <# c\n#>\n<# d #><# e #>\n",
        "<#><#>\n",
        "A:=<# a #><# b #>1<# c #>\n",
        "<# a #>",
        "<# a <# b #> c\n#>\n<#>\n    z\n",
    };
    for (sources) |source| {
        const first = switch (f.run(source)) {
            .ok => |text| text,
            .failed => return error.TestUnexpectedResult,
        };
        @memcpy(copy[0..first.len], first);
        const again = f.run(copy[0..first.len]).ok;
        try std.testing.expectEqualStrings(copy[0..first.len], again);
        const left = lexer.tokenize(source, &a).ok;
        const right = lexer.tokenize(copy[0..first.len], &b).ok;
        try std.testing.expectEqual(@as(?u32, null), sameComments(source, left, copy[0..first.len], right));
    }
}

test "format: random mixes of code and comments format to a fixed point, with every comment kept" {
    var f: Fixture = .{};
    var copy: [4096]u8 = undefined;
    var source: [768]u8 = undefined;
    const pieces = [_][]const u8{
        "A",       "X:=1",                "F(",                ")",                  "Block{",             "}",
        "{",       ",",                   ";",                 " ",                  "  ",                 "\t",
        "\n",      "\n",                  "\n\n",              "\n    b",            "\n        b",        "\r\n",
        "<# c #>", "<# m\n   l #>",       "<# n <# o #> p #>", "<#>",                "<#>\n    b",         "<#>\n\t\tb\n\n    c",
        "# line",  "# <# x",              "\"s{X}\"",          "\"t{ <#c#> Y\n }\"", "\"u{ # c\rd\n }\"",  "\"v{ <# c\rd #> }\"",
        "+",       "-",                   "<",                 ">",                  "=",                  ":",
        ":=",      "\n  <#>\n      deep", "<#\n#>",            "<# #>",              "\n\t<# t\n\t\tu #>", "\r",
        "..",      "1",
    };
    var random = std.Random.DefaultPrng.init(0x666f726d6174);
    var formatted: usize = 0;
    var commented: usize = 0;
    for (0..40_000) |_| {
        var length: usize = 0;
        for (0..random.random().intRangeAtMost(usize, 1, 14)) |_| {
            const piece = pieces[random.random().uintLessThan(usize, pieces.len)];
            if (length + piece.len > source.len) break;
            @memcpy(source[length..][0..piece.len], piece);
            length += piece.len;
        }
        const text = source[0..length];
        const first = switch (f.run(text)) {
            .ok => |ok| ok,
            // What the compiler's lexer refuses, a carriage return that ends no line, and a
            // result too large are refused; nothing else may be.
            .failed => |failure| switch (failure) {
                .lexical, .stray_carriage_return, .output_limit => continue,
                else => {
                    std.debug.print("random source {any} failed: {any}\n", .{ text, failure });
                    return error.TestUnexpectedResult;
                },
            },
        };
        formatted += 1;
        if (std.mem.indexOf(u8, text, "<#") != null) commented += 1;
        @memcpy(copy[0..first.len], first);
        const again = switch (f.run(copy[0..first.len])) {
            .ok => |ok| ok,
            .failed => |failure| {
                std.debug.print("random source {any} formats to text that is refused: {any}\n", .{ text, failure });
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, copy[0..first.len], again)) {
            std.debug.print("random source {any} is not a fixed point\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
    // Enough of the mixes lex for the test to mean something.
    try std.testing.expect(formatted > 4_000 and commented > 2_000);
}

test "format: the comment comparison sees every change but blanks" {
    var a: [64]Token = undefined;
    var b: [64]Token = undefined;
    const same = [_][2][]const u8{
        .{ "X <# a #> Y", "X\n<# a #>\nY" },
        .{ "<#>\n    a\n      b\n", "<#>\n        a\n          b" },
        .{ "<# a\n  b #>", "<# a\nb #>" },
        .{ "<# a  b #>", "<# a  b #>" },
        .{ "# a b", "# a b  " },
        .{ "", "" },
    };
    for (same) |pair| try std.testing.expectEqual(@as(?u32, null), sameComments(pair[0], lexer.tokenize(pair[0], &a).ok, pair[1], lexer.tokenize(pair[1], &b).ok));
    // A comment lost, added, altered, joined to another, split, or of another kind.
    const different = [_][2][]const u8{
        .{ "X <# a #>", "X" },
        .{ "X", "X <# a #>" },
        .{ "X <# a #>", "X <# b #>" },
        .{ "X <# a #> <# b #>", "X <# a #b #>" },
        .{ "X <# ab #>", "X <# a #> <# b #>" },
        .{ "<# a #>\n<# b #>", "<# a #>" },
        .{ "<# a b #>", "<#a#> b" },
        .{ "# a", "<# a #>" },
        .{ "<#>\n    a", "<# a #>" },
        .{ "<# a #>", "<#> a" },
        .{ "<# a b #>", "<# a  c #>" },
        // A blank inside a line, a line break, and a blank line are text.
        .{ "<# a b #>", "<# ab #>" },
        .{ "<# a  b #>", "<# a b #>" },
        .{ "<# a\n b #>", "<# a b #>" },
        .{ "<# a b #>", "<# a\n b #>" },
        .{ "<# a\n\n b #>", "<# a\n b #>" },
        .{ "<#>\n    a b", "<#>\n    ab" },
    };
    for (different) |pair| try std.testing.expect(sameComments(pair[0], lexer.tokenize(pair[0], &a).ok, pair[1], lexer.tokenize(pair[1], &b).ok) != null);
    // The offset is the source's first comment that differs.
    try std.testing.expectEqual(@as(?u32, 10), sameComments("X <# a #> <# b #>", lexer.tokenize("X <# a #> <# b #>", &a).ok, "X <# a #>", lexer.tokenize("X <# a #>", &b).ok).?);
}

test "format: a result that loses, alters or retypes a comment is refused, and one that changes a token" {
    var a: [64]Token = undefined;
    var b: [64]Token = undefined;
    const source = "X <# a #> # b\n<#>\n    c\n";
    const tokens = lexer.tokenize(source, &a).ok;
    try std.testing.expectEqualStrings(source, verified(source, tokens, source, lexer.tokenize(source, &b).ok).ok);
    // The offset is the source's first comment that differs: `<# a #>` at 2, `# b` at 10, the
    // indented comment at 14.
    const lost = "X # b\n<#>\n    c\n";
    try std.testing.expectEqual(@as(u32, 2), verified(source, tokens, lost, lexer.tokenize(lost, &b).ok).failed.comment_changed);
    const altered = "X <# a #> # b\n<#>\n    d\n";
    try std.testing.expectEqual(@as(u32, 14), verified(source, tokens, altered, lexer.tokenize(altered, &b).ok).failed.comment_changed);
    const retyped = "X <# a #> # b\n<# c #>\n";
    try std.testing.expectEqual(@as(u32, 14), verified(source, tokens, retyped, lexer.tokenize(retyped, &b).ok).failed.comment_changed);
    // A token that changed is found first.
    const token = "Y <# a #> # b\n<#>\n    c\n";
    try std.testing.expectEqual(@as(u32, 0), verified(source, tokens, token, lexer.tokenize(token, &b).ok).failed.tokens_changed);
}

test "format: comments the compiler's lexer refuses are refused" {
    var f: Fixture = .{};
    try std.testing.expectEqual(Diagnostic.Code.unterminated_comment, f.run("A:=1 <# open\n").failed.lexical.code);
    try std.testing.expectEqual(Diagnostic.Code.unterminated_comment, f.run("A:=1 <# a <# b #>\n").failed.lexical.code);
    try std.testing.expectEqual(Diagnostic.Code.misplaced_indented_comment, f.run("A:=1 <#>\n    note\n").failed.lexical.code);
    try std.testing.expectEqual(Diagnostic.Code.misplaced_indented_comment, f.run("<# a #> <#>\n").failed.lexical.code);
}

test "format: a <# inside a line comment or a string is text" {
    var f: Fixture = .{};
    try f.expect("A:=1 # see <# here\n", "A := 1 # see <# here\n");
    try f.expect("S:=\"<#x#>\"\n", "S := \"<#x#>\"\n");
}

test "format: indentation follows bracket nesting, one level per line that opens" {
    var f: Fixture = .{};
    try f.expect(
        "Main():i64=Block{\nX:=If(A,Block{\n  1\n      },Block{\n2\n})\n        X\n}\n",
        "Main():i64 = Block{\n    X := If(A, Block{\n        1\n    }, Block{\n        2\n    })\n    X\n}\n",
    );
    try f.expect(
        "c:=class{\n\tvar I:i64=1\n\tG():i64=Block{\nI\n}\n}\n",
        "c := class{\n    var I:i64 = 1\n    G():i64 = Block{\n        I\n    }\n}\n",
    );
    // Arguments on their own lines, and a closer after the last of them.
    try f.expect("X:=F(\n1,\n2)\nY:=F(\n1\n)\n", "X := F(\n    1,\n    2)\nY := F(\n    1\n)\n");
    // Unbalanced closers (the compiler refuses them) do not indent below the margin.
    try f.expect("}\n)\nX\n", "}\n)\nX\n");
}

test "format: comments stay on their lines and at line ends, indented with the code" {
    var f: Fixture = .{};
    try f.expect(
        "# head\nB:=Block{\n# inside\n  X   # kept gap\n        #   deeper\n}#end\n",
        "# head\nB := Block{\n    # inside\n    X   # kept gap\n    #   deeper\n} #end\n",
    );
    try f.expect("#only", "#only\n");
    try f.expect("X:=1 # trailing spaces   \n", "X := 1 # trailing spaces\n");
    // A `#` in a string is not a comment.
    try f.expect("S:=\"a#b\"  # c\n", "S := \"a#b\"  # c\n");
}

test "format: blank lines collapse to one and none at the ends" {
    var f: Fixture = .{};
    try f.expect("\n\n\nA:=1\n\n\n\nB:=2\n\n# c\n\n\n", "A := 1\n\nB := 2\n\n# c\n");
    try f.expect("A:=1\n   \n\t\nB:=2", "A := 1\n\nB := 2\n");
    try f.expect("", "");
    try f.expect("\n\n  \n", "");
}

test "format: strings and interpolations are copied byte for byte" {
    var f: Fixture = .{};
    try f.expect("S:=\"a{ X+1 }b{F( \"x{Y}\" )}c\"+\"d\"\n", "S := \"a{ X+1 }b{F( \"x{Y}\" )}c\" + \"d\"\n");
    try f.expect("S:=\"  \\{ not {X} \\n \"\n", "S := \"  \\{ not {X} \\n \"\n");
    // An interpolation may span lines; its lines are part of the string.
    try f.expect("S:=\"a{Block{\n  X # c\n     }}\"\nT:=1\n", "S := \"a{Block{\n  X # c\n     }}\"\nT := 1\n");
    try f.expect("C:=array{'a','\\n',0u1F600}\n", "C := array{'a', '\\n', 0u1F600}\n");
}

test "format: carriage returns are dropped and CRLF input formats as LF input" {
    var f: Fixture = .{};
    try f.expect("A:=1\r\n\r\n\r\n# c\r\nB:=Block{\r\n2 # d\r\n}\r\n", "A := 1\n\n# c\nB := Block{\n    2 # d\n}\n");
    // Line ends in an interpolation too.
    try f.expect("X:=1\r\nS:=\"a{\r\nX # c\r\n}b\"\r\nT:=2\r\n", "X := 1\nS := \"a{\nX # c\n}b\"\nT := 2\n");
}

test "format: oversize source, oversize result and lexical errors are refused" {
    var f: Fixture = .{};
    try std.testing.expectEqual(Diagnostic.Code.unterminated_string, f.run("S:=\"abc\n").failed.lexical.code);
    try std.testing.expectEqual(Diagnostic.Code.invalid_character, f.run("A:=1 ! 2\n").failed.lexical.code);
    try std.testing.expectEqual(Diagnostic.Code.token_limit, formatInto("A B C", .{ .tokens = f.tokens[0..3], .check = &f.check, .open = &f.open, .output = &f.output }).failed.lexical.code);
    // Indentation can make the result longer than the source.
    try std.testing.expect(formatInto("A{\nB{\nC\n}\n}\n", .{ .tokens = &f.tokens, .check = &f.check, .open = &f.open, .output = f.output[0..12] }).failed == .output_limit);
    const big = try std.testing.allocator.alloc(u8, types.limits.source_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, ' ');
    try std.testing.expectEqual(Diagnostic.Code.source_limit, f.run(big).failed.lexical.code);
}

test "format: the token comparison sees every change but newline runs and ends" {
    var a: [16]Token = undefined;
    var b: [16]Token = undefined;
    const same = [_][2][]const u8{ .{ "A := 1\nB", "\n\nA:=1\n\n\nB\n\n" }, .{ "", "\n" }, .{ "F(1,2)", "F( 1 , 2 )" } };
    for (same) |pair| try std.testing.expectEqual(@as(?u32, null), sameTokens(pair[0], lexer.tokenize(pair[0], &a).ok, pair[1], lexer.tokenize(pair[1], &b).ok));
    const different = [_][2][]const u8{ .{ "A B", "AB" }, .{ "A\nB", "A B" }, .{ "1 .5", "1.5" }, .{ "A", "A B" }, .{ "\"a\"", "\"b\"" }, .{ "A:=1", "A: =1" }, .{ "A: =1", "A:=1" }, .{ "K->V", "K- >V" }, .{ "X..Y", "X. .Y" }, .{ "set X+=1", "set X+ =1" }, .{ "F(X)", "F (X)" }, .{ "(a:)B", "(a :)B" } };
    for (different) |pair| try std.testing.expect(sameTokens(pair[0], lexer.tokenize(pair[0], &a).ok, pair[1], lexer.tokenize(pair[1], &b).ok) != null);
}
