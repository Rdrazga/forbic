//! RFC-0087, P5.3 (E1 to E10): `ToJson(V)` and `FromJson[T][Text]`. Every row of E2 with its
//! edge values, written and read back bit for bit; the refusals of E3, which build nothing;
//! defaults, metadata and members in any order; the Book's 17:307, 17:367 and 17:391; fresh
//! instances built field by field; the effects a type that reaches a class needs; `json_type`
//! at its place; the names in every role; every trace mode, regions that fail and every fuel
//! budget on both machines; and inspection format 46. Forged IR and forged reports are in
//! `json_forgery_tests.zig`, the codec's oracle in `persist_json_model.zig`, the depth limit at
//! scale in `program_profile_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");
const native_effect_tests = @import("native_effect_tests.zig");

const Code = types.Diagnostic.Code;
const fuel: u64 = 1 << 20;

fn expectRefused(h: *harness.Harness, source: []const u8, code: Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {t}: {s}\n", .{ code, source });
        return error.Compiled;
    }
    if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), at)) std.debug.print("{t} at `{s}`, expected {t} at `{s}`: {s}\n", .{ result.failed.code, result.failed.span.text(source), code, at, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, result.failed.span.text(source));
}

fn run(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const result = try h.run(try h.compile(source), fuel);
    if (result == .failed) {
        std.debug.print("run failed: {t} at `{s}`\n", .{ result.failed.code, source[result.failed.span.start..result.failed.span.end] });
        return error.TestUnexpectedResult;
    }
    return result.ok;
}

fn text(x: evaluator.Execution, name: []const u8) []const u8 {
    return x.get(name).?.string;
}
fn integer(x: evaluator.Execution, name: []const u8) i64 {
    return x.get(name).?.integer;
}
fn logic(x: evaluator.Execution, name: []const u8) bool {
    return x.get(name).?.boolean;
}

const types_source =
    \\difficulty := enum<persistable>{Easy, Normal, Hard}
    \\point := struct<persistable>{X:float = 0.0, Y:float = 0.0}
    \\player_data := class<final><persistable>{
    \\    Level:i64 = 1
    \\    Score:i64 = 100
    \\}
    \\
;

test "E1, E2: the canonical text of every row of the table at its edges, and the Book's 17:307" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = types_source ++
        \\Min:i64 = -9223372036854775807 - 1
        \\Ints:string = ToJson(array{Min, 9223372036854775807, 0, -1})
        \\Floats:string = ToJson(array{-0.0, 0.5, NaN, Inf, -Inf, 9223372036854775808.0, 0.1})
        \\Tiny:string = ToJson(5.0e-324)
        \\Strings:string = ToJson("q\"b\\\n\t\r雪/")
        \\Chars:string = ToJson(tuple{'a', 0oFF, 0u10FFFF, 0u0})
        \\O:option(option(i64)) = option{option{1}}
        \\E:option(i64) = option{}
        \\Opts:string = ToJson(tuple{O, E, option{E}})
        \\Unit:string = ToJson(tuple{})
        \\Ea:[]i64 = array{}
        \\Em:map(i64, i64) = map{}
        \\Empty:string = ToJson(tuple{Ea, Em, ""})
        \\Map:string = ToJson(map{"a" => 1, "b" => 2})
        \\Logic:string = ToJson(array{true, false})
        \\Mode:string = ToJson(difficulty.Easy)
        \\Point:string = ToJson(point{X := 1.5})
        \\Data:player_data = player_data{Level := 5, Score := 250}
        \\Json:string = ToJson(Data)
        \\Restored:i64 = Attempt(FromJson[player_data][Json].Level, -1)
        \\Nested:string = ToJson(array{Data, Data})
    ;
    const x = try run(h, source);
    try std.testing.expectEqualStrings("[-9223372036854775808,9223372036854775807,0,-1]", text(x, "Ints"));
    try std.testing.expectEqualStrings("[-0,0.5,\"NaN\",\"Inf\",\"-Inf\",9223372036854776000,0.1]", text(x, "Floats"));
    const tiny = text(x, "Tiny");
    try std.testing.expectEqual(@as(usize, 2 + 323 + 1), tiny.len);
    try std.testing.expect(std.mem.startsWith(u8, tiny, "0.") and tiny[tiny.len - 1] == '5');
    for (tiny[2 .. tiny.len - 1]) |c| try std.testing.expectEqual(@as(u8, '0'), c);
    try std.testing.expectEqualStrings("\"q\\\"b\\\\\\n\\t\\r雪/\"", text(x, "Strings"));
    try std.testing.expectEqualStrings("[97,255,1114111,0]", text(x, "Chars"));
    try std.testing.expectEqualStrings("[{\"\":{\"\":1}},false,{\"\":false}]", text(x, "Opts"));
    try std.testing.expectEqualStrings("[]", text(x, "Unit"));
    try std.testing.expectEqualStrings("[[],[],\"\"]", text(x, "Empty"));
    try std.testing.expectEqualStrings("[{\"k\":{\"\":\"a\"},\"v\":{\"\":1}},{\"k\":{\"\":\"b\"},\"v\":{\"\":2}}]", text(x, "Map"));
    try std.testing.expectEqualStrings("[true,false]", text(x, "Logic"));
    try std.testing.expectEqualStrings("\"difficulty::Easy\"", text(x, "Mode"));
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"point\",\"x_X\":1.5,\"x_Y\":0}", text(x, "Point"));
    // 17:307: the Book's text, with this program's package name.
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"player_data\",\"x_Level\":5,\"x_Score\":250}", text(x, "Json"));
    try std.testing.expectEqual(@as(i64, 5), integer(x, "Restored"));
    // A shared instance is written at each place (E7).
    const one = "{\"$package_name\":\"/\",\"$class_name\":\"player_data\",\"x_Level\":5,\"x_Score\":250}";
    try std.testing.expectEqualStrings("[" ++ one ++ "," ++ one ++ "]", text(x, "Nested"));
}

