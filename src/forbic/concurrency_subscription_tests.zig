//! Structured concurrency, P3.9 (RFC-0082): `sticky_event(t)`, `subscribable_event(t)` and
//! `cancelable`, with subscriptions and cancellations that a failed transaction takes back, in
//! both machines and the report replay.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const concurrency = @import("concurrency_tests.zig");

const expectRun = concurrency.expectRun;
const printed = concurrency.printed;

fn expectPrinted(h: *harness.Harness, source: []const u8, expected: []const u8) !evaluator.Execution {
    const x = try expectRun(h, source);
    var buffer: [8192]u8 = undefined;
    const got = printed(x, &buffer);
    if (!std.mem.eql(u8, expected, got)) std.debug.print("program:\n{s}\n", .{source});
    try std.testing.expectEqualStrings(expected, got);
    return x;
}

fn expectReport(execution: evaluator.Execution, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.write(&out, execution, false, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("expected the diagnostic {t}: {s}\n", .{ code, source });
        return error.TestUnexpectedResult;
    }
    if (result.failed.code != code) std.debug.print("got {t} at {d} for {s}\n", .{ result.failed.code, result.failed.span.start, source });
    try std.testing.expectEqual(code, result.failed.code);
    if (!std.mem.eql(u8, at, source[result.failed.span.start..result.failed.span.end])) std.debug.print("placed at {s} in {s}\n", .{ source[result.failed.span.start..result.failed.span.end], source });
    try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
}

test "the Book's 14:1549: a sticky event remembers its last value for every later Await" {
    const h = try harness.create();
    defer scratch.release(h);
    // The Book awaits at the top level, which cannot suspend here (RFC-0078): the same lines
    // in a task.
    _ = try expectPrinted(h,
        \\StateEvent:sticky_event(i64) = sticky_event(i64){}
        \\Run()<transacts><suspends>:void = Block{
        \\    StateEvent.Signal(100)
        \\    Value1 := StateEvent.Await()
        \\    Value2 := StateEvent.Await()
        \\    Value3 := StateEvent.Await()
        \\    StateEvent.Signal(200)
        \\    Value4 := StateEvent.Await()
        \\    Value5 := StateEvent.Await()
        \\    Print("{Value1} {Value2} {Value3} {Value4} {Value5}")
        \\}
        \\T:task(void) = Spawn{ Run() }
    , "100 100 100 200 200\n");
}

test "a sticky event: an Await before the first Signal waits for it, and none after it waits" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Ready:sticky_event(string) = sticky_event(string){}
        \\Early(N:i64)<transacts><suspends>:void = Block{ Print("early {N}"); V := Ready.Await(); Print("early {N} saw {V}") }
        \\Late()<transacts><suspends>:void = Block{ Sleep(1.0); V := Ready.Await(); Print("late saw {V}") }
        \\Main()<transacts><suspends>:void = Block{
        \\    A := Spawn{ Early(1) }
        \\    B := Spawn{ Early(2) }
        \\    C := Spawn{ Late() }
        \\    Ready.Signal("go")
        \\    Print("signalled")
        \\    V := Ready.Await()
        \\    Print("main saw {V}")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "early 1\nearly 2\nsignalled\nmain saw go\nearly 1 saw go\nearly 2 saw go\nlate saw go\n");
    // Main's own Await did not suspend: its value came at once (C105).
    try std.testing.expectEqual(@as(u64, 60), x.scheduler.tick);
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

test "a sticky event's Signal in a region is held, latch and all, and dropped when the region fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Flag:sticky_event(i64) = sticky_event(i64){}
        \\Say(N:i64, Keep:logic)<transacts><decides>:i64 = Block{ Flag.Signal(N); Require[Keep]; N }
        \\Watch()<transacts><suspends>:void = Block{ V := Flag.Await(); Print("saw {V}") }
        \\W:task(void) = Spawn{ Watch() }
        \\Dropped:i64 = Attempt(Say[1, false], 0)
        \\Kept:i64 = Attempt(Say[2, true], 0)
        \\Again:i64 = Attempt(Say[3, false], 0)
        \\Check()<transacts><suspends>:void = Block{ V := Flag.Await(); Print("check {V}") }
        \\C:task(void) = Spawn{ Check() }
    , "check 2\nsaw 2\n");
    try std.testing.expectEqual(@as(usize, 0), x.scheduler.waiting.len);
}

test "a sticky event is an awaitable and a signalable; a subscribable one is only an awaitable" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\S:sticky_event(i64) = sticky_event(i64){}
        \\Reader:awaitable(i64) = S
        \\Writer:signalable(i64) = S
        \\Run()<transacts><suspends>:void = Block{ Writer.Signal(5); V := Reader.Await(); W := Reader.Await(); Print("{V} {W}") }
        \\T:task(void) = Spawn{ Run() }
    , "5 5\n");
    _ = try expectPrinted(h,
        \\E:subscribable_event(i64) = subscribable_event(i64){}
        \\Reader:awaitable(i64) = E
        \\Wait()<transacts><suspends>:void = Block{ V := Reader.Await(); Print("woke {V}") }
        \\Hear(N:i64)<transacts>:void = Print("heard {N}")
        \\H:cancelable = E.Subscribe(Hear)
        \\T:task(void) = Spawn{ Wait() }
        \\Go:void = E.Signal(9)
    , "heard 9\nwoke 9\n");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nWriter:signalable(i64) = E", .type_mismatch, "subscribable_event");
}

