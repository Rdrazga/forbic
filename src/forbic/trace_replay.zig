//! Reports for runs that did not store their call witness.
//!
//! A `full` run stores every call step, and a report replays them before it prints. That bounds
//! a run by witness storage. A `digest` run stores no step: it keeps the count and a hash of the
//! steps, so it can be as long as its fuel allows. Its report cannot read the steps back, and
//! it cannot compute them either: the replay checks schedules, copies, cell state and
//! allocations itself, but it takes the result of arithmetic, comparisons, string operations
//! and native calls from the step that recorded it. Storing only those results would still
//! grow with the run.
//!
//! So the report gets the steps a second time. The reference evaluator runs the program again
//! on the storage here and hands each window of steps to the replay, which checks the window
//! against the first run's final state and then lets it go. Memory is one window however long
//! the run is. At the end the replay's own count and digest of the stream must equal the first
//! run's, so the two runs agreed on every step, arithmetic included, and the final state being
//! printed is the one that stream leads to.
//!
//! The replay's work budget bounds the second run too. When the replay refuses a window for lack
//! of work (`ReportLimit`) it tells the run so through `TraceSink.more`, and the run stops with
//! `call_trace_limit` within a step or two instead of running to the end of its fuel. That run
//! leaves the strings of the pool's tail partly written, so the refused execution is spent.
//!
//! Both runs build strings in the tail of the program's one string pool, at the same places.
//! The replay therefore checks that the pool holds the same bytes afterwards.
//!
//! A run that stores no steps also reclaims members it can no longer reach
//! (`ControlStorage.reclaim_floor`), so the first run's final pool no longer holds what its
//! earlier steps named. The second run reclaims at the same points, and sends the window it
//! holds, with its pool, before each reclamation. The replay checks the steps of a call against
//! that pool, works out every reclamation from the rule by itself, and at the end requires the
//! second run's members to be the first run's, which are the ones a report prints.
const std = @import("std");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");

/// Storage for the second run. It must not be the storage of the run being reported, whose
/// final values the replay reads while this run is in progress.
pub const Storage = struct {
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},
    state: source_state.ReferenceState = .{},
    frames: call_frames.ReferenceStorage = .{},
    program: types.Program = .{ .source = "", .nodes = &.{}, .bindings = &.{}, .strings = "" },
    work_budget: u64 = 0,

    /// `program` is the program as compiled, not `Execution.program`, whose strings a run has
    /// extended. `work_budget` is the fuel the reported run was given.
    pub fn producer(self: *Storage, program: types.Program, work_budget: u64) types.TraceProducer {
        self.program = program;
        self.work_budget = work_budget;
        return .{ .context = self, .run = run, .inputs = &self.control.effects.inputs };
    }

    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Storage = @ptrCast(@alignCast(context));
        self.control.trace = .digest;
        self.control.trace_sink = sink;
        // The sink borrows the caller's replay, which does not outlive this call.
        defer self.control.trace_sink = null;
        return evaluator.evaluateWithRuntimeStorage(self.program, &self.values, &self.members, &self.control, &self.state, &self.frames, self.work_budget) == .ok;
    }
};

const scratch = @import("scratch.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");

