//! Variable cells, RFC-0085 I1: `ref(T)` and `ref_new`, `ref_get`, `ref_set` on hand-built IR.
//! No compiled program reaches a cell before I2, so each program here is written with a class
//! of one field, `Cell`, and made into one that uses cells (`ref_cells.fromClass`). The class
//! and the cell have the same cells and the same costs, so the program made must compute, in
//! both machines and in every trace mode, exactly what the program it was made from computes:
//! the same values, the same instance cells, the same fuel, the same steps. The report is the
//! one place they differ, and it is checked byte for byte.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const inspection = @import("inspection.zig");
const catalogue = @import("aggregate_types.zig");
const ref_cells = @import("ref_cells.zig");
const replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// The program made from `p` by turning its class `Cell` into `ref(T)`.
pub fn cells(p: types.Program) !ref_cells.Converted {
    const class = ref_cells.classNamed(p, "Cell") orelse return error.NoCellClass;
    return ref_cells.fromClass(allocator, p, class, .{});
}

/// What a run leaves that a program made from it must leave too.
const Kept = struct {
    values: []types.Value,
    active: []bool,
    members: []types.Value,
    object_cells: []types.Value,
    steps: []types.CallStep,
    failures: u32,

    fn of(x: evaluator.Execution) !Kept {
        const values = try allocator.dupe(types.Value, x.values);
        errdefer allocator.free(values);
        const active = try allocator.alloc(bool, x.values.len);
        errdefer allocator.free(active);
        for (active, 0..) |*flag, index| flag.* = x.active(index);
        const members = try allocator.dupe(types.Value, x.aggregate_values);
        errdefer allocator.free(members);
        const object_cells = try allocator.alloc(types.Value, x.object_cells.len);
        errdefer allocator.free(object_cells);
        for (object_cells, x.object_cells) |*out, cell| {
            try std.testing.expect(cell.initialized);
            out.* = cell.value;
        }
        return .{ .values = values, .active = active, .members = members, .object_cells = object_cells, .steps = try allocator.dupe(types.CallStep, x.call_steps), .failures = x.failure_count };
    }
    fn free(self: Kept) void {
        allocator.free(self.steps);
        allocator.free(self.object_cells);
        allocator.free(self.members);
        allocator.free(self.active);
        allocator.free(self.values);
    }
    fn expect(self: Kept, x: evaluator.Execution) !void {
        try std.testing.expectEqual(self.values.len, x.values.len);
        for (self.values, self.active, 0..) |value, active, index| {
            try std.testing.expectEqual(active, x.active(index));
            if (active) try replay.same(value, x.values[index]);
        }
        try std.testing.expectEqual(self.members.len, x.aggregate_values.len);
        for (self.members, x.aggregate_values) |a, b| try replay.same(a, b);
        try std.testing.expectEqual(self.object_cells.len, x.object_cells.len);
        for (self.object_cells, x.object_cells) |a, b| try replay.same(a, b.value);
        try std.testing.expectEqual(self.steps.len, x.call_steps.len);
        for (self.steps, x.call_steps) |a, b| {
            try std.testing.expectEqual(a.kind, b.kind);
            try std.testing.expectEqual(a.function, b.function);
            try std.testing.expectEqual(a.pc, b.pc);
            try replay.same(a.value, b.value);
        }
        try std.testing.expectEqual(self.failures, x.failure_count);
    }
};

fn binding(x: evaluator.Execution, name: []const u8) !types.Value {
    for (x.program.bindings) |b| if (std.mem.eql(u8, b.name.text(x.program.source), name)) return x.values[b.node];
    return error.NoBinding;
}

/// The value the cell or instance `value` holds.
fn held(x: evaluator.Execution, value: types.Value) !types.Value {
    const all = x.objectCells(value) orelse return error.NoInstance;
    try std.testing.expectEqual(@as(usize, catalogue.ref_cells), all.len);
    return all[catalogue.ref_value].value;
}

