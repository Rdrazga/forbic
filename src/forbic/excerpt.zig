//! Source excerpts under a diagnostic (RFC-0088, D1): numbered source lines and a caret underline
//! beneath the `path:line:column: error: message` header, which the host prints itself and which
//! never changes. Pure and bounded: it reads the source it is given and writes into a fixed
//! buffer, so a diagnostic costs the same whatever the program is, and no input can make it
//! slice out of range.
//!
//! Offsets are half-open byte offsets into the source snapshot the compiler admitted (D1). A
//! line is what ends at LF; a CR before the LF is not shown. Tabs advance to the next multiple
//! of four cells, every Unicode scalar is one cell, and controls, invisible formatting scalars
//! and bytes that are not UTF-8 are shown as ASCII escapes, each escape taking as many cells as
//! it has characters, so the underline is measured on what is printed (D2). Terminal widths of
//! wide glyphs and combining marks are deliberately not modelled.
const std = @import("std");
const types = @import("types.zig");
const macros = @import("macros.zig");

/// How a host prints a diagnostic: `plain` is the header alone, `excerpt` adds the source.
pub const Style = enum {
    plain,
    excerpt,

    pub fn parse(text: []const u8) ?Style {
        return std.meta.stringToEnum(Style, text);
    }
};

/// RFC-0088, "Limits and fuel": provisional bounds that hold for every profile.
pub const limits = struct {
    /// Source lines shown for one location: a context line, the first and last affected lines,
    /// one line between them and a context line after.
    pub const lines_per_location = 6;
    /// Display cells of one line, the `...` markers of a clipped line included.
    pub const cells_per_line = 160;
    /// The primary location and one related declaration.
    pub const locations = 2;
    /// Bytes written under one header.
    pub const bytes = 8192;
    pub const tab_width = 4;
};

pub const unavailable = "source excerpt unavailable\n";
pub const clipped = "note: excerpt clipped to 8192 bytes\n";
pub const related_note = "note: first declared here\n";
const marker = "...";

comptime {
    std.debug.assert(limits.bytes == 8192 and std.mem.indexOf(u8, clipped, "8192") != null);
}

/// The part of `module_source` its author wrote. The compiler appends a library block of
/// generated templates to a module that uses a macro (`macros.writeLibrary`); a span inside it
/// is the template and not the user's text, so it is not shown as source (D4). The block is
/// recognised by its exact opening (`\n#`, the pool of `Fn` words, `\n#`, the first two
/// templates) and by ending the module with `#}`.
pub fn userExtent(module_source: []const u8) usize {
    const opening = comptime "\n#" ++ macros.text[0] ++ "\n#" ++ macros.text[1] ++ "\n";
    if (!std.mem.endsWith(u8, module_source, "#}")) return module_source.len;
    const found = std.mem.lastIndexOf(u8, module_source, opening) orelse return module_source.len;
    // The pool line before it: `\n#` and whole `Fn ` words.
    var pool = found;
    while (pool >= 3 and std.mem.eql(u8, module_source[pool - 3 .. pool], "Fn ")) pool -= 3;
    if (pool < 2 or module_source[pool - 2] != '\n' or module_source[pool - 1] != '#') return module_source.len;
    if ((found - pool) % (3 * macros.fn_words_per_call) != 0) return module_source.len;
    return pool - 2;
}

/// Writes the excerpt of `diagnostic` in `source`, the module source its span is relative to:
/// the primary location, then `note: first declared here` and the related one when the
/// diagnostic names it. Writes nothing but the excerpt; the header is the host's.
pub fn writeDiagnostic(out: *std.Io.Writer, source: []const u8, diagnostic: types.Diagnostic) std.Io.Writer.Error!void {
    var buffer: Buffer = .{};
    render(&buffer, source[0..userExtent(source)], diagnostic);
    try out.writeAll(buffer.written());
}

fn render(buffer: *Buffer, source: []const u8, diagnostic: types.Diagnostic) void {
    const related = diagnostic.related.start != diagnostic.related.end;
    var width: u32 = 3;
    if (related) width = @max(width, numberWidth(source, diagnostic.related));
    width = @max(width, numberWidth(source, diagnostic.span));
    buffer.writeLocation(source, diagnostic.span, width) catch return buffer.clip();
    if (!related) return;
    // A note that leaves no room for a single line is not started.
    const before = buffer.length;
    buffer.put(related_note) catch return buffer.clip();
    buffer.writeLocation(source, diagnostic.related, width) catch {
        if (buffer.length == before + related_note.len) buffer.length = before;
        return buffer.clip();
    };
}

/// Digits of the largest line number a location may show (the line after its last).
fn numberWidth(source: []const u8, span: types.Span) u32 {
    if (!available(source, span)) return 0;
    const place = Place.of(source, span);
    return digits(place.last_number + 1);
}

fn digits(value: u32) u32 {
    var width: u32 = 1;
    var rest = value;
    while (rest >= 10) : (rest /= 10) width += 1;
    return width;
}