/// One of each kind of traced work: calls, frames that fail and are caught at each level,
/// counted and state loops, callable iteration over every kind of value, bound functions,
/// classes with dispatch, and cell and instance state that is rolled back.
pub const programs = [_][]const u8{
    "Step(S:i64)<computes>:i64=S+1\nA<public>:i64=Iterate(Step,40,0)",
    "Down(N:i64)<computes>:i64=If(N==0,0,1+Down(N-1))\nA<public>:i64=Down(12)",
    "Make()<computes>:map(i64,string)=map{1+0=>\"a\",3+0=>\"b\"};F()<computes><decides>:i64=If(Make().Length>0,Fail[\"stop\"],0);G()<computes><decides>:i64=F[];A:i64=Attempt(G[],7)",
    "var Count:i64=0\nDeep(N:i64)<transacts>:i64=If(N==0,0,Attempt(Block{set Count=Count+1;1+Deep(N-1)},-1000))\nFall(N:i64)<transacts><decides>:i64=Block{set Count=Count+1;Require[N>0];Fall[N-1]}\nKept<public>:i64=Deep(5)\nSeen<public>:i64=Count\nGone<public>:i64=Attempt(Fall[3],7)\nAfter<public>:i64=Count",
    "var C:i64=7;Step(X:i64)<transacts><decides>:option(i64)=Block{set C=C+1;Require[X<3];option{X+1}};F:function<transacts><decides>(tuple(i64),option(i64))=Step;A:i64=Attempt(Loop(F,0),C);B:i64=C;Outer(G:function<transacts><decides>(tuple(i64),option(i64)),X:i64)<transacts>:i64=Attempt(Loop(G,X),C);D:i64=Outer(F,0);E:i64=C;Safe(X:i64)<transacts>:option(i64)=Attempt(Step[X],option{});H:i64=Loop(Safe,0);I:i64=C",
    "Mode:=enum{One,Two};KF(X:float)<computes>:float=X;KS(X:string)<computes>:string=X;KL(X:logic)<computes>:logic=X;KE(X:Mode)<computes>:Mode=X;KA(X:[]i64)<computes>:[]i64=X;KO(X:option(i64))<computes>:option(i64)=X;KM(X:map(string,i64))<computes>:map(string,i64)=X;KT(X:tuple(i64,string))<computes>:tuple(i64,string)=X;Inc(X:i64)<computes>:i64=X+1;KC(X:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=X;R:=struct{N:i64,T:string};KR(X:R)<computes>:R=R{N:=X.N+1,T:=X.T};Seed:R=R{N:=2,T:=\"雪\"};V:R=Iterate((KR),20,Seed);Old:i64=Seed.N;N:i64=V.N;Text:string=V.T;Nan:float=Iterate((KF),2,NaN);Zero:float=Iterate((KF),2,-0.0);S:string=Iterate((KS),2,\"雪\");L:logic=Iterate((KL),2,true);E:Mode=Iterate((KE),2,Mode.Two);A:[]i64=Iterate((KA),2,array{});O:option(i64)=Iterate((KO),2,option{});M:map(string,i64)=Iterate((KM),2,map{});T:tuple(i64,string)=Iterate((KT),2,tuple{42,\"雪\"});C:function(tuple(i64),i64)=Iterate((KC),2,Inc);Answer:i64=C(41)",
    "var C:i64=7;Step(X:i64)<transacts><decides>:i64=Block{set C=C+1;Require[X<3];X+1};F:function<transacts><decides>(tuple(i64),i64)=Step;A:i64=Attempt(Iterate(F,5,0),C);B:i64=C;Outer(G:function<transacts><decides>(tuple(i64),i64),X:i64)<transacts>:i64=Attempt(Iterate(G,5,X),C);D:i64=Outer(F,0);E:i64=C;Safe(X:i64)<transacts>:i64=Attempt(Step[X],X+10);G:function<transacts>(tuple(i64),i64)=Safe;H:i64=Iterate(G,5,0);I:i64=C",
    "Add(A:i64,B:i64)<computes>:i64=A+B;Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;Plus:function(tuple(i64),i64)=Bind(Add,2);Closed:function(tuple(),i64)=Bind(Plus,40);Nested:function(tuple(i64),i64)=Bind(Bind(Sum,1),2);A:i64=Plus(40);B:i64=Closed();C:i64=Nested(39);D:i64=Bind(Add,20)(22)",
    "Join(S:string)<computes>:string=S+\"x\"\nText<public>:string=Iterate(Join,6,\"a\")\nLength<public>:i64=Text.Length",
    \\Base:=class{
    \\  var Calls:i64=0
    \\  Note(By:i64)<transacts>:i64=Block{set Self.Calls=Self.Calls+1;By}
    \\}
    \\Loud:=class(Base){
    \\  Note<override>(By:i64)<transacts>:i64=Super.Note(By)*2
    \\}
    \\L:=Loud{}
    \\Doubled:i64=L.Note(21)
    \\Counted:i64=L.Calls
    \\Node:=class{
    \\  Value:i64
    \\  Left:option(Node)
    \\  Right:option(Node)
    \\  Sum()<transacts>:i64=Block{
    \\    P:=Attempt(Block{N:=Self.Left?;N.Sum()},0)
    \\    Q:=Attempt(Block{N:=Self.Right?;N.Sum()},0)
    \\    Self.Value+P+Q
    \\  }
    \\}
    \\Leaf1:=Node{Value:=2,Left:=option{},Right:=option{}}
    \\Leaf2:=Node{Value:=3,Left:=option{},Right:=option{}}
    \\Branch:=Node{Value:=10,Left:=option{Leaf1},Right:=option{Leaf2}}
    \\Root:=Node{Value:=100,Left:=option{Branch},Right:=option{Leaf1}}
    \\Everything:i64=Root.Sum()
    ,
    \\Bag:=class{
    \\  var Items:[]i64
    \\  Find(Wanted:i64)<transacts><decides>:i64=Block{
    \\    I:=For(Item:Self.Items,Item==Wanted,Item)
    \\    Require[I.Length>0]
    \\    I[0]
    \\  }
    \\}
    \\B:=Bag{Items:=array{4,5,6}}
    \\Hit:i64=Attempt(B.Find[5],-1)
    \\Miss:i64=Attempt(B.Find[9],-1)
    ,
    "P:=class{var N:i64}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};S+X.N-S+1}\nKeep(S:i64)<transacts><decides>:i64=Block{X:=P{N:=S};Require[S<2];S+1}\nTotal<public>:i64=Iterate(Step,20,0)\nLost<public>:i64=Attempt(Keep[5],-1)\nLast<public>:P=P{N:=Total}",
    "A:i64=42",
};

