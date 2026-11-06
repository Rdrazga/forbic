//! `char`, `char32` and the `[]char` view of `string` (RFC-0069): literals, indexing, slicing,
//! iteration, conversions, keys and patterns, with both machines and the report replay checked
//! against each other by the harness and against `std.unicode` by the oracle.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");
const harness = @import("generic_function_tests.zig");

const char = types.Type.char;
const char32 = types.Type.char32;

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const result = h.front.compile(source);
    if (result == .ok) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code) std.debug.print("got {s}, expected {s}: {s}\n", .{ @tagName(result.failed.code), @tagName(code), source });
    try std.testing.expectEqual(code, result.failed.code);
}
fn expectCharacter(x: evaluator.Execution, name: []const u8, value_type: types.Type, code: u32) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(types.Value{ .enumeration = .{ .value_type = value_type, .index = code } }, value);
}
fn expectInteger(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    if (value != .integer or value.integer != expected) std.debug.print("{s}: {any}, expected {d}\n", .{ name, value, expected });
    try std.testing.expectEqual(expected, value.integer);
}
fn expectString(x: evaluator.Execution, name: []const u8, expected: []const u8) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, value.string);
}
fn expectLogic(x: evaluator.Execution, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse return error.TestUnexpectedResult;
    if (value.boolean != expected) std.debug.print("{s}: expected {}\n", .{ name, expected });
    try std.testing.expectEqual(expected, value.boolean);
}
/// The codes of an array of characters, which must all have the type `value_type`.
fn expectCharacters(x: evaluator.Execution, name: []const u8, value_type: types.Type, expected: []const u32) !void {
    const range = (x.get(name) orelse return error.TestUnexpectedResult).aggregate.elements;
    try std.testing.expectEqual(expected.len, range.end - range.start);
    for (expected, x.aggregate_values[range.start..range.end]) |want, got| {
        try std.testing.expectEqualDeep(types.Value{ .enumeration = .{ .value_type = value_type, .index = want } }, got);
    }
}
fn expectIntegers(x: evaluator.Execution, name: []const u8, expected: []const i64) !void {
    const range = (x.get(name) orelse return error.TestUnexpectedResult).aggregate.elements;
    try std.testing.expectEqual(expected.len, range.end - range.start);
    for (expected, x.aggregate_values[range.start..range.end]) |want, got| try std.testing.expectEqual(want, got.integer);
}

test "character literals have the Book's types and values" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A:char='a'
        \\Tab:char='\t'
        \\Quote:char='\''
        \\Brace:char='\{'
        \\Hex:char=0o61
        \\High:char=0oFF
        \\Accent:char32='é'
        \\Emoji:char32='😀'
        \\Wide:char32=0u1f600
        \\Low:char32=0u65
        \\Inferred:='z'
        \\Same:logic=A==Hex
        \\Differ:logic=A!='b'
        \\SameWide:logic=Emoji==Wide
    );
    try expectCharacter(x, "A", char, 'a');
    try expectCharacter(x, "Tab", char, '\t');
    try expectCharacter(x, "Quote", char, '\'');
    try expectCharacter(x, "Brace", char, '{');
    try expectCharacter(x, "Hex", char, 0x61);
    try expectCharacter(x, "High", char, 0xFF);
    try expectCharacter(x, "Accent", char32, 0xE9);
    try expectCharacter(x, "Emoji", char32, 0x1F600);
    try expectCharacter(x, "Wide", char32, 0x1F600);
    try expectCharacter(x, "Low", char32, 0x65);
    try expectCharacter(x, "Inferred", char, 'z');
    try expectLogic(x, "Same", true);
    try expectLogic(x, "Differ", true);
    try expectLogic(x, "SameWide", true);
    // No implicit conversion between the character types, or to and from integers.
    try expectCode(h, "C:char='é'", .type_mismatch);
    try expectCode(h, "C:char32='e'", .type_mismatch);
    try expectCode(h, "C:char=97", .type_mismatch);
    try expectCode(h, "N:i64='a'", .type_mismatch);
    try expectCode(h, "B:logic='a'==0u61", .type_mismatch);
    try expectCode(h, "B:logic='a'==97", .type_mismatch);
    try expectCode(h, "N:i64='a'+1", .type_mismatch);
    // The Book orders `int` and `float` only.
    try expectCode(h, "B:logic='a'<'b'", .type_mismatch);
    try expectCode(h, "B:logic=\"a\"<\"b\"", .type_mismatch);
    try expectCode(h, "C:char32=0uD800", .invalid_char_literal);
    try expectCode(h, "C:char32=0u110000", .invalid_char_literal);
    try expectCode(h, "C:char=''", .invalid_char_literal);
    try expectCode(h, "C:char='ab'", .invalid_char_literal);
}

test "a string is indexed, measured and sliced by code unit, and a slice never splits a scalar" {
    const h = try harness.create();
    defer scratch.release(h);
    // "José" is J o s C3 A9: five code units, four scalar values.
    const x = try h.execute(
        \\S:string="José"
        \\E:string=""
        \\N:i64=S.Length
        \\C0:char=Attempt(S[0],'?')
        \\C3:char=Attempt(S[3],'?')
        \\C4:char=Attempt(S[4],'?')
        \\C5:char=Attempt(S[5],'?')
        \\Neg:char=Attempt(S[0-1],'?')
        \\EmptyAt:char=Attempt(E[0],'?')
        \\Mid:string=Attempt(S.Slice[1,3],"!")
        \\Tail:string=Attempt(S.Slice[3],"!")
        \\Whole:string=Attempt(S.Slice[0,5],"!")
        \\All:string=Attempt(S.Slice[0],"!")
        \\End:string=Attempt(S.Slice[5],"!")
        \\SplitEnd:string=Attempt(S.Slice[0,4],"!")
        \\SplitStart:string=Attempt(S.Slice[4,5],"!")
        \\SplitTail:string=Attempt(S.Slice[4],"!")
        \\Zero:string=Attempt(S.Slice[2,2],"!")
        \\ZeroInside:string=Attempt(S.Slice[4,4],"!")
        \\ZeroEnd:string=Attempt(S.Slice[5,5],"!")
        \\Backwards:string=Attempt(S.Slice[3,1],"!")
        \\Past:string=Attempt(S.Slice[0,6],"!")
        \\PastEmpty:string=Attempt(S.Slice[6,6],"!")
        \\PastStart:string=Attempt(S.Slice[6],"!")
        \\Negative:string=Attempt(S.Slice[0-1,2],"!")
        \\NegativeEmpty:string=Attempt(S.Slice[0-1,0-1],"!")
        \\OfEmpty:string=Attempt(E.Slice[0,0],"!")
        \\OfEmptyAll:string=Attempt(E.Slice[0],"!")
        \\OfEmptyPast:string=Attempt(E.Slice[0,1],"!")
        \\Nested:string=Attempt(S.Slice[1].Slice[1,2],"!")
        \\Joined:string=Attempt(S.Slice[0,3]+S.Slice[3],"!")
        \\Rejoined:logic=Joined==S
        \\MidLength:i64=Mid.Length
        \\First(T:string)<computes><decides>:char=T[0]
        \\Head:char=Attempt(First[S],'?')
        \\NoHead:char=Attempt(First[E],'?')
    );
    try expectInteger(x, "N", 5);
    try expectCharacter(x, "C0", char, 'J');
    try expectCharacter(x, "C3", char, 0xC3);
    try expectCharacter(x, "C4", char, 0xA9);
    try expectCharacter(x, "C5", char, '?');
    try expectCharacter(x, "Neg", char, '?');
    try expectCharacter(x, "EmptyAt", char, '?');
    try expectString(x, "Mid", "os");
    try expectString(x, "Tail", "é");
    try expectString(x, "Whole", "José");
    try expectString(x, "All", "José");
    try expectString(x, "End", "");
    try expectString(x, "SplitEnd", "!");
    try expectString(x, "SplitStart", "!");
    try expectString(x, "SplitTail", "!");
    try expectString(x, "Zero", "");
    try expectString(x, "ZeroInside", "");
    try expectString(x, "ZeroEnd", "");
    try expectString(x, "Backwards", "!");
    try expectString(x, "Past", "!");
    try expectString(x, "PastEmpty", "!");
    try expectString(x, "PastStart", "!");
    try expectString(x, "Negative", "!");
    try expectString(x, "NegativeEmpty", "!");
    try expectString(x, "OfEmpty", "");
    try expectString(x, "OfEmptyAll", "");
    try expectString(x, "OfEmptyPast", "!");
    try expectString(x, "Nested", "s");
    try expectString(x, "Joined", "José");
    try expectLogic(x, "Rejoined", true);
    try expectInteger(x, "MidLength", 2);
    try expectCharacter(x, "Head", char, 'J');
    try expectCharacter(x, "NoHead", char, '?');
    // A slice is a view of its string: the bytes of `Mid` are bytes of `S`, and the only bytes
    // the run added to the pool are the ones the join copied.
    const s = x.get("S").?.string;
    const mid = x.get("Mid").?.string;
    try std.testing.expectEqual(@intFromPtr(s.ptr) + 1, @intFromPtr(mid.ptr));
    const compiled = try h.compile("S:string=\"José\"\nMid:string=Attempt(S.Slice[1,3],\"!\")\nTail:string=Attempt(S.Slice[3],\"!\")");
    const run = (try h.run(compiled, 10_000)).ok;
    try std.testing.expectEqual(compiled.strings.len, run.program.strings.len);
    // Indexing and slicing can fail, so they need a failure context, and take integers.
    try expectCode(h, "S:string=\"ab\"\nC:char=S[0]", .failure_context_required);
    try expectCode(h, "S:string=\"ab\"\nT:string=S.Slice[0,1]", .failure_context_required);
    try expectCode(h, "S:string=\"ab\"\nC:char=Attempt(S[\"a\"],'?')", .type_mismatch);
    try expectCode(h, "S:string=\"ab\"\nT:string=Attempt(S.Slice['a'],\"\")", .type_mismatch);
    try expectCode(h, "S:string=\"ab\"\nT:string=Attempt(S.Slice[0,1,2],\"\")", .argument_count);
    try expectCode(h, "S:string=\"ab\"\nT:string=Attempt(S.Slice[],\"\")", .expected_expression);
    try expectCode(h, "S:string=\"ab\"\nT:string=Attempt(S.Slice(0,1),\"\")", .expected_call);
    try expectCode(h, "S:string=\"ab\"\nN:i64=S.Size", .unknown_field);
    try expectCode(h, "C:char='a'\nN:i64=C.Length", .unknown_field);
    // A string and an array of its code units are different types.
    try expectCode(h, "B:logic=\"abc\"==array{'a','b','c'}", .type_mismatch);
    // A position is an expression like any other: a conditional, a block, a call, inside an
    // aggregate or an argument list, with commas that belong to the slice.
    const y = try h.execute(
        \\S:string="hello"
        \\Two(N:i64)<computes>:i64=N+N
        \\A:char=Attempt(S[If(S.Length>3,Two(2),0)],'?')
        \\B:string=Attempt(S.Slice[Block{K:i64=1;K},If(true,4,5)],"!")
        \\C:option(string)=Attempt(option{S.Slice[1,4]},option{})
        \\D:[]string=Attempt(array{S.Slice[0,1],S.Slice[1,2]},array{})
        \\Join(X:string,Y:string)<computes>:string=X+Y
        \\E:string=Attempt(Join(S.Slice[3,5],S.Slice[0,3]),"!")
        \\F:tuple(string,char)=Attempt(tuple{S.Slice[Two(1),Two(2)],S[Two(2)]},tuple{"!",'?'})
    );
    try expectCharacter(y, "A", char, 'o');
    try expectString(y, "B", "ell");
    try expectString(y, "E", "lohel");
    const c = y.get("C").?.aggregate.elements;
    try std.testing.expectEqualStrings("ell", y.aggregate_values[c.start].string);
    const d = y.get("D").?.aggregate.elements;
    try std.testing.expectEqualStrings("h", y.aggregate_values[d.start].string);
    try std.testing.expectEqualStrings("e", y.aggregate_values[d.start + 1].string);
    const f = y.get("F").?.aggregate.elements;
    try std.testing.expectEqualStrings("ll", y.aggregate_values[f.start].string);
    try std.testing.expectEqualDeep(types.characterValue(char, 'o'), y.aggregate_values[f.start + 1]);
}

