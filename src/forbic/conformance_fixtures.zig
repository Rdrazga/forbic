//! Where the conformance fixtures are, for the tests that read them (TASK-0109, W3.3b). The
//! tests run in the package root (`zig build test` in `forbic/`) or in the root of a tree that
//! holds the package in `forbic/` (ForbOS's build and gate scripts run them there). A test run
//! where neither is found has nothing to check.
const std = @import("std");

/// From the package root, then from the root of a tree holding the package.
pub const roots = [_][]const u8{ "tests/conformance", "forbic/tests/conformance" };

/// The first of `roots` that is a directory here, opened; null if none is.
pub fn open(io: std.Io, options: std.Io.Dir.OpenOptions) !?std.Io.Dir {
    for (roots) |root| {
        return std.Io.Dir.cwd().openDir(io, root, options) catch |problem| switch (problem) {
            error.FileNotFound => continue,
            else => return problem,
        };
    }
    return null;
}
