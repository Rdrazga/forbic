//! Grants and handles (RFC-0086, P2.3): `OpenReader[N]`, `OpenWriter[N]`, `R.ReadLine[]` and
//! `W.WriteLine(T)`. Every program runs on both machines through the harness, each given the
//! same grants: the reference evaluator reads a scripted world (`effects.Script`), the VM is
//! given the reference's record as its prefix and no world, and the report of each is replayed
//! against the record. Both machines must agree on values, fuel, diagnostics, the record and the
//! committed actions with their channels, whether the run completes or not.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const stdlib_natives = @import("stdlib_natives.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_replay = @import("trace_replay.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;

/// The grants most tests give: a reader `config` (index 0), a writer `log` (1), a second reader
/// `extra` (2) and a writer `audit` (3).
const standard_grants = [_]effects.Grant{
    .{ .kind = .reader, .name = "config" },
    .{ .kind = .writer, .name = "log" },
    .{ .kind = .reader, .name = "extra" },
    .{ .kind = .writer, .name = "audit" },
};
const config_lines = [_][]const u8{ "alpha", "beta", "gamma" };
const extra_lines = [_][]const u8{"one"};

/// Both machines and a scripted world, which only the first machine is given.
const Bench = struct {
    h: *harness.Harness,
    script: *effects.Script,

    fn create() !Bench {
        const h = try harness.create();
        errdefer scratch.release(h);
        const script = try std.testing.allocator.create(effects.Script);
        // The streams are by grant index: the writers' slots are never read.
        script.* = .{ .streams = &.{ &config_lines, &.{}, &extra_lines } };
        h.control.effects.inputs.source = script.source();
        h.control.effects.inputs.grants = &standard_grants;
        return .{ .h = h, .script = script };
    }
    fn destroy(self: Bench) void {
        std.testing.allocator.destroy(self.script);
        scratch.release(self.h);
    }
    /// A run of both machines from a fresh world.
    fn outcome(self: Bench, source: []const u8, budget: u64) !evaluator.Result {
        self.script.rewind();
        const p = try self.h.compile(source);
        return self.h.run(p, budget);
    }
    fn run(self: Bench, source: []const u8) !evaluator.Execution {
        const result = try self.outcome(source, fuel);
        if (result == .failed) {
            std.debug.print("run failed: {t} at {d}: {s}\n", .{ result.failed.code, result.failed.span.start, source });
            return error.RunFailed;
        }
        return result.ok;
    }
    fn fails(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
        const result = try self.outcome(source, fuel);
        if (result != .failed) {
            std.debug.print("expected {t}: {s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(code, result.failed.code);
        try std.testing.expectEqualStrings(at, source[result.failed.span.start..result.failed.span.end]);
    }
    fn refused(self: Bench, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
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

/// The lines a `full` run committed on `channel`.
fn committed(x: evaluator.Execution, channel: u32, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (x.effects.entries, 0..) |entry, index| if (entry.channel == channel) writer.print("{s}\n", .{x.effects.text(index)}) catch unreachable;
    return writer.buffered();
}

fn reportOf(x: evaluator.Execution, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try reporting.write(&out, x, false, .{});
    return out.buffered();
}

test "the source contract: handles open, lines are read and spent, writes commit with their region" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Config:option(reader) = option{OpenReader["config"]}
        \\Log:option(writer) = option{OpenWriter["log"]}
        \\First:string = Attempt(Block{R := Config?; R.ReadLine[]}, "")
        \\Kept:i64 = Attempt(Block{W := Log?; W.WriteLine("start {First}"); 1}, 0)
        \\Gone:i64 = Attempt(Block{W := Log?; W.WriteLine("never"); Require[false]; 1}, 0)
        \\Lost:string = Attempt(Block{R := Config?; L := R.ReadLine[]; Require[false]; L}, "-")
        \\Next:string = Attempt(Block{R := Config?; R.ReadLine[]}, "")
    );
    try std.testing.expectEqualStrings("alpha", x.get("First").?.string);
    try std.testing.expectEqual(@as(i64, 0), x.get("Gone").?.integer);
    try std.testing.expectEqualStrings("-", x.get("Lost").?.string);
    try std.testing.expectEqualStrings("gamma", x.get("Next").?.string);
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("start alpha\n", committed(x, 2, &buffer));
    try std.testing.expectEqualStrings("", committed(x, 0, &buffer));
    var report: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("{\"Config\":[{\"$reader\":\"config\"}],\"Log\":[{\"$writer\":\"log\"}],\"First\":\"alpha\",\"Kept\":1,\"Gone\":0,\"Lost\":\"-\",\"Next\":\"gamma\",\"$inputs\":{\"count\":3,\"bytes\":14}}\n", try reportOf(x, &report));
}

fn text(x: evaluator.Execution, name: []const u8) []const u8 {
    return x.get(name).?.string;
}
fn integer(x: evaluator.Execution, name: []const u8) i64 {
    return x.get(name).?.integer;
}

test "opening looks a name up among the grants of its kind: equal handles, two kinds, none (H3)" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Same:logic = Attempt(OpenReader["config"] == OpenReader["config"], false)
        \\Other:logic = Attempt(OpenReader["config"] == OpenReader["extra"], true)
        \\Writers:logic = Attempt(OpenWriter["log"] == OpenWriter["audit"], true)
        \\Kinds:i64 = Attempt(Block{W := OpenReader["log"]; 1}, 2)
        \\None:i64 = Attempt(Block{W := OpenWriter["config"]; 1}, 2)
        \\Missing:i64 = Attempt(Block{W := OpenWriter["nothing"]; 1}, 3)
        \\Named(N:string)<reads><decides>:reader = OpenReader[N]
        \\Found:i64 = Attempt(Block{R := Named["ex" + "tra"]; 1}, 0)
    );
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expect(!x.get("Other").?.boolean);
    try std.testing.expect(!x.get("Writers").?.boolean);
    try std.testing.expectEqual(@as(i64, 2), integer(x, "Kinds"));
    try std.testing.expectEqual(@as(i64, 2), integer(x, "None"));
    try std.testing.expectEqual(@as(i64, 3), integer(x, "Missing"));
    try std.testing.expectEqual(@as(i64, 1), integer(x, "Found"));
    // Opening reads nothing from the world.
    try std.testing.expectEqual(@as(usize, 0), x.effects.inputs.len);
    try std.testing.expectEqual(@as(u64, 0), b.script.reads);
    // A run with no grants has no handle to give.
    b.h.control.effects.inputs.grants = &.{};
    defer b.h.control.effects.inputs.grants = &standard_grants;
    const bare = try b.run("A:i64 = Attempt(Block{R := OpenReader[\"config\"]; 1}, 0)");
    try std.testing.expectEqual(@as(i64, 0), integer(bare, "A"));
}

