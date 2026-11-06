//! TASK-0109, W3.2a: the Forbic host services: the `forbic` command line, and the services it
//! is built on, which take an options struct instead of argv (`execute`), so that another host
//! can load, compile, run and report a program without manufacturing a command line. This file
//! and the tooling files it imports reach nothing of ForbOS: see `forbic_host_boundary.zig`.
const std = @import("std");
const forbic = @import("forbic");
const input = @import("input.zig");
const stdio = @import("output.zig");
const journal = @import("journal.zig");
const format_command = @import("format_command.zig");
const host_store = @import("storage.zig");
const project = @import("project.zig");

/// TASK-0109, W4.2 (RFC-0088, D1): whether a diagnostic is the header alone or is followed by its
/// source; W4.4: one request's, given to every report of a diagnostic, with the code of the last
/// diagnostic reported, which a host reads as a value instead of parsing the text.
pub const Reporting = struct {
    style: forbic.excerpt.Style = .plain,
    code: ?forbic.types.Diagnostic.Code = null,
    /// TASK-0109, W4.6: a project's, so that a diagnostic in one of its files names the file as
    /// it is on disk (`DIR/src/` and its path in the tree) instead of by its path in the tree.
    tree: ?Tree = null,

    pub const Tree = struct {
        /// The project directory as the request names it.
        directory: []const u8,
        /// The request's `file`: a report that falls back to it names the project, not a file.
        file: []const u8,
    };
};

/// The `forbic` tool: its command line, its standard output and error, and its exit status.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    // `output.standard` describes a pipe opened for asynchronous I/O truthfully, and `conclude`
    // ends the tool quietly when its reader has gone: see `output.zig`.
    var stdout: std.Io.File.Writer = .init(stdio.standard(.stdout), init.io, &stdout_buffer);
    var stderr: std.Io.File.Writer = .init(stdio.standard(.stderr), init.io, &stderr_buffer);
    const status = try stdio.conclude(dispatch(init, args, &stdout.interface, &stderr.interface), .of(&stdout), .of(&stderr));
    if (status != 0) std.process.exit(status);
}

/// The `forbic` command line: parses `raw_args` into a `Request` and executes it.
pub fn dispatch(init: std.process.Init, raw_args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const bundled = raw_args.len >= 4 and std.mem.eql(u8, raw_args[raw_args.len - 1], "--bundle");
    // RFC-0086, P2.4: `forbic journal show DIR`, which runs nothing and takes no option.
    if (raw_args.len >= 2 and std.mem.eql(u8, raw_args[1], "journal")) {
        if (raw_args.len != 4 or bundled or !std.mem.eql(u8, raw_args[2], "show")) return usage(err);
        return journal.show(init.io, init.arena.allocator(), raw_args[3], out, err);
    }
    // RFC-0087, P5.5: `forbic store show DIR`, which runs nothing and takes no option.
    if (raw_args.len >= 2 and std.mem.eql(u8, raw_args[1], "store")) {
        if (raw_args.len != 4 or bundled or !std.mem.eql(u8, raw_args[2], "show")) return usage(err);
        return host_store.show(init.io, init.gpa, raw_args[3], out, err);
    }
    // TASK-0109, W4.5: `forbic fmt [--check] FILE...` and `forbic fmt -`, which run nothing and
    // take none of the run options.
    if (raw_args.len >= 2 and std.mem.eql(u8, raw_args[1], "fmt")) return format_command.run(init.io, raw_args[2..], out, err, forbicUsage);
    var args = if (bundled) raw_args[0 .. raw_args.len - 1] else raw_args;
    // `forbic COMMAND FILE --seed N`: the seed of the run's random stream (RFC-0079). Without
    // it every run of a program draws the same values.
    var seed: u64 = forbic.effects.default_seed;
    var tick_rate: u64 = forbic.types.Scheduler.default_tick_rate;
    var clock: ?f64 = null;
    // RFC-0086, P2.4: `--state DIR`, and `--seed random`.
    var state: ?[]const u8 = null;
    var random_seed = false;
    // RFC-0086, P2.5: `--resume` and `--abandon`, and which run options were named (R3).
    var journaling: Journaling = .{};
    // RFC-0085, I11: `qualify` runs nothing, so it takes no run option.
    var run_options = false;
    // The style belongs to one command: a command that takes no option reports in plain.
    var diagnostics: forbic.excerpt.Style = .plain;
    // RFC-0086, P2.3: the grants of `--read` and `--write`, a list the host keeps for the run.
    const grants = try forbic.scratch.storage(Grants);
    defer forbic.scratch.release(grants);
    forbic.scratch.initialise(grants);
    {
        const options = parseOptions(args, grants) catch |problem| return switch (problem) {
            error.BadNumber => badNumber(err),
            error.BadGrant => badGrant(err),
            error.TooManyGrants => tooManyGrants(err),
            error.BadDiagnostics => badDiagnostics(err),
        };
        seed = options.seed;
        tick_rate = options.tick_rate;
        clock = options.clock;
        run_options = options.args.len + @intFromBool(options.styled) != args.len;
        args = options.args;
        state = options.state;
        random_seed = options.random_seed;
        diagnostics = options.diagnostics;
        journaling = .{ .intent = if (options.resume_run) .resume_run else if (options.abandon) .abandon else .start, .seed_given = options.seed_given, .tick_rate_given = options.tick_rate_given, .random_seed = random_seed };
        if (random_seed) {
            var entropy: [8]u8 = undefined;
            init.io.random(&entropy);
            seed = std.mem.readInt(u64, &entropy, .little);
        }
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try out.writeAll("forbic 0.0.1 (Forbic pure-core prototype; Zig 0.17.0)\n");
        return 0;
    }
    if (bundled and args.len < 3) return usage(err);
    if (args.len < 3 or args.len > 6) return usage(err);
    // TASK-0109, W4.6: `run` is `eval` by another name, the one a project is run by.
    const command = if (std.mem.eql(u8, args[1], "run")) "eval" else args[1];
    const valid = std.mem.eql(u8, command, "check") or std.mem.eql(u8, command, "eval") or std.mem.eql(u8, command, "inspect") or std.mem.eql(u8, command, "trace") or (std.mem.eql(u8, command, "qualify") and !run_options);
    if (!valid or args.len != 3) return usage(err);
    // A source is a file: `-` is not standard input here, and a file of that name is `./-`.
    if (std.mem.eql(u8, args[2], "-")) return badSource(err);
    // TASK-0109, W4.6 (RFC-0095): a FILE that is a directory is a project. The path is the user's
    // own, so a link to a directory counts; what is inside the project follows none. A path that
    // cannot be examined is left to be read as a file, which reports why.
    const in_project = !bundled and if (std.Io.Dir.cwd().statFile(init.io, args[2], .{})) |stat| stat.kind == .directory else |_| false;
    // A journal is kept by the commands that run a program and show what it did (RFC-0086); `check`
    // takes a state directory to try the schema check against its store, and runs nothing (RFC-0087,
    // P5.6).
    const trying = std.mem.eql(u8, command, "check") and journaling.intent == .start;
    if (state != null and !trying and !std.mem.eql(u8, command, "eval") and !std.mem.eql(u8, command, "trace")) return usage(err);
    // RFC-0086, P2.5: `--resume` and `--abandon` are of a state directory, and exclude each other.
    if (journaling.intent != .start and state == null) return usage(err);
    // A seed the host drew is shown, so that the run can be repeated; `inspect` runs nothing, and
    // neither does `--abandon`.
    if (random_seed and !std.mem.eql(u8, command, "inspect") and journaling.intent != .abandon) try err.print("forbic: seed {d}\n", .{seed});
    // `valid` admits these five words only.
    const named: Command = if (std.mem.eql(u8, command, "check")) .check else if (std.mem.eql(u8, command, "eval")) .eval else if (std.mem.eql(u8, command, "inspect")) .inspect else if (std.mem.eql(u8, command, "trace")) .trace else .qualify;
    return execute(init, .{
        .command = named,
        .file = args[2],
        .bundled = bundled,
        .seed = seed,
        .tick_rate = tick_rate,
        .clock = clock,
        .grants = .{ .list = grants.slice(), .paths = grants.paths[0..grants.count] },
        .state = state,
        .journaling = journaling,
        .diagnostics = diagnostics,
        .project = in_project,
    }, out, err);
}

/// TASK-0109, W3.2a: what `execute` does with the program it compiled: one of the commands of the
/// `forbic` tool, which reports on `out` and `err` as the tool does, or `run`, which runs it as
/// `check` does and hands its execution to the host instead of reporting it.
pub const Command = union(enum) {
    check,
    eval,
    inspect,
    trace,
    qualify,
    run: Consumer,
};

/// TASK-0109, W3.2a: a host's use of the execution of a `run`. The execution borrows the run's
/// storage, which `execute` releases when `consume` returns; the status `consume` returns is the
/// run's.
pub const Consumer = struct {
    context: *anyopaque,
    consume: *const fn (context: *anyopaque, execution: forbic.evaluator.Execution, out: *std.Io.Writer, err: *std.Io.Writer) anyerror!u8,
    /// TASK-0109, W4.4: whether the run shows and writes what `eval` does (its `Print` lines on
    /// `out` and its writers' lines in their files) before the execution is handed over.
    prints: bool = false,
};

/// TASK-0109, W3.2a: everything `execute` needs, as a host names it without a command line. The
/// `forbic` tool fills it from its options (`dispatch`), which also decide which combinations it
/// accepts; the defaults are those of a command line that names none of them.
pub const Request = struct {
    command: Command,
    /// The path of the source, or of a module bundle when `bundled`, or of a project directory; or,
    /// when the host gives the bytes (`given`), only the name every report calls the program by.
    /// `-` is not standard input here: a program is read from a file, so a file called `-` is
    /// named `./-` (`SourceIsStandardInput`).
    file: [:0]const u8,
    bundled: bool = false,
    seed: u64 = forbic.effects.default_seed,
    tick_rate: u64 = forbic.types.Scheduler.default_tick_rate,
    /// The wall clock's reading at tick 0 in seconds (RFC-0086); null is the host's real-time
    /// clock.
    clock: ?f64 = null,
    /// The run's grants and the path of each (RFC-0086, P2.3; RFC-0087 K2), valid as
    /// `parseOptions` leaves them.
    grants: journal.Grants = .{ .list = &.{}, .paths = &.{} },
    /// The state directory of a journaled `eval` or `trace` (RFC-0086, P2.4), or the store a `check`
    /// tries its schema against (RFC-0087, P5.6).
    state: ?[]const u8 = null,
    journaling: Journaling = .{},
    diagnostics: forbic.excerpt.Style = .plain,
    /// TASK-0109, W4.4: the bytes of the program (a source, or a bundle packet when `bundled`), given
    /// by the host instead of read from `file`, which then only names it. A journal records their
    /// SHA-256 as it does a file's.
    given: ?[]const u8 = null,
    /// TASK-0109, W4.4: the native table the program is compiled against.
    natives: []const forbic.native.Entry = &forbic.native_std.table,
    /// TASK-0109, W4.4: where the code of the last diagnostic reported is left for the host.
    reporting: ?*Reporting = null,
    /// TASK-0109, W4.6 (RFC-0095): `file` is a project directory, read into the packet of its
    /// folder tree (`project.zig`) and run as that packet would be with `bundled`; a journal
    /// records the packet's SHA-256.
    project: bool = false,
};

/// TASK-0109, W4.4: the requests `execute` refuses, which `dispatch` never makes. W3.2a asserted
/// them; a host builds a `Request` itself, so they are errors of the service.
pub const RequestError = error{
    /// `--resume` and `--abandon` are of a state directory.
    IntentWithoutState,
    /// A state directory is taken by `eval`, `trace`, `run` and a starting `check` only.
    StateNotTaken,
    /// The grants are not a list a host may give (`effects.validGrants`), or have no path each.
    InvalidGrants,
    /// `qualify` runs nothing and takes no run option, so it takes no grant. (`inspect` runs
    /// nothing either, but its command line accepts the options of the others; it opens none.)
    GrantsNotTaken,
    /// TASK-0109, W4.6: a project is a directory `execute` reads, so it is neither `bundled` nor
    /// `given`.
    InvalidProject,
    /// `file` is `-` and the host gave no bytes: the program would be read from a file called `-`,
    /// which is not what `-` says elsewhere (`fmt -`, `--read NAME=-`). Name that file `./-`.
    SourceIsStandardInput,
};

/// TASK-0109, W4.4: whether `execute` takes `request`: the combinations `dispatch` makes.
pub fn checkRequest(request: Request) RequestError!void {
    const command = request.command;
    const starting = request.journaling.intent == .start;
    if (!starting and request.state == null) return error.IntentWithoutState;
    if (request.state != null and !(command == .eval or command == .trace or command == .run or (command == .check and starting))) return error.StateNotTaken;
    if (request.grants.list.len != request.grants.paths.len or !forbic.effects.validGrants(request.grants.list)) return error.InvalidGrants;
    if (request.grants.list.len != 0 and command == .qualify) return error.GrantsNotTaken;
    if (request.project and (request.bundled or request.given != null)) return error.InvalidProject;
    if (request.given == null and std.mem.eql(u8, request.file, "-")) return error.SourceIsStandardInput;
}

const RunOptions = struct {
    seed: u64,
    tick_rate: u64,
    clock: ?f64 = null,
    args: []const [:0]const u8,
    state: ?[]const u8 = null,
    random_seed: bool = false,
    /// RFC-0086, P2.5: whether `--seed` and `--tick-rate` were named (R3), and `--resume` or
    /// `--abandon`, which take no value.
    seed_given: bool = false,
    tick_rate_given: bool = false,
    resume_run: bool = false,
    abandon: bool = false,
    /// TASK-0109, W4.2: `--diagnostics=plain|excerpt`, one word, and whether it was named.
    diagnostics: forbic.excerpt.Style = .plain,
    styled: bool = false,
};

/// RFC-0086, P2.5: what a journaled command asks of its state directory, and which of the run's
/// parameters its command line named (a resumed run takes the others from its journal, R3).
pub const Journaling = struct {
    intent: journal.Intent = .start,
    seed_given: bool = false,
    tick_rate_given: bool = false,
    random_seed: bool = false,
};

/// RFC-0086, P2.3: the grants a `forbic` run is given, `--read NAME=PATH` and `--write NAME=PATH`
/// in the order they are written, and the path each names (`-` is standard input). Held behind
/// a pointer: a list of `grant_capacity` grants does not belong on the native stack.
const Grants = struct {
    list: [forbic.effects.grant_capacity]forbic.effects.Grant = undefined,
    paths: [forbic.effects.grant_capacity][]const u8 = undefined,
    count: usize = 0,

    fn slice(self: *const Grants) []const forbic.effects.Grant {
        return self.list[0..self.count];
    }
};

/// The options after FILE: `--seed N` (RFC-0079) and `--tick-rate N`, the ticks per second of
/// the run's virtual clock (RFC-0082), from 1 to 1,000,000, and `--clock S`, the wall clock's
/// reading at tick 0 in seconds (RFC-0086), a finite number. Each is given at most once, in any
/// order; what is left over (a second `--seed`, say) stays in `args` for the usage check.
fn runOptions(all: []const [:0]const u8) error{ BadNumber, BadDiagnostics }!RunOptions {
    return parseOptions(all, null) catch |problem| switch (problem) {
        error.BadNumber => error.BadNumber,
        error.BadDiagnostics => error.BadDiagnostics,
        // Without a list to fill, a grant is not an option: it stays for the usage check.
        error.BadGrant, error.TooManyGrants => unreachable,
    };
}

/// `runOptions`, and from RFC-0086 (P2.3) the grants `--read NAME=PATH` and `--write NAME=PATH`,
/// each as often as the host has room for, gathered into `grants` in the order written. A name is
/// 1 to 128 bytes of UTF-8 text, given once per kind; a path is not empty.
fn parseOptions(all: []const [:0]const u8, grants: ?*Grants) error{ BadNumber, BadGrant, TooManyGrants, BadDiagnostics }!RunOptions {
    var options: RunOptions = .{ .seed = forbic.effects.default_seed, .tick_rate = forbic.types.Scheduler.default_tick_rate, .args = all };
    var given: u6 = 0;
    while (options.args.len >= 4) {
        // RFC-0086, P2.5: the two options without a value, each at most once and only right after
        // `--state DIR` (G5); given both, or anywhere else, one is left for the usage check.
        const last = options.args[options.args.len - 1];
        const after_state = options.args.len >= 6 and std.mem.eql(u8, options.args[options.args.len - 3], "--state");
        if (std.mem.eql(u8, last, "--resume") and given & 48 == 0 and after_state) {
            options.resume_run = true;
            given |= 16;
            options.args = options.args[0 .. options.args.len - 1];
            continue;
        }
        if (std.mem.eql(u8, last, "--abandon") and given & 48 == 0 and after_state) {
            options.abandon = true;
            given |= 32;
            options.args = options.args[0 .. options.args.len - 1];
            continue;
        }
        // TASK-0109, W4.2: `--diagnostics=plain|excerpt` is one word, given at most once; a second
        // one is left for the usage check like any other word. A value that is neither is refused.
        // The word after an option that takes a value is that value (`--key --diagnostics=x`).
        if (std.mem.startsWith(u8, last, "--diagnostics=") and !options.styled and !takesValue(options.args[options.args.len - 2])) {
            options.diagnostics = forbic.excerpt.Style.parse(last["--diagnostics=".len..]) orelse return error.BadDiagnostics;
            options.styled = true;
            options.args = options.args[0 .. options.args.len - 1];
            continue;
        }
        if (options.args.len < 5) break;
        const option = options.args[options.args.len - 2];
        const value = options.args[options.args.len - 1];
        if (grants != null and std.mem.eql(u8, option, "--key")) {
            // RFC-0087, P5.5 (K2): a persistent key is a name and no resource.
            const list = grants.?;
            if (list.count == forbic.effects.grant_capacity) return error.TooManyGrants;
            list.list[list.count] = .{ .kind = .key, .name = value };
            list.paths[list.count] = "";
            list.count += 1;
        } else if (grants != null and (std.mem.eql(u8, option, "--read") or std.mem.eql(u8, option, "--write"))) {
            const list = grants.?;
            if (list.count == forbic.effects.grant_capacity) return error.TooManyGrants;
            const split = std.mem.indexOfScalar(u8, value, '=') orelse return error.BadGrant;
            if (split + 1 == value.len) return error.BadGrant;
            list.list[list.count] = .{ .kind = if (option[2] == 'w') .writer else .reader, .name = value[0..split] };
            list.paths[list.count] = value[split + 1 ..];
            list.count += 1;
        } else if (std.mem.eql(u8, option, "--seed") and given & 1 == 0) {
            // RFC-0086, P2.4: `random` is a seed the host draws from its entropy.
            if (std.mem.eql(u8, value, "random")) options.random_seed = true else options.seed = std.fmt.parseInt(u64, value, 0) catch return error.BadNumber;
            options.seed_given = true;
            given |= 1;
        } else if (std.mem.eql(u8, option, "--tick-rate") and given & 2 == 0) {
            options.tick_rate = std.fmt.parseInt(u64, value, 10) catch return error.BadNumber;
            if (!forbic.types.Scheduler.validRate(options.tick_rate)) return error.BadNumber;
            options.tick_rate_given = true;
            given |= 2;
        } else if (std.mem.eql(u8, option, "--clock") and given & 4 == 0) {
            if (!decimal(value)) return error.BadNumber;
            const start = std.fmt.parseFloat(f64, value) catch return error.BadNumber;
            if (!std.math.isFinite(start)) return error.BadNumber;
            options.clock = start;
            given |= 4;
        } else if (std.mem.eql(u8, option, "--state") and given & 8 == 0) {
            // RFC-0086, P2.4: the state directory of a journaled run.
            options.state = value;
            given |= 8;
        } else break;
        options.args = options.args[0 .. options.args.len - 2];
    }
    // They were read from the end: the list is in the order they were written.
    if (grants) |list| {
        std.mem.reverse(forbic.effects.Grant, list.list[0..list.count]);
        std.mem.reverse([]const u8, list.paths[0..list.count]);
        if (!forbic.effects.validGrants(list.slice())) return error.BadGrant;
        // Standard input is one stream: two readers of it would split its lines between them in
        // an order that depends on buffering, so it is granted once at most.
        var stdin_readers: usize = 0;
        for (list.slice(), list.paths[0..list.count]) |grant, path| {
            if (grant.kind == .reader and std.mem.eql(u8, path, "-")) stdin_readers += 1;
        }
        if (stdin_readers > 1) return error.BadGrant;
    }
    return options;
}

