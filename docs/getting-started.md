# Getting started with Forbic

This guide takes you from nothing to a running program, a project of several files and a Zig
application that runs Forbic programs. It assumes you can use a terminal; it does not assume you
know Verse, Zig or the project Forbic came from. Forbic follows the language described in the
[Book of Verse](https://github.com/verselang/book), the community's description of Epic Games'
Verse, with its own spelling where it differs; you do not need to read the Book first. The
commands are written for a POSIX shell (one command per line); on Windows they work the same in
PowerShell or Git Bash, with `zig-out\bin\forbic.exe` for the tool.

## 1. Install Zig 0.17.0

Forbic is written in Zig and builds with exactly one version of it, 0.17.0; the build stops
with "Forbic requires Zig 0.17.0." under any other. Download the archive for your system from
[ziglang.org/download](https://ziglang.org/download/), unpack it anywhere and put the directory
holding the `zig` executable on your `PATH`. Check:

```sh
zig version
# 0.17.0
```

Nothing else is needed: no package manager, no network access while building, no C compiler.

## 2. Build the `forbic` tool

Forbic is the `forbic/` directory: a Zig package with its own `build.zig`. From it:

```sh
zig build
zig-out/bin/forbic --version
# forbic 0.0.1 (Forbic pure-core prototype; Zig 0.17.0)
```

`zig build` installs the tool into `zig-out/bin/`. Add `-Doptimize=ReleaseSafe` for a faster
tool that keeps its safety checks. The tool is built at the `program` profile, the capacities for
real programs (the largest source, the most nodes, the deepest recursion, and so on, are fixed
numbers; [RFC-0048](rfcs/0048-capacity-profiles.md) lists them). The package's own tests run at
the smaller `bootstrap` profile:

```sh
zig build test -Doptimize=ReleaseSafe            # a few minutes the first time
zig build integration -Doptimize=ReleaseSafe     # the tool's conformance scenarios
```

The examples below call the tool `forbic`; put `zig-out/bin` on your `PATH` or write the path.

## 3. A first program

A Forbic program is a file of declarations, one per line. Write `hello.forb`:

```forbic
# hello.forb: a binding, a function and a printed line.
Name:string = "world"
Greet(Who:string)<computes>:string = "Hello, {Who}!"
Greeting:string = Greet(Name)
Shown:tuple() = Print(Greeting)
```

Every top-level binding has a type (`Name:string`). `Greet` is a function: its parameters, its
effects in angle brackets (`<computes>`: it may compute and may not do anything else) and its
result type. `"Hello, {Who}!"` interpolates. `Print` is an effect a program may use at the top
level; its value is the empty tuple.

```text
$ forbic eval hello.forb
Hello, world!
{"Name":"world","Greeting":"Hello, world!","Shown":[]}
$ forbic check hello.forb
ok: 3 bindings, 3 typed nodes
```

`eval` runs the program and prints what it printed, then every binding as JSON. `check` does
the same work and prints only a summary, which is what you want in a script. That work is: compile
(parse and check types and effects), admit (each of the two machines that can run a program, a
reference evaluator and a register VM, checks the compiled program on its own before running
it), and run. `forbic trace FILE` shows where failures happened, `forbic inspect FILE` the
compiled bytecode, and `forbic qualify FILE` every name in its fully qualified form.

When something is wrong, the tool says where. Write `bad.forb`, a program that divides by
zero, and run it; `--diagnostics=excerpt` adds the line:

```forbic
Count:i64 = 1 / 0
```

```text
$ forbic eval bad.forb --diagnostics=excerpt
bad.forb:1:15: error: division by zero
  1 | Count:i64 = 1 / 0
    |               ^
```

A program that does not compile exits with status 1, as does one that fails as it runs; a
command line the tool does not take exits with 2 and prints the usage (`-` is not a source:
standard input is read by `fmt -` and `--read NAME=-` only, and a file called `-` is `./-`).
Finally, `forbic fmt FILE` lays a file out in the canonical style
([formatting.md](formatting.md)), and `forbic fmt --check FILE` names the files that would change.

The language is described in [pure-core.md](pure-core.md), section by section, with the RFC that
introduced each form. Where Forbic differs from the Book of Verse, and why, is in
[book-feature-matrix.md](book-feature-matrix.md) and [RFC-0067](rfcs/0067-book-divergences.md).

## 4. A first project

A program of more than a few files is a project: a directory with a manifest, `forbic.json`, and
its sources under `src/`. The sample is [examples/hello-project](../examples/hello-project) (the
commands below run from the `forbic/` directory):

```text
hello-project/
  forbic.json                                    {"root": "/hello@example.com/Hello"}
  src/
    hello@example.com/
      Hello/
        main.forb                              the root module's first file
        visits.forb                            its second file
      Text/
        greet.forb                             another module
```

Each folder under `src/` is a module named by its path: `src/hello@example.com/Text/` is the
module `/hello@example.com/Text`. The first segment is a domain you own (any name with an `@` or
a `.` will do; the path only has to be unique among your modules), the others are names. The
files of one folder are one module: `visits.forb` uses `Greeting`, declared in `main.forb`,
without importing it, and the files are read in the byte order of their names. Another folder
is reached by its path:

```forbic
# main.forb
Text := import{/hello@example.com/Text}
Greeting<public>:string = Text.Greet("world")
```

`forbic.json` names the root module, whose bindings the run prints. Run the project by naming its
directory; every option of `eval` works the same way:

```text
$ forbic check examples/hello-project
ok: 4 bindings, 20 typed nodes
$ forbic run examples/hello-project
Hello, world! (visit 0)
{"Greeting":"Hello, world!","Visits":[],"Visit":0,"Shown":[]}
```

`run` is another name for `eval`; `check`, `eval`, `trace`, `inspect` and `qualify` all take a
project directory where they take a file. A diagnostic names the file as it is on disk:

```text
$ forbic check tests/projects/hello-error --diagnostics=excerpt
tests/projects/hello-error/src/hello@example.com/Hello/shout.forb:2:25: error: name must refer to a parameter or earlier declaration
  2 | Loud<public>:string = "{Greting}!"
    |                         ^~~~~~~
```

### State that outlives a run

`visits.forb` keeps a count per visitor in a persistent cell: a module variable of type
`weak_map(persistent_key, visit)`. A program reaches a key only when the host grants it, by name
(`--key visitor`), and the value is kept between runs only in a state directory the host names
(`--state DIR`):

```text
$ forbic run examples/hello-project --key visitor --state my-state
Hello, world! (visit 1)
...
$ forbic run examples/hello-project --key visitor --state my-state
Hello, world! (visit 2)
...
```

The state directory holds a journal of the run and a store of the persistent cells. If the
process is killed during a run, the next run with the same directory refuses to start until you
add `--resume` (finish the interrupted run from its journal) or `--abandon` (keep what it had
committed and drop the rest). `forbic store show my-state` and `forbic journal show my-state`
print what the directory holds. Keep the state directory outside `src/`.

### What a project may hold

- `forbic.json` is one JSON object with one field, `root`, a module path. Any other field is
  refused, so that a manifest written for a later version is not misread by this one.
- Only files ending in `.forb` are sources; other files (notes, a README) are left out, and so
  is every name that starts with `.`.
- No link is followed. `forbic.json`, `src/` and every entry under `src/` that the walk reads may
  not be a symbolic link (on Windows, also a junction or other reparse point: a folder synced
  by a cloud service can be one): every source is a file of the directory you named. Entries
  beside `src/` and names starting with `.` are not read, so they may be anything.
- A folder that holds `.forb` files is a module, so its path under `src/` must be a module
  path: a domain (letters, digits, `_`, `.`, `@` and `-`), then names (a letter or `_`, then
  letters, digits and `_`). `src/hello@example.com/Hello` is one; `src/hello@example.com/my-lib`
  is not. A source directly in `src/` belongs to no module and is refused.
- The walk is bounded by the profile: at most `module_files` sources (16,384 at `program`), twice
  that many entries in all, paths under `src/` of at most `module_path_bytes` (1,024), and the
  sources together within `source_bytes` (8 MiB, counting a newline between the files of each
  folder, which are joined into one module). Past a bound the project is refused with the
  bound named, and nothing runs.

The rules for modules, imports and `using` are in [pure-core.md](pure-core.md) ("Module paths and
folder modules") and [RFC-0093](rfcs/0093-module-paths.md); the layout is
[RFC-0095](rfcs/0095-project-layout.md).

## 5. A first embedding host

To run Forbic programs from your own Zig application (a service that applies business rules, a
desktop application with user policies, a game's rules), depend on the package and use its
`forbic_embed` module. Make a Zig project beside the `forbic/` directory (from `forbic/`, go up one
level first), with a copy of the sample project to run:

```sh
cd ..
mkdir my-host
cd my-host
zig init
cp -r ../forbic/examples .
```

In the `build.zig.zon` that `zig init` wrote, add the package to `.dependencies = .{ ... }`:

```zig
.forbic = .{ .path = "../forbic" },
```

In its `build.zig`, give the executable the module, just before `b.installArtifact(exe);`:

```zig
const forbic = b.dependency("forbic", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("forbic_embed", forbic.module("forbic_embed"));
```

Then replace `src/main.zig` with a host that compiles once, prepares once, and could run the
program as often as it likes (here, once), and run it with `zig build run`:

```zig
const std = @import("std");
const embed = @import("forbic_embed");
pub const forbic_profile_name = "program";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const compiler = try embed.Compiler.create(gpa);
    defer compiler.destroy();
    const compiled = try compiler.compile(.{ .project = .{ .io = init.io, .path = "examples/hello-project" } }, .{});
    const program = (try embed.prepare(gpa, compiled.ok)).ok;
    defer program.destroy();
    const worker = try embed.Worker.create(gpa);
    defer worker.destroy();
    const completed = (try program.run(worker, .{})).completed;
    std.debug.print("{s}\n", .{(try completed.value("Greeting")).?.string});
}
```

```text
$ zig build run
Hello, world!
```

The printed line `Hello, world! (visit 0)` of the `forbic` tool does not appear: a run sends its
`Print` lines where the host says (`RunOptions.output`), and this host says nowhere. A real host
handles the `failed` and `refused` cases instead of taking `.ok`: every problem a
program or its input can cause is a value, never a crash. Your application can also give
programs functions of its own (natives), readers and writers, keys and a state directory.
[embedding.md](embedding.md) is the guide and the API reference, and
[apps/forbic-example](../apps/forbic-example/README.md) is a complete host, a small orders service,
which you can run from the `forbic/` directory:

```sh
zig build forbic-example -- zig-out/forbic-example
```

## Where next

- [pure-core.md](pure-core.md): the language reference.
- [apps/forbic/README.md](../apps/forbic/README.md): every command and option of the tool.
- [README.md](README.md): the index of the documents and RFCs.
