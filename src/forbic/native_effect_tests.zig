//! Native effects (RFC-0079): output, draws, rollback, machine agreement, replay and forgery.
//!
//! Every program here runs on both machines, each with its own effect log and its own
//! recording sink. The harness requires the same values, steps, fuel and effect record of both
//! and replays the report of each; `World.run` further requires that the two sinks heard the
//! same calls in the same order, which is what a device would have seen.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");

pub const World = struct {
    h: *harness.Harness,
    reference: *effects.Recorder,
    actual: *effects.Recorder,
    shown: []u8,

    pub fn create() !World {
        const h = try harness.create();
        errdefer scratch.release(h);
        const reference = try std.testing.allocator.create(effects.Recorder);
        errdefer std.testing.allocator.destroy(reference);
        const actual = try std.testing.allocator.create(effects.Recorder);
        errdefer std.testing.allocator.destroy(actual);
        reference.* = .{};
        actual.* = .{};
        h.control.effects.sink = reference.sink();
        h.runtime.machine.control.effects.sink = actual.sink();
        return .{ .h = h, .reference = reference, .actual = actual, .shown = try std.testing.allocator.alloc(u8, 96 * 1024) };
    }
    pub fn destroy(self: World) void {
        std.testing.allocator.free(self.shown);
        std.testing.allocator.destroy(self.actual);
        std.testing.allocator.destroy(self.reference);
        scratch.release(self.h);
    }
    fn clear(self: World) void {
        self.reference.clear();
        self.actual.clear();
    }
    /// What both sinks heard is the same, call for call; returns what a device would show.
    pub fn agreed(self: World) ![]const u8 {
        try std.testing.expectEqual(@as(u64, 0), self.reference.lost + self.actual.lost);
        try std.testing.expectEqual(self.reference.call_count, self.actual.call_count);
        for (self.reference.calls[0..self.reference.call_count], self.actual.calls[0..self.actual.call_count]) |a, b| {
            try std.testing.expectEqual(a.kind, b.kind);
            try std.testing.expectEqual(a.sequence, b.sequence);
            try std.testing.expectEqualStrings(self.reference.text(a), self.actual.text(b));
        }
        return self.actual.visible(self.shown);
    }
    /// Runs a program to completion on both machines and returns the VM's execution.
    pub fn run(self: World, source: []const u8) !evaluator.Execution {
        self.clear();
        const x = try self.h.execute(source);
        const visible = try self.agreed();
        // A full run keeps what it committed, and that is what the sink was shown.
        var listed: std.Io.Writer = .fixed(self.shown[visible.len..]);
        for (0..x.effects.entries.len) |index| {
            try listed.writeAll(x.effects.text(index));
            try listed.writeByte('\n');
        }
        try std.testing.expectEqualStrings(visible, listed.buffered());
        try std.testing.expectEqual(@as(u64, x.effects.entries.len), x.effects.output.count);
        // Every prepared action was committed or aborted, exactly once.
        var prepared: u64 = 0;
        var committed: u64 = 0;
        var aborted: u64 = 0;
        for (self.actual.calls[0..self.actual.call_count]) |call| switch (call.kind) {
            .prepare => prepared += 1,
            .commit => committed += 1,
            .abort => aborted += 1,
        };
        try std.testing.expectEqual(prepared, committed + aborted);
        try std.testing.expectEqual(committed, x.effects.output.count);
        try std.testing.expectEqual(aborted, x.effects.discarded);
        return x;
    }
    /// Runs a program and requires exactly this output.
    pub fn expect(self: World, source: []const u8, output: []const u8) !evaluator.Execution {
        const x = try self.run(source);
        try std.testing.expectEqualStrings(output, self.actual.visible(self.shown));
        return x;
    }
};

