# Forbic bootstrap pure core

Status: experimental implementation contract. This is a deliberately small
strict subset, not full Verse compatibility or an accepted complete language.

```forbic
Gaps<public>:i64 = 3 * 2
MasterPercent:i64 = 55
Terminal:string = "ghostty"
Theme:string = "kanagawa"
Animations:logic = false
```

Top-level immutable bindings require annotations (scalar, earlier record/enum,
array, tuple, option or map types).
Declarations are separated by a newline or semicolon. `#` starts a line comment.

Names are ASCII identifiers; string content is valid UTF-8. Names may refer only
to earlier bindings/functions/types, except that a function body may call a function declared
further down (RFC-0091, "Functions completion" below). Optional `<public>` marks a public binding. Duplicate names
and unsupported effects/imports/syntax are errors.

Integer expressions support parentheses, unary `+`/`-`, and binary `+`, `-`, `*`,
`/`, with conventional precedence and left associativity. Division truncates
toward zero; overflow and division by zero are diagnosed without host crashes.
Failable Euclidean division is `Quotient[A, B]` and `Mod[A, B]`, and exact
division is `Rational[A, B]` (see "Euclidean division and rationals" below).
The explicit `i64` type is a systems integer. Verse's unbounded `int` is not yet
implemented and is rejected. String escapes are the Book's thirteen: `\t \n \r \" \' \\ \{ \} \< \> \& \# \~`
(RFC-0089); each stands for the character after the backslash.
String/logic values support literals and earlier binding references, not coercions.

### Lexical forms (RFC-0089)

- Integers are decimal or `0x` followed by hexadecimal digits of either case (`0xFF`); both
  must fit the signed 64-bit range (`-0x8000000000000000` is the smallest). `0x` with no digit,
  or followed by a name character or a fraction, is `invalid_hex_literal`.
- `<# ... #>` is a comment that nests and may span lines (a newline in it is not a token).
  `<#>` starts an indented comment: standing first on its line, it takes the rest of that line
  and the following lines that are blank or indented four columns (a tab is four) past it; anywhere but first on its line it is
  `misplaced_indented_comment`. A block comment with no end is `unterminated_comment`. Nothing inside a string literal is a comment.
- `Name:type := v` means `Name:type = v` for constants and `var`s; `var Name := v` is still an
  error.

## Binary64 numeric semantics

`float` is IEEE 754 binary64. Decimal literals have grammar
`digits ('.' digits)? ([eE] [+-]? digits)?`, with a fraction or exponent required
to distinguish them from i64 literals. Examples: `0.55`, `1e3`, `6.25E-2`.
Leading/trailing decimal points and separators are unsupported. A float may end in the
suffix `f64` (`12.34f64`), which changes nothing; `1.` and `1f64` stay errors.
The sign is a unary operator. Decimal conversion rounds to nearest, ties to even;
underflow may round to subnormal or zero. A finite literal that rounds to infinity
is rejected with a range diagnostic; explicit `Inf`, `-Inf` and `NaN` are supported.
These names cannot be rebound or used as parameters.

Float expressions support the same precedence, associativity and `+ - * /`
operators as i64, with both operands required to be float. There are no implicit
numeric conversions or mixed i64/float operations. Float parameters/results work
in pure functions, including captured values and strict arguments.

Each operation uses Zig strict floating-point mode: binary64 rounding at operation
boundaries, without reassociation or fused multiply-add contraction. Signed zero
and subnormals are preserved. IEEE overflow and division by zero produce infinity
or NaN, rather than checked i64 errors. Produced NaNs normalize to quiet payload
`0x7ff8000000000000`. The rounding and conversion intrinsics are `Floor[X]`, `Ceil[X]`, `Round[X]`, `Int[X]` and `ToFloat(N)` (RFC-0041); a total
NaN ordering remains unimplemented; typed comparisons are specified below. Hosts must retain the normal rounding/subnormal
environment; this does not cover host code that changes floating-point control
modes or future platform-dependent transcendental libraries.

`forbic eval` and `inspect` emit finite floats as JSON numbers, and nonfinite values
as `"NaN"`, `"Inf"`, `"-Inf"` strings. This is diagnostic encoding, not a typed
artifact/round-trip loader. Inspection format 1 gains float types and `floating`,
`float_negate`, `float_binary` operations; existing scalar fields stay unchanged.
Desktop schema fields retain their required types; float does not implicitly
replace an integer field or relax validation.

## Typed predicates

`==`, `!=`, `<`, `<=`, `>` and `>=` produce `logic`. Operands have the same
exact type. Equality accepts scalar values and closed nominal enums; ordering
accepts i64/float and `rational` (RFC-0070). Mixed numeric types, cross-nominal enum comparisons and
aggregate comparisons are checked type errors. Two or more comparison operators
at one level without parentheses form a chain: `A <= B < C` means
`A <= B and B < C`, with every operand evaluated at most once and an operand
evaluated only if every link before it held. The six operators may be mixed and
each link is type-checked as the comparison it is. A chain whose shared operand
is `logic` (`A == B == C`) is `type_mismatch`: write the parentheses (RFC-0076).

`not` is unary; `and` binds more tightly than `or`. Unary operators bind above
arithmetic, arithmetic above comparison, and comparison above binary logic.
Binary logic short-circuits, left to right (RFC-0076): `P and Q` evaluates `Q`
only if `P` is true, and `P or Q` evaluates `Q` only if `P` is false. A skipped
operand does nothing: no write, no fatal error, no failure. A right operand is
*plain* when it holds only integer and float literals, `true`, `false`, `not`,
comparison operators, parentheses, further `and`/`or`, and names of locals,
parameters and constants of the current scope of type `logic`, `i64` or `float`.
For a plain operand the operator stays the strict `logic_binary` node, whose
result and effects equal skipping; its fixed node count is charged as fuel either
way. Any other right operand makes the operator the conditional `If(P, Q, false)`
or `If(P, true, Q)`, and a skipped operand then costs no fuel. Both remain
`logic` operators, not failure combinators; explicit failure contexts and
failable calls are described below.

NaNs compare equal to each other. All four ordering predicates are false with
any NaN operand, including two NaNs. Signed zeros compare equal; numeric extrema,
infinities and subnormals retain exact ordering. UTF-8 string equality compares
decoded bytes without normalization; enum equality preserves nominal identity.
Each operation costs one unit; string equality additionally charges the shorter
byte length before comparison. Both independent validators recompute the emitted
string-comparison count so metadata cannot bypass fuel. Inspection format 7
reports predicate operations; prior programs retain formats 1-6. See
[RFC-0021](rfcs/0021-predicates.md), `tests/conformance/predicates.forb` and
`desktop/config/predicates-baseline.forb`.

## Lazy expressions and failure regions

`If(condition, first, second)` checks both same-type arms and executes only one.
`Attempt(body, fallback)` selects its same-type fallback on explicit language
failure. `Require[logic]` returns true or fails; `Fail[string]` fails with a reason
and needs a contextual result type. Calls to `<computes><decides>` helpers use
square brackets and require an Attempt body or a decides function. A fallback
is outside its own Attempt; it can fail outward to an enclosing body. Arithmetic,
duplicate-key, fuel, storage and admission errors terminate execution.

```forbic
Check(X:i64)<computes><decides>:i64=If(Require[X>=0],X,Fail["negative"])
Gaps<public>:i64=Attempt(Check[-1],If(true,6,1/0))
```

Independent IR/VM admission checks every arm's scope/dominance and 32-level
structured control targets before execution. Merges expose selected results;
arm-local temporaries cannot escape. Executed instructions/member copies consume
fuel; skipped ones consume none. Immutable failed-body members remain in bounded
run storage until reuse. Attempts own nested VM journal regions, including rollback of the typed source
cells specified below. This version has no native actions. Rollback cannot undo external work.

VM execution publishes a borrowed activity bitmap, first 32 caught traces, total
failure count and aggregate member prefix. Sparse reporting reconstructs the
schedule before reading skipped registers or writing output. Reference control
execution requires `evaluateWithControlStorage` and caller-owned `ControlStorage`;
legacy reference APIs reject control programs with `control_storage_required`.
All slices and reason strings borrow run storage and immutable program pools until
reuse. `forbic trace FILE [--bundle]` exposes defining-file reasons and local byte
locations; trace output preflights 4 MiB. Root-only control inspection uses format8;
runtime function programs use formats10-13 described below. See
[RFC-0022](rfcs/0022-failure-regions.md), `tests/conformance/failure.forb` and
`desktop/config/failure-baseline.forb`. Runtime transacts bodies, broader native
effects and loops remain in the completion track.

## Typed source mutation and transaction effects

`var Name<public>:type=initializer` declares a per-run typed mutable binding;
visibility is optional. `set Name=expression` writes one. Expression
`Set(Name,expression)` evaluates its value once and returns the assigned value.
Targets are static mutable names, including qualified public imported cells.
Parameters, immutable bindings, field paths and array elements are not write
targets. Exact types and contextual empty aggregates apply as for other bindings.
Public root mutable bindings export their final value; earlier immutable copies
keep their observed value.

```forbic
var Count<public>:i64=1
First(X:i64,Y:i64)<computes>:i64=X
Increment(X:i64)<transacts>:i64=Set(Count,Count+X)
Discard:i64=Attempt(First(Increment(5),Fail["discard"]),Count)
set Count=Count+1
```

Count exports 2; Discard observes 1 after rollback. All source execution owns an
implicit outer transaction. Successful child Attempts merge their writes into the
parent; parent abort also undoes those child writes. Fallback begins after child
rollback and can write in its enclosing transaction. Fatal errors abort the entire
run without guest cleanup fuel. Every init/read/write costs one operation after
strict operand evaluation. Aggregates are whole immutable values assigned to cells;
old aliases/map views keep immutable member borrows. This adds no class/field
identity or state that persists across runs.

Functions declare a heap effect: `<computes>`, `<transacts>`, or some of `<reads>`,
`<writes>`, `<allocates>` (see "Effect families" below), with `<decides>` or `<suspends>`
in any order. Computes bodies/defaults cannot read/write mutable cells or invoke
helpers with heap effects, even in unused bodies/untaken arms. Transacts bodies can. Passing
an already observed value into a computes parameter remains valid. Decides helpers
use square-bracket calls in failure contexts; other helpers use parentheses. Root
expressions have implicit transaction effects. Transacts bodies use runtime frames;
local variables are implemented by RFC-0030 on L5.

IR and bytecode independently validate 256 typed cell definitions, exact root
initialization before every read/write, privacy, types, dominance and a separately
counted source-operation prefix. Counts cannot hide malformed untaken tails. The
VM owns a typed journal with 8,192 shallow undo records and 33 frames (outer plus
32 active root or source-capable frame Attempts), checked before writes. Its older retained i64 journal/outbox API is
separate. Reference `evaluateWithStateStorage` receives caller-owned
`ReferenceState` full snapshots and `ControlStorage`; older APIs return
`state_storage_required` after admission for source programs. Caller storage and
program pools stay immutable while results are consumed; all borrows expire on
owning reuse. Cells reset for every admitted run, including reuse for pure programs.

Reporting independently reconstructs copied current cell Values/rollback and
validates root/callee reads/writes before output. Full cell images/checkpoint undo
counts replace root-register versions because returned frames can write cells.
Cold source replay scratch is278680 bytes on x86_64, measured separately in memory
profile12. This replaces33792 bytes of root-only versions/images, in addition to
other bounded replay frame/value/control scratch. Copying/restoring each cell
costs one report-work unit, without consuming guest fuel. Memory
profile7 reports the overlapping VM journal/reference image reservations;
allocator, stack and RSS measurements are separate. Inspection format 9 includes
typed cell definitions and source-operation count; older programs retain formats
1-8. CLI/desktop/extension value formats remain unchanged. Extension manifests
retain immutable metadata admission and reject source cells before evaluation.
Source transactions cannot undo external OS work. See
[RFC-0023](rfcs/0023-source-mutation.md), `tests/conformance/mutation.forb` and
`desktop/config/mutation-baseline.forb`.

## Pure functions

Pure functions require annotated parameters/results and `<computes>`:

```forbic
Base:i64 = 2
Scale(Unit:i64)<computes>:i64 = Unit * Base
Label()<computes>:string = "Traverse"
Gaps<public>:i64 = Scale(3)
```

A parameter may not take a name that is visible where it is declared
(`shadowed_name`, RFC-0076): an earlier binding, cell, function or type, an
import alias, a public name of a module in `using`, or the function's own name.
Globals/functions capture their earlier declarations. Optional `<public>` precedes the function's parameter list.
Arguments are strictly evaluated even if a parameter is unused. Unused function
bodies are type-checked without executing arithmetic. Eligible computes helpers,
including lazy If, caught failures and computes/decides bodies, use bounded
iterative runtime frames. Transacts helpers share source cells in runtime bodies;
defaults retain templates and can contain eligible runtime calls. Bodies
consisting only of parameter aliases retain alias elimination and strict argument
evaluation. Direct self-recursion uses bounded guest frames under RFC-0032.
Calls to a function declared further down from the root, a default, a generic body or a constructor function (RFC-0091), unsupported effects, incorrect
argument counts/types and ambiguous names are diagnosed. Function declarations are
metadata; RFC-0033 also admits typed function references as values in bindings.
`forbic eval` returns bindings only.

Diagnostics use one-based line and UTF-8 byte column positions. `<public>` is
retained as IR metadata and enforced across explicit bundle imports.

## Immutable modules

The host supplies a `modules.Bundle` inventory and root path to
`compiler.Workspace.compileBundle`. All inputs are immutable. Prefix imports use
`Theme := import{"theme.forb"}`. Qualified public names work in annotations,
constructors, enum cases, field selection and calls; private names stay local.
Public signatures and fields cannot expose private nominal types. A parameter or
local may not take the name of an import alias of its file (`shadowed_name`,
RFC-0076). Sibling nominal types remain distinct;
structural types share the existing catalogue.

Paths are canonical case-sensitive UTF-8 POSIX paths. Unescaped source import
paths resolve relative to the importing file, normalize dot components and cannot
escape the virtual root. Cycles, missing files, duplicates, late/public imports
and namespace collisions produce checked diagnostics. Lexical dependency order
is deterministic and independent of inventory order. Reachable unused declarations
are checked; extra inputs have path/size/UTF-8 admission without compilation.

The bootstrap accepts 64 inventory modules, 256 imports, 256 bytes per path and a
16,384-byte path pool. Inventory source totals and joined reachable source each
fit the 65,536-byte source pool, including joining newlines. Compiler-owned
source/path pools preserve exact original partitions. IR/VM/report admission
checks all metadata before execution/publication. Results expose root bindings;
imported nodes execute and retain their original diagnostic file/line/byte column.