test "E2, PM1: every row read back is the value written, bit for bit, -0.0 and NaN included" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = types_source ++
        \\Floats:[]float = array{-0.0, 0.0, 0.5, NaN, Inf, -Inf, 5.0e-324, 9223372036854775808.0, 1.0e300, 0.1}
        \\BackFloats:[]float = Attempt(FromJson[[]float][ToJson(Floats)], array{})
        \\Words:[]string = array{"", "q\"b\\\n\t\r", "雪", "\{x\}"}
        \\SameWords:logic = Attempt(Block{Require[FromJson[[]string][ToJson(Words)] == Words]; true}, false)
        \\Chars:tuple(char, char32) = tuple{0oFF, 0u10FFFF}
        \\SameChars:logic = Attempt(Block{Require[FromJson[tuple(char, char32)][ToJson(Chars)] == Chars]; true}, false)
        \\Deep:option(option(option(i64))) = option{option{option{}}}
        \\SameDeep:logic = Attempt(Block{Require[FromJson[option(option(option(i64)))][ToJson(Deep)] == Deep]; true}, false)
        \\M:map(difficulty, []point) = map{difficulty.Hard => array{point{X := -0.0}}, difficulty.Easy => array{}}
        \\SameMap:logic = Attempt(Block{Require[FromJson[map(difficulty, []point)][ToJson(M)] == M]; true}, false)
        \\Order:string = Attempt(ToJson(FromJson[map(difficulty, []point)][ToJson(M)]), "")
        \\Ints:tuple(i64, i64, tuple()) = tuple{-9223372036854775807 - 1, 9223372036854775807, tuple{}}
        \\SameInts:logic = Attempt(Block{Require[FromJson[tuple(i64, i64, tuple())][ToJson(Ints)] == Ints]; true}, false)
    ;
    const x = try run(h, source);
    const written = x.elements(x.get("Floats").?).?;
    const read = x.elements(x.get("BackFloats").?).?;
    try std.testing.expectEqual(written.len, read.len);
    for (written, read) |a, b| try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating)));
    for ([_][]const u8{ "SameWords", "SameChars", "SameDeep", "SameMap", "SameInts" }) |name| try std.testing.expect(logic(x, name));
    // A map keeps its insertion order.
    try std.testing.expectEqualStrings("[{\"k\":{\"\":\"difficulty::Hard\"},\"v\":{\"\":[{\"$package_name\":\"/\",\"$class_name\":\"point\",\"x_X\":-0,\"x_Y\":0}]}},{\"k\":{\"\":\"difficulty::Easy\"},\"v\":{\"\":[]}}]", text(x, "Order"));
}

