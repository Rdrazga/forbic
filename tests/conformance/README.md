# Language conformance

Classify fixtures as supported Forbic subset, proposed dialect extension,
intentionally unsupported, or upstream reference only. Record source provenance,
expected result/diagnostic, and limits for every imported example.

Book examples are useful test inputs, but passing examples does not establish
complete semantic conformance. Do not automatically import content without
checking its license and matching it to the accepted language specification.

`float.forb` and `float-type-error.forb` are project-authored supported-subset
fixtures. The former checks typed function arithmetic, separate rounding,
signed-zero and nonfinite JSON reporting; the latter rejects mixed i64/float
arithmetic at the operator. Neither is a copied upstream conformance test.
`float-extension.forb` and its SHA-256-bound manifest test the same valid JSON
encoding through the real pure-extension CLI; this does not enable native grants
or OS isolation. All four numeric source fixtures are project-authored.


`callables.forb` checks a returned record with a definition-site callable default,
public typed reference output, transacts/decides parameter invocation, strict
arguments and shared rollback. Its value and extension output are independently
computed; trace2 preserves the defining Visit origin. Inspection18 exposes exact
signatures and lowered operations. `callables-error.forb` confirms fatal division
failure bypasses Attempt. SDK worker/configuration paths consume the same source;
`desktop/config/callables-baseline.forb` exercises callable policy helpers.

`callable-iteration.forb` exercises a returned record's typed Step, parameter
dispatch, successful repeated states and whole-loop source rollback. Its expected
values are independently derived (Cell4, Good3, Recovered4, Total11). CLI/SDK/
Traverse/desktop, trace2, inspection19 and precise fatal-count fixtures use the
same source. TASK-0074 records frozen inputs and cross-host acceptance.

`state-loops.forb` exercises a returned record's typed Step, parameter dispatch,
normal option termination with committed writes and whole-loop failure rollback.
Expected Cell5, Good3, Recovered5 and Total13 are independently derived. CLI/SDK/
Traverse/desktop, trace2, inspection20 and strict seed division diagnostics share
this source. TASK-0075 records frozen inputs and cross-host acceptance.

`bound-functions.forb` exercises a default's captured function escaping its
creator, parameter/loop dispatch, committed writes and whole-loop rollback.
Independent values are Cell9, Good3, Recovered9 and Total21. CLI/SDK/Traverse/
desktop, trace2, inspection21 and strict captured-argument division diagnostics
share this source. TASK-0076 records frozen inputs and cross-host acceptance.

`anonymous-functions.forb` exercises a default's anonymous capture escaping its
creator, parameter/loop dispatch, committed writes and whole-loop rollback.
Independent values are Cell 9, Good 3, Recovered 9 and Total 21. CLI/SDK/Traverse/
desktop, trace format 2, inspection 22 and strict capture division diagnostics
share this source. The anonymous site is original byte offset 82. TASK-0077
records frozen inputs and cross-host acceptance.

`generic-functions.forb` specializes `Identity[i64]`, `Identity[string]`, a
`Twice[i64]` callback and a stored `Step[i64]` that writes `Cell`. Independent
values are Number 43, Moved 7, Cell 3 and Total 53. CLI/SDK/Traverse/desktop,
trace format 1, inspection 23 and a strict specialized-argument division
diagnostic share this source. Specialization ID 0 identifies `Step[i64]`.

`effect-polymorphism.forb` applies one template at computes and transacts, then
forwards transacts-decides through `Pass`: a committed write and a rolled-back
attempt. Independent values are Pure 7, Moved 6, Kept 2, Rolled 7, Cell 7 and
Total 29, shared by CLI/SDK/Traverse/desktop, trace and inspection fixtures.

`array-index.forb` reads nested rows through a decides function and a
transacting probe whose failed read rolls its write back. Independent values are
Hit 6, Miss -1, Past -1, Name "beta", Kept 2, Dropped 1, Cell 1 and Total 8; the
trace reports three requirement failures at the indexed expressions.

`array-fold.forb` defines a generic `Fold` over arrays from `Loop` and indexed
reads. Independent values are Sum 116, Largest 9, Empty 7 and Last "b".

`numeric-conversions.forb` covers ties-to-even rounding, floor/ceil/truncate on
negatives, huge and NaN failures and a transacting probe whose failed conversion
rolls back. Independent values are Tie 4, Above 3, Down -3, Up -2, Toward -2,
Huge and NotANumber -99, Kept 4, Dropped 1, Cell 1, Scaled 3.5 and Total -192.