test "two handles of one grant read one stream, a line read in a region that fails is spent, and the end is the end (I2, I6, I7)" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Line(R:reader)<transacts>:string = Attempt(R.ReadLine[], "<end>")
        \\A:option(reader) = option{OpenReader["config"]}
        \\B:option(reader) = option{OpenReader["config"]}
        \\One:string = Attempt(Line(A?), "-")
        \\Two:string = Attempt(Line(B?), "-")
        \\Spent:string = Attempt(Block{R := B?; L := R.ReadLine[]; Require[L == "nothing"]; L}, "spent")
        \\End:string = Attempt(Line(A?), "-")
        \\Again:string = Attempt(Line(B?), "-")
        \\Extra:string = Attempt(Block{E := OpenReader["extra"]; E.ReadLine[]}, "none")
    );
    try std.testing.expectEqualStrings("alpha", text(x, "One"));
    try std.testing.expectEqualStrings("beta", text(x, "Two"));
    try std.testing.expectEqualStrings("spent", text(x, "Spent"));
    try std.testing.expectEqualStrings("<end>", text(x, "End"));
    try std.testing.expectEqualStrings("<end>", text(x, "Again"));
    try std.testing.expectEqualStrings("one", text(x, "Extra"));
    // Every read is an entry, the ends included, each asking for its grant's line.
    const requests = [_]u32{ 0, 0, 0, 0, 0, 2 };
    const statuses = [_]effects.InputStatus{ .value, .value, .value, .end, .end, .value };
    try std.testing.expectEqual(requests.len, x.effects.inputs.len);
    for (x.effects.inputs, requests, statuses) |entry, request, status| {
        try std.testing.expectEqual(effects.InputKind.line, entry.kind);
        try std.testing.expectEqual(request, entry.request);
        try std.testing.expectEqual(status, entry.status);
        try std.testing.expectEqual(@as(u64, 0), entry.tick);
    }
    try std.testing.expectEqualStrings("alphabetagammaone", x.effects.input_bytes);
}

