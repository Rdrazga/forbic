# Forbic toolchain entry point

Host the compiler/runtime CLI here. Reuse `src/forbic/` and keep compiler logic
independent of desktop integration.

`forbic check FILE` compiles, lowers, verifies, and executes the
[pure core](../../docs/pure-core.md) on the bounded register VM.
`forbic eval FILE` emits values as JSON. Unsupported syntax, type mismatches,
overflow, and exhausted budgets produce diagnostics and exit 1. Usage errors exit 2.
Output of any size may be piped. A reader that closes its end early (`forbic inspect F | head -1`)
ends the tool without a message and with status 141, what a shell reports for `SIGPIPE`, on
every platform; any other failure to write output is named on standard error and exits 1.
`forbic inspect FILE` compiles, lowers and verifies without executing. Its JSON
report shows instructions, result registers/types, binding metadata, source byte
spans and one decoded string pool. String operands index UTF-8 bytes in that pool.
Inspection can succeed for division-by-zero or overflow programs that `eval`
rejects. It is a developer report, not executable serialized bytecode; see
[RFC-0010](../../docs/rfcs/0010-bytecode-inspection.md). Programs with a type
record/array catalogue use inspection format 2, which adds type definitions, fields and a
member-reference pool. Records become JSON objects, arrays become JSON arrays.
Value output has a 1 MiB/65,536-work profile; inspection preflights 4 MiB before
writing. Execution fuel is 16,384 units, with constructors charging each copied
member. See [RFC-0015](../../docs/rfcs/0015-immutable-aggregates.md).
This is a Verse-inspired bootstrap rather than an Epic Verse implementation.
Record fields support typed pure defaults; omitted defaults expand at construction,
and overrides suppress evaluation. Unused defaults are still type-checked.
See [RFC-0016](../../docs/rfcs/0016-record-field-defaults.md) and
`desktop/config/defaults-baseline.forb` for a typed desktop example.

Closed enums (`mode := enum { Light, Dark }`) provide nominal qualified constants
through functions, records/defaults and arrays. JSON values use qualified strings;
inspection uses format 3 for enum catalogues. Pattern matching and
open enum evolution remain later increments. See
[RFC-0017](../../docs/rfcs/0017-closed-enums.md) and
`desktop/config/enums-baseline.forb`.
Immutable structural tuples use `tuple(i64,string)` types, `tuple{6,"Traverse"}`
constructors and constant positional access `Pair(0)`. Nested contexts type empty
arrays; functions and defaults preserve strict order and lexical captures. Value
JSON uses arrays and inspection uses format 4 for tuple catalogues. See
[RFC-0018](../../docs/rfcs/0018-immutable-tuples.md) and
`desktop/config/tuples-baseline.forb`.
Options use `option(t)` and zero/one-member `option{...}` constructors; maps use
`map(k,v)` and insertion-ordered `map{key=>value,...}` constructors. Total
`Lookup(M,K)` returns an option, `Or(O,Fallback)` selects a strictly evaluated
fallback, `.IsSet` reports presence and map `.Length` counts pairs. Duplicate keys
are checked failures; key hashing/comparison consumes fuel. Inspection format 5
adds collection metadata. See [RFC-0019](../../docs/rfcs/0019-options-maps.md).
CLI syntax/output remain compatible. Internal transaction instructions are described in
[RFC-0005](../../docs/rfcs/0005-bounded-transaction-runtime.md).

`forbic check/eval/inspect/trace PACKET --bundle` accepts a strict JSON packet with
`root` and `modules:[{path,source}]`. All file content is supplied explicitly;
imports perform no filesystem lookup. Private names and private nominal types
cannot escape module APIs. Imported diagnostics retain their original virtual
path and local line/byte column; inspection format 6 emits this provenance.
`traverse check/plan/apply PACKET [STORE] --bundle` and
`stanza plan PACKET WIDTH HEIGHT --bundle` consume the same root configuration.
Try `desktop/config/modules-baseline.json`; see
[RFC-0020](../../docs/rfcs/0020-immutable-module-bundles.md).