test "Print shows lines in program order, from roots, functions and loops, and yields the empty tuple" {
    const w = try World.create();
    defer w.destroy();
    var x = try w.expect("A:tuple()=Print(\"hello\")\nB:=Print(\"\")\nC:=Print(\"雪 and \\\"quotes\\\"\")", "hello\n\n雪 and \"quotes\"\n");
    const unit = x.get("A").?.aggregate;
    try std.testing.expectEqual(unit.elements.start, unit.elements.end);
    try std.testing.expectEqual(@as(u64, 3), x.effects.output.count);
    try std.testing.expectEqual(@as(u64, 0), x.effects.draws + x.effects.discarded);
    // From a function, from a function it calls, and from a method.
    _ = try w.expect(
        \\Inner(N:i64)<transacts>:i64=Block{Print("inner {N}");N+1}
        \\Outer(N:i64)<transacts>:i64=Block{Print("before");R:=Inner(N);Print("after {R}");R}
        \\Bell:=class{
        \\  var Rings:i64=0
        \\  Ring()<transacts>:i64=Block{set Self.Rings=Self.Rings+1;Print("ring {Self.Rings}");Self.Rings}
        \\}
        \\A:i64=Outer(1)
        \\B:=Bell{}
        \\C:i64=B.Ring()+B.Ring()
        \\D:=Print("done {A} {C}")
    , "before\ninner 1\nafter 2\nring 1\nring 2\ndone 2 3\n");
    // From every kind of loop, with text built at run time.
    _ = try w.expect(
        \\Step(S:i64)<transacts>:i64=Block{Print("step {S}");S+1}
        \\Say(X:i64)<transacts>:i64=Block{Print("say {X}");X*2}
        \\A:i64=Iterate(Step,3,0)
        \\Each()<transacts>:[]i64=For(X:array{7,8},Say(X))
        \\B:[]i64=Each()
        \\Count(S:i64)<transacts>:option(i64)=Block{Print("loop {S}");If(S<2,option{S+1},option{})}
        \\C:i64=Loop(Count,0)
        \\var N:i64=0
        \\Spin()<transacts>:i64=Block{While(N<2,Block{Print("while {N}");set N=N+1});N}
        \\D:i64=Spin()
    , "step 0\nstep 1\nstep 2\nsay 7\nsay 8\nloop 0\nloop 1\nloop 2\nwhile 0\nwhile 1\n");
    // A function value and a bound function that print.
    _ = try w.expect(
        \\Say(Prefix:string,X:i64)<transacts>:i64=Block{Print("{Prefix}{X}");X}
        \\F:function<transacts>(tuple(i64),i64)=Bind(Say,"n=")
        \\A:i64=F(4)+F(5)
    , "n=4\nn=5\n");
}

test "ToDiagnostic prints every kind of value and stands only where it is printed" {
    const w = try World.create();
    defer w.destroy();
    _ = try w.expect(
        \\P:=struct{X:i64}
        \\E:=enum{One,Two}
        \\C:=class{V:i64}
        \\Id(X:i64)<computes>:i64=X
        \\A:=Print(ToDiagnostic(42))
        \\B:=Print(ToDiagnostic(1.5))
        \\D:=Print(ToDiagnostic(true))
        \\F:=Print(ToDiagnostic("text"))
        \\G:=Print(ToDiagnostic('c'))
        \\H:=Print(ToDiagnostic(array{1,2}))
        \\I:=Print(ToDiagnostic(P{X:=1}))
        \\J:=Print(ToDiagnostic(E.Two))
        \\K:=Print(ToDiagnostic(tuple{1,"a"}))
        \\L:=Print(ToDiagnostic(option{3}))
        \\M:=Print(ToDiagnostic(map{1=>2}))
        \\N:=Print(ToDiagnostic(Id))
        \\O:=Print(ToDiagnostic(C{V:=1}))
        \\Q:=Print(ToDiagnostic(1+2*3))
    , "42\n1.5\ntrue\ntext\nc\n<array>\n<struct>\n<enum>\n<tuple>\n<option>\n<map>\n<function>\n<object>\n7\n");
    // A diagnostic is opaque: it cannot be bound, compared, measured, joined or passed on.
    const refused = [_][]const u8{
        "A:=ToDiagnostic(1)",
        "A:string=ToDiagnostic(1)",
        "A:=Print(ToDiagnostic(1)+\"x\")",
        "A:=Print(\"x\"+ToDiagnostic(1))",
        "A:=Print(ToString(ToDiagnostic(1).Length))",
        "A:=Print(If(ToDiagnostic(1)==\"1\",\"y\",\"n\"))",
        "A:=Print((ToDiagnostic(1)))",
        "A:=Print(\"{ToDiagnostic(1)}\")",
        "F(S:string)<computes>:string=S\nA:=Print(F(ToDiagnostic(1)))",
        "A:=Print(ToDiagnostic(1).Slice[0,1])",
        "A:=array{ToDiagnostic(1)}",
        "A:=Print(Block{ToDiagnostic(1)})",
    };
    for (refused) |source| {
        const outcome = w.h.front.compile(source);
        if (outcome != .failed or outcome.failed.code != .diagnostic_position) {
            std.debug.print("not refused as a diagnostic out of place: {s}\n", .{source});
            return error.TestUnexpectedResult;
        }
    }
    // The program's own `ToDiagnostic` is the program's, wherever it stands.
    _ = try w.expect("ToDiagnostic(X:i64)<computes>:string=\"mine\"\nS:string=ToDiagnostic(1)+\"!\"\nA:=Print(ToDiagnostic(1))\nB:=Print(S)", "mine\nmine!\n");
}

