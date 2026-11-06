//! Persistent cells (RFC-0087, P5.5), continued: keys (K2), loads (S4) and store actions (S5) on
//! both machines, in `persistent_cell_tests.zig`'s bench. Each test names the rule it shows.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const modules = @import("modules.zig");
const cells = @import("persistent_cell_tests.zig");

const Bench = cells.Bench;
const committed = cells.committed;
const reportOf = cells.reportOf;
const standard_grants = cells.standard_grants;

const stats_types =
    \\player_stats<public> := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
    \\var Stats<public>:weak_map(persistent_key, player_stats) = map{}
    \\GetStats(Key:persistent_key)<reads>:player_stats = Attempt(Stats[Key], player_stats{})
    \\
;
const alice_stats = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":7}";
const bob_stats = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":9,\"x_Experience\":1}";

test "K2: keys are granted by name among keys only; they are equal by grant, comparable, and values like any other" {
    const grants = [_]effects.Grant{ .{ .kind = .reader, .name = "alice" }, .{ .kind = .key, .name = "alice" }, .{ .kind = .key, .name = "bob" } };
    const b = try Bench.create(&grants, &.{});
    defer b.destroy();
    const x = try b.run(
        \\A:option(persistent_key) = option{GetPersistentKey["alice"]}
        \\B:option(persistent_key) = option{GetPersistentKey["bob"]}
        \\C:option(persistent_key) = option{GetPersistentKey["carol"]}
        \\Same:logic = Attempt(GetPersistentKey["alice"] == GetPersistentKey["alice"], false)
        \\Other:logic = Attempt(GetPersistentKey["alice"] == GetPersistentKey["bob"], true)
        \\Made(N:string)<reads><decides>:persistent_key = GetPersistentKey[N]
        \\Named:i64 = Attempt(Block{K := Made["ali" + "ce"]; 1}, 0)
        \\Pair:option(tuple(persistent_key, i64)) = option{tuple{GetPersistentKey["bob"], 5}}
        \\M:option(map(persistent_key, string)) = option{map{GetPersistentKey["bob"] => "b", GetPersistentKey["alice"] => "a"}}
        \\Xs:option([]persistent_key) = option{array{GetPersistentKey["bob"], GetPersistentKey["alice"]}}
    );
    var report: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("{\"A\":[{\"$key\":\"alice\"}],\"B\":[{\"$key\":\"bob\"}],\"C\":[],\"Same\":true,\"Other\":false,\"Named\":1,\"Pair\":[[{\"$key\":\"bob\"},5]],\"M\":[[{\"$key\":\"bob\"},\"b\",{\"$key\":\"alice\"},\"a\"]],\"Xs\":[[{\"$key\":\"bob\"},{\"$key\":\"alice\"}]]}\n", try reportOf(x, &report));
}

test "K2: a key has no members, is no value of any, and cannot be built or cast; the names yield to every declaration" {
    const grants = [_]effects.Grant{.{ .kind = .key, .name = "alice" }};
    const b = try Bench.create(&grants, &.{});
    defer b.destroy();
    try b.refused("K:persistent_key = persistent_key{}\nV:i64 = 1", .unknown_name, "persistent_key");
    try b.refused("F()<reads><decides>:any = any(GetPersistentKey[\"alice\"])\nV:i64 = 1", .type_mismatch, "GetPersistentKey");
    try b.refused("F(K:persistent_key)<computes>:i64 = K.Name\nV:i64 = 1", .unknown_field, "Name");
    // Looked up outside a failure context, and in a function that does not read.
    try b.refused("K:persistent_key = GetPersistentKey[\"alice\"]\nV:i64 = 1", .failure_context_required, "GetPersistentKey");
    try b.refused("F()<computes><decides>:persistent_key = GetPersistentKey[\"alice\"]\nV:i64 = 1", .call_requires_reads, "GetPersistentKey");
    // Called with parentheses, and with a name that is no string.
    try b.refused("K:option(persistent_key) = option{GetPersistentKey(\"alice\")}\nV:i64 = 1", .expected_call, "GetPersistentKey");
    try b.refused("K:option(persistent_key) = option{GetPersistentKey[1]}\nV:i64 = 1", .type_mismatch, "1");
    // Each name means a declaration of it, in every role.
    const own = try b.run(
        \\persistent_key := struct{N:i64}
        \\GetPersistentKey(S:string)<computes>:i64 = 40
        \\K:persistent_key = persistent_key{N := GetPersistentKey("x") + 2}
        \\V:i64 = K.N
    );
    try std.testing.expectEqual(@as(i64, 42), own.get("V").?.integer);
    const local = try b.run("V:i64 = Block{persistent_key := 5; GetPersistentKey := 6; persistent_key + GetPersistentKey}");
    try std.testing.expectEqual(@as(i64, 11), local.get("V").?.integer);
    const parameter = try b.run("F(GetPersistentKey:i64, persistent_key:i64)<computes>:i64 = GetPersistentKey * persistent_key\nV:i64 = F(6, 7)");
    try std.testing.expectEqual(@as(i64, 42), parameter.get("V").?.integer);
}

