//! Forged IR, tables and reports around grants and handles (RFC-0086, P2.3, "Admission"): every
//! case is refused by both machines' admissions, each in its own code, and, for a report, by the
//! replay, which admits the program again before it replays and checks every handle against the
//! run's grants. Each case is made from a valid program by changing one thing; the program it is
//! made from runs.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const stdlib_natives = @import("stdlib_natives.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

const grants = [_]effects.Grant{
    .{ .kind = .reader, .name = "config" },
    .{ .kind = .writer, .name = "log" },
    .{ .kind = .reader, .name = "extra" },
};
const config_lines = [_][]const u8{ "alpha", "beta" };
const extra_lines = [_][]const u8{"one"};

/// The program every case is made from. `Peek` opens a reader by a name it is given, `Pass`
/// returns a handle, `Up` and `Down` are the casts to and from `any` of an `i64`, which the
/// cases retype to handles.
const base =
    \\Use(R:reader, W:writer)<transacts>:string = Block{ L := Attempt(R.ReadLine[], ""); W.WriteLine(L); L }
    \\Peek(N:string, K:i64)<reads>:i64 = Attempt(Block{ R := OpenReader[N]; K }, 0)
    \\Pass(R:reader)<computes>:reader = R
    \\Up(X:i64)<computes>:any = any(X)
    \\Down(A:any)<computes><decides>:i64 = i64[A]
    \\A:string = Attempt(Use(OpenReader["config"], OpenWriter["log"]), "-")
    \\B:i64 = Peek("extra", 1)
    \\C:option(reader) = option{Pass(OpenReader["config"])}
    \\D:option(writer) = option{OpenWriter["log"]}
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    definitions: std.ArrayList(types.Definition),
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .definitions = .empty,
            .program = p,
            .original = p,
        };
        try copy.definitions.appendSlice(allocator, p.definitions);
        copy.point();
        return copy;
    }
    fn point(self: *Copy) void {
        self.program.nodes = self.nodes;
        self.program.function_nodes = self.function_nodes;
        self.program.functions = self.functions;
        self.program.definitions = self.definitions.items;
    }
    fn free(self: *Copy) void {
        self.definitions.deinit(allocator);
        allocator.free(self.functions);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        self.definitions.items.len = self.original.definitions.len;
        @memcpy(self.definitions.items, self.original.definitions);
        self.program = self.original;
        self.point();
    }
    /// Appends a definition, which takes the next type id.
    fn define(self: *Copy, item: types.Definition) !types.Type {
        try self.definitions.append(allocator, item);
        self.program.definitions = self.definitions.items;
        return @fromBackingInt(@intCast(self.definitions.items.len - 1 + catalogue.builtin_count));
    }
    fn function(self: *const Copy, name: []const u8) usize {
        for (self.original.functions, 0..) |f, index| if (std.mem.eql(u8, f.name.text(self.original.source), name)) return index;
        unreachable;
    }
    /// The `nth` node of `kind` in the body of the function `name`, by its place in the body.
    fn body(self: *const Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) u32 {
        const f = self.original.functions[self.function(name)];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
            if (seen == nth) return @intCast(index);
            seen += 1;
        };
        unreachable;
    }
    fn at(self: *Copy, name: []const u8, index: u32) *types.FunctionNode {
        return &self.function_nodes[self.original.functions[self.function(name)].body.start + index];
    }
    fn parameter(self: *const Copy, name: []const u8, n: u32) u32 {
        const f = self.original.functions[self.function(name)];
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .parameter and entry.input.parameter == n) return @intCast(index);
        unreachable;
    }
    /// The `nth` root node of `kind`.
    fn root(self: *const Copy, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) u32 {
        var seen: usize = 0;
        for (self.original.nodes, 0..) |node, index| if (node.kind == kind) {
            if (seen == nth) return @intCast(index);
            seen += 1;
        };
        unreachable;
    }
};

/// The type `grant(kind)` of the program, and `option` of it.
fn handleType(p: types.Program, kind: effects.GrantKind) types.Type {
    for (p.definitions, 0..) |item, index| if (item == .grant and item.grant == kind) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    unreachable;
}
fn optionOf(p: types.Program, element: types.Type) types.Type {
    for (p.definitions, 0..) |item, index| if (item == .option and item.option == element) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    unreachable;
}

fn setup(h: *harness.Harness, script: *effects.Script) void {
    script.* = .{ .streams = &.{ &config_lines, &.{}, &extra_lines } };
    h.control.effects.inputs.source = script.source();
    h.control.effects.inputs.grants = &grants;
    h.runtime.machine.control.effects.inputs.grants = &grants;
}

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