test "the Book's 14:1598: Signal calls every subscription, and a cancelled one no longer" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\LogScore(N:i64)<transacts>:void = Print("log {N}")
        \\UpdateUI(N:i64)<transacts>:void = Print("ui {N}")
        \\CheckAchievements(N:i64)<transacts>:void = Print("achievements {N}")
        \\ScoreEvent:subscribable_event(i64) = subscribable_event(i64){}
        \\Logger:cancelable = ScoreEvent.Subscribe(LogScore)
        \\UIUpdater:cancelable = ScoreEvent.Subscribe(UpdateUI)
        \\AchievementChecker:cancelable = ScoreEvent.Subscribe(CheckAchievements)
        \\First:void = ScoreEvent.Signal(1000)
        \\Off:void = Logger.Cancel()
        \\Second:void = ScoreEvent.Signal(2000)
    , "log 1000\nui 1000\nachievements 1000\nui 2000\nachievements 2000\n");
    try expectReport(x, "{\"ScoreEvent\":{\"$event\":{\"waiting\":0}},\"Logger\":{\"$cancelable\":{\"canceled\":true}},\"UIUpdater\":{\"$cancelable\":{\"canceled\":false}},\"AchievementChecker\":{\"$cancelable\":{\"canceled\":false}},\"First\":[],\"Off\":[],\"Second\":[]}\n");
}

test "the Book's 14:1704: a Subscribe or a Cancel in a failed transaction never takes effect" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Handler(N:i64)<transacts>:void = Print("handler {N}")
        \\MyEvent:subscribable_event(i64) = subscribable_event(i64){}
        \\Undone:i64 = Attempt(Block{ Sub := MyEvent.Subscribe(Handler); Require[false]; 1 }, 0)
        \\One:void = MyEvent.Signal(100)
        \\Live:cancelable = MyEvent.Subscribe(Handler)
        \\Kept:i64 = Attempt(Block{ Live.Cancel(); Require[false]; 1 }, 0)
        \\Two:void = MyEvent.Signal(200)
    , "handler 200\n");
}

test "a subscription rolled back in a function, and one that a region keeps, in a task" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\E:subscribable_event(string) = subscribable_event(string){}
        \\A(S:string)<transacts>:void = Print("a {S}")
        \\B(S:string)<transacts>:void = Print("b {S}")
        \\Try(Keep:logic)<transacts><decides>:cancelable = Block{ C := E.Subscribe(B); Require[Keep]; C }
        \\Run()<transacts><suspends>:void = Block{
        \\    X := E.Subscribe(A)
        \\    Lost := Attempt(Block{ C := Try[false]; 1 }, 0)
        \\    E.Signal("one")
        \\    Kept := Attempt(Block{ C := Try[true]; 1 }, 0)
        \\    Sleep(0.5)
        \\    E.Signal("two")
        \\    Gone := Attempt(Block{ X.Cancel(); E.Signal("three"); Require[false]; 1 }, 0)
        \\    E.Signal("four")
        \\}
        \\T:task(void) = Spawn{ Run() }
    , "a one\na two\nb two\na four\nb four\n");
}

test "a subscription cancelled during a Signal: later ones and the callback's own, and one made then" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Ev:subscribable_event(i64) = subscribable_event(i64){}
        \\var Hs:[]cancelable = array{}
        \\Fourth(N:i64)<transacts>:void = Print("fourth {N}")
        \\Stop(I:i64)<transacts>:void = Block{ X := Attempt(Block{ C := Hs[I]; C.Cancel(); 1 }, 0); void(X) }
        \\First(N:i64)<transacts>:void = Block{
        \\    Print("first {N}")
        \\    Stop(1)
        \\    Stop(0)
        \\    Set(Hs, Hs + array{Ev.Subscribe(Fourth)})
        \\}
        \\Second(N:i64)<transacts>:void = Print("second {N}")
        \\Third(N:i64)<transacts>:void = Print("third {N}")
        \\Run()<transacts>:i64 = Block{
        \\    set Hs = array{Ev.Subscribe(First), Ev.Subscribe(Second), Ev.Subscribe(Third)}
        \\    Ev.Signal(1)
        \\    Ev.Signal(2)
        \\    Hs.Length
        \\}
        \\R:i64 = Run()
    , "first 1\nthird 1\nthird 2\nfourth 2\n");
    try std.testing.expectEqual(@as(i64, 4), x.get("R").?.integer);
}

test "callbacks run at once, before Signal returns: they may spawn, signal, and signal their own event again" {
    const h = try harness.create();
    defer scratch.release(h);
    _ = try expectPrinted(h,
        \\Ev:subscribable_event(i64) = subscribable_event(i64){}
        \\Bell:event(i64) = event(i64){}
        \\Worker(N:i64)<transacts><suspends>:void = Block{ Print("worker {N} starts"); Sleep(1.0); Print("worker {N} ends") }
        \\Listen()<transacts><suspends>:void = Block{ V := Bell.Await(); Print("bell {V}") }
        \\Again(N:i64)<transacts>:void = Block{ Print("again {N}"); If(N > 1, Ev.Signal(N - 1), void(N)) }
        \\Start(N:i64)<transacts>:void = Block{ T := Spawn{ Worker(N) }; Bell.Signal(N); Print("started {N}") }
        \\Main()<transacts><suspends>:void = Block{
        \\    L := Spawn{ Listen() }
        \\    A := Ev.Subscribe(Again)
        \\    B := Ev.Subscribe(Start)
        \\    Ev.Signal(3)
        \\    Print("signal returned")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "again 3\nagain 2\nagain 1\nworker 1 starts\nstarted 1\nworker 2 starts\nstarted 2\nworker 3 starts\nstarted 3\nsignal returned\nbell 1\nworker 1 ends\nworker 2 ends\nworker 3 ends\n");
}

test "a subscribable event wakes its waiters as an event does, and its subscriptions run first" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectPrinted(h,
        \\Ev:subscribable_event(string) = subscribable_event(string){}
        \\Hear(S:string)<transacts>:void = Print("heard {S}")
        \\Wait()<transacts><suspends>:void = Block{ V := Ev.Await(); Print("woke {V}") }
        \\Main()<transacts><suspends>:void = Block{
        \\    W := Spawn{ Wait() }
        \\    H := Ev.Subscribe(Hear)
        \\    Ev.Signal("x")
        \\    Print("main")
        \\    Ev.Signal("lost to waiters")
        \\}
        \\M:task(void) = Spawn{ Main() }
    , "heard x\nmain\nheard lost to waiters\nwoke x\n");
    try std.testing.expectEqual(@as(u64, 2), x.scheduler.completed);
}

