# Forbic completion track

Status: active iterative development, starting at TASK-0054. The experimental
[pure core](pure-core.md) is executable today. [RFC-0002](rfcs/0002-forbic-core.md)
records the intended language; Draft guarantees are not promises made by the
current compiler. Complete the strict desktop dialect first. Full Verse
compatibility is a subsequent track with its own specification and evidence.

## Iteration and acceptance

Each increment specifies grammar, typing/effects, evaluation order, ownership,
failure behavior and resource admission before implementation. Deliver the
complete path through compiler, verifier, runtime, diagnostics and affected
product consumers. Review correctness separately from performance and memory;
retain evidence and a task handoff before marking an increment complete.

Each feature requires positive/negative source fixtures, precise diagnostics,
quota boundaries, independent semantic checks, malformed IR/bytecode admission,
deterministic simulation, failure injection, replay and workspace recovery.
Assertions protect internal invariants; valid input and resource pressure return
checked outcomes. Do not pad assertion density or impose arbitrary value caps.

Run pinned-tool Debug/Safe tests, supported Linux execution/cross compilation and
the integrated local check. Measure workspace sizes, allocation/lifetime behavior
and representative performance with production safety checks enabled. Update
contracts and status together. External CI and final UI appearance remain deferred.

## Dependency-ordered increments

| Increment | Result | Status and acceptance focus |
| --- | --- | --- |
| L0: scalar pure core | i64, logic, strings, immutable bindings and pure template functions | Implemented: checked arithmetic, strict arguments, bounded expansion, independent evaluator and verified register VM |
| L1: precise numeric core | Binary64 float for ratios, scaling and material data | TASK-0054: decimal/exponent grammar, nonfinite arithmetic, canonical NaN, signed zero, subnormals, separate rounding and valid JSON reporting; conversions/unbounded int remain later |
| L2: aggregates and types | Named structs/enums, fields, arrays, tuples, options and maps | TASK-0055/0056/0057/0058/0059: immutable records, closed nominal enums, homogeneous arrays, heterogeneous tuples, options and insertion-ordered maps with total lookup/fallback, contextual empties, field selection/Length, typed functions/defaults, bounded sharing, verified metadata and iterative reports implemented. Composite comparable keys and failable indexing require later contracts; the initial value track is implemented |
| L3: modules | Path imports, visibility, qualified lookup and reproducible resolution | TASK-0060: immutable bundles, lexical deterministic resolution, qualified public APIs, nominal privacy escape checks, root-only exports, original-file diagnostics and strict API-v2 packets implemented. Independent metadata admission, capacity/mutation/oracle checks and Windows/Linux replay validated |
| L4: failure and effects | Failable comparisons/calls, failure contexts/reasons, source mutation and rollback | Active TASK-0061/0062/0063: typed predicates/strict logic, lazy If/Attempt, explicit Require/Fail, computes/transacts/decides checking, typed per-run mutable bindings/writes, nested rollback, arm visibility, defining-source traces and independent snapshot/report validation implemented. TASK63 is locally validated; its handoff records the independent rollback, cross-host replay, capacity and performance evidence. Broader native-effect classification and later runtime control remain next. Existing journal/outbox does not make external actions atomic |
| L5: runtime control flow | Blocks/local bindings, branches, iteration, calls, bounded guest recursion, first-class functions/generics and effect polymorphism | TASK-0064/0065/0066 implement and locally validate computes calls, lazy If and internally caught failure bodies. TASK-0067 implements and locally validates computes/decides bodies with checked iterative propagation, independent effect/context/body admission, exact quotas/fuel, aggregate lifetimes, bounded value/failure/propagation evidence, one defining origin and independent root/callee report replay. Their handoffs record prototype costs and remaining boundaries. TASK-0068 implements and locally validates transacts bodies with shared caller cells, checked source effects and own/root rollback plus independent state replay. Defaults retain templates. TASK-0069 implements and locally validates typed immutable lexical Block bindings and strict sequences without new runtime opcodes. TASK-0070 implements and locally validates mutable locals with strict assignment copies, compiler version checkpoints and checked call evidence. TASK-0071 implements and locally validates counted typed state iteration over reusable frames with checked repeat evidence. TASK-0072 implements bounded direct self-recursion with strict typed argument snapshots and existing iterative guest frames; independent admission/replay, exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. TASK-0073 implements typed function references, exact structural effect signatures, strict indirect dispatch and bounded dynamic cycles with independent admission and full replay; its independent admission/replay, exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. TASK-0074 extends counted iteration to callable values with strict step/count/seed order, one target snapshot, exact signature effects and existing bounded repeat frames; independent admission/replay, exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. TASK-0075 implements general state loops with exact state-to-option transitions, strict target/seed order, normal termination and shared bounded guest dispatch; independent admission/replay, exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. TASK-0076 implements immutable escaping prefix captures with Bind, exact residual signatures, shared bounded dispatch, independent physical-copy replay and bounded wire reports; independent admission/replay, exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. TASK-0077 implements explicit typed anonymous bodies and captures with bounded compiler continuations, immutable escaping descriptors, original-source identity, independent admission and full replay; exact quotas, SDK/simulation/product and Windows/Linux/live/ARM acceptance are locally validated in its handoff. Follow-on work implements generic/effect polymorphism. Acceptance covers branches/merges, strict order, stack/fuel budgets and cleanup. No native recursion in compiler/VM |
| L6: systems and managed storage | Numeric conversions/int/rational decisions, bytes/graphemes, owned handles, C ABI, native descriptors and recoverable dispatch | Honest native effects implemented (RFC-0079, parity P2): effect natives declared by their table entry and admitted by both machines, a bounded effect log with prepare/commit/abort per rollback region, committed output in program order and never from a failed region, seeded draws that rollback does not undo and that the report replay recomputes, host sinks with a documented recovery contract and a failing test double. Remaining: world inputs that cannot be recomputed (time) and owned handles, a durable sink, bounded heap/GC with lifetime tests and isolation boundaries |
| L7: structured concurrency | Suspension, sync/race/scoped spawn, cancellation and async failure | Planned after L4–L6: no rollback region crosses suspension. Specify task visibility, joining, cancellation ordering, resource cleanup and a deterministic scheduler model |
| L8: reactive state | Live values, dependencies and when observers | Planned after L4/L7: publish committed state only; detect cycles, bound propagation and define observer ordering/reload without rollback glitches |
| L9: persistence/evolution | Typed stores, migrations, public API compatibility and reload | Planned after L3–L8: durable recovery, migration rejection, extension compatibility and resource-state lifetime across reload |
| L10: developer/product completion | Formatter, LSP, documentation, standard library, SDK/config/policy migration and packaging | Incremental across L2–L9: useful real desktop/SDK fixtures at each step; final combined semantic, recovery, isolation and sustained resource acceptance |