test "S4: a persistent cell starts as its entries, for each key in grant order, from the record; absent entries are absent" {
    const stored = [_]effects.Stored{
        .{ .request = effects.loadRequest(0, 2), .text = bob_stats },
        .{ .request = effects.loadRequest(0, 1), .text = alice_stats },
    };
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(stats_types ++
        \\A:i64 = Attempt(Stats[GetPersistentKey["alice"]].Level, -1)
        \\B:i64 = Attempt(Stats[GetPersistentKey["bob"]].Level, -1)
        \\Count:i64 = Attempt(Block{GetStats(GetPersistentKey["alice"]).Level + GetStats(GetPersistentKey["bob"]).Experience}, -1)
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 9), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("Count").?.integer);
    // Two loads, one per key grant in grant order, as inputs of kind `load` at tick 0.
    try std.testing.expectEqual(@as(usize, 2), x.effects.inputs.len);
    for (x.effects.inputs, [_]u32{ 1, 2 }) |entry, grant| {
        try std.testing.expectEqual(effects.InputKind.load, entry.kind);
        try std.testing.expectEqual(effects.loadRequest(0, grant), entry.request);
        try std.testing.expectEqual(@as(u64, 0), entry.tick);
    }
    try std.testing.expectEqualStrings(alice_stats ++ bob_stats, x.effects.input_bytes);
    var report: [2048]u8 = undefined;
    const text = try reportOf(x, &report);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Stats\":[{\"$key\":\"alice\"},{\"Level\":3,\"Experience\":7},{\"$key\":\"bob\"},{\"Level\":9,\"Experience\":1}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"$inputs\":{\"count\":2,\"bytes\":") != null);
    // Nothing is stored: every entry is at its end, and the record still holds the loads.
    const empty = try Bench.create(&standard_grants, &.{});
    defer empty.destroy();
    const y = try empty.run(stats_types ++ "A:i64 = Attempt(Stats[GetPersistentKey[\"alice\"]].Level, -1)");
    try std.testing.expectEqual(@as(i64, -1), y.get("A").?.integer);
    try std.testing.expectEqual(@as(usize, 2), y.effects.inputs.len);
    for (y.effects.inputs) |entry| try std.testing.expectEqual(effects.InputStatus.end, entry.status);
    // No key granted: no load at all.
    const none = try Bench.create(&.{.{ .kind = .writer, .name = "log" }}, &.{});
    defer none.destroy();
    const z = try none.run(stats_types ++ "A:i64 = Attempt(Stats[GetPersistentKey[\"alice\"]].Level, -1)");
    try std.testing.expectEqual(@as(i64, -1), z.get("A").?.integer);
    try std.testing.expectEqual(@as(usize, 0), z.effects.inputs.len);
}

test "S4: several persistent cells, each asking for every key; the request names the cell and the grant" {
    const stored = [_]effects.Stored{
        .{ .request = effects.loadRequest(0, 1), .text = "5" },
        .{ .request = effects.loadRequest(2, 2), .text = "[\"x\",\"y\"]" },
        .{ .request = effects.loadRequest(2, 1), .text = "[]" },
    };
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(
        \\var Counts:weak_map(persistent_key, i64) = map{}
        \\Mid:i64 = 1
        \\var Plain:weak_map(i64, i64) = map{}
        \\var Names:weak_map(persistent_key, []string) = map{}
        \\Alice()<reads><decides>:persistent_key = GetPersistentKey["alice"]
        \\Bob()<reads><decides>:persistent_key = GetPersistentKey["bob"]
        \\C:i64 = Attempt(Counts[Alice[]], -1)
        \\D:i64 = Attempt(Counts[Bob[]], -1)
        \\N:i64 = Attempt(Names[Bob[]].Length, -1)
        \\M:i64 = Attempt(Names[Alice[]].Length, -1)
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("N").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("M").?.integer);
    // `Counts` is cell 0, `Plain` cell 1 and `Names` cell 2 (`Mid` is no cell).
    try std.testing.expectEqual(@as(usize, 4), x.effects.inputs.len);
    const wanted = [_]u32{ effects.loadRequest(0, 1), effects.loadRequest(0, 2), effects.loadRequest(2, 1), effects.loadRequest(2, 2) };
    for (x.effects.inputs, wanted) |entry, request| try std.testing.expectEqual(request, entry.request);
}