test "For visits code units, ScalarAt finds scalar values, and units become a string again" {
    const h = try harness.create();
    defer scratch.release(h);
    // "aé😀" is 61 | C3 A9 | F0 9F 98 80: seven code units, three scalar values.
    const x = try h.execute(
        \\S:string="aé😀"
        \\Units:[]char=For(C:S,C)
        \\Positions:[]i64=For(I->C:S,I)
        \\Ascii:[]char=For(C:S,C.ToCodeUnit()<128,C)
        \\Scalars:[]char32=For(I->C:S,R:=S.ScalarAt[I],R)
        \\Starts:[]i64=For(I->C:S,R:=S.ScalarAt[I],I)
        \\Points:[]i64=For(I->C:S,R:=S.ScalarAt[I],R.ToCodePoint())
        \\Back:string=Attempt(string[Units],"!")
        \\RoundTrip:logic=Back==S
        \\Rest:string=Attempt(string[For(C:S,C.ToCodeUnit()>=128,C)],"!")
        \\Truncated:string=Attempt(string[For(I->C:S,I<2,C)],"!")
        \\Lone:string=Attempt(string[array{0oC3}],"!")
        \\Continuation:string=Attempt(string[array{0oA9}],"!")
        \\Overlong:string=Attempt(string[array{0oC0,0o80}],"!")
        \\Surrogate:string=Attempt(string[array{0oED,0oA0,0o80}],"!")
        \\TooLarge:string=Attempt(string[array{0oF4,0o90,0o80,0o80}],"!")
        \\Largest:string=Attempt(string[array{0oF4,0o8F,0oBF,0oBF}],"!")
        \\None:[]char=For(C:"",C)
        \\Empty:string=Attempt(string[None],"!")
        \\NoScalars:[]char32=For(I->C:"",R:=""  .ScalarAt[I],R)
        \\Rebuilt:string=Attempt(string[For(C:"héllo",C)],"!")
        \\First:char32=Attempt(S.ScalarAt[0],0u3F)
        \\Second:char32=Attempt(S.ScalarAt[1],0u3F)
        \\Inside:char32=Attempt(S.ScalarAt[2],0u3F)
        \\Third:char32=Attempt(S.ScalarAt[3],0u3F)
        \\AtEnd:char32=Attempt(S.ScalarAt[7],0u3F)
        \\Before:char32=Attempt(S.ScalarAt[0-1],0u3F)
        \\Vowels(T:string)<computes>:i64=For(C:T,C=='a' or C=='e' or C=='i' or C=='o' or C=='u',1).Length
        \\Counted:i64=Vowels("education")
        \\Pairs:[]i64=For(C:"ab",D:"xy",C.ToCodeUnit()*1000+D.ToCodeUnit())
    );
    try expectCharacters(x, "Units", char, &.{ 0x61, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80 });
    try expectIntegers(x, "Positions", &.{ 0, 1, 2, 3, 4, 5, 6 });
    try expectCharacters(x, "Ascii", char, &.{0x61});
    try expectCharacters(x, "Scalars", char32, &.{ 0x61, 0xE9, 0x1F600 });
    try expectIntegers(x, "Starts", &.{ 0, 1, 3 });
    try expectIntegers(x, "Points", &.{ 0x61, 0xE9, 0x1F600 });
    try expectString(x, "Back", "aé😀");
    try expectLogic(x, "RoundTrip", true);
    try expectString(x, "Rest", "é😀");
    try expectString(x, "Truncated", "!");
    try expectString(x, "Lone", "!");
    try expectString(x, "Continuation", "!");
    try expectString(x, "Overlong", "!");
    try expectString(x, "Surrogate", "!");
    try expectString(x, "TooLarge", "!");
    try expectString(x, "Largest", "\u{10FFFF}");
    try expectCharacters(x, "None", char, &.{});
    try expectString(x, "Empty", "");
    try expectCharacters(x, "NoScalars", char32, &.{});
    try expectString(x, "Rebuilt", "héllo");
    try expectCharacter(x, "First", char32, 0x61);
    try expectCharacter(x, "Second", char32, 0xE9);
    try expectCharacter(x, "Inside", char32, 0x3F);
    try expectCharacter(x, "Third", char32, 0x1F600);
    try expectCharacter(x, "AtEnd", char32, 0x3F);
    try expectCharacter(x, "Before", char32, 0x3F);
    try expectInteger(x, "Counted", 5);
    try expectIntegers(x, "Pairs", &.{ 97120, 97121, 98120, 98121 });
    // Every string of the run, the rejected ones included, left the pool valid UTF-8.
    try std.testing.expect(std.unicode.utf8ValidateSlice(x.program.strings));
    try expectCode(h, "S:string=Attempt(string[array{1,2}],\"\")", .type_mismatch);
    try expectCode(h, "S:string=Attempt(string[\"ab\"],\"\")", .type_mismatch);
    try expectCode(h, "S:string=string[array{'a'}]", .failure_context_required);
    try expectCode(h, "S:string=Attempt(string(array{'a'}),\"\")", .not_callable);
    try expectCode(h, "R:char32=Attempt(\"a\".ScalarAt[],0u3F)", .expected_expression);
    try expectCode(h, "R:char32=Attempt(\"a\".ScalarAt[0,1],0u3F)", .argument_count);
}

test "characters convert as the Book defines, and to text without ever making invalid UTF-8" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A:char='a'
        \\Unit:i64=A.ToCodeUnit()
        \\Point:i64='😀'.ToCodePoint()
        \\N:i64=255
        \\FromInt:char=Attempt((65).ToChar[],'?')
        \\Top:char=Attempt(N.ToChar[],'?')
        \\Over:char=Attempt((256).ToChar[],'?')
        \\Under:char=Attempt((0-1).ToChar[],'?')
        \\Zero:char=Attempt((0).ToChar[],'?')
        \\Wide:char32=Attempt((233).ToChar32[],0u3F)
        \\WideTop:char32=Attempt((1114111).ToChar32[],0u3F)
        \\WideOver:char32=Attempt((1114112).ToChar32[],0u3F)
        \\WideUnder:char32=Attempt((0-1).ToChar32[],0u3F)
        \\SurrogateLow:char32=Attempt((55296).ToChar32[],0u3F)
        \\SurrogateHigh:char32=Attempt((57343).ToChar32[],0u3F)
        \\BelowSurrogates:char32=Attempt((55295).ToChar32[],0u3F)
        \\AboveSurrogates:char32=Attempt((57344).ToChar32[],0u3F)
        \\Widened:char32=Attempt(A.ToAsciiChar32[],0u3F)
        \\NotAscii:char32=Attempt(0oC3.ToAsciiChar32[],0u3F)
        \\Del:char32=Attempt(0o7F.ToAsciiChar32[],0u3F)
        \\Encoded:string='é'.ToAsciiString()
        \\EncodedLength:i64='😀'.ToAsciiString().Length
        \\Text:string=ToString(A)
        \\Replaced:string=ToString(0oC3)
        \\WideText:string=ToString('😀')
        \\Shown:string="<{A}{'é'}{0o80}>"
        \\Back:i64=Attempt(Unit.ToChar[],'?').ToCodeUnit()
    );
    try expectInteger(x, "Unit", 97);
    try expectInteger(x, "Point", 0x1F600);
    try expectCharacter(x, "FromInt", char, 'A');
    try expectCharacter(x, "Top", char, 0xFF);
    try expectCharacter(x, "Over", char, '?');
    try expectCharacter(x, "Under", char, '?');
    try expectCharacter(x, "Zero", char, 0);
    try expectCharacter(x, "Wide", char32, 0xE9);
    try expectCharacter(x, "WideTop", char32, 0x10FFFF);
    try expectCharacter(x, "WideOver", char32, 0x3F);
    try expectCharacter(x, "WideUnder", char32, 0x3F);
    try expectCharacter(x, "SurrogateLow", char32, 0x3F);
    try expectCharacter(x, "SurrogateHigh", char32, 0x3F);
    try expectCharacter(x, "BelowSurrogates", char32, 0xD7FF);
    try expectCharacter(x, "AboveSurrogates", char32, 0xE000);
    try expectCharacter(x, "Widened", char32, 0x61);
    try expectCharacter(x, "NotAscii", char32, 0x3F);
    try expectCharacter(x, "Del", char32, 0x7F);
    try expectString(x, "Encoded", "é");
    try expectInteger(x, "EncodedLength", 4);
    try expectString(x, "Text", "a");
    try expectString(x, "Replaced", "\u{FFFD}");
    try expectString(x, "WideText", "😀");
    try expectString(x, "Shown", "<aé\u{FFFD}>");
    try expectInteger(x, "Back", 97);
    try std.testing.expect(std.unicode.utf8ValidateSlice(x.program.strings));
    // A method belongs to one type, is called the way its failure says, and takes no argument.
    try expectCode(h, "N:i64='é'.ToCodeUnit()", .unknown_field);
    try expectCode(h, "N:i64='a'.ToCodePoint()", .unknown_field);
    try expectCode(h, "C:char=(65).ToChar()", .expected_call);
    try expectCode(h, "C:char=(65).ToChar[]", .failure_context_required);
    try expectCode(h, "N:i64='a'.ToCodeUnit[]", .expected_call);
    try expectCode(h, "N:i64='a'.ToCodeUnit(1)", .argument_count);
    try expectCode(h, "C:char=Attempt((1.5).ToChar[],'?')", .type_mismatch);
    try expectCode(h, "S:string=ToString(array{'a'})", .type_mismatch);
    // Writing one code unit of a string is not offered yet; it is a type error, not a crash.
    try expectCode(h, "F()<transacts>:string=Block{var S:string=\"ab\";set S[0]='F';S}", .type_mismatch);
    try expectCode(h, "S:string=Attempt(string[array{}],\"\")", .array_type_required);
}