These are dependencies, not deadlines or a rule against independent tooling
work. Task IDs remain in `coordination/tasks/`; UI stage numbers are separate.

## Open design decisions

RFC-0015 fixes immutable records as nominal and arrays as structural. Class
identity and mutability, generic constraints,
overload/subtype resolution, recoverable errors versus failure, trace representation,
heap/GC policy, suspension visibility, hot reload and migration semantics require
concrete RFC decisions. Fixed bootstrap capacities must become explicit host
profiles with checked admission before broad desktop/extension use. Large input
is not inherently invalid. Benchmark results cannot decide language correctness.

`float` is binary64, consistent with the [Book's primitive reference](https://verselang.github.io/book/02_primitives/).
TASK-0061 specifies reflexive NaN equality and unordered comparisons explicitly;
host IEEE equality alone would change those semantics. Strict predicate values
remain distinct from future source failure contexts.
Checked truncating i64 division remains distinct from unbounded int/rational arithmetic.

## Completion boundary

Forbic is complete when its accepted grammar, type/effect system, standard library
and native interface work together, documented guarantees hold at every boundary,
and representative desktop/config/extension programs pass semantic, recovery,
isolation and sustained resource tests. Full Verse additionally needs feature-by-
feature compatibility decisions, including intentionally omitted functional logic,
lenient evaluation and upstream APIs, with separate compatibility evidence.
