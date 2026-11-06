# Embedding Forbic in a Zig application

Forbic is a small, verifiable policy language: a program is checked when it compiles, admitted
independently by two machines (a reference evaluator and a VM), and every run is bounded by fuel
and by fixed capacities. This guide is for someone who writes a Zig application (a CRM back end,
the policy layer of a desktop application, the rules of a game) and wants that application to
run Forbic programs. The language itself is described in [pure-core.md](pure-core.md); the
`forbic` command-line tool in [apps/forbic/README.md](../apps/forbic/README.md).

The whole API is one file, `src/embed/forbic_embed.zig`, the `forbic_embed` module of the
`forbic/` package. It imports the language and the Forbic host services as the package's `forbic`
and `forbic_host` modules only, never the rest of this repository; the package's `zig build check`
proves it by compiling it in a module that reaches nothing else. A complete example host, a small
orders service, is in [apps/forbic-example](../apps/forbic-example/README.md).

## Getting started

Use Zig 0.17.0. Depend on the `forbic/` package (in `build.zig.zon`,
`.dependencies = .{ .forbic = .{ .path = "forbic" } }`, or wherever your copy is) and import its
`forbic_embed` module into your executable:

```zig
const forbic = b.dependency("forbic", .{ .target = target, .optimize = optimize });
const embedding = forbic.module("forbic_embed");
const exe = b.addExecutable(.{ .name = "my-host", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "forbic_embed", .module = embedding }},
}) });
```

Your root source file chooses the capacity profile, as the `forbic` tool does: `program` for real
programs, `bootstrap` (the default when you declare nothing) for small, fast tests.

```zig
pub const forbic_profile_name = "program";
```

The smallest host compiles a program, prepares it, runs it and reads a value:

```zig
const std = @import("std");
const embed = @import("forbic_embed");
pub const forbic_profile_name = "program";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const compiler = try embed.Compiler.create(gpa);
    defer compiler.destroy();
    const compiled = try compiler.compile(.{ .text = .{ .name = "hello.forb", .bytes = "Answer<public>:i64 = 6 * 7\n" } }, .{});
    const program = (try embed.prepare(gpa, compiled.ok)).ok;
    defer program.destroy();
    const worker = try embed.Worker.create(gpa);
    defer worker.destroy();
    const completed = (try program.run(worker, .{})).completed;
    std.debug.print("{d}\n", .{(try completed.value("Answer")).?.integer});
}
```

A real host handles each `failed` and `refused` case instead of taking `.ok`: they are values
(below), never panics.

## The life of a program

1. **Natives** (optional). A `Natives` table holds the standard natives and yours.
2. **Compile.** A `Compiler` turns a `Source` into a `Compilation` or a `Failure`.
3. **Prepare.** `prepare` admits the compilation on both machines and copies it into a
   `Program` you own. A program is immutable: any number of threads may run it at once.
4. **Run.** `Program.run` runs it on a `Worker` (one per thread) with `RunOptions`: fuel, seed,
   clock, tick rate, trace mode, grants and where printed lines go. The `Outcome` is a
   `Completed` run or a `Diagnostic`.
5. **Durable runs** (optional). `Program.runDurable` runs it with a state directory: persistent
   cells are loaded from and saved to a store there, and a journal lets a crashed run be resumed
   or abandoned.
6. **Cache** (optional). A `Cache` keeps prepared programs by identity, within ceilings you set.

## API reference

Everything below is in `forbic_embed` (`embed` in the examples). Errors are closed error sets,
and everything that can go wrong because of a program or its input is a value. Nothing asserts
on what a host passes in.

### Natives

A native is an ordinary Zig function whose first parameter is `*embed.native.Context`. Its Forbic
signature is derived from its Zig types at compile time (`i64`, `bool` for `logic`, `f64` for
`float`, `[]const u8` for `string`, `native.Array(T)`, an optional result for `option(T)`,
`native.ArrayOut(T)` for an array result, `native.Error!T` for a native that can fail).
`native.entry(id, function, cost)` makes a pure native, `native.effectEntry(..., effect)` one that
acts (`output`), draws (`draw`) or reads (`input`). The cost is charged before each call:
`base + per_element * N`, where `N` counts array elements and string bytes of the arguments.

- `Natives.init(storage: []native.Entry) InitError!Natives`: the table lives in your storage,
  whose length is its capacity (at least `standard_natives`, at most `max_natives`). It starts
  with the standard natives. Errors: `StorageTooSmall`, `StorageTooLarge`.
