//! Read one bounded regular-file snapshot. Linux opens nonblocking before fstat,
//! so a FIFO path cannot stall the host before its kind is rejected.
const std = @import("std");
const builtin = @import("builtin");

pub fn read(io: std.Io, path: [:0]const u8, buffer: []u8, maximum: usize) ![]const u8 {
    std.debug.assert(maximum > 0 and buffer.len == maximum + 1);
    const file = try open(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InputNotRegularFile;
    if (stat.size > maximum) return error.InputBudget;
    const count = try file.readPositionalAll(io, buffer, 0);
    if (count > maximum) return error.InputBudget;
    std.debug.assert(count <= maximum);
    return buffer[0..count];
}

fn open(io: std.Io, path: [:0]const u8) !std.Io.File {
    if (builtin.os.tag != .linux) return std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = true });
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true };
    for (0..4) |_| {
        const result = linux.openat(linux.AT.FDCWD, path, flags, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return .{ .handle = @intCast(result), .flags = .{ .nonblocking = true } },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.InputOpen,
        }
    }
    return error.InputInterrupted;
}

test "bounded input reads exact regular snapshots and rejects directories and overage" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_length = try temporary.dir.realPath(io, &directory);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&path, "{s}/source.forb", .{directory[0..directory_length]}, 0);
    var buffer: [5]u8 = undefined;
    try temporary.dir.writeFile(io, .{ .sub_path = "source.forb", .data = "four" });
    try std.testing.expectEqualStrings("four", try read(io, file, &buffer, 4));
    try temporary.dir.writeFile(io, .{ .sub_path = "source.forb", .data = "" });
    try std.testing.expectEqualStrings("", try read(io, file, &buffer, 4));
    try temporary.dir.writeFile(io, .{ .sub_path = "source.forb", .data = "extra" });
    try std.testing.expectError(error.InputBudget, read(io, file, &buffer, 4));
    const folder = try std.mem.printSentinel(&path, "{s}", .{directory[0..directory_length]}, 0);
    try std.testing.expectError(error.InputNotRegularFile, read(io, folder, &buffer, 4));
}

test "Linux FIFO input is rejected without requiring a writer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try temporary.dir.realPath(io, &directory);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&path, "{s}/waiting.forb", .{directory[0..count]}, 0);
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0)));
    var buffer: [5]u8 = undefined;
    try std.testing.expectError(error.InputNotRegularFile, read(io, fifo, &buffer, 4));
}
