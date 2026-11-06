//! `forbic fmt` over the repository's Forbic sources (TASK-0109, W4.5): formatting keeps each
//! program's meaning, and formatting formatted text changes nothing.
//!
//! Meaning is what the compiler makes of the text: a program that compiles has the same
//! `forbic inspect` report before and after, and one that does not is refused with the same
//! diagnostic. Positions move with the text: a report's source spans are compared as the number
//! of bytes other than blanks before them, which formatting keeps, and a diagnostic by its code
//! and the text it covers with the blanks taken out.
const std = @import("std");
const format = @import("format.zig");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const inspection = @import("inspection.zig");
const Workspace = @import("compiler.zig").Workspace;
const fixtures = @import("conformance_fixtures.zig");

/// Where the sources are, from the root of the tree the tests run in. A root that is not there
/// (`desktop/` is not in every copy of the tree) is skipped. The conformance fixtures are found
/// from the package root and from the root of a tree holding the package in `forbic/`
/// (`conformance_fixtures.zig`).
const roots = fixtures.roots ++ [_][]const u8{ "desktop", "apps/extension-host/fixtures" };

const report_bytes = 4 * 1024 * 1024;

const Corpus = struct {
    formatter: *format.Storage,
    workspace: *Workspace,
    inspector: *inspection.Workspace,
    source: []u8,
    first: []u8,
    reports: [2][]u8,
    normal: [2][]u8,
    files: usize = 0,
    refused: usize = 0,
    /// Files with a block or indented comment that were formatted.
    commented: usize = 0,
    failing: usize = 0,

    const Outcome = union(enum) { report: []const u8, failed: types.Diagnostic };

    fn check(self: *Corpus, name: []const u8, source: []const u8) !void {
        self.files += 1;
        const formatted = switch (self.formatter.format(source)) {
            .ok => |text| text,
            .failed => |failure| switch (failure) {
                // What the formatter cannot lex, the compiler cannot either.
                .lexical => |diagnostic| {
                    self.refused += 1;
                    const outcome = try self.compile(source, 0);
                    if (outcome != .failed or outcome.failed.code != diagnostic.code) return fail(name, "lexical refusal differs from the compiler's");
                    return;
                },
                else => return fail(name, @tagName(failure)),
            },
        };
        // Block and indented comments (RFC-0089) are laid out like the rest.
        if (std.mem.indexOf(u8, source, "<#") != null) self.commented += 1;
        @memcpy(self.first[0..formatted.len], formatted);
        const first = self.first[0..formatted.len];
        switch (self.formatter.format(first)) {
            .ok => |again| if (!std.mem.eql(u8, again, first)) return fail(name, "not idempotent"),
            .failed => return fail(name, "formatted text is refused"),
        }
        const before = try self.compile(source, 0);
        const after = try self.compile(first, 1);
        if (before == .failed) self.failing += 1;
        if (std.meta.activeTag(before) != std.meta.activeTag(after)) return fail(name, "compiles on one side only");
        switch (before) {
            .report => |report| {
                const left = try normalise(report, source, self.normal[0]);
                const right = try normalise(after.report, first, self.normal[1]);
                if (!std.mem.eql(u8, left, right)) return fail(name, "inspection differs");
            },
            .failed => |diagnostic| {
                if (diagnostic.code != after.failed.code) return fail(name, "diagnostic differs");
                if (!sameIgnoringBlanks(spanText(source, diagnostic.span), spanText(first, after.failed.span))) return fail(name, "diagnostic covers other text");
            },
        }
    }

    fn compile(self: *Corpus, source: []const u8, side: usize) !Outcome {
        scratch.initialise(self.workspace);
        const program = switch (self.workspace.compile(source)) {
            .ok => |program| program,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        var out = std.Io.Writer.fixed(self.reports[side]);
        return switch (try self.inspector.write(&out, program)) {
            .ok => .{ .report = out.buffered() },
            .failed => |diagnostic| .{ .failed = diagnostic },
        };
    }
};

fn fail(name: []const u8, why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("format corpus: {s}: {s}\n", .{ name, why });
    return error.TestUnexpectedResult;
}

/// The report with each source span (`"span"`, `"source"`, `"generic_source"`) given as
/// `solid` offsets, and each `"local_span"` (a span less its module's start) left out.
fn normalise(report: []const u8, source: []const u8, into: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(into);
    var at: usize = 0;
    scan: while (std.mem.indexOfPos(u8, report, at, "\":{\"start\":")) |found| {
        const key_start = std.mem.lastIndexOfScalar(u8, report[0..found], '"') orelse break;
        const key = report[key_start + 1 .. found];
        try out.writeAll(report[at..key_start]);
        at = key_start;
        const local = std.mem.eql(u8, key, "local_span");
        const known = local or std.mem.eql(u8, key, "span") or std.mem.eql(u8, key, "source") or std.mem.eql(u8, key, "generic_source");
        var cursor = found + "\":{\"start\":".len;
        const start = number(report, &cursor);
        if (!known or !std.mem.startsWith(u8, report[cursor..], ",\"end\":")) {
            try out.writeAll(report[at..cursor]);
            at = cursor;
            continue :scan;
        }
        cursor += ",\"end\":".len;
        const end = number(report, &cursor);
        if (local) {
            try out.writeAll("\"local_span\":{");
        } else try out.print("\"{s}\":{{\"start\":{d},\"end\":{d}", .{ key, solid(source, start), solid(source, end) });
        at = cursor;
    }
    try out.writeAll(report[at..]);
    return out.buffered();
}

fn number(text: []const u8, cursor: *usize) usize {
    var value: usize = 0;
    while (cursor.* < text.len and std.ascii.isDigit(text[cursor.*])) : (cursor.* += 1) value = value * 10 + (text[cursor.*] - '0');
    return value;
}

/// The bytes other than blanks and colons before `offset`. The lexer drops the colon of
/// `Name:type := v` and the formatter does not write it, so colons are not counted (the tokens
/// that remain are compared by the formatter itself). An offset past the source is in the
/// library block the compiler appends to it, which is the same text on both sides.
fn solid(source: []const u8, offset: usize) usize {
    var count: usize = 0;
    for (source[0..@min(offset, source.len)]) |byte| {
        if (!std.ascii.isWhitespace(byte) and byte != ':') count += 1;
    }
    return count + (offset -| source.len);
}

fn spanText(source: []const u8, span: types.Span) []const u8 {
    return source[@min(span.start, source.len)..@min(span.end, source.len)];
}

fn sameIgnoringBlanks(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

test "format corpus: every repository source keeps its meaning and formats to a fixed point" {
    const io = std.testing.io;
    var corpus: Corpus = .{
        .formatter = try scratch.storage(format.Storage),
        .workspace = try scratch.storage(Workspace),
        .inspector = try scratch.storage(inspection.Workspace),
        .source = scratch.alloc(u8, types.limits.source_bytes + 1) orelse return error.OutOfMemory,
        .first = scratch.alloc(u8, types.limits.source_bytes) orelse return error.OutOfMemory,
        .reports = .{ scratch.alloc(u8, report_bytes) orelse return error.OutOfMemory, scratch.alloc(u8, report_bytes) orelse return error.OutOfMemory },
        .normal = .{ scratch.alloc(u8, report_bytes) orelse return error.OutOfMemory, scratch.alloc(u8, report_bytes) orelse return error.OutOfMemory },
    };
    defer {
        scratch.release(corpus.formatter);
        scratch.release(corpus.workspace);
        scratch.release(corpus.inspector);
        scratch.free(corpus.source);
        scratch.free(corpus.first);
        for (corpus.reports) |report| scratch.free(report);
        for (corpus.normal) |normal| scratch.free(normal);
    }
    scratch.initialise(corpus.formatter);
    scratch.initialise(corpus.inspector);
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |problem| switch (problem) {
            error.FileNotFound => continue,
            else => return problem,
        };
        defer dir.close(io);
        var walker = try dir.walk(std.testing.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".forb")) continue;
            const source = try entry.dir.readFile(io, entry.basename, corpus.source);
            if (source.len > types.limits.source_bytes) return fail(entry.path, "larger than a source");
            try corpus.check(entry.path, source);
        }
    }
    // Run from a tree without its fixtures, the test has nothing to check.
    if (corpus.files == 0) return error.SkipZigTest;
    // The conformance error fixtures are among the sources the compiler refuses.
    try std.testing.expect(corpus.failing > 0);
    // `lexical.forb` and the comment fixtures hold block and indented comments, which are laid
    // out and checked like the rest.
    try std.testing.expect(corpus.commented >= 3);
}

