//! The report replay works out every value that the program and the values before it decide
//! (RFC-0024, "Amendment: the replay works out every value"). Each forgery below is a report of
//! a real run of both machines with one recorded value changed so that nothing else the run
//! recorded disagrees with it: the value of a node no other node reads, or the root value of a
//! binding nothing reads. Before the amendment the replay accepted every one of them. The
//! sweeps change each recorded value of real reports in turn, one at a time, and every change is
//! refused.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 22;
const limits: reporting.Limits = .{ .work = 1 << 24 };

/// A writable copy of a report's steps, root values and members, for forging one of them.
const Copy = struct {
    execution: evaluator.Execution,
    steps: []types.CallStep,
    values: []types.Value,
    members: []types.Value,

    fn of(x: evaluator.Execution) !Copy {
        const allocator = std.testing.allocator;
        const steps = try allocator.dupe(types.CallStep, x.call_steps);
        errdefer allocator.free(steps);
        const values = try allocator.dupe(types.Value, x.values);
        errdefer allocator.free(values);
        const members = try allocator.dupe(types.Value, x.aggregate_values);
        var execution = x;
        execution.call_steps = steps;
        execution.values = values;
        execution.aggregate_values = members;
        return .{ .execution = execution, .steps = steps, .values = values, .members = members };
    }
    fn free(self: Copy) void {
        std.testing.allocator.free(self.members);
        std.testing.allocator.free(self.values);
        std.testing.allocator.free(self.steps);
    }
};

fn run(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    const p = try h.compile(source);
    const outcome = try h.run(p, fuel);
    if (outcome == .failed) {
        std.debug.print("run failed: {t}\n", .{outcome.failed.code});
        return error.RunFailed;
    }
    return outcome.ok;
}

/// Whether the replay refuses the report as one the program could not have produced.
fn refuses(x: evaluator.Execution) !bool {
    _ = reporting.validate(x, false, limits) catch |err| switch (err) {
        error.InvalidExecution => return true,
        error.ReportLimit => return err,
    };
    return false;
}

/// The node a step of a function stands at.
fn nodeOf(p: types.Program, step: types.CallStep) ?types.Node {
    if (step.function >= p.functions.len) return null;
    const body = p.functions[step.function].body;
    if (step.pc >= body.end - body.start) return null;
    return p.function_nodes[body.start + step.pc].node;
}

/// A value of the same kind that differs from `value`, and is itself well formed: so that a
/// refusal is the replay's answer about the value and not about its form. Null for a value that
/// names storage (an aggregate, a function, an instance), whose forgeries the replay's other
/// checks cover.
fn other(p: types.Program, value: types.Value) ?types.Value {
    return switch (value) {
        .integer => |x| .{ .integer = x +% 1 },
        .boolean => |x| .{ .boolean = !x },
        // Far from 0, adding 1 changes nothing, and halving does.
        .floating => |x| .{ .floating = if (types.isNan(x) or std.math.isInf(x)) 0.0 else if (x + 1.0 == x) x * 0.5 else x + 1.0 },
        .rational => |r| if (r.numerator < std.math.maxInt(i64) - r.denominator) .{ .rational = .{ .numerator = r.numerator + r.denominator, .denominator = r.denominator } } else null,
        // A shorter string at the same place, or a one-byte literal for an empty one.
        .string => |s| if (s.len != 0) .{ .string = s[0..0] } else if (p.strings.len != 0 and p.strings[0] < 0x80) .{ .string = p.strings[0..1] } else null,
        .enumeration, .aggregate, .callable, .object => null,
    };
}

/// The first `value` step of a node of kind `tag` in the function named `function`.
fn stepOf(x: evaluator.Execution, function: []const u8, tag: std.meta.Tag(@FieldType(types.Node, "kind"))) !usize {
    const p = x.program;
    for (x.call_steps, 0..) |step, index| {
        if (step.kind != .value) continue;
        const node = nodeOf(p, step) orelse continue;
        if (node.kind != tag) continue;
        if (!std.mem.eql(u8, p.functions[step.function].name.text(p.source), function)) continue;
        return index;
    }
    std.debug.print("no value step of {t} in {s}\n", .{ tag, function });
    return error.TestUnexpectedResult;
}