test "lines are text as they are: an empty one, a carriage return, a lone line; bytes that are not text end the run (I6)" {
    const b = try Bench.create();
    defer b.destroy();
    const odd = [_][]const u8{ "", "carriage\r", "\xe9\x9b\xaa", "last" };
    b.script.streams = &.{&odd};
    defer b.script.streams = &.{ &config_lines, &.{}, &extra_lines };
    const program = "Line(R:reader)<transacts>:string = Attempt(R.ReadLine[], \"<end>\")\nAll(R:reader)<transacts>:tuple(string, string, string, string, string) = tuple{Line(R), Line(R), Line(R), Line(R), Line(R)}\nT:tuple(string, string, string, string, string) = Attempt(All(OpenReader[\"config\"]), tuple{\"\", \"\", \"\", \"\", \"\"})\nL:i64 = T(1).Length";
    const x = try b.run(program);
    const lines = x.get("T").?.aggregate.elements;
    const expected = [_][]const u8{ "", "carriage\r", "\xe9\x9b\xaa", "last", "<end>" };
    for (x.aggregate_values[lines.start..lines.end], expected) |value, line| try std.testing.expectEqualStrings(line, value.string);
    try std.testing.expectEqual(@as(i64, 9), integer(x, "L"));
    // Bytes that are not UTF-8, or a newline inside a line, are no line of text: `input_invalid`
    // at the call, and the record keeps the entry (I8).
    for ([_][]const u8{ "\xff", "a\nb", "\xe9\x9b" }) |bad| {
        const stream = [_][]const u8{ "fine", bad };
        b.script.streams = &.{&stream};
        try b.fails(program, .input_invalid, "ReadLine");
        try std.testing.expectEqual(@as(u32, 2), b.h.control.effects.inputs.count);
    }
}

/// The lines a `full` run committed, `channel: text` each.
fn tagged(x: evaluator.Execution, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (x.effects.entries, 0..) |entry, index| writer.print("{d}: {s}\n", .{ entry.channel, x.effects.text(index) }) catch unreachable;
    return writer.buffered();
}

test "a line written is an action on its writer's channel: held by its region, committed with the outermost one, in program order with Print (H5)" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Note(W:writer, T:string)<transacts>:void = W.WriteLine(T)
        \\Inner(Log:writer, Audit:writer)<transacts>:i64 = Block{ Audit.WriteLine("a1"); J := Attempt(Block{ Note(Log, "l2"); Print("p2"); Require[false]; 1 }, 2); Note(Audit, "a2"); J }
        \\Outer(Log:writer, Audit:writer)<transacts>:i64 = Block{ Print("p1"); Note(Log, "l1"); I := Attempt(Inner(Log, Audit), 3); K := Attempt(Block{ Note(Log, "gone"); Require[false]; 4 }, 5); Print("p3"); I + K }
        \\Root:i64 = Attempt(Block{ L := OpenWriter["log"]; L.WriteLine("root"); 1 }, 0)
        \\Deep:i64 = Attempt(Block{ L := OpenWriter["log"]; A := OpenWriter["audit"]; Outer(L, A) }, 0)
        \\After:i64 = Attempt(Block{ Note(OpenWriter["audit"], "after"); 1 }, 0)
    );
    try std.testing.expectEqual(@as(i64, 7), integer(x, "Deep"));
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\2: root
        \\0: p1
        \\2: l1
        \\4: a1
        \\4: a2
        \\0: p3
        \\4: after
        \\
    , tagged(x, &buffer));
    // Three lines were dropped with their regions: `l2`, `p2` and `gone`.
    try std.testing.expectEqual(@as(u64, 3), x.effects.discarded);
    try std.testing.expectEqual(@as(u64, 7), x.effects.output.count);
    // A writer's lines read nothing from the world.
    try std.testing.expectEqual(@as(usize, 0), x.effects.inputs.len);
    // Outside every region a line is committed at once.
    const root = try b.run("W:option(writer) = option{OpenWriter[\"audit\"]}\nA:i64 = Attempt(Block{ X := W?; 1 }, 0)\nB:tuple() = Print(\"between\")\nC:i64 = Attempt(Block{ X := W?; X.WriteLine(\"held\"); 1 }, 0)");
    try std.testing.expectEqualStrings("0: between\n4: held\n", tagged(root, &buffer));
}

test "a digest run hands each committed line to its sink with its channel, in one sequence" {
    const b = try Bench.create();
    defer b.destroy();
    const source = "Go(W:writer)<transacts>:i64 = Block{ W.WriteLine(\"one\"); Print(\"two\"); C := Attempt(Block{ W.WriteLine(\"three\"); Print(\"four\"); 1 }, 0); D := Attempt(Block{ W.WriteLine(\"never\"); Require[false]; 1 }, 0); C + D }\nA:i64 = Attempt(Go(OpenWriter[\"audit\"]), 9)";
    const p = try b.h.compile(source);
    var recorder: effects.Recorder = .{};
    const vm = &b.h.runtime.machine.control;
    vm.effects.inputs.grants = &standard_grants;
    vm.effects.sink = recorder.sink();
    vm.trace = .digest;
    defer {
        vm.effects.sink = null;
        vm.trace = .full;
        vm.effects.inputs.grants = &.{};
    }
    const x = b.h.runtime.evaluate(p, fuel).ok;
    try std.testing.expectEqual(@as(i64, 1), integer(x, "A"));
    // `Go` runs inside the root's `Attempt`: its lines are committed with it, in order.
    const channels = [_]u32{ 4, 0, 4, 0 };
    const texts = [_][]const u8{ "one", "two", "three", "four" };
    var commits: usize = 0;
    for (recorder.calls[0..recorder.call_count]) |call| if (call.kind == .commit) {
        try std.testing.expectEqual(channels[commits], call.channel);
        try std.testing.expectEqual(@as(u64, commits), call.sequence);
        try std.testing.expectEqualStrings(texts[commits], recorder.text(call));
        commits += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), commits);
}

