# Forbic deterministic simulator

Developer tool (`forbic-dst`): the language and journal campaigns of module `forbic_dst`
(`src/dst/`): seeded workloads of both machines against a model, journaled programs
crashed at every disk operation, and their recovery. ForbOS's `forbos-dst` runs the same
suites, under the same names and seeds, among its own.

```sh
zig build dst-test -Doptimize=ReleaseSafe
zig build dst -- --seed 17 --steps 1000 --suite all
zig build dst-install -Doptimize=ReleaseSafe
```

Seed is an unsigned 64-bit decimal integer; steps are 1..1,000,000. Both suites run by
default; select `language` or `journal` with `--suite`, `swarm` or `performance` with
`--mode`. Output is JSON Lines: a start record, then one report per suite. Exit 1 means an
oracle or campaign failure (a failure record and its trace follow); exit 2 means invalid
arguments. Debug and ReleaseSafe keep assertions active.