pub const fuel = 131072;
const text_bytes = 64 * 1024;

pub const Fixture = struct {
    h: *harness.Harness,
    again: *Storage,
    full: []u8,
    replayed: []u8,

    pub fn create() !Fixture {
        const h = try harness.create();
        errdefer scratch.release(h);
        const again = try scratch.storage(Storage);
        errdefer scratch.release(again);
        scratch.initialise(again);
        const full = try std.testing.allocator.alloc(u8, text_bytes);
        errdefer std.testing.allocator.free(full);
        return .{ .h = h, .again = again, .full = full, .replayed = try std.testing.allocator.alloc(u8, text_bytes) };
    }
    pub fn destroy(self: Fixture) void {
        std.testing.allocator.free(self.replayed);
        std.testing.allocator.free(self.full);
        scratch.release(self.again);
        scratch.release(self.h);
    }
    pub fn mode(self: Fixture, trace: types.TraceMode, window: u32) void {
        self.h.control.trace = trace;
        self.h.control.trace_window = window;
        self.h.runtime.machine.control.trace = trace;
        self.h.runtime.machine.control.trace_window = window;
    }
    const Pair = struct { reference: evaluator.Execution, actual: evaluator.Execution };
    /// Runs both machines without the harness's own report, which needs a stored witness.
    fn both(self: Fixture, p: types.Program) !Pair {
        const h = self.h;
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const actual = h.runtime.evaluate(p, fuel);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqualSlices(bool, reference.ok.activity, actual.ok.activity);
        try std.testing.expectEqual(reference.ok.failure_count, actual.ok.failure_count);
        try std.testing.expectEqualDeep(reference.ok.failures, actual.ok.failures);
        for (reference.ok.values, actual.ok.values, 0..) |a, b, index| if (actual.ok.active(index)) try same(a, b);
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try same(a, b);
        try std.testing.expectEqual(reference.ok.object_cells.len, actual.ok.object_cells.len);
        for (reference.ok.object_cells, actual.ok.object_cells) |a, b| {
            try std.testing.expectEqual(a.initialized, b.initialized);
            try same(a.value, b.value);
        }
        return .{ .reference = reference.ok, .actual = actual.ok };
    }
};

pub fn same(a: types.Value, b: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .floating) try std.testing.expectEqual(@as(u64, @bitCast(a.floating)), @as(u64, @bitCast(b.floating))) else try std.testing.expectEqualDeep(a, b);
}