test "every compile-time refusal of P3.9 is positioned" {
    const h = try harness.create();
    defer scratch.release(h);
    // A subscribable event's Signal calls `<transacts>` code; a Subscribe writes and builds.
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nS(N:i64)<writes>:void = E.Signal(N)", .call_requires_reads_allocates, "Signal");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts>:void = void(N)\nS()<writes>:cancelable = E.Subscribe(F)", .call_requires_allocates, "Subscribe");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts>:void = void(N)\nS()<reads>:void = Block{ C := E.Subscribe(F); C.Cancel() }", .call_requires_writes_allocates, "Subscribe");
    // A sticky event's Signal writes, as an event's does.
    try expectRefused(h, "S:sticky_event(i64) = sticky_event(i64){}\nF()<reads>:void = S.Signal(1)", .call_requires_writes, "Signal");
    try expectRefused(h, "S:sticky_event(i64) = sticky_event(i64){}\nF()<transacts>:i64 = S.Await()", .call_requires_suspends, "Await");
    // A callback that suspends, fails, takes another type or returns a value is no callback.
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts><suspends>:void = Sleep(1.0)\nC:cancelable = E.Subscribe(F)", .type_mismatch, "F");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts><decides>:void = Require[N > 0]\nC:cancelable = E.Subscribe(F)", .type_mismatch, "F");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(S:string)<transacts>:void = void(S)\nC:cancelable = E.Subscribe(F)", .type_mismatch, "F");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts>:i64 = N\nC:cancelable = E.Subscribe(F)", .type_mismatch, "F");
    // Nothing goes between the braces, and the types are no functions.
    try expectRefused(h, "S:sticky_event(i64) = sticky_event(i64){1}", .unexpected_token, "1");
    try expectRefused(h, "X:i64 = cancelable(1)", .unknown_name, "cancelable");
    // A plain event has no Subscribe, a subscription no Await, and a sticky event no Subscribe.
    try expectRefused(h, "E:event(i64) = event(i64){}\nF(N:i64)<transacts>:void = void(N)\nC:cancelable = E.Subscribe(F)", .unknown_field, "Subscribe");
    try expectRefused(h, "S:sticky_event(i64) = sticky_event(i64){}\nF(N:i64)<transacts>:void = void(N)\nC:cancelable = S.Subscribe(F)", .unknown_field, "Subscribe");
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts>:void = void(N)\nC:cancelable = E.Subscribe(F)\nG()<transacts><suspends>:void = C.Await()", .unknown_field, "Await");
    // A cancelable has no fields, no equality and no cast to `any`.
    try expectRefused(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nF(N:i64)<transacts>:void = void(N)\nC:cancelable = E.Subscribe(F)\nB:logic = C == C", .not_comparable, "==");
}

test "the names of P3.9 yield to whatever the program declares by them" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type of the program's own named `cancelable`, and a method `Subscribe` of an event's
    // extension, are what the names mean.
    _ = try expectPrinted(h,
        \\cancelable := class{ N:i64 }
        \\C:cancelable = cancelable{ N := 3 }
        \\Show:void = Print("{C.N}")
    , "3\n");
    _ = try expectPrinted(h,
        \\(E:subscribable_event(i64)).Subscribe(N:i64)<transacts>:i64 = N + 1
        \\E:subscribable_event(i64) = subscribable_event(i64){}
        \\X:i64 = E.Subscribe(4)
        \\Show:void = Print("{X}")
    , "5\n");
    _ = try expectPrinted(h,
        \\sticky_event(N:i64)<computes>:i64 = N * 2
        \\X:i64 = sticky_event(21)
        \\Show:void = Print("{X}")
    , "42\n");
}

test "a program without the new events keeps its catalogue and IR" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("E:event(i64) = event(i64){}\nF()<transacts>:void = E.Signal(1)\nX:void = F()");
    for (p.definitions) |item| try std.testing.expect(item != .cancelable and (item != .event or item.event.kind == .plain));
    for (p.function_nodes) |entry| try std.testing.expect(entry.input != .operation or (entry.node.kind != .event_notify and entry.node.kind != .event_subscribe and entry.node.kind != .subscription_cancel));
}

/// A copy of `p` whose function bodies and metadata are the harness's, to forge.
fn forgeable(h: *harness.Harness, p: types.Program) types.Program {
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    @memcpy(h.metadata[0..p.functions.len], p.functions);
    var forged = p;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    forged.functions = h.metadata[0..p.functions.len];
    return forged;
}

/// The function of `p` named `name`.
fn named(p: types.Program, name: []const u8) usize {
    for (p.functions, 0..) |f, id| if (!f.anonymous and std.mem.eql(u8, f.name.text(p.source), name)) return id;
    unreachable;
}