test "the grant options: readers and writers by name, in the order written, among the others" {
    const grants = try std.testing.allocator.create(Grants);
    defer std.testing.allocator.destroy(grants);
    grants.* = .{};
    const options = try parseOptions(&.{ "forbic", "eval", "f", "--read", "config=config.txt", "--seed", "4", "--write", "log=out/log.txt", "--read", "in=-", "--read", "a=b=c" }, grants);
    try std.testing.expectEqual(@as(u64, 4), options.seed);
    try std.testing.expectEqual(@as(usize, 3), options.args.len);
    try std.testing.expectEqual(@as(usize, 4), grants.count);
    const kinds = [_]forbic.effects.GrantKind{ .reader, .writer, .reader, .reader };
    const names = [_][]const u8{ "config", "log", "in", "a" };
    const paths = [_][]const u8{ "config.txt", "out/log.txt", "-", "b=c" };
    for (grants.slice(), grants.paths[0..grants.count], kinds, names, paths) |grant, path, kind, name, expected| {
        try std.testing.expectEqual(kind, grant.kind);
        try std.testing.expectEqualStrings(name, grant.name);
        try std.testing.expectEqualStrings(expected, path);
    }
    // A reader and a writer may share a name; two of a kind may not.
    grants.* = .{};
    _ = try parseOptions(&.{ "forbic", "eval", "f", "--read", "x=a", "--write", "x=b" }, grants);
    for ([_][]const [:0]const u8{
        &.{ "forbic", "eval", "f", "--read", "x=a", "--read", "x=b" },
        &.{ "forbic", "eval", "f", "--read", "x" },
        &.{ "forbic", "eval", "f", "--read", "=a" },
        &.{ "forbic", "eval", "f", "--write", "x=" },
        &.{ "forbic", "eval", "f", "--read", "\xff=a" },
        // Standard input is one stream, read by one reader at most.
        &.{ "forbic", "eval", "f", "--read", "a=-", "--read", "b=-" },
    }) |args| {
        grants.* = .{};
        try std.testing.expectError(error.BadGrant, parseOptions(args, grants));
    }
    // More than the host has room for.
    const many = try std.testing.allocator.alloc([:0]const u8, 3 + 2 * (forbic.effects.grant_capacity + 1));
    defer std.testing.allocator.free(many);
    const names_storage = try std.testing.allocator.alloc([16]u8, forbic.effects.grant_capacity + 1);
    defer std.testing.allocator.free(names_storage);
    many[0] = "forbic";
    many[1] = "eval";
    many[2] = "f";
    for (0..forbic.effects.grant_capacity + 1) |index| {
        many[3 + 2 * index] = "--read";
        many[4 + 2 * index] = try std.mem.printSentinel(&names_storage[index], "g{d}=p", .{index}, 0);
    }
    grants.* = .{};
    try std.testing.expectError(error.TooManyGrants, parseOptions(many, grants));
    grants.* = .{};
    _ = try parseOptions(many[0 .. many.len - 2], grants);
    try std.testing.expectEqual(@as(usize, forbic.effects.grant_capacity), grants.count);
    // Without a list to fill, `runOptions` leaves them to the usage check.
    try std.testing.expectEqual(@as(usize, 5), (try runOptions(&.{ "forbic", "eval", "f", "--read", "x=a" })).args.len);
}

test "the options after FILE: a seed and a tick rate, each once, in either order" {
    const Case = struct { args: []const [:0]const u8, seed: u64, rate: u64, left: usize };
    for ([_]Case{
        .{ .args = &.{ "forbic", "eval", "f" }, .seed = forbic.effects.default_seed, .rate = 60, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--tick-rate", "10" }, .seed = forbic.effects.default_seed, .rate = 10, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--seed", "3", "--tick-rate", "1000000" }, .seed = 3, .rate = 1_000_000, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--tick-rate", "1", "--seed", "0x10" }, .seed = 16, .rate = 1, .left = 3 },
        // A second one of either is left for the usage check to refuse.
        .{ .args = &.{ "forbic", "eval", "f", "--tick-rate", "5", "--tick-rate", "5" }, .seed = forbic.effects.default_seed, .rate = 5, .left = 5 },
        .{ .args = &.{ "forbic", "eval", "f", "--seed", "1", "--tick-rate", "2", "--seed", "1" }, .seed = 1, .rate = 2, .left = 5 },
        .{ .args = &.{ "forbic", "eval", "f", "--rate", "5" }, .seed = forbic.effects.default_seed, .rate = 60, .left = 5 },
    }) |case| {
        const options = try runOptions(case.args);
        try std.testing.expectEqual(case.seed, options.seed);
        try std.testing.expectEqual(case.rate, options.tick_rate);
        try std.testing.expectEqual(case.left, options.args.len);
    }
    // Out of range, not decimal, or not a number.
    for ([_][:0]const u8{ "0", "1000001", "0x10", "-1", "1.5", "", "18446744073709551616" }) |rate| {
        try std.testing.expectError(error.BadNumber, runOptions(&.{ "forbic", "eval", "f", "--tick-rate", rate }));
    }
}

/// TASK-0109, W4.2: the options of `parseOptions` that are followed by their value.
fn takesValue(word: []const u8) bool {
    for ([_][]const u8{ "--seed", "--tick-rate", "--clock", "--state", "--key", "--read", "--write" }) |option| {
        if (std.mem.eql(u8, word, option)) return true;
    }
    return false;
}

/// A decimal number as people write one: an optional minus, digits, an optional fraction and an
/// optional exponent. No hexadecimal, no digit separators, no leading plus.
fn decimal(text: []const u8) bool {
    var at: usize = 0;
    if (at < text.len and text[at] == '-') at += 1;
    const whole = at;
    while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
    if (at == whole) return false;
    if (at < text.len and text[at] == '.') {
        at += 1;
        const fraction = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == fraction) return false;
    }
    if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
        at += 1;
        if (at < text.len and (text[at] == '-' or text[at] == '+')) at += 1;
        const exponent = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at == exponent) return false;
    }
    return at == text.len;
}

test "the clock option: a finite number of seconds, once, in any order with the others" {
    const Case = struct { args: []const [:0]const u8, clock: ?f64, seed: u64, left: usize };
    for ([_]Case{
        .{ .args = &.{ "forbic", "eval", "f" }, .clock = null, .seed = forbic.effects.default_seed, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--clock", "1700000000" }, .clock = 1700000000.0, .seed = forbic.effects.default_seed, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--clock", "-2.5", "--seed", "4", "--tick-rate", "10" }, .clock = -2.5, .seed = 4, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--seed", "4", "--clock", "0.5" }, .clock = 0.5, .seed = 4, .left = 3 },
        .{ .args = &.{ "forbic", "eval", "f", "--clock", "1.7e9" }, .clock = 1.7e9, .seed = forbic.effects.default_seed, .left = 3 },
        // A second one is left for the usage check to refuse.
        .{ .args = &.{ "forbic", "eval", "f", "--clock", "1", "--clock", "2" }, .clock = 2.0, .seed = forbic.effects.default_seed, .left = 5 },
    }) |case| {
        const options = try runOptions(case.args);
        try std.testing.expectEqual(case.clock, options.clock);
        try std.testing.expectEqual(case.seed, options.seed);
        try std.testing.expectEqual(case.left, options.args.len);
    }
    for ([_][:0]const u8{ "nan", "inf", "-inf", "", "1e400", "x", "1.5s", "0x10", "1_0", "0x1p-2", "+5", ".5", "5.", "1e", "--1" }) |start| {
        try std.testing.expectError(error.BadNumber, runOptions(&.{ "forbic", "eval", "f", "--clock", start }));
    }
    // The host's clock reads the start plus the virtual time at the tick asked for.
    var clock: HostClock = .{ .io = std.testing.io, .start = 1700000000.0, .tick_rate = 60 };
    const answer = try HostClock.read(&clock, .{ .kind = .clock, .tick = 90 });
    try std.testing.expectEqual(@as(f64, 1700000001.5), @as(f64, @bitCast(answer.bits)));
    try std.testing.expectError(error.InputFailed, HostClock.read(&clock, .{ .kind = .line, .tick = 0 }));
    // Without the option it is the real-time clock, which is past 2020 on any host that runs this.
    clock.start = null;
    const now: f64 = @bitCast((try HostClock.read(&clock, .{ .kind = .clock })).bits);
    try std.testing.expect(now > 1577836800.0);
}

/// Where a run that keeps no witness sends its output: each committed `Print` is a line on
/// standard output as soon as nothing can undo it (RFC-0079). A write that fails is remembered,
/// and ends the run, so that a reader that has gone ends the tool as it does everywhere else.
const OutputLines = struct {
    out: *std.Io.Writer,
    failed: bool = false,
    /// RFC-0086, P2.3: where the lines of the other channels go.
    writers: ?*HostWriters = null,

    fn prepare(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: forbic.effects.Action) bool {
        const self: *OutputLines = @ptrCast(@alignCast(context));
        // RFC-0087, P5.5 (S3): a store action is committed to no store where there is no journal.
        if (action.channel == forbic.effects.store_channel) return true;
        // A line of a writer goes to that writer's file (RFC-0086 H6).
        if (action.channel != 0) {
            const writers = self.writers orelse return true;
            writers.line(action.channel, action.text) catch {
                self.failed = true;
                return false;
            };
            return true;
        }
        self.out.writeAll(action.text) catch {
            self.failed = true;
            return false;
        };
        self.out.writeByte('\n') catch {
            self.failed = true;
            return false;
        };
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn sink(self: *OutputLines) forbic.effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }
};

/// The world's clock of a `forbic` run (RFC-0086). With `--clock S` it reads `S + now / R` seconds
/// at tick `now` of a run whose tick rate is `R`, so that a run and its goldens can be repeated;
/// without it, the host's real-time clock. The run's input log asks it once per tick it reads.
const HostClock = struct {
    io: std.Io,
    start: ?f64,
    tick_rate: u64,

    fn paced(start: f64, tick: u64, rate: u64) f64 {
        @setFloatMode(.strict);
        return start + @as(f64, @floatFromInt(tick)) / @as(f64, @floatFromInt(rate));
    }
    fn read(context: *anyopaque, request: forbic.effects.Request) error{InputFailed}!forbic.effects.Answer {
        const self: *HostClock = @ptrCast(@alignCast(context));
        // The tool grants no reader yet (P2.3): the clock is all a run can ask it for.
        if (request.kind != .clock) return error.InputFailed;
        const seconds = if (self.start) |start| paced(start, request.tick, self.tick_rate) else real: {
            const now = std.Io.Clock.real.now(self.io);
            break :real @as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_s;
        };
        return .{ .bits = @bitCast(seconds) };
    }
    fn source(self: *HostClock) forbic.effects.InputSource {
        return .{ .context = self, .read = read };
    }
};

/// The world of a `forbic` run (RFC-0086, P2.3): its clock, and the line sources of its reader
/// grants, each opened before the run starts and read on as the run asks (I6, I7). A source that
/// cannot be read, or a line longer than the reader's buffer, is a device that failed.
const HostWorld = struct {
    clock: HostClock,
    grants: []const forbic.effects.Grant,
    /// By grant index: the reader of a reader grant, none for a writer.
    readers: []?std.Io.File.Reader,
    /// RFC-0087, P5.5 (S4): the entries the run's persistent cells load from its store, read and
    /// checked before it started. An entry the store lacks, and every entry when there is no state
    /// directory (S3), is at its end.
    loads: []const host_store.Load = &.{},

    fn read(context: *anyopaque, request: forbic.effects.Request) error{InputFailed}!forbic.effects.Answer {
        const self: *HostWorld = @ptrCast(@alignCast(context));
        switch (request.kind) {
            .clock => return HostClock.read(&self.clock, request),
            .load => return if (host_store.answer(self.loads, request.request)) |text| .{ .bytes = text } else .{ .status = .end },
            .line => {
                if (request.request >= self.readers.len) return error.InputFailed;
                const stream = &(self.readers[request.request] orelse return error.InputFailed);
                const line = stream.interface.takeDelimiter('\n') catch return error.InputFailed;
                return if (line) |bytes| .{ .bytes = bytes } else .{ .status = .end };
            },
        }
    }
    fn source(self: *HostWorld) forbic.effects.InputSource {
        return .{ .context = self, .read = read };
    }
};

/// The longest line a reader gives, which its buffer holds: the bytes of the whole input record
/// or a mebibyte, whichever is less.
const reader_line_bytes = @min(forbic.effects.input_byte_capacity, 1024 * 1024);

/// Opens the readers of `grants` (RFC-0086 H4: the host owns them for the run). A path that
/// cannot be opened ends the tool before anything runs, and the readers opened before it are
/// closed again: `execute` serves a host that keeps running.
fn openReaders(init: std.process.Init, grants: journal.Grants, err: *std.Io.Writer) !?[]?std.Io.File.Reader {
    // A run without grants needs nothing of the process but its `io`.
    if (grants.list.len == 0) return &.{};
    const arena = init.arena.allocator();
    const readers = try arena.alloc(?std.Io.File.Reader, grants.list.len);
    // The grants before `settled` hold their file or none. The one being opened is not yet, and
    // nothing after a failure here is held.
    var settled: usize = 0;
    var complete = false;
    defer if (!complete) closeReaders(init.io, grants, readers[0..settled]);
    for (grants.list, grants.paths, readers, 0..) |grant, path, *reader, index| {
        settled = index;
        reader.* = null;
        if (grant.kind != .reader) continue;
        const buffer = try arena.alloc(u8, reader_line_bytes);
        if (std.mem.eql(u8, path, "-")) {
            reader.* = stdio.describe(std.Io.File.stdin()).readerStreaming(init.io, buffer);
            continue;
        }
        const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |problem| {
            try err.print("forbic: error: cannot open reader {s} ({s})\n", .{ path, @errorName(problem) });
            return null;
        };
        reader.* = file.reader(init.io, buffer);
    }
    complete = true;
    return readers;
}

/// Closes the readers `openReaders` opened when the run is over, or a later grant failed; standard
/// input stays open.
fn closeReaders(io: std.Io, grants: journal.Grants, readers: []?std.Io.File.Reader) void {
    for (readers, grants.paths[0..readers.len]) |reader, path| if (reader) |opened| {
        if (!std.mem.eql(u8, path, "-")) opened.file.close(io);
    };
}

/// What names a file apart from its path: the device (volume) it is on and its number there. Inode
/// numbers are unique only within one device.
const WriterIdentity = struct {
    device: u64,
    inode: u64,

    fn equal(a: WriterIdentity, b: WriterIdentity) bool {
        return a.device == b.device and a.inode == b.inode;
    }

    /// `inode` is the file's number as `stat` gives it, which names it where the host has no call
    /// for the device (a system other than Windows and Linux).
    fn read(file: std.Io.File, inode: u64) !WriterIdentity {
        switch (@import("builtin").os.tag) {
            .windows => {
                const w = std.os.windows;
                var status: w.IO_STATUS_BLOCK = undefined;
                var index: w.FILE.INTERNAL_INFORMATION = undefined;
                if (w.ntdll.NtQueryInformationFile(file.handle, &status, &index, @sizeOf(@TypeOf(index)), .Internal) != .SUCCESS) return error.FileIdentityFailed;
                // Include space for the bounded NT volume label, even though only its serial is used.
                var volume: extern struct { info: w.FILE.FS_VOLUME_INFORMATION, label: [256]u16 } = undefined;
                if (w.ntdll.NtQueryVolumeInformationFile(file.handle, &status, &volume, @sizeOf(@TypeOf(volume)), .Volume) != .SUCCESS) return error.FileIdentityFailed;
                return .{ .device = volume.info.VolumeSerialNumber, .inode = @bitCast(index.IndexNumber) };
            },
            .linux => {
                const linux = std.os.linux;
                var stat: linux.Statx = undefined;
                if (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stat)) != .SUCCESS or !stat.mask.INO) return error.FileIdentityFailed;
                return .{ .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor, .inode = stat.ino };
            },
            else => return .{ .device = 0, .inode = inode },
        }
    }
};

/// The files of the writer grants of an `eval` (RFC-0086 H6): each is appended to, a committed
/// line at a time, as standard output is written; created when it does not exist.
const HostWriters = struct {
    /// By grant index: the writer of a writer grant, none for a reader, and none for a writer
    /// whose file an earlier grant opened.
    files: []?std.Io.File.Writer,
    /// By grant index: the grant whose writer appends this grant's lines. Grants of one file share
    /// one writer, so that their lines follow one another in commit order instead of each
    /// overwriting the other's from where the file ended when it was opened.
    owners: []u32,

    /// A grant that cannot be opened ends the call with none: the files opened for the grants before
    /// it are closed again, as `openReaders` closes its readers.
    fn open(init: std.process.Init, grants: journal.Grants, err: *std.Io.Writer) !?HostWriters {
        std.debug.assert(grants.list.len == grants.paths.len and grants.list.len <= forbic.effects.grant_capacity);
        if (grants.list.len == 0) return .{ .files = &.{}, .owners = &.{} };
        const arena = init.arena.allocator();
        const files = try arena.alloc(?std.Io.File.Writer, grants.list.len);
        const owners = try arena.alloc(u32, grants.list.len);
        const inodes = try arena.alloc(?WriterIdentity, grants.list.len);
        // The grants before `settled` hold their file or none; the one being opened closes its own
        // file where it fails.
        var settled: usize = 0;
        var complete = false;
        defer if (!complete) for (files[0..settled]) |held| if (held) |writer| writer.file.close(init.io);
        for (grants.list, grants.paths, files, owners, inodes, 0..) |grant, path, *writer, *owner, *inode, index| {
            settled = index;
            writer.* = null;
            owner.* = @intCast(index);
            inode.* = null;
            if (grant.kind != .writer) continue;
            const file = std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = false, .read = true }) catch |problem| {
                try err.print("forbic: error: cannot open writer {s} ({s})\n", .{ path, @errorName(problem) });
                return null;
            };
            const stat = file.stat(init.io) catch |problem| {
                file.close(init.io);
                try err.print("forbic: error: cannot open writer {s} ({s})\n", .{ path, @errorName(problem) });
                return null;
            };
            const identity = WriterIdentity.read(file, @bitCast(stat.inode)) catch |problem| {
                file.close(init.io);
                try err.print("forbic: error: cannot open writer {s} ({s})\n", .{ path, @errorName(problem) });
                return null;
            };
            // The same file under another grant, by whatever path: its writer takes these lines.
            const shared: ?usize = for (inodes[0..index], 0..) |earlier, at| {
                if (earlier != null and WriterIdentity.equal(earlier.?, identity)) break at;
            } else null;
            if (shared) |at| {
                file.close(init.io);
                owner.* = owners[at];
                continue;
            }
            inode.* = identity;
            const buffer = arena.alloc(u8, 4096) catch |problem| {
                file.close(init.io);
                return problem;
            };
            writer.* = file.writer(init.io, buffer);
            writer.*.?.seekTo(stat.size) catch {
                file.close(init.io);
                return error.WriteFailed;
            };
        }
        complete = true;
        return .{ .files = files, .owners = owners };
    }
    /// One committed line of the writer whose channel is `channel`.
    fn line(self: *HostWriters, channel: u32, text: []const u8) !void {
        std.debug.assert(channel != 0 and channel <= self.files.len);
        const writer = if (self.files[self.owners[channel - 1]]) |*writer| writer else return error.WriteFailed;
        try writer.interface.writeAll(text);
        try writer.interface.writeByte('\n');
    }
    fn finish(self: *HostWriters) !void {
        for (self.files) |*file| if (file.*) |*writer| try writer.interface.flush();
    }
    fn close(self: *HostWriters, io: std.Io) void {
        for (self.files) |file| if (file) |writer| writer.file.close(io);
    }
};

/// The output a `full` run committed, which its effect log kept: a line each. They are
/// written when the run is over, whether it completed or ended in a fatal error, because what
/// was committed has happened. A writer's line goes to its file (RFC-0086 H6).
fn writeKeptOutput(out: *std.Io.Writer, log: *const forbic.effects.Log, writers: ?*HostWriters) !void {
    for (0..log.kept) |index| {
        const channel = log.entries[index].channel;
        if (channel == forbic.effects.store_channel) continue;
        if (channel != 0) {
            if (writers) |files| try files.line(channel, log.text(@intCast(index)));
            continue;
        }
        try out.writeAll(log.text(@intCast(index)));
        try out.writeByte('\n');
    }
}

/// A journaled run (RFC-0086, P2.4): its sink and input journal are those of the journal in
/// `state`, it is a `digest` run from its first attempt so that the tool never runs it twice, and
/// what it shows and writes comes from the journal's durable prefix (J5, J8). P2.5: a resumed run
/// that ends before it passed its journal's last seal diverged (R4); its journal takes no end.
fn finishJournal(run: *journal.Run, end: forbic.durable.End, err: *std.Io.Writer) !enum { ended, failed, diverged } {
    run.finish(end) catch |problem| {
        if (problem == error.Diverged) return .diverged;
        // The journal ended, and the writers could not be published from it: a recovery can.
        if (problem == error.Unpublished and run.store_problem != null) {
            try err.print("forbic: error: the journal in {s} is finished; its store is not published ({s})\n", .{ run.path, try run.storeReason() });
        } else if (problem == error.Unpublished) {
            try err.print("forbic: error: the journal in {s} is finished; its writers are not published ({s})\n", .{ run.path, @errorName(run.unpublished.?) });
        } else if (problem == error.Unrotated) {
            try err.print("forbic: error: the journal in {s} is finished and its writers are published, but it is not rotated ({s})\n", .{ run.path, @errorName(run.unrotated.?) });
        } else try err.print("forbic: error: the journal in {s} is unfinished ({s})\n", .{ run.path, @errorName(problem) });
        return .failed;
    };
    if (run.shownFailed()) return error.WriteFailed;
    return .ended;
}

/// RFC-0086, P2.5 (R4): what a resumed run's fatal error is. A run whose journal found it
/// diverged, or whose input log was asked for another input than its prefix holds, did not do
/// what its journal holds: `recovery_diverged` at the node, and the journal is left unfinished.
fn recovered(run: *journal.Run, diagnostic: forbic.types.Diagnostic) ?forbic.types.Diagnostic {
    if (run.resumption == null) return null;
    if (run.journal.diverged or diagnostic.code == .input_diverged) return .{ .span = diagnostic.span, .code = .recovery_diverged };
    return null;
}

