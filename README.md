# Forbic

Forbic is an **experimental** compiler and language based on Verse. It implements the semantics
of the [Book of Verse](https://github.com/verselang/book), the description of Epic Games'
language for Unreal Editor for Fortnite, with its own call-like syntax (`If(C, A, B)`,
`Block{...}`), deterministic replay, two independent machines and bounded capacities. It is built
for programs whose behaviour must be checked and bounded: configuration, policy and business rules
that an application runs on the user's behalf. A program is type- and effect-checked when it
compiles; two independent machines (a reference evaluator and a register VM) each admit the
compiled program on their own before it runs, and agree on every result; every run is bounded by
fuel and by fixed capacities, and failure rolls back what the failed region changed. Reading
files, writing files, keys that persist between runs and the clock are effects a host grants by
name, and a run that keeps state can survive a crash and be resumed from its journal, replaying
to the same result.

Forbic is written in Zig (exactly 0.17.0) and has no other dependencies. This repository is the
whole language as one Zig package: the compiler and both machines, the `forbic` command-line
tool, the embedding API for Zig applications, the formatter, the conformance tests and the
deterministic simulation that tests the journal and store.

**Attribution.** The Book of Verse is published by Epic Games under CC0-1.0; Forbic follows its
semantics and cites its chapters. "Verse" is Epic Games' language. Forbic is not affiliated with
or endorsed by Epic Games.

## How it is built

Forbic is an experiment in AI-assisted development. It was built by AI agents (Anthropic's
Claude models and OpenAI's GPT/Sol models), orchestrated in T3 Code under the owner's direction.
The guard rails are independent cross-model reviews of every change, scope checks against the
Book, and deterministic simulation testing of the machines, the journal and the store, besides
the unit, conformance and scale tests.

## Status

An experimental prototype, version 0.0.1. Milestone M1 is complete:

- Book parity: every feature of the Book of Verse is either implemented or ruled out by a
  recorded decision, with the spelling and the differences listed in
  [docs/book-feature-matrix.md](docs/book-feature-matrix.md). Forbic does not aim to run Book
  programs unchanged.
- Two review rounds over the whole language, with their findings fixed.
- One Zig package with an embedding API ([docs/embedding.md](docs/embedding.md)), and projects
  of several files and folders run with `forbic run DIR`.
- The package builds and its tests pass on Windows and on Linux.

The language, the file formats and the API may still change.

## Licence

Copyright (c) 2026 Ryan Drazga. Licensed under either of

- the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)), or
- the MIT License ([LICENSE-MIT](LICENSE-MIT)),

at your option. Unless you state otherwise, any contribution you intentionally submit for
inclusion in this work, as defined in the Apache-2.0 licence, is dual licensed as above, without
any additional terms or conditions.

Forbic was developed inside ForbOS, a Linux desktop project that uses it for its configuration
and policy. A few documents name ForbOS files (paths such as `desktop/config/...` or
`src/tooling/response.zig`); those are files of that repository, not of this package.

## Build

On Windows, enable long paths before cloning (`git config --global core.longpaths true`): a few
test fixtures sit in deep directories of the persistent store.

You need Zig 0.17.0 exactly (the build refuses any other version) and nothing else: the package
has no dependencies and builds offline. From the repository root:

```sh
zig build                                # installs zig-out/bin/forbic
zig build test                           # language tests (small profile) and host tests
zig build integration -Doptimize=ReleaseSafe   # the conformance scenarios of the forbic tool
zig build check                          # compiles everything, tests included, without running
```

The other steps are `test-program` (the language tests at the large `program` profile, a few
minutes), `dst-test` and `dst` (the deterministic simulation), `forbic-example` (the example
embedding host) and `forbic` (runs the tool: `zig build forbic -- eval FILE`). `-Dprofile=bootstrap`
builds the tool with the small capacities the tests use; the default, `program`, is for real
programs.

## Quick start

```forbic
# hello.forb
Name:string = "world"
Greet(Who:string)<computes>:string = "Hello, {Who}!"
Greeting:string = Greet(Name)
Shown:tuple() = Print(Greeting)
```

```text
$ forbic eval hello.forb
Hello, world!
{"Name":"world","Greeting":"Hello, world!","Shown":[]}
```

`eval` prints what the program printed, then its bindings as JSON. `forbic check FILE` compiles,
admits and runs it and prints a one-line summary; a program that does not compile, or fails as
it runs, gets a diagnostic (`--diagnostics=excerpt` adds the source line). A project of several
files and folders is a directory: `forbic run DIR` and `forbic check DIR` (see
[examples/hello-project](examples/hello-project/README.md)).

## Documentation

- [docs/getting-started.md](docs/getting-started.md): install, build, a first program, a first
  project, a first embedding host.
- [docs/README.md](docs/README.md): the index of the language reference and the guides.
- [docs/pure-core.md](docs/pure-core.md): the language reference.
- [docs/embedding.md](docs/embedding.md): running Forbic programs from a Zig application.
- [docs/formatting.md](docs/formatting.md): `forbic fmt`.
- [apps/forbic/README.md](apps/forbic/README.md): the `forbic` tool, command by command.

## Layout

| Path | What it holds |
| --- | --- |
| `src/forbic/` | the language: lexer, compiler, both machines, reports (module `forbic`) |
| `src/tooling/` | the host services: the `forbic` command line, journal, store, inputs and outputs, projects (module `forbic_host`) |
| `src/embed/` | the embedding API (module `forbic_embed`) |
| `src/dst/` | the deterministic simulation of the language, journal and store (module `forbic_dst`) |
| `apps/forbic/` | the `forbic` tool; `apps/forbic-example/` an example embedding host; `apps/dst/` the simulator |
| `tests/` | conformance fixtures and goldens, the example host's expected output, test projects |
| `examples/` | sample projects |
| `docs/` | the reference and the guides (the design records, `docs/rfcs/`, are kept privately) |