/// The first node of `kind` in the body of function `id`, counted from its start.
fn first(p: types.Program, id: usize, kind: std.meta.Tag(@FieldType(types.Node, "kind"))) u32 {
    const f = p.functions[id];
    for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, at| if (entry.input == .operation and entry.node.kind == kind) return @intCast(at);
    unreachable;
}

/// The root node bound to `name`.
fn binding(p: types.Program, name: []const u8) u32 {
    for (p.bindings) |b| if (std.mem.eql(u8, b.name.text(p.source), name)) return b.node;
    unreachable;
}

/// Refused by both machines, and by the replay, which admits a run of it again.
fn refusedEverywhere(h: *harness.Harness, forged: types.Program, run: evaluator.Execution) !void {
    try harness.invalid(h, forged);
    var replayed = run;
    replayed.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(replayed, false, .{}));
}

const forged_source =
    \\Plain:event(i64) = event(i64){}
    \\Sticky:sticky_event(i64) = sticky_event(i64){}
    \\Subs:subscribable_event(i64) = subscribable_event(i64){}
    \\Other:subscribable_event(string) = subscribable_event(string){}
    \\Hear(N:i64)<transacts>:void = Print("{N}")
    \\Text(S:string)<transacts>:void = Print(S)
    \\Seven:i64 = 7
    \\Word:string = "w"
    \\HearValue:function<transacts>(tuple(i64), void) = Hear
    \\TextValue:function<transacts>(tuple(string), void) = Text
    \\Root:cancelable = Subs.Subscribe(Hear)
    \\Use()<transacts>:void = Block{
    \\    C := Subs.Subscribe(Hear)
    \\    D := Other.Subscribe(Text)
    \\    Subs.Signal(1)
    \\    C.Cancel()
    \\    Sticky.Signal(2)
    \\}
    \\Writes()<writes>:void = Sticky.Signal(3)
    \\U:void = Use()
    \\Go:void = Subs.Signal(4)
;

test "forged subscriptions, cancellations and calls of a Signal are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(forged_source);
    const run = try expectRun(h, forged_source);
    var forged = forgeable(h, p);
    // The root's own nodes, forged in a copy.
    // On the heap: a capacity-sized copy would not fit the native stack at the program profile.
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    forged.nodes = nodes;
    const root = binding(p, "Root");
    std.debug.assert(p.nodes[root].kind == .event_subscribe);
    const original_root = p.nodes[root];
    const restoreRoot = struct {
        fn f(n: []types.Node, at: u32, node: types.Node) void {
            n[at] = node;
        }
    }.f;
    // A subscription of an event of another kind, or of a value that is no event; a callback of
    // another type, or no callback; a subscription typed as anything but `cancelable`.
    for ([_][]const u8{ "Plain", "Sticky", "Seven", "Other" }) |name| {
        nodes[root].kind.event_subscribe.event = binding(p, name);
        try refusedEverywhere(h, forged, run);
        restoreRoot(nodes, root, original_root);
    }
    for ([_][]const u8{ "TextValue", "Seven", "Word" }) |name| {
        nodes[root].kind.event_subscribe.callback = binding(p, name);
        try refusedEverywhere(h, forged, run);
        restoreRoot(nodes, root, original_root);
    }
    nodes[root].value_type = p.nodes[binding(p, "Seven")].value_type;
    try refusedEverywhere(h, forged, run);
    restoreRoot(nodes, root, original_root);
    // An operand that is not before the node.
    nodes[root].kind.event_subscribe.event = root;
    try refusedEverywhere(h, forged, run);
    restoreRoot(nodes, root, original_root);
    // The root's `Signal`: its calls of another kind of event, with another value, or with two.
    const go = binding(p, "Go");
    std.debug.assert(p.nodes[go].kind == .event_notify);
    const original_go = p.nodes[go];
    for ([_][]const u8{ "Plain", "Sticky", "Other", "Seven" }) |name| {
        nodes[go].kind.event_notify.callable = binding(p, name);
        try refusedEverywhere(h, forged, run);
        restoreRoot(nodes, go, original_go);
    }
    nodes[go].kind.event_notify.arguments.end += 1;
    try refusedEverywhere(h, forged, run);
    restoreRoot(nodes, go, original_go);
    nodes[go].kind.event_notify.arguments.start += 1;
    nodes[go].kind.event_notify.arguments.end += 1;
    try refusedEverywhere(h, forged, run);
    restoreRoot(nodes, go, original_go);
    // In a function: each operation where its function may not do what it does; a Cancel of what
    // is no subscription; the metadata without what the operations make it.
    const use = named(p, "Use");
    const base = p.functions[use].body.start;
    const subscribe = base + first(p, use, .event_subscribe);
    const cancel = base + first(p, use, .subscription_cancel);
    const notify = base + first(p, use, .event_notify);
    for ([_]types.EffectDetail{ types.heapDetail(true, false, true), types.heapDetail(true, true, false), types.heapDetail(false, true, true) }) |detail| {
        h.metadata[use].detail = detail;
        try refusedEverywhere(h, forged, run);
        h.metadata[use] = p.functions[use];
    }
    h.body[cancel].node.kind.subscription_cancel = h.body[notify].node.kind.event_notify.callable;
    try refusedEverywhere(h, forged, run);
    h.body[cancel] = p.function_nodes[cancel];
    h.body[cancel].node.kind.subscription_cancel = @intCast(cancel - base);
    try refusedEverywhere(h, forged, run);
    h.body[cancel] = p.function_nodes[cancel];
    h.body[subscribe].node.kind.event_subscribe.callback = h.body[subscribe].node.kind.event_subscribe.event;
    try refusedEverywhere(h, forged, run);
    h.body[subscribe] = p.function_nodes[subscribe];
    h.body[notify].node.value_type = .i64;
    try refusedEverywhere(h, forged, run);
    h.body[notify] = p.function_nodes[notify];
    h.metadata[use].has_local = false;
    try refusedEverywhere(h, forged, run);
    h.metadata[use] = p.functions[use];
    h.metadata[use].has_failure = false;
    try refusedEverywhere(h, forged, run);
    h.metadata[use] = p.functions[use];
    h.metadata[use].has_source = false;
    try refusedEverywhere(h, forged, run);
    h.metadata[use] = p.functions[use];
    h.metadata[use].source_ops -= 1;
    try refusedEverywhere(h, forged, run);
    h.metadata[use] = p.functions[use];
    h.metadata[use].control_ops -= 1;
    try refusedEverywhere(h, forged, run);
    h.metadata[use] = p.functions[use];
    // A sticky Signal turned into calls in a function that may only write.
    const writes = named(p, "Writes");
    const signal = p.functions[writes].body.start + first(p, writes, .event_signal);
    const value = h.body[signal].node.kind.event_signal.value;
    const event = h.body[signal].node.kind.event_signal.event;
    h.body[signal].node.kind = .{ .event_notify = .{ .callable = event, .arguments = .{ .start = 0, .end = 1 } } };
    _ = value;
    try harness.invalid(h, forged);
    h.body[signal] = p.function_nodes[signal];
    // A catalogue whose `cancelable` comes twice. (An event kind out of range cannot be built:
    // `EventKind` is an exhaustive enum.)
    const definitions = try std.testing.allocator.alloc(types.Definition, p.definitions.len + 1);
    defer std.testing.allocator.free(definitions);
    @memcpy(definitions[0..p.definitions.len], p.definitions);
    definitions[p.definitions.len] = .cancelable;
    forged.definitions = definitions;
    try refusedEverywhere(h, forged, run);
    forged.definitions = p.definitions;
    // The forged copies are the program again: it runs.
    _ = try h.run(forged, concurrency.fuel);
}

