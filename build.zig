const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) {
        @compileError("Forbic requires Zig 0.17.0.");
    }
}

/// The Forbic package (TASK-0109, W3.3a). Modules: `forbic`, the language (compiler, both
/// machines, reports); `forbic_host`, the `forbic` command line and the host services, built on
/// that same `forbic` module object; `forbic_dst`, the deterministic simulation kernel, runner and
/// the language and journal suites (W3.3c). Artifact: the `forbic` executable. A consumer passes
/// its target, optimisation and `profile` to `b.dependency("forbic", ...)` and attaches the
/// `check`, `test`, `integration` and `dst-test` steps itself: depending on the package builds
/// none of its tests.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option([]const u8, "profile", "Forbic capacity profile for the language tool: program (default) or bootstrap") orelse "program";
    const forbic = b.addModule("forbic", .{
        .root_source_file = b.path("src/forbic/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host = b.addModule("forbic_host", .{
        .root_source_file = b.path("src/tooling/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "forbic", .module = forbic }},
    });
    const dst = b.addModule("forbic_dst", .{
        .root_source_file = b.path("src/dst/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "forbic", .module = forbic }},
    });

    const check = b.step("check", "Compile the language, the host, the forbic CLI and their tests");
    const test_step = b.step("test", "Run the language tests at the bootstrap profile and the host tests");
    const test_program = b.step("test-program", "Run the language tests at the program profile");

    // The capacity profile is chosen by the root source file of the final program
    // (`src/forbic/profile.zig`): the CLI's root declares it from this option.
    const profile_options = b.addOptions();
    profile_options.addOption([]const u8, "profile", profile);
    const tool = b.addExecutable(.{ .name = "forbic", .root_module = b.createModule(.{
        .root_source_file = b.path("apps/forbic/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "forbic_host", .module = host }, .{ .name = "build_options", .module = profile_options.createModule() } },
    }) });
    b.installArtifact(tool);
    check.dependOn(&tool.step);
    const run = b.addRunArtifact(tool);
    run.addPassthruArgs();
    b.step("forbic", "Run the forbic CLI").dependOn(&run.step);

    // The default test runner declares no profile, so these run at the bootstrap capacities.
    for ([_]*std.Build.Module{ forbic, host }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        check.dependOn(&tests.step);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const program_tests = b.addTest(.{
        .name = "forbic-program",
        .root_module = forbic,
        .test_runner = .{ .path = b.path("src/forbic_program_runner.zig"), .mode = .simple },
    });
    check.dependOn(&program_tests.step);
    test_program.dependOn(&b.addRunArtifact(program_tests).step);

    // The host boundary: every public declaration of the host services, analysed with only this
    // package and the standard library reachable (`src/forbic_host_boundary.zig`).
    const boundary = b.addTest(.{
        .name = "forbic-host-boundary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/forbic_host_boundary.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "forbic", .module = forbic }},
        }),
        .filters = &.{"forbic host boundary"},
    });
    check.dependOn(&boundary.step);
    addEmbedding(b, target, optimize, forbic, host, check, test_step);

    // The conformance scenarios (TASK-0109, W3.3b). The goldens record capacity-dependent
    // numbers, so they are checked with a tool built at the bootstrap capacities whatever the
    // installed tool uses.
    const integration = b.step("integration", "Run the conformance scenarios");
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "profile", "bootstrap");
    const conformance = b.addExecutable(.{ .name = "forbic-conformance", .root_module = b.createModule(.{
        .root_source_file = b.path("apps/forbic/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "forbic_host", .module = host }, .{ .name = "build_options", .module = conformance_options.createModule() } },
    }) });
    check.dependOn(&conformance.step);
    addConformanceTests(b, conformance, integration);
    addProjectTests(b, conformance, integration);
    // Six scenarios write logs under `.zig-cache/` of the package root (`--write
    // log=.zig-cache/...`), which a package built inside another tree does not have: every
    // scenario waits for a helper that makes it.
    const scratch = b.addRunArtifact(b.addExecutable(.{ .name = "conformance-scratch", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/scratch_directory.zig"),
        .target = b.graph.host,
    }) }));
    scratch.setCwd(b.path("."));
    scratch.has_side_effects = true;
    scratch.expectExitCode(0);
    for (integration.dependencies.items) |scenario_step| scenario_step.dependOn(&scratch.step);

    // TASK-0109, W4.4: the example host run twice on one fresh directory.
    integration.dependOn(&b.top_level_steps.get("forbic-example-scenario").?.step);

    // The deterministic simulation (TASK-0109, W3.3c): `forbic-dst` runs the language and
    // journal campaigns of `forbic_dst` (ForbOS's `forbos-dst` runs them among its own suites).
    const simulator = b.addExecutable(.{ .name = "forbic-dst", .root_module = b.createModule(.{
        .root_source_file = b.path("apps/dst/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "forbic_dst", .module = dst }, .{ .name = "forbic_host", .module = host } },
    }) });
    check.dependOn(&simulator.step);
    const campaign = b.addRunArtifact(simulator);
    campaign.addPassthruArgs();
    b.step("dst", "Run the seeded language and journal deterministic simulations").dependOn(&campaign.step);
    b.step("dst-install", "Install only the Forbic deterministic simulator").dependOn(&b.addInstallArtifact(simulator, .{}).step);
    const dst_test = b.step("dst-test", "Run the deterministic simulation kernel, the language and journal suites and the simulator's tests");
    for ([_]*std.Build.Module{ dst, simulator.root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        check.dependOn(&tests.step);
        dst_test.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// TASK-0109, W4.4: the embedding API, the module `forbic_embed` (`src/embed/forbic_embed.zig`), on
/// the same `forbic` and `forbic_host` objects as the CLI. Its tests run in `test` at the bootstrap
/// profile; `check` compiles them, its boundary and the example host. The example's scenario, two
/// runs on one fresh directory with the second seeing what the first kept, is the step
/// `forbic-example-scenario`.
fn addEmbedding(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode, forbic: *std.Build.Module, host: *std.Build.Module, check: *std.Build.Step, test_step: *std.Build.Step) void {
    const embedding = b.addModule("forbic_embed", .{
        .root_source_file = b.path("src/embed/forbic_embed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "forbic", .module = forbic }, .{ .name = "forbic_host", .module = host } },
    });
    const tests = b.addTest(.{ .name = "forbic-embed", .root_module = embedding });
    check.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The boundary: every public declaration of the API, analysed with only the package's
    // modules reachable from `src/embed` (`src/embed/forbic_embed_boundary.zig`).
    const boundary = b.addTest(.{
        .name = "forbic-embed-boundary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/embed/forbic_embed_boundary.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "forbic", .module = forbic }, .{ .name = "forbic_host", .module = host } },
        }),
        .filters = &.{"forbic embed boundary"},
    });
    check.dependOn(&boundary.step);

    const executable = b.addExecutable(.{ .name = "forbic-example", .root_module = b.createModule(.{
        .root_source_file = b.path("apps/forbic-example/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "forbic_embed", .module = embedding }},
    }) });
    check.dependOn(&executable.step);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("forbic-example", "Run the example host of the Forbic embedding API: forbic-example WORK_DIR").dependOn(&run.step);
    const work = b.tmpPath();
    var previous: ?*std.Build.Step = null;
    for ([_][]const u8{ @embedFile("tests/forbic-example/first.txt"), @embedFile("tests/forbic-example/second.txt") }) |expected| {
        const scenario_run = b.addRunArtifact(executable);
        scenario_run.addDirectoryArg(work);
        scenario_run.has_side_effects = true;
        scenario_run.expectExitCode(0);
        scenario_run.expectStdOutEqual(expected);
        scenario_run.expectStdErrEqual("");
        if (previous) |step| scenario_run.step.dependOn(step);
        previous = &scenario_run.step;
    }
    b.step("forbic-example-scenario", "Run the example host twice on one fresh directory and check its output").dependOn(previous.?);
}

/// TASK-0109, W4.6: projects (RFC-0095). The sample `examples/hello-project` checked, run, run with
/// a key, and run twice on one fresh state directory, the second run seeing the first's count; a
/// project whose second file does not compile, reported at that file with its excerpt; and a
/// directory that is no project. A project is a tree the scenario cannot list as inputs, so each
/// runs every time.
fn addProjectTests(b: *std.Build, executable: *std.Build.Step.Compile, integration: *std.Build.Step) void {
    const hello = "examples/hello-project";
    _ = projectScenario(b, executable, integration, &.{ "check", hello }, 0, "ok: 4 bindings, 20 typed nodes\n", "");
    _ = projectScenario(b, executable, integration, &.{ "run", hello }, 0, "Hello, world! (visit 0)\n{\"Greeting\":\"Hello, world!\",\"Visits\":[],\"Visit\":0,\"Shown\":[]}\n", "");
    _ = projectScenario(b, executable, integration, &.{ "run", hello, "--key", "visitor" }, 0, "Hello, world! (visit 1)\n{\"Greeting\":\"Hello, world!\",\"Visits\":[{\"$key\":\"visitor\"},{\"Count\":1}],\"Visit\":1,\"Shown\":[],\"$inputs\":{\"count\":1,\"bytes\":0}}\n", "");
    _ = projectScenario(b, executable, integration, &.{ "check", "tests/projects/hello-error", "--diagnostics=excerpt" }, 1, "", "tests/projects/hello-error/src/hello@example.com/Hello/shout.forb:2:25: error: name must refer to a parameter or earlier declaration\n  2 | Loud<public>:string = \"{Greting}!\"\n    |                         ^~~~~~~\n");
    _ = projectScenario(b, executable, integration, &.{ "run", "tests/conformance" }, 1, "", "tests/conformance: error: is not a Forbic project: it has no forbic.json naming its root module\n");
    const state = b.tmpPath();
    var previous: ?*std.Build.Step = null;
    for ([_][]const u8{
        "Hello, world! (visit 1)\n{\"Greeting\":\"Hello, world!\",\"Visits\":[{\"$key\":\"visitor\"},{\"Count\":1}],\"Visit\":1,\"Shown\":[],\"$inputs\":{\"count\":1,\"bytes\":0}}\n",
        "Hello, world! (visit 2)\n{\"Greeting\":\"Hello, world!\",\"Visits\":[{\"$key\":\"visitor\"},{\"Count\":2}],\"Visit\":2,\"Shown\":[],\"$inputs\":{\"count\":1,\"bytes\":78}}\n",
    }) |expected| {
        const run = projectScenario(b, executable, integration, &.{ "run", hello, "--key", "visitor", "--state" }, 0, expected, "");
        run.addDirectoryArg(state);
        if (previous) |step| run.step.dependOn(step);
        previous = &run.step;
    }
}

fn projectScenario(b: *std.Build, executable: *std.Build.Step.Compile, integration: *std.Build.Step, args: []const []const u8, exit_code: u8, stdout: []const u8, stderr: []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.addArgs(args);
    run.has_side_effects = true;
    run.expectExitCode(exit_code);
    run.expectStdOutEqual(stdout);
    run.expectStdErrEqual(stderr);
    integration.dependOn(&run.step);
    return run;
}

/// The conformance scenarios: the `forbic` tool at the bootstrap profile run on the fixtures in
/// `tests/conformance`, from the package root (TASK-0109, W3.3b: moved from ForbOS's
/// `addCliTests`).
fn addConformanceTests(b: *std.Build, executable: *std.Build.Step.Compile, integration: *std.Build.Step) void {
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/calls.forb" }, 0, @embedFile("tests/conformance/calls.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/frame-branches.forb" }, 0, @embedFile("tests/conformance/frame-branches.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/frame-failure.forb" }, 0, @embedFile("tests/conformance/frame-failure.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failable-frames.forb" }, 0, @embedFile("tests/conformance/failable-frames.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/transactional-frames.forb" }, 0, @embedFile("tests/conformance/transactional-frames.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/blocks.forb" }, 0, @embedFile("tests/conformance/blocks.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/locals.forb" }, 0, @embedFile("tests/conformance/locals.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/iteration.forb" }, 0, @embedFile("tests/conformance/iteration.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/recursion.forb" }, 0, @embedFile("tests/conformance/recursion.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/callables.forb" }, 0, @embedFile("tests/conformance/callables.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/callable-iteration.forb" }, 0, @embedFile("tests/conformance/callable-iteration.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/state-loops.forb" }, 0, @embedFile("tests/conformance/state-loops.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/bound-functions.forb" }, 0, @embedFile("tests/conformance/bound-functions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/anonymous-functions.forb" }, 0, @embedFile("tests/conformance/anonymous-functions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/generic-functions.forb" }, 0, @embedFile("tests/conformance/generic-functions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/effect-polymorphism.forb" }, 0, @embedFile("tests/conformance/effect-polymorphism.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-index.forb" }, 0, @embedFile("tests/conformance/array-index.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/numeric-conversions.forb" }, 0, @embedFile("tests/conformance/numeric-conversions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-std.forb" }, 0, @embedFile("tests/conformance/native-std.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/strings.forb" }, 0, @embedFile("tests/conformance/strings.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/compound-set.forb" }, 0, @embedFile("tests/conformance/compound-set.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/type-aliases.forb" }, 0, @embedFile("tests/conformance/type-aliases.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-concat.forb" }, 0, @embedFile("tests/conformance/array-concat.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/type-inference.forb" }, 0, @embedFile("tests/conformance/type-inference.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failable-conditions.forb" }, 0, @embedFile("tests/conformance/failable-conditions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/case.forb" }, 0, @embedFile("tests/conformance/case.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/field-updates.forb" }, 0, @embedFile("tests/conformance/field-updates.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-updates.forb" }, 0, @embedFile("tests/conformance/array-updates.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/interpolation.forb" }, 0, @embedFile("tests/conformance/interpolation.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/closures.forb" }, 0, @embedFile("tests/conformance/closures.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-loops.forb" }, 0, @embedFile("tests/conformance/for-loops.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/map-updates.forb" }, 0, @embedFile("tests/conformance/map-updates.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/named-arguments.forb" }, 0, @embedFile("tests/conformance/named-arguments.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/condition-bindings.forb" }, 0, @embedFile("tests/conformance/condition-bindings.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/while-loops.forb" }, 0, @embedFile("tests/conformance/while-loops.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/overloads.forb" }, 0, @embedFile("tests/conformance/overloads.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/classes.forb" }, 0, @embedFile("tests/conformance/classes.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/stdlib.forb" }, 0, @embedFile("tests/conformance/stdlib.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/alignments.forb" }, 0, @embedFile("tests/conformance/alignments.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/parametric-types.forb" }, 0, @embedFile("tests/conformance/parametric-types.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-locals.forb" }, 0, @embedFile("tests/conformance/for-locals.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/constructors.forb" }, 0, @embedFile("tests/conformance/constructors.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/class-members.forb" }, 0, @embedFile("tests/conformance/class-members.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/chars.forb" }, 0, @embedFile("tests/conformance/chars.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/early-exit.forb" }, 0, @embedFile("tests/conformance/early-exit.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failure-forms.forb" }, 0, @embedFile("tests/conformance/failure-forms.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/rational.forb" }, 0, @embedFile("tests/conformance/rational.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/case-patterns.forb" }, 0, @embedFile("tests/conformance/case-patterns.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-generators.forb" }, 0, @embedFile("tests/conformance/for-generators.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/comparable-keys.forb" }, 0, @embedFile("tests/conformance/comparable-keys.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/not-combinator.forb" }, 0, @embedFile("tests/conformance/not-combinator.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-fold.forb" }, 0, @embedFile("tests/conformance/array-fold.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/effects.forb" }, 0, @embedFile("tests/conformance/effects.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/remaining-types.forb" }, 0, @embedFile("tests/conformance/remaining-types.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/generic-methods.forb" }, 0, @embedFile("tests/conformance/generic-methods.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-effects.forb" }, 0, @embedFile("tests/conformance/native-effects.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-spawn.forb" }, 0, @embedFile("tests/conformance/concurrency-spawn.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/refinements.forb" }, 0, @embedFile("tests/conformance/refinements.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-events.forb" }, 0, @embedFile("tests/conformance/concurrency-events.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-structured.forb" }, 0, @embedFile("tests/conformance/concurrency-structured.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-branch.forb" }, 0, @embedFile("tests/conformance/concurrency-branch.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-variables.forb" }, 0, @embedFile("tests/conformance/live-variables.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-reclaim.forb" }, 0, @embedFile("tests/conformance/concurrency-reclaim.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-exit.forb" }, 0, @embedFile("tests/conformance/concurrency-exit.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-cancel.forb" }, 0, @embedFile("tests/conformance/concurrency-cancel.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-fields.forb" }, 0, @embedFile("tests/conformance/live-fields.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-function-types.forb" }, 0, @embedFile("tests/conformance/live-function-types.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-reactions.forb" }, 0, @embedFile("tests/conformance/live-reactions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-batch.forb" }, 0, @embedFile("tests/conformance/live-batch.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-await.forb" }, 0, @embedFile("tests/conformance/live-await.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-cancel.forb" }, 0, @embedFile("tests/conformance/live-cancel.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/transparent-functions.forb" }, 0, @embedFile("tests/conformance/transparent-functions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/accessors.forb" }, 0, @embedFile("tests/conformance/accessors.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-handles.forb", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-handles-log.txt" }, 0, @embedFile("tests/conformance/native-handles.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--clock", "1700000000", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-journal-log.txt" }, 0, @embedFile("tests/conformance/native-journal.json"), "");
    scenario(b, executable, integration, &.{ "journal", "show", "tests/conformance/native-journal.state" }, 0, @embedFile("tests/conformance/native-journal-show.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--state", "tests/conformance/native-recovery.state" }, 1, "", "forbic: error: state directory tests/conformance/native-recovery.state holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--seed", "5", "--state", "tests/conformance/native-recovery.state", "--resume" }, 1, "", "forbic: error: the journal in tests/conformance/native-recovery.state is of another run (recovery_mismatch): its seed differs\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-handles.forb", "--state", "tests/conformance/native-recovery.state", "--resume" }, 1, "", "forbic: error: the journal in tests/conformance/native-recovery.state is of another run (recovery_mismatch): its program differs\n");
    scenario(b, executable, integration, &.{ "journal", "show", "tests/conformance/native-recovery.state" }, 0, @embedFile("tests/conformance/native-recovery-show.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--state", ".zig-cache/native-recovery-none", "--abandon" }, 0, "", "forbic: state directory .zig-cache/native-recovery-none holds no unfinished run\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--state", "tests/conformance/native-recovery.state", "--resume", "--abandon" }, 2, "", "usage: forbic check FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR] [--bundle] | eval FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | inspect FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--bundle] | trace FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | qualify FILE [--bundle] | journal show DIR | store show DIR | fmt [--check] FILE...|- | --version\n       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal.forb", "--resume" }, 2, "", "usage: forbic check FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR] [--bundle] | eval FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | inspect FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--bundle] | trace FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | qualify FILE [--bundle] | journal show DIR | store show DIR | fmt [--check] FILE...|- | --version\n       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-journal.forb", "--abandon" }, 2, "", "usage: forbic check FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR] [--bundle] | eval FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | inspect FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--bundle] | trace FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | qualify FILE [--bundle] | journal show DIR | store show DIR | fmt [--check] FILE...|- | --version\n       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n");
    scenario(b, executable, integration, &.{ "journal", "show", ".zig-cache/native-journal-missing" }, 1, "", "forbic: error: cannot open journal .zig-cache/native-journal-missing/journal (FileNotFound)\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/shared-locals.forb" }, 0, @embedFile("tests/conformance/shared-locals.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/shared-locals-tasks.forb" }, 0, @embedFile("tests/conformance/shared-locals-tasks.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/weak-maps.forb" }, 0, @embedFile("tests/conformance/weak-maps.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/persistable-json.forb" }, 0, @embedFile("tests/conformance/persistable-json.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-for.forb" }, 0, @embedFile("tests/conformance/concurrency-for.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/weak-maps-session.forb" }, 0, @embedFile("tests/conformance/weak-maps-session.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/persistence.forb", "--key", "alice", "--key", "bob" }, 0, @embedFile("tests/conformance/persistence.json"), "");
    scenario(b, executable, integration, &.{ "store", "show", "tests/conformance/persistence.state" }, 0, @embedFile("tests/conformance/persistence-store-show.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/schema-evolution.forb", "--key", "alice" }, 0, @embedFile("tests/conformance/schema-evolution.json"), "");
    scenario(b, executable, integration, &.{ "store", "show", "tests/conformance/schema-evolution.state" }, 0, @embedFile("tests/conformance/schema-evolution-store-show.json"), "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/schema-evolution.forb", "--state", "tests/conformance/schema-evolution.state" }, 0, "ok: the schema of tests/conformance/schema-evolution.forb is compatible with the store in tests/conformance/schema-evolution.state\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/persistence.forb", "--state", "tests/conformance/persistence.state" }, 0, "ok: the schema of tests/conformance/persistence.forb is compatible with the store in tests/conformance/persistence.state, whose schema records no types: only its cells were checked\n", "");
    scenario(b, executable, integration, &.{ "journal", "show", "tests/conformance/persistence-recovery.state" }, 0, @embedFile("tests/conformance/persistence-recovery-show.json"), "");
    scenario(b, executable, integration, &.{ "store", "show", "tests/conformance/persistence-recovery.state" }, 0, @embedFile("tests/conformance/persistence-recovery-store-show.json"), "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/persistence.forb", "--state", "tests/conformance/persistence-recovery.state" }, 0, "ok: the schema of tests/conformance/persistence.forb is compatible with the store in tests/conformance/persistence-recovery.state\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/closures-complete.forb" }, 0, @embedFile("tests/conformance/closures-complete.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-locals.forb" }, 0, @embedFile("tests/conformance/live-locals.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/capture-rule.forb" }, 0, @embedFile("tests/conformance/capture-rule.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-functions.forb" }, 0, @embedFile("tests/conformance/nested-functions.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-overloads.forb" }, 0, @embedFile("tests/conformance/nested-overloads.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/accessor-initialisation.forb" }, 0, @embedFile("tests/conformance/accessor-initialisation.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/qualification.forb" }, 0, @embedFile("tests/conformance/qualification.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/enumerator-qualification.forb" }, 0, @embedFile("tests/conformance/enumerator-qualification.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/predicts.forb" }, 0, @embedFile("tests/conformance/predicts.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-inputs.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/native-inputs.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/profile.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/profile.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/frame-branches-error.forb" }, 1, "", "tests/conformance/frame-branches-error.forb:1:42: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/calls-error.forb" }, 1, "", "tests/conformance/calls-error.forb:1:27: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/string-join-reclaim-error.forb" }, 1, "", "tests/conformance/string-join-reclaim-error.forb:3:26: error: evaluation work budget exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/string-join-reclaim-error.forb", "--state", ".zig-cache/string-join-reclaim-state" }, 1, "", "tests/conformance/string-join-reclaim-error.forb:3:26: error: evaluation work budget exhausted\n");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/failure.forb" }, 0, @embedFile("tests/conformance/failure-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/frame-failure.forb" }, 0, @embedFile("tests/conformance/frame-failure-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/failable-frames.forb" }, 0, @embedFile("tests/conformance/failable-frames-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/transactional-frames.forb" }, 0, @embedFile("tests/conformance/transactional-frames-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/blocks.forb" }, 0, @embedFile("tests/conformance/blocks-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/locals.forb" }, 0, @embedFile("tests/conformance/locals-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/iteration.forb" }, 0, @embedFile("tests/conformance/iteration-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/recursion.forb" }, 0, @embedFile("tests/conformance/recursion-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/callables.forb" }, 0, @embedFile("tests/conformance/callables-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/callable-iteration.forb" }, 0, @embedFile("tests/conformance/callable-iteration-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/state-loops.forb" }, 0, @embedFile("tests/conformance/state-loops-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/bound-functions.forb" }, 0, @embedFile("tests/conformance/bound-functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/anonymous-functions.forb" }, 0, @embedFile("tests/conformance/anonymous-functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/generic-functions.forb" }, 0, @embedFile("tests/conformance/generic-functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/effect-polymorphism.forb" }, 0, @embedFile("tests/conformance/effect-polymorphism-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/array-index.forb" }, 0, @embedFile("tests/conformance/array-index-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/numeric-conversions.forb" }, 0, @embedFile("tests/conformance/numeric-conversions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-std.forb" }, 0, @embedFile("tests/conformance/native-std-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/strings.forb" }, 0, @embedFile("tests/conformance/strings-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/compound-set.forb" }, 0, @embedFile("tests/conformance/compound-set-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/type-aliases.forb" }, 0, @embedFile("tests/conformance/type-aliases-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/array-concat.forb" }, 0, @embedFile("tests/conformance/array-concat-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/type-inference.forb" }, 0, @embedFile("tests/conformance/type-inference-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/failable-conditions.forb" }, 0, @embedFile("tests/conformance/failable-conditions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/case.forb" }, 0, @embedFile("tests/conformance/case-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/field-updates.forb" }, 0, @embedFile("tests/conformance/field-updates-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/array-updates.forb" }, 0, @embedFile("tests/conformance/array-updates-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/interpolation.forb" }, 0, @embedFile("tests/conformance/interpolation-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/closures.forb" }, 0, @embedFile("tests/conformance/closures-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/for-loops.forb" }, 0, @embedFile("tests/conformance/for-loops-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/map-updates.forb" }, 0, @embedFile("tests/conformance/map-updates-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/named-arguments.forb" }, 0, @embedFile("tests/conformance/named-arguments-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/condition-bindings.forb" }, 0, @embedFile("tests/conformance/condition-bindings-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/while-loops.forb" }, 0, @embedFile("tests/conformance/while-loops-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/overloads.forb" }, 0, @embedFile("tests/conformance/overloads-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/classes.forb" }, 0, @embedFile("tests/conformance/classes-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/stdlib.forb" }, 0, @embedFile("tests/conformance/stdlib-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/alignments.forb" }, 0, @embedFile("tests/conformance/alignments-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/parametric-types.forb" }, 0, @embedFile("tests/conformance/parametric-types-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/for-locals.forb" }, 0, @embedFile("tests/conformance/for-locals-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/constructors.forb" }, 0, @embedFile("tests/conformance/constructors-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/class-members.forb" }, 0, @embedFile("tests/conformance/class-members-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/chars.forb" }, 0, @embedFile("tests/conformance/chars-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/early-exit.forb" }, 0, @embedFile("tests/conformance/early-exit-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/failure-forms.forb" }, 0, @embedFile("tests/conformance/failure-forms-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/rational.forb" }, 0, @embedFile("tests/conformance/rational-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/case-patterns.forb" }, 0, @embedFile("tests/conformance/case-patterns-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/for-generators.forb" }, 0, @embedFile("tests/conformance/for-generators-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/comparable-keys.forb" }, 0, @embedFile("tests/conformance/comparable-keys-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/not-combinator.forb" }, 0, @embedFile("tests/conformance/not-combinator-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/array-fold.forb" }, 0, @embedFile("tests/conformance/array-fold-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/effects.forb" }, 0, @embedFile("tests/conformance/effects-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/remaining-types.forb" }, 0, @embedFile("tests/conformance/remaining-types-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/generic-methods.forb" }, 0, @embedFile("tests/conformance/generic-methods-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-effects.forb" }, 0, @embedFile("tests/conformance/native-effects-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-spawn.forb" }, 0, @embedFile("tests/conformance/concurrency-spawn-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/refinements.forb" }, 0, @embedFile("tests/conformance/refinements-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-events.forb" }, 0, @embedFile("tests/conformance/concurrency-events-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-structured.forb" }, 0, @embedFile("tests/conformance/concurrency-structured-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-branch.forb" }, 0, @embedFile("tests/conformance/concurrency-branch-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-variables.forb" }, 0, @embedFile("tests/conformance/live-variables-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-reclaim.forb" }, 0, @embedFile("tests/conformance/concurrency-reclaim-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-exit.forb" }, 0, @embedFile("tests/conformance/concurrency-exit-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-cancel.forb" }, 0, @embedFile("tests/conformance/concurrency-cancel-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-fields.forb" }, 0, @embedFile("tests/conformance/live-fields-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-function-types.forb" }, 0, @embedFile("tests/conformance/live-function-types-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-reactions.forb" }, 0, @embedFile("tests/conformance/live-reactions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-batch.forb" }, 0, @embedFile("tests/conformance/live-batch-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-await.forb" }, 0, @embedFile("tests/conformance/live-await-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-cancel.forb" }, 0, @embedFile("tests/conformance/live-cancel-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/transparent-functions.forb" }, 0, @embedFile("tests/conformance/transparent-functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/accessors.forb" }, 0, @embedFile("tests/conformance/accessors-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-handles.forb", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-handles-log.txt" }, 0, @embedFile("tests/conformance/native-handles-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-journal.forb", "--clock", "1700000000", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-journal-log.txt" }, 0, @embedFile("tests/conformance/native-journal-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/shared-locals.forb" }, 0, @embedFile("tests/conformance/shared-locals-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/shared-locals-tasks.forb" }, 0, @embedFile("tests/conformance/shared-locals-tasks-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/weak-maps.forb" }, 0, @embedFile("tests/conformance/weak-maps-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/persistable-json.forb" }, 0, @embedFile("tests/conformance/persistable-json-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/concurrency-for.forb" }, 0, @embedFile("tests/conformance/concurrency-for-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/weak-maps-session.forb" }, 0, @embedFile("tests/conformance/weak-maps-session-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/persistence.forb", "--key", "alice", "--key", "bob" }, 0, @embedFile("tests/conformance/persistence-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/schema-evolution.forb", "--key", "alice" }, 0, @embedFile("tests/conformance/schema-evolution-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/closures-complete.forb" }, 0, @embedFile("tests/conformance/closures-complete-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/live-locals.forb" }, 0, @embedFile("tests/conformance/live-locals-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/capture-rule.forb" }, 0, @embedFile("tests/conformance/capture-rule-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/nested-functions.forb" }, 0, @embedFile("tests/conformance/nested-functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/nested-overloads.forb" }, 0, @embedFile("tests/conformance/nested-overloads-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/accessor-initialisation.forb" }, 0, @embedFile("tests/conformance/accessor-initialisation-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/qualification.forb" }, 0, @embedFile("tests/conformance/qualification-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/enumerator-qualification.forb" }, 0, @embedFile("tests/conformance/enumerator-qualification-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/predicts.forb" }, 0, @embedFile("tests/conformance/predicts-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/native-inputs.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/native-inputs-trace.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/profile.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/profile-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/callables.forb" }, 0, @embedFile("tests/conformance/callables-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/callable-iteration.forb" }, 0, @embedFile("tests/conformance/callable-iteration-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/state-loops.forb" }, 0, @embedFile("tests/conformance/state-loops-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/bound-functions.forb" }, 0, @embedFile("tests/conformance/bound-functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/anonymous-functions.forb" }, 0, @embedFile("tests/conformance/anonymous-functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/generic-functions.forb" }, 0, @embedFile("tests/conformance/generic-functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/effect-polymorphism.forb" }, 0, @embedFile("tests/conformance/effect-polymorphism-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/array-index.forb" }, 0, @embedFile("tests/conformance/array-index-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/numeric-conversions.forb" }, 0, @embedFile("tests/conformance/numeric-conversions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/native-std.forb" }, 0, @embedFile("tests/conformance/native-std-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/strings.forb" }, 0, @embedFile("tests/conformance/strings-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/compound-set.forb" }, 0, @embedFile("tests/conformance/compound-set-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/type-aliases.forb" }, 0, @embedFile("tests/conformance/type-aliases-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/array-concat.forb" }, 0, @embedFile("tests/conformance/array-concat-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/type-inference.forb" }, 0, @embedFile("tests/conformance/type-inference-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/failable-conditions.forb" }, 0, @embedFile("tests/conformance/failable-conditions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/case.forb" }, 0, @embedFile("tests/conformance/case-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/field-updates.forb" }, 0, @embedFile("tests/conformance/field-updates-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/array-updates.forb" }, 0, @embedFile("tests/conformance/array-updates-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/interpolation.forb" }, 0, @embedFile("tests/conformance/interpolation-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/closures.forb" }, 0, @embedFile("tests/conformance/closures-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/for-loops.forb" }, 0, @embedFile("tests/conformance/for-loops-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/map-updates.forb" }, 0, @embedFile("tests/conformance/map-updates-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/named-arguments.forb" }, 0, @embedFile("tests/conformance/named-arguments-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/condition-bindings.forb" }, 0, @embedFile("tests/conformance/condition-bindings-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/while-loops.forb" }, 0, @embedFile("tests/conformance/while-loops-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/overloads.forb" }, 0, @embedFile("tests/conformance/overloads-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/classes.forb" }, 0, @embedFile("tests/conformance/classes-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/stdlib.forb" }, 0, @embedFile("tests/conformance/stdlib-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/alignments.forb" }, 0, @embedFile("tests/conformance/alignments-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/parametric-types.forb" }, 0, @embedFile("tests/conformance/parametric-types-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/for-locals.forb" }, 0, @embedFile("tests/conformance/for-locals-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/constructors.forb" }, 0, @embedFile("tests/conformance/constructors-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/class-members.forb" }, 0, @embedFile("tests/conformance/class-members-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/chars.forb" }, 0, @embedFile("tests/conformance/chars-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/early-exit.forb" }, 0, @embedFile("tests/conformance/early-exit-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/failure-forms.forb" }, 0, @embedFile("tests/conformance/failure-forms-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/rational.forb" }, 0, @embedFile("tests/conformance/rational-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/case-patterns.forb" }, 0, @embedFile("tests/conformance/case-patterns-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/for-generators.forb" }, 0, @embedFile("tests/conformance/for-generators-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/comparable-keys.forb" }, 0, @embedFile("tests/conformance/comparable-keys-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/not-combinator.forb" }, 0, @embedFile("tests/conformance/not-combinator-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/array-fold.forb" }, 0, @embedFile("tests/conformance/array-fold-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/effects.forb" }, 0, @embedFile("tests/conformance/effects-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/remaining-types.forb" }, 0, @embedFile("tests/conformance/remaining-types-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/generic-methods.forb" }, 0, @embedFile("tests/conformance/generic-methods-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/native-effects.forb" }, 0, @embedFile("tests/conformance/native-effects-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-spawn.forb" }, 0, @embedFile("tests/conformance/concurrency-spawn-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/refinements.forb" }, 0, @embedFile("tests/conformance/refinements-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-events.forb" }, 0, @embedFile("tests/conformance/concurrency-events-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-structured.forb" }, 0, @embedFile("tests/conformance/concurrency-structured-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-branch.forb" }, 0, @embedFile("tests/conformance/concurrency-branch-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-variables.forb" }, 0, @embedFile("tests/conformance/live-variables-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-reclaim.forb" }, 0, @embedFile("tests/conformance/concurrency-reclaim-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-exit.forb" }, 0, @embedFile("tests/conformance/concurrency-exit-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-cancel.forb" }, 0, @embedFile("tests/conformance/concurrency-cancel-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-fields.forb" }, 0, @embedFile("tests/conformance/live-fields-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-function-types.forb" }, 0, @embedFile("tests/conformance/live-function-types-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-reactions.forb" }, 0, @embedFile("tests/conformance/live-reactions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-batch.forb" }, 0, @embedFile("tests/conformance/live-batch-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-await.forb" }, 0, @embedFile("tests/conformance/live-await-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-cancel.forb" }, 0, @embedFile("tests/conformance/live-cancel-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/transparent-functions.forb" }, 0, @embedFile("tests/conformance/transparent-functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/accessors.forb" }, 0, @embedFile("tests/conformance/accessors-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/native-handles.forb", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-handles-log.txt" }, 0, @embedFile("tests/conformance/native-handles-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/native-journal.forb", "--clock", "1700000000", "--read", "config=tests/conformance/native-handles.txt", "--write", "log=.zig-cache/native-journal-log.txt" }, 0, @embedFile("tests/conformance/native-journal-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/shared-locals.forb" }, 0, @embedFile("tests/conformance/shared-locals-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/shared-locals-tasks.forb" }, 0, @embedFile("tests/conformance/shared-locals-tasks-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/weak-maps.forb" }, 0, @embedFile("tests/conformance/weak-maps-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/persistable-json.forb" }, 0, @embedFile("tests/conformance/persistable-json-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/concurrency-for.forb" }, 0, @embedFile("tests/conformance/concurrency-for-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/weak-maps-session.forb" }, 0, @embedFile("tests/conformance/weak-maps-session-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/persistence.forb", "--key", "alice", "--key", "bob" }, 0, @embedFile("tests/conformance/persistence-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/schema-evolution.forb", "--key", "alice" }, 0, @embedFile("tests/conformance/schema-evolution-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/closures-complete.forb" }, 0, @embedFile("tests/conformance/closures-complete-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/live-locals.forb" }, 0, @embedFile("tests/conformance/live-locals-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/capture-rule.forb" }, 0, @embedFile("tests/conformance/capture-rule-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/nested-functions.forb" }, 0, @embedFile("tests/conformance/nested-functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/nested-overloads.forb" }, 0, @embedFile("tests/conformance/nested-overloads-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/accessor-initialisation.forb" }, 0, @embedFile("tests/conformance/accessor-initialisation-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/qualification.forb" }, 0, @embedFile("tests/conformance/qualification-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/enumerator-qualification.forb" }, 0, @embedFile("tests/conformance/enumerator-qualification-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/predicts.forb" }, 0, @embedFile("tests/conformance/predicts-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/native-inputs.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/native-inputs-inspection.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/profile.forb", "--clock", "1700000000" }, 0, @embedFile("tests/conformance/profile-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/frame-failure-error.forb" }, 1, "", "tests/conformance/frame-failure-error.forb:1:45: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failable-frames-error.forb" }, 1, "", "tests/conformance/failable-frames-error.forb:1:54: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/transactional-frames-error.forb" }, 1, "", "tests/conformance/transactional-frames-error.forb:1:130: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/blocks-error.forb" }, 1, "", "tests/conformance/blocks-error.forb:1:29: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/locals-error.forb" }, 1, "", "tests/conformance/locals-error.forb:1:39: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/iteration-error.forb" }, 1, "", "tests/conformance/iteration-error.forb:1:43: error: iteration count must be nonnegative\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/recursion-error.forb" }, 1, "", "tests/conformance/recursion-error.forb:1:35: error: runtime call depth budget exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/callables-error.forb" }, 1, "", "tests/conformance/callables-error.forb:1:25: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/callable-iteration-error.forb" }, 1, "", "tests/conformance/callable-iteration-error.forb:1:36: error: iteration count must be nonnegative\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/state-loops-error.forb" }, 1, "", "tests/conformance/state-loops-error.forb:1:59: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/bound-functions-error.forb" }, 1, "", "tests/conformance/bound-functions-error.forb:1:52: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/anonymous-functions-error.forb" }, 1, "", "tests/conformance/anonymous-functions-error.forb:1:21: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/generic-functions-error.forb" }, 1, "", "tests/conformance/generic-functions-error.forb:2:26: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/effect-polymorphism-error.forb" }, 1, "", "tests/conformance/effect-polymorphism-error.forb:2:25: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-index-error.forb" }, 1, "", "tests/conformance/array-index-error.forb:2:26: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/numeric-conversions-error.forb" }, 1, "", "tests/conformance/numeric-conversions-error.forb:2:25: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-std-error.forb" }, 1, "", "tests/conformance/native-std-error.forb:2:11: error: a native function reported a fatal error\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/strings-error.forb" }, 1, "", "tests/conformance/strings-error.forb:1:36: error: decoded string budget exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/compound-set-error.forb" }, 1, "", "tests/conformance/compound-set-error.forb:2:6: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/type-aliases-error.forb" }, 1, "", "tests/conformance/type-aliases-error.forb:2:8: error: expected a scalar, earlier record/enum, array, tuple, option, map or function type\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-concat-error.forb" }, 1, "", "tests/conformance/array-concat-error.forb:1:34: error: aggregate element storage budget exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/type-inference-error.forb" }, 1, "", "tests/conformance/type-inference-error.forb:2:12: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failable-conditions-error.forb" }, 1, "", "tests/conformance/failable-conditions-error.forb:2:24: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/case-error.forb" }, 1, "", "tests/conformance/case-error.forb:2:53: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/field-updates-error.forb" }, 1, "", "tests/conformance/field-updates-error.forb:3:8: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-updates-error.forb" }, 1, "", "tests/conformance/array-updates-error.forb:2:36: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/interpolation-error.forb" }, 1, "", "tests/conformance/interpolation-error.forb:2:26: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/closures-error.forb" }, 1, "", "tests/conformance/closures-error.forb:1:59: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-loops-error.forb" }, 1, "", "tests/conformance/for-loops-error.forb:2:34: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/map-updates-error.forb" }, 1, "", "tests/conformance/map-updates-error.forb:2:42: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/named-arguments-error.forb" }, 1, "", "tests/conformance/named-arguments-error.forb:1:42: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/condition-bindings-error.forb" }, 1, "", "tests/conformance/condition-bindings-error.forb:2:35: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/while-loops-error.forb" }, 1, "", "tests/conformance/while-loops-error.forb:2:70: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/overloads-error.forb" }, 1, "", "tests/conformance/overloads-error.forb:2:32: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/classes-error.forb" }, 1, "", "tests/conformance/classes-error.forb:3:45: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/stdlib-error.forb" }, 1, "", "tests/conformance/stdlib-error.forb:3:27: error: i64 arithmetic overflow\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/alignments-error.forb" }, 1, "", "tests/conformance/alignments-error.forb:2:6: error: this name is already visible here and may not be shadowed: choose another name (first declared at 1:1)\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/parametric-types-error.forb" }, 1, "", "tests/conformance/parametric-types-error.forb:4:10: error: this type argument is not a subtype of the bound its parameter declares\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-locals-error.forb" }, 1, "", "tests/conformance/for-locals-error.forb:2:50: error: write target must be a declared mutable binding\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/constructors-error.forb" }, 1, "", "tests/conformance/constructors-error.forb:4:12: error: an archetype delegates once, to a constructor function of its class or of a superclass\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/class-members-error.forb" }, 1, "", "tests/conformance/class-members-error.forb:3:53: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/chars-error.forb" }, 1, "", "tests/conformance/chars-error.forb:2:20: error: a character literal is one character or escape in single quotes, 0oXX for a code unit or 0uXXXXXX for a Unicode scalar value\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/early-exit-error.forb" }, 1, "", "tests/conformance/early-exit-error.forb:2:69: error: Err ended the run\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failure-forms-error.forb" }, 1, "", "tests/conformance/failure-forms-error.forb:2:46: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/rational-error.forb" }, 1, "", "tests/conformance/rational-error.forb:2:19: error: i64 arithmetic overflow\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/case-patterns-error.forb" }, 1, "", "tests/conformance/case-patterns-error.forb:2:65: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/for-generators-error.forb" }, 1, "", "tests/conformance/for-generators-error.forb:2:44: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/comparable-keys-error.forb" }, 1, "", "tests/conformance/comparable-keys-error.forb:2:48: error: map constructor contains an equal key more than once\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/not-combinator-error.forb" }, 1, "", "tests/conformance/not-combinator-error.forb:2:53: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/array-fold-error.forb" }, 1, "", "tests/conformance/array-fold-error.forb:2:42: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/effects-error.forb" }, 1, "", "tests/conformance/effects-error.forb:3:29: error: `set` requires <writes>\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/remaining-types-error.forb" }, 1, "", "tests/conformance/remaining-types-error.forb:2:74: error: no value selects this Case arm: an arm before it is written the same and takes whatever it would\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/generic-methods-error.forb" }, 1, "", "tests/conformance/generic-methods-error.forb:6:5: error: a generic method has no dispatch slot: its body is written in braces, as a generic function's, and it is not abstract, overrides nothing and nothing overrides it\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-effects-error.forb" }, 1, "committed before the error\n", "tests/conformance/native-effects-error.forb:2:71: error: i64 arithmetic overflow\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-spawn-error.forb" }, 1, "", "tests/conformance/concurrency-spawn-error.forb:2:12: error: this call requires <suspends>: a <suspends> function is called only from a <suspends> function\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/refinements-error.forb" }, 1, "", "tests/conformance/refinements-error.forb:3:41: error: a refinement is type{_X:i64 where ...} or type{_X:float where ...}: each constraint compares the placeholder with a literal of the base type (an integer; a float with a point, Inf or -Inf, never NaN) by <, <=, > or >=, with at most one bound on each side and some value between them\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-events-error.forb" }, 1, "", "tests/conformance/concurrency-events-error.forb:2:30: error: this call requires <suspends>: a <suspends> function is called only from a <suspends> function\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-subscribe-error.forb" }, 1, "", "tests/conformance/concurrency-subscribe-error.forb:2:34: error: this call requires <reads> and <allocates>: what it calls reads mutable state and constructs class instances\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-structured-error.forb" }, 1, "", "tests/conformance/concurrency-structured-error.forb:2:48: error: Sync waits for at least two arms that can suspend: an arm that never waits is code to write before or after it\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-branch-error.forb" }, 1, "", "tests/conformance/concurrency-branch-error.forb:2:44: error: Rush and Branch cannot stand in the body of a Loop{} or a While, whose visits are not the function's frame: write them in a function the loop calls\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-variables-error.forb" }, 1, "", "tests/conformance/live-variables-error.forb:4:5: error: a live variable declared with live is never set by the program: only its guard gives it a value\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-reclaim-error.forb" }, 1, "", "tests/conformance/concurrency-reclaim-error.forb:8:67: error: object storage exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-exit-error.forb" }, 1, "", "tests/conformance/concurrency-exit-error.forb:2:63: error: Return and Break cannot leave the body of a Spawn or a Branch: a task has no caller to return to\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-cancel-error.forb" }, 1, "", "tests/conformance/concurrency-cancel-error.forb:2:40: error: this call requires <suspends>: a <suspends> function is called only from a <suspends> function\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-fields-error.forb" }, 1, "", "tests/conformance/live-fields-error.forb:5:7: error: a live variable declared with live is never set by the program: only its guard gives it a value\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-function-types-error.forb" }, 1, "", "tests/conformance/live-function-types-error.forb:4:7: error: a function used as a type is a function's name or an instance's method, of one parameter, that reads at most: not a call, not a value, and without <decides>, <suspends>, <writes> or <allocates>\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-reactions-error.forb" }, 1, "", "tests/conformance/live-reactions-error.forb:5:36: error: the body of an Upon or a When runs at once when its guard succeeds and cannot suspend: start a task with Spawn{...} in it to wait\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-batch-error.forb" }, 1, "", "tests/conformance/live-batch-error.forb:4:35: error: the body of a Batch holds notifications back until it ends and cannot suspend: start a task with Spawn{...} in it to wait\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-await-error.forb" }, 1, "", "tests/conformance/live-await-error.forb:4:15: error: this call requires <suspends>: a <suspends> function is called only from a <suspends> function\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-cancel-error.forb" }, 1, "", "tests/conformance/live-cancel-error.forb:6:37: error: the body of an Upon or a When runs at once when its guard succeeds and cannot suspend: start a task with Spawn{...} in it to wait\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/transparent-functions-error.forb" }, 1, "", "tests/conformance/transparent-functions-error.forb:3:37: error: a transparent function takes its result type from its body, so its body cannot name the function itself: write the result type, Name(...)<effects>:Type = ...\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/accessors-error.forb" }, 1, "", "tests/conformance/accessors-error.forb:4:43: error: runtime call depth budget exhausted\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-handles-error.forb" }, 1, "", "tests/conformance/native-handles-error.forb:1:41: error: this call requires <writes> and <allocates>: what it calls writes mutable state and constructs class instances\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-journal-error.forb" }, 1, "", "tests/conformance/native-journal-error.forb:1:31: error: this call requires <reads> and <allocates>: what it calls reads mutable state and constructs class instances\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/shared-locals-error.forb" }, 1, "", "tests/conformance/shared-locals-error.forb:2:93: error: this local var is shared with a closure that names it, so other code can change it: reading it needs <reads>, as reading any var does\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/shared-locals-tasks-error.forb" }, 1, "", "tests/conformance/shared-locals-tasks-error.forb:2:76: error: the body of a Spawn or a Branch and an arm of Sync, Race or Rush capture the parameters and immutable locals around them by value and cannot assign them; a local var they assign is shared\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/weak-maps-error.forb" }, 1, "", "tests/conformance/weak-maps-error.forb:3:11: error: a weak_map can only be looked up and set one key at a time: it has no Length, no iteration, no equality and no conversion back to a map, and it cannot be a map key, comparable or joined with ConcatenateMaps\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/persistable-json-error.forb" }, 1, "", "tests/conformance/persistable-json-error.forb:2:1: error: a <persistable> class is <final>: saved data names its class, so no subclass can stand for it\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-for-error.forb" }, 1, "", "tests/conformance/concurrency-for-error.forb:3:46: error: the body of this For suspends, so an iteration has no rollback region: none of its generators, filters, bindings or body may fail, and this one can\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/weak-maps-session-error.forb" }, 1, "", "tests/conformance/weak-maps-session-error.forb:3:31: error: a module var of type weak_map(session, V) is a keyed cell: it can neither be read nor replaced whole, only looked up as X[K] and set as set X[K] = V\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/schema-evolution-error.forb", "--state", "tests/conformance/schema-evolution.state" }, 1, "", "tests/conformance/schema-evolution-error.forb:1:1: error: the program is incompatible with the store's schema: persistent cell :Best removed: the store holds its entries\ntests/conformance/schema-evolution-error.forb:6:1: error: the program is incompatible with the store's schema: open enum mode is now closed\ntests/conformance/schema-evolution-error.forb:7:1: error: the program is incompatible with the store's schema: field Level of class profile removed: the store's entries hold it\ntests/conformance/schema-evolution-error.forb:8:5: error: the program is incompatible with the store's schema: the default of field Title of class profile changed from \"\" to \"Rookie\"\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/persistence-error.forb" }, 1, "", "tests/conformance/persistence-error.forb:2:5: error: a persistent cell's value type is persistable: logic, i64, float, string, char, char32, arrays, options, tuples and maps of persistable types, and <persistable> structs, classes and enums\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/lexical.forb" }, 0, @embedFile("tests/conformance/lexical.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/lexical.forb" }, 0, @embedFile("tests/conformance/lexical-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/lexical.forb" }, 0, @embedFile("tests/conformance/lexical-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/lexical-error.forb" }, 1, "", "tests/conformance/lexical-error.forb:2:1: error: a block comment opened with <# must close with #> before the end of the source\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/text.forb" }, 0, @embedFile("tests/conformance/text.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/text.forb" }, 0, @embedFile("tests/conformance/text-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/text.forb" }, 0, @embedFile("tests/conformance/text-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/text-error.forb" }, 1, "", "tests/conformance/text-error.forb:2:1: error: a ToString the program declares takes one value of a type with no built-in text and returns a string that does not fail: ToString(Value:Point):string\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/control-flow.forb" }, 0, @embedFile("tests/conformance/control-flow.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/control-flow.forb" }, 0, @embedFile("tests/conformance/control-flow-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/control-flow.forb" }, 0, @embedFile("tests/conformance/control-flow-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/control-flow-error.forb" }, 1, "", "tests/conformance/control-flow-error.forb:2:19: error: an If without an else has no value: it stands as a statement, or give it an else, If(Condition, Then, Else)\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/functions.forb" }, 0, @embedFile("tests/conformance/functions.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/functions.forb" }, 0, @embedFile("tests/conformance/functions-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/functions.forb" }, 0, @embedFile("tests/conformance/functions-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/functions-error.forb" }, 1, "", "tests/conformance/functions-error.forb:1:39: error: Err ended the run\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/classes-complete.forb" }, 0, @embedFile("tests/conformance/classes-complete.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/classes-complete.forb" }, 0, @embedFile("tests/conformance/classes-complete-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/classes-complete.forb" }, 0, @embedFile("tests/conformance/classes-complete-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/classes-complete-error.forb" }, 1, "", "tests/conformance/classes-complete-error.forb:5:27: error: an override keeps the parameter types of the method it replaces; its result and its access may only stay or narrow\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/book-tightening.forb" }, 0, @embedFile("tests/conformance/book-tightening.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/book-tightening.forb" }, 0, @embedFile("tests/conformance/book-tightening-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/book-tightening.forb" }, 0, @embedFile("tests/conformance/book-tightening-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/book-tightening-error.forb" }, 1, "", "tests/conformance/book-tightening-error.forb:2:6: error: _ is the wildcard of a Case pattern and names nothing else: give the declaration, parameter or field a name\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/live-locals-error.forb" }, 1, "", "tests/conformance/live-locals-error.forb:4:14: error: a live local's type has no default value for its cell to hold before its guard gives it one: a class, a function, any, a task, an event, rational or a refinement\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/capture-rule-error.forb" }, 1, "", "tests/conformance/capture-rule-error.forb:2:66: error: this local var is shared with a closure that names it, so other code can change it: reading it needs <reads>, as reading any var does\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-functions-error.forb" }, 1, "", "tests/conformance/nested-functions-error.forb:3:10: error: a nested function is private to the function that declares it, so it takes no access specifier\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-overloads-error.forb" }, 1, "", "tests/conformance/nested-overloads-error.forb:4:26: error: a default of a nested function reads what a top-level function's default reads: literals, module declarations and the parameters before it, not the locals or parameters of the code around it\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/accessor-initialisation-error.forb" }, 1, "", "tests/conformance/accessor-initialisation-error.forb:8:6: error: record constructor must supply every field\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/qualification-error.forb" }, 1, "", "tests/conformance/qualification-error.forb:3:14: error: expected a value expression\n");
    scenario(b, executable, integration, &.{ "qualify", "tests/conformance/qualification.forb" }, 0, @embedFile("tests/conformance/qualification-qualified.txt"), "");
    scenario(b, executable, integration, &.{ "qualify", "tests/conformance/nested-modules.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/nested-modules-qualified.txt"), "");
    scenario(b, executable, integration, &.{ "qualify", "tests/conformance/qualification-error.forb" }, 1, "", "tests/conformance/qualification-error.forb:3:14: error: expected a value expression\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/enumerator-qualification-error.forb" }, 1, "", "tests/conformance/enumerator-qualification-error.forb:3:17: error: a qualifier is (local:) before a local or a parameter of a function, (Module:) before a name that the module declares, or (e:) before an enumerator of the enum e\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/predicts-error.forb" }, 1, "", "tests/conformance/predicts-error.forb:3:44: error: a <predicts> function can only call <predicts> functions: this one dictates, as every function does that does not say <predicts>\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/native-inputs-error.forb" }, 1, "", "tests/conformance/native-inputs-error.forb:1:22: error: this call requires <writes> and <allocates>: what it calls writes mutable state and constructs class instances\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/profile-error.forb" }, 1, "", "tests/conformance/profile-error.forb:1:19: error: this call requires <transacts>: what it calls reads, writes and allocates\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failure-error.forb" }, 1, "", "tests/conformance/failure-error.forb:1:16: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/mutation.forb" }, 0, @embedFile("tests/conformance/mutation.json"), "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/mutation-error.forb" }, 1, "", "tests/conformance/mutation-error.forb:2:21: error: reading a `var` requires <reads>\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/failure.forb" }, 0, @embedFile("tests/conformance/failure.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/predicates.forb" }, 0, "{\"Enabled\":true,\"NaNEqual\":true,\"NaNOrdered\":false,\"ZeroEqual\":true,\"TextEqual\":true}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/predicates-error.forb" }, 1, "", "tests/conformance/predicates-error.forb:1:21: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/modules.bundle.json", "--bundle" }, 0, "{\"Config\":{\"gap\":6,\"master\":55},\"Gap\":6,\"Master\":55,\"Tone\":\"theme/settings.forb::mode.dark\",\"Accent\":\"#7e9cd8\"}\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/modules-error.bundle.json", "--bundle" }, 1, "", "theme/settings.forb:2:32: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-modules.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/nested-modules.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/nested-modules.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/nested-modules-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/nested-modules.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/nested-modules-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-modules-error.bundle.json", "--bundle" }, 1, "", "main.forb:3:33: error: imported declaration is private\n");
    scenario(b, executable, integration, &.{ "qualify", "tests/conformance/module-paths.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/module-paths-qualified.txt"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/module-paths.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/module-paths.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/module-paths.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/module-paths-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/module-paths.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/module-paths-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/module-paths-error.bundle.json", "--bundle" }, 1, "", "user@example.com/App/report.forb:2:7: error: module path is absent from the supplied inventory\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/module-paths-nested-error.bundle.json", "--bundle" }, 1, "", "user@example.com/Lib/lib.forb:2:1: error: name is already defined in this scope\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/persistable-json-folders.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/persistable-json-folders.json"), "");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/persistable-json-folders.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/persistable-json-folders-trace.json"), "");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/persistable-json-folders.bundle.json", "--bundle" }, 0, @embedFile("tests/conformance/persistable-json-folders-inspection.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/collections.forb" }, 0, "{\"Config\":{\"Layout\":[\"gap\",[6],\"master\",[55],\"missing\",[]],\"Colors\":[\"accent\",\"#7e9cd8\",\"background\",\"#1f1f28\"]},\"Gap\":6,\"Master\":55,\"Absent\":[],\"Accent\":\"#7e9cd8\",\"HasGap\":true}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/collections-error.forb" }, 1, "", "tests/conformance/collections-error.forb:1:26: error: map constructor contains an equal key more than once\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/tuples.forb" }, 0, "{\"Desktop\":{\"Pair\":[[],[6,\"Traverse\"]]},\"Gap\":6,\"Label\":\"Traverse\",\"Unit\":[]}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/tuples-error.forb" }, 1, "", "tests/conformance/tuples-error.forb:2:16: error: tuple position is outside its element range\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/defaults.forb" }, 0, "{\"Default\":{\"Theme\":{\"Accent\":\"#7e9cd8\",\"Opacity\":0.7},\"Labels\":[]},\"Custom\":{\"Theme\":{\"Accent\":\"#7e9cd8\",\"Opacity\":0.9},\"Labels\":[\"Traverse\"]},\"Safe\":{\"X\":42}}\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/defaults-runtime-error.forb" }, 1, "", "tests/conformance/defaults-runtime-error.forb:1:18: error: division by zero\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/enums.forb" }, 0, "{\"Desktop\":{\"Mode\":\"mode.Dark\",\"Allowed\":[\"mode.Light\",\"mode.Dark\"]},\"Selected\":\"mode.Light\",\"Unused\":[]}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/enums-error.forb" }, 1, "", "tests/conformance/enums-error.forb:3:16: error: expression type does not match the required type\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/aggregates.forb" }, 0, "{\"Items\":[{\"X\":7,\"Y\":8},{\"X\":0,\"Y\":0}],\"Count\":2,\"Empty\":[[],[\"snow: 雪\"]]}\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/float.forb" }, 0, "{\"Ratio\":0.55,\"Positive\":\"Inf\",\"Negative\":\"-Inf\",\"Invalid\":\"NaN\",\"Zero\":-0,\"Rounded\":0}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/float-type-error.forb" }, 1, "", "tests/conformance/float-type-error.forb:1:19: error: expression type does not match the required type\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/basic.forb" }, 0, "{\"A\":14,\"Text\":\"snow: 雪\",\"Enabled\":true}\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/overflow.forb" }, 1, "", "tests/conformance/overflow.forb:1:29: error: i64 arithmetic overflow\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/type-error.forb" }, 1, "", "tests/conformance/type-error.forb:1:9: error: expression type does not match the required type\n");
    // TASK-0109, W4.5: `forbic fmt --check` leaves files as they are; formatting-unformatted.forb formats to formatting.forb (src/forbic/format_corpus_tests.zig).
    scenario(b, executable, integration, &.{ "fmt", "--check", "tests/conformance/formatting.forb" }, 0, "", "");
    scenario(b, executable, integration, &.{ "fmt", "--check", "tests/conformance/formatting-unformatted.forb", "tests/conformance/formatting.forb" }, 1, "tests/conformance/formatting-unformatted.forb\n", "");
    scenario(b, executable, integration, &.{ "fmt", "--check", "tests/conformance/formatting-error.forb" }, 1, "", "tests/conformance/formatting-error.forb:2:19: error: string must close before the end of the line\n");
    scenario(b, executable, integration, &.{ "fmt", "--check", "tests/conformance/formatting-comments.forb" }, 0, "", "");
    scenario(b, executable, integration, &.{ "fmt", "--check", "tests/conformance/formatting-comments-unformatted.forb", "tests/conformance/formatting-comments.forb" }, 1, "tests/conformance/formatting-comments-unformatted.forb\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/formatting-comments.forb" }, 0, "{\"Base\":42,\"Wide\":3,\"Total\":83,\"Text\":\"a <# kept #> b # kept 42\",\"Last\":1}\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/formatting.forb" }, 0, "{\"Base\":40,\"Count\":40,\"Prices\":[1,10,2,20],\"Keys\":[1,2],\"Each\":[-1,-2,-3],\"Total\":89,\"Text\":\"base 42, total small\",\"Choice\":42}\n", "");
    scenario(b, executable, integration, &.{"unsupported"}, 2, "", "usage: forbic check FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR] [--bundle] | eval FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | inspect FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--bundle] | trace FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | qualify FILE [--bundle] | journal show DIR | store show DIR | fmt [--check] FILE...|- | --version\n       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/native-journal.forb", "--state", ".zig-cache/native-journal-check" }, 0, "ok: tests/conformance/native-journal.forb has no persistent cell: the store in .zig-cache/native-journal-check is not used\n", "");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/concurrency-spawn.forb", "--tick-rate", "1000000", "--seed", "1" }, 0, "ok: 5 bindings, 21 typed nodes\n", "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/concurrency-spawn.forb", "--tick-rate", "0" }, 2, "", "error: invalid or out-of-range numeric argument\n");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/inspection-runtime-error.forb" }, 0, @embedFile("tests/conformance/inspection-runtime-error.json"), "");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/inspection-runtime-error.forb" }, 1, "", "tests/conformance/inspection-runtime-error.forb:1:10: error: division by zero\n");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/type-error.forb" }, 1, "", "tests/conformance/type-error.forb:1:9: error: expression type does not match the required type\n");
    // TASK-0109, W4.2 (RFC-0088, D1): `--diagnostics=excerpt` adds the source under the header, which does not change;
    // `plain` is the default and the form of every golden above; a value that is neither is refused.
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/alignments-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/alignments-error.forb:2:6: error: this name is already visible here and may not be shadowed: choose another name (first declared at 1:1)\n  2 | Next(Count:i64)<computes>:i64=Count+1\n    |      ^~~~~\nnote: first declared here\n  1 | Count:i64=0\n    | ^~~~~\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/calls-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/calls-error.forb:1:27: error: division by zero\n  1 | Bad(N:i64)<computes>:i64=1/N\n    |                           ^\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/calls-error.forb", "--diagnostics=plain" }, 1, "", "tests/conformance/calls-error.forb:1:27: error: division by zero\n");
    scenario(b, executable, integration, &.{ "trace", "tests/conformance/calls-error.forb", "--seed", "3", "--diagnostics=excerpt" }, 1, "", "tests/conformance/calls-error.forb:1:27: error: division by zero\n  1 | Bad(N:i64)<computes>:i64=1/N\n    |                           ^\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/excerpt-tabs-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/excerpt-tabs-error.forb:2:40: error: name must refer to a parameter or earlier declaration\n  2 | Pair:tuple(string,i64)= tuple{\"héllo\",Unknown}\n    |                                       ^~~~~~~\n");
    scenario(b, executable, integration, &.{ "qualify", "tests/conformance/excerpt-tabs-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/excerpt-tabs-error.forb:2:40: error: name must refer to a parameter or earlier declaration\n  2 | Pair:tuple(string,i64)= tuple{\"héllo\",Unknown}\n    |                                       ^~~~~~~\n");
    scenario(b, executable, integration, &.{ "inspect", "tests/conformance/type-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/type-error.forb:1:9: error: expression type does not match the required type\n  1 | A:i64 = \"text\"\n    |         ^~~~~~\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/excerpt-eof-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/excerpt-eof-error.forb:4:1: error: unmatched parenthesis\n  4 |\n    | ^\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/excerpt-generated-error.forb", "--diagnostics=excerpt" }, 1, "", "tests/conformance/excerpt-generated-error.forb:2:28: error: division by zero\n  2 | A<public>:[]i64=For(X:Xs,10/X)\n    |                            ^\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/modules-error.bundle.json", "--diagnostics=excerpt", "--bundle" }, 1, "", "theme/settings.forb:2:32: error: division by zero\n  2 | Fault<public>()<computes>:i64=1/0\n    |                                ^\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/nested-modules-error.bundle.json", "--diagnostics=excerpt", "--bundle" }, 1, "", "main.forb:3:33: error: imported declaration is private\n  3 | Secret<public>:i64=Kit.Geometry.Private.Secret\n    |                                 ^~~~~~~\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/excerpt-crlf-error.bundle.json", "--diagnostics=excerpt", "--bundle" }, 1, "", "main.forb:2:15: error: expression type does not match the required type\n  2 | B:i64=Base.One+true\n    |               ^\n");
    scenario(b, executable, integration, &.{ "eval", "tests/conformance/calls-error.forb", "--diagnostics=full" }, 2, "", "error: --diagnostics takes plain or excerpt\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/type-error.forb", "--diagnostics=" }, 2, "", "error: --diagnostics takes plain or excerpt\n");
    scenario(b, executable, integration, &.{ "check", "tests/conformance/schema-evolution-error.forb", "--state", "tests/conformance/schema-evolution.state", "--diagnostics=excerpt" }, 1, "", "tests/conformance/schema-evolution-error.forb:1:1: error: the program is incompatible with the store's schema: persistent cell :Best removed: the store holds its entries\n  1 | # RFC-0087, P5.6 (G3): a version of schema-evolution-before.forb that the store it wrote refuses,\n    | ^\ntests/conformance/schema-evolution-error.forb:6:1: error: the program is incompatible with the store's schema: open enum mode is now closed\n  6 | mode<public> := enum<persistable><closed>{Easy, Normal}\n    | ^~~~\ntests/conformance/schema-evolution-error.forb:7:1: error: the program is incompatible with the store's schema: field Level of class profile removed: the store's entries hold it\n  7 | profile<public> := class<final><persistable>{\n    | ^~~~~~~\ntests/conformance/schema-evolution-error.forb:8:5: error: the program is incompatible with the store's schema: the default of field Title of class profile changed from \"\" to \"Rookie\"\n  8 |     Title:string = \"Rookie\"\n    |     ^~~~~\n");
}

fn scenario(b: *std.Build, executable: *std.Build.Step.Compile, integration: *std.Build.Step, args: []const []const u8, exit_code: u8, stdout: []const u8, stderr: []const u8) void {
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.addArgs(args);
    for (args) |arg| if (std.mem.endsWith(u8, arg, ".forb") or std.mem.endsWith(u8, arg, ".json")) run.addFileInput(b.path(arg));
    run.expectExitCode(exit_code);
    run.expectStdOutEqual(stdout);
    run.expectStdErrEqual(stderr);
    integration.dependOn(&run.step);
}