- `register(entry) RegisterError!void`: a native that needs nothing of the host.
- `registerWith(comptime Host, host: *const Host, entry) RegisterError!void`: a native that reads
  `host` through `context.hostContext(Host)`, which returns `?*const Host` and is null when the
  entry was registered with another type. Errors of both: `TooManyNatives` (storage full),
  `DuplicateNative` (a name already held, the standard ones included), `InvalidNative` (a name
  that is not 1 to 128 bytes of UTF-8; a signature or effect the machines would not admit, such
  as an `output` native that returns a value; an entry that already carries a context).
- `table() []const native.Entry`.

A program binds a native by its name: `TaxRate := native{"orders.tax_rate"}`. A call against
its signature is refused when the program compiles (`type_mismatch`, `argument_count`), and a
name the table does not have is `unknown_native`.

**What a native must be.** A pure native is a function of its arguments and of its context: the
VM runs it, and the report of a run runs it again to check the run, so it must give the same
result every time. Keep its context alive while any program compiled with the table can run, and
unchanged while a run, or a report of one, can call it. Something that changes between runs (a
clock, a file, a database) is not a context: give it to the program as a grant (a reader, or a
persistent key), which the run records, or rebuild the table and prepare the program again.
Effect natives describe actions and draws through the context (`act`, `draw`, `input`) and never
touch the world themselves: the host commits what the run commits.

### Compiling

- `Compiler.create(gpa) error{OutOfMemory}!*Compiler` and `destroy()`. The compiler's storage is
  as large as the profile's capacities but is reserved, not touched, until a program uses it.
  One compiler per thread.
- `Source` is one of: `.text = .{ .name, .bytes }` (source you hold); `.file = .{ .io, .path }`
  (a source file); `.packet = .{ .name, .bytes }` and `.packet_file = .{ .io, .path }` (a module
  bundle packet, the JSON `forbic eval FILE --bundle` reads); `.files = .{ .root, .files }` (the
  files of a bundle as `embed.File{ .path, .source }`). A bundle whose `root` is a module path,
  such as `/acme@example.com/Orders`, is a folder tree: each folder's files, in the byte order
  of their names, are one module (RFC-0093). `.project = .{ .io, .path }` is a project
  directory, read as `forbic run DIR` reads it (RFC-0095): `forbic.json` names the root, `src/`
  holds the tree, and the program is that of its packet (the same identity as its files given as
  `.files`); a diagnostic's `path` is then the file's path in the tree, under `DIR/src/`.
- `compile(source, CompileOptions{ .natives = &natives }) error{OutOfMemory}!Compiled`, where
  `Compiled` is `.ok: Compilation` or `.failed: Failure`. The source is read once. Without a
  table, only the standard natives are visible.
- `identify(source, options) error{OutOfMemory}!Identified`: the program's identity without
  compiling it (below).
- Your bytes (the name, the text, the packet, the files and their list) are borrowed only until
  `compile`, `identify` or `Cache.obtain` returns: the compiler keeps copies of what it holds on
  to, so you may free or reuse them then. A source larger than the profile allows is refused
  before more of it is copied: a text longer than its `source_bytes` with `source_limit` at its
  start, a packet longer than a packet can be, or files that no bundle that compiles could hold
  (more than its files, more path bytes than they can have, more than `source_bytes` of
  sources), with `invalid_bundle` (`BundleLimit`), for `identify` as for `compile`.
- `Compilation` and `Failure` borrow their compiler, and those copies, until the compiler's next
  use: its next `compile`, `identify` or `Cache.obtain`, successful or not, which reads into the
  same buffers. `current()` says whether a compilation still holds; `prepare` refuses one that
  does not. It carries `program` (the IR, for inspection), `name()` and `identity`.
