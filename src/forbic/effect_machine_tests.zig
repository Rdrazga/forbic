//! Native effects (RFC-0079) where a run does not complete, or is not what the compiler made:
//! every budget, sinks that fail at every step, the bounds of the effect log, forged calls and
//! forged tables. Both machines must stop at the same place for the same reason, and have
//! shown the world the same lines by then.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const stdlib_natives = @import("stdlib_natives.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");
const World = @import("native_effect_tests.zig").World;

/// Prints inside and outside regions, in functions and at the root, with draws between.
const mixed =
    \\Risky(N:i64)<transacts><decides>:i64=Block{Print("risky {N}");Require[N>0];N}
    \\Roll()<transacts>:i64=Block{R:=GetRandomInt(1,6);Print("rolled");R}
    \\A:=Print("first")
    \\B:i64=Attempt(Block{Print("pending");X:=Risky[1];Print("inner {X}");Risky[0]},-1)
    \\C:i64=Roll()
    \\D:i64=Attempt(Block{Print("kept one");Y:=Risky[2];Print("kept two");Y},-1)
    \\E:[]i64=Shuffle(array{1,2,3})
    \\F:=Print("last")
;
const mixed_output = "first\nrolled\nkept one\nrisky 2\nkept two\nlast\n";

/// The state both machines are in after a run that did or did not complete: no region open,
/// nothing pending, and every prepared action settled exactly once.
fn settled(w: World, indeterminate: u64) !void {
    for ([_]*const effects.Log{ &w.h.control.effects, &w.h.runtime.machine.control.effects }) |log| {
        try std.testing.expectEqual(@as(u32, 0), log.depth);
        try std.testing.expectEqual(log.kept, log.count);
        try std.testing.expectEqual(@as(u32, 0), log.mark_count);
    }
    try std.testing.expectEqual(w.h.control.effects.committed.count, w.h.runtime.machine.control.effects.committed.count);
    try std.testing.expect(w.h.control.effects.committed.eql(w.h.runtime.machine.control.effects.committed));
    try std.testing.expectEqual(w.h.control.effects.stream.position, w.h.runtime.machine.control.effects.stream.position);
    var prepared: u64 = 0;
    var ended: u64 = 0;
    for (w.actual.calls[0..w.actual.call_count]) |call| {
        if (call.kind == .prepare) prepared += 1 else ended += 1;
    }
    // A commit that failed is the one call the sink neither kept nor was told to forget.
    try std.testing.expectEqual(prepared, ended + indeterminate);
}

test "at every budget both machines stop alike, and what was committed by then stays visible" {
    const w = try World.create();
    defer w.destroy();
    const sources = [_][]const u8{
        mixed,
        "Step(S:i64)<transacts>:i64=Block{Print(\"step {S}\");S+GetRandomInt(0,1)}\nA:i64=Iterate(Step,6,0)\nB:[]i64=Shuffle(array{4,5,6,7})",
        "Deep(N:i64)<transacts>:i64=If(N==0,0,Attempt(Block{Print(\"deep {N}\");R:=Deep(N-1);Require[N!=2];R+1},Block{Print(\"caught {N}\");100}))\nA:i64=Deep(4)",
    };
    var full: [1024]u8 = undefined;
    for (sources) |source| {
        const p = try w.h.compile(source);
        // The whole output first.
        w.reference.clear();
        w.actual.clear();
        try std.testing.expect((try w.h.run(p, 131072)) == .ok);
        const whole = try w.agreed();
        @memcpy(full[0..whole.len], whole);
        const expected = full[0..whole.len];
        var budget: u64 = 0;
        var stopped_with_output = false;
        var stopped_pending = false;
        while (true) : (budget += 1) {
            w.reference.clear();
            w.actual.clear();
            // The harness requires the same diagnostic of both machines, or the same run.
            const outcome = try w.h.run(p, budget);
            const visible = try w.agreed();
            try settled(w, 0);
            if (outcome == .ok) {
                try std.testing.expectEqualStrings(expected, visible);
                break;
            }
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
            // What a run that ran out of fuel showed is the start of what the whole run shows:
            // committed output is not taken back, and nothing pending slipped out.
            try std.testing.expect(std.mem.startsWith(u8, expected, visible));
            stopped_with_output = stopped_with_output or visible.len != 0;
            for (w.actual.calls[0..w.actual.call_count]) |call| stopped_pending = stopped_pending or call.kind == .abort;
            try std.testing.expect(budget < 4096);
        }
        try std.testing.expect(stopped_with_output and budget > 20);
        if (source.ptr == mixed.ptr) try std.testing.expect(stopped_pending);
    }
}

