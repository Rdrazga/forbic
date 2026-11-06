# Book of Verse compatibility track

Status: working analysis, not a compatibility claim. Forbic deliberately differs
from the Book (see [completion.md](completion.md)); this page records where, so
the later compatibility track starts from evidence. The Book column was compiled
from fetched chapter summaries and must be re-verified against the Book itself
before any row is cited as a guarantee. Repo claims were checked against the
sources and tests named in each row's increment.

Status key: SAME, DS (same semantics, different spelling), PARTIAL, MISSING,
OOS (omitted by design). Full per-feature rows live in the task handoff of
TASK-0080 as each gap closes; this page keeps the ranked summary.

The order of remaining work, with a definition of done per increment, is in
[parity-plan.md](parity-plan.md). The list below records what each gap covers.

## Highest-leverage gaps for a desktop/config dialect

1. Iteration: several generators, ranges, binding filters and failing bodies are done (RFC-0064; arrays and maps with filters: RFC-0056; failable indexing: RFC-0040; concatenation: RFC-0046).
2. Character access: done (`char`, `char32`, indexing, slicing, iteration: RFC-0069; concatenation, `Length`, conversion: RFC-0043; interpolation: RFC-0053). The Book has no string ordering.
3. Bindings in `For` filters: done (RFC-0064; failable `If` conditions: RFC-0049; condition bindings and destructuring: RFC-0059; `not`: RFC-0062; `or` is `Attempt(A, B)`).
4. `Case` with a default or exhaustive over an enum: done (RFC-0050); binding patterns and guards remain.
5. `Quotient`, `Mod` and `rational`: done (RFC-0070; float/i64 conversions: RFC-0041). Whether `int` is arbitrary precision is an owner decision (RFC-0067).
6. Exported type aliases and re-exports (`using`: RFC-0062; local type aliases: RFC-0045).
7. Subtype-aware overload resolution (overloading by parameter types: RFC-0061; default and named parameters: RFC-0058).
8. `set` on fields, elements and map keys: done (RFC-0044, RFC-0051, RFC-0052, RFC-0057).
9. Classes and interfaces (declaration, construction, fields, identity, rollback, single inheritance, casts, methods, virtual dispatch, `<abstract>`, `<final>`, `Super`, `<private>`/`<protected>`, `<unique>`, method values and interfaces with cross-casts: RFC-0063; generic classes and interface defaults are the next stages).
10. Composite map keys and key removal: done (RFC-0065; map insertion and option unwrap: RFC-0057; map iteration: RFC-0056). Key removal is a Forbic extension.

Zig-native functions (RFC-0042) are a dialect extension: performance-critical
kernels (`std.sum`, `std.sorted`, `std.dot`, `std.sqrt`, ...) run in Zig behind typed,
bounded, independently admitted calls. They also close the Book's math-library
gap for deterministic functions.

Concurrency (`sync`/`race`/`spawn`/`<suspends>`), live variables, persistence and
evolution stay deferred to L7-L9 until native-effect recovery exists.

## Divergences that need an RFC decision, not just work

- Comparisons return `logic` and chains are rejected (RFC-0021); the Book's are
  failable and return the left operand.
- `and`/`or` are strict (RFC-0021/0022); the Book's short-circuit and combine failure.
- `/` truncates `i64` and zero division is a fatal diagnostic; the Book's is
  failable over `rational`.
- Signed zero is preserved in arithmetic while `0.0==-0.0`.
- Shadowing by parameters and inner blocks is allowed (RFC-0029); the Book forbids it.
- Duplicate map keys are a fatal error; the Book keeps the last.
- `If` needs a `logic` condition and exact arm types; the Book uses a failable
  condition and widens arms.
- Exact structural typing and no effect widening (RFC-0015/0033) versus Book subtyping.
- Per-run mutable cells with rollback versus the Book's module-scope rule.
- `computes`/`transacts` are mandatory and closed; the Book's effects are additive.
- `string` is UTF-8 text, not `[]char`.
- `Fail["reason"]` and failure traces are a dialect extension with no Book equivalent.
