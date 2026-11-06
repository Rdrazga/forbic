//! Minimal test runner that selects the `program` capacity profile for Forbic:
//!   zig test src/forbic/root.zig --test-runner src/forbic_program_runner.zig (from `forbic/`),
//!   or `zig build test-program` in `forbic/`.
//! The default runner owns `@import("root")`, so a profile override must live here.
const std = @import("std");
const builtin = @import("builtin");

pub const forbic_profile_name = "program";

pub fn main() !void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    for (builtin.test_functions) |test_function| {
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
        std.testing.io_instance = .init(std.testing.allocator, .{});
        // A capacity that costs time whether or not a test uses it shows up here first.
        const started = std.Io.Clock.awake.now(std.testing.io);
        const outcome = test_function.func();
        const elapsed = @divTrunc(started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms);
        if (elapsed >= 500) std.debug.print("SLOW {d} ms {s}\n", .{ elapsed, test_function.name });
        std.testing.io_instance.deinit();
        const leaked = std.testing.allocator_instance.deinit() != 0;
        outcome catch |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                continue;
            },
            else => {
                failed += 1;
                std.debug.print("FAIL {s}: {s}\n", .{ test_function.name, @errorName(err) });
                continue;
            },
        };
        if (leaked) {
            failed += 1;
            std.debug.print("LEAK {s}\n", .{test_function.name});
            continue;
        }
        passed += 1;
    }
    std.debug.print("{d} passed; {d} skipped; {d} failed under profile {s}.\n", .{ passed, skipped, failed, forbic_profile_name });
    if (failed != 0) std.process.exit(1);
}
