//! `<persistable>` types (RFC-0087, P5.2, T1 to T8): the specifier on structs, classes and
//! enums, every rule and its diagnostic at its place, the flags and the field constants
//! (`Program.constants`), inspection format 39, every trace mode, the Book's examples 17:67,
//! 17:94, 17:126, 17:135, 17:152 and 17:197, the word in every role a name can have, and an
//! oracle: random persistable types with random literal defaults, whose every constant is the
//! value both machines compute for the default, and the same programs with one rule broken,
//! refused with the code and at the place a model predicts. Forged IR is in
//! `persistable_forgery_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const modules = @import("modules.zig");
const catalogue = @import("aggregate_types.zig");
const persistable = @import("persistable.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");

const Code = types.Diagnostic.Code;
const allocator = std.testing.allocator;

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

/// The definition named `name`.
fn definitionNamed(p: types.Program, name: []const u8) types.Definition {
    for (p.definitions) |item| if (catalogue.declaredName(item)) |span| if (std.mem.eql(u8, span.text(p.source), name)) return item;
    unreachable;
}

/// The fields of the struct or class named `name`.
fn fieldsOf(p: types.Program, name: []const u8) []const types.Field {
    const span = switch (definitionNamed(p, name)) {
        .record => |record| record.fields,
        .class => |class| class.fields,
        else => unreachable,
    };
    return p.fields[span.start..span.end];
}

/// That constant `index` of the run's program is `value`, bit for bit and member by member.
fn expectConstant(x: evaluator.Execution, index: u32, value: types.Value) !void {
    const p = x.program;
    const constant = p.constants[index];
    switch (constant.kind) {
        .integer => |expected| try std.testing.expectEqual(expected, value.integer),
        .boolean => |expected| try std.testing.expectEqual(expected, value.boolean),
        .floating => |expected| try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(value.floating))),
        .string => |span| try std.testing.expectEqualStrings(span.text(p.strings), value.string),
        .enumeration, .character => |expected| {
            try std.testing.expectEqual(constant.value_type, value.enumeration.value_type);
            try std.testing.expectEqual(expected, value.enumeration.index);
        },
        .aggregate => |span| {
            try std.testing.expectEqual(constant.value_type, value.aggregate.value_type);
            const members = x.elements(value).?;
            try std.testing.expectEqual(@as(usize, span.end - span.start), members.len);
            for (p.constant_members[span.start..span.end], members) |member, held| try expectConstant(x, member, held);
        },
    }
}

/// Every field of struct `name` with a constant holds it in `Name{}`, bound to `binding`.
fn expectDefaults(x: evaluator.Execution, name: []const u8, binding: []const u8) !void {
    const value = x.get(binding).?;
    const members = x.elements(value).?;
    for (fieldsOf(x.program, name), members) |field, held| if (field.constant) |constant| try expectConstant(x, constant, held);
}

