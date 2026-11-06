//! Persistent cells (RFC-0087, P5.5): `persistent_key` and `GetPersistentKey[Name]` (K2), a
//! persistent cell's loads at its declaration (S4) and the store actions of its writes (S5). Every
//! program runs on both machines through the harness, given the same key grants: the reference
//! evaluator reads a scripted store (`effects.Script.store`), the VM is given the reference's
//! record as its prefix and no store, and the report of each is replayed against the record.
//! Forged IR is in `persistent_cell_forgery_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");

const fuel: u64 = 1 << 22;

/// The grants most tests give: two readers' worth of nothing, a writer `log`, and the keys
/// `alice` (index 1) and `bob` (index 2), so that a key's index is not its position among keys.
pub const standard_grants = [_]effects.Grant{
    .{ .kind = .writer, .name = "log" },
    .{ .kind = .key, .name = "alice" },
    .{ .kind = .key, .name = "bob" },
};

/// Both machines and a scripted store, which only the first machine is given.
pub const Bench = struct {
    h: *harness.Harness,
    script: *effects.Script,

    pub fn create(grants: []const effects.Grant, store: []const effects.Stored) !Bench {
        const h = try harness.create();
        errdefer scratch.release(h);
        const script = try std.testing.allocator.create(effects.Script);
        script.* = .{ .store = store };
        h.control.effects.inputs.source = script.source();
        h.control.effects.inputs.grants = grants;
        return .{ .h = h, .script = script };
    }
    pub fn destroy(self: Bench) void {
        std.testing.allocator.destroy(self.script);
        scratch.release(self.h);
    }
    pub fn outcome(self: Bench, source: []const u8, budget: u64) !evaluator.Result {
        self.script.rewind();
        const p = try self.h.compile(source);
        return self.h.run(p, budget);
    }
    /// A run of both machines of a bundle of files.
    pub fn runBundle(self: Bench, inputs: []const @import("modules.zig").Input) !evaluator.Execution {
        self.script.rewind();
        const p = switch (self.h.front.compileBundle(.{ .root = inputs[0].path, .modules = inputs })) {
            .ok => |program| program,
            .failed => |problem| {
                std.debug.print("bundle: {s} at {d}\n", .{ problem.diagnostic.message(), problem.diagnostic.span.start });
                return error.Compile;
            },
        };
        const result = try self.h.run(p, fuel);
        if (result == .failed) {
            std.debug.print("bundle failed: {t}\n", .{result.failed.code});
            return error.RunFailed;
        }
        return result.ok;
    }
    pub fn run(self: Bench, source: []const u8) !evaluator.Execution {
        const result = try self.outcome(source, fuel);
        if (result == .failed) {
            std.debug.print("run failed: {t} at {d}: {s}\n", .{ result.failed.code, result.failed.span.start, source });
            return error.RunFailed;
        }
        return result.ok;
    }
    pub fn fails(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
        const result = try self.outcome(source, fuel);
        if (result != .failed) {
            std.debug.print("expected {t}: {s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        }
        if (result.failed.code != code) std.debug.print("got {t} at '{s}'\n", .{ result.failed.code, source[result.failed.span.start..result.failed.span.end] });
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
    }
    pub fn refused(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
        const result = self.h.front.compile(source);
        if (result != .failed) {
            std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        }
        if (result.failed.code != code) std.debug.print("got {t} for {s}\n", .{ result.failed.code, source });
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
    }
};

/// The actions a `full` run committed on `channel`, one per line.
pub fn committed(x: evaluator.Execution, channel: u32, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (x.effects.entries, 0..) |entry, index| if (entry.channel == channel) writer.print("{s}\n", .{x.effects.text(index)}) catch unreachable;
    return writer.buffered();
}

pub fn reportOf(x: evaluator.Execution, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try reporting.write(&out, x, false, .{});
    return out.buffered();
}

const stats_types =
    \\player_stats<public> := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
    \\var Stats<public>:weak_map(persistent_key, player_stats) = map{}
    \\GetStats(Key:persistent_key)<reads>:player_stats = Attempt(Stats[Key], player_stats{})
    \\AddExperience(Key:persistent_key, Points:i64)<reads><writes>:void = Block{
    \\    Current := GetStats(Key)
    \\    set Stats[Key] = player_stats{Level := Current.Level, Experience := Current.Experience + Points}
    \\    Points
    \\}
    \\
;

test "the source contract: an entry is loaded, a write is saved on the store channel" {
    const stored = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":7}" }};
    const b = try Bench.create(&standard_grants, &stored);
    defer b.destroy();
    const x = try b.run(stats_types ++
        \\Main()<transacts><decides>:i64 = Block{
        \\    K := GetPersistentKey["alice"]
        \\    AddExperience(K, 10)
        \\    GetStats(K).Experience
        \\}
        \\Gained:i64 = Attempt(Main[], -1)
        \\Bob:i64 = Attempt(Block{GetStats(GetPersistentKey["bob"]).Level}, -1)
        \\Nobody:i64 = Attempt(Block{GetStats(GetPersistentKey["carol"]).Level}, -1)
    );
    try std.testing.expectEqual(@as(i64, 17), x.get("Gained").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Bob").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Nobody").?.integer);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("{\"cell\":\":Stats\",\"key\":\"alice\",\"value\":{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":17}}\n", committed(x, effects.store_channel, &buffer));
    var report: [2048]u8 = undefined;
    const text = try reportOf(x, &report);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Stats\":[{\"$key\":\"alice\"},{\"Level\":3,\"Experience\":17}]") != null);
}
