# Forbic contributor and agent instructions

## Context

- Read `README.md`, `docs/README.md` and `docs/pure-core.md` (the language reference) first.
  `docs/book-feature-matrix.md` records how each Book of Verse feature is implemented or why it is
  not.
- "Verse" means Epic Games' language and the Book of Verse; this language is Forbic. Cite Book
  chapters for semantics; never copy Book programs as Forbic tests without adapting the spelling.
- Design records (RFCs) live in `docs/rfcs/` and planning notes in `notes/`. Both are kept in the
  local checkout and are not committed (see `.gitignore`); published documents may link to them.
- Book parity is complete (M1). New language features start as a proposal in `notes/proposals/`
  and an RFC before code.

## Toolchain and checks

- Use Zig exactly 0.17.0; the build refuses any other version. The package has no dependencies.
- `zig build check` compiles everything, tests included. `zig build test` runs the language tests
  at the small profile and the host tests. `zig build integration -Doptimize=ReleaseSafe` runs
  the conformance scenarios of the `forbic` tool. `zig build test-program` runs the language tests
  at the `program` profile (slow; run it once per batch of changes, filtered to the area you
  changed while you work). `zig build dst-test` and `zig build dst` run the deterministic
  simulation.
- Changes to the machines, admission, reclamation, the journal or replay run the whole
  `test-program` suite and both DST steps before they are delivered.
- Use UTF-8, LF and `zig fmt`. Unit tests sit beside the code they test; conformance fixtures
  and goldens live in `tests/conformance/` (sources use the `.forb` extension). A changed golden
  must be explained by the change; regenerate it with the tool, never by hand.
- Add tests for meaningful behaviour; do not fabricate passing tests.

## Delivery

- Keep caches (`.zig-cache/`, `zig-out/`) and scratch work (`.local/`) out of commits.
- Commit only when asked, with a message that says what changed and why.
