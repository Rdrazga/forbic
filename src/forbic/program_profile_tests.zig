//! Large-scale programs that only fit the `program` capacity profile. Under
//! `bootstrap` these skip; run them with
//!   zig test src/forbic/root.zig --test-runner src/forbic_program_runner.zig
const std = @import("std");
const builtin = @import("builtin");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const profile = @import("profile.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const bytecode = @import("bytecode.zig");
const comparable = @import("comparable_tests.zig");
const effects = @import("effects.zig");
const vm_machine = @import("vm.zig");
const prepared = @import("prepared.zig");

fn requireProgram() error{SkipZigTest}!void {
    if (!std.mem.eql(u8, profile.active.name, "program")) return error.SkipZigTest;
}

fn build(allocator: std.mem.Allocator) std.ArrayList(u8) {
    _ = allocator;
    return .empty;
}

test "five hundred functions and four thousand bindings compile and run" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const functions = 500;
    const bindings = 4000;
    for (0..functions) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=N+{d}\n", .{ i, i });
    for (0..bindings) |i| try source.print(std.testing.allocator, "B{d}:i64=F{d}({d})\n", .{ i, i % functions, i });
    try source.print(std.testing.allocator, "Total<public>:i64=B{d}+B0\n", .{bindings - 1});
    try std.testing.expect(source.items.len > 60_000);
    const x = try h.execute(source.items);
    const last: i64 = (bindings - 1) + ((bindings - 1) % functions);
    try std.testing.expectEqual(last + 0, x.get("Total").?.integer);
}

test "arrays of twenty thousand elements sum natively and concatenate" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Sum:=native{\"std.sum\"}\nItems:[]i64=array{");
    const count = 20_000;
    var expected: i64 = 0;
    for (0..count) |i| {
        try source.print(std.testing.allocator, "{s}{d}", .{ if (i == 0) "" else ",", i % 10 });
        expected += @intCast(i % 10);
    }
    try source.appendSlice(std.testing.allocator, "}\nBoth:=Items+Items\nTotal<public>:i64=Sum(Items)\nDouble<public>:i64=Sum(Both)\nLength<public>:i64=Both.Length\n");
    const program = try h.compile(source.items);
    const reference = h.runtime.evaluate(program, 400_000);
    if (reference == .failed) std.debug.print("array test failed: {s}\n", .{reference.failed.message()});
    try std.testing.expectEqual(expected, reference.ok.get("Total").?.integer);
    try std.testing.expectEqual(2 * expected, reference.ok.get("Double").?.integer);
    try std.testing.expectEqual(@as(i64, 2 * count), reference.ok.get("Length").?.integer);
}

test "hundreds of types and enum cases fit the catalogue" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    for (0..300) |i| try source.print(std.testing.allocator, "R{d}:=struct{{A:i64={d}\nB:string=\"x\"}}\n", .{ i, i });
    for (0..60) |i| {
        try source.print(std.testing.allocator, "E{d}:=enum{{", .{i});
        for (0..40) |c| try source.print(std.testing.allocator, "{s}C{d}", .{ if (c == 0) "" else ",", c });
        try source.appendSlice(std.testing.allocator, "}\n");
    }
    try source.appendSlice(std.testing.allocator, "Pick<public>:i64=R299{}.A\nSame<public>:logic=(E59.C39==E59.C39)\n");
    const x = try h.execute(source.items);
    try std.testing.expectEqual(@as(i64, 299), x.get("Pick").?.integer);
    try std.testing.expect(x.get("Same").?.boolean);
}

test "long strings and deep recursion beyond the bootstrap limits" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Text:string=\"");
    for (0..200_000) |i| try source.append(std.testing.allocator, 'a' + @as(u8, @intCast(i % 26)));
    try source.appendSlice(std.testing.allocator, "\"\nBig<public>:i64=(Text+Text).Length\nDepth(N:i64)<computes>:i64=If(N>0,Depth(N-1)+1,0)\nTop<public>:i64=Depth(100)\n");
    const x = try h.execute(source.items);
    try std.testing.expectEqual(@as(i64, 400_000), x.get("Big").?.integer);
    try std.testing.expectEqual(@as(i64, 100), x.get("Top").?.integer);
}

test "a hundred native bindings and a thirty arm ladder" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Sum:=native{\"std.sum\"}\n");
    for (0..100) |i| try source.print(std.testing.allocator, "Alias{d}:=native{{\"std.abs\"}}\n", .{i});
    try source.appendSlice(std.testing.allocator, "Pick(N:i64)<computes>:i64=");
    for (0..30) |i| try source.print(std.testing.allocator, "If(N=={d},{d},", .{ i, i * 3 });
    try source.appendSlice(std.testing.allocator, "-1");
    for (0..30) |_| try source.append(std.testing.allocator, ')');
    try source.appendSlice(std.testing.allocator, "\nA<public>:i64=Pick(17)\nB<public>:i64=Pick(99)\nC<public>:float=Alias99(-2.5)\nT<public>:i64=Sum(array{1,2,3})\n");
    const x = try h.execute(source.items);
    try std.testing.expectEqual(@as(i64, 51), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(f64, 2.5), x.get("C").?.floating);
    try std.testing.expectEqual(@as(i64, 6), x.get("T").?.integer);
}

/// A wall-clock budget. Budgets are calibrated for optimised builds; unoptimised code is slower by
/// a factor that differs from one code path to the next, so a Debug build checks every result
/// and leaves the budgets to the ReleaseSafe runs (P0.8).
fn budget(within: bool) !void {
    if (builtin.mode == .debug) return;
    try std.testing.expect(within);
}

fn elapsedMs(start: std.Io.Timestamp) u64 {
    const nanoseconds = start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds();
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
}

test "compile and admission time grows gently with function count" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]usize{ 100, 250, 500, 1000 }) |functions| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        for (0..functions) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=N+{d}\n", .{ i, i });
        // Iterate keeps every function a published runtime function instead of an inlined template.
        for (0..functions) |i| try source.print(std.testing.allocator, "B{d}:i64=Iterate(F{d},1,{d})\n", .{ i, i, i });
        try source.appendSlice(std.testing.allocator, "Total<public>:i64=B0\n");
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        const compiled = elapsedMs(start);
        const run = h.runtime.evaluate(program, 400_000);
        const total = elapsedMs(start);
        try std.testing.expect(run == .ok);
        try budget(total < 5000);
        std.debug.print("functions={d} source={d}B compile={d}ms total={d}ms\n", .{ functions, source.items.len, compiled, total });
    }
}

test "twenty thousand functions and bindings are admitted in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 20_000;
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=N+{d}\n", .{ i, i });
    // Iterate keeps every function a published runtime function instead of an inlined template.
    for (0..count) |i| try source.print(std.testing.allocator, "B{d}:i64=Iterate(F{d},1,{d})\n", .{ i, i, i });
    try source.print(std.testing.allocator, "Total<public>:i64=B{d}\n", .{count - 1});
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    try std.testing.expect(program.functions.len >= count and program.bindings.len >= count);
    // Each machine admits the whole program before it runs it, so each time includes one admission.
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 4_000_000);
    const referenced = elapsedMs(start);
    const actual = h.runtime.evaluate(program, 4_000_000);
    const total = elapsedMs(start);
    std.debug.print("functions={d} bindings={d} source={d}B compile={d}ms reference={d}ms vm={d}ms total={d}ms\n", .{ program.functions.len, program.bindings.len, source.items.len, compiled, referenced - compiled, total - referenced, total });
    try std.testing.expectEqual(@as(i64, 2 * (count - 1)), reference.ok.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 2 * (count - 1)), actual.ok.get("Total").?.integer);
    // Duplicate detection by pairwise comparison took about N^2/2 name comparisons per admission.
    try budget(total < 5000);
}

test "a hundred subclasses override fifteen hundred methods and dispatch through the base" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const classes = 100;
    const methods = 20;
    const overridden = 15;
    try source.appendSlice(std.testing.allocator, "Base:=class{\n");
    for (0..methods) |j| try source.print(std.testing.allocator, "  M{d}()<transacts>:i64={d}\n", .{ j, j });
    try source.appendSlice(std.testing.allocator, "}\n");
    for (0..classes) |i| {
        try source.print(std.testing.allocator, "C{d}:=class(Base){{\n", .{i});
        for (0..overridden) |j| try source.print(std.testing.allocator, "  M{d}<override>()<transacts>:i64={d}\n", .{ j, (i + 1) * 100 + j });
        try source.appendSlice(std.testing.allocator, "}\n");
    }
    for (0..classes) |i| try source.print(std.testing.allocator, "O{d}:Base=C{d}{{}}\nR{d}:i64=O{d}.M{d}()\n", .{ i, i, i, i, i % methods });
    try source.appendSlice(std.testing.allocator, "Low<public>:i64=R7\nHigh<public>:i64=R99\nKept<public>:i64=R17\n");
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    try std.testing.expectEqual(@as(usize, methods), program.slots.len);
    try std.testing.expectEqual(@as(usize, (classes + 1) * methods), program.dispatch.len);
    try std.testing.expect(program.functions.len >= classes * overridden + methods);
    const x = try h.run(program, 400_000);
    std.debug.print("methods={d} dispatch={d} compile={d}ms total={d}ms\n", .{ program.functions.len, program.dispatch.len, compiled, elapsedMs(start) });
    // Members are scanned once: a per-member pass over the token array showed up here as 160 ms.
    try budget(compiled < 1000);
    try std.testing.expectEqual(@as(i64, 807), x.ok.get("Low").?.integer);
    // C99 overrides M0..M14 only, so M19 is the base's; C17 inherits M17 too.
    try std.testing.expectEqual(@as(i64, 19), x.ok.get("High").?.integer);
    try std.testing.expectEqual(@as(i64, 17), x.ok.get("Kept").?.integer);
}

/// A hierarchy on one interface with fields and default bodies, a pool of extension methods, and
/// `calls` calls of them. Returns the compile time in milliseconds after running the program.
fn interfaceScale(h: *harness.Harness, classes: usize, calls: usize) !u64 {
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    const defaults = 20;
    const extensions = 50;
    try source.appendSlice(a, "Shape:=interface{\n  var Hits:i64=1\n  Side:i64=2\n  Area()<transacts>:i64=Self.Side*Self.Side\n  Grow(By:i64=1)<transacts>:i64=Block{set Self.Hits=Self.Hits+By;Self.Hits}\n");
    for (0..defaults) |j| try source.print(a, "  M{d}()<transacts>:i64={d}+Self.Side\n", .{ j, j });
    try source.appendSlice(a, "}\n");
    // Every fourth class starts a chain on the interface; the others extend the class before them.
    for (0..classes) |i| {
        if (i % 4 == 0) {
            try source.print(a, "C{d}:=class(Shape){{\n  Side<override>:i64={d}\n}}\n", .{ i, i });
        } else try source.print(a, "C{d}:=class(C{d}){{\n  M{d}<override>()<transacts>:i64={d}\n}}\n", .{ i, i - 1, i % defaults, 1000 + i });
    }
    for (0..extensions) |k| try source.print(a, "(S:Shape).E{d}(N:i64=1)<transacts>:i64=S.Area()+N+{d}\n(V:i64).X{d}()<computes>:i64=V+{d}\n", .{ k, k, k, k });
    for (0..classes) |i| try source.print(a, "O{d}:Shape=C{d}{{}}\n", .{ i, i });
    for (0..calls / 2) |n| try source.print(a, "R{d}:i64=O{d}.E{d}()+{d}.X{d}()\n", .{ n, n % classes, n % extensions, n, n % extensions });
    const last = calls / 2 - 1;
    try source.print(a, "Last<public>:i64=R{d}\nFirst<public>:i64=R0\nGrown<public>:i64=O1.Grow()+O1.Grow(By:=5)\nKept<public>:i64=O5.M5()\nPlain<public>:i64=O5.M6()\n", .{last});
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    const x = try h.run(program, 16_000_000);
    std.debug.print("interface classes={d} extension calls={d} functions={d} dispatch={d} source={d}B compile={d}ms total={d}ms\n", .{ classes, calls, program.functions.len, program.dispatch.len, source.items.len, compiled, elapsedMs(start) });
    const side: i64 = @intCast((last % classes) - (last % classes) % 4);
    const k: i64 = @intCast(last % extensions);
    try std.testing.expectEqual(side * side + 1 + k + @as(i64, @intCast(last)) + k, x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.ok.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, 2 + 7), x.ok.get("Grown").?.integer);
    // C5 overrides M5; M6 is the interface's body reading the side its chain's first class gave.
    try std.testing.expectEqual(@as(i64, 1005), x.ok.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 6 + 4), x.ok.get("Plain").?.integer);
    return compiled;
}

test "two hundred classes on an interface with defaults take two thousand extension method calls" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const half = try interfaceScale(h, 100, 1000);
    const full = try interfaceScale(h, 200, 2000);
    // Method tables are walked per slot, not per method, so doubling the program about doubles
    // the work; a quadratic table scan would show as a factor of four.
    try budget(full < 1000);
    try budget(full <= 3 * half + 50);
}

test "recursion ten thousand frames deep returns" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.run(try h.compile("Down(N:i64)<computes>:i64=If(N==0,0,1+Down(N-1))\nA<public>:i64=Down(10000)"), 4_000_000);
    try std.testing.expectEqual(@as(i64, 10000), x.ok.get("A").?.integer);
}

test "two hundred thousand instances are created and counted in one run" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const x = try h.run(try h.compile("P:=class{var N:i64}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};S+X.N-S+1}\nTotal<public>:i64=Iterate(Step,200000,0)"), 64_000_000);
    std.debug.print("instances=200000 total={d}ms\n", .{elapsedMs(start)});
    try std.testing.expectEqual(@as(i64, 200000), x.ok.get("Total").?.integer);
    try std.testing.expectEqual(@as(usize, 400000), x.ok.object_cells.len);
}

test "a case with five hundred arms selects any of them" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Pick(N:i64)<computes>:i64=Case(N");
    for (0..500) |i| try source.print(std.testing.allocator, ",{d}=>{d}", .{ i, i * 10 });
    try source.appendSlice(std.testing.allocator, ",_=>-1)\nFirst<public>:i64=Pick(0)\nLast<public>:i64=Pick(499)\nNone<public>:i64=Pick(500)\n");
    const x = try h.run(try h.compile(source.items), 1_000_000);
    try std.testing.expectEqual(@as(i64, 0), x.ok.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, 4990), x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("None").?.integer);
}

test "a case with three hundred type-test arms narrows to any of three hundred classes" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const classes = 300;
    try source.appendSlice(std.testing.allocator, "Base:=class{}\nvar Seen:i64=0\nNote(N:i64)<transacts>:logic=Block{set Seen=Seen+1;N>=0}\n");
    for (0..classes) |i| try source.print(std.testing.allocator, "C{d}:=class(Base){{V:i64={d}}}\n", .{ i, i * 10 });
    // Every arm binds the instance narrowed to its own class.
    try source.appendSlice(std.testing.allocator, "Pick(B:Base)<transacts>:i64=Case(B");
    for (0..classes) |i| try source.print(std.testing.allocator, ",X{d}:C{d}=>X{d}.V", .{ i, i, i });
    // A guard per arm that writes and then does not hold: each is undone before the next arm.
    // Such an arm keeps the names it bound in one live local until the `Case` ends, so their
    // number is bounded by `local_bindings`, not by the control depth.
    const guarded = 200;
    comptime std.debug.assert(guarded < types.limits.local_bindings);
    try source.appendSlice(std.testing.allocator, ",_=>-1)\nScan(N:i64)<transacts>:i64=Case(N");
    for (0..guarded) |i| try source.print(std.testing.allocator, ",X:i64 where Note({d}-X)=>X*2", .{i});
    try source.print(std.testing.allocator, ",_=>-2)\nFirst<public>:i64=Pick(C0{{}})\nLast<public>:i64=Pick(C{d}{{}})\nNone<public>:i64=Pick(Base{{}})\nMiss<public>:i64=Scan({d})\nHit<public>:i64=Scan({d})\nNotes<public>:i64=Seen\n", .{ classes - 1, guarded, guarded - 1 });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    std.debug.print("type-test arms={d} compile={d}ms\n", .{ classes, elapsedMs(start) });
    const x = try h.run(program, 10_000_000);
    try std.testing.expectEqual(@as(i64, 0), x.ok.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, (classes - 1) * 10), x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("None").?.integer);
    try std.testing.expectEqual(@as(i64, -2), x.ok.get("Miss").?.integer);
    try std.testing.expectEqual(@as(i64, (guarded - 1) * 2), x.ok.get("Hit").?.integer);
    // Four hundred guards ran; only the one that held kept its write.
    try std.testing.expectEqual(@as(i64, 1), x.ok.get("Notes").?.integer);
}

test "five hundred regions nested through recursion commit and roll back" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var Count:i64=0
        \\Deep(N:i64)<transacts>:i64=If(N==0,0,Attempt(Block{set Count=Count+1;1+Deep(N-1)},-1000))
        \\Fall(N:i64)<transacts><decides>:i64=Block{set Count=Count+1;Require[N>0];Fall[N-1]}
        \\Kept<public>:i64=Deep(500)
        \\Seen<public>:i64=Count
        \\Gone<public>:i64=Attempt(Fall[300],7)
        \\After<public>:i64=Count
    ;
    const x = try h.run(try h.compile(source), 4_000_000);
    try std.testing.expectEqual(@as(i64, 500), x.ok.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 500), x.ok.get("Seen").?.integer);
    try std.testing.expectEqual(@as(i64, 7), x.ok.get("Gone").?.integer);
    try std.testing.expectEqual(@as(i64, 500), x.ok.get("After").?.integer);
}

test "two thousand mutable cells and a hundred thousand loop iterations" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    for (0..2000) |i| try source.print(std.testing.allocator, "var V{d}:i64={d}\n", .{ i, i });
    try source.appendSlice(std.testing.allocator, "Bump(S:i64)<transacts>:i64=Block{set V0=V0+1;S+V1999}\nSum<public>:i64=Iterate(Bump,100000,0)\nHits<public>:i64=V0\n");
    const start = std.Io.Clock.awake.now(std.testing.io);
    const x = try h.run(try h.compile(source.items), 64_000_000);
    std.debug.print("cells=2000 iterations=100000 total={d}ms\n", .{elapsedMs(start)});
    try std.testing.expectEqual(@as(i64, 100000), x.ok.get("Hits").?.integer);
    try std.testing.expectEqual(@as(i64, 199_900_000), x.ok.get("Sum").?.integer);
}

test "fuel above 2^32 is accepted and a small budget still stops both machines alike" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const program = try h.compile("Step(S:i64)<computes>:i64=S+1\nTotal<public>:i64=Iterate(Step,20,0)");
    // `run` requires the reference evaluator and the VM to agree on the outcome and, when
    // they stop, on the diagnostic: every budget below the exact cost is the same work_limit.
    var needed: u64 = 0;
    while (needed < 4096) : (needed += 1) {
        const x = try h.run(program, needed);
        if (x == .ok) break;
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, x.failed.code);
    }
    try std.testing.expect(needed > 20 and needed < 4096);
    try std.testing.expectEqual(@as(i64, 20), (try h.run(program, needed)).ok.get("Total").?.integer);
    // A 32-bit fuel path would keep only the low half, which is one unit short of the cost.
    const wide: u64 = (1 << 32) + needed - 1;
    try std.testing.expectEqual(@as(i64, 20), (try h.run(program, wide)).ok.get("Total").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, @as(u32, @truncate(wide)))).failed.code);
    // The profile default is a bound on time, beyond what 32 bits can count.
    try std.testing.expect(types.limits.evaluation_work > std.math.maxInt(u32));
    for ([_]u64{ types.limits.evaluation_work, std.math.maxInt(u64) }) |fuel| {
        try std.testing.expectEqual(@as(i64, 20), (try h.run(program, fuel)).ok.get("Total").?.integer);
    }
}

test "a loop writes one cell more often than the undo quota outside and inside a failed Attempt" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // The call witness holds a step per visited node, which is fewer loop iterations than
    // 2 * source_undos + 100, so an iteration writes the cell sixteen times: the writes still
    // exceed the quota that counted every one of them. source_state.zig runs the full count.
    // `Set` yields what it wrote, so the chain is a call step per write.
    const body_writes = 16;
    const iterations = types.limits.source_undos / body_writes + 100;
    comptime std.debug.assert(body_writes * iterations > types.limits.source_undos + 100);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "var Total<public>:i64=5\nBump(S:i64)<transacts>:i64=Block{");
    try source.appendSlice(std.testing.allocator, "set Total=");
    for (1..body_writes) |_| try source.appendSlice(std.testing.allocator, "Set(Total,");
    try source.appendSlice(std.testing.allocator, "S");
    for (1..body_writes) |_| try source.appendSlice(std.testing.allocator, ")");
    try source.appendSlice(std.testing.allocator, ";S+1}\n");
    const prefix = source.items.len;

    try source.print(std.testing.allocator, "Sum<public>:i64=Iterate(Bump,{d},0)\nAfter<public>:i64=Total\n", .{iterations});
    const start = std.Io.Clock.awake.now(std.testing.io);
    const kept = try h.run(try h.compile(source.items), 64_000_000);
    std.debug.print("writes={d} outside Attempt total={d}ms\n", .{ body_writes * iterations, elapsedMs(start) });
    try std.testing.expectEqual(@as(i64, iterations), kept.ok.get("Sum").?.integer);
    try std.testing.expectEqual(@as(i64, iterations - 1), kept.ok.get("After").?.integer);

    source.shrinkRetainingCapacity(prefix);
    try source.print(std.testing.allocator, "Tried<public>:i64=Attempt(Block{{set Total=Iterate(Bump,{d},0)+1000;Fail[\"undo\"];Total}},0-Total)\nAfter<public>:i64=Total\n", .{iterations});
    const undone = try h.run(try h.compile(source.items), 64_000_000);
    try std.testing.expectEqual(@as(usize, 1), undone.ok.failures.len);
    try std.testing.expectEqual(@as(i64, -5), undone.ok.get("Tried").?.integer);
    try std.testing.expectEqual(@as(i64, 5), undone.ok.get("After").?.integer);

    source.shrinkRetainingCapacity(prefix);
    try source.print(std.testing.allocator, "Tried<public>:i64=Attempt(Block{{set Total=Iterate(Bump,{d},0)+1000;Total}},0-Total)\nAfter<public>:i64=Total\n", .{iterations});
    const committed = try h.run(try h.compile(source.items), 64_000_000);
    try std.testing.expectEqual(@as(i64, iterations + 1000), committed.ok.get("Tried").?.integer);
    try std.testing.expectEqual(@as(i64, iterations + 1000), committed.ok.get("After").?.integer);
}

test "five million loop iterations outgrow the stored witness and complete in digest mode" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // The body builds no aggregate and writes no cell, so the witness is the only ceiling here.
    const program = try h.compile("Step(S:i64)<computes>:i64=S+1\nTotal<public>:i64=Iterate(Step,5000000,0)");
    const fuel = 64_000_000;
    // Stored, the witness is full long before the loop ends, in both machines alike.
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    try std.testing.expectEqual(@as(i64, 5_000_000), reference.ok.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 5_000_000), actual.ok.get("Total").?.integer);
    // Three steps a visit: the parameter, the constant and the sum.
    try std.testing.expectEqual(@as(u64, 15_000_000), actual.ok.witness.count);
    try std.testing.expect(actual.ok.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(@as(usize, 0), reference.ok.call_steps.len + actual.ok.call_steps.len);
    // The report replays a second run a window at a time; no part of it holds the witness.
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Total\":5000000}\n", out.buffered());
    std.debug.print("iterations=5000000 steps=15000000 reference={d}ms vm={d}ms replayed report={d}ms\n", .{ reference_ms, actual_ms, elapsedMs(start) });
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
    h.control.trace = .off;
    h.runtime.machine.control.trace = .off;
    try std.testing.expectEqual(@as(i64, 5_000_000), evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).ok.get("Total").?.integer);
    const silent = h.runtime.evaluate(program, fuel);
    try std.testing.expectEqual(@as(i64, 5_000_000), silent.ok.get("Total").?.integer);
    try std.testing.expect(silent.ok.callWitness() == null);
}

test "a fifty thousand entry map with tuple keys is built looked up compared and reduced" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 50_000;
    try source.appendSlice(std.testing.allocator, "Grid:=map(tuple(i64,i64),i64)\nCells:Grid=map{");
    for (0..count) |i| try source.print(std.testing.allocator, "{s}tuple{{{d},{d}}}=>{d}", .{ if (i == 0) "" else ",", i, i * 7 % 13, i });
    // The last, a middle and an absent key; then the same after the middle one is removed.
    try source.print(std.testing.allocator, "}}\nLast<public>:i64=Attempt(Cells[tuple{{{d},{d}}}],-1)\nNear<public>:i64=Attempt(Cells[tuple{{25000,{d}}}],-1)\nMiss<public>:i64=Attempt(Cells[tuple{{25000,{d}}}],-1)\n", .{ count - 1, (count - 1) * 7 % 13, 25000 * 7 % 13, 25000 * 7 % 13 + 1 });
    try source.print(std.testing.allocator, "Fewer:Grid=Attempt(Without[Cells,tuple{{25000,{d}}}],Cells)\nCount<public>:i64=Fewer.Length\nGone<public>:i64=Attempt(Fewer[tuple{{25000,{d}}}],-1)\nNext<public>:i64=Attempt(Fewer[tuple{{25001,{d}}}],-1)\nKept<public>:i64=Cells.Length\nSame<public>:logic=Cells==Cells\nDiffer<public>:logic=Fewer!=Cells\nAbsent<public>:i64=Attempt(Without[Fewer,tuple{{25000,{d}}}].Length,-1)\n", .{ 25000 * 7 % 13, 25000 * 7 % 13, 25001 * 7 % 13, 25000 * 7 % 13 });
    const program = try h.compile(source.items);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const x = try h.run(program, 64_000_000);
    std.debug.print("map entries={d} source={d} bytes total={d}ms\n", .{ count, source.items.len, elapsedMs(start) });
    if (x == .failed) std.debug.print("map scale test failed: {s}\n", .{x.failed.message()});
    try std.testing.expectEqual(@as(i64, count - 1), x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 25000), x.ok.get("Near").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("Miss").?.integer);
    try std.testing.expectEqual(@as(i64, count - 1), x.ok.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("Gone").?.integer);
    try std.testing.expectEqual(@as(i64, 25001), x.ok.get("Next").?.integer);
    try std.testing.expectEqual(@as(i64, count), x.ok.get("Kept").?.integer);
    try std.testing.expect(x.ok.get("Same").?.boolean and x.ok.get("Differ").?.boolean);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("Absent").?.integer);
    // The entries around the removed one keep their order.
    const fewer = x.ok.elements(x.ok.get("Fewer").?).?;
    try std.testing.expectEqual(@as(i64, 24999), fewer[2 * 24999 + 1].integer);
    try std.testing.expectEqual(@as(i64, 25001), fewer[2 * 25000 + 1].integer);
    // A budget that covers the literal but not the lookups stops both machines alike.
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, 600_000)).failed.code);
}

test "a range of a million with a filter runs in digest mode without building an array" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const count = 1_000_000;
    const program = try h.compile("Kept<public>:[]i64=For(I:1..1000000,I>999990,I*2)\nCount<public>:i64=Kept.Length");
    const fuel = 64_000_000;
    // Stored, the witness of a loop this long is full before it ends, in both machines alike.
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |execution| {
        try std.testing.expectEqual(@as(i64, 10), execution.get("Count").?.integer);
        const kept = execution.elements(execution.get("Kept").?).?;
        try std.testing.expectEqual(@as(usize, 10), kept.len);
        for (kept, 0..) |element, index| try std.testing.expectEqual(@as(i64, 2 * (count - 9 + @as(i64, @intCast(index)))), element.integer);
        // The range is never an array: an iteration leaves its two-element state behind and a
        // kept one a copy of the short accumulator, far less than a member per element squared.
        // Each skipped iteration's state tuple is garbage that reclamation may already have removed.
        try std.testing.expect(execution.aggregate_values.len < 2 * count + 256);
    }
    try std.testing.expect(actual.ok.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    // The report replays a second run a window at a time.
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Kept\":[1999982,1999984,1999986,1999988,1999990,1999992,1999994,1999996,1999998,2000000],\"Count\":10}\n", out.buffered());
    std.debug.print("range iterations={d} steps={d} members={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ count, actual.ok.witness.count, actual.ok.aggregate_values.len, reference_ms, actual_ms, elapsedMs(start) });
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "ninety thousand nested range iterations with bindings replay from a stored witness" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // 300 x 300 pairs; the binding fails for none, the filters keep the 299 pairs that sum to 300.
    const x = (try h.run(try h.compile("Sums<public>:[]i64=For(X:1..300,Y:1..300,S:=X+Y,S==300,X*1000+Y)\nCount<public>:i64=Sums.Length\nLast<public>:i64=Attempt(Sums[298],0)"), 64_000_000)).ok;
    try std.testing.expectEqual(@as(i64, 299), x.get("Count").?.integer);
    try std.testing.expectEqual(@as(i64, 299_001), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 1_299), x.elements(x.get("Sums").?).?[0].integer);
}

test "ten million iterations that write a cell, build a tuple and call a function run in a pool they would fill five times" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const iterations = 10_000_000;
    const program = try h.compile("var Count:i64=0\nStep(S:i64)<transacts>:i64=Block{set Count=Count+1;T:=tuple{S,S+1};T(1)}\nTotal<public>:i64=Iterate(Step,10000000,0)\nSeen<public>:i64=Count");
    const fuel = 1 << 32;
    // Stored, the witness is the first ceiling; without reclamation the pool is the next.
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    h.control.reclaim_floor = types.ControlStorage.reclaim_never;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.reclaim_never;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, h.runtime.evaluate(program, fuel).failed.code);
    h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    var start = begun;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        try std.testing.expectEqual(@as(i64, iterations), x.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, iterations), x.get("Seen").?.integer);
        // A visit leaves two members and keeps none, so each reclamation empties the pool:
        // twenty million members in portions of the floor, and the rest as the call returns.
        try std.testing.expectEqual(@as(u64, 2 * iterations / types.ControlStorage.default_reclaim_floor + 1), x.reclaims);
        try std.testing.expectEqual(@as(usize, 0), x.aggregate_values.len);
    }
    try std.testing.expect(2 * iterations > 4 * types.limits.aggregate_elements);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try std.testing.expectEqualDeep(a, b);
    // The report replays a second run that reclaims as the first did, and works out each
    // reclamation for itself.
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Total\":10000000,\"Seen\":10000000}\n", out.buffered());
    const report_ms = elapsedMs(start);
    std.debug.print("iterations=10000000 members=20000000 reclaims={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ actual.ok.reclaims, reference_ms, actual_ms, report_ms });
    // Memory is constant in the count; time must stay proportional to it.
    try budget(elapsedMs(begun) < 60_000);
    // The reference's run is the same execution, so one replay admits both; reclaim_tests
    // forges every field of a reclaiming run at a size where that takes no time.
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
    // A second run that does not reclaim cannot even finish, and validates nothing.
    again.control.reclaim_floor = types.ControlStorage.reclaim_never;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(actual.ok, again.producer(program, fuel), true, .{}));
}

test "a loop that keeps every member it builds still stops at the pool, alike in both machines" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // The state is the array: every member stays in use, so there is nothing to reclaim.
    const program = try h.compile("Grow(S:[]i64)<computes>:[]i64=S+array{S.Length}\nAll<public>:i64=Iterate(Grow,5000000,array{}).Length");
    comptime std.debug.assert(5_000_000 > types.limits.aggregate_elements);
    const fuel = 1 << 32;
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(program, fuel);
    std.debug.print("accumulating members={d} reclaims={d} total={d}ms\n", .{ types.limits.aggregate_elements, h.runtime.machine.control.reclaims, elapsedMs(start) });
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, reference.failed.code);
    try std.testing.expectEqualDeep(reference.failed, actual.failed);
    // The attempts to make room are spaced by what they cost: a handful for the whole pool.
    try std.testing.expectEqual(h.control.reclaims, h.runtime.machine.control.reclaims);
    try std.testing.expect(h.control.reclaims > 0 and h.control.reclaims < 64);
    // A shorter one of the same shape completes, with all of its members.
    const fits = try h.compile("Grow(S:[]i64)<computes>:[]i64=S+array{S.Length}\nAll<public>:i64=Iterate(Grow,3000000,array{}).Length");
    const kept = evaluator.evaluateWithRuntimeStorage(fits, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const kept_actual = h.runtime.evaluate(fits, fuel);
    try std.testing.expectEqual(@as(i64, 3_000_000), kept.ok.get("All").?.integer);
    try std.testing.expectEqual(@as(i64, 3_000_000), kept_actual.ok.get("All").?.integer);
    try std.testing.expectEqualDeep(kept.ok.witness, kept_actual.ok.witness);
}

