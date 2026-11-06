//! Forged IR around `<predicts>` (RFC-0085, I12, F19 to F22): every case is refused by both
//! machines' admissions, each in its own code (rule 9), and by the report replay, which admits
//! the program again. Each is made from a program that runs by changing one field.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");

const Copy = struct {
    functions: []types.RuntimeFunction,
    definitions: []types.Definition,
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        const allocator = std.testing.allocator;
        var copy: Copy = .{
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .definitions = try allocator.dupe(types.Definition, p.definitions),
            .program = p,
            .original = p,
        };
        copy.program.functions = copy.functions;
        copy.program.definitions = copy.definitions;
        return copy;
    }
    fn free(self: Copy) void {
        std.testing.allocator.free(self.functions);
        std.testing.allocator.free(self.definitions);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.functions, self.original.functions);
        @memcpy(self.definitions, self.original.definitions);
    }
};

fn functionNamed(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, index| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return index;
    std.debug.panic("no function {s}", .{name});
}

/// Every function dictates; each test forges one of them to predict.
const program_text =
    \\var X:i64 = 0
    \\var Y:i64 = 0
    \\box := class{ var N:i64 = 0 }
    \\B:box = box{}
    \\E:subscribable_event(i64) = subscribable_event(i64){}
    \\Plain(N:i64)<computes>:i64 = N + 1
    \\Pure(N:i64)<computes><predicts>:i64 = N * 2
    \\Step(N:i64)<computes>:i64 = N + 1
    \\CallsPlain(N:i64)<computes>:i64 = Plain(N)
    \\CallsPure(N:i64)<computes>:i64 = Pure(N)
    \\Invokes(F:function<computes>(tuple(i64), i64), N:i64)<computes>:i64 = F(N)
    \\Iterates(N:i64)<computes>:i64 = Iterate(Step, N, 0)
    \\Loops(Xs:[]i64)<computes>:[]i64 = For(V:Xs, V + 1)
    \\Draws()<transacts>:i64 = GetRandomInt(1, 6)
    \\Prints()<transacts>:void = Print("x")
    \\Spawns()<transacts>:task(i64) = Spawn{ 1 }
    \\Branches()<transacts><suspends>:void = Branch{ Sleep(1.0) }
    \\Syncs()<transacts><suspends>:tuple(i64, i64) = Sync(Block{ Sleep(1.0); 1 }, Block{ Sleep(2.0); 2 })
    \\Signals()<transacts>:void = E.Signal(1)
    \\Live()<transacts>:i64 = Block{ set live X = Y + 1; 0 }
    \\LiveField()<transacts>:i64 = Block{ set live B.N = Y; 0 }
    \\Reacts()<transacts>:task(void) = When(X, Set(Y, 1))
    \\Batches()<transacts>:i64 = Batch{ set X = 2; 3 }
    \\Awaits()<transacts><suspends>:logic = Await(X > 5)
    \\Recurs(N:i64)<computes>:i64 = If(N > 0, Recurs(N - 1), 0)
    \\Value:i64 = CallsPure(3) + CallsPlain(1) + Invokes(Plain, 1) + Iterates(2) + Loops(array{1}).Length + Recurs(3)
;

test "forged prediction: a predicting function that runs what dictates is refused by both machines (F19, F20)" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    try std.testing.expectEqual(@as(i64, 13), (try h.run(p, 1 << 20)).ok.get("Value").?.integer);
    var copy = try Copy.of(p);
    defer copy.free();
    // F19: a call, an invocation of a dictating function type, an `Iterate` of a function, a
    // loop over a closure that dictates, a draw, a `spawn`, a `branch`, a `structured` whose
    // arms dictate, and the `event_notify` of a subscribable `Signal`. F20: `cell_live`,
    // `object_live`, `reaction`, `batch` and `await_guard`. F21: `Plain` is the value of a
    // dictating function type, which states its set exactly.
    for ([_][]const u8{ "CallsPlain", "Invokes", "Iterates", "Loops", "Draws", "Spawns", "Branches", "Syncs", "Signals", "Live", "LiveField", "Reacts", "Batches", "Awaits", "Plain" }) |name| {
        copy.functions[functionNamed(p, name)].detail.predicts = true;
        harness.invalid(h, copy.program) catch |err| {
            std.debug.print("a predicting {s} was admitted\n", .{name});
            return err;
        };
        copy.restore();
    }
    // What a predicting function may hold is admitted: a call of a predicting function, the
    // `Print` of a string, its own recursion. The run is what it was.
    for ([_][]const u8{ "CallsPure", "Prints", "Recurs", "Step" }) |name| {
        copy.functions[functionNamed(p, name)].detail.predicts = true;
        try std.testing.expectEqual(@as(i64, 13), (try h.run(copy.program, 1 << 20)).ok.get("Value").?.integer);
        copy.restore();
    }
}

