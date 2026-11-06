//! RFC-0087, P5.6: the schema of compiled programs (G1) and the check between versions of one
//! program (G3), with the places of its refusals in the program's text, in single files and in
//! bundles; and the schema and the check at the `program` profile's scale. The rules on texts,
//! forged texts and bounds are tested in `persist_schema.zig`, and the rules against the model in
//! `persist_json_model.zig` (PM4 to PM6).
const std = @import("std");
const builtin = @import("builtin");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const profile = @import("profile.zig");
const modules = @import("modules.zig");
const persist_schema = @import("persist_schema.zig");
const harness = @import("generic_function_tests.zig");

const allocator = std.testing.allocator;

fn describe(arena: std.mem.Allocator, h: *harness.Harness, source: []const u8) !persist_schema.Description {
    return persist_schema.describe(arena, try h.compile(source));
}

test "G1: a program's schema lists its persistent cells and each type they reach once, in the order they are met" {
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\mode := enum<persistable><open>{Easy, Normal}
        \\node := class<final><persistable>{ Next:option(node) = option{}, Mode:mode = mode.Normal, Tags:map(string, []i64) = map{"a" => array{1}} }
        \\pair := struct<persistable>{ Left:i64, Right:tuple(mode, float) = tuple{mode.Easy, -0.0} }
        \\unrelated := struct<persistable>{ X:i64 = 0 }
        \\var Nodes:weak_map(persistent_key, node) = map{}
        \\var Session:weak_map(session, i64) = map{}
        \\var Pairs:weak_map(persistent_key, []pair) = map{}
        \\var Counts:weak_map(persistent_key, i64) = map{}
        \\V:i64 = 1
    ;
    const description = try describe(arena, h, source);
    try std.testing.expectEqualStrings(
        "{\"schema\":1,\"cells\":[{\"cell\":\":Nodes\",\"key\":\"persistent_key\",\"value\":0},{\"cell\":\":Pairs\",\"key\":\"persistent_key\",\"value\":1},{\"cell\":\":Counts\",\"key\":\"persistent_key\",\"value\":2}]," ++
            "\"types\":[{\"class\":{\"package\":\"/\",\"name\":\"node\",\"fields\":[{\"name\":\"Next\",\"type\":3,\"default\":\"false\"},{\"name\":\"Mode\",\"type\":4,\"default\":\"\\\"mode::Normal\\\"\"},{\"name\":\"Tags\",\"type\":5,\"default\":\"[{\\\"k\\\":{\\\"\\\":\\\"a\\\"},\\\"v\\\":{\\\"\\\":[1]}}]\"}]}}," ++
            "{\"array\":6},{\"primitive\":\"i64\"},{\"option\":0},{\"enum\":{\"package\":\"/\",\"name\":\"mode\",\"open\":true,\"cases\":[\"Easy\",\"Normal\"]}},{\"map\":[7,8]}," ++
            "{\"struct\":{\"package\":\"/\",\"name\":\"pair\",\"fields\":[{\"name\":\"Left\",\"type\":2},{\"name\":\"Right\",\"type\":9,\"default\":\"[\\\"mode::Easy\\\",-0]\"}]}},{\"primitive\":\"string\"},{\"array\":2},{\"tuple\":[4,10]},{\"primitive\":\"float\"}]}\n",
        description.text,
    );
    // The schema's cells are the program's persistent cells, the session cell left out; its types
    // are the program's own.
    try std.testing.expectEqual(@as(usize, 3), description.cells.len);
    try std.testing.expectEqual(@as(u32, 3), description.cells[2]);
    // A pure function of the persistent types: other declarations, around and between them, and
    // another order of the types, leave the text as it was.
    const reordered =
        \\other := class<final>{ var Y:i64 = 0 }
        \\mode := enum<persistable><open>{Easy, Normal}
        \\pair := struct<persistable>{ Left:i64, Right:tuple(mode, float) = tuple{mode.Easy, -0.0} }
        \\F(X:i64)<computes>:i64 = X + 1
        \\node := class<final><persistable>{ Next:option(node) = option{}, Mode:mode = mode.Normal, Tags:map(string, []i64) = map{"a" => array{1}} }
        \\var Nodes:weak_map(persistent_key, node) = map{}
        \\var Plain:i64 = 4
        \\var Pairs:weak_map(persistent_key, []pair) = map{}
        \\var Counts:weak_map(persistent_key, i64) = map{}
        \\V:i64 = F(1)
    ;
    try std.testing.expectEqualStrings(description.text, (try describe(arena, h, reordered)).text);
    // A structural type with one part many times is one entry with one part, many times.
    const repeated = try describe(arena, h, "var Cells:weak_map(persistent_key, tuple([]i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64, []i64)) = map{}\nV:i64 = 1");
    try std.testing.expectEqualStrings("{\"schema\":1,\"cells\":[{\"cell\":\":Cells\",\"key\":\"persistent_key\",\"value\":0}],\"types\":[{\"tuple\":[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]},{\"array\":2},{\"primitive\":\"i64\"}]}\n", repeated.text);
    // A program without persistent cells has an empty schema.
    try std.testing.expectEqualStrings("{\"schema\":1,\"cells\":[],\"types\":[]}\n", (try describe(arena, h, "var S:weak_map(session, i64) = map{}\nV:i64 = 1")).text);
}