test "T1 to T7: persistable structs, classes and enums are built, compared, matched and called as before" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\difficulty := enum<persistable><closed>{Easy, Normal, Hard}
        \\achievement := enum<persistable><open>{FirstWin}
        \\coordinates := struct<persistable>{X:float = 0.0, Y:float = -0.0}
        \\player_profile := class<persistable><final>{
        \\    Version:i64 = 1
        \\    Title:string = ""
        \\    Unlocked:[]string = array{}
        \\    BestTimes:map(string, float) = map{}
        \\    LastScore:option(i64) = option{}
        \\    Mode:difficulty = difficulty.Normal
        \\    Home:coordinates = coordinates{X := 2.5}
        \\    Level()<reads>:i64 = Self.Version + 1
        \\}
        \\Profile:player_profile = player_profile{Title := "t"}
        \\Ver:i64 = Profile.Version
        \\Lv:i64 = Profile.Level()
        \\Md:difficulty = Profile.Mode
        \\Easy:logic = Attempt(Block{Require[Profile.Mode == difficulty.Normal]; true}, false)
        \\Name:string = Case(Profile.Mode, difficulty.Easy => "e", difficulty.Normal => "n", difficulty.Hard => "h")
        \\Hm:coordinates = Profile.Home
        \\Same:logic = Attempt(Block{Require[coordinates{} == coordinates{Y := 0.0}]; true}, false)
        \\Open:i64 = Case(achievement.FirstWin, achievement.FirstWin => 1, _ => 2)
        \\Empty:coordinates = coordinates{}
    ;
    const x = try h.execute(source);
    try std.testing.expectEqual(@as(i64, 1), x.get("Ver").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("Lv").?.integer);
    try std.testing.expectEqual(@as(u32, 1), x.get("Md").?.enumeration.index);
    try std.testing.expect(x.get("Easy").?.boolean);
    try std.testing.expectEqualStrings("n", x.get("Name").?.string);
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), x.get("Open").?.integer);
    const home = x.elements(x.get("Hm").?).?;
    try std.testing.expectEqual(@as(f64, 2.5), home[0].floating);
    // The flags (T1), on what says the specifier and on nothing else.
    const p = x.program;
    try std.testing.expect(definitionNamed(p, "difficulty").enumeration.persistable);
    try std.testing.expect(!definitionNamed(p, "difficulty").enumeration.is_open);
    try std.testing.expect(definitionNamed(p, "achievement").enumeration.persistable and definitionNamed(p, "achievement").enumeration.is_open);
    try std.testing.expect(definitionNamed(p, "coordinates").record.persistable);
    try std.testing.expect(definitionNamed(p, "player_profile").class.persistable and definitionNamed(p, "player_profile").class.is_final);
    // T5: every default is a constant of the field's type, and holds what the default builds.
    for (fieldsOf(p, "player_profile")) |field| {
        const constant = field.constant.?;
        try std.testing.expectEqual(field.value_type, p.constants[constant].value_type);
    }
    try expectDefaults(x, "coordinates", "Empty");
    const y = p.constants[fieldsOf(p, "coordinates")[1].constant.?];
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(y.kind.floating)));
    try live_tests.expectEveryMode(source);
}

test "T5: every literal form is a constant, bit for bit what both machines build for the default" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\e := enum<persistable>{A, B, C}
        \\inner := struct<persistable>{N:i64 = -7, S:string = "in"}
        \\all := struct<persistable>{
        \\    I:i64 = -9223372036854775808
        \\    J:i64 = 9223372036854775807
        \\    F:float = -1.5
        \\    Z:float = -0.0
        \\    N:float = NaN
        \\    P:float = Inf
        \\    M:float = -Inf
        \\    L:logic = true
        \\    C:char = 'q'
        \\    U:char = 0oFF
        \\    W:char32 = 0u10FFFF
        \\    S:string = "two words"
        \\    E:e = e.C
        \\    O:option(i64) = option{}
        \\    Q:option(option(i64)) = option{option{4}}
        \\    A:[]i64 = array{3, -1, 3}
        \\    T:tuple() = tuple{}
        \\    U2:tuple(i64, string, logic) = tuple{1, "t", false}
        \\    Mp:map(string, []i64) = map{"a" => array{}, "b" => array{1}}
        \\    Ms:map(inner, i64) = map{inner{} => 1, inner{N := 2} => 2}
        \\    R:inner = inner{S := "given"}
        \\    G:i64 = Block{12}
        \\}
        \\D:all = all{}
    ;
    const x = try h.execute(source);
    try expectDefaults(x, "all", "D");
    for (fieldsOf(x.program, "all")) |field| try std.testing.expect(field.constant != null);
    // A program that names no persistable type has no constants and no flags (the IR of every
    // program before P5.2).
    const plain = try h.compile("s := struct{X:i64 = 1}\nV:i64 = s{}.X");
    try std.testing.expectEqual(@as(usize, 0), plain.constants.len);
    try std.testing.expectEqual(@as(usize, 0), plain.constant_members.len);
    for (plain.fields) |field| try std.testing.expect(field.constant == null);
    try live_tests.expectEveryMode(source);
}