/// A span that can be shown: in order and inside the source. The receiver word has no place in
/// the text, and an empty span at the end is the end of the file.
fn available(source: []const u8, span: types.Span) bool {
    return span.start <= span.end and span.end <= source.len;
}

const Line = struct {
    /// Offset of the first byte, and of the end of the shown text (before a CR that precedes the
    /// LF, and before the LF).
    start: usize,
    end: usize,
    /// Offset of the next line, null for the last one.
    after: ?usize,

    fn at(source: []const u8, start: usize) Line {
        std.debug.assert(start <= source.len);
        const lf = std.mem.indexOfScalarPos(u8, source, start, '\n');
        var end = lf orelse source.len;
        if (lf != null and end > start and source[end - 1] == '\r') end -= 1;
        return .{ .start = start, .end = end, .after = if (lf) |index| index + 1 else null };
    }

    /// The line holding the byte at `offset`; a LF belongs to the line it ends.
    fn holding(source: []const u8, offset: usize) Line {
        std.debug.assert(offset <= source.len);
        const start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |index| index + 1 else 0;
        return .at(source, start);
    }
};

/// The lines a span touches: from the one holding its first byte to the one holding its last
/// (D3), so a span that ends where the next line starts does not touch that line.
const Place = struct {
    first: Line,
    last: Line,
    first_number: u32,
    last_number: u32,

    fn of(source: []const u8, span: types.Span) Place {
        std.debug.assert(available(source, span));
        const first: Line = .holding(source, span.start);
        const last: Line = if (span.end > span.start) .holding(source, span.end - 1) else first;
        const before = std.mem.count(u8, source[0..first.start], "\n");
        const between = std.mem.count(u8, source[first.start..last.start], "\n");
        return .{ .first = first, .last = last, .first_number = @intCast(before + 1), .last_number = @intCast(before + 1 + between) };
    }
};

/// One printed piece of a line: a scalar as it is, a tab as its spaces, or an escape.
const Unit = struct {
    bytes: u3,
    cells: u32,
    kind: enum { literal, tab, byte_escape, scalar_escape },
    /// The byte or scalar an escape spells.
    value: u21 = 0,

    fn at(content: []const u8, offset: usize, column: u32) Unit {
        const first = content[offset];
        if (first == '\t') return .{ .bytes = 1, .cells = limits.tab_width - column % limits.tab_width, .kind = .tab };
        if (first < 0x20 or first == 0x7f) return byteEscape(first);
        if (first < 0x80) return .{ .bytes = 1, .cells = 1, .kind = .literal };
        const length = std.unicode.utf8ByteSequenceLength(first) catch return byteEscape(first);
        if (offset + length > content.len) return byteEscape(first);
        const scalar = std.unicode.utf8Decode(content[offset..][0..length]) catch return byteEscape(first);
        if (hidden(scalar)) {
            var spelling: [Escape.capacity]u8 = undefined;
            return .{ .bytes = length, .cells = @intCast(Escape.scalar(&spelling, scalar).len), .kind = .scalar_escape, .value = scalar };
        }
        return .{ .bytes = length, .cells = 1, .kind = .literal };
    }

    fn byteEscape(byte: u8) Unit {
        var spelling: [Escape.capacity]u8 = undefined;
        return .{ .bytes = 1, .cells = @intCast(Escape.byte(&spelling, byte).len), .kind = .byte_escape, .value = byte };
    }
};

const Escape = struct {
    /// `\u{10FFFF}`.
    const capacity = 10;

    fn byte(into: *[capacity]u8, value: u8) []const u8 {
        if (value == '\r') return "\\r";
        return std.fmt.bufPrint(into, "\\x{X:0>2}", .{value}) catch unreachable;
    }

    fn scalar(into: *[capacity]u8, value: u21) []const u8 {
        return std.fmt.bufPrint(into, "\\u{{{X}}}", .{value}) catch unreachable;
    }
};

/// Scalars that print as nothing or move the text around them: C1 controls, soft hyphen,
/// zero-width and directional marks and overrides, line and paragraph separators, byte order
/// mark, interlinear annotation marks, the fillers that draw as blanks, the variation selectors
/// and tag characters, and the noncharacters at the end of the first plane. A reader of the
/// excerpt must see them, not be misled by them.
fn hidden(scalar: u21) bool {
    return switch (scalar) {
        0x80...0x9f, 0xad, 0x34f, 0x61c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b...0x180f, 0x200b...0x200f, 0x2028...0x202e, 0x2060...0x206f, 0x3164, 0xfe00...0xfe0f, 0xfeff, 0xffa0, 0xfff9...0xfffb, 0xfffe, 0xffff, 0xe0000...0xe0fff => true,
        else => false,
    };
}