test "G1: each default is the text ToJson writes for it, every literal form included" {
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A struct whose fields all have defaults: `ToJson(all{})` is its metadata, then each field and
    // its default's text, which the schema must hold.
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
        \\    Tiny:float = 5.0e-324
        \\    L:logic = true
        \\    C:char = 'q'
        \\    U:char = 0oFF
        \\    W:char32 = 0u10FFFF
        \\    S:string = "two \"words\"\n\t\\ and"
        \\    E:e = e.C
        \\    O:option(i64) = option{}
        \\    Q:option(option(i64)) = option{option{4}}
        \\    A:[]i64 = array{3, -1, 3}
        \\    T:tuple() = tuple{}
        \\    U2:tuple(i64, string, logic) = tuple{1, "t", false}
        \\    Mp:map(string, []i64) = map{"a" => array{}, "b" => array{1}}
        \\    In:inner = inner{S := "x"}
        \\    Ins:[]inner = array{inner{}, inner{N := 2}}
        \\}
        \\var Alls:weak_map(persistent_key, all) = map{}
        \\Saved:string = ToJson(all{})
    ;
    const p = try h.compile(source);
    const description = try persist_schema.describe(arena, p);
    const x = try h.run(p, 1 << 20);
    const saved = x.ok.get("Saved").?.string;
    const schema = (try persist_schema.parse(arena, description.text)).full;
    const object = schema.types[schema.cells[0].value].@"struct";
    var expected: std.ArrayList(u8) = .empty;
    try expected.appendSlice(arena, "{\"$package_name\":\"/\",\"$class_name\":\"all\"");
    for (object.fields) |field| {
        try expected.print(arena, ",\"x_{s}\":{s}", .{ field.name, field.default.? });
    }
    try expected.append(arena, '}');
    try std.testing.expectEqualStrings(saved, expected.items);
}