test "Book 17:67: the seven refused classes, each at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "not_final := class<persistable>{XP:i64 = 0}", .persistable_final, "not_final");
    try expectRefused(h, "is_unique := class<final><unique><persistable>{XP:i64 = 0}", .persistable_unique, "is_unique");
    try expectRefused(h, "some_base := class{XP:i64 = 0}\nhas_super := class<final><persistable>(some_base){}", .persistable_inherits, "has_super");
    try expectRefused(h, "some_marker := interface{}\nhas_interface := class<final><persistable>(some_marker){XP:i64 = 0}", .persistable_inherits, "has_interface");
    try expectRefused(h, "is_parametric[t:type] := class<final><persistable>{XP:i64 = 0}", .persistable_parametric, "persistable");
    try expectRefused(h, "has_var := class<final><persistable>{var XP:i64 = 0}", .persistable_field, "XP");
    try expectRefused(h, "StartingXP()<computes>:i64 = 0\ncalls_function := class<final><persistable>{XP:i64 = StartingXP()}", .persistable_default, "StartingXP");
    // Book 17:94, the class that is persistable.
    _ = try h.compile(
        \\player_profile := class<final><persistable>{
        \\    Version:i64 = 1
        \\    Title:string = ""
        \\    Unlocked:[]string = array{}
        \\    BestTimes:map(string, float) = map{}
        \\    LastScore:option(i64) = option{}
        \\}
    );
}

test "Book 17:126 and 17:135: a parametric struct and a var field are refused; coordinates is persistable" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "parametric_pair[t:type] := struct<persistable>{Value:i64}", .persistable_parametric, "persistable");
    try expectRefused(h, "mutable_point := struct<persistable>{var X:float = 0.0}", .persistable_field, "X");
    // Without the specifier a struct's `var` is what it was: no field form.
    try std.testing.expect(h.front.compile("mutable_point := struct{var X:float = 0.0}").failed.code != .persistable_field);
    const p = try h.compile("coordinates := struct<persistable>{X:float = 0.0, Y:float = 0.0}\nC:coordinates = coordinates{}");
    try std.testing.expect(definitionNamed(p, "coordinates").record.persistable);
    // Book 17:152.
    const e = try h.compile("difficulty := enum<persistable><closed>{Easy, Normal, Hard}\nachievement := enum<persistable><open>{FirstWin}");
    try std.testing.expect(definitionNamed(e, "difficulty").enumeration.persistable and definitionNamed(e, "achievement").enumeration.persistable);
}

test "Book 17:197: every prohibited field type is persistable_field at the field" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_][]const u8{
        "f_any := class<final><persistable>{Anything:any}",
        "f_rational := class<final><persistable>{Anything:rational}",
        "f_function := class<final><persistable>{Anything:function(tuple(i64), i64)}",
        "f_weak_map := class<final><persistable>{Anything:weak_map(i64, i64)}",
        "marker := interface{}\nf_interface := class<final><persistable>{Anything:marker}",
        "plain_enum := enum{Solo}\nf_enum := class<final><persistable>{Anything:plain_enum}",
        "plain_class := class{Value:i64 = 0}\nf_class := class<final><persistable>{Anything:plain_class}",
        "plain_struct := struct{Value:i64 = 0}\nf_struct := class<final><persistable>{Anything:plain_struct}",
        // And the kinds T2 adds: refinements, tasks, events, live types, handles, and what
        // holds any of them.
        "small := type{_X:i64 where 0 <= _X, _X <= 9}\nf := struct<persistable>{Anything:small}",
        "f := struct<persistable>{Anything:task(i64)}",
        "f := struct<persistable>{Anything:event(i64)}",
        "f := struct<persistable>{Anything:[]any}",
        "f := struct<persistable>{Anything:option(rational)}",
        "f := struct<persistable>{Anything:tuple(i64, function(tuple(), i64))}",
        "f := struct<persistable>{Anything:map(i64, any)}",
        "plain := struct{V:i64}\nf := struct<persistable>{Anything:[]plain}",
        "box[t:type] := struct<persistable>{V:t}\nf := struct<persistable>{Anything:i64}",
        "box[t:type] := struct{V:t}\nf := struct<persistable>{Anything:box[i64]}",
    };
    for (cases) |source| {
        const result = h.front.compile(source);
        const at = std.mem.indexOf(u8, source, "Anything").?;
        if (std.mem.indexOf(u8, source, "box[t:type] := struct<persistable>") != null) {
            try std.testing.expectEqual(Code.persistable_parametric, result.failed.code);
            continue;
        }
        if (result != .failed or result.failed.code != .persistable_field or result.failed.span.start != at) std.debug.print("{s}: {any}\n", .{ source, result });
        try std.testing.expectEqual(Code.persistable_field, result.failed.code);
        try std.testing.expectEqualStrings("Anything", result.failed.span.text(source));
    }
    // `comparable` and `type` are no field types in Forbic at all (the Book's other two rows).
    try std.testing.expect(h.front.compile("f := class<final><persistable>{Key:comparable}").failed.code != .persistable_field);
    try std.testing.expect(h.front.compile("f := class<final><persistable>{Shape:type}").failed.code != .persistable_field);
    // Persistable types hold each other, in any order a class may be named.
    _ = try h.compile("p := class<final><persistable>{Next:option(p) = option{}, Later:[]later = array{}}\nlater := class<final><persistable>{X:i64 = 1}\ns := struct<persistable>{P:option(p) = option{}}");
}