test "a sink that refuses a prepare or fails a commit ends both machines at the same node" {
    const w = try World.create();
    defer w.destroy();
    defer {
        w.reference.fail_prepare = null;
        w.actual.fail_prepare = null;
        w.reference.fail_commit = null;
        w.actual.fail_commit = null;
    }
    const p = try w.h.compile(mixed);
    // The order in which the run prepares its actions, and the ones it commits.
    const prepared = [_][]const u8{ "first", "pending", "risky 1", "inner 1", "risky 0", "rolled", "kept one", "risky 2", "kept two", "last" };
    const committed = [_][]const u8{ "first", "rolled", "kept one", "risky 2", "kept two", "last" };
    var expected: [256]u8 = undefined;
    for (0..prepared.len) |refused| {
        w.reference.clear();
        w.actual.clear();
        w.reference.fail_prepare = refused;
        w.actual.fail_prepare = refused;
        const outcome = try w.h.run(p, 131072);
        // A prepare that is refused is a fatal error at the call, never a failure the guest
        // could catch: the world's state must not steer the program.
        try std.testing.expectEqual(types.Diagnostic.Code.effect_prepare_failed, outcome.failed.code);
        try std.testing.expectEqualStrings("Print", p.source[outcome.failed.span.start..outcome.failed.span.end]);
        const visible = try w.agreed();
        try settled(w, 0);
        // Committed before the refusal: what was committed among the earlier prepares. The
        // region around "kept one" had not committed when "risky 2" or "kept two" was refused.
        var writer: std.Io.Writer = .fixed(&expected);
        const done: usize = switch (refused) {
            0 => 0,
            1, 2, 3, 4, 5 => 1,
            6, 7, 8 => 2,
            else => 5,
        };
        for (committed[0..done]) |line| try writer.print("{s}\n", .{line});
        try std.testing.expectEqualStrings(writer.buffered(), visible);
    }
    w.reference.fail_prepare = null;
    w.actual.fail_prepare = null;
    for (0..committed.len) |failing| {
        w.reference.clear();
        w.actual.clear();
        w.reference.fail_commit = failing;
        w.actual.fail_commit = failing;
        const outcome = try w.h.run(p, 131072);
        try std.testing.expectEqual(types.Diagnostic.Code.effect_commit_failed, outcome.failed.code);
        // Outside a region the commit is the call's own; a region's actions are committed
        // where the region ends, which is where the error points: the comma after the body
        // of the `Attempt`.
        const at = p.source[outcome.failed.span.start..outcome.failed.span.end];
        if (failing == 0 or failing == 1 or failing == 5) try std.testing.expectEqualStrings("Print", at) else {
            try std.testing.expectEqualStrings(",", at);
            try std.testing.expect(std.mem.endsWith(u8, p.source[0..outcome.failed.span.start], "Print(\"kept two\");Y}"));
        }
        const visible = try w.agreed();
        try settled(w, 1);
        var writer: std.Io.Writer = .fixed(&expected);
        for (committed[0..failing]) |line| try writer.print("{s}\n", .{line});
        try std.testing.expectEqualStrings(writer.buffered(), visible);
        // The actions of the region behind the one that failed were told they will not follow.
        if (failing == 2) {
            var aborted: usize = 0;
            for (w.actual.calls[0..w.actual.call_count]) |call| aborted += @intFromBool(call.kind == .abort and (std.mem.eql(u8, w.actual.text(call), "risky 2") or std.mem.eql(u8, w.actual.text(call), "kept two")));
            try std.testing.expectEqual(@as(usize, 2), aborted);
        }
    }
    // With the sinks whole again the run completes as it always did.
    w.reference.fail_commit = null;
    w.actual.fail_commit = null;
    _ = try w.expect(mixed, mixed_output);
}