/// Programs over a `Cell`, with what their bindings hold, worked out by hand.
const Case = struct { source: []const u8, expected: []const struct { []const u8, i64 } };
const cases = [_]Case{
    // Built, read and written at the root and in functions; a cell handed on and written by
    // the callee, whose writes the caller sees.
    .{ .source =
    \\Cell:=class{var V:i64}
    \\Bump(C:Cell,D:i64)<transacts>:i64=Block{set C.V=C.V+D;C.V}
    \\Make(N:i64)<transacts>:Cell=Cell{V:=N}
    \\A:Cell=Make(4)
    \\B:i64=Bump(A,3)
    \\C:i64=Bump(A,10)
    \\R:i64=A.V
    \\Root:Cell=Cell{V:=1}
    \\set Root.V=Root.V+41
    \\RV:i64=Root.V
    , .expected = &.{ .{ "B", 7 }, .{ "C", 17 }, .{ "R", 17 }, .{ "RV", 42 } } },
    // R1: a write in a region that fails is undone, one in a region that commits is kept, and
    // an inner region that fails inside an outer one that commits restores the outer's write.
    .{ .source =
    \\Cell:=class{var V:i64}
    \\C:Cell=Cell{V:=1}
    \\Try(D:i64)<transacts><decides>:i64=Block{set C.V=C.V+D;Require[D<5];C.V}
    \\A:i64=Attempt(Try[2],-1)
    \\B:i64=Attempt(Try[9],-1)
    \\K:i64=C.V
    \\Nest()<transacts>:i64=Attempt(Block{set C.V=10;Attempt(Block{set C.V=20;Fail["x"];0},0);Require[C.V==10];C.V},-2)
    \\N:i64=Nest()
    \\After:i64=C.V
    , .expected = &.{ .{ "A", 3 }, .{ "B", -1 }, .{ "K", 3 }, .{ "N", 10 }, .{ "After", 10 } } },
    // R2: a cell made in a region that fails is forgotten with it, and so is what holds it; one
    // made before the region keeps existing with its value restored.
    .{ .source =
    \\Cell:=class{var V:i64}
    \\var Hold:option(Cell)=option{}
    \\Made(N:i64)<transacts><decides>:i64=Block{X:=Cell{V:=N};set X.V=X.V*2;set Hold=option{X};Require[N<3];X.V}
    \\M:i64=Attempt(Made[1],-1)
    \\First:i64=Attempt(Block{X:=Hold?;X.V},-1)
    \\N:i64=Attempt(Made[7],-1)
    \\Second:i64=Attempt(Block{X:=Hold?;X.V},-1)
    , .expected = &.{ .{ "M", 2 }, .{ "First", 2 }, .{ "N", -1 }, .{ "Second", 2 } } },
    // R3 (pure-core "Mutable lexical locals", with the local in a cell): 13.
    .{ .source =
    \\Cell:=class{var V:i64}
    \\F(N:i64)<transacts>:i64=Block{X:=Cell{V:=N};Held:=X.V;Attempt(Block{set X.V=X.V+1;Fail["undo"];X.V},Block{set X.V=X.V+7;X.V});Held+X.V}
    \\R:i64=F(3)
    , .expected = &.{.{ "R", 13 }} },
    // A cell captured by a bound function, read and written through it, and one cell per visit
    // of a loop.
    .{ .source =
    \\Cell:=class{var V:i64}
    \\Add(C:Cell,D:i64)<transacts>:i64=Block{set C.V=C.V+D;C.V}
    \\Run(N:i64)<transacts>:i64=Block{C:=Cell{V:=0};F:=Bind(Add,C);Iterate(Fn(S:i64){Block{F(S);S+1}},N,0);C.V}
    \\Sum:i64=Run(10)
    \\Each(N:i64)<transacts>:i64=Iterate(Fn(S:i64){Block{X:=Cell{V:=S};set X.V=X.V+1;X.V}},N,0)
    \\Count:i64=Each(25)
    , .expected = &.{ .{ "Sum", 45 }, .{ "Count", 25 } } },
};

