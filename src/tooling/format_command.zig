//! TASK-0109, W4.5: `forbic fmt FILE...` rewrites each file in its canonical layout,
//! `forbic fmt --check FILE...` lists the files that would change and changes none, and
//! `forbic fmt -` formats standard input to standard output. See docs/formatting.md.
const std = @import("std");
const builtin = @import("builtin");
const forbic = @import("forbic");
const input = @import("input.zig");
const stdio = @import("output.zig");

pub const Mode = enum { write, check };

/// `args` are the words after `fmt`. Returns the exit status: 0 when every file is formatted
/// (or, with `--check`, already was), 1 when a file would change or could not be formatted,
/// and 2 for a command line it does not take, after `usage` has been written.
pub fn run(io: std.Io, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer, usage: *const fn (*std.Io.Writer) anyerror!u8) !u8 {
    var mode: Mode = .write;
    var files = args;
    if (files.len > 0 and std.mem.eql(u8, files[0], "--check")) {
        mode = .check;
        files = files[1..];
    }
    if (files.len == 0) return usage(err);
    const piped = files.len == 1 and std.mem.eql(u8, files[0], "-");
    for (files) |file| {
        // Options come first, and `-` stands alone.
        if (!piped and (std.mem.eql(u8, file, "-") or std.mem.startsWith(u8, file, "--"))) return usage(err);
    }
    const storage = try forbic.scratch.storage(forbic.format.Storage);
    defer forbic.scratch.release(storage);
    forbic.scratch.initialise(storage);
    const maximum = forbic.types.limits.source_bytes;
    // Room for the largest admissible source and one byte more, which tells a larger one.
    const buffer = forbic.scratch.alloc(u8, maximum + 1) orelse return error.OutOfMemory;
    defer forbic.scratch.free(buffer);
    if (piped) {
        var reader_buffer: [4096]u8 = undefined;
        var reader = stdio.describe(std.Io.File.stdin()).readerStreaming(io, &reader_buffer);
        return stream(storage, &reader.interface, buffer, mode, out, err);
    }
    var status: u8 = 0;
    for (files) |path| status = @max(status, try formatFile(io, storage, path, buffer, mode, out, err));
    return status;
}

/// Formats standard input; with `--check`, prints `-` instead when it would change.
pub fn stream(storage: *forbic.format.Storage, reader: *std.Io.Reader, buffer: []u8, mode: Mode, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const maximum = buffer.len - 1;
    const count = reader.readSliceShort(buffer) catch return refuse(err, "-", "cannot read standard input");
    if (count > maximum) return tooLarge(err, "-");
    const source = buffer[0..count];
    const text = try formatted(storage, "-", source, err) orelse return 1;
    if (mode == .check) {
        if (std.mem.eql(u8, text, source)) return 0;
        try out.writeAll("-\n");
        return 1;
    }
    try out.writeAll(text);
    return 0;
}

fn formatFile(io: std.Io, storage: *forbic.format.Storage, path: [:0]const u8, buffer: []u8, mode: Mode, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const maximum = buffer.len - 1;
    const source = input.read(io, path, buffer, maximum) catch |problem| {
        if (problem == error.InputBudget) return tooLarge(err, path);
        try err.print("{s}: error: cannot read source ({s})\n", .{ path, @errorName(problem) });
        return 1;
    };
    const text = try formatted(storage, path, source, err) orelse return 1;
    if (std.mem.eql(u8, text, source)) return 0;
    if (mode == .check) {
        try out.print("{s}\n", .{path});
        return 1;
    }
    // The new text replaces the file in one step: a failure leaves the old text whole.
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |problem| return cannotWrite(err, path, problem);
    // A replace would put a regular file where the link was.
    if (stat.kind == .sym_link) return refuse(err, path, "is a symbolic link; format the file it names");
    // Renaming over a file would get past what forbids writing it.
    const writable = cwd.openFile(io, path, .{ .mode = .write_only }) catch |problem| return cannotWrite(err, path, problem);
    writable.close(io);
    const permissions = stat.permissions;
    var atomic = cwd.createFileAtomic(io, path, .{ .replace = true, .permissions = permissions }) catch |problem| return cannotWrite(err, path, problem);
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, text) catch |problem| return cannotWrite(err, path, problem);
    atomic.replace(io) catch |problem| return cannotWrite(err, path, problem);
    return 0;
}