test "forged grants: a kind, a name, a type and a function that do not fit are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const reader = handleType(p, .reader);
    const writer = handleType(p, .writer);
    const peek = c.body("Peek", .grant, 0);
    // An unknown kind, and the other kind than the node's type says.
    for ([_]effects.GrantKind{ @fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(255)), .writer }) |kind| {
        c.at("Peek", peek).node.kind.grant.kind = kind;
        try refused(h, run, c.program);
        c.restore();
    }
    // A name of type `i64`, a name after the node, the node itself.
    c.at("Peek", peek).node.kind.grant.name = c.parameter("Peek", 1);
    try refused(h, run, c.program);
    c.restore();
    for ([_]u32{ peek, peek + 1 }) |name| {
        c.at("Peek", peek).node.kind.grant.name = name;
        try refused(h, run, c.program);
        c.restore();
    }
    // Typed as the handle without the option, as an option of the other kind, as a string.
    for ([_]types.Type{ reader, optionOf(p, writer), .string }) |wrong| {
        c.at("Peek", peek).node.value_type = wrong;
        try refused(h, run, c.program);
        c.restore();
    }
    // In a function that only computes: opening reads the run's grants.
    const f = c.function("Peek");
    c.functions[f].transacts = false;
    c.functions[f].detail.no_reads = false;
    c.functions[f].detail.no_writes = false;
    c.functions[f].detail.no_allocates = false;
    try refused(h, run, c.program);
    c.restore();
    // The same at the root: a name that is no string, typed without the option.
    const top = c.root(.grant, 0);
    c.nodes[top].value_type = reader;
    try refused(h, run, c.program);
    c.restore();
    c.nodes[top].kind.grant.kind = @fromBackingInt(@intCast(9));
    try refused(h, run, c.program);
    c.restore();
}

test "forged handles: nothing makes one but a grant, and the catalogue has one type per kind" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const p = try h.compile(base);
    const run = (try h.run(p, fuel)).ok;
    var c = try Copy.of(p);
    defer c.free();
    const reader = handleType(p, .reader);
    // An enumerator typed `reader`: no grant has a case a program can name. (A `Case` over
    // handles would be made of such enumerators, and is refused with them.)
    const value = c.body("Peek", .option_value, 0);
    c.at("Peek", value).node.kind = .{ .enumeration = 0 };
    try refused(h, run, c.program);
    c.restore();
    // A cast of a handle to `any`: `Up` made to take a reader.
    const up = c.function("Up");
    c.functions[up].parameters[0] = reader;
    c.at("Up", c.parameter("Up", 0)).node.value_type = reader;
    try refused(h, run, c.program);
    c.restore();
    // A cast from `any` to a handle, and a test of `any` for one.
    const down = c.function("Down");
    c.at("Down", c.body("Down", .instance_of, 0)).node.kind.instance_of.class = reader;
    try refused(h, run, c.program);
    c.restore();
    c.at("Down", c.body("Down", .downcast, 0)).node.value_type = reader;
    c.functions[down].value_type = reader;
    try refused(h, run, c.program);
    c.restore();
    // A second definition of a kind, and one of a kind that does not exist.
    _ = try c.define(.{ .grant = .reader });
    try refused(h, run, c.program);
    c.restore();
    _ = try c.define(.{ .grant = @fromBackingInt(@intCast(4)) });
    try refused(h, run, c.program);
    c.restore();
    // A definition of the other kind alone, which nothing uses, is admitted.
    var lone = try Copy.of(try h.compile("A:i64 = 1\nF(R:reader)<computes>:reader = R"));
    defer lone.free();
    _ = try lone.define(.{ .grant = .writer });
    const own = try harness.create();
    defer scratch.release(own);
    try std.testing.expect(try own.run(lone.program, fuel) == .ok);
}

fn kernel(id: []const u8) u16 {
    return stdlib_natives.find(&native_std.table, id).?;
}

fn printsElsewhere(ctx: *native.Context, text: []const u8) native.Error!void {
    try ctx.actOn(1, text);
}
fn writesElsewhere(ctx: *native.Context, writer: native.Writer, text: []const u8) native.Error!void {
    try ctx.actOn(writer.grant + 2, text);
}
fn readsElsewhere(ctx: *native.Context, reader: native.Reader) native.Error!?[]const u8 {
    _ = try ctx.input(.line, reader.grant + 2);
    return null;
}
fn readsAsAWriter(ctx: *native.Context, writer: native.Writer, text: []const u8) native.Error!void {
    _ = text;
    _ = try ctx.input(.line, writer.grant);
}