fn endOf(diagnostic: forbic.types.Diagnostic) forbic.durable.End {
    return .{ .outcome = .fatal, .code = @tagName(diagnostic.code), .start = diagnostic.span.start, .end = diagnostic.span.end };
}

/// TASK-0109, W3.2a: the service under every `forbic` command that reads a program: loads
/// `given.file`, compiles and admits it, runs it with the request's options and reports it, or
/// hands its execution to the host (`run`). Problems are reported on `err` as the tool reports
/// them; the status is the tool's exit status.
pub fn execute(init: std.process.Init, given: Request, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const command = given.command;
    const file = given.file;
    // TASK-0109, W4.6: a project is run as the packet of its tree.
    const bundled = given.bundled or given.project;
    const clock = given.clock;
    const state = given.state;
    const journaling = given.journaling;
    // The combinations `dispatch` refuses are refused here too (W4.4): a host makes its own requests.
    try checkRequest(given);
    var own_reporting: Reporting = .{};
    const reporting = given.reporting orelse &own_reporting;
    reporting.* = .{ .style = given.diagnostics, .tree = if (given.project) .{ .directory = file, .file = file } else null };
    // RFC-0086, P2.5 (R7a): abandoning runs nothing and reads no program.
    if (state) |path| if (journaling.intent == .abandon) {
        return switch (try journal.Run.open(init, path, .{ .intent = .abandon }, out, false, err)) {
            .done => |status| status,
            .ok => unreachable,
        };
    };
    var seed = given.seed;
    var tick_rate = given.tick_rate;
    const maximum: usize = if (bundled) forbic.bundle_packet.max_packet_bytes else forbic.types.limits.source_bytes;
    // Room for the largest admissible source; only the bytes a file has are ever touched. A host's
    // bytes and a project, which `project.Storage` reads, need none.
    const reads = given.given == null and !given.project;
    const source_buffer: []u8 = if (reads) forbic.scratch.alloc(u8, maximum + 1) orelse return error.OutOfMemory else &.{};
    defer if (reads) forbic.scratch.free(source_buffer);
    const tree = if (given.project) try forbic.scratch.storage(project.Storage) else null;
    defer if (tree) |storage| forbic.scratch.release(storage);
    const workspace = try forbic.scratch.storage(forbic.Workspace);
    defer forbic.scratch.release(workspace);
    forbic.scratch.initialise(workspace);
    // RFC-0085, I11: `qualify` asks the compiler for the definition of every identifier.
    const qualifying = command == .qualify;
    workspace.qualify = qualifying;
    workspace.natives = given.natives;
    // A host's bytes are bounded as a file's are; a project's packet is within the bound by the
    // walk's bounds.
    const source = if (tree) |storage| loaded: {
        forbic.scratch.initialise(storage);
        switch (storage.load(init.io, file)) {
            .refused => |refusal| {
                try refusal.write(err, file);
                return 1;
            },
            .ok => |read| {
                std.debug.assert(read.packet.len <= maximum);
                break :loaded read.packet;
            },
        }
    } else if (given.given) |bytes| (if (bytes.len > maximum) {
        try err.print("{s}: error: cannot read source ({s})\n", .{ file, @errorName(error.InputBudget) });
        return 1;
    } else bytes) else input.read(init.io, file, source_buffer, maximum) catch |read_error| {
        try err.print("{s}: error: cannot read source ({s})\n", .{ file, @errorName(read_error) });
        return 1;
    };
    const packet = if (bundled) try forbic.scratch.storage(forbic.bundle_packet.Workspace) else null;
    defer if (packet) |storage| forbic.scratch.release(storage);
    const program = if (packet) |storage| bundled_program: {
        forbic.scratch.initialise(storage);
        const bundle = storage.parse(source) catch |problem| {
            try err.print("{s}: error: invalid bounded module bundle ({s})\n", .{ file, @errorName(problem) });
            return 1;
        };
        break :bundled_program switch (workspace.compileBundle(bundle)) {
            .failed => |problem| return reportDiagnostic(err, reporting, problem.path, problem.source, problem.diagnostic),
            .ok => |program| program,
        };
    } else switch (workspace.compile(source)) {
        .failed => |diagnostic| return reportDiagnostic(err, reporting, file, source, diagnostic),
        .ok => |program| program,
    };
    if (qualifying) {
        // The source with every identifier in its qualified form; nothing runs.
        const written = forbic.scratch.alloc(forbic.types.Span, @max(program.modules.len, 1)) orelse return error.OutOfMemory;
        defer forbic.scratch.free(written);
        forbic.qualify.write(workspace.qualification(program, written), out) catch |problem| switch (problem) {
            // A module nested in a file and another file can have one path (`a.forb`'s `b`
            // and `a/b.forb`): their definitions would print alike.
            error.AmbiguousPath => {
                try err.print("{s}: error: two modules of the bundle have the same qualified path, so their definitions have no forms that tell them apart\n", .{file});
                return 1;
            },
            error.WriteFailed => return error.WriteFailed,
        };
        return 0;
    }
    // RFC-0087, P5.6: `forbic check FILE --state DIR` checks the program's schema against the store's,
    // without the run lock and without running the program.
    if (command == .check) if (state) |path| return trySchema(init, reporting, file, program, path, out, err);
    if (command == .inspect) {
        const inspector = try forbic.scratch.storage(forbic.inspection.Workspace);
        defer forbic.scratch.release(inspector);
        return switch (try inspector.write(out, program)) {
            .ok => 0,
            .failed => |diagnostic| reportProgramDiagnostic(err, reporting, file, program, diagnostic),
        };
    }
    // `eval` shows what the program printed, before its values, and appends to its writers what
    // it wrote to them; `check` and `trace` do neither (RFC-0086 H6).
    const printing = command == .eval or (command == .run and command.run.prints);
    // RFC-0086, P2.5: what the state directory holds decides, before anything is opened, whether
    // the run starts afresh, resumes the journal with its parameters (R3), or runs nothing.
    var list: journal.Grants = given.grants;
    // RFC-0087, P5.6 (G1): the schema of a program with persistent cells, described before the state
    // directory is opened, so that a program a store cannot hold changes nothing there.
    const persistent: []const host_store.Cell = if (state != null) try host_store.cellsOf(init.arena.allocator(), program) else &.{};
    const described: ?forbic.persist_schema.Description = if (persistent.len != 0) (try describeSchema(init, file, program, err)) orelse return 1 else null;
    // RFC-0086, P2.3: the run's readers, which the host opens first (H4). A journaled run that is
    // given its grants opens them before its state directory is: a reader that cannot be opened
    // ends the request with nothing created there, not the directory, its lock or the store's
    // schema object (RFC-0087, P5.6 G1). A run that takes its grants from its journal (a resume
    // that names none) can only open them once the journal is read; a start has nothing to resume.
    const early = state != null and list.list.len != 0;
    var journaled: ?*journal.Run = null;
    defer if (journaled) |run| run.close();
    var readers: []?std.Io.File.Reader = &.{};
    var readers_of = list;
    defer closeReaders(init.io, readers_of, readers);
    if (early) readers = (try openReaders(init, list, err)) orelse return 1;
    if (state) |path| {
        var request: journal.Request = .{ .intent = journaling.intent, .seed = if (journaling.seed_given and !journaling.random_seed) seed else null, .random_seed = journaling.random_seed, .tick_rate = if (journaling.tick_rate_given) tick_rate else null, .grants = list };
        std.crypto.hash.sha2.Sha256.hash(source, &request.program, .{});
        switch (try journal.Run.open(init, path, request, out, printing, err)) {
            .done => |status| return status,
            .ok => |run| journaled = run,
        }
        if (journaled.?.resumption) |resumed| {
            // The grants a command line names are the journal's own (R3), so the readers opened
            // for them are the resumed run's.
            std.debug.assert(!early or resumed.grants.list.len == list.list.len);
            seed = resumed.seed;
            tick_rate = resumed.tick_rate;
            list = resumed.grants;
        }
    }
    // RFC-0087, P5.5 (S3 to S7): a journaled run of a program with persistent cells starts on the
    // store of the state directory: its schema is written, the generation it starts from is named
    // in the journal's header, and the entries its cells load are read and checked first. P5.6
    // (G3): before any of that, the schema of that generation is checked against the program's.
    var loads: []const host_store.Load = &.{};
    var store_reference: ?forbic.durable.StoreRef = null;
    if (journaled) |run| {
        const cells = persistent;
        if (cells.len != 0) {
            if (run.resumption != null and run.store == null) {
                try err.print("forbic: error: the journal in {s} cannot be resumed (recovery_mismatch): it records no store\n", .{run.path});
                return 1;
            }
            // RFC-0087, P5.7 (R8): a resumed run's sealed loads are served from its journal, so their
            // entries are not read from the store.
            if (run.resumption != null) if (try run.loadSealed(err)) |status| return status;
            const sealed: forbic.effects.InputRecord = if (run.sealed) |held| held.record() else .{};
            switch (try host_store.prepare(init.io, init.gpa, init.arena.allocator(), run.dir, cells, described.?.text, list.list, if (run.resumption != null) run.store else null, sealed)) {
                .ok => |prepared| {
                    store_reference = prepared.reference;
                    loads = prepared.loads;
                },
                .problem => |problem| {
                    switch (problem) {
                        .failed => |reason| try err.print("forbic: error: the store in {s} cannot be read (store_failed): {s}\n", .{ run.path, reason }),
                        .disk => |disk| try err.print("forbic: error: the store in {s} cannot be used ({s})\n", .{ run.path, @errorName(disk) }),
                        .incompatible => |refusals| return reportRefusals(err, reporting, file, program, described.?, refusals),
                        // c1-2: the journal is of another run, as a header whose program differs is.
                        .other_schema => try err.print("forbic: error: the journal in {s} cannot be resumed (recovery_mismatch): {s}\n", .{ run.path, host_store.other_schema }),
                    }
                    return 1;
                },
            }
        }
    }
    const runtime = try forbic.scratch.storage(forbic.bytecode.Workspace);
    defer forbic.scratch.release(runtime);
    forbic.scratch.initialise(runtime);
    runtime.machine.control.effects.seed = seed;
    runtime.machine.control.tick_rate = tick_rate;
    runtime.machine.control.effects.inputs.grants = list.list;
    if (!early) {
        readers_of = list;
        readers = (try openReaders(init, list, err)) orelse return 1;
    }
    var world: HostWorld = .{ .clock = .{ .io = init.io, .start = clock, .tick_rate = tick_rate }, .grants = list.list, .readers = readers, .loads = loads };
    runtime.machine.control.effects.inputs.source = world.source();
    // A journaled run's writers are materialised from its journal instead (J8).
    var files: ?HostWriters = if (printing and state == null) (try HostWriters.open(init, given.grants, err)) orelse return 1 else null;
    defer if (files) |*opened| opened.close(init.io);
    const writers: ?*HostWriters = if (files) |*opened| opened else null;
    var lines: OutputLines = .{ .out = out, .writers = writers };
    if (journaled) |run| {
        if (run.resumption) |resumed| {
            // R6: each reader reads on from past the lines its journal sealed.
            for (world.readers, resumed.cursors) |*reader, cursor| if (reader.*) |*opened| opened.seekTo(cursor) catch |problem| {
                try err.print("forbic: error: cannot reposition a reader of {s} ({s})\n", .{ run.path, @errorName(problem) });
                return 1;
            };
            if (try run.proceed(err)) |status| return status;
            // R4: the sealed inputs are the run's prefix.
            runtime.machine.control.effects.inputs.prefix = run.sealed.?.record();
        } else if (try run.start(source, seed, tick_rate, list, world.readers, store_reference, err)) |status| return status;
        runtime.machine.control.trace = .digest;
        runtime.machine.control.effects.sink = run.journal.sink();
        runtime.machine.control.effects.inputs.journal = run.journal.inputJournal();
    }
    const execution = switch (runtime.evaluate(program, forbic.types.limits.evaluation_work)) {
        // A run that outgrows the stored call witness runs again keeping only the count and
        // digest of its steps. So does one that fills the member pool, the string pool or the
        // cells of its instances: without stored steps to name them, members, strings and
        // instances no longer in use are reclaimed. Short runs never come here, so their
        // reports are unchanged.
        // And so does one that fills its effect log: a run that stores its steps keeps the
        // output it commits for its report, and a run that does not hands each line on. The
        // first run showed nothing, so the second one shows everything once.
        // So does one that fills its live dependencies (RFC-0084): reclamation forgets the
        // records nothing reaches, and their entries.
        .failed => |diagnostic| if (journaled == null and (diagnostic.code == .call_trace_limit or diagnostic.code == .aggregate_limit or diagnostic.code == .string_limit or diagnostic.code == .object_limit or diagnostic.code == .effect_limit or diagnostic.code == .live_edge_limit)) long: {
            runtime.machine.control.trace = .digest;
            if (printing) runtime.machine.control.effects.sink = lines.sink();
            // The second attempt is served what the first one read, and asks the world only
            // past it, so both attempts see one world (RFC-0086, I3).
            runtime.machine.control.effects.inputs.again();
            const again = runtime.evaluate(program, forbic.types.limits.evaluation_work);
            if (lines.failed) return error.WriteFailed;
            if (writers) |opened| try opened.finish();
            break :long switch (again) {
                .failed => |problem| return reportProgramDiagnostic(err, reporting, file, program, problem),
                .ok => |execution| execution,
            };
        } else {
            // A journaled run ends in its journal, which shows and publishes what it made durable.
            if (journaled) |run| {
                if (recovered(run, diagnostic)) |diverged| return reportProgramDiagnostic(err, reporting, file, program, diverged);
                if (try finishJournal(run, endOf(diagnostic), err) == .diverged) return reportProgramDiagnostic(err, reporting, file, program, .{ .span = diagnostic.span, .code = .recovery_diverged });
                return reportProgramDiagnostic(err, reporting, file, program, diagnostic);
            }
            // What the run committed before it ended has happened: it is shown, then the error.
            if (printing) try writeKeptOutput(out, &runtime.machine.control.effects, writers);
            if (writers) |opened| try opened.finish();
            return reportProgramDiagnostic(err, reporting, file, program, diagnostic);
        },
        .ok => |execution| execution,
    };
    if (journaled) |run| switch (try finishJournal(run, .{ .outcome = .completed }, err)) {
        .ended => {},
        .failed => return 1,
        // The run completed before it passed its journal's last seal (R4).
        .diverged => return reportProgramDiagnostic(err, reporting, file, program, .{ .span = .{ .start = 0, .end = 0 }, .code = .recovery_diverged }),
    };
    if (printing and execution.trace == .full) try writeKeptOutput(out, &runtime.machine.control.effects, writers);
    if (writers) |opened| try opened.finish();
    // A report of a digest run replays a second run, by the reference evaluator on this storage,
    // instead of stored steps: see `trace_replay`.
    // A host's run gets the execution as it is, without a report to replay.
    const again = if (command != .run and execution.trace == .digest) try forbic.scratch.storage(forbic.trace_replay.Storage) else null;
    defer if (again) |storage| forbic.scratch.release(storage);
    if (again) |storage| {
        forbic.scratch.initialise(storage);
        // The second run draws from the stream the first one drew from, on the same clock.
        storage.control.effects.seed = seed;
        storage.control.tick_rate = tick_rate;
    }
    switch (command) {
        .run => |consumer| return consumer.consume(consumer.context, execution, out, err),
        .eval => {
            _ = (if (again) |storage| forbic.value_report.writeReplayed(out, execution, storage.producer(program, forbic.types.limits.evaluation_work), false, .{}) else forbic.value_report.write(out, execution, false, .{})) catch |report_error| switch (report_error) {
                error.ReportLimit, error.InvalidExecution => return reportDiagnostic(err, reporting, file, source, .{
                    .span = .{ .start = 0, .end = 0 },
                    .code = if (report_error == error.ReportLimit) .report_limit else .invalid_ir,
                }),
                error.WriteFailed => return error.WriteFailed,
            };
        },
        .trace => {
            (if (again) |storage| forbic.failure_report.writeReplayed(out, execution, storage.producer(program, forbic.types.limits.evaluation_work), file, .{}) else forbic.failure_report.write(out, execution, file, .{})) catch |problem| switch (problem) {
                error.ReportLimit, error.InvalidExecution => return reportProgramDiagnostic(err, reporting, file, program, .{ .span = .{ .start = 0, .end = 0 }, .code = if (problem == error.ReportLimit) .report_limit else .invalid_ir }),
                error.WriteFailed => return error.WriteFailed,
            };
        },
        // `inspect` and `qualify` reported above.
        .check, .inspect, .qualify => try out.print("ok: {d} bindings, {d} typed nodes\n", .{ program.bindings.len, program.nodes.len }),
    }
    return 0;
}

/// RFC-0087, P5.6 (G1): the schema of `program`, or null when it has none a store could hold.
fn describeSchema(init: std.process.Init, file: []const u8, program: forbic.types.Program, err: *std.Io.Writer) !?forbic.persist_schema.Description {
    return forbic.persist_schema.describe(init.arena.allocator(), program) catch |problem| switch (problem) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try err.print("{s}: error: the schema of the program's persistent cells cannot be written ({s})\n", .{ file, @errorName(problem) });
            return null;
        },
    };
}

/// RFC-0087, P5.6 (G3): each refusal of the schema check at the declaration it names, in the order of
/// the program's text, as `FILE:LINE:COLUMN: error: MESSAGE: REASON`.
fn reportRefusals(err: *std.Io.Writer, reporting: *Reporting, fallback: []const u8, program: forbic.types.Program, described: forbic.persist_schema.Description, refusals: []const forbic.persist_schema.Refusal) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const Located = struct { span: forbic.types.Span, at: usize };
    const located = try arena_state.allocator().alloc(Located, refusals.len);
    for (refusals, located, 0..) |refusal, *out, index| out.* = .{ .span = forbic.persist_schema.located(program, described, refusal.place), .at = index };
    std.mem.sort(Located, located, {}, struct {
        fn before(_: void, a: Located, b: Located) bool {
            return a.span.start < b.span.start or (a.span.start == b.span.start and a.at < b.at);
        }
    }.before);
    for (located) |place| {
        const problem = forbic.modules.locateIn(program, .{ .span = place.span, .code = .schema_incompatible }, fallback);
        const position = problem.diagnostic.location(problem.source);
        try writeTreeFolder(err, reporting, problem.path);
        try err.print("{s}:{d}:{d}: error: {s}: {s}\n", .{ problem.path, position.line, position.column, problem.diagnostic.message(), refusals[place.at].reason });
        if (reporting.style == .excerpt) try forbic.excerpt.writeDiagnostic(err, problem.source, problem.diagnostic);
    }
    reporting.code = .schema_incompatible;
    return 1;
}

/// RFC-0087, P5.6: `forbic check FILE --state DIR`. The program's schema against the schema of the
/// store's active generation; nothing runs, no lock is taken and nothing is written.
fn trySchema(init: std.process.Init, reporting: *Reporting, file: []const u8, program: forbic.types.Program, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const cells = try host_store.cellsOf(init.arena.allocator(), program);
    if (cells.len == 0) {
        try out.print("ok: {s} has no persistent cell: the store in {s} is not used\n", .{ file, path });
        return 0;
    }
    const described = (try describeSchema(init, file, program, err)) orelse return 1;
    switch (try host_store.trial(init.io, init.gpa, init.arena.allocator(), path, described.text)) {
        .empty => try out.print("ok: the store in {s} has no generation yet: a first run starts it\n", .{path}),
        .journal => {
            try err.print("forbic: error: the state directory {s} holds a journal, which the next run processes first and which may publish another schema: run it or end it with --abandon, then check\n", .{path});
            return 1;
        },
        .checked => |outcome| {
            if (outcome.refusals.len != 0) return reportRefusals(err, reporting, file, program, described, outcome.refusals);
            try out.print("ok: the schema of {s} is compatible with the store in {s}", .{ file, path });
            try out.writeAll(if (outcome.typed) "\n" else ", whose schema records no types: only its cells were checked\n");
        },
        .problem => |problem| {
            switch (problem) {
                .failed => |reason| try err.print("forbic: error: the store in {s} cannot be read (store_failed): {s}\n", .{ path, reason }),
                .disk => |disk| try err.print("forbic: error: the store in {s} cannot be used ({s})\n", .{ path, @errorName(disk) }),
                .incompatible => unreachable,
                // A check names no journal to resume.
                .other_schema => unreachable,
            }
            return 1;
        },
    }
    return 0;
}

