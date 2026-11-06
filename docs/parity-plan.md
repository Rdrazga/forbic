# Forbic: plan to completion and feature parity

Status: plan of record (TASK-0108 coordinates). It replaces the ranked gap list in
[book-compatibility.md](book-compatibility.md) as the order of work; that page keeps the
evidence and the list of deliberate divergences.

## Goal

Every feature of the Book of Verse has a Forbic counterpart with the same meaning for
programs that use it as intended. Two things are explicitly not goals:

- **Source compatibility.** Forbic keeps its own spelling (`If(c, a, b)`, `Block{...}`,
  `Attempt(a, b)`); a Book-syntax front end is optional later work (P8).
- **Identical semantics where Forbic chose differently on purpose.** Each such divergence is
  either aligned or kept, by a recorded decision (P1.9), never by accident.

The Book side was verified against the Book's source (commit `2af9dfd`, 2026-09-15): every
feature, with its source, is in [book-feature-matrix.md](book-feature-matrix.md), and each
deliberate divergence has a recommendation in [RFC-0067](rfcs/0067-book-divergences.md).
The rows below were corrected from that evidence. Epic's separate language reference pages no
longer exist, so the Book is the only primary source. Several alignments change the meaning of
existing programs and wait for the owner's decision (see "Decisions needed").

## Definition of done for one increment

An increment is finished when all of these hold, and not before:

1. An RFC states the source contract, the IR, the failure and effect behaviour, and the limits.
2. Both machines implement it, each admits its IR independently, and the report validator
   replays it. Forged-IR tests show each new operation is rejected when malformed.
3. Tests sit beside the code: behaviour, diagnostics, rollback, a randomized differential or
   oracle where state is involved, and a scale test in `program_profile_tests.zig`.
4. A conformance fixture (eval, trace, inspection, error) and a DST case exist.
5. Capacities are in the profile, set at real bounds, and cost nothing until used.
6. A read-only subagent review has been run on the diff and its confirmed findings are fixed.
7. `book-compatibility.md`, `pure-core.md` and the task file are updated; gates pass
   (bootstrap Debug, `program` runner, `zig build test integration -Doptimize=safe`,
   `tools/dev.ps1 check`); the work is committed.

## Phases

Phases P0-P2 are the sequential language and can run largely in parallel. P3 unblocks P4-P6.

### P0. Runtime foundations (in progress: TASK-0107)