/// `Name:logic`, true when the text decodes as the type.
fn decodes(buffer: []u8, name: []const u8, type_text: []const u8, json: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}:logic = Attempt(Block{{FromJson[{s}][\"{s}\"]; true}}, false)\n", .{ name, type_text, json });
}

test "E3: each rule refuses its texts, and a decode that fails builds nothing" {
    const h = try harness.create();
    defer scratch.release(h);
    // Texts written as Forbic string contents: `\"` is a quote, `\\` a backslash, `\\{` a brace.
    const Case = struct { type_text: []const u8, json: []const u8, ok: bool };
    const cases = [_]Case{
        .{ .type_text = "i64", .json = "1", .ok = true },
        .{ .type_text = "i64", .json = " -0 ", .ok = true },
        .{ .type_text = "i64", .json = "\\{", .ok = false },
        .{ .type_text = "i64", .json = "1 2", .ok = false },
        .{ .type_text = "i64", .json = "null", .ok = false },
        .{ .type_text = "i64", .json = "1.0", .ok = false },
        .{ .type_text = "i64", .json = "1e3", .ok = false },
        .{ .type_text = "i64", .json = "01", .ok = false },
        .{ .type_text = "i64", .json = "9223372036854775808", .ok = false },
        .{ .type_text = "i64", .json = "-9223372036854775809", .ok = false },
        .{ .type_text = "[]i64", .json = "[1,]", .ok = false },
        .{ .type_text = "string", .json = "1", .ok = false },
        .{ .type_text = "string", .json = "\\\"\\\\ud800\\\"", .ok = false },
        .{ .type_text = "string", .json = "\\\"a\\\\udfff\\\"", .ok = false },
        .{ .type_text = "string", .json = "\\\"\\\\x41\\\"", .ok = false },
        .{ .type_text = "string", .json = "\\\"\\\\ud83d\\\\ude00\\\"", .ok = true },
        .{ .type_text = "string", .json = "\\\"tab\\there\\\"", .ok = false },
        .{ .type_text = "logic", .json = "\\\"true\\\"", .ok = false },
        .{ .type_text = "char", .json = "255", .ok = true },
        .{ .type_text = "char", .json = "256", .ok = false },
        .{ .type_text = "char32", .json = "1114112", .ok = false },
        .{ .type_text = "char32", .json = "55296", .ok = false },
        .{ .type_text = "float", .json = "1e400", .ok = false },
        .{ .type_text = "float", .json = "1e-400", .ok = true },
        .{ .type_text = "float", .json = "\\\"Infinity\\\"", .ok = false },
        .{ .type_text = "option(i64)", .json = "\\{\\\"x\\\":1\\}", .ok = false },
        .{ .type_text = "option(i64)", .json = "\\{\\\"\\\":1,\\\"\\\":2\\}", .ok = false },
        .{ .type_text = "option(i64)", .json = "true", .ok = false },
        .{ .type_text = "tuple(i64, i64)", .json = "[1]", .ok = false },
        .{ .type_text = "tuple()", .json = "[1]", .ok = false },
        .{ .type_text = "map(i64, i64)", .json = "[\\{\\\"k\\\":\\{\\\"\\\":1\\}\\}]", .ok = false },
        .{ .type_text = "map(i64, i64)", .json = "[\\{\\\"k\\\":1,\\\"v\\\":\\{\\\"\\\":2\\}\\}]", .ok = false },
        .{ .type_text = "map(i64, i64)", .json = "[\\{\\\"v\\\":\\{\\\"\\\":2\\},\\\"k\\\":\\{\\\"\\\":1\\}\\}]", .ok = true },
        .{ .type_text = "map(float, i64)", .json = "[\\{\\\"k\\\":\\{\\\"\\\":0\\},\\\"v\\\":\\{\\\"\\\":2\\}\\},\\{\\\"k\\\":\\{\\\"\\\":-0\\},\\\"v\\\":\\{\\\"\\\":3\\}\\}]", .ok = false },
        .{ .type_text = "map(float, i64)", .json = "[\\{\\\"k\\\":\\{\\\"\\\":\\\"NaN\\\"\\},\\\"v\\\":\\{\\\"\\\":2\\}\\},\\{\\\"k\\\":\\{\\\"\\\":\\\"NaN\\\"\\},\\\"v\\\":\\{\\\"\\\":3\\}\\}]", .ok = false },
        .{ .type_text = "difficulty", .json = "\\\"difficulty::Hard\\\"", .ok = true },
        .{ .type_text = "difficulty", .json = "\\\"difficulty::Expert\\\"", .ok = false },
        .{ .type_text = "difficulty", .json = "\\\"mode::Easy\\\"", .ok = false },
        .{ .type_text = "difficulty", .json = "\\\"Easy\\\"", .ok = false },
        .{ .type_text = "point", .json = "\\{\\}", .ok = true },
        .{ .type_text = "point", .json = "\\{\\\"x_X\\\":1,\\\"x_X\\\":2\\}", .ok = false },
        .{ .type_text = "point", .json = "\\{\\\"x_Z\\\":1\\}", .ok = false },
        .{ .type_text = "point", .json = "\\{\\\"X\\\":1\\}", .ok = false },
        .{ .type_text = "point", .json = "\\{\\\"$class_name\\\":\\\"other\\\"\\}", .ok = false },
        .{ .type_text = "point", .json = "\\{\\\"$package_name\\\":\\\"/elsewhere\\\"\\}", .ok = false },
        .{ .type_text = "point", .json = "\\{\\\"$class_name\\\":\\\"point\\\",\\\"$class_name\\\":\\\"point\\\"\\}", .ok = false },
        .{ .type_text = "needed", .json = "\\{\\\"x_B\\\":1\\}", .ok = false },
        .{ .type_text = "needed", .json = "\\{\\\"x_A\\\":1\\}", .ok = true },
    };
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, types_source ++ "needed := struct<persistable>{A:i64, B:i64 = 2}\n");
    var buffer: [512]u8 = undefined;
    var names: [cases.len][8]u8 = undefined;
    for (cases, 0..) |case, index| {
        const name = try std.fmt.bufPrint(&names[index], "D{d}", .{index});
        try source.appendSlice(std.testing.allocator, try decodes(&buffer, name, case.type_text, case.json));
    }
    const x = try run(h, source.items);
    for (cases, 0..) |case, index| {
        const name = try std.fmt.bufPrint(&names[index], "D{d}", .{index});
        if (logic(x, name) != case.ok) std.debug.print("{s} {s} decoded {}\n", .{ case.type_text, case.json, logic(x, name) });
        try std.testing.expectEqual(case.ok, logic(x, name));
    }
    // A decode that fails late has built members, strings and instances; none is kept.
    const failing = try run(h, types_source ++
        \\F1:logic = Attempt(Block{FromJson[[][]string][" [[\"ab\", \"c\\\"d\"], [\"e\"], [1]] "]; true}, false)
        \\F2:logic = Attempt(Block{FromJson[[]player_data]["[\{\}, \{\"x_Level\":2\}, \{\"x_Score\":\"no\"\}]"]; true}, false)
    );
    try std.testing.expect(!logic(failing, "F1") and !logic(failing, "F2"));
    try std.testing.expectEqual(@as(usize, 0), failing.aggregate_values.len);
    try std.testing.expectEqual(@as(usize, 0), failing.object_cells.len);
    try std.testing.expectEqual(failing.program.strings.len, h.front.compile(types_source ++
        \\F1:logic = Attempt(Block{FromJson[[][]string][" [[\"ab\", \"c\\\"d\"], [\"e\"], [1]] "]; true}, false)
        \\F2:logic = Attempt(Block{FromJson[[]player_data]["[\{\}, \{\"x_Level\":2\}, \{\"x_Score\":\"no\"\}]"]; true}, false)
    ).ok.strings.len);
}

test "E3 and the Book's 17:367: absent fields take their defaults, metadata may be absent, members come in any order" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\versioned_data := class<final><persistable>{
        \\    Version:i64 = 1
        \\    NewField:i64 = 0
        \\}
        \\# Old JSON, written before NewField existed, carries no x_NewField.
        \\OldJson:string = "\{\"x_Version\":1\}"
        \\Data:versioned_data = Attempt(FromJson[versioned_data][OldJson], versioned_data{Version := -1, NewField := -1})
        \\Version:i64 = Data.Version
        \\NewField:i64 = Data.NewField
        \\record := struct<persistable>{A:[]i64 = array{1, 2}, B:option(string) = option{"b"}, C:tuple(logic, float) = tuple{true, -0.5}}
        \\Spaced:record = Attempt(FromJson[record][" \{ \"x_C\" : [ false , 2 ] ,\n\t\"$class_name\" : \"record\" \} "], record{})
        \\Again:string = ToJson(Spaced)
        \\Escaped:record = Attempt(FromJson[record]["\{\"\\u0078_B\":\{\"\":\"\\u96ea\"\},\"$package_name\":\"\\/\"\}"], record{})
        \\EscapedText:string = ToJson(Escaped)
    );
    try std.testing.expectEqual(@as(i64, 1), integer(x, "Version"));
    try std.testing.expectEqual(@as(i64, 0), integer(x, "NewField"));
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"record\",\"x_A\":[1,2],\"x_B\":{\"\":\"b\"},\"x_C\":[false,2]}", text(x, "Again"));
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"record\",\"x_A\":[1,2],\"x_B\":{\"\":\"雪\"},\"x_C\":[true,-0.5]}", text(x, "EscapedText"));
}