fn bindingNode(x: evaluator.Execution, name: []const u8) !u32 {
    for (x.program.bindings) |binding| if (std.mem.eql(u8, binding.name.text(x.program.source), name)) return binding.node;
    return error.TestUnexpectedResult;
}

/// The report with the value step of the first node of kind `tag` in `function` changed.
fn expectStepForgeryRefused(x: evaluator.Execution, function: []const u8, tag: std.meta.Tag(@FieldType(types.Node, "kind"))) !void {
    const copy = try Copy.of(x);
    defer copy.free();
    const index = try stepOf(x, function, tag);
    const recorded = copy.steps[index].value;
    // A lookup that found its key is forged as one that did not.
    copy.steps[index].value = if (tag == .map_lookup) .{ .aggregate = .{ .value_type = recorded.aggregate.value_type, .elements = .{ .start = recorded.aggregate.elements.end, .end = recorded.aggregate.elements.end } } } else other(x.program, recorded) orelse {
        std.debug.print("{t} step {d} in {s} has no other value: {any}\n", .{ tag, index, function, copy.steps[index].value });
        return error.TestUnexpectedResult;
    };
    if (!try refuses(copy.execution)) {
        std.debug.print("forged {t} step {d} in {s} accepted\n", .{ tag, index, function });
        return error.TestUnexpectedResult;
    }
}

/// The report with the root value of binding `name` changed to `forged`, or to `other` of it.
fn expectRootForgeryRefused(x: evaluator.Execution, name: []const u8, forged: ?types.Value) !void {
    const copy = try Copy.of(x);
    defer copy.free();
    const node = try bindingNode(x, name);
    copy.values[node] = forged orelse other(x.program, copy.values[node]) orelse return error.TestUnexpectedResult;
    if (!try refuses(copy.execution)) {
        std.debug.print("forged root value of {s} accepted\n", .{name});
        return error.TestUnexpectedResult;
    }
}

/// The report with the scalar members of the root value of binding `name` changed, one at a time.
fn expectMemberForgeriesRefused(x: evaluator.Execution, name: []const u8) !void {
    const node = try bindingNode(x, name);
    const elements = x.values[node].aggregate.elements;
    try std.testing.expect(elements.end > elements.start);
    for (elements.start..elements.end) |member| {
        const copy = try Copy.of(x);
        defer copy.free();
        copy.members[member] = other(x.program, copy.members[member]) orelse continue;
        if (!try refuses(copy.execution)) {
            std.debug.print("forged member {d} of {s} accepted\n", .{ member, name });
            return error.TestUnexpectedResult;
        }
    }
}

// Each local of `Probe` is read by nothing, so a forged value of its node disagrees with no
// other recorded value: only working the value out again can refuse it.
const frame_program =
    \\Sqrt:=native{"std.sqrt"}
    \\Upper:=native{"std.upper"}
    \\Sorted:=native{"std.sorted"}
    \\var X:i64 = 3
    \\var F:float = 2.5
    \\var S:string = "ab"
    \\var M:map(string,i64) = map{"a"=>1,"b"=>2}
    \\var O:option(i64) = option{4}
    \\var A:[]i64 = array{5,6,7}
    \\Probe()<transacts>:i64 = Block{
    \\    I := 7
    \\    B := true
    \\    T := "lit"
    \\    D := 1.5
    \\    N := -X
    \\    Times := X * 2
    \\    Half := F * 0.5
    \\    Minus := -F
    \\    Wide := ToFloat(X)
    \\    Down := Attempt(Block{ Q := Floor[F]; 0 }, 0)
    \\    Ratio := Attempt(Block{ Q := Rational[X, 2]; 0 }, 0)
    \\    Above := X > 2
    \\    Length := A.Length
    \\    Size := S.Length
    \\    Joined := S + "c"
    \\    Shown := ToString(X)
    \\    Found := Or(Lookup(M, "b"), 0)
    \\    Kept := Or(O, 0)
    \\    Root := Sqrt(F)
    \\    Loud := Upper(S)
    \\    X }
    \\V:i64 = Probe()
;

test "replay: a forged value of a pure node in a traced frame is refused, kind by kind" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, frame_program);
    const kinds = [_]std.meta.Tag(@FieldType(types.Node, "kind")){ .integer, .boolean, .string, .floating, .negate, .binary, .float_binary, .float_negate, .int_to_float, .float_to_int, .rational, .compare, .array_length, .string_length, .string_concat, .to_string, .map_lookup, .option_or, .native_call };
    for (kinds) |kind| try expectStepForgeryRefused(x, "Probe", kind);
}