`native-std.forb` binds the standard Zig natives for sums, sorting, maximum,
search, a dot product with `Sqrt`, a range and a call from a function. Independent
values are Total 22, Ordered [3,3,7,9], Biggest 9, Where 2, Missing -1, Norm 5,
Count 10 and Scored 122; the error fixture overflows `std.sum` into a fatal native
diagnostic.

`text.forb` (B5, RFC-0053) declares `ToString` for a struct, an enum, a class and an array
and interpolates or calls it: Own "(1,2)", Kinds "dark Thing:a n=3", Call "(1,2)71.5false",
Nested "[(1,2)] x(1,2) (1,2)", Each ["(1,1)","(2,4)","(3,9)"], Transparent "<1|2>" (a `ToString` written `:=`), while `{7} {1.5} {true} {"s"} {'c'}`
keep their own text; the error fixture declares a `ToString` that returns `i64`
(`to_string_signature`).

`strings.forb` concatenates strings, measures UTF-8 bytes, converts numbers and
uses the standard string natives (trim, upper, substring, split, join). Independent
values are Greeting "hello, 雪!", Size 11, Report "count=42 ratio=2.5 on=true", Loud
"OK", Part "雪", Cut "?", Words [a,b,,c], Back "a+b++c" and Chain "((a))"; the error
fixture exhausts the string pool.

`classes.forb` is project-authored and exercises an abstract base, a final subclass, inherited
`var` fields, overrides reached through the base type, `Super`, a failing downcast, rollback of
a field write inside a failed `Attempt`, a two-instance cycle and an interface implemented by
`Node` (First 1, Again 2). Expected values are derived by
hand (Before 9/10, After 18/10, Kept 1, Told "rect!", Width 2, NotSquare -1). The report lists
each instance once under `$objects`. `classes-error.forb` checks that division by zero in a
method is fatal through `Attempt`. Inspection format 24 carries the method and dispatch tables.

`comparable-keys.forb` is project-authored and exercises RFC-0065: maps keyed by tuples,
records and arrays of options, structural `==` through a `T:comparable` function, map order in
equality, float keys, `Without` succeeding and failing inside a `<decides>` function, rollback
of a removal and an insertion inside a failed `Attempt`, and `For` over tuple keys. Expected
values are derived by hand: Hit "a", Miss "?", Shade Color.Green, Found 3 (2+1), Equal true,
Ordered false, Zero true, A 2 (three cells less one), B -1 (the key is already gone), Rolled 3
(both writes undone), Keys [(0,0),(3,4),(1,2)] because the key set again goes to the end, Names
["3,4=b","1,2=again"]. The trace records the three failed lookups. `comparable-keys-error.forb`
checks that two structurally equal keys in one literal are a fatal duplicate.

`for-generators.forb` is project-authored and exercises the general `For` of RFC-0064: nested
generators, a keyed outer generator, inclusive and empty ranges, a map generator with a filter and
a failable binding, a body that fails and a transacting body whose skipped iteration is undone.
Expected values are derived by hand (Pairs [12,13,23], Flat [1,2,203], Squares [1,4,9,16],
Empty [], Triangle [11,12,13,22,23,33], Worth ["nut=15","gear=80"], Picked [2,4,6], Kept [1,4],
After 4); the trace reports ten caught failures (six `X<Y`, one `Count>0`, two `Xs[I]`, one
`Require`). `for-generators-error.forb` checks that division by zero in a binding is fatal
through the iteration's failure region.