test "a million comparisons on the last of sixteen thousand types are admitted by one pass over the catalogue" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const forged = try comparable.Comparisons.create(std.testing.allocator, types.limits.user_types, types.limits.nodes, false);
    defer forged.destroy(std.testing.allocator);
    const program = forged.program;
    // Without fuel a run is its admission: every node is checked and the first one then stops.
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 0);
    const reference_ms = elapsedMs(start);
    const lowered = bytecode.lower(program, &h.runtime.instructions).ok;
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.machine.run(lowered, 0);
    const actual_ms = elapsedMs(start);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, reference.failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, actual.failed.code);
    std.debug.print("comparisons={d} types={d} admission reference={d}ms vm={d}ms\n", .{ program.nodes.len - 1, program.definitions.len, reference_ms, actual_ms });
    // Asked of the catalogue once per comparison, this was a walk down sixteen thousand
    // definitions a million times, before any fuel was charged: minutes. One pass over the
    // catalogue and an answer per node is a small part of a second.
    try budget(reference_ms < 2000 and actual_ms < 2000);
    // Funded, both machines run it and charge it alike, to the unit.
    const fuel = forged.fuel();
    try std.testing.expect(evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).ok.values[program.nodes.len - 1].boolean);
    try std.testing.expect(h.runtime.machine.run(lowered, fuel).ok[program.nodes.len - 1].boolean);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel - 1).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, h.runtime.machine.run(lowered, fuel - 1).failed.code);
}

test "a million exact rational sums telescope in digest mode and five thousand rationals key a map" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // 1/(1*2) + 1/(2*3) + ... + 1/(N*(N+1)) is N/(N+1): every partial sum reduces, so the terms
    // stay small while a million additions, reductions and Euclidean divisions run. Each visit
    // leaves a tuple behind, so the pool is reclaimed around two-word scalars throughout.
    const iterations = 1_000_000;
    const program = try h.compile(
        \\Term(K:i64)<computes>:rational=Attempt(Rational[1,K*(K+1)],MakeRationalFromInt(0))
        \\Step(S:tuple(rational,i64,i64))<computes>:tuple(rational,i64,i64)=tuple{S(0)+Term(S(1)),S(1)+1,S(2)+Attempt(Mod[S(1),7]-Quotient[-S(1),7],0)}
        \\End:tuple(rational,i64,i64)=Iterate(Step,1000000,tuple{MakeRationalFromInt(0),1,0})
        \\Sum<public>:rational=End(0)
        \\Check<public>:i64=End(2)
        \\Whole<public>:i64=Ceil(Sum)-Floor(Sum)
        \\Near<public>:logic=ToFloat(Sum)<1.0 and Sum<MakeRationalFromInt(1)
    );
    const fuel = 1 << 32;
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    if (actual == .failed) std.debug.print("rational scale test failed: {s}\n", .{actual.failed.message()});
    // Mod[K,7] - Quotient[-K,7] is (K mod 7) + ceil(K/7), summed over K = 1..N by a plain model.
    var check: i64 = 0;
    var k: i64 = 1;
    while (k <= iterations) : (k += 1) check += @mod(k, 7) + @divFloor(k + 6, 7);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        try std.testing.expectEqualDeep(types.Rational{ .numerator = iterations, .denominator = iterations + 1 }, x.get("Sum").?.rational);
        try std.testing.expectEqual(check, x.get("Check").?.integer);
        try std.testing.expectEqual(@as(i64, 1), x.get("Whole").?.integer);
        try std.testing.expect(x.get("Near").?.boolean);
        try std.testing.expect(x.reclaims > 0);
    }
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try std.testing.expectEqualDeep(a, b);
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    var expected: [128]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"Sum\":{{\"$rational\":[1000000,1000001]}},\"Check\":{d},\"Whole\":1,\"Near\":true}}\n", .{check}), out.buffered());
    std.debug.print("rational iterations={d} reclaims={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ iterations, actual.ok.reclaims, reference_ms, actual_ms, elapsedMs(start) });
    try budget(reference_ms + actual_ms < 60_000);
    // Rational keys at scale: distinct fractions, each found again by another spelling of it.
    h.control.trace = .full;
    h.runtime.machine.control.trace = .full;
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 5_000;
    try source.appendSlice(std.testing.allocator, "R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))\nTable:map(rational,i64)=map{");
    // K/10007 with a prime denominator: all distinct and none reducible.
    for (1..count + 1) |i| try source.print(std.testing.allocator, "{s}R({d},10007)=>{d}", .{ if (i == 1) "" else ",", i, i });
    try source.print(std.testing.allocator, "}}\nLast<public>:i64=Or(Lookup(Table,R({d},{d})),-1)\nMiddle<public>:i64=Or(Lookup(Table,R(-7500,-30021)),-1)\nMiss<public>:i64=Or(Lookup(Table,R(1,10009)),-1)\nSize<public>:i64=Table.Length\nSame<public>:logic=Table==Table\n", .{ 3 * count, 3 * 10007 });
    const keyed = try h.compile(source.items);
    start = std.Io.Clock.awake.now(std.testing.io);
    const x = try h.run(keyed, 64_000_000);
    if (x == .failed) std.debug.print("rational map scale test failed: {s}\n", .{x.failed.message()});
    std.debug.print("rational keys={d} total={d}ms\n", .{ count, elapsedMs(start) });
    try std.testing.expectEqual(@as(i64, count), x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 2500), x.ok.get("Middle").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.ok.get("Miss").?.integer);
    try std.testing.expectEqual(@as(i64, count), x.ok.get("Size").?.integer);
    try std.testing.expect(x.ok.get("Same").?.boolean);
}

test "a First over a million-element range undoes every miss and stops at its hit, in digest mode" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // 999998 is the least I whose square passes the bound; every iteration before it writes the
    // cell and fails its filter, and the search must not look at the two elements after it.
    const program = try h.compile("var Log:i64=0\nNote(X:i64)<transacts>:i64=Block{set Log=Log+1;X}\n" ++
        "Search()<transacts>:i64=Attempt(First[I:1..1000000,Note(I)*I>999996000000,10/(1000000-I)>=0,I],-1)\n" ++
        "Found<public>:i64=Search()\nWrites<public>:i64=Log\n" ++
        "Miss<public>:option(i64)=option{First[I:1..300000,I<0,I]}\n");
    const fuel = 1 << 30;
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |execution| {
        try std.testing.expectEqual(@as(i64, 999_998), execution.get("Found").?.integer);
        // One write survives: that of the iteration the search yielded.
        try std.testing.expectEqual(@as(i64, 1), execution.get("Writes").?.integer);
        try std.testing.expectEqual(@as(usize, 0), execution.elements(execution.get("Miss").?).?.len);
        // A failed iteration leaves three members, which reclamation takes back as the run goes.
        try std.testing.expect(execution.aggregate_values.len < 1_000_000);
    }
    try std.testing.expect(actual.ok.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    try std.testing.expectEqual(h.control.failure_count, h.runtime.machine.control.failure_count);
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Found\":999998,\"Writes\":1,\"Miss\":[]}\n", out.buffered());
    std.debug.print("first iterations=1299998 steps={d} members={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ actual.ok.witness.count, actual.ok.aggregate_values.len, reference_ms, actual_ms, elapsedMs(start) });
}

test "a million bitwise steps agree with Zig in both machines" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const count = 1_000_000;
    const program = try h.compile("Mixed<public>:tuple(i64,i64)=Iterate(Fn(S:tuple(i64,i64)){tuple{S(0)+1,BitXor(BitOr(BitAnd(S(1),1048575)*3,S(0)),BitNot(S(0)*S(0)))}},1000000,tuple{0,1})\n" ++
        "Low<public>:i64=BitAnd(Mixed(1),65535)\n");
    var position: i64 = 0;
    var value: i64 = 1;
    for (0..count) |_| {
        value = ((value & 1048575) * 3 | position) ^ ~(position * position);
        position += 1;
    }
    const fuel = 1 << 30;
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(program, fuel);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |execution| {
        const mixed = execution.elements(execution.get("Mixed").?).?;
        try std.testing.expectEqual(position, mixed[0].integer);
        try std.testing.expectEqual(value, mixed[1].integer);
        try std.testing.expectEqual(value & 65535, execution.get("Low").?.integer);
    }
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    std.debug.print("bitwise steps={d} value={d} total={d}ms\n", .{ count, value, elapsedMs(start) });
}

test "twenty thousand option forms that catch are found in one pass and compiled in a second" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const options = 20_000;
    try source.appendSlice(std.testing.allocator, "Xs:[]i64=array{1,2,3}\n");
    // Three thousand established loops beside them: whether a constructor lies in one is
    // looked up, not searched for, so they add their own compile time and no product.
    for (0..3000) |index| try source.print(std.testing.allocator, "L{d}:[]i64=For(X:Xs,X+{d})\n", .{ index, index });
    for (0..options) |index| try source.print(std.testing.allocator, "O{d}:option(i64)=option{{Xs[{d}]}}\n", .{ index, index % 5 });
    try source.print(std.testing.allocator, "Last<public>:i64=Or(O{d},-1)\nMiss<public>:i64=Or(O{d},-1)\n", .{ options - 3, options - 1 });
    var start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const many_ms = elapsedMs(start);
    try std.testing.expectEqual(@as(u32, options), h.front.option_caught_count);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    const x = (try h.run(program, 1 << 24)).ok;
    try std.testing.expectEqual(@as(i64, 3), x.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Miss").?.integer);
    try std.testing.expectEqual(@as(u32, options / 5 * 2), x.failure_count);
    // The same program with the regions spelled out is compiled in one pass; finding the
    // constructors costs about one more, not one per constructor. (The region is a binding
    // condition: by RFC-0076 rule 7 an `option{Xs[I]}` in an `Attempt` body is itself a
    // constructor that catches, so the old spelling `Attempt(option{Xs[I]},option{})` is
    // found in a first pass like the short one.)
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "Xs:[]i64=array{1,2,3}\n");
    for (0..3000) |index| try source.print(std.testing.allocator, "L{d}:[]i64=For(X:Xs,X+{d})\n", .{ index, index });
    for (0..options) |index| try source.print(std.testing.allocator, "O{d}:option(i64)=If(V:=Xs[{d}],option{{V}},option{{}})\n", .{ index, index % 5 });
    start = std.Io.Clock.awake.now(std.testing.io);
    _ = try h.compile(source.items);
    const spelled_ms = elapsedMs(start);
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    std.debug.print("catching options={d} compile={d}ms spelled={d}ms\n", .{ options, many_ms, spelled_ms });
    try budget(many_ms <= 4 * spelled_ms + 200);
}

test "a Loop{} of two million visits that count in a cell ends by Break in digest mode with a replayed report" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const iterations = 2_000_000;
    // `Last` is a tuple the loop carries: each visit builds a new one, and the one in the state
    // has to survive every reclamation of the visits' other members.
    const program = try h.compile(
        \\var Count:i64=0
        \\Spin(N:i64)<transacts>:i64=Block{
        \\  var Last:tuple(i64,i64)=tuple{0,0}
        \\  Loop{
        \\    set Count=Count+1
        \\    set Last=tuple{Count,Last(0)}
        \\    If(Count>=N,Break(),false)
        \\  }
        \\  Last(0)*10+Last(0)-Last(1)
        \\}
        \\Total<public>:i64=Spin(2000000)
        \\Seen<public>:i64=Count
    );
    const fuel = 1 << 32;
    // Stored, the witness is full long before the loop ends, in both machines alike.
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    // Without reclamation the visits' states and tuples fill the pool.
    h.control.reclaim_floor = types.ControlStorage.reclaim_never;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.reclaim_never;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).failed.code);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, h.runtime.evaluate(program, fuel).failed.code);
    h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    var start = begun;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        // The last tuple is (2000000, 1999999).
        try std.testing.expectEqual(@as(i64, iterations * 10 + 1), x.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, iterations), x.get("Seen").?.integer);
        try std.testing.expect(x.reclaims > 1);
    }
    try std.testing.expect(actual.ok.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    for (reference.ok.aggregate_values, actual.ok.aggregate_values) |a, b| try std.testing.expectEqualDeep(a, b);
    // The report replays a second run a window at a time, exits included.
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Total\":20000001,\"Seen\":2000000}\n", out.buffered());
    std.debug.print("Loop{{}} visits=2000000 steps={d} reclaims={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ actual.ok.witness.count, actual.ok.reclaims, reference_ms, actual_ms, elapsedMs(start) });
    try budget(elapsedMs(begun) < 120_000);
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "a function returns from the innermost of five hundred conditionals and of five hundred regions" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const depth = 500;
    var text = build(std.testing.allocator);
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "var Cell:i64=0\nF(N:i64)<transacts>:i64=Block{");
    for (0..depth) |level| try text.print(std.testing.allocator, "If(N>{d},Block{{set Cell=Cell+1;", .{level});
    try text.appendSlice(std.testing.allocator, "Return(Cell*1000+N)");
    for (0..depth) |_| try text.appendSlice(std.testing.allocator, "},false)");
    try text.appendSlice(std.testing.allocator, ";0-N}\n");
    // Five hundred regions open at once: the Return commits every one of them, and a failure in
    // the caller afterwards still undoes all their writes.
    try text.appendSlice(std.testing.allocator, "G(N:i64)<transacts>:i64=");
    for (0..depth) |_| try text.appendSlice(std.testing.allocator, "Attempt(Block{set Cell=Cell+1;");
    try text.appendSlice(std.testing.allocator, "If(N>0,Return(Cell),false)");
    for (0..depth) |_| try text.appendSlice(std.testing.allocator, ";0},-1)");
    try text.appendSlice(std.testing.allocator, "\nH(N:i64)<transacts>:i64=Attempt(Block{G(N);Fail[\"undo\"];0},Cell)\n");
    try text.appendSlice(std.testing.allocator, "A<public>:i64=F(500)\nB<public>:i64=F(7)\nC<public>:i64=Cell\nD<public>:i64=G(1)\nE<public>:i64=G(0)\nI<public>:i64=H(1)\nJ<public>:i64=Cell");
    const r = try h.run(try h.compile(text.items), 1 << 24);
    const x = r.ok;
    const expected = [_]struct { []const u8, i64 }{
        // F(500) passes every test; F(7) stops at the eighth. G(1) returns from the innermost
        // region with all five hundred writes kept, G(0) leaves them one by one, and H's failure
        // restores the cell to what it was before its call of G.
        .{ "A", 500 * 1000 + 500 }, .{ "B", -7 }, .{ "C", 507 }, .{ "D", 1007 }, .{ "E", 0 }, .{ "I", 1507 }, .{ "J", 1507 },
    };
    for (expected) |entry| {
        if (x.get(entry[0]).?.integer != entry[1]) std.debug.print("{s}: expected {d}, found {d}\n", .{ entry[0], entry[1], x.get(entry[0]).?.integer });
        try std.testing.expectEqual(entry[1], x.get(entry[0]).?.integer);
    }
}

test "a mebibyte of text is read unit by unit and scalar by scalar in digest mode without an array of it" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // Sixteen bytes and ten scalar values, of every encoded length, 65,536 times over.
    const pattern = "abcd\u{E9}\u{96EA}\u{1F600}xyz";
    comptime std.debug.assert(pattern.len == 16);
    const repeats = 65_536;
    const bytes = pattern.len * repeats;
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "Text:string=\"");
    for (0..repeats) |_| try source.appendSlice(std.testing.allocator, pattern);
    // The state is a position, the sum of the code units and the sum of the code points: three
    // members a visit, none of which outlives it, and no string is built at all.
    try source.appendSlice(std.testing.allocator,
        \\"
        \\Step(S:tuple(i64,i64,i64))<computes>:tuple(i64,i64,i64)=tuple{S(0)+1,S(1)+Attempt(Text[S(0)].ToCodeUnit(),0),S(2)+Attempt(Text.ScalarAt[S(0)].ToCodePoint(),0)}
        \\Sum<public>:tuple(i64,i64,i64)=Iterate(Step,Text.Length,tuple{0,0,0})
        \\Tail<public>:[]char=For(I->C:Text,I>1048572,C)
        \\Cut<public>:i64=Attempt(Text.Slice[16,1048560].Length,0-1)
        \\
    );
    var unit_sum: i64 = 0;
    for (pattern) |byte| unit_sum += byte;
    var point_sum: i64 = 0;
    var view = std.unicode.Utf8View.initComptime(pattern).iterator();
    while (view.nextCodepoint()) |point| point_sum += point;
    const program = try h.compile(source.items);
    const fuel = 1 << 32;
    // Stored, the witness of a loop this long is full before it ends, in both machines alike.
    try std.testing.expectEqual(types.Diagnostic.Code.call_trace_limit, (try h.run(program, fuel)).failed.code);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    const begun = std.Io.Clock.awake.now(std.testing.io);
    var start = begun;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        const sum = x.elements(x.get("Sum").?).?;
        try std.testing.expectEqual(@as(i64, bytes), sum[0].integer);
        try std.testing.expectEqual(unit_sum * repeats, sum[1].integer);
        try std.testing.expectEqual(point_sum * repeats, sum[2].integer);
        const tail = x.elements(x.get("Tail").?).?;
        try std.testing.expectEqual(@as(usize, 3), tail.len);
        for (tail, "xyz") |unit, byte| try std.testing.expectEqualDeep(types.characterValue(types.Type.char, byte), unit);
        try std.testing.expectEqual(@as(i64, bytes - 32), x.get("Cut").?.integer);
        // Nothing the size of the text is kept: the members of the visits are reclaimed, so
        // what remains is what the last stretch left behind, and not one byte of string was
        // built, the megabyte-long slice included.
        try std.testing.expect(x.aggregate_values.len < types.ControlStorage.default_reclaim_floor + 64);
        try std.testing.expect(x.reclaims > 0);
        try std.testing.expectEqual(program.strings.len, x.program.strings.len);
    }
    try std.testing.expect(actual.ok.witness.count > types.limits.call_steps);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    // The visits built more members than the pool holds; what is left is less than one floor.
    try std.testing.expect(h.runtime.machine.control.reclaimed_members > types.limits.aggregate_elements);
    // The report replays a second run a window at a time and works every text operation out again.
    start = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    var expected: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"Sum\":[{d},{d},{d}],\"Tail\":[{{\"$char\":120}},{{\"$char\":121}},{{\"$char\":122}}],\"Cut\":{d}}}\n", .{ bytes, unit_sum * repeats, point_sum * repeats, bytes - 32 }), out.buffered());
    std.debug.print("text bytes={d} steps={d} steps/byte={d} members reclaimed={d} left={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ bytes, actual.ok.witness.count, actual.ok.witness.count / bytes, h.runtime.machine.control.reclaimed_members, actual.ok.aggregate_values.len, reference_ms, actual_ms, elapsedMs(start) });
    // Memory is constant in the length of the text; time must stay proportional to it.
    try budget(elapsedMs(begun) < 60_000);
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

/// A chain `C0 <- C1 <- ...` in which every class adds a field, every tenth a block clause, and
/// every constructor function delegates to the one above. Returns the milliseconds of the compile.
fn constructorChain(h: *harness.Harness, classes: usize) !u64 {
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try source.appendSlice(a, "C0:=class{\n  F0:i64\n  var Sum:i64=0\n  Block{set Self.Sum=Self.Sum+1}\n}\nK0<constructor>(A:i64)<transacts>:=C0{F0:=A}\n");
    var sum: i64 = 1;
    for (1..classes) |i| {
        try source.print(a, "C{d}:=class(C{d}){{\n  F{d}:i64={d}\n", .{ i, i - 1, i, i });
        if (i % 10 == 0) {
            try source.print(a, "  Block{{set Self.Sum=Self.Sum+{d}}}\n", .{i});
            sum += @intCast(i);
        }
        try source.print(a, "}}\nK{d}<constructor>(A:i64)<transacts>:=C{d}{{F{d}:=A+{d},K{d}<constructor>(A+1)}}\n", .{ i, i, i, i, i - 1 });
    }
    const last = classes - 1;
    const half = classes / 2;
    try source.print(a, "X:=K{d}(5)\nY:=K{d}(0)\nZ:=C{d}{{K{d}<constructor>(7)}}\n", .{ last, half, last, half });
    try source.print(a, "Deep<public>:i64=X.F0*1000000+X.F{d}*1000+X.F{d}\nSum<public>:i64=X.Sum\nMid<public>:i64=Y.F0*1000+Y.F{d}\nRest<public>:i64=Z.F0*1000000+Z.F{d}*1000+Z.F{d}\n", .{ half, last, half, half, last });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    const x = try h.run(program, 4_000_000);
    // Level `i` receives `A = 5 + (last - i)` and stores `A + i`: every field is `5 + last`.
    const every: i64 = @intCast(5 + last);
    try std.testing.expectEqual(every * 1_001_001, x.ok.get("Deep").?.integer);
    try std.testing.expectEqual(sum, x.ok.get("Sum").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(half * 1001)), x.ok.get("Mid").?.integer);
    // Delegating half way up leaves the fields below to their defaults.
    try std.testing.expectEqual(@as(i64, @intCast((7 + half) * 1_001_000 + last)), x.ok.get("Rest").?.integer);
    // One `object_new` per instance: three instances, never one per level.
    try std.testing.expectEqual(@as(usize, (classes + 2) * 2 + (half + 3)), x.ok.object_cells.len);
    std.debug.print("constructor chain classes={d} functions={d} template nodes={d} compile={d}ms\n", .{ classes, program.functions.len, program.function_nodes.len, compiled });
    return compiled;
}

test "a chain of two hundred classes whose constructor functions delegate upward" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const half = try constructorChain(h, 100);
    const full = try constructorChain(h, 200);
    // A constructor function carries the field expressions of every one it delegates through,
    // so the templates grow with the square of the depth. That is the known cost of building an
    // instance with one node; it must not be worse.
    try budget(full < 30_000);
    try budget(full <= 16 * @max(half, 5));
}

test "a hundred thousand instances are built through delegating constructor functions in digest mode" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const visits = 100_000;
    // Every tenth construction fails in the superclass's constructor function, after the
    // subclass's field value has been computed and counted: nothing of it may remain.
    const program = try h.compile(
        \\var Count:i64=0
        \\var Made:i64=0
        \\var Tried:i64=0
        \\Base:=class{
        \\  Id:i64
        \\  var Hits:i64=0
        \\  Block{set Made=Made+1}
        \\}
        \\MakeBase<constructor>(Id:i64)<transacts><decides>:=Base{Id:=Block{Q:=Quotient[Id,10];Require[Q*10!=Id];Id}}
        \\Leaf:=class(Base){
        \\  Extra:i64
        \\  Block{set Self.Hits=Self.Extra+Self.Id-Self.Id}
        \\}
        \\Try(V:i64)<transacts>:i64=Block{set Tried=Tried+1;V}
        \\MakeLeaf<constructor>(Id:i64,Extra:i64=3)<transacts><decides>:=Leaf{Extra:=Try(Extra),MakeBase<constructor>[Id]}
        \\Spin(N:i64)<transacts>:i64=Block{
        \\  var Sum:i64=0
        \\  Loop{
        \\    set Count=Count+1
        \\    set Sum=Sum+Attempt(MakeLeaf[Count].Hits,0)
        \\    If(Count>=N,Break(),false)
        \\  }
        \\  Sum
        \\}
        \\Total<public>:i64=Spin(100000)
        \\Built<public>:i64=Made
        \\Counted<public>:i64=Tried
    );
    const fuel = 1 << 32;
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    var start = begun;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    if (reference == .failed) std.debug.print("reference failed: {s}\n", .{reference.failed.message()});
    if (actual == .failed) std.debug.print("vm failed: {s}\n", .{actual.failed.message()});
    const kept = visits - visits / 10;
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        try std.testing.expectEqual(@as(i64, kept * 3), x.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, kept), x.get("Built").?.integer);
        // The count of the failed tenth was undone with the construction.
        try std.testing.expectEqual(@as(i64, kept), x.get("Counted").?.integer);
        // No instance outlives its visit, so a digest run reclaims every one of them.
        try std.testing.expectEqual(@as(usize, 0), x.object_cells.len);
    }
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    for (reference.ok.object_cells, actual.ok.object_cells) |x, y| try std.testing.expectEqualDeep(x.value, y.value);
    start = std.Io.Clock.awake.now(std.testing.io);
    // Nothing public names an instance at the end, so the report lists none.
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    try std.testing.expectEqualStrings("{\"Total\":270000,\"Built\":90000,\"Counted\":90000}\n", out.buffered());
    std.debug.print("constructors instances={d} steps={d} reclaims={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ kept, actual.ok.witness.count, actual.ok.reclaims, reference_ms, actual_ms, elapsedMs(start) });
    try budget(elapsedMs(begun) < 120_000);
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "five hundred nested modules take ten thousand qualified references, in time proportional to both" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    var totals: [2]u64 = undefined;
    for ([_]usize{ 5, 10 }, &totals) |tops, *total| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        // `tops` public modules, each with seven modules of six: 50 modules per top one. Every
        // leaf has a value, a cell and a function that both machines call.
        const mids = 7;
        const leaves = 6;
        for (0..tops) |t| {
            try source.print(std.testing.allocator, "T{d}<public>:=module{{\nBase:i64={d}\n", .{ t, t });
            for (0..mids) |m| {
                try source.print(std.testing.allocator, "M{d}<public>:=module{{\nShift:i64=Base+{d}\n", .{ m, m });
                for (0..leaves) |l| {
                    try source.print(std.testing.allocator, "L{d}<public>:=module{{\nV<public>:i64=Shift*10+{d}\nvar C<public>:i64=0\nF<public>(X:i64)<transacts>:i64=Block{{set C=C+1;X+V}}\n}}\n", .{ l, l });
                }
                try source.appendSlice(std.testing.allocator, "}\n");
            }
            try source.appendSlice(std.testing.allocator, "}\n");
        }
        // A chain as deep as modules may nest, each level reading the one around it.
        const depth = types.limits.module_depth;
        try source.appendSlice(std.testing.allocator, "D0<public>:=module{\nW0<public>:i64=1\n");
        for (1..depth) |level| try source.print(std.testing.allocator, "D{d}<public>:=module{{\nW{d}<public>:i64=W{d}+1\n", .{ level, level, level - 1 });
        for (0..depth) |_| try source.appendSlice(std.testing.allocator, "}\n");
        try source.appendSlice(std.testing.allocator, "Deepest<public>:i64=D0");
        for (1..depth) |level| try source.print(std.testing.allocator, ".D{d}", .{level});
        try source.print(std.testing.allocator, ".W{d}\n", .{depth - 1});
        const references = tops * 500;
        var expected: i64 = 0;
        for (0..references) |r| {
            const t = r % tops;
            const m = (r / tops) % mids;
            const l = (r / (tops * mids)) % leaves;
            try source.print(std.testing.allocator, "R{d}:i64=T{d}.M{d}.L{d}.V+T{d}.M{d}.L{d}.F({d})\n", .{ r, t, m, l, t, m, l, r });
            const value: i64 = @intCast((t + m) * 10 + l);
            if (r + 1 == references) expected = 2 * value + @as(i64, @intCast(r));
        }
        try source.print(std.testing.allocator, "Total<public>:i64=R{d}\n", .{references - 1});
        const inputs = [_]modules.Input{.{ .path = "main.forb", .source = source.items }};
        const start = std.Io.Clock.awake.now(std.testing.io);
        const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if (bundled == .failed) std.debug.print("nested scale: {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.diagnostic.span.start });
        const program = bundled.ok;
        const compiled = elapsedMs(start);
        try std.testing.expectEqual(tops * (1 + mids + mids * leaves) + depth, program.nested.len);
        // Each machine admits the whole program before it runs it, so each time includes one admission.
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 4_000_000);
        const referenced = elapsedMs(start);
        const actual = h.runtime.evaluate(program, 4_000_000);
        total.* = elapsedMs(start);
        std.debug.print("nested modules={d} qualified references={d} source={d}B compile={d}ms reference={d}ms vm={d}ms total={d}ms\n", .{ program.nested.len, 2 * references, source.items.len, compiled, referenced - compiled, total.* - referenced, total.* });
        try std.testing.expectEqual(expected, reference.ok.get("Total").?.integer);
        try std.testing.expectEqual(expected, actual.ok.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, depth), actual.ok.get("Deepest").?.integer);
        try std.testing.expectEqual(@as(usize, references + 2), program.bindings.len);
    }
    // Twice the modules and twice the references: a cost in their product would be four times.
    try budget(totals[1] < 5000);
    try budget(totals[1] < 3 * totals[0] + 250);
}

test "privacy of eight thousand chained classes beside a nested module is admitted in one pass" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const vm = @import("vm.zig");
    var times: [2]u64 = undefined;
    for ([_]usize{ 4000, 8000 }, &times) |count, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        // Each class names the next: information that travels against the order of the
        // catalogue, which a pass per step would make quadratic.
        for (0..count) |index| {
            if (index + 1 < count) try source.print(std.testing.allocator, "c{d}:=class{{n:c{d}}}\n", .{ index, index + 1 }) else try source.print(std.testing.allocator, "c{d}:=class{{n:i64=0}}\n", .{index});
        }
        try source.appendSlice(std.testing.allocator, "M:=module{last:=class{x:i64=0}}\nTop<public>:i64=1\n");
        const inputs = [_]modules.Input{.{ .path = "main.forb", .source = source.items }};
        var program = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs }).ok;
        // Forged: the last class of the chain holds the nested module's private class.
        const fields = try std.testing.allocator.dupe(types.Field, program.fields);
        defer std.testing.allocator.free(fields);
        var last: ?types.Type = null;
        var tail: ?usize = null;
        var name: [16]u8 = undefined;
        const wanted = try std.fmt.bufPrint(&name, "c{d}", .{count - 1});
        for (program.definitions, 0..) |item, index| if (item == .class) {
            if (std.mem.eql(u8, item.class.name.text(program.source), wanted)) tail = item.class.fields.start;
            if (std.mem.eql(u8, item.class.name.text(program.source), "last")) last = @fromBackingInt(@intCast(@as(u16, @intCast(index)) + 4));
        };
        fields[tail.?].value_type = last.?;
        program.fields = fields;
        const start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.validate(program, h.values.len);
        const referenced = elapsedMs(start);
        const lowered = bytecode.lower(program, &h.runtime.instructions);
        const verified = vm.verify(lowered.ok, &h.runtime.machine.register_types);
        time.* = elapsedMs(start);
        std.debug.print("chained classes={d} evaluator admission={d}ms vm admission={d}ms\n", .{ count, referenced, time.* - referenced });
        // Nothing here is public, so nothing escapes: both admit, and agree.
        try std.testing.expect(reference == null and verified != .failed);
    }
    try budget(times[1] < 1000);
    try budget(times[1] < 3 * times[0] + 100);
}