Typed comparison operators return logic; `not`, `and` and `or` compose predicate
values. `and` and `or` short-circuit, left to right: the right operand runs only when
the left does not decide the result (RFC-0076). Equality admits scalar/closed-enum
values of the same exact type; ordering admits i64/float. NaN equals itself and
is unordered; signed zeros compare equal. String comparisons charge the shorter
decoded byte length before comparison. Inspection format 7 reports predicates.
Try `tests/conformance/predicates.forb`; see
[RFC-0021](../../docs/rfcs/0021-predicates.md). Source failure and effects remain
separate work on the completion track.

`forbic qualify FILE [--bundle]` prints the source with every identifier in its fully qualified
form (`(/Path:)Name`, `(local:)Name`, `(/Verse.org/Verse:)i64`), the Book's automatic
qualification, and runs nothing; it takes no run option. Try
`tests/conformance/qualification.forb`; see
[RFC-0085](../../docs/rfcs/0085-closures-and-unreleased-forms.md), I11.

`forbic trace FILE [--bundle]` reports the first 32 caught failure reasons with
defining-file locations, total count and truncation flag, after full value/schedule
admission and exact 4 MiB output preflight. Try `tests/conformance/failure.forb`.
`If` and `Attempt` skip untaken arms; `Require[]`, `Fail[]` and decides helpers
provide explicit failure. Arithmetic/fuel errors terminate execution. See
[RFC-0022](../../docs/rfcs/0022-failure-regions.md).

Typed mutable bindings use `var Name:type=initializer`, `set Name=expression` and
expression `Set(Name,expression)`. Functions declare a heap effect: computes,
transacts, or some of reads, writes, allocates (RFC-0078); a read needs reads, a set
writes, a construction allocates, and a call the effects of what it calls. Attempts
undo failed body writes before fallback; fatal errors abort the whole run. Public
mutable root bindings export final values, and immutable aliases keep old values.
Try `forbic eval tests/conformance/mutation.forb` or
`forbic inspect tests/conformance/mutation.forb` (format 9); see
[RFC-0023](../../docs/rfcs/0023-source-mutation.md). State is per-run; local
variables follow RFC-0030 and native actions require later contracts. Eligible computes helpers
use bounded runtime frames and inspection format 10; body/capture/argument pools
are admitted even when unused. Computes If bodies and transitive callers use
frames with caller-owned step evidence; inspection format 11 exposes their control
metadata. Defaults still use templates. Try `tests/conformance/calls.forb` and
`desktop/config/calls-baseline.forb`; see
[RFC-0024](../../docs/rfcs/0024-runtime-calls.md). Try
`tests/conformance/frame-branches.forb` for lazy branches inside runtime helpers;
[RFC-0025](../../docs/rfcs/0025-frame-branches.md) defines their report admission.
Computes helpers with internally caught Require/Fail also use frames. Each frame
owns 32 catcher slots; fatal errors abort the run and caller source state.
`tests/conformance/frame-failure.forb` exercises nested helper recovery;
`forbic trace tests/conformance/frame-failure.forb` emits format2 with the root
instruction, defining function/local instruction and original-file location.
Root-only failures retain format1. Inspection12 adds failure metadata; memory
profile10 reflects changed persistent reservations. See
[RFC-0026](../../docs/rfcs/0026-frame-failure.md).
Computes/decides bodies now propagate uncaught language failure to caller Attempt
regions. A call requires its declared failure context even when its body cannot
fail. Propagation preserves one defining reason/location and consumes no extra
guest fuel; fatal errors still terminate and abort the run. Try
`tests/conformance/failable-frames.forb` and its `forbic trace` output. Inspection13
adds declared decides metadata. Memory profile11 records failure/outcome values
and report ownership; guest capacities remain unchanged. Reports check complete
root/callee continuations and physical copies before publishing output. See
[RFC-0027](../../docs/rfcs/0027-failable-frames.md).

Transacts helpers now read/write caller source cells in runtime frames. Own
Attempt regions commit successful writes or restore cells before fallback; root
catchers also restore failed callee writes. Fatal errors abort the complete run.
Try `tests/conformance/transactional-frames.forb` with eval/trace/inspect, and
`desktop/config/transactional-frames-baseline.forb`. Inspection14 adds declared
transacts, direct source count and transitive source metadata. Memory profile12
separates cold source replay scratch from persistent reservations; SDK/value/config
schemas and guest capacities stay unchanged. [RFC-0028](../../docs/rfcs/0028-transactional-frames.md)
defines source ownership and report reconstruction. Typed lexical blocks now
provide immutable locals and strict expression sequences. Mutable locals follow
RFC-0030 as described below.