test "replay: a forged member of a pure native's result in a traced frame is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\Sorted:=native{"std.sorted"}
        \\var A:[]i64 = array{7,5,6}
        \\Probe()<transacts>:i64 = Block{ Q := Sorted(A); A.Length }
        \\V:i64 = Probe()
    );
    const index = try stepOf(x, "Probe", .native_call);
    const elements = x.call_steps[index].value.aggregate.elements;
    for (elements.start..elements.end) |member| {
        const copy = try Copy.of(x);
        defer copy.free();
        copy.members[member] = other(x.program, copy.members[member]).?;
        try std.testing.expect(try refuses(copy.execution));
    }
}

test "replay: a forged value in a reaction's guard is refused" {
    // The reviewers' case (P4.6 O1, P4.7): the literal `0` of the guard `X > 0` at the
    // reaction's creation, recorded as `7`, made the replay accept a guard it never evaluated.
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h,
        \\var X:i64 = 0
        \\var Log:string = ""
        \\U:task(i64) = Upon(X > 0, Block{ Set(Log, Log + "u"); 0 })
        \\set X = 1
    );
    const p = x.program;
    var forged = false;
    for (x.call_steps, 0..) |step, index| {
        const node = nodeOf(p, step) orelse continue;
        if (step.kind != .value or node.kind != .integer or node.kind.integer != 0) continue;
        const copy = try Copy.of(x);
        defer copy.free();
        copy.steps[index].value = .{ .integer = 7 };
        try std.testing.expect(try refuses(copy.execution));
        forged = true;
    }
    try std.testing.expect(forged);
}

const root_program =
    \\Sqrt:=native{"std.sqrt"}
    \\Upper:=native{"std.upper"}
    \\Sorted:=native{"std.sorted"}
    \\Twice(N:i64)<computes>:i64 = N * 2 + 1
    \\Pair(N:i64)<computes>:tuple(i64,i64) = tuple{N, Twice(N)}
    \\Base:i64 = 4
    \\Lit:i64 = 9
    \\Flag:logic = false
    \\Text:string = "word"
    \\Times:i64 = Base * 3
    \\Above:logic = Base > 3
    \\Wide:float = ToFloat(Base) * 0.5
    \\Joined:string = Text + "s"
    \\Shown:string = ToString(Base)
    \\Size:i64 = Text.Length
    \\Called:i64 = Twice(Base)
    \\Second:i64 = Pair(Base)(1)
    \\Root:float = Sqrt(2.0)
    \\Loud:string = Upper(Text)
    \\Ordered:[]i64 = Sorted(array{3,1,2})
    \\Three:[]i64 = array{1,2,3}
    \\Twin:[]i64 = Attempt(Three.Insert[1,Three], Three)
    \\Flat:[]i64 = Concatenate(array{Three,array{4},Three})
;

test "replay: a forged root value of a pure node, of an untraced call and of a pure native is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try run(h, root_program);
    for ([_][]const u8{ "Lit", "Flag", "Text", "Times", "Above", "Wide", "Joined", "Shown", "Size", "Called", "Second", "Root", "Loud" }) |name| try expectRootForgeryRefused(x, name, null);
    // A string with other bytes where the run built one: the literal `word` for `WORD`.
    const word = std.mem.indexOf(u8, x.program.strings, "word").?;
    try expectRootForgeryRefused(x, "Loud", .{ .string = x.program.strings[word..][0..4] });
    try expectMemberForgeriesRefused(x, "Ordered");
    // A native given one array twice, and rows that are one array twice, which the replay
    // copies as often as the native reads them.
    try expectMemberForgeriesRefused(x, "Twin");
    try expectMemberForgeriesRefused(x, "Flat");
}