test "tasks hold handles across a switch and read and write at the tick they run at" {
    const b = try Bench.create();
    defer b.destroy();
    const x = try b.run(
        \\Later(R:reader, W:writer, Wait:float)<transacts><suspends>:string = Block{ Sleep(Wait); L := Attempt(R.ReadLine[], "<end>"); W.WriteLine("{Wait} {L}"); L }
        \\Both:option(tuple(reader, writer)) = option{tuple{OpenReader["config"], OpenWriter["log"]}}
        \\Start(Wait:float)<transacts>:option(task(string)) = Attempt(Block{ P := Both?; option{Spawn{ Later(P(0), P(1), Wait) }} }, option{})
        \\A:option(task(string)) = Start(2.0)
        \\B:option(task(string)) = Start(1.0)
        \\First:string = Attempt(Block{ P := Both?; P(0).ReadLine[] }, "<end>")
    );
    try std.testing.expectEqualStrings("alpha", text(x, "First"));
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("1 beta\n2 gamma\n", committed(x, 2, &buffer));
    const ticks = [_]u64{ 0, 60, 120 };
    try std.testing.expectEqual(ticks.len, x.effects.inputs.len);
    for (x.effects.inputs, ticks) |entry, tick| try std.testing.expectEqual(tick, entry.tick);
}

test "handles are values: in arrays, maps, options, tuples, fields and variables, passed, returned and compared" {
    const b = try Bench.create();
    defer b.destroy();
    var report: [2048]u8 = undefined;
    const x = try b.run(
        \\Box := class{ R:reader, var W:option(writer) }
        \\Open(N:string)<reads><decides>:reader = OpenReader[N]
        \\var Current:option(reader) = option{}
        \\Rs:[]reader = Attempt(array{Open["config"], Open["extra"]}, array{})
        \\M:map(reader, string) = Attempt(map{Open["extra"] => "x", Open["config"] => "c"}, map{})
        \\Pair:option(tuple(reader, i64)) = option{tuple{Open["config"], 1}}
        \\Boxed:option(Box) = option{Box{R := Open["extra"], W := option{OpenWriter["log"]}}}
        \\Stored:i64 = Attempt(Block{ set Current = option{Open["config"]}; 1 }, 0)
        \\Look:string = Attempt(M[Open["config"]], "-")
        \\Same:logic = Attempt(Block{ B := Boxed?; Rs[1] == B.R }, false)
        \\Read:string = Attempt(Block{ R := Current?; R.ReadLine[] }, "-")
        \\Kept:option(reader) = Current
    );
    try std.testing.expectEqualStrings("c", text(x, "Look"));
    try std.testing.expect(x.get("Same").?.boolean);
    try std.testing.expectEqualStrings("alpha", text(x, "Read"));
    const shown = try reportOf(x, &report);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\"Rs\":[{\"$reader\":\"config\"},{\"$reader\":\"extra\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\"Kept\":[{\"$reader\":\"config\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "{\"$writer\":\"log\"}") != null);
}

test "a program that names no handle keeps its catalogue, IR and report" {
    const b = try Bench.create();
    defer b.destroy();
    const plain = try b.h.compile("A:i64 = 1\nB:string = \"x\"\nC:tuple() = Print(B)");
    for (plain.definitions) |definition| try std.testing.expect(definition != .grant);
    for (plain.nodes) |node| try std.testing.expect(node.kind != .grant);
    var report: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"A\":1,\"B\":\"x\",\"C\":[]}\n", try reportOf(try b.run("A:i64 = 1\nB:string = \"x\"\nC:tuple() = Print(B)"), &report));
    // The record of a run that opens a grant lists them all, a run parameter as the seed is.
    try std.testing.expectEqual(@as(usize, standard_grants.len), (try b.run("A:i64 = Attempt(Block{ R := OpenReader[\"extra\"]; 1 }, 0)")).effects.grants.len);
}