/// A long run in digest mode through both machines, required to agree on everything a run
/// leaves behind, with the report a replay of a second run admits. Prints the three times.
const LongRun = struct {
    reference: evaluator.Execution,
    actual: evaluator.Execution,
    report: []const u8,
};
fn longRun(h: *harness.Harness, again: *trace_replay.Storage, name: []const u8, program: types.Program, fuel: u64, into: []u8) !LongRun {
    return longRunAt(h, again, name, program, fuel, types.ControlStorage.default_reclaim_floor, into);
}
/// `longRun` with the host's reclamation floor `floor`.
fn longRunAt(h: *harness.Harness, again: *trace_replay.Storage, name: []const u8, program: types.Program, fuel: u64, floor: u32, into: []u8) !LongRun {
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    h.control.reclaim_floor = floor;
    h.runtime.machine.control.reclaim_floor = floor;
    again.control.reclaim_floor = floor;
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    if (reference == .failed) std.debug.print("{s}: {s}\n", .{ name, reference.failed.message() });
    try std.testing.expect(reference == .ok and actual == .ok);
    const a = reference.ok;
    const b = actual.ok;
    try std.testing.expectEqualDeep(a.witness, b.witness);
    try std.testing.expectEqual(a.reclaims, b.reclaims);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    try std.testing.expectEqual(h.control.reclaimed_bytes, h.runtime.machine.control.reclaimed_bytes);
    try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
    try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
    try std.testing.expectEqual(a.program.strings.len, b.program.strings.len);
    try std.testing.expectEqual(a.object_cells.len, b.object_cells.len);
    for (a.aggregate_values, b.aggregate_values) |x, y| try std.testing.expectEqualDeep(x, y);
    for (a.object_cells, b.object_cells) |x, y| try std.testing.expectEqualDeep(x, y);
    for (a.values, b.values, 0..) |x, y, index| if (b.active(index)) try std.testing.expectEqualDeep(x, y);
    start = std.Io.Clock.awake.now(std.testing.io);
    var out = std.Io.Writer.fixed(into);
    _ = try reporting.writeReplayed(&out, b, again.producer(program, fuel), true, .{});
    const report_ms = elapsedMs(start);
    std.debug.print("{s}: reclaims={d} freed members={d} bytes={d} cells={d} left members={d} bytes={d} cells={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ name, b.reclaims, h.control.reclaimed_members, h.control.reclaimed_bytes, h.control.reclaimed_cells, b.aggregate_values.len, b.program.strings.len, b.object_cells.len, reference_ms, actual_ms, report_ms });
    return .{ .reference = a, .actual = b, .report = out.buffered() };
}
/// The diagnostic both machines stop with when the run does not reclaim.
fn unreclaimed(h: *harness.Harness, program: types.Program, fuel: u64) !types.Diagnostic.Code {
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    h.control.reclaim_floor = types.ControlStorage.reclaim_never;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.reclaim_never;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(program, fuel);
    try std.testing.expect(reference == .failed and actual == .failed);
    try std.testing.expectEqualDeep(reference.failed, actual.failed);
    return actual.failed.code;
}

test "ten million visits that each build a string and keep its length run in a string pool they would fill" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const program = try h.compile("var Sum:i64=0\nStep(S:i64)<transacts>:i64=Block{T:=\"{S}\";set Sum=Sum+T.Length;S+1}\nTotal<public>:i64=Iterate(Step,10000000,0)\nLengths<public>:i64=Sum");
    const fuel = 1 << 32;
    // The digits of 0 to 9,999,999: more bytes than the pool holds.
    const digits = 10 + 90 * 2 + 900 * 3 + 9000 * 4 + 90000 * 5 + 900000 * 6 + 9000000 * 7;
    comptime std.debug.assert(digits > types.limits.string_bytes);
    try std.testing.expectEqual(types.Diagnostic.Code.string_limit, try unreclaimed(h, program, fuel));
    var buffer: [128]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "strings 10000000", program, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":10000000,\"Lengths\":68888890}\n", run.report);
    try std.testing.expectEqual(@as(i64, digits), run.actual.get("Lengths").?.integer);
    // No string outlives its visit: the pool ends as the program's literals left it.
    try std.testing.expectEqual(program.strings.len, run.actual.program.strings.len);
    try std.testing.expect(run.actual.reclaims >= digits / (types.limits.string_bytes / 8) and h.control.reclaimed_bytes >= digits);
    try budget(elapsedMs(begun) < 60_000);
    var forged = run.actual;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "ten million visits that each create an instance, write it, read it and drop it run in cells they would fill" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const program = try h.compile("P:=class{var N:i64}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};set X.N=X.N+1;X.N}\nTotal<public>:i64=Iterate(Step,10000000,0)");
    const fuel = 1 << 32;
    comptime std.debug.assert(2 * 10_000_000 > 4 * types.limits.object_cells);
    try std.testing.expectEqual(types.Diagnostic.Code.object_limit, try unreclaimed(h, program, fuel));
    var buffer: [128]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "instances 10000000", program, fuel, &buffer);
    // Nothing is left to list: an instance no binding reaches is not part of the result.
    try std.testing.expectEqualStrings("{\"Total\":10000000}\n", run.report);
    try std.testing.expectEqual(@as(usize, 0), run.actual.object_cells.len);
    try std.testing.expectEqual(@as(u64, 20_000_000), h.control.reclaimed_cells);
    try std.testing.expectEqual(@as(u64, 20_000_000 / (types.limits.object_cells / 8) + 1), run.actual.reclaims);
    try budget(elapsedMs(begun) < 60_000);
    var forged = run.actual;
    forged.reclaims -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "a window of the last hundred of five million instances stays in an array cell" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // The loop runs inside one region, which holds a record for the cell throughout: what a
    // rollback would restore is the window the loop began with.
    const program = try h.compile("P:=class{var N:i64}\nvar Ring:[]P=array{}\nFill(S:i64)<transacts>:i64=Block{set Ring=Ring+array{P{N:=S}};S+1}\nStep(S:i64)<transacts><decides>:i64=Block{X:=P{N:=S};set Ring[S-(S/100)*100]=X;S+1}\nF:function<transacts><decides>(tuple(i64),i64)=Step\nReady:i64=Iterate(Fill,100,0)\nTotal<public>:i64=Attempt(Iterate(F,5000000,Ready),-1)\nAdd(S:tuple(i64,i64))<transacts>:tuple(i64,i64)=tuple{S(0)+1,S(1)+Attempt(Ring[S(0)].N,0)}\nWindow<public>:i64=Iterate(Add,100,tuple{0,0})(1)");
    const fuel = 1 << 33;
    // Each visit copies the array of a hundred, so without reclamation the members run out first.
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, try unreclaimed(h, program, fuel));
    const buffer = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(buffer);
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "window 100 of 5000000", program, fuel, buffer);
    try std.testing.expectEqual(@as(i64, 5_000_100), run.actual.get("Total").?.integer);
    // The cell holds the instances made by the last hundred visits.
    try std.testing.expectEqual(@as(i64, 100 * 5_000_000 + 4950), run.actual.get("Window").?.integer);
    // The hundred that the cell holds, and the hundred it began with: an earlier call from
    // the root made those, so they lie below everything this call can reclaim.
    try std.testing.expectEqual(@as(usize, 2 * 200), run.actual.object_cells.len);
    // Only the private `Ring` reaches an instance, so a public report lists none of them.
    try std.testing.expectEqualStrings("{\"Total\":5000100,\"Window\":500004950}\n", run.report);
    try std.testing.expect(run.actual.reclaims > 10);
    try budget(elapsedMs(begun) < 120_000);
    // A window that is not the one the run kept: the instance a cell names moved or went.
    const cells = try std.testing.allocator.dupe(@import("source_state.zig").Cell, run.actual.object_cells);
    defer std.testing.allocator.free(cells);
    cells[cells.len - 1].value.integer -= 1;
    var forged = run.actual;
    forged.object_cells = cells;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "a list of a hundred thousand nodes is built once and walked a hundred times without being examined in vain" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // Each walk runs inside one region and hops through the fields; every node stays in use.
    const program = try h.compile("Node:=class{Value:i64,var Next:option(Node)}\nPush(S:option(Node))<transacts>:option(Node)=option{Node{Value:=1,Next:=S}}\nHead:option(Node)=Iterate(Push,100000,option{})\nHop(S:tuple(Node,i64))<transacts><decides>:tuple(Node,i64)=Block{N:=S(0).Next?;tuple{N,S(1)+N.Value}}\nF:function<transacts><decides>(tuple(tuple(Node,i64)),tuple(Node,i64))=Hop\nOnce(K:i64)<transacts>:i64=K+Attempt(Block{H:=Head?;Iterate(F,99999,tuple{H,1})(1)},-1)\nTotal<public>:i64=Iterate(Once,100,0)");
    const fuel = 1 << 32;
    const buffer = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "list 100000 walked 100 times", program, fuel, buffer);
    try std.testing.expectEqual(@as(i64, 100 * 100_000), run.actual.get("Total").?.integer);
    // Every node is still there, and the walks' tuples are not.
    try std.testing.expectEqual(@as(usize, 3 * 100_000), run.actual.object_cells.len);
    try std.testing.expectEqual(@as(u64, 0), h.control.reclaimed_cells);
    try std.testing.expect(h.control.reclaimed_members > 4 * types.limits.aggregate_elements);
    // Each reclamation reads all the cells, as roots, and frees none of them: the wait it
    // earns keeps their number at what the members alone ask for.
    try std.testing.expect(run.actual.reclaims < 2 * (20_000_000 / types.ControlStorage.default_reclaim_floor) + 8);
    // Only the private `Head` reaches the nodes, so a public report lists none of them.
    try std.testing.expectEqualStrings("{\"Total\":10000000}\n", run.report);
    try budget(elapsedMs(begun) < 120_000);
}

test "a string that grows and a list that grows still stop at their limits, alike in both machines" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const fuel = 1 << 32;
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    for ([_][]const u8{
        "Grow(S:string)<computes>:string=S+\"0123456789abcdef\"\nAll<public>:i64=Iterate(Grow,5000000,\"\").Length",
        "Node:=class{Value:i64,var Next:option(Node)}\nPush(S:option(Node))<transacts>:option(Node)=option{Node{Value:=1,Next:=S}}\nHead<public>:option(Node)=Iterate(Push,2000000,option{})",
    }, [_]types.Diagnostic.Code{ .string_limit, .object_limit }) |source, limit| {
        const program = try h.compile(source);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const actual = h.runtime.evaluate(program, fuel);
        std.debug.print("accumulating {s} reclaims={d} total={d}ms\n", .{ @tagName(limit), h.runtime.machine.control.reclaims, elapsedMs(start) });
        try std.testing.expectEqual(limit, reference.failed.code);
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
        // The attempts to make room are spaced by what they cost: a handful for the whole store.
        try std.testing.expectEqual(h.control.reclaims, h.runtime.machine.control.reclaims);
        try std.testing.expect(h.control.reclaims > 0 and h.control.reclaims < 64);
        try budget(elapsedMs(start) < 60_000);
    }
}

// The class machinery and the catalogue at the size of a real program: every lookup below was a
// scan of all the slots, all the definitions or all the globals, so the whole was their square.

/// A bound on each compile below, in milliseconds: about ten times what it takes, and a
/// small part of what it took while the lookups were scans.
const scale_bound_ms: u64 = 1500;

fn scaleClasses(source: *std.ArrayList(u8), classes: usize, methods: usize, shared: bool) !void {
    const allocator = std.testing.allocator;
    for (0..classes) |i| {
        try source.print(allocator, "C{d}:=class{{\n  V:i64={d}\n", .{ i, i });
        // `shared` gives every class the same ten names (as `Update` or `Name` are everywhere
        // in a program); otherwise each class has names of its own.
        for (0..methods) |j| {
            if (shared) try source.print(allocator, "  M{d}()<transacts>:i64=Self.V+{d}\n", .{ j, j }) else try source.print(allocator, "  M{d}x{d}()<transacts>:i64=Self.V+{d}\n", .{ i, j, j });
        }
        try source.appendSlice(allocator, "}\n");
    }
    for (0..classes) |i| {
        if (shared) try source.print(allocator, "O{d}:C{d}=C{d}{{}}\nR{d}:i64=O{d}.M{d}()\n", .{ i, i, i, i, i, i % methods }) else try source.print(allocator, "O{d}:C{d}=C{d}{{}}\nR{d}:i64=O{d}.M{d}x{d}()\n", .{ i, i, i, i, i, i, i % methods });
    }
}

fn scaleTuples(source: *std.ArrayList(u8), tuples: usize) !void {
    const allocator = std.testing.allocator;
    const kinds = [_][]const u8{ "i64", "string", "logic", "float" };
    const values = [_][]const u8{ "1", "\"a\"", "true", "1.5" };
    // Seven elements of four types each: every tuple type below is a different one.
    for (0..tuples) |i| {
        try source.print(allocator, "T{d}:tuple(", .{i});
        var digits = i;
        for (0..7) |place| {
            try source.print(allocator, "{s}{s}", .{ if (place == 0) "" else ",", kinds[digits % 4] });
            digits /= 4;
        }
        try source.appendSlice(allocator, ")=tuple{");
        digits = i;
        for (0..7) |place| {
            try source.print(allocator, "{s}{s}", .{ if (place == 0) "" else ",", values[digits % 4] });
            digits /= 4;
        }
        try source.appendSlice(allocator, "}\n");
    }
}

test "three thousand classes of ten methods and seven thousand tuple types compile in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const classes = 3000;
    const methods = 10;
    // The catalogue holds 16,384 definitions: the classes, these tuples and a few structural types.
    const tuples = 7_000;
    var slowest: u64 = 0;
    for ([_]bool{ true, false }) |shared| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try scaleClasses(&source, classes, methods, shared);
        try scaleTuples(&source, tuples);
        try source.print(std.testing.allocator, "Low<public>:i64=R7\nHigh<public>:i64=R{d}\nLast<public>:i64=T{d}(0)\n", .{ classes - 1, tuples - tuples % 4 - 4 });
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        const compiled = elapsedMs(start);
        slowest = @max(slowest, compiled);
        try std.testing.expectEqual(@as(usize, classes * methods), program.slots.len);
        try std.testing.expect(program.functions.len >= classes * methods);
        try std.testing.expect(program.definitions.len >= classes + tuples);
        const run = h.runtime.evaluate(program, 4_000_000);
        if (run == .failed) std.debug.print("scale run: {s}\n", .{run.failed.message()});
        std.debug.print("classes={d} methods={d} shared names={} tuples={d} source={d}B definitions={d} compile={d}ms total={d}ms\n", .{ classes, program.slots.len, shared, tuples, source.items.len, program.definitions.len, compiled, elapsedMs(start) });
        // C7.M7 is 7 + 7; the last class calls method 2999 % 10 = 9 on V = 2999.
        try std.testing.expectEqual(@as(i64, 14), run.ok.get("Low").?.integer);
        try std.testing.expectEqual(@as(i64, classes - 1 + (classes - 1) % methods), run.ok.get("High").?.integer);
    }
    // Scanning every slot for every method call and declaration, and every definition for
    // every tuple type, took tens of seconds here; indexed, it is a fraction of one.
    try budget(slowest < scale_bound_ms);
}

test "twenty thousand functions that each read a global of their own, and two thousand specializations, compile in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 20_000;
    const generics = 1000;
    for (0..count) |i| try source.print(std.testing.allocator, "G{d}:i64={d}\nF{d}(N:i64)<computes>:i64=N+G{d}\n", .{ i, i, i, i });
    // Iterate keeps every function a published runtime function, whose body names its global.
    for (0..count) |i| try source.print(std.testing.allocator, "B{d}:i64=Iterate(F{d},1,0)\n", .{ i, i });
    // A thousand generic functions, each specialized twice.
    for (0..generics) |i| try source.print(std.testing.allocator, "Id{d}[T:type](X:T)<computes>:T{{X}}\n", .{i});
    for (0..generics) |i| try source.print(std.testing.allocator, "S{d}:i64=Id{d}[i64]({d})\nW{d}:string=Id{d}[string](\"w\")\n", .{ i, i, i, i, i });
    try source.print(std.testing.allocator, "Total<public>:i64=B{d}+S{d}\n", .{ count - 1, generics - 1 });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    try std.testing.expect(program.functions.len >= count and program.globals.len >= count);
    const run = h.runtime.evaluate(program, 4_000_000);
    if (run == .failed) std.debug.print("scale run: {s}\n", .{run.failed.message()});
    std.debug.print("functions={d} globals={d} specializations={d} source={d}B compile={d}ms total={d}ms\n", .{ program.functions.len, program.globals.len, 2 * generics, source.items.len, compiled, elapsedMs(start) });
    try std.testing.expectEqual(@as(i64, count - 1 + generics - 1), run.ok.get("Total").?.integer);
    try budget(compiled < scale_bound_ms);
}

test "two thousand instantiations of fifty parametric classes are made once each, found again and dispatched" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const templates = 50;
    const scalars = [_][]const u8{ "i64", "logic", "string", "float" };
    // Forty argument lists: every scalar, six shapes over each, and every pair of scalars.
    var lists: [40][32]u8 = undefined;
    var lengths: [40]usize = undefined;
    var count: usize = 0;
    for ([_][]const u8{ "{s}", "[]{s}", "option({s})", "[][]{s}", "map(i64,{s})", "tuple({s},i64,i64)" }) |shape| {
        for (scalars) |scalar| {
            var out = std.Io.Writer.fixed(&lists[count]);
            inline for (.{ "{s}", "[]{s}", "option({s})", "[][]{s}", "map(i64,{s})", "tuple({s},i64,i64)" }) |known| {
                if (std.mem.eql(u8, shape, known)) try out.print(known, .{scalar});
            }
            lengths[count] = out.buffered().len;
            count += 1;
        }
    }
    for (scalars) |first| for (scalars) |second| {
        lengths[count] = (try std.fmt.bufPrint(&lists[count], "tuple({s},{s})", .{ first, second })).len;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 40), count);
    for (0..templates) |t| try source.print(std.testing.allocator, "T{d}[A:type]:=class{{\n  V:option(A)=option{{}}\n  Id()<transacts>:i64={d}\n  Has()<transacts>:logic=Self.V.IsSet\n}}\n", .{ t, t });
    // Each type is named twice where it is first made, and a third time in `Again`.
    for (0..templates) |t| for (0..count) |list| {
        const arguments = lists[list][0..lengths[list]];
        try source.print(std.testing.allocator, "X{d}_{d}:T{d}[{s}]=T{d}[{s}]{{}}\n", .{ t, list, t, arguments, t, arguments });
    };
    try source.appendSlice(std.testing.allocator, "Again()<transacts>:i64=0");
    for (0..templates) |t| {
        const arguments = lists[(t * 7) % count][0..lengths[(t * 7) % count]];
        try source.print(std.testing.allocator, "+T{d}[{s}]{{}}.Id()+X{d}_{d}.Id()+If(X{d}_{d}.Has(),1000,0)", .{ t, arguments, t, (t * 3) % count, t, (t * 11) % count });
    }
    try source.appendSlice(std.testing.allocator, "\nTotal<public>:i64=Again()\n");
    var start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compile_ms = elapsedMs(start);
    var made: usize = 0;
    for (program.definitions) |item| made += @intFromBool(item == .class and item.class.arguments != null);
    try std.testing.expectEqual(@as(usize, templates * 40), made);
    // One slot and one dispatch entry for each method of each instantiation.
    try std.testing.expectEqual(@as(usize, templates * 40 * 2), program.slots.len);
    try std.testing.expectEqual(@as(usize, templates * 40 * 2), program.dispatch.len);
    start = std.Io.Clock.awake.now(std.testing.io);
    const x = (try h.run(program, 64_000_000)).ok;
    // Twice the sum of the template numbers: no instance holds a value.
    try std.testing.expectEqual(@as(i64, templates * (templates - 1)), x.get("Total").?.integer);
    std.debug.print("instantiations={d} definitions={d} source={d} bytes compile={d}ms both machines and reports={d}ms\n", .{ made, program.definitions.len, source.items.len, compile_ms, elapsedMs(start) });
    // Naming a type that exists is a lookup: the compile stays far from the square of the count.
    try budget(compile_ms < 30_000);
}

test "a five hundred deep list of a parametric node is built and summed in digest mode" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const program = try h.compile(
        \\Node[T:type]:=class{
        \\  Value:T
        \\  Next:option(Node[T])=option{}
        \\}
        \\Build(N:i64,Tail:option(Node[i64]))<transacts>:option(Node[i64])=If(N==0,Tail,Build(N-1,option{Node[i64]{Value:=N,Next:=Tail}}))
        \\Sum(L:option(Node[i64]))<transacts>:i64=Attempt(Block{H:=L?;H.Value+Sum(H.Next)},0)
        \\Total<public>:i64=Sum(Build(500,option{}))
    );
    const fuel = 4_000_000;
    // Stored first: both machines agree step by step and the report replays the run.
    const stored = (try h.run(program, fuel)).ok;
    try std.testing.expectEqual(@as(i64, 125250), stored.get("Total").?.integer);
    try std.testing.expectEqual(@as(usize, 1500), stored.object_cells.len);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(program, fuel);
    try std.testing.expectEqual(@as(i64, 125250), reference.ok.get("Total").?.integer);
    try std.testing.expectEqual(@as(i64, 125250), actual.ok.get("Total").?.integer);
    try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
    try std.testing.expectEqual(@as(usize, 0), reference.ok.call_steps.len + actual.ok.call_steps.len);
    try std.testing.expectEqual(@as(usize, 1500), actual.ok.object_cells.len);
    const buffer = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(buffer);
    var out = std.Io.Writer.fixed(buffer);
    _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
    // No binding holds the list, so no instance is listed (the stored report says the same).
    try std.testing.expectEqualStrings("{\"Total\":125250}\n", out.buffered());
    var forged = actual.ok;
    forged.witness.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

test "more bindings of generic calls than there are type slots are no declarations of types" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // The declaration pre-pass keeps a table of the classes it leaves for later (RFC-0073). A
    // binding is not one of them, however it is spelled and however many there are.
    const bindings = types.limits.user_types + 1;
    try source.appendSlice(std.testing.allocator, "Id[T:type](X:T)<computes>:T{X}\n");
    for (0..bindings) |i| try source.print(std.testing.allocator, "B{d}:=Id[i64]({d})\n", .{ i, i });
    try source.print(std.testing.allocator, "Total<public>:i64=B{d}\n", .{bindings - 1});
    const program = try h.compile(source.items);
    try std.testing.expectEqual(@as(usize, 2), program.definitions.len);
    try std.testing.expectEqual(@as(u32, 0), h.front.late_count);
    const x = (try h.run(program, 64_000_000)).ok;
    try std.testing.expectEqual(@as(i64, bindings - 1), x.get("Total").?.integer);
}

test "five hundred instantiations of templates in nested modules, each named by its path, cost in proportion to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const modules = @import("modules.zig");
    const scalars = [_][]const u8{ "i64", "logic", "string", "float" };
    const shapes = [_][]const u8{ "", "[]", "[][]", "option", "map" };
    var totals: [2]u64 = undefined;
    for ([_]usize{ 25, 50 }, &totals) |templates, *total| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        // One template in a module of a module, for each `templates`; twenty argument lists.
        for (0..templates) |t| try source.print(std.testing.allocator, "K{d}<public>:=module{{\nM<public>:=module{{\nBox<public>[A:type]:=class{{\n  V:option(A)=option{{}}\n  Id<public>()<transacts>:i64={d}\n}}\n}}\n}}\n", .{ t, t });
        var lists: [20][24]u8 = undefined;
        var lengths: [20]usize = undefined;
        var count: usize = 0;
        for (shapes, 0..) |shape, kind| for (scalars) |scalar| {
            lengths[count] = (switch (kind) {
                0, 1, 2 => try std.fmt.bufPrint(&lists[count], "{s}{s}", .{ shape, scalar }),
                3 => try std.fmt.bufPrint(&lists[count], "option({s})", .{scalar}),
                else => try std.fmt.bufPrint(&lists[count], "map(i64,{s})", .{scalar}),
            }).len;
            count += 1;
        };
        // Each type is named twice by its path where it is first made, and once more below.
        for (0..templates) |t| for (0..count) |list| {
            const arguments = lists[list][0..lengths[list]];
            try source.print(std.testing.allocator, "X{d}_{d}:K{d}.M.Box[{s}]=K{d}.M.Box[{s}]{{}}\n", .{ t, list, t, arguments, t, arguments });
        };
        try source.appendSlice(std.testing.allocator, "Again()<transacts>:i64=0");
        for (0..templates) |t| {
            const arguments = lists[(t * 7) % count][0..lengths[(t * 7) % count]];
            try source.print(std.testing.allocator, "+K{d}.M.Box[{s}]{{}}.Id()+X{d}_{d}.Id()", .{ t, arguments, t, (t * 3) % count });
        }
        try source.appendSlice(std.testing.allocator, "\nTotal<public>:i64=Again()\n");
        const inputs = [_]modules.Input{.{ .path = "main.forb", .source = source.items }};
        const start = std.Io.Clock.awake.now(std.testing.io);
        const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if (bundled == .failed) std.debug.print("nested instantiations: {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.diagnostic.span.start });
        const program = bundled.ok;
        const compiled = elapsedMs(start);
        var made: usize = 0;
        for (program.definitions) |item| made += @intFromBool(item == .class and item.class.arguments != null);
        try std.testing.expectEqual(templates * count, made);
        try std.testing.expectEqual(2 * templates, program.nested.len);
        // Each machine admits the whole program, origins and reach included, before it runs it.
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 64_000_000);
        const referenced = elapsedMs(start);
        const actual = h.runtime.evaluate(program, 64_000_000);
        total.* = elapsedMs(start);
        std.debug.print("nested instantiations={d} qualified references={d} source={d}B compile={d}ms reference={d}ms vm={d}ms total={d}ms\n", .{ made, 2 * made + templates, source.items.len, compiled, referenced - compiled, total.* - referenced, total.* });
        const expected: i64 = @intCast(templates * (templates - 1));
        try std.testing.expectEqual(expected, reference.ok.get("Total").?.integer);
        try std.testing.expectEqual(expected, actual.ok.get("Total").?.integer);
    }
    // Twice the instantiations and twice the references: a cost in their square would be four times.
    try budget(totals[1] < 5000);
    try budget(totals[1] < 3 * totals[0] + 250);
}

test "the shadowing check costs each declaration the same however many names the module has" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // RFC-0076 (D5): every parameter, local and loop variable is held against every name of
    // the module by hashed lookups, so twice the bindings and functions take about twice the
    // time, not four times. Each function declares two parameters, two locals and a `For`
    // variable; none of them is the name of a binding or of a function.
    var times: [2]u64 = undefined;
    for ([_]usize{ 4000, 8000 }, &times) |count, *time| {
        source.clearRetainingCapacity();
        for (0..count) |i| try source.print(std.testing.allocator, "G{d}:i64={d}\nF{d}(N:i64,M:i64)<computes>:i64=Block{{P:=N+G{d};Q:=For(K:1..2,K+M);P+Q.Length}}\n", .{ i, i, i, i });
        try source.print(std.testing.allocator, "Total<public>:i64=F{d}(1,2)\n", .{count - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        try std.testing.expect(program.functions.len >= count);
        const run = h.runtime.evaluate(program, 4_000_000);
        if (run == .failed) std.debug.print("scale run: {s}\n", .{run.failed.message()});
        try std.testing.expectEqual(@as(i64, @intCast(1 + count - 1 + 2)), run.ok.get("Total").?.integer);
        // The last declaration is checked against all of them: a clash with the first binding is found.
        try source.print(std.testing.allocator, "Late(G0:i64)<computes>:i64=G0\n", .{});
        try std.testing.expectEqual(types.Diagnostic.Code.shadowed_name, h.front.compile(source.items).failed.code);
    }
    std.debug.print("shadowing check: 4000 functions {d}ms, 8000 functions {d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < scale_bound_ms * 2);
    // Linear with room for noise; a scan of the bindings per declaration would be four times.
    try budget(times[1] <= times[0] * 3 + 50);
}

/// The least fuel with which both machines complete `program`: found on the VM, then the
/// reference is held to the same boundary. `control` modes are the caller's.
fn leastFuelOfBoth(h: *harness.Harness, program: types.Program, limit: u64) !u64 {
    var low: u64 = 0;
    var high: u64 = limit;
    try std.testing.expect(h.runtime.evaluate(program, high) == .ok);
    while (low < high) {
        const middle = low + (high - low) / 2;
        const result = h.runtime.evaluate(program, middle);
        if (result == .ok) {
            high = middle;
        } else {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            low = middle + 1;
        }
    }
    try std.testing.expect(evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, low) == .ok);
    const below = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, low - 1);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, below.failed.code);
    return low;
}

test "standard array forms over four hundred thousand elements cost fuel in exact proportion to the array" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var costs: [3]u64 = undefined;
    var times: [3]u64 = undefined;
    for ([_]i64{ 100_000, 200_000, 400_000 }, &costs, &times) |count, *cost, *time| {
        var text: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&text,
            \\Range:=native{{"std.range"}}
            \\Items:[]i64=Range({0d})
            \\Found<public>:i64=Attempt(Items.Find[{1d}],0-1)
            \\Fewer<public>:i64=Items.RemoveAllElements(7).Length
            \\Middle<public>:i64=Attempt(Items.Slice[1,{1d}],Items).Length
            \\Replaced<public>:i64=Items.ReplaceAll(array{{5,6}},array{{0}}).Length
            \\Twice<public>:i64=Concatenate(array{{Items,Items}}).Length
            \\Ends<public>:i64=Attempt(Items.Last[]+Items.Last[{1d}],0-1)
            \\
        , .{ count, count - 1 });
        const program = try h.compile(source);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 32);
        const actual = h.runtime.evaluate(program, 1 << 32);
        time.* = elapsedMs(start);
        for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
            try std.testing.expectEqual(count - 1, x.get("Found").?.integer);
            try std.testing.expectEqual(count - 1, x.get("Fewer").?.integer);
            try std.testing.expectEqual(count - 2, x.get("Middle").?.integer);
            try std.testing.expectEqual(count - 1, x.get("Replaced").?.integer);
            try std.testing.expectEqual(2 * count, x.get("Twice").?.integer);
            try std.testing.expectEqual(count - 1, x.get("Ends").?.integer);
        }
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        cost.* = try leastFuelOfBoth(h, program, 1 << 32);
    }
    std.debug.print("standard array forms: fuel {d} {d} {d}, both machines {d}ms {d}ms {d}ms\n", .{ costs[0], costs[1], costs[2], times[0], times[1], times[2] });
    // Every form is affine in the length: twice the elements, twice the difference, to the unit.
    try std.testing.expectEqual(2 * (costs[1] - costs[0]), costs[2] - costs[1]);
    // And a handful of units an element, for six forms and the array itself.
    try std.testing.expect(costs[2] < 16 * 400_000);
    try budget(times[2] < 10_000);
}

test "a native search of two hundred thousand elements costs a fraction of the guest loop, in fuel and in time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const head = "Range:=native{\"std.range\"}\nItems:[]i64=Range(200000)\nWanted:i64=199999\n";
    const native_source = head ++ "Where<public>:i64=Attempt(Items.Find[Wanted],0-1)\n";
    const guest_source = head ++ "Visit(S:tuple(i64,i64))<computes>:tuple(i64,i64)=tuple{S(0)+1,If(Attempt(Items[S(0)],0-1)==Wanted,S(0),S(1))}\nWhere<public>:i64=Iterate(Visit,Items.Length,tuple{0,0-1})(1)\n";
    // A loop this long outgrows a stored witness; both programs run in digest mode.
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    var fuel: [2]u64 = undefined;
    var time: [2]u64 = undefined;
    for ([_][]const u8{ native_source, guest_source }, &fuel, &time) |source, *cost, *elapsed| {
        const program = try h.compile(source);
        // The reference runs first: the report of the VM's run is what the test reads.
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 32);
        try std.testing.expectEqual(@as(i64, 199_999), reference.ok.get("Where").?.integer);
        var best: u64 = std.math.maxInt(u64);
        for (0..3) |_| {
            const start = std.Io.Clock.awake.now(std.testing.io);
            const actual = h.runtime.evaluate(program, 1 << 32);
            const nanoseconds: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds());
            best = @min(best, nanoseconds);
            try std.testing.expectEqual(@as(i64, 199_999), actual.ok.get("Where").?.integer);
        }
        elapsed.* = best;
        cost.* = try leastFuelOfBoth(h, program, 1 << 32);
    }
    std.debug.print("search of 200000: native fuel={d} {d}us, guest loop fuel={d} {d}us\n", .{ fuel[0], time[0] / 1000, fuel[1], time[1] / 1000 });
    // Both programs pay for the array; the search itself is two units an element natively.
    try std.testing.expect(fuel[1] > 2 * fuel[0]);
    try budget(time[1] > 2 * time[0]);
}

test "a megabyte of text is searched, replaced, cut and extended in fuel proportional to its length" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var costs: [3]u64 = undefined;
    for ([_]i64{ 1 << 18, 1 << 19, 1 << 20 }, &costs) |bytes, *cost| {
        var text: [1024]u8 = undefined;
        // "abc" and a two-byte scalar: five code units, so the lengths are multiples of five.
        const repeats = @divExact(bytes, 4);
        const length = repeats * 5;
        const source = try std.fmt.bufPrint(&text,
            \\Repeat:=native{{"std.repeat"}}
            \\Text:string=Repeat("abcé",{0d})
            \\Out<public>:i64=Text.ReplaceAll("bc","xyz").Length
            \\Same<public>:i64=Text.ReplaceAll("cb","xyz").Length
            \\Wide<public>:i64=Text.ReplaceAll("é","e").Length
            \\At<public>:i64=Attempt(Text.Find['c'],0-1)
            \\Miss<public>:i64=Attempt(Text.Find['q'],0-1)
            \\Cut<public>:i64=Attempt(Text.Remove[5,{1d}].Length,0-1)
            \\Split<public>:i64=Attempt(Text.Remove[4,{1d}].Length,0-1)
            \\Longer<public>:i64=Attempt(Text.Insert[{2d},"--"].Length,0-1)
            \\Tail<public>:char=Attempt(Text.Last[1],'?')
            \\
        , .{ repeats, length - 5, @divExact(length, 2) - @mod(@divExact(length, 2), 5) });
        const program = try h.compile(source);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 32);
        const actual = h.runtime.evaluate(program, 1 << 32);
        for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
            try std.testing.expectEqual(length + repeats, x.get("Out").?.integer);
            try std.testing.expectEqual(length, x.get("Same").?.integer);
            try std.testing.expectEqual(length - repeats, x.get("Wide").?.integer);
            try std.testing.expectEqual(@as(i64, 2), x.get("At").?.integer);
            try std.testing.expectEqual(@as(i64, -1), x.get("Miss").?.integer);
            try std.testing.expectEqual(@as(i64, 10), x.get("Cut").?.integer);
            // A cut that would split the scalar fails, however long the text.
            try std.testing.expectEqual(@as(i64, -1), x.get("Split").?.integer);
            try std.testing.expectEqual(length + 2, x.get("Longer").?.integer);
            try std.testing.expectEqualDeep(types.characterValue(types.Type.char, 0xC3), x.get("Tail").?);
        }
        try std.testing.expectEqual(reference.ok.program.strings.len, actual.ok.program.strings.len);
        cost.* = try leastFuelOfBoth(h, program, 1 << 32);
    }
    std.debug.print("standard text forms: fuel {d} {d} {d}\n", .{ costs[0], costs[1], costs[2] });
    // Twice the text, twice the difference; strings are charged in words, so to within a few.
    const first = costs[1] - costs[0];
    const second = costs[2] - costs[1];
    try std.testing.expect(second >= 2 * first - 64 and second <= 2 * first + 64);
    try std.testing.expect(costs[2] < 16 * (5 << 18));
}