test "a program with variable cells computes what the program it was made from computes, in both machines" {
    const plain = try harness.create();
    defer scratch.release(plain);
    const made = try harness.create();
    defer scratch.release(made);
    for (cases) |case| {
        const p = try plain.compile(case.source);
        const x = (try plain.run(p, fuel)).ok;
        const kept = try Kept.of(x);
        defer kept.free();
        const converted = try cells(p);
        defer converted.deinit(allocator);
        // The class's operations are cell operations now: admission refuses any class
        // operation left on a cell (F10, F11), so the run below shows none is.
        var operations: usize = 0;
        for (converted.program.nodes) |node| operations += @intFromBool(node.kind == .ref_new or node.kind == .ref_get or node.kind == .ref_set);
        for (converted.program.function_nodes) |entry| operations += @intFromBool(entry.input == .operation and (entry.node.kind == .ref_new or entry.node.kind == .ref_get or entry.node.kind == .ref_set));
        try std.testing.expect(operations >= 3);
        // `run` requires the two machines to agree on everything and the replay to admit both.
        const y = (try made.run(converted.program, fuel)).ok;
        kept.expect(y) catch |problem| {
            std.debug.print("{s}\n", .{case.source});
            return problem;
        };
        for (case.expected) |entry| try std.testing.expectEqual(entry[1], (try binding(y, entry[0])).integer);
    }
}

test "a variable cell costs what an instance of a class with one field costs, to the unit" {
    const plain = try harness.create();
    defer scratch.release(plain);
    const made = try harness.create();
    defer scratch.release(made);
    for (cases) |case| {
        const p = try plain.compile(case.source);
        const converted = try cells(p);
        defer converted.deinit(allocator);
        // The least budget the class's program completes with.
        var low: u64 = 0;
        var high: u64 = fuel;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (try plain.run(p, middle) == .ok) high = middle else low = middle;
        }
        try std.testing.expect(try made.run(converted.program, high) == .ok);
        const short = try made.run(converted.program, high - 1);
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, short.failed.code);
        try std.testing.expectEqualDeep((try plain.run(p, high - 1)).failed, short.failed);
    }
}

/// The value report of a stored run, into `buffer`.
fn report(x: evaluator.Execution, public_only: bool, buffer: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    _ = try reporting.write(&out, x, public_only, .{});
    return out.buffered();
}

test "a report names a variable cell by its id and lists each reachable one once, after the instances" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [4096]u8 = undefined;
    const Expected = struct { source: []const u8, class: []const u8, cell: []const u8 };
    for ([_]Expected{
        .{
            .source =
            \\Cell:=class{var V:i64}
            \\Get(X:Cell)<transacts>:i64=X.V
            \\A:Cell=Cell{V:=3}
            \\F:function<transacts>(tuple(),i64)=Bind(Get,A)
            \\B:Cell=A
            \\N:i64=F()
            ,
            .class = "{\"A\":{\"$object\":0},\"F\":{\"function\":{\"name\":\"Get\",\"module\":null,\"captures\":[{\"$object\":0}]}},\"B\":{\"$object\":0},\"N\":3,\"$objects\":[{\"id\":0,\"class\":\"Cell\",\"fields\":{\"V\":3}}]}\n",
            .cell = "{\"A\":{\"$ref\":0},\"F\":{\"function\":{\"name\":\"Get\",\"module\":null,\"captures\":[{\"$ref\":0}]}},\"B\":{\"$ref\":0},\"N\":3,\"$refs\":[{\"id\":0,\"value\":3}]}\n",
        },
        // Instances and cells that hold each other, numbered apart: a cell dropped before the
        // report is not listed, and ids count only what is.
        .{
            .source =
            \\Pt:=class{X:i64}
            \\Cell:=class{var V:Pt}
            \\Box:=class{var R:Cell,var S:Cell}
            \\Dropped:i64=Block{D:=Cell{V:=Pt{X:=9}};D.V.X}
            \\A:Cell=Cell{V:=Pt{X:=1}}
            \\B:Box=Box{R:=A,S:=Cell{V:=Pt{X:=2}}}
            \\set A.V=Pt{X:=5}
            \\Y:i64=A.V.X
            ,
            .class = "{\"Dropped\":9,\"A\":{\"$object\":0},\"B\":{\"$object\":6},\"Y\":5,\"$objects\":[{\"id\":0,\"class\":\"Cell\",\"fields\":{\"V\":{\"$object\":9}}},{\"id\":2,\"class\":\"Pt\",\"fields\":{\"X\":2}},{\"id\":4,\"class\":\"Cell\",\"fields\":{\"V\":{\"$object\":2}}},{\"id\":6,\"class\":\"Box\",\"fields\":{\"R\":{\"$object\":0},\"S\":{\"$object\":4}}},{\"id\":9,\"class\":\"Pt\",\"fields\":{\"X\":5}}]}\n",
            .cell = "{\"Dropped\":9,\"A\":{\"$ref\":0},\"B\":{\"$object\":2},\"Y\":5,\"$objects\":[{\"id\":0,\"class\":\"Pt\",\"fields\":{\"X\":2}},{\"id\":2,\"class\":\"Box\",\"fields\":{\"R\":{\"$ref\":0},\"S\":{\"$ref\":1}}},{\"id\":5,\"class\":\"Pt\",\"fields\":{\"X\":5}}],\"$refs\":[{\"id\":0,\"value\":{\"$object\":5}},{\"id\":1,\"value\":{\"$object\":0}}]}\n",
        },
    }) |expected| {
        const p = try h.compile(expected.source);
        const x = (try h.run(p, fuel)).ok;
        try std.testing.expectEqualStrings(expected.class, try report(x, false, &buffer));
        const converted = try cells(p);
        defer converted.deinit(allocator);
        const y = (try h.run(converted.program, fuel)).ok;
        try std.testing.expectEqualStrings(expected.cell, try report(y, false, &buffer));
    }
}