test "every compile diagnostic of the forms, at its place" {
    const b = try Bench.create();
    defer b.destroy();
    // Opening reads the run's grants: a function that only computes may not.
    try b.refused("F()<computes><decides>:reader = OpenReader[\"config\"]", .call_requires_reads, "OpenReader");
    try b.refused("F()<writes><decides>:writer = OpenWriter[\"log\"]", .call_requires_reads, "OpenWriter");
    // A line and a write are effect natives: all three heap effects, named as for a call.
    try b.refused("F(R:reader)<reads><decides>:string = R.ReadLine[]", .call_requires_writes_allocates, "ReadLine");
    try b.refused("F(W:writer)<reads><writes>:void = W.WriteLine(\"x\")", .call_requires_allocates, "WriteLine");
    try b.refused("F(W:writer)<computes>:void = W.WriteLine(\"x\")", .call_requires_transacts, "WriteLine");
    // Both dictate, as every input and every write but `Print` does (D15); opening predicts.
    try b.refused("F(R:reader)<transacts><predicts><decides>:string = R.ReadLine[]", .call_requires_dictates, "ReadLine");
    try b.refused("F(W:writer)<transacts><predicts>:void = W.WriteLine(\"x\")", .call_requires_dictates, "WriteLine");
    _ = try b.h.compile("F()<reads><predicts><decides>:reader = OpenReader[\"config\"]");
    // Each that can fail stands in a failure context, written with brackets.
    try b.refused("A:reader = OpenReader[\"config\"]", .failure_context_required, "OpenReader");
    try b.refused("F(R:reader)<transacts>:string = R.ReadLine[]", .failure_context_required, "ReadLine");
    try b.refused("A:i64 = Attempt(Block{ R := OpenReader(\"config\"); 1 }, 0)", .expected_call, "OpenReader");
    try b.refused("F(R:reader)<transacts>:string = Attempt(R.ReadLine(), \"\")", .expected_call, "ReadLine");
    try b.refused("F(W:writer)<transacts>:void = W.WriteLine[\"x\"]", .expected_call, "WriteLine");
    // A name is a `string`, and so is a line written.
    try b.refused("A:i64 = Attempt(Block{ R := OpenReader[1]; 1 }, 0)", .type_mismatch, "1");
    try b.refused("F(W:writer)<transacts>:void = W.WriteLine(42)", .type_mismatch, "42");
    try b.refused("A:i64 = Attempt(Block{ R := OpenReader[\"a\", \"b\"]; 1 }, 0)", .argument_count, ",");
    try b.refused("F(R:reader)<transacts>:string = Attempt(R.ReadLine[1], \"\")", .argument_count, "ReadLine");
    // The methods belong to their kind of handle.
    try b.refused("F(R:reader)<transacts>:void = R.WriteLine(\"x\")", .unknown_field, "WriteLine");
    try b.refused("F(W:writer)<transacts>:string = Attempt(W.ReadLine[], \"\")", .unknown_field, "ReadLine");
    // A guard reads cells and nothing else, so it reads no line and writes none.
    try b.refused("var X:i64 = 0\nR:option(reader) = option{OpenReader[\"config\"]}\nW:task(void) = When(X > Attempt(Block{ H := R?; H.ReadLine[].Length }, 0), Print(\"late\"))", .guard_effect, "ReadLine");
    try b.refused("var X:i64 = 0\nO:option(writer) = option{OpenWriter[\"log\"]}\nU:task(void) = Upon(Block{ Attempt(Block{ H := O?; H.WriteLine(\"x\"); 1 }, 0); X > 0 }, Print(\"late\"))", .guard_effect, "WriteLine");
    // Neither type can be built, cast to `any` or named as a function.
    try b.refused("A:reader = reader{}", .unknown_name, "reader");
    try b.refused("F(R:reader)<computes>:any = any(R)", .type_mismatch, "R");
    try b.refused("A:i64 = Attempt(Block{ R := reader(\"config\"); 1 }, 0)", .unknown_name, "reader");
    try b.refused("F(W:writer)<computes>:i64 = W.Name", .unknown_field, "Name");
}