test "G1 and G3 in a bundle: package and store names are the files' and modules', and a refusal is located in the file that declares what it names" {
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]modules.Input{
        .{ .path = "main.forb", .source = "Progress := import{\"kit/progress.forb\"}\nV:i64 = 1\n" },
        .{ .path = "kit/progress.forb", .source = "stats<public> := class<final><persistable>{ Level:i64 = 1 }\nSlots<public> := module{\n    var Data<public>:weak_map(persistent_key, stats) = map{}\n    var Old<public>:weak_map(persistent_key, i64) = map{}\n}\n" },
    };
    const old = try persist_schema.describe(arena, switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &before })) {
        .ok => |program| program,
        .failed => return error.Compile,
    });
    try std.testing.expectEqualStrings("{\"schema\":1,\"cells\":[{\"cell\":\"kit/progress.forb:Slots.Data\",\"key\":\"persistent_key\",\"value\":0},{\"cell\":\"kit/progress.forb:Slots.Old\",\"key\":\"persistent_key\",\"value\":1}],\"types\":[{\"class\":{\"package\":\"/kit/progress.forb\",\"name\":\"stats\",\"fields\":[{\"name\":\"Level\",\"type\":1,\"default\":\"1\"}]}},{\"primitive\":\"i64\"}]}\n", old.text);
    // The next version drops a cell and changes a default: located in main.forb (the start of the
    // root file) and in kit/progress.forb (the field).
    const after = [_]modules.Input{
        .{ .path = "main.forb", .source = "Progress := import{\"kit/progress.forb\"}\nV:i64 = 1\n" },
        .{ .path = "kit/progress.forb", .source = "stats<public> := class<final><persistable>{ Level:i64 = 2 }\nSlots<public> := module{\n    var Data<public>:weak_map(persistent_key, stats) = map{}\n}\n" },
    };
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &after })) {
        .ok => |compiled| compiled,
        .failed => return error.Compile,
    };
    const new = try persist_schema.describe(arena, program);
    const outcome = try persist_schema.check(arena, old.text, new.text);
    try std.testing.expectEqual(@as(usize, 2), outcome.refusals.len);
    const expected = [_]struct { path: []const u8, line: u32, column: u32, reason: []const u8 }{
        .{ .path = "main.forb", .line = 1, .column = 1, .reason = "persistent cell kit/progress.forb:Slots.Old removed: the store holds its entries" },
        .{ .path = "kit/progress.forb", .line = 1, .column = 45, .reason = "the default of field Level of class stats (/kit/progress.forb) changed from 1 to 2" },
    };
    for (outcome.refusals, expected) |refusal, want| {
        const located = modules.locate(program.source, program.paths, program.modules, .{ .span = persist_schema.located(program, new, refusal.place), .code = .schema_incompatible }, "?");
        const position = located.diagnostic.location(located.source);
        try std.testing.expectEqualStrings(want.path, located.path);
        try std.testing.expectEqual(want.line, position.line);
        try std.testing.expectEqual(want.column, position.column);
        try std.testing.expectEqualStrings(want.reason, refusal.reason);
    }
}

test "G3: each place a refusal names is the declaration in the new program, in a single file" {
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = try describe(arena, h,
        \\mode := enum<persistable><closed>{Easy, Hard}
        \\stats := class<final><persistable>{ Level:i64 = 1, Mode:mode = mode.Easy }
        \\var Stats:weak_map(persistent_key, stats) = map{}
        \\var Gone:weak_map(persistent_key, i64) = map{}
        \\V:i64 = 1
    );
    const source =
        \\V:i64 = 1
        \\mode := enum<persistable><closed>{Easy, Hard, Mythic}
        \\stats := class<final><persistable>{ Mode:mode = mode.Easy, Level:string = "1", Extra:i64 }
        \\var Stats:weak_map(persistent_key, stats) = map{}
    ;
    const program = try h.compile(source);
    const new = try persist_schema.describe(arena, program);
    const outcome = try persist_schema.check(arena, old.text, new.text);
    const expected = [_]struct { at: []const u8, reason: []const u8 }{
        .{ .at = "", .reason = "persistent cell :Gone removed: the store holds its entries" },
        .{ .at = "Level", .reason = "field Level of class stats moved: the fields of saved entries keep their order" },
        .{ .at = "Level", .reason = "the default of field Level of class stats changed from 1 to \"1\"" },
        .{ .at = "Level", .reason = "field Level of class stats: the store's i64 is now string" },
        .{ .at = "Extra", .reason = "field Extra added to class stats without a default: the store's entries lack it" },
        .{ .at = "Mythic", .reason = "enumerator Mythic added to closed enum mode" },
    };
    try std.testing.expectEqual(expected.len, outcome.refusals.len);
    for (outcome.refusals, expected) |refusal, want| {
        const span = persist_schema.located(program, new, refusal.place);
        try std.testing.expectEqualStrings(want.at, source[span.start..span.end]);
        try std.testing.expectEqualStrings(want.reason, refusal.reason);
    }
    // The type itself, for a removal: the type's name.
    const shrunk_source =
        \\mode := enum<persistable><closed>{Easy}
        \\stats := class<final><persistable>{ Level:i64 = 1, Mode:mode = mode.Easy }
        \\var Stats:weak_map(persistent_key, stats) = map{}
        \\var Gone:weak_map(persistent_key, i64) = map{}
        \\V:i64 = 1
    ;
    const shrunk = try h.compile(shrunk_source);
    const shrunk_new = try persist_schema.describe(arena, shrunk);
    const removal = (try persist_schema.check(arena, old.text, shrunk_new.text)).refusals;
    try std.testing.expectEqual(@as(usize, 1), removal.len);
    const span = persist_schema.located(shrunk, shrunk_new, removal[0].place);
    try std.testing.expectEqualStrings("mode", shrunk_source[span.start..span.end]);
    try std.testing.expectEqualStrings("enumerator Hard of enum mode removed", removal[0].reason);
}