test "E5 and the Book's 17:391: decoding runs no block clause, constructing does" {
    const w = try native_effect_tests.World.create();
    defer w.destroy();
    const x = try w.expect(
        \\audited := class<final><persistable>{
        \\    Value:i64 = 0
        \\    Block{ Print("constructed") }
        \\}
        \\# Normal construction runs the block clause.
        \\Instance:audited = audited{Value := 1}
        \\# Deserialization does not: nothing is printed here.
        \\Loaded:i64 = Attempt(FromJson[audited]["\{\}"].Value, -1)
        \\Many:i64 = Attempt(FromJson[[]audited]["[\{\}, \{\"x_Value\":2\}]"].Length, -1)
    , "constructed\n");
    try std.testing.expectEqual(@as(i64, 0), x.get("Loaded").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Many").?.integer);
}

test "E4: each object of a text is a new instance, and a chain is built from its innermost link" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\node := class<final><persistable>{
        \\    Label:string = ""
        \\    Next:option(node) = option{}
        \\}
        \\Text:string = "\{\"x_Label\":\"a\",\"x_Next\":\{\"\":\{\"x_Label\":\"b\",\"x_Next\":\{\"\":\{\"x_Label\":\"c\"\}\}\}\}\}"
        \\Chain:node = Attempt(FromJson[node][Text], node{})
        \\Second:node = Attempt(FromJson[node][Text], node{})
        \\Labels:string = Attempt(Block{ B := Chain.Next?; C := B.Next?; Chain.Label + B.Label + C.Label }, "")
        \\Same:logic = Attempt(Block{Require[ToJson(Chain) == ToJson(Second)]; true}, false)
        \\Canonical:string = ToJson(Chain)
    );
    try std.testing.expectEqualStrings("abc", text(x, "Labels"));
    try std.testing.expect(logic(x, "Same"));
    // Three instances per decode, of a header and two fields each, the innermost first: the
    // first text's outer link is the third instance, the second text's the sixth.
    try std.testing.expectEqual(@as(usize, 18), x.object_cells.len);
    try std.testing.expectEqual(@as(u32, 6), x.get("Chain").?.object.id);
    try std.testing.expectEqual(@as(u32, 15), x.get("Second").?.object.id);
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Label\":\"a\",\"x_Next\":{\"\":{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Label\":\"b\",\"x_Next\":{\"\":{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Label\":\"c\",\"x_Next\":false}}}}}", text(x, "Canonical"));
}