test "forged tables: a native reaches only the grant it was given, on its own channel" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    var table: [native_std.table.len]native.Entry = native_std.table;
    h.front.natives = &table;
    defer h.front.natives = &native_std.table;
    const print = kernel("std.print");
    const read_line = kernel("std.read_line");
    const write_line = kernel("std.write_line");
    const Case = struct { index: u16, entry: native.Entry, source: []const u8 };
    for ([_]Case{
        // An action without a writer on a writer's channel.
        .{ .index = print, .entry = native.effectEntry("std.print", printsElsewhere, .{ .base = 2 }, .output), .source = "A:tuple() = Print(\"x\")" },
        // A writer's action on another channel.
        .{ .index = write_line, .entry = native.effectEntry("std.write_line", writesElsewhere, .{ .base = 2 }, .output), .source = "A:i64 = Attempt(Block{ W := OpenWriter[\"log\"]; W.WriteLine(\"x\"); 1 }, 0)" },
        // A reader's line of another grant.
        .{ .index = read_line, .entry = native.effectEntry("std.read_line", readsElsewhere, .{ .base = 2 }, .input), .source = "A:string = Attempt(Block{ R := OpenReader[\"config\"]; R.ReadLine[] }, \"-\")" },
        // An action that reaches for an input.
        .{ .index = write_line, .entry = native.effectEntry("std.write_line", readsAsAWriter, .{ .base = 2 }, .output), .source = "A:i64 = Attempt(Block{ W := OpenWriter[\"log\"]; W.WriteLine(\"x\"); 1 }, 0)" },
    }) |case| {
        table[case.index] = case.entry;
        defer table[case.index] = native_std.table[case.index];
        const p = try h.compile(case.source);
        script.rewind();
        const result = try h.run(p, fuel);
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_native, result.failed.code);
        try std.testing.expectEqual(@as(u64, 0), script.reads);
        try std.testing.expectEqual(@as(u64, 0), h.control.effects.committed.count);
    }
    // A writer handed to the reader's native, and a reader to the writer's: the operand's type is
    // not the parameter's, in both machines.
    const p = try h.compile("A:string = Attempt(Block{ R := OpenReader[\"config\"]; W := OpenWriter[\"log\"]; W.WriteLine(\"x\"); R.ReadLine[] }, \"-\")");
    var c = try Copy.of(p);
    defer c.free();
    const write_call = c.root(.native_call, 0);
    const read_call = c.root(.native_call, 1);
    try std.testing.expectEqual(write_line, c.nodes[write_call].kind.native_call.native);
    const writer_operand = c.nodes[write_call].kind.native_call.args[0];
    const reader_operand = c.nodes[read_call].kind.native_call.args[0];
    c.nodes[read_call].kind.native_call.args[0] = writer_operand;
    try harness.invalid(h, c.program);
    c.restore();
    c.nodes[write_call].kind.native_call.args[0] = reader_operand;
    try harness.invalid(h, c.program);
}

/// Runs `source` on both machines and returns the reference's run, whose record lives in the
/// harness until the next run.
fn stored(h: *harness.Harness, script: *effects.Script, source: []const u8) !evaluator.Execution {
    script.rewind();
    _ = try h.run(try h.compile(source), fuel);
    script.rewind();
    const x = evaluator.evaluateWithRuntimeStorage(try h.compile(source), &h.values, &h.members, &h.control, &h.state, &h.frames, fuel).ok;
    _ = try reporting.validate(x, false, .{});
    return x;
}