/// The formatted text, or null after a diagnostic for `path`.
fn formatted(storage: *forbic.format.Storage, path: []const u8, source: []const u8, err: *std.Io.Writer) !?[]const u8 {
    switch (storage.format(source)) {
        .ok => |text| return text,
        .failed => |failure| switch (failure) {
            .lexical => |diagnostic| {
                if (diagnostic.code == .source_limit) {
                    _ = try tooLarge(err, path);
                    return null;
                }
                const position = diagnostic.location(source);
                try err.print("{s}:{d}:{d}: error: {s}\n", .{ path, position.line, position.column, diagnostic.message() });
            },
            .output_limit => try err.print("{s}: error: the formatted source would be larger than the {d}-byte source limit\n", .{ path, forbic.types.limits.source_bytes }),
            .stray_carriage_return => |offset| {
                const position = (forbic.types.Diagnostic{ .span = .{ .start = offset, .end = offset }, .code = .source_limit }).location(source);
                try err.print("{s}:{d}:{d}: error: a carriage return that does not end a line; the file is left as it is\n", .{ path, position.line, position.column });
            },
            .comment_changed => |offset| {
                const position = (forbic.types.Diagnostic{ .span = .{ .start = offset, .end = offset }, .code = .source_limit }).location(source);
                try err.print("{s}:{d}:{d}: error: the formatter would change a comment here (a formatter defect); nothing is written\n", .{ path, position.line, position.column });
            },
            .tokens_changed => |offset| {
                const position = (forbic.types.Diagnostic{ .span = .{ .start = offset, .end = offset }, .code = .source_limit }).location(source);
                try err.print("{s}:{d}:{d}: error: the formatter would change the program here (a formatter defect); nothing is written\n", .{ path, position.line, position.column });
            },
        },
    }
    return null;
}

fn tooLarge(err: *std.Io.Writer, path: []const u8) !u8 {
    try err.print("{s}: error: source is larger than the {d}-byte limit\n", .{ path, forbic.types.limits.source_bytes });
    return 1;
}

fn refuse(err: *std.Io.Writer, path: []const u8, why: []const u8) !u8 {
    try err.print("{s}: error: {s}\n", .{ path, why });
    return 1;
}

fn cannotWrite(err: *std.Io.Writer, path: []const u8, problem: anyerror) !u8 {
    try err.print("{s}: error: cannot write the formatted source ({s})\n", .{ path, @errorName(problem) });
    return 1;
}

fn testUsage(err: *std.Io.Writer) anyerror!u8 {
    try err.writeAll("usage\n");
    return 2;
}

test "fmt rewrites files in place, checks without writing, and reports what it refuses" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "a.forb", .data = "A:i64=1\r\n\r\n\r\nB:=Block{\n2}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.forb", .data = "B := 2\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "bad.forb", .data = "A := 1\nS := \"open\n" });
    var paths: [4][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const a = try std.mem.printSentinel(&paths[0], "{s}/a.forb", .{at}, 0);
    const b = try std.mem.printSentinel(&paths[1], "{s}/b.forb", .{at}, 0);
    const bad = try std.mem.printSentinel(&paths[2], "{s}/bad.forb", .{at}, 0);
    const missing = try std.mem.printSentinel(&paths[3], "{s}/missing.forb", .{at}, 0);
    var out_bytes: [1024]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    // `--check` lists the file that would change, and writes nothing.
    try std.testing.expectEqual(@as(u8, 1), try run(io, &.{ "--check", a, b }, &out, &message, testUsage));
    var want: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}\n", .{a}), out.buffered());
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings("A:i64=1\r\n\r\n\r\nB:=Block{\n2}\n", try temporary.dir.readFile(io, "a.forb", &file_bytes));
    // Without it the file is rewritten, and a formatted file is left as it is.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try run(io, &.{ a, b }, &out, &message, testUsage));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectEqualStrings("A:i64 = 1\n\nB := Block{\n    2}\n", try temporary.dir.readFile(io, "a.forb", &file_bytes));
    try std.testing.expectEqual(@as(u8, 0), try run(io, &.{ "--check", a, b }, &out, &message, testUsage));
    try std.testing.expectEqualStrings("", out.buffered());
    // A file the lexer refuses is named with the position, and the others are still formatted.
    try temporary.dir.writeFile(io, .{ .sub_path = "b.forb", .data = "B:=2\n" });
    try std.testing.expectEqual(@as(u8, 1), try run(io, &.{ bad, missing, b }, &out, &message, testUsage));
    var expected: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}:2:6: error: string must close before the end of the line\n{s}: error: cannot read source (FileNotFound)\n", .{ bad, missing }), message.buffered());
    try std.testing.expectEqualStrings("B := 2\n", try temporary.dir.readFile(io, "b.forb", &file_bytes));
    try std.testing.expectEqualStrings("A := 1\nS := \"open\n", try temporary.dir.readFile(io, "bad.forb", &file_bytes));
    // A file its user may not write is left as it is, though its directory would allow a rename.
    // Zig 0.17 sets no file permissions on Windows (`dirSetFilePermissions` is a TODO there).
    if (builtin.os.tag != .windows) {
        try temporary.dir.writeFile(io, .{ .sub_path = "b.forb", .data = "B:=2\n" });
        try temporary.dir.setFilePermissions(io, "b.forb", @fromBackingInt(@intCast(0o444)), .{});
        defer temporary.dir.setFilePermissions(io, "b.forb", .default_file, .{}) catch {};
        const forbidden = if (temporary.dir.openFile(io, "b.forb", .{ .mode = .write_only })) |opened| allowed: {
            // A user every file is writable to (root) cannot test this.
            opened.close(io);
            break :allowed false;
        } else |_| true;
        if (forbidden) {
            message = .fixed(&err_bytes);
            try std.testing.expectEqual(@as(u8, 1), try run(io, &.{b}, &out, &message, testUsage));
            try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "error: cannot write the formatted source (") != null);
            try std.testing.expectEqualStrings("B:=2\n", try temporary.dir.readFile(io, "b.forb", &file_bytes));
        }
    }
    // Command lines it does not take.
    for ([_][]const [:0]const u8{ &.{}, &.{"--check"}, &.{ "--quiet", a }, &.{ a, "--check" }, &.{ a, "-" }, &.{ "-", "-" } }) |words| {
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try run(io, words, &out, &message, testUsage));
        try std.testing.expectEqualStrings("usage\n", message.buffered());
    }
}