/// TASK-0109, W4.4: a diagnostic as the `forbic` tool writes it, `PATH:LINE:COLUMN: error: MESSAGE`
/// and its related declaration, then, in `excerpt` style, its source; public so that an embedding
/// host writes the same text.
pub fn writeDiagnostic(err: *std.Io.Writer, path: []const u8, source: []const u8, diagnostic: forbic.types.Diagnostic, style: forbic.excerpt.Style) std.Io.Writer.Error!void {
    const position = diagnostic.location(source);
    try err.print("{s}:{d}:{d}: error: {s}", .{ path, position.line, position.column, diagnostic.message() });
    // The declaration a refused name already belongs to, when the diagnostic names it.
    if (diagnostic.relatedLocation(source)) |first| try err.print(" (first declared at {d}:{d})", .{ first.line, first.column });
    try err.writeByte('\n');
    if (style == .excerpt) try forbic.excerpt.writeDiagnostic(err, source, diagnostic);
}
/// TASK-0109, W4.6: a file of a project's tree is named where it is on disk, `DIR/src/` before its
/// path in the tree. The others (the project itself, the module path of the root or of a folder)
/// keep their names.
fn writeTreeFolder(err: *std.Io.Writer, reporting: *const Reporting, path: []const u8) std.Io.Writer.Error!void {
    const tree = reporting.tree orelse return;
    if (path.ptr == tree.file.ptr or !forbic.modules.canonicalPath(path)) return;
    try err.print("{s}/{s}/", .{ project.withoutSeparator(tree.directory), project.sources_name });
}
fn reportDiagnostic(err: *std.Io.Writer, reporting: *Reporting, path: []const u8, source: []const u8, diagnostic: forbic.types.Diagnostic) !u8 {
    try writeTreeFolder(err, reporting, path);
    try writeDiagnostic(err, path, source, diagnostic, reporting.style);
    reporting.code = diagnostic.code;
    return 1;
}
fn reportProgramDiagnostic(err: *std.Io.Writer, reporting: *Reporting, fallback: []const u8, program: forbic.types.Program, diagnostic: forbic.types.Diagnostic) !u8 {
    const problem = forbic.modules.locateIn(program, diagnostic, fallback);
    return reportDiagnostic(err, reporting, problem.path, problem.source, problem.diagnostic);
}
fn badNumber(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: invalid or out-of-range numeric argument\n");
    return 2;
}
/// RFC-0086, P2.3: a grant option the host cannot give.
fn badGrant(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: a grant is NAME=PATH, its name 1 to 128 bytes of UTF-8 text, given once per kind, and standard input is read by one reader at most\n");
    return 2;
}
/// A source named `-`, which would be a file of that name: standard input is read by `fmt -` and
/// a reader grant (`--read NAME=-`) only.
fn badSource(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: - is not a source (standard input is read by fmt and --read only); name a file called - as ./-\n");
    return 2;
}
/// TASK-0109, W4.2: a `--diagnostics=` value that names no style.
fn badDiagnostics(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: --diagnostics takes plain or excerpt\n");
    return 2;
}
fn tooManyGrants(err: *std.Io.Writer) !u8 {
    try err.print("error: too many grants (at most {d})\n", .{forbic.effects.grant_capacity});
    return 2;
}
fn forbicUsage(err: *std.Io.Writer) anyerror!u8 {
    return usage(err);
}
fn usage(err: *std.Io.Writer) !u8 {
    // `--seed N`, `--tick-rate N`, `--clock S` and the grants `--read NAME=PATH` and
    // `--write NAME=PATH` come after FILE, in any order, and before `--bundle` (RFC-0079,
    // RFC-0082, RFC-0086); so do `--seed random` and, for `eval` and `trace`, `--state DIR`
    // (RFC-0086, P2.4) with `--resume` or `--abandon` (P2.5). This line is a golden of the
    // build.
    try err.writeAll("usage: forbic check FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR] [--bundle] | eval FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | inspect FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--bundle] | trace FILE [--seed N|random] [--tick-rate N] [--clock S] [--read NAME=PATH]... [--write NAME=PATH]... [--key NAME]... [--state DIR [--resume|--abandon]] [--bundle] | qualify FILE [--bundle] | journal show DIR | store show DIR | fmt [--check] FILE...|- | --version\n");
    // TASK-0109, W4.2: a line of its own, so that the line above is not touched. Also a golden.
    try err.writeAll("       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n");
    // TASK-0109, W4.6: a line of its own too, for the same reason. Also a golden.
    try err.writeAll("       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n");
    return 2;
}

test "every forbic output path survives a slow pipe and ends quietly when the reader closes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_length = try temporary.dir.realPath(io, &directory);
    var path_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_bytes, "{s}/large.forb", .{directory[0..directory_length]}, 0);
    // 200 bindings: an inspection of about 260 KiB, four times a Windows pipe's buffer.
    var source_bytes: [16 * 1024]u8 = undefined;
    var source: std.Io.Writer = .fixed(&source_bytes);
    for (0..200) |index| try source.print("V{d}:i64=(({d}+1)*2-3)+{d}*{d};\n", .{ index, index, index, index });
    try temporary.dir.writeFile(io, .{ .sub_path = "large.forb", .data = source.buffered() });
    // `dispatch` uses only `io` of the process state on these paths.
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    const capacity = 512 * 1024;
    const expected = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(expected);
    const actual = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(actual);
    var no_cause: ?std.Io.File.Writer.Error = null;
    var message_bytes: [256]u8 = undefined;
    for ([_][:0]const u8{ "inspect", "eval", "trace", "check" }) |command| {
        const args = [_][:0]const u8{ "forbic", command, path };
        var whole: std.Io.Writer = .fixed(expected);
        var message: std.Io.Writer = .fixed(&message_bytes);
        try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &args, &whole, &message));
        try std.testing.expectEqualStrings("", message.buffered());
        try std.testing.expect(whole.buffered().len > 0);
        if (std.mem.eql(u8, command, "inspect")) try std.testing.expect(whole.buffered().len > 100 * 1024);

        // The same bytes arrive when the pipe takes five at a time through the tool's buffer.
        var accepted: std.Io.Writer = .fixed(actual);
        var buffer: [4096]u8 = undefined;
        var slow: stdio.Faulty = .init(&buffer, &accepted, 5);
        try std.testing.expectEqual(@as(u8, 0), try stdio.conclude(dispatch(init, &args, &slow.interface, &message), slow.sink(), .{ .writer = &message, .cause = &no_cause }));
        try std.testing.expectEqualStrings(whole.buffered(), accepted.buffered());
        try std.testing.expectEqualStrings("", message.buffered());

        // A reader that leaves half way: no diagnostic, no error, the conventional status.
        accepted = .fixed(actual);
        var closing: stdio.Faulty = .init(&buffer, &accepted, 1000);
        closing.limit = whole.buffered().len / 2;
        try std.testing.expectEqual(stdio.closed_status, try stdio.conclude(dispatch(init, &args, &closing.interface, &message), closing.sink(), .{ .writer = &message, .cause = &no_cause }));
        try std.testing.expectEqualStrings(whole.buffered()[0..closing.limit], accepted.buffered());
        try std.testing.expectEqualStrings("", message.buffered());
    }
}

test "a forbic run is granted readers and writers by name: lines in, lines appended, and only eval writes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "config.txt", .data = "alpha\nbeta\r\n\nlast" });
    try temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data =
        \\Line(R:reader)<transacts>:string = Attempt(R.ReadLine[], "<end>")
        \\Lines:tuple(string, string, string, string, string) = Attempt(Block{ R := OpenReader["config"]; tuple{Line(R), Line(R), Line(R), Line(R), Line(R)} }, tuple{"", "", "", "", ""})
        \\Wrote:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("first {Lines(0)}"); Print("shown"); W.WriteLine("second"); 1 }, 0)
        \\Gone:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("never"); Require[false]; 1 }, 0)
    });
    var paths: [4][std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const read = try std.mem.printSentinel(&paths[1], "config={s}/config.txt", .{at}, 0);
    const write = try std.mem.printSentinel(&paths[2], "log={s}/log.txt", .{at}, 0);
    const fresh = try std.mem.printSentinel(&paths[3], "log={s}/new.txt", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [4096]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var log_bytes: [256]u8 = undefined;
    // `check` and `trace` read the reader and write nothing.
    for ([_][:0]const u8{ "check", "trace" }) |command| {
        var out: std.Io.Writer = .fixed(&out_bytes);
        var message: std.Io.Writer = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", command, program, "--read", read, "--write", write }, &out, &message));
        try std.testing.expectEqualStrings("", message.buffered());
        try std.testing.expectEqualStrings("earlier\n", try temporary.dir.readFile(io, "log.txt", &log_bytes));
    }
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "eval", program, "--write", write, "--read", read }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings("shown\n{\"Lines\":[\"alpha\",\"beta\\r\",\"\",\"last\",\"<end>\"],\"Wrote\":1,\"Gone\":0,\"$inputs\":{\"count\":5,\"bytes\":14}}\n", out.buffered());
    // The writer appended its committed lines to what the file held.
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &log_bytes));
    // A writer's file that does not exist is created.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "eval", program, "--read", read, "--write", fresh }, &out, &message));
    try std.testing.expectEqualStrings("first alpha\nsecond\n", try temporary.dir.readFile(io, "new.txt", &log_bytes));
    // Without the grants the program runs as one with none: nothing opens.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "eval", program }, &out, &message));
    try std.testing.expectEqualStrings("{\"Lines\":[\"\",\"\",\"\",\"\",\"\"],\"Wrote\":0,\"Gone\":0}\n", out.buffered());
    // A reader that cannot be opened ends the tool before anything runs; so does a bad grant.
    var missing_bytes: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const missing = try std.mem.printSentinel(&missing_bytes, "config={s}/missing.txt", .{at}, 0);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try dispatch(init, &.{ "forbic", "eval", program, "--read", missing }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open reader") != null);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 2), try dispatch(init, &.{ "forbic", "eval", program, "--read", "config" }, &out, &message));
    try std.testing.expectEqualStrings("error: a grant is NAME=PATH, its name 1 to 128 bytes of UTF-8 text, given once per kind, and standard input is read by one reader at most\n", message.buffered());
    // Two writers of one file share it: each line is appended after the one committed before it.
    var both_bytes: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const one = try std.mem.printSentinel(&both_bytes[0], "log={s}/shared.txt", .{at}, 0);
    const other = try std.mem.printSentinel(&both_bytes[1], "audit={s}/./shared.txt", .{at}, 0);
    try temporary.dir.writeFile(io, .{ .sub_path = "two.forb", .data = "A:i64 = Attempt(Block{ L := OpenWriter[\"log\"]; B := OpenWriter[\"audit\"]; L.WriteLine(\"one\"); B.WriteLine(\"two\"); L.WriteLine(\"three\"); 1 }, 0)" });
    var two_bytes: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const two = try std.mem.printSentinel(&two_bytes, "{s}/two.forb", .{at}, 0);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    const status = try dispatch(init, &.{ "forbic", "eval", two, "--write", one, "--write", other }, &out, &message);
    errdefer std.debug.print("two writers of one file: {s}\n", .{message.buffered()});
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", try temporary.dir.readFile(io, "shared.txt", &log_bytes));
}

/// How many handles the process holds, where the system says: the leak checks below compare it
/// before and after a refused request. Null where there is no cheap count.
fn openHandles(io: std.Io) ?usize {
    switch (@import("builtin").os.tag) {
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
                extern "kernel32" fn GetProcessHandleCount(process: std.os.windows.HANDLE, count: *u32) callconv(.winapi) std.os.windows.BOOL;
            };
            var count: u32 = 0;
            if (kernel32.GetProcessHandleCount(kernel32.GetCurrentProcess(), &count).toBool() == false) return null;
            return count;
        },
        .linux => {
            var directory = std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true }) catch return null;
            defer directory.close(io);
            var count: usize = 0;
            var walker = directory.iterate();
            while (walker.next(io) catch return null) |_| count += 1;
            return count;
        },
        else => return null,
    }
}

test "a request whose reader grant cannot be opened changes nothing in its state directory (c8-2)" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const at = directory[0..try temporary.dir.realPath(io, &directory)];
    try temporary.dir.writeFile(io, .{ .sub_path = "persistent.forb", .data = progress_source });
    try temporary.dir.writeFile(io, .{ .sub_path = "plain.forb", .data = "A:i64 = 1\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "line\n" });
    var paths: [6][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const persistent = try std.mem.printSentinel(&paths[0], "{s}/persistent.forb", .{at}, 0);
    const plain = try std.mem.printSentinel(&paths[1], "{s}/plain.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[2], "{s}/state", .{at}, 0);
    const good = try std.mem.printSentinel(&paths[3], "in={s}/ok.txt", .{at}, 0);
    const missing = try std.mem.printSentinel(&paths[4], "other={s}/missing.txt", .{at}, 0);
    const only_missing = try std.mem.printSentinel(&paths[5], "in={s}/missing.txt", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [4096]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    // A new state directory stays absent, for a program with persistent cells (whose schema object
    // the store would have written) and for one without; the reader that fails may be the first
    // or the second.
    const Case = struct { program: [:0]const u8, grants: []const [:0]const u8 };
    for ([_]Case{
        .{ .program = persistent, .grants = &.{ "--key", "alice", "--read", only_missing } },
        .{ .program = persistent, .grants = &.{ "--key", "alice", "--read", good, "--read", missing } },
        .{ .program = plain, .grants = &.{ "--read", only_missing } },
        .{ .program = plain, .grants = &.{ "--read", good, "--read", missing } },
    }) |case| {
        for ([_][:0]const u8{ "eval", "trace" }) |command| {
            var args: [12][:0]const u8 = undefined;
            args[0..4].* = .{ "forbic", command, case.program, "--state" };
            args[4] = state;
            @memcpy(args[5..][0..case.grants.len], case.grants);
            var out: std.Io.Writer = .fixed(&out_bytes);
            var message: std.Io.Writer = .fixed(&err_bytes);
            try std.testing.expectEqual(@as(u8, 1), try dispatch(init, args[0 .. 5 + case.grants.len], &out, &message));
            try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open reader") != null);
            try std.testing.expectEqualStrings("", out.buffered());
            try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state", .{}));
        }
    }
    // An empty state directory that was there stays empty: no lock, no store.
    try temporary.dir.createDir(io, "state", .default_dir);
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try dispatch(init, &.{ "forbic", "eval", persistent, "--key", "alice", "--read", good, "--read", missing, "--state", state }, &out, &message));
    {
        var opened = try temporary.dir.openDir(io, "state", .{ .iterate = true });
        defer opened.close(io);
        var walker = opened.iterate();
        try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try walker.next(io));
    }
    // The same request with readers that open runs, so the refusal was the reader's.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "eval", persistent, "--key", "alice", "--read", good, "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try temporary.dir.access(io, "state/store", .{});
}

test "a grant that fails to open closes the readers and writers opened before it (c8-3)" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const at = directory[0..try temporary.dir.realPath(io, &directory)];
    try temporary.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "line\n" });
    var paths: [5][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const readable = try std.mem.printSentinel(&paths[0], "{s}/ok.txt", .{at}, 0);
    const missing = try std.mem.printSentinel(&paths[1], "{s}/missing.txt", .{at}, 0);
    const writable = try std.mem.printSentinel(&paths[2], "{s}/log.txt", .{at}, 0);
    // A writer whose folder does not exist cannot be created.
    const impossible = try std.mem.printSentinel(&paths[3], "{s}/nowhere/log.txt", .{at}, 0);
    const readers = [_]forbic.effects.Grant{ .{ .kind = .reader, .name = "a" }, .{ .kind = .reader, .name = "b" }, .{ .kind = .reader, .name = "c" } };
    const writers = [_]forbic.effects.Grant{ .{ .kind = .writer, .name = "a" }, .{ .kind = .writer, .name = "b" } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var message_bytes: [512]u8 = undefined;
    const reading: journal.Grants = .{ .list = &readers, .paths = &.{ readable, readable, missing } };
    const writing: journal.Grants = .{ .list = &writers, .paths = &.{ writable, impossible } };
    // One refusal first: the arena the failing calls fill is the process's, and the system may
    // open what it needs the first time.
    var message: std.Io.Writer = .fixed(&message_bytes);
    try std.testing.expectEqual(@as(?[]?std.Io.File.Reader, null), try openReaders(init, reading, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open reader") != null);
    message = .fixed(&message_bytes);
    try std.testing.expect(try HostWriters.open(init, writing, &message) == null);
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open writer") != null);
    // Where the system counts handles, a refused request leaves none open behind it.
    const before = openHandles(io) orelse return error.SkipZigTest;
    for (0..8) |_| {
        message = .fixed(&message_bytes);
        try std.testing.expectEqual(@as(?[]?std.Io.File.Reader, null), try openReaders(init, reading, &message));
        message = .fixed(&message_bytes);
        try std.testing.expect(try HostWriters.open(init, writing, &message) == null);
    }
    const after = openHandles(io).?;
    try std.testing.expect(after < before + 8);
    // A host's request does the same: readers, then a refused grant, on the way out of `execute`.
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = "A:i64 = 1\n" });
    const program = try std.mem.printSentinel(&paths[4], "{s}/main.forb", .{at}, 0);
    for (0..8) |_| {
        message = .fixed(&message_bytes);
        var out_bytes: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_bytes);
        try std.testing.expectEqual(@as(u8, 1), try execute(init, .{ .command = .eval, .file = program, .grants = reading }, &out, &message));
    }
    try std.testing.expect(openHandles(io).? < before + 8);
}

test "a source named - is refused, as a usage error on the command line, and a file of that name is ./- (c8-5)" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // A file called `-` is not run as the program `-` names; it is named by a path (`./-`).
    try temporary.dir.writeFile(io, .{ .sub_path = "-", .data = "A:i64 = 1\n" });
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const at = directory[0..try temporary.dir.realPath(io, &directory)];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [2048]u8 = undefined;
    for ([_][]const [:0]const u8{
        &.{ "forbic", "eval", "-" },
        &.{ "forbic", "check", "-" },
        &.{ "forbic", "trace", "-", "--seed", "3" },
        &.{ "forbic", "inspect", "-" },
        &.{ "forbic", "qualify", "-" },
        &.{ "forbic", "eval", "-", "--bundle" },
        &.{ "forbic", "run", "-", "--state", "s" },
    }) |args| {
        var out: std.Io.Writer = .fixed(&out_bytes);
        var message: std.Io.Writer = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try dispatch(init, args, &out, &message));
        try std.testing.expectEqualStrings("error: - is not a source (standard input is read by fmt and --read only); name a file called - as ./-\n", message.buffered());
        try std.testing.expectEqualStrings("", out.buffered());
    }
    // Other malformed commands are still the usage line, and `./-` is the file.
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 2), try dispatch(init, &.{ "forbic", "qualify", "-", "--seed", "1" }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
    var path_bytes: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const named = try std.mem.printSentinel(&path_bytes, "{s}/-", .{at}, 0);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "eval", named }, &out, &message));
    try std.testing.expectEqualStrings("{\"A\":1}\n", out.buffered());
}

test "forbic qualify prints the source qualified, refuses the run options, and reports what does not compile" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    try temporary.dir.writeFile(io, .{ .sub_path = "good.forb", .data = "Twice(X:i64)<computes>:i64 = X * 2\nValue:i64 = Twice(21)\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "bad.forb", .data = "Value:i64 = Missing\n" });
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const good = try std.mem.printSentinel(&paths[0], "{s}/good.forb", .{directory[0..length]}, 0);
    const bad = try std.mem.printSentinel(&paths[1], "{s}/bad.forb", .{directory[0..length]}, 0);
    // `dispatch` uses only `io` of the process state on these paths.
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [1024]u8 = undefined;
    var err_bytes: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "qualify", good }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings("(/:)Twice((local:)X:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)X * 2\n(/:)Value:(/Verse.org/Verse:)i64 = (/:)Twice(21)\n", out.buffered());
    // Nothing runs, so no run option is taken.
    for ([_][]const [:0]const u8{
        &.{ "forbic", "qualify", good, "--seed", "1" },
        &.{ "forbic", "qualify", good, "--tick-rate", "10" },
        &.{ "forbic", "qualify", good, "--read", "a=b" },
        &.{ "forbic", "qualify" },
    }) |args| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try dispatch(init, args, &out, &message));
        try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
        try std.testing.expectEqualStrings("", out.buffered());
    }
    // A program that does not compile has no qualified form: its diagnostic, as `check` gives it.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try dispatch(init, &.{ "forbic", "qualify", bad }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "bad.forb:1:13: error: name must refer to a parameter or earlier declaration\n"));
    try std.testing.expectEqualStrings("", out.buffered());
}

test "the state and seed options: a directory once, `random` as a seed, and only for the commands that run" {
    const options = try runOptions(&.{ "forbic", "eval", "f", "--state", "run", "--seed", "random", "--tick-rate", "10" });
    try std.testing.expectEqualStrings("run", options.state.?);
    try std.testing.expect(options.random_seed);
    try std.testing.expectEqual(@as(usize, 3), options.args.len);
    // A second `--state`, or a second seed, is left for the usage check.
    try std.testing.expectEqual(@as(usize, 5), (try runOptions(&.{ "forbic", "eval", "f", "--state", "a", "--state", "b" })).args.len);
    try std.testing.expectEqual(@as(usize, 5), (try runOptions(&.{ "forbic", "eval", "f", "--seed", "random", "--seed", "4" })).args.len);
    try std.testing.expectError(error.BadNumber, runOptions(&.{ "forbic", "eval", "f", "--seed", "Random" }));
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [2048]u8 = undefined;
    for ([_][]const [:0]const u8{
        &.{ "forbic", "check", "f.forb", "--state", "s", "--resume" },
        &.{ "forbic", "inspect", "f.forb", "--state", "s" },
        &.{ "forbic", "journal" },
        &.{ "forbic", "journal", "show" },
        &.{ "forbic", "journal", "list", "s" },
        &.{ "forbic", "journal", "show", "s", "--seed", "1" },
        &.{ "forbic", "journal", "show", "s", "--bundle" },
    }) |args| {
        var out: std.Io.Writer = .fixed(&out_bytes);
        var message: std.Io.Writer = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try dispatch(init, args, &out, &message));
        try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic check FILE [--seed N|random]"));
    }
}

/// Runs the tool, returning its status, with what it wrote in `out` and `err`.
fn tool(init: std.process.Init, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    return dispatch(init, args, out, err);
}

/// The lines of `text` after the first: a journal's records past its header.
fn afterHeader(text: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    return text[first + 1 ..];
}