test "the effect log is bounded: a full run keeps its output up to the capacity, a region its pending output" {
    try @import("profile.zig").requireBootstrap();
    const w = try World.create();
    defer w.destroy();
    // A full run lists what it committed, so it can commit only as many actions as its log
    // has entries. The ones it did commit have happened.
    const loop = "Step(S:i64)<transacts>:i64=Block{Print(\"\");S+1}\nA:i64=Iterate(Step,1100,0)";
    var p = try w.h.compile(loop);
    w.reference.clear();
    w.actual.clear();
    var outcome = try w.h.run(p, 131072);
    try std.testing.expectEqual(types.Diagnostic.Code.effect_limit, outcome.failed.code);
    try std.testing.expectEqualStrings("Print", p.source[outcome.failed.span.start..outcome.failed.span.end]);
    try std.testing.expectEqual(@as(u64, types.limits.effect_entries), w.h.runtime.machine.control.effects.committed.count);
    try std.testing.expectEqual(@as(u64, types.limits.effect_entries), w.actual.commits);
    try settled(w, 0);
    // Exactly the capacity is fine.
    w.reference.clear();
    w.actual.clear();
    p = try w.h.compile("Step(S:i64)<transacts>:i64=Block{Print(\"\");S+1}\nA:i64=Iterate(Step,1024,0)");
    outcome = try w.h.run(p, 131072);
    try std.testing.expectEqual(@as(usize, types.limits.effect_entries), outcome.ok.effects.entries.len);
    // The bytes are bounded as well: three copies of half the capacity do not fit a region.
    const big = "Twice(S:string)<computes>:string=S+S\nBig:string=Iterate(Twice,13,\"abcd\")\n";
    try std.testing.expectEqual(@as(usize, 4 << 13), types.limits.effect_bytes / 2);
    // Without the recording sinks, which have no room to write such lines down.
    const sinks = [_]?effects.Sink{ w.h.control.effects.sink, w.h.runtime.machine.control.effects.sink };
    w.h.control.effects.sink = null;
    w.h.runtime.machine.control.effects.sink = null;
    defer {
        w.h.control.effects.sink = sinks[0];
        w.h.runtime.machine.control.effects.sink = sinks[1];
    }
    p = try w.h.compile(big ++ "A:i64=Attempt(Block{Print(Big);Print(Big);Print(Big);Fail[\"x\"];1},-1)");
    outcome = try w.h.run(p, 131072);
    try std.testing.expectEqual(types.Diagnostic.Code.effect_limit, outcome.failed.code);
    try std.testing.expectEqual(@as(u64, 0), w.h.runtime.machine.control.effects.committed.count);
    // Two fit exactly, and a region that fails gives the room back.
    p = try w.h.compile(big ++ "A:i64=Attempt(Block{Print(Big);Print(Big);Fail[\"x\"];1},-1)\nB:i64=Attempt(Block{Print(Big);Print(Big);Fail[\"x\"];1},-1)\nC:=Print(\"end\")");
    outcome = try w.h.run(p, 131072);
    try std.testing.expectEqual(@as(u64, 4), outcome.ok.effects.discarded);
    try std.testing.expectEqualStrings("end", outcome.ok.effects.bytes);
}

/// A program like `p` in which the native call of `function` that names `from` names `to`.
fn renamed(h: *harness.Harness, p: types.Program, from: u16, to: u16) !types.Program {
    var forged = p;
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    var changed: usize = 0;
    for (h.body[0..p.function_nodes.len]) |*entry| {
        if (entry.input == .operation and entry.node.kind == .native_call and entry.node.kind.native_call.native == from) {
            entry.node.kind.native_call.native = to;
            changed += 1;
        }
    }
    try std.testing.expect(changed != 0);
    forged.function_nodes = h.body[0..p.function_nodes.len];
    return forged;
}