test "output inside a region that fails never appears, at every nesting and through every failure form" {
    const w = try World.create();
    defer w.destroy();
    const cases = [_]struct { source: []const u8, output: []const u8, discarded: u64 }{
        // An Attempt whose body fails, and one whose body succeeds.
        .{ .source = "A:i64=Attempt(Block{Print(\"gone\");Fail[\"x\"];1},Block{Print(\"kept\");2})", .output = "kept\n", .discarded = 1 },
        .{ .source = "A:i64=Attempt(Block{Print(\"kept\");1},Block{Print(\"unused\");2})", .output = "kept\n", .discarded = 0 },
        // Inner commits, outer fails: the inner region's output goes with the outer one.
        .{ .source = "A:i64=Attempt(Block{Print(\"o1\");B:i64=Attempt(Block{Print(\"i1\");1},2);Print(\"o2\");Fail[\"x\"];B},9)\nZ:=Print(\"end\")", .output = "end\n", .discarded = 3 },
        // Inner fails, outer commits: only the inner region's output is lost.
        .{ .source = "A:i64=Attempt(Block{Print(\"o1\");B:i64=Attempt(Block{Print(\"i1\");Fail[\"x\"];1},Block{Print(\"i2\");2});Print(\"o2\");B},9)", .output = "o1\ni2\no2\n", .discarded = 1 },
        // Three deep, failing at each level in turn.
        .{ .source = "A:i64=Attempt(Block{Print(\"1\");Attempt(Block{Print(\"2\");Attempt(Block{Print(\"3\");Fail[\"x\"];0},Block{Print(\"3b\");0})},0)},0)", .output = "1\n2\n3b\n", .discarded = 1 },
        .{ .source = "A:i64=Attempt(Block{Print(\"1\");Attempt(Block{Print(\"2\");B:i64=Attempt(Block{Print(\"3\");0},0);Fail[\"x\"];B},Block{Print(\"2b\");0})},0)", .output = "1\n2b\n", .discarded = 2 },
        // A failing function: its output and its caller's, back to the Attempt that catches.
        .{ .source = "F(N:i64)<transacts><decides>:i64=Block{Print(\"f {N}\");Require[N>0];N}\nG(N:i64)<transacts><decides>:i64=Block{Print(\"g {N}\");F[N]+F[N-1]}\nA:i64=Attempt(G[1],-1)\nB:i64=Attempt(G[2],-1)", .output = "g 2\nf 2\nf 1\n", .discarded = 3 },
        // option{} catches the failure of its expression.
        .{ .source = "F(N:i64)<transacts><decides>:i64=Block{Print(\"f {N}\");Require[N>0];N}\nA:option(i64)=option{F[0]}\nB:option(i64)=option{F[1]}", .output = "f 1\n", .discarded = 1 },
        // A failable condition: what the condition printed before it failed is gone.
        .{ .source = "F(N:i64)<transacts><decides>:i64=Block{Print(\"f {N}\");Require[N>0];N}\nA:string=If(F[0]>0,\"yes\",\"no\")\nB:string=If(F[5]>0,\"yes\",\"no\")\nC:=Print(A+B)", .output = "f 5\nnoyes\n", .discarded = 1 },
        // For: an iteration whose filter or body fails is skipped, with what it printed.
        .{ .source = "F(N:i64)<transacts><decides>:i64=Block{Print(\"f {N}\");Require[N!=2];N}\nRun()<transacts>:[]i64=For(X:array{1,2,3},F[X])\nA:[]i64=Run()", .output = "f 1\nf 3\n", .discarded = 1 },
        .{ .source = "Note(N:i64)<transacts>:i64=Block{Print(\"n {N}\");N}\nRun()<transacts>:[]i64=For(X:array{1,2,3},Y:=Note(X),Y!=2,Block{Print(\"b {Y}\");Y})\nA:[]i64=Run()", .output = "n 1\nb 1\nn 3\nb 3\n", .discarded = 1 },
        // logic{} and Not.
        .{ .source = "F(N:i64)<transacts><decides>:i64=Block{Print(\"f {N}\");Require[N>0];N}\nA:logic=logic{F[0]}\nB:logic=logic{F[1]}", .output = "f 1\n", .discarded = 1 },
        // A decides loop that fails: every visit's output goes.
        .{ .source = "Step(X:i64)<transacts><decides>:option(i64)=Block{Print(\"s {X}\");Require[X<2];option{X+1}}\nA:i64=Attempt(Loop(Step,0),-1)\nZ:=Print(\"end\")", .output = "end\n", .discarded = 3 },
        // Return keeps what the frame did: its regions are committed, not rolled back.
        .{ .source = "F(N:i64)<transacts>:i64=Block{Attempt(Block{Print(\"in {N}\");If(N>0,Return(N),0)},0);Print(\"after\");0}\nA:i64=F(1)+F(0)", .output = "in 1\nin 0\nafter\n", .discarded = 0 },
        // ... and an enclosing region can still undo them.
        .{ .source = "F(N:i64)<transacts>:i64=Block{Attempt(Block{Print(\"in {N}\");If(N>0,Return(N),0)},0);Print(\"after\");0}\nA:i64=Attempt(Block{X:=F(1);Fail[\"x\"];X},-1)", .output = "", .discarded = 1 },
        // A write and a print in one region share its fate.
        .{ .source = "var Count:i64=0\nBump()<transacts><decides>:i64=Block{set Count=Count+1;Print(\"count {Count}\");Require[Count<2];Count}\nA:i64=Attempt(Bump[],-1)\nB:i64=Attempt(Bump[],-1)\nC:i64=Count\nD:=Print(\"final {C}\")", .output = "count 1\nfinal 1\n", .discarded = 1 },
    };
    for (cases) |case| {
        const x = w.expect(case.source, case.output) catch |err| {
            std.debug.print("case: {s}\n", .{case.source});
            return err;
        };
        if (x.effects.discarded != case.discarded) {
            std.debug.print("case: {s}\ndiscarded {d}, expected {d}\n", .{ case.source, x.effects.discarded, case.discarded });
            return error.TestUnexpectedResult;
        }
    }
}

