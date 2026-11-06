//! Persistent cells at scale (RFC-0087, P5.5, scale tests 1 to 3): a thousand and twenty-four keys
//! and four cells, an entry of ten mebibytes written and loaded, and a hundred thousand writes in
//! a thousand regions published once. They only fit the `program` capacity profile, and skip under
//! `bootstrap`; run them with
//!   zig test src/forbic/root.zig --test-runner src/forbic_program_runner.zig
//! Wall-clock assertions use `budget`, which Debug builds leave to the optimised runs (P0.8).
const std = @import("std");
const builtin = @import("builtin");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const profile = @import("profile.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const store = @import("store.zig");
const cells = @import("persistent_cell_tests.zig");

const allocator = std.testing.allocator;

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

test "rfc0087 P5.5: a thousand and twenty-four keys and four persistent cells ask for four thousand and ninety-six loads, in the time of the entries they decode" {
    try requireProgram();
    const keys = effects.grant_capacity;
    try std.testing.expect(keys == 1024);
    const grants = try allocator.alloc(effects.Grant, keys);
    defer allocator.free(grants);
    const names = try allocator.alloc([8]u8, keys);
    defer allocator.free(names);
    for (grants, names, 0..) |*grant, *name, index| {
        const text = try std.fmt.bufPrint(name, "k{d}", .{index});
        grant.* = .{ .kind = .key, .name = text };
    }
    // Every cell holds an entry for every key: its cell and key in the number.
    const stored = try allocator.alloc(effects.Stored, 4 * keys);
    defer allocator.free(stored);
    const texts = try allocator.alloc([16]u8, 4 * keys);
    defer allocator.free(texts);
    for (0..4) |cell| for (0..keys) |key| {
        const at = cell * keys + key;
        const text = try std.fmt.bufPrint(&texts[at], "{d}", .{cell * 10_000 + key});
        stored[at] = .{ .request = effects.loadRequest(@intCast(cell), @intCast(key)), .text = text };
    };
    const b = try cells.Bench.create(grants, stored);
    defer b.destroy();
    const source =
        \\var A:weak_map(persistent_key, i64) = map{}
        \\var B:weak_map(persistent_key, i64) = map{}
        \\var C:weak_map(persistent_key, i64) = map{}
        \\var D:weak_map(persistent_key, i64) = map{}
        \\Pick(N:string)<reads><decides>:persistent_key = GetPersistentKey[N]
        \\S:i64 = Attempt(A[Pick["k17"]] + B[Pick["k1023"]] + C[Pick["k0"]] + D[Pick["k500"]], -1)
        \\Last:i64 = Attempt(D[Pick["k1023"]], -1)
    ;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const x = try b.run(source);
    const both_ms = elapsedMs(begun);
    try std.testing.expectEqual(@as(i64, 17 + 10_000 + 1023 + 20_000 + 0 + 30_000 + 500), x.get("S").?.integer);
    try std.testing.expectEqual(@as(i64, 30_000 + 1023), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(usize, 4 * keys), x.effects.inputs.len);
    // The cells' final values are the loaded maps, in grant order.
    for (0..4) |cell| {
        const entries = x.elements(x.cells[cell].value).?;
        try std.testing.expectEqual(@as(usize, 2 * keys), entries.len);
        try std.testing.expectEqual(@as(i64, @intCast(cell * 10_000 + keys - 1)), entries[2 * keys - 1].integer);
    }
    const replayed = std.Io.Clock.awake.now(std.testing.io);
    _ = try reporting.validate(x, false, .{ .work = 1 << 40 });
    const report_ms = elapsedMs(replayed);
    std.debug.print("persistent cells: 4096 loads: both machines {d}ms, replay {d}ms\n", .{ both_ms, report_ms });
    try budget(both_ms < 20_000 and report_ms < 20_000);
}

test "rfc0087 P5.5: an entry of ten mebibytes is written as a store action and loaded again, on both machines and in the replay" {
    try requireProgram();
    const grants = [_]effects.Grant{.{ .kind = .key, .name = "a" }};
    const writing =
        \\var Big:weak_map(persistent_key, string) = map{}
        \\Double(S:string)<computes>:string = S + S
        \\Build(N:i64)<computes>:string = If(N == 0, "0123456789", Double(Build(N - 1)))
        \\Written:i64 = Attempt(Block{ K := GetPersistentKey["a"]; set Big[K] = Build(20); 1 }, -1)
    ;
    const wb = try cells.Bench.create(&grants, &.{});
    defer wb.destroy();
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const written = try wb.run(writing);
    const write_ms = elapsedMs(begun);
    try std.testing.expectEqual(@as(i64, 1), written.get("Written").?.integer);
    try std.testing.expectEqual(@as(usize, 1), written.effects.entries.len);
    const action = written.effects.text(0);
    try std.testing.expectEqual(effects.store_channel, written.effects.entries[0].channel);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const parsed = (try store.parseAction(arena_state.allocator(), action)).?;
    try std.testing.expectEqualStrings(":Big", parsed.cell);
    try std.testing.expectEqualStrings("a", parsed.key);
    // The string's ten mebibytes and the quotes around them.
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024 + 2), parsed.value.len);
    // Loaded by another run: the entry is the text the first one saved.
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 0), .text = parsed.value }};
    const rb = try cells.Bench.create(&grants, &stored);
    defer rb.destroy();
    const reading =
        \\var Big:weak_map(persistent_key, string) = map{}
        \\Length:i64 = Attempt(Big[GetPersistentKey["a"]].Length, -1)
    ;
    const started = std.Io.Clock.awake.now(std.testing.io);
    const loaded = try rb.run(reading);
    const load_ms = elapsedMs(started);
    try std.testing.expectEqual(@as(i64, 10 * 1024 * 1024), loaded.get("Length").?.integer);
    try std.testing.expectEqual(@as(usize, 1), loaded.effects.inputs.len);
    try std.testing.expectEqual(parsed.value.len, loaded.effects.input_bytes.len);
    std.debug.print("persistent cells: an entry of 10 MiB: written {d}ms, loaded {d}ms (both machines and the replay)\n", .{ write_ms, load_ms });
    try budget(write_ms < 30_000 and load_ms < 30_000);
}