test "a journaled run shows and writes from its journal, rotates it at its end, and journal show prints it" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "config.txt", .data = "alpha\nbeta\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "earlier\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data =
        \\Stamp:float = GetSecondsSinceEpoch()
        \\First:string = Attempt(Block{ R := OpenReader["config"]; R.ReadLine[] }, "")
        \\Wrote:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("first {First}"); Print("shown"); W.WriteLine("second"); 1 }, 0)
        \\Gone:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("never"); Require[false]; 1 }, 0)
        \\Last:tuple() = Print("last")
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "fatal.forb", .data = "Shown:tuple() = Print(\"before\")\nZero:i64 = 0\nBad:i64 = 1 / Zero\n" });
    var paths: [10][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const read = try std.mem.printSentinel(&paths[1], "config={s}/config.txt", .{at}, 0);
    const write = try std.mem.printSentinel(&paths[2], "log={s}/log.txt", .{at}, 0);
    const plain_write = try std.mem.printSentinel(&paths[3], "log={s}/plain.txt", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[4], "{s}/state", .{at}, 0);
    const traced = try std.mem.printSentinel(&paths[5], "{s}/traced", .{at}, 0);
    const fatal = try std.mem.printSentinel(&paths[6], "{s}/fatal.forb", .{at}, 0);
    const fatal_state = try std.mem.printSentinel(&paths[7], "{s}/fatal-state", .{at}, 0);
    const random_state = try std.mem.printSentinel(&paths[8], "{s}/random", .{at}, 0);
    const trace_write = try std.mem.printSentinel(&paths[9], "log={s}/traced.txt", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var plain_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [256]u8 = undefined;

    // A journaled `eval` shows and writes what a plain one does.
    var plain: std.Io.Writer = .fixed(&plain_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", plain_write }, &plain, &message));
    var out: std.Io.Writer = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings(plain.buffered(), out.buffered());
    try std.testing.expectEqualStrings("shown\nlast\n{\"Stamp\":1700000000,\"First\":\"alpha\",\"Wrote\":1,\"Gone\":0,\"Last\":[],\"$inputs\":{\"count\":2,\"bytes\":5}}\n", out.buffered());
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));
    try std.testing.expectEqualStrings(try temporary.dir.readFile(io, "plain.txt", &file_bytes), try temporary.dir.readFile(io, "log.txt", &file_bytes));
    // The base the writer was copied to, and no temporary file left.
    try std.testing.expectEqualStrings("earlier\n", try temporary.dir.readFile(io, "state/writers/1.base", &file_bytes));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "log.txt.tmp", .{}));

    // The finished journal was rotated (RFC-0086, P2.5, R2); `journal show` shows it.
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));

    // `journal show`: the header, then every record of the durable prefix.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"header\":{\"toolchain\":\"forbic 0.0.1 (Forbic pure-core prototype; Zig 0.17.0)\",\"profile\":\"bootstrap\",\"program\":\""));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"seed\":6216465378251330560,\"tick_rate\":60,\"grants\":[{\"kind\":\"reader\",\"name\":\"config\",\"path\":\"") != null);
    // The SHA-256 of `earlier\n`.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"base\":\"1153aedfe51b31ee4886151d45aff3b7309eb9a05b64408af0dd19ecf00c595a\"}]}}\n") != null);
    try std.testing.expectEqualStrings(
        \\{"input":{"sequence":0,"kind":"clock","request":0,"tick":0,"status":"value","value":1700000000}}
        \\{"input":{"sequence":1,"kind":"line","request":0,"tick":0,"status":"value","line":"alpha"}}
        \\{"action":{"sequence":0,"channel":2,"text":"first alpha"}}
        \\{"action":{"sequence":1,"channel":0,"text":"shown"}}
        \\{"action":{"sequence":2,"channel":2,"text":"second"}}
        \\{"seal":{"actions":3,"inputs":2}}
        \\{"action":{"sequence":3,"channel":0,"text":"last"}}
        \\{"seal":{"actions":4,"inputs":2}}
        \\{"end":{"outcome":"completed"}}
        \\
    , afterHeader(out.buffered()));

    // A second run on the directory starts afresh: its writer's base is what the first published.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state }, &out, &message));
    try std.testing.expectEqualStrings(plain.buffered(), out.buffered());
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));

    // A journaled `trace` reports as a plain one, shows no line, and publishes its writers.
    plain = .fixed(&plain_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "trace", program, "--clock", "1700000000", "--read", read, "--write", trace_write }, &plain, &message));
    // A plain `trace` writes nothing.
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "traced.txt", .{}));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "trace", program, "--clock", "1700000000", "--read", read, "--write", trace_write, "--state", traced }, &out, &message));
    try std.testing.expectEqualStrings(plain.buffered(), out.buffered());
    try std.testing.expectEqualStrings("first alpha\nsecond\n", try temporary.dir.readFile(io, "traced.txt", &file_bytes));

    // A fatal error ends the journal with its code and span; what was sealed before it is shown.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", fatal, "--state", fatal_state }, &out, &message));
    try std.testing.expectEqualStrings("before\n", out.buffered());
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "fatal.forb:3:13: error: division by zero\n"));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", fatal_state }, &out, &message));
    try std.testing.expectEqualStrings("{\"action\":{\"sequence\":0,\"channel\":0,\"text\":\"before\"}}\n{\"seal\":{\"actions\":1,\"inputs\":0}}\n{\"end\":{\"outcome\":\"fatal\",\"code\":\"division_by_zero\",\"start\":57,\"end\":58}}\n", afterHeader(out.buffered()));

    // `--seed random`: the seed drawn is shown on standard error and kept in the header.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", fatal, "--seed", "random", "--state", random_state }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "forbic: seed "));
    const shown_seed = message.buffered()["forbic: seed ".len..std.mem.indexOfScalar(u8, message.buffered(), '\n').?];
    _ = try std.fmt.parseInt(u64, shown_seed, 10);
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", random_state }, &out, &message));
    var expected_seed: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&expected_seed, "\"seed\":{s},", .{shown_seed})) != null);

    // `journal show` of what is no journal.
    var missing_bytes: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const missing = try std.mem.printSentinel(&missing_bytes, "{s}/missing", .{at}, 0);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "journal", "show", missing }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open journal") != null);
    try temporary.dir.createDirPath(io, "garbage");
    try temporary.dir.writeFile(io, .{ .sub_path = "garbage/journal", .data = "not a journal at all" });
    var garbage_bytes: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const garbage = try std.mem.printSentinel(&garbage_bytes, "{s}/garbage", .{at}, 0);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "journal", "show", garbage }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "is no journal (it has no valid header)\n"));
}

/// RFC-0086, P2.5: what a crash leaves of a finished journal: its records up to the end of seal
/// number `seals` (counted from one), and the first bytes of the record after it, torn.
fn crashed(journal_bytes: []const u8, seals: usize, out: []u8) ![]const u8 {
    var image: forbic.durable.Image = .{ .bytes = journal_bytes };
    var buffer: [4096]u8 = undefined;
    var prefix = try forbic.durable.Prefix.init(image.disk(), &buffer);
    var count: usize = 0;
    while (try prefix.next()) |record| if (record.decoded == .seal) {
        count += 1;
        if (count == seals) {
            const torn = @min(record.item.end + 7, journal_bytes.len);
            @memcpy(out[0..torn], journal_bytes[0..torn]);
            return out[0..torn];
        }
    };
    return error.NoSuchSeal;
}

/// The journal `journal_bytes` with its header's program digest made that of `program`: a forged
/// header, which a resume cannot tell from the program's own.
fn forgedHeader(journal_bytes: []const u8, program: []const u8, out: []u8) ![]const u8 {
    var image: forbic.durable.Image = .{ .bytes = journal_bytes };
    var buffer: [4096]u8 = undefined;
    var reader: forbic.durable.Reader = .{ .disk = image.disk(), .buffer = &buffer };
    const first = (try reader.next()).?;
    var grants: [4]forbic.durable.GrantRecord = undefined;
    var header = try forbic.durable.decodeHeader(first.payload, &grants);
    std.crypto.hash.sha2.Sha256.hash(program, &header.program, .{});
    var payload: [2048]u8 = undefined;
    const encoded = try forbic.durable.encodeHeader(header, &payload);
    std.mem.writeInt(u32, out[0..4], @intCast(encoded.len), .little);
    out[4] = 1;
    @memcpy(out[5..][0..encoded.len], encoded);
    std.mem.writeInt(u32, out[5 + encoded.len ..][0..4], forbic.durable.checksum(1, &.{encoded}), .little);
    const rest = journal_bytes[first.end..];
    const at = 9 + encoded.len;
    @memcpy(out[at..][0..rest.len], rest);
    return out[0 .. at + rest.len];
}

test "a crashed journaled run is resumed to the journal an uninterrupted run writes, refused when it is another run's, diverges when it does not repeat it, and is abandoned" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "config.txt", .data = "alpha\nbeta\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    const source =
        \\Stamp:float = GetSecondsSinceEpoch()
        \\First:string = Attempt(Block{ R := OpenReader["config"]; R.ReadLine[] }, "")
        \\Wrote:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("first {First}"); Print("shown"); W.WriteLine("second"); 1 }, 0)
        \\Second:string = Attempt(Block{ R := OpenReader["config"]; R.ReadLine[] }, "")
        \\Again:tuple() = Print("again {Second}")
        \\Late:float = GetSecondsSinceEpoch()
        \\Last:tuple() = Print("last")
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = source });
    // The same program, but for a line it prints before the first seal.
    const changed = "Stamp:float = GetSecondsSinceEpoch()\nFirst:string = Attempt(Block{ R := OpenReader[\"config\"]; R.ReadLine[] }, \"\")\nWrote:i64 = Attempt(Block{ W := OpenWriter[\"log\"]; W.WriteLine(\"first {First}\"); Print(\"shewn\"); W.WriteLine(\"second\"); 1 }, 0)\nSecond:string = Attempt(Block{ R := OpenReader[\"config\"]; R.ReadLine[] }, \"\")\nAgain:tuple() = Print(\"again {Second}\")\nLate:float = GetSecondsSinceEpoch()\nLast:tuple() = Print(\"last\")";
    try temporary.dir.writeFile(io, .{ .sub_path = "changed.forb", .data = changed });
    var paths: [6][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const read = try std.mem.printSentinel(&paths[1], "config={s}/config.txt", .{at}, 0);
    const write = try std.mem.printSentinel(&paths[2], "log={s}/log.txt", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[3], "{s}/state", .{at}, 0);
    const other = try std.mem.printSentinel(&paths[4], "{s}/changed.forb", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [256]u8 = undefined;
    var whole_bytes: [8192]u8 = undefined;
    var image_bytes: [8192]u8 = undefined;
    var kept_bytes: [8192]u8 = undefined;

    // The uninterrupted run, its journal, and what it wrote.
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("shown\nagain beta\nlast\n{\"Stamp\":1700000000,\"First\":\"alpha\",\"Wrote\":1,\"Second\":\"beta\",\"Again\":[],\"Late\":1700000000,\"Last\":[],\"$inputs\":{\"count\":3,\"bytes\":9}}\n", out.buffered());
    const report = try arena.allocator().dupe(u8, out.buffered()["shown\n".len..]);
    const whole = try arena.allocator().dupe(u8, try temporary.dir.readFile(io, "state/journal.done", &whole_bytes));
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));

    // A crash after the first seal: the journal holds its first commit point and a torn record,
    // and the writer was not published.
    const reset = struct {
        fn f(dir: std.Io.Dir, image: []const u8) !void {
            try dir.writeFile(std.testing.io, .{ .sub_path = "state/journal", .data = image });
            try dir.writeFile(std.testing.io, .{ .sub_path = "log.txt", .data = "earlier\n" });
        }
    }.f;
    const image = try crashed(whole, 1, &image_bytes);
    try reset(temporary.dir, image);

    // Without `--resume` or `--abandon` the run is refused, untouched (`run_unfinished`).
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n"));
    try std.testing.expectEqualStrings(image, try temporary.dir.readFile(io, "state/journal", &kept_bytes));
    // A resume that names another seed, tick rate or grant, or of another program, is refused
    // untouched (`recovery_mismatch`).
    for ([_][]const [:0]const u8{
        &.{ "forbic", "eval", program, "--seed", "5", "--state", state, "--resume" },
        &.{ "forbic", "eval", program, "--seed", "random", "--state", state, "--resume" },
        &.{ "forbic", "eval", program, "--tick-rate", "30", "--state", state, "--resume" },
        &.{ "forbic", "eval", program, "--read", read, "--state", state, "--resume" },
        &.{ "forbic", "eval", other, "--state", state, "--resume" },
    }) |args| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 1), try tool(init, args, &out, &message));
        try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "(recovery_mismatch)") != null);
        try std.testing.expectEqualStrings("", out.buffered());
        try std.testing.expectEqualStrings(image, try temporary.dir.readFile(io, "state/journal", &kept_bytes));
    }
    // `--resume` and `--abandon` follow `--state DIR` (G5), exclude each other, and are for `eval`
    // and `trace`.
    for ([_][]const [:0]const u8{
        &.{ "forbic", "eval", program, "--resume" },
        &.{ "forbic", "eval", program, "--resume", "--state", state },
        &.{ "forbic", "eval", program, "--state", state, "--seed", "5", "--resume" },
        &.{ "forbic", "eval", program, "--abandon", "--state", state },
        &.{ "forbic", "eval", program, "--state", state, "--resume", "--abandon" },
        &.{ "forbic", "eval", program, "--state", state, "--abandon", "--abandon" },
        &.{ "forbic", "check", program, "--state", state, "--resume" },
        &.{ "forbic", "inspect", program, "--abandon" },
    }) |args| {
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try tool(init, args, &out, &message));
        try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
    }

    // R4: the resumed run takes its parameters from the header, verifies what was sealed, shows
    // only what was not, reads on from past the sealed line (R6), and writes the journal the
    // uninterrupted run wrote, byte for byte; its report is the uninterrupted one's.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings(report, out.buffered());
    try std.testing.expectEqualStrings(whole, try temporary.dir.readFile(io, "state/journal.done", &kept_bytes));
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));
    // A crash after the second seal, resumed by `trace` with its options named again.
    try reset(temporary.dir, try crashed(whole, 2, &image_bytes));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "trace", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings(whole, try temporary.dir.readFile(io, "state/journal.done", &kept_bytes));
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));
    // A world whose clock would answer otherwise: the reading was sealed, and the journal's is
    // served (I3); nothing past the cut asks for another.
    try reset(temporary.dir, try crashed(whole, 2, &image_bytes));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000100", "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings("last\n{\"Stamp\":1700000000,\"First\":\"alpha\",\"Wrote\":1,\"Second\":\"beta\",\"Again\":[],\"Late\":1700000000,\"Last\":[],\"$inputs\":{\"count\":3,\"bytes\":9}}\n", out.buffered());

    // A forged header that names the changed program: what it prints before the first seal is not
    // the journal's (`recovery_diverged` at the committing node), and the journal is left as it was.
    var forged_bytes: [8192]u8 = undefined;
    const forged = try forgedHeader(try crashed(whole, 1, &image_bytes), changed, &forged_bytes);
    try reset(temporary.dir, forged);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", other, "--clock", "1700000000", "--state", state, "--resume" }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "changed.forb:3:") != null);
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "error: the resumed run did not do what its journal holds: it committed another action or commit point, asked for another input, or ended before the journal's last seal; the journal is left as it was\n"));
    try std.testing.expectEqualStrings("", out.buffered());
    var cut_bytes: [8192]u8 = undefined;
    var found_image: forbic.durable.Image = .{ .bytes = forged };
    var scan_buffer: [4096]u8 = undefined;
    const cut = (try forbic.durable.scan(found_image.disk(), &scan_buffer)).cut;
    try std.testing.expectEqualStrings(forged[0..cut], try temporary.dir.readFile(io, "state/journal", &cut_bytes));

    // R7a: abandoned, the run publishes what it sealed and runs nothing.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--abandon" }, &out, &message));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state is abandoned\n"));
    try std.testing.expectEqualStrings("earlier\nfirst alpha\nsecond\n", try temporary.dir.readFile(io, "log.txt", &file_bytes));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "{\"seal\":{\"actions\":3,\"inputs\":2}}\n{\"abandoned\":{}}\n"));
    // A resume finds nothing unfinished: it runs afresh, as a run without it does.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--clock", "1700000000", "--read", read, "--write", write, "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings("shown\n", out.buffered()[0.."shown\n".len]);
}

test "the key option: a name, repeatable, among the other grants in the order written (RFC-0087 K2)" {
    const grants = try std.testing.allocator.create(Grants);
    defer std.testing.allocator.destroy(grants);
    grants.* = .{};
    const options = try parseOptions(&.{ "forbic", "eval", "f", "--key", "alice", "--read", "config=c.txt", "--key", "bob", "--seed", "4" }, grants);
    try std.testing.expectEqual(@as(usize, 3), options.args.len);
    try std.testing.expectEqual(@as(usize, 3), grants.count);
    const kinds = [_]forbic.effects.GrantKind{ .key, .reader, .key };
    const names = [_][]const u8{ "alice", "config", "bob" };
    for (grants.slice(), grants.paths[0..grants.count], kinds, names) |grant, path, kind, name| {
        try std.testing.expectEqual(kind, grant.kind);
        try std.testing.expectEqualStrings(name, grant.name);
        // A key names no resource.
        if (kind == .key) try std.testing.expectEqualStrings("", path);
    }
    // A key shares its name with a reader and a writer, but not with another key; and its name is
    // 1 to 128 bytes of text.
    grants.* = .{};
    _ = try parseOptions(&.{ "forbic", "eval", "f", "--key", "x", "--read", "x=a", "--write", "x=b" }, grants);
    for ([_][]const [:0]const u8{
        &.{ "forbic", "eval", "f", "--key", "x", "--key", "x" },
        &.{ "forbic", "eval", "f", "--key", "" },
        &.{ "forbic", "eval", "f", "--key", "\xff" },
    }) |args| {
        grants.* = .{};
        try std.testing.expectError(error.BadGrant, parseOptions(args, grants));
    }
    // Without a list to fill, `--key` is left for the usage check.
    try std.testing.expectEqual(@as(usize, 5), (try runOptions(&.{ "forbic", "eval", "f", "--key", "x" })).args.len);
}

/// The progress program of RFC-0087's source contract: `Gained` is the experience of `alice` after
/// adding ten, `Shown` a line printed after it is saved.
const progress_source =
    \\player_stats := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
    \\var Stats:weak_map(persistent_key, player_stats) = map{}
    \\Add(K:persistent_key, Points:i64)<reads><writes>:i64 = Block{
    \\    Current := Attempt(Stats[K], player_stats{})
    \\    set Stats[K] = player_stats{Level := Current.Level, Experience := Current.Experience + Points}
    \\    Points
    \\}
    \\Gained:i64 = Attempt(Block{ K := GetPersistentKey["alice"]; Add(K, 10); Stats[K].Experience }, -1)
    \\Shown:tuple() = Print("saved")
;

test "a persistent program is saved between sessions: the second sees the first's writes, store show prints them, and a run without a state directory saves nothing" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = progress_source });
    var paths: [3][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    const report = struct {
        fn of(gained: i64, buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "saved\n{{\"Stats\":[{{\"$key\":\"alice\"}},{{\"Level\":1,\"Experience\":{d}}}],\"Gained\":{d},\"Shown\":[],\"$inputs\":{{\"count\":1,\"bytes\":{d}}}}}\n", .{ gained, gained, if (gained == 10) @as(usize, 0) else 78 });
        }
    }.of;
    var expected_bytes: [512]u8 = undefined;

    // The first session on an empty directory: nothing to load, ten gained and saved.
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings(try report(10, &expected_bytes), out.buffered());
    // The store: a first generation with the entry, and no journal left.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"number\":1,\"parent\":null}\n{\"schema\":{\"schema\":1,\"cells\":[{\"cell\":\":Stats\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"struct\":{\"package\":\"/\",\"name\":\"player_stats\",\"fields\":[{\"name\":\"Level\",\"type\":1,\"default\":\"1\"},{\"name\":\"Experience\",\"type\":1,\"default\":\"0\"}]}},{\"primitive\":\"i64\"}]}}\n{\"entry\":{\"cell\":\":Stats\",\"key\":\"alice\",\"object\":\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":1,\"x_Experience\":10}}}\n"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));

    // The second session loads what the first saved, and saves on top of it.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":20}],\"Gained\":20,"));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"number\":2,\"parent\":\"") != null);
    // The journal of the second session holds the load that was served and the action it made.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"grants\":[{\"kind\":\"key\",\"name\":\"alice\"}],\"store\":{\"base\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"input\":{\"sequence\":0,\"kind\":\"load\",\"request\":0,\"tick\":0,\"status\":\"value\",\"text\":\"{\\\"$package_name\\\":\\\"/\\\",\\\"$class_name\\\":\\\"player_stats\\\",\\\"x_Level\\\":1,\\\"x_Experience\\\":10}\"}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"action\":{\"sequence\":0,\"channel\":4294967295,\"text\":\"{\\\"cell\\\":\\\":Stats\\\",\\\"key\\\":\\\"alice\\\",\\\"value\\\":{") != null);

    // Another key has no entry and gets its own; a key that is not granted gets none.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "bob", "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":30}],\"Gained\":30,"));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "bob", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[],\"Gained\":-1,"));

    // Without a state directory the store is empty and nothing is saved (S3).
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "alice" }, &out, &message));
    try std.testing.expectEqualStrings("saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":10}],\"Gained\":10,\"Shown\":[],\"$inputs\":{\"count\":1,\"bytes\":0}}\n", out.buffered());
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "trace", program, "--key", "alice" }, &out, &message));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"number\":3,") != null);
    // Show takes a directory and nothing else.
    for ([_][]const [:0]const u8{ &.{ "forbic", "store" }, &.{ "forbic", "store", "show" }, &.{ "forbic", "store", "list", state }, &.{ "forbic", "store", "show", state, "--bundle" } }) |args| {
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try tool(init, args, &out, &message));
        try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
    }
    // A directory with no store.
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "store", "show", program }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot open the state directory") != null);
}