Try `forbic eval tests/conformance/blocks.forb` and its trace/inspect output.
`Block{X:i64=1; X+2; X}` visits the discarded addition and returns1. Locals may
shadow earlier parameters/global values; nested scopes disappear on close. Each
initializer sees outer names until its own name is published. If/Attempt preserve
lazy selection and lexical sibling/fallback scope. Blocks add no opcode, fuel or
transaction region. Memory profile13 versions256 live local names independently
of root bindings. [RFC-0029](../../docs/rfcs/0029-local-blocks.md) defines the
grammar, exact typing, strict order and ownership.

Mutable locals use `Block{var X:i64=1;Held:i64=X;set X=3;Held+X}`, which returns4.
`Set(X,Expr)` returns the assigned snapshot. Init/write requires transacts in
helpers; computes/defaults reject it, including unused bodies. If commits only
its selected versions after condition evaluation. Attempt restores saved versions
before fallback. `forbic eval tests/conformance/locals.forb` demonstrates mixed
global/local rollback, and `forbic inspect` exposes local_set/hidden state tuples
with format15. [RFC-0030](../../docs/rfcs/0030-mutable-locals.md) defines checked
copy evidence, quotas and lifetimes. General loops and mutable captures remain later.

`Step(X:i64)<computes>:i64=X+1;Value:i64=Iterate(Step,3,7)` returns10.
Count and Initial evaluate strictly; zero skips dispatch, negative counts fail
fatally. A static Step is an earlier one-parameter helper returning the same state
type; transacts/decides permission remains mandatory even for zero counts.
Qualified public helpers and contextual aggregate initial states are supported.
`forbic eval tests/conformance/iteration.forb` demonstrates immutable state and
rollback across visits. `forbic inspect` exposes iterate in format16; SDK/value/
configuration/trace schemas retain their prior contracts. See
[RFC-0031](../../docs/rfcs/0031-counted-iteration.md) for checked dispatch fuel,
frame lifetimes, quotas and replay. Direct self-recursion follows RFC-0032; typed callable values follow RFC-0033.


`F(N:i64)<computes>:i64=If(N==0,42,F(N-1));Value:i64=F(7)` returns42 through
bounded guest frames. Self arguments evaluate strictly; decides uses brackets.
Depth32 is admitted; attempting the next frame returns a fatal diagnostic.
Frame/live-register/member/event/fuel pressure is checked and leaves the workspace
reusable. Recursion shares caller source rollback without adding a region.
`forbic inspect` uses format17 even for unused self bodies. Value/trace/SDK/config
formats stay unchanged. Try `tests/conformance/recursion.forb` and
`desktop/config/recursion-baseline.forb`; see
[RFC-0032](../../docs/rfcs/0032-bounded-self-recursion.md).


Typed function values use `function(tuple(i64),i64)` with exact parameter/result
schemas. Optional effect specifiers (`<computes>`, `<reads>`, ..., `<decides>`) precede
the parentheses; a function with fewer effects is a value of a type with more. Bare earlier public/qualified names and body-local self names
produce immutable references; taking a reference executes no effects. Locals and
parameters shadow function names. Values can be passed, returned, selected and
stored in records, arrays, tuples, options, maps and mutable cells/locals.

`F(41)` and a decides `F[41]` check the signature effects and evaluate the callee
before strict left-to-right arguments. Indirect calls retain full bounded evidence
and use the same guest frame, register, member, source and fuel quotas. Reports
describe a reference as `{"function":{"name":"F","module":null}}`, with the
defining virtual path for bundles. These descriptors provide no native action.
Inspection18 includes callable types and unused bodies; older programs retain
their existing formats. Try `tests/conformance/callables.forb` and
`desktop/config/callables-baseline.forb`; see
[RFC-0033](../../docs/rfcs/0033-typed-function-values.md). Named references borrow
only checked immutable metadata. Generics and effect
polymorphism require subsequent storage/type contracts.