test "replay: a forged root value is refused in a digest run, whose steps a second run sends" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(
        \\var Count:i64 = 0
        \\Twice(N:i64)<computes>:i64 = N * 2 + 1
        \\Bump()<transacts>:i64 = Block{ set Count = Count + 1; Count * 10 }
        \\Called:i64 = Twice(4)
        \\Times:i64 = Called * 3
        \\Bumped:i64 = Bump()
    );
    f.mode(.digest, types.ControlStorage.default_trace_window);
    const actual = f.h.runtime.evaluate(p, fuel);
    try std.testing.expect(actual == .ok);
    _ = try reporting.validateReplayed(actual.ok, f.again.producer(p, fuel), false, limits);
    for ([_][]const u8{ "Called", "Times" }) |name| {
        const copy = try Copy.of(actual.ok);
        defer copy.free();
        const node = try bindingNode(actual.ok, name);
        copy.values[node] = .{ .integer = copy.values[node].integer + 1 };
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(copy.execution, f.again.producer(p, fuel), false, limits));
    }
}

/// Changes each recorded value of the report of `source` in turn: every step, every active root
/// value and every member, each to `other` of it. Every change must be refused.
fn sweep(h: *harness.Harness, name: []const u8, source: []const u8) !void {
    const x = try run(h, source);
    const copy = try Copy.of(x);
    defer copy.free();
    var tried: u32 = 0;
    var accepted: u32 = 0;
    for (copy.steps, 0..) |*step, index| {
        const original = step.value;
        step.value = other(x.program, original) orelse continue;
        defer step.value = original;
        tried += 1;
        if (!try refuses(copy.execution)) {
            accepted += 1;
            const node = nodeOf(x.program, step.*);
            std.debug.print("SWEEP {s}: step {d} ({t}, node {?t}) accepted\n", .{ name, index, step.kind, if (node) |n| std.meta.activeTag(n.kind) else null });
        }
    }
    for (copy.values, 0..) |*value, index| {
        if (!x.active(index)) continue;
        const original = value.*;
        value.* = other(x.program, original) orelse continue;
        defer value.* = original;
        tried += 1;
        if (!try refuses(copy.execution)) {
            accepted += 1;
            std.debug.print("SWEEP {s}: root value {d} ({t}) accepted\n", .{ name, index, std.meta.activeTag(x.program.nodes[index].kind) });
        }
    }
    for (copy.members, 0..) |*member, index| {
        const original = member.*;
        member.* = other(x.program, original) orelse continue;
        defer member.* = original;
        tried += 1;
        if (!try refuses(copy.execution)) {
            accepted += 1;
            std.debug.print("SWEEP {s}: member {d} accepted\n", .{ name, index });
        }
    }
    try std.testing.expect(tried != 0);
    if (accepted != 0) {
        std.debug.print("SWEEP {s}: {d} of {d} forgeries accepted\n", .{ name, accepted, tried });
        return error.TestUnexpectedResult;
    }
}