/// Programs whose frames and visits build cells, drop most and keep some: in the state, in a
/// capture, in a field of a cell, in an instance, behind a region that fails.
const reclaimed = [_][]const u8{
    "Cell:=class{var V:i64}\nStep(S:i64)<transacts>:i64=Block{X:=Cell{V:=S};set X.V=X.V+1;X.V}\nTotal<public>:i64=Iterate(Step,60,0)",
    "Cell:=class{var V:i64}\nStep(S:tuple(Cell,Cell,Cell))<transacts>:tuple(Cell,Cell,Cell)=tuple{S(1),S(2),Cell{V:=S(2).V+1}}\nEnd<public>:tuple(Cell,Cell,Cell)=Iterate(Step,50,tuple{Cell{V:=0},Cell{V:=1},Cell{V:=2}})\nSum<public>:i64=End(0).V+End(2).V",
    "Cell:=class{var V:string}\nFill(B:Cell,S:i64)<transacts>:i64=Block{set B.V=\"v{S}\";T:=tuple{S,B.V.Length};S+T(1)-T(1)+1}\nRun(N:i64)<transacts>:string=Block{B:=Cell{V:=\"\"};Iterate(Fn(S:i64){Fill(B,S)},N,0);B.V}\nEnd<public>:string=Run(60)",
    "Cell:=class{var V:i64}\nGet(X:Cell,K:i64)<transacts>:i64=X.V+K\nStep(S:tuple(i64,function<transacts>(tuple(i64),i64)))<transacts>:tuple(i64,function<transacts>(tuple(i64),i64))=Block{X:=Cell{V:=S(0)+1};D:=Cell{V:=0};tuple{S(1)(0),Bind(Get,X)}}\nSeed:Cell=Cell{V:=0}\nV<public>:i64=Iterate(Step,30,tuple{0,Bind(Get,Seed)})(0)",
    "Cell:=class{var V:i64}\nvar Hold:Cell=Cell{V:=0}\nStep(S:i64)<transacts>:i64=Block{A:=Attempt(Block{X:=Cell{V:=S};Attempt(Block{set X.V=S+1;set Hold.V=S;Require[S<6];0},1);set Hold=X;Require[S<9];X.V},-1);S+1+A-A}\nTotal<public>:i64=Iterate(Step,14,0)\nKept<public>:i64=Hold.V",
    // Cells that hold instances that hold cells, dropped visit after visit, one pair kept.
    "Pt:=class{X:i64}\nCell:=class{var V:Pt}\nBox:=class{var C:Cell,N:i64}\nvar Keep:option(Box)=option{}\nStep(S:i64)<transacts>:i64=Block{C:=Cell{V:=Pt{X:=S}};B:=Box{C:=C,N:=S};set C.V=Pt{X:=S+1};If(S==7,Block{set Keep=option{B};0},0);S+1}\nTotal<public>:i64=Iterate(Step,30,0)\nBack<public>:i64=Attempt(Block{B:=Keep?;B.C.V.X*100+B.N},-1)",
};