test "fmt lays out block and indented comments, and names a comment the lexer refuses" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "c.forb", .data = "B:=Block{\n<# a\n  b #>\n<#>\n    note\nX <# c #>+1}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "open.forb", .data = "A := 1 <# open\n" });
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const c = try std.mem.printSentinel(&paths[0], "{s}/c.forb", .{at}, 0);
    const open = try std.mem.printSentinel(&paths[1], "{s}/open.forb", .{at}, 0);
    var out_bytes: [1024]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try run(io, &.{ "--check", c }, &out, &message, testUsage));
    try std.testing.expectEqual(@as(u8, 0), try run(io, &.{c}, &out, &message, testUsage));
    try std.testing.expectEqualStrings("B := Block{\n    <# a\n      b #>\n    <#>\n        note\n    X <# c #> + 1}\n", try temporary.dir.readFile(io, "c.forb", &file_bytes));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try run(io, &.{ "--check", c }, &out, &message, testUsage));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectEqualStrings("", message.buffered());
    // The lexer's own refusal is reported, with its position, and the file is left as it is.
    try std.testing.expectEqual(@as(u8, 1), try run(io, &.{open}, &out, &message, testUsage));
    var want: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), try std.fmt.bufPrint(&want, "{s}:1:8: error: ", .{open})));
    try std.testing.expectEqualStrings("A := 1 <# open\n", try temporary.dir.readFile(io, "open.forb", &file_bytes));
}

test "fmt of a stream: formatted text out, a check, and the size limit" {
    const storage = try forbic.scratch.storage(forbic.format.Storage);
    defer forbic.scratch.release(storage);
    forbic.scratch.initialise(storage);
    var buffer: [65]u8 = undefined;
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    var reader: std.Io.Reader = .fixed("X:=F( 1,2 )\n");
    try std.testing.expectEqual(@as(u8, 0), try stream(storage, &reader, &buffer, .write, &out, &message));
    try std.testing.expectEqualStrings("X := F(1, 2)\n", out.buffered());
    out = .fixed(&out_bytes);
    reader = .fixed("X:=1\n");
    try std.testing.expectEqual(@as(u8, 1), try stream(storage, &reader, &buffer, .check, &out, &message));
    try std.testing.expectEqualStrings("-\n", out.buffered());
    out = .fixed(&out_bytes);
    reader = .fixed("X := 1\n");
    try std.testing.expectEqual(@as(u8, 0), try stream(storage, &reader, &buffer, .check, &out, &message));
    try std.testing.expectEqualStrings("", out.buffered());
    // A stream longer than the room it is given is refused whole.
    const comment: [60]u8 = @splat('c');
    reader = .fixed("X := 1 # " ++ comment ++ "\n");
    try std.testing.expectEqual(@as(u8, 1), try stream(storage, &reader, &buffer, .write, &out, &message));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "-: error: source is larger than the "));
}