`Iterate(Step,Count,Initial)` also accepts callable parameters, locals/source cells,
selected/returned/aggregate values and own self references. The exact signature
has one parameter with the same result/state type. Step evaluates once before
Count and contextual Initial; every visit retains that target snapshot even if
the supplying cell changes. Signature effects apply with zero Count or an unused
body. Zero still evaluates all operands before returning Initial; negative Count
is fatal afterward. Existing dispatch fuel, bounded reusable guest frames and
rollback semantics apply. Reports independently resolve the checked Step snapshot
and validate visit/seed/return/constructor/failure evidence before output.
Inspection19 exposes iterate_value even unused; profile15 capacities/layouts remain.
See [RFC-0034](../../docs/rfcs/0034-callable-iteration.md) and `desktop/config/callable-iteration-baseline.forb`.
Captures, general loops, generics/effect polymorphism and L6-L10 remain active.


`Loop(Step,Initial)` runs a state transition of exact type
`function(tuple(S),option(S))` until it returns `option{}`. Step evaluates once
before contextual Initial. Each `option{Next}` continues with that immutable
state; None returns the current state. Even the terminating visit executes and
its successful source writes commit. Failure remains distinct and restores all
visits under the nearest Attempt. Exact declared effects apply even unused.

Loop uses bounded iterative guest frames and existing fuel/member/evidence/source
limits, with no separate visit cap. The opcode and every dispatch/restart cost one
fuel unit. Options currently use append-only run member storage; managed storage
follows in L6. Full visit replay independently admits option termination, copies,
physical members and rollback before writing reports. Inspection20 exposes loops
even in unused bodies. `Loop` is now reserved; prior self-dispatch fixtures use
`Spin` with unchanged behavior. Memory profile16 records an eight-byte increase
per VM frame (256 bytes per 32-frame storage); reference frames and cold replay
arrays retain their prior sizes. These are overlapping ABI reservations, not RSS.
See [RFC-0035](../../docs/rfcs/0035-state-loops.md) and `desktop/config/state-loops-baseline.forb`.
Captures, generic/effect polymorphism and L6-L10 remain active.


`Bind(Function,Value,...)` copies one or more leading parameters into an immutable
function value. `Bind(Add,2)(40)` calls a two-parameter Add with2 and40. Nested
binding appends captures; full binding returns a zero-parameter function. The
residual structural signature keeps the exact result and declared effects.
Function evaluates once before the strict contextual captured arguments.
Creation does not invoke the target; ordinary argument effects still apply.

Captured source/local values are snapshots that safely escape guest frames,
including aggregates and function values. A descriptor names the original code,
residual type and checked run-owned member span. Calls/Iterate/Loop supply the
prefix before residual arguments or seed; self retains its full signature.
Copies cost one fuel unit each in addition to the Bind operation. The existing
16 original parameters,8192 members/registers/events and32 guest frames remain.
Caught failure retains append-only allocation history and restores source/local
state. Fatal cleanup supports healthy reuse. Managed lifetime work follows in L6.

Independent IR/VM admission checks unused bodies too. Raw descriptor admission
rejects capture cycles/future references before full replay checks copy order,
physical ranges, target snapshots, inputs and repeated visits. Inspection21
exposes binding. Bound values report an additional `captures` array; iterative
preflight counts all three JSON containers per bound descriptor under the existing
256-container value depth and explicit work/output limits, before external output.
Unbound function reports retain their prior shape. Worker/SDK admission shares
this bounded wire structure and rejects unrelated nulls.

Memory profile17 measures208-byte VM frames,204800 bytes of cold call replay and
6168 bytes of cold iterative value traversal. Reference frames remain544 bytes;
source replay remains278680 bytes. Rows overlap and are ABI reservations, not RSS.
See [RFC-0036](../../docs/rfcs/0036-bound-function-captures.md) and `desktop/config/bound-functions-baseline.forb`.
Anonymous body syntax is documented below; generic/effect polymorphism and L6-L10 remain active.


An anonymous function is a typed expression:

```forbic
Plus:function(tuple(i64),i64)=Fn[Amount:i64=2](N:i64)<computes>:i64{Amount+N}
Answer:i64=Plus(40)
Identity:function(tuple(i64),i64)=Fn(N:i64)<computes>:i64{N}
```

`Fn` is reserved. The optional capture list is nonempty when present; captures
have explicit `Name:Type=Expression` declarations. Parameters, result and effects
are explicit. Capture and parameter names are unique across both lists, with at
most 16 total. The body is one expression; `Block` supplies local declarations
and strict sequences. Capture initializers run once, left to right, in the
creator's context. The body is checked even unused and runs only on invocation.
Creation inherits initializer effects; declared body effects apply on invocation.

Captures are immutable snapshots of every supported Value kind, including other
functions, and may safely escape the creator. Other enclosing locals/parameters
are inaccessible unless explicitly captured. Ordinary globals, earlier functions,
module privacy and source cells retain their existing rules. Reading a cell in
an initializer snapshots it; reading directly in a transacts body reads it at
invocation. A named creator can explicitly capture its full self descriptor.
Nested and returned anonymous bodies work with calls, `Iterate`, `Loop`, defaults,
imports and aggregates. Empty captures produce a function reference; nonempty
captures lower to checked prefix `Bind`, with the same residual signature,
append-only run-owned storage, copy fuel and rollback rules.

The compiler suspends creators in explicit bounded continuations, sharing the
existing operator/operand/local/template/work pools. Bodies publish private code
entries before their creators, then reuse temporary template tails. No native
parse or guest recursion is added. Anonymous bodies share the 64 runtime code
entries with named functions. Independent IR/VM admission checks unused bodies,
original/residual types, source-site identity and metadata. Full report replay
checks capture copies, targets, arguments, seeds, failures and source chronology.

Inspection format 22 exposes anonymous bodies. Anonymous JSON descriptors use
`{"function":{"name":"Fn","module":null,"anonymous":82,"captures":[2]}}`:
`anonymous` is the original file's byte offset of `Fn`; module names replace null
for imported code, and empty captures omit the array. The offset is a bounded
unsigned integer below 65536. Named reports retain their prior shape. Worker/SDK
admission checks the exact descriptor shape independently. Existing iterative
work/output/depth limits and zero-output preflight failures remain in force.

Memory profile 18 reports 39936 bytes of compiler continuations (64 x 624).
Only compiler workspace and its containing extension-host row grow by this
amount. VM/reference frames remain 208/544 bytes; cold source/call/value replay
buffers remain 278680/204800/6168 bytes. Guest capacities are unchanged. These
overlapping ABI reservations do not measure RSS or allocator/native-stack costs.
See [RFC-0037](../../docs/rfcs/0037-anonymous-functions.md) and `desktop/config/anonymous-functions-baseline.forb`.
Generic/effect polymorphism and L6-L10 remain active.

## Explicit generic functions

A named function may declare explicit type parameters and a brace-delimited body:

```forbic
Identity[T:type](X:T)<computes>:T{X}
Number<public>:i64=Identity[i64](41)
Chosen:function(tuple(i64),i64)=Identity[i64]
```

Type arguments are written at every reference; there is no inference, coercion
or overload. A specialization is an ordinary exact function value, so it works
with `Bind`, `Fn`, aggregates, `Iterate` and `Loop`. Templates are balanced token
ranges until specialized; materialization checks the whole body for the concrete
types even if the result is unused. Repeating a declaration with the same type
tuple reuses its checked code. Bodies resolve names in their defining module and
declaration-time namespace. Type and value parameters share the 16-parameter
budget, and templates share the 64-definition source budget with named functions.

Inspection format 23 exposes specialized code. Specialized JSON descriptors add a
bounded `specialization` array of concrete type IDs after name/module (and any
anonymous site) and before captures:
`{"function":{"name":"Step","module":null,"specialization":[0]}}`. Unspecialized
descriptors keep their prior shape, and worker/SDK admission checks the array
independently. `tests/conformance/generic-functions.forb` and
`desktop/config/generic-functions-baseline.forb` are the product fixtures.
See [RFC-0038](../../docs/rfcs/0038-explicit-generics.md). Effect polymorphism, generic types and L6-L10 remain active.