test "two maps of twenty thousand entries are merged in fuel proportional to their entries, not to their product" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    var costs: [3]u64 = undefined;
    var bases: [3]u64 = undefined;
    for ([_]usize{ 5_000, 10_000, 20_000 }, &costs, &bases) |count, *cost, *base| {
        source.clearRetainingCapacity();
        // The second map shares the upper half of the first one's keys and adds as many new.
        try source.appendSlice(std.testing.allocator, "First:map(i64,i64)=map{");
        for (0..count) |key| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (key == 0) "" else ",", key, key });
        try source.appendSlice(std.testing.allocator, "}\nSecond:map(i64,i64)=map{");
        for (count / 2..count / 2 + count) |key| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (key == count / 2) "" else ",", key, key + 1_000_000 });
        try source.appendSlice(std.testing.allocator, "}\n");
        const without = source.items.len;
        try source.print(std.testing.allocator, "Both:map(i64,i64)=ConcatenateMaps(First,Second)\nSize<public>:i64=Both.Length\nKept<public>:i64=Attempt(Both[0],0-1)\nWon<public>:i64=Attempt(Both[{d}],0-1)\nNew<public>:i64=Attempt(Both[{d}],0-1)\n", .{ count - 1, count / 2 + count - 1 });
        const program = try h.compile(source.items);
        const result = try h.run(program, 1 << 32);
        if (result == .failed) std.debug.print("map merge failed: {s}\n", .{result.failed.message()});
        const x = result.ok;
        try std.testing.expectEqual(@as(i64, @intCast(count + count / 2)), x.get("Size").?.integer);
        try std.testing.expectEqual(@as(i64, 0), x.get("Kept").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(count - 1 + 1_000_000)), x.get("Won").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(count / 2 + count - 1 + 1_000_000)), x.get("New").?.integer);
        // The merged map keeps the first map's order, then the second one's new keys.
        const both = x.elements(x.get("Both").?).?;
        try std.testing.expectEqual(@as(i64, 0), both[0].integer);
        try std.testing.expectEqual(@as(i64, @intCast(count)), both[2 * count].integer);
        cost.* = try leastFuelOfBoth(h, program, 1 << 32);
        // The literals alone, so that what is compared is the merge and the three lookups.
        base.* = try leastFuelOfBoth(h, try h.compile(source.items[0..without]), 1 << 32);
    }
    const merges = [_]u64{ costs[0] - bases[0], costs[1] - bases[1], costs[2] - bases[2] };
    std.debug.print("map merges of 5000, 10000 and 20000 entries: fuel {d} {d} {d}\n", .{ merges[0], merges[1], merges[2] });
    // A product would quadruple with each doubling; the indexed merge about doubles.
    try std.testing.expect(merges[1] < 3 * merges[0] and merges[2] < 3 * merges[1]);
    try std.testing.expect(merges[2] < 64 * 20_000);
}

test "a pattern that nearly matches everywhere in a quarter of a megabyte is searched in linear time and fuel" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // The text is 2^K times "a" and the pattern 2^(K-1) times "a" and then "b": a plain search
    // compares half the text at each position, 2^34 code units for the last of these.
    var costs: [3]u64 = undefined;
    var times: [3]u64 = undefined;
    for ([_]u32{ 16, 17, 18 }, &costs, &times) |k, *cost, *time| {
        var text: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&text,
            \\Double(S:string)<computes>:string=S+S
            \\Index:=native{{"std.index_of"}}
            \\Split:=native{{"std.split"}}
            \\Text:string=Iterate(Double,{0d},"a")
            \\Pattern:string=Iterate(Double,{1d},"a")+"b"
            \\Out<public>:i64=Text.ReplaceAll(Pattern,"c").Length
            \\Hit<public>:i64=(Text+"b").ReplaceAll(Pattern,"c").Length
            \\At<public>:option(i64)=Index(Text,Pattern)
            \\Parts<public>:i64=Split(Text,Pattern).Length
            \\
        , .{ k, k - 1 });
        const program = try h.compile(source);
        const size: i64 = @as(i64, 1) << @intCast(k);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 32);
        const actual = h.runtime.evaluate(program, 1 << 32);
        time.* = elapsedMs(start);
        for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
            try std.testing.expectEqual(size, x.get("Out").?.integer);
            // With the "b" at its end the text ends in the pattern, once.
            try std.testing.expectEqual(@divExact(size, 2) + 1, x.get("Hit").?.integer);
            try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("At").?).?.len);
            try std.testing.expectEqual(@as(i64, 1), x.get("Parts").?.integer);
        }
        cost.* = try leastFuelOfBoth(h, program, 1 << 32);
        // A budget the declared cost does not fit stops the call before it searches.
        const begun = std.Io.Clock.awake.now(std.testing.io);
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, h.runtime.evaluate(program, cost.* / 2).failed.code);
        try budget(elapsedMs(begun) < 2_000);
    }
    std.debug.print("adversarial text search: fuel {d} {d} {d}, both machines {d}ms {d}ms {d}ms\n", .{ costs[0], costs[1], costs[2], times[0], times[1], times[2] });
    const first = costs[1] - costs[0];
    const second = costs[2] - costs[1];
    try std.testing.expect(second >= 2 * first - 64 and second <= 2 * first + 64);
    try budget(times[2] < 5_000);
}

test "four thousand references to a two megabyte string are moved without reading it" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // Every standard form that hands elements on hands these on by reference. Checking the
    // bytes of each would read eight gigabytes for a few thousand units of fuel.
    const source =
        \\Double(S:string)<computes>:string=S+S
        \\Big:string=Iterate(Double,20,"é")
        \\Grow(X:[]string)<computes>:[]string=X+X
        \\Many:[]string=Iterate(Grow,12,array{Big})
        \\Sliced<public>:i64=Attempt(Many.Slice[0],Many).Length
        \\Cut<public>:i64=Attempt(Many.Remove[0,1],Many).Length
        \\Wider<public>:i64=Attempt(Many.Insert[0,Many],Many).Length
        \\Kept<public>:i64=Many.RemoveAllElements("x").Length
        \\Same<public>:i64=Many.ReplaceAllElements("x","y").Length
        \\Runs<public>:i64=Many.ReplaceAll(array{"x"},array{"y"}).Length
        \\Flat<public>:i64=Concatenate(array{Many,Many}).Length
        \\Merged<public>:i64=ConcatenateMaps(map{1=>Big,2=>Big},map{2=>Big,3=>Big}).Length
        \\
    ;
    const program = try h.compile(source);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 32);
    const actual = h.runtime.evaluate(program, 1 << 32);
    const elapsed = elapsedMs(start);
    for ([_]evaluator.Execution{ reference.ok, actual.ok }) |x| {
        try std.testing.expectEqual(@as(i64, 4096), x.get("Sliced").?.integer);
        try std.testing.expectEqual(@as(i64, 4095), x.get("Cut").?.integer);
        try std.testing.expectEqual(@as(i64, 8192), x.get("Wider").?.integer);
        try std.testing.expectEqual(@as(i64, 4096), x.get("Kept").?.integer);
        try std.testing.expectEqual(@as(i64, 4096), x.get("Same").?.integer);
        try std.testing.expectEqual(@as(i64, 4096), x.get("Runs").?.integer);
        try std.testing.expectEqual(@as(i64, 8192), x.get("Flat").?.integer);
        try std.testing.expectEqual(@as(i64, 3), x.get("Merged").?.integer);
    }
    std.debug.print("moving 4096 references to a 2 MiB string through eight forms: both machines {d}ms\n", .{elapsed});
    // Seconds for each form before; the comparisons with "x" stop at the lengths.
    try budget(elapsed < 5_000);
}

/// `count` loops whose bodies index, so that each needs the general lowering; every other one
/// also holds a constructor that catches. Returns how often the compile went through the source.
fn forcedLoopPasses(h: *harness.Harness, count: usize, compile_ms: *u64) !u32 {
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try source.appendSlice(a, "Xs:[]i64=array{1,2,3}\n");
    for (0..count) |index| {
        if (index % 2 == 0) try source.print(a, "A{d}:[]i64=For(I->X:Xs,Xs[I])\n", .{index}) else try source.print(a, "A{d}:[]i64=For(I->X:Xs,Xs[I]+Or(option{{Xs[X]}},0))\n", .{index});
    }
    try source.print(a, "Plain<public>:[]i64=A{d}\nCaught<public>:[]i64=A{d}\n", .{ count - 2, count - 1 });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    compile_ms.* = elapsedMs(start);
    try std.testing.expectEqual(@as(u32, @intCast(count)), h.front.for_forced_count);
    const passes = h.front.passes;
    const x = try h.run(program, 64_000_000);
    const plain = x.ok.elements(x.ok.get("Plain").?).?;
    const caught = x.ok.elements(x.ok.get("Caught").?).?;
    try std.testing.expectEqual(@as(usize, 3), plain.len);
    try std.testing.expectEqual(@as(i64, 3), plain[2].integer);
    // 1 + Xs[1], 2 + Xs[2], and 3 + 0 where `Xs[3]` fails inside the constructor.
    try std.testing.expectEqual(@as(usize, 3), caught.len);
    try std.testing.expectEqual(@as(i64, 3), caught[0].integer);
    try std.testing.expectEqual(@as(i64, 5), caught[1].integer);
    try std.testing.expectEqual(@as(i64, 3), caught[2].integer);
    return passes;
}

test "two thousand loops that need the general lowering compile in as many passes as twenty" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var few_ms: u64 = 0;
    var many_ms: u64 = 0;
    const few = try forcedLoopPasses(h, 20, &few_ms);
    const many = try forcedLoopPasses(h, 2000, &many_ms);
    std.debug.print("forced loops: 20 in {d} passes {d}ms, 2000 in {d} passes {d}ms\n", .{ few, few_ms, many, many_ms });
    // One compile per loop was 2,000 passes here (400 loops took 3.7 s), and two per loop
    // that holds a catching constructor.
    try std.testing.expectEqual(few, many);
    try std.testing.expect(many <= 4);
    try budget(many_ms < 5000);
}

/// `classes` classes directly below one parent, each overriding the parent's `methods`
/// methods, then one call through the parent. Returns the compile time in milliseconds.
fn siblingOverrides(h: *harness.Harness, classes: usize, methods: usize, comptime root: []const u8, every: usize) !u64 {
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try source.appendSlice(a, "Base:=" ++ root ++ "{\n");
    for (0..methods) |j| try source.print(a, "  M{d}()<transacts>:i64={d}\n", .{ j, j });
    try source.appendSlice(a, "}\n");
    for (0..classes) |i| {
        try source.print(a, "C{d}:=class(Base){{\n", .{i});
        // Only every `every`th class overrides, and the last: the others take what is above them.
        if (i % every == 0 or i + 1 == classes) for (0..methods) |j| try source.print(a, "  M{d}<override>()<transacts>:i64={d}\n", .{ j, (i + 1) * 10 + j });
        try source.appendSlice(a, "}\n");
    }
    try source.print(a, "Q:Base=C{d}{{}}\nPlain<public>:i64=Q.M0()\n", .{classes - 2});
    try source.print(a, "O:Base=C{d}{{}}\nLast<public>:i64=O.M{d}()\nP:Base=C0{{}}\nFirst<public>:i64=P.M0()\n", .{ classes - 1, methods - 1 });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    try std.testing.expectEqual(@as(usize, methods), program.slots.len);
    try std.testing.expectEqual(@as(usize, (classes + 1) * methods), program.dispatch.len);
    const x = try h.run(program, 400_000);
    try std.testing.expectEqual(@as(i64, @intCast(classes * 10 + methods - 1)), x.ok.get("Last").?.integer);
    try std.testing.expectEqual(@as(i64, 10), x.ok.get("First").?.integer);
    try std.testing.expectEqual(@as(i64, if ((classes - 2) % every == 0) @as(i64, @intCast((classes - 1) * 10)) else 0), x.ok.get("Plain").?.integer);
    return compiled;
}

test "overrides in classes directly below one parent cost in proportion to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    // All override; half of them do, so that the others look past their siblings' overrides
    // for the parent's; the same below an interface, whose methods are defaults.
    inline for (.{ "class", "class", "interface", "interface" }, [_]usize{ 1, 2, 1, 2 }) |root, every| {
        const few = try siblingOverrides(h, 500, 2, root, every);
        const many = try siblingOverrides(h, 4000, 2, root, every);
        const wide = try siblingOverrides(h, 400, 20, root, every);
        std.debug.print("sibling overrides below one {s}, every {d}: 500x2 {d}ms, 4000x2 {d}ms, 400x20 {d}ms\n", .{ root, every, few, many, wide });
        // Eight times the classes: linear work is eight times the time. Each class once walked
        // the catalogue down to its parent, each override read every earlier override of its
        // slot, and each class that does not override read them too: sixty-four times.
        try budget(many < 20 * @max(few, 5));
        try budget(many < 200);
    }
}

/// The operation is in the same expression as the test, as it was in `std.sqrt`: an optimiser
/// that sees `@sqrt` of what it cannot prove non-negative must not decide the test for it.
fn canonicalOf(comptime operation: enum { sqrt, divide, subtract, multiply, negate }, x: f64) u64 {
    return @bitCast(types.canonicalFloat(switch (operation) {
        .sqrt => @sqrt(x),
        .divide => x / x,
        .subtract => (x * std.math.inf(f64)) - (x * std.math.inf(f64)),
        .multiply => x * std.math.inf(f64) * 0.0,
        .negate => -(@sqrt(x)),
    }));
}

test "a NaN is recognised by its bits in this build, whatever operation made it" {
    try requireProgram();
    // In a register the optimiser cannot see through: each is a NaN once the operation runs.
    var inputs = [_]f64{ -1.0, 0.0, 1.0, -4.0 };
    std.mem.doNotOptimizeAway(&inputs);
    const canonical: u64 = 0x7ff8_0000_0000_0000;
    try std.testing.expectEqual(canonical, canonicalOf(.sqrt, inputs[0]));
    try std.testing.expectEqual(canonical, canonicalOf(.negate, inputs[3]));
    try std.testing.expectEqual(canonical, canonicalOf(.divide, inputs[1]));
    try std.testing.expectEqual(canonical, canonicalOf(.subtract, inputs[2]));
    try std.testing.expectEqual(canonical, canonicalOf(.multiply, inputs[2]));
    // And numbers stay what they are, the zeros and infinities included.
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.0))), canonicalOf(.sqrt, 4.0 * inputs[2]));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), canonicalOf(.sqrt, -inputs[1]));
    try std.testing.expect(!types.isNan(std.math.inf(f64) * inputs[2]) and !types.isNan(-std.math.inf(f64)) and types.isNan(@bitCast(@as(u64, 0xfff0_0000_0000_0001))));
    try std.testing.expect(types.isCanonicalFloat(@bitCast(canonicalOf(.sqrt, inputs[0]))) and !types.isCanonicalFloat(@bitCast(@as(u64, 0xfff8_0000_0000_0000))));
    // Through both machines, comparisons and the report: the NaNs a program makes are one
    // NaN, equal to itself (RFC-0067), and print as such.
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\N:float=Sqrt(-1.0)
        \\Z:float=0.0
        \\M:float=Z*Sqrt(-4.0)
        \\Same<public>:logic=N==M
        \\Differ<public>:logic=N!=M
        \\Less<public>:logic=N<M
        \\Text<public>:string=ToString(N)
        \\Kept<public>:float=Max(N,1.0)
    );
    try std.testing.expectEqual(canonical, @as(u64, @bitCast(x.get("Kept").?.floating)));
    try std.testing.expect(x.get("Same").?.boolean and !x.get("Differ").?.boolean and !x.get("Less").?.boolean);
    try std.testing.expectEqualStrings("NaN", x.get("Text").?.string);
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"Kept\":\"NaN\"") != null);
}

test "the effects of eight thousand functions are checked in time proportional to their number, by the compiler and by both admissions" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // RFC-0078: every read, `set`, construction and call is held against the declared set of
    // the function it stands in, a constant amount of work each, in the compiler and again in
    // each machine's admission. The functions cycle through four sets; each does what its set
    // allows and calls the one before it, which declares no more.
    var compile_ms: [2]u64 = undefined;
    var reference_ms: [2]u64 = undefined;
    var machine_ms: [2]u64 = undefined;
    for ([_]usize{ 4000, 8000 }, 0..) |count, round| {
        source.clearRetainingCapacity();
        try source.appendSlice(std.testing.allocator, "var C:i64=1\ncell:=class{var N:i64=2}\nQ:cell=cell{}\n");
        for (0..count) |i| switch (i % 4) {
            0 => try source.print(std.testing.allocator, "F{d}(X:i64)<computes>:i64=X+1\n", .{i}),
            1 => try source.print(std.testing.allocator, "F{d}(X:i64)<reads>:i64=X+C+Q.N+F{d}(X)\n", .{ i, i - 1 }),
            2 => try source.print(std.testing.allocator, "F{d}(X:i64)<writes><reads>:i64=Block{{set C=C+1;F{d}(X)}}\n", .{ i, i - 1 }),
            else => try source.print(std.testing.allocator, "F{d}(X:i64)<transacts>:i64=Block{{B:=cell{{N:=X}};set Q.N=B.N;F{d}(X)}}\n", .{ i, i - 1 }),
        };
        try source.print(std.testing.allocator, "Total<public>:i64=F{d}(1)\n", .{count - 1});
        var start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        compile_ms[round] = elapsedMs(start);
        try std.testing.expect(program.functions.len >= count);
        start = std.Io.Clock.awake.now(std.testing.io);
        try std.testing.expect(evaluator.validate(program, types.limits.nodes) == null);
        reference_ms[round] = elapsedMs(start);
        start = std.Io.Clock.awake.now(std.testing.io);
        const run = h.runtime.evaluate(program, 1 << 20);
        machine_ms[round] = elapsedMs(start);
        if (run == .failed) std.debug.print("effect scale run: {s}\n", .{run.failed.message()});
        // The last function builds a cell of 1, stores 1 in `Q.N`, and the chain below it adds
        // one to `C` and reads both: 1 + 2 + 1 + (1 + 1).
        try std.testing.expectEqual(@as(i64, 6), run.ok.get("Total").?.integer);
        // The last declaration is checked like the first: one that declares too little is refused.
        try source.print(std.testing.allocator, "Late()<reads>:i64=F{d}(1)\n", .{count - 1});
        try std.testing.expectEqual(types.Diagnostic.Code.call_requires_writes_allocates, h.front.compile(source.items).failed.code);
    }
    std.debug.print("effect checking, 4000 and 8000 functions: compile {d}ms {d}ms, reference admission {d}ms {d}ms, VM admission and run {d}ms {d}ms\n", .{ compile_ms[0], compile_ms[1], reference_ms[0], reference_ms[1], machine_ms[0], machine_ms[1] });
    // Linear with room for noise; a pass over the functions per call would be four times.
    for ([_][2]u64{ compile_ms, reference_ms, machine_ms }) |times| {
        try budget(times[1] < scale_bound_ms * 2);
        try budget(times[1] <= times[0] * 3 + 50);
    }
}

test "two million values pass through any, a cell of any and a checked cast in a pool they would fill" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // RFC-0080: each visit makes one of three kinds of value, holds it as `any` in a cell that
    // outlives the visit, and reads it back by a type test and by a cast. The values built
    // lie above what a reclamation keeps, and the cell is the only root that names them.
    const program = try h.compile(
        \\P:=struct{X:i64,Y:i64}
        \\Ints:=[]i64
        \\var Held:[]any=array{}
        \\var Sum:i64=0
        \\Wrap(S:i64)<computes>:any=Block{K:=S-(S/3)*3;If(K==0,any(S),If(K==1,any(P{X:=S,Y:=1}),any(array{S,S})))}
        \\Open(V:any)<computes>:i64=Case(V,N:i64=>N,Q:P=>Q.X+Q.Y,L:Ints=>L.Length,_=>0-1)
        \\Step(S:i64)<transacts>:i64=Block{
        \\    set Held=array{Wrap(S)}
        \\    set Sum=Sum+Attempt(Open(Held[0]),0-5)+Attempt(Case[Held[0],N:i64=>1],0)+Attempt(P[Held[0]].Y,0)*10
        \\    S+1
        \\}
        \\Total<public>:i64=Iterate(Step,2000000,0)
        \\Checked<public>:i64=Sum
        \\Last<public>:i64=Attempt(Ints[Held[0]].Length,0-1)
    );
    const fuel = 1 << 34;
    // One member for the cell's array on every visit, two more for a struct or an array on two of three.
    comptime std.debug.assert(7 * 2_000_000 / 3 > types.limits.aggregate_elements);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, try unreclaimed(h, program, fuel));
    var expected: i64 = 0;
    var visit: i64 = 0;
    while (visit < 2_000_000) : (visit += 1) {
        switch (@mod(visit, 3)) {
            0 => expected += visit + 1,
            1 => expected += visit + 1 + 10,
            else => expected += 2,
        }
    }
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "any 2000000", program, fuel, &buffer);
    var want: [256]u8 = undefined;
    // The last visit is 1999999, which is 0 modulo 3: an integer, so the cast to `Ints` fails.
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{{\"Total\":2000000,\"Checked\":{d},\"Last\":-1}}\n", .{expected}), run.report);
    try std.testing.expect(run.actual.reclaims > 0);
    try budget(elapsedMs(begun) < 120_000);
}

test "four thousand conversions to any and casts out of it compile and run in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 2000, 4000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "P:=struct{X:i64}\nInts:=[]i64\n");
        for (0..total) |i| {
            switch (i % 4) {
                0 => try source.print(std.testing.allocator, "A{d}:any=any({d})\nB{d}:i64=Attempt(i64[A{d}],0-1)\n", .{ i, i, i, i }),
                1 => try source.print(std.testing.allocator, "A{d}:any=any(P{{X:={d}}})\nB{d}:i64=Attempt(P[A{d}].X,0-1)\n", .{ i, i, i, i }),
                2 => try source.print(std.testing.allocator, "A{d}:any=any(ToArray(tuple{{{d},{d}}}))\nB{d}:i64=Attempt(Ints[A{d}].Length,0-1)+{d}-2\n", .{ i, i, i, i, i, i }),
                else => try source.print(std.testing.allocator, "A{d}:any=any(\"s\")\nB{d}:i64=Attempt(Case[A{d},N:i64=>N,S:string=>{d}],0-1)\n", .{ i, i, i, i }),
            }
        }
        try source.print(std.testing.allocator, "Last<public>:i64=B{d}+B0+B1+B2+B3\n", .{total - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.execute(source.items);
        time.* = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, @intCast(total - 1 + 0 + 1 + 2 + 3)), x.get("Last").?.integer);
    }
    std.debug.print("any conversions and casts: 2000 in {d}ms, 4000 in {d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 4 * times[0] + 500);
}

/// A sink that keeps nothing but counts: the lines a long run commits, their bytes, and
/// whether each is the line the one before it was followed by.
const LineCounter = struct {
    lines: u64 = 0,
    bytes: u64 = 0,
    prepared: u64 = 0,
    aborted: u64 = 0,
    ordered: bool = true,

    fn prepare(context: *anyopaque, text: []const u8) bool {
        const self: *LineCounter = @ptrCast(@alignCast(context));
        _ = text;
        self.prepared += 1;
        return true;
    }
    fn commit(context: *anyopaque, action: effects.Action) bool {
        const self: *LineCounter = @ptrCast(@alignCast(context));
        // "line N ...": N is the number of lines before this one.
        const end = std.mem.indexOfScalarPos(u8, action.text, 5, ' ') orelse action.text.len;
        const number = std.fmt.parseInt(u64, action.text[5..end], 10) catch std.math.maxInt(u64);
        self.ordered = self.ordered and action.sequence == self.lines and number == self.lines and std.mem.startsWith(u8, action.text, "line ");
        self.lines += 1;
        self.bytes += action.text.len;
        return true;
    }
    fn abort(context: *anyopaque, text: []const u8) void {
        const self: *LineCounter = @ptrCast(@alignCast(context));
        _ = text;
        self.aborted += 1;
    }
    fn sink(self: *LineCounter) effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }
};

test "two million lines are printed through a sink by a log that holds none of them, and a region holds only what the log has room for" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    defer {
        h.control.effects.sink = null;
        h.runtime.machine.control.effects.sink = null;
    }
    const lines = 2_000_000;
    const tail = " of a long run that keeps nothing";
    const program = try h.compile("Step(S:i64)<transacts>:i64=Block{Print(\"line {S}" ++ tail ++ "\");S+1}\nTotal<public>:i64=Iterate(Step,2000000,0)");
    // More lines than the log has entries, and more text than it has bytes.
    const digits = 10 + 90 * 2 + 900 * 3 + 9000 * 4 + 90000 * 5 + 900000 * 6 + 1000000 * 7;
    const bytes = digits + lines * ("line ".len + tail.len);
    comptime std.debug.assert(lines > types.limits.effect_entries and bytes > types.limits.effect_bytes);
    var reference: LineCounter = .{};
    var actual: LineCounter = .{};
    h.control.effects.sink = reference.sink();
    h.runtime.machine.control.effects.sink = actual.sink();
    const fuel = 1 << 32;
    var buffer: [128]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "print 2000000", program, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":2000000}\n", run.report);
    for ([_]*const LineCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, lines), counter.lines);
        try std.testing.expectEqual(@as(u64, bytes), counter.bytes);
        try std.testing.expectEqual(@as(u64, lines), counter.prepared);
        try std.testing.expectEqual(@as(u64, 0), counter.aborted);
        try std.testing.expect(counter.ordered);
    }
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(@as(u64, lines), x.effects.output.count);
        try std.testing.expectEqual(@as(u64, bytes), x.effects.output.bytes);
        try std.testing.expectEqual(@as(usize, 0), x.effects.entries.len + x.effects.bytes.len);
    }
    try std.testing.expect(run.reference.effects.output.eql(run.actual.effects.output));
    // Each line left the log as it was committed: nothing was ever held.
    try std.testing.expectEqual(@as(u32, 0), h.control.effects.count + h.runtime.machine.control.effects.count);
    try budget(elapsedMs(begun) < 60_000);
    // The replay folded two million lines of its own, from the second run's pool.
    var forged = run.actual;
    forged.effects.output.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
    forged = run.actual;
    forged.effects.output.count -= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));

    // Inside a region every line has to wait, and the log is where they wait: one line more
    // than it has entries stops both machines at the same call, and nothing was shown.
    reference = .{};
    actual = .{};
    const pending = try h.compile("Step(S:i64)<transacts>:i64=Block{Print(\"line {S}\");S+1}\nTotal<public>:i64=Attempt(Block{X:=Iterate(Step,1048577,0);Require[X>0];X},0-1)");
    try std.testing.expectEqual(@as(usize, 1048576), types.limits.effect_entries);
    const outcome = evaluator.evaluateWithRuntimeStorage(pending, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const machine = h.runtime.evaluate(pending, fuel);
    try std.testing.expectEqualDeep(outcome.failed, machine.failed);
    try std.testing.expectEqual(types.Diagnostic.Code.effect_limit, machine.failed.code);
    try std.testing.expectEqualStrings("Print", pending.source[machine.failed.span.start..machine.failed.span.end]);
    for ([_]*const LineCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, 0), counter.lines);
        try std.testing.expectEqual(@as(u64, types.limits.effect_entries), counter.prepared);
        try std.testing.expectEqual(@as(u64, types.limits.effect_entries), counter.aborted);
    }
    // One fewer fits, and commits in order when the region does.
    reference = .{};
    actual = .{};
    const fits = try h.compile("Step(S:i64)<transacts>:i64=Block{Print(\"line {S}\");S+1}\nTotal<public>:i64=Attempt(Block{X:=Iterate(Step,1048576,0);Require[X>0];X},0-1)");
    const kept = try longRun(h, again, "print 1048576 in a region", fits, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":1048576}\n", kept.report);
    for ([_]*const LineCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, types.limits.effect_entries), counter.lines);
        try std.testing.expect(counter.ordered and counter.aborted == 0);
    }
    try budget(elapsedMs(begun) < 120_000);
}

test "a million draws, a shuffle of a hundred thousand and a million failed regions that each draw agree with the stream" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const source =
        \\Range:=native{"std.range"}
        \\Sum:=native{"std.sum"}
        \\Step(S:i64)<transacts>:i64=S+GetRandomInt(1,6)
        \\Lost(S:i64)<transacts>:i64=S+Attempt(Block{D:=GetRandomInt(1,1000);Require[D>1000];D},1)
        \\Wide(S:float)<transacts>:float=S+GetRandomFloat(0.0,1.0)
        \\Total<public>:i64=Iterate(Step,1000000,0)
        \\Deck:[]i64=Shuffle(Range(100000))
        \\Cards<public>:i64=Sum(Deck)
        \\Top<public>:i64=Attempt(Deck[0],0-1)
        \\Undone<public>:i64=Iterate(Lost,1000000,0)
        \\Mean<public>:float=Iterate(Wide,100000,0.0)/100000.0
        \\After<public>:i64=GetRandomInt(1,1000000)
        \\
    ;
    const program = try h.compile(source);
    const fuel = 1 << 32;
    // The same stream, read here in the order the program reads it.
    var model: effects.Stream = .{};
    var total: i64 = 0;
    for (0..1_000_000) |_| total += model.integer(1, 6).?;
    const key = model.next();
    const deck = try std.testing.allocator.alloc(i64, 100_000);
    defer std.testing.allocator.free(deck);
    for (deck, 0..) |*card, index| card.* = @intCast(index);
    var pass: effects.Stream = .{ .seed = key };
    var index: usize = deck.len;
    while (index > 1) {
        index -= 1;
        std.mem.swap(i64, &deck[index], &deck[@intCast(pass.below(index + 1).?)]);
    }
    // A draw in a region that fails is spent all the same.
    for (0..1_000_000) |_| _ = model.integer(1, 1000).?;
    var mean: f64 = 0;
    for (0..100_000) |_| mean += model.float(0.0, 1.0);
    mean /= 100000.0;
    const after = model.integer(1, 1000000).?;
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "draw 2100000", program, fuel, &buffer);
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(total, x.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, 100_000 * 99_999 / 2), x.get("Cards").?.integer);
        try std.testing.expectEqual(deck[0], x.get("Top").?.integer);
        try std.testing.expectEqual(@as(i64, 1_000_000), x.get("Undone").?.integer);
        try std.testing.expectEqual(@as(u64, @bitCast(mean)), @as(u64, @bitCast(x.get("Mean").?.floating)));
        try std.testing.expectEqual(after, x.get("After").?.integer);
        try std.testing.expectEqual(model.position, x.effects.draws);
        try std.testing.expectEqual(@as(u64, 0), x.effects.output.count + x.effects.discarded);
        const dealt = x.elements(x.get("Deck").?).?;
        for (dealt, deck) |card, wanted| try std.testing.expectEqual(wanted, card.integer);
    }
    // A die that is fair to within sampling error, and floats spread over their interval.
    try std.testing.expect(total > 3_490_000 and total < 3_510_000);
    try std.testing.expect(mean > 0.49 and mean < 0.51);
    try std.testing.expect(model.position >= 2_100_002);
    try budget(elapsedMs(begun) < 60_000);
    var forged = run.actual;
    forged.effects.draws += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
    forged = run.actual;
    forged.effects.seed += 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(program, fuel), true, .{}));
}

// ---- RFC-0081

test "SortBy sorts a hundred thousand elements in digest mode in time and members that grow as n log n" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    var times: [2]u64 = undefined;
    var members: [2]usize = undefined;
    for ([_]i64{ 50_000, 100_000 }, &times, &members) |n, *time, *used| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        // A pseudo-random permutation with repeated keys: K*7919 mod N, halved.
        // A permutation of 0..n-1, I*7919 mod n, built and checked by loops whose state is the
        // array or scalars, so that nothing but the sort grows faster than n.
        try source.print(std.testing.allocator, "Xs:[]i64=Iterate(Fn(A:[]i64)<computes>:[]i64{{A+array{{A.Length*7919-A.Length*7919/{d}*{d}}}}},{d},array{{}})\n", .{ n, n, n });
        try source.appendSlice(std.testing.allocator, "Less(A:i64,B:i64)<computes><decides>:void=Require[A/2<B/2]\nYs:[]i64=SortBy(Xs,Less)\n");
        try source.appendSlice(std.testing.allocator, "Ordered<public>:logic=Iterate(Fn(S:tuple(i64,logic))<computes>:tuple(i64,logic){tuple{S(0)+1,S(1) and Attempt(Ys[S(0)-1]/2<=Ys[S(0)]/2,false)}},Ys.Length-1,tuple{1,true})(1)\nCount<public>:i64=Ys.Length\n");
        const program = try h.compile(source.items);
        const fuel = 4_000_000_000;
        const start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const actual = h.runtime.evaluate(program, fuel);
        time.* = elapsedMs(start);
        if (reference == .failed or actual == .failed) {
            std.debug.print("SortBy of {d}: {s} / {s}\n", .{ n, if (reference == .failed) @tagName(reference.failed.code) else "ok", if (actual == .failed) @tagName(actual.failed.code) else "ok" });
            return error.TestUnexpectedResult;
        }
        for ([_]evaluator.Execution{ reference.ok, actual.ok }) |execution| {
            try std.testing.expect(execution.get("Ordered").?.boolean);
            try std.testing.expectEqual(n, execution.get("Count").?.integer);
        }
        try std.testing.expectEqualDeep(reference.ok.witness, actual.ok.witness);
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        used.* = actual.ok.aggregate_values.len;
        // Each of the seventeen passes appends two arrays of n positions, without copying them.
        try std.testing.expect(used.* < 40 * @as(usize, @intCast(n)));
    }
    std.debug.print("SortBy: 50000 in {d}ms ({d} members), 100000 in {d}ms ({d} members)\n", .{ times[0], members[0], times[1], members[1] });
    try budget(times[1] < 3 * times[0] + 500);
}