test "a forged schedule of subscriptions is refused by the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try expectRun(h,
        \\Ev:subscribable_event(i64) = subscribable_event(i64){}
        \\S:sticky_event(i64) = sticky_event(i64){}
        \\var Hs:[]cancelable = array{}
        \\A(N:i64)<transacts>:void = Print("a {N}")
        \\B(N:i64)<transacts>:void = Block{ X := Attempt(Block{ C := Hs[0]; C.Cancel(); 1 }, 0); Print("b {N}") }
        \\Run()<transacts><suspends>:i64 = Block{
        \\    set Hs = array{Ev.Subscribe(A), Ev.Subscribe(B), Ev.Subscribe(A)}
        \\    Ev.Signal(1)
        \\    Ev.Signal(2)
        \\    S.Signal(5)
        \\    S.Await()
        \\}
        \\T:task(i64) = Spawn{ Run() }
    );
    _ = try reporting.validate(x, false, .{});
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a 1\nb 1\na 1\nb 2\na 2\n", printed(x, &buffer));
    const steps = x.call_steps;
    const Forgery = enum { callback_dropped, notify_value, sticky_value, sticky_waits, subscription_state, callback_swapped };
    var cells: [512]@import("source_state.zig").Cell = undefined;
    for (std.enums.values(Forgery)) |forgery| {
        @memcpy(h.steps[0..steps.len], steps);
        var forged = x;
        forged.call_steps = h.steps[0..steps.len];
        var count = steps.len;
        var done = false;
        var index: usize = 0;
        while (index < count and !done) : (index += 1) {
            const step = &h.steps[index];
            const f = x.program.functions[step.function];
            const node: std.meta.Tag(@FieldType(types.Node, "kind")) = if (step.function < x.program.functions.len and step.pc < f.body.end - f.body.start) std.meta.activeTag(x.program.function_nodes[f.body.start + step.pc].node.kind) else .canceling;
            const name = f.name.text(x.program.source);
            switch (forgery) {
                // The steps of one callback's frame taken out: the replay calls it all the same.
                .callback_dropped => if (std.mem.eql(u8, name, "A")) {
                    var end = index;
                    while (end < count and h.steps[end].function == step.function) end += 1;
                    std.mem.copyForwards(types.CallStep, h.steps[index .. count - (end - index)], h.steps[end..count]);
                    count -= end - index;
                    forged.call_steps = h.steps[0..count];
                    done = true;
                },
                .notify_value => if (step.kind == .value and node == .event_notify) {
                    step.value = .{ .integer = 0 };
                    done = true;
                },
                .sticky_value => if (step.kind == .value and node == .event_await) {
                    step.value = .{ .integer = 6 };
                    done = true;
                },
                .sticky_waits => if (step.kind == .value and node == .event_await) {
                    step.kind = .@"suspend";
                    step.value = x.get("S").?;
                    done = true;
                },
                // The other A called first: its frame's steps put in the place of B's.
                .callback_swapped => if (std.mem.eql(u8, name, "B")) {
                    var a = index;
                    while (a < count and !std.mem.eql(u8, x.program.functions[h.steps[a].function].name.text(x.program.source), "A")) a += 1;
                    if (a < count) {
                        step.function = h.steps[a].function;
                        done = true;
                    }
                },
                .subscription_state => {
                    @memcpy(cells[0..x.object_cells.len], x.object_cells);
                    forged.object_cells = cells[0..x.object_cells.len];
                    var at: usize = 0;
                    while (at < x.object_cells.len) {
                        const class: types.Type = @fromBackingInt(@as(u16, @intCast(cells[at].value.integer)));
                        if (catalogue.isCancelable(class, x.program.definitions) and cells[at + catalogue.cancelable_state].value.integer == catalogue.cancelable_canceled) {
                            cells[at + catalogue.cancelable_state].value.integer = catalogue.cancelable_active;
                            done = true;
                            break;
                        }
                        at += catalogue.classCells(class, x.program.definitions).?;
                    }
                },
            }
        }
        if (!done) {
            std.debug.print("no step to forge for {t}\n", .{forgery});
            return error.TestUnexpectedResult;
        }
        _ = reporting.validate(forged, false, .{}) catch |err| {
            try std.testing.expectEqual(error.InvalidExecution, err);
            continue;
        };
        std.debug.print("forged schedule admitted: {t}\n", .{forgery});
        return error.TestUnexpectedResult;
    }
}