test "T8: a package name is the file's bundle path and the nested modules around the type" {
    const h = try harness.create();
    defer scratch.release(h);
    // A single file has no path: its types are in the package `/`.
    const single = try run(h, "slot := struct<persistable>{N:i64 = 1}\nText:string = ToJson(slot{})");
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"slot\",\"x_N\":1}", text(single, "Text"));
    const modules = @import("modules.zig");
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "Save:=import{\"kit/save.forb\"}\nmine := struct<persistable>{K:i64 = 0}\nA<public>:string = ToJson(Save.Slots.Deep.slot{})\nB<public>:string = ToJson(Save.stats{})\nC<public>:string = ToJson(mine{})\nD<public>:i64 = Attempt(FromJson[Save.Slots.Deep.slot][\"\\{\\\"$package_name\\\":\\\"/kit/save.forb/Slots/Deep\\\",\\\"x_N\\\":4\\}\"].N, -1)\nE<public>:i64 = Attempt(FromJson[Save.Slots.Deep.slot][\"\\{\\\"$package_name\\\":\\\"/kit/save.forb\\\",\\\"x_N\\\":4\\}\"].N, -1)" },
        .{ .path = "kit/save.forb", .source = "Slots<public> := module{\n    Deep<public> := module{\n        slot<public> := struct<persistable>{N:i64 = 2}\n    }\n}\nstats<public> := struct<persistable>{M:i64 = 3}" },
    };
    const bundled = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok, fuel)).ok;
    try std.testing.expectEqualStrings("{\"$package_name\":\"/kit/save.forb/Slots/Deep\",\"$class_name\":\"slot\",\"x_N\":2}", text(bundled, "A"));
    try std.testing.expectEqualStrings("{\"$package_name\":\"/kit/save.forb\",\"$class_name\":\"stats\",\"x_M\":3}", text(bundled, "B"));
    try std.testing.expectEqualStrings("{\"$package_name\":\"/main.forb\",\"$class_name\":\"mine\",\"x_K\":0}", text(bundled, "C"));
    try std.testing.expectEqual(@as(i64, 4), integer(bundled, "D"));
    try std.testing.expectEqual(@as(i64, -1), integer(bundled, "E"));
}

test "effects: a type that reaches a class makes ToJson read and FromJson allocate; others need nothing" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, types_source ++
        \\Pure(P:point)<computes>:string = ToJson(P)
        \\PureBack(T:string)<computes><decides>:point = FromJson[point][T]
        \\Reading(D:player_data)<reads>:string = ToJson(D)
        \\Building(T:string)<allocates><decides>:player_data = FromJson[player_data][T]
        \\Nested(T:string)<allocates><decides>:[]option(player_data) = FromJson[[]option(player_data)][T]
        \\A:string = Pure(point{})
        \\B:float = Attempt(PureBack["\{\"x_Y\":2.5\}"].Y, -1.0)
        \\C:string = Reading(player_data{})
        \\D:i64 = Attempt(Building[C].Score, -1)
        \\E:i64 = Attempt(Nested["[false, \{\"\":\{\}\}]"].Length, -1)
    );
    try std.testing.expectEqual(@as(f64, 2.5), x.get("B").?.floating);
    try std.testing.expectEqual(@as(i64, 100), integer(x, "D"));
    try std.testing.expectEqual(@as(i64, 2), integer(x, "E"));
    try expectRefused(h, types_source ++ "F(D:player_data)<computes>:string = ToJson(D)", .field_read_requires_reads, "ToJson");
    try expectRefused(h, types_source ++ "F(D:[]tuple(i64, player_data))<computes>:string = ToJson(D)", .field_read_requires_reads, "ToJson");
    try expectRefused(h, types_source ++ "F(T:string)<reads><decides>:player_data = FromJson[player_data][T]", .construction_requires_allocates, "FromJson");
    try expectRefused(h, types_source ++ "F(T:string)<computes><decides>:option(player_data) = FromJson[option(player_data)][T]", .construction_requires_allocates, "FromJson");
    // A decode fails, so it stands in a failure context, as every failable call does.
    try expectRefused(h, types_source ++ "F(T:string)<computes>:point = FromJson[point][T]", .failure_context_required, "FromJson");
    try expectRefused(h, types_source ++ "A:point = FromJson[point][\"\\{\\}\"]", .failure_context_required, "FromJson");
}