test "a damaged store is refused before anything runs (store_failed), and an entry that does not decode ends the run (load_invalid)" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = progress_source });
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));

    // The entry's object is another file under its name: refused, before a journal is made.
    var store_dir = try temporary.dir.openDir(io, "state/store", .{});
    defer store_dir.close(io);
    const entry_name = blk: {
        var found: [64]u8 = undefined;
        var objects = try store_dir.openDir(io, "objects", .{ .iterate = true });
        defer objects.close(io);
        var walker = objects.iterate();
        while (try walker.next(io)) |item| {
            const file = try objects.openFile(io, item.name, .{});
            defer file.close(io);
            var bytes: [512]u8 = undefined;
            const read = try file.readPositionalAll(io, &bytes, 0);
            if (std.mem.indexOf(u8, bytes[0..read], "x_Experience") != null) {
                @memcpy(&found, item.name[0..64]);
                break :blk found;
            }
        }
        return error.NoEntryObject;
    };
    var object_path: [96]u8 = undefined;
    const object = try std.fmt.bufPrint(&object_path, "state/store/objects/{s}", .{entry_name});
    var original_bytes: [512]u8 = undefined;
    const original = try arena.allocator().dupe(u8, try temporary.dir.readFile(io, object, &original_bytes));
    // s5-1: the object is one the rotated journal's publication wrote, so the next run, whatever
    // its keys, writes it again from that journal's text before it starts.
    try temporary.dir.writeFile(io, .{ .sub_path = object, .data = "damaged" });
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--key", "bob", "--state", state }, &out, &message));
    var repaired_bytes: [512]u8 = undefined;
    try std.testing.expectEqualStrings(original, try temporary.dir.readFile(io, object, &repaired_bytes));
    // Without a journal that holds its text, nothing can: refused, before a journal is made.
    try temporary.dir.deleteFile(io, "state/journal.done");
    try temporary.dir.writeFile(io, .{ .sub_path = object, .data = "damaged" });
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "(store_failed): an object is not the bytes its name is the hash of") != null);
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));
    // A key not granted does not load the object, so the damage is not met: the program runs.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--key", "bob", "--state", state }, &out, &message));
    // Show refuses it too.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "(store_failed)") != null);

    // A generation whose entry holds a text that is no value of the cell's type: the store is whole,
    // its schema is the program's (P5.6: the check passes, as it would for a store damaged on
    // disk), the run starts, and ends at the cell with load_invalid (G7).
    try temporary.dir.writeFile(io, .{ .sub_path = object, .data = original });
    var files = try host_store.Files.open(io, try temporary.dir.openDir(io, "state", .{}), false);
    defer files.close(io);
    var held = files.handle(std.testing.allocator);
    const current = (try held.activeName()).?;
    var generation_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer generation_arena.deinit();
    const schema = (try held.generation(generation_arena.allocator(), current)).schema;
    const published = (try held.publish(current, schema, &.{.{ .cell = ":Stats", .key = "alice", .text = @constCast("{\"x_Level\":\"high\"}") }})).?;
    _ = published;
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "main.forb:2:5: error: a stored entry of a persistent cell does not decode") != null);
    // The journal records the fatal end, and the store is as it was: nothing was committed.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"end\":{\"outcome\":\"fatal\",\"code\":\"load_invalid\"") != null);
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "x_Level\":\"high\"") != null);
}

test "a crashed run of a persistent program is resumed to the store an uninterrupted run publishes, and abandoning publishes what it sealed" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = progress_source });
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var whole_bytes: [8192]u8 = undefined;
    var image_bytes: [8192]u8 = undefined;
    var shown_bytes: [8192]u8 = undefined;
    var again_bytes: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    // The uninterrupted run, its journal and the store it published.
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--key", "alice", "--state", state }, &out, &message));
    const report = try arena.allocator().dupe(u8, out.buffered());
    const whole = try arena.allocator().dupe(u8, try temporary.dir.readFile(io, "state/journal.done", &whole_bytes));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    const published = try arena.allocator().dupe(u8, out.buffered());
    const reset = struct {
        fn f(dir: std.Io.Dir, image: []const u8) !void {
            // The crash: the store was never published, and the journal is cut after its first seal.
            try dir.deleteTree(std.testing.io, "state/store/generations");
            try dir.createDirPath(std.testing.io, "state/store/generations");
            try dir.deleteFile(std.testing.io, "state/store/active");
            try dir.deleteFile(std.testing.io, "state/journal.done");
            try dir.writeFile(std.testing.io, .{ .sub_path = "state/journal", .data = image });
        }
    }.f;
    // RFC-0087, P5.7: the uninterrupted run records its publication after its end, of both actions.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    const generation = published[15..][0..64];
    var record_bytes: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), try std.fmt.bufPrint(&record_bytes, "{{\"end\":{{\"outcome\":\"completed\"}}}}\n{{\"published\":{{\"generation\":\"{s}\",\"through\":2}}}}\n", .{generation})));
    // A crash after the first seal, which holds the store action: resumed to the same store. The
    // resume publishes what was sealed first and records it before the run goes on (P5.7); the end
    // has nothing more to publish. Its journal is the uninterrupted one's but for those records.
    try reset(temporary.dir, try crashed(whole, 1, &image_bytes));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expectEqualStrings(report, out.buffered());
    var stripped_bytes: [2][8192]u8 = undefined;
    try std.testing.expectEqualStrings(try withoutPublished(whole, &stripped_bytes[0]), try withoutPublished(try temporary.dir.readFile(io, "state/journal.done", &again_bytes), &stripped_bytes[1]));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&record_bytes, "{{\"seal\":{{\"actions\":1,\"inputs\":1}}}}\n{{\"published\":{{\"generation\":\"{s}\",\"through\":1}}}}\n{{\"action\":{{\"sequence\":1,", .{generation})) != null);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "{\"end\":{\"outcome\":\"completed\"}}\n"));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expectEqualStrings(published, out.buffered());
    // The same crash, abandoned: the sealed store action is published, and nothing runs.
    try reset(temporary.dir, try crashed(whole, 1, &image_bytes));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--abandon" }, &out, &message));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state is abandoned\n"));
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expectEqualStrings(published, out.buffered());
    // R9: the record of the publication, then `abandoned`.
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), try std.fmt.bufPrint(&record_bytes, "{{\"published\":{{\"generation\":\"{s}\",\"through\":1}}}}\n{{\"abandoned\":{{}}}}\n", .{generation})));
    // A crash before the first seal publishes nothing, whether abandoned or resumed.
    try reset(temporary.dir, whole[0..try headerEnd(whole)]);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--abandon" }, &out, &message));
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "has no generation yet") != null);
    _ = &shown_bytes;
}

/// RFC-0087, P5.6: the first version of a program whose store later versions run on.
const evolving_source =
    \\mode := enum<persistable><open>{Easy, Normal}
    \\level := enum<persistable><closed>{Low, High}
    \\profile := class<final><persistable>{
    \\    Title:string = ""
    \\    Rank:i64 = 1
    \\    Mode:mode = mode.Easy
    \\    Gate:level = level.Low
    \\}
    \\point := struct<persistable>{ X:i64, Y:i64 = 0 }
    \\var Profiles:weak_map(persistent_key, profile) = map{}
    \\var Points:weak_map(persistent_key, tuple(point, []string)) = map{}
    \\Main()<transacts><decides>:i64 = Block{
    \\    K := GetPersistentKey["alice"]
    \\    set Profiles[K] = profile{Title := "Ace", Rank := 3, Mode := mode.Normal}
    \\    set Points[K] = tuple{point{X := 4}, array{"a"}}
    \\    1
    \\}
    \\Saved:i64 = Attempt(Main[], 0)
;

/// The files of the store of the state directory `state`, each with its bytes, as one text.
fn storeImage(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var store_dir = try dir.openDir(io, "state/store", .{ .iterate = true });
    defer store_dir.close(io);
    var walker = try store_dir.walk(gpa);
    defer walker.deinit();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    while (try walker.next(io)) |entry| if (entry.kind == .file) try names.append(gpa, try gpa.dupe(u8, entry.path));
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (names.items) |name| {
        const file = try store_dir.openFile(io, name, .{});
        defer file.close(io);
        var bytes: [4096]u8 = undefined;
        const count = try file.readPositionalAll(io, &bytes, 0);
        try text.print(gpa, "{s}\n{s}\n", .{ name, bytes[0..count] });
    }
    return text.toOwnedSlice(gpa);
}

test "a store accepts a later version that adds what G3 allows, which loads old entries with their defaults; a downgrade and a removal are refused at their declarations, before anything is written" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "v1.forb", .data = evolving_source });
    // Version 2: a class field with a default, an enumerator after the old ones, a default where a
    // field had none, a cell; it reads alice's entry as version 1 left it, with the new defaults.
    try temporary.dir.writeFile(io, .{ .sub_path = "v2.forb", .data =
        \\mode := enum<persistable><open>{Easy, Normal, Hard}
        \\level := enum<persistable><closed>{Low, High}
        \\profile := class<final><persistable>{
        \\    Title:string = ""
        \\    Rank:i64 = 1
        \\    Mode:mode = mode.Easy
        \\    Gate:level = level.Low
        \\    Badges:[]string = array{"new"}
        \\}
        \\point := struct<persistable>{ X:i64, Y:i64 = 0 }
        \\var Profiles:weak_map(persistent_key, profile) = map{}
        \\var Points:weak_map(persistent_key, tuple(point, []string)) = map{}
        \\var Visits:weak_map(persistent_key, i64) = map{}
        \\Main()<transacts><decides>:i64 = Block{
        \\    K := GetPersistentKey["alice"]
        \\    P := Profiles[K]
        \\    set Visits[K] = 1
        \\    P.Rank * 100 + P.Badges.Length * 10 + Points[K](0).X
        \\}
        \\Read:i64 = Attempt(Main[], -1)
        \\Title:string = Attempt(Profiles[GetPersistentKey["alice"]].Title, "none")
    });
    var paths: [4][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const v1 = try std.mem.printSentinel(&paths[0], "{s}/v1.forb", .{at}, 0);
    const v2 = try std.mem.printSentinel(&paths[1], "{s}/v2.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[2], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    // Before any run, check finds no store; after the first, the store's schema is version 1's.
    try expectOk(&message, try tool(init, &.{ "forbic", "check", v2, "--state", state }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "/state has no generation yet: a first run starts it\n"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state", .{}));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", v1, "--key", "alice", "--state", state }, &out, &message));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"schema\":{\"schema\":1,\"cells\":[{\"cell\":\":Profiles\",\"key\":\"persistent_key\",\"value\":0},{\"cell\":\":Points\",\"key\":\"persistent_key\",\"value\":1}],\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"profile\",\"fields\":[{\"name\":\"Title\",\"type\":2,\"default\":\"\\\"\\\"\"},{\"name\":\"Rank\",\"type\":3,\"default\":\"1\"},{\"name\":\"Mode\",\"type\":4,\"default\":\"\\\"mode::Easy\\\"\"},{\"name\":\"Gate\",\"type\":5,\"default\":\"\\\"level::Low\\\"\"}]}},{\"tuple\":[6,7]},{\"primitive\":\"string\"},{\"primitive\":\"i64\"},{\"enum\":{\"package\":\"/\",\"name\":\"mode\",\"open\":true,\"cases\":[\"Easy\",\"Normal\"]}},{\"enum\":{\"package\":\"/\",\"name\":\"level\",\"open\":false,\"cases\":[\"Low\",\"High\"]}},{\"struct\":{\"package\":\"/\",\"name\":\"point\",\"fields\":[{\"name\":\"X\",\"type\":3},{\"name\":\"Y\",\"type\":3,\"default\":\"0\"}]}},{\"array\":2}]}}\n") != null);
    // `check --state` accepts version 2 without running it or writing anything.
    const first = try storeImage(io, temporary.dir, std.testing.allocator);
    defer std.testing.allocator.free(first);
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "check", v2, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "v2.forb is compatible with the store in ") != null);
    const checked = try storeImage(io, temporary.dir, std.testing.allocator);
    defer std.testing.allocator.free(checked);
    try std.testing.expectEqualStrings(first, checked);
    // Version 2 runs: alice's profile of version 1 reads with the default badges (G4).
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", v2, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"Read\":314,\"Title\":\"Ace\"") != null);
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"number\":2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"cell\":\":Visits\",\"key\":\"persistent_key\",\"value\":") != null);
    // G5: version 1 again is a downgrade; refused at each declaration it lacks, by `check` and by a
    // run, and the store is as it was.
    const second = try storeImage(io, temporary.dir, std.testing.allocator);
    defer std.testing.allocator.free(second);
    const downgrade =
        \\v1.forb:1:1: error: the program is incompatible with the store's schema: persistent cell :Visits removed: the store holds its entries
        \\v1.forb:1:1: error: the program is incompatible with the store's schema: enumerator Hard of enum mode removed
        \\v1.forb:3:1: error: the program is incompatible with the store's schema: field Badges of class profile removed: the store's entries hold it
        \\
    ;
    for ([_][]const u8{ "check", "eval", "trace" }) |command| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        const name: [:0]const u8 = if (std.mem.eql(u8, command, "check")) "check" else if (std.mem.eql(u8, command, "eval")) "eval" else "trace";
        try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", name, v1, "--key", "alice", "--state", state }, &out, &message));
        try std.testing.expectEqualStrings("", out.buffered());
        var lines = std.mem.splitScalar(u8, downgrade, '\n');
        var given = std.mem.splitScalar(u8, message.buffered(), '\n');
        while (lines.next()) |line| try std.testing.expect(std.mem.endsWith(u8, given.next().?, line));
        const after = try storeImage(io, temporary.dir, std.testing.allocator);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(second, after);
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));
    }
}

test "each refusal of G3 is reported at the declaration it names, and a store whose schema is unreadable or later is store_failed" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "v1.forb", .data = evolving_source });
    var paths: [3][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const v1 = try std.mem.printSentinel(&paths[0], "{s}/v1.forb", .{at}, 0);
    const changed = try std.mem.printSentinel(&paths[1], "{s}/changed.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[2], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", v1, "--key", "alice", "--state", state }, &out, &message));
    const Case = struct { from: []const u8, to: []const u8, line: []const u8, also_from: []const u8 = "", also_to: []const u8 = "" };
    // Each case changes one thing of version 1; the line is the one refusal, from its place on.
    const cases = [_]Case{
        // A cell removed: at the start of the file.
        .{ .from = "var Points:weak_map(persistent_key, tuple(point, []string)) = map{}\n", .to = "", .also_from = "    set Points[K] = tuple{point{X := 4}, array{\"a\"}}\n", .line = "changed.forb:1:1: error: the program is incompatible with the store's schema: persistent cell :Points removed: the store holds its entries" },
        // A cell's value type changed: at the cell.
        .{ .from = "tuple(point, []string)) = map{}", .to = "tuple(point, []i64)) = map{}", .also_from = "array{\"a\"}", .also_to = "array{1}", .line = "changed.forb:11:5: error: the program is incompatible with the store's schema: persistent cell :Points: the store's tuple(struct point, []string) is now tuple(struct point, []i64)" },
        .{ .from = "tuple(point, []string)) = map{}", .to = "tuple(point, []string, i64)) = map{}", .also_from = "array{\"a\"}}", .also_to = "array{\"a\"}, 1}", .line = "changed.forb:11:5: error: the program is incompatible with the store's schema: persistent cell :Points: the store's tuple(struct point, []string) is now tuple(struct point, []string, i64)" },
        // A class: a field removed (at the type), retyped, moved, without a default, its default
        // changed or removed (at the field).
        .{ .from = "    Rank:i64 = 1\n", .to = "", .also_from = "Rank := 3, ", .line = "changed.forb:3:1: error: the program is incompatible with the store's schema: field Rank of class profile removed: the store's entries hold it" },
        .{ .from = "    Rank:i64 = 1\n", .to = "    Rank:float = 1.0\n", .also_from = "Rank := 3,", .also_to = "Rank := 3.0,", .line = "changed.forb:5:5: error: the program is incompatible with the store's schema: field Rank of class profile: the store's i64 is now float" },
        .{ .from = "    Title:string = \"\"\n    Rank:i64 = 1\n", .to = "    Rank:i64 = 1\n    Title:string = \"\"\n", .line = "changed.forb:5:5: error: the program is incompatible with the store's schema: field Title of class profile moved: the fields of saved entries keep their order" },
        .{ .from = "    Gate:level = level.Low\n", .to = "    Gate:level = level.Low\n    Extra:i64\n", .also_from = "Mode := mode.Normal}", .also_to = "Mode := mode.Normal, Extra := 0}", .line = "changed.forb:8:5: error: the program is incompatible with the store's schema: field Extra added to class profile without a default: the store's entries lack it" },
        .{ .from = "    Rank:i64 = 1\n", .to = "    Rank:i64 = 2\n", .line = "changed.forb:5:5: error: the program is incompatible with the store's schema: the default of field Rank of class profile changed from 1 to 2" },
        .{ .from = "    Rank:i64 = 1\n", .to = "    Rank:i64\n", .line = "changed.forb:5:5: error: the program is incompatible with the store's schema: the default of field Rank of class profile removed" },
        // A struct never changes.
        .{ .from = "point := struct<persistable>{ X:i64, Y:i64 = 0 }", .to = "point := struct<persistable>{ X:i64, Y:i64 = 0, Z:i64 = 0 }", .line = "changed.forb:9:49: error: the program is incompatible with the store's schema: field Z added to struct point: a struct's fields never change" },
        .{ .from = "point := struct<persistable>{ X:i64, Y:i64 = 0 }", .to = "point := struct<persistable>{ X:i64 }", .line = "changed.forb:9:1: error: the program is incompatible with the store's schema: field Y of struct point removed: the store's entries hold it" },
        // Enums: an open one closed, a closed one opened or grown, a case removed, moved, or
        // inserted before the old ones of an open one.
        .{ .from = "enum<persistable><open>{Easy, Normal}", .to = "enum<persistable><closed>{Easy, Normal}", .line = "changed.forb:1:1: error: the program is incompatible with the store's schema: open enum mode is now closed" },
        .{ .from = "enum<persistable><closed>{Low, High}", .to = "enum<persistable><open>{Low, High}", .line = "changed.forb:2:1: error: the program is incompatible with the store's schema: closed enum level is now open" },
        .{ .from = "enum<persistable><closed>{Low, High}", .to = "enum<persistable><closed>{Low, High, Top}", .line = "changed.forb:2:47: error: the program is incompatible with the store's schema: enumerator Top added to closed enum level" },
        .{ .from = "enum<persistable><closed>{Low, High}", .to = "enum<persistable><closed>{High, Low}", .line = "changed.forb:2:42: error: the program is incompatible with the store's schema: enumerator Low of enum level moved: the store's enumerators keep their order" },
        .{ .from = "enum<persistable><open>{Easy, Normal}", .to = "enum<persistable><open>{First, Easy, Normal}", .line = "changed.forb:1:33: error: the program is incompatible with the store's schema: enumerator First inserted before the store's enumerators of enum mode: new ones come after the old" },
        // A type renamed or moved: where it is used.
        .{ .from = "point", .to = "spot", .line = "changed.forb:11:5: error: the program is incompatible with the store's schema: persistent cell :Points: the store's tuple(struct point, []string) is now tuple(struct spot, []string)" },
    };
    for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, evolving_source, case.from, case.to);
        defer std.testing.allocator.free(source);
        const renamed = if (case.also_from.len == 0) try std.testing.allocator.dupe(u8, source) else try std.mem.replaceOwned(u8, std.testing.allocator, source, case.also_from, case.also_to);
        defer std.testing.allocator.free(renamed);
        try std.testing.expect(!std.mem.eql(u8, renamed, evolving_source));
        try temporary.dir.writeFile(io, .{ .sub_path = "changed.forb", .data = renamed });
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        const status = try tool(init, &.{ "forbic", "check", changed, "--state", state }, &out, &message);
        const given = message.buffered();
        if (status != 1 or std.mem.count(u8, given, "\n") != 1 or !std.mem.endsWith(u8, given, "\n") or std.mem.indexOf(u8, given, case.line) == null) {
            std.debug.print("expected {s}\ngot {d}: {s}{s}\n", .{ case.line, status, given, out.buffered() });
            return error.TestUnexpectedResult;
        }
    }
    // A store whose generation names a schema that is none, or one of a later version, cannot be
    // read: store_failed, by a run and by `check`, before anything runs.
    var files = try host_store.Files.open(io, try temporary.dir.openDir(io, "state", .{}), false);
    defer files.close(io);
    var held = files.handle(std.testing.allocator);
    for ([_][]const u8{ "{}", "{\"schema\":2,\"cells\":[]}\n" }, [_][]const u8{ "the schema of its generation cannot be read: the schema is not one", "the schema of its generation cannot be read: the schema is of version 2, written by a later toolchain than this one (version 1)" }) |schema, reason| {
        const current = (try held.activeName()).?;
        _ = (try held.publish(current, try held.putObject(schema), &.{.{ .cell = ":Other", .key = "alice", .text = @constCast("1") }})).?;
        for ([_][:0]const u8{ "eval", "check" }) |command| {
            out = .fixed(&out_bytes);
            message = .fixed(&err_bytes);
            try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", command, v1, "--key", "alice", "--state", state }, &out, &message));
            try std.testing.expect(std.mem.indexOf(u8, message.buffered(), reason) != null);
        }
    }
}