test "programs with subscriptions need the same fuel on both machines, and every budget stops both at one node" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_][]const u8{
        "Ev:subscribable_event(i64) = subscribable_event(i64){}\nvar Hs:[]cancelable = array{}\nA(N:i64)<transacts>:void = Print(\"a {N}\")\nB(N:i64)<transacts>:void = Block{ X := Attempt(Block{ C := Hs[0]; C.Cancel(); 1 }, 0); Print(\"b {N}\") }\nRun()<transacts>:i64 = Block{ set Hs = array{Ev.Subscribe(A), Ev.Subscribe(B), Ev.Subscribe(A)}; Ev.Signal(1); Ev.Signal(2); Hs.Length }\nR:i64 = Run()\nG:void = Ev.Signal(3)",
        "S:sticky_event(i64) = sticky_event(i64){}\nW()<transacts><suspends>:void = Block{ V := S.Await(); Print(\"w {V}\") }\nMain()<transacts><suspends>:i64 = Block{ T := Spawn{ W() }; K := Attempt(Block{ S.Signal(1); Require[false]; 1 }, 0); Sleep(0.1); S.Signal(2); S.Await() + K }\nM:task(i64) = Spawn{ Main() }",
        "Ev:subscribable_event(i64) = subscribable_event(i64){}\nWork(N:i64)<transacts><suspends>:void = Block{ Sleep(1.0); Print(\"work {N}\") }\nStart(N:i64)<transacts>:void = Block{ T := Spawn{ Work(N) }; If(N > 0, Ev.Signal(N - 1), void(N)) }\nMain()<transacts><suspends>:void = Block{ C := Ev.Subscribe(Start); Ev.Signal(3); C.Cancel(); Ev.Signal(9) }\nM:task(void) = Spawn{ Main() }",
    }) |source| {
        const p = try h.compile(source);
        var budget: u64 = 0;
        while (true) : (budget += 1) {
            const outcome = try h.run(p, budget);
            if (outcome == .ok) break;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, outcome.failed.code);
            try std.testing.expect(budget < 100_000);
        }
        try std.testing.expect(budget > 30);
    }
}

test "subscriptions in a digest run that reclaims report as a stored run, in every window" {
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const source =
        \\Junk(N:i64)<transacts>:i64 = Block{ X:[]i64 = array{N, N, N, N, N, N, N, N}; X.Length }
        \\Many(N:i64)<transacts>:i64 = If(N == 0, 0, Junk(N) + Many(N - 1))
        \\Ev:subscribable_event([]i64) = subscribable_event([]i64){}
        \\Flag:sticky_event([]i64) = sticky_event([]i64){}
        \\var Sum:i64 = 0
        \\var Hs:[]cancelable = array{}
        \\Add(Xs:[]i64)<transacts>:void = Block{ J := Many(3); Set(Sum, Sum + Xs.Length + J) }
        \\Drop(Xs:[]i64)<transacts>:void = Block{ J := Many(2); X := Attempt(Block{ C := Hs[0]; C.Cancel(); 1 }, 0); Set(Sum, Sum + J) }
        \\Wait()<transacts><suspends>:i64 = Block{ J := Many(4); V := Flag.Await(); V.Length + J }
        \\Main()<transacts><suspends>:i64 = Block{
        \\    W := Spawn{ Wait() }
        \\    set Hs = array{Ev.Subscribe(Add), Ev.Subscribe(Drop), Ev.Subscribe(Add)}
        \\    K := Many(6)
        \\    Ev.Signal(array{1, 2, 3})
        \\    Sleep(0.5)
        \\    Flag.Signal(array{K, K})
        \\    Ev.Signal(array{4})
        \\    W.Await() + Sum
        \\}
        \\M:task(i64) = Spawn{ Main() }
        \\C:i64 = Many(14)
    ;
    const p = try f.h.compile(source);
    f.mode(.full, types.ControlStorage.default_trace_window);
    const stored = (try f.h.run(p, concurrency.fuel)).ok;
    var out: std.Io.Writer = .fixed(f.full);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = out.buffered();
    for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
        f.mode(.digest, window);
        f.h.control.reclaim_floor = 16;
        f.h.runtime.machine.control.reclaim_floor = 16;
        f.again.control.reclaim_floor = 16;
        f.again.control.trace_window = window;
        defer {
            f.h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
            f.h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
            f.again.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        }
        const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, concurrency.fuel);
        const actual = f.h.runtime.evaluate(p, concurrency.fuel);
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
        try std.testing.expect(actual.ok.reclaims != 0);
        out = .fixed(f.replayed);
        _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, concurrency.fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        _ = try reporting.validateReplayed(reference.ok, f.again.producer(p, concurrency.fuel), false, .{});
    }
}