test "characters are comparable: map keys, Case patterns, fields, cells and rollback" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Counts:map(char,i64)=map{'a'=>1,'b'=>2}
        \\Got:i64=Or(Lookup(Counts,'b'),0)
        \\Missing:i64=Or(Lookup(Counts,'c'),0)
        \\Names:map(char32,string)=map{'é'=>"e-acute",'😀'=>"grin"}
        \\Name:string=Attempt(Names['😀'],"?")
        \\Tally(T:string)<transacts>:map(char,i64)=Block{
        \\  var M:map(char,i64)=map{}
        \\  var I:i64=0
        \\  While(I<T.Length,Block{C:char=Attempt(T[I],'?');set M[C]=Or(Lookup(M,C),0)+1;set I=I+1})
        \\  M
        \\}
        \\Letters:map(char,i64)=Tally("banana")
        \\As:i64=Or(Lookup(Letters,'a'),0)
        \\Ns:i64=Or(Lookup(Letters,'n'),0)
        \\Kinds:i64=Letters.Length
        \\Kind(C:char)<computes>:i64=Case(C,'a'=>1,'\n'=>2,0o7A=>3,_=>0)
        \\K1:i64=Kind('a')
        \\K2:i64=Kind('\n')
        \\K3:i64=Kind('z')
        \\K4:i64=Kind('q')
        \\Wide(R:char32)<computes>:string=Case(R,'é'=>"accent",0u1F600=>"grin",_=>"other")
        \\W1:string=Wide('é')
        \\W2:string=Wide('😀')
        \\W3:string=Wide(0u41)
        \\glyph:=struct{Unit:char,Scalar:char32}
        \\G:glyph=glyph{Unit:='x',Scalar:='é'}
        \\Field:char=G.Unit
        \\Pair:tuple(char,char32)=tuple{'x','é'}
        \\Maybe:option(char)=option{'q'}
        \\Inner:char=Or(Maybe,'?')
        \\SameRecord:logic=G==glyph{Unit:='x',Scalar:=0uE9}
        \\SameArray:logic=array{'a','b'}==array{0o61,0o62}
        \\ByPair:map(tuple(char,char32),i64)=map{tuple{'x','é'}=>7}
        \\Found:i64=Or(Lookup(ByPair,Pair),0)
        \\var Last:char='-'
        \\Kept:char=Attempt(Block{Set(Last,'z');Require[1>2];Last},Last)
        \\Written:char=Attempt(Block{Set(Last,'y');Require[1<2];Last},'!')
        \\Final:char=Last
        \\Id[T:type](X:T)<computes>:T{X}
        \\Generic:char32=Id[char32]('é')
    );
    try expectInteger(x, "Got", 2);
    try expectInteger(x, "Missing", 0);
    try expectString(x, "Name", "grin");
    try expectInteger(x, "As", 3);
    try expectInteger(x, "Ns", 2);
    try expectInteger(x, "Kinds", 3);
    try expectInteger(x, "K1", 1);
    try expectInteger(x, "K2", 2);
    try expectInteger(x, "K3", 3);
    try expectInteger(x, "K4", 0);
    try expectString(x, "W1", "accent");
    try expectString(x, "W2", "grin");
    try expectString(x, "W3", "other");
    try expectCharacter(x, "Field", char, 'x');
    try expectCharacter(x, "Inner", char, 'q');
    try expectLogic(x, "SameRecord", true);
    try expectLogic(x, "SameArray", true);
    try expectInteger(x, "Found", 7);
    try expectCharacter(x, "Kept", char, '-');
    try expectCharacter(x, "Written", char, 'y');
    try expectCharacter(x, "Final", char, 'y');
    try expectCharacter(x, "Generic", char32, 0xE9);
    // Equal characters are equal keys, and the two character types do not mix in one map.
    const duplicate = try h.compile("M:map(char,i64)=map{'a'=>1,0o61=>2}");
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_map_key, (try h.run(duplicate, 10_000)).failed.code);
    try expectCode(h, "M:map(char,i64)=map{'a'=>1,'é'=>2}", .type_mismatch);
    try expectCode(h, "K(C:char)<computes>:i64=Case(C,'é'=>1,_=>0)", .type_mismatch);
}

test "programs that use char as a name keep their meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    // `char` and `char32` are not reserved words: a binding, a parameter, a function and a
    // user type of either name are what they were before the character types existed.
    const x = try h.execute(
        \\char:i64=3
        \\char32(N:i64)<computes>:i64=N+char
        \\Slice(N:i64)<computes>:i64=N*2
        \\ToChar(N:i64)<computes>:i64=N+1
        \\ScalarAt:i64=5
        \\A:i64=char32(4)+Slice(ScalarAt)+ToChar(1)
    );
    try expectInteger(x, "A", 7 + 10 + 2);
    const y = try h.execute(
        \\char:=struct{Code:i64}
        \\char32:=enum{Low,High}
        \\C:char=char{Code:=9}
        \\N:i64=C.Code
        \\K:char32=char32.High
        \\Is:logic=K==char32.High
    );
    try expectInteger(y, "N", 9);
    try expectLogic(y, "Is", true);
    // With such a type declared, a character literal is still a builtin character and so no value of it.
    try expectCode(h, "char:=struct{Code:i64}\nC:char='a'", .type_mismatch);
    // `0or` is still an integer and the operator.
    const z = try h.execute("B:logic=1==0or 2==2");
    try expectLogic(z, "B", true);
}

/// The first node of `p` that is the text operation `op`.
fn textNode(p: types.Program, op: types.TextOp) u32 {
    for (p.nodes, 0..) |node, index| if (node.kind == .text and node.kind.text.op == op) return @intCast(index);
    unreachable;
}
/// The first text operation `op` that makes a value of type `result`.
fn textNodeOf(p: types.Program, op: types.TextOp, result: types.Type) u32 {
    for (p.nodes, 0..) |node, index| if (node.kind == .text and node.kind.text.op == op and node.value_type == result) return @intCast(index);
    unreachable;
}
fn bindingNode(p: types.Program, name: []const u8) u32 {
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), name)) return binding.node;
    unreachable;
}

const forging_source =
    \\S:string="aé"
    \\Inside:i64=2
    \\Big:i64=300
    \\Surrogate:i64=55296
    \\Negative:i64=0-1
    \\One:i64=1
    \\Broken:[]char=array{0oC3}
    \\Whole:[]char=array{'a'}
    \\Numbers:[]i64=array{1}
    \\C:char=Attempt(S[0],'?')
    \\T:string=Attempt(S.Slice[0,1],"!")
    \\R:char32=Attempt(S.ScalarAt[0],0u3F)
    \\K:char=Attempt((65).ToChar[],'?')
    \\W:char32=Attempt((65).ToChar32[],0u3F)
    \\J:string=Attempt(string[Whole],"!")
    \\N:i64=C.ToCodeUnit()
    \\P:i64=R.ToCodePoint()
    \\Shown:string=ToString(C)
;

test "forged character constants outside their type are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("A:char='a'\nB:char32='é'\nM:=enum{X,Y}\nE:M=M.Y");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    const a = bindingNode(p, "A");
    const b = bindingNode(p, "B");
    const e = bindingNode(p, "E");
    _ = try h.run(forged, 10_000);
    // A `char` is a byte; a `char32` is a scalar value: no surrogate, nothing past U+10FFFF.
    for ([_]u32{ 0x100, 300, 0xD800, 0x10FFFF, std.math.maxInt(u32) }) |code| {
        nodes[a].kind = .{ .character = code };
        try harness.invalid(h, forged);
    }
    nodes[a] = p.nodes[a];
    for ([_]u32{ 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0x110000, std.math.maxInt(u32) }) |code| {
        nodes[b].kind = .{ .character = code };
        try harness.invalid(h, forged);
    }
    // The edges of the scalar values are values.
    for ([_]u32{ 0, 0xD7FF, 0xE000, 0x10FFFF }) |code| {
        nodes[b].kind = .{ .character = code };
        const x = (try h.run(forged, 10_000)).ok;
        try std.testing.expectEqual(code, x.get("B").?.enumeration.index);
    }
    nodes[b] = p.nodes[b];
    for ([_]u32{ 0, 0x7F, 0x80, 0xFF }) |code| {
        nodes[a].kind = .{ .character = code };
        const x = (try h.run(forged, 10_000)).ok;
        try std.testing.expectEqual(code, x.get("A").?.enumeration.index);
    }
    nodes[a] = p.nodes[a];
    // A character constant is of a character type, and an enum case is not a character.
    nodes[e].kind = .{ .character = 1 };
    try harness.invalid(h, forged);
    nodes[e] = p.nodes[e];
    nodes[a].kind = .{ .enumeration = 0 };
    try harness.invalid(h, forged);
    nodes[a] = p.nodes[a];
    nodes[a].kind = .{ .integer = 97 };
    try harness.invalid(h, forged);
    nodes[a] = p.nodes[a];
    _ = try h.run(forged, 10_000);
}