test "a run that saves nothing leaves its schema when it is another, so the defaults it read are kept; check refuses to judge a directory that holds a journal" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "first.forb", .data =
        \\stats := class<final><persistable>{ Rank:i64 = 1 }
        \\var Stats:weak_map(persistent_key, stats) = map{}
        \\Saved:i64 = Attempt(Block{ set Stats[GetPersistentKey["alice"]] = stats{Rank := 3}; 1 }, 0)
    });
    // A version that adds a field with a default and only reads: alice's entry reads with 5.
    try temporary.dir.writeFile(io, .{ .sub_path = "reader.forb", .data =
        \\stats := class<final><persistable>{ Rank:i64 = 1, Bonus:i64 = 5 }
        \\var Stats:weak_map(persistent_key, stats) = map{}
        \\Bonus:i64 = Attempt(Stats[GetPersistentKey["alice"]].Bonus, -1)
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "seven.forb", .data =
        \\stats := class<final><persistable>{ Rank:i64 = 1, Bonus:i64 = 7 }
        \\var Stats:weak_map(persistent_key, stats) = map{}
        \\Bonus:i64 = Attempt(Stats[GetPersistentKey["alice"]].Bonus, -1)
    });
    var paths: [4][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const first = try std.mem.printSentinel(&paths[0], "{s}/first.forb", .{at}, 0);
    const reader = try std.mem.printSentinel(&paths[1], "{s}/reader.forb", .{at}, 0);
    const seven = try std.mem.printSentinel(&paths[2], "{s}/seven.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[3], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", first, "--key", "alice", "--state", state }, &out, &message));
    // Before it reads, the reader may change the default it adds.
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "check", seven, "--state", state }, &out, &message));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", reader, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"Bonus\":5") != null);
    // Its schema is the store's now, in a generation with the same entries: the default it read is
    // kept, and a later version that changes it is refused.
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"number\":2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"name\":\"Bonus\",\"type\":1,\"default\":\"5\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"x_Rank\":3}") != null);
    const second = try arena.allocator().dupe(u8, out.buffered());
    for ([_][:0]const u8{ "check", "eval" }) |command| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", command, seven, "--key", "alice", "--state", state }, &out, &message));
        try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "seven.forb:1:51: error: the program is incompatible with the store's schema: the default of field Bonus of class stats changed from 5 to 7\n"));
    }
    // The same reader again changes nothing: its schema is the base's.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", reader, "--key", "alice", "--state", state }, &out, &message));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expectEqualStrings(second, out.buffered());
    // A journal in the directory is processed by the next run before it checks, and may publish
    // another schema: `check` does not judge such a directory.
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = "" });
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "check", reader, "--state", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "/state holds a journal, which the next run processes first and which may publish another schema: run it or end it with --abandon, then check\n") != null);
}

/// Where the header record of a journal ends.
fn headerEnd(journal_bytes: []const u8) !usize {
    var image: forbic.durable.Image = .{ .bytes = journal_bytes };
    var buffer: [4096]u8 = undefined;
    var reader: forbic.durable.Reader = .{ .disk = image.disk(), .buffer = &buffer };
    return (try reader.next()).?.end;
}

/// RFC-0087, P5.7: the records of a journal but its `published` ones, which a resume adds.
fn withoutPublished(journal_bytes: []const u8, out: []u8) ![]const u8 {
    var image: forbic.durable.Image = .{ .bytes = journal_bytes };
    var buffer: [4096]u8 = undefined;
    var reader: forbic.durable.Reader = .{ .disk = image.disk(), .buffer = &buffer };
    var at: usize = 0;
    while (try reader.next()) |item| {
        if (item.kind == .published) continue;
        const bytes = journal_bytes[item.start..item.end];
        @memcpy(out[at..][0..bytes.len], bytes);
        at += bytes.len;
    }
    return out[0..at];
}

/// The bytes of `journal_bytes` up to the start of its last record, which must be a `published`.
fn beforeLastRecord(journal_bytes: []const u8) !usize {
    var image: forbic.durable.Image = .{ .bytes = journal_bytes };
    var buffer: [4096]u8 = undefined;
    var reader: forbic.durable.Reader = .{ .disk = image.disk(), .buffer = &buffer };
    var last: ?forbic.durable.Item = null;
    while (try reader.next()) |item| last = item;
    if (last.?.kind != .published or last.?.end != journal_bytes.len) return error.NoRecord;
    return @intCast(last.?.start);
}

test "a store's publications: run_unfinished leaves it untouched, a crash before a record is published again, a forged record is refused, and an active a crash took back is brought up" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = progress_source });
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [8192]u8 = undefined;
    var image_bytes: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const a = arena.allocator();
    const eval = [_][:0]const u8{ "forbic", "eval", program, "--key", "alice", "--state", state };
    // Two sessions: the second's journal records the generation after the first's.
    try expectOk(&message, try tool(init, &eval, &out, &message));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    const first = try a.dupe(u8, out.buffered()[15..][0..64]);
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":20}],\"Gained\":20,"));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    const shown = try a.dupe(u8, out.buffered());
    const second = shown[15..][0..64];
    const done = try a.dupe(u8, try temporary.dir.readFile(io, "state/journal.done", &file_bytes));
    const active_path = "state/store/active";
    const store_files = struct {
        /// The files of the store as text: active and the names under objects and generations.
        fn list(dir: std.Io.Dir, allocator: std.mem.Allocator) ![]const u8 {
            var text: std.Io.Writer.Allocating = .init(allocator);
            var bytes: [65]u8 = undefined;
            try text.writer.writeAll(try dir.readFile(std.testing.io, "state/store/active", &bytes));
            for ([_][]const u8{ "state/store/objects", "state/store/generations" }) |place| {
                var opened = try dir.openDir(std.testing.io, place, .{ .iterate = true });
                defer opened.close(std.testing.io);
                var names: std.ArrayList([]const u8) = .empty;
                var walker = opened.iterate();
                while (try walker.next(std.testing.io)) |item| try names.append(allocator, try allocator.dupe(u8, item.name));
                std.mem.sort([]const u8, names.items, {}, struct {
                    fn less(_: void, x: []const u8, y: []const u8) bool {
                        return std.mem.order(u8, x, y) == .lt;
                    }
                }.less);
                for (names.items) |name| try text.writer.print("{s}\n", .{name});
            }
            return text.written();
        }
    }.list;

    // R10: an unfinished journal of the second session (cut after its first seal, the store taken back
    // to the first generation) is refused without --resume or --abandon, and nothing is touched.
    try temporary.dir.deleteFile(io, "state/journal.done");
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = try crashed(done, 1, &image_bytes) });
    var line: [65]u8 = undefined;
    try temporary.dir.writeFile(io, .{ .sub_path = active_path, .data = try std.fmt.bufPrint(&line, "{s}\n", .{first}) });
    const before = try store_files(temporary.dir, a);
    const journal_before = try a.dupe(u8, try temporary.dir.readFile(io, "state/journal", &file_bytes));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &eval, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n"));
    try std.testing.expectEqualStrings(before, try store_files(temporary.dir, a));
    try std.testing.expectEqualStrings(journal_before, try temporary.dir.readFile(io, "state/journal", &file_bytes));
    // R8: resumed, the run is served its sealed load from the journal: the entry of the first
    // generation it loaded is not read again, so a store that lost its object still resumes, and
    // the run sees what it started from. The resume publishes the sealed write after the first
    // generation: the same generation the uninterrupted second session made.
    var entry_name: [64]u8 = undefined;
    {
        var objects = try temporary.dir.openDir(io, "state/store/objects", .{ .iterate = true });
        defer objects.close(io);
        var walker = objects.iterate();
        const found = while (try walker.next(io)) |item| {
            const file = try objects.openFile(io, item.name, .{});
            defer file.close(io);
            var bytes: [512]u8 = undefined;
            if (std.mem.indexOf(u8, bytes[0..try file.readPositionalAll(io, &bytes, 0)], "\"x_Experience\":10") != null) break item.name;
        } else return error.NoEntryObject;
        @memcpy(&entry_name, found[0..64]);
    }
    var object_path: [96]u8 = undefined;
    const object = try std.fmt.bufPrint(&object_path, "state/store/objects/{s}", .{&entry_name});
    const object_text = try a.dupe(u8, try temporary.dir.readFile(io, object, &file_bytes));
    try temporary.dir.deleteFile(io, object);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--state", state, "--resume" }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":20}],\"Gained\":20,"));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    var record_bytes: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&record_bytes, "{{\"published\":{{\"generation\":\"{s}\",\"through\":1}}}}\n", .{second})) != null);
    try temporary.dir.writeFile(io, .{ .sub_path = object, .data = object_text });
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expectEqualStrings(shown, out.buffered());

    // A crash after the publication's files and `active`, before its record: the finished journal
    // is published again by the next command, to the same files, and its record appended; then it
    // is rotated, and `--resume` runs nothing.
    const recorded_at = try beforeLastRecord(done);
    try temporary.dir.deleteFile(io, "state/journal.done");
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = done[0..recorded_at] });
    const published_files = try store_files(temporary.dir, a);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--state", state, "--resume" }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state has finished; nothing runs\n"));
    try std.testing.expectEqualStrings(done, try temporary.dir.readFile(io, "state/journal.done", &file_bytes));
    try std.testing.expectEqualStrings(published_files, try store_files(temporary.dir, a));
    // A crash after the record, before the rotation: nothing to publish, nothing appended.
    try temporary.dir.rename("state/journal.done", temporary.dir, "state/journal", io);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", program, "--state", state, "--resume" }, &out, &message));
    try std.testing.expectEqualStrings(done, try temporary.dir.readFile(io, "state/journal.done", &file_bytes));
    try std.testing.expectEqualStrings(published_files, try store_files(temporary.dir, a));

    // A forged record: the generation it names is the first, which the prefix does not make. The
    // finished journal is not published, and is left as it is; `--abandon` reports it and ends.
    const forged = try a.alloc(u8, done.len);
    @memcpy(forged, done);
    const payload = forged[recorded_at + 5 ..][0..40];
    _ = try std.fmt.hexToBytes(payload[0..32], first);
    std.mem.writeInt(u32, forged[recorded_at + 45 ..][0..4], forbic.durable.checksum(6, &.{payload}), .little);
    try temporary.dir.deleteFile(io, "state/journal.done");
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = forged });
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--resume" }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "is finished; its store is not published (StoreFailed: a published record of the journal names a generation its publication does not make)\n") != null);
    try std.testing.expectEqualStrings(forged, try temporary.dir.readFile(io, "state/journal", &file_bytes));
    try std.testing.expectEqualStrings(published_files, try store_files(temporary.dir, a));
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "eval", program, "--state", state, "--abandon" }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state had finished; its store is not published\n"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "state/journal", .{}));

    // P12: a crash kept the rotation and lost the replacement of `active`, and the generation it
    // named: `active` names the first generation, which the rotated journal's chain starts from.
    // The next run brings the store up to the journal's record before it starts, and runs on it.
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal.done", .data = done });
    try temporary.dir.writeFile(io, .{ .sub_path = active_path, .data = try std.fmt.bufPrint(&line, "{s}\n", .{first}) });
    var generation_path: [96]u8 = undefined;
    try temporary.dir.deleteFile(io, try std.fmt.bufPrint(&generation_path, "state/store/generations/{s}", .{second}));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "store", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "x_Experience\":10") != null);
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":30}],\"Gained\":30,"));
    // An `active` outside the rotated journal's chain is another publication's, left as it is.
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal.done", .data = done });
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":40}],\"Gained\":40,"));
}

test "the next run brings the store up to the rotated journal when a crash lost active or the generation it names, and a rotated journal it cannot verify stops no run" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    const at = directory[0..length];
    try temporary.dir.writeFile(io, .{ .sub_path = "main.forb", .data = progress_source });
    try temporary.dir.writeFile(io, .{ .sub_path = "plain.forb", .data = "Value:i64 = 1\n" });
    var paths: [3][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const program = try std.mem.printSentinel(&paths[0], "{s}/main.forb", .{at}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{at}, 0);
    const plain = try std.mem.printSentinel(&paths[2], "{s}/plain.forb", .{at}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var file_bytes: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const eval = [_][:0]const u8{ "forbic", "eval", program, "--key", "alice", "--state", state };
    const gained = struct {
        fn expect(written: []const u8, experience: i64) !void {
            var bytes: [128]u8 = undefined;
            try std.testing.expect(std.mem.startsWith(u8, written, try std.fmt.bufPrint(&bytes, "saved\n{{\"Stats\":[{{\"$key\":\"alice\"}},{{\"Level\":1,\"Experience\":{d}}}],\"Gained\":{d},", .{ experience, experience })));
        }
    }.expect;
    // The first session, on no base: its chain starts at no generation. The crash lost `active`
    // itself; the next run writes it again, and loads the first session's write.
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try temporary.dir.deleteFile(io, "state/store/active");
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try gained(out.buffered(), 20);
    // The crash kept `active` and lost the generation it names: written again from the journal.
    var active_bytes: [65]u8 = undefined;
    const active = try temporary.dir.readFile(io, "state/store/active", &active_bytes);
    var generation_path: [96]u8 = undefined;
    try temporary.dir.deleteFile(io, try std.fmt.bufPrint(&generation_path, "state/store/generations/{s}", .{active[0..64]}));
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try gained(out.buffered(), 30);
    // A rotated journal whose record names a generation its publication does not make tells
    // nothing: a run without a persistent cell starts, and so does one with them, on `active`.
    const done = try arena.allocator().dupe(u8, try temporary.dir.readFile(io, "state/journal.done", &file_bytes));
    const recorded_at = try beforeLastRecord(done);
    const payload = done[recorded_at + 5 ..][0..40];
    @memset(payload[0..32], 0x5a);
    std.mem.writeInt(u32, done[recorded_at + 45 ..][0..4], forbic.durable.checksum(6, &.{payload}), .little);
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal.done", .data = done });
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try expectOk(&message, try tool(init, &.{ "forbic", "eval", plain, "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("{\"Value\":1}\n", out.buffered());
    try temporary.dir.writeFile(io, .{ .sub_path = "state/journal.done", .data = done });
    out = .fixed(&out_bytes);
    try expectOk(&message, try tool(init, &eval, &out, &message));
    try gained(out.buffered(), 40);
}

fn expectOk(message: *std.Io.Writer, status: u8) !void {
    if (status != 0) std.debug.print("status {d}: {s}\n", .{ status, message.buffered() });
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "host writer preserves short multiple and over-buffer lines" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "writer", .{ .read = true });
    var buffer: [4096]u8 = undefined;
    var files = [_]?std.Io.File.Writer{file.writer(io, &buffer)};
    var owners = [_]u32{0};
    var writers: HostWriters = .{ .files = &files, .owners = &owners };
    defer writers.close(io);
    try writers.line(1, "short");
    try writers.line(1, "second");
    const large: [5000]u8 = @splat('x');
    try writers.line(1, &large);
    try writers.finish();
    const actual = try temporary.dir.readFileAlloc(io, "writer", std.testing.allocator, .limited(6000));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("short\nsecond\n" ++ large ++ "\n", actual);
}

test "writer identity distinguishes devices with equal inode numbers" {
    const first: WriterIdentity = .{ .device = 1, .inode = 42 };
    try std.testing.expect(!WriterIdentity.equal(first, .{ .device = 2, .inode = 42 }));
    try std.testing.expect(!WriterIdentity.equal(first, .{ .device = 1, .inode = 43 }));
    try std.testing.expect(WriterIdentity.equal(first, first));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "identity", .{});
    defer file.close(std.testing.io);
    const reopened = try temporary.dir.openFile(std.testing.io, "identity", .{});
    defer reopened.close(std.testing.io);
    try std.testing.expect(WriterIdentity.equal(try WriterIdentity.read(file, 0), try WriterIdentity.read(reopened, 0)));
}

test "the diagnostics option: one word, once, among the others, and only plain or excerpt" {
    const Case = struct { args: []const [:0]const u8, style: forbic.excerpt.Style, left: usize, styled: bool };
    for ([_]Case{
        .{ .args = &.{ "forbic", "eval", "f" }, .style = .plain, .left = 3, .styled = false },
        .{ .args = &.{ "forbic", "eval", "f", "--diagnostics=excerpt" }, .style = .excerpt, .left = 3, .styled = true },
        .{ .args = &.{ "forbic", "eval", "f", "--diagnostics=plain" }, .style = .plain, .left = 3, .styled = true },
        .{ .args = &.{ "forbic", "eval", "f", "--seed", "3", "--diagnostics=excerpt", "--tick-rate", "10" }, .style = .excerpt, .left = 3, .styled = true },
        .{ .args = &.{ "forbic", "eval", "f", "--diagnostics=excerpt", "--seed", "3" }, .style = .excerpt, .left = 3, .styled = true },
        .{ .args = &.{ "forbic", "eval", "f", "--state", "s", "--resume", "--diagnostics=excerpt" }, .style = .excerpt, .left = 3, .styled = true },
        // A second one is left for the usage check to refuse.
        .{ .args = &.{ "forbic", "eval", "f", "--diagnostics=plain", "--diagnostics=excerpt" }, .style = .excerpt, .left = 4, .styled = true },
        // The file is not an option, and a word that is not exactly the option is not one.
        .{ .args = &.{ "forbic", "eval", "--diagnostics=excerpt" }, .style = .plain, .left = 3, .styled = false },
        .{ .args = &.{ "forbic", "eval", "f", "--diagnostics", "excerpt" }, .style = .plain, .left = 5, .styled = false },
        .{ .args = &.{ "forbic", "eval", "f", "-diagnostics=excerpt" }, .style = .plain, .left = 4, .styled = false },
        // A value that looks like the option is a value: here the name of a key.
        .{ .args = &.{ "forbic", "eval", "f", "--key", "--diagnostics=excerpt" }, .style = .plain, .left = 5, .styled = false },
        .{ .args = &.{ "forbic", "eval", "f", "--state", "--diagnostics=excerpt" }, .style = .plain, .left = 3, .styled = false },
    }) |case| {
        const options = try runOptions(case.args);
        try std.testing.expectEqual(case.style, options.diagnostics);
        try std.testing.expectEqual(case.left, options.args.len);
        try std.testing.expectEqual(case.styled, options.styled);
    }
    for ([_][]const u8{ "", "Excerpt", "full", "excerpt,plain", "plain ", "none" }) |value| {
        var storage: [64]u8 = undefined;
        const word = try std.fmt.bufPrintSentinel(&storage, "--diagnostics={s}", .{value}, 0);
        try std.testing.expectError(error.BadDiagnostics, runOptions(&.{ "forbic", "eval", "f", word }));
    }
}

test "forbic commands that take source print an excerpt under the header only when asked" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    try temporary.dir.writeFile(io, .{ .sub_path = "bad.forb", .data = "A:i64 = 1\nValue:i64 = Missing + 1\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "good.forb", .data = "A:i64 = 1\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "late.forb", .data = "Zero:i64 = 0\nValue:i64 = 1 / Zero\n" });
    var paths: [3][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const bad = try std.mem.printSentinel(&paths[0], "{s}/bad.forb", .{directory[0..length]}, 0);
    const good = try std.mem.printSentinel(&paths[1], "{s}/good.forb", .{directory[0..length]}, 0);
    const late = try std.mem.printSentinel(&paths[2], "{s}/late.forb", .{directory[0..length]}, 0);
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [1024]u8 = undefined;
    var err_bytes: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const header = "bad.forb:2:13: error: name must refer to a parameter or earlier declaration\n";
    // Plain, by default and by name: the header and nothing else.
    for ([_][]const [:0]const u8{
        &.{ "forbic", "check", bad },
        &.{ "forbic", "check", bad, "--diagnostics=plain" },
    }) |args| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 1), try dispatch(init, args, &out, &message));
        try std.testing.expect(std.mem.endsWith(u8, message.buffered(), header));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message.buffered(), "\n"));
        try std.testing.expectEqualStrings("", out.buffered());
    }
    // An excerpt for every command that takes source, wherever the option stands among the others.
    for ([_][]const [:0]const u8{
        &.{ "forbic", "check", bad, "--diagnostics=excerpt" },
        &.{ "forbic", "eval", bad, "--seed", "2", "--diagnostics=excerpt" },
        &.{ "forbic", "trace", bad, "--diagnostics=excerpt", "--seed", "2" },
        &.{ "forbic", "inspect", bad, "--diagnostics=excerpt" },
        &.{ "forbic", "qualify", bad, "--diagnostics=excerpt" },
    }) |args| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 1), try dispatch(init, args, &out, &message));
        const text = message.buffered();
        try std.testing.expect(std.mem.endsWith(u8, text, header ++ "  2 | Value:i64 = Missing + 1\n    |             ^~~~~~~\n"));
        try std.testing.expectEqualStrings("", out.buffered());
    }
    // A run error is reported the same way, and a program that is fine prints nothing to stderr.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try dispatch(init, &.{ "forbic", "eval", late, "--diagnostics=excerpt" }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "late.forb:2:15: error: division by zero\n  2 | Value:i64 = 1 / Zero\n    |               ^\n"));
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try dispatch(init, &.{ "forbic", "check", good, "--diagnostics=excerpt" }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    // The style is of one command: the next one, given none, is plain again.
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try dispatch(init, &.{ "forbic", "check", bad }, &out, &message));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message.buffered(), "\n"));
    // A value that is no style is refused before anything is read; a second option is a usage error.
    for ([_][:0]const u8{ "--diagnostics=full", "--diagnostics=" }) |value| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try dispatch(init, &.{ "forbic", "check", bad, value }, &out, &message));
        try std.testing.expectEqualStrings("error: --diagnostics takes plain or excerpt\n", message.buffered());
    }
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 2), try dispatch(init, &.{ "forbic", "check", bad, "--diagnostics=plain", "--diagnostics=excerpt" }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic check FILE"));
    // TASK-0109, W4.6: the line of projects follows this one.
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "\n       check, eval, inspect, trace and qualify also take [--diagnostics=plain|excerpt]\n       run is eval;") != null);
    // Commands that run nothing and read no source take no such option.
    for ([_][]const [:0]const u8{
        &.{ "forbic", "journal", "show", "s", "--diagnostics=excerpt" },
        &.{ "forbic", "store", "show", "s", "--diagnostics=excerpt" },
    }) |args| {
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 2), try dispatch(init, args, &out, &message));
        try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
    }
}