test "both machines fold the witness they would have stored and a replayed report equals the stored one" {
    const f = try Fixture.create();
    defer f.destroy();
    const sentinel: types.CallStep = .{ .function = 0xfeedface, .pc = 7, .value = .{ .integer = -1 } };
    for (programs) |source| {
        const p = try f.h.compile(source);
        f.mode(.full, types.ControlStorage.default_trace_window);
        const stored = (try f.h.run(p, fuel)).ok;
        const expected: types.Witness = stored.callWitness().?;
        try std.testing.expectEqual(@as(u64, stored.call_steps.len), expected.count);
        var out = std.Io.Writer.fixed(f.full);
        const stored_stats = try reporting.write(&out, stored, false, .{});
        const values_end = out.end;
        try trace_report.write(&out, stored, "test.forb", .{});
        const full_end = out.end;
        for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
            f.mode(.digest, window);
            if (window < types.limits.call_steps) {
                f.h.control.calls[window] = sentinel;
                f.h.runtime.machine.control.calls[window] = sentinel;
            }
            const runs = try f.both(p);
            // Nothing is stored, and nothing beyond the window was ever written.
            try std.testing.expectEqual(@as(usize, 0), runs.reference.call_steps.len + runs.actual.call_steps.len);
            if (window < types.limits.call_steps) {
                try std.testing.expectEqualDeep(sentinel, f.h.control.calls[window]);
                try std.testing.expectEqualDeep(sentinel, f.h.runtime.machine.control.calls[window]);
            }
            if (types.cold(p)) try std.testing.expect(runs.reference.trace == .digest and runs.actual.trace == .digest);
            try std.testing.expectEqualDeep(expected, runs.reference.callWitness().?);
            try std.testing.expectEqualDeep(expected, runs.actual.callWitness().?);
            // The replay reads steps a window at a time and charges what the stored replay did.
            f.again.control.trace_window = window;
            out = .fixed(f.replayed);
            const replayed_stats = try reporting.writeReplayed(&out, runs.actual, f.again.producer(p, fuel), false, .{});
            try std.testing.expectEqualDeep(stored_stats, replayed_stats);
            try std.testing.expectEqual(values_end, out.end);
            try trace_report.writeReplayed(&out, runs.actual, f.again.producer(p, fuel), "test.forb", .{});
            try std.testing.expectEqualSlices(u8, f.full[0..full_end], f.replayed[0..out.end]);
            _ = try reporting.validateReplayed(runs.reference, f.again.producer(p, fuel), false, .{});
            // A report that replays stored steps has none to read here.
            if (types.cold(p)) try std.testing.expectError(error.InvalidExecution, reporting.validate(runs.actual, false, .{}));
        }
        f.mode(.off, 5);
        const silent = try f.both(p);
        try std.testing.expectEqual(@as(usize, 0), silent.reference.call_steps.len + silent.actual.call_steps.len);
        if (types.cold(p)) {
            try std.testing.expect(silent.reference.callWitness() == null and silent.actual.callWitness() == null);
            try std.testing.expectError(error.InvalidExecution, reporting.validate(silent.actual, false, .{}));
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(silent.actual, f.again.producer(p, fuel), false, .{}));
        }
    }
}

test "every field of every step and the order of steps reach the digest" {
    const f = try Fixture.create();
    defer f.destroy();
    for (programs) |source| {
        const p = try f.h.compile(source);
        const x = (try f.h.run(p, fuel)).ok;
        const steps = f.h.steps[0..x.call_steps.len];
        const pool = x.program.strings.ptr;
        const honest = types.Witness.of(x.call_steps, pool);
        // Folding in pieces is folding at once: a window boundary is not part of the stream.
        var pieces: types.Witness = .{};
        var at: usize = 0;
        while (at < x.call_steps.len) : (at += @min(5, x.call_steps.len - at)) pieces.fold(x.call_steps[at..][0..@min(5, x.call_steps.len - at)], pool);
        try std.testing.expectEqualDeep(honest, pieces);
        for (0..steps.len) |index| for (0..5) |change| {
            @memcpy(steps, x.call_steps);
            const step = &steps[index];
            switch (change) {
                0 => step.function +%= 1,
                1 => step.pc +%= 1,
                2 => step.kind = if (step.kind == .value) .propagate else .value,
                3 => switch (step.value) {
                    .integer => |*value| value.* +%= 1,
                    .boolean => |*value| value.* = !value.*,
                    .floating => |*value| value.* = if (value.* == 1.5) 2.5 else 1.5,
                    .string => |*value| value.* = if (value.len == 0) pool[0..1] else value.*[0 .. value.len - 1],
                    .aggregate => |*value| value.elements.end += 1,
                    .enumeration => |*value| value.index += 1,
                    .callable => |*value| value.function += 1,
                    .object => |*value| value.id += 1,
                    .rational => |*value| value.numerator +%= 1,
                },
                else => {
                    // Equal neighbours leave the stream as it was (a NaN step equals itself here).
                    if (index + 1 == steps.len or types.Witness.of(steps[index..][0..1], pool).eql(.of(steps[index + 1 ..][0..1], pool))) continue;
                    std.mem.swap(types.CallStep, step, &steps[index + 1]);
                },
            }
            const forged = types.Witness.of(steps, pool);
            try std.testing.expectEqual(honest.count, forged.count);
            try std.testing.expect(honest.digest != forged.digest);
        };
        if (steps.len != 0) {
            const shorter = types.Witness.of(x.call_steps[0 .. steps.len - 1], pool);
            try std.testing.expect(shorter.count != honest.count and shorter.digest != honest.digest);
        }
    }
}