test "forged text operations are rejected at admission by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forging_source);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 10_000);
    const string = bindingNode(p, "S");
    const integer = bindingNode(p, "Inside");
    const units = bindingNode(p, "Whole");
    const numbers = bindingNode(p, "Numbers");
    const Change = struct { op: types.TextOp, result: ?types.Type = null, a: ?u32 = null, b: ?u32 = null, c: ?u32 = null };
    const far: u32 = @intCast(p.nodes.len);
    const changes = [_]Change{
        // Result types.
        .{ .op = .unit, .result = char32 },
        .{ .op = .unit, .result = .i64 },
        .{ .op = .boundary, .result = .i64 },
        .{ .op = .slice, .result = char },
        .{ .op = .scalar, .result = char },
        .{ .op = .code, .result = char },
        .{ .op = .from_code, .result = .i64 },
        .{ .op = .from_code, .result = .string },
        .{ .op = .valid, .result = .string },
        .{ .op = .join, .result = .logic },
        // Operand types: a string, then positions; a character; an integer; an array of `char`.
        .{ .op = .unit, .a = integer },
        .{ .op = .unit, .b = string },
        .{ .op = .boundary, .a = units },
        .{ .op = .boundary, .b = string },
        .{ .op = .slice, .a = integer },
        .{ .op = .slice, .b = string },
        .{ .op = .slice, .c = string },
        .{ .op = .scalar, .a = units },
        .{ .op = .scalar, .b = units },
        .{ .op = .code, .a = integer },
        .{ .op = .code, .a = string },
        .{ .op = .from_code, .a = string },
        .{ .op = .valid, .a = string },
        .{ .op = .valid, .a = numbers },
        .{ .op = .join, .a = string },
        .{ .op = .join, .a = numbers },
        // Operands the operation does not take are zero: one encoding per operation.
        .{ .op = .unit, .c = 1 },
        .{ .op = .boundary, .c = 1 },
        .{ .op = .scalar, .c = 1 },
        .{ .op = .code, .b = 1 },
        .{ .op = .code, .c = 1 },
        .{ .op = .from_code, .b = 1 },
        .{ .op = .valid, .b = 1 },
        .{ .op = .join, .c = 1 },
        // Registers that do not exist.
        .{ .op = .unit, .a = far },
        .{ .op = .unit, .b = far },
        .{ .op = .slice, .c = far },
        .{ .op = .code, .a = far },
        .{ .op = .from_code, .a = far },
        .{ .op = .valid, .a = far },
        .{ .op = .join, .a = far },
    };
    for (changes) |change| {
        const at = textNode(p, change.op);
        if (change.result) |result| nodes[at].value_type = result;
        if (change.a) |a| nodes[at].kind.text.a = a;
        if (change.b) |b| nodes[at].kind.text.b = b;
        if (change.c) |c| nodes[at].kind.text.c = c;
        harness.invalid(h, forged) catch |err| {
            std.debug.print("admitted: {any}\n", .{change});
            return err;
        };
        nodes[at] = p.nodes[at];
    }
    // An operand that is its own or a later register.
    for ([_]types.TextOp{ .unit, .boundary, .slice, .scalar, .code, .from_code, .valid, .join }) |op| {
        const at = textNode(p, op);
        nodes[at].kind.text.a = at;
        try harness.invalid(h, forged);
        nodes[at] = p.nodes[at];
    }
    // `ToString` takes numbers, logic and characters, nothing else.
    for (nodes, 0..) |node, index| if (node.kind == .to_string) {
        nodes[index].kind = .{ .to_string = units };
        try harness.invalid(h, forged);
        nodes[index] = p.nodes[index];
    };
    // A value read out of an arm that did not have to run: `N` takes the code of `C`, and the
    // unit read inside `C`'s attempt is a `char` too, but it is not available after the merge.
    const code = textNode(p, .code);
    nodes[code].kind.text.a = textNode(p, .unit);
    try harness.invalid(h, forged);
    nodes[code] = p.nodes[code];
    _ = try h.run(forged, 10_000);
}

test "forged text operations that pass admission trap alike in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forging_source);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    const inside = bindingNode(p, "Inside");
    const big = bindingNode(p, "Big");
    const surrogate = bindingNode(p, "Surrogate");
    const negative = bindingNode(p, "Negative");
    const one = bindingNode(p, "One");
    // The compiler's `demand` still tests the operands it was given, so each forged operation
    // below runs on a value its guard never saw.
    const unit = textNode(p, .unit);
    for ([_]u32{ big, negative }) |position| {
        // A unit read has no guard inside a loop either: outside the string is fatal, not undefined.
        nodes[unit].kind.text.b = position;
        try std.testing.expectEqual(types.Diagnostic.Code.index_out_of_range, (try h.run(forged, 10_000)).failed.code);
    }
    nodes[unit] = p.nodes[unit];
    const slice = textNode(p, .slice);
    const slices = [_][2]u32{
        .{ nodes[slice].kind.text.b, inside }, // ends inside the two bytes of é
        .{ inside, nodes[slice].kind.text.c }, // backwards
        .{ inside, big }, // starts inside é and ends past the string
        .{ nodes[slice].kind.text.b, big }, // ends past the string
        .{ negative, one }, // starts before the string
        .{ negative, negative }, // empty, but nowhere in the string
        .{ big, big },
    };
    for (slices) |positions| {
        nodes[slice].kind.text.b = positions[0];
        nodes[slice].kind.text.c = positions[1];
        try harness.traps(h, forged, 10_000);
    }
    nodes[slice] = p.nodes[slice];
    const scalar = textNode(p, .scalar);
    for ([_]u32{ inside, big, negative }) |position| {
        nodes[scalar].kind.text.b = position;
        try harness.traps(h, forged, 10_000);
    }
    nodes[scalar] = p.nodes[scalar];
    // An integer that is no value of the character type.
    const narrow = textNodeOf(p, .from_code, char);
    for ([_]u32{ big, negative, surrogate }) |operand| {
        nodes[narrow].kind.text.a = operand;
        try harness.traps(h, forged, 10_000);
    }
    nodes[narrow] = p.nodes[narrow];
    var wide: u32 = 0;
    for (p.nodes, 0..) |node, index| {
        if (node.kind == .text and node.kind.text.op == .from_code and node.value_type == char32 and p.nodes[node.kind.text.a].kind == .integer) wide = @intCast(index);
    }
    for ([_]u32{ surrogate, negative }) |operand| {
        nodes[wide].kind.text.a = operand;
        try harness.traps(h, forged, 10_000);
    }
    nodes[wide].kind.text.a = big; // U+012C is a scalar value
    try std.testing.expectEqual(@as(u32, 300), (try h.run(forged, 10_000)).ok.get("W").?.enumeration.index);
    nodes[wide] = p.nodes[wide];
    // Units that are not text never become a string.
    const join = textNode(p, .join);
    nodes[join].kind.text.a = bindingNode(p, "Broken");
    try harness.traps(h, forged, 10_000);
    nodes[join] = p.nodes[join];
    _ = try h.run(forged, 10_000);
}

test "a report rejects forged characters and text results" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(forging_source ++
        \\
        \\Maybe:option(char)=option{'q'}
        \\Chosen:char=Or(Maybe,'?')
        \\Units:[]char=For(V:"aé",V)
        \\Valid:logic=Attempt(Block{string[Units];true},false)
        \\Tail(Text:string)<computes><decides>:string=Text.Slice[1]
        \\Rest:string=Attempt(Tail[S],"!")
    );
    const p = x.program;
    const values = try std.testing.allocator.dupe(types.Value, x.values);
    defer std.testing.allocator.free(values);
    const members = try std.testing.allocator.dupe(types.Value, x.aggregate_values);
    defer std.testing.allocator.free(members);
    const steps = try std.testing.allocator.dupe(types.CallStep, x.call_steps);
    defer std.testing.allocator.free(steps);
    var forged = x;
    forged.values = values;
    forged.aggregate_values = members;
    forged.call_steps = steps;
    _ = try reporting.validate(forged, false, .{});
    const expectInvalid = struct {
        fn check(execution: evaluator.Execution) !void {
            try std.testing.expectError(error.InvalidExecution, reporting.validate(execution, false, .{}));
        }
    }.check;
    // A character outside its type, wherever it is held. `Chosen` comes out of an option, which
    // no replay recomputes, so only the admission of the value itself can refuse it.
    const chosen = bindingNode(p, "Chosen");
    for ([_]u32{ 0x100, 300, std.math.maxInt(u32) }) |code| {
        values[chosen].enumeration.index = code;
        try expectInvalid(forged);
    }
    values[chosen] = .{ .enumeration = .{ .value_type = char32, .index = 'q' } };
    try expectInvalid(forged);
    values[chosen] = x.values[chosen];
    const c = bindingNode(p, "C");
    values[c].enumeration.index = 300;
    try expectInvalid(forged);
    values[c] = x.values[c];
    const r = bindingNode(p, "R");
    values[r].enumeration.index = 0xD800;
    try expectInvalid(forged);
    values[r].enumeration.index = 0x110000;
    try expectInvalid(forged);
    values[r].enumeration.value_type = char;
    try expectInvalid(forged);
    values[r] = x.values[r];
    for (members, 0..) |member, index| if (member == .enumeration and member.enumeration.value_type == char) {
        members[index].enumeration.index = 0x100;
        try expectInvalid(forged);
        members[index] = member;
        break;
    };
    // A constant that is not the one in the program.
    for (p.nodes, 0..) |node, index| if (node.kind == .character and x.active(index)) {
        values[index].enumeration.index ^= 1;
        try expectInvalid(forged);
        values[index] = x.values[index];
        break;
    };
    // Every text operation is worked out again: another unit, boundary, slice, scalar, code
    // or character than the operands give is not the run that was reported.
    const Wrong = struct { op: types.TextOp, value: types.Value };
    const s = x.get("S").?.string;
    const wrongs = [_]Wrong{
        .{ .op = .unit, .value = types.characterValue(char, 'b') },
        .{ .op = .boundary, .value = .{ .boolean = false } },
        .{ .op = .slice, .value = .{ .string = s[0..3] } },
        .{ .op = .slice, .value = .{ .string = s[1..1] } },
        .{ .op = .scalar, .value = types.characterValue(char32, 0xE9) },
        .{ .op = .code, .value = .{ .integer = 98 } },
        .{ .op = .from_code, .value = types.characterValue(char, 66) },
        .{ .op = .valid, .value = .{ .boolean = false } },
        .{ .op = .join, .value = .{ .string = s[0..1] } },
    };
    for (wrongs) |wrong| {
        var at: u32 = 0;
        for (p.nodes, 0..) |node, index| if (node.kind == .text and node.kind.text.op == wrong.op and x.active(index)) {
            at = @intCast(index);
            break;
        };
        // A forged join is other text of the right length: the `!` of a fallback, from the pool.
        const other = std.mem.indexOfScalar(u8, p.strings, '!').?;
        const value: types.Value = if (wrong.op == .join) .{ .string = p.strings[other .. other + 1] } else wrong.value;
        values[at] = value;
        // The forgery is carried through the `merge` that selects the operation's result, so
        // that nothing but the operation itself contradicts it.
        var merged: ?usize = null;
        for (p.nodes, 0..) |node, index| if (node.kind == .merge and node.kind.merge.left == at) {
            merged = index;
            values[index] = value;
        };
        expectInvalid(forged) catch |err| {
            std.debug.print("report accepted a forged {s}\n", .{@tagName(wrong.op)});
            return err;
        };
        values[at] = x.values[at];
        if (merged) |index| values[index] = x.values[index];
    }
    // The same inside a call: the steps of `Tail` and of the loop over the units.
    var checked: usize = 0;
    for (steps, 0..) |step, index| {
        if (step.kind != .value) continue;
        const f = p.functions[step.function];
        const node = p.function_nodes[f.body.start + step.pc].node;
        if (p.function_nodes[f.body.start + step.pc].input != .operation or node.kind != .text) continue;
        steps[index].value = switch (node.kind.text.op) {
            .unit => types.characterValue(char, step.value.enumeration.index ^ 1),
            .boundary, .valid => .{ .boolean = !step.value.boolean },
            .slice => .{ .string = s[0..1] },
            .scalar => types.characterValue(char32, step.value.enumeration.index ^ 1),
            .code => .{ .integer = step.value.integer + 1 },
            .from_code => types.characterValue(node.value_type, step.value.enumeration.index ^ 1),
            .join => .{ .string = s[0..step.value.string.len] },
        };
        try expectInvalid(forged);
        steps[index] = step;
        checked += 1;
    }
    try std.testing.expect(checked >= 3);
    _ = try reporting.validate(forged, false, .{});
}