test "T3 to T5: the other refusals, each at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    // T3: live fields, fields with accessors, and `var live`.
    try expectRefused(h, "p := class<final><persistable>{live S:i64 = 1}", .persistable_field, "S");
    try expectRefused(h, "p := class<final><persistable>{var live S:i64 = 1}", .persistable_field, "S");
    try expectRefused(h,
        \\p := class<final><persistable>{
        \\    var A<getter(G)><setter(S)>:i64 = external{}
        \\    G(:accessor)<reads>:i64 = 1
        \\    S(:accessor, V:i64)<transacts>:void = Block{ 0 }
        \\}
    , .persistable_field, "A");
    try expectRefused(h, "p := class<abstract><persistable>{A:i64 = 2}", .persistable_final, "p");
    // An interface takes no specifier but effects.
    try expectRefused(h, "p := interface<persistable>{}", .unsupported_specifier, "persistable");
    // T1: each specifier once.
    try expectRefused(h, "p := struct<persistable><persistable>{S:i64 = 1}", .unsupported_specifier, "persistable");
    try expectRefused(h, "p := class<final><persistable><persistable>{S:i64 = 1}", .unsupported_specifier, "persistable");
    try expectRefused(h, "p := enum<persistable><open><closed>{A}", .unsupported_specifier, "closed");
    try expectRefused(h, "p := enum<persistable><persistable>{A}", .unsupported_specifier, "persistable");
    try expectRefused(h, "p := struct<final>{S:i64 = 1}", .unsupported_specifier, "final");
    // T5: what is not a literal constant, at the node that is not.
    try expectRefused(h, "M:i64 = 3\np := struct<persistable>{S:i64 = M}", .persistable_default, "M");
    try expectRefused(h, "p := struct<persistable>{S:i64 = 1 + 2}", .persistable_default, "+");
    try expectRefused(h, "p := struct<persistable>{S:string = \"a{1}\"}", .persistable_default, "{");
    try expectRefused(h, "p := struct<persistable>{S:float = 0.0 - 0.0}", .persistable_default, "-");
    try expectRefused(h, "F()<computes>:[]i64 = array{}\np := struct<persistable>{S:[]i64 = F()}", .persistable_default, "F");
    try expectRefused(h, "M:i64 = 3\np := struct<persistable>{S:[]i64 = array{1, M}}", .persistable_default, "M");
    try expectRefused(h, "p := struct<persistable>{S:i64 = If(true, 1, 2)}", .persistable_default, "If");
    try expectRefused(h, "q := struct<persistable>{N:i64 = 1}\nM:q = q{}\np := struct<persistable>{S:q = M}", .persistable_default, "M");
    // A map default with two equal keys has no value, by the language's equality: -0.0 and
    // 0.0 are one key, inside a struct too.
    try expectRefused(h, "p := struct<persistable>{M:map(i64, i64) = map{1 => 2, 1 => 3}}", .persistable_default, "M");
    try expectRefused(h, "p := struct<persistable>{M:map(float, i64) = map{0.0 => 2, -0.0 => 3}}", .persistable_default, "M");
    try expectRefused(h, "k := struct<persistable>{A:float = -0.0}\nq := struct<persistable>{X:i64 = 1}\np := struct<persistable>{Q:q = q{}, M:map(k, i64) = map{k{} => 1, k{A := 0.0} => 2}}", .persistable_default, "M");
    // Equal keys in a map that is no persistable default are what they were: fatal where built.
    _ = try h.compile("p := struct{M:map(i64, i64) = map{1 => 2, 1 => 3}}");
    // Without the specifier nothing is checked: a struct keeps any field and any default.
    _ = try h.compile("F()<computes>:i64 = 1\np := struct{S:i64 = F(), A:any = any(1)}");
    // Methods and block clauses are allowed (T3); no rule reads them.
    _ = try h.compile("p := class<final><persistable>{A:i64 = 2, G()<computes>:i64 = 3, Block{X := 1}}\nV:i64 = p{}.G()");
}