test "a thousand instantiations with two specializations of a generic method each compile in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 500, 1000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "Box[T:type]:=class{V:T\nWith[U:type](X:U)<reads>:tuple(T,U){tuple{Self.V,X}}\n}\n");
        for (0..total) |i| {
            try source.print(std.testing.allocator, "S{d}:=struct{{N:i64}}\nB{d}:=Box[S{d}]{{V:=S{d}{{N:={d}}}}}\nR{d}:i64=B{d}.With[i64]({d})(0).N+B{d}.With[S{d}](S{d}{{N:=1}})(1).N\n", .{ i, i, i, i, i, i, i, i, i, i, i });
        }
        try source.print(std.testing.allocator, "Last<public>:i64=R{d}\n", .{total - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.execute(source.items);
        time.* = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, @intCast(total)), x.get("Last").?.integer);
    }
    std.debug.print("generic method specializations: 2x500 in {d}ms, 2x1000 in {d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 4 * times[0] + 500);
}

test "two thousand castable type values and casts through them compile and run in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 1000, 2000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "Base:=class<castable>{N:i64=0}\nKinds:=castable_subtype(Base)\nIs(B:Base,K:Kinds)<computes>:i64=Attempt(Block{K[B];1},0)\n");
        for (0..total) |i| {
            try source.print(std.testing.allocator, "C{d}:=class(Base){{}}\nK{d}:Kinds=C{d}\nI{d}:Base=C{d}{{}}\nR{d}:i64=Is(I{d},K{d})+Is(I{d},Base)+Is(I{d},C{d})\n", .{ i, i, i, i, i, i, i, i, i, i, i });
        }
        try source.print(std.testing.allocator, "Last<public>:i64=R{d}+Is(I0,K1)\n", .{total - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.execute(source.items);
        time.* = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, 3), x.get("Last").?.integer);
    }
    std.debug.print("castable type values: 1000 in {d}ms, 2000 in {d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 4 * times[0] + 500);
}

test "two thousand classes that each declare a generic method of one name compile in time that grows linearly" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 1000, 2000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        for (0..total) |i| {
            try source.print(std.testing.allocator, "C{d}:=class{{N:i64={d}\nMap[U:type](X:U)<reads>:i64{{Self.N}}\n}}\nR{d}:i64=C{d}{{}}.Map[i64](1)\n", .{ i, i, i, i });
        }
        try source.print(std.testing.allocator, "Last<public>:i64=R{d}\n", .{total - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.execute(source.items);
        time.* = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, @intCast(total - 1)), x.get("Last").?.integer);
    }
    std.debug.print("generic methods of one name: 1000 classes in {d}ms, 2000 in {d}ms\n", .{ times[0], times[1] });
    // A lookup asks the supertypes of the receiver, not every method of the name.
    try budget(times[1] < 3 * times[0] + 300);
}

// The report checked each binding's name against every earlier one (`fix2`): with thousands of
// bindings that, not `any`, made the conversions of the test above grow faster than their
// number. Names are now found through an index.
test "a report of sixteen thousand bindings is admitted in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 4000, 16000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        for (0..total) |i| try source.print(std.testing.allocator, "A{d}:i64={d}\n", .{ i, i });
        const p = try h.compile(source.items);
        const x = h.runtime.evaluate(p, 1 << 30);
        try std.testing.expect(x == .ok);
        const start = std.Io.Clock.awake.now(std.testing.io);
        for (0..4) |_| _ = try reporting.validate(x.ok, false, .{ .work = 1 << 30 });
        time.* = elapsedMs(start);
    }
    std.debug.print("report of bindings: 4000 in {d}ms, 16000 in {d}ms\n", .{ times[0], times[1] });
    // Linear is four times as long; the square was sixteen.
    try budget(times[1] < 8 * times[0] + 200);
}

// Structured concurrency (RFC-0082), scale tests 1, 2, 5 and 6 at the program profile's
// capacities: 65,536 live tasks, 262,144 saved frames, and ten million ticks.
const concurrency = @import("concurrency_tests.zig");

test "sixty-five thousand live tasks each sleep a time of their own, and one more is task_limit" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency.liveTasks(h);
}

test "saved frames at their capacity, and one more, which is suspended_frame_limit" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency.savedFrames(h);
}

test "ten million ticks are crossed by one sleeper in three advances" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency.longSleep(h);
}

// RFC-0083: refinement casts at scale, and the compile time of many refinements, casts and
// parametric aliases.

test "two million refinement casts in digest mode keep their values in a pool they would fill" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    // Each visit casts a value that lies within the bounds two times in three, holds three
    // values of the refinement in a cell that outlives the visit and reads one back.
    const program = try h.compile(
        \\Age:=type{_X:i64 where 0<=_X,_X<=1000}
        \\var Held:[]Age=array{}
        \\var Sum:i64=0
        \\Step(S:i64)<transacts>:i64=Block{
        \\    K:=S-(S/1500)*1500
        \\    A:Age=Attempt(Age[K],0)
        \\    set Held=array{A,A,7}
        \\    set Sum=Sum+Attempt(i64(Held[0]),0)
        \\    S+1
        \\}
        \\Total<public>:i64=Iterate(Step,2000000,0)
        \\Checked<public>:i64=Sum
        \\Last<public>:i64=Attempt(i64(Held[2]),-1)
    );
    const fuel = 1 << 34;
    comptime std.debug.assert(3 * 2_000_000 > types.limits.aggregate_elements);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, try unreclaimed(h, program, fuel));
    var expected: i64 = 0;
    var visit: i64 = 0;
    while (visit < 2_000_000) : (visit += 1) {
        const k = @mod(visit, 1500);
        if (k <= 1000) expected += k;
    }
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "refinements 2000000", program, fuel, &buffer);
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{{\"Total\":2000000,\"Checked\":{d},\"Last\":7}}\n", .{expected}), run.report);
    try std.testing.expect(run.actual.reclaims > 0);
    try budget(elapsedMs(begun) < 120_000);
}

test "four thousand refinements with a cast each and four thousand alias uses compile in time proportional to their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for ([_]usize{ 2000, 4000 }, &times) |total, *time| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "Pair[T:type]:=tuple(T,T)\nTwice[T:type]:=Pair[Pair[T]]\n");
        for (0..total) |i| {
            try source.print(std.testing.allocator, "R{d}:=type{{_X:i64 where {d}<=_X,_X<={d}}}\nB{d}:i64=Attempt(i64(R{d}[V{d}]),0-1)\nV{d}:i64={d}\n", .{ i, i, i + 10, i, i, i, i, i + (i % 2) * 20 });
            try source.print(std.testing.allocator, "P{d}:Twice[i64]=tuple{{tuple{{{d},1}},tuple{{2,3}}}}\n", .{ i, i });
        }
        try source.print(std.testing.allocator, "Last<public>:i64=B{d}+B0+B1+P{d}(0)(0)\n", .{ total - 1, total - 1 });
        // Values are named before their use: the cast reads `V`, declared on the line after.
        const fixed = try reorder(std.testing.allocator, source.items);
        defer std.testing.allocator.free(fixed);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.execute(fixed);
        time.* = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, -1 + 0 - 1 + @as(i64, @intCast(total - 1))), x.get("Last").?.integer);
    }
    std.debug.print("refinements and alias uses: 2000 in {d}ms, 4000 in {d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 4 * times[0] + 500);
}

/// Moves each `V` binding of the test above before the cast that reads it.
fn reorder(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var held: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == 'B') {
            held = line;
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        if (line[0] == 'V') if (held) |cast| {
            try out.appendSlice(allocator, cast);
            try out.append(allocator, '\n');
            held = null;
        };
    }
    return out.toOwnedSlice(allocator);
}

// Structured concurrency (RFC-0082, P3.2), scale test 3: a million switches between two
// tasks through two events, in a digest run that the replay checks.
const concurrency_events = @import("concurrency_event_tests.zig");

test "a million switches between two tasks through two events" {
    try requireProgram();
    const f = try @import("trace_replay.zig").Fixture.create();
    defer f.destroy();
    try concurrency_events.pingPong(f, 250_000);
}

// Structured concurrency (RFC-0082, P3.3), scale test 4: a tree of sixteen thousand tasks
// cancelled from its root, the requests made on an explicit stack.
const concurrency_structured = @import("concurrency_structured_tests.zig");

test "a tree of sixteen thousand tasks cancelled from its root" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency_structured.treeCancel(h, 13);
}

const concurrency_branch = @import("concurrency_branch_tests.zig");

test "a tree of thirty-two thousand branches cancelled by their frames' ends" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency_branch.branchTree(h, 14);
}

// Live variables (RFC-0084, P4.1): scale tests 2 and 5 and the layered graph at depth 40.
const live = @import("live_tests.zig");

test "rings of live variables at the propagation's two bounds" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live.ringScale(f);
}

test "live_edges entries exactly and one more, at the root and in a region" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live.entryScale(f);
}

test "a layered graph of live variables forty deep evaluates each record once" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try live.layers(h, 40);
}

test "two million writes of a watched cell, in one region and beside two million entries, take time in proportion" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live.regionWrites(f);
    try live.rootWrites(f);
}

test "a guard attached a million times at the root stays within the stores in a digest run" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live.reattached(f);
}

// Structured concurrency (RFC-0082, P3.5): reclamation across task stacks. A service loop of a
// million visits, each of which builds and sleeps, stays in bounded stores in a digest run whose
// replay works every reclamation out again.
const reclaim = @import("reclaim_tests.zig");

test "a service loop of a million visits that each sleep stays in bounded stores in a digest run" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try reclaim.serviceLoop(f, 500_000);
}

// Live fields (RFC-0084, P4.2): scale test 1.
const live_fields = @import("live_field_tests.zig");

test "a chain of 460,000 instances whose live fields read the one before, written at its head" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live_fields.chainScale(f, 460_000);
}

// Functions as types (RFC-0084, P4.3): a chain of 350,000 instances whose field of a function
// type follows a module var. An instance (three fields and its header) and its record take
// eleven cells.
const live_types = @import("live_type_tests.zig");

test "a chain of 350,000 instances whose fields of a function type follow one module var" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try live_types.fanScale(f, 350_000);
}

// RFC-0082, P3.6: a loop left by arms' exits, each visit abandoning expressions.
const concurrency_exit = @import("concurrency_exit_tests.zig");

test "ten thousand visits of a loop left by arms' exits" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency_exit.exitLoop(h, 10_000, 1 << 30);
}

// Reactions (RFC-0084, P4.4): scale tests 3, 4 and 6.
const reactions = @import("reaction_tests.zig");

test "a fan-out of one cell to 100,000 records and to 10,000 Whens" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try reactions.fanOut(f, 100_000, 10_000);
}

test "a million writes of a watched cell, each delivered to a When, in bounded stores" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try reactions.watchedWrites(f, 1_000_000);
}

test "deliveries exactly at their bound in one delivery loop, and one more" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try reactions.deliveryBound(f);
}

// RFC-0082, P3.7: a chain of 65,000 awaiters, each awaiting the one before it, cancelled by
// one request at its root; every link unwinds in its own turn of the scheduler.
const concurrency_cancel = @import("concurrency_cancel_tests.zig");

test "a chain of sixty-five thousand awaiters cancelled from its root" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    try concurrency_cancel.awaitChain(h, 65_000, 1 << 34);
}

// Batches (RFC-0084, P4.5): a scale test.
const batches = @import("batch_tests.zig");

test "a million writes of a watched cell in one batch deliver once, and so do a thousand nested batches" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try batches.batchScale(f, 1_000_000, 1000);
}

// RFC-0084, P4.6: `Await(G)`. Sixty thousand tasks wait on one cell and one write wakes them
// all; and a thousand tasks wait each for its own threshold while a thousand writes raise the
// cell, each waking those still waiting, which evaluate their guards again.
const awaits = @import("await_tests.zig");

test "one write wakes sixty thousand tasks waiting at an Await" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    _ = try awaits.awaitFanOut(f, 60_000);
}

test "a thousand awaiters woken by a thousand writes, each until it passes its threshold" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const x = try awaits.awaitScale(f, 1_000, 1_000);
    try std.testing.expectEqual(@as(u64, 1_000 + 1_000 * 1_001 / 2), x.live.evaluations);
}

// RFC-0084, P4.7: sixty thousand Whens on one cell, cancelled by a task the first one's body
// hands off to while the others are notified: each later delivery does nothing.
const reaction_cancels = @import("reaction_cancel_tests.zig");

test "sixty thousand Whens cancelled while a write has notified them" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    _ = try reaction_cancels.cancelScale(f, 60_000);
}

// RFC-0082, P3.9: fifty thousand subscriptions to one event, twenty signals, a third of whose
// callbacks cancel a subscription during the signal.
const subscriptions = @import("concurrency_subscription_tests.zig");

test "fifty thousand subscriptions and twenty signals, with cancellations during them" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try subscriptions.subscriptionFan(f, 50_000, 20, 1 << 40);
}

test "a For that builds a hundred thousand instances, and one of a hundred thousand integers, are linear in both machines and the replay" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const Case = struct { []const u8, []const u8, []const u8 };
    for ([_]Case{
        .{ "instances", "P:=class{N:i64}\nAll:[]P=For(K:1..100000,P{N:=K})\nN<public>:i64=All.Length", "{\"N\":100000}\n" },
        .{ "integers", "Xs:[]i64=For(K:1..100000,K*2)\nN<public>:i64=Xs.Length\nLast<public>:i64=Attempt(Xs[99999],0)", "{\"N\":100000,\"Last\":200000}\n" },
    }) |case| {
        const program = try h.compile(case[1]);
        // Forty units an element suffice. A copy of the accumulator at every element charged
        // about five billion, and took some 200 s in each machine.
        const fuel = 40 * 100_000;
        var buffer: [128]u8 = undefined;
        // A stored run: every copy and room stays in the pool, which a copy at every element
        // filled at 5,000 elements.
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
        var start = std.Io.Clock.awake.now(std.testing.io);
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        const reference_ms = elapsedMs(start);
        start = std.Io.Clock.awake.now(std.testing.io);
        const actual = h.runtime.evaluate(program, fuel);
        const actual_ms = elapsedMs(start);
        if (reference == .failed) std.debug.print("{s}: {s}\n", .{ case[0], reference.failed.message() });
        try std.testing.expect(reference == .ok and actual == .ok);
        try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
        for (reference.ok.aggregate_values, actual.ok.aggregate_values) |x, y| try std.testing.expectEqualDeep(x, y);
        try std.testing.expectEqual(reference.ok.call_steps.len, actual.ok.call_steps.len);
        try std.testing.expect(actual.ok.aggregate_values.len < 8 * 100_000);
        start = std.Io.Clock.awake.now(std.testing.io);
        var out = std.Io.Writer.fixed(&buffer);
        _ = try reporting.writeReplayed(&out, actual.ok, again.producer(program, fuel), true, .{});
        const report_ms = elapsedMs(start);
        try std.testing.expectEqualStrings(case[2], out.buffered());
        std.debug.print("For of 100000 {s}, stored: members={d} reference={d}ms vm={d}ms replayed report={d}ms\n", .{ case[0], actual.ok.aggregate_values.len, reference_ms, actual_ms, report_ms });
        try budget(reference_ms < 5000 and actual_ms < 5000 and report_ms < 5000);
        // A digest run that reclaims keeps each room behind its array, for the same fuel.
        start = std.Io.Clock.awake.now(std.testing.io);
        const run = try longRun(h, again, case[0], program, fuel, &buffer);
        try std.testing.expectEqualStrings(case[2], run.report);
        try budget(elapsedMs(start) < 15_000);
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
}

// RFC-0086, P2.2: inputs at scale. Scale test 1: a million reads of the clock at one tick hold
// one entry. Scale test 2: `input_entries` ticks that each read the clock fill the record
// exactly, and one tick more is `input_limit`. Each machine asks a world of its own that answers
// alike, and the replayed report's second run is given the record and no world.

/// Both machines are given the same scripted world.
const Worlds = struct {
    reference: effects.Script = .{},
    actual: effects.Script = .{},

    fn give(self: *Worlds, h: *harness.Harness) void {
        h.control.effects.inputs.source = self.reference.source();
        h.runtime.machine.control.effects.inputs.source = self.actual.source();
    }
    fn take(h: *harness.Harness) void {
        h.control.effects.inputs.source = null;
        h.runtime.machine.control.effects.inputs.source = null;
    }
};

test "a million reads of the clock at one tick hold one entry, in both machines and in the replay" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var worlds: Worlds = .{};
    worlds.give(h);
    defer Worlds.take(h);
    const program = try h.compile("Step(S:float)<transacts>:float=GetSecondsSinceEpoch()+S*0.0\nLast<public>:float=Iterate(Step,1000000,0.0)");
    const fuel = 1 << 32;
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "clock 1000000", program, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Last\":1700000000,\"$inputs\":{\"count\":1,\"bytes\":0}}\n", run.report);
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| try std.testing.expectEqual(@as(usize, 1), x.effects.inputs.len);
    try std.testing.expectEqual(@as(u64, 1), worlds.reference.reads);
    try std.testing.expectEqual(@as(u64, 1), worlds.actual.reads);
    try budget(elapsedMs(begun) < 60_000);
}

test "input_entries ticks that each read the clock fill the record exactly, and one tick more is input_limit" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var worlds: Worlds = .{};
    worlds.give(h);
    defer Worlds.take(h);
    const capacity = effects.input_entry_capacity;
    try std.testing.expectEqual(@as(usize, 1024 * 1024), capacity);
    const format = "Tick(N:i64)<transacts><suspends>:float=Block{{var T:float=0.0;var I:i64=0;While(I<N,Block{{NextTick();set T=GetSecondsSinceEpoch();set I=I+1}});T}}\nX<public>:task(float)=Spawn{{Tick({d})}}\nA<public>:float=GetSecondsSinceEpoch()";
    var text: [512]u8 = undefined;
    const fuel = 1 << 34;
    // The root reads at tick 0 and the task at each of its ticks after it.
    const exact = try h.compile(try std.fmt.bufPrint(&text, format, .{capacity - 1}));
    var buffer: [1024]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "clock ticks 1048575", exact, fuel, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, run.report, "\"$inputs\":{\"count\":1048576,\"bytes\":0}") != null);
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(@as(usize, capacity), x.effects.inputs.len);
        const last = x.effects.inputs[capacity - 1];
        try std.testing.expectEqual(@as(u64, capacity - 1), last.tick);
        try std.testing.expectEqual(@as(u64, @bitCast(worlds.reference.paced(capacity - 1))), last.bits);
    }
    try budget(elapsedMs(begun) < 120_000);
    // One tick more stops both machines at the call, with the whole record kept.
    worlds.reference.rewind();
    worlds.actual.rewind();
    const over = try h.compile(try std.fmt.bufPrint(&text, format, .{capacity}));
    const reference = evaluator.evaluateWithRuntimeStorage(over, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(over, fuel);
    try std.testing.expectEqualDeep(reference.failed, actual.failed);
    try std.testing.expectEqual(types.Diagnostic.Code.input_limit, actual.failed.code);
    try std.testing.expectEqualStrings("GetSecondsSinceEpoch", over.source[actual.failed.span.start..actual.failed.span.end]);
    try std.testing.expectEqual(@as(u32, capacity), h.control.effects.inputs.count);
    try std.testing.expectEqual(@as(u32, capacity), h.runtime.machine.control.effects.inputs.count);
    try std.testing.expectEqual(@as(u64, capacity), worlds.actual.reads);
}

// RFC-0094, B6: `Profile` at scale. A million profiled steps in a digest run read the clock once
// (every step is at one tick) and print a million lines through a sink that holds none of them;
// both machines are given a world of their own, and the replay is given the record and none.
test "a million profiled steps read the clock once and print a million lines, in both machines and the replay" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var worlds: Worlds = .{};
    worlds.give(h);
    defer Worlds.take(h);
    defer {
        h.control.effects.sink = null;
        h.runtime.machine.control.effects.sink = null;
    }
    const steps = 1_000_000;
    const line = "profile step: 0 s";
    var reference: LineCounter = .{};
    var actual: LineCounter = .{};
    h.control.effects.sink = reference.sink();
    h.runtime.machine.control.effects.sink = actual.sink();
    const program = try h.compile("Step(S:i64)<transacts>:i64=Profile(\"step\",S+1)\nTotal<public>:i64=Iterate(Step,1000000,0)");
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "profile 1000000", program, 1 << 32, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":1000000,\"$inputs\":{\"count\":1,\"bytes\":0}}\n", run.report);
    for ([_]*const LineCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, steps), counter.lines);
        try std.testing.expectEqual(@as(u64, steps * line.len), counter.bytes);
        try std.testing.expectEqual(@as(u64, 0), counter.aborted);
    }
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(@as(u64, steps), x.effects.output.count);
        try std.testing.expectEqual(@as(usize, 1), x.effects.inputs.len);
    }
    try std.testing.expect(run.reference.effects.output.eql(run.actual.effects.output));
    try std.testing.expectEqual(@as(u64, 1), worlds.reference.reads);
    try std.testing.expectEqual(@as(u64, 1), worlds.actual.reads);
    try budget(elapsedMs(begun) < 60_000);
}

test "profiles nested a hundred deep print their lines from the inside out, and a thousand tasks that sleep are measured each" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var worlds: Worlds = .{};
    worlds.give(h);
    defer Worlds.take(h);
    var text: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    const depth = 100;
    try writer.writeAll("A<public>:i64=");
    for (0..depth) |_| try writer.writeAll("Profile(\"n\",");
    try writer.writeAll("1");
    for (0..depth) |_| try writer.writeAll(")");
    const nested = (try h.run(try h.compile(writer.buffered()), 1 << 24)).ok;
    try std.testing.expectEqual(@as(i64, 1), nested.get("A").?.integer);
    try std.testing.expectEqual(@as(usize, depth), nested.effects.entries.len);
    try std.testing.expectEqual(@as(usize, 1), nested.effects.inputs.len);
    // A thousand tasks sleep for one of seven spans: each measures its own span in the world's
    // clock, and the readings are one entry per tick that anyone read at (the start, and seven).
    worlds.reference.rewind();
    worlds.actual.rewind();
    const tasks = 1000;
    var source: [64 * 1024]u8 = undefined;
    var many: std.Io.Writer = .fixed(&source);
    try many.writeAll("Nap(N:i64)<transacts><suspends>:float=Profile(\"nap\",Block{Sleep(ToFloat(N)*0.5);ToFloat(N)})\n");
    for (0..tasks) |index| try many.print("T{d}<public>:task(float)=Spawn{{Nap({d})}}\n", .{ index, index % 7 + 1 });
    const napped = (try h.run(try h.compile(many.buffered()), 1 << 26)).ok;
    try std.testing.expectEqual(@as(usize, tasks), napped.effects.entries.len);
    try std.testing.expectEqual(@as(usize, 8), napped.effects.inputs.len);
    // The seven spans, in seconds of text: 0.5, 1, 1.5, 2, 2.5, 3 and 3.5.
    const spans = [7][]const u8{ "0.5", "1", "1.5", "2", "2.5", "3", "3.5" };
    var bytes: usize = 0;
    for (0..tasks) |index| bytes += "profile nap: ".len + spans[index % 7].len + " s".len;
    try std.testing.expectEqual(bytes, napped.effects.bytes.len);
    try std.testing.expect(std.mem.indexOf(u8, napped.effects.bytes, "profile nap: 3.5 s") != null);
}

test "rfc0085 I8: a chain of five hundred classes with fields with accessors, and a million assignments through one" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // Each class declares a field with accessors over the one cell `R` of the first, its
    // getter adding the class's number and its setter taking it off again; each class below
    // reaches every field above it, which its declaration checks.
    const classes = 500;
    try source.appendSlice(std.testing.allocator, "c0 := class{\n var F0<getter(G0)><setter(S0)>:i64 = external{}\n var R:i64 = 0\n G0(:accessor)<reads>:i64 = Self.R\n S0(:accessor, V:i64)<writes>:void = Block{ set Self.R = V; 0 }\n}\n");
    for (1..classes) |i| try source.print(std.testing.allocator, "c{d} := class(c{d}){{\n var F{d}<getter(G{d})><setter(S{d})>:i64 = external{{}}\n G{d}(:accessor)<reads>:i64 = Self.R + {d}\n S{d}(:accessor, V:i64)<writes>:void = Block{{ set Self.R = V - {d}; 0 }}\n}}\n", .{ i, i - 1, i, i, i, i, i, i, i });
    const steps = 1_000_000;
    try source.print(std.testing.allocator, "O := c{d}{{}}\nStep(S:i64)<transacts>:i64 = Block{{ set O.F{d} += 1; S + 1 }}\nLast<public>:i64 = Iterate(Step, {d}, 0)\nFirst<public>:i64 = O.F0\nDeepest<public>:i64 = O.F{d}\n", .{ classes - 1, classes - 1, steps, classes - 1 });
    const compiled = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    try budget(elapsedMs(compiled) < 20_000);
    const fuel = 1 << 32;
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "accessors 1000000", program, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Last\":1000000,\"First\":1000000,\"Deepest\":1000499}\n", run.report);
    try budget(elapsedMs(begun) < 60_000);
}

test "rfc0085 I9: a chain of five hundred classes with fields with accessors and no default, built two thousand times" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // Each class declares a field with accessors and no default whose setter adds what it is
    // given, times the class's number, to the one cell `R` of the first. Every archetype of the
    // deepest gives all five hundred, so one construction is five hundred setter calls.
    const classes = 500;
    try source.appendSlice(std.testing.allocator, "c0 := class{\n var F0<getter(G0)><setter(S0)>:i64\n var R:i64 = 0\n G0(:accessor)<reads>:i64 = Self.R\n S0(:accessor, V:i64)<transacts>:void = Block{ set Self.R += V; 0 }\n}\n");
    for (1..classes) |i| try source.print(std.testing.allocator, "c{d} := class(c{d}){{\n var F{d}<getter(G{d})><setter(S{d})>:i64\n G{d}(:accessor)<reads>:i64 = Self.R\n S{d}(:accessor, V:i64)<transacts>:void = Block{{ set Self.R += V * {d}; 0 }}\n}}\n", .{ i, i - 1, i, i, i, i, i, i });
    try source.print(std.testing.allocator, "Make(K:i64)<transacts>:i64 = c{d}{{", .{classes - 1});
    // Written deepest first: the setters still run in declaration order.
    var field: usize = classes;
    while (field > 0) {
        field -= 1;
        try source.print(std.testing.allocator, "F{d} := K{s}", .{ field, if (field == 0) "" else ", " });
    }
    const builds = 2000;
    try source.print(std.testing.allocator, "}}.R\nStep(S:i64)<transacts>:i64 = S + Make(1)\nTotal<public>:i64 = Iterate(Step, {d}, 0)\n", .{builds});
    const compiled = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    try budget(elapsedMs(compiled) < 20_000);
    const fuel = 1 << 32;
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "accessor initialisation 2000", program, fuel, &buffer);
    // Each build: 1 + 1 + 2 + ... + 499 = 124751.
    var expected: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"Total\":{d}}}\n", .{builds * (1 + 499 * 500 / 2)}), run.report);
    try budget(elapsedMs(begun) < 60_000);
}

test "rfc0085 I9: archetypes of a class without such fields cost nothing for the fields of another (review of a9)" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // Ten thousand fields with accessors and no default on `big`, and twenty thousand
    // archetypes of `small`: each looks at `small`'s supertypes, not at every field (a first
    // version walked them all, which took seconds here).
    const fields = 10_000;
    const archetypes = 20_000;
    try source.appendSlice(std.testing.allocator, "big := class{\n var I:i64 = 0\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n");
    for (0..fields) |index| try source.print(std.testing.allocator, " var F{d}<getter(G)><setter(S)>:i64\n", .{index});
    try source.appendSlice(std.testing.allocator, "}\nsmall := class{ X:i64 = 1 }\nMake()<transacts>:i64 = Block{\n var T:i64 = 0\n");
    for (0..archetypes) |_| try source.appendSlice(std.testing.allocator, " set T += small{}.X\n");
    try source.appendSlice(std.testing.allocator, " T\n}\n");
    const compiled = std.Io.Clock.awake.now(std.testing.io);
    _ = try h.compile(source.items);
    try budget(elapsedMs(compiled) < 5_000);
}

// RFC-0086, P2.3: handles at scale. Scale test 3: a reader of 10 MiB in 100,000 lines through a
// `digest` run that reclaims the line of each frame as the frame ends. Scale test 4: a million
// lines on a writer's channel outside every region in a `digest` run, each handed to its sink as
// it commits, and a region of exactly `effect_entries` lines on a channel, and one more.

const scale_grants = [_]effects.Grant{ .{ .kind = .reader, .name = "in" }, .{ .kind = .writer, .name = "out" } };

/// A sink that counts what a long run commits on the writer's channel, in one sequence.
const ChannelCounter = struct {
    lines: u64 = 0,
    bytes: u64 = 0,
    prepared: u64 = 0,
    aborted: u64 = 0,
    ordered: bool = true,

    fn prepare(context: *anyopaque, _: []const u8) bool {
        const self: *ChannelCounter = @ptrCast(@alignCast(context));
        self.prepared += 1;
        return true;
    }
    fn commit(context: *anyopaque, action: effects.Action) bool {
        const self: *ChannelCounter = @ptrCast(@alignCast(context));
        self.ordered = self.ordered and action.sequence == self.lines and action.channel == effects.writerChannel(1);
        self.lines += 1;
        self.bytes += action.text.len;
        return true;
    }
    fn abort(context: *anyopaque, _: []const u8) void {
        const self: *ChannelCounter = @ptrCast(@alignCast(context));
        self.aborted += 1;
    }
    fn sink(self: *ChannelCounter) effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }
};

test "a reader of 10 MiB in 100,000 lines through a digest run that reclaims each line as its frame ends" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const count = 100_000;
    // Lines of 104 bytes, each a little different from the one before it.
    const storage = try std.testing.allocator.alloc([104]u8, count);
    defer std.testing.allocator.free(storage);
    const lines = try std.testing.allocator.alloc([]const u8, count);
    defer std.testing.allocator.free(lines);
    for (storage, lines, 0..) |*bytes, *line, index| {
        @memset(bytes, 'a' + @as(u8, @intCast(index % 26)));
        line.* = bytes;
    }
    const streams = [_][]const []const u8{lines};
    // Both machines read a world of their own that answers alike.
    var reference_world: effects.Script = .{ .streams = &streams };
    var actual_world: effects.Script = .{ .streams = &streams };
    h.control.effects.inputs.source = reference_world.source();
    h.runtime.machine.control.effects.inputs.source = actual_world.source();
    h.control.effects.inputs.grants = &scale_grants;
    h.runtime.machine.control.effects.inputs.grants = &scale_grants;
    defer {
        Worlds.take(h);
        h.control.effects.inputs.grants = &.{};
        h.runtime.machine.control.effects.inputs.grants = &.{};
    }
    // The reader is opened in a region and read outside every region, by the body of a `For`.
    const program = try h.compile("Step(R:reader,T:i64)<transacts>:i64=T+Attempt(R.ReadLine[],\"\").Length\nRs<public>:[]reader=Attempt(array{OpenReader[\"in\"]},array{})\nBytes<public>:[]i64=For(R:Rs,Iterate(Bind(Step,R),100001,0))");
    const fuel = 1 << 34;
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "reader 100000 lines", program, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Rs\":[{\"$reader\":\"in\"}],\"Bytes\":[10400000],\"$inputs\":{\"count\":100001,\"bytes\":10400000}}\n", run.report);
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(@as(usize, count + 1), x.effects.inputs.len);
        try std.testing.expectEqual(effects.InputStatus.end, x.effects.inputs[count].status);
        try std.testing.expectEqual(@as(usize, count * 104), x.effects.input_bytes.len);
        // The lines were reclaimed with their frames: the pool holds a sliver of them.
        try std.testing.expect(x.program.strings.len < 1024 * 1024);
    }
    try std.testing.expect(run.actual.reclaims != 0);
    try std.testing.expectEqual(@as(u64, count + 1), reference_world.reads);
    try std.testing.expectEqual(@as(u64, count + 1), actual_world.reads);
    try budget(elapsedMs(begun) < 60_000);
}