const Pair = struct { reference: evaluator.Execution, actual: evaluator.Execution };
/// Both machines' runs of `p` in the fixture's mode, which must agree on everything they leave:
/// values, the whole member pool, the program's cells, the instance cells, the witness and how
/// often and how much they reclaimed.
fn both(f: replay.Fixture, p: types.Program) !Pair {
    const h = f.h;
    const expected = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
    const actual = h.runtime.evaluate(p, fuel);
    try std.testing.expect(expected == .ok and actual == .ok);
    const a = expected.ok;
    const b = actual.ok;
    try std.testing.expectEqualSlices(bool, a.activity, b.activity);
    for (a.values, b.values, 0..) |x, y, index| if (b.active(index)) try replay.same(x, y);
    try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
    for (a.aggregate_values, b.aggregate_values) |x, y| try replay.same(x, y);
    try std.testing.expectEqual(h.state.cell_count, h.runtime.machine.source.cell_count);
    try std.testing.expectEqual(a.object_cells.len, b.object_cells.len);
    for (a.object_cells, b.object_cells) |x, y| try replay.same(x.value, y.value);
    try std.testing.expectEqual(a.trace, b.trace);
    try std.testing.expectEqualDeep(a.witness, b.witness);
    try std.testing.expectEqual(a.reclaims, b.reclaims);
    try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
    try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
    try std.testing.expectEqual(h.control.object_reclaim_at, h.runtime.machine.control.object_reclaim_at);
    try std.testing.expectEqual(a.program.strings.len, b.program.strings.len);
    return .{ .reference = a, .actual = b };
}
fn configure(f: replay.Fixture, trace: types.TraceMode, window: u32, floor: u32) void {
    f.mode(trace, window);
    f.h.control.reclaim_floor = floor;
    f.h.runtime.machine.control.reclaim_floor = floor;
    f.again.control.trace_window = window;
    f.again.control.reclaim_floor = floor;
}
/// The value and failure reports of a run, after a replay admitted it: of a stored witness, or
/// of a second run streamed to it.
fn replayed(f: replay.Fixture, x: evaluator.Execution, p: types.Program, into: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(into);
    _ = try reporting.writeReplayed(&out, x, f.again.producer(p, fuel), false, .{ .work = 1 << 24 });
    try trace_report.writeReplayed(&out, x, f.again.producer(p, fuel), "test.forb", .{});
    return out.buffered();
}

test "variable cells are reclaimed as instances are: both machines and the replay agree, and every trace mode reports alike" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    var freed: u64 = 0;
    for (reclaimed) |source| {
        const compiled = try f.h.compile(source);
        const converted = cells(compiled) catch |problem| {
            std.debug.print("{s}\n", .{source});
            return problem;
        };
        defer converted.deinit(allocator);
        const p = converted.program;
        // A stored witness, which never reclaims, reports what the others must.
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.h.run(p, fuel)).ok;
        try std.testing.expectEqual(@as(u64, 0), stored.reclaims);
        const cells_kept = stored.object_cells.len;
        var out = std.Io.Writer.fixed(stored_text);
        _ = try reporting.write(&out, stored, false, .{ .work = 1 << 24 });
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = out.buffered();
        var reclaiming = false;
        for ([_]u32{ 0, 1, 5, 40 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
            configure(f, .digest, window, floor);
            const runs = both(f, p) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try std.testing.expect(runs.actual.object_cells.len <= cells_kept);
            if (runs.actual.reclaims != 0) reclaiming = true;
            if (floor == 0 and window == 1) freed += f.h.control.reclaimed_cells;
            const actual = replayed(f, runs.actual, p, other) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try std.testing.expectEqualStrings(expected, actual);
            try std.testing.expectEqualStrings(expected, try replayed(f, runs.reference, p, other));
        };
        try std.testing.expect(reclaiming);
        // An `off` run has nothing to replay; the machines still agree, cell for cell.
        configure(f, .off, 5, 0);
        _ = try both(f, p);
    }
    // The cells of dropped visits went, in every program that drops them.
    try std.testing.expect(freed > 100);
}