| Id | Work | State |
| --- | --- | --- |
| P0.1 | 64-bit fuel | done |
| P0.2 | Destructuring limits from real bounds | done |
| P0.3 | Hash-based duplicate checks in admission | done |
| P0.4 | Undo records bound what can be restored | done |
| P0.5 | Call-witness trace sink (full / digest / off) | done |
| P0.6 | Member pool reclamation | done |
| P0.6b | Run strings and instances are still growth-only for a run: reclaim them | open |
| P0.7 | Remaining per-size scans in the compiler (method tables, catalogue interning, generic lookup); per-class vtable spans instead of the flattened dispatch table | open |
| P0.8 | Linux gate restored (the Podman VM disk is missing; needs the owner's go-ahead to recreate) | blocked |

### P1. The sequential language

| Id | Feature | Book form | Notes on design |
| --- | --- | --- | --- |
| P1.1 | Early exit | `return` (tail position), `loop` with `break` (no value; `break` never exits `for`; there is no `continue`), `defer` | `Return` and `Break` lower to the existing failure/merge machinery with a result slot. The Book's loop needs a spelling beside the existing `Loop(Step, Initial)` state loop (owner question). `Defer` runs in LIFO order on normal exit, `return`, `break` and cancellation, and does **not** run when the block fails: rollback undoes its registration. Deferred code cannot fail, suspend or exit. `While`, `Iterate`, the state `Loop` and `Fn` stay as extensions. `Err()` joins `Fail["reason"]`. |
| P1.2 | Iteration | `for` with several generators, bindings in filters, ranges `A..B`, failable bodies | Extend the `For` templates: filters may bind, generators nest, a failing body skips. `A..B` is a range value usable only as a generator (no array is built). |
| P1.3 | Numbers | `int`, `rational`, `Quotient`, `Mod` | The Book describes two runtimes: arbitrary precision, or 64-bit with a runtime error on overflow; checked `i64` already matches the second. Whether `int` is a new arbitrary-precision type or the Book-facing name of `i64` is an owner question. Add failable Euclidean `Quotient` / `Mod`, and `rational` with the operations the Book documents (`=`, `Floor`, `Ceil`) through bracketed division. `i64` `/` stays truncating and fatal on zero (RFC-0067 D3). |
| P1.4 | Text | `char`, `char32`, `string` as `[]char` | `string` stays UTF-8 text and gains the `[]char` view: failable indexing and slicing that fail where a UTF-8 sequence would be split (RFC-0067 D11). The Book has no string ordering; `<` is for `int` and `float` only. |
| P1.5 | Maps and `comparable` | composite keys, `comparable` | A `comparable` predicate over types; keys of any comparable type. Key removal is not in the Book and is a Forbic extension. In the Book only `<unique>` classes compare, map equality is order-sensitive, and a duplicate literal key keeps the last value; RFC-0067 D6 and D15 decide each. |
| P1.6 | `case` | literals, enumerators and `_` only | The Book's `case` has no bindings, guards or type tests; those are Forbic extensions (RFC-0066). What parity needs: a default-less `case` that fails in a `<decides>` context, open enums, unreachable-arm diagnostics, and `string` / `char` scrutinees. |
| P1.7 | Types | parametric classes, structs and interfaces; `type{...}`; `where`; `any`, `void`, `subtype`; container variance | Generic nominal types specialise like generic functions (one definition per argument list, interned). `where T:subtype(X)` and `comparable` constraints checked at specialisation. `any` as a top type with casts out; `void` as the unit result. Arrays, options and tuples become covariant where they are immutable values. |
| P1.8 | Classes, remaining | constructors, interface defaults and fields, named/default arguments on methods, extension methods, `<concrete>`, `<castable>`, `<final_super>`, block clauses | Constructor functions return an archetype; interface defaults are methods published under the interface's slot; extension methods are functions with a receiver that resolve after members. A superclass method may satisfy an interface method of the same name. |
| P1.9 | Divergence decisions | failable comparisons and chains, short-circuit `and`/`or`, failable division, failable `If` conditions with arm widening, additive effects, shadowing, duplicate keys | One RFC decides each: align, or keep with a stated reason. Default position: align where the Book form is strictly more expressive and existing programs keep their meaning (`and`/`or` in failure contexts, comparison chains, arm widening by subtype); keep where the Book form would make failures silent (division by zero stays fatal for `i64`; duplicate keys stay fatal). |
| P1.10 | Effects | `<reads>`, `<writes>`, `<allocates>`, `<suspends>`; `<converges>` on natives, abstract methods and signatures | An unannotated function is `<transacts>` and specifiers narrow it; a function with fewer effects is usable where more are expected. Split `<transacts>` into the Book's families so reading state or allocating does not need write permission. `<varies>` is not in the Book and is dropped; `<predicts>` is unreleased. `<suspends>` is declared here and implemented in P3. |
| P1.11 | Modules | nested modules, `<internal>`, `<scoped>`, exported aliases, re-exports, module-level variables | Module declarations inside a file; access levels checked like class access; aliases and re-exports in the public API packet. |
| P1.12 | Standard library | array, map, string and math functions; `Print`; `GetRandom*` | Written in Forbic where a guest loop is acceptable and as Zig-native functions where it is not (RFC-0042). Natives gain map, record, nested-array and callable parameters. Randomness and output are native effects (P2). |
| P1.13 | Book features found by verification | `first`; `logic{}` / `option{}` as failure contexts; optional chaining `?.`; qualifiers `(c:)` / `(local:)`; tuple flattening and tuple-to-array conversion; refinement types; the `subtype` family; `<localizes>`; attributes; split read/write access; `using{Instance}`; bitwise intrinsics; `profile` | Each becomes its own increment or is ruled out of scope by the owner (RFC-0067, owner questions). |

### P2. Native effects and recovery

Everything a program does to the world goes through a native effect with a
prepare/commit/abort contract, so rollback and failure stay honest: output, time, randomness,
handles. Completion levels L6 in [completion.md](completion.md). Required before P3 because a
suspended task must not hold an uncommitted external action.

### P3. Structured concurrency

`<suspends>`, `sync`, `race`, `rush`, `branch`, `spawn`, `task` (`Await`, `Cancel`), `event`
(`Signal`, `Await`), `Sleep`. Design constraints already fixed by the architecture: no rollback
region crosses a suspension point; scheduling is deterministic and replayable (a third
independent implementation in the report validator replays the schedule); cancellation runs
`defer` blocks (P1.1) in a defined order; every task has an owner and a bound. Both machines
suspend by saving guest frames, which they already keep off the native stack.

### P4. Live variables and reactions

Live variables and the Book's reactive forms publish committed state only; dependency tracking,
cycle detection, bounded propagation and observer order are specified before code. Needs P3.

### P5. Persistence and evolution

`weak_map`-keyed module variables, `<persistable>` types, stores that survive a session, schema
compatibility rules and rejection of incompatible updates. Needs P1.11, P2 and P4.

### P6. Reports and tooling at scale

Reports for long runs (digest validation from P0.5), streamed output, incremental admission so
an unchanged program is not re-verified per run, diagnostics with source excerpts.

### P7. Developer product

Formatter, language server, documentation generator, package layout, migration of the desktop
configuration and SDK to the completed language (L10).

### P8. Optional: Book-syntax front end

A second parser that accepts the Book's indentation and block syntax and lowers to the same IR.
Only worth doing if running unmodified Book programs becomes a goal.

### After parity

Proposals for what comes after Book parity are in
[docs/proposals/post-parity](../../docs/proposals/post-parity/README.md): exact decimals, dates and
text formatting, processes and host events, one request/response effect for databases and
networks, and a multi-run host in Zig. None is scheduled; they are for review once P1 to P5 and
RFC-0085 are done. Parity work should not close a door any of them needs.

## Decisions

The owner's stated goal is a very verifiable, low-bug language that is also fairly fast once
compiled, and every divergence question was left to the coordinator's judgement on that
basis. RFC-0067 "Decisions" records each one. In short: `int` is the name of checked `i64`
(no bignums); shadowing is forbidden; `and` / `or` short-circuit; class members are
`<internal>` by default; equality and map keys need `<unique>`; overloads on related classes
are rejected; a discarded comparison is an error; `option{E}` catches everywhere; effects stay
mandatory; types stay exact with explicit conversions; `i64` `/`, signed zero and fatal
duplicate keys are kept. The alignments that change existing programs land together as
P1.9b after the third wave.

On 2026-10-14 the owner approved every feature the Book itself marks unreleased (`[U]` in
the feature matrix): live variables and their reactive forms, `task.Cancel`, `NextTick`, sticky
and subscribable events, nested functions with capture by reference, `<predicts>`, JSON,
transparent functions, accessors, automatic qualification and the unreleased attributes. Each
is in scope for the phase that owns its area. Where the Book leaves its semantics open, the
implementing RFC specifies them and records the choice as a divergence.

## Progress

Merged: P0.1-P0.6 and P0.6b (strings and instances reclaimed); P1.1 (RFC-0068), P1.2
(RFC-0064), P1.3 (RFC-0070; `int` is checked `i64`), P1.4 (RFC-0069), P1.5 (RFC-0065), P1.6 as
extensions (RFC-0066), P1.7 parametric types (RFC-0073), P1.8 (RFC-0071, RFC-0075), P1.9 and
its breaking alignments (RFC-0067, RFC-0076), P1.10 effect families (RFC-0078), P1.11
(RFC-0074), P1.12 (RFC-0077), P1.13a (RFC-0072), P1.13b `void`, `any`, failing `Case[...]`,
`ToArray` (RFC-0080), P2 native effects with `Print` and randomness (RFC-0079), and a defect
pass over report privacy and compile cost. `coordination/tasks/0108-feature-parity.md` records
each with its open items.

Since then (to revision 197):
- P1.13c generic methods, the `subtype` family and `SortBy` (RFC-0081); P1.13d refinement types,
  qualifiers, parametric aliases and open enums (RFC-0083); defect passes, the last (`pf2`)
  fixing generic functions beside same-named methods and an `Fn` in a `For` of a generic
  function, and making a `For` in a task linear.
- P2 complete: input effects, the clock, grants and handles, the durable journal and recovery
  (RFC-0086 P2.2 to P2.5).
- P3.1 to P3.9: the scheduler, `Spawn`, `Sleep`, the virtual clock, `Await`, events, `Sync`,
  `Race`, `Rush`, `Branch`, cancellation, landings, `Cancel`, and a suspending `For` body
  (RFC-0082).
- P4.1 to P4.8: live variables, `When`, `Upon`, `Await(G)`, `Batch`, and live locals (RFC-0084).
- RFC-0085 I1 to I14 (I13: one capture rule for every closure): shared locals and nested functions, the full oracle and scale
  tests over them (I6), transparent functions, accessors, enumerator and automatic
  qualification, `<predicts>`, live locals.
- P5.1 `weak_map`, P5.2 `<persistable>`, P5.3 JSON, P5.4 session cells, P5.5 persistent cells
  and the store, and P5.6 schema compatibility (RFC-0087).

In progress: the milestone of
`coordination/tasks/0109-verse-standalone.md` (Forbic ready to stand alone). Then P5.6 (schema compatibility) and P5.7 (store recovery), P5.8 only when ForbOS
publishes modules others depend on, and P0.8, which waits for the owner's go-ahead on the Linux
VM. Known and recorded, not fixed: a `For` past a quarter of the pool copies again, arrays of
arrays cost n^2/2 members, a `For` whose visits `Sleep` copies its accumulator, and dead
`var live` locals after a module `var` are re-evaluated on each write
(`docs/development/capacity-review.md`, "Defect pass pf2").

## Order and parallel work

- Now: P0.5, then P0.6. In parallel with them: P1.1, P1.2, P1.5 and P1.9 (the decision RFC),
  which touch the compiler and templates more than the frame loops.
- Next: P1.3 and P1.4 (new value kinds, both machines), P1.6, P1.8.
- Then: P1.7 (the largest single item; generic nominal types reach every part of the
  catalogue) and P1.10, P1.11, P1.12.
- P2 starts when P1.12 needs its first effect; P3 after P2; P4 and P5 after P3.

Independent increments are delegated to subagents working in private copies of the tree and
merged serially, as in TASK-0107; anything that changes the frame loops or the catalogue layout
is serialised. Each merge runs the gates on the combined tree.

## Risks

- **Generic nominal types** change the identity of types (a specialisation is a definition);
  reports, inspection and the 16-bit type index all feel it. Budget a design RFC first.
- **Concurrency under two independent machines plus replay** triples the scheduler work. The
  deterministic scheduler must be specified as data both can follow, not as code they share.
- **Divergence decisions** can invalidate existing fixtures. Each alignment lands with its
  golden changes reviewed, not regenerated blindly.
- **The Linux gate** is not running. Everything is verified on Windows plus cross-compilation
  until the owner approves recreating the VM.