test "a million lines on a writer through a sink by a log that holds none of them, and a region holds exactly what the log has room for" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    h.control.effects.inputs.grants = &scale_grants;
    h.runtime.machine.control.effects.inputs.grants = &scale_grants;
    defer {
        h.control.effects.sink = null;
        h.runtime.machine.control.effects.sink = null;
        h.control.effects.inputs.grants = &.{};
        h.runtime.machine.control.effects.inputs.grants = &.{};
    }
    const lines = 1_000_000;
    // The writer is opened in a region and written to outside every region, by the body of a
    // `For`: each line commits as it is written.
    const outside = try h.compile("Step(W:writer,S:i64)<transacts>:i64=Block{W.WriteLine(\"line {S} of a long run\");S+1}\nWs<public>:[]writer=Attempt(array{OpenWriter[\"out\"]},array{})\nTotal<public>:[]i64=For(W:Ws,Iterate(Bind(Step,W),1000000,0))");
    var reference: ChannelCounter = .{};
    var actual: ChannelCounter = .{};
    h.control.effects.sink = reference.sink();
    h.runtime.machine.control.effects.sink = actual.sink();
    const fuel = 1 << 32;
    var buffer: [128]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "write 1000000", outside, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Ws\":[{\"$writer\":\"out\"}],\"Total\":[1000000]}\n", run.report);
    for ([_]*const ChannelCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, lines), counter.lines);
        try std.testing.expectEqual(@as(u64, 0), counter.aborted);
        try std.testing.expect(counter.ordered);
    }
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expectEqual(@as(u64, lines), x.effects.output.count);
        try std.testing.expectEqual(@as(usize, 0), x.effects.entries.len + x.effects.bytes.len);
    }
    try std.testing.expect(run.reference.effects.output.eql(run.actual.effects.output));
    try std.testing.expectEqual(@as(u32, 0), h.control.effects.count + h.runtime.machine.control.effects.count);
    try budget(elapsedMs(begun) < 60_000);
    // The replay folded the lines of its own, on their channel.
    var forged = run.actual;
    forged.effects.output.digest ^= 1;
    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(outside, fuel), true, .{}));

    // Inside a region every line waits in the log: one more than it has entries stops both
    // machines at the same call, and nothing was shown.
    reference = .{};
    actual = .{};
    const format = "Step(W:writer,S:i64)<transacts>:i64=Block{{W.WriteLine(\"line {{S}}\");S+1}}\nTotal<public>:i64=Attempt(Block{{W:=OpenWriter[\"out\"];X:=Iterate(Bind(Step,W),{d},0);Require[X>0];X}},0-1)";
    var text: [512]u8 = undefined;
    const pending = try h.compile(try std.fmt.bufPrint(&text, format, .{types.limits.effect_entries + 1}));
    const outcome = evaluator.evaluateWithRuntimeStorage(pending, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const machine = h.runtime.evaluate(pending, fuel);
    try std.testing.expectEqualDeep(outcome.failed, machine.failed);
    try std.testing.expectEqual(types.Diagnostic.Code.effect_limit, machine.failed.code);
    try std.testing.expectEqualStrings("WriteLine", pending.source[machine.failed.span.start..machine.failed.span.end]);
    for ([_]*const ChannelCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, 0), counter.lines);
        try std.testing.expectEqual(@as(u64, types.limits.effect_entries), counter.aborted);
    }
    // Exactly as many fit, and commit in order when the region does.
    reference = .{};
    actual = .{};
    const fits = try h.compile(try std.fmt.bufPrint(&text, format, .{types.limits.effect_entries}));
    const kept = try longRun(h, again, "write 1048576 in a region", fits, fuel, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":1048576}\n", kept.report);
    for ([_]*const ChannelCounter{ &reference, &actual }) |counter| {
        try std.testing.expectEqual(@as(u64, types.limits.effect_entries), counter.lines);
        try std.testing.expect(counter.ordered and counter.aborted == 0);
    }
    try budget(elapsedMs(begun) < 120_000);
}

/// One program of `count` entries over `kind`: a literal of that type, a map converted to it,
/// lookups of the last, a middle and an absent key, and updates one key at a time.
fn keyedProgram(h: *harness.Harness, source: *std.ArrayList(u8), kind: []const u8, count: usize) !types.Program {
    source.clearRetainingCapacity();
    try source.print(std.testing.allocator, "Big:{s}(i64,i64)=map{{", .{kind});
    for (0..count) |i| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (i == 0) "" else ",", i, i * 3 });
    try source.appendSlice(std.testing.allocator, "}\nPlain:map(i64,i64)=map{");
    for (0..count) |i| try source.print(std.testing.allocator, "{s}{d}=>{d}", .{ if (i == 0) "" else ",", i, i + 1 });
    try source.print(std.testing.allocator, "}}\nFrom:{s}(i64,i64)=Plain\nPut(W:{s}(i64,i64),K:i64)<transacts>:{s}(i64,i64)=Block{{var C:{s}(i64,i64)=W;set C[K]=K*5;set C[0]=-1;C}}\nMore:{s}(i64,i64)=Put(Big,{d})\n", .{ kind, kind, kind, kind, kind, count });
    try source.print(std.testing.allocator, "Last<public>:i64=Attempt(Big[{d}],-1)\nNear<public>:i64=Attempt(From[{d}],-1)\nMiss<public>:i64=Attempt(Big[{d}],-1)\nAdded<public>:i64=Attempt(More[{d}],-1)\nFirst<public>:i64=Attempt(More[0],-2)\nKept<public>:i64=Attempt(Big[0],-2)\n", .{ count - 1, count / 2, count + 7, count });
    return h.compile(source.items);
}

test "a fifty thousand entry weak_map is built, converted from a map, looked up and updated as a map is, in the same fuel" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 50_000;
    const fuel = 64_000_000;
    var elapsed: [2]u64 = undefined;
    for ([_][]const u8{ "weak_map", "map" }, 0..) |kind, index| {
        const program = try keyedProgram(h, &source, kind, count);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.run(program, fuel);
        elapsed[index] = elapsedMs(start);
        if (x == .failed) std.debug.print("{s} scale test failed: {s}\n", .{ kind, x.failed.message() });
        try std.testing.expectEqual(@as(i64, (count - 1) * 3), x.ok.get("Last").?.integer);
        try std.testing.expectEqual(@as(i64, count / 2 + 1), x.ok.get("Near").?.integer);
        try std.testing.expectEqual(@as(i64, -1), x.ok.get("Miss").?.integer);
        try std.testing.expectEqual(@as(i64, count * 5), x.ok.get("Added").?.integer);
        try std.testing.expectEqual(@as(i64, -1), x.ok.get("First").?.integer);
        try std.testing.expectEqual(@as(i64, 0), x.ok.get("Kept").?.integer);
        // The update appended one entry and replaced one in place: insertion order is kept.
        const more = x.ok.elements(x.ok.get("More").?).?;
        try std.testing.expectEqual(@as(usize, 2 * (count + 1)), more.len);
        try std.testing.expectEqual(@as(i64, count), more[2 * count].integer);
        try std.testing.expectEqual(@as(i64, -1), more[1].integer);
        // A budget that covers the literals but not the lookups stops both machines alike.
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, 1_000_000)).failed.code);
    }
    std.debug.print("weak_map entries={d}: {d}ms, the same program over a map: {d}ms\n", .{ count, elapsed[0], elapsed[1] });
    try budget(elapsed[0] <= 3 * elapsed[1] + 200);
    // At a smaller size, where every budget can be tried, the two programs need the same fuel
    // but for the one `upcast` that converts `Plain`, a node of fuel.
    const weak = try keyedProgram(h, &source, "weak_map", 64);
    var weak_fuel: u64 = 0;
    while ((try h.run(weak, weak_fuel)) == .failed) weak_fuel += 1;
    const plain = try keyedProgram(h, &source, "map", 64);
    var plain_fuel: u64 = 0;
    while ((try h.run(plain, plain_fuel)) == .failed) plain_fuel += 1;
    try std.testing.expectEqual(plain_fuel + 1, weak_fuel);
}

// RFC-0087, P5.4: a session cell at scale. Five million updates, each building the cell's map
// anew (two members), run in a member pool they would fill more than twice: the cell is a root
// the reclamation keeps, and everything else it drops. The same program over an ordinary cell
// of `weak_map(i64, i64)` needs more fuel (a read of the whole cell and a write of it around
// each lookup and update) and no less time.
test "rfc0087 P5.4: five million updates of a session cell run in a pool they would fill twice, with a replayed report" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const iterations = 5_000_000;
    comptime std.debug.assert(2 * iterations > 2 * types.limits.aggregate_elements);
    const keyed = try h.compile("var Count<public>:weak_map(session,i64)=map{}\nStep(S:i64)<reads><writes>:i64=Block{K:=GetSession();set Count[K]=Attempt(Count[K],0)+1;S+1}\nTotal<public>:i64=Iterate(Step,5000000,0)\nSeen<public>:i64=Attempt(Count[GetSession()],0)");
    const fuel = 1 << 32;
    // Without reclamation the pool is the ceiling.
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, try unreclaimed(h, keyed, fuel));
    const begun = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [128]u8 = undefined;
    const run = try longRun(h, again, "session cell updated 5000000 times", keyed, fuel, &buffer);
    const keyed_ms = elapsedMs(begun);
    try std.testing.expectEqualStrings("{\"Count\":[{\"$session\":0},5000000],\"Total\":5000000,\"Seen\":5000000}\n", run.report);
    for ([_]evaluator.Execution{ run.reference, run.actual }) |x| {
        try std.testing.expect(x.reclaims > 0);
        // What is left is the cell's last map.
        try std.testing.expectEqual(@as(usize, 2), x.aggregate_values.len);
        try std.testing.expectEqual(@as(i64, iterations), x.elements(x.cells[0].value).?[1].integer);
    }
    try budget(keyed_ms < 60_000);
    // The same over an ordinary cell, keyed by an integer.
    const ordinary = try h.compile("var Count<public>:weak_map(i64,i64)=map{}\nStep(S:i64)<reads><writes>:i64=Block{set Count[0]=Attempt(Count[0],0)+1;S+1}\nTotal<public>:i64=Iterate(Step,5000000,0)\nSeen<public>:i64=Attempt(Count[0],0)");
    const start = std.Io.Clock.awake.now(std.testing.io);
    const plain = try longRun(h, again, "ordinary weak_map cell updated 5000000 times", ordinary, fuel, &buffer);
    const ordinary_ms = elapsedMs(start);
    try std.testing.expectEqualStrings("{\"Count\":[0,5000000],\"Total\":5000000,\"Seen\":5000000}\n", plain.report);
    std.debug.print("session cell: {d}ms, ordinary cell: {d}ms\n", .{ keyed_ms, ordinary_ms });
    try budget(keyed_ms <= 2 * ordinary_ms + 1000);
    // At a size where every budget can be tried, the session cell needs less fuel: per step,
    // its lookup and update are two nodes where the ordinary cell's are four.
    // (Each is compiled just before it runs: a program borrows the compiler's workspace.)
    const ordinary_fuel = try leastFuelOfBoth(h, try h.compile("var Count:weak_map(i64,i64)=map{}\nStep(S:i64)<reads><writes>:i64=Block{set Count[0]=Attempt(Count[0],0)+1;S+1}\nTotal<public>:i64=Iterate(Step,20,0)"), 1 << 20);
    const keyed_fuel = try leastFuelOfBoth(h, try h.compile("var Count:weak_map(session,i64)=map{}\nStep(S:i64)<reads><writes>:i64=Block{K:=GetSession();set Count[K]=Attempt(Count[K],0)+1;S+1}\nTotal<public>:i64=Iterate(Step,20,0)"), 1 << 20);
    std.debug.print("least fuel of 20 updates: session cell {d}, ordinary cell {d}\n", .{ keyed_fuel, ordinary_fuel });
    try std.testing.expect(keyed_fuel < ordinary_fuel);
}

// RFC-0085, I3: nested functions at scale. Two thousand in one block, each found by name among
// all those in scope and each carrying the capture of the function around it, compile in time
// linear in their number; and a million calls of one that increments a shared local.
test "rfc0085 I3: two thousand nested functions in one block, and a million calls of a counter" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 2000;
    // Each calls the one before it, but every fiftieth starts a chain again, which keeps the
    // calls shallow: `G{i}(K) = K + N + i % 50`.
    try source.appendSlice(std.testing.allocator, "Chain(N:i64)<computes>:i64 = Block{\n");
    for (0..count) |i| {
        if (i % 50 == 0) try source.print(std.testing.allocator, "    G{d}(K:i64)<computes>:i64 = K + N\n", .{i}) else try source.print(std.testing.allocator, "    G{d}(K:i64)<computes>:i64 = G{d}(K) + 1\n", .{ i, i - 1 });
    }
    try source.print(std.testing.allocator, "    G{d}(1) + G0(2)\n}}\nValue<public>:i64 = Chain(10)\n", .{count - 1});
    const compiled = std.Io.Clock.awake.now(std.testing.io);
    const chain = try h.compile(source.items);
    try budget(elapsedMs(compiled) < 10_000);
    var nested: usize = 0;
    for (chain.functions) |f| if (f.nested) {
        nested += 1;
    };
    try std.testing.expectEqual(@as(usize, count), nested);
    const result = try h.run(chain, 1 << 24);
    try std.testing.expectEqual(@as(i64, (1 + 10 + (count - 1) % 50) + (2 + 10)), result.ok.get("Value").?.integer);
    const counter =
        \\counter := tuple(function<reads>(tuple(), i64), function<transacts>(tuple(), void))
        \\MakeCounter(I:i64)<transacts>:counter = Block{
        \\    var N:i64 = I
        \\    Get()<reads>:i64 = N
        \\    Inc()<transacts>:void = Set(N, N + 1)
        \\    tuple{Get, Inc}
        \\}
        \\Run(Steps:i64)<transacts>:i64 = Block{
        \\    C := MakeCounter(0)
        \\    Step(S:i64)<transacts>:i64 = Block{ C(1)(); S + 1 }
        \\    Last := Iterate(Step, Steps, 0)
        \\    Last * 1000000 + C(0)()
        \\}
        \\Total<public>:i64 = Run(1000000)
    ;
    const program = try h.compile(counter);
    var buffer: [256]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "nested counter 1000000", program, 1 << 32, &buffer);
    try std.testing.expectEqualStrings("{\"Total\":1000001000000}\n", run.report);
    try budget(elapsedMs(begun) < 60_000);
}

test "rfc0085 I11: forbic qualify of eight thousand functions notes eight times what one thousand note, in linear time" {
    try requireProgram();
    const qualify = @import("qualify.zig");
    const w = try scratch.storage(@import("compiler.zig").Workspace);
    defer scratch.release(w);
    scratch.initialise(w);
    w.qualify = true;
    var counts: [2]u32 = undefined;
    var times: [2]u64 = undefined;
    var printed: [2]usize = undefined;
    const written = scratch.alloc(types.Span, 1) orelse return error.OutOfMemory;
    defer scratch.free(written);
    for ([_]usize{ 1000, 8000 }, 0..) |blocks, round| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        for (0..blocks) |index| try source.print(std.testing.allocator, "F{d}(X:i64)<computes>:i64 = Block{{ Y := X + {d}; Y * 2 }}\nV{d}:i64 = F{d}({d})\n", .{ index, index, index, index, index });
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = w.compile(source.items).ok;
        try qualify.write(w.qualification(program, written), &out.writer);
        times[round] = elapsedMs(start);
        counts[round] = w.resolution_count;
        printed[round] = out.written().len;
        try std.testing.expectEqual(@as(u32, 0), w.resolution_conflicts);
    }
    // Each block notes the same ten identifiers: F, X, i64, i64, Y, X, Y, V, i64, F.
    try std.testing.expectEqual(@as(u32, 10 * 1000), counts[0]);
    try std.testing.expectEqual(8 * counts[0], counts[1]);
    try std.testing.expect(printed[1] > 8 * printed[0]);
    try budget(times[1] < 16 * times[0] + 200);
}

// RFC-0086, P2.4: scale test 5 (writing). A journal of a million actions in a thousand regions,
// each region one commit point, synced in groups of sixteen seals, on a disk of each machine's
// own: both write the same journal, and its time is the run's with the journal's work in it.
test "a journal of a million actions in a thousand regions, synced in groups, written alike by both machines" {
    try requireProgram();
    const durable = @import("durable.zig");
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const disk_bytes = 64 * 1024 * 1024;
    var memories: [2]durable.Memory = undefined;
    var journals: [2]durable.Journal = undefined;
    var buffers: [2][4096]u8 = undefined;
    for (&memories, &journals, &buffers) |*memory, *journal, *buffer| {
        memory.* = .{ .bytes = try std.testing.allocator.alloc(u8, disk_bytes) };
        journal.* = .init(memory.disk(), buffer);
        journal.group = 16;
        var header: [256]u8 = undefined;
        try journal.start(try durable.encodeHeader(.{ .toolchain = "scale", .profile = "program", .program = @splat(0), .seed = effects.default_seed, .tick_rate = 60, .grants = &.{} }, &header));
    }
    defer for (&memories) |*memory| std.testing.allocator.free(memory.bytes);
    h.control.effects.sink = journals[0].sink();
    h.runtime.machine.control.effects.sink = journals[1].sink();
    h.control.effects.inputs.grants = &scale_grants;
    h.runtime.machine.control.effects.inputs.grants = &scale_grants;
    defer {
        h.control.effects.sink = null;
        h.runtime.machine.control.effects.sink = null;
        h.control.effects.inputs.grants = &.{};
        h.runtime.machine.control.effects.inputs.grants = &.{};
    }
    const program = try h.compile("Step(W:writer,S:i64)<transacts>:i64=Block{W.WriteLine(\"line {S}\");S+1}\nRegion(W:writer,K:i64)<transacts>:i64=Attempt(Block{X:=Iterate(Bind(Step,W),1000,K);Require[X>K];X},K)\nWs<public>:[]writer=Attempt(array{OpenWriter[\"out\"]},array{})\nTotal<public>:[]i64=For(W:Ws,Iterate(Bind(Region,W),1000,0))");
    const fuel = 1 << 34;
    var report: [128]u8 = undefined;
    const begun = std.Io.Clock.awake.now(std.testing.io);
    const run = try longRun(h, again, "journal 1000000 actions", program, fuel, &report);
    const run_ms = elapsedMs(begun);
    try std.testing.expectEqualStrings("{\"Ws\":[{\"$writer\":\"out\"}],\"Total\":[1000000]}\n", run.report);
    for (&journals) |*journal| try journal.finish(.{ .outcome = .completed });
    try std.testing.expectEqualSlices(u8, memories[0].contents(), memories[1].contents());
    // The header's sync, one per sixteen seals, and the end's.
    for (journals) |journal| try std.testing.expectEqual(@as(u64, 1 + 1000 / 16 + 1), journal.syncs);
    const scanned = std.Io.Clock.awake.now(std.testing.io);
    var image: durable.Image = .{ .bytes = memories[0].contents() };
    var buffer: [4096]u8 = undefined;
    var prefix = try durable.Prefix.init(image.disk(), &buffer);
    var actions: u64 = 0;
    var seals: u64 = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => actions += 1,
        .seal => |seal| {
            seals += 1;
            try std.testing.expectEqual(seals * 1000, seal.actions);
        },
        else => {},
    };
    const scan_ms = elapsedMs(scanned);
    try std.testing.expectEqual(@as(u64, 1_000_000), actions);
    try std.testing.expectEqual(@as(u64, 1000), seals);
    std.debug.print("journal of 1000000 actions: {d} bytes, {d} syncs per machine, both machines with the replay {d}ms, cut and read back {d}ms\n", .{ memories[0].len, journals[0].syncs, run_ms, scan_ms });
    try budget(run_ms < 60_000 and scan_ms < 10_000);

    // RFC-0086, P2.5: scale test 5 (resuming). A crash after the 500th seal, the next record torn:
    // each machine's disk is cut there (R1), and the run resumed from its start verifies the half
    // that was sealed and appends the other half (R4), to the journal written whole.
    const whole = try std.testing.allocator.dupe(u8, memories[0].contents());
    defer std.testing.allocator.free(whole);
    var middle: u64 = 0;
    {
        var whole_image: durable.Image = .{ .bytes = whole };
        var reading = try durable.Prefix.init(whole_image.disk(), &buffer);
        var count: u64 = 0;
        while (try reading.next()) |record| if (record.decoded == .seal) {
            count += 1;
            if (count == 500) middle = record.item.end;
        };
    }
    const kept: usize = @intCast(middle + 13);
    const sealed = try scratch.storage([2]durable.SealedInputs);
    defer scratch.release(sealed);
    const resumed = std.Io.Clock.awake.now(std.testing.io);
    for (&memories, &journals, &buffers, sealed, [2]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |*memory, *journal, *side_buffer, *inputs, control| {
        @memcpy(memory.bytes[0..kept], whole[0..kept]);
        memory.len = kept;
        memory.synced = kept;
        journal.* = .init(memory.disk(), side_buffer);
        journal.group = 16;
        const found = try durable.scan(memory.disk(), side_buffer);
        try std.testing.expectEqual(@as(u64, 500_000), found.actions);
        try durable.cutAt(memory.disk(), found);
        control.effects.inputs.prefix = try inputs.load(memory.disk(), side_buffer);
        journal.resumeAt(found);
    }
    const cut_ms = elapsedMs(resumed);
    defer {
        h.control.effects.inputs.prefix = .{};
        h.runtime.machine.control.effects.inputs.prefix = .{};
    }
    const rerun = std.Io.Clock.awake.now(std.testing.io);
    const again_run = try longRun(h, again, "journal 1000000 actions resumed from 500000", program, fuel, &report);
    try std.testing.expectEqualStrings("{\"Ws\":[{\"$writer\":\"out\"}],\"Total\":[1000000]}\n", again_run.report);
    for (&journals) |*journal| {
        try std.testing.expect(!journal.diverged and !journal.verifying());
        try journal.finish(.{ .outcome = .completed });
    }
    const resume_ms = elapsedMs(rerun);
    for (memories) |memory| try std.testing.expectEqualSlices(u8, whole, memory.contents());
    std.debug.print("journal of 1000000 actions resumed from its middle: cut and read the sealed inputs {d}ms, both machines with the replay {d}ms\n", .{ cut_ms, resume_ms });
    try budget(cut_ms < 10_000 and resume_ms < 60_000);
}

test "rfc0085 I4: five hundred overloads of a nested function, and defaults as many as the parameter limit" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 500;
    // `F(X:cK)` for five hundred unrelated classes: each overload is checked against those before
    // it, and each call chooses among them by the class of its argument.
    for (0..count) |k| try source.print(std.testing.allocator, "c{d} := class{{}}\n", .{k});
    try source.appendSlice(std.testing.allocator, "Run(N:i64)<transacts>:i64 = Block{\n");
    for (0..count) |k| try source.print(std.testing.allocator, "    F(X:c{d})<computes>:i64 = {d} + N\n", .{ k, k });
    try source.appendSlice(std.testing.allocator, "    0");
    for (0..count) |k| try source.print(std.testing.allocator, " + F(c{d}{{}})", .{k});
    try source.appendSlice(std.testing.allocator, "\n}\n");
    // A nested function with the active profile's limit of parameters, every one after the
    // first defaulted to the one before it plus one, called with the first alone.
    const limit = types.limits.parameters;
    try source.appendSlice(std.testing.allocator, "Wide()<computes>:i64 = Block{\n    G(P0:i64");
    for (1..limit) |i| try source.print(std.testing.allocator, ", P{d}:i64 = P{d} + 1", .{ i, i - 1 });
    try source.appendSlice(std.testing.allocator, ")<computes>:i64 = P0");
    for (1..limit) |i| try source.print(std.testing.allocator, " + P{d}", .{i});
    try source.appendSlice(std.testing.allocator, "\n    G(1)\n}\nValue<public>:i64 = Run(1)\nTotal<public>:i64 = Wide()\n");
    const compiled = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    try budget(elapsedMs(compiled) < 10_000);
    const result = try h.run(program, 1 << 24);
    try std.testing.expectEqual(@as(i64, count * (count - 1) / 2 + count), result.ok.get("Value").?.integer);
    try std.testing.expectEqual(@as(i64, limit * (limit + 1) / 2), result.ok.get("Total").?.integer);
}

// RFC-0087, P5.2: `<persistable>` at scale. A thousand persistable structs of eight defaults
// each, and one whose defaults are an array and a map of thirty thousand literals, compile and
// are admitted by both machines in about the time of the same program without the specifier;
// the table holds every default as a constant. A map default forged to hold two equal keys
// among them is refused in time linear in the table (the classes of `persistable.zig`).
test "rfc0087 P5.2: a thousand persistable structs and defaults of thirty thousand literals, compiled and admitted in linear time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const types_count = 1000;
    const literals = 30_000;
    var elapsed: [2]u64 = undefined;
    var constants: usize = 0;
    for ([_][]const u8{ "<persistable>", "" }, 0..) |specifier, index| {
        source.clearRetainingCapacity();
        for (0..types_count) |t| {
            try source.print(std.testing.allocator, "s{d}:=struct{s}{{", .{ t, specifier });
            for (0..8) |f| try source.print(std.testing.allocator, "{s}F{d}:i64={d}", .{ if (f == 0) "" else ",", f, t * 8 + f });
            try source.appendSlice(std.testing.allocator, "}\n");
        }
        try source.print(std.testing.allocator, "big:=struct{s}{{A:[]i64=array{{", .{specifier});
        for (0..literals) |i| try source.print(std.testing.allocator, "{s}{d}", .{ if (i == 0) "" else ",", i });
        try source.appendSlice(std.testing.allocator, "},M:map(i64,string)=map{");
        for (0..literals) |i| try source.print(std.testing.allocator, "{s}{d}=>\"v\"", .{ if (i == 0) "" else ",", i });
        try source.print(std.testing.allocator, "}}}}\nV<public>:i64=s{d}{{}}.F7+big{{}}.A.Length\n", .{types_count - 1});
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        try std.testing.expect(evaluator.validate(program, types.limits.nodes) == null);
        const x = try h.run(program, 64_000_000);
        elapsed[index] = elapsedMs(start);
        try std.testing.expectEqual(@as(i64, types_count * 8 - 1 + literals), x.ok.get("V").?.integer);
        if (index == 0) {
            constants = program.constants.len;
            // Eight per struct, and the two aggregates with their members.
            try std.testing.expectEqual(@as(usize, types_count * 8 + 2 + 3 * literals), constants);
            // Two keys of the map made one: refused by both machines, in about the same time.
            const members = try std.testing.allocator.dupe(u32, program.constant_members);
            defer std.testing.allocator.free(members);
            const map = program.constants[program.fields[program.fields.len - 1].constant.?].kind.aggregate;
            members[map.end - 2] = members[map.start];
            var forged = program;
            forged.constant_members = members;
            const refused_at = std.Io.Clock.awake.now(std.testing.io);
            try harness.invalid(h, forged);
            const refusal = elapsedMs(refused_at);
            std.debug.print("persistable: a forged map of {d} keys refused in {d}ms\n", .{ literals, refusal });
            try budget(refusal < 2_000);
        }
    }
    std.debug.print("persistable types={d}, constants={d}: {d}ms, without the specifier: {d}ms\n", .{ types_count, constants, elapsed[0], elapsed[1] });
    try budget(elapsed[0] <= 3 * elapsed[1] + 500);
}

// RFC-0087, P5.3, scale test 4: `ToJson` and `FromJson` of an array of a million records
// (2^20, made by doubling, which extends the array in place), on both machines and in the
// replay, in time linear in the text. The array holds one record many times; its text writes
// it at each place, and decoding builds each of them. The text, some 50 MB, is most of the
// string pool.
test "rfc0087 P5.3: ToJson and FromJson of an array of a million records" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const count = 1 << 20;
    const program = try h.compile(
        \\r := struct<persistable>{A:i64 = 0}
        \\Double(Xs:[]r)<computes>:[]r = Xs + Xs
        \\All:[]r = Iterate(Double, 20, array{r{A := 7}})
        \\Text:string = ToJson(All)
        \\Back:[]r = Attempt(FromJson[[]r][Text], array{})
        \\Length<public>:i64 = Back.Length
        \\Last<public>:i64 = Attempt(Back[1048575].A, -1)
        \\Bytes<public>:i64 = Text.Length
    );
    const start = std.Io.Clock.awake.now(std.testing.io);
    const result = try h.run(program, 1 << 32);
    const elapsed = elapsedMs(start);
    if (result == .failed) std.debug.print("a million records: {s}\n", .{result.failed.message()});
    try std.testing.expectEqual(@as(i64, count), result.ok.get("Length").?.integer);
    try std.testing.expectEqual(@as(i64, 7), result.ok.get("Last").?.integer);
    const bytes = result.ok.get("Bytes").?.integer;
    std.debug.print("ToJson and FromJson of {d} records ({d} bytes), both machines and the replay: {d}ms\n", .{ count, bytes, elapsed });
    try budget(elapsed < 60_000);
}

// RFC-0087, P5.3, scale test 5: values and texts nested exactly `json_depth` deep, and one
// container more: a chain of nodes, each an object and the array of its one child, the
// innermost with an empty array. `ToJson` of the deeper value is the fatal `json_depth_limit`;
// `FromJson` of the deeper text fails.
test "rfc0087 P5.3: json_depth exactly and one more, for ToJson and FromJson" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const persist_json = @import("persist_json.zig");
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const links = persist_json.json_depth / 2;
    const head =
        \\node := class<final><persistable>{Kids:[]node = array{}}
        \\Chain(N:i64)<allocates>:node = Iterate(Fn(X:node)<allocates>:node{node{Kids := array{X}}}, N - 1, node{})
        \\
    ;
    const tail =
        \\Text:string = ToJson(Deep)
        \\Back<public>:logic = Attempt(Block{FromJson[node][Text]; true}, false)
        \\Deeper<public>:logic = Attempt(Block{FromJson[node]["\{\"x_Kids\":[" + Text + "]\}"]; true}, false)
        \\Bytes<public>:i64 = Text.Length
        \\
    ;
    try source.print(std.testing.allocator, "{s}Deep:node = Chain({d})\n{s}", .{ head, links, tail });
    const start = std.Io.Clock.awake.now(std.testing.io);
    const exact = try h.run(try h.compile(source.items), 1 << 32);
    if (exact == .failed) std.debug.print("json_depth: {s}\n", .{exact.failed.message()});
    try std.testing.expect(exact.ok.get("Back").?.boolean);
    try std.testing.expect(!exact.ok.get("Deeper").?.boolean);
    const bytes = exact.ok.get("Bytes").?.integer;
    var deeper: std.ArrayList(u8) = .empty;
    defer deeper.deinit(std.testing.allocator);
    try deeper.print(std.testing.allocator, "{s}Deep:node = Chain({d})\nText:string = ToJson(Deep)\n", .{ head, links + 1 });
    const beyond = try h.run(try h.compile(deeper.items), 1 << 32);
    try std.testing.expectEqual(types.Diagnostic.Code.json_depth_limit, beyond.failed.code);
    std.debug.print("json_depth {d}: a text of {d} bytes encoded and decoded, and one link more refused: {d}ms\n", .{ persist_json.json_depth, bytes, elapsedMs(start) });
    try budget(elapsedMs(start) < 30_000);
}

// RFC-0087, P5.3 (review): a text of more elements than the program profile's members, whose
// last element is wrong, fails as `FromJson` does, building nothing; the same text with that
// element right needs more members than there are, which is fatal.
test "rfc0087 P5.3: a large text that does not decode fails, and only a valid one meets the capacities" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const head = "Double(X:string)<computes>:string = X + X\nS:string = Iterate(Double, 22, \"1,\")\n";
    const start = std.Io.Clock.awake.now(std.testing.io);
    const bad = try h.run(try h.compile(head ++ "A:i64 = Attempt(FromJson[[]i64][\"[\" + S + \"x]\"].Length, -1)"), 1 << 32);
    if (bad == .failed) std.debug.print("a large invalid text: {s}\n", .{bad.failed.message()});
    try std.testing.expectEqual(@as(i64, -1), bad.ok.get("A").?.integer);
    const good = try h.run(try h.compile(head ++ "A:i64 = Attempt(FromJson[[]i64][\"[\" + S + \"1]\"].Length, -1)"), 1 << 32);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, good.failed.code);
    std.debug.print("a text of 2^22 + 1 elements refused, and the valid one at aggregate_limit: {d}ms\n", .{elapsedMs(start)});
    try budget(elapsedMs(start) < 30_000);
}

// RFC-0082, P3.8: two `For` loops with a filter and a binding, each waiting for the next tick in
// every one of ten thousand iterations, in a digest run that the replay checks. A `For` that
// built its array in a task's frames cost the square of its length in every machine, with a
// site or without (an open item of P3.8, as on base56), so the test stayed at ten thousand; since
// w15 these loops of integers grow into their rooms.
const concurrency_for = @import("concurrency_for_tests.zig");