test "replay: every recorded value of real reports, changed in turn, is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    try sweep(h, "frame", frame_program);
    try sweep(h, "root", root_program);
    // The conformance fixtures `numeric-conversions`, `rational`, `strings`, `native-std` and
    // `map-updates`, as they are.
    try sweep(h, "numeric-conversions",
        \\var Cell:i64=0
        \\Big:float=1.0e30
        \\Bad:float=NaN
        \\Nearest(X:float)<computes>:i64=Attempt(Round[X],-99)
        \\Probe(X:float)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Floor[X]},Cell)
        \\Tie<public>:i64=Nearest(2.5)+Nearest(3.5)+Nearest(-2.5)
        \\Above<public>:i64=Nearest(2.75)
        \\Down<public>:i64=Attempt(Floor[-2.5],0)
        \\Up<public>:i64=Attempt(Ceil[-2.5],0)
        \\Toward<public>:i64=Attempt(Int[-2.5],0)
        \\Huge<public>:i64=Nearest(Big)
        \\NotANumber<public>:i64=Nearest(Bad)
        \\Kept<public>:i64=Probe(4.5)
        \\Dropped<public>:i64=Probe(Bad)
        \\Scaled<public>:float=ToFloat(7)*0.5
        \\Total<public>:i64=Tie+Above+Down+Up+Toward+Huge+NotANumber+Kept+Dropped+Cell
    );
    try sweep(h, "rational",
        \\var Cell:i64=0
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\Share(Total:i64,N:i64)<computes><decides>:i64=Floor(Rational[Total,N])
        \\Probe(B:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Quotient[7,B]},-Cell-100)
        \\Half<public>:rational=R(10,-4)
        \\Same<public>:logic=R(5,2)==R(15,6) and R(1,-3)==R(-1,3)
        \\Down<public>:i64=Floor(Half)
        \\Up<public>:i64=Ceil(Half)
        \\Quot<public>:i64=Attempt(Quotient[-7,2],0)
        \\Rem<public>:i64=Attempt(Mod[-7,2],0)
        \\NegQuot<public>:i64=Attempt(Quotient[7,-2],0)
        \\NegRem<public>:i64=Attempt(Mod[7,-2],0)
        \\Truncated<public>:i64=-7/2
        \\Sum<public>:rational=R(1,2)+R(1,3)-R(1,6)
        \\Product<public>:rational=-R(3,4)*R(2,9)
        \\Ordered<public>:logic=R(1,3)<R(1,2) and R(-1,2)<=R(-1,2)
        \\Approx<public>:float=ToFloat(R(1,8))
        \\Whole<public>:rational=MakeRationalFromInt(7)
        \\Fair<public>:i64=Attempt(Share[225,100],-1)
        \\NoPlayers<public>:i64=Attempt(Share[225,0],-1)
        \\Kept<public>:i64=Probe(2)
        \\Dropped<public>:i64=Probe(0)
        \\Prices<public>:map(rational,string)=map{R(1,2)=>"half",R(1,3)=>"third"}
        \\Found<public>:string=Or(Lookup(Prices,R(2,4)),"none")
        \\Count<public>:i64=Cell
    );
    try sweep(h, "strings",
        \\Substring:=native{"std.substring"}
        \\Upper:=native{"std.upper"}
        \\Trim:=native{"std.trim"}
        \\Split:=native{"std.split"}
        \\Join:=native{"std.join"}
        \\Name:string="雪"
        \\Wrap(S:string)<computes>:string="("+S+")"
        \\Greeting<public>:string="hello, "+Name+"!"
        \\Size<public>:i64=Greeting.Length
        \\Report<public>:string="count="+ToString(42)+" ratio="+ToString(2.5)+" on="+ToString(true)
        \\Loud<public>:string=Upper(Trim("  ok  "))
        \\Part<public>:string=Or(Substring(Greeting,7,3),"?")
        \\Cut<public>:string=Or(Substring(Greeting,8,1),"?")
        \\Words<public>:[]string=Split("a,b,,c",",")
        \\Back<public>:string=Join(Words,"+")
        \\Chain<public>:string=Iterate(Wrap,2,"a")
    );
    try sweep(h, "native-std",
        \\Sum:=native{"std.sum"}
        \\Sorted:=native{"std.sorted"}
        \\Max:=native{"std.max"}
        \\Find:=native{"std.find"}
        \\Dot:=native{"std.dot"}
        \\Sqrt:=native{"std.sqrt"}
        \\Range:=native{"std.range"}
        \\Items:[]i64=array{9,3,7,3}
        \\Score(Values:[]i64,Bias:i64)<computes>:i64=Sum(Values)+Bias
        \\Total<public>:i64=Sum(Items)
        \\Ordered<public>:[]i64=Sorted(Items)
        \\Biggest<public>:i64=Or(Max(Items),-1)
        \\Where<public>:i64=Or(Find(Items,7),-1)
        \\Missing<public>:i64=Or(Find(Items,5),-1)
        \\Norm<public>:float=Sqrt(Dot(array{3.0,4.0},array{3.0,4.0}))
        \\Count<public>:i64=Sum(Range(5))
        \\Scored<public>:i64=Score(Items,100)
    );
    try sweep(h, "map-updates",
        \\var Scores:map(string,i64)=map{"a"=>1,"b"=>2}
        \\Maybe:option(i64)=option{7}
        \\Nothing:option(i64)=option{}
        \\Look(K:string)<transacts>:i64=Attempt(Scores[K],-1)
        \\Bump(K:string)<transacts><decides>:i64=Block{set Scores[K]+=10;Scores[K]}
        \\A<public>:i64=Look("a")
        \\B<public>:i64=Look("zz")
        \\C<public>:i64=Attempt(Maybe?,-5)
        \\D<public>:i64=Attempt(Nothing?,-5)
        \\set Scores["c"]=30
        \\E<public>:i64=Attempt(Bump["a"],-1)
        \\F<public>:i64=Attempt(Bump["q"],-1)
        \\G<public>:map(string,i64)=Scores
    );
}

