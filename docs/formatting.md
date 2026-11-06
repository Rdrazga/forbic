# Forbic formatting (`forbic fmt`)

Status: implemented (TASK-0109, W4.5). Code: `src/forbic/format.zig` (the formatter),
`src/tooling/format_command.zig` (the command), `src/forbic/format_corpus_tests.zig` (the corpus
test).

```text
forbic fmt FILE...          rewrite each file in its canonical layout
forbic fmt --check FILE...  print the files that would change; exit 1 if any would
forbic fmt -                read standard input, write the formatted text to standard output
```

`--check -` checks standard input and prints `-` when it would change. The exit status is 0 when
nothing failed (and, with `--check`, nothing would change), 1 when a file would change or could
not be read, lexed or written, and 2 for a command line `fmt` does not take. A file that fails is
named on standard error and the other files are still formatted. A rewrite replaces the file in
one step (an atomic replace that gives the new file the old one's permissions), so a failure
leaves the old text whole. A file its user may not write is refused ("cannot write the formatted
source"), though its directory would allow the rename; so is a symbolic link ("format the file
it names"), which the replace would turn into a regular file. A file with other hard links gets a
new file at its path; the other links keep the old text.

## What the formatter may change

The formatter reads the tokens the compiler's own lexer (`lexer.tokenize`) makes, so it accepts
exactly the text the compiler can lex. That lexer ignores spaces, tabs, carriage returns and
comments (`#` to the end of the line, block comments `<# ... #>`, indented comments `<#>`;
RFC-0089), and makes a token of every newline. The formatter changes only:

- the spaces and tabs between tokens, and the indentation of lines;
- carriage returns that end lines, which it drops, inside interpolations too (CRLF input gives
  LF output; a carriage return within a comment's text stays);
- the number of newlines in a run: at most one blank line is kept, and none at the start or end
  of the file, which ends with one newline (an empty file stays empty);
- trailing blanks after a comment, and the blanks that begin the lines of a comment that moves
  (see "Comments" under Conventions).

It keeps every token in order with its spelling, keeps every line break between tokens where the
author put it (long lines are not reflowed), keeps every comment with its text, and copies each
string literal, with its interpolations and anything inside them, byte for byte. The one token
it does not write is the colon the lexer itself drops, that of `Name:type := v`
(`lexer.dropTypedInitializerColons`): `X:i64:=3` becomes `X:i64 = 3`, which lexes to the same
tokens.

The compiler reads a few pairs of neighbouring tokens differently when they touch, so for those
the formatter keeps them touching, or apart, as written (`format.touchMatters`):

| Pair | Read together as | Where |
| --- | --- | --- |
| `:` `=` | `:=` | `bindingAhead`, `destructureEnd`, `labelAt`, `namedArgument` and others in `compiler.zig` |
| `+` `=`, `-` `=`, `*` `=`, `/` `=` | a compound assignment | `compoundAt` |
| `-` `>` | `K->V` of a map generator, and a live variable's `->` | `forClause`, `arrowAhead`, `liveTypeShape` |
| `.` `.` | `..` of a range | `forClause` |
| a name, `:`, then `)` | the qualifier `(Word:)` | `qualifierAt` |
| `:` `)` | the end of a qualifier | `qualifierAt` |
| a name, then `(`, `[` or `<` | the header of a nested function | `nestedHeaderAt` |

So `(local :)X` and `F (X)` keep their spaces, while `X : i64` becomes `X:i64` (the colon is
not followed by `)`). The other
places where the compiler reads the source bytes themselves see no difference: a statement start
(`writtenAsStatement`) and the macro count (`macros.countWord`) skip blanks, and a nested
module's header (`modules.moduleHeader`) skips spaces and tabs. That last one does not skip a
carriage return, so a file with a carriage return between tokens that does not end a line (one
followed by anything but a newline) is refused ("a carriage return that does not end a line; the
file is left as it is") rather than changed. One in a comment, or at the very end of the file,
is harmless and is not refused. None of these readers skips a comment, so one that stands
between the text they look at and its neighbour (a block comment before a statement on its
line, say) makes the same difference after formatting as before: the formatter never moves a
comment past a token or a line break, and changes only the blanks around it.

Before it returns, the formatter lexes its own output and compares the tokens with the source's
(`format.sameTokens`): the same kinds and spellings, a run of newlines counting as one and
newlines at either end not counting, and each pair of the table above touching in both or in
neither. If they differ the result is refused ("the formatter would
change the program here (a formatter defect)") and nothing is written. Since the compiler sees
only tokens, and treats a run of newlines as one separator, a formatted program means what it
meant.

It then compares the comments (`format.sameComments`): as many as the source's, in the same
order, each of the same kind (`#`, `<# #>`, `<#>`) and with the same lines, apart from the
blanks that begin or end a line (a blank inside a line, a line break or a blank line is text). If
they differ the result is refused too ("the formatter would change a comment here (a formatter
defect)"), nothing is written, and the position is the source's first comment that differs. This
is the guard of the comment layout below: a comment lost, joined to another, split, altered, or
turned into one of another kind (an indented comment is measured by its own indentation) is
found before anything is written. No source of the tests reaches it (the random test of
`format.zig` runs the layout over thousands of mixes of code and comments); a source that does is
a formatter defect to report. Diagnostics name the same text; their line and column move with the layout, and so do the
other places that report a source position: the spans of `forbic inspect` and the byte offset
that names an anonymous function in `forbic eval` (`"anonymous":82`). Removing blank lines
lowers the number of newline tokens, so a program refused for its token count can be accepted
after formatting, never the reverse.

## Conventions

Derived from `tests/conformance/*.forb` and `desktop/**/*.forb`, where the spaced forms
(`X := 1`, `Name:string = "a"`, `F(A, B)`) are the most common spelling and the denser ones
(`ApiVersion:i64=1`, `F(A,B)`) come from generated or older fixtures.

Indentation: four spaces per level. Each line that leaves brackets open indents the lines after
it by one level, however many brackets it opens (`If(A, Block{` opens one level). A line that
begins with closing brackets goes back to the indentation of the line that opened the outermost
of them, so `}, Block{` and `})` line up with the line that opened them. Closers the source
never opened (a program the compiler refuses) do not indent below the margin. A comment on its
own line takes the indentation of a code line in its place. Lines inside a string's
interpolation are part of the string and keep their text.

### Comments

A comment is placed by where it stands among the tokens of its line. The text of every comment is
kept byte for byte, except for the blanks named here.

| Where | Layout |
| --- | --- |
| a `#` comment at the end of a line | as before: the blanks written before it stay (at least one space), trailing blanks go |
| alone on its line(s) | a comment-only line takes the indentation of a code line in its place; see below for the lines it spans |
| a block comment between two tokens of a line | one space on each side (`F( <# c #> 1)`, `X <# c #> + 1`), whatever the neighbours' usual spacing; its text, lines included, is copied as written |
| a block comment before the first token of a line | followed by one space, after the line's indentation; copied as written |
| a block comment after the last token of a line | the first keeps the blanks written before it, like a `#` comment (aligned comments stay aligned), the others have one space before them |
| several on one line | one space between them; a `#` comment last |
| in a string's interpolation | part of the string, copied with it |

"Alone" means the line holds comments and no token. Such a line is moved as a unit: the whole run
of comments from the first one's first byte to the end of the line goes from the indentation it
had to the indentation of a code line in its place, and every later line the comments cover moves
by the same number of columns (a space is one column and a tab four, as the lexer counts them for
an indented comment): a line of a block comment that spans lines keeps its distance from the first
line, its leading blanks becoming spaces, and never moves left of column zero; a line of
blanks in it becomes empty. When the first line does not move, the comment is left exactly as
written (tabs in its later lines stay). A block comment that is not alone is never re-indented: a
line break inside it is part of its text, and the code beside it decides the line's indentation.

An indented comment `<#>` stands first on its line and takes, as its body, the lines below it
that are blank or indented four columns more than its line. It moves like a comment that is alone:
the marker takes the indentation of a code line in its place, and each body line keeps its number
of columns past the marker, written as spaces. Blanks that end any of its lines go, and a line of
blanks inside it is empty. Blank lines after its last body line are not part of it and collapse
like any blank lines. Moving it can neither add nor remove body lines: the lines after it are
code of the same bracket depth, so at most as indented as the marker (a line that begins with
closers is less), and the body needs four columns more.

Carriage returns directly before a line end in a block or an indented comment are dropped
(CRLF input gives LF output; in `\r\r\n` both go, since keeping the first would make a second
pass drop it); one that is not directly before a line end stays, as in a `#` comment, in a
string's interpolation too.

A comment with the same text can therefore be a different comment after a move only in its
blanks; `format.sameComments` checks this. Formatting twice gives the same result because the
second pass sees each comment at the indentation the first gave it, where nothing moves.

Spacing on a line, decided for each pair of neighbouring tokens in this order:

| Pair | Spacing | Example |
| --- | --- | --- |
| before `,` or `;` | none | `F(A, B)`, `X; Y` |
| after `,` or `;` | one, but as written before a closer | `F(A, B)`, `Block{X; 0}` |
| around `.` | none | `Self.Health`, `1..9` |
| after `(` or `[`, before `)` or `]` | none | `F(X)`, `Items[0]` |
| around `:=`, `=`, `=>`, `==`, `!=`, `<=`, `>=`, `+=`, `-=`, `*=`, `/=`, `*`, `/` | one | `X := 1`, `map{1 => 2}` |
| around a binary `+` or `-` | one | `A + B`, `F(X) - 1` |
| after a unary `+` or `-` | none | `-1`, `F(-X)`, `not -Y` |
| around `:` | none | `Name:string`, `(:accessor, V:i64)`, `For(X:Xs)` |
| a pair of the table above | as written | `K->V`, `1..9`, `(local:)X` |
| everything else | one space if any was written, else none | `Block{ X }`, `array{1}`, `<transacts>`, `X < 3` |

A sign is binary after an operand: a name, a number, a character, a string or a closing bracket,
except after `and`, `or`, `not` and `Return`. `:=` and the compound assignments are operators
only when their two tokens touch, as they always do in practice; `: =` stays two tokens with
`=` spaced (`X: = 1`).

Spacing is kept as written (any run of blanks becoming one space) where tokens alone cannot say
which convention applies: inside braces, where `Block{ X }` and `array{1}` are both common;
around `<` and `>`, which both compare (`X < 3`) and bracket specifiers (`F<public>`,
`)<transacts>:`); around `?`; and between a name and an opening bracket (`F(X)`, but `and (B)`).

Two tokens are never joined into a different token: where the table says "none" but the source
had a space, the space stays when the two spellings written together would lex otherwise
(`1 .5` would become the float `1.5`).

A comment at the end of a line keeps the blanks written before it (so aligned comments stay
aligned when the code before them does not change width), with at least one space.

## Limits

The formatter's storage (`format.Storage`) is sized from the capacity profile: room for
`tokens` tokens twice (the source's and the output's), one indentation entry per token, and
`source_bytes` of output. A source larger than `source_bytes` is refused before it is lexed
("source is larger than the N-byte limit"); so is a result that would be larger (indentation can
lengthen a file), since it could not be compiled. Nothing in the formatter recurses: bracket
nesting is an explicit stack bounded by the token count.

## Tests

- `src/forbic/format.zig`: spacing, joining, indentation, comments (each placement of block and
  indented comments: between tokens, before and after the units of a line, alone on lines,
  spanning lines, nested, at several depths, at the start and end of the file, in a string's
  interpolation, beside line comments, with CRLF input), blank lines, strings and interpolations,
  oversize input and output, the token comparison and the comment comparison, the refusal of a
  result that loses, alters or retypes a comment, and a random test over 40000 mixes of code and
  comments that checks each result against the lexer, to be a fixed point and to keep its
  comments. Each expected result is also checked to be its own format.
- `src/forbic/format_corpus_tests.zig`: every `.forb` file under `tests/conformance/`,
  `desktop/` and `apps/extension-host/fixtures/` formats to a fixed point, and compiles to the
  same `forbic inspect` report, or is refused with the same diagnostic code over the same text
  (whitespace aside), before and after formatting. The report names source positions (`span`,
  `source`, `generic_source`); they are compared as the number of non-blank bytes before them,
  which formatting keeps (colons are not counted: the lexer drops one that the formatter does
  not write). Files with block or indented comments (`lexical.forb`, the comment fixtures) are
  formatted like the others, and the test requires some. `tests/conformance/formatting-unformatted.forb`
  formats exactly to `tests/conformance/formatting.forb`, and
  `formatting-comments-unformatted.forb` to `formatting-comments.forb` (every placement above).
- The build's scenarios run `forbic fmt --check` on those fixtures and on
  `formatting-error.forb`, which the lexer refuses.
- `src/tooling/format_command.zig`: in-place rewrite, `--check`, standard input, errors and the
  command lines it refuses.

## Not done

No reflowing of long lines or of arguments over several lines; no reordering, sorting or
normalising of anything the lexer keeps (names, numbers, string spellings); no formatting of
bundles (`--bundle` packets) as a whole: format their files one by one.