test "json_type: a type that is not persistable, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = types_source ++ "plain := struct{V:i64 = 0}\nopen_class := class{}\n";
    const Row = struct { tail: []const u8, at: []const u8 };
    const rows = [_]Row{
        .{ .tail = "A:string = ToJson(plain{})", .at = "plain{}" },
        .{ .tail = "A:string = ToJson(open_class{})", .at = "open_class{}" },
        .{ .tail = "A:string = ToJson(any(1))", .at = "any" },
        .{ .tail = "A:string = ToJson(array{plain{}})", .at = "array{plain{}}" },
        .{ .tail = "F(X:i64)<computes>:i64 = X\nA:string = ToJson(F)", .at = "F" },
        .{ .tail = "F(W:weak_map(i64, i64))<computes>:string = ToJson(W)", .at = "W" },
        .{ .tail = "A:i64 = Attempt(Block{FromJson[plain][\"\\{\\}\"]; 1}, 0)", .at = "plain" },
        .{ .tail = "A:i64 = Attempt(Block{FromJson[[]plain][\"[]\"]; 1}, 0)", .at = "[" },
        .{ .tail = "A:i64 = Attempt(Block{FromJson[map(i64, any)][\"[]\"]; 1}, 0)", .at = "map" },
        .{ .tail = "A:i64 = Attempt(Block{FromJson[weak_map(i64, i64)][\"[]\"]; 1}, 0)", .at = "weak_map" },
    };
    var buffer: [512]u8 = undefined;
    for (rows) |row| try expectRefused(h, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, row.tail }), .json_type, row.at);
    // The form's own shape: a bracket of the type, then one of the text; parentheses for ToJson.
    try expectRefused(h, head ++ "A:i64 = Attempt(Block{FromJson[point]; 1}, 0)", .expected_call, "FromJson");
    try expectRefused(h, head ++ "A:i64 = Attempt(Block{FromJson[point][\"\\{\\}\", \"\\{\\}\"]; 1}, 0)", .argument_count, ",");
    try expectRefused(h, head ++ "A:string = ToJson(1, 2)", .argument_count, ",");
    try expectRefused(h, head ++ "A:string = ToJson[1]", .unknown_name, "ToJson");
    try expectRefused(h, head ++ "A:i64 = Attempt(Block{FromJson[point][1]; 1}, 0)", .type_mismatch, "1");
}