test "the word persistable is a specifier only: every name of it keeps its meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute("persistable := struct{X:i64 = 1}\nY:i64 = persistable{}.X");
    try std.testing.expectEqual(@as(i64, 1), x.get("Y").?.integer);
    x = try h.execute("persistable(X:i64)<computes>:i64 = X + 1\nY:i64 = persistable(1)");
    try std.testing.expectEqual(@as(i64, 2), x.get("Y").?.integer);
    x = try h.execute("F(persistable:i64)<computes>:i64 = Block{ Z := persistable; Z * 2 }\nY:i64 = F(4)");
    try std.testing.expectEqual(@as(i64, 8), x.get("Y").?.integer);
    x = try h.execute("p := struct<persistable>{persistable:i64 = 5}\nY:i64 = p{}.persistable");
    try std.testing.expectEqual(@as(i64, 5), x.get("Y").?.integer);
    x = try h.execute("persistable := enum<persistable>{persistable}\nY:persistable = persistable.persistable");
    try std.testing.expectEqual(@as(u32, 0), x.get("Y").?.enumeration.index);
    // In a bundle: a public persistable type is used from another module, which names the
    // type and its enumerator in defaults of its own.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nusing{L}\nhold := struct<persistable>{S:stats = stats{Level := 3}, M:mode = mode.Hard}\nX:i64 = hold{}.S.Level" },
        .{ .path = "lib.forb", .source = "stats<public> := struct<persistable>{Level:i64 = 1}\nmode<public> := enum<persistable>{Easy, Hard}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("{s}\n", .{bundled.failed.diagnostic.message()});
    try std.testing.expect(bundled == .ok);
    const run = (try h.run(bundled.ok, 1 << 20)).ok;
    try std.testing.expectEqual(@as(i64, 3), run.get("X").?.integer);
    try std.testing.expect(definitionNamed(bundled.ok, "hold").record.persistable);
    // A module's own type of the name is no specifier: a struct named `persistable` stays one.
    const named = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nusing{L}\nX:i64 = persistable{}.N" },
        .{ .path = "lib.forb", .source = "persistable<public> := struct{N:i64 = 6}" },
    };
    const both = h.front.compileBundle(.{ .root = "main.forb", .modules = &named });
    try std.testing.expect(both == .ok);
    try std.testing.expectEqual(@as(i64, 6), (try h.run(both.ok, 1 << 20)).ok.get("X").?.integer);
}

test "inspection format 39 prints the flags, the fields' constants and the table; a program without the specifier keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const buffer = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(buffer);
    const p = try h.compile("e := enum<persistable>{A, B}\ns := struct<persistable>{X:i64 = -2, E:e = e.B, A:[]i64 = array{7}, N:i64}\nc := class<final><persistable>{S:string = \"z\"}\nV:i64 = s{N := 1}.X");
    var out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, p));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 39), parsed.value.object.get("format").?.integer);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.buffered(), "\"persistable\":true"));
    var with_constant: usize = 0;
    for (parsed.value.object.get("fields").?.array.items) |item| if (item.object.get("constant") != null) {
        with_constant += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), with_constant);
    const constants = parsed.value.object.get("constants").?.array.items;
    try std.testing.expectEqual(p.constants.len, constants.len);
    const s_fields = fieldsOf(p, "s");
    try std.testing.expectEqual(@as(i64, -2), constants[s_fields[0].constant.?].object.get("integer").?.integer);
    try std.testing.expectEqual(@as(i64, 1), constants[s_fields[1].constant.?].object.get("enumeration").?.integer);
    try std.testing.expect(s_fields[3].constant == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("constant_members").?.array.items.len);
    // The same program without the specifier: no flag, no constant, an older format.
    const plain = try h.compile("e := enum{A, B}\ns := struct{X:i64 = -2, E:e = e.B, A:[]i64 = array{7}, N:i64}\nc := class<final>{S:string = \"z\"}\nV:i64 = s{N := 1}.X");
    out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, plain));
    const original = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer original.deinit();
    try std.testing.expect(original.value.object.get("format").?.integer < 32);
    try std.testing.expect(original.value.object.get("constants") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "persistable") == null);
}