test "S5: a write is a store action on its own channel, committed in program order with the lines around it, and aborted with its region" {
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = alice_stats }};
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(stats_types ++
        \\Level(Key:persistent_key, L:i64)<reads><writes>:i64 = Block{
        \\    set Stats[Key] = player_stats{Level := L, Experience := GetStats(Key).Experience}
        \\    L
        \\}
        \\Alice()<reads><decides>:persistent_key = GetPersistentKey["alice"]
        \\Bob()<reads><decides>:persistent_key = GetPersistentKey["bob"]
        \\Kept:i64 = Attempt(Block{Print("a"); Level(Alice[], 10); Print("b"); 1}, 0)
        \\Gone:i64 = Attempt(Block{
        \\    Print("c")
        \\    Level(Bob[], 20)
        \\    Attempt(Block{Level(Alice[], 30); Print("d"); Require[false]; 0}, 0)
        \\    Level(Bob[], 21)
        \\    Require[false]
        \\    1
        \\}, 0)
        \\Deep:i64 = Attempt(Block{
        \\    Level(Alice[], 40)
        \\    Attempt(Block{Level(Bob[], 50); Attempt(Block{Level(Alice[], 60); Require[false]; 0}, 0); Print("e"); Level(Bob[], 51)}, 0)
        \\    1
        \\}, 0)
        \\Last:i64 = Attempt(Stats[Alice[]].Level, -1) * 1000 + Attempt(Stats[Bob[]].Level, -1)
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("Gone").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Deep").?.integer);
    try std.testing.expectEqual(@as(i64, 40 * 1000 + 51), x.get("Last").?.integer);
    var buffer: [4096]u8 = undefined;
    const prefix = "{\"cell\":\":Stats\",\"key\":\"";
    const alice10 = prefix ++ "alice\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":10,\"x_Experience\":7}}\n";
    const alice40 = prefix ++ "alice\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":40,\"x_Experience\":7}}\n";
    const bob50 = prefix ++ "bob\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":50,\"x_Experience\":0}}\n";
    const bob51 = prefix ++ "bob\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":51,\"x_Experience\":0}}\n";
    try std.testing.expectEqualStrings(alice10 ++ alice40 ++ bob50 ++ bob51, committed(x, effects.store_channel, &buffer));
    try std.testing.expectEqualStrings("a\nb\ne\n", committed(x, 0, &buffer));
    // Gone's two writes, its line and the nested write and line, and Deep's innermost write, were
    // prepared and dropped.
    try std.testing.expectEqual(@as(u64, 6), x.effects.discarded);
    // One sequence for every channel: the lines and the actions in the order they were made.
    try std.testing.expectEqual(@as(usize, 7), x.effects.entries.len);
    const channels = [_]u32{ 0, effects.store_channel, 0, effects.store_channel, effects.store_channel, 0, effects.store_channel };
    for (x.effects.entries, channels) |entry, channel| try std.testing.expectEqual(channel, entry.channel);
}