- `Failure` is `.unreadable` (the file system's error, by name), `.invalid_bundle`
  (`InvalidBundle` or `BundleLimit`), `.project` (a project directory refused before anything is
  compiled: `refusal.reason`, `refusal.path()`) or `.diagnostic`. `failure.code()` is the diagnostic's code
  (null when nothing was compiled), and `failure.write(writer, style)` writes exactly what the
  `forbic` tool writes on standard error for the same source, except that for a project the tool
  writes `DIR/src/` before the path of the file in the tree.
- `Diagnostic` has `path` and `source` (the file or module it points into; for a bundle, the file
  that holds the error), `code()`, `message()`, `location()` (1-based line and byte column) and
  `write(writer, style)`. `Style` is `.plain` (`PATH:LINE:COLUMN: error: MESSAGE`) or `.excerpt`
  (the same header, then the source lines with the place underlined). The style is a parameter
  of each write: nothing is global.

### Preparing

- `prepare(gpa, compilation) PrepareError!Preparation`: `.ok: *Program` or
  `.refused: Refusal{ .by, .diagnostic }`. The reference evaluator admits the IR and the VM admits
  the bytecode, each on its own (RFC-0088, A1 and A3). A program the compiler produced is
  refused only when the toolchain, or a forged compilation, is at fault. Errors: `OutOfMemory`,
  `StaleCompilation`.
- A `Program` owns one copy of everything it needs: the IR, the bytecode, the register types,
  the native table (names, signatures, functions and contexts), its name and the source a
  durable run compiles again. Nothing you passed in is borrowed after `prepare` returns, except
  native functions and contexts. Methods: `identity()`, `name()`, `ir()`, `bytes()` (everything
  it holds), `run`, `runDurable`, `destroy()`.

### Running

- `Worker.create(gpa) error{OutOfMemory}!*Worker` and `destroy()`: the mutable storage of runs,
  one per thread, reserved and touched only as far as a run uses it.
- `Program.run(worker, RunOptions) RunError!Outcome`. Every choice is given again for every run:
  nothing of an earlier run reaches the next.
  - `fuel` (default `default_fuel`, the profile's evaluation work): the work a run may do before
    it ends with `work_limit`.
  - `seed` (default `default_seed`): the run's random stream; one seed, one stream.
  - `tick_rate` (1 to 1,000,000, default 60) and `clock`: `.{ .start = seconds }` (the default,
    `0`) reads `start + tick / tick_rate`, so that a run can be repeated; `.{ .real = io }` reads
    the host's real-time clock.
  - `trace`: `.digest` (the default: a count and digest of the steps; reports are checked by
    replaying the run), `.full` (every step kept, within the profile's capacity) or `.off`.
  - `grants`, at most `grant_capacity`: `.{ .reader = .{ .name, .from = *std.Io.Reader } }`, read
    a line at a time by `OpenReader["name"]`; `.{ .writer = .{ .name, .to = *std.Io.Writer } }`,
    to which `OpenWriter["name"]` appends committed lines; `.{ .key = "name" }`, a persistent key
    (`GetPersistentKey["name"]`). Names are 1 to 128 bytes of UTF-8, once per kind.
  - `output: ?*std.Io.Writer`: where each committed `Print` line goes, with a newline.
  Errors: `InvalidTickRate`, `InvalidClock` (a start that is not finite), `InvalidGrants`,
  `SharedReader` (one reader stream given twice).
- Output is committed, never speculative: a line is written when nothing can undo it, so what a
  failed region printed is never written. You flush your writers. A writer that refuses a line
  ends the run with `effect_commit_failed`.
- Without a state directory the store is empty: a persistent cell loads nothing and a run saves
  nothing (RFC-0087, S3). That is a quote, a test or a dry run.
- `Outcome` is `.completed: Completed` or `.failed: Diagnostic` (a run-time error of the program,
  running out of fuel or of a capacity included), located in the program's source.
- `Completed` borrows its worker until the worker's next call of `run` (even one refused), and
  until a report of it whose replay stops short (`ReportLimit`, `InvalidExecution`,
  `OutOfMemory`: the replay rebuilt the run's strings only part way); after that every method
  returns `error.Stale`. `value(name) error{Stale}!?Value` gives a top-level binding's value
  (`.integer`, `.float`, `.logic`, `.string`, or `.other` for arrays, maps, structs and instances),
  null when there is none or the run did not compute it; `effects()` the run's effect record;
  `writeValues(writer)` the JSON object `forbic eval` prints; `writeTrace(writer)` the report
  `forbic trace` prints. Both reports are validated before a byte is written, a `digest` run's by
  replaying it. `ReportError`: `Stale`, `NoTrace` (an `off` run), `ReportLimit`,
  `InvalidExecution` (a run that does not replay as reported: a defect), `WriteFailed`,
  `OutOfMemory`.

### Threading

A `Program` is immutable after `prepare`: share it freely across threads. Everything a run
changes (fuel, effects, grants, inputs, cells, scheduler, pools, undo records, the strings it
builds) is in its `Worker`, which is never shared by two runs at once. A `Compiler` is one
thread's. A `Cache` is not thread-safe: guard it with a mutex, and share the programs it lends.
Parallelism is between runs; a run itself is sequential and deterministic.

### Durable runs: persistence and recovery

`Program.runDurable(io, gpa, DurableOptions, visitor) DurableError!DurableOutcome` is the run
`forbic eval FILE --state DIR` makes:

- `state`: the state directory. The run takes its lock (a second run on it is refused), writes a
  journal of every input it takes and every action it commits, loads the persistent cells of its
  keys from the store there, and when it ends publishes the writes of those cells as the store's
  next generation and its writers' lines to their files.
- `intent`: `.start` (refuses a directory that holds an unfinished run), `.resume_run` (runs an
  unfinished journal again from the start, served its sealed inputs, checking that it does
  what the journal says, then goes on) or `.abandon` (runs nothing; publishes what was sealed).
- `seed`, `tick_rate`: null takes the default to start, or the journal's to resume; a value given
  to a resumed run must be the journal's. `clock`: a start in seconds, or null for real time.
- `grants`: `FileGrant` is `.reader = .{ .name, .path }`, `.writer = .{ .name, .path }` or
  `.key = name`. Readers and writers are files, so that a resumed run reads on from where its
  journal sealed them.
- `output` receives the `Print` lines as the journal makes them durable; `messages` receives
  diagnostics and notes as the `forbic` tool writes them, in `style`.
- `visitor` is null or a pointer to a value with `pub fn completed(self, embed.Completed) !void`,
  called once the journal has ended and the store is published. Its `Completed` lives only for
  that call (and is spent, as above, by a report that stops short).

`DurableOutcome` is `.completed`, `.nothing_ran` (abandoned, or nothing to do) or
`.failed: DurableFailure`, whose `cause` is `.program` (with the diagnostic's `code`), `.state`
(the state directory, its journal or its store refused: in use, unfinished, of another run,
damaged), `.visitor` or `.host` (with `error_name`), and whose `note()` is the first line written
to `messages`.
`DurableError`: `InvalidTickRate`, `InvalidClock`, `InvalidGrants`, `OutOfMemory`.

What survives a crash, and what a host does about it:

- Inside a run, every change to the program's state is undone when its region fails: that is the
  VM's rollback. An action on the world (a printed line, a writer's line, a saved cell) is not
  undone: it is committed only when nothing can undo it, sealed in the journal, and published
  when the run ends.
- If the process dies during a durable run, the directory holds an unfinished journal. The next
  run with `.start` is refused with `run_unfinished`. Run with `.resume_run` to finish it (the
  program must be the same; a different program, seed or grants is `recovery_mismatch`), or with
  `.abandon` to end it, keeping only what it had sealed.
- A durable run compiles its program again from the source the `Program` kept (the store and the
  journal name the program by the SHA-256 of that source). In M1 a durable run does not run on the
  prepared handle; in-memory runs do.
- `forbic store show DIR` and `forbic journal show DIR` print what a directory holds.

### Identity and the cache (RFC-0088, A2 and A5)

`Identity` is a domain-separated, length-delimited SHA-256 of everything that decides what a
compilation is: the source's name and bytes (or a bundle's root and its modules' paths and bytes,
in order), the compiler options, the toolchain build (version, Zig version, optimization mode,
target), the shapes of the IR and bytecode types, every capacity of the profile, and the native
table's names, signatures, costs and effects, with the type of each native's context. It hashes
canonical fields, never pointers: two tables whose functions or contexts are at other addresses
have one identity. `eql` and `hex` compare and print it.

`Cache.create(gpa, CacheLimits{ .entries, .bytes, .leases })` makes a bounded cache; the default
`entries` and `bytes` are zero, which keeps nothing. At most `max_cache_entries` entries; `leases`
(default 64, 1 to `max_cache_leases`) bounds the leases out at once. Errors: `TooManyEntries`,
`TooManyLeases`, `OutOfMemory`. Do not move a cache: leases name it by address.

- `obtain(compiler, source, options) error{ OutOfMemory, TooManyLeases }!Obtained`: `.ok: Lease`,
  `.failed: Failure` or `.refused: Refusal`. Each lease is a ticket of its own. A program of the same identity and the same native functions
  and contexts is lent from the cache (`lease.hit`); otherwise the source is compiled and
  prepared, and kept when it fits.
- Inserting into a full cache evicts unlent entries, oldest inserted first (a hit does not make
  an entry younger), if that makes room for the entries and the bytes; otherwise nothing is
  evicted and the program is the lease's alone (`lease.kept` is false). A program larger than the
  byte ceiling is never kept. A lent program is pinned until every lease of it is given back.
- `release(lease) error{UnknownLease}!void`: gives a lease back to the cache that lent it, once;
  a second release of it, or a release to another cache, is refused and changes nothing. A lease
  the cache did not keep destroys its program.
- `usage()`: entries, bytes, pinned entries and leases out. `destroy() error{InUse}!void` refuses
  while any lease is out.

## Bounds

Every capacity is the profile's (`src/forbic/profile.zig`) or yours: the native table's
storage, the cache's entries and bytes, the buffers of your readers and writers. Storage sized by a
capacity is reserved and costs nothing until it is used. A run is bounded by its fuel and by the
profile's capacities; exhausting either is a diagnostic, never a crash or an unbounded
allocation. A source file is at most the profile's `source_bytes`, a packet at most
`bundle_packet.max_packet_bytes`.

## Not yet

A VM-only preparation for hosts that never use the reference evaluator, durable runs on the
prepared handle and reference-evaluator workers are not part of this API yet. (Project
directories are: `Source.project`, RFC-0095.)