test "characters print as their code under a key no field can have, and inspect by name" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\A<public>:char='a'
        \\High<public>:char=0oC3
        \\Wide<public>:char32='😀'
        \\Units<public>:[]char=For(C:"hé",C)
        \\Keys<public>:map(char,string)=map{'k'=>"v"}
        \\Maybe<public>:option(char32)=option{'é'}
        \\Text<public>:string="{A}{High}{Wide}"
    );
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{});
    try std.testing.expectEqualStrings("{\"A\":{\"$char\":97},\"High\":{\"$char\":195},\"Wide\":{\"$char32\":128512},\"Units\":[{\"$char\":104},{\"$char\":195},{\"$char\":169}],\"Keys\":[{\"$char\":107},\"v\"],\"Maybe\":[{\"$char32\":233}],\"Text\":\"a\u{FFFD}😀\"}\n", out.buffered());
    // The type of a register or binding is spelled, and the operations keep their names.
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const p = try h.compile("A:char='a'\nW:char32=Attempt(\"é\".ScalarAt[0],0u3F)\nN:i64=A.ToCodeUnit()");
    const document = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(document);
    var inspected = std.Io.Writer.fixed(document);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&inspected, p));
    const text = inspected.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"char\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"char32\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"character\":97}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"text\":{\"op\":\"scalar\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"text\":{\"op\":\"code\",") != null);
}

/// The least fuel with which `source` completes. Both machines are run at every budget up to
/// it and must stop alike, with the same diagnostic, at each one.
fn threshold(h: *harness.Harness, source: []const u8, ceiling: u64) !u64 {
    const p = try h.compile(source);
    var fuel: u64 = 0;
    while (fuel <= ceiling) : (fuel += 1) {
        const result = try h.run(p, fuel);
        if (result == .ok) return fuel;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
    }
    return error.TestUnexpectedResult;
}

test "fuel is the same in both machines at every budget and proportional to what an operation touches" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [4096]u8 = undefined;
    // Reading a unit, testing a boundary, slicing and decoding a scalar cost the same in a
    // string of ten bytes and in one of a thousand.
    var costs: [2]u64 = undefined;
    for ([_]usize{ 10, 1000 }, &costs) |length, *cost| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("S:string=\"");
        try out.splatByteAll('x', length);
        try out.writeAll("\"\nC:char=Attempt(S[3],'?')\nT:string=Attempt(S.Slice[1,5],\"\")\nU:string=Attempt(S.Slice[2],\"\")\nR:char32=Attempt(S.ScalarAt[2],0u3F)\nN:i64=C.ToCodeUnit()+R.ToCodePoint()");
        cost.* = try threshold(h, out.buffered(), 4096);
    }
    try std.testing.expectEqual(costs[0], costs[1]);
    // Checking units costs one per unit; joining them costs one per unit read and the string's
    // bytes at the rate of every string a run builds, `1 + bytes / 8`.
    var joined: [2]u64 = undefined;
    var plain: [2]u64 = undefined;
    const counts = [_]usize{ 8, 72 };
    for (counts, &joined, &plain) |count, *with, *without| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("U:[]char=array{");
        for (0..count) |index| try out.writeAll(if (index == 0) "'a'" else ",'a'");
        try out.writeAll("}");
        without.* = try threshold(h, out.buffered(), 4096);
        try out.writeAll("\nS:string=Attempt(string[U],\"\")");
        with.* = try threshold(h, out.buffered(), 4096);
    }
    const first = joined[0] - plain[0];
    const second = joined[1] - plain[1];
    try std.testing.expectEqual(@as(u64, 2 * (counts[1] - counts[0]) + (counts[1] / 8 - counts[0] / 8)), second - first);
    // Units that are not text cost the check and no bytes: the `demand` fails before the join.
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeAll("U:[]char=array{");
    for (0..counts[0]) |index| try out.writeAll(if (index == 0) "0o80" else ",'a'");
    try out.writeAll("}\nS:string=Attempt(string[U],\"\")");
    const rejected = try threshold(h, out.buffered(), 4096);
    try std.testing.expect(rejected < joined[0]);
    try std.testing.expectEqual(joined[0] - rejected, 1 + counts[0] + (1 + counts[0] / 8));
    // Text built from characters is charged like any other string.
    const shown = try threshold(h, "A:char='a'\nS:string=ToString(A)", 64);
    const number = try threshold(h, "A:i64=7\nS:string=ToString(A)", 64);
    try std.testing.expectEqual(number, shown);
}

/// An integer as source text. The lexer has no negative literal, so one below zero is a difference.
fn writeInteger(out: *std.Io.Writer, value: i64) !void {
    if (value < 0) try out.print("(0-{d})", .{-value}) else try out.print("{d}", .{value});
}
/// The element of an option binding, or null when it is empty.
fn optionOf(x: evaluator.Execution, comptime prefix: []const u8, index: usize) !?types.Value {
    var name: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&name, prefix ++ "{d}", .{index});
    const range = (x.get(text) orelse return error.TestUnexpectedResult).aggregate.elements;
    return if (range.start == range.end) null else x.aggregate_values[range.start];
}
fn expectOptionString(actual: ?types.Value, expected: ?[]const u8) !void {
    try std.testing.expectEqual(expected == null, actual == null);
    if (expected) |text| try std.testing.expectEqualStrings(text, actual.?.string);
}
fn expectOptionCharacter(actual: ?types.Value, value_type: types.Type, expected: ?u32) !void {
    try std.testing.expectEqual(expected == null, actual == null);
    if (expected) |code| try std.testing.expectEqualDeep(types.Value{ .enumeration = .{ .value_type = value_type, .index = code } }, actual.?);
}