test "a constructor that fails takes what its blocks printed with it" {
    const w = try World.create();
    defer w.destroy();
    _ = try w.expect(
        \\Chest:=class{
        \\  Gold:i64
        \\}
        \\Open(N:i64)<transacts><decides>:Chest=Block{Print("opening {N}");Require[N>0];Chest{Gold:=N}}
        \\A:i64=Attempt(Block{C:=Open[0];C.Gold},-1)
        \\B:i64=Attempt(Block{C:=Open[5];C.Gold},-1)
        \\Z:=Print("gold {A} {B}")
    , "opening 5\ngold -1 5\n");
}

test "a draw is not undone by a failure, its uses are, and both machines draw the same values" {
    const w = try World.create();
    defer w.destroy();
    var model: effects.Stream = .{};
    // The draw inside the failed region moved the stream: the next draw is the second value.
    var x = try w.run("A:i64=Attempt(Block{X:=GetRandomInt(1,1000000);Print(\"drew {X}\");Fail[\"no\"];X},-1)\nB:i64=GetRandomInt(1,1000000)\nC:=Print(\"kept {B}\")");
    const lost = model.integer(1, 1000000).?;
    const kept = model.integer(1, 1000000).?;
    try std.testing.expect(lost != kept);
    try std.testing.expectEqual(@as(i64, -1), x.get("A").?.integer);
    try std.testing.expectEqual(kept, x.get("B").?.integer);
    try std.testing.expectEqual(model.position, x.effects.draws);
    try std.testing.expectEqual(@as(u64, 1), x.effects.discarded);
    var line: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&line, "kept {d}\n", .{kept}), w.actual.visible(w.shown));
    // Bounds in either order, a single value, the ends of i64, and floats.
    model = .{};
    x = try w.run(
        \\A:i64=GetRandomInt(6,1)
        \\B:i64=GetRandomInt(7,7)
        \\C:i64=GetRandomInt(-9223372036854775807-1,9223372036854775807)
        \\D:float=GetRandomFloat(2.0,-2.0)
        \\E:float=GetRandomFloat(0.5,0.5)
        \\F:float=GetRandomFloat(NaN,1.0)
        \\G:float=GetRandomFloat(0.0,Inf)
        \\Roll()<transacts>:i64=GetRandomInt(1,6)
        \\H:i64=Roll()+Roll()*10
    );
    try std.testing.expectEqual(model.integer(6, 1).?, x.get("A").?.integer);
    try std.testing.expect(x.get("A").?.integer >= 1 and x.get("A").?.integer <= 6);
    try std.testing.expectEqual(model.integer(7, 7).?, x.get("B").?.integer);
    try std.testing.expectEqual(model.integer(std.math.minInt(i64), std.math.maxInt(i64)).?, x.get("C").?.integer);
    const d = model.float(2.0, -2.0);
    try std.testing.expectEqual(@as(u64, @bitCast(d)), @as(u64, @bitCast(x.get("D").?.floating)));
    try std.testing.expect(d >= -2.0 and d <= 2.0);
    try std.testing.expectEqual(model.float(0.5, 0.5), x.get("E").?.floating);
    _ = model.float(0, 0);
    _ = model.float(0, 0);
    try std.testing.expect(std.math.isNan(x.get("F").?.floating) and std.math.isNan(x.get("G").?.floating));
    const first = model.integer(1, 6).?;
    const second = model.integer(1, 6).?;
    try std.testing.expectEqual(first + second * 10, x.get("H").?.integer);
    try std.testing.expectEqual(model.position, x.effects.draws);
    // Another seed, other values; the same seed, the same values.
    w.h.control.effects.seed = 12345;
    w.h.runtime.machine.control.effects.seed = 12345;
    defer {
        w.h.control.effects.seed = effects.default_seed;
        w.h.runtime.machine.control.effects.seed = effects.default_seed;
    }
    model = .{ .seed = 12345 };
    x = try w.run("A:i64=GetRandomInt(1,1000000)\nB:i64=GetRandomInt(1,1000000)");
    try std.testing.expectEqual(model.integer(1, 1000000).?, x.get("A").?.integer);
    try std.testing.expectEqual(model.integer(1, 1000000).?, x.get("B").?.integer);
    try std.testing.expectEqual(@as(u64, 12345), x.effects.seed);
    try std.testing.expect(x.get("A").?.integer != kept and x.get("A").?.integer != lost);
}