// ---- Scale (the `program` profile) -------------------------------------------------------------

fn requireProgram() error{SkipZigTest}!void {
    if (!std.mem.eql(u8, profile.active.name, "program")) return error.SkipZigTest;
}

fn budget(within: bool) !void {
    if (builtin.mode == .debug) return;
    try std.testing.expect(within);
}

fn elapsedMs(start: std.Io.Timestamp) u64 {
    const nanoseconds = start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds();
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
}

/// `count` persistable classes, each with a field of the class before it and of an enum, and a
/// persistent cell of each: with `grown`, each class has one more field with a default and the
/// enum one more case; with `broken`, every class's first field has another default.
fn scaleSource(gpa: std.mem.Allocator, count: usize, grown: bool, broken: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (grown) "mode := enum<persistable><open>{A, B, C}\n" else "mode := enum<persistable><open>{A, B}\n");
    for (0..count) |i| {
        try out.print(gpa, "c{d} := class<final><persistable>{{ N:i64 = {d}, M:mode = mode.A, T:tuple(i64, []string) = tuple{{{d}, array{{}}}}", .{ i, if (broken) i + 1 else i, i });
        if (i != 0) try out.print(gpa, ", P:option(c{d}) = option{{}}", .{i - 1});
        if (grown) try out.appendSlice(gpa, ", G:[]i64 = array{}");
        try out.appendSlice(gpa, " }\n");
        try out.print(gpa, "var V{d}:weak_map(persistent_key, c{d}) = map{{}}\n", .{ i, i });
    }
    try out.appendSlice(gpa, "Z:i64 = 1\n");
    return out.toOwnedSlice(gpa);
}

test "rfc0087 P5.6: the schema of four thousand persistent cells over four thousand classes is written and checked in milliseconds" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const count = 4000;
    try std.testing.expect(count <= types.limits.source_cells);
    const sources = [_][]u8{ try scaleSource(allocator, count, false, false), try scaleSource(allocator, count, true, false), try scaleSource(allocator, count, true, true) };
    defer for (sources) |source| allocator.free(source);
    var texts: [3][]const u8 = undefined;
    var described_ms: u64 = 0;
    for (sources, &texts) |source, *text| {
        const p = try h.compile(source);
        const begun = std.Io.Clock.awake.now(std.testing.io);
        const description = try persist_schema.describe(arena, p);
        described_ms = @max(described_ms, elapsedMs(begun));
        try std.testing.expectEqual(@as(usize, count), description.cells.len);
        text.* = description.text;
    }
    // Every class once, the enum, and the shared structural types and primitives.
    const schema = (try persist_schema.parse(arena, texts[0])).full;
    try std.testing.expectEqual(@as(usize, count + 5 + count - 1), schema.types.len);
    const begun = std.Io.Clock.awake.now(std.testing.io);
    // The same, and the evolution: compatible. Back: every class refuses its removed field, and the
    // enum its case. Broken: every class refuses the default of its first field.
    try std.testing.expectEqual(@as(usize, 0), (try persist_schema.check(arena, texts[0], texts[0])).refusals.len);
    try std.testing.expectEqual(@as(usize, 0), (try persist_schema.check(arena, texts[0], texts[1])).refusals.len);
    try std.testing.expectEqual(@as(usize, count + 1), (try persist_schema.check(arena, texts[1], texts[0])).refusals.len);
    try std.testing.expectEqual(@as(usize, count), (try persist_schema.check(arena, texts[1], texts[2])).refusals.len);
    const checked_ms = elapsedMs(begun);
    try budget(described_ms < 2_000 and checked_ms < 4_000);
}