test "forged prediction: the replay admits the program again and refuses the run of a forgery" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(program_text);
    const ran = (try h.run(p, 1 << 20)).ok;
    _ = try reporting.validate(ran, false, .{});
    var copy = try Copy.of(p);
    defer copy.free();
    for ([_][]const u8{ "CallsPlain", "Invokes", "Draws", "Batches" }) |name| {
        copy.functions[functionNamed(p, name)].detail.predicts = true;
        var forged = ran;
        forged.program = copy.program;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        copy.restore();
    }
}

test "forged prediction: a callee forged to dictate under a predicting caller (F19)" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Inner(N:i64)<computes><predicts>:i64 = N + 1
        \\Outer(N:i64)<computes><predicts>:i64 = Inner(N) * 2
        \\Value:i64 = Outer(1)
    );
    try std.testing.expectEqual(@as(i64, 4), (try h.run(p, 1 << 16)).ok.get("Value").?.integer);
    var copy = try Copy.of(p);
    defer copy.free();
    copy.functions[functionNamed(p, "Inner")].detail.predicts = false;
    try harness.invalid(h, copy.program);
    copy.restore();
    // The caller dictating too: admitted, it calls what it may.
    copy.functions[functionNamed(p, "Inner")].detail.predicts = false;
    copy.functions[functionNamed(p, "Outer")].detail.predicts = false;
    try std.testing.expectEqual(@as(i64, 4), (try h.run(copy.program, 1 << 16)).ok.get("Value").?.integer);
}

test "forged prediction: a value whose type drops or adds the bit (F21)" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Add(K:i64, N:i64)<computes><predicts>:i64 = K + N
        \\Plain(N:i64)<computes>:i64 = N
        \\Bound(K:i64)<computes><predicts>:function<computes><predicts>(tuple(i64), i64) = Fn(N:i64){ K + N }
        \\F:function<computes><predicts>(tuple(i64, i64), i64) = Add
        \\G:function<computes>(tuple(i64), i64) = Plain
        \\Value:i64 = F(1, 2) + Bound(3)(4) + G(5)
    );
    try std.testing.expectEqual(@as(i64, 15), (try h.run(p, 1 << 16)).ok.get("Value").?.integer);
    var copy = try Copy.of(p);
    defer copy.free();
    // Each function type of the program in turn with the bit flipped: a `function_value` of a
    // predicting function typed without it, of a dictating one typed with it, and a `bind`
    // whose residual drops the bit or whose callable gains it.
    var flipped: usize = 0;
    for (p.definitions, 0..) |item, index| {
        if (item != .callable) continue;
        copy.definitions[index].callable.detail.predicts = !item.callable.detail.predicts;
        harness.invalid(h, copy.program) catch |err| {
            std.debug.print("a function type with the bit flipped was admitted: {d}\n", .{index});
            return err;
        };
        copy.restore();
        flipped += 1;
    }
    try std.testing.expect(flipped >= 3);
}

test "forged prediction: a subscription callback type that predicts is refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    // The callbacks of a subscribable event have the one type `function<transacts>(tuple(T),
    // void)`; a callback type forged to predict, with the function it is made of, is no such
    // type (review of f85a: the evaluator read the bit as it read a reserved one).
    const p = try h.compile(
        \\E:subscribable_event(i64) = subscribable_event(i64){}
        \\var X:i64 = 0
        \\Tally(V:i64)<transacts>:void = Set(X, V)
        \\C:cancelable = E.Subscribe(Tally)
        \\D:void = E.Signal(3)
        \\Y:i64 = X
    );
    const ran = (try h.run(p, 1 << 16)).ok;
    var copy = try Copy.of(p);
    defer copy.free();
    copy.functions[functionNamed(p, "Tally")].detail.predicts = true;
    for (p.definitions, 0..) |item, index| if (item == .callable and item.callable.transacts) {
        copy.definitions[index].callable.detail.predicts = true;
    };
    try harness.invalid(h, copy.program);
    var forged = ran;
    forged.program = copy.program;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
}

test "forged prediction: a native table that lets a draw predict is refused (F22)" {
    const h = try harness.create();
    defer scratch.release(h);
    var table: [native_std.table.len]native.Entry = native_std.table;
    h.front.natives = &table;
    defer h.front.natives = &native_std.table;
    const p = try h.compile("P()<transacts>:i64 = GetRandomInt(1, 6)\nValue:i64 = P()");
    _ = try h.run(p, 1 << 16);
    for (&table) |*entry| if (entry.effect == .draw) {
        entry.predicts = true;
    };
    // The entry is no longer well formed: the compiler has no such form, and both machines
    // refuse the program compiled against the honest table.
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, h.front.compile("P()<transacts><predicts>:i64 = GetRandomInt(1, 6)").failed.code);
    try harness.invalid(h, p);
    // An action of more than one string, or of no string, is refused the bit too.
    table = native_std.table;
    // Of the actions only `Print` predicts; `WriteLine` does not (RFC-0086, P2.3).
    for (&table) |*entry| if (entry.effect == .output and entry.predicts) {
        var forged = entry.*;
        forged.params = &.{.{ .element = .i64, .kind = .scalar }};
        try std.testing.expect(!native.wellFormed(forged));
    };
}