test "the names ToJson and FromJson yield to every declaration of them, and are the standard forms elsewhere" {
    const h = try harness.create();
    defer scratch.release(h);
    const programs = [_][]const u8{
        "ToJson(X:i64)<computes>:string = \"mine\"\nA:string = ToJson(1)",
        "FromJson(X:i64)<computes><decides>:i64 = X\nA:string = Attempt(Block{X := FromJson[1]; \"mine\"}, \"\")",
        "A:string = Block{ ToJson := Fn(X:i64)<computes>:string{\"mine\"}; ToJson(1) }",
        "F(ToJson:function(tuple(i64), string))<computes>:string = ToJson(1)\nG(X:i64)<computes>:string = \"mine\"\nA:string = F(G)",
        "c := class{ ToJson(X:i64)<computes>:string = \"mine\"\n Call()<computes>:string = Self.ToJson(1) }\nA:string = c{}.Call()",
    };
    for (programs) |source| try std.testing.expectEqualStrings("mine", text(try run(h, source), "A"));
    // Types of the program's own named so, which are no calls.
    const own = try run(h, "ToJson := struct{ N:i64 = 3 }\nFromJson := class{ M:i64 = 1 }\nA:i64 = ToJson{}.N + FromJson{}.M");
    try std.testing.expectEqual(@as(i64, 4), integer(own, "A"));
    try expectRefused(h, "ToJson := struct{ N:i64 = 3 }\nB:string = ToJson(4)", .unknown_name, "ToJson");
    // The program's type in brackets is a cast of the value in them.
    try expectRefused(h, "FromJson := struct{ N:i64 = 3 }\nB:i64 = Attempt(FromJson[i64][\"4\"], 0)", .expected_expression, "i64");
    // A declaration further down is the module's throughout: a use above it is refused.
    try expectRefused(h, "A:string = ToJson(1)\nToJson(X:i64)<computes>:string = \"mine\"", .unknown_name, "ToJson");
    try expectRefused(h, "F()<computes>:i64 = Block{ X := ToJson(1); ToJson := 1; 0 }", .used_before_declaration, "ToJson");
    try expectRefused(h, "F()<computes>:i64 = Block{ X := Attempt(FromJson[i64][\"1\"], 0); FromJson := 1; X }", .used_before_declaration, "FromJson");
    // A bare name is no call; in a class with a member of the name, the name is the member's.
    try expectRefused(h, "A:i64 = Block{ F := ToJson; 1 }", .unknown_name, "ToJson");
    try expectRefused(h, "c := class{ ToJson(X:i64)<computes>:string = \"mine\"\n Call()<computes>:string = ToJson(1) }", .unknown_name, "ToJson");
    // A module of a bundle: what it exports wins where it is used, the standard form elsewhere.
    const modules = @import("modules.zig");
    const lib = "ToJson<public>(X:i64)<computes>:string = \"mine\"";
    const used = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:string = ToJson(1)" },
        .{ .path = "lib.forb", .source = lib },
    };
    const bundled = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &used }).ok, fuel)).ok;
    try std.testing.expectEqualStrings("mine", text(bundled, "A"));
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:string = ToJson(1)\nB<public>:string = L.ToJson(1)" },
        .{ .path = "lib.forb", .source = lib },
    };
    const standard = (try h.run(h.front.compileBundle(.{ .root = "main.forb", .modules = &plain }).ok, fuel)).ok;
    try std.testing.expectEqualStrings("1", text(standard, "A"));
    try std.testing.expectEqualStrings("mine", text(standard, "B"));
}

/// Encodes and decodes in functions, closures and tasks, in regions that commit and fail, with
/// instances built in a region that fails: every trace mode gives the stored report.
const modes_source = types_source ++
    \\node := class<final><persistable>{
    \\    Label:string = ""
    \\    Next:option(node) = option{}
    \\}
    \\Encode(N:node)<reads>:string = ToJson(N)
    \\Decode(T:string)<allocates><decides>:node = FromJson[node][T]
    \\Twice(T:string)<transacts><decides>:string = Block{ N := Decode[T]; Encode(node{Label := N.Label + "!", Next := option{N}}) }
    \\Kept:string = Attempt(Twice["\{\"x_Label\":\"a\"\}"], "-")
    \\Dropped:string = Attempt(Block{ X := Twice["\{\"x_Label\":\"b\"\}"]; Require[false]; X }, "dropped")
    \\Points(N:i64)<computes>:string = Iterate(Fn(S:string)<computes>:string{ Attempt(ToJson(FromJson[[]point][S] + array{point{X := 1.0}}), S) }, N, "[]")
    \\Many:string = Points(5)
    \\Bad:i64 = Attempt(Block{ X := Decode["\{\"x_Label\":1\}"]; 1 }, 0)
    \\Later:task(string) = Spawn{ Block{ Sleep(1.0); Attempt(Twice[Kept], "-") } }
    \\Last:string = Attempt(Twice[Twice[Kept]], "-")
;

test "every trace mode, with reclamation, gives the stored report; regions that fail keep no instance" {
    _ = try live_tests.everyMode(modes_source);
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, modes_source);
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Label\":\"a!\",\"x_Next\":{\"\":{\"$package_name\":\"/\",\"$class_name\":\"node\",\"x_Label\":\"a\",\"x_Next\":false}}}", text(x, "Kept"));
    try std.testing.expectEqualStrings("dropped", text(x, "Dropped"));
    try std.testing.expectEqual(@as(i64, 0), integer(x, "Bad"));
    // Five points of 59 bytes each, four commas and the brackets.
    try std.testing.expectEqual(@as(usize, 5 * 59 + 4 + 2), text(x, "Many").len);
}

