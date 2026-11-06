# Forbic implementation

Compiler, intermediate representation, reference pure evaluator, bytecode lowering,
verified register VM, and bounded transaction journal live here. The config CLI
path, live Stanza, shell and pure extension host use `bytecode.Workspace`.
Compiler workspaces contain only front-end storage. Reference evaluation receives
separate caller-owned value storage; differential tests retain this independent
oracle alongside the VM's registers. Both evaluators borrow compiler IR/string
storage and input source, so those must outlive the result.
The compiler checks computes/transacts/decides effects and typed per-run source
mutation. Broader native effects remain next. Internal VM
transaction instructions and journal APIs are covered by differential tests,
failure injection, bytecode mutation, and snapshot-based deterministic simulation.

See [RFC-0005](../../docs/rfcs/0005-bounded-transaction-runtime.md) for ownership,
resource bounds, nested rollback, and committed intent acknowledgement. These
records do not execute native actions. Scheduling, GC, persistence, capabilities,
and reactive state need later contracts.

See [language RFC](../../docs/rfcs/0002-forbic-core.md). The Book of Verse is a
reference, not automatic conformance proof for this intentionally different dialect.

The [completion track](../../docs/completion.md) defines subsequent
increments. Binary64 float literals/functions/arithmetic use distinct verified
opcodes, strict rounding and canonical NaN; both independent execution paths,
inspection and JSON value reporting implement the pure-core numeric contract.

Structural tuple schemas use a bounded separate Type pool and existing immutable
aggregate member storage. Constructors and positional access are independently
verified in the IR evaluator and VM; iterative reporting uses diagnostic JSON
arrays and inspection format 4. Tuple syntax, exact resource profiles and
limitations are specified in [RFC-0018](../../docs/rfcs/0018-immutable-tuples.md).

Options and insertion-ordered maps share aggregate storage. Total `Lookup` borrows
a value member; strict `Or` provides a typed fallback. Dynamic key hashes/probes
and comparisons consume fuel, including exact string bytes. Report preflight
admits all borrowed values before hashing and rejects forged duplicate keys.
[RFC-0019](../../docs/rfcs/0019-options-maps.md) defines the collection contract.

Immutable module bundles use compiler-owned original source partitions and path
pools. Prefix imports resolve within a supplied inventory, enforce public names
and reject cycles. IR/VM/report admission independently checks provenance and
root-only bindings. Strict fixed-storage JSON packets support explicit product
bundle mode and API-v2 whole-packet integrity. See
[RFC-0020](../../docs/rfcs/0020-immutable-module-bundles.md).

Typed scalar/enum predicates and strict logic lower to dedicated verified opcodes.
Both engines independently check operand types and the dynamic string-comparison
count; NaN equality and ordering are explicit. Value/Node/VM reservation sizes and
capacities remain stable. [RFC-0021](../../docs/rfcs/0021-predicates.md) defines
these predicate foundations. Lazy If/Attempt and explicit source failure are
specified in [RFC-0022](../../docs/rfcs/0022-failure-regions.md). Both engines
independently admit arm dominance; control results borrow activity and trace storage.
Reference control callers use evaluateWithControlStorage with persistent caller
storage. Source mutation additionally requires evaluateWithStateStorage and
caller-owned ReferenceState full images; the VM uses an independent typed undo
journal. Reporting reconstructs copied cell Values and rollback before output. See
[RFC-0023](../../docs/rfcs/0023-source-mutation.md). Eligible straight-line computes helpers use bounded iterative runtime frames;
computes If, caught failure, computes/decides and transacts bodies use frames; defaults retain templates. See
[RFC-0024](../../docs/rfcs/0024-runtime-calls.md). Runtime bodies use immutable
borrowed node encoding, decoded into VM operations independently of IR admission.
Persistent reference callers use evaluateWithRuntimeStorage and ReferenceStorage;
compatibility APIs reserve cold stack scratch whose borrows cannot escape.
Returned aggregates refer only to the external run member pool. Native effects,
counted iteration follows RFC-0031; direct self-recursion follows RFC-0032.
[RFC-0025](../../docs/rfcs/0025-frame-branches.md) adds independently admitted
per-function branch structure, transitive control flags and bounded call-step
evidence in caller ControlStorage. Reports replay branch/copy/return/constructor
paths with independent bounded scratch before hashing maps or producing output.
Calls alone keep root activity dense; reference APIs without persistent control
storage reject emitted controlled calls, preserving ownership. Inspection format
11 exposes branch metadata. Internally caught computes failures add own-frame
catchers, explicit failure steps and transitive failure metadata, independently
admitted even when unused. Reports consume callee failures in global chronology
without restoring caller cell versions. Inspection12 and failure trace format2
expose the defining scope; root-only failure reports retain format1. Memory
profile10 records catcher/step/trace ABI changes with unchanged capacities.
[RFC-0026](../../docs/rfcs/0026-frame-failure.md) defines caught failure. Declared
decides helpers can now propagate language outcomes iteratively to caller catchers;
only the origin records a failure. Root catches restore their source region.
Independent IR/VM context passes include unused and untaken calls. Reports admit
every readable Value before map hashing, then replay one reconstructed root/callee
schedule, including inactive failed calls, propagated causes and root termination.
The former root-call-end array and duplicate trace traversal are removed. Root
constructor copies are checked too; report work includes descriptors, root/callee
visits, constructor copies and expanded output. Inspection13 exposes decides;
memory profile11 adds failure/outcome ABI rows and versions replay ownership with
unchanged capacities. [RFC-0027](../../docs/rfcs/0027-failable-frames.md) records
this increment; simulation and SDK/worker fixtures exercise cross-frame recovery.