/// TASK-0109, W3.2a: what a host's `run` was handed, and the status it answers with.
const Handed = struct {
    calls: usize = 0,
    bindings: usize = 0,
    status: u8,

    fn consume(context: *anyopaque, execution: forbic.evaluator.Execution, out: *std.Io.Writer, _: *std.Io.Writer) anyerror!u8 {
        const self: *Handed = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.bindings = execution.program.bindings.len;
        try out.writeAll("handed\n");
        return self.status;
    }
    fn consumer(self: *Handed) Consumer {
        return .{ .context = self, .consume = consume };
    }
};

test "a host executes a request without a command line: the tool's reports, or the execution handed to it" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const at = directory[0..try temporary.dir.realPath(io, &directory)];
    try temporary.dir.writeFile(io, .{ .sub_path = "good.forb", .data = "Base:i64 = 20\nTotal:i64 = Base * 2 + 2\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "fails.forb", .data = "Bad(N:i64)<computes>:i64=1/N\nAnswer:i64=Bad(0)\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "wrong.forb", .data = "A:i64 = \"text\"\n" });
    var paths: [3][std.Io.Dir.max_path_bytes]u8 = undefined;
    const good = try std.mem.printSentinel(&paths[0], "{s}/good.forb", .{at}, 0);
    const fails = try std.mem.printSentinel(&paths[1], "{s}/fails.forb", .{at}, 0);
    const wrong = try std.mem.printSentinel(&paths[2], "{s}/wrong.forb", .{at}, 0);
    // No grant, journal or state directory: `execute` uses only `io` of the process state.
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var expected_out: [4096]u8 = undefined;
    var expected_err: [4096]u8 = undefined;
    var actual_out: [4096]u8 = undefined;
    var actual_err: [4096]u8 = undefined;
    // Each command of the tool, asked for by a request, reports what its command line reports.
    const Case = struct { args: []const [:0]const u8, request: Request, status: u8 };
    for ([_]Case{
        .{ .args = &.{ "forbic", "eval", good }, .request = .{ .command = .eval, .file = good }, .status = 0 },
        .{ .args = &.{ "forbic", "check", good }, .request = .{ .command = .check, .file = good }, .status = 0 },
        .{ .args = &.{ "forbic", "trace", good, "--seed", "7", "--tick-rate", "10", "--clock", "5" }, .request = .{ .command = .trace, .file = good, .seed = 7, .tick_rate = 10, .clock = 5 }, .status = 0 },
        .{ .args = &.{ "forbic", "inspect", good }, .request = .{ .command = .inspect, .file = good }, .status = 0 },
        .{ .args = &.{ "forbic", "qualify", good }, .request = .{ .command = .qualify, .file = good }, .status = 0 },
        .{ .args = &.{ "forbic", "eval", fails }, .request = .{ .command = .eval, .file = fails }, .status = 1 },
        .{ .args = &.{ "forbic", "check", wrong, "--diagnostics=excerpt" }, .request = .{ .command = .check, .file = wrong, .diagnostics = .excerpt }, .status = 1 },
    }) |case| {
        var out: std.Io.Writer = .fixed(&expected_out);
        var message: std.Io.Writer = .fixed(&expected_err);
        try std.testing.expectEqual(case.status, try dispatch(init, case.args, &out, &message));
        var host_out: std.Io.Writer = .fixed(&actual_out);
        var host_message: std.Io.Writer = .fixed(&actual_err);
        try std.testing.expectEqual(case.status, try execute(init, case.request, &host_out, &host_message));
        try std.testing.expectEqualStrings(out.buffered(), host_out.buffered());
        try std.testing.expectEqualStrings(message.buffered(), host_message.buffered());
        try std.testing.expect(out.buffered().len + message.buffered().len > 0);
    }
    // A `run` hands the execution to the host, whose status is the run's, and reports nothing.
    var handed: Handed = .{ .status = 3 };
    var out: std.Io.Writer = .fixed(&actual_out);
    var message: std.Io.Writer = .fixed(&actual_err);
    try std.testing.expectEqual(@as(u8, 3), try execute(init, .{ .command = .{ .run = handed.consumer() }, .file = good }, &out, &message));
    try std.testing.expectEqual(@as(usize, 1), handed.calls);
    try std.testing.expectEqual(@as(usize, 2), handed.bindings);
    try std.testing.expectEqualStrings("handed\n", out.buffered());
    try std.testing.expectEqualStrings("", message.buffered());
    // A program that does not compile, or ends in an error, is reported as `check` reports it, and
    // the host is handed nothing.
    for ([_][:0]const u8{ wrong, fails }) |file| {
        var expected: std.Io.Writer = .fixed(&expected_err);
        var unused: std.Io.Writer = .fixed(&expected_out);
        try std.testing.expectEqual(@as(u8, 1), try execute(init, .{ .command = .check, .file = file }, &unused, &expected));
        out = .fixed(&actual_out);
        message = .fixed(&actual_err);
        try std.testing.expectEqual(@as(u8, 1), try execute(init, .{ .command = .{ .run = handed.consumer() }, .file = file }, &out, &message));
        try std.testing.expectEqualStrings("", out.buffered());
        try std.testing.expectEqualStrings(expected.buffered(), message.buffered());
        try std.testing.expect(std.mem.indexOf(u8, message.buffered(), ": error: ") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), handed.calls);
}

fn doubled(_: *forbic.native.Context, value: i64) i64 {
    return value *% 2;
}

test "a host's request the command line never makes is an error, and a request may bring its bytes, natives and reporting" {
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [512]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const reader = [_]forbic.effects.Grant{.{ .kind = .reader, .name = "in" }};
    const twice = [_]forbic.effects.Grant{ .{ .kind = .key, .name = "a" }, .{ .kind = .key, .name = "a" } };
    const Case = struct { request: Request, problem: RequestError };
    for ([_]Case{
        .{ .request = .{ .command = .eval, .file = "f", .journaling = .{ .intent = .resume_run } }, .problem = error.IntentWithoutState },
        .{ .request = .{ .command = .eval, .file = "f", .journaling = .{ .intent = .abandon } }, .problem = error.IntentWithoutState },
        .{ .request = .{ .command = .inspect, .file = "f", .state = "s" }, .problem = error.StateNotTaken },
        .{ .request = .{ .command = .check, .file = "f", .state = "s", .journaling = .{ .intent = .resume_run } }, .problem = error.StateNotTaken },
        .{ .request = .{ .command = .eval, .file = "f", .grants = .{ .list = &reader, .paths = &.{} } }, .problem = error.InvalidGrants },
        .{ .request = .{ .command = .eval, .file = "f", .grants = .{ .list = &twice, .paths = &.{ "", "" } } }, .problem = error.InvalidGrants },
        .{ .request = .{ .command = .qualify, .file = "f", .grants = .{ .list = &reader, .paths = &.{"p"} } }, .problem = error.GrantsNotTaken },
        .{ .request = .{ .command = .eval, .file = "-" }, .problem = error.SourceIsStandardInput },
        .{ .request = .{ .command = .check, .file = "-", .bundled = true }, .problem = error.SourceIsStandardInput },
        .{ .request = .{ .command = .qualify, .file = "-", .project = true }, .problem = error.SourceIsStandardInput },
    }) |case| {
        try std.testing.expectError(case.problem, checkRequest(case.request));
        try std.testing.expectError(case.problem, execute(init, case.request, &out, &message));
    }
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectEqualStrings("", message.buffered());
    // `inspect` runs nothing but takes the options of the others, grants among them (c8-4).
    try checkRequest(.{ .command = .inspect, .file = "f", .grants = .{ .list = &reader, .paths = &.{"p"} } });
    // The bytes a host gives are the program; `file` only names it. Its natives are the table the
    // program binds, and the code of a refusal is left where the host asked.
    var natives: [forbic.native_std.table.len + 1]forbic.native.Entry = undefined;
    @memcpy(natives[0..forbic.native_std.table.len], &forbic.native_std.table);
    natives[forbic.native_std.table.len] = forbic.native.entry("host.doubled", doubled, .{});
    var reporting: Reporting = .{};
    try std.testing.expectEqual(@as(u8, 0), try execute(init, .{ .command = .eval, .file = "given.forb", .given = "Doubled := native{\"host.doubled\"}\nValue:i64 = Doubled(21)\n", .natives = &natives, .reporting = &reporting }, &out, &message));
    try std.testing.expectEqualStrings("{\"Value\":42}\n", out.buffered());
    try std.testing.expectEqual(@as(?forbic.types.Diagnostic.Code, null), reporting.code);
    try std.testing.expectEqual(@as(u8, 1), try execute(init, .{ .command = .check, .file = "given.forb", .given = "Doubled := native{\"host.doubled\"}\n", .reporting = &reporting, .diagnostics = .excerpt }, &out, &message));
    try std.testing.expectEqual(@as(?forbic.types.Diagnostic.Code, .unknown_native), reporting.code);
    try std.testing.expectEqualStrings("given.forb:1:19: error: no native function with this id is registered with the host\n  1 | Doubled := native{\"host.doubled\"}\n    |                   ^~~~~~~~~~~~~~\n", message.buffered());
    // A run that prints shows its lines before it hands its execution over.
    var handed: Handed = .{ .status = 0 };
    out = .fixed(&out_bytes);
    var consumer = handed.consumer();
    consumer.prints = true;
    try std.testing.expectEqual(@as(u8, 0), try execute(init, .{ .command = .{ .run = consumer }, .file = "given.forb", .given = "Shown:tuple() = Print(\"line\")\n" }, &out, &message));
    try std.testing.expectEqualStrings("line\nhanded\n", out.buffered());
}

// TASK-0109, W4.6: project directories.

const ProjectFile = struct { path: []const u8, data: []const u8 };

/// A project in `at`: its manifest naming `/user@example.com/Hello`, and `files` under `src/`.
fn writeProject(io: std.Io, at: std.Io.Dir, files: []const ProjectFile) !void {
    try at.writeFile(io, .{ .sub_path = "forbic.json", .data = "{\"root\": \"/user@example.com/Hello\"}\n" });
    var room: [256]u8 = undefined;
    for (files) |file| {
        const path = try std.fmt.bufPrint(&room, "src/{s}", .{file.path});
        if (std.fs.path.dirnamePosix(path)) |folder| try at.createDirPath(io, folder);
        try at.writeFile(io, .{ .sub_path = path, .data = file.data });
    }
}

const hello_files = [_]ProjectFile{
    .{ .path = "user@example.com/Hello/main.forb", .data = "Kit := import{/user@example.com/Kit}\nGreeting<public>:string = \"Hello, {Kit.Name}\"\nShown:tuple() = Print(Greeting)\n" },
    .{ .path = "user@example.com/Hello/more.forb", .data = "# The second file of the folder: one module with main.forb.\nLength<public>:i64 = Greeting.Length\n" },
    .{ .path = "user@example.com/Kit/names.forb", .data = "Name<public>:string = \"world\"\n" },
};

test "forbic check, eval, run, trace, inspect and qualify take a project directory, which runs as the packet of its tree" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "hello");
    var hello = try temporary.dir.openDir(io, "hello", .{});
    defer hello.close(io);
    try writeProject(io, hello, &hello_files);
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    var paths: [2][std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    const dir = try std.mem.printSentinel(&paths[0], "{s}/hello", .{directory[0..length]}, 0);
    const packet_path = try std.mem.printSentinel(&paths[1], "{s}/hello.bundle.json", .{directory[0..length]}, 0);
    // The packet the project reads into, written where `--bundle` reads it.
    {
        const storage = try forbic.scratch.storage(project.Storage);
        defer forbic.scratch.release(storage);
        forbic.scratch.initialise(storage);
        switch (storage.load(io, dir)) {
            .ok => |read| try temporary.dir.writeFile(io, .{ .sub_path = "hello.bundle.json", .data = read.packet }),
            .refused => return error.TestUnexpectedResult,
        }
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    const gpa = std.testing.allocator;
    const out_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(out_bytes);
    const bundle_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(bundle_bytes);
    var err_bytes: [1024]u8 = undefined;
    var bundle_err_bytes: [1024]u8 = undefined;
    for ([_][:0]const u8{ "check", "eval", "run", "trace", "inspect", "qualify" }) |command| {
        var out: std.Io.Writer = .fixed(out_bytes);
        var message: std.Io.Writer = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", command, dir }, &out, &message));
        try std.testing.expectEqualStrings("", message.buffered());
        // `run` is `eval`.
        const as_bundle: [:0]const u8 = if (std.mem.eql(u8, command, "run")) "eval" else command;
        var bundle_out: std.Io.Writer = .fixed(bundle_bytes);
        var bundle_message: std.Io.Writer = .fixed(&bundle_err_bytes);
        try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", as_bundle, packet_path, "--bundle" }, &bundle_out, &bundle_message));
        try std.testing.expectEqualStrings(bundle_out.buffered(), out.buffered());
    }
    var out: std.Io.Writer = .fixed(out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "run", dir, "--seed", "3", "--diagnostics=excerpt" }, &out, &message));
    try std.testing.expectEqualStrings("Hello, world\n{\"Greeting\":\"Hello, world\",\"Shown\":[],\"Length\":12}\n", out.buffered());
    // A file is still a file, and a packet a packet: `run` takes both as `eval` does.
    out = .fixed(out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "run", packet_path, "--bundle" }, &out, &message));
    try std.testing.expectEqualStrings("Hello, world\n{\"Greeting\":\"Hello, world\",\"Shown\":[],\"Length\":12}\n", out.buffered());
    // A directory named as a packet is read as one, as before.
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "check", dir, "--bundle" }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/hello: error: cannot read source (InputNotRegularFile)\n"));
    // `run` is one of the commands of the usage, and takes nothing alone.
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 2), try tool(init, &.{ "forbic", "run" }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "\n       run is eval; for FILE, each of these takes a project directory DIR holding DIR/forbic.json and DIR/src/\n"));
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 2), try tool(init, &.{ "forbic", "run", dir, "--abandon" }, &out, &message));
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "usage: forbic "));
}

test "a project's diagnostics name its files where they are on disk, and its refusals the path refused" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "p");
    var tree = try temporary.dir.openDir(io, "p", .{});
    defer tree.close(io);
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    var room: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const dir = try std.mem.printSentinel(&room, "{s}/p", .{directory[0..length]}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [4096]u8 = undefined;
    var err_bytes: [2048]u8 = undefined;
    var expected_bytes: [2048]u8 = undefined;

    // Before it has a manifest, the directory is no project.
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "run", dir }, &out, &message));
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_bytes, "{s}: error: is not a Forbic project: it has no forbic.json naming its root module\n", .{dir}), message.buffered());

    // A compile error in the second file of a folder, a run error in a file of another folder,
    // and a path that names no folder: each where its file is.
    for ([_]struct { files: []const ProjectFile, status: u8, header: []const u8, excerpt: []const u8 }{
        .{
            .files = &.{
                .{ .path = "user@example.com/Hello/a.forb", .data = "A:i64 = 1\n" },
                .{ .path = "user@example.com/Hello/b.forb", .data = "# The second file of the folder.\nB:i64 = A + Missing\n" },
            },
            .status = 1,
            .header = "src/user@example.com/Hello/b.forb:2:13: error: name must refer to a parameter or earlier declaration\n",
            .excerpt = "  2 | B:i64 = A + Missing\n    |             ^~~~~~~\n",
        },
        .{
            .files = &.{
                .{ .path = "user@example.com/Hello/a.forb", .data = "Kit := import{/user@example.com/Kit}\nA:i64 = Kit.Fault()\n" },
                .{ .path = "user@example.com/Kit/k.forb", .data = "Zero:i64 = 0\nFault<public>()<computes>:i64 = 1 / Zero\n" },
            },
            .status = 1,
            .header = "src/user@example.com/Kit/k.forb:2:35: error: division by zero\n",
            .excerpt = "  2 | Fault<public>()<computes>:i64 = 1 / Zero\n    |                                   ^\n",
        },
        .{
            .files = &.{.{ .path = "user@example.com/Hello/a.forb", .data = "using{/user@example.com/Nowhere}\nA:i64 = 1\n" }},
            .status = 1,
            .header = "src/user@example.com/Hello/a.forb:1:7: error: module path is absent from the supplied inventory\n",
            .excerpt = "  1 | using{/user@example.com/Nowhere}\n    |       ^~~~~~~~~~~~~~~~~~~~~~~~~\n",
        },
    }) |case| {
        tree.deleteTree(io, "src") catch {};
        try writeProject(io, tree, case.files);
        for ([_][:0]const u8{ "--diagnostics=plain", "--diagnostics=excerpt" }) |style| {
            out = .fixed(&out_bytes);
            message = .fixed(&err_bytes);
            try std.testing.expectEqual(case.status, try tool(init, &.{ "forbic", "run", dir, style }, &out, &message));
            const excerpt = if (std.mem.endsWith(u8, style, "excerpt")) case.excerpt else "";
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_bytes, "{s}/{s}{s}", .{ dir, case.header, excerpt }), message.buffered());
        }
    }

    // A refusal of the walk names the path it refused, and nothing runs.
    tree.deleteTree(io, "src") catch {};
    try writeProject(io, tree, &.{ .{ .path = "user@example.com/Hello/a.forb", .data = "A:i64 = 1\n" }, .{ .path = "user@example.com/Hello/b.forb", .data = "B:i64 = 1 # \xfe\n" } });
    out = .fixed(&out_bytes);
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 1), try tool(init, &.{ "forbic", "check", dir }, &out, &message));
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_bytes, "{s}/src/user@example.com/Hello/b.forb: error: is not UTF-8 text\n", .{dir}), message.buffered());
    try std.testing.expectEqualStrings("", out.buffered());
}

test "a project's durable run: keys and a state directory as eval takes them, the journal recording the project's packet" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "p");
    var tree = try temporary.dir.openDir(io, "p", .{});
    defer tree.close(io);
    try writeProject(io, tree, &.{
        .{ .path = "user@example.com/Hello/stats.forb", .data = progress_source ++ "\n" },
        .{ .path = "user@example.com/Hello/notes.txt", .data = "not a source" },
    });
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &directory);
    var paths: [2][std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const dir = try std.mem.printSentinel(&paths[0], "{s}/p", .{directory[0..length]}, 0);
    const state = try std.mem.printSentinel(&paths[1], "{s}/state", .{directory[0..length]}, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [8192]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "run", dir, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":10}],\"Gained\":10,"));
    // The second run sees what the first saved; a file that is not a source changes nothing.
    try tree.writeFile(io, .{ .sub_path = "src/user@example.com/Hello/notes.txt", .data = "edited" });
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "run", dir, "--key", "alice", "--state", state }, &out, &message));
    try std.testing.expectEqualStrings("", message.buffered());
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "saved\n{\"Stats\":[{\"$key\":\"alice\"},{\"Level\":1,\"Experience\":20}],\"Gained\":20,"));
    // The journal names the program by the SHA-256 of the project's packet.
    const storage = try forbic.scratch.storage(project.Storage);
    defer forbic.scratch.release(storage);
    forbic.scratch.initialise(storage);
    var digest: [32]u8 = undefined;
    switch (storage.load(io, dir)) {
        .ok => |read| std.crypto.hash.sha2.Sha256.hash(read.packet, &digest, .{}),
        .refused => return error.TestUnexpectedResult,
    }
    out = .fixed(&out_bytes);
    try std.testing.expectEqual(@as(u8, 0), try tool(init, &.{ "forbic", "journal", "show", state }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), &std.fmt.bytesToHex(digest, .lower)) != null);
}

test "a host's request of a project is neither bundled nor given" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = undefined, .preopens = undefined };
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    try std.testing.expectError(error.InvalidProject, execute(init, .{ .command = .check, .file = "p", .project = true, .bundled = true }, &out, &message));
    try std.testing.expectError(error.InvalidProject, execute(init, .{ .command = .eval, .file = "p", .project = true, .given = "A:i64 = 1\n" }, &out, &message));
    try std.testing.expectError(error.InvalidProject, checkRequest(.{ .command = .check, .file = "p", .project = true, .bundled = true }));
    try checkRequest(.{ .command = .trace, .file = "p", .project = true });
}