/// The oracle of P3.9: a direct model of the subscriptions of one event (C107 to C112). A
/// subscription is called by a `Signal` when it was made before the `Signal` began and is still
/// active at its turn, in the order they were made; a region that fails takes back everything
/// done in it, the lines printed included.
const Model = struct {
    const capacity = 96;
    /// Per subscription, in the order made: its callback, and whether it is active.
    callback: [capacity]u8 = undefined,
    active: [capacity]bool = undefined,
    count: usize = 0,
    /// The handles the program keeps, in order: each names a subscription.
    handles: [capacity]usize = undefined,
    handle_count: usize = 0,
    out: [4096]u8 = undefined,
    out_len: usize = 0,

    fn subscribe(self: *Model, callback: u8) void {
        self.callback[self.count] = callback;
        self.active[self.count] = true;
        self.handles[self.handle_count] = self.count;
        self.count += 1;
        self.handle_count += 1;
    }
    fn cancel(self: *Model, handle: usize) void {
        if (handle < self.handle_count) self.active[self.handles[handle]] = false;
    }
    fn signal(self: *Model, value: u32, actions: []const Action) void {
        const limit = self.count;
        for (0..limit) |at| {
            if (!self.active[at]) continue;
            const callback = self.callback[at];
            switch (actions[callback]) {
                .none => {},
                .cancel => |handle| self.cancel(handle),
                .subscribe => |other| self.subscribe(other),
            }
            const line = std.fmt.bufPrint(self.out[self.out_len..], "s{d} {d}\n", .{ callback, value }) catch unreachable;
            self.out_len += line.len;
        }
    }
};
const Action = union(enum) { none, cancel: usize, subscribe: u8 };
const Op = union(enum) { subscribe: u8, cancel: usize, signal: u32, region: struct { keep: bool, from: usize, to: usize } };

fn modelRun(model: *Model, ops: []const Op, actions: []const Action, from: usize, to: usize) void {
    var at = from;
    while (at < to) : (at += 1) switch (ops[at]) {
        .subscribe => |callback| model.subscribe(callback),
        .cancel => |handle| model.cancel(handle),
        .signal => |value| model.signal(value, actions),
        .region => |r| {
            const saved = model.*;
            modelRun(model, ops, actions, r.from, r.to);
            if (!r.keep) model.* = saved;
            at = r.to - 1;
        },
    };
}

fn writeOps(out: *std.Io.Writer, ops: []const Op, from: usize, to: usize, names: *u32) !void {
    var at = from;
    while (at < to) : (at += 1) switch (ops[at]) {
        .subscribe => |callback| try out.print("Set(Hs, Hs + array{{Ev.Subscribe(S{d})}}); ", .{callback}),
        .cancel => |handle| try out.print("Stop({d}); ", .{handle}),
        .signal => |value| try out.print("Ev.Signal({d}); ", .{value}),
        .region => |r| {
            names.* += 1;
            try out.print("X{d} := Attempt(Block{{ ", .{names.*});
            try writeOps(out, ops, r.from, r.to, names);
            try out.print("Require[{s}]; 1 }}, 0); ", .{if (r.keep) "true" else "false"});
            at = r.to - 1;
        },
    };
}

test "the model and both machines agree on random programs of subscriptions, cancellations, signals and regions" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5139);
    const random = prng.random();
    var source: [16 * 1024]u8 = undefined;
    var compared: usize = 0;
    for (0..60) |_| {
        const callbacks = 2 + random.uintLessThan(u8, 4);
        var actions: [8]Action = undefined;
        for (0..callbacks) |c| actions[c] = switch (random.uintLessThan(u8, 4)) {
            0, 1 => .none,
            2 => .{ .cancel = random.uintLessThan(usize, 6) },
            // Only an earlier callback can be named.
            else => if (c == 0) .none else .{ .subscribe = random.uintLessThan(u8, @intCast(c)) },
        };
        var ops: [64]Op = undefined;
        var count: usize = 0;
        var subscribed: usize = 0;
        while (count < 24) {
            const pick = random.uintLessThan(u8, 10);
            if (pick < 3 and subscribed < 10) {
                ops[count] = .{ .subscribe = random.uintLessThan(u8, callbacks) };
                subscribed += 1;
                count += 1;
            } else if (pick < 5) {
                ops[count] = .{ .cancel = random.uintLessThan(usize, 8) };
                count += 1;
            } else if (pick < 8) {
                ops[count] = .{ .signal = random.uintLessThan(u32, 100) };
                count += 1;
            } else if (count + 4 < ops.len) {
                // A region of the next two or three plain operations.
                const inner = 2 + random.uintLessThan(usize, 2);
                const at = count;
                count += 1;
                for (0..inner) |_| {
                    ops[count] = switch (random.uintLessThan(u8, 3)) {
                        0 => .{ .subscribe = random.uintLessThan(u8, callbacks) },
                        1 => .{ .cancel = random.uintLessThan(usize, 8) },
                        else => .{ .signal = random.uintLessThan(u32, 100) },
                    };
                    count += 1;
                }
                ops[at] = .{ .region = .{ .keep = random.boolean(), .from = at + 1, .to = count } };
            }
        }
        var model: Model = .{};
        modelRun(&model, ops[0..count], actions[0..callbacks], 0, count);
        var out: std.Io.Writer = .fixed(&source);
        try out.writeAll("Ev:subscribable_event(i64) = subscribable_event(i64){}\nvar Hs:[]cancelable = array{}\nStop(I:i64)<transacts>:void = Block{ Y := Attempt(Block{ C := Hs[I]; C.Cancel(); 1 }, 0); void(Y) }\n");
        for (0..callbacks) |c| {
            try out.print("S{d}(N:i64)<transacts>:void = Block{{ ", .{c});
            switch (actions[c]) {
                .none => {},
                .cancel => |handle| try out.print("Stop({d}); ", .{handle}),
                .subscribe => |other| try out.print("Set(Hs, Hs + array{{Ev.Subscribe(S{d})}}); ", .{other}),
            }
            try out.print("Print(\"s{d} {{N}}\") }}\n", .{c});
        }
        try out.writeAll("Run()<transacts>:i64 = Block{ ");
        var names: u32 = 0;
        try writeOps(&out, ops[0..count], 0, count, &names);
        try out.writeAll("0 }\nR:i64 = Run()\n");
        const x = try expectRun(h, out.buffered());
        var buffer: [4096]u8 = undefined;
        const got = printed(x, &buffer);
        if (!std.mem.eql(u8, model.out[0..model.out_len], got)) std.debug.print("program:\n{s}\n", .{out.buffered()});
        try std.testing.expectEqualStrings(model.out[0..model.out_len], got);
        compared += got.len;
    }
    try std.testing.expect(compared > 500);
}

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms));
}

