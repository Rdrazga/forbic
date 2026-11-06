# Forbic documentation

Start with [getting-started.md](getting-started.md). Paths in these documents are relative to the
package root (the directory holding `build.zig`), so `src/forbic/compiler.zig` is a file of the
package. Forbic was developed inside ForbOS, a Linux desktop project that uses it for its
configuration and policy; a path under `desktop/`, `src/extensions/`, `src/ui/` or
`apps/extension-host/`, and ForbOS's own `src/root.zig`, `src/simulation/` and
`src/tooling/response.zig`, names a file of that repository, kept as an example of a host.

## Guides

- [getting-started.md](getting-started.md): install Zig, build, a first program, a first project,
  a first embedding host.
- [embedding.md](embedding.md): running Forbic from a Zig application, with the API reference.
- [formatting.md](formatting.md): `forbic fmt`, its layout rules and what it never changes.
- [../apps/forbic/README.md](../apps/forbic/README.md): the `forbic` tool, command by command.
- [../examples/hello-project/README.md](../examples/hello-project/README.md): the sample project.

## Reference

- [pure-core.md](pure-core.md): the language as implemented, section by section, each with the
  RFC that introduced it. This is the reference; where it and an RFC differ, it is current.
- [book-feature-matrix.md](book-feature-matrix.md): every feature of the Book of Verse, whether
  Forbic has it, with the same spelling or another, or leaves it out, with the reason and the
  Book's source.
- [rfcs/README.md](rfcs/README.md): the RFCs, one per increment, with the reasoning, the limits
  and the tests behind each rule. [RFC-0067](rfcs/0067-book-divergences.md) collects the
  deliberate differences from the Book.

## History and plans

- [parity-plan.md](parity-plan.md): the plan that brought Forbic to the Book's features, with
  each increment's definition of done.
- [book-compatibility.md](book-compatibility.md): the earlier gap analysis against the Book.
- [completion.md](completion.md): the earlier completion track.