test "at every budget both machines stop at the same node, and the least that runs is the same" {
    const h = try harness.create();
    defer scratch.release(h);
    const sources = [_][]const u8{
        types_source ++ "A:string = ToJson(array{point{}, point{X := 1.5}})\nB:i64 = Attempt(FromJson[[]point][A].Length, -1)",
        types_source ++ "F(T:string)<allocates><decides>:i64 = FromJson[[]player_data][T].Length\nA:i64 = Attempt(F[\"[\\{\\}, \\{\\\"x_Score\\\":3\\}, \\{\\\"x_Level\\\":2\\}]\"], -1)",
        types_source ++ "F(D:player_data)<reads>:string = ToJson(map{D.Level => D})\nA:string = F(player_data{})\nB:i64 = Attempt(FromJson[map(i64, player_data)][\"[\\{\\\"v\\\":\\{\\\"\\\":\\{\\}\\},\\\"k\\\":\\{\\\"\\\":3\\}\\}]\"].Length, -1)",
    };
    for (sources) |source| {
        const p = try h.compile(source);
        var budget: u64 = 1;
        var stopped: usize = 0;
        while (budget < 1 << 16) : (budget += 1) {
            const result = try h.run(p, budget);
            if (result == .ok) break;
            try std.testing.expectEqual(Code.work_limit, result.failed.code);
            stopped += 1;
        }
        try std.testing.expect(stopped > 10 and budget < 1 << 16);
    }
}

test "inspection format 46 prints the JSON operations; a program without one keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    var buffer: [1 << 16]u8 = undefined;
    for ([_]struct { source: []const u8, format: i64 }{
        .{ .source = types_source ++ "A:string = ToJson(point{})\nF(T:string)<computes><decides>:point = FromJson[point][T]\nB:float = Attempt(F[A].X, -1.0)", .format = 46 },
        .{ .source = types_source ++ "A:point = point{}", .format = 39 },
    }) |case| {
        var out = std.Io.Writer.fixed(&buffer);
        try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, try h.compile(case.source)));
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.format, parsed.value.object.get("format").?.integer);
        const written = out.buffered();
        try std.testing.expectEqual(case.format == 46, std.mem.indexOf(u8, written, "{\"json_encode\":") != null);
        try std.testing.expectEqual(case.format == 46, std.mem.indexOf(u8, written, "{\"json_decode\":") != null);
    }
}

/// The least fuel with which `source` runs, found by bisection, both machines agreeing at each.
fn leastFuel(h: *harness.Harness, source: []const u8) !u64 {
    const p = try h.compile(source);
    var low: u64 = 0;
    var high: u64 = 1 << 20;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try h.run(p, middle) == .ok) high = middle else low = middle + 1;
    }
    return low;
}

test "fuel: a decode that fails pays for every byte it read, on both machines (review D2)" {
    const h = try harness.create();
    defer scratch.release(h);
    // `S` is 16,384 spaces, made by doubling.
    const head = "Double(X:string)<computes>:string = X + X\nS:string = Iterate(Double, 14, \" \")\n";
    // `T` is built in both programs; one decodes it, the other a one-byte text that fails or
    // decodes as it does. The 16,385 bytes read cost 2,048 units more, whether the text fails
    // at its end or decodes.
    const Row = struct { text: []const u8, read: []const u8, control: []const u8, extra: u64 };
    for ([_]Row{
        .{ .text = "S + \"x\"", .read = "A:i64 = Attempt(FromJson[i64][T], 0)", .control = "A:i64 = Attempt(FromJson[i64][\"x\"], 0)", .extra = 0 },
        .{ .text = "S + \"1\"", .read = "A:i64 = Attempt(FromJson[i64][T], 0)", .control = "A:i64 = Attempt(FromJson[i64][\"1\"], 0)", .extra = 0 },
        .{ .text = "\"\\\"\" + S", .read = "A:string = Attempt(FromJson[string][T], \"\")", .control = "A:string = Attempt(FromJson[string][\"x\"], \"\")", .extra = 0 },
    }) |row| {
        var buffer: [512]u8 = undefined;
        const control = try leastFuel(h, try std.fmt.bufPrint(&buffer, "{s}T:string = {s}\n{s}", .{ head, row.text, row.control }));
        const read = try leastFuel(h, try std.fmt.bufPrint(&buffer, "{s}T:string = {s}\n{s}", .{ head, row.text, row.read }));
        // The control's one-byte text is a literal node more, a unit.
        try std.testing.expectEqual(control - 1 + 2048 + row.extra, read);
    }
}

test "a large text that does not decode fails, and only a valid one meets the capacities (review)" {
    // The sizes assume the bootstrap profile's members; the program profile's are in
    // `program_profile_tests.zig`.
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // More elements than the bootstrap profile's members: 2^13 + 1 integers, the last of them
    // no integer.
    const head = "Double(X:string)<computes>:string = X + X\nS:string = Iterate(Double, 13, \"1,\")\n";
    const bad = try run(h, head ++ "A:i64 = Attempt(FromJson[[]i64][\"[\" + S + \"x]\"].Length, -1)");
    try std.testing.expectEqual(@as(i64, -1), integer(bad, "A"));
    const good = try h.run(try h.compile(head ++ "A:i64 = Attempt(FromJson[[]i64][\"[\" + S + \"1]\"].Length, -1)"), fuel);
    try std.testing.expectEqual(Code.aggregate_limit, good.failed.code);
}