/// The scale test of P3.9: `count` subscriptions to one event, every third a `Cut`; then
/// `signals` signals, each followed by a `Signal` and an `Await` of a sticky event, which do not
/// suspend. The last subscription is always a `Late`, which the first `Cut` of each signal
/// cancels before its turn and makes again, so that the new one waits for the next signal
/// (C109): no `Late` is ever called. Prints how long each machine and the replay took.
pub fn subscriptionFan(f: trace_replay.Fixture, count: u32, signals: u32, budget: u64) !void {
    var buffer: [2048]u8 = undefined;
    const source = try std.fmt.bufPrint(&buffer,
        \\Ev:subscribable_event(i64) = subscribable_event(i64){{}}
        \\Flag:sticky_event(i64) = sticky_event(i64){{}}
        \\var Total:i64 = 0
        \\var Spare:option(cancelable) = option{{}}
        \\Add(N:i64)<transacts>:void = Set(Total, Total + N)
        \\Late(N:i64)<transacts>:void = Set(Total, Total + 1000000)
        \\Cut(N:i64)<transacts>:void = Block{{ X := Attempt(Block{{ C := Spare?; C.Cancel(); 1 }}, 0); Set(Spare, option{{Ev.Subscribe(Late)}}); Set(Total, Total + 1) }}
        \\Build(N:i64)<transacts>:i64 = Block{{
        \\    var I:i64 = 0
        \\    While(I < N, Block{{ C := If(Mod[I, 3] == 0, Ev.Subscribe(Cut), Ev.Subscribe(Add)); set I = I + 1 }})
        \\    Set(Spare, option{{Ev.Subscribe(Late)}})
        \\    I
        \\}}
        \\Fire(N:i64)<transacts><suspends>:i64 = Block{{
        \\    var I:i64 = 0
        \\    While(I < N, Block{{ Ev.Signal(I); Flag.Signal(I); V := Flag.Await(); set I = I + 1 }})
        \\    Total
        \\}}
        \\B:i64 = Build({d})
        \\M:task(i64) = Spawn{{ Fire({d}) }}
    , .{ count, signals });
    const p = try f.h.compile(source);
    // A digest run, which reclaims as it goes, checked by the replay through a second run.
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &f.h.values, &f.h.members, &f.h.control, &f.h.state, &f.h.frames, budget);
    const referenced = elapsed(start);
    const actual = f.h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("subscription fan failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    // Each signal `I` reaches every `Add` with `I` and every `Cut` once, and no `Late`.
    const cuts: i64 = @divTrunc(@as(i64, count) + 2, 3);
    const adds: i64 = @as(i64, count) - cuts;
    const s: i64 = signals;
    var report: [4096]u8 = undefined;
    var written: std.Io.Writer = .fixed(&report);
    _ = try reporting.writeReplayed(&written, actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    var expected: [64]u8 = undefined;
    if (std.mem.indexOf(u8, written.buffered(), "\"Total\":") == null) std.debug.print("report: {s}\n", .{written.buffered()});
    try std.testing.expect(std.mem.indexOf(u8, written.buffered(), try std.fmt.bufPrint(&expected, "\"Total\":{d},", .{adds * @divTrunc(s * (s - 1), 2) + cuts * s})) != null);
    std.debug.print("{d} subscriptions, {d} signals: reference={d}ms vm={d}ms replay={d}ms\n", .{ count, signals, referenced, ran - referenced, elapsed(start) - ran });
}

test "subscriptions at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try subscriptionFan(f, 30, 12, 1 << 24);
}

test "review: a program that names a sticky or subscribable event only as a type is inspected at format 27" {
    const h = try harness.create();
    defer scratch.release(h);
    const inspection = @import("inspection.zig");
    const w = try scratch.make(inspection.Workspace);
    defer scratch.release(w);
    for ([_]struct { source: []const u8, format: i64 }{
        .{ .source = "F(S:sticky_event(i64))<computes>:i64 = 1\nX:i64 = 2", .format = 27 },
        .{ .source = "F(S:subscribable_event(i64))<computes>:i64 = 1\nX:i64 = 2", .format = 27 },
        .{ .source = "F(C:cancelable)<computes>:i64 = 1\nX:i64 = 2", .format = 27 },
        // A plain event named only as a type keeps the format it had before P3.9.
        .{ .source = "F(E:event(i64))<computes>:i64 = 1\nX:i64 = 2", .format = 10 },
    }) |case| {
        const p = try h.compile(case.source);
        var buffer: [16 * 1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(inspection.Result.ok, try w.write(&out, p));
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.format, parsed.value.object.get("format").?.integer);
    }
}