## Explicit effect parameters

A generic parameter may be `E:effect`, written at references as an effect set with its
first word bare (`computes`, `reads<writes>`, `transacts<decides>`), and used as `<E>` in headers and
`function<E>(...)` types:

```forbic
Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{F(F(X))}
Moved:i64=Apply[transacts,i64](Bump,2)
```

Each specialization is checked as an ordinary concrete function, so effects and
call syntax stay exact; there is no inference or subtyping. `<E>` already carries
the decides bit. Specialization keys carry the effect as a canonical witness
function type, so reports and admission reuse the RFC-0038 shapes. See
[RFC-0039](../../docs/rfcs/0039-effect-polymorphism.md) and `tests/conformance/effect-polymorphism.forb`.

## Array element reads

`Items[I]` reads an element of an array and fails when `I` is outside
`0..Length-1`. It is a failable bracket operation, so it needs an `Attempt` body
or a `<decides>` function:

```forbic
Pick(I:i64)<computes>:i64=Attempt(Items[I],-1)
Cell:i64=Attempt(Rows[R][C],0)
```

The bound is checked by an ordinary `demand`, so rollback and failure traces
match `Require`. See [RFC-0040](../../docs/rfcs/0040-array-index.md) and `tests/conformance/array-index.forb`.
Array concatenation, iteration and writes through an index remain separate work.

A fold over an array needs no new primitive: explicit generics, `Loop` and
`Items[I]` already compose. `tests/conformance/array-fold.forb` defines

```forbic
Fold[T:type,A:type](Step:function(tuple(T,A),T),Items:[]A,Init:T)<computes>:T{Loop(Fn[Step:function(tuple(T,A),T)=Step,Items:[]A=Items](S:tuple(i64,T))<computes>:option(tuple(i64,T)){Attempt(option{tuple{S(0)+1,Step(S(1),Items[S(0)])}},option{})},tuple{0,Init})(1)}
```

and uses it for sums, maxima, empty arrays and strings. The failed read at the end
of the array is what stops the loop. A reusable standard library for such helpers
belongs to L10.

## Numeric conversions

`Floor[X]`, `Ceil[X]`, `Round[X]` (ties to even) and `Int[X]` (toward zero)
convert a `float` to `i64`; they fail, like `Require`, unless `X` is finite and
fits `i64`, so they need an `Attempt` body or `<decides>` function. `ToFloat(N)`
converts an `i64` to the nearest `float`. There are no implicit conversions. See
[RFC-0041](../../docs/rfcs/0041-numeric-conversions.md) and `tests/conformance/numeric-conversions.forb`.

## Native Zig functions

Performance-critical code can be written in Zig. A host registers typed Zig
functions; Forbic binds one with `Name := native{"id"}` and calls it like any
function. The signature is derived from the Zig type, so the two cannot disagree:

```forbic
Sum:=native{"std.sum"}
Sorted:=native{"std.sorted"}
Total:i64=Sum(array{9,3,7,3})
```

Natives are pure and total, take up to four parameters (`i64`, `logic`, `float`,
`string`, arrays of scalars) and return a scalar, an option or an array. Natives
work anywhere, including function bodies, loops and rollback. Each call is charged its declared cost before it runs, bounded by the
guest member pool, admitted independently by both machines and re-checked on return.
A fatal native error is a diagnostic that `Attempt` cannot catch. The standard table
(`std.sum`, `std.sorted`, `std.range`, `std.find`, `std.dot`, `std.sqrt` and more)
is available by default; hosts supply their own through `workspace.natives`. See
[RFC-0042](../../docs/rfcs/0042-native-zig-functions.md) and `tests/conformance/native-std.forb`.

## Strings built at run time

`A + B` concatenates, `S.Length` is the byte length, and `ToString(X)` renders an
`i64`, `float` or `logic`. Run-built strings append to the unused tail of the
program's string pool (bounded by the 64 KiB string budget; overflow is
`string_limit`) so every string stays a reference into one validated pool. The
standard natives add `std.substring`, `std.index_of`, `std.contains`,
`std.starts_with`, `std.ends_with`, `std.upper`, `std.lower`, `std.trim`,
`std.repeat`, `std.join`, `std.split` and `std.parse_int`. See [RFC-0043](../../docs/rfcs/0043-run-owned-strings.md) and
`tests/conformance/strings.forb`.