/// The oracle's types: what a field may hold, built from the scalars, an enum, earlier structs
/// and the containers, with a name that is the type in Forbic.
const Shape = struct {
    const Kind = enum { i64, float, logic, string, char, char32, enumeration, record, array, option, tuple, map };
    kind: Kind,
    /// The element of an array or option, the second element of a tuple, a map's value.
    inner: u8 = 0,
    /// The first element of a tuple; a struct's number.
    other: u8 = 0,
};

const Generator = struct {
    random: std.Random,
    shapes: [64]Shape = undefined,
    shape_count: u8 = 0,
    /// The fields of each struct, by shape.
    structs: [6][6]u8 = undefined,
    widths: [6]u8 = @splat(0),
    /// The fields of each struct without a default, one bit each: every archetype gives them.
    required: [6]u8 = @splat(0),
    /// The field the oracle broke, which no archetype gives: its type is not its shape's.
    broken: [6]u8 = @splat(0),
    struct_count: u8 = 0,

    fn add(self: *Generator, made: Shape) u8 {
        std.debug.assert(self.shape_count < self.shapes.len);
        self.shapes[self.shape_count] = made;
        self.shape_count += 1;
        return self.shape_count - 1;
    }

    /// A shape of at most `depth` levels, of structs before `structs`.
    fn shape(self: *Generator, depth: u8, structs: u8) u8 {
        const leaf = depth == 0 or self.shape_count + 3 >= self.shapes.len;
        const choice = self.random.uintLessThan(u8, if (leaf) 8 else 12);
        return switch (choice) {
            0 => self.add(.{ .kind = .i64 }),
            1 => self.add(.{ .kind = .float }),
            2 => self.add(.{ .kind = .logic }),
            3 => self.add(.{ .kind = .string }),
            4 => self.add(.{ .kind = .char }),
            5 => self.add(.{ .kind = .char32 }),
            6 => self.add(.{ .kind = .enumeration }),
            7 => if (structs == 0) self.add(.{ .kind = .i64 }) else self.add(.{ .kind = .record, .other = self.random.uintLessThan(u8, structs) }),
            8 => self.add(.{ .kind = .array, .inner = self.shape(depth - 1, structs) }),
            9 => self.add(.{ .kind = .option, .inner = self.shape(depth - 1, structs) }),
            10 => self.add(.{ .kind = .tuple, .other = self.shape(depth - 1, structs), .inner = self.shape(depth - 1, structs) }),
            else => self.add(.{ .kind = .map, .other = self.add(.{ .kind = if (self.random.boolean()) .i64 else .string }), .inner = self.shape(depth - 1, structs) }),
        };
    }

    fn typeName(self: *const Generator, out: *std.Io.Writer, index: u8) !void {
        const s = self.shapes[index];
        switch (s.kind) {
            .i64, .float, .logic, .string, .char, .char32 => try out.writeAll(@tagName(s.kind)),
            .enumeration => try out.writeAll("e"),
            .record => try out.print("s{d}", .{s.other}),
            .array => {
                try out.writeAll("[]");
                try self.typeName(out, s.inner);
            },
            .option => {
                try out.writeAll("option(");
                try self.typeName(out, s.inner);
                try out.writeAll(")");
            },
            .tuple => {
                try out.writeAll("tuple(");
                try self.typeName(out, s.other);
                try out.writeAll(", ");
                try self.typeName(out, s.inner);
                try out.writeAll(")");
            },
            .map => {
                try out.writeAll("map(");
                try self.typeName(out, s.other);
                try out.writeAll(", ");
                try self.typeName(out, s.inner);
                try out.writeAll(")");
            },
        }
    }

    /// A literal constant of shape `index`; `key` numbers a map's keys so none is equal.
    fn literal(self: *Generator, out: *std.Io.Writer, index: u8, key: u32) !void {
        const s = self.shapes[index];
        switch (s.kind) {
            .i64 => try out.print("{d}", .{self.random.intRangeAtMost(i64, -1000, 1000) * @as(i64, if (key == 0) 1 else 0) + key}),
            .float => {
                const floats = [_][]const u8{ "0.0", "-0.0", "1.5", "-2.25", "NaN", "Inf", "-Inf", "1000000.0" };
                try out.writeAll(floats[self.random.uintLessThan(usize, floats.len)]);
            },
            .logic => try out.writeAll(if (self.random.boolean()) "true" else "false"),
            .string => if (key != 0) try out.print("\"k{d}\"", .{key}) else try out.print("\"v{d}\"", .{self.random.uintLessThan(u32, 100)}),
            .char => try out.print("'{c}'", .{@as(u8, 'a') + self.random.uintLessThan(u8, 26)}),
            .char32 => try out.print("0u{X}", .{0x1F600 + self.random.uintLessThan(u32, 64)}),
            .enumeration => try out.print("e.C{d}", .{self.random.uintLessThan(u8, 3)}),
            .record => {
                // The archetype gives some fields and leaves the others to their defaults.
                try out.print("s{d}{{", .{s.other});
                var first = true;
                for (self.structs[s.other][0..self.widths[s.other]], 0..) |field, position| {
                    if (self.broken[s.other] & (@as(u8, 1) << @intCast(position)) != 0) continue;
                    if (self.required[s.other] & (@as(u8, 1) << @intCast(position)) == 0 and self.random.boolean()) continue;
                    if (!first) try out.writeAll(", ");
                    first = false;
                    try out.print("F{d} := ", .{position});
                    try self.literal(out, field, 0);
                }
                try out.writeAll("}");
            },
            .array => {
                try out.writeAll("array{");
                for (0..self.random.uintLessThan(usize, 3)) |position| {
                    if (position != 0) try out.writeAll(", ");
                    try self.literal(out, s.inner, 0);
                }
                try out.writeAll("}");
            },
            .option => if (self.random.boolean()) try out.writeAll("option{}") else {
                try out.writeAll("option{");
                try self.literal(out, s.inner, 0);
                try out.writeAll("}");
            },
            .tuple => {
                try out.writeAll("tuple{");
                try self.literal(out, s.other, 0);
                try out.writeAll(", ");
                try self.literal(out, s.inner, 0);
                try out.writeAll("}");
            },
            .map => {
                try out.writeAll("map{");
                for (0..self.random.uintLessThan(u32, 3)) |position| {
                    if (position != 0) try out.writeAll(", ");
                    try self.literal(out, s.other, @intCast(position + 1));
                    try out.writeAll(" => ");
                    try self.literal(out, s.inner, 0);
                }
                try out.writeAll("}");
            },
        }
    }
};