/// A walk over the units of one line's text.
const Walker = struct {
    content: []const u8,
    offset: usize = 0,
    column: u32 = 0,

    const Step = struct { unit: Unit, offset: usize, column: u32 };

    fn next(self: *Walker) ?Step {
        if (self.offset >= self.content.len) return null;
        const step: Step = .{ .unit = .at(self.content, self.offset, self.column), .offset = self.offset, .column = self.column };
        self.offset += step.unit.bytes;
        self.column += step.unit.cells;
        return step;
    }
};

/// The cells of a line that are printed. A line of up to `cells_per_line` cells is printed whole;
/// a longer one is cut at unit boundaries to a window that holds the underlined start, with `...`
/// where it is cut.
const Window = struct {
    low: u32,
    high: u32,
    left: bool,
    right: bool,

    /// Cells of context kept before the start of a mark when the line is cut on the left.
    const context = 40;

    fn of(content: []const u8, total: u32, start_column: u32) Window {
        if (total <= limits.cells_per_line) return .{ .low = 0, .high = total, .left = false, .right = false };
        var low: u32 = 0;
        if (start_column > limits.cells_per_line - 2 * context - marker.len) {
            // The first unit that begins at or after the wanted cell.
            low = total;
            var walker: Walker = .{ .content = content };
            while (walker.next()) |step| if (step.column >= start_column - context) {
                low = step.column;
                break;
            };
        }
        const left_cells: u32 = if (low > 0) marker.len else 0;
        const room = limits.cells_per_line - left_cells;
        if (total - low <= room) return .{ .low = low, .high = total, .left = low > 0, .right = false };
        // The last unit that ends before the right marker.
        const limit = low + room - marker.len;
        var high = low;
        var walker: Walker = .{ .content = content };
        while (walker.next()) |step| {
            if (step.column < low) continue;
            if (step.column + step.unit.cells > limit) break;
            high = step.column + step.unit.cells;
        }
        return .{ .low = low, .high = high, .left = low > 0, .right = true };
    }
};

/// Output of at most `limits.bytes`, of which the end is held back for the `clipped` line.
const Buffer = struct {
    bytes: [limits.bytes]u8 = undefined,
    length: usize = 0,
    limit: usize = limits.bytes - clipped.len,

    const Full = error{Full};

    fn written(self: *const Buffer) []const u8 {
        return self.bytes[0..self.length];
    }

    fn put(self: *Buffer, text: []const u8) Full!void {
        if (text.len > self.limit - self.length) return error.Full;
        @memcpy(self.bytes[self.length..][0..text.len], text);
        self.length += text.len;
    }

    fn repeat(self: *Buffer, byte: u8, count: usize) Full!void {
        if (count > self.limit - self.length) return error.Full;
        @memset(self.bytes[self.length..][0..count], byte);
        self.length += count;
    }

    /// The marker of output that did not fit: it has the room kept for it.
    fn clip(self: *Buffer) void {
        self.limit = limits.bytes;
        self.put(clipped) catch unreachable;
    }

    /// `LABEL |` with the label right-aligned in `width` cells: a line number, `...` for lines
    /// left out, or nothing for the line of a caret.
    fn gutter(self: *Buffer, width: u32, label: []const u8) Full!void {
        std.debug.assert(label.len <= width);
        try self.repeat(' ', width - label.len);
        try self.put(label);
        try self.put(" |");
    }

    fn numbered(self: *Buffer, width: u32, number: u32) Full!void {
        var text: [10]u8 = undefined;
        return self.gutter(width, std.fmt.bufPrint(&text, "{d}", .{number}) catch unreachable);
    }

    fn putUnit(self: *Buffer, content: []const u8, step: Walker.Step) Full!void {
        var spelling: [Escape.capacity]u8 = undefined;
        switch (step.unit.kind) {
            .literal => try self.put(content[step.offset..][0..step.unit.bytes]),
            .tab => try self.repeat(' ', step.unit.cells),
            .byte_escape => try self.put(Escape.byte(&spelling, @intCast(step.unit.value))),
            .scalar_escape => try self.put(Escape.scalar(&spelling, step.unit.value)),
        }
    }

    fn writeLocation(self: *Buffer, source: []const u8, span: types.Span, width: u32) Full!void {
        if (!available(source, span)) return self.put(unavailable);
        const place: Place = .of(source, span);
        if (place.last_number == place.first_number) return self.writeRow(source, place.first, place.first_number, width, span);
        // A span over several lines: a line of context, the first affected line, what lies
        // between (a single line as it is, more as `...`), the last one and a line of context
        // (D3). The empty line a final LF leaves is not context.
        var shown: u32 = 0;
        if (place.first.start > 0) {
            const before: Line = .holding(source, place.first.start - 1);
            try self.writeRow(source, before, place.first_number - 1, width, null);
            shown += 1;
        }
        try self.writeRow(source, place.first, place.first_number, width, span);
        shown += 1;
        const between = place.last_number - place.first_number - 1;
        if (between == 1) {
            const middle: Line = .at(source, place.first.after.?);
            try self.writeRow(source, middle, place.first_number + 1, width, null);
            shown += 1;
        } else if (between > 1) {
            const saved = self.length;
            errdefer self.length = saved;
            try self.gutter(width, marker);
            try self.put("\n");
        }
        try self.writeRow(source, place.last, place.last_number, width, span);
        shown += 1;
        if (place.last.after) |after| if (after < source.len) {
            try self.writeRow(source, .at(source, after), place.last_number + 1, width, null);
            shown += 1;
        };
        std.debug.assert(shown <= limits.lines_per_location);
    }

    /// One source line, and under it the part of `mark` that falls on it. The row is written
    /// whole or not at all.
    fn writeRow(self: *Buffer, source: []const u8, line: Line, number: u32, width: u32, mark: ?types.Span) Full!void {
        const saved = self.length;
        errdefer self.length = saved;
        const content = source[line.start..line.end];
        // The mark within the line, as offsets into its text: a part of the mark outside the line
        // (or on its CR and LF) is clamped to the line.
        var from: usize = 0;
        var to: usize = 0;
        if (mark) |span| {
            from = std.math.clamp(@as(usize, span.start), line.start, line.end) - line.start;
            to = std.math.clamp(@as(usize, span.end), line.start + from, line.end) - line.start;
        }
        // Pass one: the cells of the line, and where the mark starts and ends in them. A mark that
        // starts at the end of the line starts after its last cell.
        var total: u32 = 0;
        var start_column: ?u32 = null;
        var end_column: u32 = 0;
        var walker: Walker = .{ .content = content };
        while (walker.next()) |step| {
            const next = step.offset + step.unit.bytes;
            if (start_column == null and from >= step.offset and from < next) start_column = step.column;
            if (to > from and to - 1 >= step.offset and to - 1 < next) end_column = step.column + step.unit.cells;
            total = step.column + step.unit.cells;
        }
        const first_column = start_column orelse total;
        if (to <= from) end_column = first_column + 1;
        const window: Window = .of(content, total, first_column);
        std.debug.assert(window.low <= first_column);

        try self.numbered(width, number);
        if (content.len != 0) try self.put(" ");
        if (window.left) try self.put(marker);
        walker = .{ .content = content };
        while (walker.next()) |step| {
            if (step.column < window.low) continue;
            if (step.column + step.unit.cells > window.high) break;
            try self.putUnit(content, step);
        }
        if (window.right) try self.put(marker);
        try self.put("\n");
        if (mark == null) return;

        // The underline: a caret at the start and a tilde under the rest, as far as the text is
        // printed. A mark that is empty, or only a line end, is one caret.
        const left_cells: u32 = if (window.left) marker.len else 0;
        const right_cells: u32 = if (window.right) marker.len else 0;
        try self.gutter(width, "");
        try self.put(" ");
        try self.repeat(' ', left_cells + first_column - window.low);
        try self.put("^");
        const stop = @min(end_column, window.high + right_cells);
        if (stop > first_column + 1) try self.repeat('~', stop - first_column - 1);
        try self.put("\n");
    }
};