fn index(id: []const u8) u16 {
    return stdlib_natives.find(&native_std.table, id).?;
}

test "forged calls: an effect native named by a function that only computes is refused by both machines" {
    const w = try World.create();
    defer w.destroy();
    const h = w.h;
    // The pure kernel and the draw have one signature, so only the effect tells them apart.
    var p = try h.compile("F(A:i64,B:i64)<computes>:i64=Min(A,B)\nX:i64=F(1,6)");
    try harness.invalid(h, try renamed(h, p, index("std.min_int"), index("std.random_int")));
    // The same through a callable that claims to compute, and inside a failable function.
    p = try h.compile("F(A:i64,B:i64)<computes>:i64=Min(A,B)\nG:function(tuple(i64,i64),i64)=F\nX:i64=G(1,6)");
    try harness.invalid(h, try renamed(h, p, index("std.min_int"), index("std.random_int")));
    p = try h.compile("F(A:i64,B:i64)<computes><decides>:i64=Block{Require[A<B];Min(A,B)}\nX:i64=Attempt(F[1,6],0)");
    try harness.invalid(h, try renamed(h, p, index("std.min_int"), index("std.random_int")));
    // A function that says <transacts> may name it, and then both machines draw alike.
    p = try h.compile("F(A:i64,B:i64)<transacts>:i64=Min(A,B)\nX:i64=F(1,6)");
    const drawn = (try h.run(try renamed(h, p, index("std.min_int"), index("std.random_int")), 4096)).ok;
    var model: effects.Stream = .{};
    try std.testing.expectEqual(model.integer(1, 6).?, drawn.get("X").?.integer);
    try std.testing.expectEqual(model.position, drawn.effects.draws);
    // A pure kernel named where an effect was compiled is a pure call: nothing is drawn.
    p = try h.compile("F(A:i64,B:i64)<transacts>:i64=GetRandomInt(A,B)\nX:i64=F(1,6)");
    const pure = (try h.run(try renamed(h, p, index("std.random_int"), index("std.min_int")), 4096)).ok;
    try std.testing.expectEqual(@as(i64, 1), pure.get("X").?.integer);
    try std.testing.expectEqual(@as(u64, 0), pure.effects.draws);
    // An action in place of a pure call of the same operand is refused by its result type.
    p = try h.compile("N:=native{\"std.byte_length\"}\nF(S:string)<transacts>:i64=N(S)\nX:i64=F(\"abc\")");
    try harness.invalid(h, try renamed(h, p, index("std.byte_length"), index("std.print")));
    // A call that names no entry of the table.
    p = try h.compile("F()<transacts>:i64=GetRandomInt(1,6)\nX:i64=F()");
    try harness.invalid(h, try renamed(h, p, index("std.random_int"), @intCast(native_std.table.len)));
}

test "forged calls: an effect native named by a function with only some heap effects is refused by both machines" {
    const w = try World.create();
    defer w.destroy();
    const h = w.h;
    // RFC-0078 splits `<transacts>` into families; an effect native still needs all three, in
    // each admission as in the compiler, whichever two a function declares.
    for ([_][]const u8{ "<reads><writes>", "<reads><allocates>", "<writes><allocates>", "<reads>", "<writes>", "<allocates>" }) |declared| {
        var text: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "F(A:i64,B:i64){s}:i64=Min(A,B)\nX:i64=F(1,6)", .{declared});
        const p = try h.compile(source);
        try harness.invalid(h, try renamed(h, p, index("std.min_int"), index("std.random_int")));
    }
    // All three spelled out is `<transacts>`: both machines draw alike.
    const p = try h.compile("F(A:i64,B:i64)<reads><writes><allocates>:i64=Min(A,B)\nX:i64=F(1,6)");
    const drawn = (try h.run(try renamed(h, p, index("std.min_int"), index("std.random_int")), 4096)).ok;
    var model: effects.Stream = .{};
    try std.testing.expectEqual(model.integer(1, 6).?, drawn.get("X").?.integer);
}