/// How the oracle breaks a program: one field of one struct is made to break one rule.
const Breach = enum { none, var_field, plain_type, call_default, name_default, arithmetic_default, duplicate_key };

test "oracle: random persistable types and literal defaults: every constant is what both machines build; one broken rule is refused where the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5052_5332);
    const buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buffer);
    var checked_constants: usize = 0;
    var refusals: [std.enums.values(Breach).len]usize = @splat(0);
    for (0..80) |round| {
        var g: Generator = .{ .random = prng.random() };
        var out = std.Io.Writer.fixed(buffer);
        try out.writeAll("e := enum<persistable>{C0, C1, C2}\nplain := struct{V:i64 = 0}\nM:i64 = 4\nF()<computes>:i64 = 5\n");
        g.struct_count = 1 + g.random.uintLessThan(u8, 5);
        const breach: Breach = if (round < 20) .none else @fromBackingInt(@intCast(g.random.uintLessThan(u8, std.enums.values(Breach).len)));
        const broken_struct = g.random.uintLessThan(u8, g.struct_count);
        // Where the broken field's name is, and the text a refusal is reported at.
        var expected_at: []const u8 = "";
        var expected_name_offset: usize = 0;
        for (0..g.struct_count) |index| {
            const width = 1 + g.random.uintLessThan(u8, 5);
            g.widths[index] = width;
            try out.print("s{d} := struct<persistable>{{", .{index});
            for (0..width) |position| {
                const field = g.shape(2, @intCast(index));
                g.structs[index][position] = field;
                if (position != 0) try out.writeAll(", ");
                if (breach != .none and index == broken_struct and position == width - 1) {
                    g.broken[index] |= @as(u8, 1) << @intCast(position);
                    if (breach == .var_field) try out.writeAll("var ");
                    expected_name_offset = out.end;
                    switch (breach) {
                        .var_field => {
                            try out.print("F{d}:", .{position});
                            try g.typeName(&out, field);
                            try out.writeAll(" = ");
                            try g.literal(&out, field, 0);
                        },
                        .plain_type => try out.print("F{d}:plain = plain{{}}", .{position}),
                        .duplicate_key => try out.print("F{d}:map(i64, i64) = map{{1 => 2, 1 => 3}}", .{position}),
                        else => {
                            // The form, and the node of it that is no literal.
                            const form: [2][]const u8 = switch (breach) {
                                .call_default => .{ "F()", "F" },
                                .name_default => .{ "M", "M" },
                                else => .{ "2 * 3", "*" },
                            };
                            expected_at = form[1];
                            try out.print("F{d}:i64 = {s}", .{ position, form[0] });
                        },
                    }
                    continue;
                }
                try out.print("F{d}:", .{position});
                try g.typeName(&out, field);
                // A field without a default has no constant; the rest have one.
                if (g.random.uintLessThan(u8, 4) == 0) {
                    g.required[index] |= @as(u8, 1) << @intCast(position);
                    continue;
                }
                try out.writeAll(" = ");
                try g.literal(&out, field, 0);
            }
            try out.writeAll("}\n");
        }
        for (0..g.struct_count) |index| {
            try out.print("D{d}:s{d} = s{d}{{", .{ index, index, index });
            var first = true;
            for (0..g.widths[index]) |position| if (g.required[index] & (@as(u8, 1) << @intCast(position)) != 0) {
                if (!first) try out.writeAll(", ");
                first = false;
                try out.print("F{d} := ", .{position});
                try g.literal(&out, g.structs[index][position], 0);
            };
            try out.writeAll("}\n");
        }
        const source = out.buffered();
        if (breach != .none) {
            const result = h.front.compile(source);
            if (result != .failed) {
                std.debug.print("{t} compiled: {s}\n", .{ breach, source });
                return error.Compiled;
            }
            const name_end = std.mem.indexOfScalarPos(u8, source, expected_name_offset, ':').?;
            const field_name = source[expected_name_offset..name_end];
            const code: Code = switch (breach) {
                .var_field, .plain_type => .persistable_field,
                else => .persistable_default,
            };
            const at = if (expected_at.len != 0) expected_at else field_name;
            if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), at)) {
                std.debug.print("{t}: {t} at `{s}`, expected {t} at `{s}`: {s}\n", .{ breach, result.failed.code, result.failed.span.text(source), code, at, source });
                return error.TestUnexpectedResult;
            }
            refusals[@backingInt(breach)] += 1;
            continue;
        }
        const p = try h.compile(source);
        const x = (try h.run(p, 1 << 20)).ok;
        var name_buffer: [8]u8 = undefined;
        for (0..g.struct_count) |index| {
            const struct_name = try std.fmt.bufPrint(&name_buffer, "s{d}", .{index});
            const fields = fieldsOf(p, struct_name);
            var binding_buffer: [8]u8 = undefined;
            const binding = try std.fmt.bufPrint(&binding_buffer, "D{d}", .{index});
            const members = x.elements(x.get(binding).?).?;
            for (fields, members) |field, held| if (field.constant) |constant| {
                try expectConstant(x, constant, held);
                checked_constants += 1;
            };
            try std.testing.expect(definitionNamed(p, struct_name).record.persistable);
        }
        // The catalogue's persistable types, by the shared pass, are exactly the flagged
        // types and the containers of them (T2): here, every type the program has but `plain`.
        const kinds = try allocator.alloc(bool, p.definitions.len);
        defer allocator.free(kinds);
        persistable.persistableTypes(p.definitions, p.tuple_elements, kinds);
        for (p.definitions, kinds) |item, kind| {
            const plain_struct = item == .record and std.mem.eql(u8, item.record.name.text(p.source), "plain");
            const expected = !plain_struct and item != .callable;
            if (kind != expected) std.debug.print("{any}: {any}\n", .{ item, kind });
            try std.testing.expectEqual(expected, kind);
        }
    }
    try std.testing.expect(checked_constants > 100);
    for (refusals[1..]) |count| try std.testing.expect(count > 0);
}
