//! Makes `.zig-cache/` in the directory it runs in (the package root): six conformance
//! scenarios write their logs there (`--write log=.zig-cache/...`), and a package built inside
//! another tree, or with its cache elsewhere, has no such directory of its own.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache");
}