test "S5, S2: nested and compound updates save the whole new value; names are escaped; a cell of a nested module has its path" {
    const grants = [_]effects.Grant{ .{ .kind = .key, .name = "a\"b\\c" }, .{ .kind = .key, .name = "雪\n" } };
    const b = try Bench.create(&grants, &.{});
    defer b.destroy();
    const inputs = [_]modules.Input{.{ .path = "main.forb", .source =
        \\point<public> := struct<persistable>{X:i64, Y:i64}
        \\Kit<public> := module{
        \\    Inner<public> := module{
        \\        var Data<public>:weak_map(persistent_key, []point) = map{}
        \\        Put<public>(K:persistent_key, P:point)<reads><writes>:i64 = Block{
        \\            set Data[K] = array{P}
        \\            1
        \\        }
        \\        Bump<public>(K:persistent_key)<reads><writes><decides>:i64 = Block{
        \\            set Data[K][0].X += 10
        \\            1
        \\        }
        \\    }
        \\    var Slots<public>:weak_map(persistent_key, point) = map{}
        \\    Move<public>(K:persistent_key)<reads><writes><decides>:i64 = Block{
        \\        set Slots[K] = point{X := 3, Y := 4}
        \\        set Slots[K].Y -= 1
        \\        1
        \\    }
        \\}
        \\Do()<reads><writes><decides>:i64 = Block{
        \\    K := GetPersistentKey["a\"b\\c"]
        \\    L := GetPersistentKey["雪\n"]
        \\    Kit.Inner.Put(K, point{X := 1, Y := 2})
        \\    Kit.Inner.Bump[K]
        \\    Kit.Move[L]
        \\    1
        \\}
        \\R:i64 = Attempt(Do[], -1)
    }};
    const x = try b.runBundle(&inputs);
    try std.testing.expectEqual(@as(i64, 1), x.get("R").?.integer);
    var buffer: [4096]u8 = undefined;
    const point = "\"$class_name\":\"point\"";
    const expected =
        "{\"cell\":\"main.forb:Kit.Inner.Data\",\"key\":\"a\\\"b\\\\c\",\"value\":[{\"$package_name\":\"/main.forb\"," ++ point ++ ",\"x_X\":1,\"x_Y\":2}]}\n" ++
        "{\"cell\":\"main.forb:Kit.Inner.Data\",\"key\":\"a\\\"b\\\\c\",\"value\":[{\"$package_name\":\"/main.forb\"," ++ point ++ ",\"x_X\":11,\"x_Y\":2}]}\n" ++
        "{\"cell\":\"main.forb:Kit.Slots\",\"key\":\"雪\\n\",\"value\":{\"$package_name\":\"/main.forb\"," ++ point ++ ",\"x_X\":3,\"x_Y\":4}}\n" ++
        "{\"cell\":\"main.forb:Kit.Slots\",\"key\":\"雪\\n\",\"value\":{\"$package_name\":\"/main.forb\"," ++ point ++ ",\"x_X\":3,\"x_Y\":3}}\n";
    try std.testing.expectEqualStrings(expected, committed(x, effects.store_channel, &buffer));
}

test "S2: the store name of a cell of a bundle is its file's path, a colon, and its modules and name" {
    const grants = [_]effects.Grant{.{ .kind = .key, .name = "k" }};
    const b = try Bench.create(&grants, &.{});
    defer b.destroy();
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "S := import{\"kit/save.forb\"}\nR:i64 = S.Put()" },
        .{ .path = "kit/save.forb", .source = "Slots := module{ var Data:weak_map(persistent_key, i64) = map{}\n Add<public>()<reads><writes>:i64 = Attempt(Block{K := GetPersistentKey[\"k\"]; set Data[K] = 5; 1}, 0) }\nvar Top:weak_map(persistent_key, i64) = map{}\nPut<public>()<reads><writes>:i64 = Attempt(Block{K := GetPersistentKey[\"k\"]; set Top[K] = 6; Slots.Add()}, 0)" },
    };
    const p = switch (b.h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |program| program,
        .failed => |problem| {
            std.debug.print("bundle: {s}\n", .{problem.diagnostic.message()});
            return error.Compile;
        },
    };
    const x = (try b.h.run(p, 1 << 20)).ok;
    var buffer: [2048]u8 = undefined;
    const text = committed(x, effects.store_channel, &buffer);
    try std.testing.expectEqualStrings("{\"cell\":\"kit/save.forb:Top\",\"key\":\"k\",\"value\":6}\n{\"cell\":\"kit/save.forb:Slots.Data\",\"key\":\"k\",\"value\":5}\n", text);
    // Its loads: the cells in the order of the program's cell table, the root file's last.
    try std.testing.expectEqual(@as(usize, 2), x.effects.inputs.len);
}

test "S4, G7: a text that does not decode ends the run at the cell with load_invalid; nothing it built stays" {
    const bad_texts = [_][]const u8{ "", "{", "[]", "{\"x_Level\":1}", "{\"$class_name\":\"other\",\"x_Level\":1}", "{\"x_Level\":1.5}", "{\"x_Level\":1,\"x_Level\":2}", alice_stats ++ " x", "{\"$class_name\":\"player_stats\",\"x_Level\":\"\xff\xfe\"}" };
    for (bad_texts) |text| {
        const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = text }};
        const b = try Bench.create(&standard_grants, &stored);
        defer b.destroy();
        // `x_Level` is required by no rule (it has a default) but the others are refused as text.
        const result = try b.outcome(stats_types ++ "V:i64 = 1", 1 << 20);
        const lenient = std.mem.eql(u8, text, "{\"x_Level\":1}");
        if (lenient) {
            try std.testing.expect(result == .ok);
        } else {
            try std.testing.expect(result == .failed);
            try std.testing.expectEqual(types.Diagnostic.Code.load_invalid, result.failed.code);
        }
    }
    // The span is the cell's name, and a later entry of the same cell is never asked for.
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "oops" }};
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    try b.fails(stats_types ++ "V:i64 = 1", .load_invalid, "Stats");
    try std.testing.expectEqual(@as(usize, 2), b.h.control.effects.inputs.count);
}