/// A sink that gives every store action of a run to `updates` and counts commit points.
const Publisher = struct {
    updates: *store.Updates,
    actions: u64 = 0,
    seals: u64 = 0,
    failed: bool = false,

    fn prepare(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: effects.Action) bool {
        const self: *Publisher = @ptrCast(@alignCast(context));
        if (action.channel != effects.store_channel) return true;
        self.actions += 1;
        self.updates.add(action.text) catch {
            self.failed = true;
            return false;
        };
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn seal(context: *anyopaque, _: u64) bool {
        const self: *Publisher = @ptrCast(@alignCast(context));
        self.seals += 1;
        return true;
    }
    fn sink(self: *Publisher) effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort, .seal = seal };
    }
};

test "rfc0087 P5.5: a hundred thousand store writes in a thousand regions run in digest mode on both machines, replay, and are published once" {
    try requireProgram();
    const grants = [_]effects.Grant{ .{ .kind = .key, .name = "a" }, .{ .kind = .key, .name = "b" } };
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "5" }};
    const b = try cells.Bench.create(&grants, &stored);
    defer b.destroy();
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const source =
        \\var X:weak_map(persistent_key, i64) = map{}
        \\Burst(K:persistent_key, Base:i64)<reads><writes><decides>:i64 = Block{
        \\    For(J:0..99, Block{ set X[K] = Base + J; J })
        \\    Base
        \\}
        \\Run()<reads><writes><decides>:i64 = Block{
        \\    A := GetPersistentKey["a"]
        \\    B := GetPersistentKey["b"]
        \\    Burst[B, 7]
        \\    For(I:0..999, Attempt(Block{ Burst[A, I * 1000]; 0 }, 0))
        \\    0
        \\}
        \\R:i64 = Attempt(Run[], -1)
        \\Last:i64 = Attempt(X[GetPersistentKey["a"]], -1)
    ;
    const p = try b.h.compile(source);
    const fuel: u64 = 1 << 36;
    var updates_reference = store.Updates.init(allocator);
    defer updates_reference.deinit();
    var updates_vm = store.Updates.init(allocator);
    defer updates_vm.deinit();
    var reference_sink: Publisher = .{ .updates = &updates_reference };
    var vm_sink: Publisher = .{ .updates = &updates_vm };
    const reference = &b.h.control;
    const vm = &b.h.runtime.machine.control;
    reference.trace = .digest;
    vm.trace = .digest;
    reference.effects.sink = reference_sink.sink();
    vm.effects.sink = vm_sink.sink();
    defer {
        reference.trace = .full;
        vm.trace = .full;
        reference.effects.sink = null;
        vm.effects.sink = null;
        vm.effects.inputs.prefix = .{};
    }
    var start = std.Io.Clock.awake.now(std.testing.io);
    const first = evaluator.evaluateWithRuntimeStorage(p, &b.h.values, &b.h.members, reference, &b.h.state, &b.h.frames, fuel);
    const reference_ms = elapsedMs(start);
    try std.testing.expect(first == .ok);
    vm.effects.inputs.prefix = reference.effects.inputs.record();
    vm.effects.inputs.grants = &grants;
    start = std.Io.Clock.awake.now(std.testing.io);
    const second = b.h.runtime.evaluate(p, fuel);
    const vm_ms = elapsedMs(start);
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(@as(i64, 999_099), second.ok.get("Last").?.integer);
    // A hundred writes of `b`, and a hundred in each of a thousand regions: 100,100 actions, one
    // commit point for each region and for the first burst.
    try std.testing.expectEqual(@as(u64, 100_100), reference_sink.actions);
    try std.testing.expectEqual(reference_sink.actions, vm_sink.actions);
    try std.testing.expectEqual(reference_sink.seals, vm_sink.seals);
    try std.testing.expect(first.ok.effects.output.eql(second.ok.effects.output));
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.writeReplayed(&out, second.ok, again.producer(p, fuel), false, .{});
    const report_ms = elapsedMs(start);
    // Published once: the last write of each entry makes the one generation.
    var memory: store.Memory = .init(allocator);
    defer memory.deinit();
    var files: store.Store = .{ .disk = memory.disk(), .gpa = allocator };
    start = std.Io.Clock.awake.now(std.testing.io);
    const list = try updates_vm.sorted();
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("999099", list[0].text);
    try std.testing.expectEqualStrings("106", list[1].text);
    const generation = (try files.publish(null, store.hashOf("schema"), list)).?;
    const publish_ms = elapsedMs(start);
    try std.testing.expectEqual(@as(u64, 4), memory.puts);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const active = (try files.active(arena_state.allocator())).?;
    try std.testing.expectEqualSlices(u8, &generation, &active.hash);
    std.debug.print("persistent cells: 100,100 store writes in 1,001 regions: reference {d}ms, vm {d}ms, replay {d}ms, publication {d}ms\n", .{ reference_ms, vm_ms, report_ms, publish_ms });
    try budget(reference_ms < 60_000 and vm_ms < 60_000 and report_ms < 60_000 and publish_ms < 5_000);
}