test "a guard depends on the variable cells it reads, and a write of one is a program write that propagates" {
    const plain = try harness.create();
    defer scratch.release(plain);
    const made = try harness.create();
    defer scratch.release(made);
    const source =
        \\Cell:=class{var V:i64}
        \\C:Cell=Cell{V:=1}
        \\D:Cell=Cell{V:=100}
        \\var Y:i64=0
        \\set live Y=C.V+10
        \\var live Z:i64=Y+D.V
        \\First:tuple(i64,i64)=tuple{Y,Z}
        \\Poke(N:i64)<transacts>:i64=Block{set C.V=N;Y}
        \\P:i64=Poke(5)
        \\set D.V=200
        \\Second:tuple(i64,i64)=tuple{Y,Z}
        \\Undo(N:i64)<transacts><decides>:i64=Block{set C.V=N;Require[N<0];Y}
        \\U:i64=Attempt(Undo[50],-1)
        \\Third:tuple(i64,i64)=tuple{Y,Z}
    ;
    const p = try plain.compile(source);
    const x = (try plain.run(p, fuel)).ok;
    const kept = try Kept.of(x);
    defer kept.free();
    const live = x.live;
    const converted = try cells(p);
    defer converted.deinit(allocator);
    // The guards' reads are cell reads now, in the guards' own bodies.
    var reads: usize = 0;
    for (converted.program.functions) |function| for (converted.program.function_nodes[function.body.start..function.body.end]) |entry| {
        reads += @intFromBool(entry.input == .operation and entry.node.kind == .ref_get);
    };
    try std.testing.expect(reads >= 2);
    const y = (try made.run(converted.program, fuel)).ok;
    try kept.expect(y);
    try std.testing.expectEqualDeep(live, y.live);
    try std.testing.expect(y.live.propagations >= 2);
    const expectPair = struct {
        fn check(run: evaluator.Execution, name: []const u8, a: i64, b: i64) !void {
            const value = try binding(run, name);
            const members = run.aggregate_values[value.aggregate.elements.start..value.aggregate.elements.end];
            try std.testing.expectEqual(a, members[0].integer);
            try std.testing.expectEqual(b, members[1].integer);
        }
    }.check;
    try expectPair(y, "First", 11, 111);
    try std.testing.expectEqual(@as(i64, 15), (try binding(y, "P")).integer);
    try expectPair(y, "Second", 15, 215);
    try std.testing.expectEqual(@as(i64, -1), (try binding(y, "U")).integer);
    try expectPair(y, "Third", 15, 215);
}

test "inspection format 32 prints the cell type and the three operations" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(cases[0].source);
    const converted = try cells(p);
    defer converted.deinit(allocator);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const buffer = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(buffer);
    var out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, converted.program));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 32), parsed.value.object.get("format").?.integer);
    var found = false;
    for (parsed.value.object.get("type_definitions").?.array.items) |item| if (std.mem.eql(u8, item.object.get("kind").?.string, "ref")) {
        try std.testing.expectEqual(@as(i64, @backingInt(converted.ref)), item.object.get("id").?.integer);
        try std.testing.expectEqualStrings("i64", item.object.get("value").?.string);
        found = true;
    };
    try std.testing.expect(found);
    const text = out.buffered();
    for ([_][]const u8{ "{\"ref_new\":", "{\"ref_get\":", "{\"ref_set\":{\"ref\":" }) |needle| try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    // The program it was made from keeps its format.
    out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, p));
    const original = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer original.deinit();
    try std.testing.expect(original.value.object.get("format").?.integer < 32);
}

/// A writable copy of a report's steps and root values, for forging one of them.
const Forged = struct {
    execution: evaluator.Execution,
    steps: []types.CallStep,
    values: []types.Value,

    fn of(x: evaluator.Execution) !Forged {
        const steps = try allocator.dupe(types.CallStep, x.call_steps);
        errdefer allocator.free(steps);
        const values = try allocator.dupe(types.Value, x.values);
        var execution = x;
        execution.call_steps = steps;
        execution.values = values;
        return .{ .execution = execution, .steps = steps, .values = values };
    }
    fn free(self: Forged) void {
        allocator.free(self.values);
        allocator.free(self.steps);
    }
    fn refused(self: Forged) !bool {
        _ = reporting.validate(self.execution, false, .{ .work = 1 << 24 }) catch |err| switch (err) {
            error.InvalidExecution => return true,
            error.ReportLimit => return err,
        };
        return false;
    }
};

/// A value of the same type as `value` that differs from it: another integer, or the cell
/// after it, which has the same type.
fn changed(value: types.Value) ?types.Value {
    return switch (value) {
        .integer => |n| .{ .integer = n +% 1 },
        .object => |o| .{ .object = .{ .value_type = o.value_type, .id = o.id + catalogue.ref_cells } },
        else => null,
    };
}