test "random strings and operations agree with std.unicode in both machines and the report" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x74657874);
    const random = prng.random();
    const edges = [_]u21{ '\n', '\t', '"', '\\', '{', '}', '\'', 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF };
    const integers = [_]i64{ -1, 0, 0x7F, 0x80, 0xFF, 0x100, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0x10FFFF, 0x110000, std.math.maxInt(i64), std.math.minInt(i64) + 1 };
    const rounds: usize = 2000;
    const indexed = 3;
    const sliced = 4;
    var operations: usize = 0;
    var kept_slices: usize = 0;
    var kept_joins: usize = 0;
    var source_buffer: [4096]u8 = undefined;
    for (0..rounds) |round| {
        // A string of up to eight scalar values, of every encoded length and at its edges.
        var bytes: [32]u8 = undefined;
        var length: usize = 0;
        for (0..random.uintLessThan(usize, 9)) |_| {
            const scalar: u21 = switch (random.uintLessThan(u8, 8)) {
                0...3 => random.intRangeAtMost(u21, 0x20, 0x7E),
                4 => random.intRangeAtMost(u21, 0x80, 0x7FF),
                5 => pick: {
                    const code = random.intRangeAtMost(u21, 0x800, 0xFFFF);
                    break :pick if (code >= 0xD800 and code <= 0xDFFF) 0x96EA else code;
                },
                6 => random.intRangeAtMost(u21, 0x10000, 0x10FFFF),
                else => edges[random.uintLessThan(usize, edges.len)],
            };
            length += try std.unicode.utf8Encode(scalar, bytes[length..]);
        }
        const text = bytes[0..length];
        const signed: i64 = @intCast(length);
        var out = std.Io.Writer.fixed(&source_buffer);
        try out.writeAll("S:string=\"");
        for (text) |byte| switch (byte) {
            '\n' => try out.writeAll("\\n"),
            '\t' => try out.writeAll("\\t"),
            '"', '\\', '{', '}' => try out.print("\\{c}", .{byte}),
            else => try out.writeByte(byte),
        };
        try out.writeAll(
            \\"
            \\N:i64=S.Length
            \\Units:[]char=For(C:S,C)
            \\Starts:[]i64=For(I->C:S,R:=S.ScalarAt[I],I)
            \\Points:[]i64=For(I->C:S,R:=S.ScalarAt[I],R.ToCodePoint())
            \\Texts:[]string=For(I->C:S,R:=S.ScalarAt[I],ToString(R))
            \\Lengths:[]i64=For(I->C:S,R:=S.ScalarAt[I],R.ToAsciiString().Length)
            \\Back:option(string)=Attempt(option{string[Units]},option{})
            \\
        );
        var positions: [indexed]i64 = undefined;
        for (&positions, 0..) |*position, index| {
            position.* = random.intRangeAtMost(i64, -2, signed + 2);
            try out.print("U{d}:option(char)=Attempt(option{{S[", .{index});
            try writeInteger(&out, position.*);
            try out.print("]}},option{{}})\nQ{d}:option(char32)=Attempt(option{{S.ScalarAt[", .{index});
            try writeInteger(&out, position.*);
            try out.writeAll("]},option{})\n");
        }
        var bounds: [sliced][2]i64 = undefined;
        for (&bounds, 0..) |*bound, index| {
            bound.* = .{ random.intRangeAtMost(i64, -1, signed + 1), random.intRangeAtMost(i64, -1, signed + 1) };
            // Half of the pairs in order, so that most slices are at least plausible.
            if (index % 2 == 0 and bound[0] > bound[1]) std.mem.swap(i64, &bound[0], &bound[1]);
            try out.print("L{d}:option(string)=Attempt(option{{S.Slice[", .{index});
            try writeInteger(&out, bound[0]);
            try out.writeAll(",");
            try writeInteger(&out, bound[1]);
            try out.print("]}},option{{}})\nT{d}:option(string)=Attempt(option{{S.Slice[", .{index});
            try writeInteger(&out, bound[0]);
            try out.writeAll("]},option{})\n");
        }
        // Units to join: random bytes, or the string with one byte changed, dropped or cut off.
        var units: [40]u8 = undefined;
        var unit_count: usize = 0;
        if (length == 0 or random.boolean()) {
            unit_count = random.intRangeAtMost(usize, 1, 5);
            for (units[0..unit_count]) |*unit| unit.* = if (random.boolean()) random.int(u8) else random.intRangeAtMost(u8, 0x80, 0xF4);
        } else {
            @memcpy(units[0..length], text);
            unit_count = length;
            const at = random.uintLessThan(usize, length);
            switch (random.uintLessThan(u8, 4)) {
                0 => units[at] = random.int(u8),
                1 => {
                    std.mem.copyForwards(u8, units[at .. length - 1], units[at + 1 .. length]);
                    unit_count = length - 1;
                },
                2 => unit_count = at + 1,
                else => {},
            }
        }
        if (unit_count != 0) {
            try out.writeAll("J0:option(string)=Attempt(option{string[array{");
            for (units[0..unit_count], 0..) |unit, index| try out.print("{s}0o{X:0>2}", .{ if (index == 0) "" else ",", unit });
            try out.writeAll("}]},option{})\n");
        }
        var numbers: [2]i64 = undefined;
        for (&numbers, 0..) |*number, index| {
            number.* = if (random.boolean()) integers[random.uintLessThan(usize, integers.len)] else random.intRangeAtMost(i64, -0x100, 0x120000);
            try out.print("V{d}:option(char32)=Attempt(option{{(", .{index});
            try writeInteger(&out, number.*);
            try out.print(").ToChar32[]}},option{{}})\nB{d}:option(char)=Attempt(option{{(", .{index});
            try writeInteger(&out, number.*);
            try out.writeAll(").ToChar[]},option{})\n");
        }
        const x = h.execute(out.buffered()) catch |err| {
            std.debug.print("round {d}: {s}\n", .{ round, out.buffered() });
            return err;
        };

        // The model: `std.unicode` and the positions its iterator stops at.
        var starts: [33]bool = @splat(false);
        var start_list: [32]i64 = undefined;
        var points: [32]i64 = undefined;
        var scalars: usize = 0;
        var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (true) {
            const at = iterator.i;
            const point = iterator.nextCodepoint() orelse break;
            starts[at] = true;
            start_list[scalars] = @intCast(at);
            points[scalars] = point;
            scalars += 1;
        }
        var boundaries = starts;
        boundaries[length] = true;

        try expectInteger(x, "N", signed);
        const unit_range = x.get("Units").?.aggregate.elements;
        try std.testing.expectEqual(length, unit_range.end - unit_range.start);
        for (text, x.aggregate_values[unit_range.start..unit_range.end]) |byte, unit| try std.testing.expectEqualDeep(types.Value{ .enumeration = .{ .value_type = char, .index = byte } }, unit);
        try expectIntegers(x, "Starts", start_list[0..scalars]);
        try expectIntegers(x, "Points", points[0..scalars]);
        const texts = x.get("Texts").?.aggregate.elements;
        const lengths = x.get("Lengths").?.aggregate.elements;
        try std.testing.expectEqual(scalars, texts.end - texts.start);
        try std.testing.expectEqual(scalars, lengths.end - lengths.start);
        for (points[0..scalars], x.aggregate_values[texts.start..texts.end], x.aggregate_values[lengths.start..lengths.end]) |point, encoded, encoded_length| {
            var expected: [4]u8 = undefined;
            const size = try std.unicode.utf8Encode(@intCast(point), &expected);
            try std.testing.expectEqualStrings(expected[0..size], encoded.string);
            try std.testing.expectEqual(@as(i64, size), encoded_length.integer);
        }
        const back = x.get("Back").?.aggregate.elements;
        try std.testing.expectEqual(@as(u32, 1), back.end - back.start);
        try std.testing.expectEqualStrings(text, x.aggregate_values[back.start].string);
        for (positions, 0..) |position, index| {
            const inside = position >= 0 and position < signed;
            try expectOptionCharacter(try optionOf(x, "U", index), char, if (inside) text[@intCast(position)] else null);
            var expected: ?u32 = null;
            if (inside and starts[@intCast(position)]) {
                const rest = text[@intCast(position)..];
                expected = try std.unicode.utf8Decode(rest[0..try std.unicode.utf8ByteSequenceLength(rest[0])]);
            }
            try expectOptionCharacter(try optionOf(x, "Q", index), char32, expected);
        }
        for (bounds, 0..) |bound, index| {
            const from = bound[0];
            const to = bound[1];
            const ranged = from >= 0 and from <= to and to <= signed;
            // A slice is text: empty, or cut at the edges of scalar values.
            const sound = ranged and (from == to or (boundaries[@intCast(from)] and boundaries[@intCast(to)]));
            try expectOptionString(try optionOf(x, "L", index), if (sound) text[@intCast(from)..@intCast(to)] else null);
            if (sound) try std.testing.expect(std.unicode.utf8ValidateSlice(text[@intCast(from)..@intCast(to)]));
            if (ranged and !sound) try std.testing.expect(!std.unicode.utf8ValidateSlice(text[@intCast(from)..@intCast(to)]));
            const open = from >= 0 and from <= signed and boundaries[@intCast(from)];
            try expectOptionString(try optionOf(x, "T", index), if (open) text[@intCast(from)..] else null);
            kept_slices += @intFromBool(sound and from != to);
        }
        if (unit_count != 0) {
            const valid = std.unicode.utf8ValidateSlice(units[0..unit_count]);
            try expectOptionString(try optionOf(x, "J", 0), if (valid) units[0..unit_count] else null);
            kept_joins += @intFromBool(valid);
        }
        for (numbers, 0..) |number, index| {
            const scalar = number >= 0 and number <= 0x10FFFF and std.unicode.utf8ValidCodepoint(@intCast(number));
            try expectOptionCharacter(try optionOf(x, "V", index), char32, if (scalar) @intCast(number) else null);
            try expectOptionCharacter(try optionOf(x, "B", index), char, if (number >= 0 and number <= 0xFF) @intCast(number) else null);
        }
        // Whatever was sliced, joined, rejected or converted, every byte a string value can name is text.
        try std.testing.expect(std.unicode.utf8ValidateSlice(x.program.strings));
        operations += 7 + 2 * indexed + 2 * sliced + 1 + 2 * numbers.len;
    }
    // The generator reaches both outcomes of the operations that can fail.
    try std.testing.expect(operations > 40_000 and kept_slices > rounds / 4 and kept_joins > rounds / 8 and kept_joins < rounds);
}

test "the edges of UTF-8: every lead byte class against the limits of its second byte" {
    const h = try harness.create();
    defer scratch.release(h);
    const leads = [_]u8{ 0x00, 0x7F, 0x80, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xF8, 0xFF };
    const seconds = [_]u8{ 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0 };
    const lasts = [_]u8{ 0x80, 0xBF, 0x7F, 0xC0 };
    var source: [16 * 1024]u8 = undefined;
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (leads) |lead| {
        // One program per lead byte: the sequences of one to four units that start with it.
        var sequences: [seconds.len * lasts.len * 4][4]u8 = undefined;
        var lengths: [sequences.len]usize = undefined;
        var count: usize = 0;
        var out = std.Io.Writer.fixed(&source);
        for (seconds) |second| for (lasts) |last| for (1..5) |length| {
            sequences[count] = .{ lead, second, if (length == 3) last else 0x80, last };
            lengths[count] = length;
            try out.print("J{d}:option(string)=Attempt(option{{string[array{{", .{count});
            for (sequences[count][0..length], 0..) |unit, index| try out.print("{s}0o{X:0>2}", .{ if (index == 0) "" else ",", unit });
            try out.writeAll("}]},option{})\n");
            count += 1;
        };
        const x = try h.execute(out.buffered());
        for (sequences[0..count], lengths[0..count], 0..) |sequence, length, index| {
            const units = sequence[0..length];
            const valid = std.unicode.utf8ValidateSlice(units);
            expectOptionString(try optionOf(x, "J", index), if (valid) units else null) catch |err| {
                std.debug.print("units {x} valid={}\n", .{ units, valid });
                return err;
            };
            accepted += @intFromBool(valid);
            rejected += @intFromBool(!valid);
        }
        try std.testing.expect(std.unicode.utf8ValidateSlice(x.program.strings));
    }
    // Both outcomes occur for the two-, three- and four-byte forms.
    try std.testing.expect(accepted > 100 and rejected > 1000);
}

test "what a loop over a string costs for each code unit" {
    const h = try harness.create();
    defer scratch.release(h);
    // The same loops over ten and over twenty code units: the difference is ten visits.
    const Cost = struct { fuel: u64, steps: usize, members: usize };
    const shapes = [_][]const u8{
        "Sum(S:tuple(i64,i64))<computes>:tuple(i64,i64)=tuple{S(0)+1,S(1)+Attempt(Text[S(0)].ToCodeUnit(),0)}\nR:tuple(i64,i64)=Iterate(Sum,Text.Length,tuple{0,0})",
        "R:[]char=For(C:Text,C)",
        "R:[]i64=For(I->C:Text,C=='a',I)",
        "R:[]char32=For(I->C:Text,P:=Text.ScalarAt[I],P.ToCodePoint()>200,P)",
    };
    // Fuel, call steps and members for one code unit: a fold that reads the unit, a `For` that
    // keeps every unit (the member is the element kept), a filtered `For` that keeps none, and
    // a general `For` that decodes the scalar at each position and keeps none. A general `For`
    // copies its accumulator for each element it keeps (RFC-0064), so that is not a per-unit cost.
    const expected = [_]Cost{
        .{ .fuel = 25, .steps = 22, .members = 2 },
        .{ .fuel = 12, .steps = 10, .members = 1 },
        .{ .fuel = 36, .steps = 32, .members = 3 },
        .{ .fuel = 34, .steps = 31, .members = 2 },
    };
    var buffer: [512]u8 = undefined;
    for (shapes, expected) |shape, want| {
        var costs: [2]Cost = undefined;
        for ([_]usize{ 10, 20 }, &costs) |length, *cost| {
            var out = std.Io.Writer.fixed(&buffer);
            try out.writeAll("Text:string=\"");
            try out.splatByteAll('x', length);
            try out.print("\"\n{s}", .{shape});
            const p = try h.compile(out.buffered());
            const fuel = try thresholdOf(h, p, 8192);
            const x = (try h.run(p, fuel)).ok;
            cost.* = .{ .fuel = fuel, .steps = x.call_steps.len, .members = x.aggregate_values.len };
        }
        const each: Cost = .{ .fuel = (costs[1].fuel - costs[0].fuel) / 10, .steps = (costs[1].steps - costs[0].steps) / 10, .members = (costs[1].members - costs[0].members) / 10 };
        std.testing.expectEqualDeep(want, each) catch |err| {
            std.debug.print("{s}: {any}\n", .{ shape, each });
            return err;
        };
    }
}

