//! TASK-0109, W3.2a/W3.3a: the boundary of the Forbic host services. The package's `check`
//! (`forbic/build.zig`) compiles this file as the root of a module whose directory is `forbic/src`
//! and whose only import is the `forbic` module, so that the host services compile with nothing of
//! ForbOS reachable: an import of a ForbOS file by any of them leaves the module's directory (or,
//! in a copy of the package alone, names a file that is not there), and `@import("forbos")` names
//! no module; either fails the build.
const std = @import("std");
const forbic_host = @import("tooling/forbic_host.zig");

test "forbic host boundary" {
    // Every public service and type of the host, and through them every function they call.
    std.testing.refAllDecls(forbic_host);
    std.testing.refAllDecls(@import("tooling/journal.zig"));
    std.testing.refAllDecls(@import("tooling/storage.zig"));
    std.testing.refAllDecls(@import("tooling/input.zig"));
    std.testing.refAllDecls(@import("tooling/output.zig"));
    std.testing.refAllDecls(@import("tooling/format_command.zig"));
    std.testing.refAllDecls(@import("tooling/project.zig"));
}