/// A second run that completes and then changes one byte of the string pool.
const Scribbler = struct {
    inner: types.TraceProducer,
    byte: *u8,
    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Scribbler = @ptrCast(@alignCast(context));
        const completed = self.inner.run(self.inner.context, sink);
        self.byte.* ^= 1;
        return completed;
    }
};

/// A second run whose stream differs from the real one in the value of one step.
const Tamperer = struct {
    inner: types.TraceProducer,
    sink: types.TraceSink = undefined,
    done: bool = false,
    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Tamperer = @ptrCast(@alignCast(context));
        self.sink = sink;
        return self.inner.run(self.inner.context, .{ .context = self, .write = write });
    }
    fn write(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Tamperer = @ptrCast(@alignCast(context));
        var copy: [8]types.CallStep = undefined;
        @memcpy(copy[0..steps.len], steps);
        if (!self.done) for (copy[0..steps.len]) |*step| if (step.value == .integer) {
            step.value.integer +%= 1;
            self.done = true;
            break;
        };
        self.sink.write(self.sink.context, copy[0..steps.len], members, strings);
    }
};

test "a replayed report rejects a forged witness, final value, final cell, member, string pool and second run" {
    const f = try Fixture.create();
    defer f.destroy();
    for (programs) |source| {
        const p = try f.h.compile(source);
        if (!types.cold(p)) continue;
        f.mode(.digest, 3);
        f.again.control.trace_window = 3;
        const x = (try f.both(p)).actual;
        _ = try reporting.validateReplayed(x, f.again.producer(p, fuel), false, .{});
        if (x.witness.count == 0) continue;
        var forged = x;
        forged.witness.digest ^= 1;
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
        for ([_]u64{ x.witness.count - 1, x.witness.count + 1 }) |count| {
            forged = x;
            forged.witness.count = count;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
        }
        forged = x;
        forged.witness.failures += 1;
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
        // A stored witness of the same run is not a licence to skip the replay.
        forged = x;
        forged.trace = .full;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
        forged = x;
        forged.trace = .off;
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
        // The result of every traced root call is what the stream returned.
        const values = try std.testing.allocator.dupe(types.Value, x.values);
        defer std.testing.allocator.free(values);
        for (p.nodes, 0..) |node, index| {
            if (!node.isInvocation() or !x.active(index) or values[index] != .integer) continue;
            const invocation = node.invocationWith(null, x.values).?;
            const target = p.functions[invocation.target()];
            if (node.kind != .invoke and invocation == .call and !target.has_control and !target.has_source and !target.has_local) continue;
            values[index].integer +%= 1;
            forged = x;
            forged.values = values;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
            values[index] = x.values[index];
        }
        // The final state of every instance is the state the stream built.
        const cells = try std.testing.allocator.dupe(source_state.Cell, x.object_cells);
        defer std.testing.allocator.free(cells);
        for (cells, 0..) |*cell, index| {
            if (cell.value != .integer) continue;
            // A header names the class; a different one moves every later instance.
            cell.value.integer +%= 1;
            forged = x;
            forged.object_cells = cells;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
            cell.* = x.object_cells[index];
        }
        // Every member the run built is the copy the stream describes.
        const members = try std.testing.allocator.dupe(types.Value, x.aggregate_values);
        defer std.testing.allocator.free(members);
        for (members, 0..) |*member, index| {
            if (member.* != .integer) continue;
            member.integer +%= 1;
            forged = x;
            forged.aggregate_values = members;
            const outcome = reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{});
            member.* = x.aggregate_values[index];
            // Members of a native result or of an untraced plain call are admitted, not replayed.
            if (outcome) |_| {} else |problem| try std.testing.expectEqual(error.InvalidExecution, problem);
        }
        // A second run that fails, or whose steps are not the first run's, validates nothing.
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(x, f.again.producer(p, 1), false, .{}));
        var tamperer: Tamperer = .{ .inner = f.again.producer(p, fuel) };
        const tampered = reporting.validateReplayed(x, .{ .context = &tamperer, .run = Tamperer.run }, false, .{});
        if (tamperer.done) try std.testing.expectError(error.InvalidExecution, tampered) else _ = try tampered;
        // The strings to be printed must still be the ones admitted before the second run.
        if (x.program.strings.len != 0) {
            var scribbler: Scribbler = .{ .inner = f.again.producer(p, fuel), .byte = @constCast(&x.program.strings[x.program.strings.len - 1]) };
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(x, .{ .context = &scribbler, .run = Scribbler.run }, false, .{}));
            scribbler.byte.* ^= 1;
            _ = try reporting.validateReplayed(x, f.again.producer(p, fuel), false, .{});
        }
    }
}