test "format corpus: the formatting fixture formats to its golden, which is a fixed point" {
    const io = std.testing.io;
    var source_bytes: [4096]u8 = undefined;
    var golden_bytes: [4096]u8 = undefined;
    var directory = try fixtures.open(io, .{}) orelse return error.SkipZigTest;
    defer directory.close(io);
    const source = directory.readFile(io, "formatting-unformatted.forb", &source_bytes) catch |problem| switch (problem) {
        error.FileNotFound => return error.SkipZigTest,
        else => return problem,
    };
    const golden = try directory.readFile(io, "formatting.forb", &golden_bytes);
    const formatter = try scratch.storage(format.Storage);
    defer scratch.release(formatter);
    scratch.initialise(formatter);
    try std.testing.expect(!std.mem.eql(u8, source, golden));
    try std.testing.expectEqualStrings(golden, formatter.format(source).ok);
    try std.testing.expectEqualStrings(golden, formatter.format(golden).ok);
}

test "format corpus: the comment fixture formats to its golden, which is a fixed point" {
    const io = std.testing.io;
    var source_bytes: [4096]u8 = undefined;
    var golden_bytes: [4096]u8 = undefined;
    var directory = try fixtures.open(io, .{}) orelse return error.SkipZigTest;
    defer directory.close(io);
    const source = try directory.readFile(io, "formatting-comments-unformatted.forb", &source_bytes);
    const golden = try directory.readFile(io, "formatting-comments.forb", &golden_bytes);
    const formatter = try scratch.storage(format.Storage);
    defer scratch.release(formatter);
    scratch.initialise(formatter);
    try std.testing.expect(!std.mem.eql(u8, source, golden));
    // The fixture holds a block comment and an indented comment of every kind the layout names.
    try std.testing.expect(std.mem.count(u8, source, "<#>") >= 3 and std.mem.count(u8, source, "<#") >= 12);
    try std.testing.expectEqualStrings(golden, formatter.format(source).ok);
    try std.testing.expectEqualStrings(golden, formatter.format(golden).ok);
}