Transactional frames share caller-owned per-run source cells. Source-capable own
Attempt bodies use the existing33 regions and8192 undo budget; no region opens
merely on a call. Pure catchers preserve caller writes. Independent IR/VM checks
include declared effects, defining-module cell spans, visibility, availability and
typed operands in unused bodies. Report replay shares copied current Values and
full images across root/callee schedules and charges source copies separately
from guest fuel. Inspection14 exposes transacts/source metadata. Memory profile12
measures cold source replay scratch separately from overlapping persistent ABI
rows; it replaces the earlier33792-byte root-version scratch with278680 bytes on
x86_64. Guest capacities are unchanged. [RFC-0028](../../docs/rfcs/0028-transactional-frames.md)
records the contract; native actions remain later.

Typed lexical Block expressions compile immutable locals to earlier root/body
operands. Every initializer and discarded computation remains strict; lazy arms
and own/root rollback preserve existing effects and evidence. The iterative parser
uses the existing128 expression stack and a separate256-live-name catalogue.
Closed scopes reuse its prefix; names never enter public bindings or runtime
captures. A result can alias an earlier register after later strict operations.
Memory profile13 records the compiler catalogue and live-local capacity, with
unchanged runtime reservations and cold source scratch. Inspection/value/SDK/
config/trace formats are unchanged. [RFC-0029](../../docs/rfcs/0029-local-blocks.md)
records this increment; [RFC-0030](../../docs/rfcs/0030-mutable-locals.md) adds
mutable locals with version selection and rollback.

Mutable Block locals use `var Name:Type=Expr`, `Set(Name,Expr)` and `set Name=Expr`
statements. Assignments/initialization require transacts and add one typed copy
operation/fuel unit. Earlier immutable aliases retain snapshots. Compiler-only
checkpoints pack live versions in groups of128, merge the selected lazy arm and
extract the result/state. Attempt failure selects the saved versions before
fallback; globals retain their separate source journal. Hidden tuples consume
ordinary node/type/member/fuel/report budgets. Runtime calls with local assignments
retain checked step evidence via independently recomputed has_local; copied
assignment/projection Values are replayed before output. Inspection15 and memory
profile14 record this representation and32 compiler checkpoints. No local
references or mutable captures escape. General loops require later control
contracts; cold source replay scratch and per-run state quotas stay unchanged.

`Iterate(Step,Count,Initial)` repeatedly applies an earlier one-parameter helper
whose parameter/result have the same exact type. Count is nonnegative i64; zero
returns the strictly evaluated Initial without a frame. Negative counts are fatal
after both operands evaluate. Declared effects are admitted even for zero/unused
iteration. Count and Initial evaluate in order; empty constructors inherit the
helper's state type. Each dispatch costs one fuel unit in addition to the Iterate
opcode and helper inputs/operations. Existing fuel/events/members bound large
counts; there is no separate arbitrary count limit.

The Step frame holds the remaining count and immutable seed. Both machines reuse
its register range without native recursion; returned aggregates borrow append-only
external member storage. Ordinary alias calls keep templates; iteration separately
publishes a reusable alias body. Nested iteration uses normal32-frame depth and
8192-register/event bounds. It creates no source region: enclosing Attempt can
undo global writes from earlier visits. Reports independently replay every visit,
seed/result copy, physical constructor and failure continuation before output.
Inspection16 exposes root/unused-body iteration; profile15 publishes changed frame
arrays and cold replay reservations. [RFC-0031](../../docs/rfcs/0031-counted-iteration.md)
records the contract. General loops, mutual recursion, callable captures, generics
and native actions remain on the completion track.


Typed direct self calls encode body-only recur argument ranges with the current
function implicit. Named calls still target earlier catalogue entries; no forward
placeholder or native recursion is introduced. Independent IR/VM admission checks
exact signatures, earlier and arm-visible operands, argument-pool chronology,
effects and unused metadata. Self operations force control evidence and saturate
possible constructor work, including untaken arms. Both existing machines push
ordinary guest frames, preserving the VM's held-PC/indirect arguments and the
reference machine's advanced continuations/copied parameters. A recursive child
inside Iterate has no iteration controller; the Step resumes after it returns.
Existing32 frames,8192 live registers/events/members and fuel bound execution.
Source writes share caller rollback; fatal cleanup consumes no fuel. Replay checks
parameter/return copies and propagated defining causes before output. Inspection17
identifies unused self bodies; profile15 and storage capacities remain unchanged.
See [RFC-0032](../../docs/rfcs/0032-bounded-self-recursion.md). Forward/mutual calls,
callables/generics and remaining runtime guarantees stay on the completion track.


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

A generic parameter may be `E:effect`, written at references as `computes`,
`transacts`, or either with `<decides>`, and used as `<E>` in headers and
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