test "replay: every recorded value of real reports with tasks and reactions, changed in turn, is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    try sweep(h, "live-reactions",
        \\var Health:i64 = 100
        \\var IsDead:logic = false
        \\var Hits:i64 = 0
        \\var Log:i64 = 0
        \\Dead:task(logic) = Upon(Health <= 0, Set(IsDead, true))
        \\Counter:task(void) = When(Health, Set(Hits, Hits + 1))
        \\set Health = 50
        \\Alive:logic = IsDead
        \\set Health = 0
        \\Fell:logic = IsDead
        \\var A:i64 = 0
        \\First:task(void) = When(A > 0, Set(Log, Log * 10 + 1))
        \\Second:task(void) = When(A > 0, Set(Log, Log * 10 + 2))
        \\set A = 1
        \\Ordered:i64 = Log
        \\Tried:logic = Attempt(Block{ set A = 2; Require[A < 0]; true }, false)
        \\Kept:logic = Attempt(Block{ set A = 3; true }, false)
        \\AfterRegions:i64 = Log
        \\Bump()<transacts>:i64 = Block{ set A = 4; Log }
        \\Bumped:i64 = Bump()
        \\var Made:i64 = 0
        \\Never:logic = Attempt(Block{ U:task(i64) = Upon(true, Set(Made, 1)); Require[Made < 0]; true }, false)
        \\NotMade:i64 = Made
        \\Total:i64 = Hits
    );
    try sweep(h, "await",
        \\var X:i64 = 0
        \\Waiter()<transacts><suspends>:i64 = Block{ V := Await(Block{ Require[X > 1]; X * 2 }); V + 1 }
        \\Writer()<transacts><suspends>:void = Block{ Sleep(0.0); set X = 1; Sleep(0.5); set X = 2; X }
        \\W:task(i64) = Spawn{ Waiter() }
        \\K:task(void) = Spawn{ Writer() }
        \\var live D:i64 = X * 3 + 1
    );
    // RFC-0082, P3.9: subscriptions whose callbacks compute, a cancelled one, and a sticky event.
    try sweep(h, "subscriptions",
        \\var Total:i64 = 0
        \\Add(N:i64)<transacts>:void = Set(Total, Total + N * 2)
        \\Show(N:i64)<transacts>:void = Print("ui {N + 1}")
        \\ScoreEvent:subscribable_event(i64) = subscribable_event(i64){}
        \\Adder:cancelable = ScoreEvent.Subscribe(Add)
        \\Shower:cancelable = ScoreEvent.Subscribe(Show)
        \\First:void = ScoreEvent.Signal(10)
        \\Off:void = Adder.Cancel()
        \\Second:void = ScoreEvent.Signal(20)
        \\Ready:sticky_event(i64) = sticky_event(i64){}
        \\Run()<transacts><suspends>:i64 = Block{ Ready.Signal(Total + 3); V := Ready.Await(); V * 4 }
        \\T:task(i64) = Spawn{ Run() }
    );
    try sweep(h, "concurrency-spawn",
        \\var Log:[]string = array{}
        \\Note(S:string)<transacts>:void = Set(Log, Log + array{S})
        \\Fetch(N:i64)<transacts><suspends>:i64 = Block{ Sleep(0.1); Note("fetched {N}"); N * 10 }
        \\Main()<transacts><suspends>:void = Block{
        \\    Note("main")
        \\    W := Spawn{ Fetch(1) }
        \\    X := Fetch(2)
        \\    Note("got {X}")
        \\    Sleep(2.5)
        \\    Note("done")
        \\}
        \\Started:task(void) = Spawn{ Main() }
    );
}

// The independent review's cases (`rpl_review.md`, D1 and D2), kept as regressions. A native
// that touches a few elements of a large array costs the replay a few units, not the array;
// the default report budget admits these runs at the bootstrap profile's fuel.
fn costCheck(source: []const u8) !void {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(source);
    const budget = types.limits.evaluation_work;
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const actual = h.runtime.evaluate(p, budget);
    try std.testing.expect(reference == .ok and actual == .ok);
    _ = try reporting.validate(reference.ok, false, .{});
    _ = try reporting.validate(actual.ok, false, .{});
}