test "Shuffle is a permutation that one word of the stream decides, of every kind of element" {
    const w = try World.create();
    defer w.destroy();
    var x = try w.run(
        \\P:=struct{X:i64,Name:string}
        \\A:[]i64=Shuffle(array{1,2,3,4,5,6,7,8})
        \\B:[]string=Shuffle(array{"a","b","c"})
        \\C:[]P=Shuffle(array{P{X:=1,Name:="one"},P{X:=2,Name:="two"}})
        \\None:[]i64=array{}
        \\D:[]i64=Shuffle(None)
        \\E:[]i64=Shuffle(array{9})
        \\F:[][]i64=Shuffle(array{array{1},array{2,2},array{3,3,3}})
        \\Again:[]i64=Attempt(Block{S:=Shuffle(A);Fail["no"];S},None)
        \\G:i64=GetRandomInt(1,1000000)
    );
    // One word each, whatever the length; the one in the failed region is spent too.
    var model: effects.Stream = .{};
    const key = model.next();
    for (0..6) |_| _ = model.next();
    try std.testing.expectEqual(model.integer(1, 1000000).?, x.get("G").?.integer);
    try std.testing.expectEqual(@as(u64, 8), x.effects.draws);
    // The order is the Fisher-Yates pass over the stream the word names.
    var expected = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var pass: effects.Stream = .{ .seed = key };
    var index: usize = expected.len;
    while (index > 1) {
        index -= 1;
        std.mem.swap(i64, &expected[index], &expected[@intCast(pass.below(index + 1).?)]);
    }
    const a = x.elements(x.get("A").?).?;
    for (a, expected) |actual, wanted| try std.testing.expectEqual(wanted, actual.integer);
    var seen: [9]bool = @splat(false);
    for (a) |value| seen[@intCast(value.integer)] = true;
    for (seen[1..]) |found| try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 3), x.elements(x.get("B").?).?.len);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("C").?).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("D").?).?.len);
    try std.testing.expectEqual(@as(i64, 9), x.elements(x.get("E").?).?[0].integer);
    var lengths: usize = 0;
    for (x.elements(x.get("F").?).?) |row| lengths += x.elements(row).?.len;
    try std.testing.expectEqual(@as(usize, 6), lengths);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("Again").?).?.len);
    // The argument is a value: it is as it was.
    x = try w.run("Xs:[]i64=array{1,2,3,4,5}\nYs:[]i64=Shuffle(Xs)\nSame:logic=Xs==array{1,2,3,4,5}");
    try std.testing.expect(x.get("Same").?.boolean);
}

