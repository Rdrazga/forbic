//! Deterministic simulation of Forbic (module `forbic_dst`; TASK-0109, W3.3c): the kernel, the
//! campaign runner, and the language and journal suites. Developer-only.
//!
//! A consumer with suites of its own (ForbOS's `src/simulation`) runs them with `runSuite` under
//! its own `Suite` enum and the same kernel, so its reports keep their suite names, seeds and
//! trace hashes.
const std = @import("std");
comptime {
    if (@import("builtin").mode == .fast or @import("builtin").mode == .small)
        @compileError("Deterministic simulation requires Debug or ReleaseSafe assertions");
}
pub const kernel = @import("kernel.zig");
pub const language = @import("language.zig");
pub const journal = @import("journal.zig");
/// Requested-byte accounting of a campaign (a copy of ForbOS's UI host meter, so this package
/// depends on no UI host path).
pub const Meter = @import("meter.zig").Meter;
pub const Suite = enum { language, journal };
// Their tests are this module's tests; the block adds none.
comptime {
    _ = kernel;
    _ = language;
    _ = journal;
    _ = @import("meter.zig");
}
pub fn Report(comptime SuiteName: type) type {
    return struct {
        version: u32 = kernel.version,
        seed: u64,
        suite: SuiteName,
        mode: kernel.Mode,
        steps: u32,
        virtual_ticks: u64,
        counters: kernel.Counters,
        profile: kernel.Profile,
        trace_sha256: [64]u8,
        state_bytes: usize,
        requested_peak_bytes: usize,
        initialization_allocations: u64,
        live_bytes_after_teardown: usize,
        recovery_completed: bool,
    };
}
pub const Options = struct {
    seed: u64 = 0,
    steps: u32 = 1000,
    mode: kernel.Mode = .swarm,
    pub fn validate(self: Options) kernel.Error!void {
        if (self.steps == 0 or self.steps > kernel.max_steps) return error.InvalidOptions;
    }
};

pub fn run(gpa: std.mem.Allocator, suite: Suite, options: Options, context: *kernel.Context) !Report(Suite) {
    return switch (suite) {
        .language => runSuite(language.State, gpa, suite, options, context),
        .journal => runSuite(journal.State, gpa, suite, options, context),
    };
}
/// Runs one campaign of `State`, reported as `suite` (a tag of the caller's suite enum, whose
/// name seeds the trace).
pub fn runSuite(comptime State: type, gpa: std.mem.Allocator, suite: anytype, options: Options, context: *kernel.Context) !Report(@TypeOf(suite)) {
    try options.validate();
    context.* = kernel.Context.init(options.seed, options.mode);
    context.record(@tagName(suite), options.steps, kernel.version);
    return runState(State, gpa, suite, options, context);
}
fn runState(comptime State: type, gpa: std.mem.Allocator, suite: anytype, options: Options, c: *kernel.Context) !Report(@TypeOf(suite)) {
    var meter: Meter = .{ .backing = gpa, .limit_bytes = std.math.maxInt(usize) };
    const report = try runManaged(State, meter.allocator(), suite, options, c, &meter);
    try c.check(meter.live_bytes == 0, "simulation_teardown_releases_all_requested_bytes");
    var result = report;
    result.counters = c.counters;
    result.trace_sha256 = c.hash();
    result.live_bytes_after_teardown = meter.live_bytes;
    return result;
}
fn runManaged(comptime State: type, gpa: std.mem.Allocator, suite: anytype, options: Options, c: *kernel.Context, meter: *Meter) !Report(@TypeOf(suite)) {
    // The state is requested through the meter like every byte of a campaign, but as raw
    // memory: `create` would fill it with a marker in safe builds, writing (and so committing)
    // every page of storage that is mostly never used. Debug keeps the marker.
    const memory = gpa.rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(memory));
    if (@import("builtin").mode == .debug) @memset(memory[0..@sizeOf(State)], undefined);
    defer gpa.destroy(state);
    if (@hasDecl(State, "initInPlace")) {
        try state.initInPlace(gpa);
    } else {
        state.* = if (@hasDecl(State, "init")) try State.init(gpa) else .{};
    }
    defer if (@hasDecl(State, "deinit")) state.deinit(gpa);
    const initialized = .{ .allocations = meter.allocation_calls, .resizes = meter.resize_calls, .frees = meter.free_calls, .bytes = meter.live_bytes };
    meter.deny_allocations = true;
    for (0..options.steps) |step| {
        c.step = @intCast(step);
        c.counters.operations += 1;
        c.record("step", step, 0);
        try state.step(c);
        try c.advance(1);
    }
    c.step = options.steps;
    c.heal();
    try state.finish(c);
    try c.check(c.counters.operations == options.steps, "requested_operations_completed");
    try c.check(c.counters.checks > options.steps, "nonvacuous_oracle_coverage");
    try c.check(!meter.failure_observed and meter.allocation_calls == initialized.allocations and meter.resize_calls == initialized.resizes and meter.free_calls == initialized.frees, "no_simulation_loop_allocation_or_release");
    try c.check(meter.live_bytes == initialized.bytes, "simulation_memory_stays_at_initialized_budget");
    return .{ .seed = options.seed, .suite = suite, .mode = options.mode, .steps = options.steps, .virtual_ticks = c.tick, .counters = c.counters, .profile = c.profile, .trace_sha256 = c.hash(), .state_bytes = @sizeOf(State), .requested_peak_bytes = meter.peak_bytes, .initialization_allocations = initialized.allocations, .live_bytes_after_teardown = 0, .recovery_completed = true };
}
