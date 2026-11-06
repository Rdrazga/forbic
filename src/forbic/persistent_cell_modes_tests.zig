//! Persistent cells (RFC-0087, P5.5), continued: every trace mode with reclamation (a persistent
//! cell's members are roots), every fuel budget on both machines, and an oracle: random programs
//! of reads and writes of a persistent cell in regions that commit and fail agree with a model of
//! its entries and of the actions they save.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const cells = @import("persistent_cell_tests.zig");

const Bench = cells.Bench;
const fuel: u64 = 1 << 22;
const allocator = std.testing.allocator;

/// Runs `source` in `full` mode, then in `digest` mode at six windows and with the pool reclaimed at
/// every chance, and in `off` mode: every report, replayed from a second run, must be the stored
/// one. The second machine is given the first one's record as its prefix and no store.
fn modes(b: Bench, source: []const u8) !void {
    const p = try b.h.compile(source);
    const whole = try b.run(source);
    var stored: [8192]u8 = undefined;
    const expected = try cells.reportOf(whole, &stored);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const vm = &b.h.runtime.machine.control;
    const reference = &b.h.control;
    defer {
        vm.trace = .full;
        reference.trace = .full;
        vm.trace_window = types.ControlStorage.default_trace_window;
        vm.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        reference.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        reference.trace_window = types.ControlStorage.default_trace_window;
        vm.effects.inputs.prefix = .{};
    }
    var buffer: [8192]u8 = undefined;
    for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
        vm.trace = .digest;
        vm.trace_window = window;
        vm.reclaim_floor = 0;
        reference.trace = .digest;
        reference.trace_window = window;
        reference.reclaim_floor = 0;
        again.control.trace_window = window;
        again.control.reclaim_floor = 0;
        vm.effects.inputs.prefix = whole.effects.inputRecord();
        const digest = b.h.runtime.evaluate(p, fuel).ok;
        var out: std.Io.Writer = .fixed(&buffer);
        _ = try reporting.writeReplayed(&out, digest, again.producer(p, fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        // The reference evaluator too, from the store.
        b.script.rewind();
        const checked = evaluator.evaluateWithRuntimeStorage(p, &b.h.values, &b.h.members, reference, &b.h.state, &b.h.frames, fuel);
        try std.testing.expect(checked == .ok);
        try std.testing.expectEqual(whole.effects.inputs.len, checked.ok.effects.inputs.len);
        try std.testing.expectEqual(whole.effects.output.count, checked.ok.effects.output.count);
        try std.testing.expect(whole.effects.output.eql(checked.ok.effects.output));
    }
    vm.trace = .off;
    reference.trace = .off;
    vm.effects.inputs.prefix = whole.effects.inputRecord();
    b.script.rewind();
    const off = evaluator.evaluateWithRuntimeStorage(p, &b.h.values, &b.h.members, reference, &b.h.state, &b.h.frames, fuel);
    const off_vm = b.h.runtime.evaluate(p, fuel);
    try std.testing.expect(off == .ok and off_vm == .ok);
    try std.testing.expect(off.ok.effects.output.eql(whole.effects.output) and off_vm.ok.effects.output.eql(whole.effects.output));
}

const stats_source =
    \\player_stats := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
    \\var Stats:weak_map(persistent_key, player_stats) = map{}
    \\Alice()<reads><decides>:persistent_key = GetPersistentKey["alice"]
    \\Bob()<reads><decides>:persistent_key = GetPersistentKey["bob"]
    \\GetStats(K:persistent_key)<reads>:player_stats = Attempt(Stats[K], player_stats{})
    \\Go(K:persistent_key, L:i64)<transacts>:i64 = Block{
    \\    set Stats[K] = player_stats{Level := L, Experience := GetStats(K).Experience}
    \\    Print("l {L}")
    \\    L
    \\}
    \\Step(S:i64)<computes>:i64 = S + 1
    \\Before:i64 = Iterate(Step, 30, 0)
    \\A:i64 = Attempt(Block{K := Alice[]; Go(K, 5) + Go(K, 6)}, -1)
    \\Lost:i64 = Attempt(Block{Go(Bob[], 70); Require[false]; 1}, -2)
    \\Churn:i64 = Iterate(Step, 40, 0)
    \\B:i64 = Attempt(Stats[Alice[]].Level * 100 + Stats[Bob[]].Level, -3)
;

test "every trace mode, with the pool reclaimed at every chance, reports a persistent program as the stored run does" {
    const stored = [_]effects.Stored{
        .{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":7}" },
        .{ .request = effects.loadRequest(0, 2), .text = "{\"x_Level\":9}" },
    };
    const b = try Bench.create(&cells.standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(stats_source);
    try std.testing.expectEqual(@as(i64, 11), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.get("Lost").?.integer);
    try std.testing.expectEqual(@as(i64, 6 * 100 + 9), x.get("B").?.integer);
    try modes(b, stats_source);
}

test "every fuel budget stops both machines at one node with one record" {
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":7}" }};
    const b = try Bench.create(&cells.standard_grants, &stored);
    defer b.destroy();
    const source =
        \\player_stats := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
        \\var Stats:weak_map(persistent_key, player_stats) = map{}
        \\Go(K:persistent_key, L:i64)<reads><writes>:i64 = Block{ set Stats[K] = player_stats{Level := L}; L }
        \\A:i64 = Attempt(Block{K := GetPersistentKey["alice"]; Go(K, 5) + Go(K, 6)}, -1)
        \\B:i64 = Attempt(Stats[GetPersistentKey["alice"]].Level, -3)
    ;
    var total: u64 = 0;
    var budget: u64 = 1;
    while (true) : (budget += 1) {
        const result = try b.outcome(source, budget);
        if (result == .ok) {
            total = budget;
            break;
        }
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
    }
    // The least fuel that completes it completes it, and one less does not: a load and a store
    // action are charged alike on both machines (the harness compares their failures).
    try std.testing.expect(total > 40);
    const exact = try b.outcome(source, total);
    try std.testing.expect(exact == .ok);
    const less = try b.outcome(source, total - 1);
    try std.testing.expect(less == .failed);
}