## Compound assignment

`set X += e` (also `-=`, `*=`, `/=`) means `set X = X op (e)` for cells and block
locals, including floats and `+=` on strings; `X` is read before `e` runs. See
[RFC-0044](../../docs/rfcs/0044-compound-assignment.md) and `tests/conformance/compound-set.forb`.

## Type aliases

`Name := type` names any spellable type; the alias is transparent (the same
structural type), declared before use and private to its module:

```forbic
Grid:=[][]i64
Total(G:Grid)<computes>:i64=Attempt(G[1][0],-1)
```

See [RFC-0045](../../docs/rfcs/0045-type-aliases.md) and `tests/conformance/type-aliases.forb`.

## Array concatenation

`A + B` joins two arrays of the same type into a fresh immutable array (one unit of
work per produced element; overflow of the member pool is `aggregate_limit`):

```forbic
Append(Items:[]i64,N:i64)<computes>:[]i64=Items+array{N}
```

See [RFC-0046](../../docs/rfcs/0046-array-concatenation.md) and `tests/conformance/array-concat.forb`.

## Type inference

`Name := expression` binds an immutable value with the expression's type, at the
top level and in `Block` locals (`var` bindings still declare their type; contextual
empties need a declared type). See [RFC-0047](../../docs/rfcs/0047-type-inference.md) and
`tests/conformance/type-inference.forb`.

## Failable conditions

A failure inside an `If` condition (an index, a `<decides>` call or a conversion,
all written with brackets) selects the else branch, as if written
`If(Attempt(condition, false), ...)`; writes made by the failed condition are rolled
back. A condition with an explicit `Require`/`Fail` still fails the enclosing region.
See [RFC-0049](../../docs/rfcs/0049-failable-conditions.md) and `tests/conformance/failable-conditions.forb`.

## Case

`Case(Scrutinee, Pattern=>Value, ..., _=>Default)` picks the first arm whose pattern
equals the scrutinee (a name or field path); arms are lazy and a final `_` default
is required. See [RFC-0050](../../docs/rfcs/0050-case.md) and `tests/conformance/case.forb`.

## Field updates

`WithField(Record, Field, Value)` returns a copy with one field replaced, and
`set P.A.B = e` (also `+=`, `-=`, `*=`, `/=`) assigns the rebuilt record back to `P`:
structs have value semantics. See [RFC-0051](../../docs/rfcs/0051-field-updates.md) and
`tests/conformance/field-updates.forb`.

## Array element updates

`WithIndex[Array, Index, Value]` returns a copy with one element replaced and fails
outside `0..Length`; `set A[I] = v`, `set Grid[1][0] = v`, `set P.Xs[I] += v` rebuild
the path (failable, so use them in a failure context). See
[RFC-0052](../../docs/rfcs/0052-array-element-updates.md) and `tests/conformance/array-updates.forb`.

## String interpolation

Inside a string, `{expr}` splices the text of an `i64`, `float`, `logic` or `string`
expression: `"Hello {Name}! n={Count+1}"`; `\{` and `\}` write literal braces. See
[RFC-0053](../../docs/rfcs/0053-string-interpolation.md) and `tests/conformance/interpolation.forb`.

## Implicit captures

An `Fn` without `[...]` captures the enclosing locals and parameters its body names, by
value, and may omit `<effect>` and `:Type`: `Fn(X:i64){N+X}`. See
[RFC-0054](../../docs/rfcs/0054-implicit-captures-and-inference.md) and `tests/conformance/closures.forb`.

## For iteration

`For(X:Items, Body)` maps an array, `For(I->X:Items, Body)` adds the index, and conditions
between head and body filter: `For(X:Items, X>3, X*2)`. See
[RFC-0056](../../docs/rfcs/0056-for-iteration.md) and `tests/conformance/for-loops.forb`.

## Maps and options

`M[K]` looks a key up (failable), `Opt?` unwraps an option (failable), and
`set M[K] = V` inserts or replaces. See [RFC-0057](../../docs/rfcs/0057-map-updates-and-option-unwrap.md) and
`tests/conformance/map-updates.forb`.