/// A digest run that reclaims, at several reclaim floors and windows: its report is admitted.
/// The checks of root nodes that read the bytes of strings wait for the second run (R6).
fn staleCheck(name: []const u8, source: []const u8) !u32 {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const p = try f.h.compile(source);
    var refused: u32 = 0;
    for ([_]u32{ 0, 1, 5, 40 }) |floor| for ([_]u32{ 1, 2, 3, 64, types.ControlStorage.default_trace_window }) |window| {
        f.mode(.digest, window);
        f.h.control.reclaim_floor = floor;
        f.h.runtime.machine.control.reclaim_floor = floor;
        f.again.control.trace_window = window;
        f.again.control.reclaim_floor = floor;
        const actual = f.h.runtime.evaluate(p, fuel);
        try std.testing.expect(actual == .ok);
        if (reporting.validateReplayed(actual.ok, f.again.producer(p, fuel), false, limits)) |_| {} else |err| {
            refused += 1;
            std.debug.print("{s}: floor {d} window {d} reclaims {d}: {t}\n", .{ name, floor, window, actual.ok.reclaims, err });
        }
    };
    return refused;
}

test "replay: a native costs the replay what it costs the run: root Slice of a large array, twenty times" {
    try @import("profile.zig").requireBootstrap();
    try costCheck(
        \\Range:=native{"std.range"}
        \\Big:[]i64 = Range(4000)
        \\None:[]i64 = array{}
        \\A1:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A2:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A3:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A4:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A5:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A6:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A7:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A8:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A9:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A10:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A11:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A12:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A13:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A14:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A15:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A16:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A17:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A18:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A19:[]i64 = Attempt(Big.Slice[0,1], None)
        \\A20:[]i64 = Attempt(Big.Slice[0,1], None)
    );
}

test "replay: a native costs the replay what it costs the run: Slice of a large array in a loop" {
    try @import("profile.zig").requireBootstrap();
    try costCheck(
        \\Range:=native{"std.range"}
        \\Big:[]i64 = Range(4000)
        \\Step(S:i64)<computes>:i64 = S + Attempt(Big.Slice[S, S+1], array{0}).Length
        \\Total:i64 = Iterate(Step, 40, 0)
    );
}

test "replay, digest run that reclaims: root map_set with a string key built after a reclaiming call" {
    const n = try staleCheck("map_set",
        \\var C:i64 = 0
        \\var M:map(string,i64) = map{"12"=>1}
        \\Noise(N:i64)<transacts>:i64 = Block{ set C = C + 1; T := ToString(N) + "abcdefgh"; U := T + T; U.Length }
        \\A:i64 = Noise(1)
        \\K:string = ToString(12)
        \\set M[K] = 5
        \\L:i64 = M.Length
    );
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "replay, digest run that reclaims: root map literal with string keys built after a reclaiming call" {
    const n = try staleCheck("map_literal",
        \\var C:i64 = 0
        \\Noise(N:i64)<transacts>:i64 = Block{ set C = C + 1; T := "aaaaaaaaaaaa" + ToString(N); U := T + T; U.Length }
        \\A:i64 = Noise(1)
        \\K1:string = ToString(1)
        \\K2:string = ToString(2)
        \\M:map(string,i64) = map{K1=>1, K2=>2}
        \\L:i64 = M.Length
    );
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "replay, digest run that reclaims: root pure string checks after a reclaiming call" {
    const n = try staleCheck("pure",
        \\var C:i64 = 0
        \\Noise(N:i64)<transacts>:i64 = Block{ set C = C + 1; T := ToString(N) + "abcdefgh"; U := T + T; U.Length }
        \\A:i64 = Noise(1)
        \\K:string = ToString(12)
        \\J:string = K + "x"
        \\E:logic = J == "12x"
        \\B:i64 = Noise(2)
    );
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "replay, digest run that reclaims: root failure reason built after a reclaiming call" {
    const n = try staleCheck("reason",
        \\var C:i64 = 0
        \\Noise(N:i64)<transacts>:i64 = Block{ set C = C + 1; T := ToString(N) + "abcdefgh"; U := T + T; U.Length }
        \\A:i64 = Noise(1)
        \\R:string = ToString(12) + "why"
        \\X:i64 = Attempt(Block{ Fail[R]; 1 }, 2)
        \\B:i64 = Noise(2)
    );
    try std.testing.expectEqual(@as(u32, 0), n);
}
