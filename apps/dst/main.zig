//! The Forbic deterministic simulator (`forbic-dst`): the language and journal suites of
//! `forbic_dst`. Explicit seed replay; assertions and simulator failures yield a nonzero exit.
//! ForbOS's `forbos-dst` runs the same suites among its own.
const std = @import("std");
const builtin = @import("builtin");
const dst = @import("forbic_dst");
/// Standard handles as they were opened: a failure trace can exceed a pipe's buffer.
const output = @import("forbic_host").output;
const Options = struct { run: dst.Options = .{}, suite: ?dst.Suite = null };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parse(args) catch {
        var bytes: [512]u8 = undefined;
        var writer = output.standard(.stderr).writer(init.io, &bytes);
        try writer.interface.writeAll("usage: forbic-dst [--seed U64] [--steps 1..1000000] [--suite all|language|journal] [--mode swarm|performance]\n");
        try writer.interface.flush();
        std.process.exit(2);
    };
    var bytes: [4096]u8 = undefined;
    var writer = output.standard(.stdout).writer(init.io, &bytes);
    var context: dst.kernel.Context = undefined;
    // Flush the replay header before running. A native assertion can abort
    // without unwinding; the campaign driver still has the exact seed/binary.
    try std.json.Stringify.value(.{ .type = "start", .version = dst.kernel.version, .seed = options.run.seed, .steps = options.run.steps, .mode = options.run.mode, .zig = builtin.zig_version_string, .build_mode = @tagName(builtin.mode), .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag) }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    for (std.meta.tags(dst.Suite)) |suite| {
        if (options.suite != null and options.suite.? != suite) continue;
        const report = dst.run(init.gpa, suite, options.run, &context) catch |err| {
            try std.json.Stringify.value(.{ .type = "failure", .suite = suite, .seed = options.run.seed, .steps = options.run.steps, .mode = options.run.mode, .version = dst.kernel.version, .step = context.step, .tick = context.tick, .phase = context.phase, .error_name = @errorName(err), .property = context.failure, .counters = context.counters, .profile = context.profile, .trace_sha256 = context.hash() }, .{}, &writer.interface);
            try writer.interface.writeByte('\n');
            try writer.interface.writeAll("{\"type\":\"trace\",\"entries\":");
            try context.writeTrace(&writer.interface);
            try writer.interface.writeAll("}\n");
            try writer.interface.flush();
            std.process.exit(1);
        };
        try std.json.Stringify.value(.{ .type = "result", .report = report }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }
}
fn parse(args: []const [:0]const u8) !Options {
    if (args.len % 2 != 1 or args.len > 9) return error.Arguments;
    var result: Options = .{};
    var seen: u4 = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const key = args[index];
        const value = args[index + 1];
        const flag: u4 = if (std.mem.eql(u8, key, "--seed")) 1 else if (std.mem.eql(u8, key, "--steps")) 2 else if (std.mem.eql(u8, key, "--suite")) 4 else if (std.mem.eql(u8, key, "--mode")) 8 else return error.Arguments;
        if (seen & flag != 0) return error.Arguments;
        seen |= flag;
        switch (flag) {
            1 => result.run.seed = try std.fmt.parseInt(u64, value, 10),
            2 => result.run.steps = try std.fmt.parseInt(u32, value, 10),
            4 => result.suite = if (std.mem.eql(u8, value, "all")) null else std.meta.stringToEnum(dst.Suite, value) orelse return error.Arguments,
            8 => result.run.mode = std.meta.stringToEnum(dst.kernel.Mode, value) orelse return error.Arguments,
            else => unreachable,
        }
    }
    try result.run.validate();
    return result;
}
test "CLI rejects ambiguous options and invalid budgets" {
    try std.testing.expectError(error.Arguments, parse(&.{ "dst", "--seed", "0", "--seed", "1" }));
    try std.testing.expectError(error.Arguments, parse(&.{ "dst", "--suite", "engine" }));
    try std.testing.expectError(error.InvalidOptions, parse(&.{ "dst", "--steps", "0" }));
    try std.testing.expectEqual(@as(u64, 18446744073709551615), (try parse(&.{ "dst", "--seed", "18446744073709551615" })).run.seed);
}
