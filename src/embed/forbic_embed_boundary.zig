//! TASK-0109, W4.4: the boundary of the embedding API. The package's `check` (`forbic/build.zig`)
//! compiles this file as the root of a module whose directory is `forbic/src/embed` and whose only
//! imports are the package's `forbic` and `forbic_host` modules, so that every public declaration of
//! the API compiles with nothing of ForbOS reachable: an import of a file outside this directory
//! fails the build, and `@import("forbos")` names no module.
const std = @import("std");

test "forbic embed boundary" {
    // Every public function and type of the API, and through them every function they call.
    std.testing.refAllDecls(@import("forbic_embed.zig"));
}