## Default and named arguments

`F(A:i64, B:i64=10)` declares a default; calls may omit it or name it: `F(1, B:=5)`. See
[RFC-0058](../../docs/rfcs/0058-default-and-named-arguments.md) and `tests/conformance/named-arguments.forb`.

## Condition bindings and destructuring

`If(X := Items[I], X > 3, Then, Else)` binds names across failable conditions, and
`(A, B) := Pair` destructures a tuple. See [RFC-0059](../../docs/rfcs/0059-condition-bindings-and-destructuring.md) and
`tests/conformance/condition-bindings.forb`.

## While loops

`While(I < N, Block{ set Total = Total + I; set I = I + 1 })` loops over `var` locals; see
[RFC-0060](../../docs/rfcs/0060-while-loops.md) and `tests/conformance/while-loops.forb`.

## Overloading

Functions of one name may differ in parameter types: `Twice(X:i64)` and `Twice(X:float)`. See
[RFC-0061](../../docs/rfcs/0061-overloading.md) and `tests/conformance/overloads.forb`.

## Not and using

`Not[E]` succeeds when `E` fails; `using{L}` brings the public names of an imported module into
scope. See [RFC-0062](../../docs/rfcs/0062-not-and-using.md) and `tests/conformance/not-combinator.forb`.

## Diagnostics with source excerpts

`forbic check|eval|inspect|trace|qualify FILE --diagnostics=excerpt` prints the source under the
header of a diagnostic: numbered lines and a caret underline, on standard error. The header
(`path:line:column: error: message`, columns counted in bytes) is the same as ever, and so is
every diagnostic without the option: `--diagnostics=plain` is the default. Any other value is
refused (exit 2); the option is given at most once, among the other options and before
`--bundle`.

```text
tests/conformance/alignments-error.forb:2:6: error: this name is already visible here and may not be shadowed: choose another name (first declared at 1:1)
  2 | Next(Count:i64)<computes>:i64=Count+1
    |      ^~~~~
note: first declared here
  1 | Count:i64=0
    | ^~~~~
```

Tabs advance to the next stop of four cells; every Unicode scalar is one cell (wide glyphs and
combining marks are not measured, so they may not line up on every terminal); controls, invisible
formatting characters and bytes that are not UTF-8 are shown as ASCII escapes (`\x1B`, `\u{202E}`),
and the underline is measured on what is printed. A span over several lines shows its first and
last lines with a line of context each and `...` for the lines left out; an empty span, and the
end of the file, get one caret. A line longer than 160 cells is cut around the mark with `...`;
a diagnostic's excerpt is at most 8192 bytes, and says when it was cut. A diagnostic whose span is
not in the source (or lies in text the compiler generated) reads `source excerpt unavailable`.
Diagnostics in an imported module of a bundle show that module's own source. See
[RFC-0088](../../docs/rfcs/0088-reports-and-tooling-at-scale.md), "D1 as implemented", and the
fixtures `tests/conformance/excerpt-*-error.*`.

`forbic run DIR` and `forbic check DIR` take a project directory: `DIR/forbic.json` names the root
module (`{"root": "/hello@example.com/Hello"}`) and `DIR/src/` holds the folder tree of RFC-0093,
one folder per module. `run` is `eval` by another name, with every option `eval` takes; `check`,
`eval`, `trace`, `inspect` and `qualify` take a project wherever they take a FILE (a directory
named with `--bundle` is still read as a packet). The directory is read into the packet of its
tree, its sources in the byte order of their paths, and runs as that packet does; a journal
records the packet's SHA-256. A diagnostic names its file on disk
(`DIR/src/hello@example.com/Hello/main.forb:2:13: error: ...`). Only `.forb` files under `src/`
are read, names starting with `.` are left out, a symbolic link or junction among the manifest,
`src/` and what the walk reads under it is refused (nothing is read through a link), a folder
holding sources must have a module path, and the walk is bounded by the profile (sources, entries, path length and
source bytes); a refusal names the path and the bound, exits 1 and runs nothing. Try
`examples/hello-project`; see [RFC-0095](../../docs/rfcs/0095-project-layout.md).