test "rfc0082 P3.8: two For loops that wait in every one of ten thousand iterations" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const start = std.Io.Clock.awake.now(std.testing.io);
    try concurrency_for.suspendingLoops(f, 10_000);
    try budget(elapsedMs(start) < 60_000);
}

// RFC-0085, I6: shared locals at scale. Each test measures what the RFC says must stay linear
// (compile time, reclamation) at two sizes four times apart and asserts it with `budget()`.

/// `Run` with `count` blocks, each a local an `Fn` shares (S1d): every one is a cell of its own.
fn sharedLocalsProgram(source: *std.ArrayList(u8), count: usize) !void {
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "Run(S:i64)<transacts>:i64 = Block{\n    var Total:i64 = 0\n");
    for (0..count) |i| try source.print(std.testing.allocator, "    Block{{ var X{d}:i64 = S + {d}; G{d} := Fn()<transacts>:i64{{ Set(X{d}, X{d} * 2) }}; set Total = Total + G{d}() + X{d}; 0 }}\n", .{ i, i, i, i, i, i, i });
    try source.appendSlice(std.testing.allocator, "    Total\n}\nValue<public>:i64 = Run(1)\n");
}

test "rfc0085 I6: eight thousand shared locals, each a cell, compile in time linear in their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const sizes = [_]usize{ 2000, 8000 };
    var times: [2]u64 = undefined;
    for (sizes, &times) |count, *time| {
        try sharedLocalsProgram(&source, count);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        // One `ref_new` per local, and sharing cost one compile more than a program without it.
        var cells: usize = 0;
        for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .ref_new) {
            cells += 1;
        };
        for (program.nodes) |node| if (node.kind == .ref_new) {
            cells += 1;
        };
        try std.testing.expectEqual(count, cells);
        const result = try h.run(program, 1 << 26);
        // Each block adds the doubled local twice: 4 * (1 + i).
        const n: i64 = @intCast(count);
        try std.testing.expectEqual(4 * (n + @divExact(n * (n - 1), 2)), result.ok.get("Value").?.integer);
    }
    std.debug.print("shared locals: {d} in {d}ms, {d} in {d}ms\n", .{ sizes[0], times[0], sizes[1], times[1] });
    // Four times the locals: linear is four times the time, quadratic sixteen.
    try budget(times[1] < 7 * times[0] + 300);
}

/// `chains` functions, each with `depth` closures nested in each other, alternately nested
/// functions and `Fn`s, the innermost assigning the local of the outermost function, which each
/// level reads too: every level captures the cell through the level around it (S1, S2).
fn deepClosuresProgram(source: *std.ArrayList(u8), depth: usize, chains: usize) !void {
    source.clearRetainingCapacity();
    for (0..chains) |chain| {
        try source.print(std.testing.allocator, "Deep{d}(S:i64)<transacts>:i64 = Block{{\n    var C:i64 = S\n    ", .{chain});
        for (0..depth - 1) |k| {
            if (k % 2 == 0) try source.print(std.testing.allocator, "G{d}()<transacts>:i64 = Block{{ ", .{k}) else try source.print(std.testing.allocator, "G{d} := Fn()<transacts>:i64{{ Block{{ ", .{k});
        }
        const last = depth - 1;
        if (last % 2 == 0) try source.print(std.testing.allocator, "G{d}()<transacts>:i64 = Set(C, C + 1)", .{last}) else try source.print(std.testing.allocator, "G{d} := Fn()<transacts>:i64{{ Set(C, C + 1) }}", .{last});
        var k = depth - 1;
        while (k > 0) {
            k -= 1;
            try source.print(std.testing.allocator, "; G{d}() + C }}", .{k + 1});
            if (k % 2 == 1) try source.appendSlice(std.testing.allocator, " }");
        }
        try source.print(std.testing.allocator, "\n    G0() + C\n}}\nValue{d}<public>:i64 = Deep{d}({d})\n", .{ chain, chain, chain });
    }
}

/// Compiles and runs `deepClosuresProgram` and checks every chain's value; the compile's time.
fn deepClosures(h: *harness.Harness, source: *std.ArrayList(u8), depth: usize, chains: usize) !u64 {
    try deepClosuresProgram(source, depth, chains);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const time = elapsedMs(start);
    var nested: usize = 0;
    for (program.functions) |f| if (f.nested) {
        nested += 1;
    };
    try std.testing.expectEqual(chains * ((depth + 1) / 2), nested);
    const result = try h.run(program, 1 << 26);
    var name: [32]u8 = undefined;
    for (0..chains) |chain| {
        // The innermost makes the cell `S + 1` and yields it; each level around adds the cell.
        const s: i64 = @intCast(chain);
        try std.testing.expectEqual(@as(i64, @intCast(depth + 1)) * (s + 1), result.ok.get(try std.fmt.bufPrint(&name, "Value{d}", .{chain})).?.integer);
    }
    return time;
}

test "rfc0085 I6: closures nested over one cell compile in time linear in their number, and four hundred deep" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    // Four times as many chains fifty deep: four times the time.
    const few = try deepClosures(h, &source, 50, 20);
    const many = try deepClosures(h, &source, 50, 80);
    // One chain four times deeper: the capture scan of RFC-0054 reads each closure's body for
    // its free names, and every level's body holds the levels inside it, so the time grows with
    // the square of the depth, for `Fn`s as for nested functions (measured: 800 levels of `Fn`s
    // alone, with no cell, take 150 ms). Recorded in "I6 as implemented"; this bounds it.
    const shallow = try deepClosures(h, &source, 100, 1);
    const deep = try deepClosures(h, &source, 400, 1);
    std.debug.print("nested closures: 20 chains in {d}ms, 80 chains in {d}ms; 100 levels in {d}ms, 400 levels in {d}ms\n", .{ few, many, shallow, deep });
    try budget(many < 7 * few + 300);
    try budget(deep < 24 * shallow + 300 and deep < 2000);
}

/// `Run` spawns `count` tasks that each write the one cell `C` after a sleep.
fn fanOutProgram(buffer: []u8, count: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\var Out:i64 = 0
        \\Run(N:i64)<transacts><suspends>:i64 = Block{{
        \\    var C:i64 = 0
        \\    var I:i64 = 0
        \\    Loop{{ If(I >= N, Break(), false); set I = I + 1; K := I; Spawn{{ Sleep(1.0); Set(C, C + K) }}; 0 }}
        \\    Sleep(2.0)
        \\    set Out = C
        \\    C
        \\}}
        \\P:task(i64) = Spawn{{ Run({d}) }}
    , .{count});
}

test "rfc0085 I6: a fan-out of sixty thousand tasks writes one cell, and reclaims in time linear in their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var text: [1024]u8 = undefined;
    var report: [256]u8 = undefined;
    const sizes = [_]usize{ 15_000, 60_000 };
    // The host's floor, at which the larger fan-out reclaims as its tasks complete, and a small
    // one at which both reclaim all along.
    for ([_]u32{ types.ControlStorage.default_reclaim_floor, 4096 }) |floor| {
        var times: [2]u64 = undefined;
        var reclaims: [2]u64 = undefined;
        for (sizes, &times, &reclaims) |count, *time, *made| {
            const program = try h.compile(try fanOutProgram(&text, count));
            const start = std.Io.Clock.awake.now(std.testing.io);
            const run = try longRunAt(h, again, "fan-out of one cell", program, 1 << 36, floor, &report);
            time.* = elapsedMs(start);
            made.* = run.actual.reclaims;
            const n: i64 = @intCast(count);
            try std.testing.expectEqual(@divExact(n * (n + 1), 2), run.actual.cells[0].value.integer);
            try std.testing.expectEqual(@as(u64, count + 1), run.actual.scheduler.completed);
        }
        std.debug.print("fan-out of one cell at floor {d}: {d} tasks in {d}ms ({d} reclaims), {d} tasks in {d}ms ({d} reclaims)\n", .{ floor, sizes[0], times[0], reclaims[0], sizes[1], times[1], reclaims[1] });
        // Each reclamation examines every task: it is paid for by what the run appended since
        // the one before, also when a task completes after a switch (I6-D3). The
        // larger fan-out once reclaimed 7,826 times at the host's floor and took 80 seconds.
        try std.testing.expect(reclaims[1] > 0 and reclaims[1] < 200);
        try budget(times[1] < 7 * times[0] + 500 and times[1] < 30_000);
    }
}

/// Each of `count` visits makes a cell, a task that writes it after a sleep and a closure, waits
/// for the task and drops all three: two switches a visit. A service task meanwhile sleeps and
/// writes a cell of its own through a closure across every switch (RFC-0082 P3.5's path).
fn switchesProgram(buffer: []u8, count: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\var Out:i64 = 0
        \\var Served:i64 = 0
        \\Visit(I:i64)<transacts><suspends>:i64 = Block{{ var C:i64 = I; Get := Fn()<reads>:i64{{ C }}; T := Spawn{{ Sleep(1.0); Set(C, C + 1) }}; T.Await(); Get() }}
        \\Service(N:i64)<transacts><suspends>:i64 = Block{{
        \\    var D:i64 = 0
        \\    Bump := Fn()<transacts>:void{{ Set(D, D + 1) }}
        \\    Loop{{ If(D >= N, Break(), false); Sleep(1.0); Bump() }}
        \\    set Served = D
        \\    D
        \\}}
        \\Run(N:i64)<transacts><suspends>:i64 = Block{{
        \\    var I:i64 = 0
        \\    var Sum:i64 = 0
        \\    Loop{{ If(I >= N, Break(), false); set Sum = Sum + Visit(I); set I = I + 1 }}
        \\    set Out = Sum
        \\    Sum
        \\}}
        \\S:task(i64) = Spawn{{ Service({d}) }}
        \\P:task(i64) = Spawn{{ Run({d}) }}
    , .{ count, count });
}

test "rfc0085 I6: cells made and dropped across four hundred thousand switches are reclaimed in linear time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var text: [2048]u8 = undefined;
    var report: [256]u8 = undefined;
    const sizes = [_]usize{ 25_000, 100_000 };
    var times: [2]u64 = undefined;
    var left: [2]usize = undefined;
    for (sizes, &times, &left) |count, *time, *cells| {
        const program = try h.compile(try switchesProgram(&text, count));
        const start = std.Io.Clock.awake.now(std.testing.io);
        const run = try longRunAt(h, again, "cells across switches", program, 1 << 36, 4096, &report);
        time.* = elapsedMs(start);
        const n: i64 = @intCast(count);
        try std.testing.expectEqual(@divExact(n * (n + 1), 2), run.actual.cells[0].value.integer);
        try std.testing.expectEqual(n, run.actual.cells[1].value.integer);
        try std.testing.expect(run.actual.scheduler.switches >= 4 * count);
        try std.testing.expect(run.actual.reclaims > 0);
        // Every visit's cell was freed: two cells each.
        try std.testing.expect(h.control.reclaimed_cells >= 2 * count);
        cells.* = run.actual.object_cells.len;
    }
    std.debug.print("cells across switches: {d} visits in {d}ms ({d} cells left), {d} visits in {d}ms ({d} cells left)\n", .{ sizes[0], times[0], left[0], sizes[1], times[1], left[1] });
    // What is left does not grow with the visits: a few thousand cells of the 200,000 made.
    for (left) |cells| try std.testing.expect(cells < 4096);
    try budget(times[1] < 7 * times[0] + 500 and times[1] < 120_000);
}

/// `count` functions, each with a local an `Fn` shares and two loops one in the other that
/// assign it: no loop carries it (S2), which the macro pass decides for each loop.
fn sharedLoopsProgram(source: *std.ArrayList(u8), count: usize) !void {
    source.clearRetainingCapacity();
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(S:i64)<transacts>:i64 = Block{{ var C:i64 = S; G := Fn()<transacts>:void{{ Set(C, C + 1) }}; For(A:1..2, For(B:1..2, Block{{ set C = C + A * B; 0 }})); G(); C }}\nV{d}:i64 = F{d}({d})\n", .{ i, i, i, i });
    try source.print(std.testing.allocator, "Last<public>:i64 = V{d}\n", .{count - 1});
}

test "rfc0085 I6: loops over shared locals in two thousand functions compile in time linear in their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const sizes = [_]usize{ 500, 2000 };
    var times: [2]u64 = undefined;
    for (sizes, &times) |count, *time| {
        try sharedLoopsProgram(&source, count);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        const result = try h.run(program, 1 << 26);
        // The loops add 1 + 2 + 2 + 4, the closure 1.
        try std.testing.expectEqual(@as(i64, @intCast(count - 1 + 10)), result.ok.get("Last").?.integer);
    }
    std.debug.print("loops over shared locals: {d} functions in {d}ms, {d} functions in {d}ms\n", .{ sizes[0], times[0], sizes[1], times[1] });
    try budget(times[1] < 7 * times[0] + 300);
}

/// Programs whose tasks build after the scheduler resumed them (RFC-0085, I6-D3): `count` tasks
/// that sleep, build `width` arrays, sleep and build again; `count` `Sync`s of two arms that
/// sleep and build, in a loop; and a fan-out of `count` tasks that each build after one sleep.
/// Each writes its total to `Out`.
fn resumedProgram(buffer: []u8, which: u8, count: usize, width: usize) ![]const u8 {
    return switch (which) {
        0 => std.fmt.bufPrint(buffer,
            \\var Out:i64 = 0
            \\Run(N:i64,K:i64)<transacts><suspends>:i64=Block{{var S:i64=0;var J:i64=0;Loop{{If(J>=N,Break(),false);set J=J+1;Spawn{{Sleep(1.0);Xs:=For(I:1..K,array{{I}});Sleep(1.0);Ys:=For(X:Xs,array{{X.Length,1}});set S=S+Ys.Length;0}};0}};Sleep(4.0);set Out=S;S}}
            \\P:task(i64)=Spawn{{Run({d},{d})}}
        , .{ count, width }),
        1 => std.fmt.bufPrint(buffer,
            \\var Out:i64 = 0
            \\Work(K:i64)<transacts><suspends>:i64=Block{{Sleep(1.0);Xs:=For(I:1..K,array{{I}});Xs.Length}}
            \\Run(N:i64,K:i64)<transacts><suspends>:i64=Block{{var S:i64=0;var J:i64=0;Loop{{If(J>=N,Break(),false);set J=J+1;R:=Sync(Work(K),Work(K));set S=S+R(0)+R(1)}};set Out=S;S}}
            \\P:task(i64)=Spawn{{Run({d},{d})}}
        , .{ count, width }),
        else => std.fmt.bufPrint(buffer,
            \\var Out:i64 = 0
            \\Run(N:i64,K:i64)<transacts><suspends>:i64=Block{{var S:i64=0;var J:i64=0;Loop{{If(J>=N,Break(),false);set J=J+1;Spawn{{Sleep(1.0);Xs:=For(I:1..K,array{{I}});set S=S+Xs.Length;0}};0}};Sleep(3.0);set Out=S;S}}
            \\P:task(i64)=Spawn{{Run({d},{d})}}
        , .{ count, width }),
    };
}

test "rfc0085 I6: tasks that build after they resume are reclaimed at their ends, in bounded pools and linear time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var text: [1024]u8 = undefined;
    var report: [256]u8 = undefined;
    const width = 30;
    const names = [_][]const u8{ "tasks that sleep, build, sleep and build", "Syncs of two arms that build", "a fan-out of tasks that build" };
    // Sizes four times apart; the larger of the first two failed with `aggregate_limit` when a
    // resumed task's end did not reclaim, and took twelve seconds when every one did.
    const sizes = [_][2]usize{ .{ 500, 2000 }, .{ 750, 3000 }, .{ 5000, 20_000 } };
    for (names, sizes, 0..) |name, pair, which| {
        var times: [2]u64 = undefined;
        for (pair, &times) |count, *time| {
            const program = try h.compile(try resumedProgram(&text, @intCast(which), count, width));
            const start = std.Io.Clock.awake.now(std.testing.io);
            const run = try longRun(h, again, name, program, 1 << 38, &report);
            time.* = elapsedMs(start);
            const total: i64 = @intCast(count * width * @as(usize, if (which == 1) 2 else 1));
            try std.testing.expectEqual(total, run.actual.cells[0].value.integer);
            try std.testing.expect(run.actual.reclaims > 0);
            // What is left is at most the floor's room and what the tasks still running hold, not
            // what every task built (a few million members): base56 left 24,000 members of the
            // larger first program, and without the depth-1 rule after a switch it filled the pool.
            try std.testing.expect(run.actual.aggregate_values.len <= types.ControlStorage.default_reclaim_floor + 64 * count);
            // An `off` run reclaims alike in both machines and computes the same.
            h.control.trace = .off;
            h.runtime.machine.control.trace = .off;
            const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 1 << 38);
            const actual = h.runtime.evaluate(program, 1 << 38);
            try std.testing.expect(reference == .ok and actual == .ok);
            try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
            try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
            try std.testing.expectEqual(total, actual.ok.cells[0].value.integer);
        }
        std.debug.print("{s}: {d} in {d}ms, {d} in {d}ms\n", .{ name, pair[0], times[0], pair[1], times[1] });
        // Four times the tasks cost four times as much, sixteen times if reclamation were
        // quadratic; the allowance is for a loaded machine.
        try budget(times[1] < 12 * times[0] + 1000);
    }
}

/// `count` tasks, each spawned in a loop that sleeps, then sleeps once and builds an array whose
/// length `Kc` cycles through 300..1500 (RFC-0085, I6-D3): the tasks resume on their own and
/// build above the marks of their entry frames while the loop that spawned them keeps going.
fn cyclingProgram(buffer: []u8, count: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\var Out:i64=0
        \\Run(N:i64)<transacts><suspends>:i64=Block{{var J:i64=0;var Kc:i64=300;Loop{{If(J>=N,Break(),false);set J=J+1;set Kc=Kc+137;If(Kc>1500,Block{{set Kc=Kc-1200;0}},0);L:=Kc;Spawn{{Sleep(1.0);Ys:=For(I:1..L,array{{I}});set Out=Out+Ys.Length;0}};Sleep(2.0)}};Out}}
        \\P:task(i64)=Spawn{{Run({d})}}
    , .{count});
}

/// An `off` run through both machines, which must compute and reclaim alike.
fn offRun(h: *harness.Harness, program: types.Program, fuel: u64, floor: u32) !evaluator.Execution {
    h.control.trace = .off;
    h.runtime.machine.control.trace = .off;
    h.control.reclaim_floor = floor;
    h.runtime.machine.control.reclaim_floor = floor;
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(program, fuel);
    if (reference == .failed) std.debug.print("off run: {s}\n", .{reference.failed.message()});
    if (actual == .failed) std.debug.print("off run (vm): {s}\n", .{actual.failed.message()});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    try std.testing.expectEqual(reference.ok.object_cells.len, actual.ok.object_cells.len);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
    try std.testing.expectEqual(reference.ok.cells[0].value.integer, actual.ok.cells[0].value.integer);
    return actual.ok;
}

test "rfc0085 I6: a resumed task that reclaims inside its own loop still reclaims at its end" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var text: [1024]u8 = undefined;
    var report: [256]u8 = undefined;
    // Four thousand tasks that each build 300 to 1,500 members after they resume filled the
    // pool (`aggregate_limit`) when the end of a task that had reclaimed in its own loop was
    // held back by the switch that resumed it; base56 ran it. A thousand of them ran, and left
    // millions of members behind (the last tasks' garbage, never reclaimed). A reclamation rule
    // may make a run faster, never make a run fail.
    const begun = std.Io.Clock.awake.now(std.testing.io);
    for ([_]usize{ 1000, 4000 }) |count| {
        var expected: i64 = 0;
        var kc: i64 = 300;
        for (0..count) |_| {
            kc += 137;
            if (kc > 1500) kc -= 1200;
            expected += kc;
        }
        const program = try h.compile(try cyclingProgram(&text, count));
        const floor = types.ControlStorage.default_reclaim_floor;
        if (count == 1000) {
            // Both machines in digest mode, with the replay admitting the report, then `off`.
            const run = try longRun(h, again, "cycling tasks 1000", program, 1 << 40, &report);
            try std.testing.expectEqual(expected, run.actual.cells[0].value.integer);
            try std.testing.expect(run.actual.reclaims > 0);
            // The pool ends within the floor, not millions of members as without the end's reclamation.
            try std.testing.expect(run.actual.aggregate_values.len <= floor);
            const quiet = try offRun(h, program, 1 << 40, floor);
            try std.testing.expectEqual(run.actual.aggregate_values.len, quiet.aggregate_values.len);
        } else {
            // The size that failed: `off` runs through both machines (a digest run of it takes
            // a minute with its replay, and the smaller size covers that).
            const quiet = try offRun(h, program, 1 << 40, floor);
            try std.testing.expectEqual(expected, quiet.cells[0].value.integer);
            try std.testing.expect(quiet.reclaims > 0 and quiet.aggregate_values.len <= floor);
        }
    }
    std.debug.print("cycling tasks: {d}ms\n", .{elapsedMs(begun)});
    try budget(elapsedMs(begun) < 300_000);
}

test "rfc0085 I6: Rush, Branch and When in a loop reclaim to the pool they left before, at every floor" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var report: [4096]u8 = undefined;
    const Case = struct { name: []const u8, source: []const u8, out: i64 };
    const cases = [_]Case{
        .{ .name = "Rush of two arms that build", .out = 1800, .source =
        \\var Out:i64=0
        \\Arm(K:i64,D:float)<transacts><suspends>:i64=Block{Sleep(D);Xs:=For(I:1..K,array{I});Xs.Length}
        \\One()<transacts><suspends>:i64=Rush(Arm(30,1.0),Arm(40,2.0))
        \\Run(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Loop{If(J>=N,Break(),false);set J=J+1;R:=One();set Out=Out+R;Sleep(3.0)};Out}
        \\P:task(i64)=Spawn{Run(60)}
        },
        .{ .name = "Branch that builds", .out = 1800, .source =
        \\var Out:i64=0
        \\One()<transacts><suspends>:void=Block{Branch{Sleep(1.0);Xs:=For(I:1..30,array{I});Set(Out,Out+Xs.Length)};Sleep(2.0)}
        \\Run(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Loop{If(J>=N,Break(),false);set J=J+1;One()};Out}
        \\P:task(i64)=Spawn{Run(60)}
        },
        .{ .name = "When whose body builds", .out = 1220, .source =
        \\var Out:i64=0
        \\var G:i64=0
        \\Run(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Q:task(void)=When(G,Block{Xs:=For(I:1..20,array{I});Set(Out,Out+Xs.Length)});Loop{If(J>=N,Break(),false);set J=J+1;Sleep(1.0);Ys:=For(I:1..15,array{I});set G=G+Ys.Length};Out}
        \\P:task(i64)=Spawn{Run(60)}
        },
    };
    for (cases) |case| {
        const program = try h.compile(case.source);
        for ([_]u32{ 0, 8, 64, 4096, types.ControlStorage.default_reclaim_floor }) |floor| {
            const run = try longRunAt(h, again, case.name, program, 1 << 32, floor, &report);
            try std.testing.expectEqual(case.out, run.actual.cells[0].value.integer);
            const quiet = try offRun(h, program, 1 << 32, floor);
            try std.testing.expectEqual(run.actual.aggregate_values.len, quiet.aggregate_values.len);
            // A run that reclaims at the end of its tasks ends within a floor of what it must keep
            // (the first two programs left eight members on base56 and 551 now).
            try std.testing.expect(run.actual.aggregate_values.len <= @as(usize, floor) + 1024 or floor == types.ControlStorage.default_reclaim_floor);
        }
    }
}

// Live locals (RFC-0085, I14): a chain of 300,000 `var live` locals, each in a frame of its own
// that has returned, following the one before, written at its head; a million writes of a local
// that another follows; and a million visits that each make a live local and drop it, which a
// digest run holds only by reclaiming the cells and their records (nine cells each).
const live_locals = @import("live_local_tests.zig");

test "rfc0085 I14: a chain of 300,000 live locals, a million watched writes and a million dropped live locals" {
    try requireProgram();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    const begun = std.Io.Clock.awake.now(std.testing.io);
    try live_locals.scale(f, 300_000, 1_000_000, 1_000_000);
    try budget(elapsedMs(begun) < 60_000);
}

// pf2 (capacity review, "Defect pass pf2"): a `For` that builds its array in a frame pushed after
// the run's last task switch grows into its room as one at the root does. It copied its
// accumulator at every element once any task had run: 20,000 elements took 5.6 s spawned and
// 71 ms not.
test "pf2: a For in a spawned function and after a sleep is linear in its length" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source: [512]u8 = undefined;
    const forms = [_][]const u8{
        "Build(N:i64)<computes>:[]i64 = For(I:1..N, I)\nT:task([]i64) = Spawn{{ Build({d}) }}\nW()<transacts><suspends>:i64 = Block{{ Xs := T.Await(); Xs.Length }}\nU:task(i64) = Spawn{{ W() }}",
        "Run()<transacts><suspends>:i64 = Block{{ Sleep(0.0); Xs := For(I:1..{d}, I); Xs.Length }}\nT:task(i64) = Spawn{{ Run() }}",
        "Build(N:i64)<computes>:[]i64 = For(I:1..N, I)\nXs:[]i64 = Build({d})\nN:i64 = Xs.Length",
    };
    var times: [forms.len][2]u64 = undefined;
    inline for (forms, &times) |form, *time| {
        for ([_]u64{ 50_000, 100_000 }, time) |length, *ms| {
            const program = try h.compile(try std.fmt.bufPrint(&source, form, .{length}));
            // The faster of two runs: a machine that others share slows a run now and then.
            ms.* = std.math.maxInt(u64);
            for (0..2) |_| {
                const start = std.Io.Clock.awake.now(std.testing.io);
                const x = try h.run(program, 64_000_000);
                ms.* = @min(ms.*, elapsedMs(start));
                try std.testing.expect(x == .ok);
            }
        }
    }
    std.debug.print("pf2 For of 50,000 / 100,000 elements, spawned: {d}/{d}ms, after a sleep: {d}/{d}ms, without a task: {d}/{d}ms\n", .{ times[0][0], times[0][1], times[1][0], times[1][1], times[2][0], times[2][1] });
    for (times) |time| {
        try budget(time[1] < 3 * time[0] + 200);
        try budget(time[1] < 10_000);
    }
}

/// What one run of `program` costs in a mode, in milliseconds: the reference, the VM and, for a
/// stored run, the replay of its report. Both machines must agree on the outcome.
const ScaleTimes = struct { reference: u64, actual: u64, report: u64 };

fn scaleTimes(h: *harness.Harness, program: types.Program, mode: types.TraceMode, fuel: u64) !ScaleTimes {
    h.control.trace = mode;
    h.runtime.machine.control.trace = mode;
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    if (reference == .failed) std.debug.print("{s}\n", .{reference.failed.message()});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    var report_ms: u64 = 0;
    if (mode == .full) {
        start = std.Io.Clock.awake.now(std.testing.io);
        _ = try reporting.validate(actual.ok, false, .{ .work = 1 << 40 });
        report_ms = elapsedMs(start);
    }
    return .{ .reference = reference_ms, .actual = actual_ms, .report = report_ms };
}

// pf2 (capacity review, "Defect pass pf2"): a `For` that builds instances, strings, or a result
// that is large, grows in time in proportion to its length, in both machines and the replay.
test "pf2: a For of instances with fields that change, of strings and of integers is linear in length" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source: [512]u8 = undefined;
    const forms = [_][]const u8{
        "P := class{{ var N:i64 }}\nAll:[]P = For(K:1..{d}, P{{N := K}})\nN:i64 = All.Length",
        "P := class{{ N:i64 }}\nBuild(M:i64)<allocates>:[]P = For(K:1..M, P{{N := K}})\nAll:[]P = Build({d})\nN:i64 = All.Length",
        "Xs:[]string = For(I:1..{d}, \"s{{I}}\")\nN:i64 = Xs.Length",
        "Xs:[]i64 = For(I:1..{d}, I * 2)\nN:i64 = Xs.Length",
    };
    inline for (forms, 0..) |form, which| for ([_]types.TraceMode{ .full, .digest }) |mode| {
        var times: [2]ScaleTimes = undefined;
        for ([_]u64{ 50_000, 100_000 }, &times) |length, *time| {
            const program = try h.compile(try std.fmt.bufPrint(&source, form, .{length}));
            // The faster of two runs: a machine that others share slows a run now and then.
            const first = try scaleTimes(h, program, mode, 40 * length);
            const second = try scaleTimes(h, program, mode, 40 * length);
            time.* = .{ .reference = @min(first.reference, second.reference), .actual = @min(first.actual, second.actual), .report = @min(first.report, second.report) };
        }
        std.debug.print("pf2 form {d} {t}: 50,000 / 100,000 elements: reference {d}/{d}ms, vm {d}/{d}ms, replay {d}/{d}ms\n", .{ which, mode, times[0].reference, times[1].reference, times[0].actual, times[1].actual, times[0].report, times[1].report });
        // Twice the elements, under three times the time (and a little for the clock).
        try budget(times[1].reference < 3 * times[0].reference + 100);
        try budget(times[1].actual < 3 * times[0].actual + 100);
        try budget(times[1].report < 3 * times[0].report + 100);
    };
    h.control.trace = .full;
    h.runtime.machine.control.trace = .full;
}

// w15 (TASK-0109, RFC-0055 "Amendment: w15"): a `For` whose every visit waits has seen a switch
// at every join after its first. It grows into its room while no other task holds suspended
// frames, and, beside another task's loop, when its elements name nothing. Each copied its
// accumulator at every element before: 10,000 / 20,000 visits took 412/1,658 ms alone in the
// reference evaluator (11/19 ms after).
test "w15: a For whose visits sleep is linear in its visits, alone and beside another task's loop of integers" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source: [512]u8 = undefined;
    const forms = [_][]const u8{
        "Run()<transacts><suspends>:i64 = Block{{ Xs := For(I:1..{d}, Block{{ Sleep(0.0); I * 3 }}); Xs.Length }}\nT:task(i64) = Spawn{{ Run() }}",
        "Wait(I:i64)<transacts><suspends>:i64 = Block{{ Sleep(0.0); I }}\nRun()<transacts><suspends>:i64 = Block{{ Ss := For(I:1..{d}, Block{{ J := Wait(I); \"s{{J}}\" }}); Ss.Length }}\nT:task(i64) = Spawn{{ Run() }}",
        "Run(K:i64)<transacts><suspends>:i64 = Block{{ Xs := For(I:1..{d}, Block{{ Sleep(0.0); I * K }}); Xs.Length }}\nT1:task(i64) = Spawn{{ Run(2) }}\nT2:task(i64) = Spawn{{ Run(3) }}",
    };
    inline for (forms, 0..) |form, which| {
        var times: [2]ScaleTimes = undefined;
        for ([_]u64{ 10_000, 20_000 }, &times) |length, *time| {
            const program = try h.compile(try std.fmt.bufPrint(&source, form, .{length}));
            // The faster of two runs: a machine that others share slows a run now and then.
            const first = try scaleTimes(h, program, .digest, 1 << 36);
            const second = try scaleTimes(h, program, .digest, 1 << 36);
            time.* = .{ .reference = @min(first.reference, second.reference), .actual = @min(first.actual, second.actual), .report = 0 };
        }
        std.debug.print("w15 sleeping For form {d}: 10,000 / 20,000 visits: reference {d}/{d}ms, vm {d}/{d}ms\n", .{ which, times[0].reference, times[1].reference, times[0].actual, times[1].actual });
        // Twice the visits, under three times the time (and a little for the clock).
        try budget(times[1].reference < 3 * times[0].reference + 100);
        try budget(times[1].actual < 3 * times[0].actual + 100);
    }
    h.control.trace = .full;
    h.runtime.machine.control.trace = .full;
}

/// What both machines make of `program` with `fuel` in a digest run, and how long each took:
/// the diagnostic they agree on, or none.
const Outcome = struct { code: ?types.Diagnostic.Code, reference: u64, actual: u64, evaluations: u64 };

fn digestOutcome(h: *harness.Harness, program: types.Program, fuel: u64) !Outcome {
    h.control.trace = .digest;
    h.runtime.machine.control.trace = .digest;
    defer {
        h.control.trace = .full;
        h.runtime.machine.control.trace = .full;
    }
    var start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const reference_ms = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    const actual = h.runtime.evaluate(program, fuel);
    const actual_ms = elapsedMs(start);
    try std.testing.expectEqual(std.meta.activeTag(reference), std.meta.activeTag(actual));
    if (reference == .failed) {
        try std.testing.expectEqual(reference.failed.code, actual.failed.code);
        return .{ .code = reference.failed.code, .reference = reference_ms, .actual = actual_ms, .evaluations = 0 };
    }
    try std.testing.expectEqual(reference.ok.aggregate_values.len, actual.ok.aggregate_values.len);
    try std.testing.expectEqual(reference.ok.live.evaluations, actual.ok.live.evaluations);
    return .{ .code = null, .reference = reference_ms, .actual = actual_ms, .evaluations = reference.ok.live.evaluations };
}

