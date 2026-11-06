//! The `forbic_host` module (TASK-0109, W3.3a): the Forbic command line and the host services a
//! program runs with. `command` is the `forbic` command line, `execute` and its `Request`, and the
//! run's options, grants, journal, store and reports (`forbic_host.zig`); the others are the
//! services it is made of. The module imports the language as the `forbic` module, the same
//! module object an embedding host gets, never by path, so one build has one set of language
//! types; it has no import of ForbOS code.
pub const command = @import("forbic_host.zig");
pub const journal = @import("journal.zig");
pub const storage = @import("storage.zig");
pub const input = @import("input.zig");
pub const output = @import("output.zig");
pub const format_command = @import("format_command.zig");
/// TASK-0109, W4.6: a project directory read into the packet of its folder tree.
pub const project = @import("project.zig");

// The services' tests are this module's (a `comptime` reference adds no test of its own, so the
// counts stay those of the files).
comptime {
    _ = command;
    _ = journal;
    _ = storage;
    _ = input;
    _ = output;
    _ = format_command;
    _ = project;
}