fn drawsAsOutput(ctx: *native.Context, text: []const u8) native.Error!void {
    _ = text;
    _ = try ctx.draw();
}
fn actsAsDraw(ctx: *native.Context, low: i64, high: i64) native.Error!i64 {
    _ = high;
    try ctx.act("smuggled");
    return low;
}
fn actsTwice(ctx: *native.Context, text: []const u8) native.Error!void {
    try ctx.act(text);
    try ctx.act(text);
}

test "forged tables: a native gets only the effect its entry declares, and an entry that lies is refused" {
    const w = try World.create();
    defer w.destroy();
    const h = w.h;
    var table: [native_std.table.len]native.Entry = native_std.table;
    h.front.natives = &table;
    defer h.front.natives = &native_std.table;
    const min = index("std.min_int");
    const random = index("std.random_int");
    const print = index("std.print");
    // A pure kernel declared an effect: a function that only computes may not call it, and
    // neither machine lets it.
    table[min].effect = .draw;
    var p = try h.compile("F(A:i64,B:i64)<computes>:i64=Min(A,B)\nX:i64=F(1,6)");
    try harness.invalid(h, p);
    // From the root, or from <transacts>, it runs: it draws nothing, and the replay agrees.
    p = try h.compile("F(A:i64,B:i64)<transacts>:i64=Min(A,B)\nX:i64=F(1,6)+Min(8,9)");
    try std.testing.expectEqual(@as(i64, 9), (try h.run(p, 4096)).ok.get("X").?.integer);
    table[min] = native_std.table[min];
    // A draw declared pure has no stream: the call is a fault of the native in both machines.
    table[random].effect = .none;
    p = try h.compile("X:i64=GetRandomInt(1,6)");
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(p, 4096)).failed.code);
    p = try h.compile("F()<transacts>:i64=GetRandomInt(1,6)\nX:i64=F()");
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(p, 4096)).failed.code);
    table[random] = native_std.table[random];
    // An action declared pure, or declared a draw, is not a well formed entry: the compiler
    // has no such form, and a program compiled against the honest table is refused.
    const honest = try h.compile("X:=Print(\"x\")");
    for ([_]native.Effect{ .none, .draw }) |declared| {
        table[print].effect = declared;
        try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, h.front.compile("X:=Print(\"x\")").failed.code);
        try harness.invalid(h, honest);
    }
    table[print] = native_std.table[print];
    // A draw declared an action answers, which an action may not.
    const drawing = try h.compile("X:i64=GetRandomInt(1,6)");
    table[random].effect = .output;
    try harness.invalid(h, drawing);
    table[random] = native_std.table[random];
    // Natives that reach for the other effect: each is a fault at the call in both machines,
    // and nothing reaches the world.
    table[print] = native.effectEntry("std.print", drawsAsOutput, .{ .base = 2 }, .output);
    p = try h.compile("X:=Print(\"x\")");
    w.reference.clear();
    w.actual.clear();
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(p, 4096)).failed.code);
    table[print] = native_std.table[print];
    table[random] = native.effectEntry("std.random_int", actsAsDraw, .{ .base = 2 }, .draw);
    p = try h.compile("X:i64=GetRandomInt(1,6)");
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, (try h.run(p, 4096)).failed.code);
    try std.testing.expectEqualStrings("", try w.agreed());
    table[random] = native_std.table[random];
    // An action native may describe more than one action; they share the call's fate.
    table[print] = native.effectEntry("std.print", actsTwice, .{ .base = 2 }, .output);
    _ = try w.expect("A:=Print(\"a\")\nB:i64=Attempt(Block{Print(\"b\");Fail[\"x\"];1},2)\nC:=Print(\"c\")", "a\na\nc\nc\n");
    table[print] = native_std.table[print];
}