test "the names yield to every declaration of them, and are the standard ones elsewhere" {
    const b = try Bench.create();
    defer b.destroy();
    // A function, a local and a parameter of the name.
    const programs = [_][]const u8{
        "OpenReader(N:string)<computes>:i64 = N.Length\nA:i64 = OpenReader(\"four\")",
        "A:i64 = Block{ OpenReader := Fn(N:string)<computes>:i64{N.Length}; OpenReader(\"four\") }",
        "F(OpenWriter:function(tuple(string), i64))<computes>:i64 = OpenWriter(\"four\")\nG(N:string)<computes>:i64 = N.Length\nA:i64 = F(G)",
        "OpenReader(N:string)<computes><decides>:i64 = N.Length\nA:i64 = Attempt(OpenReader[\"four\"], 0)",
    };
    for (programs) |source| try std.testing.expectEqual(@as(i64, 4), integer(try b.run(source), "A"));
    // Types of the program's own named `reader` and `writer`.
    const own = try b.run("reader := class{ N:i64 }\nwriter := struct{ M:i64 }\nR:reader = reader{ N := 3 }\nW:writer = writer{ M := 1 }\nA:i64 = R.N + W.M");
    try std.testing.expectEqual(@as(i64, 4), integer(own, "A"));
    // Extension methods of the names for the handle types are what the names mean.
    const extended = try b.run("(R:reader).ReadLine<public>()<computes>:string = \"own\"\n(W:writer).WriteLine<public>(T:string)<computes>:i64 = T.Length\nA:string = Attempt(Block{ R := OpenReader[\"config\"]; R.ReadLine() }, \"-\")\nB:i64 = Attempt(Block{ W := OpenWriter[\"log\"]; W.WriteLine(\"four\") }, 0)");
    try std.testing.expectEqualStrings("own", text(extended, "A"));
    try std.testing.expectEqual(@as(i64, 4), integer(extended, "B"));
    try std.testing.expectEqual(@as(usize, 0), extended.effects.inputs.len);
    // A declaration further down is the module's throughout: a use above it is refused.
    try b.refused("A:i64 = Attempt(Block{ R := OpenReader[\"config\"]; 1 }, 0)\nOpenReader(N:string)<computes><decides>:i64 = 1", .unknown_name, "OpenReader");
    try b.refused("F()<reads>:i64 = Block{ X := Attempt(Block{ R := OpenReader[\"config\"]; 1 }, 0); OpenReader := 1; X }", .used_before_declaration, "OpenReader");
    // A bare name is no call.
    try b.refused("A:i64 = Block{ F := OpenReader; 1 }", .unknown_name, "OpenReader");
    // A module of a bundle: what it exports wins where it is used, the standard form elsewhere.
    const modules = @import("modules.zig");
    const lib = "OpenReader<public>(N:string)<computes><decides>:i64 = N.Length\nRead<public>()<transacts>:string = Attempt(Block{ R := OpenWriter[\"log\"]; \"log\" }, \"-\")";
    const used = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA<public>:i64 = Attempt(OpenReader[\"four\"], 0)\nB<public>:string = L.Read()" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const bundled = (try b.h.run(b.h.front.compileBundle(.{ .root = "main.forb", .modules = &used }).ok, fuel)).ok;
    try std.testing.expectEqual(@as(i64, 4), integer(bundled, "A"));
    try std.testing.expectEqualStrings("log", text(bundled, "B"));
    const plain = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64 = Attempt(Block{ R := OpenReader[\"config\"]; 1 }, 0)\nB<public>:i64 = Attempt(L.OpenReader[\"four\"], 0)" },
        .{ .path = "lib.forb", .source = lib },
    };
    b.script.rewind();
    const standard = (try b.h.run(b.h.front.compileBundle(.{ .root = "main.forb", .modules = &plain }).ok, fuel)).ok;
    try std.testing.expectEqual(@as(i64, 1), integer(standard, "A"));
    try std.testing.expectEqual(@as(i64, 4), integer(standard, "B"));
    // The natives by their ids, as RFC-0079's are.
    const bound = try b.run("Read := native{\"std.read_line\"}\nWrite := native{\"std.write_line\"}\nF(R:reader, W:writer)<transacts>:string = Block{ Write(W, \"x\"); Attempt(Read(R)?, \"-\") }\nA:string = Attempt(F(OpenReader[\"config\"], OpenWriter[\"log\"]), \"none\")");
    try std.testing.expectEqualStrings("alpha", text(bound, "A"));
}

test "a reader's device that fails, a run with no world, and a record that is full end the run at the call" {
    const b = try Bench.create();
    defer b.destroy();
    const program = "F(R:reader)<transacts>:string = Block{ A := Attempt(R.ReadLine[], \"\"); Attempt(R.ReadLine[], \"\") }\nX:string = Attempt(F(OpenReader[\"config\"]), \"-\")";
    // A device that fails: the second machine has a world of its own that fails alike.
    b.script.fail_read = 1;
    var failing: effects.Script = .{ .fail_read = 1, .streams = &.{&config_lines} };
    b.h.runtime.machine.control.effects.inputs.source = failing.source();
    try b.fails(program, .input_failed, "ReadLine");
    b.h.runtime.machine.control.effects.inputs.source = null;
    try std.testing.expectEqual(@as(u32, 1), b.h.control.effects.inputs.count);
    b.script.fail_read = null;
    // A host that gives no world.
    b.h.control.effects.inputs.source = null;
    defer b.h.control.effects.inputs.source = b.script.source();
    try b.fails(program, .input_unavailable, "ReadLine");
    try std.testing.expectEqual(@as(u32, 0), b.h.control.effects.inputs.count);
}

test "lines fill the record's entries exactly, and one more is input_limit at the call, with the record kept" {
    try @import("profile.zig").requireBootstrap();
    const b = try Bench.create();
    defer b.destroy();
    // Empty lines take no bytes: the entries are what runs out. (The bytes run out with the
    // string pool of a run that stores its steps, which holds every line it read; the log's
    // own bound on bytes is tested in `effects.zig`.)
    const lines = try std.testing.allocator.alloc([]const u8, effects.input_entry_capacity + 1);
    defer std.testing.allocator.free(lines);
    @memset(lines, "");
    const streams = [_][]const []const u8{lines};
    b.script.streams = &streams;
    defer b.script.streams = &.{ &config_lines, &.{}, &extra_lines };
    const format = "F(R:reader, N:i64)<transacts>:i64 = Block{{ var I:i64 = 0; While(I < N, Block{{ Attempt(R.ReadLine[], \"\"); set I = I + 1 }}); I }}\nX:i64 = Attempt(F(OpenReader[\"config\"], {d}), 0)";
    var source: [512]u8 = undefined;
    // A thousand reads outgrow the stored witness: both machines run in `digest` mode, the
    // second given the first one's record and the same grants, as the harness gives them.
    const h = b.h;
    for ([_]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |control| control.trace = .digest;
    defer for ([_]*types.ControlStorage{ &h.control, &h.runtime.machine.control }) |control| {
        control.trace = .full;
    };
    h.runtime.machine.control.effects.inputs.grants = &standard_grants;
    defer h.runtime.machine.control.effects.inputs.grants = &.{};
    for ([_]usize{ effects.input_entry_capacity, effects.input_entry_capacity + 1 }) |reads| {
        b.script.rewind();
        const p = try h.compile(try std.fmt.bufPrint(&source, format, .{reads}));
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, fuel);
        h.runtime.machine.control.effects.inputs.prefix = h.control.effects.inputs.record();
        const actual = h.runtime.evaluate(p, fuel);
        for ([_]evaluator.Result{ reference, actual }) |result| {
            if (reads == effects.input_entry_capacity) {
                try std.testing.expectEqual(@as(i64, @intCast(reads)), result.ok.get("X").?.integer);
            } else {
                // One more: `input_limit` at the call, with the full record kept (I8).
                try std.testing.expectEqual(types.Diagnostic.Code.input_limit, result.failed.code);
                try std.testing.expectEqualStrings("ReadLine", p.source[result.failed.span.start..result.failed.span.end]);
            }
        }
        try std.testing.expectEqualDeep(h.control.effects.inputs.record().entries, h.runtime.machine.control.effects.inputs.record().entries);
        try std.testing.expectEqual(@as(u32, effects.input_entry_capacity), h.runtime.machine.control.effects.inputs.count);
    }
}

test "at every budget both machines stop at the same node with the same record, actions and lines" {
    const b = try Bench.create();
    defer b.destroy();
    const sources = [_][]const u8{
        "F(R:reader, W:writer)<transacts>:string = Block{ L := Attempt(R.ReadLine[], \"\"); W.WriteLine(L); M := Attempt(Block{ X := R.ReadLine[]; W.WriteLine(X); Require[false]; X }, \"-\"); M }\nA:string = Attempt(F(OpenReader[\"config\"], OpenWriter[\"log\"]), \"none\")",
        "Later(R:reader)<transacts><suspends>:string = Block{ Sleep(1.0); Attempt(R.ReadLine[], \"\") }\nT:option(task(string)) = Attempt(Block{ R := OpenReader[\"extra\"]; option{Spawn{ Later(R) }} }, option{})\nB:i64 = Attempt(Block{ W := OpenWriter[\"audit\"]; W.WriteLine(\"b\"); 1 }, 0)",
        "Step(S:string)<transacts>:string = Attempt(Block{ R := OpenReader[\"config\"]; W := OpenWriter[\"log\"]; L := R.ReadLine[]; W.WriteLine(L); S + L }, S)\nA:string = Iterate(Step, 4, \"\")",
    };
    for (sources) |source| {
        const whole = (try b.outcome(source, fuel)).ok;
        const entries = whole.effects.inputs.len;
        var budget: u64 = 1;
        var stopped: usize = 0;
        while (budget < 4096) : (budget += 1) {
            const result = try b.outcome(source, budget);
            if (result == .ok) break;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            // Whatever was recorded before the limit is a prefix of the whole run's record.
            const kept = b.h.control.effects.inputs.record();
            try std.testing.expect(kept.entries.len <= entries);
            try std.testing.expectEqualDeep(whole.effects.inputs[0..kept.entries.len], kept.entries);
            stopped += 1;
        }
        try std.testing.expect(stopped > 5 and budget < 4096);
    }
}

test "the tool's rerun after a limit is served the first attempt's lines and asks the world only past them" {
    const b = try Bench.create();
    defer b.destroy();
    const source = "F(R:reader)<transacts>:string = Block{ A := Attempt(R.ReadLine[], \"\"); B := Attempt(R.ReadLine[], \"\"); C := Attempt(R.ReadLine[], \"\"); A + B + C }\nX:string = Attempt(F(OpenReader[\"config\"]), \"-\")";
    const p = try b.h.compile(source);
    const vm = &b.h.runtime.machine.control.effects.inputs;
    vm.grants = &standard_grants;
    defer vm.grants = &.{};
    var first: effects.Script = .{ .streams = &.{&config_lines} };
    vm.source = first.source();
    vm.prefix = .{};
    defer vm.source = null;
    // The first attempt stops after its second line.
    var budget: u64 = 1;
    while (true) : (budget += 1) {
        const attempt = b.h.runtime.evaluate(p, budget);
        if (attempt == .failed and vm.count == 2) break;
        first.rewind();
        try std.testing.expect(budget < 4096);
    }
    // The second attempt, in digest mode, asks a world whose stream now reads otherwise.
    const other = [_][]const u8{ "x", "y", "z" };
    var second: effects.Script = .{ .streams = &.{&other} };
    vm.again();
    vm.source = second.source();
    b.h.runtime.machine.control.trace = .digest;
    defer b.h.runtime.machine.control.trace = .full;
    const x = b.h.runtime.evaluate(p, fuel).ok;
    try std.testing.expectEqual(@as(u64, 1), second.reads);
    try std.testing.expectEqualStrings("alphabetax", text(x, "X"));
    // Its report replays a second run that is given the record and the grants, and no world.
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try reporting.writeReplayed(&out, x, again.producer(p, fuel), false, .{});
    try std.testing.expectEqualStrings("{\"X\":\"alphabetax\",\"$inputs\":{\"count\":3,\"bytes\":10}}\n", out.buffered());
    try std.testing.expectEqual(@as(?effects.InputSource, null), again.control.effects.inputs.source);
}

test "digest runs at six windows give the stored report, and refuse a forged record or grants" {
    const b = try Bench.create();
    defer b.destroy();
    const source =
        \\Later(R:reader, W:writer, Wait:float)<transacts><suspends>:string = Block{ Sleep(Wait); L := Attempt(R.ReadLine[], "<end>"); W.WriteLine("t {L}"); Print("p {L}"); L }
        \\Step(S:string)<transacts>:string = Attempt(Block{ R := OpenReader["extra"]; S + R.ReadLine[] }, S + ".")
        \\Go(Wait:float)<transacts>:option(task(string)) = Attempt(Block{ R := OpenReader["config"]; W := OpenWriter["log"]; option{Spawn{ Later(R, W, Wait) }} }, option{})
        \\A:option(task(string)) = Go(1.0)
        \\B:option(task(string)) = Go(2.0)
        \\C:string = Iterate(Step, 6, "")
        \\H:option(writer) = option{OpenWriter["audit"]}
    ;
    const p = try b.h.compile(source);
    const whole = try b.run(source);
    var stored_report: [2048]u8 = undefined;
    const expected = try reportOf(whole, &stored_report);
    try std.testing.expect(std.mem.indexOf(u8, expected, "\"H\":[{\"$writer\":\"audit\"}]") != null);
    const again = try scratch.storage(trace_replay.Storage);
    defer scratch.release(again);
    scratch.initialise(again);
    const vm = &b.h.runtime.machine.control;
    defer {
        vm.trace = .full;
        vm.trace_window = types.ControlStorage.default_trace_window;
        vm.reclaim_floor = types.ControlStorage.default_reclaim_floor;
        vm.effects.inputs.grants = &.{};
    }
    vm.effects.inputs.grants = &standard_grants;
    var buffer: [2048]u8 = undefined;
    for ([_]u32{ 1, 2, 3, 7, 64, types.ControlStorage.default_trace_window }) |window| {
        vm.trace = .digest;
        vm.trace_window = window;
        vm.reclaim_floor = 0;
        again.control.trace_window = window;
        again.control.reclaim_floor = 0;
        vm.effects.inputs.prefix = whole.effects.inputRecord();
        const digest = b.h.runtime.evaluate(p, fuel).ok;
        var out: std.Io.Writer = .fixed(&buffer);
        _ = try reporting.writeReplayed(&out, digest, again.producer(p, fuel), false, .{});
        try std.testing.expectEqualStrings(expected, out.buffered());
        // A line changed, though the second run is given it: its steps no longer lead to the
        // values the first run reported.
        var entries: [16]effects.InputEntry = undefined;
        @memcpy(entries[0..digest.effects.inputs.len], digest.effects.inputs);
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..digest.effects.input_bytes.len], digest.effects.input_bytes);
        bytes[0] = 'A';
        var forged = digest;
        forged.effects.input_bytes = bytes[0..digest.effects.input_bytes.len];
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        // Grants renamed, swapped in kind, or fewer.
        const renamed = [_]effects.Grant{ standard_grants[0], standard_grants[1], standard_grants[2], .{ .kind = .writer, .name = "other" } };
        const swapped = [_]effects.Grant{ standard_grants[0], .{ .kind = .reader, .name = "log" }, standard_grants[2], standard_grants[3] };
        for ([_][]const effects.Grant{ &renamed, &swapped, standard_grants[0..3] }) |grants| {
            forged = digest;
            forged.effects.grants = grants;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
    }
}