test "forged reports: a handle that names no grant of its kind, grants changed, a line or its channel forged" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const x = try stored(h, &script,
        \\Use(R:reader, W:writer)<transacts>:string = Block{ L := Attempt(R.ReadLine[], ""); W.WriteLine(L); L }
        \\Nap()<transacts><suspends>:void = Sleep(1.0)
        \\var V:option(reader) = option{}
        \\A:string = Attempt(Use(OpenReader["config"], OpenWriter["log"]), "-")
        \\C:option(reader) = option{OpenReader["extra"]}
        \\S:i64 = Attempt(Block{ set V = option{OpenReader["config"]}; 1 }, 0)
        \\T:task(void) = Spawn{ Nap() }
        \\K:option(reader) = V
    );
    // The handles of the run: the members of the options that hold them.
    var handles: usize = 0;
    for (x.aggregate_values, 0..) |value, at| if (value == .enumeration and catalogue.grantKind(value.enumeration.value_type, x.program.definitions) != null) {
        handles += 1;
        var members: [256]types.Value = undefined;
        @memcpy(members[0..x.aggregate_values.len], x.aggregate_values);
        var forged = x;
        forged.aggregate_values = members[0..x.aggregate_values.len];
        // Past every grant, of the other kind, or (for a reader) another grant of its kind.
        const kind = catalogue.grantKind(value.enumeration.value_type, x.program.definitions).?;
        const other: u32 = if (kind == .writer) 0 else 1;
        const sibling: u32 = if (kind == .writer) 3 else if (value.enumeration.index == 0) 2 else 0;
        for ([_]u32{ 99, other, sibling }) |index| {
            members[at].enumeration.index = index;
            errdefer std.debug.print("member {d} as {d}\n", .{ at, index });
            try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        }
    };
    try std.testing.expect(handles >= 3);
    // The registers of the root that hold a handle.
    var registers: usize = 0;
    for (x.values, 0..) |value, at| if (x.active(at) and value == .enumeration and catalogue.grantKind(value.enumeration.value_type, x.program.definitions) != null) {
        registers += 1;
        var values: [256]types.Value = undefined;
        @memcpy(values[0..x.values.len], x.values);
        var forged = x;
        forged.values = values[0..x.values.len];
        values[at].enumeration.index = if (value.enumeration.index == 0) 2 else 0;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    };
    try std.testing.expect(registers >= 2);
    // The cell `V`, which the report lists as the run ended.
    try std.testing.expect(x.cells.len != 0);
    // The grants: renamed, a kind swapped, one missing, one added twice, an unknown kind.
    const renamed = [_]effects.Grant{ grants[0], grants[1], .{ .kind = .reader, .name = "other" } };
    const swapped = [_]effects.Grant{ grants[0], .{ .kind = .reader, .name = "log" }, grants[2] };
    const doubled = [_]effects.Grant{ grants[0], grants[1], grants[2], grants[2] };
    const unknown = [_]effects.Grant{ grants[0], grants[1], grants[2], .{ .kind = @fromBackingInt(@intCast(4)), .name = "x" } };
    for ([_][]const effects.Grant{ &renamed, &swapped, grants[0..2], &doubled, &unknown, &.{} }) |list| {
        var forged = x;
        forged.effects.grants = list;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    }
    // More grants than a host may give, the run's own first: refused before anything is replayed
    // against them (a writer's channel past every grant is no channel).
    const names = try allocator.alloc([8]u8, effects.grant_capacity + 1);
    defer allocator.free(names);
    const many = try allocator.alloc(effects.Grant, effects.grant_capacity + 1);
    defer allocator.free(many);
    @memcpy(many[0..grants.len], &grants);
    for (many[grants.len..], names[grants.len..], grants.len..) |*grant, *name, index| {
        grant.* = .{ .kind = .writer, .name = try std.fmt.bufPrint(name, "w{d}", .{index}) };
    }
    var crowded = x;
    crowded.effects.grants = many;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(crowded, false, .{}));
    // A line's bytes, the grant it was asked of, and a line claimed where the stream ended.
    var entries: [8]effects.InputEntry = undefined;
    @memcpy(entries[0..x.effects.inputs.len], x.effects.inputs);
    for (0..3) |field| {
        @memcpy(entries[0..x.effects.inputs.len], x.effects.inputs);
        var forged = x;
        forged.effects.inputs = entries[0..x.effects.inputs.len];
        switch (field) {
            0 => forged.effects.input_bytes = "ALPHA",
            1 => entries[0].request = 2,
            else => entries[0].status = .end,
        }
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    }
    // A committed line listed on another channel, or `Print`'s.
    var listed: [8]effects.Entry = undefined;
    @memcpy(listed[0..x.effects.entries.len], x.effects.entries);
    try std.testing.expectEqual(@as(u32, 2), listed[0].channel);
    for ([_]u32{ 0, 4, 3 }) |channel| {
        listed[0].channel = channel;
        var forged = x;
        forged.effects.entries = listed[0..x.effects.entries.len];
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
    }
    _ = try reporting.validate(x, false, .{});
}

test "a forged step of a grant in a frame is refused: another handle, none, or one more member" {
    const h = try harness.create();
    defer scratch.release(h);
    var script: effects.Script = .{};
    setup(h, &script);
    const x = try stored(h, &script, "Open(N:string)<reads>:option(reader) = option{OpenReader[N]}\nA:option(reader) = Open(\"extra\")\nB:option(reader) = Open(\"none\")");
    var forged_steps: usize = 0;
    for (h.control.calls[0..h.control.call_count], 0..) |step, at| {
        if (step.value != .aggregate) continue;
        const shape = catalogue.definition(step.value.aggregate.value_type, x.program.definitions) orelse continue;
        if (shape != .option or catalogue.grantKind(shape.option, x.program.definitions) == null) continue;
        const original = h.control.calls[at];
        defer h.control.calls[at] = original;
        const span = original.value.aggregate.elements;
        forged_steps += 1;
        // The option of a grant found claimed empty, or of none claimed found.
        h.control.calls[at].value.aggregate.elements = if (span.start == span.end) .{ .start = span.start, .end = span.start + 1 } else .{ .start = span.start, .end = span.start };
        try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{}));
    }
    try std.testing.expect(forged_steps >= 2);
    _ = try reporting.validate(x, false, .{});
}