test "the replay works out what a cell holds: a changed read, write or construction is refused, at the root and in a function" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(cases[0].source);
    const converted = try cells(p);
    defer converted.deinit(allocator);
    const x = (try h.run(converted.program, fuel)).ok;
    const forged = try Forged.of(x);
    defer forged.free();
    try std.testing.expect(!try forged.refused());
    var kinds: [3]usize = @splat(0);
    // Each step of a cell operation, its value changed to another of its type.
    for (forged.steps, 0..) |step, index| {
        if (step.kind != .value or step.function >= converted.program.functions.len) continue;
        const f = converted.program.functions[step.function];
        if (step.pc >= f.body.end - f.body.start) continue;
        const entry = converted.program.function_nodes[f.body.start + step.pc];
        if (entry.input != .operation) continue;
        const kind: usize = switch (entry.node.kind) {
            .ref_new => 0,
            .ref_get => 1,
            .ref_set => 2,
            else => continue,
        };
        const original = step.value;
        forged.steps[index].value = changed(original) orelse continue;
        try std.testing.expect(try forged.refused());
        forged.steps[index].value = original;
        kinds[kind] += 1;
    }
    for (kinds) |count| try std.testing.expect(count != 0);
    // And the root's own.
    kinds = @splat(0);
    for (converted.program.nodes, 0..) |node, index| {
        const kind: usize = switch (node.kind) {
            .ref_new => 0,
            .ref_get => 1,
            .ref_set => 2,
            else => continue,
        };
        if (!x.active(index)) continue;
        const original = forged.values[index];
        forged.values[index] = changed(original) orelse continue;
        try std.testing.expect(try forged.refused());
        forged.values[index] = original;
        kinds[kind] += 1;
    }
    for (kinds) |count| try std.testing.expect(count != 0);
    try std.testing.expect(!try forged.refused());
}

test "a root write of a variable cell is a delivery point in both machines and the replay" {
    // From the independent review: a pending reaction sees the root's write at once.
    const plain = try harness.create();
    defer scratch.release(plain);
    const made = try harness.create();
    defer scratch.release(made);
    for ([_][]const u8{
        \\Cell:=class{var V:i64}
        \\C:Cell=Cell{V:=0}
        \\var Fired:i64=0
        \\U:task(i64)=Upon(C.V>0,Set(Fired,Fired+1))
        \\set C.V=5
        \\A:i64=Fired
        ,
        \\Cell:=class{var V:i64}
        \\C:Cell=Cell{V:=0}
        \\var Fired:i64=0
        \\U:task(i64)=Upon(C.V>0,Set(Fired,Fired+1))
        \\Poke(N:i64)<transacts>:i64=Block{set C.V=N;Fired}
        \\B:i64=Poke(5)
        \\A:i64=Fired
        ,
        // Writes in a region that fails, at the root and in one that commits, under a `When`:
        // the value is the class program's, whatever it is.
        \\Cell:=class{var V:i64}
        \\C:Cell=Cell{V:=0}
        \\var Log:i64=0
        \\W:task(void)=When(C.V,Set(Log,Log*10+C.V))
        \\R:logic=Attempt(Block{set C.V=1;set C.V=2;Require[1>2];true},false)
        \\set C.V=3
        \\K:logic=Attempt(Block{set C.V=4;true},false)
        \\A:i64=Log
        ,
    }, [_]?i64{ 1, 1, null }) |source, expected| {
        const p = try plain.compile(source);
        const x = (try plain.run(p, fuel)).ok;
        const kept = try Kept.of(x);
        defer kept.free();
        const live = x.live;
        const converted = try cells(p);
        defer converted.deinit(allocator);
        const y = (try made.run(converted.program, fuel)).ok;
        try kept.expect(y);
        try std.testing.expectEqualDeep(live, y.live);
        if (expected) |value| try std.testing.expectEqual(value, (try binding(y, "A")).integer);
        try std.testing.expect(y.live.deliveries != 0);
    }
}