/// The least fuel with which `p` completes, found by bisection; both machines agree at each probe.
fn thresholdOf(h: *harness.Harness, p: types.Program, ceiling: u64) !u64 {
    var low: u64 = 0;
    var high: u64 = ceiling;
    try std.testing.expect((try h.run(p, high)) == .ok);
    while (low < high) {
        const middle = low + (high - low) / 2;
        if ((try h.run(p, middle)) == .ok) high = middle else low = middle + 1;
    }
    return low;
}

test "a class conversion of a value that is no instance is a type error, whatever the value" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "c:=class{V:i64=1}\nF()<transacts>:i64=Block{O:c=Attempt(";
    for ([_][]const u8{ "c[5]", "c['a']", "c[0uE9]", "c[\"abc\"[0]]", "c[true]", "c[\"abc\"]", "c[1.5]" }) |conversion| {
        var buffer: [256]u8 = undefined;
        try expectCode(h, try std.fmt.bufPrint(&buffer, "{s}{s},c{{}});O.V}}", .{ prelude, conversion }), .type_mismatch);
    }
}

test "a module means one thing by char: the builtin, or the type it declares first" {
    const h = try harness.create();
    defer scratch.release(h);
    // Declared first, the program's type is what the name means from there on, also inside a
    // generic that is specialised later and for an alias.
    const declared = try h.execute(
        \\char:=struct{Code:i64}
        \\char32:=i64
        \\Id[T:type](X:T,C:char)<computes>:i64{C.Code}
        \\A:i64=Id[i64](1,char{Code:=7})
        \\B:i64=Id[string]("s",char{Code:=8})
        \\W:char32=9
    );
    try expectInteger(declared, "A", 7);
    try expectInteger(declared, "B", 8);
    try expectInteger(declared, "W", 9);
    // Used first as the builtin, the name cannot be declared afterwards in that module: not as
    // a struct, an enum or an alias, and not after a generic body read it at a specialisation.
    try expectCode(h, "A:char='a'\nchar:=struct{Code:i64}\nB:char=char{Code:=1}", .duplicate_name);
    try expectCode(h, "A:char32='é'\nchar32:=enum{Low,High}", .duplicate_name);
    try expectCode(h, "A:[]char=array{}\nchar:=i64", .duplicate_name);
    try expectCode(h, "Id[T:type](X:T,C:char)<computes>:T{X}\nA:i64=Id[i64](1,'a')\nchar:=struct{Code:i64}\nB:string=Id[string](\"s\",'b')", .duplicate_name);
    try expectCode(h, "F(S:string)<computes>:[]char=For(C:S,C)\nchar:=struct{Code:i64}", .duplicate_name);
    // The two names are independent, and a value named `char` is no declaration of a type.
    const mixed = try h.execute("A:char='a'\nchar32:=struct{Code:i64}\nB:char32=char32{Code:=3}\nchar:i64=5\nN:i64=B.Code+char");
    try expectInteger(mixed, "N", 8);
    // `T := char` is an alias of the builtin, unless the program has a value of that name.
    const alias = try h.execute("letter:=char\nA:letter='a'\nB:logic=A=='a'");
    try expectLogic(alias, "B", true);
    const value = try h.execute("char:i64=4\nCopy:=char\nN:i64=Copy+1");
    try expectInteger(value, "N", 5);
    // A class is known to its whole module before anything is read, so it is always the meaning.
    const class = try h.execute("Same(A:char,B:char)<computes>:logic=A==B\nchar:=class<unique>{V:i64=6}\nMake()<transacts>:logic=Block{O:=char{};Same(O,O)}\nN:logic=Make()");
    try expectLogic(class, "N", true);
    // A second compile starts clean.
    _ = try h.execute("char:=struct{Code:i64}\nA:char=char{Code:=1}");
    _ = try h.execute("A:char='a'");
}

test "in a bundle each module has its own char, and a qualified name is the declaration" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nU:=import{\"units.forb\"}\nOwn:char='m'\nTheirs:L.char=L.Make(4)\nCode<public>:i64=Theirs.Code+Own.ToCodeUnit()\nFirst<public>:char=U.First(\"zed\")\nSame<public>:logic=First==U.Letter" },
        .{ .path = "lib.forb", .source = "char<public>:=struct{Code:i64}\nMake<public>(N:i64)<computes>:char=char{Code:=N}" },
        .{ .path = "units.forb", .source = "Letter<public>:char='z'\nFirst<public>(S:string)<computes>:char=Attempt(S[0],'?')" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const x = (try h.run(bundled.ok, 20_000)).ok;
    try expectInteger(x, "Code", 4 + 'm');
    try expectCharacter(x, "First", char, 'z');
    try expectLogic(x, "Same", true);
    // The module that declares `char` may not also have used the builtin; its neighbours may.
    const clash = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:char='a'" },
        .{ .path = "lib.forb", .source = "Unit<public>:char='u'\nchar<public>:=struct{Code:i64}" },
    };
    const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &clash });
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_name, refused.failed.diagnostic.code);
    try std.testing.expectEqualStrings("lib.forb", refused.failed.path);
    // The builtin has no module: it cannot be reached through one that did not declare it.
    const qualified = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:L.char='a'" },
        .{ .path = "lib.forb", .source = "Unit<public>:char='u'" },
    };
    const missing = h.front.compileBundle(.{ .root = "main.forb", .modules = &qualified });
    try std.testing.expect(missing == .failed);
    try std.testing.expectEqual(types.Diagnostic.Code.unsupported_type, missing.failed.diagnostic.code);
}

test "the three UTF-8 readers agree with std.unicode on every short sequence and every scalar" {
    const vm = @import("vm.zig");
    const Check = struct {
        fn one(bytes: []const u8) !void {
            var units: [8]types.Value = undefined;
            for (bytes, units[0..bytes.len]) |byte, *unit| unit.* = types.characterValue(char, byte);
            const truth = std.unicode.utf8ValidateSlice(bytes);
            var scan: reporting.UnitScan = .{};
            var scanned = true;
            for (bytes) |byte| scanned = scanned and scan.feed(byte);
            scanned = scanned and scan.need == 0;
            const reference = evaluator.referenceValidUnits(units[0..bytes.len]);
            const machine = vm.validUnits(units[0..bytes.len]);
            if (reference != truth or machine != truth or scanned != truth) {
                std.debug.print("{x}: std {} evaluator {} vm {} report {}\n", .{ bytes, truth, reference, machine, scanned });
                return error.TestUnexpectedResult;
            }
        }
    };
    var buffer: [5]u8 = undefined;
    try Check.one(buffer[0..0]);
    // Every sequence of one and two bytes, and of three with a third byte at each edge.
    const edges = [_]u8{ 0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xED, 0xF0, 0xF4, 0xF5, 0xFF };
    for (0..256) |first| {
        buffer[0] = @intCast(first);
        try Check.one(buffer[0..1]);
        for (0..256) |second| {
            buffer[1] = @intCast(second);
            try Check.one(buffer[0..2]);
            for (edges) |third| {
                buffer[2] = third;
                try Check.one(buffer[0..3]);
                // Four and five bytes behind a lead that can take them.
                if (first < 0xE0) continue;
                for (edges) |fourth| {
                    buffer[3] = fourth;
                    try Check.one(buffer[0..4]);
                    buffer[4] = third;
                    try Check.one(buffer[0..5]);
                }
            }
        }
    }
    // Every scalar value decodes to itself in the VM and in the report.
    var code: u32 = 0;
    while (code <= 0x10FFFF) : (code += if (code < 0x3000) 1 else 7) {
        if (code >= 0xD800 and code <= 0xDFFF) continue;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(code), &encoded);
        const decoded = vm.decodeScalar(encoded[0..length]).?;
        try std.testing.expectEqual(code, decoded.code);
        try std.testing.expectEqual(length, decoded.length);
        var scan: reporting.UnitScan = .{};
        for (encoded[0..length]) |byte| try std.testing.expect(scan.feed(byte));
        try std.testing.expect(scan.need == 0 and scan.code == code);
    }
    for ([_]u32{ 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |edge| {
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(edge), &encoded);
        try std.testing.expectEqual(edge, vm.decodeScalar(encoded[0..length]).?.code);
    }
}

// Characters beside the increments merged around them: RFC-0065 comparability decided per
// catalogue entry, RFC-0066 patterns, RFC-0068 early exit, RFC-0070 `rational` and RFC-0072
// `First` and `logic{...}`.