test "an effect needs <transacts>, yields to the program's own names and binds as a native" {
    const w = try World.create();
    defer w.destroy();
    const front = w.h.front;
    // A function that only computes cannot act on the world or draw from it.
    for ([_][]const u8{
        "F()<computes>:tuple()=Print(\"x\")",
        "F()<computes>:i64=GetRandomInt(1,6)",
        "F()<computes>:float=GetRandomFloat(0.0,1.0)",
        "F(Xs:[]i64)<computes>:[]i64=Shuffle(Xs)",
        "F()<computes><decides>:i64=Block{Print(\"x\");1}",
        "F()<computes>:i64=Block{G:=Fn()<computes>:i64{GetRandomInt(1,2)};G()}",
        "P:=native{\"std.print\"}\nF()<computes>:tuple()=P(\"x\")",
        "R:=native{\"std.random_int\"}\nF()<computes>:i64=R(1,6)",
    }) |source| {
        const outcome = front.compile(source);
        if (outcome != .failed or outcome.failed.code != .call_requires_transacts) {
            std.debug.print("not call_requires_transacts: {s}\n", .{source});
            return error.TestUnexpectedResult;
        }
    }
    // Every heap effect is needed, not any one family (RFC-0078): the diagnostic names the
    // ones a function lacks.
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        .{ "F()<reads>:tuple()=Print(\"x\")", .call_requires_writes_allocates },
        .{ "F()<writes>:i64=GetRandomInt(1,6)", .call_requires_reads_allocates },
        .{ "F()<allocates>:float=GetRandomFloat(0.0,1.0)", .call_requires_reads_writes },
        .{ "F(Xs:[]i64)<reads><writes>:[]i64=Shuffle(Xs)", .call_requires_allocates },
        .{ "F()<reads><allocates>:tuple()=Print(\"x\")", .call_requires_writes },
        .{ "F()<writes><allocates><decides>:i64=Block{Print(\"x\");1}", .call_requires_reads },
        .{ "R:=native{\"std.random_int\"}\nF()<reads><writes>:i64=R(1,6)", .call_requires_allocates },
    }) |case| {
        const outcome = front.compile(case[0]);
        if (outcome != .failed or outcome.failed.code != case[1]) {
            std.debug.print("expected {s}: {s}\n", .{ @tagName(case[1]), case[0] });
            return error.TestUnexpectedResult;
        }
    }
    _ = try w.expect("F()<reads><writes><allocates>:tuple()=Print(\"spelled\")\nA:tuple()=F()", "spelled\n");
    // Types and counts.
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, front.compile("A:=Print(42)").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, front.compile("A:=GetRandomInt(1.0,2.0)").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, front.compile("A:=GetRandomFloat(1,2)").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, front.compile("A:=Shuffle(\"text\")").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, front.compile("A:i64=Print(\"x\")").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.argument_count, front.compile("A:=Print(\"x\",\"y\")").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.argument_count, front.compile("A:=GetRandomInt(1)").failed.code);
    // Brackets are for forms that can fail, and none of these can.
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, front.compile("A:=Print[\"x\"]").failed.code);
    // The names are not reserved: whatever the program declares by one is what it means.
    _ = try w.expect("Print(S:string)<computes>:i64=S.Length\nA:i64=Print(\"four\")", "");
    _ = try w.expect("GetRandomInt(A:i64,B:i64)<computes>:i64=A+B\nX:i64=GetRandomInt(1,2)\nShuffle(Xs:[]i64)<computes>:i64=Xs.Length\nY:i64=Shuffle(array{1,2})", "");
    var x = try w.run("F(Print:i64)<computes>:i64=Print+1\nA:i64=F(1)\nG()<computes>:i64=Block{Shuffle:=5;Shuffle}\nB:i64=G()");
    try std.testing.expectEqual(@as(i64, 2), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("B").?.integer);
    try std.testing.expectEqual(@as(u64, 0), x.effects.draws);
    // A member of the class a method is in: reached through `Self`, and bare it stays the
    // unknown name it was rather than quietly becoming the standard function.
    x = try w.expect("C:=class{\n  Print(S:string)<computes>:i64=S.Length\n  F()<computes>:i64=Self.Print(\"abc\")\n}\nA:i64=C{}.F()", "");
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, front.compile("C:=class{\n  Print(S:string)<computes>:i64=S.Length\n  F()<transacts>:tuple()=Print(\"abc\")\n}").failed.code);
    // A name a used module exports wins; without `using` the bare name is the standard one, in
    // every module of a bundle, and a module's effects need <transacts> as the root's do not.
    const modules = @import("modules.zig");
    const lib = "GetRandomInt<public>(A:i64,B:i64)<computes>:i64=A*B\nSay<public>(S:string)<transacts>:tuple()=Print(\"lib {S}\")";
    const used = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64=GetRandomInt(6,7)\nB<public>:tuple()=Say(\"one\")" },
        .{ .path = "lib.forb", .source = lib },
    };
    var bundled = front.compileBundle(.{ .root = "main.forb", .modules = &used });
    try std.testing.expect(bundled == .ok);
    w.clear();
    x = (try w.h.run(bundled.ok, 4096)).ok;
    try std.testing.expectEqual(@as(i64, 42), x.get("A").?.integer);
    try std.testing.expectEqual(@as(u64, 0), x.effects.draws);
    try std.testing.expectEqualStrings("lib one\n", try w.agreed());
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64=GetRandomInt(6,7)\nB<public>:i64=L.GetRandomInt(6,7)" },
        .{ .path = "lib.forb", .source = lib },
    };
    bundled = front.compileBundle(.{ .root = "main.forb", .modules = &plain });
    try std.testing.expect(bundled == .ok);
    x = (try w.h.run(bundled.ok, 4096)).ok;
    var stream: effects.Stream = .{};
    try std.testing.expectEqual(stream.integer(6, 7).?, x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 42), x.get("B").?.integer);
    const refused = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64=1" },
        .{ .path = "lib.forb", .source = "Say<public>(S:string)<computes>:tuple()=Print(S)" },
    };
    try std.testing.expectEqual(types.Diagnostic.Code.call_requires_transacts, front.compileBundle(.{ .root = "main.forb", .modules = &refused }).failed.diagnostic.code);
    // Declared further down, the name is the program's above as well: not the standard one.
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, front.compile("A:=Print(\"x\")\nPrint(S:string)<computes>:i64=1").failed.code);
    // Bound by id, an effect native is called like any native, from `<transacts>`.
    x = try w.expect("Say:=native{\"std.print\"}\nRoll:=native{\"std.random_int\"}\nWord:=native{\"std.random_word\"}\nF()<transacts>:i64=Block{Say(\"bound\");Roll(1,6)}\nA:i64=F()\nB:tuple()=Say(\"root\")\nC:i64=Word()", "bound\nroot\n");
    var model: effects.Stream = .{};
    try std.testing.expectEqual(model.integer(1, 6).?, x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, @bitCast(model.next())), x.get("C").?.integer);
    // A host without the kernels has no such forms.
    const empty = [_]native.Entry{};
    front.natives = &empty;
    defer front.natives = &native_std.table;
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, front.compile("A:=Print(\"x\")").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, front.compile("A:=GetRandomInt(1,2)").failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_native, front.compile("A:=Shuffle(array{1})").failed.code);
}