test "G7: a stored text that is not UTF-8 encodes no value: load_invalid, on both machines, never a string that is no text" {
    const source = "var Names:weak_map(persistent_key, string) = map{}\nGot:string = Attempt(Names[GetPersistentKey[\"alice\"]], \"none\")";
    for ([_][]const u8{ "\"\xff\xfe\"", "\"a\xc3\"", "\"\xed\xa0\x80\"" }) |text| {
        const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = text }};
        const b = try Bench.create(&standard_grants, &stored);
        defer b.destroy();
        try b.fails(source, .load_invalid, "Names");
    }
    // The same entry as text loads.
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "\"ok\"" }};
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(source);
    try std.testing.expectEqualStrings("ok", x.get("Got").?.string);
}

test "W7: a persistent cell's value type is persistable" {
    const b = try Bench.create(&standard_grants, &.{});
    defer b.destroy();
    try b.refused("var C:weak_map(persistent_key, rational) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("var C:weak_map(persistent_key, any) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("var C:weak_map(persistent_key, function(tuple(i64), i64)) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("p := struct{X:i64}\nvar C:weak_map(persistent_key, p) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("p := class{X:i64}\nvar C:weak_map(persistent_key, []p) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("var C:weak_map(persistent_key, session) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("var C:weak_map(persistent_key, persistent_key) = map{}\nV:i64 = 1", .weak_map_value, "C");
    try b.refused("var C:weak_map(persistent_key, weak_map(i64, i64)) = map{}\nV:i64 = 1", .weak_map_value, "C");
    // Persistable shapes of every kind are accepted.
    const x = try b.run(
        \\p := struct<persistable>{X:i64 = 0}
        \\c := class<final><persistable>{N:string = ""}
        \\e := enum<persistable><open>{One, Two}
        \\var A:weak_map(persistent_key, logic) = map{}
        \\var B:weak_map(persistent_key, tuple(i64, float)) = map{}
        \\var C:weak_map(persistent_key, map(string, option(p))) = map{}
        \\var D:weak_map(persistent_key, c) = map{}
        \\var E:weak_map(persistent_key, []e) = map{}
        \\var F:weak_map(persistent_key, char32) = map{}
        \\V:i64 = 1
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("V").?.integer);
    // A local, a parameter and a field of the type are ordinary values; so is a cell of another key.
    const y = try b.run(
        \\r := struct{M:weak_map(persistent_key, rational)}
        \\F(M:weak_map(persistent_key, rational))<computes>:i64 = 1
        \\var Other:weak_map(i64, rational) = map{}
        \\V:i64 = Block{L:weak_map(persistent_key, rational) = map{}; F(L)}
    );
    try std.testing.expectEqual(@as(i64, 1), y.get("V").?.integer);
}

test "W5: a persistent cell is named only as X[K] and set as set X[K] = V" {
    const b = try Bench.create(&standard_grants, &.{});
    defer b.destroy();
    const decl = "var C:weak_map(persistent_key, i64) = map{}\n";
    try b.refused(decl ++ "D:weak_map(persistent_key, i64) = C\nV:i64 = 1", .weak_map_whole, "C");
    try b.refused(decl ++ "set C = map{}\nV:i64 = 1", .weak_map_whole, "C");
    try b.refused(decl ++ "V:i64 = C.Length", .weak_map_whole, "C");
    try b.refused("var live C:weak_map(persistent_key, i64) = map{}\nV:i64 = 1", .weak_map_whole, "C");
    try b.refused("E:map(persistent_key, i64) = map{}\nvar C:weak_map(persistent_key, i64) = E\nV:i64 = 1", .weak_map_initializer, "E");
    // Writing needs `<writes>`, reading `<reads>`, looking up a failure context.
    try b.refused(decl ++ "F(K:persistent_key)<reads>:i64 = Block{set C[K] = 1; 1}\nV:i64 = 1", .set_requires_writes, "C");
    try b.refused(decl ++ "F(K:persistent_key)<computes><decides>:i64 = C[K]\nV:i64 = 1", .variable_read_requires_reads, "C");
    try b.refused(decl ++ "F(K:persistent_key)<reads>:i64 = C[K]\nV:i64 = 1", .failure_context_required, "[");
}