CLI commands take a strict JSON `{root,modules:[{path,source}]}` packet with a
trailing `--bundle`. Inspection format 6 adds module/import tables and local
instruction spans. Bundled enum strings use `path::type.case`. Extension API 2
hashes the entire exact packet before parsing; API 1 remains single-source.
See [RFC-0020](rfcs/0020-immutable-module-bundles.md),
`tests/conformance/modules.bundle.json` and `desktop/config/modules-baseline.json`.
Modules declared inside a file are described under
[Nested modules](#nested-modules-access-levels-and-exported-aliases), and a bundle given as a
folder tree under [Module paths and folder modules](#module-paths-and-folder-modules).

## Module paths and folder modules

```forbic
# user@example.com/App/main.forb, a file of the folder module /user@example.com/App
Kit := import{/user@example.com/App/Kit}
using{/user@example.com/Lib}
using{/user@example.com/App/Kit/Geometry/Flat}
Square<public>:i64 = Area(Kit.Side, Kit.Side)
```

A bundle whose `root` is a module path (`/user@example.com/App`) is a folder tree: each file
belongs to the module of its folder (`a/b/c.forb` to `/a/b`, whose first segment is a domain
and whose others are names), and the files of a folder are one module, joined in the byte order
of their names, one namespace with sequential declarations: a later file reads the internal
names of an earlier one. `Name := import{/D/A}` at the start of a file aliases a folder's module
for the whole module; `using{/D/A}` brings in its public names from there to the end of the
module, through its later files; `using{/D/A/Inner}` or `using{/D/A/Inner.Deeper}` reaches a
module declared in a file of the folder, with its access (after a domain alone, `/D/Inner`: a
domain may hold `.`). A path names the longest folder of the tree it begins with; a subfolder is
a module of its own path, and a file may not declare a module of a subfolder's name, nor one with
a folder below its path (`M` with a folder `/D/A/M/B`, even when `/D/A/M` has no file), so that a
path never means two modules; both machines' admission checks it too. Paths are absolute and the host gives the tree: nothing is looked up. The
lexer reads a path where a division has no left operand, after `{` or `(`. A path in a single
file is `module_bundle_required`, in a bundle of files `folder_bundle_required`; a quoted import
in a tree is `path_import_required`. Reports and function values name the module path, an enum
value prints `/user@example.com/Lib::color.green`, inspection lists `module_files`, and every
diagnostic, also of a run, points into the file with its own line and column. Both machines
admit the module, file and import tables of a tree before running it (`modules.validateBundle`).
The bootstrap takes 64 files, the `program` profile 16,384. See
[RFC-0093](rfcs/0093-module-paths.md) and `tests/conformance/module-paths.bundle.json`. On disk a
folder tree is a project: a directory whose `forbic.json` names the root module and whose `src/`
holds the tree, which `forbic run DIR` and `forbic check DIR` read
([RFC-0095](rfcs/0095-project-layout.md), `examples/hello-project`).

## Immutable records and arrays

```forbic
palette<public> := struct { Bg:string, Opacity:float }
Base:palette = palette{Opacity := 0.7, Bg := "#101820"}
Colors:[]palette = array{Base, Base}
Background:string = Base.Bg
Count:i64 = Colors.Length
Empty:[][]palette = array{array{}, array{Base}}
```

Records have nominal identity and public immutable fields. Struct declarations
use braces, with comma/newline separated annotated fields. Constructors supply
each explicit field once with `:=`, in any order; commas/newlines and a trailing
comma are accepted. Expressions evaluate in source order, while stored fields
follow declaration order. Field selection is a postfix expression, including
after calls/constructors and through nested records. Empty records are valid.
Types and values/functions share the top-level namespace; builtin type names,
`struct`, `array`, `enum`, `tuple`, `option`, `map`, `import`, `Lookup`, `Or`, booleans and
`not`, `and`, `or` and nonfinite literal names cannot be rebound.

Array types `[]t` are homogeneous, exact and structurally interned. Nonempty
`array{...}` can infer its element type; empty arrays require a contextual array
type from a binding/function result, parameter, record field or enclosing typed
array. `.Length` returns i64. There are no implicit conversions, structural record
coercions, methods/inheritance or recursive
schemas yet. Failable array indexing awaits source failure semantics. All custom
type references name earlier definitions, so the graph is acyclic.

Fields may specify a pure `= expression` default after the type annotation:

```forbic
palette := struct { Bg:string = "#101820", Opacity:float = 0.7 }
settings := struct { Theme:palette = palette{}, Labels:[]string = array{} }
Default:settings = settings{}
Custom:settings = settings{Theme := palette{Opacity := 0.9}}
```

Every default is type-checked at declaration but evaluated only when omitted
during construction. Explicit fields evaluate first in source order, then omitted
defaults in declaration order. Overrides suppress default evaluation; fields
without defaults remain required. Missing required fields reject compilation
before default expansion. Default failures retain their expression source spans.
Defaults capture earlier globals/functions, never caller parameters or sibling
fields. An earlier global with a sibling field's spelling remains capturable.
Defaults cannot reference the current/forward record type or constructed instance.
Builtin type names and aggregate syntax names cannot be used as value expressions.

Default bodies share the existing template-node/member/expansion budgets and
do not consume named-function slots. Compact eight-byte body descriptors are
compiler-owned metadata, one per admitted field; initialized prefixes track the
type catalogue. Expansion uses checked iterative remapping without runtime calls,
guest allocation or new bytecode/type metadata. Fully overridden defaults emit
no runtime operations. See [RFC-0016](rfcs/0016-record-field-defaults.md).

## Closed enums

```forbic
mode<public> := enum<closed> { Light, Dark }
settings := struct { Mode:mode = mode.Dark }
Keep(X:mode)<computes>:mode = X
Desktop:settings = settings{Mode := Keep(mode.Light)}
Allowed:[]mode = array{mode.Light, mode.Dark}
```

Enums are nominal types with qualified named constants. `<closed>` is optional
and the default; empty enums are legal uninhabited types. Cases can share names
across different enums, including spellings reserved for ordinary expressions.
A parameter or local may not take the name of an earlier enum type
(`shadowed_name`, RFC-0076); enum cases are not visible names and stay free. Cross-enum
assignment, unknown/duplicate cases, enum constructors, arithmetic and selection
from an enum value are rejected. Enums work in signatures, records/defaults and
contextual arrays. Open enums, comparisons, pattern matching, persisted schema
and publication compatibility are unimplemented. See [RFC-0017](rfcs/0017-closed-enums.md).

IR/bytecode enum literals carry the declaration-local case index and nominal type;
runtime values are immediate descriptors, with no member storage or allocation.
The whole case catalogue and every literal index are validated before execution,
including unused and malformed tails. Enum literals cost one execution work unit.
Value JSON uses qualified strings such as `"mode.Dark"`; inspection format 3
exposes the case catalogue once and typed literal indexes. Diagnostic encoding
is not a persisted or serialized executable ABI.

## Immutable tuples

```forbic
Pair:tuple(i64,string) = tuple{6,"Traverse"}
Gap:i64 = Pair(0)
Label:string = Pair(1)
Keep(P:tuple(i64,string))<computes>:tuple(i64,string) = P
Nested:tuple([]i64,tuple(logic)) = tuple{array{},tuple{true}}
Unit:tuple() = tuple{}
```

Tuple types are structurally interned ordered sequences of exact member types.
Empty and singleton tuples are distinct from scalars and arrays. Type annotations
use `tuple(t,...)`, with optional newlines and trailing commas. Constructors use
`tuple{...}`, accepting comma/newline separators and trailing commas, while
parentheses continue to group expressions. Members evaluate strictly in source
order. Empty arrays receive exact element types from positional context supplied
by annotations, signatures, fields/defaults and enclosing aggregates; other
members can infer their types.
Wrong arity and member types are compile errors. No implicit conversions,
destructuring or argument spreading are added.

Postfix `value(N)` selects a zero-based position using an unsigned decimal integer
literal, after bindings, parameters, calls, constructors, grouping or selections.
The compiler checks the index and exact result type. Nonliteral/out-of-range
indexes, positional access on other types and tuple `.Length` are rejected.
Dynamic/failable indexing awaits failure semantics. Tuples work in pure templates,
lexically captured defaults, records and homogeneous arrays.

Tuple schemas use a separate contiguous element Type pool; all ranges, earlier
references, structural uniqueness and unused tails are admitted before execution.
Runtime values reuse immutable aggregate descriptors and shallow member storage;
the separate `tuple_element` IR/bytecode operation costs one work unit. Tuple
constructors cost one plus copied members. No guest allocation or native recursion
is introduced. Value JSON uses arrays; inspection format 4 includes ordered
`tuple_elements` and positional instructions whenever a tuple definition occurs.
See [RFC-0018](rfcs/0018-immutable-tuples.md) and
`desktop/config/tuples-baseline.forb`.

## Immutable options and maps

```forbic
Settings:map(string,option(i64)) = map{"gap"=>option{6},"none"=>option{}}
Gap:i64 = Or(Or(Lookup(Settings,"gap"),option{}),12)
HasKey:logic = Lookup(Settings,"none").IsSet
Count:i64 = Settings.Length
```

Structural `option(t)` holds zero or one exact member. `option{}` requires context;
`option{value}` can infer it. Structural `map(k,v)` holds insertion-ordered exact
key/value pairs, written `map{key=>value,...}`. Empty maps require context; others
infer their first pair. Context from fields/defaults, signatures and enclosing
aggregates flows positionally. Keys admit every comparable type: i64, logic, UTF-8
strings, float, nominal closed enums, instances of a `class<unique>` (by identity;
`not_unique` for any other class, RFC-0076) and records,
tuples, options, arrays and maps of comparable parts (RFC-0065). String equality is
exact bytes, NaNs are equal to NaNs and signed zeros are equal; there is no coercion.

`Lookup(M,K)` returns an option of the value type. `Or(O,Fallback)` returns the
present member or fallback, with both arguments evaluated strictly. Empty and
present-empty nested values remain distinct. `.IsSet` returns logic and map
`.Length` returns pair count. Map keys/values evaluate in source order before
duplicate-key admission, which fails with `duplicate_map_key`. Failable indexing and
updates are RFC-0057; composite keys and key removal are RFC-0065.

Options/maps reuse immutable member storage. Lookup borrows an existing value
member instead of adding a guest allocation. Hashing uses deterministic numeric
byte order and bounded call-local scratch (at most 16 KiB); probes/key comparisons
charge fuel, including string bytes. IR size alone cannot establish full funding
for map programs. Resource exhaustion remains a located diagnostic. Value JSON
uses zero/one arrays for options and alternating key/value arrays for maps;
report preflight validates all borrowed strings before key admission. Inspection
format 5 applies whenever an option/map schema occurs. See
[RFC-0019](rfcs/0019-options-maps.md) and `desktop/config/collections-baseline.forb`.

## Aggregate representation and reporting

Type IDs 0..3 identify i64/logic/string/float; ID 4+n names definition n (`rational`
is such a definition, added when a program first uses it). The character
types `char` and `char32` have the fixed IDs 0xFF00 and 0xFF01, above every catalogue ID,
and print by name. IR carries
type, field, case and tuple element catalogues and one contiguous constructor
member-reference pool.
Runtime values carry small descriptors into a separate caller-owned immutable
Value pool. Constructors copy immediate members; nested values and assignments
share descriptors. No deep copies, native recursion or guest heap allocation
occur. Results borrow input/register/member storage until its next write.
The independent evaluator's `evaluateWithStorage` accepts both caller pools;
the scalar `evaluate` wrapper supplies no member pool and returns checked pressure
if a program requires one. The VM reserves its full member pool at initialization.

Both evaluators verify every definition, field, constructor range and operand,
including unused/malformed tails, before execution. Constructor fuel is one plus
the number of copied members; other nodes cost one. Legacy straight-line root
programs need at most 16,384 fuel units. General CLI/session/settings consumers
retain that allowance; runtime calls can exhaust it while reusing bounded bodies.
Extensions retain their manifest's explicit allowance, capped at 8,192 units.
Template expansion charges member remapping as well as node/alias visits.

Value JSON expands records as objects and arrays/tuples/options/maps as arrays using an explicit
stack. Admission checks the whole execution and the expanded report before any
output: default 65,536 work units and 1 MiB exact escaped output, including LF.
Alias graphs can exceed reporting budgets even when execution is valid; `eval`
returns a report-limit diagnostic while `check` does not expand values. Extension
responses retain the 256 KiB envelope profile. Inspection uses format 5 when an
option/map definition exists, format 4 when a
tuple definition exists, format 3 when an enum definition exists, or format 2 for
record/array catalogues, with type definitions, fields and one member pool;
scalar format 1 remains compatible. Inspection preflights a 4 MiB exact output budget.
These reports are diagnostics, not serialized executable/typed artifacts.
See [RFC-0015](rfcs/0015-immutable-aggregates.md).

The front end emits typed indexed IR in dependency order. The config CLIs lower
it to verified dense-register bytecode; the independent reference evaluator walks
root IR and executes callees through its own frames. Live Stanza and the shell use the verified VM. Lexer/parser/VM
use preallocated bounded storage, no recursion,
and no allocation after workspace initialization. Source, token, binding, node,
string, expression-stack, and evaluation-work limits are explicit. Exceeding a
limit is a diagnostic. IR and source borrow the workspace/input lifetime.

## What the compiler produces

The current pipeline is UTF-8 source -> tokens -> typed, indexed IR -> in-memory
dense-register bytecode -> checked register VM. Zig compiles the compiler and VM
themselves into native executables; guest Forbic has no native-code, LLVM or
WebAssembly backend. Bytecode is a borrowed Zig representation, not a serialized
artifact format or an untrusted binary loader.

For `Gaps:i64 = 3 * 2`, the IR contains an integer node for 3, an integer node for
2, and a multiply node referring to the first two indexes. Lowering emits two
integer instructions and a multiply instruction. Each produces one register;
the binding records the final register's index. References reuse an earlier
index. Eligible helper bodies have separate relative operands, captures and
argument/member pools. The VM borrows body node encoding and decodes each
operation after independent bytecode type admission. Computes branches use local
PCs and own-body catchers; computes/decides failure can cross runtime frames.
Transacts bodies use caller source state; defaults retain compilation templates. No constant folding
is performed.

Every VM run verifies the whole program, including the tail, before executing
any instruction: source/string UTF-8, spans, earlier operand indexes, operand
types, binding types and transaction structure. Arithmetic, tagged value access,
storage bounds and work budgets remain checked during execution. A prepared
bytecode benchmark excludes lowering, but still includes this full verification.
The independent IR evaluator remains a separate validation/execution oracle.
Float arithmetic uses distinct opcodes from checked integer arithmetic and adds
no allocations or native recursion.

A host that runs one program many times prepares it once (`forbic.prepared`,
RFC-0088 "A1 as implemented"): the handle owns a copy of the program and its
bytecode, the reference evaluator's `validate` admits the IR and the VM's `verify`
admits the bytecode, each on its own, and each run of the handle skips only that
machine's own admission. A run's meaning is unchanged: everything a run changes
(fuel, effects, grants, handles, inputs, cells, scheduler, pools, undo records,
results, and the string pool's tail) is in the run's storage and starts afresh, and
grants, inputs and store loads are checked by every run. A handle's runs give the
values, fuel, diagnostics, traces and reports of compile-and-run. Raw IR still goes
through the checked entry points, and a report still replays and validates by itself.

`forbic inspect FILE` reports this representation as versioned JSON without
executing guest arithmetic. Instructions include result registers, types and
source byte spans; bindings include names, visibility and result indexes. The
decoded UTF-8 string pool appears once, with string instructions referring to
its byte spans. Division by zero can therefore be inspected even though `eval`
and `check` diagnose it. See [RFC-0010](rfcs/0010-bytecode-inspection.md).

| Resource | Current bound |
| --- | --- |
| Source / decoded string storage | 64 KiB each |
| Tokens including EOF | 16,384 |
| Typed IR nodes / default evaluation work | 8,192 nodes / 16,384 work units |
| Bindings / identifier length | 256 / 128 bytes |
| Operator and operand stacks | 128 entries each |
| Function definitions / parameters | 64 / 16 per function |
| Function/default template nodes | 8,192 shared separate nodes |
| Published runtime body nodes | 8,192 separate nodes |
| Called-function depth / live frame registers | 32 / 8,192 Values, main excluded |
| Call argument references | 8,192 each for main/templates/runtime bodies |
| Controlled-call step evidence | 8,192 value/failure/propagation/root-failure events per run in ControlStorage |
| Compilation expansion work | 65,536 visits, including aliases/member remapping |
| User types / record fields | 256 types / 1,024 fields, 256 per record |
| Enum cases | 1,024 total, 256 per enum |
| Tuple element types / tuple arity | 1,024 total / 256 per tuple |
| Nested compound type annotations | 128 iterative frames |
| Member references / execution members | 8,192 per main/template/runtime-body/reference/VM pool |

These are fixed bootstrap limits, not configurable host profiles yet.

Runtime calls charge one instruction plus each visited body input/value and its
member/key/string work. Every frame push checks depth/register capacity. Returning
a Value is free; aggregate/string results borrow external run/program storage,
never frame registers. Repeated calls can allocate more physical members than
the static main operand pool, capped at 8,192 per run. Fatal errors clear frames
and abort source state without guest cleanup fuel.

Persistent oracle callers supply ReferenceStorage through evaluateWithRuntimeStorage.
Compatibility APIs reserve cold stack frame scratch; dense call-only results
carry no activity borrows. Computes branch callers additionally retain a bounded
step prefix in caller ControlStorage; APIs without it return control_storage_required
after admission. Unused controlled functions alone do not require it. Memory profile 11
exposes call-step storage/capacity alongside VM/reference frame scratch,
runtime body storage and argument capacities. Compiler template/runtime pools
coexist during the bridge, and ABI rows overlap; stack and RSS are excluded.
[RFC-0024](rfcs/0024-runtime-calls.md) records the complete initial contract.
Inspection format 10 exposes functions/captures/body nodes and argument/member pools.
Inspection format 11 additionally reports per-function control counts/transitive
flags. Independent reporting runs straight-line calls again and uses an explicit
frame/register replay for controlled invocations. It checks every
recorded function/PC/type, selected arm, parameter/capture/merge/return copy and
physical constructor/member copy after raw borrowed-Value/map admission,
including failed-body and unreturned maps.
Since RFC-0024's amendment "the replay works out every value", every value the program decides
(arithmetic, comparisons, conversions, built strings, lookups, natives that only compute, guards)
is worked out again and compared; only inputs the report carries (the effect seed, the tick
rate, the configuration) are taken from it. Step and report-work exhaustion are checked;
fatal execution clears steps and aborts source state without cleanup fuel.
[RFC-0025](rfcs/0025-frame-branches.md) specifies frame branches.

Computes bodies can catch Require/Fail inside their own Attempt regions with 32
per-frame catcher slots. Language failure pops the nearest own-body catcher,
changes its begin marker to false and selects fallback; fallback failures can
reach an outer own-body catcher. Declared computes/decides bodies can also
propagate uncaught language failure to a caller.
These helpers have no source writes, so their catchers do not begin/abort the
caller journal or restore its cells. Failed-body allocations remain in the run
member prefix. Every visited failed opcode consumes ordinary instruction fuel.

CallStep has value/failure/propagate/root_failure kinds. A failure copies the
exact false condition or borrowed string reason and produces no register. Each
failed parent call copies that defining cause; a failed root invocation ends with
a root_failure event. Successful root calls have no delimiter. One independent
root/callee replay reconstructs catchers, continuations, copies and source
rollback, consuming origins in global chronology. The first 32 traces include owning root instruction and optional
defining function/local PC; root traces have null function and local PC0. Root
activity can stay dense while called frames fail. Counts remain fully checked
after prefix truncation. Trace format2 is selected whenever an admitted call step
failed, including beyond the stored trace prefix; actual root-only failures keep
format1. Inspection12 exposes transitive has_failure and control metadata.

[RFC-0026](rfcs/0026-frame-failure.md) specifies internally caught failure.
Every decides call requires an own Attempt body or declared decides caller,
including an unused/untaken call whose body cannot fail. Root calls require a
root Attempt. Fallback is outside its own catcher and can reach an outer region
or escape a decides body. IR lexical and VM availability checks enforce these
contexts independently. Iterative unwind selects the nearest caller catcher;
only the defining opcode records a failure, so propagation keeps its reason and
scope without increasing failure_count. Returning/unwinding/copying evidence costs
no extra guest fuel. Each visited call still consumes one instruction.

```forbic
Leaf(N:i64)<computes><decides>:i64=If(Require[N>=0],N+1,N)
Chain(N:i64)<computes><decides>:i64=Leaf[N]+10
Recovered:i64=Attempt(Chain[-1],7)
```

Reports admit all readable root/event/physical Values before map hashing and
then replay one bounded root/callee schedule, including failed inactive calls,
exact propagation/root termination, physical member copies and source rollback.
Straight-line hidden constructors also validate their descriptors/maps. Report
work charges checked descriptors/members, raw events, root/callee visits, copied
constructor members and expanded output visits. Exact work/output quotas are
checked before any writer output. The previous duplicate trace traversal and
32 KiB root-call-end scratch are removed; bounded replay frames/Values remain
cold stack scratch, excluded from persistent ABI rows and RSS. Arithmetic output
remains typed opaque evidence. Inspection13 adds declared decides metadata;
earlier inspection formats remain for other programs. Trace format2 fields remain
compatible; existing decides helper failures now use their runtime defining scope.
Memory profile11 adds CallFailure/Result ABI rows and versions report ownership
without changing guest capacities. Rows overlap and are not summed. Fatal run
errors clear event/trace counts and abort source state without cleanup fuel;
invalid admission preserves prior storage.
[RFC-0027](rfcs/0027-failable-frames.md) specifies cross-frame pure failure.

The current source dialect has typed per-run mutation, lazy failure regions and
immutable module bundles under their accepted contracts. It has no native calls,
loops, async, guest file writes or transaction hooks; those features require
separate semantics and tests before acceptance. The CLI's file I/O is outside the pure evaluator.
Internal VM transaction instructions and the journal are specified in
[RFC-0005](rfcs/0005-bounded-transaction-runtime.md); they do not extend this grammar.

The [completion track](completion.md) lists remaining language milestones and
the acceptance process for each iteration.


## Transactional runtime frames

```forbic
var Cell:i64=1
First(A:i64,B:i64)<computes>:i64=A
Leaf(N:i64)<transacts><decides>:i64=First(Set(Cell,Cell+N),If(Require[N>=0],Cell,Cell))
Own(N:i64)<transacts>:i64=Attempt(Leaf[N],Set(Cell,Cell+7))
Recovered:i64=Own(-2)
Observed:i64=Cell
```

Both values are8: Leaf's write aborts before fallback adds7 to the original1.
Calls share caller state without implicit regions. Source-capable own Attempt
bodies share the existing33-region capacity with root Attempts and the outer run;
pure own catchers preserve caller writes. Initialization and every visited write
consume the8192 undo budget until root commit; abort restores its checkpoint.
Immutable aggregates remain snapshots in external member storage. Fatal errors
abort all source state and clear evidence; admission errors preserve prior storage.

Every declared transacts call requires a transacts caller, including unused and
untaken calls with no actual writes. Both independent verifiers admit defining
module spans, cell privacy, root initialization availability, types and relative
write operands. Body cell initialization is rejected. Transitive source bodies
retain bounded call events even without branches. Root/callee report replay
shares copied current cells and full source images, checking reads, writes,
rollback, commit and global capacities before output. Inspection14 exposes source
effects/counts/flags even for unused declared transacts helpers. Memory profile12
separates cold replay bytes from persistent ABI rows; rows overlap and are not
summed. Guest fuel/capacities and SDK/value/config schemas are unchanged. Native
actions remain outside source rollback. [RFC-0028](rfcs/0028-transactional-frames.md)
defines this increment; counted iteration follows RFC-0031 and direct self-recursion
follows RFC-0032.


## Lexical immutable blocks

```forbic
var Cell:i64=1
Adjust(N:i64)<transacts>:i64=Block{
 Snapshot:i64=Cell
 Result:i64=Attempt(Block{Changed:i64=Set(Cell,Cell+N);If(Require[N>=0],Changed,Changed)},Snapshot)
 Snapshot+Result
}
Value:i64=Adjust(-2)
```

Value is2 and Cell remains1. `Block{...}` is an expression containing typed
immutable local declarations and strict expressions, separated by newlines or
semicolons. The final expression supplies the result; trailing separators are
allowed. Empty blocks or a final declaration without a result are errors. Unused
initializers and discarded expressions still execute. A discarded expression
whose outermost operator is a comparison, a chain, `not`, `and` or `or` is
`discarded_comparison`, also in parentheses: write `Require[...]` to make it a
check, or bind or use the value (RFC-0076). The same holds for a statement of a
loop body, the last statement of a `Defer{...}` and of a class `Block{...}`
clause; a call or `If` used as a statement is not affected. Blocks add no opcode,
guest fuel or region; lazy If/Attempt arms and failure contexts retain their
existing behavior. Local functions/types/imports/public/var/set declarations are
unsupported; expression Set still writes admitted global cells.

There is no shadowing (RFC-0076): a local may not take a name that is visible
where it is declared (`shadowed_name`, at the new name). Visible are the locals
of the blocks around it, the parameters and the name of its function, the
binding or local whose initializer it stands in, every declaration made earlier
in the text by the scopes around the code (values, cells, functions, types,
aliases, templates, natives, nested modules, import aliases) and the public
names of every module in `using`; in a generic function or parametric type also its
type parameters, which are checked themselves where they are written. The body of a
template is checked where the template is declared, from its tokens, as compiling it would
check it, so an uncalled generic function or an uninstantiated parametric type is not
exempt: a local against the locals and `Fn` parameters around it, a method's parameters and
locals, field defaults and `Block{...}` clauses (`fix2`; the copy of a `Defer` body is left to
compilation). A `using` may
not bring in a name that a scope around it has declared already. The diagnostic
names the earlier declaration too when it is in the same file ("first declared at
line:column"). Names declared later, names of sibling scopes,
fields and methods, named arguments and enum cases are free. Same-scope
duplicates are errors. A name becomes visible after its initializer;
self-reference in it is unknown_name. Annotations keep
the type namespace. Closing a block removes its names; they cannot escape through
sibling arms/fallbacks or later declarations. A cell read is an immutable snapshot
in a local even if a later statement changes that cell. Aggregate aliases borrow
only admitted immutable run/member storage, with definition-site default captures.

The parser remains iterative. At most256 live local bindings span active block
scopes, independently of256 root bindings; closed scopes reuse the catalogue.
The existing128 expression stack, nodes/templates/members/evidence/fuel limits
remain checked. `local_binding_limit` diagnoses live-name pressure. Compiler reset
clears prefixes on reuse. Local names lower to existing earlier operands; every
strict statement remains in the runtime/report schedule, even when the final
result aliases an earlier register. Both independent verifiers retain arm
availability/type checks; report replay validates copies/effects before output.
Inspection shows the lowered schedule and retains its existing formats. Memory
profile13 adds compiler-local capacity/reservation metadata; cold source replay
scratch and runtime capacities stay unchanged. ABI rows overlap and exclude
allocator backing/RSS. [RFC-0029](rfcs/0029-local-blocks.md) records this
increment. RFC-0030 extends it with mutable local versions and rollback.

## Mutable lexical locals

```forbic
F(N:i64)<transacts>:i64=Block{
 var X:i64=N
 Held:i64=X
 Attempt(Block{set X=X+1;Fail["undo"];X},Set(X,X+7))
 Held+X
}
Value:i64=F(3)
```

Value is13: the failed write is restored before fallback assigns10; Held remains3.
Set/set writes require `<writes>` (RFC-0078; before it, `<transacts>`), including unused
computations; declaring a local `var` needs `<writes>` (`local_var_requires_writes`) and
reading one needs no effect; defaults remain computes. Set returns its assigned Value, while a
set statement requires a later block result. Types are exact. A local may not
take the name of a visible global cell or of an outer local (`shadowed_name`,
RFC-0076); immutable locals/parameters reject writes. Initializers
publish names after evaluation and all sequences remain strict. Copies add one
operation/fuel unit; reads/immutable snapshots reuse earlier operands.

If condition writes precede the versions saved for its two arms. Only the selected
arm's writes survive. Attempt saves before its body, restores before fallback on
language failure, and retains success/fallback writes. Nested successful regions
remain undoable by outer failure. Local state is isolated to its lexical invocation;
global cells retain shared source rollback. Fatal errors abort the run without
cleanup fuel. Returned Values borrow immutable program/run/member storage.

The iterative compiler lowers local versions into typed local_set copy operations
and ordinary lazy merges. At most32 live compiler checkpoints save up to256 live
locals. State tuples group at most128 locals each and use one outer result/state
tuple, supporting all256 without a hidden257-field tuple. Constructors/projections
use existing type/node/member/fuel/report budgets. No local journal or allocation
is added at runtime. RuntimeFunction has_local is independently recomputed even
for unused bodies/callees; it requires transacts and retains bounded call steps.
Reports independently check assignment and state projection copies before output.
Inspection15 exposes the lowered representation; value/SDK/config/trace schemas
stay unchanged. Memory profile14 publishes checkpoints and overlapping compiler
reservation. Cold source replay scratch remains278680 bytes on x86_64, separate
from other cold frames, allocator backing and RSS. [RFC-0030](rfcs/0030-mutable-locals.md)
records this increment. General loops, escaping mutable captures and suspension require
later control/owned-storage contracts; external actions remain outside rollback.

## Counted typed state iteration

```forbic
Step(X:i64)<computes>:i64=X+2
Value:i64=Iterate(Step,5,3)
```

Value is13. The original static Step is an earlier named or qualified public helper with exactly one
parameter and the same exact result type. It receives the previous immutable
state and returns the next snapshot. Count must be i64. Count and Initial evaluate
strictly in order; Initial inherits the helper's type for empty constructors.
Zero returns Initial without dispatch; a negative count fails fatally after both
operands evaluate. Declared effects are admitted for zero counts and unused bodies:
transacts needs transacts permission, and decides needs Attempt/decides context.

Each dispatch, including a restart, consumes one guest fuel unit. The Iterate
operation and helper inputs/operations retain their ordinary costs. Large counts
are bounded by existing fuel,8192 events/members/registers and32 guest frames,
without a separate count limit. Nested iteration consumes normal call depth;
repeated successful visits reuse one Step frame/register range. Both machines are
iterative. Ordinary alias calls retain templates while iteration publishes a
separate reusable alias body. Dynamic constructor work uses the existing saturated
bound. Returned Values never borrow reused frame slots; aggregate members remain
append-only for a run that stores its call witness, preserving previous states and
caller snapshots. A run that does not store it reclaims the members a finished visit
or call can no longer reach: see [Member reclamation](#member-reclamation).

Iteration creates no source region. Global writes from all visits share the caller
journal; nearest own/root Attempt undoes earlier successful writes when a later
visit fails. Helper own catchers finish before its returned state starts the next
visit. Fatal errors abort all owned state without cleanup fuel. Local variables
escape only as immutable result Values. A control-bearing iterate opcode carries
a target and two earlier operands; both admission passes recompute unused metadata,
effects, earlier-ID dependency order and structured operand/failure context.

Every visit retains bounded existing value/failure/propagation evidence. Independent
report replay checks the count, repeated seed/result copies, visit order, physical
constructors and failure continuations, with separate dispatch work charges.
Raw descriptors/maps are admitted before replay/output; arithmetic remains typed
opaque evidence. Inspection16 includes root and unused-body iteration, while
SDK/value/configuration/trace formats stay unchanged. Memory profile15 publishes
changed persistent frame arrays and cold replay frame/value array reservations;
these overlap storage rows and are separate from allocator backing/RSS. Source
replay scratch remains unchanged. [RFC-0031](rfcs/0031-counted-iteration.md)
defines this increment. General loops, mutual recursion (since RFC-0091, below),
captures, generics and the remaining runtime/product guarantees stay on the
completion track. External actions remain outside VM rollback.


## Bounded direct self-recursion

```forbic
Sum(N:i64)<computes>:i64=If(N==0,0,N+Sum(N-1))
Value<public>:i64=Sum(7)
```

An unqualified own function name in its body uses the declared exact parameter
and return types. Arguments evaluate strictly in order. A local or parameter may
not take that name (`shadowed_name`, RFC-0076); qualified public calls obey
ordinary module privacy. Transacts and
decides retain declared effect/context admission even in unused bodies. Decides
self calls use brackets. Record defaults can call earlier recursive helpers at
their definition site; a function parameter may have a default, which may read the
parameters before it and, in a method, `Self` (RFC-0071, RFC-0076).

The body-only self continuation carries arguments and an implicit current target.
Ordinary named calls retain earlier-ID dependencies; a call of a function declared further
down is the one exception (RFC-0091, "Functions completion" below).
Both independent machines push existing guest frames iteratively; VM arguments
remain indirect and reference parameters are copied. Each self operation costs
one fuel unit without an extra dispatch charge. Inputs/operations and constructors
retain ordinary costs. Existing32 frames and8192 live registers/events/members
bound execution. Result Values borrow immutable run/program storage, never frame
slots. A recursive child inside Iterate returns before the Step's next visit.

No implicit source region is created. Nearest own/root Attempt restores recursive
writes on language failure and restores mutable local versions. One defining
origin propagates through self continuations. Arithmetic/resource failures remain
fatal; cleanup consumes no fuel and permits healthy reuse. Complete evidence and
independent replay check parameter/return copies, physical members and causes
before output. Admission checks all unused signatures, effects, argument chronology
and arm visibility. Any possible constructor work saturates member_work for a self
body; a body with none retains zero. Inspection17 includes unused self continuations;
profile15, native reservations and value/trace/SDK/config formats remain unchanged.
[RFC-0032](rfcs/0032-bounded-self-recursion.md) defines this increment. General
loops, captures/generics and L6-L10 remain active; mutual recursion is RFC-0091. Typed
callables follow RFC-0033 below.


## Typed function values and indirect invocation

```forbic
Inc(X:i64)<computes>:i64=X+1
Apply(F:function(tuple(i64),i64),X:i64)<computes>:i64=F(X)
F:function(tuple(i64),i64)=Inc
Answer<public>:i64=Apply(F,41)
```

Function schemas are structural ordered parameter tuples and results, with
effects. The effect specifiers go before the type parentheses
(`function<reads><decides>(tuple(i64),i64)`). The current
profile accepts16 parameters. Nominal privacy propagates through signatures;
function values cannot be compared or used as map keys. A function with fewer effects
is a value of a function type with more (RFC-0078); parameter and result types are exact.

A bare earlier named/qualified public function is a typed immutable code
reference. An unqualified body's own name may produce a self reference. Locals
and parameters may not take the name of a visible function (`shadowed_name`,
RFC-0076). References can be passed/returned, stored
in every aggregate, or stored in mutable source/local bindings. Taking a reference
has no effects; invoking it checks all declared effects even in an unused body.
The callee evaluates before strict left-to-right arguments. Record defaults retain
definition-site references and calls. Parameter defaults are filled by the caller in
parameter order and may read the parameters before them (RFC-0076).
Ordinary alias calls retain templates; Iterate and references share one explicitly
published reusable alias target.

Each reference contains signature Type and runtime function ID. It borrows checked
program metadata, with no native pointer, frame borrow, capture environment, heap
allocation or native guest recursion. A dynamic operation stores an earlier callee
operand and checked argument range. Named dependencies use earlier IDs, or a later
function available where the caller is (RFC-0091);
passed references can form dynamic cycles and remain bounded by32 frames,
8192 live registers,8192 call events,8192 physical members and instruction fuel.
Invocations cost one operation unit; no extra dispatch unit is introduced.

The reference machine snapshots parameters and advances its caller before entry;
the VM retains indirect argument indexes and the caller PC. Both independently
admit unused signature/target/type/privacy/effect/context/chronology metadata and
arm visibility. Every indirect call traces pure children too. Unknown callee work
saturates possible constructor work at8193 and conservatively permits caught
failures; a transacts signature admits source/local work. A transacts callable can
therefore require source-region storage even without declared cells. These flags
are recomputed independently from signatures. Dynamic calls share caller cells
and create no rollback region. Own/root Attempt restores source/local versions;
fatal cleanup consumes no fuel and supports reuse.

Reporting admits every raw callable descriptor before maps and schedule replay,
then resolves targets from checked copied Values and verifies literal/self IDs,
arguments, returns, constructors, causes and continuations. References serialize
as `{"function":{"name":"Inc","module":null}}`, using their defining virtual
path when bundled. This descriptive output grants no native authority. Inspection18
includes callable schemas/operations and unused annotations; older programs retain
their prior formats. [RFC-0033](rfcs/0033-typed-function-values.md) specifies
this increment. Generic/effect polymorphism,
general loops and L6-L10 remain on the completion track.

The worker wire consumer checks callable name/module descriptors as scalar leaves.
Only a complete reference may contain a null defining module; ordinary payload
null remains invalid. Callable metadata does not consume guest record field slots,
and existing wire depth, active-field and frame bounds remain checked. Empty source
regions participate in combined root/callee rollback nesting and replay too.


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
See [RFC-0034](rfcs/0034-callable-iteration.md) and `desktop/config/callable-iteration-baseline.forb`.
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
See [RFC-0035](rfcs/0035-state-loops.md) and `desktop/config/state-loops-baseline.forb`.
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
See [RFC-0036](rfcs/0036-bound-function-captures.md) and `desktop/config/bound-functions-baseline.forb`.
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
most 16 total. Neither may take a name visible where the `Fn` is written, which
includes the locals and parameters of the functions around it (`shadowed_name`,
RFC-0076); the one exception is a capture of that very name (`[X:t = X]`). The
body is one expression; `Block` supplies local declarations
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
See [RFC-0037](rfcs/0037-anonymous-functions.md) and `desktop/config/anonymous-functions-baseline.forb`.
Generic/effect polymorphism and L6-L10 remain active.

## Explicit generic functions

A named function may declare explicit type parameters and a brace-delimited body:

```forbic
Identity[T:type](X:T)<computes>:T{X}
Number<public>:i64=Identity[i64](41)
Chosen:function(tuple(i64),i64)=Identity[i64]
```

Type arguments are written at every reference, or read off the arguments of a call
(`Identity(41)`, RFC-0091, below); there is no coercion or overload. A specialization is an ordinary exact function value, so it works
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
See [RFC-0038](rfcs/0038-explicit-generics.md). Effect polymorphism, generic types and L6-L10 remain active.

## Explicit effect parameters

A generic parameter may be `E:effect`, written at references as `computes`,
`transacts`, or either with `<decides>`, and used as `<E>` in headers and
`function<E>(...)` types:

```forbic
Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{F(F(X))}
Moved:i64=Apply[transacts,i64](Bump,2)
```

Each specialization is checked as an ordinary concrete function, so effects and
call syntax stay exact; a type argument is inferred only by matching the argument types
exactly (RFC-0091, B3), and there is no subtyping. `<E>` already carries
the decides bit. Specialization keys carry the effect as a canonical witness
function type, so reports and admission reuse the RFC-0038 shapes. See
[RFC-0039](rfcs/0039-effect-polymorphism.md) and `tests/conformance/effect-polymorphism.forb`.

## Array element reads

`Items[I]` reads an element of an array and fails when `I` is outside
`0..Length-1`. It is a failable bracket operation, so it needs an `Attempt` body
or a `<decides>` function:

```forbic
Pick(I:i64)<computes>:i64=Attempt(Items[I],-1)
Cell:i64=Attempt(Rows[R][C],0)
```

The bound is checked by an ordinary `demand`, so rollback and failure traces
match `Require`. See [RFC-0040](rfcs/0040-array-index.md) and `tests/conformance/array-index.forb`.
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
[RFC-0041](rfcs/0041-numeric-conversions.md) and `tests/conformance/numeric-conversions.forb`.

## Euclidean division and rationals

`Quotient[A, B]` and `Mod[A, B]` divide two `i64` values the Euclidean way: the remainder
is in `[0, |B|)` and `Quotient * B + Mod == A`, so `Quotient[-7,2]` is -4, `Mod[-7,2]` is 1,
`Quotient[7,-2]` is -3 and `Mod[7,-2]` is 1. Both fail, like `Require`, when `B` is zero, so
they need an `Attempt` body or a `<decides>` function. The one pair whose quotient does not
fit, the least `i64` over -1, is the fatal `arithmetic_overflow` for both. `A / B` is
unchanged: truncating, and fatal on a zero divisor.

`rational` is an exact fraction of two checked `i64` terms, always held in lowest terms with
a positive denominator. `Rational[A, B]` builds one and fails when `B` is zero;
`MakeRationalFromInt(N)` is total. `Floor(R)` and `Ceil(R)` (parentheses: they cannot fail)
round to `i64`. A rational is comparable: `==`, `!=`, a map key, and a part of structural
equality. As extensions beyond the Book, `+`, `-`, `*` and unary `-` are exact and stop the
run with `arithmetic_overflow` only when the reduced answer does not fit; `<`, `<=`, `>`,
`>=` order exactly; and `ToFloat(R)` is the correctly rounded `float`. There is no implicit
conversion between `i64` and `rational` and no `/` between rationals. The five names are
not reserved: a program's own declaration of one of them wins. A value is a two-word scalar
(no members); reports print it as `{"$rational":[numerator,denominator]}` and inspection
lists the type as `{"kind":"rational"}`. Each operation costs one unit of fuel. See
[RFC-0070](rfcs/0070-quotient-mod-and-rational.md) and `tests/conformance/rational.forb`.

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
`string`, arrays of scalars) and return a scalar, an option or an array. A generic native
([RFC-0077](rfcs/0077-standard-library.md)) also names one type variable `T`, as `T`,
`[]T`, `[][]T` or the values of a `map(K, T)`: it moves values of `T` without looking inside
them, compares them as `==` does when it is registered as comparable, and each machine's
admission binds `T` and `K` from the operand types. Such a native is reached through the
standard forms, not bound by name. Natives
work anywhere, including function bodies, loops and rollback. Each call is charged its declared cost before it runs, bounded by the
guest member pool, admitted independently by both machines and re-checked on return.
A fatal native error is a diagnostic that `Attempt` cannot catch. The standard table
(`std.sum`, `std.sorted`, `std.range`, `std.find`, `std.dot`, `std.sqrt` and more)
is available by default; hosts supply their own through `workspace.natives`. See
[RFC-0042](rfcs/0042-native-zig-functions.md) and `tests/conformance/native-std.forb`.

## Strings built at run time

`A + B` concatenates, `S.Length` is the byte length, and `ToString(X)` renders an
`i64`, `float`, `logic`, `char` or `char32` and hands a `string` back as it is (a type with a
`ToString` declared by the program goes through it, see "String interpolation").
Run-built strings append to the unused tail of the
program's string pool (bounded by the 64 KiB string budget; overflow is
`string_limit`) so every string stays a reference into one validated pool. The
standard natives add `std.substring`, `std.index_of`, `std.contains`,
`std.starts_with`, `std.ends_with`, `std.upper`, `std.lower`, `std.trim`,
`std.repeat`, `std.join`, `std.split` and `std.parse_int`. See [RFC-0043](rfcs/0043-run-owned-strings.md) and
`tests/conformance/strings.forb`.

## Compound assignment

`set X += e` (also `-=`, `*=`, `/=`) means `set X = X op (e)` for cells and block
locals, including floats and `+=` on strings; `X` is read before `e` runs. See
[RFC-0044](rfcs/0044-compound-assignment.md) and `tests/conformance/compound-set.forb`.

## Type aliases

`Name := type` names any spellable type; the alias is transparent (the same
structural type), declared before use and private to its module unless it is
`Name<public> := type` ([RFC-0074](rfcs/0074-nested-modules-and-access.md)):

```forbic
Grid:=[][]i64
Total(G:Grid)<computes>:i64=Attempt(G[1][0],-1)
```

See [RFC-0045](rfcs/0045-type-aliases.md) and `tests/conformance/type-aliases.forb`.

## Array concatenation

`A + B` joins two arrays of the same type into a fresh immutable array (one unit of
work per produced element; overflow of the member pool is `aggregate_limit`):

```forbic
Append(Items:[]i64,N:i64)<computes>:[]i64=Items+array{N}
```

See [RFC-0046](rfcs/0046-array-concatenation.md) and `tests/conformance/array-concat.forb`.

## Type inference

`Name := expression` binds an immutable value with the expression's type, at the
top level and in `Block` locals (`var` bindings still declare their type; contextual
empties need a declared type). See [RFC-0047](rfcs/0047-type-inference.md) and
`tests/conformance/type-inference.forb`.

## Failable conditions

A failure inside an `If` condition (an index, a `<decides>` call or a conversion,
all written with brackets) selects the else branch, as if written
`If(Attempt(condition, false), ...)`; writes made by the failed condition are rolled
back. A condition with an explicit `Require`/`Fail` still fails the enclosing region.
A condition whose only failable part has no bracket, a lone unwrap as in
`If(Opt?.X > 0, A, B)`, is a failable condition too, wherever it stands: the condition of an
`If` is its own failure context also inside one that already exists (an `Attempt` body, a
`<decides>` function), so an empty `Opt` selects the else branch and no longer fails that
context (RFC-0076, which supersedes the owner decision in RFC-0049). A program that relied on
the failure escaping writes the unwrap outside: `Block{ V := O?; If(V > 3, 1, 0) }`.
See [RFC-0049](rfcs/0049-failable-conditions.md) and `tests/conformance/failable-conditions.forb`.

## Case

`Case(Scrutinee, Pattern=>Value, ..., _=>Default)` picks the first arm whose pattern
equals the scrutinee (a name or field path); arms are lazy and a final `_` default
is required. See [RFC-0050](rfcs/0050-case.md) and `tests/conformance/case.forb`.
`Case[...]` is the form that fails instead of needing a default
([RFC-0080](rfcs/0080-remaining-types.md)).

## Control-flow completion (RFC-0090)

```forbic
Bump(N:i64)<transacts>:void = If(N > 0, Set(Count, Count + N))   # If without an else
Once:[]i64 = For(X := Some?, X * 10)                              # no generator: one element or none
Fed:[]i64  = For(T := GetThing[], N:T..T+2, T*10+N)              # a binding before the generator
```

- **`If(Condition, Then)`** runs `Then` when the one condition holds (logic, failable or a
  binding) and is the unit value of type `void` either way; `Then`'s value is dropped as a
  statement's. Where its value is bound or converted to another type, it is `if_without_else`.
- **A `For` whose first clause is a binding or a filter** runs its clauses before the first
  generator once, in the code around the loop and in one region with everything after them: a
  failure undoes their writes and skips the rest, so the generator's source is not evaluated.
  Without a generator the body runs at most once. Such a `For` cannot be left by `Return` or
  `Break` (`for_clause_exit`).
- **`Case(...)`** refuses an arm written like an unguarded arm before it (`unreachable_arm`) and
  a type test subsumed by an earlier one (`subsumed_arm`), as `Case[...]` does; a redundant `_`
  after every case of an enum is accepted (the Book only warns). A constant arm needs a
  scrutinee of an integer, `logic`, `char`, `char32`, `string`, enum or `i64` refinement type
  (`case_scrutinee_type`); RFC-0066's patterns over other types are unchanged.

No IR is new. See [RFC-0090](rfcs/0090-control-flow-completion.md) and
`tests/conformance/control-flow.forb`.

## Field updates

`WithField(Record, Field, Value)` returns a copy with one field replaced, and
`set P.A.B = e` (also `+=`, `-=`, `*=`, `/=`) assigns the rebuilt record back to `P`:
structs have value semantics. See [RFC-0051](rfcs/0051-field-updates.md) and
`tests/conformance/field-updates.forb`.

## Array element updates

`WithIndex[Array, Index, Value]` returns a copy with one element replaced and fails
outside `0..Length`; `set A[I] = v`, `set Grid[1][0] = v`, `set P.Xs[I] += v` rebuild
the path (failable, so use them in a failure context). See
[RFC-0052](rfcs/0052-array-element-updates.md) and `tests/conformance/array-updates.forb`.

## String interpolation

Inside a string, `{expr}` splices the text of an `i64`, `float`, `logic`, `string`, `char`
or `char32` expression: `"Hello {Name}! n={Count+1}"`; `\{` and `\}` write literal braces. See
[RFC-0053](rfcs/0053-string-interpolation.md) and `tests/conformance/interpolation.forb`.

A program gives any other type its text by declaring `ToString(V:T)<effects>:string` (one value
of a type with no text of its own, a string result, not failable; else `to_string_signature`).
Interpolation, `ToString(V)`, `Module.ToString(V)` and `ToDiagnostic(V)` of such a value call the
overload chosen by the type, with the effects of any call; a type with none is `type_mismatch`.
The overload is found in the module and the modules around it, then through `using` (two used
modules whose `ToString` both take the type are `ambiguous_call`). Values with a text of their own keep it
and cannot be redefined; no IR changed. See RFC-0053 "B5 as implemented" and
`tests/conformance/text.forb`.

## Implicit captures

An `Fn` without `[...]` captures the enclosing locals and parameters its body names, by
value (a local `var` it names is shared and the `Fn` refers to the variable, see "Shared
locals"), and may omit `<effect>` and `:Type`: `Fn(X:i64){N+X}`. See
[RFC-0054](rfcs/0054-implicit-captures-and-inference.md) and `tests/conformance/closures.forb`.

## For iteration

`For(X:Items, Body)` maps an array, `For(I->X:Items, Body)` adds the index, and conditions
between head and body filter: `For(X:Items, X>3, X*2)`. See
[RFC-0056](rfcs/0056-for-iteration.md) and `tests/conformance/for-loops.forb`.
A string is a source too: `For(C:Text, ...)` visits its code units as `char` and
`For(I->C:Text, ...)` adds the byte position.

A `For` may have several generators, ranges, bindings and a body that fails:
`For(X:Xs, Y:1..X, Z:=Lookup[Y], X+Z)` nests in order, binds `Z` where the lookup succeeds and
skips (undoing its writes) every iteration in which something fails. See
[RFC-0064](rfcs/0064-for-generators-ranges-and-bindings.md) and
`tests/conformance/for-generators.forb`.

A `For` may assign the `var` locals of the code around it, in every form:
`Block{ var T:i64 = 0; For(X:Xs, Block{ set T = T + X; T }); T }`. The loop carries them from
one iteration to the next as `While` does, and an iteration that fails puts back what it
assigned. A loop that assigns none is lowered as before. See the amendment of RFC-0064 and
`tests/conformance/for-locals.forb`.

A failure in generated loop code is traced to the user's expression where there is one (a
failing filter or condition, a `Not[...]` that holds) and otherwise to its own loop, and a
diagnostic about generated code names the call it was generated for (RFC-0056, "Blame").
A module's library block holds the templates of the forms it uses and no others (RFC-0056,
"What a block holds").

## Maps and options

`M[K]` looks a key up (failable), `Opt?` unwraps an option (failable), and
`set M[K] = V` inserts or replaces. See [RFC-0057](rfcs/0057-map-updates-and-option-unwrap.md) and
`tests/conformance/map-updates.forb`.

## First, logic{...}, option{...} as a failure context, optional chaining

`First[X:Items, X>3, X*2]` takes the clauses of a `For` (generators, keyed generators, ranges,
bindings, filters) and yields the body of the first iteration in which everything succeeds; it
fails when there is none, so it needs a failure context. Iterations are tried in order, nothing
after the first success is evaluated, and every iteration that fails (also a failing body, and
an outer iteration whose inner generators find nothing) has its writes undone, so exactly the
writes of the iteration that is yielded remain. `First[Items]` with no generator at the head is
still a call of a program's own function `First`, and `First[T:type](...)` still the header of
a generic one. Only a module that uses the form carries its templates: the library block of
every other module is what it was.

`logic{E}` is `true` when `E` succeeds and `false` when it fails, with the writes of a failed `E`
undone; it is `Attempt(Block{E; true}, false)` and a failure context everywhere, including
`<decides>` functions. `E` must be able to fail (`failure_expected` otherwise; a comparison is
a `logic` value here and cannot).

`option{E}` with an `E` that can fail yields the empty option when it does (writes undone),
wherever it stands (RFC-0076): outside every failure context, inside a `logic{...}`, a
`First[...]` or another such `option{...}`, and also inside an `Attempt` body, a condition, an
iteration of a `For` and a `<decides>` function, where the failure left the constructor before.
The surrounding context does not fail, and the nearest catcher wins: an `option{}` inside an
`Attempt` catches before the `Attempt`. A program that relied on the failure escaping writes
the failable part outside: `Block{ V := Prices[K]; option{V} }`. An `option{V}` in which
nothing can fail compiles to what it always did. A constructor whose expression can fail is
found by a first compile and given its region (`Attempt(option{E}, option{})`) by the next.

`Opt?.Field`, `Opt?.Method(Args)`, `Opt?(I)` and `Opt?[I]` are the unwrap of RFC-0057 followed
by the access: they fail when `Opt` is empty, the method does not run then, and chains
(`Head?.Next?.Value`) fail at the first empty link.

None of these adds an IR operation. See
[RFC-0072](rfcs/0072-failure-forms-and-bit-operations.md), `src/forbic/failure_form_tests.zig`
and `tests/conformance/failure-forms.forb`.

## Bitwise intrinsics

`BitAnd(A, B)`, `BitOr(A, B)`, `BitXor(A, B)` and `BitNot(A)` combine the two's-complement bits
of `i64` values. They are the Book's whole list (no shifts). They are total and cannot overflow,
are pure, and cost one unit each as an addition does; `BitNot(A)` is `BitXor(A, -1)`. The names
are not reserved: a program's own function of the same name is used instead, and inside a class
that has a member of the name the bare name is not the intrinsic (use `Self.`). In the IR they are
three more operators of the integer `binary` node (`bit_and`, `bit_or`, `bit_xor`); both
admissions reject them on `float_binary`. See
[RFC-0072](rfcs/0072-failure-forms-and-bit-operations.md).

## Comparable types, composite keys and key removal

A type is comparable when its values have an equality: scalars, enums, instances of a
`class<unique>` (the same instance), and records, tuples, options, arrays and maps whose parts
are comparable. A function is not, nor anything that holds one. Nor is a class without
`<unique>` (`not_unique`), anything that holds one, or a value of interface type (cast it to
its unique class first). A class below a unique class says `<unique>` itself; a unique class may
have a superclass that is not unique; an interface cannot be unique (`unsupported_specifier`).
See RFC-0076. `==` and `!=` accept two values of one comparable
type and compare structural values part by part, in order; a map key may be of any comparable
type; and `F[T:comparable]` restricts a type parameter to them. `Without[M, K]` is a copy of
`M` without the entry under `K`, the others in their order; it fails when `K` is absent, so
`Attempt(Without[M, K], M)` never fails. See
[RFC-0065](rfcs/0065-comparable-keys-and-removal.md) and `tests/conformance/comparable-keys.forb`.

## Characters and strings as code units

`char` is one UTF-8 code unit (`0..255`) and `char32` one Unicode scalar value (`0..0x10FFFF`
without the surrogates). `'a'`, `'\n'` and `0o61` are `char`; `'é'`, `'😀'` and `0u1F600` are
`char32`. Neither converts to the other or to an integer implicitly, both compare with `==`
and `!=` only (there is no ordering of characters or strings), and both are comparable: map
keys, parts of keys and constant patterns of a `Case`. Neither name is reserved. A module
means one thing by each: a type it declares under the name before using it, or else the
builtin, after which declaring the name in that module is `duplicate_name`.

A `string` is still valid UTF-8 text in one pool, and can be read as its code units. All
positions are byte positions, and the failable forms fail like `Items[I]`:

| Form | Result | Fails when |
| --- | --- | --- |
| `S[I]` | `char` | `I` is outside the string |
| `S.Slice[A, B]`, `S.Slice[A]` | `string` | not `0 <= A <= B <= Length`, or the slice is not empty and an end splits an encoded scalar |
| `S.ScalarAt[I]` | `char32` | `I` is outside the string or no scalar starts there |
| `string[Units]` | `string` | the `[]char` is not valid UTF-8 |
| `N.ToChar[]`, `N.ToChar32[]` | `char`, `char32` | `N` is no value of the type |
| `C.ToAsciiChar32[]` | `char32` | the `char` is above ASCII |
| `C.ToCodeUnit()`, `R.ToCodePoint()` | `i64` | never |
| `R.ToAsciiString()`, `ToString(R)` | `string` | never: the UTF-8 encoding |
| `ToString(C)` | `string` | never: the byte when ASCII, U+FFFD otherwise |

So a string value never holds bytes that are not text: where the Book's `[]char` operation
would make some, the operation fails, and the one total conversion substitutes U+FFFD. A slice
is a view of its string and adds no bytes to the pool; `string[Units]` copies once.
`For(C:S, C)` is the `[]char` of a string; `For(I->C:S, R:=S.ScalarAt[I], ...)` visits its
scalar values. A string and a `[]char` are different types and do not compare.

A character is represented as the nominal immediate that carries an enum case: its type and
its code. No value kind was added; a constant is the node `character`, and the operations are
the node `text` (`unit`, `boundary`, `slice`, `scalar`, `code`, `from_code`, `valid`, `join`),
each admitted and implemented by both machines and recomputed by the report replay. Every
operation costs one unit except `valid` (one per code unit) and `join` (one per code unit and
`1 + bytes / 8` for the string). A report prints a character as `{"$char":97}` or
`{"$char32":128512}`. Not offered yet: `set S[I] = C`, characters in native signatures. See
[RFC-0069](rfcs/0069-char-and-string-view.md) and `tests/conformance/chars.forb`.

## Default and named arguments

`F(A:i64, B:i64=10)` declares a default; calls may omit it or name it: `F(1, B:=5)`. A
default may read the parameters before it (`Area(W:i64, H:i64 = W, Depth:i64 = W + H)`); a call
fills the omitted parameters in parameter order and evaluates every argument once (RFC-0076). See
[RFC-0058](rfcs/0058-default-and-named-arguments.md) and `tests/conformance/named-arguments.forb`.

## Condition bindings and destructuring

`If(X := Items[I], X > 3, Then, Else)` binds names across failable conditions, and
`(A, B) := Pair` destructures a tuple. One binding condition is enough:
`If(N := Next[I], N * 10, -1)`. See [RFC-0059](rfcs/0059-condition-bindings-and-destructuring.md) and
`tests/conformance/condition-bindings.forb`.

## While loops

`While(I < N, Block{ set Total = Total + I; set I = I + 1 })` loops over `var` locals; see
[RFC-0060](rfcs/0060-while-loops.md) and `tests/conformance/while-loops.forb`.
A single condition may bind (`While(N := Next[I], Body)`) or be a lone unwrap.

## Early exit

```forbic
Find(T:i64)<transacts>:i64 = Block{
    For(I->X:Items, If(X == T, Return(I), false))
    -1
}
Bits(X:i64)<transacts>:i64 = Block{
    var B:i64 = 1
    var C:i64 = 0
    Loop{ If(B > X, Break(), false); set B = 2 * B; set C = C + 1 }
    C
}
Copy(Name:string)<transacts><decides>:i64 = Block{ File := Open[Name]; Defer{ Close(File) }; Read[File] }
```

`Return(Value)` ends the function it is written in (the named function, method or `Fn`; the
bodies of `For`, `While` and `Loop{}` are not functions of their own) and keeps everything
written so far: the regions open in the function are committed, not rolled back. As in the Book
it is the last thing its scope does: a function's whole body, the last statement of a block, an
arm of `If`, `Attempt` or `Case`, or the body of a loop. `Loop{ Statements }` is the Book's
loop, told from the state loop `Loop(Step, Initial)` by its brace; it carries the `var` locals
it assigns, like `While`, and ends by `Break()`, which leaves the nearest `Loop{}` (never a
`For` or `While`) and takes no value, or by a `Return`. `Defer{ Statements }` runs its body when
the `Block` or loop visit it stands in ends, returns or breaks, the latest first, and not when
it fails; the body cannot fail, `Return` or `Break`, and it means what it meant where it was
written. `Err(Message)` ends the run with `runtime_error`; nothing catches it. None of these
yields a value, so each takes the type its place expects (`logic` where nothing is expected),
and an arm that is itself an exit takes the type of the other arm (a name bound to an exit
keeps the type it was given).

`Return` and `Err` are one IR operation each, `exit` and `err`. An `exit` commits the regions
its frame has open and ends the frame with its operand as the result; it never leaves more
than its own frame, and both machines admit it only in a function body with an operand of the
result type. Loops that can be left are state loops whose state starts with a mode; an exit in
the body is an `exit` of the visit's function with the mode set, and the code after the loop
exits again in its own frame. A `Defer` registers nothing at run time: its body is copied to
every place its scope is left, which is why a failure runs none of it and has no registration
to undo. A `For` that something leaves early is run for what it does and has the value `true`.
A `First[...]` cannot be left that way: a `Return` or `Break` out of its clauses or body is
`first_exit`. Inside `logic{...}` and a catching `option{...}` an exit commits the region and
leaves, as in an `Attempt`.
Inspection format 25 shows the two operations. See [RFC-0068](rfcs/0068-early-exit.md) and
`tests/conformance/early-exit.forb`.

## Overloading

Functions of one name may differ in parameter types: `Twice(X:i64)` and `Twice(X:float)`.
Overloads must be distinct (RFC-0076): two functions of one name in one scope, or two extension
methods of one name, with the same number of parameters are `related_overloads` at the second
definition when the two types overlap at every position. Types overlap when they are equal,
one is a subtype of the other, or one is an interface and the other an interface or a class
that is not `<final>`, and an option and `logic` overlap (`option_logic_overloads`: the Book's
`false` is both). `Speak(A:Animal)` beside `Speak(D:Dog)` is therefore refused; no
definition is preferred as the more specific one. A pair whose parameters name a class declared
further down is decided, and refused, where that class is declared, so the order of the
declarations does not matter. A call without a receiver chooses among functions only: a
method of the same name is not a candidate. Among distinct overloads the exact types
are tried first, then the one definition the arguments are assignable to. See
[RFC-0061](rfcs/0061-overloading.md) and `tests/conformance/overloads.forb`.

## Not and using

`Not[E]` succeeds when `E` fails; `using{L}` brings the public names of an imported module into
scope. `Not[A > B]` drops its comparison and is `discarded_comparison`: write
`Require[not (A > B)]`. A name that a `using` in effect exports is visible, so no declaration,
parameter or local may take it (`shadowed_name`); a name the used module keeps to itself is
free (RFC-0076). See [RFC-0062](rfcs/0062-not-and-using.md) and
`tests/conformance/not-combinator.forb`.

## Nested modules, access levels and exported aliases

```forbic
Geometry<public> := module{
  point<public> := struct{x:i64=0, y:i64=0}
  Seed<internal>:i64 = 10
  Flat<public> := module{
    Area<public>(P:point)<computes>:i64 = P.x*P.y + Seed
  }
}
using{Geometry.Flat}
Twelve:i64 = Area(Geometry.point{x:=1, y:=2})
```

In a bundle, `Name := module{ declarations }` declares a module inside a file or inside
another module, to a depth of 16; a body holds what a file holds except imports. A declaration
is in reach of its own module and of the modules nested in it; `<public>` puts it in reach
wherever its module can be named, and a module can be named inside the scope that declares it
and, if it is `<public>` itself, wherever that scope can be named. `Outer.Inner.Name` is a
path, `using{Outer.Inner}` brings the public names of a module into the scope that says it
and into the modules nested there, and an unqualified name is the one declaration of that name
in the scopes around the code: a declaration of a module may not repeat a name that a scope
around it declared earlier or that a `using` in effect exports (`shadowed_name`, RFC-0076);
sibling modules may use the same names. `<internal>` on a declaration of a file or module says
the default aloud. A field or method of a class or interface is `<internal>` by default too
(RFC-0076): usable in the scope that declares the type and the modules nested in it, and
`internal_member` elsewhere; `<public>` makes it usable wherever the type can be named, and
`<internal>` on a member means this, not `<public>`. A program compiled from one file is one
module, so nothing changes for it. Declarations stay sequential; classes are declared ahead as
in a file.

`Name<public> := type` exports an alias; `var<private> Count<public>:i64` in a class is read
by anyone and assigned by the class (the specifier on `var` is the write access and is never
the wider one; `internal` and `protected` are not ordered, so neither is the write access of
the other, RFC-0076). A public declaration may mention only types that are nameable wherever it is:
with modules inside files that also refuses a public binding whose type belongs to a module
that is not public (`private_type_escape`). An `<internal>` or `<private>` field of a public
class does not leave its module, so it may have a private type: the field is marked hidden
in the IR (`"hidden":true` in inspection), both admissions let it stay out of the class's
public signature, and no `public_only` report prints it or follows it. Since `fix2` every such
field of a public class is hidden, whatever its type, and so are those of the classes above a
public one (a subclass holds its parent's marks), in a single file too: a public report shows
nothing the public API cannot reach (see "Reports" below). A public class may therefore have
a private parent with an internal field of a private type.

Both machines admit the table of nested modules by finding the modules in the source text
again and requiring the table to be exactly those, and apply the reach rules to every call,
function value, captured binding and cell access. Reports keep `module` as the file; an enum
value of a nested module prints `file::Outer.Inner.type.case`, and inspection lists
`nested_modules` for a program that has any. Macros used in a nested module take their
templates from the file's library block, so generated names stay out of reach as before.
Constructor functions follow the same reach rules as any function, also where an archetype
delegates to one by path (`A.B.Make<constructor>(...)`); the field values a delegation takes
over and the calls of block clauses stay code of the module that wrote them, so they cross a
boundary their archetype could not. `<final>` and a write access stand together
(`var<private> X<public><final>:t = v`), and an extension method does not hide a bare name of
a scope further out, nor of a module in `using`: with `using{L}` and `(S:string).Double()`, a
bare `Double(4)` is `L`'s function (RFC-0076).
Module paths are implemented (RFC-0093, below). `<scoped>`, the qualifiers `(c:)`, `(i:)` and `(/path:)`, and `using`
of an instance are not implemented and have no recorded decision yet (book-feature-matrix.md, "State at the M1
close-out"). See [RFC-0074](rfcs/0074-nested-modules-and-access.md) and
`tests/conformance/nested-modules.bundle.json`.

## Class and interface members, extension methods

Methods take default and named arguments like functions (`Obj.Grow(Times := 2)`); the names and
defaults are those of the declaration the receiver's static type sees, the body is the
instance's. A method default may read the parameters before it and `Self`, and fields of `Self`
if the method declares `<reads>` (`field_read_requires_reads` otherwise, RFC-0078); `Self` is the
receiver (RFC-0076). Members are `<internal>` unless marked `<public>` (see
[Nested modules](#nested-modules-access-levels-and-exported-aliases)). An interface may give a method a body, which implementing classes inherit unless
they override it, and may declare fields (`var Health:i64 = 100`): every implementing class
holds the field in its own layout, and a value of the interface reads and assigns it through
getter and setter slots that the class implements, so nothing assumes where the field lives.
`Name<override>:T = value` restates the default of an inherited field. A method the superclass
already has stands in for an interface method of the same signature. `(V:i64).Double()<computes>:i64 = V * 2`
declares an extension method, an ordinary function called as `7.Double()`: members of the
receiver's type win, the definition is chosen statically, and it is scoped and overloaded like
a function. `class<concrete>` requires a default for every field; `class<castable>` is accepted on a class that is not parametric (`castable_parametric` otherwise, RFC-0092 B8).
None of this adds an IR operation: accessors, default bodies and forwarders are method bodies
with their slot's exact signature that narrow `Self` with a checked `downcast`. See
[RFC-0071](rfcs/0071-class-members-and-constructors.md) and `tests/conformance/class-members.forb`.

## Constructor functions, block clauses and final members

`MakeEntity<constructor>(Name:string, Health:i64 = 7)<transacts> := Entity{Name := Name, Health := Health}`
declares a constructor function: a function whose body is one archetype of its class. It is
called, overloaded, given named and default arguments and used as a value like any function,
and may be `<decides>`: every field value is computed before the instance exists, so a failed
constructor builds nothing, and what its field values wrote is undone with it. Inside an
archetype of the class or of a subclass, `MakeEntity<constructor>(arguments)` takes the place
of `Field := value` entries: the values that constructor's archetype writes become values of
this archetype, evaluated where the entry stands. A field it does not write takes the value the
delegating archetype names or the default of the class being built; a field given twice is
`duplicate_field`. The instance is still built by one `object_new` that takes every field, so
it is never observable half-built. A constructor function of an abstract class exists only to
be delegated to.

A member `Block{ ... }` of a class body runs on every new instance of the class and its
subclasses, after all fields have their values: the superclass's clauses first, then the
class's own in the order written. It sees `Self`, may assign `var` fields and call methods,
cannot fail or `Return`, and cannot build its own class. `Name<final>:T = value` is a field no
archetype gives and no subclass restates; `Name<final>(...)...= body` in an interface is a method
nothing below overrides.

No IR operation is added. A constructor function is a function whose template ends in the
`object_new`; delegation expands the part of that template that computes the given values into
the delegating archetype. The clauses of a class are one function `(Self:Class)<transacts>:logic`
that the compiler calls after every `object_new` of the class or a subclass, so the machines
admit construction exactly as before; that the clause calls are present is a property of
compiled code, not something admission checks. A constructor function whose values assign a
local or touch a module variable cannot be delegated to from another module. An extension method
no longer takes the bare name of an intrinsic (`6.BitAnd(3)` beside `BitAnd(6, 3)`), and a
`While` or `Loop{}` body may write `set Self.Field = v` without carrying `Self`. Defaults that
read `Self` or earlier parameters are implemented by RFC-0076, in functions, methods and
constructor functions. Type-narrowing field overrides are specified and not implemented; `<final_super>` is
implemented by RFC-0092 (below). See
[RFC-0075](rfcs/0075-constructors-and-class-initialisation.md) and
`tests/conformance/constructors.forb`.

## Classes completion (RFC-0092, B4)

A class's override may narrow its result to a class or interface below the inherited one, or
to anything `any` holds where the slot returns `any` (`Create<override>()...:derived_type`):
callers through the class see the narrower type, callers through a class above reach the
override as before. The override gets a slot of its own, with the parameters and effects of the
slot it replaces, and its class answers the old slot with a generated forwarder of the old
slot's exact signature, so every dispatch row both machines admit keeps its slot's signature.
An override may also narrow its access (`<public>` to `<protected>`, `<internal>` or `<private>`,
and so on, never across `internal` and `protected`); the narrowed access holds through its
class and below, a compiler rule like all member access. `Super{...}` in a method builds a new
instance of the superclass. `struct<E>` states the effect of building one, which every
archetype inside a function needs (`struct_effect_required_...`).

`class<final_super>(P)` marks a member of `P`'s family and needs a superclass;
`class<final_super_base>` requires every class directly below it to be `<final_super>`.
`GetCastableFinalSuperClass[Base, X]` (a failure context, a castable class `Base`, `X` of
`Base` or below) yields the `castable_subtype(Base)` of the family member `X` is of, or fails;
it calls one family function per base, made by the first query, which closes the family
(`final_super_after_query` for a member declared later). The marks are in the class table,
printed by inspection format 52 and checked by each machine's own admission
(`validFinalSupers`, `verifyFinalSupers`); no machine reads them to run anything. `<scoped>` is
left out (module lists need path identity, B7; independent checking needs scope lists in the
IR). No IR operation is added. See [RFC-0092](rfcs/0092-classes-completion.md) and
`tests/conformance/classes-complete.forb`.

## Parametric classes, structs and interfaces

`Box[T:type] := class{...}`, `Point[T:type] := struct{...}` and `Container[T:type] := interface{...}`
declare parametric types, in the bracket spelling of generic functions; `Box[i64]` names one
wherever a type is written, `Box[i64]{Value := 1}` builds an instance and `Box[i64][Value]`
casts to one. Each list of type arguments is one type: a catalogue definition of its own, made
where it is first named (which may be the middle of a function body) and found again by a hash
of its arguments, in every module of a bundle. An instantiation is a class, struct or interface
in every respect: fields and methods typed by the arguments, identity, and for a `class<unique>`
`==`, `comparable` and map keys (RFC-0076), superclasses and interfaces that are themselves
instantiations (`class(Box[i64])`,
`class(Container[T])`), dispatch through an instantiated interface, casts and `Case` type
tests, named and default arguments, access specifiers, `<abstract>`, `<final>`, `<concrete>`,
interface fields and default bodies, extension methods on the instantiated type, rollback. A
type may name itself with its own arguments (`Next:option(Node[T])`); a body that names its
template with arguments that grow without end is `instantiation_limit`, at the capacity
`instantiation_depth`. Parameters are constrained by `T:type`, `T:comparable` or
`T:subtype(Base)`, the last also on generic functions; a constraint is checked where the
arguments are written (`type_argument_bound`, `not_comparable`), and the body is checked for
each argument list, so it may use everything its bound has. Instantiations for different
arguments are unrelated types: there is no variance.

An instantiated class is declared in the two steps of a plain class: naming it reserves it,
after the supertypes its header names, and its fields, signatures and bodies are compiled at
once where nothing is in the way, otherwise as soon as the class that is collecting its own
fields and signatures has them, or the supertype whose declaration is open is finished. In
between it is what a class declared further down is to the code above it, so templates that
name each other mean the same whichever is named first. A struct instantiation is made in one
step. A plain class whose supertypes name an instantiation gets its place in the catalogue
after them (when it is first named or where it stands), as does every class below it; like
any class it can be named before its declaration. Programs without parametric types declare
their classes exactly as before.

No IR operation is added. `Class` and `Record` carry `arguments`, the tuple type of the type
arguments, as a specialized function carries `specialization`; name and arguments are the
identity of an instantiation. Both machines admit that the arguments are an earlier tuple
(so origins are acyclic), that the source declares a parametric type of that kind and arity at
the name, that `comparable` parameters have comparable arguments, and that no two definitions
of a module claim one name with the same arguments. They do not check that the fields are what
the template gives for the arguments, and need not: every operation is admitted against the
definition itself, and the origin only names the type in reports (`"class":"Box","arguments":[0]`)
and inspection. `any`, `void`, variance, refinement types, parametric aliases, generic methods
are specified but not implemented here (see RFC-0080, RFC-0081, RFC-0083); inferred type
arguments of generic functions are RFC-0091. See
[RFC-0073](rfcs/0073-parametric-types.md) and `tests/conformance/parametric-types.forb`.

## Functions completion (RFC-0091, B3)

```forbic
IsEven(N:i64)<computes>:logic=If(N==0,true,IsOdd(N-1))
IsOdd(N:i64)<computes>:logic=If(N==0,false,IsEven(N-1))
Func(A:i64,(B:i64,C:i64),D:i64)<computes>:i64=A+B+C+D
Fatal(Message:string)<computes>:false=Err(Message)
Half(N:i64)<computes>:i64=If(N>=0,N/2,Fatal("negative"))
Identity[T:type](X:T)<computes>:T{X}
A:i64=Identity(41)
```

**Mutual recursion.** A function body may call a module function declared further down in its
scope: one plain declaration of the name, whose header is read at the call (types resolved
there). No module value lies between the two (`forward_value_between`): a value is computed
where it is declared, so a function is called only once every function it reaches is
available. The root, defaults, generic bodies and constructor functions still need the
declaration first (`unknown_name`); a later overload, transparent function or unreadable
header is `forward_signature`, an omitted default `forward_arguments`. A body that called a
later `G` may not declare a local, parameter or nested function `G` after the call
(`shadowed_name`), as when `G` is declared first. The call is a `call`
of a later ID. Both machines admit it (rule F1) only for a named function with the caller's
`available_at`, and count it in the caller's summary as an `invoke` of its signature
(`member_work` saturated, control and failure set, heap state when it may touch the heap), so
summaries stay local and exact. Depth is bounded by the profile's frames (`call_depth_limit`).

**Destructured parameters.** `(B:i64, C:i64)` or `(B, C):tuple(i64, i64)`, nested to any depth,
types written once (`parameter_pattern` otherwise); the parameter is the tuple, its names
immutable locals bound at the start of the body by tuple element reads. Every kind of function
takes them but a constructor function; a pattern has no default and no name.

**`false`.** The bottom type, `Type.bottom` above the catalogue: valid everywhere, inhabited by
nothing, no equality, key, text, default or persistence. A value of it stands for any type as a
whole value (an argument, a result, a binding, a `set`, either arm of `If`/`Attempt`); the
compiler writes an `Err` of the expected type after it, which no run reaches. No variance
through aggregates (RFC-0067 D8). `Err`, `Return` and `Break` keep their typing.

**Inferred type arguments.** `Name(arguments)` of a generic function reads each type argument
off the argument types, through arrays, options, tuples and maps, exactly; a parameter no
argument gives, two arguments that disagree, an effect parameter, a named argument or a
`<decides>` template is `type_inference`. The call is the one `Name[types](...)` writes.

No IR operation is added; inspection, value, trace and SDK formats are unchanged. See
[RFC-0091](rfcs/0091-functions-completion.md), `tests/conformance/functions.forb`,
`mutual_recursion_tests.zig` and `function_completion_tests.zig`.

## Profile (RFC-0094, B6)

```forbic
Wait(S:float)<transacts><suspends>:float=Block{Sleep(S);S}
Quick:i64=Profile("quick",6*7)
Slow:task(float)=Spawn{Profile("slow",Wait(2.5))}
```

`Profile(Tag, Body)` yields the value of `Body` and, when `Body` has finished, prints
`profile <Tag>: <Seconds> s` through `Print`: `Seconds` is the text of the second reading of
`GetSecondsSinceEpoch()` minus the first (`0`, `2.5`). The readings are the recorded clock of
RFC-0086, one per tick of the virtual clock and never going back, so the second machine, the
digest second run and the replay see the same ones, and **a body that does not wait takes
`0 s`**. `Tag` is a `string` expression evaluated once, before the first reading. The form
needs the effects of `Print` and the clock (`<transacts>`), dictates (`<predicts>` refuses it)
and is no guard. A body that fails or is cancelled, or leaves with `Return` or `Break`, reaches
neither the second reading nor the line; a region that fails after the form discards the line
with the rest of its output, and the first reading stays in the record. A body that always
leaves is the form itself. The lowering is the two clock reads, the body, a subtraction,
`to_string` and `string_concat` of the line, and `std.print`: no operation is added. `Profile`
is a standard name, not a reserved word: any declaration of it wins. See
[RFC-0094](rfcs/0094-profile.md), `tests/conformance/profile.forb` and
`profile_form_tests.zig`.

## Breaking alignments (RFC-0076)

[RFC-0076](rfcs/0076-breaking-alignments.md) aligned nine rules with the Book at once. Five
reject programs that compiled before, with a diagnostic; D2 and the catching rule change
results without one; the last two only admit more programs.

- D2: `and`/`or` short-circuit; a plain right operand keeps the strict node. No diagnostic.
- D1: `A <= B <= C` is a chain; a comparison, `not`, `and` or `or` whose value a statement
  drops is `discarded_comparison` (a chain over a `logic` operand is `type_mismatch`).
- D5: no declaration may take a name that is visible where it is written: `shadowed_name`.
- D14: class and interface members are `<internal>` unless marked `<public>`: `internal_member`.
- D15: `==`, `!=`, map keys and `comparable` need a `class<unique>`: `not_unique`.
- D16: overloads whose parameter types overlap at every position: `related_overloads`
  (`option_logic_overloads` where an option stands beside `logic`). Two
  function types overlap when one function could be a value of both (`fix2`): effects never
  keep them apart, and classes overlap by a common supertype in a parameter.
- `option{E}` and the condition of an `If` catch wherever they stand. No diagnostic.
- A parameter default reads the parameters before it, and `Self` in a method
  (`field_read_requires_reads` since RFC-0078 for a field of `Self` in a method without `<reads>`).
- An extension method does not keep its bare name from a module in `using`. No diagnostic.

Each diagnostic is reported at the offending token: the operator, the name being declared, the
member being used, the operator or key, the second definition's name. See
`tests/conformance/alignments.forb` and `src/forbic/alignment_tests.zig`.

## Standard functions

The Book's standard functions over numbers, arrays, maps and strings are available in every
module without a declaration. A form with brackets can fail and needs a failure context; one
with parentheses cannot fail.

| Area | Forms |
| --- | --- |
| Arrays | `Xs.Find[V]`, `Xs.RemoveFirstElement[V]`, `Xs.RemoveAllElements(V)`, `Xs.Remove[A, B]`, `Xs.ReplaceFirstElement[V, W]`, `Xs.ReplaceAllElements(V, W)`, `Xs.ReplaceElement[I, W]`, `Xs.ReplaceAll(Pattern, Replacement)`, `Xs.Insert[I, Ys]`, `Xs.Last[]`, `Xs.Last[N]`, `Xs.Slice[A, B]`, `Xs.Slice[A]`, `Concatenate(Rows)`, `Concatenate(A, B, ...)` |
| Maps | `ConcatenateMaps(A, B)`: the first map's keys in their order with the second map's values where both have a key, then the keys only the second has |
| Strings | `S.Find[C]` (a `char`), `S.ReplaceAll(Pattern, Replacement)`, `S.Insert[I, T]`, `S.Remove[A, B]`, `S.Last[]`, `S.Last[N]`, `Join(Strings, Separator)`, `Concatenate(Strings)`, `ToString(S)` |
| Numbers | `Abs`, `Min`, `Max`, `Clamp` (for `i64` and for `float`), `Sqrt`, `Pow`, `Exp`, `Ln`, `Log(Base, X)`, `Sin`, `Cos`, `Tan`, `ArcSin`, `ArcCos`, `ArcTan(X)`, `ArcTan(Y, X)`, `Sinh`, `Cosh`, `Tanh`, `ArSinh`, `ArCosh`, `ArTanh`, `Lerp(From, To, Parameter)`, `X.IsFinite[]`, `PiFloat` |

The array forms that search compare as `==` does and need a comparable element type; the
others take any element type. A range form fails unless `0 <= A <= B <= Length`, an index
form unless the index is inside, and `Last[N]` unless `N` is in `0..Length-1`; the ends of
`i64` are positions like any other. A string stays text: positions are code units, `Insert`
and `Remove` fail at a position inside an encoded scalar, and the element-wise methods are
those of a `[]char` only. `Abs` of the least `i64` is the fatal `arithmetic_overflow`. The
float functions never fail: outside their domains they give NaN or an infinity, `Min` and
`Max` give NaN when either argument is NaN, and every result is a function of its arguments
alone on every host, because the kernels use only IEEE arithmetic (no host C library).

None of the names is reserved, and a name has one meaning in a scope. A function name means
the standard function only where the program declares nothing by it (a local, parameter,
binding, function, generic, native binding, type, alias, a name a `using` brings in, or a
member of the class a method is in); a method name only where the receiver's type has no
member of the name and no extension method of the name is declared for that type. A call with
no receiver never reaches a method, the method it is written in included: a method recurs
through `Self.M(...)`, which dispatches (RFC-0076). A module's
own top-level declaration of a name is the module's throughout: a use above it is the
unknown name it always was, not the standard function. In a block, a local may take a
standard name, but not after the block used the name as the standard one
(`used_before_declaration`). A private name of a module that is `using`-ed is not in reach,
so the standard one applies in the module that uses it. The bit operations follow the same
rules. The names are forms, not values (`F := Sqrt` is `unknown_name`).

No IR operation was added: a form is a `native_call` of a kernel of the standard table, or
reads, slices, concatenations and `array_set` that existed, behind an ordinary `demand` when
it can fail. Costs are those of RFC-0042 (the declared cost of the kernel, one unit per member
built, comparisons charged as `==`), so the array forms are linear in the arrays they read
and build, except `ReplaceAll` of an array, whose plain search is the product of the lengths
in the worst case and is charged comparison by comparison; `ConcatenateMaps` is linear in the
entries of its maps, and the string forms in their bytes whatever the bytes are (a two-way
search). Not offered: `SortBy` (needs a
function a native can call). `Print`, `ToDiagnostic`, `GetRandomInt`, `GetRandomFloat` and
`Shuffle` are native effects: see the next section. See
[RFC-0077](rfcs/0077-standard-library.md), `src/forbic/stdlib_tests.zig` and
`tests/conformance/stdlib.forb`.

## Native effects

A run acts on the world only through an effect native, and takes from it only through one
(RFC-0079). `Print(Message)` is one line of output and yields `tuple()`;
`Print(ToDiagnostic(Value))` prints a value of any type (numbers, `logic`, characters and
strings as `ToString` gives them, a value whose type has a `ToString` of the program's own as
that says, other values as their kind), and `ToDiagnostic` stands
nowhere else (`diagnostic_position`); `GetRandomInt(Low, High)` and `GetRandomFloat(Low, High)`
draw uniformly between bounds given in either order, both included; `Shuffle(Items)` is a
uniform permutation. Each needs `<transacts>` in a function, all three heap effects of
RFC-0078 (`call_requires_*` names those missing), and each
yields to whatever the program declares by its name.

**Loops at the root.** The root may do all of this, and so may a loop there (`fix2`).
`Loop{...}` at the root always could (its function has every heap effect, and an `Fn` in it
inherits them). The function a macro writes for a `For`, `While` or `First` at the root, or
inside another such function, is compiled with every heap effect and declares exactly the
ones its body uses, so a loop that uses none compiles as before. A function the program
writes inside such a loop keeps the `<computes>` it has at the root, and inside a function of
the program a loop still does only what that function may.

**Rollback regions and the effect log.** Every `attempt_begin` opens a rollback region, in a
function or at the root, whether or not there are cells; its `otherwise` commits it and a
failure it catches aborts it, as for cells. An action is *prepared* at the call: the native
hands its bytes to the machine's effect log, which copies them and holds them under the
innermost open region. When that region commits its actions join the region around it, and
when the outermost one commits they are *committed*, shown in program order. Outside every
region an action is committed at the call. When a region fails, its actions and those regions
inside it handed up to it are *aborted*: output printed inside a failed `Attempt` never
appears. A fatal error aborts what is pending and leaves what was committed, because that has
been shown. A sink of the host that refuses to prepare an action is the fatal
`effect_prepare_failed` at the call (never a failure the guest could catch, which would make
the run depend on the device), and one that fails to commit is `effect_commit_failed` at the
node that committed. The log counts open regions and keeps a mark only for a region that
prepared an action of its own, so nesting costs nothing and the marks cannot outgrow the
entries.

**Draws.** The run's stream is SplitMix64 at a position, from a seed the host gives
(`effects.default_seed` unless it says otherwise; `forbic eval FILE --seed N`). A draw advances
the position and rollback never moves it back (RFC-0067 D19): what a failed region did with a
value is undone, the draw is spent. The seed is the whole record of the world's part in a run,
so the second machine and the report replay read the same values from it and never ask the
world. `GetRandomInt` rejects the words that would favour low values (at most 128 in a row,
which no run reaches); `GetRandomFloat` reads one word, takes 53 bits, interpolates and clamps,
and is NaN for a bound that is not finite; `Shuffle` reads one word and permutes by a
Fisher-Yates pass over the stream that word names.

**Trace modes and reclamation.** A `full` run keeps every committed action for its report,
which lists them, so it commits at most `effect_entries` (`effect_limit` beyond). A `digest`
or `off` run hands each committed action to the host's sink and releases it, so a loop that
prints outside a region is bounded by fuel alone; only actions of open regions occupy the log.
The log holds copies, so reclamation neither keeps its bytes alive nor rewrites them. An
effect at the root leaves a call step of kind `root`, sent at once in a run that streams its
steps, so that a replay reads the action's text from the shared string pool while it holds it.

**Admission and replay.** Each machine refuses, in its own function admission, a call of an
effect native in a function that is not `<transacts>`. A table entry declares its effect, and a
native is lent only the port of the effect it declares (`invalid_native` otherwise); an effect
native takes scalars and strings only, an action returns `tuple()` and a draw a number or a
`logic`. The report replay counts regions as the machines do, runs each effect native again
against a port of its own (no pools), and requires the record of the run (seed, words drawn,
the tally of committed actions, the number discarded and, in a `full` run, the actions
themselves, compared byte for byte as they are prepared) to be the one the steps lead to; a recorded draw must be the value the replay's
own stream gives. Both machines agree on the record of every program the harness runs.
`Execution.effects` is the record; `effects.Log`, `effects.Sink` and `effects.Recorder` (a test
double that refuses a chosen prepare or commit) are the host's side. See
[RFC-0079](rfcs/0079-native-effects.md), `src/forbic/native_effect_tests.zig`,
`effect_machine_tests.zig`, `effect_replay_tests.zig` and `tests/conformance/native-effects.forb`.

## Inputs: the wall clock (RFC-0086, P2.2)

What the world gives a run that no seed gives is an *input*: an `input` effect native
(`native.Effect.input`) asks the run's input log (`effects.Inputs`, in each machine's effect
log), which records the answer as an entry `{sequence, kind, request, tick, status, value}`
before the native sees it. An entry is never rolled back, by a region that fails or by a fatal
error (I2, I8): what a failed region did with the value is undone, the reading is spent.
`GetSecondsSinceEpoch()` (`native{"std.clock_seconds"}`) is Unix time in seconds, a `float`,
read **once per tick** of the virtual clock (Q1): the first read at a tick asks the world and
records the raw answer; every later read at that tick, in any task or region, yields the same
value and records nothing. The value never goes back: it is the raw reading, or the previous
value where the world's clock went back (`<` decides, so of two zeros the earlier stays). The
root runs at tick 0. It needs all three heap effects (`call_requires_*`), so no guard holds it
(`guard_effect`), and it yields to every declaration of its name.

**One world, then the record (I3).** A log asks its *prefix* while it lasts, each request
required to be the recorded one (`kind`, `request`, `tick`; `input_diverged` otherwise), and its
host's `effects.InputSource` after it. The first run has no prefix. The second machine of a
test, the `digest` second run of a report (given it by the replay through
`TraceProducer.inputs`) and the tool's rerun after a limit (`Inputs.again`, the log's own record
as its prefix) are given the earlier run's record, so they never ask the world for what it
already answered. A source that cannot answer is `input_failed`, a run without one
`input_unavailable`, an answer that is no time (NaN, an infinity) `input_invalid`, each fatal at
the call. The record is bounded by `input_entries` and `input_bytes` (`input_limit` at the call
that would record one more), not by fuel; a million reads at one tick hold one entry.
`input_limit` is not a limit at which the tool runs again.

**Report and replay.** `forbic eval` adds `"$inputs":{"count":C,"bytes":B}` after `$scheduler`
and before `$live` when the run recorded an entry; a program that reads nothing reports as
before. The report replay never runs an input native: `InputReplay` keeps a cursor into the
record, the latest reading and the scheduler replay's tick, works out at each call whether it
took an entry (which must be the next one, asked at that tick) and what value it had to yield,
and at the end requires every entry to have been taken. It knows the standard input natives by
id; a report of a call of another is refused. `forbic eval|check|trace FILE --clock S` makes the
host's clock read `S + now / R` seconds at tick `now`; without it the host reads its real-time
clock. See [RFC-0086](rfcs/0086-input-effects-and-durable-sink.md), `effects.zig` (the log,
`effects.Script`, the random model), `src/forbic/input_tests.zig` and
`tests/conformance/native-inputs.forb`.

## Grants and handles (RFC-0086, P2.3)

A host grants a run, before it starts, an ordered list of named capabilities
(`effects.Grant`, in `effects.Inputs.grants`): **readers**, line sources it opened, and
**writers**, append-only channels. The list is a run parameter, like the seed: both machines and
the replay's second run are given the same one, the record carries it (`Record.grants`), and
nothing during a run changes it. A **handle** is a value of the built-in type `reader` or
`writer` (`Definition.grant`), an enumeration value whose index is the grant's index; only the
`grant` operation makes one, which `OpenReader[Name]` and `OpenWriter[Name]` lower to (an option
unwrapped in a failure context: no grant of the name, of the kind, fails). Opening needs
`<reads>`, predicts, and costs a unit per grant of the kind compared. Handles are comparable (equal
when they name one grant), can be stored, passed and used as map keys, and cannot be built, cast
to or from `any`, type-tested or named by an enumerator; each machine refuses IR that makes one
any other way, and the replay refuses a report whose handle names no grant of its kind.

`R.ReadLine[]` (`std.read_line`, an `input` native) reads the next line of the grant's stream
into the run's strings: the bytes up to the next newline, without it, which must be UTF-8 text
(`input_invalid` otherwise); a stream's end is an entry like a line, and the read fails on it.
Every read is an input entry with the grant's index as its request, never rolled back: a line read
in a region that fails is spent, and two handles of one grant share its stream (I2, I6, I7).
`W.WriteLine(Text)` (`std.write_line`, an `output` native) is an action on the writer's
**channel**, its grant's index plus one (channel 0 is `Print`'s): held by its region, committed
with the outermost one, in one sequence and one commit order with every other channel
(`Entry.channel`, `Action.channel`; the tally folds every channel but 0, so no earlier record
changes). Both need all three heap effects and dictate. A native reaches only the grant it was
given (`Context.handle`; `invalid_native` otherwise). `forbic eval|check|trace FILE --read
NAME=PATH --write NAME=PATH` grants files (`-` is standard input for a reader); only `eval`
appends a writer's committed lines to its file, as only `eval` shows `Print`'s. A report prints
a handle as `{"$reader":"NAME"}` or `{"$writer":"NAME"}`; inspection of a program with a handle is
format 35. See [RFC-0086](rfcs/0086-input-effects-and-durable-sink.md) "P2.3 as implemented",
`src/forbic/handle_tests.zig`, `handle_forgery_tests.zig` and
`tests/conformance/native-handles.forb`.

## The durable journal (RFC-0086, P2.4)

A run can be **journaled**: `forbic eval|trace FILE --state DIR` writes `DIR/journal`, one
append-only stream of checksummed records (`src/forbic/durable.zig`): a header (the toolchain, the
profile, the program's SHA-256, the seed, the tick rate and the grants), every input the world
gives the run, appended before the guest sees it (`effects.InputJournal` in `Inputs.journal`;
an append that fails is `input_failed` and records nothing), every committed action, and one
**seal** per commit point. The effect log tells its sink where each commit point ends
(`effects.Sink.seal`, after the actions of an outermost region that commits, or of an action
outside every region; none for a region that fails or commits nothing), so the actions of one
region become durable together or not at all. Syncs are grouped (64 seals in the tool); a reader
cuts a journal at its last valid seal or end, so what a crash leaves is a whole number of commit
points. Nothing is shown before its seal is durable: the journal reads back what each sync made
durable and shows it (`Print`'s lines on standard output in an `eval`), and at the end each
writer's target is written again from its base copy (`DIR/writers/G.base`) and its channels'
durable lines, through a temporary file renamed over it. A disk operation that fails ends the run
with `effect_commit_failed` or `input_failed` at the node, alike on both machines; the journal then
takes nothing more. The VM state is never in the journal: rollbackable state is lost in a crash and
was never visible; the actions and inputs that were sealed survive it. A journaled run is a
`digest` run from its first attempt, and a state directory is locked for its run. `--seed random`
draws the seed from the host's entropy and prints `forbic: seed N`; `forbic journal show DIR` prints
a journal's durable prefix, one JSON object per record. See
[RFC-0086](rfcs/0086-input-effects-and-durable-sink.md) "P2.4 as implemented",
`src/forbic/durable.zig`, `durable_tests.zig`, `src/tooling/journal.zig`,
`src/dst/journal.zig` and `tests/conformance/native-journal.forb`.

**Recovery (P2.5).** A crash is recovered by running the program again, not by undoing anything.
At its end a run publishes its writers and renames its journal to `DIR/journal.done`, so the next
run on the directory starts afresh; a journal left in `DIR/journal` is one whose run did not finish
(or whose end's processing did not: the next command publishes and rotates it, but only to the files
it grants itself under the same names). Without a flag such a run is refused (`run_unfinished`).
`--resume` cuts the journal after its last valid seal (R1), checks that the header is this run's
(program digest, toolchain, profile, seed, tick rate and grants: `recovery_mismatch`, before
anything is written, the lock file included), that each reader is a regular file whose sealed lines
are still its first bytes, and that the writers' bases and the files they share are the recorded
ones (R3, R6), then runs the program from its start with the header's parameters. Its input log is served the
sealed inputs (I3), and its journal is in verify mode: each action and seal up to the cut is
compared with the journal's (channel, bytes, and the inputs taken by then) and neither appended
nor shown again; past the cut the journal appends and the readers read on. A run that does not do
what the journal holds, or that asks the world for an input before it passed the last seal, ends
with `recovery_diverged` at the node and leaves the journal as cut. `--abandon` cuts the journal,
publishes the writers it can from what was sealed (one it cannot is named and skipped, and the
command exits with 1), appends `abandoned` and rotates the journal; it reads no program. A journal
is never taken for no journal unless its first record is no whole header: one of more grants than
the build holds is refused. Rollbackable VM state is rebuilt by the re-execution; external actions
are exactly once by their sequence numbers (on Windows, as far as the file system keeps its renames
in order), and the standard output of a crashed run is at most once. See RFC-0086 "P2.5 as
implemented" (G1 to G22).

## Effect families

RFC-0078 adopts the Book's effect families. A signature states a heap effect, which is
mandatory: `<computes>` (none), `<transacts>` (all three), or one to three of `<reads>`,
`<writes>`, `<allocates>`; `<reads><writes><allocates>` is `<transacts>`. `<decides>` or
`<suspends>` may follow, never both; specifiers come in any order, each once, and
`<computes>`/`<transacts>` stand alone among the heap words.

```forbic
var Count:i64 = 0
counter := class{var N:i64 = 0}
Peek()<reads>:i64 = Count
Reset(C:counter)<writes>:i64 = Block{set C.N = 0; 0}
Fresh()<allocates>:counter = counter{}
Twice(F:function<transacts>(tuple(i64),i64), X:i64)<transacts>:i64 = F(F(X))
```

- Reading a module `var` or any field of a class instance needs `<reads>`; `set` needs
  `<writes>` (a compound `set X += E` both); building an instance needs `<allocates>`; a call
  needs every heap effect of its static callee. Each missing effect is its own diagnostic,
  which names it.
- Every heap effect is journalled and undone when its failure context fails, so every
  combination is allowed there: `<writes><decides>`, `<allocates><decides>`.
- A function with fewer effects stands where more are expected: in a binding, an argument,
  a result, a field, an element, a `var`. It is lowered to an `upcast` to the wider function
  type. An override or interface implementation may narrow its slot's effects, never widen
  them.
- A function type also takes a function whose parameters are classes (or interfaces) above
  its own and whose result is a class below its own (`fix2`, the Book's variance); other
  parameter and result types stay exact, and so do overrides.
- The arms of an `If` or `Attempt` that are functions join to the narrowest type both are
  values of: the wider one, or the same parameters and result with the effects of either
  (the Book's union). The second arm is widened where it stands and the `merge` widens the
  first, which both machines admit as they admit an `upcast`. Arms that carry the versions of
  locals they assign, and effects that cannot stand together (`<decides>` with
  `<suspends>`), do not join (`type_mismatch`).
- `class<E>` and `interface<E>` state the effect of building an instance beyond its
  allocation; the block clauses are compiled under it and every construction needs it.
- `<suspends>` is declared and checked: a suspending function is called only from one,
  outside every failure context and `Defer`. Module initialisers are not such a context, so
  nothing suspends before P3.
- `<converges>` is trusted on a native's entry (every standard native has it), accepted and
  not carried on an abstract method, and checked by sub-effecting on a function type.
- Both machines check the declared set of each function against its body and its callees,
  refuse non-canonical sets, and refuse a suspension reachable from the root. Inspection
  format 26 lists the sets when one is narrower than the earlier formats can say.

## `void`, `any`, `Case[...]` and `ToArray` (RFC-0080)

```forbic
Bump(N:i64)<transacts>:void = Set(Count, Count + N)      # the body's value is dropped
Whole:any = any(5)                                       # the one way into any
AsInt:i64 = Attempt(i64[Whole], -1)                      # a checked cast out: 5
Kind(V:any)<computes>:string = Case(V, N:i64 => "int", K:Dog => "dog", _ => "other")
Named(N:i64)<computes><decides>:string = Case[N, 1 => "one", 2 => "two"]
Listed:[]i64 = ToArray(tuple{1, 2, 3})
Nothing:[]i64 = Concatenate()
```

- **`void`** names the type `tuple()`. A function, method, extension method, generic function
  or `Fn` whose result is written `:void` takes a body of any type, drops its value and yields
  `tuple{}`; a body that is itself a comparison is `discarded_comparison`, as a dropped
  statement is. Nothing else converts to `void`: `X:void = 5` is `type_mismatch`, and
  `Return(V)` in such a function gives the unit value. `void(X)` evaluates `X` and is `tuple{}`.
- **`any`** is the top type: a place of type `any` holds a value of some other type,
  unchanged. A value gets there only through `any(X)`; nothing converts implicitly. It comes
  back through `Type[Value]`, which fails unless the value is of the type, or through a
  `Name:Type` arm of a `Case`. `Type` is any named type: a scalar, `string`, `char`,
  `rational`, a struct, an enum, a class or interface, an instantiation, an alias of a
  structural type, a type parameter. A value is of the type it was made as and of no other,
  except that an instance is also what its class inherits and implements. `any` has no other
  operation: no `==` (`not_comparable`), no arithmetic, interpolation, member or index, no map
  key. There is no box: `any(X)` is an `upcast` node of type `any`, the cast is `instance_of`,
  a `demand` and `downcast`, and each machine asks the value itself what it is. Both
  admissions refuse every other operation on an operand of type `any`.
- **`Case[Scrutinee, arms...]`** fails when no arm takes the scrutinee, undoing what its
  region wrote, and needs a failure context. It has no `_` arm or irrefutable pattern, nor an
  unguarded arm whose type tests all hold by the static types (`X:any`; `M:i64` over an
  `i64`), checked per argument list in a generic function (`case_cannot_fail`); it need not cover an enum, and refuses an arm written exactly like an
  unguarded arm before it (`unreachable_arm`). `Case(...)` is as total as it was.
- **`ToArray(Tuple)`** is the array of a tuple's elements: their one type is the element
  type, or, where the place of the call expects an array type, each converts to its element
  type as a value does anywhere. `Concatenate()` is the empty array or string its place
  expects; the first argument of `Join`, and of `Concatenate` with several arguments, is typed
  by the form or by the place of the call, so an empty `array{}` may stand there.
- `Ints := Lib.Kit.Box[i64]` aliases an instantiation reached through a module path.
- `void`, `any` and `ToArray` are not reserved: a declaration of the program by one of these
  names is what the name means, by the rule of the standard functions. A use of `void` or
  `any` above the module's own declaration of that type name is `unsupported_type`.

See [RFC-0080](rfcs/0080-remaining-types.md), which also specifies what is left (the
`subtype` family as values, generic methods, refinement types, `SortBy`), and
`tests/conformance/remaining-types.forb`.

## Generic methods, the `subtype` family, `SortBy` and function types (RFC-0081)

```forbic
Box[T:type] := class{
    Value:T
    Map[U:type](F:function(tuple(T), U))<reads><allocates>:Box[U]{ Box[U]{Value := F(Self.Value)} }
}
Mapped:string = Box[i64]{Value := 5}.Map[string](Fn(N:i64)<computes>:string{ "v{N}" }).Value
Wanted:castable_subtype(Component) = Physics          # a type value
Found:logic = Attempt(Block{ Wanted[Part]; true }, false)
Spawn(K:concrete_subtype(Entity))<allocates>:Entity = K{}
Cast[T:castable_subtype(Component)](C:Component)<computes><decides>:T{ T[C] }
Sorted:[]i64 = SortBy(array{3, 1, 2}, Less)           # Less(A, B)<decides> succeeds when A goes first
Wide := function<transacts>(tuple(i64), i64)          # an alias may name effects
Back:i64 = Attempt(Wide[any(Twice)], Other)(21)       # a function with fewer effects is a Wide
```

- **Generic methods.** A method of a class, interface or parametric type may have type
  parameters of its own: `Name[U:type, ...](...)<effects>:Result{ body }`, the body in braces
  as a generic function's. `Value.Name[Types](Arguments)` calls the specialization for those
  types, compiled once for each list of types and each class that declares the method (the
  instantiation, for a parametric type); without a call it is a function value bound to the
  receiver. A generic method has no dispatch slot, so it is final: `<override>` and
  `<abstract>` on one, a body-less one (also in an interface), one that would replace a member
  of a class above, and a member below that takes its name are `generic_method_slot`; two
  members of one name in a class are `duplicate_name`; a name a class reaches by two supertypes
  is `ambiguous_call` where it is used. Its type parameters may not take the names of the
  parametric type's, and its bounds may not name them.
- **The `subtype` family.** `subtype(T)`, `castable_subtype(T)` and `concrete_subtype(T)` are
  types, and a type name written where one is expected is a type value: a class or interface
  below `T` (a declared one, not an instantiation), and for `subtype(T)` of a type that is not a
  class, `T` itself. `castable_subtype` needs a class declared `<castable>` or below one
  (`not_castable`); `concrete_subtype` a class declared `<concrete>` that is not abstract
  (`not_concrete`). `K[V]` casts through a `castable_subtype` value as `Class[V]` does, and
  `K{}` builds through a `concrete_subtype` value (an empty archetype only), with the effects of
  building an instance of `T`. A value is a struct the compiler makes for the metatype, named
  by it, holding the function that tests or builds the class; it is not comparable when it
  holds one. Values of different metatypes do not convert into each other (types stay exact).
  `castable_subtype(T)` and `concrete_subtype(T)` also bound type parameters.
  `castable_concrete_subtype(T)` (RFC-0092, B8) is both: its value holds the test and the
  construction, needs a class that is `<castable>` (or below one) and `<concrete>` and not
  abstract (`not_castable`, then `not_concrete`), casts with `K[V]` and builds with `K{}`, and
  bounds type parameters (both rules). It is its own type: not a `castable_subtype(T)` or a
  `concrete_subtype(T)`, and not comparable.
- **`SortBy(Items, Less)`** is the array in the order `Less` gives, stably: `Less(Left, Right)`
  is a failable function that succeeds when `Left` goes first. Each comparison runs in a
  failure region of its own: one that fails undoes what it did, one that succeeds keeps it, an
  error ends the run. It is a bottom-up merge sort written in the language (a generated
  template), charged like any code: `O(n log n)` comparisons and appends. The name is the
  standard function only in a bundle that uses the name for nothing else.
- **Function types.** `Name := function<effects>(...)` is an alias. A cast out of `any`, and a
  `Case` type test, take a function whose effects are fewer than the target type's, as every
  other place where a value meets a declared type does (RFC-0078); the value comes out at the
  target type.

See [RFC-0081](rfcs/0081-generic-methods-and-subtypes.md) and
`tests/conformance/generic-methods.forb`.

## Structured concurrency: `Spawn`, `Sleep` and the scheduler (RFC-0082, P3.1)

```forbic
var Log:[]string = array{}
Note(S:string)<transacts>:void = Set(Log, Log + array{S})
Fetch(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.1); Note("fetched {N}"); N * 10 }
Main()<transacts><suspends>:void = Block{ W := Spawn{ Fetch(1) }; X := Fetch(2); Note("got {X}") }
Started:task(void) = Spawn{ Main() }
```

`Spawn{ Statements }` starts a task that runs the statements, a body compiled as an anonymous
function of no parameters that captures by value (a local `var` it names is shared, RFC-0085 I13),
does what the code around it may to state and
suspends; it needs `<allocates>` and yields the handle `task(T)` of its body's type. Outside every
rollback region the task runs at once, on top of its creator, until it first waits or settles; in
a region its start is held and happens when the outermost region commits, after the region's
output, or never when the region fails. `Sleep(Seconds)` waits on the virtual clock: `ceil(S * R)`
ticks at the run's tick rate `R` (60 by default, `--tick-rate N`), the next tick for zero, at once
for a negative duration, never for infinity or a deadline at or above 2^62, and NaN is the fatal
`invalid_sleep_duration`. It stands only in a `<suspends>` function, outside every failure context
and `Defer`, as a call of a `<suspends>` function does. The root runs first and never waits; then
the scheduler runs ready tasks in turn, jumps the clock to the earliest deadline when none is
ready (timers of one deadline wake in the order they began), and ends quiescent, listing the
tasks that still wait. A body cannot `Return` or `Break` out of itself (`return_in_task_body`), also through a loop's
macro, nor assign what it captured for a parameter or an immutable local (`arm_assigns_local`;
a local `var` it assigns is shared, RFC-0085 I5). A `Spawn` in a loop at the root makes
the loop declare every heap effect.

Every site (a `sleep`, or a call of something that suspends) is followed in IR by its check:
`canceling`, an `if_begin` on it whose first arm, the landing, ends with `cancel_exit`, an empty
`otherwise`, and a `merge` of the two that code after the site uses. Both machines admit the shape
exactly, refuse a site in a function that does not suspend, at the root or inside the first arm of
an `attempt_begin`, refuse `canceling` and `cancel_exit` anywhere else, and refuse a reader of a
site's register other than its merge. No task is cancelled before P3.3, so `canceling` is `false`.
A task's frames move to bounded stores when it waits (`tasks`, `saved_frames`, `saved_registers`,
`scheduler_actions` are profile capacities, each a located fatal error at its limit; the saved
registers count the saved frames' parameters too), and the run
records its scheduler (`Execution.scheduler`: tick rate, final tick, tasks created, completed and
cancelled, switches, the tasks left waiting), which both machines agree on and the report replay
works out again from the steps `start`, `suspend`, `resume`, `settle` and `tick`. A frame end
that saw another task run since its push reclaims with the suspended tasks' values as roots
(P3.5, below). Reports of a program that spawns end with
`"$scheduler"`, show handles in place as `{"$task":{"sequence":N,"state":S}}` (with `"result"`
when completed) and `var` bindings with their final values. Inspection
format 27 shows the operations. See [RFC-0082](rfcs/0082-structured-concurrency.md),
`src/forbic/concurrency_tests.zig`, `src/forbic/scheduler_model.zig` and
`tests/conformance/concurrency-spawn.forb`.

## Refinement types, qualifiers, parametric aliases and open enums (RFC-0083)

```forbic
Age := type{_X:i64 where 0 <= _X, _X <= 120}         # a type of its own over i64 or float
Valid:Age = 25                                         # a literal within the bounds
ToAge(N:i64)<computes><decides>:Age = Age[N]           # a cast that fails outside them
Older:i64 = i64(Valid) + 1                             # i64(X), float(X): the base again
Mix()<computes>:i64 = Block{(local:)Volume:i64 = 1; Volume}   # beside a module's Volume
Strings[T:type] := map(string, T)                      # a parametric alias
Mode := enum<open>{On, Off}                            # Case(...) over it needs `_`
```

- **Refinements.** `Name := type{_X:Base where C1, C2}`, at module level, with `Base` `i64` or
  `float` and each constraint `_X op L` or `L op _X` (`<`, `<=`, `>`, `>=`) against a literal of
  the base (`Inf`, `-Inf` for floats; never NaN); at most one bound per side, some value between
  them (`refinement_bound`). A literal written where the refinement is expected converts when it
  lies within the bounds (`outside_refinement` otherwise); `Name[V]` casts a value of the base,
  failing outside them (a NaN is outside every float refinement); `i64(X)` and `float(X)` give the
  base back. A refinement has its base's equality and is a type like any other in every place;
  arithmetic, ordering and the base's functions need the conversion first, and it does not go
  into `any`. The IR is the catalogue definition `refinement` (base, bounds as bits, open flags)
  and the operation `refine` between a refinement and its base; each machine checks the bounds
  there (a forged value outside them is invalid bytecode), both admissions refuse every other
  use of a refinement where the base is expected, and the report replay checks every value of a
  refinement it meets against its bounds.
- **Qualifiers.** A local or parameter declared `(local:)Name` may share its name with a
  declaration outside the function or a name a `using` brings in (the one exemption from
  RFC-0076 D5); inside its scope `Name` is the local. A use `(local:)Name` must be a local or
  parameter. `(Module:)Name` is `Module.Name` with `Module` a module. Anywhere else a qualifier
  is `invalid_qualifier`.
- **Parametric aliases** `Name[T:type, ...] := Type` are the type the text names with the
  arguments in place, with the constraints of a parametric type; nothing is built through one,
  each list of arguments is read once, and they nest at most eight deep.
- **Open enums** `enum<open>{...}`: a `Case(...)` over one without `_` is `open_enum_case`;
  `Case[...]` over one fails instead.
- In `Case[...]`, and since RFC-0090 in `Case(...)`, an arm whose type an earlier unguarded
  `Name:Type` arm takes (the same type or one below it) is `subsumed_arm`.

Inspection format 28 shows refinements (`"kind":"refinement"` with `base`, `low`, `high` and
`low_open`/`high_open` when set), `refine` and `"open":true` on an open enum. See
[RFC-0083](rfcs/0083-refinements-qualifiers-aliases.md) and
`tests/conformance/refinements.forb`.

## Structured concurrency: events and `Await` (RFC-0082, P3.2)

```forbic
Gate:event(i64) = event(i64){}
Waiter()<transacts><suspends>:i64 = Gate.Await()
Main()<transacts><suspends>:i64 = Block{ W := Spawn{ Waiter() }; Gate.Signal(7); W.Await() }
Started:task(i64) = Spawn{ Main() }
```

`event(T){}` builds an event, an instance with nothing between its braces, so it needs
`<allocates>`. `E.Signal(V)` needs `<writes>` and is no site: outside every rollback region it
wakes every task waiting on `E` then, in the order they began to wait, each to resume with `V`
when the scheduler reaches it, for one unit of fuel per task woken; with none waiting `V` is
lost. Inside a region it is held with the region's starts, in program order, and carried out when
the outermost region commits, or never when it fails. `E.Await()` and `T.Await()` for a handle
`T` are sites, needing `<reads><suspends>`: an event's next `Signal` is always waited for; a
handle whose task completed gives its result at once (sticky), and one whose task has not makes
the task join its awaiters, which resume with the result in order when it settles. Awaiting is
not owning. `event`, `Await` and `Signal` are standard names and yield to the program's own
declarations, extension methods of the receiver's type included. An event is printed in place
as `{"$event":{"waiting":K}}`; its hidden cells count its waiters and name the first and the
last by sequence, so the three schedulers agree on them. Tasks left waiting at quiescence are
listed with what they wait for (`"wait":"event"` or `"task"`). The values the scheduler holds
for later (a ready task's resume value, a waiting task's event or handle, and held signals) are
roots of reclamation. See RFC-0082 ("P3.2 as implemented"),
`src/forbic/concurrency_event_tests.zig` and `tests/conformance/concurrency-events.forb`.

## Structured concurrency: `Sync`, `Race` and cancellation (RFC-0082, P3.3)

```forbic
Fetch(N:i64, S:float)<transacts><suspends>:i64 = Block{ Defer{ Print("done {N}") }; Sleep(S); N * 10 }
Both()<transacts><suspends>:tuple(i64, i64) = Sync(Fetch(1, 0.5), Fetch(2, 0.25))   # (10, 20)
First()<transacts><suspends>:i64 = Race(Fetch(3, 2.0), Fetch(4, 0.5))               # 40
```

`Sync(A1, ..., An)` and `Race(A1, ..., An)` are sites: they need `<suspends>`, stand outside
every failure context and `Defer`, and take from two arms up to the parameter limit
(`concurrency_arms`); a `Sync` needs two arms that can suspend (`sync_arms`). Each arm is an
expression compiled as a function of no parameters, like a `Spawn` body: it captures by value,
except a local `var` it names, which is shared (RFC-0085 I13) (`arm_assigns_local`; from RFC-0085 I5 a local `var` an arm assigns is shared), can be left by
`Return` or `Break` only from P3.6 (below), and does what
the code around it may. A `Sync` yields the tuple of its arms' results in arm order; a `Race` the
result of the first arm to complete, its type the one its place expects or else its first arm's.
The arms start in order, each a task handed off to at once and running until it first waits or
settles; no arm starts once a `Race` is won. A `Race` asks every other started arm to cancel, in
arm order, and yields only when all of them have settled. `Sync` and `Race` are standard names
and yield to the program's own declarations.

Cancellation is a request: a sleeper's timer goes, a waiter leaves its event or task, and the
task is ready to yield cancelled; a task waiting on an expression passes the request to its
arms, depth first, and yields cancelled once they have settled. A task yields cancelled at its
site: the check after the site takes the landing, which runs the `Defer`s whose scope is open
there, innermost first, and ends the frame by `cancel_exit`; the call in its caller yields
cancelled in turn, down to the task's first frame, and the task settles `canceled`. Children
therefore settle before their parents go on. A landing calls each `Defer`'s body as a function
compiled once, where the `Defer` stands, with the locals as they are at the site; a local `var`
such a `Defer` assigns is shared (RFC-0085 I5), so the landing writes its cell. Only a program with a `Sync` or
a `Race` can cancel a task, so only such a program gets landings. New steps (`resume_canceled`,
`cancel_exit`, `call_canceled`, and `settle` without a result) record the unwinding, and the run's
record counts the cancelled tasks; the report replay works all of it out again. Tasks left
waiting may be arms (`"kind":"arm"`) or tasks waiting on an expression (`"wait":"record"`). An
arm's result is a root of reclamation until its expression is over. See RFC-0082 ("P3.3 as
implemented"), `src/forbic/concurrency_structured_tests.zig` and
`tests/conformance/concurrency-structured.forb`.

## Structured concurrency: `Rush`, `Branch` and the tasks a frame owns (RFC-0082, P3.4)

```forbic
Fire()<transacts><suspends>:void = Block{
    Branch{ Defer{ Print("cleaned") }; Sleep(1.0); Print("never") }   # cancelled when Fire ends
    Print("fire returns")
}
Quick()<transacts><suspends>:i64 = Rush(Fetch(1, 2.0), Fetch(2, 0.5))   # 20; Fetch(1) keeps running
```

`Branch{ Statements }` and `Rush(A1, ..., An)` are sites, with the rules of the other sites:
`<suspends>`, outside every failure context and `Defer`. Neither may stand in the body of a
`Loop{}` or a `While`, where the task would belong to the visit and not to the function
(`concurrency_in_loop`); a function, an arm or a task's body in between is a frame of its own.
A `Branch` body is a task's body, as a `Spawn`'s is: it captures by value (a local `var` it names
is shared), cannot be left by
`Return` or `Break` (`return_in_task_body`), does what the code around it may, and its value is
dropped: the form yields the unit value. The task starts by hand-off and is owned by the frame
that ran the form, the function, `Fn`, arm or task body it is written in. A `Rush` is read as a
`Race` is; its first arm to complete yields, and the started arms that are not settled go on,
owned by the frame that ran the `Rush`, in arm order. `Rush` and `Branch` are standard names
and yield to the program's own declarations.

A frame's end, whether by its result, an `exit` or `cancel_exit`, and the end of each visit of a
loop's function (a call of it), first asks every task it owns
that is not settled to cancel, in the order the tasks came to it (one unit of fuel each), and
the task waits at the frame's end until they have settled; then the frame ends as it was
ending. A task asked to cancel while it waits at a frame's end only takes the flag: the end goes
on, and the task's next site yields cancelled at once (a `resume_canceled` step with no
`suspend` before it). A task the frame owns leaves its list when it settles and its slot is
free. New steps record the wait at a frame's end: a `suspend` and a `resume` at the body's
length, with the number of owned tasks and `true`. A program with a `Rush` or a `Branch` can
cancel tasks too, so its `Defer`s open at sites get landings as in P3.3. Tasks left waiting may
be branches (`"kind":"branch"`). See RFC-0082 ("P3.4 as implemented"),
`src/forbic/concurrency_branch_tests.zig` and `tests/conformance/concurrency-branch.forb`.

## Reclamation across task stacks (RFC-0082, P3.5)

```forbic
Service(N:i64)<transacts><suspends>:string = Block{
    Keep := array{N, N + 1}                      # held across every sleep: a root
    var I:i64 = 0
    Loop{ If(I >= 1000000, Break(), false); set I = I + 1; Junk := array{I, I}; Sleep(0.0) }
    "kept {Keep.Length}"                         # a million visits in bounded stores
}
T:task(string) = Spawn{ Service(1) }
```

A frame end, or a visit's, that saw another task run since the frame was pushed reclaims too, in
`digest` and `off` runs, with these roots beyond the usual ones and the scheduler's values: for
every frame of every suspended task, the registers available at the node it stands at (its site,
or the call it waits in), by the analysis that admits operands, kept per body node as the newest
available register before the node (so rooting a frame costs its available registers, not its
body); its captures and a loop's seed, and in the reference evaluator its copied parameters. A
frame waiting at its end for the tasks it owns holds only its result, and one that ends cancelled
nothing. The frames below the one that ends on the active stack are no roots: a task is restored
on an empty stack and a hand-off runs on top of its creator, so they have not run since its push
and name nothing above its marks. Such a frame reclaims above its own marks or above the sizes of
the three stores when the root ended, whichever is more, so nothing the root's registers name
ever moves. The suspended frames' captures are rewritten, and each of their marks above the
reclaiming ones becomes the number of what stays below its old place, in each store: members as
an empty span, string bytes as an empty string at that place, cells by the instances that stay.
Every switch is made outside every region, so no region is open at such a frame end. The
suspended frames, registers and parameters count in what the reclamation examined, and in the
decision of a call's frame to reclaim as it returns. Depths compare within the run of the task
on the stack: every restore begins the comparison again. A frame that saw no other task run
reclaims what it did before, and a program without tasks keeps its layout, its IR and its
capacities. The
three implementations compute this each in its own code; both machines agree on the pool after
every reclamation, and the replay works every reclamation out again. See RFC-0082 ("P3.5 as
implemented"), `src/forbic/reclaim_tests.zig` and `tests/conformance/concurrency-reclaim.forb`.

## Exits from arms (RFC-0082, P3.6)

```forbic
Abandon()<transacts><suspends>:i64 = Block{
    Sync(
        Block{ Sleep(0.0); Return(5) },          # returns from Abandon, not from the arm
        Block{ Sleep(0.0); Print("never") })     # cancelled: it was ready, not yet run
    0                                            # never reached
}
Count()<transacts><suspends>:i64 = Block{
    var N:i64 = 0
    Loop{ set N = N + 1; R := Race(Block{ Sleep(2.0); 2 }, Block{ Sleep(1.0); If(N == 3, Break(), 1) }) }
    N                                            # 3
}
```

A `Return`, or a `Break` to a `Loop{}` around the expression, in an arm of `Sync`, `Race` or
`Rush` leaves the arm: the arm's own `Defer`s run, and it ends with a pending exit, the node
`arm_exit` of its function, which commits the frame's open regions as `exit` does. An arm that
may exit is a function with metadata `exits`, the type of its pending exits: the result type of
the function a `Return` leaves, `logic` when only `Break`s leave its expression's arms, or
`tuple(i64, option(R))` with a loop state's mode when both do. Its settling abandons the
expression unless something resolved it first: the other started arms are asked to cancel, in
arm order, for every kind (a `Rush` keeps none), and no arm starts after it. When the started
arms have settled, the site yields the pending exit (`resume_exited`, at once in the start phase
or when restored) without writing its register, and its check, after the cancellation test,
tests `arm_exited` and carries the exit on where the expression stands: the macro pass writes
that exit again there (`<arm_reissue>`), so it runs the `Defer`s of that scope and leaves as far
as an exit written there would, one frame at a time. A task asked to cancel yields cancelled
instead; an arm that a `Rush` handed to its frame and that exits later only ends. An arm that
may exit runs only as an arm of a site whose check reads exits of its type: both admissions
refuse any other use of its closure, a call, an iteration or a dispatch of it, `recur` and
`self_value` in it, and an `arm_exit` anywhere else; the check's second test has a fixed shape,
and the code that carries the exit on holds no site and no node of a check. A `Return` in a
`Spawn`, `Branch` or `Defer` body inside an arm is still refused, and a `Return` in a function
an arm calls returns from that function only (Book 14:562). A program whose arms nothing leaves
keeps its IR and its capacities. See RFC-0082 ("P3.6 as implemented"),
`src/forbic/concurrency_exit_tests.zig` and `tests/conformance/concurrency-exit.forb`.

## Cancellation, `NextTick`, the interfaces of tasks and events, and the clock (RFC-0082, P3.7)

```forbic
Watcher()<transacts><suspends>:void = Block{ Defer{ Print("cleaned") }; NextTick() }
Wait(T:task(void))<transacts><suspends>:void = Block{ Defer{ Print("waiter") }; T.Await() }
Stop()<transacts><suspends>:void = Block{
    W := Spawn{ Watcher() }
    A := Spawn{ Wait(W) }
    W.Cancel()                     # W unwinds at its next site: "cleaned"
    W.Cancel()                     # safe: W is already asked
}                                  # A awaited a cancelled task: "waiter", A is cancelled too
Consume(Source:awaitable(i64))<transacts><suspends>:i64 = Source.Await()   # a handle or an event
Produce(Target:signalable(i64))<transacts>:void = Target.Signal(1)         # an event only
Now()<reads>:float = GetSimulationElapsedTime()                            # now / tick rate
```

`T.Cancel()` is a site (`task_cancel`) of a `<writes><suspends>` function: after the check of its
own task's flag it makes one cancellation request to the task of the handle and yields the unit
value at once. A request does nothing to a task that has settled or was asked already; it ends
the wait of a waiting task (its timer, its place among an event's waiters or a task's awaiters),
cancels the expression a task waits on (its started arms first, in arm order), and only flags a
task that is ready, waits at a frame's end, runs, is below on the active stack or is a committed
start waiting for its turn: such a task yields cancelled at its next primitive site. A spawned task that
ends cancelled marks its handle `canceled` (2), with no result, and asks every task awaiting it to
cancel, in the order they began to wait; an `Await` of a handle already cancelled asks the
awaiter's own task and yields cancelled at once (Q3). An arm cancelled that way, from outside its
expression, asks the task running the expression to cancel unless the expression is cancelling or
resolved; a task asked during its start phase starts no further arm, cancels its expression and
yields cancelled at once or once its arms are settled. A task can thus end cancelled in its first
run, on top of its creator, which gets what it waits for as if the task had completed there. A
program with a `Cancel` gets the landings of its `Defer`s (C37), and `landing_assigns_local`
applies to it. `NextTick()` is `Sleep(0.0)`, the next tick. `awaitable(t)` and `signalable(t)` are
one catalogue definition, `scheduled_interface`, not a class: an `upcast` takes `task(t)` to
`awaitable(t)` and `event(t)` to either without changing the value, `Await` of an awaitable is a
`task_await` that awaits a handle as a handle and an event as an event by the instance's own type,
and `Signal` of a signalable is an `event_signal`; nothing else reaches such a value. Both
admissions accept exactly these casts and operands, and the catalogue one interface of each kind
per value type; the interfaces work with type parameters as `task(T)` does. The clock is
`elapsed_time`, `now / R` in binary64, of type `float`, needing `<reads>`; root code reads 0.0.
Requests cost one unit each, also one to a task that has settled. Every request and cancellation is
replayed by `SchedulerReplay`, and both admissions refuse a forged `task_cancel`, `elapsed_time`,
cast or operand of an interface. An `elapsed_time` in a function whose declared set lacks
`reads` is refused by both admissions with the rule that refuses a `grant` there: the effect
check of state operations covers every operation that reads, source operation or not. A program
that never cancels, calls `NextTick`, uses the interfaces or reads the clock keeps its IR and its
capacities. See RFC-0082 ("P3.7 as implemented"), `src/forbic/concurrency_cancel_tests.zig` and
`tests/conformance/concurrency-cancel.forb`.

## `For` with a suspending body (RFC-0082, P3.8)

```forbic
var Steps:i64 = 0
Count()<transacts><suspends>:void = For(I:0..9, Block{ set Steps = Steps + 1; NextTick() })  # Book 14:1086
Kept()<transacts><suspends>:[]i64 = For(I:0..4, I != 2, J := I * 10, Block{ Sleep(0.1); J })  # [0,10,30,40]
Bad(Xs:[]i64)<transacts><suspends>:[]i64 = For(I:0..2, Y := Xs[I], Block{ NextTick(); Y })
                                         # suspending_for_fails at `Y := Xs[I]`
```

A `For` whose generators after the first, filters, bindings and body cannot fail may hold a site
in its body. It has no rollback region per iteration, so no region is open at the site: the
general templates of RFC-0064 (a state loop with an index, `Iterate`, whose visits are suspending
calls) lose their per-iteration `Attempt`; a binding is `Y:=(V)`, a filter is bound
(`__for_keep:=(F)`) and chooses between the rest of the iteration and nothing, both outside every
failure context; a `For` that can be left (RFC-0068) drops its `Attempt` the same way. Which
loops are so lowered the compile decides: a site whose only barriers are the regions of
iterations of general `For` calls notes those calls, through the loop functions such a region
kept from suspending, and the next compile lowers them without regions; every such loop of a
program costs one compile more together. What can fail in such an iteration is refused at the
clause or the body it stands in (`suspending_for_fails`); a site in a clause stays
`suspends_in_failure_context`. In such an iteration `Print` commits, `Spawn` hands off and `Signal`
wakes at once. A cancellation lands in the iteration that waits: its landing runs the iteration's
`Defer`s, then the checks of the loop's calls run those of the iterations around it and of the
function. The forms of RFC-0056 without filters keep their lowering: their body, a function
outside every region, could suspend before. Their filter's function, called in the condition of
an `If`, no longer inherits `suspends`, so a filtered such `For` compiles in a suspending
function and in a task's body, where it was refused; one with a site in its body is lowered as a
general `For` without regions, so its filter may not fail either. Locals are carried as by every `For`, and a local an `Fn`
shares is not (RFC-0085, S2). No operation is new; admission refuses a forged site in an
iteration's region as any site in a region. A `For` with no site keeps its IR and its capacities.
See RFC-0082 ("P3.8 as implemented"), `src/forbic/concurrency_for_tests.zig` and
`tests/conformance/concurrency-for.forb`.

## Live variables (RFC-0084, P4.1)

```forbic
var Source:i64 = 1
var live Doubled:i64 = Source * 2        # 2; follows Source
live Label:string = "source {Source}"    # never set by the program, still follows Source
var Manual:i64 = 0
set live Manual = Source + 3             # made live after initialisation
set Source = 10                          # Doubled = 20, Label = "source 10", Manual = 13
set Manual = 0                           # a plain set turns liveness off: Manual stays 0
```

A live variable is a module `var` with a guard: `var live X:T = G` declares one, `set live X = G`
attaches `G` to an existing module `var`, replacing any guard it had, and `live Y:T = G` declares
a live-only variable that no program writes (`live_assigned`). `live` is a modifier only before a
name, so `var live:i64 = 0` still declares a variable called `live`. The guard is compiled as an
anonymous function of no parameters named by its word `live`, of type `function<reads>(tuple(), T)`:
it may read and compute, but not write, build an instance, act, draw or suspend (`guard_effect`);
it captures immutable locals and parameters by value and refuses a local `var`
(`guard_local_var`). `set live` needs `<transacts>`. In P4.1 only module cells are live targets: a
local, a parameter, an immutable binding, an element or a field is `live_target`, and `set live`
in a `Defer` body that is copied more than once is `live_deferred`. (Fields became targets in
P4.2, and local `var`s in P4.8, where a guard that names one follows it: see "Live locals".)

The IR operation is `cell_live`; it builds a record, an instance of the hidden definition
`live(T)` (a header and six cells: guard, stamp, height, owner, place, origin), and links the
target cell to it. While a guard runs, every read of a mutable module cell or `var` field is
tracked, also in functions it calls and in its own failed regions; after it returns, the reads
become dependency entries stamped by a run-wide counter that no rollback takes back, so a
rollback revives the entries that were valid when its region began and drops the ones it made.
A program write of a linked cell detaches its record. After every write in a live program the
machine propagates before the next node: dirty records are evaluated by `(height, id)`, where a
record stands above every record it reads (heights capped at `live_height`), and a comparable
result equal to the target's value is not written, which gives the fixed point. Three bounds end
a run with a located error: `live_unstable` at the record evaluated more than
`live_record_evaluations` times in one propagation (the cycle detector), `live_propagation_limit`
at the writing node beyond `live_evaluations` evaluations, and `live_edge_limit` there when the
entries that must be kept would pass `live_edges`. Propagation, records and entries are undone
with a failed region.

New steps (`live_eval` before a guard frame, `live_settle` after it) record each evaluation; the
report replay (`LiveReplay`) predicts the order, the stability and the bounds and re-executes
every guard on its own cells. A live program reports its final cells, and its values object ends
with `"$live":{...}`, after `$objects` and `$scheduler`, counting records, propagations,
evaluations and entries. Reclamation does not run while a guard is tracked; a cell's link is a
reference, records reach their guards, entries are weak and are renumbered with the cells, and
the tool runs a program again in `digest` mode at `live_edge_limit`. Inspection format 29 prints
`cell_live`, `live(T)` definitions and live-only cells. See RFC-0084 ("P4.1 as implemented"),
`src/forbic/live_tests.zig` and `tests/conformance/live-variables.forb`.

## Live fields (RFC-0084, P4.2)

```forbic
var Bonus:i64 = 5
meter := class{
    var Raw:i64 = 1
    var live Total:i64 = Self.Doubled + Bonus  # reads a field declared after it
    var live Doubled:i64 = Self.Raw * 2
    live Label:string = "raw {Self.Raw}"       # live-only: no program writes it
}
M:meter = meter{ Raw := 3 }                    # Total 11, Doubled 6, Label "raw 3"
gauge := class{ var Level:i64 = 0 }
G:gauge = gauge{}
set live G.Level = Bonus + 1                   # a guard attached to a field of an instance
```

A class body may declare `var live F:T = G` (with `var<private> live F<public>` for who may
attach a guard) and the live-only `live F:T = G`. A guard names the fields of the instance as
`Self.F`. The construction gives a live field the default of `T` first (`0`, `0.0`, `false`,
`""`, an empty array, map or option, the first case of an enum, a tuple or struct of those), and
a type without one is `live_field_default`. The class's block-clause function (named `Block`, or
`class` when the class has no `Block{...}` clauses) then
begins with one `object_live(Self, F, guard)` per live field, in declaration order, before the
clauses the program wrote; a class with live fields and no clauses gets one, and superclasses
attach theirs first. Building such a class needs `<reads>` and `<writes>` besides `<allocates>`
(`construction_requires_reads`, `construction_requires_writes`). An archetype, a constructor or a
restatement that gives a live field a value is `live_assigned`, as is `set` or `set live` of a
live-only field. `set live E.F = G` evaluates `E` once and attaches `G` to the `var` field `F`; it
needs `<transacts>` and the field's write access, and a plain `set E.F` detaches.

The IR adds `object_live {object, field, guard}`, `Field.live_only` (a live-only field is not
`var`, but its reads are dependencies) and `RuntimeFunction.clauses_of`, which marks the
block-clause function of a class with live fields. Both admissions refuse a live-only field as
the target of a program write, or of an `object_live` anywhere but in its class's own clauses on
their `Self` parameter, and a call of such clauses with anything but the latest construction
before it (or one upcast of it), a clauses function that recurs, and every other way to reach
one. A
record's owner is the target's instance and its place the field. A field's link is part of the
instance's cell for the journal and for reclamation, and a reclamation keeps a record while its
target or any cell it reads is kept (RFC-0084 C24), so the records it forgets can never be
evaluated again and every trace mode charges the same. Inspection format 29 prints
`object_live`, `"live_only":true` on fields and the `function_clauses` table. See RFC-0084
("P4.2 as implemented"), `src/forbic/live_field_tests.zig` and
`tests/conformance/live-fields.forb`.

## Functions as types (RFC-0084, P4.3)

```forbic
var Mult:i64 = 2
Multiply(Arg:i64)<reads>:i64 = Arg * Mult
var Scaled:Multiply = 10                 # Multiply(10) = 20; the raw value 10 is kept
set Scaled = 4                           # assigns the raw value: 8
set Mult = 3                             # 12
clamp := class{ var High:i64 = 100; Apply(V:i64)<reads>:i64 = If(V > Self.High, Self.High, V) }
Bounds:clamp = clamp{}
var Base->Health:Bounds.Apply = 50       # Base is the raw cell, Health follows Bounds.Apply(Base)
set Health = 120                         # Base 120, Health 100
```

A declaration whose type is a function's name, or a method reached through a module binding and
its fields (`Bounds.Apply`), declares two variables: a raw one of the function's parameter type,
which holds what is assigned, and a live-only one of its result type, which follows the function
of the raw one. The function has one parameter and no `<decides>`, `<suspends>`, `<writes>` or
`<allocates>`; anything else in that place (`F(Mult)`, a value, a generic or overloaded function)
is `live_type_form`, and a missing initialiser `live_initializer`. `In->Out:F = E` names the raw
variable `In`; `X:F = E` keeps it hidden, under a name of the library block (`__raw0`, ...) that no
program can reach (a field the program declares may not start `__raw`). With `var`, the raw variable is an ordinary `var`, and `set Out = V`,
`Set(Out, V)` and `set Out += D` (which reads `Out`) assign it, checked against `Out`'s access;
without `var` neither is assigned (`live_assigned`). With `live`, the initialiser is the raw
variable's guard until its first assignment. The same forms declare fields in a class body: the
raw field, then the live-only field, whose guard the class's clauses attach (P4.2). A local
declaration with a function as its type is `live_target`.

There is no new IR: the raw variable is a cell or field declared as any is, and the other is a
live-only cell (`cell_live` with `initialize`) or field (`object_live` in the clauses) whose guard
is a function named by a library `Fn` word, `Fn{ F(raw) }`, which reads the raw value and, through
`F`, what `F` reads. The macro pass marks each declaration whose type might be a function, and the
parser compiles that guard only when the type names one; a program without such a declaration
keeps its tokens, and one whose marked types name types keeps its IR. See RFC-0084 ("P4.3 as
implemented"), `src/forbic/live_type_tests.zig` and `tests/conformance/live-function-types.forb`.

## Reactions (RFC-0084, P4.4)

```forbic
var Health:i64 = 100
var IsDead:logic = false
var Hits:i64 = 0
Dead:task(logic) = Upon(Health <= 0, Set(IsDead, true))  # fires once, the first time it holds
Counter:task(void) = When(Health, Set(Hits, Hits + 1))  # runs now, then after every write
set Health = 0                                          # IsDead true, Hits 2
Tried:logic = Attempt(Block{ set Health = 5; Require[Health < 0]; true }, false)  # tells no one
```

`When(G, B)` evaluates its guard `G` at once and again after every write of a cell or field the
guard read, and runs the body `B` whenever the guard succeeds; it then reads the guard again and
waits. `Upon(G, B)` runs `B` once, the first time `G` succeeds, and its `task(T)` completes with
`B`'s result. A guard of type `logic` succeeds when it is `true`; any other guard when it does
not fail (`G[]`, `X?`, `Require[...]`). A guard reads at most (`guard_effect`, `guard_local_var`);
a body has its creator's heap effects, cannot suspend (`reaction_body_suspends`) and cannot
`Return` or `Break` (`return_in_task_body`), but it may `Spawn`. Making a reaction needs
`<reads>` and `<allocates>`.

A write notifies the reactions whose guards read it, each once, in the order of their first
trigger. They are delivered when nothing is open: at the end of a write outside every region,
when the outermost region commits (a region that fails takes back its notifications, and the
reactions it made never start), after a drain, and after a body. Each delivery reads the guard
again; a body that writes what other guards read is followed by their deliveries in the same
loop, and a loop of more than `deliveries` ends the run with `reaction_limit`. The IR adds
`reaction {kind, guard, body}`, the task kinds `upon` and `when` with wait kind `guard`, and the
steps `observe`, `deliver` and `fire`; a reaction left waiting is listed at quiescence. See
RFC-0084 ("P4.4 as implemented"), `src/forbic/reaction_tests.zig` and
`tests/conformance/live-reactions.forb`.

## Batches (RFC-0084, P4.5)

```forbic
var X:i64 = 0
var Notices:i64 = 0
Watch:task(void) = When(X, Set(Notices, Notices + 1))   # Notices 1
B:i64 = Batch{ set X = 2; set X += 5; Notices }          # B 1: nothing delivered inside
After:i64 = Notices                                      # 2: one delivery, after the batch
```

`Batch{ Statements }` runs its statements at once, as `Block{...}` does, and yields the last
one's value. What their writes notify is held until the outermost batch has ended: each
reaction notified is then delivered once, in the order of its first notification, and sees the
final state (Book 15:552). Batches nest; a batch in a region delivers when the outermost region
commits, or nothing if it fails. The body has the heap effects of the code around it, cannot
suspend (`batch_suspends`), cannot `Return` or `Break` out of itself (`return_in_task_body`)
and cannot assign a parameter or an immutable local around it (`arm_assigns_local`; a local
`var` it assigns is shared, RFC-0085 I5). A task it hands off runs under
the batch until it first waits; when it runs again it is on its own. A program whose only live
form is a `Batch` is not live: it reports as before. The IR adds `batch`, a call of the body's
closure; see RFC-0084 ("P4.5 as implemented"), `src/forbic/batch_tests.zig` and
`tests/conformance/live-batch.forb`.

## Await of a guard (RFC-0084, P4.6)

```forbic
gauge := class{ var Level:i64 = 0 }
DoubleWhenFull(Source:gauge, Target:gauge)<transacts><suspends>:void = Block{
    Await(Source.Level > 10)            # waits until the source passes 10
    set Target.Level = Source.Level * 2
    Target.Level
}
Second()<transacts><suspends>:i64 = Await(Items[1] * 10)  # a guard's value, when it holds
```

`Await(G)` without a receiver is a site of a `<suspends>` function: it evaluates its guard `G`
with tracking, and when the guard succeeds (a `logic` guard that is `true`, any other that does
not fail) the site yields its value and the task goes on. Otherwise the task waits on its guard,
listed with the wait `guard` if the run ends. A write of a cell or field the guard read wakes
the task: it joins the ready queue, behind what is ready already, and when it runs it evaluates
the guard again where it stands, so it goes on only if the guard holds on the state as it is
then, and waits again if not. A request to cancel ends the wait, and the task yields cancelled
there. The guard reads at most (`guard_effect`, `guard_local_var`); `Await` needs `<reads>` and
`<suspends>` and stands nowhere a site may not (`call_requires_suspends`,
`suspends_in_failure_context`, `reaction_body_suspends`). The IR adds `await_guard`, a primitive
site with its check; `T.Await()` of a handle is unchanged. See RFC-0084 ("P4.6 as implemented"),
`src/forbic/await_tests.zig` and `tests/conformance/live-await.forb`.

## Cancelling reactions (RFC-0084, P4.7)

```forbic
var X:i64 = 0
var Y:i64 = 0
Watch:task(i64) = Upon(X > 5, Set(Y, X))
StopObserving()<transacts><suspends>:void = Watch.Cancel()
S:task(void) = Spawn{ StopObserving() }   # runs by hand-off: Watch is cancelled at once
set X = 10                                # notifies nothing: Y stays 0 (Book 15:532)
```

`T.Cancel()` of an `Upon` or a `When` (RFC-0082's `task_cancel`, a site) is a request to the
reaction's task. A reaction waiting on its guard settles cancelled at once: its dependencies go,
so no later write reaches it, and a notification already pending for it is delivered as one
that does nothing. A reaction that is firing (only a task its body handed off to can ask it,
since a body cannot hold a site) is flagged: its body runs to its end, and then an `Upon`
completes with the body's result and a `When` settles cancelled instead of registering again. A
reaction made in a region that committed and whose start is still waiting in the drain settles
cancelled at once, and its start does nothing: its guard is never evaluated. A cancelled
reaction's handle says `canceled`, and every task that awaits it is cancelled (RFC-0082 Q3).
A cancel of a reaction that has settled costs a unit and does nothing. P4.7 adds no IR: it
replaces P3.7's refusal `reaction_cancel` with this. See RFC-0084 ("P4.7 as implemented"),
`src/forbic/reaction_cancel_tests.zig` and `tests/conformance/live-cancel.forb`.

## Sticky and subscribable events (RFC-0082, P3.9)

```forbic
Ready:sticky_event(string) = sticky_event(string){}
Score:subscribable_event(i64) = subscribable_event(i64){}
Show(N:i64)<transacts>:void = Print("score {N}")
Shown:cancelable = Score.Subscribe(Show)       # at the root too: not a site
Play()<transacts><suspends>:void = Block{
    Ready.Signal("go")                          # latched
    V := Ready.Await()                          # "go" at once: no wait, no switch
    Score.Signal(3)                             # Show(3) runs now, before Signal returns
    Undo := Attempt(Block{ Shown.Cancel(); Require[false]; 1 }, 0)   # taken back
    Score.Signal(4)                             # Show(4) again
}
```

A `sticky_event(t)` and a `subscribable_event(t)` are kinds of the catalogue's event definition,
so every rule of `event(t)` holds for them; `cancelable` is a definition of its own. A sticky
event's `Signal` latches its value and wakes its waiters; inside a region the whole `Signal` is
held and carried out at the outermost commit, or dropped. Its `Await` checks its task's flag, then
yields the latched value at once if the latch is set, and otherwise waits as on an event; a latch
never clears. A sticky event is an `awaitable(t)` and a `signalable(t)`; a subscribable one only an
`awaitable(t)`, since its `Signal` needs `<transacts>`. `E.Subscribe(F)` (`event_subscribe`, needing
`<writes><allocates>`) builds a `cancelable` and appends it to the event's list; `F` is a function
value of exactly `function<transacts>(tuple(t), void)`. `C.Cancel()` (`subscription_cancel`,
`<writes>`) takes an active subscription off its list, keeping its link to the one after it, and
does nothing to one already cancelled. Both are writes of hidden cells that a region journals like
a field's, so a region that fails takes them back, with the `cancelable` it built. A subscribable
event's `Signal` is `event_signal` (its waiters) and then `event_notify`, which calls each
subscription active when the `Signal` began and still active at its turn, in the order made, with
the value, as ordinary calls on top of the signalling frame (or as calls of the root); a
subscription made during the `Signal` is first called by the next one. Each subscription reached
costs one unit of fuel; the callbacks' returns leave no step, the node one `value` step after the
last, and the replay chooses every call from its own cells. A program that names none of the three
types keeps its IR, catalogue and reports. See RFC-0082 ("P3.9: sticky and subscribable events"),
`src/forbic/concurrency_subscription_tests.zig` and `tests/conformance/concurrency-events.forb`.

## Transparent functions (RFC-0085, I7)

```forbic
Next<public>(X:i64)<computes> := X + 1
Positive(X:i64)<computes><decides> := Block{ Require[X > 0]; X }
Pair(X:i64)<computes> := tuple{Next(X), "{X}"}
```

`Name(Parameters)<effects> := Body` is a function whose result type is the type of its body,
compiled without an expected type. The effect is written, as on every function (V10); a
transparent body names neither the function, called or as a value (`transparent_recursion`),
nor `Return` (`return_type_required`), whose operand would need the type. Methods of classes
and interfaces and generic functions are not transparent (`transparent_method`,
`transparent_generic`, V11); an extension method may be. `Name<constructor>(...) := Class{...}`
is a constructor function as before. The function is otherwise an ordinary one: its code entry
is the same as with the result type written, but for `transparent`, which no execution and
neither admission reads, and which inspection lists under `function_transparent` (format 30)
for the evolution checks of P5 (V12). A body that only names parameters stays a template and
has no entry. See [RFC-0085](rfcs/0085-closures-and-unreleased-forms.md) and
`tests/conformance/transparent-functions.forb`.

## Enumerator qualification (RFC-0085, I10)

```forbic
Start:i64 = 0
game_state := enum{ (game_state:)Start, Playing }
keyword_enum := enum{ (keyword_enum:)set, (keyword_enum:)For, (keyword_enum:)keyword_enum, Regular }
S:game_state = (game_state:)Start
```

In the body of `e := enum{...}`, `(e:)Name` declares the enumerator `Name`, which may be any
word, the enum's own name included (the Book's 09:507 and 09:547); the qualifier names the enum
declared (`invalid_qualifier` otherwise). In an expression, `(e:)Name` is `e.Name` where `e` is
an enum in reach (V20); a module of that name is a module path as before (RFC-0083). The token
pass lets a reserved word follow a qualifier only when the program declares an enum of that
name. Unqualified, the same words stay accepted as enumerators (V19). The forms lower to the
enumerator nodes of the unqualified ones. See `tests/conformance/enumerator-qualification.forb`.

## Automatic qualification (RFC-0085, I11)

`forbic qualify FILE [--bundle]` prints the program with every identifier its author wrote in
its fully qualified form (the Book's 16:789), in the layout it was written in, and runs nothing:

```forbic
(/:)ProcessValue((local:)Input:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)Input * 2
(/:)player_class := class{ var (/player_class:)Health:(/Verse.org/Verse:)float = 100.0 }
```

A definition of a file or of a module nested in one is `(/Path:)Name`, where `Path` is the file's
path in its bundle without `.forb`, then each nested module (`/` for a program without a
bundle, V18); a field, method or enumerator is `(/Path/type:)Name`; a parameter, local or
nested function is `(local:)Name`; a built-in type or standard function is `(/Verse.org/Verse:)Name`. A bundle's files
each begin with a line `# path`. The forms come from a table the compiler fills only when the
host asks for it (`Workspace.qualify`): for each identifier, the definition it resolved to. A
compile without the flag notes nothing, and the program, its IR and every report are the same
with it. A qualifier the author wrote is replaced by the form of its name; text a macro
generated is not printed. The output is not source: path qualifiers stay refused (Q6). Members
of built-in types (`Length`, standard methods), named arguments, `Self`, the getter and setter
names of accessors and the paths of `using` are printed as written. `qualify.verify` checks
that each printed form, read again under the scope rules where it stands, names the definition
it was computed from; the tests check it over every conformance fixture. See
`tests/conformance/qualification.forb` and its `-qualified.txt`.

## Prediction (RFC-0085, I12)

```forbic
CheckPlayerStatus()<reads><predicts>:i64 = Health
Apply(F:function<computes><predicts>(tuple(i64), i64), X:i64)<computes><predicts>:i64 = F(X)
shape := class<computes><predicts>{ Size:i64 = 2 }
```

`<predicts>` stands beside a heap effect on functions, methods, `Fn`, function types and
classes. It gives up the effect `dictates` (`EffectDetail.predicts`, `EffectSet.dictates`),
which every other function has: fewer effects is the subtype, so a predicting function is a
value of a dictating type, widened by an `upcast`, never the reverse. A predicting function
runs only what predicts (`call_requires_dictates`): its calls, invocations, loops, `Iterate`,
method calls, parameter defaults, tasks and arms; the live forms `set live`, `Upon`, `When`,
`Await(G)` and `Batch{}` dictate (`form_requires_dictates`), and so does the `Signal` of a
subscribable event, whose callbacks have a dictating type. A construction in predicting code
needs block clauses and field defaults that predict (`construction_requires_dictates`); a class
that says `<predicts>` has them predict where it is declared. An override predicts where its
slot does (`override_widens_dictates`). Closures and the functions macros write inherit the
bit with the heap effects. Natives that only compute predict, as does `Print` of a string; the
draws dictate (V22, `native.dictates`, a host entry may not say `predicts` otherwise); the root
dictates (V23). Both admissions, and the replay, which admits the program again, refuse in a
function without `dictates` every node that runs dictating code and every live form (rule 9).
Nothing runs differently: inspection format 31 lists the bit as `predicts` in the effect lists
of format 26, and a program without the specifier has no bit set. See
`tests/conformance/predicts.forb`.

## Accessors (RFC-0085, I8)

```forbic
entity := class{
    var Health<getter(GetHealth)><setter(SetHealth)>:i64 = external{}
    var InternalHealth:i64 = 100
    GetHealth(:accessor)<reads>:i64 = Self.InternalHealth
    SetHealth(:accessor, NewValue:i64)<transacts>:void = If(NewValue >= 0 and NewValue <= 100, Block{ set Self.InternalHealth = NewValue; 0 }, 0)
}
```

A `var` field of a class or an interface with `<getter(G)><setter(S)>` and `= external{}` has
no cell: it is no catalogue field, so layouts, reports and both machines know only the other
fields. `G` and `S` are methods with bodies of the same class or interface, `G(:accessor):T`
and `S(:accessor, V:T):void`, the `accessor` parameter unnamed (`accessor_signature`), and
neither fails nor suspends (`accessor_effect`). `E.F` is a call of `G` and `set E.F = V` a call
of `S`, each through the method's slot (`method_value` and `invoke`, as an interface field's
accessors are), with the one value of the standard type `accessor`, an empty struct named where
the program first writes the word; `set E.F op= D` and paths through the field read through the
getter once and hand the whole value to the setter. A read needs `<reads>` and the getter's
effects, a `set` `<writes>` and the setter's. Who may read and assign is the field's access; the
methods run on its authority. No source expression makes an `accessor` (`accessor_construction`),
so the getter and setter run only through the field. The field is never restated, overridden,
declared again by a member of its name, or stood in for (`accessor_override`); it is no live
target (`live_target`, `accessor_live`) and no archetype names it (`accessor_archetype`). The
other refusals are `accessor_pair`, `accessor_mutable` and `accessor_default`. A guard that reads
the field tracks what the getter reads; a getter that reads its own field ends at the call depth.
A field with accessors and no default (I9) has no cell either: every archetype of a class that
has it gives it a value (`missing_field` otherwise, and a `<concrete>` class has none), and
`C{F := V, ...}` computes its values in the order written, then the defaults of the cells it
omits, builds the instance with one `object_new`, runs the block clauses, and then calls the
setter of each such field in declaration order (the superclass's first) through its slot, as
`set` does; the construction needs each setter's effects, and a stated class effect bounds them. A constructor function's archetype
does the same, and delegation lends the values it gives these fields as it lends its cells'.
No IR is new. See [RFC-0085](rfcs/0085-closures-and-unreleased-forms.md) ("I8 as
implemented", "I9 as implemented"), `src/forbic/accessor_tests.zig`,
`src/forbic/accessor_init_tests.zig`, `tests/conformance/accessors.forb` and
`tests/conformance/accessor-initialisation.forb`.

## Shared locals (RFC-0085, I1 to I6 and I13)

```forbic
Total(Xs:[]i64)<transacts>:i64 = Block{
    var Sum:i64 = 0
    Add:function<transacts>(tuple(i64), void) = Fn(X:i64)<transacts>:void{ Set(Sum, Sum + X) }
    For(Y:Xs, Add(Y))
    Sum
}
```

**Which locals.** A local `var` that any closure names is shared, and the closure refers to the
variable itself; immutable locals, parameters, explicit captures `Fn[C:T = X]` and a `var` that no
closure names stay as they are (RFC-0085 Q1, S1e, I13). In full, a local `var` is **shared**
when, after its declaration and within its scope, a nested function names it (S1a, see "Nested
functions"), or any other closure form names it (S1e): an `Fn` without a `[...]` list, a task
body (`Spawn{}`, `Branch{}`), an arm of `Sync`, `Race` or `Rush`, an `Upon` or `When` body or a
`Batch{}` body, directly or through the captures of the closures around it, whether or not
anything assigns it; or a landing assigns it (a landing that only reads a local reads it at its
site, which is the value the cancellation would see); and the assignments (S1d) of those forms (`Set(X, E)`,
`set X = E`, `set X op= E`, a path assignment `set X[I] = E` or `set X.F = E`) need no rule of their
own. A guard that names it shares it too (S1b). A name after a dot, a label and a name the
closure declares itself name nothing. The bodies of `For`, `While`, `Loop{}` and `First` and the
inline copies of a `Defer` are not closure forms: the macro pass writes them as functions, but
their bodies are the code around them. What a closure form captured for a parameter, an
immutable local or a name of an explicit `Fn[...]` list stays a copy, and assigning it is refused
as before (`not_mutable`, `arm_assigns_local`).

**What a shared local is.** A variable cell `ref(T)`: its declaration is `ref_new` of the initial
value, a read of its name is `ref_get` and an assignment `ref_set`, which yields the value
written, in the function that declares it and in every closure that names it, each of which
captures the cell (S2). So a closure's writes are seen by the code around it, by other closures
and by tasks that captured them. Every execution of the declaration makes a new cell: each call,
each visit of a loop whose body declares it. `ref(T)` is a definition of its own, not a class: no
class operation, cast through `any`, `instance_of`, comparison or map key reaches one, and both
admissions and the replay refuse IR that tries (RFC-0085, F1 to F17). A cell takes two object
cells; `ref_new` costs two units of fuel, `ref_get` and `ref_set` one.

**Lifetime.** A cell lives while anything reaches it: a register of a live or suspended frame, a
capture span, another cell, a scheduler-held value (a pending spawn's closure, a reaction's
body), and is reclaimed as an instance is (see "Member reclamation"). A closure that outlives the
frame keeps the cell; one that is dropped frees it. A report prints a cell as `{"$ref":N}`,
numbered among the listed cells in creation order, and lists each reachable cell once under
`"$refs"`, after `$objects`, so every trace mode reports alike. Inspection format 32 prints the
definition and the three operations.

**Rollback, effects and loops.** A write is journalled like a field's and undone with a region
that fails; a cell made in such a region is forgotten with it, with the closures and pending
starts that hold it (S4). Reading a shared local needs `<reads>` wherever it is read
(`local_read_requires_reads`, S6), a compound or path assignment too; writing it needs
`<writes>`, declaring it `<writes>` as for every local `var`; making the cell needs nothing
more. No loop carries a shared local (`For`, `While`, `Loop{}`): its body reaches the cell.

**What stays a copy.** An immutable local or a parameter keeps RFC-0054's capture by value, and so
does an explicit capture `Fn[C:T = X]`, which reads `X` where the `Fn` is built; a `var` that no
closure names is a plain local with versions, never a cell. So `Snap()` in `closures.forb` is 51,
as the Book's rule gives (it was 2 through I14, when an `Fn` that only read a local took a
snapshot, RFC-0054). Programs that name no local `var` in any closure compile to the IR, the
capacities, the compile count and the reports they had; the programs that do change are listed in
[RFC-0085, I13 as implemented](rfcs/0085-closures-and-unreleased-forms.md#i13-as-implemented).
Reading the local in a closure needs `<reads>` though nothing assigns it (the Book's rule for any
`var`): a function whose closure names a local `var` and declares no `<reads>` is refused at the
name (`local_read_requires_reads`).

**Tasks.** No region crosses a site, so every write of a cell before a switch is committed, and
a task that runs next sees it, in schedule order (S5). A task that outlives its creator keeps the
cell through its saved frame; a `Spawn` held in a region that fails is dropped with what the
region wrote and made; a cancelled task's later writes simply do not happen, and a landing that
assigns a local writes its cell.

**Guards.** A guard may name a local `var`, directly or through what a closure around it captured:
the local is then shared and the guard follows its cell (live locals, I14, below; before I14 these
were `guard_local_var` and `guard_capture_var`, Q10). A guard that calls a closure or a nested function that reads a cell depends on the cell.

**How the compiler decides.** It learns that a local is shared from a use after its
declaration: it notes the declaration and compiles the program again, so a program that shares
takes one compile more (all the names of the first compile are noted together), and a share found
only in a landing one more after the compile that finds the landings (the second wave). The scan
that gives a closure its captures notes the local it names (`captureFreeNames`, S1e);
`Workspace.share_names` turns that rule off, for the tests that show what a program meant before
Q1 and for the migration list.

**Checked together (I6).** A randomised oracle composes `Fn`s, nested functions with defaults,
overloads and recursion, task bodies, `Sync` and `Race` arms, landings, `When` and `Upon` bodies,
`Batch{}` bodies, loops whose visits fail and closures held in module `var`s and tuples over the
locals of one function, against a plain model of the locals and of RFC-0082's scheduler, on both
machines in all three trace modes, with the replay of every digest run giving the stored report.
The program profile measures thousands of shared locals, closures nested hundreds deep, a
fan-out of 60,000 tasks over one cell and cells made and dropped across 400,000 switches. See
`tests/conformance/shared-locals.forb`, `shared-locals-tasks.forb` and
`closures-complete.forb`, and, for the one rule of Q1 (I13), `tests/conformance/capture-rule.forb`.

## Live locals (RFC-0085, I14; RFC-0084, P4.8)

```forbic
StopObserving()<transacts><suspends>:void = Block{    # Book 15:533
    var X:i64 = 0
    var Y:i64 = 0
    Watch := Upon(X > 5, Set(Y, X))    # the guard names X: X is shared; the body assigns Y
    Watch.Cancel()
    set X = 10                         # Y remains 0
    Set(Seen, Y)
}
Chain(V:i64)<transacts>:i64 = Block{ var A:i64 = 1; var live B:i64 = A + 1; set A = V; B }   # V + 1
```

A guard (of `var live`, `set live`, `Upon`, `When` or `Await`) that names a local `var`,
directly, through a loop's function or through the captures of the closures around it, shares
the local (S1b): the guard captures its variable cell and reads it with `ref_get`, so it depends
on the local and is evaluated again when it is written. `set live X = G` on a local `var` and a
local `var live X:T = G` make the local shared too (S1c) and attach a record to its cell
(`object_live` at field 0, the cell its owner): `var live` makes the cell with the default of
`T`, which the guard's establishing write replaces (`live_local_default` for a type without one,
as for a live field). Everything else is RFC-0084's: a plain `set` of the local detaches it,
propagation runs to a fixed point, a failed region takes back the record, the link and the
value, and the cell and its record live while anything reaches them (a closure the frame handed
on, a reaction, the entries of what its guard reads), so a `When` on a local of a function that
has returned keeps running, and a `var live` local of such a function whose guard reads a module
`var` is evaluated at every write of it: `n` calls cost `n + n(n+1)/2` evaluations, each charged
as fuel. Dropping such a record would change what a program observes (its guard can fail), so it
stays (I14-D6; RFC-0085, "Amendment: w15"). Both need `<transacts>`. A parameter, an immutable local, an
explicit capture, a live-only local (`live Y:T = G` in a block) and a local declared with a
function as its type (the forms of P4.3) are still no live target (`live_target`). An explicit capture `Fn[C:T = X]` is a value,
and a guard that names it reads the copy. A guard in a loop's body that names a local of the
declaring function follows the local now, where before it followed a copy, and so does every read-only `Fn` of that
local in the function, where before it took a snapshot (I14-D3). No IR
operation, step or capacity is new; admission takes `object_live` on a `ref(T)` at field 0 only,
with a guard of type `T`. See RFC-0085 ("I14 as implemented"), `src/forbic/live_local_tests.zig`
and `tests/conformance/live-locals.forb`.

## Weak maps (RFC-0087, P5.1)

```forbic
Get(W:weak_map(string, i64), K:string)<computes>:i64 = Attempt(W[K], -1)
Tally()<transacts>:i64 = Block{
    var W:weak_map(string, i64) = map{"a" => 1}
    set W["b"] = 2
    Get(W, "a") + Get(W, "b")
}
```

`weak_map(K, V)` is a map that can only be looked up and set one key at a time (the Book's
03:1090). `K` is comparable (`weak_map_key`). `W[K]`, `Lookup(W, K)`, `set W[K] = V` and the
nested and compound updates of a map work on it, as `map_lookup` and `map_set`; `map{...}` where
a `weak_map` is expected is built at its type, keys checked as for a map; a `map(K, V)` value
converts to `weak_map(K, V)` by an `upcast` that changes only its type, and nothing converts
back. `Length`, `For`, `==`, `!=`, a `comparable` type argument, `ConcatenateMaps`, `Without`,
use as a map key and a conversion to a map are `weak_map_operation` (03:1112, 03:1133). The
value is a map's aggregate tagged with the `weak_map` type, so a value held as `any` is found
only as a `weak_map`; it costs what the map costs and prints as a map. The arms of an `If` join
exactly, a map and a `weak_map` not at all (D8, Q7). The name `weak_map` yields to a
declaration of it as `task` does. A top-level `var` of a `weak_map` type is an ordinary cell, but
for a session cell and a persistent cell (below). Both admissions accept the lookup, the update and the
literal of a `weak_map` and the `upcast` from its map, and refuse every other map operation on
it; inspection format 36 prints the definition. See
[RFC-0087](rfcs/0087-persistence.md) "P5.1 as implemented" and
`tests/conformance/weak-maps.forb`.

## Session cells (RFC-0087, P5.4)

```forbic
var GlobalCounter:weak_map(session, i64) = map{}
IncrementCounter()<reads><writes>:i64 = Block{
    CurrentValue := Attempt(GlobalCounter[GetSession()], 0)
    set GlobalCounter[GetSession()] = CurrentValue + 1
    CurrentValue + 1
}
```

`session` is a type with one value per run, which `GetSession()` gives (`<reads>`, the Book's
16:620): the `grant` node of kind `session`, no name and the type `grant(session)`, the
enumeration of index 0, printed `{"$session":0}`. It is comparable and a value like any other, but
no cast reaches or leaves it, as for handles. A module `var` of type `weak_map(session, V)` is a
**session cell**, a keyed cell: its initialiser is `map{}` (`weak_map_initializer`), and it is
named only as `X[K]` and `set X[K] = V` and the nested and compound updates of an entry; every
other use (a read, `set X = ...`, `Set`, an argument, `live`) is `weak_map_whole` (03:1144). The
declaration is one `weak_init` at the root, outside every region, and the cell's binding; a
lookup is a `weak_get` of `option(V)` unwrapped as `X?` is (a failure context, `<reads>`); an
update a `weak_set`, a program write of the cell (`<writes>`) that builds its map as `map_set`
does, journalled and rolled back with its regions, and in a live program propagated; a guard's
lookup is a tracked read of the whole cell. A report shows the cell's final value, from the final
cells every program with a keyed cell records. Both admissions derive `keyed` from the cell's
type and refuse a whole operation of a keyed cell, a `weak_*` of an ordinary one, a second or
misplaced `weak_init` and a session `grant` with a name; the replay rebuilds every map from its
own cells. A `weak_map` of another key, and a local or field of a keyed type, stay ordinary.
Inspection format 43 prints them. See [RFC-0087](rfcs/0087-persistence.md) "P5.4 as
implemented" and `tests/conformance/weak-maps-session.forb`.

## Persistent cells (RFC-0087, P5.5)

```forbic
player_stats<public> := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
var Stats<public>:weak_map(persistent_key, player_stats) = map{}
AddExperience(Key:persistent_key, Points:i64)<reads><writes>:i64 = Block{
    Current := Attempt(Stats[Key], player_stats{})
    set Stats[Key] = player_stats{Level := Current.Level, Experience := Current.Experience + Points}
    Points
}
Main()<transacts><decides>:i64 = Block{
    K := GetPersistentKey["alice"]
    AddExperience(K, 10)
    Stats[K].Experience
}
```

`persistent_key` is the type of the keys the host grants by name (`--key alice`): the `grant`
node of kind `key`, an `option(grant(key))` that `GetPersistentKey[Name]` unwraps in a failure
context (`<reads>`, the first key of the name). A key is comparable and a value like any other, is
printed `{"$key":"alice"}`, and, as a handle, is made by nothing but the `grant`. A module `var`
of type `weak_map(persistent_key, V)` is a **persistent cell**, a keyed cell like a session cell
with a value type that is persistable (`weak_map_value`). Where it is declared (one `weak_init` at
the root) it is **loaded**: for each key grant in order the run asks for one input entry of kind
`load` (the request is the cell and the grant, the answer the entry's text in the store, or its
end), and the present entries are decoded as `V` as `FromJson` decodes; a stored text that is no
value of the type ends the run at the cell with `load_invalid`. Every `set X[K] = V` is also an
**action** on the store channel, `{"cell":":Stats","key":"alice","value":TEXT}` with `ToJson`'s text of the
new value, held by the innermost region, committed in program order with every other action and
dropped with a region that fails.

A host run with `--state DIR` keeps a **store** in `DIR/store/`: content-addressed objects (the
entries' texts and the schema), generations (a canonical manifest of `(cell, key, object)`, named
by its hash) and `active`, the one file replaced. The journal's header names the generation the
run started from; the entries its cells load are read and checked first (`store_failed`); the
loads and the actions are in the journal, sealed with the output of their region; and the next
generation is published from the durable prefix at the run's end, in the processing of a finished
journal and by `--abandon`, objects first and `active` last, so that publishing again after a crash
writes the same files. Without `--state` the store is empty and nothing is saved; `check` and the
goldens run persistent programs so. `forbic store show DIR` prints the active generation.
See [RFC-0087](rfcs/0087-persistence.md) "P5.5 as implemented" and
`tests/conformance/persistence.forb`.

**Recovery of a store (P5.7).** Each publication appends and syncs a journal record
`published {generation, through}` (kind 6): the generation it made and the number of sealed actions
it covers. The next publication builds on the last record's generation with the store actions
sealed after it, so a journal's publications form a chain from its header's base, and each record
is accepted only if it names exactly the generation its publication makes, worked out in memory
from the base and the journal (a forged one is `store_failed`; one whose `through` is not the
sealed actions, or no later than the record before, ends the journal like a torn record). The host
publishes at a run's end, when it processes a finished journal, when it abandons one (then
`abandoned`), and before a resumed run starts again; a crash between a publication's files and its
record is repaired by publishing again, which makes the same generation. A resumed run is served its
sealed loads from the journal and reads from the store only the entries of the loads past the cut,
from the generation it started from, whatever was published since (R8). An unfinished journal is
`run_unfinished` without `--resume` or `--abandon` (R10). Where a crash kept a record and lost the
replacement of `active` before it, or the generation `active` names, or an object the chain's
publications wrote (a file system that does not order its metadata), `active` is behind on the
chain: the next publication, and the next run on the rotated journal, write the chain's
generations and their objects again and make `active` its last. The header's schema is trusted no
more than its program: a resumed run's must be its program's, and a publication first requires
the object it names to be a schema; a header's tick rate outside the scheduler's range is a header
this build cannot read. Journals of programs without a persistent cell are unchanged. See [RFC-0087](rfcs/0087-persistence.md) "P5.7 as implemented"
and `tests/conformance/persistence-recovery.state`.

**Schema compatibility (P5.6).** Each generation keeps the schema of the program that published
it (`persist_schema.zig`): canonical JSON of the persistent cells (store name, key kind, value
type) and of each type they reach, once, in a flat table (primitives, `array`, `option`, `map`,
`tuple`, and each persistable struct, class or enum by package and name with its fields, their
defaults as the text `ToJson` writes, or its cases and openness). Before a journaled run of a
program with a persistent cell, the host checks the schema of the generation it starts from
against the program's, a pure function of the two texts, and refuses an incompatible program with
one `schema_incompatible` line per refusal, located at the declaration it names, before the store
is touched: every stored cell stays, with its key; a class keeps its fields in order with their
types and defaults, and adds fields with defaults only; a struct and a closed enum never change; an
open enum stays open and adds cases after its old ones; structural types keep their shape. A
downgrade is refused by the same rules, and a run that saves nothing still leaves its schema when
it differs from its base's, so the defaults it read are kept. `forbic check FILE --state DIR` runs the check without the
lock and without running the program. A store written by P5.5 (`"schema":0`, no types) is checked
for its cells only; the load's decode (`load_invalid`) stays behind the check. See
[RFC-0087](rfcs/0087-persistence.md) "P5.6 as implemented" and
`tests/conformance/schema-evolution.forb`.

## Persistable types (RFC-0087, P5.2)

```forbic
difficulty := enum<persistable><closed>{Easy, Normal, Hard}
stats := struct<persistable>{Level:i64 = 1, Experience:i64 = 0}
profile := class<final><persistable>{
    Title:string = ""
    Mode:difficulty = difficulty.Normal
    Stats:stats = stats{Level := 5}
}
```

`<persistable>` marks a struct, a `<final>` class or an enum whose values can be saved (the
Book's 17:60). Its fields are of persistable types: `logic`, `i64`, `float`, `string`, `char`,
`char32`, arrays, options, tuples and maps of them, and persistable structs, classes and enums;
no `var`, live or accessor field (`persistable_field`, 17:114, 17:197). A persistable class is
`<final>`, not `<unique>`, and inherits nothing (`persistable_final`, `persistable_unique`,
`persistable_inherits`); no persistable type is parametric (`persistable_parametric`). A field
default is a literal constant: a number, a character, a string without interpolation, `true`,
`false`, an enumerator, or `option{...}`, `array{...}`, `map{...}`, `tuple{...}` or a persistable
struct's archetype of them, a map without equal keys (`persistable_default`, 17:112, Q10). The
compiler records each default as a constant of `Program.constants`, which P5.3's decoder reads;
otherwise a persistable type is built, compared, matched and called as any other. Both
admissions recompute the rules from the catalogue and check every constant against its field's
type; inspection format 39 prints the flags and the table. See
[RFC-0087](rfcs/0087-persistence.md) "P5.2 as implemented" and
`tests/conformance/persistable-json.forb`.

## JSON (RFC-0087, P5.3)

```forbic
player_data := class<final><persistable>{
    Level:i64 = 1
    Score:i64 = 100
}
Json:string = ToJson(player_data{Level := 5, Score := 250})
# {"$package_name":"/","$class_name":"player_data","x_Level":5,"x_Score":250}
Restored:i64 = Attempt(FromJson[player_data][Json].Level, -1)       # 5
Old:i64 = Attempt(FromJson[player_data]["\{\"x_Level\":3\}"].Score, -1)  # 100, the default
```

`ToJson(V)` gives the canonical JSON of a value of a persistable type (E1, E2): no whitespace;
`true`/`false`; an `i64` in decimal; a `float` as the value report writes one, `"NaN"`, `"Inf"`
and `"-Inf"` as strings; a `string` with `"`, `\` and the control characters escaped; a `char`
or `char32` as the number of its code; an option as `false` or `{"":v}`; an array or a tuple as
an array; a map as an array of `{"k":{"":key},"v":{"":value}}` in insertion order; an enumerator
as `"name::Case"`; a struct or a class as an object of `$package_name` (`/`, then the bundle path
of its file and its nested modules; in a folder tree the module path, `/d/A/M`, with no second
`/`), `$class_name` and `x_` fields in declaration order. It cannot
fail. `FromJson[T][Text]` reads RFC 8259 JSON as `T` (E3, E4): any whitespace, members in any
order, metadata optional but right when present, a missing field filled from its default
constant (17:352), and it fails on anything else: a text that is not JSON, a value of another
form, an integer with a fraction or out of range, a float that overflows, a lone surrogate, equal
map keys, an unknown enumerator, an unknown or repeated member, a missing field without a default,
or a text nested more than 65,536 arrays and objects deep. A decode that fails builds nothing, meets no capacity however large the text, and pays one
fuel unit per 8 bytes it read before it failed: the text is checked in one pass and built in a
second.
Decoding builds each instance afresh, field by field, and runs no block clause or constructor
(17:379). A type that is not persistable is `json_type`. `ToJson` of a type that reaches a class
reads instances (`<reads>`) and `FromJson` of one builds them (`<allocates>`); `FromJson` fails,
so it stands in a failure context. Encoding a value nested more than 65,536 containers deep ends
the run with `json_depth_limit`. Both machines run one codec, `src/forbic/persist_json.zig`, which
an independent model checks (`persist_json_model.zig`); the report replay encodes and decodes
again and compares. The operations are `json_encode` and `json_decode`, control and source
operations; inspection format 46 prints them. See [RFC-0087](rfcs/0087-persistence.md)
"P5.3 as implemented" and `tests/conformance/persistable-json.forb`.

## Nested functions (RFC-0085, I3)

```forbic
MakeCounter(Initial:i64)<transacts>:counter = Block{
    var Count:i64 = Initial
    GetCount()<reads>:i64 = Count
    Increment()<transacts>:void = Set(Count, Count + 1)
    tuple{GetCount, Increment}
}
Fact(N:i64)<computes>:i64 = Block{
    Go(K:i64, Acc:i64)<computes>:i64 = If(K <= 1, Acc, Go(K - 1, Acc * K))
    Go(N, 1)
}
```

`Name(P)<effects>:R = Body` (or `:= Body`, a transparent one) as a statement of a block
(`Block{}`, and the bodies of `Spawn{}`, `Branch{}` and `Batch{}`, which are blocks) declares a
**nested function**. Its name means it from the next statement to the end of the block, so it
is not used before it is declared and two cannot call each other. Its body is a code entry of
its own, an anonymous one flagged `nested` and named by the declared name, published before the
code around it; nothing stands where it is declared. It captures what its body names, as an
`Fn` does: parameters and immutable locals by value, and a local `var` by its cell, since a
nested function that names a `var` shares it (S1a, see "Shared locals"). A direct call is a
`call` of the entry with its captures as leading arguments, the same at every call; a use as a
value is its `function_value` bound to them (`bind`); a call in its own body is a `recur`. Every
closure that names an earlier nested function (an `Fn`, a nested function, a loop's body, a task
body, an arm, a guard, a landing) captures its captures, so that it can call it. An effect
specifier is mandatory (V2) and the function's own: only a call is checked against the caller.
`Return` leaves it, `Break` cannot, and a `Defer` around it is not its own. Refused: an access
specifier (`nested_access`), type parameters (`nested_generic`), `Super.Name` or `(super:)` in
its body (`nested_super`), a header anywhere but at the start of a statement of a block, or in a
`Defer` body, whose copies would be entries of one name (`nested_position`), a name already in
scope (`shadowed_name`) unless it overloads a nested function of the same block. Inside its own body
only the body itself may name it: a closure there cannot (`unknown_name`), as a loop in a named
function cannot name that function. See `tests/conformance/nested-functions.forb`.

**Overloads, defaults and named parameters (I4).** Nested functions of one block may share a
name when their parameter types differ, under the rules of top-level overloads (RFC-0061,
RFC-0076): `duplicate_name`, `related_overloads`, `overload_conflict`; a call is the `call` of
the overload whose parameter types the arguments have, with that overload's captures, and takes
no named argument; a value is the overload of the expected function type (`ambiguous_call`
otherwise). A parameter may have a default and a direct call may name parameters, as for a
top-level function (RFC-0058): arguments by position, then by name, and each parameter left out
takes its default, which reads literals, module declarations and the parameters before it and
is expanded where the call stands. A default cannot name a local, a parameter or a nested
function of the code around the block (`nested_default`). A call of itself passes every
argument, and a value takes every parameter. `forbic qualify` names each use `(local:)Name`,
noted with the overload chosen. No IR is new. See
`tests/conformance/nested-overloads.forb`.

## Member reclamation

A run builds in three stores that are only appended to: the member pool (aggregates, captures
and map entries are spans of it), the string pool (literals, then every string the run builds)
and the cells (the program's own, then those of every class instance). A run that stores its
call witness (`full`, the default) never gives any of it back, because the stored steps name
every span, string and instance the run built and its report reads them back. A `digest` or
`off` run keeps no step, so it may reuse what nothing can reach any more; the memory it needs
is then bounded by what is in use and not by what it ever built. The tool runs a program in
`digest` mode when the stored run stops at `call_trace_limit`, `aggregate_limit`,
`string_limit`, `object_limit` or `live_edge_limit`, so short runs and their reports are exactly
as before.

**Where.** At the end of a frame of a traced call: when a loop visit ends and the next begins
(`Iterate`, `Loop`, and so `While`, `For` and `Loop{}`), and when a call returns. Each frame
records the size of the three stores when it was pushed, its *marks*. Everything the frame and
its callees built lies above the marks, and its own registers are dead at that point. A frame
that ends early, by the `exit` of a `Return` or `Break` (RFC-0068), ends at the same place: the
`exit` first commits every region the frame had open, and what it hands on is the result or the
next loop state, the one value the frame hands on anyway. The locals a `Loop{}` carries travel
in that state, so they are reachable from it and need no root of their own.

**What is in use.** Above the marks, only what is reachable from:

- the one value the frame hands on (the next loop state, or the result);
- the cells that existed when the frame was pushed: the program's `var` cells and the cells of
  older instances, which frames below may still name and which can have been written since;
- an instance above the mark for one of whose cells an open region holds an undo record (see
  below);
- for strings, the reasons of the failure traces a run keeps.

Reachability goes through members (a span names its members), through instances (a reference
names the instance, whose fields name whatever was last written to them, cycles included) and
ends at strings. An instance nothing reaches is not a root: what it holds goes with it.

Nothing else can name anything above the marks. Registers and parameters of the frames below,
captures and the states of enclosing loops were written before the frame was pushed. So was
everything a rollback restores: every region still open was opened before the frame was pushed,
a record or an image holds the value its cell had when its region began, and a rollback forgets
every cell created since its region began, which includes every cell above the frame's mark.
So an instance that a field write made unreachable inside a region is either older than the
frame, and then not a candidate, or was created inside the region, and then the rollback that
restores the field forgets it too. A record for a cell created inside its own region can hold
a newer value, but the rollback that would use it forgets the cell. Such a record still names
its cell, so the instance stays until the region ends: the count of records, which decides
where `undo_limit` falls, is then what it would be without reclamation. Root values and what
they name lie below the marks of every frame and are never moved.

**How.** Members name only members below them, but a field names whatever was written to it,
so reachability is a walk: values still to be examined wait in a worklist, and a per-member
forest leads from any member to the next one not yet reached, so that a span costs what it adds
however often it is named and however it overlaps others. What is reachable then slides down to
its mark in order, in each store, and every value still in use is rewritten: spans, instance
ids and string addresses.

- Members: as before. Keeping the order keeps neighbours neighbours, so the layout rules of
  RFC-0055 (adjacent arrays join without a copy, the newest array grows in place) mean
  afterwards what they meant before. An empty span moves with the positions it lies between.
  The room a copy left behind an array (RFC-0055, "Rooms": placeholders no value names) is
  reached with the array that ends where it begins and slides down behind it, so a join finds it
  where it would without the reclamation; the report replay keeps its own list of rooms and
  moves it the same way.
- Instances are renumbered: the ones that stay close up, in creation order, and every reference
  is rewritten. An instance's id is the position of its first cell, a report numbers the
  instances it lists the same way, and a rollback forgets instances by cutting the cells back to a count; all three
  stay true only if the cells stay dense. Reusing freed cells in place would keep ids stable
  but needs a free list that rollback can restore and that both machines and the replay walk
  alike, and would leave reports with ids that depend on when a run happened to reclaim. With
  renumbering the cells after a reclamation are a function of the reachable set alone. The
  regions' own marks are untouched (no open region began above the frame's mark), and the
  records they hold for cells that moved name them where they are afterwards.
- Strings: a string is a view of bytes, and views overlap (RFC-0055: `+` extends the newest
  string in place, so a string may begin below the mark; RFC-0069: a slice is a view of its
  operand). The bytes that some string still names form runs; each run slides down to the end
  of the one before, starting at the mark, and a string moves with its bytes. A string that
  began below the mark keeps its place, and so do the bytes it names above it. An empty string
  moves with the place it stands at. Afterwards a string may end the pool that is not the
  newest string made: one whose later strings were freed. `+` does not extend it: it copies it,
  as a run that never reclaims copies it past the garbage beyond it, and the copy is the newest
  string again (TASK-0109 W2 round 2, c7-1; `run_strings.Pool.stale`, the end a reclamation
  that frees the last byte of the newest string leaves, which names nothing once the next
  string made has moved the end past it). A reclamation
  that keeps that byte keeps the newest string extendable where it slid. So whether `+` extends,
  and what it is charged, do not depend on whether or where a run reclaimed.

The layout after a reclamation is a function of the reachable set alone, which is why the
reference evaluator, the VM and the report replay can each compute it in their own code and
agree on every position: the reference walks depth first with a stack and compresses its forest
by pointing every entry it passed at the end, the VM walks breadth first with queues and halves
its paths; for strings both mark the places strings start at in a bitmap, keep the furthest end
per start and sweep once, the reference in terms of runs and their shift and the VM in terms of
gaps and the bytes dropped so far; the replay sorts the strings it finds and looks a moved
string up among the runs, and moves nothing but its own cells.

**When.** Reclaiming at every frame end would change the layout of every run and cost more
than it frees. Each store has a size at which the run reclaims next. A frame end reclaims, all
three stores at once, when one of them has reached that size and holds something above the
frame's mark. After a reclamation that examined `e` and left `k` in a store of capacity `c`,
the store's next size is `k + max(min(floor, (c - k) / 2), wait)`. The floor
(`ControlStorage.reclaim_floor`) is stated in members, by default an eighth of the pool, and
the other stores get the same share of their capacity; half the remaining room replaces it when
a store is nearly full of what is in use. `e` is the members and an eighth of the string bytes
above the marks, every cell and every undo record; `wait` is `e / 8` members or cells, or `e`
bytes. A run below the floor in every store never reclaims, so its digest and its report are
those of the same run without reclamation.

Two more frame ends reclaim, in a run that has reclaimed before:

- A frame nearer the root than the one that reclaimed last, as soon as a store has grown by
  `wait` since. The deeper frame could free nothing below its own mark and counted what lay
  there as in use; without this a loop whose every visit runs a shorter loop would leave each
  inner loop's remains below the next one's mark until a store was full.
- The frame of a call from the root, when it returns and has built anything. What a call
  leaves behind is then what it handed on and what the cells hold, so a report lists no
  instance that the visits after the last reclamation merely happened to leave.

**Fuel.** Reclamation is not charged: the same program needs the same fuel with and without
it, and both machines stop at the same node when fuel runs out. For strings that holds since
c7-1 (above). For arrays it is still open: a reclamation that frees members made after an array
can leave it at the end of the pool, or next to a later right operand, and the join then grows it
in place or joins the neighbours where a run that does not reclaim copies (RFC-0055, "Amendment:
c7-1"), so such a run may need less fuel, never more. The work is bounded instead.
A reclamation costs a constant per member and per eight bytes above the marks, per cell and
per record, at most a constant times `e` (the forest adds a factor that is one or two in
practice and logarithmic at worst). The next one, whichever frame makes it, is not due before
a store has grown by `wait`, and growth is charged: a member and a cell one unit each, eight
bytes one unit. So reclamation costs at most eight such visits per unit of fuel charged for
what the run built, plus one reclamation per traced call made from the root, each at most the
stores and the cells. A run in which nearly everything stays in use pays `e` again only after
building an eighth of it anew.

**Tasks.** Under several stacks the fact this rests on, that everything above a frame's marks
was built by that frame and its callees, holds only while no other task ran since its push. A
frame end that saw a switch reclaims with the suspended tasks' values as roots as well, above
its marks or the stores' sizes when the root ended; see "Reclamation across task stacks" above.
A join writes into the room behind an array only at or above its frame's floor, and in a frame
that saw a switch only while no task holds suspended frames, or members that name nothing
(numbers, logic values, enumerators): a suspended frame's end reclaims above its own marks and
would not see what a member below them names (RFC-0055, amendments "pf2" and "w15").

**Reports.** A `digest` run is reported by running the program again and replaying the
stream of steps (`trace_replay.zig`). The second run sends the steps it holds before it
reclaims, together with its member pool and the size of its string pool, so the replay checks
every step against what that step names. The replay works out each reclamation for itself from
the rule above, on its own copy of the cells: it renumbers its own values, moves its instances
and their records, and must find itself where the run says it is (the same string pool size,
a member pool at least as large as it computed); it counts the reclamations and compares the
count with the run's. Strings are not recomputed by the replay; it follows the size of the
pool from the steps (every string a call builds is the value of a step) and is told it where
steps cannot say: when a traced call begins, and after each native call. At the end the first
run's members must equal the second run's member for member, its instances the replay's cell
for cell, its failure reasons the replay's, and the bytes of the string pool must be the ones
admitted before the second run. A final state that names an instance or a string the rule
reclaimed therefore differs from what the replay computed, and is rejected. Both runs build
in one string pool, so a second run that fails, or reclaims on another floor, leaves the first
run's strings unreadable: such a report is rejected, never printed.

The report lists the instances that the bindings it prints reach, through aggregates,
captures and the fields it prints, and no other: an instance only a private binding holds is
not in a `public_only` report, and one that nothing holds is in no report. A `public_only`
report (the extension host's, for a single file as for a bundle) shows nothing the public API
cannot reach (`fix2`): an instance as the nearest class, its own or one above it, that another
module can name, with that class's shown fields (`{"id":N,"class":null,"fields":{}}` when there
is none), a function value without its captures, so neither what only a capture holds, and a
value held as `any` whose type the public API cannot name (a private record) as
`{"$hidden":true}`, since reading it back needs a cast that names the type. Each listed
instance's id counts the cells of the listed instances before it (a header and one per printed
field), so a run that reclaimed and the same run stored print the same report, whatever
unreachable instances either still holds. The worker validator admits exactly that form.

**What still grows.**

- A value that really accumulates: an array, map or string that is a loop's state, that a cell
  holds, or that is reachable from one; a list of instances that grows. It stops at
  `aggregate_limit`, `string_limit` or `object_limit` as before, in both machines at the same
  node. Which allocation finds a store full can depend on the floor, since that decides how
  much unreclaimed remains lie in it; that it is full of what is in use does not.
- Instances and strings created inside a region that is still open are reclaimed like any
  others unless a record names them: an instance written in the region it was created in stays
  until that region ends, and each such write costs a record (`undo_limit`).
- What an earlier call from the root left in use and a later one made unreachable: it lies
  below the marks of every later frame.
- A run with a stored witness, by design, and anything outside traced calls: what root
  expressions and plain calls of straight-line functions from the root build, which is
  bounded by the program text.
- Members, strings and instances left by a failed or rolled back region stay until the next
  reclamation, like any other; rollback itself releases only the instances.
- A store so full of what is in use that less than `wait` is left cannot be reclaimed again
  and stops at its limit even if a little could be freed.