// w15 (TASK-0109; RFC-0055 "Amendment: w15", pf2 item 4): accepted costs, each charged as fuel,
// so that a run's time follows its fuel and a budget stops it. A `For` grows into rooms up to
// about a quarter of the pool and copies its array at each element beyond; an array of arrays
// built by a `For` costs `n^2/2` members of fuel.
test "w15: past a quarter of the pool a For copies at each element, and a For of arrays costs n^2/2, in fuel" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source: [256]u8 = undefined;
    const quarter: u64 = types.limits.aggregate_elements / 4;
    // Below the quarter: linear, at most 40 units of fuel an element.
    var below: [2]Outcome = undefined;
    for ([_]u64{ quarter / 2, quarter - quarter / 8 }, &below) |length, *outcome| {
        const program = try h.compile(try std.fmt.bufPrint(&source, "Xs:[]i64 = For(I:1..{d}, I)\nN:i64 = Xs.Length", .{length}));
        outcome.* = try digestOutcome(h, program, 40 * length);
        try std.testing.expectEqual(@as(?types.Diagnostic.Code, null), outcome.code);
    }
    // A sixteenth beyond it: every element past the quarter copies the array, a quarter of the
    // pool, so the same 40 units an element stop it, and the copies it made were charged.
    const beyond = quarter + quarter / 16;
    const past = try digestOutcome(h, try h.compile(try std.fmt.bufPrint(&source, "Xs:[]i64 = For(I:1..{d}, I)\nN:i64 = Xs.Length", .{beyond})), 40 * beyond);
    try std.testing.expectEqual(@as(?types.Diagnostic.Code, .work_limit), past.code);
    std.debug.print("w15 For of {d} / {d} elements: reference {d}/{d}ms, vm {d}/{d}ms; of {d} with the same fuel an element: work_limit after {d}ms / {d}ms\n", .{ quarter / 2, quarter - quarter / 8, below[0].reference, below[1].reference, below[0].actual, below[1].actual, beyond, past.reference, past.actual });
    try budget(below[1].reference < 3 * below[0].reference + 100);
    try budget(past.reference < 4 * below[1].reference + 1000);
    // Arrays of arrays: more than `n^2/2` units of fuel, and at most `n^2/2 + 40n`.
    var squares: [2]Outcome = undefined;
    for ([_]u64{ 1_000, 2_000 }, &squares) |length, *outcome| {
        const program = try h.compile(try std.fmt.bufPrint(&source, "Ys:[][]i64 = For(I:1..{d}, array{{I}})\nN:i64 = Ys.Length", .{length}));
        try std.testing.expectEqual(@as(?types.Diagnostic.Code, .work_limit), (try digestOutcome(h, program, length * length / 2)).code);
        outcome.* = try digestOutcome(h, program, length * length / 2 + 40 * length);
        try std.testing.expectEqual(@as(?types.Diagnostic.Code, null), outcome.code);
    }
    std.debug.print("w15 For of 1,000 / 2,000 arrays: reference {d}/{d}ms, vm {d}/{d}ms\n", .{ squares[0].reference, squares[1].reference, squares[0].actual, squares[1].actual });
    try budget(squares[1].reference < 10_000);
}

// w15 (TASK-0109; RFC-0085 "Amendment: w15", I14-D6, accepted): a `var live` local that reads a
// module `var`, in a function called `n` times, leaves `n` records that every later write of the
// `var` evaluates: `n(n+1)/2` evaluations besides the `n` that establish them, each charged as
// fuel. One write evaluates at most `live_evaluations` guards (`live_propagation_limit`).
test "w15: dead live locals that read a module var cost n(n+1)/2 evaluations, each charged" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source: [256]u8 = undefined;
    var outcomes: [2]Outcome = undefined;
    for ([_]u64{ 500, 1_000 }, &outcomes) |n, *outcome| {
        const program = try h.compile(try std.fmt.bufPrint(&source, "var M:i64 = 0\nVisit(I:i64)<transacts>:i64 = Block{{ var live L:i64 = M + I; set M = M + 1; L }}\nXs:[]i64 = For(I:1..{d}, Visit(I))\nN:i64 = Xs.Length", .{n}));
        outcome.* = try digestOutcome(h, program, 1 << 36);
        try std.testing.expectEqual(@as(?types.Diagnostic.Code, null), outcome.code);
        try std.testing.expectEqual(n + n * (n + 1) / 2, outcome.evaluations);
    }
    std.debug.print("w15 dead live locals, 500 / 1,000 calls: reference {d}/{d}ms, vm {d}/{d}ms\n", .{ outcomes[0].reference, outcomes[1].reference, outcomes[0].actual, outcomes[1].actual });
    // Four times the evaluations: about four times the time, and no more.
    try budget(outcomes[1].reference < 6 * outcomes[0].reference + 200);
    try budget(outcomes[1].actual < 6 * outcomes[0].actual + 200);
}

// RFC-0089 (B1): comments, hexadecimal literals, the f64 suffix and the typed `:=` cost time in
// proportion to the source, at the size of a program-profile source.
test "b1: lexical forms lex in linear time and a source full of nested comments lexes" {
    try requireProgram();
    const lexer = @import("lexer.zig");
    const allocator = std.testing.allocator;
    const tokens = try allocator.alloc(lexer.Token, types.limits.tokens);
    defer allocator.free(tokens);
    var times: [2]u64 = undefined;
    for ([_]usize{ 30_000, 60_000 }, &times) |lines, *ms| {
        var source = build(allocator);
        defer source.deinit(allocator);
        for (0..lines) |i| {
            try source.print(allocator, "A{d}<public>:i64:=0x{x} <# one <# two #> #> + 1.5f64.Floor\n", .{ i, i });
            if (i % 4 == 0) try source.appendSlice(allocator, "<#>\n    note ( [ {\n\n    more\n");
            if (i % 5 == 0) try source.appendSlice(allocator, "<# over\n lines #>\n");
        }
        try std.testing.expect(source.items.len <= types.limits.source_bytes);
        ms.* = std.math.maxInt(u64);
        // The faster of two batches of twenty lexes, so that a few milliseconds are measurable.
        for (0..2) |_| {
            const start = std.Io.Clock.awake.now(std.testing.io);
            for (0..20) |_| {
                const result = lexer.tokenize(source.items, tokens);
                if (result == .failed) std.debug.print("b1 scale: {s} at {d}\n", .{ result.failed.message(), result.failed.span.start });
                try std.testing.expect(result == .ok);
            }
            ms.* = @min(ms.*, elapsedMs(start));
        }
    }
    std.debug.print("b1 lexing 30,000 / 60,000 declarations with comments: {d}/{d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 3 * times[0] + 20);
    try budget(times[1] < 5_000);
    // A source of the largest size made only of nested block comments: every byte is read once.
    const limit = types.limits.source_bytes;
    const nested = try allocator.alloc(u8, limit);
    defer allocator.free(nested);
    @memset(nested, ' ');
    for (0..limit / 4) |i| {
        @memcpy(nested[2 * i ..][0..2], "<#");
        @memcpy(nested[limit - 2 * i - 2 ..][0..2], "#>");
    }
    const start = std.Io.Clock.awake.now(std.testing.io);
    const result = lexer.tokenize(nested, tokens);
    const nested_ms = elapsedMs(start);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(usize, 1), result.ok.len);
    std.debug.print("b1 lexing {d} bytes of nested comments: {d}ms\n", .{ limit, nested_ms });
    try budget(nested_ms < 2_000);
    // And the same forms through the whole compiler and both machines.
    const h = try harness.create();
    defer scratch.release(h);
    var program_source = build(allocator);
    defer program_source.deinit(allocator);
    for (0..1000) |i| try program_source.print(allocator, "B{d}:i64:=0x{x} <# c <# n #> #> + {d}\n<#>\n    hidden\n", .{ i, i, i % 7 });
    try program_source.appendSlice(allocator, "Total<public>:i64=B999+B0\n");
    const x = try h.execute(program_source.items);
    try std.testing.expectEqual(@as(i64, 0x3e7 + 5 + 0), x.get("Total").?.integer);
}

// RFC-0085, I13 (Q1): a local that closures only name is shared, so a program of thousands of
// them pays for a cell each and one compile more, in time linear in their number.

/// `Run` with `count` blocks, each a local `var` an `Fn` only names, which the block writes
/// after the `Fn` is built: the `Fn` reads the variable (the snapshot of RFC-0054 gave the
/// local's first value).
fn namedLocalsProgram(source: *std.ArrayList(u8), count: usize) !void {
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "Run(S:i64)<transacts>:i64 = Block{\n    var Total:i64 = 0\n");
    for (0..count) |i| try source.print(std.testing.allocator, "    Block{{ var X{d}:i64 = S + {d}; R{d} := Fn()<reads>:i64{{ X{d} }}; set X{d} = X{d} + 1; set Total = Total + R{d}() + X{d}; 0 }}\n", .{ i, i, i, i, i, i, i, i });
    try source.appendSlice(std.testing.allocator, "    Total\n}\nValue<public>:i64 = Run(1)\n");
}

test "rfc0085 I13: eight thousand locals that closures only name are cells, compiled in time linear in their number" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const sizes = [_]usize{ 2000, 8000 };
    var times: [2]u64 = undefined;
    for (sizes, &times) |count, *time| {
        try namedLocalsProgram(&source, count);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        // Every note is taken in the first compile: one compile more, however many locals.
        try std.testing.expectEqual(@as(u32, 2), h.front.passes);
        try std.testing.expectEqual(count, h.front.share_key_count);
        var cells: usize = 0;
        for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .ref_new) {
            cells += 1;
        };
        for (program.nodes) |node| if (node.kind == .ref_new) {
            cells += 1;
        };
        try std.testing.expectEqual(count, cells);
        const result = try h.run(program, 1 << 26);
        // Each block adds the local twice, at its value after the write: 2 * (2 + i).
        const n: i64 = @intCast(count);
        try std.testing.expectEqual(n * (n + 3), result.ok.get("Value").?.integer);
    }
    std.debug.print("named locals: {d} in {d}ms, {d} in {d}ms\n", .{ sizes[0], times[0], sizes[1], times[1] });
    // Four times the locals: linear is four times the time, quadratic sixteen.
    try budget(times[1] < 7 * times[0] + 300);
}

test "a program's own ToString builds the text of tens of thousands of values in time proportional to them" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for (&times, [_]u64{ 5_000, 20_000 }) |*time, count| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.print(std.testing.allocator, "point:=struct{{X:i64,Y:i64}}\nToString(P:point)<computes>:string=\"({{P.X}},{{P.Y}})\"\nvar Total:i64=0\nvar N:i64=0\nRun()<transacts>:i64=Block{{While(N<{d},Block{{S:=\"{{point{{X:=N,Y:=N*2}}}}\";set Total=Total+S.Length;set N=N+1}});Total}}\nSize<public>:i64=Run()\n", .{count});
        var expected: i64 = 0;
        for (0..count) |i| {
            var buffer: [48]u8 = undefined;
            expected += @intCast((try std.fmt.bufPrint(&buffer, "({d},{d})", .{ i, 2 * i })).len);
        }
        const program = try h.compile(source.items);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.run(program, 400_000_000);
        time.* = elapsedMs(start);
        if (x == .failed) std.debug.print("ToString scale test failed: {s}\n", .{x.failed.message()});
        try std.testing.expectEqual(expected, x.ok.get("Size").?.integer);
    }
    std.debug.print("ToString interpolation: 5,000 / 20,000 values: {d}/{d}ms\n", .{ times[0], times[1] });
    // Four times the values, under five times the time (and a little for the clock).
    try budget(times[1] < 5 * times[0] + 100);
}

/// RFC-0090, B2: `count` functions that each run an `If` without an else, `count` bindings that
/// are each a `For` without a generator or with a binding before its range, and one `Case(...)`
/// of `arms` constant arms, whose unreachable-arm check compares each arm with those before it.
fn controlFlowProgram(source: *std.ArrayList(u8), count: usize, arms: usize) !void {
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "var C:i64=0\nXs:[]i64=array{1,2,3}\n");
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<transacts>:void=If(N>{d},Set(C,C+1))\n", .{ i, i % 7 });
    for (0..count) |i| {
        if (i % 2 == 0) {
            try source.print(std.testing.allocator, "V{d}:[]i64=For(X:=Xs[{d}],X+{d})\n", .{ i, i % 4, i });
        } else try source.print(std.testing.allocator, "V{d}:[]i64=For(Y:=Xs[{d}],N:Y..3,N)\n", .{ i, i % 4 });
    }
    try source.appendSlice(std.testing.allocator, "Pick(N:i64)<computes>:i64=Case(N");
    for (0..arms) |i| try source.print(std.testing.allocator, ",{d}=>{d}", .{ i, i * 2 });
    try source.appendSlice(std.testing.allocator, ",_=>-1)\nRun()<transacts>:i64=Block{");
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(5);", .{i});
    try source.appendSlice(std.testing.allocator, "C}\nRan<public>:i64=Run()\n");
    try source.print(std.testing.allocator, "Picked<public>:i64=Pick({d})+Pick({d})\n", .{ arms - 1, arms });
    try source.print(std.testing.allocator, "Lengths<public>:i64=V0.Length+V1.Length+V{d}.Length+V{d}.Length\n", .{ count - 2, count - 1 });
}

test "rfc0090 B2: Ifs without an else, Fors without a generator and a long Case are compiled and run in time proportional to them" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const sizes = [_]usize{ 500, 2000 };
    var times: [2]u64 = undefined;
    var case_ms: u64 = 0;
    for (sizes, &times) |count, *time| {
        // The arms nest one conditional each, up to the program profile's control depth.
        const arms = 1000;
        try controlFlowProgram(&source, count, arms);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        const compiled = elapsedMs(start);
        const x = try h.run(program, 1 << 26);
        time.* = elapsedMs(start);
        if (x == .failed) std.debug.print("control-flow scale test failed: {s}\n", .{x.failed.message()});
        // `F{i}(5)` adds one where 5 > i % 7: five of every seven.
        var ran: i64 = 0;
        for (0..count) |i| ran += @intFromBool(5 > i % 7);
        try std.testing.expectEqual(ran, x.ok.get("Ran").?.integer);
        try std.testing.expectEqual(@as(i64, (arms - 1) * 2 - 1), x.ok.get("Picked").?.integer);
        // V0 = For(X:=Xs[0],...): one element; V1 = For(Y:=Xs[1],N:2..3,N): two; the last two
        // read Xs[(count-2)%4] and Xs[(count-1)%4], which is past the end for an odd one.
        var lengths: i64 = 1 + 2;
        lengths += if ((count - 2) % 4 < 3) 1 else 0;
        const last = (count - 1) % 4;
        lengths += if (last < 3) @as(i64, @intCast(3 - last)) else 0;
        try std.testing.expectEqual(lengths, x.ok.get("Lengths").?.integer);
        if (count == sizes[1]) case_ms = compiled;
        std.debug.print("control flow: {d} Ifs and Fors, a Case of {d} arms: compile={d}ms total={d}ms\n", .{ count, arms, compiled, time.* });
    }
    // Four times the forms: linear is four times the time, quadratic sixteen.
    try budget(times[1] < 6 * times[0] + 300);
    try budget(case_ms < 10_000);
}

test "rfc0091 B3: mutual recursion ten thousand frames deep, in time linear in its depth" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for (&times, [_]i64{ 2_500, 10_000 }) |*time, depth| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.print(std.testing.allocator, "var Log:i64=0\nDown(N:i64)<transacts>:i64=If(N<=0,Log,Block{{set Log=Log+1;Up(N-1)+1}})\nUp(N:i64)<transacts>:i64=If(N<=0,Log,Block{{set Log=Log+2;Down(N-1)+1}})\nValue<public>:i64=Down({d})\nWritten<public>:i64=Log\n", .{depth});
        const program = try h.compile(source.items);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const x = try h.run(program, 1 << 26);
        time.* = elapsedMs(start);
        if (x == .failed) std.debug.print("deep mutual recursion failed: {s}\n", .{x.failed.message()});
        // Down writes 1 and Up 2, a half each; the base reads what they wrote.
        const written = @divTrunc(depth, 2) * 3;
        try std.testing.expectEqual(depth + written, x.ok.get("Value").?.integer);
        try std.testing.expectEqual(written, x.ok.get("Written").?.integer);
    }
    std.debug.print("mutual recursion 2,500 / 10,000 deep: {d}/{d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 6 * times[0] + 200);
    // Past the frames of the profile, both machines stop with the same diagnostic.
    const r = try h.run(try h.compile("Down(N:i64)<computes>:i64=If(N<=0,0,Up(N-1)+1)\nUp(N:i64)<computes>:i64=If(N<=0,0,Down(N-1)+1)\nValue<public>:i64=Down(100000)"), 1 << 26);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
}

/// A ring of `count` functions, each calling the next one declared after it and the last the
/// first, and a hub that calls every one of them before its declaration.
fn ringProgram(source: *std.ArrayList(u8), count: usize) !void {
    source.clearRetainingCapacity();
    try source.print(std.testing.allocator, "Hub(N:i64)<computes>:i64=0", .{});
    for (0..count) |i| try source.print(std.testing.allocator, "+F{d}(N)", .{i});
    try source.appendSlice(std.testing.allocator, "\n");
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=If(N<=0,{d},F{d}(N-1)+1)\n", .{ i, i, (i + 1) % count });
    try source.print(std.testing.allocator, "Value<public>:i64=F0({d})\nAll<public>:i64=Hub(0)\n", .{count});
}

test "rfc0091 B3: a ring of eight thousand functions that call the next one before its declaration compiles in linear time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const sizes = [_]usize{ 2_000, 8_000 };
    var times: [2]u64 = undefined;
    for (sizes, &times) |count, *time| {
        try ringProgram(&source, count);
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        // Every call but the last one's names a later function.
        var forward: usize = 0;
        for (program.functions, 0..) |f, id| for (program.function_nodes[f.body.start..f.body.end]) |entry| {
            if (entry.input == .operation and entry.node.kind == .call and entry.node.kind.call.function > id) forward += 1;
        };
        try std.testing.expectEqual(2 * count - 1, forward);
        const x = try h.run(program, 1 << 26);
        if (x == .failed) std.debug.print("ring failed: {s}\n", .{x.failed.message()});
        // Around the ring once: count steps back to F0, whose base is 0.
        try std.testing.expectEqual(@as(i64, @intCast(count)), x.ok.get("Value").?.integer);
        const n: i64 = @intCast(count);
        try std.testing.expectEqual(@divTrunc(n * (n - 1), 2), x.ok.get("All").?.integer);
    }
    std.debug.print("ring of 2,000 / 8,000 functions compiled in {d}/{d}ms\n", .{ times[0], times[1] });
    // Four times the functions: linear is four times the time, quadratic sixteen.
    try budget(times[1] < 7 * times[0] + 300);
}

test "rfc0091 B3: eight thousand inferred generic calls and destructured parameters compile in linear time" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var times: [2]u64 = undefined;
    for (&times, [_]usize{ 2_000, 8_000 }) |*time, count| {
        var source = build(std.testing.allocator);
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "Pick[A:type,B:type](P:tuple(A,B),D:B)<computes>:B{P(1)}\nSum((X:i64,(Y:i64,Z:i64)))<computes>:i64=X+Y+Z\nRun()<computes>:i64=0");
        for (0..count) |i| try source.print(std.testing.allocator, "+Pick(tuple{{\"k\",Sum(tuple{{{d},tuple{{1,2}}}})}},0)", .{i});
        try source.appendSlice(std.testing.allocator, "\nValue<public>:i64=Run()\n");
        const start = std.Io.Clock.awake.now(std.testing.io);
        const program = try h.compile(source.items);
        time.* = elapsedMs(start);
        const x = try h.run(program, 1 << 26);
        const n: i64 = @intCast(count);
        try std.testing.expectEqual(@divTrunc(n * (n - 1), 2) + 3 * n, x.ok.get("Value").?.integer);
    }
    std.debug.print("inferred calls 2,000 / 8,000 compiled in {d}/{d}ms\n", .{ times[0], times[1] });
    try budget(times[1] < 7 * times[0] + 300);
}

// RFC-0092, B4: a chain of `depth` producers whose overrides each narrow the result one class
// further; `siblings` more producers below the first that narrow it once each. Compile and run
// time, through the base (which forwards through every level) and through each class.
fn narrowingChain(h: *harness.Harness, depth: usize, siblings: usize) !u64 {
    const a = std.testing.allocator;
    var source = build(a);
    defer source.deinit(a);
    try source.appendSlice(a, "T0:=class{Tag:i64=0}\n");
    for (1..depth) |k| try source.print(a, "T{d}:=class(T{d}){{}}\n", .{ k, k - 1 });
    try source.appendSlice(a, "P0:=class{Make()<allocates>:T0=T0{}}\n");
    for (1..depth) |k| try source.print(a, "P{d}:=class(P{d}){{Make<override>()<allocates>:T{d}=T{d}{{Tag:={d}}}}}\n", .{ k, k - 1, k, k, k });
    for (0..siblings) |k| try source.print(a, "Q{d}:=class(P0){{Make<override>()<allocates>:T1=T1{{Tag:={d}}}}}\n", .{ k, 100_000 + k });
    try source.print(a, "Deep:P0=P{d}{{}}\nThrough<public>:i64=Block{{V:=Deep.Make();1}}\n", .{depth - 1});
    try source.print(a, "Own<public>:i64=P{d}{{}}.Make().Tag\n", .{depth - 1});
    if (siblings != 0) try source.print(a, "Side:P0=Q{d}{{}}\nWide<public>:i64=Block{{V:=Side.Make();1}}\n", .{siblings - 1});
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    try std.testing.expectEqual(depth + siblings, program.slots.len);
    const x = try h.run(program, 4_000_000);
    const total = elapsedMs(start);
    if (x == .failed) std.debug.print("narrowing chain failed: {s}\n", .{x.failed.message()});
    try std.testing.expectEqual(@as(i64, @intCast(depth - 1)), x.ok.get("Own").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.ok.get("Through").?.integer);
    return total;
}

test "deep chains of narrowing overrides and many narrowing siblings compile and dispatch in proportion to them" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const small = try narrowingChain(h, 50, 500);
    const large = try narrowingChain(h, 100, 2000);
    std.debug.print("narrowing overrides: 50+500 {d}ms, 100+2000 {d}ms\n", .{ small, large });
    // Four times the siblings and twice the depth: a chain of n narrowing levels has n(n+1)/2
    // dispatch rows, as a chain of n classes that each add a method has, so both grow about
    // four times; a cost quadratic in the siblings would grow sixteen times.
    try budget(large < 7 * small + 300 and large < scale_bound_ms);
}

// RFC-0092, B4: a family of `members` `<final_super>` classes below one castable base, and
// `queries` queries of it: the family function is made once, so each query costs a call.
fn finalSuperFamily(h: *harness.Harness, members: usize, queries: usize) !u64 {
    const a = std.testing.allocator;
    var source = build(a);
    defer source.deinit(a);
    try source.appendSlice(a, "Root:=class<castable>{}\n");
    for (0..members) |k| try source.print(a, "F{d}:=class<final_super>(Root){{}}\nD{d}:=class(F{d}){{}}\n", .{ k, k, k });
    try source.appendSlice(a, "var Found:i64=0\n");
    for (0..queries) |q| try source.print(a, "set Found=Found+Attempt(Block{{K:=GetCastableFinalSuperClass[Root,D{d}{{}}];K[F{d}{{}}];1}},0)\n", .{ (q * 7) % members, (q * 7) % members });
    try source.appendSlice(a, "Total<public>:i64=Found\n");
    const start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    const x = try h.run(program, 40_000_000);
    const total = elapsedMs(start);
    if (x == .failed) std.debug.print("final_super family failed: {s}\n", .{x.failed.message()});
    try std.testing.expectEqual(@as(i64, @intCast(queries)), x.ok.get("Total").?.integer);
    std.debug.print("final_super family: {d} members, {d} queries, compile {d}ms, total {d}ms\n", .{ members, queries, compiled, total });
    return compiled;
}

test "a family of thousands of final_super classes is compiled once for every query of it" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    const few = try finalSuperFamily(h, 500, 100);
    const many = try finalSuperFamily(h, 2000, 400);
    try budget(many < 7 * few + 300 and many < scale_bound_ms);
}

test "a thousand folders of four files and a thousand modules in them compile and run in time proportional to their number" {
    // RFC-0093, B7: a chain of folder modules, each made of four files and declaring a module,
    // each importing the one before it by path and `using` that one's module by a longer path.
    try requireProgram();
    const modules = @import("modules.zig");
    const h = try harness.create();
    defer scratch.release(h);
    var totals: [2]u64 = undefined;
    for ([_]usize{ 500, 1000 }, &totals) |folders, *total| {
        var texts: std.ArrayList(u8) = .empty;
        defer texts.deinit(std.testing.allocator);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(std.testing.allocator);
        // Offsets into `texts` and `names`, as the lists move while they grow.
        const Entry = struct { path: [2]usize, source: [2]usize };
        const entries = try std.testing.allocator.alloc(Entry, folders * 4);
        defer std.testing.allocator.free(entries);
        var expected: i64 = 0;
        for (0..folders) |i| {
            var folder_buffer: [64]u8 = undefined;
            const folder = try std.fmt.bufPrint(&folder_buffer, "/d.org/G{d}/M{d}", .{ i / 32, i });
            var previous_buffer: [64]u8 = undefined;
            const previous = if (i == 0) "" else try std.fmt.bufPrint(&previous_buffer, "/d.org/G{d}/M{d}", .{ (i - 1) / 32, i - 1 });
            for (0..4) |file| {
                const path_start = names.items.len;
                try names.print(std.testing.allocator, "{s}/f{d}.forb", .{ folder[1..], file });
                const source_start = texts.items.len;
                switch (file) {
                    0 => {
                        if (i != 0) try texts.print(std.testing.allocator, "P := import{{{s}}}\n", .{previous});
                        try texts.print(std.testing.allocator, "N<public> := module{{ X<public>:i64 = {d} }}\nV0:i64 = {d}\n", .{ i, i });
                    },
                    1 => try texts.appendSlice(std.testing.allocator, "V1:i64 = V0 + 1\n"),
                    2 => if (i != 0) try texts.print(std.testing.allocator, "using{{{s}/N}}\nV2:i64 = V1 + X\n", .{previous}) else try texts.appendSlice(std.testing.allocator, "V2:i64 = V1\n"),
                    else => try texts.appendSlice(std.testing.allocator, if (i != 0) "S<public>:i64 = P.S + V2 + N.X\n" else "S<public>:i64 = V2 + N.X\n"),
                }
                entries[i * 4 + file] = .{ .path = .{ path_start, names.items.len }, .source = .{ source_start, texts.items.len } };
            }
            expected = if (i == 0) 1 else expected + 3 * @as(i64, @intCast(i));
        }
        const inputs = try std.testing.allocator.alloc(modules.Input, entries.len);
        defer std.testing.allocator.free(inputs);
        // The inventory lists the files last folder first, and each folder's files backwards.
        for (entries, 0..) |entry, index| inputs[entries.len - 1 - index] = .{ .path = names.items[entry.path[0]..entry.path[1]], .source = texts.items[entry.source[0]..entry.source[1]] };
        var root_buffer: [64]u8 = undefined;
        const root = try std.fmt.bufPrint(&root_buffer, "/d.org/G{d}/M{d}", .{ (folders - 1) / 32, folders - 1 });
        const start = std.Io.Clock.awake.now(std.testing.io);
        const bundled = h.front.compileBundle(.{ .root = root, .modules = inputs });
        if (bundled == .failed) std.debug.print("folder scale: {s}: {s} at {d}\n", .{ bundled.failed.path, bundled.failed.diagnostic.message(), bundled.failed.diagnostic.span.start });
        const program = bundled.ok;
        const compiled = elapsedMs(start);
        try std.testing.expectEqual(folders, program.modules.len);
        try std.testing.expectEqual(folders, program.nested.len);
        try std.testing.expectEqual(folders * 4, program.parts.len);
        try std.testing.expectEqual(2 * (folders - 1), program.imports.len);
        // Each machine admits the whole program before it runs it, so each time includes one admission.
        const reference = evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, 4_000_000);
        const referenced = elapsedMs(start);
        const actual = h.runtime.evaluate(program, 4_000_000);
        total.* = elapsedMs(start);
        std.debug.print("folders={d} files={d} nested modules={d} source={d}B compile={d}ms reference={d}ms vm={d}ms total={d}ms\n", .{ folders, program.parts.len, program.nested.len, program.source.len, compiled, referenced - compiled, total.* - referenced, total.* });
        try std.testing.expectEqual(expected, reference.ok.get("S").?.integer);
        try std.testing.expectEqual(expected, actual.ok.get("S").?.integer);
    }
    // Twice the folders: a cost in their square would be four times.
    try budget(totals[1] < 5000);
    try budget(totals[1] < 3 * totals[0] + 250);
}

test "a large program prepared once runs a thousand times on each machine without being admitted again" {
    try requireProgram();
    const h = try harness.create();
    defer scratch.release(h);
    var source = build(std.testing.allocator);
    defer source.deinit(std.testing.allocator);
    const count = 5_000;
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=N+{d}\n", .{ i, i });
    // Iterate keeps every function a published runtime function instead of an inlined template.
    for (0..count) |i| try source.print(std.testing.allocator, "B{d}:i64=Iterate(F{d},1,{d})\n", .{ i, i, i });
    try source.print(std.testing.allocator, "Total<public>:i64=B{d}\n", .{count - 1});
    const fuel: u64 = 4_000_000;
    const runs = 1_000;
    const baseline_runs = 20;
    // Compile and run, as the CLI does: each run compiles and each machine admits on its own.
    var start = std.Io.Clock.awake.now(std.testing.io);
    for (0..baseline_runs) |_| {
        const program = try h.compile(source.items);
        try std.testing.expectEqual(@as(i64, 2 * (count - 1)), h.runtime.evaluate(program, fuel).ok.get("Total").?.integer);
    }
    const vm_per_compile = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    for (0..baseline_runs) |_| {
        const program = try h.compile(source.items);
        try std.testing.expectEqual(@as(i64, 2 * (count - 1)), evaluator.evaluateWithRuntimeStorage(program, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).ok.get("Total").?.integer);
    }
    const reference_per_compile = elapsedMs(start);
    // Prepared once, then run many times on storage of each machine's own.
    start = std.Io.Clock.awake.now(std.testing.io);
    const program = try h.compile(source.items);
    const compiled = elapsedMs(start);
    const admitted = .{ vm_machine.verifications, evaluator.validations };
    const handle = (try prepared.prepare(std.testing.allocator, program)).ok;
    defer handle.destroy();
    const preparing = elapsedMs(start) - compiled;
    try std.testing.expectEqual(admitted[0] + 1, vm_machine.verifications);
    try std.testing.expectEqual(admitted[1] + 1, evaluator.validations);
    const machine = try scratch.storage(prepared.VmRun);
    defer scratch.release(machine);
    scratch.initialise(machine);
    const reference = try scratch.storage(prepared.ReferenceRun);
    defer scratch.release(reference);
    scratch.initialise(reference);
    start = std.Io.Clock.awake.now(std.testing.io);
    for (0..runs) |_| try std.testing.expectEqual(@as(i64, 2 * (count - 1)), (try handle.runVm(machine, .{ .work_budget = fuel })).ok.get("Total").?.integer);
    const vm_prepared = elapsedMs(start);
    start = std.Io.Clock.awake.now(std.testing.io);
    for (0..runs) |_| try std.testing.expectEqual(@as(i64, 2 * (count - 1)), (try handle.runReference(reference, .{ .work_budget = fuel })).ok.get("Total").?.integer);
    const reference_prepared = elapsedMs(start);
    // Two thousand runs, and still the one admission of each kind made by `prepare`.
    try std.testing.expectEqual(admitted[0] + 1, vm_machine.verifications);
    try std.testing.expectEqual(admitted[1] + 1, evaluator.validations);
    // In microseconds per run: compile and run against a prepared run, and what a thousand saved.
    const vm_each = vm_per_compile * 1000 / baseline_runs;
    const reference_each = reference_per_compile * 1000 / baseline_runs;
    const vm_run = vm_prepared * 1000 / runs;
    const reference_run = reference_prepared * 1000 / runs;
    std.debug.print("prepared: functions={d} nodes={d} source={d}B handle={d}B compile={d}ms prepare={d}ms; per run (us) vm {d} compiled vs {d} prepared, reference {d} vs {d}; {d} runs each saved vm={d}ms reference={d}ms\n", .{ program.functions.len, program.nodes.len, source.items.len, handle.bytes(), compiled, preparing, vm_each, vm_run, reference_each, reference_run, runs, (vm_each * runs) / 1000 - (vm_prepared + preparing), (reference_each * runs) / 1000 - reference_prepared });
    // What the handle holds is the program's own size: about its source, nodes, tables and
    // bytecode, nothing sized by a capacity.
    try std.testing.expect(handle.bytes() < 64 * source.items.len);
    try budget(vm_run < vm_each and reference_run < reference_each);
    try budget(vm_prepared + reference_prepared < 30_000);
}