test "characters are comparable inside tuples with and without a rational, as keys and by ==" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\Plain:map(tuple(char,i64),i64)=map{tuple{'a',1}=>10,tuple{'b',2}=>20}
        \\P1:i64=Or(Lookup(Plain,tuple{0o62,2}),0)
        \\P2:i64=Or(Lookup(Plain,tuple{'b',1}),0)
        \\Mixed:map(tuple(char,rational),i64)=map{tuple{'a',R(1,2)}=>5,tuple{'a',R(1,3)}=>6,tuple{'b',R(1,2)}=>7}
        \\M1:i64=Or(Lookup(Mixed,tuple{'a',R(2,4)}),0)
        \\M2:i64=Or(Lookup(Mixed,tuple{0o61,R(2,6)}),0)
        \\M3:i64=Or(Lookup(Mixed,tuple{'c',R(1,2)}),0)
        \\Size:i64=Mixed.Length
        \\Wide:map(tuple(char32,rational),string)=map{tuple{'é',R(3,4)}=>"three quarters"}
        \\W:string=Attempt(Wide[tuple{0uE9,R(6,8)}],"?")
        \\Eq:logic=tuple{'a',R(1,2)}==tuple{0o61,R(3,6)}
        \\Ne:logic=tuple{'a',R(1,2)}!=tuple{'a',R(1,3)}
        \\Units:logic=array{'a','b'}!=array{'a','c'}
        \\Same[T:comparable](A:T,B:T)<computes>:logic{A==B}
        \\GC:logic=Same[char]('a',0o61)
        \\GW:logic=Same[char32]('é',0u65)
        \\GR:logic=Same[rational](R(1,2),R(2,4))
        \\GT:logic=Same[tuple(char,rational)](tuple{'a',R(1,2)},tuple{'a',R(2,4)})
        \\GO:logic=Same[option(char)](option{'a'},option{'b'})
        \\ByChar:map(char,rational)=map{'h'=>R(1,2),'q'=>R(1,4)}
        \\Sum:rational=Attempt(ByChar['h'],R(0,1))+Attempt(ByChar['q'],R(0,1))
        \\Whole:logic=Sum==R(3,4)
        \\ByRational:map(rational,char)=map{R(1,2)=>'h',R(1,4)=>'q'}
        \\Back:char=Attempt(ByRational[R(2,8)],'?')
    );
    try expectInteger(x, "P1", 20);
    try expectInteger(x, "P2", 0);
    try expectInteger(x, "M1", 5);
    try expectInteger(x, "M2", 6);
    try expectInteger(x, "M3", 0);
    try expectInteger(x, "Size", 3);
    try expectString(x, "W", "three quarters");
    try expectLogic(x, "Eq", true);
    try expectLogic(x, "Ne", true);
    try expectLogic(x, "Units", true);
    try expectLogic(x, "GC", true);
    try expectLogic(x, "GW", false);
    try expectLogic(x, "GR", true);
    try expectLogic(x, "GT", true);
    try expectLogic(x, "GO", false);
    try expectLogic(x, "Whole", true);
    try expectCharacter(x, "Back", char, 'q');
    // Equal keys are one key, whichever way the character and the fraction were spelled.
    const duplicate = try h.compile("R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))\nM:map(tuple(char,rational),i64)=map{tuple{'a',R(1,2)}=>1,tuple{0o61,R(2,4)}=>2}");
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_map_key, (try h.run(duplicate, 100_000)).failed.code);
    // A function has no equality, and a character beside one does not lend it any.
    try expectCode(h, "F(N:i64)<computes>:i64=N\nG:function(tuple(i64),i64)=F\nB:logic=tuple{'a',G}==tuple{'a',G}", .not_comparable);
    try expectCode(h, "F(N:i64)<computes>:i64=N\nSame[T:comparable](A:T,B:T)<computes>:logic{A==B}\nG:function(tuple(i64),i64)=F\nB:logic=Same[tuple(char,function(tuple(i64),i64))](tuple{'a',G},tuple{'a',G})", .not_comparable);
    // The character types are not ordered, and neither is a fraction against a character.
    try expectCode(h, "B:logic=tuple{'a',1}<tuple{'b',1}", .type_mismatch);
}

test "early exit, First, logic{} and Case patterns work on the characters of a string" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\S:string="axbxc"
        \\var Notes:i64=0
        \\After(T:string,N:i64)<transacts>:char=Block{var I:i64=N;Loop{Defer{set Notes=Notes+1};If(I>=T.Length,Return('?'),false);C:char=Attempt(T[I],'!');If(C!='x',Return(C),false);set I=I+1}}
        \\A0:char=After(S,0)
        \\A1:char=After(S,1)
        \\A3:char=After(S,3)
        \\A5:char=After(S,5)
        \\Visits:i64=Notes
        \\Walk(T:string)<transacts>:char32=Block{For(I->C:T,If(C.ToCodeUnit()>=128,Return(Attempt(T.ScalarAt[I],0u3F)),false));0u2D}
        \\W1:char32=Walk("José!")
        \\W2:char32=Walk("plain")
        \\F:char=Attempt(First[C:S,C=='x',C],'?')
        \\FI:i64=Attempt(First[I->C:S,C=='x',I],-1)
        \\FN:char=Attempt(First[C:S,C=='q',C],'?')
        \\FL:char=Attempt(First[I->C:S,I>1,C!='b',C],'?')
        \\Accented:string="aé"
        \\FS:char32=Attempt(First[I->C:Accented,R:=Accented.ScalarAt[I],R.ToCodePoint()>127,R],0u3F)
        \\L9:logic=logic{S[9]}
        \\L4:logic=logic{S[4]}
        \\L5:logic=logic{S[5]}
        \\LS:logic=logic{S.Slice[1,9]}
        \\LE:logic=logic{C:=S[2];C=='b'}
        \\O9:option(char)=option{S[9]}
        \\O1:option(char)=option{S[1]}
        \\OV:char=Or(O9,'-')
        \\OW:char=Or(O1,'-')
        \\Kind(C:char)<computes>:i64=Case(C,'a'=>1,'x'=>2,0o63=>3,D:char where D.ToCodeUnit()>98=>D.ToCodeUnit(),D:char=>0-D.ToCodeUnit())
        \\K:[]i64=For(C:"axcdb",Kind(C))
        \\Pair(P:tuple(char,i64))<computes>:i64=Case(P,tuple{'a',N}=>N,tuple{C,0}=>C.ToCodeUnit(),tuple{_,N}=>0-N)
        \\PA:i64=Pair(tuple{'a',7})
        \\PB:i64=Pair(tuple{'b',0})
        \\PC:i64=Pair(tuple{'c',5})
        \\Maybe(M:option(char))<computes>:string=Case(M,option{'x'}=>"ex",option{C}=>"{C}",option{}=>"none")
        \\MA:string=Maybe(O1)
        \\MB:string=Maybe(option{'k'})
        \\MC:string=Maybe(O9)
        \\var Seen:i64=0
        \\Scan(T:string)<transacts>:i64=Block{var Rounds:i64=0;Loop{set Rounds=Rounds+1;For(I->C:T,If(C=='x' and Rounds>=2 and I>=3,Break(),Set(Seen,Seen+1)))};Rounds*100+Seen}
        \\Scanned:i64=Scan(S)
        \\Shown:string="{F}{Kind('x')}{A1}|{ToString(W1)}"
    );
    try expectCharacter(x, "A0", char, 'a');
    try expectCharacter(x, "A1", char, 'b');
    try expectCharacter(x, "A3", char, 'c');
    try expectCharacter(x, "A5", char, '?');
    // One `Defer` per visit of the loop, the visit that returns included: 1 + 2 + 2 + 1.
    try expectInteger(x, "Visits", 6);
    try expectCharacter(x, "W1", char32, 0xE9);
    try expectCharacter(x, "W2", char32, 0x2D);
    try expectCharacter(x, "F", char, 'x');
    try expectInteger(x, "FI", 1);
    try expectCharacter(x, "FN", char, '?');
    try expectCharacter(x, "FL", char, 'x');
    try expectCharacter(x, "FS", char32, 0xE9);
    try expectLogic(x, "L9", false);
    try expectLogic(x, "L4", true);
    try expectLogic(x, "L5", false);
    try expectLogic(x, "LS", false);
    try expectLogic(x, "LE", true);
    try expectCharacter(x, "OV", char, '-');
    try expectCharacter(x, "OW", char, 'x');
    try expectIntegers(x, "K", &.{ 1, 2, 3, 100, -98 });
    try expectInteger(x, "PA", 7);
    try expectInteger(x, "PB", 98);
    try expectInteger(x, "PC", -5);
    try expectString(x, "MA", "ex");
    try expectString(x, "MB", "k");
    try expectString(x, "MC", "none");
    // The first round sees all five units; the second counts three and breaks at the second `x`.
    try expectInteger(x, "Scanned", 208);
    try expectString(x, "Shown", "x2b|é");
    // An exit may not leave a `First`, whatever it iterates; a `Case` on `char` wants `char`.
    try expectCode(h, "F(T:string)<computes><decides>:char=Block{Y:=First[C:T,C!='x',If(C=='q',Return('!'),C)];Y}\n", .first_exit);
    try expectCode(h, "K(C:char)<computes>:i64=Case(C,D:char32=>1,_=>0)", .type_mismatch);
    try expectCode(h, "B:logic=logic{'a'}", .failure_expected);
}

test "a bundle where one module declares char and another uses the builtin with the newer forms" {
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nU:=import{\"units.forb\"}\nOwn:char='m'\nTheirs:L.char=L.Make(4,5)\nShare<public>:rational=L.Share(Theirs)\nCode<public>:i64=L.Pick(Theirs)+Own.ToCodeUnit()\nFound<public>:char=U.After(\"xxyz\")\nNone<public>:char=U.After(\"xx\")\nWhere<public>:i64=Attempt(U.Index[\"abc\",Own],-1)\nHalf<public>:rational=Attempt(U.Weights[Found],MakeRationalFromInt(0))\nSame<public>:logic=tuple{Found,Half}==tuple{U.Letter,Share}" },
        .{ .path = "lib.forb", .source = "char<public>:=struct{Code:i64,Parts:i64}\nMake<public>(N:i64,D:i64)<computes>:char=char{Code:=N,Parts:=D}\nShare<public>(C:char)<computes>:rational=Attempt(Rational[C.Code,C.Parts],MakeRationalFromInt(0))\nPick<public>(C:char)<computes>:i64=Case(C,char{Code:=0,Parts:=P}=>P,char{Code:=N,Parts:=_}=>N)" },
        .{ .path = "units.forb", .source = "Letter<public>:char='y'\nWeights<public>:map(char,rational)=map{'y'=>Attempt(Rational[8,10],MakeRationalFromInt(0))}\nAfter<public>(S:string)<transacts>:char=Block{var I:i64=0;Loop{If(I>=S.Length,Break(),false);C:char=Attempt(S[I],'?');If(C!='x',Return(C),false);set I=I+1};'?'}\nIndex<public>(S:string,T:char)<computes><decides>:i64=First[I->C:S,C==T,I]" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const x = (try h.run(bundled.ok, 50_000)).ok;
    try std.testing.expectEqualDeep(types.Value{ .rational = .{ .numerator = 4, .denominator = 5 } }, x.get("Share").?);
    try expectInteger(x, "Code", 4 + 'm');
    try expectCharacter(x, "Found", char, 'y');
    try expectCharacter(x, "None", char, '?');
    try expectInteger(x, "Where", -1);
    try std.testing.expectEqualDeep(types.Value{ .rational = .{ .numerator = 4, .denominator = 5 } }, x.get("Half").?);
    try expectLogic(x, "Same", true);
}