/// The oracle's model: the entries of the cell in the order they were made, with their values, and
/// the actions committed.
const Model = struct {
    keys: [3]?i64 = .{ null, null, null },
    order: [3]u8 = undefined,
    present: usize = 0,
    text: std.ArrayList(u8) = .empty,
    discarded: u64 = 0,

    fn deinit(self: *Model) void {
        self.text.deinit(allocator);
    }
    fn set(self: *Model, key: usize, value: i64) void {
        if (self.keys[key] == null) {
            self.order[self.present] = @intCast(key);
            self.present += 1;
        }
        self.keys[key] = value;
    }
    fn saved(self: *Model, key: usize, value: i64) !void {
        try self.text.print(allocator, "{{\"cell\":\":X\",\"key\":\"{s}\",\"value\":{d}}}", .{ names[key], value });
    }
};
const names = [_][]const u8{ "alice", "bob" };

test "oracle: random programs of reads and writes of a persistent cell, in regions that commit and fail, agree with a model" {
    var prng = std.Random.DefaultPrng.init(0x5054_5ce2);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    var texts: [2][24]u8 = undefined;
    for (0..40) |_| {
        source.items.len = 0;
        var model: Model = .{};
        defer model.deinit();
        // Which keys start with an entry, and the value: loaded in grant order.
        var stored: [2]effects.Stored = undefined;
        var held: usize = 0;
        for (0..2) |key| {
            if (random.boolean()) {
                const value = random.intRangeAtMost(i64, -20, 20);
                const text = try std.fmt.bufPrint(&texts[key], "{d}", .{value});
                stored[held] = .{ .request = effects.loadRequest(0, @intCast(key + 1)), .text = text };
                held += 1;
                model.set(key, value);
            }
        }
        try source.appendSlice(allocator, "var X:weak_map(persistent_key, i64) = map{}\nAlice()<reads><decides>:persistent_key = GetPersistentKey[\"alice\"]\nBob()<reads><decides>:persistent_key = GetPersistentKey[\"bob\"]\n");
        const count = 4 + random.uintLessThan(usize, 16);
        var expected: [24]i64 = undefined;
        for (0..count) |index| {
            const key = random.uintLessThan(usize, 2);
            const who: []const u8 = if (key == 0) "Alice[]" else "Bob[]";
            const constant = random.intRangeAtMost(i64, -50, 50);
            switch (random.uintLessThan(u8, 6)) {
                // A write at the root.
                0 => {
                    try source.print(allocator, "R{d}:i64 = Attempt(Block{{ set X[{s}] = {d}; {d} }}, -1000)\n", .{ index, who, constant, constant });
                    model.set(key, constant);
                    try model.saved(key, constant);
                    expected[index] = constant;
                },
                // A compound update, which fails when the entry is absent.
                1 => {
                    try source.print(allocator, "R{d}:i64 = Attempt(Block{{ K := {s}; set X[K] += {d}; X[K] }}, -1000)\n", .{ index, who, constant });
                    if (model.keys[key]) |value| {
                        model.set(key, value + constant);
                        try model.saved(key, value + constant);
                        expected[index] = value + constant;
                    } else expected[index] = -1000;
                },
                // A write in a region that fails: undone, and its action dropped.
                2 => {
                    try source.print(allocator, "R{d}:i64 = Attempt(Block{{ set X[{s}] = {d}; Require[false]; 0 }}, Attempt(X[{s}], -2000))\n", .{ index, who, constant, who });
                    model.discarded += 1;
                    expected[index] = model.keys[key] orelse -2000;
                },
                // A write in a function, inside a region that commits.
                3 => {
                    try source.print(allocator, "F{d}(K:persistent_key)<reads><writes>:i64 = Block{{ set X[K] = Attempt(X[K], 0) * 2 + {d}; Attempt(X[K], 0) }}\nR{d}:i64 = Attempt(F{d}({s}), -3000)\n", .{ index, constant, index, index, who });
                    const next = (model.keys[key] orelse 0) * 2 + constant;
                    model.set(key, next);
                    try model.saved(key, next);
                    expected[index] = next;
                },
                // A committing region around one that fails: the outer write stays.
                4 => {
                    try source.print(allocator, "R{d}:i64 = Attempt(Block{{ set X[{s}] = {d}; Attempt(Block{{ set X[{s}] = {d}; Require[false]; 0 }}, 0); Attempt(X[{s}], -1) }}, -5000)\n", .{ index, who, constant, who, constant + 1, who });
                    model.set(key, constant);
                    try model.saved(key, constant);
                    model.discarded += 1;
                    expected[index] = constant;
                },
                // A read.
                else => {
                    try source.print(allocator, "R{d}:i64 = Attempt(X[{s}], -4000)\n", .{ index, who });
                    expected[index] = model.keys[key] orelse -4000;
                },
            }
        }
        const b = try Bench.create(&cells.standard_grants, stored[0..held]);
        defer b.destroy();
        const x = try b.run(source.items);
        for (expected[0..count], 0..) |want, index| {
            var name: [8]u8 = undefined;
            const got = x.get(try std.fmt.bufPrint(&name, "R{d}", .{index})).?.integer;
            if (got != want) {
                std.debug.print("R{d} = {d}, model {d}:\n{s}\n", .{ index, got, want, source.items });
                return error.TestUnexpectedResult;
            }
        }
        // The actions committed, in order, are the model's; the discarded ones are counted.
        var buffer: [16384]u8 = undefined;
        const got = cells.committed(x, effects.store_channel, &buffer);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| try joined.appendSlice(allocator, line);
        try std.testing.expectEqualStrings(model.text.items, joined.items);
        try std.testing.expectEqual(model.discarded, x.effects.discarded);
        // The cell's entries are the model's, in the order they were made (W8).
        const cell = x.cells[x.program.nodes[0].kind.weak_init];
        const entries = x.elements(cell.value).?;
        try std.testing.expectEqual(2 * model.present, entries.len);
        for (model.order[0..model.present], 0..) |key, at| {
            try std.testing.expectEqual(@as(u32, @intCast(key + 1)), entries[2 * at].enumeration.index);
            try std.testing.expectEqual(model.keys[key].?, entries[2 * at + 1].integer);
        }
        // One load per key grant, whether or not the store had the entry.
        try std.testing.expectEqual(@as(usize, 2), x.effects.inputs.len);
    }
}