`early-exit.forb` is project-authored and exercises RFC-0068: `Return` from nested conditionals
and from a `For`, the Book's loop `Loop{}` with `Break` (also through a `For`), `Defer` at the
normal end of a block, on `Return`, on every visit of a loop and not on failure, and an `Err`
that is not reached. `Note` appends a digit to `Trace`, so the traces read as the order things
ran in. Expected values are derived by hand: A 99 (-1, 0 and 1), B 19 (index 2, then -1), C 4,
D 5 (5*5 is the first product above 20), E 4 with T1 1234 (one deferred note per visit, the last
on the `Return`), F 12343 (the value is ready before the two `Defer`s append 2 and 1) and G 9
with T2 12343214251, H -1 (the failed block's note and its `Defer` leave no trace) and I 2 with
T3 1234321425167, J 4. The trace reports the one caught failure, the `Require` of `Risky[0]`.
Inspection format 25 shows the `exit` and `err` operations. `early-exit-error.forb` checks that
`Err` ends the run through a loop, a `Defer` and an `Attempt`.

`chars.forb` is project-authored and exercises RFC-0069 on `"José"` (`4A 6F 73 C3 A9`: five code
units, four scalar values). Expected values are derived by hand: Length 5; First `J` (74), Third
the lead byte 195, None and Past the fallback `?` (63); Units [74,111,115,195,169]; Scalars
[74,111,115,233]; Front "Jos", Accent "é", Split "!" (the slice would end inside `é`), Empty ""
(an empty slice splits nothing); Back "José" and Same true; Broken "!" (`C3 28` is not UTF-8);
Code 74, Point 233; Made 74, TooBig 63; Wide 233, Surrogate 63; Widened 74, NotAscii 63;
Shown "J|�|é|😀" (a lone code unit above ASCII reads as U+FFFD); Count 5 (the vowels of
"education", by a `Case` on `char`); A 1, B -1 with its write undone, C 1 and Tally [`x`, 2]
(a `map(char,i64)` cell); Grin "grin" from a `map(char32,string)`. The value report prints a
character as `{"$char":code}` or `{"$char32":code}`. The trace reports nine caught failures: the
empty `Head[""]`, `Name[5]`, the one position of `Name` that starts no scalar, the split slice, the
units that are not text, 256, the surrogate, the non-ASCII widening and the `Require` in `Note`.
`chars-error.forb` checks that `0uD800` names no scalar value while `0uD7FF` does.

`alignments.forb` is project-authored and exercises RFC-0076: `and`/`or` that skip a right
operand the left one decides, comparison chains, `class<unique>` equality and map keys, an
`option{E}` and an `If` condition that catch inside a `<decides>` function and a `For`, and
parameter defaults that read earlier parameters and `Self`. `Hit` adds 1 and `Mid` adds 10 to
`Calls`, so the counts show what ran. Expected values are derived by hand: Skipped false, Kept
true, Ran true, AfterLogic 1 (only `Ran` called `Hit`), Safe true, NoTrap false (the division
is skipped); Ranges true, Once true (`Mid(5)` once), Stopped false, AfterChains 21 (`Mid(9)`
never ran), Mixed true; Identity true, Owned 12; Missing the empty option, Found option{20},
Undone the empty option with AfterUndone still 21, Each [option{10}, option{20}, option{}];
Sizes 100; Square 224, Slab 235, Added 106. `alignments-error.forb` checks that a parameter
named like an earlier binding is `shadowed_name`.

`stdlib.forb` is project-authored and exercises RFC-0077 with the Book's own examples.
Expected values are derived by hand. Arrays over `Nums` [1,2,3,1,2,3] and `Tens`
[10,20,30,40,50]: Found 1, Missing -1, Fruit 2 (through a generic function), Point 1 (a struct
is compared part by part), NotANumber 1 (one NaN); Mid [20,30,40], Tail [30,40,50], EmptySlice
[], and Backwards, Beyond, NoneGone, CutBeyond, AtBeyond and InsertBeyond the fallback [-1];
FirstGone [1,3,1,2,3], AllGone [1,3,1,3], Cut [10,30,40,50], FirstNew [1,99,3,1,2,3], AllNew
[1,99,3,1,99,3], At [10,99,30,40,50], Runs [1,99,4,99,5], Longer [1,9,9,9,1,9,9,9,1], Overlap
[2,2,1] (runs do not overlap), Inserted [10,20,25,30,40,50], Appended [7], Flat [1,2,3,4], Many
[1..6], Last 50, LastTwoBack 30, LastOfNone and LastNegative -1, Chain 2. Kept 1 with Stocked
[4,6]; Undone -1 with Restocked [4,6] (the removal of 6 is rolled back when the search for it
fails). Merged [1,"original",2,"updated",3,"new"], unchanged by an empty map; ByPoint keeps the
first key's place with the second value. Strings over `"José"`: Replaced
"Applesy, this is a string, Applesllo!", Unaccented "Jose", Unit 2, NoUnit -1, Dashed "Jos-é",
Split and SplitCut "!" (position 4 is inside `é`), Shorter "Jé", LastUnit 169, Joined
"a, b, c", Glued "abJosécd". Numbers: AbsInt 5, AbsFloat 3.14, Least -4, Most 3, MaxNaN NaN,
MinInf -Inf, Clamped 2, ClampedFloat 1, Root 1.4142135623730951, RootOfNegative NaN, Cube 8,
PowZero 1, E 2.7182818284590455 (within one unit in the last place of e), One 1, LnZero -Inf,
Decades 2, Sine 0.8414709848078965, Cosine 0.5403023058681398, Tangent 1.5574077246549023,
SinePi 1.2246467991473532e-16 (`PiFloat` is not pi), QuarterTurn 0.7853981633974483, HalfTurn
3.141592653589793, OutOfDomain NaN, Origin 0, Hyperbolic 1.9566876725032807, Inverse
2.7476376282784143, Blend 4, Beyond1 11, Diagonal 5, Finite 2.5, Infinite -1. The trace
reports fourteen caught failures: the fallbacks above. `stdlib-error.forb` checks that `Abs`
of the least `i64` is a fatal overflow through an `Attempt`, while that of its neighbour is not.

`native-effects.forb` is project-authored and exercises RFC-0079 with the default seed. The
draws were worked out by an independent model of the stream (SplitMix64 from the seed
`0x56455253452f5400`, rejection for bounded integers, 53 bits for floats): Die 5; Lost -1,
whose draw (3) is spent though its region failed; Next 1 (bounds in either order), the next
value of the stream; Wide -915853; Unit 0.020742529924025477; Deck [1,2,4,5,3], a Fisher-Yates
pass keyed by the sixth word. Kept 1, Gone -1, Inner 2, Undone -1, Caught empty, Called 15. The
lines `eval` prints before the values are exactly `hello`, `kept`, `risky 1`, `caught`,
`outer 2`, `say 7`, `say 8`, `<array>`, `5`, `<struct>` and `bye 5 1`: nothing printed in a
region that failed (`gone`, `inner`, `inner kept`, `outer gone`, the `risky 0` of each failed
call and `never 3`) appears. The trace reports five caught failures: four `Require` in `Risky`
and the one of `Lost`. `native-effects-error.forb` shows that a fatal error keeps what was
committed: `eval` prints `committed before the error`, never the pending line, and then the
overflow of `Abs` on standard error.

`generic-methods.forb` is project-authored and exercises RFC-0081. Generic methods: Described
"area 9" (an interface's generic method over `Square{Side:=3}`), Mapped "v5", Paired
[5,"five"], Applied [5,true] through the method bound to its receiver, Grown 5 (two then one
element added to a counter), Undone -1 with Kept 3 (the three added in the failed region are
taken back), Deep 4 (a generic method that calls itself). Type values: Physical [1,3] (the
parts that are `Physics`), Counts [3,2,1] for `Component`, `Physics`, `Render`, Spawned
["player","enemy"] built through `concrete_subtype` values, Massive 49 (the cast to `Physics`
reads mass 5, the cast to `Render` fails). `SortBy`: Sorted ["b","e","d","a","c"] (ranks
1,1,2,3,3, equal ranks in their order), Down [9,7,4,2], Succeeded 4: of the comparisons of the
two passes over [2,9,4,7] (9>2, 7>4; then 7>9 fails, 7>2, 4>2) only the four that succeeded keep
their write. Functions: Widened 42 (`Twice` held as `any` comes out as a `<transacts>` function),
Narrowed 8. The trace reports ten caught failures: the `Require` of `Undone`; the four casts
through type values that fail in `Ids`, each placed where the type value of its class was first
written; the cast to `Render` in `Massive`; three comparisons of `ByRank` and the one of
`Counting` that failed. `generic-methods-error.forb` overrides a
generic method: `generic_method_slot`.

`book-tightening.forb` is project-authored and exercises RFC-0092 (B8), hand-checked. A
`castable_concrete_subtype(Base)` value `Kid` builds a `Kid` (BuiltN 2) that the same value
tests true (BuiltIsKid) while a sibling `Other` and the castable `Plain` are not it
(OtherIsKid, PlainIsKid false); an array of such values builds Made [2,3,2] and tests
Other Tests [false,true,false]. As a bound it builds `Other` (3, times 10) and casts `Kid`
(2): Generic 32. A parametric `Box[T]` below the castable `Base` is accepted: Boxed 7 (the
cast to `Kid` of a `Box` fails, no 100). `_` is the wildcard of a pattern: Kinded 123
(`_:Kid`, `_:Other`, `_` for `Plain`) and Wild 10 (`option{ _ }`). `and` and `or` skip the right
operand when the left decides: Counted 1, the one `Tick()` of `Run`. The trace reports the
failed casts that `Attempt` caught. `book-tightening-error.forb` declares a parameter named `_`:
`underscore_name`.
