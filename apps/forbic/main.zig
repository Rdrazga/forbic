const std = @import("std");
const options = @import("build_options");

/// The language tool is built with the `program` capacity profile by default
/// (see docs/rfcs/0048-capacity-profiles.md); `zig build -Dprofile=bootstrap` builds the small one.
pub const forbic_profile_name = options.profile;

pub fn main(init: std.process.Init) !void {
    try @import("forbic_host").command.main(init);
}