/// `count` copies of `byte`, for the long lines and underlines of expected output.
fn times(comptime byte: u8, comptime count: usize) *const [count]u8 {
    const repeated: [count]u8 = @splat(byte);
    return &repeated;
}

fn expectExcerpt(expected: []const u8, source: []const u8, span: types.Span) !void {
    try expectDiagnostic(expected, source, .{ .span = span, .code = .unknown_name });
}

fn expectDiagnostic(expected: []const u8, source: []const u8, diagnostic: types.Diagnostic) !void {
    var storage: [limits.bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writeDiagnostic(&writer, source, diagnostic);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "the style option names plain and excerpt and nothing else" {
    try std.testing.expectEqual(Style.plain, Style.parse("plain").?);
    try std.testing.expectEqual(Style.excerpt, Style.parse("excerpt").?);
    for ([_][]const u8{ "", "Plain", "EXCERPT", "excerpt ", "full", "none", "plain,excerpt" }) |text| try std.testing.expect(Style.parse(text) == null);
}

test "a span is underlined with a caret and tildes under a numbered line" {
    try expectExcerpt(
        \\  3 | Name := Value
        \\    |         ^~~~~
        \\
    , "a\nb\nName := Value\n", .{ .start = 12, .end = 17 });
    // One byte is one caret; the numbers are right-aligned in the widest the location needs.
    try expectExcerpt("  1 | x\n    | ^\n", "x\n", .{ .start = 0, .end = 1 });
    var long: [2100]u8 = undefined;
    for (0..long.len / 2) |index| {
        long[2 * index] = 'y';
        long[2 * index + 1] = '\n';
    }
    try expectExcerpt(
        \\549 | y
        \\    | ^
        \\
    , &long, .{ .start = 2 * 548, .end = 2 * 548 + 1 });
    try expectExcerpt(
        \\ 999 | y
        \\     | ^
        \\
    , &long, .{ .start = 2 * 998, .end = 2 * 998 + 1 });
}

test "tabs advance to the next stop of four cells and the underline follows them" {
    // `\tab\tc`: the tab is four cells, `a` and `b` follow, the second tab is two cells.
    const source = "\tab\tc\n";
    try expectExcerpt("  1 |     ab  c\n    |      ^\n", source, .{ .start = 2, .end = 3 });
    try expectExcerpt("  1 |     ab  c\n    |       ^~\n", source, .{ .start = 3, .end = 4 });
    try expectExcerpt("  1 |     ab  c\n    | ^~~~\n", source, .{ .start = 0, .end = 1 });
    try expectExcerpt("  1 |     ab  c\n    | ^~~~~~~~~\n", source, .{ .start = 0, .end = 5 });
}

test "every scalar is one cell, whatever its bytes, and a mark inside a scalar covers the scalar" {
    const source = "é=→😀x\n";
    // bytes: é 0..2, = 2, → 3..6, 😀 6..10, x 10.
    try expectExcerpt("  1 | é=→😀x\n    |     ^\n", source, .{ .start = 10, .end = 11 });
    try expectExcerpt("  1 | é=→😀x\n    |    ^\n", source, .{ .start = 6, .end = 10 });
    try expectExcerpt("  1 | é=→😀x\n    | ^~\n", source, .{ .start = 1, .end = 3 });
    try expectExcerpt("  1 | é=→😀x\n    |  ^~~\n", source, .{ .start = 2, .end = 9 });
}

test "controls, invisible formatting and bytes that are not UTF-8 are shown as ASCII escapes" {
    try expectExcerpt("  1 | a\\x01b\\x7Fc\n    |           ^\n", "a\x01b\x7fc\n", .{ .start = 4, .end = 5 });
    // A CR that does not end the line is a control like another.
    try expectExcerpt("  1 | a\\rb\n    |  ^~\n", "a\rb\n", .{ .start = 1, .end = 2 });
    // NUL, ESC and DEL.
    try expectExcerpt("  1 | \\x00\\x1B\\x7F\n    | ^~~~~~~~~~~~\n", "\x00\x1b\x7f\n", .{ .start = 0, .end = 3 });
    // A scalar the terminal would not show, or would use to reorder the text around it.
    try expectExcerpt("  1 | a\\u{202E}b\n    |          ^\n", "a\u{202e}b\n", .{ .start = 4, .end = 5 });
    try expectExcerpt("  1 | \\u{85}\\u{FEFF}\\u{200B}x\n    |                       ^\n", "\u{85}\u{feff}\u{200b}x\n", .{ .start = 8, .end = 9 });
    // Tag characters, variation selectors and fillers draw as nothing too: `x` follows 9 cells.
    try expectExcerpt("  1 | \\u{E0041}x\n    |          ^\n", "\u{e0041}x\n", .{ .start = 4, .end = 5 });
    try expectExcerpt("  1 | \\u{3164}\\u{FE0F}\\u{34F}x\n    |                        ^\n", "\u{3164}\u{fe0f}\u{34f}x\n", .{ .start = 8, .end = 9 });
    // A truncated sequence, a lone continuation byte, a surrogate and an overlong form: one
    // escape for each byte.
    try expectExcerpt("  1 | a\\xFFb\\xC3\n    |       ^~~~\n", "a\xffb\xc3", .{ .start = 3, .end = 4 });
    try expectExcerpt("  1 | \\x80\\xED\\xA0\\x80\n    | ^" ++ times('~', 15) ++ "\n", "\x80\xed\xa0\x80", .{ .start = 0, .end = 4 });
    try expectExcerpt("  1 | \\xC0\\x80\n    | ^" ++ times('~', 7) ++ "\n", "\xc0\x80\n", .{ .start = 0, .end = 2 });
    // Four-byte forms past the last scalar, and a valid sequence cut by the end of the line.
    try expectExcerpt("  1 | \\xF8\\x88\\x80\\x80\\x80\n    | ^" ++ times('~', 19) ++ "\n", "\xf8\x88\x80\x80\x80\n", .{ .start = 0, .end = 5 });
    try expectExcerpt("  1 | \\xE2\\x82\n    | ^~~~\n", "\xe2\x82\nx\n", .{ .start = 0, .end = 1 });
}

test "a CR before the LF is not shown, and a mark on the line end is one caret after the text" {
    const source = "ab\r\ncd\r\n";
    try expectExcerpt("  2 | cd\n    | ^~\n", source, .{ .start = 4, .end = 6 });
    // The span ends where the next line starts, so that line is not underlined.
    try expectExcerpt("  1 | ab\n    | ^~\n", source, .{ .start = 0, .end = 4 });
    // The CR, the LF, and both.
    try expectExcerpt("  1 | ab\n    |   ^\n", source, .{ .start = 2, .end = 3 });
    try expectExcerpt("  1 | ab\n    |   ^\n", source, .{ .start = 3, .end = 4 });
    try expectExcerpt("  1 | ab\n    |   ^\n", source, .{ .start = 2, .end = 4 });
}

test "a span over several lines shows its first and last lines with a line of context each" {
    const source = "l1\nl2\nl3\nl4\nl5\nl6\nl7\n";
    // l2 to l5: the two lines between are omitted.
    try expectExcerpt(
        \\  1 | l1
        \\  2 | l2
        \\    |  ^
        \\... |
        \\  5 | l5
        \\    | ^~
        \\  6 | l6
        \\
    , source, .{ .start = 4, .end = 14 });
    // l2 to l4: the one line between is shown as it is.
    try expectExcerpt(
        \\  1 | l1
        \\  2 | l2
        \\    | ^~
        \\  3 | l3
        \\  4 | l4
        \\    | ^~
        \\  5 | l5
        \\
    , source, .{ .start = 3, .end = 11 });
    // l1 to l2: nothing before, and the line after.
    try expectExcerpt(
        \\  1 | l1
        \\    | ^~
        \\  2 | l2
        \\    | ^~
        \\  3 | l3
        \\
    , source, .{ .start = 0, .end = 6 });
    // The last line of the text has no line after it, and the empty line a final LF leaves
    // is not one.
    try expectExcerpt(
        \\  5 | l5
        \\  6 | l6
        \\    | ^~
        \\  7 | l7
        \\    | ^~
        \\
    , source, .{ .start = 15, .end = 21 });
    // A span that ends where the next line starts does not touch that line.
    try expectExcerpt("  2 | l2\n    | ^~\n", source, .{ .start = 3, .end = 6 });
}

test "an empty span, the end of the file and an empty file get one caret" {
    try expectExcerpt("  1 | abc\n    |    ^\n", "abc", .{ .start = 3, .end = 3 });
    try expectExcerpt("  1 | abc\n    |   ^\n", "abc", .{ .start = 2, .end = 2 });
    // After a final LF the caret is on the empty line that follows it.
    try expectExcerpt("  2 |\n    | ^\n", "abc\n", .{ .start = 4, .end = 4 });
    try expectExcerpt("  1 |\n    | ^\n", "", .{ .start = 0, .end = 0 });
    try expectExcerpt("  1 | abc\n    |    ^\n", "abc\n", .{ .start = 3, .end = 3 });
}

test "a span that cannot be shown gives a line saying so" {
    for ([_]types.Span{
        .{ .start = 5, .end = 4 },
        .{ .start = 0, .end = 5 },
        .{ .start = 4, .end = 4 },
        .{ .start = 3, .end = 9 },
        .{ .start = std.math.maxInt(u32), .end = std.math.maxInt(u32) },
        types.Span.self_word,
    }) |span| try expectExcerpt(unavailable, "abc", span);
    // Related declarations are told apart: each location has its own verdict.
    const source = "A:i64=1\nA:i64=2\n";
    try expectDiagnostic("  2 | A:i64=2\n    | ^\nnote: first declared here\nsource excerpt unavailable\n", source, .{ .span = .{ .start = 8, .end = 9 }, .code = .duplicate_name, .related = .{ .start = 90, .end = 91 } });
    try expectDiagnostic("source excerpt unavailable\nnote: first declared here\n  1 | A:i64=1\n    | ^\n", source, .{ .span = .{ .start = 99, .end = 100 }, .code = .duplicate_name, .related = .{ .start = 0, .end = 1 } });
}

test "a related declaration is a note with its own excerpt" {
    const source = "A:i64=1\nA:i64=2\n";
    try expectDiagnostic(
        \\  2 | A:i64=2
        \\    | ^
        \\note: first declared here
        \\  1 | A:i64=1
        \\    | ^
        \\
    , source, .{ .span = .{ .start = 8, .end = 9 }, .code = .duplicate_name, .related = .{ .start = 0, .end = 1 } });
    // An empty related span names nothing.
    try expectDiagnostic("  2 | A:i64=2\n    | ^\n", source, .{ .span = .{ .start = 8, .end = 9 }, .code = .duplicate_name });
}

/// The cells before `needle` in `text`: every character of the rendered text is one cell.
fn cellsBefore(text: []const u8, needle: u8) !usize {
    const at = std.mem.indexOfScalar(u8, text, needle) orelse return error.TestUnexpectedResult;
    return try std.unicode.utf8CountCodepoints(text[0..at]);
}

test "a long line is cut at unit boundaries to 160 cells around the mark and says where it was cut" {
    var line: [300]u8 = @splat('a');
    try expectExcerpt("  1 | " ++ times('a', 157) ++ "...\n    | ^\n", &line, .{ .start = 0, .end = 1 });
    // The start is past the first screen: 40 cells of context are kept before it.
    try expectExcerpt("  1 | ..." ++ times('a', 140) ++ "\n    | " ++ times(' ', 43) ++ "^\n", &line, .{ .start = 200, .end = 201 });
    // A mark that runs past the cut is underlined as far as the text is printed, marker included.
    try expectExcerpt("  1 | " ++ times('a', 157) ++ "...\n    | ^" ++ times('~', 159) ++ "\n", &line, .{ .start = 0, .end = 300 });
    // The end of a long line.
    try expectExcerpt("  1 | ..." ++ times('a', 40) ++ "\n    | " ++ times(' ', 43) ++ "^\n", &line, .{ .start = 300, .end = 300 });
    // Cut on both sides.
    var longer: [600]u8 = @splat('a');
    try expectExcerpt("  1 | ..." ++ times('a', 154) ++ "...\n    | " ++ times(' ', 43) ++ "^\n", &longer, .{ .start = 200, .end = 201 });
}

test "a mark stays under its character however the line is cut" {
    var random: std.Random.DefaultPrng = .init(0x5eed);
    const pieces = [_][]const u8{ "a", "b", "é", "😀", "\t", "\x01", "\xff", "\u{202e}", "→", "ab" };
    var source: [4096]u8 = undefined;
    for (0..400) |_| {
        // A line of random pieces with one `X`, and a span that is the `X`.
        var length: usize = 0;
        const count = random.random().intRangeAtMost(usize, 0, 300);
        const x = random.random().intRangeAtMost(usize, 0, count);
        var mark: usize = 0;
        for (0..count + 1) |index| {
            if (index == x) {
                mark = length;
                source[length] = 'X';
                length += 1;
            }
            if (index == count) break;
            const piece = pieces[random.random().uintLessThan(usize, pieces.len)];
            @memcpy(source[length..][0..piece.len], piece);
            length += piece.len;
        }
        source[length] = '\n';
        var storage: [limits.bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try writeDiagnostic(&writer, source[0 .. length + 1], .{ .span = .{ .start = @intCast(mark), .end = @intCast(mark + 1) }, .code = .unknown_name });
        const output = writer.buffered();
        try std.testing.expect(std.unicode.utf8ValidateSlice(output));
        const split = std.mem.indexOfScalar(u8, output, '\n').?;
        const row = output[0..split];
        const underline = output[split + 1 .. output.len - 1];
        try std.testing.expect(std.mem.startsWith(u8, row, "  1 |"));
        try std.testing.expect(std.mem.startsWith(u8, underline, "    |"));
        // No more than 160 cells of text after the gutter.
        try std.testing.expect(try std.unicode.utf8CountCodepoints(row[5..]) <= 1 + limits.cells_per_line);
        // The caret is under the `X`.
        try std.testing.expectEqual(try cellsBefore(row, 'X'), try cellsBefore(underline, '^'));
    }
}

test "a cut never splits an escape or a scalar" {
    var source: [3 * 400]u8 = undefined;
    for (0..400) |index| @memcpy(source[3 * index ..][0..3], "→");
    var escapes: [4 * 200]u8 = undefined;
    for (0..200) |index| @memcpy(escapes[4 * index ..][0..4], "\x01\x02\xff\x7f");
    for ([_][]const u8{ source[0..1200], escapes[0..800] }) |text| {
        var start: u32 = 0;
        while (start <= text.len) : (start += 7) {
            var storage: [limits.bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&storage);
            try writeDiagnostic(&writer, text, .{ .span = .{ .start = start, .end = start }, .code = .unknown_name });
            const output = writer.buffered();
            try std.testing.expect(std.unicode.utf8ValidateSlice(output));
            const row = output[0..std.mem.indexOfScalar(u8, output, '\n').?];
            // Whole escapes only: once the complete ones (`\x` and two hex digits) are taken out,
            // what is left is the gutter, the markers and the scalars of the line, never a piece
            // of an escape or a part of a scalar.
            var at: usize = 0;
            while (at < row.len) {
                if (row[at] == '\\') {
                    try std.testing.expect(at + 4 <= row.len);
                    try std.testing.expect(row[at + 1] == 'x' and std.ascii.isHex(row[at + 2]) and std.ascii.isHex(row[at + 3]));
                    at += 4;
                } else if (std.mem.startsWith(u8, row[at..], "→")) {
                    at += "→".len;
                } else {
                    try std.testing.expect(std.mem.indexOfScalar(u8, " |1.", row[at]) != null);
                    at += 1;
                }
            }
        }
    }
}

test "a location shows at most six lines, and output past the byte limit is clipped and marked" {
    // Context, first, between, last and context lines at most: five rows with a number.
    var buffer: Buffer = .{};
    const source = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
    for ([_]struct { span: types.Span, rows: usize }{ .{ .span = .{ .start = 4, .end = 9 }, .rows = 5 }, .{ .span = .{ .start = 4, .end = 15 }, .rows = 4 } }) |case| {
        buffer = .{};
        render(&buffer, source, .{ .span = case.span, .code = .unknown_name });
        var rows: usize = 0;
        var split = std.mem.splitScalar(u8, buffer.written(), '\n');
        while (split.next()) |row| {
            const trimmed = std.mem.trimStart(u8, row, " ");
            if (trimmed.len != 0 and std.ascii.isDigit(trimmed[0])) rows += 1;
        }
        try std.testing.expectEqual(case.rows, rows);
        try std.testing.expect(rows <= limits.lines_per_location);
    }

    // Room for the first location and not for the whole second one: the note is not started.
    const duplicate = "A:i64=1\nA:i64=2\n";
    const diagnostic: types.Diagnostic = .{ .span = .{ .start = 8, .end = 9 }, .code = .duplicate_name, .related = .{ .start = 0, .end = 1 } };
    buffer = .{ .limit = 69 };
    render(&buffer, duplicate, diagnostic);
    try std.testing.expectEqualStrings("  2 | A:i64=2\n    | ^\n" ++ clipped, buffer.written());
    // Room for the note and the line but not its underline: the row is not half written.
    buffer = .{ .limit = 61 };
    render(&buffer, duplicate, diagnostic);
    try std.testing.expectEqualStrings("  2 | A:i64=2\n    | ^\n" ++ clipped, buffer.written());
    buffer = .{ .limit = 70 };
    render(&buffer, duplicate, diagnostic);
    try std.testing.expectEqualStrings("  2 | A:i64=2\n    | ^\nnote: first declared here\n  1 | A:i64=1\n    | ^\n", buffer.written());
    // Not even the first row.
    buffer = .{ .limit = 20 };
    render(&buffer, duplicate, diagnostic);
    try std.testing.expectEqualStrings(clipped, buffer.written());
    // The `...` row is whole or not there: room for its gutter and not for its line end.
    buffer = .{ .limit = 32 };
    render(&buffer, "l1\nl2\nl3\nl4\nl5\nl6\nl7\n", .{ .span = .{ .start = 4, .end = 14 }, .code = .unknown_name });
    try std.testing.expectEqualStrings("  1 | l1\n  2 | l2\n    |  ^\n" ++ clipped, buffer.written());
    // Part of a multi-line location.
    buffer = .{ .limit = 40 };
    render(&buffer, "l1\nl2\nl3\n", .{ .span = .{ .start = 0, .end = 8 }, .code = .unknown_name });
    try std.testing.expectEqualStrings("  1 | l1\n    | ^~\n  2 | l2\n" ++ clipped, buffer.written());
}

test "no span of any source can make the renderer fail, and its output stays bounded and valid UTF-8" {
    var random: std.Random.DefaultPrng = .init(0xd1a9);
    const alphabet = [_][]const u8{ "a", " ", "\n", "\r\n", "\r", "\t", "é", "\xc3", "\xff", "😀", "\x00", "\u{2028}", times('x', 40) };
    var source: [1024]u8 = undefined;
    for (0..3000) |_| {
        var length: usize = 0;
        while (length < 900) {
            const piece = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            if (random.random().uintLessThan(u8, 8) == 0) break;
            @memcpy(source[length..][0..piece.len], piece);
            length += piece.len;
        }
        const text = source[0..length];
        const bound: u32 = @intCast(length + 3);
        const span: types.Span = .{ .start = random.random().uintAtMost(u32, bound), .end = random.random().uintAtMost(u32, bound) };
        const related: types.Span = .{ .start = random.random().uintAtMost(u32, bound), .end = random.random().uintAtMost(u32, bound) };
        var storage: [limits.bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try writeDiagnostic(&writer, text, .{ .span = span, .code = .unknown_name, .related = related });
        try std.testing.expect(writer.buffered().len <= limits.bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(writer.buffered()));
        try std.testing.expect(writer.buffered().len > 0);
    }
}

test "a library block of generated templates is not the user's text" {
    const user = "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,X)\n";
    var storage: [user.len + macros.libraryLength(1, .{})]u8 = undefined;
    @memcpy(storage[0..user.len], user);
    macros.writeLibrary(storage[user.len..], 1, .{});
    try std.testing.expectEqual(user.len, userExtent(&storage));
    // Without a macro there is no block, and a source that merely ends in `#}` is whole.
    try std.testing.expectEqual(user.len, userExtent(user));
    try std.testing.expectEqual(@as(usize, 7), userExtent("a\n#}\n#}"));
    // The end of the user's text is a place; the templates are not.
    try expectDiagnostic("  3 |\n    | ^\n", &storage, .{ .span = .{ .start = user.len, .end = user.len }, .code = .unknown_name });
    try expectDiagnostic(unavailable, &storage, .{ .span = .{ .start = user.len + 10, .end = user.len + 20 }, .code = .unknown_name });
    try expectDiagnostic(unavailable, &storage, .{ .span = .{ .start = 4, .end = user.len + 3 }, .code = .unknown_name });
    try expectDiagnostic("  1 | Xs:[]i64=array{1,2}\n    | ^~\n", &storage, .{ .span = .{ .start = 0, .end = 2 }, .code = .unknown_name });
    // A pool of several calls.
    var many: [user.len + macros.libraryLength(4, .{ .loops = true, .cases = true })]u8 = undefined;
    @memcpy(many[0..user.len], user);
    macros.writeLibrary(many[user.len..], 4, .{ .loops = true, .cases = true });
    try std.testing.expectEqual(user.len, userExtent(&many));
}