test "a run longer than the stored witness completes, agrees and is reported in digest mode" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    // Three steps a visit: the parameter, the constant and the sum.
    const p = try f.h.compile("Step(S:i64)<computes>:i64=S+1\nA<public>:i64=Iterate(Step,3000,0)");
    f.mode(.full, types.ControlStorage.default_trace_window);
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try f.h.run(p, fuel)).failed.code);
    f.mode(.off, types.ControlStorage.default_trace_window);
    try std.testing.expectEqual(@as(i64, 3000), (try f.both(p)).actual.get("A").?.integer);
    f.mode(.digest, types.ControlStorage.default_trace_window);
    const runs = try f.both(p);
    try std.testing.expectEqual(@as(i64, 3000), runs.actual.get("A").?.integer);
    try std.testing.expectEqual(@as(u64, 9000), runs.actual.witness.count);
    try std.testing.expect(runs.actual.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(runs.reference.witness, runs.actual.witness);
    var out = std.Io.Writer.fixed(f.replayed);
    // The replay is charged per step, so a long run needs a budget to match.
    try std.testing.expectError(error.ReportLimit, reporting.writeReplayed(&out, runs.actual, f.again.producer(p, fuel), false, .{ .work = 9000 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    _ = try reporting.writeReplayed(&out, runs.actual, f.again.producer(p, fuel), false, .{});
    try std.testing.expectEqualStrings("{\"A\":3000}\n", out.buffered());
    var forged = runs.actual;
    forged.witness.digest +%= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
    const values = try std.testing.allocator.dupe(types.Value, runs.actual.values);
    defer std.testing.allocator.free(values);
    forged = runs.actual;
    forged.values = values;
    for (p.bindings) |binding| values[binding.node] = .{ .integer = 2999 };
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, f.again.producer(p, fuel), false, .{}));
}

test "a report that runs out of work stops the second run within a window" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const p = try f.h.compile("Step(S:i64)<computes>:i64=S+1\nA<public>:i64=Iterate(Step,3000,0)");
    f.mode(.digest, types.ControlStorage.default_trace_window);
    const runs = try f.both(p);
    try std.testing.expectEqual(@as(u64, 9000), runs.actual.witness.count);
    var out = std.Io.Writer.fixed(f.replayed);
    // A budget that the first window of steps exceeds: the replay refuses the report at that window.
    try std.testing.expectError(error.ReportLimit, reporting.writeReplayed(&out, runs.actual, f.again.producer(p, fuel), false, .{ .work = 100 }));
    // And the second run is stopped there, not run to its end: the work of the report bounds the
    // work of the run that feeds it. It folded the window that was refused and no more than a
    // step or two (the pair of folds at the end of a call) after it.
    const folded = f.again.control.witness.count;
    try std.testing.expect(folded >= types.ControlStorage.default_trace_window);
    try std.testing.expect(folded <= types.ControlStorage.default_trace_window + 8);
    try std.testing.expect(f.again.control.stopped);
    // The storage is reusable: a fresh first run is replayed to its end when the budget allows it.
    // (The refused execution is spent: the stopped run left its string pool partly rewritten.)
    const fresh = try f.both(p);
    _ = try reporting.writeReplayed(&out, fresh.actual, f.again.producer(p, fuel), false, .{});
    try std.testing.expectEqual(@as(u64, 9000), f.again.control.witness.count);
    try std.testing.expect(!f.again.control.stopped);
}