/// Random programs of cells written, read, made and dropped in functions and in regions that
/// commit or fail, nested, with what each cell must hold worked out by a plain model of cells
/// and undo: never by running the compiler or a machine.
const Generator = struct {
    random: std.Random,
    text: std.ArrayList(u8) = .empty,
    /// What each named cell holds, as the model sees it.
    model: [cell_count]i64 = undefined,
    made: usize = 0,

    const cell_count = 4;

    fn print(self: *Generator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(allocator, format, arguments);
    }
    /// Statements of a block, `depth` regions deep, each followed by `;`.
    fn statements(self: *Generator, depth: u32) !void {
        const count = self.random.intRangeAtMost(u32, 1, 4);
        for (0..count) |_| {
            const i = self.random.uintLessThan(usize, cell_count);
            const j = self.random.uintLessThan(usize, cell_count);
            const k = self.random.intRangeAtMost(i64, 0, 9);
            switch (self.random.uintLessThan(u32, if (depth < 3) 4 else 3)) {
                0 => {
                    try self.print("set C{d}.V=C{d}.V+{d};", .{ i, i, k });
                    self.model[i] +%= k;
                },
                1 => {
                    try self.print("set C{d}.V=C{d}.V*2-{d};", .{ i, j, k });
                    self.model[i] = self.model[j] *% 2 -% k;
                },
                // A cell made here, written, read into a named one and dropped.
                2 => {
                    const x = self.made;
                    self.made += 1;
                    try self.print("X{d}:=Cell{{V:=C{d}.V}};set X{d}.V=X{d}.V+{d};set C{d}.V=X{d}.V;", .{ x, j, x, x, k, i, x });
                    self.model[i] = self.model[j] +% k;
                },
                // A region that commits or fails.
                3 => {
                    const saved = self.model;
                    const fails = self.random.boolean();
                    try self.print("Attempt(Block{{", .{});
                    try self.statements(depth + 1);
                    try self.print("Require[{s}];0}},1);", .{if (fails) "1>2" else "1<2"});
                    if (fails) self.model = saved;
                },
                else => unreachable,
            }
        }
    }

    fn program(self: *Generator) ![]u8 {
        self.made = 0;
        for (&self.model, 0..) |*cell, i| cell.* = @intCast(i * 10);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "Cell:=class{var V:i64}\n");
        for (0..cell_count) |i| try out.print(allocator, "C{d}:Cell=Cell{{V:={d}}}\n", .{ i, i * 10 });
        // Functions of statements, called in order from the root.
        for (0..self.random.intRangeAtMost(u32, 1, 3)) |n| {
            self.text.clearRetainingCapacity();
            try self.statements(0);
            try out.print(allocator, "G{d}()<transacts>:i64=Block{{{s}0}}\nR{d}:i64=G{d}()\n", .{ n, self.text.items, n, n });
        }
        for (0..cell_count) |i| try out.print(allocator, "K{d}:i64=C{d}.V\n", .{ i, i });
        return out.toOwnedSlice(allocator);
    }
    fn deinit(self: *Generator) void {
        self.text.deinit(allocator);
    }
};

test "random programs of variable cells hold what a model of cells and undo says, and what their class computes" {
    const plain = try harness.create();
    defer scratch.release(plain);
    const made = try harness.create();
    defer scratch.release(made);
    var prng = std.Random.DefaultPrng.init(0x85b1);
    var generator: Generator = .{ .random = prng.random() };
    defer generator.deinit();
    var failed_regions: usize = 0;
    for (0..150) |_| {
        const source = try generator.program();
        defer allocator.free(source);
        failed_regions += std.mem.count(u8, source, "1>2");
        const p = try plain.compile(source);
        const x = (try plain.run(p, fuel)).ok;
        const kept = try Kept.of(x);
        defer kept.free();
        const converted = try cells(p);
        defer converted.deinit(allocator);
        const y = (try made.run(converted.program, fuel)).ok;
        kept.expect(y) catch |problem| {
            std.debug.print("{s}\n", .{source});
            return problem;
        };
        for (0..Generator.cell_count) |i| {
            var name: [2]u8 = .{ 'K', '0' + @as(u8, @intCast(i)) };
            const value = (try binding(y, &name)).integer;
            std.testing.expectEqual(generator.model[i], value) catch |problem| {
                std.debug.print("{s}\n", .{source});
                return problem;
            };
            // And the cell itself holds it at the end.
            name[0] = 'C';
            try std.testing.expectEqual(generator.model[i], (try held(y, try binding(y, &name))).integer);
        }
    }
    try std.testing.expect(failed_regions > 50);
}