test "RFC-0087, P5.6 (G4): a class entry saved before a field was added loads with the field's default, in every trace mode" {
    // The entries of a version without `Badges` and `Seen`: they are filled from their defaults, an
    // aggregate and a scalar, in the instance's cells and in the members laid out for its fields.
    const stored = [_]effects.Stored{
        .{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"profile\",\"x_Rank\":3}" },
        .{ .request = effects.loadRequest(0, 2), .text = "{\"x_Rank\":4,\"x_Seen\":2}" },
    };
    const b = try Bench.create(&cells.standard_grants, &stored);
    defer b.destroy();
    const source =
        \\profile := class<final><persistable>{ Rank:i64 = 1, Badges:[]string = array{"new", "old"}, Seen:i64 = 7 }
        \\var Profiles:weak_map(persistent_key, profile) = map{}
        \\Alice()<reads><decides>:persistent_key = GetPersistentKey["alice"]
        \\Bob()<reads><decides>:persistent_key = GetPersistentKey["bob"]
        \\A:i64 = Attempt(Profiles[Alice[]].Rank * 1000 + Profiles[Alice[]].Badges.Length * 100 + Profiles[Alice[]].Seen, -1)
        \\B:i64 = Attempt(Profiles[Bob[]].Rank * 1000 + Profiles[Bob[]].Badges.Length * 100 + Profiles[Bob[]].Seen, -1)
        \\T:string = Attempt(Profiles[Alice[]].Badges[1], "")
    ;
    const x = try b.run(source);
    try std.testing.expectEqual(@as(i64, 3207), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 4202), x.get("B").?.integer);
    try std.testing.expectEqualStrings("old", x.get("T").?.string);
    try modes(b, source);
}
